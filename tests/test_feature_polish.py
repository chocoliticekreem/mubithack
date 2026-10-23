"""Feature -> polish: end-to-end cycles that judge the whole game against its acceptance list."""

from __future__ import annotations

import json

from forge.feature import polish_feature
from forge.improve import audit_message
from forge.llm import FakeLLM
from forge.memory import RunStore
from test_fix_loop import _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply


def test_auditor_sees_the_acceptance_list():
    msg = audit_message({"pitch": "p", "core_loop": "c", "acceptance": ["players earn pass XP in rounds"]}, "", [])
    assert "Acceptance checks the game must meet" in msg and "players earn pass XP in rounds" in msg


async def test_polish_runs_cycles_until_clean_and_checks_feature_counters(settings):
    _seeded_game(settings)
    store = RunStore(settings, "fab")
    spec = store.load_spec()
    spec["features"] = [{"request": "battle pass", "plan": {"telemetry": ["bp_xp"]}}]
    spec["acceptance"] = ["players earn pass XP in rounds"]
    store.save_spec(spec)
    rounds = iter([{"bp_xp": 0}, {"bp_xp": 5}])

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        return {"goal": goal, "counters": next(rounds)}

    high = {"kind": "broken_link", "system": "pass", "title": "pass XP never awarded", "expected": "e",
            "observed": "bp_xp 0", "severity": "high"}
    llm = FakeLLM({"auditor": [audit_reply([high]), audit_reply([])],
                   "fixer": ["```luau\nreturn {hose = 2}\n```"],
                   "verifier": [json.dumps({"verdict": "not_fixed", "evidence": "e"})] * 2,
                   "reflector": ["# L\n"]})
    cycles = await polish_feature(settings, "fab", cycles=3, playtest=playtest, harness=FakeHarness(), llm=llm,
                                  log=lambda _: None)
    assert len(cycles) == 2  # stopped once nothing high/medium was open
    assert cycles[0]["feature_verified"] is False and cycles[1]["feature_verified"] is True
    assert "players earn pass XP in rounds" in [c.user for c in llm.calls if c.role == "auditor"][0]
