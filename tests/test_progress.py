"""Live build progress (forge/progress.py): runs/<slug>/progress.json is always valid JSON, pct only goes up while
running, events are capped, a crash marks the build failed, and a fake `forge new` of a template obby writes it
from the plan through every zone and script to done."""
from __future__ import annotations

import asyncio
import dataclasses
import io
import json
import re
import threading

import pytest

from forge import director, progress
from forge.config import load_settings
from forge.llm import FakeLLM, fake_default_reply
from forge.loop import UI, new_game
from forge.memory import RunStore
from forge.progress import Progress
from tests.test_levels import zone_reply


class Clock:
    def __init__(self):
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


def load(path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_pct_moves_by_time_and_items_and_never_goes_down(tmp_path):
    clock = Clock()
    path = tmp_path / "progress.json"
    p = Progress(path, "park", clock=clock)
    seen = [load(path)["pct"]]
    p.phase("design", "Planning")
    for _ in range(10):
        clock.t += 20
        p.tick()
        seen.append(load(path)["pct"])
    assert 0 < seen[-1] < 15 and seen[1] < seen[-1]  # creeps inside the design band, never reaches its top
    p.phase("levels", "Designing zones", items=("zones", 10))
    p.step("Designing zones 1-5 of 10", inflight=5)
    clock.t += 60
    p.tick()
    mid = load(path)["pct"]
    assert 15 < mid < 15 + 5 * 6.5  # creeping toward the five zones in flight, below the step they complete
    for _ in range(10):
        clock.t += 30
        p.item_done()
        seen.append(load(path)["pct"])
    assert seen[-1] == 80
    p.phase("design", "a phase going back must not move pct back")
    p.tick()
    seen.append(load(path)["pct"])
    assert seen == sorted(seen)
    p.done("Game ready")
    out = load(path)
    assert out["pct"] == 100 and out["phase"] == "done" and out["running"] is False
    assert out["events"][-1] == {"t": clock.t, "text": "Game ready", "ok": True}


def test_events_are_capped_newest_last_and_items_reported(tmp_path):
    path = tmp_path / "progress.json"
    p = Progress(path, "park")
    p.phase("build", "Writing 3 scripts", items=("scripts", 3))
    for i in range(55):
        p.event(f"event {i}", i % 2 == 0)
    p.item_done()
    out = load(path)
    assert len(out["events"]) == progress.MAX_EVENTS and out["events"][-1]["text"] == "event 54"
    assert out["items"] == {"label": "scripts", "done": 1, "total": 3} and out["phase"] == "build"
    assert set(out) == {"slug", "command", "running", "pct", "phase", "step", "items", "started", "updated", "eta_s",
                        "events"}


def test_an_exception_marks_the_build_failed_and_stops_the_ticker(tmp_path):
    path = tmp_path / "progress.json"
    with pytest.raises(KeyError):
        with Progress(path, "park") as p:
            p.phase("levels", "Designing", items=("zones", 2))
            p.item_done()
            raise KeyError("boom")
    out = load(path)
    assert out["phase"] == "failed" and out["running"] is False and out["pct"] > 0
    assert out["events"][-1]["ok"] is False and "KeyError" in out["events"][-1]["text"]
    assert not any(t.name == "forge-progress" and t.is_alive() for t in threading.enumerate())


def test_the_file_is_valid_json_while_many_threads_write(tmp_path):
    path = tmp_path / "progress.json"
    p = Progress(path, "park").start()
    p.phase("levels", "Designing", items=("zones", 400))
    bad: list[str] = []
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            try:
                load(path)
            except ValueError as e:
                bad.append(str(e))

    def writer(k):
        for i in range(100):
            p.event(f"w{k} {i}")
            p.item_done()

    r = threading.Thread(target=reader)
    r.start()
    ws = [threading.Thread(target=writer, args=(k,)) for k in range(4)]
    for w in ws:
        w.start()
    for w in ws:
        w.join()
    stop.set()
    r.join()
    p.stop()
    assert bad == [] and load(path)["items"]["done"] == 400
    assert not list(tmp_path.glob(".*.tmp"))


# ---------------------------------------------------------------- forge new, end to end (FakeLLM)

ZONE_ASK = re.compile(r"Zone (\d+) of \d+: stages (\d+) to (\d+)")


def park_spec() -> dict:
    kits = {e["name"]: e for e in director.kit_index()}
    mods = [director.kit_module(kits[n]) for n in ("ParkObby", "ObbyKit", "WorldKit", "ObbyThemes")]
    return {"title": "Funfair Frenzy", "slug": "funfair", "pitch": "An amusement park obby",
            "core_loop": "jump through themed zones", "acceptance": [],
            "modules": mods + [{"path": "ServerScriptService/FunfairGifts.server.luau", "purpose": "gifts",
                                "depends": []}]}


def reply(role: str, user: str) -> str:
    if role == "level_designer":
        z, a, b = map(int, ZONE_ASK.search(user).groups())
        return zone_reply(z, a, b - a + 1)
    if role == "designer":
        return json.dumps(park_spec())
    if role == "coder":
        return "```luau\nreturn {}\n```"
    return fake_default_reply(role, user)


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def test_forge_new_writes_progress_from_the_plan_to_done(settings):
    llm = FakeLLM({}, default=reply, latency={"level_designer": 0.05})
    idea = "build me an amusement park obby with 100 stages"
    slug = asyncio.run(new_game(idea, iterations=0, use_studio=False, settings=settings, llm=llm,
                                ui=UI(io.StringIO()), use_director=False, jobs=6))
    store = RunStore(settings, slug)
    out = load(store.dir / "progress.json")
    assert out["running"] is False and out["phase"] == "done" and out["pct"] == 100
    assert out["items"] == {"label": "scripts", "done": 1, "total": 1}
    texts = [e["text"] for e in out["events"]]
    assert "Game plan ready: Funfair Frenzy, 10 zones x 10 stages" in texts
    assert "You asked for 100 stages: building 10 zones x 10 stages" in texts
    built = [re.match(r"Zone (\d+) of 10 '.+' built: 10 stages, \d+ errors?", t) for t in texts]
    assert sorted(int(m.group(1)) for m in built if m) == list(range(1, 11))
    assert "Wrote ServerScriptService/FunfairGifts.server.luau" in texts
    assert "Build finished: 100 stages, 0 compile errors" in texts and texts[-1] == "Game ready: Funfair Frenzy"
    spec = store.load_spec()
    lv = spec["levels"]
    assert (lv["zones"], lv["stages_per_zone"], lv["requested_stages"], lv["scope_note"]) == (10, 10, 100, None)
    assert [p["zone"] for p in lv["plan"]] == list(range(1, 11)) and len({p["theme_id"] for p in lv["plan"]}) == 10
    assert llm.peak_concurrency > 1  # the zones went out together
    config = (store.game_dir / "ReplicatedStorage/Config.luau").read_text()
    assert config.count("theme = ") == 10


def test_a_zone_finishing_does_not_freeze_the_zones_still_in_flight(tmp_path):
    clock = Clock()
    path = tmp_path / "progress.json"
    p = Progress(path, "park", clock=clock)
    p.phase("levels", "Designing", items=("zones", 10))
    p.step("Designing zones 1-8 of 10", inflight=8)
    clock.t += 125
    p.tick()
    p.item_done()
    at = load(path)["pct"]
    clock.t += 30
    p.tick()
    assert load(path)["pct"] > at  # the other 7 zones keep their head start


def test_the_bands_follow_the_phases_the_build_runs(tmp_path):
    clock = Clock()
    path = tmp_path / "progress.json"
    p = Progress(path, "tycoon", clock=clock)
    clock.t += 75
    p.tick()
    p.plan(["build", "playtest"])  # no levels: building is most of the work, not a jump to 80
    p.phase("build", "Writing 4 scripts", items=("scripts", 4))
    assert 9 <= load(path)["pct"] <= 16
    for _ in range(4):
        clock.t += 30
        p.item_done()
    assert 55 <= load(path)["pct"] <= 62
    p.phase("playtest", "Playtesting the game", items=("playtest rounds", 1))
    seen = []
    for _ in range(5):
        clock.t += 30
        p.tick()
        seen.append((load(path)["pct"], load(path)["eta_s"]))
    assert seen[0][0] < seen[-1][0] < 98 and all(eta and eta > 0 for _, eta in seen)  # the playtest moves the bar
    p.plan(["levels", "build", "playtest"])
    assert [tuple(round(x) for x in p.bands[k]) for k in ("levels", "build", "playtest")] == \
        [(15, 70), (70, 85), (85, 98)]


def test_forge_new_reports_each_playtest_round_and_retries_a_failed_zone(settings):
    tries = {"zone 3": 0}

    def flaky(role: str, user: str) -> str:
        m = ZONE_ASK.search(user) if role == "level_designer" else None
        if m and int(m.group(1)) == 3 and tries["zone 3"] < 3:  # the call and its JSON retries, first time round
            tries["zone 3"] += 1
            return "no json here"
        return reply(role, user)

    llm = FakeLLM({}, default=flaky)
    slug = asyncio.run(new_game("an amusement park obby with 40 stages", iterations=1, use_studio=False,
                                settings=settings, llm=llm, ui=UI(io.StringIO()), use_director=False, jobs=4))
    out = load(RunStore(settings, slug).dir / "progress.json")
    texts = [e["text"] for e in out["events"]]
    assert any(re.match(r"Zone 3 of 4 failed: .*; retrying it", t) for t in texts), texts
    assert any(re.match(r"Zone 3 of 4 '.+' built", t) for t in texts)
    assert "Build finished: 40 stages, 0 compile errors" in texts and not any("planned stages" in t for t in texts)
    assert any(t.startswith("Playtest round 1 done") for t in texts) and out["phase"] == "done"
    designer = next(c.user for c in llm.calls if c.role == "designer")
    assert "## Course scope (Forge builds exactly this)" in designer and "4 zones of 10 stages" in designer
