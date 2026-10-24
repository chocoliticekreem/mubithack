"""`forge levels`: the level_designer Mubit task, validator corrections in the same task, fallbacks, resumability,
and what lands in the game (ObbyKit, Levels data modules, obby genre checks). FakeLLM only."""

from __future__ import annotations

import dataclasses
import json
import shutil
import subprocess

import pytest

from forge import checks, director, levels, obby
from forge.cli import build_parser
from forge.config import load_settings
from forge.llm import FakeLLM, load_prompt
from forge.memory import RunStore

LUAU = shutil.which("luau-compile")


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


def make_game(settings, slug: str = "park", **spec_extra) -> RunStore:
    store = RunStore(settings, slug)
    store.ensure()
    store.save_spec({"title": "Funfair Frenzy", "slug": slug, "pitch": "An amusement park obby",
                     "core_loop": "jump through themed zones", "modules": [], "acceptance": [], **spec_extra})
    store.save_state(store.new_state("park obby"))
    (store.game_dir / "ReplicatedStorage").mkdir(parents=True)
    return store


def good_stage(n: int) -> dict:
    return {"stage": n, "name": f"Hop {n}", "pieces": [
        {"kind": "platform", "gap": 5, "side": 3}, {"kind": "moving", "gap": 12, "move": [0, 0, -6]},
        {"kind": "checkpoint", "gap": 5}]}


def bad_stage(n: int) -> dict:
    return {"stage": n, "name": f"Leap {n}", "pieces": [{"kind": "platform", "gap": 14}, {"kind": "checkpoint", "gap": 5}]}


def zone_reply(zone: int, first: int, count: int, bad: tuple[int, ...] = ()) -> str:
    stages = [bad_stage(n) if n in bad else good_stage(n) for n in range(first, first + count)]
    return json.dumps({"zone": zone, "name": f"Zone Name {zone}", "theme": "candy floss skies",
                       "palette": ["#FF8A65", "#4FC3F7", "#FFD54F"], "material": "SmoothPlastic", "stages": stages})


def test_prompt_is_fixed_and_role_registered():
    text = load_prompt("level_designer")
    assert "ONLY one JSON object" in text and "Corrections:" in text
    assert "Funfair" not in text and "stage 41" not in text  # nothing per call


def test_a_valid_zone_is_written_as_data_with_the_kit_and_checks(settings):
    store = make_game(settings)
    llm = FakeLLM({"level_designer": [zone_reply(1, 1, 4), zone_reply(2, 5, 4)]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 2), stages_per_zone=4, log=lambda _: None)
    assert res["ok"] and res["stages"] == 8 and res["planned"] == 8 and res["calls"] == 2
    assert [z["status"] for z in res["zones"]] == ["written", "written"]
    assert all(c.role == "level_designer" and c.session_id == "park" for c in llm.calls)
    first = llm.calls[0].user
    assert "Zone 1 of 2: stages 1 to 4" in first and "## Obstacle kinds" in first and "## Jump limits" in first
    assert "1:1 2:" in first and "Choose a name and theme" in first
    assert 'Zone 1 "Zone Name 1" (stages 1-4)' in llm.calls[1].user  # the second zone sees the first
    luau = store.game_dir / obby.LEVELS_DIR / "Zone02.luau"
    assert luau.exists() and "stage = 5" in luau.read_text()
    data = json.loads((store.dir / "levels" / "zone-01.json").read_text())
    assert obby.validate_zone(data, 1, 4) == [] and data["name"] == "Zone Name 1"
    spec = store.load_spec()
    assert spec["levels"]["zones"] == 2 and spec["levels"]["stages_per_zone"] == 4
    assert [p["zone"] for p in spec["levels"]["plan"]] == [1, 2] and spec["levels"]["plan"][0]["kinds"] == ["platform", "moving"]
    assert any(m.get("kit") == "ObbyKit" and m["prebuilt"] for m in spec["modules"])
    assert (store.game_dir / "ReplicatedStorage/Kit/ObbyKit.luau").exists()
    ids = {c.id for c in checks.load_checks(store.dir)}
    assert "obby-stage-count" in ids and "local expected = 8" in (store.dir / "checks/obby-stage-count.luau").read_text()
    if LUAU:
        r = subprocess.run([LUAU, "--null", str(luau)], capture_output=True, text=True)
        assert r.returncode == 0, r.stderr


def test_validator_errors_go_back_as_a_correction_in_the_same_task(settings):
    store = make_game(settings)
    fixed = json.dumps({"stages": [good_stage(2)]})
    llm = FakeLLM({"level_designer": [zone_reply(1, 1, 3, bad=(2,)), fixed]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=3, log=lambda _: None)
    assert res["ok"] and res["calls"] == 2 and res["zones"][0]["corrections"] == 1 and res["zones"][0]["errors"] == [1, 0]
    first, correction = llm.calls
    assert correction.role == first.role == "level_designer" and correction.session_id == first.session_id
    assert correction.user.startswith(first.user[:2000])
    assert ("- stage 2 jump from the start pad to piece 1 (platform): gap 14.0 at rise 0.0 > max 10.0"
            in correction.user)
    assert '"name": "Leap 2"' in correction.user and "only the corrected stages (2)" in correction.user
    data = json.loads((store.dir / "levels" / "zone-01.json").read_text())
    assert [s["name"] for s in data["stages"]] == ["Hop 1", "Hop 2", "Hop 3"]
    log = [json.loads(ln) for ln in (store.dir / "levels" / "log.jsonl").read_text().splitlines()]
    assert log[0]["attempts"][0]["errors"] == 1 and log[0]["corrections"] == 1


def test_stages_still_broken_after_two_corrections_become_fallbacks(settings):
    store = make_game(settings)
    still = json.dumps({"stages": [bad_stage(2)]})
    llm = FakeLLM({"level_designer": [zone_reply(1, 1, 3, bad=(2,)), still, still]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=3, log=lambda _: None)
    assert res["calls"] == 3 and res["zones"][0]["fallback"] == [2] and res["ok"] is False
    data = json.loads((store.dir / "levels" / "zone-01.json").read_text())
    assert data["stages"][1]["fallback"] is True and obby.validate_zone(data, 1, 3) == []
    assert "FALLBACK stages [2]" in levels.render_summary(res)


def test_a_zone_whose_call_fails_is_reported_and_the_next_zone_still_runs(settings):
    store = make_game(settings)
    llm = FakeLLM({"level_designer": ["no json here", "still none", "nope", zone_reply(2, 4, 3)]},
                  log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 2), stages_per_zone=3, log=lambda _: None)
    assert [z["status"] for z in res["zones"]] == ["failed", "written"] and res["ok"] is False
    assert "zone  1: FAILED" in levels.render_summary(res) and not (store.dir / "levels" / "zone-01.json").exists()


def test_rerun_skips_valid_zones_and_restores_missing_data_modules(settings):
    store = make_game(settings)
    llm = FakeLLM({"level_designer": [zone_reply(1, 1, 3)]}, log_path=store.calls_log)
    levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=3, log=lambda _: None)
    luau = store.game_dir / obby.LEVELS_DIR / "Zone01.luau"
    luau.unlink()
    again = FakeLLM({}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=again, zones=(1, 1), log=lambda _: None)
    assert again.calls == [] and res["zones"][0]["status"] == "skipped" and res["calls"] == 0 and luau.exists()
    with pytest.raises(SystemExit, match="keep --stages-per-zone 3"):
        levels.run_levels(settings, "park", llm=again, zones=(1, 1), stages_per_zone=20, log=lambda _: None)


def test_planned_zone_names_and_total_zones_shape_the_message(settings):
    store = make_game(settings, levels={"plan": [{"zone": 3, "name": "Coaster Canyon", "theme": "rollercoaster rails"}]})
    llm = FakeLLM({"level_designer": [zone_reply(3, 41, 20)]}, log_path=store.calls_log)
    levels.run_levels(settings, "park", llm=llm, zones=(3, 3), total_zones=10, log=lambda _: None)
    user = llm.calls[0].user
    assert "Zone 3 of 10: stages 41 to 60" in user and "Planned name: Coaster Canyon; theme: rollercoaster rails" in user
    assert "Already introduced (use them freely)" in user and "New in this zone" in user
    assert "Stage 60 is the zone's finale" in user
    spec = store.load_spec()
    assert spec["levels"]["zones"] == 10 and "local expected = 200" in (store.dir / "checks/obby-stage-count.luau").read_text()


def test_difficulty_curve_and_mechanic_schedule():
    total, per = 200, 20
    curve = [levels.difficulty(n, total, per) for n in range(1, total + 1)]
    assert min(curve) >= 1 and max(curve) == 10 and curve[0] <= 2
    assert curve[19] > curve[18] and curve[104] < curve[103]  # zone finale up, breather down
    assert sum(curve[180:]) / 20 > sum(curve[:20]) / 20 + 3  # later zones are harder
    intro = levels.intro_stages(total)
    assert [m[1] for m in intro] == [m[0] for m in levels.MECHANICS] and intro[0][0] == 1
    assert max(m[0] for m in intro) <= 0.75 * total and all(b[0] - a[0] <= 8 for a, b in zip(intro, intro[1:]))
    assert levels.parse_zones("3") == (3, 3) and levels.parse_zones("1-10") == (1, 10)
    with pytest.raises(ValueError):
        levels.parse_zones("5-2")


def test_cli_parses_forge_levels():
    args = build_parser().parse_args(["levels", "park", "--zones", "1-2", "--stages-per-zone", "10", "--total-zones", "10"])
    assert (args.cmd, args.slug, args.zones, args.stages_per_zone, args.total_zones) == ("levels", "park", "1-2", 10, 10)


def test_correction_message_fits_the_user_budget():
    zone = obby.normalize_zone(json.loads(zone_reply(1, 1, 20, bad=tuple(range(1, 21)))), 1, 1, 20)
    errors = obby.validate_zone(zone, 1, 20)
    msg = levels.correction_message("x" * 30_000, zone, errors, 1, 20)
    assert len(msg) <= 24_100 and "## Your previous level data has errors" in msg
    assert director.kit_index()  # the kit the levels need is in the index
