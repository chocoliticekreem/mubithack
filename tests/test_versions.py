"""forge.versions: per-game git versions with rollback as a new version."""

from __future__ import annotations

import pytest

from forge.versions import GameVersions, VersionError


def test_snapshot_restore_and_rollback_of_a_rollback(tmp_path):
    g = tmp_path / "game"
    (g / "a.luau").parent.mkdir(parents=True)
    (g / "a.luau").write_text("one")
    v = GameVersions(g)
    assert v.snapshot("first") == "v1"
    (g / "a.luau").write_text("two")
    (g / "b.luau").write_text("new file")
    assert v.snapshot("second") == "v2"
    (g / "c.luau").write_text("never committed")
    assert v.restore("v1", "bad change") == "v3"
    assert (g / "a.luau").read_text() == "one"
    assert not (g / "b.luau").exists() and not (g / "c.luau").exists()
    assert v.restore("v2", "undo the rollback") == "v4"
    assert (g / "b.luau").read_text() == "new file"
    assert [e["version"] for e in v.log()] == ["v1", "v2", "v3", "v4"]
    assert v.log()[2]["message"] == "rollback to v1: bad change"
    assert v.current() == "v4"


def test_unknown_version_is_an_error(tmp_path):
    v = GameVersions(tmp_path / "g")
    v.snapshot("x")
    with pytest.raises(VersionError, match="v1"):
        v.restore("v9", "nope")


def test_empty_snapshot_still_makes_a_version(tmp_path):
    v = GameVersions(tmp_path / "g")
    assert v.snapshot("a") == "v1" and v.snapshot("b") == "v2"


def test_versions_ten_and_up_sort_numerically(tmp_path):
    v = GameVersions(tmp_path / "g")
    for _ in range(11):
        v.snapshot("x")
    assert v.current() == "v11" and v.tags()[:3] == ["v1", "v2", "v3"]
