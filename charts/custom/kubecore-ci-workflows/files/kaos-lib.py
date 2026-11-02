"""kaos-lib delivery helpers for the ML CI (PRD novelcore/kaos#1147).

Contract: kubecore-operator study/kubecore/package-delivery-design.md. The operator writes
`kaosLib: {spec, version, support}` into the app's pipeline-context; this script is the CI side:

  decide  ml-ci-build detect-steps: the spec to build with and what to report back in
          pipeline-images (`kaos-lib-package`, `kaos-lib-compat`).
  context ml-ci-reconcile: the spec the platform context delivers.
  support the kaos-lib support verdict of the version a build resolved.
  bump    the bump pull request (branch kaos-lib/bump-<version>) in the app repo.

Standard library + PyYAML only (the toolbox image has both). Every input is data: nothing
read here is ever evaluated by a shell.
"""
import argparse
import base64
import datetime
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

import yaml

# A spec is the WHOLE pip requirement a build installs: a distribution name with optional
# extras, then ==X.Y.Z or " @ <url>". The URL forms (the operator's kaoslibpkg forms):
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


def valid_spec(spec):
    return len(spec) <= 512 and any(r.match(spec) for r in (RELEASE_RE, TAG_RE, COMMIT_RE, INDEX_RE))


ARG_RE = re.compile(r"^\s*ARG\s+KAOS_LIB_PACKAGE(\s|=|$)", re.M)
NONE = "none"  # pipeline-images kaos-lib-package: no step Dockerfile declares ARG KAOS_LIB_PACKAGE
BUMP_PREFIX = "kaos-lib/bump-"
COMPAT_PATH = ".kaos/compat.yaml"
COMPAT_KEY = "kaos-lib"


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


def read_compat(repo_dir):
    """The app's declared range (.kaos/compat.yaml, key kaos-lib); "" when none is declared."""
    try:
        with open(os.path.join(repo_dir, COMPAT_PATH)) as f:
            doc = yaml.safe_load(f) or {}
    except (OSError, yaml.YAMLError):
        return ""
    val = doc.get(COMPAT_KEY) if isinstance(doc, dict) else None
    return str(val).strip() if val is not None else ""


def managed(repo_dir, step_paths):
    """Step paths whose Dockerfile declares ARG KAOS_LIB_PACKAGE (the steps the platform can move)."""
    out = []
    for p in step_paths:
        try:
            with open(os.path.join(repo_dir, p, "Dockerfile")) as f:
                if ARG_RE.search(f.read()):
                    out.append(p)
        except OSError:
            pass
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

def parse_version(v):
    v = str(v).strip()
    if not re.fullmatch(r"[0-9]+(\.[0-9]+)*", v):
        raise ValueError(f"{v!r} is not a plain X.Y.Z release version")
    return [int(x) for x in v.split(".")]


def _cmp(a, b):
    n = max(len(a), len(b))
    a, b = a + [0] * (n - len(a)), b + [0] * (n - len(b))
    return (a > b) - (a < b)


def contains(specifier, version):
    """PEP 440 specifier membership for plain release versions (==, !=, <=, >=, <, >, ~=, ===, .*)."""
    v = parse_version(version)
    for clause in [c.strip() for c in str(specifier).split(",") if c.strip()]:
        m = re.fullmatch(r"(===|==|!=|<=|>=|~=|<|>)\s*([0-9][0-9.]*)(\.\*)?", clause)
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
            ok = _cmp(v, t) == 0
        elif op == "!=":
            ok = _cmp(v, t) != 0
        elif op == "<=":
            ok = _cmp(v, t) <= 0
        elif op == ">=":
            ok = _cmp(v, t) >= 0
        elif op == "<":
            ok = _cmp(v, t) < 0
        elif op == ">":
            ok = _cmp(v, t) > 0
        else:  # ~=X.Y[.Z]: >= X.Y[.Z] and the same release up to the last component
            if len(t) < 2:
                raise ValueError(f"{clause!r}: ~= needs at least X.Y")
            ok = _cmp(v, t) >= 0 and v[:len(t) - 1] == t[:-1]
        if not ok:
            return False
    return True


def bump_range(version):
    """The compat range a bump pull request writes: the new version's minor (0.x) or major series."""
    v = parse_version(version) + [0, 0]
    if v[0] == 0:
        return f">=0.{v[1]},<0.{v[1] + 1}"
    return f">={v[0]}.{v[1]},<{v[0] + 1}"


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
        behind = bool(newest) and _cmp(v, parse_version(newest)) < 0
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


def compat_file(current, specifier):
    """`.kaos/compat.yaml` with its kaos-lib line set to specifier; comments and other keys kept."""
    line = f'{COMPAT_KEY}: "{specifier}"'
    if current and re.search(rf"^{re.escape(COMPAT_KEY)}\s*:", current, re.M):
        return re.sub(rf"^{re.escape(COMPAT_KEY)}\s*:.*$", line, current, count=1, flags=re.M)
    head = ("# The kaos-lib versions this app's code works with: a PEP 440 version specifier.\n"
            "# Written by the platform's bump pull request; see docs/kaos-lib-versions.md.\n")
    return (current.rstrip("\n") + "\n" if current else head) + line + "\n"


def bump(gh, slug, base, version, spec, default_changelog, log=print):
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
        new = compat_file(current, rng)
        if new != current:
            body = {"message": f"chore(kaos-lib): accept kaos-lib {version} ({rng})",
                    "content": base64.b64encode(new.encode()).decode(), "branch": branch}
            if sha:
                body["sha"] = sha
            code, out = gh.call("PUT", f"/repos/{slug}/contents/{COMPAT_PATH}", body)
            if code not in (200, 201):
                raise SystemExit(f"bump: cannot write {COMPAT_PATH} on {branch} (HTTP {code}): {out}")
        rel = RELEASE_RE.match(spec) or TAG_RE.match(spec)
        if rel:  # a GitHub release (asset or tag archive): its notes are the release's body
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
                f"Package: `{spec}`\n\n## Release notes\n\n"
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
    b = sub.add_parser("bump")
    for a in ("--slug", "--base", "--version", "--spec", "--changelog-url"):
        b.add_argument(a, required=a != "--changelog-url", default="")
    b.add_argument("--token-file", default="/etc/github-token/token")
    args = ap.parse_args(argv)

    if args.cmd == "decide":
        with open(args.steps) as f:
            steps = [ln.strip() for ln in f if ln.strip()]
        out = decide(load_context(args.context), args.recorded.strip(), read_compat(args.repo), managed(args.repo, steps))
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
        json.dump(bump(gh, args.slug, args.base, args.version, args.spec, args.changelog_url,
                       log=lambda m: print(m, file=sys.stderr)), sys.stdout)
    return 0


if __name__ == "__main__":
    sys.exit(main())
