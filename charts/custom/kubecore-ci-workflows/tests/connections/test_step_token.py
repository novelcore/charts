"""The step's kaos-lake token (kaos PRD 1217 F-05): the pipeline renderer projects an
audience-bound service-account token into every step that runs as the app's own account,
only when the pipeline context carries workloadIdentity.audience.

It is the platformEnhance post-pass of the rendered `hera-enhance-commit` step, applied to
the committed enhancer goldens (the enhancer itself needs the network and is covered by
test_hera_enhancer.py).
"""
import os
import subprocess
import sys
import tempfile

import pytest
import yaml

from harness import FIXTURES, GOLDEN, golden_text

HERA = [n for n, f in FIXTURES.items() if f.kind == "hera"]
AUDIENCE = "kaos-lake"
APP_SA = "app-workflow"


def _with_token(ctx):
    ctx["workloadIdentity"] = {"audience": AUDIENCE}
    ctx["serviceAccountName"] = APP_SA
    return ctx


def _with_audience(ctx):
    ctx["workloadIdentity"] = {"audience": AUDIENCE}
    return ctx


def _golden_path(kind, name):
    return os.path.join(GOLDEN, kind, f"{name}.yaml")


def _post_pass_script():
    """The python of the platformEnhance post-pass in the rendered hera-enhance-commit step."""
    with open(os.environ["RENDERED"]) as f:
        docs = [d for d in yaml.safe_load_all(f) if d]
    for d in docs:
        if d.get("kind") != "ClusterWorkflowTemplate" or d["metadata"]["name"] != "ml-ci-build":
            continue
        for t in d["spec"]["templates"]:
            if t["name"] != "hera-enhance-commit":
                continue
            lines = t["container"]["args"][0].split("\n")
            start = next(i for i, ln in enumerate(lines) if ln.rstrip().endswith("<<'STEPTOKEOF'"))
            end = next(i for i in range(start + 1, len(lines)) if lines[i] == "STEPTOKEOF")
            return "\n".join(lines[start + 1:end]) + "\n"
    raise RuntimeError("ml-ci-build/hera-enhance-commit not found")


def _run_post_pass(wft_text, ctx):
    with tempfile.TemporaryDirectory() as td:
        script, wft, cx = (os.path.join(td, n) for n in ("pass.py", "wft.yaml", "ctx.yaml"))
        open(script, "w").write(_post_pass_script())
        open(wft, "w").write(wft_text)
        yaml.safe_dump(ctx, open(cx, "w"))
        subprocess.run([sys.executable, script, wft, cx], check=True)
        return open(wft).read()


def _steps(wft, account):
    spec = wft["spec"]
    return [t for t in spec["templates"]
            if "container" in t and (t.get("serviceAccountName") or spec.get("serviceAccountName")) == account]


def _assert_token(t):
    assert {"name": "kaos-lake-token", "projected": {"sources": [
        {"serviceAccountToken": {"audience": AUDIENCE, "expirationSeconds": 3600, "path": "token"}}]}} in t["volumes"]
    assert {"name": "kaos-lake-token", "mountPath": "/var/run/secrets/kaos-lake", "readOnly": True} \
        in t["container"]["volumeMounts"]
    assert {"name": "KAOS_LAKE_TOKEN_FILE", "value": "/var/run/secrets/kaos-lake/token"} in t["container"]["env"]


@pytest.mark.parametrize("name", HERA)
def test_hera_post_pass_token_golden(name):
    ctx = _with_audience(yaml.safe_load(open(FIXTURES[name].context)))
    out = _run_post_pass(golden_text("hera", name), ctx)
    with open(_golden_path("hera-step-token", name)) as f:
        assert out == f.read()
    steps = _steps(yaml.safe_load(out), ctx["serviceAccountName"])
    assert steps, "no step runs as the app's account"
    for t in steps:
        _assert_token(t)


@pytest.mark.parametrize("name", HERA)
def test_hera_post_pass_without_audience_is_a_no_op(name):
    ctx = yaml.safe_load(open(FIXTURES[name].context))
    assert "workloadIdentity" not in ctx
    assert _run_post_pass(golden_text("hera", name), ctx) == golden_text("hera", name)
