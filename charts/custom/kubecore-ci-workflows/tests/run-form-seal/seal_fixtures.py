"""Inputs of the run-form seal for the tests (PRD novelcore/kaos#1533 F-21/F-22, contract §3.2).

`Case` builds the six inputs of `run_form.py seal` in a temp directory from plain dicts that a test can
change before it runs the seal, and `Case.run()` runs the real file with `python3 -I`, as the chart does.
The data is shaped like the engine's: the step table and class offers of tests/matrix-pipeline, the
compute classes of tests/connections/fixtures/contexts/yolo-meluxina-poc.yaml. Stdlib plus PyYAML.
"""
import copy
import json
import os
import stat
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
CHART = HERE.parent.parent
SEAL = CHART / "files" / "run_form.py"

COMMIT = "0123456789abcdef0123456789abcdef01234567"
COMMIT2 = "fedcba9876543210fedcba9876543210fedcba98"
ENGINE = "0.17.0"
NAMESPACE = "PLACEHOLDER-vision-runtime"
MARKER = "SECRET-MARKER-9f3a"  # planted in author data; it must never reach stderr

CPU_REFUSED = {
    "gpu-t4": ["it is a GPU machine and the step does not declare gpu=True",
               "Add gpu=True to the step in pipeline.py to run it on a GPU machine."],
    "meluxina-gpu": ["it is a GPU machine and the step does not declare gpu=True",
                     "Add gpu=True to the step in pipeline.py to run it on a GPU machine."],
}


def context(hpc=True):
    cls = lambda name, tier, mt, desc, cpu, mem, **kw: {  # noqa: E731
        "name": name, "tier": tier, "machineType": mt, "description": desc,
        "allocatable": {"cpu": cpu, "memoryGiB": mem}, "maxNodeCount": 4, "diskSizeGb": 50,
        "tolerationKey": "platform.kubecore.io/ml-workload", "tolerationValue": tier, **kw}
    cpu = cls("cpu-standard", "cpu", "n2-standard-8", "n2-standard-8 (8 vCPU, 32 GiB)", 7, 27)
    gpu = cls("gpu-t4", "gpu", "n1-standard-8", "n1-standard-8 + 1x T4", 7, 25,
              guestAccelerator={"type": "nvidia-tesla-t4", "count": 1})
    ctx = {
        "project": "vision", "app": "demo", "pipelineName": "demo", "namespace": NAMESPACE,
        "lakefs": {"endpoint": "http://lakefs.internal.invalid", "adminSecret": "PLACEHOLDER"},
        "computeClasses": {
            "cpu": cpu, "gpu": gpu,
            "all": [cpu, cls("kubecorecpu", "cpu", "e2-standard-8", "e2-standard-8 + 200GiB", 7, 27), gpu]},
        "hpc": {"enabled": False, "provider": "meluxina"},
    }
    if hpc:
        ctx["hpc"] = {
            "enabled": True, "provider": "meluxina", "account": "PLACEHOLDER-account",
            "user": "PLACEHOLDER-user", "scratch": "/project/scratch/PLACEHOLDER",
            "classes": [
                {"name": "meluxina-gpu", "tier": "gpu", "partition": "gpu", "qos": "default", "gpus": 4,
                 "cpus": 128, "memoryGiB": 512, "maxTimeLimitMinutes": 2880,
                 "description": "4x A100-40GB, 2x EPYC 7452, 512 GB"},
                {"name": "meluxina-cpu", "tier": "cpu", "partition": "cpu", "qos": "default", "gpus": 0,
                 "cpus": 128, "memoryGiB": 512, "description": "2x EPYC 7452, 128 cores, 512 GB"}]}
    return ctx


STEPS = [
    {"name": "prep", "kind": "transform", "reads": [], "inputs": ["dataset"], "needs": [],
     "produces": [{"name": "cleaned", "type": "dataset"}]},
    {"name": "train", "kind": "train", "reads": [], "inputs": [], "needs": ["prep"],
     "produces": [{"name": "champion", "type": "model"}], "matrix": {"seed": [1, 2, 3]}},
    {"name": "evaluate", "kind": "evaluate", "reads": [], "inputs": [], "needs": ["train"],
     "produces": [{"name": "metrics", "type": "artifact"}], "when_text": 'optimizer  ==   "adam"'},
    {"name": "report", "kind": "publish", "reads": [], "inputs": [], "needs": ["evaluate"],
     "produces": [{"name": "summary", "type": "artifact"}], "when_text": "prep.ok == true"},
]

# (name, value, enum or None, role, step). Argo order, as the engine's order_form leaves it.
PARAMS = [
    ("pipeline-info", "The defaults run as they are: press Submit.", None, "info", None),
    ("experiment-name", "my-experiment-v1", None, "experiment", None),
    ("experiment-description", "", None, "experiment", None),
    ("optimizer", "adam", ["adam", "sgd", "lion"], "setting", None),
    ("learning-rate", "0.001", None, "setting", None),
    ("momentum", "0.9", None, "setting", None),
    ("epochs", "10", None, "setting", None),
    ("use-aug", "false", None, "setting", None),
    ("hf-token", "", None, "setting", None),
    ("dataset", "dataset-default@latest", None, "input", None),
    ("prep-class", "cpu-standard", ["cpu-standard", "kubecorecpu"], "class", "prep"),
    ("prep-walltime", "1h", None, "walltime", "prep"),
    ("train-class", "cpu-standard", ["cpu-standard", "kubecorecpu", "meluxina-cpu"], "class", "train"),
    ("train-walltime", "2h", None, "walltime", "train"),
    ("train-checkpoint-every", "30m", None, "checkpoint-every", "train"),
    ("train-matrix", '[{"seed":1},{"seed":2},{"seed":3}]', None, "matrix", "train"),
    ("train-parallel", "4", None, "parallel", "train"),
    ("evaluate-class", "cpu-standard", ["cpu-standard", "kubecorecpu", "meluxina-cpu"], "class", "evaluate"),
    ("evaluate-walltime", "4h", None, "walltime", "evaluate"),
    ("report-walltime", "4h", None, "walltime", "report"),
    ("reuse-from-run", "", None, "reuse", None),
    ("start-from-step", "", None, "start", None),
    ("promote-cleaned", "false", ["false", "true"], "promote", "prep"),
    ("config", "", None, "advanced", None),
]

RAW = {
    "version": 1,
    "types": {"experiment-name": "string", "learning-rate": "number", "momentum": "number",
              "epochs": "integer", "use-aug": "boolean", "hf-token": "string"},
    "optionDefaults": {"optimizer": {
        "adam": {"learning-rate": "0.001"},
        "sgd": {"learning-rate": "0.1", "momentum": "0.9", "hf-token": "x", "image-train": "evil:latest"},
        "lion": {}}},
    "leafOptions": {
        "learning-rate": {"group": "optimizer", "options": ["adam", "sgd"]},
        "momentum": {"group": "optimizer", "options": ["sgd"]},
        "hf-token": {"group": "optimizer", "options": ["adam", "sgd", "lion"]}},
}


def offers(hpc=True):
    prep = {"offered": ["cpu-standard", "kubecorecpu"],
            "refused": {**CPU_REFUSED, **({"meluxina-cpu": ["a step that produces a dataset runs on the "
                                                            "cluster for now", "Choose one of: cpu-standard, kubecorecpu."]}
                                          if hpc else {})}}
    rest = {"offered": ["cpu-standard", "kubecorecpu"] + (["meluxina-cpu"] if hpc else []),
            "refused": dict(CPU_REFUSED)}
    return {"prep": prep, "train": rest, "evaluate": rest, "report": None}


def wft(hpc=True):
    params = []
    for name, value, enum, _role, _step in PARAMS:
        p = {"name": name, "value": value, "description": f"description of {name}"}
        if enum:
            p["enum"] = list(enum)
        params.append(p)
    # the hpc=False context offers no HPC class: the Argo enum agrees
    if not hpc:
        for p in params:
            if p.get("enum") and "meluxina-cpu" in p["enum"]:
                p["enum"].remove("meluxina-cpu")
    names = ["main", "compose-and-validate", "kaos-promote", "kaos-gather-train", "kaos-matrix-train",
             "hpc-follower", "prep", "train", "evaluate", "report"]
    return {
        "apiVersion": "argoproj.io/v1alpha1", "kind": "WorkflowTemplate",
        "metadata": {
            "name": "demo-pipeline", "namespace": NAMESPACE,
            "labels": {"platform.kubecore.io/project": "vision", "platform.kubecore.io/app": "demo",
                       "platform.kubecore.io/managed-by": "kubecore-ci"},
            "annotations": {"platform.kubecore.io/generated-by": "ml-ci-build/hera-render",
                            "platform.kubecore.io/cost-tracking": "enabled",
                            "platform.kubecore.io/engine-version": ENGINE}},
        "spec": {
            "entrypoint": "main",
            "workflowMetadata": {"labels": {"platform.kubecore.io/engine": ENGINE}},
            "arguments": {"parameters": params},
            "templates": [{"name": n, "container": {"image": "alpine"}} for n in names]}}


def form_data(hpc=True):
    rank = {}
    for i, (name, _v, _e, role, step) in enumerate(PARAMS):
        rank[name] = {"role": role, "step": step, "sort": [i, 0]}
    return {"version": 1, "offers": offers(hpc), "pinned": {"report": "cpu-standard"},
            "rendered": [n for n, *_ in PARAMS if n not in ("pipeline-info",)],
            "rank": rank, "raw": json.dumps(RAW, sort_keys=True, separators=(",", ":"))}


class Result:
    def __init__(self, rc, out, err, before, after, case):
        self.rc, self.out, self.err, self.before, self.after, self.case = rc, out, err, before, after, case

    @property
    def unchanged(self):
        return self.before == self.after

    def annotation(self):
        return json.loads(self.case.load_wft()["metadata"]["annotations"]["ui.kubecore.io/run-form"])

    def gate_lines(self):
        return [ln for ln in self.err.splitlines() if ln.startswith("GATE FAIL: run form: ")]


class Case:
    """The inputs of one seal run. Change `wft`, `ctx`, `steps`, `form_data`, `form_yaml` before `run()`."""

    def __init__(self, hpc=True, root=None):
        self.root = Path(os.path.realpath(root or tempfile.mkdtemp(prefix="run-form-seal-")))
        self.workspace = self.root / "workspace"
        self.out = self.workspace / "out"
        self.config = self.workspace / "repo" / "config"
        for d in (self.out, self.config):
            d.mkdir(parents=True, exist_ok=True)
        self.wft_path = self.out / "workflow-template.yaml"
        self.hpc = hpc
        self.wft = wft(hpc)
        self.ctx = context(hpc)
        self.steps = copy.deepcopy(STEPS)
        self.form_data = form_data(hpc)
        self.form_yaml = None
        self.previous = None
        self.engine = ENGINE
        self.commit = COMMIT
        self.raw_texts = {}  # file name -> text that replaces the serialised input

    def raw(self, mutate):
        """Change the raw form (the `raw` member of form-data) as a dict and write it back as text."""
        r = copy.deepcopy(RAW)
        mutate(r)
        self.form_data["raw"] = json.dumps(r, sort_keys=True, separators=(",", ":"))

    def param(self, name):
        return next(p for p in self.wft["spec"]["arguments"]["parameters"] if p["name"] == name)

    def write(self):
        dump = lambda o: yaml.dump(o, default_flow_style=False, allow_unicode=True, sort_keys=False)  # noqa: E731
        files = {
            "workflow-template.yaml": (self.out, dump(self.wft)),
            "context.yaml": (self.root, dump(self.ctx)),
            "form-data.json": (self.root, json.dumps(self.form_data)),
            "steps.json": (self.root, json.dumps(self.steps)),
        }
        for name, (d, text) in files.items():
            text = self.raw_texts.get(name, text)
            if text is not None and not (d / name).is_symlink():
                (d / name).write_text(text, encoding="utf-8")
        if self.form_yaml is not None:
            (self.config / "_form.yaml").write_text(self.form_yaml, encoding="utf-8")
        if self.previous is not None:
            (self.root / "previous.yaml").write_text(
                self.previous if isinstance(self.previous, str) else dump(self.previous), encoding="utf-8")

    def args(self):
        a = ["seal", "--wft", str(self.wft_path), "--context", str(self.root / "context.yaml"),
             "--form-data", str(self.root / "form-data.json"), "--steps", str(self.root / "steps.json"),
             "--config-dir", str(self.config), "--engine", self.engine, "--source-commit", self.commit]
        if self.previous is not None:
            a += ["--previous", str(self.root / "previous.yaml")]
        return a

    def load_wft(self):
        return yaml.safe_load(self.wft_path.read_text(encoding="utf-8"))

    def _snapshot(self):
        try:
            st = os.lstat(self.wft_path)
        except OSError:
            return None
        return self.wft_path.read_bytes() if stat.S_ISREG(st.st_mode) else ("not-regular", st.st_mode)

    def run(self, args=None, write=True):
        if write:
            self.write()
        before = self._snapshot()
        p = subprocess.run([sys.executable, "-I", str(SEAL)] + (self.args() if args is None else args),
                           capture_output=True, text=True, cwd=str(self.root), timeout=120,
                           env={"PATH": os.environ.get("PATH", ""), "HOME": str(self.root)})
        after = self._snapshot()
        return Result(p.returncode, p.stdout, p.stderr, before, after, self)
