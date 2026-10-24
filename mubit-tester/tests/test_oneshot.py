"""One-shot tester tools against a fake Studio: test_feature (plan, run, verdict, record, stop),
diff_since_last_run, test_runs, watch_errors, bisect_versions (real GameVersions repo, fake runner),
the swarm wrapper, screenshot focus, sync guard, and the extension hook."""

from __future__ import annotations

import contextlib
import dataclasses
import json
import sys
import types
from pathlib import Path

import pytest
from mcp.server.mcpserver.exceptions import ToolError

from forge.config import load_settings
from forge.versions import GameVersions
from mubit_tester import bisect as bs
from mubit_tester import server as ms
from mubit_tester import testrun
from test_harness import PLAYERS, FakeStudio


def _text(result) -> str:
    return "\n".join(getattr(c, "text", "") for c in result.content)


class OneShotStudio(FakeStudio):
    """FakeStudio plus executable checks, ForgeProbe errors, screenshots and sync."""

    def __init__(self, handlers, check_results=None, probe_errors=None, **kw):
        super().__init__(handlers, **kw)
        self.check_results = check_results or {}
        self.probe_errors = probe_errors if probe_errors is not None else []
        self.synced: list[tuple[Path, int, bool]] = []
        self.shots: list[Path] = []
        self.names = {"fake-studio": "Forge-agents-24.rbxlx"}

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        if "__http" in code:  # an executable check
            for marker, (ok, detail) in self.check_results.items():
                if marker in code:
                    return json.dumps({"ok": ok, "detail": detail})
            return json.dumps({"ok": False, "detail": "no fake result"})
        return await super().execute_luau(code, datamodel, timeout)

    async def probe_report(self):
        errs = self.probe_errors() if callable(self.probe_errors) else self.probe_errors
        return {"errors": errs, "warnings": []}

    async def screenshot(self, out, camera=None, look_at=None):
        out = Path(out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(b"\x89PNG\r\n\x1a\n" + b"0" * 32)
        self.shots.append(out)
        self.last_camera = (camera, look_at)
        return out

    async def sync(self, root, port=None, prune=True):
        self.synced.append((Path(root), port, prune))
        return "OK 3 files"

    async def list_studios(self):
        return [{"id": k, "name": v} for k, v in self.names.items()]


@pytest.fixture
def env(tmp_path, monkeypatch):
    """Settings rooted in tmp: a scenarios dir, a Forge game with versions and checks, game/."""
    base = load_settings()
    s = dataclasses.replace(base, repo_root=tmp_path, runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game")
    (tmp_path / "game").mkdir()
    (tmp_path / "game" / "Main.server.luau").write_text("print('hi')\n")
    sc = tmp_path / "mubit-tester" / "scenarios"
    sc.mkdir(parents=True)
    (sc / "smoke.json").write_text(json.dumps({"name": "smoke", "description": "players spawn", "steps": [
        {"assert": {"cmd": "players", "path": "result.*.health", "op": ">", "value": 0}}]}))
    (sc / "hydrant_refill.json").write_text(json.dumps({"name": "hydrant_refill",
        "description": "refill the hose water at a hydrant", "steps": [
            {"assert": {"cmd": "counters", "path": "result.refills", "op": ">=", "value": 1}}]}))
    (sc / "lobby_countdown.json").write_text(json.dumps({"name": "lobby_countdown",
        "description": "squad pad countdown launches a mission", "steps": [
            {"assert": {"cmd": "players", "path": "result.*.health", "op": ">", "value": 0}}]}))
    game = s.runs_dir / "tycoon" / "game"
    game.mkdir(parents=True)
    (game / "Shop.server.luau").write_text("-- v1\n")
    checks = s.runs_dir / "tycoon" / "checks"
    checks.mkdir(parents=True)
    (checks / "buy-dropper.luau").write_text("-- check: buying a dropper costs 25\n-- covers: shop\n"
                                             "local marker = 'BUY_DROPPER'\nreturn { ok = true, detail = '' }\n")
    monkeypatch.setattr(ms, "load_settings", lambda: s)
    monkeypatch.setattr(ms, "STATE", {"studio_id": None, "hint": None, "mode": "server", "clients": []})
    monkeypatch.setattr(ms, "_free_port", lambda p: p)
    from forge import sync as fsync
    monkeypatch.setattr(fsync, "check", lambda root: [])
    return s


def _studio(monkeypatch, **kw) -> OneShotStudio:
    handlers = {"players": lambda a: PLAYERS, "counters": lambda a: {"refills": kw.pop("refills", 1)},
                "events": lambda a: {"now": 5.0, "events": []}, "inspect": lambda a: {"pos": [10, 2, 30]}}
    st = OneShotStudio(handlers, **kw)

    @contextlib.asynccontextmanager
    async def opener(select: bool = True):
        yield st
    monkeypatch.setattr(ms, "open_studio", opener)
    return st


def _fake_ai(goal_met=True, bugs=None):
    ai = types.ModuleType("fake_ai")
    ai.calls = []

    async def multi_playtest(settings, goal, players=None, steps=20, roles=None, *, studio=None, harness=None, **kw):
        ai.calls.append((goal, players, steps))
        return {"run_id": "pt-1", "goal": goal, "goal_met": goal_met, "summary": "judge says so", "bugs": bugs or []}
    ai.multi_playtest = multi_playtest
    return ai


# ---------------------------------------------------------------- planning + verdict (pure)

def test_plan_picks_smoke_and_matching_scenarios():
    scs = [{"name": "smoke", "description": ""}, {"name": "hydrant_refill", "description": "refill the hose at a hydrant"},
           {"name": "lobby_countdown", "description": "squad pad countdown"}]
    p = testrun.plan("Refilling the hose at a hydrant restores water", scs, [])
    assert p["scenarios"] == ["smoke", "hydrant_refill"] and p["playtest"]
    assert "hydrant_refill" in p["why"]
    p = testrun.plan("x", scs, [], playtest=False, only_scenarios=["lobby_countdown", "nope"])
    assert p["scenarios"] == ["lobby_countdown"] and p["why"]["missing"] == "nope" and p["playtest"] is None


def test_verdict_rules():
    ok_sc = {"name": "smoke", "passed": True}
    assert testrun.verdict({"scenarios": [ok_sc]})[0] == "PASS"
    assert testrun.verdict({"scenarios": [ok_sc], "checks": [{"id": "c", "ok": False}]})[0] == "FAIL"
    assert testrun.verdict({"scenarios": [ok_sc], "errors": {"errors": ["boom"]}})[0] == "ERRORS"
    assert testrun.verdict({"scenarios": [{"name": "x", "passed": None, "skipped": True}]})[0] == "INCONCLUSIVE"
    assert testrun.verdict({"playtest": {"goal_met": False}})[0] == "FAIL"


# ---------------------------------------------------------------- test_feature

async def test_test_feature_end_to_end(env, monkeypatch):
    st = _studio(monkeypatch, playing=False, check_results={"BUY_DROPPER": (True, "cash 100 -> 75")})
    ai = _fake_ai(goal_met=True)
    monkeypatch.setattr(ms, "_ai", lambda: ai)
    res = await ms.mcp.call_tool("test_feature", {"description": "refill the hose at a hydrant", "game": "tycoon",
                                                  "checks": True, "steps": 4})
    md = _text(res)
    first = md.splitlines()[0]
    assert first == "## PASS: refill the hose at a hydrant"            # verdict first
    assert "| scenario | smoke | PASS |" in md and "| scenario | hydrant_refill | PASS |" in md
    assert "| check | buy-dropper | PASS |" in md and "| AI playtest | pt-1 | PASS |" in md
    assert any(getattr(c, "type", "") == "image" for c in res.content)  # screenshot returned as an image
    assert st.synced and st.synced[0][0] == env.runs_dir / "tycoon" / "game"
    assert st.played == 1 and st.stopped >= 1 and not st.playing      # always stops play
    assert ai.calls == [("refill the hose at a hydrant", None, 4)]
    rec = testrun.load_records(env)[-1]
    assert rec["verdict"][0] == "PASS" and rec["manifest"] == {"Shop.server.luau": rec["manifest"]["Shop.server.luau"]}
    assert Path(rec["dir"], "report.md").exists() and Path(rec["screenshot"]).exists()
    assert [s["stage"] for s in rec["stages"]][:2] == ["sync", "play"]
    # the check run is the game's latest one: forge done's checks part reads it
    from forge.done import _checks
    assert _checks(env.runs_dir / "tycoon") == {"part": "checks", "ok": True, "detail": "1/1 pass"}


async def test_test_feature_fail_has_next_step_and_no_llm_when_asked(env, monkeypatch):
    _studio(monkeypatch, check_results={"BUY_DROPPER": (False, "cash 100 -> 100")},
            probe_errors=[{"message": "Shop:12 attempt to index nil", "count": 2, "script": "Shop"}])
    monkeypatch.setattr(ms, "_ai", lambda: pytest.fail("playtest=false must not load the AI"))
    md = _text(await ms.mcp.call_tool("test_feature", {"description": "buy a dropper", "game": "tycoon",
                                                       "playtest": False, "screenshot": False}))
    assert md.startswith("## FAIL: buy a dropper") and "check buy-dropper" in md.splitlines()[1]
    assert "**Next:**" in md and "cash 100 -> 100" in md and "Shop:12 attempt to index nil" in md


async def test_test_feature_sync_failure_is_a_verdict_not_a_crash(env, monkeypatch):
    st = _studio(monkeypatch)
    from forge import sync as fsync
    monkeypatch.setattr(fsync, "check", lambda root: [(Path("Main.server.luau"), "syntax error near end")])
    md = _text(await ms.mcp.call_tool("test_feature", {"description": "anything", "playtest": False}))
    assert md.startswith("## FAIL") and "sync failed" in md and "syntax error" in md
    assert st.played == 0


async def test_diff_since_last_run_and_test_runs(env, monkeypatch):
    st = _studio(monkeypatch, check_results={"BUY_DROPPER": (False, "no dropper")},
                 probe_errors=[{"message": "Shop:12 nil", "count": 1}])
    args = {"description": "buy a dropper", "game": "tycoon", "playtest": False, "screenshot": False}
    await ms.mcp.call_tool("test_feature", args)
    assert "nothing to compare" in _text(await ms.mcp.call_tool("diff_since_last_run", {}))
    # fix the code, rerun
    (env.runs_dir / "tycoon" / "game" / "Shop.server.luau").write_text("-- v2 fixed\n")
    st.check_results = {"BUY_DROPPER": (True, "cash 100 -> 75")}
    st.probe_errors = []
    import time as _t
    _t.sleep(1.1)  # record ids/started are per second
    await ms.mcp.call_tool("test_feature", args)
    md = _text(await ms.mcp.call_tool("diff_since_last_run", {}))
    assert md.splitlines()[0].startswith("## FAIL -> PASS (better): 1 fixed, 0 regressed, 0 new error(s), 1 file(s) changed")
    assert "| check buy-dropper | FAIL | PASS |" in md and "Shop:12 nil" in md and "changed `Shop.server.luau`" in md
    runs = _text(await ms.mcp.call_tool("test_runs", {}))
    assert runs.index("PASS") < runs.index("FAIL")  # newest first


# ---------------------------------------------------------------- watch_errors

async def test_watch_errors_reports_only_new(env, monkeypatch):
    seq = iter([
        [{"message": "old error", "count": 3}],
        [{"message": "old error", "count": 3}],
        [{"message": "old error", "count": 4}, {"message": "Hose:40 nil water", "count": 1, "trace": "Hose:40"}],
    ])
    last = {"v": []}

    def errs():
        last["v"] = next(seq, last["v"])
        return last["v"]
    _studio(monkeypatch, probe_errors=errs)
    md = _text(await ms.mcp.call_tool("watch_errors", {"seconds": 1.2, "poll": 0.5}))
    assert md.startswith("## 2 new script error(s)") and "Hose:40 nil water" in md and "old error** x1" in md


async def test_watch_errors_needs_play(env, monkeypatch):
    st = _studio(monkeypatch)

    async def broken():
        return {"error": "no Server datamodel"}
    st.probe_report = broken
    with pytest.raises(ToolError, match="play_start"):
        await ms.mcp.call_tool("watch_errors", {"seconds": 1})


# ---------------------------------------------------------------- bisect

def _versions(tmp_path, n=6, broken_from=4) -> Path:
    game = tmp_path / "g" / "game"
    game.mkdir(parents=True)
    gv = GameVersions(game)
    for i in range(1, n + 1):
        (game / "Shop.server.luau").write_text(f"-- v{i}\nlocal price = {25 if i < broken_from else 0}\n")
        gv.snapshot(f"iteration {i}")
    return game


async def test_bisect_finds_first_bad(tmp_path):
    game = _versions(tmp_path, n=8, broken_from=5)
    seen = []

    async def run_at(folder: Path):
        text = (folder / "Shop.server.luau").read_text()
        seen.append(text.splitlines()[0])
        return "price = 25" in text, text.splitlines()[0]
    res = await bs.bisect(game, GameVersions(game).tags(), run_at)
    assert res["first_bad"] == "v5" and res["last_good"] == "v4"
    assert len(seen) <= 5  # ends + log2(8)
    assert GameVersions(game).current() == "v8" and "v8" in (game / "Shop.server.luau").read_text()  # untouched
    md = bs.format_bisect(res, GameVersions(game).log(), ["Shop.server.luau"])
    assert md.startswith("## v5 broke it (last good v4)") and "iteration 5" in md


async def test_bisect_edge_cases(tmp_path):
    game = _versions(tmp_path, n=3, broken_from=99)

    async def always(folder):
        return True, "ok"
    res = await bs.bisect(game, GameVersions(game).tags(), always)
    assert res["first_bad"] is None and "nothing to bisect" in res["note"]
    with pytest.raises(bs.BisectError, match="at least 2"):
        await bs.bisect(game, ["v1"], always)
    with pytest.raises(bs.BisectError, match="older"):
        await bs.bisect(game, GameVersions(game).tags(), always, good="v3", bad="v1")


async def test_bisect_versions_tool(env, monkeypatch):
    game = env.runs_dir / "tycoon" / "game"
    gv = GameVersions(game)
    for i in range(1, 5):
        (game / "Shop.server.luau").write_text(f"-- v{i}\n" + ("local marker = 'GOOD'\n" if i < 3 else ""))
        gv.snapshot(f"iteration {i}")
    st = _studio(monkeypatch)
    # the check passes iff the synced version still has the GOOD marker
    orig_sync = st.sync

    async def sync(root, port=None, prune=True):
        st.check_results = {"BUY_DROPPER": ("GOOD" in (Path(root) / "Shop.server.luau").read_text(), str(root))}
        return await orig_sync(root, port, prune)
    st.sync = sync
    md = _text(await ms.mcp.call_tool("bisect_versions", {"game": "tycoon", "check": "buy-dropper"}))
    assert md.startswith("## v3 broke it (last good v2)") and "`Shop.server.luau`" in md
    assert st.synced[-1][0] == game and st.synced[-1][2] is True  # current version re-synced, pruned
    assert not st.playing
    with pytest.raises(ToolError, match="not a Forge game"):
        await ms.mcp.call_tool("bisect_versions", {"game": str(env.base_game_dir), "check": "x"})


# ---------------------------------------------------------------- swarm, screenshot, sync, extensions

async def test_swarm_wrapper(env, monkeypatch):
    monkeypatch.delitem(sys.modules, "mubit_tester.swarm", raising=False)
    with pytest.raises(ToolError, match="isn't in this checkout"):
        await ms.mcp.call_tool("swarm", {"goal": "x"})
    mod = types.ModuleType("mubit_tester.swarm")
    got = {}

    async def run_swarm(settings, goal, testers=10, progress=None):
        got.update(goal=goal, testers=testers)
        await progress("tester 1 done")
        return {"verdict": "FAIL", "bugs": 2}
    mod.run_swarm = run_swarm
    mod.format_swarm = lambda r: f"## {r['verdict']}: {r['bugs']} bugs"
    monkeypatch.setitem(sys.modules, "mubit_tester.swarm", mod)
    md = _text(await ms.mcp.call_tool("swarm", {"goal": "put out fires", "testers": 3}))
    assert md == "## FAIL: 2 bugs" and got == {"goal": "put out fires", "testers": 3}


async def test_screenshot_focus_and_query_table(env, monkeypatch):
    st = _studio(monkeypatch)
    res = await ms.mcp.call_tool("screenshot", {"focus": "2"})
    assert "saved `" in _text(res) and any(getattr(c, "type", "") == "image" for c in res.content)
    cam, look = st.last_camera
    assert look == [5, 3, 0] and cam[1] > look[1]           # framed from above player 2
    res = await ms.mcp.call_tool("screenshot", {"focus": "Workspace.Map.Shop"})
    assert st.last_camera[1] == [10, 2, 30]


async def test_sync_tool_guards_shared_place_and_takes_a_game(env, monkeypatch):
    st = _studio(monkeypatch)
    md = _text(await ms.mcp.call_tool("sync", {"game": "tycoon", "prune": True}))
    assert "synced" in md and st.synced[-1][0] == env.runs_dir / "tycoon" / "game" and st.synced[-1][2]
    st.names = {"fake-studio": "Firefighter Mubit (placeId: 1301)"}
    with pytest.raises(ToolError, match="shared Team Create"):
        await ms.mcp.call_tool("sync", {})
    with pytest.raises(ToolError, match="no game 'nope'"):
        await ms.mcp.call_tool("sync", {"game": "nope"})


def test_free_port_moves_off_a_busy_port():
    import socket
    from mubit_tester.server import _free_port
    with socket.socket() as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        port = busy.getsockname()[1]
        assert _free_port(port) != port


async def test_extensions_register_tools(monkeypatch):
    mod = types.ModuleType("fake_bridge_ext")

    def register(mcp):
        @mcp.tool()
        def bridge_ping() -> str:
            """Ping the Studio plugin bridge."""
            return "pong"
    mod.register = register
    monkeypatch.setitem(sys.modules, "fake_bridge_ext", mod)
    monkeypatch.setattr(ms, "LOADED_EXTENSIONS", [])
    assert ms.load_extensions(["fake_bridge_ext", "no_such_module_xyz"]) == ["fake_bridge_ext"]
    assert _text(await ms.mcp.call_tool("bridge_ping", {})) == "pong"
    ms.mcp.remove_tool("bridge_ping")
