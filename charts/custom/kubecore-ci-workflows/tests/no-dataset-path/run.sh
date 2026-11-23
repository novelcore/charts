#!/bin/sh
# No dataset path in the ML CI (PRD novelcore/kaos#1911 D-73, chart 0.17.16). Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/no-dataset-path/run.sh /tmp/rendered.yaml
#
# The run form's dataset field is a plain field with a default; the console reads the choices live and
# the run refuses a dataset or version that does not exist at its first step. So nothing in the CI
# reads the catalog or runs because a dataset changed: no fan-out on a dataset event, no DATASET DRIFT
# check, no dataset fill or digest at render time. Nothing calls the catalog, so a render succeeds with
# the catalog unreachable. Needs yq v4. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
FAILED=0
PASSED=0

expect_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $3"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"
  fi
}
cwt() { yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")" "$RENDERED"; }
tmpl() { yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\") | .spec.templates[] | select(.name == \"$2\")" "$RENDERED"; }
count() { printf '%s\n' "$1" | grep -c -- "$2" || true; }

expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-dataset-release") | .metadata.name' "$RENDERED" | grep -c .)" "0" \
  "no ml-ci-dataset-release template is rendered"

RECONCILE=$(cwt ml-ci-reconcile)
expect_eq "$(printf '%s\n' "$RECONCILE" | yq '[.spec.arguments.parameters[] | select(.name == "dataset_event")] | length')" "0" \
  "ml-ci-reconcile has no dataset_event parameter"
expect_eq "$(count "$RECONCILE" 'dataset_event')" "0" "ml-ci-reconcile names dataset_event nowhere"
expect_eq "$(count "$RECONCILE" 'dataset-choices')" "0" "ml-ci-reconcile carries no catalog reader"
expect_eq "$(count "$RECONCILE" 'DATASET DRIFT')" "0" "ml-ci-reconcile has no DATASET DRIFT check"
expect_eq "$(count "$RECONCILE" 'kaos-lake')" "0" "ml-ci-reconcile mounts no kaos-lake token"
expect_eq "$(count "$RECONCILE" 'dataset-sha')" "0" "ml-ci-reconcile reads no dataset-sha"
expect_eq "$(printf '%s\n' "$RECONCILE" | yq '.spec.templates[] | select(.name == "ml-ci-reconcile") | .steps[][] | select(.name == "await-inputs") | .when')" \
  "{{workflow.parameters.force}} == true" "await-inputs waits only for a forced run"

ENHANCE=$(tmpl ml-ci-build hera-enhance-commit)
expect_eq "$(count "$ENHANCE" 'dataset-choices')" "0" "hera-enhance-commit has no catalog reader or dataset fill"
expect_eq "$(count "$ENHANCE" '/tmp/dataset-sha')" "0" "hera-enhance-commit writes no /tmp/dataset-sha"
expect_eq "$(count "$ENHANCE" 'dataset_sha\|dataset_moved')" "0" "hera-enhance-commit records no dataset-sha"
expect_eq "$(printf '%s\n' "$ENHANCE" | yq '[.volumes[]? | select(.name == "kaos-lake-token")] | length')" "0" \
  "hera-enhance-commit mounts no kaos-lake token"
# (the steps' own token, add_step_token, is a separate use and stays: it names the mount path, not a catalog)
expect_eq "$(count "$ENHANCE" 'kaos/v1/catalog\|workloadAudience')" "0" "hera-enhance-commit names no catalog endpoint or kaos-lake audience value"
# An existing app has the key committed: pruning it would be one gitops commit per app.
expect_eq "$(count "$ENHANCE" '"dataset-sha", "wft-bytes"')" "1" "hera-enhance-commit still keeps a committed dataset-sha key from pruning"
expect_eq "$(count "$(tmpl ml-ci-build patch-images)" 'KEY}" = "dataset-sha"')" "1" "patch-images still skips a committed dataset-sha key"

# The other drift checks are untouched.
for D in 'CONTEXT DRIFT' 'ENGINE DRIFT' 'KAOS-LIB DRIFT' 'NAMESPACE DRIFT'; do
  [ "$(count "$RECONCILE" "$D")" -ge 1 ] && R=present || R=missing
  expect_eq "$R" "present" "ml-ci-reconcile keeps its $D check"
done

# Nothing calls the catalog: no rendered template of the chart names it.
expect_eq "$(grep -c 'kaos/v1/catalog\|dataset-choices\|ml-ci-dataset-rerender\|dataset-release-sa' "$RENDERED")" "0" \
  "no rendered template reads the catalog or fans out on a dataset event"

echo "no-dataset-path: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
