"""The `dataset` dropdown of an ML pipeline, from kaos-lake's read-only catalog (PRD
novelcore/kaos#1283 D-05). One definition for the two places that need it: the render
(hera-enhance-commit writes the choices into the pipeline and records their digest) and the
drift check (ml-ci-reconcile compares that digest with the catalog now).

    python3 -I dataset-choices.py digest ENDPOINT TOKEN_FILE

prints the digest of the catalog's choices, or exits 1 when the catalog cannot be read.
"""
import hashlib
import json
import sys
import urllib.request


def read_catalog(endpoint, token_path):
    """The catalog's datasets. Raises when it cannot be read."""
    req = urllib.request.Request(endpoint.rstrip("/") + "/kaos/v1/catalog",
                                 headers={"Authorization": "Bearer " + open(token_path).read().strip()})
    return json.load(urllib.request.urlopen(req, timeout=20)).get("datasets") or []


def choices(datasets):
    """(choices, default): <dataset>@<vN> newest first and <dataset>@latest per dataset, the default
    dataset first; the default is its newest version."""
    datasets = sorted(datasets, key=lambda d: (not d.get("default"), d.get("name", "")))
    out, default = [], ""
    for d in datasets:
        versions = [f"{d['name']}@{v['tag']}" for v in d.get("versions") or []]
        out += versions + [f"{d['name']}@latest"]
        if d.get("default") and not default:
            default = versions[0] if versions else f"{d['name']}@latest"
    return out, default


def digest(offered):
    """sha256 of the sorted choices: what a pipeline was rendered with."""
    return hashlib.sha256("\n".join(sorted(offered)).encode()).hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "digest":
        sys.exit("usage: dataset-choices.py digest ENDPOINT TOKEN_FILE")
    try:
        print(digest(choices(read_catalog(sys.argv[2], sys.argv[3]))[0]))
    except Exception as exc:  # noqa: BLE001
        print(f"catalog not read ({type(exc).__name__}: {exc})", file=sys.stderr)
        sys.exit(1)
