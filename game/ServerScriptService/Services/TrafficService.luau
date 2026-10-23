--!strict
-- TrafficService [owner: Traffic]. Cartoon city traffic (docs/game/08 "City").
--
-- Cars follow lane centrelines of CityBuilder's road graph, pick random turns at junctions, obey
-- traffic lights (any Instance under Workspace.Map.City with attribute LightState, or tagged
-- "TrafficLight") and otherwise stop-sign rules, keep their distance, honk at people in the road,
-- and PULL OVER for fire trucks with the siren on (a few panic-swerve). A truck that rams a car at
-- speed sends it flying with real physics and the driver pops out yelling.
--
-- Simulation is KINEMATIC on the server (no physics until a car is hit), at TrafficConfig.SimHz.
-- The server never moves a car's parts while it drives: it publishes the pose as model attributes
-- (PublishHz) and every client interpolates the anchored Hitbox (TrafficController), so a car costs
-- one attribute update per publish, not 30 part CFrames. Cars spawn/despawn near players only.
-- No road graph (Workspace.Map.City.RoadGraphJson / RoadGraph folder) = no traffic, no errors.
--
-- Reads: Workspace.Map.City.RoadGraphJson (StringValue, JSON) or .RoadGraph (RoadNode parts attr NodeId,
--   RoadEdge ObjectValues with A/B), or CityBuilder.Graph; LightState attrs; tag Truck + attr SirenOn;
--   VehicleService.SirenChanged(truck, on) (nil-guarded), VehicleService:GetDriver / truck attr Driver.
-- Writes: Workspace.Traffic (Folder) / TrafficCar_<kind> Models (tag TrafficCar) with attributes
--   Pose: CFrame (ground point, facing travel), Speed: number, State: "Drive"|"Yield"|"Panic"|"Wrecked",
--   Kind, RootY, HalfLen (CarBuilder).
-- Remotes: Traffic/Honk (S->C all: car: Model)
-- Signals: Rammed(driver: Player?, car: Model, kind: string)
-- Calls (nil-guarded): PhysicsFxService:Impulse(part, vector) / :Pop(kind, pos, word)
-- API: TrafficService:GetCars(): {Model}, :GetStats(): {[string]: number}, :Clear()
-- Counters: traffic_graph_loaded, traffic_spawned, traffic_despawned, traffic_yields, traffic_panics,
--   traffic_honks, traffic_rammed
-- Test hooks (DevHook only): _selftest(), _loadGraph(json: string), _spawnNear(player, n?)
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
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("TrafficConfig") :: ModuleScript) :: any
local TrafficLib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Traffic")
local RoadNet = require(TrafficLib:WaitForChild("RoadNet") :: ModuleScript)
local Driver = require(TrafficLib:WaitForChild("Driver") :: ModuleScript)
local CarBuilder = require(TrafficLib:WaitForChild("CarBuilder") :: ModuleScript)

local TrafficService = {}
TrafficService.Priority = 130
TrafficService.Rammed = Signal.new() :: Signal.Signal<Player?, Model, string>

local CAR_TAG = "TrafficCar"
local LIGHT_TAG = "TrafficLight"

type Seg = RoadNet.Seg
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
	holding: string?,
	stopWaited: number,
	atSignal: boolean,
	v: number,
	lat: number,
	latTarget: number,
	yaw: number,
	state: string,
	stateT: number,
	clearT: number,
	stuck: number,
	lastHonk: number,
	seed: number,
	x: number,
	y: number,
	z: number,
	hx: number,
	hz: number,
	pose: CFrame,
	pubPose: CFrame?,
	pubV: number,
	pubState: string,
	dead: boolean,
}

type Truck = { model: Model, pos: Vector3, vel: Vector3, cf: CFrame, speed: number, siren: boolean }

local services: { [string]: any } = {}
local net: RoadNet.Net? = nil
local graphKey = ""
local folder: Folder? = nil
local cars: { Car } = {}
local byModel: { [Model]: Car } = {}
local lightFor: { [number]: Instance } = {}
local occupancy: { [string]: number } = {}
local sirenOverride: { [Model]: boolean } = {}
local rng = Random.new()
local lastToast = 0
local HonkRemote: RemoteEvent? = nil

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
	local function surface(x: number, y: number, z: number): number
		local hit = workspace:Raycast(Vector3.new(x, y + 5, z), Vector3.new(0, -16, 0), params)
		return if hit then hit.Position.Y else y
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

-- Match each incoming lane of a signalled junction to the light that controls it.
local function scanLights()
	local n = net
	if not n then
		return
	end
	local lights: { Instance } = {}
	for _, inst in CollectionService:GetTagged(LIGHT_TAG) do
		if inst:IsDescendantOf(workspace) then
			table.insert(lights, inst)
		end
	end
	if #lights == 0 then
		local city = cityFolder()
		if city then
			for i, d in city:GetDescendants() do
				if d:GetAttribute("LightState") ~= nil then
					table.insert(lights, d)
				end
				if i % 4000 == 0 then
					task.wait()
				end
			end
		end
	end
	lightFor = {}
	if #lights == 0 then
		return
	end
	local where: { { inst: Instance, pos: Vector3, look: Vector3, axis: string? } } = {}
	for _, l in lights do
		local p = posOf(l)
		if p then
			local ax = l:GetAttribute("Axis") or l:GetAttribute("Direction") or l:GetAttribute("Approach") or l:GetAttribute("Dir")
			table.insert(where, { inst = l, pos = p, look = lookOf(l), axis = if type(ax) == "string" then string.lower(ax) else nil })
		end
	end
	for _, lane in n.lanes do
		if (n.degree[lane.to] or 0) < 3 then
			continue
		end
		local node = n.nodes[lane.to]
		local laneAxis = if math.abs(lane.hx) > math.abs(lane.hz) then "x" else "z"
		local best: Instance? = nil
		local bestScore = math.huge
		for _, w in where do
			local dn = math.sqrt((w.pos.X - node.x) ^ 2 + (w.pos.Z - node.z) ^ 2)
			if dn > Cfg.LightMatchRadius then
				continue
			end
			local dEnd = math.sqrt((w.pos.X - lane.bx) ^ 2 + (w.pos.Z - lane.bz) ^ 2)
			local score: number
			if w.axis then
				local a = w.axis :: string
				local isX = string.find(a, "ew", 1, true) or a == "x" or string.find(a, "east", 1, true) or string.find(a, "west", 1, true)
				local isZ = string.find(a, "ns", 1, true) or a == "z" or string.find(a, "north", 1, true) or string.find(a, "south", 1, true)
				if (laneAxis == "x" and isZ and not isX) or (laneAxis == "z" and isX and not isZ) then
					continue
				end
				score = dEnd
			else
				-- a light faces the traffic it controls: its LookVector points against the lane heading
				local align = -(w.look.X * lane.hx + w.look.Z * lane.hz)
				score = (1 - align) * 40 + dEnd
			end
			if score < bestScore then
				bestScore = score
				best = w.inst
			end
		end
		if best then
			lightFor[lane.id] = best
		end
	end
end

-- Cars -------------------------------------------------------------------------------------------------

local function release(car: Car)
	local node = car.holding
	if node then
		occupancy[node] = math.max(0, (occupancy[node] or 1) - 1)
		car.holding = nil
	end
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
	occupancy = {}
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
		holding = nil,
		stopWaited = 0,
		atSignal = false,
		v = seg.lane and (seg.lane :: any).speed * 0.6 or 10,
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
		pubPose = nil,
		pubV = -1,
		pubState = "",
		dead = false,
	}
	m:SetAttribute("Pose", cf)
	m:SetAttribute("Speed", car.v)
	m:SetAttribute("State", "Drive")
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
		table.insert(out, { model = m, pos = root.Position, vel = vel, cf = root.CFrame, speed = vel.Magnitude, siren = siren :: boolean })
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
	local gui = Instance.new("BillboardGui")
	gui.Name = "Yell"
	gui.Size = UDim2.fromOffset(220, 60)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 220
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = Color3.fromHex("#FFF1D6")
	t.TextStrokeTransparency = 0
	t.TextStrokeColor3 = Color3.fromHex("#2A1410")
	t.Parent = gui
	gui.Parent = parent
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
		Net.notify("all", `{who.DisplayName} rammed {what}! Insurance is crying.`, "blame")
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

local function segLimit(car: Car): number
	local seg = car.seg
	if seg.kind == "lane" then
		return (seg.lane :: any).speed * car.speedMul
	end
	local n = net :: RoadNet.Net
	local a, b = n.lanes[seg.from :: number], n.lanes[seg.to :: number]
	local turn = RoadNet.turn(a, b)
	local base = math.min(a.speed, b.speed) * car.speedMul
	return if turn == "straight" then base else base * 0.55
end

-- Junction rule for a car on a lane approaching its end. Returns a speed cap.
local function junctionCap(car: Car, dist: number): number
	local n = net :: RoadNet.Net
	local lane = car.seg.lane :: RoadNet.Lane
	if car.cleared then
		return math.huge
	end
	local node = lane.to
	if (n.degree[node] or 0) < 3 then
		car.cleared = true
		return math.huge
	end
	local light = lightFor[lane.id]
	if light and light.Parent then
		local st = Driver.light(light:GetAttribute("LightState"))
		if Driver.mustStopForLight(st, dist, car.v, Cfg.Brake) then
			car.atSignal = true -- waiting at a red light is not being stuck
			return Driver.stopSpeed(dist - 0.5, Cfg.Brake * 0.8)
		end
		if dist < 8 then
			if (occupancy[node] or 0) < Cfg.LightCap then
				occupancy[node] = (occupancy[node] or 0) + 1
				car.holding = node
				car.cleared = true
				return math.huge
			end
			return Driver.stopSpeed(dist - 0.5, Cfg.Brake)
		end
		return math.huge
	end
	-- stop sign: come to a full stop at the line, wait, then go when the junction is free
	if dist < 2.5 and car.v < 1 then
		car.stopWaited += 1 / Cfg.SimHz
		if car.stopWaited >= Cfg.StopWait and (occupancy[node] or 0) < Cfg.StopSignCap then
			occupancy[node] = (occupancy[node] or 0) + 1
			car.holding = node
			car.cleared = true
			return math.huge
		end
		car.atSignal = true
	end
	return Driver.stopSpeed(dist - 0.5, Cfg.Brake * 0.8)
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
			release(car)
			local lid = seg.to :: number
			car.s -= seg.len
			car.laneId = lid
			car.seg = RoadNet.laneSeg(n, lid)
			car.nextLane = RoadNet.pickNext(n, lid, rng:NextNumber(), Cfg.StraightBias)
			car.cleared = false
			car.stopWaited = 0
		end
	end
	return true
end

local function stepCar(car: Car, dt: number, trucks: { Truck }, peds: { Ped }, now: number): boolean
	car.atSignal = false
	-- 1. emergency yield ------------------------------------------------------------------------
	local needYield = false
	local mustHold = false
	local cvx, cvz = car.hx * car.v, car.hz * car.v
	for _, t in trucks do
		if not t.siren then
			continue
		end
		local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, t.pos.X, t.pos.Z)
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
		if needYield or mustHold then
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
	local target = segLimit(car)
	local brake = Cfg.Brake
	local gap = math.huge
	for _, o in cars do
		if o == car or o.state == "Wrecked" then
			continue
		end
		local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, o.x, o.z)
		if fwd > Cfg.LookAhead + 15 then
			continue
		end
		local g = Driver.leaderGap(fwd, right, car.hx, car.hz, o.hx, o.hz, car.halfLen, o.halfLen, Cfg)
		if g and g < gap then
			gap = g
		end
	end
	local blockedByPed = false
	for _, p in peds do
		local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, p.pos.X, p.pos.Z)
		if math.abs(p.pos.Y - car.y) > 10 then
			continue
		end
		local g = Driver.pedGap(fwd, right, car.halfLen, Cfg)
		if g then
			if g < gap then
				gap = g
			end
			if g < Cfg.HonkDistance and car.state == "Drive" then
				blockedByPed = true
			end
		end
	end
	for _, t in trucks do
		local fwd, right = Driver.relative(car.x, car.z, car.hx, car.hz, t.pos.X, t.pos.Z)
		if fwd > 0 and fwd < Cfg.LookAhead + Cfg.TruckFront and math.abs(right) < Cfg.TruckHalfWidth + 2.5 then
			local g = fwd - car.halfLen - Cfg.TruckFront
			if g < gap then
				gap = g
			end
			if g < Cfg.HonkDistance and t.speed < 3 and car.state == "Drive" then
				blockedByPed = true -- parked truck in my lane: HONK
			end
		end
	end
	if gap < math.huge then
		target = math.min(target, Driver.followSpeed(gap, target, Cfg))
	end
	if blockedByPed then
		honk(car, now)
	end
	if car.seg.kind == "lane" and car.state == "Drive" then
		target = math.min(target, junctionCap(car, car.seg.len - car.s))
	end
	if car.state == "Yield" then
		target = 0
		brake = Cfg.YieldBrake
	elseif car.state == "Panic" then
		target = 0
		brake = if car.stateT < Cfg.PanicSeconds then 14 else Cfg.YieldBrake
	end

	-- 3. integrate ---------------------------------------------------------------------------------
	car.v = Driver.approach(car.v, target, Cfg.Accel, brake, dt)
	car.s += car.v * dt
	if not advance(car) then
		return false
	end
	if car.state == "Panic" and car.stateT < Cfg.PanicSeconds then
		local wl, wy = Driver.panicWobble(car.stateT, car.seed)
		car.lat = Cfg.PullOverOffset * math.min(1, car.stateT / Cfg.PanicSeconds) + wl
		car.yaw = wy
	else
		local step = Cfg.LateralSpeed * dt
		car.lat += math.clamp(car.latTarget - car.lat, -step, step)
		if car.state == "Drive" then
			car.yaw *= math.max(0, 1 - dt * 3)
			if math.abs(car.yaw) < 0.01 then
				car.yaw = 0
			end
		end
	end
	placeCar(car)

	-- 4. stuck bookkeeping -----------------------------------------------------------------------
	if car.v < 0.5 and car.state == "Drive" and not car.atSignal then
		car.stuck += dt
	else
		car.stuck = 0
	end
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
	-- despawn far and stuck-unseen cars
	for i = #cars, 1, -1 do
		local car = cars[i]
		if car.state == "Wrecked" then
			continue
		end
		local d = nearestDist(car.x, car.z, people)
		if d > Cfg.DespawnRadius or (car.stuck > Cfg.StuckDespawn and d > Cfg.UnseenRadius) then
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
		local s = rng:NextNumber() * lane.len
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
	local lit = 0
	for _ in lightFor do
		lit += 1
	end
	print(`[TrafficService] road graph: {n.edgeCount} edges, {#n.lanes} lanes, {lit} lanes with lights`)
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
		while acc >= step do
			acc -= step
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
	local yielding, wrecked = 0, 0
	for _, c in cars do
		if c.state == "Yield" or c.state == "Panic" then
			yielding += 1
		elseif c.state == "Wrecked" then
			wrecked += 1
		end
	end
	local lit = 0
	for _ in lightFor do
		lit += 1
	end
	return {
		cars = #cars,
		yielding = yielding,
		wrecked = wrecked,
		lanes = if net then #(net :: RoadNet.Net).lanes else 0,
		litLanes = lit,
	}
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
	return true, `{s.cars} cars on {s.lanes} lanes ({s.litLanes} lit), {s.yielding} yielding`
end

return TrafficService
