"""ForgeBridge protocol: Bridge state, HTTP routes, a fake plugin over real HTTP, widget actions,
plugin build/install, MCP tools and the forge/studio.py fast path."""

from __future__ import annotations

import asyncio
import json
import re
import stat
import threading
import time
from pathlib import Path

import pytest

from forge import bridge as fb

REPO = Path(__file__).resolve().parent.parent
TOKEN = "t0ken"


class FakePlugin:
    """Speaks the plugin side of the protocol over HTTP, like ForgeBridge.plugin.luau."""

    def __init__(self, port: int, place: str = "Forge-agents-25.rbxlx", dm: str = "Edit",
                 token: str = TOKEN, on_play=None) -> None:
        self.c = fb.BridgeClient(port, token)
        self.place, self.dm, self.session = place, dm, f"{dm}-{id(self)}"
        self.on_play = on_play
        self.alive = True
        self.forge: dict = {}
        self.ran: list[dict] = []

    def hello(self) -> dict:
        return self.c._call("POST", "/plugin/hello", {"place": self.place, "dm": self.dm,
                                                      "session": self.session, "version": 1})

    def send(self, *events: dict) -> dict:
        return self.c._call("POST", "/plugin/events", {"session": self.session, "events": list(events)})

    def bye(self) -> None:
        self.alive = False
        self.c._call("POST", "/plugin/bye", {"session": self.session})

    def execute(self, cmd: dict) -> tuple[bool, object]:
        op, args = cmd["op"], cmd["args"]
        if op == "ping":
            return True, {"dm": self.dm}
        if op == "run":
            code = args["code"]
            if "error(" in code:
                return False, "boom"
            m = re.match(r"return (.*)", code)
            return True, str(eval(m.group(1))) if m else ""
        if op == "play":
            if self.on_play:
                self.on_play(self, args.get("start", True))
            return True, "starting" if args.get("start", True) else "stopping"
        return False, f"unknown op {op}"

    def loop(self) -> None:
        fv = -1
        while self.alive:
            try:
                r = self.c._call("GET", f"/plugin/poll?session={self.session}&wait=2&fv={fv}", timeout=10)
            except fb.BridgeError:
                return  # server shut down at the end of the test
            if r.get("forge"):
                self.forge = r["forge"]
                fv = r["forge"]["version"]
            for cmd in r.get("commands", []):
                self.ran.append(cmd)
                ok, res = self.execute(cmd)
                self.c._call("POST", "/plugin/result", {"session": self.session, "id": cmd["id"], "ok": ok,
                                                        "result": res if ok else None,
                                                        "error": None if ok else res, "ms": 0.1})

    def start(self) -> "FakePlugin":
        assert self.hello()["bound"]
        threading.Thread(target=self.loop, daemon=True).start()
        return self


@pytest.fixture
def server():
    bridge = fb.Bridge(TOKEN, ["Forge-agents-25"], poll_wait=2)
    srv = fb.serve_in_thread(bridge, 0)
    port = srv.server_address[1]
    yield bridge, port, fb.BridgeClient(port, TOKEN)
    srv.shutdown()
    srv.server_close()


# ---------------------------------------------------------------- pure state


def test_place_key_strips_extension_and_case():
    assert fb.place_key("Forge-agents-25.rbxlx") == "forge-agents-25"
    assert fb.place_key("Forge-Agents-25") == "forge-agents-25"
    assert fb.place_key(None) == ""


def test_unlisted_place_stays_unbound_and_leaves_no_trace():
    b = fb.Bridge(TOKEN, ["Forge-agents-25"])
    r = b.hello("Firefighter Mubit", "Edit", "s1")
    assert r["bound"] is False and "forge" not in r
    assert b.status()["sessions"] == [] and b.seq == 0


def test_server_session_means_playing_and_its_expiry_means_stopped():
    now = [0.0]
    b = fb.Bridge(TOKEN, ["P"], clock=lambda: now[0], session_ttl=5)
    b.hello("P", "Edit", "e")
    b.hello("P.rbxlx", "Server", "s")
    assert b.status()["playing"] is True
    now[0] = 3
    b.poll("e", wait=0)            # Edit keeps polling, Server goes quiet
    now[0] = 7
    st = b.status()
    assert st["playing"] is False and [s["dm"] for s in st["sessions"]] == ["Edit"]
    kinds = [(e["type"], e.get("state")) for e in b.get_events()["events"]]
    assert ("play", "started") in kinds and ("play", "stopped") in kinds


def test_reloaded_plugin_replaces_its_old_session_but_clients_coexist():
    b = fb.Bridge(TOKEN, ["P"])
    b.hello("P.rbxlx", "Edit", "old")
    b.hello("P.rbxlx", "Edit", "new")
    b.hello("P", "Client", "c1")
    b.hello("P", "Client", "c2")
    sessions = {s["session"] for s in b.status()["sessions"]}
    assert sessions == {"new", "c1", "c2"}
    gone = [e for e in b.get_events()["events"] if e.get("state") == "gone"]
    assert gone[0]["session"] == "old" and gone[0]["why"] == "replaced"


def test_submit_needs_a_live_plugin_in_that_datamodel():
    b = fb.Bridge(TOKEN, ["P"])
    with pytest.raises(fb.BridgeError, match="Edit"):
        b.submit("run", {"code": "return 1"})
    b.hello("P", "Edit", "e")
    with pytest.raises(fb.BridgeError, match="Server"):
        b.submit("run", {"code": "return 1"}, "Server")
    with pytest.raises(fb.BridgeError, match="unknown op"):
        b.submit("format_disk", {})


def test_poll_returns_commands_only_for_its_datamodel():
    b = fb.Bridge(TOKEN, ["P"])
    b.hello("P", "Edit", "e")
    b.hello("P", "Server", "s")
    cid = b.submit("run", {"code": "return 2"}, "Server")
    b.poll("e", 0, -1)  # consume the initial forge status
    assert b.poll("e", wait=0, forge_version=b.forge_version)["commands"] == []
    got = b.poll("s", wait=0, forge_version=b.forge_version)["commands"]
    assert [c["id"] for c in got] == [cid]


def test_forge_status_change_wakes_a_waiting_poll():
    b = fb.Bridge(TOKEN, ["P"])
    b.hello("P", "Edit", "e")
    v = b.forge_version
    out = {}

    def waiter():
        t0 = time.perf_counter()
        out["r"] = b.poll("e", wait=5, forge_version=v)
        out["dt"] = time.perf_counter() - t0
    th = threading.Thread(target=waiter)
    th.start()
    time.sleep(0.1)
    b.set_forge(job="build tycoon", role="coder")
    th.join(3)
    assert out["r"]["forge"]["role"] == "coder" and out["dt"] < 2


def test_events_since_filter_limit_and_clipping():
    b = fb.Bridge(TOKEN, ["P"])
    b.hello("P", "Edit", "e")
    first = b.get_events()["next"]
    n = b.add_events("e", [{"type": "log", "kind": "output", "message": "hi"},
                           {"type": "error", "message": "x" * 10000, "script": "ServerScriptService.A"},
                           {"no": "type"}])
    assert n == 2
    res = b.get_events(since=first)
    assert [e["type"] for e in res["events"]] == ["log", "error", "forge"]  # forge: last_error
    assert all(e["dm"] == "Edit" for e in res["events"][:2])
    assert len(res["events"][1]["message"]) <= fb.MAX_FIELD + 1
    assert b.get_events(since=first, types=["error"])["events"][0]["script"] == "ServerScriptService.A"
    assert b.get_events(since=res["next"])["events"] == []
    assert b.add_events("nobody", [{"type": "log"}]) == 0


def test_play_error_reaches_the_edit_widget_as_forge_last_error():
    b = fb.Bridge(TOKEN, ["P"])
    b.hello("P", "Edit", "e")
    b.hello("P", "Server", "s")
    v = b.forge_version
    b.add_events("s", [{"type": "error", "message": "Fire:3: nil", "script": "ServerScriptService.Fire", "trace": "t"}])
    got = b.poll("e", wait=0, forge_version=v)["forge"]["last_error"]
    assert got["script"] == "ServerScriptService.Fire" and got["dm"] == "Server"
    v = b.forge_version
    b.add_events("s", [{"type": "error", "message": "Fire:3: nil", "script": "ServerScriptService.Fire", "trace": "t"}])
    assert b.forge_version == v  # the same error again doesn't wake the widget


def test_command_times_out_when_studio_never_answers():
    b = fb.Bridge(TOKEN, ["P"])
    b.hello("P", "Edit", "e")
    with pytest.raises(fb.BridgeError, match="timed out"):
        b.run("run", {"code": "return 1"}, timeout=0.3)
    assert b.queue == deque_empty()


def deque_empty():
    from collections import deque
    return deque()


# ---------------------------------------------------------------- over HTTP


def test_http_requires_token(server):
    _, port, _ = server
    bad = fb.BridgeClient(port, "wrong")
    with pytest.raises(fb.BridgeError, match="401"):
        bad.status()
    assert bad.health() is True  # /health is open, and says nothing about the state


def test_round_trip_run_and_errors(server):
    bridge, port, client = server
    FakePlugin(port).start()
    res = client.run("run", {"code": "return 40 + 2"})
    assert res["ok"] and res["result"] == "42" and res["ms"] < 1000
    assert client.luau("return 1 + 1") == "2"
    with pytest.raises(fb.LuauError, match="boom"):
        client.luau("error('x')")
    with pytest.raises(fb.BridgeError, match="Server"):
        client.run("run", {"code": "return 1"}, "Server")


def test_event_stream_over_http(server):
    _, port, client = server
    p = FakePlugin(port).start()
    p.send({"type": "log", "kind": "error", "message": "ServerScriptService.Fire:12: attempt to index nil"},
           {"type": "selection", "paths": ["ServerScriptService.Fire"]})
    res = client.events(0)
    types = [e["type"] for e in res["events"]]
    assert types[:1] == ["session"] and "log" in types and "selection" in types
    later = client.events(res["next"], wait=0.2)
    assert later["events"] == []


def test_long_poll_waiting_events_returns_when_one_arrives(server):
    _, port, client = server
    p = FakePlugin(port).start()
    since = client.events(0)["next"]
    threading.Timer(0.3, lambda: p.send({"type": "log", "message": "late"})).start()
    t0 = time.perf_counter()
    res = client.events(since, wait=5)
    assert res["events"][0]["message"] == "late" and time.perf_counter() - t0 < 3


def test_play_start_routes_to_edit_and_stop_to_server(server):
    bridge, port, client = server
    plugins: dict = {}

    def on_play(plugin, start):
        if start:   # Studio opens a Server datamodel whose plugin copy says hello
            plugins["server"] = FakePlugin(port, dm="Server", on_play=on_play)
            threading.Timer(0.1, plugins["server"].start).start()
        else:       # ending the test tears the Server datamodel down
            threading.Timer(0.1, plugin.bye).start()
    edit = FakePlugin(port, on_play=on_play).start()
    res = client.run("play", {"start": True}, timeout=5)
    assert res["ok"] and client.status()["playing"] is True
    assert edit.ran[-1]["op"] == "play"
    res = client.run("play", {"start": False}, timeout=5)
    assert res["ok"] and client.status()["playing"] is False
    assert plugins["server"].ran[-1]["args"] == {"start": False}
    assert client.run("play", {"start": False})["result"] == "already stopped"


def test_forge_status_reaches_the_plugin(server):
    _, port, client = server
    p = FakePlugin(port).start()
    client.set_status(job="tiny-tycoon v3", role="critic", last_test="PASS smoke")
    for _ in range(40):
        if p.forge.get("role") == "critic":
            break
        time.sleep(0.05)
    assert p.forge["job"] == "tiny-tycoon v3" and p.forge["last_test"] == "PASS smoke"
    assert client.status()["forge"]["role"] == "critic"


def test_connected_client_matches_place_and_datamodel(server, monkeypatch):
    bridge, port, _ = server
    monkeypatch.setattr(fb, "load_token", lambda *a, **k: TOKEN)
    FakePlugin(port).start()
    assert fb.connected_client("Forge-agents-25.rbxlx", "Edit", port) is not None
    assert fb.connected_client("Forge-agents-25", None, port) is not None
    assert fb.connected_client("Forge-agents-25.rbxlx", "Server", port) is None
    assert fb.connected_client("Firefighter Mubit", None, port) is None
    monkeypatch.setenv("FORGE_BRIDGE", "0")
    assert fb.connected_client("Forge-agents-25.rbxlx", "Edit", port) is None


def test_connected_client_is_none_when_no_bridge(monkeypatch):
    monkeypatch.setattr(fb, "load_token", lambda *a, **k: TOKEN)
    assert fb.connected_client(None, None, 1) is None


# ---------------------------------------------------------------- widget actions


def test_run_tests_button_runs_scenario_and_reports(tmp_path):
    b = fb.Bridge(TOKEN, ["P"])
    calls = []

    def spawn(argv, env, done):
        calls.append((argv, env["FORGE_STUDIO"]))
        assert b.forge["role"] == "tester"
        done(0, "PASS smoke (6 steps)\n...")
    fb.Actions(b, tmp_path, spawn=spawn)
    b.hello("P.rbxlx", "Edit", "e")
    b.add_events("e", [{"type": "run_tests", "place": "P.rbxlx"}])
    argv, studio = calls[0]
    assert argv[-3:] == ["test", "scenario_run", "smoke"] and studio == "p"
    assert b.forge["last_test"].startswith("PASS smoke") and b.forge["job"] is None


def test_test_summary_names_the_failing_step():
    out = ("## Scenario `smoke`: FAIL\n\n| n | step | ok | ms | detail |\n|---|---|---|---|---|\n"
           "| 1 | players spawned | ok | 66 | x |\n| 3 | everyone moved | FAIL | 15430 | y |\n")
    assert fb.test_summary("smoke", 1, out) == "FAIL smoke: step 3 everyone moved"
    ok = "## Scenario `smoke`: PASS\n| 1 | a | ok | 1 | |\n| 2 | b | ok | 1 | |\n"
    assert fb.test_summary("smoke", 0, ok) == "PASS smoke: 2 steps"
    assert fb.test_summary("smoke", 1, "boom") == "FAIL smoke: boom"


def test_fix_button_without_a_forge_job_is_left_for_mcp(tmp_path):
    b = fb.Bridge(TOKEN, ["P"])
    fb.Actions(b, tmp_path, spawn=lambda *a: pytest.fail("must not spawn"))
    b.hello("P", "Edit", "e")
    b.add_events("e", [{"type": "fix_request", "script": "ServerScriptService.Fire", "error": "nil index"}])
    assert "waiting in studio_events" in b.forge["message"]
    assert b.get_events(types=["fix_request"])["events"][0]["error"] == "nil index"


def test_fix_button_runs_forge_correct_on_the_mapped_file(tmp_path, monkeypatch):
    from forge import memory
    game = tmp_path / "game"
    (game / "ServerScriptService" / "Fire").mkdir(parents=True)
    (game / "ServerScriptService" / "Fire" / "FireSim.server.luau").write_text("--")

    class Store:
        def __init__(self, settings, slug):
            self.game_dir = game
    monkeypatch.setattr(memory, "RunStore", Store)
    b = fb.Bridge(TOKEN, ["P"])
    calls = []
    fb.Actions(b, tmp_path, spawn=lambda argv, env, done: (calls.append(argv), done(0, "fixed it")))
    b.set_forge(slug="tycoon")
    b.hello("P", "Edit", "e")
    b.add_events("e", [{"type": "fix_request", "script": "ServerScriptService.Fire.FireSim", "error": "nil"}])
    assert calls[0][-4:] == ["correct", "tycoon", "ServerScriptService/Fire/FireSim.server.luau", "nil"]
    assert b.forge["message"].startswith("fixed")


def test_studio_path_to_file(tmp_path):
    (tmp_path / "StarterPlayerScripts").mkdir()
    (tmp_path / "StarterPlayerScripts" / "Hud.client.luau").write_text("")
    (tmp_path / "ReplicatedStorage").mkdir()
    (tmp_path / "ReplicatedStorage" / "Config.luau").write_text("")
    assert fb.studio_path_to_file(tmp_path, "StarterPlayer.StarterPlayerScripts.Hud").name == "Hud.client.luau"
    assert fb.studio_path_to_file(tmp_path, "game.ReplicatedStorage.Config").name == "Config.luau"
    assert fb.studio_path_to_file(tmp_path, "Workspace.Nope") is None


# ---------------------------------------------------------------- plugin file


def test_plugin_source_implements_every_op_and_bakes_url_and_token():
    src = (REPO / "studio-plugin" / "ForgeBridge.plugin.luau").read_text()
    for op in fb.OPS:
        assert re.search(rf"function ops\.{op}\b", src), op
    for route in ("/plugin/hello", "/plugin/poll", "/plugin/result", "/plugin/events", "/plugin/bye"):
        assert route in src
    built = fb.build_plugin(REPO, "abc123", 40000, ["Forge-agents-25.rbxlx", "Other"])
    assert '"http://127.0.0.1:40000"' in built and '"abc123"' in built and "__FORGE" not in built
    assert '"forge-agents-25,other"' in built
    with pytest.raises(fb.BridgeError, match="place"):
        fb.build_plugin(REPO, "abc123", 40000, [])
    assert "MUBIT" not in built.upper().replace("MUBIT KEY", "")


def test_install_writes_private_file_where_told(tmp_path, monkeypatch):
    monkeypatch.setattr(fb, "store_dir", lambda root=None: tmp_path / "store")
    (tmp_path / "store").mkdir()
    out = fb.install_plugin(REPO, ["Forge-agents-25"], tmp_path / "Plugins", 34999)
    assert out == tmp_path / "Plugins" / "ForgeBridge.lua"
    assert stat.S_IMODE(out.stat().st_mode) == 0o600
    token = (tmp_path / "store" / "token").read_text()
    assert f'"{token}"' in out.read_text()


def test_default_plugins_dir_on_mac(monkeypatch):
    monkeypatch.setattr(fb.sys, "platform", "darwin")
    assert fb.default_plugins_dir() == Path.home() / "Documents" / "Roblox" / "Plugins"


# ---------------------------------------------------------------- MCP tools


async def test_register_adds_three_tools_and_reports_a_down_bridge():
    from mcp.server.mcpserver import MCPServer
    m = MCPServer("t")
    names = fb.register(m, port=1)
    assert names == ["studio_status", "studio_events", "studio_run"]
    assert {t.name for t in await m.list_tools()} == set(names)
    res = await m.call_tool("studio_status", {})
    text = "\n".join(getattr(c, "text", "") for c in (res.content if hasattr(res, "content") else res[0]))
    assert "bridge not running" in text


async def test_mcp_tools_against_a_live_bridge(server):
    from mcp.server.mcpserver import MCPServer
    bridge, port, _ = server
    FakePlugin(port).start()
    m = MCPServer("t")
    fb.register(m, port=port)

    async def call(name, args):
        import forge.bridge as mod
        orig = mod.load_token
        mod.load_token = lambda *a, **k: TOKEN
        try:
            res = await m.call_tool(name, args)
        finally:
            mod.load_token = orig
        return "\n".join(getattr(c, "text", "") for c in (res.content if hasattr(res, "content") else res[0]))
    assert '"connected": true' in await call("studio_status", {})
    assert (await call("studio_run", {"code": "return 6 * 7"})).splitlines()[1] == "42"
    ev = await call("studio_events", {"since": 0})
    assert "session" in ev and "next=" in ev


# ---------------------------------------------------------------- forge/studio.py fast path


def _studio(monkeypatch, client):
    from forge import studio as fs
    s = fs.Studio.__new__(fs.Studio)
    s._session, s.studio_id, s.studio_name, s.call_timeout = object(), "id", "Forge-agents-25.rbxlx", 5
    import io
    s._errlog = io.StringIO()
    monkeypatch.setattr(fb, "connected_client", lambda place, dm, port=None: client)
    called = []

    async def call(tool, **args):
        called.append(tool)
        return "via-mcp"
    s.call = call
    return s, called


def test_execute_luau_uses_bridge_when_connected(monkeypatch):
    class C:
        def luau(self, code, dm, timeout):
            return f"bridge:{dm}:{code}"
    s, called = _studio(monkeypatch, C())
    assert asyncio.run(s.execute_luau("return 1", "Server")) == "bridge:Server:return 1"
    assert called == []


def test_execute_luau_luau_errors_raise_and_bridge_errors_fall_back(monkeypatch):
    from forge.studio import StudioError

    class Bad:
        def luau(self, *a):
            raise fb.LuauError("syntax")
    s, _ = _studio(monkeypatch, Bad())
    with pytest.raises(StudioError, match="syntax"):
        asyncio.run(s.execute_luau("return (", "Edit"))

    class Down:
        def luau(self, *a):
            raise fb.BridgeError("bridge not reachable")
    s, called = _studio(monkeypatch, Down())
    assert asyncio.run(s.execute_luau("return 1")) == "via-mcp" and called == ["execute_luau"]


def test_execute_luau_without_bridge_uses_mcp(monkeypatch):
    s, called = _studio(monkeypatch, None)
    assert asyncio.run(s.execute_luau("return 1")) == "via-mcp"


def test_place_allowed_prefix_patterns():
    from forge.bridge import place_allowed

    places = {"firefighter mubit", "forge*"}
    assert place_allowed("Firefighter Mubit", places)
    assert place_allowed("Forge.rbxlx", places)
    assert place_allowed("Forge-agents-27.rbxlx", places)
    assert not place_allowed("Some Other Game", places)
    assert not place_allowed("firefighter mubit 2", {"firefighter mubit"})
