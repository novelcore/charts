"""files/engine.py (PRD-HPC-1461 D-80): the engine block check, the schema profile, the wheel fetch
(sha256 fails closed) and the WorkflowTemplate stamp."""
import hashlib
import io
import json
import os
import zipfile

import pytest
import yaml

import engine

SHA = "a" * 64
BLOCK = {"version": "v0.4.7", "image": "reg.example/kaos-pipeline-engine:v0.4.7",
         "wheel": "https://example.com/engine.whl", "wheelSha256": SHA}


def write_context(tmp_path, block, wrap=True, **extra):
    ctx = dict(extra)
    if block is not None:
        ctx["engine"] = block
    path = tmp_path / "pipeline-context.yaml"
    doc = {"kind": "ConfigMap", "data": {"context.yaml": yaml.safe_dump(ctx)}} if wrap else ctx
    path.write_text(yaml.safe_dump(doc))
    return str(path)


def make_wheel(members):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as z:
        for name, data in members.items():
            z.writestr(name, data)
    return buf.getvalue()


GOOD_WHEEL = {"kaos_pipeline_engine/kubecore/__init__.py": "", "kaos_pipeline_engine/kubecore/enhance.py": "x = 1\n",
              "kaos_engine/render.py": "ignored"}


@pytest.fixture
def served(monkeypatch):
    """Serve `data` for every URL fetch_wheel asks for."""
    box = {}
    monkeypatch.setattr(engine, "_read_url", lambda url: box["data"])
    return box


# ---------------------------------------------------------------- context and profile

def test_context_is_the_engine_block_and_a_profile(tmp_path):
    repo = tmp_path / "repo"
    (repo / "config").mkdir(parents=True)
    out = engine.engine_of(write_context(tmp_path, BLOCK, extra="x"), str(repo))
    assert out == {"version": "v0.4.7", "image": BLOCK["image"], "wheel": BLOCK["wheel"], "wheel_sha256": SHA,
                   "profile": "hera"}


def test_a_mode_key_is_ignored(tmp_path):
    out = engine.engine_of(write_context(tmp_path, dict(BLOCK, mode="legacy")), str(tmp_path))
    assert out["version"] == "v0.4.7"


@pytest.mark.parametrize("make", [
    lambda repo: (repo / "config" / "quantization.yaml").write_text("x: 1\n"),
    lambda repo: (repo / "config" / "quantization").mkdir(),
])
def test_quantization_config_means_the_yolo_profile(tmp_path, make):
    repo = tmp_path / "repo"
    (repo / "config").mkdir(parents=True)
    make(repo)
    assert engine.profile_of(str(repo)) == "yolo"


def test_no_quantization_means_hera_whatever_the_app_calls_itself(tmp_path):
    repo = tmp_path / "repo"
    (repo / "config").mkdir(parents=True)
    (repo / "pyproject.toml").write_text('[project]\nname = "yolo-pipelines"\n')
    (repo / "config" / "data.yaml").write_text("a: 1\n")
    assert engine.profile_of(str(repo)) == "hera"


def make_app(tmp_path, quantization=True, own_engine=None):
    """An app checkout; `own_engine` is the text of a kubecore/derive_tree.py it carries (an old app)."""
    repo = tmp_path / "repo"
    (repo / "config").mkdir(parents=True)
    if quantization:
        (repo / "config" / "quantization.yaml").write_text("quantization:\n  mode: none\n")
    if own_engine is not None:
        (repo / "kubecore").mkdir()
        (repo / "kubecore" / "derive_tree.py").write_text(own_engine)
    return str(repo)


@pytest.mark.parametrize("own_engine", [
    "@dataclass\nclass DataConfig:\n    ref: str = 'main'\n    version: str = ''\n",   # what named legacy-v1
    "raise SystemExit('executed')\n",
    "def broken(:\n",
    "x = 1\n" * 40000,                                                                   # over 64 KiB
])
def test_an_app_with_an_engine_copy_of_its_own_is_not_read_and_gets_the_profile_of_its_config(tmp_path, own_engine):
    # The engine refuses such an app as an old app (kaos-hpc-operator engine/kaos_engine/render.py); this script
    # neither reads nor trusts what the app carries, so the refusal is the engine's and its exit code is the render's.
    out = engine.engine_of(write_context(tmp_path, BLOCK), make_app(tmp_path, own_engine=own_engine))
    assert out["profile"] == "yolo"
    assert engine.engine_of(write_context(tmp_path, BLOCK), make_app(tmp_path / "h", quantization=False,
                                                                       own_engine=own_engine))["profile"] == "hera"


def test_the_profiles_are_the_two_the_engine_has():
    assert engine.PROFILES == ("hera", "yolo")


def test_a_profile_outside_the_engine_set_fails_closed(tmp_path, monkeypatch):
    monkeypatch.setattr(engine, "profile_of", lambda repo: "yolo-v9")
    with pytest.raises(engine.EngineError, match="yolo-v9") as exc:
        engine.engine_of(write_context(tmp_path, BLOCK), str(tmp_path))
    assert exc.value.code == engine.EXIT_PROFILE


@pytest.mark.parametrize("block", [
    None,
    "not a dict",
    dict(BLOCK, version=""),
    dict(BLOCK, version="v1+x/y"),
    dict(BLOCK, image="kaos-pipeline-engine:v0.4.7"),
    dict(BLOCK, image="reg.example/kaos-pipeline-engine:latest"),
    dict(BLOCK, image="reg.example/kaos-pipeline-engine"),
    dict(BLOCK, wheel=""),
    dict(BLOCK, wheelSha256="xyz"),
    dict(BLOCK, wheelSha256=""),
])
def test_no_usable_engine_is_an_error(tmp_path, block):
    with pytest.raises(engine.EngineError) as exc:
        engine.engine_of(write_context(tmp_path, block), str(tmp_path))
    assert exc.value.code == engine.EXIT_NO_ENGINE


def test_an_unreadable_context_has_no_engine(tmp_path):
    with pytest.raises(engine.EngineError):
        engine.engine_of(str(tmp_path / "missing.yaml"), str(tmp_path))


def test_cli_context_and_version(tmp_path, capsys):
    path = write_context(tmp_path, BLOCK)
    assert engine.main(["context", "--context", path, "--repo", str(tmp_path)]) == 0
    assert json.loads(capsys.readouterr().out)["version"] == "v0.4.7"
    assert engine.main(["version", "--context", path]) == 0
    assert capsys.readouterr().out.strip() == "v0.4.7"
    assert engine.main(["version", "--context", write_context(tmp_path, None)]) == 0
    assert capsys.readouterr().out.strip() == ""
    assert engine.main(["context", "--context", write_context(tmp_path, None), "--repo", str(tmp_path)]) == engine.EXIT_NO_ENGINE


# ---------------------------------------------------------------- context-sha (PRD novelcore/kaos#1911 AC-24)

CTX = {"project": "p", "app": "a", "namespace": "ml-p", "engine": BLOCK,
       "hpc": {"enabled": True, "provider": "meluxina", "scratch": "/s/a", "home": "/h/u", "classes": [{"name": "c"}]},
       "kaosLib": {"spec": "kaos-lib==0.5.0", "version": "0.5.0", "support": {"version": "0.5.0"}},
       "computeClasses": {"cpu": {"name": "cpu-small", "maxNodeCount": 4}}}


def sha_of(tmp_path, ctx, wrap=True):
    path = tmp_path / "ctx.yaml"
    doc = {"kind": "ConfigMap", "data": {"context.yaml": yaml.safe_dump(ctx)}} if wrap else ctx
    path.write_text(yaml.safe_dump(doc))
    return engine.context_sha(str(path))


def test_context_sha_ignores_what_the_render_does_not_read(tmp_path):
    base = sha_of(tmp_path, CTX)
    assert len(base) == 64
    moved = json.loads(json.dumps(CTX))
    moved["hpc"].update(scratch="/s/elsewhere", home="/h/other")
    moved["kaosLib"].update(spec="kaos-lib==0.6.0", version="0.6.0")
    assert sha_of(tmp_path, moved) == base


def test_context_sha_of_a_pinned_app_moves_with_its_pin(tmp_path):
    # the app's own pin must fire the forced run (KAOS-LIB PIN): its whole kaosLib block is hashed
    pinned = json.loads(json.dumps(CTX))
    pinned["kaosLib"]["pinned"] = True
    base = sha_of(tmp_path, pinned)
    assert base != sha_of(tmp_path, CTX)
    for key, value in (("spec", "kaos-lib==0.6.0"), ("version", "0.6.0")):
        moved = json.loads(json.dumps(pinned))
        moved["kaosLib"][key] = value
        assert sha_of(tmp_path, moved) != base


def test_context_sha_ignores_formatting_comments_and_key_order(tmp_path):
    base = sha_of(tmp_path, CTX)
    path = tmp_path / "c.yaml"
    body = "# a comment\n" + yaml.safe_dump(dict(reversed(list(CTX.items()))), default_flow_style=True)
    path.write_text(yaml.safe_dump({"kind": "ConfigMap", "data": {"context.yaml": body}}))
    assert engine.context_sha(str(path)) == base
    assert sha_of(tmp_path, CTX, wrap=False) == base


@pytest.mark.parametrize("path", [("project",), ("app",), ("namespace",), ("engine", "wheelSha256"), ("engine", "version"),
                                  ("hpc", "enabled"), ("hpc", "classes"), ("kaosLib", "support"),
                                  ("computeClasses", "cpu", "maxNodeCount")])
def test_context_sha_moves_with_every_other_field(tmp_path, path):
    changed = json.loads(json.dumps(CTX))
    node = changed
    for key in path[:-1]:
        node = node[key]
    node[path[-1]] = "changed"
    assert sha_of(tmp_path, changed) != sha_of(tmp_path, CTX)


def test_context_sha_hashes_a_field_nobody_has_looked_at(tmp_path):
    added = dict(CTX, somethingNew={"x": 1})
    assert sha_of(tmp_path, added) != sha_of(tmp_path, CTX)
    assert sha_of(tmp_path, dict(CTX, hpc=dict(CTX["hpc"], newKey="v"))) != sha_of(tmp_path, CTX)


def test_a_section_left_empty_by_the_projection_is_a_section_never_written(tmp_path):
    only = {"app": "a", "kaosLib": {"spec": "s", "version": "1"}}
    assert sha_of(tmp_path, only) == sha_of(tmp_path, {"app": "a"})
    assert sha_of(tmp_path, {"app": "a", "kaosLib": {"spec": "s", "support": {"v": 1}}}) != sha_of(tmp_path, {"app": "a"})


@pytest.mark.parametrize("text", ["", "[]", "a: [", "kind: ConfigMap\ndata: {}\n"])
def test_context_sha_of_something_that_is_not_a_context_is_empty(tmp_path, capsys, text):
    path = tmp_path / "bad.yaml"
    path.write_text(text)
    assert engine.context_sha(str(path)) == ""
    assert engine.main(["context-sha", "--context", str(path)]) == 1
    assert engine.context_sha(str(tmp_path / "missing.yaml")) == ""


def _raw_sha(tmp_path, text):
    path = tmp_path / "raw.yaml"
    path.write_text(text)
    return engine.context_sha(str(path))


@pytest.mark.parametrize("text", [
    "app: a\non: 1\n",                       # an unquoted `on` is the boolean True beside a string key
    "app: a\ntrigger: {on: 1, name: x}\n",   # nested
    "app: a\n1: x\n",                        # an int key beside a string key
    "app: a\nyes: 1\nno: 2\n",
    "app: a\n? null\n: 1\n",
    "app: a\n2026-01-02: x\n",               # a date key
    "app: a\n1: x\n\"1\": y\n",              # keys that print the same
])
def test_context_sha_is_total_over_key_types(tmp_path, text):
    digest = _raw_sha(tmp_path, text)
    assert len(digest) == 64
    assert _raw_sha(tmp_path, text) == digest


def test_context_sha_of_mixed_keys_does_not_depend_on_their_order(tmp_path):
    assert _raw_sha(tmp_path, "app: a\non: 1\nname: x\n") == _raw_sha(tmp_path, "name: x\non: 1\napp: a\n")
    assert _raw_sha(tmp_path, "app: a\n1: x\n\"1\": y\n") == _raw_sha(tmp_path, "\"1\": y\n1: x\napp: a\n")
    assert _raw_sha(tmp_path, "app: a\n1: x\n\"1\": y\n") != _raw_sha(tmp_path, "app: a\n1: y\n\"1\": x\n")
    assert _raw_sha(tmp_path, "app: a\non: 1\n") != _raw_sha(tmp_path, "app: a\non: 2\n")


def test_context_sha_never_raises(tmp_path, monkeypatch):
    path = tmp_path / "c.yaml"
    path.write_text("app: a\n")
    monkeypatch.setattr(engine, "_canonical", lambda v: (_ for _ in ()).throw(RecursionError()))
    assert engine.context_sha(str(path)) == ""
    assert engine.main(["context-sha", "--context", str(path)]) == 1


def test_cli_context_sha(tmp_path, capsys):
    path = write_context(tmp_path, BLOCK, app="a")
    assert engine.main(["context-sha", "--context", path]) == 0
    assert capsys.readouterr().out.strip() == engine.context_sha(path)


# ---------------------------------------------------------------- the wheel

def test_fetch_verifies_and_unpacks_the_engine_only(tmp_path, served):
    served["data"] = make_wheel(GOOD_WHEEL)
    sha = hashlib.sha256(served["data"]).hexdigest()
    engine_dir = engine.fetch_wheel("https://x/e.whl", sha, str(tmp_path / "dest"))
    assert os.path.isfile(os.path.join(engine_dir, "kubecore", "enhance.py"))
    assert not os.path.exists(tmp_path / "dest" / "kaos_engine")  # the runner is not unpacked


def test_a_sha256_that_differs_fails_closed(tmp_path, served):
    served["data"] = make_wheel(GOOD_WHEEL)
    with pytest.raises(engine.EngineError) as exc:
        engine.fetch_wheel("https://x/e.whl", "b" * 64, str(tmp_path / "dest"))
    assert exc.value.code == engine.EXIT_INTEGRITY
    assert "sha256 mismatch" in str(exc.value)
    assert not (tmp_path / "dest").exists()  # nothing was unpacked


def test_a_malformed_sha256_is_refused(tmp_path, served):
    served["data"] = make_wheel(GOOD_WHEEL)
    with pytest.raises(engine.EngineError):
        engine.fetch_wheel("https://x/e.whl", "short", str(tmp_path / "dest"))


def test_a_wheel_without_the_engine_is_refused(tmp_path, served):
    served["data"] = make_wheel({"other/x.py": ""})
    with pytest.raises(engine.EngineError):
        engine.fetch_wheel("https://x/e.whl", hashlib.sha256(served["data"]).hexdigest(), str(tmp_path / "dest"))


def test_zip_slip_is_refused(tmp_path, served):
    served["data"] = make_wheel({"kaos_pipeline_engine/../../evil.py": "x"})
    with pytest.raises(engine.EngineError):
        engine.fetch_wheel("https://x/e.whl", hashlib.sha256(served["data"]).hexdigest(), str(tmp_path / "dest"))
    assert not (tmp_path / "evil.py").exists()


def test_a_download_that_fails_fails_the_build(monkeypatch):
    monkeypatch.setattr(engine, "FETCH_PAUSE_SECONDS", 0)

    def boom(*a, **k):
        raise OSError("network down")

    monkeypatch.setattr(engine.urllib.request, "urlopen", boom)
    with pytest.raises(engine.EngineError) as exc:
        engine._read_url("https://x/e.whl")
    assert exc.value.code == engine.EXIT_UNAVAILABLE
    assert "could not be downloaded" in str(exc.value)


@pytest.mark.parametrize("url", ["http://example.com/e.whl", "file:///etc/passwd", "ftp://x/e"])
def test_only_https_or_local_http(url):
    with pytest.raises(engine.EngineError):
        engine._read_url(url)


# ---------------------------------------------------------------- stamp

def test_stamp_marks_the_wft_and_the_workflows_it_makes(tmp_path):
    path = tmp_path / "wft.yaml"
    path.write_text(yaml.safe_dump({"metadata": {"name": "x"}, "spec": {"templates": []}}))
    engine.stamp(str(path), "v0.4.7")
    wft = yaml.safe_load(path.read_text())
    assert wft["metadata"]["annotations"]["platform.kubecore.io/engine-version"] == "v0.4.7"
    assert wft["spec"]["workflowMetadata"]["labels"]["platform.kubecore.io/engine"] == "v0.4.7"


def test_stamp_refuses_a_version_that_is_not_a_label_value(tmp_path):
    path = tmp_path / "wft.yaml"
    path.write_text("{}")
    with pytest.raises(engine.EngineError):
        engine.stamp(str(path), "v1+abc")


# ---------------------------------------------------------------- the step table (PRD kaos#1911)

TABLE = [{"name": "prepare", "kind": "transform", "reads": [], "inputs": ["raw"], "needs": [],
          "produces": [{"name": "clean", "type": "dataset"}]},
         {"name": "train", "kind": "train", "reads": ["train"], "inputs": ["raw", "labels"], "needs": ["prepare"],
          "produces": [{"name": "model", "type": "model"}]}]


def write_wft(tmp_path, args, name="compose-and-validate"):
    wft = {"kind": "WorkflowTemplate", "spec": {"templates": [
        {"name": "main", "dag": {"tasks": []}}, {"name": name, "container": {"image": "x", "args": args}}]}}
    path = tmp_path / "wft.yaml"
    path.write_text(yaml.safe_dump(wft))
    return str(path)


def test_the_step_table_is_the_compose_argument_after_steps(tmp_path):
    wft = write_wft(tmp_path, ["a=1", "--advanced", "{{workflow.parameters.config}}", "--steps", json.dumps(TABLE), "--run", "r"])
    assert engine.step_table(wft) == TABLE


def test_cli_steps_prints_the_table(tmp_path, capsys):
    assert engine.main(["steps", "--wft", write_wft(tmp_path, ["--steps", json.dumps(TABLE)])]) == 0
    assert json.loads(capsys.readouterr().out) == TABLE


@pytest.mark.parametrize("args", [
    ["--advanced", "x"],                        # an engine from before the step contract
    ["--steps"],                                # nothing after it
    ["--steps", "not json"],
    ["--steps", json.dumps({"name": "a"})],     # not a list
    ["--steps", json.dumps([{"name": "a"}])],   # a step without inputs
    ["--steps", json.dumps([{"name": "a", "inputs": "raw"}])],
])
def test_a_render_without_a_step_table_is_not_from_an_engine_on_the_step_contract(tmp_path, capsys, args):
    with pytest.raises(engine.EngineError) as err:
        engine.step_table(write_wft(tmp_path, args))
    assert err.value.code == engine.EXIT_NO_CONTRACT
    assert engine.main(["steps", "--wft", write_wft(tmp_path, args)]) == engine.EXIT_NO_CONTRACT
    assert "engine: FATAL" in capsys.readouterr().err


def test_a_render_without_the_compose_step_has_no_step_table(tmp_path):
    with pytest.raises(engine.EngineError) as err:
        engine.step_table(write_wft(tmp_path, ["--steps", json.dumps(TABLE)], name="other"))
    assert err.value.code == engine.EXIT_NO_CONTRACT


# ---------------------------------------------------------------- produced datasets (pipeline-images record)

def dataset_table(*produced):
    """A step table whose steps produce the given (name, type) pairs, one step per pair."""
    return [{"name": f"s{i}", "kind": "transform", "reads": [], "inputs": [], "needs": [],
             "produces": [{"name": n, "type": t}]} for i, (n, t) in enumerate(produced)]


def produced_of(tmp_path, table):
    return engine.produced_datasets(engine.step_table(write_wft(tmp_path, ["--steps", json.dumps(table)])))


def test_the_produced_datasets_are_the_short_names_sorted_and_comma_separated(tmp_path):
    table = dataset_table(("features", "dataset"), ("model", "model"), ("clean", "dataset"), ("report", "artifact"))
    assert produced_of(tmp_path, table) == "clean,features"


def test_a_pipeline_that_produces_no_dataset_has_an_empty_record(tmp_path):
    assert produced_of(tmp_path, dataset_table(("model", "model"), ("report", "artifact"))) == ""
    assert produced_of(tmp_path, []) == ""
    assert produced_of(tmp_path, [{"name": "gate", "kind": "control", "reads": [], "inputs": [], "needs": []}]) == ""


def test_a_name_is_listed_once(tmp_path):
    assert produced_of(tmp_path, dataset_table(("clean", "dataset"), ("clean", "dataset"))) == "clean"


def test_cli_produced_prints_the_record(tmp_path, capsys):
    table = dataset_table(("features", "dataset"), ("clean", "dataset"))
    assert engine.main(["produced", "--wft", write_wft(tmp_path, ["--steps", json.dumps(table)])]) == 0
    assert capsys.readouterr().out == "clean,features\n"
    assert engine.main(["produced", "--wft", write_wft(tmp_path, ["--steps", json.dumps([])])]) == 0
    assert capsys.readouterr().out == "\n"


@pytest.mark.parametrize("produces", ["clean", [{"name": "clean"}], [{"type": "dataset"}], [{"name": 3, "type": "dataset"}]])
def test_a_produces_entry_that_is_not_a_name_and_a_type_is_not_a_step_table_of_the_contract(tmp_path, produces):
    table = [{"name": "a", "kind": "transform", "reads": [], "inputs": [], "needs": [], "produces": produces}]
    with pytest.raises(engine.EngineError) as err:
        produced_of(tmp_path, table)
    assert err.value.code == engine.EXIT_NO_CONTRACT


def test_a_render_without_a_step_table_records_nothing(tmp_path, capsys):
    assert engine.main(["produced", "--wft", write_wft(tmp_path, ["--advanced", "x"])]) == engine.EXIT_NO_CONTRACT
    out = capsys.readouterr()
    assert out.out == "" and "engine: FATAL" in out.err


# ---------------------------------------------------------------- engine-attempt (one try per refusal)

COMMIT = "c" * 40
LIB = {"spec": "kaos-lib==0.5.0", "version": "0.5.0"}


def test_a_failed_attempt_is_the_engine_version_and_the_time(tmp_path):
    assert engine.attempt(write_context(tmp_path, BLOCK), now=1700000000) == "v0.4.7@1700000000"
    assert engine.attempt(write_context(tmp_path, None), now=5) == "unknown@5"


def test_a_refused_app_records_its_commit_and_the_kaos_lib_delivered(tmp_path):
    ctx = write_context(tmp_path, BLOCK, kaosLib=LIB)
    value = engine.attempt(ctx, now=1700000000, refused_commit=COMMIT)
    key = hashlib.sha256(b"kaos-lib==0.5.0").hexdigest()[:12]
    assert value == f"v0.4.7@1700000000@{COMMIT}@{key}"
    assert engine.refused(value, ctx, COMMIT) is True


def test_a_refusal_holds_until_the_commit_the_engine_or_the_kaos_lib_changes(tmp_path):
    ctx = write_context(tmp_path, BLOCK, kaosLib=LIB)
    value = engine.attempt(ctx, now=1, refused_commit=COMMIT)
    assert engine.refused(value, ctx, "d" * 40) is False, "a new commit is tried"
    newer = write_context(tmp_path, dict(BLOCK, version="v0.4.8"), kaosLib=LIB)
    assert engine.refused(value, newer, COMMIT) is False, "a new engine is tried"
    moved = write_context(tmp_path, BLOCK, kaosLib={"spec": "kaos-lib==0.5.1"})
    assert engine.refused(value, moved, COMMIT) is False, "another kaos-lib is tried"


@pytest.mark.parametrize("value", ["", "v0.4.7@1700000000", "v0.4.7@1700000000@", "junk", "v0.4.7@1@" + "c" * 40])
def test_an_attempt_that_is_not_a_refusal_never_holds(tmp_path, value):
    assert engine.refused(value, write_context(tmp_path, BLOCK, kaosLib=LIB), COMMIT) is False


def test_an_unreadable_context_never_holds(tmp_path):
    value = engine.attempt(write_context(tmp_path, BLOCK, kaosLib=LIB), now=1, refused_commit=COMMIT)
    assert engine.refused(value, str(tmp_path / "missing.yaml"), COMMIT) is False


def test_cli_attempt_and_refused(tmp_path, capsys):
    ctx = write_context(tmp_path, BLOCK, kaosLib=LIB)
    assert engine.main(["attempt", "--context", ctx, "--refused-commit", COMMIT]) == 0
    value = capsys.readouterr().out.strip()
    assert value.startswith("v0.4.7@") and value.split("@")[2] == COMMIT
    assert engine.main(["refused", "--context", ctx, "--commit", COMMIT, "--attempt", value]) == 0
    assert engine.main(["refused", "--context", ctx, "--commit", "d" * 40, "--attempt", value]) == 1
    assert engine.main(["attempt", "--context", ctx]) == 0
    assert capsys.readouterr().out.strip().count("@") == 1


# ── context-sha: the vector shared with the k8smlapp composition (kubecore-operator) ───────────────────────────
# fixtures/operator-context-*.yaml are the pipeline-context ConfigMaps the composition renders; the digests are
# the composition's own `context_proj` for them (golden-f26-below-0.16.0.yaml / the AC-24 render test there).
# b carries `& < >`, U+2028, non-ASCII, a float and a whole float: the places Go's json and Python's differ.
@pytest.mark.parametrize("name,digest", [
    ("operator-context-a.yaml", "a04e43d2f5f9c48d47b3ef399cc6e811c08de6ed998505afd262316b360bbe44"),
    ("operator-context-b.yaml", "afbbdab2b46ab417d166129473eb18e5fa869a3505b1068b0d7f1b66e02e6d11"),
])
def test_context_sha_equals_the_compositions(name, digest):
    assert engine.context_sha(os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", name)) == digest
