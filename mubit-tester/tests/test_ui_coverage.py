"""UI coverage: every UI surface of the game is assigned to a presser and reported pressed / not pressed."""

from __future__ import annotations

import json
import re

from mubit_tester import ai, play
from mubit_tester import surfaces as S
from test_tester_ai import FakeHarness, ScriptedLLM, _a, _settings
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


# ---------------------------------------------------------------- the scripted pass before free play


class PassHarness(UIHarness):
    """A battle pass: PASS opens a panel with Get Premium Pass, X, a Claim on tier 1 and '...' on tier 2;
    Claim turns into Claimed; X closes the panel. Every press is logged as a ui_press event."""

    def __init__(self):
        super().__init__({"101": "own"})
        self.open = self.claimed = False
        self.logged: list[dict] = []

    def buttons(self) -> list[dict]:
        out = [{"text": "PASS", "path": "BattlePassGui.PassButton", "gui": "BattlePassGui"}]
        if self.open:
            out += [{"text": "Get Premium Pass", "path": "BattlePassGui.Panel.TextButton", "gui": "BattlePassGui"},
                    {"text": "X", "path": "BattlePassGui.Panel.Close", "gui": "BattlePassGui"},
                    {"text": "Claimed" if self.claimed else "Claim", "path": "BattlePassGui.Panel.Tier1.Free",
                     "gui": "BattlePassGui"},
                    {"text": "...", "path": "BattlePassGui.Panel.Tier2.Free", "gui": "BattlePassGui"}]
        return out

    async def observe(self, user_id):
        return dict(await FakeHarness.observe(self, user_id), ui=self.buttons(), panels=[])

    async def ui(self, user_id, max=None):
        return {"buttons": self.buttons(), "panels": [], "total": len(self.buttons())}

    async def act(self, user_id, action, **args):
        if action != "press":
            return await FakeHarness.act(self, user_id, action, **args)
        self.acts.append((user_id, action, args))
        btn = next(b for b in self.buttons() if b["path"] == args.get("path") or b["text"] == args.get("text"))
        effect: dict = {}
        if btn["text"] == "PASS" or btn["text"] == "X":
            self.open = btn["text"] == "PASS" and not self.open
            effect = {"panels_opened" if self.open else "panels_closed": ["BattlePassGui.Panel 'Battle Pass'"]}
        elif btn["text"] == "Claim":
            self.claimed = True
            effect = {"buttons_new": ["Claimed @ BattlePassGui.Panel.Tier1.Free"]}
        data = {"name": "Alice", "userId": 101, "path": btn["path"], "text": btn["text"], "gui": "BattlePassGui",
                "fired": True, "changed": bool(effect), "effect": effect}
        self.logged.append({"t": 1, "kind": "ui_press", "data": data})
        return {"done": True, "fired": True, "changed": bool(effect), "effect": effect, "path": btn["path"],
                "text": btn["text"], "detail": f"clicked '{btn['text']}'"}

    async def events(self, since=None):
        res = await FakeHarness.events(self, since)
        if since is not None:
            res["events"] += self.logged
            self.logged = []
        return res


async def test_scripted_pass_presses_the_surface_and_its_enabled_actions_before_free_play(tmp_path):
    root = _game(tmp_path, {"BattlePassController.client.luau": PASS_SCRIPT})
    llm = ScriptedLLM({"Alice": [_a("jump")]}, delay=0)
    h = PassHarness()
    rep = await ai.multi_playtest(_settings(tmp_path), "play", players=2, steps=1, llm=llm, harness=h,
                                  step_seconds=0, game_dir=root)
    presses = [a for a in h.acts if a[1] == "press"]
    assert [p[2]["path"] for p in presses] == ["BattlePassGui.PassButton", "BattlePassGui.Panel.Tier1.Free",
                                               "BattlePassGui.Panel.TextButton", "BattlePassGui.Panel.Close"]
    assert h.acts.index(presses[-1]) < h.acts.index((101, "jump", {}))  # all of it before free play
    [rec] = rep["ui_pass"]
    assert [(p["kind"], p["button"]) for p in rec["presses"]] == [
        ("entry", "Pass"), ("action", "Claim"), ("action", "Get Premium Pass"), ("close", "X")]
    assert rec["skipped"] == [] and not h.open and h.claimed
    cov = rep["ui_coverage"]
    assert cov["gaps"] == [] and cov["scripted_presses"] == 4
    assert cov["surfaces"][0]["actions_pressed"] == ["Claim", "Get Premium Pass"]
    note = cov["surfaces"][0]["scripted"]
    assert "Pass: fired, opened a panel" in note and "Claim: fired, changed the screen" in note
    assert "Get Premium Pass: fired, changed nothing on screen" in note
    users = {re.search(r"## You\n(\w+)", c.user).group(1): c.user for c in llm.calls if c.role == "player"}
    assert "[already pressed by the scripted UI pass: Pass: fired, opened a panel" in users["Alice"]
    assert "scripted_pass" in next(c.user for c in llm.calls if c.role == "judge")
    assert len([p for p in rep["ui_presses"] if p["player"] == "Alice"]) == 4


async def test_scripted_pass_skips_actions_that_are_not_on_screen_and_needs_a_presser(tmp_path):
    root = _game(tmp_path, {"BattlePassController.client.luau": PASS_SCRIPT})
    h = PassHarness()
    h.claimed = True  # nothing to claim: the only tier-1 button is the "Claimed" label
    rep = await ai.multi_playtest(_settings(tmp_path), "play", players=2, steps=1,
                                  llm=ScriptedLLM({}, delay=0), harness=h, step_seconds=0, game_dir=root)
    [rec] = rep["ui_pass"]
    assert rec["skipped"] == ["Claim"] and "Claimed" not in [p["button"] for p in rec["presses"]]
    assert rep["ui_coverage"]["gaps"] == ["Pass (BattlePassGui): opened, but Claim never pressed"]
    nobody = PassHarness()
    nobody.windows = {}
    rep = await ai.multi_playtest(_settings(tmp_path), "play", players=2, steps=1,
                                  llm=ScriptedLLM({}, delay=0), harness=nobody, step_seconds=0, game_dir=root)
    assert "ui_pass" not in rep and not [a for a in nobody.acts if a[1] == "press"]


async def test_a_minimized_studio_window_is_named_not_pressed_blindly(tmp_path):
    """Live 2026-10-24: Macro's game view did not render during play (viewport 1x1), so every button had no size."""
    root = _game(tmp_path, {"BattlePassController.client.luau": PASS_SCRIPT})
    blind = "the game view is not rendering (viewport 1x1): the Studio window that drives this player is minimized"

    class Minimized(PassHarness):
        async def ui(self, user_id, max=None):
            return {"buttons": [], "panels": [], "total": 0, "viewport": [1, 1], "not_rendering": blind}

    h = Minimized()
    rep = await ai.multi_playtest(_settings(tmp_path), "play", players=2, steps=1,
                                  llm=ScriptedLLM({}, delay=0), harness=h, step_seconds=0, game_dir=root)
    [rec] = rep["ui_pass"]
    assert rec["blocked"] == blind and rec["presses"] == [] and not [a for a in h.acts if a[1] == "press"]
    assert rep["ui_coverage"]["gaps"] == [f"Pass (BattlePassGui): never pressed, its panel was never opened; {blind}"]
    assert rep["ui_coverage"]["surfaces"][0]["scripted"] == "not pressed: " + blind


def test_pass_helpers_pick_enabled_buttons_and_put_purchases_last():
    buttons = [{"text": "Claimed", "path": "G.A"}, {"text": "Claim", "path": "G.B"}, {"text": "X", "path": "G.X",
                                                                                     "gui": "G"}]
    assert S.pick_button(buttons, "claim")["path"] == "G.B"
    assert S.pick_button(buttons[:1], "Claim") is None  # a state label is not the action
    assert S.pick_button([{"text": "Claim Reward", "path": "G.C"}], "Claim")["path"] == "G.C"
    assert S.pick_button(buttons, "nope", path="G.A")["path"] == "G.A"
    assert S.order_actions(["Get Premium Pass", "Claim", "Buy Coins", "Equip"]) == [
        "Claim", "Equip", "Get Premium Pass", "Buy Coins"]
    assert S.close_button(buttons, "G")["path"] == "G.X" and S.close_button(buttons, "Other") is None
    assert S.new_buttons({"buttons_new": ["Play @ G.P", "? @ G.Q", "X @ G.X", "Locked @ G.L"]}) == ["Play"]
    assert S.opened({"guis_opened": ["ShopGui"]}) and not S.opened({"hud_new": ["x"]})


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
