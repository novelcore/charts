import pytest
import yaml

from harness import FIXTURES, golden_text, pinned_ref, render

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
