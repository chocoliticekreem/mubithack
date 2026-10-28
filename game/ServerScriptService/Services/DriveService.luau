--!strict
-- DriveService [owner: Drive]. The drive from the station to a call (DriveConfig). Live funnel: 28-35% of
-- players quit between "In Truck" and "Arrived On Scene", so every drive is measured, riders get a job,
-- and an empty driver's seat can be taken. NO autopilot: the truck only ever moves when a kid drives it.
--
--   * Telemetry (AnalyticsService custom events through FunnelService:LogCustomFields; CustomField01 = the
--     Player attr Device Phone | Tablet | PC | Console | Unknown, as OnboardingV3 does):
--       DriveStart  (value = road route metres, F2 role driver | passenger, F3 rookie | call): first time a
--                   squad member sits in a truck while their run is Dispatched
--       DriveArrive (value = seconds in the truck until the run went Active, F2 role, F3 rookie | call)
--       DriveQuit   (value = road metres left, F2 role, F3 DriveMath.quitField "left|t30-60|r1|s0|w10+"):
--                   left the game, or left the call (InstanceId changed) before arriving
--       TruckReset  (value 1, F2 why: below | noground | sunk | stuck | settle | recall | manual, F3 call | free):
--                   VehicleService.Rescued ("Truck reset!") or the R / RESPAWN TRUCK button
--       TruckStuck  (value = metres left, F2 role, F3 nodriver | notstarted | idle | blocked | wrongway): on a
--                   call, the road distance left didn't shrink by DriveConfig.StuckStuds for StuckSeconds.
--                   notstarted = the truck never rolled yet since DriveStart (the lobby seats the squad at launch,
--                   so a kid reading the call card used to count as "idle"; that inflated TruckStuck ~ DriveStart)
--       UnstuckApplied (value = metres left, 0 off a call; F2 role, F3 call | free): the driver's client auto-unstuck
--                   the truck (VehicleController AUTO-UNSTICK, Drive/Unstuck C->S with the try index; 0 = no free spot)
--     Distance = the road route (StarterPlayerScripts/ClientLib/Pathfind, the GPS's own A*) from the truck
--     to the player's WaypointPos, recomputed every RouteRefresh s or when off it. Wrong way = moving at
--     WrongWayMinSpeed+ while the road distance left grows.
--   * Practice fires: when a run is dispatched, up to TargetMax small roadside fires (tag DriveTarget,
--     Workspace.DriveTargets.<runId>) sit on the curb along the road route. Riders spray them with the
--     truck's roof cannon (DriveController): Drive/Hit (C->S: target) from a rider within TargetRange,
--     TargetHits hits put one out for TargetXp XP (DataService:AddXp, caption "PRACTICE FIRE OUT!"). Removed when
--     the run arrives or ends.
--   * Drive/TakeWheel (C->S): a rider on a call whose driver's seat is empty slides over
--     (VehicleService:TakeWheel); DriveController shows TAKE THE WHEEL! after NoDriverSeconds.
-- Counters: drive_starts, drive_starts_<role>, drive_arrives, drive_quits, drive_stuck, drive_stuck_<cause>,
--   drive_resets, drive_targets_spawned, drive_targets_out, drive_wheel_taken, drive_no_graph, drive_unstuck,
--   drive_unstuck_none (Drive/Unstuck C->S: the driver's client unstuck the truck / found no free spot)
-- Test hooks (DevHook only): _state(player) -> JSON, _targets(runId?) -> number
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DriveConfig") :: ModuleScript) :: any
local DriveMath = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Vehicle"):WaitForChild("DriveMath") :: ModuleScript)

local DriveService = {}
DriveService.Priority = 96 -- after FunnelService (95), VehicleService, MissionService

local TRUCK_TAG: string = (Names.Tag :: any).Truck or "Truck"
local TARGET_TAG = "DriveTarget"

type P = { x: number, y: number, z: number }
type Drive = {
	run: string,
	t0: number,
	role: string,
	device: string,
	rookie: boolean,
	total: number,
	left: number,
	prevLeft: number?,
	poly: { P }?,
	polyAt: number,
	bestLeft: number,
	bestAt: number,
	inStuck: boolean,
	resets: number,
	stuck: number,
	wrongSecs: number,
	rolled: boolean, -- the truck has moved since DriveStart
	unstuck: number,
}

local services: { [string]: any } = {}
local drives: { [Player]: Drive } = {}
local Pathfind: any = nil
local graph: any = nil
local graphSig = ""
local targetRuns: { [string]: Folder } = {}
local lastHit: { [Player]: number } = {}

local function count(name: string)
	pcall(Telemetry.count, name, 1)
end

local function log(player: Player, event: string, value: number, f2: string?, f3: string?)
	local F = services.FunnelService
	if not F or type(F.LogCustomFields) ~= "function" then
		return
	end
	local device = player:GetAttribute("Device")
	pcall(F.LogCustomFields, F, player, event, value, if type(device) == "string" then device else "Unknown", f2, f3)
end

------------------------------------------------------------------------------------------ road graph

local function loadPathfind()
	if Pathfind then
		return
	end
	local ok, mod = pcall(function()
		local sps = StarterPlayer:WaitForChild("StarterPlayerScripts", 10)
		local lib = sps and sps:WaitForChild("ClientLib", 10)
		local m = lib and lib:WaitForChild("Pathfind", 10)
		return if m and m:IsA("ModuleScript") then require(m) :: any else nil
	end)
	Pathfind = if ok then mod else nil
end

local function refreshGraph()
	if not Pathfind then
		return
	end
	local map = workspace:FindFirstChild("Map")
	local city = map and map:FindFirstChild("City")
	local json = city and city:FindFirstChild("RoadGraphJson")
	if not json or not json:IsA("StringValue") or json.Value == "" then
		return
	end
	local sig = `{#json.Value}:{string.sub(json.Value, 1, 48)}`
	if sig == graphSig then
		return
	end
	graphSig = sig
	local ok, data = pcall(HttpService.JSONDecode, HttpService, json.Value)
	graph = if ok then Pathfind.decode(data) else nil
end

local function route(from: Vector3, to: Vector3): { P }?
	if not Pathfind or not graph then
		return nil
	end
	local ok, poly = pcall(Pathfind.route, graph, { x = from.X, y = from.Y, z = from.Z }, { x = to.X, y = to.Y, z = to.Z })
	return if ok then poly else nil
end

local function lengthOf(poly: { P }?): number
	return if poly and Pathfind then Pathfind.length(poly) else 0
end

------------------------------------------------------------------------------------------ helpers

local function runOf(player: Player): (string, Instance?)
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return "", nil
	end
	local runs = workspace:FindFirstChild("Runs")
	return id, runs and runs:FindFirstChild(id)
end

local function seatOf(player: Player): (BasePart?, Model?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.SeatPart
	local node: Instance? = seat
	while node and node ~= workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, TRUCK_TAG) then
			return seat, node :: Model
		end
		node = node.Parent
	end
	return nil, nil
end

local function rootPos(player: Player): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

------------------------------------------------------------------------------------------ practice fires

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.RespectCanCollide = true

local function makeTarget(parent: Instance, pos: Vector3, runId: string, n: number): Model
	local m = Instance.new("Model")
	m.Name = `PracticeFire{n}`
	local can = Instance.new("Part")
	can.Name = "Can"
	can.Shape = Enum.PartType.Cylinder
	can.Size = Vector3.new(3.4, 3, 3)
	can.CFrame = CFrame.new(pos + Vector3.new(0, 1.7, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	can.Color = Color3.fromRGB(70, 74, 82)
	can.Material = Enum.Material.Metal
	can.Anchored = true
	can.CanCollide = false
	can.CanTouch = false
	can.CastShadow = false
	can.Parent = m
	local flame = Instance.new("Part")
	flame.Name = "Flame"
	flame.Shape = Enum.PartType.Ball
	flame.Size = Vector3.new(3.2, 3.2, 3.2)
	flame.CFrame = CFrame.new(pos + Vector3.new(0, 4.4, 0))
	flame.Color = Color3.fromRGB(255, 140, 30)
	flame.Material = Enum.Material.Neon
	flame.Transparency = 0.25
	flame.Anchored = true
	flame.CanCollide = false
	flame.CanTouch = false
	flame.CastShadow = false
	flame.Parent = m
	local fire = Instance.new("Fire")
	fire.Size = 6
	fire.Heat = 9
	fire.Parent = flame
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 150, 60)
	light.Range = 14
	light.Brightness = 2
	light.Parent = flame
	m.PrimaryPart = can
	m:SetAttribute("RunId", runId)
	m:SetAttribute("Hits", 0)
	m:SetAttribute("Out", false)
	m.Parent = parent
	CollectionService:AddTag(m, TARGET_TAG)
	return m
end

-- small fires on the curb along the road route (both sides, alternating), never inside a building
local function spawnTargets(runId: string, poly: { P })
	if targetRuns[runId] or not Cfg.Targets or not Pathfind then
		return
	end
	local root = workspace:FindFirstChild("DriveTargets")
	if not root then
		local f = Instance.new("Folder")
		f.Name = "DriveTargets"
		f.Parent = workspace
		root = f
	end
	local folder = Instance.new("Folder")
	folder.Name = runId
	folder.Parent = root
	targetRuns[runId] = folder
	local filter: { Instance } = { folder }
	for _, t in CollectionService:GetTagged(TRUCK_TAG) do
		table.insert(filter, t)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(filter, p.Character)
		end
	end
	local traffic = workspace:FindFirstChild("Traffic")
	if traffic then
		table.insert(filter, traffic)
	end
	rayParams.FilterDescendantsInstances = filter
	local total = Pathfind.length(poly)
	local spots = DriveMath.spaced(total, Cfg.TargetSkipStart, Cfg.TargetSkipEnd, Cfg.TargetSpacing, Cfg.TargetMax)
	local n = 0
	for i, along in spots do
		local s = Pathfind.samples(poly, along, 1, 1)[1]
		if not s then
			continue
		end
		local off = DriveMath.curbOffset(nil, Cfg.TargetCurbOffset)
		for _, side in { if i % 2 == 0 then -1 else 1, if i % 2 == 0 then 1 else -1 } do
			-- right of travel = (-dz, dx) with heading (dx, dz)
			local x, z = s.x - s.dz * off * side, s.z + s.dx * off * side
			local hit = workspace:Raycast(Vector3.new(x, s.y + 40, z), Vector3.new(0, -70, 0), rayParams)
			if hit and math.abs(hit.Position.Y - s.y) <= 3.5 then
				n += 1
				makeTarget(folder, hit.Position, runId, n)
				break
			end
		end
	end
	count("drive_targets_spawned")
	print(`[DriveService] {runId}: {n} practice fires along {math.floor(total)} studs`)
end

local function clearTargets(runId: string)
	local f = targetRuns[runId]
	targetRuns[runId] = nil
	if f then
		f:Destroy()
	end
end

local function douse(m: Model)
	m:SetAttribute("Out", true)
	local flame = m:FindFirstChild("Flame")
	if flame and flame:IsA("BasePart") then
		flame.Transparency = 1
		for _, d in flame:GetChildren() do
			if d:IsA("Fire") or d:IsA("PointLight") then
				d.Enabled = false
			end
		end
		local smoke = Instance.new("Smoke")
		smoke.Color = Color3.fromRGB(230, 230, 235)
		smoke.Opacity = 0.35
		smoke.RiseVelocity = 6
		smoke.Size = 3
		smoke.Parent = flame
		task.delay(2.5, function()
			smoke.Enabled = false
		end)
	end
end

local function onHit(player: Player, target: any)
	if typeof(target) ~= "Instance" or not target:IsA("Model") or not CollectionService:HasTag(target, TARGET_TAG) then
		return
	end
	local m = target :: Model
	if m:GetAttribute("Out") == true or not m:IsDescendantOf(workspace) then
		return
	end
	local id = runOf(player)
	if id == "" or m:GetAttribute("RunId") ~= id then
		return
	end
	local seat, truck = seatOf(player)
	if not seat or not truck or seat.Name == "DriveSeat" then
		return -- riders only: the driver drives
	end
	local now = os.clock()
	if now - (lastHit[player] or 0) < (Cfg.HitInterval or 0.25) * 0.8 then
		return
	end
	lastHit[player] = now
	local at = m:GetPivot().Position
	if (truck:GetPivot().Position - at).Magnitude > (Cfg.TargetRange or 120) then
		return
	end
	local hits = (tonumber(m:GetAttribute("Hits")) or 0) + 1
	m:SetAttribute("Hits", hits)
	if hits < (Cfg.TargetHits or 3) then
		return
	end
	douse(m)
	count("drive_targets_out")
	local xp = tonumber(Cfg.TargetXp) or 5
	local Data = services.DataService
	if Data and type(Data.AddXp) == "function" then
		pcall(Data.AddXp, Data, player, xp, "PRACTICE FIRE OUT!") -- the reason is the "+5 XP" pop's caption
	else
		Popup.show(m, `+{xp} XP`, "good", player)
	end
end

------------------------------------------------------------------------------------------ drives

local function finish(player: Player, d: Drive, how: string)
	drives[player] = nil
	if how == "arrive" then
		count("drive_arrives")
		log(player, "DriveArrive", math.floor(os.clock() - d.t0 + 0.5), d.role, if d.rookie then "rookie" else "call")
	else
		count("drive_quits")
		local secs = os.clock() - d.t0
		log(player, "DriveQuit", DriveMath.metres(d.left), d.role, DriveMath.quitField(how, secs, d.resets, d.stuck, d.wrongSecs))
	end
end

local function begin(player: Player, runId: string, run: Instance, seat: BasePart, truck: Model)
	local wp = player:GetAttribute("WaypointPos")
	local from = truck:GetPivot().Position
	local poly = if typeof(wp) == "Vector3" then route(from, wp) else nil
	local total = lengthOf(poly)
	if total <= 0 and typeof(wp) == "Vector3" then
		total = (wp - from).Magnitude
	end
	local role = if seat.Name == "DriveSeat" then "driver" else "passenger"
	local device = player:GetAttribute("Device")
	local now = os.clock()
	local d: Drive = {
		run = runId,
		t0 = now,
		role = role,
		device = if type(device) == "string" then device else "Unknown",
		rookie = run:GetAttribute("Rookie") == true,
		total = total,
		left = total,
		prevLeft = nil,
		poly = poly,
		polyAt = now,
		bestLeft = total,
		bestAt = now,
		inStuck = false,
		resets = 0,
		stuck = 0,
		wrongSecs = 0,
		rolled = false,
		unstuck = 0,
	}
	drives[player] = d
	count("drive_starts")
	count(`drive_starts_{role}`)
	log(player, "DriveStart", DriveMath.metres(total), role, if d.rookie then "rookie" else "call")
	if poly then
		spawnTargets(runId, poly)
	elseif not graph then
		count("drive_no_graph")
	end
end

local function update(player: Player, d: Drive, dt: number)
	local now = os.clock()
	local seat, truck = seatOf(player)
	if seat then
		d.role = if seat.Name == "DriveSeat" then "driver" else "passenger"
	end
	local here = if truck then truck:GetPivot().Position else rootPos(player)
	local wp = player:GetAttribute("WaypointPos")
	if not here or typeof(wp) ~= "Vector3" then
		return
	end
	-- road distance left (the server's own copy of the GPS route)
	local left: number
	local poly = d.poly
	local off = math.huge
	local along = 0
	if poly and Pathfind then
		along, off = Pathfind.project(poly, here.X, here.Z)
	end
	if not poly or now - d.polyAt >= (Cfg.RouteRefresh or 3) or off > (Cfg.OffRoute or 35) then
		d.poly = route(here, wp)
		d.polyAt = now
		poly = d.poly
		if poly then
			along = 0
			along, off = Pathfind.project(poly, here.X, here.Z)
		end
	end
	if poly and Pathfind then
		left = math.max(0, Pathfind.length(poly) - along)
	else
		left = (wp - here).Magnitude
	end
	d.left = left
	-- wrong way: moving, and the road distance left grows
	local speed = 0
	if truck and truck.PrimaryPart then
		local v = truck.PrimaryPart.AssemblyLinearVelocity
		speed = Vector3.new(v.X, 0, v.Z).Magnitude
	end
	if speed >= 4 then
		d.rolled = true
	end
	local wrong = false
	if d.prevLeft and speed >= (Cfg.WrongWayMinSpeed or 8) and left > (d.prevLeft :: number) + 1 then
		d.wrongSecs += dt
		wrong = true
	end
	d.prevLeft = left
	-- stuck: no real progress for StuckSeconds
	if left < d.bestLeft - (Cfg.StuckStuds or 4) then
		d.bestLeft = left
		d.bestAt = now
		d.inStuck = false
	elseif not d.inStuck and now - d.bestAt >= (Cfg.StuckSeconds or 5) then
		d.inStuck = true
		d.stuck += 1
		local driveSeat = truck and truck:FindFirstChild("DriveSeat")
		local hasDriver = driveSeat ~= nil and driveSeat:IsA("VehicleSeat") and driveSeat.Occupant ~= nil
		local throttle = if hasDriver then (driveSeat :: VehicleSeat).ThrottleFloat else 0
		local cause = DriveMath.stuckCause(hasDriver, throttle, speed, wrong or d.wrongSecs > 0 and speed > 4, d.rolled)
		count("drive_stuck")
		count(`drive_stuck_{cause}`)
		log(player, "TruckStuck", DriveMath.metres(left), d.role, cause)
	end
end

local function tick(dt: number)
	refreshGraph()
	for _, player in Players:GetPlayers() do
		local id, run = runOf(player)
		local d = drives[player]
		if d and d.run ~= id then
			finish(player, d, "cancel") -- left the call (or got a new one) before arriving
			d = nil
		end
		local state = if run then run:GetAttribute(Names.Attr.RoundState) else nil
		if run and state == "Dispatched" then
			if not d then
				local seat, truck = seatOf(player)
				if seat and truck then
					begin(player, id, run, seat, truck)
				end
			else
				update(player, d, dt)
			end
		elseif d and run then
			-- on scene; a call that ended while still driving (time up, ended by an admin) is not an arrival
			finish(player, d, if state == "Results" or state == "Lobby" then "cancel" else "arrive")
		end
	end
	-- practice fires go once the run is on scene or over
	for runId in targetRuns do
		local runs = workspace:FindFirstChild("Runs")
		local run = runs and runs:FindFirstChild(runId)
		if not run or run:GetAttribute(Names.Attr.RoundState) ~= "Dispatched" then
			clearTargets(runId)
		end
	end
end

local function onRescued(truck: Model, why: string)
	count("drive_resets")
	local logged = false
	for _, p in Players:GetPlayers() do
		local _, t = seatOf(p)
		if t == truck then
			local d = drives[p]
			if d then
				d.resets += 1
				d.bestAt = os.clock() -- a reset isn't "stuck" time
				d.inStuck = false
			end
			if not logged then
				logged = true
				log(p, "TruckReset", 1, why, if d then "call" else "free")
			end
		end
	end
	if not logged then
		local owner = truck:GetAttribute("OwnerUserId")
		local p = if type(owner) == "number" then Players:GetPlayerByUserId(owner) else nil
		if p then
			log(p, "TruckReset", 1, why, if drives[p] then "call" else "free")
		end
	end
end

------------------------------------------------------------------------------------------ lifecycle

function DriveService:Init(all: { [string]: any })
	services = all
end

function DriveService:Start()
	Net.onServer(Net.event("Drive", "Hit"), { rate = 6, burst = 3 }, onHit)
	Net.onServer(Net.event("Drive", "TakeWheel"), { rate = 1, burst = 2 }, function(player: Player)
		local id, run = runOf(player)
		if id == "" or not run or run:GetAttribute(Names.Attr.RoundState) ~= "Dispatched" then
			return
		end
		local V = services.VehicleService
		if V and type(V.TakeWheel) == "function" then
			local ok, moved = pcall(V.TakeWheel, V, player)
			if ok and moved then
				count("drive_wheel_taken")
				local d = drives[player]
				if d then
					d.role = "driver"
				end
			end
		end
	end)
	Net.onServer(Net.event("Drive", "Unstuck"), { rate = 1, burst = 2 }, function(player: Player, try: any)
		local seat, truck = seatOf(player)
		if not seat or not truck or seat.Name ~= "DriveSeat" then
			return
		end
		local n = if type(try) == "number" then math.floor(try) else 0
		if n <= 0 or n > 20 then
			count("drive_unstuck_none")
			return
		end
		count("drive_unstuck")
		local d = drives[player]
		if d then
			d.unstuck += 1
			d.bestAt = os.clock() -- just moved it: a fresh chance before another TruckStuck
			d.inStuck = false
		end
		log(player, "UnstuckApplied", if d then DriveMath.metres(d.left) else 0, if d then d.role else "driver", if d then "call" else "free")
	end)
	local V = services.VehicleService
	if V and V.Rescued then
		V.Rescued:Connect(onRescued)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local d = drives[player]
		if d then
			finish(player, d, "left")
		end
		lastHit[player] = nil
	end)
	task.spawn(function()
		loadPathfind()
		local step = tonumber(Cfg.TickSeconds) or 0.5
		while true do
			task.wait(step)
			local ok, err = pcall(tick, step)
			if not ok then
				warn(`[DriveService] {err}`)
			end
		end
	end)
end

------------------------------------------------------------------------------------------ test hooks

function DriveService:_state(player: Player): string
	local d = drives[player]
	if not d then
		return "{}"
	end
	return HttpService:JSONEncode({
		run = d.run,
		role = d.role,
		rookie = d.rookie,
		total = math.floor(d.total),
		left = math.floor(d.left),
		seconds = math.floor((os.clock() - d.t0) * 10) / 10,
		resets = d.resets,
		stuck = d.stuck,
		unstuck = d.unstuck,
		rolled = d.rolled,
		wrongSecs = math.floor(d.wrongSecs * 10) / 10,
	})
end

function DriveService:_targets(runId: string?): number
	local n = 0
	for _, m in CollectionService:GetTagged(TARGET_TAG) do
		if (not runId or m:GetAttribute("RunId") == runId) and m:GetAttribute("Out") ~= true then
			n += 1
		end
	end
	return n
end

return DriveService
