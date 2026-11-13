#!/usr/bin/env bash
# Behavioural test of the check-drift cap on a REAL Argo Workflows controller (v4.0.6, the pools'
# version) in a throwaway kind cluster. Usage (from the repo root; needs kind, docker, helm, yq v4,
# kubectl, jq):
#
#   bash charts/custom/kubecore-ci-workflows/tests/check-drift-cap/kind/run.sh [outdir]
#
# The rendered ml-ci-reconcile is installed UNCHANGED (its real check-drift script, mutex and
# semaphore) except for the GitHub API base (a fake, with a per-request delay so a check takes
# seconds) and the system-pool nodeSelector; the semaphore's ConfigMap is the chart's own, with
# 2 slots. ml-ci-build is the stand-in of tests/sync-wait/kind. Proves:
#  1. a fan-out of 6 apps never runs more than 2 check-drift pods at once, uses both slots, and
#     the rest wait in Argo (semaphore "waiting", no pod): every run Succeeds, none lost;
#  2. the pending-reaper (run for real, threshold 1s) ignores a run waiting for a slot;
#  3. forced runs (the re-render that must not be dropped) all submit their build under the cap;
#  4. an app whose build holds its mutex does not hold a slot while its sync waits: the other
#     apps' syncs finish meanwhile, and the sync runs after the build (no deadlock).
# Uses its own kubeconfig; never touches another cluster. Exit status = failed asserts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../../.."
OUT="${1:-/tmp/check-drift-cap-evidence}"; mkdir -p "$OUT"
export KUBECONFIG="${KUBECONFIG_KIND:-/tmp/kind-capdrift.kube}"
K="kubectl -n argo"
CLUSTER="${KIND_CLUSTER:-capdrift}"
FAILED=0; PASSED=0
ok() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3 (expected '$2', got '$1')"; fi; }
le() { if [ "$1" -le "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3 ($1 <= $2)"; else FAILED=$((FAILED+1)); echo "FAIL: $3 ($1 > $2)"; fi; }
ge() { if [ "$1" -ge "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3 ($1 >= $2)"; else FAILED=$((FAILED+1)); echo "FAIL: $3 ($1 < $2)"; fi; }

kind get clusters | grep -qx "$CLUSTER" || kind create cluster --name "$CLUSTER" --kubeconfig "$KUBECONFIG" --wait 120s
$K get deploy workflow-controller >/dev/null 2>&1 || {
  kubectl create ns argo
  kubectl apply -n argo --server-side -f "https://github.com/argoproj/argo-workflows/releases/download/v4.0.6/install.yaml"
  $K patch deploy workflow-controller --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--executor-image","quay.io/argoproj/argoexec:v4.0.6"]}]'
  $K rollout status deploy/workflow-controller --timeout=240s; }

# the fake GitHub of tests/sync-wait/kind, plus a delay file (seconds per request)
$K delete pod fakegh --ignore-not-found --wait=true >/dev/null 2>&1
sed "s#        def do_GET(self):#        def do_GET(self):\n            import os, time; time.sleep(float(open('/data/delay').read() or 0) if os.path.exists('/data/delay') else 0)#" \
  "${CHART}/tests/sync-wait/kind/fixtures.yaml" | kubectl apply -f - >/dev/null
$K wait --for=condition=Ready pod/fakegh --timeout=180s >/dev/null

helm template t "$CHART" --set workflow.namespace=argo --set reconciler.serviceAccountName=ci-build-sa --set github.org=acme --set github.tokenSecretName=github-token --set ci.checkDrift.slots=2 > "$OUT/rendered.yaml"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile") | del(.spec.nodeSelector) | del(.spec.tolerations)' "$OUT/rendered.yaml" \
  | sed 's#https://api.github.com#http://fakegh.argo.svc:8080#g' > "$OUT/ml-ci-reconcile.rendered.yaml"
yq 'select(.kind == "ConfigMap" and .metadata.name == "ci-check-drift-slots")' "$OUT/rendered.yaml" | kubectl apply -f - >/dev/null
kubectl apply -f "$OUT/ml-ci-reconcile.rendered.yaml" >/dev/null
yq 'select(.kind == "WorkflowTemplate" and .metadata.name == "pending-reaper") | .spec.templates[0].container.args[0]' "$OUT/rendered.yaml" \
  | sed 's/^PENDING_MAX=.*/PENDING_MAX=1/' > "$OUT/reaper.sh"
ok "$($K get cm ci-check-drift-slots -o jsonpath='{.data.slots}')" "2" "the chart's ConfigMap carries the cap (2 for this test)"

CTX=$(printf 'kind: ConfigMap\ndata:\n  context.yaml: "{engine: {version: v0.4.7, image: reg.example/kaos-pipeline-engine:v0.4.7, wheel: https://example.com/e.whl, wheelSha256: aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}"\n' | sha256sum | cut -c1-64)
reset() { # $1 = built sha ("" = unbuilt), $2 = HEAD, $3 = delay
  $K delete workflows --all --wait=true >/dev/null 2>&1
  for a in 1 2 3 4 5 6; do
    kubectl -n ml-proj delete cm app$a-pipeline-images --ignore-not-found >/dev/null
    kubectl -n ml-proj create cm app$a-pipeline-images --from-literal=last-built-sha="$1" --from-literal=context-sha="$CTX" >/dev/null
  done
  $K exec fakegh -- sh -c "echo $2 > /data/head; echo $3 > /data/delay"
}
sync() { # name app force
  cat <<YAML | $K create -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: $1}
spec:
  workflowTemplateRef: {name: ml-ci-reconcile, clusterScope: true}
  arguments: {parameters: [{name: app_name, value: $2}, {name: project_name, value: proj}, {name: ci_namespace, value: argo},
    {name: gitops_repository, value: proj}, {name: workflow_template_path, value: kubeapps/$2/main/wft.yaml}, {name: force, value: "$3"}]}
YAML
}
build() { # name app sha seconds
  cat <<YAML | $K create -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: $1}
spec:
  workflowTemplateRef: {name: ml-ci-build, clusterScope: true}
  arguments: {parameters: [{name: app_name, value: $2}, {name: commit_sha, value: $3}, {name: build_seconds, value: "$4"}]}
YAML
}
phase() { $K get workflow "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
wait_phase() { for _ in $(seq 1 "${3:-180}"); do case "$(phase "$1")" in Succeeded|Failed|Error) [ "$(phase "$1")" = "$2" ] && return 0; return 1;; esac; sleep 1; done; return 1; }
checks() { $K get pods --no-headers 2>/dev/null | awk '$1 ~ /check-drift/ && ($3 == "Running" || $3 == "Pending" || $3 == "ContainerCreating" || $3 == "PodInitializing") {n++} END {print n+0}'; }
waiting() { $K get workflows -o json | jq '[.items[] | select(.status.phase=="Running") | .status.synchronization.semaphore.waiting // [] | length] | add // 0'; }
evidence() { argo -n argo get "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/$2.txt"; }
all_done() { # names...: wait until each is Succeeded, sampling the number of check-drift pods
  MAXC=0; MAXW=0; REAPED=""
  for _ in $(seq 1 240); do
    C=$(checks); [ "$C" -gt "$MAXC" ] && MAXC=$C
    W=$(waiting); [ "$W" -gt "$MAXW" ] && MAXW=$W
    [ -n "${WITH_REAPER:-}" ] && [ "$W" -gt 0 ] && REAPED="${REAPED}$(sh "$OUT/reaper.sh" 2>&1 | grep -c '^REAP')"
    D=0; for n in "$@"; do [ "$(phase "$n")" = "Succeeded" ] && D=$((D+1)); done
    [ "$D" = "$#" ] && return 0; sleep 1
  done; return 1
}

if [ -z "${ONLY:-}" ] || [ "$ONLY" = 1 ]; then
echo "== 1+2. six apps polled at once, cap 2: never more than 2 check-drift pods, none lost, the reaper leaves the queue alone =="
reset aaaaaaa1 aaaaaaa1 4
for a in 1 2 3 4 5 6; do sync cap-$a app$a false; done
WITH_REAPER=1 all_done cap-1 cap-2 cap-3 cap-4 cap-5 cap-6; ok "$?" "0" "all six runs Succeeded (none lost in the queue)"
le "$MAXC" 2 "never more than 2 check-drift pods at once"
ge "$MAXC" 2 "both slots are used"
ge "$MAXW" 3 "the rest wait in Argo on the semaphore (at least 3 waiting at the peak)"
ok "$(printf '%s' "$REAPED" | tr -d 0)" "" "the pending-reaper (threshold 1s) reaped nothing while runs waited for a slot"
ok "$($K get workflows -o json | jq '[.items[] | select(.status.phase != "Succeeded")] | length')" "0" "no run failed or was stopped"
ok "$($K get workflows -o json | jq '[.items[].status.nodes[]? | select(.type=="Pod" and .phase!="Succeeded")] | length')" "0" "no failed pod node"
evidence cap-6 1-last-queued

fi
if [ -z "${ONLY:-}" ] || [ "$ONLY" = 3 ]; then
echo "== 3. six FORCED runs (an unbuilt HEAD): every one still submits its build, under the cap =="
reset "" bbbbbbb1 3
for a in 1 2 3 4 5 6; do sync force-$a app$a true; done
all_done force-1 force-2 force-3 force-4 force-5 force-6; ok "$?" "0" "all six forced runs Succeeded"
le "$MAXC" 2 "forced runs: never more than 2 check-drift pods at once (the wait step and the decision each count)"
ok "$($K get workflows -o json | jq '[.items[] | select(.metadata.name | startswith("ml-ci-build-reconciled"))] | length')" "6" "six builds were submitted, one per app: no forced re-render dropped"
ok "$($K get workflows -o json | jq '[.items[] | select(.metadata.name | startswith("ml-ci-build-reconciled")) | .metadata.labels["platform.kubecore.io/app"]] | unique | length')" "6" "for six different apps"
evidence force-6 3-forced

fi
echo "== 4. an app whose build holds its mutex holds no slot: its sync waits, the others finish, then it runs =="
reset aaaaaaa1 ccccccc1 1
build ml-ci-build-hold app1 ccccccc1 150; sleep 10; sync mx-1 app1 false
for a in 2 3 4; do sync mx-$a app$a false; done
all_done mx-2 mx-3 mx-4; ok "$?" "0" "the other apps' syncs finish while app1's build runs"
ok "$(phase ml-ci-build-hold)" "Running" "app1's build is still running (the mutex is still held)"
ok "$($K get workflow mx-1 -o json | jq -r '[.status.nodes[] | select(.displayName=="decide")][0].phase')" "Pending" "app1's sync is waiting on its build mutex"
ok "$($K get workflow mx-1 -o json | jq '.status.synchronization.semaphore.holding // [] | length')" "0" "and holds no semaphore slot while it waits"
wait_phase mx-1 Succeeded 400; ok "$?" "0" "app1's sync runs after the build: no deadlock"
evidence mx-1 4-mutex-and-slot

$K exec fakegh -- sh -c "echo 0 > /data/delay"
echo "check-drift-cap/kind: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
