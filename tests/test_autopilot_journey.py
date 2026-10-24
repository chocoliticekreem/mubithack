"""Autopilot and the hard gates: dead interactions and failed journey steps are full-confidence fix jobs, and a
version that adds a dead interaction or loses a journey step is rolled back."""

from __future__ import annotations

import json
import shutil

import pytest

from forge import autopilot as ap
from forge import journey as fjourney
from test_autopilot import FakeRunner, _ap, _anoms, _game, _gaps, _llm, _measure, _settings, fast  # noqa: F401
from test_interactions import SHOP

REF = "dead:ServerScriptService/Shop.luau:prompt_no_handler:ProximityPrompt-ChangingRoomPrompt-Try-on-costumes"
DEAD = {"kind": "dead_interaction", "system": "interactions", "severity": "high",
        "title": '[interactions] ProximityPrompt "ChangingRoomPrompt" at ServerScriptService/Shop.luau:196 does nothing',
        "observed": "nothing connects its Triggered", "expected": "connect its Triggered", "path": "ServerScriptService/Shop.luau",
        "proof": "static interaction audit: Shop.luau:196", "ref": REF}


def test_a_dead_interaction_becomes_a_full_confidence_fix_job_that_is_picked():
    a = ap.hard_anomaly(DEAD)
    assert a["id"].startswith("an-dead") and a["confidence"] == 1.0 and a["evidence"] == [DEAD["ref"]]
    assert a["job"] == {"kind": "fix", "request": "nothing connects its Triggered Expected: connect its Triggered",
                        "path": "ServerScriptService/Shop.luau"}
    assert ap.hard_anomaly(DEAD)["id"] == a["id"]  # stable across rounds, so a developer can reject it
    # two objects of one file whose refs share a long prefix still get their own ids
    other = ap.hard_anomaly({**DEAD, "ref": REF.replace("Try-on-costumes", "Ring-the-bell")})
    assert other["id"] != a["id"] and len(a["id"]) <= 3 + 48 + 7
    picked = ap.decide(ap.candidates([a], []), per_round=1, min_rank=2.0, calls_left=None)
    assert picked[0]["picked"] and picked[0]["kind"] == "fix"


def test_the_gate_rolls_back_a_new_dead_interaction_or_a_lost_journey_step():
    before = {"dead": 1, "journey": {"ok": False, "passing": ["join", "prompts"], "failing": ["costume"]}}
    after = {"dead": 2, "journey": {"ok": False, "passing": ["join", "costume"], "failing": ["prompts"]}}
    g = ap.gate(before, after)
    assert g["verdict"] == "rolled_back"
    assert "dead interactions 1 -> 2" in g["regressions"]
    assert "journey steps that passed now fail: prompts" in g["regressions"]
    assert "journey steps now pass: costume" in g["improvements"]
    g = ap.gate(after | {"journey": before["journey"] | {"failing": []}, "dead": 0}, {"dead": 0, "journey": {
        "passing": ["join", "prompts", "costume"], "failing": []}})
    assert g["verdict"] == "kept"


@pytest.mark.skipif(shutil.which("luau-ast") is None, reason="luau-ast not on PATH")
def test_autopilot_puts_the_dead_prompt_first_and_runs_its_fix_job(tmp_path, monkeypatch):
    monkeypatch.setenv("FORGE_JOURNEY", "1")
    s = _settings(tmp_path)
    run = _game(s)
    (run / "game" / "ServerScriptService" / "Shop.luau").write_text(SHOP)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins feel slow", 4, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    runner = FakeRunner(run)
    _ap(s, "g", llm, _measure({}), tmp_path, runner=runner, rounds=1, per_round=1).run()
    rdir = run / "autopilot" / "rounds" / "1"
    det = json.loads((rdir / "detect.json").read_text())
    first = det["anomalies"][0]
    ref = "dead:ServerScriptService/Shop.luau:prompt_no_handler:ProximityPrompt-ChangingRoomPrompt-Try-on-costumes"
    assert first["evidence"] == [ref] and first["confidence"] == 1.0
    assert first["job"]["path"] == "ServerScriptService/Shop.luau"
    items = json.loads((rdir / "evidence.json").read_text())["items"]
    assert ref in [i["id"] for i in items]
    decided = json.loads((rdir / "decide.json").read_text())
    assert decided["picked"] == [first["id"]] and runner.calls and runner.calls[0][0] == "fix"


def _confirm_round(tmp_path, after_journey, again):
    """One round whose only regression is a journey step that passed in the baseline and failed after."""
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins feel slow", 7, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    base = {"journey": {"ok": True, "passing": ["join", "prompts"], "failing": []}}
    measurer = _measure({(1, "baseline"): base, (1, "after"): {"engine": "headless", "journey": after_journey}})
    a = _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), rounds=1)
    runs = []

    def journeyer(apx, r):
        runs.append(r)
        return again

    a.journeyer = journeyer
    return a.run()["rounds"][0], measurer.seen, runs


LOST = {"ok": False, "passing": ["join"], "failing": ["prompts"]}


def test_a_journey_step_lost_once_is_confirmed_by_a_second_journey_before_a_rollback(tmp_path):
    rnd, seen, runs = _confirm_round(tmp_path, LOST, {"ok": True, "passing": ["join", "prompts"], "failing": []})
    assert runs == [1] and (1, "confirm") not in [(r, t) for r, t, _ in seen]  # only the journey ran again
    assert rnd["verdict"] == "kept"


def test_a_journey_step_that_fails_again_rolls_the_round_back(tmp_path):
    rnd, _, runs = _confirm_round(tmp_path / "b", LOST, LOST)
    assert runs == [1] and rnd["verdict"] == "rolled_back"
    assert any(str(x).startswith(ap.JOURNEY_LOST) for x in rnd["regressions"])


def test_confirm_keeps_a_step_failing_only_when_it_failed_both_times():
    got = fjourney.confirm({"ok": False, "passing": ["join"], "failing": ["prompts", "costume"]},
                           {"ok": False, "passing": ["join", "prompts"], "failing": ["costume"]})
    assert got["failing"] == ["costume"] and got["passing"] == ["join", "prompts"]
