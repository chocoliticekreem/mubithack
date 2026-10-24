"""forge dashboard: live build progress (runs/<slug>/progress.json) on "Running now" and the Runs panel feed."""

from __future__ import annotations

import dataclasses
import json

import pytest

from forge import dashboard as db
from forge.config import load_settings
from forge.memory import RunStore

NOW = 1_800_000_000.0


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def progress(**over) -> dict:
    p = {"slug": "funfair", "command": "new", "running": True, "pct": 42, "phase": "levels",
         "step": "Designing zones 3, 4, 5 of 10", "items": {"label": "zones", "done": 3, "total": 10},
         "started": NOW - 100, "updated": NOW - 2, "eta_s": 180,
         "events": [{"t": NOW - 100 + i, "text": f"event {i}", "ok": True} for i in range(9)]
         + [{"t": NOW - 3, "text": "Zone 3 of 10 'Carousel Climb' built: 10 stages, 2 errors", "ok": False}]}
    return {**p, **over}


def write(settings, slug: str, body) -> RunStore:
    store = RunStore(settings, slug)
    store.dir.mkdir(parents=True, exist_ok=True)
    (store.dir / "progress.json").write_text(body if isinstance(body, str) else json.dumps(body))
    return store


def test_live_progress_is_cleaned_and_keeps_the_newest_six_events_newest_first(settings):
    store = write(settings, "funfair", progress())
    p = db.progress_view(store.dir, NOW)
    assert (p["pct"], p["phase"], p["running"], p["stalled"], p["eta_s"]) == (42, "levels", True, False, 180)
    assert p["items"] == {"label": "zones", "done": 3, "total": 10}
    assert [e["text"] for e in p["events"]][1:] == ["event 8", "event 7", "event 6", "event 5", "event 4"]
    assert p["events"][0]["ok"] is False and p["events"][0]["text"].startswith("Zone 3 of 10")


def test_missing_corrupt_and_partial_progress(settings):
    store = RunStore(settings, "funfair")
    store.dir.mkdir(parents=True)
    assert db.progress_view(store.dir, NOW) is None
    for bad in ('{"pct": 4', "[1, 2]", "null", ""):
        write(settings, "funfair", bad)
        assert db.progress_view(store.dir, NOW) is None, bad
    write(settings, "funfair", {"pct": "lots", "items": {"label": "zones"}, "events": ["x", {"ok": 1}, {"text": "hi", "ok": "y"}]})
    p = db.progress_view(store.dir, NOW)
    assert (p["pct"], p["items"], p["running"], p["eta_s"]) == (0, None, False, None)
    assert p["events"] == [{"t": None, "text": "hi", "ok": None}]
    write(settings, "funfair", {"pct": 140})
    assert db.progress_view(store.dir, NOW)["pct"] == 100


def test_running_but_not_updated_for_two_minutes_is_stalled(settings):
    store = write(settings, "funfair", progress(updated=NOW - db.PROGRESS_STALE - 1))
    p = db.progress_view(store.dir, NOW)
    assert (p["running"], p["stalled"], p["eta_s"]) == (False, True, None)
    write(settings, "funfair", progress(running=False, phase="done", pct=100, updated=NOW - 9999))
    assert db.progress_view(store.dir, NOW)["stalled"] is False


def test_now_view_gives_a_live_build_its_own_card_before_the_game_has_a_spec(settings):
    write(settings, "funfair", progress())
    rows = db.now_view([], [], NOW, db.progress_all(settings, NOW))
    assert len(rows) == 1
    r = rows[0]
    assert (r["kind"], r["slug"], r["status"], r["step"], r["elapsed"]) == \
        ("build", "funfair", "running", "Designing zones 3, 4, 5 of 10", 100)
    assert r["progress"]["pct"] == 42 and len(r["progress"]["events"]) == 6


def test_now_view_rides_progress_on_the_job_building_it(settings):
    write(settings, "funfair", progress())
    job = {"name": "job-1", "kind": "job", "status": "running", "command": 'forge new "a funfair obby"',
           "started": NOW - 100, "updated": NOW - 1, "tail": ["[director] planning"]}
    rows = db.now_view([job], [], NOW, db.progress_all(settings, NOW))
    assert [(r["name"], r["slug"], r["progress"]["pct"]) for r in rows] == [("job-1", "funfair", 42)]
    game = {"slug": "funfair", "title": "Funfair Frenzy", "agents": [],
            "live": {"name": "job-1", "role": "coder", "line": "[coder] Shop.luau"}}
    rows = db.now_view([job], [game], NOW, db.progress_all(settings, NOW))
    assert len(rows) == 1 and rows[0]["title"] == "Funfair Frenzy" and rows[0]["step"] == "Designing zones 3, 4, 5 of 10"


def test_now_view_drops_finished_and_long_stalled_builds_but_flags_a_fresh_stall(settings):
    write(settings, "done", progress(running=False, phase="done", pct=100, updated=NOW - db.PROGRESS_FRESH - 1))
    write(settings, "dead", progress(updated=NOW - db.PROGRESS_SHOWN - 1))
    write(settings, "stuck", progress(updated=NOW - db.PROGRESS_STALE - 30))
    rows = db.now_view([], [], NOW, db.progress_all(settings, NOW))
    assert [(r["slug"], r["status"], r["progress"]["stalled"]) for r in rows] == [("stuck", "stalled", True)]


def test_a_build_that_just_finished_stays_on_running_now_for_its_go_test_moment(settings):
    # a MuMake build has no job row: without its own row the page never sees it finish (the "go test" pop-up)
    write(settings, "fresh", progress(running=False, phase="done", pct=100, updated=NOW - 5))
    rows = db.now_view([], [], NOW, db.progress_all(settings, NOW))
    assert [(r["slug"], r["status"], r["progress"]["phase"]) for r in rows] == [("fresh", "done", "done")]


def test_activity_view_carries_progress_and_lists_a_build_still_in_design(settings):
    write(settings, "funfair", progress())
    old = RunStore(settings, "old")
    old.ensure()
    old.save_spec({"title": "Old"})
    feed = db.activity_view(settings, runs=3, events=5, now=NOW)
    by = {r["slug"]: r for r in feed["runs"]}
    assert by["funfair"]["progress"]["step"] == "Designing zones 3, 4, 5 of 10"
    assert by["old"]["progress"] is None
    write(settings, "funfair", "{broken")
    assert {r["slug"]: r for r in db.activity_view(settings, now=NOW)["runs"]}["funfair"]["progress"] is None


def test_an_old_finished_build_does_not_take_over_a_later_run_of_the_same_game(settings):
    write(settings, "obby", progress(slug="obby", running=False, phase="done", pct=100, step="Game ready: Obby",
                                     updated=NOW - 86400))
    job = {"name": "job-2", "kind": "job", "status": "running", "command": "forge run obby", "started": NOW - 50,
           "updated": NOW - 1, "tail": []}
    game = {"slug": "obby", "title": "Obby", "agents": [],
            "live": {"name": "job-2", "role": "critic", "line": "critic: reviewing iteration 2"}}
    rows = db.now_view([job], [game], NOW, db.progress_all(settings, NOW))
    assert [(r["slug"], r["step"]) for r in rows] == [("obby", "critic: reviewing iteration 2")]
    assert "progress" not in rows[0]
    write(settings, "obby", progress(slug="obby", running=False, phase="done", pct=100, step="Game ready: Obby",
                                     updated=NOW - 5))  # just finished: its job row still shows the 100%
    rows = db.now_view([job], [game], NOW, db.progress_all(settings, NOW))
    assert rows[0]["progress"]["pct"] == 100
