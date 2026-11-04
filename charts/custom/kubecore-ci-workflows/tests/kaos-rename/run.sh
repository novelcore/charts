#!/usr/bin/env bash
# The kubecore -> kaos rename of what an app's developers see (checks on their
# commits, the engine folder in their repo). Existing app repos keep the old
# names, so every old name must keep working. Usage (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/kaos-rename/run.sh
#
# The scripts under test are EXECUTED against stub curl / a fixture enhancer
# tarball. Needs helm, yq v4, jq, python3 + PyYAML. Exit status = failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0; PASSED=0

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
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

BASE_TMP=$(mktemp -d); trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

tmpl() { yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\") | .spec.templates[] | select(.name == \"$2\")" "$RENDERED"; }

# ── 1. commit-status contexts ───────────────────────────────────────────────
ctx_default() { tmpl "$1" status | yq '.inputs.parameters[] | select(.name == "context") | .value'; }
expect_eq "$(ctx_default ci-build)" "kaos-ci" "ci-build: status context defaults to kaos-ci"
expect_eq "$(ctx_default ci-rc-build)" "kaos-ci/rc" "ci-rc-build: status context defaults to kaos-ci/rc"
expect_eq "$(ctx_default ml-ci-build)" "kaos-ml-ci" "ml-ci-build: status context defaults to kaos-ml-ci"
expect_eq "$(grep -cE '"(kubecore-ml-ci|kubecore-ci/rc)"' "$RENDERED")" "0" \
  "no template names kubecore-ml-ci or kubecore-ci/rc any more"

# post CONTEXT WF: run the rendered status script of WF with the given context
# against a stub curl; prints the contexts it posted, one per line.
status_contexts() {
  local T; T=$(mktemp -d "${BASE_TMP}/st-XXXX"); mkdir -p "$T/bin"
  cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out=""; hdr=""; method=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;; -D) hdr="$2"; shift ;; -X) method="$2"; shift ;; -d) data="$2"; shift ;;
    -w|-H|--connect-timeout|--max-time) shift ;; -*) ;; *) url="$1" ;;
  esac; shift
done
: > "$hdr"
[ -z "$data" ] || echo "$data" >> "$STUB_DIR/bodies"
case "$method $url" in
  "POST "*'/deployments') echo '{"id":4242}' > "$out" ;;
  "GET "*'deployments?sha='*) echo '[{"id":4242}]' > "$out" ;;
  "POST "*) echo '{}' > "$out" ;;
  *) echo '[]' > "$out" ;;
esac
printf '201'
STUB
  printf '#!/bin/sh\n' > "$T/bin/sleep"; chmod +x "$T/bin/curl" "$T/bin/sleep"
  printf 'tok' > "$T/token"; : > "$T/bodies"
  tmpl "$1" status | yq '.container.args[0]' \
    | sed -e "s#/etc/github-token/token#$T/token#g" \
          -e "s#{{workflow.parameters.repo_url}}#https://github.com/acme/app.git#g" \
          -e "s#{{workflow.parameters.commit_sha}}#abc123#g" \
          -e "s#{{workflow.parameters.branch}}#refs/heads/dev#g" \
          -e "s#{{workflow.parameters.event_type}}#push#g" \
          -e "s#{{workflow.namespace}}#ci#g; s#{{workflow.name}}#wf-1#g; s#{{workflow.uid}}#u-1#g" \
          -e "s#{{inputs.parameters.state}}#pending#g; s#{{inputs.parameters.description}}#d#g" \
          -e "s#{{inputs.parameters.context}}#$2#g; s#{{inputs.parameters.environment}}#auto#g" > "$T/run.sh"
  ( cd "$T" && PATH="$T/bin:$PATH" STUB_DIR="$T" sh "$T/run.sh" >/dev/null 2>&1 )
  jq -r 'select(.context) | .context' "$T/bodies" | tr '\n' ' '
}
expect_eq "$(status_contexts ci-build kaos-ci)" "kaos-ci kubecore-ci " \
  "ci-build: kaos-ci is posted under BOTH names (kubecore-ci is still required by the ruleset)"
expect_eq "$(status_contexts ci-build kubecore-ci)" "kubecore-ci " \
  "ci-build: an explicit kubecore-ci context is posted as given, once"
expect_eq "$(status_contexts ml-ci-build kaos-ml-ci)" "kaos-ml-ci " "ml-ci-build: posts only kaos-ml-ci"
expect_eq "$(status_contexts ci-rc-build kaos-ci/rc)" "kaos-ci/rc " "ci-rc-build: posts only kaos-ci/rc"

# The report comment: a comment left under the old check name is updated, not duplicated.
REPORT=$(tmpl ml-ci-build report | yq '.container.args[0]')
expect_has "$REPORT" "OLD_MARKER" "report: also finds a comment written under the old check name"
expect_has "$REPORT" "startswith(\$m) or startswith(\$o)" "report: upsert matches either marker"

# ── 2. ci-reconcile accepts either status as "built" ────────────────────────
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
needs_build() {  # $1 = status contexts present (space separated) -> prints needs_build
  local T; T=$(mktemp -d "${BASE_TMP}/rc-XXXX"); mkdir -p "$T/bin" "$T/tmp"
  local sj='[]'; local c
  for c in $1; do sj=$(printf '%s' "$sj" | jq -c --arg c "$c" '. + [{context:$c,state:"success"}]'); done
  printf '%s' "$sj" | jq -c '{statuses: .}' > "$T/status.json"
  cat > "$T/bin/curl" <<STUB
#!/bin/sh
for a in "\$@"; do url="\$a"; done
case "\$url" in
  */commits/*/status) cat "$T/status.json" ;;
  */commits/*) echo '{"sha":"$HEAD_SHA"}' ;;
esac
STUB
  cat > "$T/bin/kubectl" <<'STUB'
#!/bin/sh
echo '{"items":[]}'
STUB
  chmod +x "$T/bin/curl" "$T/bin/kubectl"; printf 'tok' > "$T/token"
  tmpl ci-reconcile check-drift | yq '.container.args[0]' \
    | sed -e "s#/tmp/#$T/tmp/#g; s#/etc/github-token/token#$T/token#g" \
          -e "s#{{workflow.parameters.app_name}}#app#g; s#{{workflow.parameters.project_name}}#proj#g" \
          -e "s#{{workflow.parameters.ci_namespace}}#ci#g; s#{{workflow.parameters.branch}}#dev#g" \
          -e "s#{{workflow.parameters.repo_url}}#https://github.com/acme/proj-app.git#g" > "$T/run.sh"
  ( cd "$T" && PATH="$T/bin:$PATH" sh "$T/run.sh" >"$T/out" 2>&1 )
  cat "$T/tmp/needs_build" 2>/dev/null || { echo "no needs_build; output:"; tail -5 "$T/out"; }
}
expect_eq "$(needs_build "")" "true" "reconcile: no status on HEAD -> build (dropped webhook)"
expect_eq "$(needs_build "kaos-ci")" "false" "reconcile: kaos-ci on HEAD -> already built"
expect_eq "$(needs_build "kubecore-ci")" "false" "reconcile: kubecore-ci on HEAD -> already built (a build from before the rename)"
expect_eq "$(needs_build "kaos-ci kubecore-ci")" "false" "reconcile: both on HEAD -> already built"
expect_eq "$(needs_build "wft-render")" "true" "reconcile: an unrelated status is not a build"

# ── 3. the platform enhancer: either engine package, from the enhancer ref ──
# fixture_enhancer PKG...: a tarball (GitHub's layout) holding each given package,
# whose enhance module records which package ran.
run_enhance() {
  local T; T=$(mktemp -d "${BASE_TMP}/enh-XXXX"); mkdir -p "$T/tmp" "$T/workspace/out"
  printf 'token' > "$T/token"; echo "namespace: proj-ml" > "$T/tmp/context.yaml"
  local pkg
  for pkg in "$@"; do
    mkdir -p "$T/src/org-enhancer-abc/$pkg/local-dev"
    : > "$T/src/org-enhancer-abc/$pkg/__init__.py"
    cat > "$T/src/org-enhancer-abc/$pkg/enhance.py" <<EOF
import argparse, yaml
p = argparse.ArgumentParser()
for a in ("--raw", "--context", "--output"):
    p.add_argument(a, required=True)
args = p.parse_args()
wft = yaml.safe_load(open(args.raw))
wft.setdefault("metadata", {})["annotations"] = {"enhanced-by": "$pkg"}
yaml.safe_dump(wft, open(args.output, "w"))
EOF
  done
  tar -C "$T/src" -czf "$T/enhancer.tar.gz" org-enhancer-abc
  printf 'apiVersion: argoproj.io/v1alpha1\nkind: WorkflowTemplate\nmetadata: {name: app1-pipeline}\nspec: {templates: []}\n' \
    > "$T/workspace/out/raw-workflow-template.yaml"
  { echo 'set -e'
    tmpl ml-ci-build hera-enhance-commit | yq '.container.args[0]' \
      | awk "/python3 - <<'OVERLAYEOF'/ {on=1} on {print} on && /--output \/workspace\/out\/workflow-template.yaml \)/ {exit}" \
      | sed -e "s#/tmp/kubecore-enhancer#$T/tmp/kubecore-enhancer#g" \
            -e "s#/tmp/context.yaml#$T/tmp/context.yaml#g" \
            -e "s#/workspace/#$T/workspace/#g" \
            -e "s#/etc/github-token/token#$T/token#g" \
            -e "s#urllib.request.urlopen(req, timeout=60)#open(\"$T/enhancer.tar.gz\", \"rb\")#"
  } > "$T/enhance.sh"
  ( cd "$T" && env -u PYTHONPATH sh "$T/enhance.sh" >"$T/out" 2>&1 ); RC=$?
  ENH_OUT=$(cat "$T/out")
  ENH_ANN=$(yq '.metadata.annotations."enhanced-by"' "$T/workspace/out/workflow-template.yaml" 2>/dev/null)
}
run_enhance kubecore
expect_eq "$RC:$ENH_ANN" "0:kubecore" "enhancer ref with the old engine package (kubecore/): runs kubecore.enhance"
run_enhance kaos_pipeline
expect_eq "$RC:$ENH_ANN" "0:kaos_pipeline" "enhancer ref with the new engine package (kaos_pipeline/): runs kaos_pipeline.enhance"
run_enhance kubecore kaos_pipeline
expect_eq "$RC:$ENH_ANN" "0:kaos_pipeline" "enhancer ref with both: the new one wins"
run_enhance other
expect_has "$ENH_OUT" "no kaos_pipeline/ or kubecore/ files" "enhancer ref with neither: fails loud"

# ── 4. app repo engine folder: either one rebuilds compose-and-validate ─────
RE=$(grep -oE 'WFT_SRC_RE="[^"]*"' "$RENDERED" | head -1 | sed 's/^WFT_SRC_RE="//; s/"$//')
expect_has "$RE" "kaos_pipeline/|kubecore/" "ml-ci-build: the pipeline-source regex names both engine folders"
for f in kaos_pipeline/authoring.py kubecore/authoring.py pipeline.py config/a.yaml; do
  printf '%s\n' "$f" | grep -qE "$RE"; expect_eq "$?" "0" "a change to $f counts as a pipeline change"
done
printf '%s\n' "README.md" | grep -qE "$RE"; expect_eq "$?" "1" "a change to README.md does not"
CV=$(grep -c 'grep -qE "^(config/|kaos_pipeline/|kubecore/)"' "$RENDERED")
expect_eq "$CV" "1" "compose-and-validate is rebuilt when either engine folder changes"

echo "kaos-rename: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
