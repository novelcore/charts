"""The guard behind engine.py CONTEXT_UNREAD (PRD novelcore/kaos#1911 AC-24): the context-sha leaves these paths
out because the render does not read them. Here the pinned engine's enhancer renders every fixture twice, with
those paths moved, and the output must be identical. When the engine starts to read one, this fails: take the
path out of the lists (and the composition's $ctxUnread) in the same change."""
import copy
import os
import sys

import pytest

from harness import FIXTURES, _load, enhance_hera, fetch_engine, ENGINE_REF

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
