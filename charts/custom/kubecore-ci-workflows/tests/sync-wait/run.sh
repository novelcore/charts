#!/usr/bin/env bash
# Render guard for "waiting for a build is not a failure" (ci-sync). Usage
# (from the repo root; needs helm, yq v4):
#
#   bash charts/custom/kubecore-ci-workflows/tests/sync-wait/run.sh
#
# check-drift must take the SAME Argo mutex as ml-ci-build, so a sync waits
# Pending on the build's lock instead of failing and retrying (dozens of red
# check-drift(n) nodes per first build). The behaviour itself is proven on a
# real Argo controller by tests/sync-wait/kind/run.sh. Exit status = failures.
set -u
CHART=$(cd "$(dirname "$0")/../.." && pwd)
FAILED=0; PASSED=0
expect_eq() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi; }
R=$(mktemp); trap 'rm -f "$R"' EXIT
helm template t "$CHART" > "$R" || { echo "FAIL: helm template"; exit 1; }

# ml-ci-build takes the lock on its ml-ci-run-locked template (a render-only run takes none: tests/build-pacing).
BUILD_LOCK=$(yq 'select(.kind=="ClusterWorkflowTemplate" and .metadata.name=="ml-ci-build") | .spec.templates[] | select(.name=="ml-ci-run-locked") | .synchronization.mutexes[0].name' "$R")
SYNC_LOCK=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.templates[] | select(.name=="decide-and-submit") | .synchronization.mutexes[0].name' "$R")
expect_eq "$SYNC_LOCK" "$BUILD_LOCK" "decide-and-submit (check-drift AND submit-build) takes the mutex ml-ci-build holds"
expect_eq "$SYNC_LOCK" "{{workflow.parameters.app_name}}-build" "the mutex is the per-app build lock"

DEADLINE=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.activeDeadlineSeconds' "$R")
expect_eq "$DEADLINE" "10800" "the wait is bounded by the run's activeDeadlineSeconds"

# head_sha has a default; needs_build deliberately has none (fail closed: a pod that exits 0 without
# writing it is an Argo error and is retried, never "no build needed"; the script writes it first on every path).
for o in needs_build head_sha; do
  D=$(yq "select(.metadata.name==\"ml-ci-reconcile\") | .spec.templates[] | select(.name==\"check-drift\") | .outputs.parameters[] | select(.name==\"$o\") | .valueFrom | has(\"default\")" "$R")
  if [ "$o" = needs_build ]; then expect_eq "$D" "false" "output $o has no default (fail closed)"; else expect_eq "$D" "true" "output $o has a default"; fi
done

AWAIT=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.templates[] | select(.name=="ml-ci-reconcile") | .steps[0][0].name' "$R")
expect_eq "$AWAIT" "await-inputs" "non-build inputs are awaited first, before the lock"
# No deadlock: submit-build only creates the Workflow (a resource template) and
# neither it nor check-drift takes a lock of its own; the queued build starts
# when the sync's template finishes.
for t in ml-ci-reconcile submit-build check-drift-with-retry check-drift-attempts; do
  L=$(yq "select(.metadata.name==\"ml-ci-reconcile\") | .spec.templates[] | select(.name==\"$t\") | .synchronization" "$R")
  expect_eq "$L" "null" "$t takes no lock of its own (the input wait never blocks a build)"
done
# check-drift takes a slot of the cluster-wide check-drift semaphore (tests/check-drift-cap), never a mutex:
# it waits for no build, and no build waits for it (a slot is released when its pod ends).
L=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.templates[] | select(.name=="check-drift") | .synchronization.mutexes' "$R")
expect_eq "$L" "null" "check-drift takes no mutex of its own (the input wait never blocks a build)"
SUBMIT_KIND=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.templates[] | select(.name=="submit-build") | .resource.action' "$R")
expect_eq "$SUBMIT_KIND" "create" "submit-build only creates the build Workflow, never waits for it"
WF_LOCK=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.synchronization' "$R")
expect_eq "$WF_LOCK" "null" "no workflow-level lock"

echo "sync-wait: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
