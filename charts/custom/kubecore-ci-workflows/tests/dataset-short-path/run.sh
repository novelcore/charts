#!/usr/bin/env bash
# The dataset-only re-render (PRD novelcore/kaos#1911 AC-24). Usage (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/dataset-short-path/run.sh
#
# When the datasets are the ONLY thing that differs (the commit is built, context, engine and kaos-lib are
# in sync, the images are built) ml-ci-reconcile submits ml-ci-build entered at ml-ci-dataset-render: a
# render-only run without the probe. Proven here:
#   1. the short run calls the SAME render-hera template, with the same arguments, as ml-ci-run (whose
#      render is what every other build commits), after the same clone and detect-steps;
#   2. it takes the app's build mutex, the one ml-ci-build and ml-ci-reconcile's decision hold;
#   3. check-drift EXECUTED against stubs chooses it only when nothing else drifted, and takes the full
#      ml-ci-build for every other reason (new commit, context drift, kaos-lib, unbuilt image, no render);
#   4. submit-build enters the short template only on render_only, through Strict's `entrypoint`;
#   5. the commit guard of hera-enhance-commit, EXECUTED: pushes only while the commit is HEAD and built.
# Needs helm, yq v4, jq, python3. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0; PASSED=0
HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_eq() { if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"; else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi; }
expect_has() { case "$1" in *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;; *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"; echo "  actual: $(printf '%s' "$1" | tail -5)" ;; esac; }

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"; kill ${CATALOG_PID:-0} 2>/dev/null' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }
ML='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")'
REC='select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-reconcile")'
tmpl() { yq "$ML | .spec.templates[] | select(.name == \"$1\") | $2" "$RENDERED"; }

# ── 1. the same render, with the same inputs ────────────────────────────────
expect_eq "$(tmpl ml-ci-dataset-run '.steps | map(map(.name) | join("+")) | join(" > ")')" "clone > detect-steps > render-hera" \
  "short run: clone > detect-steps > render-hera"
expect_eq "$(tmpl ml-ci-run '.steps[][] | select(.name == "clone") | .template')/$(tmpl ml-ci-dataset-run '.steps[][] | select(.name == "clone") | .template')" "clone/clone" \
  "both runs clone with the same template"
expect_eq "$(tmpl ml-ci-run '.steps[][] | select(.name == "detect-steps") | .template')/$(tmpl ml-ci-dataset-run '.steps[][] | select(.name == "detect-steps") | .template')" "detect-steps/detect-steps" \
  "both runs detect with the same template (its engine json, image and profile feed the render)"
FULL=$(tmpl ml-ci-run '.steps[][] | select(.name == "render-hera") | {"template": .template, "templateRef": .templateRef, "arguments": .arguments}' | yq -o=json -I=0 '.')
SHORT=$(tmpl ml-ci-dataset-run '.steps[][] | select(.name == "render-hera") | {"template": .template, "templateRef": .templateRef, "arguments": .arguments}' | yq -o=json -I=0 '.')
expect_eq "$SHORT" "$FULL" "the short run calls render-hera with exactly the template and arguments ml-ci-run does"
expect_eq "$(printf '%s' "$SHORT" | jq -r '.template')" "render-hera" "and it is the render-hera template of ml-ci-build, not a copy"
expect_eq "$(tmpl render-hera '.steps | map(map(.template) | join("+")) | join(" > ")')" "hera-render > hera-enhance-commit" \
  "render-hera is the tokenless render then the token-holding enhance and commit, for both runs"
# No second render, enhance or seal anywhere: hera-render and hera-enhance-commit stay the only templates that call them.
expect_eq "$(yq "$ML | .spec.templates[] | select(.name != \"render-hera\") | .steps[][]? | select(.template == \"hera-render\" or .template == \"hera-enhance-commit\") | .name" "$RENDERED" | grep -vc '^---$')" "0" \
  "no other template calls hera-render or hera-enhance-commit"
expect_eq "$(tmpl ml-ci-dataset-render '.steps | map(map(.name) | join("+")) | join(" > ")')" "status-pending+render-run > status" \
  "entrypoint: the pending status beside the run, the success status after it"
expect_eq "$(tmpl ml-ci-dataset-render '.steps[][] | select(.name == "status-pending" or .name == "status") | .continueOn.failed' | grep -vc '^---$')" "2" \
  "the statuses only report (a GitHub write that fails is not a failed run)"
expect_eq "$(yq "$ML | .spec.onExit" "$RENDERED")" "exit-handler" "a failed short run is reported by the same exit handler (failure status, run report)"

# ── 2. the build mutex ──────────────────────────────────────────────────────
expect_eq "$(tmpl ml-ci-dataset-run-locked '.synchronization.mutexes[0].name')" "$(tmpl ml-ci-run-locked '.synchronization.mutexes[0].name')" \
  "the short run holds the app's build mutex, the one the builds hold"
expect_eq "$(tmpl ml-ci-dataset-run-locked '.steps[][].template')" "ml-ci-dataset-run" "the mutex covers the clone, detect and render"
expect_eq "$(tmpl ml-ci-dataset-render '.synchronization')" "null" "the entrypoint itself takes no lock: the pending status is not queued"

# ── 4. submit-build ─────────────────────────────────────────────────────────
MANIFEST=$(yq "$REC | .spec.templates[] | select(.name == \"submit-build\") | .resource.manifest" "$RENDERED")
expect_has "$MANIFEST" "entrypoint: \"{{=inputs.parameters.render_only == 'true' ? 'ml-ci-dataset-render' : 'ml-ci-build'}}\"" \
  "submit-build enters ml-ci-dataset-render only on render_only, ml-ci-build otherwise"
expect_has "$MANIFEST" "name: dataset_render" "submit-build tells the build it is the dataset-only run"
expect_has "$MANIFEST" "generateName: ml-ci-build-reconciled-" "the short run is named and labelled as a reconciled build: the in-flight and queued checks see it"
expect_eq "$(yq "$REC | .spec.templates[] | select(.name == \"decide-and-submit\") | .steps[][] | select(.name == \"submit-build\") | .arguments.parameters[] | select(.name == \"render_only\") | .value" "$RENDERED")" \
  "{{steps.check-drift.outputs.parameters.render_only}}" "decide-and-submit passes check-drift's decision on"
expect_eq "$(yq "$REC | .spec.templates[] | select(.name == \"check-drift\") | .outputs.parameters[] | select(.name == \"render_only\") | .valueFrom.default" "$RENDERED")" "false" \
  "the decision defaults to the full build"
expect_eq "$(yq "$ML | .spec.arguments.parameters[] | select(.name == \"dataset_render\") | .value" "$RENDERED")" "false" \
  "every other ml-ci-build run is not a dataset-only run"

# ── 3. the decision, executed ───────────────────────────────────────────────
DRIFT_SRC="${BASE_TMP}/check-drift.src"
yq "$REC | .spec.templates[] | select(.name == \"check-drift\") | .container.args[0]" "$RENDERED" > "$DRIFT_SRC"
WORK="${BASE_TMP}/catalog"; mkdir -p "$WORK"
cat > "$WORK/catalog.py" <<'PY'
import http.server, json, sys
BODY = {"datasets": [{"name": "dataset-cars", "versions": [{"tag": "v2", "commit": "c2"}]}]}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(json.dumps(BODY).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 18931), H).serve_forever()
PY
python3 "$WORK/catalog.py" & CATALOG_PID=$!
sleep 1
OLD_DS=1111111111111111111111111111111111111111111111111111111111111111
IDLE='{"items": []}'
GOOD_WFT='kind: WorkflowTemplate
spec:
  templates:
  - name: compose-and-validate
    inputs:
      parameters:
      - name: image-train
        valueFrom: {configMapKeyRef: {name: app1-pipeline-images, key: train}}
      - name: image-compose
        valueFrom: {configMapKeyRef: {name: app1-pipeline-images, key: compose-and-validate}}
'
GOOD_IMAGES="metadata:
  namespace: ml-proj
data:
  dataset-sha: ${OLD_DS}
  train: reg/proj/app1:train-dev-v1.0.0-aaaaaaa
  compose-and-validate: reg/proj/app1:compose-and-validate-dev-v1.0.0-aaaaaaa
"
GOOD_CTX=$(printf 'kaosLib:\n  spec: "kaos-lib==0.5.1"\n  version: "0.5.1"\n')
# run_case: a dataset event on an app whose commit is built and whose datasets differ. Variables: LAST (the
# CM's last-built-sha), CM_CTX_SHA, CM_KL (the CM's kaos-lib-package), WFT, IMAGES, GITOPS_CTX.
run_case() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX"); mkdir -p "$T/bin"
  printf 'token' > "$T/token"; printf 'pod-token' > "$T/lake-token"
  printf '%s' "$WFT" > "$T/wft.yaml"; printf '%s' "$IMAGES" > "$T/images.yaml"; printf '%s' "$GITOPS_CTX" > "$T/ctx.yaml"
  CMJ=$(jq -nc --arg l "${LAST:-$HEAD_SHA}" --arg c "${CM_CTX_SHA:-}" --arg k "${CM_KL:-}" --arg d "$OLD_DS" \
    '{data: ({"last-built-sha": $l, "dataset-sha": $d} + (if $c == "" then {} else {"context-sha": $c} end) + (if $k == "" then {} else {"kaos-lib-package": $k} end))}')
  cat > "$T/bin/kubectl" <<KEOF
#!/usr/bin/env bash
case "\$*" in
  *"get workflows"*) printf '%s' '$IDLE' ;;
  *"get configmap"*"pipeline-context"*) printf 'lakefs:\n  endpoint: http://127.0.0.1:${CAT_PORT:-18931}/\ncomputeClasses:\n' ;;
  *"get configmap"*) printf '%s' '$CMJ' ;;
  *) echo "stub kubectl: unexpected \$*" >&2; exit 1 ;;
esac
KEOF
  cat > "$T/bin/curl" <<KEOF
#!/usr/bin/env bash
case "\$*" in
  *"/commits/"*) printf '{"sha":"%s"}' '$HEAD_SHA' ;;
  *"pipeline-images.yaml"*) cat "$T/images.yaml" ;;
  *"pipeline-context.yaml"*) cat "$T/ctx.yaml" ;;
  *"workflow-template.yaml"*) [ -n '$WFT' ] || exit 22; cat "$T/wft.yaml" ;;
  *) exit 22 ;;
esac
KEOF
  chmod +x "$T/bin/kubectl" "$T/bin/curl"
  sed -e "s#{{workflow.namespace}}#ci#g" -e "s#{{inputs.parameters.mode}}#decide#g" -e "s#{{workflow.parameters.force}}#false#g" \
      -e "s#{{workflow.parameters.context_sha}}##g" -e "s#{{workflow.parameters.app_name}}#app1#g" -e "s#{{workflow.parameters.project_name}}#proj#g" \
      -e "s#{{workflow.parameters.branch}}#dev#g" -e "s#{{workflow.parameters.ci_namespace}}#ci#g" -e "s#{{workflow.parameters.ml_namespace}}##g" \
      -e "s#{{workflow.parameters.gitops_repository}}#proj#g" -e "s#{{workflow.parameters.gitops_branch}}#main#g" \
      -e "s#{{workflow.parameters.workflow_template_path}}#kubeapps/app1/main/workflow-template.yaml#g" -e "s#{{workflow.parameters.repo_url}}##g" \
      -e "s#{{workflow.parameters.dataset_event}}#true#g" -e "s#/tmp/#${T}/#g" -e "s#/etc/github-token/token#${T}/token#g" \
      -e "s#/var/run/secrets/kaos-lake/token#${T}/lake-token#g" "$DRIFT_SRC" > "$T/check-drift.sh"
  OUT=$(PATH="$T/bin:$PATH" bash "$T/check-drift.sh" 2>&1); RC=$?
  NEEDS=$(cat "$T/needs_build" 2>/dev/null || echo "<unset>"); RONLY=$(cat "$T/render_only" 2>/dev/null || echo "<unset>")
}
defaults() { WFT="$GOOD_WFT"; IMAGES="$GOOD_IMAGES"; GITOPS_CTX="$GOOD_CTX"; LAST="$HEAD_SHA"; CM_CTX_SHA=""; CM_KL="kaos-lib==0.5.1"; }

defaults; run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/true" "only the datasets differ, images built: the render-only run"
expect_has "$OUT" "submitting the render-only ml-ci-dataset-render run" "and says so"

defaults; LAST=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "a commit that was never built: the full build"
expect_has "$OUT" "COMMIT DRIFT" "  (commit drift)"

defaults; CM_CTX_SHA=2222222222222222222222222222222222222222222222222222222222222222 run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "the platform context changed since the last render: the full build"
expect_has "$OUT" "CONTEXT DRIFT" "  (context drift)"

defaults; CM_KL="kaos-lib==0.5.0" run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "the images have another kaos-lib than the platform delivers: the full build"
expect_has "$OUT" "full path: kaos-lib" "  (and says why)"

defaults; CM_KL="none" run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/true" "no step declares the kaos-lib ARG: nothing to rebuild, the render-only run"

defaults; GITOPS_CTX="computeClasses:" CM_KL="" run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/true" "a context without kaosLib delivers nothing to rebuild: the render-only run"

defaults; IMAGES=$(printf '%s' "$GOOD_IMAGES" | sed 's#reg/proj/app1:train-dev-v1.0.0-aaaaaaa#:train-latest#') run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "a step image still the -latest placeholder: the full build, which builds it"
expect_has "$OUT" "image train is not built" "  (and says which)"

defaults; IMAGES=$(printf '%s' "$GOOD_IMAGES" | grep -v '^  train:') run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "a step image absent from the record: the full build"

defaults; IMAGES=$(printf '%s' "$GOOD_IMAGES" | grep -v 'compose-and-validate') run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "no compose image recorded: the full build"

defaults; WFT="" run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "no committed render yet: the full build"
expect_has "$OUT" "no committed render" "  (and says why)"

defaults; WFT="kind: WorkflowTemplate" run_case
expect_eq "$RC/$NEEDS/$RONLY" "0/true/false" "a committed render that references no image: the full build"

# the retry rules stay: a catalog that cannot be read is "not yet" (exit 3, retried), never a decision
defaults; CAT_PORT=1 run_case
expect_eq "$RC/$RONLY" "3/false" "dataset event, catalog unreadable: exit 3 (not yet), no render-only decision"
unset CAT_PORT

# ── 5. the commit guard of hera-enhance-commit, executed ────────────────────
ENH="${BASE_TMP}/enhance.src"
yq "$ML | .spec.templates[] | select(.name == \"hera-enhance-commit\") | .container.args[0]" "$RENDERED" > "$ENH"
GUARD="${BASE_TMP}/guard.sh"
awk '/^if \[ "\$\{DATASET_RENDER:-false\}" = "true" \]; then$/ {on=1} on {print} on && /^fi$/ {exit}' "$ENH" > "$GUARD"
[ -s "$GUARD" ] || { FAILED=$((FAILED + 1)); echo "FAIL: the guard block was not extracted"; }
guard_case() { # $1 HEAD now, $2 last-built-sha in gitops, $3 DATASET_RENDER
  G=$(mktemp -d "${BASE_TMP}/guard-XXXX"); mkdir -p "$G/bin"
  printf 'data:\n  last-built-sha: %s\n' "$2" > "$G/images.yaml"
  printf '#!/bin/sh\n[ -n "%s" ] || exit 22\nprintf %s "{\\"sha\\":\\"%s\\"}"\n' "$1" '%s' "$1" > "$G/bin/curl"
  chmod +x "$G/bin/curl"
  OUT=$( { printf 'set -e\nIMAGES_FILE=%s\nTOKEN=t\nCOMMIT_SHA=%s\nDATASET_RENDER=%s\nAPP_REPO_URL=https://github.com/acme/proj-app1.git\nAPP_REF=refs/heads/dev\n' "$G/images.yaml" "$HEAD_SHA" "$3"; cat "$GUARD"; echo 'echo REACHED-COMMIT'; } > "$G/run.sh"; PATH="$G/bin:$PATH" sh "$G/run.sh" 2>&1); RC=$?
}
guard_case "$HEAD_SHA" "$HEAD_SHA" true
expect_eq "$RC" "0" "guard: HEAD and last-built are the commit: goes on to the commit"; expect_has "$OUT" "REACHED-COMMIT" "  (reaches the commit)"
guard_case bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$HEAD_SHA" true
case "$OUT" in *REACHED-COMMIT*) FAILED=$((FAILED + 1)); echo "FAIL: guard: a newer HEAD still pushed" ;; *) PASSED=$((PASSED + 1)); echo "PASS: guard: a newer HEAD pushes nothing" ;; esac
expect_has "$OUT" "skipped — acme/proj-app1 is at" "  (and says why)"
guard_case "$HEAD_SHA" cccccccccccccccccccccccccccccccccccccccc true
case "$OUT" in *REACHED-COMMIT*) FAILED=$((FAILED + 1)); echo "FAIL: guard: an unrecorded build still pushed" ;; *) PASSED=$((PASSED + 1)); echo "PASS: guard: a commit gitops does not record as built pushes nothing" ;; esac
guard_case "" "$HEAD_SHA" true
expect_eq "$RC" "1" "guard: HEAD unreadable fails the run, nothing pushed"
guard_case bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "$HEAD_SHA" false
expect_has "$OUT" "REACHED-COMMIT" "guard: any other run (dataset_render=false) is not affected"

echo "dataset-short-path: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
