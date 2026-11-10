"""Turn the rendered ml-ci-build into a runnable stand-in on a kind cluster.

Keeps EVERYTHING that decides ordering and locking (steps, whens, withParam, parallelism,
synchronization, inputs/outputs) and replaces only what a template DOES: every container,
script and resource template becomes a stub that writes its declared outputs (has_changes from
the workflow parameter stub_has_changes) and sleeps; build-push sleeps build_seconds.
Usage: stub.py RENDERED.yaml > ml-ci-build.stub.yaml
"""
import json
import sys

import yaml

STEPS = json.dumps([{"name": f"s{i}", "path": f"steps/s{i}"} for i in range(1, 4)])
OUTPUT_VALUES = {
    "has_changes": "{{workflow.parameters.stub_has_changes}}",
    "changed_steps": STEPS,
    "wft_changed": "false",
    "frontend": "hera",
}


def stub_script(tmpl):
    lines = ["set -e", "echo \"stub:" + tmpl["name"] + " start $(date +%s)\""]
    for p in (tmpl.get("outputs") or {}).get("parameters") or []:
        path = (p.get("valueFrom") or {}).get("path")
        if path:
            value = OUTPUT_VALUES.get(p["name"], "x")
            lines.append(f"mkdir -p $(dirname {path}); printf '%s' '{value}' > {path}")
    if tmpl["name"] == "build-push":
        lines.append("sleep {{workflow.parameters.build_seconds}}")
    else:
        lines.append("sleep 1")
    lines.append("echo \"stub:" + tmpl["name"] + " end $(date +%s)\"")
    return "\n".join(lines)


docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cwt = next(d for d in docs if d["kind"] == "ClusterWorkflowTemplate" and d["metadata"]["name"] == "ml-ci-build")
spec = cwt["spec"]
for k in ("nodeSelector", "tolerations", "onExit", "volumes", "serviceAccountName"):
    spec.pop(k, None)
spec["arguments"]["parameters"].append({"name": "stub_has_changes", "value": "true"})
spec["arguments"]["parameters"].append({"name": "build_seconds", "value": "20"})
for t in spec["templates"]:
    if not any(k in t for k in ("container", "script", "resource")):
        continue
    for k in ("container", "script", "resource", "podSpecPatch", "initContainers", "volumes", "nodeSelector",
              "tolerations", "retryStrategy", "serviceAccountName", "automountServiceAccountToken", "securityContext", "executor"):
        t.pop(k, None)
    t["container"] = {"image": "alpine:3.20", "command": ["sh", "-c"], "args": [stub_script(t)]}
yaml.safe_dump(cwt, sys.stdout)
