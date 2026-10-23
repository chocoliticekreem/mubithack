"""Spend the fix budget on fixable bugs: time limits, unproven skips, 'no edits', and ordering."""

from __future__ import annotations

import asyncio
import json

from forge import improve as imp
from forge.improve import ImproveStore, run_cycle
from forge.llm import FakeLLM
from test_fix_loop import HOSE, _seeded_game, settings  # noqa: F401
from test_improve import audit_reply
from test_investigator import FakeStudio, StudioHarness
from test_patcher import BIG

OTHER = {**HOSE, "title": "HUD shows the wrong fire count", "system": "hud"}


def _concl(root_cause, file="ServerScriptService/Services/HoseService.luau"):
    return json.dumps({"action": "conclude", "root_cause": root_cause, "file": file, "evidence": "e", "fix_hint": "h"})


async def _cycle(settings, llm, playtest=None):
    async def default(settings_, goal, players, steps, *, llm, harness):
        return {"goal": goal, "counters": {"a": 1}}

    async def resync(root):
        pass

    return await run_cycle(settings, "fab", llm=llm, harness=StudioHarness(FakeStudio([])),
                           playtest=playtest or default, faults=[], goal="play", rounds=1, fix=True,
                           resync=resync, log=lambda _: None, max_fixes=2)


def test_unproven_markers():
    f = "ReplicatedStorage/Config/FireConfig.luau"
    assert imp.unproven({"root_cause": "Most likely a testing artefact, not a game bug", "file": f})
    assert imp.unproven({}) and imp.unproven({"root_cause": "x", "file": None})
    assert not imp.unproven({"root_cause": "HudController reads FireCount before MissionService sets it", "file": f})
    # run 9: a concrete cause phrased as a negation was skipped
    assert not imp.unproven({"root_cause": "Delivery never fires. This is a game bug, not a testing artefact.",
                             "file": f})
    # plausible but unproven causes get one attempt (run 8 skipped all four of these)
    assert not imp.unproven({"root_cause": "Probably a balance problem in the fire numbers, though I could "
                                           "not fully prove it", "file": f})


async def test_unproven_anomaly_is_skipped_and_the_next_one_is_fixed(settings):
    _seeded_game(settings)
    llm = FakeLLM({"auditor": [audit_reply([HOSE, OTHER])],
                   "investigator": [_concl("Most likely a testing artefact: prompts look fine"),
                                    _concl("HUD reads the counter before it is set")],
                   "fixer": ["```luau\nreturn {hose = 2}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})
    cycle = await _cycle(settings, llm)
    assert [f["status"] for f in cycle["code_fixes"]] == ["unproven", "kept"]
    assert [c.role for c in llm.calls].count("fixer") == 1  # no budget spent on the unproven one
    assert ImproveStore(settings, "fab").was_unproven(HOSE)


async def test_previously_unproven_anomalies_go_last(settings):
    _seeded_game(settings)
    ImproveStore(settings, "fab").mark_unproven(HOSE)
    llm = FakeLLM({"auditor": [audit_reply([HOSE, OTHER])],
                   "investigator": [_concl("HUD reads the counter before it is set"), _concl("a testing artefact")],
                   "fixer": ["```luau\nreturn {hose = 2}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})
    cycle = await _cycle(settings, llm)
    assert cycle["code_fixes"][0]["anomaly"] == OTHER["title"]


async def test_patcher_no_edits_means_no_fix_needed_without_a_retry(settings):
    game = _seeded_game(settings)
    (game / "ServerScriptService/Services/HoseService.luau").write_text(BIG)
    llm = FakeLLM({"auditor": [audit_reply([HOSE])],
                   "investigator": [_concl("The hose handler returns early when Water is nil")],
                   "patcher": [json.dumps({"summary": "nothing to change", "edits": []})]})
    cycle = await _cycle(settings, llm)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "no_fix_needed" and len(fx["attempts"]) == 1
    assert [c.role for c in llm.calls].count("patcher") == 1


async def test_a_stalled_round_times_out_as_a_failed_check(settings, monkeypatch):
    monkeypatch.setattr(imp, "ROUND_TIMEOUT", 0.05)

    async def stalls(settings_, goal, players, steps, *, llm, harness):
        await asyncio.sleep(5)

    [d] = await imp._rounds(settings, stalls, 1, 1, goal="g", players=None, steps=1, llm=None, harness=None)
    assert d["errors"]["count"] == 1 and "timed out" in d["errors"]["first"][0]
