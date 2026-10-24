"""A round whose only regression is counters that stopped moving gets one confirming measurement before it is
rolled back: smoke-play bots sample different stages each run, so a counter like jump_pad_used can be 0 by
chance (the overnight obby's round 1 threw away three jobs that way)."""

from forge import autopilot as apm

from test_autopilot import FakeRunner, _ap, _anoms, _game, _gaps, _llm, _measure, _settings, fast  # noqa: F401


def _one_round(tmp_path, script):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins feel slow", 7, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    measurer = _measure(script)
    res = _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), rounds=1).run()
    return res["rounds"][0], measurer.seen, run


def test_dead_counters_that_move_when_confirmed_keep_the_round(tmp_path):
    base = {"counters": {"coins_collected": 3, "jump_pad_used": 2}}
    rnd, seen, _ = _one_round(tmp_path, {(1, "baseline"): base,
                                         (1, "after"): {"counters": {"coins_collected": 3, "jump_pad_used": 0}},
                                         (1, "confirm"): {"counters": {"coins_collected": 2, "jump_pad_used": 1}}})
    assert [(r, t) for r, t, _ in seen] == [(1, "baseline"), (1, "after"), (1, "confirm")]
    assert rnd["verdict"] == "kept"


def test_dead_counters_still_dead_when_confirmed_roll_back(tmp_path):
    base = {"counters": {"coins_collected": 3, "jump_pad_used": 2}}
    dead = {"counters": {"coins_collected": 3, "jump_pad_used": 0}}
    rnd, seen, run = _one_round(tmp_path, {(1, "baseline"): base, (1, "after"): dead, (1, "confirm"): dead})
    assert rnd["verdict"] == "rolled_back"
    assert any(str(x).startswith(apm.DEAD_COUNTERS) for x in rnd["regressions"])
    assert (1, "confirm") in [(r, t) for r, t, _ in seen]


def test_other_regressions_roll_back_without_a_confirming_measurement(tmp_path):
    base = {"counters": {"coins_collected": 3, "jump_pad_used": 2}}
    bad = {"counters": {"coins_collected": 3, "jump_pad_used": 0}, "errors": [{"message": "Game: nil"}]}
    rnd, seen, _ = _one_round(tmp_path, {(1, "baseline"): base, (1, "after"): bad})
    assert rnd["verdict"] == "rolled_back"
    assert (1, "confirm") not in [(r, t) for r, t, _ in seen]


def test_helpers():
    assert apm.only_dead_counters({"regressions": [f"{apm.DEAD_COUNTERS}: jump_pad_used"]})
    assert not apm.only_dead_counters({"regressions": [f"{apm.DEAD_COUNTERS}: x", "1 new runtime errors: y"]})
    assert not apm.only_dead_counters({"regressions": []})
    merged = apm.merge_counters({"counters": {"a": 0, "b": 2}, "critic": 6}, {"counters": {"a": 1, "c": 3}})
    assert merged["counters"] == {"a": 1.0, "b": 2.0, "c": 3.0} and merged["critic"] == 6
