"""Smoke play (forge/smoke.py): the scoring playtest plays the game with the ForgeTest harness before the critic
reads the report. A fake Studio answers the harness commands from a tiny game model."""

from __future__ import annotations

import asyncio
import dataclasses
import io
import json
import re
import time

import pytest

from forge import fun, loop, roles, smoke
from forge.config import load_settings
from forge.llm import FakeLLM
from forge.loop import UI, Run
from forge.memory import RunStore
from forge.studio import StudioError

CALL_RE = re.compile(r'Invoke\("(\w+)", \[(=+)\[(.*)\]\2\]\)\s*$', re.S)
LAVA = "Workspace.Obby.Stages.Stage015.02_lava.Lava"
NOT_RENDERING = "the game view is not rendering (viewport 1x1)"


class FakeGame:
    """A fake Studio for one player (Alice, 101) in a game with optional checkpoints, coins, prompts and UI."""

    def __init__(self, *, stages=0, coins=(), prompts=(), touchables=(), ui=(), ui_error=None, stage0=True,
                 window=True, fails=(), delay=0.0, slow=(), broken=False):
        self.stages, self.coins, self.prompts, self.touchables = stages, list(coins), list(prompts), list(touchables)
        self.ui_buttons, self.ui_error, self.stage0, self.window = list(ui), ui_error, stage0, window
        self.fails, self.delay, self.slow, self.broken = set(fails), delay, set(slow), broken
        self.stage, self.dead_polls, self.bots = 0, 0, []
        self.counters = {"game_started": 1}
        self.calls: list[tuple[str, dict]] = []
        self.log: list[str] = []
        self.studio_id = "fake-studio"

    def bump(self, k, n=1):
        self.counters[k] = self.counters.get(k, 0) + n

    # ---- Studio surface used by Run.playtest
    async def sync(self, root, port, prune=True):
        return "OK 1 files"

    async def play(self):
        self.log.append("play")

    async def probe_report(self):
        self.log.append("probe_report")
        return {"uptime": 9, "errors": [], "players": 1, "counters": dict(self.counters)}

    async def console(self):
        return ""

    async def screenshot(self, path):
        return None

    async def stop(self):
        self.log.append("stop")

    async def call(self, tool, **args):
        if tool == "execute_luau" and args.get("datamodel_type") == "Client":  # Harness.ui_windows
            if not self.window:
                raise StudioError("no Client datamodel")
            return json.dumps({"userId": 101, "session": "S1"})
        if tool == "user_mouse_input":
            return "ok"
        raise AssertionError(f"unexpected tool {tool}")

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        if self.broken:
            raise StudioError("Studio went away")
        m = CALL_RE.search(code)
        if not m:
            return "{}"  # fun.census
        cmd, args = m.group(1), json.loads(m.group(3))
        self.calls.append((cmd, args))
        self.log.append(cmd)
        if self.delay or cmd in self.slow:
            await asyncio.sleep(5.0 if cmd in self.slow else self.delay)
        try:
            return json.dumps({"ok": True, "result": self.run(cmd, args)})
        except Exception as e:  # noqa: BLE001
            return json.dumps({"ok": False, "error": str(e)})

    # ---- the harness commands
    def run(self, cmd, args):
        return getattr(self, "c_" + cmd)(args)

    def c_ping(self, a):
        return {"version": "2", "session": "S1"}

    def c_counters(self, a):
        return dict(self.counters)

    def c_players(self, a):
        alive = self.dead_polls <= 0
        self.dead_polls -= 1
        return [{"userId": 101, "name": "Alice", "pos": [0, 4, 0], "hasCharacter": True,
                 "health": 100 if alive else 0, "attrs": {"Stage": self.stage}}]

    def c_observe(self, a):
        obs = {"me": {"userId": 101}, "prompts": self.prompts, "touchables": self.touchables, "ui": self.ui_buttons}
        if self.ui_error:
            obs["ui_error"] = self.ui_error
        if self.stages:
            obs["obby"] = {"stage": self.stage, "stages": self.stages, "max_stage": self.stages, "hazards": [],
                           "nearest": {"stage": max(1, self.stage), "dist": 3}}
        return obs

    def c_query(self, a):
        if a.get("tag") == "Coin":
            return [{"path": c["path"], "pos": c["pos"], "dist": c.get("dist", 10), "attrs": {"Available": True}}
                    for c in self.coins]
        if a.get("tag") == "ObbyStage":
            return [{"attrs": {"Stage": s, "Zone": (s - 1) // 20 + 1}} for s in range(1, self.stages + 1)]
        if a.get("tag") == "KillPart":
            return [{"path": LAVA, "pos": [0, 30, -1200]}] if self.stages else []
        return []

    def c_act(self, a):
        action, args = a["action"], a.get("args") or {}
        if action == "repeat":  # walk_to a coin by position
            pos = args["args"]["pos"]
            if any(c["pos"] == pos for c in self.coins):
                old = self.counters.get("coin_collected", 0)
                self.bump("coin_collected")
                return {"done": True, "effect": {"counters": {"coin_collected": [old, old + 1]}}}
            return {"done": True, "effect": {}}
        if action == "go_use":
            self.bump("item_bought")
            return {"done": True, "detail": f"used {args['path']}", "effect": {"counters": {"item_bought": [0, 1]}}}
        if action == "go_touch":
            return {"done": True, "detail": f"touched {args['path']}"}
        raise RuntimeError(f"unknown action {action}")

    def c_bot_spawn(self, a):
        self.bots = [{"userId": -1001 - i, "name": f"Bot{i + 1}", "bot": True} for i in range(a["n"])]
        return self.bots

    def c_bot_clear(self, a):
        n, self.bots = len(self.bots), []
        return {"removed": n}

    def c_multi(self, a):
        out = []
        for c in a["calls"]:
            try:
                out.append({"ok": True, "result": self.run(c["cmd"], c["args"])})
            except Exception as e:  # noqa: BLE001
                out.append({"ok": False, "error": str(e)})
        return out

    def c_obby_try(self, a):
        start = a.get("from_stage", self.stage)
        if start == 0 and not self.stage0:
            raise RuntimeError("no checkpoint with Stage 0 (200 parts tagged Checkpoint, stages 1..200)")
        to = start + 1
        if start in self.fails:
            tries = [{"result": "fell", "hazard": f"Workspace.Obby.Stages.Stage{to:03d}.02_lava.Lava", "at": [0, 9, -40],
                      "secs": 2.1}] * a.get("attempts", 1)
            return {"done": False, "reached": False, "from_stage": start, "to_stage": to, "attempts": tries}
        if a["userId"] == 101:
            self.stage = to
            self.bump("checkpoint_reached")
        return {"done": True, "reached": True, "from_stage": start, "to_stage": to,
                "attempts": [{"result": "reached", "at": [0, 9, -50], "secs": 4.0}]}

    def c_teleport(self, a):
        if a.get("path") == LAVA:
            self.dead_polls = 2
            self.bump("player_died")
        return True

    def c_ui(self, a):
        return {"buttons": self.ui_buttons}

    def c_ui_target(self, a):
        return {"x": 20, "y": 20}

    def c_ui_effect(self, a):
        return {"fired": True, "changed": True, "path": "HUD.Shop", "text": "Shop", "effect": {"hud_new": ["Shop open"]}}


COINS = [{"path": "Workspace.Lobby.LobbyCoin", "pos": [0, 4, -34], "dist": 31},
         {"path": "Workspace.Lobby.LobbyCoin", "pos": [-3, 4, -27], "dist": 38}]


def cmds(game: FakeGame, name: str) -> list[dict]:
    return [a for c, a in game.calls if c == name]


@pytest.fixture(autouse=True)
def fast_polls(monkeypatch):
    monkeypatch.setattr(smoke, "POLL", 0.01)
    monkeypatch.setattr(smoke, "SETTLE", 0.01)


async def play(game: FakeGame, budget: float = 30.0, spec: dict | None = None) -> dict:
    return await smoke.smoke_play(game, spec or {}, None, budget_s=budget)


# ---------------------------------------------------------------- step selection


def test_sample_stages_spread_over_the_whole_course():
    assert smoke.sample_stages(200) == [1, 20, 40, 60, 80, 100, 120, 140, 160, 180, 199]
    assert smoke.sample_stages(5) == [1, 2, 3, 4]
    assert smoke.sample_stages(1) == [] and smoke.sample_stages(0) == []


async def test_obby_runs_from_spawn_samples_every_zone_with_bots_and_kills_once():
    game = FakeGame(stages=200, coins=COINS, fails={40})
    res = await play(game)
    assert [s["what"] for s in res["steps"]] == ["players", "ui", "pickups", "obby", "kill part"]
    assert res["steps"][1]["skipped"] and "no on-screen buttons" in res["steps"][1]["detail"]
    [multi] = cmds(game, "multi")
    assert multi["calls"][0]["args"] == {"userId": 101, "from_stage": 0, "attempts": smoke.ATTEMPTS,
                                         "timeout": multi["calls"][0]["args"]["timeout"]}
    assert [c["args"]["from_stage"] for c in multi["calls"][1:]] == smoke.sample_stages(200)
    assert all(c["args"]["userId"] < 0 for c in multi["calls"][1:])  # one bot tester per sampled stage
    ob = res["obby"]
    assert ob["samples"][0] == {"from": 0, "to": 1, "by": "player", "result": "reached", "where": "on checkpoint 1",
                                "secs": 4.0, "attempts": 1, "zone": 1}
    assert (ob["reached"], ob["total"]) == (11, 12) and ob["player_stage"] == 1
    assert ob["zones_sampled"] == list(range(1, 11)) and 3 not in ob["zones_reached"]
    fell = next(s for s in ob["samples"] if s["from"] == 40)
    assert fell["result"] == "fell" and "Stage041.02_lava.Lava" in fell["where"] and fell["attempts"] == 2
    kill = res["steps"][-1]
    assert kill["ok"] and "died" in kill["detail"] and "at checkpoint 1" in kill["detail"]
    assert cmds(game, "bot_clear"), "bots are cleared after the run"
    d = res["counters_delta"]
    assert d["checkpoint_reached"] == 1 and d["coin_collected"] == 2 and d["player_died"] == 1


async def test_coins_are_walked_to_by_position_and_count_when_the_game_registers_them():
    game = FakeGame(coins=COINS + [{"path": "Workspace.Far.Coin", "pos": [0, 4, -900], "dist": 900}])
    res = await play(game)
    pick = next(s for s in res["steps"] if s["what"] == "pickups")
    assert pick["ok"] and pick["detail"].startswith("2/2 Coin parts")  # the 900-stud coin is out of range
    walks = [a["args"] for a in cmds(game, "act") if a["action"] == "repeat"]
    assert [w["args"]["pos"] for w in walks] == [[0, 4, -34], [-3, 4, -27]] and all(w["action"] == "walk_to"
                                                                                     for w in walks)


async def test_a_harness_without_stage_0_runs_the_player_from_checkpoint_1():
    game = FakeGame(stages=200, stage0=False)
    res = await play(game)
    first = res["obby"]["samples"][0]
    assert (first["from"], first["to"], first["by"], first["result"]) == (1, 2, "player", "reached")
    assert cmds(game, "obby_try")[-1]["from_stage"] == 1


async def test_other_genres_use_the_nearest_prompt_and_spawn_no_bots():
    game = FakeGame(prompts=[{"path": "Workspace.Shop.Counter", "action": "Buy", "dist": 6}])
    res = await play(game)
    step = res["steps"][-1]
    assert step["what"] == "prompt" and step["ok"] and "item_bought 0->1" in step["detail"]
    assert not cmds(game, "bot_spawn") and not cmds(game, "multi") and res["obby"] is None


async def test_a_game_with_nothing_to_use_says_so():
    res = await play(FakeGame())
    assert res["steps"][-1] == {"what": "core loop", "ok": False, "skipped": True,
                                "detail": "skipped: no prompt or touchable near the player", "secs": 0.0}


# ---------------------------------------------------------------- UI


async def test_ui_is_skipped_with_the_reason_when_no_click_can_land():
    res = await play(FakeGame(ui=[{"text": "Shop", "path": "HUD.Shop", "gui": "HUD"}], ui_error=NOT_RENDERING))
    ui = res["steps"][1]
    assert ui["skipped"] and NOT_RENDERING in ui["detail"]
    res = await play(FakeGame(ui=[{"text": "Shop", "path": "HUD.Shop", "gui": "HUD"}], window=False))
    assert "no Studio window drives this player" in res["steps"][1]["detail"]


async def test_ui_presses_the_visible_surfaces_when_a_window_drives_the_player():
    game = FakeGame(ui=[{"text": "Shop", "path": "HUD.Shop", "gui": "HUD", "x": 20, "y": 20}])
    res = await play(game, spec={"title": "Shop game", "core_loop": "buy things in the shop"})
    ui = res["steps"][1]
    assert ui["what"] == "ui" and ui["ok"] and "Shop: fired" in ui["detail"]
    assert cmds(game, "ui_target") and cmds(game, "ui_effect")


# ---------------------------------------------------------------- budget, never raising, shape


async def test_the_budget_skips_what_does_not_fit():
    game = FakeGame(stages=200, coins=COINS, delay=0.15)
    t0 = time.monotonic()
    res = await play(game, budget=1.0)
    assert time.monotonic() - t0 < 3.0
    assert any(s.get("skipped") and "budget" in s["detail"] for s in res["steps"])
    assert not cmds(game, "multi")


async def test_a_hung_step_is_cut_after_the_overrun(monkeypatch):
    monkeypatch.setattr(smoke, "OVERRUN", 0.3)
    game = FakeGame(coins=COINS, slow={"observe"})
    t0 = time.monotonic()
    res = await play(game, budget=0.5)
    assert time.monotonic() - t0 < 3.0 and res["error"].startswith("cut after")


async def test_never_raises_when_studio_breaks():
    res = await play(FakeGame(broken=True))
    assert res["steps"][0]["what"] == "players" and not res["steps"][0]["ok"]
    assert "Studio went away" in res["steps"][0]["detail"]


async def test_one_broken_step_does_not_stop_the_others(monkeypatch):
    async def boom(self, obs, reserve):
        raise KeyError("oops")
    monkeypatch.setattr(smoke._Smoke, "pickups", boom)
    res = await play(FakeGame(stages=20))
    whats = {s["what"]: s for s in res["steps"]}
    assert "KeyError" in whats["pickups"]["detail"] and whats["obby"]["ok"] and whats["kill part"]["ok"]


async def test_report_shape_and_off_switch():
    res = await play(FakeGame(stages=20, coins=COINS))
    assert set(res) >= {"budget_s", "secs", "steps", "obby", "counters_delta"}
    assert all(set(s) >= {"what", "ok", "detail", "secs"} for s in res["steps"])
    assert all(set(r) >= {"from", "to", "result", "where"} for r in res["obby"]["samples"])
    off = await play(FakeGame(), budget=0)
    assert off["skipped"] and not off["steps"]


def test_counters_the_spec_names_come_first():
    spec = {"acceptance": ["touching a checkpoint bumps checkpoint_reached"], "core_loop": "collect coins"}
    assert list(smoke.spec_first({"juice": 3, "checkpoint_reached": 1}, spec)) == ["checkpoint_reached", "juice"]


# ---------------------------------------------------------------- the critics see it


SMOKE = {"secs": 21.0, "budget_s": 45, "steps": [{"what": "pickups", "ok": True, "detail": "2/3 Coin parts", "secs": 5}],
         "obby": {"samples": [{"from": 0, "to": 1, "by": "player", "result": "reached", "where": "on checkpoint 1",
                               "zone": 1},
                              {"from": 40, "to": 41, "by": "bot", "result": "fell", "where": "hazard Lava at [0, 9, 1]",
                               "zone": 3}],
                  "reached": 1, "total": 2, "zones_sampled": [1, 3], "zones_reached": [1]},
         "counters_delta": {"checkpoint_reached": 2, "coin_collected": 6}}


def test_critic_message_gets_a_smoke_play_section_not_a_json_copy():
    llm = FakeLLM({"critic": [json.dumps({"score": 7, "summary": "played", "issues": []})]})
    report = {"uptime": 30, "errors": [], "counters": {"coin_collected": 6}, "smoke": SMOKE}
    roles.critique(llm, {"title": "T"}, report, "", {"ServerScriptService/Game.server.luau": "print(1)"},
                   session_id="t")
    user = llm.calls[-1].user
    assert "## Smoke play" in user and "0->1 player z1: reached" in user and "40->41 bot z3: fell hazard Lava" in user
    assert "coin_collected +6" in user and "a failed bot run is a lead, not proof" in user
    assert '"smoke"' not in user  # not duplicated inside the ForgeProbe report JSON
    assert user.index("## ForgeProbe report") < user.index("## Smoke play") < user.index("## Console output")


def test_no_smoke_section_without_smoke_play():
    llm = FakeLLM({"critic": [json.dumps({"score": 7, "summary": "s", "issues": []})]})
    roles.critique(llm, {"title": "T"}, {"uptime": 3}, "", {}, session_id="t")
    assert "## Smoke play" not in llm.calls[-1].user


def test_fun_critic_evidence_names_the_smoke_play():
    msg = fun.fun_message({"title": "T"}, {}, {"counters": {}, "smoke": SMOKE}, {})
    assert "smoke play 21.0s: 1/1 steps ok, obby 1/2 reached; checkpoint_reached +2" in msg


# ---------------------------------------------------------------- inside Run.playtest


@pytest.fixture
def run(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_PLAY_SECONDS", "0")
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "g")
    store.ensure()
    return Run(s, store, llm=object.__new__(type("L", (), {"complete": None})), ui=UI(io.StringIO()))


async def test_playtest_plays_before_the_probe_report(run, tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_SMOKE_SECONDS", "20")
    run.spec = {"title": "Obby"}
    game, rec = FakeGame(stages=20, coins=COINS), {"steps": []}
    report, _ = await run.playtest(game, rec, tmp_path)
    assert report["smoke"]["obby"]["reached"] >= 1
    assert report["counters"]["checkpoint_reached"] == 1  # the probe was read after the play
    assert game.log.index("multi") < game.log.index("probe_report") < game.log.index("stop")
    assert {"step": "smoke", "ok": True, "secs": report["smoke"]["secs"]} in rec["steps"]


async def test_playtest_smokes_after_a_round_start_too(run, tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_SMOKE_SECONDS", "20")
    monkeypatch.setattr(loop, "START_ROUND_DELAY", 0)
    run.spec = {"playtest": {"start_round": True}}
    game = FakeGame(prompts=[{"path": "Workspace.Pad", "action": "Start", "dist": 4}])
    game.c_round = lambda a: {"RoundState": "Active"}
    report, _ = await run.playtest(game, {"steps": []}, tmp_path)
    assert game.log.index("round") < game.log.index("act") < game.log.index("probe_report")
    assert report["smoke"]["steps"][-1]["what"] == "prompt"


async def test_smoke_off_leaves_the_playtest_as_it_was(run, tmp_path):
    game = FakeGame(stages=20)
    report, _ = await run.playtest(game, {"steps": []}, tmp_path)  # conftest: FORGE_SMOKE_SECONDS=0
    assert "smoke" not in report and not game.calls
