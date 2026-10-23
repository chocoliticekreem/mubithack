"""Tests for forge.mcp_server: tool registration, report formatting, stdout hygiene, stdio e2e."""

from __future__ import annotations

import sys
import textwrap
import types
from pathlib import Path

import pytest

from forge import mcp_server as ms

REPO = Path(__file__).resolve().parent.parent

FAKE_REPORT = {
    "run_id": "pt-20261023-abc",
    "goal": "spawn and pick up the hose",
    "goal_met": False,
    "summary": "Spawned fine, but the hose prompt never appeared.",
    "bugs": [{"title": "Hose prompt missing", "evidence": "no ProximityPrompt within 10 studs", "severity": "high"}],
    "steps": [
        {"n": 1, "observation": "on spawn", "action": {"type": "walk_to", "target": "FireTruck", "reason": "hose is on the truck"},
         "result": "arrived | near truck", "request_id": "req-1", "latency_ms": 900},
        {"n": 2, "observation": "at truck", "action": "press E", "reason": "interact", "result": "x" * 200,
         "request_id": "req-2", "latency_ms": 800},
    ],
    "probe": {"errors": []},
    "request_ids": ["req-1", "req-2"],
}

FAKE_PLAY_SRC = textwrap.dedent('''
    import copy
    REPORT = None
    async def playtest(settings, goal, steps=20, studio_name=None, *, llm=None, studio=None, step_seconds=2.0):
        print("PROGRESS: step 1 ...")          # must not reach the MCP stdout channel
        r = copy.deepcopy(REPORT); r["goal"] = goal; return r
    def load_report(settings, run_id):
        print("loading"); return copy.deepcopy(REPORT)
    def list_reports(settings):
        print("listing"); return [copy.deepcopy(REPORT)]
    async def correct_step(settings, run_id, step, note, *, llm=None):
        print("correcting")
        return {"run_id": run_id, "step": step, "before": "press E", "after": note, "request_id": "req-9"}
''')


def _fake_play_module() -> types.ModuleType:
    mod = types.ModuleType("forge.play")
    exec(FAKE_PLAY_SRC, mod.__dict__)
    mod.REPORT = FAKE_REPORT
    return mod


@pytest.fixture
def fake_play(monkeypatch):
    mod = _fake_play_module()
    import forge
    monkeypatch.setitem(sys.modules, "forge.play", mod)
    monkeypatch.setattr(forge, "play", mod, raising=False)
    return mod


def _text(result) -> str:
    return "\n".join(getattr(c, "text", "") for c in result.content)


async def test_tools_registered():
    names = {t.name for t in await ms.mcp.list_tools()}
    assert names == {"playtest", "playtest_correct", "playtest_report", "playtest_list", "forge_doctor"}
    schema = {t.name: t.input_schema for t in await ms.mcp.list_tools()}["playtest"]
    assert schema["required"] == ["goal"]
    assert {"goal", "steps", "studio"} <= set(schema["properties"])


def test_format_report():
    md = ms.format_report(FAKE_REPORT)
    assert "pt-20261023-abc" in md
    assert "**Goal met:** no" in md
    assert "[high] Hose prompt missing" in md
    assert "| n | action | reason | result |" in md
    assert "hose is on the truck" in md          # reason pulled out of a dict action
    assert "arrived \\| near truck" in md        # pipes escaped
    assert "x" * 200 not in md                   # long results trimmed
    assert "Mubit requests: 2" in md
    assert "playtest_correct(run_id=\"pt-20261023-abc\"" in md


async def test_playtest_tool_formats_and_keeps_stdout_clean(fake_play, capsys):
    res = await ms.mcp.call_tool("playtest", {"goal": "reach the fire", "steps": 3})
    md = _text(res)
    assert "**Goal:** reach the fire" in md and "Hose prompt missing" in md
    out, err = capsys.readouterr()
    assert out == ""
    assert "PROGRESS" in err


async def test_other_tools(fake_play, capsys):
    md = _text(await ms.mcp.call_tool("playtest_correct", {"run_id": "pt-1", "step": 2, "note": "use the hose"}))
    assert "step 2" in md and "use the hose" in md and "req-9" in md
    assert "pt-20261023-abc" in _text(await ms.mcp.call_tool("playtest_report", {"run_id": "pt-20261023-abc"}))
    assert "| `pt-20261023-abc` | no | 1 | 2 |" in _text(await ms.mcp.call_tool("playtest_list", {}))
    assert capsys.readouterr().out == ""


def test_format_list_empty():
    assert "No playtest reports" in ms.format_list([])


async def test_stdio_server_lists_and_calls_tools(tmp_path):
    """Start the real server over stdio (with a fake forge.play that prints) and talk to it."""
    from mcp.client.session import ClientSession
    from mcp.client.stdio import StdioServerParameters, stdio_client

    boot = tmp_path / "boot.py"
    boot.write_text(textwrap.dedent(f'''
        import sys, types, json
        sys.path.insert(0, {str(REPO)!r})
        mod = types.ModuleType("forge.play")
        exec({FAKE_PLAY_SRC!r}, mod.__dict__)
        mod.REPORT = json.loads({__import__("json").dumps(FAKE_REPORT)!r})
        sys.modules["forge.play"] = mod
        from forge.mcp_server import main
        main()
    '''))
    params = StdioServerParameters(command=sys.executable, args=[str(boot)], cwd=str(REPO))
    with open(tmp_path / "stderr.log", "w") as errlog:
        async with stdio_client(params, errlog=errlog) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                names = {t.name for t in (await session.list_tools()).tools}
                assert {"playtest", "playtest_correct", "playtest_report", "playtest_list", "forge_doctor"} <= names
                res = await session.call_tool("playtest", {"goal": "reach the fire"})
                assert not res.is_error
                assert "Hose prompt missing" in _text(res)
    assert "PROGRESS" in (tmp_path / "stderr.log").read_text()


def test_cli_has_play_commands():
    from forge.cli import build_parser
    p = build_parser()
    a = p.parse_args(["play", "reach the fire", "--steps", "5", "--studio", "Forge"])
    assert (a.goal, a.steps, a.studio) == ("reach the fire", 5, "Forge")
    a = p.parse_args(["play-correct", "pt-1", "3", "should jump"])
    assert (a.run_id, a.step, a.note) == ("pt-1", 3, "should jump")
    assert p.parse_args(["play-list"]).cmd == "play-list"
    assert p.parse_args(["mcp"]).cmd == "mcp"


async def test_tool_errors_surface_message(monkeypatch):
    mod = types.ModuleType("forge.play")

    def list_reports(settings):
        raise FileNotFoundError("no runs/playtests dir")
    mod.list_reports = list_reports
    import forge
    monkeypatch.setitem(sys.modules, "forge.play", mod)
    monkeypatch.setattr(forge, "play", mod, raising=False)
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="no runs/playtests dir"):
        await ms.mcp.call_tool("playtest_list", {})
