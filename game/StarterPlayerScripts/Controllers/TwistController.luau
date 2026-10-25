--!strict
-- TwistController [owner: Twists]. Shows the call's twist (server: Services/TwistService, words and icons:
-- Config/TwistConfig.Defs). Nothing here changes gameplay.
--   * TWIST card in the top-centre stack (HudLayout "TopCentre", under the INCOMING CALL card): a yellow
--     icon chip + "TWIST!" + the title ("CAT IN A TREE!") + one short line. It pops when the call comes in
--     (Player attr Twist set) and again on arrival (Workspace.Runs.<InstanceId> RoundState -> Active), for
--     TwistConfig.CardSeconds each. Informational only: no input, so touch / PC / gamepad all just read it.
--     Colours follow the HUD rules (docs/game/16): dark panel, yellow = what's special / what to do.
--   * NIGHT CALL: a local helmet torch (SpotLight + a soft glow) on my character while Twist == "night".
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local TwistConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TwistConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any

local TwistController = {}
TwistController.Priority = 112

local player = Players.LocalPlayer
local ATTR = "Twist"
local ui: { [string]: any } = {}
local showToken = 0
local runConn: RBXScriptConnection? = nil
local torch: { Instance } = {}

local function label(parent: Instance, name: string, text: string, font: Enum.Font, color: Color3, size: UDim2, pos: UDim2): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font
	l.Text = text
	l.TextColor3 = color
	l.TextScaled = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Size = size
	l.Position = pos
	l.Parent = parent
	return l
end

local function stroke(parent: Instance, thickness: number, color: Color3, contextual: boolean?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color
	s.ApplyStrokeMode = if contextual then Enum.ApplyStrokeMode.Contextual else Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function build()
	local gui = UiKit.screen("TwistGui", 27)
	local card = Instance.new("Frame")
	card.Name = "TwistCard"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 10)
	card.Size = UDim2.fromOffset(400, 76)
	card.BackgroundColor3 = Palette.UiPanelDark
	card.BackgroundTransparency = 0.04
	card.Visible = false
	card.Parent = gui
	UiKit.corner(card, 14)
	stroke(card, 3, Palette.UiWarn)
	local chip = Instance.new("Frame")
	chip.Name = "Icon"
	chip.Position = UDim2.fromOffset(8, 8)
	chip.Size = UDim2.fromOffset(60, 60)
	chip.BackgroundColor3 = Palette.UiWarn
	chip.Parent = card
	UiKit.corner(chip, 10)
	stroke(chip, 2, Palette.UiInk)
	ui.icon = label(chip, "Glyph", "", UiKit.Body, Palette.UiInk, UDim2.new(1, -10, 1, -10), UDim2.fromOffset(5, 5))
	ui.icon.TextXAlignment = Enum.TextXAlignment.Center
	label(card, "Head", "TWIST!", UiKit.Header, Palette.UiWarn, UDim2.new(1, -90, 0, 16), UDim2.fromOffset(80, 6))
	ui.title = label(card, "Title", "", UiKit.Header, Palette.UiCream, UDim2.new(1, -90, 0, 30), UDim2.fromOffset(80, 22))
	stroke(ui.title, 2, Palette.UiInk, true)
	ui.hint = label(card, "Hint", "", UiKit.Body, Palette.UiCream, UDim2.new(1, -90, 0, 18), UDim2.fromOffset(80, 53))
	ui.card = card
	HudLayout.add("TopCentre", card, 27)
end

local function show(twist: string)
	local def = TwistConfig.Defs[twist]
	if not (def and ui.card) then
		return
	end
	showToken += 1
	local token = showToken
	ui.icon.Text = def.icon
	ui.title.Text = def.title
	ui.hint.Text = def.hint
	ui.card.Visible = true
	HudLayout.flush()
	UiKit.pop(ui.card, 0.35)
	task.delay(TwistConfig.CardSeconds, function()
		if token == showToken and ui.card then
			ui.card.Visible = false
			HudLayout.flush()
		end
	end)
end

local function setTorch(on: boolean)
	for _, inst in torch do
		inst:Destroy()
	end
	table.clear(torch)
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not on or not head then
		return
	end
	local spot = Instance.new("SpotLight")
	spot.Name = "TwistTorch"
	spot.Face = Enum.NormalId.Front
	spot.Range = 48
	spot.Angle = 60
	spot.Brightness = 3
	spot.Color = Color3.fromRGB(255, 244, 214)
	spot.Shadows = true
	spot.Parent = head
	table.insert(torch, spot)
	if root then
		local glow = Instance.new("PointLight")
		glow.Name = "TwistGlow"
		glow.Range = 16
		glow.Brightness = 0.7
		glow.Color = Color3.fromRGB(255, 236, 200)
		glow.Parent = root
		table.insert(torch, glow)
	end
end

local function twistNow(): string?
	local t = player:GetAttribute(ATTR)
	return if type(t) == "string" and t ~= "" then t else nil
end

-- arrival: the run's RoundState flips to Active -> show the card again
local function watchRun()
	if runConn then
		runConn:Disconnect()
		runConn = nil
	end
	local id = player:GetAttribute(Names.Attr.InstanceId)
	local runs = workspace:FindFirstChild("Runs")
	local folder = if type(id) == "string" and id ~= "" and runs then runs:FindFirstChild(id) else nil
	if not folder then
		return
	end
	local was = folder:GetAttribute("RoundState")
	runConn = folder:GetAttributeChangedSignal("RoundState"):Connect(function()
		local st = folder:GetAttribute("RoundState")
		if st == "Active" and was ~= "Active" then
			local t = twistNow()
			if t then
				show(t)
			end
		end
		was = st
	end)
end

local function onTwist()
	local t = twistNow()
	setTorch(t == "night")
	if t then
		watchRun()
		show(t)
	elseif runConn then
		runConn:Disconnect()
		runConn = nil
	end
end

function TwistController:Init(_all: { [string]: any }) end

function TwistController:Start()
	build()
	player:GetAttributeChangedSignal(ATTR):Connect(onTwist)
	player.CharacterAdded:Connect(function(char: Model)
		char:WaitForChild("Head", 10)
		setTorch(twistNow() == "night")
	end)
	if twistNow() then
		onTwist()
	end
end

-- test hook: show a twist card now (Studio screenshots)
function TwistController:_show(twist: string)
	show(twist)
end

return TwistController
