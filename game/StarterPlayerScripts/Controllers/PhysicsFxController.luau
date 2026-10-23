--!strict
-- PhysicsFxController [owner: Physics]. Client side of the goofy physics (docs/game/08 "Goofy physics").
--   * Ragdoll.listen(): Shared/Ragdoll knockbacks and ragdolls land on this client's character (the
--     client owns its character physics). Idempotent; ToolController calls it too.
--   * Hard landings: tracks the fastest downward speed while airborne; touching down at
--     PhysicsConfig.HardLandingSpeed or more fires Physics/Land(speed) and the server ragdolls us
--     (longer for bigger drops) with an "OOF!" pop. Camera shake on impact.
--   * Banana-peel slips: running across a WetFloor puddle faster than SlipSpeed rolls a slip chance;
--     on a slip our feet fly up (spin + hop, FallingDown) right away and Physics/Slip asks the server
--     for the proper ragdoll + "WHOOPS!" pop.
--   * Wobbly carry: while Player attr Carrying is set and we walk, a side-to-side stumble sway.
--   * Pops: renders Physics/Pop (word, position, kind) as small world text above whoever it hit
--     (ClientLib/WorldPopup).
-- Remotes: Physics/Land, Physics/Slip (C->S), Physics/Pop (S->C) - declared by PhysicsFxService.
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PhysicsConfig") :: ModuleScript) :: any
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)

local LocalPlayer = Players.LocalPlayer

local PhysicsFxController = {}
PhysicsFxController.Priority = 100

local controllers: { [string]: any } = {}
local LandRemote: RemoteEvent? = nil
local SlipRemote: RemoteEvent? = nil
local peakFall = 0
local wasAirborne = false
local lastSlip = 0
local wobbleT = 0

local POP_COLORS = {
	Color3.fromRGB(255, 214, 64),
	Color3.fromRGB(255, 120, 60),
	Color3.fromRGB(255, 255, 255),
	Color3.fromRGB(120, 220, 255),
}

local function shake(magnitude: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, magnitude, seconds)
	end
end

local function onWetFloor(root: BasePart): boolean
	for _, inst in CollectionService:GetTagged(Names.Tag.WetFloor) do
		if inst:IsA("BasePart") then
			local p = inst.CFrame:PointToObjectSpace(root.Position)
			if inst.Shape == Enum.PartType.Cylinder then
				-- puddles are cylinders lying with X up (ToolService)
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

-- pops ------------------------------------------------------------------------------------------------
local function pop(word: string, position: Vector3, _kind: string?)
	-- subtle world text over whoever it happened to (ClientLib/WorldPopup: caps, dedupe, setting)
	local subject = WorldPopup.subjectAt(position, 5)
	if not WorldPopup.show(subject, word, { color = POP_COLORS[math.random(1, #POP_COLORS)] }) then
		return
	end
	if Cfg.PopSoundId ~= "" then
		local att = Instance.new("Attachment")
		att.Name = "PhysicsPop"
		att.WorldPosition = position
		att.Parent = workspace.Terrain
		local s = Instance.new("Sound")
		s.SoundId = Cfg.PopSoundId
		s.Volume = 0.6
		s.PlaybackSpeed = 0.9 + math.random() * 0.3
		s.RollOffMaxDistance = 120
		s.Parent = att
		s:Play()
		Debris:AddItem(att, 2)
	end
end

-- per-frame: landings, slips, wobbly carry --------------------------------------------------------------
local function slip(hum: Humanoid, root: BasePart, flat: Vector3)
	lastSlip = os.clock()
	local fwd = if flat.Magnitude > 1e-3 then flat.Unit else root.CFrame.LookVector
	local right = fwd:Cross(Vector3.yAxis)
	-- banana peel: feet shoot forward, body rotates backwards over the right axis, a little hop
	pcall(function()
		hum:ChangeState(Enum.HumanoidStateType.FallingDown)
	end)
	root.AssemblyLinearVelocity = flat * 1.2 + Vector3.new(0, Cfg.SlipHop, 0)
	root.AssemblyAngularVelocity = right * Cfg.SlipSpin + Vector3.new(0, (math.random() * 2 - 1) * 4, 0)
	shake(0.35, 0.4)
	if SlipRemote then
		SlipRemote:FireServer()
	end
end

local function step(dt: number)
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not (char and hum and root) or hum.Health <= 0 then
		peakFall, wasAirborne = 0, false
		return
	end
	local ragdolled = Ragdoll.isRagdolled(char)
	local seated = hum.SeatPart ~= nil
	local v = root.AssemblyLinearVelocity
	local airborne = hum.FloorMaterial == Enum.Material.Air

	-- hard landings
	if airborne and not seated then
		wasAirborne = true
		if -v.Y > peakFall then
			peakFall = -v.Y
		end
	elseif wasAirborne then
		local speed = peakFall
		wasAirborne, peakFall = false, 0
		if not ragdolled and not seated and speed >= Cfg.HardLandingSpeed and LandRemote then
			LandRemote:FireServer(speed)
			shake(math.clamp(speed / Cfg.SplatLandingSpeed, 0.3, 1), 0.5)
		end
	end
	if ragdolled or seated or airborne then
		return
	end

	-- banana-peel slips
	local flat = Vector3.new(v.X, 0, v.Z)
	if os.clock() - lastSlip >= Cfg.SlipCooldown and flat.Magnitude >= Cfg.SlipSpeed then
		local p = 1 - (1 - math.clamp(Cfg.SlipChancePerSecond, 0, 1)) ^ dt
		if math.random() < p and onWetFloor(root) then
			slip(hum, root, flat)
			return
		end
	end

	-- wobbly carry
	local carrying = LocalPlayer:GetAttribute(Names.Attr.Carrying)
	if type(carrying) == "string" and carrying ~= "" and hum.MoveDirection.Magnitude > 0.1 then
		wobbleT += dt
		local right = root.CFrame.RightVector
		local sway = math.cos(wobbleT * Cfg.CarryWobbleHz * 2 * math.pi) * Cfg.CarryWobble
		-- the walking humanoid re-steers every frame, so this reads as a stumble, not a drift
		root.AssemblyLinearVelocity += right * sway * 0.35
	else
		wobbleT = 0
	end
end

function PhysicsFxController:Init(all: { [string]: any })
	controllers = all
end

function PhysicsFxController:Start()
	Ragdoll.listen()
	RunService.Heartbeat:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok then
			warn(`[PhysicsFx] {err}`)
		end
	end)
	-- remotes (wait for the server to declare them; never block the per-frame step on them)
	local ok, err = pcall(function()
		LandRemote = Net.event("Physics", "Land")
		SlipRemote = Net.event("Physics", "Slip")
		local Pop = Net.event("Physics", "Pop")
		Pop.OnClientEvent:Connect(function(word: any, position: any, kind: any)
			if type(word) == "string" and typeof(position) == "Vector3" then
				pop(word, position, if type(kind) == "string" then kind else nil)
			end
		end)
	end)
	if not ok then
		warn(`[PhysicsFx] remotes: {err}`)
	end
end

return PhysicsFxController
