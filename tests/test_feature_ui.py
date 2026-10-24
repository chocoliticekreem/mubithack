"""A feature with client UI is verified only when a tester really clicked one of its buttons."""

from __future__ import annotations

import json

from forge.feature import feature_has_ui, feature_ui_presses, feature_verified, polish_feature
from forge.improve import audit_message, round_digest
from forge.llm import FakeLLM
from forge.memory import RunStore
from test_fix_loop import _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply

UI_FEATURE = {"request": "add a battle pass with tiers", "plan": {
    "telemetry": ["bp_xp", "bp_claims"],
    "new_modules": [{"path": "ServerScriptService/Services/BattlePassService.luau"},
                    {"path": "StarterPlayerScripts/BattlePassController.client.luau"}]}}
SERVER_FEATURE = {"request": "double xp weekends", "plan": {
    "telemetry": ["xp_boost"], "new_modules": [{"path": "ServerScriptService/Services/BoostService.luau"}]}}
COUNTERS = {"bp_xp": 40, "bp_claims": 1, "xp_boost": 2}


def press(text, path, fired=True):
    return {"player": "Alice", "text": text, "path": path, "fired": fired, "changed": fired, "effect": {}}


def test_feature_has_ui_from_client_paths_and_ui_names():
    assert feature_has_ui(UI_FEATURE)
    assert not feature_has_ui(SERVER_FEATURE)
    assert feature_has_ui({"plan": {"new_modules": [{"path": "ReplicatedStorage/Shared/ShopGui.luau"}]}})
    assert feature_has_ui({"plan": {"edits": [{"path": "StarterPlayerScripts/Controllers/HudController.luau"}]}})


def test_counters_alone_do_not_verify_a_ui_feature():
    assert feature_verified(UI_FEATURE, COUNTERS, []) is False
    assert feature_verified(UI_FEATURE, COUNTERS, [press("Pass", "BattlePassGui.PassButton", fired=False)]) is False
    assert feature_verified(UI_FEATURE, COUNTERS, [press("Shop", "ShopGui.Open")]) is False  # someone else's UI
    assert feature_verified(UI_FEATURE, COUNTERS, [press("Pass", "BattlePassGui.PassButton")]) is True
    assert feature_verified(UI_FEATURE, {"bp_xp": 40}, [press("Pass", "BattlePassGui.PassButton")]) is False


def test_server_only_feature_still_verifies_on_counters():
    assert feature_verified(SERVER_FEATURE, COUNTERS, []) is True
    assert feature_verified(SERVER_FEATURE, {}, []) is False
    assert feature_verified({"request": "x", "plan": {}}, COUNTERS, []) is False


def test_press_matching_uses_the_feature_tokens():
    hits = feature_ui_presses(UI_FEATURE, [press("Claim", "BattlePassGui.Panel.Tier1.Claim"),
                                           press("Claim", "QuestGui.Claim"), "junk"])
    assert [h["path"] for h in hits] == ["BattlePassGui.Panel.Tier1.Claim"]


def test_round_digest_carries_ui_presses_to_the_auditor():
    p = dict(press("Pass", "BattlePassGui.PassButton"), t=3, gui="BattlePassGui")
    d = round_digest({"ui_presses": [p] * 12}, 1)
    assert len(d["ui_presses"]) == 8
    assert d["ui_presses"][0] == {"player": "Alice", "text": "Pass", "path": "BattlePassGui.PassButton",
                                  "fired": True, "changed": True, "effect": {}}
    assert "BattlePassGui.PassButton" in audit_message({"pitch": "p"}, "", [d])
    assert round_digest({}, 1)["ui_presses"] == []


async def test_polish_needs_a_ui_press_and_tells_testers_to_use_the_ui(settings):  # noqa: F811
    _seeded_game(settings)
    store = RunStore(settings, "fab")
    spec = store.load_spec()
    spec["features"] = [UI_FEATURE]
    store.save_spec(spec)
    rounds = iter([[], [press("Pass", "BattlePassGui.PassButton")]])
    goals = []

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        goals.append(goal)
        return {"goal": goal, "counters": COUNTERS, "ui_presses": next(rounds)}

    llm = FakeLLM({"auditor": [audit_reply([]), audit_reply([])], "reflector": ["# L\n"]})
    cycles = await polish_feature(settings, "fab", cycles=3, playtest=playtest, harness=FakeHarness(), llm=llm,
                                  log=lambda _: None)
    assert [c["feature_verified"] for c in cycles] == [False, True]  # counters were > 0 both times
    assert [c["feature_ui_presses"] for c in cycles] == [0, 1]
    assert "through its buttons" in goals[0] and "press" in goals[0]
    auditor_user = [c.user for c in llm.calls if c.role == "auditor"][1]
    assert json.dumps("BattlePassGui.PassButton") in auditor_user
