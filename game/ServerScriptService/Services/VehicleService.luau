--!strict
-- VehicleService [owner: Vehicle agent]. v2: ONE fire truck per player (docs/game/08 "Vehicles").
-- On join each player gets "FireTruck_<UserId>" (attr OwnerUserId, Bay) built by
-- Lib/Map/Props/TruckBuilder at the TruckBay whose attr Bay = their Helmet (1-4), or at a reserve
-- spot in front of the station when that bay is taken / there are no TruckBay parts yet. Trucks live
-- in Workspace.Trucks (so a station rebuild never eats them) and are destroyed when the owner leaves.
-- Getting in is goofy: the cab doors are PHYSICAL (HingeConstraint "DoorHinge", servo + bouncy limits).
-- "Open door" on the handle (or pull it with physics hands) swings it open with a wobble; only then
-- does the seat prompt on that side show ("Drive" for the owner on the left, "Ride shotgun" on the
-- right). Back benches ("CrewSeat_1..4") have their own "Hop on" prompts. Getting out pops the door
-- open and puts you outside it. Driving off with a door open lets it swing on inertia and SLAM shut,
-- bonking anyone in the way; a hard ram can knock a door clean off (RespawnTruck builds a new truck).
-- The driver's client owns the truck's physics and VehicleController simulates the goofy suspension.
-- With nobody driving a truck is anchored (parked), so it never drifts or blocks a round.
--
-- Public API (docs/game/08 "Vehicles"):
--   VehicleService:GetTruck(player: Player): Model?
--   VehicleService:RespawnTruck(player: Player): boolean   -- near your truck: flip it upright in place;
--                                                            far away: back to your bay; lost / a door
--                                                            fell off: a fresh truck at your bay
--   VehicleService:ParkAt(player: Player, cf: CFrame): boolean   -- cf = ground point, truck faces cf.LookVector
--   VehicleService:GetDriver(truck: Model?): Player?
--   VehicleService:GetOwner(truck: Model?): Player?
--   VehicleService:ResetTruck(player: Player?)             -- back to the bay (all trucks when nil)
-- Legacy (VehicleConfig.PerMissionTrucks = true only): GetTruck(instanceId: string) / ParkAt(instanceId)
--   build a v1 truck inside that mission instance. With the flag off, string calls return nil/false.
-- Signals: Entered(player, truck)  Exited(player, truck)  -- any seat (drive or crew)
--          SirenChanged(truck, on)
--          Driven(driver: Player, studs: number)          -- a driver got out (studs travelled)
--          RanOver(driver: Player, victim: Player)        -- a player bowled over by a moving truck
-- Remotes: Vehicle/Horn (C->S), Vehicle/Siren (C->S toggle), Vehicle/Respawn (C->S),
--          Vehicle/Honked (S->C all: truck: Model), Vehicle/Pop (S->C all: part, text, kind) for SLAM!/BONK!
-- Truck attrs also: DoorOpen_L/R, DoorGone_L/R (booleans). Optional: HandsService:RegisterGrabbable(doorPanel).
-- Truck attrs: OwnerUserId: number, Bay: number (0 = reserve), SirenOn: boolean, Driver: number (UserId, 0 = none),
--   InstanceId: string ("" for player trucks)
-- Optional hook: PhysicsFxService:TruckHit(truck: Model, target: Model | BasePart, velocity: Vector3): boolean
--   (true = handled; otherwise this service ragdolls players itself). Loose props are launched here only
--   when PhysicsFxService is absent (it ploughs its own registered props in front of moving trucks).
-- Telemetry: trucks_built, truck_drives, truck_distance, truck_honks, truck_run_over, truck_prop_hits, truck_respawns,
--   truck_door_bonks, truck_doors_lost
-- Test hooks (DevHook only): _selftest(), _seat(player)
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local PhysicsService = game:GetService("PhysicsService")
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
VehicleService.Entered = Signal.new() :: Signal.Signal<Player, Model>
VehicleService.Exited = Signal.new() :: Signal.Signal<Player, Model>
VehicleService.SirenChanged = Signal.new() :: Signal.Signal<Model, boolean>
VehicleService.Driven = Signal.new() :: Signal.Signal<Player, number>
VehicleService.RanOver = Signal.new() :: Signal.Signal<Player, Player>

local TRUCK_BAY_TAG = "TruckBay"
local BODY_GROUP = "TruckBody"
local DOOR_GROUP = "TruckDoor" -- doors don't collide with their own cab, only with people and props

type Door = {
	side: string, -- "L" | "R"
	model: Model,
	panel: BasePart,
	hinge: HingeConstraint?,
	prompt: ProximityPrompt?,
	open: boolean,
	gone: boolean, -- fell off
	free: boolean, -- swinging on inertia (about to slam)
	freeSince: number,
}

type Truck = {
	model: Model,
	chassis: BasePart,
	seat: VehicleSeat?,
	horn: Sound?,
	siren: Sound?,
	driver: Player?,
	driveStart: Vector3?,
	lastHonk: number,
	owner: Player?,
	bay: number, -- 1..4 = TruckBay, 0 = reserve row
	reserve: number, -- reserve slot when bay == 0
	occupants: { [Seat | VehicleSeat]: Player },
	removing: boolean, -- destroyed on purpose (no auto-respawn)
	doors: { [string]: Door },
	seatPrompts: { [Seat | VehicleSeat]: ProximityPrompt },
	lastVel: Vector3?,
}

-- TruckBuilder's PrimaryPart (Chassis) sits 2 studs above the ground point it was built on.
local GROUND_TO_PIVOT = CFrame.new(0, 2, 0)
-- Parts that only look like wheels: the suspension rays carry the truck, so these never touch the road.
local NO_COLLIDE_PREFIX = { "Wheel_", "Hub_", "HubCap_", "Fender_", "CabStep_", "SideSkirt_" }

local services: { [string]: any } = {}
local byModel: { [Model]: Truck } = {}
local byOwner: { [Player]: Truck } = {}
local byInstance: { [string]: Truck } = {} -- legacy per-mission trucks
local lastRespawn: { [Player]: number } = {}
local runOverAt: { [Player]: number } = {}
local propHitAt: { [BasePart]: number } = {}
local bonkAt: { [Player]: number } = {}
local trucksFolder: Folder? = nil
local spawnFor: (player: Player) -> any -- forward (register's auto-respawn needs it)

---------------------------------------------------------------------------- helpers

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function folder(): Folder
	local f = trucksFolder
	if f and f.Parent then
		return f
	end
	local existing = workspace:FindFirstChild("Trucks")
	if existing and existing:IsA("Folder") then
		trucksFolder = existing
		return existing
	end
	local made = Instance.new("Folder")
	made.Name = "Trucks"
	made.Parent = workspace
	trucksFolder = made
	return made
end

local function soundId(own: string, audioName: string): string
	if own ~= "" then
		return own
	end
	local ok, Audio = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AudioConfig") :: ModuleScript) :: any
	end)
	local entry = ok and type(Audio) == "table" and type(Audio.Sounds) == "table" and Audio.Sounds[audioName]
	return if type(entry) == "table" and type(entry.id) == "string" then entry.id else ""
end

local function groundParams(): RaycastParams
	local ignore: { Instance } = {}
	for _, m in CollectionService:GetTagged(Names.Tag.Truck) do
		table.insert(ignore, m)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

-- Ground point under `pos` facing `fwd` (flattened).
local function groundCF(pos: Vector3, fwd: Vector3): CFrame
	local flat = Vector3.new(fwd.X, 0, fwd.Z)
	if flat.Magnitude < 0.1 then
		flat = Vector3.new(0, 0, -1)
	end
	local hit = workspace:Raycast(pos + Vector3.new(0, 8, 0), Vector3.new(0, -120, 0), groundParams())
	local y = if hit then hit.Position.Y else pos.Y
	local p = Vector3.new(pos.X, y, pos.Z)
	return CFrame.lookAt(p, p + flat.Unit)
end

local function ragdoll(character: Model, seconds: number, push: Vector3?)
	-- Shared/Ragdoll; fall back to PlatformStand if it is missing.
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

local function physicsFxHit(t: Truck, target: Instance, v: Vector3): boolean
	local PFx = services.PhysicsFxService
	if PFx and type(PFx.TruckHit) == "function" then
		local ok, handled = pcall(PFx.TruckHit, PFx, t.model, target, v)
		return ok and handled == true
	end
	return false
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
	if (t.model:GetAttribute("SirenOn") == true) == on then
		return
	end
	t.model:SetAttribute("SirenOn", on)
	if t.siren then
		if on then
			t.siren:Play()
		else
			t.siren:Stop()
		end
	end
	VehicleService.SirenChanged:Fire(t.model, on)
end

-- Move a truck (and whoever rides it) onto ground cframe `cf`. Parked = anchored unless someone drives.
local function place(t: Truck, cf: CFrame)
	local c = t.chassis
	if not c.Parent then
		return
	end
	c.Anchored = true
	c.AssemblyLinearVelocity = Vector3.zero
	c.AssemblyAngularVelocity = Vector3.zero
	t.model:PivotTo(cf * GROUND_TO_PIVOT)
	local d = t.driver
	if d then
		c.Anchored = false
		pcall(function()
			c:SetNetworkOwner(d)
		end)
	end
end

-- Snap a truck upright onto the ground under it (keep yaw).
local function settle(t: Truck)
	local c = t.chassis
	if c.Parent then
		place(t, groundCF(c.Position, c.CFrame.LookVector))
	end
end

---------------------------------------------------------------------------- station bays

local function stationModel(): Instance?
	local Map = services.MapService
	if Map and type(Map.GetLocation) == "function" then
		local ok, m = pcall(Map.GetLocation, Map, VehicleConfig.HomeLocation)
		if ok and m then
			return m
		end
	end
	local mapF = workspace:FindFirstChild("Map")
	return mapF and mapF:FindFirstChild(VehicleConfig.HomeLocation)
end

-- { [bay]: BasePart } from TruckBay-tagged parts (Station v2).
local function bayParts(): { [number]: BasePart }
	local out: { [number]: BasePart } = {}
	for _, p in CollectionService:GetTagged(TRUCK_BAY_TAG) do
		local n = p:GetAttribute("Bay")
		if p:IsA("BasePart") and type(n) == "number" and p:IsDescendantOf(workspace) then
			out[n] = p
		end
	end
	return out
end

-- Ground cframe the reserve row is laid out from (truck-forward = LookVector).
local function anchorCF(): CFrame
	local bays = bayParts()
	local first = bays[1] or bays[2] or bays[3] or bays[4]
	if first then
		return groundCF(first.Position, first.CFrame.LookVector)
	end
	local station = stationModel()
	if station then
		for _, d in station:GetDescendants() do
			if d:IsA("BasePart") and (d:HasTag(Names.Tag.TruckSpot) or d.Name == "TruckSpot") then
				return groundCF(d.Position, d.CFrame.LookVector)
			end
		end
		for _, d in station:GetDescendants() do
			-- v1 decor truck (StationBuilder bay 2): its nose points out of the bay door
			if d:IsA("Model") and d:HasTag(Names.Tag.Truck) and d.PrimaryPart and not byModel[d] then
				local cf = d:GetPivot()
				return groundCF(cf.Position, cf.LookVector)
			end
		end
		if station:IsA("Model") then
			local cf = station:GetPivot()
			return groundCF(cf.Position, cf.LookVector)
		end
	end
	local Map = services.MapService
	if Map and type(Map.GetSpawnCFrame) == "function" then
		local ok, cf = pcall(Map.GetSpawnCFrame, Map, 1)
		if ok and typeof(cf) == "CFrame" then
			return groundCF(cf.Position + cf.LookVector * 20, cf.LookVector)
		end
	end
	return CFrame.new(0, 0, 0)
end

local function reserveCF(k: number): CFrame
	local a = anchorCF()
	local spot = a * CFrame.new((k - 2.5) * VehicleConfig.ReserveSpacing, 0, -VehicleConfig.ReserveAhead)
	return groundCF(spot.Position, a.LookVector)
end

local function helmetOf(player: Player): number
	local h = player:GetAttribute(Names.Attr.Helmet)
	return if type(h) == "number" then math.floor(h) else 0
end

-- Bay = helmet if that TruckBay exists and no other truck holds it; else the first free reserve slot.
local function assignHome(t: Truck, player: Player)
	local want = helmetOf(player)
	local bays = bayParts()
	local taken = false
	for _, o in byOwner do
		if o ~= t and o.bay == want then
			taken = true
		end
	end
	if want >= 1 and bays[want] and not taken then
		t.bay = want
		t.reserve = 0
	else
		t.bay = 0
		local used: { [number]: boolean } = {}
		for _, o in byOwner do
			if o ~= t and o.bay == 0 then
				used[o.reserve] = true
			end
		end
		local k = 1
		while used[k] do
			k += 1
		end
		t.reserve = k
	end
	t.model:SetAttribute("Bay", t.bay)
end

local function homeCF(t: Truck): CFrame
	if t.bay >= 1 then
		local part = bayParts()[t.bay]
		if part then
			return groundCF(part.Position, part.CFrame.LookVector)
		end
	end
	return reserveCF(math.max(t.reserve, 1))
end

-- v1 decor trucks (no owner) parked where a player truck goes are cleared away.
local function clearDecor(cf: CFrame)
	for _, m in CollectionService:GetTagged(Names.Tag.Truck) do
		if m:IsA("Model") and not byModel[m] and m:GetAttribute("OwnerUserId") == nil then
			if (m:GetPivot().Position - cf.Position).Magnitude < 14 then
				m:Destroy()
			end
		end
	end
end

---------------------------------------------------------------------------- seats + doors

local function unseat(seat: Seat | VehicleSeat)
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	local hum = seat.Occupant
	if hum then
		hum.Sit = false
	end
end

local function occupantPlayer(seat: Seat | VehicleSeat): Player?
	local occ = seat.Occupant
	return if occ then Players:GetPlayerFromCharacter(occ.Parent) else nil
end

local function popAt(part: Instance, text: string, kind: string)
	pcall(function()
		Net.event("Vehicle", "Pop"):FireAllClients(part, text, kind)
	end)
end

local function oneShot(parent: Instance, id: string, speed: number, volume: number)
	if id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.PlaybackSpeed = speed
	s.Volume = volume
	s.RollOffMaxDistance = 120
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 4)
end

-- Seat prompts only show when you could actually get in: the seat is free and (for the cab) the door
-- on that side is open or gone. Handle prompts say Open / Close.
local function refreshPrompts(t: Truck)
	for seat, p in t.seatPrompts do
		local free = seat.Occupant == nil
		local side = seat:GetAttribute("DoorSide")
		local doorOk = true
		if type(side) == "string" then
			local d = t.doors[side]
			doorOk = d == nil or d.open or d.gone
		end
		p.Enabled = free and doorOk
	end
	for _, d in t.doors do
		if d.prompt then
			d.prompt.Enabled = not d.gone
			d.prompt.ActionText = if d.open then "Close door" else "Open door"
		end
	end
end

local function setDoor(t: Truck, d: Door, open: boolean)
	local h = d.hinge
	if d.gone or not h or not h.Parent then
		return
	end
	local wasOpen = d.open
	d.open = open
	d.free = false
	h.ActuatorType = Enum.ActuatorType.Servo
	h.AngularSpeed = VehicleConfig.DoorSpeed
	h.ServoMaxTorque = VehicleConfig.DoorTorque
	-- aim AT the limit: the door slams into it and the limit's restitution makes it wobble back
	h.TargetAngle = if open then VehicleConfig.DoorDir * VehicleConfig.DoorOpenAngle else 0
	t.model:SetAttribute(`DoorOpen_{d.side}`, open)
	if wasOpen ~= open then
		oneShot(d.panel, VehicleConfig.DoorSlamSoundId, if open then 1.3 else 0.7, if open then 0.5 else 0.9)
	end
	refreshPrompts(t)
end

local function bonkNear(t: Truck, d: Door, now: number)
	local panel = d.panel
	if not panel.Parent or panel.AssemblyAngularVelocity.Magnitude < 1.5 then
		return
	end
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not char or not root or not hum or hum.SeatPart or (root.Position - panel.Position).Magnitude > 3.6 then
			continue
		end
		if now - (bonkAt[p] or 0) < 1.2 then
			continue
		end
		bonkAt[p] = now
		count("truck_door_bonks")
		local away = root.Position - t.chassis.Position
		away = Vector3.new(away.X, 0, away.Z)
		away = if away.Magnitude > 0.1 then away.Unit else Vector3.new(1, 0, 0)
		local push = away * VehicleConfig.DoorBonkPush + Vector3.new(0, 18, 0)
		if not physicsFxHit(t, char, push) then
			ragdoll(char, 1.2, push)
		end
		popAt(root, "BONK!", "bonk")
		oneShot(root, VehicleConfig.BonkSoundId, 0.9 + math.random() * 0.3, 0.8)
	end
end

-- Rammed hard: the door flies off (cartoon). The side then counts as open for getting in.
local function breakDoor(t: Truck, d: Door)
	if d.gone then
		return
	end
	d.gone = true
	d.open = true
	if d.hinge then
		d.hinge:Destroy()
		d.hinge = nil
	end
	local panel = d.panel
	t.model:SetAttribute(`DoorGone_{d.side}`, true)
	d.model.Parent = folder()
	d.model.Name = "LooseDoor"
	for _, part in d.model:GetDescendants() do
		if part:IsA("BasePart") then
			part.CollisionGroup = "Default"
			part.CanCollide = part == panel
		end
	end
	pcall(function()
		panel:SetNetworkOwner(nil)
	end)
	local out = (panel.Position - t.chassis.Position)
	out = Vector3.new(out.X, 0, out.Z)
	out = if out.Magnitude > 0.1 then out.Unit else Vector3.new(1, 0, 0)
	panel.AssemblyLinearVelocity = t.chassis.AssemblyLinearVelocity * 0.6 + out * 30 + Vector3.new(0, 28, 0)
	panel.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 18
	Debris:AddItem(d.model, 12)
	popAt(panel, "CLONK! DOOR OFF!", "bonk")
	oneShot(panel, soundId("", "DoorBreak"), 1.2, 0.8)
	count("truck_doors_lost")
	if t.driver then
		Net.notify(t.driver, "Your door fell off. Very aerodynamic.", "info")
	end
	refreshPrompts(t)
end

-- 10 Hz: open doors swing free when the truck drives off and SLAM shut; pulled-open doors latch open.
local function doorTick(t: Truck, now: number)
	local c = t.chassis
	local speed = c.AssemblyLinearVelocity.Magnitude
	for _, d in t.doors do
		local h = d.hinge
		if d.gone then
			continue
		end
		if not h or not h.Parent or not d.panel.Parent then
			d.gone = true
			refreshPrompts(t)
			continue
		end
		local angle = h.CurrentAngle * VehicleConfig.DoorDir
		if d.open and not d.free and t.driver and not c.Anchored and speed > VehicleConfig.DoorSwingSpeed then
			d.free = true
			d.freeSince = now
			h.ActuatorType = Enum.ActuatorType.None -- inertia swings it shut as the truck pulls away
		end
		if d.free then
			bonkNear(t, d, now)
			if angle < 8 or now - d.freeSince > VehicleConfig.DoorFreeSeconds then
				setDoor(t, d, false)
				popAt(d.panel, "SLAM!", "slam")
				bonkNear(t, d, now)
			end
		elseif not d.open and angle > 30 then
			setDoor(t, d, true) -- yanked open by hand / physics
		end
	end
end

local function exitCF(t: Truck, seat: Instance): CFrame
	local c = t.chassis.CFrame
	if seat:IsA("BasePart") then
		local rel = c:PointToObjectSpace(seat.Position)
		if rel.Z < -4 then -- cab seat: out of the side door
			local side = if rel.X < 0 then -1 else 1
			local pos = c * Vector3.new(side * 7.6, 1.5, -4.2)
			return CFrame.lookAt(pos, pos + c.RightVector * side)
		end
		local side = if rel.X < 0 then -1 else 1
		local pos = c * Vector3.new(side * 3, 1.5, 16.5)
		return CFrame.lookAt(pos, pos - c.LookVector)
	end
	return c * CFrame.new(-7.6, 1.5, -4.2)
end

-- Fallback for exits the client didn't place (e.g. the seat weld broke): don't leave anyone in the cab.
local function placeOutside(t: Truck, seat: Instance, player: Player)
	task.delay(0.3, function()
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum or hum.SeatPart or not t.chassis.Parent then
			return
		end
		local rel = t.chassis.CFrame:PointToObjectSpace(root.Position)
		if math.abs(rel.X) < 5.2 and rel.Z > -13.5 and rel.Z < 14 and rel.Y < 9 then
			char:PivotTo(exitCF(t, seat))
		end
	end)
end

local function onDriverChanged(t: Truck)
	local seat = t.seat
	if not seat then
		return
	end
	local player = occupantPlayer(seat)
	if player == t.driver then
		return
	end
	local old = t.driver
	if old then
		local studs = 0
		if t.driveStart and t.chassis.Parent then
			studs = math.floor((t.chassis.Position - t.driveStart).Magnitude)
		end
		count("truck_distance", studs)
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
		for _, d in t.doors do
			if not d.gone then
				pcall(function()
					d.panel:SetNetworkOwner(player)
				end)
			end
		end
		count("truck_drives")
	else
		t.model:SetAttribute("Driver", 0)
		task.delay(0.4, function()
			if not t.driver and t.chassis.Parent then
				settle(t)
			end
		end)
	end
end

local function watchSeat(t: Truck, seat: Seat | VehicleSeat)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local now = occupantPlayer(seat)
		local was = t.occupants[seat]
		if was == now then
			return
		end
		if was then
			t.occupants[seat] = nil
			VehicleService.Exited:Fire(was, t.model)
			-- getting out of the cab pops that side's door open
			local side = seat:GetAttribute("DoorSide")
			local d = if type(side) == "string" then t.doors[side] else nil
			if d and not d.open and not d.gone then
				setDoor(t, d, true)
			end
			placeOutside(t, seat, was)
		end
		if now then
			t.occupants[seat] = now
			VehicleService.Entered:Fire(now, t.model)
		end
		if seat == t.seat then
			onDriverChanged(t)
		end
		refreshPrompts(t)
	end)
end

local function canSit(player: Player): Humanoid?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or hum.SeatPart or player:GetAttribute(Names.Attr.Downed) == true then
		return nil
	end
	return hum
end

local function prompt(parent: Instance, name: string, action: string, objectText: string, key: Enum.KeyCode, dist: number): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = name
	p.ActionText = action
	p.ObjectText = objectText
	p.KeyboardKeyCode = key
	p.HoldDuration = 0.1
	p.MaxActivationDistance = dist
	p.RequiresLineOfSight = false
	p.Parent = parent
	return p
end

local function keyOf(name: string, fallback: Enum.KeyCode): Enum.KeyCode
	local ok, k = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	return if ok and k then k else fallback
end

local function rigDoor(t: Truck, side: string)
	local m = t.model
	local model = m:FindFirstChild(`Door_{side}`)
	local panel = model and model:FindFirstChild(`DoorPanel_{side}`)
	if not model or not model:IsA("Model") or not panel or not panel:IsA("BasePart") then
		return
	end
	local hinge = panel:FindFirstChild("DoorHinge") :: HingeConstraint?
	if not hinge then
		return
	end
	hinge.LimitsEnabled = true
	if VehicleConfig.DoorDir >= 0 then
		hinge.LowerAngle, hinge.UpperAngle = 0, VehicleConfig.DoorOpenAngle
	else
		hinge.LowerAngle, hinge.UpperAngle = -VehicleConfig.DoorOpenAngle, 0
	end
	hinge.Restitution = VehicleConfig.DoorRestitution
	local d: Door = {
		side = side,
		model = model,
		panel = panel,
		hinge = hinge,
		prompt = nil,
		open = false,
		gone = false,
		free = false,
		freeSince = 0,
	}
	t.doors[side] = d
	panel:SetAttribute("Grabbable", true)
	local Hands = services.HandsService
	if Hands and type(Hands.RegisterGrabbable) == "function" then
		pcall(Hands.RegisterGrabbable, Hands, panel)
	end
	local handle = model:FindFirstChild(`DoorHandle_{side}`)
	if handle and handle:IsA("BasePart") then
		local p = prompt(handle, "DoorPrompt", "Open door", "Truck door", keyOf(VehicleConfig.KeyDoor, Enum.KeyCode.E), 8)
		p.Triggered:Connect(function(_player: Player)
			setDoor(t, d, not d.open)
		end)
		d.prompt = p
	end
	setDoor(t, d, false)
end

-- Weld every part to the chassis (one physics assembly) except Jointed ones (doors, steering wheel,
-- bobblehead); hinged doors; seats + their prompts.
local function rig(t: Truck)
	local m, root = t.model, t.chassis
	-- seats are TruckBuilder mount points; older builds may lack them
	if not m:FindFirstChild("DriveSeat") then
		local seat = Instance.new("VehicleSeat")
		seat.Name = "DriveSeat"
		seat.Size = Vector3.new(2, 0.4, 2)
		seat.Transparency = 1
		seat.CanCollide = false
		seat.CanTouch = false
		seat.HeadsUpDisplay = false
		seat.CFrame = root.CFrame * CFrame.new(-2.4, 2.1, -7.0)
		seat.Parent = m
	end
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			d.Anchored = false
			local anc = d:FindFirstAncestorWhichIsA("Model")
			local isDoor = anc ~= nil and anc ~= m and string.sub(anc.Name, 1, 5) == "Door_"
			if d:GetAttribute("Jointed") == true then
				if isDoor then
					d.Massless = false
					d.CustomPhysicalProperties = PhysicalProperties.new(0.5, 0.3, 0.4)
					d.CollisionGroup = DOOR_GROUP
				else
					d.Massless = true
					d.CollisionGroup = BODY_GROUP
				end
				continue
			end
			local w = Instance.new("WeldConstraint")
			w.Part0 = root
			w.Part1 = d
			w.Parent = d
			d.Massless = true
			d.CollisionGroup = BODY_GROUP
			for _, prefix in NO_COLLIDE_PREFIX do
				if string.sub(d.Name, 1, #prefix) == prefix then
					d.CanCollide = false
				end
			end
		end
	end
	root.Anchored = true
	root.CollisionGroup = BODY_GROUP
	root.CustomPhysicalProperties = PhysicalProperties.new(1.2, 0.3, 0.6)
	rigDoor(t, "L")
	rigDoor(t, "R")

	local seat = m:FindFirstChild("DriveSeat") :: VehicleSeat
	seat.MaxSpeed = VehicleConfig.MaxSpeed
	seat.CanTouch = false
	seat:SetAttribute("DoorSide", "L")
	t.seat = seat
	watchSeat(t, seat)
	local ownerName = if t.owner then t.owner.DisplayName else "Crew"
	local enterKey = keyOf(VehicleConfig.KeyEnter, Enum.KeyCode.F)
	local dp = prompt(seat, "SeatPrompt", "Drive", `{ownerName}'s Truck`, enterKey, 9)
	t.seatPrompts[seat] = dp
	dp.Triggered:Connect(function(player: Player)
		if VehicleConfig.OwnerOnlyDrives and t.owner and player ~= t.owner then
			Net.notify(player, `{ownerName}'s truck! Ride shotgun or hop on the back. Yours is in bay {helmetOf(player)}.`, "info")
			return
		end
		local hum = canSit(player)
		if hum and not seat.Occupant then
			seat:Sit(hum)
		end
	end)
	for i = 1, 5 do
		local s = m:FindFirstChild(`CrewSeat_{i}`)
		if s and s:IsA("Seat") then
			s.CanTouch = false
			watchSeat(t, s)
			if i == 5 then
				s:SetAttribute("DoorSide", "R")
			end
			local p = prompt(s, "SeatPrompt", if i == 5 then "Ride shotgun" else "Hop on", `{ownerName}'s Truck`, enterKey, 8)
			t.seatPrompts[s] = p
			p.Triggered:Connect(function(player: Player)
				local hum = canSit(player)
				if hum and not s.Occupant then
					s:Sit(hum)
				end
			end)
		end
	end
	refreshPrompts(t)
end

local function nameTag(t: Truck)
	local owner = t.owner
	local roof = t.model:FindFirstChild("CabRoof")
	if not owner or not roof then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "OwnerTag"
	gui.Size = UDim2.fromOffset(200, 40)
	gui.StudsOffset = Vector3.new(0, 4.5, 0)
	gui.MaxDistance = 160
	gui.AlwaysOnTop = false
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(1, 1)
	l.Font = Enum.Font.LuckiestGuy
	l.TextScaled = true
	l.Text = `{owner.DisplayName}'s 67`
	l.TextColor3 = Color3.fromRGB(255, 244, 196)
	l.TextStrokeTransparency = 0
	l.Parent = gui
	gui.Parent = roof
end

local function register(m: Model, instanceId: string, owner: Player?): Truck?
	local root = m.PrimaryPart
	if not root then
		return nil
	end
	m:SetAttribute("SirenOn", false)
	m:SetAttribute("Driver", 0)
	m:SetAttribute(Names.Attr.InstanceId, instanceId)
	local dropoff = m:FindFirstChild("RescueDropoff")
	if dropoff and dropoff:IsA("BasePart") then
		dropoff.CanQuery = false -- invisible volume must not block raycasts
	end
	local sirenPart = m:FindFirstChild("Siren")
	local t: Truck = {
		model = m,
		chassis = root,
		seat = nil,
		horn = makeSound(root, "HornSound", soundId(VehicleConfig.HornSoundId, "Horn"), false, 1),
		siren = makeSound(sirenPart or root, "SirenSound", soundId(VehicleConfig.SirenSoundId, "Siren"), true, 0.6),
		driver = nil,
		driveStart = nil,
		lastHonk = 0,
		owner = owner,
		bay = 0,
		reserve = 0,
		occupants = {},
		removing = false,
		doors = {},
		seatPrompts = {},
		lastVel = nil,
	}
	if VehicleConfig.Drivable then
		rig(t)
	end
	nameTag(t)
	byModel[m] = t
	m.Destroying:Connect(function()
		byModel[m] = nil
		if instanceId ~= "" and byInstance[instanceId] == t then
			byInstance[instanceId] = nil
		end
		if owner and byOwner[owner] == t then
			byOwner[owner] = nil
			-- blown up / fell out of the world: a fresh one at the bay
			if not t.removing and owner.Parent == Players then
				task.delay(2, function()
					if owner.Parent == Players and not byOwner[owner] then
						count("truck_respawns")
						local ok, err = pcall(spawnFor, owner)
						if not ok then
							warn(`[VehicleService] respawn for {owner.Name} failed: {err}`)
						end
					end
				end)
			end
		end
	end)
	count("trucks_built")
	return t
end

---------------------------------------------------------------------------- per-player trucks

function spawnFor(player: Player): Truck?
	if byOwner[player] then
		return byOwner[player]
	end
	local m = TruckBuilder.Build(folder(), CFrame.new(0, 2000, 0)) -- built out of sight, then placed
	m.Name = `FireTruck_{player.UserId}`
	m:SetAttribute("OwnerUserId", player.UserId)
	local t = register(m, "", player)
	if not t then
		m:Destroy()
		return nil
	end
	byOwner[player] = t
	assignHome(t, player)
	local cf = homeCF(t)
	clearDecor(cf)
	place(t, cf)
	return t
end

local function despawnFor(player: Player)
	local t = byOwner[player]
	byOwner[player] = nil
	if t then
		t.removing = true
		t.model:Destroy()
	end
end

local function onPlayer(player: Player)
	if not VehicleConfig.PerPlayerTrucks then
		return
	end
	task.spawn(function()
		-- SquadService hands out helmets on join; give it a moment so the bay matches
		local t0 = os.clock()
		while helmetOf(player) == 0 and os.clock() - t0 < 4 and player.Parent == Players do
			task.wait(0.2)
		end
		if player.Parent ~= Players then
			return
		end
		local ok, err = pcall(spawnFor, player)
		if not ok then
			warn(`[VehicleService] truck for {player.Name} failed: {err}`)
		end
	end)
	player:GetAttributeChangedSignal(Names.Attr.Helmet):Connect(function()
		local t = byOwner[player]
		if not t or t.driver or next(t.occupants) ~= nil then
			return
		end
		local atHome = (t.chassis.Position - (homeCF(t) * GROUND_TO_PIVOT).Position).Magnitude < 4
		local old = t.bay
		assignHome(t, player)
		if atHome and (t.bay ~= old or t.bay == 0) then
			place(t, homeCF(t))
		end
	end)
end

---------------------------------------------------------------------------- driving remotes

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
	count("truck_honks")
end

local function toggleSiren(player: Player)
	local t = truckOf(player)
	if t then
		setSiren(t, not (t.model:GetAttribute("SirenOn") == true))
	end
end

---------------------------------------------------------------------------- collisions (comedy)

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.MaxParts = 24

local function isCharacterPart(p: BasePart): boolean
	local m = p:FindFirstAncestorWhichIsA("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then
			return true
		end
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return false
end

local function hitPlayers(t: Truck, d: Player, v: Vector3, now: number)
	local front = t.chassis.CFrame * CFrame.new(0, 2, -15)
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
			if not physicsFxHit(t, char, v) then
				local dir = (v.Unit + Vector3.new(0, 0.9, 0)).Unit
				ragdoll(char, 2.5, dir * VehicleConfig.RunOverLaunch)
			end
			count("truck_run_over")
			VehicleService.RanOver:Fire(d, p)
			Net.notify("all", `{d.DisplayName} ran over {p.DisplayName}! ROAD RAGE`, "blame")
		end
	end
end

local function hitProps(t: Truck, v: Vector3, now: number)
	local ignore: { Instance } = { folder() }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	overlap.FilterDescendantsInstances = ignore
	local box = t.chassis.CFrame * CFrame.new(0, 3, -15.5)
	local parts = workspace:GetPartBoundsInBox(box, Vector3.new(11, 7, 5), overlap)
	for _, part in parts do
		local root = part.AssemblyRootPart or part
		if part.Anchored or root.Anchored or root.AssemblyMass > VehicleConfig.PropMaxMass then
			continue
		end
		if now - (propHitAt[root] or 0) < 1 or isCharacterPart(part) or part:FindFirstAncestorOfClass("Tool") then
			continue
		end
		propHitAt[root] = now
		count("truck_prop_hits")
		if physicsFxHit(t, root, v) then
			continue
		end
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
		local launch = v * VehicleConfig.PropLaunch + Vector3.new(0, 25 + math.random() * 15, 0)
		root.AssemblyLinearVelocity = launch
		root.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 20
	end
end

local tickAcc = 0
local doorAcc = 0
local function collisionTick(dt: number)
	tickAcc += dt
	if tickAcc < 0.05 then
		return
	end
	tickAcc = 0
	local now = os.clock()
	doorAcc += 1
	local doDoors = doorAcc % 2 == 0 -- doors at 10 Hz
	for _, t in byModel do
		local d = t.driver
		local c = t.chassis
		if doDoors and c.Parent then
			doorTick(t, now)
		end
		if not d or c.Anchored or not c.Parent then
			t.lastVel = nil
			continue
		end
		local v = c.AssemblyLinearVelocity
		local speed = v.Magnitude
		-- rammed hard (sudden speed change): doors may fly off
		local last = t.lastVel
		t.lastVel = v
		local dvFlat = if last then Vector3.new(v.X - last.X, 0, v.Z - last.Z).Magnitude else 0
		if dvFlat > VehicleConfig.DoorBreakDv then -- horizontal only: hard landings don't count
			for _, door in t.doors do
				if not door.gone and (door.open or math.random() < VehicleConfig.DoorBreakClosedChance) then
					breakDoor(t, door)
				end
			end
		end
		if speed >= VehicleConfig.RunOverSpeed then
			hitPlayers(t, d, v, now)
		end
		-- PhysicsFxService ploughs its registered props itself; only do it here without it
		if speed >= VehicleConfig.PropHitSpeed and not services.PhysicsFxService then
			hitProps(t, v, now)
		end
	end
	for p, at in propHitAt do
		if now - at > 5 or not p.Parent then
			propHitAt[p] = nil
		end
	end
end

-- Trucks that fell out of the world come back to their bay.
local function lostTick()
	while true do
		task.wait(1)
		local lost: { Player } = {}
		for owner, t in byOwner do
			if t.chassis.Parent and t.chassis.Position.Y < VehicleConfig.LostBelowY then
				table.insert(lost, owner)
			end
		end
		for _, owner in lost do
			local t = byOwner[owner]
			if t then
				t.removing = true
				byOwner[owner] = nil
				t.model:Destroy()
			end
			count("truck_respawns")
			pcall(spawnFor, owner)
		end
	end
end

---------------------------------------------------------------------------- legacy per-mission trucks

local function legacyParkAt(id: string): boolean
	local Map = services.MapService
	local root = Map and type(Map.GetInstance) == "function" and Map:GetInstance(id)
	if not root then
		return false
	end
	local spot: BasePart? = nil
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and (d:HasTag(Names.Tag.TruckSpot) or d.Name == "TruckSpot") then
			spot = d
			break
		end
	end
	local existing = byInstance[id]
	if existing and existing.model.Parent then
		if spot then
			place(existing, spot.CFrame)
		end
		return true
	end
	if not spot then
		return false
	end
	local m = TruckBuilder.Build(root, spot.CFrame)
	m.Name = "FireTruck67"
	local t = register(m, id, nil)
	if not t then
		return false
	end
	byInstance[id] = t
	return true
end

---------------------------------------------------------------------------- lifecycle

function VehicleService:Init(all: { [string]: any })
	services = all
end

function VehicleService:Start()
	folder()
	pcall(function()
		for _, g in { BODY_GROUP, DOOR_GROUP } do
			if not PhysicsService:IsCollisionGroupRegistered(g) then
				PhysicsService:RegisterCollisionGroup(g)
			end
		end
		PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, DOOR_GROUP, false)
	end)
	Net.event("Vehicle", "Pop")
	Net.onServer(Net.event("Vehicle", "Horn"), { rate = 4, burst = 2 }, honk)
	Net.onServer(Net.event("Vehicle", "Siren"), { rate = 2, burst = 1 }, toggleSiren)
	Net.onServer(Net.event("Vehicle", "Respawn"), { rate = 0.5, burst = 1 }, function(player: Player)
		VehicleService:RespawnTruck(player)
	end)
	Net.event("Vehicle", "Honked")

	Players.PlayerRemoving:Connect(function(p: Player)
		despawnFor(p)
		runOverAt[p] = nil
		bonkAt[p] = nil
		lastRespawn[p] = nil
	end)
	RunService.Heartbeat:Connect(collisionTick)

	local t0 = os.clock()
	while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	task.spawn(lostTick)
	local nBays = 0
	for _ in bayParts() do
		nBays += 1
	end
	print(`[VehicleService] per-player trucks; {nBays} TruckBay(s) found{if nBays == 0 then " (reserve parking)" else ""}`)
end

---------------------------------------------------------------------------- API

local function isPlayer(x: any): boolean
	return typeof(x) == "Instance" and x:IsA("Player")
end

function VehicleService:GetTruck(who: any): Model?
	if isPlayer(who) then
		local t = byOwner[who :: Player]
		return if t and t.model.Parent then t.model else nil
	end
	if type(who) == "string" and who ~= "" then
		local t = byInstance[who]
		return if t then t.model else nil
	end
	return nil
end

function VehicleService:GetDriver(truck: Model?): Player?
	local t = truck and byModel[truck]
	return if t then t.driver else nil
end

function VehicleService:GetOwner(truck: Model?): Player?
	local t = truck and byModel[truck]
	return if t then t.owner else nil
end

function VehicleService:ParkAt(who: any, cf: CFrame?): boolean
	if isPlayer(who) then
		local player = who :: Player
		local t = byOwner[player] or spawnFor(player)
		if not t then
			return false
		end
		place(t, cf or homeCF(t))
		return true
	end
	if type(who) == "string" and VehicleConfig.PerMissionTrucks then
		return legacyParkAt(who)
	end
	return false -- v2: missions no longer park trucks
end

function VehicleService:RespawnTruck(player: Player): boolean
	if not isPlayer(player) or player.Parent ~= Players then
		return false
	end
	local now = os.clock()
	if now - (lastRespawn[player] or -math.huge) < VehicleConfig.RespawnCooldown then
		return false
	end
	lastRespawn[player] = now
	count("truck_respawns")
	local t = byOwner[player]
	local doorLost = false
	if t then
		for _, d in t.doors do
			doorLost = doorLost or d.gone
		end
	end
	if not t or doorLost or not t.model.Parent or not t.chassis.Parent or t.chassis.Position.Y < VehicleConfig.LostBelowY then
		if t then
			for seat in t.occupants do
				unseat(seat)
			end
		end
		if t then
			t.removing = true
			byOwner[player] = nil
			t.model:Destroy()
		end
		local fresh = spawnFor(player)
		Net.notify(player, "Fresh truck waiting at the station!", "info")
		return fresh ~= nil
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local near = root ~= nil and (root.Position - t.chassis.Position).Magnitude <= VehicleConfig.UnflipRange
	if near then
		-- flip it back on its wheels right here (a little drop for the boing)
		local c = t.chassis
		local g = groundCF(c.Position, c.CFrame.LookVector)
		place(t, g + Vector3.new(0, 3, 0))
	else
		for seat in t.occupants do
			unseat(seat)
		end
		place(t, homeCF(t))
		Net.notify(player, "Your truck is back at the station.", "info")
	end
	return true
end

function VehicleService:ResetTruck(player: Player?)
	for owner, t in byOwner do
		if player == nil or owner == player then
			for seat in t.occupants do
				unseat(seat)
			end
			place(t, homeCF(t))
		end
	end
end

function VehicleService:_seat(player: Player): boolean
	local t = byOwner[player]
	local hum = canSit(player)
	if not t or not t.seat or not hum or t.seat.Occupant then
		return false
	end
	t.seat:Sit(hum)
	return true
end

function VehicleService:_selftest(): (boolean, string)
	local n, missing = 0, {}
	for _, p in Players:GetPlayers() do
		local m = VehicleService:GetTruck(p)
		if not m then
			table.insert(missing, p.Name)
		elseif not m:HasTag(Names.Tag.Truck) or (VehicleConfig.Drivable and not m:FindFirstChild("DriveSeat")) then
			return false, `{m.Name} is missing its Truck tag or DriveSeat`
		else
			n += 1
		end
	end
	if VehicleConfig.PerPlayerTrucks and #missing > 0 then
		return false, `no truck for {table.concat(missing, ", ")}`
	end
	return true, `{n} player truck(s) live`
end

return VehicleService
