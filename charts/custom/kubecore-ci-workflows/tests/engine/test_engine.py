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
