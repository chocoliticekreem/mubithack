--!strict
-- PhysicsFxService [owner: Physics]. Goofy physics (docs/game/08 "Goofy physics").
--
-- Knockable props: light city props (trash cans, cones, mailboxes, benches, chairs, boxes, crates,
--   ducks, barrels, buckets, hydrant caps ...) under Workspace.Map are registered at MapReady and
--   whenever builders add more: anything tagged "Knockable", any Model/Folder whose name matches
--   PhysicsConfig.KnockableNames (Lib/Physics/PropPhysics.isKnockableName), and every hydrant's "Cap".
--   Attr Knockable = false opts out. Registered props are welded into one assembly and stay ANCHORED
--   (asleep) until a player comes within WakeRadius (plus a velocity lookahead, so fast trucks wake
--   ahead); then they are unanchored, light and bouncy. They fall asleep again (re-anchored where they
--   lie, or back home if they fell out of the world) when nobody is near. The nearest player within
--   OwnerRadius owns an awake prop's physics so pushing it feels instant.
-- Budgets: at most MaxAwakePerArea awake props per PropAreaStuds square and MaxAwakeServer in total;
--   a forced wake (truck, blast, Impulse) evicts the least recently touched awake prop.
-- Trucks: any Truck-tagged Model moving faster than TruckFlingSpeed sends props in front of it flying
--   (BOING / YEET pops). VehicleService.RanOver gets a BOING pop over the victim.
-- Tools: hose spray (Tool/Spray, read alongside ToolService) shoves the prop it hits; axe swings
--   (the Axe Tool's Activated) BONK props in front; engine Explosions (HazardService) fling props.
-- Players: hard landings (client reports, server ragdolls) and banana-peel slips on WetFloor puddles.
--
-- Public API (others call it nil-guarded through `services.PhysicsFxService`):
--   PhysicsFxService:Impulse(target: Instance, vector: Vector3, sourcePlayer: Player?): boolean
--     target = Player, character Model, prop Model/Folder or any part of one (or a loose unanchored
--     part). Players/NPCs get Ragdoll.knockback (and a short ragdoll when |vector| >= ImpulseRagdollAt);
--     props wake (forced) and are flung by the server.
--   PhysicsFxService:Blast(center: Vector3, radius: number, power: number?, sourcePlayer: Player?): number
--     props only (HazardService already shoves people); returns props flung
--   PhysicsFxService:Pop(kind: string, position: Vector3, word: string?)   -- comedic world text
--   PhysicsFxService:Register(inst: Instance): boolean                    -- make something knockable
--   PhysicsFxService:GetStats(): { registered, awake, pending }
-- Remotes: Physics/Pop (S->C all: word: string, position: Vector3, kind: string)
--          Physics/Land (C->S: fallSpeed: number)   Physics/Slip (C->S: no args)
-- Reads: tags Knockable, Truck, Rescuable, WetFloor; Player attr Water; Shared/Ragdoll
-- Consumes (nil-guarded): VehicleService.RanOver
-- Counters: props_registered, props_woken, props_slept, props_evicted, props_flung, props_ploughed,
--   props_hosed, props_bonked, props_blasted, physics_impulses, hard_landings, slips, physics_pops
-- Test hooks (DevHook only): _selftest(), _stats()

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PhysicsConfig") :: ModuleScript) :: any
local PropPhysics =
	require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Physics"):WaitForChild("PropPhysics") :: ModuleScript)

local PhysicsFxService = {}
PhysicsFxService.Priority = 80

local TAG = "Knockable"
local WELD = "PropWeld"
-- parts tagged with these are gameplay objects, never physics props
local KEEP_TAGS = {
	Names.Tag.Hydrant,
	Names.Tag.TruckRefill,
	Names.Tag.Door,
	Names.Tag.RescueDropoff,
	Names.Tag.StationSpawn,
	Names.Tag.TruckSpot,
	Names.Tag.AlarmLamp,
	Names.Tag.MissionBoard,
	Names.Tag.SquadPad,
	Names.Tag.Hazard,
	Names.Tag.FuseBox,
	Names.Tag.Window,
	Names.Tag.WetFloor,
	Names.Tag.RescueSpawn,
}

type Prop = {
	inst: Instance,
	root: BasePart,
	parts: { BasePart },
	home: CFrame,
	area: number,
	awake: boolean,
	idle: number,
	holdUntil: number,
	lastHit: number,
	owner: Player?,
	tuned: boolean,
}

local services: { [string]: any } = {}
local props: { [Instance]: Prop } = {} -- by prop root instance (Model/Folder/part)
local byPart: { [BasePart]: Prop } = {}
local grid: PropPhysics.Grid = PropPhysics.Grid.new(32)
local budget: PropPhysics.Budget = PropPhysics.Budget.new(60, 300)
local pending: { Instance } = {}
local registered = 0
local popRemote: RemoteEvent? = nil
local popTokens = 8
local popStamp = os.clock()
local normNames: { string } = {}
local normExclude: { string } = {}
local lastAxe: { [Player]: number } = {}
local lastHose: { [Player]: number } = {}
local lastSlip: { [Player]: number } = {}
local started = false

local function count(name: string, n: number?)
	Telemetry.count(name, n)
end

local function areaOf(pos: Vector3): number
	return PropPhysics.cellKey(pos.X, pos.Z, Cfg.PropAreaStuds)
end

local function rootOfChar(char: Model?): BasePart?
	local r = char and char:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

type Body = { player: Player, pos: Vector3, vel: Vector3 }

local function bodies(): { Body }
	local out: { Body } = {}
	for _, p in Players:GetPlayers() do
		local r = rootOfChar(p.Character)
		if r then
			table.insert(out, { player = p, pos = r.Position, vel = r.AssemblyLinearVelocity })
		end
	end
	return out
end

local function nearest(list: { Body }, pos: Vector3): (Player?, number)
	local best, bestD = nil :: Player?, math.huge
	for _, b in list do
		local d = (b.pos - pos).Magnitude
		if d < bestD then
			best, bestD = b.player, d
		end
	end
	return best, bestD
end

-- pops ----------------------------------------------------------------------------------------------
function PhysicsFxService:Pop(kind: string, position: Vector3, word: string?)
	if typeof(position) ~= "Vector3" or not popRemote then
		return
	end
	local now = os.clock()
	local rate = tonumber(Cfg.PopsPerSecond) or 8
	popTokens = math.min(rate, popTokens + (now - popStamp) * rate)
	popStamp = now
	if popTokens < 1 then
		return
	end
	popTokens -= 1
	local text = word or PropPhysics.popWord(kind, math.random())
	popRemote:FireAllClients(text, position, kind)
	count("physics_pops")
end

-- registration ----------------------------------------------------------------------------------------
local function hasKeepTag(inst: Instance): boolean
	for _, t in KEEP_TAGS do
		if inst:HasTag(t) then
			return true
		end
	end
	return false
end

-- An ancestor that makes this off-limits: a truck, an NPC, a character, or an already-registered prop.
local function blockedByAncestor(inst: Instance): boolean
	local a = inst.Parent
	while a and a ~= workspace do
		if props[a] or a:HasTag(Names.Tag.Truck) or a:HasTag(Names.Tag.Rescuable) then
			return true
		end
		if a:IsA("Model") and a:FindFirstChildOfClass("Humanoid") then
			return true
		end
		a = a.Parent
	end
	return false
end

local function isHydrantCap(inst: Instance): boolean
	local parent = inst.Parent
	return inst:IsA("BasePart") and inst.Name == "Cap" and parent ~= nil and parent.Name == "Hydrant"
end

local function isCandidate(inst: Instance): boolean
	if props[inst] or inst:GetAttribute(TAG) == false then
		return false
	end
	if inst:HasTag(TAG) then
		return true
	end
	if isHydrantCap(inst) then
		return true
	end
	if not (inst:IsA("Model") or inst:IsA("Folder")) then
		return false -- single parts only by tag (or hydrant caps): part names are too generic
	end
	return PropPhysics.isKnockableName(inst.Name, normNames, normExclude)
end

-- Collect the parts of a candidate; nil when it isn't a sane light prop.
local function collect(inst: Instance): ({ BasePart }?, BasePart?)
	if hasKeepTag(inst) then
		return nil, nil
	end
	local parts: { BasePart } = {}
	if inst:IsA("BasePart") then
		parts = { inst }
	else
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				table.insert(parts, d)
			elseif
				d:IsA("Humanoid")
				or d:IsA("ProximityPrompt")
				or d:IsA("Seat")
				or d:IsA("VehicleSeat")
				or d:IsA("HingeConstraint")
				or d:IsA("Motor6D")
			then
				return nil, nil
			end
		end
	end
	if #parts == 0 or #parts > Cfg.PropMaxParts then
		return nil, nil
	end
	local minV, maxV = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
	local root: BasePart? = if inst:IsA("Model") then inst.PrimaryPart else nil
	local biggest = 0
	for _, p in parts do
		if not p.Anchored or hasKeepTag(p) then
			return nil, nil -- someone else simulates it, or it's a gameplay object
		end
		local half = p.Size / 2
		minV = minV:Min(p.Position - Vector3.one * half.Magnitude)
		maxV = maxV:Max(p.Position + Vector3.one * half.Magnitude)
		local vol = p.Size.X * p.Size.Y * p.Size.Z
		if not root and vol > biggest then
			biggest = vol
		end
	end
	if not root then
		for _, p in parts do
			if p.Size.X * p.Size.Y * p.Size.Z == biggest then
				root = p
				break
			end
		end
	end
	local ext = maxV - minV
	if math.max(ext.X, ext.Y, ext.Z) > Cfg.PropMaxExtent * 1.6 then
		return nil, nil -- the bounding-sphere estimate overshoots a little; this is generous on purpose
	end
	return parts, root
end

local function unregister(prop: Prop)
	if props[prop.inst] ~= prop then
		return
	end
	props[prop.inst] = nil
	for _, p in prop.parts do
		if byPart[p] == prop then
			byPart[p] = nil
		end
	end
	budget:sleep(prop)
	grid:remove(prop)
	registered -= 1
end

function PhysicsFxService:Register(inst: Instance): boolean
	if typeof(inst) ~= "Instance" or props[inst] or not inst:IsDescendantOf(workspace) then
		return false
	end
	if blockedByAncestor(inst) then
		return false
	end
	local parts, root = collect(inst)
	if not parts or not root then
		return false
	end
	for _, p in parts do
		if byPart[p] then
			return false -- overlaps an existing prop
		end
	end
	local r = root :: BasePart
	for _, p in parts do
		if p ~= r and not p:FindFirstChild(WELD) then
			local w = Instance.new("WeldConstraint")
			w.Name = WELD
			w.Part0 = r
			w.Part1 = p
			w.Parent = p
		end
	end
	local prop: Prop = {
		inst = inst,
		root = r,
		parts = parts,
		home = r.CFrame,
		area = areaOf(r.Position),
		awake = false,
		idle = 0,
		holdUntil = 0,
		lastHit = 0,
		owner = nil,
		tuned = false,
	}
	props[inst] = prop
	for _, p in parts do
		byPart[p] = prop
	end
	grid:insert(prop, r.Position.X, r.Position.Z)
	registered += 1
	count("props_registered")
	r.AncestryChanged:Connect(function()
		if not r:IsDescendantOf(workspace) then
			unregister(prop)
		end
	end)
	return true
end

local function scan(root: Instance)
	for _, d in root:GetDescendants() do
		if isCandidate(d) then
			PhysicsFxService:Register(d)
		end
	end
end

-- wake / sleep ------------------------------------------------------------------------------------------
local sleepProp: (prop: Prop) -> ()

local function tune(prop: Prop)
	if prop.tuned then
		return
	end
	prop.tuned = true
	local phys = PhysicalProperties.new(Cfg.PropDensity, Cfg.PropFriction, Cfg.PropElasticity, 1, 1)
	local anyCollide = false
	for _, p in prop.parts do
		p.CustomPhysicalProperties = phys
		anyCollide = anyCollide or p.CanCollide
	end
	if not anyCollide then
		prop.root.CanCollide = true -- decorative no-collide props (farm ducks) would fall through the world
	end
end

local function wake(prop: Prop, force: boolean): boolean
	local now = os.clock()
	if prop.awake then
		budget:touch(prop, now)
		return true
	end
	if not budget:wake(prop, prop.area, now) then
		if not force then
			return false
		end
		local areaFull = budget:count(prop.area) >= budget.perArea
		local victim = budget:evict(if areaFull then prop.area else nil, function(id: any): boolean
			return (id :: Prop).holdUntil > now -- mid-fling props stay up
		end)
		if victim then
			sleepProp(victim :: Prop)
			count("props_evicted")
		end
		if not budget:wake(prop, prop.area, now) then
			return false
		end
	end
	tune(prop)
	grid:remove(prop)
	prop.awake = true
	prop.idle = 0
	for _, p in prop.parts do
		if p.Parent then
			p.Anchored = false
		end
	end
	count("props_woken")
	return true
end

sleepProp = function(prop: Prop)
	budget:sleep(prop)
	prop.awake = false
	prop.idle = 0
	prop.owner = nil
	local r = prop.root
	if not r.Parent then
		return
	end
	if r.Position.Y < prop.home.Position.Y - Cfg.FallResetDepth then
		r.CFrame = prop.home -- fell out of the world: back where it started (moves the welded assembly)
	end
	r.AssemblyLinearVelocity = Vector3.zero
	r.AssemblyAngularVelocity = Vector3.zero
	for _, p in prop.parts do
		if p.Parent then
			p.Anchored = true
		end
	end
	grid:insert(prop, r.Position.X, r.Position.Z)
	count("props_slept")
end

local function setOwner(prop: Prop, player: Player?)
	if prop.owner == player or not prop.awake or prop.root.Anchored then
		return
	end
	local ok = pcall(function()
		prop.root:SetNetworkOwner(player)
	end)
	if ok then
		prop.owner = player
	end
end

-- Server-driven fling: wake (forced), take ownership briefly, set the velocity.
local function fling(prop: Prop, v: Vector3, spin: number?): boolean
	if not prop.root.Parent or not wake(prop, true) then
		return false
	end
	local now = os.clock()
	setOwner(prop, nil)
	prop.holdUntil = now + Cfg.ServerHoldSeconds
	prop.lastHit = now
	local x, y, z = PropPhysics.clamp3(v.X, v.Y, v.Z, Cfg.MaxPropSpeed)
	prop.root.AssemblyLinearVelocity = Vector3.new(x, y, z)
	local s = spin or 6
	prop.root.AssemblyAngularVelocity = Vector3.new(
		(math.random() * 2 - 1) * s,
		(math.random() * 2 - 1) * s,
		(math.random() * 2 - 1) * s
	)
	count("props_flung")
	return true
end

local function propFrom(inst: Instance?): Prop?
	local a = inst
	while a and a ~= workspace do
		local p = props[a]
		if p then
			return p
		end
		if a:IsA("BasePart") and byPart[a] then
			return byPart[a]
		end
		a = a.Parent
	end
	return nil
end

-- Props whose root is within `r` of `pos` (sleeping via the grid, awake by direct scan).
local function propsNear(pos: Vector3, r: number): { Prop }
	local out: { Prop } = {}
	for _, id in grid:query(pos.X, pos.Z, r) do
		local p = id :: Prop
		if (p.root.Position - pos).Magnitude <= r then
			table.insert(out, p)
		end
	end
	for id in budget.awake do
		local p = id :: Prop
		if (p.root.Position - pos).Magnitude <= r then
			table.insert(out, p)
		end
	end
	return out
end

-- periodic: wake near players, sleep far ones, hand ownership to the nearest player ----------------
local function tick(dt: number)
	local list = bodies()
	local now = os.clock()
	for _, b in list do
		local r = Cfg.WakeRadius + b.vel.Magnitude * Cfg.WakeLookahead
		for _, id in grid:query(b.pos.X, b.pos.Z, r) do
			local p = id :: Prop
			if not p.awake and (p.root.Position - b.pos).Magnitude <= r then
				wake(p, false)
			end
		end
	end
	local toSleep: { Prop } = {}
	for id in budget.awake do
		local p = id :: Prop
		if not p.root.Parent then
			table.insert(toSleep, p)
			continue
		end
		if p.root:GetAttribute("HeldBy") ~= nil then
			budget:touch(p, now) -- in someone's physics hands: HandsService owns it, don't sleep or re-own
			continue
		end
		local who, d = nearest(list, p.root.Position)
		local sleepNow, idle = PropPhysics.shouldSleep(d, p.root.AssemblyLinearVelocity.Magnitude, p.idle, dt, Cfg)
		p.idle = idle
		if sleepNow and p.holdUntil <= now then
			table.insert(toSleep, p)
		elseif p.holdUntil <= now then
			setOwner(p, if who and d <= Cfg.OwnerRadius then who else nil)
		end
		if d <= Cfg.WakeRadius then
			budget:touch(p, now)
		end
	end
	for _, p in toSleep do
		sleepProp(p)
	end
end

-- trucks plough through props -------------------------------------------------------------------------
local function truckTick()
	local now = os.clock()
	for _, m in CollectionService:GetTagged(Names.Tag.Truck) do
		if not m:IsA("Model") or not m:IsDescendantOf(workspace) then
			continue
		end
		local chassis = m.PrimaryPart
		if not chassis or chassis.Anchored then
			continue
		end
		local v = chassis.AssemblyLinearVelocity
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude < Cfg.TruckFlingSpeed then
			continue
		end
		local dir = flat.Unit
		local origin = chassis.Position
		for _, p in propsNear(origin + dir * (Cfg.TruckFrontReach * 0.5), Cfg.TruckFrontReach) do
			if now - p.lastHit < Cfg.PropHitCooldown then
				continue
			end
			local d = p.root.Position - origin
			local along = d:Dot(dir)
			local side = (Vector3.new(d.X, 0, d.Z) - dir * along).Magnitude
			if along >= 0 and along <= Cfg.TruckFrontReach and side <= Cfg.TruckHalfWidth and math.abs(d.Y) < 9 then
				local x, y, z = PropPhysics.truckFling(v.X, v.Y, v.Z, Cfg, math.random() * 2 - 1)
				if fling(p, Vector3.new(x, y, z), 12) then
					count("props_ploughed")
					PhysicsFxService:Pop("truck", p.root.Position + Vector3.new(0, 3, 0))
				end
			end
		end
	end
end

-- tools ---------------------------------------------------------------------------------------------
local function onSpray(player: Player, rawAim: any)
	local aim = Net.unit(rawAim)
	local char = player.Character
	if not aim or not char or not char:FindFirstChild("Hose") then
		return
	end
	local water = player:GetAttribute(Names.Attr.Water)
	if type(water) == "number" and water <= 0 then
		return
	end
	local now = os.clock()
	if now - (lastHose[player] or 0) < 0.12 then
		return
	end
	lastHose[player] = now
	local head = char:FindFirstChild("Head")
	local from: BasePart? = if head and head:IsA("BasePart") then head else rootOfChar(char)
	if not from then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local hit = workspace:Raycast(from.Position, aim * Cfg.HosePropReach, params)
	local prop = hit and propFrom(hit.Instance)
	if prop then
		local v = prop.root.AssemblyLinearVelocity + aim * Cfg.HosePropImpulse + Vector3.new(0, 6, 0)
		if fling(prop, v, 3) then
			count("props_hosed")
		end
	end
end

local function onAxe(player: Player)
	local now = os.clock()
	if now - (lastAxe[player] or 0) < Cfg.AxePropCooldown then
		return
	end
	lastAxe[player] = now
	local root = rootOfChar(player.Character)
	if not root then
		return
	end
	local look = root.CFrame.LookVector
	for _, p in propsNear(root.Position, Cfg.AxePropReach) do
		local d = p.root.Position - root.Position
		if d.Magnitude < 1e-3 or look:Dot(d.Unit) > 0.25 then
			local v = (Vector3.new(look.X, 0, look.Z).Unit + Vector3.new(0, 0.7, 0)).Unit * Cfg.AxePropImpulse
			if fling(p, v, 14) then
				count("props_bonked")
				PhysicsFxService:Pop("axe", p.root.Position + Vector3.new(0, 2, 0))
			end
		end
	end
end

local function hookCharacter(player: Player, char: Model)
	local function onTool(child: Instance)
		if child:IsA("Tool") and child.Name == "Axe" and not child:GetAttribute("PhysicsFxHooked") then
			child:SetAttribute("PhysicsFxHooked", true)
			child.Activated:Connect(function()
				if child.Parent == player.Character then
					onAxe(player)
				end
			end)
		end
	end
	char.ChildAdded:Connect(onTool)
	for _, c in char:GetChildren() do
		onTool(c)
	end
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(c)
		hookCharacter(player, c)
	end)
	if player.Character then
		hookCharacter(player, player.Character)
	end
end

-- player events ---------------------------------------------------------------------------------------
local function onLand(player: Player, rawSpeed: any)
	local speed = tonumber(rawSpeed)
	local char = player.Character
	local root = rootOfChar(char)
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not speed or speed ~= speed or not char or not root or not hum or hum.SeatPart or hum.Health <= 0 then
		return
	end
	if Ragdoll.isRagdolled(char) then
		return
	end
	local secs = PropPhysics.landingSeconds(math.min(speed, 400), Cfg)
	if secs <= 0 then
		return
	end
	if Ragdoll.enable(char, secs) then
		count("hard_landings")
		PhysicsFxService:Pop("land", root.Position + Vector3.new(0, 2, 0))
	end
end

local function nearWetFloor(pos: Vector3): boolean
	for _, inst in CollectionService:GetTagged(Names.Tag.WetFloor) do
		if inst:IsA("BasePart") then
			local d = inst.Position - pos
			local reach = math.max(inst.Size.X, inst.Size.Y, inst.Size.Z) / 2 + 4
			if Vector3.new(d.X, 0, d.Z).Magnitude <= reach and math.abs(d.Y) < 8 then
				return true
			end
		end
	end
	return false
end

local function onSlip(player: Player)
	local now = os.clock()
	if now - (lastSlip[player] or 0) < Cfg.SlipCooldown then
		return
	end
	local char = player.Character
	local root = rootOfChar(char)
	if not char or not root or Ragdoll.isRagdolled(char) or not nearWetFloor(root.Position) then
		return
	end
	lastSlip[player] = now
	if Ragdoll.enable(char, Cfg.SlipSeconds) then
		count("slips")
		PhysicsFxService:Pop("slip", root.Position + Vector3.new(0, 3, 0))
	end
end

-- public ----------------------------------------------------------------------------------------------
function PhysicsFxService:Impulse(target: Instance, vector: Vector3, sourcePlayer: Player?): boolean
	if typeof(target) ~= "Instance" or typeof(vector) ~= "Vector3" then
		return false
	end
	local mag = vector.Magnitude
	if mag ~= mag or mag < 1e-3 then
		return false
	end
	count("physics_impulses")
	local char: Model? = nil
	if target:IsA("Player") then
		char = target.Character
	elseif target:IsA("Model") and target:FindFirstChildOfClass("Humanoid") then
		char = target
	elseif target.Parent and target.Parent:IsA("Model") and target.Parent:FindFirstChildOfClass("Humanoid") then
		char = target.Parent :: Model
	end
	if char then
		local ok = Ragdoll.knockback(char, vector) == true
		local secs = PropPhysics.impulseRagdollSeconds(mag, Cfg)
		if secs > 0 then
			ok = (Ragdoll.enable(char, secs) == true) or ok
			local r = rootOfChar(char)
			if r then
				self:Pop("shove", r.Position + Vector3.new(0, 3, 0))
			end
		end
		return ok
	end
	local prop = propFrom(target)
	if not prop and target:IsA("Model") then
		if self:Register(target) then
			prop = props[target]
		end
	end
	if prop then
		return fling(prop, prop.root.AssemblyLinearVelocity + vector, 8)
	end
	if target:IsA("BasePart") and not target.Anchored then
		local ok = pcall(function()
			if target:GetNetworkOwner() == nil then
				target:ApplyImpulse(vector * target.AssemblyMass)
			end
		end)
		return ok
	end
	return false
end

function PhysicsFxService:Blast(center: Vector3, radius: number, power: number?, _sourcePlayer: Player?): number
	if typeof(center) ~= "Vector3" or type(radius) ~= "number" or radius <= 0 then
		return 0
	end
	local pw = power or Cfg.BlastPropPower
	local n = 0
	for _, p in propsNear(center, radius) do
		local d = p.root.Position - center
		local x, y, z = PropPhysics.blast(d.X, d.Y, d.Z, radius, pw)
		if (x * x + y * y + z * z) > 1 and fling(p, Vector3.new(x, y, z), 16) then
			n += 1
		end
	end
	if n > 0 then
		count("props_blasted", n)
	end
	return n
end

function PhysicsFxService:GetStats(): { [string]: number }
	return { registered = registered, awake = budget:count(nil), pending = #pending }
end

-- lifecycle ---------------------------------------------------------------------------------------------
function PhysicsFxService:Init(all: { [string]: any })
	services = all
	grid = PropPhysics.Grid.new(Cfg.GridCellStuds)
	budget = PropPhysics.Budget.new(Cfg.MaxAwakePerArea, Cfg.MaxAwakeServer)
	normNames = {}
	for _, n in Cfg.KnockableNames do
		table.insert(normNames, PropPhysics.normalize(n))
	end
	normExclude = {}
	for _, n in Cfg.KnockableExclude do
		table.insert(normExclude, PropPhysics.normalize(n))
	end
end

function PhysicsFxService:Start()
	if started then
		return
	end
	started = true
	popRemote = Net.event("Physics", "Pop")
	Net.onServer(Net.event("Physics", "Land"), { rate = 1, burst = 1 }, onLand)
	Net.onServer(Net.event("Physics", "Slip"), { rate = 0.5, burst = 1 }, onSlip)

	-- hose: read the same Tool/Spray intents ToolService validates (we only push props)
	Net.event("Tool", "Spray").OnServerEvent:Connect(function(player: Player, aim: any)
		local ok, err = pcall(onSpray, player, aim)
		if not ok then
			warn(`[PhysicsFx] spray: {err}`)
		end
	end)
	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		lastAxe[p] = nil
		lastHose[p] = nil
		lastSlip[p] = nil
	end)

	-- engine explosions (HazardService) fling props too
	workspace.ChildAdded:Connect(function(child: Instance)
		if child:IsA("Explosion") then
			local pos, radius = child.Position, math.max(child.BlastRadius, 4) * Cfg.BlastRadiusScale
			task.defer(function()
				PhysicsFxService:Blast(pos, radius, Cfg.BlastPropPower)
			end)
		end
	end)

	-- truck run-over -> BOING (VehicleService already ragdolls the victim)
	local Vehicle = services.VehicleService
	if Vehicle and Vehicle.RanOver and type(Vehicle.RanOver.Connect) == "function" then
		Vehicle.RanOver:Connect(function(_driver: Player, victim: Player)
			local r = rootOfChar(victim.Character)
			if r then
				PhysicsFxService:Pop("runover", r.Position + Vector3.new(0, 3, 0))
			end
		end)
	end

	-- wait for the map, then scan it and keep watching for rebuilt / new props
	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 20 do
		task.wait(0.2)
	end
	local map = workspace:WaitForChild("Map", 10)
	if map then
		scan(map)
		map.DescendantAdded:Connect(function(d: Instance)
			if d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart") then
				table.insert(pending, d) -- builders parent models before/while filling them: register later
			end
		end)
	end
	CollectionService:GetInstanceAddedSignal(TAG):Connect(function(inst: Instance)
		table.insert(pending, inst)
	end)
	for _, inst in CollectionService:GetTagged(TAG) do
		PhysicsFxService:Register(inst)
	end
	print(`[PhysicsFx] {registered} knockable props`)

	local acc, truckAcc, pendAcc = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		truckAcc += dt
		pendAcc += dt
		if truckAcc >= 1 / Cfg.TruckHz then
			truckAcc = 0
			local ok, err = pcall(truckTick)
			if not ok then
				warn(`[PhysicsFx] truck: {err}`)
			end
		end
		if acc >= 1 / Cfg.TickHz then
			local step = acc
			acc = 0
			local ok, err = pcall(tick, step)
			if not ok then
				warn(`[PhysicsFx] tick: {err}`)
			end
		end
		if pendAcc >= 1 and #pending > 0 then
			pendAcc = 0
			local batch = pending
			pending = {}
			for _, inst in batch do
				if inst.Parent and isCandidate(inst) then
					PhysicsFxService:Register(inst)
				end
			end
		end
	end)
end

-- test hooks -------------------------------------------------------------------------------------------
function PhysicsFxService._stats(): { [string]: number }
	return PhysicsFxService:GetStats()
end

function PhysicsFxService._selftest(): (boolean, string)
	if not PropPhysics.isKnockableName("ParkBench_2", normNames, normExclude) then
		return false, "ParkBench not knockable"
	end
	if PropPhysics.isKnockableName("FuseBox", normNames, normExclude) then
		return false, "FuseBox knockable"
	end
	if budget:count(nil) > Cfg.MaxAwakeServer then
		return false, "awake over the server cap"
	end
	for area, n in budget.areas do
		if n > Cfg.MaxAwakePerArea then
			return false, `area {area} over cap`
		end
	end
	return true, `ok ({registered} props, {budget:count(nil)} awake)`
end

return PhysicsFxService
