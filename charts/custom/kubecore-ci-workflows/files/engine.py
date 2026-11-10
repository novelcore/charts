"""Platform pipeline engine helpers for the ML CI (PRD-HPC-1461 D-79, F-50/F-51).

The platform renders, enhances and composes an ML app's pipeline with ONE engine release (the
`kaos-pipeline-engine` image and wheel of kaos-hpc-operator), never with the `kubecore/` copy the app
vendored, so a platform change needs no commit in a client repository. The operator writes
`engine: {version, image, wheel, wheelSha256, mode}` into the app's pipeline-context; this script is
the CI side of that contract:

  decide   ml-ci-build detect-steps and ml-ci-pr-render detect-engine: which engine renders this app,
           in which mode, with which schema profile, and what the vendored copy and compose Dockerfile
           look like. Prints one JSON object (the DECISION; the rest of the build reads only that).
  fetch    download the engine wheel, verify its sha256 and unzip it (never pip): the enhancer and the
           known-vendored table are read from the unpacked copy.
  record   what hera-enhance-commit writes into the app's pipeline-images: engine-mode, engine-version,
           engine-shadow, engine-vendored (the F-53 fleet count reads them).
  stamp    mark a rendered WorkflowTemplate with the engine that produced it.
  compare  parsed-YAML comparison of two renders (shadow mode): `equal` or `differs:<n>`.

Modes: `legacy` renders with the app's vendored code (today's path, unchanged), `shadow` renders both
ways and commits the legacy output, `engine` renders with the platform engine only. The mode in the
context is what the control plane asks for; `decide` HOLDS an app at `legacy` whenever the engine cannot
safely take it (no wheel pinned, no schema profile, an invalid block) and says why. A mode the engine can
take but cannot be set up for (the wheel does not download, its sha256 differs) FAILS the build: unknown
never silently becomes the old path.

Standard library + PyYAML only (the toolbox image has both). Every input from the app checkout is DATA:
files are hashed and parsed, never imported or executed. Run as `python3 -I`.
"""
import argparse
import hashlib
import json
import os
import re
import sys
import time
import tomllib
import urllib.parse
import urllib.request
import zipfile

import yaml

MODES = ("legacy", "shadow", "engine")
EXIT_INTEGRITY = 3   # the wheel is not the one the context pins: refuse, never fall back
EXIT_UNAVAILABLE = 4  # the engine could not be set up (download failed, wheel unreadable)
# The version is the operator build tag; it becomes a label value on the WorkflowTemplate and the
# builds, so it must be one (no "+", no "/").
VERSION_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
# registry/path:tag with a PINNED tag (never a digest-less floating one).
IMAGE_RE = re.compile(r"^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?(?:/[A-Za-z0-9._-]+)+:[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
# The compose-and-validate Dockerfile both templates have always carried (one blob in both histories).
# Anything else is a custom Dockerfile: its app stays legacy, an owner decision.
PRISTINE_COMPOSE_DOCKERFILES = frozenset({"8031ff2bde50732723622a26f2480d64e799bb77"})
COMPOSE_DOCKERFILE = "steps/compose_and_validate/Dockerfile"
VENDORED_MODULES = ("authoring.py", "derive_tree.py")
WHEEL_PREFIX = "kaos_pipeline_engine/"
KNOWN_VENDORED = "known-vendored.json"
FETCH_ATTEMPTS = 3
FETCH_PAUSE_SECONDS = 5
WHEEL_MAX_BYTES = 32 * 1024 * 1024
LOCAL_HOSTS = ("127.0.0.1", "localhost")


class EngineError(Exception):
    """A refusal that carries the process exit code."""

    def __init__(self, message, code):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------- inputs

def load_context(path):
    """The bare context of a pipeline-context.yaml (a ConfigMap whose data.context.yaml holds it).

    An unreadable or malformed file is {}: the caller then has no engine block and stays legacy.
    """
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


def engine_block(ctx):
    """The context's `engine:` block as a dict of strings, or {} when there is none."""
    block = ctx.get("engine")
    if not isinstance(block, dict):
        return {}
    return {k: ("" if v is None else str(v)) for k, v in block.items()}


def git_blob_sha(path):
    """The git blob sha1 of a file, computed here so no git runs in an untrusted checkout."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return ""
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()  # noqa: S324 - git's own object id


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
                      "failing the build rather than rendering with an engine that was not verified", EXIT_UNAVAILABLE)


def fetch_wheel(url, sha256, dest):
    """Download the wheel at url, verify sha256, unzip its kaos_pipeline_engine/ tree into dest.

    Returns the directory that holds `kubecore/` (the engine directory). No pip, no import. A sha256
    that differs raises EngineError(EXIT_INTEGRITY): the context pins that exact file.
    """
    if not SHA256_RE.match(sha256 or ""):
        raise EngineError(f"engine wheelSha256 is not a sha256 hex digest: {sha256!r}", EXIT_INTEGRITY)
    data = _read_url(url)
    got = hashlib.sha256(data).hexdigest()
    if got != sha256:
        raise EngineError(f"engine wheel sha256 mismatch: the context pins {sha256}, {url} is {got}; "
                          "refusing to render or enhance with it (failing closed)", EXIT_INTEGRITY)
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


def load_known(engine_dir):
    """known-vendored.json of the unpacked wheel ({} modules when the wheel has none)."""
    try:
        with open(os.path.join(engine_dir, KNOWN_VENDORED)) as f:
            return json.load(f).get("modules", {})
    except (OSError, ValueError):
        return {}


# ---------------------------------------------------------------- the decision

def holds(reason, **extra):
    """A legacy decision: the app stays on today's path and the reason says why."""
    return dict(blank(), reason=reason, **extra)


def blank():
    return {"engine_image": "", "version": "", "mode": "legacy", "requested_mode": "legacy", "profile": "",
            "vendored": "", "compose_dockerfile": "", "rebuild_compose": False, "reason": "",
            "wheel": "", "wheel_sha256": ""}


def template_hint(repo):
    """The schema profile the app's template implies, from its pyproject name: yolo or hera, else ""."""
    try:
        with open(os.path.join(repo, "pyproject.toml"), "rb") as f:
            name = str(tomllib.load(f).get("project", {}).get("name", "")).lower()
    except (OSError, tomllib.TOMLDecodeError):
        return ""
    if "yolo" in name:
        return "yolo"
    return "hera" if "hera" in name else ""


def vendored_state(repo, known):
    """(state, derive_tree profile entry or None): pristine, modified or absent, for the app's kubecore/."""
    if not os.path.isdir(os.path.join(repo, "kubecore")):
        return "absent", None
    state, derive = "pristine", None
    for module in VENDORED_MODULES:
        blob = git_blob_sha(os.path.join(repo, "kubecore", module))
        entry = (known.get(module) or {}).get(blob) if blob else None
        if module == "derive_tree.py":
            derive = entry
        if entry is None:
            state = "modified"
    return state, derive


def choose_profile(derive, repo):
    """(profile, why-not): the engine schema profile for this app, or "" with the reason it has none."""
    if derive is not None:
        if derive.get("engine_profile"):
            return derive["engine_profile"], ""
        return "", derive.get("no_profile_reason") or "its vendored derive_tree.py matches no engine schema profile"
    hint = template_hint(repo)
    if hint:
        return hint, ""
    return "", "its vendored derive_tree.py is unknown and the template cannot be told from pyproject.toml"


def recorded(images_path, key):
    """A key of the app's pipeline-images ConfigMap, "" when absent or unreadable."""
    try:
        with open(images_path) as f:
            return str(((yaml.safe_load(f) or {}).get("data") or {}).get(key) or "")
    except (OSError, yaml.YAMLError, AttributeError, TypeError):
        return ""


def decide(ctx_path, repo, images_path, work):
    """The decision for one build: see the module docstring. Never raises in legacy mode."""
    block = engine_block(load_context(ctx_path))
    if not block:
        return holds("NoEngineBlock: the pipeline context carries no engine block")
    requested = block.get("mode", "legacy")
    if requested not in MODES:
        return holds(f"InvalidMode: engine.mode {requested!r} is not one of {'|'.join(MODES)}")
    if requested == "legacy":
        return holds("ModeLegacy: the control plane renders this app with its vendored code")
    version, image = block.get("version", ""), block.get("image", "")
    wheel, wheel_sha = block.get("wheel", ""), block.get("wheelSha256", "")
    if not (VERSION_RE.match(version) and IMAGE_RE.match(image) and not image.endswith(":latest")):
        return holds(f"InvalidEngineBlock: engine.version {version!r} / engine.image {image!r} are not a pinned release",
                     requested_mode=requested)
    if not wheel or not wheel_sha:
        return holds("NoWheel: the pinned engine release has no wheel yet; held at legacy",
                     requested_mode=requested, version=version, engine_image=image)
    engine_dir = fetch_wheel(wheel, wheel_sha, work)  # raises: a mode we cannot set up fails the build
    known = load_known(engine_dir)
    state, derive = vendored_state(repo, known)
    profile, why_not = choose_profile(derive, repo)
    compose = _compose_state(repo)
    out = dict(blank(), requested_mode=requested, version=version, engine_image=image, wheel=wheel,
               wheel_sha256=wheel_sha, vendored=state, compose_dockerfile=compose)
    if not profile:
        return dict(out, reason=f"NoProfile: held at legacy, {why_not}")
    out["profile"] = profile
    if requested == "engine" and compose == "custom":
        return dict(out, reason="CustomComposeDockerfile: steps/compose_and_validate/Dockerfile is not the platform's; "
                                "held at legacy (owner decision)")
    out["mode"] = requested
    out["rebuild_compose"] = requested == "engine" and recorded(images_path, "engine-compose") != version
    out["reason"] = f"{requested.capitalize()}: engine {version}, profile {profile}, vendored {state}"
    return out


def _compose_state(repo):
    path = os.path.join(repo, COMPOSE_DOCKERFILE)
    if not os.path.isfile(path):
        return "absent"
    return "pristine" if git_blob_sha(path) in PRISTINE_COMPOSE_DOCKERFILES else "custom"


# ---------------------------------------------------------------- the record

# Keys of the app's {app}-pipeline-images this module owns (the render prunes every other unknown key).
RECORD_KEYS = ("engine-mode", "engine-version", "engine-shadow", "engine-vendored")
UNMANAGED = ("NoEngineBlock", "NotHera")  # decisions of an app the engine says nothing about: record nothing


def record(decision, shadow=""):
    """{"set": {key: value}, "clear": [key]} for pipeline-images, from the decision of this build.

    engine-mode is the EFFECTIVE mode (a held app records legacy). engine-version is the engine that
    produced the committed output, so it exists only in engine mode (in legacy and shadow the vendored
    code did). engine-shadow is the verdict of the comparison and only exists in shadow mode. An app whose
    context has no engine block is not touched at all.
    """
    if not decision or str(decision.get("reason", "")).startswith(UNMANAGED):
        return {"set": {}, "clear": []}
    mode = decision.get("mode", "legacy")
    want = {"engine-mode": mode}
    if mode == "engine":
        want["engine-version"] = decision.get("version", "")
    if mode == "shadow" and shadow:
        want["engine-shadow"] = shadow
    if mode in ("shadow", "engine") and decision.get("vendored"):
        want["engine-vendored"] = decision["vendored"]
    return {"set": want, "clear": [k for k in RECORD_KEYS if k not in want]}


# ---------------------------------------------------------------- stamp and compare

def stamp(wft_path, version):
    """Mark a rendered WorkflowTemplate with the engine that produced it (annotation and run label).

    The Workflow label platform.kubecore.io/engine is what the removal gate counts running Workflows by.
    """
    if not VERSION_RE.match(version):
        raise EngineError(f"engine version {version!r} is not a valid label value", EXIT_INTEGRITY)
    with open(wft_path) as f:
        wft = yaml.safe_load(f)
    wft.setdefault("metadata", {}).setdefault("annotations", {})["platform.kubecore.io/engine-version"] = version
    wft.setdefault("spec", {}).setdefault("workflowMetadata", {}).setdefault("labels", {})["platform.kubecore.io/engine"] = version
    with open(wft_path, "w") as f:
        yaml.dump(wft, f, default_flow_style=False, allow_unicode=True, sort_keys=False)


def flatten(node, path=""):
    """{json-pointer: leaf} of a parsed YAML document; empty containers are leaves."""
    if isinstance(node, dict) and node:
        out = {}
        for key in sorted(node, key=str):
            out.update(flatten(node[key], f"{path}/{key}"))
        return out
    if isinstance(node, list) and node:
        out = {}
        for i, item in enumerate(node):
            out.update(flatten(item, f"{path}/{i}"))
        return out
    if not path and node in (None, {}, []):
        return {}  # an empty (or missing) document has no paths
    return {path or "/": node}


def diff_paths(a, b):
    """The sorted paths at which two parsed documents differ (a value, or present on one side only)."""
    fa, fb = flatten(a), flatten(b)
    return sorted(p for p in set(fa) | set(fb) if fa.get(p, _MISSING) != fb.get(p, _MISSING))


_MISSING = object()


def _load_doc(path):
    if not os.path.exists(path):
        return {}
    with open(path) as f:
        return yaml.safe_load(f)


def compare(pairs, log=print):
    """`equal` or `differs:<n>` over (left, right) file pairs; a missing file is an empty document."""
    paths = []
    for left, right in pairs:
        paths += [f"{os.path.basename(left)}{p}" for p in diff_paths(_load_doc(left), _load_doc(right))]
    for p in paths[:25]:
        log(f"engine-shadow: differs at {p}")
    return "equal" if not paths else f"differs:{len(paths)}"


def write_record(args):
    """`record` command: decision from the environment, shadow verdict from a file, result to --out."""
    try:
        decision = json.loads(os.environ.get(args.decision_env) or "{}")
    except ValueError:
        decision = {}
    shadow = ""
    if args.shadow_file and os.path.exists(args.shadow_file):
        with open(args.shadow_file) as f:
            shadow = f.read().strip()
    with open(args.out, "w") as f:
        json.dump(record(decision if isinstance(decision, dict) else {}, shadow), f)


# ---------------------------------------------------------------- command line

def main(argv=None):
    parser = argparse.ArgumentParser(prog="engine.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--context", required=True)
    d.add_argument("--repo", required=True)
    d.add_argument("--images", default="")
    d.add_argument("--work", default="/tmp/kaos-engine-decide")
    f = sub.add_parser("fetch")
    f.add_argument("--wheel", required=True)
    f.add_argument("--sha256", required=True)
    f.add_argument("--dest", required=True)
    s = sub.add_parser("stamp")
    s.add_argument("--wft", required=True)
    s.add_argument("--version", required=True)
    r = sub.add_parser("record")
    r.add_argument("--decision-env", default="ENGINE_DECISION", help="env var holding the decision JSON")
    r.add_argument("--shadow-file", default="", help="file holding the shadow verdict, if any")
    r.add_argument("--out", required=True)
    c = sub.add_parser("compare")
    c.add_argument("files", nargs="+", help="left right [left right ...]")
    args = parser.parse_args(argv)
    try:
        if args.cmd == "decide":
            print(json.dumps(decide(args.context, args.repo, args.images, args.work), sort_keys=True))
        elif args.cmd == "fetch":
            print(fetch_wheel(args.wheel, args.sha256, args.dest))
        elif args.cmd == "stamp":
            stamp(args.wft, args.version)
        elif args.cmd == "record":
            write_record(args)
        else:
            if len(args.files) % 2:
                parser.error("compare takes pairs of files")
            print(compare(list(zip(args.files[::2], args.files[1::2])), log=lambda m: print(m, file=sys.stderr)))
    except EngineError as exc:
        print(f"engine: FATAL: {exc}", file=sys.stderr)
        return exc.code
    return 0


if __name__ == "__main__":
    sys.exit(main())
