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
--[[PALETTE]]
}

GameAssets.Sounds = {
--[[SOUNDS]]
}

local VOLUMES = {
--[[VOLUMES]]
}

local PITCHES = {
--[[PITCHES]]
}

--[[ALIASES]]
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
	s.PlaybackSpeed = pitch or (PITCHES[name] or 1) * (0.95 + math.random() * 0.1)
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

-- A one-shot sparkle burst at a part or position.
function GameAssets.burst(at: BasePart | Vector3, color: Color3?, count: number?)
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
	p.Color = ColorSequence.new(color or GameAssets.Palette.Primary)
	p.LightEmission, p.Rate, p.Speed = 1, 0, NumberRange.new(8, 16)
	p.Lifetime, p.SpreadAngle = NumberRange.new(0.4, 0.8), Vector2.new(180, 180)
	p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.2), NumberSequenceKeypoint.new(1, 0) })
	p.Parent = a
	p:Emit(count or 20)
	Debris:AddItem(a, 2)
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

return GameAssets
