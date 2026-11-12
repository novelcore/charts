import pytest

import harness


def test_diff_hera_fails_when_engine_dir_set(monkeypatch, capsys):
    monkeypatch.setenv("ENGINE_DIR", "/nonexistent")
    rc = harness.main(["diff-hera", "--raw", "r", "--context", "c", "--ref-a", "a", "--ref-b", "b"])
    assert rc != 0
    assert "ENGINE_DIR" in capsys.readouterr().err


def test_diff_hera_fails_when_refs_equal(monkeypatch, capsys):
    monkeypatch.delenv("ENGINE_DIR", raising=False)
    rc = harness.main(["diff-hera", "--raw", "r", "--context", "c", "--ref-a", "x", "--ref-b", "x"])
    assert rc != 0
    assert "nothing to compare" in capsys.readouterr().err


SHA = "a" * 40


def _isolate(monkeypatch):
    monkeypatch.delenv("ENGINE_DIR", raising=False)
    monkeypatch.setattr(harness, "_ENGINE_CACHE", {})
    monkeypatch.setattr(harness, "_ENGINE_FAIL", {})


def test_fetch_engine_caches_success(monkeypatch):
    _isolate(monkeypatch)
    calls = []
    monkeypatch.setattr(harness, "_fetch_engine", lambda repo, ref: calls.append(ref) or "/tmp/x")
    assert harness.fetch_engine(SHA, "o/r") == "/tmp/x"
    assert harness.fetch_engine(SHA, "o/r") == "/tmp/x"
    assert len(calls) == 1


def test_fetch_engine_caches_failure(monkeypatch):
    _isolate(monkeypatch)
    calls = []

    def boom(repo, ref):
        calls.append(ref)
        raise OSError("network down")

    monkeypatch.setattr(harness, "_fetch_engine", boom)
    for _ in range(2):
        with pytest.raises(Exception):
            harness.fetch_engine(SHA, "o/r")
    assert len(calls) == 1
