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


VARY = [{"kind": "conveyor", "gap": 4, "size": [6, 1, 8]}, {"kind": "trampoline", "gap": 4, "size": [6, 1, 6]},
        {"kind": "spinner", "gap": 4, "size": [10, 1, 10]}, {"kind": "turntable", "gap": 4, "size": [8, 1, 8]},
        {"kind": "disappearing", "gap": 4, "count": 2, "spacing": 2}, {"kind": "pendulum", "gap": 4, "size": [6, 1, 10]},
        {"kind": "lava", "gap": 0, "rise": -0.5, "size": [8, 1, 3]}]


def good_stage(n: int) -> dict:
    """A run stage (50-80 studs, in its lane) that passes the validator and, with its neighbours, every zone rule:
    shaped platforms, a mover and a jump pad in each, two varying kinds (a distinct kind sequence per stage number). Its
    turn is the designer's guess; Forge writes the route's."""
    a, b = VARY[n % 7], VARY[(n // 7) % 7]
    rnd = {"kind": "platform", "shape": "round", "gap": 3, "size": [8, 1, 8]}
    tail = [dict(rnd, gap=0, rise=0.5)] if b["kind"] == "lava" else []
    first = [a, dict(rnd, gap=0, rise=0.5)] if a["kind"] == "lava" else [a]
    return {"stage": n, "name": f"Hop {n}", "turn": 30 if n % 2 else -30, "pieces": [
        rnd, {"kind": "moving", "gap": 4, "move": [4, 0, 0]}, *first, {"kind": "jumppad", "gap": 4}, b, *tail,
        {"kind": "checkpoint", "gap": 4, "rise": 1}]}


LIFTS = [[{"kind": "jumppad", "gap": 4}, {"kind": "checkpoint", "gap": 6, "rise": 16}],
         [{"kind": "trampoline", "gap": 4}, {"kind": "checkpoint", "gap": 4, "rise": 16}],
         [{"kind": "moving", "gap": 3, "move": [0, 16, 0], "period": 5}, {"kind": "checkpoint", "gap": 3, "rise": 16}]]


def corner_stage(n: int) -> dict:
    """A route corner: one lifting piece, then the checkpoint 16 up, 23-26 studs long."""
    return {"stage": n, "name": f"Lift {n}", "pieces": LIFTS[n % 3]}


def route_stage(n: int, first: int, count: int) -> dict:
    plan = obby.route_plan(count)
    return corner_stage(n) if plan[n - first]["role"] == "corner" else good_stage(n)


def bad_stage(n: int) -> dict:
    return {"stage": n, "name": f"Leap {n}", "pieces": [{"kind": "platform", "gap": 14}, {"kind": "checkpoint", "gap": 5}]}


def zone_reply(zone: int, first: int, count: int, bad: tuple[int, ...] = ()) -> str:
    stages = [bad_stage(n) if n in bad else route_stage(n, first, count) for n in range(first, first + count)]
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
    assert "## Park theme: entrance" in first and "## Park theme: finale" in llm.calls[1].user
    assert 'Zone 1 "Zone Name 1" (stages 1-4)' in llm.calls[1].user  # the second zone sees the first
    luau = store.game_dir / obby.LEVELS_DIR / "Zone02.luau"
    assert luau.exists() and "stage = 5" in luau.read_text() and 'theme_id = "finale"' in luau.read_text()
    assert "turn = -90" in luau.read_text() and "turn = 30" not in luau.read_text()  # Forge's route, not the model's
    data = json.loads((store.dir / "levels" / "zone-01.json").read_text())
    assert obby.validate_zone(data, 1, 4) == [] and data["name"] == "Zone Name 1" and data["theme_id"] == "entrance"
    assert obby.zone_rules(data, 1, 4, "entrance") == [] and obby.footprint_problems(data, 1, 4) == []
    assert [s["turn"] for s in data["stages"]] == [r["turn"] for r in obby.route_plan(4)] == [0, 0, -90, -90]
    assert data["palette"] == list(obby.THEME_PALETTES["entrance"])  # the landmark's colours, not the model's
    finale = json.loads((store.dir / "levels" / "zone-02.json").read_text())
    assert finale["palette"] == list(obby.THEME_PALETTES["finale"]) and finale["palette"][0] != data["palette"][0]
    spec = store.load_spec()
    assert spec["levels"]["zones"] == 2 and spec["levels"]["stages_per_zone"] == 4
    plan = spec["levels"]["plan"]
    assert [p["zone"] for p in plan] == [1, 2] and [p["theme_id"] for p in plan] == ["entrance", "finale"]
    assert {"platform", "moving", "jumppad"} <= set(plan[0]["kinds"]) and plan[0]["rules_left"] == 0
    assert plan[0]["stats"]["turned"] == 2 and plan[0]["stats"]["plain_share"] == 0
    assert plan[0]["stats"]["outside_plot"] == 0 and plan[0]["stats"]["extent"][1] <= obby.PLOT_HALF_WIDTH
    summary = levels.render_summary(res)
    assert "plain platforms 0%" in summary and "ZONE-RULE" not in summary and "0 stages outside it" in summary
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
    # stage 2 breaks one jump and two zone rules (all plain platforms, no obstacle): 3 errors, then none
    assert res["ok"] and res["calls"] == 2 and res["zones"][0]["corrections"] == 1 and res["zones"][0]["errors"] == [3, 0]
    first, correction = llm.calls
    assert correction.role == first.role == "level_designer" and correction.session_id == first.session_id
    assert correction.user.startswith(first.user[:2000])
    assert ("- stage 2 jump from the start pad to piece 1 (platform): gap 14.0 at rise 0.0 > max 10.0"
            in correction.user)
    assert "- stage 2 has no obstacle: give it at least one of" in correction.user
    assert '"name": "Leap 2"' in correction.user and "only the corrected stages (2)" in correction.user
    data = json.loads((store.dir / "levels" / "zone-01.json").read_text())
    assert [s["name"] for s in data["stages"]] == ["Hop 1", "Hop 2", "Lift 3"]
    log = [json.loads(ln) for ln in (store.dir / "levels" / "log.jsonl").read_text().splitlines()]
    assert log[0]["attempts"][0]["errors"] == 3 and log[0]["attempts"][0]["rules"] == 2 and log[0]["corrections"] == 1


def test_a_corner_that_stays_broken_falls_back_to_a_short_lift(settings):
    store = make_game(settings)
    still = json.dumps({"stages": [bad_stage(3)]})
    llm = FakeLLM({"level_designer": [zone_reply(1, 1, 4, bad=(3,)), still, still]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=4, log=lambda _: None)
    assert res["zones"][0]["fallback"] == [3]
    data = json.loads((store.dir / "levels" / "zone-01.json").read_text())
    corner = data["stages"][2]
    assert corner["fallback"] and corner["turn"] == -90 and len(corner["pieces"]) == 2
    assert obby.validate_zone(data, 1, 4) == [] and obby.footprint_problems(data, 1, 4) == []
    for n in range(3):
        st = obby.fallback_stage(n, 5, corner=True)
        lo, hi = obby.CORNER_LENGTH
        assert obby.validate_stage(st, n) == [] and lo <= obby.stage_length(st) <= hi, n
        assert obby.course_layout({"stages": [st]}, n, 1)[0][-1]["y"] >= obby.CORNER_LIFT[0], n
    assert len({tuple(p["kind"] for p in obby.fallback_stage(n, 5, corner=True)["pieces"]) for n in range(3)}) == 3


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
    assert "Stage 60 is the zone's finale" in user and "## Park theme: coaster" in user  # from the planned name
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


def test_zone_theme_comes_from_the_plan_then_the_names_then_the_park_order():
    park = {"title": "Funfair Frenzy", "pitch": "An amusement park obby"}
    assert [levels.zone_theme(park, z, 10) for z in range(1, 11)] == list(obby.THEMES)
    assert levels.zone_theme(park, 1, 1) == "entrance" and levels.zone_theme(park, 4, 4) == "finale"
    planned = dict(park, levels={"plan": [{"zone": 2, "theme_id": "pirate"}, {"zone": 3, "theme": "ferris"},
                                          {"zone": 4, "name": "Ghost Train Gulch"}, {"zone": 5, "name": "Teacup Twirl"}]})
    assert [levels.zone_theme(planned, z, 10) for z in (2, 3, 4, 5)] == ["pirate", "ferris", "haunted", "teacups"]
    lava = {"title": "Lava Rising", "pitch": "climb floating platforms before the lava gets you; parkour"}
    assert levels.zone_theme(lava, 1, 5) is None and not levels.is_park(lava)
    assert levels.zone_theme(dict(lava, levels={"plan": [{"zone": 1, "name": "Pirate Cove"}]}), 1, 5) == "pirate"


def test_every_example_stage_is_valid_and_shows_its_theme():
    assert set(levels.EXAMPLES) == set(obby.THEMES) == set(levels.THEME_NOTES)
    for theme, ex in levels.EXAMPLES.items():
        st = obby.normalize_stage(ex, ex["stage"])
        assert obby.validate_stage(st, ex["stage"]) == [], theme
        assert [p for p in obby.rule_problems({"stages": [st]}, ex["stage"], 1, theme) if p["stage"]] == [], theme
        assert all(any(test(p) for p in st["pieces"]) for _, _, test in obby.SIGNATURES[theme]), theme
        assert any(p.get("shape") not in (None, "block") for p in st["pieces"]) and "turn" not in ex, theme
        lo, hi = obby.RUN_LENGTH
        assert lo <= obby.stage_length(st) <= hi, theme  # a run stage of the route
        assert obby.run_climbs({"stages": [st]}, ex["stage"], 1)[0]["climb"] <= 4, theme  # rises, then drops back
        surfaces, _ = obby.layout(st)
        assert max(abs(s.x) + s.bw / 2 + abs((s.move or (0,))[0]) for s in surfaces[1:]) <= obby.LANE_HALF_WIDTH, theme
    corner = obby.normalize_stage(dict(levels.CORNER_EXAMPLE, turn=obby.CORNER_TURN), 6)
    assert obby.validate_stage(corner, 6) == [] and obby.CORNER_LENGTH[0] <= obby.stage_length(corner) <= obby.CORNER_LENGTH[1]


def test_zone_message_teaches_the_theme_turns_zone_rules_and_an_example():
    spec = {"title": "Funfair Frenzy", "pitch": "An amusement park obby", "core_loop": "run the rides"}
    user = levels.zone_message(spec, 2, 10, 20)
    from forge.roles import MAX_USER_CHARS
    assert len(user) < MAX_USER_CHARS * 0.6
    assert "## Park theme: carousel\nThis zone is a giant merry-go-round" in user
    assert "Signature kinds: turntable and moving" in user
    assert "- stage 22: turntable: a signature kind of this zone" in user  # introduced early in the zone
    assert "Kinds you may use in this zone: checkpoint, platform, lava, moving" in user and "turntable" in user
    assert "## Zone rules" in user and "At least 6 of the 20 stages turn" in user
    assert "its signature turntable and moving each appear in at least 6 of the 20 stages" in user
    assert "The course never crosses itself" in user and "at least 20 studs above its start" in user
    assert "its plot beside its ride: every piece, mover's path and jump within x -38 to 38" in user
    assert ("- stages 21-25: run 1, out (away from the start): turn 0\n- stage 26: corner (turn -90)\n"
            "- stages 27-30: run 2, back (toward the start): stage 27 turns -90, the rest 0") in user
    assert "Run stages: 50-80 studs long each" in user and "Corners: 20-26 studs long: ONE piece" in user
    assert '{"stage": 26, "name": "Big Top Bounce"' in user  # the corner example sits on the zone's first corner
    assert "Alternate left and right turns" not in user and "alternating +30" not in user
    assert json.dumps(levels.EXAMPLES["carousel"], ensure_ascii=False) in user
    assert "## Work fast: recipes that pass\nDo not check every jump or lay out the turns in your head" in user
    assert levels.MAX_TOKENS >= 64_000  # a 20-stage zone with the zone rules ran out of a 32k cap reasoning, live
    assert "Every stage: stage, name, turn 0 [-90, 90]" in user and "cylinder (a log" in user
    finale = levels.zone_message(spec, 10, 10, 20)
    assert "Signature: a mix" in finale and "at least 6 different kinds (the finale mixes everything)" in finale
    plain = levels.zone_message({"title": "Lava Rising", "pitch": "a lava obby"}, 1, 5, 20)
    assert "## Park theme" not in plain and "## Zone rules" in plain and "signature" not in plain.split("## Zone rules")[1][:900]
    _, _, allowed = levels.usable_kinds(100, 1, 20, None)
    assert len(allowed) - 1 >= obby.MIN_ZONE_KINDS + 1  # room for the kinds rule even before the schedule gets there


def same_stage(n: int) -> dict:
    return {"stage": n, "name": f"Same {n}", "pieces": [
        {"kind": "platform", "gap": 5}, {"kind": "moving", "gap": 12, "move": [0, 0, -6]}, {"kind": "checkpoint", "gap": 5}]}


def test_zone_rule_errors_go_back_as_corrections_with_the_zone_overview(settings):
    store = make_game(settings)
    plain = json.dumps({"zone": 1, "name": "Copy Paste", "stages": [same_stage(n) for n in range(1, 4)]})
    fixed = json.dumps({"stages": [route_stage(n, 1, 3) for n in range(1, 4)]})
    llm = FakeLLM({"level_designer": [plain, fixed]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=3, log=lambda _: None)
    assert res["ok"] and res["calls"] == 2 and res["zones"][0]["errors"] == [6, 0]
    correction = llm.calls[1].user
    assert "- stage 1 and stages 2 and 3 share the kind sequence [platform, moving]" in correction
    assert "- the zone is the entrance zone: its signature kind jumppad is in 0 of its 3 stages" in correction
    assert "turns in" not in correction.split("## Your previous level data")[1]  # Forge wrote the route's turns
    assert ("- stage 3 piece 3 (checkpoint) leaves the zone's plot: x -52.0 is past its left edge (-38); keep to the "
            "route's turns and stage lengths") in correction  # a 47-stud corner puts its lane 47 studs over
    assert ("## The zone now (stage: route role, turn, heading, length, where its checkpoint ends, kinds)\n"
            "1: run, turn 0 (heading 0), 47 studs, ends at x 0 z 47 height 0.0; platform > moving > checkpoint\n"
            "2: run, turn 0 (heading 0), 47 studs, ends at x 0 z 94 height 0.0; platform > moving > checkpoint\n"
            "3: corner, turn -90 (heading -90), 47 studs, ends at x -47 z 94 height 0.0; platform > moving > checkpoint"
            ) in correction
    assert "only the corrected stages (1, 2, 3) and any other stages you change to meet the zone rules" in correction


def test_zone_rules_still_broken_after_the_corrections_are_written_and_reported(settings):
    store = make_game(settings)
    plain = json.dumps({"zone": 1, "name": "Copy Paste", "stages": [same_stage(n) for n in range(1, 4)]})
    llm = FakeLLM({"level_designer": [plain, plain, plain]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=3, log=lambda _: None)
    z = res["zones"][0]
    assert res["calls"] == 3 and res["ok"] is False and z["fallback"] == [] and len(z["rules_left"]) >= 3
    assert "ZONE-RULE errors left" in levels.render_summary(res) and (store.dir / "levels/zone-01.json").exists()
    assert store.load_spec()["levels"]["plan"][0]["rules_left"] == len(z["rules_left"])


def test_rerun_redesigns_a_reachable_zone_that_breaks_the_zone_rules(settings):
    store = make_game(settings)
    old = obby.normalize_zone(json.loads(json.dumps({"zone": 1, "name": "Old", "stages": [same_stage(n) for n in (1, 2, 3)]})),
                              1, 1, 3)
    assert obby.validate_zone(old, 1, 3) == []  # an overnight-style zone: every jump fine, no variety
    (store.dir / "levels").mkdir(parents=True)
    (store.dir / "levels" / "zone-01.json").write_text(json.dumps(old))
    llm = FakeLLM({"level_designer": [zone_reply(1, 1, 3)]}, log_path=store.calls_log)
    res = levels.run_levels(settings, "park", llm=llm, zones=(1, 1), stages_per_zone=3, log=lambda _: None)
    assert res["zones"][0]["status"] == "written" and res["calls"] == 1 and res["ok"]


def test_correction_message_fits_the_user_budget():
    zone = obby.normalize_zone(json.loads(zone_reply(1, 1, 20, bad=tuple(range(1, 21)))), 1, 1, 20)
    errors = obby.validate_zone(zone, 1, 20)
    msg = levels.correction_message("x" * 30_000, zone, errors, 1, 20)
    assert len(msg) <= 24_100 and "## Your previous level data has errors" in msg
    assert director.kit_index()  # the kit the levels need is in the index


def test_zone_theme_never_gives_a_later_zone_a_ride_an_earlier_zone_has():
    spec = {"title": "Funfair Frenzy", "pitch": "an amusement park obby", "levels": {"plan": [
        {"zone": 1, "name": "Grand Entrance", "theme_id": "entrance"},
        {"zone": 2, "name": "Candy Carousel", "theme_id": "carousel"},
        {"zone": 3, "name": "Coaster Corner", "theme_id": "coaster"},
        {"zone": 4, "name": "Coaster Lights Midway", "theme": "neon arcade under coaster lights"}]}}
    # the words name a taken ride, so the zone gets its park-order ride (teacups for zone 4), or the next free one
    assert levels.zone_theme(spec, 4, 6) == "teacups"
    # once nobody has the coaster, the zone's own words pick it
    spec["levels"]["plan"][2] = {"zone": 3, "name": "Teacup Twirl", "theme_id": "teacups"}
    assert levels.zone_theme(spec, 4, 6) == "coaster"
    # a theme the plan sets explicitly is kept, even a repeat (a human chose it)
    spec["levels"]["plan"][3]["theme_id"] = "carousel"
    assert levels.zone_theme(spec, 4, 6) == "carousel"
