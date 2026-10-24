"""Live player journey (forge/journey.py): every step pass/fail with evidence; a prompt with no observable effect is
a failure, what a trigger opens is closed again before the next one, on-screen buttons must be on top and do
something, RESET and ride gates move the player where they promise. A fake Studio answers the ForgeTest harness and
the journey's own snapshots; one test runs the real harness on the headless engine against a synthetic lobby."""

from __future__ import annotations

import asyncio
import json
import math
import re
import shutil
import time
from pathlib import Path

import pytest

from forge import journey

CALL_RE = re.compile(r'Invoke\("(\w+)", \[(=+)\[(.*)\]\2\]\)\s*$', re.S)
REPO = Path(__file__).resolve().parent.parent
SPAWN = [0, 4, 0]
CHECKPOINT = [0, 30, 80]
CLOSE = "Cosmetics.Dim.Window.Close"


@pytest.fixture(autouse=True)
def fast(monkeypatch):
    for name in ("SETTLE", "QUIET", "EFFECT_WAIT", "POLL", "BOOT_SECONDS", "BOOT_POLL"):
        monkeypatch.setattr(journey, name, 0.0)
    for name in ("RESPAWN_WAIT", "RIDE_WAIT"):
        monkeypatch.setattr(journey, name, 0.3)


def _prompt(name, action, effect, parent="Workspace.Lobby.Pad", siblings=0, dist=20.0):
    return {"path": f"{parent}.{name}", "name": name, "parent": parent, "parentName": parent.rsplit(".", 1)[-1],
            "action": action, "object": "", "hold": 0, "range": 10, "key": "E", "siblings": siblings, "los": False,
            "pos": [0, 1, -dist], "dist": dist, "effect": effect}


def _button(path, text, effect="attr", covered_by=None):
    return {"path": path, "text": text, "name": path.rsplit(".", 1)[-1], "class": "TextButton", "gui": "HUD",
            "x": 100, "y": 500, "w": 190, "h": 50, "layout": "computed", "effect": effect,
            **({"covered_by": covered_by} if covered_by else {})}


class FakeGame:
    """One player (Ana, 7) in a lobby. A prompt's `effect`: panel (opens the costume panel), late (opens it after a
    few looks), attr (sets an attribute), none (nothing happens), hidden (Roblox never shows it), wear (puts a
    costume on by itself), toggle (opens and closes the panel). The panel has an X (`close`) unless close=False.
    HUD buttons (`buttons`): attr, none, reset (back to the checkpoint), panel. `headless` presses buttons."""

    def __init__(self, prompts, *, kit=True, headless=False, close=True, buttons=(), obby=False, rides=(),
                 census=None, costume_view=None):
        self.prompts, self.kit, self.close, self.hud = prompts, kit, close, list(buttons)
        self.headless = headless
        self.obby, self.rides = obby, list(rides)
        self.census = census
        self.costume_view = costume_view
        self.panel = False
        self.tag = False
        self.pending = 0  # client snapshots until a late panel opens (a remote queued while the client boots)
        self.presses = 0
        self.pressed: list[str] = []
        self.attrs: dict = {}
        self.costume = {"Costume_head": "MouseEars"}
        self.events: list[dict] = []
        self.clock = 100.0
        self.calls: list[str] = []
        self.pos = list(SPAWN)
        self.stage = 0
        self.hidden_roots: list = []
        self.panel_hidden = False

    async def state(self):
        return {"playing": True}

    def _view(self):
        if self.costume_view is not None:
            return {k: self.costume_view for k in self.costume}
        return {k: {"parts": 3, "visible": 3, "far": 1.2, "head_far": 1.1, "effects": 0, "body": 15, "head": True,
                    "slot": "head"} for k in self.costume}

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        self.clock += 1
        m = CALL_RE.search(code)
        if m:
            cmd, args = m.group(1), json.loads(m.group(3))
            self.calls.append(cmd)
            try:
                return json.dumps({"ok": True, "result": getattr(self, "c_" + cmd)(args)})
            except Exception as e:  # noqa: BLE001
                return json.dumps({"ok": False, "error": str(e)})
        marker = code.splitlines()[0]
        self.calls.append(marker)
        if "forge journey: prompts" in marker:
            return json.dumps([{k: v for k, v in p.items() if k != "effect"} for p in self.prompts])
        if "forge journey: server snapshot" in marker:
            return json.dumps({"attrs": dict(self.attrs), "stats": {"Coins": "5"}, "char": {"Humanoid Humanoid": 1},
                               "costume": dict(self.costume), "costume_view": self._view(), "parts": {},
                               "pos": list(self.pos), "health": 100})
        if "forge journey: client snapshot" in marker:
            if self.pending:
                self.pending -= 1
                self.panel = self.pending == 0
            gui = {"HUD.Coins": "TextLabel", **{b["path"]: "TextButton" for b in self.hud},
                   **({"HUD.RoomTag": "TextLabel"} if self.tag else {})}
            if self.panel:
                gui.update({"Cosmetics.Dim": "Frame", "Cosmetics.Dim.Window": "Frame",
                            "Cosmetics.Dim.Window.Grid": "ScrollingFrame"})
            return json.dumps({"gui": gui, "texts": {"HUD.Coins": "5"}})
        if "forge journey: census" in marker:
            return json.dumps(self.census or {"parts": 120, "colours": 9, "materials": 4, "tall": 12,
                                              "tall_names": ["Arch"], "biggest": {"name": "Plaza", "size": [140, 2, 126]},
                                              "sky": True, "terrain": 0})
        if "forge journey: panel buttons" in marker:
            if not self.panel:
                return json.dumps([])
            rows = [{"path": "Cosmetics.Dim.Window.Grid.MouseEars.Action", "text": "TAKE OFF", "costume": "MouseEars"},
                    {"path": "Cosmetics.Dim.Window.Grid.TopHat.Action", "text": "WEAR", "costume": "TopHat"}]
            if self.close:
                rows.insert(0, {"path": CLOSE, "text": "X", "name": "Close"})
            return json.dumps(rows)
        if "forge journey: buttons" in marker:
            rows = [{k: v for k, v in b.items() if k != "effect"} for b in self.hud]
            if self.panel and not self.panel_hidden:  # an open panel's own buttons are on screen too
                rows.append(_button(CLOSE, "X"))
            return json.dumps({"layout": "computed", "buttons": rows})
        if "forge journey: hide panels" in marker:
            self.hidden_roots.append(code)
            self.panel_hidden = bool(re.search(r"JSONDecode\(.*\), false\n", code))
            return json.dumps({"n": 1})
        if "forge journey: ride gates" in marker:
            return json.dumps(self.rides)
        if "forge journey: costume request" in marker:
            action, cid = re.search(r'InvokeServer\("(\w+)", "(\w+)"\)', code).groups()
            if action == "equip" and cid == "TopHat":
                self.costume["Costume_head"] = "TopHat"
                return json.dumps({"ok": True})
            return json.dumps({"ok": False, "err": "Buy it first"})
        if "CosmeticsRemotes" in code:
            return json.dumps({"kit": self.kit})
        raise AssertionError(f"unexpected luau: {marker}")

    async def press(self, user_id, *, path=None, text=None, wait=None):
        """forge.headless: fire the button's events on the client."""
        self.pressed.append(path)
        if path == CLOSE and self.panel:
            self.panel = False
            return {"done": True, "detail": "pressed 'X'"}
        if path and path.endswith("TopHat.Action") and self.panel:
            self.costume["Costume_head"] = "TopHat"
            return {"done": True, "detail": "pressed 'WEAR'"}
        b = next((x for x in self.hud if x["path"] == path), None)
        if b is None:
            return {"done": False, "detail": f"no visible button matches {path}"}
        if b["effect"] == "attr":
            self.attrs[b["text"]] = "pressed"
        elif b["effect"] == "reset":
            self.pos = list(CHECKPOINT)
        elif b["effect"] == "panel":
            self.panel = not self.panel
        return {"done": True, "detail": f"pressed '{b['text']}'"}

    # ---- harness commands
    def c_ping(self, a):
        return {"version": "2"}

    def c_players(self, a):
        return [{"userId": 7, "name": "Ana", "pos": list(self.pos), "hasCharacter": True, "health": 100,
                 "attrs": {**self.attrs, "Stage": self.stage}}]

    def c_counters(self, a):
        return {}

    def c_events(self, a):
        since = float(a.get("since") or 0)
        return {"now": self.clock, "events": [e for e in self.events if e["t"] > since]}

    def c_query(self, a):
        if a.get("tag") == "Checkpoint" and self.obby:
            return [{"path": "Workspace.Obby.Stage1.Checkpoint", "pos": list(CHECKPOINT), "attrs": {"Stage": 1}}]
        return []

    def c_teleport(self, a):
        self.pos = list(a["pos"])
        return {"pos": self.pos}

    def c_observe(self, a):
        d = math.dist(self.pos, CHECKPOINT)
        return {"obby": {"nearest": {"stage": 1, "dist": round(d)}}}

    def c_obby_try(self, a):
        self.stage, self.pos = 1, list(CHECKPOINT)
        return {"done": True, "reached": True, "attempts": [{"result": "reached"}]}

    def c_teleport_stage(self, a):
        self.stage = int(a["stage"])
        self.pos = [0, 60, 200]
        return {"stage": self.stage}

    def c_act(self, a):
        action, args = a["action"], a.get("args") or {}
        if action == "walk_to":
            if args.get("pos"):
                self.pos = list(args["pos"])
            return {"done": True, "detail": "arrived 1.0 studs from target via path"}
        if action == "interact":
            ride = next((r for r in self.rides if r.get("prompt") == args["path"]), None)
            if ride is not None:
                if ride.get("works", True):
                    self.pos = list(ride["start"])
                return {"done": True, "detail": "triggered"}
            p = next(x for x in self.prompts if x["path"] == args["path"])
            if p["effect"] == "hidden":
                return {"done": False, "detail": f"held, not triggered: '{p['action']}'"}
            self.events.append({"t": self.clock, "kind": "prompt_triggered", "data": {"prompt": p["path"]}})
            self.presses += 1
            if p["effect"] == "panel":
                self.panel = True
            elif p["effect"] == "toggle":
                self.panel = not self.panel
            elif p["effect"] == "late" and not self.panel:
                self.pending = 3
            elif p["effect"] == "attr":
                self.attrs["Rang"] = "true"
            elif p["effect"] == "wear":
                self.costume["Costume_head"] = "TopHat"
            elif p["effect"] == "tagged":  # the panel, and a HUD tag that stays after it closes
                self.panel = self.tag = True
            return {"done": True, "detail": "triggered"}
        raise AssertionError(f"unexpected action {action}")


def _run(fake, clicks=False):
    return asyncio.run(journey.run_journey(fake, clicks=clicks, log=lambda _: None))


def _step(rec, name):
    return next(s for s in rec["steps"] if s["step"] == name)


def test_the_overnight_changing_room_fails_at_the_costume_prompt_with_evidence():
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "none"),
                     _prompt("ProximityPrompt", "Try on costumes", "hidden", siblings=1)])
    rec = _run(fake)
    assert rec["ok"] is False and rec["engine"] == "studio"
    assert _step(rec, "join")["ok"] and _step(rec, "lobby")["ok"]
    prompts = _step(rec, "prompts")
    assert prompts["ok"] is False and "0/2 prompts did something" in prompts["detail"]
    dead, hidden = rec["prompts"]
    assert dead["triggered"] and dead["server_saw"] and not dead["ok"]
    assert "was triggered and the server saw it, but nothing happened in" in dead["detail"]
    assert "1 other prompt(s) on the same part use the same key" in hidden["detail"]
    costume = _step(rec, "costume")
    assert costume["ok"] is False and "no costume prompt put a costume on or opened the costume panel" in costume["detail"]
    assert _step(rec, "stage1")["skipped"] and _step(rec, "respawn")["skipped"]  # not an obby
    assert _step(rec, "layout")["skipped"] and _step(rec, "ride")["skipped"]


def test_two_prompts_that_open_the_same_panel_both_pass_because_each_panel_is_closed_first():
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "panel"),
                     _prompt("ProximityPrompt", "Try on", "panel", parent="Workspace.Room.Stand_TopHat", dist=30)],
                    headless=True)
    rec = _run(fake)
    first, second = rec["prompts"]
    assert first["ok"] and second["ok"], journey.render(rec)
    assert "opened Cosmetics.Dim (3 GUI objects)" in second["detail"]
    assert "closed it: pressed its 'X' button" in first["detail"] and first["restore"]["closed"] is True
    assert fake.pressed.count(CLOSE) == 2 and fake.panel is False
    assert _step(rec, "prompts")["ok"] is True and _step(rec, "costume")["ok"] is True


def test_in_studio_without_clicks_a_panel_left_open_makes_the_next_prompt_unknown_not_dead():
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "panel"),
                     _prompt("ProximityPrompt", "Try on", "panel", parent="Workspace.Room.Stand_TopHat", dist=30)])
    rec = _run(fake)  # a Studio session: the X needs a real click
    first, second = rec["prompts"]
    assert first["ok"] and first["restore"]["closed"] is None and "needs a real click" in first["detail"]
    assert second["ok"] is None and "unknown" in second["detail"] and "run it headless" in second["detail"]
    assert _step(rec, "prompts")["ok"] is None and _step(rec, "costume")["ok"] is True
    assert CLOSE not in fake.pressed


def test_a_panel_left_open_in_studio_is_hidden_for_the_buttons_check_and_its_buttons_left_out():
    hud = [_button("HUD.Skip", "Skip Stage", "attr")]
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "panel")], buttons=hud)
    rec = _run(fake)
    layout = _step(rec, "layout")
    assert layout["ok"] is True and "1/1 on-screen buttons" in layout["detail"]
    assert "Cosmetics.Dim (left open, see prompts) hidden for this check" in layout["detail"]
    assert fake.panel and not fake.panel_hidden  # shown again: the game still thinks it is open
    buttons = _step(rec, "buttons")
    assert buttons["ok"] is None and "not pressed: 'Skip Stage' (a press is a real click" in buttons["detail"]


def test_closing_waits_for_the_panel_not_for_a_tag_the_prompt_also_left_on_the_hud():
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "tagged")], headless=True)
    room = _run(fake)["prompts"][0]
    assert room["ok"] and room["restore"]["closed"] is True and fake.tag and not fake.panel


def test_a_panel_nothing_closes_fails_its_prompt():
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "panel")], headless=True, close=False)
    rec = _run(fake)
    room = rec["prompts"][0]
    assert room["ok"] is False and room["restore"]["closed"] is False
    assert "cannot be closed: it has no close button (X / Close / Back)" in room["detail"]
    assert "used it again, walked away did not close it" in room["detail"]
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "toggle")], headless=True, close=False)
    rec = _run(fake)
    assert rec["prompts"][0]["ok"] and "used it again (it toggles)" in rec["prompts"][0]["detail"]


def test_a_connected_changing_room_opens_the_panel_and_wearing_changes_the_character():
    fake = FakeGame([_prompt("Bell", "Ring", "attr", parent="Workspace.Lobby.Bell", dist=10),
                     _prompt("ChangingRoomPrompt", "Try on costumes", "panel")])
    rec = _run(fake)
    bell, room = rec["prompts"]
    assert bell["ok"] and "attribute Rang None->true" in bell["detail"]
    assert room["ok"] and "opened Cosmetics.Dim (3 GUI objects)" in room["detail"]
    costume = _step(rec, "costume")
    assert costume["ok"] is True
    assert "equip TopHat through CosmeticsRemotes.Request" in costume["detail"]
    assert "Costume_head (TopHat, was MouseEars): 3/3 parts show, all within 1.1 studs of the head" in costume["detail"]
    assert fake.costume == {"Costume_head": "TopHat"}


def test_the_costume_shot_in_studio_hides_a_panel_it_could_not_close_and_shows_it_again(tmp_path):
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "panel")], buttons=[_button("HUD.Skip", "Skip")])
    shots = []

    async def screenshot(out, camera=None, look_at=None):
        shots.append((Path(out).name, len(fake.hidden_roots)))
        return out

    fake.screenshot = screenshot
    rec = asyncio.run(journey.run_journey(fake, shots=tmp_path, log=lambda _: None))
    assert ("costume.png", 1) in shots  # hidden for the costume shot
    assert ("buttons.png", 5) in shots  # for the buttons check and its shot too, shown again after each
    assert len(fake.hidden_roots) == 6 and not fake.panel_hidden
    assert re.search(r"JSONDecode\(.*\), false\n", fake.hidden_roots[0])
    assert re.search(r"JSONDecode\(.*\), true\n", fake.hidden_roots[1])
    assert _step(rec, "costume")["shot"].endswith("costume.png")


def test_a_costume_prompt_that_dresses_the_player_itself_counts_and_the_costume_must_show():
    fake = FakeGame([_prompt("Stand_TopHat", "Try on", "wear", parent="Workspace.Room.Stand", dist=12)], headless=True)
    rec = _run(fake)
    costume = _step(rec, "costume")
    assert costume["ok"] is True and "put it on by itself" in costume["detail"] and "(TopHat, was MouseEars)" in costume["detail"]
    fake = FakeGame([_prompt("Stand_TopHat", "Try on", "wear", parent="Workspace.Room.Stand", dist=12)], headless=True,
                    costume_view={"parts": 3, "visible": 0, "far": 1.0, "head_far": 1.0, "body": 15, "head": True,
                                  "slot": "head"})
    assert "none of its 3 parts show" in _step(_run(fake), "costume")["detail"]
    fake = FakeGame([_prompt("Stand_TopHat", "Try on", "wear", parent="Workspace.Room.Stand", dist=12)], headless=True,
                    costume_view={"parts": 3, "visible": 3, "far": 40.0, "head_far": 41.5, "body": 15, "head": True,
                                  "slot": "head"})
    costume = _step(_run(fake), "costume")
    assert costume["ok"] is False and "41.5 studs from the head: it is not on the character" in costume["detail"]


def test_a_panel_that_opens_within_the_looks_counts_and_one_that_never_does_is_pressed_once():
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "late")], headless=True)
    rec = _run(fake)  # the panel opens on the third look after the press (and its X closes it)
    assert rec["prompts"][0]["ok"] and fake.presses == 1 and _step(rec, "costume")["ok"] is True
    fake = FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "none")])
    _run(fake)
    assert fake.presses == 1  # no second press: each extra window is a chance for a coincidence


def test_no_prompts_and_no_costumes_are_not_applicable_not_failures():
    rec = _run(FakeGame([], kit=False))
    assert rec["ok"] is True
    assert _step(rec, "prompts")["skipped"] and _step(rec, "costume")["skipped"]
    rec = _run(FakeGame([], kit=True))
    assert _step(rec, "costume")["ok"] is False and "no costume prompt in the lobby" in _step(rec, "costume")["detail"]


def _census(**over):
    base = {"parts": 160, "colours": 18, "materials": 7, "tall": 60, "tall_names": ["Arch"],
            "biggest": {"name": "Lawn", "size": [400, 1, 266]}, "sky": True, "terrain": 0,
            "ground": {"grey": 0, "other": 106400, "biggest": {"name": "Lawn", "size": [400, 1, 266], "colour": "5fb25f",
                                                                "material": "Grass", "grey": False}}}
    return {**base, **over}


def test_the_lobby_fails_on_the_template_baseplate_grey_ground_or_a_park_without_rides():
    rec = _run(FakeGame([], census=_census(ground={"grey": 160000, "other": 106400, "biggest": {
        "name": "Baseplate", "size": [512, 4, 512], "colour": "5b5b5b", "material": "Plastic", "grey": True}})))
    lobby = _step(rec, "lobby")
    assert lobby["ok"] is False and "the ground is the grey template Baseplate (512x4x512)" in lobby["detail"]
    assert "default-grey ground shows on about 34% of the 400-stud square" in lobby["detail"]
    rec = _run(FakeGame([], census=_census(ground={"grey": 90000, "other": 0, "biggest": {
        "name": "Floor", "size": [300, 1, 300], "colour": "a3a2a5", "material": "Plastic", "grey": True}})))
    assert "the biggest ground part is default-grey Plastic (Floor 300x1x300)" in _step(rec, "lobby")["detail"]
    rec = _run(FakeGame([], census=_census(worldkit=True, park=False)))
    assert "no Workspace.Park: buildPark never ran" in _step(rec, "lobby")["detail"]
    rec = _run(FakeGame([], census=_census(worldkit=True, park=True, near_landmarks=0,
                                           landmarks=[{"name": "FerrisWheel", "dist": 910}])))
    assert "no WorldKit landmark ride within 600 studs of the spawn (nearest: FerrisWheel 910 studs)" in \
        _step(rec, "lobby")["detail"]
    rec = _run(FakeGame([], census=_census(worldkit=True, park=True, near_landmarks=2,
                                           landmarks=[{"name": "BigTop", "dist": 240}])))
    assert _step(rec, "lobby")["ok"] is True and "park yes, 2 landmark(s) within 600 studs (BigTop 240)" in \
        _step(rec, "lobby")["detail"]


def test_headless_puts_the_template_baseplate_back_unless_the_game_names_it(tmp_path):
    game = tmp_path / "game" / "ServerScriptService"
    game.mkdir(parents=True)
    (game / "Main.server.luau").write_text('print("a lawn")\n')
    fake = FakeGame([], headless=True, census=_census())
    fake.game_dir = tmp_path / "game"
    lobby = _step(_run(fake), "lobby")
    assert lobby["ok"] is False and "the grey template Baseplate" in lobby["detail"] and "the template" in lobby["detail"]
    (game / "Main.server.luau").write_text('workspace.Baseplate:Destroy()\n')
    assert _step(_run(fake), "lobby")["ok"] is True


def test_buttons_must_be_on_top_and_do_something_and_reset_brings_the_player_back():
    hud = [_button("HUD.TextButton[1]", "RESET", "reset"), _button("HUD.Gift", "GIFT", "attr",
                                                                    covered_by={"path": "HUD.Skip", "text": "Skip Stage",
                                                                                "class": "TextButton"}),
           _button("HUD.Skip", "Skip Stage", "attr"), _button("HUD.Dance", "DANCE", "none")]
    fake = FakeGame([], kit=False, headless=True, buttons=hud, obby=True)
    rec = _run(fake)
    layout, buttons = _step(rec, "layout"), _step(rec, "buttons")
    assert layout["ok"] is False and "'GIFT' (HUD.Gift) is covered by 'Skip Stage' (HUD.Skip, a TextButton)" in layout["detail"]
    by = {b["text"]: b for b in rec["buttons"]}
    assert set(by) == {"RESET", "Skip Stage", "DANCE"}  # a covered button is not pressed
    assert by["RESET"]["ok"] and "took the player from the lobby (80 studs away) back to checkpoint 1" in by["RESET"]["detail"]
    assert by["Skip Stage"]["ok"] and "attribute Skip Stage None->pressed" in by["Skip Stage"]["detail"]
    assert by["DANCE"]["ok"] is False and "was pressed (its events fired), but nothing happened" in by["DANCE"]["detail"]
    assert buttons["ok"] is False and "2/3 buttons did something" in buttons["detail"]
    assert fake.pressed[0] == "HUD.TextButton[1]"  # RESET first, right after stage1

    hud[0]["effect"] = "none"
    rec = _run(FakeGame([], kit=False, headless=True, buttons=hud, obby=True))
    reset = next(b for b in rec["buttons"] if b["text"] == "RESET")
    assert reset["ok"] is False and "pressed 80 studs from checkpoint 1, but the player was not brought back" in reset["detail"]


def test_a_button_whose_label_counts_down_is_on_cooldown_not_dead():
    """GIFT 1:10 pressed early only plays an error sound (every funfair HUD button plays a click, so sounds cannot
    count): its countdown is the answer, so it is not judged and does not fail the step."""
    hud = [_button("HUD.TextButton[2]", "GIFT 1:10", "none"), _button("HUD.Mute", "MUTE", "attr")]
    rec = _run(FakeGame([], kit=False, headless=True, buttons=hud))
    gift = next(b for b in rec["buttons"] if b["text"].startswith("GIFT"))
    assert gift["ok"] is None and gift["cooldown"] and "on cooldown, not judged" in gift["detail"]
    assert _step(rec, "buttons")["ok"] is True
    hud[0]["text"] = "GIFT"  # no countdown: a press that does nothing is dead
    assert _step(_run(FakeGame([], kit=False, headless=True, buttons=hud)), "buttons")["ok"] is False


def test_a_button_that_opens_a_panel_is_closed_again_and_studio_without_clicks_presses_nothing():
    hud = [_button("Cosmetics.CostumesButton", "COSTUMES", "panel")]
    fake = FakeGame([], kit=False, headless=True, buttons=hud)
    rec = _run(fake)
    b = rec["buttons"][0]
    assert b["ok"] and "opened Cosmetics.Dim" in b["detail"] and "closed it: pressed its 'X' button" in b["detail"]
    assert fake.panel is False
    fake = FakeGame([], kit=False, buttons=hud)
    rec = _run(fake)
    assert _step(rec, "layout")["ok"] is True and _step(rec, "buttons")["ok"] is None
    assert "not pressed" in rec["buttons"][0]["detail"] and fake.pressed == []


RIDE = {"path": "Workspace.Obby.Stages.RideGate", "prompt": "Workspace.Obby.Stages.RideGate.RidePad.RidePrompt",
        "action": "Ride to Carousel", "enabled": True, "zone": 1, "stage": 10, "next": 2, "next_name": "Carousel",
        "start_path": "Workspace.Obby.ZoneStarts.Zone02Start", "start": [300, 61, 40]}


def test_the_ride_gate_takes_the_player_to_the_next_zone_with_the_stage_kept():
    fake = FakeGame([], kit=False, headless=True, rides=[RIDE])
    rec = _run(fake)
    ride = _step(rec, "ride")
    assert ride["ok"] is True and "'Ride to Carousel' -> arrived at Carousel's start" in ride["detail"]
    assert "Stage 10" in ride["detail"] and fake.stage == 10
    rec = _run(FakeGame([], kit=False, headless=True, rides=[{**RIDE, "works": False}]))
    assert _step(rec, "ride")["ok"] is False and "did NOT arrive at Carousel's start" in _step(rec, "ride")["detail"]
    rec = _run(FakeGame([], kit=False, headless=True, rides=[{**RIDE, "start": None}]))
    assert "which has no ObbyZoneStart pad" in _step(rec, "ride")["detail"]


def _snap(gui=None, attrs=None, costume=None, parts=None, pos=(0, 4, 0), texts=None):
    return {"server": {"attrs": attrs or {}, "stats": {}, "char": {}, "costume": costume or {}, "parts": parts or {},
                       "pos": list(pos)},
            "client": {"gui": gui or {}, "texts": texts or {}}}


def test_effects_leave_out_ambient_change_and_timers_do_not_count():
    s0 = _snap(gui={"HUD.Toast": "TextLabel"}, texts={"HUD.Timer": "1:30"})
    s1 = _snap(texts={"HUD.Timer": "1:29"})  # the toast expired and the timer ticked with nobody acting
    amb = journey.ambient_of(s0, s1)
    s2 = _snap(gui={"Shop.Frame": "Frame", "Shop.Frame.Buy": "TextButton"}, texts={"HUD.Timer": "1:28"},
               attrs={"Coins": "4"}, parts={"Workspace.Ride.Car": 1}, pos=(0, 4, 30))
    eff = journey.diff(s1, s2, amb)
    assert eff["panels"] == [{"path": "Shop.Frame", "size": 2}] and "texts" not in eff
    assert eff["attrs"] == {"Coins": [None, "4"]} and eff["parts"] == ["Workspace.Ride.Car"] and eff["moved"] == 30
    assert journey.observable(eff)
    gone = journey.diff(s0, s1)
    assert gone.get("gui_gone") == ["HUD.Toast"] and not journey.observable(gone)
    assert journey.pressed(gone) and journey.pressed({}, {"skip_denied": [0, 1]}) and not journey.pressed({})
    assert journey.describe({}) == "nothing"


def test_the_wear_button_is_the_one_that_puts_something_new_on_and_close_buttons_are_ranked():
    buttons = [{"path": "a", "text": "TAKE OFF", "costume": "MouseEars"}, {"path": "b", "text": "NEED 30"},
               {"path": "c", "text": "WEAR", "costume": "MouseEars"}, {"path": "d", "text": "WEAR", "costume": "TopHat"}]
    assert journey._pick_wear(buttons, {"Costume_head": "MouseEars"}, {})["path"] == "d"
    assert journey._pick_wear([{"path": "e", "text": "BUY 10"}], {}, {"Coins": "9"}) is None
    assert journey._pick_wear([{"path": "e", "text": "BUY 10"}], {}, {"Coins": "12"})["path"] == "e"
    assert journey._pick_wear([{"path": "f", "text": "FREE"}], {}, {})["path"] == "f"
    rows = [{"path": "p.Buy", "text": "BUY", "name": "Buy"}, {"path": "p.Back", "text": "Back", "name": "Back"},
            {"path": "p.TextButton", "text": "X", "name": "TextButton"}, {"path": "p.CloseIcon", "text": "", "name": "CloseIcon"}]
    assert [b["path"] for b in journey._closers(rows)] == ["p.TextButton", "p.Back", "p.CloseIcon"]


def test_records_are_stale_once_the_game_changes_and_failed_steps_become_anomalies(tmp_path):
    game = tmp_path / "game" / "ServerScriptService"
    game.mkdir(parents=True)
    (game / "Shop.luau").write_text("return {}\n")
    rec = _run(FakeGame([_prompt("ChangingRoomPrompt", "Try on costumes", "none")]))
    journey.save(tmp_path, rec, tmp_path / "game")
    ok, detail = journey.summary(journey.latest(tmp_path), tmp_path / "game")
    assert not ok and "prompts FAILED" in detail and "costume FAILED" in detail
    found = [{"kind": "prompt_no_handler", "kit": False,
              "id": 'prompt_no_handler:ServerScriptService/Shop.luau:ProximityPrompt "ChangingRoomPrompt"',
              "file": "ServerScriptService/Shop.luau",
              "object": 'ProximityPrompt "ChangingRoomPrompt" ("Try on costumes")'}]
    an = journey.as_anomalies(journey.latest(tmp_path), found)
    assert [a["ref"] for a in an] == ["journey:prompts", "journey:costume"]
    assert all(a["proof"].startswith("live journey 1") and a["path"] == "ServerScriptService/Shop.luau"
               and a["static"] for a in an)
    (game / "Shop.luau").write_text("return {fixed = true}\n")
    ok, detail = journey.summary(journey.latest(tmp_path), tmp_path / "game")
    assert not ok and detail.startswith("stale: the game changed since")
    assert journey.summary(None)[1].startswith("no journey yet")


def test_a_step_is_explained_by_the_static_audit_only_when_every_failing_item_is(tmp_path):
    rec = {"n": 3, "engine": "headless", "ts": "t", "steps": [{"step": "buttons", "ok": False, "detail": "RESET, GIFT"}],
           "buttons": [{"text": "RESET", "ok": False}, {"text": "DANCE", "ok": False}]}
    reset = {"kind": "remote_no_listener", "kit": False, "id": "r", "file": "StarterPlayerScripts/Hud.luau",
             "object": 'RemoteEvent "ResetToCheckpoint"'}
    assert "static" not in journey.as_anomalies(rec, [reset])[0]  # DANCE has no static finding: keep the step
    rec["buttons"] = rec["buttons"][:1]
    a = journey.as_anomalies(rec, [reset])[0]
    assert a["static"] == "r" and a["path"] == "StarterPlayerScripts/Hud.luau"


def test_no_sync_records_read_stale_and_done_merges_engines_with_studio_first(tmp_path):
    game = tmp_path / "game"
    (game / "ServerScriptService").mkdir(parents=True)
    (game / "ServerScriptService" / "Main.server.luau").write_text("print(1)\n")
    ran = {"engine": "studio", "steps": [{"step": "join", "ok": True, "detail": "ok"}]}
    journey.save(tmp_path, ran, None)  # forge journey --no-sync: whatever Studio held
    ok, detail = journey.summary(journey.for_done(tmp_path, game), game)
    assert not ok and "stale: it ran on what Studio held (--no-sync)" in detail
    journey.save(tmp_path, {"engine": "headless", "steps": [
        {"step": "layout", "ok": True, "detail": "computed: on top"},
        {"step": "buttons", "ok": False, "detail": "'RESET' was pressed but nothing happened"},
        {"step": "lobby", "ok": True, "detail": "a park"}]}, game)
    journey.save(tmp_path, {"engine": "studio", "steps": [
        {"step": "layout", "ok": False, "detail": "'GIFT' is covered by 'Skip Stage'"},
        {"step": "buttons", "ok": None, "detail": "not pressed (no clicks)"},
        {"step": "lobby", "ok": True, "detail": "a park"}]}, game)
    merged = journey.for_done(tmp_path, game)
    by = {s["step"]: s for s in merged["steps"]}
    assert merged["engine"] == "studio+headless" and merged["ok"] is False
    assert by["layout"]["ok"] is False and by["layout"]["detail"].startswith("[studio]")
    assert by["buttons"]["ok"] is False and by["buttons"]["detail"].startswith("[headless]")
    assert by["buttons"]["engines"] == {"studio": None, "headless": False}
    ok, detail = journey.summary(merged, game)
    assert not ok and "(studio+headless, journey 3+2)" in detail and "layout FAILED: [studio]" in detail


@pytest.mark.skipif(shutil.which("luau-compile") is None, reason="luau-compile not on PATH")
def test_every_luau_script_the_journey_sends_compiles(tmp_path):
    import subprocess

    fill = {"__X__": "1", "__Y__": "2", "__Z__": "3", "__RADIUS__": "150", "__UID__": "7",
            "__CENTER__": "Vector3.new(1, 2, 3)", "__ROOTS__": json.dumps('["Cosmetics.Dim"]'),
            "__ACTION__": '"equip"', "__ID__": '"TopHat"', "__LANDMARK_RADIUS__": "600", "__REAL__": "true",
            "__VISIBLE__": "false"}
    for name in ("PROMPTS_LUAU", "SERVER_SNAP_LUAU", "CLIENT_SNAP_LUAU", "CENSUS_LUAU", "PANEL_BUTTONS_LUAU",
                 "BUTTONS_LUAU", "HIDE_LUAU", "COSTUME_REQUEST_LUAU", "RIDES_LUAU"):
        code = getattr(journey, name)
        for k, v in fill.items():
            code = code.replace(k, v)
        assert "__" not in re.sub(r"--.*", "", code), name
        path = tmp_path / f"{name}.luau"
        path.write_text(code)
        res = subprocess.run(["luau-compile", "--null", str(path)], capture_output=True, text=True)
        assert res.returncode == 0, f"{name}: {res.stdout}{res.stderr}"


# ------------------------------------------------------------------------------------ headless, real harness

LOBBY = r"""
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local plaza = Instance.new("Part")
plaza.Name, plaza.Anchored, plaza.Size, plaza.Position = "Plaza", true, Vector3.new(80, 1, 80), Vector3.new(0, -0.5, 0)
plaza.Parent = workspace
local function stall(name, x, z)
	local p = Instance.new("Part")
	p.Name, p.Anchored, p.Size, p.Position = name, true, Vector3.new(4, 1, 4), Vector3.new(x, 0.5, z or 20)
	p.Parent = workspace
	return p
end
local open = Instance.new("RemoteEvent")
open.Name = "OpenShop"
open.Parent = RS
for _, spot in { { "ShopStall", -12, "Open shop" }, { "Kiosk", -12, "Browse the shop", 32 } } do
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText, prompt.HoldDuration, prompt.MaxActivationDistance = spot[3], 0, 10
	prompt.Parent = stall(spot[1], spot[2], spot[4])
	prompt.Triggered:Connect(function(player)
		open:FireClient(player)
	end)
end
local broken = Instance.new("ProximityPrompt")
broken.ActionText, broken.HoldDuration, broken.MaxActivationDistance = "Try on costumes", 0, 10
broken.Parent = stall("ChangingRoomPad", 12)
local gift = Instance.new("RemoteEvent")
gift.Name = "ClaimGift"
gift.Parent = RS
gift.OnServerEvent:Connect(function(player)
	player:SetAttribute("Gifted", true)
end)
"""
CLIENT = r"""
local RS = game:GetService("ReplicatedStorage")
local lp = game:GetService("Players").LocalPlayer
local gui = Instance.new("ScreenGui")
gui.Name = "Shop"
gui.Parent = lp:WaitForChild("PlayerGui")
local frame = Instance.new("Frame")
frame.Name, frame.Visible, frame.Size = "Panel", false, UDim2.fromScale(0.5, 0.5)
frame.Parent = gui
local buy = Instance.new("TextButton")
buy.Name, buy.Text, buy.Size = "Buy", "BUY", UDim2.fromOffset(120, 40)
buy.Parent = frame
local x = Instance.new("TextButton")
x.Name, x.Text, x.Size, x.Position = "Close", "X", UDim2.fromOffset(40, 40), UDim2.new(1, -44, 0, 4)
x.Parent = frame
x.Activated:Connect(function()
	frame.Visible = false
end)
RS:WaitForChild("OpenShop").OnClientEvent:Connect(function()
	frame.Visible = true
end)
local hud = Instance.new("ScreenGui")
hud.Name = "HUD"
hud.Parent = lp:WaitForChild("PlayerGui")
local function button(text, pos, size, z)
	local b = Instance.new("TextButton")
	b.Text, b.Position, b.Size, b.ZIndex = text, pos, size, z or 1
	b.Parent = hud
	return b
end
button("GIFT", UDim2.fromScale(0.02, 0.6), UDim2.fromScale(0.15, 0.08)).Activated:Connect(function()
	RS:WaitForChild("ClaimGift"):FireServer()
end)
button("DANCE", UDim2.fromScale(0.02, 0.85), UDim2.fromScale(0.15, 0.08))
local skip = button("SKIP", UDim2.fromScale(0.3, 0.68), UDim2.fromScale(0.12, 0.1), 5)
skip.Activated:Connect(function()
	skip.Text = "SKIPPED"
end)
button("SHOP", UDim2.fromScale(0.3, 0.7), UDim2.fromScale(0.15, 0.08))
"""


@pytest.mark.skipif(shutil.which("luau") is None, reason="luau CLI not installed")
def test_headless_journey_with_the_real_harness(tmp_path):
    """Two prompts open one panel (each closed with its X before the next), a dead prompt, a button covered by
    another (computed layout), a dead button and two working ones, pressed through the real headless press."""
    from forge import headless as hl

    root = tmp_path / "game"
    for rel, text in {"ServerScriptService/Lobby.server.luau": LOBBY, "StarterPlayerScripts/Shop.client.luau": CLIENT,
                      "ServerScriptService/ForgeTest.server.luau": (REPO / "mubit-tester/roblox/ForgeTest.server.luau").read_text(),
                      "StarterPlayerScripts/ForgeTestAgent.client.luau":
                          (REPO / "mubit-tester/roblox/ForgeTestAgent.client.luau").read_text()}.items():
        (root / rel).parent.mkdir(parents=True, exist_ok=True)
        (root / rel).write_text(text)

    async def go():
        hs = hl.HeadlessStudio(root, players=1, idle=0.0)
        try:
            return await journey.run_journey(hs, log=lambda _: None)
        finally:
            await hs.stop()

    t0 = time.monotonic()
    rec = asyncio.run(go())
    assert rec["engine"] == "headless" and time.monotonic() - t0 < 180
    by = {p["action"]: p for p in rec["prompts"]}
    for action in ("Open shop", "Browse the shop"):  # the same panel twice: closed with its X in between
        assert by[action]["ok"] and "opened Shop.Panel (3 GUI objects)" in by[action]["detail"], journey.render(rec)
        assert "closed it: pressed its 'X' button" in by[action]["detail"]
    assert not by["Try on costumes"]["ok"] and by["Try on costumes"]["server_saw"]
    assert "nothing happened" in by["Try on costumes"]["detail"]
    assert _step(rec, "prompts")["ok"] is False and _step(rec, "costume")["ok"] is False
    lobby = _step(rec, "lobby")  # one plaza and three stalls is a bare world, on the template baseplate
    assert lobby["ok"] is False and "a bare world" in lobby["detail"] and "template Baseplate" in lobby["detail"]
    layout = _step(rec, "layout")
    assert layout["ok"] is False and "'SHOP' (HUD.TextButton[4]) is covered by 'SKIP' (HUD.TextButton[3]" in layout["detail"]
    pressed = {b["text"]: b for b in rec["buttons"]}
    assert set(pressed) == {"GIFT", "DANCE", "SKIP"}
    assert pressed["GIFT"]["ok"] and "attribute Gifted None->true" in pressed["GIFT"]["detail"]
    assert pressed["SKIP"]["ok"] and "'SKIP'->'SKIPPED'" in pressed["SKIP"]["detail"]
    assert pressed["DANCE"]["ok"] is False and "nothing happened" in pressed["DANCE"]["detail"]


def test_refresh_plays_a_new_player_in_a_new_server_not_the_sessions_used_one(tmp_path, monkeypatch):
    """After a fix cycle the harness's player has been playtesting (the live loop's one was 19000 studs up the
    course): the journey must not start there."""
    from forge import headless as hl

    game = tmp_path / "game"
    (game / "ServerScriptService").mkdir(parents=True)
    (game / "ServerScriptService" / "Main.server.luau").write_text("print(1)\n")
    ran, made = [], []

    async def run(studio, **k):
        ran.append(studio)
        return {"ok": True, "engine": "headless", "steps": [{"step": "join", "ok": True, "detail": "x"}]}

    class Fresh:
        headless = True

        def __init__(self, game_dir, **k):
            self.game_dir, self.stopped = game_dir, False
            made.append(self)

        async def stop(self):
            self.stopped = True

    class Used:
        headless = True
        slug = "g"

    class Harness:
        def __init__(self, studio):
            self.studio, self.ready = studio, 0

        async def ensure_ready(self):
            self.ready += 1

    monkeypatch.setattr(journey, "run_journey", run)
    monkeypatch.setattr(hl, "HeadlessStudio", Fresh)
    used = Harness(Used())
    asyncio.run(journey.refresh(used, game, tmp_path, force=True, log=lambda _: None))
    assert ran == made and made[0].game_dir == game and made[0].stopped  # a new headless session, stopped after

    class Window:
        headless = False
        stops = 0

        async def stop(self):
            Window.stops += 1

    studio = Harness(Window())
    asyncio.run(journey.refresh(studio, game, tmp_path, force=True, log=lambda _: None))
    assert Window.stops == 1 and studio.ready == 1 and ran[-1] is studio.studio  # the playtest restarted first


def test_forge_journey_no_sync_saves_a_record_forge_done_reads_as_stale(tmp_path, monkeypatch):
    import dataclasses
    from contextlib import asynccontextmanager

    from forge import cli
    from forge import headless as hl
    from forge.config import load_settings

    settings = dataclasses.replace(load_settings(), runs_dir=tmp_path / "runs", repo_root=tmp_path)
    game = settings.runs_dir / "g" / "game" / "ServerScriptService"
    game.mkdir(parents=True)
    (game / "Main.server.luau").write_text("print(1)\n")

    class Studio:  # a Studio window: plays and stops; with --no-sync nothing is pushed into it
        synced = False

        async def play(self):
            return {}

        async def stop(self):
            return None

    @asynccontextmanager
    async def backend(*a, **k):
        yield Studio()

    async def sync(*a, **k):
        Studio.synced = True

    async def run(studio, **k):
        return {"ok": True, "engine": "studio", "steps": [{"step": "join", "ok": True, "detail": "Ana joined"}]}

    monkeypatch.setattr(cli, "load_settings", lambda: settings)
    monkeypatch.setattr(cli, "sync_before_checks", sync)
    monkeypatch.setattr(hl, "backend", backend)
    monkeypatch.setattr(journey, "run_journey", run)
    assert cli.main(["journey", "g", "--studio", "Forge", "--no-sync"]) == 0 and not Studio.synced
    run_dir = settings.runs_dir / "g"
    assert journey.latest(run_dir)["game_hash"] is None
    assert journey.summary(journey.for_done(run_dir, game.parent), game.parent)[1].startswith("stale: it ran on what")
    assert cli.main(["journey", "g", "--studio", "Forge"]) == 0 and Studio.synced
    assert journey.summary(journey.for_done(run_dir, game.parent), game.parent)[0] is True
