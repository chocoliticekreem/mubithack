--!strict
-- ColdOpenController [owner: Onboarding]. Onboarding v3's cold open: a brand-new player's first join opens on
-- a 7-second cutscene instead of a menu (Tizyz: "cutscenes help a ton with bounce rate", the threat is felt
-- before any instruction). Shots (Lib/Onboarding/ColdOpen.Shots, all from code, no assets):
--   0.0 s  wide on the burning panda house, slow push-in; the panda waves HELP! in the window, fire crackles
--   2.4 s  the fire truck pulls up from the road, lights flashing, the siren rising
--   4.8 s  close on the panda + the big title SAVE THE PANDA!
--   7.0 s  cut to you on the pavement, extinguisher in hand (FirstFireService) -> SPRAY THE FIRE!
-- Any tap / key / button skips it after ColdOpen.MinSkip s (FirstFireConfig.ColdOpen). Movement is off and
-- the HUD is hidden (HudRevealController asks :IsPlaying()) while it runs.
-- Trigger: Player attrs ColdOpen = true and FirstFire = "burning" (FirstFireService), once per session; the
-- set is Workspace.TrainingFires.Spot<FirstFireSpot> (Lib/Onboarding/PandaHouse: camera markers by name).
-- Funnel (Onboarding/Seen): "coldopen" at the start, "coldopen_skip" (value = seconds in) when skipped,
-- "coldopen_end" (value = seconds) at the end either way: the server hands over the extinguisher on it.
-- Public: ColdOpenController:IsPlaying(): boolean, :Play() (tests: replay it), .Ended (BindableEvent)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local FireCfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FirstFireConfig") :: ModuleScript) :: any
local ColdOpen = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("ColdOpen") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any

local ColdOpenController = {}
ColdOpenController.Priority = 110
local endedEvent = Instance.new("BindableEvent")
ColdOpenController.Ended = endedEvent.Event

local player = Players.LocalPlayer
local Cold = FireCfg.ColdOpen or {}
local COLD_ATTR: string = Cold.Attr or "ColdOpen"

local playing = false
local played = false

local function seen(step: string, value: number?)
	pcall(function()
		Net.event("Onboarding", "Seen"):FireServer(step, value)
	end)
end

local function controls(on: boolean)
	pcall(function()
		local pm = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 5) :: ModuleScript) :: any
		local c = pm:GetControls()
		if on then
			c:Enable()
		else
			c:Disable()
		end
	end)
end

local function findSet(timeout: number): Model?
	local t0 = os.clock()
	while os.clock() - t0 < timeout do
		local spot = player:GetAttribute(FireCfg.SpotAttr)
		local folder = workspace:FindFirstChild("TrainingFires")
		local m = folder and type(spot) == "number" and folder:FindFirstChild(`Spot{spot}`)
		if m and m:IsA("Model") and m:FindFirstChild("CamHouse") and m:FindFirstChild("LookPanda") then
			return m
		end
		task.wait(0.1)
	end
	return nil
end

local function pos(set: Model, name: string, fallback: Vector3): Vector3
	local p = set:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p.Position else fallback
end

local function ease(a: number): number
	return 1 - (1 - a) * (1 - a) -- quad out
end

------------------------------------------------------------------------------------------ the overlay

type Overlay = { gui: ScreenGui, top: Frame, bottom: Frame, title: TextLabel, sub: TextLabel, skip: TextLabel, fade: Frame, titleScale: UIScale }

local function buildOverlay(): Overlay
	local gui = UiKit.screen("ColdOpen", 70, true)
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	local function bar(name: string, anchorY: number): Frame
		local f = Instance.new("Frame")
		f.Name = name
		f.AnchorPoint = Vector2.new(0, anchorY)
		f.Position = UDim2.fromScale(0, anchorY)
		f.Size = UDim2.new(1, 0, 0.11, 0)
		f.BackgroundColor3 = Color3.new(0, 0, 0)
		f.BorderSizePixel = 0
		f.Parent = gui
		return f
	end
	local top = bar("BarTop", 0)
	local bottom = bar("BarBottom", 1)
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.AnchorPoint = Vector2.new(0.5, 0.5)
	title.Position = UDim2.fromScale(0.5, 0.3)
	title.Size = UDim2.new(0.9, 0, 0.17, 0)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.LuckiestGuy
	title.TextScaled = true
	title.Text = Cold.Title or "SAVE THE PANDA!"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.Visible = false
	title.Rotation = -3
	title.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.UiFlameTop),
		ColorSequenceKeypoint.new(0.55, Palette.UiFlameMid),
		ColorSequenceKeypoint.new(1, Palette.UiFlameLow),
	})
	grad.Parent = title
	local ts = Instance.new("UIStroke")
	ts.Thickness = 6
	ts.Color = Palette.UiInk
	ts.Parent = title
	local titleScale = Instance.new("UIScale")
	titleScale.Parent = title
	local sub = Instance.new("TextLabel")
	sub.Name = "Sub"
	sub.AnchorPoint = Vector2.new(0.5, 0.5)
	sub.Position = UDim2.fromScale(0.5, 0.42)
	sub.Size = UDim2.new(0.8, 0, 0.06, 0)
	sub.BackgroundTransparency = 1
	sub.Font = Enum.Font.FredokaOne
	sub.TextScaled = true
	sub.Text = Cold.Sub or ""
	sub.TextColor3 = Palette.UiCream
	sub.Visible = false
	sub.Parent = gui
	local ss = Instance.new("UIStroke")
	ss.Thickness = 3
	ss.Color = Palette.UiInk
	ss.Parent = sub
	local skip = Instance.new("TextLabel")
	skip.Name = "Skip"
	skip.AnchorPoint = Vector2.new(1, 0.5)
	skip.Position = UDim2.new(1, -24, 0.945, 0)
	skip.Size = UDim2.new(0.4, 0, 0.04, 0)
	skip.BackgroundTransparency = 1
	skip.Font = Enum.Font.FredokaOne
	skip.TextScaled = true
	skip.TextXAlignment = Enum.TextXAlignment.Right
	skip.TextColor3 = Palette.UiCream
	skip.TextTransparency = 1
	skip.Parent = gui
	local mode = InputHints.mode()
	skip.Text = if mode == "touch" then (Cold.SkipTouch or "Tap to skip") elseif mode == "gamepad" then (Cold.SkipPad or "Press any button to skip") else (Cold.SkipKeys or "Press any key to skip")
	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 0
	fade.BorderSizePixel = 0
	fade.ZIndex = 10
	fade.Parent = gui
	return { gui = gui, top = top, bottom = bottom, title = title, sub = sub, skip = skip, fade = fade, titleScale = titleScale }
end

------------------------------------------------------------------------------------------ the truck

type TruckAnim = { model: Model, parked: CFrame, from: CFrame, lights: { BasePart } }

local function truckOf(set: Model): TruckAnim?
	local t = set:FindFirstChild("PropTruck")
	if not t or not t:IsA("Model") then
		return nil
	end
	local parked = t:GetAttribute("ParkedCFrame")
	local fromPos = set:GetAttribute("TruckFrom")
	if typeof(parked) ~= "CFrame" then
		return nil
	end
	local from = if typeof(fromPos) == "Vector3" then CFrame.new(fromPos) * parked.Rotation else parked * CFrame.new(0, 0, 40)
	local lights = {}
	for _, d in t:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "LightRed" or d.Name == "LightBlue") then
			table.insert(lights, d)
		end
	end
	return { model = t, parked = parked, from = from, lights = lights }
end

-- the panda's arm waving (its limbs hang on Motor6Ds named "Flail", RescueNpcBuilder)
local function pandaArms(): { Motor6D }
	local id = player:GetAttribute(FireCfg.PandaAttr)
	local r = workspace:FindFirstChild("Rescuables")
	local m = r and type(id) == "string" and r:FindFirstChild(id)
	local out = {}
	if m then
		for _, d in m:GetDescendants() do
			if d:IsA("Motor6D") and d.Name == "Flail" and d.Part1 and string.sub(d.Part1.Name, 1, 3) == "Arm" then
				table.insert(out, d)
			end
		end
	end
	return out
end

local function sound(id: string?, volume: number, looped: boolean): Sound?
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Looped = looped
	s.Parent = SoundService
	s:Play()
	return s
end

------------------------------------------------------------------------------------------ play

function ColdOpenController:IsPlaying(): boolean
	return playing
end

function ColdOpenController:Play()
	if playing then
		return
	end
	playing = true
	played = true
	local set = findSet(8)
	if not set then
		-- no set (it was blocked, or very slow): straight to the fire, the server must not wait
		playing = false
		seen("coldopen_end", 0)
		endedEvent:Fire(false)
		return
	end
	local s = set :: Model
	seen("coldopen")
	controls(false)
	local cam = workspace.CurrentCamera
	local prevType = cam.CameraType
	cam.CameraType = Enum.CameraType.Scriptable
	local ov = buildOverlay()
	local truck = truckOf(s)
	if truck then
		truck.model:PivotTo(truck.from)
	end
	local arms = pandaArms()
	local crackle = sound(Cold.Crackle, 0.7, true)
	local siren = sound(Cold.Siren, 0, true)
	local camHouse = pos(s, "CamHouse", s:GetPivot().Position + Vector3.new(-20, 12, -30))
	local lookHouse = pos(s, "LookHouse", s:GetPivot().Position)
	local camTruck = pos(s, "CamTruck", camHouse)
	local camPanda = pos(s, "CamPanda", camHouse)
	local lookPanda = pos(s, "LookPanda", lookHouse)
	TweenService:Create(ov.fade, TweenInfo.new(0.5), { BackgroundTransparency = 1 }):Play()

	local t0 = os.clock()
	local skippedAt: number? = nil
	local titleShown = false
	local skipShown = false
	local inputConn = UserInputService.InputBegan:Connect(function(input: InputObject)
		local t = os.clock() - t0
		if skippedAt == nil and ColdOpen.canSkip(t, Cold.MinSkip or 2) and ColdOpen.isSkipInput(input.UserInputType.Name, input.KeyCode.Name) then
			skippedAt = t
		end
	end)
	-- the touch Jump button and thumbstick live in the TouchGui: a tap there is still a tap
	local touchConn = UserInputService.TouchTap:Connect(function()
		local t = os.clock() - t0
		if skippedAt == nil and ColdOpen.canSkip(t, Cold.MinSkip or 2) then
			skippedAt = t
		end
	end)

	local done = false
	local renderConn = RunService.RenderStepped:Connect(function()
		if done then
			return
		end
		local t = os.clock() - t0
		local shot, a = ColdOpen.shotAt(t)
		if shot == "house" then
			local from = camHouse
			local to = camHouse:Lerp(lookHouse, 0.22)
			cam.CFrame = CFrame.lookAt(from:Lerp(to, ease(a)), lookHouse)
		elseif shot == "truck" then
			if truck then
				local p = truck.from:Lerp(truck.parked, ease(math.clamp(a * 1.15, 0, 1)))
				truck.model:PivotTo(p)
				cam.CFrame = CFrame.lookAt(camTruck, p.Position + Vector3.new(0, 4, 0))
			else
				cam.CFrame = CFrame.lookAt(camTruck, lookHouse)
			end
		elseif shot == "title" then
			if truck then
				truck.model:PivotTo(truck.parked)
			end
			cam.CFrame = CFrame.lookAt(camPanda:Lerp(lookPanda, 0.25 * ease(a)), lookPanda)
			if not titleShown then
				titleShown = true
				ov.title.Visible = true
				ov.sub.Visible = true
				ov.titleScale.Scale = 0.3
				TweenService:Create(ov.titleScale, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				UiKit.pop(ov.sub, 0.4)
			end
		end
		-- the siren rises as the truck comes in; lights flash
		if siren then
			local k = math.clamp((t - 1.6) / 3.2, 0, 1)
			siren.Volume = 0.75 * k
			siren.PlaybackSpeed = 0.8 + 0.25 * k
		end
		if truck then
			local on = math.floor(t * 6) % 2 == 0
			for i, l in truck.lights do
				l.Transparency = if (i % 2 == 0) == on then 0 else 0.7
			end
		end
		for i, m in arms do
			m.Transform = CFrame.Angles(0, 0, (if i % 2 == 0 then 1 else -1) * (0.9 + 0.6 * math.sin(t * 9)))
		end
		if not skipShown and t >= (Cold.MinSkip or 2) then
			skipShown = true
			TweenService:Create(ov.skip, TweenInfo.new(0.4), { TextTransparency = 0.15 }):Play()
		end
	end)

	while os.clock() - t0 < ColdOpen.Length and skippedAt == nil and player.Parent ~= nil do
		task.wait()
	end
	local total = os.clock() - t0
	-- a quick dip to black and back to you
	TweenService:Create(ov.fade, TweenInfo.new(0.2), { BackgroundTransparency = 0 }):Play()
	task.wait(0.22)
	done = true
	renderConn:Disconnect()
	inputConn:Disconnect()
	touchConn:Disconnect()
	if truck then
		truck.model:PivotTo(truck.parked)
		for _, l in truck.lights do
			l.Transparency = 0
		end
	end
	for _, m in arms do
		m.Transform = CFrame.new()
	end
	if crackle then
		TweenService:Create(crackle, TweenInfo.new(1), { Volume = 0 }):Play()
		task.delay(1.1, function()
			crackle:Destroy()
		end)
	end
	if siren then
		TweenService:Create(siren, TweenInfo.new(1.5), { Volume = 0 }):Play()
		task.delay(1.6, function()
			siren:Destroy()
		end)
	end
	cam.CameraType = if prevType == Enum.CameraType.Scriptable then Enum.CameraType.Custom else prevType
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if hum then
		cam.CameraSubject = hum
	end
	controls(true)
	if skippedAt then
		seen("coldopen_skip", skippedAt)
	end
	seen("coldopen_end", total)
	playing = false
	endedEvent:Fire(skippedAt ~= nil)
	TweenService:Create(ov.fade, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	for _, l in { ov.title, ov.sub, ov.skip } do
		TweenService:Create(l, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
	end
	for _, b in { ov.top, ov.bottom } do
		TweenService:Create(b, TweenInfo.new(0.35), { BackgroundTransparency = 1 }):Play()
	end
	task.delay(0.4, function()
		ov.gui:Destroy()
	end)
end

local function maybePlay()
	if played or playing then
		return
	end
	if player:GetAttribute(COLD_ATTR) == true and player:GetAttribute(FireCfg.PhaseAttr) == "burning" then
		task.spawn(function()
			ColdOpenController:Play()
		end)
	end
end

function ColdOpenController:Init(_all: { [string]: any }) end

function ColdOpenController:Start()
	if Cold.Enabled == false then
		return
	end
	player:GetAttributeChangedSignal(COLD_ATTR):Connect(maybePlay)
	player:GetAttributeChangedSignal(FireCfg.PhaseAttr):Connect(maybePlay)
	maybePlay()
end

return ColdOpenController
