--!nonstrict
-- PlotGrowth: builds visible growth models on a player's plot as upgrades are bought.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local GrowthModels = require(ServerScriptService:WaitForChild("GrowthModels", 10))
local Upgrades = require(ReplicatedStorage:WaitForChild("Upgrades", 10))
local PlotThemes = require(ReplicatedStorage:WaitForChild("PlotThemes", 10))
local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets", 10))
local okT, Telemetry = pcall(function()
	return require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 10))
end)

local PlotGrowth = {}
local built: { [Player]: { [string]: Model } } = {}

local ORE_WORDS = { "silver", "gold", "diamond", "ruby", "emerald", "neon", "bronze", "platinum", "crystal" }

local function count(name: string)
	if okT and Telemetry and type(Telemetry.count) == "function" then
		pcall(Telemetry.count, name, 1)
	end
end

local function getList(): { any }
	if type(Upgrades) ~= "table" then return {} end
	for _, k in ipairs({ "list", "List", "upgrades", "Upgrades", "all", "All" }) do
		if type(Upgrades[k]) == "table" and #Upgrades[k] > 0 then return Upgrades[k] end
	end
	if #Upgrades > 0 then return Upgrades end
	return {}
end

local function findDef(id: string, list: { any }): any?
	for _, k in ipairs({ "byId", "ById" }) do
		if type(Upgrades[k]) == "table" and type(Upgrades[k][id]) == "table" then return Upgrades[k][id] end
	end
	for _, d in ipairs(list) do
		if type(d) == "table" and d.id == id then return d end
	end
	return nil
end

local function ownedSet(ownedIds: any): { [string]: boolean }
	local set = {}
	if type(ownedIds) ~= "table" then return set end
	for k, v in pairs(ownedIds) do
		if type(v) == "string" then
			set[v] = true
		elseif v == true and type(k) == "string" then
			set[k] = true
		elseif type(v) == "table" and type(v.id) == "string" then
			set[v.id] = true
		end
	end
	return set
end

local function classify(def: any): string?
	local kind = string.lower(tostring(def.kind or def.type or ""))
	local key = string.lower(tostring(def.id or "") .. " " .. tostring(def.name or ""))
	local function has(s: string): boolean
		return string.find(kind, s, 1, true) ~= nil or string.find(key, s, 1, true) ~= nil
	end
	if has("dropper") then return "dropper" end
	if has("speed") or string.find(kind, "conveyor", 1, true) then return "speed" end
	if string.find(kind, "mult", 1, true) or has("cash") or has("multiplier") then return "cash" end
	if string.find(kind, "ore", 1, true) or string.find(kind, "tier", 1, true) or def.tierColor then return "ore" end
	for _, w in ipairs(ORE_WORDS) do
		if string.find(key, w, 1, true) then return "ore" end
	end
	return nil
end

local function resolveTheme(plot: Instance): any
	local themes = PlotThemes.Themes
	local name = plot:GetAttribute("Theme") or plot.Name
	if type(themes) == "table" and type(name) == "string" then
		local lname = string.lower(name)
		for _, t in pairs(themes) do
			if type(t) == "table" and type(t.name) == "string" and string.find(lname, string.lower(t.name), 1, true) then
				return t
			end
		end
	end
	return {}
end

local function partCF(plot: Instance, name: string): (CFrame?, Vector3?)
	local p = plot:FindFirstChild(name, true)
	if p and p:IsA("BasePart") then return p.CFrame, p.Size end
	if p and p:IsA("Model") then
		local ok, cf, size = pcall(function() return p:GetBoundingBox() end)
		if ok then return cf, size end
	end
	return nil, nil
end

local function floorInfo(plot: Instance): (CFrame, Vector3)
	for _, n in ipairs({ "Floor", "Base", "Plot" }) do
		local cf, size = partCF(plot, n)
		if cf and size then return cf, size end
	end
	if plot:IsA("Model") then
		if plot.PrimaryPart then return plot.PrimaryPart.CFrame, plot.PrimaryPart.Size end
		local ok, cf, size = pcall(function() return plot:GetBoundingBox() end)
		if ok then return cf, size end
	end
	return CFrame.new(), Vector3.new(60, 1, 60)
end

-- Direction along the conveyor (longest horizontal axis)
local function conveyorFrame(plot: Instance): (CFrame, Vector3, number)
	local cf, size = partCF(plot, "Conveyor")
	if not cf or not size then
		local fcf, fsize = floorInfo(plot)
		cf, size = fcf, fsize
	end
	local dir = cf.LookVector
	local len = size.Z
	if size.X > size.Z then dir = cf.RightVector; len = size.X end
	dir = Vector3.new(dir.X, 0, dir.Z)
	if dir.Magnitude < 0.01 then dir = Vector3.new(0, 0, -1) end
	return CFrame.lookAt(cf.Position, cf.Position + dir.Unit), size, len
end

local function placeFor(kind: string, slot: number, plot: Instance): CFrame
	local conv, csize, len = conveyorFrame(plot)
	local dir = conv.LookVector
	local side = dir:Cross(Vector3.yAxis)
	local top = Vector3.new(0, csize.Y / 2, 0)
	if kind == "dropper" then
		local dcf = partCF(plot, "Dropper")
		local origin = dcf and dcf.Position or conv.Position - dir * (len / 2)
		local pos = origin + dir * (slot * 6) + Vector3.new(0, 3, 0)
		return CFrame.lookAt(pos, pos + dir)
	elseif kind == "speed" then
		local pos = conv.Position + top + dir * (-len / 4 + (slot - 1) * (len / 4)) + Vector3.new(0, 0.2, 0)
		return CFrame.lookAt(pos, pos + dir)
	end
	local ccf, csz = partCF(plot, "Collector")
	local base = ccf and ccf.Position or conv.Position + dir * (len / 2)
	local reach = (csz and math.max(csz.X, csz.Z) or 6) / 2 + 5
	local sgn = (kind == "ore") and 1 or -1
	local pos = base + side * (sgn * reach) + dir * ((slot - 1) * 4) - Vector3.new(0, (csz and csz.Y or 1) / 2 - 0.5, 0)
	return CFrame.lookAt(pos, pos + dir)
end

local function growthFolder(plot: Instance): Folder
	local f = plot:FindFirstChild("Growth")
	if f and f:IsA("Folder") then return f end
	local nf = Instance.new("Folder")
	nf.Name = "Growth"
	nf.Parent = plot
	return nf
end

local function finish(model: Model)
	local primary = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart", true)
	if type(GameAssets.popIn) == "function" then
		local ok = pcall(GameAssets.popIn, model)
		if not ok and primary then pcall(GameAssets.popIn, primary) end
	end
	if type(GameAssets.burst) == "function" and primary then
		local color = primary.Color
		pcall(GameAssets.burst, primary.Position, color)
	end
	count("plot_growth_built")
end

function PlotGrowth.apply(player: Player, plot: Instance?, ownedIds: any)
	if not player or not plot or not plot.Parent then return end
	local owned = ownedSet(ownedIds)
	if next(owned) == nil then return end
	built[player] = built[player] or {}
	local mine = built[player]
	local list = getList()
	local theme = resolveTheme(plot)
	local folder = growthFolder(plot)

	local function ensure(key: string, make: () -> Model?)
		local existing = mine[key]
		if existing and existing.Parent then return end
		local ok, model = pcall(make)
		if not ok or not model then return end
		model.Parent = folder
		mine[key] = model
		finish(model)
	end

	local counters = { dropper = 0, speed = 0, ore = 0, cash = 0 }
	local defs = list
	if #defs == 0 then
		defs = {}
		for id in pairs(owned) do
			local d = findDef(id, list)
			if d then table.insert(defs, d) end
		end
	end
	for _, def in ipairs(defs) do
		local kind = type(def) == "table" and classify(def) or nil
		if kind then
			counters[kind] += 1
			local slot = counters[kind]
			local id = tostring(def.id)
			if owned[id] then
				local key = kind .. ":" .. id
				if kind == "dropper" then
					ensure(key, function() return GrowthModels.dropperMachine(placeFor("dropper", slot, plot), theme) end)
				elseif kind == "speed" then
					ensure(key, function() return GrowthModels.chevrons(placeFor("speed", slot, plot), theme) end)
				elseif kind == "ore" then
					local color = def.tierColor or def.color
					if typeof(color) ~= "Color3" then color = nil end
					ensure(key, function() return GrowthModels.orePile(placeFor("ore", slot, plot), theme, color) end)
				elseif kind == "cash" then
					ensure(key, function() return GrowthModels.vault(placeFor("cash", slot, plot), theme, tostring(def.name or id)) end)
				end
			end
		end
	end

	ensure("wall", function()
		local fcf, fsize = floorInfo(plot)
		return GrowthModels.plotWall(fcf, fsize, theme)
	end)
end

function PlotGrowth.clear(player: Player)
	local mine = built[player]
	built[player] = nil
	if not mine then return end
	for _, model in pairs(mine) do
		if model and model.Parent then
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("BasePart") then
					pcall(function()
						TweenService:Create(d, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.In), {
							Size = d.Size * 0.1,
							Transparency = 1,
						}):Play()
					end)
				end
			end
			task.delay(0.4, function()
				if model then model:Destroy() end
			end)
		end
	end
end

Players.PlayerRemoving:Connect(function(player)
	PlotGrowth.clear(player)
end)

return PlotGrowth
