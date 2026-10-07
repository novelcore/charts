#!/bin/sh
# Render assertions for the PRD 695 CI-secrets wiring in ci-build and
# ci-rc-build. Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/render/run.sh /tmp/rendered.yaml
#
# Needs yq v4 on PATH. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="${HERE}/../../files/ci-secrets-prep.sh"
FAILED=0
PASSED=0

# expect_eq ACTUAL EXPECTED DESCRIPTION
expect_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $3"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"
  fi
}

# q WORKFLOW EXPR: evaluate EXPR against WORKFLOW's build-push template.
q() {
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\") | .spec.templates[] | select(.name == \"build-push\") | $2" "$RENDERED"
}

for wf in ci-build ci-rc-build; do
  expect_eq "$(q "$wf" '.volumes[] | select(.name == "ci-secrets-project") | .secret.secretName + " optional=" + (.secret.optional | tostring)')" \
    '{{workflow.parameters.project_name}}-ci-secrets optional=true' "$wf: optional {project}-ci-secrets volume"
  expect_eq "$(q "$wf" '.volumes[] | select(.name == "ci-secrets-app") | .secret.secretName + " optional=" + (.secret.optional | tostring)')" \
    '{{workflow.parameters.project_name}}-{{workflow.parameters.app_name}}-ci-secrets optional=true' "$wf: optional {project}-{app}-ci-secrets volume"
  expect_eq "$(q "$wf" '.volumes[] | select(.name == "kaniko-secrets") | .emptyDir.medium')" \
    Memory "$wf: kaniko-secrets is memory-backed"
  expect_eq "$(q "$wf" '.initContainers | map(.name) | join(",")')" \
    ci-secrets-prep "$wf: exactly one init container, ci-secrets-prep"
  expect_eq "$(q "$wf" '.initContainers[0].args[0]')" "$(cat "$SCRIPT")" \
    "$wf: init container runs files/ci-secrets-prep.sh verbatim"
  expect_eq "$(q "$wf" '.initContainers[0].volumeMounts | map(.name + "=" + .mountPath) | sort | join(",")')" \
    'ci-secrets-app=/etc/ci-secrets/app,ci-secrets-project=/etc/ci-secrets/project,kaniko-config=/kaniko/.docker,kaniko-secrets=/kaniko/secrets,registry-auth=/etc/registry-auth' \
    "$wf: init container mounts"
  expect_eq "$(q "$wf" '.container.volumeMounts | map(.name + "=" + .mountPath + ":" + ((.readOnly // false) | tostring)) | sort | join(",")')" \
    'kaniko-config=/kaniko/.docker:false,kaniko-secrets=/kaniko/secrets:true,workspace=/workspace:false' \
    "$wf: kaniko sees only the laid-out copy, read-only"
  writes=$(q "$wf" '.container.args[0]' | grep -c '/kaniko/.docker/config.json <<')
  expect_eq "$writes" 0 "$wf: docker config is written only by ci-secrets-prep"
done

# Scope guard: ML templates are out of scope for PRD 695.
ml_hits=$(yq 'select(.kind == "ClusterWorkflowTemplate" and (.metadata.name | test("^ml-")))' "$RENDERED" | grep -c 'ci-secrets')
expect_eq "$ml_hits" 0 "ml-* templates carry no ci-secrets wiring"

# A Zot-less pool never renders ci-registry-auth; every template that mounts it must
# tolerate its absence or the kubelet never starts the pod (#1057 for ci-*, and the ML
# templates on 2026-10-07, e2e-suite-ml-jq4vp).
for wf in ci-build ci-rc-build ml-ci-build ml-ci-rc-build; do
  expect_eq "$(yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$wf\") | .spec.volumes[] | select(.name == \"registry-auth\") | .secret.optional" "$RENDERED")" \
    true "$wf: registry-auth (ci-registry-auth) volume is optional"
done
# ml-ci-build's docker-config step: GAR without the Secret is a keyless no-op, not a crash.
dc=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "build-push") | .initContainers[] | select(.name == "docker-config") | .args[0]' "$RENDERED")
expect_eq "$(printf '%s' "$dc" | grep -c 'cat /etc/registry-auth/username 2>/dev/null || true')" 1 \
  "ml-ci-build docker-config: a missing ci-registry-auth does not abort under set -e"
expect_eq "$(printf '%s' "$dc" | grep -c '\*-docker.pkg.dev\*)')" 1 \
  "ml-ci-build docker-config: GAR without the Secret takes the keyless branch"

echo "render: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
