"""kaos-lib delivery helpers for the ML CI (PRD novelcore/kaos#1147).

Contract: kubecore-operator study/kubecore/package-delivery-design.md. The operator writes
`kaosLib: {spec, version, support}` into the app's pipeline-context; this script is the CI side:

  decide  ml-ci-build detect-steps: the spec to build with and what to report back in
          pipeline-images (`kaos-lib-package`, `kaos-lib-compat`).
  context ml-ci-reconcile: the spec the platform context delivers.
  support the kaos-lib support verdict of the version a build resolved.
  bump    the bump pull request (branch kaos-lib/bump-<version>) in the app repo.
  contract  whether a build may install a spec: the step contract starts at kaos-lib 0.5
          (PRD novelcore/kaos#1911, AC-01).

Standard library + PyYAML only (the toolbox image has both). Every input is data: nothing
read here is ever evaluated by a shell.
"""
import argparse
import base64
import datetime
import json
import os
import re
import stat
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

# A spec is the WHOLE pip requirement a build installs: a distribution name with optional
# extras, then ==X.Y.Z or " @ <url>". The URL forms (the operator's kaoslibpkg forms):
#   kaos-lib[zitadel] @ https://<region>-python.pkg.dev/.../kaos_lib-X.Y.Z[rcN]-py3-none-any.whl[#sha256=<hex>]
#     (the platform registry, kaos-lib-rc / kaos-lib: what the kaos-lib CI publishes and recommends)
#   kaos-lib[zitadel] @ https://github.com/kaos-io/kaos-lib/releases/<download>/vX.Y.Z/<wheel|sdist>
#   kaos-lib[zitadel] @ https://github.com/kaos-io/kaos-lib/archive/refs/tags/vX.Y.Z.zip
#   kubecore[zitadel] @ https://github.com/<owner>/<repo>/archive/<40-hex sha>.zip#subdirectory=...
# No quotes, "$", ";", backticks or other whitespace, so a spec cannot break out of the build-arg.
# Anything else is refused, never built. (The release URL is split below only so the chart's
# install-at-start-up check does not match it.)
NAME = r"[A-Za-z0-9][A-Za-z0-9._-]*(?:\[[A-Za-z0-9._-]+(?:,[A-Za-z0-9._-]+)*\])?"
RELEASE_RE = re.compile(r"^" + NAME + r" @ https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/releases/"
                        r"download/(v[0-9]+\.[0-9]+\.[0-9]+)/[A-Za-z0-9._+-]+$")
TAG_RE = re.compile(r"^" + NAME + r" @ https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/archive/refs/tags/"
                    r"(v[0-9]+\.[0-9]+\.[0-9]+)\.(?:zip|tar\.gz)$")
COMMIT_RE = re.compile(r"^" + NAME + r" @ https://[A-Za-z0-9.-]+/[A-Za-z0-9._/-]*archive/[0-9a-f]{40}\.zip"
                       r"(?:#[A-Za-z0-9._/=&-]+)?$")
INDEX_RE = re.compile(r"^" + NAME + r" ?==[0-9]+\.[0-9]+\.[0-9]+$")
REGISTRY_RE = re.compile(r"^" + NAME + r" @ https://([a-z0-9-]+)-python\.pkg\.dev/([A-Za-z0-9._/-]+)/kaos_lib-"
                         r"([0-9]+\.[0-9]+\.[0-9]+(?:rc[0-9]+)?)-py3-none-any\.whl(?:#sha256=[0-9a-f]{64})?$")
# Where the kaos-lib CI writes one record per release: <rc|stable>/<tag>/release.json (with `notes`).
RELEASES_BASE = "https://storage.googleapis.com/kaos-dev-511509-kaos-lib"


def valid_spec(spec):
    return len(spec) <= 512 and any(r.match(spec) for r in (REGISTRY_RE, RELEASE_RE, TAG_RE, COMMIT_RE, INDEX_RE))


def registry_record_url(spec, base=RELEASES_BASE):
    """The public release record of a registry wheel spec (its notes, sha256s), or "" for other forms."""
    m = REGISTRY_RE.match(spec)
    if not m:
        return ""
    version = m.group(3)
    rel, _, rc = version.partition("rc")
    tag = f"v{rel}-rc.{rc}" if rc else f"v{rel}"
    return f"{base}/{'rc' if rc else 'stable'}/{tag}/release.json"


# The step contract (PRD novelcore/kaos#1911): the first kaos-lib a pipeline step can run with. A pipeline
# rendered by this chart's engine gives a step one context and takes one result back, which kaos-lib reads
# and writes from this version on.
CONTRACT_MIN = "0.5"
# The kaos-lib guide's page a new .kaos/compat.yaml points at, under the address the chart is given
# (kaosLib.guideUrl).
SUPPORT_WINDOW_PAGE = "support-window.html"


def guide_page(guide_url, page):
    return guide_url.rstrip("/") + "/" + page


ARG_RE = re.compile(r"^\s*ARG\s+KAOS_LIB_PACKAGE(\s|=|$)", re.M)
NONE = "none"  # pipeline-images kaos-lib-package: no step Dockerfile declares ARG KAOS_LIB_PACKAGE
BUMP_PREFIX = "kaos-lib/bump-"
COMPAT_PATH = ".kaos/compat.yaml"
COMPAT_KEY = "kaos-lib"
# The checkout files read here (.kaos/compat.yaml, each step's Dockerfile) are the app's, untrusted:
# a cap far above any real one (a template's step Dockerfile is well under 2 KB), so a huge or
# endless file (a symlink to /dev/zero) is refused, not read.
APP_FILE_MAX_BYTES = 64 * 1024
EXIT_REFUSED = 5  # decide: a checkout file is there but not something to read as data


class CheckoutFileError(Exception):
    """A checkout file that is there but must not be read: the decision fails with this reason."""


# ---------------------------------------------------------------- inputs

def load_context(path):
    """The bare context of a pipeline-context.yaml (a ConfigMap whose data.context.yaml holds it)."""
    try:
        with open(path) as f:
            doc = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return {}
    if isinstance(doc, dict) and doc.get("kind") == "ConfigMap":
        data = doc.get("data") or {}
        raw = data.get("context.yaml", next(iter(data.values()), "") if data else "")
        try:
            doc = yaml.safe_load(raw) or {}
        except yaml.YAMLError:
            return {}
    return doc if isinstance(doc, dict) else {}


def kaos_lib(ctx):
    v = ctx.get("kaosLib")
    return v if isinstance(v, dict) else {}


def read_checkout_file(repo_dir, rel):
    """The text of <repo_dir>/<rel>, None when there is no such file. Raises CheckoutFileError when it
    is there but not something to read as data: a symlink, not a regular file (a FIFO, a device),
    resolving outside the checkout, larger than APP_FILE_MAX_BYTES or not UTF-8.

    An absolute <rel> is a chart-owned file (the compose Dockerfile under /tmp), not the app's: it is
    read as is, still a regular file within the bound.
    """
    path = os.path.join(repo_dir, rel)
    try:
        st = os.lstat(path)
    except (FileNotFoundError, NotADirectoryError):  # no such file (or a component is not a directory)
        return None
    except OSError as exc:
        raise CheckoutFileError(f"{rel}: cannot stat ({exc.strerror})") from exc
    inside = os.path.isabs(rel) or os.path.realpath(path).startswith(os.path.realpath(repo_dir) + os.sep)
    if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode) or not inside:
        raise CheckoutFileError(f"{rel} is not a regular file in the checkout (a symlink, a device or outside it); "
                                "refusing to read it")
    if st.st_size > APP_FILE_MAX_BYTES:
        raise CheckoutFileError(f"{rel} is {st.st_size} bytes, more than {APP_FILE_MAX_BYTES}; refusing to read it")
    # Defence in depth against a swap between the lstat and the open: never follow a final symlink,
    # never block on a FIFO, and check what was actually opened before reading it.
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except OSError as exc:
        raise CheckoutFileError(f"{rel} cannot be opened as a regular file ({exc.strerror}); refusing to read it") from exc
    try:
        fst = os.fstat(fd)
        if not stat.S_ISREG(fst.st_mode):
            raise CheckoutFileError(f"{rel} is not a regular file in the checkout (a symlink, a device or outside it); "
                                    "refusing to read it")
        chunks, size = [], 0
        while size <= APP_FILE_MAX_BYTES:
            chunk = os.read(fd, APP_FILE_MAX_BYTES + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
        raw = b"".join(chunks)
    except OSError as exc:
        raise CheckoutFileError(f"{rel} cannot be read ({exc.strerror})") from exc
    finally:
        os.close(fd)
    if len(raw) > APP_FILE_MAX_BYTES:
        raise CheckoutFileError(f"{rel} is more than {APP_FILE_MAX_BYTES} bytes; refusing to read it")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CheckoutFileError(f"{rel} is not UTF-8 text; refusing to read it") from exc


def read_compat(repo_dir):
    """The app's declared range (.kaos/compat.yaml, key kaos-lib); "" when none is declared (no file,
    a file that is not YAML, or no/empty kaos-lib key). A compat.yaml that cannot be read safely, or
    whose kaos-lib value is not a scalar (a string or a number), raises CheckoutFileError."""
    text = read_checkout_file(repo_dir, COMPAT_PATH)
    if text is None:
        return ""
    try:
        doc = yaml.safe_load(text) or {}
    except (yaml.YAMLError, RecursionError):
        return ""
    val = doc.get(COMPAT_KEY) if isinstance(doc, dict) else None
    if val is None:
        return ""
    # Only a scalar is ever turned into text: str() of a list or mapping built from YAML aliases
    # (a few hundred bytes) expands to gigabytes. A bool or a date is no specifier either.
    if isinstance(val, bool) or not isinstance(val, (str, int, float)):
        raise CheckoutFileError(f"{COMPAT_PATH}: {COMPAT_KEY} is a {type(val).__name__}, not a version "
                                "specifier string; refusing to use it")
    return str(val).strip()


def managed(repo_dir, step_paths):
    """Step paths whose Dockerfile declares ARG KAOS_LIB_PACKAGE (the steps the platform can move).
    A step without a Dockerfile is not managed; one whose Dockerfile cannot be read safely raises
    CheckoutFileError."""
    out = []
    for p in step_paths:
        text = read_checkout_file(repo_dir, os.path.join(p, "Dockerfile"))
        if text is not None and ARG_RE.search(text):
            out.append(p)
    return out


# ---------------------------------------------------------------- decide (ml-ci-build)

def decide(ctx, recorded, compat, managed_paths):
    """What this build installs and reports.

    spec    the --build-arg KAOS_LIB_PACKAGE value ("" = none: the Dockerfile default)
    record  pipeline-images kaos-lib-package ("" = leave the keys as they are)
    compat  pipeline-images kaos-lib-compat (written with record)
    rebuild every managed step must be rebuilt (the spec moved since the last build)

    The operator already holds an app whose desired version is outside its compat range at
    the spec it was built with, so the CI builds what the context delivers.
    """
    want = str(kaos_lib(ctx).get("spec") or "").strip()
    if not want:
        return {"spec": "", "record": "", "compat": "", "rebuild": False, "managed": [],
                "reason": "the platform context delivers no kaos-lib package"}
    if not valid_spec(want):
        return {"spec": "", "record": "", "compat": "", "rebuild": False, "managed": [],
                "reason": f"REFUSED: the platform context's kaosLib.spec {want[:80]!r} is not a requirement "
                          "<name>[extras] ==X.Y.Z or @ a release asset, tag archive or commit archive"}
    if not managed_paths:
        return {"spec": "", "record": NONE, "compat": compat, "rebuild": False, "managed": [],
                "reason": "no step Dockerfile declares ARG KAOS_LIB_PACKAGE: the platform cannot move this app's package"}
    rebuild = recorded != want
    reason = (f"kaos-lib {recorded or '<unrecorded>'} -> {want}: rebuilding {len(managed_paths)} step(s)"
              if rebuild else f"kaos-lib {want}: the images already have it")
    return {"spec": want, "record": want, "compat": compat, "rebuild": rebuild, "managed": managed_paths,
            "reason": reason}


# ---------------------------------------------------------------- versions and specifiers

VERSION_RE = re.compile(r"([0-9]+(?:\.[0-9]+)*)(?:rc([0-9]+))?")


def parse_version(v):
    """The release part of X.Y.Z or X.Y.ZrcN (an rc of the kaos-lib prerelease channel)."""
    m = VERSION_RE.fullmatch(str(v).strip())
    if not m:
        raise ValueError(f"{v!r} is not a plain X.Y.Z or X.Y.ZrcN version")
    return [int(x) for x in m.group(1).split(".")]


def _key(v):
    """PEP 440 order, as the operator's kaoslibpkg: X.Y.ZrcN sorts just BEFORE X.Y.Z."""
    m = VERSION_RE.fullmatch(str(v).strip())
    if not m:
        raise ValueError(f"{v!r} is not a plain X.Y.Z or X.Y.ZrcN version")
    return [int(x) for x in m.group(1).split(".")], (0, int(m.group(2))) if m.group(2) else (1, 0)


def _cmp(a, b):
    """Compare two version strings (X.Y.Z or X.Y.ZrcN)."""
    (ra, sa), (rb, sb) = _key(a), _key(b)
    n = max(len(ra), len(rb))
    ka, kb = (ra + [0] * (n - len(ra)), sa), (rb + [0] * (n - len(rb)), sb)
    return (ka > kb) - (ka < kb)


def contains(specifier, version):
    """PEP 440 specifier membership for X.Y.Z and X.Y.ZrcN (==, !=, <=, >=, <, >, ~=, ===, .*); an rc
    counts as itself, so >=0.4 does not hold 0.4.0rc1 (the operator's rule too)."""
    v = parse_version(version)
    for clause in [c.strip() for c in str(specifier).split(",") if c.strip()]:
        m = re.fullmatch(r"(===|==|!=|<=|>=|~=|<|>)\s*([0-9][0-9.]*(?:rc[0-9]+)?)(\.\*)?", clause)
        if not m:
            raise ValueError(f"cannot read the specifier clause {clause!r}")
        op, target, wild = m.group(1), m.group(2).rstrip("."), bool(m.group(3))
        t = parse_version(target)
        if wild:
            if op not in ("==", "!="):
                raise ValueError(f"{clause!r}: a wildcard needs == or !=")
            prefix = v[:len(t)] + [0] * max(0, len(t) - len(v))
            ok = prefix == t
            ok = ok if op == "==" else not ok
        elif op in ("==", "==="):
            ok = _cmp(version, target) == 0
        elif op == "!=":
            ok = _cmp(version, target) != 0
        elif op == "<=":
            ok = _cmp(version, target) <= 0
        elif op == ">=":
            ok = _cmp(version, target) >= 0
        elif op == "<":
            ok = _cmp(version, target) < 0
        elif op == ">":
            ok = _cmp(version, target) > 0
        else:  # ~=X.Y[.Z]: >= X.Y[.Z] and the same release up to the last component
            if len(t) < 2:
                raise ValueError(f"{clause!r}: ~= needs at least X.Y")
            ok = _cmp(version, target) >= 0 and v[:len(t) - 1] == t[:-1]
        if not ok:
            return False
    return True


def bump_range(version):
    """The compat range a bump pull request writes: the new version's minor (0.x) or major series."""
    v = parse_version(version) + [0, 0]
    if v[0] == 0:
        return f">=0.{v[1]},<0.{v[1] + 1}"
    return f">={v[0]}.{v[1]},<{v[0] + 1}"


# ---------------------------------------------------------------- the step contract

def spec_version(spec):
    """The version a spec installs; "" for a commit archive (it names no version) or an unreadable spec."""
    for pattern in (REGISTRY_RE, RELEASE_RE, TAG_RE):
        m = pattern.match(spec)
        if m:
            return m.group(3).lstrip("v")
    if INDEX_RE.match(spec):
        return spec.rsplit("==", 1)[1].strip()
    return ""


def on_contract(version):
    """True when version is kaos-lib 0.5 or later (0.5.0rcN is part of 0.5), False when it is older, None
    when it is not a released version: unknown is never refused."""
    try:
        return (parse_version(version) + [0])[:2] >= parse_version(CONTRACT_MIN)
    except ValueError:
        return None


def accepts_contract(compat):
    """The app's declared range admits the first release of the step contract."""
    try:
        return bool(compat) and contains(compat, CONTRACT_MIN + ".0")
    except ValueError:
        return False


def crosses_contract(recorded, spec):
    """The images were built with a kaos-lib from before the step contract and spec is on it: they cannot
    run a pipeline of this engine, so they are not "stale, rebuilt on use"."""
    return on_contract(spec_version(recorded)) is False and on_contract(spec_version(spec)) is True


# What an app made before the current pipelines is told: the engine ends its refusals of such an app with the
# same two sentences (kaos-hpc-operator engine step_contract.OLD_APP_NOTICE).
OLD_APP_NOTICE = "This app was made before the current pipelines. Create it again from the template."


def contract_check(spec, compat):
    """{ok, message}: may a build install spec?

    Refused: a spec older than the step contract for an app whose own range does not accept kaos-lib 0.5.
    Its steps would be built with a kaos-lib that cannot read what the pipeline hands them. Not refused: a
    spec with no readable version; and an app whose range already accepts 0.5 while the platform still
    delivers the older spec (the build that reports the new range: the platform moves the app after it).
    """
    version = spec_version(spec)
    if on_contract(version) is not False:
        return {"ok": True, "message": ""}
    if accepts_contract(compat):
        return {"ok": True, "message": f"kaos-lib {version} is still delivered to this app; its {COMPAT_PATH} "
                                       f"accepts {CONTRACT_MIN}, so the platform moves it after this build"}
    return {"ok": False, "message":
            f"It is built with kaos-lib {version}; the current pipelines need kaos-lib {CONTRACT_MIN} or newer. "
            f"{OLD_APP_NOTICE}"}


# ---------------------------------------------------------------- support verdict

def support_json(ctx):
    s = kaos_lib(ctx).get("support")
    if isinstance(s, str):
        try:
            s = json.loads(s)
        except ValueError:
            return None
    return s if isinstance(s, dict) else None


def support_verdict(version, support, today=None):
    """{verdict, message}: current | behind | deprecated | unsupported | unknown (contract: Support window).

    unsupported = outside `supported` and past any deadline; deprecated = in a deprecated range before its
    deadline; behind = supported but older than the newest release; a git version cannot be compared.
    """
    today = today or datetime.date.today()
    newest = str(support.get("version") or "")
    try:
        v = parse_version(version)
    except ValueError:
        return {"verdict": "unknown", "message": f"kaos-lib {version}: not a released version, nothing to check"}
    for dep in support.get("deprecated") or []:
        rng, after = str(dep.get("range") or ""), str(dep.get("unsupported_after") or "")
        try:
            if not (rng and contains(rng, version)):
                continue
            past = bool(after) and today > datetime.date.fromisoformat(after)
        except ValueError:
            continue
        if past:
            return {"verdict": "unsupported", "message": f"kaos-lib {version} is unsupported since {after}; "
                                                         f"move to {support.get('supported') or newest}"}
        return {"verdict": "deprecated", "message": f"kaos-lib {version} is deprecated, unsupported after {after or '?'}"}
    supported = str(support.get("supported") or "")
    try:
        in_window = not supported or contains(supported, version)
    except ValueError:
        in_window = True
    if not in_window:
        return {"verdict": "unsupported", "message": f"kaos-lib {version} is outside the supported range {supported}"}
    try:
        behind = bool(newest) and _cmp(version, newest) < 0
    except ValueError:
        behind = False
    if behind:
        return {"verdict": "behind", "message": f"kaos-lib {version}: {newest} is available"}
    return {"verdict": "current", "message": f"kaos-lib {version} is current"}


def status_for(verdict):
    """The kaos-lib/support commit status for a verdict: (state, description prefix)."""
    if verdict["verdict"] == "unsupported":
        return "failure", ""
    if verdict["verdict"] in ("behind", "deprecated"):
        return "success", "warning: "
    return "success", ""


def safe(text, n=140):
    """A commit-status description: printable, no shell or quote characters, at most n characters."""
    return re.sub(r"[^A-Za-z0-9 .,:;<>=!~()/_+@-]", "", text)[:n]


# ---------------------------------------------------------------- bump pull request

class GitHub:
    """The few GitHub REST calls the bump job makes. GITHUB_API overrides the base (tests)."""

    def __init__(self, token, api=None):
        self.api = (api or os.environ.get("GITHUB_API") or "https://api.github.com").rstrip("/")
        self.token = token

    def call(self, method, path, body=None, ok=(200, 201, 204)):
        req = urllib.request.Request(self.api + path, method=method,
                                     data=json.dumps(body).encode() if body is not None else None,
                                     headers={"Accept": "application/vnd.github+json", "User-Agent": "kubecore-ci",
                                              "Authorization": f"Bearer {self.token}",
                                              "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            if e.code in ok:
                return e.code, (json.loads(raw) if raw else None)
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"message": raw.decode(errors="replace")[:200]}


def changelog_url(spec, default_url):
    """Where the release notes of a spec live: the archive's repository at its commit, else default_url."""
    m = re.match(r"^" + NAME + r" @ https://github\.com/([^/]+)/([^/]+)/archive/([0-9a-f]{40})\.zip(?:#(.*))?$", spec)
    if not m:
        return default_url
    frag = dict(urllib.parse.parse_qsl(m.group(4) or "", separator="&"))
    sub = frag.get("subdirectory", "").strip("/")
    return f"https://raw.githubusercontent.com/{m.group(1)}/{m.group(2)}/{m.group(3)}/" + (f"{sub}/" if sub else "") + "CHANGELOG.md"


def release_notes(changelog, version):
    """The `## <version>` section of a CHANGELOG.md ("" when absent). `## v0.3.0` and `## [0.3.0]` count."""
    out, inside = [], False
    head = re.compile(r"^##\s+\[?v?" + re.escape(version) + r"\]?(\s|$)")
    for line in changelog.splitlines():
        if line.startswith("## "):
            if inside:
                break
            inside = bool(head.match(line))
            continue
        if inside:
            out.append(line)
    return "\n".join(out).strip()


def fetch(url):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "kubecore-ci"}), timeout=30) as r:
            return r.read().decode(errors="replace")
    except (urllib.error.URLError, OSError, ValueError):
        return ""


def compat_file(current, specifier, guide_url):
    """`.kaos/compat.yaml` with its kaos-lib line set to specifier; comments and other keys kept."""
    line = f'{COMPAT_KEY}: "{specifier}"'
    if current and re.search(rf"^{re.escape(COMPAT_KEY)}\s*:", current, re.M):
        return re.sub(rf"^{re.escape(COMPAT_KEY)}\s*:.*$", line, current, count=1, flags=re.M)
    head = ("# The kaos-lib versions this app's code works with: a PEP 440 version specifier.\n"
            f"# Written by the platform's bump pull request; see {guide_page(guide_url, SUPPORT_WINDOW_PAGE)}\n")
    return (current.rstrip("\n") + "\n" if current else head) + line + "\n"


def bump(gh, slug, base, version, spec, default_changelog, guide_url, log=print):
    """Open the ONE bump pull request for version, close the bump pull requests it supersedes.

    Idempotent: a pull request ever opened for this version's branch (open, closed or merged)
    means no new one. Returns {"action": opened|exists|declined|refused, "number": N|None, "closed": [...]}.
    """
    try:
        parse_version(version)
    except ValueError:
        log(f"bump: {version!r} is not a released version: a compat range does not apply, no pull request")
        return {"action": "refused", "number": None, "closed": []}
    owner = slug.split("/")[0]
    branch = BUMP_PREFIX + version
    q = urllib.parse.urlencode({"state": "all", "head": f"{owner}:{branch}", "per_page": 100})
    code, prs = gh.call("GET", f"/repos/{slug}/pulls?{q}")
    if code != 200:
        raise SystemExit(f"bump: cannot list pull requests of {slug} (HTTP {code}): {prs}")
    mine = [p for p in prs if (p.get("head") or {}).get("ref") == branch]
    number, action = None, ""
    if mine:
        p = sorted(mine, key=lambda p: p["number"])[0]
        number = p["number"]
        action = "exists" if p.get("state") == "open" else "declined"
        log(f"bump: #{number} for kaos-lib {version} already exists ({p.get('state')}"
            f"{', merged' if p.get('merged_at') else ''}): no second pull request")
    else:
        code, ref = gh.call("GET", f"/repos/{slug}/git/ref/heads/{urllib.parse.quote(base)}")
        if code != 200:
            raise SystemExit(f"bump: cannot read {slug}@{base} (HTTP {code}): {ref}")
        code, out = gh.call("POST", f"/repos/{slug}/git/refs", {"ref": f"refs/heads/{branch}", "sha": ref["object"]["sha"]},
                            ok=(201, 422))
        if code == 422:
            log(f"bump: branch {branch} already exists (an earlier attempt): reusing it")
        code, cur = gh.call("GET", f"/repos/{slug}/contents/{COMPAT_PATH}?ref={urllib.parse.quote(branch)}", ok=(200, 404))
        current, sha = "", None
        if code == 200:
            current, sha = base64.b64decode(cur["content"]).decode(), cur["sha"]
        rng = bump_range(version)
        new = compat_file(current, rng, guide_url)
        if new != current:
            body = {"message": f"chore(kaos-lib): accept kaos-lib {version} ({rng})",
                    "content": base64.b64encode(new.encode()).decode(), "branch": branch}
            if sha:
                body["sha"] = sha
            code, out = gh.call("PUT", f"/repos/{slug}/contents/{COMPAT_PATH}", body)
            if code not in (200, 201):
                raise SystemExit(f"bump: cannot write {COMPAT_PATH} on {branch} (HTTP {code}): {out}")
        rel = RELEASE_RE.match(spec) or TAG_RE.match(spec)
        record_url = registry_record_url(spec)
        if record_url:  # the platform registry: the release record carries the CHANGELOG section
            url = record_url
            try:
                notes = str((json.loads(fetch(url) or "{}") or {}).get("notes") or "").strip()
            except ValueError:
                notes = ""
        elif rel:  # a GitHub release (asset or tag archive): its notes are the release's body
            url = f"https://github.com/{rel.group(1)}/{rel.group(2)}/releases/tag/{rel.group(3)}"
            code, r = gh.call("GET", f"/repos/{rel.group(1)}/{rel.group(2)}/releases/tags/{rel.group(3)}", ok=(200, 404))
            notes = str((r or {}).get("body") or "").strip() if code == 200 else ""
        else:
            url = changelog_url(spec, default_changelog)
            notes = release_notes(fetch(url), version) if url else ""
        text = (f"The platform moves this app to **kaos-lib {version}**, which is outside the range in "
                f"`{COMPAT_PATH}`. This pull request changes the range to `{rng}`.\n\n"
                f"- **Merge it** when you are ready: the push builds your step images with kaos-lib {version}.\n"
                f"- **Close it** to stay on the version your images have: the platform opens no second pull request "
                f"for {version}.\n\n"
                + f"Package: `{spec}`\n\n## Release notes\n\n"
                + (notes or f"No release notes for {version} were found at {url or 'the package changelog'}.")
                + "\n\n🤖 Opened by the KubeCore platform (kaos-lib delivery).")
        code, pr = gh.call("POST", f"/repos/{slug}/pulls",
                           {"title": f"Bump kaos-lib to {version}", "head": branch, "base": base, "body": text})
        if code != 201:
            raise SystemExit(f"bump: cannot open the pull request for {branch} (HTTP {code}): {pr}")
        number, action = pr["number"], "opened"
        log(f"bump: opened #{number} ({branch} -> {base})")

    closed = []
    q = urllib.parse.urlencode({"state": "open", "per_page": 100})
    code, open_prs = gh.call("GET", f"/repos/{slug}/pulls?{q}")
    if code != 200:
        raise SystemExit(f"bump: cannot list open pull requests of {slug} (HTTP {code}): {open_prs}")
    for p in open_prs:
        ref = (p.get("head") or {}).get("ref") or ""
        same_repo = ((p.get("head") or {}).get("repo") or {}).get("full_name") == slug
        if not ref.startswith(BUMP_PREFIX) or ref == branch or not same_repo:
            continue
        gh.call("POST", f"/repos/{slug}/issues/{p['number']}/comments",
                {"body": f"Superseded by kaos-lib {version} (#{number})."})
        code, out = gh.call("PATCH", f"/repos/{slug}/pulls/{p['number']}", {"state": "closed"})
        if code != 200:
            raise SystemExit(f"bump: cannot close superseded #{p['number']} (HTTP {code}): {out}")
        gh.call("DELETE", f"/repos/{slug}/git/refs/heads/{urllib.parse.quote(ref)}", ok=(204, 404, 422))
        closed.append(p["number"])
        log(f"bump: closed #{p['number']} ({ref}), superseded by kaos-lib {version}")
    return {"action": action, "number": number, "closed": closed}


# ---------------------------------------------------------------- CLI

def main(argv=None):
    ap = argparse.ArgumentParser(prog="kaos-lib.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decide")
    d.add_argument("--context", required=True)
    d.add_argument("--recorded", default="")
    d.add_argument("--repo", required=True)
    d.add_argument("--steps", required=True, help="file with one step path per line")
    c = sub.add_parser("context")
    c.add_argument("--context", required=True)
    s = sub.add_parser("support")
    s.add_argument("--context", required=True)
    k = sub.add_parser("contract")
    k.add_argument("--spec", required=True)
    k.add_argument("--recorded", default="")
    k.add_argument("--compat", default="")
    b = sub.add_parser("bump")
    for a in ("--slug", "--base", "--version", "--spec", "--changelog-url", "--guide-url"):
        b.add_argument(a, required=a != "--changelog-url", default="")
    b.add_argument("--token-file", default="/etc/github-token/token")
    args = ap.parse_args(argv)

    if args.cmd == "decide":
        with open(args.steps) as f:
            steps = [ln.strip() for ln in f if ln.strip()]
        try:
            compat, managed_paths = read_compat(args.repo), managed(args.repo, steps)
        except CheckoutFileError as exc:
            # The step's existing failure path: kaos-lib left as it is (no spec, no record written).
            print(f"kaos-lib: REFUSED: {exc}", file=sys.stderr)
            return EXIT_REFUSED
        out = decide(load_context(args.context), args.recorded.strip(), compat, managed_paths)
        json.dump(out, sys.stdout)
    elif args.cmd == "context":
        print(str(kaos_lib(load_context(args.context)).get("spec") or "").strip())
    elif args.cmd == "support":
        ctx = load_context(args.context)
        sup, version = support_json(ctx), str(kaos_lib(ctx).get("version") or "").strip()
        if not sup or not version:
            json.dump({"verdict": "", "state": "", "description": ""}, sys.stdout)
            return 0
        v = support_verdict(version, sup)
        state, prefix = status_for(v)
        json.dump({"verdict": v["verdict"], "state": state, "description": safe(prefix + v["message"])}, sys.stdout)
    elif args.cmd == "bump":
        with open(args.token_file) as f:
            gh = GitHub(f.read().strip())
        json.dump(bump(gh, args.slug, args.base, args.version, args.spec, args.changelog_url, args.guide_url,
                       log=lambda m: print(m, file=sys.stderr)), sys.stdout)
    elif args.cmd == "contract":
        out = contract_check(args.spec.strip(), args.compat.strip())
        out["crosses"] = crosses_contract(args.recorded.strip(), args.spec.strip())
        json.dump(out, sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
