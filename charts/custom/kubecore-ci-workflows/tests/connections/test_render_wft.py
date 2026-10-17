import os

import pytest
import yaml

from harness import FIXTURES, golden_text, render

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
