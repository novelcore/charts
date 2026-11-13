#!/usr/bin/env bash
# Tests for kubecore-operator#1375: no step that holds the GitHub App token runs
# code from the developer-controlled /workspace/repo. Earlier steps run the
# developer's code with write access to that checkout (pipeline.py in
# hera-render, Dockerfile RUN in the image build), and on a PR it is the PR
# head, possibly a fork. Usage (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/untrusted-workspace/run.sh
#
# The scripts under test are EXECUTED against a booby-trapped workspace: every
# trap writes a PWNED-* marker if it ever runs. The tag steps push to a local
# bare repo; the engine wheel download is served from a fixture wheel on localhost.
# Needs helm, yq v4, git, jq, python3 + PyYAML. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0

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
expect_no_pwn() {
  P=$(ls "$1"/PWNED-* 2>/dev/null | xargs -r -n1 basename | tr '\n' ' ')
  expect_eq "${P:-none}" "none" "$2"
}

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.tokenSecretName=ci-token --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

# script_of WORKFLOW TEMPLATE: a step's script from the rendered chart.
script_of() {
  yq "select(.metadata.name == \"$1\") | .spec.templates[] | select(.name == \"$2\") | .container.args[0]" "$RENDERED"
}

# ── tag: pushes from a fresh repo, never from the trapped checkout ───────────

new_tag_case() {
  T=$(mktemp -d "${BASE_TMP}/tag-XXXX")
  printf 'token' > "$T/token"
  git init -q --bare "$T/origin.git"
  git --git-dir="$T/origin.git" config uploadpack.allowReachableSHA1InWant true  # as GitHub
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  ( cd "$T/seed" && echo app > README.md && git add README.md \
      && git -c user.name=t -c user.email=t@t commit -qm init && git push -q origin HEAD:refs/heads/dev )
  SHA=$(git --git-dir="$T/origin.git" rev-parse refs/heads/dev)
  # The developer-controlled checkout at commit_sha, as the clone step leaves
  # it, then as earlier steps may have tampered with it.
  mkdir -p "$T/workspace"
  git clone -q "$T/origin.git" "$T/workspace/repo" 2>/dev/null
  R="$T/workspace/repo"
  git -C "$R" checkout -q "$SHA"
  for h in pre-push post-checkout reference-transaction; do
    printf '#!/bin/sh\ntouch "%s/PWNED-hook-%s"\n' "$T" "$h" > "$R/.git/hooks/$h"
    chmod +x "$R/.git/hooks/$h"
  done
  printf '#!/bin/sh\ntouch "%s/PWNED-fsmonitor"\n' "$T" > "$T/fsmon.sh"; chmod +x "$T/fsmon.sh"
  git -C "$R" config core.fsmonitor "$T/fsmon.sh"
}

run_tag() {
  script_of "$1" tag \
    | sed -e "s#/tmp/tagrepo#$T/tagrepo#g" \
          -e "s#/workspace/#$T/workspace/#g" \
          -e "s#/etc/github-token/token#$T/token#g" \
          -e "s#{{inputs.parameters.new_version}}#1.2.3#g" \
          -e "s#{{inputs.parameters.image_tag}}#dev-v1.2.3-20261001-120000-abc1234#g" \
          -e "s#{{inputs.parameters.rc_tag}}#v1.2.3-rc.1#g" \
          -e "s#{{workflow.parameters.repo_url}}#file://$T/origin.git#g" \
          -e "s#{{workflow.parameters.commit_sha}}#${SHA}#g" > "$T/tag.sh"
  OUT=$(cd "$T" && sh "$T/tag.sh" 2>&1); RC=$?
}

for wf in ml-ci-build ci-build ci-rc-build; do
  new_tag_case; run_tag "$wf"
  case "$wf" in ci-rc-build) TAG=v1.2.3-rc.1 ;; *) TAG=dev-v1.2.3-20261001-120000 ;; esac
  expect_eq "$RC" "0" "$wf/tag: exits 0"
  expect_eq "$(git --git-dir="$T/origin.git" rev-parse "refs/tags/${TAG}^{commit}" 2>/dev/null)" "$SHA" \
    "$wf/tag: ${TAG} lands on commit_sha"
  expect_eq "$(git --git-dir="$T/origin.git" cat-file -t "refs/tags/${TAG}" 2>/dev/null)" "tag" \
    "$wf/tag: annotated, as before"
  expect_no_pwn "$T" "$wf/tag: no hook or .git/config of the checkout runs"
done

# ── enhancer: the engine wheel unpacked outside the workspace, nothing of the app imported ───

T=$(mktemp -d "${BASE_TMP}/enh-XXXX")
printf 'token' > "$T/token"
mkdir -p "$T/tmp" "$T/workspace/out" "$T/workspace/repo/kubecore" "$T/workspace/repo/steps/step_a" \
         "$T/serve" "$T/wheel/kaos_pipeline_engine/kubecore" "$T/wheel/kaos_engine"
# Fixture engine wheel: records where yaml came from and its sys.path.
: > "$T/wheel/kaos_pipeline_engine/kubecore/__init__.py"
: > "$T/wheel/kaos_engine/__init__.py"
cat > "$T/wheel/kaos_pipeline_engine/kubecore/enhance.py" <<'EOF'
import argparse, sys, yaml
p = argparse.ArgumentParser()
for a in ("--raw", "--context", "--output"):
    p.add_argument(a, required=True)
p.add_argument("--catalog", default="")
p.add_argument("--helper-configmap", default="")
args = p.parse_args()
wft = yaml.safe_load(open(args.raw))
wft.setdefault("metadata", {})["annotations"] = {"enhanced-by": "platform", "yaml-from": yaml.__file__,
                                                 "sys-path": ":".join(sys.path)}
yaml.safe_dump(wft, open(args.output, "w"))
EOF
( cd "$T/wheel" && python3 -I -c "
import zipfile
with zipfile.ZipFile('$T/serve/engine.whl', 'w') as z:
    z.write('kaos_pipeline_engine/kubecore/__init__.py'); z.write('kaos_pipeline_engine/kubecore/enhance.py')
    z.write('kaos_engine/__init__.py')" )
WHEEL_SHA=$(sha256sum "$T/serve/engine.whl" | cut -c1-64)
PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -m http.server "$PORT" --bind 127.0.0.1 -d "$T/serve" > /dev/null 2>&1 &
HTTP_PID=$!
trap 'kill $HTTP_PID 2>/dev/null; rm -rf "$BASE_TMP"' EXIT
sleep 1
# The trapped app checkout: shadows yaml, hooks interpreter start-up, and ships
# its own (vendored) kubecore.enhance.
for m in yaml sitecustomize usercustomize; do
  printf 'open("%s/PWNED-%s", "w").close()\n' "$T" "$m" > "$T/workspace/repo/$m.py"
done
printf 'open("%s/PWNED-vendored-enhance", "w").close()\n' "$T" > "$T/workspace/repo/kubecore/enhance.py"
: > "$T/workspace/repo/kubecore/__init__.py"
echo "FROM scratch" > "$T/workspace/repo/steps/step_a/Dockerfile"
cat > "$T/workspace/out/raw-workflow-template.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata: {name: app1-pipeline}
spec:
  arguments:
    parameters:
    - name: image-step-a
  templates:
  - name: step-a
    container: {image: "{{workflow.parameters.image-step-a}}"}
EOF
echo "namespace: proj-ml" > "$T/tmp/context.yaml"

# enhance_section WORKFLOW TEMPLATE: from the engine.py write through the stamp.
enhance_section() {
  script_of "$1" "$2" | awk "/cat > \/tmp\/engine.py <</ {on=1} on {print} on && /engine.py stamp/ {exit}" \
    | sed -e "s#/tmp/#$T/tmp/#g" \
          -e "s#/workspace/#$T/workspace/#g" \
          -e "s#/etc/github-token/token#$T/token#g"
}
engine_json() {  # engine_json URL SHA
  printf '{"version":"v0.4.7","wheel":"%s","wheel_sha256":"%s"}' "$1" "$2"
}
run_enhance() {  # run_enhance ENGINE_JSON
  OUT=$(cd "$T" && env -u PYTHONPATH ENGINE_JSON="$1" sh "$T/enhance.sh" 2>&1); RC=$?
}

for pair in "ml-ci-build hera-enhance-commit" "ml-ci-pr-render hera-enhance-gate"; do
  set -- $pair
  rm -rf "$T"/PWNED-* "$T/workspace/out/workflow-template.yaml" "$T/tmp/kubecore-engine"
  { echo 'set -e'; enhance_section "$1" "$2"; } > "$T/enhance.sh"
  run_enhance "$(engine_json "http://127.0.0.1:${PORT}/engine.whl" "$WHEEL_SHA")"
  expect_eq "$RC" "0" "$2: enhance exits 0"
  ANN=$(yq '.metadata.annotations' "$T/workspace/out/workflow-template.yaml" 2>/dev/null)
  expect_has "$ANN" "enhanced-by: platform" "$2: the platform enhancer ran (not the vendored copy)"
  expect_has "$ANN" "platform.kubecore.io/engine-version: v0.4.7" "$2: the WFT is stamped with the engine version"
  expect_eq "$(yq '.spec.workflowMetadata.labels["platform.kubecore.io/engine"]' "$T/workspace/out/workflow-template.yaml")" "v0.4.7" \
    "$2: the Workflows it makes carry the engine label"
  case "$ANN" in
    *"yaml-from: $T"*) FAILED=$((FAILED + 1)); echo "FAIL: $2: yaml imported from the checkout" ;;
    *"yaml-from: "*) PASSED=$((PASSED + 1)); echo "PASS: $2: yaml imported from site-packages, not the checkout" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $2: enhancer did not record where yaml came from" ;;
  esac
  case "$ANN" in
    *"$T/workspace"*) FAILED=$((FAILED + 1)); echo "FAIL: $2: workspace on the enhancer's sys.path" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $2: workspace not on the enhancer's sys.path" ;;
  esac
  expect_no_pwn "$T" "$2: no module of the checkout imported"

  # Fail closed: a wheel whose sha256 differs from the context's pin enhances nothing.
  rm -rf "$T/workspace/out/workflow-template.yaml" "$T/tmp/kubecore-engine"
  run_enhance "$(engine_json "http://127.0.0.1:${PORT}/engine.whl" "$(printf 'b%.0s' $(seq 64))")"
  expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "$2: a wheel whose sha256 differs fails the step"
  expect_has "$OUT" "sha256 mismatch" "$2: ... and says why"
  expect_eq "$(ls "$T/workspace/out/workflow-template.yaml" 2>/dev/null)" "" "$2: ... and writes no WorkflowTemplate"
  # A wheel that does not download fails the step too (nothing listens on port 9; the retry pause is shortened).
  sed -i 's/^FETCH_PAUSE_SECONDS = .*/FETCH_PAUSE_SECONDS = 0/' "$T/enhance.sh"
  run_enhance "$(engine_json "http://127.0.0.1:9/engine.whl" "$WHEEL_SHA")"
  expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "$2: a wheel that does not download fails the step"
  expect_has "$OUT" "could not be downloaded" "$2: ... and says why"
  # No engine in the build: nothing to enhance with.
  run_enhance ""
  expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "$2: no engine fails the step"
done

# ── PR gate: runs outside the checkout, still checks steps/<dir>/Dockerfile ──

gate_section() {
  script_of ml-ci-pr-render hera-enhance-gate \
    | awk "/python3 - \/workspace\/out\/workflow-template.yaml <<'GATEEOF'/ {on=1} on {print} on && /^GATEEOF\$/ {exit}" \
    | sed -e "s#/workspace/#$T/workspace/#g"
}
# the enhanced WorkflowTemplate the gate reads (the last loop iteration ended on failure cases)
{ echo 'set -e'; enhance_section ml-ci-pr-render hera-enhance-gate; } > "$T/enhance.sh"
rm -rf "$T/tmp/kubecore-engine"
run_enhance "$(engine_json "http://127.0.0.1:${PORT}/engine.whl" "$WHEEL_SHA")"
rm -f "$T"/PWNED-*
gate_section > "$T/gate.sh"
expect_eq "$(script_of ml-ci-pr-render hera-enhance-gate | grep -c 'cd /workspace/repo')" "0" \
  "hera-enhance-gate: never cds into the checkout"
OUT=$(cd "$T" && sh "$T/gate.sh" 2>&1); RC=$?
expect_eq "$RC" "0" "gate: step with a Dockerfile passes"
expect_has "$OUT" "GATE OK" "gate: reports OK"
rm -r "$T/workspace/repo/steps/step_a"
OUT=$(cd "$T" && sh "$T/gate.sh" 2>&1); RC=$?
expect_eq "$RC" "1" "gate: step without a Dockerfile fails"
expect_has "$OUT" "expected steps/step_a/Dockerfile" "gate: names the missing file relative to the repo"
expect_no_pwn "$T" "gate: no module of the checkout imported"

# The gate also reads the shape of the engine after the images moved: the step's template is named after the step and
# its container image is the template's own input `image` (the task fills it from the image record).
mkdir -p "$T/workspace/repo/steps/step_a"
cat > "$T/workspace/out/workflow-template.yaml" <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: WorkflowTemplate
metadata: {name: app1-pipeline}
spec:
  arguments:
    parameters: [{name: promote-x, value: "false"}]
  templates:
  - name: compose-and-validate
    inputs: {parameters: [{name: image}]}
    container: {image: "{{inputs.parameters.image}}"}
  - name: kaos-promote
    inputs: {parameters: [{name: image}]}
    container: {image: "{{inputs.parameters.image}}"}
  - name: hpc-follower
    inputs: {parameters: [{name: image}]}
    container: {image: "registry.example/follower:1"}
  - name: step-a
    inputs: {parameters: [{name: image}]}
    container: {image: "{{inputs.parameters.image}}"}
EOF
echo "FROM scratch" > "$T/workspace/repo/steps/step_a/Dockerfile"
OUT=$(cd "$T" && sh "$T/gate.sh" 2>&1); RC=$?
expect_eq "$RC" "0" "gate (template inputs): the platform's own templates need no folder, the step has its Dockerfile"
expect_has "$(cat "$T/workspace/report-extra.md")" '| `step-a` | built from `steps/step_a/` |' "gate (template inputs): the report names the step's folder"
expect_has "$(cat "$T/workspace/report-extra.md")" '| `kaos-promote` | built by the platform |' "gate (template inputs): the final task is the platform's"
rm -r "$T/workspace/repo/steps/step_a"
OUT=$(cd "$T" && sh "$T/gate.sh" 2>&1); RC=$?
expect_eq "$RC" "1" "gate (template inputs): a step without a Dockerfile fails"
expect_has "$OUT" "expected steps/step_a/Dockerfile" "gate (template inputs): names the missing file"

echo "untrusted-workspace: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
