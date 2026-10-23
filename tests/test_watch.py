from forge.watch import diff, snapshot


def test_snapshot_and_diff(tmp_path):
    (tmp_path / "ReplicatedStorage").mkdir()
    (tmp_path / "tools").mkdir()
    a = tmp_path / "ReplicatedStorage" / "A.luau"
    a.write_text("return {}")
    (tmp_path / "tools" / "x.luau").write_text("ignored")
    s1 = snapshot(tmp_path)
    assert list(s1) == ["ReplicatedStorage/A.luau"]
    s2 = dict(s1, **{"ReplicatedStorage/B.luau": 1.0})
    s2["ReplicatedStorage/A.luau"] = s1["ReplicatedStorage/A.luau"] + 1
    assert diff(s1, s2) == ["ReplicatedStorage/A.luau", "ReplicatedStorage/B.luau"]
    assert diff(s2, {}) == ["-ReplicatedStorage/A.luau", "-ReplicatedStorage/B.luau"]
