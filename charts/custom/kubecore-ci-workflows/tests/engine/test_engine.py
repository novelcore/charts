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


# The four structured-config schemas the templates' vendored kubecore/derive_tree.py has had, cut down
# to the two dataclasses the engine profiles differ in (kaos-hpc-operator engine/README.md).
DT_HEAD = ("from dataclasses import dataclass\nfrom enum import Enum\n\n"
           "class DataSource(Enum):\n    lakefs = 'lakefs'\n\n")
DT_LEGACY_V1 = DT_HEAD + ("@dataclass\nclass DataConfig:\n    ref: str = 'main'\n    source: DataSource = DataSource.lakefs\n"
                          "    version: str = ''\n    seed: int = 42\n\n"
                          "@dataclass\nclass QuantizationConfig:\n    image_size: int = 640\n"
                          "    output_prefix: str = 'quantization'\n")
DT_HERA = DT_HEAD + ("@dataclass\nclass DataConfig:\n    ref: str = 'main'\n    source: DataSource = DataSource.lakefs\n"
                     "    seed: int = 42\n\n"
                     "@dataclass\nclass QuantizationConfig:\n    image_size: int = 640\n    output_prefix: str = ''\n")
DT_YOLO_V1 = DT_HEAD + ("@dataclass\nclass DataConfig:\n    source: DataSource = DataSource.lakefs\n    seed: int = 42\n\n"
                        "@dataclass\nclass QuantizationConfig:\n    image_size: int = 640\n    output_prefix: str = ''\n")
DT_YOLO = DT_HEAD + ("@dataclass\nclass DataConfig:\n    source: DataSource = DataSource.lakefs\n    seed: int = 42\n\n"
                     "@dataclass\nclass QuantizationConfig:\n    image_size: int = 640\n")


def make_app(tmp_path, derive_tree=None, quantization=True, data_yaml=None):
    repo = tmp_path / "repo"
    (repo / "config").mkdir(parents=True)
    if quantization:
        (repo / "config" / "quantization.yaml").write_text("quantization:\n  mode: none\n")
    if data_yaml is not None:
        (repo / "config" / "data.yaml").write_text(data_yaml)
    if derive_tree is not None:
        (repo / "kubecore").mkdir()
        (repo / "kubecore" / "derive_tree.py").write_text(derive_tree)
    return str(repo)


@pytest.mark.parametrize("derive_tree, profile", [
    (DT_LEGACY_V1, "legacy-v1"),
    (DT_HERA, "hera"),
    (DT_YOLO_V1, "yolo-v1"),
    (DT_YOLO, "yolo"),
])
def test_the_vendored_derive_tree_names_the_profile(tmp_path, derive_tree, profile):
    assert engine.profile_of(make_app(tmp_path, derive_tree)) == profile


def test_a_yolo_app_of_the_template_main_renders_with_hera(tmp_path):
    # kubecore-operator#1830: yolo-pipelines-template `main` (derive_tree blob c3c4e36, since 2026-10-19) has a
    # quantization section AND DataConfig.ref; the `yolo` schema has no ref, so every such app failed to
    # render with "Key 'ref' not in 'DataConfig'". Its schema is the hera profile.
    repo = make_app(tmp_path, DT_HERA, quantization=True, data_yaml='data:\n  ref: "main"\n  seed: 42\n')
    assert engine.profile_of(repo) == "hera"


def test_the_derive_tree_is_parsed_never_executed(tmp_path):
    trap = "raise SystemExit('executed')\n" + DT_YOLO
    assert engine.profile_of(make_app(tmp_path, trap)) == "yolo"


def test_a_derive_tree_without_a_schema_falls_back_to_the_config(tmp_path):
    stub = "# moved to kaos-lib\nfrom kaos.derive_tree import *\n"  # parses, names no DataConfig
    assert engine.profile_of(make_app(tmp_path, stub, quantization=True)) == "yolo"
    assert engine.profile_of(make_app(tmp_path / "h", stub, quantization=False)) == "hera"


# The derive_tree.py and data.yaml the profile is read from are the app's (untrusted, possibly a fork's PR
# head). A file that is there but cannot be read safely or parsed fails the build (EXIT_PROFILE) with the
# reason; it is never guessed around, never followed out of the checkout and never read without a bound.
def test_a_derive_tree_that_is_not_python_fails_closed(tmp_path):
    with pytest.raises(engine.EngineError) as exc:
        engine.profile_of(make_app(tmp_path, "def broken(:\n"))
    assert exc.value.code == engine.EXIT_PROFILE and "kubecore/derive_tree.py" in str(exc.value)


# Deeply nested source makes CPython's parser raise MemoryError ("Parser stack overflowed") or
# RecursionError ("during ast construction") instead of SyntaxError; where it does depends on the
# Python version, so the parser is made to raise them here.
@pytest.mark.parametrize("error", [MemoryError("Parser stack overflowed"), RecursionError("ast construction")])
def test_a_derive_tree_too_deep_to_parse_fails_closed(tmp_path, monkeypatch, error):
    repo = make_app(tmp_path, DT_HERA)

    def deep(*args, **kwargs):
        raise error
    monkeypatch.setattr(engine.ast, "parse", deep)
    with pytest.raises(engine.EngineError) as exc:
        engine.profile_of(repo)
    assert exc.value.code == engine.EXIT_PROFILE and type(error).__name__ in str(exc.value)


def test_a_huge_derive_tree_is_refused_unread(tmp_path):
    repo = make_app(tmp_path, "x = 1\n" * (engine.APP_FILE_MAX_BYTES // 6 + 1))
    with pytest.raises(engine.EngineError, match="bytes") as exc:
        engine.profile_of(repo)
    assert exc.value.code == engine.EXIT_PROFILE


@pytest.mark.parametrize("target", ["/dev/zero", "outside"])
def test_a_symlinked_derive_tree_is_refused(tmp_path, target):
    repo = make_app(tmp_path)
    if target == "outside":
        target = str(tmp_path / "outside.py")
        (tmp_path / "outside.py").write_text(DT_HERA)
    os.makedirs(os.path.join(repo, "kubecore"))
    os.symlink(target, os.path.join(repo, "kubecore", "derive_tree.py"))
    with pytest.raises(engine.EngineError, match="not a regular file") as exc:
        engine.profile_of(repo)
    assert exc.value.code == engine.EXIT_PROFILE


def test_a_symlinked_kubecore_dir_is_refused(tmp_path):
    repo = make_app(tmp_path)
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "elsewhere" / "derive_tree.py").write_text(DT_HERA)
    os.symlink(str(tmp_path / "elsewhere"), os.path.join(repo, "kubecore"))
    with pytest.raises(engine.EngineError, match="not a regular file"):
        engine.profile_of(repo)


def test_a_kubecore_file_is_no_vendored_schema(tmp_path):
    repo = make_app(tmp_path)
    (tmp_path / "repo" / "kubecore").write_text("not a directory\n")
    assert engine.profile_of(repo) == "yolo"


def test_a_fifo_derive_tree_is_refused_not_waited_on(tmp_path):
    repo = make_app(tmp_path)
    os.makedirs(os.path.join(repo, "kubecore"))
    os.mkfifo(os.path.join(repo, "kubecore", "derive_tree.py"))
    with pytest.raises(engine.EngineError, match="not a regular file"):
        engine.profile_of(repo)


def test_a_symlinked_data_yaml_is_refused(tmp_path):
    repo = make_app(tmp_path)
    os.symlink("/dev/zero", os.path.join(repo, "config", "data.yaml"))
    with pytest.raises(engine.EngineError, match="config/data.yaml"):
        engine.profile_of(repo)


def test_the_cli_names_the_reason_and_exits_with_the_profile_code(tmp_path, capsys):
    repo = make_app(tmp_path, "def broken(:\n")
    assert engine.main(["context", "--context", write_context(tmp_path, BLOCK), "--repo", repo]) == engine.EXIT_PROFILE
    err = capsys.readouterr().err
    assert err.startswith("engine: FATAL: kubecore/derive_tree.py is not Python") and "rather than guess" in err


def test_a_profile_outside_the_engine_set_fails_closed(tmp_path, monkeypatch):
    monkeypatch.setattr(engine, "profile_of", lambda repo: "yolo-v9")
    with pytest.raises(engine.EngineError, match="yolo-v9") as exc:
        engine.engine_of(write_context(tmp_path, BLOCK), str(tmp_path))
    assert exc.value.code == engine.EXIT_PROFILE


@pytest.mark.parametrize("data_yaml, profile", [
    ('data:\n  ref: "main"\n', "hera"),      # the yolo schema would reject data.ref
    ('data:\n  source: "lakefs"\n', "yolo"),
    ("not: [valid\n", "yolo"),
])
def test_without_a_vendored_schema_a_data_ref_means_hera(tmp_path, data_yaml, profile):
    assert engine.profile_of(make_app(tmp_path, None, quantization=True, data_yaml=data_yaml)) == profile


def test_the_context_carries_the_vendored_profile(tmp_path):
    repo = make_app(tmp_path, DT_LEGACY_V1)
    assert engine.engine_of(write_context(tmp_path, BLOCK), repo)["profile"] == "legacy-v1"


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
