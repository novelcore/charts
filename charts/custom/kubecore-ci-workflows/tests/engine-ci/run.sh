#!/usr/bin/env bash
# The chart's engine-only CI scripts (PRD-HPC-1461 D-80), EXECUTED against stubs, not grepped:
#   - hera-render: the one render step (engine image, `python -I -m kaos_engine.render`, no `pip install -e .`),
#     and that a failed render leaves no raw WorkflowTemplate for the enhance step;
#   - detect-steps: the engine of the build, the schema profile, and when the chart-owned
#     compose-and-validate image is rebuilt (config/ changed, the engine moved, kaos-lib moved);
#   - the compose Dockerfile (files/compose.Dockerfile) as build-push hands it to kaniko;
#   - hera-enhance-commit: nothing replaces the live WorkflowTemplate before the render, enhance and gates pass;
#   - the exit handler's engine-record: `engine-last-error` / `engine-attempt` written and cleared;
#   - PRD novelcore/kaos#1911 AC-01: an app made before the current pipelines is refused before
#     anything is built or committed (detect-steps for its kaos-lib, hera-render for its pipeline.py), and
#     engine-record turns that into the commit status, the error record and the one-attempt record.
# The wheel download and the sha256 check are in tests/untrusted-workspace, files/engine.py in tests/engine,
# ENGINE DRIFT and its one-attempt-per-hour guard in tests/engine-drift. Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/engine-ci/run.sh /tmp/rendered.yaml
#
# Needs yq v4, jq, git, python3 + PyYAML. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
APP=app1
ENG=v0.4.7
OLD_ENG=v0.4.6
ENGINE_IMAGE="reg.example/kaos-pipeline-engine:${ENG}"
SPEC="kaos-lib==0.5.0"
OLD_APP_SENTENCE="This app was made before the current pipelines. Create it again from the template."
STATUS_TEXT="Not built: this app was made before the current pipelines. Create it again from the template."

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
BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT

# script WORKFLOW TEMPLATE: the main container's script of a template.
script() {
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")
      | .spec.templates[] | select(.name == \"$2\") | .container.args[0]" "$RENDERED"
}
tpl() {  # tpl WORKFLOW TEMPLATE EXPR
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")
      | .spec.templates[] | select(.name == \"$2\") | $3" "$RENDERED"
}

# ── hera-render ──────────────────────────────────────────────────────────────

RENDER_SRC=$(script ml-ci-build hera-render)
expect_eq "$(tpl ml-ci-build hera-render '.container.image')" '{{inputs.parameters.engine_image}}' "hera-render: runs the engine image the context pins"
expect_has "$RENDER_SRC" 'python -I -m kaos_engine.render pipeline.py --repo /workspace/repo --profile "${ENGINE_PROFILE}"' "hera-render: renders with the engine runner"
expect_not "$(printf '%s\n' "$RENDER_SRC" | grep -v '^[[:space:]]*#')" "pip install -e" "hera-render: never installs the app (no pip install -e .)"
expect_not "$(printf '%s\n' "$RENDER_SRC" | grep -v '^[[:space:]]*#')" "PYTHONPATH" "hera-render: no PYTHONPATH into the app checkout"
expect_eq "$(tpl ml-ci-build hera-render '.automountServiceAccountToken')" "false" "hera-render: no service-account token in the pod that runs untrusted code"
expect_eq "$(tpl ml-ci-build hera-render '.container.volumeMounts[].name' | tr '\n' ' ')" "workspace scratch python-overlay " "hera-render: no github-token mount (workspace, scratch and the python overlay only)"
expect_eq "$(tpl ml-ci-build hera-render '.container.env[] | select(.name == "ENGINE_PROFILE") | .value')" '{{inputs.parameters.engine_profile}}' "hera-render: the profile reaches the script as an env var"
expect_eq "$(yq 'select(.metadata.name == "ml-ci-pr-render") | .spec.templates[] | select(.name == "ml-ci-pr-render") | .steps[][] | select(.name == "hera-render") | .templateRef.template' "$RENDERED")" \
  "hera-render" "the PR check renders with the same template as the merge build"

# run_render STUB_BEHAVIOUR: the script against a stub python; the stub logs its arguments.
#   STUB_BEHAVIOUR ok: render writes out/raw-workflow-template.yaml; fail: exits 1 (pipeline.py raised);
#   deps: the extra-dependencies call prints one requirement.
OLD_APP_ERROR_DEFAULT="kubecore.authoring.AuthoringError: step 'hello-world' has no kind=. Every step declares what it does: kind= is one of ingest, transform, train, evaluate, publish, control (for example step('hello-world', kind='transform', ...)). ${OLD_APP_SENTENCE}"
run_render() {
  OLD_APP_ERROR="${OLD_APP_ERROR:-$OLD_APP_ERROR_DEFAULT}"
  T=$(mktemp -d "${BASE_TMP}/render-XXXX"); mkdir -p "$T/bin" "$T/workspace/repo/out" "$T/workspace/out"
  printf 'stale\n' > "$T/workspace/out/raw-workflow-template.yaml"   # a previous render of the same workspace
  printf 'stale\n' > "$T/workspace/repo/out/raw-workflow-template.yaml"
  # A stand-in engine package: only what the chart reads of it, the marker of an old app's refusal.
  mkdir -p "$T/pkg/kaos_pipeline_engine"; : > "$T/pkg/kaos_pipeline_engine/__init__.py"
  printf '{"old_app_marker": "Create it again from the template."}\n' > "$T/pkg/kaos_pipeline_engine/authoring-schema.json"
  printf '%s\n' "$OLD_APP_ERROR" > "$T/old-error"   # what the engine prints for an app from before the step contract
  cat > "$T/bin/python" <<EOF
#!/usr/bin/env bash
echo "python \$*" >> "$T/calls"
case "\$*" in
  *"extra_dependencies"*) [ "$1" = deps ] && echo "scikit-image>=0.22" ;;
  *"-m kaos_engine.render"*) [ "$1" = fail ] && { echo "pipeline.py raised" >&2; exit 1; }
                             [ "$1" = old ] && { printf 'Traceback (most recent call last):\n  File "pipeline.py", line 9\n' >&2; cat "$T/old-error" >&2; exit 1; }
                             echo "kind: WorkflowTemplate" > out/raw-workflow-template.yaml ;;
  *"-m pip freeze"*) echo "hera==5.27.0" ;;
  "-I - "*) shift 2; PYTHONPATH="$T/pkg" exec python3 - "\$@" ;;   # the refusal reader, run for real
esac
exit 0
EOF
  chmod +x "$T/bin/python"
  { echo 'set -e'; printf '%s\n' "$RENDER_SRC" | sed -e "s#/tmp/#$T/#g" -e "s#/workspace#$T/workspace#g" \
      -e "s#{{inputs.parameters.engine_image}}#${ENGINE_IMAGE}#g"; } > "$T/render.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" ENGINE_PROFILE="${2:-hera}" bash "$T/render.sh" 2>&1); RC=$?
  CALLS=$(cat "$T/calls" 2>/dev/null)
}
run_render ok yolo
expect_eq "$RC" 0 "hera-render: runs"
expect_has "$CALLS" "python -I -m kaos_engine.render pipeline.py --repo $T/workspace/repo --profile yolo" "hera-render: the profile of the build is passed to the runner"
expect_not "$CALLS" "pip install" "hera-render: an app with no extra dependencies installs nothing"
expect_has "$(cat "$T/workspace/out/raw-workflow-template.yaml")" "kind: WorkflowTemplate" "hera-render: the raw WorkflowTemplate lands where the enhance step reads it"
run_render deps hera
expect_has "$CALLS" "python -m pip freeze --exclude-editable" "hera-render: the engine's own versions become the constraints"
expect_has "$CALLS" "python -m pip install --quiet -c $T/engine-constraints.txt -r $T/extra-deps.txt" "hera-render: only the missing app dependencies install, under those constraints"
run_render fail hera
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "hera-render: a render that fails fails the step"
expect_eq "$(ls "$T/workspace/out/raw-workflow-template.yaml" 2>/dev/null)" "" "hera-render: ... and leaves no raw WorkflowTemplate of an earlier render behind"
expect_has "$OUT" "pipeline.py raised" "hera-render: the render's own error stays in the step log"
expect_eq "$(ls "$T/workspace/old-app" "$T/workspace/report-extra.md" 2>/dev/null)" "" "hera-render: a render that fails for another reason is not reported as an app that has not moved"

# PRD novelcore/kaos#1911 AC-01: an app made before the current pipelines. The engine refuses it with a
# message that ends with its old_app_marker; the chart reports the reason and says to create the app again.
run_render old hera
expect_eq "$RC" "1" "hera-render (old app): the step fails with the render's exit code"
expect_eq "$(ls "$T/workspace/out/raw-workflow-template.yaml" 2>/dev/null)" "" "hera-render (old app): no raw WorkflowTemplate for the enhance step"
WHAT="step 'hello-world' has no kind=. Every step declares what it does: kind= is one of ingest, transform, train, evaluate, publish, control (for example step('hello-world', kind='transform', ...))."
expect_eq "$(cat "$T/workspace/old-app" 2>/dev/null)" "$WHAT" "hera-render (old app): the reason is left for the report, without the exception name and the old-app sentence"
expect_has "$OUT" "kaos-ci: OLD APP: $WHAT $OLD_APP_SENTENCE" "hera-render (old app): ... and is one line of the step log"
EXTRA=$(cat "$T/workspace/report-extra.md" 2>/dev/null)
expect_has "$EXTRA" "#### What to change" "hera-render (old app): the report comment gets a section"
expect_has "$EXTRA" "$WHAT" "hera-render (old app): ... with the engine's message"
expect_has "$EXTRA" "Create it again from the template." "hera-render (old app): ... and what to do"
expect_not "$EXTRA" "http" "hera-render (old app): ... with no guide to link"
expect_not "$EXTRA" "kaosctl" "hera-render (old app): ... and no command that moves the app"
expect_has "$EXTRA" "the pipeline you could run before this commit is still the one that runs" "hera-render (old app): says the app keeps the pipeline it had"
for WORD in Argo argo workflow Workflow namespace cluster kubectl ConfigMap gitops; do
  expect_not "$EXTRA" "$WORD" "hera-render (old app): the report section does not name the platform's internals ($WORD)"
done
OLD_APP_ERROR="kubecore.authoring.AuthoringError: step 'train': hpc_time_limit= was removed. Write walltime= with the same value (walltime='12h'). ${OLD_APP_SENTENCE}" run_render old hera
expect_eq "$(cat "$T/workspace/old-app" 2>/dev/null)" "step 'train': hpc_time_limit= was removed. Write walltime= with the same value (walltime='12h')." "hera-render (old app): a removed keyword is reported the same way"
OLD_APP_ERROR="kubecore.authoring.AuthoringError: step 'x' is wrong. ${OLD_APP_SENTENCE}" run_render old hera
expect_eq "$(cat "$T/workspace/old-app" 2>/dev/null)" "step 'x' is wrong." "hera-render (old app): the old-app sentence is not part of the reason"
OLD_APP_ERROR="kubecore.authoring.AuthoringError: ${OLD_APP_SENTENCE}" run_render old hera
expect_eq "$RC/$(cat "$T/workspace/old-app" 2>/dev/null | wc -c)" "1/1" "hera-render (old app): a refusal that is only the old-app sentence is still reported (an empty reason)"
expect_has "$(cat "$T/workspace/report-extra.md" 2>/dev/null)" "Create it again from the template." "hera-render (old app): ... with its section"
OLD_APP_ERROR="kubecore.authoring.AuthoringError: step 'x' has a bad walltime." run_render old hera
expect_eq "$RC/$(ls "$T/workspace/old-app" 2>/dev/null)" "1/" "hera-render: a refusal without the marker is an ordinary failure, not an old app"
OLD_APP_ERROR="kubecore.authoring.AuthoringError: step 'x': bad \`name\` \$(id) ${OLD_APP_SENTENCE}" run_render old hera
expect_eq "$(cat "$T/workspace/old-app" 2>/dev/null)" "step 'x': bad name \$(id)" "hera-render (old app): the message is data (backticks dropped, nothing evaluated)"

# ── a failed render never replaces the live WorkflowTemplate ─────────────────

GROUPS_OF=$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "render-hera")
                | .steps | map(map(.name) | join("+")) | join(" > ")' "$RENDERED")
expect_eq "$GROUPS_OF" "hera-render > hera-enhance-commit" "render-hera: the commit step starts only after the render step succeeded"
expect_eq "$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "render-hera") | .steps[][] | select(.continueOn) | .name' "$RENDERED" | grep -vc '^---$')" "0" \
  "render-hera: no step continues on failure (a failed render fails the group)"
COMMIT_SRC=$(script ml-ci-build hera-enhance-commit)
pos() { printf '%s\n' "$COMMIT_SRC" | grep -n -m1 -F -- "$1" | cut -d: -f1; }
P_ENH=$(pos 'engine.py fetch'); P_GATE=$(pos 'GATE OK'); P_SIZE=$(pos 'WFTSIZEEOF'); P_CP=$(pos 'cp /workspace/out/workflow-template.yaml "$WFT_FILE"'); P_PUSH=$(pos 'git push')
[ "$P_ENH" -lt "$P_GATE" ] && [ "$P_GATE" -lt "$P_SIZE" ] && [ "$P_SIZE" -lt "$P_CP" ] && [ "$P_CP" -lt "$P_PUSH" ] \
  && expect_eq ok ok "hera-enhance-commit: the live WFT file is written only after the enhance, the gate and the size guard (set -e before all)" \
  || expect_eq "enh=$P_ENH gate=$P_GATE size=$P_SIZE cp=$P_CP push=$P_PUSH" "increasing" "hera-enhance-commit: order of enhance, gate, size guard, write, push"
expect_eq "$(printf '%s\n' "$COMMIT_SRC" | grep -m1 -v '^$')" "set -e" "hera-enhance-commit: set -e from the first line"

# ── detect-steps: the engine, the profile, the compose rebuild triggers ──────

DETECT_SRC="${BASE_TMP}/detect.src"; script ml-ci-build detect-steps > "$DETECT_SRC"

# detect_case: an app repo (pipeline.py, config/, steps a) already built, and a gitops fixture whose
# pipeline-images records ENGINE_COMPOSE ("-" = absent) and kaos-lib-package KL, with a context naming
# engine ENG (ENGINE_IN_CTX=no: none).
detect_case() {  # detect_case ENGINE_COMPOSE [KL]
  T=$(mktemp -d "${BASE_TMP}/detect-XXXXXX")
  mkdir -p "$T/bin" "$T/workspace/repo/steps/a" "$T/workspace/repo/steps/compose_and_validate" "$T/workspace/repo/config" "$T/fixture/kubeapps/${APP}/main"
  printf 'token' > "$T/token"
  ( cd "$T/workspace/repo"
    printf 'from kubecore.authoring import pipeline\n' > pipeline.py
    printf 'a: 1\n' > config/data.yaml
    printf 'FROM python:3.12\nARG KAOS_LIB_PACKAGE="kaos-lib==0.3.0"\n' > steps/a/Dockerfile
    printf 'FROM scratch\n' > steps/compose_and_validate/Dockerfile   # a leftover of an old app: not an app step any more
    if [ -n "${COMPAT:-}" ]; then mkdir .kaos && printf 'kaos-lib: "%s"\n' "$COMPAT" > .kaos/compat.yaml; fi
    git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm one \
      && printf 'x\n' > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm two )
  BUILT=$(git -C "$T/workspace/repo" rev-parse HEAD)
  python3 - "$T/fixture/kubeapps/${APP}/main" "$BUILT" "$1" "${2:--}" "${ENGINE_IN_CTX:-yes}" "${CTX_SPEC:-kaos-lib==0.5.0}" <<'PY'
import sys, yaml
d, built, compose, kl, eng, ctx_spec = sys.argv[1:7]
data = {"last-built-sha": built, "a": "reg/app:a-dev-v1-x-1", "compose-and-validate": "reg/app:compose-and-validate-dev-v1-x-1"}
if compose != "-":
    data["engine-compose"] = compose
if kl != "-":
    data["kaos-lib-package"] = kl
yaml.safe_dump({"kind": "ConfigMap", "metadata": {"name": "app1-pipeline-images"}, "data": data}, open(d + "/pipeline-images.yaml", "w"))
ctx = {"project": "proj", "app": "app1", "kaosLib": {"spec": ctx_spec, "version": ctx_spec.rsplit("==", 1)[-1]}}
if eng == "yes":
    ctx["engine"] = {"version": "v0.4.7", "image": "reg.example/kaos-pipeline-engine:v0.4.7",
                     "wheel": "https://example.com/engine.whl", "wheelSha256": "a" * 64, "mode": "legacy"}
yaml.safe_dump({"kind": "ConfigMap", "metadata": {"name": "app1-pipeline-context"}, "data": {"context.yaml": yaml.safe_dump(ctx)}},
               open(d + "/pipeline-context.yaml", "w"))
PY
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ]; then dst="\${@: -1}"; mkdir -p "\$dst"; cp -r "$T/fixture/." "\$dst/"; exit 0; fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$T/bin/git"
}
run_detect() {
  sed -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" \
      -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" \
      -e "s#{{workflow.parameters.event_type}}#${EVENT:-push}#g" \
      -e "s#{{workflow.parameters.kaos_lib_rebuild}}#false#g" \
      -e "s#/tmp/#${T}/#g" -e "s#/workspace#${T}/workspace#g" -e "s#/etc/github-token/token#${T}/token#g" \
      "$DETECT_SRC" > "$T/detect.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" bash "$T/detect.sh" 2>&1); RC=$?
  CHANGED=$(cat "$T/changed_steps.json" 2>/dev/null); COMPOSE_REC=$(cat "$T/engine_compose" 2>/dev/null)
}
COMPOSE='{"name":"compose-and-validate","path":"config"}'

detect_case "$ENG" "$SPEC"; run_detect
expect_eq "$RC/$CHANGED" "0/[]" "detect-steps: everything on the context's engine and kaos-lib: nothing rebuilds"
expect_eq "$(cat "$T/engine_version") $(cat "$T/engine_image") $(cat "$T/engine_profile")" "$ENG $ENGINE_IMAGE hera" \
  "detect-steps: the engine of the build is the context's (a mode key in it is ignored); profile hera without a quantization config"
expect_eq "$(jq -r .wheel_sha256 "$T/engine.json")" "$(printf 'a%.0s' $(seq 64))" "detect-steps: the engine JSON carries the wheel pin to the enhance step"
expect_eq "$COMPOSE_REC" "" "detect-steps: no compose build, no engine-compose to record"

detect_case "$ENG" "$SPEC"; : > "$T/workspace/repo/config/quantization.yaml"; run_detect
expect_eq "$(cat "$T/engine_profile")" "yolo" "detect-steps: config/quantization.yaml selects the yolo profile"
detect_case "$ENG" "$SPEC"; mkdir "$T/workspace/repo/config/quantization"; run_detect
expect_eq "$(cat "$T/engine_profile")" "yolo" "detect-steps: config/quantization/ selects the yolo profile"

detect_case "$ENG" "$SPEC"
( cd "$T/workspace/repo" && printf 'b: 2\n' > config/model.yaml && git add -A && git -c user.email=t@t -c user.name=t commit -qm cfg )
sed -i "s#^  last-built-sha: .*#  last-built-sha: $(git -C "$T/workspace/repo" rev-parse HEAD~1)#" "$T/fixture/kubeapps/${APP}/main/pipeline-images.yaml"
run_detect
expect_eq "$CHANGED" "[$COMPOSE]" "detect-steps: config/ changed: only the compose image rebuilds"
expect_has "$OUT" "config/ changed" "detect-steps: says why"
expect_eq "$COMPOSE_REC" "$ENG" "detect-steps: the built compose image will be recorded as engine-compose"

detect_case "$OLD_ENG" "$SPEC"; EVENT=reconcile run_detect
expect_eq "$RC/$CHANGED" "0/[$COMPOSE]" "detect-steps: the engine moved (reconcile of a built HEAD): the compose image is the ONLY image that rebuilds"
expect_has "$OUT" "engine ${OLD_ENG} -> ${ENG}" "detect-steps: says why"
expect_eq "$(cat "$T/wft_changed")" "true" "detect-steps: ... and the render runs (a reconcile always renders)"
detect_case "-" "$SPEC"; EVENT=reconcile run_detect
expect_eq "$CHANGED" "[$COMPOSE]" "detect-steps: no engine-compose recorded yet: the compose image rebuilds"

detect_case "$ENG" "kaos-lib==0.3.0"; run_detect
expect_eq "$CHANGED" '[{"name":"a","path":"steps/a"},'"$COMPOSE"']' "detect-steps: the kaos-lib package moved: the compose image rebuilds with the steps that declare the ARG"
expect_has "$OUT" "kaos-lib package moved" "detect-steps: says why"

detect_case "$ENG" "$SPEC"; sed -i 's#compose-and-validate: .*#compose-and-validate: reg/app:compose-and-validate-latest#' "$T/fixture/kubeapps/${APP}/main/pipeline-images.yaml"; run_detect
expect_eq "$CHANGED" "[$COMPOSE]" "detect-steps: a compose image that was never built (placeholder) builds"

ENGINE_IN_CTX=no detect_case "$ENG" "$SPEC"; run_detect
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "detect-steps: a context with no engine fails the build"
expect_has "$OUT" "engine: FATAL" "detect-steps: ... loudly"
expect_not "$CHANGED" "a" "detect-steps: ... and decides nothing"

detect_case "$ENG" "$SPEC"; rm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml"; run_detect
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "detect-steps: no pipeline-context in gitops fails the build"

detect_case "$ENG" "$SPEC"; run_detect
expect_not "$(cat "$T/step_pairs")" "compose" "detect-steps: an app's own steps/compose_and_validate is not an app step (the compose image is the chart's)"

# ── detect-steps: a kaos-lib older than the step contract (PRD novelcore/kaos#1911 AC-01) ──

OLD_SPEC="kaos-lib==0.4.3"
CTX_SPEC="$OLD_SPEC" COMPAT=">=0.4,<0.5" detect_case "$ENG" "$OLD_SPEC"; run_detect
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "detect-steps (kaos-lib 0.4, range <0.5): the build is refused"
expect_eq "$(ls "$T/changed_steps.json" "$T/engine.json" 2>/dev/null)" "" "detect-steps (kaos-lib 0.4): ... before it decides what to build or which engine renders"
NM=$(cat "$T/workspace/old-app" 2>/dev/null)
expect_eq "$NM" "It is built with kaos-lib 0.4.3; the current pipelines need kaos-lib 0.5 or newer." "detect-steps (kaos-lib 0.4): says what is wrong"
expect_has "$OUT" "kaos-ci: OLD APP: It is built with kaos-lib 0.4.3; the current pipelines need kaos-lib 0.5 or newer. $OLD_APP_SENTENCE" "detect-steps (kaos-lib 0.4): one line of the step log, the same old-app sentence"
expect_has "$(cat "$T/workspace/report-extra.md" 2>/dev/null)" "#### What to change" "detect-steps (kaos-lib 0.4): the report comment gets its section"
CTX_SPEC="$OLD_SPEC" detect_case "$ENG" "$OLD_SPEC"; run_detect
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "detect-steps (kaos-lib 0.4, no range declared): refused too"
CTX_SPEC="$OLD_SPEC" COMPAT=">=0.5,<0.6" detect_case "$ENG" "$OLD_SPEC"; run_detect
expect_eq "$RC" "0" "detect-steps (kaos-lib 0.4 still delivered, the commit accepts 0.5): the build goes on: it is how the platform learns the new range"
expect_eq "$(ls "$T/workspace/old-app" 2>/dev/null)" "" "detect-steps: ... and nothing is reported as an old app"
expect_eq "$(cat "$T/kaos_lib_compat")" ">=0.5,<0.6" "detect-steps: ... the range it will report is the commit's"
COMPAT=">=0.4,<0.5" detect_case "$ENG" "$SPEC"; run_detect
expect_eq "$RC/$CHANGED" "0/[]" "detect-steps (kaos-lib 0.5 delivered): the app's range is not what this check reads"

# Images from before the step contract are not "stale, rebuilt on use": a reconcile-submitted build
# rebuilds them (after the render, which an app that has not moved fails first).
detect_case "$ENG" "$OLD_SPEC"; EVENT=reconcile run_detect
expect_eq "$RC/$CHANGED" '0/[{"name":"a","path":"steps/a"},'"$COMPOSE"']' "detect-steps (reconcile, images on kaos-lib 0.4, 0.5 delivered): every image that installs kaos-lib rebuilds"
expect_not "$OUT" "kaos-lib STALE" "detect-steps: ... they are not left stale"
expect_eq "$(cat "$T/kaos_lib_package")" "$SPEC" "detect-steps: ... and are built with the kaos-lib the platform delivers"
detect_case "$ENG" "kaos-lib==0.5.1"; EVENT=reconcile run_detect
expect_eq "$CHANGED" "[]" "detect-steps (reconcile, images on another 0.5): stale, rebuilt on use, as before"
expect_has "$OUT" "kaos-lib STALE" "detect-steps: ... and says so"

# ── the compose Dockerfile ───────────────────────────────────────────────────

DF="${CHART}/files/compose.Dockerfile"
code() { grep -v '^[[:space:]]*#' "$DF"; }
expect_eq "$(code | grep -c '^FROM ')" "1" "compose Dockerfile: one stage"
expect_has "$(code)" 'ARG ENGINE_IMAGE
FROM ${ENGINE_IMAGE}' "compose Dockerfile: FROM the engine image of the build"
expect_has "$(code)" 'ARG KAOS_LIB_PACKAGE' "compose Dockerfile: takes the same KAOS_LIB_PACKAGE build-arg as the step images"
expect_has "$(code)" 'pip install --no-cache-dir --no-deps -c /etc/kaos-engine/constraints.txt "${KAOS_LIB_PACKAGE}"' "compose Dockerfile: only kaos-lib is added, under the engine's own pinned set"
expect_has "$(code)" 'test -f /etc/kaos-engine/constraints.txt' "compose Dockerfile: an engine image without its pinned set fails the build"
expect_has "$(code)" 'import kaos_lib.datasets, kaos_lib.lock, kaos_lib.lakefs, kaos_lib.zitadel, jwt, cryptography' "compose Dockerfile: the build proves kaos-lib imports with what the engine image carries"
expect_has "$(code)" 'ENV KUBECORE_SCHEMA_PROFILE=${ENGINE_PROFILE} KUBECORE_CONFIG_DIR=/work/config' "compose Dockerfile: the profile and the config dir"
expect_has "$(code)" 'COPY . /work/config/' "compose Dockerfile: the build context (the app's config/) is the config tree"
expect_has "$(code)" 'LABEL io.kaos.engine=${ENGINE_VERSION}' "compose Dockerfile: labelled with the engine version"
expect_eq "$(code | grep -c '^COPY ')" "1" "compose Dockerfile: copies nothing else from the app"
expect_eq "$(code | grep -ciE 'ENTRYPOINT|CMD')" "0" "compose Dockerfile: sets no command (the rendered WorkflowTemplate carries it)"
expect_eq "$(code | tail -1)" "USER 65532:65532" "compose Dockerfile: back to the engine image's non-root user after the install"

BUILD_SRC="${BASE_TMP}/build.src"; script ml-ci-build build-push > "$BUILD_SRC"
run_build() {  # run_build STEP_NAME STEP_PATH
  T=$(mktemp -d "${BASE_TMP}/build-XXXXXX"); mkdir -p "$T/workspace/repo/config" "$T/workspace/repo/steps/a"
  printf 'FROM x\nARG KAOS_LIB_PACKAGE\n' > "$T/workspace/repo/steps/a/Dockerfile"
  printf 'PWNED\n' > "$T/workspace/repo/Dockerfile"   # the app's root Dockerfile is never used
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s/args\n' "$T" > "$T/executor"; chmod +x "$T/executor"
  sed -e "s#/kaniko/executor#${T}/executor#g" -e "s#/workspace#${T}/workspace#g" \
      -e "s#{{inputs.parameters.step_name}}#$1#g" -e "s#{{inputs.parameters.step_path}}#$2#g" \
      -e "s#{{inputs.parameters.image_tag}}#dev-v1#g" -e "s#{{workflow.parameters.[a-z_]*}}#x#g" \
      "$BUILD_SRC" > "$T/build.sh"
  OUT=$(KAOS_LIB_PACKAGE="$SPEC" ENGINE_IMAGE="$ENGINE_IMAGE" ENGINE_VERSION="$ENG" ENGINE_PROFILE=yolo sh "$T/build.sh" 2>&1); RC=$?
  ARGS=$(cat "$T/args" 2>/dev/null)
}
run_build compose-and-validate config
expect_eq "$RC" 0 "build-push (compose): runs"
expect_has "$ARGS" "--context=$T/workspace/repo/config" "build-push (compose): the app's config/ folder is the only context"
expect_has "$ARGS" "--dockerfile=$T/workspace/compose.Dockerfile" "build-push (compose): the Dockerfile is the chart's, outside the app checkout"
expect_eq "$(cat "$T/workspace/compose.Dockerfile")" "$(cat "$DF")" "build-push (compose): the chart's Dockerfile, byte for byte"
expect_has "$ARGS" "--build-arg=ENGINE_IMAGE=${ENGINE_IMAGE}" "build-push (compose): the engine image is the base"
expect_has "$ARGS" "--build-arg=ENGINE_VERSION=${ENG}" "build-push (compose): the engine version labels the image"
expect_has "$ARGS" "--build-arg=ENGINE_PROFILE=yolo" "build-push (compose): the profile is baked in"
expect_has "$ARGS" "--build-arg=KAOS_LIB_PACKAGE=${SPEC}" "build-push (compose): the same kaos-lib build-arg as the steps"
expect_has "$ARGS" "compose-and-validate-dev-v1" "build-push (compose): pushed under the step name the WFT's image-compose-and-validate key reads"
run_build a steps/a
expect_has "$ARGS" "--dockerfile=$T/workspace/repo/steps/a/Dockerfile" "build-push (step): an app step still builds from its own Dockerfile"
expect_not "$ARGS" "ENGINE_IMAGE" "build-push (step): ... without engine build-args"

# ── engine-record: engine-last-error / engine-attempt written and cleared ────

REC_SRC="${BASE_TMP}/record.src"; script ml-ci-build engine-record > "$REC_SRC"
# record_case PHASE: a gitops origin with pipeline-images and context; pods are added with pod().
record_case() {
  T=$(mktemp -d "${BASE_TMP}/rec-XXXXXX"); mkdir -p "$T/bin" "$T/seed/kubeapps/${APP}/main" "$T/logs"
  printf 'token' > "$T/token"; PHASE="$1"; PODS='[]'
  python3 - "$T/seed/kubeapps/${APP}/main" "${2:-}" <<'PY'
import sys, yaml
d, extra = sys.argv[1], sys.argv[2]
data = {"last-built-sha": "x", "a": "reg/app:a-1", "engine-version": "v0.4.7"}
if extra == "stale-error":
    data["engine-last-error"] = "render: boom"
    data["engine-attempt"] = "v0.4.7@1"
yaml.safe_dump({"kind": "ConfigMap", "metadata": {"name": "app1-pipeline-images"}, "data": data}, open(d + "/pipeline-images.yaml", "w"))
ctx = {"engine": {"version": "v0.4.7", "image": "reg.example/kaos-pipeline-engine:v0.4.7", "wheel": "https://x/e.whl", "wheelSha256": "a" * 64},
       "kaosLib": {"spec": "kaos-lib==0.5.0"}}
yaml.safe_dump({"kind": "ConfigMap", "data": {"context.yaml": yaml.safe_dump(ctx)}}, open(d + "/pipeline-context.yaml", "w"))
PY
  git init -q --bare -b main "$T/origin.git"
  ( cd "$T/seed" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed && git push -q "$T/origin.git" main )
}
# pod NODE_NAME EXIT_CODE [LOG TEXT]
pod() {
  local n=${#PODS}; local name="pod-$RANDOM$RANDOM"
  PODS=$(printf '%s' "$PODS" | jq --arg nn "$1" --arg name "$name" --arg code "$2" --arg t "$(printf '%02d' $(( $(printf '%s' "$PODS" | jq length) + 10 )))" '
    . + [{metadata: {name: $name, annotations: {"workflows.argoproj.io/node-name": $nn}},
          status: {startTime: ("2026-11-10T12:00:" + $t + "Z"), containerStatuses: [{name: "main", state: {terminated: {exitCode: ($code | tonumber)}}}]}}]')
  printf '%b' "${3:-}" > "$T/logs/$name"
}
run_record() {
  printf '%s' "$PODS" | jq '{items: .}' > "$T/pods-fixture.json"
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get pods"*) cat "$T/pods-fixture.json" ;;
  *"logs "*) n=\$(printf '%s' "\$*" | sed 's/.*logs -n [^ ]* \\([^ ]*\\) .*/\\1/'); cat "$T/logs/\$n" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ]; then set -- "\${@:1:\$((\$#-2))}" "$T/origin.git" "\${@: -1}"; fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$T/bin/kubectl" "$T/bin/git"
  # GitHub: every call is logged with its payload and answered ${GH_ANSWER:-201}.
  cat > "$T/bin/curl" <<CURLEOF
#!/usr/bin/env bash
out=""; data=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in -o) out="\$2"; shift ;; -d) data="\$2"; shift ;; -D|-w|-X|-H|--connect-timeout|--max-time) shift ;; -*) ;; *) url="\$1" ;; esac
  shift
done
printf '%s %s\n' "\$url" "\$data" >> "$T/github-calls"
[ -n "\$out" ] && printf '{}' > "\$out"
printf '%s' "${GH_ANSWER:-201}"
CURLEOF
  chmod +x "$T/bin/curl"
  sed -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" -e "s#{{workflow.name}}#wf#g" -e "s#{{workflow.namespace}}#ci#g" \
      -e "s#{{workflow.parameters.commit_sha}}#${COMMIT}#g" -e "s#{{workflow.parameters.repo_url}}#https://github.com/org/proj-app1.git#g" \
      -e "s#{{workflow.uid}}#uid1#g" -e "s#^\( *\)ARGO_BASE=\"\"#\1ARGO_BASE=\"${ARGO_BASE_TEST:-}\"#" -e "s#{{workflow.status}}#${PHASE}#g" -e "s#/tmp/#${T}/#g" -e "s#/workspace#${T}/workspace#g" \
      -e "s#/etc/github-token/token#${T}/token#g" "$REC_SRC" > "$T/record.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" HOME="$T" bash "$T/record.sh" 2>&1); RC=$?
  [ -n "${SHOW:-}" ] && echo "$OUT"
  CALLS=$(cat "$T/github-calls" 2>/dev/null)
  rm -rf "$T/check"; git clone -q "$T/origin.git" "$T/check" 2>/dev/null
  IMG="$T/check/kubeapps/${APP}/main/pipeline-images.yaml"
  ERR=$(yq '.data."engine-last-error" // "<absent>"' "$IMG"); ATT=$(yq '.data."engine-attempt" // "<absent>"' "$IMG")
}
# The node names Argo gives these pods: every engine step retries a lost pod (preemptionRetry), so each
# attempt is a `(N)` child of a Retry node (kubecore-operator issue 1832: the record matched none of them).
# The nesting: ml-ci-build [1] probe-detect, [2] build-run (ml-ci-run-locked) > [0] run (ml-ci-run) >
# [1] detect-steps, [3] render-hera > [0] hera-render, [1] hera-enhance-commit, and [3] build-push per item.
COMMIT=$(printf 'c%.0s' $(seq 40))
PROBE_NODE='wf[1].probe-detect(0)'
RUN='wf[2].build-run[0].run'
DETECT_NODE="${RUN}[1].detect-steps(0)"
RENDER_NODE="${RUN}[3].render-hera[0].hera-render(0)"
RENDER_RETRY="${RUN}[3].render-hera[0].hera-render(1)"
ENHANCE_NODE="${RUN}[3].render-hera[1].hera-enhance-commit(0)"
COMPOSE_NODE="${RUN}[3].build-push(0:name:compose-and-validate,path:config)(0)"

record_case Failed; pod "$DETECT_NODE" 0; pod "$RENDER_NODE" 1 'time=x argo=true\nINFO rendering\n\033[31mpipeline.py raised: ValueError: step x reads a missing key\033[0m\nexit status 1\nError: exit status 1\n'; run_record
expect_eq "$RC" 0 "engine-record (render failed): runs"
expect_eq "$ERR" "render: pipeline.py raised: ValueError: step x reads a missing key" "engine-record: the last error line of the failed render, one line, no colour codes, not Argo's closing 'Error: exit status 1'"
expect_has "$ATT" "v0.4.7@" "engine-record: the attempt is recorded as <engine version>@<epoch>"
expect_eq "$(( $(date +%s) - ${ATT##*@} < 120 ))" "1" "engine-record: ... with the time of this attempt"
expect_has "$(git -C "$T/check" log -1 --format=%s)" "record the engine error" "engine-record: committed to gitops"

expect_eq "$CALLS" "" "engine-record: a render that failed for another reason posts no status of its own"

# kubecore-operator issue 1864: a refused when= (engine 0.1.0-dev.094d290) on stage was recorded as "render: Error: exit
# status 1", Argo's executor line. The record is the traceback's last line, without the module path.
WHEN_ERR="step 'qat-finetune': when= is written with the name of a run-form field, for example when=\"mode != off\". Write the field's name instead of {{workflow.parameters.<field>}}."
record_case Failed; pod "$DETECT_NODE" 0
pod "$RENDER_NODE" 1 "hera-render: rendering pipeline.py with the platform engine x (profile yolo)\nkaos-engine: version=0.1.0 profile=yolo\nTraceback (most recent call last):\n  File \"pipeline.py\", line 35, in <module>\n    raise AuthoringError(\nkubecore.authoring.AuthoringError: ${WHEN_ERR}\ntime=\"2026-11-12T21:58:00Z\" level=info msg=\"sub-process exited\" argo=true error=\"exit status 1\"\nError: exit status 1\n"
run_record
expect_eq "$ERR" "$(printf 'render: AuthoringError: %s' "$WHEN_ERR" | cut -c1-200)" "engine-record (issue 1864): the engine's error, not the executor's 'Error: exit status 1'"
record_case Failed; pod "$DETECT_NODE" 0; pod "$RENDER_NODE" 1 "doing things\nsomething went sideways\nError: exit status 2\n"; run_record
expect_eq "$ERR" "render: something went sideways" "engine-record: with no error line, the step's own last line, never the executor's"
record_case Failed; pod "$DETECT_NODE" 0; pod "$RENDER_NODE" 1 "Traceback (most recent call last):\nurllib3.exceptions.ReadTimeoutError: read timed out (retried)\nkaos-engine: pipeline.py changed the engine module kubecore.authoring\nError: exit status 1\n"; run_record
expect_eq "$ERR" "render: kaos-engine: pipeline.py changed the engine module kubecore.authoring" "engine-record: a handled traceback earlier in the log does not hide the later error"
record_case Failed; pod "$DETECT_NODE" 0; pod "$COMPOSE_NODE" 1 "INFO[0010] RUN python -m kubecore.compose\nTraceback (most recent call last):\nkubecore.compose.ComposeError: config group model has no default\nerror building image: error building stage: failed to execute command: waiting for process to exit: exit status 1\nError: exit status 1\n"; run_record
expect_eq "$ERR" "compose image build: ComposeError: config group model has no default" "engine-record: the compose build's own error, not kaniko's closing line"

# PRD novelcore/kaos#1911 AC-01: the run was refused because the app was made before the current pipelines.
WHAT="step 'hello-world' has no kind=. Every step declares what it does: kind= is one of ingest, transform, train, evaluate, publish, control."
refused_case() {  # refused_case NODE [SEED]: a failed run whose NODE left /workspace/old-app
  record_case Failed "${2:-}"; mkdir -p "$T/workspace"; printf '%s\n' "$WHAT" > "$T/workspace/old-app"
  pod "wf.detect-steps" 0; pod "$1" 1 "Traceback\nkubecore.authoring.AuthoringError: step 'hello-world' has no kind=\nkaos-ci: OLD APP: ${WHAT} ${OLD_APP_SENTENCE}\n"
}
refused_case "$RENDER_NODE"; run_record
expect_eq "$RC" 0 "engine-record (old app): runs"
expect_eq "$ERR" "$(printf '%s %s' "$STATUS_TEXT" "$WHAT" | cut -c1-200)" "engine-record (old app): engine-last-error is the old-app sentence and the reason, at most 200 characters"
KEY=$(printf 'kaos-lib==0.5.0' | sha256sum | cut -c1-12)
expect_eq "$(printf '%s' "$ATT" | cut -d@ -f1,3,4)" "v0.4.7@${COMMIT}@${KEY}" "engine-record (old app): engine-attempt names the engine, the refused commit and the kaos-lib delivered"
expect_eq "$(( $(date +%s) - $(printf '%s' "$ATT" | cut -d@ -f2) < 120 ))" "1" "engine-record (old app): ... and when"
expect_eq "$(yq '.data | keys | sort | join(",")' "$IMG")" "a,engine-attempt,engine-last-error,engine-version,last-built-sha" "engine-record (old app): no other key is written"
expect_eq "$(yq '.data."last-built-sha" + "/" + .data."engine-version" + "/" + .data.a' "$IMG")" "x/v0.4.7/reg/app:a-1" "engine-record (old app): the built commit, the engine of the last render and the images stay as they were"
expect_eq "$(printf '%s\n' "$CALLS" | grep -c .)" "1" "engine-record (old app): one GitHub call"
expect_has "$CALLS" "https://api.github.com/repos/org/proj-app1/statuses/${COMMIT} " "engine-record (old app): a commit status on the built commit"
STATUS=$(printf '%s' "$CALLS" | cut -d' ' -f2-)
expect_eq "$(printf '%s' "$STATUS" | jq -r '.state + "/" + .context')" "failure/kubecore-ml-ci" "engine-record (old app): the build's own check, failed"
expect_eq "$(printf '%s' "$STATUS" | jq -r '.description')" "$STATUS_TEXT" "engine-record (old app): the description says the app is old and to create it again (the reason does not fit 140 characters)"
expect_eq "$(( $(printf '%s' "$STATUS" | jq -r '.description' | wc -c) <= 140 ))" "1" "engine-record (old app): ... within GitHub's 140 characters"
expect_eq "$(printf '%s' "$STATUS" | jq -r 'has("target_url")')" "false" "engine-record (old app): no run report address is configured, so the check links none"
expect_not "$STATUS" "migrate" "engine-record (old app): no guide is linked"
for WORD in Argo argo workflow Workflow namespace cluster kubectl ConfigMap gitops; do
  expect_not "$STATUS $ERR" "$WORD" "engine-record (old app): status and record do not name the platform's internals ($WORD)"
done

refused_case "wf.detect-steps"; run_record
expect_has "$ERR" "$STATUS_TEXT" "engine-record (old app at detect-steps, a kaos-lib older than 0.5): recorded the same way"
expect_eq "$(printf '%s' "$ATT" | cut -d@ -f3)" "$COMMIT" "engine-record: ... with the refused commit"

refused_case "$RENDER_NODE"; GH_ANSWER=403 run_record
expect_eq "$RC" 0 "engine-record (old app): a status GitHub refuses does not stop the record"
expect_has "$ERR" "$STATUS_TEXT" "engine-record: ... which is still written"

WHAT_SHORT="step 'x' has no kind=."
record_case Failed; mkdir -p "$T/workspace"; printf '%s\n' "$WHAT_SHORT" > "$T/workspace/old-app"; pod "$RENDER_NODE" 1 "boom\n"; ARGO_BASE_TEST=https://argo.example run_record
STATUS=$(printf '%s' "$CALLS" | cut -d' ' -f2-)
expect_eq "$(printf '%s' "$STATUS" | jq -r '.description')" "$STATUS_TEXT $WHAT_SHORT" "engine-record (old app): a reason that fits GitHub's 140 characters follows the sentence"
expect_eq "$(printf '%s' "$STATUS" | jq -r '.target_url')" "https://argo.example/workflows/ci/wf?uid=uid1" "engine-record (old app): the check links the run report, as the failure status does"
record_case Failed; mkdir -p "$T/workspace"; printf '\n' > "$T/workspace/old-app"; pod "$RENDER_NODE" 1 "boom\n"; run_record
STATUS=$(printf '%s' "$CALLS" | cut -d' ' -f2-)
expect_eq "$(printf '%s' "$STATUS" | jq -r '.description')/$ERR" "$STATUS_TEXT/$STATUS_TEXT" "engine-record (old app): a refusal with no reason is the sentence alone, with no trailing space"
expect_eq "$(printf '%s' "$ATT" | cut -d@ -f3)" "$COMMIT" "engine-record (old app): ... and is still the one attempt"

record_case Succeeded stale-error; mkdir -p "$T/workspace"; printf 'leftover\n' > "$T/workspace/old-app"; pod "$RENDER_NODE" 0; pod "$ENHANCE_NODE" 0; run_record
expect_eq "$ERR/$ATT/$CALLS" "<absent>/<absent>/" "engine-record: a run that succeeded is never reported as old app, whatever the workspace holds"

record_case Failed; pod "$RENDER_NODE" 0; pod "$ENHANCE_NODE" 4 "engine: FATAL: engine wheel sha256 mismatch: the context pins aaa, https://x/e.whl is bbb\n"; run_record
expect_has "$ERR" "enhance: engine: FATAL: engine wheel sha256 mismatch" "engine-record: a wheel that does not verify is the enhance error"

record_case Failed; pod "$COMPOSE_NODE" 1 "error building image: kaniko failed\n"; run_record
expect_has "$ERR" "compose image build: error building image" "engine-record: a failed compose image build is recorded"

record_case Failed; pod "$DETECT_NODE" 1 "engine: FATAL: the pipeline context has no usable engine; failing the build\n"; run_record
expect_has "$ERR" "engine check: engine: FATAL" "engine-record: a context with no usable engine is recorded"

record_case Failed; pod "$RENDER_NODE" 1 "$(printf 'x%.0s' $(seq 400))\n"; run_record
expect_eq "$(printf '%s' "$ERR" | wc -c | tr -d ' ')" "200" "engine-record: the error is bounded to 200 characters"

record_case Failed; pod "${RUN}[3].build-push(1:name:a,path:steps/a)(0)" 1 "error: a client step image failed\n"; run_record
expect_eq "$ERR" "<absent>" "engine-record: a failed client step image is not an engine error"

record_case Failed stale-error; pod "$DETECT_NODE" 1 "something else broke\n"; run_record
expect_eq "$ERR" "render: boom" "engine-record: a run that failed outside the engine leaves the record as it was"

record_case Succeeded stale-error; pod "$RENDER_NODE" 0; pod "$ENHANCE_NODE" 0; run_record
expect_eq "$ERR/$ATT" "<absent>/<absent>" "engine-record: a run that rendered and enhanced clears engine-last-error and engine-attempt"
expect_has "$(git -C "$T/check" log -1 --format=%s)" "clear the engine error" "engine-record: the clearing is committed to gitops"

record_case Succeeded stale-error; pod "$COMPOSE_NODE" 0; run_record
expect_eq "$ERR/$ATT" "<absent>/<absent>" "engine-record: a run that built the compose image clears them too"

record_case Succeeded stale-error; pod "$DETECT_NODE" 0; run_record
expect_eq "$ERR" "render: boom" "engine-record: a run that ran no engine stage leaves the record as it was"

record_case Succeeded stale-error; pod "$RENDER_NODE" 1 "transient\n"; pod "$RENDER_RETRY" 0; pod "$ENHANCE_NODE" 0; run_record
expect_eq "$ERR" "<absent>" "engine-record: a pod that failed and was retried to success is not an error of the run"

# retried engine pods (kubecore-operator issue 1832)
record_case Failed; pod "$PROBE_NODE" 1 "engine: FATAL: the pipeline context has no usable engine; failing the build\n"; run_record
expect_has "$ERR" "engine check: engine: FATAL" "engine-record: the probe's engine check (probe-detect) that failed is recorded"
expect_has "$ATT" "v0.4.7@" "engine-record: ... with engine-attempt, so the reconcile's hourly guard engages"

record_case Succeeded stale-error; pod "$PROBE_NODE" 0; pod "$DETECT_NODE" 0; run_record
expect_eq "$ERR" "render: boom" "engine-record: a passed engine check alone is not a render: the record stays"

record_case Succeeded stale-error; pod "$COMPOSE_NODE" 1 "error: lost\n"; pod "${COMPOSE_NODE%(0)}(1)" 0; run_record
expect_eq "$ERR/$ATT" "<absent>/<absent>" "engine-record: a compose build retried to success clears the record"

record_case Failed; pod "$DETECT_NODE" 0; pod "$RENDER_NODE" 1 "pipeline.py raised: KeyError: 'output_prefix'\n"; run_record
expect_eq "$ERR" "render: pipeline.py raised: KeyError: 'output_prefix'" "engine-record (retry-named pods): a failed render(0) records engine-last-error with stage render"
expect_has "$ATT" "v0.4.7@" "engine-record (retry-named pods): ... and engine-attempt, which the reconcile guard reads"
expect_has "$OUT" "engine-record: render:" "engine-record (retry-named pods): ... and never says the run failed outside the engine"

record_case Succeeded stale-error; pod "$DETECT_NODE" 0; pod "$RENDER_NODE" 137 "imminent node shutdown\n"; pod "$RENDER_RETRY" 0; pod "$ENHANCE_NODE" 0; run_record
expect_eq "$ERR/$ATT" "<absent>/<absent>" "engine-record: render(0) preempted, render(1) succeeded: no error, the stale one cleared"

record_case Failed stale-error; pod "$RENDER_NODE" 137 "imminent node shutdown\n"; pod "$RENDER_RETRY" 0; pod "$ENHANCE_NODE" 0; pod "$COMPOSE_NODE" 1 "error building image: kaniko failed\n"; run_record
expect_has "$ERR" "compose image build: error building image" "engine-record: a preempted attempt retried to success is not the error; the stage that failed last is"

record_case Failed; pod "$RENDER_NODE" 137 "imminent node shutdown\n"; pod "$RENDER_RETRY" 1 "pipeline.py raised: ValueError: bad step\n"; run_record
expect_eq "$ERR" "render: pipeline.py raised: ValueError: bad step" "engine-record: the error of a retried render is its LAST attempt's"

record_case Failed stale-error; pod "$DETECT_NODE" 0; pod "$RENDER_NODE" 0; pod "$ENHANCE_NODE" 0; pod "${RUN}[3].build-push(1:name:a,path:steps/a)(0)" 1 "error: a client step image failed\n"; run_record
expect_eq "$ERR" "render: boom" "engine-record: a run that rendered but failed in a client step leaves the record as it was"

record_case Succeeded; pod "$RENDER_NODE" 0; pod "$ENHANCE_NODE" 0; run_record
before=$(git -C "$T/origin.git" rev-parse main)
expect_has "$OUT" "already recorded" "engine-record: nothing to clear, nothing committed"
expect_eq "$(git -C "$T/origin.git" rev-parse main)" "$before" "engine-record: ... no empty commit"

# the exit handler runs it next to the failure status, and a failing record never fails the run
expect_eq "$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "exit-handler") | .steps[][] | select(.name == "engine-record") | .continueOn.failed' "$RENDERED")" \
  "true" "exit-handler: engine-record is reporting only (continueOn failed)"
expect_eq "$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "exit-handler") | .steps | map(map(.name) | join("+")) | join(" > ")' "$RENDERED")" \
  "post-failure-status > engine-record > run-report" "exit-handler: engine-record runs after the failure status (its old-app status is the last one) and before the report"

# ── patch-images: the datasets the pipeline produces are recorded with every build ──────────────────────────

PATCH_SRC="${BASE_TMP}/patch.src"; script ml-ci-build patch-images > "$PATCH_SRC"
# run_patch TABLE_JSON|none: a gitops origin holding the committed WorkflowTemplate (its compose step carries
# TABLE_JSON as the step table; "none": a render of an engine from before the step contract) and the app's
# pipeline-images with a stale produced-datasets and an unrelated image key.
run_patch() {
  T=$(mktemp -d "${BASE_TMP}/patch-XXXXXX"); mkdir -p "$T/bin" "$T/seed/kubeapps/${APP}/main"
  printf 'token' > "$T/token"
  printf 'kind: ConfigMap\nmetadata: {name: app1-pipeline-images}\ndata: {last-built-sha: old, produced-datasets: stale, a: "reg/app:a-1"}\n' \
    > "$T/seed/kubeapps/${APP}/main/pipeline-images.yaml"
  python3 - "$1" "$T/seed/kubeapps/${APP}/main/workflow-template.yaml" <<'PY'
import json, sys, yaml
args = ["a=1"] if sys.argv[1] == "none" else ["a=1", "--steps", sys.argv[1], "--run", "r"]
wft = {"kind": "WorkflowTemplate", "metadata": {"name": "app1-pipeline"},
       "spec": {"templates": [{"name": "main", "dag": {"tasks": []}},
                              {"name": "compose-and-validate", "container": {"image": "x", "args": args}}]}}
yaml.safe_dump(wft, open(sys.argv[2], "w"))
PY
  ( cd "$T/seed" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed )
  git clone -q --bare "$T/seed" "$T/origin.git"
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ]; then set -- "\${@:1:\$((\$#-2))}" "$T/origin.git" "\${@: -1}"; fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$T/bin/git"
  sed -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" -e "s#{{workflow.parameters.commit_sha}}#${COMMIT}#g" \
      -e "s#{{inputs.parameters.image_tag}}#dev-v2#g" -e "s#{{inputs.parameters.changed_steps}}#[]#g" \
      -e "s#{{workflow.parameters.[a-z_]*}}##g" -e "s#/tmp/#${T}/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" -e "s#/etc/registry-auth#${T}/none#g" "$PATCH_SRC" > "$T/patch.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" KL_RECORD="" KL_COMPAT="" ENGINE_COMPOSE="" HOME="$T" bash "$T/patch.sh" 2>&1); RC=$?
  rm -rf "$T/check"; git clone -q "$T/origin.git" "$T/check" 2>/dev/null
  IMG="$T/check/kubeapps/${APP}/main/pipeline-images.yaml"
  PRODUCED=$(yq '.data."produced-datasets" // "<absent>"' "$IMG")
}
step_table() {  # step_table NAME:TYPE...: one step per produced output
  local i=0 out="" sep=""
  for e in "$@"; do
    out="${out}${sep}{\"name\":\"s${i}\",\"kind\":\"transform\",\"reads\":[],\"inputs\":[],\"needs\":[],\"produces\":[{\"name\":\"${e%%:*}\",\"type\":\"${e##*:}\"}]}"
    sep=","; i=$((i + 1))
  done
  printf '[%s]' "$out"
}
run_patch "$(step_table features:dataset clean:dataset model:model)"
expect_eq "$RC" 0 "patch-images (two produced datasets): runs"
expect_eq "$PRODUCED" "clean,features" "patch-images (two produced datasets): produced-datasets is the short names, sorted, comma separated, no spaces"
expect_eq "$(yq '.data."last-built-sha"' "$IMG")/$(yq '.data.a' "$IMG")" "${COMMIT}/reg/app:a-1" "patch-images (two produced datasets): the other keys are as before"
run_patch "$(step_table model:model report:artifact)"
expect_eq "$RC/$PRODUCED" "0/" "patch-images (no produced dataset): the key is written, empty (a stale value is replaced)"
expect_eq "$(yq '.data | has("produced-datasets")' "$IMG")" "true" "patch-images (no produced dataset): ... never omitted"
run_patch "[]"
expect_eq "$RC/$PRODUCED" "0/" "patch-images (a pipeline with no steps): the key is written, empty"
# A refused build never gets here (hera-render fails first, tests/render-order); a committed render with no step
# table is not from an engine on the step contract, and nothing is written.
run_patch none
expect_eq "$([ "$RC" != 0 ] && echo failed)" "failed" "patch-images (a render with no step table): the step fails"
expect_eq "$PRODUCED/$(yq '.data."last-built-sha"' "$IMG")" "stale/old" "patch-images (a render with no step table): ... and nothing is written"
expect_has "$OUT" "engine: FATAL" "patch-images (a render with no step table): ... saying why"
KEYLINE='[ "${KEY}" = "produced-datasets" ] && continue'
expect_has "$(cat "$PATCH_SRC")" "$KEYLINE" "patch-images: the digest-pin loop skips produced-datasets (it is not an image)"
expect_has "$(script ml-ci-build hera-enhance-commit)" '"produced-datasets"' "hera-enhance-commit: the stale-key prune keeps produced-datasets"

echo "engine-ci: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
