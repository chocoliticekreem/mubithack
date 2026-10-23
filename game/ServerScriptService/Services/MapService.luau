--!strict
-- MapService [owner: G2]. Builds Workspace.Map from every ServerScriptService/Lib/Map/Locations/*Builder.
-- Builder contract: { Id: string, Slot: number, Build(model: Model, origin: CFrame, rng: Random) }.
-- API: GetLocation(id), GetLocations(), RebuildLocation(id), GetSpawnCFrame(slot).
-- Signal: LocationBuilt(model, id). Writes Workspace attribute MapReady.
-- BuildAll() also works in the Edit datamodel (preview), so the map is visible in Studio.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local MapConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MapConfig") :: ModuleScript)

local MapService = {}
MapService.Priority = 0
MapService.LocationBuilt = Signal.new()

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

local function discover()
	local dir = ServerScriptService:WaitForChild("Lib"):WaitForChild("Map"):WaitForChild("Locations")
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

function MapService:BuildAll()
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
	return MapConfig.SlotOrigin(slot) * CFrame.new(0, 5, 0)
end

function MapService:Start()
	local ms = MapService:BuildAll()
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count("map_build_ms", ms)
	end)
	print(`[MapService] built {#mapFolder():GetChildren()} locations in {ms} ms`)
end

function MapService._selftest(): boolean
	return workspace:GetAttribute(Names.Attr.MapReady) == true
end

return MapService
