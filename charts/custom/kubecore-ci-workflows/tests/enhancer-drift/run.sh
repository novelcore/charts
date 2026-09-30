#!/usr/bin/env bash
# Tests for the enhancer-drift re-render (kubecore-operator#1199): ml-ci-build
# records the platform enhancer it rendered with (`enhancer-ref` in the app's
# pipeline-images), and ml-ci-reconcile re-renders an app whose recorded ref is
# not the chart's pin. Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/enhancer-drift/run.sh /tmp/rendered.yaml
#
# The scripts under test are EXECUTED, not grepped: check-drift is extracted
# from the rendered ml-ci-reconcile and run against stub kubectl/curl, and the
# render step's pipeline-images writer is extracted from ml-ci-build and run on
# fixture files. Needs yq v4, jq, python3 + PyYAML, and helm for the one
# render-time refusal case. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
PIN=$(yq '.platformEnhancer.ref' "${CHART}/values.yaml")
OLD_PIN=0123456789abcdef0123456789abcdef01234567
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APP=app1

expect_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $3"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"
  fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# ── check-drift ──────────────────────────────────────────────────────────────

DRIFT_SRC="${BASE_TMP}/check-drift.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .container.args[0]' \
  "$RENDERED" > "$DRIFT_SRC"

GITOPS_CONTEXT='kind: ConfigMap  # the gitops pipeline-context.yaml, as fetched raw'
CTX_SHA=$(printf '%s\n' "$GITOPS_CONTEXT" | sha256sum | cut -c1-64)

# new_case: a sandbox where every OTHER input of check-drift is in sync — HEAD
# built, context-sha current, the cpu budget and the ml environment matching the
# live WFT — so the enhancer is the only thing a case varies.
new_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX")
  mkdir -p "$T/bin"
  printf 'token' > "$T/token"
  printf '%s\n' "$GITOPS_CONTEXT" > "$T/gitops-context.yaml"
  printf '{"items": []}' > "$T/workflows.json"
  cat > "$T/context.yaml" <<'EOF'
computeClasses:
  cpu:
    name: cpu-small
    allocatable:
      cpu: 3
      memoryGiB: 13
mlEnvironment:
  name: train
EOF
  cat > "$T/wft.json" <<'EOF'
{"spec": {"arguments": {"parameters": [{"name": "step-a-mem", "value": "13Gi"}]},
          "templates": [{"name": "step-a",
                         "nodeSelector": {"platform.kubecore.io/environment": "train"}}]}}
EOF
  cm "$PIN"
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get workflows"*) cat "$T/workflows.json" ;;
  *"get configmap ${APP}-pipeline-images"*)
    [ -f "$T/cm.json" ] || { echo "Error from server (NotFound): not found" >&2; exit 1; }
    cat "$T/cm.json" ;;
  *"get configmap ${APP}-pipeline-context"*) cat "$T/context.yaml" ;;
  *"get workflowtemplate ${APP}-pipeline"*) cat "$T/wft.json" ;;
  *) echo "stub kubectl: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"/commits/dev"*) printf '{"sha": "%s"}' "$HEAD_SHA" ;;
  *"pipeline-context.yaml"*) cat "$T/gitops-context.yaml" ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$T/bin/kubectl" "$T/bin/curl"
}

# cm REF [CONTEXT_SHA]: the app's pipeline-images; REF "-" omits enhancer-ref,
# CONTEXT_SHA "-" omits context-sha.
cm() {
  jq -n --arg head "$HEAD_SHA" --arg ctx "${2:-$CTX_SHA}" --arg ref "$1" '
    {data: ({"last-built-sha": $head, "step-a": "reg/app:step-a-dev-v1-x-aaaaaaa"}
            + (if $ctx == "-" then {} else {"context-sha": $ctx} end)
            + (if $ref == "-" then {} else {"enhancer-ref": $ref} end))}' > "$T/cm.json"
}

# reconcile_build NAME PHASE FINISHED_AT PIN [APP]: one reconcile-submitted build.
reconcile_build() {
  jq --arg name "$1" --arg phase "$2" --arg fin "$3" --arg pin "$4" --arg app "${5:-$APP}" '
    .items += [{metadata: {name: $name, creationTimestamp: $fin,
                           labels: {"platform.kubecore.io/app": $app,
                                    "platform.kubecore.io/submitted-by": "ml-ci-reconcile",
                                    "platform.kubecore.io/enhancer-ref": $pin}},
                status: {phase: $phase, finishedAt: $fin}}]' \
    "$T/workflows.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/workflows.json"
}

# run_drift: check-drift with the Argo placeholders filled and its fixed paths
# moved into the sandbox. Sets OUT (stdout+stderr), NEEDS, RC.
run_drift() {
  sed -e "s#{{workflow.namespace}}#ci#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" \
      -e "s#{{workflow.parameters.project_name}}#proj#g" \
      -e "s#{{workflow.parameters.branch}}#dev#g" \
      -e "s#{{workflow.parameters.ci_namespace}}#ci#g" \
      -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" \
      -e "s#{{workflow.parameters.repo_url}}##g" \
      -e "s#{{workflow.parameters.ml_namespace}}#proj-train#g" \
      -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.workflow_template_path}}#kubeapps/${APP}/main/workflow-template.yaml#g" \
      -e "s#/tmp/#${T}/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" \
      "$DRIFT_SRC" > "$T/check-drift.sh"
  # DRIFT_SHELL: production runs this under the alpine image's busybox sh.
  OUT=$(PATH="$T/bin:$PATH" "${DRIFT_SHELL:-bash}" "$T/check-drift.sh" 2>&1); RC=$?
  NEEDS=$(cat "$T/needs_build" 2>/dev/null || echo "<unset>")
}

new_case; run_drift
expect_eq "$RC/$NEEDS" "0/false" "in sync: the recorded enhancer is the pin — no build"
expect_has "$OUT" "up to date" "in sync: reports up to date"

new_case; cm "$OLD_PIN"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "the pin moved: re-render"
expect_has "$OUT" "ENHANCER DRIFT" "the pin moved: says why"
expect_eq "$(cat "$T/head_sha")" "$HEAD_SHA" "the pin moved: builds the already-built HEAD (render only)"

new_case; cm "-"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "rendered before enhancer-ref was recorded: re-render once"

new_case; cm "-" "-"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "no context-sha (not a Hera render path): never enhancer drift"

new_case; cm "$OLD_PIN"; reconcile_build b1 Failed "$(ago 600)" "$PIN"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "a re-render at this pin failed 10 min ago: wait, do not storm"
expect_has "$OUT" "b1" "a recent failed re-render is named"

new_case; cm "$OLD_PIN"; reconcile_build b1 Succeeded "$(ago 300)" "$PIN"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "a re-render at this pin succeeded 5 min ago (ArgoCD not synced yet): wait"

new_case; cm "$OLD_PIN"; reconcile_build b1 Failed "$(ago 7200)" "$PIN"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "the last attempt at this pin is over an hour old: retry"

new_case; cm "$OLD_PIN"; reconcile_build b1 Failed "$(ago 600)" "$OLD_PIN"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "a recent failure at an OLDER pin does not hold back the new one"

new_case; cm "$OLD_PIN"; reconcile_build b1 Failed "$(ago 600)" "$PIN" other-app; run_drift
expect_eq "$RC/$NEEDS" "0/true" "another app's failed re-render does not hold this one back"

new_case; cm "$OLD_PIN"; reconcile_build b1 Failed "$(ago 7200)" "$PIN"
jq 'del(.items[0].status.finishedAt)' "$T/workflows.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/workflows.json"
run_drift
expect_eq "$RC/$NEEDS" "0/true" "no finishedAt: the attempt is dated by its creation — two hours old, retry"

new_case; cm "$OLD_PIN"; reconcile_build b1 Failed "not-a-time" "$PIN"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "an unreadable attempt time is unknown — unknown never submits work"

new_case; cm "$OLD_PIN"; reconcile_build b1 Running "" "$PIN"
jq '.items[0].status = {phase: "Running"} | .items[0].metadata.name = "ml-ci-build-reconciled-x"' \
  "$T/workflows.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/workflows.json"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "a build in flight: the existing in-flight guard still wins"

new_case; cm "$OLD_PIN"
jq '.data["last-built-sha"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$T/cm.json" > "$T/c.tmp" \
  && mv "$T/c.tmp" "$T/cm.json"; run_drift
expect_has "$OUT" "COMMIT DRIFT" "an unbuilt commit is still reported as commit drift first"

# ── submit-build carries the pin ──────────────────────────────────────────────

LABEL=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
            | .spec.templates[] | select(.name == "submit-build") | .resource.manifest' "$RENDERED" \
        | yq '.metadata.labels["platform.kubecore.io/enhancer-ref"]')
expect_eq "$LABEL" "$PIN" "a reconcile-submitted build is labelled with the pin it renders at"

# ── ml-ci-build records the enhancer it rendered with ─────────────────────────

RENDER_SRC="${BASE_TMP}/hera-enhance-commit.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.args[0]' \
  "$RENDERED" > "$RENDER_SRC"
expect_has "$(grep -F "<<'IMGEOF'" "$RENDER_SRC")" "\"${PIN}\"" \
  "the render passes the pinned enhancer ref to the pipeline-images writer"
WRITER="${BASE_TMP}/writer.py"
awk '/<<'"'"'IMGEOF'"'"'/{on=1; next} /^IMGEOF$/{on=0} on' "$RENDER_SRC" > "$WRITER"

W=$(mktemp -d "${BASE_TMP}/writer-XXXX")
wft() {
  python3 - "$W/wft.yaml" "$@" <<'PYEOF'
import sys, yaml
steps = sys.argv[2:]
yaml.safe_dump({"metadata": {"name": "app1-pipeline", "namespace": "proj-train"},
                "spec": {"arguments": {"parameters": [
                    {"name": f"image-{s}",
                     "valueFrom": {"configMapKeyRef": {"name": "app1-pipeline-images", "key": s}}}
                    for s in steps]}}}, open(sys.argv[1], "w"))
PYEOF
}
images_key() { python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1]))["data"]).get(sys.argv[2], "<absent>"))' "$W/images.yaml" "$1"; }
write() { python3 "$WRITER" "$W/wft.yaml" "$W/images.yaml" "$APP" "$CTX_SHA" "$1" 2>&1; }

cat > "$W/images.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: app1-pipeline-images, namespace: proj-train}
data: {last-built-sha: aaaa, context-sha: stale, step-a: "reg/app:step-a-1", step-b: "reg/app:step-b-1"}
EOF
wft step-a step-b
OUT=$(write "$PIN")
expect_eq "$(images_key enhancer-ref)" "$PIN" "a render records the enhancer it ran"
expect_eq "$(images_key context-sha)" "$CTX_SHA" "context-sha is still recorded beside it"

BEFORE=$(cat "$W/images.yaml"); OUT=$(write "$PIN")
expect_eq "$(cat "$W/images.yaml")" "$BEFORE" "re-rendering with the same enhancer rewrites nothing"
expect_has "$OUT" "already has" "re-rendering with the same enhancer says so"

wft step-a; OUT=$(write "$PIN")
expect_eq "$(images_key step-b)" "<absent>" "a step that left the render is pruned"
expect_eq "$(images_key enhancer-ref)" "$PIN" "enhancer-ref is never pruned as a stale step key"

OUT=$(write "$OLD_PIN")
expect_eq "$(images_key enhancer-ref)" "$OLD_PIN" "a render with another pin records that pin"

# ── the digest pin leaves the record alone ────────────────────────────────────

PATCH=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
            | .spec.templates[] | select(.name == "patch-images") | .container.args[0]' "$RENDERED")
expect_has "$PATCH" '[ "${KEY}" = "enhancer-ref" ] && continue' \
  "the digest-pin loop skips enhancer-ref (it is not an image)"

# ── the pin must be a commit ──────────────────────────────────────────────────

if command -v helm >/dev/null 2>&1; then
  REFUSAL=$(helm template t "$CHART" --set platformEnhancer.ref=main 2>&1 >/dev/null); RC=$?
  expect_eq "$RC" 1 "helm refuses a platformEnhancer.ref that is not a full commit sha"
  expect_has "$REFUSAL" "platformEnhancer.ref" "the refusal names the value"
else
  FAILED=$((FAILED + 1)); echo "FAIL: helm not on PATH — the pin-format case cannot run"
fi

echo "enhancer-drift: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
