--!nonstrict
-- GameAssets: prebuilt by Forge's art pass (forge/director.py). Palette, verified sound ids, particle
-- bursts, camera shake and styled parts. Works on server and client. Do not rewrite; require it.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local GameAssets = {}

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
	C1 = Color3.fromRGB(255, 94, 126),
	C2 = Color3.fromRGB(255, 196, 41),
	C3 = Color3.fromRGB(79, 195, 247),
	C4 = Color3.fromRGB(123, 224, 90),
	C5 = Color3.fromRGB(177, 108, 255),
	C6 = Color3.fromRGB(255, 154, 60),
	C7 = Color3.fromRGB(255, 244, 224),
}

GameAssets.Sounds = {
	Coin = "rbxassetid://135483737426662",
	Buy = "rbxassetid://106979530295524",
	Gem = "rbxassetid://4612374036",
	Click = "rbxasset://sounds/volume_slider.ogg",
	Pop = "rbxassetid://135483737426662",
	Error = "rbxasset://sounds/oof.ogg",
	Whoosh = "rbxassetid://9126229255",
	Jump = "rbxasset://sounds/action_jump.mp3",
	Land = "rbxasset://sounds/action_jump_land.mp3",
	Boom = "rbxasset://sounds/impact_explosion_03.mp3",
	Splash = "rbxasset://sounds/impact_water.mp3",
	Hurt = "rbxasset://sounds/ouch.ogg",
	Win = "rbxassetid://85188102085028",
	Music = "rbxassetid://100051026808390",
}

local VOLUMES = {
	Coin = 0.6,
	Buy = 0.6,
	Gem = 0.5,
	Click = 0.5,
	Pop = 0.7,
	Error = 0.5,
	Whoosh = 0.5,
	Jump = 0.5,
	Land = 0.5,
	Boom = 0.6,
	Splash = 0.5,
	Hurt = 0.5,
	Win = 0.6,
	Music = 0.25,
}

local PITCHES = {
	Coin = 1.0,
	Buy = 1.0,
	Gem = 1.0,
	Click = 1.0,
	Pop = 1.6,
	Error = 0.7,
	Whoosh = 1.0,
	Jump = 1.0,
	Land = 1.0,
	Boom = 1.0,
	Splash = 1.0,
	Hurt = 1.1,
	Win = 1.0,
	Music = 1.0,
}

GameAssets.Textures = {
	Sparkle = "rbxasset://textures/particles/sparkles_main.dds",
	Fire = "rbxasset://textures/particles/fire_main.dds",
	Smoke = "rbxasset://textures/particles/smoke_main.dds",
}

-- Play a sound by name. With a parent (a BasePart or Attachment) it is a 3D world sound; without one it
-- plays as a UI sound (client: PlayLocalSound; server: everyone hears it from SoundService).
function GameAssets.play(name: string, parent: Instance?, pitch: number?): Sound?
	local id = GameAssets.Sounds[name]
	if not id or id == "" then
		return nil
	end
	-- counted for Forge's scene census (sounds are cleaned up after a few seconds)
	SoundService:SetAttribute("ForgeSoundsPlayed", (SoundService:GetAttribute("ForgeSoundsPlayed") or 0) + 1)
	local s = Instance.new("Sound")
	s.Name = name
	s.SoundId = id
	s.Volume = VOLUMES[name] or 0.5
	local speed
	if pitch then
		speed = pitch
	elseif name == "Coin" then
		-- livelier rapid coin pickups: random pitch 0.95-1.1
		speed = (PITCHES.Coin or 1) * (0.95 + math.random() * 0.15)
	else
		local jitter = 0.95 + math.random() * 0.1
		speed = (PITCHES[name] or 1) * jitter
	end
	s.PlaybackSpeed = speed
	if parent == nil and RunService:IsClient() then
		s.Parent = SoundService
		SoundService:PlayLocalSound(s)
		Debris:AddItem(s, 6)
		return s
	end
	s.Parent = parent or SoundService
	s:Play()
	Debris:AddItem(s, 6)
	return s
end

-- Looping background music at low volume. Idempotent: calling it again
-- reuses the existing looping "Music" sound instead of stacking a second one.
function GameAssets.music(name: string?, volume: number?): Sound?
	local id = GameAssets.Sounds[name or "Music"]
	if not id or id == "" then
		return nil
	end
	local existing = SoundService:FindFirstChild("Music")
	if existing and existing:IsA("Sound") then
		existing.Looped = true
		if volume then
			existing.Volume = volume
		end
		if not existing.IsPlaying then
			existing:Play()
		end
		return existing
	end
	local s = Instance.new("Sound")
	s.Name, s.SoundId, s.Looped, s.Volume = "Music", id, true, volume or VOLUMES.Music
	s.Parent = SoundService
	s:Play()
	return s
end

local function confettiColors()
	local P = GameAssets.Palette
	local list = { P.C1, P.C2, P.C3, P.C4, P.C5, P.C6, P.C7 }
	local keys = {}
	for i, c in ipairs(list) do
		keys[i] = ColorSequenceKeypoint.new((i - 1) / (#list - 1), c)
	end
	return ColorSequence.new(keys)
end

-- A one-shot particle burst at a part or position.
-- style (optional): nil/"sparkle" = single-colour sparkle burst, "confetti" = multicolour falling
-- confetti, "ring" = short flat high-speed ring.
function GameAssets.burst(at: BasePart | Vector3, color: Color3?, count: number?, style: string?)
	workspace:SetAttribute("ForgeBursts", (workspace:GetAttribute("ForgeBursts") or 0) + 1)
	local holder: BasePart
	if typeof(at) == "Vector3" then
		holder = Instance.new("Part")
		holder.Anchored, holder.CanCollide, holder.CanQuery, holder.CanTouch = true, false, false, false
		holder.Transparency, holder.Size, holder.Position = 1, Vector3.new(0.2, 0.2, 0.2), at
		holder.Parent = workspace
		Debris:AddItem(holder, 3)
	else
		holder = at
	end
	local a = Instance.new("Attachment")
	a.Parent = holder
	local p = Instance.new("ParticleEmitter")
	p.Texture = GameAssets.Textures.Sparkle
	p.Rate = 0
	local n = count or 20
	if style == "confetti" then
		p.Color = confettiColors()
		p.LightEmission = 0.3
		p.Speed = NumberRange.new(18, 34)
		p.Lifetime = NumberRange.new(0.9, 1.5)
		p.SpreadAngle = Vector2.new(60, 60)
		p.Acceleration = Vector3.new(0, -30, 0)
		p.Rotation = NumberRange.new(0, 360)
		p.RotSpeed = NumberRange.new(-240, 240)
		p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(0.8, 0.7), NumberSequenceKeypoint.new(1, 0) })
		p.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.8, 0), NumberSequenceKeypoint.new(1, 1) })
		n = count or 30
	elseif style == "ring" then
		p.Color = ColorSequence.new(color or GameAssets.Palette.Primary)
		p.LightEmission = 1
		p.Speed = NumberRange.new(26, 30)
		p.Lifetime = NumberRange.new(0.25, 0.4)
		p.Drag = 2
		p.SpreadAngle = Vector2.new(0, 0)
		pcall(function()
			p.Shape = Enum.ParticleEmitterShape.Disc
			p.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
			p.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
		end)
		p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.4), NumberSequenceKeypoint.new(1, 0) })
		p.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		n = count or 24
	else
		p.Color = ColorSequence.new(color or GameAssets.Palette.Primary)
		p.LightEmission, p.Speed = 1, NumberRange.new(8, 16)
		p.Lifetime, p.SpreadAngle = NumberRange.new(0.4, 0.8), Vector2.new(180, 180)
		p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	end
	p.Parent = a
	p:Emit(n)
	Debris:AddItem(a, 2)
end

-- A pulsing Highlight on a part/model to mark important targets (booth, checkpoint, gates).
-- Returns the Highlight; destroy it to stop the pulse.
function GameAssets.glow(target: Instance, color: Color3?): Highlight?
	if not target or not target.Parent then
		return nil
	end
	local old = target:FindFirstChild("ForgeGlow")
	if old and old:IsA("Highlight") then
		old.FillColor = color or GameAssets.Palette.Primary
		old.OutlineColor = GameAssets.Palette.Cream
		return old
	end
	workspace:SetAttribute("ForgeGlows", (workspace:GetAttribute("ForgeGlows") or 0) + 1)
	local h = Instance.new("Highlight")
	h.Name = "ForgeGlow"
	h.Adornee = target
	h.FillColor = color or GameAssets.Palette.Primary
	h.OutlineColor = GameAssets.Palette.Cream
	h.FillTransparency = 0.7
	h.OutlineTransparency = 0.1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = target
	local tween = TweenService:Create(
		h,
		TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ FillTransparency = 0.25, OutlineTransparency = 0.5 }
	)
	tween:Play()
	h.Destroying:Connect(function()
		tween:Cancel()
	end)
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
	bloom.Intensity, bloom.Size, bloom.Threshold = 0.6, 24, 1.6
	local cc = ensure("ColorCorrectionEffect")
	cc.Saturation, cc.Contrast, cc.Brightness = 0.15, 0.08, 0.02
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

-- Ambient loop: the server creates the persistent looping "Music" sound in SoundService (so it exists in
-- the scene from startup); the client reuses it (music() is idempotent) or creates its own if it never
-- replicates. A later explicit call from any script just reuses this sound.
if RunService:IsServer() then
	task.defer(function()
		local ok = pcall(function()
			GameAssets.music("Music", VOLUMES.Music)
		end)
		if not ok then
			warn("[GameAssets] could not start server music")
		end
	end)
elseif RunService:IsClient() then
	task.defer(function()
		local ok = pcall(function()
			-- give the server's Music sound a moment to replicate so we don't stack a second one
			SoundService:WaitForChild("Music", 3)
			GameAssets.music("Music", VOLUMES.Music)
		end)
		if not ok then
			warn("[GameAssets] could not start music")
		end
	end)
end

return GameAssets
