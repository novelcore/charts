#!/usr/bin/env bash
# Tests for ml-ci-reconcile as the event-driven build trigger
# (kubecore-operator#1439) and for the app repo it polls (#1347). Usage (from
# the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/reconcile-trigger/run.sh
#
# The k8smlapp composition fires ml-ci-reconcile with force=true at app creation
# and on every platform-context change; the hourly CronWorkflow (force=false) is
# only the backstop. In force mode "not yet" must retry (exit 3), never skip:
# there is no next poll to catch it. The scripts under test are EXECUTED, not
# grepped: check-drift is extracted from the rendered ml-ci-reconcile and run
# against stub kubectl/curl. Needs helm, yq v4, jq.
# Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

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

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

# ── CI no longer writes the app repo's dataset config ───────────────────────
# The composition owns .kubecore/dataset-config.yaml; a second writer's
# chore(dataset) commit re-triggered builds (charts#158).
ML_SCRIPTS=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | .container.args[0] // .script.source // ""' "$RENDERED")
expect_eq "$(printf '%s' "$ML_SCRIPTS" | grep -v '^[[:space:]]*#' | grep -c 'dataset-config')" "0" \
  "no ml-ci-build step writes .kubecore/dataset-config.yaml"

DRIFT_SRC="${BASE_TMP}/check-drift.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .container.args[0]' "$RENDERED" > "$DRIFT_SRC"

# new_case FORCE WORKFLOWS_JSON HEAD CM: a sandbox with stub kubectl/curl.
#   WORKFLOWS_JSON  what `kubectl get workflows` returns
#   HEAD            the app repo's HEAD sha, or "" when the repo is not there
#   CM              "built" (last-built-sha = HEAD), "unbuilt" (no baseline yet),
#                   or "absent" (NotFound; gitops already targets ml-proj)
run_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX")
  mkdir -p "$T/bin"
  printf 'token' > "$T/token"
  case "$4" in
    built)   CMJ="{\"data\":{\"last-built-sha\":\"${HEAD_SHA}\"}}" ;;
    unbuilt) CMJ='{"data":{}}' ;;
    *)       CMJ="" ;;
  esac
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get workflows"*) printf '%s' '$2' ;;
  *"get configmap"*"pipeline-context"*) echo 'Error from server (NotFound)'; exit 1 ;;
  *"get configmap"*)
    if [ -z '$CMJ' ]; then echo 'Error from server (NotFound): configmaps "app1-pipeline-images" not found'; exit 1; fi
    printf '%s' '$CMJ' ;;
  *) echo "stub kubectl: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$T/curl.log"
case "\$*" in
  *"/commits/"*) [ -n '$3' ] || exit 22; printf '{"sha":"%s"}' '$3' ;;
  *"pipeline-images.yaml"*) printf 'metadata:\n  namespace: ml-proj\n' ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$T/bin/kubectl" "$T/bin/curl"
  sed -e "s#{{workflow.namespace}}#ci#g" \
      -e "s#{{workflow.parameters.force}}#$1#g" \
      -e "s#{{workflow.parameters.app_name}}#app1#g" \
      -e "s#{{workflow.parameters.project_name}}#proj#g" \
      -e "s#{{workflow.parameters.branch}}#dev#g" \
      -e "s#{{workflow.parameters.ci_namespace}}#ci#g" \
      -e "s#{{workflow.parameters.ml_namespace}}##g" \
      -e "s#{{workflow.parameters.gitops_repository}}#proj#g" \
      -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.workflow_template_path}}#kubeapps/app1/main/workflow-template.yaml#g" \
      -e "s#{{workflow.parameters.repo_url}}##g" \
      -e "s#/tmp/#${T}/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" "$DRIFT_SRC" > "$T/check-drift.sh"
  OUT=$(PATH="$T/bin:$PATH" bash "$T/check-drift.sh" 2>&1); RC=$?
  NEEDS=$(cat "$T/needs_build" 2>/dev/null || echo "<unset>")
  SHA=$(cat "$T/head_sha" 2>/dev/null || echo "<unset>")
}

IDLE='{"items": []}'
BUSY='{"items": [{"metadata": {"name": "ml-ci-build-x"}, "status": {"phase": "Running"},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app1"}]}}}]}'

# ── the app repo it polls (#1347) ────────────────────────────────────────────
run_case false "$IDLE" "" built
expect_has "$OUT" "polling acme/proj-app1@dev" "reconciler polls the app repo in the chart's org"
expect_has "$(cat "$T/curl.log" 2>/dev/null)" "repos/acme/proj-app1/commits/dev" "reconciler reads HEAD from the chart's org"
SUBMIT_URL=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(has("resource")) | .resource.manifest' "$RENDERED" \
  | yq '.. | select(tag == "!!map" and .name == "repo_url") | .value')
expect_eq "$SUBMIT_URL" "https://github.com/acme/{{workflow.parameters.project_name}}-{{workflow.parameters.app_name}}.git" \
  "reconcile-submitted build clones the app repo from the chart's org"

# ── backstop (force=false): unchanged ────────────────────────────────────────
expect_eq "$RC/$NEEDS" "0/false" "backstop, repo unreadable: skips (exit 0)"
run_case false "$BUSY" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "backstop, build in flight: skips"
run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, HEAD built, nothing drifted: no build"
run_case false "$IDLE" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "backstop, HEAD never built: builds it"

# ── force=true: the event-driven trigger ─────────────────────────────────────
run_case true "$IDLE" "" built
expect_eq "$RC" "3" "force, app repo not created yet: retries (exit 3)"
run_case true "$BUSY" "$HEAD_SHA" built
expect_eq "$RC" "3" "force, build in flight: waits for it (exit 3), never drops the trigger"
run_case true "$IDLE" "$HEAD_SHA" absent
expect_eq "$RC" "3" "force, pipeline-images still syncing: retries (exit 3)"
run_case true "$IDLE" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "force, new app: builds HEAD"
run_case true "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "force, HEAD already built (context changed): re-renders anyway"

RETRY=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .retryStrategy.expression' "$RENDERED")
expect_eq "$RETRY" "asInt(lastRetry.exitCode) == 3" "check-drift retries exactly the force-mode 'not yet' (exit 3)"
FORCE_DEFAULT=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.arguments.parameters[] | select(.name == "force") | .value' "$RENDERED")
expect_eq "$FORCE_DEFAULT" "false" "force defaults to false (CronWorkflows rendered before it keep the backstop)"

echo "reconcile-trigger: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
