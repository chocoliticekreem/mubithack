--!strict
-- Calm [owner: G3]. "Reduce effects": one switch that every popup, flash, shake and FOV punch asks before it
-- goes off, so phones (small screen, thumbs over half of it) get a calm, friendly game.
--
-- Setting: ProfileSchema.Settings.effects (0 Auto, 1 Calm, 2 Full), mirrored by DataService to the Player
-- attr Effects; the lobby button under POP-UPS (ClientLib/WorldPopup) cycles it. Auto = calm on touch
-- input or a phone-size screen (shorter side under SmallSide px), full on desktop.
-- Dev: Player attr InputHintsMode = "touch" (ClientLib/InputHints) makes Auto calm on desktop too.
--
-- API
--   Calm.on() -> boolean           reduced effects right now
--   Calm.small() -> boolean        phone-size screen (shorter viewport side < SmallSide)
--   Calm.fx(x) -> number           x scaled for shakes / FOV kicks (x * Fx when calm)
--   Calm.alpha(from) -> number     a flash's starting transparency, fainter when calm
--   Calm.seconds(s, max) -> number on-screen time: min(s, max) when calm
--   Calm.mode() -> "Auto" | "Calm" | "Full";  Calm.label() -> "EFFECTS: AUTO (CALM)" ...
--   Calm.Changed: BindableEvent, fires (on: boolean) when the answer flips
local Players = game:GetService("Players")

local Calm = {}

Calm.SmallSide = 500 -- px: shorter viewport side below this is a phone
Calm.Fx = 0.35 -- shake / FOV punch multiplier when calm
Calm.FlashFx = 0.4 -- flash opacity multiplier when calm
Calm.Attr = "Effects" -- Player attr: 0 Auto, 1 Calm, 2 Full
Calm.Changed = Instance.new("BindableEvent")

local MODES = { [0] = "Auto", [1] = "Calm", [2] = "Full" }

local InputHints: any = nil
local function hints(): any
	if InputHints == nil then
		local ok, m = pcall(function()
			return require(script.Parent:WaitForChild("InputHints") :: ModuleScript)
		end)
		InputHints = if ok then m else false
	end
	return InputHints
end

function Calm.small(): boolean
	local cam = workspace.CurrentCamera
	if not cam then
		return false
	end
	local v = cam.ViewportSize
	return math.min(v.X, v.Y) < Calm.SmallSide
end

local function setting(): number
	local lp = Players.LocalPlayer
	local v = lp and tonumber(lp:GetAttribute(Calm.Attr))
	return if v == 1 or v == 2 then v else 0
end

function Calm.mode(): string
	return MODES[setting()]
end

function Calm.on(): boolean
	local s = setting()
	if s == 1 then
		return true
	elseif s == 2 then
		return false
	end
	local ih = hints()
	return (ih and ih.isTouch()) or Calm.small()
end

function Calm.label(): string
	local m = Calm.mode()
	if m == "Auto" then
		return if Calm.on() then "EFFECTS: AUTO (CALM)" else "EFFECTS: AUTO (FULL)"
	end
	return `EFFECTS: {string.upper(m)}`
end

function Calm.fx(x: number): number
	return if Calm.on() then x * Calm.Fx else x
end

function Calm.alpha(from: number): number
	-- transparency 0 = opaque: keep FlashFx of the opacity
	return if Calm.on() then 1 - (1 - from) * Calm.FlashFx else from
end

function Calm.seconds(s: number, max: number): number
	return if Calm.on() then math.min(s, max) else s
end

-- Changed: re-evaluate on the things that feed it
local last: boolean? = nil
local function check()
	local now = Calm.on()
	if now ~= last then
		last = now
		Calm.Changed:Fire(now)
	end
end
task.defer(function()
	local lp = Players.LocalPlayer
	if lp then
		lp:GetAttributeChangedSignal(Calm.Attr):Connect(check)
	end
	local ih = hints()
	if ih then
		ih.onChanged(check)
	end
	local function hook()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(check)
		end
	end
	hook()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hook)
	check()
end)

return Calm
