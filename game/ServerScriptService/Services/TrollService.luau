--!strict
-- TrollService [owner: Admin]. The goofy, kid-safe troll commands behind AdminService (:fling, :rocket,
-- :spin, :tiny, :giant, :bighead, :ragdoll, :noodle, :explode, :slap, :jail, :clone, :penguinrain,
-- :dance, :confetti, :sparkles, :fakeban, :invert, :normal). Server-authoritative: AdminService checks
-- ranks, targets and rate limits, then calls :Run. Nothing here damages, saves or touches missions, and
-- EVERY effect reverts by itself (AdminConfig.Troll timings); :Revert / :normal undoes them at once.
-- A respawn or leaving reverts everything except jail (a respawn goes back into the cage until it ends).
--
-- Public API:
--   TrollService:Run(kind: string, target: Player, by: Player): (boolean, string)
--   TrollService:Revert(target: Player, kind: string?): number   -- reverts that kind (nil = all); count
--   TrollService:Active(target: Player): { string }               -- kinds currently on the player
--   TrollService.Kinds: { string }                                -- every kind :Run accepts
-- Remotes: Troll/Fx (S->C target: kind "fakeban", seconds: number, by: string)
-- Writes: Player attrs TrollInverted (TrollController flips controls), TrollJailed;
--   Folder Workspace.AdminTrolls (cages, clones, plush penguins, boom puffs; all temporary)
-- Uses: Shared/Ragdoll, PhysicsFxService:Impulse / :Pop (nil-guarded), HandsConfig/HandsMath slap
--   numbers + the Hands/Fx "slap" pop, ForgeTelemetry.
-- Counters: trolls_run, trolls_reverted
-- Test hooks (DevHook only): _active(player) -> "kind,kind", _selftest()

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript) :: any
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("AdminConfig") :: ModuleScript) :: any
local HandsConfig = require(ConfigFolder:WaitForChild("HandsConfig") :: ModuleScript) :: any
local HandsMath = require(ReplicatedStorage:WaitForChild("HandsMath") :: ModuleScript) :: any

local TrollService = {}
TrollService.Priority = 75

local T = Cfg.Troll
local A = Cfg.Attr

type Entry = { revert: () -> (), keepOnRespawn: boolean? }

local services: { [string]: any } = {}
local active: { [Player]: { [string]: Entry } } = {}
local fxRemote: RemoteEvent? = nil
local folder: Folder? = nil
local clones = 0
local penguins = 0
local penguinTemplate: Model? = nil

TrollService.Kinds = {
	"fling", "rocket", "spin", "tiny", "giant", "bighead", "ragdoll", "noodle", "explode", "slap", "jail",
	"clone", "penguinrain", "dance", "confetti", "sparkles", "fakeban", "invert",
}

------------------------------------------------------------------------------------------- utils

local function trollFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local nf = workspace:FindFirstChild("AdminTrolls") :: Folder?
	if not nf then
		nf = Instance.new("Folder")
		nf.Name = "AdminTrolls"
		nf.Parent = workspace
	end
	folder = nf
	return nf :: Folder
end

local function charOf(p: Player): (Model?, Humanoid?, BasePart?)
	local c = p.Character
	if not c then
		return nil, nil, nil
	end
	local hum = c:FindFirstChildOfClass("Humanoid")
	local root = c:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root or hum.Health <= 0 then
		return nil, nil, nil
	end
	return c, hum, root
end

local function pop(kind: string, pos: Vector3, word: string)
	local Fx = services.PhysicsFxService
	if Fx and type(Fx.Pop) == "function" then
		pcall(Fx.Pop, Fx, kind, pos, word)
	end
end

local function impulse(p: Player, v: Vector3, by: Player?, ragdollSeconds: number?)
	local Fx = services.PhysicsFxService
	local ok = false
	if Fx and type(Fx.Impulse) == "function" then
		local okCall, res = pcall(Fx.Impulse, Fx, p, v, by)
		ok = okCall and res == true
	end
	local c = p.Character
	if not ok and c then
		Ragdoll.knockback(c, v)
	end
	if c and ragdollSeconds and ragdollSeconds > 0 then
		Ragdoll.enable(c, ragdollSeconds)
	end
end

local function randomFlat(): Vector3
	local a = math.random() * math.pi * 2
	return Vector3.new(math.cos(a), 0, math.sin(a))
end

-- Registers a revertable effect: replaces (reverts) the same kind first; reverts by itself after
-- `seconds` unless something newer took its place.
local function track(p: Player, kind: string, revert: () -> (), seconds: number?, keepOnRespawn: boolean?)
	local t = active[p]
	if not t then
		t = {}
		active[p] = t
	end
	local prev = t[kind]
	if prev then
		t[kind] = nil
		pcall(prev.revert)
	end
	local entry: Entry = { revert = revert, keepOnRespawn = keepOnRespawn }
	t[kind] = entry
	if seconds then
		task.delay(seconds, function()
			local cur = active[p]
			if cur and cur[kind] == entry then
				cur[kind] = nil
				local ok, err = pcall(revert)
				if not ok then
					warn(`[TrollService] revert {kind}: {err}`)
				end
				Telemetry.count("trolls_reverted")
			end
		end)
	end
end

local function revert(p: Player, kind: string?, respawn: boolean?): number
	local t = active[p]
	if not t then
		return 0
	end
	local n = 0
	for k, e in t do
		if (kind == nil or k == kind) and not (respawn and e.keepOnRespawn) then
			t[k] = nil
			local ok, err = pcall(e.revert)
			if not ok then
				warn(`[TrollService] revert {k}: {err}`)
			end
			n += 1
		end
	end
	if n > 0 then
		Telemetry.count("trolls_reverted", n)
	end
	return n
end

local function attach(root: BasePart, name: string, pos: Vector3?): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.Position = pos or Vector3.zero
	a.Parent = root
	return a
end

local function part(name: string, size: Vector3, cf: CFrame, color: Color3, parent: Instance, anchored: boolean?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Anchored = anchored ~= false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	p.Parent = parent
	return p
end

local function groundBelow(pos: Vector3, ignore: { Instance }): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	local hit = workspace:Raycast(pos, Vector3.new(0, -200, 0), params)
	return hit and hit.Position
end

local CONFETTI = {
	Color3.fromHex("#E8412C"), Color3.fromHex("#FFC531"), Color3.fromHex("#4FB3D9"), Color3.fromHex("#6CC24A"),
	Color3.fromHex("#FF7AB6"), Color3.fromHex("#B07CFF"),
}

local function burst(at: Attachment, count: number, speed: number?)
	for _, c in CONFETTI do
		local e = Instance.new("ParticleEmitter")
		e.Name = "Confetti"
		e.Enabled = false
		e.Color = ColorSequence.new(c)
		e.Size = NumberSequence.new(0.3)
		e.Squash = NumberSequence.new(-0.6)
		e.Lifetime = NumberRange.new(1.8, 2.8)
		e.Speed = NumberRange.new((speed or 18) * 0.6, speed or 18)
		e.SpreadAngle = Vector2.new(80, 80)
		e.Acceleration = Vector3.new(0, -20, 0)
		e.Drag = 1
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-300, 300)
		e.EmissionDirection = Enum.NormalId.Top
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Parent = at
		e:Emit(math.max(1, math.floor(count / #CONFETTI)))
	end
end

------------------------------------------------------------------------------------------ effects

local K: { [string]: (Player, Player) -> (boolean, string) } = {}

K.fling = function(p, by)
	local _, _, root = charOf(p)
	if not root then
		return false, "no character"
	end
	impulse(p, randomFlat() * T.FlingSpeed + Vector3.new(0, T.FlingLift, 0), by, 2.5)
	pop("shove", root.Position + Vector3.new(0, 3, 0), "YEET!")
	return true, "flung"
end

K.rocket = function(p, _by)
	local c, hum, root = charOf(p)
	if not c or not hum or not root then
		return false, "no character"
	end
	local made: { Instance } = {}
	local alive = true
	local function cleanup()
		alive = false
		for _, i in made do
			i:Destroy()
		end
		made = {}
	end
	track(p, "rocket", cleanup, T.RocketMaxSeconds)
	local att = attach(root, "TrollRocket")
	table.insert(made, att)
	local a0 = attach(root, "TrollTrail0", Vector3.new(-0.6, -1, 0))
	local a1 = attach(root, "TrollTrail1", Vector3.new(0.6, -1, 0))
	table.insert(made, a0)
	table.insert(made, a1)
	local trail = Instance.new("Trail")
	trail.Name = "TrollRocketTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Lifetime = 0.7
	trail.LightEmission = 0.8
	trail.Color = ColorSequence.new(Color3.fromHex("#FFC531"), Color3.fromHex("#E8412C"))
	trail.Transparency = NumberSequence.new(0, 1)
	trail.WidthScale = NumberSequence.new(1, 0.2)
	trail.Parent = root
	table.insert(made, trail)
	local flame = Instance.new("Fire")
	flame.Name = "TrollRocketFlame"
	flame.Size = 4
	flame.Heat = -12
	flame.Parent = root
	table.insert(made, flame)
	local lv = Instance.new("LinearVelocity")
	lv.Name = "TrollRocketLift"
	lv.Attachment0 = att
	lv.MaxForce = 1e7
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.VectorVelocity = Vector3.new(0, T.RocketSpeed, 0)
	lv.Parent = root
	table.insert(made, lv)
	pop("shove", root.Position + Vector3.new(0, 3, 0), "WHOOSH!")
	task.spawn(function()
		task.wait(T.RocketSeconds)
		if not alive or not root.Parent then
			return
		end
		-- parachute: a slow straight-down velocity (vertical only, so they can still steer)
		flame:Destroy()
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
		lv.LineDirection = Vector3.new(0, 1, 0)
		lv.LineVelocity = -T.RocketFallSpeed
		lv.MaxForce = 1e6
		local chute = part("TrollParachute", Vector3.new(7, 0.6, 7), root.CFrame * CFrame.new(0, 6, 0), Color3.fromHex("#E8412C"), c, false)
		chute.Shape = Enum.PartType.Cylinder
		chute.Size = Vector3.new(0.6, 7, 7)
		chute.CFrame = root.CFrame * CFrame.new(0, 6, 0) * CFrame.Angles(0, 0, math.rad(90))
		chute.CanCollide = false
		chute.CanQuery = false
		chute.CanTouch = false
		chute.Massless = true
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = chute
		w.Parent = chute
		table.insert(made, chute)
		pop("shove", root.Position + Vector3.new(0, 8, 0), "PARACHUTE!")
		local t0 = os.clock()
		while alive and root.Parent and os.clock() - t0 < T.RocketMaxSeconds do
			local g = groundBelow(root.Position, { c, trollFolder() })
			if g and root.Position.Y - g.Y < 4.5 then
				break
			end
			task.wait(0.1)
		end
		if alive then
			revert(p, "rocket")
		end
	end)
	return true, "blasted off"
end

K.spin = function(p, _by)
	local _, hum, root = charOf(p)
	if not hum or not root then
		return false, "no character"
	end
	local att = attach(root, "TrollSpin")
	local av = Instance.new("AngularVelocity")
	av.Name = "TrollSpin"
	av.Attachment0 = att
	av.MaxTorque = 1e7
	av.RelativeTo = Enum.ActuatorRelativeTo.World
	av.AngularVelocity = Vector3.new(0, T.SpinSpeed, 0)
	av.Parent = root
	local auto = hum.AutoRotate
	hum.AutoRotate = false
	track(p, "spin", function()
		av:Destroy()
		att:Destroy()
		if hum.Parent then
			hum.AutoRotate = auto
		end
	end, T.SpinSeconds)
	pop("shove", root.Position + Vector3.new(0, 3, 0), "WHEEE!")
	return true, "spinning"
end

local function scaleTo(p: Player, factor: number, word: string): (boolean, string)
	local c, _, root = charOf(p)
	if not c or not root then
		return false, "no character"
	end
	local t = active[p]
	local base = c:GetAttribute("TrollBaseScale")
	if type(base) ~= "number" or not (t and t.scale) then
		base = c:GetScale()
	end
	local baseScale = base :: number
	c:SetAttribute("TrollBaseScale", baseScale)
	local target = baseScale * factor
	local from = c:GetScale()
	c:ScaleTo(target)
	if target > from then
		c:PivotTo(c:GetPivot() + Vector3.new(0, 2.5 * (target - from), 0)) -- feet stay above the floor
	end
	track(p, "scale", function()
		if c.Parent and p.Character == c then
			c:ScaleTo(baseScale)
		end
		c:SetAttribute("TrollBaseScale", nil)
	end, T.ScaleSeconds)
	pop("shove", root.Position + Vector3.new(0, 3 * factor, 0), word)
	return true, word
end

K.tiny = function(p, _by)
	return scaleTo(p, T.TinyScale, "tiny!")
end

K.giant = function(p, _by)
	return scaleTo(p, T.GiantScale, "GIANT!")
end

-- Every part rigidly welded to the Head (the costume's bean head, helmet, eyes, pupils): grow them
-- around the neck. The Head itself is invisible under the costume and keeps its size (neck, physics).
K.bighead = function(p, _by)
	local c, _, root = charOf(p)
	local head = c and c:FindFirstChild("Head") :: BasePart?
	if not c or not root or not head then
		return false, "no head"
	end
	revert(p, "bighead")
	local k = T.BigHeadScale
	local char = c :: Model
	local hd = head :: BasePart
	local anchor = hd.CFrame * CFrame.new(0, -hd.Size.Y / 2, 0) -- grow up from the neck
	-- the head group: costume / accessory parts welded (directly or in a chain) to the Head; never the
	-- body parts themselves (direct children of the character)
	local group: { [BasePart]: boolean } = {}
	local function inGroup(bp: BasePart?): boolean
		return bp ~= nil and (bp == hd or group[bp] == true)
	end
	local function joinable(bp: BasePart?): boolean
		return bp ~= nil and bp ~= hd and bp.Parent ~= char and not group[bp]
	end
	local changed = true
	while changed do
		changed = false
		for _, d in char:GetDescendants() do
			if d:IsA("WeldConstraint") or d:IsA("Weld") then
				local p0, p1 = (d :: any).Part0 :: BasePart?, (d :: any).Part1 :: BasePart?
				if inGroup(p0) and joinable(p1) then
					group[p1 :: BasePart] = true
					changed = true
				elseif inGroup(p1) and joinable(p0) then
					group[p0 :: BasePart] = true
					changed = true
				end
			end
		end
	end
	local plain = next(group) == nil -- no costume: a plain avatar head just grows
	local headSize = hd.Size
	type SavedPart = { part: BasePart, size: Vector3, rel: CFrame }
	type SavedWeld = { weld: Weld, c0: CFrame, c1: CFrame, base: any }
	local parts: { SavedPart } = {}
	local wcs: { WeldConstraint } = {}
	local welds: { SavedWeld } = {}
	for _, d in char:GetDescendants() do
		if d:IsA("WeldConstraint") then
			if group[d.Part0 :: any] or group[d.Part1 :: any] then
				table.insert(wcs, d)
			end
		elseif d:IsA("Weld") then
			if group[d.Part0 :: any] or group[d.Part1 :: any] then
				table.insert(welds, { weld = d, c0 = d.C0, c1 = d.C1, base = d:GetAttribute("BaseC0") })
			end
		end
	end
	for bp in group do
		table.insert(parts, { part = bp, size = bp.Size, rel = anchor:ToObjectSpace(bp.CFrame) })
	end
	local function scaled(cf: CFrame, s: number): CFrame
		return CFrame.new(cf.Position * s) * cf.Rotation
	end
	local function joints(on: boolean)
		for _, w in wcs do
			if w.Parent then
				w.Enabled = on
			end
		end
		for _, w in welds do
			if w.weld.Parent then
				w.weld.Enabled = on
			end
		end
	end
	local function place(s: number, at: CFrame)
		joints(false)
		for _, sp in parts do
			if sp.part.Parent then
				sp.part.Size = sp.size * s
				sp.part.CFrame = at * scaled(sp.rel, s)
			end
		end
		for _, w in welds do
			local wd = w.weld
			local p0, p1 = wd.Part0, wd.Part1
			if not (wd.Parent and p0 and p1) then
				continue
			end
			if group[p0] and group[p1] then
				wd.C0 = scaled(w.c0, s)
				wd.C1 = scaled(w.c1, s)
			elseif group[p1] then
				wd.C1 = w.c1
				wd.C0 = p0.CFrame:ToObjectSpace(p1.CFrame * w.c1)
			else
				wd.C0 = w.c0
				wd.C1 = p1.CFrame:ToObjectSpace(p0.CFrame * w.c0)
			end
			if typeof(w.base) == "CFrame" then
				wd:SetAttribute("BaseC0", wd.C0 * w.c0:Inverse() * w.base)
			end
		end
		joints(true)
	end
	if plain then
		hd.Size = headSize * k
	else
		place(k, anchor)
	end
	track(p, "bighead", function()
		if not char.Parent then
			return
		end
		if plain then
			hd.Size = headSize
			return
		end
		place(1, hd.CFrame * CFrame.new(0, -hd.Size.Y / 2, 0))
		for _, w in welds do
			if w.weld.Parent then
				w.weld.C0 = w.c0
				w.weld.C1 = w.c1
				if typeof(w.base) == "CFrame" then
					w.weld:SetAttribute("BaseC0", w.base)
				end
			end
		end
	end, T.BigHeadSeconds)
	pop("shove", hd.Position + Vector3.new(0, 4, 0), "BIG HEAD!")
	return true, "big head"
end


K.ragdoll = function(p, _by)
	local c, _, root = charOf(p)
	if not c or not root then
		return false, "no character"
	end
	Ragdoll.enable(c, T.RagdollSeconds)
	pop("shove", root.Position + Vector3.new(0, 3, 0), "FLOP!")
	return true, "ragdolled"
end

local ARM_JOINTS = {
	RightShoulder = true, LeftShoulder = true, RightElbow = true, LeftElbow = true, RightWrist = true, LeftWrist = true,
	["Right Shoulder"] = true, ["Left Shoulder"] = true, -- R6
}

K.noodle = function(p, _by)
	local c, _, root = charOf(p)
	if not c or not root then
		return false, "no character"
	end
	revert(p, "noodle")
	local motors: { Motor6D } = {}
	local made: { Instance } = {}
	for _, d in c:GetDescendants() do
		if d:IsA("Motor6D") and ARM_JOINTS[d.Name] and d.Enabled and d.Part0 and d.Part1 then
			local a0 = Instance.new("Attachment")
			a0.Name = "NoodleA0"
			a0.CFrame = d.C0
			a0.Parent = d.Part0
			local a1 = Instance.new("Attachment")
			a1.Name = "NoodleA1"
			a1.CFrame = d.C1
			a1.Parent = d.Part1
			local s = Instance.new("BallSocketConstraint")
			s.Name = "NoodleSocket"
			s.Attachment0 = a0
			s.Attachment1 = a1
			s.LimitsEnabled = true
			s.UpperAngle = 120
			s.Restitution = 0.6
			s.Parent = d.Part1
			table.insert(made, a0)
			table.insert(made, a1)
			table.insert(made, s)
			table.insert(motors, d)
			d.Enabled = false
		end
	end
	if #motors == 0 then
		return false, "no arms to noodle"
	end
	track(p, "noodle", function()
		for _, i in made do
			i:Destroy()
		end
		for _, m in motors do
			if m.Parent then
				m.Enabled = true
			end
		end
	end, T.NoodleSeconds)
	pop("shove", root.Position + Vector3.new(0, 3, 0), "NOODLE ARMS!")
	return true, "noodle arms"
end

K.explode = function(p, by)
	local _, _, root = charOf(p)
	if not root then
		return false, "no character"
	end
	local pos = root.Position
	local f = trollFolder()
	local ball = part("TrollBoom", Vector3.one, CFrame.new(pos), Color3.fromHex("#FF8A1E"), f)
	ball.Shape = Enum.PartType.Ball
	ball.Material = Enum.Material.Neon
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	TweenService:Create(ball, TweenInfo.new(0.45, Enum.EasingStyle.Quad), { Size = Vector3.one * 14, Transparency = 1 }):Play()
	local puff = part("TrollSmoke", Vector3.one, CFrame.new(pos), Color3.new(), f)
	puff.Transparency = 1
	puff.CanCollide = false
	puff.CanQuery = false
	puff.CanTouch = false
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "Smoke"
	smoke.Enabled = false
	smoke.Color = ColorSequence.new(Color3.fromHex("#8C8A88"), Color3.fromHex("#E8E4DC"))
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2), NumberSequenceKeypoint.new(1, 6) })
	smoke.Transparency = NumberSequence.new(0.2, 1)
	smoke.Lifetime = NumberRange.new(1.2, 2)
	smoke.Speed = NumberRange.new(6, 14)
	smoke.SpreadAngle = Vector2.new(180, 180)
	smoke.Drag = 2
	smoke.Texture = "rbxasset://textures/particles/smoke_main.dds"
	smoke.Parent = puff
	smoke:Emit(26)
	local s = Instance.new("Sound")
	s.SoundId = "rbxasset://sounds/impact_explosion_03.mp3" -- built-in (HazardConfig.ExplosionSoundId)
	s.Volume = 0.8
	s.Parent = puff
	s:Play()
	Debris:AddItem(ball, 1)
	Debris:AddItem(puff, 3)
	impulse(p, randomFlat() * T.ExplodeSpeed * 0.6 + Vector3.new(0, T.ExplodeSpeed * 0.8, 0), by, 3)
	pop("boom", pos + Vector3.new(0, 4, 0), "KABOOM!")
	return true, "KABOOM"
end

K.slap = function(p, by)
	local c, _, root = charOf(p)
	if not c or not root then
		return false, "no character"
	end
	-- the hands slap at full swing (HandsMath / HandsConfig), from the caller's side when nearby
	local push, lift = HandsMath.slap(HandsConfig.SlapMaxReportedSpeed, HandsConfig)
	local byRoot = by.Character and by.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local dir = randomFlat()
	if byRoot and by ~= p then
		local away = root.Position - byRoot.Position
		away = Vector3.new(away.X, 0, away.Z)
		if away.Magnitude > 1e-3 and away.Magnitude < 60 then
			dir = away.Unit
		end
	end
	impulse(p, dir * push * 1.6 + Vector3.new(0, lift * 2, 0), by, HandsConfig.SlapRagdollSeconds + 0.8)
	local hit = root.Position + Vector3.new(0, 1.5, 0)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local fx = net and net:FindFirstChild("Hands") and (net :: any).Hands:FindFirstChild("Fx")
	if fx and fx:IsA("RemoteEvent") then
		fx:FireAllClients("slap", hit, p.UserId) -- the same SLAP! pop + sound as a hand slap
	else
		pop("shove", hit, "SLAP!")
	end
	Popup.show(p, `{by.DisplayName} slapped {p.DisplayName}`, "blame", by)
	return true, "SLAP"
end

local function placeInCage(p: Player, cage: Model)
	local c = p.Character
	local center = cage:GetAttribute("Center")
	if c and typeof(center) == "CFrame" then
		local hum = c:FindFirstChildOfClass("Humanoid")
		if hum and hum.SeatPart then
			hum.Sit = false
		end
		c:PivotTo(center)
	end
end

local function jailTag(p: Player, on: boolean)
	local c = p.Character
	local head = c and c:FindFirstChild("Head")
	if not head then
		return
	end
	local old = head:FindFirstChild("TrollJailTag")
	if old then
		old:Destroy()
	end
	if not on then
		return
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "TrollJailTag"
	bb.Size = UDim2.fromOffset(170, 44)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 120
	local l = Instance.new("TextLabel")
	l.Size = UDim2.fromScale(1, 1)
	l.BackgroundColor3 = Color3.fromHex("#2B2522")
	l.BackgroundTransparency = 0.15
	l.TextColor3 = Color3.fromHex("#FFC531")
	l.Font = Enum.Font.LuckiestGuy
	l.TextScaled = true
	l.Text = "IN JAIL!"
	l.Parent = bb
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = l
	bb.Parent = head
end

K.jail = function(p, _by)
	local c, _, root = charOf(p)
	if not c or not root then
		return false, "no character"
	end
	local g = groundBelow(root.Position + Vector3.new(0, 1, 0), { c, trollFolder() }) or (root.Position - Vector3.new(0, 3, 0))
	local base = CFrame.new(g) * CFrame.Angles(0, select(2, root.CFrame:ToOrientation()), 0)
	local cage = Instance.new("Model")
	cage.Name = `Jail_{p.UserId}`
	local W, H = 7, 8
	local steel = Color3.fromHex("#4A4650")
	part("Floor", Vector3.new(W + 1, 0.6, W + 1), base * CFrame.new(0, 0.3, 0), steel, cage).Material = Enum.Material.DiamondPlate
	local roof = part("Roof", Vector3.new(W + 1, 0.6, W + 1), base * CFrame.new(0, H + 0.6, 0), steel, cage)
	roof.Material = Enum.Material.DiamondPlate
	for side = 0, 3 do
		local rot = base * CFrame.Angles(0, side * math.pi / 2, 0)
		for i = -3, 3 do
			local bar = part("Bar", Vector3.new(0.35, H, 0.35), rot * CFrame.new(i * 1.1, H / 2 + 0.6, W / 2), Color3.fromHex("#2B2522"), cage)
			bar.Material = Enum.Material.Metal
		end
		local wall = part("Wall", Vector3.new(W + 1, H, 0.4), rot * CFrame.new(0, H / 2 + 0.6, W / 2), steel, cage)
		wall.Transparency = 1 -- invisible: the bars are too far apart for a tiny penguin otherwise
	end
	local sign = part("Sign", Vector3.new(5, 1.4, 0.3), base * CFrame.new(0, H + 1.6, W / 2), Color3.fromHex("#FFC531"), cage)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.Parent = sign
	local sl = Instance.new("TextLabel")
	sl.Size = UDim2.fromScale(1, 1)
	sl.BackgroundTransparency = 1
	sl.Font = Enum.Font.LuckiestGuy
	sl.TextScaled = true
	sl.TextColor3 = Color3.fromHex("#2B2522")
	sl.Text = "JAIL"
	sl.Parent = sg
	cage:SetAttribute("Center", base * CFrame.new(0, 3.6, 0))
	cage.Parent = trollFolder()
	p:SetAttribute(A.Jailed, true)
	placeInCage(p, cage)
	jailTag(p, true)
	track(p, "jail", function()
		cage:Destroy()
		if p.Parent then
			p:SetAttribute(A.Jailed, nil)
			jailTag(p, false)
		end
	end, T.JailSeconds, true)
	pop("shove", root.Position + Vector3.new(0, 4, 0), "BUSTED!")
	return true, "jailed"
end

local function stripClone(m: Model)
	for _, d in m:GetDescendants() do
		if d:IsA("LuaSourceContainer") or d:IsA("Tool") or d:IsA("ForceField") or d:IsA("Sound") then
			d:Destroy()
		end
	end
	for _, d in m:GetDescendants() do
		for _, tag in d:GetTags() do
			d:RemoveTag(tag)
		end
		for k in d:GetAttributes() do
			d:SetAttribute(k, nil)
		end
	end
	for _, tag in m:GetTags() do
		m:RemoveTag(tag)
	end
	for k in m:GetAttributes() do
		m:SetAttribute(k, nil)
	end
end

K.clone = function(p, _by)
	local c, _, root = charOf(p)
	if not c or not root then
		return false, "no character"
	end
	if clones >= T.MaxClones then
		return false, "too many clones already"
	end
	local was = c.Archivable
	c.Archivable = true
	local ok, copy = pcall(function()
		return c:Clone()
	end)
	c.Archivable = was
	if not ok or not copy then
		return false, "couldn't copy"
	end
	local m = copy :: Model
	stripClone(m)
	m.Name = `{p.Name}_clone`
	local hum = m:FindFirstChildOfClass("Humanoid")
	local croot = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not croot then
		m:Destroy()
		return false, "couldn't copy"
	end
	hum.DisplayName = `{p.DisplayName}?? (clone)`
	hum.MaxHealth = math.huge
	hum.Health = math.huge
	hum.WalkSpeed = 8
	hum.BreakJointsOnDeath = false
	m:PivotTo(root.CFrame * CFrame.new(3, 0, 0))
	m.Parent = trollFolder()
	pcall(function()
		croot:SetNetworkOwner(nil)
	end)
	clones += 1
	local walk: AnimationTrack? = nil
	local animator = hum:FindFirstChildOfClass("Animator") or Instance.new("Animator", hum)
	pcall(function()
		local anim = Instance.new("Animation")
		anim.AnimationId = T.WalkAnim
		walk = (animator :: Animator):LoadAnimation(anim)
		if walk then
			walk.Looped = true
			walk:Play(0.1, 1, 1.4)
		end
	end)
	local home = croot.Position
	task.spawn(function()
		local t0 = os.clock()
		while m.Parent and os.clock() - t0 < T.CloneSeconds do
			local to = home + randomFlat() * (4 + math.random() * 10)
			hum:MoveTo(to)
			if math.random() < 0.35 then
				hum.Jump = true
			end
			task.wait(1.2 + math.random())
		end
		if m.Parent then
			pop("shove", croot.Position + Vector3.new(0, 3, 0), "POOF!")
			m:Destroy()
		end
		clones = math.max(0, clones - 1)
	end)
	pop("shove", croot.Position + Vector3.new(0, 3, 0), "CLONED!")
	return true, "cloned"
end

local function buildPenguin(): Model
	local m = Instance.new("Model")
	m.Name = "PlushPenguin"
	local black, white, orange = Color3.fromHex("#2B2522"), Color3.fromHex("#F4F0E8"), Color3.fromHex("#FF8A1E")
	local body = part("Body", Vector3.new(1.6, 2, 1.5), CFrame.new(), black, m, false)
	body.Shape = Enum.PartType.Ball
	body.Size = Vector3.one * 1.8
	body.Material = Enum.Material.Fabric
	local function bit(name: string, size: Vector3, offset: CFrame, color: Color3, ball: boolean?)
		local b = part(name, size, offset, color, m, false)
		if ball then
			b.Shape = Enum.PartType.Ball
		end
		b.Material = Enum.Material.Fabric
		b.CanCollide = false
		b.Massless = true
		local w = Instance.new("WeldConstraint")
		w.Part0 = body
		w.Part1 = b
		w.Parent = b
	end
	bit("Belly", Vector3.one * 1.3, CFrame.new(0, -0.15, -0.35), white, true)
	bit("Beak", Vector3.new(0.35, 0.25, 0.5), CFrame.new(0, 0.35, -0.95), orange)
	bit("EyeL", Vector3.one * 0.32, CFrame.new(-0.3, 0.55, -0.72), white, true)
	bit("EyeR", Vector3.one * 0.32, CFrame.new(0.3, 0.55, -0.72), white, true)
	bit("FootL", Vector3.new(0.45, 0.15, 0.6), CFrame.new(-0.35, -0.9, -0.3), orange)
	bit("FootR", Vector3.new(0.45, 0.15, 0.6), CFrame.new(0.35, -0.9, -0.3), orange)
	body.CustomPhysicalProperties = PhysicalProperties.new(0.3, 0.6, 0.6)
	m.PrimaryPart = body
	return m
end

K.penguinrain = function(p, _by)
	local _, _, root = charOf(p)
	if not root then
		return false, "no character"
	end
	local room = T.MaxPenguins - penguins
	if room <= 0 then
		return false, "the sky is out of penguins (wait a moment)"
	end
	local tpl = penguinTemplate
	if not tpl then
		tpl = buildPenguin()
		penguinTemplate = tpl
	end
	local n = math.min(T.PenguinCount, room)
	penguins += n
	local f = trollFolder()
	task.spawn(function()
		for _ = 1, n do
			local pg = (tpl :: Model):Clone()
			local off = randomFlat() * (2 + math.random() * 12)
			local at = root.Position + off + Vector3.new(0, 30 + math.random() * 20, 0)
			pg:PivotTo(CFrame.new(at) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6))
			pg.Parent = f
			Debris:AddItem(pg, T.PenguinSeconds)
			task.wait(0.12)
		end
		task.wait(T.PenguinSeconds)
		penguins = math.max(0, penguins - n)
	end)
	pop("shove", root.Position + Vector3.new(0, 6, 0), "PENGUINS!")
	return true, `{n} penguins`
end

K.dance = function(p, _by)
	local _, hum, root = charOf(p)
	if not hum or not root then
		return false, "no character"
	end
	local animator = hum:FindFirstChildOfClass("Animator")
	if not animator then
		return false, "can't dance (no Animator)"
	end
	local anim = Instance.new("Animation")
	anim.AnimationId = T.DanceAnim
	local ok, track0 = pcall(function()
		return animator:LoadAnimation(anim)
	end)
	if not ok or not track0 then
		return false, "dance didn't load"
	end
	local tr = track0 :: AnimationTrack
	tr.Looped = true
	tr.Priority = Enum.AnimationPriority.Action
	tr:Play(0.2)
	local notes = attach(root, "TrollNotes", Vector3.new(0, 2.5, 0))
	local e = Instance.new("ParticleEmitter")
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Color = ColorSequence.new(Color3.fromHex("#B07CFF"), Color3.fromHex("#4FB3D9"))
	e.Rate = 6
	e.Lifetime = NumberRange.new(1, 1.6)
	e.Speed = NumberRange.new(3, 5)
	e.Size = NumberSequence.new(0.6)
	e.Parent = notes
	track(p, "dance", function()
		tr:Stop(0.2)
		notes:Destroy()
	end, T.DanceSeconds)
	pop("shove", root.Position + Vector3.new(0, 3, 0), "DANCE!")
	return true, "dancing"
end

K.confetti = function(p, _by)
	local _, _, root = charOf(p)
	if not root then
		return false, "no character"
	end
	local at = attach(root, "TrollConfetti", Vector3.new(0, 2, 0))
	burst(at, 90, 22)
	Debris:AddItem(at, T.ConfettiSeconds)
	pop("shove", root.Position + Vector3.new(0, 4, 0), "PARTY!")
	return true, "confetti"
end

K.sparkles = function(p, _by)
	local _, _, root = charOf(p)
	if not root then
		return false, "no character"
	end
	local s = Instance.new("Sparkles")
	s.Name = "TrollSparkles"
	s.SparkleColor = Color3.fromHex("#FFC531")
	s.Parent = root
	track(p, "sparkles", function()
		s:Destroy()
	end, T.SparkleSeconds)
	return true, "sparkly"
end

K.fakeban = function(p, by)
	local r = fxRemote
	if not r then
		return false, "not ready"
	end
	r:FireClient(p, "fakeban", T.FakeBanSeconds, by.DisplayName)
	return true, "fake-banned (jk)"
end

K.invert = function(p, _by)
	p:SetAttribute(A.Inverted, true)
	track(p, "invert", function()
		if p.Parent then
			p:SetAttribute(A.Inverted, nil)
		end
	end, T.InvertSeconds)
	return true, "controls flipped"
end

--------------------------------------------------------------------------------------------- api

function TrollService:Run(kind: string, target: Player, by: Player): (boolean, string)
	local fn = K[kind]
	if not fn then
		return false, `unknown troll {tostring(kind)}`
	end
	if not target.Parent then
		return false, "left the game"
	end
	local ok, a, b = pcall(fn, target, by)
	if not ok then
		warn(`[TrollService] {kind} on {target.Name}: {a}`)
		return false, "something went wrong"
	end
	if a then
		Telemetry.count("trolls_run")
	end
	return a == true, tostring(b)
end

function TrollService:Revert(target: Player, kind: string?): number
	local k = kind
	if k == "tiny" or k == "giant" then
		k = "scale"
	end
	return revert(target, k)
end

function TrollService:Active(target: Player): { string }
	local out: { string } = {}
	for k in active[target] or {} do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

function TrollService:Init(all: { [string]: any })
	services = all
end

function TrollService:Start()
	fxRemote = Net.event("Troll", "Fx")
	local function hook(p: Player)
		p.CharacterRemoving:Connect(function()
			revert(p, nil, true)
		end)
		p.CharacterAdded:Connect(function()
			local t = active[p]
			if t and t.jail then
				task.wait(0.3)
				local cage = trollFolder():FindFirstChild(`Jail_{p.UserId}`) :: Model?
				if cage then
					placeInCage(p, cage)
					jailTag(p, true)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(hook)
	for _, p in Players:GetPlayers() do
		hook(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		revert(p)
		active[p] = nil
	end)
end

------------------------------------------------------------------------------------------ hooks

function TrollService:_active(player: Player): string
	return table.concat(self:Active(player), ",")
end

function TrollService:_selftest(): (boolean, string)
	local missing = {}
	for _, k in TrollService.Kinds do
		if not K[k] then
			table.insert(missing, k)
		end
	end
	return #missing == 0, `kinds={#TrollService.Kinds} missing={table.concat(missing, ",")} clones={clones} penguins={penguins}`
end

return TrollService
