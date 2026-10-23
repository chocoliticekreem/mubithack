--!strict
-- FireService [owner: G1]. Fire simulation on parts tagged "Flammable" (built by MapService builders).
-- The maths lives in Lib/Fire/FireSim (pure, unit-tested); this file owns the Roblox side.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   FireService:Ignite(part: BasePart, cause: Player?): boolean
--   FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
--   FireService:IsBurning(part: BasePart): boolean
--   FireService:CountBurning(locationId: string?): number   -- locationId or v1.5 instanceId; nil = all
--   FireService:ExtinguishAll(locationId: string?)          -- nil = every location/instance
--   FireService:ClearInstance(instanceId: string)            -- v1.5, called by MissionService at mission end
-- Indexes MapService.LocationBuilt (key = locationId) and v1.5 MapService.InstanceBuilt (key = instanceId).
-- Signals: Ignited(part, cause: Player?), Spread(from, to), Extinguished(part, by: Player?), Charred(part)
-- Writes: tag Burning; attrs FireLevel (1..3, nil when out), Charred (true) + Color/Material on burnt-out parts
-- Budget: every location (mission instance) is stepped on its own and has its own MaxBurningPerLocation
--   cap, so parallel missions never starve each other; MaxBurning is a server-wide safety net.
-- Counters: fires_ignited, fires_spread, fires_extinguished, parts_charred, fire_tick_over_budget,
--   fire_cap_hit
-- Test hooks (DevHook only): _index(model, locationId), _forget(locationId), _ignite(pos),
--   _water(origin, aim, litres), _selftest()

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local FireConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("FireConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local FireSim = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Fire"):WaitForChild("FireSim") :: ModuleScript)

type Cell = {
	part: BasePart,
	heat: number, -- 0..100, server only, never replicated
	fuel: number, -- seconds of burning left
	state: number, -- FireSim.IDLE / BURNING / CHARRED
	level: number, -- last replicated FireLevel (0 = none)
	neighbors: { Cell },
	location: string,
	cause: Player?, -- who lit it (for Blame)
}

type Location = {
	id: string,
	model: Instance?,
	burning: { [Cell]: true },
	count: number,
	capWarned: boolean,
}

local FireService = {}
FireService.Priority = 50
FireService.Ignited = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Spread = Signal.new() :: Signal.Signal<BasePart, BasePart>
FireService.Extinguished = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Charred = Signal.new() :: Signal.Signal<BasePart>

local services: { [string]: any } = {}
local cells: { [BasePart]: Cell } = {}
local locations: { [string]: Location } = {}
local totalBurning = 0

local function loc(id: string): Location
	local l = locations[id]
	if not l then
		l = { id = id, model = nil, burning = {}, count = 0, capWarned = false }
		locations[id] = l
	end
	return l
end

local function setLevel(c: Cell)
	local level = FireSim.levelFor(c.state, c.heat)
	if level == c.level then
		return -- replicate transitions only
	end
	c.level = level
	c.part:SetAttribute(Names.Attr.FireLevel, if level > 0 then level else nil)
end

local function startBurning(c: Cell, cause: Player?): boolean
	if c.state ~= FireSim.IDLE then
		return false
	end
	local l = loc(c.location)
	if not FireSim.canIgnite(l.count, FireConfig.MaxBurningPerLocation, totalBurning, FireConfig.MaxBurning) then
		if not l.capWarned then
			l.capWarned = true
			Telemetry.count("fire_cap_hit")
		end
		return false
	end
	c.state, c.cause = FireSim.BURNING, cause
	c.heat = math.max(c.heat, FireConfig.IgniteAt)
	l.burning[c] = true
	l.count += 1
	totalBurning += 1
	CollectionService:AddTag(c.part, Names.Tag.Burning)
	setLevel(c)
	return true
end

local function stopBurning(c: Cell, charred: boolean)
	if c.state ~= FireSim.BURNING then
		return
	end
	local l = loc(c.location)
	l.burning[c] = nil
	l.count -= 1
	l.capWarned = false
	totalBurning -= 1
	if charred and c.part.Parent then
		-- set Charred before removing the tag: clients use it to skip the "put out" steam puff
		c.part:SetAttribute(Names.Attr.Charred, true)
		c.part.Color = FireConfig.CharredColor
		c.part.Material = FireConfig.CharredMaterial
	end
	c.state = if charred then FireSim.CHARRED else FireSim.IDLE
	c.heat = if charred then c.heat else 0
	CollectionService:RemoveTag(c.part, Names.Tag.Burning)
	setLevel(c)
	if charred then
		Telemetry.count("parts_charred")
		FireService.Charred:Fire(c.part)
	end
end

-- One location's step: its own burning set, its own cap, so one big fire can't stall another mission.
local function stepLocation(l: Location, dt: number)
	-- drop cells whose part was destroyed without a re-index
	for c in l.burning do
		if not c.part.Parent then
			l.burning[c] = nil
			l.count -= 1
			totalBurning -= 1
			cells[c.part] = nil
		end
	end
	local lit, charred = FireSim.step(l.burning :: any, dt, FireConfig :: any)
	for _, c in charred :: { any } do
		stopBurning(c :: Cell, true)
	end
	for c in l.burning do
		setLevel(c)
	end
	for _, e in lit :: { any } do
		local from, to = e.from :: Cell, e.to :: Cell
		if to.state == FireSim.IDLE and startBurning(to, from.cause) then
			FireService.Spread:Fire(from.part, to.part)
			Telemetry.count("fires_spread")
		end
	end
end

local function step(dt: number)
	local t0 = os.clock()
	for _, l in locations do
		if l.count > 0 then
			stepLocation(l, dt)
		end
	end
	if (os.clock() - t0) * 1000 > FireConfig.TickBudgetMs then
		Telemetry.count("fire_tick_over_budget")
	end
end

-- Drop every cell of a location (its parts are being destroyed or rebuilt).
local function forget(locationId: string)
	local l = locations[locationId]
	if l then
		totalBurning -= l.count
		locations[locationId] = nil
	end
	for part, c in cells do
		if c.location == locationId then
			if c.state == FireSim.BURNING and part.Parent then
				-- re-indexed in place (not rebuilt): don't leave a ghost Burning tag behind
				CollectionService:RemoveTag(part, Names.Tag.Burning)
				part:SetAttribute(Names.Attr.FireLevel, nil)
			end
			cells[part] = nil
		end
	end
end

-- Index every Flammable BasePart under `model` as one location. Re-indexing replaces the old cells.
local function index(model: Instance, locationId: string)
	forget(locationId)
	loc(locationId).model = model
	-- an instance destroyed without a re-index (MapService:DestroyInstance) frees its cells
	model.Destroying:Once(function()
		local l = locations[locationId]
		if l and l.model == model then
			forget(locationId)
		end
	end)
	local list: { Cell } = {}
	local positions: { FireSim.Pos } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Flammable) then
			local old = cells[d]
			if old and old.location ~= locationId then
				continue -- already owned by another location
			end
			local c: Cell = {
				part = d,
				heat = 0,
				fuel = (d:GetAttribute(Names.Attr.Fuel) :: number?) or FireConfig.DefaultFuel,
				state = FireSim.IDLE,
				level = 0,
				neighbors = {},
				location = locationId,
				cause = nil,
			}
			cells[d] = c
			table.insert(list, c)
			table.insert(positions, { x = d.Position.X, y = d.Position.Y, z = d.Position.Z })
		end
	end
	local links = FireSim.buildNeighbors(positions, FireConfig.SpreadRadius)
	for i, c in list do
		for _, j in links[i] do
			table.insert(c.neighbors, list[j])
		end
	end
end

function FireService:Init(all: { [string]: any })
	services = all
end

function FireService:Start()
	local MapService = services.MapService
	if MapService then
		if MapService.LocationBuilt then
			MapService.LocationBuilt:Connect(function(model: Model, locationId: string)
				index(model, locationId)
			end)
		end
		-- v1.5 parallel missions: each instance is its own fire location, keyed by instanceId
		if MapService.InstanceBuilt then
			MapService.InstanceBuilt:Connect(function(model: Model, instanceId: string, _locationId: string)
				index(model, instanceId)
			end)
		end
		local ok, all = pcall(function()
			return MapService:GetLocations()
		end)
		if ok and type(all) == "table" then
			for id, model in all do
				index(model, id)
			end
		end
		local ok2, inst = pcall(function()
			return MapService:GetInstances()
		end)
		if ok2 and type(inst) == "table" then
			for id, model in inst do
				index(model, id)
			end
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		local period = 1 / FireConfig.TickHz
		if acc >= period then
			acc -= period
			if acc > period then
				acc = 0 -- after a hitch, skip the backlog instead of burning it all in one frame
			end
			step(period)
		end
	end)
end

function FireService:Ignite(part: BasePart, cause: Player?): boolean
	local c = part and cells[part]
	if not c or c.state ~= FireSim.IDLE then
		return false
	end
	if not startBurning(c, cause) then
		return false
	end
	Telemetry.count("fires_ignited")
	FireService.Ignited:Fire(part, cause)
	return true
end

function FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
	if typeof(origin) ~= "Vector3" or typeof(aim) ~= "Vector3" or type(litres) ~= "number" or litres <= 0 then
		return 0
	end
	local hit = 0
	local out: { Cell } = {}
	for _, l in locations do
		for c in l.burning do
			local d = c.part.Position - origin
			if FireSim.inCone(d.X, d.Y, d.Z, aim.X, aim.Y, aim.Z, FireConfig.HoseRange, FireConfig.HoseConeCos) then
				hit += 1
				if FireSim.cool(c :: any, litres, FireConfig :: any) then
					table.insert(out, c)
				else
					setLevel(c)
				end
			end
		end
	end
	for _, c in out do -- apply after the loop: never remove keys from a set while iterating it
		stopBurning(c, false)
		FireService.Extinguished:Fire(c.part, player)
		Telemetry.count("fires_extinguished")
	end
	return hit
end

function FireService:IsBurning(part: BasePart): boolean
	local c = part and cells[part]
	return c ~= nil and c.state == FireSim.BURNING
end

function FireService:CountBurning(locationId: string?): number
	if not locationId then
		return totalBurning
	end
	local l = locations[locationId]
	return if l then l.count else 0
end

function FireService:ExtinguishAll(locationId: string?)
	local list: { Cell } = {}
	for id, l in locations do
		if locationId == nil or id == locationId then
			for c in l.burning do
				table.insert(list, c)
			end
		end
	end
	for _, c in list do
		stopBurning(c, false)
	end
end

-- v1.5: a mission instance ended. Put its fires out silently (no Extinguished signal, so nobody gets
-- Blame credit), then drop its cells and budget. Safe to call twice or for an unknown id.
function FireService:ClearInstance(instanceId: string)
	if type(instanceId) ~= "string" then
		return
	end
	self:ExtinguishAll(instanceId)
	forget(instanceId)
end

-- test hooks -------------------------------------------------------------------------------
function FireService:_index(model: Instance, locationId: string)
	index(model, locationId)
end

function FireService:_forget(locationId: string)
	self:ClearInstance(locationId)
end

function FireService:_ignite(pos: Vector3): BasePart?
	local best, bestD = nil :: Cell?, math.huge
	for _, c in cells do
		local d = (c.part.Position - pos).Magnitude
		if c.state == FireSim.IDLE and d < bestD and c.part:IsDescendantOf(workspace) then
			best, bestD = c, d
		end
	end
	if best and self:Ignite(best.part, nil) then
		return best.part
	end
	return nil
end

function FireService:_water(origin: Vector3, aim: Vector3, litres: number): number
	return self:ApplyWater(nil, origin, aim.Unit, litres)
end

function FireService:_selftest(): (boolean, string)
	-- Self-contained: builds two 2-cell locations far above the map, fills location A to its cap and
	-- checks B still ignites (per-instance budget), then douses and removes everything.
	local made: { Model } = {}
	local function build(name: string, x: number): Model
		local model = Instance.new("Model")
		model.Name = name
		for i = 0, 1 do
			local p = Instance.new("Part")
			p.Name = `Cell{i}`
			p.Anchored = true
			p.CanCollide = false
			p.Size = Vector3.new(4, 4, 4)
			p.Position = Vector3.new(x + i * 8, 900, 0)
			CollectionService:AddTag(p, Names.Tag.Flammable)
			p.Parent = model
		end
		model.Parent = workspace
		table.insert(made, model)
		return model
	end
	local a = build("FireSelftestA", 0)
	local b = build("FireSelftestB", 200)
	index(a, "_selftestA")
	index(b, "_selftestB")
	local cap = FireConfig.MaxBurningPerLocation
	local result, message = true, "ok"
	local a0 = a:FindFirstChild("Cell0") :: BasePart
	local a1 = a:FindFirstChild("Cell1") :: BasePart
	local b0 = b:FindFirstChild("Cell0") :: BasePart
	FireConfig.MaxBurningPerLocation = 1
	local ok, err = pcall(function()
		if not self:Ignite(a0, nil) then
			result, message = false, "Ignite returned false"
		elseif not CollectionService:HasTag(a0, Names.Tag.Burning) then
			result, message = false, "Ignite did not tag Burning"
		elseif self:Ignite(a1, nil) then
			result, message = false, "per-location cap not enforced"
		elseif not self:Ignite(b0, nil) then
			result, message = false, "full location A starved location B"
		else
			self:ApplyWater(nil, a0.Position - Vector3.new(0, 0, 5), Vector3.new(0, 0, 1), 1000)
			if self:IsBurning(a0) then
				result, message = false, "ApplyWater did not extinguish"
			end
		end
	end)
	FireConfig.MaxBurningPerLocation = cap
	self:_forget("_selftestA")
	self:_forget("_selftestB")
	for _, m in made do
		m:Destroy()
	end
	if not ok then
		return false, tostring(err)
	end
	return result, message
end

return FireService
