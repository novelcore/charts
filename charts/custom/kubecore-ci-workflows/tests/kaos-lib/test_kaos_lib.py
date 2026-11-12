"""files/kaos-lib.py: the CI side of kaos-lib delivery (PRD novelcore/kaos#1147).

Run: pytest charts/custom/kubecore-ci-workflows/tests/kaos-lib (needs PyYAML and pytest).
GitHub is an in-process fake HTTP server (FakeGitHub) the bump job talks to through GITHUB_API.
"""
import base64
import datetime
import http.server
import importlib.util
import json
import os
import re
import subprocess
import sys
import threading
import urllib.parse
from pathlib import Path

import pytest
import yaml

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("kaos_lib_ci", HERE.parents[1] / "files" / "kaos-lib.py")
kl = importlib.util.module_from_spec(spec)
spec.loader.exec_module(kl)

SHA = "0136a205a82fbe4ed4a82037329e048f58e7e740"
# A spec is the whole requirement: name + extras + ==X.Y.Z or @ <url>.
GIT = f"kubecore[zitadel] @ https://github.com/novelcore/hera-pipeline-template/archive/{SHA}.zip#subdirectory=packages/kubecore"
LIB = f"kaos-lib @ https://github.com/kaos-io/kaos-lib/archive/{'b' * 40}.zip"
WHEEL = "kaos-lib[zitadel] @ https://github.com/kaos-io/kaos-lib/releases/download/v0.3.0/kaos_lib-0.3.0-py3-none-any.whl"
TAG = "kaos-lib[zitadel] @ https://github.com/kaos-io/kaos-lib/archive/refs/tags/v0.3.0.zip"
AR = "https://europe-west1-python.pkg.dev/kaos-dev-511509"
REG = f"kaos-lib[zitadel] @ {AR}/kaos-lib/kaos-lib/kaos_lib-0.4.0-py3-none-any.whl#sha256={'c' * 64}"
REG_RC = f"kaos-lib[zitadel] @ {AR}/kaos-lib-rc/kaos-lib/kaos_lib-0.4.0rc3-py3-none-any.whl"


def ctx_file(tmp_path, kaos_lib=None):
    ctx = {"project": "p", "app": "a"}
    if kaos_lib is not None:
        ctx["kaosLib"] = kaos_lib
    cm = {"apiVersion": "v1", "kind": "ConfigMap", "data": {"context.yaml": yaml.safe_dump(ctx)}}
    p = tmp_path / "pipeline-context.yaml"
    p.write_text(yaml.safe_dump(cm))
    return p


def app_repo(tmp_path, compat=">=0.2,<0.3", steps=("steps/a", "steps/b"), managed=("steps/a",)):
    repo = tmp_path / "repo"
    for s in steps:
        (repo / s).mkdir(parents=True)
        arg = f'ARG KAOS_LIB_PACKAGE="{GIT}"\n' if s in managed else ""
        (repo / s / "Dockerfile").write_text(f"FROM python:3.11-slim\n{arg}RUN true\n")
    if compat is not None:
        (repo / ".kaos").mkdir()
        (repo / ".kaos" / "compat.yaml").write_text(f'# comment\nkaos-lib: "{compat}"\n')
    return repo


# ---------------------------------------------------------------- decide

def test_a_spec_the_images_do_not_have_rebuilds_the_steps_that_declare_the_arg(tmp_path):
    repo = app_repo(tmp_path)
    d = kl.decide(kl.load_context(ctx_file(tmp_path, {"spec": GIT, "version": "git-0136a205a82f"})),
                  "kaos-lib==0.2.0", kl.read_compat(repo), kl.managed(repo, ["steps/a", "steps/b"]))
    assert d["spec"] == GIT and d["record"] == GIT and d["rebuild"] is True
    assert d["managed"] == ["steps/a"] and d["compat"] == ">=0.2,<0.3"


def test_the_spec_already_built_rebuilds_nothing(tmp_path):
    repo = app_repo(tmp_path)
    d = kl.decide(kl.load_context(ctx_file(tmp_path, {"spec": GIT})), GIT, "", kl.managed(repo, ["steps/a"]))
    assert d["spec"] == GIT and d["rebuild"] is False


def test_a_context_without_kaos_lib_changes_nothing(tmp_path):
    d = kl.decide(kl.load_context(ctx_file(tmp_path)), "kaos-lib==0.2.0", ">=0.2", ["steps/a"])
    assert (d["spec"], d["record"], d["rebuild"]) == ("", "", False)


@pytest.mark.parametrize("spec", [REG, REG_RC, WHEEL, TAG, LIB, GIT, "kaos-lib==0.3.0", "kaos-lib[zitadel]==0.3.0",
                                  "kaos-lib[zitadel,x] ==0.3.0",
                                  "kaos-lib @ https://github.com/kaos-io/kaos-lib/releases/download/v0.3.0/kaos_lib-0.3.0.tar.gz"])
def test_every_requirement_form_is_built_as_it_is(tmp_path, spec):
    d = kl.decide(kl.load_context(ctx_file(tmp_path, {"spec": spec, "version": "0.3.0"})), "", "", ["steps/a"])
    assert d["spec"] == spec and d["record"] == spec and d["rebuild"]


def test_the_comparison_is_exact_string_equality(tmp_path):
    """Moving from the kubecore name to kaos-lib at the same commit is a move: it rebuilds."""
    other = GIT.replace("kubecore[zitadel]", "kaos-lib[zitadel]")
    d = kl.decide(kl.load_context(ctx_file(tmp_path, {"spec": other})), GIT, "", ["steps/a"])
    assert d["rebuild"] is True


@pytest.mark.parametrize("bad", ["latest", ">=0.3", "==0.3.0", '==0.3.0"; id; "', "kaos-lib @ https://evil/x.zip",
                                 WHEEL.split(" ", 1)[1], "kaos-lib  @ https://github.com/x/y/archive/refs/tags/v1.0.0.zip",
                                 "kaos-lib[zitadel] >=0.3", "kaos-lib==0.3.0; python_version>'3'",
                                 f"kaos-lib @ https://github.com/x/y/archive/{SHA}.zip$(id)", "kaos-lib==0.3",
                                 WHEEL + " ; id", "kaos-lib @ https://evil.example/releases/download/v1.0.0/x.whl"])
def test_a_spec_outside_the_operator_pattern_is_refused_never_built(tmp_path, bad):
    d = kl.decide(kl.load_context(ctx_file(tmp_path, {"spec": bad})), "", "", ["steps/a"])
    assert (d["spec"], d["record"]) == ("", "") and d["reason"].startswith("REFUSED")


def test_an_app_whose_dockerfiles_declare_no_arg_reports_none(tmp_path):
    repo = app_repo(tmp_path, compat=None, managed=())
    d = kl.decide(kl.load_context(ctx_file(tmp_path, {"spec": GIT})), "", kl.read_compat(repo),
                  kl.managed(repo, ["steps/a", "steps/b"]))
    assert (d["spec"], d["record"], d["compat"], d["rebuild"]) == ("", "none", "", False)


def test_the_cli_prints_the_decision(tmp_path, capsys):
    repo = app_repo(tmp_path)
    steps = tmp_path / "steps.txt"
    steps.write_text("steps/a\nsteps/b\n")
    kl.main(["decide", "--context", str(ctx_file(tmp_path, {"spec": "kaos-lib==0.2.1"})), "--recorded", "kaos-lib==0.2.0",
             "--repo", str(repo), "--steps", str(steps)])
    out = json.loads(capsys.readouterr().out)
    assert out["spec"] == "kaos-lib==0.2.1" and out["rebuild"] and out["compat"] == ">=0.2,<0.3"


def test_context_prints_the_delivered_spec(tmp_path, capsys):
    kl.main(["context", "--context", str(ctx_file(tmp_path, {"spec": LIB, "version": "git-bbbbbbbbbbbb"}))])
    assert capsys.readouterr().out.strip() == LIB


# ---------------------------------------------------------------- checkout reads (kubecore-operator issue 1833)
# .kaos/compat.yaml and the step Dockerfiles are the app's (untrusted), read in detect-steps, which
# holds the git token. A file that is there but is a symlink, not a regular file, outside the
# checkout, over the bound or not UTF-8 is refused with the reason, never followed or read unbounded.

SCRIPT = HERE.parents[1] / "files" / "kaos-lib.py"


def steps_file(tmp_path, *paths):
    f = tmp_path / "steps.txt"
    f.write_text("".join(p + "\n" for p in paths))
    return f


def test_a_regular_compat_and_dockerfile_are_read(tmp_path):
    repo = app_repo(tmp_path)
    assert kl.read_compat(repo) == ">=0.2,<0.3"
    assert kl.managed(repo, ["steps/a", "steps/b"]) == ["steps/a"]


def test_a_missing_compat_is_no_range(tmp_path):
    repo = app_repo(tmp_path, compat=None)
    assert kl.read_compat(repo) == ""
    (repo / ".kaos").write_text("not a directory\n")  # a `.kaos` file: still no compat.yaml
    assert kl.read_compat(repo) == ""


def test_a_compat_that_is_not_yaml_is_no_range(tmp_path):
    repo = app_repo(tmp_path)
    (repo / ".kaos" / "compat.yaml").write_text("kaos-lib: [unclosed\n")
    assert kl.read_compat(repo) == ""


def test_a_missing_dockerfile_is_no_managed_step(tmp_path):
    repo = app_repo(tmp_path)
    assert kl.managed(repo, ["steps/a", "steps/gone"]) == ["steps/a"]


@pytest.mark.parametrize("target", ["/dev/zero", "outside"])
def test_a_symlinked_compat_is_refused(tmp_path, target):
    repo = app_repo(tmp_path, compat=None)
    if target == "outside":
        target = str(tmp_path / "outside.yaml")
        (tmp_path / "outside.yaml").write_text('kaos-lib: ">=0.2"\n')
    (repo / ".kaos").mkdir()
    os.symlink(target, repo / ".kaos" / "compat.yaml")
    with pytest.raises(kl.CheckoutFileError, match="not a regular file"):
        kl.read_compat(repo)


@pytest.mark.parametrize("target", ["/dev/zero", "outside"])
def test_a_symlinked_dockerfile_is_refused(tmp_path, target):
    repo = app_repo(tmp_path)
    if target == "outside":
        target = str(tmp_path / "Dockerfile.outside")
        (tmp_path / "Dockerfile.outside").write_text(f'ARG KAOS_LIB_PACKAGE="{GIT}"\n')
    os.remove(repo / "steps" / "b" / "Dockerfile")
    os.symlink(target, repo / "steps" / "b" / "Dockerfile")
    with pytest.raises(kl.CheckoutFileError, match="steps/b/Dockerfile"):
        kl.managed(repo, ["steps/a", "steps/b"])


def test_a_step_dir_symlinked_out_of_the_checkout_is_refused(tmp_path):
    repo = app_repo(tmp_path)
    (tmp_path / "elsewhere").mkdir()
    (tmp_path / "elsewhere" / "Dockerfile").write_text(f'ARG KAOS_LIB_PACKAGE="{GIT}"\n')
    os.symlink(tmp_path / "elsewhere", repo / "steps" / "c")
    with pytest.raises(kl.CheckoutFileError, match="not a regular file in the checkout"):
        kl.managed(repo, ["steps/c"])


def test_a_step_dir_symlinked_inside_the_checkout_is_read(tmp_path):
    repo = app_repo(tmp_path)
    os.symlink(repo / "steps" / "a", repo / "steps" / "c")
    assert kl.managed(repo, ["steps/c"]) == ["steps/c"]


def test_a_fifo_dockerfile_is_refused_not_waited_on(tmp_path):
    repo = app_repo(tmp_path)
    os.remove(repo / "steps" / "b" / "Dockerfile")
    os.mkfifo(repo / "steps" / "b" / "Dockerfile")
    with pytest.raises(kl.CheckoutFileError, match="not a regular file"):
        kl.managed(repo, ["steps/b"])


def test_an_oversized_compat_is_refused_unread(tmp_path):
    repo = app_repo(tmp_path)
    (repo / ".kaos" / "compat.yaml").write_text("# x\n" * (kl.APP_FILE_MAX_BYTES // 4 + 1))
    with pytest.raises(kl.CheckoutFileError, match="bytes"):
        kl.read_compat(repo)


def test_an_oversized_dockerfile_is_refused_unread(tmp_path):
    repo = app_repo(tmp_path)
    (repo / "steps" / "a" / "Dockerfile").write_text("RUN true\n" * (kl.APP_FILE_MAX_BYTES // 9 + 1))
    with pytest.raises(kl.CheckoutFileError, match="bytes"):
        kl.managed(repo, ["steps/a"])


def test_a_dockerfile_at_the_bound_is_read(tmp_path):
    repo = app_repo(tmp_path)
    body = f'ARG KAOS_LIB_PACKAGE="{GIT}"\n'
    (repo / "steps" / "a" / "Dockerfile").write_text(body + "#" * (kl.APP_FILE_MAX_BYTES - len(body)))
    assert kl.managed(repo, ["steps/a"]) == ["steps/a"]


def test_a_dockerfile_that_is_not_utf8_is_refused(tmp_path):
    repo = app_repo(tmp_path)
    (repo / "steps" / "a" / "Dockerfile").write_bytes(b"FROM x\n\xff\xfe\n")
    with pytest.raises(kl.CheckoutFileError, match="UTF-8"):
        kl.managed(repo, ["steps/a"])


def test_the_chart_owned_compose_dockerfile_outside_the_checkout_is_read(tmp_path):
    # detect-steps appends /tmp/compose-ctx (absolute, the chart's own Dockerfile) to the step paths.
    repo = app_repo(tmp_path)
    compose = tmp_path / "compose-ctx"
    compose.mkdir()
    (compose / "Dockerfile").write_text(f'FROM engine\nARG KAOS_LIB_PACKAGE="{GIT}"\n')
    assert kl.managed(repo, ["steps/a", str(compose)]) == ["steps/a", str(compose)]


def test_the_cli_refuses_with_the_reason_and_writes_no_decision(tmp_path, capsys):
    repo = app_repo(tmp_path, compat=None)
    (repo / ".kaos").mkdir()
    os.symlink("/dev/zero", repo / ".kaos" / "compat.yaml")
    rc = kl.main(["decide", "--context", str(ctx_file(tmp_path, {"spec": GIT})), "--repo", str(repo),
                  "--steps", str(steps_file(tmp_path, "steps/a"))])
    out, err = capsys.readouterr()
    assert rc == kl.EXIT_REFUSED and out == ""
    assert err.startswith("kaos-lib: REFUSED: .kaos/compat.yaml is not a regular file")


@pytest.mark.parametrize("victim", [".kaos/compat.yaml", "steps/a/Dockerfile"])
def test_the_cli_does_not_hang_on_dev_zero(tmp_path, victim):
    # A subprocess with a deadline: before the fix this read /dev/zero until OOM or the step deadline.
    repo = app_repo(tmp_path)
    os.remove(repo / victim)
    os.symlink("/dev/zero", repo / victim)
    proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "decide", "--context", str(ctx_file(tmp_path, {"spec": GIT})),
                           "--repo", str(repo), "--steps", str(steps_file(tmp_path, "steps/a", "steps/b"))],
                          capture_output=True, text=True, timeout=30)
    assert proc.returncode == kl.EXIT_REFUSED and proc.stdout == ""
    assert f"kaos-lib: REFUSED: {victim} is not a regular file" in proc.stderr


@pytest.mark.parametrize("value, compat", [('">=0.2,<0.3"', ">=0.2,<0.3"), ("0.4", "0.4"), ("1", "1"), ("", "")])
def test_a_scalar_compat_value_is_the_range(tmp_path, value, compat):
    repo = app_repo(tmp_path)
    (repo / ".kaos" / "compat.yaml").write_text(f"kaos-lib: {value}\n")
    assert kl.read_compat(repo) == compat


@pytest.mark.parametrize("value", ["[a, b]", "{a: b}", "true", "2026-11-12"])
def test_a_compat_value_that_is_not_a_scalar_is_refused(tmp_path, value):
    repo = app_repo(tmp_path)
    (repo / ".kaos" / "compat.yaml").write_text(f"kaos-lib: {value}\n")
    with pytest.raises(kl.CheckoutFileError, match="not a version specifier"):
        kl.read_compat(repo)


ALIAS_BOMB = "a: &a [x, x, x, x, x, x, x, x, x, x]\n" + "".join(
    f"{chr(98 + i)}: &{chr(98 + i)} [*{chr(97 + i)}, *{chr(97 + i)}, *{chr(97 + i)}, *{chr(97 + i)}, *{chr(97 + i)},"
    f" *{chr(97 + i)}, *{chr(97 + i)}, *{chr(97 + i)}, *{chr(97 + i)}, *{chr(97 + i)}]\n" for i in range(8)
) + "kaos-lib: *i\n"  # 10**9 leaves in well under 1 KiB


def test_a_compat_alias_bomb_is_refused_not_expanded(tmp_path):
    # A subprocess with a deadline: str() of the value would expand 10**9 strings.
    assert len(ALIAS_BOMB) < 1024
    repo = app_repo(tmp_path)
    (repo / ".kaos" / "compat.yaml").write_text(ALIAS_BOMB)
    proc = subprocess.run([sys.executable, "-I", str(SCRIPT), "decide", "--context", str(ctx_file(tmp_path, {"spec": GIT})),
                           "--repo", str(repo), "--steps", str(steps_file(tmp_path, "steps/a"))],
                          capture_output=True, text=True, timeout=30)
    assert proc.returncode == kl.EXIT_REFUSED and proc.stdout == ""
    assert "kaos-lib: REFUSED: .kaos/compat.yaml: kaos-lib is a list" in proc.stderr


def test_a_symlink_swapped_in_after_the_lstat_is_not_followed(tmp_path, monkeypatch):
    # The lstat saw a regular file; by the open it is a symlink to /dev/zero: O_NOFOLLOW refuses it.
    repo = app_repo(tmp_path)
    target = repo / ".kaos" / "compat.yaml"
    real_lstat = os.lstat

    def lstat_then_swap(path, *a, **kw):
        st = real_lstat(path, *a, **kw)
        if str(path) == str(target):
            os.remove(target)
            os.symlink("/dev/zero", target)
        return st
    monkeypatch.setattr(kl.os, "lstat", lstat_then_swap)
    real_realpath = os.path.realpath
    # The containment check is made to pass so the open itself is what refuses the swapped-in symlink.
    monkeypatch.setattr(kl.os.path, "realpath",
                        lambda p: os.path.join(real_realpath(repo), ".kaos", "compat.yaml") if str(p) == str(target)
                        else real_realpath(p))
    with pytest.raises(kl.CheckoutFileError, match="cannot be opened as a regular file"):
        kl.read_compat(repo)


# ---------------------------------------------------------------- versions

@pytest.mark.parametrize("specifier,version,ok", [
    (">=0.2,<0.3", "0.2.9", True), (">=0.2,<0.3", "0.3.0", False), ("==0.2.4", "0.2.4", True),
    ("==0.2.*", "0.2.7", True), ("==0.2.*", "0.3.0", False), ("!=0.2.5", "0.2.5", False),
    ("~=0.2.3", "0.2.9", True), ("~=0.2.3", "0.3.0", False), ("~=1.4", "1.9", True), (">0.2", "0.2.0", False),
    # rcs of the prerelease channel sort just before their final, as in the operator
    (">=0.4", "0.4.0rc1", False), ("<0.4", "0.4.0rc1", True), (">=0.3,<0.5", "0.4.0rc2", True),
    ("==0.4.0rc2", "0.4.0rc2", True), (">0.4.0rc2", "0.4.0rc10", True), ("<0.4.0", "0.4.0rc99", True),
])
def test_specifiers(specifier, version, ok):
    assert kl.contains(specifier, version) is ok


@pytest.mark.parametrize("version,rng", [("0.3.0", ">=0.3,<0.4"), ("0.10.2", ">=0.10,<0.11"), ("1.2.0", ">=1.2,<2")])
def test_bump_range(version, rng):
    assert kl.bump_range(version) == rng
    assert kl.contains(rng, version)


# ---------------------------------------------------------------- support

SUPPORT = {"version": "0.4.0", "supported": ">=0.3",
           "deprecated": [{"range": "<0.3", "unsupported_after": "2026-12-01"}], "breaking": True}
DAY = datetime.date(2026, 11, 2)


@pytest.mark.parametrize("version,verdict", [
    ("0.4.0", "current"), ("0.3.1", "behind"), ("0.2.0", "deprecated"), ("git-0136a205a82f", "unknown")])
def test_support_verdicts(version, verdict):
    assert kl.support_verdict(version, SUPPORT, DAY)["verdict"] == verdict


@pytest.mark.parametrize("version,newest,verdict", [("0.4.0rc1", "0.4.0", "behind"), ("0.4.0rc1", "0.4.0rc2", "behind"),
                                                    ("0.4.0rc2", "0.4.0rc2", "current"), ("0.4.0", "0.4.0rc5", "current")])
def test_support_verdicts_order_rcs(version, newest, verdict):
    assert kl.support_verdict(version, dict(SUPPORT, version=newest), DAY)["verdict"] == verdict


@pytest.mark.parametrize("bad", [REG.replace("-python.pkg.dev", "-docker.pkg.dev"), REG.replace(AR, "https://evil.example/x"),
                                 REG_RC.replace("-py3-none-any.whl", ".tar.gz"), REG[:-1], REG_RC + "#egg=x"])
def test_registry_specs_outside_the_operator_pattern_are_refused(bad):
    assert not kl.valid_spec(bad)


def test_registry_record_url_names_the_channel_and_tag():
    assert kl.registry_record_url(REG) == f"{kl.RELEASES_BASE}/stable/v0.4.0/release.json"
    assert kl.registry_record_url(REG_RC) == f"{kl.RELEASES_BASE}/rc/v0.4.0-rc.3/release.json"
    assert kl.registry_record_url(WHEEL) == "" and kl.registry_record_url(GIT) == ""


def test_a_deprecated_version_past_its_deadline_is_unsupported():
    assert kl.support_verdict("0.2.0", SUPPORT, datetime.date(2026, 12, 2))["verdict"] == "unsupported"


def test_outside_the_window_with_no_deadline_is_unsupported():
    assert kl.support_verdict("0.1.0", {"version": "0.4.0", "supported": ">=0.3"}, DAY)["verdict"] == "unsupported"


def test_the_status_is_red_only_when_unsupported():
    assert kl.status_for({"verdict": "unsupported"})[0] == "failure"
    assert kl.status_for({"verdict": "behind"}) == ("success", "warning: ")
    assert kl.status_for({"verdict": "deprecated"}) == ("success", "warning: ")
    assert kl.status_for({"verdict": "current"}) == ("success", "")


def test_support_cli_reads_the_json_from_the_context(tmp_path, capsys):
    kl.main(["support", "--context", str(ctx_file(tmp_path, {"spec": "==0.1.0", "version": "0.1.0",
                                                             "support": json.dumps({"version": "0.4.0", "supported": ">=0.3"})}))])
    out = json.loads(capsys.readouterr().out)
    assert out["state"] == "failure" and out["verdict"] == "unsupported"
    assert re.fullmatch(r"[A-Za-z0-9 .,:;<>=!~()/_+@-]*", out["description"])


def test_support_cli_without_support_data_posts_nothing(tmp_path, capsys):
    kl.main(["support", "--context", str(ctx_file(tmp_path, {"spec": "==0.3.0", "version": "0.3.0"}))])
    assert json.loads(capsys.readouterr().out) == {"verdict": "", "state": "", "description": ""}


def test_the_description_strips_shell_characters():
    assert kl.safe('a"$(id)`b\\c') == "a(id)bc"


# ---------------------------------------------------------------- release notes / compat file

def test_changelog_url_follows_the_archive():
    assert kl.changelog_url(GIT, "D") == (
        f"https://raw.githubusercontent.com/novelcore/hera-pipeline-template/{SHA}/packages/kubecore/CHANGELOG.md")
    assert kl.changelog_url(LIB, "D") == f"https://raw.githubusercontent.com/kaos-io/kaos-lib/{'b' * 40}/CHANGELOG.md"
    assert kl.changelog_url("kaos-lib==0.3.0", "D") == "D"


def test_release_notes_take_one_section():
    log = "# log\n\n## 0.4.0\n\nnew\n\n## [0.3.0]\n\n- **Migration**: rename x\n\n## v0.2.0\n\nold\n"
    assert kl.release_notes(log, "0.3.0") == "- **Migration**: rename x"
    assert kl.release_notes(log, "0.2.0") == "old"
    assert kl.release_notes(log, "0.9.0") == ""


def test_compat_file_keeps_comments():
    assert kl.compat_file('# keep\nkaos-lib: ">=0.2,<0.3"\nother: 1\n', ">=0.3,<0.4") == (
        '# keep\nkaos-lib: ">=0.3,<0.4"\nother: 1\n')
    assert yaml.safe_load(kl.compat_file("", ">=0.3,<0.4")) == {"kaos-lib": ">=0.3,<0.4"}


# ---------------------------------------------------------------- bump (fake GitHub)

class FakeGitHub:
    """Just enough of GitHub: pulls (list/create/close), refs, contents, issue comments."""

    def __init__(self, slug="org/proj-app", compat='# c\nkaos-lib: ">=0.2,<0.3"\n'):
        self.slug, self.prs, self.comments, self.calls = slug, [], [], []
        self.refs = {"refs/heads/dev": "basesha"}
        self.files = {("dev", ".kaos/compat.yaml"): compat} if compat is not None else {}

    def pr(self, branch, state="open", merged=False, base="dev"):
        n = len(self.prs) + 1
        self.prs.append({"number": n, "state": state, "merged_at": "x" if merged else None, "base": {"ref": base},
                         "head": {"ref": branch, "repo": {"full_name": self.slug}}, "title": branch, "body": ""})
        self.refs[f"refs/heads/{branch}"] = "s"
        return n

    def handle(self, method, path, body):
        self.calls.append((method, path))
        u = urllib.parse.urlparse(path)
        q = dict(urllib.parse.parse_qsl(u.query))
        p = u.path.removeprefix(f"/repos/{self.slug}")
        if method == "GET" and p == "/pulls":
            out = [x for x in self.prs if q.get("state") == "all" or x["state"] == q.get("state")]
            if "head" in q:
                out = [x for x in out if f"{self.slug.split('/')[0]}:{x['head']['ref']}" == q["head"]]
            return 200, out
        if method == "POST" and p == "/pulls":
            n = len(self.prs) + 1
            self.prs.append({"number": n, "state": "open", "merged_at": None, "base": {"ref": body["base"]},
                             "head": {"ref": body["head"], "repo": {"full_name": self.slug}},
                             "title": body["title"], "body": body["body"]})
            return 201, self.prs[-1]
        m = re.fullmatch(r"/pulls/(\d+)", p)
        if method == "PATCH" and m:
            self.prs[int(m.group(1)) - 1]["state"] = body["state"]
            return 200, self.prs[int(m.group(1)) - 1]
        if method == "GET" and p.startswith("/git/ref/heads/"):
            ref = "refs/heads/" + urllib.parse.unquote(p.removeprefix("/git/ref/heads/"))
            return (200, {"object": {"sha": self.refs[ref]}}) if ref in self.refs else (404, {"message": "Not Found"})
        if method == "POST" and p == "/git/refs":
            if body["ref"] in self.refs:
                return 422, {"message": "Reference already exists"}
            self.refs[body["ref"]] = body["sha"]
            self.files.update({(body["ref"].removeprefix("refs/heads/"), k[1]): v
                               for k, v in list(self.files.items()) if k[0] == "dev"})
            return 201, {}
        if method == "DELETE" and p.startswith("/git/refs/heads/"):
            self.refs.pop("refs/heads/" + urllib.parse.unquote(p.removeprefix("/git/refs/heads/")), None)
            return 204, None
        if p == "/contents/.kaos/compat.yaml":
            key = (q.get("ref") or (body or {}).get("branch"), ".kaos/compat.yaml")
            if method == "GET":
                if key not in self.files:
                    return 404, {"message": "Not Found"}
                return 200, {"sha": "fsha", "content": base64.b64encode(self.files[key].encode()).decode()}
            self.files[key] = base64.b64decode(body["content"]).decode()
            return 200, {}
        if method == "GET" and u.path == "/repos/kaos-io/kaos-lib/releases/tags/v0.3.0":
            return 200, {"body": "- **Migration**: from the release"}
        m = re.fullmatch(r"/issues/(\d+)/comments", p)
        if method == "POST" and m:
            self.comments.append((int(m.group(1)), body["body"]))
            return 201, {}
        return 404, {"message": f"fake: unexpected {method} {path}"}


@pytest.fixture
def github(monkeypatch):
    fake = FakeGitHub()

    class H(http.server.BaseHTTPRequestHandler):
        def _do(self):
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n)) if n else None
            assert self.headers["Authorization"] == "Bearer tok"
            code, out = fake.handle(self.command, self.path, body)
            raw = json.dumps(out).encode() if out is not None else b""
            self.send_response(code)
            self.send_header("Content-Length", str(len(raw)))
            self.end_headers()
            self.wfile.write(raw)
        do_GET = do_POST = do_PATCH = do_PUT = do_DELETE = _do

        def log_message(self, *a):
            pass

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    fake.api = f"http://127.0.0.1:{srv.server_address[1]}"
    monkeypatch.setattr(kl, "fetch", lambda url: "## 0.3.0\n\n- **Migration**: rename `x` to `y`\n\n## 0.2.0\n\nold\n")
    yield fake
    srv.shutdown()


def run_bump(fake, version="0.3.0", spec="kaos-lib[zitadel]==0.3.0"):
    return kl.bump(kl.GitHub("tok", fake.api), fake.slug, "dev", version, spec, "https://changelog", log=lambda m: None)


def test_bump_opens_one_pull_request_with_the_new_range_and_the_release_notes(github):
    out = run_bump(github)
    assert out == {"action": "opened", "number": 1, "closed": []}
    pr = github.prs[0]
    assert (pr["head"]["ref"], pr["base"]["ref"]) == ("kaos-lib/bump-0.3.0", "dev")
    assert "- **Migration**: rename `x` to `y`" in pr["body"] and "old" not in pr["body"]
    assert github.files[("kaos-lib/bump-0.3.0", ".kaos/compat.yaml")] == '# c\nkaos-lib: ">=0.3,<0.4"\n'
    assert github.files[("dev", ".kaos/compat.yaml")] == '# c\nkaos-lib: ">=0.2,<0.3"\n', "dev untouched"


def test_bump_is_idempotent(github):
    run_bump(github)
    assert run_bump(github) == {"action": "exists", "number": 1, "closed": []}
    assert len(github.prs) == 1


@pytest.mark.parametrize("merged", [False, True])
def test_a_closed_or_merged_bump_is_never_reopened(github, merged):
    github.pr("kaos-lib/bump-0.3.0", state="closed", merged=merged)
    assert run_bump(github)["action"] == "declined"
    assert len(github.prs) == 1 and ("POST", f"/repos/{github.slug}/pulls") not in github.calls


def test_a_newer_version_closes_the_superseded_bump(github):
    old = github.pr("kaos-lib/bump-0.3.0")
    other = github.pr("feature/x")
    out = run_bump(github, version="0.4.0", spec="kaos-lib[zitadel]==0.4.0")
    assert out["action"] == "opened" and out["closed"] == [old]
    assert github.prs[old - 1]["state"] == "closed" and github.prs[other - 1]["state"] == "open"
    assert "refs/heads/kaos-lib/bump-0.3.0" not in github.refs
    assert github.comments == [(old, f"Superseded by kaos-lib 0.4.0 (#{out['number']}).")]


def test_a_branch_left_by_an_earlier_attempt_is_reused(github):
    github.refs["refs/heads/kaos-lib/bump-0.3.0"] = "basesha"
    github.files[("kaos-lib/bump-0.3.0", ".kaos/compat.yaml")] = github.files[("dev", ".kaos/compat.yaml")]
    assert run_bump(github)["action"] == "opened"


def test_an_app_without_compat_gets_the_file(monkeypatch, github):
    github.files.clear()
    run_bump(github)
    assert yaml.safe_load(github.files[("kaos-lib/bump-0.3.0", ".kaos/compat.yaml")]) == {"kaos-lib": ">=0.3,<0.4"}


def test_a_git_version_opens_nothing(github):
    assert run_bump(github, version="git-0136a205a82f", spec=GIT)["action"] == "refused"
    assert github.calls == []


def test_a_registry_wheel_takes_its_notes_from_the_release_record(github, monkeypatch):
    seen = []

    def fetch(url):
        seen.append(url)
        return json.dumps({"notes": "### Added\n- layouts"})
    monkeypatch.setattr(kl, "fetch", fetch)
    run_bump(github, version="0.4.0", spec=REG)
    assert seen == [f"{kl.RELEASES_BASE}/stable/v0.4.0/release.json"]
    assert "### Added\n- layouts" in github.prs[0]["body"] and f"Package: `{REG}`" in github.prs[0]["body"]


def test_a_release_wheel_takes_its_notes_from_the_github_release(github):
    run_bump(github, spec=WHEEL)
    assert "- **Migration**: from the release" in github.prs[0]["body"]


def test_a_tag_archive_takes_its_notes_from_the_github_release(github):
    run_bump(github, spec=TAG)
    assert "- **Migration**: from the release" in github.prs[0]["body"]
    assert f"Package: `{TAG}`" in github.prs[0]["body"]
