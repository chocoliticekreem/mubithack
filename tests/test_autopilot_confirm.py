"""Counters that stopped moving get one confirming measurement, and only counters that are not from a fixed scripted
play are noise-prone enough to need it: the unseeded smoke play's runs land differently each time, so a counter like
jump_pad_used can be 0 by chance (the overnight obby's round 1 threw away three jobs that way). Since fix A such a
soft drop never rolls back; the confirming measurement says in the journal whether it was real. A counter of a fixed
scripted play is like for like, so its drop rolls back at once."""

from forge import autopilot as apm

from test_autopilot import FakeRunner, _ap, _anoms, _fixed_play, _game, _gaps, _llm, _measure, _settings, fast  # noqa: F401


def _one_round(tmp_path, script):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins feel slow", 7, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    measurer = _measure(script)
    res = _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), rounds=1).run()
    return res["rounds"][0], measurer.seen, run


def _verify(run):
    import json
    return json.loads((run / "autopilot" / "rounds" / "1" / "verify.json").read_text())


def test_dead_counters_that_move_when_confirmed_keep_the_round(tmp_path):
    base = {"counters": {"coins_collected": 3, "jump_pad_used": 2}}
    rnd, seen, run = _one_round(tmp_path, {(1, "baseline"): base,
                                           (1, "after"): {"counters": {"coins_collected": 3, "jump_pad_used": 0}},
                                           (1, "confirm"): {"counters": {"coins_collected": 2, "jump_pad_used": 1}}})
    assert [(r, t) for r, t, _ in seen] == [(1, "baseline"), (1, "after"), (1, "confirm")]
    assert rnd["verdict"] == "kept" and rnd["soft"] == []
    assert _verify(run)["confirmed"] == {"first": [f"{apm.DEAD_COUNTERS}: jump_pad_used"], "second": []}


def test_soft_dead_counters_still_dead_when_confirmed_are_journaled_not_rolled_back(tmp_path):
    base = {"counters": {"coins_collected": 3, "jump_pad_used": 2}}
    dead = {"counters": {"coins_collected": 3, "jump_pad_used": 0}}
    rnd, seen, run = _one_round(tmp_path, {(1, "baseline"): base, (1, "after"): dead, (1, "confirm"): dead})
    assert rnd["verdict"] == "kept" and rnd["regressions"] == []
    assert rnd["soft"] == [f"{apm.DEAD_COUNTERS}: jump_pad_used"]
    assert (1, "confirm") in [(r, t) for r, t, _ in seen]
    journal = (run / "autopilot" / "journal.md").read_text()
    assert "Soft signals (journal and detector evidence, no rollback): core counters stopped moving: jump_pad_used" \
        in journal and "confirming measurement: core counters stopped moving: jump_pad_used" in journal


def test_a_fixed_play_counter_that_dies_rolls_back_without_a_confirming_measurement(tmp_path):
    played = _fixed_play({"coins_collected": 3, "jump_pad_used": 2}, {"coins_collected": 3, "jump_pad_used": 2})
    dead = _fixed_play({"coins_collected": 3}, {"coins_collected": 3})
    rnd, seen, _ = _one_round(tmp_path, {(1, "baseline"): played, (1, "after"): dead})
    assert rnd["verdict"] == "rolled_back" and rnd["regressions"] == [f"{apm.DEAD_SCRIPTED}: jump_pad_used"]
    assert (1, "confirm") not in [(r, t) for r, t, _ in seen]


def test_other_regressions_roll_back_without_a_confirming_measurement(tmp_path):
    base = {"counters": {"coins_collected": 3, "jump_pad_used": 2}}
    bad = {"counters": {"coins_collected": 3, "jump_pad_used": 0}, "errors": [{"message": "Game: nil"}]}
    rnd, seen, _ = _one_round(tmp_path, {(1, "baseline"): base, (1, "after"): bad})
    assert rnd["verdict"] == "rolled_back"
    assert (1, "confirm") not in [(r, t) for r, t, _ in seen]


def test_helpers():
    assert apm.soft_dead_counters({"soft": [f"{apm.DEAD_COUNTERS}: jump_pad_used"]})
    assert not apm.soft_dead_counters({"soft": ["critic score 7 -> 5"], "regressions": [f"{apm.DEAD_SCRIPTED}: x"]})
    assert not apm.soft_dead_counters({"soft": []})
    merged = apm.merge_counters({"counters": {"a": 0, "b": 2}, "critic": 6}, {"counters": {"a": 1, "c": 3}})
    assert merged["counters"] == {"a": 1.0, "b": 2.0, "c": 3.0} and merged["critic"] == 6
