"""files/engine.py: the platform pipeline engine decision, the wheel fetch, stamp and compare (D-79).

Every branch of `decide` runs against a real unpacked fixture wheel served from a loopback http
server, and a fixture app checkout. Run with: python -m pytest tests/engine (needs PyYAML, pytest).
"""
import hashlib
import http.server
import io
import json
import threading
import zipfile

import pytest
import yaml

import engine

HERA_DERIVE = "5e88509fd4229f2f5b64936c1f3f3c3378137685"
YOLO_DERIVE = "7f0b5d7a008b67db499594a540c529ba21db1e3b"
AUTHORING = "b107b7cc6d201af4e938b01ad603d74b80e7a586"
COMPOSE_PRISTINE = "8031ff2bde50732723622a26f2480d64e799bb77"
GOOD_IMAGE = "europe-west1-docker.pkg.dev/kaos-dev-511509/kaos-pool/kaos-pipeline-engine:v0.9.0"


def blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


# Fixture app files: their git blob shas are what the fixture known-vendored.json lists.
DERIVE_HERA, DERIVE_YOLO, AUTHORING_PRISTINE = b"# hera derive\n", b"# yolo derive\n", b"# authoring\n"
DERIVE_FIRST = b"# first authoring derive\n"
COMPOSE_FILE = b"FROM python:3.11-slim\n"

KNOWN = {"modules": {
    "derive_tree.py": {
        blob(DERIVE_HERA): {"engine_profile": "hera", "profile": "hera"},
        blob(DERIVE_YOLO): {"engine_profile": "yolo", "profile": "yolo"},
        blob(DERIVE_FIRST): {"engine_profile": None, "profile": "ambiguous",
                             "no_profile_reason": "the first authoring wrote Parameter(default=)"},
    },
    "authoring.py": {blob(AUTHORING_PRISTINE): {"profile": "ambiguous"}},
}}


def make_wheel(members=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        files = {"kaos_pipeline_engine/kubecore/__init__.py": "",
                 "kaos_pipeline_engine/known-vendored.json": json.dumps(KNOWN),
                 "kaos_engine/render.py": "x = 1\n"}
        files.update(members or {})
        for name, content in files.items():
            zf.writestr(name, content)
    return buf.getvalue()


@pytest.fixture()
def server(tmp_path):
    """Serve tmp_path/www on a loopback port; returns (base_url, www dir)."""
    www = tmp_path / "www"
    www.mkdir()

    class Handler(http.server.SimpleHTTPRequestHandler):
        def __init__(self, *a, **kw):
            super().__init__(*a, directory=str(www), **kw)

        def log_message(self, *a):
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    yield f"http://127.0.0.1:{httpd.server_port}", www
    httpd.shutdown()


@pytest.fixture(autouse=True)
def fixtures_are_the_platform_files(monkeypatch):
    """No waiting between download attempts; the fixture compose Dockerfile is the pristine one."""
    monkeypatch.setattr(engine, "FETCH_PAUSE_SECONDS", 0)
    monkeypatch.setattr(engine, "PRISTINE_COMPOSE_DOCKERFILES", frozenset({blob(COMPOSE_FILE)}))


class World:
    """A gitops context, an app checkout, a pipeline-images file and a served wheel."""

    def __init__(self, tmp_path, server):
        self.base, self.www = server
        self.tmp = tmp_path
        self.repo = tmp_path / "repo"
        (self.repo / "kubecore").mkdir(parents=True)
        (self.repo / "kubecore" / "derive_tree.py").write_bytes(DERIVE_HERA)
        (self.repo / "kubecore" / "authoring.py").write_bytes(AUTHORING_PRISTINE)
        (self.repo / "steps" / "compose_and_validate").mkdir(parents=True)
        self.compose(COMPOSE_FILE)
        self.wheel_bytes = make_wheel()
        (self.www / "engine.whl").write_bytes(self.wheel_bytes)
        self.engine = {"version": "v0.9.0", "image": GOOD_IMAGE, "mode": "engine",
                       "wheel": f"{self.base}/engine.whl", "wheelSha256": hashlib.sha256(self.wheel_bytes).hexdigest()}
        self.images = tmp_path / "pipeline-images.yaml"
        self.images.write_text("data: {}\n")

    def compose(self, content):
        (self.repo / "steps" / "compose_and_validate" / "Dockerfile").write_bytes(content)

    def context(self, **engine_changes):
        block = dict(self.engine, **engine_changes)
        block = {k: v for k, v in block.items() if v is not None}
        inner = yaml.safe_dump({"project": "p", "app": "a", "engine": block})
        path = self.tmp / "pipeline-context.yaml"
        path.write_text(yaml.safe_dump({"kind": "ConfigMap", "data": {"context.yaml": inner}}))
        return str(path)

    def decide(self, ctx=None, **engine_changes):
        return engine.decide(ctx or self.context(**engine_changes), str(self.repo), str(self.images),
                             str(self.tmp / "work"))


@pytest.fixture()
def world(tmp_path, server):
    return World(tmp_path, server)


# ------------------------------------------------------------ legacy: held, never fetches, never raises

def test_should_stay_legacy_when_the_context_has_no_engine_block(world, tmp_path):
    path = tmp_path / "ctx.yaml"
    path.write_text(yaml.safe_dump({"project": "p"}))
    out = engine.decide(str(path), str(world.repo), "", str(tmp_path / "w"))
    assert out["mode"] == "legacy" and out["reason"].startswith("NoEngineBlock")
    assert out["vendored"] == "" and out["rebuild_compose"] is False


def test_should_stay_legacy_when_the_context_is_unreadable(world, tmp_path):
    out = engine.decide(str(tmp_path / "missing.yaml"), str(world.repo), "", str(tmp_path / "w"))
    assert out["mode"] == "legacy" and out["reason"].startswith("NoEngineBlock")


def test_should_stay_legacy_when_the_control_plane_asks_for_legacy(world):
    out = world.decide(mode="legacy")
    assert (out["mode"], out["requested_mode"]) == ("legacy", "legacy")
    assert out["reason"].startswith("ModeLegacy")
    assert not (world.tmp / "work").exists(), "legacy must not download the wheel"


def test_should_stay_legacy_when_the_mode_is_not_one_we_know(world):
    out = world.decide(mode="turbo")
    assert out["mode"] == "legacy" and out["reason"].startswith("InvalidMode")


def test_should_hold_legacy_when_the_pin_has_no_wheel_yet(world):
    out = world.decide(wheel=None, wheelSha256=None)
    assert out["mode"] == "legacy" and out["requested_mode"] == "engine"
    assert out["reason"].startswith("NoWheel") and out["version"] == "v0.9.0"


@pytest.mark.parametrize("changes", [
    {"version": "v0.9.0+abc"}, {"version": ""}, {"image": "kaos-pipeline-engine:v0.9.0"},
    {"image": "reg.example/kaos-pipeline-engine:latest"}, {"image": "reg.example/kaos-pipeline-engine"},
])
def test_should_hold_legacy_when_the_engine_block_is_not_a_pinned_release(world, changes):
    out = world.decide(**changes)
    assert out["mode"] == "legacy" and out["reason"].startswith("InvalidEngineBlock")


# ------------------------------------------------------------ shadow and engine

def test_should_take_the_hera_profile_from_the_vendored_blob_in_engine_mode(world):
    out = world.decide()
    assert out["mode"] == "engine" and out["profile"] == "hera" and out["vendored"] == "pristine"
    assert out["compose_dockerfile"] == "pristine"
    assert out["engine_image"] == GOOD_IMAGE and out["version"] == "v0.9.0"
    assert out["wheel_sha256"] == world.engine["wheelSha256"]


def test_should_take_the_yolo_profile_from_the_vendored_blob(world):
    (world.repo / "kubecore" / "derive_tree.py").write_bytes(DERIVE_YOLO)
    out = world.decide(mode="shadow")
    assert (out["mode"], out["profile"], out["vendored"]) == ("shadow", "yolo", "pristine")


def test_should_report_modified_and_use_the_template_profile_for_an_unknown_derive_tree(world):
    (world.repo / "kubecore" / "derive_tree.py").write_bytes(b"# edited by the client\n")
    (world.repo / "pyproject.toml").write_text('[project]\nname = "yolo-training-pipeline"\n')
    out = world.decide()
    assert (out["mode"], out["profile"], out["vendored"]) == ("engine", "yolo", "modified")


def test_should_report_modified_when_authoring_py_was_edited(world):
    (world.repo / "kubecore" / "authoring.py").write_bytes(b"raise SystemExit('booby trap')\n")
    out = world.decide()
    assert out["vendored"] == "modified" and out["mode"] == "engine" and out["profile"] == "hera"


def test_should_report_absent_when_the_app_has_no_vendored_copy(world):
    for f in (world.repo / "kubecore").iterdir():
        f.unlink()
    (world.repo / "kubecore").rmdir()
    (world.repo / "pyproject.toml").write_text('[project]\nname = "hera-pipeline-template"\n')
    out = world.decide()
    assert (out["vendored"], out["profile"], out["mode"]) == ("absent", "hera", "engine")


def test_should_hold_legacy_when_no_profile_can_be_told(world):
    (world.repo / "kubecore" / "derive_tree.py").write_bytes(b"# unknown\n")
    out = world.decide()
    assert out["mode"] == "legacy" and out["requested_mode"] == "engine"
    assert out["reason"].startswith("NoProfile") and out["profile"] == ""


def test_should_hold_legacy_for_the_first_authoring_with_its_reason(world):
    (world.repo / "kubecore" / "derive_tree.py").write_bytes(DERIVE_FIRST)
    out = world.decide(mode="shadow")
    assert out["mode"] == "legacy" and "Parameter(default=)" in out["reason"]


def test_should_keep_a_custom_compose_dockerfile_legacy_in_engine_mode(world):
    world.compose(b"FROM python:3.11-slim\nRUN pip install something-else\n")
    out = world.decide()
    assert out["mode"] == "legacy" and out["requested_mode"] == "engine" and out["compose_dockerfile"] == "custom"
    assert out["reason"].startswith("CustomComposeDockerfile") and out["rebuild_compose"] is False


def test_should_still_shadow_an_app_with_a_custom_compose_dockerfile(world):
    world.compose(b"FROM custom\n")
    out = world.decide(mode="shadow")
    assert out["mode"] == "shadow" and out["compose_dockerfile"] == "custom"


def test_should_see_no_compose_dockerfile_as_absent_not_custom(world):
    (world.repo / "steps" / "compose_and_validate" / "Dockerfile").unlink()
    out = world.decide()
    assert out["compose_dockerfile"] == "absent" and out["mode"] == "engine"


def test_should_ask_for_a_compose_rebuild_until_the_recorded_version_matches(world):
    assert world.decide()["rebuild_compose"] is True  # nothing recorded
    world.images.write_text("data: {engine-compose: v0.8.0}\n")
    assert world.decide()["rebuild_compose"] is True
    world.images.write_text("data: {engine-compose: v0.9.0}\n")
    assert world.decide()["rebuild_compose"] is False
    assert world.decide(mode="shadow")["rebuild_compose"] is False  # only engine mode composes with the engine


def test_should_make_the_same_decision_twice(world):
    assert world.decide() == world.decide()


# ------------------------------------------------------------ the wheel: fail closed

def test_should_fail_closed_with_a_clear_message_when_the_wheel_sha256_differs(world, capsys):
    ctx = world.context(wheelSha256="0" * 64)
    with pytest.raises(engine.EngineError) as err:
        engine.decide(ctx, str(world.repo), "", str(world.tmp / "w"))
    assert err.value.code == engine.EXIT_INTEGRITY
    assert "sha256 mismatch" in str(err.value) and "failing closed" in str(err.value)
    assert "0" * 64 in str(err.value) and world.engine["wheelSha256"] in str(err.value)


def test_should_exit_3_from_the_command_line_on_a_sha256_mismatch(world, capsys):
    rc = engine.main(["decide", "--context", world.context(wheelSha256="1" * 64), "--repo", str(world.repo),
                      "--work", str(world.tmp / "w")])
    assert rc == engine.EXIT_INTEGRITY
    assert "engine: FATAL: engine wheel sha256 mismatch" in capsys.readouterr().err


def test_should_fail_the_build_when_the_wheel_cannot_be_downloaded(world):
    ctx = world.context(wheel=f"{world.base}/missing.whl")
    with pytest.raises(engine.EngineError) as err:
        engine.decide(ctx, str(world.repo), "", str(world.tmp / "w"))
    assert err.value.code == engine.EXIT_UNAVAILABLE and "failing the build" in str(err.value)


def test_should_refuse_a_wheel_url_that_is_not_https(world):
    ctx = world.context(wheel="http://example.com/engine.whl")
    with pytest.raises(engine.EngineError) as err:
        engine.decide(ctx, str(world.repo), "", str(world.tmp / "w"))
    assert err.value.code == engine.EXIT_UNAVAILABLE and "must be https" in str(err.value)


def test_should_refuse_a_sha256_that_is_not_a_digest(world):
    with pytest.raises(engine.EngineError) as err:
        world.decide(wheelSha256="abc")
    assert err.value.code == engine.EXIT_INTEGRITY


def test_should_refuse_a_wheel_member_that_escapes_the_unpack_directory(world):
    evil = make_wheel({"kaos_pipeline_engine/../../evil.py": "x"})
    (world.www / "evil.whl").write_bytes(evil)
    with pytest.raises(engine.EngineError) as err:
        engine.fetch_wheel(f"{world.base}/evil.whl", hashlib.sha256(evil).hexdigest(), str(world.tmp / "d"))
    assert "escapes" in str(err.value)
    assert not (world.tmp / "evil.py").exists()


def test_should_refuse_a_wheel_without_an_engine(world):
    empty = io.BytesIO()
    with zipfile.ZipFile(empty, "w") as zf:
        zf.writestr("other/file.py", "x")
    (world.www / "empty.whl").write_bytes(empty.getvalue())
    with pytest.raises(engine.EngineError) as err:
        engine.fetch_wheel(f"{world.base}/empty.whl", hashlib.sha256(empty.getvalue()).hexdigest(), str(world.tmp / "d"))
    assert "holds no kaos_pipeline_engine/kubecore/" in str(err.value)


def test_should_unpack_only_the_engine_tree_and_never_a_top_level_kubecore(world):
    dest = world.tmp / "unpacked"
    engine_dir = engine.fetch_wheel(world.engine["wheel"], world.engine["wheelSha256"], str(dest))
    assert engine_dir == str(dest / "kaos_pipeline_engine")
    assert (dest / "kaos_pipeline_engine" / "kubecore" / "__init__.py").is_file()
    assert not (dest / "kaos_engine").exists() and not (dest / "kubecore").exists()
    assert not (dest / ".wheel.whl").exists()


def test_should_fetch_from_the_command_line(world, capsys):
    rc = engine.main(["fetch", "--wheel", world.engine["wheel"], "--sha256", world.engine["wheelSha256"],
                      "--dest", str(world.tmp / "cli")])
    assert rc == 0 and capsys.readouterr().out.strip().endswith("kaos_pipeline_engine")


# ------------------------------------------------------------ stamp and compare

WFT = {"apiVersion": "argoproj.io/v1alpha1", "kind": "WorkflowTemplate", "metadata": {"name": "a-pipeline"},
       "spec": {"entrypoint": "main", "arguments": {"parameters": [{"name": "x", "value": "1"}]}}}


def write(path, doc):
    path.write_text(yaml.safe_dump(doc, sort_keys=False))
    return str(path)


def test_should_stamp_the_annotation_and_the_workflow_label(tmp_path):
    path = write(tmp_path / "w.yaml", WFT)
    engine.stamp(path, "v0.9.0")
    doc = yaml.safe_load(open(path))
    assert doc["metadata"]["annotations"]["platform.kubecore.io/engine-version"] == "v0.9.0"
    assert doc["spec"]["workflowMetadata"]["labels"]["platform.kubecore.io/engine"] == "v0.9.0"
    assert doc["spec"]["entrypoint"] == "main"


def test_should_keep_existing_workflow_metadata_when_stamping(tmp_path):
    wft = json.loads(json.dumps(WFT))
    wft["spec"]["workflowMetadata"] = {"labels": {"team": "a"}, "annotations": {"k": "v"}}
    path = write(tmp_path / "w.yaml", wft)
    engine.stamp(path, "v0.9.0")
    meta = yaml.safe_load(open(path))["spec"]["workflowMetadata"]
    assert meta["labels"] == {"team": "a", "platform.kubecore.io/engine": "v0.9.0"} and meta["annotations"] == {"k": "v"}


def test_should_refuse_to_stamp_a_version_that_is_not_a_label_value(tmp_path):
    with pytest.raises(engine.EngineError):
        engine.stamp(write(tmp_path / "w.yaml", WFT), "0.9.0+abc")


def test_should_compare_equal_for_the_same_parsed_document_in_another_order(tmp_path):
    a = write(tmp_path / "a.yaml", WFT)
    (tmp_path / "b.yaml").write_text("spec: {arguments: {parameters: [{value: '1', name: x}], }, entrypoint: main}\n"
                                     "metadata: {name: a-pipeline}\nkind: WorkflowTemplate\napiVersion: argoproj.io/v1alpha1\n")
    assert engine.compare([(a, str(tmp_path / "b.yaml"))]) == "equal"


def test_should_count_every_differing_path(tmp_path):
    other = json.loads(json.dumps(WFT))
    other["spec"]["entrypoint"] = "other"
    other["spec"]["arguments"]["parameters"][0]["value"] = "2"
    other["metadata"]["labels"] = {"extra": "1"}
    logs = []
    out = engine.compare([(write(tmp_path / "a.yaml", WFT), write(tmp_path / "b.yaml", other))], log=logs.append)
    assert out == "differs:3" and len(logs) == 3


def test_should_compare_a_missing_file_as_an_empty_document(tmp_path):
    a = write(tmp_path / "a.yaml", {"kind": "ConfigMap"})
    assert engine.compare([(a, str(tmp_path / "missing.yaml"))]) == "differs:1"
    assert engine.compare([(str(tmp_path / "x"), str(tmp_path / "y"))]) == "equal"


def test_should_sum_the_differences_of_several_pairs(tmp_path):
    a, b = write(tmp_path / "a.yaml", WFT), write(tmp_path / "b.yaml", WFT)
    h1, h2 = write(tmp_path / "h1.yaml", {"data": {"a": "1"}}), write(tmp_path / "h2.yaml", {"data": {"a": "2"}})
    assert engine.main(["compare", a, b, h1, h2]) == 0
    assert engine.compare([(a, b), (h1, h2)]) == "differs:1"


# ------------------------------------------------------------ the pipeline-images record

def decision(**changes):
    return dict(engine.blank(), reason="Engine: ok", vendored="pristine", version="v0.9.0", **changes)


def test_should_record_engine_mode_version_and_vendored_in_engine_mode():
    rec = engine.record(decision(mode="engine"))
    assert rec["set"] == {"engine-mode": "engine", "engine-version": "v0.9.0", "engine-vendored": "pristine"}
    assert rec["clear"] == ["engine-shadow"]


def test_should_record_the_shadow_verdict_and_no_version_in_shadow_mode():
    rec = engine.record(decision(mode="shadow"), "differs:4")
    assert rec["set"] == {"engine-mode": "shadow", "engine-shadow": "differs:4", "engine-vendored": "pristine"}
    assert rec["clear"] == ["engine-version"]


def test_should_record_only_the_mode_in_legacy_and_clear_the_rest():
    rec = engine.record(dict(engine.blank(), reason="ModeLegacy: x"))
    assert rec["set"] == {"engine-mode": "legacy"}
    assert sorted(rec["clear"]) == ["engine-shadow", "engine-vendored", "engine-version"]


@pytest.mark.parametrize("reason", ["NoEngineBlock: none", "NotHera: kubeline"])
def test_should_record_nothing_for_an_app_the_engine_says_nothing_about(reason):
    assert engine.record(dict(engine.blank(), reason=reason)) == {"set": {}, "clear": []}
    assert engine.record({}) == {"set": {}, "clear": []}


def test_should_write_the_record_from_the_environment(tmp_path, monkeypatch):
    monkeypatch.setenv("ENGINE_DECISION", json.dumps(decision(mode="shadow")))
    (tmp_path / "shadow").write_text("equal")
    out = tmp_path / "rec.json"
    assert engine.main(["record", "--shadow-file", str(tmp_path / "shadow"), "--out", str(out)]) == 0
    assert json.loads(out.read_text())["set"]["engine-shadow"] == "equal"
    monkeypatch.setenv("ENGINE_DECISION", "not json")
    assert engine.main(["record", "--out", str(out)]) == 0
    assert json.loads(out.read_text()) == {"set": {}, "clear": []}
