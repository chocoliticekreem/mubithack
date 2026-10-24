--!strict
-- TutorialBeam (client): arrow + Beam to the current tutorial target, plus a SHOP button arrow on step 4.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local TutorialConfig = require(ReplicatedStorage:WaitForChild("TutorialConfig"))
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme"))

local player = Players.LocalPlayer
local RESHOW_AFTER = 15
local LAST_STEP = 5

local HINTS: { [number]: string } = {
	[1] = "Walk to a CLAIM gate!",
	[2] = "Watch your dropper make cash!",
	[3] = "Step on the glowing pad: $10",
	[4] = "Tap the yellow SHOP button!",
	[5] = "Buy an upgrade in the SHOP!",
}

-- Telemetry (a no-op on the client, wrapped so it can never error).
local telemetry: any = nil
task.spawn(function()
	local ok, mod = pcall(function()
		local inst = ReplicatedStorage:WaitForChild("ForgeTelemetry", 5)
		if inst then
			return require(inst)
		end
		return nil
	end)
	if ok then
		telemetry = mod
	end
end)
local function count(name: string)
	if telemetry and typeof(telemetry.count) == "function" then
		pcall(function()
			telemetry.count(name, 1)
		end)
	end
end

local folder = Workspace:FindFirstChild("TutorialBeam")
if not folder then
	local f = Instance.new("Folder")
	f.Name = "TutorialBeam"
	f.Parent = Workspace
	folder = f
end
local worldFolder = folder :: Folder

local arrowPart: BasePart? = nil
local targetPart: BasePart? = nil
local attachments: { Attachment } = {}
local shopGui: ScreenGui? = nil
local shopArrow: TextLabel? = nil
local shopButton: GuiObject? = nil
local shopConn: RBXScriptConnection? = nil
local targetConn: RBXScriptConnection? = nil
local boundValue: ObjectValue? = nil

local currentStep = 0
local lastStepSeen = -1
local lastNonce: any = nil
local lastChange = os.clock()
local pulseUntil = 0
local doneCounted = false
local shopCounted = false
local lastShopSearch = 0

local function clearWorld()
	for _, a in ipairs(attachments) do
		a:Destroy()
	end
	attachments = {}
	worldFolder:ClearAllChildren()
	arrowPart = nil
	targetPart = nil
end

local function clearShop()
	if shopConn then
		shopConn:Disconnect()
		shopConn = nil
	end
	if shopGui then
		shopGui:Destroy()
		shopGui = nil
	end
	shopArrow = nil
	shopButton = nil
end

local function resolveTarget(): BasePart?
	local tv = player:FindFirstChild("TutorialTarget")
	if not tv or not tv:IsA("ObjectValue") then
		return nil
	end
	local v = tv.Value
	if v and v:IsA("BasePart") then
		return v
	end
	if v and v:IsA("Model") then
		if v.PrimaryPart then
			return v.PrimaryPart
		end
		return v:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function buildWorld(target: BasePart)
	targetPart = target
	local arrow = Instance.new("Part")
	arrow.Name = "TutorialArrow"
	arrow.Shape = Enum.PartType.Block
	arrow.Size = TutorialConfig.ARROW_SIZE
	arrow.Material = Enum.Material.Neon
	arrow.Color = TutorialConfig.ARROW_COLOR
	arrow.Anchored = true
	arrow.CanCollide = false
	arrow.CanQuery = false
	arrow.CanTouch = false
	arrow.CastShadow = false
	arrow.CFrame = CFrame.new(target.Position + Vector3.new(0, TutorialConfig.ARROW_HEIGHT, 0))

	local gui = Instance.new("BillboardGui")
	gui.Name = "Hint"
	gui.Size = UDim2.fromOffset(300, 60)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.Adornee = arrow
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = UiTheme.ink
	label.BackgroundTransparency = 0.15
	label.TextColor3 = UiTheme.accent
	label.Font = UiTheme.font
	label.TextScaled = true
	label.Text = HINTS[currentStep] or TutorialConfig.STEPS[currentStep] or ""
	UiTheme.roundify(label, 12)
	label.Parent = gui
	gui.Parent = arrow
	arrow.Parent = worldFolder
	arrowPart = arrow

	local character = player.Character
	local hrp = character and character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		local a0 = Instance.new("Attachment")
		a0.Name = "TutorialBeamStart"
		a0.Parent = hrp
		local a1 = Instance.new("Attachment")
		a1.Name = "TutorialBeamEnd"
		a1.Parent = target
		attachments = { a0, a1 }

		local beam = Instance.new("Beam")
		beam.Name = "TutorialBeamLine"
		beam.Attachment0 = a0
		beam.Attachment1 = a1
		beam.Width0 = 0.4
		beam.Width1 = 0.4
		beam.LightEmission = 1
		beam.FaceCamera = true
		beam.Color = ColorSequence.new(TutorialConfig.BEAM_COLOR)
		beam.Transparency = NumberSequence.new(0)
		beam.Segments = 10
		beam.Enabled = true
		beam.Parent = worldFolder
	end
end

local function findShopButton(): GuiObject?
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return nil
	end
	for _, d in ipairs(pg:GetDescendants()) do
		if d:IsA("TextButton") and string.find(string.upper(d.Text), "SHOP", 1, true) then
			return d
		end
	end
	return nil
end

local function buildShopArrow(button: GuiObject)
	clearShop()
	local pg = player:FindFirstChildOfClass("PlayerGui")
	if not pg then
		return
	end
	local sg = Instance.new("ScreenGui")
	sg.Name = "TutorialShopArrow"
	sg.ResetOnSpawn = false
	sg.IgnoreGuiInset = true
	sg.DisplayOrder = 50
	local arrow = Instance.new("TextLabel")
	arrow.Name = "ShopArrow"
	arrow.AnchorPoint = Vector2.new(0.5, 1)
	arrow.Size = UDim2.fromOffset(60, 50)
	arrow.BackgroundTransparency = 1
	arrow.Text = "▼"
	arrow.TextScaled = true
	arrow.Font = UiTheme.font
	arrow.TextColor3 = UiTheme.accent
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = UiTheme.ink
	stroke.Parent = arrow
	arrow.Parent = sg
	sg.Parent = pg
	shopGui = sg
	shopArrow = arrow
	shopButton = button
	if button:IsA("GuiButton") then
		shopConn = button.Activated:Connect(function()
			if currentStep == 4 and not shopCounted then
				shopCounted = true
				count("shop_opened")
			end
			clearShop()
		end)
	end
end

local function rebuild(pulse: boolean)
	clearWorld()
	clearShop()
	if currentStep < 1 or currentStep > LAST_STEP then
		return
	end
	if pulse then
		pulseUntil = os.clock() + 1.2
	end
	local target = resolveTarget()
	if target and target:IsDescendantOf(Workspace) then
		buildWorld(target)
	end
	if currentStep == 4 then
		local b = findShopButton()
		if b then
			buildShopArrow(b)
		end
	end
end

local function bindTarget()
	local tv = player:FindFirstChild("TutorialTarget")
	if tv and tv:IsA("ObjectValue") and tv ~= boundValue then
		if targetConn then
			targetConn:Disconnect()
		end
		boundValue = tv
		targetConn = tv:GetPropertyChangedSignal("Value"):Connect(function()
			rebuild(false)
		end)
		rebuild(false)
	end
end

local function onStep()
	local s = player:GetAttribute("TutorialStep")
	if typeof(s) ~= "number" then
		return
	end
	if s == lastStepSeen then
		return
	end
	lastStepSeen = s
	currentStep = s
	lastChange = os.clock()
	count("tutorial_steps")
	if s > LAST_STEP and not doneCounted then
		doneCounted = true
		count("tutorial_done")
	end
	if s == 4 then
		shopCounted = false
	end
	rebuild(false)
end

local function onNonce()
	local n = player:GetAttribute("TutorialNonce")
	if n == lastNonce then
		return
	end
	local first = lastNonce == nil
	lastNonce = n
	if first then
		return
	end
	lastChange = os.clock()
	if currentStep >= 1 and currentStep <= LAST_STEP then
		count("tutorial_reshown")
		rebuild(true)
	end
end

player:GetAttributeChangedSignal("TutorialStep"):Connect(onStep)
player:GetAttributeChangedSignal("TutorialNonce"):Connect(onNonce)
player.ChildAdded:Connect(function()
	task.defer(bindTarget)
end)

local function onCharacter(character: Model)
	task.spawn(function()
		character:WaitForChild("HumanoidRootPart", 10)
		rebuild(false)
	end)
end
player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end

RunService.Heartbeat:Connect(function()
	local now = os.clock()
	local arrow = arrowPart
	local target = targetPart
	if arrow and target then
		if not target:IsDescendantOf(Workspace) then
			clearWorld()
		else
			local bounce = math.sin(now * TutorialConfig.BOUNCE_SPEED) * TutorialConfig.BOUNCE_HEIGHT
			local scale = 1
			if now < pulseUntil then
				scale = 1 + 0.4 * math.abs(math.sin(now * 12))
			end
			arrow.Size = TutorialConfig.ARROW_SIZE * scale
			arrow.CFrame = CFrame.new(target.Position + Vector3.new(0, TutorialConfig.ARROW_HEIGHT + bounce, 0))
				* CFrame.Angles(math.rad(45), now * 2, math.rad(35))
		end
	end
	if currentStep == 4 then
		local btn = shopButton
		if btn and btn.Parent and shopArrow then
			local pos = btn.AbsolutePosition
			local size = btn.AbsoluteSize
			local bounce = math.abs(math.sin(now * 5)) * 14
			shopArrow.Position = UDim2.fromOffset(pos.X + size.X / 2, pos.Y - bounce)
		elseif not shopCounted and now - lastShopSearch > 0.5 then
			lastShopSearch = now
			local b = findShopButton()
			if b then
				buildShopArrow(b)
			end
		end
	end
end)

-- Re-show a stuck step's hint.
task.spawn(function()
	while true do
		task.wait(1)
		if currentStep >= 1 and currentStep <= LAST_STEP and os.clock() - lastChange >= RESHOW_AFTER then
			lastChange = os.clock()
			count("tutorial_reshown")
			rebuild(true)
		end
	end
end)

bindTarget()
onStep()
onNonce()
