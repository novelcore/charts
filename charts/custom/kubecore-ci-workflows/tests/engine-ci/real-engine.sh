#!/usr/bin/env bash
# OPT-IN, local: the chart's own engine scripts against a REAL engine wheel and REAL template checkouts, no
# Docker. For each template checkout it renders pipeline.py twice (the app's vendored code, then the
# platform engine through the chart's hera-render-engine script), enhances both (the pinned template
# enhancer, then the engine wheel's through the chart's enhance section) and compares the parsed WFTs,
# the shadow verdict. Not part of charts/validate (needs hera, hydra, a built wheel and the templates).
#
#   ENGINE_WHEEL=/path/kaos_pipeline_engine-X.whl          the engine wheel (python -m build in kaos-hpc-operator/engine)
#   ENGINE_PYTHON=/path/venv/bin/python                    python 3.12 with the engine's requirements.txt and that wheel
#   TEMPLATES=/path/dir                                    holds fresh checkouts hera/ and yolo/ of the two templates
#   bash tests/engine-ci/real-engine.sh /tmp/rendered.yaml
#
# Needs yq v4, jq, python3 + PyYAML (the enhance runs on the system python3, as in the toolbox image).
set -u
RENDERED="$1"
: "${ENGINE_WHEEL:?}" "${ENGINE_PYTHON:?}" "${TEMPLATES:?}"
HERE=$(cd "$(dirname "$0")" && pwd)
FAILED=0; PASSED=0
T=$(mktemp -d); SRV=""
trap '[ -n "$SRV" ] && kill "$SRV" 2>/dev/null; rm -rf "${T:?}"' EXIT
expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
ML='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")'
ml_script() { yq "$ML | .spec.templates[] | select(.name == \"$1\") | .container.args[0]" "$RENDERED"; }

mkdir -p "$T/www" "$T/bin"; cp "$ENGINE_WHEEL" "$T/www/engine.whl"
SHA=$(sha256sum "$T/www/engine.whl" | cut -c1-64)
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$T/www" > /dev/null 2>&1 & SRV=$!
sleep 1
printf '#!/bin/sh\nexec "%s" "$@"\n' "$ENGINE_PYTHON" > "$T/bin/python"; chmod +x "$T/bin/python"   # the engine image's `python` 
VERSION=$("$ENGINE_PYTHON" -c 'from kaos_engine import engine_version; print(engine_version())')
echo "engine wheel $(basename "$ENGINE_WHEEL") (version ${VERSION}), sha256 ${SHA:0:12}"

ml_script hera-render-engine > "$T/render.src"
ml_script hera-enhance-commit > "$T/enhance-commit.sh"
S=$(grep -nF "cat > /tmp/engine.py <<'ENGINEPYEOF'" "$T/enhance-commit.sh" | head -1 | cut -d: -f1)
E=$(grep -nF "engine.py record --shadow-file" "$T/enhance-commit.sh" | head -1 | cut -d: -f1)
sed -n "${S},${E}p" "$T/enhance-commit.sh" > "$T/enhance-seg.sh"
ml_script detect-steps > "$T/detect-steps.sh"
S=$(grep -nF 'ENGINE (PRD-HPC-1461 D-79): which engine renders this app' "$T/detect-steps.sh" | cut -d: -f1)
E=$(grep -nF "echo \"engine: \$(jq -r '.reason'" "$T/detect-steps.sh" | cut -d: -f1)
sed -n "${S},${E}p" "$T/detect-steps.sh" > "$T/detect-seg.sh"

for tpl in hera yolo; do
  SRC="${TEMPLATES}/${tpl}"; D="$T/$tpl"; mkdir -p "$D/ws/out/engine" "$D/tmp"
  cp -r "$SRC" "$D/ws/repo"; rm -rf "$D/ws/repo/out" "$D/ws/repo/.git"
  echo "=== ${tpl} template $(git -C "$SRC" rev-parse --short HEAD)"
  # the context: the template's own local-dev placeholder context plus this wheel's engine block
  mkctx() {  # mkctx MODE CONFIGMAP_OUT BARE_OUT
    python3 - "$SRC/kubecore/local-dev/pipeline-context.yaml" "$1" "http://127.0.0.1:$PORT/engine.whl" "$SHA" "${VERSION//+/-}" "$2" "$3" <<'PY'
import sys, yaml
src, mode, wheel, sha, version, cm_out, bare_out = sys.argv[1:8]
ctx = yaml.safe_load(open(src))
yaml.safe_dump(ctx, open(bare_out, "w"), sort_keys=False)   # what the enhancer reads (no engine block needed)
ctx["engine"] = {"version": version, "image": f"reg.example/kaos-pool/kaos-pipeline-engine:{version}",
                 "mode": mode, "wheel": wheel, "wheelSha256": sha}
yaml.safe_dump({"apiVersion": "v1", "kind": "ConfigMap", "data": {"context.yaml": yaml.safe_dump(ctx, sort_keys=False)}},
               open(cm_out, "w"), sort_keys=False)
PY
  }
  mkctx shadow "$D/ctx.yaml" "$D/tmp/context.yaml"
  # 1. decide (the real known-vendored.json of the wheel)
  { echo "set -e; FRONTEND=hera; KL_CTX='$D/ctx.yaml'; IMAGES_PATH=''"; sed -e "s#/tmp/#$D/tmp/#g" -e "s#/workspace/repo#$D/ws/repo#g" "$T/detect-seg.sh"; } > "$D/detect.sh"
  ( cd "$D" && sh detect.sh ) > "$D/detect.log" 2>&1; echo "decide rc=$?"; cat "$D/detect.log" | grep '^engine:'
  PROFILE=$(cat "$D/tmp/engine_profile"); MODE=$(cat "$D/tmp/engine_mode")
  expect_eq "$MODE/$PROFILE/$(jq -r .vendored "$D/tmp/engine.json")" "shadow/${tpl}/pristine" "${tpl}: decide takes the ${tpl} profile from the real vendored derive_tree.py blob, pristine"
  # 2. legacy render: the app's own pipeline.py with its own kubecore/
  ( cd "$D/ws/repo" && "$ENGINE_PYTHON" pipeline.py > "$D/legacy.log" 2>&1 ) && cp "$D/ws/repo/out/raw-workflow-template.yaml" "$D/ws/out/raw-workflow-template.yaml"
  expect_eq "$([ -s "$D/ws/out/raw-workflow-template.yaml" ] && echo rendered)" "rendered" "${tpl}: legacy render (vendored code)"
  # 3. engine render, through the chart's own script
  sed -e "s#/workspace#$D/ws#g" -e "s#{{inputs.parameters.engine_image}}#$(jq -r .engine_image "$D/tmp/engine.json")#g" "$T/render.src" > "$D/render.sh"
  ( cd "$D" && env PATH="$T/bin:$PATH" ENGINE_PROFILE="$PROFILE" sh render.sh ) > "$D/engine-render.log" 2>&1; RC=$?
  [ "$RC" = 0 ] || tail -15 "$D/engine-render.log"
  expect_eq "$RC" "0" "${tpl}: the chart's hera-render-engine script renders with the real runner"
  grep -E "^(hera-render-engine|kaos-engine):" "$D/engine-render.log" | sed "s#$D#<sandbox>#g"
  expect_eq "$(cmp -s "$D/ws/out/raw-workflow-template.yaml" "$D/ws/out/engine/raw-workflow-template.yaml" && echo byte-equal)" "byte-equal" "${tpl}: the raw WorkflowTemplates of the two renders are byte-equal"
  # 4. enhance: shadow (legacy = the template's own kubecore/enhance.py as the pinned tarball, engine = the wheel)
  # The pinned enhancer is always the HERA template's (platformEnhancer.repo), for yolo apps too.
  mkdir -p "$D/tar/org-tpl-abc"; cp -r "${TEMPLATES}/hera/kubecore" "$D/tar/org-tpl-abc/kubecore"
  tar -C "$D/tar" -czf "$D/enhancer.tar.gz" org-tpl-abc
  printf 'token' > "$D/token"
  { echo "set -e"; sed -e "s#/tmp/#$D/tmp/#g" -e "s#/workspace/#$D/ws/#g" -e "s#/etc/github-token/token#$D/token#g" \
      -e "s#urllib.request.urlopen(req, timeout=60)#open(\"$D/enhancer.tar.gz\", \"rb\")#" "$T/enhance-seg.sh"; } > "$D/enhance.sh"
  ( cd "$D" && env -u PYTHONPATH ENGINE_DECISION="$(cat "$D/tmp/engine.json")" sh enhance.sh ) > "$D/enhance.log" 2>&1; RC=$?
  grep -E "^(engine-shadow|platform enhancer)" "$D/enhance.log" | sed "s#$D#<sandbox>#g"
  [ "$RC" = 0 ] || tail -15 "$D/enhance.log"
  expect_eq "$RC" "0" "${tpl}: shadow enhance (legacy enhancer, engine wheel enhancer, compare) runs"
  expect_eq "$(cat "$D/tmp/engine-shadow-result" 2>/dev/null)" "equal" "${tpl}: engine-shadow: equal"
  expect_eq "$(cat "$D/tmp/engine-record.json")" "{\"set\": {\"engine-mode\": \"shadow\", \"engine-shadow\": \"equal\", \"engine-vendored\": \"pristine\"}, \"clear\": [\"engine-version\"]}" "${tpl}: the pipeline-images record"
  # 5. engine mode end to end: the WFT is the engine's, stamped
  mkctx engine "$D/ctx-engine.yaml" "$D/tmp/context.yaml"
  { echo "set -e; FRONTEND=hera; KL_CTX='$D/ctx-engine.yaml'; IMAGES_PATH=''"; sed -e "s#/tmp/#$D/tmp/#g" -e "s#/workspace/repo#$D/ws/repo#g" "$T/detect-seg.sh"; } > "$D/detect2.sh"
  ( cd "$D" && sh detect2.sh ) > /dev/null 2>&1
  cp "$D/ws/out/workflow-template.yaml" "$D/legacy-wft.yaml"; rm -f "$D/ws/out/workflow-template.yaml"
  ( cd "$D" && env -u PYTHONPATH ENGINE_DECISION="$(cat "$D/tmp/engine.json")" sh enhance.sh ) > "$D/enhance2.log" 2>&1; RC=$?
  expect_eq "$RC/$(jq -r .mode "$D/tmp/engine.json")" "0/engine" "${tpl}: engine mode enhance from the wheel (no tarball, no pip)"
  expect_eq "$(yq '.metadata.annotations["platform.kubecore.io/engine-version"]' "$D/ws/out/workflow-template.yaml")" "${VERSION//+/-}" "${tpl}: the WFT is stamped"
  expect_eq "$(yq '.spec.workflowMetadata.labels["platform.kubecore.io/engine"]' "$D/ws/out/workflow-template.yaml")" "${VERSION//+/-}" "${tpl}: Workflows carry the engine label"
  python3 - "$D/legacy-wft.yaml" "$D/ws/out/workflow-template.yaml" > "$D/diff.txt" <<'PY'
import sys, yaml
a, b = (yaml.safe_load(open(p)) for p in sys.argv[1:3])
for doc in (b,):
    doc["metadata"]["annotations"].pop("platform.kubecore.io/engine-version")
    doc["spec"]["workflowMetadata"]["labels"].pop("platform.kubecore.io/engine")
    if not doc["spec"]["workflowMetadata"]["labels"]:
        doc["spec"]["workflowMetadata"].pop("labels")
    if not doc["spec"]["workflowMetadata"]:
        doc["spec"].pop("workflowMetadata")
print("equal" if a == b else "differs")
PY
  expect_eq "$(cat "$D/diff.txt")" "equal" "${tpl}: the engine-mode WFT equals the vendored-code WFT apart from the stamp"
done
echo "real-engine: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
