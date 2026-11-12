#!/usr/bin/env bash
# An old app is refused before anything is recorded (PRD novelcore/kaos#1911 AC-01, T-05, F-05).
#
# The wave changes every app: pipeline.py gets kind=, inputs= and produces= (outputs= and hpc_time_limit=
# are gone), a step takes no arguments, and kaos-lib is 0.5 or newer. No app is moved: an app made before it
# is created again from the template. It must fail BEFORE anything is recorded, with the engine's one-sentence
# reason and "Create it again from the template.", where its engineer already looks; the pipeline it had keeps
# running. The parts are tested where their harness is:
#
#   tests/engine-ci      detect-steps refuses a kaos-lib older than 0.5; hera-render reports the engine's
#                        refusal; engine-record posts the commit status and writes the one-attempt record
#   tests/engine-drift   ml-ci-reconcile builds a refused commit once, not every poll
#   tests/render-order   the render is a group of its own before the image builds
#   tests/kaos-lib       the kaos-lib check itself and the bump pull request
#   tests/engine         the step table (a render without one is not from an engine on the step contract)
#   tests/connections    the step table and the pickers on real engine output
#
# This suite holds the rest: the pull request check's status for an old app, the wording
# (no platform internals, GitHub's 140 characters), where the step table is read, and, with a real
# engine, the whole refusal: the chart's own hera-render script run against apps on the old contract.
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/step-contract/run.sh /tmp/rendered.yaml
#
# With a real engine (local only; the CI image has no engine libraries):
#   ENGINE_PYTHON=<python with the kaos-pipeline-engine wheel of the step contract installed>
#   OLD_ENGINE_PYTHON=<python with a kaos-pipeline-engine wheel from before it>          (optional)
#   OLD_APPS="<dir> <dir>"   checkouts of apps still on the old contract, e.g. a template  (optional)
#   ENGINE_WHEEL=<the kaos_pipeline_engine wheel file of ENGINE_PYTHON's engine>         (optional): the
#     whole render path of an app on the contract: hera-render, then hera-enhance-commit's enhance (the
#     wheel served from localhost and verified), the step table, the pickers from a fake catalog, the gate
#
# Needs yq v4, jq, python3 + PyYAML. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
APPS="${HERE}/../connections/fixtures/apps"
FAILED=0
PASSED=0
SKIPPED=0
STATUS_TEXT="Not built: this app was made before the current pipelines. Create it again from the template."
INTERNALS="Argo argo workflow Workflow namespace cluster kubectl ConfigMap gitops Kubernetes pod"

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}
expect_not() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  unexpected: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}
skip() { SKIPPED=$((SKIPPED + 1)); echo "SKIP: $1"; }
BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT

script() {  # script WORKFLOW TEMPLATE: the main container's script of a template
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")
      | .spec.templates[] | select(.name == \"$2\") | .container.args[0]" "$RENDERED"
}

# ── the wording ──────────────────────────────────────────────────────────────

expect_eq "$(grep -c -F "$STATUS_TEXT" "$RENDERED")" "2" "the old-app commit status is one text, used by the build and by the pull request check"
expect_eq "$(( ${#STATUS_TEXT} <= 140 ))" "1" "it fits GitHub's 140 characters (${#STATUS_TEXT})"
REFUSAL_FN=$(script ml-ci-build hera-render | awk '/^old_app\(\) \{/{f=1} f{print} f&&/^}/{exit}')
expect_has "$REFUSAL_FN" "Create it again from the template." "the report section says to create the app again"
expect_not "$REFUSAL_FN" "http" "... and links no guide (no app is moved)"
for WORD in $INTERNALS; do
  expect_not "$STATUS_TEXT $REFUSAL_FN" "$WORD" "what the app's engineer reads does not name the platform's internals ($WORD)"
done
expect_eq "$(script ml-ci-build detect-steps | grep -c '^old_app() {')" "1" "detect-steps reports the same way (a kaos-lib older than 0.5)"
expect_eq "$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "engine-record") | .container.volumeMounts[] | select(.name == "workspace") | .readOnly' "$RENDERED")" \
  "true" "engine-record reads the refusal from the workspace, read-only"
expect_has "$(script ml-ci-build report)" 'if [ -s /workspace/report-extra.md ]; then cat /workspace/report-extra.md' "the report comment carries the section the refused step left"

# ── where the step table is read ─────────────────────────────────────────────

for pair in "ml-ci-build hera-enhance-commit" "ml-ci-pr-render hera-enhance-gate"; do
  set -- $pair
  SRC=$(script "$1" "$2")
  pos() { printf '%s\n' "$SRC" | grep -n -m1 -F -- "$1" | cut -d: -f1; }
  P_STAMP=$(pos 'engine.py stamp'); P_STEPS=$(pos 'engine.py steps --wft /workspace/out/workflow-template.yaml'); P_GATE=$(pos 'GATE OK')
  [ -n "$P_STEPS" ] && [ "$P_STAMP" -lt "$P_STEPS" ] && [ "$P_STEPS" -lt "$P_GATE" ] \
    && expect_eq ok ok "$2: the step table is read after the enhance and before the gate (set -e: a render without one stops here)" \
    || expect_eq "stamp=$P_STAMP steps=${P_STEPS:-absent} gate=$P_GATE" "increasing" "$2: where the step table is read"
done

# ── the pull request check of an app that has not moved ──────────────────────

STATUS_SRC="${BASE_TMP}/pr-status.src"; script ml-ci-pr-render status > "$STATUS_SRC"
run_pr_status() {  # run_pr_status STATE DESCRIPTION [refused]
  T=$(mktemp -d "${BASE_TMP}/pr-XXXXXX"); mkdir -p "$T/bin" "$T/workspace"; printf 'token' > "$T/token"
  printf '2 steps, 9 KiB' > "$T/workspace/summary"
  [ "${3:-}" = refused ] && printf "step 'x' has no kind=.\n\",\"state\":\"success\n" > "$T/workspace/old-app"
  cat > "$T/bin/curl" <<CURLEOF
#!/usr/bin/env bash
while [ \$# -gt 0 ]; do [ "\$1" = -d ] && printf '%s' "\$2" > "$T/payload"; shift; done
CURLEOF
  chmod +x "$T/bin/curl"
  sed -e "s#{{workflow.parameters.repo_url}}#https://github.com/org/proj-app1.git#g" -e "s#{{workflow.parameters.commit_sha}}#abc#g" \
      -e "s#{{inputs.parameters.state}}#$1#g" -e "s#{{inputs.parameters.description}}#$2#g" \
      -e "s#{{workflow.namespace}}#ci#g" -e "s#{{workflow.name}}#wf#g" -e "s#{{workflow.uid}}#u#g" \
      -e "s#/workspace#${T}/workspace#g" -e "s#/etc/github-token/token#${T}/token#g" "$STATUS_SRC" > "$T/status.sh"
  OUT=$(PATH="$T/bin:$PATH" sh "$T/status.sh" 2>&1); RC=$?
  PAYLOAD=$(cat "$T/payload" 2>/dev/null)
}
run_pr_status failure "WorkflowTemplate render FAILED" refused
expect_eq "$RC" "0" "pull request check (old app): the status step runs"
expect_eq "$(printf '%s' "$PAYLOAD" | jq -r '.state + "|" + .context + "|" + .description')" "failure|wft-render|${STATUS_TEXT}" \
  "pull request check (old app): the check fails with why and what to do"
expect_eq "$(printf '%s' "$PAYLOAD" | jq -r '.target_url // "none"')" "none" "pull request check (old app): no guide is linked (the run report is, when the platform has an address for it)"
expect_eq "$(printf '%s' "$PAYLOAD" | jq -r 'keys | join(",")')" "context,description,state" "pull request check (old app): nothing the render wrote reaches the request (the description is the chart's text)"
run_pr_status failure "WorkflowTemplate render FAILED"
expect_eq "$(printf '%s' "$PAYLOAD" | jq -r '.description')" "WorkflowTemplate render FAILED" "pull request check: any other failure keeps its own description"
run_pr_status success "@/workspace/summary" refused
expect_eq "$(printf '%s' "$PAYLOAD" | jq -r '.state + "|" + .description')" "success|2 steps, 9 KiB" "pull request check: a render that succeeded is never reported as an old app"
expect_eq "$(yq 'select(.metadata.name == "ml-ci-pr-render") | .spec.templates[] | select(.name == "ml-ci-pr-render") | .steps[][] | select(.name == "hera-render") | .templateRef.template' "$RENDERED")" \
  "hera-render" "pull request check: it renders with the build's hera-render, so it refuses the same apps the same way"

# ── with a real engine: the chart's hera-render against apps on the old contract ──

RENDER_SRC="${BASE_TMP}/render.src"; script ml-ci-build hera-render > "$RENDER_SRC"
# real_render PYTHON APP_DIR [PROFILE]: the hera-render script as rendered, `python` being PYTHON.
real_render() {
  T=$(mktemp -d "${BASE_TMP}/real-XXXXXX"); mkdir -p "$T/bin" "$T/workspace"
  cp -r "$2" "$T/workspace/repo"; rm -rf "$T/workspace/repo/out" "$T/workspace/repo/.git"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$1" > "$T/bin/python"; chmod +x "$T/bin/python"
  { echo 'set -e'; sed -e "s#/tmp/#$T/#g" -e "s#/workspace#$T/workspace#g" -e "s#{{inputs.parameters.engine_image}}#local-engine#g" "$RENDER_SRC"; } > "$T/render.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" ENGINE_PROFILE="${3:-hera}" sh "$T/render.sh" 2>&1); RC=$?
  NM=$(cat "$T/workspace/old-app" 2>/dev/null)
}
# old_app NAME PIPELINE_BODY: the hera fixture app with a pipeline.py from before the step contract.
old_app() {
  mkdir -p "${BASE_TMP}/apps"; rm -rf "${BASE_TMP}/apps/$1"; cp -r "${APPS}/hera" "${BASE_TMP}/apps/$1"
  { printf 'from pathlib import Path\nfrom kubecore.authoring import pipeline, step\nwith pipeline("ml-pipeline") as p:\n'
    printf '%s\n' "$2"
    printf 'p.write(Path(__file__).parent / "out" / "raw-workflow-template.yaml")\n'; } > "${BASE_TMP}/apps/$1/pipeline.py"
}
refused_like() {  # refused_like LABEL EXPECTED_TEXT: the asserts every refused app must pass
  expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "$1: the render fails"
  expect_eq "$(ls "$T/workspace/out/raw-workflow-template.yaml" 2>/dev/null)" "" "$1: nothing is rendered, so nothing can be enhanced, committed or built"
  expect_has "$NM" "$2" "$1: the report says what to change"
  expect_not "$NM" "https://" "$1: ... with no address in it"
  expect_not "$NM" "Create it again" "$1: ... and without the old-app sentence (the chart says it once)"
  expect_not "$NM" "Error: " "$1: ... and without the exception name"
  expect_has "$(cat "$T/workspace/report-extra.md" 2>/dev/null)" "Create it again from the template." "$1: the report says to create the app again"
  expect_not "$(cat "$T/workspace/report-extra.md" 2>/dev/null)" "http" "$1: ... and links no guide"
  expect_has "$OUT" "kaos-ci: OLD APP: " "$1: one line of the step log says so"
}

if [ -z "${ENGINE_PYTHON:-}" ]; then
  skip "the real-engine cases need ENGINE_PYTHON (a python with the kaos-pipeline-engine wheel of the step contract)"
else
  real_render "$ENGINE_PYTHON" "${APPS}/hera" hera
  expect_eq "$RC" "0" "real engine, an app on the step contract (hera shape): renders"
  expect_eq "$(ls "$T/workspace/old-app" 2>/dev/null)" "" "real engine, an app on the step contract: is not reported as not moved"
  expect_has "$(cat "$T/workspace/out/raw-workflow-template.yaml" 2>/dev/null)" "KAOS_STEP_CONTEXT" "real engine: ... and its steps get the step context"
  real_render "$ENGINE_PYTHON" "${APPS}/yolo" yolo
  expect_eq "$RC" "0" "real engine, an app on the step contract (yolo shape): renders"

  old_app no-kind '    step("hello-world", reads=["experiment", "dataset"])'
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/no-kind"
  refused_like "real engine, a step without kind= (every app from before the step contract)" "step 'hello-world' has no kind="
  old_app outputs '    step("hello-world", kind="transform", reads=["experiment"], outputs=["hello-result"])'
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/outputs"
  refused_like "real engine, outputs=" "step 'hello-world': outputs= is no longer part of step()."
  old_app time-limit '    step("hello-world", kind="train", reads=["experiment"], hpc_time_limit="12h")'
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/time-limit"
  refused_like "real engine, hpc_time_limit=" "step 'hello-world': hpc_time_limit= is no longer part of step()."

  old_app disk '    step("hello-world", kind="transform", reads=["experiment"], disk="20Gi")'
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/disk"
  refused_like "real engine, disk=" "step 'hello-world': disk is no longer declared"
  old_app platform '    step("hello-world", kind="transform", reads=["experiment"])'
  printf '  - platform: live\n' >> "${BASE_TMP}/apps/platform/config/config.yaml"
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/platform"
  refused_like "real engine, the removed platform config group" "config/config.yaml lists"

  # An app that carries a copy of the engine (a kubecore/ folder): this chart reads nothing of it (engine.py no
  # longer takes its profile from it), so the engine's own refusal is what the app gets: the old-app status, and
  # nothing rendered, so nothing recorded.
  old_app own-engine '    step("hello-world", kind="transform", reads=["experiment"])'
  mkdir -p "${BASE_TMP}/apps/own-engine/kubecore"; printf 'x = 1\n' > "${BASE_TMP}/apps/own-engine/kubecore/derive_tree.py"
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/own-engine"
  refused_like "real engine, an app with a kubecore/ folder of its own" "a kubecore/ folder of its own"

  # Not an old app: a mistake in a pipeline on the step contract is the engine's own error, nothing more.
  old_app unknown-kind '    step("hello-world", kind="training", reads=["experiment"])'
  real_render "$ENGINE_PYTHON" "${BASE_TMP}/apps/unknown-kind"
  expect_eq "$([ "$RC" != 0 ] && echo failed)/$NM" "failed/" "real engine, a wrong kind= on a moved app: fails the render and is not reported as an app that has not moved"
  expect_has "$OUT" "kind='training' is not a step kind" "real engine: ... the engine's message is in the step log"

  for DIR in ${OLD_APPS:-}; do
    real_render "$ENGINE_PYTHON" "$DIR" "$( { [ -f "$DIR/config/quantization.yaml" ] || [ -d "$DIR/config/quantization" ]; } && echo yolo || echo hera)"
    refused_like "real engine, $(basename "$DIR") as it is today" "step '"
    echo "      $(basename "$DIR"): ${NM}"
  done

  if [ -z "${ENGINE_WHEEL:-}" ]; then
    skip "the whole render path of an app on the contract needs ENGINE_WHEEL (the engine's wheel file)"
  else
    # hera-render, then the part of hera-enhance-commit from the engine fetch to the gate, as rendered.
    real_render "$ENGINE_PYTHON" "${APPS}/yolo" yolo
    PORT=18931
    mkdir -p "$T/www"; cp "$ENGINE_WHEEL" "$T/www/engine.whl"
    cat > "$T/server.py" <<'PY'
import http.server, json, sys
CATALOG = {"datasets": [{"name": "dataset-cars", "versions": [{"tag": "v2"}]}, {"name": "dataset-default", "default": True, "versions": []}]}
class H(http.server.SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/kaos/v1/catalog":
            self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(CATALOG).encode()); return
        super().do_GET()
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), lambda *a: H(*a, directory=sys.argv[2])).serve_forever()
PY
    python3 "$T/server.py" "$PORT" "$T/www" & SERVER=$!
    sleep 1
    python3 - "${HERE}/../connections/fixtures/contexts/yolo-pipeline.yaml" "$T/context.yaml" "$PORT" <<'PY'
import sys, yaml
ctx = yaml.safe_load(open(sys.argv[1]))
ctx["lakefs"]["endpoint"] = f"http://127.0.0.1:{sys.argv[3]}"
yaml.safe_dump(ctx, open(sys.argv[2], "w"), sort_keys=False)
PY
    printf 'pod-token' > "$T/token"
    { echo 'set -e'
      script ml-ci-build hera-enhance-commit | awk "/cat > \/tmp\/engine.py <</ {on=1} on {print} on && /^GATEEOF/ {exit}"
    } | sed -e "s#/tmp/#$T/#g" -e "s#/workspace#$T/workspace#g" -e "s#/var/run/secrets/kaos-lake/token#$T/token#g" > "$T/enhance.sh"
    ENGINE_JSON=$(jq -nc --arg w "http://127.0.0.1:${PORT}/engine.whl" --arg s "$(sha256sum "$ENGINE_WHEEL" | cut -d' ' -f1)" \
      '{version: "v0.5.0", image: "reg.example/kaos-pipeline-engine:v0.5.0", wheel: $w, wheel_sha256: $s, profile: "yolo"}')
    OUT=$(cd "$T" && env -u PYTHONPATH ENGINE_JSON="$ENGINE_JSON" sh "$T/enhance.sh" 2>&1); RC=$?
    kill "$SERVER" 2>/dev/null
    expect_eq "$RC" "0" "real engine, the whole render path: render, enhance with the verified wheel, step table, pickers, gate"
    [ "$RC" = 0 ] || printf '%s\n' "$OUT" | tail -15
    expect_eq "$(jq -r '[.[] | .inputs[]] | unique | join(",")' "$T/steps.json" 2>/dev/null)" "calibration,dataset" "real engine: the step table names the inputs of the pipeline"
    WFT="$T/workspace/out/workflow-template.yaml"
    for FIELD in calibration dataset; do
      expect_eq "$(yq ".spec.arguments.parameters[] | select(.name == \"$FIELD\") | .value + \" | \" + (.enum | join(\",\"))" "$WFT")" \
        "dataset-default@latest | dataset-default@latest,dataset-cars@v2,dataset-cars@latest" "real engine: the field of input ${FIELD} is a picker with the catalog's choices, its default kept"
    done
    expect_eq "$(yq '[.spec.arguments.parameters[] | select(.enum and (.enum | contains(["dataset-cars@latest"]))) | .name] | join(",")' "$WFT")" "dataset,calibration" "real engine: no other field got the catalog's choices"
    expect_eq "$(yq '[.spec.arguments.parameters[].name | select(. == "plan" or . == "pipeline-version")] | length' "$WFT")" "0" "real engine: the form has no reserved key"
    expect_eq "$(yq '.metadata.annotations."platform.kubecore.io/engine-version"' "$WFT")" "v0.5.0" "real engine: the WorkflowTemplate is stamped with the engine"
    expect_has "$OUT" "GATE OK" "real engine: the gate passes"
  fi

  if [ -z "${OLD_ENGINE_PYTHON:-}" ]; then
    skip "the old-engine cases need OLD_ENGINE_PYTHON (a python with a kaos-pipeline-engine wheel from before the step contract)"
  else
    # The other direction: an app that has moved is never rendered by an engine from before the step contract,
    # and what such an engine renders of an old app is never committed by this chart.
    real_render "$OLD_ENGINE_PYTHON" "${APPS}/hera" hera
    expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "old engine, an app on the step contract: the render fails"
    expect_eq "$(ls "$T/workspace/out/raw-workflow-template.yaml" 2>/dev/null)" "" "old engine, an app on the step contract: nothing is rendered"
    expect_eq "$NM" "" "old engine: ... and the app is not told to migrate (it has)"
    old_app old-app '    step("hello-world", reads=["experiment", "dataset"])'
    real_render "$OLD_ENGINE_PYTHON" "${BASE_TMP}/apps/old-app"
    expect_eq "$RC" "0" "old engine, an old app: the old engine still renders it"
    python3 -I "${CHART}/files/engine.py" steps --wft "$T/workspace/out/raw-workflow-template.yaml" > "$T/steps.json" 2> "$T/steps.err"
    expect_eq "$?" "6" "old engine, an old app: ... and the chart refuses the render (no step table), so it is never committed"
    expect_has "$(cat "$T/steps.err")" "not on the step contract" "old engine: ... saying the engine is not on the step contract"
  fi
fi

echo "step-contract: ${PASSED} passed, ${FAILED} failed, ${SKIPPED} skipped"
exit "$FAILED"
