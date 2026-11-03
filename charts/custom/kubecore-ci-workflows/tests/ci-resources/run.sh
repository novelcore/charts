#!/bin/sh
# Resource policy for EVERY container the chart runs (platform decision
# 2026-11-03: "give it what it wants, don't care about cpu limits, only
# requests"):
#   - no container has a CPU limit (CPU is requested, never capped);
#   - every container requests cpu and memory;
#   - a memory limit, where set, is at least 1.25x the memory request (except the
#     ML kaniko build-push, bounded by the node);
#   - the ML build-push (kaniko) request fits an e2-standard-4 CI node, the
#     smallest pool CI class (3920m cpu / ~12.2 GiB left after GKE daemonsets)
#     together with a render, a reconciler and a status step.
# The step images render-wft writes into an ML app's pipeline are checked for
# "no cpu limit" only where they come from the tooling values (gcloud steps).
# Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/ci-resources/run.sh /tmp/rendered.yaml
#
# Needs yq v4 and python3 on PATH. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
FAILED=0
PASSED=0
ok() { PASSED=$((PASSED + 1)); echo "PASS: $1"; }
ko() { FAILED=$((FAILED + 1)); echo "FAIL: $1"; }

# owner/template/container <TAB> cpu req <TAB> mem req <TAB> cpu lim <TAB> mem lim
LIST=$(yq -r '
  select(.kind == "ClusterWorkflowTemplate" or .kind == "WorkflowTemplate" or .kind == "CronWorkflow")
  | .metadata.name as $o
  | (.spec.templates // .spec.workflowSpec.templates)[]
  | .name as $t
  | ( [(.container // .script) | select(. != null) | . * {"name": "main"}]
      + (.initContainers // []) )[]
  | [($o + "/" + $t + "/" + .name),
     (.resources.requests.cpu // "" | tostring), (.resources.requests.memory // "" | tostring),
     (.resources.limits.cpu // "" | tostring), (.resources.limits.memory // "" | tostring)]
  | @tsv' "$RENDERED" | grep -v '^---$' | grep .)

N=$(printf '%s\n' "$LIST" | grep -c .)
[ "$N" -ge 35 ] && ok "found $N containers to check" || ko "found only $N containers (expected >= 35)"

RESULT=$(printf '%s\n' "$LIST" | python3 -I -c '
import sys
def mem(q):
    u={"Ki":2**10,"Mi":2**20,"Gi":2**30}
    for k,v in u.items():
        if q.endswith(k): return float(q[:-2])*v
    return float(q)
def cpu(q):
    return float(q[:-1])/1000 if q.endswith("m") else float(q)
for line in sys.stdin:
    n,cr,mr,cl,ml=(line.rstrip("\n").split("\t")+[""]*5)[:5]
    if not cr or not mr: print("FAIL: %s requests cpu and memory (cpu=%r memory=%r)"%(n,cr,mr)); continue
    if cl: print("FAIL: %s has a cpu limit (%s)"%(n,cl)); continue
    # The ML kaniko build-push is the one exception: 1.25x its 11Gi request would
    # exceed what an e2-standard-4 can give (see values.yaml kaniko.resources).
    if ml and n != "ml-ci-build/build-push/main" and mem(ml) < 1.25*mem(mr): print("FAIL: %s memory limit %s is below 1.25x its request %s"%(n,ml,mr)); continue
    print("PASS: %s requests cpu %s memory %s, no cpu limit%s"%(n,cr,mr,", memory limit "+ml if ml else ""))
')
printf '%s\n' "$RESULT"
FAILED=$((FAILED + $(printf '%s\n' "$RESULT" | grep -c '^FAIL')))
PASSED=$((PASSED + $(printf '%s\n' "$RESULT" | grep -c '^PASS')))

# Fit: the smallest CI node class (e2-standard-4) must hold an ML build-push,
# a render, a reconciler and a status step together.
FIT=$(printf '%s\n' "$LIST" | python3 -I -c '
import sys
def mem(q):
    for k,v in {"Mi":2**20,"Gi":2**30}.items():
        if q.endswith(k): return float(q[:-2])*v
    return float(q)
def cpu(q): return float(q[:-1])/1000 if q.endswith("m") else float(q)
r={}
for line in sys.stdin:
    n,cr,mr=line.split("\t")[:3]; r[n]=(cpu(cr),mem(mr))
want=["ml-ci-build/build-push/main","ml-ci-build/hera-render/main","ml-ci-reconcile/check-drift/main","ml-ci-build/status/main","ml-ci-pr-render/hera-enhance-gate/main"]
tot_c=sum(r[w][0] for w in want); tot_m=sum(r[w][1] for w in want)
# e2-standard-4: 3920m cpu, 13591656Ki memory allocatable, minus ~460m / ~0.7GiB of GKE daemonsets
free_c=3.920-0.460; free_m=13591656*1024-0.7*2**30
print("cpu %.2f of %.2f, memory %.2f of %.2f GiB"%(tot_c,free_c,tot_m/2**30,free_m/2**30))
sys.exit(0 if tot_c<=free_c and tot_m<=free_m else 1)
')
if [ $? -eq 0 ]; then ok "build + render + reconciler + status + enhance-gate fit an e2-standard-4 CI node ($FIT)"
else ko "build + render + reconciler + status + enhance-gate fit an e2-standard-4 CI node ($FIT)"; fi

echo "$PASSED passed, $FAILED failed"
exit "$FAILED"
