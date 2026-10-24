"""ForgeBridge "Runs" panel: the activity feed (forge/dashboard.py activity_view) built from fixture run
folders, the bridge's GET /activity route, and the plugin build that embeds studio-plugin/Activity.luau."""

from __future__ import annotations

import dataclasses
import json
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path

import pytest

from forge import bridge as fb
from forge import dashboard as db
from forge.config import load_settings
from forge.memory import RunStore

REPO = Path(__file__).resolve().parent.parent
TOKEN = "t0ken"
NOW = 1_800_000_000.0


def iso(t: float) -> str:
    return datetime.fromtimestamp(t, timezone.utc).isoformat(timespec="seconds")


def _age(path: Path, t: float) -> None:
    os.utime(path, (t, t))


@pytest.fixture
def settings(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "obby")
    store.ensure()
    store.save_spec({"title": "Funfair Frenzy"})
    state = store.new_state("obby")
    state["iterations"] = [
        {"n": 1, "score": 6.0, "errors": [], "studio": True, "summary": "works", "ended": iso(NOW - 500)},
        {"n": 2, "score": 5.0, "errors": [{"message": "Game.server:3: attempt to index nil"}], "studio": True,
         "summary": "broke the shop", "ended": iso(NOW - 100)},
    ]
    store.save_state(state)
    (store.dir / "timings.json").write_text(json.dumps({"running": True, "calls": [
        {"role": "director", "label": "design doc + spec.json", "start": NOW - 900, "end": NOW - 850,
         "ok": True, "latency_ms": 50000, "request_id": "mreq_d"},
        {"role": "coder", "label": "ServerScriptService/Shop.luau", "start": NOW - 700, "end": NOW - 600,
         "ok": True, "latency_ms": 40000, "request_id": "mreq_c", "n_calls": 2},
        {"role": "coder", "label": "ServerScriptService/Hud.luau", "start": NOW - 650, "end": NOW - 640,
         "ok": False, "error": "compile: bad token", "request_id": "mreq_c2"},
        {"role": "coder", "label": "ServerScriptService/Late.luau", "start": NOW - 30, "end": None, "ok": None},
    ]}))
    (store.dir / "levels").mkdir()
    (store.dir / "levels" / "log.jsonl").write_text("\n".join(json.dumps(r) for r in (
        {"ts": iso(NOW - 800), "zone": 1, "first": 1, "count": 10, "theme_id": "entrance",
         "attempts": [{"request_id": "mreq_l1", "errors": 0}]},
        {"ts": iso(NOW - 780), "zone": 3, "first": 21, "count": 10, "theme_id": "bumper",
         "attempts": [{"request_id": "mreq_l2", "errors": 2, "first_errors": ["stage 29 piece 4: too high"]},
                      {"request_id": "mreq_l3", "errors": 0}]},
    )) + "\n")
    (store.dir / "autopilot").mkdir()
    (store.dir / "autopilot" / "status.json").write_text(json.dumps({"state": "finished", "rounds": [
        {"round": 1, "ts": iso(NOW - 300), "verdict": "rolled_back", "kept": 0, "rolled_back": 3,
         "why": "Onboarding HUD stuck on step 1"},
        {"round": 2, "ts": iso(NOW - 200), "verdict": "kept", "kept": 1, "rolled_back": 0,
         "what_improved": "counters now moving: shop_nudge"},
    ]}))
    # a Mubit call logged after timings.json's last call (an improve pass), with its trace
    (store.dir / "improve").mkdir()
    (store.dir / "improve" / "calls.jsonl").write_text(json.dumps(
        {"ts": iso(NOW - 50), "role": "fixer", "request_id": "mreq_f", "latency_ms": 9000}) + "\n")
    (store.dir / "improve" / "traces").mkdir()
    (store.dir / "improve" / "traces" / "20261024T000000-fixer-mreq_f.json").write_text(json.dumps(
        {"user": "path: ServerScriptService/Shop.luau\n## Problem\nprice never updates",
         "reply": '{"summary": "price is read once at start"}'}))
    for p in store.dir.rglob("*"):
        _age(p, NOW - 60)

    old = RunStore(s, "old-tycoon")
    old.ensure()
    old.save_state(old.new_state("old-tycoon"))
    old.calls_log.write_text(json.dumps({"ts": iso(NOW - 9000), "role": "coder", "request_id": "mreq_o",
                                         "latency_ms": 1000}) + "\n")
    (old.dir / "timings.json").write_text(json.dumps({"running": True, "calls": [
        {"role": "coder", "label": "Main.luau", "start": NOW - 9100, "end": None, "ok": None}]}))
    for p in [old.dir, *old.dir.rglob("*")]:
        _age(p, NOW - 9000)
    return s


def test_feed_lists_newest_run_first_with_one_line_actions(settings):
    feed = db.activity_view(settings, runs=5, events=20, now=NOW)
    assert [r["slug"] for r in feed["runs"]] == ["obby", "old-tycoon"]
    run = feed["runs"][0]
    assert run["title"] == "Funfair Frenzy" and run["status"] == "running" and run["age_s"] == 60
    texts = [e["text"] for e in run["events"]]
    assert texts[0] == "coder wrote ServerScriptService/Late.luau"
    assert texts[1] == "fixer: Shop.luau: price never updates"
    for want in ("coder wrote ServerScriptService/Shop.luau", "level_designer zone 3: 0 errors after 2 tries",
                 "level_designer zone 1: 0 errors", "playtest round 2: 1 errors, score 5.0",
                 "autopilot round 2: kept (kept 1, rolled back 0)",
                 "autopilot round 1: rolled_back (kept 0, rolled back 3)", "director: design doc + spec.json"):
        assert want in texts, want
    ages = [e["age_s"] for e in run["events"]]
    assert ages == sorted(ages), "newest first"
    by = {e["text"]: e for e in run["events"]}
    assert by["coder wrote ServerScriptService/Late.luau"]["status"] == "running"
    assert by["coder wrote ServerScriptService/Hud.luau"]["status"] == "fail"
    assert "compile: bad token" in by["coder wrote ServerScriptService/Hud.luau"]["detail"]
    assert by["playtest round 2: 1 errors, score 5.0"]["status"] == "fail"
    assert "attempt to index nil" in by["playtest round 2: 1 errors, score 5.0"]["detail"]
    assert by["playtest round 1: 0 errors, score 6.0"]["status"] == "ok"
    assert by["autopilot round 1: rolled_back (kept 0, rolled back 3)"]["status"] == "fail"
    assert by["autopilot round 2: kept (kept 1, rolled back 0)"]["status"] == "ok"
    assert "2 Mubit calls" in by["coder wrote ServerScriptService/Shop.luau"]["detail"]
    fixer = by["fixer: Shop.luau: price never updates"]
    assert fixer["request_id"] == "mreq_f" and "price is read once at start" in fixer["detail"]


def test_feed_limits_runs_and_events(settings):
    feed = db.activity_view(settings, runs=1, events=3, now=NOW)
    assert len(feed["runs"]) == 1 and len(feed["runs"][0]["events"]) == 3
    assert db.activity_view(settings, runs=0, now=NOW)["runs"] == []


def test_a_crashed_run_is_idle_and_its_open_call_stopped(settings):
    old = db.activity_view(settings, runs=5, events=5, now=NOW)["runs"][1]
    assert old["status"] == "idle" and old["age_s"] == 9000
    by = {e["text"]: e for e in old["events"]}
    assert by["coder wrote Main.luau"]["status"] == "stopped"
    assert by["coder: writing a module"]["status"] == "ok"


def test_a_live_job_keeps_a_run_running_while_its_files_are_stale(tmp_path):
    """A long Mubit call or playtest writes nothing for minutes; the job pid still says it is running."""
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "tycoon")
    store.ensure()
    store.save_state(store.new_state("tycoon"))
    (store.dir / "timings.json").write_text(json.dumps({"running": True, "calls": [
        {"role": "critic", "label": "playtest", "start": NOW - 400, "end": None, "ok": None}]}))
    for p in [store.dir, *store.dir.rglob("*")]:
        _age(p, NOW - 400)
    (s.runs_dir / "jobs").mkdir()
    job = s.runs_dir / "jobs" / "j1.json"
    job.write_text(json.dumps({"id": "j1", "pid": os.getpid(), "args": ["new", "tycoon"],
                               "log": str(s.runs_dir / "jobs" / "j1.log")}))
    assert [r["status"] for r in db.running(s, NOW)] == ["running"]
    run = db.activity_view(s, runs=1, events=5, now=NOW)["runs"][0]
    assert run["status"] == "running"
    assert [(e["text"], e["status"]) for e in run["events"]] == [("critic: playtest", "running")]

    dead = subprocess.Popen(["true"])
    dead.wait()
    for pid in (dead.pid, 0):
        job.write_text(json.dumps({"id": "j1", "pid": pid, "args": ["new", "tycoon"]}))
        run = db.activity_view(s, runs=1, events=5, now=NOW)["runs"][0]
        assert run["status"] == "idle" and run["events"][0]["status"] == "stopped", pid


def test_a_job_for_another_game_does_not_mark_this_one_running(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")
    store = RunStore(s, "tycoon")
    store.ensure()
    store.save_state(store.new_state("tycoon"))
    (store.dir / "timings.json").write_text(json.dumps({"calls": []}))
    for p in [store.dir, *store.dir.rglob("*")]:
        _age(p, NOW - 400)
    (s.runs_dir / "jobs").mkdir()
    (s.runs_dir / "jobs" / "j1.json").write_text(json.dumps(
        {"id": "j1", "pid": os.getpid(), "args": ["new", "tycoon-2"]}))
    assert db.activity_view(s, runs=1, now=NOW)["runs"][0]["status"] == "idle"


def test_feed_with_no_runs(tmp_path):
    s = dataclasses.replace(load_settings(), runs_dir=tmp_path / "nothing")
    assert db.activity_view(s, now=NOW) == {"now": NOW, "runs": []}


# ---------------------------------------------------------------- bridge route


@pytest.fixture
def server(settings):
    seen = []

    def feed(runs, events):
        seen.append((runs, events))
        return db.activity_view(settings, runs, events, now=NOW)

    bridge = fb.Bridge(TOKEN, ["Forge-agents-25"], poll_wait=1, activity=feed)
    srv = fb.serve_in_thread(bridge, 0)
    yield srv.server_address[1], seen
    srv.shutdown()
    srv.server_close()


def test_activity_route_serves_the_feed_and_clamps_its_query(server):
    port, seen = server
    c = fb.BridgeClient(port, TOKEN)
    got = c.activity(runs=1, events=2)
    assert [r["slug"] for r in got["runs"]] == ["obby"] and len(got["runs"][0]["events"]) == 2
    c._call("GET", "/activity?runs=99&events=0")
    assert seen == [(1, 2), (10, 1)]


def test_activity_route_needs_the_token(server):
    port, _ = server
    with pytest.raises(fb.BridgeError, match="401"):
        fb.BridgeClient(port, "wrong").activity()


def test_activity_route_without_a_feed_is_a_clear_409():
    bridge = fb.Bridge(TOKEN, ["x"])
    srv = fb.serve_in_thread(bridge, 0)
    try:
        with pytest.raises(fb.BridgeError, match="409.*activity feed"):
            fb.BridgeClient(srv.server_address[1], TOKEN).activity()
    finally:
        srv.shutdown()
        srv.server_close()


def test_activity_source_reads_the_checkout_runs(tmp_path, settings):
    root = settings.runs_dir.parent
    feed = fb.activity_source(root)(2, 2)
    assert [r["slug"] for r in feed["runs"]][:1] == ["obby"] and time.time() - feed["now"] < 60


# ---------------------------------------------------------------- plugin build


def test_built_plugin_embeds_the_activity_module_and_keeps_the_no_op_guard():
    built = fb.build_plugin(REPO, "abc123", 40000, ["Forge-agents-25"])
    first, rest = built.split("\n", 1)
    assert first == "--!nocheck"
    assert rest.startswith("local Activity = (function()\n")
    assert rest.index("return Activity") < rest.index('local URL = "http://127.0.0.1:40000"')
    assert '"/activity?runs=3&events=5"' in built and "Activity.rows(feed)" in built


@pytest.mark.skipif(not shutil.which("luau-compile"), reason="luau-compile not on PATH")
def test_built_plugin_compiles(tmp_path):
    out = tmp_path / "ForgeBridge.lua"
    out.write_text(fb.build_plugin(REPO, "abc123", 40000, ["Forge-agents-25"]))
    r = subprocess.run(["luau-compile", "--null", str(out)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr + r.stdout
