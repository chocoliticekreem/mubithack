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
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ColdOpen = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("ColdOpen") :: ModuleScript)

local HudGate = {}

local current: ColdOpen.Facts? = nil
local listeners: { [number]: () -> () } = {}
local nextId = 0

function HudGate.allows(key: string): boolean
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
	for _, fn in listeners do
		task.spawn(fn)
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
