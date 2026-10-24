"""forge MCP server: tools, background jobs, read tools, and a stdio end-to-end check."""

from __future__ import annotations

import dataclasses
import json
import os
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


async def test_job_runs_detached_and_reports_finish(settings):
    meta = fm.start_job("t", ["x"], argv=[sys.executable, "-c", "print('hello'); print('done')"])
    st = _wait(meta["id"])
    assert st["status"] == "finished" and st["tail"] == ["hello", "done"]
    assert "finished" in await fm.job(meta["id"]) and meta["id"] in fm.jobs()


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


async def test_unknown_job_is_a_tool_error(settings):
    with pytest.raises(ToolError):
        await fm.job("nope")


async def test_build_tools_start_the_right_forge_command(settings, monkeypatch):
    seen = []
    monkeypatch.setattr(fm, "start_job", lambda kind, args, env=None, argv=None:
                        seen.append((kind, args, env)) or {"id": f"{kind}-1"})
    _game(settings)
    assert "new-1" in await fm.build_game("lava obby", iterations=2, studio="Forge-ai", wait_seconds=0)
    fm.iterate("g1", 2, use_studio=False)
    fm.correct("g1", "ServerScriptService/Round.server.luau", "rounds never end")
    fm.fault_drill("flame-and-blame", cycles=2, only="dry", studio="abc")
    assert seen[0] == ("new", ["new", "lava obby", "--iterations", "2"], {"FORGE_STUDIO": "Forge-ai"})
    assert seen[1][1] == ["run", "g1", "--iterations", "2", "--no-studio"]
    assert seen[2][1] == ["correct", "g1", "ServerScriptService/Round.server.luau", "rounds never end"]
    assert seen[3][1][-4:] == ["--only", "dry", "--studio", "abc"]
    fm.tester_report("g1", "hose broken", run_ids=["pt-1", "pt-2"], reporter="sam")
    assert seen[4][1] == ["report", "g1", "hose broken", "--run", "pt-1", "--run", "pt-2", "--by", "sam"]
    await fm.improve_game("g1", cycles=4, max_fixes=2, studio="abc", edit_human_files=True, wait_seconds=0)
    assert seen[5][1] == ["fix", "g1", "--cycles", "4", "--rounds", "2", "--steps", "15", "--max-fixes", "2",
                          "--reports", "--edit-human-files", "--studio", "abc"]


async def test_build_tools_reject_bad_input(settings):
    with pytest.raises(ToolError):
        await fm.build_game("   ")
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
    assert "build_game" in fm.games()


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


def test_forge_plugin_is_in_the_marketplace_and_starts_the_server():
    market = json.loads((REPO / ".claude-plugin" / "marketplace.json").read_text())
    assert {"name": "forge", "source": "./forge-plugin"}.items() <= next(
        p for p in market["plugins"] if p["name"] == "forge").items()
    cfg = json.loads((REPO / "forge-plugin" / ".mcp.json").read_text())["mcpServers"]["forge"]
    assert cfg["command"] == "${CLAUDE_PLUGIN_ROOT}/bin/forge-mcp.sh"
    launcher = (REPO / "forge-plugin" / "bin" / "forge-mcp.sh")
    assert launcher.stat().st_mode & 0o111 and "forge\" server" in launcher.read_text()
    assert not (REPO / ".mcp.json").exists()  # the plugin replaces the project-level server


@pytest.mark.skipif(not (REPO / ".venv" / "bin" / "forge").exists(), reason="needs the checkout's .venv")
async def test_plugin_launcher_serves_setup_over_stdio():
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    params = StdioServerParameters(command=str(REPO / "forge-plugin" / "bin" / "forge-mcp.sh"),
                                   env={**os.environ, "FORGE_PROJECT_DIR": str(REPO)}, cwd="/")
    async with stdio_client(params) as (r, w), ClientSession(r, w) as s:
        init = await s.initialize()
        assert "setup first" in (init.instructions or "")
        assert "setup" in {t.name for t in (await s.list_tools()).tools}


def test_versions_and_rollback_tools(settings):
    from forge.versions import GameVersions

    store = _game(settings)
    f = store.game_dir / "ServerScriptService/Round.server.luau"
    v = GameVersions(store.game_dir)
    v.snapshot("first build")
    f.write_text("print('broken')\n")
    v.snapshot("fix: something")
    table = fm.versions("g1")
    assert "| v1 |" in table and "fix: something" in table
    assert "Restored v1 as v3" in fm.rollback("g1", "v1", reason="made it worse", sync_studio=False)
    assert f.read_text() == "print('round')\n"
    with pytest.raises(ToolError, match="no version"):
        fm.rollback("g1", "v99", sync_studio=False)


def test_cli_rollback_without_sync(settings, monkeypatch, capsys):
    from forge import cli
    from forge.versions import GameVersions

    store = _game(settings)
    monkeypatch.setattr(cli, "load_settings", lambda: settings)
    v = GameVersions(store.game_dir)
    v.snapshot("one")
    (store.game_dir / "ServerScriptService/Round.server.luau").write_text("print('two')\n")
    v.snapshot("two")
    assert cli.main(["rollback", "g1", "v1", "--no-sync"]) == 0
    assert "restored v1 as v3" in capsys.readouterr().out
    assert cli.main(["versions", "g1"]) == 0
    assert "rollback to v1: by hand" in capsys.readouterr().out


LOG = """
━━ forge new  lava-obby ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [designer]  spec                                           ✓  3.1s  req_ab
━━ build  4 modules ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [coder]     ServerScriptService/Round.server.luau          ✓  9.0s  req_cd
  [compile]   Round.server.luau                              ✗  line 4: expected end
━━ iteration 1  lava-obby ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  [critic]    score 6.5/10                                   ✓  4.0s
"""


def test_summarize_log_reads_phase_steps_score_and_failures():
    sm = fm.summarize_log(LOG.splitlines())
    assert sm["phase"] == "iteration 1 lava-obby" and sm["ok"] == 3 and sm["failed"] == 1
    assert sm["score"] == "6.5" and "expected end" in sm["fails"][0]


async def test_job_wait_streams_progress_and_summarizes(settings):
    code = ("import time,sys\n"
            "for ln in " + repr(LOG.splitlines()) + ":\n"
            "    print(ln, flush=True); time.sleep(0.05)\n")
    meta = fm.start_job("t", ["new", "x"], argv=[sys.executable, "-c", code])

    class Ctx:
        msgs = []

        async def report_progress(self, n, total=None, message=None):
            self.msgs.append(message)
    ctx = Ctx()
    md = await fm.job(meta["id"], wait_seconds=20, ctx=ctx)
    first = md.splitlines()[0]
    assert first.startswith(f"## Job `{meta['id']}`: finished; phase: iteration 1 lava-obby; 3 step(s) ok, 1 failed")
    assert "last score 6.5" in first and "Recent failures: [compile]" in md
    assert any("iteration 1" in m for m in ctx.msgs) and any("✗" in m for m in ctx.msgs)
    running = fm.start_job("t", ["x"], argv=[sys.executable, "-c", "import time; print('━━ build  1 ━━'); time.sleep(5)"])
    md = await fm.job(running["id"], wait_seconds=0.5)
    assert ": running; phase: build 1" in md.splitlines()[0] and "wait_seconds=300" in md
    fm.cancel_job(running["id"])


async def test_improve_game_appends_readiness_when_finished(settings, monkeypatch):
    _game(settings)
    real = fm.start_job
    monkeypatch.setattr(fm, "start_job", lambda kind, args, env=None, argv=None:
                        real(kind, args, argv=[sys.executable, "-c", "print('━━ fix cycle 1 ━━')"]))
    md = await fm.improve_game("g1", wait_seconds=15)
    assert "finished" in md.splitlines()[0] and "g1: not ready yet" in md and "[ ] checks" in md


def test_done_tool(settings):
    _game(settings)
    md = fm.done("g1")
    assert md.startswith("## g1: not ready") and "**Next:**" in md and "improve_game(slug)" in md
    with pytest.raises(ToolError):
        fm.done("nope")

