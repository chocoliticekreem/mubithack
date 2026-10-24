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
