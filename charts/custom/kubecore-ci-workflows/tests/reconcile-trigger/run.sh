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
# against stub kubectl/curl. Needs helm, yq v4, jq, python3.
# Exit status is the number of failed assertions.
#
# PRD novelcore/kaos#1283 D-05: DATASET DRIFT (the hourly backstop re-renders when the catalog's
# datasets differ from the ones the live pipeline was rendered with) and the dataset_event run
# (kaos-lake's release event: a build in flight is waited out, an unrecorded pipeline re-renders)
# are exercised against a local fake catalog; so is the fan-out that starts those runs.
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
trap 'rm -rf "$BASE_TMP"; kill ${CATALOG_PID:-0} ${BROKEN_PID:-0} 2>/dev/null' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

# ── CI no longer writes the app repo's dataset config ───────────────────────
# The composition owns .kubecore/dataset-config.yaml; a second writer's
# chore(dataset) commit re-triggered builds (charts#158).
ML_SCRIPTS=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | .container.args[0] // .script.source // ""' "$RENDERED")
expect_eq "$(printf '%s' "$ML_SCRIPTS" | grep -v '^[[:space:]]*#' | grep -c 'dataset-config')" "0" \
  "no ml-ci-build step writes .kubecore/dataset-config.yaml"

# charts#158: a build that changes no step must still record last-built-sha, or
# the backstop rebuilds the same SHA. patch-images records it; it must run on
# every non-chore build, not only when a step image changed.
PATCH_WHEN=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "ml-ci-run") | .steps[][] | select(.name == "patch-images") | .when' "$RENDERED")
expect_eq "$PATCH_WHEN" "{{workflow.parameters.branch_type}} != chore && ({{inputs.parameters.locked}} == true || {{steps.detect-steps.outputs.parameters.has_changes}} != true)" \
  "patch-images (records last-built-sha) runs on every non-chore build (an unlocked render-only run records only when it built nothing)"

DRIFT_SRC="${BASE_TMP}/check-drift.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .container.args[0]' "$RENDERED" > "$DRIFT_SRC"

# new_case FORCE WORKFLOWS_JSON HEAD CM: a sandbox with stub kubectl/curl.
#   WORKFLOWS_JSON  what `kubectl get workflows` returns
#   HEAD            the app repo's HEAD sha, or "" when the repo is not there
#   CM              "built" (last-built-sha = HEAD), "unbuilt" (no baseline yet),
#                   or "absent" (NotFound; gitops already targets ml-proj)
GITOPS_CTX='kind: ConfigMap  # gitops pipeline-context.yaml, raw'
CTX_SHA=$(printf '%s' "$GITOPS_CTX" | sha256sum | cut -c1-64)

run_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX")
  mkdir -p "$T/bin"
  printf 'token' > "$T/token"
  printf 'pod-token' > "$T/lake-token"
  case "$4" in
    built)   CMJ="{\"data\":{\"last-built-sha\":\"${HEAD_SHA}\",\"dataset-sha\":\"${DS_CM:-}\"}}" ;;
    unbuilt) CMJ='{"data":{}}' ;;
    *)       CMJ="" ;;
  esac
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get workflows"*) printf '%s' '$2' ;;
  *"get configmap"*"pipeline-context"*)
    if [ -n '${CTX_YAML:-}' ]; then printf '%s' '${CTX_YAML:-}'; exit 0; fi
    echo 'Error from server (NotFound)'; exit 1 ;;
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
  *"pipeline-images.yaml"*) printf 'metadata:\n  namespace: ml-proj\ndata:\n  dataset-sha: %s\n' '${GITOPS_DS:-}'
    [ -z '${GITOPS_KL:-}' ] || printf '  kaos-lib-package: "%s"\n' '${GITOPS_KL:-}' ;;
  *"pipeline-context.yaml"*) [ -z '${CTX_GITOPS_OFF:-}' ] || exit 22; printf '%s' '$GITOPS_CTX' ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$T/bin/kubectl" "$T/bin/curl"
  sed -e "s#{{workflow.namespace}}#ci#g" \
      -e "s#{{inputs.parameters.mode}}#${MODE:-decide}#g" \
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
      -e "s#{{workflow.parameters.dataset_event}}#${DATASET_EVENT:-false}#g" \
      -e "s#/tmp/#${T}/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" \
      -e "s#/var/run/secrets/kaos-lake/token#${T}/lake-token#g" "$DRIFT_SRC" > "$T/check-drift.sh"
  OUT=$(PATH="$T/bin:$PATH" bash "$T/check-drift.sh" 2>&1); RC=$?
  NEEDS=$(cat "$T/needs_build" 2>/dev/null || echo "<unset>")
  SHA=$(cat "$T/head_sha" 2>/dev/null || echo "<unset>")
}

QUEUED_OTHER='{"items": [{"metadata": {"name": "ml-ci-build-q"}, "status": {"phase": "Pending"},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app1"}, {"name": "commit_sha", "value": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}}}]}'
QUEUED_HEAD='{"items": [{"metadata": {"name": "ml-ci-build-q"}, "status": {"phase": "Pending"},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app1"}, {"name": "commit_sha", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}}]}'
# ml-ci-build takes its lock on a template AFTER a probe: the workflow is Running and a node is Pending on the lock.
QUEUED_ON_LOCK='{"items": [{"metadata": {"name": "ml-ci-build-q"}, "status": {"phase": "Running", "nodes": {"n1": {"phase": "Pending", "message": "Waiting for ci/Mutex/app1-build lock. Lock status: 0/1"}}},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app1"}, {"name": "commit_sha", "value": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]}}}]}'
QUEUED_ON_LOCK_HEAD='{"items": [{"metadata": {"name": "ml-ci-build-q"}, "status": {"phase": "Running", "nodes": {"n1": {"phase": "Pending", "message": "Waiting for ci/Mutex/app1-build lock. Lock status: 0/1"}}},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app1"}, {"name": "commit_sha", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}}]}'
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
# A build QUEUED on the app's lock (phase Pending) is not "in flight": the sync
# holds that lock, so it runs first and the queued build runs after it.
run_case true "$QUEUED_OTHER" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "force, a build of another commit is queued behind us: decides now (no exit 3)"
run_case true "$QUEUED_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "force, a build of HEAD is already queued: submits nothing (no duplicate)"
expect_has "$OUT" "already queues a build of HEAD" "force, queued build of HEAD: says why"
run_case false "$QUEUED_OTHER" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "backstop, a build is queued: still skips (no stacking, kubecore-operator#872)"
# The same queue as a RUNNING workflow whose lock node is Pending (the build probes, then takes the lock):
run_case true "$QUEUED_ON_LOCK" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "force, a build waiting on the lock (workflow Running): is queued, not running: decides now (no deadlock)"
run_case true "$QUEUED_ON_LOCK_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "force, a build of HEAD waiting on the lock: submits nothing (no duplicate)"
run_case false "$QUEUED_ON_LOCK" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "backstop, a build waiting on the lock: still skips"
# await mode (the unlocked wait for non-build inputs) ignores a running build.
MODE=await run_case true "$BUSY" "$HEAD_SHA" unbuilt
expect_eq "$RC" "0" "await mode, build running: does not wait on it (decide mode's lock does)"
# Outputs exist on a failing "not yet" exit too (no "cannot save parameter").
run_case true "$IDLE" "" built
expect_eq "$RC/$NEEDS/$SHA" "3/false/" "force, not yet: exit 3 still writes needs_build=false and an empty head_sha"
run_case true "$IDLE" "$HEAD_SHA" absent
expect_eq "$RC" "3" "force, pipeline-images still syncing: retries (exit 3)"
run_case true "$IDLE" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "force, new app: builds HEAD"
run_case true "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "force, HEAD already built (context changed): re-renders anyway"

# The trigger names no context (an operator older than this chart still passes a hash, nothing reads it): a
# forced run for a built HEAD whose gitops context is newer or older than the trigger's never waits on it.
CTX_GITOPS_OFF=1 run_case true "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/true" "force, the gitops context cannot be read: unknown never waits, builds"

# ── force=true, the app's OWN kaos-lib pin (PRD novelcore/kaos#1911) ──────────
# The operator writes kaosLib.pinned: true into the gitops context only for spec.ml.kaosLib. The forced run
# (fired when the context changes) then rebuilds the stale images at once; a platform-wide move (no mark) stays
# with the hourly poll's pacing. Exhaustive cases (idle apps, attempt guard, queues): tests/kaos-lib.
PIN_CTX=$(printf 'kaosLib:\n  spec: "kaos-lib==0.5.1"\n  version: "0.5.1"\n  pinned: true\n')
PLATFORM_CTX=$(printf 'kaosLib:\n  spec: "kaos-lib==0.5.1"\n  version: "0.5.1"\n')
PIN_REF=$(printf '%s' "kaos-lib==0.5.1" | sha256sum | cut -c1-12)
GITOPS_CTX="$PIN_CTX" GITOPS_KL="kaos-lib==0.5.0" run_case true "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS/$(cat "$T/kaos_lib_ref" 2>/dev/null)" "0/true/$PIN_REF" "force, the app pins another kaos-lib than its images have: rebuilds now (kaos_lib_ref set)"
expect_has "$OUT" "KAOS-LIB PIN" "force, pin: says why"
GITOPS_CTX="$PIN_CTX" GITOPS_KL="kaos-lib==0.5.1" run_case true "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$(cat "$T/kaos_lib_ref" 2>/dev/null)" "0/" "force, the app's images already have its pin: no kaos-lib rebuild"
GITOPS_CTX="$PLATFORM_CTX" GITOPS_KL="kaos-lib==0.5.0" run_case true "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$(cat "$T/kaos_lib_ref" 2>/dev/null)" "0/" "force, the platform's own kaos-lib moved (no pin mark): the forced run does not rebuild it (hourly pacing)"
GITOPS_CTX="$PIN_CTX" GITOPS_KL="kaos-lib==0.5.0" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$(cat "$T/kaos_lib_ref" 2>/dev/null)" "" "backstop (not forced): a pin mark changes nothing in the hourly poll's own path (its use-based pacing)"

RETRY=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .retryStrategy.expression' "$RENDERED")
expect_eq "$RETRY" "asInt(lastRetry.exitCode) == 3 || asInt(lastRetry.exitCode) == 137" "check-drift retries the force-mode not-yet (3) and a killed pod (137)"
FORCE_DEFAULT=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.arguments.parameters[] | select(.name == "force") | .value' "$RENDERED")
expect_eq "$FORCE_DEFAULT" "false" "force defaults to false (CronWorkflows rendered before it keep the backstop)"

# ── DATASET DRIFT (PRD novelcore/kaos#1283 D-05) ─────────────────────────────
# The render records a digest of the dataset choices it offered (dataset-sha);
# the backstop compares it with the catalog now.
WORK="${BASE_TMP}/catalog"; mkdir -p "$WORK"
cat > "$WORK/catalog.py" <<'PY'
import http.server, json, sys
BODY = {"datasets": [
    {"name": "dataset-cars", "versions": [{"tag": "v2", "commit": "c2"}, {"tag": "v1", "commit": "c1"}]},
    {"name": "dataset-default", "default": True, "versions": [{"tag": "v3", "commit": "c3"}]},
]}
BROKEN = sys.argv[2] == "broken"
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = (not BROKEN) and self.path == "/kaos/v1/catalog" and self.headers.get("Authorization") == "Bearer pod-token"
        self.send_response(200 if ok else (503 if BROKEN else 401))
        self.end_headers()
        self.wfile.write(json.dumps(BODY if ok else {"message": "no"}).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/catalog.py" 18921 ok & CATALOG_PID=$!
python3 "$WORK/catalog.py" 18922 broken & BROKEN_PID=$!
sleep 1
# What a render of that catalog records: sha256 of the sorted choices, one per line.
DS_NOW=$(python3 -c "import hashlib; print(hashlib.sha256('\n'.join(sorted(['dataset-default@v3','dataset-default@latest','dataset-cars@v2','dataset-cars@v1','dataset-cars@latest'])).encode()).hexdigest())")
ctx_for() { printf 'lakefs:\n  endpoint: http://127.0.0.1:%s/\ncomputeClasses:\n' "$1"; }
OLD_DS=1111111111111111111111111111111111111111111111111111111111111111

CTX_YAML=$(ctx_for 18921)
DS_CM="$OLD_DS" GITOPS_DS="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/true" "backstop, datasets differ from the render's: builds (re-renders)"
expect_has "$OUT" "reconcile: DATASET DRIFT" "and says DATASET DRIFT"

DS_CM="$DS_NOW" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, datasets as rendered: no build"
expect_has "$OUT" "datasets in sync" "and says so"

DS_CM="$OLD_DS" GITOPS_DS="$DS_NOW" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, gitops already carries a render for the catalog (ArgoCD pending): no second build"
expect_has "$OUT" "waiting for ArgoCD" "and says why"

DS_CM=none run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, a pipeline without a dataset parameter: not applicable"

DS_CM="" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, a pipeline rendered before dataset-sha existed: unknown is no drift"

CTX_YAML=$(ctx_for 18922)
DS_CM="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, catalog answers 503: no drift, never an error"
expect_has "$OUT" "dataset drift unknown" "and says it is unknown"

CTX_YAML=$(ctx_for 1)
DS_CM="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, catalog unreachable: no drift, never an error"

CTX_YAML="computeClasses:"
DS_CM="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "backstop, no lakeFS endpoint in the context: no drift"

# A drifted commit still builds; the dataset check only adds a reason.
CTX_YAML=$(ctx_for 18921)
DS_CM="$DS_NOW" run_case false "$IDLE" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/true" "backstop, HEAD never built and datasets in sync: still builds"

# ── dataset_event: kaos-lake's release event ─────────────────────────────────
DATASET_EVENT=true
DS_CM="$OLD_DS" GITOPS_DS="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/true" "event, datasets differ: re-renders"
expect_has "$OUT" "reconcile: DATASET DRIFT" "event: says DATASET DRIFT"
DS_CM="$DS_NOW" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "event, datasets unchanged (another project's release): no build"
DS_CM="" GITOPS_DS="" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/true" "event, a pipeline that never recorded its datasets: re-renders once (records them)"
DS_CM=none run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "event, a pipeline without a dataset parameter: nothing"
DS_CM="$OLD_DS" run_case false "$BUSY" "$HEAD_SHA" built
expect_eq "$RC" "3" "event, a build in flight (its render may predate the release): waits (exit 3), never drops it"
DS_CM="$OLD_DS" run_case false "$QUEUED_HEAD" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "event, dataset drift but a build of HEAD is already queued: submits nothing (it renders from the current catalog when it starts)"
DS_CM="$OLD_DS" run_case false "$QUEUED_OTHER" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "event, dataset drift and only a build of another commit queued: re-renders HEAD"
run_case false "$IDLE" "" built
expect_eq "$RC/$NEEDS" "0/false" "event, app repo unreadable: skips like the poll (the hourly poll catches up)"
CTX_YAML=$(ctx_for 18922)
DS_CM="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "3/false" "event, catalog answers 503 (after its retries): not yet, exit 3 so Argo retries; the event is not dropped"
expect_has "$OUT" "dataset catalog not read" "event, unreadable catalog: says so"
expect_has "$OUT" "retrying" "event, unreadable catalog: says it retries"
CTX_YAML=$(ctx_for 1)
DS_CM="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "3/false" "event, catalog unreachable: not yet (exit 3)"
unset DATASET_EVENT
CTX_YAML=$(ctx_for 18922)
DS_CM="$OLD_DS" run_case false "$IDLE" "$HEAD_SHA" built
expect_eq "$RC/$NEEDS" "0/false" "hourly poll, catalog answers 503: no drift, no build, exit 0 as before"
expect_has "$OUT" "dataset drift unknown" "hourly poll, unreadable catalog: says it is unknown"
unset DATASET_EVENT CTX_YAML DS_CM GITOPS_DS

DE_DEFAULT=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.arguments.parameters[] | select(.name == "dataset_event") | .value' "$RENDERED")
expect_eq "$DE_DEFAULT" "false" "dataset_event defaults to false (the CronWorkflow is the plain backstop)"
LAKE_AUD=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .volumes[] | select(.name == "kaos-lake-token") | .projected.sources[0].serviceAccountToken.audience' "$RENDERED")
expect_eq "$LAKE_AUD" "kaos-lake" "check-drift mounts a kaos-lake audience token for the catalog"

# ── ml-ci-dataset-release: the fan-out kaos-lake's event starts ──────────────
FANOUT_SRC="${BASE_TMP}/fanout.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-dataset-release")
    | .spec.templates[] | select(.name == "fan-out") | .container.args[0]' "$RENDERED" > "$FANOUT_SRC"
expect_eq "$(test -s "$FANOUT_SRC" && echo yes)" "yes" "ml-ci-dataset-release has a fan-out step"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-dataset-release") | .spec.serviceAccountName' "$RENDERED")" \
  "dataset-release-sa" "the template pins its own account (an absent serviceAccountName in a submitted Workflow cannot fall back to default)"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-dataset-release") | .spec.synchronization.mutexes[0].name' "$RENDERED")" \
  "dataset-release" "at most one fan-out at a time"

# fanout_case CRONS_JSON: a sandbox with stub kubectl; jq is real. $T/created holds every
# Workflow the fan-out created.
fanout_case() {
  T=$(mktemp -d "${BASE_TMP}/fan-XXXX"); mkdir -p "$T/bin"
  printf '%s' "$1" > "$T/crons.json"
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get cronworkflows"*) [ -z "\${CRONS_FAIL:-}" ] || { echo forbidden >&2; exit 1; }; cat "$T/crons.json" ;;
  *"create -n ci -f -"*) cat >> "$T/created" ; echo >> "$T/created" ;;
  *) echo "stub kubectl: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  chmod +x "$T/bin/kubectl"
  sed -e "s#{{workflow.namespace}}#ci#g" "$FANOUT_SRC" > "$T/fanout.sh"
  OUT=$(PATH="$T/bin:$PATH" bash "$T/fanout.sh" 2>&1); RC=$?
}
cron() { # NAME TEMPLATE [SUSPEND]
  printf '{"metadata":{"name":"%s-ci-reconciler","labels":{"platform.kubecore.io/app":"%s"}},"spec":{"suspend":%s,"workflowSpec":{"serviceAccountName":"operate-workflow-sa","workflowTemplateRef":{"name":"%s","clusterScope":true},"arguments":{"parameters":[{"name":"app_name","value":"%s"},{"name":"dataset_event","value":"false"}]}}}}' "$1" "$1" "${3:-false}" "$2" "$1"
}
fanout_case "{\"items\":[$(cron mlapp ml-ci-reconcile),$(cron svcapp ci-reconcile),$(cron paused ml-ci-reconcile true),$(cron other ml-ci-reconcile)]}"
expect_eq "$RC" "0" "fan-out succeeds"
expect_eq "$(jq -r '.metadata.labels["platform.kubecore.io/app"]' "$T/created" | grep -v '^$' | sort | tr '\n' ' ')" "mlapp other " \
  "only the project's running ML apps get a dataset check (not a service app's reconciler, not a paused one)"
expect_eq "$(jq -r '.spec.arguments.parameters[] | select(.name=="dataset_event") | .value' "$T/created" | sort -u)" "true" \
  "each check runs ml-ci-reconcile with dataset_event=true"
expect_eq "$(jq -r '.spec.workflowTemplateRef.name' "$T/created" | sort -u)" "ml-ci-reconcile" "from the app's own reconciler spec"
# F-26 (Strict templateReferencing): the Workflow carries none of serviceAccountName, volumes or
# synchronization, whatever the cron spec had (this fixture's cron has them). ml-ci-reconcile owns
# the account and the token volume, and its decide-and-submit holds the {app}-build mutex that
# serialises two events for one app (tests/strict-references/run.sh proves it).
expect_eq "$(jq -r '.spec | keys | join(",")' "$T/created" | sort -u)" "arguments,ttlStrategy,workflowTemplateRef" \
  "only workflowTemplateRef, arguments and ttlStrategy: no serviceAccountName, volumes or own mutex"
expect_eq "$(jq -r '.spec.arguments.parameters[] | select(.name=="app_name") | .value' "$T/created" | sort | tr '\n' ' ')" "mlapp other " \
  "the reconciler's own parameters are kept"

fanout_case '{"items":[]}'
expect_eq "$RC" "0" "a project with no ML app: no error"
expect_eq "$(test -e "$T/created" && echo created || echo none)" "none" "and nothing is created"
fanout_case "{\"items\":[$(cron svcapp ci-reconcile)]}"
expect_eq "$RC/$(test -e "$T/created" && echo created || echo none)" "0/none" "only service apps: nothing, no error"
CRONS_FAIL=1 fanout_case '{"items":[]}'
expect_eq "$RC" "1" "an unreadable cluster fails the Workflow loudly (the hourly poll catches up)"

# ── a build of the same commit in flight is never doubled (PRD novelcore/kaos#1911, chart 0.17.3) ──
# live: one commit got ten ml-ci-build-reconciled-* in 55 minutes while its push build was queued.
DATASET_EVENT=true run_case false "$QUEUED_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "event, HEAD never recorded but its push build is queued: submits nothing"
expect_has "$OUT" "a build of aaaaaaa is already queued or running" "event, queued build of HEAD: says why"
DATASET_EVENT=true run_case false "$QUEUED_ON_LOCK_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "event, a build of HEAD waiting on the lock (workflow Running): submits nothing"
DATASET_EVENT=true run_case false "$QUEUED_OTHER" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "event, only a build of another commit queued: builds HEAD"
DATASET_EVENT=true run_case false "$IDLE" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "event, nothing in flight, HEAD never built (lost webhook): builds HEAD"
run_case false "$QUEUED_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "hourly poll, build of HEAD queued: submits nothing"
run_case false "$QUEUED_ON_LOCK_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "hourly poll, build of HEAD waiting on the lock: submits nothing"
run_case false "$IDLE" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS/$SHA" "0/true/$HEAD_SHA" "hourly poll, nothing in flight, HEAD never built: builds HEAD"
# a reconciled build of HEAD counts like the push build
QUEUED_RECONCILED_HEAD='{"items": [{"metadata": {"name": "ml-ci-build-reconciled-q"}, "status": {"phase": "Pending"},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app1"}, {"name": "commit_sha", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, {"name": "event_type", "value": "reconcile"}]}}}]}'
DATASET_EVENT=true run_case false "$QUEUED_RECONCILED_HEAD" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/false" "event, an earlier reconciled build of HEAD is queued: submits nothing"
# a build of HEAD for ANOTHER app does not count
QUEUED_HEAD_OTHER_APP='{"items": [{"metadata": {"name": "ml-ci-build-q"}, "status": {"phase": "Pending"},
  "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "app2"}, {"name": "commit_sha", "value": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}]}}}]}'
DATASET_EVENT=true run_case false "$QUEUED_HEAD_OTHER_APP" "$HEAD_SHA" unbuilt
expect_eq "$RC/$NEEDS" "0/true" "event, a build of the same sha for another app: builds HEAD"
unset DATASET_EVENT

echo "reconcile-trigger: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
