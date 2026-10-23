--!strict
-- VehicleService [owner: G2]. Fire truck No. 67: built at boot by Lib/Map/Props/TruckBuilder, parked on a
-- location's TruckSpot marker, and DRIVABLE: a "Drive" prompt on the cab doors seats you in a hidden
-- VehicleSeat; the driver's client owns the truck's physics and VehicleController simulates bouncy
-- raycast suspension (ClientLib/TruckDrive). Up to 4 crew ride on the back benches (touch the bench).
-- With nobody driving the truck is anchored (parked), so it never drifts or blocks a round.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   VehicleService:GetTruck(): Model?
--   VehicleService:ResetTruck()                         -- ParkAt(VehicleConfig.HomeLocation)
--   VehicleService:ParkAt(locationId: string): boolean  -- locationId or v1.5 instanceId: onto its TruckSpot (riders come along)
--   VehicleService:GetDriver(): Player?
-- Signals: Driven(driver: Player, studs: number)        -- fires when a driver gets out (studs travelled)
--          RanOver(driver: Player, victim: Player)      -- a player bowled over by the moving truck
-- Remotes: Vehicle/Horn (C->S, no args), Vehicle/Siren (C->S, no args: toggle), Vehicle/Honked (S->C all: no args)
-- Writes: workspace.FireTruck67 (tag Truck; parts "Reel" tag TruckRefill, "RescueDropoff" tag RescueDropoff,
--   "DriveSeat" VehicleSeat, "CrewSeat_1..4" Seats); truck attrs SirenOn: boolean, Driver: number (UserId, 0 = none)
-- Telemetry: truck_drives, truck_distance, truck_honks, truck_run_over
-- Test hooks (DevHook only): _selftest(), _seat(player)
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

local services: { [string]: any } = {}
local truck: Model? = nil
local chassis: BasePart? = nil
local driveSeat: VehicleSeat? = nil
local hornSound: Sound? = nil
local sirenSound: Sound? = nil
-- TruckBuilder's PrimaryPart (Chassis) sits 2 studs above the ground point it was built on.
local groundToPivot = CFrame.new(0, 2, 0)
local homeGround: CFrame? = nil -- where the truck was first parked, if the home location has no TruckSpot
local parkedAt: string? = nil
local driver: Player? = nil
local driveStart: Vector3? = nil
local lastHonk = 0
local runOverAt: { [Player]: number } = {}

-- Parts that only look like wheels: the suspension rays carry the truck, so these never touch the road.
local NO_COLLIDE_PREFIX = { "Wheel_", "Hub_", "HubCap_", "Fender_", "CabStep_", "SideSkirt_" }

local function locationModel(id: string): Instance?
	local Map = services.MapService
	if not Map then
		return nil
	end
	local inst = if type(Map.GetInstance) == "function" then Map:GetInstance(id) else nil
	return inst or Map:GetLocation(id)
end

-- `id` is a locationId ("Station", "Town") or a v1.5 mission instanceId.
local function findSpot(id: string): BasePart?
	local location = locationModel(id)
	if not location then
		return nil
	end
	for _, d in location:GetDescendants() do
		if d:IsA("BasePart") and (d:HasTag(Names.Tag.TruckSpot) or d.Name == "TruckSpot") then
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
	snd.SoundId = id
	snd.Looped = looped
	snd.Volume = volume
	snd.RollOffMaxDistance = 300
	return snd
end

local function setAnchored(on: boolean)
	if chassis then
		chassis.Anchored = on
	end
end

-- Weld every part to the chassis so the truck is one physics assembly.
local function rig(m: Model, root: BasePart)
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
	root.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.3, 0.6) -- heavy-ish, bouncy

	-- Driver seat: hidden inside the cab; you get in through the door prompt, not by touching it.
	local seat = Instance.new("VehicleSeat")
	seat.Name = "DriveSeat"
	seat.Size = Vector3.new(2, 0.4, 2)
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false -- no accidental sits
	seat.MaxSpeed = VehicleConfig.MaxSpeed
	seat.HeadsUpDisplay = false
	seat.CFrame = root.CFrame * CFrame.new(-2.4, 2.2, -8.6)
	seat.Massless = true
	local sw = Instance.new("WeldConstraint")
	sw.Part0 = root
	sw.Part1 = seat
	sw.Parent = seat
	seat.Parent = m
	driveSeat = seat

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
				VehicleService:_seat(player)
			end)
		end
	end

	-- Crew benches: two seats per bench, touch to hop on, jump to hop off.
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
				-- face the middle of the deck
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

local function onDriverChanged()
	local seat = driveSeat
	local m = truck
	if not seat or not m then
		return
	end
	local occ = seat.Occupant
	local player = if occ then Players:GetPlayerFromCharacter(occ.Parent) else nil
	if player == driver then
		return
	end
	-- previous driver got out
	if driver then
		local studs = 0
		if driveStart and chassis then
			studs = math.floor((chassis.Position - driveStart).Magnitude)
		end
		Telemetry.count("truck_distance", studs)
		VehicleService.Driven:Fire(driver, studs)
		driver = nil
		driveStart = nil
	end
	if player and chassis then
		driver = player
		driveStart = chassis.Position
		m:SetAttribute("Driver", player.UserId)
		setAnchored(false)
		pcall(function()
			(chassis :: BasePart):SetNetworkOwner(player)
		end)
		Telemetry.count("truck_drives")
		Net.notify(player, "WASD to drive, H to honk, G for the siren. Space to hop out.", "info")
	else
		m:SetAttribute("Driver", 0)
		-- settle: snap upright onto the ground under us (keep yaw), then anchor as parked
		task.delay(0.4, function()
			if driver or not chassis then
				return
			end
			local c = chassis :: BasePart
			local look = c.CFrame.LookVector
			local flat = Vector3.new(look.X, 0, look.Z)
			if flat.Magnitude < 0.1 then
				flat = Vector3.new(0, 0, -1)
			end
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { m }
			local hit = workspace:Raycast(c.Position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), params)
			local groundY = if hit then hit.Position.Y else c.Position.Y - 2
			local pos = Vector3.new(c.Position.X, groundY, c.Position.Z)
			setAnchored(true)
			m:PivotTo(CFrame.lookAt(pos, pos + flat.Unit) * groundToPivot)
		end)
	end
end

local function honk(player: Player)
	if player ~= driver or not hornSound then
		return
	end
	local t = os.clock()
	if t - lastHonk < VehicleConfig.HonkCooldown then
		return
	end
	lastHonk = t
	hornSound.PlaybackSpeed = 0.9 + math.random() * 0.25 -- every honk a bit different
	hornSound:Play()
	Net.event("Vehicle", "Honked"):FireAllClients()
	Telemetry.count("truck_honks")
end

local function toggleSiren(player: Player)
	local m = truck
	if not m or player ~= driver then
		return
	end
	local on = not (m:GetAttribute("SirenOn") == true)
	m:SetAttribute("SirenOn", on)
	if sirenSound then
		if on then
			sirenSound:Play()
		else
			sirenSound:Stop()
		end
	end
end

-- Bowl over anyone standing in front of a fast truck (the trailer's "Road Rage").
local function runOverTick()
	local m = truck
	local c = chassis
	if not m or not c or not driver or c.Anchored then
		return
	end
	local v = c.AssemblyLinearVelocity
	local speed = v.Magnitude
	if speed < VehicleConfig.RunOverSpeed then
		return
	end
	local front = c.CFrame * CFrame.new(0, 2, -15)
	local now = os.clock()
	for _, p in Players:GetPlayers() do
		if p == driver then
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
			local d = driver :: Player
			VehicleService.RanOver:Fire(d, p)
			Net.notify("all", `{d.DisplayName} ran over {p.DisplayName}! ROAD RAGE`, "blame")
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
	local spot = findSpot(home)
	-- StationBuilder may already have placed truck 67 in bay 2: adopt it instead of building a twin.
	local m: Model? = nil
	local homeModel = locationModel(home)
	if homeModel then
		for _, d in homeModel:GetDescendants() do
			if d:IsA("Model") and d:HasTag(Names.Tag.Truck) and d.PrimaryPart then
				m = d
				break
			end
		end
	end
	if m then
		homeGround = (m :: Model):GetPivot() * groundToPivot:Inverse()
		m.Parent = workspace
	else
		local cf = if spot then spot.CFrame else CFrame.new(0, 0.2, 0)
		m = TruckBuilder.Build(workspace, cf)
		homeGround = cf
		groundToPivot = cf:Inverse() * (m :: Model):GetPivot()
	end
	local truckModel = m :: Model
	truckModel.Name = "FireTruck67"
	local dropoff = truckModel:FindFirstChild("RescueDropoff")
	if dropoff and dropoff:IsA("BasePart") then
		dropoff.CanQuery = false -- invisible volume must not block raycasts
	end
	truck = truckModel
	truckModel:SetAttribute("SirenOn", false)
	truckModel:SetAttribute("Driver", 0)
	local root = truckModel.PrimaryPart
	chassis = root
	parkedAt = home

	if root then
		hornSound = makeSound(root, "HornSound", VehicleConfig.HornSoundId, false, 1)
		local sirenPart = truckModel:FindFirstChild("Siren")
		local existing = sirenPart and sirenPart:FindFirstChild("SirenSound") :: Sound?
		sirenSound = existing or makeSound(root, "SirenSound", VehicleConfig.SirenSoundId, true, 0.6)
		if sirenSound and sirenSound.SoundId == "" then
			sirenSound.SoundId = VehicleConfig.SirenSoundId
		end
		if VehicleConfig.Drivable then
			rig(truckModel, root)
			if driveSeat then
				(driveSeat :: VehicleSeat):GetPropertyChangedSignal("Occupant"):Connect(onDriverChanged)
			end
		end
	end

	local Map = services.MapService
	if Map and Map.LocationBuilt then
		Map.LocationBuilt:Connect(function(model: Model, id: string)
			-- a rebuilt station brings its own truck: keep only ours
			for _, d in model:GetDescendants() do
				if d:IsA("Model") and d:HasTag(Names.Tag.Truck) and d ~= truck then
					d:Destroy()
				end
			end
			if id == parkedAt and not driver then
				VehicleService:ParkAt(id)
			end
		end)
	end
	-- The siren wails on its own while the round is hot.
	workspace:GetAttributeChangedSignal(Names.Attr.RoundState):Connect(function()
		local st = workspace:GetAttribute(Names.Attr.RoundState)
		if st == "Alarm" and truck then
			truck:SetAttribute("SirenOn", true)
			if sirenSound then
				sirenSound:Play()
			end
		elseif (st == "Results" or st == "Lobby") and truck then
			truck:SetAttribute("SirenOn", false)
			if sirenSound then
				sirenSound:Stop()
			end
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		runOverAt[p] = nil
	end)
	RunService.Heartbeat:Connect(runOverTick)
	print(`[VehicleService] truck {VehicleConfig.TruckNumber} parked at {parkedAt} ({if spot then "TruckSpot" else "builder's bay"})`)
end

function VehicleService:GetTruck(): Model?
	return truck
end

function VehicleService:GetDriver(): Player?
	return driver
end

-- Teleports the truck (and anyone sitting in it: seats are welded) onto the location's TruckSpot.
function VehicleService:ParkAt(locationId: string): boolean
	local spot = findSpot(locationId)
	local m = truck
	local target: CFrame? = if spot then spot.CFrame elseif locationId == VehicleConfig.HomeLocation then homeGround else nil
	if not m or not target then
		return false
	end
	setAnchored(true)
	if chassis then
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
	end
	m:PivotTo((target :: CFrame) * groundToPivot)
	parkedAt = locationId
	if driver then
		-- keep it drivable at the new spot
		setAnchored(false)
		pcall(function()
			(chassis :: BasePart):SetNetworkOwner(driver)
		end)
	end
	return true
end

function VehicleService:ResetTruck()
	-- kick the driver out first so the truck doesn't drive away from the bay
	local seat = driveSeat
	if seat and seat.Occupant then
		seat.Occupant.Sit = false
		seat.Occupant.Jump = true
	end
	VehicleService:ParkAt(VehicleConfig.HomeLocation)
end

function VehicleService:_seat(player: Player): boolean
	local seat = driveSeat
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not seat or not hum or hum.Health <= 0 or seat.Occupant then
		return false
	end
	if hum:GetAttribute(Names.Attr.Downed) or char and char:GetAttribute(Names.Attr.Downed) then
		return false
	end
	seat:Sit(hum)
	return true
end

function VehicleService:_selftest(): (boolean, string)
	local m = truck
	if not m then
		return false, "no truck built"
	end
	if not m:HasTag(Names.Tag.Truck) then
		return false, "truck not tagged Truck"
	end
	if VehicleConfig.Drivable and not m:FindFirstChild("DriveSeat") then
		return false, "no DriveSeat"
	end
	if not driver and not VehicleService:ParkAt(VehicleConfig.HomeLocation) then
		return false, `no TruckSpot at {VehicleConfig.HomeLocation}`
	end
	return true, `parked at {parkedAt}`
end

return VehicleService
