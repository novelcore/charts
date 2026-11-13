#!/usr/bin/env bash
# The pull-request and merge render runs the developer's pipeline.py (PRD novelcore/kaos#1911).
# It must run as an unprivileged user with nothing writable but its workspace and scratch space,
# no Kubernetes token, no capabilities, and a network policy that keeps it off the cluster's
# internal addresses and the metadata endpoint. Usage (repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/render-isolation/run.sh
#
# Rendered-chart assertions, plus (when podman and the python image are available) an executed
# check of the writable-site-packages mechanism the render needs to pip-install an app's
# dependencies under a read-only root filesystem. Needs helm and yq v4. Exit status is the
# number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
check() { # check DESCRIPTION EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then PASSED=$((PASSED + 1)); echo "PASS: $1"
  else FAILED=$((FAILED + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fi
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
helm template t "$CHART" --set github.org=acme > "$T/default.yaml" || { echo "FAIL: helm template"; exit 1; }
helm template t "$CHART" --set github.org=acme --set renderPods.networkPolicy.enabled=true \
  --set 'renderPods.networkPolicy.kubeApiCIDRs={172.16.15.130/32}' > "$T/policy.yaml" || { echo "FAIL: helm template (policy)"; exit 1; }

R='select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "hera-render")'
q() { yq "${R} | $1" "$T/default.yaml"; }
j() { yq -o=json -I=0 "${R} | $1" "$T/default.yaml"; }

# ── the pod ──────────────────────────────────────────────────────────────
check "no Kubernetes token in the pod" "false" "$(q '.automountServiceAccountToken')"
check "the pod runs as a non-root user" "true" "$(q '.securityContext.runAsNonRoot')"
uid=$(q '.securityContext.runAsUser')   # compared in the shell: `>` in a yq expression needs a newer yq than CI has
check "the pod's user is not root" "true" "$([ "${uid:-0}" -gt 0 ] 2>/dev/null && echo true || echo false)"
check "the workspace is group-writable for that user (fsGroup)" "$(q '.securityContext.runAsUser')" "$(q '.securityContext.fsGroup')"
check "the default seccomp profile" "RuntimeDefault" "$(q '.securityContext.seccompProfile.type')"
check "read-only root filesystem" "true" "$(q '.container.securityContext.readOnlyRootFilesystem')"
check "no privilege escalation" "false" "$(q '.container.securityContext.allowPrivilegeEscalation')"
check "every capability dropped" '["ALL"]' "$(j '.container.securityContext.capabilities.drop')"
check "the main container writes only the workspace, scratch space and the python overlay" \
  "/tmp /usr/local /workspace " "$(q '.container.volumeMounts[].mountPath' | sort | tr '\n' ' ')"
check "no GitHub token, registry secret or lake token mounted" "0" \
  "$(yq "${R} | .. | select(tag == \"!!str\")" "$T/default.yaml" | grep -cE 'github-token|registry-auth|kaos-lake')"
check "the overlay init container is not root and has no capabilities" '{"runAsNonRoot":true,"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}' \
  "$(j '.initContainers[] | select(.name == "python-overlay") | .securityContext')"
check "the overlay is copied from the engine image the render runs" "true" \
  "$([ "$(q '.initContainers[] | select(.name == "python-overlay") | .image')" = "$(q '.container.image')" ] && echo true || echo false)"
check "the pod carries the label the network policy selects" "render" "$(q '.metadata.labels."platform.kubecore.io/ci-pod"')"

# ── the network policy ───────────────────────────────────────────────────
NP='select(.kind == "NetworkPolicy" and .metadata.name == "ci-render-egress")'
check "no network policy unless asked for" "0" "$(yq "${NP}" "$T/default.yaml" | grep -c .)"
check "the policy selects the render pod" "render" "$(yq "${NP} | .spec.podSelector.matchLabels.\"platform.kubecore.io/ci-pod\"" "$T/policy.yaml")"
check "egress only" '["Egress"]' "$(yq -o=json -I=0 "${NP} | .spec.policyTypes" "$T/policy.yaml")"
check "the metadata endpoint and every private range are outside the internet rule" \
  '["10.0.0.0/8","172.16.0.0/12","192.168.0.0/16","169.254.0.0/16"]' \
  "$(yq -o=json -I=0 "${NP} | .spec.egress[] | select(.ports[0].port == 443 and .to[0].ipBlock.cidr == \"0.0.0.0/0\") | .to[0].ipBlock.except" "$T/policy.yaml")"
check "the internet rule is https only" "1" \
  "$(yq "${NP} | .spec.egress[] | select(.to[0].ipBlock.cidr == \"0.0.0.0/0\") | .ports[]" "$T/policy.yaml" | grep -c 'port: 443')"
check "the Kubernetes API is allowed at the configured address, on 443" "172.16.15.130/32 443" \
  "$(yq "${NP} | .spec.egress[] | select(.to[0].ipBlock.cidr == \"172.16.15.130/32\") | .to[0].ipBlock.cidr + \" \" + (.ports[0].port | tostring)" "$T/policy.yaml")"
check "DNS is allowed" "true" \
  "$(yq "${NP} | .spec.egress[].ports[] | select(.port == 53)" "$T/policy.yaml" | grep -q 'port: 53' && echo true || echo false)"
check "nothing else is allowed (4 egress rules: dns, node-local dns, api, internet)" "4" "$(yq "${NP} | .spec.egress | length" "$T/policy.yaml")"
if helm template t "$CHART" --set github.org=acme --set renderPods.networkPolicy.enabled=true > /dev/null 2> "$T/err"; then
  check "an enabled policy without the API address is refused at render time" "refused" "rendered"
else
  check "an enabled policy without the API address is refused at render time" "true" \
    "$(grep -q 'kubeApiCIDRs' "$T/err" && echo true || echo false)"
fi

# The copy must not touch the volume's own root directory: on a cluster that root belongs to root, and a
# non-root "cp -a /usr/local/. /overlay/" ends 1 on its times after copying everything (seen on dev, chart
# 0.14.2). Rootless podman does not reproduce that, so the shape of the command is asserted as well.
check "the overlay copy copies the entries, never the mount root itself" "true" \
  "$(q '.initContainers[] | select(.name == "python-overlay") | .args[0]' | grep -q -- '-mindepth 1 -maxdepth 1 -exec cp -a --no-preserve=ownership -t /overlay/' && echo true || echo false)"

# ── executed: pip install under a read-only root filesystem, as an unprivileged user ──
IMG="${OVERLAY_IMAGE:-docker.io/library/python:3.12-slim}"
if command -v podman > /dev/null && podman image exists "$IMG" 2> /dev/null; then
  V="ci-render-overlay-$$"
  podman volume create "$V" > /dev/null
  U="--user 65532:65532 --cap-drop=ALL --security-opt no-new-privileges --security-opt label=disable --read-only --tmpfs /tmp"
  # shellcheck disable=SC2086
  # The volume as the kubelet hands it over with fsGroup: its root belongs to root, the group may write.
  # (Mounting it ":U" made the test user its owner and hid a failing copy.) The command is the rendered one.
  podman run --rm --security-opt label=disable -v "$V:/overlay" "$IMG" sh -c 'chown root:65532 /overlay && chmod 2775 /overlay'
  COPY=$(q '.initContainers[] | select(.name == "python-overlay") | .args[0]')
  # shellcheck disable=SC2086
  OUT=$(podman run --rm $U -e HOME=/tmp -v "$V:/overlay" "$IMG" sh -c "$COPY" 2>&1 \
    && podman run --rm $U -e HOME=/tmp -e PIP_NO_CACHE_DIR=1 -e PYTHONDONTWRITEBYTECODE=1 -v "$V:/usr/local" "$IMG" sh -c '
      python -m pip freeze --exclude-editable > /tmp/c.txt && echo six > /tmp/r.txt &&
      python -m pip install --quiet --disable-pip-version-check -c /tmp/c.txt -r /tmp/r.txt &&
      python -I -c "import six" && echo installed; touch /etc/x 2>&1 | grep -o "Read-only file system"' 2>&1)
  podman volume rm -f "$V" > /dev/null
  check "a dependency installs and imports with a read-only root filesystem" "installed Read-only file system" "$(echo "$OUT" | tr '\n' ' ' | sed 's/ $//')"
else
  echo "SKIP: executed overlay check (needs podman and ${IMG})"
fi

echo "passed: ${PASSED}, failed: ${FAILED}"
exit "$FAILED"
