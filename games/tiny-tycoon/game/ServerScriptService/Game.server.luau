--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local PlotBuilder = require(ServerScriptService:WaitForChild("PlotBuilder"))
local Tycoon = require(ServerScriptService:WaitForChild("Tycoon"))

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

-- World
local base = PlotBuilder.buildBase()
ForgeTelemetry.count("map_built", 1)

-- No SpawnLocation is created: Instance.new("SpawnLocation") adds a default Decal that
-- loads an unapproved asset and logs a warning. Characters are teleported to their plot
-- on every CharacterAdded (including respawns), so a spawn object is not needed.
local _ = base

type PlayerState = {
	index: number,
	plot: any,
	tycoon: any,
	counted: boolean,
	conns: { RBXScriptConnection },
}

local states: { [Player]: PlayerState } = {}
local slots: { [number]: Player? } = {}

local function nextFreeSlot(): number?
	for i = 1, Config.MAX_PLOTS do
		if slots[i] == nil then
			return i
		end
	end
	return nil
end

local function removePlot(plot: any)
	pcall(function()
		local parts: { Instance } = {}
		for _, key in { "conveyor", "collector", "dropperButton", "conveyorButton", "dropperSlot2" } do
			local p = plot[key]
			if typeof(p) == "Instance" then
				table.insert(parts, p)
			end
		end
		if type(plot.droppers) == "table" then
			for _, d in plot.droppers do
				if typeof(d) == "Instance" then
					table.insert(parts, d)
				end
			end
		end
		local container = parts[1] and parts[1].Parent
		if
			container
			and container ~= Workspace
			and (container:IsA("Model") or (container:IsA("Folder") and container.Name ~= "Plots" and container.Name ~= "TycoonPlots"))
		then
			container:Destroy()
		else
			for _, p in parts do
				p:Destroy()
			end
		end
	end)
end

local function teleport(player: Player, state: PlayerState, character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	if state.plot == nil or states[player] ~= state then
		return
	end
	character:PivotTo(state.plot.spawnCFrame + Vector3.new(0, 3, 0))
	if not state.counted then
		state.counted = true
		ForgeTelemetry.count("plot_assigned", 1)
	end
end

local function setupPlayer(player: Player)
	if states[player] then
		return
	end

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

	local index = nextFreeSlot()
	if not index then
		player:Kick("Server is full")
		return
	end
	slots[index] = player

	local state: PlayerState = { index = index, plot = nil, tycoon = nil, counted = false, conns = {} }
	states[player] = state

	local okPlot, plot = pcall(PlotBuilder.buildPlot, index)
	if not okPlot then
		warn("Plot build failed: " .. tostring(plot))
		states[player] = nil
		slots[index] = nil
		return
	end
	state.plot = plot
	state.tycoon = Tycoon.new(player, plot)

	table.insert(state.conns, player.CharacterAdded:Connect(function(character)
		teleport(player, state, character)
	end))
	if player.Character then
		local character = player.Character
		task.spawn(teleport, player, state, character)
	end
end

local function cleanupPlayer(player: Player)
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil
	for _, c in state.conns do
		c:Disconnect()
	end
	if state.tycoon then
		pcall(function()
			state.tycoon:destroy()
		end)
	end
	if state.plot then
		removePlot(state.plot)
	end
	if slots[state.index] == player then
		slots[state.index] = nil
	end
end

Players.PlayerAdded:Connect(setupPlayer)
Players.PlayerRemoving:Connect(cleanupPlayer)
for _, player in Players:GetPlayers() do
	task.spawn(setupPlayer, player)
end
