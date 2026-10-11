#!/bin/sh
# kubecore-e2e-canary render + probe tests. Usage (from the repo root):
#
#   sh charts/custom/kubecore-e2e-canary/tests/render/run.sh
#
# The chart exists for one e2e check (kaos `helm_release_self_heals`, kubecore-operator
# #1464): its readiness probe must fail until `readyAfter` and pass from then on, so a
# Helm upgrade with `wait` can be made to time out on purpose. These tests render the
# chart and EXECUTE the rendered probe command under the local sh with the rendered env,
# for an instant in the past, an instant in the future and an empty value. Needs helm and
# yq v4. Exit status is the number of failed assertions.
set -u
CHART="$(cd "$(dirname "$0")/../.." && pwd)"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0
PASSED=0

pass() { PASSED=$((PASSED + 1)); echo "PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "  $2"; }
expect_eq() {
  if [ "$1" = "$2" ]; then pass "$3"; else fail "$3" "expected [$2] got [$1]"; fi
}

render() { # name, extra helm args...
  name="$1"; shift
  helm template canary "$CHART" "$@" > "$WORK/$name.yaml" 2> "$WORK/$name.err"
}
dep() { yq "select(.kind == \"Deployment\") | $2" "$WORK/$1.yaml"; }

# Runs the rendered readiness probe command with the rendered READY_AFTER_EPOCH, exactly
# as the kubelet would run it in the container (busybox sh + date there; the local sh and
# date here — `date +%s` and `[ -ge ]` are POSIX).
probe() { # name -> exit status of the probe
  epoch=$(dep "$1" '.spec.template.spec.containers[0].env[] | select(.name == "READY_AFTER_EPOCH") | .value')
  cmd=$(dep "$1" '.spec.template.spec.containers[0].readinessProbe.exec.command[2]')
  READY_AFTER_EPOCH="$epoch" sh -c "$cmd"
}

# 1. Default: empty readyAfter -> ready immediately.
render default || fail "default renders" "$(cat "$WORK/default.err")"
expect_eq "$(yq 'select(.kind != null) | .kind' "$WORK/default.yaml" | sort -u | tr '\n' ' ')" "Deployment " \
  "the chart renders exactly one kind: Deployment (no Namespace, no RBAC, no Service)"
expect_eq "$(dep default '.spec.template.spec.containers[0].env[] | select(.name == "READY_AFTER_EPOCH") | .value')" "0" \
  "empty readyAfter renders epoch 0"
if probe default; then pass "empty readyAfter: the probe passes now"; else fail "empty readyAfter: the probe passes now"; fi

# 2. readyAfter in the past -> ready.
render past --set readyAfter=2020-01-01T00:00:00Z || fail "past renders" "$(cat "$WORK/past.err")"
expect_eq "$(dep past '.spec.template.spec.containers[0].env[] | select(.name == "READY_AFTER_EPOCH") | .value')" "1577836800" \
  "readyAfter 2020-01-01T00:00:00Z renders epoch 1577836800"
if probe past; then pass "readyAfter in the past: the probe passes"; else fail "readyAfter in the past: the probe passes"; fi
expect_eq "$(dep past '.spec.template.metadata.annotations."e2e.kubecore.io/ready-after"')" "2020-01-01T00:00:00Z" \
  "the pod template carries readyAfter, so a new value rolls the Deployment"

# 3. readyAfter in the future -> NOT ready (the fault).
render future --set readyAfter=2099-01-01T00:00:00Z || fail "future renders" "$(cat "$WORK/future.err")"
if probe future; then fail "readyAfter in the future: the probe fails"; else pass "readyAfter in the future: the probe fails"; fi

# 3b. A numeric offset is honoured (RFC3339 with a zone, not only Z).
render offset --set readyAfter=2020-01-01T02:00:00+02:00 || fail "offset renders" "$(cat "$WORK/offset.err")"
expect_eq "$(dep offset '.spec.template.spec.containers[0].env[] | select(.name == "READY_AFTER_EPOCH") | .value')" "1577836800" \
  "readyAfter with a +02:00 offset renders the same instant"

# 4. A malformed value fails the render: it must never quietly mean "ready now".
if render bad --set readyAfter=tomorrow; then
  fail "a non-RFC3339 readyAfter fails the render" "it rendered"
else
  pass "a non-RFC3339 readyAfter fails the render"
fi

# 5. Shape: pinned image, requests, rollout that judges the new pod, restricted security.
img=$(dep default '.spec.template.spec.containers[0].image')
case "$img" in
  registry.k8s.io/e2e-test-images/busybox:1.36.1-1@sha256:*) pass "image is an exact tag plus digest ($img)" ;;
  *) fail "image is an exact tag plus digest" "$img" ;;
esac
expect_eq "$(dep default '.spec.template.spec.containers[0].resources.requests.cpu')" "5m" "cpu request set"
expect_eq "$(dep default '.spec.template.spec.containers[0].resources.requests.memory')" "8Mi" "memory request set"
expect_eq "$(dep default '.spec.strategy.rollingUpdate.maxUnavailable')" "0" \
  "maxUnavailable 0: Helm's wait judges the new pod, not the old one"
expect_eq "$(dep default '.spec.template.spec.securityContext.runAsNonRoot')" "true" "runs as non-root"
expect_eq "$(dep default '.spec.template.spec.automountServiceAccountToken')" "false" "no service account token"
expect_eq "$(dep default '.spec.template.spec.containers[0].securityContext.capabilities.drop[0]')" "ALL" "drops all capabilities"

# 6. Scheduling values pass through (the operator renders the pool's system scheduling).
render sched --set nodeSelector.pool=system --set 'tolerations[0].key=k' --set 'tolerations[0].operator=Exists' \
  || fail "sched renders" "$(cat "$WORK/sched.err")"
expect_eq "$(dep sched '.spec.template.spec.nodeSelector.pool')" "system" "nodeSelector passes through"
expect_eq "$(dep sched '.spec.template.spec.tolerations[0].key')" "k" "tolerations pass through"

echo "passed=$PASSED failed=$FAILED"
exit "$FAILED"
