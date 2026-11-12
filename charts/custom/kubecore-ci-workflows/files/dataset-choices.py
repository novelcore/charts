"""The dataset pickers of an ML pipeline, from kaos-lake's read-only catalog (PRD novelcore/kaos#1283
D-05, PRD novelcore/kaos#1911 D-15). Every name a step declares in `inputs=` is a form field that holds a
dataset reference (`dataset-<name>@<version>`); each one gets the catalog's choices. One definition for
the two places that need it: the render (hera-enhance-commit fills the fields and records the digest of
what it offered) and the drift check (ml-ci-reconcile compares that digest with the catalog now).

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


def _ref(d):
    """The name a reference uses: a shared dataset is `<owner>/<dataset>` (PRD novelcore/kaos#1533 F-23)."""
    name, owner = d.get("name", ""), d.get("owner")
    return f"{owner}/{name}" if owner and "/" not in name else name


def _ordered(datasets):
    """The project's own datasets first, the default first, then by name; then the shared ones grouped by
    owner (owners in catalog order, catalog order within an owner)."""
    own = sorted((d for d in datasets if not d.get("owner")), key=lambda d: (not d.get("default"), d.get("name", "")))
    shared = [d for d in datasets if d.get("owner")]
    owners = list(dict.fromkeys(d["owner"] for d in shared))
    return own + [d for o in owners for d in shared if d["owner"] == o]


def choices(datasets):
    """<dataset>@<version> newest first, then <dataset>@latest, per dataset; the default dataset first, the
    shared datasets (<owner>/<dataset>) after the project's own."""
    out = []
    for d in _ordered(datasets):
        ref = _ref(d)
        out += [f"{ref}@{v['tag']}" for v in d.get("versions") or []] + [f"{ref}@latest"]
    return out


def input_names(table):
    """Every name a step declares in inputs= (the engine's step table): the form fields to fill."""
    return sorted({name for step in table for name in step["inputs"]})


def fill(wft, names, datasets):
    """Offer the catalog's choices on the form field of every input in names; returns {field: default}.

    The default stays what the app's config says when the catalog offers it (`latest` included: it is
    resolved to a commit when the run starts). A default the catalog does not offer becomes the latest of
    the same dataset, or of the project's own default dataset when that dataset does not exist. A shared
    dataset is only ever kept, never picked as a fallback; a project with no dataset of its own leaves the
    value as it is. A field the
    form does not have is an error: the engine gives every input a field of its own name.
    """
    offered = choices(datasets)
    ordered = _ordered(datasets)
    known = {_ref(d) for d in ordered}
    own = [d for d in ordered if not d.get("owner")]
    params = {p.get("name"): p for p in (wft["spec"].get("arguments") or {}).get("parameters") or []}
    filled = {}
    for name in names:
        if name not in params:
            raise KeyError(f"the pipeline declares the input '{name}' but its form has no field of that name")
        param = params[name]
        param["enum"] = list(offered)
        if param.get("value") not in offered:
            dataset = str(param.get("value") or "").split("@", 1)[0]
            fallback = dataset if dataset in known else (own[0]["name"] if own else "")
            if fallback:
                param["value"] = f"{fallback}@latest"
        filled[name] = param["value"]
    return filled


def digest(offered):
    """sha256 of the sorted choices: what a pipeline was rendered with. The choices include the shared
    datasets, so a share or unshare moves it and re-renders."""
    return hashlib.sha256("\n".join(sorted(offered)).encode()).hexdigest()


if __name__ == "__main__":
    if len(sys.argv) != 4 or sys.argv[1] != "digest":
        sys.exit("usage: dataset-choices.py digest ENDPOINT TOKEN_FILE")
    try:
        print(digest(choices(read_catalog(sys.argv[2], sys.argv[3]))))
    except Exception as exc:  # noqa: BLE001
        print(f"catalog not read ({type(exc).__name__}: {exc})", file=sys.stderr)
        sys.exit(1)
