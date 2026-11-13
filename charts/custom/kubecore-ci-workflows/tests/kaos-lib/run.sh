#!/usr/bin/env bash
# kaos-lib delivery in the rendered chart (PRD novelcore/kaos#1147). The scripts
# are EXECUTED with stubs, not grepped:
#   - ml-ci-build detect-steps: the spec a build installs, which steps it
#     rebuilds when the spec moved, what patch-images will report;
#   - ml-ci-build build-push: --build-arg KAOS_LIB_PACKAGE + label io.kaos.lib,
#     only for a Dockerfile that declares the ARG;
#   - ml-ci-build patch-images: records kaos-lib-package / kaos-lib-compat;
#   - ml-ci-reconcile check-drift: KAOS-LIB DRIFT (rebuild when the context's
#     kaosLib.spec is not what the images have; one attempt per spec per hour);
#   - kaos-lib-support: the kaos-lib/support commit status (the release
#     refusal lived in ml-ci-rc-build, removed as unreferenced in 0.12.124);
#   - the wiring: rc/pr-render borrow it, the bump job takes data as env.
# files/kaos-lib.py itself: test_kaos_lib.py (pytest). Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/kaos-lib/run.sh /tmp/rendered.yaml
#
# Needs yq v4, jq, git, python3 + PyYAML. Ages are computed from the wall clock: compare them as ranges, never as exact numbers
# (the validate image is python:3.11-bookworm, the product scripts run in alpine/k8s; both must pass). Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
FAILED=0
PASSED=0
APP=app1
SHA40=0136a205a82fbe4ed4a82037329e048f58e7e740
# A spec is the whole requirement (name, extras, @ url or ==version).
SPEC="kubecore[zitadel] @ https://github.com/novelcore/hera-pipeline-template/archive/${SHA40}.zip#subdirectory=packages/kubecore"
OLD="kaos-lib==0.2.0"
ENGINE_V=v0.4.7
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

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
src() {  # src WORKFLOW TEMPLATE [initContainer|container]
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")
      | .spec.templates[] | select(.name == \"$2\") | .container.args[0]" "$RENDERED"
}
BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# context_cm FILE SPEC [SUPPORT_JSON]: a gitops pipeline-context.yaml delivering SPEC.
context_cm() {
  python3 - "$@" <<'PY'
import json, sys, yaml
path, spec = sys.argv[1], sys.argv[2]
ctx = {"project": "proj", "app": "app1",
       "engine": {"version": "v0.4.7", "image": "reg.example/kaos-pipeline-engine:v0.4.7",
                  "wheel": "https://example.com/engine.whl", "wheelSha256": "a" * 64}}
if spec != "-":
    ctx["kaosLib"] = {"spec": spec, "version": sys.argv[4] if len(sys.argv) > 4 else "0.2.1"}
    if len(sys.argv) > 3 and sys.argv[3]:
        ctx["kaosLib"]["support"] = sys.argv[3]
yaml.safe_dump({"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "app1-pipeline-context"},
                "data": {"context.yaml": yaml.safe_dump(ctx)}}, open(path, "w"))
PY
}

# ── detect-steps ─────────────────────────────────────────────────────────────

DETECT_SRC="${BASE_TMP}/detect.src"; src ml-ci-build detect-steps > "$DETECT_SRC"

# detect_case RECORDED: an app repo with steps a (declares the ARG) and b (does
# not), already built; a gitops fixture with pipeline-images (RECORDED as
# kaos-lib-package, "-" = absent) and the pipeline-context in $T/ctx.yaml.
detect_case() {
  T=$(mktemp -d "${BASE_TMP}/detect-XXXXXX")
  mkdir -p "$T/bin" "$T/workspace/repo/steps/a" "$T/workspace/repo/steps/b" "$T/workspace/repo/.kaos" \
           "$T/fixture/kubeapps/${APP}/main"
  printf 'token' > "$T/token"
  printf 'hera' > "$T/workspace/frontend"
  ( cd "$T/workspace/repo"
    printf 'FROM python:3.11-slim\nARG KAOS_LIB_PACKAGE="kubecore==0.2.0"\nRUN pip install "${KAOS_LIB_PACKAGE}"\n' > steps/a/Dockerfile
    printf 'FROM python:3.11-slim\nRUN true\n' > steps/b/Dockerfile
    printf 'kaos-lib: ">=0.2,<0.3"\n' > .kaos/compat.yaml
    git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm one \
      && printf 'x\n' > README.md && git add -A && git -c user.email=t@t -c user.name=t commit -qm two )
  BUILT=$(git -C "$T/workspace/repo" rev-parse HEAD)
  python3 - "$T/fixture/kubeapps/${APP}/main/pipeline-images.yaml" "$BUILT" "$1" <<'PY'
import sys, yaml
data = {"last-built-sha": sys.argv[2], "a": "reg/app:a-dev-v1-x-1", "b": "reg/app:b-dev-v1-x-1",
        "compose-and-validate": "reg/app:compose-and-validate-dev-v1-x-1", "engine-compose": "v0.4.7"}
if sys.argv[3] != "-":
    data["kaos-lib-package"] = sys.argv[3]
yaml.safe_dump({"kind": "ConfigMap", "metadata": {"name": "app1-pipeline-images"}, "data": data}, open(sys.argv[1], "w"))
PY
  # git: a clone of the gitops repo copies the fixture; everything else is real git.
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
      -e "s#{{workflow.parameters.kaos_lib_rebuild}}#${KL_REBUILD:-false}#g" \
      -e "s#/tmp/#${T}/#g" \
      -e "s#/workspace#${T}/workspace#g" \
      -e "s#/etc/github-token/token#${T}/token#g" \
      "$DETECT_SRC" > "$T/detect.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" ${KL_SHELL:-bash} "$T/detect.sh" 2>&1); RC=$?
  KL_PKG=$(cat "$T/kaos_lib_package" 2>/dev/null); KL_REC=$(cat "$T/kaos_lib_record" 2>/dev/null)
  KL_COMPAT=$(cat "$T/kaos_lib_compat" 2>/dev/null); CHANGED=$(cat "$T/changed_steps.json" 2>/dev/null)
}

detect_case "$OLD"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; run_detect
expect_eq "$RC" 0 "detect-steps: runs"
expect_eq "$KL_PKG" "$SPEC" "detect-steps: builds with the spec the context delivers"
expect_eq "$KL_REC/$KL_COMPAT" "$SPEC/>=0.2,<0.3" "detect-steps: reports the spec and the app's compat range"
expect_eq "$CHANGED" '[{"name":"a","path":"steps/a"},{"name":"compose-and-validate","path":"config"}]' "detect-steps: a moved spec rebuilds the steps that declare the ARG and the compose image, not the others"
expect_has "$OUT" "kaos-lib package moved to ${SPEC}" "detect-steps: says why the step rebuilds"

detect_case "$SPEC"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; run_detect
expect_eq "$CHANGED" "[]" "detect-steps: the spec the images already have rebuilds nothing"
expect_eq "$KL_PKG" "$SPEC" "detect-steps: a step that rebuilds for its own reasons still gets the spec"

detect_case "-"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "-"; run_detect
expect_eq "$KL_PKG/$KL_REC/$CHANGED" "//[]" "detect-steps: a context without kaosLib changes nothing"

# ON-DEMAND REBUILD: a stale app is rebuilt when it is used (a push), not by every reconcile-submitted build.
detect_case "$OLD"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; EVENT=reconcile run_detect
expect_eq "$CHANGED" "[]" "detect-steps: a reconcile build (re-render, dataset, context) leaves STALE kaos-lib images alone"
expect_eq "$KL_PKG/$KL_REC" "$OLD/$OLD" "detect-steps: ... and keeps recording the spec the images really have"
expect_has "$OUT" "kaos-lib STALE" "detect-steps: says the app is stale and rebuilt when next used"
detect_case "$OLD"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; EVENT=reconcile KL_REBUILD=true run_detect
# The compose image carries kaos-lib too (it resolves the run's data with it), so a kaos-lib move rebuilds it with the steps.
expect_eq "$CHANGED" '[{"name":"a","path":"steps/a"},{"name":"compose-and-validate","path":"config"}]' "detect-steps: the reconciler's kaos-lib build (kaos_lib_rebuild=true) rebuilds the stale step and the compose image"
detect_case "$OLD"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; EVENT=push run_detect
expect_eq "$CHANGED/$KL_REC" '[{"name":"a","path":"steps/a"},{"name":"compose-and-validate","path":"config"}]/'"$SPEC" "detect-steps: a push (the app is in use) rebuilds the stale step and the compose image: the run gets the fresh image"
detect_case "-"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; EVENT=reconcile run_detect
expect_eq "$CHANGED" '[{"name":"a","path":"steps/a"},{"name":"compose-and-validate","path":"config"}]' "detect-steps: an app with NO record (built before delivery) is rebuilt, with the compose image, by a reconcile build once"

# A commit that touched step b is built (last-built-sha = HEAD). A reconcile of it rebuilds nothing
# (the pool's ConfigMap trails gitops, so the backstop can run for the SHA that just finished: live,
# kaos e2e 10480ba0 rebuilt e2e-probe 2 min after its own build); the same SHA on a push still does.
built_head_touching_b() {
  detect_case "$SPEC"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"
  ( cd "$T/workspace/repo" && printf 'y\n' > steps/b/code.py && git add -A \
      && git -c user.email=t@t -c user.name=t commit -qm three )
  sed -i "s#^  last-built-sha: .*#  last-built-sha: $(git -C "$T/workspace/repo" rev-parse HEAD)#" \
    "$T/fixture/kubeapps/${APP}/main/pipeline-images.yaml"
}
built_head_touching_b; EVENT=reconcile run_detect
expect_eq "$RC/$CHANGED" "0/[]" "detect-steps: a reconcile of an already built HEAD rebuilds no step"
expect_has "$OUT" "is already built" "detect-steps: says why nothing rebuilds"
built_head_touching_b; EVENT=push run_detect
expect_eq "$CHANGED" '[{"name":"b","path":"steps/b"}]' "detect-steps: the same HEAD on a push still rebuilds the step it touched"

detect_case "-"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" 'kaos-lib==0.3.0"; touch /tmp/pwned; "'; run_detect
expect_eq "$KL_PKG/$KL_REC" "/" "detect-steps: a spec outside the operator pattern is refused"
expect_has "$OUT" "REFUSED" "detect-steps: the refusal is loud"

detect_case "-"; context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"
rm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml"; run_detect
expect_eq "$RC/$KL_PKG/$KL_REC" "1//" "detect-steps: no context in gitops: no engine, the build fails and kaos-lib is left as it is"

detect_case "-"; sed -i '/ARG KAOS_LIB_PACKAGE/d' "$T/workspace/repo/steps/a/Dockerfile"
context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "$SPEC"; run_detect
expect_eq "$KL_PKG/$KL_REC/$CHANGED" "$SPEC/$SPEC/"'[{"name":"compose-and-validate","path":"config"}]' "detect-steps: no step Dockerfile declares the ARG: the chart's compose Dockerfile does, so the spec is still delivered through it"

# ── build-push ───────────────────────────────────────────────────────────────

BUILD_SRC="${BASE_TMP}/build.src"; src ml-ci-build build-push > "$BUILD_SRC"
ENVV=$(yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "build-push")
           | .container.env[] | select(.name == "KAOS_LIB_PACKAGE") | .value' "$RENDERED")
expect_eq "$ENVV" "{{inputs.parameters.kaos_lib_package}}" "build-push: the spec reaches kaniko as an env var, not script text"
expect_not "$BUILD_SRC" "inputs.parameters.kaos_lib_package" "build-push: the script never splices the spec"
run_build() {  # run_build SPEC DECLARES_ARG
  T=$(mktemp -d "${BASE_TMP}/build-XXXXXX"); mkdir -p "$T/workspace/repo/steps/a"
  if [ "$2" = yes ]; then printf 'FROM x\nARG KAOS_LIB_PACKAGE="kubecore==0.2.0"\n' > "$T/workspace/repo/steps/a/Dockerfile"
  else printf 'FROM x\n' > "$T/workspace/repo/steps/a/Dockerfile"; fi
  printf '#!/bin/sh\nfor a in "$@"; do printf "%%s\\n" "$a"; done > %s/args\n' "$T" > "$T/executor"; chmod +x "$T/executor"
  sed -e "s#/kaniko/executor#${T}/executor#g" -e "s#/workspace#${T}/workspace#g" \
      -e "s#{{inputs.parameters.step_name}}#a#g" -e "s#{{inputs.parameters.step_path}}#steps/a#g" \
      -e "s#{{inputs.parameters.image_tag}}#dev-v1#g" -e "s#{{workflow.parameters.[a-z_]*}}#x#g" \
      "$BUILD_SRC" > "$T/build.sh"
  OUT=$(KAOS_LIB_PACKAGE="$1" sh "$T/build.sh" 2>&1); RC=$?
  ARGS=$(cat "$T/args" 2>/dev/null)
}
run_build "$SPEC" yes
expect_eq "$RC" 0 "build-push: runs"
expect_has "$ARGS" "--build-arg=KAOS_LIB_PACKAGE=${SPEC}" "build-push: passes the spec as ONE build-arg (spaces and # kept)"
expect_has "$ARGS" "--label=io.kaos.lib=${SPEC}" "build-push: stamps the image label io.kaos.lib"
expect_has "$ARGS" "--cache-repo=" "build-push: the layer cache is still on (kaniko keys it on the ARG)"
run_build "$SPEC" no
expect_not "$ARGS" "KAOS_LIB_PACKAGE" "build-push: a Dockerfile without the ARG gets no build-arg"
expect_not "$ARGS" "io.kaos.lib" "build-push: ... and no label claiming a package it does not have"
run_build "" yes
expect_not "$ARGS" "KAOS_LIB_PACKAGE" "build-push: no spec: the Dockerfile's default, as before"

# ── patch-images ─────────────────────────────────────────────────────────────

PATCH_SRC="${BASE_TMP}/patch.src"; src ml-ci-build patch-images > "$PATCH_SRC"
run_patch() {  # run_patch RECORD COMPAT
  T=$(mktemp -d "${BASE_TMP}/patch-XXXXXX"); mkdir -p "$T/bin" "$T/seed/kubeapps/${APP}/main"
  printf 'token' > "$T/token"
  printf 'kind: ConfigMap\nmetadata: {name: app1-pipeline-images}\ndata: {last-built-sha: old, a: "reg/app:a-1"}\n' \
    > "$T/seed/kubeapps/${APP}/main/pipeline-images.yaml"
  # the committed render the build records the produced datasets from (its compose step's step table)
  printf '{"kind": "WorkflowTemplate", "spec": {"templates": [{"name": "compose-and-validate", "container": {"image": "x", "args": ["--steps", "[]"]}}]}}\n' \
    > "$T/seed/kubeapps/${APP}/main/workflow-template.yaml"
  git init -q --bare -b main "$T/origin.git"
  ( cd "$T/seed" && git init -q -b main && git add -A && git -c user.email=t@t -c user.name=t commit -qm seed \
      && git push -q "$T/origin.git" main )
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ]; then set -- "\${@:1:\$((\$#-2))}" "$T/origin.git" "\${@: -1}"; fi
exec /usr/bin/git "\$@"
EOF
  chmod +x "$T/bin/git"
  sed -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" -e "s#{{workflow.parameters.commit_sha}}#${HEAD_SHA}#g" \
      -e "s#{{inputs.parameters.image_tag}}#dev-v2#g" -e "s#{{inputs.parameters.changed_steps}}#[]#g" \
      -e "s#{{workflow.parameters.[a-z_]*}}##g" -e "s#/tmp/#${T}/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" -e "s#/etc/registry-auth#${T}/none#g" "$PATCH_SRC" > "$T/patch.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" KL_RECORD="$1" KL_COMPAT="$2" HOME="$T" ${KL_SHELL:-bash} "$T/patch.sh" 2>&1); RC=$?
  git clone -q "$T/origin.git" "$T/check" 2>/dev/null
  REC=$(yq '.data."kaos-lib-package" // "<absent>"' "$T/check/kubeapps/${APP}/main/pipeline-images.yaml")
  COMPAT=$(yq '.data."kaos-lib-compat" // "<absent>"' "$T/check/kubeapps/${APP}/main/pipeline-images.yaml")
}
run_patch "$SPEC" ">=0.2,<0.3"
expect_eq "$RC" 0 "patch-images: runs"
expect_eq "$REC" "$SPEC" "patch-images: records the built spec (kaos-lib-package)"
expect_eq "$COMPAT" ">=0.2,<0.3" "patch-images: records the app's range (kaos-lib-compat)"
run_patch "none" ""
expect_eq "$REC/$COMPAT" "none/" "patch-images: none, with no range declared"
run_patch "" ""
expect_eq "$REC/$COMPAT" "<absent>/<absent>" "patch-images: nothing to report leaves the keys alone"

# ── ml-ci-reconcile: KAOS-LIB DRIFT ──────────────────────────────────────────

DRIFT_SRC="${BASE_TMP}/check-drift.src"; src ml-ci-reconcile check-drift > "$DRIFT_SRC"
REF=$(printf '%s' "$SPEC" | sha256sum | cut -c1-12)
drift_case() {  # drift_case RECORDED(-=absent) CONTEXT_SPEC(-=none); RUN_AGE = seconds since the app's last LABELLED pipeline run (default 1h: hot); REF_AGE = seconds since its last run that only has spec.workflowTemplateRef (none by default)
  RUN_AGE="${RUN_AGE-3600}"; RUN_TS=""; [ -n "$RUN_AGE" ] && RUN_TS=$(ago "$RUN_AGE")
  REF_TS=""; [ -n "${REF_AGE:-}" ] && REF_TS=$(ago "$REF_AGE")
  T=$(mktemp -d "${BASE_TMP}/drift-XXXXXX"); mkdir -p "$T/bin"; printf 'token' > "$T/token"
  context_cm "$T/gitops-context.yaml" "$2"
  CTX_SHA=$(sha256sum < "$T/gitops-context.yaml" | cut -c1-64)
  printf '{"items": []}' > "$T/workflows.json"
  printf 'computeClasses:\n  cpu:\n    allocatable:\n      memoryGiB: 13\nmlEnvironment:\n  name: train\n' > "$T/context.yaml"
  printf '{"spec": {"templates": [{"name": "compose-and-validate", "inputs": {"parameters": [{"name": "mem", "default": "13Gi"}]}}, {"nodeSelector": {"platform.kubecore.io/environment": "train"}}]}}' > "$T/wft.json"
  jq -n --arg head "$HEAD_SHA" --arg ctx "$CTX_SHA" --arg rec "$1" \
    '{data: ({"last-built-sha": $head, "context-sha": $ctx}
             + (if $rec == "-" then {} else {"kaos-lib-package": $rec} end))}' > "$T/cm.json"
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"workflow-template=${APP}-pipeline"*)
    [ "${RUNS_UNREADABLE:-}" = 1 ] && exit 1
    if [ -n "${RUN_AGE:-}" ]; then printf '{"items": [{"metadata": {"creationTimestamp": "%s"}}]}' "${RUN_TS}"; else printf '{"items": []}'; fi ;;
  *"get workflows -n proj-train"*)
    # the namespace's full list: a labelled run, an unlabelled run with the template ref, other apps' runs
    [ "${RUNS_UNREADABLE:-}" = 1 ] && exit 1
    echo "1" >> "$T/ref-list-read"
    jq -n --arg lab "${RUN_TS}" --arg ref "${REF_TS}" --arg app "${APP}-pipeline" \
      '{items: ([{metadata: {creationTimestamp: "2020-01-01T00:00:00Z"}, spec: {workflowTemplateRef: {name: "other-pipeline"}}}]
        + (if \$lab != "" then [{metadata: {creationTimestamp: \$lab, labels: {"workflows.argoproj.io/workflow-template": \$app}}, spec: {workflowTemplateRef: {name: \$app}}}] else [] end)
        + (if \$ref != "" then [{metadata: {creationTimestamp: \$ref}, spec: {workflowTemplateRef: {name: \$app}}}] else [] end))}' ;;
  *"get workflows"*) cat "$T/workflows.json" ;;
  *"get configmap ${APP}-pipeline-images"*) cat "$T/cm.json" ;;
  *"get configmap ${APP}-pipeline-context"*) cat "$T/context.yaml" ;;
  *"get workflowtemplate ${APP}-pipeline"*) cat "$T/wft.json" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"/commits/dev"*) printf '{"sha": "%s"}' "$HEAD_SHA" ;;
  *"pipeline-context.yaml"*) cat "$T/gitops-context.yaml" ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$T/bin/kubectl" "$T/bin/curl"
}
attempt() {  # attempt PHASE AGE_S REF
  jq --arg fin "$(ago "$2")" --arg ph "$1" --arg ref "$3" --arg app "$APP" '.items += [{metadata: {name: "b1", creationTimestamp: $fin,
     labels: {"platform.kubecore.io/app": $app, "platform.kubecore.io/submitted-by": "ml-ci-reconcile", "platform.kubecore.io/kaos-lib": $ref}},
     spec: {arguments: {parameters: [{name: "app_name", value: $app}]}}, status: {phase: $ph, finishedAt: $fin}}]' \
    "$T/workflows.json" > "$T/w" && mv "$T/w" "$T/workflows.json"
}
run_drift() {
  sed -e "s#{{workflow.namespace}}#ci#g" -e "s#{{workflow.parameters.force}}#false#g" \
      -e "s#{{workflow.parameters.context_sha}}##g" -e "s#{{workflow.parameters.app_name}}#${APP}#g" \
      -e "s#{{workflow.parameters.project_name}}#proj#g" -e "s#{{workflow.parameters.branch}}#dev#g" \
      -e "s#{{workflow.parameters.ci_namespace}}#ci#g" -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" \
      -e "s#{{workflow.parameters.repo_url}}##g" -e "s#{{workflow.parameters.ml_namespace}}#proj-train#g" \
      -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.workflow_template_path}}#kubeapps/${APP}/main/workflow-template.yaml#g" \
      -e "s#/tmp/#${T}/#g" -e "s#/etc/github-token/token#${T}/token#g" "$DRIFT_SRC" > "$T/check-drift.sh"
  OUT=$(PATH="$T/bin:$PATH" ${KL_SHELL:-bash} "$T/check-drift.sh" 2>&1); RC=$?
  NEEDS=$(cat "$T/needs_build" 2>/dev/null || echo "<unset>"); KREF=$(cat "$T/kaos_lib_ref" 2>/dev/null)
}
drift_case "$SPEC" "$SPEC"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "reconcile: the images have the delivered spec: no build"
expect_has "$OUT" "kaos-lib in sync" "reconcile: says so"
drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$RC/$NEEDS/$KREF" "0/true/$REF" "reconcile: the context delivers another spec: rebuild, labelled with its ref"
expect_has "$OUT" "KAOS-LIB DRIFT" "reconcile: says why"
drift_case "-" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: images built before the record existed: rebuild once"
drift_case "${SPEC/kubecore\[zitadel\]/kaos-lib[zitadel]}" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: exact string equality: the same URL under another name is drift"
drift_case "none" "$SPEC"; run_drift
expect_eq "$NEEDS" "false" "reconcile: no Dockerfile declares the ARG (none): nothing to rebuild"
drift_case "$OLD" "-"; run_drift
expect_eq "$NEEDS" "false" "reconcile: the context delivers no kaos-lib: no drift"
drift_case "$OLD" "$SPEC"; attempt Failed 600 "$REF"; run_drift
expect_eq "$NEEDS" "false" "reconcile: an attempt at this spec failed 10 min ago: wait, do not storm"
drift_case "$OLD" "$SPEC"; attempt Failed 7200 "$REF"; run_drift
expect_eq "$NEEDS" "true" "reconcile: the last attempt is over an hour old: retry"
drift_case "$OLD" "$SPEC"; attempt Failed 600 "000000000000"; run_drift
expect_eq "$NEEDS" "true" "reconcile: a recent attempt at ANOTHER spec does not hold this one back"
# ON-DEMAND REBUILD + BACKGROUND TRICKLE (the app's last pipeline run decides when a stale app is rebuilt)
RUN_AGE=3600 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: STALE app that ran within the day (hot): rebuilt at once"
RUN_AGE=3600 drift_case "$OLD" "$SPEC"; printf '{"items": [{"metadata": {"name": "bg", "labels": {"platform.kubecore.io/kaos-lib": "abc"}}, "status": {"phase": "Running"}, "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "other"}]}}}]}' > "$T/workflows.json"; run_drift
expect_eq "$NEEDS" "true" "reconcile: a hot app is not held back by another app's background rebuild"
RUN_AGE=259200 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: STALE app that ran 3 days ago (warm), nothing else rebuilding: rebuilt in the background"
RUN_AGE=259200 drift_case "$OLD" "$SPEC"; printf '{"items": [{"metadata": {"name": "bg", "labels": {"platform.kubecore.io/kaos-lib": "abc"}}, "status": {"phase": "Running"}, "spec": {"arguments": {"parameters": [{"name": "app_name", "value": "other"}]}}}]}' > "$T/workflows.json"; run_drift
expect_eq "$NEEDS" "false" "reconcile: a warm app waits while another background kaos-lib rebuild runs (one at a time per project)"
expect_has "$OUT" "background kaos-lib rebuild(s) already in flight" "reconcile: says why"
RUN_AGE=3456000 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "false" "reconcile: STALE app idle 40 days: not rebuilt in the background"
expect_has "$OUT" "rebuilds when it is next used" "reconcile: says it rebuilds when used"
RUN_AGE="" drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "false" "reconcile: STALE app that never ran: not rebuilt in the background"
RUNS_UNREADABLE=1 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "false" "reconcile: the runs cannot be listed: unknown use is never a reason to rebuild"
# A run counts as use by its label OR by spec.workflowTemplateRef.name (the console/gateway create runs with no label)
RUN_AGE="" REF_AGE=3600 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "reconcile: STALE app whose only run is unlabelled (template ref), 1h ago: rebuilt"
# the age is computed from the clock when the stub is written, so a second may pass before the script reads it: a range, not an exact number
SEEN_AGE=$(printf '%s' "$OUT" | sed -n 's/.*the app ran \([0-9][0-9]*\)s ago.*/\1/p' | head -1)
expect_eq "$([ "${SEEN_AGE:-0}" -ge 3600 ] && [ "${SEEN_AGE:-0}" -lt 3660 ] && echo yes || echo "no (${SEEN_AGE:-none})")" "yes" "reconcile: ... and the age is the unlabelled run's (3600s, give or take the clock)"
RUN_AGE="" REF_AGE=259200 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: unlabelled run 3 days ago (warm), nothing else rebuilding: rebuilt in the background"
RUN_AGE="" REF_AGE=3456000 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "false" "reconcile: unlabelled run 40 days ago: idle, not rebuilt in the background"
RUN_AGE=3456000 REF_AGE=3600 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: an old labelled run and a fresh unlabelled one: the fresh one counts (rebuilt)"
RUN_AGE=3600 REF_AGE=3456000 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "true" "reconcile: a fresh labelled run and an old unlabelled one: the fresh one counts (rebuilt)"
RUN_AGE=3600 drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$([ -f "$T/ref-list-read" ] && wc -l < "$T/ref-list-read" || echo 0)" "0" "reconcile: a hot labelled run: the namespace's full run list is not read"
RUN_AGE="" REF_AGE="" drift_case "$OLD" "$SPEC"; run_drift
expect_eq "$NEEDS" "false" "reconcile: no run of either shape (other apps' runs only): never used, not rebuilt"
expect_has "$OUT" "app use: never" "reconcile: says never"
LABEL=$(yq 'select(.metadata.name == "ml-ci-reconcile") | .spec.templates[] | select(.name == "submit-build") | .resource.manifest' "$RENDERED" \
        | yq '.metadata.labels["platform.kubecore.io/kaos-lib"]')
expect_eq "$LABEL" "{{inputs.parameters.kaos_lib_ref}}" "reconcile: the submitted build carries the spec ref (the attempt guard's label)"

# ── kaos-lib-support ─────────────────────────────────────────────────────────

SUP_SRC="${BASE_TMP}/support.src"; src ml-ci-build kaos-lib-support > "$SUP_SRC"
SUPPORT='{"version": "0.4.0", "supported": ">=0.3", "deprecated": [{"range": "<0.3", "unsupported_after": "2099-01-01"}]}'
support_case() {  # support_case VERSION SUPPORT_JSON REFUSE
  T=$(mktemp -d "${BASE_TMP}/support-XXXXXX"); mkdir -p "$T/bin" "$T/fixture/kubeapps/${APP}/main"; printf 'token' > "$T/token"
  context_cm "$T/fixture/kubeapps/${APP}/main/pipeline-context.yaml" "kaos-lib[zitadel]==$1" "$2" "$1"
  cat > "$T/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = clone ]; then dst="\${@: -1}"; mkdir -p "\$dst"; cp -r "$T/fixture/." "\$dst/"; exit 0; fi
exec /usr/bin/git "\$@"
EOF
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
out=""; data=""; while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift ;; -d) data="\$2"; shift ;; -D) : > "\$2"; shift ;; esac; shift; done
printf '%s\n' "\$data" >> "$T/posted"; [ -n "\$out" ] && printf '{}' > "\$out"; printf '201'
EOF
  chmod +x "$T/bin/git" "$T/bin/curl"
  sed -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" -e "s#{{workflow.parameters.commit_sha}}#${HEAD_SHA}#g" \
      -e "s#{{workflow.parameters.repo_url}}#https://github.com/org/proj-app1.git#g" \
      -e "s#{{inputs.parameters.refuse_unsupported}}#$3#g" -e "s#{{workflow\.[a-z]*}}#w#g" \
      -e "s#/tmp/#${T}/#g" -e "s#/etc/github-token/token#${T}/token#g" "$SUP_SRC" > "$T/support.sh"
  OUT=$(PATH="$T/bin:$PATH" ${KL_SHELL:-bash} "$T/support.sh" 2>&1); RC=$?
  POSTED=$(cat "$T/posted" 2>/dev/null)
}
support_case 0.4.0 "$SUPPORT" false
expect_eq "$RC" 0 "support: runs"
expect_has "$POSTED" '"state":"success","description":"kaos-lib 0.4.0 is current","context":"kaos-lib/support"' "support: current = success"
support_case 0.3.1 "$SUPPORT" false
expect_has "$POSTED" '"state":"success","description":"warning: kaos-lib 0.3.1: 0.4.0 is available"' "support: behind = success with a warning"
support_case 0.2.0 "$SUPPORT" false
expect_has "$POSTED" '"state":"success","description":"warning: kaos-lib 0.2.0 is deprecated' "support: deprecated = success with a warning"
support_case 0.1.0 '{"version": "0.4.0", "supported": ">=0.3"}' false
expect_eq "$RC" 0 "support: unsupported on a build: reported, the build is not failed here"
expect_has "$POSTED" '"state":"failure"' "support: unsupported = a red kaos-lib/support status"
support_case 0.1.0 '{"version": "0.4.0", "supported": ">=0.3"}' true
expect_eq "$RC" 1 "support: unsupported on a release: refused (the step fails)"
expect_has "$OUT" "REFUSED" "support: the refusal says why"
support_case 0.3.1 "$SUPPORT" true
expect_eq "$RC" 0 "support: behind on a release: allowed"
support_case 0.4.0 "" false
expect_eq "$RC/${POSTED:-none}" "0/none" "support: no support data in the context: no status"
TARGET=$(helm template t "${HERE}/../.." --set github.tokenSecretName=ci-token --set argo.uiBaseUrl=https://argo.example 2>/dev/null \
  | yq 'select(.metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "kaos-lib-support") | .container.args[0]')
expect_has "$TARGET" 'RUN_URL="${ARGO_BASE}/workflows/' "support: the status links to the Argo run (target_url)"

# ── wiring ───────────────────────────────────────────────────────────────────

# Parsed with PyYAML, not yq: the same yq expression answered differently in the charts-validate pod (yq 4.44.3).
for wf in ml-ci-build ml-ci-pr-render; do
  S=$(python3 -I - "$RENDERED" "$wf" <<'PY'
import sys, yaml
rendered, wf = sys.argv[1], sys.argv[2]
out = []
for doc in yaml.safe_load_all(open(rendered)):
    if not doc or doc.get("kind") != "ClusterWorkflowTemplate" or doc["metadata"]["name"] != wf:
        continue
    for t in doc["spec"]["templates"]:
        if t["name"] != ("ml-ci-run" if wf == "ml-ci-build" else wf):  # ml-ci-build's steps live in ml-ci-run
            continue
        for group in t.get("steps", []):
            for step in group:
                if step["name"] == "kaos-lib-support":
                    out.append(str(bool((step.get("continueOn") or {}).get("failed", False))).lower())
print(",".join(out))
PY
)
  expect_eq "$S" "true" "$wf: posts kaos-lib/support, reporting only"
done
PARAMS=$(yq 'select(.metadata.name == "kaos-lib-bump-pr") | [.spec.arguments.parameters[].name] | join(" ")' "$RENDERED" | grep -v '^---$' | grep .)
expect_eq "$PARAMS" "app project_name repo_url branch version spec" "kaos-lib-bump-pr: the parameter contract the composition renders against"
REQUIRED=$(yq 'select(.metadata.name == "kaos-lib-bump-pr") | [.spec.arguments.parameters[] | select(has("value") | not) | .name] | join(" ")' "$RENDERED" | grep -v '^---$' | grep .)
expect_eq "$REQUIRED" "app project_name version spec" "kaos-lib-bump-pr: app, project_name, version and spec are required"
BUMP=$(src kaos-lib-bump-pr bump)
expect_not "$BUMP" "{{workflow.parameters" "kaos-lib-bump-pr: parameters reach the script as env vars only"
expect_has "$BUMP" "kaos-lib.py bump" "kaos-lib-bump-pr: runs the tested bump"
expect_has "$BUMP" '--guide-url "https://storage.googleapis.com/kaos-dev-511509-kaos-lib/docs"' "kaos-lib-bump-pr: the bump is given the kaos-lib guide address (the support window page in a new compat file)"
expect_eq "$(grep -c 'docs/kaos-lib-versions.md' "$RENDERED")" "0" "kaos-lib-bump-pr: nothing points at the page the templates no longer have"

echo "kaos-lib: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
