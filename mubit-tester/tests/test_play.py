"""Tests for mubit_tester.play: the AI playtester loop with a scripted LLM and a fake Studio."""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from mubit_tester import play
from forge.config import Settings
from forge.llm import FakeLLM, load_prompt

OBS = {
    "me": {"pos": [0, 3, 0], "health": 100, "max_health": 100,
           "attrs": {"Water": 50, "TankSize": 100, "Carrying": False}, "tool": None, "backpack": ["Hose", "Axe"]},
    "world": {"RoundState": "Active", "MissionId": "m1", "now": 1000},
    "things": [
        {"name": "Hydrant1", "path": "Workspace.Map.Hydrant1", "tag": "Hydrant", "dist": 12, "pos": [12, 3, 0]},
        {"name": "Kitchen", "path": "Workspace.Map.HouseA.Kitchen", "tag": "Burning", "dist": 30,
         "pos": [30, 3, 0], "FireLevel": 2},
    ],
    "prompts": [
        {"action": "Refill", "object": "Hydrant", "dist": 5, "range": 10, "in_range": True, "hold": 1.0,
         "key": "E", "path": "Workspace.Map.Hydrant1"},
    ],
    "hud": ["Water 50/100", "3:12"],
}

PROBE = {"uptime": 5.0, "errors": [{"message": "Fire.luau:12: attempt to index nil", "script": "Fire", "count": 1}],
         "warnings": [], "players": 1, "counters": {"fires_started": 1}, "instances": 300}


class FakeStudio:
    def __init__(self, playing: bool = False):
        self.playing = playing
        self.calls: list[tuple[str, dict]] = []
        self.luau: list[tuple[str, str]] = []
        self.selected: str | None = None
        self.played = 0
        self.stopped = 0
        self.probes = 0
        self.studio_id = "studio-1"

    async def select(self, name_hint=None):
        self.selected = name_hint
        return self.studio_id

    async def play(self):
        self.played += 1
        self.playing = True

    async def stop(self):
        self.stopped += 1
        self.playing = False

    async def state(self):
        return {"playing": self.playing}

    async def call(self, tool, **args):
        self.calls.append((tool, args))
        return "ok"

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.luau.append((code, datamodel))
        return "[RETURNED RESULTS]\n" + json.dumps(OBS)

    async def probe_report(self):
        self.probes += 1
        return PROBE


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        mubit_api_key=None, provider="anthropic", base_url="https://api.mubit.ai/anthropic",
        model="claude-sonnet-5", studio_mcp_path="", sync_port=34873, repo_root=tmp_path,
        runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game",
    )


def _a(action, args=None, bug=None, reason="r"):
    return json.dumps({"action": action, "args": args or {}, "reason": reason, "bug": bug})


JUDGE = json.dumps({"goal_met": True, "summary": "Refilled and sprayed.",
                    "bugs": [{"title": "Fire script errors", "evidence": "probe step 1", "severity": "high"}]})


def test_prompts_static_and_registered():
    for role in ("player", "judge"):
        text = load_prompt(role)
        assert len(text) > 500
        assert not re.search(r"\{[a-z_][a-z0-9_]*\}", text)
    assert "## Correction" not in load_prompt("player")


async def test_playtest_dispatches_actions_and_saves(tmp_path):
    settings = _settings(tmp_path)
    llm = FakeLLM({
        "player": [
            _a("move_to", {"x": 10, "y": 3, "z": 5}),
            _a("move_to_instance", {"path": "Workspace.Map.Hydrant1"}),
            _a("interact", {"path": "Workspace.Map.Hydrant1"}),
            _a("equip", {"slot": 1}),
            _a("spray", {"target": "Workspace.Map.HouseA.Kitchen", "ms": 1000},
               bug={"title": "Water did not drop", "evidence": "Water stayed 50", "severity": "medium"}),
            _a("key", {"key": "q"}),
            _a("wait", {"seconds": 0}),
            _a("done"),
            _a("move_to", {"x": 0, "y": 0, "z": 0}),  # must never be used
        ],
        "judge": [JUDGE],
    })
    studio = FakeStudio()
    rep = await play.playtest(settings, "refill water and spray the kitchen fire", steps=20,
                              llm=llm, studio=studio, step_seconds=0)

    # played and stopped since we started it
    assert studio.played == 1 and studio.stopped == 1
    # done ended early: 8 steps, one leftover player reply
    assert len(rep["steps"]) == 8
    assert rep["steps"][-1]["action"]["action"] == "done"
    assert len(llm.responses["player"]) == 1

    tools = [t for t, _ in studio.calls]
    assert tools == ["character_navigation", "character_navigation", "user_keyboard_input",
                     "user_keyboard_input", "user_mouse_input", "user_keyboard_input"]
    nav1, nav2, interact, equip, spray, key = (a for _, a in studio.calls)
    assert nav1 == {"datamodel_type": "Client", "x": 10.0, "y": 3.0, "z": 5.0}
    assert nav2 == {"datamodel_type": "Client", "instance_path": "Workspace.Map.Hydrant1"}
    # hold-duration prompt -> keyDown / wait / keyUp on its key
    assert [x["action"] for x in interact["actions"]] == ["keyDown", "wait", "keyUp"]
    assert interact["actions"][0]["key_code"] == "E" and interact["actions"][1]["wait_time_ms"] >= 1000
    assert equip["actions"] == [{"action": "keyPress", "key_code": "One"}]
    assert spray["datamodel_type"] == "Client"
    assert [x["action"] for x in spray["actions"]] == ["moveTo", "mouseButtonDown", "wait", "mouseButtonUp"]
    assert spray["actions"][0]["instance_path"] == "Workspace.Map.HouseA.Kitchen"
    assert spray["actions"][2]["wait_time_ms"] == 1000
    assert key["actions"] == [{"action": "keyPress", "key_code": "Q"}]

    # observation from the Client datamodel, probe merged on step 1 and 6
    assert all(dm == "Client" for _, dm in studio.luau)
    assert studio.luau[0][0] == play.OBSERVE_LUAU
    assert "probe" in rep["steps"][0]["observation"] and "probe" in rep["steps"][5]["observation"]
    assert "probe" not in rep["steps"][1]["observation"]
    assert rep["steps"][0]["observation"]["probe"]["errors"][0]["message"].startswith("Fire.luau:12")
    assert len(json.dumps(rep["steps"][0]["observation"])) < 3000

    # player user message content + session id
    pcalls = [c for c in llm.calls if c.role == "player"]
    assert all(c.session_id == "playtest-" + rep["run_id"] for c in pcalls)
    assert "refill water and spray the kitchen fire" in pcalls[0].user
    assert "1 of 20" in pcalls[0].user and "Hydrant1" in pcalls[0].user
    assert "step 1: move_to" in pcalls[1].user

    # judge
    jcall = [c for c in llm.calls if c.role == "judge"][0]
    assert "Water did not drop" in jcall.user and "Fire.luau:12" in jcall.user
    assert rep["goal_met"] is True
    assert rep["bugs"] == [{"title": "Fire script errors", "evidence": "probe step 1", "severity": "high"}]
    assert rep["bug_hints"][0]["title"] == "Water did not drop"
    assert rep["probe"] == PROBE
    assert len(rep["request_ids"]) == 9  # 8 player + 1 judge

    # saved
    saved = play.load_report(settings, rep["run_id"])
    assert saved["goal_met"] is True and len(saved["steps"]) == 8
    assert (settings.runs_dir / "playtests" / rep["run_id"] / "report.json").exists()
    listed = play.list_reports(settings)
    assert listed == [{"run_id": rep["run_id"], "goal": rep["goal"], "goal_met": True, "n_steps": 8, "bugs": 1}]


async def test_already_playing_is_left_running_and_errors_recorded(tmp_path):
    settings = _settings(tmp_path)
    llm = FakeLLM({"player": ["not json", "still not", "nope", _a("teleport")], "judge": ["garbage"] * 3})
    studio = FakeStudio(playing=True)
    rep = await play.playtest(settings, "explore", steps=2, llm=llm, studio=studio, step_seconds=0,
                              studio_name="Place1")
    assert studio.selected == "Place1"
    assert studio.played == 0 and studio.stopped == 0
    assert len(rep["steps"]) == 2
    assert rep["steps"][0]["result"].startswith("error: LLMError")
    assert "unknown action" in rep["steps"][1]["result"]
    assert rep["goal_met"] is None and any(e.startswith("judge:") for e in rep["errors"])


async def test_correct_step_records_correction(tmp_path):
    settings = _settings(tmp_path)
    llm = FakeLLM({"player": [_a("move_to", {"x": 1, "y": 2, "z": 3}), _a("done")], "judge": [JUDGE]})
    rep = await play.playtest(settings, "refill water", steps=5, llm=llm, studio=FakeStudio(), step_seconds=0)
    run_id = rep["run_id"]

    llm2 = FakeLLM({"player": [_a("move_to_instance", {"path": "Workspace.Map.Hydrant1"})]})
    note = "Walk to the hydrant by its path instead of guessing coordinates."
    out = await play.correct_step(settings, run_id, 1, note, llm=llm2)

    assert out["run_id"] == run_id and out["step"] == 1
    assert out["before"]["action"] == "move_to"
    assert out["after"]["action"] == "move_to_instance"
    assert out["request_id"] == "fake-1"
    call = llm2.calls[0]
    assert call.role == "player" and call.session_id == "playtest-" + run_id
    assert "## Correction from a human tester\n" + note in call.user
    # same observation + goal as the original step's call
    original = [c for c in llm.calls if c.role == "player"][0].user
    assert call.user.startswith(original)

    saved = play.load_report(settings, run_id)
    assert saved["corrections"][-1]["note"] == note
    assert saved["corrections"][-1]["after"]["action"] == "move_to_instance"

    with pytest.raises(ValueError):
        await play.correct_step(settings, run_id, 99, note, llm=llm2)


def test_compact_observation_limits_size():
    big = dict(OBS)
    big["things"] = [dict(OBS["things"][0], name=f"T{i}" * 20) for i in range(12)]
    big["hud"] = ["x" * 80] * 10
    out = play.compact_observation(big)
    assert len(json.dumps(out, separators=(",", ":"))) < 3000
    assert out["me"] == OBS["me"]


def test_touchables_are_trimmed_and_shown_in_brief():
    big = dict(OBS)
    big["touchables"] = [{"name": f"Pad{i}" * 20, "path": "Workspace.Plot.Pad", "dist": i, "touch": True,
                          "label": "Gadget Lab $150"} for i in range(30)]
    out = play.compact_observation(big)
    assert len(json.dumps(out, separators=(",", ":"))) < 3000
    assert out["touchables"]
    assert "touch=Gadget Lab $150@0" in play._obs_brief(big)
