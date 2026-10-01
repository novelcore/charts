#!/usr/bin/env bash
# Tests for the dataset CLI config write (kubecore-operator#1347): Hera apps get
# .kubecore/dataset-config.yaml (it was written only by the kubeline render-wft,
# so no Hera app ever had it), and ml-ci-reconcile polls the app repo in the
# chart's GitHub org (it was hardcoded to novelcore, so in any other org it
# never ran). Usage (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/dataset-config/run.sh
#
# The scripts under test are EXECUTED, not grepped: the write is extracted from
# the rendered hera-enhance-commit and run against a local bare repo standing in
# for the app repo; check-drift is extracted from ml-ci-reconcile and run
# against stub kubectl/curl. Needs helm, yq v4, jq, git, python3 + PyYAML.
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
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}
expect_lacks() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

# ── hera-enhance-commit writes .kubecore/dataset-config.yaml ────────────────

HERA_SRC="${BASE_TMP}/hera.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.args[0]' \
  "$RENDERED" | awk '/Dataset CLI config \(kubecore-operator#1347\)/ {on=1}
                     on {print}
                     on && /skipping dataset-config write/ {getline; print; exit}' > "$HERA_SRC"

expect_lacks "$(grep -v '^[[:space:]]*#' "$HERA_SRC")" "/workspace/repo" \
  "hera write never touches /workspace/repo (untrusted checkout) in the token-holding step"

CLI_CTX='    lakefs:
      externalUrl: https://lakefs-proj.example
      repository: proj
      cli:
        oidcIssuer: https://access.example
        oidcClientId: "393185060682989570"
        oidcProjectId: "391662738398511106"'

# new_case CONTEXT: an app repo (bare "origin" with one commit on dev) and the
# gitops pipeline-context ConfigMap carrying CONTEXT under data.context.yaml.
new_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX")
  # No `git init -b`: the CI runner's git predates it (< 2.28).
  git init -q --bare "$T/origin.git" && git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/dev
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  ( cd "$T/seed" && git checkout -q -b dev && echo app > README.md && git add README.md \
      && git -c user.name=t -c user.email=t@t commit -qm init && git push -q origin dev )
  printf 'apiVersion: v1\nkind: ConfigMap\ndata:\n  context.yaml: |\n    namespace: proj-ml\n%s\n' "$1" \
    > "$T/pipeline-context.yaml"
}

run_write() {
  {
    echo 'set -e'
    echo "TOKEN=token APP_NAME=app1 CONTEXT_PATH=$T/pipeline-context.yaml"
    sed -e "s#{{workflow.parameters.project_name}}#proj#g" \
        -e "s#{{workflow.parameters.branch}}#refs/heads/dev#g" \
        -e "s#{{workflow.parameters.repo_url}}#$T/origin.git#g" \
        -e "s#/tmp/apprepo#$T/apprepo#g" "$HERA_SRC"
  } > "$T/write.sh"
  # Production runs this under python:3.12-slim's /bin/sh (dash).
  OUT=$(sh "$T/write.sh" 2>&1); RC=$?
  PUSHED=$(git --git-dir="$T/origin.git" show dev:.kubecore/dataset-config.yaml 2>/dev/null || echo "<absent>")
  COMMITS=$(git --git-dir="$T/origin.git" rev-list --count dev)
}

new_case "$CLI_CTX"; run_write
expect_eq "$RC" "0" "CLI app provisioned: write exits 0"
expect_has "$OUT" "pushed .kubecore/dataset-config.yaml" "CLI app provisioned: reports the push"
expect_has "$PUSHED" "oidcClientId: '393185060682989570'" "CLI app provisioned: client_id reaches the app repo"
expect_has "$PUSHED" "oidcIssuer: https://access.example" "CLI app provisioned: issuer reaches the app repo"
expect_has "$PUSHED" "oidcProjectId: '391662738398511106'" "CLI app provisioned: audience project reaches the app repo"
expect_has "$PUSHED" "lakefsUrl: https://lakefs-proj.example" "CLI app provisioned: lakeFS URL reaches the app repo"
expect_eq "$COMMITS" "2" "CLI app provisioned: exactly one commit added"

run_write
expect_has "$OUT" "already current" "re-render with the same context: no-op"
expect_eq "$COMMITS" "2" "re-render with the same context: no new commit"

new_case '    lakefs:
      externalUrl: https://lakefs-proj.example
      repository: proj'
run_write
expect_has "$PUSHED" "lakefsUrl: https://lakefs-proj.example" "no CLI app yet: lakeFS settings still written"
expect_lacks "$PUSHED" "oidcClientId" "no CLI app yet: no half-written login settings"

new_case '    lakefs:
      repository: proj'
run_write
expect_eq "$RC" "0" "no lakeFS URL yet: write exits 0"
expect_has "$OUT" "skipping dataset-config write" "no lakeFS URL yet: skips loudly"
expect_eq "$PUSHED" "<absent>" "no lakeFS URL yet: nothing pushed"

# ── ml-ci-reconcile polls the app repo in the chart's org ───────────────────

T=$(mktemp -d "${BASE_TMP}/case-XXXX")
mkdir -p "$T/bin"
printf 'token' > "$T/token"
cat > "$T/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"get workflows"*) printf '{"items": []}' ;;
  *) echo "stub kubectl: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/curl.log"
exit 22
EOF
chmod +x "$T/bin/kubectl" "$T/bin/curl"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .container.args[0]' "$RENDERED" \
  | sed -e "s#{{workflow.namespace}}#ci#g" \
        -e "s#{{workflow.parameters.app_name}}#app1#g" \
        -e "s#{{workflow.parameters.project_name}}#proj#g" \
        -e "s#{{workflow.parameters.branch}}#dev#g" \
        -e "s#{{workflow.parameters.ci_namespace}}#ci#g" \
        -e "s#{{workflow.parameters.gitops_repository}}#proj#g" \
        -e "s#{{workflow.parameters.repo_url}}##g" \
        -e "s#/tmp/#${T}/#g" \
        -e "s#/etc/github-token/token#${T}/token#g" > "$T/check-drift.sh"
OUT=$(PATH="$T/bin:$PATH" bash "$T/check-drift.sh" 2>&1)
expect_has "$OUT" "polling acme/proj-app1@dev" "reconciler polls the app repo in the chart's org"
expect_has "$(cat "$T/curl.log" 2>/dev/null)" "repos/acme/proj-app1/commits/dev" "reconciler reads HEAD from the chart's org"

# The submitted ml-ci-build is an embedded resource manifest (a string).
SUBMIT_URL=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(has("resource")) | .resource.manifest' "$RENDERED" \
  | yq '.. | select(tag == "!!map" and .name == "repo_url") | .value')
expect_eq "$SUBMIT_URL" "https://github.com/acme/{{workflow.parameters.project_name}}-{{workflow.parameters.app_name}}.git" \
  "reconcile-submitted build clones the app repo from the chart's org"

echo "dataset-config: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
