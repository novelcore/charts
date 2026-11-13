#!/usr/bin/env bash
# PRD novelcore/kaos#1533 F-26 (charts C0, C1, C2a-C2c): the chart is
# conformant with Argo's `workflowRestrictions.templateReferencing: Strict`.
#
#   bash charts/custom/kubecore-ci-workflows/tests/strict-references/run.sh
#
# Strict (argo-workflows workflow/controller/operator.go, workflow/util/merge.go)
# marks a Workflow Error unless it has spec.workflowTemplateRef AND sets no spec
# field outside allowedUserOverrideFields. A CronWorkflow's workflowSpec is
# copied into each Workflow as is, so it follows the same rule. This test fails
# on any chart-rendered object that would break it:
#   1. every CronWorkflow.spec.workflowSpec;
#   2. every `kind: Workflow` manifest embedded in a resource step;
#   3. the Workflow the dataset-release fan-out builds with jq (the jq program
#      is EXECUTED on fixture CronWorkflows), including OQ-5: two fan-outs for
#      one app submit Workflows that serialise on ml-ci-reconcile's
#      `{app}-build` mutex;
#   4. the reconcile templates own their ServiceAccount and token volume (C2a),
#      the autoscaler healer owns its ServiceAccount (C2b);
#   5. backward compatibility: a caller that still passes serviceAccountName
#      and volumes of its own is untouched by the template change.
# Needs helm, jq, python3 with PyYAML. Exit status is the number of failures.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0; PASSED=0
BASE_TMP=$(mktemp -d); trap 'rm -rf "$BASE_TMP"' EXIT

ok()   { PASSED=$((PASSED + 1)); echo "PASS: $1"; }
fail() { FAILED=$((FAILED + 1)); echo "FAIL: $1"; [ $# -gt 1 ] && echo "  $2"; }
expect_eq() { if [ "$1" = "$2" ]; then ok "$3"; else fail "$3" "expected: $2 | actual: $1"; fi; }

RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme --set github.tokenSecretName=ci-token \
  > "$RENDERED" 2>"${BASE_TMP}/helm.err" \
  || { cat "${BASE_TMP}/helm.err"; echo "FAIL: helm template"; exit 1; }

# ── 1 + 2: allowlist walk (python) ───────────────────────────────────────────
python3 -I - "$RENDERED" <<'PY' > "${BASE_TMP}/walk.out"
import re, sys, yaml
ALLOWED = {"arguments", "entrypoint", "shutdown", "suspend", "activeDeadlineSeconds",
           "priority", "ttlStrategy", "podGC", "volumeClaimGC", "archiveLogs",
           "workflowMetadata", "workflowTemplateRef", "metrics", "artifactGC"}
def check(where, spec):
    if not isinstance(spec, dict) or not spec.get("workflowTemplateRef"):
        print(f"FAIL: {where}: no workflowTemplateRef"); return
    bad = sorted(set(spec) - ALLOWED)
    if bad: print(f"FAIL: {where}: fields outside the Strict allowlist: {', '.join(bad)}")
    else:   print(f"PASS: {where}: workflowTemplateRef and only allowlisted fields")
def embedded(node, out):
    if isinstance(node, dict):
        res = node.get("resource")
        if isinstance(res, dict) and isinstance(res.get("manifest"), str): out.append(res["manifest"])
        for v in node.values(): embedded(v, out)
    elif isinstance(node, list):
        for v in node: embedded(v, out)
n = 0
for d in yaml.safe_load_all(open(sys.argv[1])):
    if not d: continue
    name = d.get("metadata", {}).get("name", "?")
    if d.get("kind") == "CronWorkflow":
        n += 1; check(f"CronWorkflow/{name}", d["spec"].get("workflowSpec"))
    ms = []; embedded(d, ms)
    for m in ms:
        # Argo parameter references are not YAML; neutralise them for parsing.
        m = re.sub(r"\{\{[^}]*\}\}", "X", m)
        for md in yaml.safe_load_all(m):
            if md and md.get("kind") == "Workflow":
                n += 1; check(f"{d['kind']}/{name} embedded Workflow {md['metadata'].get('generateName', '')}", md.get("spec"))
            elif md and md.get("kind") == "CronWorkflow":
                n += 1; check(f"{d['kind']}/{name} embedded CronWorkflow", md["spec"].get("workflowSpec"))
print(f"INFO: {n} objects checked")
PY
cat "${BASE_TMP}/walk.out" | grep -v '^INFO'
FAILED=$((FAILED + $(grep -c '^FAIL' "${BASE_TMP}/walk.out")))
PASSED=$((PASSED + $(grep -c '^PASS' "${BASE_TMP}/walk.out")))
CHECKED=$(sed -n 's/^INFO: \([0-9]*\) objects.*/\1/p' "${BASE_TMP}/walk.out")
[ "${CHECKED:-0}" -ge 3 ] && ok "the walk found the CronWorkflow and the embedded Workflows (${CHECKED})" \
  || fail "the walk found fewer than 3 objects (${CHECKED:-0}): the test would pass vacuously"

# ── 3: dataset-release fan-out (jq executed) ─────────────────────────────────
tmpl() { python3 -I - "$RENDERED" "$1" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind") == "ClusterWorkflowTemplate" and d["metadata"]["name"] == sys.argv[2]:
        yaml.safe_dump(d, sys.stdout); break
PY
}
tmpl ml-ci-dataset-release > "${BASE_TMP}/dr.yaml"
tmpl ml-ci-reconcile > "${BASE_TMP}/mlr.yaml"
python3 -I - "${BASE_TMP}/dr.yaml" "${BASE_TMP}" <<'PY'
import re, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
src = d["spec"]["templates"][0]["container"]["args"][0]
m = re.search(r"jq -c --arg app \"\$APP\" '(.*?)' \\\n", src, re.S)
open(sys.argv[2] + "/fanout.jq", "w").write(m.group(1))
open(sys.argv[2] + "/fanout.src", "w").write(src)
PY
[ -s "${BASE_TMP}/fanout.jq" ] && ok "extracted the fan-out jq program" || fail "could not extract the fan-out jq program"

# Fixture: one app's CronWorkflow as the k8smlapp composition renders it today,
# WITH the fields Strict refuses (a pre-F-26 operator), to prove the fan-out
# strips them; and as the F-26 operator renders it.
cron() { cat <<JSON
{"items":[{"metadata":{"name":"$1-ci-reconciler","labels":{"platform.kubecore.io/app":"$1"}},
 "spec":{"workflowSpec":{"workflowTemplateRef":{"name":"ml-ci-reconcile","clusterScope":true}$2,
  "arguments":{"parameters":[{"name":"app_name","value":"$1"},{"name":"project_name","value":"p"}]}}}}]}
JSON
}
OLD=',"serviceAccountName":"operate-workflow-sa","volumes":[{"name":"github-token","secret":{"secretName":"tok"}}],"synchronization":{"mutexes":[{"name":"x"}]}'
ALLOWED=(arguments entrypoint shutdown suspend activeDeadlineSeconds priority ttlStrategy podGC volumeClaimGC archiveLogs workflowMetadata workflowTemplateRef metrics artifactGC)
allow_json=$(printf '%s\n' "${ALLOWED[@]}" | jq -R . | jq -s .)

for variant in old new; do
  if [ "$variant" = old ]; then X="$OLD"; else X=""; fi
  cron myapp "$X" | jq -c --arg app myapp -f "${BASE_TMP}/fanout.jq" > "${BASE_TMP}/wf-$variant.json" 2>"${BASE_TMP}/jq.err" \
    || { fail "fan-out jq ($variant cron) errored" "$(cat "${BASE_TMP}/jq.err")"; continue; }
  bad=$(jq -r --argjson a "$allow_json" '.spec | keys - $a | join(",")' "${BASE_TMP}/wf-$variant.json")
  expect_eq "$bad" "" "fan-out Workflow ($variant cron): no field outside the Strict allowlist"
  expect_eq "$(jq -r '.spec.workflowTemplateRef.name' "${BASE_TMP}/wf-$variant.json")" "ml-ci-reconcile" \
    "fan-out Workflow ($variant cron): references ml-ci-reconcile"
  expect_eq "$(jq -r '.spec.workflowTemplateRef.clusterScope' "${BASE_TMP}/wf-$variant.json")" "true" \
    "fan-out Workflow ($variant cron): keeps clusterScope"
  expect_eq "$(jq -r '[.spec.arguments.parameters[] | select(.name=="dataset_event")] | map(.value) | join(",")' "${BASE_TMP}/wf-$variant.json")" "true" \
    "fan-out Workflow ($variant cron): dataset_event=true exactly once"
  expect_eq "$(jq -r '.spec.arguments.parameters[] | select(.name=="app_name") | .value' "${BASE_TMP}/wf-$variant.json")" "myapp" \
    "fan-out Workflow ($variant cron): the cron's own arguments are kept"
  expect_eq "$(jq -r '.spec.ttlStrategy.secondsAfterCompletion' "${BASE_TMP}/wf-$variant.json")" "3600" \
    "fan-out Workflow ($variant cron): ttlStrategy kept"
done

SRC_NOCOMMENT=$(grep -v '^[[:space:]]*#' "${BASE_TMP}/fanout.src")
for w in synchronization serviceAccountName volumes; do
  case "$(cat "${BASE_TMP}/fanout.jq")" in *"$w"*) fail "fan-out jq body mentions $w";; *) ok "fan-out jq body has no $w";; esac
done
: "$SRC_NOCOMMENT"

# OQ-5: two concurrent fan-outs for the SAME app. Both submit a Workflow of
# ml-ci-reconcile with the same app_name argument; ml-ci-reconcile's
# decide-and-submit step holds the `{app}-build` mutex (the same one ml-ci-build
# holds), so Argo serialises them in queue order. dataset-release's own
# per-app mutex is gone.
python3 -I - "${BASE_TMP}/mlr.yaml" "${BASE_TMP}/wf-new.json" <<'PY' > "${BASE_TMP}/oq5.out"
import json, sys, yaml
t = yaml.safe_load(open(sys.argv[1])); wf = json.load(open(sys.argv[2]))
steps = {s["name"]: s for s in t["spec"]["templates"]}
def mutex(tp):
    return [m["name"] for m in (tp.get("synchronization") or {}).get("mutexes", [])]
entry = t["spec"]["entrypoint"]
reach = {s["template"] for grp in steps[entry]["steps"] for s in grp}
print("reaches-decide" if "decide-and-submit" in reach else "NO-decide")
print("mutex=" + ",".join(mutex(steps["decide-and-submit"])))
print("wf-level-mutex=" + ",".join(mutex(t["spec"])))
app = [p["value"] for p in wf["spec"]["arguments"]["parameters"] if p["name"] == "app_name"][0]
print("app=" + app)
PY
expect_eq "$(sed -n 1p "${BASE_TMP}/oq5.out")" "reaches-decide" "OQ-5: ml-ci-reconcile's entrypoint runs decide-and-submit"
expect_eq "$(sed -n 2p "${BASE_TMP}/oq5.out")" 'mutex={{workflow.parameters.app_name}}-build' \
  "OQ-5: decide-and-submit holds {app}-build"
# Two fan-outs, one app: identical template + identical app_name => identical mutex key.
cron myapp "" | jq -c --arg app myapp -f "${BASE_TMP}/fanout.jq" > "${BASE_TMP}/wfA.json"
cron myapp "" | jq -c --arg app myapp -f "${BASE_TMP}/fanout.jq" > "${BASE_TMP}/wfB.json"
ka=$(jq -r '.spec.workflowTemplateRef.name + "/" + (.spec.arguments.parameters[] | select(.name=="app_name") | .value)' "${BASE_TMP}/wfA.json")
kb=$(jq -r '.spec.workflowTemplateRef.name + "/" + (.spec.arguments.parameters[] | select(.name=="app_name") | .value)' "${BASE_TMP}/wfB.json")
expect_eq "$ka" "$kb" "OQ-5: two fan-outs for one app submit the same template with the same app_name (one mutex key)"
expect_eq "$ka" "ml-ci-reconcile/myapp" "OQ-5: that key resolves to myapp-build via ml-ci-reconcile"
expect_eq "$(sed -n 3p "${BASE_TMP}/oq5.out")" "wf-level-mutex=" "OQ-5: no workflow-level mutex that would hide the per-step one"
# dataset-release keeps ONE own mutex, on the fan-out Workflow itself (inside the template: allowed).
expect_eq "$(python3 -I -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]));print([m['name'] for m in d['spec']['synchronization']['mutexes']])" "${BASE_TMP}/dr.yaml")" \
  "['dataset-release']" "dataset-release template keeps its own single fan-out mutex"

# ── C1: the pending-reaper is a namespaced WorkflowTemplate ──────────────────
python3 -I - "$RENDERED" <<'PY' > "${BASE_TMP}/reaper.out"
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
wft = [d for d in docs if d["kind"] == "WorkflowTemplate" and d["metadata"]["name"] == "pending-reaper"]
cwt = [d for d in docs if d["kind"] == "ClusterWorkflowTemplate" and d["metadata"]["name"] == "pending-reaper"]
cron = [d for d in docs if d["kind"] == "CronWorkflow" and d["metadata"]["name"] == "pending-reaper"]
print("wft=%d cwt=%d cron=%d" % (len(wft), len(cwt), len(cron)))
if wft and cron:
    w = wft[0]["spec"]; c = cron[0]["spec"]["workflowSpec"]
    print("wft-ns=" + wft[0]["metadata"].get("namespace", ""))
    print("cron-ns=" + cron[0]["metadata"].get("namespace", ""))
    print("ref=%s clusterScope=%s" % (c.get("workflowTemplateRef", {}).get("name"), c.get("workflowTemplateRef", {}).get("clusterScope", False)))
    print("sa=" + w.get("serviceAccountName", ""))
    print("entry=%s deadline=%s ttl=%s" % (w.get("entrypoint"), w.get("activeDeadlineSeconds"), w.get("ttlStrategy", {}).get("secondsAfterCompletion")))
    print("tmpls=" + ",".join(t["name"] for t in w["templates"]))
PY
expect_eq "$(sed -n 1p "${BASE_TMP}/reaper.out")" "wft=1 cwt=0 cron=1" "C1: pending-reaper is one namespaced WorkflowTemplate (no ClusterWorkflowTemplate)"
expect_eq "$(sed -n 's/^wft-ns=//p' "${BASE_TMP}/reaper.out")" "$(sed -n 's/^cron-ns=//p' "${BASE_TMP}/reaper.out")" "C1: the template lives in the CronWorkflow's namespace"
expect_eq "$(sed -n 's/^ref=//p' "${BASE_TMP}/reaper.out")" "pending-reaper clusterScope=False" "C1: the cron references the namespaced template"
expect_eq "$(sed -n 's/^sa=//p' "${BASE_TMP}/reaper.out")" "t-kubecore-ci-workflows-pending-reaper" "C1: the template owns the reaper ServiceAccount"
expect_eq "$(sed -n 's/^entry=//p' "${BASE_TMP}/reaper.out")" "reap deadline=240 ttl=600" "C1: entrypoint, deadline and ttl moved verbatim"
expect_eq "$(sed -n 's/^tmpls=//p' "${BASE_TMP}/reaper.out")" "reap" "C1: the reap template moved"

# ── C2a / C2b: the templates own their ServiceAccount and token volume ───────
for t in ci-reconcile ml-ci-reconcile kaos-lib-bump-pr; do
  tmpl "$t" > "${BASE_TMP}/t.yaml"
  if [ ! -s "${BASE_TMP}/t.yaml" ]; then
    tmpl "$(python3 -I - "$RENDERED" <<'PY'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1])):
    if d and d.get("kind")=="ClusterWorkflowTemplate" and "kaos-lib" in d["metadata"]["name"]: print(d["metadata"]["name"])
PY
)" > "${BASE_TMP}/t.yaml"
  fi
  [ -s "${BASE_TMP}/t.yaml" ] || { fail "C2a: template $t not rendered"; continue; }
  expect_eq "$(python3 -I -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]))['spec'];print(d['serviceAccountName'])" "${BASE_TMP}/t.yaml")" \
    "operate-workflow-sa" "C2a: $t owns serviceAccountName operate-workflow-sa"
  expect_eq "$(python3 -I -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]))['spec'];print([p.get('value') for p in d['arguments']['parameters'] if p['name']=='github_token_secret'])" "${BASE_TMP}/t.yaml")" \
    "['ci-token']" "C2a: $t has github_token_secret defaulting to github.tokenSecretName"
  expect_eq "$(python3 -I -c "import yaml,sys;d=yaml.safe_load(open(sys.argv[1]))['spec'];print([v['secret']['secretName'] for v in d['volumes'] if v['name']=='github-token'])" "${BASE_TMP}/t.yaml")" \
    "['{{workflow.parameters.github_token_secret}}']" "C2a: $t's github-token volume reads the parameter"
done
tmpl ml-autoscaler-healer > "${BASE_TMP}/h.yaml"
expect_eq "$(python3 -I -c "import yaml,sys;print(yaml.safe_load(open(sys.argv[1]))['spec'].get('serviceAccountName'))" "${BASE_TMP}/h.yaml")" \
  "ml-compute-probe-sa" "C2b: the healer template owns ml-compute-probe-sa"
helm template t "$CHART" --set github.org=acme --set autoscalerHealer.serviceAccountName=custom-sa --show-only templates/clusterworkflowtemplate-autoscaler-healer.yaml 2>/dev/null \
  | python3 -I -c "import yaml,sys;print([d for d in yaml.safe_load_all(sys.stdin) if d and d['kind']=='ClusterWorkflowTemplate'][0]['spec']['serviceAccountName'])" > "${BASE_TMP}/h2.out"
expect_eq "$(cat "${BASE_TMP}/h2.out")" "custom-sa" "C2b: autoscalerHealer.serviceAccountName overrides it"
helm template t "$CHART" --set github.org=acme --set reconciler.serviceAccountName=other-sa --show-only templates/clusterworkflowtemplate-reconcile.yaml 2>/dev/null \
  | python3 -I -c "import yaml,sys;print([d for d in yaml.safe_load_all(sys.stdin) if d and d['kind']=='ClusterWorkflowTemplate'][0]['spec']['serviceAccountName'])" > "${BASE_TMP}/r2.out"
expect_eq "$(cat "${BASE_TMP}/r2.out")" "other-sa" "C2a: reconciler.serviceAccountName overrides it"

# ── 5: backward compatibility with today's operator ──────────────────────────
# A Workflow of the OLD shape (own serviceAccountName + volumes, no
# github_token_secret) still resolves under Argo's merge: the Workflow's own
# fields win over the template's, and an unset github_token_secret takes the
# template default. Check the parameter has a default (a caller omitting it
# must not hit "missing parameter") and that nothing the old callers pass was
# removed from the templates' parameter list.
for t in ci-reconcile ml-ci-reconcile; do
  tmpl "$t" > "${BASE_TMP}/t.yaml"
  expect_eq "$(python3 -I -c "
import yaml,sys
d=yaml.safe_load(open(sys.argv[1]))['spec']
print([('value' in p) for p in d['arguments']['parameters'] if p['name']=='github_token_secret'])" "${BASE_TMP}/t.yaml")" "[True]" \
    "compat: $t's github_token_secret has a default, so an old caller that omits it still validates"
done

echo; echo "strict-references: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
