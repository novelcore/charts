#!/usr/bin/env bash
# Tests for kaos PRD 738 F-20: no CI step persists the GitHub App token in a
# git checkout, and the build container gets no Kubernetes SA token.
#
# The token used to ride in clone URLs (https://x-access-token:TOKEN@github.com),
# which git stores as remote.origin.url in .git/config. /workspace/repo is the
# kaniko build context, so a Dockerfile `RUN cat .git/config` read a live org
# GitHub App token, and `COPY . .` baked it into a pushed image layer. Usage
# (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/git-token/run.sh
#
# Static checks run over the rendered chart; the clone steps are EXECUTED
# against a local bare repo with a realistic token. Needs helm, yq v4, jq, git.
# Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0

expect_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $3"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"
  fi
}

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }
TOKEN_VALUE="ghs_F20fakeToken0123456789abcdefABCDEFxyz"

# ── static: no token-bearing URL anywhere in the rendered chart ──────────────

URLS=$(grep -nE 'x-access-token:\$\{?[A-Za-z_]*\}?@|https://[^/" ]*\$\{?[A-Za-z_]*TOKEN[A-Za-z_]*\}?@' "$RENDERED" | head -5)
expect_eq "${URLS:-none}" "none" "no rendered script builds a token-bearing git URL"

# Every script that talks to a remote with git defines the gitAuth wrapper.
ALL_SCRIPTS=$(yq -o=json 'select(.kind == "WorkflowTemplate" or .kind == "ClusterWorkflowTemplate")' "$RENDERED" | jq -s -r '
  .[] | .metadata.name as $wf | .spec.templates[]
  | .name as $t
  | ([{n: "main", c: .container}] + [(.initContainers // [])[] | {n: .name, c: .}])[]
  | select(.c != null)
  | select(((.c.args // []) | join("\n")) | test("\\bgit\\b[^\\n]*\\b(clone|fetch|push|pull|ls-remote)\\b"))
  | "\($wf)/\($t)/\(.n) \(((.c.args // []) | join("\n")) | test("(?m)^git\\(\\) \\{"))"')
NO_WRAPPER=$(printf '%s\n' "$ALL_SCRIPTS" | awk '$2 != "true" {print $1}' | tr '\n' ' ')
expect_eq "${NO_WRAPPER:-none}" "none" "every step that runs a networked git command defines the gitAuth wrapper"
expect_eq "$(printf '%s\n' "$ALL_SCRIPTS" | grep -c true)" "14" "the wrapper covers all 14 networked git steps"

# ── executed: the clone steps leave no credential in the build context ───────

new_origin() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXXXX")
  printf '%s' "$TOKEN_VALUE" > "$T/token"
  git init -q --bare "$T/origin.git" && git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/dev
  git --git-dir="$T/origin.git" config uploadpack.allowReachableSHA1InWant true
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  ( cd "$T/seed" && git checkout -q -B dev && echo app > README.md && echo '# pipeline' > pipeline.py \
      && mkdir config && echo 'a: 1' > config/config.yaml && git add README.md pipeline.py config \
      && git -c user.name=t -c user.email=t@t commit -qm init && git push -q origin dev \
      && git tag dev-v0.1.0-20261001-120000 && git push -q origin --tags )
  SHA=$(git --git-dir="$T/origin.git" rev-parse refs/heads/dev)
  mkdir -p "$T/workspace"
}

script() {  # script WORKFLOW TEMPLATE [INIT_CONTAINER]
  if [ $# -ge 3 ]; then
    Q=".spec.templates[] | select(.name == \"$2\") | .initContainers[] | select(.name == \"$3\") | .args[0]"
  else
    Q=".spec.templates[] | select(.name == \"$2\") | .container.args[0]"
  fi
  yq "select(.metadata.name == \"$1\") | $Q" "$RENDERED" \
    | sed -e "s#/workspace/#$T/workspace/#g" \
          -e "s#/etc/github-token/token#$T/token#g" \
          -e "s#{{workflow.parameters.repo_url}}#file://$T/origin.git#g" \
          -e "s#{{workflow.parameters.branch}}#refs/heads/dev#g" \
          -e "s#{{workflow.parameters.commit_sha}}#${SHA}#g" \
          -e "s#{{inputs.parameters.step_name}}#step_a#g"
}

for case in "ci-build clone" "ci-rc-build clone" "ml-ci-build clone" "ml-ci-build build-push clone"; do
  set -- $case
  new_origin
  script "$@" > "$T/clone.sh"
  OUT=$(cd "$T" && sh "$T/clone.sh" 2>&1); RC=$?; [ "$RC" = 0 ] || printf "%s\n" "$OUT" | tail -5
  N="$1/$2${3:+/$3}"
  expect_eq "$RC" "0" "$N: exits 0"
  CFG=$(cat "$T/workspace/repo/.git/config" 2>/dev/null)
  case "$CFG" in
    *"$TOKEN_VALUE"*|*x-access-token*|*extraheader*) LEAK=leak ;;
    *) LEAK=clean ;;
  esac
  expect_eq "$LEAK" "clean" "$N: .git/config holds no token"
  expect_eq "$(git -C "$T/workspace/repo" config --get remote.origin.url)" "file://$T/origin.git" \
    "$N: origin is the plain repo URL"
  LEAKED_FILES=$(grep -rlF -- "$TOKEN_VALUE" "$T/workspace" 2>/dev/null | tr '\n' ' ')
  expect_eq "${LEAKED_FILES:-none}" "none" "$N: the token appears in no file of the build context"
done

# ci-build / ml-ci-build fetch tags in clone (the version step can no longer).
for wf in ci-build ml-ci-build; do
  new_origin
  script "$wf" clone > "$T/clone.sh"
  (cd "$T" && sh "$T/clone.sh" >/dev/null 2>&1)
  expect_eq "$(git -C "$T/workspace/repo" tag -l 'dev-v*')" "dev-v0.1.0-20261001-120000" "$wf/clone: tags fetched for the version step"
  expect_eq "$(script "$wf" version | grep -c 'git fetch')" "0" "$wf/version: no fetch from a credential-less checkout"
done

# ── the wrapper: header per process, nothing persisted ──────────────────────

AUTH_FNS="${BASE_TMP}/gitauth.sh"
yq 'select(.metadata.name == "ci-build") | .spec.templates[] | select(.name == "clone") | .container.args[0]' "$RENDERED" \
  | awk '/^git\(\) \{/ {on=1} on {print} on && /^}/ {n++; if (n == 2) exit}' > "$AUTH_FNS"
GIT_MINOR=$(git --version | sed -E 's/^git version ([0-9]+)\.([0-9]+).*/\1 \2/')
if [ "$(echo "$GIT_MINOR" | awk '{print ($1 > 2 || ($1 == 2 && $2 >= 31)) ? "yes" : "no"}')" = "yes" ]; then
  HDR=$(TOKEN="$TOKEN_VALUE" sh -c ". '$AUTH_FNS'; git config --get http.https://github.com/.extraheader")
  WANT="Authorization: Basic $(printf 'x-access-token:%s' "$TOKEN_VALUE" | base64 | tr -d '\n')"
  expect_eq "$HDR" "$WANT" "wrapper: git sees the token as a github.com Authorization header"
  HDR_AFTER=$(TOKEN="$TOKEN_VALUE" sh -c ". '$AUTH_FNS'; git config --get http.https://github.com/.extraheader >/dev/null; env | grep -c GIT_CONFIG_ || true")
  expect_eq "$HDR_AFTER" "0" "wrapper: nothing leaks into the calling shell's environment"
else
  echo "SKIP: git < 2.31 ignores GIT_CONFIG_COUNT (production images ship 2.45+)"
fi

# git_assert_no_token fails on every credential form.
for bad in "url = https://x-access-token:${TOKEN_VALUE}@github.com/acme/a.git" \
           "url = https://user:pw@github.com/acme/a.git" \
           "extraheader = AUTHORIZATION: basic Zm9v" \
           "url = https://github.com/acme/a.git?t=${TOKEN_VALUE}"; do
  R="${BASE_TMP}/assert"; rm -rf "$R"; mkdir -p "$R/.git"
  printf '[remote "origin"]\n\t%s\n' "$bad" > "$R/.git/config"
  OUT=$(TOKEN="$TOKEN_VALUE" sh -c ". '$AUTH_FNS'; git_assert_no_token '$R'; echo survived" 2>&1); RC=$?
  expect_eq "$RC" "1" "git_assert_no_token fails on: ${bad%%${TOKEN_VALUE}*}…"
done
printf '[remote "origin"]\n\turl = https://github.com/acme/a.git\n' > "$R/.git/config"
OUT=$(TOKEN="$TOKEN_VALUE" sh -c ". '$AUTH_FNS'; git_assert_no_token '$R'" 2>&1); RC=$?
expect_eq "$RC" "0" "git_assert_no_token passes a clean config"

# ── build pods: no SA token in the build container ──────────────────────────

for wf in ci-build ci-rc-build ml-ci-build; do
  P=$(yq "select(.metadata.name == \"$wf\") | .spec.templates[] | select(.name == \"build-push\") | .podSpecPatch" "$RENDERED")
  expect_eq "$(printf '%s' "$P" | yq '.automountServiceAccountToken')" "false" "$wf/build-push: automount off for the pod"
  expect_eq "$(printf '%s' "$P" | yq -o=json '[.initContainers[].name, .containers[].name] | join(",")' | tr -d '"')" "init,wait" \
    "$wf/build-push: the projected token is mounted into Argo's init and wait only"
  expect_eq "$(printf '%s' "$P" | yq '[.initContainers[], .containers[]] | map(.volumeMounts[] | select(.mountPath == "/var/run/secrets/kubernetes.io/serviceaccount")) | length')" "2" \
    "$wf/build-push: at the standard path, so argoexec finds it"
  expect_eq "$(printf '%s' "$P" | yq '.volumes[0].projected.sources[0].serviceAccountToken.path')" "token" \
    "$wf/build-push: a projected (short-lived) token, no Secret needed"
done
OFF=$(helm template t "$CHART" --set buildPods.isolateServiceAccountToken=false \
  | yq 'select(.metadata.name == "ci-build") | .spec.templates[] | select(.name == "build-push") | has("podSpecPatch")')
expect_eq "$OFF" "false" "buildPods.isolateServiceAccountToken=false restores the default mount"

# ── the chart's Role grants no Secret access ────────────────────────────────

SECRET_RULES=$(yq -o=json 'select(.kind == "Role")' "$RENDERED" | jq -s -c '[.[].rules[] | select(.resources | index("secrets") or index("*"))]')
expect_eq "$SECRET_RULES" "[]" "no chart Role grants access to Secrets"

echo "git-token: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
