--!strict
-- AxeArm [owner: Hands agent / axe]. The ONE axe, seen the same in first and third person:
--   * The axe is the real Tool (Lib/Tools/AxeBuilder): Handle welded to the R15 RightHand, metal Head
--     on a ball socket, simulated by the holder (network owner) and replicated to everyone.
--   * The holder's right arm is posed by two-bone IK (RightShoulder / RightElbow / RightWrist
--     Motor6D.Transform, after the Animator) toward a sprung GRIP pose in aim space (AxeMath). Hold the
--     Tool button to wind up (arm back over the shoulder), release to chop (~0.3 s forward-down).
--     Walking/running bounces the grip, so the head flops.
--   * The sprung pose + camera pitch go to HandsService (Hands/AxeArm, ~20/s) and come back to every
--     client (Hands/AxeArms); each client runs the same IK on that player's arm, so 3P shows the same
--     arm as the holder's 1P, and the head is the holder's own physics.
--   * Door damage: the holder sweeps the head between physics frames; touching a Door sends
--     Hands/AxeHit(door, head speed) (HandsService validates). During a chop the head also bonks
--     players/NPCs (Hands/Slap "axe") and bats loose props (Hands/Push).
--   AxeArm.start(opts)            -- once per client (FirstPersonController:Start)
--     opts.shake: (magnitude, seconds) -> ()   camera shake for whoosh / hits
--   AxeArm.getLocal(): (Tool?, string)       -- the held axe and phase "ready"|"windup"|"strike"|"recover"

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript) :: any
local AxeMath = require(ReplicatedStorage:WaitForChild("AxeMath") :: ModuleScript)
local HandsMath = require(ReplicatedStorage:WaitForChild("HandsMath") :: ModuleScript)
local HandsConfig =
	require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HandsConfig") :: ModuleScript) :: any

local LocalPlayer = Players.LocalPlayer

local AxeArm = {}

type Pose = AxeMath.Pose
type Opts = { shake: ((number, number) -> ())? }

type Remote = { target: Pose, pitch: number, cur: Pose, curPitch: number, at: number, weight: number }

local started = false
local opts: Opts = {}

-- local holder state
local swing = AxeMath.newSwing()
local held: Tool? = nil
local toolConns: { RBXScriptConnection } = {}
local phase = "ready"
local sp: Pose = { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0 }
local sv: Pose = { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0 }
local weight = 0
local bobPhase = 0
local sendAt = 0
local lastHead: Vector3? = nil
local peakSpeed = 0
local peakAt = 0
local hitCooldown = 0
local bonkCooldown: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local pitchNow = 0

local remotes: { [number]: Remote } = {}

local function now(): number
	return os.clock()
end

local function net(name: string): any
	local n = ReplicatedStorage:FindFirstChild("Net")
	local ns = n and n:FindFirstChild("Hands")
	return ns and ns:FindFirstChild(name)
end

local function swingCfg(): AxeMath.SwingCfg
	return {
		WindupSeconds = tonumber(HandsConfig.AxeWindupSeconds) or 0.5,
		StrikeSeconds = tonumber(HandsConfig.AxeStrikeSeconds) or 0.3,
		RecoverSeconds = tonumber(HandsConfig.AxeRecoverSeconds) or 0.35,
		MinCharge = tonumber(HandsConfig.AxeMinCharge) or 0.35,
	}
end

local function axeOf(char: Model?): Tool?
	local t = char and char:FindFirstChild("Axe")
	if t and t:IsA("Tool") and t:FindFirstChild("Handle") and t:FindFirstChild("Head") then
		return t
	end
	return nil
end

-- IK -----------------------------------------------------------------------------------------------
local function v(t: AxeMath.Vec): Vector3
	return Vector3.new(t.x, t.y, t.z)
end
local function tv(p: Vector3): AxeMath.Vec
	return { x = p.X, y = p.Y, z = p.Z }
end

-- Rotation whose Y axis is `primary` and whose -Z leans toward `hint`.
local function basis(primary: Vector3, hint: Vector3): CFrame
	local y = primary.Unit
	local s = hint - y * hint:Dot(y)
	if s.Magnitude < 1e-4 then
		local alt = if math.abs(y.Z) < 0.9 then Vector3.zAxis else Vector3.xAxis
		s = alt - y * alt:Dot(y)
	end
	local z = -s.Unit
	local x = y:Cross(z)
	return CFrame.fromMatrix(Vector3.zero, x, y, z)
end

type Rig = {
	root: BasePart,
	head: BasePart,
	ut: BasePart,
	ua: BasePart,
	la: BasePart,
	hand: BasePart,
	sh: Motor6D,
	el: Motor6D,
	wr: Motor6D,
	grip: Attachment,
}

local function rigOf(char: Model): Rig?
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local head = char:FindFirstChild("Head") :: BasePart?
	local ut = char:FindFirstChild("UpperTorso") :: BasePart?
	local ua = char:FindFirstChild("RightUpperArm") :: BasePart?
	local la = char:FindFirstChild("RightLowerArm") :: BasePart?
	local hand = char:FindFirstChild("RightHand") :: BasePart?
	if not (root and head and ut and ua and la and hand) then
		return nil
	end
	local sh = ua:FindFirstChild("RightShoulder")
	local el = la:FindFirstChild("RightElbow")
	local wr = hand:FindFirstChild("RightWrist")
	local grip = hand:FindFirstChild("RightGripAttachment")
	if not (sh and sh:IsA("Motor6D") and el and el:IsA("Motor6D") and wr and wr:IsA("Motor6D") and grip and grip:IsA("Attachment")) then
		return nil
	end
	return {
		root = root,
		head = head,
		ut = ut,
		ua = ua,
		la = la,
		hand = hand,
		sh = sh,
		el = el,
		wr = wr,
		grip = grip,
	}
end

local function poseCF(p: Pose): CFrame
	return CFrame.new(p.x, p.y, p.z) * CFrame.Angles(math.rad(p.rx), math.rad(p.ry), math.rad(p.rz))
end

-- Grip frame in HumanoidRootPart space for a pose + pitch (degrees).
local function gripInRoot(r: Rig, p: Pose, pitch: number): CFrame
	local rootCF = r.root.CFrame
	local eye = rootCF:PointToObjectSpace(r.head.Position)
	return CFrame.new(eye) * CFrame.Angles(math.rad(pitch), 0, 0) * poseCF(p)
end

-- Pose the right arm so RightGripAttachment lands on `gripR` (root space). `w` blends with the
-- Animator's pose (0 = untouched).
local function applyArm(r: Rig, gripR: CFrame, w: number)
	if w <= 0.001 or not (r.sh.Enabled and r.el.Enabled and r.wr.Enabled) then
		return
	end
	local sh, el, wr = r.sh, r.el, r.wr
	local utR = r.root.CFrame:ToObjectSpace(r.ut.CFrame)
	local S = utR * sh.C0.Position
	local handR = gripR * r.grip.CFrame:Inverse()
	local Wd = handR * wr.C1.Position
	local upLocal = el.C0.Position - sh.C1.Position
	local loLocal = wr.C0.Position - el.C1.Position
	local a, b = upLocal.Magnitude, loLocal.Magnitude
	if a < 1e-3 or b < 1e-3 then
		return
	end
	local pole = HandsConfig.AxeElbowPole
	local poleV = if typeof(pole) == "Vector3" then pole else Vector3.new(0.8, -1, 0.6)
	local e, w2 = AxeMath.solveElbow(tv(S), tv(Wd), a, b, tv(poleV))
	local E, W = v(e), v(w2)
	local front = -poleV
	local Rua = basis(E - S, front) * basis(upLocal, Vector3.new(0, 0, -1)):Inverse()
	local uaCF = CFrame.new(S - Rua * sh.C1.Position) * Rua
	local Rla = basis(W - E, front) * basis(loLocal, Vector3.new(0, 0, -1)):Inverse()
	local laCF = CFrame.new(E - Rla * el.C1.Position) * Rla
	local Rh = handR.Rotation
	local handCF = CFrame.new(W - Rh * wr.C1.Position) * Rh
	local tSh = sh.C0:Inverse() * utR:Inverse() * uaCF * sh.C1
	local tEl = el.C0:Inverse() * uaCF:Inverse() * laCF * el.C1
	local tWr = wr.C0:Inverse() * laCF:Inverse() * handCF * wr.C1
	if w >= 0.999 then
		sh.Transform, el.Transform, wr.Transform = tSh, tEl, tWr
	else
		sh.Transform = sh.Transform:Lerp(tSh, w)
		el.Transform = el.Transform:Lerp(tEl, w)
		wr.Transform = wr.Transform:Lerp(tWr, w)
	end
end

-- local holder ------------------------------------------------------------------------------------
local function resetHead(tool: Tool)
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local head = tool:FindFirstChild("Head") :: BasePart?
	local rest = tool:GetAttribute("AxeHeadRest")
	if handle and head and typeof(rest) == "CFrame" then
		head.CFrame = handle.CFrame * rest
		head.AssemblyLinearVelocity = handle.AssemblyLinearVelocity
		head.AssemblyAngularVelocity = Vector3.zero
	end
	lastHead = nil
end

local function unbind()
	for _, c in toolConns do
		c:Disconnect()
	end
	table.clear(toolConns)
	held = nil
	swing = AxeMath.newSwing()
	phase = "ready"
	lastHead = nil
end

local function blockedLocal(): boolean
	local carrying = LocalPlayer:GetAttribute(Names.Attr.Carrying)
	if type(carrying) == "string" and carrying ~= "" then
		return true
	end
	local char = LocalPlayer.Character
	return LocalPlayer:GetAttribute(Names.Attr.Downed) == true
		or (char ~= nil and char:GetAttribute(Names.Attr.Ragdolled) == true)
end

local function bind(tool: Tool)
	unbind()
	held = tool
	local readyPose = (HandsConfig.AxePoses or {}).Ready
	if readyPose and weight <= 0.01 then
		sp = table.clone(readyPose)
		sv = { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0 }
	end
	table.insert(
		toolConns,
		tool.Activated:Connect(function()
			if not blockedLocal() then
				AxeMath.press(swing, now(), swingCfg())
			end
		end)
	)
	table.insert(
		toolConns,
		tool.Deactivated:Connect(function()
			-- the whoosh shake + sound are ToolController's (Tool.Deactivated)
			AxeMath.release(swing, now(), swingCfg())
		end)
	)
	resetHead(tool)
end

local function springPose(target: Pose, dt: number, striking: boolean)
	local hz = if striking then HandsConfig.AxeArmStrikeHz else HandsConfig.AxeArmHz
	local zeta = if striking then HandsConfig.AxeArmStrikeDamping else HandsConfig.AxeArmDamping
	local k, c = HandsMath.springCoeffs(tonumber(hz) or 7, tonumber(zeta) or 0.55)
	for _, key in { "x", "y", "z", "rx", "ry", "rz" } do
		local x, vel = HandsMath.springStep((sp :: any)[key], (sv :: any)[key], (target :: any)[key], k, c, dt)
		;(sp :: any)[key] = x
		;(sv :: any)[key] = vel
	end
end

local function updateLocal(dt: number)
	local char = LocalPlayer.Character
	local tool = axeOf(char)
	if tool ~= held then
		if tool then
			bind(tool)
		else
			unbind()
		end
	end
	local blendRate = dt / math.max(tonumber(HandsConfig.AxeArmBlendSeconds) or 0.15, 0.01)
	local r = char and rigOf(char)
	local active = tool ~= nil and r ~= nil and not blockedLocal()
	weight = math.clamp(weight + (if active then blendRate else -blendRate), 0, 1)
	if not (tool and r) then
		return
	end
	local cfg = swingCfg()
	phase = AxeMath.step(swing, dt, cfg)
	local poses = HandsConfig.AxePoses
	local target = AxeMath.pose(swing, now(), poses, cfg)
	-- running bounce
	local vel = r.root.AssemblyLinearVelocity
	local speed01 = Vector3.new(vel.X, 0, vel.Z).Magnitude / 16
	bobPhase += dt * math.pi * 2 * 1.9 * math.min(speed01, 1.3)
	local bx, by = AxeMath.runBob(bobPhase, speed01, tonumber(HandsConfig.AxeRunBob) or 0.12)
	target = { x = target.x + bx, y = target.y + by, z = target.z, rx = target.rx + by * 40, ry = target.ry, rz = target.rz + bx * 30 }
	springPose(target, dt, phase == "strike")
	local cam = workspace.CurrentCamera
	if cam then
		local look = r.root.CFrame:VectorToObjectSpace(cam.CFrame.LookVector)
		local pitch = math.deg(math.asin(math.clamp(look.Y, -1, 1)))
		pitchNow = math.clamp(pitch * (tonumber(HandsConfig.AxePitchScale) or 0.85), -70, 70)
	end
	applyArm(r, gripInRoot(r, sp, pitchNow), weight)

	local t = now()
	if t >= sendAt then
		sendAt = t + 1 / math.max(1, tonumber(HandsConfig.AxeArmSendHz) or 20)
		local remote = net("AxeArm")
		if remote then
			local flags = (if phase == "windup" then AxeMath.Flag.Windup else 0)
				+ (if phase == "strike" then AxeMath.Flag.Strike else 0)
			remote:FireServer(AxeMath.encode(sp, pitchNow, flags))
		end
	end
end

-- Head contact checks after physics (holder only).
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude

local function humanoidModel(part: BasePart): Model?
	local m = part:FindFirstAncestorWhichIsA("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then
			return m
		end
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

local function checkHead()
	local tool = held
	local char = LocalPlayer.Character
	if not (tool and char and tool.Parent == char) then
		return
	end
	local head = tool:FindFirstChild("Head") :: BasePart?
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (head and handle and root) then
		return
	end
	-- a head that ever separated from its socket snaps back
	local a0 = handle:FindFirstChild("AxeSocket") :: Attachment?
	local a1 = head:FindFirstChild("AxeSocket") :: Attachment?
	if a0 and a1 and (a0.WorldPosition - a1.WorldPosition).Magnitude > 1.5 then
		resetHead(tool)
		return
	end
	local t = now()
	local pos = head.Position
	local rel = head.AssemblyLinearVelocity - root.AssemblyLinearVelocity
	local speed = rel.Magnitude
	if speed > peakSpeed or t - peakAt > 0.12 then
		peakSpeed, peakAt = speed, t
	end
	local last = lastHead
	lastHead = pos
	if not last then
		return
	end
	rayParams.FilterDescendantsInstances = { char }
	overlap.FilterDescendantsInstances = { char }
	local delta = pos - last
	local swingSpeed = math.max(speed, peakSpeed)
	if t >= hitCooldown and swingSpeed >= (tonumber(HandsConfig.AxeMinSpeed) or 22) * 0.5 then
		local dir = if delta.Magnitude > 1e-3 then delta + delta.Unit * 0.35 else rel.Unit * 0.35
		local hit = workspace:Spherecast(last, 0.42, dir, rayParams)
		local part = hit and hit.Instance
		if part and CollectionService:HasTag(part, Names.Tag.Door) and part:GetAttribute(Names.Attr.Broken) ~= true then
			hitCooldown = t + (tonumber(HandsConfig.AxeHitCooldown) or 0.35)
			local r = net("AxeHit")
			if r then
				r:FireServer(part, swingSpeed)
			end
			if opts.shake then
				opts.shake(math.clamp(swingSpeed / (tonumber(HandsConfig.AxeCritSpeed) or 55), 0.15, 0.6), 0.2)
			end
		end
	end
	-- bonks and bats while chopping
	if phase == "strike" and speed >= (tonumber(HandsConfig.AxeMinSpeed) or 22) * 0.6 then
		for _, p in workspace:GetPartBoundsInRadius(pos, 1.2, overlap) do
			local m = humanoidModel(p)
			local key: Instance = m or p
			if (bonkCooldown[key] or 0) > t then
				continue
			end
			if m and m ~= char then
				bonkCooldown[key] = t + (tonumber(HandsConfig.SlapCooldown) or 0.5)
				local r = net("Slap")
				if r then
					r:FireServer(m, rel, "axe")
				end
				break
			elseif not m and not p.Anchored and not CollectionService:HasTag(p, Names.Tag.Door) then
				bonkCooldown[key] = t + (tonumber(HandsConfig.PushCooldown) or 0.25)
				local r = net("Push")
				if r then
					r:FireServer(p, rel)
				end
				break
			end
		end
	end
end

-- other players ------------------------------------------------------------------------------------
local function onArms(flat: any)
	if type(flat) ~= "table" then
		return
	end
	local stride = 1 + AxeMath.PacketSize
	local t = now()
	for i = 1, #flat - stride + 1, stride do
		local userId = flat[i]
		if type(userId) ~= "number" or userId == LocalPlayer.UserId then
			continue
		end
		local pose, pitch = AxeMath.decode(table.move(flat, i + 1, i + AxeMath.PacketSize, 1, {}))
		if pose then
			local e = remotes[userId]
			if not e then
				remotes[userId] = { target = pose, pitch = pitch, cur = table.clone(pose), curPitch = pitch, at = t, weight = 0 }
			else
				e.target, e.pitch, e.at = pose, pitch, t
			end
		end
	end
end

local function updateRemotes(dt: number)
	local t = now()
	local k = 1 - math.exp(-dt * 22) -- smooth the 20 Hz packets
	for userId, e in remotes do
		local player = Players:GetPlayerByUserId(userId)
		local char = player and player.Character
		local fresh = t - e.at < 0.6
		local tool = axeOf(char)
		local r = char and rigOf(char)
		local on = fresh and tool ~= nil and r ~= nil and char:GetAttribute(Names.Attr.Ragdolled) ~= true
		e.weight = math.clamp(e.weight + (if on then dt * 8 else -dt * 8), 0, 1)
		if not player or (e.weight <= 0 and not fresh) then
			remotes[userId] = nil
			continue
		end
		if not r then
			continue
		end
		for _, key in { "x", "y", "z" } do
			(e.cur :: any)[key] += ((e.target :: any)[key] - (e.cur :: any)[key]) * k
		end
		for _, key in { "rx", "ry", "rz" } do
			(e.cur :: any)[key] += AxeMath.angleDelta((e.cur :: any)[key], (e.target :: any)[key]) * k
		end
		e.curPitch += (e.pitch - e.curPitch) * k
		applyArm(r, gripInRoot(r, e.cur, e.curPitch), e.weight)
	end
end

-- True when this player's right arm is driven by an axe packet (PhysicsHands leaves it alone).
function AxeArm.drivesArm(char: Model?): boolean
	if not char then
		return false
	end
	if char == LocalPlayer.Character then
		return held ~= nil
	end
	local player = Players:GetPlayerFromCharacter(char)
	local e = player and remotes[player.UserId]
	return e ~= nil and axeOf(char) ~= nil
end

function AxeArm.getLocal(): (Tool?, string)
	return held, phase
end

function AxeArm.start(o: Opts?)
	if started then
		return
	end
	started = true
	opts = o or {}
	task.spawn(function()
		local n = ReplicatedStorage:WaitForChild("Net")
		local ns = n:WaitForChild("Hands", 30)
		local arms = ns and ns:WaitForChild("AxeArms", 30)
		if arms then
			(arms :: any).OnClientEvent:Connect(onArms)
		end
	end)
	-- after the Animator, before physics: the IK arm replaces the animation's right arm
	RunService.PreSimulation:Connect(function(dt: number)
		local ok, err = pcall(updateLocal, dt)
		if not ok then
			warn(`[AxeArm] {err}`)
		end
		updateRemotes(dt)
	end)
	RunService.PostSimulation:Connect(function()
		local ok, err = pcall(checkHead)
		if not ok then
			warn(`[AxeArm] head: {err}`)
		end
	end)
end

return AxeArm
