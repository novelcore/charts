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
    assert {"create-nodegroups", "destroy-nodegroups", "validate-classes", "meluxina-run"} <= {
        t["name"] for t in live["templates"]}


PLATFORM_RW = {"create-nodegroups", "destroy-nodegroups", "validate-classes", "meluxina-run", "hpc-burst"}


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
        assert with_c[n] == without[n], n  # DAG, nodegroups, validate, hpc-burst, meluxina-run
    assert set(with_c) - _user_names(name) <= PLATFORM_RW | {f"{FIXTURES[name].app}-pipeline"}


def test_meluxina_twin_untouched():
    t = {t["name"]: t for t in _tpls("kubeline-live-hpc")}["meluxina-run"]
    assert "envFrom" not in t.get("script", {}) and "container" not in t


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
