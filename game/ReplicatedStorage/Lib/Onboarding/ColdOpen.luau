--!strict
-- ColdOpen [owner: Onboarding]. Pure rules for Onboarding v3's first 90 seconds (no Roblox APIs:
-- spec-tested in game/tests/cold_open.spec.luau). ColdOpenController plays the cutscene, HudRevealController
-- hides / reveals the HUD, FirstFireService runs the panda house.
--
--   ColdOpen.Shots                                  -- the cutscene's shots { name, at } (seconds, ascending)
--   ColdOpen.Length                                 -- total cutscene seconds
--   ColdOpen.shotAt(t) -> (name: string, alpha: number)   -- the shot at t and how far into it (0..1)
--   ColdOpen.canSkip(t, minSkip) -> boolean         -- any tap / key / button skips after minSkip seconds
--   ColdOpen.isSkipInput(inputType: string, keyCode: string) -> boolean
--       inputType / keyCode are Enum names. Every key, click, tap and gamepad button counts; mouse moves,
--       sticks, the scroll wheel and the Roblox menu keys (Escape, ButtonStart) don't.
--   ColdOpen.stage(f) -> number                     -- how far a brand-new player is (0..3), see Stage
--       f: { gated: boolean, phase: string?, onCall: boolean, callDone: boolean }
--   ColdOpen.Stage                                  -- { Cold = 0, Saved = 1, OnCall = 2, Done = 3 }
--   ColdOpen.HudKeys                                -- every HUD piece the reveal schedule knows
--   ColdOpen.hudVisible(key, f) -> boolean          -- may this HUD piece show now?
--       f: { gated: boolean, phase: string?, onCall: boolean, callDone: boolean, xp: boolean, cutscene: boolean }
--       gated = false (returning player, or the first call is done): everything shows.
local ColdOpen = {}

-- 0.0 wide on the burning house, the panda waving HELP! in the window
-- 2.4 the fire truck pulls up, siren rising
-- 4.8 close on the panda + the big SAVE THE PANDA! title
-- 7.0 cut to the player
ColdOpen.Shots = table.freeze({
	table.freeze({ name = "house", at = 0 }),
	table.freeze({ name = "truck", at = 2.4 }),
	table.freeze({ name = "title", at = 4.8 }),
	table.freeze({ name = "end", at = 7.0 }),
})
ColdOpen.Length = 7.0

function ColdOpen.shotAt(t: number): (string, number)
	local shots = ColdOpen.Shots
	if t >= ColdOpen.Length then
		return "end", 1
	end
	for i = #shots - 1, 1, -1 do
		local s = shots[i]
		if t >= s.at then
			local nextAt = shots[i + 1].at
			return s.name, math.clamp((t - s.at) / math.max(0.001, nextAt - s.at), 0, 1)
		end
	end
	return shots[1].name, 0
end

function ColdOpen.canSkip(t: number, minSkip: number): boolean
	return t >= minSkip
end

local NOT_SKIP_TYPES = {
	MouseMovement = true,
	MouseWheel = true,
	Focus = true,
	TextInput = true,
	None = true,
	Accelerometer = true,
	Gyro = true,
}
local NOT_SKIP_KEYS = {
	Escape = true, -- Roblox menu
	ButtonStart = true, -- Roblox menu (gamepad)
	ButtonSelect = true,
	Thumbstick1 = true, -- stick wiggles are not presses
	Thumbstick2 = true,
	Unknown = true,
}

function ColdOpen.isSkipInput(inputType: string, keyCode: string): boolean
	if NOT_SKIP_TYPES[inputType] then
		return false
	end
	if inputType == "Touch" or inputType == "MouseButton1" or inputType == "MouseButton2" or inputType == "MouseButton3" then
		return true
	end
	if inputType == "Keyboard" then
		return not NOT_SKIP_KEYS[keyCode]
	end
	if string.sub(inputType, 1, 7) == "Gamepad" then
		return keyCode ~= "" and not NOT_SKIP_KEYS[keyCode]
	end
	return false
end

ColdOpen.Stage = table.freeze({ Cold = 0, Saved = 1, OnCall = 2, Done = 3 })

-- phases after the panda is out (FirstFireConfig.PhaseAttr): the celebration and the pads may show
local SAVED_PHASES = { done = true, queued = true, open = true, launched = true }

export type Facts = { gated: boolean, phase: string?, onCall: boolean, callDone: boolean, xp: boolean?, cutscene: boolean? }

function ColdOpen.stage(f: Facts): number
	if not f.gated or f.callDone or f.phase == "skipped" then
		return ColdOpen.Stage.Done -- SKIP TUTORIAL: they asked for the whole game
	end
	if f.onCall then
		return ColdOpen.Stage.OnCall
	end
	if f.phase ~= nil and SAVED_PHASES[f.phase] then
		return ColdOpen.Stage.Saved
	end
	return ColdOpen.Stage.Cold
end

-- key -> the stage it shows from. "xp" is special: it also shows from the first XP you earn.
local MIN_STAGE: { [string]: number } = {
	xp = 1, -- XP bar (TopBox Level): the panda's +XP reveals it
	help = 1, -- HELP chip: after the panda, with the pads
	dpad = 1, -- gamepad D-pad legend: needed for GO NOW on the first-call card
	minimap = 2, -- minimap: once you're on the call (the drive)
	dispatch = 3, -- DISPATCH / 911
	store = 3,
	pass = 3, -- PASS chip + the pass meter
	news = 3,
	admin = 3,
	invite = 3,
	offer = 3, -- pass offer cards (OfferService already waits for a finished call; belt and braces)
	settings = 3, -- GRAPHICS / POP-UPS / EFFECTS buttons
}
ColdOpen.HudKeys = table.freeze({ "xp", "help", "dpad", "minimap", "dispatch", "store", "pass", "news", "admin", "invite", "offer", "settings" })

function ColdOpen.hudVisible(key: string, f: Facts): boolean
	if not f.gated then
		return true
	end
	if f.cutscene then
		return false -- nothing over the cold open
	end
	local min = MIN_STAGE[key]
	if min == nil then
		return true -- not a piece we manage
	end
	if key == "xp" and f.xp == true then
		return true
	end
	return ColdOpen.stage(f) >= min
end

return ColdOpen
