--!nonstrict
-- TutorialGuide: client-only first-60-seconds guide (banner + bouncing arrow + beam).
-- Telemetry note: ForgeTelemetry is server-only; the server owns the tutorial_steps counter
-- (it fires the TutorialStep remote), so this client script sends nothing.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("TutorialConfig", 10))
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme", 10))

-- Find the remote (ReplicatedStorage directly, or inside Remotes) with a timeout.
local function findRemote()
	local t0 = os.clock()
	while os.clock() - t0 < 10 do
		local r = ReplicatedStorage:FindFirstChild(Config.REMOTE_NAME)
		if not r then
			local folder = ReplicatedStorage:FindFirstChild("Remotes")
			if folder then
				r = folder:FindFirstChild(Config.REMOTE_NAME)
			end
		end
		if r and r:IsA("RemoteEvent") then
			return r
		end
		task.wait(0.5)
	end
	return nil
end

local remote = findRemote()
if not remote then
	return
end

local active = false
local finished = false
local step = 0
local sessionId = 0
local target: BasePart? = nil
local connections = {}
local gui, bannerLabel, stepLabel, arrow, beam, arrowGui, hrpAttach, arrowAttach
local shopButton: TextButton? = nil
local shopStroke: UIStroke? = nil
local shopTween: Tween? = nil

local function getHrp(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function partVisible(part: BasePart): boolean
	return part.Transparency < 0.99
end

local function billboardText(bb: BillboardGui): string
	local parts = {}
	for _, d in bb:GetDescendants() do
		if d:IsA("TextLabel") or d:IsA("TextButton") then
			table.insert(parts, d.Text)
		end
	end
	return table.concat(parts, " ")
end

local function billboardPart(bb: BillboardGui): BasePart?
	if bb.Adornee and bb.Adornee:IsA("BasePart") then
		return bb.Adornee
	end
	if bb.Parent and bb.Parent:IsA("BasePart") then
		return bb.Parent
	end
	return nil
end

local function parseCost(text: string): number?
	local num, suffix = string.match(text, "%$%s*([%d%.,]+)%s*([KkMm]?)")
	if not num then
		return nil
	end
	local n = tonumber((string.gsub(num, ",", "")))
	if not n then
		return nil
	end
	suffix = string.upper(suffix)
	if suffix == "K" then
		n *= 1000
	elseif suffix == "M" then
		n *= 1e6
	end
	return n
end

local function ownedByMe(inst: Instance): boolean
	local cur: Instance? = inst
	while cur and cur ~= Workspace do
		for _, v in cur:GetAttributes() do
			if v == player.UserId or v == player.Name or v == player.DisplayName then
				return true
			end
		end
		cur = cur.Parent
	end
	return false
end

local function nearest(list: { BasePart }, from: Vector3): BasePart?
	local best, bestD = nil, math.huge
	for _, p in list do
		local d = (p.Position - from).Magnitude
		if d < bestD then
			best, bestD = p, d
		end
	end
	return best
end

local function findGate(): BasePart?
	local hrp = getHrp()
	local from = hrp and hrp.Position or Vector3.zero
	local list = {}
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BillboardGui") and d.Enabled then
			local part = billboardPart(d)
			if part and partVisible(part) and string.find(billboardText(d), "^%s*Claim") then
				table.insert(list, part)
			end
		end
	end
	return nearest(list, from)
end

local function findCollector(): BasePart?
	local hrp = getHrp()
	local from = hrp and hrp.Position or Vector3.zero
	local mine, all = {}, {}
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BasePart") and string.find(string.lower(d.Name), "collector") then
			table.insert(all, d)
			if ownedByMe(d) then
				table.insert(mine, d)
			end
		end
	end
	return nearest(#mine > 0 and mine or all, from)
end

local function findCheapestPad(): BasePart?
	local anchor = findCollector()
	local hrp = getHrp()
	local origin = anchor and anchor.Position or (hrp and hrp.Position) or Vector3.zero
	local best, bestCost, bestD = nil, math.huge, math.huge
	for _, d in Workspace:GetDescendants() do
		if d:IsA("BillboardGui") and d.Enabled then
			local part = billboardPart(d)
			if part and partVisible(part) then
				local text = billboardText(d)
				if not string.find(string.lower(text), "rebirth") then
					local cost = parseCost(text)
					local dist = (part.Position - origin).Magnitude
					if cost and dist < 120 and (cost < bestCost or (cost == bestCost and dist < bestD)) then
						best, bestCost, bestD = part, cost, dist
					end
				end
			end
		end
	end
	return best
end

local function findShopButton(): TextButton?
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return nil
	end
	for _, d in pg:GetDescendants() do
		if d:IsA("TextButton") and d.Visible and (string.find(string.lower(d.Name), "shop") or string.find(string.upper(d.Text), "SHOP")) then
			return d
		end
	end
	return nil
end

local function cleanup()
	finished = true
	active = false
	for _, c in connections do
		c:Disconnect()
	end
	connections = {}
	if shopTween then
		shopTween:Cancel()
		shopTween = nil
	end
	if shopStroke then
		shopStroke:Destroy()
		shopStroke = nil
	end
	if arrow then
		arrow:Destroy()
		arrow = nil
	end
	if gui then
		gui:Destroy()
		gui = nil
	end
	target = nil
end

local function hideBanner()
	if not gui then
		return
	end
	local frame = gui:FindFirstChild("Banner")
	local scale = frame and frame:FindFirstChildOfClass("UIScale")
	if scale then
		local tw = TweenService:Create(scale, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.In), { Scale = 0 })
		tw:Play()
		tw.Completed:Wait()
	end
end

local function finish()
	if finished then
		return
	end
	active = false
	task.spawn(function()
		hideBanner()
		cleanup()
	end)
end

local function buildUi()
	gui = Instance.new("ScreenGui")
	gui.Name = "TutorialGuide"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 20

	local frame = Instance.new("Frame")
	frame.Name = "Banner"
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.fromScale(0.5, 0.04)
	frame.Size = UDim2.fromScale(0.5, 0.09)
	frame.BackgroundColor3 = Config.BANNER_COLOR
	frame.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, UiTheme.cornerRadius)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Color = Config.BANNER_STROKE_COLOR
	stroke.Thickness = UiTheme.stroke
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = frame
	local limit = Instance.new("UISizeConstraint")
	limit.MinSize = Vector2.new(260, 48)
	limit.Parent = frame
	local scale = Instance.new("UIScale")
	scale.Scale = 0
	scale.Parent = frame

	stepLabel = Instance.new("TextLabel")
	stepLabel.BackgroundTransparency = 1
	stepLabel.Size = UDim2.fromScale(0.14, 0.8)
	stepLabel.Position = UDim2.fromScale(0.02, 0.1)
	stepLabel.Font = UiTheme.headerFont
	stepLabel.TextScaled = true
	stepLabel.TextColor3 = Config.BANNER_STROKE_COLOR
	stepLabel.Text = "1/4"
	stepLabel.Parent = frame

	bannerLabel = Instance.new("TextLabel")
	bannerLabel.BackgroundTransparency = 1
	bannerLabel.Size = UDim2.fromScale(0.8, 0.7)
	bannerLabel.Position = UDim2.fromScale(0.18, 0.15)
	bannerLabel.Font = UiTheme.font
	bannerLabel.TextScaled = true
	bannerLabel.TextColor3 = Config.BANNER_TEXT_COLOR
	bannerLabel.Text = ""
	bannerLabel.Parent = frame
	local ts = Instance.new("UIStroke")
	ts.Thickness = 2
	ts.Color = UiTheme.ink
	ts.Parent = bannerLabel

	frame.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function buildArrow()
	arrow = Instance.new("Part")
	arrow.Name = "TutorialArrow"
	arrow.Size = Config.ARROW_SIZE
	arrow.Material = Enum.Material.Neon
	arrow.Color = Config.ARROW_COLOR
	arrow.Anchored = true
	arrow.CanCollide = false
	arrow.CanQuery = false
	arrow.CanTouch = false
	arrow.CastShadow = false
	arrow.Transparency = 1
	arrow.CFrame = CFrame.new(0, -500, 0)

	arrowAttach = Instance.new("Attachment")
	arrowAttach.Parent = arrow

	arrowGui = Instance.new("BillboardGui")
	arrowGui.Size = UDim2.fromOffset(80, 80)
	arrowGui.AlwaysOnTop = true
	arrowGui.Enabled = false
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "▼"
	lbl.TextScaled = true
	lbl.Font = UiTheme.headerFont
	lbl.TextColor3 = Config.ARROW_COLOR
	lbl.Parent = arrowGui
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = UiTheme.ink
	s.Parent = lbl
	arrowGui.Parent = arrow

	beam = Instance.new("Beam")
	beam.Attachment1 = arrowAttach
	beam.Color = ColorSequence.new(Config.BEAM_COLOR)
	beam.Width0 = Config.BEAM_WIDTH
	beam.Width1 = Config.BEAM_WIDTH
	beam.FaceCamera = true
	beam.LightEmission = 1
	beam.Enabled = false
	beam.Parent = arrow

	arrow.Parent = Workspace
end

local function setShopHighlight(btn: TextButton?)
	if btn == shopButton then
		return
	end
	if shopTween then
		shopTween:Cancel()
		shopTween = nil
	end
	if shopStroke then
		shopStroke:Destroy()
		shopStroke = nil
	end
	shopButton = btn
	if btn then
		shopStroke = Instance.new("UIStroke")
		shopStroke.Color = Config.ARROW_COLOR
		shopStroke.Thickness = 2
		shopStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		shopStroke.Parent = btn
		shopTween = TweenService:Create(shopStroke, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), { Thickness = 8 })
		shopTween:Play()
		table.insert(connections, btn.Activated:Connect(function()
			if active and step == 4 then
				finish()
			end
		end))
	end
end

local function evaluate()
	if step == 1 then
		target = findGate()
	elseif step == 2 then
		target = findCollector()
	elseif step == 3 then
		target = findCheapestPad()
	else
		target = nil
		setShopHighlight(findShopButton())
	end
end

local function popSoundId(): string?
	local ok, assets = pcall(function()
		local m = ReplicatedStorage:FindFirstChild("GameAssets")
		return m and m:IsA("ModuleScript") and require(m) or nil
	end)
	if not ok or type(assets) ~= "table" then
		return nil
	end
	local function pick(t: any): any
		if type(t) ~= "table" then
			return nil
		end
		return t.Pop or t.pop or t.POP
	end
	local id = pick(assets) or pick(assets.Sounds) or pick(assets.sounds) or pick(assets.SFX) or pick(assets.Audio)
	if type(id) == "number" then
		return "rbxassetid://" .. id
	end
	if type(id) == "string" then
		return id
	end
	return nil
end

local function playStepFeedback()
	local id = popSoundId()
	if id then
		local sound = Instance.new("Sound")
		sound.Name = "TutorialPop"
		sound.SoundId = id
		sound.Volume = 0.8
		sound.Parent = Workspace.CurrentCamera or Workspace
		sound:Play()
		task.delay(3, function()
			sound:Destroy()
		end)
	end
	if arrow then
		local sparkle = Instance.new("ParticleEmitter")
		sparkle.Name = "TutorialSparkle"
		sparkle.Rate = 0
		sparkle.Lifetime = NumberRange.new(0.4, 0.8)
		sparkle.Speed = NumberRange.new(10, 20)
		sparkle.SpreadAngle = Vector2.new(180, 180)
		sparkle.Size = NumberSequence.new(1.2, 0)
		sparkle.LightEmission = 1
		sparkle.Color = ColorSequence.new(Color3.fromRGB(255, 240, 120))
		sparkle.Parent = arrow
		sparkle:Emit(15)
		task.delay(1.5, function()
			sparkle:Destroy()
		end)
	end
end

local function setStep(n: number)
	if not active or n <= step then
		return
	end
	local advanced = step > 0
	step = n
	if advanced then
		playStepFeedback()
	end
	if bannerLabel then
		bannerLabel.Text = Config.STEPS[n] or ""
		stepLabel.Text = n .. "/4"
		local frame = gui and gui:FindFirstChild("Banner")
		local scale = frame and frame:FindFirstChildOfClass("UIScale")
		if scale then
			scale.Scale = 1.15
			TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		end
	end
	evaluate()
end

local function start()
	if active or finished then
		return
	end
	-- Skip if already rebirthed.
	local ls = player:FindFirstChild("leaderstats")
	local rb = ls and ls:FindFirstChild("Rebirths")
	if rb and rb:IsA("ValueBase") and (rb.Value :: any) > 0 then
		finished = true
		return
	end
	active = true
	sessionId += 1
	buildUi()
	buildArrow()
	setStep(1)

	task.delay(Config.TOTAL_SECONDS, function()
		if active then
			finish()
		end
	end)

	table.insert(connections, RunService.RenderStepped:Connect(function()
		if not arrow then
			return
		end
		local hrp = getHrp()
		if hrp and hrpAttach and hrpAttach.Parent ~= hrp then
			hrpAttach.Parent = hrp
		elseif hrp and not hrpAttach then
			hrpAttach = Instance.new("Attachment")
			hrpAttach.Name = "TutorialAttach"
			hrpAttach.Parent = hrp
			beam.Attachment0 = hrpAttach
		end
		if hrpAttach and beam.Attachment0 ~= hrpAttach then
			beam.Attachment0 = hrpAttach
		end
		local t = target
		if t and t.Parent and hrp then
			local bounce = math.sin(os.clock() * Config.BOUNCE_SPEED) * Config.BOUNCE_HEIGHT
			arrow.Transparency = 0
			arrow.CFrame = CFrame.new(t.Position + Vector3.new(0, Config.ARROW_HEIGHT + bounce, 0))
				* CFrame.Angles(math.rad(45), os.clock() * 2, math.rad(45))
			arrowGui.Enabled = true
			beam.Enabled = true
		else
			arrow.Transparency = 1
			arrowGui.Enabled = false
			beam.Enabled = false
		end
	end))

	local mySession = sessionId
	task.spawn(function()
		while active and sessionId == mySession do
			evaluate()
			task.wait(0.5)
		end
	end)
end

remote.OnClientEvent:Connect(function(event)
	if finished or type(event) ~= "string" then
		return
	end
	local E = Config.EVENTS
	if event == E.START then
		start()
	elseif event == E.SKIP then
		if active then
			finish()
		else
			finished = true
		end
	elseif not active then
		return
	elseif event == E.CLAIMED then
		setStep(2)
	elseif event == E.CASHED then
		setStep(3)
	elseif event == E.BOUGHT then
		setStep(4)
	end
end)
