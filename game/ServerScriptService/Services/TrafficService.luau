--!strict
-- TrafficService [owner: Traffic]. Cartoon city traffic (docs/game/08 "City").
--
-- Cars follow lane centrelines of CityBuilder's road graph (offsets from the graph's lane data,
-- junction boxes sized from the drawn road widths), pick random turns at junctions and RESERVE their
-- path through each junction (Lib/Traffic/Junction: conflicting paths go one after another, first
-- come first served, through road first at unsignalled junctions, never enter without room on the
-- exit lane, so junctions can't gridlock). Signalled junctions follow CityBuilder's TrafficPhase.
-- Cars keep their distance along their PATH, honk at people in the road, drive round parked trucks
-- and stalled cars, PULL OVER for moving fire trucks with the siren on (or a driven siren truck crawling
-- right behind them, TrafficConfig.SlowYieldBehind; a few panic-swerve), and
-- unstick themselves: reroute after RerouteAfter s at a line, go anyway after ForceAfter, ghost
-- through after GhostAfter, recycled when stuck out of view. A truck that rams a car at speed sends
-- it flying with real physics and the driver pops out yelling.
--
-- Simulation is KINEMATIC on the server (no physics until a car is hit), at TrafficConfig.SimHz.
-- The server never moves a car's parts while it drives: it publishes the pose as model attributes
-- (PublishHz) and every client interpolates the anchored Hitbox (TrafficController), so a car costs
-- one attribute update per publish, not 30 part CFrames. Cars spawn/despawn near players only.
-- No road graph (Workspace.Map.City.RoadGraphJson / RoadGraph folder) = no traffic, no errors.
--
-- Reads: Workspace.Map.City.RoadGraphJson (StringValue, JSON) or .RoadGraph (RoadNode parts attr NodeId,
--   RoadEdge ObjectValues with A/B), or CityBuilder.Graph; City attr TrafficPhase + TrafficLight models
--   (or LightState attrs); tag Truck + attr SirenOn;
--   VehicleService.SirenChanged(truck, on) (nil-guarded), VehicleService:GetDriver / truck attr Driver.
-- Writes: Workspace.Traffic (Folder) / TrafficCar_<kind> Models (tag TrafficCar) with attributes
--   Pose: CFrame (ground point, facing travel), Speed: number, State: "Drive"|"Yield"|"Panic"|"Wrecked",
--   Blink: "L"|"R"|"" (indicators), Brake: boolean (brake lights), Kind, RootY, HalfLen (CarBuilder).
-- Remotes: Traffic/Honk (S->C all: car: Model)
-- Signals: Rammed(driver: Player?, car: Model, kind: string)
-- Calls (nil-guarded): PhysicsFxService:Impulse(part, vector) / :Pop(kind, pos, word)
-- API: TrafficService:GetCars(): {Model}, :GetStats(): {[string]: number}, :Clear()
-- Counters: traffic_graph_loaded, traffic_spawned, traffic_despawned, traffic_yields, traffic_panics,
--   traffic_honks, traffic_rammed, traffic_forced, traffic_rerouted, traffic_ghosted, traffic_passes,
--   traffic_recycled
-- Test hooks (DevHook only): _selftest(), _why(), _loadGraph(json: string), _spawnNear(player, n?)
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TrafficConfig") :: ModuleScript) :: any
local TrafficLib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Traffic")
local RoadNet = require(TrafficLib:WaitForChild("RoadNet") :: ModuleScript)
local Driver = require(TrafficLib:WaitForChild("Driver") :: ModuleScript)
local CarBuilder = require(TrafficLib:WaitForChild("CarBuilder") :: ModuleScript)
local Junction = require(TrafficLib:WaitForChild("Junction") :: ModuleScript)

local TrafficService = {}
TrafficService.Priority = 130
TrafficService.Rammed = Signal.new() :: Signal.Signal<Player?, Model, string>

local CAR_TAG = "TrafficCar"
local LIGHT_TAG = "TrafficLight"

type Seg = RoadNet.Seg
-- a car's claim on the junction ahead: requested (waiting) or granted (reserved, crossing)
type Req = { node: string, seg: Seg, t: number, granted: boolean, eligible: boolean }
type Car = {
	model: Model,
	root: BasePart,
	kind: string,
	halfLen: number,
	speedMul: number,
	seg: Seg,
	s: number,
	laneId: number,
	nextLane: number?,
	cleared: boolean,
	req: Req?,
	waitT: number, -- seconds held at a junction line (not at a red)
	rerouteT: number,
	why: string, -- what held the car this step: "red" | "yield" | "junction" | "leader" | "obstacle" | ""
	excused: boolean, -- stopped for a good reason (red light / siren), directly or via the car ahead
	leader: any, -- Car ahead on my path (path-based)
	passing: boolean,
	passT: number,
	passX: number,
	passZ: number,
	passHalf: number,
	queued: boolean, -- stopped in a queue that resolves itself (behind a junction wait / red / queue)
	ghostT: number,
	immuneT: number, -- ignore sirens (after a too-long yield)
	v: number,
	lat: number,
	latTarget: number,
	yaw: number,
	state: string,
	stateT: number,
	clearT: number,
	stuck: number, -- seconds at ~0 speed without an excuse
	lastHonk: number,
	seed: number,
	x: number,
	y: number,
	z: number,
	hx: number,
	hz: number,
	pose: CFrame,
	blink: string,
	brake: boolean,
	pubPose: CFrame?,
	pubV: number,
	pubState: string,
	pubBlink: string,
	pubBrake: boolean,
	dead: boolean,
}

type Truck = { model: Model, pos: Vector3, vel: Vector3, cf: CFrame, speed: number, siren: boolean, driven: boolean }

local services: { [string]: any } = {}
local net: RoadNet.Net? = nil
local graphKey = ""
local folder: Folder? = nil
local cars: { Car } = {}
local byModel: { [Model]: Car } = {}
local signalled: { [string]: boolean } = {}
local lightFor: { [number]: Instance } = {}
local junctions: { [string]: { [Car]: boolean } } = {}
local phase: string? = nil
local sirenOverride: { [Model]: boolean } = {}
local rng = Random.new()
local lastToast = 0
local HonkRemote: RemoteEvent? = nil
local stats = { stuckMax = 0, forced = 0, rerouted = 0, ghosted = 0, passed = 0, recycled = 0 }

local function count(name: string, n: number?)
	Telemetry.count(name, n or 1)
end

-- Road graph -------------------------------------------------------------------------------------------

local function cityFolder(): Instance?
	local map = workspace:FindFirstChild("Map")
	return map and map:FindFirstChild("City")
end

local function v3(v: any): any
	if typeof(v) == "Vector3" then
		return { x = v.X, y = v.Y, z = v.Z }
	end
	if typeof(v) == "Instance" and (v :: Instance):IsA("BasePart") then
		local p = (v :: BasePart).Position
		return { x = p.X, y = p.Y, z = p.Z }
	end
	return v
end

-- RoadGraph folder: RoadNode parts (attr NodeId) + RoadEdge ObjectValues (A/B attrs, or A/B ObjectValue
-- children pointing at RoadNode parts, or Value = A with attr B). Edge attributes become lane data.
local function graphFromFolder(f: Instance): any?
	local nodes: { [string]: any } = {}
	local partId: { [Instance]: string } = {}
	local made = 0
	for _, d in f:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "RoadNode" or d:GetAttribute("NodeId") ~= nil) then
			made += 1
			local nid = tostring(d:GetAttribute("NodeId") or `{d.Name}_{made}`)
			nodes[nid] = v3(d)
			partId[d] = nid
		end
	end
	local function ref(v: any): string?
		if typeof(v) == "Instance" then
			local inst = v :: Instance
			if inst:IsA("ObjectValue") then
				return ref(inst.Value)
			end
			return partId[inst] or (if inst:GetAttribute("NodeId") ~= nil then tostring(inst:GetAttribute("NodeId")) else nil)
		end
		if type(v) == "string" or type(v) == "number" then
			return tostring(v)
		end
		return nil
	end
	local edges = {}
	for _, d in f:GetDescendants() do
		if not (d.Name == "RoadEdge" or (d:IsA("ObjectValue") and d.Parent ~= nil and d.Name ~= "A" and d.Name ~= "B")) then
			continue
		end
		local a = ref(d:GetAttribute("A")) or ref(d:FindFirstChild("A")) or (if d:IsA("ObjectValue") then ref(d.Value) else nil)
		local b = ref(d:GetAttribute("B")) or ref(d:FindFirstChild("B"))
		if a and b then
			local offsets = d:GetAttribute("LaneOffsets")
			local offs = nil
			if type(offsets) == "string" then
				offs = {}
				for token in string.gmatch(offsets, "[-%d%.]+") do
					table.insert(offs, tonumber(token))
				end
			end
			table.insert(edges, {
				a = a,
				b = b,
				speedLimit = d:GetAttribute("SpeedLimit"),
				width = d:GetAttribute("Width"),
				lanes = {
					count = d:GetAttribute("Lanes") or d:GetAttribute("LaneCount"),
					direction = d:GetAttribute("Direction"),
					offsets = offs,
				},
			})
		end
	end
	if next(nodes) == nil or #edges == 0 then
		return nil
	end
	return { nodes = nodes, edges = edges }
end

-- CityBuilder.Graph = { nodes = {[id] = Vector3}, edges = {{a, b}} } (only if the module is already loaded)
local function graphFromModule(): any?
	local ok, g = pcall(function()
		local lib = ServerScriptService:FindFirstChild("Lib")
		local mod = lib and lib:FindFirstChild("Map")
		mod = mod and mod:FindFirstChild("Locations")
		mod = mod and mod:FindFirstChild("CityBuilder")
		if not mod then
			return nil
		end
		local cb = require(mod :: ModuleScript) :: any
		return if type(cb) == "table" then cb.Graph else nil
	end)
	if not ok or type(g) ~= "table" or type(g.nodes) ~= "table" then
		return nil
	end
	local nodes = {}
	for k, v in g.nodes do
		nodes[k] = v3(v)
	end
	return { nodes = nodes, edges = g.edges }
end

-- Returns (decoded graph, key that changes when the source changes). A source whose key equals
-- `known` is not decoded again (returns nil, known).
local function readGraph(known: string): (any?, string)
	local city = cityFolder()
	if city then
		local js = city:FindFirstChild("RoadGraphJson")
		if js and js:IsA("StringValue") and js.Value ~= "" then
			local key = `json:{#js.Value}:{string.sub(js.Value, 1, 64)}:{string.sub(js.Value, -64)}`
			if key == known then
				return nil, key
			end
			local ok, data = pcall(function()
				return HttpService:JSONDecode(js.Value)
			end)
			if ok and type(data) == "table" then
				return data, key
			end
		end
		local f = city:FindFirstChild("RoadGraph")
		if f then
			local key = `folder:{#f:GetChildren()}`
			if key == known then
				return nil, key
			end
			local g = graphFromFolder(f)
			if g then
				return g, key
			end
		end
	end
	if known ~= "" and string.sub(known, 1, 7) == "module:" then
		return nil, known
	end
	local g = graphFromModule()
	if g then
		return g, `module:{#(g.edges or {})}`
	end
	return nil, ""
end

local function groundParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if folder then
		table.insert(ignore, folder)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	for _, t in CollectionService:GetTagged(Names.Tag.Truck) do
		table.insert(ignore, t)
	end
	params.FilterDescendantsInstances = ignore
	params.IgnoreWater = true
	return params
end

local function snapLanes(n: RoadNet.Net)
	if not Cfg.SnapToGround then
		return
	end
	local params = groundParams()
	params.RespectCanCollide = true -- leaves, decals, markers and other non-solid bits are not road
	-- The lane heights from RoadNet are already the road top. Only nudge them onto a SOLID surface that
	-- is within SNAP_TOLERANCE of that height: casting from 5 studs up across 16 studs used to land on
	-- tree canopies, traffic-light arms or parked cars, and the sloped lanes made cars bob up and down
	-- and sink into the road.
	local SNAP_TOLERANCE = 1.25
	local function surface(x: number, y: number, z: number): number
		local hit = workspace:Raycast(Vector3.new(x, y + SNAP_TOLERANCE, z), Vector3.new(0, -2 * SNAP_TOLERANCE, 0), params)
		if hit and hit.Normal.Y > 0.9 and math.abs(hit.Position.Y - y) <= SNAP_TOLERANCE then
			return hit.Position.Y
		end
		return y
	end
	for i, lane in n.lanes do
		lane.ay = surface(lane.ax, lane.ay, lane.az)
		lane.by = surface(lane.bx, lane.by, lane.bz)
		if i % 50 == 0 then
			task.wait()
		end
	end
end

local function posOf(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return nil
end

local function lookOf(inst: Instance): Vector3
	if inst:IsA("BasePart") then
		return inst.CFrame.LookVector
	elseif inst:IsA("Model") then
		return inst:GetPivot().LookVector
	end
	return Vector3.zero
end

-- Signalled junctions: every TrafficLight (CityBuilder Model named "TrafficLight", or tagged
-- "TrafficLight", or anything with a LightState attribute) belongs to the nearest junction node
-- within LightMatchRadius. Those junctions follow the City model's TrafficPhase ("XGreen" | "XAmber"
-- | "ZGreen" | "ZAmber": X = traffic driving along X); a light's own LightState (if any) overrides it
-- for that junction's lanes.
local function scanLights()
	local n = net
	if not n then
		return
	end
	local lights: { Instance } = {}
	local seen: { [Instance]: boolean } = {}
	for _, inst in CollectionService:GetTagged(LIGHT_TAG) do
		if inst:IsDescendantOf(workspace) then
			seen[inst] = true
			table.insert(lights, inst)
		end
	end
	local city = cityFolder()
	if city then
		for i, d in city:GetDescendants() do
			if not seen[d] and ((d.Name == "TrafficLight" and d:IsA("Model")) or d:GetAttribute("LightState") ~= nil) then
				seen[d] = true
				table.insert(lights, d)
			end
			if i % 4000 == 0 then
				task.wait()
			end
		end
	end
	signalled = {}
	lightFor = {}
	for _, l in lights do
		local p = posOf(l)
		if not p then
			continue
		end
		local best: string? = nil
		local bestD = Cfg.LightMatchRadius
		for id, node in n.nodes do
			if n.junction[id] then
				local d = math.sqrt((p.X - node.x) ^ 2 + (p.Z - node.z) ^ 2)
				if d < bestD then
					best, bestD = id, d
				end
			end
		end
		if best then
			signalled[best] = true
			if l:GetAttribute("LightState") ~= nil then
				-- legacy per-light state: the light facing against the lane controls it
				for _, lane in n.lanes do
					if lane.to == best then
						local look = lookOf(l)
						local align = -(look.X * lane.hx + look.Z * lane.hz)
						local cur = lightFor[lane.id]
						if align > 0.7 and (not cur) then
							lightFor[lane.id] = l
						end
					end
				end
			end
		end
	end
end

-- "green" | "yellow" | "red" for a lane into a signalled junction, nil = not signalled
local function lightState(lane: RoadNet.Lane): string?
	if not signalled[lane.to] then
		return nil
	end
	local l = lightFor[lane.id]
	if l and l.Parent then
		local st = Driver.light(l:GetAttribute("LightState"))
		if st then
			return st
		end
	end
	return Junction.lightState(phase, lane.hx, lane.hz) or "green"
end

-- Cars -------------------------------------------------------------------------------------------------

-- Drop the car's junction request / reservation.
local function release(car: Car)
	local req = car.req
	if req then
		local set = junctions[req.node]
		if set then
			set[car] = nil
		end
		car.req = nil
	end
end

local function request(car: Car, node: string, seg: Seg, t: number): Req
	local req = car.req
	if req and req.node == node then
		req.seg = seg
		return req
	end
	release(car)
	local made: Req = { node = node, seg = seg, t = t, granted = false, eligible = false }
	car.req = made
	local set = junctions[node]
	if not set then
		set = {}
		junctions[node] = set
	end
	set[car] = true
	return made
end

local function removeCar(car: Car, why: string?)
	if car.dead then
		return
	end
	car.dead = true
	release(car)
	byModel[car.model] = nil
	local i = table.find(cars, car)
	if i then
		table.remove(cars, i)
	end
	car.model:Destroy()
	if why ~= "wreck" then
		count("traffic_despawned")
	end
end

function TrafficService:Clear()
	for i = #cars, 1, -1 do
		removeCar(cars[i])
	end
	junctions = {}
end

local function placeCar(car: Car)
	local x, y, z, hx, hz = RoadNet.point(car.seg, car.s)
	local rx, rz = -hz, hx
	car.x = x + rx * car.lat
	car.y = y
	car.z = z + rz * car.lat
	car.hx, car.hz = hx, hz
	local pos = Vector3.new(car.x, car.y, car.z)
	local cf = CFrame.lookAt(pos, pos + Vector3.new(hx, 0, hz))
	if car.yaw ~= 0 then
		cf *= CFrame.Angles(0, car.yaw, 0)
	end
	car.pose = cf
end

local function spawnCar(laneId: number, s: number): Car?
	local n = net
	local f = folder
	if not n or not f then
		return nil
	end
	local kind = Driver.pickWeighted(Cfg.KindWeights, rng:NextNumber()) or "sedan"
	local seg = RoadNet.laneSeg(n, laneId)
	local x, y, z, hx, hz = RoadNet.point(seg, s)
	local pos = Vector3.new(x, y, z)
	local cf = CFrame.lookAt(pos, pos + Vector3.new(hx, 0, hz))
	local ok, model, info = pcall(CarBuilder.Build, kind, cf, rng)
	if not ok or not model then
		warn(`[TrafficService] build {kind} failed: {model}`)
		return nil
	end
	local m = model :: Model
	local car: Car = {
		model = m,
		root = m.PrimaryPart :: BasePart,
		kind = kind,
		halfLen = info.halfLen,
		speedMul = info.speedMul * (0.9 + rng:NextNumber() * 0.2),
		seg = seg,
		s = s,
		laneId = laneId,
		nextLane = RoadNet.pickNext(n, laneId, rng:NextNumber(), Cfg.StraightBias),
		cleared = false,
		req = nil,
		waitT = 0,
		rerouteT = 0,
		why = "",
		excused = false,
		leader = nil,
		passing = false,
		passT = 0,
		passX = 0,
		passZ = 0,
		passHalf = 0,
		queued = false,
		ghostT = 0,
		immuneT = 0,
		v = seg.lane and (seg.lane :: any).speed * 0.5 or 10,
		lat = 0,
		latTarget = 0,
		yaw = 0,
		state = "Drive",
		stateT = 0,
		clearT = 0,
		stuck = 0,
		lastHonk = 0,
		seed = rng:NextInteger(1, 1000),
		x = x,
		y = y,
		z = z,
		hx = hx,
		hz = hz,
		pose = cf,
		blink = "",
		brake = false,
		pubPose = nil,
		pubV = -1,
		pubState = "",
		pubBlink = "",
		pubBrake = false,
		dead = false,
	}
	m:SetAttribute("Pose", cf)
	m:SetAttribute("Speed", car.v)
	m:SetAttribute("State", "Drive")
	m:SetAttribute("Blink", "")
	m:SetAttribute("Brake", false)
	m:AddTag(CAR_TAG)
	m.Parent = f
	byModel[m] = car
	table.insert(cars, car)
	count("traffic_spawned")
	return car
end

-- World snapshot per step -----------------------------------------------------------------------------

local function gatherTrucks(): { Truck }
	local out: { Truck } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.Truck) do
		if not inst:IsA("Model") or not inst:IsDescendantOf(workspace) then
			continue
		end
		local m = inst :: Model
		local root = m.PrimaryPart
		if not root then
			continue
		end
		local siren = sirenOverride[m]
		if siren == nil then
			siren = m:GetAttribute("SirenOn") == true
		end
		local vel = root.AssemblyLinearVelocity
		local driver = m:GetAttribute("Driver")
		local driven = type(driver) == "number" and driver ~= 0
		table.insert(out, { model = m, pos = root.Position, vel = vel, cf = root.CFrame, speed = vel.Magnitude, siren = siren :: boolean, driven = driven })
	end
	return out
end

type Ped = { player: Player, pos: Vector3 }

local function gatherPeople(): ({ Ped }, { Vector3 })
	local peds: { Ped } = {}
	local all: { Vector3 } = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not root then
			continue
		end
		table.insert(all, root.Position)
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum and not hum.SeatPart and hum.Health > 0 then
			table.insert(peds, { player = p, pos = root.Position })
		end
	end
	return peds, all
end

-- Wrecks --------------------------------------------------------------------------------------------------

local function driverOf(truck: Model): Player?
	local V = services.VehicleService
	if V and type(V.GetDriver) == "function" then
		local ok, p = pcall(V.GetDriver, V, truck)
		if ok and typeof(p) == "Instance" and (p :: Instance):IsA("Player") then
			return p :: Player
		end
	end
	local uid = truck:GetAttribute("Driver") or truck:GetAttribute("OwnerUserId")
	if type(uid) == "number" and uid > 0 then
		return Players:GetPlayerByUserId(uid)
	end
	return nil
end

local function yell(parent: BasePart, text: string)
	Popup.show(parent, text, "info") -- small world text for players nearby (ClientLib/WorldPopup)
end

local function popDriver(car: Car, at: CFrame, push: Vector3)
	local f = folder
	if not f then
		return
	end
	for _, d in car.model:GetDescendants() do
		if d:IsA("BasePart") and string.sub(d.Name, 1, 6) == "Driver" then
			d.Transparency = 1
		end
	end
	local npc: Model? = nil
	pcall(function()
		local rescue = ServerScriptService:FindFirstChild("Lib")
		rescue = rescue and rescue:FindFirstChild("Rescue")
		local nb = rescue and rescue:FindFirstChild("NpcBuilder")
		if nb then
			local NpcBuilder = require(nb :: ModuleScript) :: any
			npc = NpcBuilder.Build("Civilian", at, { pose = "panicking" })
		end
	end)
	local root: BasePart
	if npc and npc.PrimaryPart then
		local m = npc :: Model
		root = m.PrimaryPart :: BasePart
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") then
				d:SetAttribute("RescueId", nil)
				for _, tag in d:GetTags() do
					d:RemoveTag(tag)
				end
				if d ~= root then
					d.Anchored = false
					d.Massless = true
					d.CanCollide = false
					d.CanQuery = false
					local w = Instance.new("WeldConstraint")
					w.Part0 = root
					w.Part1 = d
					w.Parent = d
				end
			end
		end
		for _, tag in m:GetTags() do
			m:RemoveTag(tag)
		end
		m.Name = "PoppedDriver"
		m.Parent = f
	else
		local p = Instance.new("Part")
		p.Name = "PoppedDriver"
		p.Shape = Enum.PartType.Ball
		p.Size = Vector3.new(2, 2, 2)
		p.Color = Color3.fromHex("#F0C49C")
		p.CFrame = at * CFrame.new(0, 2, 0)
		p.Parent = f
		root = p
	end
	root.Anchored = false
	root.CanCollide = true
	root.CanQuery = false
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	root.AssemblyLinearVelocity = push
	root.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))
	local lines = Cfg.Yells :: { string }
	yell(root, lines[rng:NextInteger(1, #lines)])
	local inst: Instance = if npc then npc :: Model else root
	task.delay(Cfg.DriverSeconds, function()
		if inst.Parent then
			inst:Destroy()
		end
	end)
end

local function wreck(car: Car, truck: Truck)
	if car.state == "Wrecked" or car.dead then
		return
	end
	car.state = "Wrecked"
	release(car)
	local m, root = car.model, car.root
	m:SetAttribute("State", "Wrecked")
	m:SetAttribute("Pose", car.pose)
	local rootY = (m:GetAttribute("RootY") :: number?) or 3
	root.CFrame = car.pose * CFrame.new(0, rootY, 0)
	root.Anchored = false
	root.CanCollide = true
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	local tv = truck.vel
	local side = truck.cf.RightVector * rng:NextNumber(-18, 18)
	local vel = tv * Cfg.FlingCarry + Vector3.new(0, Cfg.FlingUp, 0) + side
	local applied = false
	local P = services.PhysicsFxService
	if P and type(P.Impulse) == "function" then
		local ok, res = pcall(P.Impulse, P, root, vel - root.AssemblyLinearVelocity)
		applied = ok and res == true
	end
	if not applied then
		root.AssemblyLinearVelocity = vel
	end
	local spin = Cfg.FlingSpin
	root.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-spin, spin), rng:NextNumber(-spin, spin), rng:NextNumber(-spin, spin))
	if P and type(P.Pop) == "function" then
		pcall(P.Pop, P, "crash", root.Position + Vector3.new(0, 6, 0), if rng:NextNumber() < 0.5 then "CRASH!" else "YEET!")
	end
	popDriver(car, car.pose * CFrame.new(-4, 1, 0), (tv * 0.4) + Vector3.new(rng:NextNumber(-20, 20), Cfg.DriverPopUp, rng:NextNumber(-20, 20)))
	count("traffic_rammed")
	local who = driverOf(truck.model)
	TrafficService.Rammed:Fire(who, m, car.kind)
	local now = os.clock()
	if who and now - lastToast > Cfg.RamToastCooldown then
		lastToast = now
		local what = if car.kind == "icecream" then "the ice-cream truck" elseif car.kind == "bus" then "a whole BUS" else `a {car.kind}`
		Popup.show(who, `Rammed {what}! Insurance is crying.`, "blame", who)
	end
	task.delay(Cfg.WreckSeconds, function()
		removeCar(car, "wreck")
	end)
end

-- Simulation --------------------------------------------------------------------------------------------

local function honk(car: Car, now: number)
	if now - car.lastHonk < Cfg.HonkCooldown then
		return
	end
	car.lastHonk = now
	count("traffic_honks")
	if HonkRemote then
		HonkRemote:FireAllClients(car.model)
	end
end

-- Who is where, rebuilt once per sim step: cars per segment, and cars on a connector by the lane
-- they came from (path-based leaders; exit-lane room).
local bySeg: { [Seg]: { Car } } = {}
local connFrom: { [number]: { Car } } = {}

local function indexCars()
	bySeg = {}
	connFrom = {}
	for _, c in cars do
		if c.state == "Wrecked" or c.dead then
			continue
		end
		local list = bySeg[c.seg]
		if not list then
			list = {}
			bySeg[c.seg] = list
		end
		table.insert(list, c)
		if c.seg.kind == "conn" then
			local f = c.seg.from :: number
			local l = connFrom[f]
			if not l then
				l = {}
				connFrom[f] = l
			end
			table.insert(l, c)
		end
	end
end

local function connSpeed(car: Car, seg: Seg): number
	local n = net :: RoadNet.Net
	local a, b = n.lanes[seg.from :: number], n.lanes[seg.to :: number]
	return Driver.turnSpeed(seg.radius or math.huge, math.min(a.speed, b.speed) * car.speedMul, Cfg)
end

local function segLimit(car: Car): number
	local seg = car.seg
	if seg.kind == "lane" then
		return (seg.lane :: any).speed * car.speedMul
	end
	return connSpeed(car, seg)
end

-- Nearest car ahead along my PATH (this segment, the junction connector, the exit lane), not just
-- whatever happens to be in front geometrically: crossing traffic never blocks the queue behind it.
local function pathLeader(car: Car, look: number): (number, Car?)
	local n = net :: RoadNet.Net
	local best, who = math.huge, nil
	local function consider(o: Car, along: number)
		if o == car or o.dead or o.state == "Wrecked" or along > look then
			return
		end
		local gap = along - car.halfLen - o.halfLen
		if gap >= best then
			return
		end
		if car.passing or o.passing or math.abs(o.lat - car.lat) > 3 then
			-- someone is out of lane (passing / pulled over): only block if actually in front of me
			local _, right = Driver.relative(car.x, car.z, car.hx, car.hz, o.x, o.z)
			if math.abs(right) > 4.5 then
				return
			end
		end
		best, who = gap, o
	end
	local seg = car.seg
	for _, o in bySeg[seg] or {} do
		if o.s > car.s then
			consider(o, o.s - car.s)
		end
	end
	local rem = seg.len - car.s
	if rem < look then
		if seg.kind == "lane" then
			for _, o in connFrom[car.laneId] or {} do
				-- cars that just left my lane into the junction are still in front of me
				if o.seg.to == car.nextLane or o.s < o.halfLen * 2 + 2 then
					consider(o, rem + o.s)
				end
			end
			local nl = car.nextLane
			if nl then
				local conn = RoadNet.connector(n, car.laneId, nl)
				for _, o in bySeg[RoadNet.laneSeg(n, nl)] or {} do
					consider(o, rem + conn.len + o.s)
				end
			end
		else
			for _, o in bySeg[RoadNet.laneSeg(n, seg.to :: number)] or {} do
				consider(o, rem + o.s)
			end
		end
	end
	return best, who
end

-- Right-of-way at the junction ahead (Lib/Traffic/Junction). Returns a speed cap and sets car.why
-- when the junction is what holds the car.
local function junctionCap(car: Car, now: number): number
	local n = net :: RoadNet.Net
	local lane = car.seg.lane :: RoadNet.Lane
	local nl = car.nextLane
	if car.cleared or not nl then
		return math.huge
	end
	local node = lane.to
	if not n.junction[node] or car.ghostT > 0 then
		car.cleared = true -- bends and straight-throughs: nothing to arbitrate
		return math.huge
	end
	local distLine = car.seg.len - car.s - car.halfLen -- front bumper to the stop line
	if distLine > car.v * car.v / (2 * Cfg.Brake * 0.8) + 14 then
		return math.huge
	end
	local conn = RoadNet.connector(n, car.laneId, nl)
	local headStart = if lane.major and not signalled[node] then Cfg.MajorHeadStart else 0
	local req = request(car, node, conn, now - headStart)
	local stopCap = Driver.stopSpeed(distLine - 0.3, Cfg.Brake * 0.8)
	local light = lightState(lane)
	if light and Driver.mustStopForLight(light, distLine, car.v, Cfg.Brake) then
		req.eligible = false
		car.why = "red"
		return stopCap
	end
	-- don't block the box: only go when the exit lane has room for me
	local exitSeg = RoadNet.laneSeg(n, nl)
	local rears: { number } = {}
	for _, o in bySeg[exitSeg] or {} do
		table.insert(rears, o.s - o.halfLen)
	end
	local room = Junction.room(exitSeg.len, rears, car.halfLen * 2 + Cfg.MinGap)
	local ready = distLine <= math.max(Cfg.GrantDist, car.v * Cfg.GrantTime)
	req.eligible = room and ready
	if not ready then
		return stopCap
	end
	local force = car.waitT >= Cfg.ForceAfter
	local ok = force
	if not ok and room then
		local active: { any } = {}
		local waiting: { Junction.Request } = {}
		for o in junctions[node] or {} do
			local r = o.req
			if o ~= car and r and not o.dead then
				if r.granted then
					table.insert(active, r.seg)
				elseif r.eligible then
					table.insert(waiting, r)
				end
			end
		end
		ok = Junction.mayEnter(req, active, waiting, Cfg.Clearance)
	end
	if ok then
		req.granted = true
		car.cleared = true
		car.waitT = 0
		if force then
			stats.forced += 1
			count("traffic_forced")
		end
		return math.huge
	end
	car.why = "junction"
	return stopCap
end

-- Waiting at a free line too long: try another exit (the first one may be jammed).
local function reroute(car: Car, now: number)
	local n = net :: RoadNet.Net
	if now - car.rerouteT < Cfg.RerouteAfter then
		return
	end
	car.rerouteT = now
	local opts = RoadNet.nextLanes(n, car.laneId)
	local alts: { number } = {}
	for _, lid in opts do
		if lid ~= car.nextLane then
			table.insert(alts, lid)
		end
	end
	if #alts > 0 then
		car.nextLane = alts[rng:NextInteger(1, #alts)]
		stats.rerouted += 1
		count("traffic_rerouted")
	end
end

local function advance(car: Car): boolean
	local n = net :: RoadNet.Net
	while car.s >= car.seg.len do
		local seg = car.seg
		if seg.kind == "lane" then
			local nxt = car.nextLane
			if not nxt then
				return false -- nowhere to go: recycle
			end
			if not car.cleared then
				car.s = seg.len
				car.v = 0
				return true
			end
			car.s -= seg.len
			car.seg = RoadNet.connector(n, car.laneId, nxt)
		else
			local lid = seg.to :: number
			car.s -= seg.len
			car.laneId = lid
			car.seg = RoadNet.laneSeg(n, lid)
			car.nextLane = RoadNet.pickNext(n, lid, rng:NextNumber(), Cfg.StraightBias)
			car.cleared = false
			car.waitT = 0
		end
	end
	return true
end

-- Start driving round whatever blocks my lane at (ox, oz), if the corridor to my left is clear.
local function tryPass(car: Car, ox: number, oz: number, ohalf: number): boolean
	if car.passing or car.seg.kind ~= "lane" or car.seg.len - car.s < 45 then
		return false
	end
	for _, o in cars do
		if o ~= car and not o.dead and o.state ~= "Wrecked" then
			local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, o.x, o.z)
			local same = car.hx * o.hx + car.hz * o.hz > 0.3
			if not Driver.passClear(fwd, right, same, Cfg) then
				return false
			end
		end
	end
	car.passing = true
	car.passT = 0
	car.passX, car.passZ = ox, oz
	car.passHalf = ohalf
	car.latTarget = -Cfg.PassOffset
	stats.passed += 1
	count("traffic_passes")
	return true
end

local function stepCar(car: Car, dt: number, trucks: { Truck }, peds: { Ped }, now: number): boolean
	local n = net :: RoadNet.Net
	car.why = ""
	car.ghostT = math.max(0, car.ghostT - dt)
	car.immuneT = math.max(0, car.immuneT - dt)
	-- 0. release the junction once my tail is out of it ---------------------------------------
	local req = car.req
	if req and req.granted and car.seg.kind == "lane" then
		local onExit = car.laneId == req.seg.to
		if (onExit and car.s > car.halfLen + 1) or (not onExit and car.laneId ~= req.seg.from) then
			release(car)
		end
	end

	-- 1. emergency yield (moving siren trucks only) ----------------------------------------------
	local needYield = false
	local mustHold = false
	local cvx, cvz = car.hx * car.v, car.hz * car.v
	for _, t in trucks do
		if not t.siren or car.immuneT > 0 then
			continue
		end
		local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, t.pos.X, t.pos.Z)
		-- a parked siren truck is an obstacle; a DRIVEN one crawling right behind me (stuck behind me at a
		-- line, a kid easing up) still gets the lane: pull over (no truck sits behind a car on a call)
		if t.speed < Cfg.YieldMinSpeed and not (t.driven and Driver.slowBehind(fwd, right, Cfg)) then
			continue
		end
		local dx, dz = car.x - t.pos.X, car.z - t.pos.Z
		local d = math.max(math.sqrt(dx * dx + dz * dz), 0.01)
		local closing = ((t.vel.X - cvx) * dx + (t.vel.Z - cvz) * dz) / d
		if Driver.shouldYield(fwd, right, closing, true, Cfg) then
			needYield = true
		end
		if not Driver.truckPassed(fwd, right, Cfg) then
			mustHold = true
		end
	end
	car.stateT += dt
	if car.state == "Drive" then
		if needYield then
			car.stateT = 0
			car.clearT = 0
			car.passing = false
			if rng:NextNumber() < Cfg.PanicChance then
				car.state = "Panic"
				count("traffic_panics")
			else
				car.state = "Yield"
				count("traffic_yields")
			end
			car.latTarget = Cfg.PullOverOffset
		end
	elseif car.state == "Yield" or car.state == "Panic" then
		if car.stateT > Cfg.YieldMax then
			-- the truck is parked / circling: stop waiting for it
			car.state = "Drive"
			car.latTarget = 0
			car.stateT = 0
			car.immuneT = Cfg.YieldImmune
		elseif needYield or mustHold then
			car.clearT = 0
		else
			car.clearT += dt
			if car.clearT >= Cfg.ResumeDelay then
				car.state = "Drive"
				car.latTarget = 0
				car.stateT = 0
			end
		end
	end

	-- 2. target speed ----------------------------------------------------------------------------
	local limit = segLimit(car)
	local target = limit
	local brake = Cfg.Brake
	local look = math.max(Cfg.LookAhead, car.v * car.v / (2 * Cfg.Brake) + 20)
	local why = ""
	-- cars on my path
	local leaderGap, leader = math.huge, nil
	if car.ghostT <= 0 then
		leaderGap, leader = pathLeader(car, look)
		-- cars out of their lane (passing towards me, pulled over) that sit right in front of me
		for _, o in cars do
			if o ~= car and o.passing and not o.dead and o.state ~= "Wrecked" then
				local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, o.x, o.z)
				if fwd > 0 and fwd < look and math.abs(right) < 4.5 then
					local g = fwd - car.halfLen - o.halfLen
					if g < leaderGap then
						leaderGap, leader = g, o
					end
				end
			end
		end
	end
	car.leader = leader
	if leaderGap < math.huge then
		local cap = Driver.followSpeed(leaderGap, limit, Cfg)
		if cap < target then
			target = cap
			why = "leader"
		end
	end
	-- people and fire trucks in my lane (geometric: they are not on the road graph)
	local obsGap, ox, oz, ohalf = math.huge, 0, 0, 0
	local blockedByPed = false
	if car.ghostT <= 0 then
		for _, p in peds do
			if math.abs(p.pos.Y - car.y) > 10 then
				continue
			end
			local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, p.pos.X, p.pos.Z)
			local g = Driver.pedGap(fwd, right, car.halfLen, Cfg)
			if g then
				if g < obsGap then
					obsGap, ox, oz, ohalf = g, p.pos.X, p.pos.Z, 1.5
				end
				if g < Cfg.HonkDistance and car.state == "Drive" then
					blockedByPed = true
				end
			end
		end
		for _, t in trucks do
			local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, t.pos.X, t.pos.Z)
			if fwd > 0 and fwd < look + Cfg.TruckFront and math.abs(right) < Cfg.TruckHalfWidth + 2.5 then
				local g = fwd - car.halfLen - Cfg.TruckFront
				if g < obsGap then
					obsGap, ox, oz, ohalf = g, t.pos.X, t.pos.Z, Cfg.TruckFront
				end
				if g < Cfg.HonkDistance and t.speed < 3 and car.state == "Drive" then
					blockedByPed = true -- parked truck in my lane: HONK
				end
			end
		end
	end
	if obsGap < math.huge then
		local cap = Driver.followSpeed(obsGap, limit, Cfg)
		if cap < target then
			target = cap
			why = "obstacle"
		end
	end
	if blockedByPed and car.v < 3 then
		honk(car, now)
	end
	if car.seg.kind == "lane" and car.state == "Drive" then
		car.why = ""
		local cap = junctionCap(car, now)
		if cap < target then
			target = cap
			why = car.why
		end
		if car.cleared and car.nextLane then
			-- slow down to the speed of the turn before reaching it
			local conn = RoadNet.connector(n, car.laneId, car.nextLane :: number)
			target = math.min(target, Driver.entrySpeed(car.seg.len - car.s, connSpeed(car, conn), Cfg.Brake * 0.6))
		end
	end
	if car.state == "Yield" then
		target = 0
		brake = Cfg.YieldBrake
		why = "yield"
	elseif car.state == "Panic" then
		target = 0
		brake = if car.stateT < Cfg.PanicSeconds then 14 else Cfg.YieldBrake
		why = "yield"
	end
	if car.passing and (why == "obstacle" or why == "leader") and leaderGap > 1.5 and obsGap > 1.5 then
		target = math.max(target, 4) -- creep while steering round it
	end
	car.why = why

	-- 3. integrate ---------------------------------------------------------------------------------
	local v0 = car.v
	car.v = Driver.approach(car.v, target, Cfg.Accel, brake, dt)
	car.s += car.v * dt
	if not advance(car) then
		return false
	end
	local lat0 = car.lat
	if car.state == "Panic" and car.stateT < Cfg.PanicSeconds then
		local wl, wy = Driver.panicWobble(car.stateT, car.seed)
		car.lat = Cfg.PullOverOffset * math.min(1, car.stateT / Cfg.PanicSeconds) + wl
		car.yaw = wy
	else
		local step = (if car.passing or math.abs(car.lat) > Cfg.PullOverOffset + 0.5 then Cfg.PassLateralSpeed else Cfg.LateralSpeed) * dt
		car.lat += math.clamp(car.latTarget - car.lat, -step, step)
		if car.state == "Drive" then
			-- lean into lane changes, settle otherwise
			local want = math.clamp(-(car.lat - lat0) / dt / math.max(car.v, 6) * 0.6, -0.35, 0.35)
			car.yaw += (want - car.yaw) * math.min(1, dt * 6)
			if math.abs(car.yaw) < 0.005 then
				car.yaw = 0
			end
		end
	end
	placeCar(car)

	-- 4. passing bookkeeping ---------------------------------------------------------------------------
	if car.passing then
		car.passT += dt
		local fwd = Driver.relative(car.x, car.z, car.hx, car.hz, car.passX, car.passZ)
		local nearEnd = car.seg.kind ~= "lane" or car.seg.len - car.s < 25
		if fwd < -(car.halfLen + car.passHalf + 6) or car.passT > Cfg.PassMaxSeconds or nearEnd then
			car.passing = false
			car.latTarget = 0
		end
	end

	-- 5. stuck bookkeeping + unsticking ------------------------------------------------------------------
	local ld = car.leader
	local queued = why == "leader" and ld ~= nil and (ld.excused or ld.queued or ld.why == "junction")
	car.excused = why == "red" or why == "yield" or car.state ~= "Drive" or (queued and ld ~= nil and ld.excused)
	car.queued = queued
	if car.v < 0.5 and not car.excused and not car.queued then
		car.stuck += dt
	else
		car.stuck = 0
	end
	if why == "junction" and car.v < 0.5 then
		car.waitT += dt
	end
	if car.state == "Drive" then
		local stalledLeader = why == "leader" and ld ~= nil and not queued and not ld.excused
		local action = Junction.unstick(if stalledLeader then "leader" elseif why == "leader" then "queue" else why, car.waitT, car.stuck, Cfg)
		if action == "reroute" then
			reroute(car, now)
		elseif action == "pass" then
			if why == "obstacle" then
				tryPass(car, ox, oz, ohalf)
			elseif ld then
				tryPass(car, ld.x, ld.z, ld.halfLen)
			end
		elseif action == "ghost" then
			car.ghostT = Cfg.GhostSeconds
			car.stuck = 0
			car.cleared = true
			release(car)
			stats.ghosted += 1
			count("traffic_ghosted")
		end
	end
	stats.stuckMax = math.max(stats.stuckMax, car.stuck)

	-- 6. indicators + brake lights -------------------------------------------------------------------------
	local blink = ""
	if car.state == "Yield" and car.lat < car.latTarget - 0.5 then
		blink = "R"
	elseif car.passing and car.lat > car.latTarget + 0.5 then
		blink = "L"
	elseif not car.passing and car.lat < -1 then
		blink = "R"
	elseif car.seg.kind == "conn" then
		if n.junction[car.seg.node :: string] then
			blink = Junction.blink(car.seg.turn)
		end
	elseif car.nextLane and n.junction[(car.seg.lane :: RoadNet.Lane).to] and car.seg.len - car.s < Cfg.BlinkDistance then
		blink = Junction.blink(RoadNet.turn(car.seg.lane :: RoadNet.Lane, n.lanes[car.nextLane :: number]))
	end
	car.blink = blink
	car.brake = car.v < 0.3 or car.v < v0 - 0.2
	return true
end

local function publish()
	for _, car in cars do
		if car.state == "Wrecked" then
			continue
		end
		local m = car.model
		local moved = car.pubPose == nil or ((car.pubPose :: CFrame).Position - car.pose.Position).Magnitude > 0.03
			or math.abs((car.pubPose :: CFrame).LookVector:Dot(car.pose.LookVector) - 1) > 1e-5
		if moved then
			m:SetAttribute("Pose", car.pose)
			car.pubPose = car.pose
		end
		local v = math.floor(car.v * 10 + 0.5) / 10
		if v ~= car.pubV then
			m:SetAttribute("Speed", v)
			car.pubV = v
		end
		if car.state ~= car.pubState then
			m:SetAttribute("State", car.state)
			car.pubState = car.state
		end
		if car.blink ~= car.pubBlink then
			m:SetAttribute("Blink", car.blink)
			car.pubBlink = car.blink
		end
		if car.brake ~= car.pubBrake then
			m:SetAttribute("Brake", car.brake)
			car.pubBrake = car.brake
		end
	end
end

local function nearestDist(x: number, z: number, people: { Vector3 }): number
	local best = math.huge
	for _, p in people do
		local d = (p.X - x) ^ 2 + (p.Z - z) ^ 2
		if d < best then
			best = d
		end
	end
	return math.sqrt(best)
end

local function populate(people: { Vector3 }, budget: number)
	local n = net
	if not n or not Cfg.Enabled then
		return
	end
	-- despawn far cars, and recycle truly stuck ones nobody can see
	for i = #cars, 1, -1 do
		local car = cars[i]
		if car.state == "Wrecked" then
			continue
		end
		local d = nearestDist(car.x, car.z, people)
		if d > Cfg.DespawnRadius then
			removeCar(car)
		elseif car.stuck > Cfg.StuckDespawn and d > Cfg.UnseenRadius then
			stats.recycled += 1
			count("traffic_recycled")
			removeCar(car)
		end
	end
	if #people == 0 then
		return
	end
	local want = math.min(Cfg.MaxCars, Cfg.CarsPerPlayer * #people)
	local made = 0
	local attempts = 0
	while #cars < want and made < budget and attempts < 24 do
		attempts += 1
		local lid = rng:NextInteger(1, #n.lanes)
		local lane = n.lanes[lid]
		if n.deadEnd[lane.from] or n.deadEnd[lane.to] or lane.len < 40 then
			continue
		end
		local s = 10 + rng:NextNumber() * (lane.len - 32)
		local x, _, z = RoadNet.point(RoadNet.laneSeg(n, lid), s)
		local d = nearestDist(x, z, people)
		if d < Cfg.SpawnMin or d > Cfg.SpawnMax then
			continue
		end
		local clear = true
		for _, o in cars do
			if (o.x - x) ^ 2 + (o.z - z) ^ 2 < Cfg.SpawnClear * Cfg.SpawnClear then
				clear = false
				break
			end
		end
		if clear and spawnCar(lid, s) then
			made += 1
		end
	end
end

local function loadGraph(data: any, key: string): boolean
	local n = RoadNet.parse(data, Cfg)
	if not n then
		return false
	end
	TrafficService:Clear()
	net = n
	graphKey = key
	snapLanes(n)
	scanLights()
	count("traffic_graph_loaded")
	local sig, junc = 0, 0
	for _ in signalled do
		sig += 1
	end
	for _, j in n.junction do
		if j then
			junc += 1
		end
	end
	print(`[TrafficService] road graph: {n.edgeCount} edges, {#n.lanes} lanes, {junc} junctions ({sig} with lights)`)
	return true
end

-- Lifecycle ---------------------------------------------------------------------------------------------

function TrafficService:Init(all: { [string]: any })
	services = all
end

function TrafficService:Start()
	HonkRemote = Net.event("Traffic", "Honk")
	local f = workspace:FindFirstChild("Traffic")
	if not f then
		local made = Instance.new("Folder")
		made.Name = "Traffic"
		made.Parent = workspace
		f = made
	end
	folder = f :: Folder

	local V = services.VehicleService
	if V and type(V.SirenChanged) == "table" and type(V.SirenChanged.Connect) == "function" then
		V.SirenChanged:Connect(function(truck: Model, on: boolean)
			if typeof(truck) == "Instance" then
				sirenOverride[truck] = on == true
				truck.Destroying:Once(function()
					sirenOverride[truck] = nil
				end)
			end
		end)
	end

	-- step loop: fixed-rate kinematic sim
	local acc, pubAcc, popAcc = 0, 0, 0
	RunService.Heartbeat:Connect(function(dt: number)
		if not net or not Cfg.Enabled then
			return
		end
		local step = 1 / Cfg.SimHz
		acc = math.min(acc + dt, step * 3)
		pubAcc += dt
		popAcc += dt
		if acc < step then
			return
		end
		local trucks = gatherTrucks()
		local peds, people = gatherPeople()
		local now = os.clock()
		local city = cityFolder()
		local ph = city and city:GetAttribute("TrafficPhase")
		phase = if type(ph) == "string" then ph else nil
		while acc >= step do
			acc -= step
			indexCars()
			for i = #cars, 1, -1 do
				local car = cars[i]
				if car and car.state ~= "Wrecked" and not car.dead then
					local ok, alive = pcall(stepCar, car, step, trucks, peds, now)
					if not ok then
						warn(`[TrafficService] car step: {alive}`)
						removeCar(car)
					elseif not alive then
						removeCar(car)
					end
				end
			end
		end
		-- rams: fast trucks fling cars in front of them
		for _, t in trucks do
			if t.speed < Cfg.RamSpeed then
				continue
			end
			for i = #cars, 1, -1 do
				local car = cars[i]
				if car.state == "Wrecked" then
					continue
				end
				if (car.x - t.pos.X) ^ 2 + (car.z - t.pos.Z) ^ 2 > 60 * 60 then
					continue
				end
				local rel = t.cf:PointToObjectSpace(Vector3.new(car.x, car.y + 2, car.z))
				if math.abs(rel.Y) < 10 and Driver.rammed(rel.X, rel.Z, t.speed, Cfg) then
					wreck(car, t)
				end
			end
		end
		if pubAcc >= 1 / Cfg.PublishHz then
			pubAcc = 0
			publish()
		end
		if popAcc >= 0.5 then
			popAcc = 0
			populate(people, math.max(1, math.floor(Cfg.SpawnPerSecond * 0.5 + 0.5)))
		end
	end)

	-- graph loader: wait for the city, then keep an eye on it (CityBuilder may rebuild)
	task.spawn(function()
		local t0 = os.clock()
		while workspace:GetAttribute(Names.Attr.MapReady) ~= true and os.clock() - t0 < 30 do
			task.wait(0.5)
		end
		local warned = false
		local since = os.clock()
		while true do
			if Cfg.Enabled then
				local data, key = readGraph(graphKey)
				if data and key ~= graphKey then
					if not loadGraph(data, key) then
						graphKey = key -- don't decode the same bad graph again
						if not warned then
							warned = true
							warn("[TrafficService] road graph found but has no drivable lanes: no traffic")
						end
					end
				elseif not data and not net and not warned and os.clock() - since > Cfg.GraphWaitSeconds then
					warned = true
					print("[TrafficService] no road graph (Workspace.Map.City.RoadGraphJson): no traffic")
				end
			end
			task.wait(if net then 5 else 2)
		end
	end)
	-- lights may be built after the graph: rescan a couple of times
	task.spawn(function()
		for _ = 1, 3 do
			task.wait(15)
			if net then
				scanLights()
			end
		end
	end)
end

-- API ---------------------------------------------------------------------------------------------------

function TrafficService:GetCars(): { Model }
	local out: { Model } = {}
	for _, c in cars do
		table.insert(out, c.model)
	end
	return out
end

function TrafficService:GetStats(): { [string]: number }
	local yielding, wrecked, stopped, stuck, lit = 0, 0, 0, 0, 0
	for _, c in cars do
		if c.state == "Yield" or c.state == "Panic" then
			yielding += 1
		elseif c.state == "Wrecked" then
			wrecked += 1
		end
		if c.v < 0.5 then
			stopped += 1
		end
		if c.stuck > 6 then
			stuck += 1
		end
	end
	for _ in signalled do
		lit += 1
	end
	return {
		cars = #cars,
		yielding = yielding,
		wrecked = wrecked,
		stopped = stopped,
		stuck = stuck,
		lanes = if net then #(net :: RoadNet.Net).lanes else 0,
		signalled = lit,
		stuckMax = stats.stuckMax,
		forced = stats.forced,
		rerouted = stats.rerouted,
		ghosted = stats.ghosted,
		passed = stats.passed,
		recycled = stats.recycled,
	}
end

-- Why every stopped car is stopped (DevHook diagnostics).
function TrafficService._why(): { string }
	local out: { string } = {}
	for _, c in cars do
		if c.v < 0.5 and c.state ~= "Wrecked" then
			local node = if c.seg.kind == "lane" then (c.seg.lane :: any).to else c.seg.node
			table.insert(out, `{c.kind} @{math.floor(c.x)},{math.floor(c.z)} {c.seg.kind}->{node} why={c.why} stuck={math.floor(c.stuck * 10) / 10} wait={math.floor(c.waitT * 10) / 10} q={c.queued} ex={c.excused} req={if c.req then (if c.req.granted then "G" else "W") else "-"}`)
		end
	end
	return out
end

function TrafficService._loadGraph(json: string): boolean
	local ok, data = pcall(function()
		return HttpService:JSONDecode(json)
	end)
	return ok and loadGraph(data, `hook:{#json}`)
end

function TrafficService._spawnNear(player: Player, n: number?): number
	local nn = net
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not nn or not root then
		return 0
	end
	local made = 0
	local lanes = {}
	for i, lane in nn.lanes do
		table.insert(lanes, { i = i, d = RoadNet.laneDist2(lane, root.Position.X, root.Position.Z) })
	end
	table.sort(lanes, function(a, b)
		return a.d < b.d
	end)
	for k = 1, math.min(n or 3, #lanes) do
		if spawnCar(lanes[k].i, (nn.lanes[lanes[k].i]).len * 0.2) then
			made += 1
		end
	end
	return made
end

function TrafficService._selftest(): (boolean, string)
	if not folder then
		return false, "not started"
	end
	if not net then
		return true, "no road graph yet (no traffic)"
	end
	local s = TrafficService:GetStats()
	return true, `{s.cars} cars on {s.lanes} lanes ({s.signalled} signalled junctions), {s.yielding} yielding, {s.stuck} stuck`
end

return TrafficService
