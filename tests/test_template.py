"""Template games (forge/template.py): ParkObby's Config and bootstraps are rendered from the spec, the director
and designer are told what the template already does, and invented counters never reach acceptance."""
from __future__ import annotations

import json
import shutil
import subprocess

import pytest

from forge import director, template
from forge.llm import FakeLLM

needs_luau = pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not installed")
PARK = next(e for e in director.kit_index() if e["name"] == "ParkObby")
FILES = PARK["template"]["files"]


def _park_spec(plan: list[dict]) -> dict:
    return {"title": "Funfair Frenzy", "modules": [director.kit_module(PARK)], "acceptance": [],
            "levels": {"zones": len(plan), "stages_per_zone": 10, "plan": plan}}


def test_park_themes_are_distinct_and_follow_the_zone():
    plan = [{"name": "Grand Entrance", "theme": "the front gate"}, {"name": "Candy Carousel", "theme": "pink ponies"},
            {"name": "Spooky Lane", "theme": "haunted"}, {"name": "Second Carousel", "theme": "carousel"},
            {"name": "Rocket Night", "theme": "fireworks finale"}]
    themes = template.park_themes(plan)
    assert themes[:3] == ["entrance", "carousel", "haunted"]
    assert themes[3] != "carousel" and len(set(themes)) == len(themes)  # a taken theme is never reused
    assert themes[4] == "finale"
    assert set(themes) <= set(template.PARK_THEMES)


def test_config_takes_its_zones_from_the_level_plan_in_order():
    plan = [{"zone": 1, "name": "Grand Entrance", "theme": "entrance"},
            {"zone": 2, "name": 'Ferris "Wheel" Heights', "theme": "ferris"}]
    files = template.rendered_files(_park_spec(plan))
    assert set(files) == set(FILES)
    config = files["ReplicatedStorage/Config.luau"]
    assert config.index('"Grand Entrance"') < config.index('"Ferris \\"Wheel\\" Heights"')  # quotes escaped
    assert 'theme = "ferris"' in config and 'mood = "pop"' in config and 'FinishReward = "ChampionCape"' in config
    server = next(t for p, t in files.items() if p.endswith(".server.luau"))
    assert "ParkObby.startServer(" in server and "ParkObby.startClient(" not in server


def test_a_game_without_a_template_renders_nothing(tmp_path):
    spec = {"modules": [director.kit_module(director.kit_index()[0])], "acceptance": []}
    assert template.template_of(spec) is None and template.render(spec, tmp_path) == []


@needs_luau
def test_rendered_files_compile(tmp_path):
    plan = [{"zone": i, "name": f"Zone {i}", "theme": t} for i, t in enumerate(template.PARK_THEMES, 1)]
    for path in template.render(_park_spec(plan), tmp_path):
        out = subprocess.run(["luau-compile", str(tmp_path / path)], capture_output=True, text=True)
        assert out.returncode == 0, (path, out.stderr)


def test_install_kit_renders_the_template_and_the_fixer_cannot_edit_it(tmp_path):
    spec = _park_spec([{"zone": 1, "name": "Grand Entrance", "theme": "entrance"}])
    written = director.install_kit(spec, tmp_path)
    assert set(FILES) <= set(written) and all((tmp_path / f).is_file() for f in FILES)
    assert set(FILES) <= director.protected_paths(spec, tmp_path)


def test_the_kits_fire_the_counters_the_director_may_name():
    counters = director.kit_counters(director.match_kit_modules("an amusement park obby with costumes"))
    assert {"checkpoint_reached", "coin_collected", "costume_equip", "costume_buy"} <= set(counters)


DOC = {"fantasy": "Run a giant amusement park obby", "core_loop": "jump -> checkpoint -> next zone",
       "systems": [], "juice": [], "visual_style": {"palette": ["#FF8A65"]}, "sounds": [], "module_budget": 9,
       "acceptance": [],
       "first_60_seconds": [{"t": 5, "beat": "grab coins", "counter": "coin_collected", "min": 3},
                            {"t": 20, "beat": "equip ears", "counter": "costume_equipped", "min": 1}]}


def test_template_mode_plans_content_not_systems():
    spec_out = {"title": "Funfair Frenzy", "slug": "ff", "pitch": "p", "core_loop": "c", "acceptance": [],
                "modules": [{"path": f, "purpose": "", "depends": []} for f in FILES]
                + [{"path": "ServerScriptService/PhotoBooth.server.luau", "purpose": "photo booth", "depends": []}]}
    llm = FakeLLM({"director": [json.dumps(DOC)], "designer": [json.dumps(spec_out)]})
    spec = director.plan(llm, "An amusement-park obby: 6 themed zones, music and lobby costumes", "", session_id="g")
    d_call, s_call = llm.calls
    assert "## Prebuilt template: ParkObby" in d_call.user and "costume_equip" in d_call.user
    assert "## Prebuilt template: ParkObby" in s_call.user and "at most 2 extra" in s_call.user
    by_path = {m["path"]: m for m in spec["modules"]}
    assert all(by_path[f]["prebuilt"] and by_path[f]["purpose"].startswith("RENDERED") for f in FILES)
    assert not by_path["ServerScriptService/PhotoBooth.server.luau"].get("prebuilt")
    assert spec["director"]["module_budget"] == 2
    # the invented counter is dropped from the beat (it would be dead by construction); the kit's one stays
    assert [(b["beat"], b["counter"]) for b in spec["first_60s"]] == [("grab coins", "coin_collected"), ("equip ears", "")]
    assert not any("costume_equipped" in a for a in spec["acceptance"])


def test_config_uses_the_level_designers_theme_id_verbatim():
    # the level data was built with these ids: Config must match them even when they repeat, or WorldKit's ride
    # and ObbyThemes' dressing would disagree
    plan = [{"zone": 1, "name": "A", "theme_id": "carousel"}, {"zone": 2, "name": "B", "theme_id": "carousel"},
            {"zone": 3, "name": "Haunted Hollow", "theme": "spooky"}]
    assert template.park_themes(plan) == ["carousel", "carousel", "haunted"]


def test_the_ideas_stage_count_sets_the_course_scope():
    assert template.scope_from_idea("build me an obby with 100 stages", {"zones": 6, "stages_per_zone": 10}) \
        == (10, 10, None)  # the idea wins over the director's numbers
    assert template.scope_from_idea("a 100-stage funfair obby", {}) == (10, 10, None)
    assert template.scope_from_idea("a hundred levels of carnival parkour", {}) == (10, 10, None)
    assert template.scope_from_idea("60 stages", {}) == (6, 10, None)
    assert template.scope_from_idea("an obby with 90 levels", {}) == (9, 10, None)
    zones, per, note = template.scope_from_idea("75 stages", {})
    assert zones * per == 80 and per == 10 and "80 stages" in note and "instead of 75" in note
    zones, per, note = template.scope_from_idea("500 stages", {})
    assert zones * per == template.MAX_STAGES and "500" in note and "themes repeat" in note
    assert template.scope_from_idea("a park obby", {"zones": 4, "stages_per_zone": 12}) == (4, 12, None)
    assert template.scope_from_idea("a park obby", None) == (template.PARK_ZONES, template.PARK_STAGES_PER_ZONE, None)
    assert template.requested_stages("level 3 has a boss") is None


def test_ten_zones_render_ten_distinct_park_themes():
    plan = [{"zone": z, "name": f"Zone {z}"} for z in range(1, 11)]
    config = template.park_config(_park_spec(plan))
    assert sorted(template.park_themes(plan)) == sorted(template.PARK_THEMES) and config.count("theme = ") == 10


def test_stage_counts_in_the_ways_people_write_them():
    asks = {"an obby with 5 zones of 20 stages each": 100, "obby, 10 levels per world, 8 worlds": 80,
            "5 zones with 12 stages each": 60, "a 1,000 stage obby": 1000, "an obby, 1,000 stages": 1000,
            "a 2 level house with 50 stages": 50, "twenty stages": 20, "twenty-five stages": 25,
            "1 hundred stages": 100, "hundred stages": 100, "100 obby stages": 100, "stages: 100": 100,
            "a hundred-stage obby": 100, "100 coins and 30 stages": 30, "an obby with 100 levels": 100}
    assert {idea: template.requested_stages(idea) for idea in asks} == asks
    for idea in ("a 3-level castle obby", "stages that have 3 levels of difficulty", "100 coins",
                 "stage 5 should be hard", "level 3 has a boss"):
        assert template.requested_stages(idea) is None, idea
    zones, per, note = template.scope_from_idea("a 1,000 stage obby", {})
    assert zones * per == template.MAX_STAGES and "1000" in note
    # fewer stages than the plan: the idea still wins, and the note says so
    zones, per, note = template.scope_from_idea("an obby with 30 stages", {"zones": 8, "stages_per_zone": 10})
    assert (zones, per) == (3, 10) and "80" in note


def test_no_count_builds_more_zones_than_the_park_holds():
    # WorldKit's park keeps its rides off the courses up to 12 zones; at 13 a ride stands on course 2
    assert template.MAX_ZONES == 12 and template.MAX_STAGES <= 12 * 12
    for n in range(1, 1001):
        zones, per, _ = template.scope_from_idea(f"{n} stages", {})
        assert zones <= template.MAX_ZONES and 8 <= per <= 12, n


def test_director_prose_takes_the_course_forge_builds():
    spec = {"acceptance": ["HUD shows 'Stage 0/100'",
                           "Config defines 5 zones of 20 stages, every 5th stage is a breather, stage 100 finishes"],
            "director": {"systems": [{"name": "Zones", "what": "Defines the five 20-stage zones and the lobby."},
                                     {"name": "Finales", "what": "Every 20 stages is a ride-finale; 5 zones in all."}]}}
    assert template.align_scope(spec, 10, 10)
    assert spec["acceptance"] == ["HUD shows 'Stage 0/100'",
                                  "Config defines 10 zones of 10 stages, every 5th stage is a breather, stage 100 "
                                  "finishes"]
    assert [s["what"] for s in spec["director"]["systems"]] == [
        "Defines the 10 10-stage zones and the lobby.", "Every 10 stages is a ride-finale; 10 zones in all."]
    assert not template.align_scope(spec, 10, 10)  # already agrees
    assert "10 zones of 10 stages, 100 stages" in template.scope_block(10, 10)
