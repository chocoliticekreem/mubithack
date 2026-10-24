--!strict
-- InputHints [owner: G3]. Which input the local player is using (keyboard / touch / gamepad) and every
-- on-screen hint rewritten for it: "Press E" -> "Tap the button", "[G] DROP" -> "(DROP) DROP",
-- "[P] PASS" -> "PASS". Desktop keeps its keys. Rules + key map: StarterPlayerScripts/Lib/HintText.
--
-- Mode: UserInputService.PreferredInput (Touch / Gamepad / KeyboardAndMouse), falling back to
-- TouchEnabled / KeyboardEnabled / the last input type, live. Local Player attr InputHintsMode
-- ("touch" | "gamepad" | "keyboard") forces it (playtests, screenshots).
--
-- API
--   InputHints.mode() -> "keyboard" | "touch" | "gamepad";  InputHints.isTouch()
--   InputHints.format(text, ctx?) -> string           rewrite key tokens (server text: format on display)
--   InputHints.key(k, ctx?) -> string?                one keycap; nil = no way to do it on this input
--   InputHints.chip(k, label, after?) -> string       "[P] PASS" / "PASS"
--   InputHints.pick(keyboard, touch?, gamepad?)       whole-string variants
--   InputHints.set(obj, text, ctx?)                   obj.Text = format(text), re-applied on mode change
--   InputHints.setChip(obj, k, label, after?)         same for chip()
--   InputHints.setPick(obj, keyboard, touch?, gamepad?)
--   InputHints.watch(obj, fn(mode))                  fn now + on every mode change while obj lives
--   InputHints.onChanged(fn(mode)) -> RBXScriptConnection
-- Server-built signs: tag a TextLabel "InputHint" with attr HintText (+ optional HintTouch /
-- HintGamepad) and every client shows it for its own input.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local HintText = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("HintText") :: ModuleScript)

export type Mode = HintText.Mode

local InputHints = {}

local FORCE_ATTR = "InputHintsMode"
local TAG = "InputHint"

local changed = Instance.new("BindableEvent")
local current: Mode = "keyboard"

type Binding = { kind: string, a: any, b: any, c: any }
-- strong keys (Instance proxies in a weak table get collected while the Instance lives); dropped on Destroying
local bound: { [Instance]: Binding } = {}

local function preferred(): Mode?
	local ok, v = pcall(function()
		return (UserInputService :: any).PreferredInput
	end)
	if ok and typeof(v) == "EnumItem" then
		local n = (v :: EnumItem).Name
		return if n == "Touch" then "touch" elseif n == "Gamepad" then "gamepad" else "keyboard"
	end
	return nil
end

local function detect(): Mode
	local lp = Players.LocalPlayer
	local forced = lp and lp:GetAttribute(FORCE_ATTR)
	if forced == "touch" or forced == "gamepad" or forced == "keyboard" then
		return forced
	end
	local p = preferred()
	if p then
		return p
	end
	local last = UserInputService:GetLastInputType()
	if last == Enum.UserInputType.Touch then
		return "touch"
	elseif string.find(last.Name, "^Gamepad") then
		return "gamepad"
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		return "touch"
	end
	if UserInputService.GamepadEnabled and not UserInputService.KeyboardEnabled then
		return "gamepad"
	end
	return "keyboard"
end

local function render(b: Binding): string
	if b.kind == "fn" then
		b.a(current)
		return (nil :: any)
	elseif b.kind == "chip" then
		return HintText.chip(b.a, b.b, current, b.c)
	elseif b.kind == "pick" then
		return InputHints.pick(b.a, b.b, b.c)
	end
	return HintText.format(b.a, current, b.b)
end

local function apply(obj: Instance, b: Binding)
	local ok = pcall(function()
		local t = render(b)
		if t ~= nil and (obj :: any).Text ~= t then
			(obj :: any).Text = t
		end
	end)
	if not ok then
		bound[obj] = nil
	end
end

local function refresh()
	local m = detect()
	if m == current then
		return
	end
	current = m
	for obj, b in bound do
		apply(obj, b)
	end
	changed:Fire(m)
end

function InputHints.mode(): Mode
	return current
end

function InputHints.isTouch(): boolean
	return current == "touch"
end

function InputHints.format(text: string, ctx: HintText.Ctx?): string
	return HintText.format(text, current, ctx)
end

function InputHints.key(k: string, ctx: HintText.Ctx?): string?
	return HintText.label(k, current, ctx)
end

function InputHints.chip(k: string, label: string, after: boolean?): string
	return HintText.chip(k, label, current, after)
end

function InputHints.pick(keyboard: string, touch: string?, gamepad: string?): string
	if current == "touch" then
		return touch or HintText.format(keyboard, "touch")
	elseif current == "gamepad" then
		return gamepad or HintText.format(keyboard, "gamepad")
	end
	return keyboard
end

local function bind(obj: Instance, b: Binding)
	if not bound[obj] then
		obj.Destroying:Connect(function()
			bound[obj] = nil
		end)
	end
	bound[obj] = b
	apply(obj, b)
end

function InputHints.set(obj: Instance, text: string, ctx: HintText.Ctx?)
	bind(obj, { kind = "text", a = text, b = ctx })
end

function InputHints.setChip(obj: Instance, k: string, label: string, after: boolean?)
	bind(obj, { kind = "chip", a = k, b = label, c = after })
end

function InputHints.setPick(obj: Instance, keyboard: string, touch: string?, gamepad: string?)
	bind(obj, { kind = "pick", a = keyboard, b = touch, c = gamepad })
end

-- fn(mode) now and again on every mode change while obj exists (re-label keycaps, hide rows, ...)
function InputHints.watch(obj: Instance, fn: (Mode) -> ())
	bind(obj, { kind = "fn", a = fn })
end

function InputHints.onChanged(fn: (Mode) -> ()): RBXScriptConnection
	return changed.Event:Connect(fn)
end

-- server-built signs (GearService locker sign, donation board, ...)
local function tagged(obj: Instance)
	local function sync()
		local text = obj:GetAttribute("HintText")
		if type(text) ~= "string" then
			return
		end
		local t = obj:GetAttribute("HintTouch")
		local g = obj:GetAttribute("HintGamepad")
		InputHints.setPick(obj, text, if type(t) == "string" then t else nil, if type(g) == "string" then g else nil)
	end
	sync()
	obj:GetAttributeChangedSignal("HintText"):Connect(sync)
end

current = detect()
pcall(function()
	UserInputService:GetPropertyChangedSignal("PreferredInput" :: any):Connect(refresh)
end)
UserInputService.LastInputTypeChanged:Connect(function()
	if preferred() == nil then
		refresh()
	end
end)
task.spawn(function()
	local lp = Players.LocalPlayer
	if lp then
		lp:GetAttributeChangedSignal(FORCE_ATTR):Connect(refresh)
		refresh()
	end
end)
CollectionService:GetInstanceAddedSignal(TAG):Connect(tagged)
for _, obj in CollectionService:GetTagged(TAG) do
	task.spawn(tagged, obj)
end

return InputHints
