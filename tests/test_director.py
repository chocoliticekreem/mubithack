"""Forge quality brain: game director -> designer -> art pass (GameAssets) -> coder notes; fun critic;
curated genre lessons in the improve playbook. All with FakeLLM."""

from __future__ import annotations

import dataclasses
import io
import json
import shutil
import subprocess

import pytest

from forge import director, fun
from forge.config import load_settings
from forge.improve import CURATED_HEADER, ImproveStore
from forge.llm import FakeLLM, load_prompt
from forge.loop import UI, new_game
from forge.memory import RunStore, slugify

LUAU = shutil.which("luau-compile")
needs_luau = pytest.mark.skipif(LUAU is None, reason="luau-compile not on PATH")

DOC = {
    "fantasy": "You run a tiny cube factory that grows into a mega tycoon",
    "core_loop": "droppers make cubes -> collector pays cash -> buy pads unlock more -> rebirth",
    "progression": [{"at": "0:00", "goal": "first dropper", "unlock": "Dropper 1", "cost": "free"}],
    "systems": [{"name": f"S{i}", "what": "x", "module": f"ServerScriptService/S{i}.luau"} for i in range(6)],
    "juice": [{"moment": "cash collected", "sound": "bright coin ding", "vfx": "sparkle burst",
               "ui": "cash counter punches", "camera": "none"},
              {"moment": "rebirth", "sound": "big boom", "vfx": "confetti", "ui": "RewardPopup", "camera": "shake"}],
    "first_60_seconds": [{"t": 20, "beat": "buys the first dropper", "counter": "Item Bought", "min": 1},
                         {"t": 3, "beat": "lands on own plot", "counter": "plot_claimed"},
                         {"beat": ""}],
    "rewards": ["free gift every 3 minutes"],
    "visual_style": {"palette": ["#FFC429", "#58D65C", "bad"], "materials": ["SmoothPlastic", "Neon"],
                     "lighting": "sunny, bloom", "mood": "toy box"},
    "sounds": [{"id": "CashDing", "for": "ore collected", "describe": "short bright coin ding"},
               {"id": "Rebirth Boom", "for": "rebirth", "describe": "big explosion boom"}],
    "module_budget": 9,
    "acceptance": ["plot exists"],
}


def _modules(n: int) -> list[dict]:
    mods = [{"path": "ReplicatedStorage/Config.luau", "purpose": "tunables", "depends": []}]
    mods += [{"path": f"ServerScriptService/S{i}.luau", "purpose": f"system {i}: plays the Coin sound and a burst",
              "depends": ["ReplicatedStorage/Config.luau", director.GAME_ASSETS]} for i in range(n - 2)]
    mods.append({"path": "StarterPlayerScripts/Hud.client.luau", "purpose": "HUD with CurrencyCounter",
                 "depends": [director.GAME_ASSETS]})
    return mods


def _spec(n: int) -> dict:
    return {"title": "Cube Cash", "slug": "cube-cash", "pitch": "p", "core_loop": "c",
            "modules": _modules(n), "acceptance": ["the map is built"]}


@pytest.fixture
def settings(tmp_path):
    return dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs")


# ---------------------------------------------------------------- prompts + lessons


def test_new_roles_have_fixed_prompts_without_per_call_text():
    for role in ("director", "fun_critic"):
        text = load_prompt(role)
        assert "Reply with ONLY one JSON object" in text
        assert "{idea}" not in text and "tycoon best practices" not in text.lower()
    assert "first_60_seconds" in load_prompt("director") and "module_budget" in load_prompt("director")
    assert all(a in load_prompt("fun_critic") for a in fun.AXES)


def test_genre_lessons_pick_by_idea():
    t = director.genre_lessons("a cube tycoon with droppers and rebirths")
    assert "tycoon best practices" in t and "Fun-first rules" in t and "obby" not in t.lower()
    o = director.genre_lessons("obby with checkpoints and coins")
    assert "obby best practices" in o and "tycoon" not in o.lower()
    assert director.genre_lessons("a racing game").startswith("# Fun-first rules")


def test_sound_kit_matches_descriptions_and_ids_ship_with_studio():
    assert director.match_sound("short bright coin ding") == "Coin"
    assert director.match_sound("big explosion boom") == "Boom"
    assert director.match_sound("zzz") == "Pop"
    for name, s in director.sound_kit().items():
        assert s["id"].startswith(("rbxasset://sounds/", "rbxassetid://")), name
        assert s["keywords"] and s["describe"]
        if s["id"].startswith("rbxassetid://"):  # Creator Store audio: heard in Studio, has a built-in fallback
            assert s.get("checked") and "fallback" in s, name


# ---------------------------------------------------------------- director -> designer


def test_plan_runs_director_then_designer_with_the_doc_in_user_messages():
    llm = FakeLLM({"director": [json.dumps(DOC)], "designer": [json.dumps(_spec(9))]})
    spec = director.plan(llm, "a cube tycoon with droppers", "- old lesson", session_id="g")
    d_call, s_call = llm.calls
    assert d_call.role == "director" and s_call.role == "designer"
    assert "## Curated genre lessons" in d_call.user and "tycoon best practices" in d_call.user
    assert "## Sound table" in d_call.user and "- old lesson" in d_call.user
    assert "## Director's design doc" in s_call.user and "cash collected" in s_call.user
    assert "overrides the 3-7 module guideline" in s_call.user and "PREBUILT" in s_call.user
    assert "Director" not in load_prompt("designer")  # frozen designer prompt untouched

    # 9 coder modules (> the old cap of 7) are accepted under the director's budget of 9
    assert spec["modules"][0]["path"] == director.GAME_ASSETS and spec["modules"][0]["prebuilt"]
    assert len(spec["modules"]) == 10
    assert director.GAME_ASSETS in spec["modules"][1 + 1]["depends"]  # dependency on the kit kept
    beats = spec["first_60s"]
    assert [b["counter"] for b in beats] == ["plot_claimed", "item_bought"]  # sorted, cleaned, empty dropped
    assert any("item_bought counter reaches 1" in a for a in spec["acceptance"])
    assert spec["director"]["module_budget"] == 9
    assert {s["id"]: s["kit"] for s in spec["director"]["sounds"]} == {"CashDing": "Coin", "RebirthBoom": "Boom"}
    st = director.spec_stats(spec)
    assert st["modules"] == 10 and st["juice"] == 2 and st["first_60s_beats"] == 2 and st["juice_in_purposes"] >= 7


def test_designer_over_budget_gets_one_corrected_retry():
    llm = FakeLLM({"director": [json.dumps({**DOC, "module_budget": 6})],
                   "designer": [json.dumps(_spec(12)), json.dumps(_spec(6))]})
    spec = director.plan(llm, "tycoon", "", session_id="g")
    assert "too many modules (12)" in llm.calls[2].user and "budget is 6" in llm.calls[2].user
    assert len(spec["modules"]) == 7


def test_module_budget_is_clamped():
    assert director.normalize_doc({**DOC, "module_budget": 40})["module_budget"] == director.MAX_MODULES
    assert director.normalize_doc({**DOC, "module_budget": "x"})["module_budget"] == 7


# ---------------------------------------------------------------- art pass + coder notes


@needs_luau
def test_game_assets_renders_palette_sounds_aliases_and_compiles(tmp_path):
    llm = FakeLLM({"director": [json.dumps(DOC)], "designer": [json.dumps(_spec(5))]})
    spec = director.plan(llm, "tycoon", "", session_id="g")
    assert director.install_kit(spec, tmp_path) == [director.GAME_ASSETS]
    src = (tmp_path / director.GAME_ASSETS).read_text()
    assert "--[[" not in src
    assert "C1 = Color3.fromRGB(255, 196, 41)" in src and "C3" not in src  # bad hex skipped
    assert 'Coin = "rbxassetid://' in src and 'Hurt = "rbxasset://sounds/' in src
    assert 'SetAttribute("ForgeSoundsPlayed"' in src  # plays are counted for the census
    assert "GameAssets.Sounds.CashDing = GameAssets.Sounds.Coin" in src
    res = subprocess.run([LUAU, "--null", str(tmp_path / director.GAME_ASSETS)], capture_output=True, text=True)
    assert res.returncode == 0, res.stdout + res.stderr


def test_install_kit_skips_undirected_specs(tmp_path):
    assert director.install_kit({"modules": [{"path": "ReplicatedStorage/Config.luau"}]}, tmp_path) == []


def test_coder_notes_put_style_before_lessons():
    spec = director._attach({"modules": [], "acceptance": []}, director.normalize_doc(DOC))
    notes = director.coder_notes(spec, "- learned lesson")
    assert notes.index("Palette: #FFC429") < notes.index("- learned lesson")
    assert "cash collected" in notes and "CashDing->Coin" in notes
    assert director.coder_notes({"modules": []}, "x") == "x"


# ---------------------------------------------------------------- the loop uses it


@needs_luau
async def test_new_game_with_director_builds_kit_and_skips_it_in_the_coder(settings, monkeypatch):
    monkeypatch.setenv("FORGE_FUN_CRITIC", "1")
    spec = _spec(3)
    coder = ["```luau\nreturn {}\n```"] * 3
    fun_reply = {"scores": {"fun": 6, "juice": 4, "clarity": 7, "visuals": 5}, "summary": "flat",
                 "first_60_seconds": [{"beat": "lands", "ok": True}], "missing_juice": ["rebirth"],
                 "issues": [{"path": "StarterPlayerScripts/Hud.client.luau", "problem": "silent HUD",
                             "fix_hint": "GameAssets.play('Coin') on cash change"},
                            {"path": "Nope.luau", "problem": "unknown file", "fix_hint": "x"}]}
    critique = {"score": 8, "summary": "works", "issues": [], "done": True}
    idea = "cube tycoon"
    llm = FakeLLM({"director": [json.dumps(DOC)], "designer": [json.dumps(spec)], "coder": coder,
                   "critic": [json.dumps(critique)], "fun_critic": [json.dumps(fun_reply)],
                   "fixer": ["```luau\nreturn {}\n```"], "reflector": ["# lessons\n"]},
                  log_path=settings.runs_dir / slugify(idea) / "calls.jsonl")
    slug = await new_game(idea, iterations=1, use_studio=False, settings=settings, llm=llm,
                          ui=UI(io.StringIO()), use_director=True)
    store = RunStore(settings, slug)
    assert (store.game_dir / director.GAME_ASSETS).exists()
    coder_calls = [c for c in llm.calls if c.role == "coder"]
    assert len(coder_calls) == 3
    assert all(f"path: {director.GAME_ASSETS}\n" not in c.user for c in coder_calls)
    assert any(f"### {director.GAME_ASSETS}" in c.user for c in coder_calls)  # kit API shown as a dependency
    assert all("This game's style and juice" in c.user for c in coder_calls)
    # fun 5.5 < 8: the critic said done, but the iteration is not done; the fun issue was fixed
    rec = store.load_iteration_json(1, "record.json")
    assert rec["fun"]["score"] == 5.5 and rec["done"] is False
    assert [i["problem"] for i in rec["issues"]] == ["silent HUD"]
    assert any(f["path"] == "StarterPlayerScripts/Hud.client.luau" for f in rec["fixes"])
    latest = fun.FunStore(settings, slug).latest()
    # --no-studio still playtests headless, so the census comes from that run (static without luau)
    want = "headless playtest" if shutil.which("luau") else "static"
    assert latest["score"] == 5.5 and latest["census"]["source"] == want


# ---------------------------------------------------------------- fun critic


def test_fun_score_is_the_mean_of_the_axes_and_clamped():
    out = fun.normalize_fun({"scores": {"fun": 12, "juice": "7", "clarity": None, "visuals": 9}, "issues": []})
    assert out["scores"] == {"fun": 10.0, "juice": 7.0, "clarity": 0.0, "visuals": 9.0} and out["score"] == 6.5


def test_fun_message_carries_doc_census_and_visual_notes():
    spec = director._attach({"title": "T", "modules": [], "acceptance": []}, director.normalize_doc(DOC))
    msg = fun.fun_message(spec, {"A.luau": "print(1)"}, {"counters": {"plot_claimed": 1}},
                          {"source": "playtest", "parts": 10, "grey": 9}, "screenshot: grey baseplate")
    for s in ("cash collected", '"grey": 9', "plot_claimed", "grey baseplate", "### A.luau"):
        assert s in msg
    assert len(msg) <= 24_000


def test_static_census_and_visual_checks():
    files = {"StarterPlayerScripts/Hud.client.luau": 'local g = Theme.screen("Hud")\nGameAssets.play("Coin")',
             "ServerScriptService/Map.luau": 'local p = Instance.new("Part")\np.Color = Color3.new()\n'
                                             'GameAssets.part({Size = Vector3.one})'}
    kit_only = fun.static_census({director.GAME_ASSETS: director.render_game_assets({}),
                                  "ServerScriptService/ForgeProbe.server.luau": 'Instance.new("Sound")'})
    assert kit_only["sound_sites"] == 0 and kit_only["part_sites"] == 0  # the kit alone proves nothing
    c = fun.static_census(files)
    assert c["sound_sites"] == 1 and c["screen_gui_sites"] == 1 and c["part_sites"] == 2
    assert fun.visual_checks(c) == {"grey_ok": True, "hud_ok": True, "sounds_ok": True}
    assert fun.visual_checks({"source": "playtest", "parts": 10, "grey": 5, "sounds": 0, "client_sounds": 0,
                              "screen_guis": 0}) == {"grey_ok": False, "hud_ok": False, "sounds_ok": False}
    assert fun.visual_checks({}) == {"grey_ok": None, "hud_ok": None, "sounds_ok": None}
    # live census from a real Studio playtest (2026-10-24): sounds were played and cleaned up already
    live = {"source": "playtest", "parts": 9, "grey": 1, "sounds": 0, "sounds_played": 12, "screen_guis": 1,
            "client_sounds": 0, "client_sounds_played": 13}
    assert fun.visual_checks(live) == {"grey_ok": True, "hud_ok": True, "sounds_ok": True}


def test_census_scripts_skip_core_guis_and_character_sounds():
    assert "BubbleChat = true" in fun.CENSUS_CLIENT and "inChar(i)" in fun.CENSUS_CLIENT
    assert 'GetAttribute("ForgeSoundsPlayed")' in fun.CENSUS_SERVER


class CensusStudio:
    async def execute_luau(self, code, dm):
        assert code.startswith("-- forge census")
        if dm == "Server":
            return 'Result: {"parts": 40, "grey": 2, "sounds": 1}'
        raise RuntimeError("no client")


async def test_census_merges_server_and_reports_client_error():
    c = await fun.census(CensusStudio())
    assert c["parts"] == 40 and c["source"] == "playtest" and "client_error" in c


def test_pending_fun_anomalies_feed_the_improve_loop(settings):
    fun.FunStore(settings, "g").save(1, {"score": 5, "issues": [
        {"path": "StarterPlayerScripts/Hud.client.luau", "problem": "no sound", "fix_hint": "play Coin"}]})
    [a] = fun.pending_fun_anomalies(settings, "g")
    assert a["kind"] == "fun" and a["severity"] == "medium" and a["path"].endswith("Hud.client.luau")
    assert "[StarterPlayerScripts/Hud.client.luau]" in a["title"]
    assert fun.pending_fun_anomalies(settings, "g", since="9999") == []


def test_playbook_is_seeded_once_with_curated_genre_lessons(settings):
    store = ImproveStore(settings, "g")
    store.dir.mkdir(parents=True)
    store.playbook_path.write_text("- learned: watch the water\n")
    spec = {"title": "Cube Cash Tycoon", "pitch": "droppers", "core_loop": ""}
    assert store.seed_playbook(spec) is True
    pb = store.playbook()
    assert pb.startswith(CURATED_HEADER) and "tycoon best practices" in pb and "watch the water" in pb
    assert store.seed_playbook(spec) is False and store.playbook() == pb
