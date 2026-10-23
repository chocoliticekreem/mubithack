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
-- Signals: LocationBuilt(model: Model, locationId: string)
-- Writes: Workspace.Map.<Id> (attr LocationId), Workspace attr MapReady, counter map_build_ms
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local MapConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MapConfig") :: ModuleScript)

local MapService = {}
MapService.Priority = 0
MapService.LocationBuilt = Signal.new() :: Signal.Signal<Model, string>

local locations: { [string]: Model } = {}
local builders: { [string]: any } = {}

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
