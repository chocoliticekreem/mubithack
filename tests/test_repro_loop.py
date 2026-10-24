"""Reproduce first: the reproducer's failing check proves the bug, judges the fix and guards later fixes."""

from __future__ import annotations

import json
import shutil

import pytest

from forge import repro as frepro
from forge.checks import Check, load_checks, save_check
from forge.improve import ImproveStore, run_cycle
from forge.llm import FakeLLM, load_prompt
from test_fix_loop import HOSE, HOSE_FILE, _seeded_game, settings  # noqa: F401
from test_improve import FakeHarness, audit_reply

REPRO = "Spraying a fire cools it"
GUARD = "Hose still has water"


class CheckStudio:
    """Runs a check by its title: each rule reads the game folder and returns (ok, detail) or raises."""

    def __init__(self, game, rules):
        self.game, self.rules, self.ran = game, rules, []

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.ran.append(code)
        hose = (self.game / HOSE_FILE).read_text()
        for title, rule in self.rules.items():
            if f"-- check: {title}" in code:
                try:
                    ok, detail = rule(hose)
                except RuntimeError as e:
                    return json.dumps({"ok": False, "error": str(e)})
                return json.dumps({"ok": ok, "detail": detail})
        return "probe ok"


class StudioHarness(FakeHarness):
    def __init__(self, studio):
        super().__init__()
        self.studio = studio


SETUP = 'if not workspace then error("setup: no workspace") end\n'  # every check asserts its setup


def repro_reply(title=REPRO, body=SETUP + "return { ok = false, detail = 'x' }", consumer=f"{HOSE_FILE}:1"):
    head = f"-- consumer: {consumer}\n" if consumer else ""
    return f"```luau\n-- check: {title}\n-- covers: anomaly: {HOSE['title']}\n{head}{body}\n```"


def conclude():
    return json.dumps({"action": "conclude", "root_cause": "hose never lowers heat", "file": HOSE_FILE,
                       "evidence": "probe", "fix_hint": "lower heat"})


def llm_for(reproducer, fixer, verdicts, anomalies=(HOSE,), investigations=2):
    return FakeLLM({"auditor": [audit_reply(list(anomalies))], "investigator": [conclude()] * investigations,
                    "reproducer": list(reproducer), "fixer": [f"```luau\n{s}\n```" for s in fixer],
                    "verifier": [json.dumps({"verdict": v, "evidence": "e"}) for v in verdicts]})


def fixed(hose):
    return ("hose = 2" in hose, "heat " + ("falls" if "hose = 2" in hose else "stays 100"))


async def cycle_with(settings, llm, rules, game):
    seen = []

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        seen.append(goal)
        return {"goal": goal, "counters": {"sprays": 3}}

    async def resync(root):
        pass

    studio = CheckStudio(game, rules)
    cycle = await run_cycle(settings, "fab", llm=llm, harness=StudioHarness(studio), playtest=playtest,
                            faults=[], goal="play", rounds=1, fix=True, resync=resync, log=lambda _: None)
    return cycle, seen, studio


async def test_failing_check_then_fix_that_passes_it_is_kept_and_joins_the_suite(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply()], ["return {hose = 2}"], ["inconclusive"])
    cycle, seen, _ = await cycle_with(settings, llm, {REPRO: fixed}, game)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "kept" and fx["repro"]["before"]["ok"] is False
    assert (game / HOSE_FILE).read_text().strip() == "return {hose = 2}"
    fixer_msg = next(c.user for c in llm.calls if c.role == "fixer")
    assert "Failing check" in fixer_msg and "heat stays 100" in fixer_msg and f"-- check: {REPRO}" in fixer_msg
    run_dir = ImproveStore(settings, "fab").run.dir
    assert [c.title for c in load_checks(run_dir)] == [REPRO] and frepro.load_pending(run_dir) == []
    assert cycle["checks"]["kept"] == cycle["checks"]["written"] == ["spraying-a-fire-cools-it"]
    assert len(seen) == 2  # the audit round and the verifier's round after the fix
    assert fx["attempts"][0]["verdict"]["verdict"] == "inconclusive"  # the check overrode it
    assert ImproveStore(settings, "fab").scores()[0]["proven"] == 1


async def test_fix_that_leaves_the_check_failing_is_rolled_back_without_a_playtest(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply()], ["return {hose = 3}", "return {hose = 4}"], ["fixed", "fixed"])
    cycle, seen, _ = await cycle_with(settings, llm, {REPRO: fixed}, game)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "rolled_back"
    assert [t["status"] for t in fx["attempts"]] == ["check_failed", "check_failed"]
    assert (game / HOSE_FILE).read_text() == "return {hose = 1}\n"
    assert "verifier" not in [c.role for c in llm.calls] and len(seen) == 1
    retry = [c.user for c in llm.calls if c.role == "fixer"][1]
    assert "still fails after your fix" in retry and "heat stays 100" in retry
    run_dir = ImproveStore(settings, "fab").run.dir
    assert load_checks(run_dir) == [] and [c.title for c in frepro.load_pending(run_dir)] == [REPRO]


async def test_fix_that_breaks_another_saved_check_is_rolled_back(settings):
    game = _seeded_game(settings)
    run_dir = ImproveStore(settings, "fab").run.dir
    save_check(run_dir, Check("hose-still-has-water", GUARD, "acceptance: water", "return {ok = true}"))
    rules = {REPRO: lambda h: ("hose = 1" not in h, "heat"), GUARD: lambda h: ("hose = 3" not in h, "water 0")}
    llm = llm_for([repro_reply()], ["return {hose = 3}", "return {hose = 3}"], [])
    cycle, _, _ = await cycle_with(settings, llm, rules, game)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "rolled_back"
    assert [t["status"] for t in fx["attempts"]] == ["check_regression", "check_regression"]
    assert "broke checks that passed before" in [c.user for c in llm.calls if c.role == "fixer"][1]
    assert (game / HOSE_FILE).read_text() == "return {hose = 1}\n"
    assert cycle["checks"]["start_failing"] == [] and cycle["checks"]["kept"] == []


async def test_no_failing_check_means_unproven_and_no_fix(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply(), repro_reply("Spraying lowers heat")], [], [])
    cycle, _, _ = await cycle_with(settings, llm, {REPRO: lambda h: (True, "heat falls"),
                                                   "Spraying lowers heat": lambda h: (True, "heat falls")}, game)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "unproven" and [a["status"] for a in fx["repro"]["attempts"]] == ["passed"]
    # a passing check ends it: no retry that could invent a stricter expectation just to fail
    assert len([c for c in llm.calls if c.role == "reproducer"]) == 1
    assert "fixer" not in [c.role for c in llm.calls]
    assert ImproveStore(settings, "fab").was_unproven(HOSE)
    assert cycle["checks"]["unproven"] == [HOSE["title"]]


async def test_erroring_check_gets_one_retry_with_the_error(settings):
    game = _seeded_game(settings)

    def boom(h):
        raise RuntimeError("attempt to index nil with 'Cash'")

    llm = llm_for([repro_reply("Broken check"), repro_reply()], ["return {hose = 2}"], ["fixed"])
    cycle, _, _ = await cycle_with(settings, llm, {"Broken check": boom, REPRO: fixed}, game)
    fx = cycle["code_fixes"][0]
    assert [a["status"] for a in fx["repro"]["attempts"]] == ["errored", "proven"] and fx["status"] == "kept"
    assert "ERRORED: attempt to index nil" in [c.user for c in llm.calls if c.role == "reproducer"][1]


async def test_saved_check_failing_at_cycle_start_is_fixed_without_a_new_repro(settings):
    game = _seeded_game(settings)
    run_dir = ImproveStore(settings, "fab").run.dir
    frepro.save_pending(run_dir, Check("spraying-a-fire-cools-it", REPRO, "anomaly: hose", "return {ok = false}"))
    llm = llm_for([], ["return {hose = 2}"], ["not_fixed"], anomalies=())
    cycle, _, _ = await cycle_with(settings, llm, {REPRO: fixed}, game)
    assert cycle["checks"]["start_failing"] == ["spraying-a-fire-cools-it"]
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "kept" and fx["repro"]["source"] == "saved"
    assert "reproducer" not in [c.role for c in llm.calls]
    assert [c.id for c in load_checks(run_dir)] == ["spraying-a-fire-cools-it"] and frepro.load_pending(run_dir) == []


async def test_no_repro_keeps_the_old_investigator_gate(settings):
    game = _seeded_game(settings)
    llm = FakeLLM({"auditor": [audit_reply([HOSE])], "investigator": [conclude()],
                   "fixer": ["```luau\nreturn {hose = 2}\n```"],
                   "verifier": [json.dumps({"verdict": "fixed", "evidence": "e"})]})

    async def playtest(settings_, goal, players, steps, *, llm, harness):
        return {"goal": goal}

    async def resync(root):
        pass

    cycle = await run_cycle(settings, "fab", llm=llm, harness=StudioHarness(CheckStudio(game, {})),
                            playtest=playtest, faults=[], goal="play", rounds=1, fix=True, resync=resync,
                            log=lambda _: None, repro=False)
    assert cycle["code_fixes"][0]["status"] == "kept" and "reproducer" not in [c.role for c in llm.calls]
    assert cycle["repro"] is False


@pytest.mark.skipif(not shutil.which("luau-compile"), reason="luau-compile not on PATH")
def test_example_checks_compile_and_bad_ones_do_not():
    from forge.roles import _LUAU_FENCE

    bodies = [m.group(2) for m in _LUAU_FENCE.finditer(frepro.EXAMPLES)]
    assert len(bodies) == 2 and all(frepro.compile_error(b) is None for b in bodies)
    assert frepro.compile_error("local = = 1") is not None


def test_reproducer_prompt_and_message():
    assert "FAIL while the bug exists" in load_prompt("reproducer")
    msg = frepro.reproduce_message(HOSE, {"conclusion": {"root_cause": "rc", "file": HOSE_FILE}, "steps": []},
                                   "a.luau", {HOSE_FILE: "1| return {}"}, ("return {ok=true}", "PASSED"))
    for part in ("## Anomaly", "rc", "## Check contract", "## Example checks", "## Your previous check", "PASSED"):
        assert part in msg


# ---------------------------------------------------------------- premise: a proven bug names its consumer

REMOTES_BODY = (SETUP + 'local f = game:GetService("ReplicatedStorage"):FindFirstChild("Remotes")\n'
                'return { ok = f ~= nil, detail = "missing ReplicatedStorage.Remotes" }')


async def test_clean_fail_without_a_consumer_is_not_proven_and_retries_with_the_code_that_mentions_it(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply("Remotes exist", REMOTES_BODY, consumer=""),
                   repro_reply("Remotes exist", REMOTES_BODY, consumer="StarterPlayerScripts/Nope.luau:3")], [], [])
    cycle, _, _ = await cycle_with(settings, llm, {"Remotes exist": lambda h: (False, "missing")}, game)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "unproven"
    assert [a["status"] for a in fx["repro"]["attempts"]] == ["no_consumer", "no_consumer"]
    retry = [c.user for c in llm.calls if c.role == "reproducer"][1]
    assert "names no real consumer" in retry and '"Remotes": no game code mentions it' in retry
    assert "fixer" not in [c.role for c in llm.calls]
    assert frepro.load_pending(ImproveStore(settings, "fab").run.dir) == []


async def test_consumer_named_on_the_retry_proves_the_bug(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply(consumer=""), repro_reply(consumer=f"./{HOSE_FILE}:1")],
                  ["return {hose = 2}"], ["fixed"])
    cycle, _, _ = await cycle_with(settings, llm, {REPRO: fixed}, game)
    fx = cycle["code_fixes"][0]
    assert [a["status"] for a in fx["repro"]["attempts"]] == ["no_consumer", "proven"]
    assert fx["repro"]["attempts"][1]["consumer"] == f"{HOSE_FILE}:1" and fx["status"] == "kept"


def test_consumer_must_be_a_real_line_of_game_code(tmp_path):
    from forge.checks import valid_consumer

    (tmp_path / "ServerScriptService").mkdir()
    (tmp_path / "ServerScriptService" / "A.luau").write_text("a\nb\n")
    (tmp_path / "ServerScriptService" / "ForgeTest.server.luau").write_text("x\n")
    assert valid_consumer(tmp_path, "ServerScriptService/A.luau:2 (reads it)") == "ServerScriptService/A.luau:2"
    assert valid_consumer(tmp_path, "A.luau:1") == "ServerScriptService/A.luau:1"
    assert valid_consumer(tmp_path, "ServerScriptService/A.luau:3") is None
    assert valid_consumer(tmp_path, "ServerScriptService/ForgeTest.server.luau:1") is None  # the harness
    assert valid_consumer(tmp_path, "") is None and valid_consumer(tmp_path, None) is None


async def test_fixer_is_told_that_parallel_objects_for_the_check_are_rejected(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply()], ["return {hose = 2}"], ["fixed"])
    await cycle_with(settings, llm, {REPRO: fixed}, game)
    fixer_msg = next(c.user for c in llm.calls if c.role == "fixer")
    assert "duplicate or parallel objects" in fixer_msg


def test_reproducer_message_has_the_helpers_and_the_round_rule_only_for_lobby_games():
    found = {"conclusion": {}, "steps": []}
    plain = frepro.reproduce_message(HOSE, found, "a.luau", {}, None, {})
    lobby = frepro.reproduce_message(HOSE, found, "a.luau", {}, None, {"playtest": {"start_round": True}})
    assert "forge.startRound" in plain and "MUST call forge.startRound()" not in plain
    assert "MUST call forge.startRound()" in lobby and "-- consumer:" in lobby


# ---------------------------------------------------------------- forge done reads the suite after the fixes

async def test_cycle_writes_the_suite_after_its_fixes_to_results_json(settings):
    from forge.done import _checks
    from forge.scenarios import load_results, save_results

    game = _seeded_game(settings)
    run_dir = ImproveStore(settings, "fab").run.dir
    # the planning run: one failing check (with the reviewer's fields), one dropped
    save_results(run_dir, [{"id": "spraying-a-fire-cools-it", "ok": False, "verdict": "game_bug",
                            "covers": "acceptance: cools", "severity": "high"},
                           {"id": "gone", "ok": False, "verdict": "dropped"}])
    frepro.save_pending(run_dir, Check("spraying-a-fire-cools-it", REPRO, "anomaly: hose", "return {ok = false}"))
    llm = llm_for([], ["return {hose = 2}"], ["fixed"], anomalies=())
    cycle, _, _ = await cycle_with(settings, llm, {REPRO: fixed}, game)
    assert cycle["code_fixes"][0]["status"] == "kept"
    [r] = load_results(run_dir)
    assert r["id"] == "spraying-a-fire-cools-it" and r["ok"] is True and r["verdict"] == "pass"
    assert r["source"] == "fix cycle 1" and r["covers"] == "acceptance: cools" and r["severity"] == "high"
    assert cycle["checks"]["end"][0]["ok"] is True
    assert _checks(run_dir) == {"part": "checks", "ok": True, "detail": "1/1 pass"}


async def test_unfixed_pending_check_stays_failing_in_results_json(settings):
    from forge.scenarios import load_results

    game = _seeded_game(settings)
    run_dir = ImproveStore(settings, "fab").run.dir
    frepro.save_pending(run_dir, Check("spraying-a-fire-cools-it", REPRO, "anomaly: hose", "return {ok = false}"))
    llm = llm_for([], ["return {hose = 3}", "return {hose = 4}"], [], anomalies=())
    await cycle_with(settings, llm, {REPRO: fixed}, game)
    [r] = load_results(run_dir)
    assert r["ok"] is False and r["pending"] is True and r["verdict"] == "game_bug"


# ---------------------------------------------------------------- setup: prove the situation, never count a setup gap

async def test_check_without_a_setup_assertion_gets_one_correction_before_it_runs(settings):
    game = _seeded_game(settings)
    llm = llm_for([repro_reply(body="return { ok = false, detail = 'no tier-up seen' }"), repro_reply()],
                  ["return {hose = 2}"], ["fixed"])
    cycle, _, studio = await cycle_with(settings, llm, {REPRO: fixed}, game)
    fx = cycle["code_fixes"][0]
    assert [a["status"] for a in fx["repro"]["attempts"]] == ["no_setup", "proven"] and fx["status"] == "kept"
    retry = [c.user for c in llm.calls if c.role == "reproducer"][1]
    assert "never asserts its setup" in retry and "no tier-up seen" in retry
    # the lint costs no Studio time: the check without a setup assertion never ran
    assert not any("no tier-up seen" in code for code in studio.ran)


async def test_a_check_that_cannot_set_up_is_retried_not_proven(settings):
    game = _seeded_game(settings)

    def no_round(h):
        raise RuntimeError("setup: round did not start (RoundState=Lobby)")

    llm = llm_for([repro_reply("Needs a round"), repro_reply()], ["return {hose = 2}"], ["fixed"])
    cycle, _, _ = await cycle_with(settings, llm, {"Needs a round": no_round, REPRO: fixed}, game)
    fx = cycle["code_fixes"][0]
    assert [a["status"] for a in fx["repro"]["attempts"]] == ["setup", "proven"]
    assert "could not set up its situation" in [c.user for c in llm.calls if c.role == "reproducer"][1]


async def test_a_guard_that_only_fails_to_set_up_does_not_block_a_fix(settings):
    """Run 2: a round guard failed with 'setup: round did not start' after every fix and blocked good fixes."""
    from forge.improve import _check_rejection

    game = _seeded_game(settings)
    run_dir = ImproveStore(settings, "fab").run.dir
    save_check(run_dir, Check("round-guard", "Round guard", "acceptance: round", "return {ok = true}"))

    def round_guard(h):
        if "hose = 2" in h:  # after the fix this playtest can no longer start a round
            raise RuntimeError("setup: round did not start (RoundState=Lobby, via MissionService:StartRound)")
        return True, "round Active"

    llm = llm_for([repro_reply()], ["return {hose = 2}"], ["fixed"])
    cycle, _, _ = await cycle_with(settings, llm, {REPRO: fixed, "Round guard": round_guard}, game)
    fx = cycle["code_fixes"][0]
    assert fx["status"] == "kept" and [t["status"] for t in fx["attempts"]] == ["fixed"]
    [guard] = fx["attempts"][0]["checks"]["guards"]
    assert guard["id"] == "round-guard" and guard["setup"] is True
    # a real assertion failure still blocks the fix
    broke = {"repro": {"ok": True}, "guards": [{"id": "g", "ok": False, "detail": "cash 5 -> -5"}]}
    assert _check_rejection(broke)[0] == "check_regression"


async def test_a_suite_check_that_cannot_set_up_is_unknown_not_an_anomaly(settings):
    _seeded_game(settings)
    run_dir = ImproveStore(settings, "fab").run.dir
    save_check(run_dir, Check("round-guard", "Round guard", "acceptance: round", "return {ok = true}"))

    class NoRound:
        async def execute_luau(self, code, datamodel="Edit", timeout=None):
            return json.dumps({"ok": False, "detail": "startRound failed: setup: round did not start"})

    got = await frepro.run_suite(NoRound(), run_dir, log=lambda _: None)
    assert got["anomalies"] == [] and got["unknown"] == ["round-guard"]
    assert got["results"][0]["setup"] is True
