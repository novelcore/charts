"""Platform pipeline engine helpers for the ML CI (PRD-HPC-1461 D-79, D-80).

The platform renders, enhances and composes an ML app's pipeline with ONE engine release (the
`kaos-pipeline-engine` image and wheel of kaos-hpc-operator), never with code an app carries. The
operator writes `engine: {version, image, wheel, wheelSha256}` into the app's gitops pipeline-context
(a `mode` key may still be there: ignored); this script is the CI side of that contract:

  context  ml-ci-build detect-steps and ml-ci-pr-render detect-engine: validate the engine block and
           pick the schema profile. Prints one JSON object (the ENGINE; the rest of the build reads only
           that). A missing or invalid block is an error: there is no other way to render.
  version  ml-ci-reconcile: the engine version the context names ("" when there is none).
  fetch    download the engine wheel, verify its sha256 and unzip it (never pip). A wheel that does not
           download or whose sha256 differs fails closed.
  stamp    mark a rendered WorkflowTemplate with the engine that produced it.

Standard library + PyYAML only (the toolbox image has both). Every input from the app checkout is DATA:
files are looked up, never imported or executed. Run as `python3 -I`.
"""
import argparse
import ast
import hashlib
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import zipfile

import yaml

EXIT_NO_ENGINE = 2    # the context names no usable engine
EXIT_INTEGRITY = 3    # the wheel is not the one the context pins: refuse
EXIT_UNAVAILABLE = 4  # the wheel could not be downloaded or read
# The version is the operator build tag; it becomes a label value on the WorkflowTemplate and the
# builds, so it must be one (no "+", no "/").
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
# registry/path:tag with a PINNED tag (never a floating one).
IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?(?:/[A-Za-z0-9._-]+)+:[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
WHEEL_PREFIX = "kaos_pipeline_engine/"
FETCH_ATTEMPTS = 3
FETCH_PAUSE_SECONDS = 5
WHEEL_MAX_BYTES = 32 * 1024 * 1024
LOCAL_HOSTS = ("127.0.0.1", "localhost")


class EngineError(Exception):
    """A refusal that carries the process exit code."""

    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------- the context

def load_context(path):
    """The bare context of a pipeline-context.yaml (a ConfigMap whose data.context.yaml holds it)."""
    try:
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
        if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
            data = doc.get("data") or {}
            key = "context.yaml" if "context.yaml" in data else next(iter(data), None)
            doc = yaml.safe_load(data[key]) if key else {}
        return doc if isinstance(doc, dict) else {}
    except (OSError, yaml.YAMLError, TypeError, AttributeError):
        return {}


# MIGRATION-REMOVE(after=every ML app on prod is recreated from a template without kubecore/ (PRD-HPC-1461 D-80),
# issue=novelcore/kubecore-operator#1830): _dataclass_fields, vendored_schema_profile, _config_data_has_ref and
# their use in profile_of. They keep apps that still carry the vendored kubecore/ rendering after the train.
def _dataclass_fields(tree, name):
    """{field: default node} of the first `class <name>` in a parsed module, None when there is none."""
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == name:
            return {st.target.id: st.value for st in node.body
                    if isinstance(st, ast.AnnAssign) and isinstance(st.target, ast.Name)}
    return None


def vendored_schema_profile(repo):
    """The schema profile of the app's vendored kubecore/derive_tree.py, None when it names none.

    The engine's four profiles are exactly the structured-config schemas the templates' derive_tree.py
    has had (kaos-hpc-operator engine/README.md "Schema profiles"), and the app's config/ was written
    against its own copy, so its DataConfig / QuantizationConfig fields say which one it needs:
      DataConfig.ref + .version                   legacy-v1  (both templates 2026-07-14 .. 2026-10-19)
      DataConfig.ref                              hera       (hera since 10-19, and yolo `main` since 10-19)
      no ref, QuantizationConfig.output_prefix    yolo-v1
      no ref, no output_prefix                    yolo
    The file is parsed (ast), never imported or executed. An app without the file, or whose file has no
    DataConfig (a later template that dropped the vendored copy), returns None.
    """
    path = os.path.join(repo, "kubecore", "derive_tree.py")
    try:
        with open(path, encoding="utf-8") as f:
            tree = ast.parse(f.read(), filename=path)
    except (OSError, SyntaxError, ValueError, UnicodeDecodeError):
        return None
    data = _dataclass_fields(tree, "DataConfig")
    if data is None:
        return None
    if "ref" in data:
        return "legacy-v1" if "version" in data else "hera"
    quant = _dataclass_fields(tree, "QuantizationConfig") or {}
    return "yolo-v1" if "output_prefix" in quant else "yolo"


def _config_data_has_ref(config):
    """True when config/data.yaml sets data.ref (a key the `yolo` schema rejects)."""
    try:
        with open(os.path.join(config, "data.yaml")) as f:
            doc = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return False
    section = doc.get("data", doc) if isinstance(doc, dict) else None
    return isinstance(section, dict) and "ref" in section


def profile_of(repo):
    """The schema profile the engine renders and composes the app with.

    First the app's vendored kubecore/derive_tree.py (vendored_schema_profile). Without one: `yolo`
    when config/ has a quantization section, else `hera`; a quantization app whose config/data.yaml
    still sets data.ref gets `hera` (the only current profile with DataConfig.ref). Before 0.13.3 only
    the fallback existed and every yolo app of the template's `main` (DataConfig.ref) failed to render
    with "Key 'ref' not in 'DataConfig'" (kubecore-operator#1830).
    """
    vendored = vendored_schema_profile(repo)
    if vendored:
        return vendored
    config = os.path.join(repo, "config")
    if os.path.isfile(os.path.join(config, "quantization.yaml")) or os.path.isdir(os.path.join(config, "quantization")):
        return "hera" if _config_data_has_ref(config) else "yolo"
    return "hera"


def engine_of(ctx_path, repo):
    """The validated engine of this build; raises EngineError(EXIT_NO_ENGINE) when there is none."""
    block = load_context(ctx_path).get("engine")
    if not isinstance(block, dict):
        raise EngineError("the pipeline context carries no engine block: the platform engine is the only way to "
                          "render an ML app", EXIT_NO_ENGINE)
    block = {k: ("" if v is None else str(v)) for k, v in block.items()}
    version, image = block.get("version", ""), block.get("image", "")
    wheel, sha = block.get("wheel", ""), block.get("wheelSha256", "")
    if not (VERSION_RE.match(version) and IMAGE_RE.match(image) and not image.endswith(":latest")):
        raise EngineError(f"engine.version {version!r} / engine.image {image!r} are not a pinned release", EXIT_NO_ENGINE)
    if not wheel or not SHA256_RE.match(sha):
        raise EngineError("engine.wheel / engine.wheelSha256 are missing or not a sha256 hex digest", EXIT_NO_ENGINE)
    return {"version": version, "image": image, "wheel": wheel, "wheel_sha256": sha, "profile": profile_of(repo)}


# ---------------------------------------------------------------- the engine wheel

def _read_url(url):
    parsed = urllib.parse.urlparse(url)
    local_http = parsed.scheme == "http" and parsed.hostname in LOCAL_HOSTS
    if parsed.scheme != "https" and not local_http:
        raise EngineError(f"engine wheel url must be https, got {url!r}", EXIT_UNAVAILABLE)
    last = None
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(url, timeout=60) as r:  # noqa: S310 - scheme checked above
                data = r.read(WHEEL_MAX_BYTES + 1)
            if len(data) > WHEEL_MAX_BYTES:
                raise EngineError(f"engine wheel {url} is larger than {WHEEL_MAX_BYTES} bytes", EXIT_UNAVAILABLE)
            return data
        except (OSError, ValueError) as exc:
            last = exc
            if attempt < FETCH_ATTEMPTS:
                time.sleep(FETCH_PAUSE_SECONDS)
    raise EngineError(f"engine wheel {url} could not be downloaded ({type(last).__name__}: {last}); "
                      "failing the build rather than enhancing with an engine that was not verified", EXIT_UNAVAILABLE)


def fetch_wheel(url, sha256, dest):
    """Download the wheel at url, verify sha256, unzip its kaos_pipeline_engine/ tree into dest.

    Returns the directory that holds `kubecore/` (the engine directory). No pip, no import.
    """
    if not SHA256_RE.match(sha256 or ""):
        raise EngineError(f"engine wheelSha256 is not a sha256 hex digest: {sha256!r}", EXIT_INTEGRITY)
    data = _read_url(url)
    got = hashlib.sha256(data).hexdigest()
    if got != sha256:
        raise EngineError(f"engine wheel sha256 mismatch: the context pins {sha256}, {url} is {got}; "
                          "refusing to enhance with it (failing closed)", EXIT_INTEGRITY)
    tmp = os.path.join(dest, ".wheel.whl")
    os.makedirs(dest, exist_ok=True)
    with open(tmp, "wb") as f:
        f.write(data)
    try:
        with zipfile.ZipFile(tmp) as zf:
            count = _unzip_engine(zf, dest)
    except zipfile.BadZipFile as exc:
        raise EngineError(f"engine wheel {url} is not a zip file: {exc}", EXIT_INTEGRITY) from exc
    finally:
        os.unlink(tmp)
    engine_dir = os.path.join(dest, "kaos_pipeline_engine")
    if count == 0 or not os.path.isfile(os.path.join(engine_dir, "kubecore", "__init__.py")):
        raise EngineError(f"engine wheel {url} holds no {WHEEL_PREFIX}kubecore/", EXIT_INTEGRITY)
    return engine_dir


def _unzip_engine(zf, dest):
    """Extract only kaos_pipeline_engine/ members; refuse absolute paths and `..` (zip slip)."""
    root = os.path.realpath(dest)
    count = 0
    for info in zf.infolist():
        name = info.filename
        if not name.startswith(WHEEL_PREFIX) or name.endswith("/") or "__pycache__" in name:
            continue
        target = os.path.realpath(os.path.join(dest, name))
        if os.path.isabs(name) or ".." in name.split("/") or not target.startswith(root + os.sep):
            raise EngineError(f"engine wheel member {name!r} escapes the unpack directory", EXIT_INTEGRITY)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with zf.open(info) as src, open(target, "wb") as out:
            out.write(src.read())
        count += 1
    return count


# ---------------------------------------------------------------- stamp

def stamp(wft_path, version):
    """Mark a rendered WorkflowTemplate with the engine that produced it (annotation and run label)."""
    if not VERSION_RE.match(version):
        raise EngineError(f"engine version {version!r} is not a valid label value", EXIT_INTEGRITY)
    with open(wft_path) as f:
        wft = yaml.safe_load(f)
    wft.setdefault("metadata", {}).setdefault("annotations", {})["platform.kubecore.io/engine-version"] = version
    wft.setdefault("spec", {}).setdefault("workflowMetadata", {}).setdefault("labels", {})["platform.kubecore.io/engine"] = version
    with open(wft_path, "w") as f:
        yaml.dump(wft, f, default_flow_style=False, allow_unicode=True, sort_keys=False)


# ---------------------------------------------------------------- command line

def main(argv=None):
    parser = argparse.ArgumentParser(prog="engine.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    c = sub.add_parser("context")
    c.add_argument("--context", required=True)
    c.add_argument("--repo", required=True)
    v = sub.add_parser("version")
    v.add_argument("--context", required=True)
    f = sub.add_parser("fetch")
    f.add_argument("--wheel", required=True)
    f.add_argument("--sha256", required=True)
    f.add_argument("--dest", required=True)
    s = sub.add_parser("stamp")
    s.add_argument("--wft", required=True)
    s.add_argument("--version", required=True)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "context":
            print(json.dumps(engine_of(args.context, args.repo), sort_keys=True))
        elif args.cmd == "version":
            block = load_context(args.context).get("engine")
            print(str(block.get("version") or "") if isinstance(block, dict) else "")
        elif args.cmd == "fetch":
            print(fetch_wheel(args.wheel, args.sha256, args.dest))
        else:
            stamp(args.wft, args.version)
    except EngineError as exc:
        print(f"engine: FATAL: {exc}", file=sys.stderr)
        return exc.code
    return 0


if __name__ == "__main__":
    sys.exit(main())
