"""General guards on fixes, and learning from rejected ones (found when a kept fix gutted a 1,400-line file)."""

from __future__ import annotations

import json

from forge import improve as imp
from forge.improve import ImproveStore, run_cycle
from forge.llm import FakeLLM
from forge.memory import read_lessons
from test_fix_loop import HOSE, HOSE_FILE, _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply
from test_investigator import FakeStudio, StudioHarness

BIG = "\n".join(f"local part{i} = {i}" for i in range(200)) + "\nreturn {}\n"


def _big_game(settings):
    game = _seeded_game(settings)
    (game / HOSE_FILE).write_text(BIG)
    return game


def _playtests(counters_per_round):
    rounds = iter(counters_per_round)

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        return {"goal": goal, "counters": next(rounds), "probe": {"errors": []}}
    return playtest


async def _cycle(settings, llm, playtest, harness=None):
    synced = []

    async def resync(root):
        synced.append(True)

    cycle = await run_cycle(settings, "fab", llm=llm, harness=harness or FakeHarness(), playtest=playtest,
                            faults=[], goal="play", rounds=1, fix=True, resync=resync, log=lambda _: None,
                            repro=False)
    return cycle, synced


def test_destructive_detects_rewrites_but_allows_local_edits():
    local = BIG.replace("local part5 = 5", "local part5 = 50")
    assert imp.destructive(BIG, local) is None
    gutted = "\n".join(BIG.splitlines()[:20])
    assert "removed" in imp.destructive(BIG, gutted)
    small = "a\nb\nc\n"
    assert imp.destructive(small, "x\n") is None  # tiny files can be rewritten


async def test_destructive_fix_is_rejected_unseen_and_the_fixer_is_told_why(settings):
    game = _big_game(settings)
    gutted = "\n".join(BIG.splitlines()[:20])
    llm = FakeLLM({"auditor": [audit_reply([HOSE])],
                   "fixer": [f"```luau\n{gutted}\n```", f"```luau\n{BIG.replace('part5 = 5', 'part5 = 6')}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})
    cycle, synced = await _cycle(settings, llm, _playtests([{"a": 1}, {"a": 1}]))
    fx = cycle["code_fixes"][0]
    assert [t["status"] for t in fx["attempts"]] == ["too_destructive", "fixed"] and fx["status"] == "kept"
    assert "removed" in [c.user for c in llm.calls if c.role == "fixer"][1]
    assert len(synced) == 1  # the destructive attempt never reached Studio
    assert "part5 = 6" in (game / HOSE_FILE).read_text()


async def test_lost_counters_are_flags_not_an_overrule(settings):
    game = _big_game(settings)
    local = BIG.replace("part5 = 5", "part5 = 6")
    llm = FakeLLM({"auditor": [audit_reply([HOSE])], "fixer": [f"```luau\n{local}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "fire_cap_hit went away, as intended"})]})
    cycle, _ = await _cycle(settings, llm, _playtests([{"fire_cap_hit": 62}, {"other": 1}]))
    assert cycle["code_fixes"][0]["status"] == "kept"
    msg = next(c.user for c in llm.calls if c.role == "verifier")
    assert "## Flagged changes" in msg and "fire_cap_hit went from 62" in msg


async def test_new_server_errors_overrule_a_fixed_verdict(settings):
    _big_game(settings)
    local = BIG.replace("part5 = 5", "part5 = 6")

    def rounds():
        yield {"goal": "g", "counters": {"a": 1}, "probe": {"errors": []}}
        while True:
            yield {"goal": "g", "counters": {"a": 1}, "probe": {"errors": [{"message": "boom"}]}}
    it = rounds()

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        return next(it)

    llm = FakeLLM({"auditor": [audit_reply([HOSE])], "fixer": [f"```luau\n{local}\n```"] * 2,
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "looks fine"})] * 2, "reflector": ["# L\n"]})
    cycle, _ = await _cycle(settings, llm, playtest)
    assert cycle["code_fixes"][0]["attempts"][0]["status"] == "regression"


def test_telemetry_changes_flags_only_lost_counters_and_new_errors():
    before = [{"counters": {"a": 5, "b": 0, "c": 3}, "errors": {"count": 0}}]
    after = [{"counters": {"a": 9, "b": 0}, "errors": {"count": 2}}]
    table, hard = imp.telemetry_changes(before, after)
    assert "- c: 3 -> absent" in table
    assert hard == ["counter c went from 3 to absent", "server errors rose from 0 to 2"]


async def test_rejected_fixes_become_general_lessons(settings):
    _big_game(settings)
    local = BIG.replace("part5 = 5", "part5 = 6")
    llm = FakeLLM({"auditor": [audit_reply([HOSE])],
                   "fixer": [f"```luau\n{local}\n```"] * 2,
                   "verifier": [json.dumps({"verdict": "not_fixed", "evidence": "still broken"})] * 2,
                   "reflector": ["# Lessons\n- Keep fixes local.\n"]})
    await _cycle(settings, llm, _playtests([{"a": 1}] * 3))
    msg = next(c.user for c in llm.calls if c.role == "reflector")
    assert "not to this game's names" in msg and "still broken" in msg
    assert "Keep fixes local" in read_lessons(settings)


async def test_no_rejections_means_no_reflection(settings):
    _big_game(settings)
    local = BIG.replace("part5 = 5", "part5 = 6")
    llm = FakeLLM({"auditor": [audit_reply([HOSE])], "fixer": [f"```luau\n{local}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})
    await _cycle(settings, llm, _playtests([{"a": 1}] * 2))
    assert "reflector" not in [c.role for c in llm.calls]


async def test_investigator_is_corrected_after_its_fix_is_rejected(settings):
    _big_game(settings)
    local = BIG.replace("part5 = 5", "part5 = 6")
    concl = json.dumps({"action": "conclude", "root_cause": "rc", "file": HOSE_FILE, "evidence": "e", "fix_hint": "h"})
    llm = FakeLLM({"auditor": [audit_reply([HOSE])], "investigator": [concl, concl],
                   "fixer": [f"```luau\n{local}\n```"] * 2,
                   "verifier": [json.dumps({"verdict": "not_fixed", "evidence": "still broken"})] * 2,
                   "reflector": ["# L\n"]})
    cycle, _ = await _cycle(settings, llm, _playtests([{"a": 1}] * 3), harness=StudioHarness(FakeStudio([])))
    inv = [c.user for c in llm.calls if c.role == "investigator"]
    assert len(inv) == 2 and "## Verified outcome" in inv[1] and "still broken" in inv[1]
    assert cycle["code_fixes"][0]["reinvestigation"]["conclusion"]["root_cause"] == "rc"
    assert ImproveStore(settings, "fab").scores()[0]["code_kept"] == 0
