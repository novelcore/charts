#!/usr/bin/env python3
"""Build the lakeFS dataset catalog.yaml.

Discovers datasets = lakeFS refs (tags preferred, then branches) whose ROOT
holds a data.yaml. Resolves each to its immutable commit SHA and reads
data.yaml for a label. Emits catalog.yaml to stdout.

env: LAKEFS_ENDPOINT, LAKEFS_REPO, LAKEFS_AK, LAKEFS_SK

Shape MUST match render-wft's dataset-catalog reader:
  datasets[].{name, ref, refType, commit, repo, pathOverride, label, available}
  + top-level repo, defaultBranch.
"""
import base64
import json
import os
import sys
import urllib.error
import urllib.request

ENDPOINT = os.environ["LAKEFS_ENDPOINT"].rstrip("/")
REPO = os.environ["LAKEFS_REPO"]
AK = os.environ["LAKEFS_AK"]
SK = os.environ["LAKEFS_SK"]
AUTH = base64.b64encode(("%s:%s" % (AK, SK)).encode()).decode()


def api(path):
    req = urllib.request.Request(
        "%s/api/v1%s" % (ENDPOINT, path),
        headers={"Authorization": "Basic %s" % AUTH},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None
        raise


def obj_text(ref, path):
    req = urllib.request.Request(
        "%s/api/v1/repositories/%s/refs/%s/objects?path=%s" % (ENDPOINT, REPO, ref, path),
        headers={"Authorization": "Basic %s" % AUTH},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError:
        return None


def has_root_data_yaml(ref):
    r = api("/repositories/%s/refs/%s/objects/stat?path=data.yaml" % (REPO, ref))
    return r is not None


def ref_commit(ref):
    r = api("/repositories/%s/refs/%s/commits?amount=1" % (REPO, ref))
    if r and r.get("results"):
        return r["results"][0].get("id", "")
    return ""


def parse_label(ref, data_yaml_text):
    names = ""
    if data_yaml_text:
        for line in data_yaml_text.splitlines():
            s = line.strip()
            if s and ":" in s and s.split(":", 1)[0].strip().isdigit():
                nm = s.split(":", 1)[1].strip()
                names = (names + ", " + nm) if names else nm
    parts = [ref]
    if names:
        parts.append("classes: %s" % names)
    return " — ".join(parts)


def yq(s):
    s = str(s).replace("\\", "\\\\").replace('"', '\\"')
    return '"%s"' % s


def main():
    repo_info = api("/repositories/%s" % REPO) or {}
    default_branch = repo_info.get("default_branch", "main")

    seen = set()
    refs = []  # (name, refType) — tags first (immutable), then branches
    tags = api("/repositories/%s/tags?amount=1000" % REPO) or {"results": []}
    for t in tags.get("results", []):
        n = t.get("id", "")
        if n and "/" not in n and n not in seen:
            refs.append((n, "tag"))
            seen.add(n)
    branches = api("/repositories/%s/branches?amount=1000" % REPO) or {"results": []}
    for b in branches.get("results", []):
        n = b.get("id", "")
        if n and "/" not in n and n not in seen:
            refs.append((n, "branch"))
            seen.add(n)

    datasets = []
    for name, rtype in refs:
        if not has_root_data_yaml(name):
            continue
        commit = ref_commit(name)
        label = parse_label(name, obj_text(name, "data.yaml"))
        label += " (%s)" % ("frozen tag" if rtype == "tag" else "branch")
        datasets.append({
            "name": name,
            "ref": name,
            "refType": rtype,
            "commit": commit,
            # Pin the immutable commit so a run trains on a frozen snapshot.
            "pathOverride": "s3://%s/%s/" % (REPO, commit or name),
            "label": label,
        })

    out = []
    out.append("repo: %s" % yq(REPO))
    out.append("defaultBranch: %s" % yq(default_branch))
    out.append("datasets:")
    if not datasets:
        out.append("  []")
    for d in datasets:
        out.append("  - name: %s" % yq(d["name"]))
        out.append("    ref: %s" % yq(d["ref"]))
        out.append("    refType: %s" % yq(d["refType"]))
        out.append("    commit: %s" % yq(d["commit"]))
        out.append("    repo: %s" % yq(REPO))
        out.append("    pathOverride: %s" % yq(d["pathOverride"]))
        out.append("    label: %s" % yq(d["label"]))
        out.append("    available: true")
    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
