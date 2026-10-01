#!/bin/sh
# Render-order guard for ml-ci-build (kubecore-operator#1374). Usage (from the
# repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/render-order/run.sh /tmp/rendered.yaml
#
# The workflow's `parallelism` caps running pods and Argo gives each free slot
# to the step group's first unstarted step in list order. If build-push is
# listed before the renders, the render waits for every one of its matrix
# items (measured on poolaki 2026-10-01 with both orders, and live: ~12 min
# behind 8 builds). Needs yq v4. Exit status is the number of failed assertions.
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

GROUP=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
  | .spec.templates[] | select(.name == "ml-ci-build") | .steps[]
  | select(map(.name) | contains(["build-push"])) | map(.name) | join(",")' "$RENDERED")
expect_eq "$GROUP" "render-wft,render-hera,build-push" \
  "ml-ci-build: the renders take a parallelism slot before the build matrix"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build") | .spec.parallelism' "$RENDERED")" \
  "2" "ml-ci-build: parallelism still bounds the build matrix (#1124)"

echo "render-order: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
