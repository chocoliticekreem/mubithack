import shutil
import subprocess
from pathlib import Path

import pytest

from forge import roles, ui_kit
from forge.config import Settings
from forge.llm import FakeLLM, MubitLLM, load_prompt

LIB = ui_kit.LIBRARY_DIR
LUAU = shutil.which("luau-compile")
needs_luau = pytest.mark.skipif(LUAU is None, reason="luau-compile not on PATH")

HUD = ("StarterPlayerScripts/Hud.client.luau",
       "Shows the player's coins from leaderstats, a toast when they earn, and a shop button that opens the upgrades panel")
DATA = ("ServerScriptService/DataStore.luau",
        "Saves and loads player coins and upgrades with DataStoreService; returns {load(player), save(player)}")
REPLY = "```luau\nprint(1)\n```"


def _compile(path: Path) -> subprocess.CompletedProcess:
    return subprocess.run([LUAU, "--null", str(path)], capture_output=True, text=True, check=False)


def _settings(tmp_path: Path) -> Settings:
    return Settings(
        mubit_api_key="mbt_k", provider="anthropic", base_url="https://api.mubit.ai/anthropic",
        model="claude-sonnet-5", studio_mcp_path="", sync_port=34873, repo_root=tmp_path,
        runs_dir=tmp_path / "runs", base_game_dir=tmp_path / "game",
    )


# --- the library ---------------------------------------------------------------------------


def test_index_points_at_real_files_and_covers_every_snippet():
    entries = ui_kit.load_index()
    files = {e["file"] for e in entries}
    assert files == {p.name for p in LIB.glob("*.luau")}
    assert 8 <= len(entries) <= 12
    assert len({e["name"] for e in entries}) == len(entries)
    assert [e["name"] for e in entries if e.get("always")] == ["Theme"]
    for e in entries:
        assert (LIB / e["file"]).is_file()
        assert e["when_to_use"] and e["keywords"]
        first = (LIB / e["file"]).read_text().splitlines()[0]
        assert first.startswith(f"-- {e['name']}:"), e["file"]


def test_snippets_are_generic_and_fit_a_prompt():
    for p in LIB.glob("*.luau"):
        text = p.read_text()
        assert "```" not in text
        assert "rbxassetid" not in text
        assert not any(w in text.lower() for w in ("fire", "tycoon", "flame", "blame")), p.name
        assert len(text) < 4000, p.name


def test_rules_and_sources_present():
    readme = (LIB / "README.md").read_text()
    assert "## Sources" in readme and "https://" in readme
    r = ui_kit.rules()
    assert r.startswith("- ") and "UIStroke" in r and "## Sources" not in r
    assert len(r) < 1500


@needs_luau
@pytest.mark.parametrize("name", sorted(p.name for p in LIB.glob("*.luau")))
def test_each_snippet_compiles(name):
    res = _compile(LIB / name)
    assert res.returncode == 0, res.stdout + res.stderr


@needs_luau
def test_snippets_paste_together(tmp_path):
    """The coder pastes Theme then other snippets into one LocalScript: that file must compile too."""
    order = [e["file"] for e in ui_kit.load_index()]
    out = tmp_path / "Hud.client.luau"
    out.write_text("\n".join((LIB / f).read_text() for f in order))
    res = _compile(out)
    assert res.returncode == 0, res.stdout + res.stderr


@needs_luau
def test_compile_check_catches_broken_luau(tmp_path):
    bad = tmp_path / "Bad.luau"
    bad.write_text("local function x(\n")
    assert _compile(bad).returncode != 0


# --- selection -----------------------------------------------------------------------------


def test_client_hud_gets_theme_plus_matching_snippets():
    names = [e["name"] for e in ui_kit.select(*HUD)]
    assert names[0] == "Theme"
    assert 3 <= len(names) <= ui_kit.MAX_SNIPPETS
    assert {"Panel", "Toast", "CurrencyCounter"} <= set(names)


def test_pure_server_data_module_gets_nothing():
    assert ui_kit.kind(*DATA) is None
    assert ui_kit.select(*DATA) == []
    assert ui_kit.block(*DATA) == ""
    assert ui_kit.block("ServerScriptService/Game.server.luau",
                        "round loop; counts coins_collected with ForgeTelemetry") == ""


def test_client_input_script_gets_nothing():
    assert ui_kit.block("StarterPlayerScripts/Controls.client.luau",
                        "reads keyboard input and fires the Jump remote") == ""


def test_server_world_ui_gets_only_server_safe_snippets():
    picks = ui_kit.select("ServerScriptService/Plots.luau", "builds plots with buy pads and BillboardGui price tags")
    assert [e["name"] for e in picks] == ["PriceBillboard"]
    assert "Theme.luau" not in ui_kit.block("ServerScriptService/Plots.luau", "BillboardGui price tags")


def test_camel_case_file_names_count():
    assert ui_kit.kind("StarterPlayerScripts/ShopUI.client.luau", "") == "screen"
    assert ui_kit.kind("StarterPlayerScripts/ShopUI.client.luau", "", path_words=False) is None


@pytest.mark.parametrize("budget", [500, 3000, 6000, ui_kit.MAX_CHARS])
def test_budget_is_respected(budget):
    b = ui_kit.block(*HUD, budget)
    assert len(b) <= budget
    if b:
        assert b.startswith(ui_kit.HEADER) and b.count("```luau") == b.count("```") // 2


def test_tight_budget_degrades_to_rules_never_to_orphan_snippets():
    head = ui_kit.block(*HUD, 100_000).split("### ")[0]
    assert ui_kit.block(*HUD, len(head)) == head
    assert ui_kit.block(*HUD, len(head) - 1) == ""
    for budget in (len(head) + 2500, ui_kit.MAX_CHARS):
        b = ui_kit.block(*HUD, budget)
        for e in ui_kit.load_index():
            if e.get("needs_theme") and f"### {e['file']}" in b:
                assert "### Theme.luau" in b


# --- wiring: user message, never the system prompt -----------------------------------------


def test_coder_user_message_has_kit_and_system_prompt_does_not(tmp_path):
    llm = MubitLLM(_settings(tmp_path), None)
    seen = []

    def fake_call(system, user, session_id, max_tokens):
        seen.append((system, user))
        return REPLY, "mreq_1", 10, 2, "m"

    llm._call_anthropic = fake_call
    spec = {"title": "T", "pitch": "p", "core_loop": "c", "acceptance": [], "modules": []}
    roles.code_module(llm, spec, {"path": HUD[0], "purpose": HUD[1]}, {}, "", session_id="g")
    system, user = seen[0]
    assert system == load_prompt("coder") and "UI kit" not in system
    assert "## UI kit" in user and "### Theme.luau" in user
    assert user.rstrip().endswith("in one ```luau block.")
    assert len(user) <= roles.MAX_USER_CHARS


def test_coder_server_module_has_no_kit():
    llm = FakeLLM({"coder": [REPLY]})
    roles.code_module(llm, {"modules": []}, {"path": DATA[0], "purpose": DATA[1]}, {}, "", session_id="g")
    assert "## UI kit" not in llm.calls[0].user


def test_coder_kit_shrinks_to_fit_a_full_message():
    llm = FakeLLM({"coder": [REPLY]})
    deps = {f"ReplicatedStorage/D{i}.luau": "local x = 1\n" * 2000 for i in range(3)}
    roles.code_module(llm, {"modules": []}, {"path": HUD[0], "purpose": HUD[1]}, deps, "lesson " * 2000,
                      session_id="g")
    user = llm.calls[0].user
    assert len(user) <= roles.MAX_USER_CHARS
    assert "message truncated" not in user
    assert user.rstrip().endswith("in one ```luau block.")


def test_fixer_gets_kit_for_ui_problem_only():
    path = "StarterPlayerScripts/Hud.client.luau"
    llm = FakeLLM({"fixer": [REPLY] * 3})
    roles.fix_file(llm, path, "print(0)\n", "the coins counter is plain text and the shop button has no feedback",
                   "", "", session_id="g")
    roles.fix_file(llm, path, "print(0)\n", "attempt to index nil with 'Character' at line 4", "", "", session_id="g")
    roles.fix_file(llm, path, "print(0)\n", "luau-compile failed (attempt 1/3):\nHud.client.luau:3: Expected 'end'",
                   "", "", session_id="g")
    ui, runtime, compile_ = (c.user for c in llm.calls)
    assert "## UI kit" in ui and len(ui) <= roles.MAX_USER_CHARS
    assert ui.rstrip().endswith("in one ```luau block.")
    assert "## UI kit" not in runtime and "## UI kit" not in compile_


def test_patcher_kit_stays_small():
    src = "\n".join(f"local v{i} = {i}" for i in range(600))
    llm = FakeLLM({"patcher": ['{"edits": [{"find": "local v1 = 1", "replace": "local v1 = 2"}]}']})
    roles.patch_file(llm, HUD[0], src, "the shop panel pops in with no animation and the button text is unreadable",
                     "", "", session_id="g")
    user = llm.calls[0].user
    assert "## UI kit" in user and "## Relevant code" in user
    kit = user.split("## UI kit", 1)[1].split("## Relevant code", 1)[0]
    assert len(kit) <= roles.PATCH_UI_KIT_CHARS
    assert user.index("## Problem") < user.index("## UI kit") < user.index("## Relevant code")


def test_designer_sees_catalog_in_user_message():
    llm = FakeLLM({"designer": [('{"title": "T", "slug": "t", "pitch": "p", "core_loop": "c", "acceptance": [],'
                                ' "modules": [{"path": "ReplicatedStorage/Config.luau", "purpose": "x"}]}')]})
    roles.design(llm, "a coin game", "", session_id="g")
    user = llm.calls[0].user
    assert "## UI kit" in user and "CurrencyCounter" in user and "```" not in user
    assert "UI kit" not in load_prompt("designer")
    assert len(ui_kit.designer_block()) < 1500
