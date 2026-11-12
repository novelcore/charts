#!/bin/sh
# Render-order guard for ml-ci-build (kubecore-operator#1374). Usage (from the
# repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/render-order/run.sh /tmp/rendered.yaml
#
# The render is a step group of its own, BEFORE the build matrix (PRD
# novelcore/kaos#1911 AC-01): an app whose pipeline.py the engine refuses (it has
# not moved to the step contract) fails there, so none of its images is built.
# Until 0.13 the render shared a group with build-push (listed first, so that it
# took a `parallelism` slot before the matrix items, kubecore-operator#1374): a
# refused app then had every step image built for nothing. Needs yq v4. Exit
# status is the number of failed assertions.
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

ORDER=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
  | .spec.templates[] | select(.name == "ml-ci-run") | .steps | map(map(.name) | join("+")) | join(" > ")' "$RENDERED")
expect_eq "$ORDER" "clone > detect-steps > version+kaos-lib-support > render-hera > build-push > patch-images > tag > status" \
  "ml-ci-build: the render is its own group before the build matrix, so a failed render builds no image"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
  | .spec.templates[] | select(.name == "ml-ci-run") | .steps[][] | select(.name == "render-hera" or .name == "build-push") | select(.continueOn) | .name' "$RENDERED" | grep -vc '^---$')" \
  "0" "ml-ci-build: neither the render nor the builds continue on failure"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build") | .spec.parallelism' "$RENDERED")" \
  "2" "ml-ci-build: parallelism still bounds the build matrix (#1124)"

echo "render-order: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
