"""`forge autopilot`: evidence store, statistical pre-filter, decision ranking, the regression gate (rollback),
resume after a crash, budget stops, corrections and the read-only advise mode, all with FakeLLM."""

import dataclasses
import hashlib
import json
import threading
from pathlib import Path

import pytest

from forge import autopilot as apm
from forge import evidence as evm
from forge import orchestrator
from forge.broker import Broker, StudioSlots
from forge.config import load_settings
from forge.llm import FakeLLM
from forge.orchestrator import JobRun

GAME_FILE = "ServerScriptService/Game.server.luau"


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    monkeypatch.setattr(orchestrator, "POLL_S", 0.02)
    import forge.checks as chk
    monkeypatch.setattr(chk, "headless_available", lambda: False)


def _settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", repo_root=tmp_path)


def _game(settings, slug="g", body="local coins = 0\nForgeTelemetry.count(\"coins_collected\", 1)\n"):
    run = settings.runs_dir / slug
    (run / "game" / "ServerScriptService").mkdir(parents=True, exist_ok=True)
    (run / "game" / GAME_FILE).write_text(body)
    (run / "spec.json").write_text(json.dumps({"title": "Coin Obby", "pitch": "collect coins", "modules": [
        {"path": GAME_FILE, "purpose": "coins"}], "acceptance": ["coins can be collected"]}))
    (run / "state.json").write_text(json.dumps({"iterations": []}))
    return run


def _anoms(*items):
    return json.dumps({"summary": "s", "anomalies": [
        {"title": t, "kind": "flat_counter", "severity": "high", "impact": imp, "confidence": 0.9,
         "evidence": ev, "system": "coins", "why": "players get nothing",
         "job": {"kind": kind, "request": f"do {t}", **({"path": GAME_FILE} if kind == "fix" else {})}}
        for t, imp, kind, ev in items], "noise": []})


def _gaps(*items):
    return json.dumps({"summary": "thin", "score": 4, "gaps": [
        {"title": t, "kind": "missing", "impact": imp, "confidence": 0.8, "evidence": ["genre:saving"],
         "job": {"kind": kind, "request": f"build {t}"}} for t, imp, kind in items]})


class FakeRunner:
    """Pretends to be the forge CLI: every build job appends a line to the game file."""

    def __init__(self, run, line="-- changed\n"):
        self.run = run
        self.line = line
        self.calls = []
        self.lock = threading.Lock()

    def __call__(self, job, env, should_stop, beat):
        with self.lock:
            self.calls.append((job["kind"], job["title"]))
        p = self.run / "game" / GAME_FILE
        p.write_text(p.read_text() + self.line)
        return JobRun(True, {"exit": "0"})


def _measure(script):
    """A fake measurer: script[(round, tag)] -> Measurement (missing -> a healthy default)."""
    seen = []

    def m(ap, r, tag, focus):
        seen.append((r, tag, focus))
        val = script.get((r, tag), {})
        if isinstance(val, Exception):
            script.pop((r, tag))
            raise val
        return {"label": f"ap{r}{tag[:1]}", "studio": True, "counters": {"coins_collected": 3}, "errors": [],
                "warnings": [], "physics": {"flagged": []}, "critic": 6.0, "fun": 6.0, "boot_errors": 0, **val}
    m.seen = seen
    return m


def _broker(tmp_path):
    return Broker(root=tmp_path / "broker", pools={"llm": ["llm-1", "llm-2"], "game": ["g1", "g2"],
                                                   "sync": [], "studio": []},
                  studio_slots=StudioSlots(root=tmp_path / "slots"))


def _ap(settings, target, llm, measurer, tmp_path, runner=None, **opts):
    o = apm.AutoOptions(use_studio=False, max_calls=opts.pop("max_calls", 200), minutes=opts.pop("minutes", 60),
                        rounds=opts.pop("rounds", 2), verify_reserve=0, **opts)
    return apm.Autopilot(settings, target, o, llm=llm, measurer=measurer, runner=runner,
                         broker=_broker(tmp_path), log=lambda s: None)


# ---------------------------------------------------------------- evidence store


def test_evidence_store_roundtrip_and_render_order(tmp_path):
    st = evm.EvidenceStore(tmp_path / "ev.json")
    st.add("metric:counter:coins", "metric", "series", "coins: ap1=3")
    st.add("err:abc", "error", "probe", "Game: attempt to index nil")
    st.add("err:abc", "error", "bridge", "Game: attempt to index nil")  # same signal twice: one item
    st.add("stat:flat:coins", "stat", "prefilter", "coins never moved")
    st.point("counter:coins", "ap1", 3)
    st.point("counter:coins", "ap1", 4)  # same label replaces
    st.point("counter:coins", "ap2", "x")  # not a number: ignored
    assert st.values("counter:coins") == [4.0]
    assert st.items["err:abc"].data["also"] == ["bridge"]
    assert st.counts() == {"error": 1, "metric": 1, "stat": 1}
    st.save()
    back = evm.EvidenceStore.load(tmp_path / "ev.json")
    assert back.refs() == st.refs() and back.series == st.series
    text = back.render(5000)
    assert text.index("stat:flat:coins") < text.index("err:abc") < text.index("metric:counter:coins")
    assert len(back.render(60).splitlines()) <= 3  # a tight budget truncates


def test_measurement_and_history(tmp_path):
    run = tmp_path / "g"
    (run / "iterations" / "1").mkdir(parents=True)
    (run / "iterations" / "1" / "report.json").write_text(json.dumps(
        {"counters": {"coins_collected": 2}, "errors": [{"message": "boom at line 12", "script": "Game"}]}))
    (run / "iterations" / "1" / "critique.json").write_text(json.dumps({"score": 5}))
    (run / "iterations" / "2").mkdir()
    (run / "iterations" / "2" / "report.json").write_text(json.dumps({"source": "autopilot round 1", "counters": {}}))
    (run / "improve").mkdir()
    (run / "improve" / "1.json").write_text(json.dumps({"before": [
        {"round": 1, "counters": {"coins_collected": 5}, "errors": {"count": 0, "first": []}},
        {"round": 2, "counters": {"coins_collected": 6}, "errors": {"count": 1, "first": ["oops 3"]}}]}))
    hist = evm.history(run)
    assert [h["label"] for h in hist] == ["it1", "cycle1.1", "cycle1.2"]  # the autopilot iteration is skipped
    assert hist[0]["critic"] == 5.0 and hist[2]["errors"][0]["message"] == "oops 3"
    st = evm.EvidenceStore()
    for h in hist:
        evm.add_measurement(st, h, source="history")
    assert st.values("counter:coins_collected") == [2.0, 5.0, 6.0]
    assert st.values("errors") == [1.0, 0.0, 1.0]
    # error ids ignore the numbers that change between runs
    assert evm._hash("boom at line 12") == evm._hash("boom at line 99")


# ---------------------------------------------------------------- statistical pre-filter


def _series_store(points: dict[str, list[float]]) -> evm.EvidenceStore:
    st = evm.EvidenceStore()
    for metric, vals in points.items():
        for i, v in enumerate(vals):
            st.point(metric, f"v{i}" if i < len(vals) - 1 else "now", v)
    return st


def test_zscore_needs_history_and_floors_the_spread():
    assert evm.zscore([1, 2, 3]) is None
    assert evm.zscore([5, 5, 5, 5, 5]) == 0
    assert evm.zscore([2, 3, 2, 3, 20]) >= 10
    assert abs(evm.zscore([100, 101, 99, 100, 103])) < 1  # within 10% of the mean: not a spike


def test_prefilter_flags_spikes_regressions_errors_and_untouched():
    st = _series_store({"counter:fire_tick_over_budget": [2, 3, 2, 3, 20], "counter:coins_collected": [4, 5, 6, 0],
                        "counter:map_build_ms": [200, 210, 205, 900]})
    prev = {"label": "v2", "counters": {"coins_collected": 6, "map_build_ms": 205, "fire_tick_over_budget": 3},
            "errors": [{"message": "old error 1"}]}
    cur = {"label": "now", "counters": {"coins_collected": 0, "map_build_ms": 900, "fire_tick_over_budget": 20},
           "errors": [{"message": "old error 7"}, {"message": "Game:12 attempt to index nil"}],
           "physics": {"flagged": [{"kind": "jitter", "path": "Truck"}]}}
    st.add("err:" + evm._hash("Game:12 attempt to index nil"), "error", "probe", "x")
    cands = evm.prefilter(cur, prev, st, declared=["coins_collected", "rebirths"],
                          stuck=[{"run": "r1", "from": 3, "tester": "newbie", "steps": 4, "action": "walk"}],
                          ttfr=None, ttfr_known=True)
    ids = {c["id"]: c for c in cands}
    assert ids["stat:error_spike"]["severity"] == "high"
    assert ids["stat:error_spike"]["value"] == 2  # "old error 1" vs "old error 7" is the same error
    assert ids["stat:regression:coins_collected"]["severity"] == "high"
    assert ids["stat:spike:fire_tick_over_budget"]["bad"] is True
    assert "stat:perf:fire_tick_over_budget" in ids
    assert "stat:untouched:rebirths" in ids
    assert "stat:physics" in ids and "stat:stuck:r1@3" in ids and ids["stat:ttfr"]["severity"] == "high"
    assert not any("map_build_ms" in c["id"] for c in cands)  # setup counters are not anomalies
    sev = [c["severity"] for c in cands]
    assert sev == sorted(sev, key=lambda s: {"high": 0, "medium": 1, "low": 2}[s])


def test_prefilter_ignores_bad_event_counters_and_groups_untouched():
    st = _series_store({"counter:data_save_failed": [1, 0], "counter:lobby_afk": [1, 0]})
    prev = {"label": "v0", "counters": {"data_save_failed": 1, "lobby_afk": 1}, "errors": []}
    cur = {"label": "now", "counters": {"data_save_failed": 0, "lobby_afk": 0}, "errors": []}
    declared = ["data_save_failed", "net_dropped"] + [f"gear_{i}" for i in range(8)] + ["coins_earned"]
    cands = evm.prefilter(cur, prev, st, declared=declared)
    ids = [c["id"] for c in cands]
    assert not any("data_save_failed" in i or "lobby_afk" in i or "net_dropped" in i for i in ids)
    assert ids[0] == "stat:untouched:coins_earned"  # reward-like counters first
    assert len([i for i in ids if i.startswith("stat:untouched:")]) == evm.UNTOUCHED_SHOWN + 1
    assert "stat:untouched:+4" in ids


def test_prefilter_quiet_on_a_healthy_stable_version():
    st = _series_store({"counter:coins_collected": [5, 6, 5, 6, 6]})
    m = {"label": "now", "counters": {"coins_collected": 6}, "errors": []}
    assert evm.prefilter(m, {"label": "v3", "counters": {"coins_collected": 6}, "errors": []}, st,
                         declared=["coins_collected"]) == []


def test_stuck_spans_and_first_reward():
    steps = [{"n": i, "tester": "newbie", "action": {"action": "walk_to"}, "pos": [10 + i * 0.2, 3, 0], "result": "x"}
             for i in range(1, 5)] + [{"n": 5, "tester": "newbie", "action": {"action": "wait"}},
                                      {"n": 6, "tester": "speed", "action": "jump", "pos": [0, 0, 0]},
                                      {"n": 7, "tester": "speed", "action": "jump", "pos": [50, 0, 0]}]
    spans = evm.stuck_spans(steps)
    assert spans == [{"tester": "newbie", "from": 1, "to": 4, "steps": 4, "pos": [10.2, 3, 0], "action": "walk_to",
                      "result": "x"}]
    assert evm.first_reward([{"t": 0, "counters": {"coins": 0}}, {"t": 15, "counters": {"coins": 2}}]) == 15
    assert evm.first_reward([{"t": 0, "counters": {"jumps": 3}}]) is None
    assert evm.first_reward([{"t": 0, "counters": {"checkpoint_placement_fixed": 1}},
                             {"t": 9, "counters": {"coin_collected": 1}}]) == 9  # "point" inside a word: no


def test_bridge_events_are_attributed_to_our_place():
    evs = [{"seq": 1, "time": 10, "type": "play", "state": "started", "place": "Forge-agents-35.rbxlx"},
           {"seq": 2, "time": 11, "type": "error", "dm": "Server", "message": "Coins:12: attempt to index nil"},
           {"seq": 3, "time": 12, "type": "play", "state": "stopped", "place": "Forge-agents-35.rbxlx"},
           {"seq": 4, "time": 20, "type": "error", "dm": "Server", "message": "someone else's error"},
           {"seq": 5, "time": 21, "type": "play", "state": "started", "place": "Forge-agents-34.rbxlx"}]
    st = evm.EvidenceStore()
    counts = evm.add_bridge(st, evs, place="Forge-agents-35")
    assert counts == {"error": 1, "play": 2}
    shown = [i.text for i in st.of_kind("bridge") if i.id != "bridge:summary"]
    assert shown == ["[Server] error: Coins:12: attempt to index nil"]


# ---------------------------------------------------------------- decide


def test_candidates_merge_and_rank():
    an = apm.parse_anomalies(json.loads(_anoms(("Coins never collected", 8, "fix", ["stat:flat:coins"]),
                                               ("Odd tester path", 3, "test", ["stuck:r@1"]))),
                             {"stat:flat:coins", "stuck:r@1"}, files=[GAME_FILE])["anomalies"]
    gaps = [{"id": "coins-are-never-collected", "title": "coins are never collected", "impact": 9, "confidence": 0.7,
             "evidence": ["genre:core"], "why": "", "job": {"kind": "fix", "request": "fix coins"}},
            {"id": "no-saving", "title": "No saving", "impact": 6, "confidence": 0.8, "evidence": ["genre:saving"],
             "why": "", "job": {"kind": "feature", "request": "add saving"}}]
    cands = apm.candidates(an, gaps)
    top = cands[0]
    assert top["sources"] == ["anomaly_detector", "gap_finder"] and top["impact"] == 9
    assert top["confidence"] == 1.0 and "genre:core" in top["evidence"]
    assert top["score"] == round(9 * 1.0 * 1.25, 2)
    assert [c["kind"] for c in cands] == ["fix", "feature", "test"]
    ds = apm.decide(cands, per_round=2, min_rank=2, calls_left=30, reserve=0, tries={"gap-no-saving": 0})
    assert [d["picked"] for d in ds] == [True, False, True]
    assert "needs ~28 calls" in ds[1]["reason"]  # the feature does not fit in 30 - 4 calls
    ds = apm.decide(cands, per_round=1, min_rank=2, calls_left=None, rejected={"gap-no-saving"},
                    tries={top["id"]: 2})
    assert "tried 2 times" in ds[0]["reason"] and "rejected" in ds[1]["reason"]
    assert ds[2]["picked"]


def test_candidates_merge_on_shared_specific_evidence():
    an = [{"id": "an-map-built-twice", "title": "Map built twice", "impact": 8, "confidence": 0.85,
           "evidence": ["check:01-map", "metric:errors"], "job": {"kind": "fix", "request": "x"}},
          {"id": "an-player-blocked", "title": "Player blocked before Stage 1", "impact": 10, "confidence": 0.7,
           "evidence": ["stuck:r@4"], "job": {"kind": "fix", "request": "y"}},
          {"id": "an-stage-unreachable", "title": "Stage 1 checkpoint unreachable", "impact": 8, "confidence": 0.7,
           "evidence": ["stuck:r@4", "stat:stuck:r@4"], "job": {"kind": "fix", "request": "z"}}]
    gaps = [{"id": "map-built-counter-is-2", "title": "map_built counter is 2 instead of 1", "impact": 5,
             "confidence": 0.9, "evidence": ["check:01-map"], "job": {"kind": "fix", "request": "w"}},
            {"id": "saving", "title": "No saving", "impact": 5, "confidence": 0.9, "evidence": ["metric:errors"],
             "job": {"kind": "feature", "request": "v"}}]
    cands = apm.candidates(an, gaps)
    titles = [c["title"] for c in cands]
    assert titles.count("Stage 1 checkpoint unreachable") == 0 and "No saving" in titles  # broad ids don't merge
    mb = next(c for c in cands if c["title"] == "Map built twice")
    assert mb["sources"] == ["anomaly_detector", "gap_finder"] and len(cands) == 3


def test_parse_anomalies_drops_unknown_evidence_and_bad_paths():
    obj = json.loads(_anoms(("A", 6, "fix", ["made:up"]), ("B", 6, "polish", ["err:1"])))
    obj["anomalies"][0]["job"]["path"] = "Nope.luau"
    out = apm.parse_anomalies(obj, {"err:1"}, files=[GAME_FILE], rejected={"an-b"})["anomalies"]
    assert len(out) == 1 and out[0]["evidence"] == [] and out[0]["unverified"] == ["made:up"]
    assert out[0]["rank"] == round(6 * 0.9 * 0.5, 2) and "path" not in out[0]["job"]


# ---------------------------------------------------------------- the regression gate


def test_gate_rolls_back_on_any_hard_regression():
    base = {"studio": True, "counters": {"coins_collected": 3, "map_built": 1}, "errors": [{"message": "e 1"}],
            "checks": {"pass": 2, "passing": ["a", "b"], "failing": []}, "critic": 6, "fun": 6,
            "physics": {"flagged": []}}
    good = {**base, "errors": [], "critic": 7, "checks": {"pass": 3, "passing": ["a", "b", "c"], "failing": []}}
    g = apm.gate(base, good)
    assert g["verdict"] == "kept" and any("errors gone" in x for x in g["improvements"])
    assert any("critic score 6 -> 7" in x for x in g["improvements"])
    for bad, why in [({"compile_errors": [["x", "y"]]}, "luau-compile"),
                     ({"errors": [{"message": "e 9"}, {"message": "new boom"}]}, "new runtime errors"),
                     ({"counters": {"coins_collected": 0, "map_built": 1}}, "stopped moving"),
                     ({"checks": {"pass": 1, "passing": ["a"], "failing": ["b"]}}, "checks that passed"),
                     ({"critic": 4.5}, "critic score"), ({"critic": 3.5, "errors": []}, "critic score"),
                     ({"physics": {"flagged": [1, 2]}}, "physics")]:
        g = apm.gate(base, {**base, **bad})
        assert g["verdict"] == "rolled_back" and any(why in x for x in g["regressions"]), bad
    # a counter the jobs added themselves is not proof: with a critic dip and nothing else, roll back
    g = apm.gate(base, {**base, "critic": 5, "counters": {**base["counters"], "fix_applied": 1}})
    assert g["verdict"] == "rolled_back" and "fix_applied" in g["notes"][0]
    g = apm.gate({**base, "declared": ["coins_bought"]}, {**base, "counters": {**base["counters"], "coins_bought": 2}})
    assert g["improvements"] == ["counters now moving: coins_bought"]
    # a one-point critic dip with a measured gain (an error gone, a check passing) is LLM noise: kept
    g = apm.gate(base, {**base, "errors": [], "critic": 5})
    assert g["verdict"] == "kept" and any("soft dip" in x for x in g["improvements"])
    # a headless measurement is not compared with a Studio one on runtime errors
    assert apm.gate(base, {**base, "studio": False, "errors": [{"message": "new"}]})["verdict"] == "kept"


# ---------------------------------------------------------------- the loop


def _llm(run, script, default=None):
    return FakeLLM(script, default=default, log_path=run / "autopilot" / "calls.jsonl")


def test_loop_keeps_an_improvement_and_rolls_back_a_regression(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins never collected", 8, "fix", ["stat:untouched:coins_collected"])),
                                          _anoms(("Coins feel slow", 7, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps(), _gaps()]})
    measurer = _measure({(1, "baseline"): {"counters": {"coins_collected": 0}},
                         (1, "after"): {"critic": 7.5},
                         (2, "after"): {"errors": [{"message": "Game: nil"}]}})
    runner = FakeRunner(run)
    ap = _ap(s, "g", llm, measurer, tmp_path, runner=runner, rounds=2)
    res = ap.run()
    rounds = res["rounds"]
    assert [r["verdict"] for r in rounds] == ["kept", "rolled_back"]
    assert rounds[0]["kept"] == 1 and "critic score 6 -> 7.5" in rounds[0]["what_improved"]
    assert "new runtime errors" in rounds[1]["regressions"][0]
    # the rollback restored round 2's baseline: one changed line (kept from round 1), not two
    assert (run / "game" / GAME_FILE).read_text().count("-- changed") == 1
    assert len(runner.calls) == 2
    # measurement order: baseline, after round 1, after round 2 (round 2 reuses round 1's kept measurement)
    assert [(r, t) for r, t, _ in measurer.seen] == [(1, "baseline"), (1, "after"), (2, "after")]
    # learning: round 2's detector call carried round 1's outcome; outcomes are logged
    det2 = [c for c in llm.calls if c.role == "anomaly_detector"][1]
    assert apm.OUTCOME_MARK in det2.user and "kept" in det2.user
    outs = [json.loads(ln)["outcome"] for ln in (run / "autopilot" / "learn.jsonl").read_text().splitlines()]
    assert outs == ["kept", "rolled_back"]
    # the kept version is an iteration record forge done / the dashboard read
    state = json.loads((run / "state.json").read_text())
    assert [it["score"] for it in state["iterations"]] == [6.0, 7.5]
    assert (run / "fun" / "latest.json").exists()
    # every phase file exists, the journal says what improved
    for phase in apm.PHASES:
        assert (run / "autopilot" / "rounds" / "1" / f"{phase}.json").exists()
    assert "## Round 2: rolled_back" in (run / "autopilot" / "journal.md").read_text()
    st = json.loads((run / "autopilot" / "status.json").read_text())
    assert st["state"] == "finished" and st["stop_reason"].startswith("ran 2 round")
    assert [p["tag"] for p in st["score_trend"]] == ["baseline", "after", "after"]
    from forge.dashboard import autopilot_view
    view = autopilot_view(run)
    assert view["kept"] == 1 and view["rolled_back"] == 1 and view["anomalies"] == 2
    assert view["rounds"][0]["decisions"][0]["outcome"] == "kept"


def test_a_rollback_is_fed_back_once_as_a_correction(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    titles = iter(["Coins never collected", "Coins feel slow", "Coins look grey", "Coins spin"])
    llm = _llm(run, {}, default=lambda role, user: _anoms((next(titles), 8, "fix", ["metric:errors"]))
               if role == "anomaly_detector" else _gaps())
    measurer = _measure({(1, "after"): {"errors": [{"message": "Game: nil"}]}})
    _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), rounds=3).run()
    outs = [json.loads(ln) for ln in (run / "autopilot" / "corrections.jsonl").read_text().splitlines()]
    assert [(o["role"], o["kind"], o["round"]) for o in outs] == [("anomaly_detector", "outcome", 2)]
    dets = [c.user for c in llm.calls if c.role == "anomaly_detector"]
    assert "rolled_back" in dets[1] and "rolled_back" in dets[2]  # the history stays in the message


def test_resume_after_a_crash_redoes_only_the_unfinished_phase(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins never collected", 8, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    script = {(1, "after"): RuntimeError("Studio crashed")}
    measurer = _measure(script)
    runner = FakeRunner(run)
    with pytest.raises(RuntimeError):
        _ap(s, "g", llm, measurer, tmp_path, runner=runner, rounds=1).run()
    assert (run / "autopilot" / "rounds" / "1" / "act.json").exists()
    assert not (run / "autopilot" / "rounds" / "1" / "verify.json").exists()
    st = json.loads((run / "autopilot" / "state.json").read_text())
    assert st["phase"] == "finished" and st["round"] == 1
    res = _ap(s, "g", llm, measurer, tmp_path, runner=runner, rounds=1).run()
    assert res["rounds"][0]["verdict"] == "kept"
    assert len(runner.calls) == 1  # the job was not run again
    assert sum(1 for c in llm.calls if c.role == "anomaly_detector") == 1  # detect was not redone
    assert [(r, t) for r, t, _ in measurer.seen] == [(1, "baseline"), (1, "after"), (1, "after")]
    assert json.loads((run / "autopilot" / "state.json").read_text())["sessions"] == 2


def test_call_budget_stops_before_any_job(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins never collected", 8, "fix", ["metric:errors"]))],
                     "gap_finder": [_gaps()]})
    runner = FakeRunner(run)
    res = _ap(s, "g", llm, _measure({}), tmp_path, runner=runner, max_calls=1, rounds=3).run()
    assert res["stop_reason"].startswith("call budget spent")
    assert runner.calls == [] and res["budget"]["calls_used"] >= 1
    st = json.loads((run / "autopilot" / "status.json").read_text())
    assert st["state"] == "finished" and "budget" in st["stop_reason"]


def test_minute_budget_is_kept_across_sessions(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {}, default=lambda role, user: _anoms() if role == "anomaly_detector" else _gaps())
    now = [1000.0]
    o = apm.AutoOptions(use_studio=False, minutes=10, rounds=1, verify_reserve=0)
    ap = apm.Autopilot(s, "g", o, llm=llm, measurer=_measure({}), broker=_broker(tmp_path), clock=lambda: now[0],
                       log=lambda x: None)
    now[0] += 6 * 60
    ap.run()
    assert json.loads((run / "autopilot" / "state.json").read_text())["minutes_used"] == 6.0
    ap2 = apm.Autopilot(s, "g", o, llm=llm, measurer=_measure({}), broker=_broker(tmp_path), clock=lambda: now[0],
                        log=lambda x: None)
    now[0] += 5 * 60
    res = ap2.run()
    assert res["stop_reason"] == "time budget spent (10 min)"


def test_idea_is_made_then_booted(tmp_path, monkeypatch):
    s = _settings(tmp_path)
    made = []

    def maker(idea):
        made.append(idea)
        run = _game(s, "coin-obby")
        return run.name

    llm = FakeLLM({}, default=lambda role, user: _anoms() if role == "anomaly_detector" else _gaps())
    ap = apm.Autopilot(s, "coin obby", apm.AutoOptions(use_studio=False, rounds=1, verify_reserve=0), llm=llm,
                       measurer=_measure({}), broker=_broker(tmp_path), maker=maker, log=lambda x: None)
    res = ap.run()
    assert made == ["coin obby"] and res["slug"] == "coin-obby"
    assert json.loads((s.runs_dir / "autopilot-index.json").read_text()) == {"coin obby": "coin-obby"}
    assert res["stop_reason"].startswith("nothing above the bar")
    from forge.versions import GameVersions
    assert GameVersions(s.runs_dir / "coin-obby" / "game").current() == "v1"
    # running the same idea again resumes that game instead of building another one
    ap2 = apm.Autopilot(s, "coin obby", apm.AutoOptions(use_studio=False, rounds=1, verify_reserve=0), llm=llm,
                        measurer=_measure({}), broker=_broker(tmp_path), maker=maker, log=lambda x: None)
    assert ap2.run()["slug"] == "coin-obby" and made == ["coin obby"]


def test_human_correction_goes_to_the_task_that_made_the_finding(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": [_anoms(("Coins never collected", 8, "fix", ["metric:errors"])),
                                          _anoms()],
                     "gap_finder": [_gaps(("No saving", 6, "feature"))]})
    _ap(s, "g", llm, _measure({}), tmp_path, runner=FakeRunner(run), rounds=1, per_round=1).run()
    assert apm.find_run_with(s, "an-coins-never-collected") == "g"
    rec = apm.correct(s, "g", "an-coins-never-collected", "coins are fine, the HUD is just late", llm=llm)
    last = llm.calls[-1]
    assert last.role == "anomaly_detector" and apm.CORRECTION_MARK in last.user and "HUD is just late" in last.user
    assert rec["role"] == "anomaly_detector" and rec["request_id"] == f"fake-{len(llm.calls)}"
    rejected = json.loads((run / "autopilot" / "rejected.json").read_text())
    assert rejected[0]["id"] == "an-coins-never-collected"
    from forge.ledger import ledger
    led = ledger(s)
    assert any(e["role"] == "anomaly_detector" and e["kind"] == "correction" for e in led["entries"])
    # the rejected id is never picked again
    ds = apm.decide(apm.candidates(apm.parse_anomalies(json.loads(_anoms(
        ("Coins never collected", 8, "fix", ["metric:errors"]))), {"metric:errors"})["anomalies"], []),
        per_round=3, min_rank=1, calls_left=None, rejected={r["id"] for r in rejected})
    assert not ds[0]["picked"]
    with pytest.raises(KeyError):
        apm.correct(s, "g", "nope", "x", llm=llm)


def test_detector_failure_falls_back_to_the_prefilter(tmp_path):
    s = _settings(tmp_path)
    run = _game(s)
    llm = _llm(run, {"anomaly_detector": ["not json", "still not", "nope"], "gap_finder": [_gaps()]})
    measurer = _measure({(1, "baseline"): {"errors": [{"message": "Game: boom"}]}})
    _ap(s, "g", llm, measurer, tmp_path, runner=FakeRunner(run), rounds=1).run()
    det = json.loads((run / "autopilot" / "rounds" / "1" / "detect.json").read_text())
    assert det["anomalies"] and det["anomalies"][0]["why"].startswith("statistical pre-filter")


# ---------------------------------------------------------------- advise (read-only)


def _tree_hash(root: Path) -> str:
    h = hashlib.sha1()
    for p in sorted(root.rglob("*")):
        h.update(str(p.relative_to(root)).encode())
        if p.is_file():
            h.update(p.read_bytes())
    return h.hexdigest()


def test_advise_is_read_only_and_cites_the_records(tmp_path):
    s = _settings(tmp_path)
    root = tmp_path / "game"
    (root / "ServerScriptService").mkdir(parents=True)
    (root / "ServerScriptService" / "Fire.server.luau").write_text(
        'Telemetry.count("fires_extinguished", 1)\nTelemetry.count("fire_tick_over_budget", 1)\n')
    ev = tmp_path / "evidence" / "fab" / "improve"
    ev.mkdir(parents=True)
    for n, budget in enumerate([2, 3, 2, 30], 1):
        (ev / f"{n}.json").write_text(json.dumps({"before": [{"round": 1, "counters": {
            "fire_tick_over_budget": budget, "fires_ignited": 3}, "errors": {"count": 0, "first": []}}],
            "audit": {"anomalies": [{"title": "Hose cannot be obtained", "severity": "high", "system": "tools",
                                     "observed": "no hose"}]}}))
    (tmp_path / "games" / "fab" / "reports").mkdir(parents=True)
    (tmp_path / "games" / "fab" / "reports" / "run1.md").write_text("# Run 1\n- trucks bump at the station\n")
    llm = FakeLLM({"anomaly_detector": [_anoms(("Fire tick over budget", 7, "polish", ["stat:spike:fire_tick_over_budget"]))],
                   "gap_finder": [_gaps(("Tutorial", 6, "feature"))]})
    before = _tree_hash(root)
    rep = apm.advise(s, root, llm=llm, name="fab")
    assert _tree_hash(root) == before
    det_user = llm.calls[0].user
    assert "stat:spike:fire_tick_over_budget" in det_user and "trucks bump at the station" in det_user
    assert "stat:untouched:fires_extinguished" in det_user
    assert [c.role for c in llm.calls] == ["anomaly_detector", "gap_finder"]
    assert rep["ranked"][0]["title"] == "Fire tick over budget"
    md = (Path(rep["out_dir"]) / "report.md").read_text()
    assert "read-only" in md and "Fire tick over budget" in md and "Tutorial" in md
    assert Path(rep["out_dir"]).is_relative_to(s.runs_dir)


def test_cli_parses_autopilot():
    from forge.cli import build_parser
    a = build_parser().parse_args(["autopilot", "coin obby", "--max-calls", "120", "--studio", "Forge-agents-35"])
    assert a.target == "coin obby" and a.max_calls == 120 and a.studio == "Forge-agents-35"
    a = build_parser().parse_args(["autopilot", "--advise", "--root", "game"])
    assert a.advise and a.root == "game"
    a = build_parser().parse_args(["autopilot", "g", "--correct", "an-x", "wrong"])
    assert a.correct == ["an-x", "wrong"]
