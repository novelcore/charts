"""Tests of the trusted run-form seal, files/run_form.py (PRD novelcore/kaos#1533 F-21/F-22, contract §3, §8.4).

Run: python3 -m unittest discover -s charts/custom/kubecore-ci-workflows/tests/run-form-seal -p 'test_*.py'
(run.sh does). Needs python3 + PyYAML; `jsonschema` and, with RUN_FORM_OSR_DIR, `go` make the acceptance
checks stricter (the merged OSR consumer: Parse, CheckJoin, StampProblem) and are skipped otherwise.
Contract references: "2.2" is the consumer-check table, "3.3 step N" the ordered steps.
"""
import copy
import hashlib
import importlib.util
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).resolve().parent))
from seal_fixtures import (CHART, COMMIT, COMMIT2, ENGINE, HERE, MARKER, NAMESPACE, SEAL, Case, context,  # noqa: E402
                           form_data)

SCHEMA = HERE / "fixtures" / "run-form.schema.json"
SCHEMA_SHA256 = "c2a0f870e2f82f37a75c126c9c7087b1c36886973aa30a12da0281ab978f3098"
ANN = "ui.kubecore.io/run-form"
UPDATE = bool(os.environ.get("UPDATE_GOLDEN"))


def load_module():
    spec = importlib.util.spec_from_file_location("run_form_under_test", SEAL)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def ok(tc, r):
    tc.assertEqual(r.rc, 0, f"rc {r.rc}\nstdout: {r.out}\nstderr: {r.err}")
    return r.annotation()


def field(form, name):
    return next(f for f in form["fields"] if f["name"] == name)


def step(form, name):
    return next(s for s in form["steps"] if s["name"] == name)


# ---- the acceptance oracle, in Python: OSR join.go and runform.go, transcribed ---------------------------

TOKEN_RE = re.compile(r"[A-Za-z0-9_.-]+")


def osr_excluded(form):
    served = {g["id"] for g in form["groups"] if g["tier"] != "hidden"}
    return {f["name"] for f in form["fields"]
            if f["platform"] or f["source"] == "platform" or f["tier"] == "hidden" or f["group"] not in served}


def osr_check_join(form, params):
    ex = osr_excluded(form)
    withheld = lambda n: n.lower().startswith("image-") or n in ex  # noqa: E731
    names = {f["name"] for f in form["fields"]}
    for p in params:
        if p and not withheld(p) and p not in names:
            return "a template parameter has no entry in the form"
    names_w = lambda e: any(withheld(t) for t in TOKEN_RE.findall(e or ""))  # noqa: E731
    for f in form["fields"]:
        if f["name"] not in ex and names_w(f.get("showIf")):
            return "a showIf names a withheld parameter"
    for s in form["steps"]:
        if names_w(s.get("showIf")):
            return "a step showIf names a withheld parameter"
        refs = [s.get("walltimeField", ""), s.get("checkpointField", "")] + s.get("promoteFields", [])
        if s["classField"] is not None:
            refs.append(s["classField"])
        if any(r and withheld(r) for r in refs):
            return "a step refers to a withheld parameter"
    return None


def has_control(s):
    return any(ord(c) <= 0x1F or ord(c) == 0x7F for c in s)


def osr_checks(tc, r):
    """Everything of contract 2.2 that does not need Go, on a sealed WFT."""
    wft = r.case.load_wft()
    text = wft["metadata"]["annotations"][ANN]
    raw = text.encode("utf-8")
    tc.assertLessEqual(len(raw), 131072)  # 2.2 row 1
    seen = []

    def strict(pairs):
        keys = [k for k, _ in pairs]
        tc.assertEqual(len(keys), len(set(keys)), "duplicate key")
        return dict(pairs)

    def depth(o, d=1):
        if isinstance(o, dict):
            return max([d] + [depth(v, d + 1) for v in o.values()])
        if isinstance(o, list):
            return max([d] + [depth(v, d + 1) for v in o])
        return d

    form = json.loads(text, object_pairs_hook=strict, parse_constant=lambda c: tc.fail("NaN"))
    tc.assertLessEqual(depth(form), 32)
    tc.assertEqual(form["version"], 1)  # row 2
    tc.assertEqual(form["stamp"]["engine"], wft["metadata"]["annotations"]["platform.kubecore.io/engine-version"])  # row 3
    for f in form["fields"]:
        tc.assertFalse(has_control(f.get("showIf", "")))  # row 4
    for s in form["steps"]:
        tc.assertFalse(has_control(s.get("showIf", "")))
    names = [f["name"] for f in form["fields"]]
    tc.assertEqual(len(names), len(set(names)))  # row 5
    params = [p["name"] for p in wft["spec"]["arguments"]["parameters"]]
    tc.assertEqual(names, params)  # fields are exactly the Argo parameters, in Argo order
    tc.assertIsNone(osr_check_join(form, params))  # row 6
    for f in form["fields"]:  # row 7: submit
        if f["type"] == "enum":
            tc.assertTrue(next(p for p in wft["spec"]["arguments"]["parameters"] if p["name"] == f["name"]).get("enum"),
                          f"enum field {f['name']} without an Argo enum")
        if "pattern" in f:
            tc.assertLessEqual(len(f["pattern"]), 256)
            re.compile(f["pattern"])
            tc.assertNotRegex(f["pattern"], r"\(\?[=!<]|\\[1-9]")  # not RE2
    ex = osr_excluded(form)
    machine_names = {m["name"] for m in form["machines"]}
    for s in form["steps"]:  # row 10 (dapi)
        tc.assertTrue(set(s["offered"]) <= machine_names)
    for f in form["fields"]:
        for opts in f.get("optionDefaults", {}).values():
            for k in opts:
                tc.assertNotIn(k, ex)
                tc.assertFalse(k.lower().startswith("image-"))
    return form


# ---- tests ------------------------------------------------------------------------------------------------

class Base(unittest.TestCase):
    def case(self, **kw):
        c = Case(**kw)
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        return c

    def refused(self, r, code, fragment=None):
        self.assertEqual(r.rc, code, f"stdout: {r.out}\nstderr: {r.err}")
        self.assertTrue(r.unchanged, "the WFT file changed on a refusal")
        self.assertEqual(len(r.gate_lines()), 1, r.err)
        self.assertEqual(len([ln for ln in r.err.splitlines() if ln.strip()]), 1, r.err)
        self.assertNotIn(MARKER, r.err)
        self.assertNotIn(MARKER, r.out)
        if fragment:
            self.assertIn(fragment, r.err)


class TestSchemaCopy(Base):
    def test_fourth_copy_is_byte_identical(self):  # 2.1
        self.assertEqual(hashlib.sha256(SCHEMA.read_bytes()).hexdigest(), SCHEMA_SHA256)


class TestGolden(Base):
    def golden(self, name, annotation_text):
        path = HERE / "golden" / name
        if UPDATE:
            path.write_text(annotation_text + "\n")
        self.assertEqual(annotation_text + "\n", path.read_text(), "golden differs (UPDATE_GOLDEN=1 rewrites it)")

    def test_cluster_and_hpc_golden(self):
        c = self.case()
        r = c.run()
        form = ok(self, r)
        self.golden("base.json", c.load_wft()["metadata"]["annotations"][ANN])
        osr_checks(self, r)
        self.assertEqual(form["stamp"], {"by": "kubecore.run_form", "engine": ENGINE, "commit": COMMIT,
                                          "paramsDigest": form["stamp"]["paramsDigest"]})

    def test_cluster_only_golden(self):
        c = self.case(hpc=False)
        r = c.run()
        ok(self, r)
        self.golden("cluster-only.json", c.load_wft()["metadata"]["annotations"][ANN])
        form = osr_checks(self, r)
        self.assertEqual({m["kind"] for m in form["machines"]}, {"cluster"})

    def test_validates_against_the_json_schema(self):
        try:
            import jsonschema
        except ImportError:
            self.skipTest("jsonschema is not installed")
        schema = json.loads(SCHEMA.read_text())
        for hpc in (True, False):
            c = self.case(hpc=hpc)
            form = ok(self, c.run())
            jsonschema.Draft202012Validator(schema).validate(form)

    def test_stdout_line(self):  # 3.7
        r = self.case().run()
        m = re.fullmatch(r"run form: sealed \((\d+) fields, (\d+) machines, (\d+) steps, (\d+) bytes, commit "
                         r"([0-9a-f]{12})\)\n", r.out)
        self.assertIsNotNone(m, r.out)
        form = r.annotation()
        self.assertEqual(int(m[1]), len(form["fields"]))
        self.assertEqual(int(m[2]), len(form["machines"]))
        self.assertEqual(int(m[3]), len(form["steps"]))
        self.assertEqual(int(m[4]), len(r.case.load_wft()["metadata"]["annotations"][ANN].encode()))
        self.assertEqual(m[5], COMMIT[:12])

    def test_only_annotation_added_and_nothing_else(self):  # 3.3 step 9
        c = self.case()
        c.write()
        before = c.load_wft()
        r = c.run(write=False)
        ok(self, r)
        after = c.load_wft()
        del after["metadata"]["annotations"][ANN]
        self.assertEqual(after, before)
        self.assertNotIn("platform.kubecore.io/source-commit", before["metadata"]["annotations"])


class TestBuild(Base):
    """3.5: how each part is built."""

    @classmethod
    def setUpClass(cls):
        c = Case()
        cls.r = c.run()
        cls.form = cls.r.annotation()
        cls.root = c.root

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.root, ignore_errors=True)

    def test_role_info(self):
        f = field(self.form, "pipeline-info")
        self.assertEqual({k: f[k] for k in ("group", "type", "tier", "source", "platform")},
                         {"group": "info", "type": "text", "tier": "hidden", "source": "info", "platform": True})

    def test_role_experiment_and_raw_types(self):
        f = field(self.form, "experiment-name")
        self.assertEqual((f["source"], f["type"], f["tier"], f["group"], f["platform"]),
                         ("config", "string", "basic", "experiment", False))

    def test_role_setting_leaf_types_and_showif(self):
        lr = field(self.form, "learning-rate")
        self.assertEqual((lr["source"], lr["type"], lr["group"], lr["showIf"]),
                         ("config", "number", "settings", "optimizer == adam or optimizer == sgd"))
        self.assertEqual(field(self.form, "momentum")["showIf"], "optimizer == sgd")
        self.assertEqual(field(self.form, "epochs")["type"], "integer")
        self.assertEqual(field(self.form, "use-aug")["type"], "boolean")
        self.assertNotIn("showIf", field(self.form, "hf-token"))  # leaf under every option: always shown

    def test_role_setting_group_and_option_defaults(self):
        g = field(self.form, "optimizer")
        self.assertEqual((g["source"], g["type"], g["group"], g["tier"]), ("group", "enum", "settings", "basic"))
        # the credential-named leaf, the image-* leaf and the empty option are gone
        self.assertEqual(g["optionDefaults"], {"adam": {"learning-rate": "0.001"},
                                               "sgd": {"learning-rate": "0.1", "momentum": "0.9"}})

    def test_role_input(self):
        f = field(self.form, "dataset")
        self.assertEqual((f["source"], f["type"], f["picker"], f["group"], f["tier"]),
                         ("input", "string", "dataset", "datasets", "basic"))

    def test_role_class(self):
        f = field(self.form, "prep-class")
        self.assertEqual((f["source"], f["type"], f["picker"], f["group"], f["tier"], f["step"], f["label"]),
                         ("run-setting", "enum", "machine", "steps", "basic", "prep", "prep: machine"))

    def test_role_walltime_and_checkpoint(self):
        for name, label in (("prep-walltime", "prep: time limit"), ("train-checkpoint-every", "train: checkpoint every")):
            f = field(self.form, name)
            self.assertEqual((f["type"], f["tier"], f["group"], f["pattern"], f["minMinutes"], f["maxMinutes"], f["label"]),
                             ("duration", "advanced", "steps", "^[0-9]+[mh]?$", 1, 43200, label))

    def test_role_matrix_parallel(self):
        m, p = field(self.form, "train-matrix"), field(self.form, "train-parallel")
        self.assertEqual((m["type"], m["label"], m["tier"]), ("text", "train: runs", "advanced"))
        self.assertEqual((p["type"], p["label"], p["tier"]), ("string", "train: at the same time", "advanced"))

    def test_role_reuse_start_promote_advanced(self):
        for n in ("reuse-from-run", "start-from-step"):
            f = field(self.form, n)
            self.assertEqual((f["group"], f["tier"], f["type"], f["source"]), ("rerun", "advanced", "string", "run-setting"))
        p = field(self.form, "promote-cleaned")
        self.assertEqual((p["group"], p["tier"], p["type"], p["step"], p["label"]),
                         ("promote", "advanced", "enum", "prep", "Promote cleaned"))
        a = field(self.form, "config")
        self.assertEqual((a["group"], a["tier"], a["type"], a["source"]), ("advanced", "advanced", "yaml", "advanced"))

    def test_step_when_becomes_showif_normalised(self):
        for n in ("evaluate-class", "evaluate-walltime"):
            self.assertEqual(field(self.form, n)["showIf"], 'optimizer == "adam"')
        self.assertEqual(step(self.form, "evaluate")["showIf"], 'optimizer == "adam"')
        # a when= that reads a step result gives none
        self.assertNotIn("showIf", step(self.form, "report"))
        self.assertNotIn("showIf", field(self.form, "report-walltime"))

    def test_groups(self):
        self.assertEqual([(g["id"], g["order"], g["tier"]) for g in self.form["groups"]],
                         [("info", 0, "hidden"), ("experiment", 1, "basic"), ("settings", 2, "basic"),
                          ("datasets", 3, "basic"), ("steps", 4, "basic"), ("rerun", 5, "advanced"),
                          ("promote", 6, "advanced"), ("advanced", 7, "advanced")])  # no empty group, no platform

    def test_machines(self):
        by = {m["name"]: m for m in self.form["machines"]}
        self.assertEqual(list(by), ["cpu-standard", "kubecorecpu", "gpu-t4", "meluxina-gpu", "meluxina-cpu"])
        self.assertEqual(by["gpu-t4"], {
            "name": "gpu-t4", "tier": "gpu", "machineType": "n1-standard-8",
            "accelerator": {"type": "nvidia-tesla-t4", "count": 1},
            "allocatable": {"cpu": 7, "memoryGiB": 25, "ephemeralStorageGiB": None},
            "description": "n1-standard-8 + 1x T4", "kind": "cluster"})
        self.assertEqual(by["meluxina-gpu"], {
            "name": "meluxina-gpu", "tier": "gpu", "machineType": None, "accelerator": {"type": None, "count": 4},
            "allocatable": {"cpu": 128, "memoryGiB": 512, "ephemeralStorageGiB": None},
            "description": "4x A100-40GB, 2x EPYC 7452, 512 GB", "kind": "hpc",
            "hpc": {"provider": "meluxina", "partition": "gpu", "qos": "default", "gpus": 4,
                    "maxTimeLimitMinutes": 2880, "sharesNode": True}})
        self.assertIsNone(by["meluxina-cpu"]["accelerator"])
        self.assertNotIn("maxTimeLimitMinutes", by["meluxina-cpu"]["hpc"])

    def test_machines_never_copy_site_or_node_data(self):
        text = json.dumps(self.form["machines"])
        for bad in ("toleration", "maxNodeCount", "diskSizeGb", "PLACEHOLDER-account", "PLACEHOLDER-user", "scratch",
                    "account", "\"user\"", "controller"):
            self.assertNotIn(bad, text)

    def test_steps(self):
        prep = step(self.form, "prep")
        self.assertEqual(prep["classField"], "prep-class")
        self.assertEqual(prep["default"], "cpu-standard")
        self.assertEqual(prep["offered"], ["cpu-standard", "kubecorecpu"])
        self.assertIn("meluxina-cpu", prep["refused"])
        self.assertEqual((prep["walltimeField"], prep["promoteFields"], prep["kind"]),
                         ("prep-walltime", ["promote-cleaned"], "transform"))
        train = step(self.form, "train")
        self.assertEqual((train["walltimeField"], train["checkpointField"]), ("train-walltime", "train-checkpoint-every"))
        pinned = step(self.form, "report")
        self.assertEqual((pinned["classField"], pinned["default"], pinned["offered"], pinned["refused"]),
                         (None, "cpu-standard", ["cpu-standard"], {}))
        self.assertEqual([s["name"] for s in self.form["steps"]], ["prep", "train", "evaluate", "report"])

    def test_refused_is_verbatim(self):
        self.assertEqual(step(self.form, "train")["refused"]["gpu-t4"][1],
                         "Add gpu=True to the step in pipeline.py to run it on a GPU machine.")

    def test_type_fallback_to_string_when_default_does_not_parse(self):
        c = Case()
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        c.param("learning-rate")["value"] = "1e-4"  # not OSR's numberRE
        f = field(ok(self, c.run()), "learning-rate")
        self.assertEqual(f["type"], "string")

    def test_enum_only_where_argo_has_an_enum(self):
        c = Case()
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        c.raw(lambda r: r["types"].update({"epochs": "enum"}))
        self.assertEqual(field(ok(self, c.run()), "epochs")["type"], "string")

    def test_without_raw_form_leaves_are_enum_or_string(self):  # 3.3 step 3
        c = Case()
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        c.form_data["raw"] = None
        form = ok(self, c.run())
        self.assertEqual(field(form, "epochs")["type"], "string")
        self.assertEqual(field(form, "optimizer")["type"], "enum")
        self.assertEqual(field(form, "optimizer")["source"], "config")  # no way to know it is a group

    def test_platform_role_and_image_names_are_withheld(self):
        c = Case()
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        c.wft["spec"]["arguments"]["parameters"] += [{"name": "extra", "value": "x"}, {"name": "image-train", "value": "i"},
                                                     {"name": "Image-Prep", "value": "i"}]
        for n, role in (("extra", "platform"), ("image-train", "setting"), ("Image-Prep", "setting")):
            c.form_data["rank"][n] = {"role": role, "step": None, "sort": [99, 0]}
        r = c.run()
        form = osr_checks(self, r)
        for n in ("extra", "image-train", "Image-Prep"):
            f = field(form, n)
            self.assertEqual((f["source"], f["tier"], f["group"], f["platform"]), ("platform", "hidden", "platform", True))
        self.assertEqual(form["groups"][-1]["id"], "platform")


class TestShowIfDrop(Base):
    """3.5: a showIf OSR's join check would reject is dropped, never a build failure."""

    def sealed(self, mutate):
        c = self.case()
        mutate(c)
        r = c.run()
        form = osr_checks(self, r)
        return c, form

    def test_hidden_field_carries_no_showif(self):
        def m(c):
            c.form_yaml = "fields:\n  momentum: {tier: hidden}\n"
        c, form = self.sealed(m)
        f = field(form, "momentum")
        self.assertEqual(f["tier"], "hidden")
        self.assertNotIn("showIf", f)  # it had `optimizer == sgd`

    def test_hidden_field_with_long_condition_does_not_invalidate(self):
        def m(c):
            c.form_yaml = "fields:\n  momentum: {tier: hidden}\n"
            c.wft["spec"]["arguments"]["parameters"][3]["enum"] = ["adam", "sgd", "lion"] + [f"o{i}" for i in range(60)]
            c.raw(lambda r: r["leafOptions"].update({"momentum": {"group": "optimizer", "options": [f"o{i}" for i in range(60)]}}))
        c, form = self.sealed(m)
        self.assertNotIn("showIf", field(form, "momentum"))

    def test_when_value_image_classification_is_dropped(self):
        def m(c):
            c.steps[2]["when_text"] = "optimizer == image-classification"
        c, form = self.sealed(m)
        self.assertNotIn("showIf", step(form, "evaluate"))
        self.assertNotIn("showIf", field(form, "evaluate-class"))

    def test_leaf_option_named_image_x_is_dropped(self):
        def m(c):
            c.wft["spec"]["arguments"]["parameters"][3]["enum"] = ["adam", "sgd", "lion", "image-x"]
            c.raw(lambda r: r["leafOptions"]["momentum"].update({"options": ["sgd", "image-x"]}))
        c, form = self.sealed(m)
        self.assertNotIn("showIf", field(form, "momentum"))
        self.assertIn("showIf", field(form, "learning-rate"))  # others stay

    def test_value_equal_to_hidden_field_name_is_dropped(self):
        def m(c):
            c.steps[2]["when_text"] = "optimizer == pipeline-info"
        c, form = self.sealed(m)
        self.assertNotIn("showIf", step(form, "evaluate"))

    def test_and_or_equal_to_hidden_field_name_is_dropped(self):
        def m(c):
            c.wft["spec"]["arguments"]["parameters"].append({"name": "and", "value": "x"})
            c.form_data["rank"]["and"] = {"role": "platform", "step": None, "sort": [99, 0]}
            c.steps[2]["when_text"] = 'optimizer == "adam" and use-aug == true'
        c, form = self.sealed(m)
        self.assertNotIn("showIf", step(form, "evaluate"))

    def test_control_character_and_overlong_are_dropped(self):
        for bad in ('optimizer == "a\x01b"', 'optimizer == "' + "a" * 1100 + '"'):
            def m(c, bad=bad):
                c.steps[2]["when_text"] = bad
            c, form = self.sealed(m)
            self.assertNotIn("showIf", step(form, "evaluate"), repr(bad[:20]))

    def test_unparsable_when_is_dropped(self):
        for bad in ("optimizer", "optimizer = adam", "optimizer == adam AND use-aug == true", "a == b and", "== x"):
            def m(c, bad=bad):
                c.steps[2]["when_text"] = bad
            c, form = self.sealed(m)
            self.assertNotIn("showIf", step(form, "evaluate"), bad)

    def test_when_reading_a_withheld_field_is_dropped(self):
        def m(c):
            c.form_yaml = "fields:\n  use-aug: {tier: hidden}\n"
            c.steps[2]["when_text"] = "use-aug == true"
        c, form = self.sealed(m)
        self.assertNotIn("showIf", step(form, "evaluate"))

    def test_dotted_when_name_maps_to_the_field(self):
        def m(c):
            c.steps[2]["when_text"] = "experiment.name == run1"
        c, form = self.sealed(m)
        self.assertEqual(step(form, "evaluate")["showIf"], "experiment-name == run1")

    def test_when_joined_comparisons_are_single_spaced(self):
        def m(c):
            c.steps[2]["when_text"] = "use-aug   ==  true   or   epochs !=   '5'"
        c, form = self.sealed(m)
        self.assertEqual(step(form, "evaluate")["showIf"], "use-aug == true or epochs != '5'")


REAL = HERE / "fixtures" / "real"


class RealCase(Case):
    """A Case whose inputs are real engine output (fixtures/real/<name>), engine 0.9.9."""

    def __init__(self, name, **kw):
        super().__init__(**kw)
        d = REAL / name
        self.wft = yaml.safe_load((d / "workflow-template.yaml").read_text())
        self.ctx = yaml.safe_load((d / "context.yaml").read_text())
        self.steps = json.loads((d / "steps.json").read_text())
        self.form_data = json.loads((d / "form-data.json").read_text())
        self.engine = "0.9.9"


class TestRealEngine(Base):
    """Fixtures produced by the real engine (kaos-hpc-operator feature/1533-f21-seal-hooks), not by hand."""
    NAMES = ("tests-app", "extended-app", "pinned-step")

    def test_every_real_render_seals_and_is_golden(self):
        for name in self.NAMES:
            with self.subTest(name):
                c = RealCase(name)
                self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
                r = c.run()
                form = ok(self, r)
                osr_checks(self, r)
                golden = HERE / "golden" / f"real-{name}.json"
                text = c.load_wft()["metadata"]["annotations"][ANN]
                if UPDATE:
                    golden.write_text(text + "\n")
                self.assertEqual(text + "\n", golden.read_text())
                try:
                    import jsonschema
                    jsonschema.Draft202012Validator(json.loads(SCHEMA.read_text())).validate(form)
                except ImportError:
                    pass

    def test_dataset_input_is_a_dataset_picker_and_its_type_entry_is_ignored(self):
        c = RealCase("tests-app")
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        raw = json.loads(c.form_data["raw"])
        self.assertIn("dataset", raw["types"])  # the engine does type the input leaf
        r = c.run()
        f = field(ok(self, r), "dataset")
        self.assertEqual((f["source"], f["picker"], f["type"]), ("input", "dataset", "string"))
        self.assertIn("raw form type of dataset ignored", r.err)

    def test_real_shapes(self):
        c = RealCase("extended-app")
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        form = ok(self, c.run())
        train = step(form, "train")
        self.assertTrue(train["walltimeField"] and train["checkpointField"])
        self.assertTrue(any(m["kind"] == "hpc" for m in form["machines"]))
        self.assertTrue(any(f.get("optionDefaults") for f in form["fields"]))
        for f in form["fields"]:
            for opts in f.get("optionDefaults", {}).values():
                self.assertFalse([k for k in opts if "token" in k])  # the credential-like leaf is dropped
        pinned = RealCase("pinned-step")
        self.addCleanup(shutil.rmtree, pinned.root, ignore_errors=True)
        pf = ok(self, pinned.run())
        self.assertTrue(any(s["classField"] is None for s in pf["steps"]))

    def test_real_render_keeps_the_commit_when_unchanged(self):
        c = RealCase("extended-app")
        self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
        ok(self, c.run())
        sealed = c.load_wft()
        c2 = RealCase("extended-app")
        self.addCleanup(shutil.rmtree, c2.root, ignore_errors=True)
        c2.commit = COMMIT2
        c2.previous = sealed
        self.assertEqual(ok(self, c2.run())["stamp"]["commit"], COMMIT)


class TestStrip(Base):
    """3.3 step 2 and step 1."""

    def test_forged_ui_keys_are_deleted_in_all_four_places(self):
        c = self.case()
        c.wft["metadata"]["labels"]["ui.kubecore.io/x"] = "1"
        c.wft["metadata"]["annotations"][ANN] = "FORGED"
        c.wft["metadata"]["annotations"]["ui.kubecore.io/raw-form"] = "{}"
        c.wft["spec"]["workflowMetadata"]["labels"]["ui.kubecore.io/y"] = "1"
        c.wft["spec"]["workflowMetadata"]["annotations"] = {"ui.kubecore.io/z": "1", "keep": "me"}
        w = ok(self, c.run()) and c.load_wft()
        self.assertEqual(w["metadata"]["labels"].keys() & {"ui.kubecore.io/x"}, set())
        self.assertNotEqual(w["metadata"]["annotations"][ANN], "FORGED")
        self.assertNotIn("ui.kubecore.io/raw-form", w["metadata"]["annotations"])
        self.assertNotIn("ui.kubecore.io/y", w["spec"]["workflowMetadata"]["labels"])
        self.assertEqual(w["spec"]["workflowMetadata"]["annotations"], {"keep": "me"})

    def test_forged_labels_from_keys_are_deleted(self):  # I-1: Argo applies labelsFrom over the run's own labels
        c = self.case()
        c.wft["spec"]["workflowMetadata"]["labelsFrom"] = {
            "platform.kubecore.io/submitted-by": {"expression": "'forged'"},
            "platform.kubecore.io/app": {"expression": "'other-app'"},
            "ui.kubecore.io/anything": {"expression": "'x'"},
            "team.example.io/keep": {"expression": "workflow.name"}}
        ok(self, c.run())
        lf = c.load_wft()["spec"]["workflowMetadata"]["labelsFrom"]
        self.assertEqual(lf, {"team.example.io/keep": {"expression": "workflow.name"}})

    def test_labels_from_emptied_is_left_as_an_empty_mapping_or_absent(self):
        c = self.case()
        c.wft["spec"]["workflowMetadata"]["labelsFrom"] = {"platform.kubecore.io/source-commit": {"expression": "'x'"}}
        ok(self, c.run())
        self.assertEqual(c.load_wft()["spec"]["workflowMetadata"].get("labelsFrom") or {}, {})

    def test_labels_from_not_a_mapping_is_3(self):
        c = self.case()
        c.wft["spec"]["workflowMetadata"]["labelsFrom"] = ["platform.kubecore.io/app"]
        self.refused(c.run(), 3, "labelsFrom")

    def test_unknown_platform_keys_are_deleted_everywhere(self):
        c = self.case()
        c.wft["metadata"]["labels"]["platform.kubecore.io/evil"] = "1"
        c.wft["metadata"]["annotations"]["platform.kubecore.io/source-commit"] = "deadbeef"
        c.wft["spec"]["workflowMetadata"]["labels"]["platform.kubecore.io/source-commit"] = "deadbeef"
        c.wft["spec"]["workflowMetadata"]["annotations"] = {"platform.kubecore.io/params-digest": "x"}
        c.wft["metadata"]["labels"]["other.io/keep"] = "1"
        ok(self, c.run())
        w = c.load_wft()
        keys = list(w["metadata"]["labels"]) + list(w["metadata"]["annotations"]) + list(w["spec"]["workflowMetadata"]["labels"]) \
            + list(w["spec"]["workflowMetadata"].get("annotations", {}))
        self.assertEqual(sorted(k for k in keys if k.startswith("platform.kubecore.io/")), sorted([
            "platform.kubecore.io/project", "platform.kubecore.io/app", "platform.kubecore.io/managed-by",
            "platform.kubecore.io/generated-by", "platform.kubecore.io/cost-tracking",
            "platform.kubecore.io/engine-version", "platform.kubecore.io/engine"]))
        self.assertEqual(w["metadata"]["labels"]["other.io/keep"], "1")

    def test_step_template_labels_are_untouched(self):
        c = self.case()
        c.wft["spec"]["templates"][6]["metadata"] = {"labels": {"platform.kubecore.io/step-kind": "transform"}}
        ok(self, c.run())
        self.assertEqual(c.load_wft()["spec"]["templates"][6]["metadata"]["labels"],
                         {"platform.kubecore.io/step-kind": "transform"})

    def test_forged_allowlisted_values_fail(self):
        cases = [
            ("project", lambda w: w["metadata"]["labels"].update({"platform.kubecore.io/project": "other"})),
            ("app", lambda w: w["metadata"]["labels"].update({"platform.kubecore.io/app": "other"})),
            ("managed-by", lambda w: w["metadata"]["labels"].update({"platform.kubecore.io/managed-by": "me"})),
            ("generated-by", lambda w: w["metadata"]["annotations"].update({"platform.kubecore.io/generated-by": "me"})),
            ("cost-tracking", lambda w: w["metadata"]["annotations"].update({"platform.kubecore.io/cost-tracking": "off"})),
        ]
        for name, mut in cases:
            c = self.case()
            mut(c.wft)
            self.refused(c.run(), 1, "platform.kubecore.io/" + name)

    def test_foreign_namespace_fails(self):
        c = self.case()
        c.wft["metadata"]["namespace"] = "someone-elses-runtime"
        self.refused(c.run(), 1, "namespace")
        c = self.case()
        del c.wft["metadata"]["namespace"]
        self.refused(c.run(), 1, "namespace")

    def test_engine_mismatch_is_a_platform_fault(self):  # 3.3 step 1, exit 3
        c = self.case()
        c.engine = "0.99.0"
        self.refused(c.run(), 3, "engine")
        c = self.case()
        c.wft["metadata"]["annotations"]["platform.kubecore.io/engine-version"] = "0.1.0"
        self.refused(c.run(), 3, "engine")
        c = self.case()
        c.wft["spec"]["workflowMetadata"]["labels"]["platform.kubecore.io/engine"] = "0.1.0"
        self.refused(c.run(), 3, "engine")
        c = self.case()
        del c.wft["spec"]["workflowMetadata"]["labels"]["platform.kubecore.io/engine"]
        self.refused(c.run(), 3, "engine")

    def test_bad_commit_and_engine_strings(self):  # 3.3 step 1
        for commit in ("", "ABCDEF" + "a" * 34, COMMIT[:-1], COMMIT + "a", COMMIT[:-1] + ";"):
            c = self.case()
            c.commit = commit
            self.refused(c.run(), 3, "commit")
        for engine in ("", "_x", "a b", "x" * 64):
            c = self.case()
            c.engine = engine
            self.refused(c.run(), 3, "engine")


class TestFailClosed(Base):
    """3.7: exit codes, the file byte-unchanged, one GATE FAIL line, no input bytes."""

    def check(self, mutate, code, fragment=None):
        c = self.case()
        mutate(c)
        self.refused(c.run(), code, fragment)
        return c

    def test_bad_invocation_is_2(self):
        c = self.case()
        r = c.run(args=["seal", "--wft", str(c.wft_path)])
        self.assertEqual(r.rc, 2)
        self.assertTrue(r.unchanged)

    def test_missing_form_data_is_3(self):
        c = self.case()
        c.write()
        os.unlink(c.root / "form-data.json")
        self.refused(c.run(write=False), 3, "form-data")

    def test_malformed_form_data_is_3(self):
        for text in ("not json", "[]", '{"version": 2}', '{"version":1}', json.dumps({"version": 1, "offers": []})):
            c = self.case()
            c.raw_texts["form-data.json"] = text
            self.refused(c.run(), 3, "form-data")

    def test_form_data_strict_json(self):
        c = self.case()
        c.raw_texts["form-data.json"] = '{"version":1,"version":1,"note":"%s"}' % MARKER
        self.refused(c.run(), 3)
        c = self.case()
        c.raw_texts["form-data.json"] = '{"version":NaN}'
        self.refused(c.run(), 3)
        c = self.case()
        c.raw_texts["form-data.json"] = "[" * 40 + "]" * 40
        self.refused(c.run(), 3)

    def test_context_without_classes_is_3(self):
        self.check(lambda c: c.ctx.update({"computeClasses": {}}), 3, "context")
        self.check(lambda c: c.ctx.pop("computeClasses"), 3, "context")

    def test_context_missing_identity_is_3(self):
        self.check(lambda c: c.ctx.pop("project"), 3, "context")

    def test_offered_class_without_machine_is_3(self):
        def m(c):
            c.form_data["offers"]["train"]["offered"].append("ghost")
            c.param("train-class")["enum"].append("ghost")
        self.check(m, 3, "ghost")

    def test_unknown_role_is_3(self):
        self.check(lambda c: c.form_data["rank"]["epochs"].update({"role": "mystery"}), 3, "role")

    def test_missing_rank_entry_is_3(self):
        self.check(lambda c: c.form_data["rank"].pop("epochs"), 3, "epochs")

    def test_class_enum_must_equal_offered_is_3(self):
        self.check(lambda c: c.param("prep-class").update({"enum": ["cpu-standard"]}), 3, "prep-class")
        self.check(lambda c: c.param("prep-class").pop("enum"), 3, "prep-class")

    def test_class_default_outside_offered_is_3(self):
        self.check(lambda c: c.param("prep-class").update({"value": "kubecorecpu-x"}), 3, "prep-class")

    def test_pinned_and_class_param_together_is_3(self):
        self.check(lambda c: c.form_data["offers"].update({"prep": None}) or c.form_data["pinned"].update({"prep": "cpu-standard"}), 3)

    def test_wft_symlink_fifo_oversize_are_3(self):
        c = self.case()
        c.write()
        target = c.root / "elsewhere.yaml"
        shutil.move(str(c.wft_path), str(target))
        os.symlink(target, c.wft_path)
        r = c.run(write=False)
        self.assertEqual(r.rc, 3, r.err)
        self.assertEqual(len(r.gate_lines()), 1)
        self.assertTrue(c.wft_path.is_symlink())  # nothing replaced it
        c = self.case()
        c.write()
        c.wft_path.write_text("a: " + "x" * (4 * 1024 * 1024 + 1) + "\n")
        r = c.run(write=False)
        self.assertEqual(r.rc, 3)
        c = self.case()
        c.write()
        c.wft_path.unlink()
        os.mkfifo(c.wft_path)
        r = c.run(write=False)
        self.assertEqual(r.rc, 3)

    def test_wft_not_a_workflow_is_3(self):
        c = self.case()
        c.write()
        c.wft_path.write_text("- just\n- a list\n")
        before = c.wft_path.read_bytes()
        r = c.run(write=False)
        self.assertEqual(r.rc, 3)
        self.assertEqual(c.wft_path.read_bytes(), before)

    def test_input_files_over_their_limits_are_3(self):
        for name in ("context.yaml", "form-data.json", "steps.json"):
            c = self.case()
            c.raw_texts[name] = " " * (2 * 1024 * 1024 + 1)
            self.refused(c.run(), 3)

    def test_bad_steps_json_is_3(self):
        c = self.case()
        c.raw_texts["steps.json"] = "not json"
        self.refused(c.run(), 3, "steps")

    def test_no_input_bytes_in_stderr(self):
        c = self.case()
        c.param("epochs")["description"] = MARKER
        c.raw_texts["context.yaml"] = "project: [%s\n" % MARKER  # a YAML error quotes its input
        self.refused(c.run(), 3)
        c = self.case()
        c.raw_texts["form-data.json"] = '{"version": %s}' % MARKER
        self.refused(c.run(), 3)
        c = self.case()
        c.raw_texts["workflow-template.yaml"] = "a: [%s\n" % MARKER
        self.refused(c.run(), 3)

    def test_catch_all_in_process(self):
        mod = load_module()
        c = self.case()
        c.write()
        before = c.wft_path.read_bytes()

        def boom(*a, **k):
            raise RuntimeError("detail " + MARKER)
        mod.build_form = boom
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = mod.main(c.args())
        self.assertEqual(rc, 3)
        self.assertEqual(err.getvalue(), "GATE FAIL: run form: internal error (RuntimeError)\n")
        self.assertEqual(out.getvalue(), "")
        self.assertEqual(c.wft_path.read_bytes(), before)

    def test_catch_all_on_a_real_unexpected_value(self):
        c = self.case()
        c.wft["spec"]["arguments"]["parameters"][1]["value"] = __import__("datetime").date(2020, 1, 1)  # not JSON
        r = c.run()
        self.assertIn(r.rc, (1, 3))
        self.assertTrue(r.unchanged)
        self.assertEqual(len(r.gate_lines()), 1)
        self.assertNotIn("Traceback", r.err)

    def test_write_failure_leaves_no_temp_file_and_no_annotation(self):
        c = self.case()
        c.write()
        before = c.wft_path.read_bytes()
        os.chmod(c.out, 0o500)
        try:
            if os.geteuid() == 0:
                self.skipTest("root ignores directory modes")
            r = c.run(write=False)
        finally:
            os.chmod(c.out, 0o700)
        self.assertEqual(r.rc, 3)
        self.assertEqual(c.wft_path.read_bytes(), before)
        self.assertEqual(sorted(p.name for p in c.out.iterdir()), ["workflow-template.yaml"])


class TestLimits(Base):
    """3.6 and 3.3 step 8."""

    def test_annotation_size_boundary(self):
        mod = load_module()
        self.assertEqual((mod.MAX_ANNOTATION_BYTES, mod.WARN_ANNOTATION_BYTES, mod.MAX_ALL_ANNOTATIONS_BYTES),
                         (131072, 98304, 262144))

        def form_of(n):
            base = {"fields": [], "machines": [], "steps": []}
            pad = n - len(json.dumps(dict(base, pad=""), sort_keys=True, separators=(",", ":")).encode())
            f = dict(base, pad="a" * pad)
            self.assertEqual(len(json.dumps(f, sort_keys=True, separators=(",", ":")).encode()), n)
            return f
        self.assertEqual(len(mod.check_sizes(form_of(131072), {})), 1)  # passes, with the warning
        with self.assertRaises(mod.SealError) as e:
            mod.check_sizes(form_of(131073), {})
        self.assertEqual(e.exception.code, 1)
        warns = mod.check_sizes(form_of(98305), {})
        self.assertEqual(len(warns), 1)
        self.assertEqual(mod.check_sizes(form_of(98304), {}), [])

    def test_oversize_names_the_biggest_section(self):
        mod = load_module()
        big = {"fields": [{"name": "x" * 100}] * 2000, "machines": [{"name": "y" * 10}], "steps": []}
        with self.assertRaises(mod.SealError) as e:
            mod.check_sizes(big, {})
        self.assertIn("fields", e.exception.message)

    def test_all_annotations_total(self):
        mod = load_module()
        form = {"fields": [], "machines": [], "steps": []}
        self.assertEqual(mod.check_sizes(form, {"k": "a" * (262144 - 1 - 2)}) is not None, True)
        with self.assertRaises(mod.SealError):
            mod.check_sizes(form, {"k": "a" * 262144})

    def test_oversize_form_end_to_end_is_1(self):
        c = self.case()
        params = c.wft["spec"]["arguments"]["parameters"]
        for i in range(700):
            n = f"p{i:04d}-" + "n" * 240
            params.append({"name": n, "value": "1"})
            c.form_data["rank"][n] = {"role": "setting", "step": None, "sort": [100 + i, 0]}
        self.refused(c.run(), 1, "128 KiB")

    def test_annotations_total_end_to_end_is_1(self):
        c = self.case()
        c.wft["metadata"]["annotations"]["note"] = "a" * 262144
        self.refused(c.run(), 1, "annotations")

    def test_too_many_fields_is_1(self):
        c = self.case()
        params = c.wft["spec"]["arguments"]["parameters"]
        for i in range(1001):
            n = f"q{i}"
            params.append({"name": n, "value": "1"})
            c.form_data["rank"][n] = {"role": "setting", "step": None, "sort": [100 + i, 0]}
        self.refused(c.run(), 1, "fields")

    def test_name_that_breaks_the_schema_pattern_is_1(self):
        c = self.case()
        c.wft["spec"]["arguments"]["parameters"].append({"name": "_bad name", "value": "1"})
        c.form_data["rank"]["_bad name"] = {"role": "setting", "step": None, "sort": [100, 0]}
        self.refused(c.run(), 1)

    def test_machine_description_is_cut_to_512_bytes(self):
        c = self.case()
        c.ctx["computeClasses"]["all"][0]["description"] = "é" * 400
        form = ok(self, c.run())
        d = form["machines"][0]["description"]
        self.assertLessEqual(len(d.encode()), 512)
        self.assertLessEqual(len(d), 512)
        self.assertTrue(d.startswith("é"))


class TestStepTable(Base):
    """3.2 `--steps` and 3.3 step 6."""

    def test_missing_step_is_1(self):
        c = self.case()
        c.steps.pop(1)
        self.refused(c.run(), 1, "train")

    def test_extra_step_is_1(self):
        c = self.case()
        c.steps.append({"name": "ghost", "kind": "train", "inputs": [], "produces": []})
        self.refused(c.run(), 1, "ghost")

    def test_bad_kind_is_1(self):
        c = self.case()
        c.steps[0]["kind"] = "deploy"
        self.refused(c.run(), 1, "kind")

    def test_bad_shapes_are_1(self):
        for mut in (lambda s: s[0].update({"inputs": "dataset"}), lambda s: s[0].update({"produces": [1]}),
                    lambda s: s[0].update({"name": 5}), lambda s: s[0].update({"when_text": 5}),
                    lambda s: s[0].update({"matrix": []}), lambda s: s.append(copy.deepcopy(s[0])),
                    lambda s: s[0].update({"name": "main"}), lambda s: s[0].update({"name": "A_b"}),
                    lambda s: s[0].update({"name": "a" * 41})):
            c = self.case()
            mut(c.steps)
            self.refused(c.run(), 1)

    def test_engine_owned_templates_are_not_steps(self):
        c = self.case()  # main, compose-and-validate, hpc-follower, kaos-* are in the base template list
        ok(self, c.run())

    def test_only_the_engines_own_template_names_are_owned(self):
        for name in ("train-hpc", "kaos-other", "hpc-other", "kaos-gather-ghost", "kaos-matrix-ghost", "kaos-promote-x",
                     "hpc-follower-2", "kaos-gather-"):
            c = self.case()
            c.wft["spec"]["templates"].append({"name": name, "container": {"image": "x"}})
            self.refused(c.run(), 1, name.strip("-") if name.endswith("-") else name)

    def test_the_real_engine_template_set_passes(self):
        c = self.case()
        names = {t["name"] for t in c.wft["spec"]["templates"]}
        self.assertTrue({"compose-and-validate", "main", "kaos-promote", "kaos-gather-train", "kaos-matrix-train",
                         "hpc-follower"} <= names)
        ok(self, c.run())

    def test_extra_user_template_is_1(self):
        c = self.case()
        c.wft["spec"]["templates"].append({"name": "sneaky", "container": {"image": "x"}})
        self.refused(c.run(), 1, "sneaky")

    def test_walltime_param_of_a_step_outside_the_table_is_3(self):
        c = self.case()
        c.form_data["rank"]["epochs"] = {"role": "walltime", "step": "nostep", "sort": [1, 0]}
        self.refused(c.run(), 3, "epochs")


class TestRawForm(Base):
    """3.3 step 3 (T-12): the raw form is author data."""

    def raw_text(self, text, code=1):
        c = self.case()
        c.form_data["raw"] = text
        self.refused(c.run(), code)

    def test_duplicate_key(self):
        self.raw_text('{"version":1,"version":1,"types":{},"optionDefaults":{},"leafOptions":{"a":"%s","a":"b"}}' % MARKER)

    def test_nan_and_infinity(self):
        self.raw_text('{"version":1,"types":{"epochs":NaN}}')
        self.raw_text('{"version":1,"types":{"epochs":Infinity}}')

    def test_depth_33(self):
        deep = "[" * 31 + "]" * 31  # + the object and the member: 33
        self.raw_text('{"version":1,"types":{},"optionDefaults":{},"leafOptions":{"x":%s}}' % deep)
        self.raw_text("[" * 100000)

    def test_not_an_object_or_bad_utf8_or_trailing(self):
        for t in ("[]", "1", '{"version":1} x', '{"version":1,"types":"\\ud800"}', ""):
            self.raw_text(t)

    def test_over_128_kib(self):
        self.raw_text('{"version":1,"types":{},"optionDefaults":{},"leafOptions":{},"pad":"' + "a" * 131072 + '"}')

    def test_unknown_key_and_wrong_version(self):
        c = self.case()
        c.raw(lambda r: r.update({"extra": 1}))
        self.refused(c.run(), 1)
        c = self.case()
        c.raw(lambda r: r.update({"version": 2}))
        self.refused(c.run(), 1)

    def test_types_must_be_known_and_name_experiment_or_setting(self):
        for mut in (lambda r: r["types"].update({"epochs": "float"}), lambda r: r["types"].update({"nope": "string"}),
                    lambda r: r["types"].update({"epochs": 5}), lambda r: r.update({"types": []})):
            c = self.case()
            c.raw(mut)
            self.refused(c.run(), 1)

    def test_types_of_a_non_config_role_are_ignored_with_one_line(self):  # C-1: H4 types every leaf, an input's too
        c = self.case()
        c.raw(lambda r: r["types"].update({"dataset": "string", "train-class": "enum", "prep-walltime": "integer",
                                           "pipeline-info": "string"}))
        r = c.run()
        form = ok(self, r)
        d = field(form, "dataset")
        self.assertEqual((d["type"], d["picker"], d["source"]), ("string", "dataset", "input"))
        self.assertEqual(field(form, "train-class")["type"], "enum")
        self.assertEqual(field(form, "prep-walltime")["type"], "duration")
        self.assertEqual(r.err.count("raw form type of dataset ignored"), 1, r.err)
        self.assertEqual(len([ln for ln in r.err.splitlines() if "ignored" in ln]), 4)
        self.assertNotIn("GATE FAIL", r.err)
        # a name that is no parameter, or a type value that is not a type, still refuses
        c = self.case()
        c.raw(lambda r: r["types"].update({"dataset": "float"}))
        self.refused(c.run(), 1)

    def test_leaf_options_group_must_be_a_group(self):
        for mut in (lambda r: r["leafOptions"]["momentum"].update({"group": "epochs"}),
                    lambda r: r["leafOptions"]["momentum"].update({"group": "missing"}),
                    lambda r: r["leafOptions"].update({"nope": {"group": "optimizer", "options": ["adam"]}}),
                    lambda r: r["leafOptions"].update({"optimizer": {"group": "optimizer", "options": ["adam"]}})):
            c = self.case()
            c.raw(mut)
            self.refused(c.run(), 1)

    def test_leaf_option_not_in_the_enum(self):
        c = self.case()
        c.raw(lambda r: r["leafOptions"]["momentum"].update({"options": ["sgd", "nadam"]}))
        self.refused(c.run(), 1, "momentum")

    def test_option_defaults_rules(self):
        for mut in (lambda r: r["optionDefaults"].update({"epochs": {"a": {}}}),  # not a group param
                    lambda r: r["optionDefaults"]["optimizer"].update({"nadam": {}}),  # not in the enum
                    lambda r: r["optionDefaults"]["optimizer"]["adam"].update({"learning-rate": 1}),
                    lambda r: r["optionDefaults"]["optimizer"]["adam"].update({"learning-rate": "x" * 4097})):
            c = self.case()
            c.raw(mut)
            self.refused(c.run(), 1)

    def test_more_than_64_options(self):
        c = self.case()
        opts = [f"o{i}" for i in range(65)]
        c.param("optimizer")["enum"] = opts
        c.raw(lambda r: (r["optionDefaults"].update({"optimizer": {o: {} for o in opts}}),
                         r["leafOptions"].clear()))
        self.refused(c.run(), 1)

    def test_unknown_or_withheld_leaf_in_option_defaults_is_dropped(self):
        c = self.case()
        c.raw(lambda r: r["optionDefaults"]["optimizer"]["adam"].update({"unknown-leaf": "1", "image-x": "1"}))
        form = ok(self, c.run())
        self.assertEqual(field(form, "optimizer")["optionDefaults"]["adam"], {"learning-rate": "0.001"})

    def test_4096_value_passes(self):
        c = self.case()
        c.raw(lambda r: r["optionDefaults"]["optimizer"]["adam"].update({"learning-rate": "x" * 4096}))
        form = ok(self, c.run())
        self.assertEqual(len(field(form, "optimizer")["optionDefaults"]["adam"]["learning-rate"]), 4096)

    def test_raw_not_a_string_is_3(self):
        c = self.case()
        c.form_data["raw"] = {"version": 1}
        self.refused(c.run(), 3)


class TestDigest(Base):
    """2.4."""

    def test_known_vector(self):
        mod = load_module()
        params = [{"name": "a", "value": "1", "description": "d", "enum": ["1", "2"]},
                  {"name": "b", "valueFrom": {"configMapKeyRef": {"name": "m", "key": "k"}}},
                  {"name": "c"}, {"name": "d", "value": 1}]
        items = [{"name": "a", "value": "1"}, {"name": "b", "valueFrom": {"configMapKeyRef": {"name": "m", "key": "k"}}},
                 {"name": "c", "value": None}, {"name": "d", "value": 1}]
        text = json.dumps(items, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        self.assertEqual(mod.params_digest(params), "sha256:" + hashlib.sha256(text.encode()).hexdigest())
        self.assertEqual(text, '[{"name":"a","value":"1"},{"name":"b","valueFrom":{"configMapKeyRef":{"key":"k","name":"m"}}},'
                               '{"name":"c","value":null},{"name":"d","value":1}]')
        self.assertEqual(mod.params_digest([{"name": "é", "value": "ü"}]),
                         "sha256:" + hashlib.sha256('[{"name":"é","value":"ü"}]'.encode()).hexdigest())

    def test_stable_across_an_enum_fill_and_moves_with_a_default(self):
        a = ok(self, self.case().run())["stamp"]["paramsDigest"]
        c = self.case()
        c.param("dataset")["enum"] = ["dataset-default@latest", "dataset-default@v1"]
        c.param("dataset")["description"] = "changed"
        self.assertEqual(ok(self, c.run())["stamp"]["paramsDigest"], a)
        c = self.case()
        c.param("epochs")["value"] = "11"
        self.assertNotEqual(ok(self, c.run())["stamp"]["paramsDigest"], a)
        c = self.case()
        c.param("epochs")["value"] = 10  # 1 and "1" differ
        self.assertNotEqual(ok(self, c.run())["stamp"]["paramsDigest"], a)

    def test_format(self):
        self.assertRegex(ok(self, self.case().run())["stamp"]["paramsDigest"], r"^sha256:[0-9a-f]{64}$")


class TestPrevious(Base):
    """2.3 anti-churn and 3.2 `--previous`."""

    def sealed_previous(self, commit=COMMIT):
        c = self.case()
        c.commit = commit
        ok(self, c.run())
        return c.load_wft()

    def test_unchanged_render_keeps_the_commit(self):
        prev = self.sealed_previous(COMMIT)
        c = self.case()
        c.commit = COMMIT2
        c.previous = prev
        form = ok(self, c.run())
        self.assertEqual(form["stamp"]["commit"], COMMIT)
        self.assertEqual(c.load_wft(), prev)

    def test_form_change_takes_the_new_commit(self):
        prev = self.sealed_previous(COMMIT)
        c = self.case()
        c.commit = COMMIT2
        c.previous = prev
        c.param("epochs")["value"] = "12"
        self.assertEqual(ok(self, c.run())["stamp"]["commit"], COMMIT2)

    def test_change_outside_the_form_takes_the_new_commit(self):
        for mut in (lambda w: w["spec"]["templates"][6].update({"container": {"image": "other"}}),
                    lambda w: w["metadata"]["annotations"].update({"note": "x"}),
                    lambda w: w["spec"]["arguments"]["parameters"][1].update({"description": "other text"})):
            prev = self.sealed_previous(COMMIT)
            c = self.case()
            c.commit = COMMIT2
            c.previous = prev
            mut(c.wft)
            self.assertEqual(ok(self, c.run())["stamp"]["commit"], COMMIT2)

    def test_no_previous_takes_the_new_commit(self):
        c = self.case()
        c.commit = COMMIT2
        self.assertEqual(ok(self, c.run())["stamp"]["commit"], COMMIT2)

    def test_previous_without_a_valid_stamp_is_ignored(self):
        prev = self.sealed_previous(COMMIT)
        prev["metadata"]["annotations"][ANN] = '{"stamp":{"commit":"nope"}}'
        c = self.case()
        c.commit = COMMIT2
        c.previous = prev
        self.assertEqual(ok(self, c.run())["stamp"]["commit"], COMMIT2)

    def hostile(self, build):
        c = self.case()
        c.commit = COMMIT2
        c.write()
        build(c)
        r = c.run(args=c.args() + ([] if c.previous is not None else ["--previous", str(c.root / "previous.yaml")]), write=False)
        form = ok(self, r)
        self.assertEqual(form["stamp"]["commit"], COMMIT2)

    def test_hostile_previous_is_no_previous(self):
        prev = self.sealed_previous(COMMIT)
        text = yaml.dump(prev)

        def symlink(c):
            (c.root / "real.yaml").write_text(text)
            os.symlink(c.root / "real.yaml", c.root / "previous.yaml")

        def fifo(c):
            os.mkfifo(c.root / "previous.yaml")

        def deep(c):
            (c.root / "previous.yaml").write_text("[" * 5000 + "]" * 5000)

        def big(c):
            (c.root / "previous.yaml").write_text(text + "#" + "x" * (4 * 1024 * 1024))

        def junk(c):
            (c.root / "previous.yaml").write_text("{{{ not yaml")

        def missing(c):
            pass
        for build in (symlink, fifo, deep, big, junk, missing):
            self.hostile(build)


class TestFormYaml(Base):
    """3.4."""

    def run_with(self, text, code=0, fragment=None):
        c = self.case()
        c.form_yaml = text
        r = c.run()
        if code == 0:
            return c, ok(self, r)
        self.refused(r, code, fragment)
        return c, None

    def test_absent_is_fine(self):
        ok(self, self.case().run())

    def test_empty_file_is_fine(self):
        self.run_with("")

    def test_valid_overrides(self):
        _, form = self.run_with(
            "groups:\n  - {id: tuning, label: Tuning, tier: basic, order: 1}\n"
            "fields:\n  epochs: {label: Epochs, tier: advanced, minimum: 1, maximum: 100, group: tuning}\n"
            "  experiment-name: {label: Name}\n  dataset: {group: settings}\n")
        e = field(form, "epochs")
        self.assertEqual((e["label"], e["tier"], e["minimum"], e["maximum"], e["group"]), ("Epochs", "advanced", 1, 100, "tuning"))
        self.assertEqual(field(form, "experiment-name")["label"], "Name")
        self.assertEqual(field(form, "dataset")["group"], "settings")
        ids = [g["id"] for g in form["groups"]]
        self.assertEqual(ids[:4], ["info", "experiment", "settings", "tuning"])
        self.assertEqual([g["order"] for g in form["groups"]], list(range(len(ids))))

    def test_unused_declared_group_is_not_emitted(self):
        _, form = self.run_with("groups:\n  - {id: empty, label: Empty}\n")
        self.assertNotIn("empty", [g["id"] for g in form["groups"]])

    def test_declared_groups_sort_by_order(self):
        _, form = self.run_with(
            "groups:\n  - {id: b, label: B, order: 2}\n  - {id: a, label: A, order: 1}\n"
            "fields:\n  epochs: {group: b}\n  momentum: {group: a}\n")
        ids = [g["id"] for g in form["groups"]]
        self.assertLess(ids.index("a"), ids.index("b"))

    def test_hidden_tier_withholds_and_drops_the_option_default_key(self):
        _, form = self.run_with("fields:\n  momentum: {tier: hidden}\n")
        self.assertEqual(field(form, "optimizer")["optionDefaults"]["sgd"], {"learning-rate": "0.1"})

    def test_bad_inputs(self):
        cases = [
            ("unknown top key", "extra: 1\n"),
            ("unknown field key", "fields:\n  epochs: {color: red}\n"),
            ("pattern is not allowed", "fields:\n  epochs: {pattern: '^a'}\n"),
            ("unknown field", "fields:\n  nope: {label: x}\n"),
            ("run-setting field", "fields:\n  prep-class: {label: x}\n"),
            ("platform field", "fields:\n  pipeline-info: {tier: basic}\n"),
            ("min on a string field", "fields:\n  experiment-name: {minimum: 1}\n"),
            ("min above max", "fields:\n  epochs: {minimum: 5, maximum: 1}\n"),
            ("bool as number", "fields:\n  epochs: {minimum: true}\n"),
            ("bad tier", "fields:\n  epochs: {tier: secret}\n"),
            ("label too long", "fields:\n  epochs: {label: '%s'}\n" % ("a" * 81)),
            ("control in label", "fields:\n  epochs: {label: \"a\\x01b\"}\n"),
            ("move into info", "fields:\n  epochs: {group: info}\n"),
            ("move into platform", "fields:\n  epochs: {group: platform}\n"),
            ("move into a missing group", "fields:\n  epochs: {group: nothing}\n"),
            ("fixed id as new group", "groups:\n  - {id: settings, label: S}\n"),
            ("bad group id", "groups:\n  - {id: Bad_Id, label: S}\n"),
            ("duplicate group id", "groups:\n  - {id: a, label: S}\n  - {id: a, label: T}\n"),
            ("group without label", "groups:\n  - {id: a}\n"),
            ("group bad order", "groups:\n  - {id: a, label: A, order: -1}\n"),
            ("alias", "base: &b {label: x}\nfields:\n  epochs: *b\n"),
            ("anchor", "fields:\n  epochs: &a {label: x}\n"),
            ("duplicate key", "fields:\n  epochs: {label: a}\n  epochs: {label: b}\n"),
            ("non-string key", "fields:\n  1: {label: a}\n"),
            ("not a mapping", "- a\n- b\n"),
            ("not yaml", "fields: [\n"),
            ("python tag", "fields: !!python/object:os.system {}\n"),
            ("two documents", "fields: {}\n---\nfields: {}\n"),
            ("deep nesting", "fields: " + "[" * 10000 + "]" * 10000 + "\n"),
        ]
        for label, text in cases:
            with self.subTest(label):
                self.run_with(text.replace("a}", "a}") + "", 1)

    def test_error_names_the_key_never_the_content(self):
        c, _ = self.run_with("fields:\n  epochs: {label: '%s', color: x}\n" % MARKER, 1, "epochs")

    def test_oversize_is_1(self):
        self.run_with("# " + "x" * 65536 + "\n", 1)

    def test_exactly_64_kib_is_fine(self):
        self.run_with("#" + "x" * (65536 - 2) + "\n")

    def test_symlinked_file_dir_and_fifo_are_1(self):
        c = self.case()
        c.write()
        (c.root / "real.yaml").write_text("fields: {}\n")
        os.symlink(c.root / "real.yaml", c.config / "_form.yaml")
        self.refused(c.run(write=False), 1)
        c = self.case()
        c.write()
        os.mkfifo(c.config / "_form.yaml")
        self.refused(c.run(write=False), 1)
        for name in ("config", "repo", "workspace"):
            c = self.case()
            c.form_yaml = "fields: {}\n"
            c.write()
            if name == "config":
                real = c.root / "realdir"
                shutil.move(str(c.config), str(real))
                os.symlink(real, c.config)
            elif name == "repo":
                real = c.root / "realdir"
                shutil.move(str(c.workspace / "repo"), str(real))
                os.symlink(real, c.workspace / "repo")
            else:
                real = c.root / "realdir"
                shutil.move(str(c.workspace), str(real))
                os.symlink(real, c.workspace)
                c.wft_path = real / "out" / "workflow-template.yaml"
            r = c.run(args=[a if a != str(c.wft_path) else str(c.wft_path) for a in c.args()], write=False)
            self.assertEqual(r.rc, 1, f"{name}: {r.err}")
            self.assertEqual(len(r.gate_lines()), 1)

    def test_directory_named_form_yaml_is_1(self):
        c = self.case()
        c.write()
        (c.config / "_form.yaml").mkdir()
        self.refused(c.run(write=False), 1)


class TestWhenGrammar(Base):
    """6: the when= grammar, as the seal carries it."""

    def test_normalise(self):
        mod = load_module()
        for text, want in (("a == b", "a == b"), ("a  !=   'x y'", "a != 'x y'"), ('a=="b"', 'a == "b"'),
                           ("a == b  and c != d or e == f", "a == b and c != d or e == f"), ("", None),
                           ("a == b and", None), ("A == b AND c == d", None), ("a == b\n", None), ("\ta == b", None), ("a == b\t", None), ("  a == b  ", "a == b"),
                           ("a == \"x\ty\"", None)):
            self.assertEqual(mod.normalize_when(text), want, text)

    def test_naming_spec_values_are_pinned(self):  # OQ-8: a values-only test, kaos-lib file:line in comments
        mod = load_module()
        self.assertEqual(mod.STEP_NAME_RE.pattern, "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")  # lint/constants.py:44
        self.assertEqual(mod.STEP_NAME_MAX, 40)  # lint/constants.py:67
        self.assertEqual(tuple(mod.STEP_KINDS), ("ingest", "transform", "train", "evaluate", "publish", "control"))  # :38
        self.assertEqual(mod.TIME_RE.pattern, "^[0-9]+[mh]?$")  # lint/constants.py:69
        self.assertEqual(mod.MAX_MINUTES, 43200)  # lint/constants.py:79
        self.assertEqual(tuple(sorted(mod.RESERVED_STEP_NAMES)), ("compose-and-validate", "main"))  # :41
        self.assertEqual(mod.WHEN_NAME, "[A-Za-z0-9_.-]+")  # lint/when_text.py:19-22
        for g in ("[a-z][a-z0-9-]{0,62}",):
            self.assertEqual(mod.GROUP_ID_RE.pattern, "^" + g + "$")

    def test_label_regexes_match_the_schema(self):
        mod = load_module()
        schema = json.loads(SCHEMA.read_text())
        self.assertEqual(mod.NAME_RE.pattern, schema["$defs"]["name"]["pattern"])
        self.assertEqual(mod.ENGINE_RE.pattern, schema["properties"]["stamp"]["properties"]["engine"]["pattern"])


class TestStdlibOnly(Base):
    def test_imports_are_stdlib_plus_yaml(self):
        import ast
        tree = ast.parse(SEAL.read_text())
        mods = set()
        for n in ast.walk(tree):
            if isinstance(n, ast.Import):
                mods |= {a.name.split(".")[0] for a in n.names}
            elif isinstance(n, ast.ImportFrom) and n.level == 0:
                mods.add(n.module.split(".")[0])
        self.assertLessEqual(mods - {"yaml"}, set(sys.stdlib_module_names), mods)
        self.assertNotIn("kubecore", mods)
        for banned in ("subprocess", "socket", "urllib", "http", "requests", "ctypes"):
            self.assertNotIn(banned, mods)

    def test_runs_under_isolated_mode_from_any_directory(self):
        c = self.case()
        (c.root / "yaml.py").write_text("raise SystemExit('PWNED')\n")  # a planted module in the cwd
        (c.root / "sitecustomize.py").write_text("raise SystemExit('PWNED')\n")
        r = c.run()
        ok(self, r)
        self.assertNotIn("PWNED", r.err + r.out)


class TestOsrOracle(Base):
    """The merged OSR consumer (Parse, CheckJoin, StampProblem) accepts the output (needs go and RUN_FORM_OSR_DIR)."""

    def test_osr_accepts_the_seal(self):
        osr = os.environ.get("RUN_FORM_OSR_DIR")
        if not osr or not shutil.which("go"):
            self.skipTest("set RUN_FORM_OSR_DIR to a kaos-osr-edge-operator checkout (with go) to run the Go oracle")
        out = Path(tempfile.mkdtemp(prefix="oracle-"))
        self.addCleanup(shutil.rmtree, out, ignore_errors=True)
        cases = {}
        for name, hpc in (("base", True), ("cluster-only", False)):
            c = self.case(hpc=hpc)
            r = c.run()
            ok(self, r)
            w = c.load_wft()
            cases[name] = {"annotation": w["metadata"]["annotations"][ANN],
                           "engine": w["metadata"]["annotations"]["platform.kubecore.io/engine-version"],
                           "params": [p["name"] for p in w["spec"]["arguments"]["parameters"]]}
        # variants that exercise the drop rule
        c = self.case()
        c.steps[2]["when_text"] = "optimizer == image-classification"
        c.form_yaml = "fields:\n  momentum: {tier: hidden}\n"
        ok(self, c.run())
        w = c.load_wft()
        cases["showif-drops"] = {"annotation": w["metadata"]["annotations"][ANN], "engine": ENGINE,
                                 "params": [p["name"] for p in w["spec"]["arguments"]["parameters"]]}
        for name in TestRealEngine.NAMES:
            c = RealCase(name)
            self.addCleanup(shutil.rmtree, c.root, ignore_errors=True)
            ok(self, c.run())
            w = c.load_wft()
            cases["real-" + name] = {"annotation": w["metadata"]["annotations"][ANN], "engine": "0.9.9",
                                     "params": [p["name"] for p in w["spec"]["arguments"]["parameters"]]}
        (out / "cases.json").write_text(json.dumps(cases))
        gotest = out / "seal_oracle_test.go"
        gotest.write_text((HERE / "oracle" / "seal_oracle_test.go.txt").read_text())
        target = Path(osr) / "internal" / "readapi" / "runform" / "seal_oracle_test.go"
        (out / "overlay.json").write_text(json.dumps({"Replace": {str(target): str(gotest)}}))
        p = subprocess.run(["go", "test", "-count=1", "-overlay", str(out / "overlay.json"), "-run", "TestSealOracle",
                            "./internal/readapi/runform/"], cwd=osr, capture_output=True, text=True,
                           env={**os.environ, "SEAL_ORACLE_CASES": str(out / "cases.json")}, timeout=600)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)


if __name__ == "__main__":
    unittest.main()
