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
# bare repo; the enhancer download is served from a fixture tarball. Needs helm,
# yq v4, git, python3 + PyYAML. Exit status is the number of failed assertions.
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

# ── enhancer: unpacked outside the workspace, nothing of the app imported ───

T=$(mktemp -d "${BASE_TMP}/enh-XXXX")
printf 'token' > "$T/token"
mkdir -p "$T/tmp" "$T/workspace/out" "$T/workspace/repo/kubecore" "$T/workspace/repo/steps/step_a" \
         "$T/src/org-enhancer-abc/kubecore/local-dev"
# Fixture platform enhancer: records where yaml came from and its sys.path.
cat > "$T/src/org-enhancer-abc/kubecore/__init__.py" <<'EOF'
EOF
cat > "$T/src/org-enhancer-abc/kubecore/enhance.py" <<'EOF'
import argparse, sys, yaml
p = argparse.ArgumentParser()
for a in ("--raw", "--context", "--output"):
    p.add_argument(a, required=True)
p.add_argument("--catalog", default="")
args = p.parse_args()
wft = yaml.safe_load(open(args.raw))
wft.setdefault("metadata", {})["annotations"] = {"enhanced-by": "platform", "yaml-from": yaml.__file__,
                                                 "sys-path": ":".join(sys.path)}
yaml.safe_dump(wft, open(args.output, "w"))
EOF
echo "must not be unpacked" > "$T/src/org-enhancer-abc/kubecore/local-dev/x"
tar -C "$T/src" -czf "$T/enhancer.tar.gz" org-enhancer-abc
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

# enhance_section WORKFLOW TEMPLATE: from the enhancer unpack through the
# enhance call, with the download served from the fixture tarball.
enhance_section() {
  script_of "$1" "$2" | awk "/python3 - <<'OVERLAYEOF'/ {on=1} on {print} on && /--output \/workspace\/out\/workflow-template.yaml \)/ {exit}" \
    | sed -e "s#/tmp/kubecore-enhancer#$T/tmp/kubecore-enhancer#g" \
          -e "s#/tmp/context.yaml#$T/tmp/context.yaml#g" \
          -e "s#/workspace/#$T/workspace/#g" \
          -e "s#/etc/github-token/token#$T/token#g" \
          -e "s#urllib.request.urlopen(req, timeout=60)#open(\"$T/enhancer.tar.gz\", \"rb\")#"
}

for pair in "ml-ci-build hera-enhance-commit" "ml-ci-pr-render hera-enhance-gate"; do
  set -- $pair
  rm -f "$T"/PWNED-* "$T/workspace/out/workflow-template.yaml"
  { echo 'set -e'; echo 'CATALOG_ARG=""'; enhance_section "$1" "$2"; } > "$T/enhance.sh"
  OUT=$(cd "$T" && env -u PYTHONPATH sh "$T/enhance.sh" 2>&1); RC=$?
  expect_eq "$RC" "0" "$2: enhance exits 0"
  ANN=$(yq '.metadata.annotations' "$T/workspace/out/workflow-template.yaml" 2>/dev/null)
  expect_has "$ANN" "enhanced-by: platform" "$2: the platform enhancer ran (not the vendored copy)"
  case "$ANN" in
    *"yaml-from: $T"*) FAILED=$((FAILED + 1)); echo "FAIL: $2: yaml imported from the checkout" ;;
    *"yaml-from: "*) PASSED=$((PASSED + 1)); echo "PASS: $2: yaml imported from site-packages, not the checkout" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $2: enhancer did not record where yaml came from" ;;
  esac
  case "$ANN" in
    *"$T/workspace"*) FAILED=$((FAILED + 1)); echo "FAIL: $2: workspace on the enhancer's sys.path" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $2: workspace not on the enhancer's sys.path" ;;
  esac
  expect_eq "$(ls "$T/tmp/kubecore-enhancer/kubecore/local-dev" 2>/dev/null)" "" "$2: local-dev not unpacked"
  expect_no_pwn "$T" "$2: no module of the checkout imported"
done

# ── PR gate: runs outside the checkout, still checks steps/<dir>/Dockerfile ──

gate_section() {
  script_of ml-ci-pr-render hera-enhance-gate \
    | awk "/python3 - \/workspace\/out\/workflow-template.yaml <<'GATEEOF'/ {on=1} on {print} on && /^GATEEOF\$/ {exit}" \
    | sed -e "s#/workspace/#$T/workspace/#g"
}
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

echo "untrusted-workspace: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
