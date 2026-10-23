--!strict
-- WorldBoundsService [owner: G2]. Keeps the world tidy around the playable area:
--   * restyles the default grey "Baseplate" (from make_place / Studio templates) into a grass field
--     sized to the play area, so the lobby never sits on grey studs;
--   * builds invisible boundary walls around the play area (the city's extent when CityConfig
--     exists, otherwise WorldConfig defaults) and pulls anyone who gets past them back inside,
--     with a funny toast. Falling out of the world respawns you at the station.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript) :: any
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)

local WorldBoundsService = {}
WorldBoundsService.Priority = 2

local DEFAULT_HALF = 450 -- studs from the station when there is no city yet
local WALL_HEIGHT = 400
local services: { [string]: any } = {}
local bounds = { minX = -DEFAULT_HALF, maxX = DEFAULT_HALF, minZ = -DEFAULT_HALF, maxZ = DEFAULT_HALF }

local function cityBounds(): { minX: number, maxX: number, minZ: number, maxZ: number }?
	local cfgMod = ReplicatedStorage:FindFirstChild("Config") and ReplicatedStorage.Config:FindFirstChild("CityConfig")
	if not cfgMod then
		return nil
	end
	local ok, cfg = pcall(require, cfgMod)
	if not ok or type(cfg) ~= "table" or cfg.Enabled == false then
		return nil
	end
	local b = cfg.Bounds
	if type(b) == "table" and b.minX then
		return b
	end
	local size = tonumber(cfg.Size or cfg.CitySize)
	local origin = cfg.Origin
	if size and typeof(origin) == "Vector3" then
		return { minX = origin.X - size / 2, maxX = origin.X + size / 2, minZ = origin.Z - size / 2, maxZ = origin.Z + size / 2 }
	end
	return nil
end

local function restyleBaseplate()
	local cx, cz = (bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2
	local sx, sz = bounds.maxX - bounds.minX + 200, bounds.maxZ - bounds.minZ + 200
	for _, inst in workspace:GetChildren() do
		if inst:IsA("BasePart") and inst.Name == "Baseplate" then
			inst.Material = Enum.Material.Grass
			inst.Color = Color3.fromRGB(104, 152, 74)
			inst.Size = Vector3.new(math.min(sx, 2048), inst.Size.Y, math.min(sz, 2048))
			inst.Position = Vector3.new(cx, inst.Position.Y, cz)
			for _, t in inst:GetChildren() do
				if t:IsA("Texture") or t:IsA("Decal") then
					t:Destroy() -- the grey stud texture
				end
			end
		end
	end
end

local function buildWalls()
	local old = workspace:FindFirstChild("WorldBounds")
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "WorldBounds"
	local cx, cz = (bounds.minX + bounds.maxX) / 2, (bounds.minZ + bounds.maxZ) / 2
	local w, d = bounds.maxX - bounds.minX, bounds.maxZ - bounds.minZ
	local function wall(name: string, pos: Vector3, size: Vector3)
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Transparency = 1
		p.CanCollide = true
		p.CanQuery = false
		p.CanTouch = false
		p.Size = size
		p.Position = pos
		p.Parent = folder
	end
	local y = WALL_HEIGHT / 2 - 10
	wall("North", Vector3.new(cx, y, bounds.minZ - 2), Vector3.new(w + 8, WALL_HEIGHT, 4))
	wall("South", Vector3.new(cx, y, bounds.maxZ + 2), Vector3.new(w + 8, WALL_HEIGHT, 4))
	wall("West", Vector3.new(bounds.minX - 2, y, cz), Vector3.new(4, WALL_HEIGHT, d + 8))
	wall("East", Vector3.new(bounds.maxX + 2, y, cz), Vector3.new(4, WALL_HEIGHT, d + 8))
	folder.Parent = workspace
end

local JOKES = {
	"Dispatch says: that's not our district.",
	"The city ends here. Fires do not.",
	"Turn around, hero. The cat is the other way.",
}

local function pullBack(player: Player, root: BasePart)
	local p = root.Position
	local inside = Vector3.new(
		math.clamp(p.X, bounds.minX + 20, bounds.maxX - 20),
		math.max(p.Y, 8),
		math.clamp(p.Z, bounds.minZ + 20, bounds.maxZ - 20)
	)
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = CFrame.new(inside) * (root.CFrame - root.CFrame.Position)
	Popup.show(player, JOKES[math.random(1, #JOKES)], "info", player)
end

local function toStation(player: Player, root: BasePart)
	local Map = services.MapService
	local cf = (Map and type(Map.GetSpawnCFrame) == "function") and Map:GetSpawnCFrame(0) or CFrame.new(0, 8, 0)
	root.AssemblyLinearVelocity = Vector3.zero
	root.CFrame = cf + Vector3.new(0, 4, 0)
	pcall(Net.notify, player, "You fell off the map. Back to the station.", "bad")
end

function WorldBoundsService:Init(s)
	services = s
end

function WorldBoundsService:GetBounds()
	return bounds
end

function WorldBoundsService:Start()
	local b = cityBounds()
	if b then
		bounds = b
	end
	restyleBaseplate()
	buildWalls()
	task.spawn(function()
		while true do
			task.wait(0.5)
			for _, player in Players:GetPlayers() do
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				if root then
					local p = root.Position
					if p.Y < -60 then
						toStation(player, root)
					elseif p.X < bounds.minX - 6 or p.X > bounds.maxX + 6 or p.Z < bounds.minZ - 6 or p.Z > bounds.maxZ + 6 then
						-- players in a far-away mission copy (instance fallback) or seated in a truck are fine
						local inMission = (player:GetAttribute("InstanceId") or "") ~= ""
						local seated = root.AssemblyRootPart ~= root
						if not inMission and not seated then
							pullBack(player, root)
						end
					end
				end
			end
		end
	end)
end

function WorldBoundsService._selftest(): boolean
	return workspace:FindFirstChild("WorldBounds") ~= nil
end

return WorldBoundsService
