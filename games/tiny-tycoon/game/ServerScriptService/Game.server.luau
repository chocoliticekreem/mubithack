--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

-- Guard: the world (plaza + plot ring) and all services must be started exactly once.
-- A duplicate start is benign, so it returns silently (no warning in the output).
if workspace:GetAttribute("ForgeWorldBuilt") == true then
	return
end
workspace:SetAttribute("ForgeWorldBuilt", true)

local Config: any = require(ReplicatedStorage:WaitForChild("Config"))
local ForgeTelemetry: any = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local PlotBuilder: any = require(ServerScriptService:WaitForChild("PlotBuilder"))
local PlazaBuilder: any = require(ServerScriptService:WaitForChild("PlazaBuilder"))
local PlotClaimService: any = require(ServerScriptService:WaitForChild("PlotClaimService"))
local UpgradeService: any = require(ServerScriptService:WaitForChild("UpgradeService"))
local RebirthService: any = require(ServerScriptService:WaitForChild("RebirthService"))
local TutorialService: any = require(ServerScriptService:WaitForChild("TutorialService"))
local DataService: any = require(ServerScriptService:WaitForChild("DataService"))
local JuiceService: any = require(ServerScriptService:WaitForChild("JuiceService"))

-- CashInService runs the collector (cube -> Cash, cubes_collected); it must be started.
local CashInService: any = nil
do
	local cashInModule = ServerScriptService:WaitForChild("CashInService", 5)
	if cashInModule and cashInModule:IsA("ModuleScript") then
		local okReq, result = pcall(require, cashInModule)
		if okReq then
			CashInService = result
		else
			warn("CashInService require failed: " .. tostring(result))
		end
	end
end

-- Remotes
local remotes = ReplicatedStorage:FindFirstChild(Config.REMOTES_FOLDER)
if not remotes then
	local f = Instance.new("Folder")
	f.Name = Config.REMOTES_FOLDER
	f.Parent = ReplicatedStorage
	remotes = f
end
if not (remotes :: Instance):FindFirstChild(Config.REMOTE_NOTIFY) then
	local ev = Instance.new("RemoteEvent")
	ev.Name = Config.REMOTE_NOTIFY
	ev.Parent = remotes
end

-- Calls the first function found under any of the given names.
local function callFirst(module: any, names: { string }, ...: any): (boolean, any)
	if type(module) ~= "table" then
		return false, nil
	end
	for _, name in names do
		local fn = module[name]
		if type(fn) == "function" then
			local ok, result = pcall(fn, ...)
			if not ok then
				warn(name .. " failed: " .. tostring(result))
			end
			return ok, result
		end
	end
	return false, nil
end

-- Data: initialise once at startup (before any player is handled)
callFirst(DataService, { "init" })

-- Juice: lighting style + juice remotes, once at startup (before any player is handled)
callFirst(JuiceService, { "init" })

-- World: base, plaza, plots (each built exactly once)
local built = false
local plazaCenter = Vector3.new(0, 4, 0)
local plots: { any } = {}

local function buildWorld()
	if built then
		return
	end
	built = true

	callFirst(PlotBuilder, { "buildBase" })

	-- Baseplate styling (no default grey)
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		if typeof(Config.BASEPLATE_COLOR) == "Color3" then
			baseplate.Color = Config.BASEPLATE_COLOR
		end
		if typeof(Config.BASEPLATE_MATERIAL) == "EnumItem" then
			baseplate.Material = Config.BASEPLATE_MATERIAL
		end
	end

	local okPlaza, plaza = callFirst(PlazaBuilder, { "buildPlaza", "build", "create" })
	if okPlaza and plaza ~= nil then
		if typeof(plaza) == "CFrame" then
			plazaCenter = (plaza :: CFrame).Position
		elseif typeof(plaza) == "Vector3" then
			plazaCenter = plaza :: Vector3
		elseif type(plaza) == "table" then
			local c = plaza.spawnCFrame or plaza.centerCFrame or plaza.center or plaza.spawn
			if typeof(c) == "CFrame" then
				plazaCenter = c.Position
			elseif typeof(c) == "Vector3" then
				plazaCenter = c
			end
		end
	end

	local plotCount: number = Config.PLOT_COUNT or Config.MAX_PLOTS or 6
	for i = 1, plotCount do
		local ok, plot = pcall(PlotBuilder.buildPlot, i)
		if ok and plot ~= nil then
			table.insert(plots, plot)
		else
			warn("Plot build failed: " .. tostring(plot))
		end
	end

	ForgeTelemetry.count("map_built", 1)
end

buildWorld()

-- PlotClaimService is the single authority for claiming and auto-claiming.
callFirst(PlotClaimService, { "init", "start", "setup" }, plots)
callFirst(UpgradeService, { "init" })
callFirst(RebirthService, { "init" })
callFirst(CashInService, { "init", "start", "setup" }, plots)

-- Claim detection
-- Resolves the plot currently owned by a player (nil if none).
local function getClaimedPlot(player: Player): any?
	if type(PlotClaimService) == "table" then
		local getter = PlotClaimService.getPlot or PlotClaimService.getPlotFor
		if type(getter) == "function" then
			local ok, result = pcall(getter, player)
			if ok and result ~= nil then
				if type(result) == "number" then
					return plots[result]
				end
				return result
			end
		end
	end
	local idx = player:GetAttribute("PlotIndex") or player:GetAttribute("ClaimedPlot")
	if type(idx) == "number" then
		return plots[idx]
	end
	return nil
end

local function hasClaimedPlot(player: Player): boolean
	if getClaimedPlot(player) ~= nil then
		return true
	end
	return player:GetAttribute("PlotIndex") ~= nil or player:GetAttribute("ClaimedPlot") ~= nil
end

-- Notifies UpgradeService once per claimed plot (covers manual and auto-claim paths).
local notifiedPlot: { [Player]: any } = {}
local function checkClaim(player: Player)
	local plot = getClaimedPlot(player)
	if plot == nil then
		notifiedPlot[player] = nil
		return
	end
	if notifiedPlot[player] == plot then
		return
	end
	notifiedPlot[player] = plot
	callFirst(UpgradeService, { "onPlotClaimed" }, player, plot)
	callFirst(CashInService, { "onPlotClaimed" }, player, plot)
end

-- Moves an unclaimed player to the plaza center; claimed players are never teleported.
local function spawnAtPlaza(player: Player, character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	if hasClaimedPlot(player) then
		return
	end
	local offset = Vector3.new(math.random(-6, 6), 4, math.random(-6, 6))
	character:PivotTo(CFrame.new(plazaCenter + offset))
end

local setupDone: { [Player]: boolean } = {}

local function setupPlayer(player: Player)
	if setupDone[player] then
		return
	end
	setupDone[player] = true

	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		ls = folder
	end
	if not (ls :: Instance):FindFirstChild("Cash") then
		local cash = Instance.new("IntValue")
		cash.Name = "Cash"
		cash.Value = 0
		cash.Parent = ls
	end

	-- Load saved data and re-apply it BEFORE the tycoon / claim / tutorial wiring starts
	callFirst(DataService, { "loadPlayer" }, player)
	if player.Parent ~= Players then
		return
	end
	callFirst(DataService, { "applyPlayer" }, player)

	player.CharacterAdded:Connect(function(character)
		spawnAtPlaza(player, character)
	end)
	if player.Character then
		local character = player.Character
		task.spawn(spawnAtPlaza, player, character)
	end

	-- Watch for plot claims
	player:GetAttributeChangedSignal("PlotIndex"):Connect(function()
		checkClaim(player)
	end)
	player:GetAttributeChangedSignal("ClaimedPlot"):Connect(function()
		checkClaim(player)
	end)
	task.spawn(function()
		while player.Parent == Players do
			checkClaim(player)
			task.wait(0.5)
		end
	end)
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(setupPlayer, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(setupPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	notifiedPlot[player] = nil
	setupDone[player] = nil
	callFirst(UpgradeService, { "onPlayerRemoving" }, player)
	callFirst(CashInService, { "onPlayerRemoving" }, player)
end)

-- Tutorial: started once after all other services are wired
callFirst(TutorialService, { "start" })
