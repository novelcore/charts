#!/usr/bin/env bash
# Behavioural test of ML build pacing on a REAL Argo Workflows controller (v4.0.6, the pools'
# version) in a throwaway kind cluster. Usage (from the repo root; needs kind, docker, helm,
# yq v4, kubectl, jq, python3 with PyYAML):
#
#   bash charts/custom/kubecore-ci-workflows/tests/build-pacing/kind/run.sh [outdir]
#
# The rendered ml-ci-build is installed with its steps, whens, withParam, parallelism and
# synchronization UNCHANGED; only what each template does is stubbed (stub.py). Proves:
#  1. never more concurrent build-push pods than the project's semaphore (2), and the cap is used;
#  2. a render-only run (nothing to build) finishes while the same app's build is still running,
#     and holds no mutex or semaphore (its status carries no synchronization);
#  3. two builds of ONE app serialize on the app mutex (the second waits, no pod, then runs).
# Uses its own kubeconfig; never touches another cluster. Exit status = failed asserts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../../.."
OUT="${1:-/tmp/build-pacing-evidence}"; mkdir -p "$OUT"
export KUBECONFIG="${KUBECONFIG_KIND:-/tmp/kind-pacing.kube}"
K="kubectl -n argo"
FAILED=0; PASSED=0
ok() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3 (expected '$2', got '$1')"; fi; }
le() { if [ "$1" -le "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3 ($1 <= $2)"; else FAILED=$((FAILED+1)); echo "FAIL: $3 ($1 > $2)"; fi; }

kind get clusters | grep -qx pacing || kind create cluster --name pacing --kubeconfig "$KUBECONFIG" --wait 120s
$K get deploy workflow-controller >/dev/null 2>&1 || {
  kubectl create ns argo
  kubectl apply -n argo --server-side -f "https://github.com/argoproj/argo-workflows/releases/download/v4.0.6/install.yaml"
  $K patch deploy workflow-controller --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--executor-image","quay.io/argoproj/argoexec:v4.0.6"]}]'
  $K rollout status deploy/workflow-controller --timeout=240s; }
$K create role wtr --verb=create,patch --resource=workflowtaskresults.argoproj.io >/dev/null 2>&1
$K create rolebinding wtr --role=wtr --serviceaccount=argo:default >/dev/null 2>&1

helm template t "$CHART" --set github.tokenSecretName=ci-token --set ci.buildSlots.enabled=true --set workspace.size=64Mi --set github.org=acme \
  | python3 "${HERE}/stub.py" /dev/stdin > "$OUT/ml-ci-build.stub.yaml"
kubectl apply -f "$OUT/ml-ci-build.stub.yaml" >/dev/null
$K delete cm ci-build-slots --ignore-not-found >/dev/null
$K create cm ci-build-slots --from-literal=slots=2 >/dev/null

submit() { # name app has_changes [build_seconds]
  cat <<YAML | $K create -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: $1}
spec:
  workflowTemplateRef: {name: ml-ci-build, clusterScope: true}
  arguments: {parameters: [{name: repo_url, value: x}, {name: commit_sha, value: abcdef1}, {name: branch, value: dev},
    {name: app_name, value: $2}, {name: project_name, value: proj}, {name: gitops_repository, value: g}, {name: workflow_template_path, value: w}, {name: stub_has_changes, value: "$3"}, {name: build_seconds, value: "${4:-20}"}]}
YAML
}
phase() { $K get workflow "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
wait_done() { for _ in $(seq 1 "${2:-240}"); do case "$(phase "$1")" in Succeeded|Failed|Error) return 0;; esac; sleep 1; done; return 1; }
running_builds() { $K get pods -o json | jq '[.items[] | select(.metadata.name | test("build-push")) | select(.status.phase == "Running")] | length'; }
evidence() { argo -n argo get "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/$2.txt"; }
reset() { $K delete workflows --all --wait=true >/dev/null 2>&1; }

echo "== 1. three apps build at once: never more than 2 build-push pods =="
reset
submit pace-a1 app1 true; submit pace-a2 app2 true; submit pace-a3 app3 true
MAX=0
for _ in $(seq 1 200); do
  N=$(running_builds); [ "$N" -gt "$MAX" ] && MAX=$N
  P1=$(phase pace-a1); P2=$(phase pace-a2); P3=$(phase pace-a3)
  case "$P1$P2$P3" in *Running*|*Pending*|"") sleep 1;; *) break;; esac
done
le "$MAX" 2 "concurrent build-push pods never exceed the semaphore"
ok "$MAX" "2" "the cap is actually used (2 builds ran side by side)"
ok "$(phase pace-a1)/$(phase pace-a2)/$(phase pace-a3)" "Succeeded/Succeeded/Succeeded" "all three builds finish"
evidence pace-a1 1-build

echo "== 2. a render-only run is not blocked behind the same app's build =="
reset
submit pace-b1 app1 true 150
for _ in $(seq 1 120); do $K get pods --no-headers 2>/dev/null | grep -q "pace-b1.*build-push.*Running" && break; sleep 1; done  # the build is running, then the render-only run starts
submit pace-render app1 false
wait_done pace-render 300
ok "$(phase pace-render)" "Succeeded" "the render-only run succeeds"
ok "$(phase pace-b1)" "Running" "... while the same app's build is still running (the build mutex is not its business)"
ok "$($K get workflow pace-render -o json | jq '.status.synchronization // null')" "null" "the render-only run held no mutex or semaphore"
ok "$($K get workflow pace-render -o json | jq '[.status.nodes[] | select(.displayName == "build-push" or (.displayName | test("build-push\\("))) | select(.phase != "Omitted" and .phase != "Skipped")] | length')" "0" "... and started no build"
evidence pace-render 2-render-only
wait_done pace-b1 400

echo "== 3. two builds of one app serialize on the app mutex =="
reset
submit pace-c1 app1 true 60
for _ in $(seq 1 120); do $K get pods --no-headers 2>/dev/null | grep -q "pace-c1.*build-push" && break; sleep 1; done  # c1 holds the app mutex
submit pace-c2 app1 true 20
WAITING=0
for _ in $(seq 1 120); do
  WAITING=$($K get workflow pace-c2 -o json | jq -r '[(.status.nodes // {})[] | select(.phase == "Pending") | .message] | first // ""' | grep -c 'Waiting for .*app1-build lock')
  [ "$WAITING" = 1 ] && break; sleep 1; done
ok "$WAITING" "1" "the second build waits on the app mutex (a Pending node, no pod)"
ok "$($K get pods --no-headers | grep -c 'pace-c2.*build-push')" "0" "... and has started no build pod"
evidence pace-c2 3-waiting
wait_done pace-c1 400; wait_done pace-c2 400
ok "$(phase pace-c1)/$(phase pace-c2)" "Succeeded/Succeeded" "both finish, one after the other"

echo "build-pacing kind: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
