"""UI coverage: every UI surface of the game is assigned to a presser and reported pressed / not pressed."""

from __future__ import annotations

import json
import re

from mubit_tester import ai, play
from mubit_tester import surfaces as S
from test_tester_ai import ScriptedLLM, _a, _settings
from test_ui_press import UIHarness

PASS_SCRIPT = '''
local gui = Instance.new("ScreenGui")
gui.Name = "BattlePassGui"
local passBtn = Instance.new("TextButton")
passBtn.Text = "Pass"
local buyBtn = Instance.new("TextButton")
buyBtn.Text = "Get Premium Pass"
local closeBtn = Instance.new("TextButton")
closeBtn.Text = "X"
local b = Instance.new("TextButton")
b.Text = "Claimed"
b.Text = "Claim"
local label = Instance.new("TextLabel")
label.Text = "Tier 1"
'''
SHOP_SCRIPT = '''
local g = Instance.new("ScreenGui")
g.Name = "ShopGui"
local open = Instance.new("TextButton")
open.Text = "Shop"
'''


def _game(tmp_path, scripts: dict[str, str]):
    root = tmp_path / "game"
    for rel, src in scripts.items():
        f = root / "StarterPlayerScripts" / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(src)
    return root


def test_script_surfaces_reads_buttons_and_gui(tmp_path):
    root = _game(tmp_path, {"BattlePassController.client.luau": PASS_SCRIPT,
                            "ForgeTestAgent.client.luau": SHOP_SCRIPT})
    assert S.script_surfaces(root) == [{"name": "Pass", "gui": "BattlePassGui",
                                        "actions": ["Get Premium Pass", "Claim"],
                                        "script": "StarterPlayerScripts/BattlePassController.client.luau"}]
    assert S.script_surfaces(tmp_path / "missing") == []


def test_derive_keeps_only_confirmed_surfaces_and_caps(tmp_path):
    root = _game(tmp_path, {"Pass.client.luau": PASS_SCRIPT, "Shop.client.luau": SHOP_SCRIPT})
    obs = [{"ui": [{"text": "Pass", "path": "BattlePassGui.PassButton", "gui": "BattlePassGui"},
                   {"text": "M", "path": "Minimap.MapButton", "gui": "Minimap"}]}]
    got = S.derive_surfaces({}, root, obs)
    assert [s["name"] for s in got] == ["Pass"]  # Shop: not on screen, not in the spec; "M": no word
    assert got[0]["actions"] == ["Get Premium Pass", "Claim"] and got[0]["source"] == ["script", "live"]
    named = S.derive_surfaces({"acceptance": ["Players can buy hats in the shop"]}, root, obs)
    assert {s["name"] for s in named} == {"Pass", "Shop"}
    many = [{"ui": [{"text": f"Feature {c}", "path": f"G{c}.B", "gui": f"G{c}"} for c in "ABCDEFGH"]}]
    assert len(S.derive_surfaces({}, None, many)) == S.MAX_SURFACES


def test_assign_round_robins_over_pressers_only():
    roster = [{"name": "Alice", "can_press": True}, {"name": "Bob", "can_press": False},
              {"name": "Cy", "can_press": True}]
    got = S.assign_surfaces([{"name": "Pass"}, {"name": "Shop"}, {"name": "Help"}], roster)
    assert [s["assigned"] for s in got] == ["Alice", "Cy", "Alice"]
    assert S.assign_surfaces([{"name": "Pass"}], [{"name": "Bob"}])[0]["assigned"] is None


def test_coverage_reports_gaps():
    surfaces = [{"name": "Pass", "gui": "BattlePassGui", "actions": ["Claim"], "assigned": "Alice"},
                {"name": "Shop", "gui": "ShopGui", "actions": [], "assigned": None},
                {"name": "Help", "gui": "HelpGui", "actions": [], "assigned": "Alice"}]
    presses = [{"text": "Pass", "path": "BattlePassGui.PassButton", "gui": "BattlePassGui", "fired": True,
                "changed": True},
               {"text": "X", "path": "BattlePassGui.Panel.Close", "gui": "BattlePassGui", "fired": True},
               {"text": "Help", "path": "HelpGui.Help", "gui": "HelpGui", "fired": False}]
    cov = S.coverage(surfaces, presses)
    assert cov["pressed"] == 2 and cov["total"] == 3
    assert cov["surfaces"][0]["presses"] == 2 and cov["surfaces"][0]["actions_pressed"] == []
    assert cov["gaps"] == [
        "Pass (BattlePassGui): opened, but Claim never pressed",
        "Shop (ShopGui): never pressed, its panel was never opened; no tester could press UI this run",
        "Help (HelpGui): pressed 1x but the button never fired",
    ]
    claimed = S.coverage(surfaces[:1], presses[:1] + [{"text": "Claim", "gui": "BattlePassGui", "fired": True}])
    assert claimed["gaps"] == [] and claimed["surfaces"][0]["actions_pressed"] == ["Claim"]
    two = dict(surfaces[0], actions=["Get Premium Pass", "Claim"])
    half = S.coverage([two], presses[:1] + [{"text": "Get Premium Pass", "gui": "BattlePassGui", "fired": True}])
    assert half["gaps"] == ["Pass (BattlePassGui): opened, but Claim never pressed"]


async def test_playtest_assigns_surfaces_and_reports_coverage(tmp_path):
    root = _game(tmp_path, {"BattlePassController.client.luau": PASS_SCRIPT})
    llm = ScriptedLLM({"Alice": [_a("press", {"text": "Pass"})]}, delay=0)
    h = UIHarness({"101": "own"})
    h.observe_ui = [{"text": "Pass", "path": "BattlePassGui.PassButton", "gui": "BattlePassGui"}]
    orig = h.observe

    async def observe(user_id):
        return dict(await orig(user_id), ui=h.observe_ui)

    h.observe = observe
    rep = await ai.multi_playtest(_settings(tmp_path), "play", players=2, steps=2, llm=llm, harness=h,
                                  step_seconds=0, game_dir=root)
    users = {re.search(r"## You\n(\w+)", c.user).group(1): c.user for c in llm.calls if c.role == "player"}
    assert "## UI features assigned to you" in users["Alice"] and "- Pass (gui BattlePassGui), then: " \
        "Get Premium Pass, Claim" in users["Alice"]
    assert "## UI features assigned to you" not in users["Bob"]
    cov = rep["ui_coverage"]
    assert cov["total"] == 1 and cov["pressed"] == 1 and cov["surfaces"][0]["assigned"] == "Alice"
    assert cov["gaps"] == ["Pass (BattlePassGui): opened, but Get Premium Pass, Claim never pressed"]
    judge = next(c.user for c in llm.calls if c.role == "judge")
    assert "## UI coverage" in judge and "1/1" in judge
    saved = json.loads((play._run_dir(_settings(tmp_path), rep["run_id"]) / "report.json").read_text())
    assert saved["ui_coverage"] == cov


def test_physics_flags_in_probe_summary():
    probe = {"errors": [], "physics": {"watched": 4, "flagged": [
        {"path": "Workspace.Truck.Chassis", "model": "Workspace.Truck", "kind": "jitter", "max_speed": 6.2,
         "max_angvel": 3.1, "moved_studs": 0.4, "windows": 3, "last": 12.5}], "loudest": []}}
    want = [{"path": "Workspace.Truck.Chassis", "kind": "jitter", "max_speed": 6.2, "max_angvel": 3.1,
             "moved_studs": 0.4, "windows": 3}]
    assert play.physics_flags(probe) == want
    assert play.summarize_probe(probe)["physics"] == want
    assert "physics" not in play.summarize_probe({"errors": [], "physics": {"flagged": []}})
    assert play.physics_flags({"error": "x"}) == [] and play.physics_flags(None) == []
