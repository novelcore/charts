#!/bin/sh
# Retry-window guard (kubecore-operator#1377). Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/retry-window/run.sh /tmp/rendered.yaml
#
# Argo counts backoff.maxDuration from the FIRST attempt's start: once an
# attempt has run longer than it, the step is never retried ("Max duration
# limit exceeded"). A 5m cap therefore cancelled the spot-preemption retry of
# every real build, and the deadline retry of every long pipeline step.
# Measured on Argo v4.0.6 (poolaki, 2026-10-01): a 30s attempt under a 20s
# maxDuration ran once; without it, three times. This covers the workflow
# templates AND the step retries render-wft embeds in the rendered WFT.
# Needs yq v4. Exit status is the number of failed assertions.
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

STRATEGIES=$(yq 'select(.kind == "ClusterWorkflowTemplate" or .kind == "WorkflowTemplate")
  | .spec.templates[] | select(.retryStrategy) | .name' "$RENDERED" | grep -vc '^---$')
CAPPED=$(yq 'select(.kind == "ClusterWorkflowTemplate" or .kind == "WorkflowTemplate")
  | .spec.templates[] | select(.retryStrategy.backoff.maxDuration) | .name' "$RENDERED" | grep -vc '^---$')
expect_eq "$CAPPED" "0" "no workflow-template retryStrategy caps its window with maxDuration (${STRATEGIES} checked)"

# render-wft builds the pipeline steps' retryStrategy in Python; check the
# script text, ignoring comments.
EMBEDDED=$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "render-wft") | .container.args[0]' "$RENDERED" \
  | grep -v '^\s*#' | grep -c "maxDuration")
expect_eq "$EMBEDDED" "0" "render-wft's pipeline-step retryStrategy has no maxDuration"

LIMITS=$(yq 'select(.kind == "ClusterWorkflowTemplate" or .kind == "WorkflowTemplate")
  | .spec.templates[] | select(.retryStrategy) | .retryStrategy.limit' "$RENDERED" | grep -v '^---$' | sort -u | tr '\n' ' ')
expect_eq "$LIMITS" "2 " "every retryStrategy is still bounded by limit 2"

echo "retry-window: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
