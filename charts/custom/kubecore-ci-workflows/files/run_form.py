"""The trusted run-form seal (PRD novelcore/kaos#1533 F-21/F-22, contract §3).

Run in the token-holding `hera-enhance-commit` / `hera-enhance-gate` pod, after the enhance and the dataset
fill, with `python3 -I`:

    python3 -I run_form.py seal --wft W --context C --form-data F --steps S --config-dir D \
        --engine E --source-commit SHA [--previous P]

It builds the run form (fields, groups, machines, steps) from DATA the trusted enhance wrote (the final
WorkflowTemplate, the pipeline context, form-data.json, the step table) and `config/_form.yaml`, checks it
against annotation schema v1 as OSR consumes it, stamps it (engine, source commit, params digest) and writes
the WorkflowTemplate once, with the one annotation `ui.kubecore.io/run-form`. It is the only writer of that
annotation: the render is untrusted, so every `ui.kubecore.io/*` key and every `platform.kubecore.io/*` key
outside an allowlist is deleted first.

Stdlib plus PyYAML (both in the toolbox image). It imports nothing from the engine, runs no subprocess,
opens no socket. It fails closed: on any error the WFT file is byte-unchanged, stderr carries one
`GATE FAIL: run form: <sentence>` line (never a byte of input beyond a field or key name) and the exit status
is 1 (the app's pipeline, config or `_form.yaml` breaks the contract), 2 (bad invocation) or 3 (a platform
input is missing or inconsistent; also any unclassified error).
"""
import argparse
import copy
import hashlib
import json
import math
import os
import re
import stat
import sys

import yaml

# ---- limits (contract §3.6) ---------------------------------------------------------------------------
MAX_ANNOTATION_BYTES = 131072
WARN_ANNOTATION_BYTES = 98304
MAX_ALL_ANNOTATIONS_BYTES = 262144  # the Kubernetes per-object annotation limit
MAX_WFT_BYTES = 4 * 1024 * 1024
MAX_PREVIOUS_BYTES = 4 * 1024 * 1024
MAX_CONTEXT_BYTES = 1024 * 1024
MAX_FORM_DATA_BYTES = 2 * 1024 * 1024
MAX_STEPS_BYTES = 1024 * 1024
MAX_RAW_FORM_BYTES = 131072
MAX_FORM_YAML_BYTES = 65536
MAX_DEPTH = 32
MAX_FIELDS, MAX_GROUPS, MAX_MACHINES, MAX_STEPS = 1000, 32, 200, 200
MAX_OPTIONS = 64
MAX_OPTION_VALUE = 4096
MAX_SHOWIF = 1024
MAX_LABEL = 80
MAX_DESCRIPTION_BYTES = 512

# ---- naming spec: copied from kaos-lib src/kaos_lib/lint/ (contract §6; pinned by a values-only test) ----
STEP_NAME_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")  # lint/constants.py:44
STEP_NAME_MAX = 40  # lint/constants.py:67
STEP_KINDS = ("ingest", "transform", "train", "evaluate", "publish", "control")  # lint/constants.py:38 (= v1 step.kind)
TIME_RE = re.compile(r"^[0-9]+[mh]?$")  # lint/constants.py:69
MAX_MINUTES = 43200  # lint/constants.py:79 (30 days, = v1 maxMinutes)
RESERVED_STEP_NAMES = frozenset({"main", "compose-and-validate"})  # lint/constants.py:41
ENGINE_TEMPLATES = frozenset({"kaos-promote", "hpc-follower"})  # engine promote.py, meluxina.py HPC_TWIN_TEMPLATE
WHEN_NAME = "[A-Za-z0-9_.-]+"  # lint/when_text.py:19-22: NAME (==|!=) ("..."|'...'|NAME), joined by and/or
WHEN_COMPARISON_RE = re.compile(r"""\s*(%s)\s*(==|!=)\s*("[^"]*"|'[^']*'|%s)""" % (WHEN_NAME, WHEN_NAME))
WHEN_JOIN_RE = re.compile(r"\s+(and|or)(?=\s)")

# ---- annotation schema v1 (OSR internal/readapi/runform/run-form.schema.json) ---------------------------
ANNOTATION = "ui.kubecore.io/run-form"
ENGINE_ANNOTATION = "platform.kubecore.io/engine-version"
ENGINE_LABEL = "platform.kubecore.io/engine"
STAMP_BY = "kubecore.run_form"
ENGINE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,252}$")
GROUP_ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")
TIERS = ("basic", "advanced", "hidden")
FIELD_TYPES = ("string", "integer", "number", "boolean", "enum", "duration", "yaml", "text")
FIELD_SOURCES = ("info", "group", "config", "input", "run-setting", "advanced", "platform")
FIELD_KEYS = {"name", "group", "type", "picker", "source", "label", "tier", "platform", "step", "showIf", "minimum",
              "maximum", "pattern", "minMinutes", "maxMinutes", "optionDefaults"}
FIELD_REQUIRED = ("name", "group", "type", "tier", "platform", "source")
STEP_KEYS = {"name", "kind", "classField", "default", "offered", "refused", "walltimeField", "checkpointField",
             "promoteFields", "showIf"}
STEP_REQUIRED = ("name", "kind", "classField", "default", "offered", "refused")
MACHINE_KEYS = {"name", "tier", "machineType", "accelerator", "allocatable", "description", "kind", "hpc"}
MACHINE_REQUIRED = ("name", "tier", "machineType", "accelerator", "allocatable", "description", "kind")
HPC_KEYS = {"provider", "partition", "qos", "gpus", "maxTimeLimitMinutes", "sharesNode"}
DURATION_PATTERN = "^[0-9]+[mh]?$"
INTEGER_RE = re.compile(r"^-?(0|[1-9][0-9]*)$")  # OSR actions/validate.go integerRE
NUMBER_RE = re.compile(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$")  # OSR actions/validate.go numberRE
SHOWIF_TOKEN_RE = re.compile(r"[A-Za-z0-9_.-]+")  # OSR runform/join.go:93
BARE_VALUE_RE = re.compile(r"^[A-Za-z0-9_.-]+$")

# ---- roles (engine H2) -> fields -----------------------------------------------------------------------
ROLES = ("info", "experiment", "setting", "input", "class", "walltime", "checkpoint-every", "matrix", "parallel",
         "reuse", "start", "promote", "advanced", "platform")
PER_STEP_ROLES = ("class", "walltime", "checkpoint-every", "matrix", "parallel", "promote")
RAW_TYPES = ("string", "integer", "number", "boolean", "enum")
FIXED_GROUPS = (  # id, label, tier
    ("info", "Info", "hidden"), ("experiment", "Experiment", "basic"), ("settings", "Settings", "basic"),
    ("datasets", "Datasets", "basic"), ("steps", "Steps", "basic"), ("rerun", "Re-run", "advanced"),
    ("promote", "Promote", "advanced"), ("advanced", "Advanced", "advanced"), ("platform", "Platform", "hidden"))
FIXED_IDS = tuple(g[0] for g in FIXED_GROUPS)
HIDDEN_FIXED = ("info", "platform")
FORM_YAML_SOURCES = ("config", "group", "input")

# Roles whose fields are labelled "<step>: <label>" (contract §3.5).
STEP_LABELS = {"class": "machine", "walltime": "time limit", "checkpoint-every": "checkpoint every",
               "matrix": "runs", "parallel": "at the same time"}

# ---- trusted values of platform.kubecore.io/* keys (contract §3.3 step 2) -------------------------------
MANAGED_BY = "kubecore-ci"
GENERATED_BY = "ml-ci-build/hera-render"
COST_TRACKING = "enabled"


class SealError(Exception):
    """A refusal. code 1: the app's pipeline, config or _form.yaml; code 3: a platform input."""

    def __init__(self, code, message):
        super().__init__(message)
        self.code = code
        self.message = message


def refuse(message):
    return SealError(1, message)


def platform_fault(message):
    return SealError(3, message)


def q(name):
    """A name for a message: only names that cannot carry text of the file are echoed."""
    s = name if isinstance(name, str) else ""
    return s if re.fullmatch(r"[A-Za-z0-9._-]{1,80}", s) else "<a name with unusual characters>"


# ---- reading ---------------------------------------------------------------------------------------------

def read_regular(path, limit, what, code=3, dir_fd=None):
    """The bytes of a regular file of at most `limit` bytes. Never follows a symlink in the last component and
    never blocks on a FIFO. The message does not carry the path."""
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(path, flags, dir_fd=dir_fd)
    except OSError:
        raise SealError(code, f"{what} cannot be opened (it is missing, a symlink or not readable)") from None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise SealError(code, f"{what} is not a regular file")
        if st.st_size > limit:
            raise SealError(code, f"{what} is larger than {limit} bytes")
        with os.fdopen(fd, "rb", closefd=False) as f:
            data = f.read(limit + 1)
        if len(data) > limit:
            raise SealError(code, f"{what} is larger than {limit} bytes")
        return data, st.st_mode
    finally:
        os.close(fd)


def load_yaml(data, what, code=3):
    try:
        return yaml.safe_load(data.decode("utf-8"))
    except (yaml.YAMLError, UnicodeError, RecursionError, ValueError, MemoryError):
        raise SealError(code, f"{what} is not valid YAML") from None


def _depth_ok(text):
    """True when the JSON text nests at most MAX_DEPTH deep (read before parsing, so no recursion limit)."""
    depth, in_str, esc = 0, False, False
    for ch in text:
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
        elif ch == '"':
            in_str = True
        elif ch in "[{":
            depth += 1
            if depth > MAX_DEPTH:
                return False
        elif ch in "]}":
            depth -= 1
    return True


def _no_dups(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise ValueError("duplicate key")
        out[k] = v
    return out


def _refuse_constant(_name):
    raise ValueError("not a JSON number")


def _strings_ok(o):
    if isinstance(o, str):
        o.encode("utf-8")  # raises on a lone surrogate
    elif isinstance(o, dict):
        for k, v in o.items():
            _strings_ok(k)
            _strings_ok(v)
    elif isinstance(o, list):
        for v in o:
            _strings_ok(v)


def strict_json(text, what, code):
    """Parse one JSON value strictly: no duplicate keys, no NaN or Infinity, nesting at most MAX_DEPTH, no text
    that is not UTF-8. The message is fixed: parser errors quote their input."""
    try:
        if not _depth_ok(text):
            raise ValueError("deep")
        value = json.loads(text, object_pairs_hook=_no_dups, parse_constant=_refuse_constant)
        _strings_ok(value)
        return value
    except (ValueError, RecursionError, UnicodeError):
        raise SealError(code, f"{what} is not strict JSON (duplicate keys, NaN, nesting over {MAX_DEPTH}, or "
                              "not JSON)") from None


def read_json_file(path, limit, what):
    data, _ = read_regular(path, limit, what)
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        raise platform_fault(f"{what} is not UTF-8") from None
    return strict_json(text, what, 3)


# ---- the inputs --------------------------------------------------------------------------------------------

def is_number(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def load_wft(path):
    data, mode = read_regular(path, MAX_WFT_BYTES, "--wft")
    wft = load_yaml(data, "--wft")
    ok = isinstance(wft, dict) and isinstance(wft.get("metadata"), dict) and isinstance(wft.get("spec"), dict)
    spec = wft["spec"] if ok else {}
    args = spec.get("arguments") if ok else None
    params = args.get("parameters") if isinstance(args, dict) else None
    templates = spec.get("templates") if ok else None
    if not (ok and isinstance(params, list) and isinstance(templates, list)
            and all(isinstance(p, dict) and isinstance(p.get("name"), str) for p in params)
            and all(isinstance(t, dict) and isinstance(t.get("name"), str) for t in templates)):
        raise platform_fault("--wft is not a WorkflowTemplate with spec.arguments.parameters and spec.templates")
    names = [p["name"] for p in params]
    if len(set(names)) != len(names):
        raise platform_fault("--wft has a parameter name twice")
    return wft, mode


def load_context(path):
    data, _ = read_regular(path, MAX_CONTEXT_BYTES, "--context")
    ctx = load_yaml(data, "--context")
    if not isinstance(ctx, dict) or not all(isinstance(ctx.get(k), str) and ctx[k] for k in ("project", "app", "namespace")):
        raise platform_fault("--context lacks project, app or namespace")
    cc = ctx.get("computeClasses")
    if not isinstance(cc, dict) or not isinstance(cc.get("all") or [], list):
        raise platform_fault("--context has no compute classes")
    return ctx


def load_form_data(path):
    fd = read_json_file(path, MAX_FORM_DATA_BYTES, "--form-data")
    bad = platform_fault("--form-data is not the trusted enhance's form data (version 1)")
    if not isinstance(fd, dict) or fd.get("version") != 1 or isinstance(fd.get("version"), bool):
        raise bad
    for key in ("offers", "pinned", "rank"):
        if not isinstance(fd.get(key), dict):
            raise bad
    if not isinstance(fd.get("rendered", []), list) or not (fd.get("raw") is None or isinstance(fd.get("raw"), str)):
        raise bad
    return fd


def load_steps(path):
    steps = read_json_file(path, MAX_STEPS_BYTES, "--steps")
    if not isinstance(steps, list):
        raise platform_fault("--steps is not a list")
    return steps


def load_previous(path):
    """The live gitops template, or None: any failure means "no previous" (hostile or absent alike)."""
    if not path:
        return None
    try:
        data, _ = read_regular(path, MAX_PREVIOUS_BYTES, "--previous")
        prev = yaml.safe_load(data.decode("utf-8"))
        return prev if isinstance(prev, dict) else None
    except Exception:  # noqa: BLE001 - by contract every failure is "no previous"
        return None


# ---- step 1 and 2: identity checks and the strip ---------------------------------------------------------------

def check_identity(wft, engine, commit):
    if not COMMIT_RE.match(commit or ""):
        raise platform_fault("--source-commit is not 40 lowercase hex characters")
    if not ENGINE_RE.match(engine or ""):
        raise platform_fault("--engine is not a valid engine version")
    meta = wft["metadata"]
    ann = meta.get("annotations")
    wm = wft["spec"].get("workflowMetadata")
    lab = wm.get("labels") if isinstance(wm, dict) else None
    if not isinstance(ann, dict) or ann.get(ENGINE_ANNOTATION) != engine:
        raise platform_fault(f"the template's {ENGINE_ANNOTATION} does not equal --engine")
    if not isinstance(lab, dict) or lab.get(ENGINE_LABEL) != engine:
        raise platform_fault(f"the template's {ENGINE_LABEL} label does not equal --engine")


def strip_forged(wft, ctx, engine):
    """Delete every ui.kubecore.io/* key and every platform.kubecore.io/* key outside the allowlist in the four
    metadata places; an allowlisted key with a value that is not the trusted one refuses the seal."""
    meta, spec = wft["metadata"], wft["spec"]
    places = [
        ("metadata.labels", meta, "labels", {
            "platform.kubecore.io/project": ctx["project"], "platform.kubecore.io/app": ctx["app"],
            "platform.kubecore.io/managed-by": MANAGED_BY}),
        ("metadata.annotations", meta, "annotations", {
            "platform.kubecore.io/generated-by": GENERATED_BY, "platform.kubecore.io/cost-tracking": COST_TRACKING,
            ENGINE_ANNOTATION: engine}),
        ("spec.workflowMetadata.labels", spec.get("workflowMetadata"), "labels", {ENGINE_LABEL: engine}),
        ("spec.workflowMetadata.annotations", spec.get("workflowMetadata"), "annotations", {}),
        # Argo applies labelsFrom after the run's own labels and overwrites them: no ui.* or platform.* key survives
        ("spec.workflowMetadata.labelsFrom", spec.get("workflowMetadata"), "labelsFrom", {}),
    ]
    for place, holder, key, allow in places:
        if holder is None:
            continue
        if not isinstance(holder, dict):
            raise platform_fault(f"{place} is not a mapping")
        d = holder.get(key)
        if d is None:
            continue
        if not isinstance(d, dict):
            raise platform_fault(f"{place} is not a mapping")
        for k in list(d):
            if not isinstance(k, str):
                raise platform_fault(f"{place} has a key that is not text")
            if k.startswith("ui.kubecore.io/"):
                del d[k]
            elif k.startswith("platform.kubecore.io/"):
                if k not in allow:
                    del d[k]
                elif d[k] != allow[k]:
                    raise refuse(f"{place} carries {k} with a value the platform did not set; "
                                 "the render must not write platform.kubecore.io/* keys")
    if meta.get("namespace") != ctx["namespace"]:
        raise refuse("metadata.namespace is not the app's runtime namespace; the render must not set it")


# ---- the step table ------------------------------------------------------------------------------------------------

def check_step_table(steps, wft):
    if len(steps) > MAX_STEPS:
        raise refuse(f"the step table lists more than {MAX_STEPS} steps")
    names = []
    for s in steps:
        if not isinstance(s, dict) or not isinstance(s.get("name"), str):
            raise refuse("a step table entry has no name")
        n = s["name"]
        if not STEP_NAME_RE.match(n) or len(n) > STEP_NAME_MAX or n in RESERVED_STEP_NAMES:
            raise refuse(f"step {q(n)} is not a valid step name")
        if s.get("kind") not in STEP_KINDS:
            raise refuse(f"step {q(n)} has a kind that is not one of {', '.join(STEP_KINDS)}")
        if not (isinstance(s.get("inputs"), list) and all(isinstance(i, str) for i in s["inputs"])):
            raise refuse(f"step {q(n)} has inputs that are not a list of names")
        pr = s.get("produces", [])
        if not (isinstance(pr, list) and all(isinstance(e, dict) and isinstance(e.get("name"), str)
                                             and isinstance(e.get("type"), str) for e in pr)):
            raise refuse(f"step {q(n)} has produces that are not a list of names with a type")
        if "when_text" in s and not isinstance(s["when_text"], str):
            raise refuse(f"step {q(n)} has a when text that is not text")
        if "matrix" in s and not isinstance(s["matrix"], dict):
            raise refuse(f"step {q(n)} has a matrix that is not a mapping")
        names.append(n)
    if len(set(names)) != len(names):
        raise refuse("the step table lists a step twice")
    owned = set(RESERVED_STEP_NAMES)
    for t in wft["spec"]["templates"]:
        tn = t["name"]
        if tn in names:
            continue
        # exactly what the engine emits: compose, the dag, kaos-promote, the HPC follower, and a matrix step's
        # kaos-gather-<step> and kaos-matrix-<step>
        if tn in owned or tn in ENGINE_TEMPLATES or any(tn == pre + n for pre in ("kaos-gather-", "kaos-matrix-") for n in names):
            continue
        raise refuse(f"template {q(tn)} is not in the step table")
    have = {t["name"] for t in wft["spec"]["templates"]}
    for n in names:
        if n not in have:
            raise refuse(f"step {q(n)} of the step table has no template")


# ---- step 3: the raw form (author data) -------------------------------------------------------------------------------

def argo_enum(p):
    e = p.get("enum")
    return e if isinstance(e, list) and e and all(isinstance(x, str) for x in e) else None


def validate_raw(raw_text, params, roles, notes):
    """Returns (types, option_defaults, leaf_options, group_names). Any violation refuses (exit 1)."""
    empty = ({}, {}, {}, set())
    if raw_text is None:
        return empty
    if len(raw_text.encode("utf-8", "replace")) > MAX_RAW_FORM_BYTES:
        raise refuse("the raw form is larger than 128 KiB")
    raw = strict_json(raw_text, "the raw form", 1)
    if not isinstance(raw, dict) or not set(raw) <= {"version", "types", "optionDefaults", "leafOptions"}:
        raise refuse("the raw form has keys other than version, types, optionDefaults and leafOptions")
    v = raw.get("version")
    if type(v) is not int or v != 1:
        raise refuse("the raw form is not version 1")
    parts = {}
    for k in ("types", "optionDefaults", "leafOptions"):
        parts[k] = raw.get(k, {})
        if not isinstance(parts[k], dict):
            raise refuse(f"the raw form's {k} is not a mapping")
    by_name = {p["name"]: p for p in params}
    ignored = set()
    cfg = {n for n, r in roles.items() if r in ("experiment", "setting")}
    for name, t in parts["types"].items():
        if name not in by_name:
            raise refuse(f"the raw form types {q(name)}, which is not a parameter")
        if t not in RAW_TYPES:
            raise refuse(f"the raw form gives {q(name)} a type that is not one of {', '.join(RAW_TYPES)}")
        if name not in cfg:  # the engine types every config leaf, an input's too: only experiment/setting use it
            notes.append(f"run form: raw form type of {q(name)} ignored (its role is {roles[name]}, not experiment or setting)")
            ignored.add(name)
    types = {k: v for k, v in parts["types"].items() if k not in ignored}
    groups = set()
    for g, options in parts["optionDefaults"].items():
        p = by_name.get(g)
        if p is None or roles.get(g) != "setting" or argo_enum(p) is None:
            raise refuse(f"the raw form's optionDefaults names {q(g)}, which is not a group parameter with an enum")
        if not isinstance(options, dict) or len(options) > MAX_OPTIONS:
            raise refuse(f"the raw form's optionDefaults of {q(g)} has more than {MAX_OPTIONS} options")
        for opt, leaves in options.items():
            if opt not in argo_enum(p):
                raise refuse(f"the raw form's optionDefaults of {q(g)} has an option that is not in its enum")
            if not isinstance(leaves, dict) or not all(
                    isinstance(a, str) and isinstance(b, str) and len(b) <= MAX_OPTION_VALUE for a, b in leaves.items()):
                raise refuse(f"the raw form's optionDefaults of {q(g)} has values that are not text of at most "
                             f"{MAX_OPTION_VALUE} characters")
        groups.add(g)
    leaf_options = {}
    for leaf, lo in parts["leafOptions"].items():
        if leaf not in by_name or leaf in groups:
            raise refuse(f"the raw form's leafOptions names {q(leaf)}, which is not a config field")
        if leaf not in cfg:  # e.g. an input supplied by a `@package _global_` group option: no showIf, always shown
            notes.append(f"run form: raw form leafOptions of {q(leaf)} ignored (its role is {roles[leaf]}, not "
                         "experiment or setting)")
            continue
        if not (isinstance(lo, dict) and set(lo) == {"group", "options"} and isinstance(lo["group"], str)
                and isinstance(lo["options"], list) and all(isinstance(o, str) for o in lo["options"])):
            raise refuse(f"the raw form's leafOptions of {q(leaf)} is malformed")
        if lo["group"] not in groups:
            raise refuse(f"the raw form's leafOptions of {q(leaf)} names a group that is not a group parameter")
        if not set(lo["options"]) <= set(argo_enum(by_name[lo["group"]])):
            raise refuse(f"the raw form's leafOptions of {q(leaf)} lists an option that is not in the enum of "
                         f"{q(lo['group'])}")
        leaf_options[leaf] = lo
    return types, parts["optionDefaults"], leaf_options, groups


# ---- step 4: config/_form.yaml (author data) ---------------------------------------------------------------------

class _FormLoader(yaml.SafeLoader):
    """No anchors, no aliases, no duplicate keys, no non-string keys."""

    def compose_node(self, parent, index):
        ev = self.peek_event()
        if isinstance(ev, yaml.AliasEvent) or getattr(ev, "anchor", None):
            raise yaml.YAMLError("anchor")
        return super().compose_node(parent, index)

    def construct_mapping(self, node, deep=False):
        seen = set()
        for k, _ in node.value:
            key = self.construct_object(k, deep=True)
            if not isinstance(key, str) or key in seen:
                raise yaml.YAMLError("key")
            seen.add(key)
        return super().construct_mapping(node, deep)


def _open_config_dir(config_dir):
    """The directory fd of config_dir, opening its last three components (/workspace, repo, config) one by one with
    O_DIRECTORY|O_NOFOLLOW through the previous fd: the render pod can write /workspace and could swap `repo` for a
    symlink. None when a component does not exist. The prefix above them is chart-owned and resolved normally."""
    parts = [x for x in os.path.abspath(config_dir).split("/") if x]
    n = min(3, len(parts))
    prefix = os.path.realpath("/" + "/".join(parts[:-n]))
    flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0)
    fd = os.open(prefix, flags)
    try:
        for comp in parts[-n:]:
            try:
                nfd = os.open(comp, flags | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                os.close(fd)
                return None
            except OSError:
                raise refuse("config/_form.yaml cannot be read: a directory on its path is a symlink or not a "
                             "directory") from None
            os.close(fd)
            fd = nfd
        return fd
    except BaseException:
        try:
            os.close(fd)
        except OSError:
            pass
        raise


def _label_ok(label, where):
    if not isinstance(label, str) or len(label) > MAX_LABEL or has_control(label):
        raise refuse(f"_form.yaml: {where} must be text of at most {MAX_LABEL} characters with no control character")


def has_control(s):
    return any(ord(c) <= 0x1F or ord(c) == 0x7F for c in s)


def read_form_yaml(config_dir):
    """{"fields": {name: {...}}, "groups": [{id, label, tier, order}]}; absent is fine, anything else wrong refuses."""
    dfd = _open_config_dir(config_dir)
    if dfd is None:
        return {"fields": {}, "groups": []}
    try:
        try:
            os.stat("_form.yaml", dir_fd=dfd, follow_symlinks=False)
        except FileNotFoundError:
            return {"fields": {}, "groups": []}  # absent is fine
        except OSError:
            raise refuse("config/_form.yaml cannot be read") from None
        data, _ = read_regular("_form.yaml", MAX_FORM_YAML_BYTES, "config/_form.yaml", code=1, dir_fd=dfd)
    finally:
        os.close(dfd)
    try:
        doc = yaml.load(data.decode("utf-8"), Loader=_FormLoader)
    except (yaml.YAMLError, UnicodeError, RecursionError, ValueError, MemoryError):
        raise refuse("config/_form.yaml is not valid YAML (anchors, aliases, duplicate keys and keys that are not "
                     "text are refused)") from None
    return _check_form_yaml(doc)


def _check_form_yaml(doc):
    if doc is None:
        return {"fields": {}, "groups": []}
    if not isinstance(doc, dict) or not set(doc) <= {"fields", "groups"}:
        raise refuse("_form.yaml must be a mapping with only the keys fields and groups")
    fields = doc.get("fields") or {}
    groups = doc.get("groups") or []
    if not isinstance(fields, dict) or not isinstance(groups, list):
        raise refuse("_form.yaml: fields must be a mapping and groups a list")
    out_f = {}
    for name, o in fields.items():
        o = {} if o is None else o
        where = f"fields.{q(name)}"
        if not isinstance(o, dict):
            raise refuse(f"_form.yaml: {where} must be a mapping")
        if "pattern" in o:
            raise refuse(f"_form.yaml: {where}.pattern is not allowed (the platform does not take an author pattern)")
        extra = set(o) - {"label", "tier", "minimum", "maximum", "group"}
        if extra:
            raise refuse(f"_form.yaml: {where} has a key that is not label, tier, minimum, maximum or group")
        if "label" in o:
            _label_ok(o["label"], f"{where}.label")
        if "tier" in o and o["tier"] not in TIERS:
            raise refuse(f"_form.yaml: {where}.tier must be basic, advanced or hidden")
        for k in ("minimum", "maximum"):
            if k in o and not is_number(o[k]):
                raise refuse(f"_form.yaml: {where}.{k} must be a number")
        if "group" in o and not (isinstance(o["group"], str) and GROUP_ID_RE.match(o["group"])):
            raise refuse(f"_form.yaml: {where}.group must be a group id")
        out_f[name] = o
    out_g, seen = [], set()
    for i, g in enumerate(groups):
        where = f"groups[{i}]"
        if not isinstance(g, dict) or not set(g) <= {"id", "label", "tier", "order"} or not {"id", "label"} <= set(g):
            raise refuse(f"_form.yaml: {where} must have id and label, and may have tier and order")
        if not isinstance(g["id"], str) or not GROUP_ID_RE.match(g["id"]):
            raise refuse(f"_form.yaml: {where}.id must be a lowercase letter then up to 62 lowercase letters, digits or dashes")
        if g["id"] in FIXED_IDS:
            raise refuse(f"_form.yaml: {where}.id is a fixed group id")
        if g["id"] in seen:
            raise refuse(f"_form.yaml: {where}.id is declared twice")
        seen.add(g["id"])
        _label_ok(g["label"], f"{where}.label")
        tier = g.get("tier", "basic")
        order = g.get("order", 0)
        if tier not in TIERS:
            raise refuse(f"_form.yaml: {where}.tier must be basic, advanced or hidden")
        if type(order) is not int or order < 0:
            raise refuse(f"_form.yaml: {where}.order must be a whole number of at least 0")
        out_g.append({"id": g["id"], "label": g["label"], "tier": tier, "order": order})
    return {"fields": out_f, "groups": out_g}


# ---- the when= grammar and showIf --------------------------------------------------------------------------------

def parse_when(text):
    """[(name, op, value), ...] and the joiners, or None when the text is not the kaos-lib `when=` grammar."""
    if not isinstance(text, str):
        return None
    if has_control(text):  # kaos-lib lint/when_text.py: a control character anywhere, tab and newline included
        return None
    text = text.strip()
    if not text:
        return None
    pos, comps, joins = 0, [], []
    while True:
        m = WHEN_COMPARISON_RE.match(text, pos)
        if not m:
            return None
        comps.append((m.group(1), m.group(2), m.group(3)))
        pos = m.end()
        if pos == len(text):
            return comps, joins
        j = WHEN_JOIN_RE.match(text, pos)
        if not j:
            return None
        joins.append(j.group(1))
        pos = j.end()


def _render(comps, joins):
    out = []
    for i, (n, op, v) in enumerate(comps):
        out.append(f"{n} {op} {v}")
        if i < len(joins):
            out.append(joins[i])
    return " ".join(out)


def normalize_when(text):
    """The `when=` text with single spaces between the parts, or None when it is not valid."""
    parsed = parse_when(text)
    return _render(*parsed) if parsed else None


def showif_from_when(text, param_names, step_names):
    """The showIf a step's when= gives, or None: it must be valid and read only form fields. A name that is
    `<step>.<value>` reads a step result and gives none; `a.b` reads the field `a-b` when that is a parameter."""
    parsed = parse_when(text)
    if not parsed:
        return None
    comps, joins = parsed
    out = []
    for name, op, value in comps:
        if name in param_names:
            out.append((name, op, value))
        elif name.replace(".", "-") in param_names and name.split(".")[0] not in step_names:
            out.append((name.replace(".", "-"), op, value))
        else:
            return None
    return _render(out, joins)


def leaf_showif(group, options, enum):
    """`<group> == a or <group> == b` for a leaf that exists only under some options, else None."""
    opts = list(dict.fromkeys(options))
    if not opts or set(opts) >= set(enum):
        return None
    parts = []
    for o in opts:
        if BARE_VALUE_RE.match(o):
            parts.append(f"{group} == {o}")
        elif '"' not in o and not has_control(o):
            parts.append(f'{group} == "{o}"')
        else:
            return None
    return " or ".join(parts)


# ---- credential-like names (OSR handlers/pipeline_redact.go, word list copied) ---------------------------------

_CRED_WORDS = {"token", "secret", "secrets", "password", "passwords", "passwd", "pass", "pwd", "credential",
               "credentials", "auth", "authorization", "apikey", "passphrase", "privatekey", "accesskey", "sig",
               "accountkey"}
_CRED_PAIRS = {("api", "key"), ("access", "key"), ("private", "key"), ("secret", "key"), ("client", "secret"),
               ("signing", "key"), ("account", "key")}
_STRONG_STEMS = ("password", "passwd", "secret", "token", "apikey", "accesskey", "privatekey", "secretkey", "credential")
_STEM_EXCLUSIONS = {"author", "authority"}
_STEM_EXCLUSION_PREFIXES = ("tokeniz", "secretar", "authori")
_ML_ALLOW = {"pad_token_id", "eos_token", "bos_token", "pad_token", "unk_token", "sep_token", "cls_token", "mask_token",
             "token_type_ids", "max_token_length", "token_budget", "token_count", "pass_rate", "password_policy",
             "credential_type", "eos_token_id", "bos_token_id", "unk_token_id", "sep_token_id", "cls_token_id",
             "mask_token_id", "decoder_start_token_id", "max_tokens", "num_tokens", "max_new_tokens", "total_tokens",
             "tokens_per_second", "special_tokens"}


def _strong_stem(w):
    if w in _STEM_EXCLUSIONS or "tokeniz" in w or w.startswith(_STEM_EXCLUSION_PREFIXES):
        return False
    return any(s in w for s in _STRONG_STEMS)


def is_sensitive_key(name):
    words = re.split(r"[^A-Za-z0-9]+", re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name).lower())
    if "_".join(words).strip("_") in _ML_ALLOW:
        return False
    for i, w in enumerate(words):
        if w in _CRED_WORDS or _strong_stem(w):
            return True
        if i > 0 and (words[i - 1], w) in _CRED_PAIRS:
            return True
    return False


# ---- step 5: build ------------------------------------------------------------------------------------------------

def argo_str(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    return "" if v is None else str(v)


def resolve_type(p, role, raw_type, notes):
    """The field type of a config parameter: the raw type, else enum/string; enum only with an Argo enum; a number,
    integer or boolean whose default does not parse under OSR's grammar falls back to string."""
    enum = argo_enum(p)
    t = raw_type or ("enum" if enum else "string")
    if t == "enum" and not enum:
        notes.append(f"run form: {q(p['name'])} is typed enum but has no Argo enum; typed string")
        return "string"
    default = argo_str(p.get("value")) if "value" in p else ""
    if default != "":
        bad = ((t == "integer" and not INTEGER_RE.match(default)) or (t == "number" and not NUMBER_RE.match(default))
               or (t == "boolean" and default not in ("true", "false")))
        if bad:
            notes.append(f"run form: the default of {q(p['name'])} does not parse as {t}; typed string")
            return "string"
    return t


def build_machines(ctx):
    cc = ctx["computeClasses"]
    cluster = list(cc.get("all") or [])
    names = {c.get("name") for c in cluster if isinstance(c, dict)}
    for tier in ("cpu", "gpu"):
        d = cc.get(tier)
        if isinstance(d, dict) and d.get("name") not in names:
            cluster.append(d)
            names.add(d.get("name"))
    machines, seen = [], set()
    bad = platform_fault("--context has a compute class that is not usable")
    for c in cluster:
        if not isinstance(c, dict) or not isinstance(c.get("name"), str) or not NAME_RE.match(c["name"]):
            raise bad
        if c["name"] in seen:
            continue
        seen.add(c["name"])
        tier = c.get("tier", "cpu")
        if tier not in ("cpu", "gpu"):
            raise bad
        default = cc.get(tier) if isinstance(cc.get(tier), dict) else {}
        alloc = c.get("allocatable") if isinstance(c.get("allocatable"), dict) else {}
        dalloc = default.get("allocatable") if isinstance(default.get("allocatable"), dict) else {}
        cpu = alloc.get("cpu", dalloc.get("cpu"))
        mem = alloc.get("memoryGiB", dalloc.get("memoryGiB"))
        eph = alloc.get("ephemeralStorageGiB")
        if not is_number(cpu) or not is_number(mem) or not (eph is None or is_number(eph)):
            raise bad
        ga = c.get("guestAccelerator")
        acc = None
        if ga:
            if not isinstance(ga, dict) or type(ga.get("count")) is not int or ga["count"] < 1 \
                    or not (ga.get("type") is None or isinstance(ga.get("type"), str)):
                raise bad
            acc = {"type": ga.get("type"), "count": ga["count"]}
        mt = c.get("machineType")
        if not (mt is None or isinstance(mt, str)):
            raise bad
        machines.append({"name": c["name"], "tier": tier, "machineType": mt, "accelerator": acc,
                         "allocatable": {"cpu": cpu, "memoryGiB": mem, "ephemeralStorageGiB": eph},
                         "description": _cut(c.get("description")), "kind": "cluster"})
    hpc = ctx.get("hpc")
    if isinstance(hpc, dict) and hpc.get("enabled") is True:
        provider = hpc.get("provider") or "meluxina"
        for c in hpc.get("classes") or []:
            if not isinstance(c, dict) or not isinstance(c.get("name"), str) or not NAME_RE.match(c["name"]):
                raise bad
            if c["name"] in seen:
                continue
            seen.add(c["name"])
            tier = c.get("tier", "cpu")
            gpus = c.get("gpus", 0)
            if tier not in ("cpu", "gpu") or type(gpus) is not int or gpus < 0 or not is_number(c.get("cpus")) \
                    or not is_number(c.get("memoryGiB")) or not isinstance(provider, str) \
                    or not isinstance(c.get("partition"), str) or not isinstance(c.get("qos"), str):
                raise bad
            h = {"provider": provider, "partition": c["partition"], "qos": c["qos"], "gpus": gpus}
            mtl = c.get("maxTimeLimitMinutes")
            if mtl is not None:
                if type(mtl) is not int or mtl < 1:
                    raise bad
                h["maxTimeLimitMinutes"] = mtl
            h["sharesNode"] = True
            machines.append({"name": c["name"], "tier": tier, "machineType": None,
                             "accelerator": {"type": None, "count": gpus} if gpus > 0 else None,
                             "allocatable": {"cpu": c["cpus"], "memoryGiB": c["memoryGiB"], "ephemeralStorageGiB": None},
                             "description": _cut(c.get("description")), "kind": "hpc", "hpc": h})
    if not machines:
        raise platform_fault("--context has no compute classes")
    return machines


def _cut(desc):
    if not isinstance(desc, str):
        return ""
    return desc.encode("utf-8", "ignore")[:MAX_DESCRIPTION_BYTES].decode("utf-8", "ignore")


def _roles(params, rank, step_names):
    roles, steps = {}, {}
    for p in params:
        n = p["name"]
        r = rank.get(n)
        if not isinstance(r, dict) or r.get("role") not in ROLES:
            raise platform_fault(f"--form-data has no known role for parameter {q(n)}")
        role, st = r["role"], r.get("step")
        if role in PER_STEP_ROLES and st not in step_names:
            raise platform_fault(f"--form-data gives parameter {q(n)} a step that is not in the step table")
        roles[n], steps[n] = role, st
    return roles, steps


def build_form(wft, ctx, form_data, steps, form_yaml, raw_parts, roles, step_of, notes):
    """Fields, groups, machines and steps (before the stamp). Returns the form without `version` and `stamp`."""
    params = wft["spec"]["arguments"]["parameters"]
    types, option_defaults, leaf_options, group_params = raw_parts
    machines = build_machines(ctx)
    machine_names = {m["name"] for m in machines}
    step_names = [s["name"] for s in steps]
    param_names = {p["name"] for p in params}

    # -- fields from roles
    fields, extra = [], {}
    for p in params:
        n, role = p["name"], roles[p["name"]]
        f = {"name": n, "platform": False}
        if n.lower().startswith("image-") or role == "platform":
            f.update(group="platform", type="string", source="platform", tier="hidden", platform=True)
        elif role == "info":
            f.update(group="info", type="text", source="info", tier="hidden", platform=True)
        elif role == "experiment" or (role == "setting" and n not in group_params):
            f.update(group="experiment" if role == "experiment" else "settings", source="config", tier="basic",
                     type=resolve_type(p, role, types.get(n), notes))
        elif role == "setting":
            f.update(group="settings", source="group", tier="basic", type="enum")
        elif role == "input":
            f.update(group="datasets", source="input", tier="basic", type="string", picker="dataset")
            if step_of[n] in step_names:
                f["step"] = step_of[n]
        elif role == "class":
            f.update(group="steps", source="run-setting", tier="basic", type="enum", picker="machine", step=step_of[n])
        elif role in ("walltime", "checkpoint-every"):
            f.update(group="steps", source="run-setting", tier="advanced", type="duration", step=step_of[n],
                     pattern=DURATION_PATTERN, minMinutes=1, maxMinutes=MAX_MINUTES)
        elif role == "matrix":
            f.update(group="steps", source="run-setting", tier="advanced", type="text", step=step_of[n])
        elif role == "parallel":
            f.update(group="steps", source="run-setting", tier="advanced", type="string", step=step_of[n])
        elif role in ("reuse", "start"):
            f.update(group="rerun", source="run-setting", tier="advanced", type="string")
        elif role == "promote":
            f.update(group="promote", source="run-setting", tier="advanced",
                     type="enum" if argo_enum(p) else "string", step=step_of[n])
        elif role == "advanced":
            f.update(group="advanced", source="advanced", tier="advanced", type="yaml")
        if role in STEP_LABELS and role in PER_STEP_ROLES and f.get("source") == "run-setting":
            f["label"] = f"{step_of[n]}: {STEP_LABELS[role]}"
        elif role == "promote" and f.get("source") == "run-setting":
            f["label"] = f"Promote {n[len('promote-'):] if n.startswith('promote-') else n}"
        fields.append(f)
    by = {f["name"]: f for f in fields}

    # -- _form.yaml
    declared = {g["id"]: g for g in form_yaml["groups"]}
    for name, o in form_yaml["fields"].items():
        f = by.get(name)
        if f is None:
            raise refuse(f"_form.yaml: fields.{q(name)} is not a field of the form")
        if f["source"] not in FORM_YAML_SOURCES or f["platform"]:
            raise refuse(f"_form.yaml: fields.{q(name)} is set by the platform and cannot be changed")
        if "label" in o:
            f["label"] = o["label"]
        if "tier" in o:
            f["tier"] = o["tier"]
        for k in ("minimum", "maximum"):
            if k in o:
                if f["type"] not in ("integer", "number"):
                    raise refuse(f"_form.yaml: fields.{q(name)}.{k} applies only to an integer or number field")
                f[k] = o[k]
        if "minimum" in f and "maximum" in f and f["minimum"] > f["maximum"]:
            raise refuse(f"_form.yaml: fields.{q(name)} has a minimum above its maximum")
        if "group" in o:
            g = o["group"]
            if g in HIDDEN_FIXED:
                raise refuse(f"_form.yaml: fields.{q(name)}.group cannot be a hidden fixed group")
            if g not in FIXED_IDS and g not in declared:
                raise refuse(f"_form.yaml: fields.{q(name)}.group is not a fixed group or a declared one")
            f["group"] = g

    # -- groups: fixed in order, declared ones by order after settings; empty ones are not emitted
    used = {f["group"] for f in fields}
    tiers = {i: t for i, _l, t in FIXED_GROUPS}
    labels = {i: lab for i, lab, _t in FIXED_GROUPS}
    for g in declared.values():
        tiers[g["id"]], labels[g["id"]] = g["tier"], g["label"]
    ordered = sorted(declared.values(), key=lambda g: g["order"])  # stable: declaration order within an order
    sequence = ["info", "experiment", "settings"] + [g["id"] for g in ordered] + \
        ["datasets", "steps", "rerun", "promote", "advanced", "platform"]
    groups = [{"id": i, "label": labels[i], "order": 0, "tier": tiers[i]} for i in sequence if i in used]
    for pos, g in enumerate(groups):
        g["order"] = pos
    hidden_groups = {g["id"] for g in groups if g["tier"] == "hidden"}

    # -- the withheld set W (OSR computeExcluded), then showIf
    W = {f["name"] for f in fields if f["platform"] or f["source"] == "platform" or f["tier"] == "hidden"
         or f["group"] in hidden_groups or f["group"] not in {g["id"] for g in groups}}
    withheld = lambda t: t.lower().startswith("image-") or t in W  # noqa: E731
    step_set = set(step_names)
    step_when = {s["name"]: showif_from_when(s["when_text"], param_names, step_set)
                 for s in steps if s.get("when_text")}

    def admissible(text, what):
        if text is None:
            return None
        if len(text) > MAX_SHOWIF or has_control(text) or any(withheld(t) for t in SHOWIF_TOKEN_RE.findall(text)):
            notes.append(f"run form: the showIf of {what} names a withheld parameter or is not usable; dropped")
            return None
        return text

    for f in fields:
        if f["name"] in W:
            continue
        cand = None
        if f["name"] in leaf_options:
            lo = leaf_options[f["name"]]
            cand = leaf_showif(lo["group"], lo["options"], argo_enum(next(p for p in params if p["name"] == lo["group"])))
        elif f["source"] == "run-setting" and f.get("step") in step_when:
            cand = step_when[f["step"]]
        cand = admissible(cand, f"field {q(f['name'])}")
        if cand:
            f["showIf"] = cand
    # -- optionDefaults on group fields: served config leaves only, no credential-like name
    for g in group_params:
        f = by[g]
        od = {}
        for opt, leaves in option_defaults.get(g, {}).items():
            kept = {k: v for k, v in leaves.items()
                    if k in by and by[k]["source"] == "config" and k not in W and not withheld(k)
                    and not is_sensitive_key(k)}
            if kept:
                od[opt] = kept
        if od:
            f["optionDefaults"] = od

    # -- machines referenced by class offers, and steps
    out_steps = []
    for s in steps:
        n = s["name"]
        of = lambda role: [p["name"] for p in params if roles[p["name"]] == role and step_of[p["name"]] == n]  # noqa: E731
        classes = of("class")
        offer = form_data["offers"].get(n, "missing")
        pinned = form_data["pinned"].get(n)
        incons = platform_fault(f"--form-data has inconsistent class data for step {q(n)}")
        if len(classes) > 1 or offer == "missing":
            raise incons
        if offer is None:
            if classes or not isinstance(pinned, str):
                raise incons
            if pinned not in machine_names:
                raise platform_fault(f"the pinned class of step {q(n)} has no machine in the context")
            st = {"name": n, "kind": s["kind"], "classField": None, "default": pinned, "offered": [pinned], "refused": {}}
        else:
            if not classes or not _offer_ok(offer):
                raise incons
            cp = next(p for p in params if p["name"] == classes[0])
            default = argo_str(cp.get("value"))
            enum = argo_enum(cp)
            if enum is None or sorted(enum) != sorted(offer["offered"]):
                raise platform_fault(f"the Argo enum of {q(classes[0])} is not the classes step {q(n)} is offered")
            if default not in offer["offered"]:
                raise platform_fault(f"the default of {q(classes[0])} is not a class step {q(n)} is offered")
            for c in offer["offered"]:
                if c not in machine_names:
                    raise platform_fault(f"class {q(c)}, offered to step {q(n)}, has no machine in the context")
            st = {"name": n, "kind": s["kind"], "classField": classes[0], "default": default,
                  "offered": list(offer["offered"]),
                  "refused": {k: list(v) for k, v in offer["refused"].items()}}
        for role, key in (("walltime", "walltimeField"), ("checkpoint-every", "checkpointField")):
            got = of(role)
            if len(got) > 1:
                raise platform_fault(f"--form-data gives step {q(n)} more than one {role} parameter")
            if got:
                st[key] = got[0]
        pf = of("promote")
        if pf:
            st["promoteFields"] = pf
        sh = admissible(step_when.get(n), f"step {q(n)}")
        if sh:
            st["showIf"] = sh
        out_steps.append(st)
    return {"fields": fields, "groups": groups, "machines": machines, "steps": out_steps}, W


def _offer_ok(o):
    return (isinstance(o, dict) and isinstance(o.get("offered"), list) and o["offered"]
            and all(isinstance(c, str) for c in o["offered"]) and isinstance(o.get("refused"), dict)
            and all(isinstance(v, list) and len(v) == 2 and all(isinstance(x, str) for x in v)
                    for v in o["refused"].values()))


# ---- step 6: the check (hand-written, contract §2.1 and §2.2; the OSR join) ----------------------------------------

def _is_int(v):
    return type(v) is int


def _re2_safe(pattern):
    if len(pattern) > 256 or re.search(r"\(\?[=!<]|\\[1-9]", pattern):
        return False
    try:
        re.compile(pattern)
    except re.error:
        return False
    return True


def check_form(form, params, wft_names):
    """Refuses (1) a form that breaks schema v1 and (3) one that breaks the OSR join."""
    f_n = form["fields"]
    if len(f_n) > MAX_FIELDS:
        raise refuse(f"the form has more than {MAX_FIELDS} fields")
    if len(form["groups"]) > MAX_GROUPS:
        raise refuse(f"the form has more than {MAX_GROUPS} groups")
    if len(form["machines"]) > MAX_MACHINES:
        raise refuse(f"the form has more than {MAX_MACHINES} machines")
    if len(form["steps"]) > MAX_STEPS:
        raise refuse(f"the form has more than {MAX_STEPS} steps")
    for g in form["groups"]:
        if not (GROUP_ID_RE.match(g["id"]) and isinstance(g["label"], str) and len(g["label"]) <= MAX_LABEL
                and _is_int(g["order"]) and g["order"] >= 0 and g["tier"] in TIERS and set(g) == {"id", "label", "order", "tier"}):
            raise refuse(f"group {q(g['id'])} breaks the schema")
    seen = set()
    for f in f_n:
        n = f["name"]
        bad = lambda why: refuse(f"field {q(n)} {why}")  # noqa: E731
        if not NAME_RE.match(n):
            raise bad("has a name the run-form schema does not allow")
        if n in seen:
            raise bad("is listed twice")
        seen.add(n)
        if not set(f) <= FIELD_KEYS or not all(k in f for k in FIELD_REQUIRED):
            raise bad("has keys the schema does not allow")
        if not (isinstance(f["group"], str) and f["type"] in FIELD_TYPES and f["source"] in FIELD_SOURCES
                and f["tier"] in TIERS and isinstance(f["platform"], bool)):
            raise bad("breaks the schema")
        if f.get("picker") not in (None, "dataset", "machine"):
            raise bad("has a picker the schema does not allow")
        if "label" in f and not (isinstance(f["label"], str) and len(f["label"]) <= MAX_LABEL):
            raise bad("has a label over 80 characters")
        if "step" in f and not NAME_RE.match(f["step"]):
            raise bad("has a step the schema does not allow")
        if "showIf" in f and (len(f["showIf"]) > MAX_SHOWIF or has_control(f["showIf"])):
            raise bad("has a showIf the schema or OSR refuses")
        for k in ("minimum", "maximum"):
            if k in f and not is_number(f[k]):
                raise bad(f"has a {k} that is not a finite number")
        if "pattern" in f and not _re2_safe(f["pattern"]):
            raise bad("has a pattern that is not RE2-safe or is over 256 characters")
        if "minMinutes" in f and not (_is_int(f["minMinutes"]) and f["minMinutes"] >= 1):
            raise bad("has a minMinutes below 1")
        if "maxMinutes" in f and not (_is_int(f["maxMinutes"]) and f["maxMinutes"] <= MAX_MINUTES):
            raise bad("has a maxMinutes over 43200")
        od = f.get("optionDefaults")
        if od is not None and not (isinstance(od, dict) and len(od) <= MAX_OPTIONS and all(
                isinstance(o, dict) and all(isinstance(v, str) and len(v) <= MAX_OPTION_VALUE for v in o.values())
                for o in od.values())):
            raise bad("has optionDefaults the schema does not allow")
    if [f["name"] for f in f_n] != params:
        raise platform_fault("the form's fields are not exactly the template's parameters in order")
    for m in form["machines"]:
        if not set(m) <= MACHINE_KEYS or not all(k in m for k in MACHINE_REQUIRED) or not NAME_RE.match(m["name"]) \
                or len(m["description"]) > MAX_DESCRIPTION_BYTES or (m["kind"] == "hpc") != ("hpc" in m) \
                or ("hpc" in m and not set(m["hpc"]) <= HPC_KEYS):
            raise refuse(f"machine {q(m['name'])} breaks the schema")
    for s in form["steps"]:
        if not set(s) <= STEP_KEYS or not all(k in s for k in STEP_REQUIRED) or not s["offered"]:
            raise refuse(f"step {q(s['name'])} breaks the schema")
        if "showIf" in s and (len(s["showIf"]) > MAX_SHOWIF or has_control(s["showIf"])):
            raise refuse(f"step {q(s['name'])} has a showIf the schema or OSR refuses")
    machine_names = {m["name"] for m in form["machines"]}
    for s in form["steps"]:
        if not set(s["offered"]) <= machine_names:
            raise platform_fault(f"an offered class of step {q(s['name'])} has no machine")
    # OSR join.go: every parameter that is not withheld has a field (true by construction), and no showIf or step
    # reference names a withheld parameter
    served = {g["id"] for g in form["groups"] if g["tier"] != "hidden"}
    excluded = {f["name"] for f in f_n if f["platform"] or f["source"] == "platform" or f["tier"] == "hidden"
                or f["group"] not in served}
    withheld = lambda t: t.lower().startswith("image-") or t in excluded  # noqa: E731
    names_withheld = lambda e: any(withheld(t) for t in SHOWIF_TOKEN_RE.findall(e or ""))  # noqa: E731
    for f in f_n:
        if f["name"] not in excluded and names_withheld(f.get("showIf")):
            raise platform_fault(f"the showIf of field {q(f['name'])} names a withheld parameter")
    for s in form["steps"]:
        if names_withheld(s.get("showIf")):
            raise platform_fault(f"the showIf of step {q(s['name'])} names a withheld parameter")
        refs = [s.get("walltimeField", ""), s.get("checkpointField", "")] + s.get("promoteFields", [])
        if s["classField"] is not None:
            refs.append(s["classField"])
        if any(r and withheld(r) for r in refs):
            raise platform_fault(f"step {q(s['name'])} refers to a withheld parameter")


# ---- step 7: stamp, digest ----------------------------------------------------------------------------------------

def params_digest(params):
    """sha256 of the final spec.arguments.parameters (names, order, defaults, valueFrom), contract §2.4."""
    items = [{"name": p["name"], "valueFrom": p["valueFrom"]} if "valueFrom" in p
             else {"name": p["name"], "value": p.get("value")} for p in params]
    text = json.dumps(items, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


def serialise(form):
    try:
        return json.dumps(form, sort_keys=True, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    except (ValueError, TypeError):
        raise refuse("the form holds a value that is not JSON") from None


# ---- step 8: sizes -------------------------------------------------------------------------------------------------

def _size(o):
    return len(json.dumps(o, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8", "replace"))


def check_sizes(form, annotations):
    """Warnings (a list) or a refusal. `annotations` is every WFT annotation after writing (key -> value)."""
    try:
        total = len(json.dumps(form, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    except UnicodeError:
        raise refuse("the form holds text that is not valid UTF-8") from None
    warnings = []
    if total > MAX_ANNOTATION_BYTES:
        od = sum(_size(f.get("optionDefaults", {})) for f in form.get("fields", []))
        sections = {"fields": sum(_size({k: v for k, v in f.items() if k != "optionDefaults"}) for f in form.get("fields", [])),
                    "machines": _size(form.get("machines", [])), "steps": _size(form.get("steps", [])),
                    "optionDefaults": od}
        biggest = max(sections, key=sections.get)
        raise refuse(f"the run form is {total} bytes, over the 128 KiB limit ({MAX_ANNOTATION_BYTES} bytes); the "
                     f"biggest part is {biggest} ({sections[biggest]} bytes)")
    if total > WARN_ANNOTATION_BYTES:
        warnings.append(f"run form: warning: the form is {total} bytes, over 75% of the {MAX_ANNOTATION_BYTES} byte limit")
    all_bytes = 0
    for k, v in annotations.items():
        if not isinstance(k, str) or not isinstance(v, str):
            raise refuse("a template annotation is not text")
        all_bytes += len(k.encode("utf-8", "replace")) + len(v.encode("utf-8", "replace"))
    if all_bytes > MAX_ALL_ANNOTATIONS_BYTES:
        raise refuse(f"the template's annotations are {all_bytes} bytes, over the Kubernetes limit of "
                     f"{MAX_ALL_ANNOTATIONS_BYTES} bytes (256 KiB)")
    return warnings


# ---- step 9: write ---------------------------------------------------------------------------------------------------

def write_atomic(path, text, mode):
    d, base = os.path.split(os.path.abspath(path))
    tmp = os.path.join(d, f".{base}.{os.getpid()}.{os.urandom(4).hex()}")
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                     stat.S_IMODE(mode) or 0o644)
        try:
            with os.fdopen(fd, "wb") as f:
                f.write(text.encode("utf-8"))
                f.flush()
                os.fsync(f.fileno())
        except BaseException:
            raise
        os.replace(tmp, path)
    except OSError:
        raise platform_fault("the sealed template could not be written") from None
    finally:
        if os.path.lexists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def dump_wft(wft):
    return yaml.safe_dump(wft, default_flow_style=False, allow_unicode=True, sort_keys=False)


# ---- the seal ----------------------------------------------------------------------------------------------------------

def seal(args, notes):
    wft, mode = load_wft(args.wft)
    ctx = load_context(args.context)
    form_data = load_form_data(args.form_data)
    steps = load_steps(args.steps)
    # step 1
    check_identity(wft, args.engine, args.source_commit)
    # step 2
    strip_forged(wft, ctx, args.engine)
    params_list = wft["spec"]["arguments"]["parameters"]
    param_names = [p["name"] for p in params_list]
    check_step_table(steps, wft)
    roles, step_of = _roles(params_list, form_data["rank"], {s["name"] for s in steps})
    # step 3, 4
    raw_parts = validate_raw(form_data.get("raw"), params_list, roles, notes)
    form_yaml = read_form_yaml(args.config_dir)
    # step 5, 6
    form, _withheld = build_form(wft, ctx, form_data, steps, form_yaml, raw_parts, roles, step_of, notes)
    check_form(form, param_names, None)

    previous = load_previous(args.previous)

    def sealed(commit):
        f = dict(form)
        f["version"] = 1
        f["stamp"] = {"by": STAMP_BY, "engine": args.engine, "commit": commit, "paramsDigest": params_digest(params_list)}
        text = serialise(f)
        out = copy.deepcopy(wft)
        out["metadata"].setdefault("annotations", None)
        if out["metadata"]["annotations"] is None:
            out["metadata"]["annotations"] = {}
        out["metadata"]["annotations"][ANNOTATION] = text
        return f, text, out

    commit = args.source_commit
    live = _live_commit(previous)
    if live:
        _f, _t, candidate = sealed(live)
        if candidate == previous:
            commit = live  # the render is unchanged: the commit that last changed the template stays
    f, text, out = sealed(commit)
    # step 8
    notes.extend(check_sizes(f, out["metadata"]["annotations"]))
    # step 9
    write_atomic(args.wft, dump_wft(out), mode)
    return (f"run form: sealed ({len(f['fields'])} fields, {len(f['machines'])} machines, {len(f['steps'])} steps, "
            f"{len(text.encode('utf-8'))} bytes, commit {commit[:12]})")


def _live_commit(previous):
    try:
        ann = previous["metadata"]["annotations"][ANNOTATION]
        c = json.loads(ann)["stamp"]["commit"]
        return c if isinstance(c, str) and COMMIT_RE.match(c) else None
    except Exception:  # noqa: BLE001
        return None


def parse_args(argv):
    ap = argparse.ArgumentParser(prog="run_form.py", description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("seal")
    for name in ("wft", "context", "form-data", "steps", "config-dir", "engine", "source-commit"):
        s.add_argument("--" + name, required=True, dest=name.replace("-", "_"))
    s.add_argument("--previous", default=None)
    return ap.parse_args(argv)


def fail_line(message):
    print("GATE FAIL: run form: " + " ".join(str(message).split()), file=sys.stderr)


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)  # argparse exits 2 on a bad invocation
    notes = []
    try:
        line = seal(args, notes)
    except SealError as e:
        fail_line(e.message)
        return e.code
    except Exception as e:  # noqa: BLE001 - nothing the seal did not classify may leak a traceback or input text
        print(f"GATE FAIL: run form: internal error ({type(e).__name__})", file=sys.stderr)
        return 3
    for n in notes:
        print(n, file=sys.stderr)
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
