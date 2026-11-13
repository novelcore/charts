#!/usr/bin/env bash
# The cap on concurrent check-drift pods, and the cheap listings (dev e2e, PRD kaos#1911).
# Usage (from the repo root; needs helm, yq v4, jq):
#
#   bash charts/custom/kubecore-ci-workflows/tests/check-drift-cap/run.sh
#
# Why: ~20 check-drift pods of ml-ci-reconcile ran at once on the e2-standard-2 system nodes
# (a fan-out of ml-ci-dataset-rerender, one per app, plus the hourly polls). Each requested
# 208Mi and used 375-590Mi (it downloaded and parsed every finished workflow of the namespace),
# so the node starved. Two guards:
#   1. an Argo semaphore bounds how many check-drift pods run at once, cluster-wide; the rest
#      queue in Argo with no pod. Rendered here; the behaviour on a real controller is proven by
#      tests/check-drift-cap/kind/run.sh.
#   2. the lists are narrow: unfinished workflows only (server-side selector), the finished
#      attempts of one spec by label, the newest-run read in pages. The script is EXECUTED
#      against a stub kubectl that REFUSES an unselected whole-namespace list.
# Exit status = number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0; PASSED=0
expect_eq() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi; }
expect_has() { case "$1" in *"$2"*) PASSED=$((PASSED+1)); echo "PASS: $3";; *) FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  expected to contain: $2"; echo "  actual: $(printf '%s' "$1" | tail -5)";; esac; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/rendered.yaml"
helm template t "$CHART" --set github.org=acme --set github.tokenSecretName=tok > "$R" || { echo "FAIL: helm template"; exit 1; }
WF='select(.kind=="ClusterWorkflowTemplate" and .metadata.name=="ml-ci-reconcile") | .spec.templates[]'

# ── render: the semaphore ────────────────────────────────────────────────────
SEM=$(yq "$WF | select(.name==\"check-drift\") | .synchronization.semaphores[0]" "$R")
expect_eq "$(printf '%s' "$SEM" | yq '.configMapKeyRef.name')" "ci-check-drift-slots" "check-drift takes a semaphore from the chart's ConfigMap"
expect_eq "$(printf '%s' "$SEM" | yq '.configMapKeyRef.key')" "slots" "the semaphore reads the key slots"
CM_NS=$(yq 'select(.kind=="ConfigMap" and .metadata.name=="ci-check-drift-slots") | .metadata.namespace' "$R")
expect_eq "$(printf '%s' "$SEM" | yq '.namespace')" "$CM_NS" "the semaphore names the ConfigMap's namespace (one cluster-wide count, not one per project CI namespace)"
expect_eq "$(yq 'select(.kind=="ConfigMap" and .metadata.name=="ci-check-drift-slots") | .data.slots' "$R")" "3" "default cap is 3"
expect_eq "$(yq 'select(.kind=="ConfigMap" and .metadata.name=="ci-check-drift-slots") | .metadata.annotations["argocd.argoproj.io/sync-wave"]' "$R")" "-1" "the ConfigMap syncs before the templates that name it (a missing one makes the run end in Error)"
expect_eq "$(helm template t "$CHART" --set github.org=acme --set github.tokenSecretName=tok --set ci.checkDrift.slots=5 \
  | yq 'select(.kind=="ConfigMap" and .metadata.name=="ci-check-drift-slots") | .data.slots')" "5" "the cap is a chart value"
expect_eq "$(yq "$WF | select(.name==\"check-drift\") | .synchronization.mutexes" "$R")" "null" "check-drift takes no mutex of its own"
# One lock level only: decide-and-submit (mutex) must not also hold a slot while check-drift
# asks for one, or three of them would each wait for the slot another holds.
expect_eq "$(yq "$WF | select(.name==\"decide-and-submit\") | .synchronization.semaphores" "$R")" "null" "decide-and-submit holds no semaphore (no lock-order cycle with the app mutex)"
expect_eq "$(yq "$WF | select(.synchronization.semaphores != null) | .name" "$R" | tr '\n' ' ')" "check-drift " "check-drift is the only template of ml-ci-reconcile with a semaphore"
expect_eq "$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.synchronization' "$R")" "null" "no workflow-level lock (a queued run would hold a slot while waiting for a build)"
# A queued run must survive: no pod while it waits, the run's own deadline bounds it, and a killed pod still retries.
expect_eq "$(yq "$WF | select(.name==\"check-drift\") | .retryStrategy.expression" "$R")" "asInt(lastRetry.exitCode) == 3 || asInt(lastRetry.exitCode) == 137" "a forced event is still retried on exit 3 and 137"
expect_eq "$(yq 'select(.metadata.name=="ml-ci-reconcile") | .spec.activeDeadlineSeconds' "$R")" "10800" "the wait for a slot is bounded by the run's deadline"
# The reaper only reads Pods; a node waiting for a semaphore has none.
expect_eq "$(yq 'select(.metadata.name=="pending-reaper") | .spec.templates[].container.args[0]' "$R" | grep -c 'get pods -l')" "1" "the pending-reaper judges pods, not workflow nodes: a run waiting for a slot has no pod to kill"

# ── render: resources ────────────────────────────────────────────────────────
RES=$(yq "$WF | select(.name==\"check-drift\") | .container.resources" "$R")
expect_eq "$(printf '%s' "$RES" | yq '.limits')" "null" "check-drift has no memory limit (an OOMKill drops a forced re-render)"
expect_eq "$(printf '%s' "$RES" | yq '.requests.memory')" "96Mi" "check-drift requests what it uses with the narrow lists (measured peak 40-75 MiB)"

# ── the script: executed against a stub kubectl ──────────────────────────────
SRC="$T/check-drift.src"
yq "$WF | select(.name==\"check-drift\") | .container.args[0]" "$R" > "$SRC"
subst() { # script, sandbox dir -> sandbox script
  sed -e "s#{{workflow.namespace}}#ci#g" -e "s#{{inputs.parameters.mode}}#decide#g" \
      -e "s#{{workflow.parameters.force}}#false#g" -e "s#{{workflow.parameters.dataset_event}}#false#g" \
      -e "s#{{workflow.parameters.app_name}}#app1#g" -e "s#{{workflow.parameters.project_name}}#proj#g" \
      -e "s#{{workflow.parameters.branch}}#dev#g" -e "s#{{workflow.parameters.ci_namespace}}#ci#g" \
      -e "s#{{workflow.parameters.ml_namespace}}#ml-proj#g" -e "s#{{workflow.parameters.repo_url}}##g" \
      -e "s#/tmp/#$2/#g" -e "s#/etc/github-token/token#$2/token#g" "$1"
}
# A stub kubectl that behaves like the API server for the selectors the script may use and
# FAILS LOUDLY (exit 99, logged) on a whole-namespace workflow list: the incident's call.
mkstub() { # sandbox dir; fixture $1/wf.json = all workflows of the namespace
  cat > "$1/bin/kubectl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$1/calls.log"
case "\$*" in
  *"get workflows"*"-l workflows.argoproj.io/completed!=true"*)
    jq '{items: [.items[] | select((.metadata.labels // {})["workflows.argoproj.io/completed"] != "true")]}' "$1/wf.json" ;;
  *"get workflows"*"-l platform.kubecore.io/app="*)
    # label selector: app, submitted-by, kaos-lib
    SEL=\$(printf '%s' "\$*" | sed -E 's/.*-l ([^ ]+).*/\1/')
    jq --arg sel "\$SEL" '{items: [.items[] | select(. as \$w | (\$sel | split(",") | map(split("=")) | all(. as \$kv | ((\$w.metadata.labels // {})[\$kv[0]]) == \$kv[1])))]}' "$1/wf.json" ;;
  *"get workflows"*) echo "UNSELECTED WORKFLOW LIST: \$*" >> "$1/refused.log"; exit 99 ;;
  *"get --raw"*) page=\$(cat "$1/pages.n" 2>/dev/null || echo 0); echo \$((page+1)) > "$1/pages.n"; cat "$1/page-\$page.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/bin/kubectl"
}
fx() { # name phase completed app submittedBy ref [age_s]
  jq -n --arg n "$1" --arg p "$2" --arg c "$3" --arg a "$4" --arg s "$5" --arg r "$6" --argjson age "${7:-0}" \
    '{metadata: {name: $n, creationTimestamp: (now - $age | floor | todate),
        labels: ({"workflows.argoproj.io/completed": $c, "platform.kubecore.io/app": $a}
                 + (if $s != "" then {"platform.kubecore.io/submitted-by": $s} else {} end)
                 + (if $r != "" then {"platform.kubecore.io/kaos-lib": $r} else {} end))},
      spec: {arguments: {parameters: [{name: "app_name", value: $a}]}},
      status: ({phase: $p} + (if $c == "true" then {finishedAt: (now - $age | floor | todate)} else {} end))}'
}
# fn_of NAME: the shell function NAME from stdin (its closing brace is the first line that is just that indent + "}")
fn_of() { awk -v n="$1" '!f && $0 ~ "^ *" n "\\(\\) \\{$" { match($0, /^ */); ind = substr($0, 1, RLENGTH); f = 1 } f { print } f && $0 == ind "}" { exit }'; }
sandbox() { S=$(mktemp -d "$T/s-XXXX"); mkdir -p "$S/bin"; printf tok > "$S/token"; mkstub "$S"; }

# 1. the in-flight guard: unfinished builds are found with the selector, finished ones are never downloaded
sandbox
{ for i in 1 2 3 4 5 6; do fx "ml-ci-build-old$i" Succeeded true app1 "" ""; done
  fx ml-ci-build-running Running false app1 "" ""; } | jq -s '{items: .}' > "$S/wf.json"
subst "$SRC" "$S" > "$S/run.sh"
OUT=$(PATH="$S/bin:$PATH" bash "$S/run.sh" 2>&1); RC=$?
expect_eq "$RC" "0" "poll: exits cleanly with a build in flight"
expect_has "$OUT" "build already in flight (1 active ml-ci-build workflow(s) for app1)" "poll: the running build is found among 6 finished ones"
expect_eq "$(grep -c 'completed!=true' "$S/calls.log")" "1" "poll: the in-flight list is selected on completed!=true"
expect_eq "$(cat "$S/refused.log" 2>/dev/null | wc -l | tr -d ' ')" "0" "poll: no whole-namespace workflow list was attempted"
# a workflow the controller has not labelled yet still counts as unfinished
sandbox
fx ml-ci-build-fresh "" "" app1 "" "" | jq 'del(.metadata.labels["workflows.argoproj.io/completed"]) | del(.status.phase)' | jq -s '{items: .}' > "$S/wf.json"
subst "$SRC" "$S" > "$S/run.sh"
OUT=$(PATH="$S/bin:$PATH" bash "$S/run.sh" 2>&1)
expect_has "$OUT" "build already in flight (1 active" "poll: a just-created workflow (no completed label yet) is still seen as in flight"

# 2. kl_last_try (the hourly attempt guard) asks for the finished attempts of THIS app and spec by label
sandbox
REF=0123456789ab
{ fx ml-ci-build-try1 Failed true app1 ml-ci-reconcile "$REF" 600
  fx ml-ci-build-try2 Failed true app1 ml-ci-reconcile "ffffffffffff" 600
  fx ml-ci-build-try3 Failed true app2 ml-ci-reconcile "$REF" 600
  fx ml-ci-build-try4 Succeeded true app1 "" "$REF" 600; } | jq -s '{items: .}' > "$S/wf.json"
subst "$SRC" "$S" | fn_of kl_last_try > "$S/fn.sh"
OUT=$(PATH="$S/bin:$PATH" bash -c "APP=app1; . $S/fn.sh; kl_last_try $REF" 2>&1)
expect_has "$OUT" "ml-ci-build-try1 (Failed, " "kl_last_try: the recent finished attempt at this spec is found"
case "$OUT" in *try2*|*try3*|*try4*) FAILED=$((FAILED+1)); echo "FAIL: kl_last_try: another spec, app or submitter must not match ($OUT)";; *) PASSED=$((PASSED+1)); echo "PASS: kl_last_try: another spec, app or submitter does not match";; esac
expect_has "$(cat "$S/calls.log")" "-l platform.kubecore.io/app=app1,platform.kubecore.io/submitted-by=ml-ci-reconcile,platform.kubecore.io/kaos-lib=${REF}" "kl_last_try: the list is selected server-side"
expect_eq "$(cat "$S/refused.log" 2>/dev/null | wc -l | tr -d ' ')" "0" "kl_last_try: no whole-namespace list"

# 3. newest_ref_run reads the ML namespace in pages and keeps the newest match across them
sandbox
page() { # file continue-token items...
  f=$1; c=$2; shift 2; printf '%s\n' "$@" | jq -s --arg c "$c" '{metadata: (if $c == "" then {} else {continue: $c} end), items: .}' > "$f"; }
item() { jq -n --arg r "$1" --argjson age "$2" '{metadata: {creationTimestamp: (now - $age | floor | todate)}, spec: {workflowTemplateRef: {name: $r}}}'; }
page "$S/page-0.json" tok1 "$(item other-pipeline 10)" "$(item app1-pipeline 90000)"
page "$S/page-1.json" tok2 "$(item app1-pipeline 7200)" "$(item other-pipeline 20)"
page "$S/page-2.json" ""   "$(item app1-pipeline 50000)"
subst "$SRC" "$S" | fn_of newest_ref_run > "$S/fn.sh"
OUT=$(PATH="$S/bin:$PATH" bash -c "set -eu; ML_NS=ml-proj; APP=app1; . $S/fn.sh; newest_ref_run" 2>&1)
case "$OUT" in ''|*[!0-9]*) FAILED=$((FAILED+1)); echo "FAIL: newest_ref_run: not a number: $OUT";; *)
  if [ "$OUT" -ge 7200 ] && [ "$OUT" -le 7260 ]; then PASSED=$((PASSED+1)); echo "PASS: newest_ref_run: the newest match (7200s) across three pages ($OUT)"; else FAILED=$((FAILED+1)); echo "FAIL: newest_ref_run: expected ~7200, got $OUT"; fi;; esac
expect_eq "$(grep -c 'limit=10' "$S/calls.log")" "3" "newest_ref_run: three pages of 10, not the whole namespace"
expect_has "$(grep 'continue=tok2' "$S/calls.log")" "limit=10&continue=tok2" "newest_ref_run: follows the continue token"

echo "check-drift-cap: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
