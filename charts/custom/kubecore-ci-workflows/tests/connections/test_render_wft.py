import os

import pytest
import yaml

from harness import CONNECTIONS, EXPECTED_ENV_FROM, FIXTURES, golden_text, render

RW = [n for n, f in FIXTURES.items() if f.kind == "render-wft"]


@pytest.mark.parametrize("name", RW)
@pytest.mark.parametrize("conns", [None, []], ids=["absent", "empty"])
def test_render_wft_golden(name, conns):
    assert render(name, conns, rendered=os.environ["RENDERED"]) == golden_text("render-wft", name)


def _names(out):
    return {t["name"] for t in yaml.safe_load(out)["spec"]["templates"]}


def test_fixture_preconditions_render_wft():
    assert "hpc-burst" in _names(golden_text("render-wft", "kubeline-static-hpc"))
    live = yaml.safe_load(golden_text("render-wft", "kubeline-live-hpc"))["spec"]
    assert live["onExit"] == "destroy-nodegroups"
    assert {"create-nodegroups", "destroy-nodegroups", "validate-classes", "hpc-follower"} <= {
        t["name"] for t in live["templates"]}


PLATFORM_RW = {"create-nodegroups", "destroy-nodegroups", "validate-classes", "hpc-follower", "hpc-burst"}


def _tpls(name, conns=CONNECTIONS, ctx_override=None):
    out = render(name, conns, rendered=os.environ["RENDERED"], ctx_override=ctx_override)
    return yaml.safe_load(out)["spec"]["templates"]


def _user_names(name):  # kubeline steps[] -> expected user-step template names
    steps = [s["name"] for s in yaml.safe_load(open(FIXTURES[name].source))["steps"]]
    return set(steps) if name == "kubeline-live-hpc" else {f"{s}-{v}" for s in steps for v in ("cpu", "gpu")}


@pytest.mark.parametrize("name", RW)
def test_envfrom_optional_true(name):
    users = [t for t in _tpls(name) if t["name"] in _user_names(name)]
    assert users and len(users) == len(_user_names(name))
    for t in users:
        assert t["container"]["envFrom"] == EXPECTED_ENV_FROM


@pytest.mark.parametrize("name", RW)
def test_platform_templates_untouched(name):
    with_c = {t["name"]: t for t in _tpls(name)}
    without = {t["name"]: t for t in _tpls(name, None)}
    for n in set(with_c) - _user_names(name):
        assert with_c[n] == without[n], n  # DAG, nodegroups, validate, hpc-burst, hpc-follower
    assert set(with_c) - _user_names(name) <= PLATFORM_RW | {f"{FIXTURES[name].app}-pipeline"}


def test_hpc_twin_untouched_and_credential_free():
    t = {t["name"]: t for t in _tpls("kubeline-live-hpc")}["hpc-follower"]
    assert "envFrom" not in t["container"] and "script" not in t


def test_no_inpod_slurm_path_in_render_wft():
    """PRD-HPC-1461 AC-12/F-35: the kubeline renderer carries no Slurm submitter and mounts no
    meluxina-jwt Secret; the HPC twin only refuses (this renderer has no HPC controller support)."""
    text = golden_text("render-wft", "kubeline-live-hpc")
    assert "meluxina-run" not in text and "meluxina-jwt" not in text and "SLURM_TOKEN" not in text
    assert "slurm-api" not in text
    t = {t["name"]: t for t in _tpls("kubeline-live-hpc")}["hpc-follower"]
    assert t["container"]["args"] == ['echo "$HPC_NOT_SERVED" >&2; exit 1']
    assert not t["container"].get("volumeMounts") and not t.get("volumes")
    assert all("valueFrom" not in e for e in t["container"]["env"])


def test_env_filtering():
    users = _user_names("kubeline-static")
    with_env = [t for t in _tpls("kubeline-static") if t["name"] in users]
    assert with_env and all(t["container"]["envFrom"] == EXPECTED_ENV_FROM for t in with_env)

    def drop_env(ctx):
        ctx.pop("mlEnvironment")
        return ctx

    no_env = [t for t in _tpls("kubeline-static", ctx_override=drop_env) if t["name"] in users]
    assert no_env
    for t in no_env:
        assert t["container"]["envFrom"] == [{"configMapRef": {"name": "cm-features", "optional": True}}]


def test_entry_without_configmap_name_skipped():
    conns = [{"name": "x", "envPrefix": "X"}, {"name": "y", "envPrefix": "Y", "configMapName": ""}]
    for name in RW:
        tpls = _tpls(name, conns)
        assert tpls
        for t in tpls:
            assert "envFrom" not in t.get("container", {}), (name, t["name"])


def test_duplicate_configmap_name_emitted_once():
    conns = [{"name": "a", "envPrefix": "A", "configMapName": "cm-dup"},
             {"name": "b", "envPrefix": "B", "configMapName": "cm-dup"}]
    users = _user_names("kubeline-static")
    for t in _tpls("kubeline-static", conns):
        if t["name"] in users:
            assert t["container"]["envFrom"] == [{"configMapRef": {"name": "cm-dup", "optional": True}}]


@pytest.mark.parametrize("name", RW)
def test_envfrom_no_yaml_aliases(name):
    # Existing templates already carry shared objects (anchors/aliases) in today's
    # output, so the check is: envFrom adds none, and no alias sits on an envFrom.
    out = render(name, CONNECTIONS, rendered=os.environ["RENDERED"])
    base = golden_text("render-wft", name)
    assert out.count("&id") == base.count("&id")
    assert out.count("*id") == base.count("*id")
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if line.strip().startswith("envFrom:"):
            assert "&id" not in line and "*id" not in line, line
            assert "&id" not in lines[i + 1] and "*id" not in lines[i + 1], lines[i + 1]
    assert "envFrom:" in out


@pytest.mark.parametrize("env", ["", None], ids=["empty-string", "null"])
def test_empty_or_null_environment_counts_as_absent(env):
    # Parity with the Hera enhancer: an empty/null `environment` is "no environment", so the
    # entry applies to every ml environment (including a different one).
    conns = [{"name": "a", "envPrefix": "A", "configMapName": "cm-a", "environment": env}]

    def other_env(ctx):
        ctx["mlEnvironment"] = dict(ctx.get("mlEnvironment") or {}, name="some-other-env")
        return ctx

    users = _user_names("kubeline-static")
    for ov in (None, other_env):
        got = [t for t in _tpls("kubeline-static", conns, ctx_override=ov) if t["name"] in users]
        assert got
        for t in got:
            assert t["container"]["envFrom"] == [{"configMapRef": {"name": "cm-a", "optional": True}}]
