"""The self-improving loop: digests, scoring against planted faults, corrections, verification."""

from __future__ import annotations

import dataclasses
import json

import pytest

from forge.config import load_settings
from forge.improve import (
    ImproveStore, clear, default_faults, load_faults, matches, plant, round_digest, run_cycle, score,
)
from forge.llm import FakeLLM, load_prompt

FAULTS = [
    {"id": "dry", "module": "ToolConfig", "key": "LitresPerSpray", "value": 100,
     "systems": ["water"], "match": ["empty", "drain"], "symptom": "tank empties after one spray",
     "lesson": "one spray emptying the tank is a broken water economy"},
    {"id": "nospread", "module": "FireConfig", "key": "SpreadHeatPerSecond", "value": 0,
     "systems": ["fire"], "match": ["spread"], "symptom": "fires_spread is 0 every round",
     "lesson": "fires_spread at 0 every round means spread is off"},
]


class FakeHarness:
    def __init__(self):
        self.config = {("ToolConfig", "LitresPerSpray"): 1.2, ("FireConfig", "SpreadHeatPerSecond"): 14}
        self.ready = 0

    async def ensure_ready(self):
        self.ready += 1
        return {"ok": True}

    async def call(self, cmd, **args):
        assert cmd == "config"
        k = (args["module"], args["key"])
        old = self.config[k]
        self.config[k] = args["value"]
        return {"module": k[0], "key": k[1], "value": args["value"], "old": old}


def fake_playtest(log):
    async def playtest(settings, goal, players, steps, *, llm, harness):
        log.append(dict(harness.config))
        return {"goal": goal, "goal_met": False, "players": [{}, {}],
                "counters": {"water_used": 100, "fires_spread": 0},
                "probe": {"errors": [{"message": "boom"}]}, "bugs": [{"title": "hose dry", "severity": "high"}],
                "events": [{"kind": "tool"}, {"kind": "tool"}, {"kind": "prompt"}]}
    return playtest


def audit_reply(anomalies):
    return json.dumps({"summary": "s", "anomalies": anomalies})


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def test_prompts_exist_and_roles_are_registered():
    assert "auditor" in load_prompt("auditor").lower()
    assert "verifier" in load_prompt("verifier").lower()


def test_round_digest_is_compact_and_code_free():
    d = round_digest({"goal": "g", "goal_met": True, "players": [1, 2, 3], "counters": {"rescued": 2},
                      "probe": {"errors": [{"message": "x" * 500}, "plain", None, "a", "b"]},
                      "bugs": [{"title": "t", "severity": "low", "evidence": "long"}],
                      "events": [{"kind": "a"}, {"kind": "a"}, "junk"], "steps": [{"huge": 1}]}, 4)
    assert d["round"] == 4 and d["players"] == 3 and d["counters"] == {"rescued": 2}
    assert d["errors"]["count"] == 4 and len(d["errors"]["first"]) == 3
    assert len(d["errors"]["first"][0]) == 200
    assert d["bugs"] == [{"title": "t", "severity": "low"}]
    assert d["events"] == {"a": 2}
    assert "steps" not in d


def test_round_digest_handles_empty_report():
    d = round_digest({}, 1)
    assert d["errors"] == {"count": 0, "first": []} and d["counters"] == {} and d["bugs"] == []


def test_matches_needs_system_and_keyword():
    a = {"system": "water", "title": "Tank drains", "expected": "", "observed": ""}
    assert matches(a, FAULTS[0])
    assert not matches({**a, "system": "fire"}, FAULTS[0])
    assert not matches({**a, "title": "Hose fine"}, FAULTS[0])


def test_score_counts_detected_missed_and_unmatched():
    anomalies = [{"system": "water", "title": "tank empty", "expected": "", "observed": ""},
                 {"system": "doors", "title": "door stuck", "expected": "", "observed": ""}]
    sc = score(anomalies, FAULTS)
    assert sc["detected"] == ["dry"] and sc["missed"] == ["nospread"]
    assert sc["anomaly_for"] == {"dry": 0} and sc["unmatched_anomalies"] == [1]


async def test_plant_and_clear_restore_old_values():
    h = FakeHarness()
    old = await plant(h, FAULTS)
    assert h.config[("ToolConfig", "LitresPerSpray")] == 100 and old == {"dry": 1.2, "nospread": 14}
    await clear(h, FAULTS, old)
    assert h.config == FakeHarness().config


async def test_plant_rejects_two_faults_on_one_key():
    with pytest.raises(ValueError):
        await plant(FakeHarness(), [FAULTS[1], {**FAULTS[1], "id": "other", "value": 300}])


def test_default_faults_and_only():
    fs = [*FAULTS, {**FAULTS[1], "id": "wild", "default": False}]
    assert [f["id"] for f in default_faults(fs)] == ["dry", "nospread"]
    assert [f["id"] for f in default_faults(fs, ["wild"])] == ["wild"]
    with pytest.raises(ValueError):
        default_faults(fs, ["nope"])


def test_shipped_fault_catalogue_loads():
    faults = load_faults("flame-and-blame")
    assert len(faults) >= 4
    picked = default_faults(faults)
    assert len({(f["module"], f["key"]) for f in picked}) == len(picked)


async def test_cycle_scores_corrects_fixes_and_verifies(settings):
    seen: list[dict] = []
    detected = [{"kind": "economy", "system": "water", "title": "Tank drains at once", "expected": "e",
                 "observed": "o", "severity": "high"}]
    llm = FakeLLM({
        "auditor": [audit_reply(detected), audit_reply(detected + [
            {"kind": "balance", "system": "fire", "title": "Fire never spreads", "severity": "high"}])],
        "verifier": [json.dumps({"verdict": "fixed", "evidence": "water_used normal"})],
    })
    h = FakeHarness()
    cycle = await run_cycle(settings, "fab", llm=llm, harness=h, playtest=fake_playtest(seen),
                            faults=FAULTS, goal="play", rounds=2, log=lambda _: None)

    roles = [c.role for c in llm.calls]
    assert roles == ["auditor", "auditor", "verifier"]
    assert "## Verified outcome" not in llm.calls[0].user
    assert "fires_spread is 0 every round" in llm.calls[1].user
    assert "LitresPerSpray set back to 1.2" in llm.calls[2].user
    assert len({c.session_id for c in llm.calls}) == 1

    # 2 rounds with both faults planted, then 1 round with only the detected one fixed
    assert [r[("ToolConfig", "LitresPerSpray")] for r in seen] == [100, 100, 1.2]
    assert seen[2][("FireConfig", "SpreadHeatPerSecond")] == 0
    assert h.config == FakeHarness().config  # every fault cleared at the end

    assert (cycle["detected"], cycle["missed"], cycle["fixed_verified"]) == (1, 1, 1)
    store = ImproveStore(settings, "fab")
    assert store.scores()[0]["cycle"] == 1
    assert "spread is off" in store.playbook() and "water economy" not in store.playbook()


async def test_second_cycle_reads_playbook_and_numbers_up(settings):
    llm = FakeLLM({"auditor": [audit_reply([])] * 4})
    for _ in range(2):
        await run_cycle(settings, "fab", llm=llm, harness=FakeHarness(), playtest=fake_playtest([]),
                        faults=FAULTS, goal="play", rounds=1, log=lambda _: None)
    assert [r["cycle"] for r in ImproveStore(settings, "fab").scores()] == [1, 2]
    assert "spread is off" in llm.calls[2].user  # cycle 2's audit sees cycle 1's lessons
    assert llm.calls[0].session_id != llm.calls[2].session_id


async def test_faults_cleared_even_when_a_round_fails(settings):
    async def broken(*a, **k):
        raise RuntimeError("studio gone")
    h = FakeHarness()
    with pytest.raises(RuntimeError):
        await run_cycle(settings, "fab", llm=FakeLLM({}), harness=h, playtest=broken,
                        faults=FAULTS, goal="play", rounds=1, log=lambda _: None)
    assert h.config == FakeHarness().config
