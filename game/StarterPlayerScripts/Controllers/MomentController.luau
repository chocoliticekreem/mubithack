--!strict
-- MomentController [owner: Clippable]. Big moments for clips (Tizyz rule #5): when something dramatic or
-- funny happens near you, a ~1 s client-only cinematic beat frames it. The server sim never slows.
--   * camera: FOV punch-in eased back out (after every other camera script) + a FirstPersonController shake
--   * slow-mo feel (Full effects only): particles near it run at MomentConfig.SlowTimeScale, nearby sounds
--     drop in pitch, thin letterbox bars slide in, a little extra contrast
--   * one big caption (the one moment caption style: LuckiestGuy, flame gradient, ink stroke, like the
--     results title) + an optional who-line, and a crowd "OOOH"
-- Sources (existing remotes, nothing new on the server):
--   Hazard/Fx "backdraft" (with direction) BACKDRAFT!!, "backdraft" (MissionService set piece, no direction)
--   FLASHOVER!, "explosion" KABOOM!, "ceiling_collapse" CEILING CAVE-IN! (after its warning);
--   Rescue/Fx "yeet" YEET!; Hands/Fx "slap" on a player SLAPPED!; Squad/Fx "down" with a teammate culprit
--   BLAMED!.
-- Rules (Lib/MomentRules, spec-tested): once per MomentConfig.CooldownSeconds per player; never while
-- driving fast, over a modal or the results screen; POP-UPS: OFF = none, MINIMAL = only ones you're in;
-- EFFECTS: CALM (ClientLib/Calm, phones) = shorter, smaller caption, softer camera, no slow-mo / bars.
-- Counters (ForgeTelemetry, client): moment_shown, moment_<kind>.
-- Studio test: Player attr MomentTest = true skips the cooldown.
-- Test hook: MomentController:_play(kind, sub?) shows the beat now (no rules).
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MomentConfig") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local Calm = require(ClientLib:WaitForChild("Calm") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local WorldPopup = require(ClientLib:WaitForChild("WorldPopup") :: ModuleScript) :: any
local MomentRules = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("MomentRules") :: ModuleScript)

local MomentController = {}
MomentController.Priority = 90

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}
local rules = MomentRules.new()
local playToken = 0

local function myRoot(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function rootOfUser(userId: number): BasePart?
	local p = Players:GetPlayerByUserId(userId)
	local char = p and p.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function nameOf(userId: any): string
	local p = type(userId) == "number" and Players:GetPlayerByUserId(userId) or nil
	return if p then p.DisplayName else "Someone"
end

local function driveSpeed(): number
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	if seat and seat:IsA("VehicleSeat") then
		return seat.AssemblyLinearVelocity.Magnitude
	end
	return 0
end

local function popupMode(): string
	local ok, m = pcall(WorldPopup.getMode)
	return if ok and type(m) == "string" then m else "Normal"
end

local function busy(): boolean
	local ok, modal = pcall(HudLayout.modalOpen)
	if ok and modal then
		return true
	end
	local pg = player:FindFirstChildOfClass("PlayerGui")
	return pg ~= nil and pg:FindFirstChild("Results") ~= nil
end

------------------------------------------------------------------------------------------- the beat

local function shake(trauma: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, trauma, seconds)
	end
end

-- FOV offset on top of whatever the camera scripts set this frame (they write it absolutely every frame;
-- if nobody did, the value we wrote last frame is still there and we reuse its base).
local function fovPunch(add: number, seconds: number, token: number)
	if math.abs(add) < 0.1 then
		return
	end
	local name = "MomentFov"
	pcall(RunService.UnbindFromRenderStep, RunService, name)
	local t0 = os.clock()
	local lastBase: number? = nil
	local lastWritten: number? = nil
	RunService:BindToRenderStep(name, Enum.RenderPriority.Camera.Value + 30, function()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local cur = cam.FieldOfView
		local base = if lastWritten and lastBase and math.abs(cur - lastWritten) < 0.01 then lastBase else cur
		local t = (os.clock() - t0) / seconds
		if t >= 1 or token ~= playToken then
			cam.FieldOfView = base
			RunService:UnbindFromRenderStep(name)
			return
		end
		-- snap in fast (first 15%), hold, then ease back out
		local k = if t < 0.15 then t / 0.15 else 1 - ((t - 0.15) / 0.85) ^ 2
		local fov = math.clamp(base + add * k, 20, 110)
		cam.FieldOfView = fov
		lastBase, lastWritten = base, fov
	end)
end

-- particles / sounds near the moment run slow for the beat (client copies only; the server never slows)
local function slowNearby(pos: Vector3, seconds: number)
	local radius = tonumber(Cfg.SlowRadius) or 40
	local scale = tonumber(Cfg.SlowTimeScale) or 0.3
	local pitch = tonumber(Cfg.SlowPitch) or 0.75
	local ok, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(pos, radius)
	end)
	if not ok or type(parts) ~= "table" then
		return
	end
	local emitters: { [ParticleEmitter]: number } = {}
	local sounds: { [Sound]: number } = {}
	local function take(inst: Instance)
		if inst:IsA("ParticleEmitter") and emitters[inst] == nil then
			emitters[inst] = inst.TimeScale
			inst.TimeScale = inst.TimeScale * scale
		elseif inst:IsA("Sound") and sounds[inst] == nil and inst.IsPlaying then
			sounds[inst] = inst.PlaybackSpeed
			inst.PlaybackSpeed = inst.PlaybackSpeed * pitch
		end
	end
	for i, part in parts :: { BasePart } do
		if i > 400 then
			break
		end
		for _, c in part:GetChildren() do
			take(c)
			if c:IsA("Attachment") then
				for _, cc in c:GetChildren() do
					take(cc)
				end
			end
		end
	end
	task.delay(seconds, function()
		for e, was in emitters do
			if e.Parent then
				e.TimeScale = was
			end
		end
		for s, was in sounds do
			if s.Parent then
				s.PlaybackSpeed = was
			end
		end
	end)
end

local function screenGui(): ScreenGui
	local pg = player:WaitForChild("PlayerGui")
	local g = pg:FindFirstChild("Moments") :: ScreenGui?
	if g then
		return g
	end
	-- under modals (HudLayout.ModalOrder 50) and HazardFx flashes (50), over the HUD. Full-bleed bars:
	-- no ViewportScale (it would shrink them); the caption scales itself (viewScale).
	local gui = UiKit.screen("Moments", 32, true)
	local vs = gui:FindFirstChild("ViewportScale")
	if vs then
		vs:Destroy()
	end
	return gui
end

local function viewScale(): number
	local cam = workspace.CurrentCamera
	if not cam then
		return 1
	end
	local v = cam.ViewportSize
	return math.clamp(math.min(v.X / 1280, v.Y / 720), 0.45, 1.4)
end

local function letterbox(gui: ScreenGui, seconds: number)
	for i, y in { 0, 1 } do
		local bar = Instance.new("Frame")
		bar.Name = `Bar{i}`
		bar.AnchorPoint = Vector2.new(0, y)
		bar.Position = UDim2.fromScale(0, y)
		bar.Size = UDim2.new(1, 0, 0, 0)
		bar.BackgroundColor3 = Color3.new(0, 0, 0)
		bar.BorderSizePixel = 0
		bar.ZIndex = 1
		bar.Parent = gui
		UiKit.tween(bar, 0.15, { Size = UDim2.new(1, 0, 0.075, 0) })
		task.delay(seconds, function()
			local t = UiKit.tween(bar, 0.3, { Size = UDim2.new(1, 0, 0, 0) })
			t.Completed:Connect(function()
				bar:Destroy()
			end)
		end)
	end
end

local function grade(seconds: number)
	local cc = Instance.new("ColorCorrectionEffect")
	cc.Name = "MomentGrade"
	cc.Contrast = 0
	cc.Saturation = 0
	cc.Parent = Lighting
	UiKit.tween(cc, 0.12, { Contrast = 0.15, Saturation = 0.25 })
	task.delay(seconds, function()
		local t = UiKit.tween(cc, 0.35, { Contrast = 0, Saturation = 0 })
		t.Completed:Connect(function()
			cc:Destroy()
		end)
	end)
end

-- The one moment caption style: big LuckiestGuy word, flame gradient, thick ink stroke, slammed in
-- from 2.4x, tilted; an optional cream who-line under it.
local function caption(gui: ScreenGui, word: string, sub: string?, size: number, seconds: number)
	local old = gui:FindFirstChild("Caption")
	if old then
		old:Destroy()
	end
	local holder = Instance.new("Frame")
	holder.Name = "Caption"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.3)
	holder.Size = UDim2.fromOffset(1000, size + 50)
	holder.Rotation = -5
	holder.ZIndex = 5
	holder.Parent = gui
	local word_ = UiKit.label(holder, "Word", word, UDim2.new(1, 0, 0, size + 10), UDim2.fromOffset(0, 0), {
		font = UiKit.Header,
		textSize = size,
		color = Color3.new(1, 1, 1),
		stroke = true,
		strokeThickness = if size >= 80 then 6 else 4,
	})
	word_.ZIndex = 6
	local flame = Instance.new("UIGradient")
	flame.Rotation = 90
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.UiFlameTop),
		ColorSequenceKeypoint.new(0.5, Palette.UiFlameMid),
		ColorSequenceKeypoint.new(1, Palette.UiFlameLow),
	})
	flame.Parent = word_
	local line: TextLabel? = nil
	if sub and sub ~= "" then
		line = UiKit.label(holder, "Sub", sub, UDim2.new(1, 0, 0, 34), UDim2.fromOffset(0, size + 8), {
			font = UiKit.Header,
			textSize = math.floor(size * 0.32),
			color = Palette.UiCream,
			stroke = true,
			strokeThickness = 3,
		})
		line.ZIndex = 6
	end
	local scale = Instance.new("UIScale")
	scale.Scale = 2.4
	scale.Parent = holder
	local fit = viewScale()
	scale.Scale = 2.4 * fit
	UiKit.tween(scale, 0.18, { Scale = fit }, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	task.delay(seconds, function()
		if not holder.Parent then
			return
		end
		UiKit.tween(holder, 0.3, { Position = UDim2.fromScale(0.5, 0.26) })
		UiKit.tween(word_, 0.3, { TextTransparency = 1 })
		local s = word_:FindFirstChildOfClass("UIStroke")
		if s then
			UiKit.tween(s, 0.3, { Transparency = 1 })
		end
		if line then
			UiKit.tween(line, 0.3, { TextTransparency = 1 })
			local ls = line:FindFirstChildOfClass("UIStroke")
			if ls then
				UiKit.tween(ls, 0.3, { Transparency = 1 })
			end
		end
		task.delay(0.32, function()
			holder:Destroy()
		end)
	end)
end

local function play(kind: string, pos: Vector3?, sub: string?, calm: boolean)
	local def = Cfg.Kinds[kind]
	if type(def) ~= "table" then
		return
	end
	playToken += 1
	local token = playToken
	local beat = MomentRules.beat(Cfg, calm)
	local gui = screenGui()
	caption(gui, def.caption, sub, beat.captionSize, Calm.seconds(beat.seconds + 0.6, 1.1))
	fovPunch(beat.fov, beat.seconds, token)
	shake(beat.shake, beat.seconds * 0.6)
	if beat.slow then
		letterbox(gui, beat.seconds)
		grade(beat.seconds)
		if pos then
			slowNearby(pos, beat.seconds)
		end
	end
	UiKit.sound(Cfg.OoohSoundId, beat.ooohVolume, 1)
	Telemetry.count("moment_shown")
	Telemetry.count(`moment_{kind}`)
end

-- involved: you are in it (actor / victim / in the blast); pos: where it happened
local function moment(kind: string, pos: Vector3?, involved: boolean, sub: string?)
	local root = myRoot()
	local dist = if pos and root then (root.Position - pos).Magnitude else math.huge
	local calm = Calm.on()
	local verdict = MomentRules.admit(rules, os.clock(), kind, {
		involved = involved,
		distance = dist,
		popups = popupMode(),
		calm = calm,
		busy = busy(),
		driveSpeed = driveSpeed(),
		noCooldown = RunService:IsStudio() and player:GetAttribute("MomentTest") == true,
	}, Cfg)
	if not verdict.show then
		return
	end
	local ok, err = pcall(play, kind, pos, sub, calm)
	if not ok then
		warn(`[MomentController] {kind}: {err}`)
	end
end

------------------------------------------------------------------------------------------- sources

local function near(pos: Vector3, studs: number): boolean
	local r = myRoot()
	return r ~= nil and (r.Position - pos).Magnitude <= studs
end

local function onHazard(hazardId: string, pos: any, params: any)
	if typeof(pos) ~= "Vector3" then
		return
	end
	local kind = MomentRules.classifyHazard(hazardId, params)
	if kind == "collapse" then
		local warnS = type(params) == "table" and tonumber(params.warn) or 2.5
		task.delay(warnS or 2.5, function()
			moment("collapse", pos, near(pos, 14), nil)
		end)
	elseif kind then
		moment(kind, pos, near(pos, 14), nil)
	end
end

local KIND_WORD = { Civilian = "someone", Dog = "a dog", Cat = "a cat", Panda = "a panda" }

local function onRescue(kind: string, pos: any, data: any)
	if kind ~= "yeet" or typeof(pos) ~= "Vector3" or type(data) ~= "table" then
		return
	end
	local by = tonumber(data.by) or 0
	local what = KIND_WORD[tostring(data.kind)] or "someone"
	moment("yeet", pos, by == player.UserId, `{nameOf(by)} yeeted {what} to safety!`)
end

local function onHands(kind: string, pos: any, victimId: any)
	local v = tonumber(victimId) or 0
	if kind ~= "slap" or v == 0 or typeof(pos) ~= "Vector3" then
		return
	end
	moment("slap", pos, v == player.UserId, `{nameOf(v)} got SLAPPED!`)
end

local function onSquad(kind: string, userId: any, _cause: any, culprit: any)
	local victim = tonumber(userId) or 0
	local by = tonumber(culprit) or 0
	if kind ~= "down" or by == 0 or by == victim then
		return
	end
	local root = rootOfUser(victim)
	local me = player.UserId
	moment("blamed", if root then root.Position else nil, me == victim or me == by, `{nameOf(by)}'s fault! {nameOf(victim)} is down!`)
end

local function listen(ns: string, name: string, fn: (...any) -> ())
	task.spawn(function()
		Net.event(ns, name).OnClientEvent:Connect(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				warn(`[MomentController] {ns}/{name}: {err}`)
			end
		end)
	end)
end

function MomentController:Init(all: { [string]: any })
	controllers = all
end

function MomentController:Start()
	listen("Hazard", "Fx", onHazard)
	listen("Rescue", "Fx", onRescue)
	listen("Hands", "Fx", onHands)
	listen("Squad", "Fx", onSquad)
end

-- Test hook: the beat right now, no rules (calm follows ClientLib/Calm).
function MomentController:_play(kind: string, sub: string?)
	local r = myRoot()
	play(kind, if r then r.Position else nil, sub, Calm.on())
end

return MomentController
