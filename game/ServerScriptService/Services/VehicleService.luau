--!strict
-- VehicleService [owner: G2]. Fire trucks No. 67. The station keeps ONE lobby truck (adopted from
-- StationBuilder's bay 2, or built by Lib/Map/Props/TruckBuilder on the Station TruckSpot). Every
-- parallel mission instance gets its OWN truck, built inside the instance Model on its TruckSpot by
-- ParkAt(instanceId), so it is destroyed with the instance (MapService:DestroyInstance).
-- Every truck is DRIVABLE: a "Drive" prompt on the cab doors seats you in a hidden VehicleSeat; the
-- driver's client owns that truck's physics and VehicleController simulates bouncy raycast suspension
-- (ClientLib/TruckDrive). Up to 4 crew ride the back benches (touch a bench, jump to hop off).
-- With nobody driving a truck is anchored (parked), so it never drifts or blocks a round.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   VehicleService:GetTruck(id: string?): Model?          -- nil/"Station" = lobby truck; else that instance's truck
--   VehicleService:ResetTruck()                           -- lobby truck back to the station bay
--   VehicleService:ParkAt(id: string): boolean            -- locationId or v1.5 instanceId (builds the instance's
--                                                            truck on first call); riders come along
--   VehicleService:GetDriver(truck: Model?): Player?
-- Signals: Driven(driver: Player, studs: number)          -- fires when a driver gets out (studs travelled)
--          RanOver(driver: Player, victim: Player)        -- a player bowled over by a moving truck
-- Remotes: Vehicle/Horn (C->S, no args), Vehicle/Siren (C->S, no args: toggle),
--          Vehicle/Honked (S->C all: truck: Model)
-- Writes: workspace.FireTruck67 (lobby) and Instances.<id>.FireTruck67 (tag Truck; "Reel" tag TruckRefill,
--   "RescueDropoff" tag RescueDropoff, "DriveSeat" VehicleSeat, "CrewSeat_1..4" Seats);
--   truck attrs SirenOn: boolean, Driver: number (UserId, 0 = none), InstanceId: string ("" = lobby truck)
-- Telemetry: truck_drives, truck_distance, truck_honks, truck_run_over, trucks_built
-- Test hooks (DevHook only): _selftest(), _seat(player, id?)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript)
local TruckBuilder = require(
	ServerScriptService:WaitForChild("Lib"):WaitForChild("Map"):WaitForChild("Props"):WaitForChild("TruckBuilder") :: ModuleScript
)

local VehicleService = {}
VehicleService.Priority = 50
VehicleService.Driven = Signal.new() :: Signal.Signal<Player, number>
VehicleService.RanOver = Signal.new() :: Signal.Signal<Player, Player>

type Truck = {
	model: Model,
	chassis: BasePart,
	seat: VehicleSeat?,
	horn: Sound?,
	siren: Sound?,
	driver: Player?,
	driveStart: Vector3?,
	lastHonk: number,
}

-- TruckBuilder's PrimaryPart (Chassis) sits 2 studs above the ground point it was built on.
local GROUND_TO_PIVOT = CFrame.new(0, 2, 0)
-- Parts that only look like wheels: the suspension rays carry the truck, so these never touch the road.
local NO_COLLIDE_PREFIX = { "Wheel_", "Hub_", "HubCap_", "Fender_", "CabStep_", "SideSkirt_" }

local services: { [string]: any } = {}
local lobby: Truck? = nil
local byInstance: { [string]: Truck } = {}
local byModel: { [Model]: Truck } = {}
local homeGround: CFrame? = nil -- lobby truck's bay (used when the Station has no TruckSpot)
local runOverAt: { [Player]: number } = {}

local function locationModel(id: string): Instance?
	local Map = services.MapService
	if not Map then
		return nil
	end
	local inst = if type(Map.GetInstance) == "function" then Map:GetInstance(id) else nil
	return inst or Map:GetLocation(id)
end

local function isInstance(id: string): boolean
	local Map = services.MapService
	return Map ~= nil and type(Map.GetInstance) == "function" and Map:GetInstance(id) ~= nil
end

local function findSpot(root: Instance): BasePart?
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and (d:HasTag(Names.Tag.TruckSpot) or d.Name == "TruckSpot") then
			return d
		end
	end
	return nil
end

local function findTruckModel(root: Instance): Model?
	for _, d in root:GetDescendants() do
		if d:IsA("Model") and d:HasTag(Names.Tag.Truck) and d.PrimaryPart then
			return d
		end
	end
	return nil
end

local function ragdoll(character: Model, seconds: number, push: Vector3?)
	-- Shared/Ragdoll (body by G1). Fall back to PlatformStand while it is still a stub.
	local ok, R = pcall(require, Shared:WaitForChild("Ragdoll") :: ModuleScript)
	local done = false
	if ok and type(R) == "table" then
		done = (R :: any).enable(character, seconds) == true
		if push then
			(R :: any).knockback(character, push)
		end
	end
	if done then
		return
	end
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		task.delay(seconds, function()
			if hum.Parent then
				hum.PlatformStand = false
			end
		end)
	end
end

local function makeSound(parent: Instance, name: string, id: string, looped: boolean, volume: number): Sound
	local s = parent:FindFirstChild(name) :: Sound?
	if not s then
		local made = Instance.new("Sound")
		made.Name = name
		made.Parent = parent
		s = made
	end
	local snd = s :: Sound
	if snd.SoundId == "" then
		snd.SoundId = id
	end
	snd.Looped = looped
	snd.Volume = volume
	snd.RollOffMaxDistance = 300
	return snd
end

local function setSiren(t: Truck, on: boolean)
	t.model:SetAttribute("SirenOn", on)
	if t.siren then
		if on then
			t.siren:Play()
		else
			t.siren:Stop()
		end
	end
end

-- Snap a truck upright onto the ground under it (keep yaw) and anchor it as parked.
local function settle(t: Truck)
	local c = t.chassis
	if not c.Parent then
		return
	end
	local look = c.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.1 then
		flat = Vector3.new(0, 0, -1)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = { t.model }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	params.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(c.Position + Vector3.new(0, 6, 0), Vector3.new(0, -80, 0), params)
	local groundY = if hit then hit.Position.Y else c.Position.Y - 2
	local pos = Vector3.new(c.Position.X, groundY, c.Position.Z)
	c.Anchored = true
	t.model:PivotTo(CFrame.lookAt(pos, pos + flat.Unit) * GROUND_TO_PIVOT)
end

local function onDriverChanged(t: Truck)
	local seat = t.seat
	if not seat then
		return
	end
	local occ = seat.Occupant
	local player = if occ then Players:GetPlayerFromCharacter(occ.Parent) else nil
	if player == t.driver then
		return
	end
	local old = t.driver
	if old then
		local studs = 0
		if t.driveStart and t.chassis.Parent then
			studs = math.floor((t.chassis.Position - t.driveStart).Magnitude)
		end
		Telemetry.count("truck_distance", studs)
		t.driver = nil
		t.driveStart = nil
		VehicleService.Driven:Fire(old, studs)
	end
	if player then
		t.driver = player
		t.driveStart = t.chassis.Position
		t.model:SetAttribute("Driver", player.UserId)
		t.chassis.Anchored = false
		pcall(function()
			t.chassis:SetNetworkOwner(player)
		end)
		Telemetry.count("truck_drives")
		Net.notify(player, "WASD to drive, H to honk, G for the siren. Space to hop out.", "info")
	else
		t.model:SetAttribute("Driver", 0)
		task.delay(0.4, function()
			if not t.driver then
				settle(t)
			end
		end)
	end
end

-- Weld every part to the chassis (one physics assembly) and add the seats + Drive prompts.
local function rig(t: Truck)
	local m, root = t.model, t.chassis
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			local w = Instance.new("WeldConstraint")
			w.Part0 = root
			w.Part1 = d
			w.Parent = d
			d.Anchored = false
			d.Massless = true
			for _, prefix in NO_COLLIDE_PREFIX do
				if string.sub(d.Name, 1, #prefix) == prefix then
					d.CanCollide = false
				end
			end
		end
	end
	root.Anchored = true
	root.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.3, 0.6)

	-- Driver seat: hidden inside the cab; you get in through the door prompt, not by touching it.
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriveSeat"
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false
	seat.MaxSpeed = VehicleConfig.MaxSpeed
	seat.HeadsUpDisplay = false
	seat.Massless = true
	seat.CFrame = root.CFrame * CFrame.new(-2.4, 2.2, -8.6)
	local sw = Instance.new("WeldConstraint")
	sw.Part0 = root
	sw.Part1 = seat
	sw.Parent = seat
	seat.Parent = m
	t.seat = seat
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		onDriverChanged(t)
	end)

	for _, side in { "L", "R" } do
		local door = m:FindFirstChild(`DoorPanel_{side}`)
		if door and door:IsA("BasePart") then
			local p = Instance.new("ProximityPrompt")
			p.Name = "DrivePrompt"
			p.ActionText = "Drive"
			p.ObjectText = `Fire Truck {VehicleConfig.TruckNumber}`
			p.KeyboardKeyCode = Enum.KeyCode.F
			p.HoldDuration = 0.2
			p.MaxActivationDistance = 9
			p.RequiresLineOfSight = false
			p.Parent = door
			p.Triggered:Connect(function(player: Player)
				local char = player.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 and not seat.Occupant and player:GetAttribute(Names.Attr.Downed) ~= true then
					seat:Sit(hum)
				end
			end)
		end
	end

	-- Crew benches: two seats per bench, facing the middle of the deck.
	local n = 0
	for _, side in { "L", "R" } do
		local bench = m:FindFirstChild(`BenchSeat_{side}`)
		if bench and bench:IsA("BasePart") then
			for _, dz in { -1.4, 1.4 } do
				n += 1
				local s = Instance.new("Seat")
				s.Name = `CrewSeat_{n}`
				s.Size = Vector3.new(1.6, 0.3, 2)
				s.Transparency = 1
				s.CanCollide = false
				s.Massless = true
				local yaw = if side == "L" then -math.pi / 2 else math.pi / 2
				s.CFrame = bench.CFrame * CFrame.new(0, 0.3, dz) * CFrame.Angles(0, yaw, 0)
				local w = Instance.new("WeldConstraint")
				w.Part0 = root
				w.Part1 = s
				w.Parent = s
				s.Parent = m
			end
		end
	end
end

local function register(m: Model, instanceId: string): Truck?
	local root = m.PrimaryPart
	if not root then
		return nil
	end
	m.Name = "FireTruck67"
	m:SetAttribute("SirenOn", false)
	m:SetAttribute("Driver", 0)
	m:SetAttribute(Names.Attr.InstanceId, instanceId)
	local dropoff = m:FindFirstChild("RescueDropoff")
	if dropoff and dropoff:IsA("BasePart") then
		dropoff.CanQuery = false -- invisible volume must not block raycasts
	end
	local sirenPart = m:FindFirstChild("Siren")
	local sirenParent: Instance = if sirenPart then sirenPart else root
	local t: Truck = {
		model = m,
		chassis = root,
		seat = nil,
		horn = makeSound(root, "HornSound", VehicleConfig.HornSoundId, false, 1),
		siren = makeSound(sirenParent, "SirenSound", VehicleConfig.SirenSoundId, true, 0.6),
		driver = nil,
		driveStart = nil,
		lastHonk = 0,
	}
	if VehicleConfig.Drivable then
		rig(t)
	end
	byModel[m] = t
	m.Destroying:Connect(function()
		byModel[m] = nil
		if instanceId ~= "" and byInstance[instanceId] == t then
			byInstance[instanceId] = nil
		end
	end)
	Telemetry.count("trucks_built")
	return t
end

local function truckOf(player: Player): Truck?
	for _, t in byModel do
		if t.driver == player then
			return t
		end
	end
	return nil
end

local function honk(player: Player)
	local t = truckOf(player)
	if not t then
		return
	end
	local now = os.clock()
	if now - t.lastHonk < VehicleConfig.HonkCooldown then
		return
	end
	t.lastHonk = now
	if t.horn then
		t.horn.PlaybackSpeed = 0.9 + math.random() * 0.25 -- every honk a bit different
		t.horn:Play()
	end
	Net.event("Vehicle", "Honked"):FireAllClients(t.model)
	Telemetry.count("truck_honks")
end

local function toggleSiren(player: Player)
	local t = truckOf(player)
	if t then
		setSiren(t, not (t.model:GetAttribute("SirenOn") == true))
	end
end

-- Bowl over anyone standing in front of a fast truck ("Road Rage").
local function runOverTick()
	local now = os.clock()
	for _, t in byModel do
		local d = t.driver
		local c = t.chassis
		if not d or c.Anchored or not c.Parent then
			continue
		end
		local v = c.AssemblyLinearVelocity
		if v.Magnitude < VehicleConfig.RunOverSpeed then
			continue
		end
		local front = c.CFrame * CFrame.new(0, 2, -15)
		for _, p in Players:GetPlayers() do
			if p == d then
				continue
			end
			local char = p.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not char or not root or not hum or hum.SeatPart then
				continue
			end
			local rel = front:PointToObjectSpace(root.Position)
			if math.abs(rel.X) < 6.5 and math.abs(rel.Y) < 6 and math.abs(rel.Z) < 4 then
				if now - (runOverAt[p] or 0) < VehicleConfig.RunOverCooldown then
					continue
				end
				runOverAt[p] = now
				local dir = (v.Unit + Vector3.new(0, 0.9, 0)).Unit
				ragdoll(char, 2.5, dir * VehicleConfig.RunOverLaunch)
				Telemetry.count("truck_run_over")
				VehicleService.RanOver:Fire(d, p)
				Net.notify("all", `{d.DisplayName} ran over {p.DisplayName}! ROAD RAGE`, "blame")
			end
		end
	end
end

function VehicleService:Init(all: { [string]: any })
	services = all
end

function VehicleService:Start()
	local Horn = Net.event("Vehicle", "Horn")
	local Siren = Net.event("Vehicle", "Siren")
	Net.event("Vehicle", "Honked")
	Net.onServer(Horn, { rate = 4, burst = 2 }, honk)
	Net.onServer(Siren, { rate = 2, burst = 1 }, toggleSiren)

	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	local home = VehicleConfig.HomeLocation
	local homeModel = locationModel(home)
	local spot = homeModel and findSpot(homeModel)
	-- StationBuilder may already have placed truck 67 in bay 2: adopt it instead of building a twin.
	local m = homeModel and findTruckModel(homeModel)
	if m then
		homeGround = m:GetPivot() * GROUND_TO_PIVOT:Inverse()
		m.Parent = workspace
	else
		local cf = if spot then spot.CFrame else CFrame.new(0, 0.2, 0)
		m = TruckBuilder.Build(workspace, cf)
		homeGround = cf
	end
	lobby = register(m :: Model, "")
	if spot and lobby then
		VehicleService:ParkAt(home)
	end

	local Map = services.MapService
	if Map and Map.LocationBuilt then
		Map.LocationBuilt:Connect(function(model: Model, id: string)
			-- a rebuilt station brings its own truck: keep only ours
			for _, d in model:GetDescendants() do
				if d:IsA("Model") and d:HasTag(Names.Tag.Truck) and not byModel[d] then
					d:Destroy()
				end
			end
			if id == home and lobby and not lobby.driver then
				VehicleService:ParkAt(home)
			end
		end)
	end
	-- Lobby siren wails on its own while the (v1) round is hot.
	workspace:GetAttributeChangedSignal(Names.Attr.RoundState):Connect(function()
		local st = workspace:GetAttribute(Names.Attr.RoundState)
		if lobby and st == "Alarm" then
			setSiren(lobby, true)
		elseif lobby and (st == "Results" or st == "Lobby") then
			setSiren(lobby, false)
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		runOverAt[p] = nil
	end)
	RunService.Heartbeat:Connect(runOverTick)
	print(`[VehicleService] truck {VehicleConfig.TruckNumber} at {home} ({if spot then "TruckSpot" else "builder's bay"})`)
end

function VehicleService:GetTruck(id: string?): Model?
	if id == nil or id == "" or id == VehicleConfig.HomeLocation then
		return if lobby then lobby.model else nil
	end
	local t = byInstance[id]
	return if t then t.model else nil
end

function VehicleService:GetDriver(truck: Model?): Player?
	local t = if truck then byModel[truck] else lobby
	return if t then t.driver else nil
end

-- Locations (Station, Town) move the lobby truck; a mission instance gets its own truck, built on its
-- TruckSpot inside the instance Model the first time (so it dies with the instance).
function VehicleService:ParkAt(id: string): boolean
	local root = locationModel(id)
	local spot = root and findSpot(root)
	if root and isInstance(id) then
		local existing = byInstance[id]
		if existing and existing.model.Parent then
			if spot then
				existing.chassis.Anchored = true
				existing.model:PivotTo(spot.CFrame * GROUND_TO_PIVOT)
			end
			return true
		end
		-- the instance's builder may have made its own truck model; else build one on the TruckSpot
		local m = findTruckModel(root)
		if not m then
			if not spot then
				return false
			end
			m = TruckBuilder.Build(root, spot.CFrame)
		end
		local t = register(m :: Model, id)
		if not t then
			return false
		end
		byInstance[id] = t
		setSiren(t, true) -- arrives wailing
		task.delay(8, function()
			if t.model.Parent and not t.driver then
				setSiren(t, false)
			end
		end)
		return true
	end
	local t = lobby
	local target: CFrame? = if spot then spot.CFrame elseif id == VehicleConfig.HomeLocation then homeGround else nil
	if not t or not target then
		return false
	end
	t.chassis.Anchored = true
	t.chassis.AssemblyLinearVelocity = Vector3.zero
	t.chassis.AssemblyAngularVelocity = Vector3.zero
	t.model:PivotTo((target :: CFrame) * GROUND_TO_PIVOT)
	local d = t.driver
	if d then
		t.chassis.Anchored = false
		pcall(function()
			t.chassis:SetNetworkOwner(d)
		end)
	end
	return true
end

function VehicleService:ResetTruck()
	local t = lobby
	if t and t.seat and t.seat.Occupant then
		t.seat.Occupant.Sit = false
		t.seat.Occupant.Jump = true
	end
	VehicleService:ParkAt(VehicleConfig.HomeLocation)
end

function VehicleService:_seat(player: Player, id: string?): boolean
	local m = VehicleService:GetTruck(id)
	local t = m and byModel[m]
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not t or not t.seat or not hum or t.seat.Occupant then
		return false
	end
	t.seat:Sit(hum)
	return true
end

function VehicleService:_selftest(): (boolean, string)
	local t = lobby
	if not t then
		return false, "no lobby truck"
	end
	if not t.model:HasTag(Names.Tag.Truck) then
		return false, "truck not tagged Truck"
	end
	if VehicleConfig.Drivable and not t.model:FindFirstChild("DriveSeat") then
		return false, "no DriveSeat"
	end
	if not t.driver and not VehicleService:ParkAt(VehicleConfig.HomeLocation) then
		return false, `cannot park at {VehicleConfig.HomeLocation}`
	end
	local n = 0
	for _ in byModel do
		n += 1
	end
	return true, `lobby truck parked; {n} truck(s) live`
end

return VehicleService
