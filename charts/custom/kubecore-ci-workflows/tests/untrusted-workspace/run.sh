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
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

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
p.add_argument("--form-data", default="")
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

# ── run-form seal (PRD kaos#1533 F-21, charts issue 234): the token pod runs no repo code ───────
# The seal block of hera-enhance-commit, rendered from the chart, EXECUTED against a booby-trapped workspace. Its inputs
# are valid (tests/run-form-seal/seal_fixtures.py); the trap is everything around them. No PWNED-* marker may appear, and
# the seal either seals (planted files are ignored) or fails closed with the WFT byte-unchanged.
SEALFIX="${HERE}/../run-form-seal"
seal_block() {  # RESULT: the seal block of the step, paths redirected into $R
  script_of ml-ci-build hera-enhance-commit | awk '/^# RUN FORM/{on=1} on && /^# GATE[: ]/{on=0} on' \
    | sed -e "s#/tmp/kaos-run-form#$R/rf#g" -e "s#/tmp/context.yaml#$R/context.yaml#g" -e "s#/tmp/form-data.json#$R/form-data.json#g" \
          -e "s#/tmp/steps.json#$R/steps.json#g" -e "s#/workspace#$R/workspace#g"
}
new_seal_case() {  # sets R: a fresh, valid set of seal inputs under $R (workspace/out, workspace/repo/config)
  R=$(mktemp -d "${BASE_TMP}/seal-XXXX")
  python3 -I -c "
import sys
sys.path.insert(0, '${SEALFIX}')
import seal_fixtures as f
c = f.Case(root='$R'); c.write()" || { echo "FAIL: seal fixtures"; exit 1; }
  seal_block > "$R/seal.sh"
}
run_seal() {  # RUN_DIR: cwd of the step; sets OUT, RC
  OUT=$(cd "$1" && env PYTHONPATH="$R/workspace/repo" COMMIT_SHA=0123456789abcdef0123456789abcdef01234567 ENGINE_VERSION=0.17.0 \
        GITOPS_DIR="$R/gitops" sh -c "set -e; $(cat "$R/seal.sh"); echo SEALED" 2>&1); RC=$?
}
trap_py() {  # a module that writes a marker if it is ever imported
  printf 'open("%s/PWNED-%s", "w").close()\n' "$R" "$2" > "$1"
}
ANN_OF() { yq '.metadata.annotations["ui.kubecore.io/run-form"] | length > 0' "$R/workspace/out/workflow-template.yaml"; }

# 1. planted Python in the checkout and in the output directory; the step's cwd is the checkout, then the out directory
new_seal_case
mkdir -p "$R/workspace/repo/kubecore" "$R/workspace/repo/config"
for d in "$R/workspace/repo" "$R/workspace/out" "$R"; do
  trap_py "$d/sitecustomize.py" "sitecustomize"; trap_py "$d/usercustomize.py" "usercustomize"
  printf 'import os; open("%s/PWNED-pth", "w").close()\n' "$R" > "$d/evil.pth"
  trap_py "$d/yaml.py" "yaml"; trap_py "$d/json.py" "json"; trap_py "$d/re.py" "re"
done
trap_py "$R/workspace/repo/kubecore/__init__.py" "kubecore-init"; trap_py "$R/workspace/repo/kubecore/run_form.py" "kubecore-run-form"
trap_py "$R/workspace/repo/run_form.py" "repo-run-form"
run_seal "$R/workspace/repo"
expect_eq "$RC" "0" "seal: a trapped checkout and output directory (cwd in the checkout) do not stop a valid seal"
expect_has "$OUT" "run form: sealed" "seal: ...it seals"
expect_eq "$(ANN_OF)" "true" "seal: ...and the annotation is there"
expect_no_pwn "$R" "seal: no planted module, sitecustomize or .pth ran (cwd = checkout)"
cp "$R/workspace/out/workflow-template.yaml" "$R/sealed.yaml"
run_seal "$R/workspace/out"
expect_no_pwn "$R" "seal: no planted module ran (cwd = out directory)"

# 2. config/ is a symlink to a directory the render controls: fail closed, the WFT unchanged
new_seal_case
mkdir -p "$R/elsewhere"; printf 'fields:\n  epochs: {label: Hijacked}\n' > "$R/elsewhere/_form.yaml"
rm -rf "$R/workspace/repo/config"; ln -s "$R/elsewhere" "$R/workspace/repo/config"
cp "$R/workspace/out/workflow-template.yaml" "$R/before.yaml"
run_seal "$R/workspace/repo"
expect_eq "$RC" "1" "seal: config/ a symlink fails the step"
expect_has "$OUT" "GATE FAIL: run form:" "seal: ...with the GATE FAIL text"
expect_lacks_str() { case "$1" in *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;; *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;; esac; }
expect_lacks_str "$OUT" "SEALED" "seal: ...before the GATE"
expect_eq "$(cmp "$R/workspace/out/workflow-template.yaml" "$R/before.yaml" && echo same)" "same" "seal: ...and the WFT is byte-unchanged"
expect_no_pwn "$R" "seal: symlinked config/ ran nothing"

# 3. repo is a symlink (the render swapped the checkout directory)
new_seal_case
mkdir -p "$R/other/config"; printf 'fields: {}\n' > "$R/other/config/_form.yaml"
rm -rf "$R/workspace/repo"; ln -s "$R/other" "$R/workspace/repo"
run_seal "$R"
expect_eq "$RC" "1" "seal: repo/ a symlink fails the step"

# 4. _form.yaml a symlink, then a FIFO (must not hang), then a directory
new_seal_case
printf 'fields: {}\n' > "$R/real.yaml"; ln -s "$R/real.yaml" "$R/workspace/repo/config/_form.yaml"
cp "$R/workspace/out/workflow-template.yaml" "$R/before.yaml"
run_seal "$R/workspace/repo"
expect_eq "$RC" "1" "seal: a symlinked _form.yaml fails the step"
expect_eq "$(cmp "$R/workspace/out/workflow-template.yaml" "$R/before.yaml" && echo same)" "same" "seal: ...WFT byte-unchanged"
rm "$R/workspace/repo/config/_form.yaml"; mkfifo "$R/workspace/repo/config/_form.yaml"
run_seal "$R/workspace/repo"
expect_eq "$RC" "1" "seal: a _form.yaml FIFO fails the step without hanging"
rm "$R/workspace/repo/config/_form.yaml"; mkdir "$R/workspace/repo/config/_form.yaml"
run_seal "$R/workspace/repo"
expect_eq "$RC" "1" "seal: a _form.yaml directory fails the step"
expect_no_pwn "$R" "seal: planted _form.yaml entries ran nothing"

# 5. /workspace/out/workflow-template.yaml is a symlink: nothing follows it, its target is untouched
new_seal_case
mv "$R/workspace/out/workflow-template.yaml" "$R/target.yaml"; ln -s "$R/target.yaml" "$R/workspace/out/workflow-template.yaml"
cp "$R/target.yaml" "$R/target.before"
run_seal "$R/workspace/out"
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "seal: a symlinked workflow-template.yaml fails the step"
expect_eq "$(cmp "$R/target.yaml" "$R/target.before" && echo same)" "same" "seal: ...the symlink target is untouched"
expect_eq "$([ -L "$R/workspace/out/workflow-template.yaml" ] && echo link)" "link" "seal: ...and the symlink was not replaced"

# 6. a render that forged the form and platform labels: the seal strips and replaces, whatever is in the checkout
new_seal_case
python3 -I -c "
import yaml
p = '$R/workspace/out/workflow-template.yaml'
w = yaml.safe_load(open(p))
w['metadata']['annotations']['ui.kubecore.io/run-form'] = 'FORGED'
w['metadata']['labels']['platform.kubecore.io/evil'] = 'x'
w['spec']['workflowMetadata']['labelsFrom'] = {'platform.kubecore.io/submitted-by': {'expression': \"'forged'\"}}
yaml.safe_dump(w, open(p, 'w'), sort_keys=False)"
run_seal "$R/workspace/repo"
expect_eq "$RC" "0" "seal: a forged form and forged platform keys are replaced, not trusted"
expect_eq "$(yq '.metadata.annotations["ui.kubecore.io/run-form"] != "FORGED" and (.metadata.labels | has("platform.kubecore.io/evil") | not) and (.spec.workflowMetadata.labelsFrom | length == 0)' "$R/workspace/out/workflow-template.yaml")" "true" "seal: ...no forged key survives"

echo "untrusted-workspace: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
