--!strict
-- FireFxController [owner: G1]. Client-only fire visuals. Nothing here affects gameplay.
--
-- Reads: tag Burning, attrs FireLevel (1..3) and Charred (FireService); FireConfig.Fx*/MaxClient*;
--        Palette.Fire*/Smoke*/Charred*.
-- Writes (local only): per nearby burning part
--   * ParticleEmitters "FlameCore" + "FlameLicks" on the part itself (Box surface, so the whole part burns)
--   * Attachment "FireFx" on the top face with "Embers", "Smoke" (darkens with FireLevel), "HeatHaze"
--     and a flickering PointLight on the nearest part of each ~FxLightClusterRadius cluster (at most
--     MaxClientLights; the nearest MaxShadowLights cast shadows)
--   * a progressive scorch tint on the part while it burns
-- On put-out (tag removed, not Charred): one-shot Attachment "SteamFx" (puff + lingering wisps + hiss),
--   and with FireConfig.FxPoofChance a tiny cartoon "poof" smoke ring.
-- On burn-out (Charred): Slate material, charred colour, a few "recently out" wisps.
-- Budget / LOD: re-ranked by camera distance 4x/s; nearest MaxClientFx get emitters, beyond FxLodDistance
--   the cheap tier (no embers/haze, quarter rate), beyond FxDistance nothing. Rates also scale down when
--   many fires are on screen so the total particle count stays bounded.
-- Test hooks: FireFxController:_stats() -> { fx, lights, burning }

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local FireConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FireConfig") :: ModuleScript)
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)

local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"

type Fx = {
	part: BasePart,
	attachment: Attachment,
	core: ParticleEmitter,
	licks: ParticleEmitter,
	embers: ParticleEmitter,
	smoke: ParticleEmitter,
	haze: ParticleEmitter,
	light: PointLight?,
	level: number,
	tier: number, -- 1 = full, 2 = cheap (far)
	scale: number, -- global rate scale last applied
	seed: number,
	baseBrightness: number,
	sound: Sound?,
}

local FireFxController = {}
FireFxController.Priority = 100

local fx: { [BasePart]: Fx } = {}
local burning: { [BasePart]: number } = {} -- part -> os.clock() when it started burning (client view)
local original: { [BasePart]: Color3 } = setmetatable({}, { __mode = "k" }) :: any
local liveLights: { Fx } = {}
local poofsLive = 0

local function cameraPos(): Vector3?
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position
end

local function seq(points: { { number } }): NumberSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, NumberSequenceKeypoint.new(p[1], p[2], p[3] or 0))
	end
	return NumberSequence.new(kps)
end

local function cseq(points: { { any } }): ColorSequence
	local kps = {}
	for _, p in points do
		table.insert(kps, ColorSequenceKeypoint.new(p[1] :: number, p[2] :: Color3))
	end
	return ColorSequence.new(kps)
end

-- size factor from the part footprint (an 8x1 wall chunk ~0.7, a 4x4 cube 1, an 8x8 floor 2)
local function sizeFactor(part: BasePart): number
	return math.clamp(math.sqrt(part.Size.X * part.Size.Z) / 4, 0.6, 2.5)
end

local function playSound(parent: Instance, id: string, volume: number, looped: boolean): Sound?
	if id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Looped = looped
	s.RollOffMinDistance = 8
	s.RollOffMaxDistance = 90
	s.PlaybackSpeed = 0.9 + math.random() * 0.2
	s.Parent = parent
	s:Play()
	if not looped then
		Debris:AddItem(s, 4)
	end
	return s
end

local function newEmitter(name: string, parent: Instance): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Parent = parent
	return e
end

local function build(part: BasePart): Fx
	local s = sizeFactor(part)

	-- Core: short-lived, hot white-yellow body that hugs the part. Rotating fire sprites with a slight
	-- vertical squash read as a hand-drawn flipbook flame.
	local core = newEmitter("FlameCore", part)
	local flip = FireConfig.FxFlameFlipbook :: string
	if flip ~= "" then
		core.Texture = flip
		core.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid4x4
		core.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
	else
		core.Texture = TEX_FIRE
	end
	-- Surface (not Volume): particles spawned inside an opaque part are hidden, so emit from its faces
	core.Shape = Enum.ParticleEmitterShape.Box
	core.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	core.EmissionDirection = Enum.NormalId.Top
	core.LightEmission = 1
	core.LightInfluence = 0
	core.Brightness = 4 -- fire_main.dds is wispy; it washes out in lit interiors without this
	core.ZOffset = 0.6
	core.Color = cseq({ { 0, Palette.FireCore }, { 0.3, Palette.FireBody }, { 0.75, Palette.FireEdge }, { 1, Palette.FireDark } })
	core.Transparency = seq({ { 0, 0.6 }, { 0.1, 0 }, { 0.7, 0.2 }, { 1, 1 } })
	core.Lifetime = NumberRange.new(0.5, 0.85)
	core.Speed = NumberRange.new(4, 7)
	core.SpreadAngle = Vector2.new(8, 8)
	core.Acceleration = Vector3.new(0, 7, 0)
	core.Drag = 2
	core.Rotation = NumberRange.new(-20, 20)
	core.RotSpeed = NumberRange.new(-60, 60)
	core.Squash = seq({ { 0, -0.3 }, { 0.5, -0.6, 0.2 }, { 1, 0.3 } })

	-- Licks: taller orange-red tongues that stretch along their velocity and whip sideways.
	local licks = newEmitter("FlameLicks", part)
	licks.Texture = TEX_FIRE
	licks.Shape = Enum.ParticleEmitterShape.Box
	licks.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
	licks.EmissionDirection = Enum.NormalId.Top
	licks.Orientation = Enum.ParticleOrientation.VelocityParallel
	licks.LightEmission = 0.7
	licks.LightInfluence = 0
	licks.Brightness = 2.5
	licks.ZOffset = 0.3
	licks.Color = cseq({ { 0, Palette.FireBody }, { 0.4, Palette.FireEdge }, { 1, Palette.FireDark } })
	licks.Transparency = seq({ { 0, 0.6 }, { 0.15, 0.05 }, { 0.7, 0.35 }, { 1, 1 } })
	licks.Lifetime = NumberRange.new(0.6, 1)
	licks.Speed = NumberRange.new(6, 10)
	licks.SpreadAngle = Vector2.new(18, 18)
	licks.Acceleration = Vector3.new(0, 10, 0)
	licks.Drag = 1.2
	licks.Squash = seq({ { 0, -1.2 }, { 1, -0.4 } })
	licks.RotSpeed = NumberRange.new(-30, 30)

	-- Top-face attachment for the things that rise above the fire.
	local a = Instance.new("Attachment")
	a.Name = "FireFx"
	a.Position = Vector3.new(0, part.Size.Y / 2, 0)

	local embers = newEmitter("Embers", a)
	embers.Texture = TEX_SPARK
	embers.LightEmission = 1
	embers.LightInfluence = 0
	embers.Brightness = 3
	embers.ZOffset = 0.8
	embers.Color = cseq({ { 0, Palette.FireCore }, { 0.5, Color3.fromHex("#FFB347") }, { 1, Palette.FireEdge } })
	embers.Size = seq({ { 0, 0.18 * s, 0.06 }, { 1, 0 } })
	embers.Transparency = seq({ { 0, 0 }, { 0.8, 0.2 }, { 1, 1 } })
	embers.Lifetime = NumberRange.new(1, 2.2)
	embers.Speed = NumberRange.new(4, 9)
	embers.SpreadAngle = Vector2.new(40, 40)
	embers.Acceleration = Vector3.new(0, 3, 0)
	embers.Drag = 0.8
	embers.EmissionDirection = Enum.NormalId.Top
	embers.Shape = Enum.ParticleEmitterShape.Disc
	embers.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	embers.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward

	local smoke = newEmitter("Smoke", a)
	smoke.Texture = TEX_SMOKE
	smoke.LightEmission = 0
	smoke.LightInfluence = 1
	smoke.Transparency = seq({ { 0, 1 }, { 0.15, 0.45 }, { 0.6, 0.6 }, { 1, 1 } })
	smoke.Lifetime = NumberRange.new(3, 5)
	smoke.Speed = NumberRange.new(4, 7)
	smoke.SpreadAngle = Vector2.new(10, 10)
	smoke.Acceleration = Vector3.new(0.6, 2, 0.3)
	smoke.Drag = 0.6
	smoke.Rotation = NumberRange.new(0, 360)
	smoke.RotSpeed = NumberRange.new(-20, 20)
	smoke.EmissionDirection = Enum.NormalId.Top
	smoke.WindAffectsDrag = true

	-- Heat shimmer: Roblox has no refraction, so a barely-visible fast-spinning warm veil above the
	-- flames fakes the wobble.
	local haze = newEmitter("HeatHaze", a)
	haze.Texture = TEX_SMOKE
	haze.LightEmission = 0.4
	haze.LightInfluence = 0
	haze.Color = ColorSequence.new(Color3.fromHex("#FFE2B8"))
	haze.Transparency = seq({ { 0, 1 }, { 0.3, 0.93 }, { 0.7, 0.95 }, { 1, 1 } })
	haze.Size = seq({ { 0, 1.5 * s }, { 1, 4 * s } })
	haze.Lifetime = NumberRange.new(0.6, 1)
	haze.Speed = NumberRange.new(5, 8)
	haze.SpreadAngle = Vector2.new(6, 6)
	haze.Rotation = NumberRange.new(0, 360)
	haze.RotSpeed = NumberRange.new(-220, 220)
	haze.EmissionDirection = Enum.NormalId.Top

	a.Parent = part

	local f: Fx = {
		part = part,
		attachment = a,
		core = core,
		licks = licks,
		embers = embers,
		smoke = smoke,
		haze = haze,
		light = nil,
		level = 0,
		tier = 0,
		scale = -1,
		seed = math.random() * 1000,
		baseBrightness = 1,
		sound = nil,
	}
	return f
end

-- Apply FireLevel, LOD tier and the global rate scale to an Fx (cheap when nothing changed).
local function tune(f: Fx, level: number, tier: number, scale: number)
	if f.level == level and f.tier == tier and math.abs(f.scale - scale) < 0.05 then
		return
	end
	local s = sizeFactor(f.part)
	local area = math.clamp(f.part.Size.X * f.part.Size.Z / 16, 0.5, 4) -- more surface, more flames
	local lod = if tier == 1 then 1 else 0.25
	local r = scale * lod
	-- level 3 values were tuned live in Studio (Fire Station interior): core 45/area, licks 22/area
	f.core.Rate = (15 + 10 * level) * area * r
	f.core.Size = seq({ { 0, (0.6 + 0.2 * level) * s }, { 0.3, (1.6 + 0.4 * level) * s, 0.4 * s }, { 1, 0.4 * s } })
	f.licks.Rate = (7 + 5 * level) * area * r
	f.licks.Size = seq({ { 0, (0.4 + 0.2 * level) * s }, { 0.35, (1.9 + 0.5 * level) * s, 0.5 * s }, { 1, 0.3 } })
	f.embers.Enabled = tier == 1
	f.embers.Rate = (2 + 3 * level) * r
	f.haze.Enabled = tier == 1 and level >= 2
	f.haze.Rate = 2 + 2 * level
	-- smoke: grey wisps at level 1, thick black column at level 3
	local dark = (level - 1) / 2
	local top = Palette.SmokeGrey:Lerp(Palette.SmokeBlack, dark)
	f.smoke.Color = cseq({ { 0, Palette.SmokeGrey:Lerp(Palette.FireDark, 0.25) }, { 0.3, top }, { 1, top:Lerp(Palette.SmokeBlack, 0.5) } })
	f.smoke.Size = seq({ { 0, (1.5 + 0.5 * level) * s }, { 1, (5 + 3 * level) * s, 1 } })
	f.smoke.Rate = (1.5 + 2.5 * level) * r
	f.smoke.Lifetime = NumberRange.new(2.5 + level, 4 + level)
	f.baseBrightness = 1.2 + 0.7 * level
	if f.light then
		f.light.Range = 10 + 5 * level
	end
	f.level, f.tier, f.scale = level, tier, scale
end

local function setLight(f: Fx, on: boolean, shadows: boolean)
	if on and not f.light then
		local l = Instance.new("PointLight")
		l.Color = Color3.fromHex("#FF8A3D")
		l.Range = 10 + 5 * f.level
		l.Brightness = f.baseBrightness
		l.Parent = f.attachment
		f.light = l
		table.insert(liveLights, f)
	elseif not on and f.light then
		f.light:Destroy()
		f.light = nil
		local i = table.find(liveLights, f)
		if i then
			table.remove(liveLights, i)
		end
	end
	if f.light then
		f.light.Shadows = shadows
	end
end

local function clear(part: BasePart)
	local f = fx[part]
	if not f then
		return
	end
	setLight(f, false, false)
	f.core:Destroy()
	f.licks:Destroy()
	f.attachment:Destroy() -- embers, smoke, haze, light and sound with it
	fx[part] = nil
end

-- One-shot burst when a part lights up near the camera.
local function ignitionBurst(part: BasePart)
	local f = fx[part]
	if not f then
		return
	end
	f.licks:Emit(math.floor(8 + 4 * sizeFactor(part)))
	f.embers:Emit(10)
	playSound(f.attachment, FireConfig.SfxIgnite :: string, 0.6, false)
end

-- Tiny cartoon smoke ring + "poof!" text. Purely for comedy; capped.
local function poof(origin: Vector3)
	if poofsLive >= 4 then
		return
	end
	poofsLive += 1
	local holder = Instance.new("Model")
	holder.Name = "FirePoof"
	local n = 12
	local info = TweenInfo.new(0.9, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	for i = 1, n do
		local ang = (i / n) * math.pi * 2
		local b = Instance.new("Part")
		b.Shape = Enum.PartType.Ball
		b.Anchored = true
		b.CanCollide = false
		b.CanQuery = false
		b.CanTouch = false
		b.CastShadow = false
		b.Material = Enum.Material.SmoothPlastic
		b.Color = Palette.SmokeWhite
		b.Size = Vector3.one * 0.9
		b.Transparency = 0.1
		b.Position = origin + Vector3.new(math.cos(ang) * 0.6, 0.5, math.sin(ang) * 0.6)
		b.Parent = holder
		local out = origin + Vector3.new(math.cos(ang) * 3.2, 2.2, math.sin(ang) * 3.2)
		TweenService:Create(b, info, { Position = out, Size = Vector3.one * 1.8, Transparency = 1 }):Play()
	end
	-- the "poof!" itself is a small popup (ClientLib/WorldPopup: caps, dedupe, feedback setting)
	WorldPopup.show(origin, ({ "poof!", "pff.", "*fwump*", "psst!" })[math.random(1, 4)], { height = 1.5, flavour = true })
	holder.Parent = workspace
	task.delay(1.3, function()
		holder:Destroy()
		poofsLive -= 1
	end)
end

-- Put out (not charred): steam puff + lingering wisps + hiss, sometimes a cartoon poof.
local function steamPuff(part: BasePart)
	local cam = cameraPos()
	if not cam or (part.Position - cam).Magnitude > FireConfig.FxDistance then
		return
	end
	local s = sizeFactor(part)
	local existing = part:FindFirstChild("SteamFx")
	if existing then -- doused again while the last puff is still up: re-puff, don't stack attachments
		local e = existing:FindFirstChild("Steam") :: ParticleEmitter?
		if e then
			e:Emit(math.floor(12 + 4 * s))
		end
		return
	end
	local a = Instance.new("Attachment")
	a.Name = "SteamFx"
	a.Position = Vector3.new(0, part.Size.Y / 2, 0)
	local puff = newEmitter("Steam", a)
	puff.Texture = TEX_SMOKE
	puff.Enabled = false
	puff.LightInfluence = 0.6
	puff.Color = ColorSequence.new(Palette.SmokeWhite)
	puff.Transparency = seq({ { 0, 0.1 }, { 0.5, 0.45 }, { 1, 1 } })
	puff.Size = seq({ { 0, 1.5 * s }, { 1, 6 * s } })
	puff.Lifetime = NumberRange.new(0.8, 1.3)
	puff.Speed = NumberRange.new(6, 10)
	puff.SpreadAngle = Vector2.new(40, 40)
	puff.Drag = 2
	puff.Rotation = NumberRange.new(0, 360)
	puff.RotSpeed = NumberRange.new(-60, 60)
	puff.EmissionDirection = Enum.NormalId.Top
	local wisp = newEmitter("Wisps", a)
	wisp.Texture = TEX_SMOKE
	wisp.LightInfluence = 0.8
	wisp.Color = ColorSequence.new(Palette.SmokeWhite)
	wisp.Transparency = seq({ { 0, 1 }, { 0.2, 0.6 }, { 1, 1 } })
	wisp.Size = seq({ { 0, 0.5 * s }, { 1, 2.5 * s } })
	wisp.Lifetime = NumberRange.new(1.5, 2.5)
	wisp.Speed = NumberRange.new(1.5, 3)
	wisp.Rate = 2
	wisp.EmissionDirection = Enum.NormalId.Top
	a.Parent = part
	puff:Emit(math.floor(18 + 6 * s))
	playSound(a, FireConfig.SfxHiss :: string, 0.7, false)
	task.delay(math.max(0, FireConfig.FxWispSeconds - 1.5), function()
		wisp.Enabled = false
	end)
	Debris:AddItem(a, FireConfig.FxWispSeconds + 1)
	if math.random() < FireConfig.FxPoofChance then
		poof(part.Position + Vector3.new(0, part.Size.Y / 2, 0))
	end
end

-- Burnt out: slate + charred colour + a few smouldering wisps.
local function charPart(part: BasePart)
	part.Material = Enum.Material.Slate
	part.Color = FireConfig.CharredColor
	local cam = cameraPos()
	if not cam or (part.Position - cam).Magnitude > FireConfig.FxDistance then
		return
	end
	local a = Instance.new("Attachment")
	a.Name = "CharFx"
	a.Position = Vector3.new(0, part.Size.Y / 2, 0)
	local wisp = newEmitter("Smoulder", a)
	wisp.Texture = TEX_SMOKE
	wisp.Color = ColorSequence.new(Palette.SmokeGrey)
	wisp.Transparency = seq({ { 0, 1 }, { 0.2, 0.65 }, { 1, 1 } })
	wisp.Size = seq({ { 0, 0.6 }, { 1, 3 } })
	wisp.Lifetime = NumberRange.new(2, 3)
	wisp.Speed = NumberRange.new(1, 2.5)
	wisp.Rate = 1.5
	wisp.EmissionDirection = Enum.NormalId.Top
	a.Parent = part
	task.delay(FireConfig.FxWispSeconds, function()
		wisp.Enabled = false
	end)
	Debris:AddItem(a, FireConfig.FxWispSeconds + 3)
end

-- Re-rank by distance; give the nearest fires full effects, far ones the cheap tier, the rest nothing.
local function refresh()
	local cam = cameraPos()
	if not cam then
		return
	end
	local now = os.clock()
	local list: { { part: BasePart, d: number } } = {}
	for part, since in burning do
		if not part.Parent then
			burning[part] = nil
			clear(part)
			continue
		end
		table.insert(list, { part = part, d = (part.Position - cam).Magnitude })
		-- progressive scorch: the part darkens the longer it burns (local only; server sets the final char)
		local orig = original[part]
		if orig then
			local k = math.clamp((now - since) / FireConfig.FxScorchSeconds, 0, 1) * 0.7
			part.Color = orig:Lerp(Palette.CharredWarm, k)
		end
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local maxFx = FireConfig.MaxClientFx :: number
	local shown = math.min(#list, maxFx)
	-- past ~16 full fires, thin every emitter so the particle total stays near the budget
	local scale = math.clamp(16 / math.max(1, shown), 0.35, 1)
	local keep: { [BasePart]: boolean } = {}
	local lit: { Vector3 } = {} -- one light per cluster: skip parts close to an already-lit one
	local clusterR = FireConfig.FxLightClusterRadius :: number
	for i, item in list do
		if i > maxFx or item.d > FireConfig.FxDistance then
			break
		end
		local part = item.part
		keep[part] = true
		local fresh = fx[part] == nil
		local f = fx[part] or build(part)
		fx[part] = f
		local level = (part:GetAttribute(Names.Attr.FireLevel) :: number?) or 1
		local tier = if item.d <= FireConfig.FxLodDistance then 1 else 2
		tune(f, level, tier, scale)
		local wantLight = #lit < FireConfig.MaxClientLights
		if wantLight then
			for _, p in lit do
				if (p - part.Position).Magnitude < clusterR then
					wantLight = false
					break
				end
			end
		end
		if wantLight then
			table.insert(lit, part.Position)
		end
		setLight(f, wantLight, wantLight and #lit <= FireConfig.MaxShadowLights)
		-- crackle loop on the nearest few only
		if i <= FireConfig.MaxCrackles and not f.sound then
			f.sound = playSound(f.attachment, FireConfig.SfxCrackle :: string, 0.35 + 0.15 * level, true)
		elseif i > FireConfig.MaxCrackles and f.sound then
			f.sound:Destroy()
			f.sound = nil
		end
		if fresh and now - burning[part] < 0.5 then
			ignitionBurst(part)
		end
	end
	for part in fx do
		if not keep[part] then
			clear(part)
		end
	end
end

-- Flicker every frame, only for the handful of parts that have a light.
local function flicker()
	local t = os.clock()
	for _, f in liveLights do
		local l = f.light
		if l then
			local n = math.noise(t * 6, f.seed) * 0.5 + math.noise(t * 17, f.seed + 9) * 0.25
			l.Brightness = f.baseBrightness * (0.85 + n)
		end
	end
end

function FireFxController:Init(_controllers: { [string]: any }) end

function FireFxController:Start()
	local function added(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		burning[inst] = os.clock()
		if original[inst] == nil then
			original[inst] = inst.Color
		end
	end
	local function removed(inst: Instance)
		if not inst:IsA("BasePart") then
			return
		end
		burning[inst] = nil
		clear(inst)
		if not inst:IsDescendantOf(workspace) then
			return
		end
		if inst:GetAttribute(Names.Attr.Charred) == true then
			charPart(inst)
		else
			steamPuff(inst)
		end
	end
	CollectionService:GetInstanceAddedSignal(Names.Tag.Burning):Connect(added)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(removed)
	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		added(inst)
	end
	RunService.RenderStepped:Connect(flicker)
	while true do
		local ok, err = pcall(refresh)
		if not ok then
			warn(`[FireFx] refresh failed: {err}`)
		end
		task.wait(0.25)
	end
end

function FireFxController:_stats(): { fx: number, lights: number, burning: number }
	local n, b = 0, 0
	for _ in fx do
		n += 1
	end
	for _ in burning do
		b += 1
	end
	return { fx = n, lights = #liveLights, burning = b }
end

return FireFxController
