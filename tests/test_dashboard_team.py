"""forge dashboard: the live team panels (agent lanes, screenshot feed, Mubit ledger, version timeline,
speed) built from fixture run folders."""

from __future__ import annotations

import dataclasses
import json
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import pytest

from forge import dashboard as db
from forge.config import load_settings
from forge.memory import RunStore
from forge.versions import GameVersions

PNG = (b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde"
       b"\x00\x00\x00\x0cIDATx\x9cc\xf8\xcf\xc0\x00\x00\x03\x01\x01\x00\xc9\xfe\x92\xef\x00\x00\x00\x00IEND\xaeB`\x82")
T0 = datetime(2026, 10, 24, 12, 0, 0, tzinfo=timezone.utc)


def iso(secs: float) -> str:
    return (T0 + timedelta(seconds=secs)).isoformat(timespec="seconds")


def call(role: str, end: float, ms: int, rid: str) -> dict:
    return {"ts": iso(end), "role": role, "request_id": rid, "latency_ms": ms, "session_id": "s1"}


def trace(dirpath, role: str, end: float, rid: str, user: str, reply: str) -> None:
    dirpath.mkdir(parents=True, exist_ok=True)
    (dirpath / f"20261024T12{int(end):04d}000000-{role}-{rid}.json").write_text(json.dumps(
        {"ts": iso(end), "role": role, "session_id": "s1", "request_id": rid, "user": user, "reply": reply}))


@pytest.fixture
def settings(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "tycoon")
    store.ensure()
    store.save_spec({"title": "Cube Cash Tycoon", "pitch": "drop cubes, get rich"})
    state = store.new_state("tycoon")
    state["iterations"] = [{"n": 1, "score": 6.0, "version": "v1", "summary": "works, thin"},
                           {"n": 2, "score": 8.5, "fun": 7.0, "version": "v2", "summary": "conveyor feels good"}]
    state["corrections"] = [{"path": "Shop.luau", "note": "price never updates", "request_id": "mreq_h1",
                             "ts": iso(200)}]
    store.save_state(state)
    (store.dir / "iterations" / "1").mkdir(parents=True)
    (store.dir / "iterations" / "1" / "critique.json").write_text(json.dumps({"score": 6, "fun": 4.5}))
    (store.dir / "iterations" / "1" / "screenshot.png").write_bytes(PNG)

    gd = store.game_dir
    gd.mkdir(parents=True, exist_ok=True)
    (gd / "Main.luau").write_text("return 1\n")
    GameVersions(gd).snapshot("iteration 1: code under test")
    (gd / "Main.luau").write_text("local x = 1\nreturn x\n")
    (gd / "Shop.luau").write_text("return {}\n")
    GameVersions(gd).snapshot("iteration 2: code under test")

    # three coders at once (0-20s), then a critic, then a fixer
    calls = [call("designer", 10, 10_000, "mreq_d"),
             call("coder", 30, 20_000, "mreq_c1"), call("coder", 31, 20_000, "mreq_c2"),
             call("coder", 32, 21_000, "mreq_c3"), call("critic", 50, 8_000, "mreq_k"),
             call("fixer", 70, 9_000, "mreq_f")]
    (store.dir / "calls.jsonl").write_text("\n".join(json.dumps(c) for c in calls) + "\n")
    tr = store.dir / "traces"
    trace(tr, "designer", 10, "mreq_d", "## Game idea\na cube tycoon\n", '{"title": "Cube Cash", "summary": "plots and droppers"}')
    trace(tr, "coder", 30, "mreq_c1", "## Module to write\npath: ServerScriptService/Dropper.luau\n",
          "```luau\n-- Dropper spawns a cube every 2s\nreturn {}\n```")
    trace(tr, "coder", 31, "mreq_c2", "path: ServerScriptService/Shop.luau\n", "```luau\nreturn {}\n```")
    trace(tr, "coder", 32, "mreq_c3", "path: ServerScriptService/Plots.luau\n", "```luau\nreturn {}\n```")
    trace(tr, "critic", 50, "mreq_k", "## Game spec\n...", '{"score": 8.5, "summary": "conveyor feels good"}')
    trace(tr, "fixer", 70, "mreq_f", "## File\npath: Shop.luau\n## Problem\nprice never updates\n",
          "```luau\n-- recompute price on purchase\nreturn {}\n```")

    # a tester run with two screenshot steps
    run = store.dir / "tests" / "20261024-120100-a1"
    run.mkdir(parents=True)
    (run / "report.json").write_text(json.dumps({
        "persona": "speedrunner", "goal": "buy the first dropper", "started": iso(60), "ended": None,
        "steps": [{"n": 1, "action": {"action": "move_to", "args": {"target": "Shop"}, "reason": "the shop sells droppers"},
                   "result": "arrived", "latency_ms": 900, "ts": iso(62),
                   "assertions": [{"text": "Shop prompt visible", "ok": True}]},
                  {"n": 2, "action": {"action": "interact", "reason": "buy it"}, "result": "no money change",
                   "latency_ms": 1200, "ts": iso(65),
                   "assertions": [{"text": "cash drops by 50", "ok": False, "detail": "cash stayed 100"}]}]}))
    (run / "step-01.png").write_bytes(PNG)
    (run / "step-02.png").write_bytes(PNG)
    (run / "step-03.png").write_bytes(PNG)  # screenshot ahead of the report
    (run / "step-03.json").write_text(json.dumps({"action": "wait", "reason": "let the cube drop"}))

    # a fix cycle where the fixer was corrected and its retry verified
    imp = store.dir / "improve"
    imp.mkdir()
    (imp / "scores.json").write_text(json.dumps([{"cycle": 1, "ts": iso(80), "open": 0}]))
    (imp / "1.json").write_text(json.dumps({"cycle": 1, "session_id": "s1", "ts": iso(80), "code_fixes": [
        {"anomaly": "price never updates", "status": "kept", "version": "v2",
         "attempts": [{"status": "not_fixed"}, {"status": "fixed"}]}]}))
    trace(imp / "traces", "fixer", 75, "mreq_f1", "## File\n: price never updates\n", "{}")
    trace(imp / "traces", "fixer", 78, "mreq_f2",
          "## Your previous fix was rejected\n: price never updates\n", "{}")
    return s


def team(settings) -> dict:
    d = db.collect(settings)
    return d["games"][0]["team"], d


def test_lanes_split_parallel_coders_and_add_testers(settings):
    t, _ = team(settings)
    lanes = {ln["id"]: ln for ln in t["lanes"]["lanes"]}
    coders = [ln for ln in lanes.values() if ln["role"] == "coder"]
    assert len(coders) == 3 and {c["label"] for c in coders} == {"coder #1", "coder #2", "coder #3"}
    assert t["lanes"]["parallel_peak"] >= 3
    assert lanes["designer"]["thought"] == "plots and droppers"
    assert lanes["fixer"]["step"] == "Shop.luau: price never updates"
    assert lanes["fixer"]["thought"] == "recompute price on purchase" and lanes["fixer"]["latency_ms"] == 9000
    assert any(c["step"] == "writing Dropper.luau" and c["thought"] == "Dropper spawns a cube every 2s" for c in coders)
    tester = lanes["tester-20261024-120100-a1"]
    assert tester["kind"] == "tester" and tester["label"] == "speedrunner"
    assert tester["step"] == "step 3: wait" and tester["thought"] == "let the cube drop"
    assert tester["passed"] == 1 and tester["failed"] == 1
    roles = [ln["role"] for ln in t["lanes"]["lanes"]]
    assert roles.index("designer") < roles.index("coder") < roles.index("tester") < roles.index("critic")


def test_screenshot_feed_has_shots_and_assertions(settings):
    t, _ = team(settings)
    tester = t["testers"][0]
    assert tester["status"] == "running" and tester["n_steps"] == 3
    s1, s2, s3 = tester["steps"]
    assert s1["ok"] is True and s1["action"] == "move_to Shop" and s1["shot"].endswith("step-01.png")
    assert s2["ok"] is False and s2["assertions"][0] == {"text": "cash drops by 50", "ok": False, "detail": "cash stayed 100"}
    assert s3["ok"] is None and s3["shot"]
    assert t["critic_shots"] == [{"n": 1, "shot": "/api/shot?slug=tycoon&path=iterations/1/screenshot.png"}]


def test_timeline_scores_fun_and_diff(settings):
    t, _ = team(settings)
    v1, v2 = t["timeline"]
    assert (v1["score"], v1["fun"], v1["delta"]) == (6.0, 4.5, None)
    assert (v2["score"], v2["fun"], v2["delta"]) == (8.5, 7.0, 2.5)
    assert v2["files"] == 2 and v2["added"] == 3 and v2["removed"] == 1 and v2["current"]
    assert v2["fixes"] == ["price never updates"]


def test_speed_from_calls_shows_parallel_saving(settings):
    t, _ = team(settings)
    sp = t["speed"]
    coder = next(s for s in sp["stages"] if s["stage"] == "coder")
    assert coder["parallel"] == 3 and coder["before_secs"] == 61.0 and coder["secs"] == 22.0 and coder["x"] == 2.8
    assert sp["speedups"][0]["stage"] == "all Mubit calls" and sp["speedups"][0]["x"] > 1
    assert sp["calls"] == 6 and sp["p50_ms"] == 20_000


def test_timings_json_overrides_lanes_and_stages(settings):
    run = settings.runs_dir / "tycoon"
    (run / "timings.json").write_text(json.dumps({
        "stages": [{"name": "build", "start": iso(0), "end": iso(30), "before_secs": 90}],
        "calls": [{"role": "coder", "lane": "coder-1", "start": iso(0), "end": iso(20), "step": "Dropper.luau",
                   "thought": "spawn loop", "latency_ms": 20000},
                  {"role": "coder", "lane": "coder-2", "start": iso(1), "end": None, "step": "Shop.luau"}],
        "speedups": [{"stage": "build", "before_secs": 90, "after_secs": 30}]}))
    t, _ = team(settings)
    lanes = {ln["id"]: ln for ln in t["lanes"]["lanes"]}
    assert lanes["coder-1"]["status"] == "done" and lanes["coder-1"]["thought"] == "spawn loop"
    assert lanes["coder-2"]["status"] == "running" and lanes["coder-2"]["spans"][0][1] is None
    assert t["has_timings"] and t["lanes"]["running"] >= 2  # coder-2 and the live tester
    assert t["speed"]["stages"][0] == {"stage": "build", "start": pytest.approx(T0.timestamp()),
                                       "end": pytest.approx(T0.timestamp() + 30), "secs": 30.0, "before_secs": 90.0,
                                       "parallel": None, "running": False, "x": 3.0}
    assert t["speed"]["speedups"] == [{"stage": "build", "before_secs": 90.0, "after_secs": 30.0, "x": 3.0}]


def test_read_timings_tolerates_junk(tmp_path):
    p = tmp_path / "timings.json"
    assert db.read_timings(p)["stages"] == []
    p.write_text("not json")
    assert db.read_timings(p)["lanes"] == []
    p.write_text(json.dumps([{"name": "design", "secs": 4}, {"role": "critic", "start": 1, "end": 2}]))
    t = db.read_timings(p)
    assert t["stages"][0]["secs"] == 4 and t["calls"][0]["role"] == "critic"


def test_ledger_moments_show_correction_to_model_update(settings):
    db._TTL.clear()
    _, d = team(settings)
    led = d["mubit"]["ledger"]
    fixer = next(r for r in led["roles"] if r["role"] == "fixer")
    assert fixer["corrections"] == 2 and fixer["kept"] == 1 and fixer["train_at"] == 25
    kinds = {(m["kind"], m["request_id"]) for m in led["moments"]}
    assert ("correction", "mreq_f2") in kinds and ("verified", "mreq_f2") not in kinds
    assert ("correction", "mreq_h1") in kinds  # the human `forge correct`
    m = next(m for m in led["moments"] if m["request_id"] == "mreq_f2")
    assert m["role"] == "fixer" and m["what"] == "price never updates" and m["example_n"] >= 1
    assert m["verified"] is True and m["verdict"] == "fixed"  # the corrected retry was then proved in play
    assert led["console"].startswith("https://")


def test_thought_and_step_parsers():
    assert db.thought_of('{"reason": "go to the shop"}') == "go to the shop"
    assert db.thought_of('```json\n{"score": 7}\n```') == "score 7/10"
    assert db.thought_of("```luau\n-- builds the plots\nreturn 1\n```") == "builds the plots"
    assert db.thought_of("") == ""
    assert db.step_of("path: a/B.luau\n") == "writing B.luau"
    assert db.step_of("nothing") == ""


def test_shot_route_serves_only_run_pngs(settings):
    server = db.serve("127.0.0.1", 0, settings)
    port = server.server_address[1]
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{port}"
    try:
        state = json.loads(urllib.request.urlopen(base + "/api/state", timeout=5).read())
        shot = state["games"][0]["team"]["testers"][0]["steps"][0]["shot"]
        r = urllib.request.urlopen(base + shot, timeout=5)
        assert r.headers["Content-Type"] == "image/png" and r.read() == PNG
        for bad in ("/api/shot?slug=tycoon&path=../../etc/passwd.png", "/api/shot?slug=tycoon&path=spec.json",
                    "/api/shot?slug=nope&path=tests/x/step-01.png", "/api/shot?slug=tycoon&path=game/x.png"):
            with pytest.raises(urllib.error.HTTPError) as e:
                urllib.request.urlopen(base + bad, timeout=5)
            assert e.value.code == 404
    finally:
        server.shutdown()


def test_old_tester_run_without_end_is_stopped(settings):
    d = db.team_view(settings, "tycoon", db.game_view(settings, "tycoon"), now=time.time() + 3600)
    assert d["testers"][0]["status"] == "stopped"
