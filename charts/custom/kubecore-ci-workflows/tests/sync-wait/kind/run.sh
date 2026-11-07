#!/usr/bin/env bash
# Behavioural test of ml-ci-reconcile's wait for an in-flight build, on a REAL
# Argo Workflows controller (v4.0.6, the pools' version) in a throwaway kind
# cluster. Usage (from the repo root; needs kind, docker, helm, yq v4, kubectl,
# curl):
#
#   bash charts/custom/kubecore-ci-workflows/tests/sync-wait/kind/run.sh [outdir]
#
# The rendered ml-ci-reconcile is installed UNCHANGED except for the GitHub API
# base (a fake in the cluster) and the system-pool nodeSelector. ml-ci-build is
# a stand-in with the same app mutex whose "build" is a sleep. Each scenario's
# `argo get` tree is written to outdir as evidence. Never touches any other
# cluster: it uses its own kubeconfig. Exit status = number of failed asserts.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../../.."
OUT="${1:-/tmp/sync-wait-evidence}"; mkdir -p "$OUT"
export KUBECONFIG="${KUBECONFIG_KIND:-/tmp/kind-sync.kube}"
K="kubectl -n argo"
FAILED=0; PASSED=0
ok() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3 (expected '$2', got '$1')"; fi; }

kind get clusters | grep -qx syncwait || kind create cluster --name syncwait --kubeconfig "$KUBECONFIG" --wait 120s
$K get deploy workflow-controller >/dev/null 2>&1 || {
  kubectl create ns argo
  kubectl apply -n argo --server-side -f "https://github.com/argoproj/argo-workflows/releases/download/v4.0.6/install.yaml"
  $K patch deploy workflow-controller --type=json -p='[{"op":"replace","path":"/spec/template/spec/containers/0/args","value":["--executor-image","quay.io/argoproj/argoexec:v4.0.6"]}]'
  $K rollout status deploy/workflow-controller --timeout=240s; }

helm template t "$CHART" --set github.org=acme --set github.tokenSecretName=github-token \
 | yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile") | del(.spec.nodeSelector) | del(.spec.tolerations)' \
 | sed 's#https://api.github.com#http://fakegh.argo.svc:8080#g' > "$OUT/ml-ci-reconcile.rendered.yaml"
kubectl apply -f "${HERE}/fixtures.yaml" >/dev/null
kubectl apply -f "$OUT/ml-ci-reconcile.rendered.yaml" >/dev/null
$K wait --for=condition=Ready pod/fakegh --timeout=180s >/dev/null

reset_app() { # $1 = built sha ("" for a fresh app), $2 = HEAD
  $K delete workflows --all --wait=true >/dev/null 2>&1
  kubectl -n ml-proj delete cm app1-pipeline-images --ignore-not-found >/dev/null
  CTX=$(printf '%s' 'kind: ConfigMap  # gitops pipeline-context.yaml, raw' | sha256sum | cut -c1-64)
  kubectl -n ml-proj create cm app1-pipeline-images --from-literal=last-built-sha="$1" \
    --from-literal=context-sha="$CTX" --from-literal=enhancer-ref="$(helm template t "$CHART" | grep -m1 -o 'enhancer-ref: "[^"]*"' | cut -d'"' -f2)" >/dev/null
  $K exec fakegh -- sh -c "echo $2 > /data/head"
}
build() { # name sha seconds [deadline]
  cat <<YAML | $K create -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: $1}
spec:
  ${4:+activeDeadlineSeconds: $4}
  workflowTemplateRef: {name: ml-ci-build, clusterScope: true}
  arguments: {parameters: [{name: app_name, value: app1}, {name: commit_sha, value: $2}, {name: build_seconds, value: "$3"}]}
YAML
}
sync() { # name [deadline]
  cat <<YAML | $K create -f - >/dev/null
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata: {name: $1}
spec:
  ${2:+activeDeadlineSeconds: $2}
  workflowTemplateRef: {name: ml-ci-reconcile, clusterScope: true}
  arguments: {parameters: [{name: app_name, value: app1}, {name: project_name, value: proj}, {name: ci_namespace, value: argo},
    {name: gitops_repository, value: proj}, {name: workflow_template_path, value: kubeapps/app1/main/wft.yaml}, {name: force, value: "true"}]}
YAML
}
phase() { $K get workflow "$1" -o jsonpath='{.status.phase}' 2>/dev/null; }
wait_phase() { # wf want timeout
  for _ in $(seq 1 "${3:-180}"); do case "$(phase "$1")" in Succeeded|Failed|Error) [ "$(phase "$1")" = "${2}" ] && return 0; return 1;; esac; sleep 1; done; return 1; }
failed_nodes() { $K get workflow "$1" -o json | jq '[.status.nodes[] | select(.type=="Pod" or .type=="Retry") | select(.phase=="Failed" or .phase=="Error")] | length'; }
builds() { $K get workflows -o json | jq -r '[.items[] | select(.metadata.name|startswith("ml-ci-build")) | .metadata.name] | length'; }
evidence() { argo -n argo get "$1" 2>&1 | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/$2.txt"; }

echo "== 1. first build in flight: the sync waits Pending (no failed nodes), then decides once =="
reset_app "" bbbbbbb1
build ml-ci-build-first bbbbbbb1 40; sleep 8; sync sync-1
sleep 12; ok "$($K get workflow sync-1 -o json | jq -r '[.status.nodes[] | select(.displayName=="decide")][0].phase')" "Pending" "the sync's decide step sits Pending on the build lock while the build runs"
ok "$($K get pods --no-headers | grep 'sync-1' | grep -vc Completed)" "0" "no sync pod is running or retrying meanwhile (the input wait already completed)"
evidence sync-1 1-waiting
wait_phase sync-1 Succeeded 180; ok "$?" "0" "sync Succeeded"; evidence sync-1 1-done
ok "$(failed_nodes sync-1)" "0" "zero failed nodes in the sync"
ok "$(builds)" "1" "the built HEAD is not rebuilt (ALREADY SATISFIED), still one build"

echo "== 2. a second commit during a build is built after it, nothing lost =="
reset_app "" ccccccc1
build ml-ci-build-c1 ccccccc1 30; sleep 5; sync sync-2
$K exec fakegh -- sh -c "echo ccccccc2 > /data/head"; build ml-ci-build-c2 ccccccc2 10
wait_phase ml-ci-build-c2 Succeeded 240; ok "$?" "0" "build of the second commit ran after the first"
wait_phase sync-2 Succeeded 120; evidence sync-2 2-done
ok "$(kubectl -n ml-proj get cm app1-pipeline-images -o jsonpath='{.data.last-built-sha}')" "ccccccc2" "last-built-sha is the newest commit"
ok "$(failed_nodes sync-2)" "0" "zero failed nodes in the sync"

echo "== 3. build pod killed: lock released, sync proceeds =="
reset_app "" ddddddd1
build ml-ci-build-d1 ddddddd1 120; sleep 10; sync sync-3; sleep 5
$K wait --for=condition=Ready pod/ml-ci-build-d1 --timeout=120s >/dev/null 2>&1
# SIGKILL the build's main container on the node (what an OOM kill or a lost node does)
docker exec syncwait-control-plane sh -c "crictl stop -t 0 \$(crictl ps -q --label io.kubernetes.pod.name=ml-ci-build-d1 --name main)" >/dev/null 2>&1
wait_phase sync-3 Succeeded 240; ok "$?" "0" "sync ended Succeeded after the build died"; evidence sync-3 3-done
ok "$(phase ml-ci-build-d1)" "Failed" "the dead build is reported as such (its own red node, not the sync's)"
ok "$(failed_nodes sync-3)" "0" "zero failed nodes in the sync"

echo "== 4. two syncs at once: one build of HEAD =="
reset_app "" eeeeeee1
sync sync-4a; sync sync-4b
wait_phase sync-4a Succeeded 120; wait_phase sync-4b Succeeded 120; sleep 5
evidence sync-4a 4a-done; evidence sync-4b 4b-done
ok "$(builds)" "1" "exactly one build submitted by two simultaneous syncs"

echo "== 5. hung build: the waiting sync fails with a clear reason at its deadline; lock released at the build's =="
reset_app "" fffffff1
build ml-ci-build-hang fffffff1 600 70; sleep 5; sync sync-5 40
wait_phase sync-5 Failed 120; ok "$?" "0" "waiting sync failed at its deadline"
NODEMSG=$($K get workflow sync-5 -o json | jq -r '[.status.nodes[] | select(.displayName=="decide")][0].message')
ok "$NODEMSG" "Step exceeded its deadline" "the waiting node's reason is the deadline"
evidence sync-5 5-sync-deadline
wait_phase ml-ci-build-hang Failed 120; sync sync-5b
wait_phase sync-5b Succeeded 120; ok "$?" "0" "after the hung build is killed, a new sync gets the lock and runs"
evidence sync-5b 5-after-release
echo "== 6. inputs still arriving (repo not there): the sync retries WITHOUT the build lock, a build is not held up =="
reset_app "" ggggggg1
$K exec fakegh -- sh -c "echo > /data/head"; sync sync-6; sleep 20
build ml-ci-build-six ggggggg1 5
wait_phase ml-ci-build-six Succeeded 60; ok "$?" "0" "the build ran while the sync was still waiting for the repo"
ok "$(phase sync-6)" "Running" "the sync is still waiting for its input"
$K exec fakegh -- sh -c "echo ggggggg1 > /data/head"
wait_phase sync-6 Succeeded 150; ok "$?" "0" "the sync completes once the input arrives (already satisfied: built HEAD)"
evidence sync-6 6-inputs-late
echo "sync-wait/kind: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
