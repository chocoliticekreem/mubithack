"""Tests for mubit_tester.ai: multi-agent playtests, explore, corrections, fix suggestions."""

from __future__ import annotations

import asyncio
import json
import re
import threading
import time
from pathlib import Path

import pytest

from mubit_tester import play
from forge.config import Settings
from forge.llm import FakeLLM, load_prompt
from mubit_tester import ai

PLAYERS = [
    {"userId": 101, "name": "Alice", "helmet": 1, "pos": [0, 3, 0]},
    {"userId": 102, "name": "Bob", "helmet": 2, "pos": [5, 3, 0]},
    {"userId": 103, "name": "Cara", "helmet": 3, "pos": [9, 3, 0]},
]


def _obs(uid: int) -> dict:
    return {
        "me": {"pos": [uid - 100, 3, 0], "health": 100, "max_health": 100,
               "attrs": {"Water": 40 + uid % 10, "TankSize": 100, "Carrying": False}, "tool": None,
               "backpack": ["Hose", "Axe"]},
        "world": {"RoundState": "Active"},
        "things": [{"name": "Hydrant1", "path": "Workspace.Map.Hydrant1", "tag": "Hydrant", "dist": 12,
                    "pos": [12, 3, 0]}],
        "prompts": [],
        "hud": [f"player {uid}"],
    }


class FakeHarness:
    def __init__(self, players=PLAYERS):
        self._players = players
        self.acts: list[tuple] = []
        self.active = 0
        self.max_active = 0
        self.observed: list = []
        self.ready = 0
        self.event_calls = 0
        self.studio = None

    async def ensure_ready(self, timeout=30):
        self.ready += 1
        return {"ok": True}

    async def players(self):
        return list(self._players)

    async def observe(self, user_id):
        self.observed.append(user_id)
        await asyncio.sleep(0)
        return _obs(user_id)

    async def act(self, user_id, action, **args):
        self.active += 1
        self.max_active = max(self.max_active, self.active)
        await asyncio.sleep(0.02)
        self.active -= 1
        self.acts.append((user_id, action, args))
        return {"done": True, "detail": f"{action} ok"}

    async def events(self, since=None):
        self.event_calls += 1
        n = self.event_calls
        return {"now": n, "events": [{"t": n, "kind": "PromptTriggered", "data": {"n": n}}] if since is not None else []}

    async def counters(self):
        return {"fires_put_out": 1}


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        mubit_api_key=None, provider="anthropic", base_url="https://api.mubit.ai/anthropic",
        model="claude-sonnet-5", studio_mcp_path="", sync_port=34873, repo_root=tmp_path,
        runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game",
    )


def _a(action, args=None, **extra):
    return json.dumps({"action": action, "args": args or {}, "reason": "r", **extra})


JUDGE = json.dumps({"goal_met": True, "summary": "Team put out the fire.",
                    "bugs": [{"title": "Hydrant refill does nothing", "evidence": "step 1 Alice Water stayed 41",
                              "severity": "medium"}]})


class ScriptedLLM(FakeLLM):
    """Per-player scripts keyed by the name in the '## You' section; tracks concurrent calls."""

    def __init__(self, scripts: dict[str, list[str]], judge=JUDGE, delay=0.05, role="player"):
        super().__init__({"judge": [judge]}, default=self._reply)
        self.scripts = {k: list(v) for k, v in scripts.items()}
        self.delay = delay
        self.role = role
        self._lock = threading.Lock()
        self.in_flight = 0
        self.max_in_flight = 0

    def _reply(self, role, user):
        m = re.search(r"## You\n(\w+)", user)
        name = m.group(1) if m else "?"
        with self._lock:
            self.in_flight += 1
            self.max_in_flight = max(self.max_in_flight, self.in_flight)
        time.sleep(self.delay)
        with self._lock:
            self.in_flight -= 1
            q = self.scripts.get(name) or []
            return q.pop(0) if q else _a("done")


def test_explorer_prompt_static_and_registered():
    text = load_prompt("explorer")
    assert len(text) > 500 and "suspected_bug" in text
    assert not re.search(r"\{[a-z_][a-z0-9_]*\}", text)


def test_assign_roles_cycles_defaults_and_custom():
    r = ai.assign_roles(PLAYERS)
    assert [p["role"] for p in r] == ai.DEFAULT_ROLES[:3]
    assert r[0] == {"userId": 101, "name": "Alice", "helmet": 1, "role": ai.DEFAULT_ROLES[0]}
    r2 = ai.assign_roles(PLAYERS, ["a", "b"])
    assert [p["role"] for p in r2] == ["a", "b", "a"]


def test_map_action_vocabulary():
    assert ai.map_action({"action": "move_to", "args": {"x": 1, "y": 2, "z": 3}}) == ("walk_to", {"pos": [1.0, 2.0, 3.0]})
    assert ai.map_action({"action": "move_to_instance", "args": {"path": "Workspace.A"}}) == ("walk_to", {"path": "Workspace.A"})
    assert ai.map_action({"action": "spray", "args": {"target": "Workspace.F", "ms": 2000}}) == \
        ("use", {"seconds": 2.0, "aim": "Workspace.F"})
    assert ai.map_action({"action": "equip", "args": {"slot": 2}}) == ("equip", {"slot": 2})
    assert ai.map_action({"action": "key", "args": {"key": "Space"}}) == ("jump", {})
    assert ai.map_action({"action": "key", "args": {"key": "Q"}}).startswith("unsupported")
    assert ai.map_action({"action": "say", "args": {"text": "hi"}}) == ("say", {"text": "hi"})
    assert ai.map_action({"action": "done"}) == "done"


async def test_multi_playtest_concurrent_ticks_and_report(tmp_path):
    settings = _settings(tmp_path)
    llm = ScriptedLLM({
        "Alice": [_a("move_to_instance", {"path": "Workspace.Map.Hydrant1"}),
                  _a("spray", {"target": "Workspace.Map.House", "ms": 1000},
                     bug={"title": "Fire did not shrink", "evidence": "FL stayed 2", "severity": "medium"}),
                  _a("done")],
        "Bob": [_a("move_to", {"x": 1, "y": 2, "z": 3}), _a("key", {"key": "Q"}), _a("done")],
    })
    h = FakeHarness()
    rep = await ai.multi_playtest(settings, "put out the house fire", players=2, steps=5, llm=llm,
                                  harness=h, step_seconds=0)

    assert h.ready == 1
    assert [p["name"] for p in rep["players"]] == ["Alice", "Bob"]
    assert [p["role"] for p in rep["players"]] == ai.DEFAULT_ROLES[:2]
    # both players decided and acted concurrently in the same tick
    assert llm.max_in_flight == 2
    assert h.max_active == 2
    tick1 = [s for s in rep["steps"] if s["n"] == 1]
    assert sorted(s["player"] for s in tick1) == [101, 102]
    assert {(u, a) for u, a, _ in h.acts if True} >= {(101, "walk_to"), (102, "walk_to")}
    assert (101, "use", {"seconds": 1.0, "aim": "Workspace.Map.House"}) in h.acts
    bob2 = next(s for s in rep["steps"] if s["n"] == 2 and s["player"] == 102)
    assert bob2["result"].startswith("unsupported")
    assert len(rep["steps"]) == 6 and max(s["n"] for s in rep["steps"]) == 3  # both chose done at 3

    # user messages: role, team summary, own history, events
    pcalls = [c for c in llm.calls if c.role == "player"]
    assert all(c.session_id == "playtest-" + rep["run_id"] for c in pcalls)
    alice2 = next(c for c in pcalls if "## You\nAlice" in c.user and "2 of 5" in c.user)
    assert ai.DEFAULT_ROLES[0] in alice2.user
    assert '"name":"Bob"' in alice2.user and '"Water"' in alice2.user
    assert "step 1: move_to_instance" in alice2.user
    assert "PromptTriggered" in alice2.user
    assert all(len(c.user) < 24_000 for c in pcalls)
    for k in ("n", "player", "observation", "action", "result", "request_id", "latency_ms"):
        assert k in rep["steps"][0]
    assert "probe" not in rep["steps"][0]["observation"]  # FakeHarness has no studio probe

    # judge once, with the trace, events and hints
    jcalls = [c for c in llm.calls if c.role == "judge"]
    assert len(jcalls) == 1
    assert "Fire did not shrink" in jcalls[0].user and "Alice" in jcalls[0].user
    assert rep["goal_met"] is True and rep["bugs"][0]["title"] == "Hydrant refill does nothing"
    assert rep["bug_hints"][0]["player"] == "Alice"
    assert rep["counters"] == {"fires_put_out": 1}

    saved = play.load_report(settings, rep["run_id"])
    assert saved["players"] == rep["players"] and len(saved["steps"]) == 6
    listed = play.list_reports(settings)
    assert listed[0]["run_id"] == rep["run_id"] and listed[0]["n_steps"] == 6 and listed[0]["bugs"] == 1


async def test_named_players_and_all_by_default(tmp_path):
    settings = _settings(tmp_path)
    llm = ScriptedLLM({}, delay=0)
    rep = await ai.multi_playtest(settings, "g", steps=2, llm=llm, harness=FakeHarness(), step_seconds=0)
    assert len(rep["players"]) == 3
    rep2 = await ai.multi_playtest(settings, "g", players=["Cara", "2"], steps=2, llm=ScriptedLLM({}, delay=0),
                                   harness=FakeHarness(), step_seconds=0)
    assert [p["name"] for p in rep2["players"]] == ["Cara", "Bob"]


async def test_explore_collects_suspected_bugs(tmp_path):
    settings = _settings(tmp_path)
    bug = {"title": "Fell through floor", "evidence": "pos y=-50", "severity": "high"}
    llm = ScriptedLLM({"Alice": [_a("jump", suspected_bug=bug), _a("look_at", {"pos": [1, 2, 3]})],
                       "Bob": [_a("say", {"text": "testing doors"})]}, delay=0)
    llm.responses["judge"] = [json.dumps({"goal_met": None, "summary": "s", "bugs": [bug]})]
    h = FakeHarness(PLAYERS[:2])
    rep = await ai.explore(settings, minutes=1, llm=llm, harness=h, max_ticks=3, step_seconds=0)
    assert rep["kind"] == "explore" and rep["agent_role"] == "explorer"
    assert {c.role for c in llm.calls} == {"explorer", "judge"}
    assert rep["suspected_bugs"][0]["title"] == "Fell through floor"
    assert rep["bugs"][0]["title"] == "Fell through floor"
    assert (101, "jump", {}) in h.acts and (102, "say", {"text": "testing doors"}) in h.acts
    assert ai.EXPLORE_ROLES[0] in rep["players"][0]["role"]


async def test_correct_step_with_player(tmp_path):
    settings = _settings(tmp_path)
    llm = ScriptedLLM({"Alice": [_a("move_to", {"x": 1, "y": 2, "z": 3})], "Bob": [_a("wait", {"seconds": 0})]},
                      delay=0)
    rep = await ai.multi_playtest(settings, "refill water", players=2, steps=3, llm=llm, harness=FakeHarness(),
                                  step_seconds=0)
    run_id = rep["run_id"]
    with pytest.raises(ValueError, match="several players"):
        await ai.correct_step(settings, run_id, 1, "note", llm=FakeLLM({}))

    llm2 = FakeLLM({"player": [_a("move_to_instance", {"path": "Workspace.Map.Hydrant1"})]})
    out = await ai.correct_step(settings, run_id, 1, "Walk to the hydrant by path.", player="Bob", llm=llm2)
    assert out["player"] == 102 and out["before"]["action"] == "wait"
    assert out["after"]["action"] == "move_to_instance"
    call = llm2.calls[0]
    assert call.role == "player" and call.session_id == "playtest-" + run_id
    assert "## You\nBob" in call.user and "## Correction from a human tester" in call.user
    assert "Hydrant1" in call.user and '"name":"Alice"' in call.user
    saved = play.load_report(settings, run_id)
    assert saved["corrections"][0]["player"] == 102 and out["request_id"] in saved["request_ids"]
    # helmet number addresses the player too
    out2 = await ai.correct_step(settings, run_id, 1, "x", player="1",
                                 llm=FakeLLM({"player": [_a("done")]}))
    assert out2["player"] == 101


async def test_suggest_fix_returns_diff(tmp_path):
    settings = _settings(tmp_path)
    game = settings.base_game_dir
    (game / "ServerScriptService" / "Services").mkdir(parents=True)
    hydrant = game / "ServerScriptService" / "Services" / "HydrantService.luau"
    hydrant.write_text("local HydrantService = {}\n\nfunction HydrantService.refill(player)\n"
                       "\t-- TODO\nend\n\nreturn HydrantService\n")
    (game / "ServerScriptService" / "Services" / "MapService.luau").write_text("local M = {}\nreturn M\n")
    (game / "tools").mkdir()
    (game / "tools" / "pull.luau").write_text("-- hydrant refill tool\n")

    llm = ScriptedLLM({}, delay=0)
    rep = await ai.multi_playtest(settings, "refill", players=1, steps=1, llm=llm, harness=FakeHarness(),
                                  step_seconds=0)
    critic = json.dumps({"score": 4, "summary": "refill is a stub", "done": False, "issues": [
        {"path": "ServerScriptService/Services/HydrantService.luau", "problem": "refill does nothing",
         "fix_hint": "set Water to TankSize"}]})
    fixed = ("```luau\nlocal HydrantService = {}\n\nfunction HydrantService.refill(player)\n"
             "\tplayer:SetAttribute(\"Water\", player:GetAttribute(\"TankSize\"))\nend\n\nreturn HydrantService\n```")
    llm2 = FakeLLM({"critic": [critic], "fixer": [fixed]})
    before = hydrant.read_text()
    out = await ai.suggest_fix(settings, rep["run_id"], 0, llm=llm2)
    assert out["path"] == "ServerScriptService/Services/HydrantService.luau"
    assert out["candidates"][0] == out["path"] and "tools/pull.luau" not in out["candidates"]
    assert "+\tplayer:SetAttribute(\"Water\"" in out["patch_preview"]
    assert "-\t-- TODO" in out["patch_preview"]
    assert out["patch_preview"].startswith("--- a/game/ServerScriptService/Services/HydrantService.luau")
    assert out["request_ids"] == ["fake-1", "fake-2"]
    assert "Hydrant refill does nothing" in out["problem"] and "set Water to TankSize" in out["problem"]
    assert hydrant.read_text() == before  # preview only
    assert [c.role for c in llm2.calls] == ["critic", "fixer"]
    assert "HydrantService.luau" in llm2.calls[0].user
    with pytest.raises(ValueError):
        await ai.suggest_fix(settings, rep["run_id"], 5, llm=llm2)
