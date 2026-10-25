--!strict
-- GamepadController [owner: G3]. Console / gamepad glue (docs/game/17-console-support.md):
--   * runs ClientLib/GamepadNav every frame: the cursor lands in a menu when it opens, stays inside it,
--     goes back when it closes
--   * B = back while a menu is up or the cursor is on a HUD button (bound only then, above the truck's
--     B = OUT and the hand's B = DROP, so those keep working everywhere else)
--   * D-pad left = put the cursor on the HUD buttons (DISPATCH, STORE, PASS, NEWS, HELP, GO NOW, ACCEPT...)
--   * right stick scrolls the open menu's list
--   * the yellow chunky cursor (PlayerGui.SelectionImageObject)
--   * a small "D-PAD LEFT: MENU" reminder at the bottom left while a gamepad is in use and no menu is up
-- Nothing here does anything for keyboard / mouse / touch players.
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local GamepadNav = require(ClientLib:WaitForChild("GamepadNav") :: ModuleScript) :: any
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any

local GamepadController = {}
GamepadController.Priority = 40 -- before the menus are built, so the cursor image is in place

local BACK_ACTION = "PadBack"
local MENU_ACTION = "PadMenu"
-- above Enum.ContextActionPriority.High (3000): the truck binds B (OUT) there
local BACK_PRIORITY = 4000

local player = Players.LocalPlayer
local backBound = false
local lastBack = 0
local legend: Frame? = nil

local function doBack(): boolean
	if os.clock() - lastBack < 0.2 then
		return true -- the same press seen twice (ContextAction + InputBegan)
	end
	if not GamepadNav.active() then
		return false
	end
	lastBack = os.clock()
	return GamepadNav.back()
end

local function onBack(_: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin and doBack() then
		return Enum.ContextActionResult.Sink
	end
	return if GamepadNav.active() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end

local function onMenu(_: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	-- the cursor is already somewhere: D-pad left moves it (Roblox's own navigation)
	if GuiService.SelectedObject ~= nil or GamepadNav.top() ~= nil then
		return Enum.ContextActionResult.Pass
	end
	return if GamepadNav.focusHud() then Enum.ContextActionResult.Sink else Enum.ContextActionResult.Pass
end

local function buildLegend()
	local gui = UiKit.screen("GamepadLegend", 4)
	local f = Instance.new("Frame")
	f.Name = "Legend"
	f.AnchorPoint = Vector2.new(0, 1)
	f.Position = UDim2.new(0, 16, 1, -62) -- above the HELP chip (bottom left)
	f.Size = UDim2.fromOffset(300, 30)
	f.BackgroundColor3 = Palette.UiPanelDark
	f.BackgroundTransparency = 0.25
	f.Visible = false
	f.Parent = gui
	UiKit.corner(f, 8)
	local t = UiKit.label(f, "Text", "D-PAD  ◄ MENU   ▼ MAP", UDim2.new(1, -12, 1, 0), UDim2.fromOffset(6, 0), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiCream,
	})
	t.TextScaled = true
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 18
	cap.MinTextSize = 12
	cap.Parent = t
	legend = f
end

function GamepadController:Init(_all) end

function GamepadController:Start()
	local pg = player:WaitForChild("PlayerGui") :: PlayerGui
	pcall(function()
		pg.SelectionImageObject = GamepadNav.selectionImage()
	end)
	buildLegend()
	ContextActionService:BindAction(MENU_ACTION, onMenu, false, Enum.KeyCode.DPadLeft)
	-- B also through InputBegan: with a GUI button selected Roblox may route B to its own navigation
	UserInputService.InputBegan:Connect(function(input: InputObject)
		if input.KeyCode == Enum.KeyCode.ButtonB then
			doBack()
		end
	end)
	RunService.RenderStepped:Connect(function(dt: number)
		local ok, err = pcall(GamepadNav.step)
		if not ok then
			warn(`[GamepadController] {err}`)
		end
		local want = GamepadNav.active()
		if want ~= backBound then
			backBound = want
			if want then
				ContextActionService:BindActionAtPriority(BACK_ACTION, onBack, false, BACK_PRIORITY, Enum.KeyCode.ButtonB)
			else
				ContextActionService:UnbindAction(BACK_ACTION)
			end
		end
		local pad = InputHints.mode() == "gamepad"
		if pad and GamepadNav.top() ~= nil then
			for _, st in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
				if st.KeyCode == Enum.KeyCode.Thumbstick2 then
					GamepadNav.scroll(st.Position.Y, dt)
				end
			end
		end
		local lg = legend
		if lg then
			lg.Visible = pad and GamepadNav.top() == nil and GuiService.SelectedObject == nil
		end
	end)
end

return GamepadController
