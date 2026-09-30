#!/bin/sh
# Tests for ci-build's gitops-notify stale-deploy guard: a build of an OLDER
# commit must never move a dev overlay backwards (measured on dev 2026-09-30:
# a late build of the repo's initial commit overwrote a newer deployment).
# Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/stale-deploy/run.sh /tmp/rendered.yaml
#
# The step's script is EXECUTED, not grepped: it is extracted from the rendered
# ci-build and run against stub git / wget / kustomize on a fixture ops repo.
# NOTIFY_SHELL picks the shell that runs it (default sh; production runs it
# under the alpine image's busybox sh). Needs yq v4. Exit status is the number
# of failed assertions.
set -u
RENDERED="$1"
FAILED=0
PASSED=0

expect_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $3"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"
    echo "  step output (tail): $(printf "%s" "${OUT:-}" | tail -5)"
  fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}
expect_not_has() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected NOT to contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT

SRC="${BASE_TMP}/gitops-notify.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ci-build")
    | .spec.templates[] | select(.name == "gitops-notify") | .container.args[0]' \
  "$RENDERED" > "$SRC"

# The incident's commits: 6767e5c deployed, then a build of the OLDER 97388a6.
NEW_SHA=6767e5c0123456789abcdef0123456789abcdef0
OLD_SHA=97388a60123456789abcdef0123456789abcdef0
IMAGE=reg.example/proj/app1
APP_DIR=kubeapps/proj-app1
OLD_TAG=dev-v0.3.0-20260930-132427-97388a6
NEW_TAG=dev-v0.3.1-20260930-131700-6767e5c

# A kustomize-built tarball holding the stub kustomize the step "downloads".
mkdir -p "${BASE_TMP}/kbin"
cat > "${BASE_TMP}/kbin/kustomize" <<'EOF'
#!/bin/sh
# records "<overlay dir name> <args>"; the step cds into the overlay first
echo "$(basename "$(pwd)") $*" >> "${STUB_LOG_DIR}/kustomize.log"
EOF
chmod +x "${BASE_TMP}/kbin/kustomize"
tar -czf "${BASE_TMP}/kustomize.tar.gz" -C "${BASE_TMP}/kbin" kustomize

# new_case BUILT_SHA: a sandbox with an empty fixture ops repo (the app dir
# exists, no overlays yet) and stub git/wget. COMPARE (a file) is the GitHub
# compare body; COMPARE_FAIL=1 makes the call fail like a non-2xx.
new_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXXXX")
  BUILT="$1"
  mkdir -p "$T/bin" "$T/fixture/${APP_DIR}/base"
  printf 'token' > "$T/token"
  : > "$T/kustomize.log"; : > "$T/git.log"; : > "$T/wget.log"
  rm -f "$T/compare-body"; COMPARE_FAIL=0
  cat > "$T/bin/git" <<EOF
#!/bin/sh
echo "\$*" >> "$T/git.log"
case "\$1" in
  clone) eval "DEST=\\\${\$#}"; cp -R "$T/fixture" "\$DEST" ;;
  diff) [ -s "$T/kustomize.log" ] && exit 1; exit 0 ;;
esac
exit 0
EOF
  cat > "$T/bin/wget" <<EOF
#!/bin/sh
OUT=""; URL=""; HDRS=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -O) OUT="\$2"; shift 2 ;;
    -T) shift 2 ;;
    --header) HDRS="\$HDRS[\$2]"; shift 2 ;;
    -*) shift ;;
    *) URL="\$1"; shift ;;
  esac
done
echo "\$URL \$HDRS" >> "$T/wget.log"
case "\$URL" in
  *kustomize_*) cp "${BASE_TMP}/kustomize.tar.gz" "\$OUT" ;;
  *api.github.com*)
    if [ -f "$T/compare-fail" ]; then
      echo "wget: server returned error: HTTP/1.1 404 Not Found" >&2; exit 1
    fi
    cp "$T/compare-body" "\$OUT" ;;
  *) echo "stub wget: unexpected \$URL" >&2; exit 1 ;;
esac
EOF
  chmod +x "$T/bin/git" "$T/bin/wget"
}

# overlay NAME [IMAGE_NAME TAG [QUOTE]]: a dev overlay in the fixture; with a
# tag, the images: entry kustomize itself writes (QUOTE wraps the tag).
overlay() {
  D="$T/fixture/${APP_DIR}/overlays/$1"
  mkdir -p "$D"
  printf 'apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n- ../../base\n' > "$D/kustomization.yaml"
  if [ $# -ge 3 ]; then
    printf 'images:\n- name: other/img\n  newName: other/img\n  newTag: v1-abcdef0\n- name: %s\n  newName: %s\n  newTag: %s%s%s\n' \
      "$2" "$2" "${4:-}" "$3" "${4:-}" >> "$D/kustomization.yaml"
  fi
}

# compare STATUS AHEAD_BY BEHIND_BY: a GitHub compare body. files[] carry their
# own "status" values, as the real API returns them.
compare() {
  printf '{"url":"u","base_commit":{"sha":"x","commit":{"message":"m"}},"status":"%s","ahead_by":%s,"behind_by":%s,"total_commits":%s,"commits":[],"files":[{"filename":"a","status":"modified"},{"filename":"b","status":"added"}]}' \
    "$1" "$2" "$3" "$2" > "$T/compare-body"
}

# run_notify: the step with its Argo placeholders filled and fixed paths moved
# into the sandbox. Sets OUT and RC; EDITS = overlays kustomize edited.
run_notify() {
  # /tmp/ first: the sandbox itself may live under /tmp, and a later rewrite
  # must not be rewritten again.
  sed -e "s#/tmp/#${T}/#g" \
      -e "s#{{workflow.parameters.project_name}}#proj#g" \
      -e "s#{{workflow.parameters.app_name}}#app1#g" \
      -e "s#{{inputs.parameters.image_tag}}#dev-v0.9.9-20260930-140000-$(printf '%s' "$BUILT" | cut -c1-7)#g" \
      -e "s#{{workflow.parameters.image_repo}}##g" \
      -e "s#{{workflow.parameters.deploy_image_repo}}#${IMAGE}#g" \
      -e "s#{{workflow.parameters.commit_sha}}#${BUILT}#g" \
      -e "s#{{workflow.parameters.repo_url}}#https://github.com/kaos-io/proj-app1.git#g" \
      -e "s#/usr/local/bin/#${T}/bin/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" \
      "$SRC" > "$T/notify.sh"
  OUT=$(cd "$T" && STUB_LOG_DIR="$T" PATH="$T/bin:$PATH" "${NOTIFY_SHELL:-sh}" "$T/notify.sh" 2>&1); RC=$?
  EDITS=$(cut -d' ' -f1 "$T/kustomize.log" | sort | tr '\n' ' ' | sed 's/ $//')
  PUSHED=$(grep -c '^push' "$T/git.log")
  COMPARES=$(grep -c 'api.github.com' "$T/wget.log")
}

# ── no guard input: exactly today's behaviour, no API call ───────────────────

new_case "$NEW_SHA"; overlay dev; run_notify
expect_eq "$RC/$EDITS/$PUSHED/$COMPARES" "0/dev/1/0" "no current tag: edit + push, no compare call"
expect_has "$(cat "$T/kustomize.log")" "edit set image ${IMAGE}=${IMAGE}:dev-v0.9.9-20260930-140000-6767e5c" "no current tag: sets this build's tag"

new_case "$NEW_SHA"; overlay dev other/img2 "$OLD_TAG"; run_notify
expect_eq "$RC/$EDITS/$PUSHED/$COMPARES" "0/dev/1/0" "only ANOTHER image carries a CI tag: edit, no compare call"

new_case "$NEW_SHA"; overlay dev "$IMAGE" latest; run_notify
expect_eq "$RC/$EDITS/$PUSHED/$COMPARES" "0/dev/1/0" "current tag not in CI form (latest): edit, no compare call"

new_case "$NEW_SHA"; overlay dev "$IMAGE" "v1.2.3-6767e5"; run_notify
expect_eq "$RC/$EDITS/$PUSHED/$COMPARES" "0/dev/1/0" "current tag ends in 6 hex chars, not a sha7: edit, no compare call"

new_case "$NEW_SHA"; overlay dev "$IMAGE" "$NEW_TAG"; run_notify
expect_eq "$RC/$EDITS/$PUSHED/$COMPARES" "0/dev/1/0" "same commit already deployed (rebuild): edit, no compare call"

# ── compare answers ───────────────────────────────────────────────────────────

new_case "$NEW_SHA"; overlay dev "$IMAGE" "$OLD_TAG"; compare ahead 1 0; run_notify
expect_eq "$RC/$EDITS/$PUSHED/$COMPARES" "0/dev/1/1" "built is AHEAD of deployed: edit + push"
expect_has "$(cat "$T/wget.log")" "https://api.github.com/repos/kaos-io/proj-app1/compare/97388a6...${NEW_SHA}?per_page=1" "compare runs deployed...built in the APP repo"
expect_has "$(cat "$T/wget.log")" "[Authorization: Bearer token]" "compare authenticates with the step's token"
expect_not_has "$OUT" "WARN" "ahead: no warning"

new_case "$NEW_SHA"; overlay dev "$IMAGE" "$OLD_TAG"; compare identical 0 0; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev/1" "identical: edit + push"

# The incident, replayed: 6767e5c deployed, a late build of 97388a6 arrives.
new_case "$OLD_SHA"; overlay dev "$IMAGE" "$NEW_TAG"; compare behind 0 1; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0//0" "built is BEHIND deployed (the incident): no edit, no push, exit 0"
expect_has "$OUT" "skip ${APP_DIR}/overlays/dev: 97388a6 is older than the deployed 6767e5c" "behind: logs the skip line"
expect_has "$OUT" "Nothing to deploy" "every overlay skipped: says there is nothing to deploy"
expect_not_has "$OUT" "No changes to commit" "every overlay skipped: exits before the commit path"

new_case "$OLD_SHA"; overlay dev "$IMAGE" "$NEW_TAG" '"'; compare behind 0 1; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0//0" "a quoted newTag is read too: behind still skips"

new_case "$NEW_SHA"; overlay dev "$IMAGE" "$OLD_TAG"; compare diverged 2 3; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev/1" "diverged: edit + push (unknown never blocks)"
expect_has "$OUT" "WARN: stale-deploy guard: 6767e5c and the deployed 97388a6 have diverged" "diverged: warns with the reason"

new_case "$NEW_SHA"; overlay dev "$IMAGE" "$OLD_TAG"; touch "$T/compare-fail"; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev/1" "compare API fails (non-2xx): edit + push"
expect_has "$OUT" "WARN: stale-deploy guard: cannot compare 97388a6...6767e5c in kaos-io/proj-app1" "API failure: warns with the reason"
expect_has "$OUT" "404" "API failure: the warning carries the HTTP error"

new_case "$NEW_SHA"; overlay dev "$IMAGE" "$OLD_TAG"; printf '<html>rate limited</html>' > "$T/compare-body"; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev/1" "unreadable compare body: edit + push"
expect_has "$OUT" "unreadable compare answer" "unreadable body: warns"

new_case "$OLD_SHA"; overlay dev "$IMAGE" "$NEW_TAG"; compare behind 1 1; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev/1" "behind but ahead_by != 0 (inconsistent): edit + push"
expect_has "$OUT" "says behind but ahead_by=1" "inconsistent behind: warns"

new_case "$OLD_SHA"; overlay dev "$IMAGE" "$NEW_TAG"
printf '{"status":"behind","ahead_by":0,"x":{"status":"ahead"}}' > "$T/compare-body"; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev/1" "a body naming two compare statuses is unreadable: edit + push"

# ── several overlays: each is judged on its own ──────────────────────────────

new_case "$OLD_SHA"; overlay dev "$IMAGE" "$NEW_TAG"; overlay dev-eu; compare behind 0 1; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0/dev-eu/1" "dev newer (skipped), dev-eu untagged (edited): push the one edit"
expect_has "$OUT" "skip ${APP_DIR}/overlays/dev:" "mixed: the skipped overlay is named"
expect_has "$OUT" "Updated 1 overlay(s)" "mixed: reports one updated overlay"

new_case "$OLD_SHA"; overlay dev "$IMAGE" "$NEW_TAG"; overlay dev-eu "$IMAGE" "$NEW_TAG"; compare behind 0 1; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0//0" "both overlays newer: nothing edited, nothing pushed"
expect_has "$OUT" "every dev overlay (2)" "both skipped: counts them"

# ── unchanged paths ───────────────────────────────────────────────────────────

new_case "$NEW_SHA"; run_notify
expect_eq "$RC/$EDITS/$PUSHED" "0//0" "no dev overlays at all: unchanged exit 0"
expect_has "$OUT" "No dev overlays found under ${APP_DIR}" "no overlays: unchanged message"

new_case "$NEW_SHA"; overlay dev; run_notify
expect_has "$(cat "$T/git.log")" "pull --rebase" "the pull --rebase before push is still there"

Q='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ci-build") | .spec.templates[] | select(.name == "gitops-notify")'
expect_eq "$(yq "$Q | .activeDeadlineSeconds" "$RENDERED")/$(yq "$Q | .retryStrategy.limit" "$RENDERED")" "600/2" "retry + deadline unchanged"
expect_eq "$(yq "$Q | .container.image" "$RENDERED")" "alpine/git:latest" "no new image"

echo
echo "stale-deploy: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
