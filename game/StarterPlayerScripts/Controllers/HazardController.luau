--!strict
-- HazardController [owner: GF]. Client-only hazard juice (docs/game/02 §6 "Electric water", §8 juice table).
--   Hazard/Zapped (victim, culprit UserIds): skeleton flash on the victim (white bones, body flickers at
--     12 Hz for 0.6 s) + crackling arcs; if it's you: cyan flash -> desaturate, camera shake.
--   Hazard/Fx (hazardId, position, params): explosion flash/blur/shake by distance, fire tornado wind
--     shake + orange vignette while near, tidal wave rumble + blue splash when it passes you, backdraft
--     flash, ceiling-collapse rumble, spark bursts.
--   Live puddles: WetFloor parts within HazardConfig.ZapRadius of a FuseBox with Power = true glow cyan,
--     flicker and crackle (purely visual; HazardService decides who gets zapped).
-- Camera shake goes through FirstPersonController:Shake (nil-guarded). Nothing here affects gameplay.
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local HazardConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HazardConfig") :: ModuleScript)

local HazardController = {}
HazardController.Priority = 100

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

local SHOCK = Color3.fromHex("#CFFFFF")
local CYAN = Color3.fromHex("#7FF5F0")
local ORANGE = Color3.fromRGB(255, 122, 31)
local WATER = Color3.fromRGB(80, 160, 230)

local function shake(magnitude: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, magnitude, seconds)
	end
end

local function myRoot(): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function distTo(pos: Vector3): number
	local r = myRoot()
	return if r then (r.Position - pos).Magnitude else math.huge
end

-- Full-screen overlay frame (one ScreenGui, made on first use).
local overlay: Frame? = nil
local function screenFlash(color: Color3, from: number, seconds: number)
	if not overlay then
		local gui = Instance.new("ScreenGui")
		gui.Name = "HazardFx"
		gui.IgnoreGuiInset = true
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 50
		local f = Instance.new("Frame")
		f.Name = "Flash"
		f.Size = UDim2.fromScale(1, 1)
		f.BorderSizePixel = 0
		f.BackgroundTransparency = 1
		f.Parent = gui
		gui.Parent = player:WaitForChild("PlayerGui")
		overlay = f
	end
	local f = overlay :: Frame
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1 - from
	TweenService:Create(f, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
end

local function colorCorrection(): ColorCorrectionEffect
	local cc = Lighting:FindFirstChild("HazardCC") :: ColorCorrectionEffect?
	if cc then
		return cc
	end
	local made = Instance.new("ColorCorrectionEffect")
	made.Name = "HazardCC"
	made.Parent = Lighting
	return made
end

local function blurPulse(size: number, seconds: number)
	local b = Lighting:FindFirstChild("HazardBlur") :: BlurEffect?
	if not b then
		local made = Instance.new("BlurEffect")
		made.Name = "HazardBlur"
		made.Size = 0
		made.Parent = Lighting
		b = made
	end
	local blur = b :: BlurEffect
	blur.Size = size
	TweenService:Create(blur, TweenInfo.new(seconds), { Size = 0 }):Play()
end

---------------------------------------------------------------------------------------------- zap

local function arcs(parent: BasePart, count: number, seconds: number)
	local atts: { Attachment } = {}
	for i = 1, count * 2 do
		local a = Instance.new("Attachment")
		a.Name = "ZapArc"
		a.Parent = parent
		atts[i] = a
	end
	local beams: { Beam } = {}
	for i = 1, count do
		local b = Instance.new("Beam")
		b.Attachment0 = atts[i * 2 - 1]
		b.Attachment1 = atts[i * 2]
		b.Width0 = 0.15
		b.Width1 = 0.15
		b.LightEmission = 1
		b.Color = ColorSequence.new(SHOCK)
		b.FaceCamera = true
		b.Segments = 6
		b.Parent = parent
		beams[i] = b
	end
	local light = Instance.new("PointLight")
	light.Color = CYAN
	light.Range = 14
	light.Brightness = 4
	light.Parent = parent
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < seconds and parent.Parent do
			local half = parent.Size / 2
			for _, a in atts do
				a.Position = Vector3.new((math.random() * 2 - 1) * (half.X + 1), (math.random() * 2 - 1) * (half.Y + 2), (math.random() * 2 - 1) * (half.Z + 1))
			end
			for _, b in beams do
				b.CurveSize0 = math.random(-3, 3)
				b.CurveSize1 = math.random(-3, 3)
			end
			light.Brightness = 2 + math.random() * 4
			task.wait(0.05)
		end
		for _, a in atts do
			a:Destroy()
		end
		for _, b in beams do
			b:Destroy()
		end
		light:Destroy()
	end)
end

-- White "skeleton" bones inside each limb; the body flickers see-through at 12 Hz (cartoon x-ray).
local function skeletonFlash(char: Model, seconds: number)
	local bones: { BasePart } = {}
	local limbs: { BasePart } = {}
	for _, d in char:GetChildren() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			table.insert(limbs, d)
			local bone = Instance.new("Part")
			bone.Name = "ZapBone"
			bone.Shape = Enum.PartType.Cylinder
			local long = math.max(d.Size.X, d.Size.Y, d.Size.Z)
			bone.Size = Vector3.new(long * 0.85, 0.35, 0.35)
			bone.Color = SHOCK
			bone.Material = Enum.Material.Neon
			bone.CanCollide = false
			bone.CanQuery = false
			bone.CanTouch = false
			bone.Massless = true
			-- align the cylinder axis (X) with the limb's longest axis
			local rot = if long == d.Size.Y then CFrame.Angles(0, 0, math.pi / 2) elseif long == d.Size.Z then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity
			bone.CFrame = d.CFrame * rot
			local w = Instance.new("WeldConstraint")
			w.Part0 = d
			w.Part1 = bone
			w.Parent = bone
			bone.Transparency = 1
			bone.Parent = char
			table.insert(bones, bone)
		end
	end
	local hl = Instance.new("Highlight")
	hl.Name = "ZapHighlight"
	hl.FillColor = SHOCK
	hl.OutlineColor = Color3.new(0, 0, 0)
	hl.FillTransparency = 0.2
	hl.DepthMode = Enum.HighlightDepthMode.Occluded
	hl.Parent = char
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		arcs(root, 4, seconds)
	end
	task.spawn(function()
		local on = false
		local t0 = os.clock()
		while os.clock() - t0 < seconds and char.Parent do
			on = not on
			for _, b in bones do
				b.Transparency = if on then 0 else 1
			end
			for _, l in limbs do
				l.LocalTransparencyModifier = if on then 0.75 else 0
			end
			hl.Enabled = not on
			task.wait(1 / 12)
		end
		for _, b in bones do
			b:Destroy()
		end
		for _, l in limbs do
			if l.Parent then
				l.LocalTransparencyModifier = 0
			end
		end
		hl:Destroy()
	end)
end

local function onZapped(victimId: number, _culpritId: number?)
	local victim = Players:GetPlayerByUserId(victimId)
	local char = victim and victim.Character
	if char then
		skeletonFlash(char, 0.6)
	end
	if victim == player then
		local cc = colorCorrection()
		cc.Enabled = true
		cc.Brightness = 0.6
		cc.TintColor = SHOCK
		cc.Saturation = 0
		cc.Contrast = 0
		shake(2, 0.6)
		screenFlash(SHOCK, 0.6, 0.25)
		task.delay(0.08, function()
			cc.Brightness = 0
			cc.TintColor = Color3.new(1, 1, 1)
			cc.Saturation = -1
			cc.Contrast = 0.4
			task.wait(0.6)
			TweenService:Create(cc, TweenInfo.new(0.3), { Saturation = 0, Contrast = 0 }):Play()
		end)
	end
end

---------------------------------------------------------------------------------------------- fx

local function sparks(pos: Vector3, color: Color3, n: number)
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.Position = pos
	p.Parent = workspace
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(color)
	e.LightEmission = 1
	e.Size = NumberSequence.new(0.4, 0)
	e.Speed = NumberRange.new(15, 35)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Lifetime = NumberRange.new(0.3, 0.6)
	e.Acceleration = Vector3.new(0, -60, 0)
	e.Rate = 0
	e.Parent = p
	e:Emit(n)
	task.delay(1, function()
		p:Destroy()
	end)
end

local function followWhileAlive(model: Instance?, every: number, fn: (Vector3) -> ())
	if typeof(model) ~= "Instance" or not (model :: Instance):IsA("Model") then
		return
	end
	local m = model :: Model
	task.spawn(function()
		while m.Parent do
			fn(m:GetPivot().Position)
			task.wait(every)
		end
	end)
end

local function onFx(hazardId: string, pos: Vector3, params: { [string]: any }?)
	local p = params or {}
	local d = distTo(pos)
	if hazardId == "explosion" then
		local radius = tonumber(p.radius) or HazardConfig.ExplosionRadius
		local reach = radius * (if p.big then 8 else 5)
		if d < reach then
			local k = 1 - d / reach
			if p.big then
				-- the tanker: a white-out flash fading through orange, a long heavy shake, a blur hit
				shake(3 + 7 * k, 1.8)
				screenFlash(Color3.new(1, 1, 0.95), math.min(1, 0.4 + 0.7 * k), 0.5)
				task.delay(0.35, function()
					screenFlash(ORANGE, 0.45 * k + 0.1, 1.2)
				end)
				blurPulse(6 + 18 * k, 1.1)
			else
				shake(4 * k, 0.8)
				screenFlash(Color3.new(1, 1, 0.9), 0.85 * k, 0.15)
				blurPulse(8 * k, 0.3)
			end
		end
		sparks(pos, ORANGE, if p.big then 120 else 40)
	elseif hazardId == "electrocution" then
		sparks(pos + Vector3.new(0, 1, 0), SHOCK, 25)
	elseif hazardId == "fire_tornado" then
		followWhileAlive(p.model, 0.25, function(at: Vector3)
			local dd = distTo(at)
			if dd < 70 then
				shake(0.6 * (1 - dd / 70) + 0.2, 0.3)
				screenFlash(ORANGE, 0.12 * (1 - dd / 70), 0.25)
			end
		end)
	elseif hazardId == "tidal_wave" then
		local splashed = false
		followWhileAlive(p.model, 0.1, function(at: Vector3)
			local dd = distTo(at)
			if dd < 160 then
				shake(1.2 * (1 - dd / 160) + 0.2, 0.15)
			end
			if not splashed and dd < 25 then
				splashed = true
				screenFlash(WATER, 0.7, 1.2)
				blurPulse(10, 0.8)
			end
		end)
	elseif hazardId == "backdraft" then
		if d < HazardConfig.BackdraftRange * 2 then
			shake(2.5, 0.5)
			screenFlash(ORANGE, 0.6, 0.35)
		end
	elseif hazardId == "ceiling_collapse" then
		if d < 45 then
			shake(1, tonumber(p.warn) or 2.5)
		end
	end
end

---------------------------------------------------------------------------------------------- live puddles

local liveFx: { [BasePart]: { Instance } } = {}

local function setLive(w: BasePart, on: boolean)
	local have = liveFx[w]
	if on and not have then
		local sb = Instance.new("SelectionBox")
		sb.Name = "LiveGlow"
		sb.Adornee = w
		sb.Color3 = CYAN
		sb.LineThickness = 0.08
		sb.SurfaceColor3 = CYAN
		sb.SurfaceTransparency = 0.7
		sb.Parent = w
		local light = Instance.new("PointLight")
		light.Name = "LiveLight"
		light.Color = CYAN
		light.Range = 14
		light.Brightness = 3
		light.Parent = w
		liveFx[w] = { sb, light }
	elseif not on and have then
		for _, i in have do
			i:Destroy()
		end
		liveFx[w] = nil
	end
end

local function powered(box: Instance): boolean
	local v = box:GetAttribute(Names.Attr.Power)
	if v == nil and box.Parent then
		v = box.Parent:GetAttribute(Names.Attr.Power)
	end
	return v ~= false
end

local function puddleLoop()
	local tick = 0
	while true do
		task.wait(0.1)
		tick += 1
		-- flicker every frame-ish, recompute who is live 4x per second
		for w, fxs in liveFx do
			if not w.Parent then
				liveFx[w] = nil
				continue
			end
			local light = fxs[2] :: PointLight
			light.Brightness = 1 + math.random() * 4
		end
		if tick % 3 ~= 0 then
			continue
		end
		local boxes: { BasePart } = {}
		for _, b in CollectionService:GetTagged(Names.Tag.FuseBox) do
			local part = if b:IsA("BasePart") then b elseif b:IsA("Model") then b.PrimaryPart or b:FindFirstChildWhichIsA("BasePart", true) else nil
			if part and powered(b) then
				table.insert(boxes, part)
			end
		end
		local me = myRoot()
		for _, w in CollectionService:GetTagged(Names.Tag.WetFloor) do
			if not w:IsA("BasePart") then
				continue
			end
			local live = false
			if me and (w.Position - me.Position).Magnitude < 250 then
				for _, b in boxes do
					if (w.Position - b.Position).Magnitude <= HazardConfig.ZapRadius then
						live = true
						break
					end
				end
			end
			setLive(w, live)
			if live and math.random() < 0.1 then
				arcs(w, 2, 0.3)
			end
		end
		for w in liveFx do
			if not w:HasTag(Names.Tag.WetFloor) then
				setLive(w, false)
			end
		end
	end
end

function HazardController:Init(all: { [string]: any })
	controllers = all
end

-- Shocked (first touch of a live puddle): the victim buzzes in place, skeleton flickering and arms
-- jittering, for every viewer; the victim's own camera rattles. They can still stagger off.
local function shockLoop()
	local jitter: { [Motor6D]: CFrame } = {}
	while true do
		task.wait(0.12)
		local live: { [Motor6D]: boolean } = {}
		for _, p in Players:GetPlayers() do
			local char = p.Character
			if p:GetAttribute("Shocked") == true and char then
				skeletonFlash(char, 0.08)
				for _, name in { "RightShoulder", "LeftShoulder", "Waist", "Neck" } do
					local m = char:FindFirstChild(name, true)
					if m and m:IsA("Motor6D") then
						jitter[m] = jitter[m] or m.C0
						live[m] = true
						m.C0 = jitter[m] * CFrame.Angles(math.rad(math.random(-25, 25)), math.rad(math.random(-20, 20)), math.rad(math.random(-30, 30)))
					end
				end
				if p == player then
					shake(1.2, 0.15)
				end
			end
		end
		for m, c0 in jitter do
			if not live[m] then
				if m.Parent then
					m.C0 = c0
				end
				jitter[m] = nil
			end
		end
	end
end

function HazardController:Start()
	task.spawn(puddleLoop)
	task.spawn(shockLoop)
	local ok, Zapped = pcall(Net.event, "Hazard", "Zapped")
	if ok then
		(Zapped :: RemoteEvent).OnClientEvent:Connect(onZapped)
	end
	local ok2, Fx = pcall(Net.event, "Hazard", "Fx")
	if ok2 then
		(Fx :: RemoteEvent).OnClientEvent:Connect(onFx)
	end
	-- keep the effects from sticking after a respawn
	player.CharacterAdded:Connect(function()
		local cc = Lighting:FindFirstChild("HazardCC") :: ColorCorrectionEffect?
		if cc then
			cc.Saturation = 0
			cc.Contrast = 0
			cc.Brightness = 0
			cc.TintColor = Color3.new(1, 1, 1)
		end
	end)
end

return HazardController
