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
  steps    the step table of a rendered WorkflowTemplate (PRD novelcore/kaos#1911): what each step reads and
           produces, as the engine wrote it on the compose step. A render without one is not from an engine
           on the step contract and fails closed.
  attempt  the `engine-attempt` record of a failed run; for an app refused for the step contract it also
           names the commit and the kaos-lib delivered.
  refused  ml-ci-reconcile: exit 0 when that record is a refusal of exactly this engine, commit and kaos-lib.

Standard library + PyYAML only (the toolbox image has both). Every input from the app checkout is DATA:
files are looked up, never imported or executed. Run as `python3 -I`.
"""
import argparse
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
EXIT_NO_CONTRACT = 5  # the render carries no step table: the engine is not on the step contract
COMPOSE_STEP = "compose-and-validate"
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
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


def profile_of(repo):
    """The schema profile: `yolo` when the app's config/ has a quantization section, else `hera`."""
    config = os.path.join(repo, "config")
    if os.path.isfile(os.path.join(config, "quantization.yaml")) or os.path.isdir(os.path.join(config, "quantization")):
        return "yolo"
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


# ---------------------------------------------------------------- the step table

def step_table(wft_path):
    """The step table of a rendered WorkflowTemplate: the compose step's argument after `--steps`, one
    object per step in pipeline order (name, kind, reads, inputs, needs, produces). It is the place to
    read what a pipeline declares without running pipeline.py again."""
    problem = "the compose step has no --steps argument"
    try:
        with open(wft_path) as f:
            templates = (yaml.safe_load(f) or {})["spec"]["templates"]
        args = next(t for t in templates if t.get("name") == COMPOSE_STEP)["container"]["args"]
        table = json.loads(args[args.index("--steps") + 1])
        if isinstance(table, list) and all(
                isinstance(s, dict) and isinstance(s.get("name"), str) and isinstance(s.get("inputs"), list)
                and all(isinstance(n, str) for n in s["inputs"]) for s in table):
            return table
        problem = "its step table is not a list of steps with a name and inputs"
    except (OSError, yaml.YAMLError, KeyError, TypeError, IndexError, StopIteration, ValueError) as exc:
        problem = f"{problem} ({type(exc).__name__})"
    raise EngineError(f"the rendered pipeline carries no step table: {problem}. The pipeline engine this "
                      "context pins is not on the step contract; nothing is committed", EXIT_NO_CONTRACT)


# ---------------------------------------------------------------- engine-attempt

def _kaos_lib_key(ctx):
    lib = ctx.get("kaosLib")
    spec = str((lib if isinstance(lib, dict) else {}).get("spec") or "").strip()
    return hashlib.sha256(spec.encode()).hexdigest()[:12]


def _version(ctx):
    block = ctx.get("engine")
    return str(block.get("version") or "") if isinstance(block, dict) else ""


def attempt(ctx_path, now=None, refused_commit=""):
    """The `engine-attempt` record of a run that failed in the engine: `<engine version>@<epoch>`, read by
    ml-ci-reconcile's one-attempt-per-hour guard. An app refused for the step contract (it must change,
    trying again cannot help) records `<engine version>@<epoch>@<commit>@<kaos-lib>`: the commit that was
    refused and the first 12 hex of the sha256 of the kaos-lib spec the context delivered."""
    ctx = load_context(ctx_path)
    value = f"{_version(ctx) or 'unknown'}@{int(time.time() if now is None else now)}"
    if refused_commit:
        value += f"@{refused_commit}@{_kaos_lib_key(ctx)}"
    return value


def refused(value, ctx_path, commit):
    """True when value records a refusal of exactly this context's engine and kaos-lib and this commit:
    nothing a new attempt reads has changed. Anything else, an unreadable context included, is False."""
    parts = str(value).split("@")
    ctx = load_context(ctx_path)
    version = _version(ctx)
    return (len(parts) == 4 and bool(version) and parts[0] == version and bool(COMMIT_RE.match(parts[2]))
            and parts[2] == commit and parts[3] == _kaos_lib_key(ctx))


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
    t = sub.add_parser("steps")
    t.add_argument("--wft", required=True)
    a = sub.add_parser("attempt")
    a.add_argument("--context", required=True)
    a.add_argument("--refused-commit", default="")
    r = sub.add_parser("refused")
    r.add_argument("--context", required=True)
    r.add_argument("--commit", required=True)
    r.add_argument("--attempt", required=True)
    args = parser.parse_args(argv)
    try:
        if args.cmd == "context":
            print(json.dumps(engine_of(args.context, args.repo), sort_keys=True))
        elif args.cmd == "version":
            print(_version(load_context(args.context)))
        elif args.cmd == "fetch":
            print(fetch_wheel(args.wheel, args.sha256, args.dest))
        elif args.cmd == "steps":
            print(json.dumps(step_table(args.wft), separators=(",", ":")))
        elif args.cmd == "attempt":
            print(attempt(args.context, refused_commit=args.refused_commit))
        elif args.cmd == "refused":
            return 0 if refused(args.attempt, args.context, args.commit) else 1
        else:
            stamp(args.wft, args.version)
    except EngineError as exc:
        print(f"engine: FATAL: {exc}", file=sys.stderr)
        return exc.code
    return 0


if __name__ == "__main__":
    sys.exit(main())
