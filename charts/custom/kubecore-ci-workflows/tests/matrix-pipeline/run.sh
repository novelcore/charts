#!/usr/bin/env bash
# A pipeline with a matrix step through the PR gate, the merge build's image-record writer and the size guard
# (chart 0.15.3, PRD novelcore/kaos#1911). fixtures/workflow-template.yaml is a REAL render: prep, train with
# matrix= and report (fixtures/pipeline.py) rendered by kaos-io/kaos-hpc-operator engine/ main c4b31ca
# (`python -m kaos_engine.render pipeline.py --repo <app> --profile hera`, then `python -m kubecore.enhance`
# with tests/connections/fixtures/contexts/demo.yaml). It holds the templates the engine names with its reserved
# prefix: kaos-matrix-train (the fan: it runs the image of step train, it has no container of its own),
# kaos-gather-train and kaos-promote (they run the platform's compose image). To regenerate after an engine
# change: render the same pipeline.py with the new engine and copy the enhanced template over the fixture.
# Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/matrix-pipeline/run.sh /tmp/rendered.yaml
#
# The scripts are cut from the rendered chart and EXECUTED. Needs yq v4, python3 + PyYAML.
# Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
FAILED=0
PASSED=0
expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"; echo "  actual: $(printf '%s' "$1" | tail -6)" ;;
  esac
}
expect_lacks() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
WFT_FIXTURE="${HERE}/fixtures/workflow-template.yaml"

# ── the PR gate ─────────────────────────────────────────────────────────────────────────────
GATE_SRC=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")
    | .spec.templates[] | select(.name == "hera-enhance-gate") | .container.args[0]' "$RENDERED")
printf '%s\n' "$GATE_SRC" | awk "/python3 - \/workspace\/out\/workflow-template.yaml <<'GATEEOF'/ {on=1} on {print} on && /^GATEEOF\$/ {exit}" \
  | sed -e "s#/workspace/#$T/workspace/#g" > "$T/gate.sh"
mkdir -p "$T/workspace/out" "$T/workspace/repo/steps"
cp "$WFT_FIXTURE" "$T/workspace/out/workflow-template.yaml"
for d in prep train report; do mkdir -p "$T/workspace/repo/steps/$d"; echo "FROM scratch" > "$T/workspace/repo/steps/$d/Dockerfile"; done
gate() { OUT=$(cd "$T" && sh "$T/gate.sh" 2>&1); RC=$?; REPORT=$(cat "$T/workspace/report-extra.md" 2>/dev/null); }

gate
expect_eq "$RC" "0" "gate: a pipeline with a matrix step passes with only the folders of its own steps"
expect_has "$OUT" "GATE OK" "gate: reports OK"
expect_lacks "$OUT" "kaos_gather" "gate: no folder is asked for the platform's gather task"
expect_has "$REPORT" '| `kaos-gather-train` | built by the platform |' "report: the gather task is built by the platform"
expect_has "$REPORT" '| `kaos-promote` | built by the platform |' "report: the final task is built by the platform"
expect_has "$REPORT" '| `kaos-matrix-train` | runs the image of step `train` |' "report: the fan template runs the image of its step"
expect_has "$REPORT" '| `train` | built from `steps/train/` |' "report: the step is built from its folder"
expect_has "$REPORT" '| `compose-and-validate` | built by the platform from `config/` |' "report: compose is built from config/"
expect_lacks "$REPORT" "kaos_gather" "report: no table row names a kaos_ folder"
expect_lacks "$REPORT" "kaos_matrix" "report: no table row names a kaos_matrix folder"

rm -r "$T/workspace/repo/steps/train"
gate
expect_eq "$RC" "1" "gate: the matrix step without its folder fails"
expect_has "$OUT" "step 'train': expected steps/train/Dockerfile" "gate: the missing folder is the step's"
expect_lacks "$OUT" "kaos-gather" "gate: ... and the platform's tasks are not named as missing"
expect_lacks "$OUT" "kaos-matrix" "gate: ... nor the fan template"
mkdir -p "$T/workspace/repo/steps/train"; echo "FROM scratch" > "$T/workspace/repo/steps/train/Dockerfile"

# ── the merge build's image-record writer ───────────────────────────────────────────────────
COMMIT_SRC=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.args[0]' "$RENDERED")
printf '%s\n' "$COMMIT_SRC" | awk '/<<'"'"'IMGEOF'"'"'/{on=1; next} /^ *IMGEOF$/{on=0} on' > "$T/writer.py"
cat > "$T/images.yaml" <<'YEOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: demo-pipeline-images, namespace: PLACEHOLDER-data-room-runtime}
data:
  last-built-sha: aaaa
  prep: reg/demo:prep-1
  old-step: reg/demo:old-1
  kaos-gather-train: reg/demo:bogus
  kaos_gather_train: reg/demo:bogus
  kaos-matrix-train: reg/demo:bogus
YEOF
WROTE=$(python3 "$T/writer.py" "$WFT_FIXTURE" "$T/images.yaml" demo "" "" "" "" 2>&1)
KEYS=$(yq '.data | keys | .[]' "$T/images.yaml" | sort | tr '\n' ' ')
expect_eq "$KEYS" "compose-and-validate last-built-sha prep report train " "record: seeds the steps and compose; prunes the stale and bogus keys; nothing for the platform's tasks"
expect_eq "$(yq '.data.prep' "$T/images.yaml")" "reg/demo:prep-1" "record: a built step keeps its image"
expect_eq "$(yq '.data.train' "$T/images.yaml")" ":train-latest" "record: the matrix step is seeded as unbuilt"
expect_eq "$(yq '.data["compose-and-validate"]' "$T/images.yaml")" ":compose-and-validate-latest" "record: the platform's tasks share the compose key"
expect_has "$WROTE" "removed: ['old-step', 'kaos-gather-train', 'kaos_gather_train', 'kaos-matrix-train']" "record: the report names what it pruned"
cp "$T/images.yaml" "$T/images.first"
WROTE=$(python3 "$T/writer.py" "$WFT_FIXTURE" "$T/images.yaml" demo "" "" "" "" 2>&1)
expect_has "$WROTE" "already has exactly" "record: the second pass changes nothing"
expect_eq "$(cmp -s "$T/images.first" "$T/images.yaml" && echo same)" "same" "record: the second pass leaves the file byte-identical"

# ── the size guard and the step table ───────────────────────────────────────────────────────
printf '%s\n' "$GATE_SRC" | awk '/<<'"'"'WFTSIZEEOF'"'"'/{on=1; next} /^ *WFTSIZEEOF$/{on=0} on' > "$T/guard.py"
OUT=$(python3 "$T/guard.py" "$WFT_FIXTURE" "" 2>&1); RC=$?
expect_eq "$RC" "0" "size: the matrix pipeline is under the limit"
expect_has "$OUT" "wft-size: " "size: the guard prints the size"
TABLE=$(python3 -I "${HERE}/../../files/engine.py" steps --wft "$WFT_FIXTURE" 2>&1); RC=$?
expect_eq "$RC" "0" "step table: read from the matrix render"
expect_has "$TABLE" '"name":"train"' "step table: the matrix step is listed"
expect_has "$TABLE" '"matrix":{"seed":[1,2,3]}' "step table: its matrix is kept"
expect_lacks "$TABLE" "kaos-gather" "step table: the platform's tasks are not steps"

echo "matrix-pipeline: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
