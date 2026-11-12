#!/usr/bin/env bash
# Tests for ENGINE DRIFT (PRD-HPC-1461 D-80): ml-ci-build records the engine its render
# and its compose-and-validate image ran on (`engine-version`, `engine-compose` in the
# app's pipeline-images), and ml-ci-reconcile re-renders an app whose record is not the
# context's engine.version. A failing engine records `engine-attempt`
# (<version>@<epoch>) and ml-ci-reconcile submits at most one drift build per hour
# per engine version. An app that was REFUSED because it has not moved to the step
# contract (PRD novelcore/kaos#1911 AC-01, T-05) records
# <version>@<epoch>@<commit>@<kaos-lib> and is not built again, by the poll or by a
# forced run, until its commit, the engine or the kaos-lib delivered changes: one
# attempt, no loop. Also the force-mode "already satisfied" no-op: a forced
# reconcile of a HEAD already built and rendered from the current context by the
# current engine submits nothing (kaos e2e a3c48d99). Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   bash charts/custom/kubecore-ci-workflows/tests/engine-drift/run.sh /tmp/rendered.yaml
#
# The scripts under test are EXECUTED, not grepped: check-drift is extracted
# from the rendered ml-ci-reconcile and run against stub kubectl/curl, and the
# render step's pipeline-images writer is extracted from ml-ci-build and run on
# fixture files. Needs yq v4, jq and python3 + PyYAML. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
ENG=v0.4.7
OLD_ENG=v0.4.6
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
APP=app1

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

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
ago() { jq -rn --argjson s "$1" 'now - $s | floor | todate'; }

# ── check-drift ──────────────────────────────────────────────────────────────

DRIFT_SRC="${BASE_TMP}/check-drift.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
    | .spec.templates[] | select(.name == "check-drift") | .container.args[0]' \
  "$RENDERED" > "$DRIFT_SRC"

GITOPS_CONTEXT=$(python3 -c '
import yaml
ctx = {"engine": {"version": "v0.4.7", "image": "reg.example/kaos-pipeline-engine:v0.4.7",
                  "wheel": "https://example.com/engine.whl", "wheelSha256": "a" * 64}}
print(yaml.safe_dump({"kind": "ConfigMap", "data": {"context.yaml": yaml.safe_dump(ctx)}}))')
CTX_SHA=$(printf '%s\n' "$GITOPS_CONTEXT" | sha256sum | cut -c1-64)

# new_case: a sandbox where every OTHER input of check-drift is in sync — HEAD
# built, context-sha current, the cpu budget and the ml environment matching the
# live WFT — so the engine is the only thing a case varies.
new_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX")
  mkdir -p "$T/bin"
  printf 'token' > "$T/token"
  printf '%s\n' "$GITOPS_CONTEXT" > "$T/gitops-context.yaml"
  printf '{"items": []}' > "$T/workflows.json"
  cat > "$T/context.yaml" <<'EOF'
computeClasses:
  cpu:
    name: cpu-small
    allocatable:
      cpu: 3
      memoryGiB: 13
mlEnvironment:
  name: train
EOF
  cat > "$T/wft.json" <<'EOF'
{"spec": {"arguments": {"parameters": [{"name": "step-a-mem", "value": "13Gi"}]},
          "templates": [{"name": "step-a",
                         "nodeSelector": {"platform.kubecore.io/environment": "train"}}]}}
EOF
  cm
  images "$ENG" "$ENG"
  cat > "$T/bin/kubectl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"get workflows"*) cat "$T/workflows.json" ;;
  *"get configmap ${APP}-pipeline-images"*)
    [ -f "$T/cm.json" ] || { echo "Error from server (NotFound): not found" >&2; exit 1; }
    cat "$T/cm.json" ;;
  *"get configmap ${APP}-pipeline-context"*) cat "$T/context.yaml" ;;
  *"get workflowtemplate ${APP}-pipeline"*) cat "$T/wft.json" ;;
  *) echo "stub kubectl: unexpected \$*" >&2; exit 1 ;;
esac
EOF
  cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"/commits/dev"*) printf '{"sha": "%s"}' "$HEAD_SHA" ;;
  *"pipeline-context.yaml"*) cat "$T/gitops-context.yaml" ;;
  *"pipeline-images.yaml"*) [ -f "$T/fixture-images.yaml" ] && cat "$T/fixture-images.yaml" || exit 22 ;;
  *) exit 22 ;;
esac
EOF
  chmod +x "$T/bin/kubectl" "$T/bin/curl"
}

# cm [CONTEXT_SHA]: the live {app}-pipeline-images; CONTEXT_SHA "-" omits context-sha.
cm() {
  jq -n --arg head "$HEAD_SHA" --arg ctx "${1:-$CTX_SHA}" '
    {data: ({"last-built-sha": $head, "step-a": "reg/app:step-a-dev-v1-x-aaaaaaa"}
            + (if $ctx == "-" then {} else {"context-sha": $ctx} end))}' > "$T/cm.json"
}

# images ENGINE_VERSION COMPOSE_VERSION [CONTEXT_SHA [ATTEMPT]]: the pipeline-images in GITOPS, which the
# engine checks read (the live ConfigMap trails it by an ArgoCD sync). "-" omits a key.
images() {
  jq -n --arg v "$1" --arg c "$2" --arg ctx "${3:-$CTX_SHA}" --arg att "${4:--}" '
    {data: ({"last-built-sha": "x"}
            + (if $v == "-" then {} else {"engine-version": $v} end)
            + (if $c == "-" then {} else {"engine-compose": $c} end)
            + (if $ctx == "-" then {} else {"context-sha": $ctx} end)
            + (if $att == "-" then {} else {"engine-attempt": $att} end))}' | yq -P > "$T/fixture-images.yaml"
}
# reconcile_build NAME PHASE FINISHED_AT [APP]: one reconcile-submitted build.
reconcile_build() {
  jq --arg name "$1" --arg phase "$2" --arg fin "$3" --arg app "${4:-$APP}" '
    .items += [{metadata: {name: $name, creationTimestamp: $fin,
                           labels: {"platform.kubecore.io/app": $app,
                                    "platform.kubecore.io/submitted-by": "ml-ci-reconcile"}},
                spec: {arguments: {parameters: [{name: "app_name", value: $app}]}},
                status: {phase: $phase, finishedAt: $fin}}]' \
    "$T/workflows.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/workflows.json"
}
now_minus() { echo "${ENG}@$(( $(date +%s) - $1 ))"; }

# run_drift: check-drift with the Argo placeholders filled and its fixed paths
# moved into the sandbox; FORCE / WANT_CTX set the force and context_sha
# parameters (default: the backstop). Sets OUT (stdout+stderr), NEEDS, RC.
run_drift() {
  sed -e "s#{{workflow.namespace}}#ci#g" \
      -e "s#{{workflow.parameters.force}}#${FORCE:-false}#g" \
      -e "s#{{workflow.parameters.context_sha}}#${WANT_CTX:-}#g" \
      -e "s#{{workflow.parameters.app_name}}#${APP}#g" \
      -e "s#{{workflow.parameters.project_name}}#proj#g" \
      -e "s#{{workflow.parameters.branch}}#dev#g" \
      -e "s#{{workflow.parameters.ci_namespace}}#ci#g" \
      -e "s#{{workflow.parameters.gitops_repository}}#proj-gitops#g" \
      -e "s#{{workflow.parameters.repo_url}}##g" \
      -e "s#{{workflow.parameters.ml_namespace}}#proj-train#g" \
      -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.workflow_template_path}}#kubeapps/${APP}/main/workflow-template.yaml#g" \
      -e "s#/tmp/#${T}/#g" \
      -e "s#/etc/github-token/token#${T}/token#g" \
      "$DRIFT_SRC" > "$T/check-drift.sh"
  # DRIFT_SHELL: production runs this under the alpine image's busybox sh.
  OUT=$(PATH="$T/bin:$PATH" "${DRIFT_SHELL:-bash}" "$T/check-drift.sh" 2>&1); RC=$?
  NEEDS=$(cat "$T/needs_build" 2>/dev/null || echo "<unset>")
}

new_case; run_drift
expect_eq "$RC/$NEEDS" "0/false" "in sync: the render and the compose image ran on the context's engine — no build"
expect_has "$OUT" "up to date" "in sync: reports up to date"

new_case; images "$OLD_ENG" "$ENG"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "the engine moved: re-render"
expect_has "$OUT" "ENGINE DRIFT" "the engine moved: says why"
expect_eq "$(cat "$T/head_sha")" "$HEAD_SHA" "the engine moved: builds the already-built HEAD (render and compose only)"

new_case; images "$ENG" "$OLD_ENG"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "the compose image is on an older engine: build"
expect_has "$OUT" "ENGINE DRIFT" "the compose image is on an older engine: says why"

new_case; images "-" "-"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "no engine recorded yet: render once"

new_case; rm "$T/fixture-images.yaml"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "gitops pipeline-images unreadable: unknown never submits work"

new_case; printf 'kind: ConfigMap\ndata: {context.yaml: "app: x"}\n' > "$T/gitops-context.yaml"
jq --arg c "$(sha256sum < "$T/gitops-context.yaml" | cut -c1-64)" '.data["context-sha"] = $c' "$T/cm.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/cm.json"
images "$OLD_ENG" "$OLD_ENG"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "a context with no engine block: no engine drift"

new_case; cm "-"; images "$OLD_ENG" "$OLD_ENG"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "engine drift without a recorded context-sha still re-renders"

# An engine bump moves the context too: exactly one re-render, not one per poll.
new_case; cm "$(printf 'old' | sha256sum | cut -c1-64)"; images "$OLD_ENG" "$OLD_ENG" "$(printf 'old' | sha256sum | cut -c1-64)"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "the engine bumped (context changed, nothing rendered yet): one re-render"
expect_has "$OUT" "CONTEXT DRIFT" "the engine bumped: reported as the context drift it also is"
new_case; cm "$(printf 'old' | sha256sum | cut -c1-64)"; images "$ENG" "$ENG"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "the render is already pushed to gitops, the live record not synced yet: no second render"
expect_has "$OUT" "waiting for ArgoCD" "... and says so"

# ── one attempt per hour per engine version after a failure ──────────────────

new_case; cm "$(printf 'old' | sha256sum | cut -c1-64)"; images "$OLD_ENG" "$OLD_ENG" "$(printf 'old' | sha256sum | cut -c1-64)" "$(now_minus 600)"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "the build for this engine failed 10 min ago: no new attempt"
expect_has "$OUT" "ENGINE ATTEMPT GUARD" "the guard says why"

new_case; images "$OLD_ENG" "$ENG" "$CTX_SHA" "$(now_minus 600)"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "the guard also holds back ENGINE DRIFT itself"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(now_minus 7200)"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "the failed attempt is over an hour old: retry"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "${OLD_ENG}@$(( $(date +%s) - 600 ))"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "a recent failure at ANOTHER engine version does not hold the new one back"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "garbage"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "an unreadable attempt record is ignored"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(now_minus 600)"
jq '.data["last-built-sha"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$T/cm.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/cm.json"; run_drift
expect_has "$OUT" "COMMIT DRIFT" "a new push is still built while the engine is held back"

new_case; images "$OLD_ENG" "$OLD_ENG"; reconcile_build b1 Running ""
jq '.items[0].status = {phase: "Running"} | .items[0].metadata.name = "ml-ci-build-reconciled-x"' \
  "$T/workflows.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/workflows.json"; run_drift
expect_eq "$RC/$NEEDS" "0/false" "a build in flight: the existing in-flight guard still wins"

# Another app's build in the shared {project}-ci namespace must not block this app
# (e2e-suite-ml-jq4vp: yolo never built behind mlci's stuck build).
new_case; images "$OLD_ENG" "$OLD_ENG"; reconcile_build b1 Running "" other-app
jq '.items[0].status = {phase: "Running"} | .items[0].metadata.name = "ml-ci-build-x"' \
  "$T/workflows.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/workflows.json"; run_drift
expect_eq "$RC/$NEEDS" "0/true" "another app's build in flight does not block this app's reconcile"

new_case; images "$OLD_ENG" "$OLD_ENG"
jq '.data["last-built-sha"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$T/cm.json" > "$T/c.tmp" \
  && mv "$T/c.tmp" "$T/cm.json"; run_drift
expect_has "$OUT" "COMMIT DRIFT" "an unbuilt commit is still reported as commit drift first"

# ── an app that has not moved to the step contract: one attempt (PRD kaos#1911) ─
# The refused build recorded the engine, the commit and the kaos-lib it read. While all three are what
# they were, a new build would be refused again: the poll and the forced run submit nothing.

OLD_CTX=$(printf 'old' | sha256sum | cut -c1-64)
NO_LIB=$(printf '' | sha256sum | cut -c1-12)            # the fixture context delivers no kaos-lib
OTHER_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
refused() { echo "${1:-$ENG}@$(( $(date +%s) - ${4:-172800} ))@${2:-$HEAD_SHA}@${3:-$NO_LIB}"; }   # two days ago by default
unbuilt() { jq --arg s "$OTHER_SHA" '.data["last-built-sha"] = $s' "$T/cm.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/cm.json"; }

new_case; cm "$OLD_CTX"; images "$OLD_ENG" "$OLD_ENG" "$OLD_CTX" "$(refused)"; unbuilt; run_drift
expect_eq "$RC/$NEEDS" "0/false" "not migrated: HEAD was refused by this engine two days ago and never built: no new build (no COMMIT DRIFT, no CONTEXT DRIFT, no ENGINE DRIFT loop)"
expect_has "$OUT" "NOT MIGRATED — commit ${HEAD_SHA} was refused by engine ${ENG}" "not migrated: says which commit and engine"
expect_has "$OUT" "migrate-to-0.5.html" "not migrated: ... and where the guide is"
expect_has "$OUT" "Nothing is submitted until the app is pushed to, or the engine or the kaos-lib the platform delivers changes" "not migrated: ... and what ends the hold"
for n in 1 2 3; do run_drift; done
expect_eq "$RC/$NEEDS" "0/false" "not migrated: every later poll decides the same (it does not expire after an hour)"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused "$ENG" "$HEAD_SHA" "$NO_LIB" 60)"; run_drift
expect_has "$OUT" "NOT MIGRATED" "not migrated: a refusal a minute old is held by the same guard, not by the hourly one"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused "$ENG" "$OTHER_SHA")"; unbuilt; run_drift
expect_eq "$RC/$NEEDS" "0/true" "not migrated: the app was pushed to (HEAD is not the refused commit): built at once"
expect_has "$OUT" "COMMIT DRIFT" "not migrated: ... as the unbuilt push it is"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused "$OLD_ENG")"; unbuilt; run_drift
expect_eq "$RC/$NEEDS" "0/true" "not migrated: the platform pins another engine than the one that refused: tried again"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused "$ENG" "$HEAD_SHA" "$(printf 'kaos-lib==0.4.3' | sha256sum | cut -c1-12)")"; unbuilt; run_drift
expect_eq "$RC/$NEEDS" "0/true" "not migrated: the platform delivers another kaos-lib than the refused build read: tried again"

new_case; cm "$OLD_CTX"; images "$OLD_ENG" "$OLD_ENG" "$OLD_CTX" "$(refused)"; unbuilt; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/false" "not migrated, forced (the platform context changed, but not the engine or the kaos-lib): no build either"
expect_has "$OUT" "NOT MIGRATED" "not migrated, forced: says why"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused "$ENG" "$OTHER_SHA")"; unbuilt; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "not migrated, forced, after a push: built"

new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused "$OLD_ENG")"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "not migrated, forced, after the engine pin moved: built"

# The guard runs under the image's busybox sh in production: no bash-only syntax in it.
for SH in dash "busybox sh"; do
  command -v "${SH%% *}" >/dev/null 2>&1 || continue
  new_case; images "$OLD_ENG" "$OLD_ENG" "$CTX_SHA" "$(refused)"; unbuilt
  printf '#!/bin/sh
exec %s "$@"
' "$SH" > "$T/bin/posix-sh"; chmod +x "$T/bin/posix-sh"
  DRIFT_SHELL="$T/bin/posix-sh" run_drift
  expect_eq "$RC/$NEEDS" "0/false" "not migrated: the guard holds under ${SH}"
done

# ── force: already satisfied ─────────────────────────────────────────────────
# kaos e2e a3c48d99 (2026-10-19): the app-creation ci-sync (force) waited out
# the webhook build and then rebuilt the same SHA. A HEAD that is built and
# whose render recorded the current gitops context and the current engine is
# already what the force asks for; anything unknown still forces.

new_case; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/false" "force, HEAD built + rendered from the current context by the current engine: no build"
expect_has "$OUT" "FORCED but already satisfied — HEAD ${HEAD_SHA} built and rendered from the current context (${CTX_SHA:0:12}) by engine ${ENG}; nothing to do" "force satisfied: says why"

new_case; FORCE=true WANT_CTX="$CTX_SHA" run_drift
expect_eq "$RC/$NEEDS" "0/false" "force for the context already rendered (context_sha = recorded = gitops): no build"

new_case; FORCE=true WANT_CTX="$(printf 'next' | sha256sum | cut -c1-64)" run_drift
# Still exit 3 (the await-inputs step retries it). needs_build is now written as
# "false" BEFORE any decision (ci-sync wait change, charts#198), so the outputs
# exist on this exit too and Argo logs no "cannot save parameter".
expect_eq "$RC/$NEEDS" "3/false" "force for a context not yet in gitops: still waits (exit 3), output written as false"

new_case
jq '.data["last-built-sha"] = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' "$T/cm.json" > "$T/c.tmp" \
  && mv "$T/c.tmp" "$T/cm.json"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, last build is not HEAD: builds"
expect_has "$OUT" "FORCED — app created" "force, last build is not HEAD: the usual FORCED line"

new_case; jq 'del(.data["last-built-sha"])' "$T/cm.json" > "$T/c.tmp" && mv "$T/c.tmp" "$T/cm.json"
FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, new app (no last-built-sha): builds"

new_case; cm "$(printf 'old' | sha256sum | cut -c1-64)"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, recorded context-sha differs from gitops: builds"
expect_has "$OUT" "not proven current" "force, not satisfied: says which input is unproven"

new_case; cm "-"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, no context-sha recorded (unknown): builds"

new_case; images "$OLD_ENG" "$OLD_ENG"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, rendered by another engine: builds"

new_case; images "-" "-"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, no engine recorded (unknown): builds"

new_case; images "$ENG" "$OLD_ENG"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, compose image on another engine: builds"

new_case; : > "$T/gitops-context.yaml"; FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, gitops context empty/unreadable (unknown): builds"

new_case
cat > "$T/bin/curl" <<EOF
#!/usr/bin/env bash
case "\$*" in
  *"/commits/dev"*) printf '{"sha": "%s"}' "$HEAD_SHA" ;;
  *) exit 22 ;;
esac
EOF
FORCE=true run_drift
expect_eq "$RC/$NEEDS" "0/true" "force, gitops context fetch fails (unknown): builds"

new_case; rm -f "$T/cm.json"; FORCE=true run_drift
expect_eq "$RC" "0" "force, pipeline-images unreadable: never reaches the satisfied check"
expect_eq "$NEEDS" "false" "force, pipeline-images unreadable: unchanged (gitops NotFound path)"

# ── submit-build no longer carries an enhancer label ─────────────────────────

LABELS=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")
            | .spec.templates[] | select(.name == "submit-build") | .resource.manifest' "$RENDERED" \
        | yq '.metadata.labels | keys | join(",")')
expect_eq "$LABELS" "platform.kubecore.io/app,platform.kubecore.io/submitted-by,platform.kubecore.io/kaos-lib" "a reconcile-submitted build is labelled by app, submitter and kaos-lib spec only"

# ── ml-ci-build records the engine it rendered with ───────────────────────────

RENDER_SRC="${BASE_TMP}/hera-enhance-commit.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.args[0]' \
  "$RENDERED" > "$RENDER_SRC"
expect_has "$(grep -F "<<'IMGEOF'" "$RENDER_SRC")" '"$ENGINE_VERSION"' \
  "the render passes the engine version to the pipeline-images writer"
WRITER="${BASE_TMP}/writer.py"
awk '/<<'"'"'IMGEOF'"'"'/{on=1; next} /^IMGEOF$/{on=0} on' "$RENDER_SRC" > "$WRITER"

W=$(mktemp -d "${BASE_TMP}/writer-XXXX")
wft() {
  python3 - "$W/wft.yaml" "$@" <<'EOF'
import sys, yaml
steps = sys.argv[2:]
yaml.safe_dump({"metadata": {"name": "app1-pipeline", "namespace": "proj-train"},
                "spec": {"arguments": {"parameters": [
                    {"name": f"image-{s}",
                     "valueFrom": {"configMapKeyRef": {"name": "app1-pipeline-images", "key": s}}}
                    for s in steps]}}}, open(sys.argv[1], "w"))
EOF
}
images_key() { python3 -c 'import sys, yaml; print((yaml.safe_load(open(sys.argv[1]))["data"]).get(sys.argv[2], "<absent>"))' "$W/images.yaml" "$1"; }
write() { python3 "$WRITER" "$W/wft.yaml" "$W/images.yaml" "$APP" "$CTX_SHA" "$1" 2>&1; }

cat > "$W/images.yaml" <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: app1-pipeline-images, namespace: proj-train}
data: {last-built-sha: aaaa, context-sha: stale, step-a: "reg/app:step-a-1", step-b: "reg/app:step-b-1",
       engine-compose: v0.4.7, engine-last-error: "render: boom", engine-attempt: "v0.4.7@1"}
EOF
wft step-a step-b
OUT=$(write "$ENG")
expect_eq "$(images_key engine-version)" "$ENG" "a render records the engine it ran"
expect_eq "$(images_key context-sha)" "$CTX_SHA" "context-sha is still recorded beside it"
expect_eq "$(images_key engine-compose)/$(images_key engine-last-error)/$(images_key engine-attempt)" "v0.4.7/render: boom/v0.4.7@1" \
  "the other engine records are never pruned as stale step keys (the exit handler owns them)"

BEFORE=$(cat "$W/images.yaml"); OUT=$(write "$ENG")
expect_eq "$(cat "$W/images.yaml")" "$BEFORE" "re-rendering with the same engine rewrites nothing"
expect_has "$OUT" "already has" "re-rendering with the same engine says so"

wft step-a; OUT=$(write "$ENG")
expect_eq "$(images_key step-b)" "<absent>" "a step that left the render is pruned"
expect_eq "$(images_key engine-version)" "$ENG" "engine-version is never pruned as a stale step key"

OUT=$(write "$OLD_ENG")
expect_eq "$(images_key engine-version)" "$OLD_ENG" "a render on another engine records that engine"

# ── the digest pin leaves the records alone ───────────────────────────────────

PATCH=$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
            | .spec.templates[] | select(.name == "patch-images") | .container.args[0]' "$RENDERED")
for k in engine-version engine-compose engine-last-error engine-attempt; do
  expect_has "$PATCH" "[ \"\${KEY}\" = \"$k\" ] && continue" "the digest-pin loop skips $k (it is not an image)"
done

echo "engine-drift: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
