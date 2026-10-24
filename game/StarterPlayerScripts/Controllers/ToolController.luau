--!strict
-- ToolController [owner: G1]. Hose / extinguisher input, water streams, recoil, wet-floor sliding and
-- all the tool juice. The server decides every gameplay outcome; this file sends intent and renders.
--
--   Input: while the local Hose or Extinguisher is activated (mouse or touch held), send Tool/Spray
--     with the camera LookVector ToolConfig.SprayHz times a second.
--   Streams: for EVERY player whose Spraying attr is true (and the local player while held), an
--     arcing Beam (Bezier fit of the gravity arc, ToolMath.arcBezier) + stream particles + nozzle
--     burst + droplets at the impact point. Attachments live under workspace.Terrain as
--     "HoseStream_<UserId>" (+ "_Beam0", "_Beam1").
--   Recoil (local, instant): a LinearVelocity "ToolMover" on the HumanoidRootPart (horizontal plane)
--     pushes you backwards while the hose sprays, harder at full pressure (ToolMath.pressure of the
--     tank x HoseLine's HosePressure attr); you walk slower while bracing it. On a WetFloor puddle you
--     keep your momentum like ice, and spraying there launches you across the room. Aim straight down
--     long enough and you hose-rocket upwards.
--   Feel: FOV kick on spray start (scaled by pressure), continuous camera shake scaled by pressure,
--     shakes on axe swings / door hits / getting soaked (FirstPersonController:Shake, nil-guarded),
--     splash / foam white-out / BONK overlays when Tool/Pushed hits you, world text pops from Tool/Fx.
--   Ragdoll: calls Ragdoll.listen() so Shared/Ragdoll knockbacks and ragdolls apply to this client's
--     character (idempotent; PhysicsFxController may call it too).
-- Remotes used: Tool/Spray (C->S), Tool/Pushed (S->C), Tool/Fx (S->C) - all declared by ToolService.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)
local ToolMath = require(ReplicatedStorage:WaitForChild("ToolMath") :: ModuleScript)

type Stream = {
	emitAt: Attachment,
	emitter: ParticleEmitter,
	burst: ParticleEmitter,
	a0: Attachment,
	a1: Attachment,
	beam: Beam,
	core: Beam,
	splash: ParticleEmitter,
	sound: Sound?,
}

local ToolController = {}
ToolController.Priority = 60 -- after FirstPersonController (50) so its Shake exists

local LocalPlayer = Players.LocalPlayer
local controllers: { [string]: any } = {}
local holding: string? = nil -- "hose" | "foam" while the trigger is held
local holdingTool: Tool? = nil -- the exact Tool that was activated; a swapped-in copy never inherits it
local streams: { [Player]: Stream } = {}
local hookedTools: { [Tool]: true } = setmetatable({}, { __mode = "k" }) :: any
local mover: LinearVelocity? = nil
local slideV = Vector3.zero
local downSince: number? = nil
local fovKick = 0
local fovWritten: number? = nil
local fovApplied = 0
local sprayStartedAt = 0
local overlay: ScreenGui? = nil

local FOAM_COLOR = Color3.fromRGB(245, 248, 250)
local POP_FONT = Enum.Font.FredokaOne

-- helpers --------------------------------------------------------------------------------------
local function shake(magnitude: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, magnitude, seconds)
	end
end

local function playSound(id: string, parent: Instance, volume: number?, pitch: number?)
	if id == nil or id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.8
	s.PlaybackSpeed = pitch or 1
	s.RollOffMaxDistance = 80
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 4)
end

local function soundAt(id: string, pos: Vector3, volume: number?, pitch: number?)
	if id == nil or id == "" then
		return
	end
	local a = Instance.new("Attachment")
	a.WorldPosition = pos
	a.Parent = workspace.Terrain
	playSound(id, a, volume, pitch)
	Debris:AddItem(a, 4)
end

local function toolOf(player: Player): (Tool?, string?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local hose = char:FindFirstChild("Hose")
	if hose and hose:IsA("Tool") then
		return hose, "hose"
	end
	local ext = char:FindFirstChild("Extinguisher")
	if ext and ext:IsA("Tool") then
		return ext, "foam"
	end
	return nil, nil
end

local function nozzleOf(tool: Tool): Attachment?
	local handle = tool:FindFirstChild("Handle")
	local nozzle = handle and handle:FindFirstChild("Nozzle")
	return if nozzle and nozzle:IsA("Attachment") then nozzle else nil
end

local function resource(player: Player, kind: string): (number, number)
	if kind == "foam" then
		return (player:GetAttribute("Foam") :: number?) or 0, (player:GetAttribute("FoamSize") :: number?) or ToolConfig.FoamSize
	end
	return (player:GetAttribute(Names.Attr.Water) :: number?) or 0,
		(player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
end

local function pressureOf(player: Player, kind: string): number
	local left, size = resource(player, kind)
	if kind == "foam" then
		return if left > 0 then 1 else 0
	end
	local line = player:GetAttribute("HosePressure")
	return ToolMath.pressure(left, size, if type(line) == "number" then line else nil)
end

local function blocked(player: Player): boolean
	local carrying = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
	if carrying ~= "" or player:GetAttribute(Names.Attr.Downed) == true then
		return true
	end
	local char = player.Character
	return char ~= nil and Ragdoll.isRagdolled(char)
end

-- The trigger only counts while the Tool that was pressed is still the one in your hand. (Swapping
-- between two extinguishers used to leave `holding` = "foam" if the old Tool vanished without an
-- Unequipped, and the next extinguisher then foamed on its own.)
local function heldKind(): string?
	local t = holdingTool
	if holding and t and t.Parent ~= nil and t.Parent == LocalPlayer.Character then
		return holding
	end
	holding, holdingTool = nil, nil
	return nil
end

local function isFirstPerson(): boolean
	local cam = workspace.CurrentCamera
	return cam ~= nil and (cam.Focus.Position - cam.CFrame.Position).Magnitude < 1.5
end

local function flatAim(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.zero
end

-- An attachment CFrame whose X axis (Beam curve axis) points along `axis`.
local function axisCFrame(pos: Vector3, axis: Vector3): CFrame
	local x = if axis.Magnitude > 1e-4 then axis.Unit else Vector3.xAxis
	local helper = if math.abs(x.Y) > 0.95 then Vector3.zAxis else Vector3.yAxis
	local z = x:Cross(helper).Unit
	local y = z:Cross(x).Unit
	return CFrame.fromMatrix(pos, x, y, z)
end

-- overlays and pops ------------------------------------------------------------------------------
local function screen(): ScreenGui
	local g = overlay
	if g and g.Parent then
		return g
	end
	local pg = LocalPlayer:WaitForChild("PlayerGui")
	local ng = Instance.new("ScreenGui")
	ng.Name = "ToolFx"
	ng.IgnoreGuiInset = true
	ng.ResetOnSpawn = false
	ng.DisplayOrder = 20
	ng.Parent = pg
	overlay = ng
	return ng
end

local function flash(color: Color3, from: number, hold: number, fade: number)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(1, 1)
	f.BackgroundColor3 = color
	f.BackgroundTransparency = from
	f.BorderSizePixel = 0
	f.Parent = screen()
	task.delay(hold, function()
		TweenService:Create(f, TweenInfo.new(fade), { BackgroundTransparency = 1 }):Play()
	end)
	Debris:AddItem(f, hold + fade + 0.1)
end

local function droplets(count: number)
	local g = screen()
	local rng = Random.new()
	for _ = 1, count do
		local d = Instance.new("Frame")
		local s = rng:NextInteger(14, 46)
		d.Size = UDim2.fromOffset(s, s * 1.3)
		d.Position = UDim2.fromScale(rng:NextNumber(0.05, 0.95), rng:NextNumber(0.05, 0.7))
		d.BackgroundColor3 = Palette.WaterSpray
		d.BackgroundTransparency = 0.35
		d.BorderSizePixel = 0
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.5, 0)
		c.Parent = d
		d.Parent = g
		local fall = rng:NextNumber(0.6, 1.2)
		TweenService:Create(d, TweenInfo.new(fall, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Position = d.Position + UDim2.fromScale(0, rng:NextNumber(0.1, 0.3)),
			BackgroundTransparency = 1,
		}):Play()
		Debris:AddItem(d, fall + 0.1)
	end
end

local function screenText(text: string, color: Color3)
	-- was huge centre-screen text; now a small popup over you (ClientLib/WorldPopup)
	WorldPopup.show(LocalPlayer.Character, text, { color = color, mine = true })
end

local function worldPop(text: string, pos: Vector3, color: Color3, mine: boolean?)
	-- subtle world text (ClientLib/WorldPopup: caps, dedupe, feedback setting)
	WorldPopup.show(WorldPopup.subjectAt(pos, 4), text, { color = color, mine = mine })
end

local function nearMe(pos: Vector3, studs: number): number
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return 0
	end
	return math.clamp(1 - (root.Position - pos).Magnitude / studs, 0, 1)
end

-- streams ----------------------------------------------------------------------------------------
local function newEmitter(parent: Attachment): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.LightInfluence = 0.6
	e.LightEmission = 0.2
	e.Parent = parent
	return e
end

local function ensureStream(player: Player): Stream
	local s = streams[player]
	if s then
		return s
	end
	local terrain = workspace.Terrain
	local emitAt = Instance.new("Attachment")
	emitAt.Name = `HoseStream_{player.UserId}`
	emitAt.Parent = terrain
	local a0 = Instance.new("Attachment")
	a0.Name = `HoseStream_{player.UserId}_Beam0`
	a0.Parent = terrain
	local a1 = Instance.new("Attachment")
	a1.Name = `HoseStream_{player.UserId}_Beam1`
	a1.Parent = terrain

	local e = newEmitter(emitAt)
	e.EmissionDirection = Enum.NormalId.Front
	e.Transparency = NumberSequence.new(0.15, 0.7)
	e.Size = NumberSequence.new(0.5, 1.4)
	e.Lifetime = NumberRange.new(0.5, 0.6)
	e.Rate = 140
	e.SpreadAngle = Vector2.new(2.5, 2.5)
	e.Acceleration = Vector3.new(0, -ToolConfig.StreamGravity, 0)

	local burst = newEmitter(emitAt) -- the spiky "splash star" at the nozzle sells the pressure
	burst.EmissionDirection = Enum.NormalId.Front
	burst.Color = ColorSequence.new(Color3.new(1, 1, 1))
	burst.Transparency = NumberSequence.new(0.1, 1)
	burst.Size = NumberSequence.new(0.3, 0.05)
	burst.Lifetime = NumberRange.new(0.12, 0.18)
	burst.Rate = 60
	burst.Speed = NumberRange.new(6, 12)
	burst.SpreadAngle = Vector2.new(60, 60)

	local function beam(width0: number, width1: number, transparency: number): Beam
		local b = Instance.new("Beam")
		b.Attachment0 = a0
		b.Attachment1 = a1
		b.Width0 = width0
		b.Width1 = width1
		b.Segments = 16
		b.FaceCamera = true
		b.LightEmission = 0.3
		b.LightInfluence = 0.5
		b.Transparency = NumberSequence.new(transparency, math.min(1, transparency + 0.3))
		b.Enabled = false
		b.Parent = a0
		return b
	end
	local outer = beam(0.35, 1.2, 0.35)
	local core = beam(0.15, 0.45, 0.1)

	local splash = newEmitter(a1)
	splash.EmissionDirection = Enum.NormalId.Top
	splash.Transparency = NumberSequence.new(0.2, 1)
	splash.Size = NumberSequence.new(0.35, 0.1)
	splash.Lifetime = NumberRange.new(0.3, 0.45)
	splash.Rate = 70
	splash.Speed = NumberRange.new(8, 14)
	splash.SpreadAngle = Vector2.new(70, 70)
	splash.Acceleration = Vector3.new(0, -60, 0)

	local sound: Sound? = nil
	if ToolConfig.SoundHoseLoop ~= "" then
		local snd = Instance.new("Sound")
		snd.SoundId = ToolConfig.SoundHoseLoop
		snd.Looped = true
		snd.Volume = 0.5
		snd.RollOffMaxDistance = 70
		snd.Parent = emitAt
		sound = snd
	end

	s = {
		emitAt = emitAt,
		emitter = e,
		burst = burst,
		a0 = a0,
		a1 = a1,
		beam = outer,
		core = core,
		splash = splash,
		sound = sound,
	}
	streams[player] = s
	return s
end

local function setStreamOn(s: Stream, on: boolean)
	s.emitter.Enabled = on
	s.burst.Enabled = on
	s.beam.Enabled = on
	s.core.Enabled = on
	s.splash.Enabled = on
	local snd = s.sound
	if snd then
		if on and not snd.IsPlaying then
			snd:Play()
		elseif not on and snd.IsPlaying then
			snd:Stop()
		end
	end
end

local function dropStream(player: Player)
	local s = streams[player]
	if s then
		s.emitAt:Destroy()
		s.a0:Destroy()
		s.a1:Destroy()
		streams[player] = nil
	end
end

local function aimOf(player: Player): Vector3?
	if player == LocalPlayer then
		local cam = workspace.CurrentCamera
		return cam and cam.CFrame.LookVector
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	return head and head.CFrame.LookVector
end

local function originOf(player: Player, tool: Tool): Vector3?
	if player == LocalPlayer and isFirstPerson() then
		-- the third-person tool is hidden in first person; start where the viewmodel nozzle sits
		local fp = controllers.FirstPersonController
		local at = fp and fp.GetNozzlePosition and fp:GetNozzlePosition()
		if typeof(at) == "Vector3" then
			return at -- the physics hands' bucking nozzle (v2)
		end
		local cam = workspace.CurrentCamera :: Camera
		return (cam.CFrame * CFrame.new(0.7, -0.75, -2.2)).Position
	end
	local nozzle = nozzleOf(tool)
	return nozzle and nozzle.WorldPosition
end

local function renderStream(player: Player, kind: string, tool: Tool, aim: Vector3, now: number)
	local origin = originOf(player, tool)
	if not origin then
		return
	end
	local s = ensureStream(player)
	local pressure = pressureOf(player, kind)
	local foam = kind == "foam"
	local speed = if foam then 32 else ToolConfig.StreamSpeed * (0.6 + 0.4 * pressure)
	local g = if foam then 30 else ToolConfig.StreamGravity
	local maxT = if foam then ToolConfig.FoamRange / 32 else ToolConfig.StreamMaxTime
	local v = aim * speed
	-- find where the arc lands (excluding the sprayer)
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local excl: { Instance } = { workspace.Terrain }
	if player.Character then
		table.insert(excl, player.Character)
	end
	local puddles = workspace:FindFirstChild("Puddles")
	if puddles then
		table.insert(excl, puddles)
	end
	rp.FilterDescendantsInstances = excl
	rp.IgnoreWater = true
	local T = maxT
	local prev = origin
	local steps = 6
	for i = 1, steps do
		local t = maxT * i / steps
		local x, y, z = ToolMath.arcPoint(origin.X, origin.Y, origin.Z, v.X, v.Y, v.Z, g, t)
		local p = Vector3.new(x, y, z)
		local hit = workspace:Raycast(prev, p - prev, rp)
		if hit then
			local seg = (p - prev).Magnitude
			local frac = if seg > 1e-4 then (hit.Position - prev).Magnitude / seg else 1
			T = maxT * (i - 1 + frac) / steps
			break
		end
		prev = p
	end
	T = math.max(T, 0.03)
	local c = ToolMath.arcBezier(origin.X, origin.Y, origin.Z, v.X, v.Y, v.Z, g, T)
	local p1 = Vector3.new(c[1][1], c[1][2], c[1][3])
	local p2 = Vector3.new(c[2][1], c[2][2], c[2][3])
	local p3 = Vector3.new(c[3][1], c[3][2], c[3][3])
	s.a0.WorldCFrame = axisCFrame(origin, p1 - origin)
	s.a1.WorldCFrame = axisCFrame(p3, p3 - p2)
	s.beam.CurveSize0 = (p1 - origin).Magnitude
	s.beam.CurveSize1 = (p3 - p2).Magnitude
	s.core.CurveSize0 = s.beam.CurveSize0
	s.core.CurveSize1 = s.beam.CurveSize1
	s.emitAt.WorldCFrame = CFrame.lookAt(origin, origin + aim)

	local color = if foam then FOAM_COLOR else Palette.WaterSpray
	s.emitter.Color = ColorSequence.new(color)
	s.beam.Color = ColorSequence.new(color)
	s.core.Color = ColorSequence.new(Color3.new(1, 1, 1))
	s.splash.Color = ColorSequence.new(color)
	s.emitter.Speed = NumberRange.new(speed * 0.93, speed * 1.07)
	s.emitter.Acceleration = Vector3.new(0, -g, 0)
	s.emitter.Size = if foam then NumberSequence.new(0.8, 2.4) else NumberSequence.new(0.5, 1.4)
	s.beam.Width1 = if foam then 2.2 else 0.6 + 0.8 * pressure
	s.burst.Rate = 20 + 60 * pressure

	-- low tank: the stream sputters in pulses
	local left, size = resource(player, kind)
	local sputter = left < size * ToolConfig.LowWaterFraction and math.sin(now * 22) > 0.2
	s.emitter.Rate = if sputter then 15 else if foam then 90 else 60 + 80 * pressure
	setStreamOn(s, true)
	if sputter then
		s.beam.Enabled = false
		s.core.Enabled = false
	end
end

local function render()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local tool, kind = toolOf(player)
		local on = player:GetAttribute(Names.Attr.Spraying) == true
		if player == LocalPlayer then
			local h = heldKind()
			on = (h ~= nil and kind == h and (resource(player, kind :: string)) > 0 and not blocked(player))
		end
		local aim = aimOf(player)
		if tool and kind and on and aim then
			renderStream(player, kind, tool, aim, now)
		elseif streams[player] then
			setStreamOn(streams[player], false)
		end
	end
end

-- recoil, wet floors, hose rocket (local character) -----------------------------------------------
local function ensureMover(root: BasePart): LinearVelocity
	local m = mover
	if m and m.Parent and (m.Attachment0 :: Attachment?) and (m.Attachment0 :: Attachment).Parent == root then
		return m
	end
	local att = root:FindFirstChild("ToolMoverAtt") :: Attachment?
	if not att then
		local a = Instance.new("Attachment")
		a.Name = "ToolMoverAtt"
		a.Parent = root
		att = a
	end
	local lv = Instance.new("LinearVelocity")
	lv.Name = "ToolMover"
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	lv.PrimaryTangentAxis = Vector3.xAxis
	lv.SecondaryTangentAxis = Vector3.zAxis
	lv.Enabled = false
	lv.Parent = root
	mover = lv
	return lv
end

local function onWetFloor(root: BasePart): boolean
	for _, inst in CollectionService:GetTagged(Names.Tag.WetFloor) do
		if inst:IsA("BasePart") then
			local p = inst.CFrame:PointToObjectSpace(root.Position)
			if inst.Shape == Enum.PartType.Cylinder then
				-- cylinder axis is X (puddles lie with X up)
				if math.abs(p.X) < 5 and math.sqrt(p.Y * p.Y + p.Z * p.Z) <= inst.Size.Y / 2 then
					return true
				end
			else
				local h = inst.Size / 2
				if math.abs(p.X) <= h.X and math.abs(p.Z) <= h.Z and p.Y > -1 and p.Y < h.Y + 5 then
					return true
				end
			end
		end
	end
	return false
end

local function physicsStep(dt: number)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (char and hum and root) or hum.Health <= 0 then
		return
	end
	if hum.SeatPart then
		-- seated, the root's assembly is the whole vehicle: recoil / hose-rocket / wet-floor movers
		-- on it would shove (and flip) the truck
		if mover then
			mover.Enabled = false
		end
		downSince = nil
		return
	end
	local m = ensureMover(root)
	local _, kind = toolOf(LocalPlayer)
	local cam = workspace.CurrentCamera
	local spraying = heldKind() == "hose" and kind == "hose" and (resource(LocalPlayer, "hose")) > 0 and not blocked(LocalPlayer)
	local pressure = if spraying then pressureOf(LocalPlayer, "hose") else 0
	local aim = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)

	-- hose rocket: aim straight down for a moment and the hose lifts you
	if spraying and -aim.Y >= ToolConfig.HoseRocketCos then
		downSince = downSince or os.clock()
		if os.clock() - (downSince :: number) >= ToolConfig.HoseRocketSeconds then
			local v = root.AssemblyLinearVelocity
			local up = ToolConfig.HoseRocketSpeed * pressure
			if v.Y < up then
				root.AssemblyLinearVelocity = Vector3.new(v.X, up, v.Z)
			end
		end
	else
		downSince = nil
	end

	local ragdolled = Ragdoll.isRagdolled(char)
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local wet = grounded and onWetFloor(root)
	local cur = root.AssemblyLinearVelocity
	local curH = Vector3.new(cur.X, 0, cur.Z)
	if ragdolled or not grounded or not (spraying or wet) then
		m.Enabled = false
		slideV = curH
		return
	end
	local back = -flatAim(aim) * ToolMath.recoilSpeed(ToolConfig.HoseRecoilSpeed, pressure, false)
	local want = hum.MoveDirection * hum.WalkSpeed
	local target: Vector3
	if wet then
		-- ice: momentum carries, input barely steers, and the hose keeps accelerating you backwards
		local x, z = ToolMath.slide(slideV.X, slideV.Z, want.X, want.Z, ToolConfig.WetGrip, dt)
		slideV = Vector3.new(x, 0, z) + back * 2.5 * dt
		if slideV.Magnitude > ToolConfig.WetMaxSpeed then
			slideV = slideV.Unit * ToolConfig.WetMaxSpeed
		end
		target = slideV
	else
		target = want * ToolConfig.SprayWalkScale + back
		slideV = target
	end
	m.MaxForce = root.AssemblyMass * ToolConfig.HoseRecoilForce
	m.PlaneVelocity = Vector2.new(target.X, target.Z)
	m.Enabled = true
end

-- FOV kick (runs after FirstPersonController's camera step, adds on top of its FOV) ----------------
local function fovStep(dt: number)
	local cam = workspace.CurrentCamera
	if not cam or cam.CameraType == Enum.CameraType.Scriptable then
		fovWritten = nil
		return
	end
	local active = heldKind() ~= nil and toolOf(LocalPlayer) ~= nil and not blocked(LocalPlayer)
	local _, kind = toolOf(LocalPlayer)
	local target = if active and kind then ToolConfig.SprayFovKick * pressureOf(LocalPlayer, kind) else 0
	-- snap in (punch), ease out
	local rate = if target > fovKick then 30 else 5
	fovKick += (target - fovKick) * math.min(1, dt * rate)
	-- if nobody rewrote the FOV since our last write, remove our previous offset first
	local base = cam.FieldOfView
	if fovWritten and math.abs(cam.FieldOfView - fovWritten) < 1e-3 then
		base -= fovApplied
	end
	fovApplied = fovKick
	local fov = math.clamp(base + fovKick, 1, 120)
	cam.FieldOfView = fov
	fovWritten = fov
end

-- input ------------------------------------------------------------------------------------------
local function hookTool(inst: Instance)
	if not inst:IsA("Tool") or hookedTools[inst] then
		return
	end
	local name = inst.Name
	if name ~= "Hose" and name ~= "Extinguisher" and name ~= "Axe" then
		return
	end
	hookedTools[inst] = true
	local tool = inst :: Tool
	if name == "Axe" then
		-- press = wind-up, release = the chop (ClientLib/AxeArm): the whoosh is on release
		tool.Deactivated:Connect(function()
			shake(0.18, 0.25)
			local handle = tool:FindFirstChild("Handle")
			if handle then
				playSound(ToolConfig.SoundAxeWhoosh, handle, 0.9, Random.new():NextNumber(0.9, 1.15))
			end
			fovKick -= 3 -- a quick inward punch on the swing
		end)
		return
	end
	local kind = if name == "Hose" then "hose" else "foam"
	tool.Activated:Connect(function()
		holding, holdingTool = kind, tool
		sprayStartedAt = os.clock()
		shake(0.2 * pressureOf(LocalPlayer, kind), 0.2) -- the kick when the valve opens
	end)
	local function letGo()
		if holdingTool == tool then
			holding, holdingTool = nil, nil
		end
	end
	tool.Deactivated:Connect(letGo)
	tool.Unequipped:Connect(letGo)
	tool.Destroying:Connect(letGo)
end

local function hookCharacter(char: Model)
	holding, holdingTool = nil, nil
	mover = nil
	slideV = Vector3.zero
	char.ChildAdded:Connect(hookTool)
	for _, child in char:GetChildren() do
		hookTool(child)
	end
end

-- remotes from the server ------------------------------------------------------------------------
-- The shove itself already arrived through Shared/Ragdoll (Ragdoll.knockback); this is the juice.
local function onPushed(_velocity: any, _fromUserId: any, kind: any)
	if kind == "foam" then
		flash(FOAM_COLOR, 0, 1.2, 0.5) -- snowblind
		shake(0.25, 0.3)
		screenText("FOAMED!", Color3.new(1, 1, 1))
	elseif kind == "axe" then
		shake(0.6, 0.4)
		flash(Color3.new(1, 1, 1), 0.6, 0.03, 0.15)
		screenText("BONK!", Color3.fromRGB(255, 220, 60))
	else
		shake(0.3, 0.3)
		flash(Palette.WaterSpray, 0.55, 0.05, 0.5)
		droplets(6)
		local char = LocalPlayer.Character
		local head = char and char:FindFirstChild("Head")
		if head then
			playSound(ToolConfig.SoundSplash, head, 0.6, Random.new():NextNumber(0.9, 1.2))
		end
	end
end

local POPS: { [string]: { text: string, color: Color3 } } = {
	chop = { text = "CHOP!", color = Color3.fromRGB(255, 200, 90) },
	crack = { text = "CRACK!", color = Color3.fromRGB(255, 120, 50) },
	bonk = { text = "BONK!", color = Color3.fromRGB(255, 230, 60) },
	sploosh = { text = "SPLOOSH!", color = Color3.fromRGB(120, 210, 255) },
}

local function onFx(kind: any, position: any, extra: any)
	if type(kind) ~= "string" or typeof(position) ~= "Vector3" then
		return
	end
	local pos = position :: Vector3
	local mine = extra == LocalPlayer.UserId
	if kind == "whoosh" then
		if not mine then
			soundAt(ToolConfig.SoundAxeWhoosh, pos, 0.7)
		end
		return
	elseif kind == "refill" then
		soundAt(ToolConfig.SoundRefill, pos, 0.7)
		if mine then
			worldPop("GLUG GLUG", pos + Vector3.new(0, 3, 0), Palette.WaterSpray, true)
		end
		return
	end
	local pop = POPS[kind]
	if pop then
		worldPop(pop.text, pos, pop.color, mine)
	end
	if kind == "chop" then
		soundAt(ToolConfig.SoundAxeThunk, pos, 0.9)
		shake(0.25 * nearMe(pos, 14), 0.2)
		if mine then
			fovKick += 2.5 -- impact punch: snap out, eases back with the spray kick
			flash(Color3.new(1, 1, 1), 0.88, 0.02, 0.08) -- one-frame impact flash
		end
	elseif kind == "crack" then
		soundAt(ToolConfig.SoundDoorCrash, pos, 1)
		shake(0.55 * nearMe(pos, 30), 0.45)
		if mine then
			fovKick += 4
			flash(Color3.fromRGB(255, 236, 200), 0.8, 0.03, 0.12)
		end
	elseif kind == "bonk" then
		soundAt(ToolConfig.SoundBonk, pos, 1, Random.new():NextNumber(0.9, 1.3))
	elseif kind == "sploosh" then
		soundAt(ToolConfig.SoundSplash, pos, 1)
	end
end

-- controller -------------------------------------------------------------------------------------
function ToolController:Init(all: { [string]: any })
	controllers = all
end

function ToolController:Start()
	Ragdoll.listen()
	local Spray = Net.event("Tool", "Spray")
	Net.event("Tool", "Pushed").OnClientEvent:Connect(onPushed)
	Net.event("Tool", "Fx").OnClientEvent:Connect(onFx)
	LocalPlayer.CharacterAdded:Connect(hookCharacter)
	if LocalPlayer.Character then
		hookCharacter(LocalPlayer.Character)
	end
	Players.PlayerRemoving:Connect(dropStream)
	RunService.RenderStepped:Connect(render)
	RunService.Heartbeat:Connect(physicsStep)
	RunService:BindToRenderStep("ToolFov", Enum.RenderPriority.Camera.Value + 3, fovStep)
	while true do
		task.wait(1 / ToolConfig.SprayHz)
		local cam = workspace.CurrentCamera
		local _, kind = toolOf(LocalPlayer)
		local h = heldKind()
		if h and cam and kind == h and not blocked(LocalPlayer) then
			local left = resource(LocalPlayer, kind)
			if left > 0 then
				Spray:FireServer(cam.CFrame.LookVector)
				local p = pressureOf(LocalPlayer, kind)
				local ramp = math.clamp((os.clock() - sprayStartedAt) / 0.4, 0.4, 1)
				shake(ToolMath.shake(p, ToolConfig.SprayShakeBase, ToolConfig.SprayShakeExtra) * 0.45 * ramp, 0.18)
			end
		end
	end
end

return ToolController
