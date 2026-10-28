--!strict
-- HudRevealController [owner: Onboarding]. Onboarding v3 "minimal UI until invested": a brand-new player
-- starts with almost no HUD (no XP bar, PASS, STORE, NEWS, ADMIN, INVITE, minimap / DISPATCH, D-pad legend,
-- HELP) through the cold open, the house fire and the panda; each piece then appears, with a small pop,
-- when it becomes relevant. Returning players (Player attr FirstCallDone = true) see everything at once.
-- The schedule is pure (Lib/Onboarding/ColdOpen.hudVisible, spec-tested):
--   XP bar (TopBox)         -> your first XP (the house fire / the panda)
--   HELP chip, D-pad legend -> the panda is saved (FirstFire done / queued)
--   minimap                 -> on your first call
--   PASS, STORE, DISPATCH, NEWS, ADMIN, INVITE, pass offers -> your first call is complete
--   SKIP TUTORIAL           -> everything (they asked for the whole game)
-- How: ClientLib/HudGate holds the decision. Pieces drawn every frame by their owner ask HudGate
-- (OnboardingController's HELP chip). Everything else is held here from outside, without touching its
-- owner: while a piece is gated its ScreenGui.Enabled / GuiObject.Visible is kept false, and whatever its
-- owner sets meanwhile is remembered and put back when the gate opens (so the owner's own rules, like
-- "STORE only in the lobby", still win afterwards).
-- Funnel: Onboarding/Seen("hud") once, the first time the post-panda HUD is revealed ("HUD Revealed").
-- Public: HudRevealController:State() -> { [key]: boolean } (tests)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local FireCfg = require(ConfigDir:WaitForChild("FirstFireConfig") :: ModuleScript) :: any
local DataConfig = require(ConfigDir:WaitForChild("DataConfig") :: ModuleScript) :: any
local ColdOpen = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("ColdOpen") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local HudGate = require(ClientLib:WaitForChild("HudGate") :: ModuleScript)

local HudRevealController = {}
HudRevealController.Priority = 15 -- early: hold the HUD before the other controllers draw it

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

-- what we hold from outside: ScreenGui name (+ a direct child of its first frame / the gui, by name)
type Target = { key: string, gui: string, child: string? }
local TARGETS: { Target } = {
	{ key = "xp", gui = "TopBox" }, -- the whole top-bar box (level / XP first)
	{ key = "store", gui = "TopBox", child = "Store" },
	{ key = "dispatch", gui = "TopBox", child = "Dispatch" },
	{ key = "pass", gui = "BattlePassGui" }, -- PASS chip (left chip column), the pass panel, pass XP pops
	{ key = "news", gui = "UpdateLog" }, -- NEWS chip + WHAT'S NEW panel
	{ key = "admin", gui = "AdminGui" },
	{ key = "invite", gui = "SocialAsk" }, -- INVITE chip + the like card
	{ key = "offer", gui = "OfferGui" },
	{ key = "minimap", gui = "NavMinimap" },
	{ key = "dpad", gui = "GamepadLegend" },
	-- keys the schedule doesn't list (ColdOpen.hudVisible: shown, except over the cold open)
	{ key = "hotbar", gui = "InventoryHud" },
	{ key = "carry", gui = "Carry" },
}
-- HIDE UI (HudGate.setHidden, the 👁 button): the rest of the game HUD, hide-only ("ui:" keys are never gated
-- by the onboarding schedule). NOT here, so they always show: Results / DailyChest, the cold open and title,
-- modal menus (STORE, LOCKER, big map, REMIND ME), screen effects (negative DisplayOrder) and the 👁 itself.
-- "ui:thumbs" (touch action buttons and tap bubbles) stays up while seated: OUT / UP / DOWN are how you move.
for _, name in {
	"ProfileHud", "Achievements", "NavEdge", "Hud", "HudMarkers", "ObjectiveChip", "FireCall", "FireCallEdge",
	"StructureHud", "HeliHud", "DispatchGui", "ComeBackGui", "GearHud", "DriveHud", "DriveTurn", "MissionGuide",
	"MissionGuideEdge", "Onboarding", "OnboardingEdge", "TwistGui", "LobbyUI", "SquadGui", "ChipMenuGui",
	"TruckHud", "TeamBonus", "FanfareGui", "GearUnlocked",
} do
	table.insert(TARGETS, { key = "ui:" .. name, gui = name })
end
for _, name in { "ThumbButtons", "TapBubble", "TapBubbleIn" } do
	table.insert(TARGETS, { key = "ui:thumbs", gui = name })
end

type Held = { inst: Instance, prop: string, key: string, wanted: boolean, setting: boolean, shown: boolean }
local held: { [Instance]: Held } = {}
local hudSeenSent = false
local everGated = false
local wasHidden = false
local quiet = false -- coming back from HIDE UI: no reveal pops

local function attr(name: string): any
	return player:GetAttribute(name)
end

local function facts(): ColdOpen.Facts?
	local done = attr(FireCfg.FirstCallDoneAttr or "FirstCallDone")
	if done == nil then
		return nil -- the server hasn't said yet
	end
	local id = attr("InstanceId")
	local lvl = tonumber(attr(DataConfig.Attr.Level)) or 1
	local xp = tonumber(attr(DataConfig.Attr.Xp)) or 0
	local cut = false
	local co = controllers.ColdOpenController
	if co and type(co.IsPlaying) == "function" then
		local ok, playing = pcall(co.IsPlaying, co)
		cut = ok and playing == true
	end
	local phase = attr(FireCfg.PhaseAttr)
	return {
		gated = done ~= true,
		phase = if type(phase) == "string" then phase else nil,
		onCall = type(id) == "string" and id ~= "",
		callDone = done == true,
		xp = lvl > 1 or xp > 0,
		cutscene = cut,
	}
end

-- UiKit.pop drives a UIScale: never pop something whose own UIScale means something else (the top-bar
-- box shrinks itself on phones with one); pop its children instead
local function popOne(g: GuiObject, depth: number)
	if not g.Visible then
		return
	end
	local own = g:FindFirstChildOfClass("UIScale")
	if not own or own.Name == "PopScale" then
		UiKit.pop(g, 0.35)
		return
	end
	if depth > 0 then
		for _, c in g:GetChildren() do
			if c:IsA("GuiObject") then
				popOne(c, depth - 1)
			end
		end
	end
end

local function popTarget(inst: Instance)
	if inst:IsA("GuiObject") then
		popOne(inst, 1)
	elseif inst:IsA("ScreenGui") then
		for _, c in inst:GetChildren() do
			if c:IsA("GuiObject") then
				popOne(c, 1)
			end
		end
	end
end

local function set(h: Held, value: boolean)
	if (h.inst :: any)[h.prop] == value then
		return
	end
	h.setting = true
	;(h.inst :: any)[h.prop] = value
	h.setting = false
end

local function apply(h: Held)
	local allowed = HudGate.allows(h.key)
	if allowed then
		set(h, h.wanted)
		if not h.shown and h.wanted and everGated and not quiet then
			popTarget(h.inst) -- revealed now: a small pop so the eye goes to it
		end
		h.shown = h.wanted
	else
		set(h, false)
		h.shown = false
	end
end

local function hold(inst: Instance, prop: string, key: string)
	if held[inst] then
		return
	end
	local w = (inst :: any)[prop] == true
	-- hide-only pieces were never gated: no reveal pop the first time they're held
	local h: Held = { inst = inst, prop = prop, key = key, wanted = w, setting = false, shown = w and string.sub(key, 1, 3) == "ui:" }
	held[inst] = h
	inst:GetPropertyChangedSignal(prop):Connect(function()
		if h.setting then
			return
		end
		h.wanted = (inst :: any)[prop] == true
		if h.wanted and not HudGate.allows(h.key) then
			set(h, false) -- remembered; put back when the gate opens
		else
			h.shown = h.wanted
		end
	end)
	inst.Destroying:Connect(function()
		held[inst] = nil
	end)
	apply(h)
end

local function find(t: Target): (Instance?, string?)
	local pg = player:FindFirstChild("PlayerGui")
	local g = pg and pg:FindFirstChild(t.gui)
	if not g or not g:IsA("ScreenGui") then
		return nil, nil
	end
	if not t.child then
		return g, "Enabled"
	end
	local c = g:FindFirstChild(t.child, true)
	if c and c:IsA("GuiObject") then
		return c, "Visible"
	end
	return nil, nil
end

local function scan()
	for _, t in TARGETS do
		local inst, prop = find(t)
		if inst and prop then
			hold(inst, prop, t.key)
		end
	end
end

local function refresh()
	local f = facts()
	if f then
		if f.gated then
			everGated = true
		end
		HudGate.set(f)
	end
	for _, h in held do
		apply(h)
	end
	-- "HUD Revealed" funnel step: the first post-panda reveal a brand-new player sees
	if f and everGated and not hudSeenSent and ColdOpen.stage(f) >= ColdOpen.Stage.Saved then
		hudSeenSent = true
		pcall(function()
			Net.event("Onboarding", "Seen"):FireServer("hud")
		end)
	end
end

function HudRevealController:State(): { [string]: boolean }
	local out = {}
	for _, k in ColdOpen.HudKeys do
		out[k] = HudGate.allows(k)
	end
	return out
end

function HudRevealController:Init(all: { [string]: any })
	controllers = all
end

function HudRevealController:Start()
	local pg = player:WaitForChild("PlayerGui")
	-- hold pieces the moment they appear (most controllers build their gui in Start, after us)
	pg.ChildAdded:Connect(function(d: Instance)
		if d:IsA("ScreenGui") then
			scan() -- a new ScreenGui: held before it can draw a frame (sections are picked up by the poll)
		end
	end)
	scan()
	local names = {
		FireCfg.FirstCallDoneAttr or "FirstCallDone",
		FireCfg.PhaseAttr,
		"InstanceId",
		DataConfig.Attr.Level,
		DataConfig.Attr.Xp,
	}
	for _, n in names do
		player:GetAttributeChangedSignal(n):Connect(refresh)
	end
	HudGate.onChanged(function()
		local hid = HudGate.hidden()
		quiet = wasHidden and not hid
		wasHidden = hid
		for _, h in held do
			apply(h)
		end
		quiet = false
	end)
	refresh()
	-- the cutscene flag lives on a controller: poll it (cheap) along with late-built pieces
	task.spawn(function()
		while true do
			task.wait(0.25)
			scan()
			refresh()
		end
	end)
end

return HudRevealController
