"""Acceptance names only counters a playtest exercises (forge/testable.py), and readiness reads a profile.
A real 100-stage park obby promised gift_ready, gift_claimed and achievement_unlocked; nothing exercised them,
and the critic's rubric held every round at 6/10. All with FakeLLM."""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path

from forge import dashboard, director, testable
from forge.config import load_settings
from forge.llm import FakeLLM
from forge.memory import RunStore

PARK_KITS = ["ObbyKit", "ObbyThemes", "MusicPlayer", "Cosmetics", "CosmeticsClient", "WorldKit", "ParkObby"]
# the acceptance of runs/i-want-a-100-stage-obby (Oct 25), the run that held 6/10 for 4 rounds
PARK_ACCEPTANCE = [
    "The park is built from parts at startup and server counter stages_built is at least 1 within 3 s",
    "Walking the lobby coin trail bumps coin_collected at least 3 times",
    "Buying the 15-coin Party Hat bumps costume_buy and auto-equip bumps costume_equip",
    "Touching stage checkpoint 1 bumps checkpoint_reached and the HUD label reads 'Stage 1/100'",
    "The first jump pad bumps jump_pad_used and the trampoline before stage 4 bumps trampoline_bounce",
    "Falling or touching a kill brick bumps player_fell or player_died and respawns the player",
    "Clearing a zone bumps zone_cleared, and reaching stage 100 bumps obby_finished and park_finished",
    "Gift ready bumps gift_ready once per transition, claiming bumps gift_claimed, unlocking an achievement bumps "
    "achievement_unlocked, and ParkExtras.selfTest runs without errors",
    "The HUD shows stage, zone name, coins and reset button, and no errors appear in the output",
]


def park_spec(**over) -> dict:
    return {"modules": [{"path": f"ReplicatedStorage/Kit/{k}.luau", "kit": k, "prebuilt": True} for k in PARK_KITS]
            + [{"path": "ServerScriptService/ParkExtras.luau", "purpose": "timed gift and achievements"}],
            "acceptance": list(PARK_ACCEPTANCE), **over}


def test_every_kit_counter_has_a_mapped_exerciser():
    fired = set(director.kit_counters([e for e in director.kit_index() if e["name"] in PARK_KITS]))
    assert fired == set(testable.KIT_TESTS)  # a new kit counter must say how it is exercised
    spec = park_spec()
    paths = {c: testable.exerciser(c, spec)[0] for c in fired | set(testable.UNTESTED)}
    assert paths["stages_built"] == paths["coin_collected"] == paths["checkpoint_reached"] == testable.HEADLESS
    assert paths["trampoline_bounce"] == paths["player_died"] == testable.QA_BOTS
    for c in ("ride_gate_used", "zone_cleared", "ride_entrance_used", "obby_finished", "park_finished",
              "costume_buy", "costume_equip"):
        assert paths[c] == testable.JOURNEY, c
    for c in ("gift_ready", "gift_claimed", "achievement_unlocked", "ride_entrance_locked", "reset_used"):
        assert paths[c] == "", c


def test_kit_counters_need_their_kit_and_invented_obby_counters_have_no_exerciser():
    no_shop = {"modules": [{"kit": "ObbyKit"}]}
    assert testable.exerciser("costume_buy", no_shop)[0] == ""
    assert "no Cosmetics kit module" in testable.exerciser("costume_buy", no_shop)[1]
    assert testable.exerciser("pet_hatched", no_shop)[0] == ""
    # a game without the obby kit: the smoke's generic pass (UI, pickups, prompts, touches) plays its counters
    assert testable.exerciser("pet_hatched", {"modules": []})[0] == testable.HEADLESS
    assert testable.exerciser("achievement_unlocked", {"modules": []})[0] == ""


def test_restrict_drops_untested_clauses_and_records_each_one():
    spec = testable.restrict(park_spec())
    assert len(spec["acceptance"]) == 8
    assert not any(c in " ".join(spec["acceptance"]) for c in ("gift_ready", "gift_claimed", "achievement"))
    assert PARK_ACCEPTANCE[2] in spec["acceptance"] and PARK_ACCEPTANCE[5] in spec["acceptance"]
    dropped = spec["acceptance_untested"]
    assert [d["counters"] for d in dropped] == [["gift_ready"], ["gift_claimed"], ["achievement_unlocked"], []]
    assert "timed wait" in dropped[0]["reason"] and dropped[3]["criterion"] == "ParkExtras.selfTest runs without errors"
    again = testable.restrict(json.loads(json.dumps(spec)))
    assert again["acceptance"] == spec["acceptance"] and again["acceptance_untested"] == dropped  # idempotent


def test_restrict_keeps_the_testable_part_of_a_mixed_line_and_blanks_untested_beats():
    spec = park_spec(acceptance=["Reaching stage 10 bumps zone_cleared, and the badge bumps achievement_unlocked"],
                     first_60s=[{"t": 3, "beat": "spawn", "counter": "stages_built", "min": 1},
                                {"t": 40, "beat": "claim the gift", "counter": "gift_claimed", "min": 1}])
    out = testable.restrict(spec)
    assert out["acceptance"] == ["Reaching stage 10 bumps zone_cleared"]
    assert [b["counter"] for b in out["first_60s"]] == ["stages_built", ""]
    assert out["first_60s"][1]["beat"] == "claim the gift"
    assert {d["criterion"] for d in out["acceptance_untested"]} == {
        "the badge bumps achievement_unlocked", "first 60 seconds: claim the gift"}


def test_restrict_leaves_a_game_without_the_obby_kit_alone():
    spec = {"modules": [], "acceptance": ["buying a dropper bumps item_bought", "rebirth bumps rebirth_done"]}
    out = testable.restrict(json.loads(json.dumps(spec)))
    assert out["acceptance"] == spec["acceptance"] and "acceptance_untested" not in out


def test_director_and_designer_are_told_which_counters_are_testable():
    kits = director.match_kit_modules("i want a 100 stage amusement park obby")
    block = testable.testable_block(kits)
    assert "Studio journey: costume_buy" in block and "Studio QA bots: player_died, trampoline_bounce" in block
    assert "Nothing exercises: reset_used, ride_entrance_locked, achievement_unlocked, gift_claimed" in block
    assert testable.testable_block(director.match_kit_modules("a cube tycoon")) == ""
    doc = {"fantasy": "a park obby", "core_loop": "run the park", "progression": [], "systems": [], "juice": [],
           "first_60_seconds": [{"t": 3, "beat": "spawn", "counter": "stages_built", "min": 1}], "rewards": [],
           "visual_style": {}, "sounds": [], "module_budget": 3, "acceptance": []}
    tpl = next(e for e in kits if e.get("template"))
    spec = {"title": "Park", "slug": "park", "pitch": "p", "core_loop": "c",
            "modules": [{"path": f, "purpose": "rendered", "depends": []} for f in tpl["template"]["files"]]
            + [{"path": "ServerScriptService/ParkExtras.luau", "purpose": "gift and achievements", "depends": []}],
            "acceptance": ["checkpoint 1 bumps checkpoint_reached", "the gift bumps gift_claimed"]}
    llm = FakeLLM({"director": [json.dumps(doc)], "designer": [json.dumps(spec)]})
    out = director.plan(llm, "i want a 100 stage amusement park obby", "", session_id="g")
    assert all("## Acceptance a playtest can test" in c.user for c in llm.calls)
    assert out["acceptance"][0] == "checkpoint 1 bumps checkpoint_reached"
    assert not any("gift_claimed" in a for a in out["acceptance"])
    assert out["acceptance_untested"][0]["counters"] == ["gift_claimed"]


def test_profile_counts_testable_acceptance_and_qa_bots():
    spec = park_spec()
    it = {"score": 6, "acceptance": {"met": ["stages_built", "zone_cleared"],
                                     "missing": ["costume_buy", "gift_ready", "achievement_unlocked"]}}
    qa = {"bots": [{"reached": True}, {"reached": True}, {"reached": False}]}
    p = testable.profile(spec, it, qa, 0)
    assert p == {"score": 6, "errors": 0, "acceptance": {"met": 2, "total": 3}, "qa": {"reached": 2, "total": 3}}
    assert testable.profile_text(p) == "score 6/10, acceptance 2/3, QA 2/3, 0 errors"
    assert testable.profile_text(testable.profile({}, {"score": 5}, None, 1)) == "score 5/10, 1 error"
    assert testable.game_errors({"errors": ["ServerScriptService/ForgeTest.server.luau:2151: nil", "Game: x"]}) == 1


def test_dashboard_game_card_carries_the_profile_from_disk(tmp_path):
    settings = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(settings, "park")
    store.ensure()
    store.save_spec(park_spec(title="Park"))
    state = store.new_state("a park obby")
    state["iterations"] = [{"n": 1, "score": 6, "errors": ["ServerScriptService/ForgeTest.server.luau:1: nil"],
                            "acceptance": {"met": ["zone_cleared"], "missing": ["gift_ready", "costume_buy"]}}]
    store.save_state(state)
    (store.dir / "qa_latest.json").write_text(json.dumps({"bots": [{"reached": True}, {"reached": False}]}))
    assert dashboard.game_view(settings, "park")["profile"] == {
        "score": 6, "errors": 0, "acceptance": {"met": 1, "total": 2}, "qa": {"reached": 1, "total": 2}}
    store.save_state(store.new_state("a park obby"))
    assert dashboard.game_view(settings, "park")["profile"] is None
    html = (Path(dashboard.__file__).parent / "dashboard.html").read_text(encoding="utf-8")
    assert "${profileChip(g.profile)}" in html
