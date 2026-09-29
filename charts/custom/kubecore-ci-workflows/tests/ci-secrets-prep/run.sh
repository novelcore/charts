#!/bin/sh
# Tests for files/ci-secrets-prep.sh. Runs in the SAME image the init
# container uses (mikefarah/yq:4.44.3, busybox sh + yq):
#
#   docker run --rm --user 0 --entrypoint sh \
#     -v "$PWD/charts/custom/kubecore-ci-workflows:/chart:ro" \
#     mikefarah/yq:4.44.3 /chart/tests/ci-secrets-prep/run.sh
#
# Each case builds fake Secret volumes (with the ..data symlink layout the
# kubelet uses), runs the script, and asserts on the files it wrote and on
# its output. Exit status is the number of failed cases.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${HERE}/../../files/ci-secrets-prep.sh"
FAILED=0
PASSED=0

ZOT=zot.zot-registry.svc.cluster.local:5000
ZOT_AUTH=$(printf '%s' 'probe:zot-api-key' | base64 | tr -d '\n')

pass() { PASSED=$((PASSED + 1)); echo "PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $1"; }

# All sandboxes live under one base dir so a single trap removes them all,
# including test values, on exit (normal or not).
BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
CASE_N=0

# new_case: fresh sandbox; sets T and the script's path variables.
new_case() {
  CASE_N=$((CASE_N + 1))
  T="${BASE_TMP}/case-${CASE_N}"
  mkdir -p "$T/project" "$T/app" "$T/registry-auth" "$T/docker"
  printf '%s' probe > "$T/registry-auth/username"
  printf '%s' zot-api-key > "$T/registry-auth/password"
}

# put_key DIR KEY VALUE: one Secret key the way the kubelet projects it
# (DIR/..data/KEY real file, DIR/KEY symlink).
put_key() {
  mkdir -p "$1/..data"
  printf '%s' "$3" > "$1/..data/$2"
  ln -sf "..data/$2" "$1/$2"
}

# run_prep [ENV=VAL ...]: runs the script against the sandbox; output in $T/out.
run_prep() {
  env CI_SECRETS_PROJECT_DIR="$T/project" CI_SECRETS_APP_DIR="$T/app" \
    KANIKO_SECRETS_DIR="$T/secrets" DOCKER_CONFIG_FILE="$T/docker/config.json" \
    REGISTRY_AUTH_DIR="$T/registry-auth" REGISTRY="$ZOT" REGISTRY_TYPE=zot \
    "$@" sh "$SCRIPT" > "$T/out" 2>&1
  echo $? > "$T/rc"
}

rc() { cat "$T/rc"; }
file_is() { [ -f "$1" ] && [ "$(cat "$1")" = "$2" ]; }
json() { yq -p json -o json -I0 "$1" "$T/docker/config.json"; }
never_printed() { ! grep -q -- "$1" "$T/out"; }

# 1. Nothing mounted: build identical to today.
new_case
rmdir "$T/project" "$T/app"
run_prep
expected="{\"auths\":{\"${ZOT}\":{\"auth\":\"${ZOT_AUTH}\"}}}"
if [ "$(rc)" = 0 ] && [ "$(cat "$T/docker/config.json")" = "$expected" ] \
  && [ -z "$(find "$T/secrets" -type f 2>/dev/null)" ]; then
  pass "no secrets mounted: config.json is today's single Zot entry, no files"
else
  fail "no secrets mounted: rc=$(rc) config=$(cat "$T/docker/config.json" 2>/dev/null)"
fi

# 1b. Optional Secrets absent -> kubelet mounts EMPTY dirs: same result.
new_case
run_prep
if [ "$(rc)" = 0 ] && [ "$(cat "$T/docker/config.json")" = "$expected" ]; then
  pass "empty optional mounts: config.json is today's single Zot entry"
else
  fail "empty optional mounts: rc=$(rc)"
fi

# 1c. GAR, nothing mounted: no docker config at all, as today.
new_case
run_prep REGISTRY_TYPE=gar IMAGE_REPO=europe-west3-docker.pkg.dev/acme/shop/web
if [ "$(rc)" = 0 ] && [ ! -e "$T/docker/config.json" ]; then
  pass "gar, nothing mounted: no docker config written"
else
  fail "gar, nothing mounted: rc=$(rc)"
fi

# 1d. Zot without ci-registry-auth still fails loudly, as today.
new_case
rm "$T/registry-auth/username" "$T/registry-auth/password"
run_prep
if [ "$(rc)" != 0 ] && grep -q "requires the ci-registry-auth Secret" "$T/out"; then
  pass "zot without ci-registry-auth: FATAL, as before"
else
  fail "zot without ci-registry-auth: rc=$(rc)"
fi

# 2. Project-only secret.
new_case
put_key "$T/project" p_npm_TOKEN s3cr3t-npm
run_prep
if [ "$(rc)" = 0 ] && file_is "$T/secrets/npm/TOKEN" s3cr3t-npm \
  && never_printed s3cr3t-npm; then
  pass "project-only: /kaniko/secrets/npm/TOKEN"
else
  fail "project-only: rc=$(rc) out=$(cat "$T/out")"
fi

# 3. App overrides project for the same secret and key; other keys survive.
new_case
put_key "$T/project" p_npm_TOKEN project-value
put_key "$T/project" p_npm_REGISTRY_URL https://npm.example
put_key "$T/app" p_npm_TOKEN app-value
run_prep
if [ "$(rc)" = 0 ] && file_is "$T/secrets/npm/TOKEN" app-value \
  && file_is "$T/secrets/npm/REGISTRY_URL" https://npm.example; then
  pass "app overrides project"
else
  fail "app overrides project: TOKEN=$(cat "$T/secrets/npm/TOKEN" 2>/dev/null)"
fi

# 4. Org and project secrets with the same name land in different dirs.
new_case
put_key "$T/project" p_npm_TOKEN from-project
put_key "$T/project" o_npm_TOKEN from-org
run_prep
if [ "$(rc)" = 0 ] && file_is "$T/secrets/npm/TOKEN" from-project \
  && file_is "$T/secrets/org/npm/TOKEN" from-org; then
  pass "org + project same name: npm/ and org/npm/"
else
  fail "org + project same name"
fi

# 5. KEY containing underscores; name containing dashes.
new_case
put_key "$T/app" p_payments-api_API_KEY_V2 k2
put_key "$T/app" o_pager-duty_ROUTING__KEY_ rk
run_prep
if [ "$(rc)" = 0 ] && file_is "$T/secrets/payments-api/API_KEY_V2" k2 \
  && file_is "$T/secrets/org/pager-duty/ROUTING__KEY_" rk; then
  pass "KEY with underscores split on the first _ after the name"
else
  fail "KEY with underscores: $(find "$T/secrets" -type f)"
fi

# 6. Malformed and reserved keys are skipped by NAME, never by value.
new_case
put_key "$T/project" p_npm notakey-value
put_key "$T/project" p_org_TOKEN reserved-value
put_key "$T/project" x_npm_TOKEN wrongprefix-value
put_key "$T/project" p_Bad_TOKEN badname-value
put_key "$T/project" p_ok_TOKEN ok
run_prep
if [ "$(rc)" = 0 ] && file_is "$T/secrets/ok/TOKEN" ok \
  && [ "$(find "$T/secrets" -type f | wc -l | tr -d ' ')" = 1 ] \
  && never_printed notakey-value && never_printed reserved-value \
  && never_printed wrongprefix-value && never_printed badname-value \
  && grep -q "skipping.*p_org_TOKEN" "$T/out"; then
  pass "malformed/reserved keys skipped, values never printed"
else
  fail "malformed/reserved keys: $(find "$T/secrets" -type f) out=$(cat "$T/out")"
fi

# 7. Multiple registries merged, Zot entry preserved.
new_case
put_key "$T/project" p_ghcr_dockerconfigjson '{"auths":{"ghcr.io":{"auth":"Z2hjcjp0b2s="}}}'
put_key "$T/app" o_hub_dockerconfigjson '{"auths":{"https://index.docker.io/v1/":{"username":"u","password":"hubpass"}}}'
run_prep
if [ "$(rc)" = 0 ] \
  && [ "$(json '.auths["ghcr.io"].auth')" = '"Z2hjcjp0b2s="' ] \
  && [ "$(json '.auths["https://index.docker.io/v1/"].password')" = '"hubpass"' ] \
  && [ "$(json ".auths[\"${ZOT}\"].auth")" = "\"${ZOT_AUTH}\"" ] \
  && [ "$(json '.auths | length')" = 3 ] \
  && never_printed hubpass && never_printed Z2hjcjp0b2s=; then
  pass "multiple registries merged alongside Zot"
else
  fail "multiple registries: rc=$(rc) config=$(cat "$T/docker/config.json" 2>/dev/null) out=$(cat "$T/out")"
fi

# 8. A user entry for the Zot host (any spelling) never replaces Zot's.
new_case
put_key "$T/project" p_evil_dockerconfigjson \
  "{\"auths\":{\"${ZOT}\":{\"auth\":\"dXNlcjp1c2Vy\"},\"https://${ZOT}/v2/\":{\"auth\":\"dXNlcjp1c2Vy\"}}}"
run_prep
if [ "$(rc)" = 0 ] && [ "$(json ".auths[\"${ZOT}\"].auth")" = "\"${ZOT_AUTH}\"" ] \
  && [ "$(json '.auths | length')" = 1 ]; then
  pass "Zot entry wins over a user entry for the Zot host"
else
  fail "Zot entry preserved: config=$(cat "$T/docker/config.json")"
fi

# 9. App registry credential overrides the project one for the same secret.
new_case
put_key "$T/project" p_ghcr_dockerconfigjson '{"auths":{"ghcr.io":{"auth":"b2xk"}}}'
put_key "$T/app" p_ghcr_dockerconfigjson '{"auths":{"ghcr.io":{"auth":"bmV3"}}}'
run_prep
if [ "$(rc)" = 0 ] && [ "$(json '.auths["ghcr.io"].auth')" = '"bmV3"' ]; then
  pass "app registry credential overrides project"
else
  fail "app registry override: config=$(cat "$T/docker/config.json")"
fi

# 9b. App registry credential fully replaces project's, even when they use
# different docker config fields (auth vs username/password): no leftover
# "auth" key survives alongside the new "username"/"password" ones.
new_case
put_key "$T/project" p_ghcr_dockerconfigjson '{"auths":{"ghcr.io":{"auth":"b2xk"}}}'
put_key "$T/app" p_ghcr_dockerconfigjson '{"auths":{"ghcr.io":{"username":"u","password":"newpass"}}}'
run_prep
if [ "$(rc)" = 0 ] \
  && [ "$(json '.auths["ghcr.io"].username')" = '"u"' ] \
  && [ "$(json '.auths["ghcr.io"] | has("auth")')" = 'false' ] \
  && never_printed newpass; then
  pass "app registry credential fully replaces project's (no stale auth field)"
else
  fail "mixed-field override: config=$(cat "$T/docker/config.json" 2>/dev/null)"
fi

# 9c. Merge order is deterministic by scope tier (org, then project, then
# app), not alphabetical path order: "appreg" < "org" < "projreg"
# alphabetically, which would make the project-level secret win under a
# naive path sort even though app-level should be most specific.
new_case
put_key "$T/project" o_orgreg_dockerconfigjson '{"auths":{"conflict.io":{"auth":"org-cred"}}}'
put_key "$T/project" p_projreg_dockerconfigjson '{"auths":{"conflict.io":{"auth":"proj-cred"}}}'
put_key "$T/app" p_appreg_dockerconfigjson '{"auths":{"conflict.io":{"auth":"app-cred"}}}'
run_prep
if [ "$(rc)" = 0 ] && [ "$(json '.auths["conflict.io"].auth')" = '"app-cred"' ]; then
  pass "merge order is org < project < app, not alphabetical by path"
else
  fail "tier order: config=$(cat "$T/docker/config.json" 2>/dev/null)"
fi

# 10. GAR + user registry: user auths plus a gcr credHelper for the push host.
new_case
put_key "$T/project" p_ghcr_dockerconfigjson '{"auths":{"ghcr.io":{"auth":"Z2hjcjp0b2s="},"europe-west3-docker.pkg.dev":{"auth":"eDp5"}}}'
run_prep REGISTRY_TYPE=gar IMAGE_REPO=europe-west3-docker.pkg.dev/acme/shop/web
if [ "$(rc)" = 0 ] \
  && [ "$(json '.credHelpers["europe-west3-docker.pkg.dev"]')" = '"gcr"' ] \
  && [ "$(json '.auths | keys | join(",")')" = '"ghcr.io"' ]; then
  pass "gar + user registry: credHelper for GAR host, user auths kept, GAR user entry dropped"
else
  fail "gar + user registry: config=$(cat "$T/docker/config.json" 2>/dev/null) out=$(cat "$T/out")"
fi

# 11. A dockerconfigjson that is not a docker config fails by NAME only.
new_case
put_key "$T/project" p_ghcr_dockerconfigjson 'not-json-topsecret'
run_prep
if [ "$(rc)" != 0 ] && grep -q "ghcr/dockerconfigjson is not a docker config JSON" "$T/out" \
  && never_printed topsecret; then
  pass "invalid dockerconfigjson: FATAL naming the secret, value not printed"
else
  fail "invalid dockerconfigjson: rc=$(rc) out=$(cat "$T/out")"
fi

# 11b. A dockerconfigjson holding more than one JSON document fails by NAME
# only; values from either document are never printed.
new_case
put_key "$T/project" p_multidoc_dockerconfigjson '{"auths":{"ghcr.io":{"auth":"secret1val"}}}
{"auths":{"evil.io":{"auth":"secret2val"}}}'
run_prep
if [ "$(rc)" != 0 ] && grep -q "multidoc/dockerconfigjson is not a docker config JSON" "$T/out" \
  && never_printed secret1val && never_printed secret2val; then
  pass "multi-document dockerconfigjson: FATAL naming the secret, values not printed"
else
  fail "multi-document dockerconfigjson: rc=$(rc) out=$(cat "$T/out")"
fi

# 11c. A dockerconfigjson whose "auths" entry is not itself a map (a bare
# string, not a credentials object) fails by NAME only.
new_case
put_key "$T/project" p_badauths_dockerconfigjson '{"auths":{"ghcr.io":"not-a-map-topsecret"}}'
run_prep
if [ "$(rc)" != 0 ] && grep -q "badauths/dockerconfigjson is not a docker config JSON" "$T/out" \
  && never_printed topsecret; then
  pass "non-map auths entry: FATAL naming the secret, value not printed"
else
  fail "non-map auths entry: rc=$(rc) out=$(cat "$T/out")"
fi

# 12. The script can be inlined into an Argo template.
if ! grep -q '{{' "$SCRIPT"; then
  pass "script contains no Argo template opener"
else
  fail "script contains '{{' - Argo would try to substitute it"
fi

echo "ci-secrets-prep: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
