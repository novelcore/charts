#!/bin/sh
# ci-secrets-prep.sh: build-push init step for ci-build and ci-rc-build
# (kaos PRD 695, user-managed secrets, spec section 6.2).
#
# 1. Lays the user's CI secrets out for Dockerfile RUN steps:
#      p_{name}_{KEY}  ->  $KANIKO_SECRETS_DIR/{name}/{KEY}       (project secrets)
#      o_{name}_{KEY}  ->  $KANIKO_SECRETS_DIR/org/{name}/{KEY}   (org secrets)
#    from the project-level Secret first, then the app-level Secret, so app
#    overwrites project. Secret names never contain "_" (DNS-1123), so the
#    first "_" after the prefix ends the name; KEY may contain "_".
# 2. Writes kaniko's docker config: the platform push credential (Zot auth,
#    or the gcr credHelper for GAR) merged with the "auths" of every laid-out
#    dockerconfigjson file. The platform entry always wins for its own host.
#
# With nothing mounted, the output is byte-identical to what the build-push
# container wrote before this script existed.
#
# NEVER print a value. Only secret names, key names, file counts and registry
# host names may reach stdout/stderr. No `set -x`.
# This file is inlined into an Argo template: it must never contain two
# consecutive opening braces.
set -eu
umask 022

PROJECT_SRC="${CI_SECRETS_PROJECT_DIR:-/etc/ci-secrets/project}"
APP_SRC="${CI_SECRETS_APP_DIR:-/etc/ci-secrets/app}"
OUT="${KANIKO_SECRETS_DIR:-/kaniko/secrets}"
DOCKER_CONFIG_FILE="${DOCKER_CONFIG_FILE:-/kaniko/.docker/config.json}"
REGISTRY_AUTH_DIR="${REGISTRY_AUTH_DIR:-/etc/registry-auth}"
REGISTRY="${REGISTRY:?REGISTRY is required}"
REGISTRY_TYPE="${REGISTRY_TYPE:-zot}"
IMAGE_REPO="${IMAGE_REPO:-}"

NAME_RE='^[a-z0-9]([-a-z0-9]{0,38}[a-z0-9])?$'
KEY_RE='^[A-Za-z_][A-Za-z0-9_]*$'

# lay_out SRC_DIR: copy every p_/o_ file of one mounted Secret into OUT.
# A Secret volume holds one symlink per key plus hidden ..data entries; the
# glob skips the hidden ones. A missing optional Secret is an empty or
# absent directory.
lay_out() {
  src="$1"
  [ -d "$src" ] || return 0
  for f in "$src"/*; do
    [ -e "$f" ] || continue
    file=$(basename "$f")
    case "$file" in
      p_*) scope=p; rest="${file#p_}" ;;
      o_*) scope=o; rest="${file#o_}" ;;
      *) echo "ci-secrets: skipping unexpected key ${file}" >&2; continue ;;
    esac
    name="${rest%%_*}"
    key="${rest#*_}"
    if [ "$name" = "$rest" ] \
      || ! printf '%s' "$name" | grep -Eq "$NAME_RE" \
      || ! printf '%s' "$key" | grep -Eq "$KEY_RE"; then
      echo "ci-secrets: skipping malformed key ${file}" >&2
      continue
    fi
    if [ "$scope" = p ]; then
      if [ "$name" = org ]; then
        echo "ci-secrets: skipping ${file}: project secret name 'org' is reserved" >&2
        continue
      fi
      dest="${OUT}/${name}"
    else
      dest="${OUT}/org/${name}"
    fi
    mkdir -p "$dest"
    cat "$f" > "${dest}/${key}"
  done
}

lay_out "$PROJECT_SRC"
lay_out "$APP_SRC"

LAID_OUT=0
SECRET_NAMES=""
if [ -d "$OUT" ]; then
  LAID_OUT=$(find "$OUT" -type f | wc -l | tr -d ' ')
  SECRET_NAMES=$(find "$OUT" -type f | sed "s|^${OUT}/||; s|/[^/]*$||" | sort -u | tr '\n' ' ')
fi
echo "ci-secrets: ${LAID_OUT} file(s) under ${OUT} from secret(s): ${SECRET_NAMES:-none}"

# Registry credentials: every laid-out dockerconfigjson, in sorted path order
# (org/... sorts among project names deterministically).
USER_CONFIGS=""
if [ -d "$OUT" ]; then
  USER_CONFIGS=$(find "$OUT" -type f -name dockerconfigjson | sort)
fi
for c in $USER_CONFIGS; do
  if ! yq -p json -e '.auths | tag == "!!map"' "$c" >/dev/null 2>&1; then
    echo "FATAL: ${c#"${OUT}"/} is not a docker config JSON with an \"auths\" object" >&2
    exit 1
  fi
done

# The platform's own push host: its credential must win over any user entry.
if [ "$REGISTRY_TYPE" = "gar" ]; then
  PUSH_HOST="${IMAGE_REPO%%/*}"
  [ -n "$PUSH_HOST" ] || PUSH_HOST="${REGISTRY%%/*}"
else
  PUSH_HOST="$REGISTRY"
fi
export PUSH_HOST

AUTH=""
if [ "$REGISTRY_TYPE" != "gar" ]; then
  # Unchanged from the pre-PRD-695 build-push script: fail in-step if Zot's
  # credential is missing rather than dying later on a confusing error.
  if [ ! -f "${REGISTRY_AUTH_DIR}/username" ]; then
    echo "FATAL: registry_type=${REGISTRY_TYPE} requires the ci-registry-auth Secret, which is not mounted" >&2
    exit 1
  fi
  REG_USER=$(cat "${REGISTRY_AUTH_DIR}/username")
  REG_PASS=$(cat "${REGISTRY_AUTH_DIR}/password")
  AUTH=$(printf '%s:%s' "${REG_USER}" "${REG_PASS}" | base64 | tr -d '\n')
fi
export AUTH REGISTRY

mkdir -p "$(dirname "$DOCKER_CONFIG_FILE")"
if [ -z "$USER_CONFIGS" ]; then
  # Today's behaviour, byte for byte: Zot writes one auth entry, GAR writes
  # no docker config at all (kaniko falls through to Workload Identity).
  if [ "$REGISTRY_TYPE" != "gar" ]; then
    cat > "$DOCKER_CONFIG_FILE" <<EOF
{"auths":{"${REGISTRY}":{"auth":"${AUTH}"}}}
EOF
  fi
  echo "ci-secrets: no user registry credentials"
  exit 0
fi

# Later files win on a host collision; only "auths" is taken from user files.
# shellcheck disable=SC2016,SC2086 # yq expression, not shell; paths have no spaces
MERGED=$(yq -p json -o json -I0 eval-all \
  '. as $item ireduce ({}; . * $item) | {"auths": (.auths // {})}' \
  $USER_CONFIGS)
# Drop every user entry for the push host, in any spelling docker accepts
# (scheme and path are ignored when docker matches a host).
MERGED=$(printf '%s' "$MERGED" | yq -p json -o json -I0 \
  '.auths |= with_entries(select((.key | sub("^https?://"; "") | sub("/.*$"; "")) != strenv(PUSH_HOST)))')
if [ "$REGISTRY_TYPE" = "gar" ]; then
  # A docker config that exists but has no entry for GAR makes kaniko push
  # anonymously (kubecore-operator#1088); the gcr helper exchanges the
  # Workload Identity token instead.
  MERGED=$(printf '%s' "$MERGED" | yq -p json -o json -I0 '.credHelpers[strenv(PUSH_HOST)] = "gcr"')
else
  MERGED=$(printf '%s' "$MERGED" | yq -p json -o json -I0 '.auths[strenv(REGISTRY)] = {"auth": strenv(AUTH)}')
fi
printf '%s\n' "$MERGED" > "$DOCKER_CONFIG_FILE"
HOSTS=$(printf '%s' "$MERGED" | yq -p json '.auths | keys | .[]' | tr '\n' ' ')
echo "ci-secrets: docker config written for registries: ${HOSTS}"
