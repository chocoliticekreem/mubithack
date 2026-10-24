--!strict
-- SmokeController [owner: Smoke agent]. Client side of SmokeService (rooms fill with smoke, backdrafts).
-- Nothing here affects gameplay; everything is local and budgeted.
-- From replicated state (no traffic):
--   Workspace.SmokeRooms.<site>.Room<n> (attr Smoke) "Area" parts -> a dark smoke layer per area box that
--     grows DOWN from the ceiling and thickens (SmokeSim.layer maths mirrored here), the nearest
--     MaxLayerEmitters get a billowing underside. Your head inside a layer darkens the screen (less
--     with a GasMask).
--   Parts tagged SmokeLink (doors / windows): Seep -> wisps curling out under the door toward SeepDir;
--     DoorHeat -> an orange glow strip + light in the gap under the door; Vent -> a plume pouring out
--     of the opening along VentDir; Rattle (door closed) -> the door shakes in its frame.
-- Smoke/Fx one-shots: "backdraft" (fireball out of the doorway, flame + smoke burst, flash, shake,
--   whoosh), "relief" / "vent" (plume burst), "puff" (smoke puffs from the gaps), "creak" (timber
--   groan), "jolt" (sparks + hiss off a hot handle).
-- Consumes (nil-guarded): FirstPersonController:Shake, AudioController:Play.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("SmokeConfig") :: ModuleScript) :: any

local SmokeController = {}
SmokeController.Priority = 105

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_FIRE = "rbxasset://textures/particles/fire_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local LINK_TAG = "SmokeLink"

type Layer = {
	area: BasePart,
	room: Instance,
	part: Part,
	depth: number,
	transparency: number,
	emitter: ParticleEmitter?,
}
type LinkFx = {
	part: BasePart,
	seepAtt: Attachment,
	seep: ParticleEmitter,
	ventAtt: Attachment,
	vent: ParticleEmitter,
	glow: Part,
	light: PointLight,
	base: CFrame?,
}

local controllers: { [string]: any } = {}
local player = Players.LocalPlayer
local layers: { [BasePart]: Layer } = {}
local links: { [BasePart]: LinkFx } = {}
local overlay: Frame? = nil
local dark = 0

local function camPos(): Vector3
	local cam = workspace.CurrentCamera
	return if cam then cam.CFrame.Position else Vector3.zero
end

local function fxFolder(): Folder
	local f = workspace:FindFirstChild("SmokeFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SmokeFx"
		f.Parent = workspace
	end
	return f :: Folder
end

local function shake(magnitude: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, magnitude, seconds)
	end
end

local function play(name: string, at: Vector3, opts: { [string]: any }?)
	local a = controllers.AudioController
	if a and type(a.Play) == "function" then
		pcall(a.Play, a, name, at, opts)
	end
end

local function cheapPart(name: string, size: Vector3, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	return p
end

local function emitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SMOKE
	e.LightInfluence = 0.5
	e.Rate = 0
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local function smokeColor(): ColorSequence
	local c = Cfg.LayerColor :: Color3
	return ColorSequence.new(c:Lerp(Color3.new(0.35, 0.33, 0.33), 0.4), c)
end

-- One-shot holder: an invisible anchored part facing `dir`, removed after `life` s.
local function holder(pos: Vector3, dir: Vector3, life: number): Part
	local look = if dir.Magnitude > 1e-3 then dir.Unit else Vector3.new(0, 1, 0)
	local up = if math.abs(look.Y) > 0.95 then Vector3.new(1, 0, 0) else Vector3.new(0, 1, 0)
	local p = cheapPart("Fx", Vector3.new(1, 1, 1), CFrame.lookAt(pos, pos + look, up))
	p.Transparency = 1
	p.Parent = fxFolder()
	task.delay(life, function()
		p:Destroy()
	end)
	return p
end

---------------------------------------------------------------------------------------------- layers

local function addArea(area: Instance)
	if not area:IsA("BasePart") or area.Name ~= "Area" or layers[area] then
		return
	end
	local p = cheapPart("SmokeLayer", Vector3.new(1, 0.05, 1), area.CFrame)
	p.Material = Enum.Material.SmoothPlastic
	p.Color = Cfg.LayerColor
	p.Transparency = 1
	p.Parent = fxFolder()
	layers[area] = { area = area, room = area.Parent :: Instance, part = p, depth = 0, transparency = 1 }
end

local function removeArea(area: Instance)
	local l = layers[area :: BasePart]
	if l then
		l.part:Destroy()
		layers[area :: BasePart] = nil
	end
end

local function updateLayers(dt: number)
	local cam = camPos()
	local masked = player:GetAttribute("GasMask") == true
	local inside = 0
	local ranked: { { l: Layer, d: number, smoke: number } } = {}
	for area, l in layers do
		if not area.Parent then
			removeArea(area)
			continue
		end
		local d = (area.Position - cam).Magnitude
		local smoke = tonumber(l.room:GetAttribute("Smoke")) or 0
		if d > Cfg.FxDistance then
			if l.part.Transparency < 1 then
				l.part.Transparency = 1
			end
			if l.emitter then
				l.emitter.Rate = 0
			end
			continue
		end
		local h = area.Size.Y
		local targetDepth = h * math.clamp(smoke, 0, 1) * Cfg.LayerMaxFill
		local targetT = Cfg.LayerClear + (Cfg.LayerThick - Cfg.LayerClear) * math.clamp(smoke, 0, 1)
		local k = math.min(1, dt * 1.5)
		l.depth += (targetDepth - l.depth) * k
		l.transparency += (targetT - l.transparency) * k
		if l.depth < 0.08 then
			l.part.Transparency = 1
		else
			l.part.Size = Vector3.new(area.Size.X, l.depth, area.Size.Z)
			l.part.CFrame = area.CFrame * CFrame.new(0, h / 2 - l.depth / 2, 0)
			l.part.Transparency = l.transparency
		end
		-- head in the smoke?
		local lp = area.CFrame:PointToObjectSpace(cam)
		if math.abs(lp.X) <= area.Size.X / 2 and math.abs(lp.Z) <= area.Size.Z / 2 and lp.Y <= h / 2 and lp.Y >= h / 2 - l.depth then
			inside = math.max(inside, smoke)
		end
		table.insert(ranked, { l = l, d = d, smoke = smoke })
	end
	table.sort(ranked, function(a, b)
		return a.d < b.d
	end)
	for i, r in ranked do
		local l = r.l
		local want = i <= Cfg.MaxLayerEmitters and r.smoke > 0.12 and l.depth > 0.5
		if want and not l.emitter then
			l.emitter = emitter(l.part, {
				Name = "Billow",
				EmissionDirection = Enum.NormalId.Bottom,
				Color = smokeColor(),
				Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 7) }),
				Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(1, 1) }),
				Lifetime = NumberRange.new(2.5, 4.5),
				Speed = NumberRange.new(0.3, 1.2),
				Rotation = NumberRange.new(0, 360),
				RotSpeed = NumberRange.new(-12, 12),
				Drag = 1,
			})
		end
		if l.emitter then
			local area = l.area.Size.X * l.area.Size.Z
			l.emitter.Rate = if want then math.clamp(area / 40, 2, 14) * r.smoke else 0
		end
	end
	-- screen darkening with your head in the smoke
	local target = inside * Cfg.ScreenDarkMax * (if masked then 0.45 else 1)
	dark += (target - dark) * math.min(1, dt * 3)
	if overlay then
		overlay.BackgroundTransparency = 1 - dark
		overlay.Visible = dark > 0.01
	end
end

---------------------------------------------------------------------------------------------- doors / windows

local function newLinkFx(part: BasePart): LinkFx
	local seepAtt = Instance.new("Attachment")
	seepAtt.Name = "SmokeSeepFx"
	seepAtt.Parent = workspace.Terrain
	local seep = emitter(seepAtt, {
		Name = "Seep",
		EmissionDirection = Enum.NormalId.Front,
		Color = smokeColor(),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 2.6) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(1.2, 2.2),
		Speed = NumberRange.new(1.5, 3.5),
		SpreadAngle = Vector2.new(50, 6),
		Acceleration = Vector3.new(0, 1.6, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-40, 40),
		Drag = 0.6,
	})
	local ventAtt = Instance.new("Attachment")
	ventAtt.Name = "SmokeVentFx"
	ventAtt.Parent = workspace.Terrain
	local vent = emitter(ventAtt, {
		Name = "Vent",
		EmissionDirection = Enum.NormalId.Front,
		Color = smokeColor(),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 9) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(2.5, 4),
		Speed = NumberRange.new(5, 9),
		SpreadAngle = Vector2.new(18, 18),
		Acceleration = Vector3.new(0, 5, 0),
		Rotation = NumberRange.new(0, 360),
		RotSpeed = NumberRange.new(-20, 20),
		Drag = 0.8,
	})
	local glow = cheapPart("DoorGlow", Vector3.new(1, 0.18, 0.7), part.CFrame)
	glow.Material = Enum.Material.Neon
	glow.Color = Cfg.GlowColor
	glow.Transparency = 1
	glow.Parent = fxFolder()
	local light = Instance.new("PointLight")
	light.Color = Cfg.GlowColor
	light.Range = 7
	light.Brightness = 0
	light.Shadows = false
	light.Parent = glow
	return { part = part, seepAtt = seepAtt, seep = seep, ventAtt = ventAtt, vent = vent, glow = glow, light = light }
end

local function stopRattle(f: LinkFx)
	if f.base then
		if f.part.Parent then
			f.part.CFrame = f.base
		end
		f.base = nil
	end
end

local function dropLinkFx(part: BasePart)
	local f = links[part]
	if not f then
		return
	end
	stopRattle(f)
	f.seepAtt:Destroy()
	f.ventAtt:Destroy()
	f.glow:Destroy()
	links[part] = nil
end

local function updateLinks()
	local cam = camPos()
	local ranked: { { p: BasePart, d: number } } = {}
	for _, inst in CollectionService:GetTagged(LINK_TAG) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			local d = (inst.Position - cam).Magnitude
			if d <= Cfg.FxDistance then
				table.insert(ranked, { p = inst, d = d })
			end
		end
	end
	table.sort(ranked, function(a, b)
		return a.d < b.d
	end)
	local keep: { [BasePart]: boolean } = {}
	for i, r in ranked do
		if i > Cfg.MaxLinkFx then
			break
		end
		keep[r.p] = true
	end
	for part in links do
		if not keep[part] then
			dropLinkFx(part)
		end
	end
	for part in keep do
		local f = links[part] or newLinkFx(part)
		links[part] = f
		local base = f.base or part.CFrame
		local bottom = (base * CFrame.new(0, -part.Size.Y / 2 + 0.15, 0)).Position
		-- seep: wisps out of the gap under the door, toward the cooler side
		local seep = tonumber(part:GetAttribute("Seep")) or 0
		local seepDir = part:GetAttribute("SeepDir")
		if typeof(seepDir) == "Vector3" and seep > 0 then
			local out = bottom + seepDir * (part.Size.Z / 2 + 0.3)
			f.seepAtt.WorldCFrame = CFrame.lookAt(out, out + seepDir)
			f.seep.Rate = 6 + seep * 30
		else
			f.seep.Rate = 0
		end
		-- glow under a hot door
		local heat = tonumber(part:GetAttribute("DoorHeat")) or 0
		if heat > 0.15 and part.CanCollide then
			f.glow.Size = Vector3.new(math.max(1, part.Size.X - 0.4), 0.18, part.Size.Z + 0.3)
			f.glow.CFrame = base * CFrame.new(0, -part.Size.Y / 2 + 0.1, 0)
			f.glow.Transparency = 1 - math.clamp(heat, 0, 1) * 0.85
			f.light.Brightness = heat * (1.6 + 0.5 * math.sin(os.clock() * 13))
		else
			f.glow.Transparency = 1
			f.light.Brightness = 0
		end
		-- vent: a plume pouring out of the opening
		local vent = tonumber(part:GetAttribute("Vent")) or 0
		local ventDir = part:GetAttribute("VentDir")
		if typeof(ventDir) == "Vector3" and vent > 0.04 then
			local out = part.Position + ventDir * (part.Size.Z / 2 + 0.8) + Vector3.new(0, part.Size.Y * 0.25, 0)
			f.ventAtt.WorldCFrame = CFrame.lookAt(out, out + ventDir + Vector3.new(0, 0.35, 0))
			f.vent.Rate = 4 + vent * 40
		else
			f.vent.Rate = 0
		end
		-- rattle (closed doors only)
		local rattle = tonumber(part:GetAttribute("Rattle")) or 0
		if rattle >= 1 and part.CanCollide and part:GetAttribute("Broken") ~= true and part:HasTag("Door") then
			f.base = base
		else
			stopRattle(f)
		end
	end
end

local function animateRattles()
	local t = os.clock()
	for part, f in links do
		local base = f.base
		if base and part.Parent then
			local rattle = tonumber(part:GetAttribute("Rattle")) or 1
			local amp = math.rad(Cfg.RattleDegrees * rattle)
			local jolt = math.sin(t * 31) * math.sin(t * 3.7)
			part.CFrame = base * CFrame.new(math.sin(t * 47) * 0.04 * rattle, 0, 0) * CFrame.Angles(jolt * amp * 0.3, jolt * amp, 0)
		end
	end
end

---------------------------------------------------------------------------------------------- one-shots

local function burst(pos: Vector3, dir: Vector3, n: number, props: { [string]: any }, life: number)
	local h = holder(pos, dir, life)
	local e = emitter(h, props)
	e.EmissionDirection = Enum.NormalId.Front
	e:Emit(n)
end

local function backdraft(pos: Vector3, data: { [string]: any })
	local dir = if typeof(data.dir) == "Vector3" then (data.dir :: Vector3) else Vector3.new(0, 0, -1)
	local d = (pos - camPos()).Magnitude
	-- fireball: two neon spheres that balloon out of the doorway and fade
	for i, spec in { { Color3.fromRGB(255, 120, 30), 18, 0.6 }, { Color3.fromRGB(255, 220, 90), 10, 0.45 } } do
		local ball = cheapPart("Fireball", Vector3.new(3, 3, 3), CFrame.new(pos))
		ball.Shape = Enum.PartType.Ball
		ball.Material = Enum.Material.Neon
		ball.Color = spec[1]
		ball.Transparency = 0.05
		ball.Parent = fxFolder()
		local size = spec[2] :: number
		local secs = spec[3] :: number
		local goal = {
			Size = Vector3.new(size, size * 0.8, size),
			CFrame = CFrame.new(pos + dir * (size * 0.55) + Vector3.new(0, 1 + i, 0)),
			Transparency = 1,
		}
		TweenService:Create(ball, TweenInfo.new(secs, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
		task.delay(secs + 0.1, function()
			ball:Destroy()
		end)
	end
	burst(pos, dir, 70, {
		Texture = TEX_FIRE,
		Color = ColorSequence.new(Color3.fromRGB(255, 220, 120), Color3.fromRGB(255, 80, 20)),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 7) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(0.5, 1),
		Speed = NumberRange.new(25, 45),
		SpreadAngle = Vector2.new(28, 22),
		LightEmission = 1,
		Drag = 3,
	}, 2)
	burst(pos, dir, 35, {
		Color = smokeColor(),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 4), NumberSequenceKeypoint.new(1, 12) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(2, 3.5),
		Speed = NumberRange.new(12, 22),
		SpreadAngle = Vector2.new(35, 30),
		Acceleration = Vector3.new(0, 6, 0),
		Drag = 1.5,
	}, 4)
	local h = holder(pos, dir, 1.2)
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Range = 32
	light.Brightness = 8
	light.Parent = h
	TweenService:Create(light, TweenInfo.new(1, Enum.EasingStyle.Quad), { Brightness = 0 }):Play()
	play("Ignite", pos, { speed = 0.5, volume = 1 })
	play("DoorBreak", pos, { speed = 0.75, volume = 0.9 })
	if d < 70 then
		shake(math.clamp(1.4 * (1 - d / 70), 0.2, 1.4), 0.7)
	end
end

local function plume(pos: Vector3, data: { [string]: any }, n: number)
	local dir = if typeof(data.dir) == "Vector3" then (data.dir :: Vector3) else Vector3.new(0, 1, 0)
	burst(pos, dir + Vector3.new(0, 0.4, 0), n, {
		Color = smokeColor(),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 11) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(2.5, 4),
		Speed = NumberRange.new(9, 16),
		SpreadAngle = Vector2.new(25, 25),
		Acceleration = Vector3.new(0, 6, 0),
		Drag = 1,
	}, 5)
	play("Steam", pos, { speed = 0.55, volume = 0.7 })
end

local function puffs(data: { [string]: any })
	local points = if type(data.points) == "table" then data.points else {}
	local dirs = if type(data.dirs) == "table" then data.dirs else {}
	local stage = tonumber(data.stage) or 1
	for i, p in points do
		if typeof(p) ~= "Vector3" or (p - camPos()).Magnitude > Cfg.FxDistance then
			continue
		end
		local dir = if typeof(dirs[i]) == "Vector3" then dirs[i] else Vector3.new(0, 1, 0)
		burst(p + dir * 0.6, dir, 3 + stage * 3, {
			Color = smokeColor(),
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 3.5) }),
			Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(1, 1) }),
			Lifetime = NumberRange.new(1, 1.8),
			Speed = NumberRange.new(4, 8),
			SpreadAngle = Vector2.new(45, 10),
			Acceleration = Vector3.new(0, 3, 0),
			Drag = 2,
		}, 3)
	end
end

local function onFx(kind: any, pos: any, data: any)
	if type(kind) ~= "string" or typeof(pos) ~= "Vector3" then
		return
	end
	local d = if type(data) == "table" then data else {}
	if kind ~= "backdraft" and (pos - camPos()).Magnitude > Cfg.FxDistance then
		return
	end
	if kind == "backdraft" then
		backdraft(pos, d)
	elseif kind == "relief" then
		plume(pos, d, 45)
	elseif kind == "vent" then
		plume(pos, d, 18)
	elseif kind == "puff" then
		puffs(d)
	elseif kind == "creak" then
		local stage = tonumber(d.stage) or 1
		play("DoorBreak", pos, { speed = 0.32 + 0.04 * stage, volume = 0.25 + 0.15 * stage })
		local dist = (pos - camPos()).Magnitude
		if dist < 25 then
			shake(0.15 * stage, 0.35)
		end
	elseif kind == "jolt" then
		burst(pos, Vector3.new(0, 1, 0), 14, {
			Texture = TEX_SPARK,
			Color = ColorSequence.new(Color3.fromRGB(255, 200, 80), Color3.fromRGB(255, 90, 30)),
			Size = NumberSequence.new(0.4, 0),
			Lifetime = NumberRange.new(0.3, 0.6),
			Speed = NumberRange.new(8, 14),
			SpreadAngle = Vector2.new(70, 70),
			LightEmission = 1,
		}, 1.5)
		play("Steam", pos, { speed = 1.6, volume = 0.6 })
	end
end

---------------------------------------------------------------------------------------------- boot

local function makeOverlay()
	local gui = Instance.new("ScreenGui")
	gui.Name = "SmokeOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -1
	local f = Instance.new("Frame")
	f.Name = "Dark"
	f.Size = UDim2.fromScale(1, 1)
	f.BorderSizePixel = 0
	f.BackgroundColor3 = (Cfg.LayerColor :: Color3):Lerp(Color3.new(0, 0, 0), 0.3)
	f.BackgroundTransparency = 1
	f.Visible = false
	f.Parent = gui
	gui.Parent = player:WaitForChild("PlayerGui")
	overlay = f
end

local function watchRooms(root: Instance)
	root.DescendantAdded:Connect(addArea)
	root.DescendantRemoving:Connect(removeArea)
	for _, d in root:GetDescendants() do
		addArea(d)
	end
end

function SmokeController:Init(all: { [string]: any })
	controllers = all
end

function SmokeController:Start()
	task.spawn(makeOverlay)
	local root = workspace:FindFirstChild("SmokeRooms")
	if root then
		watchRooms(root)
	else
		local conn: RBXScriptConnection? = nil
		conn = workspace.ChildAdded:Connect(function(c)
			if c.Name == "SmokeRooms" and c:IsA("Folder") then
				if conn then
					conn:Disconnect()
				end
				watchRooms(c)
			end
		end)
	end
	CollectionService:GetInstanceRemovedSignal(LINK_TAG):Connect(function(inst)
		if inst:IsA("BasePart") then
			dropLinkFx(inst)
		end
	end)
	local fxRemote = Net.event("Smoke", "Fx")
	fxRemote.OnClientEvent:Connect(function(kind, pos, data)
		local ok, err = pcall(onFx, kind, pos, data)
		if not ok then
			warn(`[SmokeController] fx {kind}: {err}`)
		end
	end)
	local linkAcc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(updateLayers, dt)
		if not ok then
			warn(`[SmokeController] layers: {err}`)
		end
		linkAcc += dt
		if linkAcc >= 0.2 then
			linkAcc = 0
			local ok2, err2 = pcall(updateLinks)
			if not ok2 then
				warn(`[SmokeController] links: {err2}`)
			end
		end
		animateRattles()
	end)
end

function SmokeController:_stats(): { layers: number, links: number, dark: number }
	local n, m = 0, 0
	for _ in layers do
		n += 1
	end
	for _ in links do
		m += 1
	end
	return { layers = n, links = m, dark = dark }
end

return SmokeController
