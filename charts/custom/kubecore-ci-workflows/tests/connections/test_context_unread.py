"""The guard behind engine.py CONTEXT_UNREAD (PRD novelcore/kaos#1911 AC-24): the context-sha leaves these paths
out because the render does not read them. Here the pinned engine's enhancer renders every fixture twice, with
those paths moved, and the output must be identical. When the engine starts to read one, this fails: take the
path out of the lists (and the composition's $ctxUnread) in the same change."""
import copy
import os
import sys

import pytest

from harness import FIXTURES, HPC_TWIN, _load, enhance_hera, fetch_engine, ENGINE_REF

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "files"))
import engine as chart_engine  # noqa: E402


def _moved(ctx):
    out = copy.deepcopy(ctx)
    for section, key in chart_engine.CONTEXT_UNREAD + chart_engine.CONTEXT_UNREAD_UNLESS_PINNED:
        out.setdefault(section, {})[key] = "moved-" + key
    return out


@pytest.mark.parametrize("name", [n for n, f in FIXTURES.items() if f.kind == "hera"])
def test_unread_paths_do_not_change_the_render(name):
    fx = FIXTURES[name]
    ctx = _load(fx.context)
    engine_dir = fetch_engine(ENGINE_REF)
    assert enhance_hera(engine_dir, fx.source, ctx, fx.catalog) == enhance_hera(engine_dir, fx.source, _moved(ctx), fx.catalog)


def test_the_fixtures_cover_yolo_and_hpc():
    """The guard above proves nothing for a path the fixtures never exercise: it needs a yolo app and an app with
    HPC (Slurm) enabled, whose render carries the HPC twin of a step and the hpc section the paths live in."""
    yolo = [n for n, f in FIXTURES.items() if f.source.endswith("hera-raw/yolo-app.yaml")]
    hpc = [n for n, f in FIXTURES.items() if (_load(f.context).get("hpc") or {}).get("enabled") is True]
    assert yolo and hpc
    name = hpc[0]
    fx = FIXTURES[name]
    ctx = _load(fx.context)
    assert ctx["hpc"].get("scratch") and ctx["hpc"].get("home")
    rendered = enhance_hera(fetch_engine(ENGINE_REF), fx.source, _moved(ctx), fx.catalog)
    assert HPC_TWIN in rendered
