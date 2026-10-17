import pytest

import harness


def test_diff_hera_fails_when_enhancer_dir_set(monkeypatch, capsys):
    monkeypatch.setenv("ENHANCER_DIR", "/nonexistent")
    rc = harness.main(["diff-hera", "--raw", "r", "--context", "c", "--ref-a", "a", "--ref-b", "b"])
    assert rc != 0
    assert "ENHANCER_DIR" in capsys.readouterr().err


def test_diff_hera_fails_when_refs_equal(monkeypatch, capsys):
    monkeypatch.delenv("ENHANCER_DIR", raising=False)
    rc = harness.main(["diff-hera", "--raw", "r", "--context", "c", "--ref-a", "x", "--ref-b", "x"])
    assert rc != 0
    assert "nothing to compare" in capsys.readouterr().err
