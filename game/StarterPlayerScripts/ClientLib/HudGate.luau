--!strict
-- HudGate [owner: Onboarding]. The one place that says which HUD pieces a brand-new player may see yet
-- (Onboarding v3: minimal UI until they're invested). Controllers/HudRevealController keeps it up to date
-- from the player's attributes; the rules are pure (ReplicatedStorage/Lib/Onboarding/ColdOpen.hudVisible).
-- Owners that draw a piece every frame ask it directly instead of being overridden from outside:
--   local HudGate = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudGate"))
--   help.Visible = wanted and HudGate.allows("help")
--
--   HudGate.allows(key) -> boolean        -- ColdOpen.HudKeys ("xp", "help", "dpad", "minimap", ...)
--   HudGate.set(facts)                    -- HudRevealController only
--   HudGate.facts() -> ColdOpen.Facts?    -- nil until the first set (everything is hidden until then)
--   HudGate.onChanged(fn) -> () -> ()     -- fn() after every change; returns a disconnect function
-- HIDE UI (the 👁 button, Controllers/HideUiController): while hidden, allows() is false for every key, so
-- every piece HudRevealController holds goes away and comes back exactly as its owner left it. Keys that start
-- with "ui:" are hide-only pieces (the rest of the HUD: Hud, DispatchGui, ChipMenuGui ...): the onboarding
-- schedule never gates them. A key in keep (HudGate.setKeep) stays up while hidden (thumb buttons while seated).
--   HudGate.setHidden(on), HudGate.hidden() -> boolean, HudGate.setKeep(key, on)
-- SEATED (in a truck / heli seat, Controllers/HideUiController polls it): only driving UI shows. Every key in
-- SEATED_HIDE is off (tutorial / guide cards, objective chips, menus, store / dispatch, hotbar ...), so a kid
-- driving sees the road, the drive buttons, the minimap and ONE turn card (DriveController).
--   HudGate.setSeated(on), HudGate.seated() -> boolean
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ColdOpen = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("ColdOpen") :: ModuleScript)

local HudGate = {}

local current: ColdOpen.Facts? = nil
local listeners: { [number]: () -> () } = {}
local nextId = 0
local hiddenOn = false
local keep: { [string]: boolean } = {}
local seatedOn = false
local SEATED_HIDE: { [string]: boolean } = {
	["ui:Onboarding"] = true, ["ui:OnboardingEdge"] = true, ["ui:MissionGuide"] = true, ["ui:MissionGuideEdge"] = true,
	["ui:ObjectiveChip"] = true, ["ui:ChipMenuGui"] = true, ["ui:SquadGui"] = true, ["ui:TwistGui"] = true,
	["ui:LobbyUI"] = true, ["ui:DispatchGui"] = true, ["ui:ComeBackGui"] = true, ["ui:GearHud"] = true,
	["ui:StructureHud"] = true, ["ui:TeamBonus"] = true, ["ui:Achievements"] = true,
	store = true, dispatch = true, pass = true, news = true, invite = true, offer = true, admin = true, hotbar = true,
}

local function notify()
	for _, fn in listeners do
		task.spawn(fn)
	end
end

function HudGate.allows(key: string): boolean
	if hiddenOn and not keep[key] then
		return false
	end
	if seatedOn and SEATED_HIDE[key] then
		return false
	end
	if string.sub(key, 1, 3) == "ui:" then
		return true -- hide-only pieces: the onboarding schedule never gates them
	end
	local f = current
	if not f then
		return false -- not known yet: brand-new or returning? Hide until we know (a second, under the title)
	end
	return ColdOpen.hudVisible(key, f)
end

function HudGate.facts(): ColdOpen.Facts?
	return current
end

local function same(a: ColdOpen.Facts?, b: ColdOpen.Facts): boolean
	return a ~= nil
		and a.gated == b.gated
		and a.phase == b.phase
		and a.onCall == b.onCall
		and a.callDone == b.callDone
		and a.xp == b.xp
		and a.cutscene == b.cutscene
end

function HudGate.set(f: ColdOpen.Facts)
	if same(current, f) then
		return
	end
	current = table.freeze(table.clone(f))
	notify()
end

function HudGate.setHidden(on: boolean)
	if hiddenOn == on then
		return
	end
	hiddenOn = on
	notify()
end

function HudGate.setSeated(on: boolean)
	if seatedOn == on then
		return
	end
	seatedOn = on
	notify()
end

function HudGate.seated(): boolean
	return seatedOn
end

function HudGate.hidden(): boolean
	return hiddenOn
end

function HudGate.setKeep(key: string, on: boolean)
	local v = if on then true else nil
	if keep[key] == v then
		return
	end
	keep[key] = v
	if hiddenOn then
		notify()
	end
end

function HudGate.onChanged(fn: () -> ()): () -> ()
	nextId += 1
	local id = nextId
	listeners[id] = fn
	return function()
		listeners[id] = nil
	end
end

return HudGate
