#!/usr/bin/env bash
# The platform pipeline engine in the rendered chart (PRD-HPC-1461 D-79, F-50/F-51). The scripts are
# EXECUTED, not grepped: the engine decision of detect-steps (ml-ci-build) and detect-engine
# (ml-ci-pr-render), the tokenless engine render (hera-render-engine, stub interpreter), the enhance
# section of hera-enhance-commit in the three modes (legacy, shadow, engine) and its pipeline-images
# writer. files/engine.py itself: tests/engine (pytest). Branches covered: legacy unchanged, shadow
# equal / differs / engine render failed, engine, vendored modified, custom compose Dockerfile,
# no wheel pinned, wheel sha256 mismatch (fails closed, clear message). Usage (repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/engine-ci/run.sh /tmp/rendered.yaml
#
# Needs yq v4, jq, python3 + PyYAML. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
FAILED=0
PASSED=0
T=$(mktemp -d)
SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "${T:?}"' EXIT

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -6)" ;;
  esac
}
expect_not() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

FIX="python3 ${HERE}/fixture.py"
ML='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")'
PR='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")'
ml_script() { yq "$ML | .spec.templates[] | select(.name == \"$1\") | .container.args[0]" "$RENDERED"; }
pr_script() { yq "$PR | .spec.templates[] | select(.name == \"$1\") | .container.args[0]" "$RENDERED"; }
ml_tpl() { yq "$ML | .spec.templates[] | select(.name == \"$1\") | $2" "$RENDERED" | grep -v '^---$' | sed '/^$/d'; }
pr_tpl() { yq "$PR | .spec.templates[] | select(.name == \"$1\") | $2" "$RENDERED" | grep -v '^---$' | sed '/^$/d'; }

# ── a served fixture wheel ───────────────────────────────────────────────────────────────────
mkdir -p "$T/www"
SHA=$($FIX wheel "$T/www/engine.whl")
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" > "$T/http.log" 2>&1 &
SRV=$!
for _ in $(seq 1 50); do python3 -c "import urllib.request,sys; urllib.request.urlopen('http://127.0.0.1:$PORT/engine.whl')" 2>/dev/null && break; sleep 0.2; done
WHEEL_URL="http://127.0.0.1:$PORT/engine.whl"
ENGINE_IMAGE="reg.example/kaos-pool/kaos-pipeline-engine:v0.9.0"

# ── 1. detect-steps: the decision ────────────────────────────────────────────────────────────
ml_script detect-steps > "$T/detect-steps.sh"
S=$(grep -nF 'ENGINE (PRD-HPC-1461 D-79): which engine renders this app' "$T/detect-steps.sh" | cut -d: -f1)
E=$(grep -nF "echo \"engine: \$(jq -r '.reason'" "$T/detect-steps.sh" | cut -d: -f1)
[ -n "$S" ] && [ -n "$E" ] && sed -n "${S},${E}p" "$T/detect-steps.sh" > "$T/detect-seg.sh" \
  || { echo "FAIL: the ENGINE block of detect-steps was not found"; exit 1; }

# run_detect FRONTEND CONTEXT REPO [IMAGES]: sets OUT RC and C (the case directory).
run_detect() {
  C=$(mktemp -d "$T/detect-XXXX"); mkdir -p "$C/tmp"
  { echo "set -e"; echo "FRONTEND=$1; KL_CTX='$2'; IMAGES_PATH='${4:-}'"
    sed -e "s#/tmp/#$C/tmp/#g" -e "s#/workspace/repo#$3#g" "$T/detect-seg.sh"; } > "$C/detect.sh"
  OUT=$(cd "$C" && sh "$C/detect.sh" 2>&1); RC=$?
}
decision() { jq -r "$1" "$C/tmp/engine.json"; }

new_app() { A=$(mktemp -d "$T/app-XXXX"); $FIX app "$A" "$@"; }
new_ctx() { X=$(mktemp "$T/ctx-XXXX"); $FIX context "$X" "$@"; }
HITS_BEFORE=0
requests() { wc -l < "$T/http.log" | tr -d ' '; }

# legacy: no engine block, nothing downloaded, nothing fails
new_app; new_ctx --no-engine; B=$(requests); run_detect hera "$X" "$A"
expect_eq "$RC" "0" "legacy (no engine block): detect exits 0"
expect_eq "$(decision .mode)" "legacy" "legacy (no engine block): mode legacy"
expect_has "$(decision .reason)" "NoEngineBlock" "legacy (no engine block): the reason says so"
expect_eq "$(cat "$C/tmp/engine_mode")/$(cat "$C/tmp/engine_image")/$(cat "$C/tmp/engine_profile")" "legacy//" "legacy (no engine block): routing files say legacy, no image, no profile"
expect_eq "$(requests)" "$B" "legacy (no engine block): no download"

new_app; new_ctx --mode legacy --wheel "$WHEEL_URL" --sha256 "$SHA"; B=$(requests); run_detect hera "$X" "$A"
expect_eq "$(decision .mode)/$(decision .requested_mode)" "legacy/legacy" "legacy (mode legacy in the block): legacy"
expect_has "$(decision .reason)" "ModeLegacy" "legacy (mode legacy): the reason says so"
expect_eq "$(requests)" "$B" "legacy (mode legacy): the wheel is not downloaded"

new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; B=$(requests); run_detect kubeline "$X" "$A"
expect_eq "$(decision .mode)" "legacy" "a kubeline app is never rendered by the engine"
expect_has "$(decision .reason)" "NotHera" "kubeline: the reason says so"
expect_eq "$(requests)" "$B" "kubeline: no download"

new_app; run_detect hera "" "$A"
expect_eq "$RC/$(decision .mode)" "0/legacy" "no pipeline-context in gitops: legacy, no failure"

new_app; new_ctx --mode engine; run_detect hera "$X" "$A"
expect_eq "$(decision .mode)/$(decision .requested_mode)" "legacy/engine" "engine asked, the pin has no wheel: held at legacy"
expect_has "$(decision .reason)" "NoWheel" "no wheel: the reason says so"

# engine
new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$RC" "0" "engine: detect exits 0"
expect_eq "$(decision .mode)/$(decision .profile)/$(decision .vendored)/$(decision .compose_dockerfile)" "engine/hera/pristine/pristine" "engine: hera profile from the vendored blob, pristine copy and compose Dockerfile"
expect_eq "$(cat "$C/tmp/engine_mode")/$(cat "$C/tmp/engine_image")/$(cat "$C/tmp/engine_profile")" "engine/$ENGINE_IMAGE/hera" "engine: the routing files carry mode, image and profile"
expect_eq "$(decision .rebuild_compose)" "true" "engine: nothing recorded as composed yet, so the compose image is to be rebuilt"
expect_has "$OUT" "engine: mode=engine vendored=pristine compose_dockerfile=pristine rebuild_compose=true" "engine: the log line"

new_app --yolo; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$(decision .mode)/$(decision .profile)" "engine/yolo" "engine: yolo profile from the vendored blob"

printf 'apiVersion: v1\nkind: ConfigMap\ndata: {engine-compose: v0.9.0}\n' > "$T/images-current.yaml"
new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A" "$T/images-current.yaml"
expect_eq "$(decision .rebuild_compose)" "false" "engine: the recorded engine-compose is the context's version, no compose rebuild"

# vendored: modified
new_app --edited authoring; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$RC/$(decision .mode)/$(decision .vendored)" "0/engine/modified" "vendored modified (authoring.py edited): still engine, reported modified"
new_app --edited derive_tree; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$(decision .vendored)" "modified" "vendored modified (derive_tree.py edited): reported modified"
expect_not "$(cat "$C"/tmp/* 2>/dev/null)" "PWNED" "the edited copy is read as data, never run"

# custom compose Dockerfile
new_app --compose custom; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$(decision .mode)/$(decision .requested_mode)/$(decision .compose_dockerfile)" "legacy/engine/custom" "custom compose Dockerfile: held at legacy"
expect_has "$(decision .reason)" "CustomComposeDockerfile" "custom compose Dockerfile: the reason is CustomComposeDockerfile"
expect_eq "$(cat "$C/tmp/engine_mode")" "legacy" "custom compose Dockerfile: routed to the legacy render"

# shadow
new_app --compose custom; new_ctx --mode shadow --wheel "$WHEEL_URL" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$(decision .mode)/$(decision .rebuild_compose)" "shadow/false" "shadow: shadow (even with a custom compose Dockerfile), compose never rebuilt"

# wheel integrity: fails closed
new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$(printf '0%.0s' $(seq 1 64))"; run_detect hera "$X" "$A"
expect_eq "$RC" "1" "wheel sha256 mismatch: detect-steps FAILS (no fallback to the vendored render)"
expect_has "$OUT" "engine wheel sha256 mismatch" "wheel sha256 mismatch: names the problem"
expect_has "$OUT" "refusing to render or enhance with it (failing closed)" "wheel sha256 mismatch: says it fails closed"
expect_has "$OUT" "the live WorkflowTemplate stays as it is" "wheel sha256 mismatch: says the live WFT is untouched"
new_app; new_ctx --mode shadow --wheel "$WHEEL_URL" --sha256 "$(printf '1%.0s' $(seq 1 64))"; run_detect hera "$X" "$A"
expect_eq "$RC" "1" "wheel sha256 mismatch in shadow mode: fails too"
new_app; new_ctx --mode engine --wheel "http://127.0.0.1:$PORT/missing.whl" --sha256 "$SHA"; run_detect hera "$X" "$A"
expect_eq "$RC" "1" "wheel not downloadable: fails the build"
expect_has "$OUT" "failing the build rather than rendering with an engine that was not verified" "wheel not downloadable: says why"
# legacy never fails, even with a wheel that would not verify
new_app; new_ctx --mode legacy --wheel "$WHEEL_URL" --sha256 "$(printf '2%.0s' $(seq 1 64))"; run_detect hera "$X" "$A"
expect_eq "$RC/$(decision .mode)" "0/legacy" "legacy ignores the wheel: a bad sha256 never fails a legacy build"

# ── 2. the outputs and routing of ml-ci-build ────────────────────────────────────────────────
OUTS=$(ml_tpl detect-steps '.outputs.parameters[].name' | tr '\n' ' ')
for o in engine engine_mode engine_image engine_profile; do expect_has "$OUTS" "$o" "detect-steps outputs $o"; done
expect_eq "$(ml_tpl detect-steps '.outputs.parameters[] | select(.name == "engine_mode") | .valueFrom.default')" "legacy" "detect-steps: engine_mode defaults to legacy"
RH=$(ml_tpl ml-ci-build '.steps[][] | select(.name == "render-hera") | .arguments.parameters[].name' | tr '\n' ' ')
for o in engine engine_mode engine_image engine_profile; do expect_has "$RH" "$o" "ml-ci-build hands $o to render-hera"; done
STEPS=$(ml_tpl render-hera '.steps[][]')
expect_eq "$(ml_tpl render-hera '.steps[][] | select(.name == "hera-render") | .when')" "{{inputs.parameters.engine_mode}} != engine" "render-hera: the legacy render runs unless the mode is engine (legacy and shadow)"
expect_eq "$(ml_tpl render-hera '.steps[][] | select(.name == "hera-render-engine") | .when')" "{{inputs.parameters.engine_mode}} == engine" "render-hera: the engine render runs in mode engine"
expect_eq "$(ml_tpl render-hera '.steps[][] | select(.name == "hera-render-shadow") | .when')" "{{inputs.parameters.engine_mode}} == shadow" "render-hera: the comparison render runs in mode shadow"
expect_eq "$(ml_tpl render-hera '.steps[][] | select(.name == "hera-render-engine") | .continueOn.failed')" "null" "engine mode: a failed engine render fails the build"
expect_eq "$(ml_tpl render-hera '.steps[][] | select(.name == "hera-render-shadow") | .continueOn.failed')" "true" "shadow mode: a failed comparison render never fails the build"
expect_eq "$(ml_tpl render-hera '[.steps[0][].name, .steps[1][].name] | join(",")')" "hera-render,hera-render-engine,hera-render-shadow" "the legacy render finishes before the engine render (same checkout out/)"
expect_eq "$(ml_tpl render-hera '.steps[][] | select(.name == "hera-enhance-commit") | .arguments.parameters[0].name')" "engine" "hera-enhance-commit receives the decision as an immutable parameter"

# the legacy render template is untouched
HR=$(ml_script hera-render)
expect_has "$HR" 'pip install --quiet -e . || pip install --quiet hera hydra-core omegaconf pyyaml' "legacy hera-render: still pip install -e . of the app"
expect_has "$HR" 'PYTHONPATH="/workspace/repo" python pipeline.py' "legacy hera-render: still python pipeline.py with the app's copy"
expect_eq "$(ml_tpl hera-render '.container.image')" "python:3.12.13-slim" "legacy hera-render: same image as before"
expect_eq "$(ml_tpl hera-render '.inputs')" "null" "legacy hera-render: no new inputs"

# the engine render keeps the trust boundary of hera-render
expect_eq "$(ml_tpl hera-render-engine '.automountServiceAccountToken')" "false" "hera-render-engine: no service-account token in the pod that runs the app's code"
expect_eq "$(ml_tpl hera-render-engine '.executor.serviceAccountName')" "hera-render-exec" "hera-render-engine: the locked-down executor service account"
expect_eq "$(ml_tpl hera-render-engine '.container.volumeMounts[].name' | tr '\n' ' ')" "workspace " "hera-render-engine: only the workspace is mounted (no github-token)"
expect_eq "$(ml_tpl hera-render-engine '.container.image')" "{{inputs.parameters.engine_image}}" "hera-render-engine: runs the engine image of the decision"
expect_not "$(ml_script hera-render-engine)" "-e ." "hera-render-engine: never pip install -e . of the app"
expect_not "$(ml_script hera-render-engine)" "PYTHONPATH" "hera-render-engine: no PYTHONPATH into the app"

# ── 3. hera-render-engine, executed against a stub interpreter ───────────────────────────────
mkdir -p "$T/bin"
cat > "$T/bin/python" <<'STUB'
#!/bin/sh
printf 'python %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  "-I -c "*) printf '%s' "${STUB_EXTRA_DEPS:-}" ;;
  "-m pip freeze"*) printf 'hera==5.27.0\npyyaml==6.0.3\n' ;;
  "-m pip install"*) : ;;
  "-I -m kaos_engine.render"*)
    [ "${STUB_RENDER_FAILS:-0}" = 1 ] && { echo "pipeline.py raised" >&2; exit 1; }
    mkdir -p out; printf 'kind: WorkflowTemplate\n' > out/raw-workflow-template.yaml ;;
  *) echo "stub python: unexpected $*" >&2; exit 9 ;;
esac
STUB
chmod +x "$T/bin/python"
ml_script hera-render-engine > "$T/engine-render.src"
# run_render [env...]: a fresh workspace with a stale legacy render in it. Sets OUT RC, W (workspace).
run_render() {
  W=$(mktemp -d "$T/ws-XXXX"); mkdir -p "$W/repo/out" "$W/out"
  echo "stale legacy render" > "$W/repo/out/raw-workflow-template.yaml"
  : > "$W/log"
  sed -e "s#/workspace#$W#g" -e "s#{{inputs.parameters.engine_image}}#$ENGINE_IMAGE#g" "$T/engine-render.src" > "$W/render.sh"
  OUT=$(cd "$W" && env PATH="$T/bin:$PATH" STUB_LOG="$W/log" ENGINE_PROFILE=hera "$@" sh "$W/render.sh" 2>&1); RC=$?
  LOG=$(cat "$W/log")
}
run_render
expect_eq "$RC" "0" "engine render: exits 0"
expect_has "$LOG" "python -I -m kaos_engine.render pipeline.py --repo $W/repo --profile hera" "engine render: the runner, isolated (-I), with the repo and the profile"
expect_not "$LOG" "pip install" "engine render: no pip install when the engine has every dependency"
expect_eq "$(cat "$W/out/engine/raw-workflow-template.yaml" 2>/dev/null)" "kind: WorkflowTemplate" "engine render: the raw WFT is at out/engine/ (a freshly rendered one, not the stale file)"
expect_has "$OUT" "rendering pipeline.py with the platform engine $ENGINE_IMAGE (profile hera); the app's vendored kubecore/ is not imported" "engine render: the log names the engine image and says the vendored copy is not imported"
expect_eq "$(cat "$W/out/raw-workflow-template.yaml" 2>/dev/null)" "" "engine render: never writes over the legacy render's path"

run_render STUB_EXTRA_DEPS='numpy>=2'
expect_has "$LOG" "python -m pip freeze --exclude-editable" "extra deps: the engine's own versions become the constraints"
expect_has "$LOG" "python -m pip install --quiet -c /tmp/engine-constraints.txt -r /tmp/extra-deps.txt" "extra deps: installed under those constraints"
expect_not "$LOG" "pip install --quiet -e" "extra deps: the app itself is never installed"
INST=$(printf '%s\n' "$LOG" | grep -n 'pip install' | head -1 | cut -d: -f1); REND=$(printf '%s\n' "$LOG" | grep -n -- '-m kaos_engine.render' | head -1 | cut -d: -f1); DEPC=$(printf '%s\n' "$LOG" | grep -n '^python -I -c' | head -1 | cut -d: -f1)
expect_eq "$([ "$DEPC" -lt "$INST" ] && [ "$INST" -lt "$REND" ] && echo ordered)" "ordered" "extra deps: installed after the dependency check and before the render"

run_render STUB_RENDER_FAILS=1
expect_eq "$RC" "1" "engine render: a failing pipeline.py fails the step"
expect_eq "$(ls "$W/out/engine" 2>/dev/null | wc -l | tr -d ' ')" "0" "engine render: no raw WFT is left behind by a failed render (shadow then records 'failed')"

# ── 4. hera-enhance-commit: the enhance section in the three modes ──────────────────────────
ml_script hera-enhance-commit > "$T/enhance-commit.sh"
S=$(grep -nF "cat > /tmp/engine.py <<'ENGINEPYEOF'" "$T/enhance-commit.sh" | head -1 | cut -d: -f1)
E=$(grep -nF "engine.py record --shadow-file" "$T/enhance-commit.sh" | head -1 | cut -d: -f1)
[ -n "$S" ] && [ -n "$E" ] && sed -n "${S},${E}p" "$T/enhance-commit.sh" > "$T/enhance-seg.sh" \
  || { echo "FAIL: the enhance section of hera-enhance-commit was not found"; exit 1; }
expect_eq "$(ml_tpl hera-enhance-commit '.container.env[] | select(.name == "ENGINE_DECISION") | .value')" "{{inputs.parameters.engine}}" "hera-enhance-commit reads the decision from an env var, never spliced into the script"

# a fixture legacy enhancer (the pinned tarball) and the engine wheel's one
mkdir -p "$T/legacy-src/org-enhancer-abc/kubecore"
: > "$T/legacy-src/org-enhancer-abc/kubecore/__init__.py"
cat > "$T/legacy-src/org-enhancer-abc/kubecore/enhance.py" <<'EOF'
import argparse, os, yaml
p = argparse.ArgumentParser()
for a in ("--raw", "--context", "--output"):
    p.add_argument(a, required=True)
p.add_argument("--catalog", default="")
p.add_argument("--helper-configmap", default="")
args = p.parse_args()
wft = yaml.safe_load(open(args.raw))
wft.setdefault("metadata", {}).setdefault("annotations", {})["enhanced-by"] = "platform"
wft["metadata"]["annotations"]["legacy-tarball"] = "yes"
yaml.safe_dump(wft, open(args.output, "w"))
open(os.environ["FIXTURE_LOG"], "a").write("legacy-enhance ran\n")
EOF
tar -C "$T/legacy-src" -czf "$T/enhancer.tar.gz" org-enhancer-abc
# The legacy stand-in marks itself (legacy-tarball); the shadow cases need it equal to the engine's, so a
# second tarball whose output matches the engine stand-in is used there.
mkdir -p "$T/legacy-eq/org-enhancer-abc/kubecore"; : > "$T/legacy-eq/org-enhancer-abc/kubecore/__init__.py"
sed '/legacy-tarball/d' "$T/legacy-src/org-enhancer-abc/kubecore/enhance.py" > "$T/legacy-eq/org-enhancer-abc/kubecore/enhance.py"
tar -C "$T/legacy-eq" -czf "$T/enhancer-eq.tar.gz" org-enhancer-abc

RAW='apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata: {name: app1-pipeline}
spec:
  entrypoint: main
  templates: [{name: main, container: {image: "x"}}]'

# decision_json MODE [VENDORED] [WHEEL_SHA]
decision_json() {
  jq -nc --arg mode "$1" --arg ven "${2:-pristine}" --arg wheel "$WHEEL_URL" --arg sha "${3:-$SHA}" --arg img "$ENGINE_IMAGE" \
    '{mode: $mode, requested_mode: $mode, version: "v0.9.0", engine_image: $img, wheel: $wheel, wheel_sha256: $sha,
      profile: "hera", vendored: $ven, compose_dockerfile: "pristine", rebuild_compose: false, reason: "x"}'
}
# run_enhance DECISION TARBALL [LEGACY_RAW=1] [ENGINE_RAW=1] [env...]: sets OUT RC and C.
run_enhance() {
  C=$(mktemp -d "$T/enh-XXXX"); mkdir -p "$C/tmp" "$C/ws/out/engine"
  printf 'token' > "$C/token"; echo "namespace: proj-ml" > "$C/tmp/context.yaml"; : > "$C/log"
  [ "${3:-1}" = 1 ] && printf '%s\n' "$RAW" > "$C/ws/out/raw-workflow-template.yaml"
  [ "${4:-1}" = 1 ] && printf '%s\n' "$RAW" > "$C/ws/out/engine/raw-workflow-template.yaml"
  { echo "set -e"; sed -e "s#/tmp/#$C/tmp/#g" -e "s#/workspace/#$C/ws/#g" -e "s#/etc/github-token/token#$C/token#g" \
        -e "s#urllib.request.urlopen(req, timeout=60)#open(\"$2\", \"rb\")#" "$T/enhance-seg.sh"; } > "$C/enhance.sh"
  [ $# -gt 4 ] && shift 4 || shift $#
  OUT=$(cd "$C" && env -u PYTHONPATH ENGINE_DECISION="$DECISION" FIXTURE_LOG="$C/log" "$@" sh "$C/enhance.sh" 2>&1); RC=$?
}
wft_at() { yq "$1" "$C/ws/out/workflow-template.yaml"; }
rec() { jq -c . "$C/tmp/engine-record.json"; }

# legacy: byte-for-byte today's enhance (the pinned tarball), no engine anywhere
DECISION=$(decision_json legacy ""); B=$(requests); run_enhance "$DECISION" "$T/enhancer.tar.gz"
expect_eq "$RC" "0" "legacy enhance: exits 0"
expect_eq "$(cat "$C/log")" "legacy-enhance ran" "legacy enhance: only the pinned enhancer ran"
expect_eq "$(wft_at '.metadata.annotations["legacy-tarball"]')" "yes" "legacy enhance: the output is the pinned enhancer's"
expect_not "$(cat "$C/ws/out/workflow-template.yaml")" "platform.kubecore.io/engine" "legacy enhance: the WFT is not stamped (no engine label, no engine annotation)"
expect_eq "$(requests)" "$B" "legacy enhance: the engine wheel is not downloaded"
expect_eq "$(rec)" '{"set":{"engine-mode":"legacy"},"clear":["engine-version","engine-shadow","engine-vendored"]}' "legacy enhance: pipeline-images records engine-mode legacy only"
DECISION=""; run_enhance "" "$T/enhancer.tar.gz"
expect_eq "$RC/$(cat "$C/log")" "0/legacy-enhance ran" "no decision at all (an old caller): legacy enhance"
expect_eq "$(rec)" '{"set":{},"clear":[]}' "no decision: the record is empty (nothing is written to pipeline-images)"
DECISION=$(jq -nc '{mode:"legacy",reason:"NoEngineBlock: x"}'); run_enhance "$DECISION" "$T/enhancer.tar.gz"
expect_eq "$(rec)" '{"set":{},"clear":[]}' "no engine block in the context: pipeline-images is left alone"

# engine: the engine wheel's enhancer, stamped, the pinned tarball never touched
DECISION=$(decision_json engine pristine); B=$(requests); run_enhance "$DECISION" "$T/no-such-tarball" 0 1
expect_eq "$RC" "0" "engine enhance: exits 0 (the GitHub tarball of the pin is not used: it does not even exist here)"
expect_eq "$(cat "$C/log")" "engine-enhance ran" "engine enhance: only the engine wheel's enhancer ran"
expect_eq "$(requests)" "$((B + 1))" "engine enhance: exactly one download, the wheel"
expect_has "$OUT" "platform enhancer: engine v0.9.0 (wheel sha256 ${SHA:0:12} verified)" "engine enhance: the log names the engine and the verified sha256"
expect_eq "$(wft_at '.metadata.annotations["enhanced-by"]')" "platform" "engine enhance: the output is the engine enhancer's"
expect_eq "$(wft_at '.metadata.annotations["platform.kubecore.io/engine-version"]')" "v0.9.0" "engine enhance: the WFT is stamped with the engine version"
expect_eq "$(wft_at '.spec.workflowMetadata.labels["platform.kubecore.io/engine"]')" "v0.9.0" "engine enhance: Workflows carry the label platform.kubecore.io/engine=<v> (the removal gate counts it)"
expect_eq "$(wft_at '.spec.entrypoint')" "main" "engine enhance: the rest of the WFT is untouched by the stamp"
expect_eq "$(rec)" '{"set":{"engine-mode":"engine","engine-version":"v0.9.0","engine-vendored":"pristine"},"clear":["engine-shadow"]}' "engine enhance: records engine-mode, engine-version and engine-vendored"
expect_eq "$(ls "$C/tmp/kubecore-enhancer" 2>/dev/null | wc -l | tr -d ' ')" "0" "engine enhance: the pinned tarball enhancer was not unpacked"
DECISION=$(decision_json engine modified); run_enhance "$DECISION" "$T/no-such-tarball" 0 1
expect_has "$(rec)" '"engine-vendored":"modified"' "engine enhance: an edited vendored copy is recorded as engine-vendored: modified"

DECISION=$(decision_json engine pristine "$(printf '3%.0s' $(seq 1 64))"); run_enhance "$DECISION" "$T/no-such-tarball" 0 1
expect_not "$RC" "0" "engine enhance, wheel sha256 mismatch: the step fails"
expect_has "$OUT" "engine wheel sha256 mismatch" "engine enhance, sha256 mismatch: clear message"
expect_has "$OUT" "failing closed" "engine enhance, sha256 mismatch: says it fails closed"
expect_eq "$(ls "$C/ws/out/workflow-template.yaml" 2>/dev/null | wc -l | tr -d ' ')" "0" "engine enhance, sha256 mismatch: no WorkflowTemplate is produced"
expect_eq "$(ls "$C/tmp/kubecore-engine/kaos_pipeline_engine" 2>/dev/null | wc -l | tr -d ' ')" "0" "engine enhance, sha256 mismatch: nothing of the wheel is unpacked or run"

# shadow: legacy is committed; the engine's output is compared
DECISION=$(decision_json shadow pristine); run_enhance "$DECISION" "$T/enhancer-eq.tar.gz"
expect_eq "$RC" "0" "shadow enhance (equal): exits 0"
expect_eq "$(cat "$C/log" | tr '\n' ',')" "legacy-enhance ran,engine-enhance ran," "shadow enhance: both enhancers ran, legacy first"
expect_eq "$(cat "$C/tmp/engine-shadow-result")" "equal" "shadow enhance: identical parsed output is engine-shadow: equal"
expect_has "$OUT" "engine-shadow: equal" "shadow enhance (equal): logged"
expect_not "$(cat "$C/ws/out/workflow-template.yaml")" "platform.kubecore.io/engine" "shadow enhance: the committed (legacy) WFT carries no engine stamp"
expect_eq "$(rec)" '{"set":{"engine-mode":"shadow","engine-shadow":"equal","engine-vendored":"pristine"},"clear":["engine-version"]}' "shadow enhance (equal): records engine-mode shadow and engine-shadow equal"

DECISION=$(decision_json shadow pristine); run_enhance "$DECISION" "$T/enhancer-eq.tar.gz" 1 1 FIXTURE_ENGINE_DIFFERS=1
expect_eq "$RC" "0" "shadow enhance (differs): exits 0, never a red build"
expect_eq "$(cat "$C/tmp/engine-shadow-result")" "differs:2" "shadow enhance: two differing paths are engine-shadow: differs:2"
expect_has "$OUT" "engine-shadow: differs at workflow-template.yaml/spec/entrypoint" "shadow enhance (differs): the differing path is logged"
expect_eq "$(wft_at '.spec.entrypoint')" "main" "shadow enhance (differs): the committed output is still the legacy one"
expect_has "$(rec)" '"engine-shadow":"differs:2"' "shadow enhance (differs): recorded"

DECISION=$(decision_json shadow pristine); run_enhance "$DECISION" "$T/enhancer-eq.tar.gz" 1 0
expect_eq "$RC" "0" "shadow enhance (engine render failed): exits 0"
expect_eq "$(cat "$C/tmp/engine-shadow-result")" "failed" "shadow enhance: no engine render is engine-shadow: failed"
expect_eq "$(cat "$C/log")" "legacy-enhance ran" "shadow enhance (engine render failed): the legacy output is produced as usual"

DECISION=$(decision_json shadow pristine "$(printf '4%.0s' $(seq 1 64))"); run_enhance "$DECISION" "$T/enhancer-eq.tar.gz"
expect_not "$RC" "0" "shadow enhance, wheel sha256 mismatch: the step fails closed"
expect_has "$OUT" "engine wheel sha256 mismatch" "shadow enhance, sha256 mismatch: clear message"

# ── 5. pipeline-images writer: the record, and enhancer-ref in engine mode ───────────────────
awk '/<<'"'"'IMGEOF'"'"'/{on=1; next} /^IMGEOF$/{on=0} on' "$T/enhance-commit.sh" > "$T/writer.py"
expect_has "$(grep -F "<<'IMGEOF'" "$T/enhance-commit.sh")" '"$([ "${ENGINE_MODE}" = engine ] || printf' "the writer gets an empty enhancer-ref in mode engine (the pin was not used)"
W=$(mktemp -d "$T/writer-XXXX")
printf 'metadata: {name: app1-pipeline, namespace: proj-train}\nspec: {arguments: {parameters: [{name: image-a, valueFrom: {configMapKeyRef: {name: app1-pipeline-images, key: a}}}]}}\n' > "$W/wft.yaml"
reset_images() {
  printf 'apiVersion: v1\nkind: ConfigMap\nmetadata: {name: app1-pipeline-images, namespace: proj-train}\ndata: {last-built-sha: aaaa, context-sha: ctx1, enhancer-ref: oldpin, a: "reg/a:1"%s}\n' "${1:+, $1}" > "$W/images.yaml"
}
images() { python3 -c 'import sys, yaml; d = yaml.safe_load(open(sys.argv[1]))["data"]; print(" ".join(["enhancer-ref=" + str(d.get("enhancer-ref"))] + [f"{k}={d[k]}" for k in sorted(d) if k.startswith("engine-")]))' "$W/images.yaml"; }
write() { python3 "$T/writer.py" "$W/wft.yaml" "$W/images.yaml" app1 ctx1 "$1" /nonexistent "" "$2" 2>&1; }
echo '{"set":{"engine-mode":"engine","engine-version":"v0.9.0","engine-vendored":"pristine"},"clear":["engine-shadow"]}' > "$W/rec-engine.json"
echo '{"set":{"engine-mode":"legacy"},"clear":["engine-version","engine-shadow","engine-vendored"]}' > "$W/rec-legacy.json"
echo '{"set":{},"clear":[]}' > "$W/rec-none.json"

reset_images; write newpin "$W/rec-legacy.json" > /dev/null
expect_eq "$(images)" "enhancer-ref=newpin engine-mode=legacy" "writer, legacy: records engine-mode and keeps recording the pinned enhancer"
reset_images; OUT=$(write "" "$W/rec-engine.json")
expect_eq "$(images)" "enhancer-ref=oldpin engine-mode=engine engine-vendored=pristine engine-version=v0.9.0" "writer, engine: records the engine keys and leaves enhancer-ref as it was"
expect_has "$OUT" "pipeline-images keys" "writer, engine: the write is reported"
BEFORE=$(cat "$W/images.yaml"); OUT=$(write "" "$W/rec-engine.json")
expect_eq "$(cat "$W/images.yaml")" "$BEFORE" "writer: the same record again rewrites nothing"
expect_has "$OUT" "already has exactly" "writer: and says so"
write newpin "$W/rec-legacy.json" > /dev/null
expect_eq "$(images)" "enhancer-ref=newpin engine-mode=legacy" "writer: back to legacy clears engine-version and engine-vendored"
reset_images "engine-shadow: equal, engine-version: v0.8.0"; write newpin "$W/rec-legacy.json" > /dev/null
expect_eq "$(images)" "enhancer-ref=newpin engine-mode=legacy" "writer: a stale engine-shadow and engine-version are cleared"
reset_images; BEFORE=$(cat "$W/images.yaml"); write oldpin "$W/rec-none.json" > /dev/null
expect_eq "$(cat "$W/images.yaml")" "$BEFORE" "writer: an app with no engine block is not touched at all"
reset_images "engine-mode: shadow, engine-shadow: equal"; write oldpin "$W/rec-none.json" > /dev/null
expect_eq "$(images)" "enhancer-ref=oldpin engine-mode=shadow engine-shadow=equal" "writer: engine keys are never pruned as stale step keys"

# ── 6. ml-ci-pr-render: detect-engine and the engine render of a PR ──────────────────────────
expect_eq "$(pr_tpl ml-ci-pr-render '.steps[][] | select(.name == "detect-engine") | .template')" "detect-engine" "pr-render: detects the engine for every frontend (a skipped step has no outputs)"
expect_eq "$(pr_tpl ml-ci-pr-render '.steps[][] | select(.name == "hera-render") | .when')" "{{steps.detect-frontend.outputs.parameters.frontend}} == hera && {{steps.detect-engine.outputs.parameters.engine_mode}} != engine" "pr-render: legacy and shadow PRs render with the app's vendored code, as before"
expect_eq "$(pr_tpl ml-ci-pr-render '.steps[][] | select(.name == "hera-render-engine") | .when')" "{{steps.detect-frontend.outputs.parameters.frontend}} == hera && {{steps.detect-engine.outputs.parameters.engine_mode}} == engine" "pr-render: an engine-mode PR renders with the engine"
expect_eq "$(pr_tpl ml-ci-pr-render '.steps[][] | select(.name == "hera-render-engine") | .arguments.parameters[] | select(.name == "engine_image") | .value')" "{{steps.detect-engine.outputs.parameters.engine_image}}" "pr-render: engine_image is passed through to the render"
expect_eq "$(pr_tpl ml-ci-pr-render '.steps[][] | select(.name == "hera-enhance-gate") | .arguments.parameters[0].value')" "{{steps.detect-engine.outputs.parameters.engine}}" "pr-render: the gate enhances with the same decision"
expect_eq "$(pr_tpl hera-enhance-gate '.container.env[] | select(.name == "ENGINE_DECISION") | .value')" "{{inputs.parameters.engine}}" "pr-render gate: the decision arrives as an env var"

pr_script detect-engine > "$T/detect-engine.src"
mkdir -p "$T/gitops/apps/app1/dev"
cat > "$T/bin/git" <<'STUB'
#!/bin/sh
[ "$1" = clone ] || exit 0
for last; do :; done
cp -r "$STUB_DIR/gitops" "$last"
STUB
chmod +x "$T/bin/git"
# run_pr_detect FRONTEND: sets OUT RC and C; the app is $A, its context $X.
run_pr_detect() {
  C=$(mktemp -d "$T/prd-XXXX"); mkdir -p "$C/tmp" "$C/ws"; printf '%s' "$1" > "$C/ws/frontend"; printf 'token' > "$C/token"
  rm -rf "$T/gitops"; mkdir -p "$T/gitops/apps/app1/dev"; cp "$X" "$T/gitops/apps/app1/dev/pipeline-context.yaml"
  sed -e "s#/tmp/#$C/tmp/#g" -e "s#/workspace/repo#$A#g" -e "s#/workspace/#$C/ws/#g" -e "s#/etc/github-token/token#$C/token#g" \
      -e "s#{{workflow.parameters.gitops_repository}}#gitops#g; s#{{workflow.parameters.gitops_branch}}#dev#g; s#{{workflow.parameters.app_name}}#app1#g" \
      "$T/detect-engine.src" > "$C/detect-engine.sh"
  OUT=$(cd "$C" && env PATH="$T/bin:$PATH" STUB_DIR="$T" sh "$C/detect-engine.sh" 2>&1); RC=$?
}
new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_pr_detect hera
expect_eq "$RC/$(jq -r .mode "$C/tmp/engine.json")/$(cat "$C/tmp/engine_profile")/$(cat "$C/tmp/engine_vendored")" "0/engine/hera/pristine" "pr detect-engine (hera, engine): the merge build's decision"
expect_eq "$(cat "$C/tmp/engine_image")" "$ENGINE_IMAGE" "pr detect-engine: engine_image is passed through"
new_app --edited authoring; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_pr_detect hera
expect_eq "$(cat "$C/tmp/engine_mode")/$(cat "$C/tmp/engine_vendored")" "engine/modified" "pr detect-engine: an edited vendored copy is reported as vendored: modified"
new_app --compose custom; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_pr_detect hera
expect_eq "$(cat "$C/tmp/engine_mode")" "legacy" "pr detect-engine: a custom compose Dockerfile keeps the PR on the legacy render"
new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$SHA"; run_pr_detect kubeline
expect_eq "$RC/$(cat "$C/tmp/engine_mode")" "0/legacy" "pr detect-engine: a kubeline app answers legacy"
new_app; new_ctx --mode legacy; run_pr_detect hera
expect_eq "$RC/$(cat "$C/tmp/engine_mode")/$(cat "$C/tmp/engine_vendored")" "0/legacy/" "pr detect-engine: mode legacy is today's PR render"
new_app; new_ctx --mode engine --wheel "$WHEEL_URL" --sha256 "$(printf '5%.0s' $(seq 1 64))"; run_pr_detect hera
expect_eq "$RC" "1" "pr detect-engine, wheel sha256 mismatch: the check fails closed"
expect_has "$OUT" "engine wheel sha256 mismatch" "pr detect-engine, sha256 mismatch: clear message"
expect_eq "$(pr_tpl detect-engine '.container.volumeMounts[].name' | tr '\n' ' ')" "workspace github-token " "pr detect-engine: platform code with the token, reading the checkout as data"
expect_not "$(pr_script detect-engine)" "pip install" "pr detect-engine: installs nothing"
expect_not "$(pr_script detect-engine)" "cd /workspace/repo" "pr detect-engine: never cds into the checkout"

echo "engine-ci: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
