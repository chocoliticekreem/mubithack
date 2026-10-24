"""forge bench-io: table formatting and the offline (headless) rows."""
from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from forge import bench_io


def test_table_shows_speedup_and_skips_missing_rows():
    out = bench_io.table({
        "sync, nothing changed": {"before": 0.271, "after": 0.07, "note": "9 files"},
        "play until game ready": {"before": 2.5, "after": None},
        "custom row": {"before": 12.0, "after": 0.03},
    })
    lines = out.splitlines()
    assert lines[0].split()[:4] == ["step", "before", "after", "speedup"]
    sync = next(ln for ln in lines if ln.startswith("sync, nothing changed"))
    assert "271 ms" in sync and "70 ms" in sync and "3.9x" in sync and "9 files" in sync
    play = next(ln for ln in lines if ln.startswith("play until game ready"))
    assert play.split()[-1] == "-"
    assert "12.0 s" in out and "400.0x" in out
    assert "StudioMCP" not in out


def test_pick_module_prefers_a_reloadable_server_module(tmp_path):
    root = tmp_path / "g"
    (root / "ServerScriptService").mkdir(parents=True)
    (root / "ReplicatedStorage").mkdir()
    (root / "ServerScriptService" / "Main.server.luau").write_text("print(1)\n")
    (root / "ServerScriptService" / "Stateful.luau").write_text("local M = {}\nlocal cache = {}\nreturn M\n")
    (root / "ServerScriptService" / "Logic.luau").write_text("local M = {}\nreturn M\n")
    (root / "ReplicatedStorage" / "Shared.luau").write_text("return {}\n")
    assert bench_io._pick_module(root) == "ServerScriptService/Logic.luau"


@pytest.mark.skipif(shutil.which("luau") is None, reason="luau CLI not installed")
def test_offline_bench_never_touches_the_source_folder(tmp_path):
    root = tmp_path / "g"
    (root / "ServerScriptService").mkdir(parents=True)
    main = root / "ServerScriptService" / "Main.server.luau"
    main.write_text("workspace:SetAttribute('ServerBooted', true)\n")
    out = bench_io.bench(root, offline=True, repeat=1)
    assert "boot smoke test" in out and "run one logic check" in out and "headless check passed" in out
    assert main.read_text() == "workspace:SetAttribute('ServerBooted', true)\n"
    assert sorted(p.name for p in root.rglob("*")) == ["Main.server.luau", "ServerScriptService"]
