--!strict
-- PopupGate [owner: G3]. The ONE gatekeeper for pop-ups that open by themselves (rules, spec-tested:
-- Lib/PopupGateRules). Every controller that shows something unasked asks here first:
--   * until the first call is done, nothing but the onboarding flow (celebration cards, achievement
--     toasts, other players' fanfare and auto modals are dropped, not queued)
--   * then one auto modal at a time, PopupGateRules.Gap s after the last pop-up went away
--   * at most SessionCap auto modals a session (a new player's first session: NewbieCap, `like` only);
--     the rest are deferred to the next session (their pending flag / red dot stays)
-- Things the player opens (a chip, a button, a prompt) never ask: only automatic ones.
--
--   PopupGate.onboarding() -> boolean        the first call isn't done (or we don't know yet)
--   PopupGate.decide(kind) -> "show" | "wait" | "drop" | "defer"
--   PopupGate.claim(kind) -> boolean          decide == "show": the slot is yours until release(kind)
--   PopupGate.release(kind)                   your auto modal closed (the Gap starts now)
--   PopupGate.noteEnd()                       a centre card / other pop-up just went away (HudLayout)
--   PopupGate.log() -> { string }             what was shown / dropped / deferred (tests, screenshots)
local Players = game:GetService("Players")

local Rules = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("PopupGateRules") :: ModuleScript)

local PopupGate = {}

local player = Players.LocalPlayer
local newbieSession: boolean? = nil -- decided the first time we know whether this player is new
local open: string? = nil
local lastEnd = -math.huge
local autoShown = 0
local events: { string } = {}
local t0 = os.clock()

local function note(s: string)
	table.insert(events, string.format("%5.1f %s", os.clock() - t0, s))
	if #events > 200 then
		table.remove(events, 1)
	end
end

function PopupGate.onboarding(): boolean
	local onboarded = player:GetAttribute("Onboarded")
	if onboarded == nil then
		return true -- not known yet (the first second): new until proven otherwise
	end
	if player:GetAttribute("FirstFire") == "skipped" then
		return false -- SKIP TUTORIAL: they asked for the whole game
	end
	local done = player:GetAttribute("FirstCallDone")
	return done == false
end

local function isNewbieSession(): boolean
	if newbieSession == nil and player:GetAttribute("Onboarded") ~= nil then
		newbieSession = player:GetAttribute("Onboarded") == false
	end
	return newbieSession == true
end

local function state(): Rules.State
	return {
		onboarding = PopupGate.onboarding(),
		newbieSession = isNewbieSession(),
		now = os.clock(),
		open = open,
		lastEnd = lastEnd,
		autoShown = autoShown,
	}
end

local lastSaid: { [string]: string } = {}
function PopupGate.decide(kind: string): string
	local d = Rules.decide(kind, state())
	if d ~= "show" and d ~= "wait" and lastSaid[kind] ~= d then
		note(`{d} {kind}`)
	end
	lastSaid[kind] = d
	return d
end

function PopupGate.claim(kind: string): boolean
	if PopupGate.decide(kind) ~= "show" then
		return false
	end
	local k = Rules.Kinds[kind]
	if k and k.class == "modal" then
		open = kind
		autoShown += 1
	end
	note(`show {kind}`)
	return true
end

function PopupGate.release(kind: string)
	if open == kind then
		open = nil
		lastEnd = os.clock()
		note(`closed {kind}`)
	end
end

function PopupGate.noteEnd()
	lastEnd = math.max(lastEnd, os.clock())
end

function PopupGate.log(): { string }
	return table.clone(events)
end

-- Studio / tests: Players.LocalPlayer.PopupGateLog:Invoke() -> the log as text
task.defer(function()
	if player:FindFirstChild("PopupGateLog") then
		return
	end
	local f = Instance.new("BindableFunction")
	f.Name = "PopupGateLog"
	f.OnInvoke = function(): string
		return table.concat(events, "\n")
	end
	f.Parent = player
end)

return PopupGate
