"""Golden harness for the connection envFrom renderer (kaos PRD 1034, CON-02) and for what the chart
reads of a rendered pipeline (PRD novelcore/kaos#1911: the step table, the dataset pickers).

The fixtures are two chart-owned apps on the step contract (fixtures/apps/hera, fixtures/apps/yolo), each
rendered ONCE by the platform pipeline engine into fixtures/hera-raw/ (`write-raw`), and enhanced by the
same engine against fixture contexts into golden/ (`write-goldens`). The engine is `engine/` of
kaos-io/kaos-hpc-operator at ENGINE_REF, fetched and unpacked here; set ENGINE_DIR to a local `engine/`
directory instead. The chart itself enhances with the engine wheel (kubecore-ci-workflows.platformEnhance),
which tests/engine-ci and tests/untrusted-workspace exercise.

Fixtures hold PLACEHOLDER values only; nothing captured from a real tenant.

CLI:
  harness.py write-raw        render fixtures/apps/* (needs ENGINE_PYTHON: a python with the engine's
                              libraries, engine/requirements.txt)
  harness.py write-goldens    enhance every fixture; also the step-token goldens
  harness.py diff-hera --raw R --context C [--catalog K] --ref-a SHA --ref-b SHA
"""
import argparse
import copy
import difflib
import io
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
from dataclasses import dataclass
from typing import Callable, Optional

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
CHART = os.path.abspath(os.path.join(HERE, "..", ".."))
FIX = os.path.join(HERE, "fixtures")
GOLDEN = os.path.join(HERE, "golden")

# The engine the raw fixtures and the goldens are made with: kaos-io/kaos-hpc-operator, the commit of the
# engine on the step contract (branch prd1911/engine-contract at the time of writing; move it to the merged
# commit, then to each engine release the chart is pinned with, and rewrite the raw fixtures and the goldens).
ENGINE_REPO = "kaos-io/kaos-hpc-operator"
ENGINE_REF = "4ccc9426255588ed39a246d3b73fb89d9dd65acc"
# The step the engine names a step's HPC (Slurm) variant after.
HPC_TWIN = "hpc-follower"


@dataclass(frozen=True)
class Fixture:
    kind: str            # "hera"
    context: str         # path to a bare context
    source: str          # raw WFT path
    app: str
    project: str
    catalog: Optional[str] = None


def _fx(kind, app, project, source, catalog=None):
    return Fixture(kind, os.path.join(FIX, "contexts", f"{app}.yaml"),
                   os.path.join(FIX, source), app, project,
                   os.path.join(FIX, catalog) if catalog else None)


_YOLO = "hera-raw/yolo-app.yaml"
_HERA = "hera-raw/hera-app.yaml"
# fixture app -> (its raw render, the schema profile the chart would pick for it)
APPS = {"hera": (_HERA, "hera"), "yolo": (_YOLO, "yolo")}

FIXTURES = {
    "yolo-pipeline": _fx("hera", "yolo-pipeline", "vision", _YOLO),
    "data-clean": _fx("hera", "data-clean", "vision", _HERA),
    "dataset-gen-service": _fx("hera", "dataset-gen-service", "vision", _HERA),
    "yolo-vision-pipeline": _fx("hera", "yolo-vision-pipeline", "data-room", _YOLO),
    "yolo-meluxina-poc": _fx("hera", "yolo-meluxina-poc", "data-room", _YOLO),
    "demo": _fx("hera", "demo", "data-room", _HERA),
}

CONNECTIONS = [
    {"name": "inference", "envPrefix": "INFERENCE", "configMapName": "cm-inference", "environment": "runtime"},
    {"name": "features", "envPrefix": "FEATURES", "configMapName": "cm-features"},
    {"name": "other-env", "envPrefix": "OTHER_ENV", "configMapName": "cm-other", "environment": "train"},
]
EXPECTED_ENV_FROM = [
    {"configMapRef": {"name": "cm-inference", "optional": True}},
    {"configMapRef": {"name": "cm-features", "optional": True}},
]


# ── the engine ──────────────────────────────────────────────────────────────

_ENGINE_CACHE = {}
_ENGINE_FAIL = {}
_SHA_RE = re.compile(r"[0-9a-f]{40}")


def fetch_engine(ref: str, repo: str = ENGINE_REPO) -> str:
    """The `engine/` directory (it holds kubecore/ and kaos_engine/) of `repo`@`ref`, or $ENGINE_DIR unchanged."""
    if os.environ.get("ENGINE_DIR"):
        return os.environ["ENGINE_DIR"]
    if not _SHA_RE.fullmatch(ref):
        raise ValueError(f"engine ref must be a 40-char lowercase hex sha, got {ref!r}")
    key = (repo, ref)
    if key in _ENGINE_CACHE:
        return _ENGINE_CACHE[key]
    if key in _ENGINE_FAIL:  # fail fast: one fetch attempt per session, failures included
        raise RuntimeError(f"engine fetch for {repo}@{ref} already failed: {_ENGINE_FAIL[key]}")
    try:
        root = _fetch_engine(repo, ref)
    except Exception as e:
        _ENGINE_FAIL[key] = repr(e)
        raise
    _ENGINE_CACHE[key] = root
    return root


def _fetch_engine(repo: str, ref: str) -> str:
    req = urllib.request.Request(f"https://api.github.com/repos/{repo}/tarball/{ref}",
                                 headers={"Accept": "application/vnd.github+json", "User-Agent": "kubecore-ci"})
    tok = os.environ.get("GITHUB_TOKEN", "")
    if tok:
        req.add_header("Authorization", f"Bearer {tok}")
    with urllib.request.urlopen(req, timeout=60) as r:
        tb = tarfile.open(fileobj=io.BytesIO(r.read()), mode="r:gz")
    root = tempfile.mkdtemp(prefix=f"engine-{ref[:12]}-")
    n = 0
    for m in tb.getmembers():
        parts = m.name.split("/", 1)
        if len(parts) < 2 or not parts[1].startswith(("engine/kubecore/", "engine/kaos_engine/")):
            continue
        rel = parts[1][len("engine/"):]
        if "__pycache__" in rel or "/local-dev/" in rel:
            continue
        if ".." in rel.split("/") or os.path.isabs(rel):
            raise RuntimeError(f"unsafe tar member path {m.name!r}")
        out = os.path.join(root, rel)
        if m.isdir():
            os.makedirs(out, exist_ok=True)
        elif m.isfile():
            os.makedirs(os.path.dirname(out), exist_ok=True)
            with tb.extractfile(m) as src, open(out, "wb") as f:
                f.write(src.read())
            n += 1
    if n == 0:
        raise RuntimeError(f"no engine/kubecore files in {repo}@{ref}")
    return root


def render_raw(engine_dir: str, app: str) -> str:
    """Render fixtures/apps/<app> with the engine runner, as hera-render does; returns the raw WFT text."""
    python = os.environ.get("ENGINE_PYTHON")
    if not python:
        raise RuntimeError("write-raw needs ENGINE_PYTHON: a python with the engine's libraries "
                           "(kaos-hpc-operator engine/requirements.txt)")
    source, profile = APPS[app]
    with tempfile.TemporaryDirectory() as td:
        repo = os.path.join(td, "repo")
        shutil.copytree(os.path.join(FIX, "apps", app), repo)
        cmd = [python, "-m", "kaos_engine.render", "pipeline.py", "--repo", repo, "--profile", profile,
               "--engine", engine_dir]
        p = subprocess.run(cmd, cwd=engine_dir, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"kaos_engine.render exited {p.returncode}\nstderr:\n{p.stderr}")
        with open(os.path.join(repo, "out", "raw-workflow-template.yaml")) as f:
            return f.read()


def enhance_hera(engine_dir: str, raw_path: str, ctx: dict, catalog_path: Optional[str]) -> str:
    with tempfile.TemporaryDirectory() as td:
        ctx_path = os.path.join(td, "context.yaml")
        with open(ctx_path, "w") as f:
            yaml.safe_dump(ctx, f, sort_keys=False)
        out_path = os.path.join(td, "workflow-template.yaml")
        cmd = [sys.executable, "-m", "kubecore.enhance", "--raw", os.path.abspath(raw_path), "--context", ctx_path]
        if catalog_path:
            cmd += ["--catalog", os.path.abspath(catalog_path)]
        cmd += ["--output", out_path]
        p = subprocess.run(cmd, cwd=engine_dir, capture_output=True, text=True)
        if p.returncode != 0:
            raise RuntimeError(f"kubecore.enhance exited {p.returncode}\nstderr:\n{p.stderr}")
        with open(out_path) as f:
            return f.read()


# ── fixtures ────────────────────────────────────────────────────────────────

def with_connections(ctx: dict, connections: Optional[list]) -> dict:
    out = copy.deepcopy(ctx)
    if connections is None:
        out.pop("connections", None)
    else:
        out["connections"] = copy.deepcopy(connections)
    return out


def _load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def render(name: str, connections: Optional[list], *, ctx_override: Optional[Callable[[dict], dict]] = None) -> str:
    fx = FIXTURES[name]
    ctx = with_connections(_load(fx.context), connections)
    if ctx_override is not None:
        ctx = ctx_override(ctx)
    return enhance_hera(fetch_engine(ENGINE_REF), fx.source, ctx, fx.catalog)


def raw_container_names(name: str) -> set:
    """Names of the container templates in the fixture's raw (pre-enhancer) WFT: the user steps."""
    raw = _load(FIXTURES[name].source)
    return {t["name"] for t in raw["spec"]["templates"] if "container" in t}


def golden_path(kind: str, name: str) -> str:
    return os.path.join(GOLDEN, kind, f"{name}.yaml")


def golden_text(kind: str, name: str) -> str:
    with open(golden_path(kind, name)) as f:
        return f.read()


# ── CLI ─────────────────────────────────────────────────────────────────────

def _bare_context(path: str) -> dict:
    d = _load(path)
    if isinstance(d, dict) and d.get("kind") == "ConfigMap":
        return yaml.safe_load(d["data"]["context.yaml"])
    return d


def _udiff(a: str, b: str, la: str, lb: str) -> int:
    if a == b:
        print("identical")
        return 0
    sys.stdout.writelines(difflib.unified_diff(a.splitlines(True), b.splitlines(True), la, lb))
    return 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("write-raw")
    sub.add_parser("write-goldens")
    h = sub.add_parser("diff-hera")
    h.add_argument("--raw", required=True)
    h.add_argument("--context", required=True)
    h.add_argument("--catalog")
    h.add_argument("--ref-a", required=True)
    h.add_argument("--ref-b", required=True)
    a = ap.parse_args(argv)

    if a.cmd == "write-raw":
        for app, (source, _) in APPS.items():
            text = render_raw(fetch_engine(ENGINE_REF), app)
            with open(os.path.join(FIX, source), "w") as f:
                f.write(text)
            print(f"wrote fixtures/{source}")
        return 0
    if a.cmd == "write-goldens":
        for name, fx in FIXTURES.items():
            text = render(name, None)
            p = golden_path(fx.kind, name)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w") as f:
                f.write(text)
            print(f"wrote {os.path.relpath(p, HERE)}")
        print("now rewrite the step-token goldens: UPDATE_GOLDEN=1 RENDERED=<rendered chart> pytest test_step_token.py")
        return 0
    if a.cmd == "diff-hera":
        if os.environ.get("ENGINE_DIR"):
            print("diff-hera: ENGINE_DIR is set, so both refs resolve to the same directory and the "
                  "diff would be vacuous; unset ENGINE_DIR", file=sys.stderr)
            return 2
        if a.ref_a == a.ref_b:
            print(f"diff-hera: --ref-a and --ref-b are both {a.ref_a!r}; nothing to compare", file=sys.stderr)
            return 2
    ctx = _bare_context(a.context)
    if a.cmd == "diff-hera":
        ta = enhance_hera(fetch_engine(a.ref_a), a.raw, ctx, a.catalog)
        tb = enhance_hera(fetch_engine(a.ref_b), a.raw, ctx, a.catalog)
        return _udiff(ta, tb, a.ref_a, a.ref_b)
    return 2


if __name__ == "__main__":
    sys.exit(main())
