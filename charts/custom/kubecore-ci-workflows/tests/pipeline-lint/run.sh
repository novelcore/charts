#!/usr/bin/env bash
# The `pipeline-lint` PR check of ml-ci-pr-render (PRD novelcore/kaos#1682 F-02). The three
# steps are EXECUTED against stubs (curl for the GitHub API, git for the gitops clone), not
# grepped; the pin and the wiring are asserted from the rendered chart. Usage (repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/pipeline-lint/run.sh /tmp/rendered.yaml
#
# By default the pinned kaos-lib wheel is replaced by a small stand-in with the same command line,
# so the suite needs no network and no kaos-lib checkout. With KAOS_LIB_WHEEL=<path to a real
# kaos-lib wheel> the REAL linter runs in the same scenarios (and the report is asserted too).
# Needs helm, yq v4, jq, git, python3. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
T=$(mktemp -d); trap 'rm -rf "${T:?}"' EXIT

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -8)" ;;
  esac
}
expect_not() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

# ── the pin and the wiring, from the chart as shipped ───────────────────────────────────────
WHEEL_URL=$(yq '.pipelineLint.kaosLibWheelUrl' "${CHART}/values.yaml")
WHEEL_SHA=$(yq '.pipelineLint.kaosLibWheelSha256' "${CHART}/values.yaml")
RULESET=$(yq '.pipelineLint.rulesetVersion' "${CHART}/values.yaml")
expect_has "$WHEEL_URL" "-python.pkg.dev/kaos-dev-511509/kaos-lib" "the linter is pinned to a wheel of the platform's kaos-lib package index"
case "$WHEEL_URL" in
  *kaos_lib-[0-9]*.[0-9]*.[0-9]*-py3-none-any.whl) expect_eq "pinned" "pinned" "the wheel URL names one exact kaos-lib version" ;;
  *) expect_eq "$WHEEL_URL" "…/kaos_lib-<exact version>-py3-none-any.whl" "the wheel URL names one exact kaos-lib version" ;;
esac
expect_eq "$(printf '%s' "$WHEEL_SHA" | grep -cE '^[0-9a-f]{64}$')" "1" "the wheel sha256 is pinned (64 hex characters)"
expect_eq "$(printf '%s' "$RULESET" | grep -cE '^[0-9]+\.[0-9]+\.[0-9]+$')" "1" "the rule-set version the run insists on is pinned"

PR='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")'
tpl() { yq "$PR | .spec.templates[] | select(.name == \"$1\") | $2" "$RENDERED"; }
CALL=$(yq "$PR | .spec.templates[] | select(.name == \"ml-ci-pr-render\") | .steps[][] | select(.name == \"pipeline-lint\")" "$RENDERED")
expect_has "$CALL" "template: pipeline-lint" "ml-ci-pr-render calls the pipeline-lint steps"
expect_has "$CALL" "failed: true" "a linter that cannot run never fails the render (continueOn failed)"
expect_eq "$(tpl pipeline-lint-run '.automountServiceAccountToken')" "false" "run: no service-account token in the pod that reads the checkout"
expect_eq "$(tpl pipeline-lint-run '.container.volumeMounts[].name' | tr '\n' ' ')" "workspace " "run: only the workspace is mounted (no github-token)"
expect_not "$(tpl pipeline-lint-run '.container.args[0]')" "github-token" "run: the tokenless script never names the token"
expect_not "$(tpl pipeline-lint-prepare '.container.args[0]')$(tpl pipeline-lint-run '.container.args[0]')" "pip install" "no pip install at start-up (the pinned wheel is verified and unzipped)"
expect_has "$(tpl pipeline-lint-run '.container.args[0]')" 'python3 -I "${LINT_CLI}"' "run: the linter starts isolated (-I), outside the checkout"
expect_has "$(tpl pipeline-lint-prepare '.container.args[0]')" "pipeline-lint" "prepare: posts the pipeline-lint status"
expect_not "$(yq '.' "${CHART}/values.yaml")" "pipeline-lint-required" "the status is not made required by the chart (OQ-12)"

# ── a wheel to run: the real one when given, else a stand-in with the same command line ────────
mkdir -p "$T/w/kaos_lib/lint"
if [ -n "${KAOS_LIB_WHEEL:-}" ]; then
  WHEEL="$KAOS_LIB_WHEEL"; REAL=1
else
  REAL=0
  cat > "$T/w/kaos_lib/lint/standalone.py" <<'PYEOF'
import argparse, json, os, sys
p = argparse.ArgumentParser()
p.add_argument("path", nargs="?"); p.add_argument("--format", default="text"); p.add_argument("--output")
p.add_argument("--catalogue"); p.add_argument("--context"); p.add_argument("--export-catalogue")
p.add_argument("--from-report"); p.add_argument("--expect-ruleset"); p.add_argument("--file-link-base")
a = p.parse_args()
out = lambda t: open(a.output, "w").write(t) if a.output else sys.stdout.write(t)
if a.export_catalogue:
    open(a.export_catalogue, "w").write(json.dumps({"stub": "catalogue", "classes": ["gpu-a"]}))
    sys.exit(0)
if a.from_report:
    r = json.load(open(a.from_report)); s = r["summary"]
    out({"markdown": "#### Pipeline lint: %d errors\n" % s["errors"], "status": "%d errors (rule set %s)\n" % (s["errors"], r["ruleset_version"]),
         "text": "stub text\n"}[a.format])
    sys.exit(0)
if a.expect_ruleset and a.expect_ruleset != "2.0.0":
    sys.exit(1)
n = int(os.environ.get("STUB_ERRORS", "0"))
out(json.dumps({"ruleset_version": "2.0.0", "summary": {"errors": n, "warnings": 0, "infos": 0, "skipped": 0},
                "catalogue": {"given": a.catalogue}}))
sys.exit(2 if n else 0)
PYEOF
  touch "$T/w/kaos_lib/lint/__init__.py"
  ( cd "$T/w" && python3 -c "import zipfile; z = zipfile.ZipFile('$T/stub.whl', 'w'); [z.write(f) for f in ('kaos_lib/lint/standalone.py', 'kaos_lib/lint/__init__.py')]" )
  WHEEL="$T/stub.whl"
fi
SHA=$(sha256sum "$WHEEL" | cut -c1-64)
helm template t "$CHART" --set "pipelineLint.kaosLibWheelUrl=file://${WHEEL}" --set "pipelineLint.kaosLibWheelSha256=${SHA}" > "$T/r.yaml" \
  || { echo "FAIL: helm template with the test pin"; exit 1; }
mkdir -p "$T/bin"
# curl stub: GET comments answers $T/comments.json; every call is logged; bodies are kept.
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out=""; method=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in -o) out="$2"; shift ;; -D) : > "$2"; shift ;; -X) method="$2"; shift ;; -d) data="$2"; shift ;;
    -w|-H|--connect-timeout|--max-time) shift ;; -*) ;; *) url="$1" ;; esac; shift
done
echo "$method $url" >> "$STUB_DIR/calls"
[ -z "$data" ] || printf '%s\n' "$data" >> "$STUB_DIR/bodies"
case "$method $url" in
  "GET "*"/comments?"*) cat "$STUB_DIR/comments.json" > "$out"; printf 200 ;;
  "POST "*|"PATCH "*) echo '{}' > "$out"; printf 201 ;;
  *) echo '[]' > "$out"; printf 200 ;;
esac
STUB
cat > "$T/bin/git" <<'STUB'
#!/bin/sh
[ "$1" = clone ] || exit 0
for last; do :; done
cp -r "$STUB_DIR/gitops" "$last"
STUB
printf '#!/bin/sh\nexit 0\n' > "$T/bin/sleep"
chmod +x "$T/bin/curl" "$T/bin/git" "$T/bin/sleep"
printf 'ghs_FAKE_TOKEN_never_logged' > "$T/token"

mkdir -p "$T/gitops/apps/app1/dev"
cat > "$T/gitops/apps/app1/dev/pipeline-context.yaml" <<'CTX'
computeClasses:
  all: [{name: gpu-a, tier: gpu}]
hpc:
  enabled: true
  limits: {maxTimeLimitMinutes: 600}
  resumableSteps:
    - {name: model-training, verified: true, since: "2026-11-09T12:00:00Z", reason: "a continuation loaded its checkpoint and got past it", jobName: THE-JOB-NAME}
lakefs: {adminSecret: THE-SECRET-NAME}
CTX

# script NAME: a rendered step's script with the workflow placeholders and paths filled in.
script() {
  yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render") | .spec.templates[] | select(.name == "'"$1"'") | .container.args[0]' "$T/r.yaml" \
    | sed -e "s#\([ \"=]\)/tmp/#\1@TMP@/#g" -e "s#/etc/github-token/token#$T/token#g" -e "s#/workspace#$T/ws#g" \
          -e "s#{{workflow.parameters.repo_url}}#https://github.com/acme/app.git#g" \
          -e "s#{{workflow.parameters.commit_sha}}#abc123#g" -e "s#{{workflow.parameters.app_name}}#app1#g" \
          -e "s#{{workflow.parameters.gitops_repository}}#gitops#g" -e "s#{{workflow.parameters.gitops_branch}}#dev#g" \
          -e "s#{{workflow.parameters.pr_number}}#${PRN}#g" \
          -e "s#{{workflow.namespace}}#ci#g; s#{{workflow.name}}#wf-1#g; s#{{workflow.uid}}#u-1#g" \
          -e "s#@TMP@#$T/tmp#g"
}

# fresh_workspace: an empty workspace, empty call logs and no PWNED markers.
fresh_workspace() {
  rm -rf "${T:?}/ws" "${T:?}/tmp"; rm -f "${T:?}/calls" "${T:?}/bodies" "${T:?}"/PWNED-*
  mkdir -p "$T/ws/repo" "$T/tmp"; : > "$T/calls"; : > "$T/bodies"
}

# scenario PR_NUMBER COMMENTS_JSON STUB_ERRORS PIPELINE_PY: runs prepare, run, report in order.
# Sets P_RC R_RC REP_RC, CALLS, BODIES.
scenario() {
  PRN="$1"; echo "$2" > "$T/comments.json"
  fresh_workspace
  printf '%s' "$4" > "$T/ws/repo/pipeline.py"
  export STUB_DIR="$T" STUB_ERRORS="$3" PATH="$T/bin:$PATH"
  script pipeline-lint-prepare > "$T/prepare.sh"; script pipeline-lint-run > "$T/run.sh"; script pipeline-lint-report > "$T/report.sh"
  ( cd "$T" && sh "$T/prepare.sh" > "$T/prepare.log" 2>&1 ); P_RC=$?
  ( cd "$T" && sh "$T/run.sh" > "$T/run.log" 2>&1 ); R_RC=$?
  ( cd "$T" && sh "$T/report.sh" > "$T/report.log" 2>&1 ); REP_RC=$?
  CALLS=$(cat "$T/calls"); BODIES=$(cat "$T/bodies")
}
CLEAN_PY='with open("PWNED-pipeline", "w") as f: f.write("ran")
from kubecore.authoring import pipeline, step
with pipeline("p") as p:
    a = step("a", kind="transform")
'
BAD_PY='with open("PWNED-pipeline", "w") as f: f.write("ran")
from kubecore.authoring import pipeline, step
with pipeline("p") as p:
    a = step("a", kind="transform", needs=[b])
    b = step("b", kind="transform")
'
if [ "$REAL" = 1 ]; then STUB_E=0; else STUB_E=1; fi

# 1. errors: pending first, then failure; one new comment; the repository is never executed.
scenario 7 '[]' "$STUB_E" "$BAD_PY"
expect_eq "$P_RC$R_RC$REP_RC" "000" "errors: prepare, run and report all exit 0 (the status carries the verdict)"
expect_eq "$(printf '%s\n' "$CALLS" | grep -c 'POST .*/statuses/abc123')" "2" "errors: exactly two statuses (pending, then the verdict)"
expect_eq "$(grep '"state"' "$T/bodies" | jq -r .state | tr '\n' ' ')" "pending failure " "errors: pending first, then failure"
expect_eq "$(grep '"state"' "$T/bodies" | jq -r .context | sort -u)" "pipeline-lint" "errors: the status context is pipeline-lint"
expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/issues/7/comments" "errors: the first run posts one PR comment"
expect_eq "$(printf '%s\n' "$CALLS" | grep -c 'issues/.*/comments$')" "1" "errors: one comment, not several"
expect_has "$(jq -r 'select(has("body")) | .body' "$T/bodies")" "<!-- kubecore-ci-report:pipeline-lint -->" "errors: the comment carries the marker that finds it again"
expect_eq "$(ls "$T"/PWNED-* 2>/dev/null | wc -l | tr -d ' ')" "0" "the developer's pipeline.py is never executed (no PWNED marker)"
expect_eq "$(ls "$T/ws/repo/PWNED-"* 2>/dev/null | wc -l | tr -d ' ')" "0" "nothing was written into the checkout"
expect_not "$(cat "$T"/*.log)" "ghs_FAKE_TOKEN" "the token never reaches a log"
expect_not "$(cat "$T/ws/lint/catalogue.json")" "THE-SECRET-NAME" "the catalogue keeps none of the context's secrets"
expect_has "$(cat "$T/ws/lint/catalogue.json")" "gpu-a" "the catalogue carries the project's classes from the gitops context"
if [ "$REAL" = 1 ]; then
  expect_eq "$(jq -r '.summary.errors' "$T/ws/lint/report.json")" "1" "real linter: one error found in the bad fixture"
  expect_eq "$(jq -r '.catalogue.source' "$T/ws/lint/report.json")" "platform context" "real linter: the report names the platform context as its source (the same bytes as kaosctl lint --context)"
  expect_eq "$(jq -r '.catalogue.resumableSteps[0] | "\(.name) \(.verified)"' "$T/ws/lint/report.json")" "model-training true" "real linter: the platform's resumable-step record reaches the report"
  expect_not "$(cat "$T/ws/lint/catalogue.json")" "THE-JOB-NAME" "real linter: the catalogue keeps the step record's names, verdicts and reasons only, no job details"
  expect_has "$(grep '"state"' "$T/bodies" | tail -1 | jq -r .description)" "1 error" "real linter: the status text counts the errors"
fi

# 2. a push to the same PR with no errors: success; the comment is UPDATED, never duplicated.
scenario 7 '[{"id":99,"body":"<!-- kubecore-ci-report:pipeline-lint -->\nold"},{"id":5,"body":"hello"}]' 0 "$CLEAN_PY"
expect_eq "$(grep '"state"' "$T/bodies" | jq -r .state | tr '\n' ' ')" "pending success " "clean: pending, then success (warnings and infos never fail it)"
expect_has "$CALLS" "PATCH https://api.github.com/repos/acme/app/issues/comments/99" "clean: the existing comment is edited in place"
expect_eq "$(printf '%s\n' "$CALLS" | grep -c 'POST .*/comments')" "0" "clean: no second comment is created"

# 3. a run without a PR number posts the status only.
scenario "" '[]' 0 "$CLEAN_PY"
expect_eq "$(printf '%s\n' "$CALLS" | grep -c 'comments')" "0" "no PR number: no comment is touched"
expect_eq "$(grep '"state"' "$T/bodies" | jq -r .state | tr '\n' ' ')" "pending success " "no PR number: the status is still posted"

# 4. the pinned wheel does not match its sha256: nothing is run, and the status says so (error, not a silent pending).
scenario 7 '[]' 0 "$CLEAN_PY"
fresh_workspace
sed "s#${SHA}#0000000000000000000000000000000000000000000000000000000000000000#" "$T/prepare.sh" > "$T/prepare-bad.sh"
( cd "$T" && sh "$T/prepare-bad.sh" > "$T/prepare.log" 2>&1 ); P_RC=$?
( cd "$T" && sh "$T/run.sh" > "$T/run.log" 2>&1 ); R_RC=$?
( cd "$T" && sh "$T/report.sh" > "$T/report.log" 2>&1 ); REP_RC=$?
CALLS=$(cat "$T/calls")
expect_eq "$P_RC$R_RC" "00" "bad wheel: prepare and run still exit 0"
expect_eq "$REP_RC" "1" "bad wheel: report exits 1 so the node is red in the Argo run"
expect_eq "$(grep '"state"' "$T/bodies" | jq -r .state | tr '\n' ' ')" "pending error " "bad wheel: the status ends as error"
expect_has "$(grep '"state"' "$T/bodies" | tail -1 | jq -r .description)" "could not run" "bad wheel: the status says the check could not run"
expect_eq "$(printf '%s\n' "$CALLS" | grep -c 'comments')" "0" "bad wheel: no comment"

echo "passed: ${PASSED}, failed: ${FAILED}"
exit "$FAILED"
