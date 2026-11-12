"""What the chart reads of a pipeline the engine rendered on the step contract (PRD novelcore/kaos#1911).

The goldens are real engine output (harness.ENGINE_REF), so these tests hold the chart's two readers to it:
`files/engine.py steps` (the step table on the compose step; a render without one is not from an engine on
the step contract) and `files/dataset-choices.py` (a picker on the form field of every declared input, and
no field added or removed).
"""
import copy
import importlib.util
import os
import re

import pytest
import yaml

import harness
from harness import APPS, CHART, FIX, FIXTURES, GOLDEN, golden_path, golden_text


def _load(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(CHART, "files", filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


engine = _load("ci_engine", "engine.py")
choices = _load("ci_dataset_choices", "dataset-choices.py")

HERA = sorted(FIXTURES)
# fixture app -> the names its steps declare in inputs= (fixtures/apps/<app>/pipeline.py)
INPUTS = {"hera-raw/hera-app.yaml": ["dataset"], "hera-raw/yolo-app.yaml": ["calibration", "dataset"]}
CATALOG = [
    {"name": "dataset-cars", "versions": [{"tag": "v2"}, {"tag": "v1"}]},
    {"name": "dataset-default", "default": True, "versions": [{"tag": "v3"}]},
]
OFFERED = ["dataset-default@v3", "dataset-default@latest", "dataset-cars@v2", "dataset-cars@v1", "dataset-cars@latest"]
# The form keys the platform reserves for the run itself (PRD kaos#1911, section 8.1).
RESERVED = {"plan", "pipeline-version"}


def _inputs_of(name):
    return INPUTS[os.path.relpath(FIXTURES[name].source, FIX)]


def _params(wft):
    return wft["spec"]["arguments"]["parameters"]


@pytest.mark.parametrize("name", HERA)
def test_the_step_table_of_an_enhanced_pipeline_is_readable(name):
    table = engine.step_table(golden_path("hera", name))
    assert choices.input_names(table) == _inputs_of(name)
    for step in table:
        assert set(step) >= {"name", "kind", "reads", "inputs", "needs", "produces"}


def test_the_yolo_fixture_declares_what_it_produces():
    table = engine.step_table(golden_path("hera", "yolo-pipeline"))
    produced = {(e["type"], e["name"]) for step in table for e in step["produces"]}
    assert produced == {("dataset", "prepared"), ("model", "checkpoints"), ("model", "qat"), ("artifact", "quantized")}
    assert [s["kind"] for s in table] == ["control", "transform", "train", "train", "transform", "publish"]


@pytest.mark.parametrize("name", HERA)
def test_every_input_is_a_form_field_and_gets_a_picker(name):
    wft = yaml.safe_load(golden_text("hera", name))
    before = copy.deepcopy(_params(wft))
    filled = choices.fill(wft, _inputs_of(name), CATALOG)
    assert sorted(filled) == _inputs_of(name)
    after = {p["name"]: p for p in _params(wft)}
    assert [p["name"] for p in _params(wft)] == [p["name"] for p in before], "no field added, removed or moved"
    for field in before:
        if field["name"] in filled:
            assert after[field["name"]]["enum"] == OFFERED
            assert after[field["name"]]["value"] == "dataset-default@latest", "the config's default is kept"
        else:
            assert after[field["name"]] == field, f"{field['name']} is not an input and is left alone"


@pytest.mark.parametrize("name", HERA)
def test_the_form_has_no_reserved_key_before_or_after_the_chart(name):
    wft = yaml.safe_load(golden_text("hera", name))
    assert not RESERVED & {p["name"] for p in _params(wft)}
    choices.fill(wft, _inputs_of(name), CATALOG)
    assert not RESERVED & {p["name"] for p in _params(wft)}


@pytest.mark.parametrize("name", HERA)
def test_a_render_without_a_step_table_fails_closed(name, tmp_path):
    """What an engine from before the step contract renders: a compose step with no --steps."""
    wft = yaml.safe_load(golden_text("hera", name))
    compose = next(t for t in wft["spec"]["templates"] if t["name"] == "compose-and-validate")
    args = compose["container"]["args"]
    at = args.index("--steps")
    del args[at:at + 2]
    path = tmp_path / "old-engine.yaml"
    path.write_text(yaml.safe_dump(wft))
    with pytest.raises(engine.EngineError) as err:
        engine.step_table(str(path))
    assert err.value.code == engine.EXIT_NO_CONTRACT
    assert "not on the step contract" in str(err.value)


def _fixture_files():
    for root in (os.path.join(FIX, "hera-raw"), GOLDEN):
        for folder, _, files in os.walk(root):
            for f in files:
                yield os.path.join(folder, f)


def test_the_fixtures_are_on_the_step_contract():
    """One context in, one result out; none of the names the step contract replaced."""
    gone = re.compile(r"data-lock|dataset-pin|step-outputs|KUBECORE_RUN_ID|KUBECORE_DATASET_|--params\b")
    files = list(_fixture_files())
    assert len(files) == 14
    for path in files:
        text = open(path).read()
        assert not gone.search(text), f"{os.path.relpath(path, harness.HERE)} still carries {gone.search(text).group(0)}"
        assert "kaos-context" in text and "kaos-result" in text and "KAOS_STEP_CONTEXT" in text


@pytest.mark.skipif(not os.environ.get("ENGINE_PYTHON"), reason="needs ENGINE_PYTHON (a python with the engine's libraries)")
@pytest.mark.parametrize("app", sorted(APPS))
def test_the_raw_fixture_is_what_the_engine_renders_from_the_fixture_app(app):
    with open(os.path.join(FIX, APPS[app][0])) as f:
        assert harness.render_raw(harness.fetch_engine(harness.ENGINE_REF), app) == f.read()
