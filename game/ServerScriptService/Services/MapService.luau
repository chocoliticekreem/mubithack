--!strict
-- MapService [owner: G2]. Builds Workspace.Map from every ServerScriptService/Lib/Map/Locations/*Builder.
-- Builder contract: { Id: string, Slot: number, Build(model: Model, origin: CFrame, rng: Random) }.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   MapService:GetLocation(id: string): Model?
--   MapService:GetLocations(): { [string]: Model }
--   MapService:RebuildLocation(id: string): Model?       -- round reset; fires LocationBuilt again
--   MapService:GetSpawnCFrame(slot: number): CFrame      -- StationSpawn pad 1..4, 3 studs up
--   MapService:RandomFlammable(id: string, rng: Random): BasePart?
--   MapService:BuildAll(): number                        -- ms taken; also works in Edit (preview)
-- v1.5 (parallel squads, each mission in its own copy of a location):
--   MapService:BuildInstance(locationId: string, instanceId: string): Model?  -- nil: no builder / no free slot
--   MapService:DestroyInstance(instanceId: string): boolean
--   MapService:GetInstance(instanceId: string): Model?
--   MapService:GetInstances(): { [string]: Model }
--   MapService:InstanceOrigin(n: number): CFrame                -- instance slot n (0-based): x = 2000 + n*500
-- v2 incident sites (docs/game/08 "City"/"Dispatch missions"): Models tagged IncidentSite (attr SiteId)
--   MapService:GetSites(): { Model }                       -- every IncidentSite under Workspace
--   MapService:GetSite(siteId: string): Model?
--   MapService:BindSite(siteId: string, runId: string): Model?  -- fresh copy of the site for a run: attrs
--       InstanceId = runId, Busy = true; GetInstance(runId) returns it; announced as InstanceBuilt(site,
--       runId, LocationId) so FireService scopes its fires to the run (FireService:ClearInstance(runId))
--   MapService:RebuildSite(siteId: string): Model?         -- site back as first seen (Busy false, unbound)
--   Reset = swap in a clone of the site taken the first time it was bound/rebuilt (cheap, no builder rerun).
--   DestroyInstance(runId) on a bound site rebuilds the site instead of destroying it.
-- Signals: LocationBuilt(model: Model, locationId: string)
--          InstanceBuilt(model: Model, instanceId: string, locationId: string)   -- v1.5 (+ v2 BindSite)
-- Writes: Workspace.Map.<Id> (attr LocationId), Workspace attr MapReady, counter map_build_ms;
--         Workspace.Instances.<instanceId> (attrs InstanceId, LocationId), counter map_instances_built
-- Test hooks (DevHook only): _selftest()
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local MapConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MapConfig") :: ModuleScript)

local MapService = {}
MapService.Priority = 0
MapService.LocationBuilt = Signal.new() :: Signal.Signal<Model, string>
MapService.InstanceBuilt = Signal.new() :: Signal.Signal<Model, string, string>

local locations: { [string]: Model } = {}
local builders: { [string]: any } = {}
local instances: { [string]: Model } = {}
local slotOwner: { [number]: string } = {} -- instance slot -> instanceId
-- v2 incident sites (names not in the frozen Names module yet; docs/game/08 is the contract)
local SITE_TAG = "IncidentSite"
local pristine: { [string]: Model } = {} -- siteId -> unparented clone taken on first bind/rebuild
local siteRuns: { [string]: Model } = {} -- runId -> bound site Model

local function hash(s: string): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 1000003
	end
	return h
end

local function mapFolder(): Folder
	local f = workspace:FindFirstChild("Map")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Map"
		f.Parent = workspace
	end
	return f :: Folder
end

local function instancesFolder(): Folder
	local f = workspace:FindFirstChild("Instances")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Instances"
		f.Parent = workspace
	end
	return f :: Folder
end

local function count(name: string, n: number?)
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count(name, n or 1)
	end)
end

local function locationsFolder(): Instance?
	local lib = ServerScriptService:FindFirstChild("Lib")
	local map = lib and lib:FindFirstChild("Map")
	return map and map:FindFirstChild("Locations")
end

local function discover()
	local dir = locationsFolder()
	if not dir then
		warn("[MapService] no ServerScriptService.Lib.Map.Locations yet: the map is empty")
		return
	end
	for _, child in dir:GetChildren() do
		if child:IsA("ModuleScript") and string.match(child.Name, "Builder$") then
			local ok, b = pcall(require, child)
			if ok and type(b) == "table" and type(b.Build) == "function" and b.Enabled ~= false then
				builders[b.Id or child.Name] = b
			else
				warn(`[MapService] skip {child.Name}: {if ok then "bad builder" else b}`)
			end
		end
	end
end

function MapService:BuildLocation(id: string): Model?
	local b = builders[id]
	if not b then
		return nil
	end
	local old = mapFolder():FindFirstChild(id)
	if old then
		old:Destroy()
	end
	local model = Instance.new("Model")
	model.Name = id
	model:SetAttribute(Names.Attr.LocationId, id)
	local rng = Random.new(MapConfig.Seed + hash(id))
	local ok, err = pcall(b.Build, model, MapConfig.SlotOrigin(b.Slot or 0), rng)
	if not ok then
		warn(`[MapService] {id}.Build failed: {err}`)
	end
	model.Parent = mapFolder() -- parent once, after building (fast)
	locations[id] = model
	table.clear(pristine) -- sites may have been rebuilt with the location: re-snapshot lazily
	MapService.LocationBuilt:Fire(model, id)
	return model
end

function MapService:BuildAll(): number
	table.clear(builders) -- rediscover every time (Edit-mode requires are cached between previews)
	discover()
	local t0 = os.clock()
	local ids = {}
	for id in builders do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		MapService:BuildLocation(id)
	end
	workspace:SetAttribute(Names.Attr.MapReady, true)
	return math.floor((os.clock() - t0) * 1000)
end

function MapService:GetLocation(id: string): Model?
	return locations[id]
end

function MapService:GetLocations(): { [string]: Model }
	return locations
end

function MapService:RebuildLocation(id: string): Model?
	return MapService:BuildLocation(id)
end

function MapService:GetSpawnCFrame(slot: number): CFrame
	local station = locations.Station
	if station then
		for _, d in station:GetDescendants() do
			-- Slot is the contract; Helmet is what main's StationBuilder sets until G2.2 adds Slot.
			local padSlot = d:GetAttribute(Names.Attr.Slot) or d:GetAttribute(Names.Attr.Helmet)
			if d:IsA("BasePart") and d:HasTag(Names.Tag.StationSpawn) and padSlot == slot then
				return d.CFrame * CFrame.new(0, 3, 0)
			end
		end
	end
	return MapConfig.SlotOrigin(0) * CFrame.new((slot - 1) * 4, 5, 0)
end

function MapService:RandomFlammable(id: string, rng: Random): BasePart?
	local model = locations[id]
	if not model then
		return nil
	end
	local list: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.Flammable) and d:GetAttribute(Names.Attr.Charred) ~= true then
			table.insert(list, d)
		end
	end
	if #list == 0 then
		return nil
	end
	return list[rng:NextInteger(1, #list)]
end

-- Instance n (0-based) sits far from the station/lobby and from every other instance, so parallel
-- squads never see or hear each other's fires: x = 2000 + n * 500 (towns are ~260 studs wide).
function MapService:InstanceOrigin(n: number): CFrame
	return CFrame.new(2000 + n * 500, 0, 0)
end

function MapService:BuildInstance(locationId: string, instanceId: string): Model?
	if instances[instanceId] then
		MapService:DestroyInstance(instanceId)
	end
	if builders[locationId] == nil then
		discover()
	end
	local b = builders[locationId]
	if not b then
		warn(`[MapService] BuildInstance: no builder for {locationId}`)
		return nil
	end
	local slot: number? = nil
	for i = 0, MapConfig.MaxInstances - 1 do
		local s = MapConfig.InstanceFirstSlot + i
		if slotOwner[s] == nil then
			slot = s
			break
		end
	end
	if not slot then
		warn(`[MapService] BuildInstance: all {MapConfig.MaxInstances} instance slots are in use`)
		return nil
	end
	slotOwner[slot] = instanceId
	local model = Instance.new("Model")
	model.Name = instanceId
	model:SetAttribute(Names.Attr.InstanceId, instanceId)
	model:SetAttribute(Names.Attr.LocationId, locationId)
	local rng = Random.new(MapConfig.Seed + hash(locationId))
	local ok, err = pcall(b.Build, model, MapService:InstanceOrigin(slot - MapConfig.InstanceFirstSlot), rng)
	if not ok then
		warn(`[MapService] {locationId}.Build (instance {instanceId}) failed: {err}`)
	end
	model.Parent = instancesFolder()
	instances[instanceId] = model
	count("map_instances_built")
	MapService.InstanceBuilt:Fire(model, instanceId, locationId)
	return model
end

function MapService:DestroyInstance(instanceId: string): boolean
	local bound = siteRuns[instanceId]
	if bound then
		local sid = bound:GetAttribute("SiteId")
		siteRuns[instanceId] = nil
		if type(sid) == "string" and bound.Parent then
			MapService:RebuildSite(sid)
		end
		return true
	end
	local model = instances[instanceId]
	for s, owner in slotOwner do
		if owner == instanceId then
			slotOwner[s] = nil
		end
	end
	if not model then
		return false
	end
	instances[instanceId] = nil
	model:Destroy()
	return true
end

function MapService:GetInstance(instanceId: string): Model?
	return instances[instanceId] or siteRuns[instanceId]
end

-- v2 incident sites ---------------------------------------------------------------------------------

local function siteIdOf(m: Instance): string
	local v = m:GetAttribute("SiteId")
	return if type(v) == "string" and v ~= "" then v else m.Name
end

function MapService:GetSites(): { Model }
	local out: { Model } = {}
	for _, inst in CollectionService:GetTagged(SITE_TAG) do
		if inst:IsA("Model") and inst:IsDescendantOf(workspace) then
			table.insert(out, inst)
		end
	end
	return out
end

function MapService:GetSite(siteId: string): Model?
	for _, m in MapService:GetSites() do
		if siteIdOf(m) == siteId then
			return m
		end
	end
	return nil
end

-- Replace the site with a fresh clone of its first-seen state. Returns the live model (the old one if it
-- can't be cloned, e.g. Archivable = false).
local function swapSite(siteId: string): Model?
	local cur = MapService:GetSite(siteId)
	if not cur then
		return nil
	end
	if not pristine[siteId] then
		local copy = cur:Clone()
		if not copy then
			return cur
		end
		copy:SetAttribute("Busy", false)
		copy:SetAttribute(Names.Attr.InstanceId, nil)
		pristine[siteId] = copy
	end
	local fresh = pristine[siteId]:Clone()
	local parent = cur.Parent
	for runId, m in siteRuns do
		if m == cur then
			siteRuns[runId] = nil
		end
	end
	cur:Destroy()
	fresh.Parent = parent
	count("map_sites_rebuilt")
	return fresh
end

function MapService:RebuildSite(siteId: string): Model?
	local site = swapSite(siteId)
	if site then
		site:SetAttribute("Busy", false)
		site:SetAttribute(Names.Attr.InstanceId, nil)
	end
	return site
end

function MapService:BindSite(siteId: string, runId: string): Model?
	local site = swapSite(siteId)
	if not site then
		return nil
	end
	site:SetAttribute(Names.Attr.InstanceId, runId)
	site:SetAttribute("Busy", true)
	siteRuns[runId] = site
	local loc = site:GetAttribute(Names.Attr.LocationId)
	local cursor: Instance? = site.Parent
	while type(loc) ~= "string" and cursor and cursor ~= workspace do
		loc = cursor:GetAttribute(Names.Attr.LocationId)
		cursor = cursor.Parent
	end
	MapService.InstanceBuilt:Fire(site, runId, if type(loc) == "string" then loc else "City")
	return site
end

function MapService:GetInstances(): { [string]: Model }
	return instances
end

function MapService:Start()
	local ms = MapService:BuildAll()
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count("map_build_ms", ms)
	end)
	print(`[MapService] built {#mapFolder():GetChildren()} locations in {ms} ms`)
end

function MapService:_selftest(): (boolean, string)
	if workspace:GetAttribute(Names.Attr.MapReady) ~= true then
		return false, "MapReady not set"
	end
	return true, `{#mapFolder():GetChildren()} locations`
end

return MapService
