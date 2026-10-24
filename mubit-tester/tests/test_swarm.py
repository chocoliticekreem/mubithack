"""Swarm testing: personas -> real/bot testers, the multiplexed harness, per-tester cameras, bounded
LLM concurrency, dedup + severity x frequency ranking, and the `swarm` MCP tool (FakeLLM only)."""

from __future__ import annotations

import asyncio
import json
import threading
import time
from pathlib import Path

import pytest

from forge.config import Settings
from forge.llm import FakeLLM
from mubit_tester import play
from mubit_tester import server as ms
from mubit_tester import swarm as sw
from mubit_tester.harness import HarnessError
from test_harness import decode_call


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        mubit_api_key=None, provider="anthropic", base_url="https://api.mubit.ai/anthropic",
        model="claude-sonnet-5", studio_mcp_path="", sync_port=34873, repo_root=tmp_path,
        runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game",
    )


class SwarmWorld:
    """The in-game harness as the swarm sees it: one real player, bots from bot_spawn, `multi`."""

    def __init__(self, real: int = 1, multi: bool = True, delay: float = 0.0):
        self.players = [{"userId": 100 + i, "name": f"Player{i}", "pos": [i * 3.0, 3.0, 0.0]}
                        for i in range(1, real + 1)]
        self.bots: list[dict] = []
        self.multi = multi
        self.delay = delay
        self.calls: list[tuple[str, dict]] = []
        self.batches: list[int] = []
        self.spawned: list[dict] = []
        self.cleared = 0
        self.t = 0.0

    def who(self, uid) -> dict:
        for p in self.players + self.bots:
            if str(uid) in (str(p["userId"]), p["name"]):
                return p
        raise RuntimeError(f"no player {uid}")

    def run(self, cmd: str, args: dict):
        self.calls.append((cmd, args))
        if cmd == "ping":
            return {"version": "2", "players": len(self.players), "session": "s1"}
        if cmd == "players":
            return [dict(p) for p in self.players]
        if cmd == "bot_spawn":
            self.spawned.append(args)
            for i, name in enumerate(args["names"]):
                if any(b["name"] == name for b in self.bots):
                    raise RuntimeError(f"a bot named {name} already exists (bot_clear first)")
                self.bots.append({"userId": -(1001 + len(self.bots)), "name": name, "pos": [10.0 + i, 3.0, 5.0],
                                  "bot": True})
            return [dict(b) for b in self.bots]
        if cmd == "bot_clear":
            self.cleared += 1
            n = len(self.bots)
            self.bots = []
            return {"removed": n}
        if cmd == "observe":
            p = self.who(args["userId"])
            obs = {"me": {"userId": p["userId"], "name": p["name"], "pos": p["pos"], "health": 100},
                   "world": {}, "things": [], "prompts": [], "touchables": [
                       {"name": "DropperButton", "path": "Workspace.Plot1.DropperButton", "dist": 8, "touch": True}]}
            if p.get("bot"):
                obs["me"]["bot"] = True
            else:
                obs["ui"] = [{"text": "Shop", "path": "Hud.Shop", "x": 20, "y": 20, "w": 30, "h": 30},
                             {"text": "Sell", "path": "Hud.Sell", "x": 35, "y": 20, "w": 30, "h": 30}]
                obs["hud"] = ["Cash: 3"]
            return obs
        if cmd == "act":
            p = self.who(args["userId"])
            if args["action"] == "walk_to" and isinstance(args["args"].get("pos"), list):
                p["pos"] = args["args"]["pos"]
            return {"done": True, "detail": f"{args['action']} ok"}
        if cmd == "events":
            self.t += 1
            return {"now": self.t, "events": [{"t": self.t, "kind": "counter", "data": {"name": "cubes_dropped"}}]}
        if cmd == "counters":
            return {"cubes_dropped": int(self.t)}
        raise RuntimeError(f"unknown command '{cmd}'")


class SwarmStudio:
    def __init__(self, world: SwarmWorld):
        self.world = world
        self.studio_id = "fake-swarm"
        self.shots: list[tuple[str, list, list]] = []
        self.luau_calls = 0
        self.stopped = 0

    async def execute_luau(self, code: str, datamodel: str = "Edit", timeout=None) -> str:
        self.luau_calls += 1
        if "ForgeProbe" in code:
            return json.dumps({"errors": [], "warnings": [], "counters": {}, "instances": 120})
        cmd, args = decode_call(code)
        if self.world.delay:
            await asyncio.sleep(self.world.delay)
        if cmd == "multi":
            if not self.world.multi:
                return json.dumps({"ok": False, "error": "unknown command 'multi' (one of: act, observe)"})
            self.world.batches.append(len(args["calls"]))
            out = []
            for c in args["calls"]:
                try:
                    out.append({"ok": True, "result": self.world.run(c["cmd"], c.get("args") or {})})
                except Exception as e:  # noqa: BLE001
                    out.append({"ok": False, "error": str(e)})
            return json.dumps({"ok": True, "result": out})
        try:
            return json.dumps({"ok": True, "result": self.world.run(cmd, args)})
        except Exception as e:  # noqa: BLE001
            return json.dumps({"ok": False, "error": str(e)})

    async def state(self) -> dict:
        return {"playing": True}

    async def call(self, tool: str, **kw):
        raise RuntimeError("no Client datamodel")

    async def probe_report(self) -> dict:
        return {"errors": [], "warnings": [], "counters": {}, "instances": 120}

    async def screenshot(self, out: Path, camera=None, look_at=None):
        self.shots.append((Path(out).name, list(camera), list(look_at)))
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        Path(out).write_bytes(b"\x89PNG fake")
        return Path(out)

    async def stop(self) -> None:
        self.stopped += 1


# --------------------------------------------------------------------------- roster


def test_personas_and_real_player_priority():
    personas = sw.pick_personas(10)
    assert [p["key"] for p in personas] == sw.PERSONA_KEYS
    assert len(set(sw.PERSONA_KEYS)) == 10
    testers = sw.assign_testers(personas, [{"userId": 7, "name": "Alice"}, {"userId": 8, "name": "Bob"}])
    real = {t["key"]: t["name"] for t in testers if t["real"]}
    assert real == {"ui_clicker": "Alice", "accessibility": "Bob"}  # screen-first personas get real players
    bots = [t for t in testers if not t["real"]]
    assert len(bots) == 8 and all(t["name"].startswith("Swarm_") for t in bots)
    assert len({t["name"] for t in testers}) == 10
    coop = next(t for t in testers if t["key"] == "coop")
    assert coop["partner"] in {t["name"] for t in testers} and coop["partner"] != coop["name"]


def test_pick_personas_cycles_and_validates():
    twelve = sw.pick_personas(12)
    assert twelve[10]["key"] == "speedrunner2" and twelve[11]["label"] == "Griefer #2"
    assert [p["key"] for p in sw.pick_personas(2, ["griefer", "soak"])] == ["griefer", "soak"]
    with pytest.raises(ValueError):
        sw.pick_personas(1, ["nope"])


def test_camera_aims_at_each_tester():
    cam0, look0 = sw.camera_for([10, 3, -4], 0)
    cam1, _ = sw.camera_for([10, 3, -4], 1)
    assert look0 == [10.0, 4.5, -4.0]
    assert cam0 != cam1
    d = ((cam0[0] - 10) ** 2 + (cam0[2] + 4) ** 2) ** 0.5
    assert abs(d - 16) < 0.01 and cam0[1] == 12.0


def test_layout_facts_flags_small_overlapping_offscreen():
    facts = sw.layout_facts({"ui": [{"text": "A", "x": 10, "y": 20, "w": 30, "h": 30},
                                    {"text": "B", "x": 35, "y": 20, "w": 30, "h": 30},
                                    {"text": "C", "x": 300, "y": 300, "w": 100, "h": 60}]})
    assert [s["button"] for s in facts["small_touch_targets"]] == ["A", "B"]
    assert facts["overlapping"] == [["A", "B"]]
    assert facts["partly_offscreen"] == ["A"]


# --------------------------------------------------------------------------- aggregation


def _rep(title, tester, sev="medium", evidence="", real=True, step=1):
    return {"title": title, "evidence": evidence, "severity": sev, "tester": tester,
            "persona": tester.lower(), "real": real, "step": step}


def test_cluster_dedupes_same_bug_across_testers():
    reports = [
        _rep("Dropper buy pad takes no cash", "Economy", "high"),
        _rep("Dropper buy pad takes no cash at all", "Speedrunner", "medium"),
        _rep("buy pad dropper takes no cash", "Newbie", "low"),
        _rep("Player falls through baseplate edge", "Edge", "high"),
        _rep("Cubes pile up on conveyor", "Soak", "low", evidence="Workspace.Plot1.Conveyor has 40 cubes"),
        _rep("Conveyor cubes keep piling", "Physics", "low", evidence="stood on Workspace.Plot1.Conveyor"),
    ]
    groups = sw.cluster_reports(reports)
    assert len(groups) == 3
    buy = groups[0]
    assert buy["frequency"] == 3 and buy["severity"] == "high"
    bugs = sw.rank_bugs(groups)
    assert [b["score"] for b in bugs] == [9, 3, 2]  # high x 3 testers, high x 1, low x 2
    assert bugs[0]["title"].startswith("Dropper buy pad")
    assert set(bugs[0]["testers"]) == {"Economy", "Speedrunner", "Newbie"}
    assert bugs[2]["frequency"] == 2


def test_triage_merges_and_flags_not_real():
    groups = sw.cluster_reports([
        _rep("Buy pad does nothing", "Economy", "medium"),
        _rep("Dropper purchase fails with 30 cash", "Speedrunner", "medium"),
        _rep("Bot can't earn money", "Swarm_Griefer", "high", real=False),
        _rep("Respawn drops you off the map", "Edge", "low"),
    ])
    assert len(groups) == 4
    verdict = {"groups": [{"ids": [1, 2], "title": "Dropper buy pad ignores purchases", "severity": "high"},
                          {"ids": [3], "title": "Bot money", "severity": "low", "real": False},
                          {"ids": [99, "x"]}]}
    merged = sw.apply_triage(groups, verdict)
    assert len(merged) == 3
    bugs = sw.rank_bugs(merged)
    assert bugs[0]["title"] == "Dropper buy pad ignores purchases"
    assert bugs[0]["frequency"] == 2 and bugs[0]["score"] == 6
    assert bugs[-1]["real"] is False and bugs[-1]["score"] == 0
    assert sw.apply_triage(groups, {"groups": "garbage"}) == groups


# --------------------------------------------------------------------------- multiplexing


async def test_mux_batches_concurrent_calls_into_one_multi():
    world = SwarmWorld(real=1)
    world.bots = [{"userId": -1001, "name": "B1", "pos": [0, 3, 0], "bot": True},
                  {"userId": -1002, "name": "B2", "pos": [0, 3, 0], "bot": True}]
    studio = SwarmStudio(world)
    h = sw.MuxHarness(studio)
    obs = await asyncio.gather(*(h.observe(u) for u in (101, -1001, -1002)))
    assert [o["me"]["name"] for o in obs] == ["Player1", "B1", "B2"]
    assert world.batches == [3] and studio.luau_calls == 1
    # acts batch per action kind: two walks share one call, the jump goes on its own
    res = await asyncio.gather(h.act(-1001, "walk_to", pos=[1, 3, 1]), h.act(-1002, "walk_to", pos=[2, 3, 2]),
                               h.act(101, "jump"))
    assert all(r["done"] for r in res)
    assert sorted(world.batches[1:]) == [1, 2] or sorted(world.batches[1:]) == [2]
    assert h.stats["calls"] == 6 and h.stats["max_batch"] == 3
    # one failing sub-call fails only its own caller
    ok, bad = await asyncio.gather(h.observe(101), h.observe("ghost"), return_exceptions=True)
    assert ok["me"]["name"] == "Player1" and isinstance(bad, HarnessError)


async def test_mux_falls_back_without_multi():
    world = SwarmWorld(real=1, multi=False)
    world.bots = [{"userId": -1001, "name": "B1", "pos": [0, 3, 0], "bot": True}]
    h = sw.MuxHarness(SwarmStudio(world))
    a, b = await asyncio.gather(h.observe(101), h.observe(-1001))
    assert a["me"]["name"] == "Player1" and b["me"]["name"] == "B1"
    assert h.multi_ok is False
    await asyncio.gather(h.observe(101), h.observe(-1001))
    assert [c for c, _ in world.calls].count("observe") == 4


# --------------------------------------------------------------------------- the whole swarm


class CountingLLM(FakeLLM):
    """FakeLLM that records peak concurrency and replies per persona."""

    def __init__(self):
        super().__init__({}, default=self.reply)
        self.active = 0
        self.peak = 0
        self.lock = threading.Lock()

    def complete(self, role, user, *, session_id, max_tokens=4096):
        with self.lock:
            self.active += 1
            self.peak = max(self.peak, self.active)
        try:
            time.sleep(0.02)
            return super().complete(role, user, session_id=session_id, max_tokens=max_tokens)
        finally:
            with self.lock:
                self.active -= 1

    @staticmethod
    def reply(role, user):
        if role == "swarm_triage":
            return json.dumps({"groups": [{"ids": [1], "title": "Dropper buy pad takes no cash", "severity": "high"}]})
        persona = user.split("## Persona\n", 1)[1].split(":", 1)[0]
        step = int(user.split("## Step\n", 1)[1].split(" ", 1)[0])
        if step >= 3:
            return json.dumps({"action": "done", "args": {}, "reason": "enough"})
        bug = None
        if step == 2 and persona in ("Economy exploiter", "Speedrunner", "Confused new player"):
            bug = {"title": "Dropper buy pad takes no cash", "evidence": f"{persona}: touched pad, Cash 30 -> 30",
                   "severity": "high" if persona == "Economy exploiter" else "medium"}
        return json.dumps({"action": "move_to", "args": {"x": step, "y": 3, "z": step},
                           "reason": "probe", "bug": bug})


async def test_swarm_runs_ten_testers_concurrently(tmp_path):
    world = SwarmWorld(real=1)
    studio = SwarmStudio(world)
    llm = CountingLLM()
    rep = await sw.run_swarm(_settings(tmp_path), players=10, minutes=1, pool=4, llm=llm, studio=studio,
                             shot_every=2, slug="tiny")
    assert rep["errors"] == []
    # 1 real player (UI clicker) + 9 bots spawned in one call, cleared at the end
    assert len(world.spawned) == 1 and len(world.spawned[0]["names"]) == 9
    assert len(world.spawned[0]["colors"]) == 9 and world.cleared == 1
    real = [t for t in rep["testers"] if t["real"]]
    assert [t["key"] for t in real] == ["ui_clicker"] and real[0]["name"] == "Player1"
    # every tester acted; LLM concurrency stayed within the pool and went above 1
    assert {t["name"]: t["steps"] for t in rep["testers"]} == {t["name"]: 3 for t in rep["testers"]}
    assert 1 < llm.peak <= 4
    tester_calls = [c for c in llm.calls if c.role == "swarm_tester"]
    assert len(tester_calls) == 30 and all(c.session_id == "swarm-" + rep["run_id"] for c in tester_calls)
    assert "bot tester" in next(c.user for c in tester_calls if "Swarm_Griefer" in c.user)
    assert "Layout facts" in next(c.user for c in tester_calls if "## Persona\nAccessibility" in c.user)
    # the harness multiplexed: far fewer execute_luau round trips than harness calls
    assert rep["mux"]["max_batch"] > 1 and rep["mux"]["round_trips"] < rep["mux"]["calls"]
    # per-tester screenshots, camera aimed at that tester's character
    shot_names = {s[0].split("-step")[0] for s in studio.shots}
    assert shot_names == set(sw.PERSONA_KEYS)
    for name, cam, look in studio.shots:  # every tester walked to (step, 3, step) before its shot
        step = int(name.split("-step")[1].split("-")[0].split(".")[0])
        assert look == [float(step), 4.5, float(step)] and cam != look
    assert any("-bug" in s[0] for s in studio.shots)
    # the same bug from 3 testers -> one ranked bug, severity x frequency
    assert len(rep["bug_reports"]) == 3 and rep["clusters"] == 1
    assert len(rep["bugs"]) == 1
    bug = rep["bugs"][0]
    assert bug["frequency"] == 3 and bug["severity"] == "high" and bug["score"] == 9
    assert set(bug["personas"]) == {"economy", "speedrunner", "newbie"}
    assert bug["shots"] and all(s.startswith("shots/") for s in bug["shots"])
    assert rep["soak"] and rep["timing"]["wall_s"] > 0
    saved = play.load_report(_settings(tmp_path), rep["run_id"])
    assert saved["kind"] == "swarm" and saved["bugs"][0]["title"] == bug["title"]
    text = sw.format_swarm(rep)
    assert "Swarm" in text and "Dropper buy pad takes no cash" in text and "| 0 | 9 | high | 3" in text
    # one dashboard lane per tester: runs/<slug>/tests/<run>/{report.json, step-NN.png}
    from forge.dashboard import testers_view
    lanes = testers_view(tmp_path / "runs" / "tiny", "tiny", time.time())
    assert len(lanes) == 10 and all(ln["status"] == "done" and ln["n_steps"] == 3 for ln in lanes)
    assert {ln["label"].split(" (")[0] for ln in lanes} == {p["label"] for p in sw.PERSONAS}
    econ = next(ln for ln in lanes if ln["label"].startswith("Economy"))
    assert econ["failed"] == 1 and econ["passed"] == 2
    assert any(st["shot"] for ln in lanes for st in ln["steps"])
    lane_dir = Path(rep["lanes"][0])
    assert (lane_dir / "step-01.png").is_file() and (lane_dir / "step-02.png").is_file()


async def test_swarm_stops_at_deadline(tmp_path):
    world = SwarmWorld(real=1, delay=0.01)
    studio = SwarmStudio(world)
    llm = FakeLLM({}, default=lambda role, user: json.dumps({"action": "wait", "args": {"seconds": 0.05},
                                                              "reason": "idle"}))
    t0 = time.monotonic()
    rep = await sw.run_swarm(_settings(tmp_path), players=3, minutes=0.01, llm=llm, studio=studio,
                             screenshots=False, triage=False)
    assert time.monotonic() - t0 < 10
    assert rep["bugs"] == [] and all(t["steps"] >= 1 for t in rep["testers"])
    assert len(world.spawned[0]["names"]) == 2


async def test_swarm_reports_old_harness(tmp_path):
    world = SwarmWorld(real=1)
    studio = SwarmStudio(world)
    orig = world.run

    def run(cmd, args):
        if cmd == "bot_spawn":
            raise RuntimeError("unknown command 'bot_spawn' (one of: act)")
        return orig(cmd, args)

    world.run = run
    rep = await sw.run_swarm(_settings(tmp_path), players=3, minutes=0.01, llm=FakeLLM({}), studio=studio,
                             screenshots=False)
    assert any("no bot_spawn" in e for e in rep["errors"])


# --------------------------------------------------------------------------- MCP tool


async def test_swarm_tool_is_registered():
    tools = {t.name: t for t in await ms.mcp.list_tools()}
    assert "swarm" in tools and "swarm" in ms.TOOL_NAMES
    props = tools["swarm"].input_schema["properties"]
    assert {"players", "minutes", "pool", "personas"} <= set(props)
