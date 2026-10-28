--!strict
-- HideUiController [owner: G3]. The 👁 HIDE UI button (docs/game/22-declutter.md): one tap hides the whole game
-- HUD (top bar, ☰ menu, cards, squad strip, minimap, heat, objective chip, toasts, thumb buttons), one more
-- brings it back exactly as it was. Movement stays: Roblox's thumbstick / jump are never ours to hide, and the
-- touch buttons stay while seated (OUT / UP / DOWN are how you move in the truck and the heli).
--   * 👁 sits in the Roblox top-bar row right after Roblox's own buttons (ClientLib/TopBox.lead moves the
--     level box over). Hidden: the same spot shows only a small see-through 👁 to bring it back.
--   * PC: HudConfig.HideKeys (F1, or `). Gamepad: D-pad left (HUD buttons) -> 👁 -> A. Touch: tap 👁.
--   * Never hidden: results, the cold open, modal menus (STORE, LOCKER, big map, REMIND ME), screen effects.
--     A menu opening (PASS by [P], HELP by [H] ...) brings the HUD back first.
--   * The choice lasts the session (this controller lives the whole session; mirrored to Player attr
--     HudConfig.HiddenAttr). How the HUD goes away: ClientLib/HudGate.setHidden -> HudRevealController holds
--     every HUD ScreenGui's Enabled (and puts back whatever its owner wanted).
-- Test hook: Players.LocalPlayer.HideUiTest:Invoke("hide" | "show" | "toggle" | "state") -> "true" / "false"
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HudConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudGate = require(ClientLib:WaitForChild("HudGate") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local TopBox = require(ClientLib:WaitForChild("TopBox") :: ModuleScript) :: any
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any

local HideUiController = {}
HideUiController.Priority = 16 -- right after HudRevealController (15), which does the holding

local player = Players.LocalPlayer
local hidden = false
local btn: TextButton? = nil
local keyTag: TextLabel? = nil
local glyph: TextLabel? = nil
local spot: (() -> (number, number, number))? = nil

local function paint()
	local b, g, k, at = btn, glyph, keyTag, spot
	if not (b and g and k and at) then
		return
	end
	local x, y, h = at()
	local size = if hidden then math.floor(h * 0.8) else h
	b.Size = UDim2.fromOffset(size, size)
	b.Position = UDim2.fromOffset(x + math.floor((h - size) / 2), y + math.floor((h - size) / 2))
	b.BackgroundTransparency = if hidden then 0.65 else 0
	g.TextTransparency = if hidden then 0.35 else 0
	local stroke = b:FindFirstChildOfClass("UIStroke")
	if stroke then
		stroke.Transparency = if hidden then 0.6 else 0
	end
	k.Visible = not hidden and InputHints.mode() == "keyboard"
end

local function setHidden(on: boolean)
	if hidden == on then
		return
	end
	hidden = on
	HudGate.setHidden(on)
	player:SetAttribute(Cfg.HiddenAttr, on)
	paint()
end

local function toggle()
	setHidden(not hidden)
	if btn then
		UiKit.punch(btn, 0.12)
	end
end

local function build()
	local pg = player:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("HideUiGui")
	if old then
		old:Destroy()
	end
	local g = Instance.new("ScreenGui")
	g.Name = "HideUiGui"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true -- up in the top-bar row, like ClientLib/TopBox
	g.ScreenInsets = Enum.ScreenInsets.None
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.DisplayOrder = 7
	local b = Instance.new("TextButton")
	b.Name = "HideUi"
	b.Text = ""
	b.AutoButtonColor = true
	b.BackgroundColor3 = Palette.UiCream
	b.BorderSizePixel = 0
	b.Parent = g
	UiKit.corner(b, 10)
	UiKit.stroke(b, 2.5, Palette.UiInk)
	local e = Instance.new("TextLabel")
	e.Name = "Eye"
	e.BackgroundTransparency = 1
	e.Size = UDim2.fromScale(0.8, 0.8)
	e.Position = UDim2.fromScale(0.1, 0.08)
	e.Text = "👁"
	e.TextScaled = true
	e.Font = Enum.Font.GothamBold
	e.TextColor3 = Palette.UiInk
	e.Parent = b
	-- PC: the key, tiny, in the corner (no hover-only info)
	local k = Instance.new("TextLabel")
	k.Name = "Key"
	k.AnchorPoint = Vector2.new(1, 1)
	k.Position = UDim2.new(1, 4, 1, 4)
	k.Size = UDim2.fromOffset(20, 13)
	k.BackgroundColor3 = Palette.UiInk
	k.BorderSizePixel = 0
	k.Text = tostring(Cfg.HideKeys[1])
	k.TextScaled = true
	k.Font = Enum.Font.GothamBold
	k.TextColor3 = Palette.UiCream
	k.ZIndex = 3
	k.Parent = b
	UiKit.corner(k, 4)
	UiKit.onTap(b, toggle)
	g.Parent = pg
	btn, glyph, keyTag = b, e, k
	spot = TopBox.lead(44)
	paint()
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(paint)
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(paint)
	end
	InputHints.onChanged(paint)
end

local function seated(): boolean
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.SeatPart ~= nil
end

function HideUiController:Init(_all) end

function HideUiController:Start()
	build()
	if player:GetAttribute(Cfg.HiddenAttr) == true then
		setHidden(true) -- this session already chose it (a re-run of the client scripts)
	end
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.UserInputType == Enum.UserInputType.Keyboard and table.find(Cfg.HideKeys, input.KeyCode.Name) then
			toggle()
		end
	end)
	-- a menu opened while hidden (by its key): show the HUD first, the menu lives in it
	HudLayout.ModalChanged.Event:Connect(function(open: boolean)
		if open and hidden then
			setHidden(false)
		end
	end)
	-- the touch buttons stay while seated (truck OUT, heli UP / DOWN); TopBox's spot can move (voice mic)
	task.spawn(function()
		while btn and btn.Parent do
			HudGate.setKeep("ui:thumbs", seated())
			paint()
			task.wait(0.5)
		end
	end)
	local f = Instance.new("BindableFunction")
	f.Name = "HideUiTest"
	f.OnInvoke = function(what: string): string
		if what == "hide" then
			setHidden(true)
		elseif what == "show" then
			setHidden(false)
		elseif what == "toggle" then
			toggle()
		end
		return tostring(hidden)
	end
	local prev = player:FindFirstChild("HideUiTest")
	if prev then
		prev:Destroy()
	end
	f.Parent = player
end

return HideUiController
