"""Macro tester actions (go_touch, go_use, chase, repeat): mapping, validation, budgets, effect text."""

from __future__ import annotations

import json
import re

import pytest

from mubit_tester import ai
from mubit_tester import harness as hm
from mubit_tester.harness import Harness, act_budget, repeat_times
from test_harness import FakeStudio
from test_tester_ai import FakeHarness, ScriptedLLM, _a, _settings


def test_map_macros():
    assert ai.map_action({"action": "go_use", "args": {"path": "Workspace.Station.GearRack"}}) == \
        ("go_use", {"path": "Workspace.Station.GearRack"})
    # several prompts on one part: the prompt's action text picks one
    assert ai.map_action({"action": "go_use", "args": {"path": "Rack", "action": "Grab Rusty Axe"}}) == \
        ("go_use", {"path": "Rack", "action": "Grab Rusty Axe"})
    assert "action" not in ai.map_action({"action": "go_touch", "args": {"path": "P", "action": "x"}})[1]
    assert ai.map_action({"action": "go_touch", "args": {"instance_path": "Workspace.Pad", "timeout": 500}}) == \
        ("go_touch", {"path": "Workspace.Pad", "timeout": 60.0})
    assert ai.map_action({"action": "chase", "args": {"path": "Workspace.Drone"}}) == \
        ("chase", {"path": "Workspace.Drone", "touches": 3})
    assert ai.map_action({"action": "chase", "args": {"path": "D", "touches": 99}})[1]["touches"] == 5
    assert ai.map_action({"action": "chase", "args": {"path": "D", "touches": 0}})[1]["touches"] == 1
    for name in ai.MACROS:
        assert ai.map_action({"action": name, "args": {}}).startswith(f"error: {name} needs path")


def test_map_repeat_validates_and_maps_the_inner_action():
    assert ai.map_action({"action": "repeat", "args": {"action": "go_use", "args": {"path": "P"}, "times": 9}}) == \
        ("repeat", {"action": "go_use", "args": {"path": "P", "timeout": ai.REPEAT_MACRO_TIMEOUT}, "times": 5})
    # player vocabulary inside repeat goes through the same mapping
    assert ai.map_action({"action": "repeat", "args": {"action": "move_to_instance", "args": {"path": "P"}}}) == \
        ("repeat", {"action": "walk_to", "args": {"path": "P"}, "times": 2})
    assert ai.map_action({"action": "repeat", "args": {"action": "press", "args": {"text": "Buy"}, "times": 3}}) == \
        ("repeat", {"action": "press", "args": {"text": "Buy"}, "times": 3})
    assert ai.map_action({"action": "repeat", "args": {}}).startswith("error: repeat needs args.action")
    assert "can't repeat wait" in ai.map_action({"action": "repeat", "args": {"action": "wait"}})
    assert "can't repeat repeat" in ai.map_action({"action": "repeat", "args": {
        "action": "repeat", "args": {"action": "jump"}}})
    assert "needs path" in ai.map_action({"action": "repeat", "args": {"action": "go_use", "args": {}}})


def test_act_budget_covers_the_walk_and_fits_one_studio_call():
    assert act_budget("go_use", {}) == hm.MACRO_TIMEOUT + 15
    assert act_budget("chase", {"timeout": 45}) == 60
    assert act_budget("repeat", {"action": "go_use", "args": {"timeout": 15}, "times": 5}) == hm.MCP_CALL_LIMIT
    assert act_budget("repeat", {"action": "interact", "times": 3}) == 5
    assert act_budget("jump", {}) == 0
    assert repeat_times(9) == 5 and repeat_times(0) == 1 and repeat_times("x") == 2


async def test_harness_act_waits_long_enough_and_sends_no_budget_to_the_game(monkeypatch):
    sent = []
    st = FakeStudio({"act": lambda a: sent.append(a) or {"done": True, "detail": "ok", "effect": {}}})
    waits = []
    real = hm.asyncio.wait_for

    async def wait_for(aw, timeout):
        waits.append(timeout)
        return await real(aw, timeout)
    monkeypatch.setattr(hm.asyncio, "wait_for", wait_for)
    h = Harness(st, timeout=60)
    await h.act(101, "go_use", path="Workspace.Rack")
    await h.act(101, "jump")
    assert sent[0] == {"userId": 101, "action": "go_use", "args": {"path": "Workspace.Rack"}}
    assert waits == [60, 60]  # the harness floor already covers one macro
    await h.act(101, "chase", path="Workspace.Drone", timeout=60)
    assert waits[-1] == 75
    await h.act(101, "repeat", action="go_use", args={"path": "R", "timeout": 15}, times=5)
    assert waits[-1] == hm.MCP_CALL_LIMIT
    assert sent[-1] == {"userId": 101, "action": "repeat",
                        "args": {"action": "go_use", "args": {"path": "R", "timeout": 15}, "times": 5}}


async def test_repeat_of_a_gui_press_clicks_each_time_in_python():
    class H(Harness):
        def __init__(self):
            super().__init__(FakeStudio())
            self.presses = []

        async def press(self, user_id, path=None, text=None, wait=None):
            self.presses.append(text)
            return {"done": True, "fired": len(self.presses) == 1, "detail": f"press {len(self.presses)}"}
    h = H()
    res = await h.act(101, "repeat", action="press", args={"text": "Buy"}, times=3)
    assert h.presses == ["Buy"] * 3
    assert res["succeeded"] == 1 and res["done"] is False and "press x3, 1 fired" in res["detail"]


class MacroHarness(FakeHarness):
    async def act(self, user_id, action, **args):
        await super().act(user_id, action, **args)
        if action == "go_use":
            return {"done": True, "detail": "walked, then triggered 'Take Gear'",
                    "effect": {"attrs": {"Carrying": ["nil", "Axe"]}, "hud_new": ["Axe equipped"]}}
        if action == "go_touch":
            return {"done": False, "detail": "never touched Workspace.Pad", "effect": {}}
        return {"done": True, "detail": f"{action} ok"}


async def test_dispatch_reports_the_effect_and_the_ai_is_taught_macros(tmp_path):
    h = MacroHarness()
    assert "| effect: nothing changed" in await ai.dispatch(h, 101, {"action": "go_touch", "args": {"path": "P"}})
    llm = ScriptedLLM({"Alice": [_a("go_use", {"path": "Workspace.Station.GearRack"}),
                                 _a("go_touch", {"path": "Workspace.Pad"})]}, delay=0)
    rep = await ai.multi_playtest(_settings(tmp_path), "gear up", players=1, steps=3, llm=llm, harness=h,
                                  step_seconds=0)
    steps = [s for s in rep["steps"] if s["action"].get("action") != "done"]
    assert '"Carrying":["nil","Axe"]' in steps[0]["result"] and "Axe equipped" in steps[0]["result"]
    users = [c.user for c in llm.calls if c.role == "player"]
    assert all("## Macro actions" in u and "go_use" in u and "repeat" in u for u in users)
    assert re.search(r"## Step\n1 of 3 \(decisions\)", users[0])
    assert "effect" in users[1]  # the previous step's effect is in the history the tester reads next
    assert rep["decisions"] == 3 and rep["macro_decisions"] == 2


@pytest.mark.parametrize("bad", [{"action": "go_use"}, {"action": "chase", "args": {"touches": 2}}])
def test_macros_without_a_path_never_reach_the_game(bad):
    assert isinstance(ai.map_action(bad), str)


def test_macro_guide_stays_in_the_user_message_not_the_frozen_prompts():
    from forge.llm import load_prompt
    for role in ("player", "explorer"):
        assert "go_touch" not in load_prompt(role)
    assert json.dumps(ai.MACRO_GUIDE)  # plain text
