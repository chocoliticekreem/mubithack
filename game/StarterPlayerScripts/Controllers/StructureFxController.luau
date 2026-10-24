--!strict
-- StructureFxController [owner: Structure agent]. Client side of StructureService (houses burn down).
--   Structure/Fx "creak"    -> timber groan + falling dust drizzle for `warn` s, camera shake when close
--   Structure/Fx "collapse" -> big dust cloud + splinters + wood crash + shake by distance
--   Structure/Fx "shatter"  -> glass shards burst (the shatter sound comes from AudioController on Broken)
--   Structure/Fx "totalloss"-> "TOTAL LOSS" stamp (sent only to the squad / players nearby)
-- From replicated state (no traffic): buildings tagged StructureConfig.Tag with attr Smoking get thick
--   smoke pouring out of every Broken window (nearest ClientSmokeMax), and a black smoke column at
--   SmokeTop once TotalLoss; a "BUILDING  64%" integrity bar for the nearest damaged building in range.
-- Consumes (nil-guarded): FirstPersonController:Shake, AudioController:Play, ClientLib/UiKit.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("StructureConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript) :: any

local StructureFxController = {}
StructureFxController.Priority = 80

local TEX_SMOKE = "rbxasset://textures/particles/smoke_main.dds"
local TEX_SPARK = "rbxasset://textures/particles/sparkles_main.dds"
local DUST = Color3.fromRGB(196, 184, 166)
local SOOT = Color3.fromRGB(46, 42, 40)
local GLASS = Color3.fromRGB(196, 232, 248)

local controllers: { [string]: any } = {}
local player = Players.LocalPlayer

local function myPos(): Vector3?
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp then
		return hrp.Position
	end
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position
end

local function distTo(pos: Vector3): number
	local p = myPos()
	return if p then (p - pos).Magnitude else math.huge
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

local function fxFolder(): Folder
	local f = workspace:FindFirstChild("StructureFx")
	if not f then
		f = Instance.new("Folder")
		f.Name = "StructureFx"
		f.Parent = workspace
	end
	return f :: Folder
end

-- Invisible anchored holder part for emitters, removed after `life` seconds.
local function holder(cf: CFrame, size: Vector3, life: number): Part
	local p = Instance.new("Part")
	p.Name = "Fx"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = size
	p.CFrame = cf
	p.Parent = fxFolder()
	task.delay(life, function()
		p:Destroy()
	end)
	return p
end

local function emitter(parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SMOKE
	e.Enabled = false
	e.LightInfluence = 0.6
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	return e
end

local function clampSize(v: any): Vector3
	if typeof(v) ~= "Vector3" then
		return Vector3.new(8, 8, 8)
	end
	return Vector3.new(math.clamp(v.X, 2, 60), math.clamp(v.Y, 1, 40), math.clamp(v.Z, 2, 60))
end

---------------------------------------------------------------------------------------------- one-shots

local function creak(pos: Vector3, data: { [string]: any })
	local d = distTo(pos)
	if d > Cfg.ClientSmokeDistance then
		return
	end
	local warn = math.clamp(tonumber(data.warn) or 2, 0.5, 5)
	local size = clampSize(data.size)
	play("DoorBreak", pos, { speed = 0.45, volume = 0.5 }) -- slowed wood crash = a long timber groan
	local h = holder(CFrame.new(pos), Vector3.new(size.X, 0.5, size.Z), warn + 3)
	local e = emitter(h, {
		Color = ColorSequence.new(DUST),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1.6) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(1.2, 2),
		Rate = 40,
		Speed = NumberRange.new(1, 4),
		EmissionDirection = Enum.NormalId.Bottom,
		Acceleration = Vector3.new(0, -12, 0),
		SpreadAngle = Vector2.new(20, 20),
	})
	e.Enabled = true
	task.delay(warn, function()
		e.Enabled = false
	end)
	if d < Cfg.ShakeDistance then
		shake(0.35, warn)
	end
end

local function collapse(pos: Vector3, data: { [string]: any })
	local d = distTo(pos)
	if d > Cfg.ClientSmokeDistance * 1.5 then
		return
	end
	local size = clampSize(data.size)
	play("DoorBreak", pos, { speed = 0.7, volume = 1 })
	local h = holder(CFrame.new(pos), size, 9)
	local cloud = emitter(h, {
		Color = ColorSequence.new(DUST, Color3.fromRGB(150, 140, 128)),
		Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3), NumberSequenceKeypoint.new(1, 11) }),
		Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.6, 0.5), NumberSequenceKeypoint.new(1, 1) }),
		Lifetime = NumberRange.new(3, 5.5),
		Speed = NumberRange.new(8, 22),
		SpreadAngle = Vector2.new(180, 180),
		Drag = 3,
		Acceleration = Vector3.new(0, 2, 0),
		RotSpeed = NumberRange.new(-40, 40),
		Rotation = NumberRange.new(0, 360),
		Shape = Enum.ParticleEmitterShape.Box,
		ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume,
	})
	cloud:Emit(math.clamp(math.floor((size.X + size.Z) * 1.5), 24, 70))
	local splinters = emitter(h, {
		Texture = TEX_SPARK,
		Color = ColorSequence.new(Color3.fromRGB(92, 62, 40), SOOT),
		Size = NumberSequence.new(0.35, 0.15),
		Lifetime = NumberRange.new(0.8, 1.6),
		Speed = NumberRange.new(14, 30),
		SpreadAngle = Vector2.new(70, 70),
		EmissionDirection = Enum.NormalId.Top,
		Acceleration = Vector3.new(0, -60, 0),
		LightInfluence = 1,
	})
	splinters:Emit(30)
	if d < Cfg.ShakeDistance then
		shake(math.clamp(1 - d / Cfg.ShakeDistance, 0.3, 1), 0.7)
	end
end

local function shatter(pos: Vector3, data: { [string]: any })
	if distTo(pos) > Cfg.ClientSmokeDistance then
		return
	end
	local cf = if typeof(data.cf) == "CFrame" then data.cf :: CFrame else CFrame.new(pos)
	local size = if typeof(data.size) == "Vector3" then data.size :: Vector3 else Vector3.new(4, 4, 0.3)
	local h = holder(cf, size, 3)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local e = emitter(h, {
			Texture = TEX_SPARK,
			Color = ColorSequence.new(GLASS, Color3.new(1, 1, 1)),
			Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(1, 0.1) }),
			Transparency = NumberSequence.new(0.1, 0.6),
			Lifetime = NumberRange.new(0.6, 1.2),
			Speed = NumberRange.new(10, 22),
			SpreadAngle = Vector2.new(35, 35),
			EmissionDirection = face,
			Acceleration = Vector3.new(0, -70, 0),
			RotSpeed = NumberRange.new(-300, 300),
			Rotation = NumberRange.new(0, 360),
			LightEmission = 0.4,
			Shape = Enum.ParticleEmitterShape.Box,
		})
		e:Emit(14)
	end
	local puff = emitter(h, {
		Color = ColorSequence.new(SOOT),
		Size = NumberSequence.new(1.5, 5),
		Transparency = NumberSequence.new(0.3, 1),
		Lifetime = NumberRange.new(1, 2),
		Speed = NumberRange.new(6, 10),
		EmissionDirection = Enum.NormalId.Front,
		Acceleration = Vector3.new(0, 8, 0),
	})
	puff:Emit(8)
end

local stampGui: ScreenGui? = nil
local function totalLossStamp()
	if not stampGui then
		stampGui = UiKit.screen("StructureStamp", 20, true)
	end
	local gui = stampGui :: ScreenGui
	gui:ClearAllChildren()
	local label = UiKit.label(gui, "TotalLoss", "TOTAL LOSS", UDim2.fromOffset(640, 130), UDim2.fromScale(0.5, 0.36), {
		font = UiKit.Header,
		textSize = 96,
		color = Palette.UiRed or Color3.fromRGB(217, 55, 42),
		stroke = true,
		strokeThickness = 5,
	})
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Rotation = -8
	pcall(UiKit.pop, label, 0.35)
	pcall(UiKit.shake, label, 0.5, 10)
	task.delay(3, function()
		if label.Parent then
			pcall(UiKit.tween, label, 0.6, { TextTransparency = 1 })
			task.delay(0.7, function()
				label:Destroy()
			end)
		end
	end)
end

---------------------------------------------------------------------------------------------- smoke

type SmokeFx = { holder: Part, emitter: ParticleEmitter }
local windowSmoke: { [BasePart]: SmokeFx } = {}
local columns: { [Model]: SmokeFx } = {}

local function makeWindowSmoke(w: BasePart): SmokeFx
	local h = Instance.new("Part")
	h.Name = "WindowSmoke"
	h.Anchored = true
	h.CanCollide = false
	h.CanQuery = false
	h.CanTouch = false
	h.Transparency = 1
	h.Size = Vector3.new(math.max(1, w.Size.X - 0.5), math.max(1, w.Size.Y - 0.5), 0.2)
	h.CFrame = w.CFrame
	h.Parent = fxFolder()
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SMOKE
	e.Color = ColorSequence.new(Color3.fromRGB(70, 66, 62), Color3.fromRGB(28, 26, 26))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 7) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.45), NumberSequenceKeypoint.new(0.7, 0.7), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(2.5, 4)
	e.Rate = 10
	e.Speed = NumberRange.new(2, 4)
	e.SpreadAngle = Vector2.new(15, 15)
	e.Acceleration = Vector3.new(0, 7, 0) -- curls up the facade, the classic "smoke pouring out"
	e.Drag = 0.6
	e.RotSpeed = NumberRange.new(-25, 25)
	e.Rotation = NumberRange.new(0, 360)
	e.LightInfluence = 0.7
	e.Shape = Enum.ParticleEmitterShape.Box
	e.EmissionDirection = Enum.NormalId.Front -- holder faces the same way as the pane; Back too below
	e.Parent = h
	local back = e:Clone()
	back.EmissionDirection = Enum.NormalId.Back
	back.Rate = 5
	back.Parent = h
	return { holder = h, emitter = e }
end

local function makeColumn(top: Vector3): SmokeFx
	local h = Instance.new("Part")
	h.Name = "ShellSmoke"
	h.Anchored = true
	h.CanCollide = false
	h.CanQuery = false
	h.CanTouch = false
	h.Transparency = 1
	h.Size = Vector3.new(16, 1, 16)
	h.CFrame = CFrame.new(top)
	h.Parent = fxFolder()
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SMOKE
	e.Color = ColorSequence.new(Color3.fromRGB(40, 38, 38), Color3.fromRGB(90, 86, 84))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 5), NumberSequenceKeypoint.new(1, 18) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.3), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(6, 9)
	e.Rate = 7
	e.Speed = NumberRange.new(6, 10)
	e.SpreadAngle = Vector2.new(12, 12)
	e.Acceleration = Vector3.new(1.5, 2, 0) -- leans with the wind
	e.RotSpeed = NumberRange.new(-15, 15)
	e.Rotation = NumberRange.new(0, 360)
	e.LightInfluence = 0.8
	e.Shape = Enum.ParticleEmitterShape.Box
	e.EmissionDirection = Enum.NormalId.Top
	e.Parent = h
	return { holder = h, emitter = e }
end

local function refreshSmoke()
	local me = myPos()
	if not me then
		return
	end
	-- candidate windows: Broken panes of smoking buildings in range, nearest first
	local want: { { w: BasePart, d: number } } = {}
	local wantCol: { [Model]: Vector3 } = {}
	for _, m in CollectionService:GetTagged(Cfg.Tag) do
		if not m:IsA("Model") or m:GetAttribute("Smoking") ~= true then
			continue
		end
		local centre = m:GetAttribute("Center")
		if typeof(centre) ~= "Vector3" or (centre - me).Magnitude > Cfg.ClientSmokeDistance then
			continue
		end
		local top = m:GetAttribute("SmokeTop")
		if m:GetAttribute("TotalLoss") == true and typeof(top) == "Vector3" then
			wantCol[m] = top
		end
		for _, w in CollectionService:GetTagged(Names.Tag.Window) do
			if w:IsA("BasePart") and w:GetAttribute(Names.Attr.Broken) == true and w:IsDescendantOf(m) then
				table.insert(want, { w = w, d = (w.Position - me).Magnitude })
			end
		end
	end
	table.sort(want, function(a, b)
		return a.d < b.d
	end)
	local keep: { [BasePart]: boolean } = {}
	for i = 1, math.min(#want, Cfg.ClientSmokeMax) do
		local w = want[i].w
		keep[w] = true
		if not windowSmoke[w] then
			windowSmoke[w] = makeWindowSmoke(w)
		end
	end
	for w, s in windowSmoke do
		if not keep[w] then
			s.holder:Destroy()
			windowSmoke[w] = nil
		end
	end
	for m, top in wantCol do
		if not columns[m] then
			columns[m] = makeColumn(top)
		end
	end
	for m, s in columns do
		if not wantCol[m] then
			s.holder:Destroy()
			columns[m] = nil
		end
	end
end

---------------------------------------------------------------------------------------------- HUD bar

local bar: Frame? = nil
local fill: Frame? = nil
local text: TextLabel? = nil

local function ensureBar()
	if bar then
		return
	end
	local gui = UiKit.screen("StructureHud", 1)
	local panel = UiKit.panel(gui, "Integrity", UDim2.fromOffset(260, 52), UDim2.fromOffset(14, 114))
	-- left column under the objectives card (ClientLib/HudLayout owns its Position.Y)
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.add("Left", panel, 20)
	HudLayout.reserve(panel)
	local track = Instance.new("Frame")
	track.Name = "Track"
	track.BackgroundColor3 = Palette.UiInk or Color3.fromRGB(42, 20, 16)
	track.BorderSizePixel = 0
	track.Size = UDim2.new(1, -24, 0, 14)
	track.Position = UDim2.new(0, 12, 1, -22)
	UiKit.corner(track, 7)
	track.Parent = panel
	local f = Instance.new("Frame")
	f.Name = "Fill"
	f.BorderSizePixel = 0
	f.Size = UDim2.fromScale(1, 1)
	UiKit.corner(f, 7)
	f.Parent = track
	local l = UiKit.label(panel, "Label", "BUILDING 100%", UDim2.new(1, -24, 0, 26), UDim2.fromOffset(12, 3), {
		font = UiKit.Header,
		textSize = 22,
		align = Enum.TextXAlignment.Left,
	})
	panel.Visible = false
	bar, fill, text = panel, f, l
end

-- The integrity bar is only for MY run's building: the structure (or an ancestor) carries my InstanceId.
local function runOf(inst: Instance): string?
	local node: Instance? = inst
	while node and node ~= workspace do
		local id = node:GetAttribute("InstanceId")
		if type(id) == "string" and id ~= "" then
			return id
		end
		node = node.Parent
	end
	return nil
end

local shown = -1
local function refreshBar()
	local myRun = Players.LocalPlayer:GetAttribute("InstanceId")
	if type(myRun) ~= "string" or myRun == "" then
		myRun = nil -- in the lobby: no building bar at all
	end
	local me = myPos()
	local best: Model? = nil
	local bestD = Cfg.HudDistance
	if me then
		for _, m in CollectionService:GetTagged(Cfg.Tag) do
			local v = m:GetAttribute("Integrity")
			local centre = m:GetAttribute("Center")
			if typeof(v) == "number" and v < 100 and typeof(centre) == "Vector3" and myRun and runOf(m) == myRun then
				local d = (centre - me).Magnitude
				if d < bestD then
					best, bestD = m, d
				end
			end
		end
	end
	ensureBar()
	local panel, f, l = bar :: Frame, fill :: Frame, text :: TextLabel
	if not best then
		panel.Visible = false
		shown = -1
		return
	end
	panel.Visible = true
	local v = best:GetAttribute("Integrity") :: number
	local lost = best:GetAttribute("TotalLoss") == true
	if v ~= shown then
		if shown >= 0 and v < shown - 4 then
			pcall(UiKit.shake, panel, 0.3, 4)
		end
		shown = v
		pcall(UiKit.tween, f, 0.3, { Size = UDim2.fromScale(math.clamp(v / 100, 0, 1), 1) })
	end
	f.BackgroundColor3 = if v >= 60
		then Color3.fromRGB(110, 190, 90)
		elseif v >= 35 then (Palette.UiWarn or Color3.fromRGB(255, 197, 49))
		else (Palette.UiRed or Color3.fromRGB(217, 55, 42))
	l.Text = if lost then "BUILDING: TOTAL LOSS" else `BUILDING {v}%`
	l.TextColor3 = if lost then (Palette.UiRed or Color3.fromRGB(217, 55, 42)) else (Palette.UiInk or Color3.new(0, 0, 0))
end

---------------------------------------------------------------------------------------------- lifecycle

function StructureFxController:Init(all: { [string]: any })
	controllers = all
end

function StructureFxController:Start()
	local remote = Net.event("Structure", "Fx")
	remote.OnClientEvent:Connect(function(kind: string, pos: Vector3, data: any)
		if typeof(pos) ~= "Vector3" then
			return
		end
		local d = if type(data) == "table" then data else {}
		if kind == "creak" then
			creak(pos, d)
		elseif kind == "collapse" then
			collapse(pos, d)
		elseif kind == "shatter" then
			shatter(pos, d)
		elseif kind == "totalloss" then
			totalLossStamp()
		end
	end)
	task.spawn(function()
		while true do
			pcall(refreshSmoke)
			pcall(refreshBar)
			task.wait(0.5)
		end
	end)
end

return StructureFxController
