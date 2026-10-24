--!strict
-- HintText: pure rewrite of keyboard hints ("Press E", "[G] DROP", "hold Q", "click") for touch and
-- gamepad players. No Roblox APIs (spec-tested in game/tests/input_hints.spec.luau). The live side
-- (which input the player uses, re-labelling on change) is ClientLib/InputHints.
--
--   HintText.format(text, mode, ctx?) -> string   keyboard: unchanged. touch / gamepad: key tokens
--                                                 rewritten to the on-screen button that does it
--   HintText.label(key, mode, ctx?) -> string?    one keycap ("E", "hold Q", "CLICK"); nil = this input
--                                                 has no way to do it (hide the row)
--   HintText.chip(key, label, mode, after?)       "[P] PASS" on keyboard, "PASS" on touch
--   HintText.Keys                                 key -> { touch, pad } (see below)
--   ctx = { [key] = { touch = "YEET", pad = "X" } } overrides one call ("" = none on that input) (the same key is a different
--   button in a different place: G is DROP on foot, SIREN in the truck).
--
-- Touch: keys that belong to a ProximityPrompt (E R T F) become "tap the button" / "(tap)": on a phone
-- the prompt itself is the round button you tap. Keys with their own on-screen button (G Q 1 2 ...)
-- become that button's title ("tap DROP"). "click" becomes "tap".
local HintText = {}

export type Mode = "keyboard" | "touch" | "gamepad"
export type Entry = { touch: string?, pad: string? }
export type Ctx = { [string]: Entry }

local PROMPT = "@prompt" -- touch: the ProximityPrompt's own button

-- every key the game's hints mention. touch = the title of the real on-screen button (ContextAction
-- titles in InventoryController / RescueController / VehicleController, HUD chips), pad = gamepad
-- button (ProximityPrompts use their default GamepadKeyCode, ButtonX).
HintText.Keys = {
	E = { touch = PROMPT, pad = "X" },
	R = { touch = PROMPT, pad = "X" },
	T = { touch = PROMPT, pad = "X" },
	F = { touch = PROMPT, pad = "X" },
	G = { touch = "DROP", pad = "B" }, -- InvDrop / RescueDrop
	Q = { touch = "THROW", pad = "L1" }, -- InvThrow (RescueThrow is YEET / X: pass ctx)
	["1"] = { touch = "SWAP", pad = "D-PAD UP" }, -- InvSwap
	["2"] = { touch = "SWAP", pad = "D-PAD UP" },
	H = { touch = "HELP" }, -- OnboardingController HELP chip
	J = { touch = "SKIP" }, -- MissionGuideController SKIP button
	K = { touch = "DANCE" }, -- BattlePassController DANCE button
	P = { touch = "PASS" },
	B = { touch = "STORE" },
	[";"] = { touch = "ADMIN" },
	M = { touch = "M" }, -- the minimap's round "M" map button
	SPACE = { touch = "JUMP", pad = "A" },
	CLICK = { touch = "TAP", pad = "R2" },
	-- V (camera), Z X C (emotes): keyboard only
} :: { [string]: Entry }

local function entry(key: string, ctx: Ctx?): Entry?
	local k = string.upper(key)
	local o = ctx and ctx[k]
	local base = HintText.Keys[k]
	if o then
		local t = if o.touch ~= nil then o.touch else base and base.touch
		local p = if o.pad ~= nil then o.pad else base and base.pad
		return { touch = if t == "" then nil else t, pad = if p == "" then nil else p } -- "" = no way on that input
	end
	return base
end

local function cap(s: string, upper: boolean): string
	return if upper then string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2) else s
end

-- "Tap the button" / "tap DROP" (touch) or "press X" (gamepad); nil when the key has no equivalent
local function verb(key: string, mode: Mode, ctx: Ctx?, hold: boolean, upper: boolean): string?
	local e = entry(key, ctx)
	if not e then
		return nil
	end
	if mode == "touch" then
		if not e.touch then
			return nil
		end
		local what = if e.touch == PROMPT then "the button" else e.touch :: string
		return cap(if hold then "hold " .. what else "tap " .. what, upper)
	end
	if not e.pad then
		return nil
	end
	return cap(if hold then "hold " .. e.pad else "press " .. e.pad, upper)
end

-- "(tap)" / "(DROP)" / "(hold YEET)" (touch), "(X)" (gamepad)
local function paren(key: string, mode: Mode, ctx: Ctx?, hold: boolean): string?
	local e = entry(key, ctx)
	if not e then
		return nil
	end
	local name: string? = if mode == "touch" then e.touch else e.pad
	if not name then
		return nil
	end
	if name == PROMPT then
		return if hold then "(hold)" else "(tap)"
	end
	return if hold then `(hold {name})` else `({name})`
end

-- a sentence starts at pos (start of text, or after . ! ? and spaces)
local function sentenceStart(text: string, pos: number): boolean
	local before = string.match(string.sub(text, 1, pos - 1), "(%S?)%s*$")
	return before == "" or before == "." or before == "!" or before == "?"
end

local KEY = "([%u%d;])"

function HintText.format(text: string, mode: Mode, ctx: Ctx?): string
	if mode ~= "touch" and mode ~= "gamepad" then
		return text
	end
	local s = text
	-- one swap button does both: "press 1 or 2"
	s = string.gsub(s, "(%f[%a][Pp]ress) 1 or 2%f[^%w]", "%1 1")
	-- "hold [E]" -> "hold the button"
	s = string.gsub(s, "([Hh]old) %[" .. KEY .. "%]", function(h: string, k: string)
		return verb(k, mode, ctx, true, h == "Hold") or nil
	end)
	-- "[hold Q]" / "(hold Q)" -> "(hold YEET)"
	s = string.gsub(s, "[%[%(]hold " .. KEY .. "[%]%)]", function(k: string)
		return paren(k, mode, ctx, true) or nil
	end)
	-- "[E]" / "(E)" -> "(tap)"
	s = string.gsub(s, "[%[%(]" .. KEY .. "[%]%)]", function(k: string)
		return paren(k, mode, ctx, false) or nil
	end)
	-- "Press E" / "hit G" / "Hold E"
	s = string.gsub(s, "%f[%a]([Pp]ress) " .. KEY .. "%f[^%w]", function(p: string, k: string)
		return verb(k, mode, ctx, false, p == "Press") or nil
	end)
	s = string.gsub(s, "%f[%a]([Hh]it) " .. KEY .. "%f[^%w]", function(p: string, k: string)
		return verb(k, mode, ctx, false, p == "Hit") or nil
	end)
	s = string.gsub(s, "%f[%a]([Hh]old) " .. KEY .. "%f[^%w]", function(p: string, k: string)
		return verb(k, mode, ctx, true, p == "Hold") or nil
	end)
	-- a bare key in a sentence: "E to pick up", "Or E on a hydrant", "(G to drop)"
	for _, w in { "to", "on" } do
		s = string.gsub(s, "()%f[%w]([EGQRTF]) " .. w .. " ", function(pos: number, k: string)
			local e = entry(k, ctx)
			if not e then
				return nil
			end
			local upper = sentenceStart(s, pos)
			if mode == "touch" then
				if not e.touch then
					return nil
				end
				if e.touch == PROMPT then
					return cap(if w == "to" then "tap to " else "tap the button on ", upper)
				end
				return cap(`tap {e.touch} {w} `, upper)
			end
			return if e.pad then `{e.pad} {w} ` else nil
		end)
	end
	-- "Hold LEFT CLICK to spray": tools fire while a finger is on the screen / R2 is held
	s = string.gsub(s, "%f[%a]LEFT CLICK%f[^%a]", if mode == "touch" then "the screen" else "R2")
	s = string.gsub(s, "%f[%a][Ll]eft[%- ]click%f[^%a]", if mode == "touch" then "the screen" else "R2")
	-- "click" -> "tap" / "press R2"
	s = string.gsub(s, "%f[%a]([Cc][Ll][Ii][Cc][Kk])%f[^%a]", function(c: string)
		if mode == "touch" then
			return if c == "CLICK" then "TAP" elseif c == "Click" then "Tap" else "tap"
		end
		return if c == "CLICK" then "R2" elseif c == "Click" then "Press R2" else "press R2"
	end)
	if mode == "touch" then
		s = string.gsub(s, "%f[%w]W/S%f[^%w]", "stick")
		s = string.gsub(s, "%f[%w]A/D%f[^%w]", "stick")
	end
	return s
end

-- one keycap: "E" -> "TAP", "hold Q" -> "HOLD THROW", "CLICK" -> "TAP"; nil = no way on this input
function HintText.label(key: string, mode: Mode, ctx: Ctx?): string?
	if mode ~= "touch" and mode ~= "gamepad" then
		return key
	end
	local hold, k = string.match(key, "^(hold )(.+)$")
	k = k or key
	local e = entry(k, ctx)
	if not e then
		return if #k > 1 then key else nil -- a word ("WALK") reads the same everywhere
	end
	local name: string? = if mode == "touch" then e.touch else e.pad
	if not name then
		return nil
	end
	if name == PROMPT then
		name = "TAP"
	end
	return if hold then "HOLD " .. (name :: string) else name
end

-- a HUD button that also has a hotkey: "[P] PASS" (or "SKIP [J]" with after) on keyboard, "PASS" else
function HintText.chip(key: string, label: string, mode: Mode, after: boolean?): string
	if mode == "keyboard" then
		return if after then `{label} [{key}]` else `[{key}] {label}`
	end
	return label
end

return HintText
