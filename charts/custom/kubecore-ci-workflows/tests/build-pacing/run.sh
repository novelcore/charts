#!/usr/bin/env bash
# Render guards for ML build pacing: a per-project cap on concurrent image builds and a
# render-only run that never waits behind them (HPC lab incident, 2026-11-10). Usage (from
# the repo root; needs helm, yq v4):
#
#   bash charts/custom/kubecore-ci-workflows/tests/build-pacing/run.sh
#
# The behaviour itself (mutex, semaphore, a render-only run finishing while builds queue) is
# proven on a real Argo controller by tests/build-pacing/kind/run.sh. Exit status = failures.
set -u
CHART=$(cd "$(dirname "$0")/../.." && pwd)
FAILED=0; PASSED=0
expect_eq() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi; }
R=$(mktemp); ON=$(mktemp); trap 'rm -f "$R" "$ON"' EXIT
helm template t "$CHART" --set github.tokenSecretName=ci-token > "$R" || { echo "FAIL: helm template"; exit 1; }
helm template t "$CHART" --set github.tokenSecretName=ci-token --set ci.buildSlots.enabled=true > "$ON" || { echo "FAIL: helm template (slots on)"; exit 1; }
ML='select(.kind=="ClusterWorkflowTemplate" and .metadata.name=="ml-ci-build")'
tmpl() { yq "$ML | .spec.templates[] | select(.name==\"$2\") | $3" "$1"; }

# ── no workflow-level lock: a render-only run takes no build mutex ───────────
expect_eq "$(yq "$ML | .spec.synchronization" "$R")" "null" "ml-ci-build has no workflow-level mutex or semaphore"
expect_eq "$(tmpl "$R" ml-ci-run-locked '.synchronization.mutexes[0].name')" "{{workflow.parameters.app_name}}-build" "builds of one app serialize on a template-level mutex"
expect_eq "$(tmpl "$R" ml-ci-run '.synchronization')" "null" "ml-ci-run (the render-only path too) takes no lock"
expect_eq "$(tmpl "$R" ml-ci-build '.synchronization')" "null" "the entrypoint (probe) takes no lock"

# ── the probe routes: has_changes decides which run, never the other way ─────
expect_eq "$(tmpl "$R" ml-ci-build '.steps[][] | select(.name=="probe-detect") | .template')" "detect-steps" "the entrypoint probes with detect-steps first"
expect_eq "$(tmpl "$R" ml-ci-build '.steps[][] | select(.name=="build-run") | .template')" "ml-ci-run-locked" "steps to build -> the locked run"
expect_eq "$(tmpl "$R" ml-ci-build '.steps[][] | select(.name=="build-run") | .when')" "{{steps.probe-detect.outputs.parameters.has_changes}} == true" "the locked run needs has_changes == true"
expect_eq "$(tmpl "$R" ml-ci-build '.steps[][] | select(.name=="render-run") | .template')" "ml-ci-run" "nothing to build -> the unlocked run"
expect_eq "$(tmpl "$R" ml-ci-build '.steps[][] | select(.name=="render-run") | .when')" "{{steps.probe-detect.outputs.parameters.has_changes}} != true" "the unlocked run is every other case"
expect_eq "$(tmpl "$R" ml-ci-build '.steps[][] | select(.name=="render-run") | .arguments.parameters[0].value')" "false" "the unlocked run is told locked=false"
expect_eq "$(tmpl "$R" ml-ci-run-locked '.steps[][] | select(.name=="run") | .arguments.parameters[0].value')" "true" "the locked run is told locked=true"

# ── an unlocked run never builds, tags or records a commit a locked build owes ─
expect_eq "$(tmpl "$R" ml-ci-run '.steps[][] | select(.name=="build-push") | .when')" "{{steps.detect-steps.outputs.parameters.has_changes}} == true && {{inputs.parameters.locked}} == true" "build-push needs the lock"
expect_eq "$(tmpl "$R" ml-ci-run '.steps[][] | select(.name=="tag") | .when | contains("inputs.parameters.locked}} == true")')" "true" "tag needs the lock"
expect_eq "$(tmpl "$R" ml-ci-run '.steps[][] | select(.name=="patch-images") | .when | contains("inputs.parameters.locked}} == true || ")')" "true" "patch-images records unlocked only when nothing was to build"

# ── the semaphore: kaniko only, never the render/enhance/commit pods ─────────
expect_eq "$(tmpl "$R" build-push '.synchronization')" "null" "slots off (the default): no semaphore (a namespace without the ConfigMap would fail every build)"
expect_eq "$(tmpl "$ON" build-push '.synchronization.semaphores[0].configMapKeyRef.name')" "ci-build-slots" "slots on: build-push takes a slot from ci-build-slots"
expect_eq "$(tmpl "$ON" build-push '.synchronization.semaphores[0].configMapKeyRef.key')" "slots" "... key slots"
HOLDERS=$(yq "$ML | .spec.templates[] | select(.synchronization.semaphores) | .name" "$ON" | tr '\n' ' ')
expect_eq "$HOLDERS" "build-push " "only build-push holds a semaphore slot"
for t in clone detect-steps version render-hera hera-render hera-enhance-commit patch-images tag status; do
  expect_eq "$(tmpl "$ON" "$t" '.synchronization')" "null" "$t takes no lock or slot"
done

# ── on-demand kaos-lib rebuild: only the reconciler's build rebuilds for a moved pin ─
expect_eq "$(yq "$ML | .spec.arguments.parameters[] | select(.name==\"kaos_lib_rebuild\") | .value" "$R")" "false" "kaos_lib_rebuild defaults to false"
SUBMIT=$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.templates[] | select(.name=="submit-build") | .resource.manifest' "$R" \
  | yq '.spec.arguments.parameters[] | select(.name=="kaos_lib_rebuild") | .value')
expect_eq "$SUBMIT" "{{=inputs.parameters.kaos_lib_ref != '' ? 'true' : 'false'}}" "only the KAOS-LIB DRIFT build (kaos_lib_ref set) is submitted with kaos_lib_rebuild=true"
expect_eq "$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.synchronization' "$R")" "null" "ml-ci-reconcile has no workflow-level lock"

echo "build-pacing: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
