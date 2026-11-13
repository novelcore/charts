#!/usr/bin/env bash
# What a developer's Dockerfile RUN step can read inside the image build (PRD novelcore/kaos#1911).
# kaniko runs the Dockerfile in the main container of `build-push`, so every file that container
# mounts and every credential its pod can reach is readable by tenant code. Usage (repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/build-isolation/run.sh
#
# Rendered-chart assertions only. Needs helm and yq v4. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
check() { # check DESCRIPTION EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then PASSED=$((PASSED + 1)); echo "PASS: $1"
  else FAILED=$((FAILED + 1)); echo "FAIL: $1"; echo "  expected: $2"; echo "  actual:   $3"; fi
}

RENDERED=$(mktemp); trap 'rm -f "$RENDERED"' EXIT
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

BUILD='select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "build-push")'
mounts() { yq "${BUILD} | .container.volumeMounts[].mountPath" "$RENDERED" | sort | tr '\n' ' '; }

# The main container is kaniko: tenant RUN steps execute in it. It needs the build workspace and
# the docker config the docker-config init container wrote; nothing else. The registry secret
# (basic-auth password of the in-cluster registry) is read by the init container only.
check "kaniko mounts only the workspace and the docker config" "/kaniko/.docker /workspace " "$(mounts)"
check "the registry secret is still mounted in the docker-config init container" \
  "/etc/registry-auth" "$(yq "${BUILD} | .initContainers[] | select(.name == \"docker-config\") | .volumeMounts[] | select(.name == \"registry-auth\") | .mountPath" "$RENDERED")"
check "no GitHub token in the kaniko container" "0" \
  "$(yq "${BUILD} | .container.volumeMounts[] | select(.name == \"github-token\")" "$RENDERED" | grep -c . )"
check "no Kubernetes token in the build pod" "true" \
  "$(yq "${BUILD} | .podSpecPatch" "$RENDERED" | grep -q 'automountServiceAccountToken: false' && echo true || echo false)"

echo "passed: ${PASSED}, failed: ${FAILED}"
exit "$FAILED"
