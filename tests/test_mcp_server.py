"""forge MCP server: tools, background jobs, read tools, and a stdio end-to-end check."""

from __future__ import annotations

import dataclasses
import json
import sys
import time
from pathlib import Path

import pytest
from mcp.server.mcpserver.exceptions import ToolError

from forge import mcp_server as fm
from forge.config import load_settings
from forge.memory import RunStore

REPO = Path(__file__).resolve().parent.parent


@pytest.fixture
def settings(tmp_path, monkeypatch):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", repo_root=REPO)
    monkeypatch.setattr(fm, "_settings", lambda: s)
    return s


def _wait(job_id: str, timeout: float = 20) -> dict:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        st = fm.job_state(job_id)
        if st["status"] != "running":
            return st
        time.sleep(0.1)
    raise AssertionError(f"job {job_id} still running")


def _game(settings, slug="g1"):
    store = RunStore(settings, slug)
    store.ensure()
    store.save_spec({"title": "Lava", "pitch": "climb", "core_loop": "jump",
                     "modules": [{"path": "ServerScriptService/Round.server.luau", "purpose": "rounds"}]})
    state = store.new_state("idea")
    state["iterations"] = [{"n": 1, "score": 6, "issues": [1], "errors": [], "summary": "ok"}]
    store.save_state(state)
    f = store.game_dir / "ServerScriptService/Round.server.luau"
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text("print('round')\n")
    return store


async def test_registers_exactly_the_documented_tools():
    names = {t.name for t in await fm.mcp.list_tools()}
    assert names == set(fm.TOOL_NAMES)


def test_job_runs_detached_and_reports_finish(settings):
    meta = fm.start_job("t", ["x"], argv=[sys.executable, "-c", "print('hello'); print('done')"])
    st = _wait(meta["id"])
    assert st["status"] == "finished" and st["tail"] == ["hello", "done"]
    assert "finished" in fm.job(meta["id"]) and meta["id"] in fm.jobs()


def test_job_failure_shows_exit_code(settings):
    meta = fm.start_job("t", ["x"], argv=[sys.executable, "-c", "import sys; print('boom'); sys.exit(3)"])
    assert _wait(meta["id"])["status"] == "failed (exit 3)"


def test_cancel_stops_a_running_job(settings):
    meta = fm.start_job("t", ["x"], argv=[sys.executable, "-c", "import time; time.sleep(30)"])
    time.sleep(0.3)
    assert "Cancelled" in fm.cancel_job(meta["id"])
    st = _wait(meta["id"])
    assert st["status"] != "running"
    assert "not running" in fm.cancel_job(meta["id"])


def test_unknown_job_is_a_tool_error(settings):
    with pytest.raises(ToolError):
        fm.job("nope")


def test_build_tools_start_the_right_forge_command(settings, monkeypatch):
    seen = []
    monkeypatch.setattr(fm, "start_job", lambda kind, args, env=None, argv=None:
                        seen.append((kind, args, env)) or {"id": f"{kind}-1"})
    _game(settings)
    assert "new-1" in fm.new_game("lava obby", iterations=2, studio="Forge-ai")
    fm.iterate("g1", 2, use_studio=False)
    fm.correct("g1", "ServerScriptService/Round.server.luau", "rounds never end")
    fm.improve("flame-and-blame", cycles=2, only="dry", studio="abc")
    assert seen[0] == ("new", ["new", "lava obby", "--iterations", "2"], {"FORGE_STUDIO": "Forge-ai"})
    assert seen[1][1] == ["run", "g1", "--iterations", "2", "--no-studio"]
    assert seen[2][1] == ["correct", "g1", "ServerScriptService/Round.server.luau", "rounds never end"]
    assert seen[3][1][-4:] == ["--only", "dry", "--studio", "abc"]
    fm.tester_report("g1", "hose broken", run_ids=["pt-1", "pt-2"], reporter="sam")
    assert seen[4][1] == ["report", "g1", "hose broken", "--run", "pt-1", "--run", "pt-2", "--by", "sam"]
    fm.fix("g1", cycles=4, max_fixes=2, studio="abc")
    assert seen[5][1] == ["fix", "g1", "--cycles", "4", "--rounds", "2", "--steps", "15", "--max-fixes", "2",
                          "--reports", "--studio", "abc"]


def test_build_tools_reject_bad_input(settings):
    with pytest.raises(ToolError):
        fm.new_game("   ")
    with pytest.raises(ToolError):
        fm.iterate("missing-game")
    _game(settings)
    with pytest.raises(ToolError):
        fm.correct("g1", "x.luau", " ")


def test_read_tools(settings):
    _game(settings)
    assert "| g1 | 1 | 6 | 6 | 0 |" in fm.games()
    g = fm.game("g1")
    assert "Lava" in g and "ServerScriptService/Round.server.luau" in g and "score 6" in g
    assert "print('round')" in fm.read_file("g1", "ServerScriptService/Round.server.luau")
    with pytest.raises(ToolError):
        fm.read_file("g1", "../../etc/passwd")
    with pytest.raises(ToolError):
        fm.read_file("g1", "nope.luau")
    assert "No improve cycles" in fm.scores("g1")
    assert fm.calls("g1") == "No calls recorded."


def test_empty_runs_dir_gives_next_step(settings):
    assert "new_game" in fm.games()


async def test_stdio_server_lists_tools_end_to_end():
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    params = StdioServerParameters(command=sys.executable, args=["-m", "forge.cli", "server"],
                                   cwd=str(REPO))
    async with stdio_client(params) as (r, w), ClientSession(r, w) as s:
        await s.initialize()
        names = {t.name for t in (await s.list_tools()).tools}
        assert set(fm.TOOL_NAMES) <= names
        res = await s.call_tool("lessons", {})
        assert res.content and not res.is_error


def test_project_mcp_config_registers_the_server():
    cfg = json.loads((REPO / ".mcp.json").read_text())
    assert "forge server" in " ".join(cfg["mcpServers"]["forge"]["args"])
