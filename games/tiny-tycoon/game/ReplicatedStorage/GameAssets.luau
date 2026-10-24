--!nonstrict
-- GameAssets: prebuilt by Forge's art pass (forge/director.py). Palette, verified sound ids, particle
-- bursts, camera shake and styled parts. Works on server and client. Do not rewrite; require it.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameAssets = {}

-- Server-side telemetry (optional, never yields, never errors).
local telemetryFn: any = nil
local function countTelemetry(name: string, n: number?)
	if not RunService:IsServer() then
		return
	end
	if telemetryFn == nil then
		local mod = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
		if mod and mod:IsA("ModuleScript") then
			local ok, res = pcall(require, mod)
			if ok and type(res) == "table" and type(res.count) == "function" then
				telemetryFn = res.count
			else
				telemetryFn = false
			end
		else
			return -- may appear later; try again next time
		end
	end
	if telemetryFn then
		pcall(telemetryFn, name, n or 1)
	end
end

GameAssets.Palette = {
	Ink = Color3.fromRGB(28, 22, 38),
	Cream = Color3.fromRGB(255, 248, 232),
	Primary = Color3.fromRGB(255, 196, 41),
	Good = Color3.fromRGB(88, 214, 92),
	Bad = Color3.fromRGB(240, 68, 64),
	Info = Color3.fromRGB(64, 170, 255),
	Gem = Color3.fromRGB(190, 92, 255),
	Grass = Color3.fromRGB(110, 200, 90),
	Wood = Color3.fromRGB(176, 120, 72),
	Stone = Color3.fromRGB(120, 130, 150),
	C1 = Color3.fromRGB(255, 143, 208),
	C2 = Color3.fromRGB(255, 106, 43),
	C3 = Color3.fromRGB(127, 227, 255),
	C4 = Color3.fromRGB(76, 217, 100),
	C5 = Color3.fromRGB(176, 76, 255),
	C6 = Color3.fromRGB(242, 196, 107),
	C7 = Color3.fromRGB(255, 210, 63),
	C8 = Color3.fromRGB(43, 45, 66),
}

GameAssets.Sounds = {
	Coin = "rbxasset://sounds/volume_slider.ogg",
	Buy = "rbxasset://sounds/volume_slider.ogg",
	Gem = "rbxasset://sounds/volume_slider.ogg",
	Click = "rbxasset://sounds/volume_slider.ogg",
	Pop = "rbxasset://sounds/action_jump_land.mp3",
	Error = "rbxasset://sounds/oof.ogg",
	Whoosh = "rbxasset://sounds/action_jump.mp3",
	Jump = "rbxasset://sounds/action_jump.mp3",
	Land = "rbxasset://sounds/action_jump_land.mp3",
	Boom = "rbxasset://sounds/impact_explosion_03.mp3",
	Splash = "rbxasset://sounds/impact_water.mp3",
	Hurt = "rbxasset://sounds/ouch.ogg",
	Win = "rbxasset://sounds/action_get_up.mp3",
	Music = "",
}

local VOLUMES = {
	Coin = 0.6,
	Buy = 0.7,
	Gem = 0.6,
	Click = 0.5,
	Pop = 0.4,
	Error = 0.35,
	Whoosh = 0.5,
	Jump = 0.5,
	Land = 0.5,
	Boom = 0.4,
	Splash = 0.5,
	Hurt = 0.5,
	Win = 0.6,
	Music = 0.25,
}

local PITCHES = {
	Coin = 1.7,
	Buy = 1.15,
	Gem = 2.0,
	Click = 1.0,
	Pop = 1.8,
	Error = 1.3,
	Whoosh = 0.8,
	Jump = 1.0,
	Land = 1.0,
	Boom = 1.0,
	Splash = 1.0,
	Hurt = 1.0,
	Win = 1.4,
	Music = 1.0,
}

GameAssets.Textures = {
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Fire = "rbxasset://textures/particles/fire_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
}

-- Resolve a BasePart / Model / Vector3 into a part that can hold an attachment.
local function resolveHolder(at: any): BasePart?
	if typeof(at) == "Vector3" then
		local holder = Instance.new("Part")
		holder.Name = "FxAnchor"
		holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch = true, false, false, false
		holder.Transparency, holder.Size, holder.Position = 1, Vector3.new(0.2, 0.2, 0.2), at
		holder.Parent = workspace
		Debris:AddItem(holder, 4)
		return holder
	end
	if typeof(at) == "Instance" then
		if at:IsA("BasePart") then
			return at
		end
		if at:IsA("Model") then
			if at.PrimaryPart then
				return at.PrimaryPart
			end
			local best: BasePart? = nil
			local bestVol = -1
			for _, d in at:GetDescendants() do
				if d:IsA("BasePart") then
					local v = d.Size.X * d.Size.Y * d.Size.Z
					if v > bestVol then
						best, bestVol = d, v
					end
				end
			end
			return best
		end
	end
	return nil
end

-- A short-lived invisible anchored part at a world position (survives the source part being destroyed).
local function makeAnchor(pos: Vector3, life: number): BasePart
	local holder = Instance.new("Part")
	holder.Name = "FxAnchor"
	holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch = true, false, false, false
	holder.Transparency, holder.Size, holder.Position = 1, Vector3.new(0.2, 0.2, 0.2), pos
	holder.Parent = workspace
	Debris:AddItem(holder, life)
	return holder
end

-- Play a sound by name. Always creates a Sound and calls :Play(), cleaned up by Debris.
-- With a parent (BasePart / Attachment / Model) it is a 3D world sound; without one it plays as a UI
-- sound from SoundService (client: local only; server: everyone hears it).
function GameAssets.sound(name: string, parent: Instance?, pitch: number?): Sound?
	local id = GameAssets.Sounds[name]
	if not id or id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = id
	s.Volume = VOLUMES[name] or 0.5
	s.PlaybackSpeed = pitch or (PITCHES[name] or 1) * (0.95 + math.random() * 0.1)
	local target: Instance? = parent
	if target and not (target:IsA("BasePart") or target:IsA("Attachment")) then
		target = resolveHolder(target)
	end
	s.Parent = target or SoundService
	s:Play()
	Debris:AddItem(s, 6)
	countTelemetry("sounds_played", 1)
	return s
end

-- Backwards compatible alias.
function GameAssets.play(name: string, parent: Instance?, pitch: number?): Sound?
	return GameAssets.sound(name, parent, pitch)
end

-- Looping background music at low volume (call once, on the client).
function GameAssets.music(name: string?, volume: number?): Sound?
	local id = GameAssets.Sounds[name or "Music"]
	if not id or id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name, s.SoundId, s.Looped, s.Volume = "Music", id, true, volume or 0.25
	s.Parent = SoundService
	s:Play()
	return s
end

-- An expanding, fading Neon ring (flat) at a part or position. Good for upgrade / rebirth.
function GameAssets.ring(at: any, color: Color3?, maxScale: number?, seconds: number?): Part?
	local holder = resolveHolder(at)
	if not holder then
		return nil
	end
	local dur = seconds or 0.4
	local scale = maxScale or 8
	local ring = Instance.new("Part")
	ring.Name = "FxRing"
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = color or GameAssets.Palette.Primary
	ring.Anchored, ring.CanCollide, ring.CanQuery, ring.CanTouch = true, false, false, false
	ring.CastShadow = false
	ring.Size = Vector3.new(0.3, 2, 2)
	ring.CFrame = CFrame.new(holder.Position) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Transparency = 0
	ring.Parent = workspace
	TweenService:Create(ring, TweenInfo.new(dur, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.3, 2 * scale, 2 * scale),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, dur + 0.2)
	countTelemetry("rings", 1)
	return ring
end

-- A one-shot sparkle burst at a part or position (gold mixed with an optional theme colour).
-- Optional withRing adds an expanding Neon ring.
function GameAssets.burst(at: any, color: Color3?, count: number?, withRing: boolean?)
	local source = resolveHolder(at)
	if not source then
		return
	end
	-- Emit from a detached anchor so the burst survives the source (e.g. a collected cube) being destroyed.
	local holder = source
	if not (typeof(at) == "Vector3") then
		holder = makeAnchor(source.Position, 4)
	end
	local gold = GameAssets.Palette.Primary
	local a = Instance.new("Attachment")
	a.Name = "BurstAttachment"
	a.Parent = holder
	local p = Instance.new("ParticleEmitter")
	p.Name = "BurstEmitter"
	p.Texture = GameAssets.Textures.Sparkle
	if color and color ~= gold then
		p.Color = ColorSequence.new(gold, color)
	else
		p.Color = ColorSequence.new(gold)
	end
	p.LightEmission, p.Rate, p.Speed = 1, 0, NumberRange.new(12, 20)
	p.Lifetime, p.SpreadAngle = NumberRange.new(0.6, 1.0), Vector2.new(180, 180)
	p.Drag = 2
	p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	p.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.7, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	p.Enabled = false
	p.Parent = a
	p:Emit(count or 26)
	Debris:AddItem(a, 2.5)
	if withRing then
		GameAssets.ring(holder, color or gold, 8, 0.4)
	end
	countTelemetry("bursts", 1)
end

-- Multicoloured confetti plus a ring, for upgrades and rebirth.
function GameAssets.confetti(at: any, count: number?)
	local source = resolveHolder(at)
	if not source then
		return
	end
	local holder = source
	if not (typeof(at) == "Vector3") then
		holder = makeAnchor(source.Position, 4)
	end
	local P = GameAssets.Palette
	local a = Instance.new("Attachment")
	a.Name = "ConfettiAttachment"
	a.Parent = holder
	local p = Instance.new("ParticleEmitter")
	p.Name = "ConfettiEmitter"
	p.Texture = GameAssets.Textures.Sparkle
	p.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, P.C1),
		ColorSequenceKeypoint.new(0.25, P.C7),
		ColorSequenceKeypoint.new(0.5, P.C3),
		ColorSequenceKeypoint.new(0.75, P.C4),
		ColorSequenceKeypoint.new(1, P.C5),
	})
	p.LightEmission, p.Rate, p.Speed = 0.8, 0, NumberRange.new(14, 24)
	p.Lifetime, p.SpreadAngle = NumberRange.new(0.8, 1.4), Vector2.new(180, 180)
	p.Acceleration = Vector3.new(0, -12, 0)
	p.Rotation, p.RotSpeed = NumberRange.new(0, 360), NumberRange.new(-200, 200)
	p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0.2) })
	p.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	p.Enabled = false
	p.Parent = a
	p:Emit(count or 40)
	Debris:AddItem(a, 3)
	GameAssets.ring(holder, P.Primary, 8, 0.4)
	countTelemetry("bursts", 1)
end

-- A slow, permanent ambient sparkle emitter on a part/model (e.g. the plaza fountain). Returns the emitter.
function GameAssets.ambient(at: any, color: Color3?, rate: number?): ParticleEmitter?
	local holder = resolveHolder(at)
	if not holder then
		return nil
	end
	local existing = holder:FindFirstChild("AmbientSparkleAttachment")
	if existing then
		local e = existing:FindFirstChildOfClass("ParticleEmitter")
		if e then
			return e
		end
	end
	local a = Instance.new("Attachment")
	a.Name = "AmbientSparkleAttachment"
	a.Position = Vector3.new(0, holder.Size.Y / 2 + 0.5, 0)
	a.Parent = holder
	local p = Instance.new("ParticleEmitter")
	p.Name = "AmbientSparkle"
	p.Texture = GameAssets.Textures.Sparkle
	p.Color = ColorSequence.new(GameAssets.Palette.Primary, color or GameAssets.Palette.C3)
	p.LightEmission = 1
	p.Rate = rate or 8
	p.Speed = NumberRange.new(1, 3)
	p.Lifetime = NumberRange.new(2, 3.5)
	p.SpreadAngle = Vector2.new(60, 60)
	p.Acceleration = Vector3.new(0, 1.5, 0)
	p.Rotation = NumberRange.new(0, 360)
	p.RotSpeed = NumberRange.new(-40, 40)
	p.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.3, 0.9),
		NumberSequenceKeypoint.new(1, 0),
	})
	p.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.2, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	p.Parent = a
	return p
end

-- Find the plaza fountain in the workspace (by name) and attach the ambient sparkle emitter to it.
function GameAssets.sparkleFountain(color: Color3?, rate: number?): ParticleEmitter?
	for _, d in workspace:GetDescendants() do
		if (d:IsA("Model") or d:IsA("BasePart")) and string.find(string.lower(d.Name), "fountain", 1, true) then
			local e = GameAssets.ambient(d, color, rate)
			if e then
				return e
			end
		end
	end
	return nil
end

-- Add a soft glowing Highlight outline to an instance (Model or BasePart).
function GameAssets.highlight(target: Instance, color: Color3?): Highlight?
	if not target or not target.Parent then
		return nil
	end
	local h = target:FindFirstChildOfClass("Highlight")
	if not h then
		h = Instance.new("Highlight")
		h.Name = "FxHighlight"
		h.FillTransparency = 0.8
		h.OutlineTransparency = 0.2
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Adornee = target
		h.Parent = target
	end
	h.FillColor = color or GameAssets.Palette.Primary
	h.OutlineColor = color or GameAssets.Palette.Cream
	return h
end

-- Client only: a short camera shake through the humanoid's CameraOffset.
function GameAssets.shake(intensity: number?, seconds: number?)
	if not RunService:IsClient() then
		return
	end
	local char = Players.LocalPlayer and Players.LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local power, t0, dur = intensity or 0.4, os.clock(), seconds or 0.25
	local conn
	conn = RunService.RenderStepped:Connect(function()
		local left = 1 - (os.clock() - t0) / dur
		if left <= 0 then
			hum.CameraOffset = Vector3.zero
			conn:Disconnect()
			return
		end
		local k = power * left
		hum.CameraOffset = Vector3.new((math.random() - 0.5) * k, (math.random() - 0.5) * k, 0)
	end)
end

-- Server: bright, saturated lighting so the world pops (call once at startup).
function GameAssets.styleLighting()
	Lighting.ClockTime, Lighting.Brightness = 14, 2.5
	Lighting.Ambient, Lighting.OutdoorAmbient = Color3.fromRGB(120, 110, 130), Color3.fromRGB(150, 140, 160)
	Lighting.GlobalShadows = true
	local function ensure(class: string)
		local e = Lighting:FindFirstChildOfClass(class) or Instance.new(class)
		e.Parent = Lighting
		return e
	end
	local atm = ensure("Atmosphere")
	atm.Density, atm.Haze, atm.Color = 0.3, 1, Color3.fromRGB(200, 220, 255)
	local bloom = ensure("BloomEffect")
	bloom.Intensity, bloom.Size, bloom.Threshold = 0.8, 24, 1.0
	local cc = ensure("ColorCorrectionEffect")
	cc.Saturation, cc.Contrast, cc.Brightness = 0.15, 0.08, 0.02
	cc.TintColor = Color3.fromRGB(255, 248, 240)
end

-- A styled anchored part. props: Name, Size, CFrame/Position, Color, Material, Parent, Shape, CanCollide.
function GameAssets.part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored, p.TopSurface, p.BottomSurface = true, Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Material, p.Color = Enum.Material.SmoothPlastic, GameAssets.Palette.Primary
	local parent = props.Parent
	for k, v in props do
		if k ~= "Parent" then
			(p :: any)[k] = v
		end
	end
	p.Parent = parent or workspace
	return p
end

-- Tween helper used for pops: scale a part in from 0 with a Back overshoot.
function GameAssets.popIn(part: BasePart, t: number?)
	local size = part.Size
	part.Size = size * 0.05
	TweenService:Create(part, TweenInfo.new(t or 0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = size }):Play()
end

return GameAssets
