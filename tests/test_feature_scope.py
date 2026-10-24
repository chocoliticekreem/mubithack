"""Feature-scoped polish: only the feature's anomalies are fixed; the rest becomes a backlog."""

from __future__ import annotations

import json

from forge.feature import feature_focus
from forge.improve import run_cycle
from forge.llm import FakeLLM
from test_fix_loop import HOSE, _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply

FEATURE = {"request": "game passes, like a battle pass",
           "plan": {"new_modules": [{"path": "ServerScriptService/Services/BattlePassService.luau"}],
                    "telemetry": ["battlepass_xp_awarded"]}}
PASS = {"kind": "broken_link", "system": "battle pass", "title": "Tier rewards never claimable",
        "expected": "e", "observed": "battlepass_claims absent", "severity": "high"}


def test_focus_matches_the_feature_not_the_rest_of_the_game():
    belongs = feature_focus(FEATURE)
    assert belongs(PASS)
    assert belongs({**HOSE, "title": "XP not awarded", "observed": "battlepass_xp_awarded 0"})
    assert not belongs(HOSE)  # a hose bug is not the battle pass's job
    assert not belongs({**HOSE, "title": "Gear rack prompts never trigger", "system": "inventory"})


async def test_cycle_fixes_only_focused_anomalies(settings):
    _seeded_game(settings)
    llm = FakeLLM({"auditor": [audit_reply([HOSE, PASS])],
                   "fixer": ["```luau\nreturn {hose = 2}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        return {"goal": goal, "counters": {"a": 1}}

    async def resync(root):
        pass

    cycle = await run_cycle(settings, "fab", llm=llm, harness=FakeHarness(), playtest=playtest, faults=[],
                            goal="g", rounds=1, fix=True, resync=resync, log=lambda _: None,
                            focus=feature_focus(FEATURE))
    assert [f["anomaly"] for f in cycle["code_fixes"]] == [PASS["title"]]
    assert [a["title"] for a in cycle["backlog"]] == [HOSE["title"]]
    assert cycle["open"] == 1
