#!/usr/bin/env bash
# Tests for the rendered-WorkflowTemplate size guard and the shared checkpoint helper ConfigMap.
# Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/wft-size/run.sh /tmp/rendered.yaml
#
# The guard is EXECUTED: extracted from the rendered ml-ci-build hera-enhance-commit and run on
# fixture WorkflowTemplates just under and over the limit. Needs yq v4, python3 + PyYAML.
# Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"; echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LIMIT_KIB=$(yq '.wftSize.limitKiB' "${CHART}/values.yaml")
expect_eq "$LIMIT_KIB" "900" "the size limit is 900 KiB (etcd's object limit is ~1.5 MiB)"

COMMIT="${T}/commit.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.args[0]' "$RENDERED" > "$COMMIT"
GATE="${T}/gate.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")
    | .spec.templates[] | select(.name == "hera-enhance-gate") | .container.args[0]' "$RENDERED" > "$GATE"

# The guard's python, as the commit step runs it (heredoc body between the markers, dedented).
guard_of() { awk '/<<'"'"'WFTSIZEEOF'"'"'/{on=1; next} /^ *WFTSIZEEOF$/{on=0} on' "$1"; }
guard_of "$COMMIT" > "${T}/guard-commit.py"
guard_of "$GATE" > "${T}/guard-gate.py"
expect_eq "$([ -s "${T}/guard-commit.py" ] && echo yes)" "yes" "the merge build carries the size guard"
expect_eq "$([ -s "${T}/guard-gate.py" ] && echo yes)" "yes" "the PR gate carries the size guard"
expect_eq "$(cmp -s "${T}/guard-commit.py" "${T}/guard-gate.py" && echo same)" "same" "both gates run the same guard"

# fixture(kib): a WorkflowTemplate whose file is about <kib> KiB, made of five templates.
fixture() {
  python3 - "$T/wft.yaml" "$1" <<'PYEOF'
import sys, yaml
kib = int(sys.argv[2])
tpls = [{"name": f"step-{i}", "container": {"image": "x", "args": ["a" * (kib * 1024 // 5 - 60)]}} for i in range(5)]
yaml.safe_dump({"spec": {"templates": tpls}}, open(sys.argv[1], "w"), default_flow_style=False)
PYEOF
}

fixture 800
OUT=$(python3 "${T}/guard-commit.py" "$T/wft.yaml" "" 2>&1); RC=$?
expect_eq "$RC" "0" "a render under the limit passes"
expect_has "$OUT" "wft-size: " "the guard prints the size"

: > "$T/summary"; python3 "${T}/guard-gate.py" "$T/wft.yaml" "$T/summary" >/dev/null 2>&1
expect_has "$(cat "$T/summary")" " KiB" "the PR gate appends the size to the status summary"

fixture 950
OUT=$(python3 "${T}/guard-commit.py" "$T/wft.yaml" "" 2>&1); RC=$?
expect_eq "$RC" "1" "a render over the limit fails"
expect_has "$OUT" "GATE FAIL: the rendered WorkflowTemplate is" "the failure says what is wrong"
expect_has "$OUT" "limit" "the failure names the limit"
expect_has "$OUT" "Biggest templates: step-" "the failure names the biggest templates"

# The size is reported in pipeline-images and never pruned or digest-pinned as an image key.
WRITER="${T}/writer.py"
awk '/<<'"'"'IMGEOF'"'"'/{on=1; next} /^ *IMGEOF$/{on=0} on' "$COMMIT" > "$WRITER"
cat > "$T/images.yaml" <<'YEOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: app1-pipeline-images, namespace: proj-train}
data: {last-built-sha: aaaa, step-a: "reg/app:step-a-1", wft-bytes: "1"}
YEOF
python3 - "$T/wft.yaml" <<'PYEOF'
import sys, yaml
yaml.safe_dump({"metadata": {"name": "app1-pipeline", "namespace": "proj-train"},
                "spec": {"arguments": {"parameters": [{"name": "image-step-a",
                    "valueFrom": {"configMapKeyRef": {"name": "app1-pipeline-images", "key": "step-a"}}}]}}},
               open(sys.argv[1], "w"))
PYEOF
python3 "$WRITER" "$T/wft.yaml" "$T/images.yaml" app1 "" "" "" 251260 >/dev/null 2>&1
expect_eq "$(yq '.data["wft-bytes"]' "$T/images.yaml")" "251260" "a render records the size as wft-bytes"
python3 "$WRITER" "$T/wft.yaml" "$T/images.yaml" app1 "" "" "" "" >/dev/null 2>&1
expect_eq "$(yq '.data["wft-bytes"]' "$T/images.yaml")" "251260" "wft-bytes is not pruned as a stale step key"
# The same with the record read from template inputs (the engine after the images moved): no image is an argument.
python3 - "$T/wft-inputs.yaml" <<'PYEOF'
import sys, yaml
yaml.safe_dump({"metadata": {"name": "app1-pipeline", "namespace": "proj-train"},
                "spec": {"templates": [{"name": "compose-and-validate", "inputs": {"parameters": [
                    {"name": "image-step-a",
                     "valueFrom": {"configMapKeyRef": {"name": "app1-pipeline-images", "key": "step-a"}}}]}}]}},
               open(sys.argv[1], "w"))
PYEOF
python3 "$WRITER" "$T/wft-inputs.yaml" "$T/images.yaml" app1 "" "" "" 251261 >/dev/null 2>&1
expect_eq "$(yq '.data["wft-bytes"]' "$T/images.yaml")" "251261" "template inputs: a render records the size as wft-bytes"
expect_eq "$(yq '.data["step-a"]' "$T/images.yaml")" "reg/app:step-a-1" "template inputs: the step's image is kept, not pruned"
PATCH=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
            | .spec.templates[] | select(.name == "patch-images") | .container.args[0]' "$RENDERED")
expect_has "$PATCH" '[ "${KEY}" = "wft-bytes" ] && continue' "the digest-pin loop skips wft-bytes (it is not an image)"

# The checkpoint helper ConfigMap is written by the enhancer and committed with the WFT.
expect_has "$(cat "$COMMIT")" "--helper-configmap /workspace/out/ckpt-helper.yaml" "the enhancer is asked for the helper ConfigMap"
expect_has "$(cat "$COMMIT")" 'cp /workspace/out/ckpt-helper.yaml "$HELPER_FILE"' "the merge build copies it next to the WFT"
expect_has "$(cat "$COMMIT")" 'git add -A -- "${HELPER_FILE}"' "the merge build commits it (and its removal)"

# EXECUTED: the staging snippet must not fail for an app without a helper (git add -A on a missing,
# untracked path exits 128 and reddened every first build of a Hera app without checkpointed steps).
STAGE="${T}/stage.sh"
awk '/^ *if \[ -e "\$\{HELPER_FILE\}" \]/{on=1} on{print} on && /^ *fi$/{exit}' "$COMMIT" > "$STAGE"
expect_eq "$([ -s "$STAGE" ] && echo yes)" "yes" "the merge build guards the helper staging"
G="${T}/gitops"; mkdir -p "$G"; ( cd "$G" && git init -q && git -c user.name=t -c user.email=t@t commit -q --allow-empty -m init )
stage() { ( cd "$G" && set -e && HELPER_FILE="$G/ckpt-helper.yaml" && . "$STAGE" ) >/dev/null 2>&1; echo $?; }
expect_eq "$(stage)" "0" "no helper on disk, none tracked: staging succeeds (a first build)"
echo "kind: ConfigMap" > "$G/ckpt-helper.yaml"
expect_eq "$(stage)" "0" "helper written: staging succeeds"
expect_eq "$(cd "$G" && git diff --cached --name-only)" "ckpt-helper.yaml" "the helper is staged"
( cd "$G" && git -c user.name=t -c user.email=t@t commit -q -m add && rm ckpt-helper.yaml )
expect_eq "$(stage)" "0" "helper removed after being tracked: staging succeeds"
expect_eq "$(cd "$G" && git diff --cached --name-only)" "ckpt-helper.yaml" "the removal is staged"
expect_has "$(cat "$GATE")" "--helper-configmap" "the PR gate renders with the same enhancer flags"

echo "wft-size: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
