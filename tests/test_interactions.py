"""Static interaction audit (forge/interactions.py): prompts, buttons, click detectors and remotes that cannot work,
found from the parsed source with file:line, and nothing reported that the game does handle."""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from forge import interactions

pytestmark = pytest.mark.skipif(shutil.which("luau-ast") is None, reason="luau-ast not on PATH (brew install luau)")

# the overnight Funfair Frenzy bug: Lobby.build puts a prompt on the pad, Shop.setupPad adds a second one, and
# nothing connects Triggered on either
LOBBY = """local Lobby = {}
function Lobby.build()
	local pad = Instance.new("Part")
	pad.Name = "ChangingRoomPad"
	pad.Parent = workspace
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Try on costumes"
	prompt.ObjectText = "Changing Room"
	prompt.Parent = pad
	return { changingRoomPad = pad }
end
return Lobby
"""
SHOP = """local CollectionService = game:GetService("CollectionService")
local Shop = {}
local function setupPad(pad)
	local prompt = pad:FindFirstChild("ChangingRoomPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ChangingRoomPrompt"
		prompt.ActionText = "Try on costumes"
		prompt.Parent = pad
	end
	prompt:SetAttribute("ChangingRoom", true)
	CollectionService:AddTag(pad, "CostumeStand")
end
function Shop.init(info)
	setupPad(info.changingRoomPad)
end
return Shop
"""
SHOP_FIXED = SHOP.replace(
    '	prompt:SetAttribute("ChangingRoom", true)\n',
    '	prompt:SetAttribute("ChangingRoom", true)\n'
    '	prompt.Triggered:Connect(function(player)\n'
    '		game.ReplicatedStorage.CosmeticsRemotes.Open:FireClient(player)\n'
    '	end)\n').replace('pad:FindFirstChild("ChangingRoomPrompt")',
                     'pad:FindFirstChild("ChangingRoomPrompt") or pad:FindFirstChildWhichIsA("ProximityPrompt")')
# Forge's test harness handles every prompt; it is not the game, so it must not hide a dead one
HARNESS = """game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt, player)
	print(prompt, player)
end)
"""


def _game(root: Path, files: dict[str, str]) -> Path:
    for rel, text in files.items():
        p = root / "game" / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
    return root / "game"


def _line(text: str, needle: str, nth: int = 1) -> int:
    hits = [i + 1 for i, ln in enumerate(text.splitlines()) if needle in ln]
    return hits[nth - 1]


def _found(res: dict) -> set[tuple[str, str, int]]:
    return {(x["kind"], x["file"], x["line"]) for x in res["findings"]}


def test_overnight_changing_room_prompts_are_found_with_file_and_line(tmp_path):
    game = _game(tmp_path, {"ServerScriptService/Lobby.luau": LOBBY, "ServerScriptService/Shop.luau": SHOP,
                            "ServerScriptService/ForgeTest.server.luau": HARNESS})
    res = interactions.audit(game)
    assert res["ok"] is False
    assert _found(res) == {
        ("prompt_no_handler", "ServerScriptService/Lobby.luau", _line(LOBBY, 'Instance.new("ProximityPrompt")')),
        ("prompt_no_handler", "ServerScriptService/Shop.luau", _line(SHOP, 'Instance.new("ProximityPrompt")')),
    }
    shop = next(x for x in res["findings"] if x["file"].endswith("Shop.luau"))
    assert shop["object"] == 'ProximityPrompt "ChangingRoomPrompt" ("Try on costumes")'
    assert "presses E, and nothing happens" in shop["detail"] and shop["severity"] == "high"
    assert "Shop.luau:" in interactions.summary(res) and "2 dead" in interactions.summary(res)


def test_connecting_the_prompt_clears_both_and_still_dead_says_so(tmp_path):
    game = _game(tmp_path, {"ServerScriptService/Lobby.luau": LOBBY, "ServerScriptService/Shop.luau": SHOP})
    anomalies = interactions.as_anomalies(interactions.audit(game))
    shop = next(a for a in anomalies if a.get("path") == "ServerScriptService/Shop.luau")
    assert shop["proof"].startswith("static interaction audit") and shop["ref"].startswith("dead:ServerScriptService/Shop")
    assert shop["finding"] == {"kind": "prompt_no_handler", "file": "ServerScriptService/Shop.luau",
                               "object": 'ProximityPrompt "ChangingRoomPrompt" ("Try on costumes")', "count": 1,
                               "in_file": 1}
    assert shop["ref"] == "dead:ServerScriptService/Shop.luau:prompt_no_handler:ProximityPrompt-ChangingRoomPrompt-Try-on-costumes"
    assert "still finds it" in interactions.still_dead(game, shop["finding"])
    (game / "ServerScriptService/Shop.luau").write_text(SHOP_FIXED)
    assert interactions.still_dead(game, shop["finding"]) == ""
    # the fix fires the costume panel's Open remote, and nothing on the client listens yet
    assert _found(interactions.audit(game)) == {
        ("remote_no_listener", "ServerScriptService/Shop.luau", _line(SHOP_FIXED, "Open:FireClient"))}
    _game(tmp_path, {"StarterPlayerScripts/Panel.client.luau":
                     'local remotes = game.ReplicatedStorage:WaitForChild("CosmeticsRemotes")\n'
                     'remotes:WaitForChild("Open").OnClientEvent:Connect(function() end)\n'})
    # Shop now takes whatever prompt is on the pad (FindFirstChildWhichIsA) of a pad it cannot follow: Lobby's is
    # covered too, and the summary says it is only by a generic handler
    res = interactions.audit(game)
    assert res["ok"] is True and res["stats"]["generic"] == 1
    assert "1 only by a generic handler (Shop.luau:" in interactions.summary(res)


HANDLED = """local p1 = Instance.new("ProximityPrompt")
p1.Parent = workspace
p1.Triggered:Connect(function(player)
	player:SetAttribute("Opened", true)
end)

local p2 = Instance.new("ProximityPrompt")
p2.Name = "DoorPrompt"
p2.Parent = workspace

local function hook(pr)
	pr.TriggerEnded:Connect(function() end)
end
local p3 = Instance.new("ProximityPrompt")
p3.Parent = workspace
hook(p3)

local alias = Instance.new("ProximityPrompt")
local same = alias
same.Parent = workspace
same.Triggered:Connect(function() end)

local cd = Instance.new("ClickDetector")
cd.Parent = workspace
cd.MouseClick:Connect(function() end)

local function button(parent, text, onClick)
	local b = Instance.new("TextButton")
	b.Text = text
	b.Parent = parent
	b.Activated:Connect(onClick)
	return b
end
local gui = Instance.new("ScreenGui")
button(gui, "PLAY", function() end)
local shop = button(gui, "SHOP", function() end)
shop.Visible = true
"""
DOOR = """local door = workspace:WaitForChild("DoorPrompt")
door.Triggered:Connect(function() end)
"""


def test_handled_objects_are_not_findings(tmp_path):
    game = _game(tmp_path, {"ServerScriptService/World.server.luau": HANDLED,
                            "StarterPlayerScripts/Door.client.luau": DOOR})
    res = interactions.audit(game)
    assert res["findings"] == [] and res["ok"] is True
    assert res["stats"]["objects"] >= 6 and res["stats"]["handled"] == res["stats"]["objects"]


HUD = """local function mk(className, props, parent)
	local inst = Instance.new(className)
	for k, v in props do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end
local gui = mk("ScreenGui", { Name = "Hud" }, game.Players.LocalPlayer:WaitForChild("PlayerGui"))
local close = mk("TextButton", { Name = "Close", Text = "X" }, gui)
local buy = mk("TextButton", { Name = "Buy", Text = "BUY" }, gui)
buy.Activated:Connect(function()
	print("buy")
end)
"""


def test_a_button_from_a_generic_constructor_with_no_handler_is_found_at_its_call(tmp_path):
    game = _game(tmp_path, {"StarterPlayerScripts/Hud.client.luau": HUD})
    res = interactions.audit(game)
    assert _found(res) == {("button_no_handler", "StarterPlayerScripts/Hud.client.luau", _line(HUD, "local close"))}
    assert res["findings"][0]["object"] == 'TextButton "Close" ("X")' and res["findings"][0]["severity"] == "medium"


ESCAPED = """local prompts = {}
for i = 1, 3 do
	local p = Instance.new("ProximityPrompt")
	p.Parent = workspace
	prompts[i] = p
end
return prompts
"""


def test_an_object_the_audit_cannot_follow_is_unknown_not_a_finding(tmp_path):
    res = interactions.audit(_game(tmp_path, {"ServerScriptService/Prompts.luau": ESCAPED}))
    assert res["findings"] == [] and res["stats"]["unknown"] == 1


GLOBAL_HANDLER = """local PPS = game:GetService("ProximityPromptService")
local p = Instance.new("ProximityPrompt")
p.Name = "Bell"
p.Parent = workspace
local q = Instance.new("ProximityPrompt")
q.Name = "Gong"
q.Parent = workspace
PPS.PromptTriggered:Connect(function(prompt, player)
	if prompt.Name == "Bell" then
		player:SetAttribute("Rang", true)
	end
end)
"""


def test_a_prompt_triggered_handler_covers_the_prompts_it_tests_for(tmp_path):
    src = GLOBAL_HANDLER
    res = interactions.audit(_game(tmp_path, {"ServerScriptService/Bells.server.luau": src}))
    assert _found(res) == {("prompt_no_handler", "ServerScriptService/Bells.server.luau", _line(src, "local q ="))}
    catch_all = src.replace('if prompt.Name == "Bell" then', "if player then")
    res = interactions.audit(_game(tmp_path / "b", {"ServerScriptService/Bells.server.luau": catch_all}))
    assert res["findings"] == []


CONFIG = """local Config = {}
Config.Remotes = { Reset = "ResetToCheckpoint", Gift = "ClaimGift" }
return Config
"""
NET = """local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Config"))
local folder = Instance.new("Folder")
folder.Name = "Remotes"
folder.Parent = RS
local function remote(name)
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end
local gift = remote(Config.Remotes.Gift)
gift.OnServerEvent:Connect(function(player) end)
local toast = remote("Toast")
toast.OnServerEvent:Connect(function(player) end)
local ask = Instance.new("RemoteFunction")
ask.Name = "Ask"
ask.Parent = folder
"""
CLIENT = """local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Config"))
local remotes = RS:WaitForChild("Remotes")
remotes:WaitForChild(Config.Remotes.Gift):FireServer()
remotes:WaitForChild(Config.Remotes.Reset):FireServer()
local ask = remotes:WaitForChild("Ask")
local ok, res = pcall(ask.InvokeServer, ask, 1)
"""
ROUTER = """for _, r in game.ReplicatedStorage:WaitForChild("Remotes"):GetChildren() do
	r.OnServerEvent:Connect(function() end)
end
"""


def test_remotes_are_matched_by_name_through_config_modules_and_helpers(tmp_path):
    files = {"ReplicatedStorage/Config.luau": CONFIG, "ServerScriptService/Net.server.luau": NET,
             "StarterPlayerScripts/Hud.client.luau": CLIENT}
    res = interactions.audit(_game(tmp_path, files))
    assert _found(res) == {
        ("remote_no_listener", "StarterPlayerScripts/Hud.client.luau", _line(CLIENT, "Config.Remotes.Reset")),
        ("remote_never_fired", "ServerScriptService/Net.server.luau", _line(NET, "toast.OnServerEvent")),
        ("remote_no_answer", "StarterPlayerScripts/Hud.client.luau", _line(CLIENT, "pcall(ask.InvokeServer")),
    }
    objects = {x["kind"]: x["object"] for x in res["findings"]}
    assert objects["remote_no_listener"] == 'RemoteEvent "ResetToCheckpoint"'
    assert objects["remote_no_answer"] == 'RemoteFunction "Ask"'
    # a listener the audit cannot name may be the one that handles Reset: it is not reported any more
    res = interactions.audit(_game(tmp_path / "b", {**files, "ServerScriptService/Router.server.luau": ROUTER}))
    assert "remote_no_listener" not in {x["kind"] for x in res["findings"]}


SIGNALS = """local M = {}
local done = Instance.new("BindableEvent")
M.Done = done.Event
function M.finish()
	done:Fire()
end
local tick = Instance.new("BindableEvent")
tick:Fire()
local ask = Instance.new("BindableFunction")
ask:Invoke(1)
return M
"""
USES = """local M = require(script.Parent.Signals)
M.Done:Connect(function() end)
"""


def test_bindables_follow_their_exported_event_and_a_silent_fire_is_only_low(tmp_path):
    res = interactions.audit(_game(tmp_path, {"ServerScriptService/Signals.luau": SIGNALS,
                                              "ServerScriptService/Uses.server.luau": USES}))
    by_kind = {x["kind"]: x for x in res["findings"]}
    assert set(by_kind) == {"bindable_no_listener", "bindable_no_answer"}
    assert by_kind["bindable_no_listener"]["line"] == _line(SIGNALS, "tick:Fire()")
    assert by_kind["bindable_no_listener"]["severity"] == "low" and by_kind["bindable_no_answer"]["severity"] == "high"
    assert res["ok"] is False  # the unanswered Invoke blocks; the low one alone would not


DEAD_KIT = """local Kit = {}
function Kit.stand(part)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Ride"
	prompt.Parent = part
end
return Kit
"""


def test_kit_modules_count_only_when_the_game_uses_them_and_are_never_a_fix_path(tmp_path):
    files = {"ReplicatedStorage/Kit/Unused.luau": DEAD_KIT, "ReplicatedStorage/Kit/Rides.luau": DEAD_KIT,
             "ServerScriptService/Main.server.luau": 'local Rides = require(game.ReplicatedStorage.Kit.Rides)\n'
                                                    'Rides.stand(workspace.Baseplate)\n'}
    res = interactions.audit(_game(tmp_path, files))
    assert [(x["file"], x["kit"]) for x in res["findings"]] == [("ReplicatedStorage/Kit/Rides.luau", True)]
    assert "path" not in interactions.as_anomalies(res)[0]


def test_without_luau_ast_the_audit_is_unknown_never_a_pass(tmp_path, monkeypatch):
    monkeypatch.setattr(interactions.shutil, "which", lambda name: None)
    res = interactions.audit(_game(tmp_path, {"ServerScriptService/Shop.luau": SHOP}))
    assert res["ok"] is None and "luau-ast" in interactions.summary(res)
    assert interactions.still_dead(tmp_path / "game", {"kind": "prompt_no_handler", "file": "x", "count": 1}) == ""


def test_a_file_that_does_not_parse_is_reported_not_audited(tmp_path):
    res = interactions.audit(_game(tmp_path, {"ServerScriptService/Broken.luau": "local x = (\n",
                                              "ServerScriptService/Shop.luau": SHOP}))
    assert [e["file"] for e in res["errors"]] == ["ServerScriptService/Broken.luau"]
    assert {x["file"] for x in res["findings"]} == {"ServerScriptService/Shop.luau"}


TOOLS_HUD = """local gui = Instance.new("ScreenGui")
gui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local reset = Instance.new("TextButton")
reset.Name = "Reset"
reset.Text = "RESET"
reset.Parent = gui
"""
AXE_GUARDED = """game.Players.PlayerAdded:Connect(function(player)
	player:WaitForChild("Backpack").ChildAdded:Connect(function(tool)
		if tool:IsA("Tool") then
			tool.Activated:Connect(function() print("chop") end)
		end
	end)
end)
"""
AXE_BACKPACK = """local Players = game:GetService("Players")
local function hook(item)
	item.Activated:Connect(function() print("swing") end)
end
Players.PlayerAdded:Connect(function(player)
	player.Backpack.ChildAdded:Connect(hook)
	for _, item in player.Backpack:GetChildren() do
		item.Activated:Connect(function() print("swing") end)
	end
end)
"""


def test_a_tools_activated_does_not_hide_a_dead_button(tmp_path):
    for i, tools in enumerate((AXE_GUARDED, AXE_BACKPACK)):
        res = interactions.audit(_game(tmp_path / str(i), {"StarterPlayerScripts/Hud.client.luau": TOOLS_HUD,
                                                           "ServerScriptService/Axe.server.luau": tools}))
        assert _found(res) == {("button_no_handler", "StarterPlayerScripts/Hud.client.luau", 3)}, i
        assert res["stats"]["tool_connections"] >= 1 and res["stats"]["generic"] == 0


SCOPED_HANDLER = """local folder = Instance.new("Folder")
folder.Name = "Stalls"
folder.Parent = workspace
local function stall(text)
	local part = Instance.new("Part")
	part.Parent = folder
	local p = Instance.new("ProximityPrompt")
	p.ActionText = text
	p.Parent = part
end
stall("Buy popcorn")
stall("Buy candy")
for _, d in folder:GetDescendants() do
	if d:IsA("ProximityPrompt") then
		d.Triggered:Connect(function(player) player:SetAttribute("Bought", d.ActionText) end)
	end
end
"""
ELSEWHERE = """local door = Instance.new("Part")
door.Parent = workspace
local p = Instance.new("ProximityPrompt")
p.ActionText = "Open the door"
p.Parent = door
"""
UNTRACED = """local built = require(script.Parent.Builder).build()
built.bellPrompt.Triggered:Connect(function(player) player:SetAttribute("Rang", true) end)
local horn = Instance.new("ProximityPrompt")
horn.ActionText = "Honk"
horn.Parent = workspace
"""


def test_a_generic_handler_reaches_only_its_container_or_its_own_file(tmp_path):
    res = interactions.audit(_game(tmp_path / "a", {"ServerScriptService/Stalls.server.luau": SCOPED_HANDLER,
                                                    "ServerScriptService/Door.server.luau": ELSEWHERE}))
    assert _found(res) == {("prompt_no_handler", "ServerScriptService/Door.server.luau", 3)}
    # the helper's prompt (one object for both stalls) is reached through the folder it iterates
    assert res["stats"]["generic"] == 1 and list(res["stats"]["generic_at"]) == ["ServerScriptService/Stalls.server.luau:15"]
    # a connection on a value the audit cannot follow covers its own file, not the door in another one
    res = interactions.audit(_game(tmp_path / "b", {"ServerScriptService/Bell.server.luau": UNTRACED,
                                                    "ServerScriptService/Door.server.luau": ELSEWHERE}))
    assert _found(res) == {("prompt_no_handler", "ServerScriptService/Door.server.luau", 3)}
    assert res["stats"]["generic"] == 1


CATCH_ALL = """local horn = Instance.new("ProximityPrompt")
horn.Parent = workspace
game:GetService("ProximityPromptService").PromptTriggered:Connect(function(prompt, player)
	print(prompt, player)
end)
"""


def test_a_catch_all_prompt_triggered_handler_is_generic_not_a_match(tmp_path):
    res = interactions.audit(_game(tmp_path, {"ServerScriptService/Log.server.luau": CATCH_ALL}))
    assert res["findings"] == [] and res["stats"]["generic"] == 1 and res["stats"]["handled"] == 0
    assert "only by a generic handler (Log.server.luau:3)" in interactions.summary(res)


SUPPRESSING = """local remotes = game.ReplicatedStorage:WaitForChild("Remotes")
local function listen(r)
	r.OnServerEvent:Connect(function() end)
end
listen(remotes:FindFirstChild(_G.which))
"""


def test_a_listener_it_cannot_name_is_reported_as_suppressing_the_remote_checks(tmp_path):
    files = {"ReplicatedStorage/Config.luau": CONFIG, "ServerScriptService/Net.server.luau": NET,
             "StarterPlayerScripts/Hud.client.luau": CLIENT, "ServerScriptService/Any.server.luau": SUPPRESSING}
    res = interactions.audit(_game(tmp_path, files))
    assert "remote_no_listener" not in {x["kind"] for x in res["findings"]}
    sup = res["stats"]["suppressed"]
    assert {"at": "ServerScriptService/Any.server.luau:3", "site": "OnServerEvent", "off": "remote_no_listener",
            "for": "FireServer"} in sup
    assert "remote checks suppressed by Any.server.luau:3 (OnServerEvent)" in interactions.summary(res)
    assert "[suppressed] ServerScriptService/Any.server.luau:3" in interactions.render(res)


ZERO = """local gui = Instance.new("ScreenGui")
gui.Parent = game.Players.LocalPlayer:WaitForChild("PlayerGui")
local modal = Instance.new("TextButton")
modal.Name = "FreeMouse"
modal.Modal = true
modal.Size = UDim2.fromOffset(0, 0)
modal.Parent = gui
"""


def test_a_zero_size_button_is_not_a_control(tmp_path):
    res = interactions.audit(_game(tmp_path, {"StarterPlayerScripts/Mouse.client.luau": ZERO}))
    assert res["findings"] == [] and res["stats"]["inert"] == 1 and res["stats"]["objects"] == 0


TWO_DEAD = """local bell = Instance.new("Part")
bell.Parent = workspace
local ring = Instance.new("ProximityPrompt")
ring.Name = "RingPrompt"
ring.ActionText = "Ring the bell"
ring.Parent = bell
local door = Instance.new("Part")
door.Parent = workspace
local open = Instance.new("ProximityPrompt")
open.Name = "OpenPrompt"
open.ActionText = "Open the door"
open.Parent = door
"""


def test_still_dead_matches_the_object_not_just_how_many_of_its_kind_are_left(tmp_path):
    game = _game(tmp_path, {"ServerScriptService/Lobby.server.luau": TWO_DEAD})
    an = {a["finding"]["object"]: a for a in interactions.as_anomalies(interactions.audit(game))}
    door, bell = an['ProximityPrompt "OpenPrompt" ("Open the door")'], an['ProximityPrompt "RingPrompt" ("Ring the bell")']
    assert door["finding"]["count"] == 1 and door["finding"]["in_file"] == 2
    path = game / "ServerScriptService/Lobby.server.luau"
    path.write_text(TWO_DEAD + 'ring.Triggered:Connect(function(p) p:SetAttribute("Rang", true) end)\n')
    assert "OpenPrompt" in interactions.still_dead(game, door["finding"])  # the bell was fixed, not the door
    assert interactions.still_dead(game, bell["finding"]) == ""
    # renaming the door's prompt is not a fix: its kind still has as many findings in the file
    path.write_text(TWO_DEAD.replace('"OpenPrompt"', '"DoorPrompt"'))
    assert "DoorPrompt" in interactions.still_dead(game, door["finding"])


def test_ids_and_refs_survive_an_edit_that_shifts_lines(tmp_path):
    game = _game(tmp_path, {"ServerScriptService/Lobby.server.luau": TWO_DEAD})
    first = interactions.audit(game)
    (game / "ServerScriptService/Lobby.server.luau").write_text("-- a comment\n\n" + TWO_DEAD)
    second = interactions.audit(game)
    assert [x["line"] for x in first["findings"]] != [x["line"] for x in second["findings"]]
    assert {x["id"] for x in first["findings"]} == {x["id"] for x in second["findings"]}
    assert [a["ref"] for a in interactions.as_anomalies(first)] == [a["ref"] for a in interactions.as_anomalies(second)]


PROGRESS = """local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Config"))
local folder = Instance.new("Folder")
folder.Name = "Remotes"
folder.Parent = RS
local remotes = {}
local names = { Toast = "Toast", ClaimGift = "ClaimGift" }
for k, v in Config.Remotes do
	names[k] = v
end
for k, nm in names do
	local r = Instance.new("RemoteEvent")
	r.Name = nm
	r.Parent = folder
	remotes[k] = r
end
remotes.ClaimGift.OnServerEvent:Connect(function(player) end)
"""
HUD_RESET = """local RS = game:GetService("ReplicatedStorage")
local Config = require(RS:WaitForChild("Config"))
local remotes = RS:WaitForChild("Remotes")
remotes:WaitForChild(Config.Remotes.Reset):FireServer()
remotes:WaitForChild("ClaimGift"):FireServer()
"""


def test_a_remote_kept_under_its_config_key_is_found_by_the_name_the_config_gives_it(tmp_path):
    """Forge's fix loop connected remotes.Reset (filled as remotes[k] = r, named Config.Remotes.Reset =
    "ResetToCheckpoint"); the audit read it as a remote named "Reset" and rejected a fix that works."""
    files = {"ReplicatedStorage/Config.luau": CONFIG, "ServerScriptService/Progress.server.luau": PROGRESS,
             "StarterPlayerScripts/Hud.client.luau": HUD_RESET}
    game = _game(tmp_path, files)
    res = interactions.audit(game)
    assert _found(res) == {("remote_no_listener", "StarterPlayerScripts/Hud.client.luau", 4)}
    finding = interactions.as_anomalies(res)[0]["finding"]
    (game / "ServerScriptService/Progress.server.luau").write_text(
        PROGRESS + "remotes.Reset.OnServerEvent:Connect(function(player) end)\n")
    assert interactions.still_dead(game, finding) == "" and interactions.audit(game)["ok"] is True
