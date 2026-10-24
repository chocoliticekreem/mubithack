"""Fixes A-C of docs/research/2026-10-24-self-improvement-diagnosis.md, against the real round 1 of the funfair obby
(tests/fixtures/autopilot/round1, copied from runs/funfair-frenzy-an-amusement-park-obby-2/autopilot) and FakeLLM games:

A  the gate rolls back on deterministic evidence only: round 1's jump_pad_used drop is soft, a broken checkpoint is not;
B  a failed batch is blamed per job: the good job is kept, the bad one rolled back, a pair-only failure is a conflict;
C  the detector is labelled by reproduction and the fixer by the gate, never one by the other."""

import json
import threading
from pathlib import Path

import pytest

from forge import autopilot as apm
from forge import evidence as evm
from forge import repro as frepro
from forge.checks import Check, check_id, load_checks
from forge.orchestrator import JobRun

from test_autopilot import FakeRunner, _ap, _anoms, _fixed_play, _game, _gaps, _llm, _measure, _settings, fast  # noqa: F401

FIX = Path(__file__).parent / "fixtures" / "autopilot" / "round1"
CHECKPOINT = "obby-checkpoint-saves-and-respawns"
JUMP_PADS = f"{apm.DEAD_COUNTERS}: jump_pad_used"


def _real(name):
    return json.loads((FIX / name).read_text())


def _lines(path):
    return [json.loads(ln) for ln in path.read_text().splitlines() if ln.strip()] if path.exists() else []


def _round(run, r=1, phase="verify"):
    return json.loads((run / "autopilot" / "rounds" / str(r) / f"{phase}.json").read_text())


# ---------------------------------------------------------------- A. gate only on deterministic signals


def test_round1_replay_does_not_roll_back_on_jump_pad_used():
    base, after = _real("measure-baseline.json"), _real("measure-after.json")
    old = _real("verify.json")
    assert old["verdict"] == "rolled_back" and old["regressions"] == [JUMP_PADS]  # what the old gate did with it
    g = apm.gate(base, after)
    assert g["verdict"] == "kept" and g["regressions"] == []
    assert g["soft"] == [JUMP_PADS]  # still in the journal and the next detector call's evidence
    assert "counters now moving: shop_nudge" in g["improvements"]


def test_round1_replay_with_a_broken_checkpoint_still_rolls_back():
    base, after = _real("measure-baseline.json"), _real("measure-after.json")
    c = after["checks"]
    broken = {**after, "checks": {**c, "pass": c["pass"] - 1, "fail": 1, "failing": [CHECKPOINT],
                                  "passing": [x for x in c["passing"] if x != CHECKPOINT]}}
    g = apm.gate(base, broken)
    assert g["verdict"] == "rolled_back" and g["regressions"] == [f"checks that passed now fail: {CHECKPOINT}"]
    # the same round measured by a fixed smoke play: the checkpoint the scripted player reached, it no longer reaches
    played = {**base, **_fixed_play(base["counters"], {"checkpoint_reached": 2, "coin_collected": 6})}
    lost = {**after, **_fixed_play({k: v for k, v in after["counters"].items() if k != "checkpoint_reached"},
                                   {"coin_collected": 12})}
    g = apm.gate(played, lost)
    assert g["verdict"] == "rolled_back" and g["regressions"] == [f"{apm.DEAD_SCRIPTED}: checkpoint_reached"]
    assert g["soft"] == [JUMP_PADS]
    # and jump_pad_used itself rolls back once a fixed play is what moved it: the rule is determinism, not the name
    g = apm.gate({**base, **_fixed_play(base["counters"], {"jump_pad_used": 2})},
                 {**after, **_fixed_play(after["counters"], {})})
    assert g["regressions"] == [f"{apm.DEAD_SCRIPTED}: jump_pad_used"]


def test_only_a_like_for_like_fixed_play_is_hard():
    before = _fixed_play({"jump_pad_used": 2}, {"jump_pad_used": 2})
    assert before["counter_sources"] == {"jump_pad_used": "smoke"} and before["smoke"]["comparable"]
    assert apm.gate(before, _fixed_play({}, {}))["verdict"] == "rolled_back"
    for other in (_fixed_play({}, {}, seed=8), _fixed_play({}, {}, stages=(1, 40)), _fixed_play({}, {}, cut=["obby"]),
                  _fixed_play({}, {}, engine="studio"), _fixed_play({}, {}, seeded=False),
                  _fixed_play({}, {}, cut=["play"], error="cut after 65s (budget 45s)")):  # what a timeout records
        g = apm.gate(before, other)
        assert g["verdict"] == "kept" and g["soft"] == [JUMP_PADS], other["smoke"]
    unseeded = evm.measurement_from_probe({"counters": {"jump_pad_used": 2}, "smoke": {
        "engine": "headless", "steps": [{"what": "players", "ok": True}], "counters_delta": {"jump_pad_used": 2}}},
        label="x")
    assert unseeded["counter_sources"] == {"jump_pad_used": "playtest"} and not unseeded["smoke"]["comparable"]
    assert "smoke" not in evm.measurement_from_probe({"counters": {}, "smoke": {"skipped": "off"}}, label="x")


def test_a_fixed_play_that_no_longer_runs_rolls_back():
    """A job that stops the scripted play itself (no player spawns, or the play errors) is caught, although nothing
    the play would have counted can be compared. Only other conditions (engine, seed, stages, seeding) or a budget
    cut make two plays not like for like."""
    before = _fixed_play({"checkpoint_reached": 2, "coin_collected": 6}, {"checkpoint_reached": 2, "coin_collected": 6})
    no_player = [{"what": "players", "ok": False, "detail": "no player in the game"}]
    g = apm.gate(before, _fixed_play({}, {}, steps=no_player))
    assert g["verdict"] == "rolled_back"
    assert g["regressions"] == [f"{apm.BROKEN_PLAY}: smoke: players: no player in the game"]
    g = apm.gate(before, _fixed_play({}, {}, error="KeyError: 'obby'"))
    assert g["regressions"] == [f"{apm.BROKEN_PLAY}: smoke: error: KeyError: 'obby'"]
    for other in (_fixed_play({}, {}, steps=no_player, seed=8), _fixed_play({}, {}, steps=no_player, stages=(1, 40)),
                  _fixed_play({}, {}, steps=no_player, engine="studio"),
                  _fixed_play({}, {}, steps=no_player, seeded=False),
                  _fixed_play({}, {}, cut=["play"], error="cut after 65s (budget 45s)")):
        g = apm.gate(before, other)
        assert g["verdict"] == "kept" and g["regressions"] == [], other["smoke"]
    assert apm.gate({**before, "studio": True}, _fixed_play({}, {}, steps=no_player))["verdict"] == "kept"


def test_round1_replayed_through_the_loop_keeps_the_job_and_journals_the_soft_drop(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Onboarding HUD stuck on step 1", 9, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    base, after = ({k: v for k, v in _real(f"measure-{t}.json").items() if k != "screenshot"} for t in ("baseline", "after"))
    measurer = _measure({(1, "baseline"): base, (1, "after"): after, (1, "confirm"): after})
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), rounds=1).run()["rounds"][0]
    assert rnd["verdict"] == "kept" and rnd["kept"] == 1 and rnd["regressions"] == []
    assert [t for _, t, _ in measurer.seen] == ["baseline", "after", "confirm"]  # #150's look, now for the journal
    assert rnd["soft"] == [JUMP_PADS] and _round(run)["confirmed"]["second"] == [JUMP_PADS]
    assert "Soft signals (journal and detector evidence, no rollback)" in (run / "autopilot" / "journal.md").read_text()


# ---------------------------------------------------------------- B. per-job blame

COINS, SHOP = "ServerScriptService/Coins.server.luau", "ServerScriptService/Shop.server.luau"
GOOD, BAD = "Coins never collected", "Shop sells nothing"
GOOD_ID, BAD_ID = "an-coins-never-collected", "an-shop-sells-nothing"


def _fix_anoms(*items):
    """Fix anomalies, each on its own file: (title, impact, path)."""
    return json.dumps({"summary": "s", "noise": [], "anomalies": [
        {"title": t, "kind": "flat_counter", "severity": "high", "impact": imp, "confidence": 0.9,
         "evidence": ["metric:errors"], "system": "x", "why": "players get nothing",
         "job": {"kind": "fix", "request": f"fix {t}", "path": path}} for t, imp, path in items]})


class FileRunner:
    """Each fix job writes one line, `-- <title>`, into the file it was given."""

    def __init__(self, run):
        self.run, self.calls, self.lock = run, [], threading.Lock()

    def __call__(self, job, env, should_stop, beat):
        with self.lock:
            self.calls.append(job["title"])
        p = self.run / "game" / job["args"]["path"]
        p.write_text(p.read_text() + f"-- {job['title']}\n")
        return JobRun(True, {"exit": "0"})


def _guarded(run, broken):
    """A measurer with one check, 'guard', that fails when broken(text of the two files, tag) says so."""
    seen = []

    def m(ap, r, tag, focus):
        seen.append(tag)
        bad = broken("".join((run / "game" / rel).read_text() for rel in (COINS, SHOP)), tag)
        return {"label": f"ap{r}{tag[:1]}", "studio": False, "counters": {"coins_collected": 3}, "errors": [],
                "warnings": [], "physics": {"flagged": []}, "boot_errors": 0, "critic": 6.0, "fun": 6.0,
                "checks": {"pass": 0 if bad else 1, "fail": 1 if bad else 0, "passing": [] if bad else ["guard"],
                           "failing": ["guard"] if bad else []}}
    m.seen = seen
    return m


def _two_jobs(tmp_path, measurer_for):
    s = _settings(tmp_path)
    run = _game(s)
    for rel in (COINS, SHOP):
        (run / "game" / rel).write_text(f"-- {rel}\nlocal x = 1\n")
    llm = _llm(run, {"anomaly_detector": [_fix_anoms((GOOD, 8, COINS), (BAD, 7, SHOP))], "gap_finder": [_gaps()]})
    return s, run, llm, measurer_for(run)


def _blame_round(tmp_path, broken):
    s, run, llm, measurer = _two_jobs(tmp_path, lambda run: _guarded(run, broken))
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=FileRunner(run), rounds=1).run()["rounds"][0]
    return run, rnd, _round(run), measurer.seen


def test_one_good_job_and_one_that_breaks_a_passing_check(tmp_path):
    run, rnd, ver, seen = _blame_round(tmp_path, lambda text, tag: f"-- {BAD}" in text)
    # the trials are cheap (no swarm, QA or critic) and gated against the baseline measured the same way; what is
    # kept is measured once more like the batch was
    assert seen == ["baseline", "after", "job-baseline", f"job-{GOOD_ID}", f"job-{BAD_ID}", "kept"]
    assert rnd["verdict"] == "partial" and ver["blame"]["kept"] == [GOOD_ID]
    assert ver["jobs"][BAD_ID] == {"fix_label": "rolled_back", "why": "fails alone: checks that passed now fail: guard"}
    recs = {e["id"]: e for e in _lines(run / "autopilot" / "learn.jsonl")}
    assert (recs[GOOD_ID]["outcome"], recs[GOOD_ID]["fix_label"]) == ("kept", "kept")
    assert (recs[BAD_ID]["outcome"], recs[BAD_ID]["fix_label"]) == ("rolled_back", "rolled_back")
    assert (rnd["kept"], rnd["rolled_back"]) == (1, 1)
    # the version kept is the baseline plus the good job's edit, and the next round compares against it
    assert f"-- {GOOD}" in (run / "game" / COINS).read_text() and f"-- {BAD}" not in (run / "game" / SHOP).read_text()
    state = json.loads((run / "autopilot" / "state.json").read_text())
    assert state["current"]["label"] == "ap1k" and state["current"]["version"] == ver["version"] == rnd["version"]
    assert apm.kept_measurements(run / "autopilot")[-1]["label"] == "ap1k"


def test_jobs_that_only_fail_together_are_a_conflict_not_bad_fixes(tmp_path):
    run, rnd, ver, seen = _blame_round(tmp_path, lambda text, tag: f"-- {GOOD}" in text and f"-- {BAD}" in text)
    assert seen == ["baseline", "after", "job-baseline", f"job-{GOOD_ID}", f"job-{BAD_ID}", f"combo-{BAD_ID}", "kept"]
    assert rnd["verdict"] == "partial" and ver["blame"]["kept"] == [GOOD_ID]
    lab = ver["jobs"][BAD_ID]
    assert lab["fix_label"] == "conflict" and lab["conflict_with"] == [GOOD_ID] and lab["why"].startswith("passes alone")
    recs = {e["id"]: e["outcome"] for e in _lines(run / "autopilot" / "learn.jsonl")}
    assert recs == {GOOD_ID: "kept", BAD_ID: "conflict"} and (rnd["conflicts"], rnd["rolled_back"]) == (1, 0)


def test_a_batch_failure_that_does_not_recur_keeps_every_job(tmp_path):
    run, rnd, ver, seen = _blame_round(tmp_path, lambda text, tag: tag == "after")  # e.g. a flaky check
    assert seen == ["baseline", "after", "job-baseline", f"job-{GOOD_ID}", f"job-{BAD_ID}", f"combo-{BAD_ID}", "kept"]
    assert rnd["verdict"] == "partial" and sorted(ver["blame"]["kept"]) == sorted([GOOD_ID, BAD_ID])
    assert {k: v["fix_label"] for k, v in ver["jobs"].items()} == {GOOD_ID: "kept", BAD_ID: "kept"}
    assert f"-- {GOOD}" in (run / "game" / COINS).read_text() and f"-- {BAD}" in (run / "game" / SHOP).read_text()


def test_a_batch_failure_that_recurs_but_never_alone_labels_no_job(tmp_path):
    """Every job passes the cheap measurements alone and together, the full measurement fails again: the failure is
    real but no one's, so nothing is kept and no job gets a negative label."""
    run, rnd, ver, seen = _blame_round(tmp_path, lambda text, tag: tag in ("after", "kept"))
    assert seen[-1] == "kept" and rnd["verdict"] == "rolled_back" and ver["blame"]["kept"] == []
    assert {k: (v["fix_label"], v["blame"]) for k, v in ver["jobs"].items()} == {
        GOOD_ID: (None, "inconclusive"), BAD_ID: (None, "inconclusive")}
    recs = {e["id"]: (e["outcome"], e["fix_label"]) for e in _lines(run / "autopilot" / "learn.jsonl")}
    assert recs == {GOOD_ID: ("inconclusive", None), BAD_ID: ("inconclusive", None)}
    assert (rnd["kept"], rnd["rolled_back"]) == (0, 0)
    assert f"-- {GOOD}" not in (run / "game" / COINS).read_text() and f"-- {BAD}" not in (run / "game" / SHOP).read_text()
    # the kept set that failed its confirmation is not a version that exists, so it is not history either
    assert [m["label"] for m in apm.kept_measurements(run / "autopilot")] == ["ap1b"]


class TitleRunner(FileRunner):
    """Feature jobs (no path) write `-- <title>` into the file `files[title]` names."""

    def __init__(self, run, files):
        super().__init__(run)
        self.files = files

    def __call__(self, job, env, should_stop, beat):
        p = self.run / "game" / self.files[job["title"]]
        with self.lock:
            self.calls.append(job["title"])
            p.write_text(p.read_text() + f"-- {job['title']}\n")
        return JobRun(True, {"exit": "0"})


def test_an_unreproduced_batch_failure_never_reaches_the_gap_finder(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    for rel in (COINS, SHOP):
        (run / "game" / rel).write_text(f"-- {rel}\nlocal x = 1\n")
    llm = _llm(run, {"anomaly_detector": [_anoms(), _anoms()],
                     "gap_finder": [_gaps(("Add saving", 6, "feature"), ("Add a shop", 6, "feature")), _gaps()]})
    measurer = _guarded(run, lambda text, tag: tag in ("after", "kept"))
    _ap(s, "g", llm, measurer, tmp_path, runner=TitleRunner(run, {"Add saving": COINS, "Add a shop": SHOP}),
        rounds=2).run()
    recs = {e["id"]: (e["outcome"], e["fix_label"]) for e in _lines(run / "autopilot" / "learn.jsonl")}
    assert recs == {"gap-add-saving": ("inconclusive", None), "gap-add-a-shop": ("inconclusive", None)}
    gf2 = [c.user for c in llm.calls if c.role == "gap_finder"][1]
    assert "did not survive verification" not in gf2
    assert not any(c["role"] == "gap_finder" for c in _lines(run / "autopilot" / "corrections.jsonl"))


class LeftoverRunner(FileRunner):
    """The BAD job writes its edit and then fails (a crashed `forge correct` leaves its file behind)."""

    def __call__(self, job, env, should_stop, beat):
        super().__call__(job, env, should_stop, beat)
        return JobRun(True, {"exit": "0"}) if job["title"] == GOOD else JobRun(False, {"exit": "1"}, "exit 1: crash")


def test_a_failed_jobs_leftover_edit_is_not_kept_with_the_good_job(tmp_path):
    s, run, llm, measurer = _two_jobs(tmp_path, lambda run: _guarded(run, lambda text, tag: f"-- {BAD}" in text))
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=LeftoverRunner(run), rounds=1).run()["rounds"][0]
    ver = _round(run)
    # one job, but the batch held more than its edits
    assert measurer.seen == ["baseline", "after", "job-baseline", f"job-{GOOD_ID}", "kept"]
    assert rnd["verdict"] == "partial" and ver["blame"]["unattributed"] == [SHOP] and ver["blame"]["kept"] == [GOOD_ID]
    assert {e["id"]: e["outcome"] for e in _lines(run / "autopilot" / "learn.jsonl")} == {GOOD_ID: "kept",
                                                                                            BAD_ID: "failed"}
    assert f"-- {GOOD}" in (run / "game" / COINS).read_text() and f"-- {BAD}" not in (run / "game" / SHOP).read_text()


def test_a_crash_during_blame_resumes_from_the_batch_verdict(tmp_path):
    crashed = []

    def measurer_for(run):
        inner = _guarded(run, lambda text, tag: f"-- {BAD}" in text)

        def m(ap, r, tag, focus):
            if tag.startswith("job-") and not crashed:
                crashed.append(tag)
                raise RuntimeError("the headless engine died")
            return inner(ap, r, tag, focus)
        m.seen = inner.seen
        return m

    s, run, llm, measurer = _two_jobs(tmp_path, measurer_for)
    runner = FileRunner(run)
    with pytest.raises(RuntimeError):
        _ap(s, "g", llm, measurer, tmp_path, runner=runner, rounds=1).run()
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=runner, rounds=1).run()["rounds"][0]
    assert rnd["verdict"] == "partial" and _round(run)["blame"]["kept"] == [GOOD_ID]
    assert measurer.seen.count("after") == 1 and len(runner.calls) == 2  # the batch was measured once, jobs ran once


SHOP_ERROR = "ServerScriptService/Shop.server.luau:3: attempt to index nil with 'Price'"


def _studio_rounds(run, error_when, headless_fails=()):
    """A measurer like studio_measure under --studio always (how the real funfair round 1 ran: its measurements have
    studio true): BLAME_TAGS measurements are cheap and headless, every other one is a Studio measurement with
    critics. error_when(text, studio) -> the measurement has a runtime error; a check in headless_fails passes in
    Studio and fails on the headless engine (the real obby-movers-carry)."""
    seen = []

    def m(ap, r, tag, focus):
        seen.append(tag)
        studio = not tag.startswith(apm.BLAME_TAGS)
        text = "".join((run / "game" / rel).read_text() for rel in (COINS, SHOP))
        failing = [] if studio else [c for c in ("guard", "movers") if c in headless_fails]
        return {"label": f"ap{r}{tag[:1]}", "studio": studio, "counters": {"coins_collected": 3},
                "errors": [{"message": SHOP_ERROR}] if error_when(text, studio) else [], "warnings": [],
                "physics": {"flagged": []}, "boot_errors": 0,
                "checks": {"pass": 2 - len(failing), "fail": len(failing), "failing": failing,
                           "passing": [c for c in ("guard", "movers") if c not in failing]},
                **({"critic": 6.0, "fun": 6.0} if studio else {})}
    m.seen = seen
    return m


def test_a_studio_round_is_blamed_like_for_like(tmp_path):
    """Findings 1 and 8: the trials (headless) are gated against the baseline measured headless too, so a check
    only the headless engine fails does not fail every job, and a job's new runtime error is compared, not skipped."""
    s, run, llm, measurer = _two_jobs(tmp_path, lambda run: _studio_rounds(
        run, lambda text, studio: f"-- {BAD}" in text, headless_fails=("movers",)))
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=FileRunner(run), rounds=1).run()["rounds"][0]
    ver = _round(run)
    assert ver["blame"]["alone"][GOOD_ID] == []
    assert rnd["verdict"] == "partial" and ver["blame"]["kept"] == [GOOD_ID]
    assert ver["jobs"][BAD_ID]["fix_label"] == "rolled_back" and "1 new runtime errors" in ver["jobs"][BAD_ID]["why"]
    assert measurer.seen == ["baseline", "after", "job-baseline", f"job-{GOOD_ID}", f"job-{BAD_ID}", "kept"]
    state = json.loads((run / "autopilot" / "state.json").read_text())
    assert (state["current"]["label"], state["current"]["studio"], state["current"]["critic"]) == ("ap1k", True, 6.0)


def test_a_failure_only_the_batchs_engine_sees_is_confirmed_before_anything_is_kept(tmp_path):
    """Finding 8: the job's runtime error shows only in Studio. Both jobs pass the headless trials, so the kept set is
    measured like the batch and fails: nothing kept, and neither job gets a label it did not earn alone."""
    s, run, llm, measurer = _two_jobs(tmp_path, lambda run: _studio_rounds(
        run, lambda text, studio: studio and f"-- {BAD}" in text))
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=FileRunner(run), rounds=1).run()["rounds"][0]
    ver = _round(run)
    assert {k: v["fix_label"] for k, v in ver["jobs"].items()} == {GOOD_ID: None, BAD_ID: None}
    assert rnd["verdict"] == "rolled_back" and ver["blame"]["kept"] == []
    assert f"-- {BAD}" not in (run / "game" / SHOP).read_text()
    assert measurer.seen[-2:] == [f"combo-{BAD_ID}", "kept"]


def test_one_job_left_by_blame_that_fails_measured_like_the_batch_is_rolled_back(tmp_path):
    """Finding 8's own case: a failed job's leftover edit and a done job whose error shows only in Studio. The done
    job passes alone headless; measured like the batch, alone, it fails: rolled back on its own evidence."""
    s, run, llm, measurer = _two_jobs(tmp_path, lambda run: _studio_rounds(
        run, lambda text, studio: studio and f"-- {GOOD}" in text))
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=LeftoverRunner(run), rounds=1).run()["rounds"][0]
    ver = _round(run)
    assert f"-- {GOOD}" not in (run / "game" / COINS).read_text()  # its Studio error is not in the kept version
    assert rnd["verdict"] == "rolled_back" and ver["blame"]["unattributed"] == [SHOP]
    assert ver["jobs"][GOOD_ID]["fix_label"] == "rolled_back"
    assert ver["jobs"][GOOD_ID]["why"].startswith("fails alone, measured like the batch: 1 new runtime errors")
    assert measurer.seen == ["baseline", "after", "job-baseline", f"job-{GOOD_ID}", "kept"]


def test_after_a_partial_studio_round_the_next_gate_compares_studio_with_studio(tmp_path):
    """Finding 9: the version blame keeps is committed with a full measurement of the round's kind, so round 2's
    Studio 'after' is gated against a Studio measurement and its new runtime error rolls back."""
    s = _settings(tmp_path)
    run = _game(s)
    for rel in (COINS, SHOP):
        (run / "game" / rel).write_text(f"-- {rel}\nlocal x = 1\n")
    llm = _llm(run, {"anomaly_detector": [_fix_anoms((GOOD, 8, COINS), (BAD, 7, SHOP)),
                                          _fix_anoms(("Coins crash", 8, COINS))], "gap_finder": [_gaps(), _gaps()]})
    measurer = _studio_rounds(run, lambda text, studio: f"-- {BAD}" in text or "-- Coins crash" in text)
    rounds = _ap(s, "g", llm, measurer, tmp_path, runner=FileRunner(run), rounds=2).run()["rounds"]
    assert [r["verdict"] for r in rounds] == ["partial", "rolled_back"]
    assert rounds[1]["regressions"] == [f"1 new runtime errors: {apm.norm_error(SHOP_ERROR)}"]
    assert "-- Coins crash" not in (run / "game" / COINS).read_text()


# ---------------------------------------------------------------- C. the detector by reproduction, the fixer by the gate


class FakeReproducer:
    """Answers like forge/repro.reproduce: a failing check for the titles in `proves`, else the check passed."""

    def __init__(self, proves=()):
        self.proves, self.seen = set(proves), []

    def __call__(self, ap, r, anomaly):
        self.seen.append(anomaly["title"])
        cid = check_id(anomaly["title"])
        if anomaly["title"] in self.proves:
            check = Check(cid, anomaly["title"], f"anomaly: {anomaly['title']}",
                          f"-- check: {anomaly['title']}\nreturn {{ ok = false, detail = 'coins stay 0' }}\n")
            return {"proven": True, "check": check, "result": {"id": cid, "ok": False, "detail": "coins stay 0"},
                    "attempts": [{"status": "proven", "check": cid}]}
        return {"proven": False, "check": None, "result": None,
                "attempts": [{"status": "passed", "check": cid, "result": {"ok": True, "detail": "coins are collected"}}]}


class RequestRunner(FakeRunner):
    def __init__(self, run):
        super().__init__(run)
        self.requests = []

    def __call__(self, job, env, should_stop, beat):
        self.requests.append(job["args"]["request"])
        return super().__call__(job, env, should_stop, beat)


def _outcome_section(user):
    return user.split(apm.OUTCOME_MARK, 1)[1].split("\n## ", 1)[0] if apm.OUTCOME_MARK in user else ""


def test_a_not_reproduced_anomaly_gets_no_job_and_a_negative_detector_label(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"])), _anoms()],
                     "gap_finder": [_gaps(("No saving", 6, "feature")), _gaps()]})
    repro, runner = FakeReproducer(), FakeRunner(run)
    _ap(s, "g", llm, _measure({}), tmp_path, runner=runner, reproducer=repro, rounds=2).run()
    assert repro.seen == [GOOD]  # the missing feature skips reproduction
    assert runner.calls == [("feature", "No saving")]  # nothing is spent on fixing the unproven bug
    d = next(d for d in _round(run, 1, "decide")["decisions"] if d["id"] == GOOD_ID)
    assert not d["picked"] and "not reproduced" in d["reason"] and d["detector_label"] == "not_reproduced"
    recs = {e["id"]: e for e in _lines(run / "autopilot" / "learn.jsonl")}
    an, feat = recs[GOOD_ID], recs["gap-no-saving"]
    assert (an["outcome"], an["detector_label"], an["fix_label"]) == ("not_reproduced", "not_reproduced", None)
    assert "coins are collected" in an["detector_why"]
    assert (feat["detector_label"], feat["fix_label"]) == (None, "kept")  # labelled by whether the job is kept
    # the negative label goes back to the detector once, in its own Mubit task
    det2 = [c.user for c in llm.calls if c.role == "anomaly_detector"][1]
    assert f"[{GOOD_ID}] {GOOD} -> not_reproduced" in _outcome_section(det2)
    corr = _lines(run / "autopilot" / "corrections.jsonl")
    assert [(c["role"], c["kind"], c["round"], c["label"]) for c in corr] == [
        ("anomaly_detector", "outcome", 2, "not_reproduced")]


def test_a_rolled_back_fix_of_a_confirmed_bug_never_reaches_the_detector(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"])), _anoms()],
                     "gap_finder": [_gaps(), _gaps()]})
    cid = check_id(GOOD)
    measurer = _measure({(1, "after"): {"errors": [{"message": "Game: nil"}],
                                        "checks": {"pass": 1, "fail": 0, "passing": [cid], "failing": []}}})
    _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), reproducer=FakeReproducer({GOOD}), rounds=2).run()
    [rec] = _lines(run / "autopilot" / "learn.jsonl")
    assert (rec["detector_label"], rec["fix_label"], rec["check"]) == ("confirmed", "rolled_back", cid)
    assert not any(c["role"] == "anomaly_detector" for c in _lines(run / "autopilot" / "corrections.jsonl"))
    det2 = [c.user for c in llm.calls if c.role == "anomaly_detector"][1]
    assert f"[{GOOD_ID}] {GOOD} -> confirmed" in _outcome_section(det2) and "rolled_back" not in det2
    assert [c.id for c in frepro.load_pending(run)] == [cid] and load_checks(run) == []  # the bug is still there


def test_a_fix_is_judged_by_its_reproducing_check_and_a_kept_one_joins_the_suite(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    cid = check_id(GOOD)
    llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"]))], "gap_finder": [_gaps()]})
    runner = RequestRunner(run)
    measurer = _measure({(1, "after"): {"checks": {"pass": 1, "fail": 0, "passing": [cid], "failing": []}}})
    _ap(s, "g", llm, measurer, tmp_path, runner=runner, reproducer=FakeReproducer({GOOD}), rounds=1).run()
    assert "Failing check (proves the bug" in runner.requests[0] and "coins stay 0" in runner.requests[0]
    [rec] = _lines(run / "autopilot" / "learn.jsonl")
    assert (rec["detector_label"], rec["fix_label"]) == ("confirmed", "kept")
    assert [c.id for c in load_checks(run)] == [cid] and frepro.load_pending(run) == []  # now a regression guard


def test_a_fix_that_leaves_its_reproducing_check_failing_is_rolled_back(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    cid = check_id(GOOD)
    llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"]))], "gap_finder": [_gaps()]})
    measurer = _measure({(1, "after"): {"checks": {"pass": 0, "fail": 1, "passing": [], "failing": [cid]}}})
    rnd = _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), reproducer=FakeReproducer({GOOD}),
              rounds=1).run()["rounds"][0]
    assert rnd["verdict"] == "rolled_back" and rnd["regressions"] == [f"{apm.STILL_FAILING}: {cid}"]
    [rec] = _lines(run / "autopilot" / "learn.jsonl")
    assert (rec["detector_label"], rec["fix_label"]) == ("confirmed", "rolled_back")  # the detector was right


class NoEngine:
    """Stands in for HeadlessStudio: no luau process."""

    def __init__(self, *a, **k):
        pass

    async def play(self):
        return {}

    async def stop(self):
        return None


def test_the_default_reproducer_only_confirms_what_the_gate_can_judge(tmp_path, monkeypatch):
    import forge.checks as chk
    import forge.headless as hl
    from forge.llm import FakeLLM

    s = _settings(tmp_path)
    _game(s)
    ap = _ap(s, "g", FakeLLM({}), _measure({}), tmp_path)
    proven ={"proven": True, "check": Check("coins", "Coins", "anomaly: coins", "return { ok = false, detail = 'x' }"),
              "result": {"ok": False, "detail": "x"}, "attempts": [{"status": "proven", "check": "coins"}]}

    async def reproduce(*a, **k):
        return proven

    monkeypatch.setattr(chk, "headless_available", lambda: True)
    monkeypatch.setattr(hl, "HeadlessStudio", NoEngine)
    monkeypatch.setattr(frepro, "reproduce", reproduce)
    for verdict, want in (("fail", proven), ("needs_studio", None), ("pass", None), ("unknown", None)):
        monkeypatch.setattr(chk, "run_check_offline", lambda game_dir, check, v=verdict: {"verdict": v})
        assert apm.headless_reproduce(ap, 1, {"title": "Coins"}) == want, verdict
    monkeypatch.setattr(chk, "headless_available", lambda: False)
    assert apm.headless_reproduce(ap, 1, {"title": "Coins"}) is None  # no engine: no label, not "not reproduced"


def test_round1_learn_records_never_reach_the_detector():
    legacy = _lines(FIX / "learn.jsonl")
    assert [(o["title"], o["outcome"]) for o in legacy] == [
        ("Onboarding HUD stuck on step 1", "rolled_back"), ("First costume purchase never happens", "rolled_back"),
        ("Zone 9-10 gaps too wide, finale path unproven", "rolled_back")]
    assert apm.detector_outcomes(legacy) == []  # fix outcomes, not reproductions: nothing to tell the detector
    assert [apm.gap_label(o) for o in legacy] == [None, "rolled_back", None]  # only the missing feature's job labels


class ScriptedReproducer:
    """Answers like forge/repro.reproduce with attempts of the given statuses and nothing proven, or raises."""

    def __init__(self, statuses=(), raises=None):
        self.statuses, self.raises, self.seen = list(statuses), raises, []

    def __call__(self, ap, r, anomaly):
        self.seen.append(anomaly["title"])
        if self.raises is not None:
            raise self.raises
        return {"proven": False, "check": None, "result": None,
                "attempts": [{"status": st, "check": "c", "result": {"ok": st == "passed", "detail": st}}
                             for st in self.statuses]}


def _decision(i="an-x"):
    return {"id": i, "title": GOOD, "kind": "fix", "evidence": [], "why": "players get nothing",
            "job": {"kind": "fix", "request": "fix the coins"}}


def test_only_a_check_that_ran_cleanly_and_passed_is_not_reproduced(tmp_path):
    """Findings 2 and 10: a failed Mubit call (unusable), a check that errored, could not set up or names no consumer
    proves nothing either way: no detector label and no try used. Only a check that ran and found the game behaving
    correctly is a negative example."""
    from forge.llm import FakeLLM

    s = _settings(tmp_path)
    _game(s)
    ap = _ap(s, "g", FakeLLM({}), _measure({}), tmp_path)
    evm.EvidenceStore(ap.rdir(1) / "evidence.json").save()
    for i, statuses in enumerate((["unusable", "unusable"], ["setup", "errored"], ["no_consumer", "no_consumer"],
                                  ["no_setup", "errored"])):
        ap.reproducer = ScriptedReproducer(statuses)
        out = ap.reproduce(1, _decision(f"an-{i}"))
        assert out["label"] is None and out["why"].startswith("no check ran cleanly"), statuses
    assert (ap.state.get("tries") or {}) == {}
    ap.reproducer = ScriptedReproducer(["errored", "passed"])
    out = ap.reproduce(1, _decision("an-passed"))
    assert out["label"] == "not_reproduced" and "passed" in out["why"] and ap.state["tries"] == {"an-passed": 1}


def test_a_failed_reproducer_call_leaves_the_finding_unlabelled(tmp_path, monkeypatch):
    """Finding 10 end to end with the production reproducer: its Mubit call fails (FakeLLM has no reproducer reply;
    an outage or spent retries raise LLMError the same way). The finding keeps its job (unproven, as with no engine),
    the detector is told nothing about it and no correction is written."""
    import forge.checks as chk
    import forge.headless as hl

    monkeypatch.setattr(chk, "headless_available", lambda: True)
    monkeypatch.setattr(hl, "HeadlessStudio", NoEngine)
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"])), _anoms()],
                     "gap_finder": [_gaps(), _gaps()]})
    runner = FakeRunner(run)
    _ap(s, "g", llm, _measure({}), tmp_path, runner=runner, reproducer=apm.headless_reproduce, rounds=2).run()
    rp = json.loads((run / "autopilot" / "rounds" / "1" / "repro" / f"{GOOD_ID}.json").read_text())
    assert rp["label"] is None and "unusable" in rp["why"]
    assert runner.calls == [("fix", GOOD)]
    [rec] = _lines(run / "autopilot" / "learn.jsonl")
    assert (rec["detector_label"], rec["fix_label"]) == (None, "kept")
    assert apm.OUTCOME_MARK not in [c.user for c in llm.calls if c.role == "anomaly_detector"][1]
    assert _lines(run / "autopilot" / "corrections.jsonl") == []


def test_a_reproducer_that_cannot_run_leaves_the_finding_unlabelled_and_decide_finishes(tmp_path):
    """Finding 6: the reproducer's headless session cannot boot the game (a server loop without task.wait). decide()
    finishes, the finding is unlabelled and its fix job goes ahead (the fix such a game needs). A spent budget still
    stops the loop."""
    from forge.studio import StudioError

    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"]))], "gap_finder": [_gaps()]})
    runner = FakeRunner(run)
    hang = ScriptedReproducer(raises=StudioError("headless call timed out after 60s (a loop without task.wait?)"))
    _ap(s, "g", llm, _measure({}), tmp_path, runner=runner, reproducer=hang, rounds=1).run()
    [d] = _round(run, 1, "decide")["decisions"]
    assert d["picked"] and d["detector_label"] is None
    assert d["detector_why"].startswith("the reproducer could not run (StudioError: headless call timed out")
    assert runner.calls == [("fix", GOOD)] and hang.seen == [GOOD]
    ap = _ap(s, "g", llm, _measure({}), tmp_path, reproducer=ScriptedReproducer(raises=apm.BudgetSpent("spent")))
    with pytest.raises(apm.BudgetSpent):
        ap.reproduce(1, _decision("an-budget"))


def test_the_prefilters_stand_ins_are_never_labelled_as_the_detectors(tmp_path):
    """Finding 4: when the detector call fails, the pre-filter's candidates stand in. They are reproduced like any
    bug, but they are the pre-filter's: the next detector call is not told their outcome, nor shown them as its own
    previous list, and no anomaly_detector correction is written."""
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": ["not json"] * 3 + [_anoms()],
                     "gap_finder": [_gaps(("No saving", 6, "feature")), _gaps()]})
    measurer = _measure({(1, "baseline"): {"errors": [{"message": "Game: attempt to index nil with 'Coins'"}]}})
    repro = FakeReproducer()
    _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), reproducer=repro, rounds=2).run()
    det2 = [c.user for c in llm.calls if c.role == "anomaly_detector"][-1]
    assert apm.OUTCOME_MARK not in det2 and "Your previous anomaly list" not in det2
    assert not any(c["role"] == apm.ROLE for c in _lines(run / "autopilot" / "corrections.jsonl"))
    [stand_in] = _round(run, 1, "detect")["anomalies"]
    assert stand_in.get("source") == apm.PREFILTER and repro.seen == [stand_in["title"]]
    rec = next(e for e in _lines(run / "autopilot" / "learn.jsonl") if e["id"] == stand_in["id"])
    assert (rec["source"], rec["sources"], rec["detector_label"]) == (apm.PREFILTER, [apm.PREFILTER], "not_reproduced")
    assert apm.detector_outcomes([rec]) == []


def test_a_gap_merged_into_an_anomaly_is_labelled_by_its_own_kind(tmp_path):
    """Finding 5: a missing-feature gap merged into a same-titled fix anomaly gets no reproduction label (no feature
    job ran), and a broken-behaviour gap merged into a feature anomaly gets no job-result label (it was never
    reproduced). Either way the next gap_finder call carries no correction."""
    title = "Shop never sells costumes"
    cases = (("fix", "feature", [("No saving", 6, "feature")], _measure({})),  # a job, so there is a round 2
             ("feature", "fix", [], _measure({(1, "after"): {"errors": [{"message": "Game: nil"}]}})))
    for i, (an_kind, gap_kind, more, measurer) in enumerate(cases):
        s = _settings(tmp_path / str(i))
        run = _game(s)
        llm = _llm(run, {"anomaly_detector": [_anoms((title, 8, an_kind, ["metric:errors"])), _anoms()],
                         "gap_finder": [_gaps((title, 7, gap_kind), *more), _gaps()]})
        _ap(s, "g", llm, measurer, tmp_path / str(i), runner=FakeRunner(run), reproducer=FakeReproducer(),
            rounds=2).run()
        assert "did not survive verification" not in [c.user for c in llm.calls if c.role == "gap_finder"][1]
        rec = next(e for e in _lines(run / "autopilot" / "learn.jsonl") if e["title"] == title)
        assert rec["sources"] == ["anomaly_detector", "gap_finder"] and apm.gap_label(rec) is None
        assert (rec["kind"], rec.get("gap_kind"), rec["outcome"]) == (
            an_kind, gap_kind, "not_reproduced" if an_kind == "fix" else "rolled_back")


def test_gap_label_reads_the_gaps_own_kind():
    nr = {"detector_label": "not_reproduced", "outcome": "not_reproduced", "kind": "fix"}
    assert apm.gap_label({**nr, "gap_kind": "fix"}) == "not reproduced"
    assert apm.gap_label({**nr, "gap_kind": "feature"}) is None
    rb = {"detector_label": None, "outcome": "rolled_back", "kind": "feature"}
    assert apm.gap_label({**rb, "gap_kind": "feature"}) == "rolled_back"
    assert apm.gap_label({**rb, "gap_kind": "fix"}) is None
    assert apm.gap_label({**rb, "kind": "visual", "gap_kind": "feature"}) is None  # the job that ran was not the gap's
    assert apm.gap_label(rb) == "rolled_back"  # a record from before gap_kind: the decision was the gap's own
    assert apm.gap_label({**rb, "outcome": "inconclusive", "gap_kind": "feature"}) is None


def test_without_per_job_blame_a_failed_batch_of_several_jobs_labels_none_of_them():
    """Jobs whose edits were not recorded (they ran in an older session, like the real round 2 that stopped after
    act): the batch's failure cannot be pinned on any one of them. One job is its own batch."""
    act = {"jobs": [{"id": "fix-1", "gap": GOOD_ID, "kind": "fix", "status": "done"},
                    {"id": "fix-2", "gap": BAD_ID, "kind": "fix", "status": "done"}]}
    ver = {"verdict": "rolled_back", "regressions": ["checks that passed now fail: guard"]}
    labels = apm.fix_labels(act, ver, None)
    assert {k: (v["fix_label"], v.get("blame")) for k, v in labels.items()} == {
        GOOD_ID: (None, "inconclusive"), BAD_ID: (None, "inconclusive")}
    assert apm.fix_labels({"jobs": act["jobs"][:1]}, ver, None) == {
        GOOD_ID: {"fix_label": "rolled_back", "why": "checks that passed now fail: guard"}}
    assert apm.fix_labels(act, {"verdict": "kept", "improvements": []}, None)[BAD_ID]["fix_label"] == "kept"


# ---------------------------------------------------------------- checks that flip on the same code (finding 7)


class Rechecker:
    """Answers like headless_recheck: the next verdict scripted for a check id, else "fail"."""

    def __init__(self, verdicts=None):
        self.verdicts, self.seen = {k: list(v) for k, v in (verdicts or {}).items()}, []

    def __call__(self, ap, cid):
        self.seen.append(cid)
        left = self.verdicts.get(cid)
        return left.pop(0) if left else "fail"


def _flaky(run, broken, flips):
    """_guarded's measurer plus a check 'movers' that fails, on any code, in the measurements tagged in `flips`."""
    inner = _guarded(run, broken)

    def m(ap, r, tag, focus):
        out = inner(ap, r, tag, focus)
        c = out["checks"]
        (c["failing"] if tag in flips else c["passing"]).append("movers")
        c["fail" if tag in flips else "pass"] += 1
        return out
    m.seen = inner.seen
    return m


def test_a_check_seen_to_flip_on_the_same_code_gates_soft():
    base = {"studio": False, "checks": {"passing": ["guard", "movers"], "failing": []}}
    after = {"studio": False, "checks": {"passing": [], "failing": ["guard", "movers"]}}
    g = apm.gate(base, after, flaky=["movers"])
    assert g["regressions"] == ["checks that passed now fail: guard"] and g["soft"] == [f"{apm.FLIPPING}: movers"]
    g = apm.gate(base, {**after, "checks": {"passing": ["guard"], "failing": ["movers"]}}, flaky=["movers"])
    assert g["verdict"] == "kept"


def test_a_check_that_flips_on_unchanged_code_does_not_roll_the_round_back(tmp_path):
    """obby-movers-carry failed 2 of 6 headless runs of one funfair version. A check that passed before and fails
    now is run again on the same files: one pass and it is soft from then on. One that keeps failing rolls back."""
    for i, (verdicts, want) in enumerate(((["pass"], "kept"), (["fail", "fail"], "rolled_back"))):
        s = _settings(tmp_path / str(i))
        run = _game(s)
        for rel in (COINS, SHOP):
            (run / "game" / rel).write_text(f"-- {rel}\nlocal x = 1\n")
        llm = _llm(run, {"anomaly_detector": [_anoms((GOOD, 8, "fix", ["metric:errors"]))], "gap_finder": [_gaps()]})
        rechecker = Rechecker({"movers": verdicts})
        ap = _ap(s, "g", llm, _flaky(run, lambda text, tag: False, {"after"}), tmp_path / str(i),
                 runner=FakeRunner(run), rounds=1)
        ap.rechecker = rechecker
        rnd = ap.run()["rounds"][0]
        assert rnd["verdict"] == want and rechecker.seen == ["movers"] * len(verdicts)
        state = json.loads((run / "autopilot" / "state.json").read_text())
        if want == "kept":
            assert rnd["soft"] == [f"{apm.FLIPPING}: movers"] and state["flaky"] == ["movers"]
        else:
            assert rnd["regressions"] == ["checks that passed now fail: movers"] and "flaky" not in state


def test_per_job_blame_is_not_a_coin_flip_on_a_flaky_check(tmp_path):
    """The flaky check fails in GOOD's trial only. Re-run, it passes, so GOOD passes alone and is kept, and only BAD,
    which breaks 'guard' every time, is rolled back."""
    s, run, llm, measurer = _two_jobs(tmp_path, lambda run: _flaky(run, lambda text, tag: f"-- {BAD}" in text,
                                                                     {f"job-{GOOD_ID}"}))
    rechecker = Rechecker({"movers": ["pass"]})
    ap = _ap(s, "g", llm, measurer, tmp_path, runner=FileRunner(run), rounds=1)
    ap.rechecker = rechecker
    rnd = ap.run()["rounds"][0]
    ver = _round(run)
    assert rnd["verdict"] == "partial" and ver["blame"]["kept"] == [GOOD_ID]
    assert ver["jobs"][BAD_ID] == {"fix_label": "rolled_back", "why": "fails alone: checks that passed now fail: guard"}
    assert rechecker.seen == ["guard", "guard", "movers", "guard", "guard"]
    assert json.loads((run / "autopilot" / "state.json").read_text())["flaky"] == ["movers"]


def test_the_default_rechecker_runs_one_saved_check_headless(tmp_path, monkeypatch):
    import forge.checks as chk
    from forge.llm import FakeLLM

    s = _settings(tmp_path)
    run = _game(s)
    ap = _ap(s, "g", FakeLLM({}), _measure({}), tmp_path)
    chk.save_check(run, Check("movers", "Movers carry", "genre obby", "return { ok = true, detail = '' }"))
    chk.save_check(run, Check("ui", "UI fits", "x", "return { ok = true, detail = '' }", needs="studio"))
    frepro.save_pending(run, Check("coins", "Coins", "anomaly: coins", "return { ok = false, detail = '' }"))
    ran = []
    monkeypatch.setattr(chk, "run_check_offline", lambda game_dir, check: ran.append(check.id) or {"verdict": "pass"})
    assert apm.headless_recheck(ap, "movers") is None  # no luau CLI here
    monkeypatch.setattr(chk, "headless_available", lambda: True)
    assert [apm.headless_recheck(ap, c) for c in ("movers", "coins", "ui", "nope")] == ["pass", "pass", None, None]
    assert ran == ["movers", "coins"]  # a Studio-only check has no headless verdict to compare
