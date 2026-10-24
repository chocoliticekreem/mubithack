"""On-screen UI for AI testers: `ui` in observations, the `press` action (a real Studio MCP click)."""

from __future__ import annotations

import json
import re

from mubit_tester import ai, play
from mubit_tester.harness import WHO_LUAU, Harness
from test_harness import decode_call
from test_tester_ai import PLAYERS, FakeHarness, ScriptedLLM, _a, _obs, _settings

BUTTONS = [{"text": f"Button {i}", "path": f"Gui.Frame.Button{i}", "gui": "Gui", "x": 10 * i, "y": 20, "w": 80,
            "h": 30} for i in range(10)]


def test_compact_observation_keeps_ui_while_trimming_the_rest():
    obs = dict(_obs(101))
    obs["things"] = [dict(obs["things"][0], name=f"T{i}" * 80) for i in range(12)]
    obs["hud"] = ["x" * 80] * 10
    obs["ui"] = list(BUTTONS)
    obs["panels"] = [{"gui": "Gui", "path": "Gui.Frame", "title": "Battle Pass"}]
    out = play.compact_observation(obs)
    assert len(json.dumps(out, separators=(",", ":"))) < play.OBS_MAX_CHARS
    assert out["ui"] == BUTTONS and out["panels"] == obs["panels"]
    assert len(out["things"]) < 12


def test_compact_observation_trims_ui_last_and_keeps_a_floor():
    obs = dict(_obs(101))
    obs["ui"] = [dict(b, text="t" * 300) for b in BUTTONS]
    out = play.compact_observation(obs, limit=2200)
    assert play.UI_KEEP <= len(out["ui"]) < len(BUTTONS)
    assert out["things"] and out["hud"]  # ui was trimmed before the rest was emptied
    assert len(play.compact_observation(obs, limit=1500)["ui"]) == play.UI_KEEP  # never below the floor


def test_brief_shows_panels_and_buttons():
    obs = dict(_obs(101), ui=BUTTONS[:2], panels=[{"path": "Gui.Frame", "title": "Battle Pass"}])
    brief = play._obs_brief(obs)
    assert "panels=Battle Pass" in brief and "ui=Button 0,Button 1" in brief


def test_map_action_press():
    assert ai.map_action({"action": "press", "args": {"path": "BattlePassGui.PassButton"}}) == \
        ("press", {"path": "BattlePassGui.PassButton"})
    assert ai.map_action({"action": "click", "args": {"text": "Claim"}}) == ("press", {"text": "Claim"})
    assert ai.map_action({"action": "press", "args": {}}).startswith("error: press needs path or text")


# --------------------------------------------------------------------------- Harness.press


class UIStudio:
    """ForgeTest server calls via execute_luau(Server); per-window Client calls via call(studio_id=...)."""

    def __init__(self, windows: dict[str, dict | None], session="S1", fired=True, instance_path=True):
        self.studio_id = "own"
        self.windows = windows  # studio_id -> {"userId", "session"} | None (no Client datamodel)
        self.session = session
        self.fired = fired
        self.instance_path = instance_path
        self.server_calls: list[tuple[str, dict]] = []
        self.mouse: list[tuple[str, list]] = []
        self.luau_windows: list[str] = []

    async def execute_luau(self, code, datamodel="Edit", timeout=None):
        cmd, args = decode_call(code)
        self.server_calls.append((cmd, args))
        if cmd == "ping":
            res = {"version": "2", "session": self.session}
        elif cmd == "players":
            res = [{"userId": 101, "name": "Alice", "helmet": 1}, {"userId": 102, "name": "Bob", "helmet": 2}]
        elif cmd == "ui_target":
            res = {"path": "BattlePassGui.PassButton", "text": "Pass", "gui": "BattlePassGui", "x": 45, "y": 333}
            if self.instance_path:
                res["instance_path"] = "LocalPlayer.PlayerGui.BattlePassGui.PassButton"
        elif cmd == "ui_effect":
            res = {"path": "BattlePassGui.PassButton", "text": "Pass", "fired": self.fired, "changed": self.fired,
                   "effect": {"panels_opened": ["BattlePassGui.Panel 'Battle Pass'"] if self.fired else [],
                              "hud_gone": []}}
        else:
            return json.dumps({"ok": False, "error": f"unknown command {cmd}"})
        return json.dumps({"ok": True, "result": res})

    async def call(self, tool, **args):
        sid = args.get("studio_id")
        if tool == "execute_luau":
            assert args["code"] == WHO_LUAU and args["datamodel_type"] == "Client"
            self.luau_windows.append(sid)
            who = self.windows.get(sid)
            if who is None:
                raise RuntimeError("no Client datamodel")
            return json.dumps(who)
        if tool == "user_mouse_input":
            assert args["datamodel_type"] == "Client"
            self.mouse.append((sid, args["actions"]))
            return "Success"
        raise AssertionError(tool)


async def test_press_clicks_in_the_window_that_drives_the_player():
    st = UIStudio({"own": {"userId": 101, "session": "S1"}})
    res = await Harness(st).press("Alice", text="Pass", wait=0)
    assert res["done"] is True and res["fired"] is True
    assert res["effect"] == {"panels_opened": ["BattlePassGui.Panel 'Battle Pass'"]}
    assert "button fired" in res["detail"] and "Battle Pass" in res["detail"]
    [(sid, actions)] = st.mouse
    assert sid == "own"
    assert actions[0] == {"action": "moveTo", "instance_path": "LocalPlayer.PlayerGui.BattlePassGui.PassButton"}
    assert actions[-1] == {"action": "mouseButtonClick", "mouse_button": "left"}
    cmds = [c for c, _ in st.server_calls]
    assert cmds.index("ui_target") < cmds.index("ui_effect")
    assert ("ui_target", {"userId": "Alice", "text": "Pass"}) in st.server_calls


async def test_press_falls_back_to_coordinates_and_reports_a_dead_button():
    st = UIStudio({"own": {"userId": 101, "session": "S1"}}, fired=False, instance_path=False)
    res = await Harness(st).act(101, "press", path="BattlePassGui.PassButton")
    assert res["done"] is False and "did NOT fire" in res["detail"] and "nothing on screen" in res["detail"]
    assert st.mouse[0][1][0] == {"action": "moveTo", "x": 45, "y": 333}


async def test_press_refuses_players_without_a_window_and_never_fakes_it():
    st = UIStudio({"own": {"userId": 101, "session": "S1"}})
    res = await Harness(st).press(102, text="Pass", wait=0)
    assert res["done"] is False and res["pressable"] is False and "101" in res["detail"]
    assert not st.mouse and "ui_target" not in [c for c, _ in st.server_calls]


async def test_ui_windows_only_asks_known_windows_and_checks_the_session():
    st = UIStudio({"own": None, "c1": {"userId": 101, "session": "S1"}, "c2": {"userId": 102, "session": "OTHER"},
                   "unrelated": {"userId": 102, "session": "S1"}})
    h = Harness(st, client_windows=["c1", "c2"])
    assert await h.ui_windows() == {"101": "c1"}
    assert set(st.luau_windows) == {"own", "c1", "c2"}  # "unrelated" was never touched
    await h.ui_windows()
    assert len(st.luau_windows) == 3  # cached for this session


async def test_press_needs_a_target():
    res = await Harness(UIStudio({})).press(101)
    assert res["done"] is False and "path or text" in res["detail"]


# --------------------------------------------------------------------------- AI testers


class UIHarness(FakeHarness):
    def __init__(self, windows):
        super().__init__(PLAYERS[:2])
        self.windows = windows

    async def ui_windows(self):
        return self.windows

    async def observe(self, user_id):
        return dict(await super().observe(user_id), ui=BUTTONS[:2], panels=[])

    async def act(self, user_id, action, **args):
        res = await super().act(user_id, action, **args)
        if action == "press":
            self.pressed = True
        return res

    async def events(self, since=None):
        res = await super().events(since)
        if since is not None and getattr(self, "pressed", False):
            self.pressed = False
            res["events"].append({"t": 9, "kind": "ui_press", "data": {
                "name": "Alice", "userId": 101, "path": "BattlePassGui.PassButton", "text": "Pass",
                "gui": "BattlePassGui", "fired": True, "changed": True,
                "effect": {"panels_opened": ["BattlePassGui.Panel 'Battle Pass'"], "hud_gone": []}}})
        return res


async def test_testers_are_told_about_ui_and_who_can_press(tmp_path):
    llm = ScriptedLLM({"Alice": [_a("press", {"text": "Pass"})]}, delay=0)
    h = UIHarness({"101": "own"})
    rep = await ai.multi_playtest(_settings(tmp_path), "use the battle pass", players=2, steps=2, llm=llm,
                                  harness=h, step_seconds=0)
    assert (101, "press", {"text": "Pass"}) in h.acts
    users = {re.search(r"## You\n(\w+)", c.user).group(1): c.user for c in llm.calls if c.role == "player"}
    assert "## On-screen UI" in users["Alice"] and '"action": "press"' in users["Alice"]
    assert "can NOT press" not in users["Alice"]
    assert "You can NOT press UI" in users["Bob"] and "Players who can: Alice" in users["Bob"]
    assert rep["ui_pressers"] == ["Alice"]
    # before free play the scripted UI pass pressed both on-screen buttons (assigned to Alice), then her own press
    assert [a[2] for a in h.acts if a[1] == "press"] == [{"path": "Gui.Frame.Button0"}, {"path": "Gui.Frame.Button1"},
                                                          {"text": "Pass"}]
    assert [r["surface"] for r in rep["ui_pass"]] == ["Button 0", "Button 1"]
    assert rep["ui_presses"][-1] == {"t": 9, "player": "Alice", "text": "Pass", "path": "BattlePassGui.PassButton",
                                     "gui": "BattlePassGui", "fired": True, "changed": True,
                                     "effect": {"panels_opened": ["BattlePassGui.Panel 'Battle Pass'"]}}


def test_ui_presses_ignores_other_events():
    assert ai.ui_presses([{"kind": "countdown", "data": {}}, "junk", {"kind": "ui_press", "data": None}]) == []
