import pytest
import yaml

from harness import CONNECTIONS, EXPECTED_ENV_FROM, FIXTURES, golden_text, pinned_ref, raw_container_names, render

HERA = [n for n, f in FIXTURES.items() if f.kind == "hera"]


@pytest.mark.parametrize("name", HERA)
@pytest.mark.parametrize("conns", [None, []], ids=["absent", "empty"])
def test_hera_golden(name, conns):
    assert render(name, conns, ref=pinned_ref()) == golden_text("hera", name)


def _names(out):
    return {t["name"] for t in yaml.safe_load(out)["spec"]["templates"]}


def test_fixture_preconditions_hera():
    for n in ("yolo-vision-pipeline", "yolo-meluxina-poc", "demo"):
        assert "meluxina-run" in _names(golden_text("hera", n)), n
    for n in ("yolo-pipeline", "data-clean", "dataset-gen-service"):
        assert "meluxina-run" not in _names(golden_text("hera", n)), n


@pytest.mark.parametrize("name", HERA)
def test_envfrom_optional_true(name):
    out = yaml.safe_load(render(name, CONNECTIONS, ref=pinned_ref()))
    users = [t for t in out["spec"]["templates"] if t["name"] in raw_container_names(name)]
    assert users and all(t["container"].get("envFrom") == EXPECTED_ENV_FROM for t in users)


@pytest.mark.parametrize("name", ["yolo-vision-pipeline", "yolo-meluxina-poc"])
def test_meluxina_twin_untouched(name):
    a = yaml.safe_load(render(name, CONNECTIONS, ref=pinned_ref()))
    b = yaml.safe_load(render(name, None, ref=pinned_ref()))
    pick = lambda w, n: next(t for t in w["spec"]["templates"] if t["name"] == n)
    assert pick(a, "meluxina-run") == pick(b, "meluxina-run")
    assert "envFrom" not in pick(a, "meluxina-run")["container"]


@pytest.mark.parametrize("name", HERA)
def test_platform_templates_untouched(name):
    a = yaml.safe_load(render(name, CONNECTIONS, ref=pinned_ref()))
    b = yaml.safe_load(render(name, None, ref=pinned_ref()))
    user = raw_container_names(name)
    ta = {t["name"]: t for t in a["spec"]["templates"]}
    tb = {t["name"]: t for t in b["spec"]["templates"]}
    assert ta.keys() == tb.keys()
    platform = [n for n in ta if n not in user]
    assert platform, "fixture has no platform templates to compare"
    for n in platform:
        assert ta[n] == tb[n], f"platform template {n} changed by connections"


@pytest.mark.parametrize("name", HERA)
def test_envfrom_no_yaml_aliases(name):
    out = render(name, CONNECTIONS, ref=pinned_ref())
    assert "&id" not in out and "*id" not in out
