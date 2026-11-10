"""Fixtures for tests/engine-ci/run.sh: a fake engine wheel, an app checkout and a pipeline context.

  fixture.py wheel OUT.whl          a wheel whose enhancer is a stand-in (see ENHANCE_PY), prints its sha256
  fixture.py app DIR [--yolo] [--edited authoring|derive_tree] [--compose pristine|custom|none]
  fixture.py context OUT [--mode M] [--wheel URL] [--sha256 H] [--no-engine]
"""
import argparse
import hashlib
import io
import json
import os
import sys
import zipfile

import yaml

HERE = os.path.dirname(os.path.abspath(__file__))
HERA_DERIVE, YOLO_DERIVE, AUTHORING = b"# hera derive_tree\n", b"# yolo derive_tree\n", b"# authoring\n"


def blob(data):
    return hashlib.sha1(b"blob %d\0" % len(data) + data).hexdigest()


KNOWN = {"modules": {
    "derive_tree.py": {blob(HERA_DERIVE): {"engine_profile": "hera", "profile": "hera"},
                       blob(YOLO_DERIVE): {"engine_profile": "yolo", "profile": "yolo"}},
    "authoring.py": {blob(AUTHORING): {"profile": "ambiguous"}}}}

# A stand-in for kubecore.enhance of the ENGINE wheel: copies the raw WFT and marks who enhanced it.
# FIXTURE_ENGINE_DIFFERS=1 makes its output differ from the legacy stand-in's (shadow: differs).
ENHANCE_PY = '''import argparse, os, yaml
p = argparse.ArgumentParser()
for a in ("--raw", "--context", "--output"):
    p.add_argument(a, required=True)
p.add_argument("--catalog", default="")
p.add_argument("--helper-configmap", default="")
args = p.parse_args()
wft = yaml.safe_load(open(args.raw))
wft.setdefault("metadata", {}).setdefault("annotations", {})["enhanced-by"] = "platform"
if os.environ.get("FIXTURE_ENGINE_DIFFERS") == "1":
    wft["metadata"]["annotations"]["engine-only"] = "1"
    wft["spec"]["entrypoint"] = "engine-main"
yaml.safe_dump(wft, open(args.output, "w"))
open(os.environ["FIXTURE_LOG"], "a").write("engine-enhance ran\\n")
'''


def wheel(out):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("kaos_pipeline_engine/kubecore/__init__.py", "")
        zf.writestr("kaos_pipeline_engine/kubecore/enhance.py", ENHANCE_PY)
        zf.writestr("kaos_pipeline_engine/known-vendored.json", json.dumps(KNOWN))
        zf.writestr("kaos_engine/render.py", "")
    with open(out, "wb") as f:
        f.write(buf.getvalue())
    print(hashlib.sha256(buf.getvalue()).hexdigest())


def app(args):
    d = args.dir
    os.makedirs(os.path.join(d, "kubecore"), exist_ok=True)
    open(os.path.join(d, "kubecore", "derive_tree.py"), "wb").write(YOLO_DERIVE if args.yolo else HERA_DERIVE)
    open(os.path.join(d, "kubecore", "authoring.py"), "wb").write(AUTHORING)
    if args.edited:
        open(os.path.join(d, "kubecore", f"{args.edited}.py"), "w").write("raise SystemExit('PWNED')\n")
    if args.compose != "none":
        os.makedirs(os.path.join(d, "steps", "compose_and_validate"), exist_ok=True)
        src = os.path.join(HERE, "compose.Dockerfile") if args.compose == "pristine" else None
        data = open(src, "rb").read() if src else b"FROM python:3.11-slim\nRUN echo custom\n"
        open(os.path.join(d, "steps", "compose_and_validate", "Dockerfile"), "wb").write(data)


def context(args):
    ctx = {"project": "proj", "app": "app1"}
    if not args.no_engine:
        block = {"version": "v0.9.0", "image": "reg.example/kaos-pool/kaos-pipeline-engine:v0.9.0", "mode": args.mode}
        if args.wheel:
            block.update(wheel=args.wheel, wheelSha256=args.sha256)
        ctx["engine"] = block
    doc = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "app1-pipeline-context"},
           "data": {"context.yaml": yaml.safe_dump(ctx)}}
    yaml.safe_dump(doc, open(args.out, "w"))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    w = sub.add_parser("wheel"); w.add_argument("out")
    a = sub.add_parser("app"); a.add_argument("dir"); a.add_argument("--yolo", action="store_true")
    a.add_argument("--edited", choices=["authoring", "derive_tree"]); a.add_argument("--compose", default="pristine", choices=["pristine", "custom", "none"])
    c = sub.add_parser("context"); c.add_argument("out"); c.add_argument("--mode", default="engine")
    c.add_argument("--wheel", default=""); c.add_argument("--sha256", default=""); c.add_argument("--no-engine", action="store_true")
    args = p.parse_args()
    {"wheel": lambda: wheel(args.out), "app": lambda: app(args), "context": lambda: context(args)}[args.cmd]()


if __name__ == "__main__":
    sys.exit(main())
