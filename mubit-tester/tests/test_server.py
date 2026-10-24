"""Tests for mubit_tester.server (mubit-tester): tool registration, formatting, stdout hygiene, harness-backed
tools against a fake Studio, AI fallbacks, CLI mirror, stdio e2e."""

from __future__ import annotations

import contextlib
import json
import sys
import textwrap
import types
from pathlib import Path

import pytest

import mubit_tester
from mubit_tester import server as ms
from test_harness import PLAYERS, FakeStudio

REPO = Path(__file__).resolve().parent.parent.parent

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
    mod = types.ModuleType("mubit_tester.play")
    exec(FAKE_PLAY_SRC, mod.__dict__)
    mod.REPORT = FAKE_REPORT
    return mod


@pytest.fixture
def fake_studio(monkeypatch):
    st = FakeStudio({
        "players": lambda a: PLAYERS,
        "act": lambda a: {"done": True, "detail": f"{a['action']} {a['userId']} {json.dumps(a['args'])}"},
        "query": lambda a: [{"path": "Workspace.Map.H0", "name": "Hydrant", "dist": 4.2}],
        "events": lambda a: {"now": 20.0, "events": [{"t": 19.5, "kind": "prompt_triggered",
                                                      "data": {"prompt": "Hydrant.Refill", "player": "Player1"}}]},
        "counters": lambda a: {"hose.spray": 3},
        "teleport": lambda a: True,
        "ignite": lambda a: {"path": a.get("path") or "Workspace.Map.House2"},
        "set_attr": lambda a: True,
        "config": lambda a: {"module": a["module"], "key": a["key"], "value": a.get("value", 7)},
        "round": lambda a: {"state": a.get("state", "Intermission")},
    })

    @contextlib.asynccontextmanager
    async def opener(select: bool = True):
        yield st
    monkeypatch.setattr(ms, "open_studio", opener)
    monkeypatch.setattr(ms, "STATE", {"studio_id": None, "hint": None})
    return st


@pytest.fixture
def fake_play(monkeypatch, fake_studio):
    mod = _fake_play_module()
    import forge
    monkeypatch.setitem(sys.modules, "mubit_tester.play", mod)
    monkeypatch.setattr(mubit_tester, "play", mod, raising=False)
    monkeypatch.setattr(ms, "_ai", lambda: None)  # single-player fallback (mubit_tester.play)
    return mod


def _text(result) -> str:
    return "\n".join(getattr(c, "text", "") for c in result.content)


CONTRACT_TOOLS = [
    "status", "studios", "play_start", "play_stop", "multiplayer_start", "sync", "preview",
    "players", "observe", "query", "inspect", "counters", "events", "errors", "console", "screenshot",
    "act", "act_all", "teleport", "ignite", "extinguish", "set_attr", "config", "reset", "round",
    "squads", "instances", "queue", "launch", "mission_start", "mission_end",
    "scenario_run", "scenario_list",
    "playtest", "explore", "playtest_correct", "suggest_fix", "report", "reports",
]


async def test_tools_registered():
    names = [t.name for t in await ms.mcp.list_tools()]
    assert sorted(names) == sorted(CONTRACT_TOOLS)
    assert sorted(ms.TOOL_NAMES) == sorted(CONTRACT_TOOLS)
    schemas = {t.name: t.input_schema for t in await ms.mcp.list_tools()}
    assert schemas["playtest"]["required"] == ["goal"]
    assert {"goal", "players", "steps", "roles"} <= set(schemas["playtest"]["properties"])
    assert schemas["act"]["required"] == ["player", "action"]
    assert schemas["playtest_correct"]["required"] == ["run_id", "step", "note"]
    assert "player" in schemas["playtest_correct"]["properties"]
    assert schemas["scenario_run"]["required"] == ["scenario"]
    assert ms.mcp.name == "mubit-tester"


def test_plugin_config_and_permissions():
    plugin = REPO / "mubit-tester"
    cfg = json.loads((plugin / ".mcp.json").read_text())["mcpServers"]
    assert cfg["mubit-tester"]["command"] == "${CLAUDE_PLUGIN_ROOT}/bin/mubit-tester-mcp.sh"
    assert json.loads((plugin / ".claude-plugin" / "plugin.json").read_text())["name"] == "mubit-tester"
    market = json.loads((REPO / ".claude-plugin" / "marketplace.json").read_text())
    assert market["plugins"][0]["source"] == "./mubit-tester"
    settings = json.loads((REPO / ".claude" / "settings.json").read_text())
    assert settings["enabledPlugins"]["mubit-tester@mubithack"] is True
    assert "mcp__plugin_mubit-tester_mubit-tester" in settings["permissions"]["allow"]


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
    assert "#0 **[high] Hose prompt missing" in md


def test_format_report_multiplayer():
    rep = {**FAKE_REPORT, "players": [{"name": "Player1", "role": "nozzle"}, {"name": "Player2", "role": "rescuer"}],
           "steps": [{**FAKE_REPORT["steps"][0], "player": "Player1"}, {**FAKE_REPORT["steps"][1], "player": "Player2"}]}
    md = ms.format_report(rep)
    assert "**Players:** Player1, Player2 (roles: nozzle, rescuer)" in md
    assert "| n | player | action | reason | result |" in md and "| 2 | Player2 |" in md


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
    assert "pt-20261023-abc" in _text(await ms.mcp.call_tool("report", {"run_id": "pt-20261023-abc"}))
    assert "| `pt-20261023-abc` | no | 1 | 2 |" in _text(await ms.mcp.call_tool("reports", {}))
    assert capsys.readouterr().out == ""


def _fake_ai(calls: list) -> types.ModuleType:
    ai = types.ModuleType("mubit_tester.ai")

    async def multi_playtest(settings, goal, players=None, steps=20, roles=None, *, llm=None, studio=None,
                             harness=None, mode="free", squads=1):
        print("AI tick")
        calls.append(("multi", goal, players, steps, roles, studio, harness, mode, squads))
        return {**FAKE_REPORT, "goal": goal, "players": [{"name": "Player1", "role": (roles or ["?"])[0]}]}

    async def explore(settings, minutes=3, players=None, *, llm=None, studio=None):
        calls.append(("explore", minutes, players))
        return {**FAKE_REPORT, "goal": "explore"}

    async def correct_step(settings, run_id, step, note, player=None, *, llm=None):
        calls.append(("correct", run_id, step, note, player))
        return {"run_id": run_id, "step": step, "player": player, "before": "a", "after": note, "request_id": "r"}

    async def suggest_fix(settings, run_id, bug_index, *, llm=None):
        calls.append(("fix", run_id, bug_index))
        return {"path": "ServerScriptService/Services/HoseService.luau", "problem": "no prompt",
                "patch_preview": "+ prompt.Enabled = true"}

    ai.multi_playtest, ai.explore, ai.correct_step, ai.suggest_fix = multi_playtest, explore, correct_step, suggest_fix
    return ai


async def test_ai_tools_use_tester_ai(monkeypatch, fake_studio, capsys):
    calls: list = []
    monkeypatch.setattr(ms, "_ai", lambda: _fake_ai(calls))
    md = _text(await ms.mcp.call_tool("playtest", {"goal": "put out House2", "players": 2, "roles": ["nozzle", "rescuer"]}))
    assert "**Players:** Player1 (roles: nozzle)" in md
    assert calls[-1][:5] == ("multi", "put out House2", 2, 20, ["nozzle", "rescuer"]) and calls[-1][5] is fake_studio
    assert calls[-1][6].studio is fake_studio and calls[-1][7:] == ("free", 1)
    await ms.mcp.call_tool("playtest", {"goal": "co-op", "mode": "squads", "squads": 2})
    assert calls[-1][7:] == ("squads", 2)
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="mode must be"):
        await ms.mcp.call_tool("playtest", {"goal": "x", "mode": "chaos"})
    md = _text(await ms.mcp.call_tool("playtest_correct", {"run_id": "r1", "step": 3, "note": "spray", "player": "2"}))
    assert calls[-1] == ("correct", "r1", 3, "spray", "2") and "(player 2)" in md
    md = _text(await ms.mcp.call_tool("suggest_fix", {"run_id": "r1", "bug": 1}))
    assert calls[-1] == ("fix", "r1", 1) and "HoseService.luau" in md and "prompt.Enabled" in md
    await ms.mcp.call_tool("explore", {"minutes": 0.5})
    assert calls[-1] == ("explore", 0.5, None)
    out, err = capsys.readouterr()
    assert out == "" and "AI tick" in err


async def test_ai_only_tools_without_ai(monkeypatch, fake_studio):
    monkeypatch.setattr(ms, "_ai", lambda: None)
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="mubit_tester.ai"):
        await ms.mcp.call_tool("suggest_fix", {"run_id": "r1", "bug": 0})
    with pytest.raises(ToolError, match="mubit_tester.ai"):
        await ms.mcp.call_tool("explore", {})


# ---------------------------------------------------------------- harness-backed tools

async def test_world_and_control_tools(fake_studio, capsys):
    md = _text(await ms.mcp.call_tool("players", {}))
    assert "## Players (2)" in md and "Player2" in md and "Hose" in md
    md = _text(await ms.mcp.call_tool("act", {"player": "2", "action": "walk_to", "args": {"pos": [1, 2, 3]}}))
    assert "walk_to 2" in md and fake_studio.calls[-1] == ("act", {"userId": "2", "action": "walk_to", "args": {"pos": [1, 2, 3]}})
    md = _text(await ms.mcp.call_tool("act_all", {"action": "jump"}))
    assert "Player1" in md and "Player2" in md
    md = _text(await ms.mcp.call_tool("query", {"tag": "Hydrant", "near": "1"}))
    assert "Workspace.Map.H0" in md and fake_studio.calls[-1] == ("query", {"tag": "Hydrant", "near": "1", "limit": 25})
    md = _text(await ms.mcp.call_tool("events", {"since": 10}))
    assert "prompt_triggered" in md and "since=20.0" in md and fake_studio.calls[-1][1] == {"since": 10}
    assert "hose.spray" in _text(await ms.mcp.call_tool("counters", {}))
    await ms.mcp.call_tool("teleport", {"player": "Player1", "path": "Workspace.Map.H0"})
    assert fake_studio.calls[-1] == ("teleport", {"userId": "Player1", "path": "Workspace.Map.H0"})
    await ms.mcp.call_tool("ignite", {"near": "1", "radius": 30})
    assert fake_studio.calls[-1] == ("ignite", {"near": "1", "radius": 30})
    await ms.mcp.call_tool("set_attr", {"path": "Workspace.X", "key": "Water", "value": 5})
    assert fake_studio.calls[-1][1] == {"path": "Workspace.X", "key": "Water", "value": 5}
    assert '"value": 7' in _text(await ms.mcp.call_tool("config", {"module": "Hose", "key": "Range"}))
    await ms.mcp.call_tool("config", {"module": "Hose", "key": "Range", "value": 40})
    assert fake_studio.calls[-1][1] == {"module": "Hose", "key": "Range", "value": 40}
    assert "Active" in _text(await ms.mcp.call_tool("round", {"state": "Active"}))
    assert "ForgeProbe: 0 error(s), 1 warning(s)" in _text(await ms.mcp.call_tool("errors", {}))
    assert _text(await ms.mcp.call_tool("console", {"tail": 3})) == "line 197\nline 198\nline 199"
    assert capsys.readouterr().out == ""


async def test_harness_error_and_arg_checks(fake_studio):
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="unknown command inspect"):
        await ms.mcp.call_tool("inspect", {"path": "Workspace.Nope"})
    with pytest.raises(ToolError, match="pos, path or to"):
        await ms.mcp.call_tool("teleport", {"player": "1"})
    with pytest.raises(ToolError, match="nearest Flammable"):
        await ms.mcp.call_tool("extinguish", {})
    fake_studio.playing = False
    with pytest.raises(ToolError, match="play_start"):
        await ms.mcp.call_tool("players", {})


async def test_play_start_status_stop(fake_studio, monkeypatch):
    from mubit_tester import harness as hm
    monkeypatch.setattr(hm, "READY_POLL", 0.01)
    fake_studio.playing = False
    assert "needs play" in _text(await ms.mcp.call_tool("status", {}))
    md = _text(await ms.mcp.call_tool("play_start", {}))
    assert "started now: True" in md and fake_studio.played == 1
    assert "harness: ok" in _text(await ms.mcp.call_tool("status", {}))
    assert "stopped" in _text(await ms.mcp.call_tool("play_stop", {}))
    assert fake_studio.stopped == 1


async def test_multiplayer_start_falls_back_to_instructions(fake_studio):
    fake_studio.playing = False
    md = _text(await ms.mcp.call_tool("multiplayer_start", {"players": 3}))
    assert "Clients and Servers" in md and "3" in md
    fake_studio.playing = True
    assert "already running" in _text(await ms.mcp.call_tool("multiplayer_start", {"players": 2}))


def _multi_windows(fake_studio, monkeypatch, n_clients=2, joined=2):
    """Fake Studio where starting a multiplayer test spawns a Server window and client windows."""
    monkeypatch.setattr(ms, "MULTIPLAYER_POLL", 0.01)
    monkeypatch.setattr(ms, "MULTIPLAYER_WAIT", 1.0)
    monkeypatch.setattr(ms, "MULTIPLAYER_JOIN_WAIT", 0.1)
    fake_studio.playing = False
    seen = {"n": 0, "codes": [], "ran_on": []}

    async def execute_luau(code, datamodel="Edit", timeout=None):
        seen["codes"].append((code, datamodel))
        seen["ran_on"].append(fake_studio.studio_id)
        if "ExecuteMultiplayerTestAsync" in code:
            return "started"
        if "AddPlayers" in code:
            return "added"
        return json.dumps({"ok": True, "result": {"version": "2", "players": joined}})

    async def list_studios():
        seen["n"] += 1
        base = [{"id": "edit-1", "name": "Forge.rbxlx"}]
        if seen["n"] > 2:
            base += [{"id": "srv-9", "name": "Server - Forge"}]
            base += [{"id": f"cl-{i}", "name": f"Client{i} - Forge"} for i in range(1, n_clients + 1)]
        return base

    async def call(tool, **args):
        sid = args.get("studio_id")
        dms = ["Server"] if sid == "srv-9" else ["Client"] if str(sid).startswith("cl-") else ["Edit"]
        return json.dumps({"datamodels": dms})
    fake_studio.execute_luau, fake_studio.list_studios, fake_studio.call = execute_luau, list_studios, call
    return seen


async def test_multiplayer_start_selects_server_window(fake_studio, monkeypatch):
    seen = _multi_windows(fake_studio, monkeypatch)
    md = _text(await ms.mcp.call_tool("multiplayer_start", {"players": 2}))
    assert "srv-9" in md and ms.STATE["studio_id"] == "srv-9" and ms.STATE["mode"] == "server"
    assert ms.STATE["clients"] == ["cl-1", "cl-2"]
    assert "2/2 player(s) joined" in md and "| client | `cl-2` |" in md
    start = next(c for c, _ in seen["codes"] if "ExecuteMultiplayerTestAsync" in c)
    assert "ExecuteMultiplayerTestAsync(2, " in start and seen["codes"][0][1] == "Edit"
    # the ping that counted players ran in the server window's Server datamodel
    assert seen["ran_on"][-1] == "srv-9" and seen["codes"][-1][1] == "Server"


async def test_multiplayer_start_reports_slow_joins_and_adds_players(fake_studio, monkeypatch):
    seen = _multi_windows(fake_studio, monkeypatch, n_clients=1, joined=1)
    md = _text(await ms.mcp.call_tool("multiplayer_start", {"players": 3}))
    assert "1/3 player(s) joined" in md and "Not everyone joined" in md
    md = _text(await ms.mcp.call_tool("multiplayer_start", {"players": 2, "add": True}))
    assert "AddPlayers(2)" in md
    assert any("AddPlayers(2)" in c and dm == "Server" for c, dm in seen["codes"])


async def test_multiplayer_start_reports_immediate_error(fake_studio):
    fake_studio.playing = False

    async def execute_luau(code, datamodel="Edit", timeout=None):
        return "error: a test session is already running"
    fake_studio.execute_luau = execute_luau
    md = _text(await ms.mcp.call_tool("multiplayer_start", {"players": 2}))
    assert "already running" in md and "Clients and Servers" in md and "Team Test" in md


async def test_harness_calls_route_to_server_window_then_client_relay(fake_studio, monkeypatch):
    """A Server-DM call that fails on the selected window moves to the window that has a Server
    datamodel; with no server window at all (Team Test) it relays through a client. Only windows this
    server knows (pinned, or spawned by its multiplayer test) are candidates; `other` is a stranger's
    playing Studio and is never adopted."""
    from forge.studio import StudioError
    windows = {"other": ["Client", "Server"], "edit-1": ["Edit"], "srv-9": ["Server"], "cl-1": ["Client"]}
    ms.STATE.update(pinned="edit-1", server_window="srv-9", clients=["cl-1"], mode="server")
    ran: list = []

    async def list_studios():
        return [{"id": k, "name": k} for k in windows]

    async def call(tool, **args):
        return json.dumps({"datamodels": windows[args["studio_id"]]})

    async def execute_luau(code, datamodel="Edit", timeout=None):
        ran.append((fake_studio.studio_id, datamodel, "InvokeServer" in code))
        if datamodel not in windows[fake_studio.studio_id]:
            raise StudioError(f"no {datamodel} datamodel")
        return json.dumps({"ok": True, "result": [{"userId": 1, "name": "Friend1", "helmet": 1}]})
    fake_studio.execute_luau, fake_studio.list_studios, fake_studio.call = execute_luau, list_studios, call
    fake_studio.studio_id = "edit-1"
    md = _text(await ms.mcp.call_tool("players", {}))
    assert "Friend1" in md and ms.STATE["studio_id"] == "srv-9" and ms.STATE["mode"] == "server"
    assert ran[-1] == ("srv-9", "Server", False)
    # Team Test: the server window is gone, only a client remains -> relay
    del windows["srv-9"]
    fake_studio.studio_id = "edit-1"
    md = _text(await ms.mcp.call_tool("players", {}))
    assert "Friend1" in md and ms.STATE["mode"] == "client" and ran[-1] == ("cl-1", "Client", True)
    assert not any(sid == "other" for sid, _, _ in ran)
    # nothing of ours has a Server/Client datamodel: fail clearly instead of using `other`
    del windows["cl-1"]
    ms.STATE.update(clients=[], mode="server")
    fake_studio.studio_id = "edit-1"
    with pytest.raises(Exception, match="no Server datamodel"):
        await ms.mcp.call_tool("players", {})
    assert not any(sid == "other" for sid, _, _ in ran)


async def test_multiplayer_start_never_adopts_an_older_playing_window(fake_studio, monkeypatch):
    seen = _multi_windows(fake_studio, monkeypatch)
    inner = fake_studio.list_studios
    other_call = fake_studio.call

    async def list_studios():
        return [{"id": "busy-1", "name": "Forge.rbxlx"}] + await inner()

    async def call(tool, **args):
        if args.get("studio_id") == "busy-1":
            return json.dumps({"datamodels": ["Client", "Server"]})  # someone else's solo playtest
        return await other_call(tool, **args)
    fake_studio.list_studios, fake_studio.call = list_studios, call
    fake_studio.studio_id = "edit-1"
    md = _text(await ms.mcp.call_tool("multiplayer_start", {"players": 2}))
    assert ms.STATE["studio_id"] == "srv-9" and "busy-1" not in md and ms.STATE["server_window"] == "srv-9"
    assert "busy-1" not in seen["ran_on"]


async def test_studios_select(fake_studio):
    md = _text(await ms.mcp.call_tool("studios", {"select": "fake-studio"}))
    assert "| * | `fake-studio` | Forge.rbxlx |" in md and ms.STATE["studio_id"] == "fake-studio"


async def test_scenario_tools(fake_studio, monkeypatch):
    from mubit_tester import harness as hm
    monkeypatch.setattr(hm, "READY_POLL", 0.01)
    md = _text(await ms.mcp.call_tool("scenario_list", {}))
    assert "smoke" in md and "hydrant_refill" in md
    inline = json.dumps({"name": "inline", "steps": [
        {"assert": {"cmd": "players", "path": "result.*.health", "op": ">", "value": 0}},
        {"act": {"player": "all", "action": "jump"}},
    ]})
    fake_studio.playing = False
    md = _text(await ms.mcp.call_tool("scenario_run", {"scenario": inline}))
    assert "## Scenario `inline`: PASS" in md and "prompt_triggered" in md
    assert fake_studio.played == 1 and fake_studio.stopped == 1  # started play, so stopped it again
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="no scenario"):
        await ms.mcp.call_tool("scenario_run", {"scenario": "nope"})


def test_format_list_empty():
    assert "No playtest reports" in ms.format_list([])


async def test_stdio_server_lists_and_calls_tools(tmp_path):
    """Start the real server over stdio (with a fake mubit_tester.play that prints) and talk to it."""
    from mcp.client.session import ClientSession
    from mcp.client.stdio import StdioServerParameters, stdio_client

    boot = tmp_path / "boot.py"
    boot.write_text(textwrap.dedent(f'''
        import sys, types, json
        sys.path[:0] = [{str(REPO / "mubit-tester")!r}, {str(REPO)!r}]  # this checkout, not an installed copy
        mod = types.ModuleType("mubit_tester.play")
        exec({FAKE_PLAY_SRC!r}, mod.__dict__)
        mod.REPORT = json.loads({__import__("json").dumps(FAKE_REPORT)!r})
        sys.modules["mubit_tester.play"] = mod
        from mubit_tester.server import main
        main()
    '''))
    params = StdioServerParameters(command=sys.executable, args=[str(boot)], cwd=str(REPO))
    with open(tmp_path / "stderr.log", "w") as errlog:
        async with stdio_client(params, errlog=errlog) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                names = {t.name for t in (await session.list_tools()).tools}
                assert names == set(CONTRACT_TOOLS)
                res = await session.call_tool("report", {"run_id": "pt-20261023-abc"})
                assert not res.is_error
                assert "Hose prompt missing" in _text(res)
                res = await session.call_tool("scenario_list", {})
                assert not res.is_error and "smoke" in _text(res)
    assert "loading" in (tmp_path / "stderr.log").read_text()


def test_cli_has_play_commands():
    from forge.cli import build_parser
    p = build_parser()
    a = p.parse_args(["play", "reach the fire", "--steps", "5", "--studio", "Forge"])
    assert (a.goal, a.steps, a.studio) == ("reach the fire", 5, "Forge")
    a = p.parse_args(["play-correct", "pt-1", "3", "should jump"])
    assert (a.run_id, a.step, a.note) == ("pt-1", 3, "should jump")
    assert p.parse_args(["play-list"]).cmd == "play-list"
    assert p.parse_args(["mcp"]).cmd == "mcp"


def test_cli_test_mirrors_every_tool():
    from forge.cli import build_parser, test_tool_args
    p = build_parser()
    for name in CONTRACT_TOOLS:
        req = {"observe": ["1"], "inspect": ["W.X"], "act": ["1", "jump"], "act_all": ["jump"], "teleport": ["1"],
               "set_attr": ["W.X", "Water", "5"], "config": ["Hose", "Range"], "scenario_run": ["smoke"],
               "queue": ["1"], "mission_end": ["M1"],
               "playtest": ["goal"], "playtest_correct": ["r", "2", "note"], "suggest_fix": ["r"],
               "report": ["r"]}.get(name, [])
        a = p.parse_args(["test", name, *req])
        assert a.cmd == "test" and a.tool == name
    a = p.parse_args(["test", "act-all", "use", "--args", '{"seconds": 2}'])
    assert a.tool == "act_all" and test_tool_args(a) == {"action": "use", "args": {"seconds": 2}}
    a = p.parse_args(["test", "query", "--tag", "Hydrant", "--near", "2", "--limit", "3"])
    assert test_tool_args(a) == {"tag": "Hydrant", "near": "2", "limit": 3}
    a = p.parse_args(["test", "playtest-correct", "r1", "4", "it should spray", "--player", "2"])
    assert test_tool_args(a) == {"run_id": "r1", "step": 4, "note": "it should spray", "player": "2"}


def test_cli_test_runs_tool(fake_studio, capsys):
    from forge.cli import main
    assert main(["test", "players"]) == 0
    assert "## Players (2)" in capsys.readouterr().out
    assert main(["test", "inspect", "Workspace.Nope"]) == 1
    assert "unknown command inspect" in capsys.readouterr().out


async def test_tool_errors_surface_message(monkeypatch):
    mod = types.ModuleType("mubit_tester.play")

    def list_reports(settings):
        raise FileNotFoundError("no runs/playtests dir")
    mod.list_reports = list_reports
    import forge
    monkeypatch.setitem(sys.modules, "mubit_tester.play", mod)
    monkeypatch.setattr(mubit_tester, "play", mod, raising=False)
    from mcp.server.mcpserver.exceptions import ToolError
    with pytest.raises(ToolError, match="no runs/playtests dir"):
        await ms.mcp.call_tool("reports", {})
