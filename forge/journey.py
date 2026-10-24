"""Live end-to-end player journey (`forge journey <slug>`): one deterministic player (no LLM) plays the first
minute of the game through the ForgeTest harness, and every step is pass/fail with evidence.

  join      a real player joined and has a living character
  lobby     the player can see a world, not a baseplate: a census around them (parts, colours, tall scenery, sky),
            ground that is not the grey template Baseplate (nor mostly default-grey plastic), and in a game with the
            WorldKit kit a Workspace.Park with a landmark ride in view
  prompts   every ProximityPrompt within LOBBY_RADIUS of the spawn is used once, and each must have an observable
            effect: a GUI panel opens (client), an attribute or leaderstat changes, a part appears, or the
            character changes (a Costume_* model, an accessory, a teleport). No effect is a failure, so is a
            prompt the player can never use (another prompt on the same part and key shows instead)
  costume   (games with costumes) a costume prompt puts a costume on, directly or through the costume panel it
            opens (WEAR), and the costume shows: visible parts on the character's body (the head for a hat)
  stage1    (obbies) the player walks from the lobby to the course start and reaches checkpoint 1
  respawn   (obbies) the player dies on a hazard and respawns on their checkpoint
  layout    every on-screen GuiButton (outside the Core and Forge GUIs) is the top-most clickable thing at its
            centre: Studio asks PlayerGui:GetGuiObjectsAtPosition, headless computes the rectangles from Size /
            Position / AnchorPoint and orders them by DisplayOrder and ZIndex (a case it cannot compute is unknown)
  buttons   each uncovered button is pressed once and must do something: a panel opens or closes, a text changes,
            an attribute, leaderstat or telemetry counter moves, the character moves (one whose label counts down,
            GIFT 1:10, is on cooldown: not judged). A RESET / respawn button is pressed after stage1 with the player
            moved off their checkpoint, and must bring them back to it
  ride      (obbies with ride gates, ObbyKit v2) the player stands on a zone's last checkpoint (kit fixture), uses
            the RidePrompt, and must arrive at the next zone's ObbyZoneStart with the Stage kept

An effect is what changed between the moment right before the trigger and EFFECT_WAIT after it, minus what
changes on its own (a QUIET window with no action first): walking onto a pad fires its Touched handler, so the
player stands still and settles before the before-picture is taken. After each prompt and press the journey
closes what it opened, as a player would (the panel's X / Close / Back button, the prompt again, walking away)
and waits for the opened GUI to leave the screen: a panel left open would hide the next prompt's effect. A panel
nothing closes fails its prompt ("cannot be closed"); a teleport is undone with a harness teleport.

Clicks: in a headless session a button is pressed by firing its events on the simulated client. In Studio a press
is a real mouse click, which is off unless clicks=True (`--clicks`): the costume panel's WEAR then goes through its
own request (CosmeticsRemotes.Request), a panel whose X needs a click stays open (later prompts that only reopen it
are unknown, not failures), and the buttons step is unknown (the layout step still runs on real layout).

Result: runs/<slug>/journey/<n>.json + latest.json + latest-<engine>.json = {ok, engine, game_hash, steps[{step,
ok, detail, evidence, secs, skipped?}], prompts[...], buttons[...], ts}. `forge done` reads for_done(): the fresh
latest record of each engine merged step by step (Studio's verdict where it has one, headless for the rest).
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import math
import os
import re
import time
from pathlib import Path
from typing import Any, Awaitable, Callable

from forge.studio import extract_json

LOBBY_RADIUS = 150.0     # studs around the spawn that count as the lobby
MAX_PROMPTS = 8
MAX_BUTTONS = 10
WALK_TIMEOUT = 20.0
SETTLE = 2.0             # after walking to a prompt: touch handlers on the way finish
QUIET = 2.0              # the ambient window: what changes with nobody acting
EFFECT_WAIT = 1.0        # between two looks for the effect after a trigger
EFFECT_LOOKS = 4         # looks after a trigger (EFFECT_WAIT apart) before it counts as no effect. One press only:
                         # every extra second watched is a chance for a coincidence (a lobby coin respawning under
                         # the player read as a dead prompt's effect in Studio)
CLOSE_LOOKS = 4          # looks (EFFECT_WAIT apart) for an opened panel to leave the screen after a close
BOOT_SECONDS = 15.0      # before the first prompt: a new player looks around while the client boots. The overnight
                         # HUD waited 10 s for a missing folder before it started the costume panel: a press before
                         # that got its Open event queued and the panel opened seconds late, and the booting HUD's own
                         # new buttons read as a prompt's effect
BOOT_POLL = 1.5          # client snapshots while waiting for the GUI to settle (each call advances a headless clock)
COURSE_WALK = 45.0       # walking from the lobby to the course start
RESPAWN_WAIT = 10.0      # a respawn (RESET kills the character, Players.RespawnTime is 5 s)
RIDE_WAIT = 8.0          # a ride gate's teleport to the next zone
POLL = 0.4
MOVED = 8.0              # studs: the trigger moved the player (a ride, a teleporter)
AT_CHECKPOINT = 15.0     # studs from a checkpoint that count as standing on it (respawn, RESET)
AWAY_MIN = 25.0          # studs the player is moved off the checkpoint before RESET
ZONE_START_NEAR = 12.0   # studs from the next zone's start pad that count as arrived after a ride
CENSUS_RADIUS = 200.0
CENSUS_PARTS, CENSUS_COLOURS, CENSUS_TALL = 40, 5, 5
GREY_GROUND_MAX = 0.25   # share of the square around the spawn that default-grey ground may show
LANDMARK_RADIUS = 600.0  # WorldKit parks put their rides 250-700 studs from the entrance spawn: a ride in view
COSTUME_NEAR = 3.0       # studs: every part of a worn costume is this close to the body (the head for a hat)
# place/Forge.rbxlx starts with this Baseplate (game/tools/make_place.py); a headless session has no place file, so
# the census adds it back unless the game's code touches it (WorldKit.buildPark destroys it)
TEMPLATE_BASEPLATE = {"name": "Baseplate", "size": [512.0, 4.0, 512.0], "pos": [0.0, -2.0, 0.0], "colour": "5b5b5b",
                      "material": "Plastic"}
ENGINES = ("studio", "headless")
COSTUME_RX = re.compile(r"costume|changing|wardrobe|outfit|dress|try on|cosmetic|skin", re.IGNORECASE)
WEAR_RX = re.compile(r"^\s*(wear|equip|try( it)? on|put on|select)\b", re.IGNORECASE)
FREE_RX = re.compile(r"^\s*(free|buy\s*0)\b", re.IGNORECASE)
BUY_RX = re.compile(r"^\s*buy\s*(\d+)", re.IGNORECASE)
NOT_WEAR_RX = re.compile(r"take off|unequip|remove|need|reward|equipped|wearing|owned", re.IGNORECASE)
CLOSE_X_RX = re.compile(r"^\s*(x|×|✕|✖|✖️|❌)\s*$", re.IGNORECASE)
CLOSE_TEXT_RX = re.compile(r"^\s*(close|back|exit|cancel|done|ok|okay|got it|continue)\s*[!.]?\s*$", re.IGNORECASE)
CLOSE_NAME_RX = re.compile(r"close|exit|back|cancel|dismiss", re.IGNORECASE)
RESET_RX = re.compile(r"\b(reset|respawn|unstuck|back to (the )?checkpoint)\b", re.IGNORECASE)
# a label that counts down (GIFT 1:10, Ready in 30s): pressed early, nothing is the expected answer
COOLDOWN_RX = re.compile(r"\b\d{1,2}:\d{2}\b|\bready in\b|\b\d+\s?s\b", re.IGNORECASE)

PROMPTS_LUAU = r"""-- forge journey: prompts
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local center, R = Vector3.new(__X__, __Y__, __Z__), __RADIUS__
local chars = {}
for _, p in Players:GetPlayers() do if p.Character then table.insert(chars, p.Character) end end
local bots = workspace:FindFirstChild("ForgeTestBots")
local function posOf(i)
	if i:IsA("BasePart") then return i.Position end
	if i:IsA("Attachment") then return i.WorldPosition end
	if i:IsA("Model") then local ok, cf = pcall(i.GetPivot, i) if ok then return cf.Position end end
	local p = i:FindFirstAncestorWhichIsA("BasePart")
	return p and p.Position or nil
end
local out = {}
for _, d in workspace:GetDescendants() do
	if d:IsA("ProximityPrompt") and d.Enabled and d.Parent then
		local skip = bots ~= nil and d:IsDescendantOf(bots)
		for _, c in chars do if d:IsDescendantOf(c) then skip = true end end
		local pos = not skip and posOf(d.Parent) or nil
		if pos and (pos - center).Magnitude <= R then
			local same = 0
			for _, s in d.Parent:GetChildren() do
				if s ~= d and s:IsA("ProximityPrompt") and s.Enabled and s.KeyboardKeyCode == d.KeyboardKeyCode then
					same += 1
				end
			end
			table.insert(out, { path = d:GetFullName(), name = d.Name, parent = d.Parent:GetFullName(),
				parentName = d.Parent.Name, action = d.ActionText, object = d.ObjectText, hold = d.HoldDuration,
				range = d.MaxActivationDistance, key = d.KeyboardKeyCode.Name, siblings = same, los = d.RequiresLineOfSight,
				pos = { pos.X, pos.Y, pos.Z }, dist = (pos - center).Magnitude })
		end
	end
end
table.sort(out, function(a, b) if math.abs(a.dist - b.dist) > 0.5 then return a.dist < b.dist end return a.path < b.path end)
return HttpService:JSONEncode(out)
"""

SERVER_SNAP_LUAU = r"""-- forge journey: server snapshot
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local p = Players:GetPlayerByUserId(__UID__)
local center, R = __CENTER__, __RADIUS__
local out = { attrs = {}, stats = {}, char = {}, costume = {}, costume_view = {}, parts = {} }
-- how a costume model sits on the character: parts that show, how far its parts are from the body and the head
local function view(m, c)
	local head = c:FindFirstChild("Head")
	local body = {}
	for _, bp in c:GetChildren() do
		if bp:IsA("BasePart") and bp.Name ~= "HumanoidRootPart" then table.insert(body, bp) end
	end
	local v = { parts = 0, visible = 0, far = 0, head_far = 0, effects = 0, body = #body, head = head ~= nil,
		slot = m:GetAttribute("Slot") }
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			v.parts += 1
			if d.Transparency < 0.9 then v.visible += 1 end
			local near = math.huge
			for _, bp in body do near = math.min(near, (bp.Position - d.Position).Magnitude) end
			if near < math.huge then v.far = math.max(v.far, near) end
			if head and head:IsA("BasePart") then v.head_far = math.max(v.head_far, (head.Position - d.Position).Magnitude) end
		elseif (d:IsA("Trail") or d:IsA("Beam") or d:IsA("ParticleEmitter")) and d.Enabled then
			v.effects += 1
		end
	end
	v.far = math.floor(v.far * 10 + 0.5) / 10
	v.head_far = math.floor(v.head_far * 10 + 0.5) / 10
	return v
end
if p then
	for k, v in p:GetAttributes() do out.attrs[k] = tostring(v) end
	local ls = p:FindFirstChild("leaderstats")
	if ls then for _, v in ls:GetChildren() do if v:IsA("ValueBase") then out.stats[v.Name] = tostring((v :: any).Value) end end end
	local c = p.Character
	if c then
		for k, v in c:GetAttributes() do out.attrs["character." .. k] = tostring(v) end
		for _, ch in c:GetChildren() do
			local key = ch.ClassName .. " " .. ch.Name
			out.char[key] = (out.char[key] or 0) + 1
			if ch:IsA("Model") and (string.sub(ch.Name, 1, 8) == "Costume_" or CollectionService:HasTag(ch, "Costume")) then
				out.costume[ch.Name] = tostring(ch:GetAttribute("Costume") or ch.Name)
				out.costume_view[ch.Name] = view(ch, c)
			elseif ch:IsA("Accessory") then
				out.costume["Accessory " .. ch.Name] = ch.Name
				out.costume_view["Accessory " .. ch.Name] = view(ch, c)
			end
		end
		local bc = c:FindFirstChildOfClass("BodyColors")
		if bc then out.attrs["character.BodyColors"] = bc.HeadColor3:ToHex() .. bc.TorsoColor3:ToHex() end
		local root = c:FindFirstChild("HumanoidRootPart")
		if root then out.pos = { root.Position.X, root.Position.Y, root.Position.Z } end
		local hum = c:FindFirstChildOfClass("Humanoid")
		if hum then out.health = hum.Health end
	end
end
if center then
	local chars = {}
	for _, pl in Players:GetPlayers() do if pl.Character then table.insert(chars, pl.Character) end end
	local bots = workspace:FindFirstChild("ForgeTestBots")
	local n = 0
	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") and not d:IsA("Terrain") and (d.Position - center).Magnitude <= R then
			local skip = bots ~= nil and d:IsDescendantOf(bots)
			for _, c in chars do if d:IsDescendantOf(c) then skip = true end end
			if not skip then
				local key = d:GetFullName()
				out.parts[key] = (out.parts[key] or 0) + 1
				n += 1
				if n >= 800 then break end
			end
		end
	end
end
return HttpService:JSONEncode(out)
"""

CLIENT_SNAP_LUAU = r"""-- forge journey: client snapshot
local HttpService = game:GetService("HttpService")
local lp = game:GetService("Players").LocalPlayer
local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
local CORE = { BubbleChat = true, Chat = true, Freecam = true, TouchGui = true, ControlGui = true,
	PlayerList = true, RbxCameraUI = true }
local out = { gui = {}, texts = {} }
local function shown(g)
	local cur = g
	while cur and cur ~= pg do
		if cur:IsA("GuiObject") and not cur.Visible then return false end
		if cur:IsA("LayerCollector") and not cur.Enabled then return false end
		cur = cur.Parent
	end
	return cur == pg
end
local function rel(g) -- same-named siblings get an index ("HUD.TextButton[2]"): one key per object
	local parts, cur = {}, g
	while cur and cur ~= pg do
		local name, parent = cur.Name, cur.Parent
		if parent then
			local n, idx = 0, 0
			for _, c in parent:GetChildren() do
				if c.Name == cur.Name then
					n += 1
					if c == cur then idx = n end
				end
			end
			if n > 1 then name ..= "[" .. idx .. "]" end
		end
		table.insert(parts, 1, name)
		cur = parent
	end
	return table.concat(parts, ".")
end
if pg then
	local n = 0
	for _, sg in pg:GetChildren() do
		if sg:IsA("LayerCollector") and sg.Enabled and not CORE[sg.Name] and not string.match(sg.Name, "^Forge") then
			for _, d in sg:GetDescendants() do
				if d:IsA("GuiObject") and shown(d) then
					n += 1
					if n > 1500 then break end
					local key = rel(d)
					out.gui[key] = d.ClassName
					if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" then
						out.texts[key] = string.sub(d.Text, 1, 60)
					end
				end
			end
		end
	end
end
return HttpService:JSONEncode(out)
"""

CENSUS_LUAU = r"""-- forge journey: census
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local CollectionService = game:GetService("CollectionService")
local center, R, LR = Vector3.new(__X__, __Y__, __Z__), __RADIUS__, __LANDMARK_RADIUS__
local chars = {}
for _, p in Players:GetPlayers() do if p.Character then table.insert(chars, p.Character) end end
local bots = workspace:FindFirstChild("ForgeTestBots")
local GREY = { [Color3.fromRGB(163, 162, 165):ToHex()] = true, [Color3.fromRGB(99, 95, 98):ToHex()] = true,
	[Color3.fromRGB(161, 165, 162):ToHex()] = true, [Color3.fromRGB(91, 91, 91):ToHex()] = true }
local out = { parts = 0, colours = 0, materials = 0, tall = 0, tall_names = {}, biggest = nil, sky = false,
	terrain = 0, ground = { grey = 0, other = 0, biggest = nil }, landmarks = {} }
local colours, materials, tallSeen = {}, {}, {}
local floorY = center.Y - 3
local bigArea, groundArea = 0, 0
for _, d in workspace:GetDescendants() do
	if d:IsA("BasePart") and not d:IsA("Terrain") and d.Transparency < 0.95 then
		local skip = bots ~= nil and d:IsDescendantOf(bots)
		for _, c in chars do if d:IsDescendantOf(c) then skip = true end end
		local off = d.Position - center
		if not skip and Vector3.new(off.X, 0, off.Z).Magnitude <= R then
			out.parts += 1
			colours[d.Color:ToHex()] = true
			materials[d.Material.Name] = true
			local top = d.Position.Y + d.Size.Y / 2
			if top >= floorY + 8 and math.max(d.Size.X, d.Size.Y, d.Size.Z) >= 2 then
				out.tall += 1
				local m = d:FindFirstAncestorOfClass("Model")
				local label = (m and m ~= workspace and m.Name) or d.Name
				if not tallSeen[label] and #out.tall_names < 8 then
					tallSeen[label] = true
					table.insert(out.tall_names, label)
				end
			end
			local area = d.Size.X * d.Size.Z
			if area > bigArea then
				bigArea = area
				out.biggest = { name = d.Name, size = { d.Size.X, d.Size.Y, d.Size.Z } }
			end
		end
		-- ground: a wide part whose top is the floor around the spawn, clipped to the square around it
		local top = d.Position.Y + d.Size.Y / 2
		if not skip and top <= floorY + 2 and top >= floorY - 40 and d.Size.X * d.Size.Z >= 64 then
			local x0, x1 = math.max(d.Position.X - d.Size.X / 2, center.X - R), math.min(d.Position.X + d.Size.X / 2, center.X + R)
			local z0, z1 = math.max(d.Position.Z - d.Size.Z / 2, center.Z - R), math.min(d.Position.Z + d.Size.Z / 2, center.Z + R)
			if x1 > x0 and z1 > z0 then
				local hex = d.Color:ToHex()
				local grey = d.Name == "Baseplate" or (GREY[hex] == true and (d.Material == Enum.Material.Plastic
					or d.Material == Enum.Material.SmoothPlastic))
				local clipped = (x1 - x0) * (z1 - z0)
				if grey then out.ground.grey += clipped else out.ground.other += clipped end
				if d.Size.X * d.Size.Z > groundArea then
					groundArea = d.Size.X * d.Size.Z
					out.ground.biggest = { name = d.Name, size = { d.Size.X, d.Size.Y, d.Size.Z }, colour = hex,
						material = d.Material.Name, grey = grey }
				end
			end
		end
	end
end
for _ in colours do out.colours += 1 end
for _ in materials do out.materials += 1 end
for _, i in game:GetService("Lighting"):GetChildren() do
	if i:IsA("Sky") or i:IsA("Atmosphere") then out.sky = true end
end
local okT, cells = pcall(function() return workspace.Terrain:CountCells() end)
if okT then out.terrain = cells end
-- the park (WorldKit): the kit installed, Workspace.Park built, landmark rides by their distance from the spawn
local kit = game:GetService("ReplicatedStorage"):FindFirstChild("Kit")
out.worldkit = kit ~= nil and kit:FindFirstChild("WorldKit") ~= nil
local park = workspace:FindFirstChild("Park")
out.park = park ~= nil
local seen = {}
local function landmark(m)
	if seen[m] or not m:IsA("Model") or not m:IsDescendantOf(workspace) then return end
	seen[m] = true
	local ok, cf, size = pcall(function() return m:GetBoundingBox() end)
	if not ok or not cf then return end
	local dx = math.max(math.abs(cf.Position.X - center.X) - size.X / 2, 0)
	local dz = math.max(math.abs(cf.Position.Z - center.Z) - size.Z / 2, 0)
	table.insert(out.landmarks, { name = m.Name, kind = m:GetAttribute("Landmark"), dist = math.floor(math.sqrt(dx * dx + dz * dz) + 0.5) })
end
for _, m in CollectionService:GetTagged("Landmark") do landmark(m) end
if park then for _, m in park:GetDescendants() do if m:IsA("Model") and m:GetAttribute("Landmark") ~= nil then landmark(m) end end end
table.sort(out.landmarks, function(a, b) return a.dist < b.dist end)
out.near_landmarks = 0
for _, l in out.landmarks do if l.dist <= LR then out.near_landmarks += 1 end end
while #out.landmarks > 6 do table.remove(out.landmarks) end
return HttpService:JSONEncode(out)
"""

# shared by the client-side button scripts: shown(), rel() with an index for same-named siblings (as ForgeTestAgent
# and the headless press address them: "HUD.TextButton[2]"), label()
GUI_HELPERS = r"""
local function shown(g)
	local cur = g
	while cur and cur ~= pg do
		if cur:IsA("GuiObject") and not cur.Visible then return false end
		if cur:IsA("LayerCollector") and not cur.Enabled then return false end
		cur = cur.Parent
	end
	return cur == pg
end
local function rel(g)
	local parts, cur = {}, g
	while cur and cur ~= pg do
		local name, parent = cur.Name, cur.Parent
		if parent then
			local n, idx = 0, 0
			for _, c in parent:GetChildren() do
				if c.Name == cur.Name then
					n += 1
					if c == cur then idx = n end
				end
			end
			if n > 1 then name ..= "[" .. idx .. "]" end
		end
		table.insert(parts, 1, name)
		cur = parent
	end
	return table.concat(parts, ".")
end
local function label(b)
	local t = if b:IsA("TextButton") then b.Text else ""
	if t == "" then
		for _, d in b:GetDescendants() do
			if (d:IsA("TextLabel") or d:IsA("TextButton")) and d.Text ~= "" and shown(d) then t = d.Text break end
		end
	end
	return string.sub((string.gsub(t, "%s+", " ")), 1, 60)
end
local function find(path) -- a rel() path back to its object ("Name[2]" is the second child of that name)
	local cur = pg
	for seg in string.gmatch(path, "[^%.]+") do
		if not cur then return nil end
		local name, idx = string.match(seg, "^(.-)%[(%d+)%]$")
		if name then
			local n, hit = 0, nil
			for _, c in cur:GetChildren() do
				if c.Name == name then
					n += 1
					if n == tonumber(idx) then hit = c break end
				end
			end
			cur = hit
		else
			cur = cur:FindFirstChild(seg)
		end
	end
	return cur
end
"""

PANEL_BUTTONS_LUAU = r"""-- forge journey: panel buttons
local HttpService = game:GetService("HttpService")
local lp = game:GetService("Players").LocalPlayer
local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
local roots = HttpService:JSONDecode(__ROOTS__)
""" + GUI_HELPERS + r"""
local out = {}
for _, r in roots do
	local root = pg and find(r)
	if root then
		local list = root:GetDescendants()
		table.insert(list, 1, root)
		for _, b in list do
			if b:IsA("GuiButton") and shown(b) then
				local costume, cur = nil, b
				while cur and cur ~= pg and costume == nil do
					costume = cur:GetAttribute("Costume")
					cur = cur.Parent
				end
				table.insert(out, { path = rel(b), text = label(b), name = b.Name, costume = costume })
			end
		end
	end
end
return HttpService:JSONEncode(out)
"""

BUTTONS_LUAU = r"""-- forge journey: buttons
local HttpService = game:GetService("HttpService")
local lp = game:GetService("Players").LocalPlayer
local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
local REAL = __REAL__
local VW, VH, INSET = 1280, 720, 36
local CORE = { BubbleChat = true, Chat = true, Freecam = true, TouchGui = true, ControlGui = true,
	PlayerList = true, RbxCameraUI = true }
local LAYOUTS = { UIListLayout = true, UIGridLayout = true, UITableLayout = true, UIPageLayout = true }
local out = { buttons = {}, layout = if REAL then "real" else "computed" }
if not pg then return HttpService:JSONEncode(out) end
""" + GUI_HELPERS + r"""
local function num(v, d) return if type(v) == "number" then v else d end
local function interactable(g)
	local ok, v = pcall(function() return (g :: any).Interactable end)
	return not ok or v ~= false
end
local function sinks(g) -- takes the click: a button, or an Active object
	return g:IsA("GuiObject") and (g:IsA("GuiButton") or g.Active == true) and interactable(g) and shown(g)
end
local function screenOf(g) return g:FindFirstAncestorWhichIsA("LayerCollector") end
local function order(sg) return if sg and sg:IsA("ScreenGui") then num(sg.DisplayOrder, 0) else 0 end
-- computed layout (headless has no layout engine): nil when a layout object, a constraint, a scroll or a scale
-- decides where it ends up
local rects = {}
local function rect(g)
	local got = rects[g]
	if got ~= nil then return got or nil end
	local r = false
	if g:IsA("ScreenGui") then
		local top = if g.IgnoreGuiInset then 0 else INSET
		r = { 0, top, VW, VH - top }
	elseif g:IsA("GuiObject") and g.Parent then
		local parent = g.Parent
		local p = rect(parent)
		local free = p ~= nil and num(g.Rotation, 0) == 0 and not parent:IsA("ScrollingFrame")
		local auto = g.AutomaticSize
		if auto ~= nil and auto ~= Enum.AutomaticSize.None then free = false end
		for _, s in parent:GetChildren() do
			if LAYOUTS[s.ClassName] or (s.ClassName == "UIScale" and num(s.Scale, 1) ~= 1) then free = false end
		end
		for _, s in g:GetChildren() do
			if s.ClassName == "UIAspectRatioConstraint" or (s.ClassName == "UIScale" and num(s.Scale, 1) ~= 1) then free = false end
		end
		if free then
			local px, py, pw, ph = p[1], p[2], p[3], p[4]
			local pad = parent:FindFirstChildOfClass("UIPadding")
			if pad then
				local function u(v, size) return if typeof(v) == "UDim" then v.Scale * size + v.Offset else 0 end
				local l, rr, t, b = u(pad.PaddingLeft, pw), u(pad.PaddingRight, pw), u(pad.PaddingTop, ph), u(pad.PaddingBottom, ph)
				px, py, pw, ph = px + l, py + t, pw - l - rr, ph - t - b
			end
			local size, pos, anchor = g.Size, g.Position, g.AnchorPoint
			local sx = if g.SizeConstraint == Enum.SizeConstraint.RelativeYY then ph else pw
			local sy = if g.SizeConstraint == Enum.SizeConstraint.RelativeXX then pw else ph
			local w, h = size.X.Scale * sx + size.X.Offset, size.Y.Scale * sy + size.Y.Offset
			local lim = g:FindFirstChildOfClass("UISizeConstraint")
			if lim and typeof(lim.MinSize) == "Vector2" and typeof(lim.MaxSize) == "Vector2" then
				w = math.max(math.min(w, lim.MaxSize.X), lim.MinSize.X)
				h = math.max(math.min(h, lim.MaxSize.Y), lim.MinSize.Y)
			end
			local ax = if typeof(anchor) == "Vector2" then anchor.X else 0
			local ay = if typeof(anchor) == "Vector2" then anchor.Y else 0
			r = { px + pos.X.Scale * pw + pos.X.Offset - ax * w, py + pos.Y.Scale * ph + pos.Y.Offset - ay * h, w, h }
		end
	end
	rects[g] = r
	return r or nil
end
-- does c draw above a? nil when it cannot tell (two ScreenGuis with the same DisplayOrder, equal ZIndex)
local function above(c, a)
	local sc, sa = screenOf(c), screenOf(a)
	if sc ~= sa then
		local oc, oa = order(sc), order(sa)
		if oc ~= oa then return oc > oa end
		return nil
	end
	if a:IsDescendantOf(c) then return false end
	if c:IsDescendantOf(a) then return true end
	if sc and sc:IsA("ScreenGui") and sc.ZIndexBehavior == Enum.ZIndexBehavior.Global then
		if c.ZIndex ~= a.ZIndex then return c.ZIndex > a.ZIndex end
		return nil
	end
	local x, cc = c, nil -- Sibling: the two ancestors right under the common ancestor decide
	while x and not a:IsDescendantOf(x) do cc = x x = x.Parent end
	local ca = a
	while ca and ca.Parent ~= x do ca = ca.Parent end
	if not (x and cc and ca and cc:IsA("GuiObject") and ca:IsA("GuiObject")) then return nil end
	if cc.ZIndex ~= ca.ZIndex then return cc.ZIndex > ca.ZIndex end
	return nil
end
local function who(g)
	return { path = rel(g), text = label(g), class = g.ClassName }
end
local vw, vh = VW, VH
local cam = workspace.CurrentCamera
if REAL and cam then vw, vh = cam.ViewportSize.X, cam.ViewportSize.Y end
if REAL and (vw < 50 or vh < 50) then -- a minimized Studio window renders nothing: no real layout to read
	REAL, vw, vh = false, VW, VH
	out.layout = "computed (the Studio window is not rendering)"
end
local all = {}
for _, sg in pg:GetChildren() do
	if sg:IsA("LayerCollector") and sg.Enabled and not CORE[sg.Name] and not string.match(sg.Name, "^Forge") then
		for _, d in sg:GetDescendants() do
			if d:IsA("GuiObject") and shown(d) then table.insert(all, d) end
		end
	end
end
for _, b in all do
	if b:IsA("GuiButton") and interactable(b) and #out.buttons < 40 then
		local sg = screenOf(b)
		local info = { path = rel(b), text = label(b), name = b.Name, class = b.ClassName, gui = sg and sg.Name,
			order = order(sg) }
		local keep = true
		local ok, err = pcall(function()
			if REAL then
				local size = b.AbsoluteSize
				local c = b.AbsolutePosition + size / 2
				if size.X <= 1 or size.Y <= 1 or c.X < 0 or c.Y < -INSET or c.X > vw or c.Y > vh then keep = false return end
				info.x, info.y, info.w, info.h, info.layout = math.floor(c.X), math.floor(c.Y), math.floor(size.X), math.floor(size.Y), "real"
				local seen = false
				for _, hit in pg:GetGuiObjectsAtPosition(c.X, c.Y) do
					if hit == b or hit:IsDescendantOf(b) then seen = true break end
					if sinks(hit) and not b:IsDescendantOf(hit) then info.covered_by = who(hit) break end
				end
				if not seen and not info.covered_by then info.layout = "unknown" end
			else
				local r = rect(b)
				if not r then info.layout = "unknown" return end
				local cx, cy = r[1] + r[3] / 2, r[2] + r[4] / 2
				if r[3] <= 1 or r[4] <= 1 or cx < 0 or cy < 0 or cx > vw or cy > vh then keep = false return end
				info.x, info.y, info.w, info.h, info.layout = math.floor(cx), math.floor(cy), math.floor(r[3]), math.floor(r[4]), "computed"
				for _, o in all do
					if o ~= b and not o:IsDescendantOf(b) and not b:IsDescendantOf(o) and sinks(o) then
						local q = rect(o)
						if q and cx >= q[1] and cx <= q[1] + q[3] and cy >= q[2] and cy <= q[2] + q[4] and above(o, b) == true then
							info.covered_by = who(o)
							break
						end
					end
				end
			end
		end)
		if not ok then info.layout, info.error = "unknown", tostring(err) end
		if keep then table.insert(out.buttons, info) end
	end
end
table.sort(out.buttons, function(a, b)
	if a.order ~= b.order then return a.order > b.order end
	if math.abs((a.y or 0) - (b.y or 0)) > 4 then return (a.y or 0) < (b.y or 0) end
	return (a.x or 0) < (b.x or 0)
end)
return HttpService:JSONEncode(out)
"""

HIDE_LUAU = r"""-- forge journey: hide panels
local HttpService = game:GetService("HttpService")
local lp = game:GetService("Players").LocalPlayer
local pg = lp and lp:FindFirstChildOfClass("PlayerGui")
local roots, visible = HttpService:JSONDecode(__ROOTS__), __VISIBLE__
""" + GUI_HELPERS + r"""
local n = 0
for _, r in roots do
	local g = pg and find(r)
	if g and g:IsA("GuiObject") then g.Visible = visible n += 1 end
end
return HttpService:JSONEncode({ n = n })
"""

COSTUME_REQUEST_LUAU = r"""-- forge journey: costume request
local HttpService = game:GetService("HttpService")
local remotes = game:GetService("ReplicatedStorage"):FindFirstChild("CosmeticsRemotes")
local req = remotes and remotes:FindFirstChild("Request")
if not req then return HttpService:JSONEncode({ ok = false, err = "no ReplicatedStorage.CosmeticsRemotes.Request" }) end
local ok, res = pcall(function() return req:InvokeServer(__ACTION__, __ID__) end)
if not ok then return HttpService:JSONEncode({ ok = false, err = tostring(res) }) end
return HttpService:JSONEncode({ ok = type(res) == "table" and res.ok == true, err = type(res) == "table" and res.err or nil })
"""

RIDES_LUAU = r"""-- forge journey: ride gates
local HttpService = game:GetService("HttpService")
local CollectionService = game:GetService("CollectionService")
local starts = {}
for _, s in CollectionService:GetTagged("ObbyZoneStart") do
	local z = s:GetAttribute("Zone")
	if z ~= nil and s:IsA("BasePart") and s:IsDescendantOf(workspace) then starts[z] = s end
end
local out = {}
for _, g in CollectionService:GetTagged("RideGate") do
	if g:IsDescendantOf(workspace) then
		local prompt = g:FindFirstChild("RidePrompt", true)
		local nxt = g:GetAttribute("NextZone")
		local s = nxt ~= nil and starts[nxt] or nil
		table.insert(out, { path = g:GetFullName(), prompt = prompt and prompt:GetFullName() or nil,
			action = prompt and prompt.ActionText or nil, enabled = prompt ~= nil and prompt.Enabled,
			zone = g:GetAttribute("Zone"), stage = g:GetAttribute("Stage"), next = nxt,
			next_name = g:GetAttribute("NextZoneName"), start_path = s and s:GetFullName() or nil,
			start = s and { s.Position.X, s.Position.Y + s.Size.Y / 2, s.Position.Z } or nil })
	end
end
table.sort(out, function(a, b) return (tonumber(a.zone) or 1e9) < (tonumber(b.zone) or 1e9) end)
return HttpService:JSONEncode(out)
"""


def _lua_str(s: Any) -> str:
    return json.dumps(str(s))


def _num(v: Any) -> float | None:
    try:
        return float(v)
    except (TypeError, ValueError):
        return None


def _clip(v: Any, n: int = 300) -> str:
    s = " ".join(str(v).split())
    return s if len(s) <= n else s[: n - 3] + "..."


def _tail(path: Any, parts: int = 3) -> str:
    return ".".join(str(path or "?").split(".")[-parts:])


def _xyz(v: Any) -> str:
    if isinstance(v, (list, tuple)) and len(v) == 3:
        return "[" + ", ".join(f"{float(x):.0f}" for x in v) + "]"
    return "?"


def _flat(a: Any, b: Any) -> float | None:
    if isinstance(a, (list, tuple)) and isinstance(b, (list, tuple)) and len(a) == len(b) == 3:
        return math.hypot(float(a[0]) - float(b[0]), float(a[2]) - float(b[2]))
    return None


def game_hash(game_dir: Path | str) -> str:
    """sha1 over the game's .luau files (tools/ excluded): a journey describes this version only."""
    root = Path(game_dir)
    h = hashlib.sha1()
    for p in sorted(root.rglob("*.luau")):
        rel = p.relative_to(root).as_posix()
        if rel.startswith("tools/"):
            continue
        h.update(rel.encode())
        h.update(hashlib.sha1(p.read_bytes()).digest())
    return h.hexdigest()[:16]


def _mentions(game_dir: Path, word: str) -> bool:
    """Does any game file (tools/ excluded) name `word`?"""
    for p in Path(game_dir).rglob("*.luau"):
        if not p.relative_to(game_dir).as_posix().startswith("tools/") and \
                word in p.read_text(encoding="utf-8", errors="replace"):
            return True
    return False


# ------------------------------------------------------------------------------------------- effects


def _changes(a: dict, b: dict) -> dict:
    out = {}
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out[k] = [a.get(k), b.get(k)]
    return out


def _parent(key: str) -> str:
    return key.rsplit(".", 1)[0] if "." in key else ""


def diff(s1: dict, s2: dict, ambient: dict | None = None) -> dict:
    """What changed from snapshot s1 to s2 ({server, client}), leaving out what `ambient` says changes alone."""
    amb = ambient or {}
    a_srv, b_srv = s1.get("server") or {}, s2.get("server") or {}
    a_cli, b_cli = s1.get("client") or {}, s2.get("client") or {}
    out: dict = {}
    skip = lambda group: set((amb.get(group) or {}) if isinstance(amb.get(group), dict) else amb.get(group) or [])  # noqa: E731
    ga, gb = a_cli.get("gui") or {}, b_cli.get("gui") or {}
    new = [k for k in gb if k not in ga and k not in skip("gui_new")]
    gone = [k for k in ga if k not in gb and k not in skip("gui_gone")]
    new_set = set(new)
    panels = sorted(k for k in new if _parent(k) not in new_set)
    if panels:
        out["gui_new"] = new
        out["panels"] = [{"path": k, "size": sum(1 for x in new if x == k or x.startswith(k + "."))} for k in panels]
    if gone:
        out["gui_gone"] = gone
    texts = {k: v for k, v in _changes(a_cli.get("texts") or {}, b_cli.get("texts") or {}).items()
             if k not in skip("texts") and k not in new_set and k in gb}
    if texts:
        out["texts"] = texts
    for key in ("attrs", "stats", "costume"):
        ch = {k: v for k, v in _changes(a_srv.get(key) or {}, b_srv.get(key) or {}).items() if k not in skip(key)}
        if ch:
            out[key] = ch
    ca, cb = a_srv.get("char") or {}, b_srv.get("char") or {}
    added = sorted(k for k in cb if cb[k] > ca.get(k, 0) and k not in skip("char"))
    removed = sorted(k for k in ca if ca[k] > cb.get(k, 0) and k not in skip("char"))
    if added or removed:
        out["character"] = {"added": added, "removed": removed}
    pa, pb = a_srv.get("parts") or {}, b_srv.get("parts") or {}
    parts = sorted(k for k in pb if pb[k] > pa.get(k, 0) and k not in skip("parts"))
    if parts:
        out["parts"] = parts
    p1, p2 = a_srv.get("pos"), b_srv.get("pos")
    if isinstance(p1, list) and isinstance(p2, list) and len(p1) == len(p2) == 3:
        d = math.dist(p1, p2)
        if d >= MOVED and not amb.get("moved"):
            out["moved"] = round(d, 1)
    return out


def ambient_of(s0: dict, s1: dict) -> dict:
    """Keys that changed with nobody acting, in the groups diff() filters."""
    d = diff(s0, s1)
    return {"gui_new": d.get("gui_new") or [], "gui_gone": d.get("gui_gone") or [], "texts": list(d.get("texts") or {}),
            "attrs": list(d.get("attrs") or {}), "stats": list(d.get("stats") or {}),
            "costume": list(d.get("costume") or {}), "char": (d.get("character") or {}).get("added", [])
            + (d.get("character") or {}).get("removed", []), "parts": d.get("parts") or [],
            "moved": bool(d.get("moved"))}


# what counts as the prompt doing something; a GUI object that disappears or a text that changes does not (toasts
# and hints expire on timers: the gate nudge of the overnight lobby vanished inside an effect window)
VISIBLE = ("panels", "attrs", "stats", "costume", "character", "parts", "moved")


def observable(eff: dict) -> bool:
    return any(eff.get(k) for k in VISIBLE)


def pressed(eff: dict, counters: dict | None = None) -> bool:
    """A button press did something: what a prompt counts, plus a text that changed (its own label, a toast), a GUI
    object that went away (a Close / Skip button) or a telemetry counter (the server handled it)."""
    return observable(eff) or bool(eff.get("texts") or eff.get("gui_gone") or counters)


def describe(eff: dict, counters: dict | None = None) -> str:
    """'opened Cosmetics.Dim (41 GUI objects); attribute AtChangingRoom 0->1' or 'nothing'."""
    out = []
    for p in eff.get("panels") or []:
        out.append(f"opened {p['path']} ({p['size']} GUI objects)")
    if eff.get("gui_gone"):
        out.append(f"closed {len(eff['gui_gone'])} GUI object(s)")
    for k, (a, b) in list((eff.get("texts") or {}).items())[:3]:
        out.append(f"HUD text {_tail(k, 2)} {a!r}->{b!r}")
    for key, word in (("attrs", "attribute"), ("stats", "leaderstat"), ("costume", "costume")):
        for k, (a, b) in list((eff.get(key) or {}).items())[:4]:
            out.append(f"{word} {k} {a}->{b}")
    ch = eff.get("character") or {}
    if ch.get("added"):
        out.append("character gained " + ", ".join(ch["added"][:4]))
    if ch.get("removed"):
        out.append("character lost " + ", ".join(ch["removed"][:4]))
    if eff.get("parts"):
        out.append(f"{len(eff['parts'])} new part(s) ({', '.join(_tail(p, 2) for p in eff['parts'][:3])})")
    if eff.get("moved"):
        out.append(f"the character moved {eff['moved']:g} studs")
    for k, (a, b) in list((counters or {}).items())[:4]:
        out.append(f"counter {k} {a}->{b}")
    return "; ".join(out) or "nothing"


def _counter_delta(c0: dict | None, c1: dict | None) -> dict:
    out = {}
    for k, v in (c1 or {}).items():
        old = (c0 or {}).get(k, 0)
        if _num(v) is not None and _num(old) is not None and _num(v) != _num(old):
            out[k] = [old, v]
    return out


def _costume_changed(eff: dict) -> bool:
    return bool(eff.get("costume")) or any(str(k).split(" ", 1)[-1].startswith("Costume_")
                                           for k in (eff.get("character") or {}).get("added") or [])


def _worn(changed: dict, srv: dict, before: dict) -> tuple[bool, list[str]]:
    """Does each costume put on show on the character? Visible parts within COSTUME_NEAR of the body (of the head
    for a head costume), or a trail / particle effect, or (a body paint) body colours that changed."""
    views = srv.get("costume_view") or {}
    painted = (before.get("attrs") or {}).get("character.BodyColors") != (srv.get("attrs") or {}).get("character.BodyColors")
    notes, ok = [], True
    for k, (old, new) in changed.items():
        if new is None:
            continue
        v = views.get(k) or {}
        what = f"{k} ({new}, was {old or 'nothing'})"
        head = str(v.get("slot") or "").lower() == "head" or k.lower().endswith("_head")
        if v.get("parts"):
            far = _num(v.get("head_far") if head and v.get("head") else v.get("far"))
            if not v.get("visible"):
                ok = False
                notes.append(f"{what} is on the character but none of its {v['parts']} parts show (all transparent)")
            elif not v.get("body"):
                notes.append(f"{what}: {v['visible']}/{v['parts']} parts show (no body parts to measure against)")
            elif far is None or far > COSTUME_NEAR:
                ok = False
                notes.append(f"{what} is on the character's model but a part of it is {far or 0:.1f} studs from the "
                             f"{'head' if head else 'body'}: it is not on the character")
            else:
                notes.append(f"{what}: {v['visible']}/{v['parts']} parts show, all within {far:.1f} studs of the "
                             f"{'head' if head else 'body'}")
        elif v.get("effects"):
            notes.append(f"{what}: {v['effects']} trail / particle effect(s)")
        elif painted:
            notes.append(f"{what}: the body colours changed")
        else:
            ok = False
            notes.append(f"{what} has no parts, no effect and the body colours did not change: nothing shows")
    return ok and bool(notes), notes


# ------------------------------------------------------------------------------------------- the run


class _Journey:
    def __init__(self, studio: Any, *, clicks: bool, log: Any, shots: Path | None = None):
        from mubit_tester.harness import Harness

        self.studio, self.log, self.shots = studio, log, shots
        self.headless = bool(getattr(studio, "headless", False))
        self.clicks = clicks or self.headless  # a press fires the button headless; in Studio it is a real click
        self.h = Harness(studio, timeout=30.0)
        self.steps: list[dict] = []
        self.prompts: list[dict] = []
        self.buttons: list[dict] = []
        self.uid: Any = None
        self.name = ""
        self.spawn: list | None = None
        self.costume: dict | None = None
        self.left_open: set[str] = set()  # GUI a trigger opened that the journey could not close (no clicks)
        self.joined = time.monotonic()
        game_dir = getattr(studio, "game_dir", None)
        self.game_dir = Path(game_dir) if game_dir else None

    # ---------------------------------------------------------------- helpers

    def step(self, step: str, ok: bool | None, detail: str, t0: float, evidence: Any = None, **extra: Any) -> dict:
        rec = {"step": step, "ok": ok, "detail": _clip(detail, 1200), "secs": round(time.monotonic() - t0, 1),
               **({"evidence": evidence} if evidence is not None else {}), **extra}
        self.steps.append(rec)
        self.log(f"[journey] {step}: {'PASS' if ok else 'FAIL' if ok is False else 'n/a' if extra.get('skipped') else '??'}"
                 f" - {_clip(detail, 240)}")
        return rec

    def skip(self, step: str, why: str) -> dict:
        return self.step(step, None, "n/a: " + why, time.monotonic(), skipped=True)

    async def shot(self, name: str) -> str | None:
        """A Studio screenshot of this moment (headless sessions have no renderer). A panel the journey could not
        close (Studio without --clicks) is hidden for the shot and shown again: the shot shows what the step did."""
        if self.shots is None or self.headless:
            return None
        opened = self.opened()
        if opened:
            await self._show(opened, False)
        try:
            got = await self.studio.screenshot(self.shots / f"{name}.png")
        except Exception:  # noqa: BLE001 - a screenshot is evidence, never a failure
            return None
        finally:
            if opened:
                await self._show(opened, True)
        return str(got) if got else None

    def opened(self) -> list[str]:
        """The roots of the GUI the journey left open."""
        return sorted(k for k in self.left_open if _parent(k) not in self.left_open)

    async def luau(self, code: str, dm: str = "Server", timeout: float = 45.0) -> Any:
        return extract_json(await self.studio.execute_luau(code, dm, timeout=timeout))

    async def act(self, action: str, /, **args: Any) -> dict:
        try:
            res = await self.h.act(self.uid, action, **args)
            return res if isinstance(res, dict) else {"done": False, "detail": _clip(res, 200)}
        except Exception as e:  # noqa: BLE001 - a failed action is evidence
            return {"done": False, "detail": f"error: {type(e).__name__}: {_clip(e, 200)}"}

    async def press(self, b: dict) -> dict:
        """Press one GUI button (its label is logged before the press: a toggle's label changes with it)."""
        self.log(f"[journey] press '{_label(b)}' ({_tail(b.get('path'), 3)})")
        return await self.act("press", path=b["path"])

    async def teleport(self, pos: list) -> bool:
        try:
            await self.h.call("teleport", userId=self.uid, pos=pos)
        except Exception:  # noqa: BLE001
            return False
        await self.stand_still()
        return True

    async def stand_still(self) -> None:
        """Stop a walk left over from an earlier action (obby_try's run leaves the humanoid walking to its last
        target): after a teleport the player would walk back, off the checkpoint or onto it."""
        me = await self.me() or {}
        if me.get("pos"):
            await self.act("walk_to", pos=me["pos"], timeout=2, arrive_radius=50)

    async def me(self) -> dict | None:
        try:
            rows = await self.h.players()
        except Exception:  # noqa: BLE001
            return None
        return next((p for p in rows or [] if isinstance(p, dict) and p.get("userId") == self.uid), None)

    async def alive(self, timeout: float) -> dict | None:
        end = time.monotonic() + timeout
        while True:
            me = await self.me()
            if me is not None and me.get("hasCharacter", True) and (_num(me.get("health")) or 0) > 0:
                return me
            if time.monotonic() >= end:
                return None
            await asyncio.sleep(POLL)

    async def counters(self) -> dict | None:
        try:
            got = await self.h.counters()
            return got if isinstance(got, dict) else None
        except Exception:  # noqa: BLE001
            return None

    async def snap(self, center: list | None, radius: float = 40.0) -> dict:
        c = "nil" if not center else f"Vector3.new({center[0]}, {center[1]}, {center[2]})"
        srv = SERVER_SNAP_LUAU.replace("__UID__", str(int(self.uid))).replace("__CENTER__", c) \
            .replace("__RADIUS__", f"{float(radius):g}")
        out: dict = {}
        try:
            out["server"] = await self.luau(srv, "Server") or {}
        except Exception as e:  # noqa: BLE001
            out["server"], out["server_error"] = {}, _clip(e, 200)
        try:
            out["client"] = await self.luau(CLIENT_SNAP_LUAU, "Client") or {}
        except Exception as e:  # noqa: BLE001
            out["client"], out["client_error"] = {}, _clip(e, 200)
        return out

    async def client_gui(self) -> dict | None:
        try:
            return (await self.luau(CLIENT_SNAP_LUAU, "Client") or {}).get("gui") or {}
        except Exception:  # noqa: BLE001
            return None

    async def panel_buttons(self, roots: list[str]) -> list[dict]:
        try:
            rows = await self.luau(PANEL_BUTTONS_LUAU.replace("__ROOTS__", _lua_str(json.dumps(roots))), "Client")
        except Exception:  # noqa: BLE001
            return []
        return [r for r in rows or [] if isinstance(r, dict) and r.get("path")]

    async def events_since(self, t: float | None) -> list[dict]:
        try:
            got = await self.h.events(since=t, kinds=["prompt_triggered"])
        except Exception:  # noqa: BLE001
            return []
        return [e for e in (got or {}).get("events") or [] if isinstance(e, dict)]

    async def server_now(self) -> float | None:
        try:
            got = await self.h.events(since=1e12)
        except Exception:  # noqa: BLE001
            return None
        return _num((got or {}).get("now"))

    async def watch(self, center: list | None, before: dict, amb: dict, c0: dict | None,
                    done: Callable[[dict, dict], bool] = lambda e, c: observable(e)) -> tuple[dict, dict, dict]:
        """Look for the trigger's effect EFFECT_LOOKS times, EFFECT_WAIT apart -> (effect, counters, last snapshot)."""
        eff: dict = {}
        counters: dict = {}
        after = before
        for _ in range(EFFECT_LOOKS):
            await asyncio.sleep(EFFECT_WAIT)
            after = await self.snap(center)
            eff, counters = diff(before, after, amb), _counter_delta(c0, await self.counters())
            if done(eff, counters):
                break
        return eff, counters, after

    # ---------------------------------------------------------------- closing what a trigger opened

    async def wait_gone(self, keys: set[str]) -> bool:
        for _ in range(CLOSE_LOOKS):
            await asyncio.sleep(EFFECT_WAIT)
            gui = await self.client_gui()
            if gui is not None and not keys & set(gui):
                return True
        return False

    async def close(self, eff: dict, *, again: Callable[[], Awaitable[dict]] | None = None,
                    away: list | None = None) -> dict:
        """Close the panel a trigger opened as a player would: its close button (X / Close / Back), the trigger
        again (a toggle), walking away. Waits until the opened GUI has left the screen, so the next before-picture
        is the pre-trigger screen. -> {closed: True | False (nothing closes it) | None (Studio without --clicks:
        its button needs a real click), how, detail?}"""
        panels = eff.get("panels") or []
        if not panels:
            return {"closed": True, "how": "nothing opened"}
        closers = _closers(await self.panel_buttons([p["path"] for p in panels]))
        # the panel is the root holding a close button, else the biggest new root: a small label the trigger also
        # added (a "you are in the changing room" tag) may stay, and is not what has to close
        roots = [p["path"] for p in panels if any(b["path"] == p["path"] or b["path"].startswith(p["path"] + ".")
                                                  for b in closers)] or \
            [max(panels, key=lambda p: p.get("size") or 0)["path"]]
        keys = {k for k in eff.get("gui_new") or [] if any(k == r or k.startswith(r + ".") for r in roots)}
        gui = await self.client_gui()
        if gui is not None and not keys & set(gui):
            return {"closed": True, "how": "it closed by itself"}
        tried: list[str] = []
        if closers and self.clicks:
            for b in closers[:2]:
                res = await self.press(b)
                tried.append(f"pressed '{_label(b)}'" + ("" if res.get("done") else f" ({_clip(res.get('detail'), 100)})"))
                if res.get("done") and await self.wait_gone(keys):
                    return {"closed": True, "how": f"pressed its '{_label(b)}' button ({_tail(b['path'], 2)})"}
        if await self.wait_gone(keys):  # a toast or a timed panel: using the trigger again would act twice
            return {"closed": True, "how": "it closed by itself"}
        if again is not None:
            res = await again()
            tried.append("used it again")
            if res.get("done") and await self.wait_gone(keys):
                return {"closed": True, "how": "used it again (it toggles)"}
        if away is not None:
            await self.act("walk_to", pos=away, timeout=WALK_TIMEOUT, arrive_radius=4)
            tried.append("walked away")
            if await self.wait_gone(keys):
                return {"closed": True, "how": "walking away closed it"}
        if closers and not self.clicks:
            gui = await self.client_gui() or {}
            self.left_open |= keys & set(gui)
            return {"closed": None, "how": f"left open: its '{_label(closers[0])}' button needs a real click "
                                           f"(Studio without --clicks)", "roots": roots}
        why = (f"{'; '.join(tried)} and it stayed open" if closers else
               "it has no close button (X / Close / Back)" + (f", and {', '.join(tried)} did not close it" if tried else ""))
        return {"closed": False, "how": "; ".join(tried) or "nothing to press",
                "detail": f"the panel it opened ({', '.join(roots)}) cannot be closed: {why}", "roots": roots}

    async def restore(self, eff: dict, *, again: Callable[[], Awaitable[dict]] | None, away: list | None,
                      back_to: list | None) -> dict:
        """Undo what a trigger did to the screen and the player before the next one: close its panel, and put a
        player it moved back where they stood (a harness teleport: a fixture, not a player action)."""
        out = await self.close(eff, again=again, away=away) if eff.get("panels") else {"closed": True,
                                                                                      "how": "nothing opened"}
        if eff.get("moved") and back_to and await self.teleport(back_to):
            out["moved_back"] = True
            await asyncio.sleep(SETTLE)
        return out

    # ---------------------------------------------------------------- steps

    async def join(self) -> bool:
        t0 = time.monotonic()
        try:
            await self.h.ensure_ready()
        except Exception as e:  # noqa: BLE001
            self.step("join", False, f"the ForgeTest harness did not answer: {_clip(e, 300)}", t0)
            return False
        end = time.monotonic() + 20
        real: list = []
        while time.monotonic() < end:
            try:
                rows = await self.h.players()
            except Exception:  # noqa: BLE001
                rows = []
            real = [p for p in rows or [] if isinstance(p, dict) and not p.get("bot") and p.get("userId") is not None]
            if real and real[0].get("hasCharacter", True) and (_num(real[0].get("health")) or 0) > 0 and real[0].get("pos"):
                break
            await asyncio.sleep(POLL)
        if not real:
            self.step("join", False, "no player joined the game in 20 s", t0)
            return False
        me = real[0]
        self.uid, self.name, self.spawn = me["userId"], str(me.get("name") or me["userId"]), me.get("pos")
        self.joined = time.monotonic()
        if not self.spawn:
            self.step("join", False, f"{self.name} joined but has no character after 20 s", t0, evidence=me)
            return False
        self.step("join", True, f"{self.name} ({self.uid}) joined and spawned at {_xyz(self.spawn)} with "
                  f"{me.get('health')} health", t0, evidence={"userId": self.uid, "pos": self.spawn})
        return True

    def _template(self, c: dict) -> dict:
        """A headless census has no place file: put the template Baseplate back unless the game's code names it."""
        if not self.headless or self.game_dir is None or _mentions(self.game_dir, "Baseplate"):
            return c
        t = TEMPLATE_BASEPLATE
        (sx, sy, sz), (px, py, pz) = t["size"], t["pos"]
        floor, top = float(self.spawn[1]) - 3, py + sy / 2
        if not floor - 40 <= top <= floor + 2:
            return c
        r = CENSUS_RADIUS
        cx, cz = float(self.spawn[0]), float(self.spawn[2])
        w = min(px + sx / 2, cx + r) - max(px - sx / 2, cx - r)
        d = min(pz + sz / 2, cz + r) - max(pz - sz / 2, cz - r)
        if w <= 0 or d <= 0:
            return c
        ground = dict(c.get("ground") or {})
        ground["grey"] = float(ground.get("grey") or 0) + w * d
        big = ground.get("biggest") or {}
        bsize = big.get("size") or [0, 0, 0]
        if sx * sz > float(bsize[0]) * float(bsize[2]):
            ground["biggest"] = {"name": t["name"], "size": t["size"], "colour": t["colour"], "material": t["material"],
                                 "grey": True, "template": True}
        return {**c, "ground": ground, "template": "the place's template Baseplate (headless has no place file; the "
                                                   "game's code never names it, so it is still there in Studio)"}

    async def lobby(self) -> None:
        t0 = time.monotonic()
        x, y, z = self.spawn
        code = CENSUS_LUAU.replace("__X__", f"{x}").replace("__Y__", f"{y}").replace("__Z__", f"{z}") \
            .replace("__RADIUS__", f"{CENSUS_RADIUS:g}").replace("__LANDMARK_RADIUS__", f"{LANDMARK_RADIUS:g}")
        try:
            c = self._template(await self.luau(code, "Server") or {})
        except Exception as e:  # noqa: BLE001
            self.step("lobby", False, f"census failed: {_clip(e, 200)}", t0)
            return
        problems = []
        if not (c.get("parts", 0) >= CENSUS_PARTS and c.get("colours", 0) >= CENSUS_COLOURS
                and c.get("tall", 0) >= CENSUS_TALL):
            problems.append(f"a bare world (needs >= {CENSUS_PARTS} parts, {CENSUS_COLOURS} colours and {CENSUS_TALL} "
                            "tall parts around the spawn)")
        ground = c.get("ground") or {}
        gb = ground.get("biggest") or {}
        gsize = "x".join(f"{float(v):.0f}" for v in gb.get("size") or [])
        square = (2 * CENSUS_RADIUS) ** 2
        share = max(0.0, float(ground.get("grey") or 0) - float(ground.get("other") or 0)) / square
        if gb.get("name") == "Baseplate":
            problems.append(f"the ground is the grey template Baseplate ({gsize}): the world is a baseplate")
        elif gb.get("grey"):
            problems.append(f"the biggest ground part is default-grey {gb.get('material')} ({gb.get('name')} {gsize})")
        if share > GREY_GROUND_MAX:
            problems.append(f"default-grey ground shows on about {share:.0%} of the {2 * CENSUS_RADIUS:g}-stud square "
                            f"around the spawn (at most {GREY_GROUND_MAX:.0%})")
        marks = c.get("landmarks") or []
        if c.get("worldkit"):
            if not c.get("park"):
                problems.append("the game has the WorldKit kit but no Workspace.Park: buildPark never ran")
            elif not c.get("near_landmarks"):
                problems.append(f"no WorldKit landmark ride within {LANDMARK_RADIUS:g} studs of the spawn"
                                + (f" (nearest: {marks[0]['name']} {marks[0]['dist']} studs)" if marks else ""))
        big = c.get("biggest") or {}
        size = "x".join(f"{float(v):.0f}" for v in big.get("size") or [])
        detail = (f"within {CENSUS_RADIUS:g} studs: {c.get('parts', 0)} parts, {c.get('colours', 0)} colours, "
                  f"{c.get('materials', 0)} materials, {c.get('tall', 0)} tall parts ({', '.join(c.get('tall_names') or []) or 'none'}); "
                  f"sky {'yes' if c.get('sky') else 'no'}; terrain cells {c.get('terrain', 0)}; biggest {big.get('name')} {size}; "
                  f"ground {gb.get('name') or 'none'} {gsize} ({'default grey' if gb.get('grey') else gb.get('material') or '-'}"
                  f"{', the template' if gb.get('template') else ''}), grey ground {share:.0%}")
        if c.get("worldkit") or c.get("park"):
            detail += (f"; park {'yes' if c.get('park') else 'no'}, {c.get('near_landmarks', 0)} landmark(s) within "
                       f"{LANDMARK_RADIUS:g} studs (" + ", ".join(f"{m['name']} {m['dist']}" for m in marks[:3]) + ")")
        if problems:
            detail = "the player does not see a world: " + "; ".join(problems) + ". Census: " + detail
        self.step("lobby", not problems, detail, t0, evidence=c, shot=await self.shot("lobby"))

    async def list_prompts(self) -> list[dict]:
        x, y, z = self.spawn
        code = PROMPTS_LUAU.replace("__X__", f"{x}").replace("__Y__", f"{y}").replace("__Z__", f"{z}") \
            .replace("__RADIUS__", f"{LOBBY_RADIUS:g}")
        rows = await self.luau(code, "Server")
        return [r for r in rows or [] if isinstance(r, dict) and r.get("path")]

    async def use_prompt(self, p: dict) -> dict:
        """Walk to the prompt, stand still, take the before-picture, trigger it, read what changed."""
        rec = {k: p.get(k) for k in ("path", "name", "action", "object", "parent", "siblings", "los")}
        rec["dist"] = round(_num(p.get("dist")) or 0, 1)
        if not await self.alive(RESPAWN_WAIT):
            rec.update(ok=False, detail="the player has no living character")
            return rec
        reach = max(2.0, min((_num(p.get("range")) or 10) - 2.5, 6.0))
        walk = await self.act("walk_to", path=p["parent"], timeout=WALK_TIMEOUT, arrive_radius=reach)
        await asyncio.sleep(SETTLE)
        center = p.get("pos")
        s0 = await self.snap(center)
        await asyncio.sleep(QUIET)
        s1 = await self.snap(center)
        amb = ambient_of(s0, s1)
        c1 = await self.counters()
        t_server = await self.server_now()
        res = await self.act("interact", path=p["path"])
        if not res.get("done"):  # not shown yet: close in once more, settle, and take a fresh before-picture
            await self.act("walk_to", path=p["parent"], timeout=8, arrive_radius=1.5)
            await asyncio.sleep(SETTLE)
            s1 = await self.snap(center)
            c1 = await self.counters()
            t_server = await self.server_now()
            res = await self.act("interact", path=p["path"])
        eff, counters, s2 = await self.watch(center, s1, amb, c1) if res.get("done") else ({}, {}, s1)
        seen = [e for e in await self.events_since(t_server) if (e.get("data") or {}).get("prompt") == p["path"]]
        rec.update(walk=_clip(walk.get("detail"), 160), triggered=bool(res.get("done")),
                   server_saw=bool(seen), effect=eff, counters=counters, before=s1, after=s2)
        label = f"'{p.get('action') or p.get('object') or p.get('name')}' at {_tail(p['path'], 3)}"
        still = self.left_open & set((s1.get("client") or {}).get("gui") or {})
        if not res.get("done"):
            why = _clip(res.get("detail"), 220)
            if p.get("siblings"):
                why += (f"; {p['siblings']} other prompt(s) on the same part use the same key, so Roblox shows only "
                        "one of them")
            elif p.get("los") and not self.headless:
                why += ("; Roblox never showed it: it has RequiresLineOfSight on and something between the camera "
                        "and its part blocks it (often the player standing on the pad)")
            rec.update(ok=False, detail=f"{label} could not be used: {why}")
        elif observable(eff):
            rec.update(ok=True, detail=f"{label}: {describe(eff, counters)}")
        elif still:
            rec.update(ok=None, detail=(f"{label} was triggered{' and the server saw it' if seen else ''}; unknown: a "
                                        f"panel an earlier prompt opened is still on screen ({', '.join(sorted(still)[:2])}"
                                        "), and a prompt that only opens it again shows no change. The journey cannot "
                                        "press its close button in Studio without --clicks: run it headless"))
        else:
            noise = {k: eff[k] for k in ("gui_gone", "texts") if eff.get(k)}
            only = f" (only telemetry moved: {describe({}, counters)})" if counters else ""
            only += f" (not counted: {describe(noise)})" if noise else ""
            rec.update(ok=False, detail=(f"{label} was triggered{' and the server saw it' if seen else ''}, but nothing "
                                         f"happened in {EFFECT_LOOKS * EFFECT_WAIT:g} s: no GUI panel opened, no "
                                         f"attribute or leaderstat changed, no part appeared, the character did not "
                                         f"change{only}"))
        return rec

    async def settle(self) -> None:
        """Until BOOT_SECONDS after the join and the client's GUI is the same in two looks in a row."""
        last = None
        while True:
            gui = await self.client_gui()
            if gui is None:
                return  # no client view: nothing to wait for
            if time.monotonic() - self.joined >= BOOT_SECONDS and gui == last:
                return
            if time.monotonic() - self.joined >= BOOT_SECONDS + 4 * BOOT_POLL:
                return  # a GUI that never stops changing (a timer): stop waiting
            last = gui
            await asyncio.sleep(BOOT_POLL)

    async def prompts_step(self) -> None:
        t0 = time.monotonic()
        await self.settle()
        try:
            found = await self.list_prompts()
        except Exception as e:  # noqa: BLE001
            self.step("prompts", False, f"could not list the prompts: {_clip(e, 200)}", t0)
            return
        if not found:
            self.step("prompts", None, f"n/a: no ProximityPrompt within {LOBBY_RADIUS:g} studs of the spawn", t0,
                      skipped=True)
            return
        for i, p in enumerate(found[:MAX_PROMPTS], 1):
            rec = await self.use_prompt(p)
            eff = rec.get("effect") or {}
            rec["shot"] = await self.shot(f"prompt-{i}")  # the effect on screen, before it is closed
            mine = False
            if rec.get("ok") and self.costume is None and _costumey(p):
                if _costume_changed(eff):
                    self.costume = self.worn(rec.get("before") or {}, rec.get("after") or {},
                                             f"{rec['detail'].split(':', 1)[0]} put it on by itself", time.monotonic())
                    mine = True
                elif eff.get("panels"):
                    self.costume = await self.wear(rec)
                    mine = True
            if rec.get("triggered"):
                rec["restore"] = r = await self.restore(
                    eff, again=lambda p=p: self.act("interact", path=p["path"]), away=self.spawn,
                    back_to=((rec.get("before") or {}).get("server") or {}).get("pos"))
                if r.get("closed") is False and rec.get("ok"):
                    rec["ok"] = False
                    rec["detail"] = f"{rec['detail']}; but {r.get('detail')}"
                elif r.get("closed") is True and eff.get("panels"):
                    rec["detail"] = f"{rec['detail']}; closed it: {r.get('how')}"
                elif r.get("closed") is None:
                    rec["detail"] = f"{rec['detail']}; {r.get('how')}"
            if mine and self.costume is not None:
                self.costume["shot"] = await self.shot("costume")  # the panel closed, or hidden for it
            rec.pop("after", None)
            rec.pop("before", None)
            self.prompts.append(rec)
        bad = [r for r in self.prompts if r.get("ok") is False]
        unknown = [r for r in self.prompts if r.get("ok") is None]
        lines = [("PASS " if r.get("ok") else "FAIL " if r.get("ok") is False else "?? ") + str(r.get("detail"))
                 for r in self.prompts]
        more = f"; {len(found) - MAX_PROMPTS} more not tried" if len(found) > MAX_PROMPTS else ""
        ok = False if bad else None if unknown else True
        self.step("prompts", ok, f"{sum(1 for r in self.prompts if r.get('ok'))}/{len(self.prompts)} prompts did "
                  f"something{more}: " + " | ".join(lines), t0,
                  evidence=[{k: r.get(k) for k in ("path", "action", "ok", "triggered", "server_saw", "effect",
                                                   "counters", "restore", "detail")} for r in self.prompts])

    def worn(self, before: dict, after: dict, how: str, t0: float, button: dict | None = None) -> dict:
        """The costume step's verdict once something was put on (by the prompt itself or the panel's WEAR)."""
        srv_b, srv_a = before.get("server") or {}, after.get("server") or {}
        was, now = srv_b.get("costume") or {}, srv_a.get("costume") or {}
        changed = {k: [was.get(k), v] for k, v in now.items() if was.get(k) != v}
        ok, notes = _worn(changed, srv_a, srv_b)
        detail = how + "; " + ("; ".join(notes) if notes else f"the character did not change (costume models: {now or 'none'})")
        return {"ok": ok, "detail": detail, "secs": round(time.monotonic() - t0, 1), "button": button,
                "costume_before": was, "costume_after": now,
                "view": {k: (srv_a.get("costume_view") or {}).get(k) for k in changed}}

    async def wear(self, rec: dict) -> dict:
        """The costume panel is open: wear a costume from it and check it shows on the character."""
        t0 = time.monotonic()
        roots = [x["path"] for x in (rec.get("effect") or {}).get("panels") or []]
        before = rec.get("after") or {}
        buttons = await self.panel_buttons(roots)
        pick = _pick_wear(buttons, (before.get("server") or {}).get("costume") or {},
                          (before.get("server") or {}).get("stats") or {})
        if pick is None:
            texts = ", ".join(sorted({str(b.get('text')) for b in buttons if b.get("text")})[:10]) or "none"
            return {"ok": False, "secs": round(time.monotonic() - t0, 1),
                    "detail": f"the panel opened ({', '.join(roots)}) but has no WEAR / BUY button to press "
                              f"(buttons: {texts})"}
        if self.clicks:
            res = await self.press(pick)
            how = f"pressed '{_label(pick)}' ({_tail(pick['path'], 3)})" + (
                "" if res.get("done") else f" but it did not fire: {_clip(res.get('detail'), 160)}")
        elif pick.get("costume"):
            action = "equip" if WEAR_RX.search(str(pick.get("text"))) else "buy"
            code = COSTUME_REQUEST_LUAU.replace("__ACTION__", _lua_str(action)).replace("__ID__", _lua_str(pick["costume"]))
            try:
                res = await self.luau(code, "Client") or {}
            except Exception as e:  # noqa: BLE001
                res = {"ok": False, "err": _clip(e, 200)}
            how = (f"sent the panel's own request for '{_label(pick)}' ({action} {pick['costume']} through "
                   f"CosmeticsRemotes.Request, what its button does; real clicks are off in Studio): "
                   f"{'ok' if res.get('ok') else 'refused: ' + str(res.get('err'))}")
        else:
            return {"ok": None, "secs": round(time.monotonic() - t0, 1),
                    "detail": f"unknown: '{_label(pick)}' needs a real click (run with --clicks or headless)"}
        was = (before.get("server") or {}).get("costume") or {}
        after: dict = {}
        for _ in range(EFFECT_LOOKS):  # the server dresses the character; it can take a moment to replicate
            await asyncio.sleep(EFFECT_WAIT)
            after = await self.snap(None)
            if ((after.get("server") or {}).get("costume") or {}) != was:
                break
        return self.worn(before, after, how, t0, button=pick)


    async def _show(self, roots: list[str], visible: bool) -> None:
        code = HIDE_LUAU.replace("__ROOTS__", _lua_str(json.dumps(roots))).replace("__VISIBLE__", "true" if visible else "false")
        try:
            await self.luau(code, "Client")
        except Exception:  # noqa: BLE001 - a screenshot aid
            pass

    async def has_costume_system(self) -> bool:
        code = ('return game:GetService("HttpService"):JSONEncode({kit = '
                'game:GetService("ReplicatedStorage"):FindFirstChild("CosmeticsRemotes") ~= nil})')
        try:
            got = await self.luau(code, "Server")
        except Exception:  # noqa: BLE001
            return False
        return isinstance(got, dict) and bool(got.get("kit"))

    async def costume_step(self) -> None:
        t0 = time.monotonic()
        tried = [r for r in self.prompts if _costumey(r)]
        has_kit = bool(tried) or await self.has_costume_system()
        if not tried and not has_kit:
            self.skip("costume", "the game has no costume prompt or costume system")
            return
        if not tried:
            self.step("costume", False, "the game has costumes (CosmeticsRemotes) but no costume prompt in the lobby: "
                      "a player has no place to try them on", t0)
            return
        if self.costume is None:
            lines = "; ".join(str(r.get("detail")) for r in tried)
            ev = [{k: r.get(k) for k in ("path", "action", "triggered", "server_saw", "effect")} for r in tried]
            if any(r.get("ok") is None for r in tried):
                self.step("costume", None, f"unknown: {lines}", t0, evidence=ev)
            else:
                self.step("costume", False, f"no costume prompt put a costume on or opened the costume panel: {lines}",
                          t0, evidence=ev)
            return
        c = self.costume
        self.step("costume", c.get("ok"), str(c.get("detail")), t0, evidence={k: c.get(k) for k in (
            "button", "costume_before", "costume_after", "view")}, shot=c.get("shot"))

    async def course_start(self) -> dict | None:
        for tag in ("ObbyStart", "Checkpoint"):
            try:
                rows = await self.h.query(tag=tag, attrs=["Stage"], limit=200)
            except Exception:  # noqa: BLE001
                rows = []
            rows = [r for r in rows or [] if isinstance(r, dict) and r.get("path")]
            if tag == "Checkpoint":
                rows = [r for r in rows if _num((r.get("attrs") or {}).get("Stage")) == 1]
            if rows:
                return rows[0]
        return None

    async def stage1(self) -> bool:
        t0 = time.monotonic()
        try:
            cps = await self.h.query(tag="Checkpoint", attrs=["Stage"], limit=5)
        except Exception:  # noqa: BLE001
            cps = []
        if not cps:
            self.skip("stage1", "no Checkpoint-tagged parts (not an obby)")
            return False
        start = await self.course_start()
        if not await self.alive(RESPAWN_WAIT):
            self.step("stage1", False, "the player has no living character", t0)
            return False
        walk = await self.act("walk_to", path=start["path"], timeout=COURSE_WALK, arrive_radius=4) if start else \
            {"done": False, "detail": "no course start (ObbyStart) found"}
        walked = bool(walk.get("done"))
        run = await self.act("obby_try", from_stage=0, attempts=2, timeout=20)
        me = await self.me() or {}
        stage = _num((me.get("attrs") or {}).get("Stage"))
        reached = bool(run.get("reached")) or (stage or 0) >= 1
        tries = [a for a in run.get("attempts") or [] if isinstance(a, dict)]
        last = tries[-1] if tries else {}
        where = (f"hazard {_tail(last.get('hazard'))}" if last.get("hazard") else
                 f"at {_xyz(last.get('at'))}" + (f", {last['dist']:.0f} studs short" if _num(last.get("dist")) else ""))
        detail = (f"walk from the lobby to the course start ({_tail((start or {}).get('path'))}): "
                  f"{'arrived' if walked else 'did NOT arrive'} ({_clip(walk.get('detail'), 140)}); "
                  f"run start -> checkpoint 1: {'reached' if reached else last.get('result') or 'not reached'}"
                  + ("" if reached else f" ({where})") + f"; Stage now {stage if stage is not None else '?'}")
        self.step("stage1", walked and reached, detail, t0, evidence={"walk": walk, "run": run},
                  shot=await self.shot("stage1"))
        return reached

    async def nearest_checkpoint(self) -> dict:
        try:
            return (((await self.h.observe(self.uid)) or {}).get("obby") or {}).get("nearest") or {}
        except Exception:  # noqa: BLE001
            return {}

    async def respawn(self) -> None:
        t0 = time.monotonic()
        before = await self.alive(RESPAWN_WAIT) or {}
        stage = int(_num((before.get("attrs") or {}).get("Stage")) or 0)
        try:
            rows = await self.h.query(tag="KillPart", near=self.uid, limit=1)
        except Exception:  # noqa: BLE001
            rows = []
        if not rows:
            self.skip("respawn", "no KillPart-tagged hazard")
            return
        kill = rows[0]
        try:
            await self.h.call("teleport", userId=self.uid, path=kill["path"])
        except Exception as e:  # noqa: BLE001
            self.step("respawn", False, f"could not put the player on {_tail(kill['path'])}: {_clip(e, 200)}", t0)
            return
        died, back = False, None
        end = time.monotonic() + RESPAWN_WAIT
        while time.monotonic() < end:
            await asyncio.sleep(POLL)
            me = await self.me()
            if me is None or not me.get("hasCharacter", True) or (_num(me.get("health")) or 0) <= 0:
                died = True
            elif died:
                await asyncio.sleep(1.0)
                back = await self.me() or me
                break
        where, home = "no respawn seen in 10 s", False
        if back is not None:
            near = await self.nearest_checkpoint()
            home = stage >= 1 and _on_checkpoint(near, stage)
            where = (f"respawned at checkpoint {stage} ({near.get('dist')} studs)" if home else
                     f"respawned at {_xyz(back.get('pos'))}, nearest checkpoint {near.get('stage')} "
                     f"({near.get('dist')} studs), expected checkpoint {stage}")
        died_text = "died" if died else "did NOT die"
        self.step("respawn", died and home, f"touched {_tail(kill['path'])}: {died_text}; {where}", t0)

    # ---------------------------------------------------------------- on-screen buttons

    async def list_buttons(self) -> dict:
        code = BUTTONS_LUAU.replace("__REAL__", "false" if self.headless else "true")
        got = await self.luau(code, "Client")
        return got if isinstance(got, dict) else {}

    async def layout_and_buttons(self) -> None:
        t0 = time.monotonic()
        # a panel the journey could not close (Studio without --clicks) is not the player's normal screen: hide it
        # while the buttons are listed and shot, and leave its own buttons out
        opened = self.opened()
        if opened:
            await self._show(opened, False)
        try:
            view = await self.list_buttons()
        except Exception as e:  # noqa: BLE001
            self.step("layout", None, f"unknown: could not list the on-screen buttons: {_clip(e, 200)}", t0)
            self.skip("buttons", "the buttons could not be listed")
            return
        finally:
            if opened:
                await self._show(opened, True)
        rows = [b for b in view.get("buttons") or [] if isinstance(b, dict) and b.get("path")
                and not any(b["path"] == k or b["path"].startswith(k + ".") for k in opened)]
        if not rows:
            self.skip("layout", "no on-screen button")
            self.skip("buttons", "no on-screen button")
            return
        shot = await self.shot("buttons")
        covered = [b for b in rows if b.get("covered_by")]
        unknown = [b for b in rows if b.get("layout") == "unknown"]
        lines = [f"'{_label(b)}' ({_tail(b['path'], 2)}) is covered by '{_label(b['covered_by'])}' "
                 f"({_tail(b['covered_by'].get('path'), 2)}, a {b['covered_by'].get('class')}): a click on it lands there"
                 for b in covered]
        how = view.get("layout") or "?"
        detail = (f"{len(rows) - len(covered)}/{len(rows)} on-screen buttons are on top where they are drawn ({how} "
                  f"layout{f'; {len(unknown)} could not be placed' if unknown else ''})")
        if opened:
            detail += f"; {', '.join(opened)} (left open, see prompts) hidden for this check"
        self.step("layout", not covered, detail + (": " + "; ".join(lines) if lines else ""), t0,
                  evidence={"layout": how, "buttons": [{k: b.get(k) for k in ("path", "text", "x", "y", "w", "h",
                                                                               "layout", "covered_by")} for b in rows]},
                  shot=shot)
        await self.buttons_step([b for b in rows if not b.get("covered_by")], covered)

    async def buttons_step(self, free: list[dict], covered: list[dict]) -> None:
        t0 = time.monotonic()
        if not free:
            self.skip("buttons", "every on-screen button is covered (see layout)")
            return
        me = await self.me() or {}
        stage = int(_num((me.get("attrs") or {}).get("Stage")) or 0)
        reset = next((b for b in free if RESET_RX.search(_label(b)) or RESET_RX.search(str(b.get("name") or ""))), None)
        results = []
        if reset is not None:
            results.append(await self.press_reset(reset, stage))
        for b in [x for x in free if x is not reset][:MAX_BUTTONS]:
            results.append(await self.press_button(b))
        self.buttons = results
        bad = [r for r in results if r.get("ok") is False]
        unknown = [r for r in results if r.get("ok") is None and not r.get("cooldown")]
        ok = False if bad else None if unknown else True
        lines = [("PASS " if r.get("ok") else "FAIL " if r.get("ok") is False else "?? ") + str(r.get("detail"))
                 for r in results if self.clicks or r.get("ok") is not None or r.get("cooldown")]
        if unknown and not self.clicks:
            lines.append("not pressed: " + ", ".join(f"'{r.get('text')}'" for r in unknown)
                         + " (a press is a real click, off in Studio without --clicks; the headless journey presses them)")
        left = len(free) - len(results)
        more = f"; {left} more not pressed" if left > 0 else ""
        skipped = f"; {len(covered)} covered button(s) not pressed (see layout)" if covered else ""
        self.step("buttons", ok, f"{sum(1 for r in results if r.get('ok'))}/{len(results)} buttons did something"
                  f"{more}{skipped}: " + " | ".join(lines), t0,
                  evidence=[{k: r.get(k) for k in ("path", "text", "ok", "effect", "counters", "restore", "detail")}
                            for r in results])

    async def press_button(self, b: dict) -> dict:
        """Press one button and read what changed (closing what it opened afterwards)."""
        label = f"'{_label(b)}' ({_tail(b['path'], 2)})"
        rec = {"path": b["path"], "text": _label(b)}
        if not self.clicks:
            rec.update(ok=None, detail=f"{label}: not pressed (a press is a real click, off in Studio without "
                                       "--clicks; the headless journey presses it)")
            return rec
        if not await self.alive(RESPAWN_WAIT):
            rec.update(ok=False, detail=f"{label}: the player has no living character")
            return rec
        s0 = await self.snap(None)
        await asyncio.sleep(QUIET)
        s1 = await self.snap(None)
        amb = ambient_of(s0, s1)
        c1 = await self.counters()
        res = await self.press(b)
        if not res.get("done"):
            rec.update(ok=False, detail=f"{label} could not be pressed: {_clip(res.get('detail'), 200)}")
            return rec
        eff, counters, _ = await self.watch(None, s1, amb, c1, done=pressed)
        rec.update(effect=eff, counters=counters)
        if pressed(eff, counters):
            rec.update(ok=True, detail=f"{label}: {describe(eff, counters)}")
        elif COOLDOWN_RX.search(_label(b)):
            rec.update(ok=None, cooldown=True, detail=f"{label}: nothing happened, and its label counts down: on "
                                                      "cooldown, not judged")
        else:
            rec.update(ok=False, detail=(f"{label} was pressed (its events fired), but nothing happened in "
                                         f"{EFFECT_LOOKS * EFFECT_WAIT:g} s: no panel opened or closed, no text "
                                         "changed, no attribute, leaderstat or counter moved, the player did not move"))
        if eff.get("panels") or eff.get("moved"):
            rec["restore"] = r = await self.restore(eff, again=lambda: self.press(b), away=None,
                                                    back_to=(s1.get("server") or {}).get("pos"))
            if r.get("closed") is False:
                rec.update(ok=False, detail=f"{rec['detail']}; but {r.get('detail')}")
            elif r.get("closed") is True and eff.get("panels"):
                rec["detail"] += f"; closed it: {r.get('how')}"
        return rec

    async def press_reset(self, b: dict, stage: int) -> dict:
        """RESET after stage1: the player stands somewhere else, presses it, and must be back on their checkpoint."""
        label = f"'{_label(b)}' ({_tail(b['path'], 2)})"
        try:
            cps = await self.h.query(tag="Checkpoint", attrs=["Stage"], limit=500)
        except Exception:  # noqa: BLE001
            cps = []
        cp = next((r for r in cps or [] if isinstance(r, dict) and _num((r.get("attrs") or {}).get("Stage")) == stage), None)
        if stage < 1 or cp is None or not cp.get("pos"):
            return await self.press_button(b)  # no checkpoint reached: an ordinary button
        rec = {"path": b["path"], "text": _label(b), "reset": True}
        if not self.clicks:
            rec.update(ok=None, detail=f"{label}: not pressed (a real click, off in Studio without --clicks)")
            return rec
        await self.alive(RESPAWN_WAIT)
        # off the checkpoint: back where the player joined (walking off a course in the sky means falling)
        if not await self.teleport(self.spawn):
            rec.update(ok=None, detail=f"{label}: unknown: could not move the player off checkpoint {stage}")
            return rec
        await asyncio.sleep(SETTLE)
        me = await self.me() or {}
        away = _flat(me.get("pos"), cp["pos"])
        if away is None or away < AWAY_MIN:
            rec.update(ok=None, detail=f"{label}: unknown: the lobby is only {away or 0:.0f} studs from checkpoint "
                                       f"{stage}, too close to tell a RESET from standing still")
            return rec
        t = time.monotonic()
        res = await self.press(b)
        if not res.get("done"):
            rec.update(ok=False, detail=f"{label} could not be pressed: {_clip(res.get('detail'), 200)}")
            return rec
        near, pos = {}, me.get("pos")
        end = time.monotonic() + RESPAWN_WAIT
        while time.monotonic() < end:
            await asyncio.sleep(POLL)
            now = await self.me() or {}
            if not now.get("hasCharacter", True) or (_num(now.get("health")) or 0) <= 0:
                continue  # RESET by respawning: wait for the new character
            pos = now.get("pos") or pos
            d = _flat(pos, cp["pos"])
            if d is not None and d <= AT_CHECKPOINT:
                near = await self.nearest_checkpoint()
                if near.get("stage") == stage:
                    break
        back = _on_checkpoint(near, stage)
        if back:
            rec.update(ok=True, detail=f"{label}: took the player from the lobby ({away:.0f} studs away) back to "
                                       f"checkpoint {stage} ({near.get('dist')} studs) in {time.monotonic() - t:.1f} s")
        else:
            last = await self.nearest_checkpoint()
            rec.update(ok=False, detail=(f"{label} was pressed {away:.0f} studs from checkpoint {stage}, but the player "
                                         f"was not brought back in {RESPAWN_WAIT:g} s: still at {_xyz(pos)}, nearest "
                                         f"checkpoint {last.get('stage')} ({last.get('dist')} studs)"))
        return rec

    # ---------------------------------------------------------------- ride gates (ObbyKit v2)

    async def ride(self) -> None:
        t0 = time.monotonic()
        try:
            gates = [g for g in await self.luau(RIDES_LUAU, "Server") or [] if isinstance(g, dict)]
        except Exception as e:  # noqa: BLE001
            self.step("ride", None, f"unknown: could not list the ride gates: {_clip(e, 200)}", t0)
            return
        if not gates:
            self.skip("ride", "no ride gate (RideGate-tagged, ObbyKit v2 zones with anchors)")
            return
        g = gates[0]
        name = g.get("next_name") or f"zone {g.get('next')}"
        where = f"the ride gate at the end of zone {g.get('zone')} (checkpoint {g.get('stage')})"
        if not g.get("prompt") or not g.get("enabled"):
            self.step("ride", False, f"{where} has no enabled RidePrompt: the player cannot ride to {name}", t0,
                      evidence=g)
            return
        if not g.get("start"):
            self.step("ride", False, f"{where} rides to zone {g.get('next')}, which has no ObbyZoneStart pad", t0,
                      evidence=g)
            return
        stage = int(_num(g.get("stage")) or 0)
        if not await self.alive(RESPAWN_WAIT):
            self.step("ride", False, "the player has no living character", t0)
            return
        await self.stand_still()
        tp = await self.act("teleport_stage", stage=stage)  # the kit's own fixture: Stage = that checkpoint's
        if tp.get("done") is False and "error" in str(tp.get("detail")):
            self.step("ride", None, f"unknown: could not stand the player on checkpoint {stage}: "
                      f"{_clip(tp.get('detail'), 200)}", t0, evidence=g)
            return
        await self.stand_still()  # no walking from here: one step onto the pad rides by touch, not by the prompt
        await asyncio.sleep(SETTLE)
        res = await self.act("interact", path=g["prompt"])
        if not res.get("done"):
            self.step("ride", False, f"{where}: '{g.get('action')}' could not be used from the checkpoint: "
                      f"{_clip(res.get('detail'), 200)}", t0, evidence=g)
            return
        me, d = {}, None
        end = time.monotonic() + RIDE_WAIT
        while time.monotonic() < end:
            await asyncio.sleep(POLL)
            me = await self.me() or {}
            d = _flat(me.get("pos"), g["start"])
            if d is not None and d <= ZONE_START_NEAR:
                break
        attrs = me.get("attrs") or {}
        kept = _num(attrs.get("Stage"))
        arrived = d is not None and d <= ZONE_START_NEAR
        ok = arrived and kept is not None and kept >= stage
        detail = (f"{where}: '{g.get('action')}' -> "
                  + (f"arrived at {name}'s start ({d:.0f} studs from {_tail(g.get('start_path'), 2)})" if arrived else
                     f"did NOT arrive at {name}'s start (still {d if d is None else round(d)} studs from "
                     f"{_tail(g.get('start_path'), 2)}, at {_xyz(me.get('pos'))})")
                  + f"; Stage {kept if kept is not None else '?'} (expected >= {stage})"
                  + (f"; LastRide {attrs.get('LastRide')}" if attrs.get("LastRide") is not None else ""))
        self.step("ride", ok, detail, t0, evidence={"gate": g, "player": {"pos": me.get("pos"), "attrs": attrs}},
                  shot=await self.shot("ride"))

    async def run(self) -> None:
        if not await self.join():
            return
        await self.lobby()
        await self.prompts_step()
        await self.costume_step()
        if await self.stage1():
            await self.respawn()
        elif any(s["step"] == "stage1" and not s.get("skipped") for s in self.steps):
            self.skip("respawn", "checkpoint 1 was not reached")
        else:
            self.skip("respawn", "not an obby")
        await self.layout_and_buttons()  # after stage1: a RESET has a checkpoint to bring the player back to
        await self.ride()


def _on_checkpoint(near: dict, stage: int) -> bool:
    """observe's nearest checkpoint is `stage`, within AT_CHECKPOINT studs (0 studs included)."""
    d = _num(near.get("dist"))
    return near.get("stage") == stage and d is not None and d <= AT_CHECKPOINT


def _label(b: dict | None) -> str:
    b = b or {}
    return str(b.get("text") or b.get("name") or _tail(b.get("path"), 1))


def _closers(buttons: list[dict]) -> list[dict]:
    """A panel's close buttons, best first: an X, then Close / Back / Cancel / Done / OK, then one named so."""
    def rank(b: dict) -> int | None:
        text, name = str(b.get("text") or ""), str(b.get("name") or "")
        if CLOSE_X_RX.match(text):
            return 0
        if CLOSE_TEXT_RX.match(text):
            return 1
        if not text and CLOSE_NAME_RX.search(name):
            return 2
        if CLOSE_NAME_RX.search(name) and len(text) <= 2:
            return 3
        return None
    ranked = [(rank(b), i, b) for i, b in enumerate(buttons or []) if isinstance(b, dict) and b.get("path")]
    return [b for r, _, b in sorted((x for x in ranked if x[0] is not None), key=lambda x: (x[0], x[1]))]


def _costumey(p: dict) -> bool:
    text = " ".join(str(p.get(k) or "") for k in ("action", "object", "name", "parentName", "parent"))
    return bool(COSTUME_RX.search(text))


def _pick_wear(buttons: list, wearing: dict, stats: dict) -> dict | None:
    """The button that puts something new on: WEAR / EQUIP first (not what is worn), then FREE / BUY 0, then an
    affordable BUY n."""
    worn = set(str(v) for v in (wearing or {}).values())
    balance = max([_num(v) or 0 for v in (stats or {}).values()] or [0])
    rows = [b for b in buttons or [] if isinstance(b, dict) and b.get("path") and not NOT_WEAR_RX.search(str(b.get("text")))]
    for test in (lambda b: WEAR_RX.search(str(b.get("text"))) and str(b.get("costume")) not in worn,
                 lambda b: FREE_RX.search(str(b.get("text"))),
                 lambda b: (m := BUY_RX.search(str(b.get("text")))) and float(m.group(1)) <= balance):
        hit = next((b for b in rows if test(b)), None)
        if hit:
            return hit
    return None


def overall(steps: list[dict]) -> bool | None:
    ran = [s for s in steps if not s.get("skipped")]
    if any(s.get("ok") is False for s in ran):
        return False
    if not ran or any(s.get("ok") is None for s in ran):
        return None
    return True


async def run_journey(studio: Any, *, clicks: bool = False, shots: Path | None = None, log: Any = print) -> dict:
    """Play the running game once as a new player. Never raises: a failure is a step.
    -> {ok, engine, clicks, player, steps, prompts, buttons, secs}"""
    t0 = time.monotonic()
    j = _Journey(studio, clicks=clicks, log=log, shots=shots)
    try:
        await j.run()
    except Exception as e:  # noqa: BLE001 - never fail the caller
        j.step("error", False, f"journey crashed: {type(e).__name__}: {_clip(e, 400)}", time.monotonic())
    return {"ok": overall(j.steps), "engine": "headless" if j.headless else "studio", "clicks": j.clicks,
            "player": j.name, "steps": j.steps, "prompts": j.prompts, "buttons": j.buttons,
            "secs": round(time.monotonic() - t0, 1)}


# ------------------------------------------------------------------------------------------- records


def journey_dir(run_dir: Path) -> Path:
    return Path(run_dir) / "journey"


def save(run_dir: Path, rec: dict, game_dir: Path | None = None) -> Path:
    """<n>.json, latest.json and latest-<engine>.json. Without game_dir the record has no game_hash: it reads as
    stale (`forge journey --no-sync` ran whatever Studio held)."""
    from forge.memory import now_iso

    d = journey_dir(run_dir)
    d.mkdir(parents=True, exist_ok=True)
    n = 1 + max([int(p.stem) for p in d.glob("*.json") if p.stem.isdigit()] or [0])
    rec = {**rec, "n": n, "ts": now_iso(), "game_hash": game_hash(game_dir) if game_dir else rec.get("game_hash")}
    text = json.dumps(rec, indent=1, default=str)
    (d / f"{n}.json").write_text(text, encoding="utf-8")
    (d / "latest.json").write_text(text, encoding="utf-8")
    if rec.get("engine") in ENGINES:
        (d / f"latest-{rec['engine']}.json").write_text(text, encoding="utf-8")
    return d / f"{n}.json"


def latest(run_dir: Path, engine: str | None = None) -> dict | None:
    name = f"latest-{engine}.json" if engine else "latest.json"
    try:
        rec = json.loads((journey_dir(run_dir) / name).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) else None


def fresh(rec: dict | None, game_dir: Path) -> bool:
    return bool(rec) and Path(game_dir).is_dir() and rec.get("game_hash") == game_hash(game_dir)


def merge(recs: list[dict]) -> dict:
    """Records of the same code from several engines, step by step: Studio's verdict where it has one (the real
    engine: layout, physics), else headless (it presses what Studio cannot without --clicks)."""
    rank = {e: i for i, e in enumerate(ENGINES)}
    recs = sorted(recs, key=lambda r: rank.get(str(r.get("engine")), 9))
    order: list[str] = []
    for r in recs:
        for s in r.get("steps") or []:
            if s.get("step") not in order:
                order.append(s["step"])
    steps = []
    for name in order:
        got = [(str(r.get("engine")), s) for r in recs for s in r.get("steps") or [] if s.get("step") == name]
        ran = [(e, s) for e, s in got if not s.get("skipped")]
        pick = next(((e, s) for e, s in ran if s.get("ok") is not None), ran[0] if ran else got[0])
        engines = {e: s.get("ok") for e, s in ran}
        steps.append({**pick[1], "detail": f"[{pick[0]}] {pick[1].get('detail')}", "engines": engines}
                     if len(recs) > 1 and ran else dict(pick[1]))
    return {"ok": overall(steps), "engine": "+".join(str(r.get("engine")) for r in recs), "steps": steps,
            "n": "+".join(str(r.get("n")) for r in recs), "ts": max(str(r.get("ts")) for r in recs),
            "game_hash": recs[0].get("game_hash")}


def for_done(run_dir: Path, game_dir: Path) -> dict | None:
    """What `forge done` judges: the fresh latest record of each engine, merged; else the latest record (stale or
    missing, and summary says so)."""
    recs = [r for r in (latest(run_dir, e) for e in ENGINES) if r and fresh(r, game_dir)]
    if not recs:
        return latest(run_dir)
    return recs[0] if len(recs) == 1 else merge(recs)


def summary(rec: dict | None, game_dir: Path | None = None) -> tuple[bool, str]:
    """(ok, detail) for `forge done`."""
    if not rec:
        return False, "no journey yet (forge journey <slug>)"
    if game_dir is not None and not fresh(rec, game_dir):
        why = "it ran on what Studio held (--no-sync)" if rec.get("game_hash") is None else "the game changed since"
        return False, f"stale: {why} (journey {rec.get('n')}, {rec.get('ts')}); run forge journey <slug>"
    steps = rec.get("steps") or []
    bad = [s for s in steps if s.get("ok") is False]
    unknown = [s for s in steps if s.get("ok") is None and not s.get("skipped")]
    ran = [s for s in steps if not s.get("skipped")]
    head = f"{sum(1 for s in ran if s.get('ok'))}/{len(ran)} steps ({rec.get('engine')}, journey {rec.get('n')})"
    if bad:
        return False, head + ": " + "; ".join(f"{s['step']} FAILED: {_clip(s.get('detail'), 160)}" for s in bad[:3])
    if unknown:
        return False, head + ": " + "; ".join(f"{s['step']} unknown: {_clip(s.get('detail'), 120)}" for s in unknown[:2])
    return bool(ran), head + (": " + ", ".join(s["step"] for s in ran) if ran else ": nothing ran")


def _letters(s: Any) -> str:
    return re.sub(r"[^a-z]", "", str(s or "").lower())


def _explained(rec: dict, step: str, findings: list[dict]) -> list[dict]:
    """The static findings that explain a failed step's failing items, one per item ([] when one is unexplained):
    a dead prompt by its action text, a dead button by its label (a button finding, or a remote it fires)."""
    usable = [x for x in findings or [] if not x.get("kit")]
    hits = []
    if step in ("prompts", "costume"):
        items = [p for p in rec.get("prompts") or [] if p.get("ok") is False
                 and (step == "prompts" or _costumey(p))]
        for p in items:
            hit = next((x for x in usable if x.get("kind") == "prompt_no_handler" and p.get("action")
                        and str(p["action"]) in str(x.get("object"))
                        and (p.get("name") in str(x.get("object")) or p.get("name") == "ProximityPrompt")), None)
            if hit is None:
                return []
            hits.append(hit)
    elif step == "buttons":
        items = [b for b in rec.get("buttons") or [] if b.get("ok") is False]
        for b in items:
            text = _letters(b.get("text"))
            hit = next((x for x in usable if len(text) >= 3 and x.get("kind") in (
                "button_no_handler", "remote_no_listener", "remote_no_answer") and text in _letters(x.get("object"))), None)
            if hit is None:
                return []
            hits.append(hit)
    return hits


def _items_for(rec: dict, finding: dict) -> list[dict]:
    """The journey items a static finding is about: the prompts with its action text (its own name first, else the
    unnamed ones), or the buttons whose label it names (a button finding, or the remote that button fires)."""
    obj, kind = str(finding.get("object") or ""), finding.get("kind")
    if kind == "prompt_no_handler":
        same = [p for p in rec.get("prompts") or [] if p.get("action") and str(p["action"]) in obj]
        named = [p for p in same if p.get("name") and f'"{p["name"]}"' in obj]
        return named or [p for p in same if p.get("name") == "ProximityPrompt"]
    if kind in ("button_no_handler", "remote_no_listener", "remote_no_answer"):
        return [b for b in rec.get("buttons") or [] if len(_letters(b.get("text"))) >= 3
                and _letters(b.get("text")) in _letters(obj)]
    return []


def still_failing(rec: dict, anomaly: dict, base: dict | None = None) -> str:
    """After a fix attempt, the journey of the fixed code (`rec`) judges it: '' when the anomaly's own journey
    evidence passes (its step, or the prompts / buttons a static finding names) and no step that passed in `base`
    fails now. Else why, in the journey's words, for the fixer's retry."""
    steps = {s["step"]: s for s in rec.get("steps") or []}
    lost = [steps[s["step"]] for s in (base or {}).get("steps") or []
            if s.get("ok") is True and (steps.get(s["step"]) or {}).get("ok") is False]
    if lost:
        return ("The live journey after your fix: step(s) that passed before now fail: "
                + "; ".join(f"{s['step']}: {_clip(s.get('detail'), 300)}" for s in lost))
    ref = str(anomaly.get("ref") or "")
    if ref.startswith("journey:"):
        name = ref.split(":", 1)[1]
        s = steps.get(name) or {}
        if s.get("ok") is not False:
            return ""
        if name in ("prompts", "buttons") and base:
            # item by item: every prompt / button the journey used before must not fail now; one the fix exposed
            # (a button no longer covered) is the next anomaly, not this one's veto
            was = {i.get("path") for i in base.get(name) or []}
            still = [i for i in rec.get(name) or [] if i.get("ok") is False and i.get("path") in was]
            return ("The live journey after your fix: " + "; ".join(_clip(i.get("detail"), 300) for i in still)
                    if still else "")
        return f"The live journey still fails step {name} after your fix: {_clip(s.get('detail'), 600)}"
    bad = [i for i in _items_for(rec, anomaly.get("finding") or {}) if i.get("ok") is False]
    if bad:
        return ("The static audit is clean now, but in the running game it still does nothing (live journey "
                f"{rec.get('n')}): " + "; ".join(_clip(i.get("detail"), 300) for i in bad))
    return ""


def as_anomalies(rec: dict | None, findings: list[dict] | None = None) -> list[dict]:
    """Failed steps in the auditor's anomaly shape (improve.run_cycle extra anomalies, autopilot). A failed step
    whose every failing item the static audit also flagged carries that finding (`static`, and its file as the fix
    path): the static anomaly is the one a fix is re-audited against."""
    if not rec:
        return []
    out = []
    for s in rec.get("steps") or []:
        if s.get("ok") is not False:
            continue
        a = {"kind": "journey", "system": "journey", "severity": "high",
             "title": f"[journey] {s['step']}: {_clip(s.get('detail'), 200)}"[:300],
             "observed": _clip(s.get("detail"), 900), "expected": EXPECT.get(s["step"], "the step passes"),
             "proof": f"live journey {rec.get('n')} ({rec.get('engine')}, {rec.get('ts')}): step {s['step']} failed: "
                      f"{_clip(s.get('detail'), 700)}", "ref": f"journey:{s['step']}"}
        hits = _explained(rec, s["step"], findings or [])
        if hits:
            a["path"], a["static"] = hits[0]["file"], hits[0].get("id")
        out.append(a)
    return out


def enabled() -> bool:
    """FORGE_JOURNEY=0 keeps the journey and the dead-interaction anomalies out of the fix loop and autopilot
    (tests default it off in conftest.py, like the smoke play); `forge done` always shows both parts."""
    return os.environ.get("FORGE_JOURNEY", "1") != "0"


async def refresh(harness: Any, game_dir: Path, run_dir: Path, *, force: bool = False,
                  log: Any = print) -> dict | None:
    """Run the journey when the latest one is missing or describes other code (or force), save it, and return the
    latest record. It runs on a fresh server, never on the harness's session as it is: headless a new session of
    game_dir, Studio a restarted playtest."""
    rec = latest(run_dir)
    if not force and fresh(rec, game_dir):
        return rec
    studio = harness.studio
    try:  # a new player in a new server: the session's own player has been playtesting, maybe far up the course
        if getattr(studio, "headless", False):
            from forge import headless as hl

            hs = hl.HeadlessStudio(game_dir, players=1, slug=getattr(studio, "slug", ""), kind="journey")
            try:
                got = await run_journey(hs, log=log)
            finally:
                await hs.stop()
        else:
            await studio.stop()
            await harness.ensure_ready()
            got = await run_journey(studio, log=log)
    except Exception as e:  # noqa: BLE001 - no session: keep what we have
        log(f"[journey] skipped: {_clip(e, 200)}")
        return rec
    log(f"[journey] {'PASS' if got.get('ok') else 'FAIL'} -> {save(run_dir, got, game_dir)}")
    return latest(run_dir)


def anomalies_for(game_dir: Path, run_dir: Path) -> list[dict]:
    """Dead interactions (static audit) + the latest fresh journey's failed steps, as fix-loop anomalies. A failed
    step a static finding explains is left out: the static anomaly is the one a fix can be re-audited against,
    and a journey that still fails after that fix names its own cause next time."""
    from forge import interactions

    audit = interactions.audit(game_dir)
    rec = latest(run_dir)
    steps = as_anomalies(rec, audit.get("findings")) if fresh(rec, game_dir) else []
    return interactions.as_anomalies(audit) + [a for a in steps if not a.get("static")]


def brief(rec: dict | None) -> dict:
    """{ok, failing: [step], passing: [step]} for measurements and gates."""
    steps = (rec or {}).get("steps") or []
    return {"ok": (rec or {}).get("ok"), "failing": [s["step"] for s in steps if s.get("ok") is False],
            "passing": [s["step"] for s in steps if s.get("ok") is True]}


def confirm(first: dict | None, second: dict | None) -> dict:
    """Two journeys of one version: a step fails only when it failed both times (timing windows make a single
    run noisy), and passes when it passed in either."""
    a, b = first or {}, second or {}
    failing = sorted(set(a.get("failing") or []) & set(b.get("failing") or []))
    passing = sorted((set(a.get("passing") or []) | set(b.get("passing") or [])) - set(failing))
    return {"ok": not failing and (a.get("ok") or b.get("ok")), "failing": failing, "passing": passing}


EXPECT = {
    "join": "a player joins and spawns with a living character",
    "lobby": "the player spawns in a built world: scenery, colour and tall landmarks around the spawn, ground that is "
             "not the grey template Baseplate (a WorldKit park with a ride in view)",
    "prompts": "every prompt in the lobby does what its text says (opens a panel, changes the player, builds "
               "something), and a panel it opens can be closed again",
    "costume": "the changing-room prompt puts a costume on (directly or through the costume panel's WEAR), and the "
               "costume shows on the character",
    "stage1": "the player can walk from the lobby to the course start and reach checkpoint 1",
    "respawn": "dying on a hazard respawns the player on their last checkpoint",
    "layout": "every on-screen button is the top-most clickable thing where it is drawn (nothing covers it)",
    "buttons": "every on-screen button does what it says when pressed; RESET brings the player back to their "
               "checkpoint",
    "ride": "the ride gate at the end of a zone keeps the stage and takes the player to the next zone's start",
}


def render(rec: dict) -> str:
    ok = rec.get("ok")
    lines = [f"journey ({rec.get('engine')}, {rec.get('secs')}s): " + ("PASS" if ok else "FAIL" if ok is False else "UNKNOWN")]
    for s in rec.get("steps") or []:
        state = "n/a " if s.get("skipped") else "PASS" if s.get("ok") else "FAIL" if s.get("ok") is False else "??  "
        lines.append(f"  [{state}] {s['step']:<8} {s.get('detail')}")
    return "\n".join(lines)
