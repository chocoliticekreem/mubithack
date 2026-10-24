--!strict
-- Ragdoll [contract K0 v1.5; body owned by G1]. "Funky physics" for characters, shared by every
-- system that shoves people around: hose friendly fire and hose recoil (ToolService.HoseHit /
-- .HoseRecoil), explosions, electrocution, fire tornado and tidal wave (HazardService), slaps, axe hits.
--
--   Ragdoll.enable(character: Model, seconds: number): boolean      -- limp for N s, then stand up
--   Ragdoll.knockback(character: Model, impulse: Vector3): boolean  -- velocity change in studs/s
--   Ragdoll.isRagdolled(character: Model): boolean
--   Ragdoll.listen()   -- client: idempotent; applies Shared/Ragdoll to the local character
--
-- How it works for a player's character (client-owned physics):
--   server enable: swaps every Motor6D (except the root joint) for a BallSocketConstraint ON THE
--     SERVER, so every client sees the limbs flop; sets character attr Ragdolled = true; fires
--     Shared/Ragdoll(seconds, nil) to the owner, whose client puts its Humanoid into the Physics
--     state (SetStateEnabled doesn't replicate, so that part must run on the owner).
--     After `seconds` the server restores the Motor6Ds and clears Ragdolled; the owner sees the attr
--     drop, zeroes its velocity, stands upright and goes GettingUp.
--   server knockback: fires Shared/Ragdoll(0, impulse) to the owner, who adds it to the root's
--     AssemblyLinearVelocity (a server-side velocity change on a client-owned part does nothing).
--   NPCs (no player) are simulated by the server, so both are applied directly there.
--   client calls (local character only) apply directly; the joint swap is then local-only.
-- Impulses are clamped to PhysicsConfig.MaxImpulse, seconds to PhysicsConfig.RagdollMaxSeconds.
-- Returns false when nothing was applied (no Humanoid, dead, not our character on the client, or
-- already ragdolled for longer). Shared/Ragdoll is declared by Main.server.luau.
-- Clients: something must call Ragdoll.listen() once (ToolController does; PhysicsFxController may
-- too; it is idempotent, so the handler is connected exactly once per client).

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(script.Parent:WaitForChild("Names") :: ModuleScript)

local IS_SERVER = RunService:IsServer()
local SOCKET = "RagdollSocket"
local GRACE = 2 -- client safety: force a recovery this long after the longest possible ragdoll

type Saved = {
	motors: { Motor6D },
	made: { Instance },
	collide: { [BasePart]: boolean },
	requiresNeck: boolean,
	token: number,
	untilT: number,
}

local Ragdoll = {}

local saved: { [Model]: Saved } = setmetatable({}, { __mode = "k" }) :: any
local listening = false
local localToken = 0

local function physicsConfig(): any
	local cfg = ReplicatedStorage:FindFirstChild("Config")
	local mod = cfg and cfg:FindFirstChild("PhysicsConfig")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok then
			return res
		end
	end
	return { MaxImpulse = 120, RagdollMaxSeconds = 4 }
end

local function humanoidOf(character: Model): Humanoid?
	return character:FindFirstChildOfClass("Humanoid")
end

local function rootOf(character: Model): BasePart?
	local r = character:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function clampImpulse(v: Vector3): Vector3
	local max = tonumber(physicsConfig().MaxImpulse) or 120
	if v.Magnitude > max then
		return v.Unit * max
	end
	return v
end

local function clampSeconds(s: number): number
	local max = tonumber(physicsConfig().RagdollMaxSeconds) or 4
	if s ~= s then
		return 0
	end
	return math.clamp(s, 0, max)
end

-- joints ----------------------------------------------------------------------------------------
local function isRootJoint(m: Motor6D, root: BasePart?): boolean
	return root ~= nil and (m.Part0 == root or m.Part1 == root)
end

local function swapJoints(character: Model): Saved?
	local hum = humanoidOf(character)
	if not hum then
		return nil
	end
	local root = rootOf(character)
	local s: Saved = { motors = {}, made = {}, collide = {}, requiresNeck = hum.RequiresNeck, token = 0, untilT = 0 }
	hum.RequiresNeck = false
	for _, d in character:GetDescendants() do
		if d:IsA("Motor6D") and d.Enabled and d.Part0 and d.Part1 and not isRootJoint(d, root) then
			local p0 = d.Part0 :: BasePart
			local p1 = d.Part1 :: BasePart
			local a0 = Instance.new("Attachment")
			a0.Name = "RagdollA0"
			a0.CFrame = d.C0
			a0.Parent = p0
			local a1 = Instance.new("Attachment")
			a1.Name = "RagdollA1"
			a1.CFrame = d.C1
			a1.Parent = p1
			local socket = Instance.new("BallSocketConstraint")
			socket.Name = SOCKET
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.UpperAngle = 50
			socket.TwistLimitsEnabled = true
			socket.TwistLowerAngle = -50
			socket.TwistUpperAngle = 50
			socket.Restitution = 0.15
			socket.Parent = p1
			local nc = Instance.new("NoCollisionConstraint")
			nc.Name = "RagdollNoCollide"
			nc.Part0 = p0
			nc.Part1 = p1
			nc.Parent = p1
			table.insert(s.made, a0)
			table.insert(s.made, a1)
			table.insert(s.made, socket)
			table.insert(s.made, nc)
			table.insert(s.motors, d)
			d.Enabled = false
		end
	end
	for _, p in character:GetDescendants() do
		if p:IsA("BasePart") and p.Parent == character then
			s.collide[p] = p.CanCollide
			p.CanCollide = p ~= root -- limbs collide so they don't sink; the root box doesn't
		end
	end
	return s
end

local function restoreJoints(character: Model, s: Saved)
	for _, inst in s.made do
		inst:Destroy()
	end
	for _, m in s.motors do
		if m.Parent then
			m.Enabled = true
		end
	end
	for p, was in s.collide do
		if p.Parent then
			p.CanCollide = was
		end
	end
	local hum = humanoidOf(character)
	if hum then
		hum.RequiresNeck = s.requiresNeck
	end
end

-- humanoid state (owner side: the client for players, the server for NPCs) -----------------------
local function goLimp(hum: Humanoid)
	pcall(function()
		hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, false)
		hum:ChangeState(Enum.HumanoidStateType.Physics)
	end)
end

local function standUp(character: Model)
	local hum = humanoidOf(character)
	local root = rootOf(character)
	if root then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		local look = root.CFrame.LookVector
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude < 1e-3 then
			flat = Vector3.new(0, 0, -1)
		end
		local pos = root.Position + Vector3.new(0, 1.5, 0)
		root.CFrame = CFrame.lookAt(pos, pos + flat.Unit)
	end
	if hum and hum.Health > 0 then
		pcall(function()
			hum:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true)
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end)
	end
end

local function addVelocity(character: Model, impulse: Vector3)
	local root = rootOf(character)
	local hum = humanoidOf(character)
	if not root or (hum and hum.SeatPart) then
		return -- seated: the root's assembly is the vehicle, a shove would launch / flip it
	end
	local v = clampImpulse(impulse)
	-- A grounded humanoid eats horizontal velocity within a few frames; a little hop keeps the shove.
	if Vector3.new(v.X, 0, v.Z).Magnitude > 12 and v.Y < 8 then
		v = Vector3.new(v.X, 8, v.Z)
	end
	root.AssemblyLinearVelocity += v
end

-- enable / recover (server for everyone, client for its own character) ---------------------------
local function recover(character: Model, token: number)
	local s = saved[character]
	if not s or s.token ~= token then
		return
	end
	saved[character] = nil
	restoreJoints(character, s)
	character:SetAttribute(Names.Attr.Ragdolled, false)
	local owner = Players:GetPlayerFromCharacter(character)
	if not IS_SERVER or owner == nil then
		standUp(character) -- NPCs on the server, or our own character on the client
		local hum = humanoidOf(character)
		if hum and not owner then
			hum.PlatformStand = false
		end
	end
end

local nextToken = 0

local function enableHere(character: Model, seconds: number): boolean
	local hum = humanoidOf(character)
	if not hum or hum.Health <= 0 or hum.SeatPart then
		return false -- never go limp in a seat (standing back up re-poses the root = the whole vehicle)
	end
	local now = os.clock()
	local untilT = now + seconds
	local s = saved[character]
	if s and s.untilT >= untilT then
		return false -- already limp for longer
	end
	if not s then
		s = swapJoints(character)
		if not s then
			return false
		end
		saved[character] = s
	end
	nextToken += 1
	local token = nextToken
	local cur = s :: Saved
	cur.token = token
	cur.untilT = untilT
	character:SetAttribute(Names.Attr.Ragdolled, true)
	local owner = Players:GetPlayerFromCharacter(character)
	if not IS_SERVER or owner == nil then
		goLimp(hum)
		if owner == nil then
			hum.PlatformStand = true
		end
	end
	task.delay(seconds, recover, character, token)
	return true
end

local function remote(): RemoteEvent?
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Shared")
	local r = ns and ns:FindFirstChild("Ragdoll")
	return if r and r:IsA("RemoteEvent") then r else nil
end

local function isLocalCharacter(character: Model): boolean
	local lp = Players.LocalPlayer
	return lp ~= nil and lp.Character == character
end

-- public ------------------------------------------------------------------------------------------
function Ragdoll.enable(character: Model, seconds: number): boolean
	if typeof(character) ~= "Instance" or not character:IsA("Model") then
		return false
	end
	local secs = clampSeconds(seconds)
	if secs <= 0 then
		return false
	end
	if IS_SERVER then
		if not enableHere(character, secs) then
			return false
		end
		local owner = Players:GetPlayerFromCharacter(character)
		local r = remote()
		if owner and r then
			r:FireClient(owner, secs, nil)
		end
		return true
	end
	if not isLocalCharacter(character) then
		return false
	end
	return enableHere(character, secs)
end

function Ragdoll.knockback(character: Model, impulse: Vector3): boolean
	if typeof(character) ~= "Instance" or not character:IsA("Model") or typeof(impulse) ~= "Vector3" then
		return false
	end
	if impulse.Magnitude ~= impulse.Magnitude or impulse.Magnitude < 1e-3 then
		return false
	end
	local hum = humanoidOf(character)
	if not hum or hum.Health <= 0 then
		return false
	end
	if IS_SERVER then
		local owner = Players:GetPlayerFromCharacter(character)
		if owner then
			local r = remote()
			if not r then
				return false
			end
			r:FireClient(owner, 0, clampImpulse(impulse))
			return true
		end
		addVelocity(character, impulse)
		return true
	end
	if not isLocalCharacter(character) then
		return false
	end
	addVelocity(character, impulse)
	return true
end

function Ragdoll.isRagdolled(character: Model): boolean
	return character:GetAttribute(Names.Attr.Ragdolled) == true
end

-- Client: owner side of a server ragdoll. Watches the local character's Ragdolled attribute (the
-- server sets and clears it) and Shared/Ragdoll (seconds, impulse?).
function Ragdoll.listen()
	if IS_SERVER or listening then
		return
	end
	listening = true
	local lp = Players.LocalPlayer
	local function onAttr(character: Model)
		local on = character:GetAttribute(Names.Attr.Ragdolled) == true
		local hum = humanoidOf(character)
		if not hum or saved[character] then
			return -- a local-only ragdoll handles itself
		end
		localToken += 1
		local token = localToken
		if on then
			goLimp(hum)
			local max = (tonumber(physicsConfig().RagdollMaxSeconds) or 4) + GRACE
			task.delay(max, function()
				if localToken == token and character.Parent and Ragdoll.isRagdolled(character) then
					standUp(character) -- server never cleared it (lost event); don't stay stuck
				end
			end)
		else
			standUp(character)
		end
	end
	local function hook(character: Model)
		character:GetAttributeChangedSignal(Names.Attr.Ragdolled):Connect(function()
			onAttr(character)
		end)
	end
	lp.CharacterAdded:Connect(hook)
	if lp.Character then
		hook(lp.Character)
	end
	task.spawn(function()
		local net = ReplicatedStorage:WaitForChild("Net", 15)
		local ns = net and net:WaitForChild("Shared", 15)
		local r = ns and ns:WaitForChild("Ragdoll", 15)
		if not (r and r:IsA("RemoteEvent")) then
			warn("[Ragdoll] Shared/Ragdoll remote missing")
			return
		end
		r.OnClientEvent:Connect(function(seconds: any, impulse: any)
			local character = lp.Character
			if not character then
				return
			end
			if typeof(impulse) == "Vector3" then
				addVelocity(character, impulse)
			end
			local hum = humanoidOf(character)
			if typeof(seconds) == "number" and seconds > 0 and hum then
				goLimp(hum) -- the attr change usually arrives first; this covers the race
			end
		end)
	end)
end

-- Builds a throwaway R15-ish rig (not parented to workspace), ragdolls it and restores it.
function Ragdoll._selftest(): (boolean, string)
	local m = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Parent = m
	local torso = Instance.new("Part")
	torso.Name = "UpperTorso"
	torso.Parent = m
	local arm = Instance.new("Part")
	arm.Name = "RightUpperArm"
	arm.Parent = m
	local rj = Instance.new("Motor6D")
	rj.Name = "Root"
	rj.Part0 = root
	rj.Part1 = torso
	rj.Parent = torso
	local sh = Instance.new("Motor6D")
	sh.Name = "RightShoulder"
	sh.Part0 = torso
	sh.Part1 = arm
	sh.Parent = arm
	Instance.new("Humanoid").Parent = m
	local s = swapJoints(m)
	local ok = s ~= nil and not sh.Enabled and rj.Enabled and arm:FindFirstChild(SOCKET) ~= nil
	if s then
		restoreJoints(m, s)
	end
	ok = ok and sh.Enabled and arm:FindFirstChild(SOCKET) == nil
	m:Destroy()
	return ok, if ok then "ok" else "joint swap/restore failed"
end

return Ragdoll
