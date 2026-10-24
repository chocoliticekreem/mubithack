local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))

local STORE_NAME = "CubeCashTycoon_v1"
local ATTEMPTS = 3
local LOAD_TIMEOUT = 3
local SAVE_TIMEOUT = 5

local DataService = {}

-- Fired (with the player) as soon as the player's data is ready (loaded or memory fallback).
local loadedEvent = Instance.new("BindableEvent")
DataService.PlayerLoaded = loadedEvent.Event

local store: any = nil
local useMemory = false
local printedMemory = false
local initialized = false
local memory: { [string]: any } = {}
local cache: { [Player]: any } = {}
local loaded: { [Player]: boolean } = {}
local saving: { [Player]: boolean } = {}
local countedLoad: { [Player]: boolean } = {}
local finalState: { [Player]: string } = {}
local serviceCache: { [string]: any } = {}

local function switchToMemory()
	useMemory = true
	if not printedMemory then
		printedMemory = true
		print("DataService: using in-memory store")
	end
end

local function keyFor(player: Player): string
	return "p_" .. tostring(player.UserId)
end

-- Never blocks: only looks at services that already exist.
local function getService(name: string): any
	if serviceCache[name] then
		return serviceCache[name]
	end
	local inst = ServerScriptService:FindFirstChild(name)
	if not inst then
		return nil
	end
	local ok, mod = pcall(require, inst)
	if ok then
		serviceCache[name] = mod
		return mod
	end
	return nil
end

-- pcall with a timeout; the call runs in its own thread so a hung DataStore never blocks the caller.
local function callWithTimeout(fn: () -> any, timeout: number): (boolean, any)
	local done = false
	local okResult = false
	local value: any = nil
	task.spawn(function()
		local ok, res = pcall(fn)
		okResult = ok
		value = res
		done = true
	end)
	local startT = os.clock()
	while not done and (os.clock() - startT) < timeout do
		task.wait(0.1)
	end
	if not done then
		return false, "timeout"
	end
	return okResult, value
end

local function retry(fn: () -> any): (boolean, any)
	local lastErr: any = nil
	for attempt = 1, ATTEMPTS do
		local ok, res = pcall(fn)
		if ok then
			return true, res
		end
		lastErr = res
		if attempt < ATTEMPTS then
			task.wait(1)
		end
	end
	return false, lastErr
end

local function normalise(raw: any): any
	local data = { Cash = 0, TotalEarned = 0, Rebirths = 0, Upgrades = {} }
	if type(raw) == "table" then
		if type(raw.Cash) == "number" then
			data.Cash = math.max(0, math.floor(raw.Cash))
		end
		if type(raw.TotalEarned) == "number" then
			data.TotalEarned = math.max(0, math.floor(raw.TotalEarned))
		end
		if type(raw.Rebirths) == "number" then
			data.Rebirths = math.max(0, math.floor(raw.Rebirths))
		end
		if type(raw.Upgrades) == "table" then
			for _, id in raw.Upgrades do
				if type(id) == "string" then
					table.insert(data.Upgrades, id)
				end
			end
		end
	end
	return data
end

local function copyData(d: any): any
	return normalise(d)
end

local function getStat(player: Player, name: string): any
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		return nil
	end
	local v = ls:FindFirstChild(name)
	if v and (v:IsA("IntValue") or v:IsA("NumberValue")) then
		return v
	end
	return nil
end

function DataService.loadPlayer(player: Player)
	local key = keyFor(player)
	local raw: any = nil
	if not useMemory and store then
		-- single attempt, hard cap so loading never stalls the claim
		local ok, res = callWithTimeout(function()
			return store:GetAsync(key)
		end, LOAD_TIMEOUT)
		if ok then
			raw = res
		else
			switchToMemory()
			raw = memory[key]
		end
	else
		raw = memory[key]
	end
	if not player.Parent then
		return
	end
	cache[player] = normalise(raw)
	loaded[player] = true
	if not countedLoad[player] then
		countedLoad[player] = true
		ForgeTelemetry.count("data_loaded", 1)
	end
	loadedEvent:Fire(player)
end

function DataService.applyPlayer(player: Player)
	local data = cache[player]
	if not data then
		data = normalise(nil)
		cache[player] = data
	end
	local ls = player:FindFirstChild("leaderstats") or player:WaitForChild("leaderstats", 3)
	if ls then
		local cash = getStat(player, "Cash")
		if cash then
			cash.Value = data.Cash
		end
		local total = getStat(player, "TotalEarned")
		if total then
			total.Value = data.TotalEarned
		end
		local rb = getStat(player, "Rebirths")
		if rb then
			rb.Value = data.Rebirths
		end
	end
	player:SetAttribute("TotalEarned", data.TotalEarned)

	local rebirth = getService("RebirthService")
	if rebirth and type(rebirth.restoreRebirths) == "function" then
		pcall(rebirth.restoreRebirths, player, data.Rebirths)
	end
	local upgrades = getService("UpgradeService")
	if upgrades and type(upgrades.restoreOwned) == "function" then
		pcall(upgrades.restoreOwned, player, table.clone(data.Upgrades))
	end
end

local function snapshot(player: Player): any
	local data = cache[player] or normalise(nil)
	local snap = copyData(data)
	local cash = getStat(player, "Cash")
	if cash then
		snap.Cash = math.max(0, math.floor(cash.Value))
	end
	local total = getStat(player, "TotalEarned")
	if total then
		snap.TotalEarned = math.max(0, math.floor(total.Value))
	else
		local attr = player:GetAttribute("TotalEarned")
		if type(attr) == "number" then
			snap.TotalEarned = math.max(0, math.floor(attr))
		end
	end
	local rb = getStat(player, "Rebirths")
	if rb then
		snap.Rebirths = math.max(0, math.floor(rb.Value))
	end
	local upgrades = getService("UpgradeService")
	if upgrades and type(upgrades.getOwnedIds) == "function" then
		local ok, ids = pcall(upgrades.getOwnedIds, player)
		if ok and type(ids) == "table" then
			local list = {}
			for _, id in ids do
				if type(id) == "string" then
					table.insert(list, id)
				end
			end
			snap.Upgrades = list
		end
	end
	return snap
end

function DataService.savePlayer(player: Player)
	if not loaded[player] or saving[player] then
		return
	end
	saving[player] = true
	local snap = snapshot(player)
	cache[player] = copyData(snap)
	local key = keyFor(player)
	local saved = false
	if not useMemory and store then
		local ok = retry(function()
			local okCall, err = callWithTimeout(function()
				store:UpdateAsync(key, function()
					return snap
				end)
				return true
			end, SAVE_TIMEOUT)
			if not okCall then
				error(err)
			end
			return true
		end)
		if ok then
			saved = true
		else
			switchToMemory()
		end
	end
	if not saved then
		memory[key] = copyData(snap)
		saved = true
	end
	saving[player] = nil
	if saved then
		ForgeTelemetry.count("data_saved", 1)
	end
end

-- Idempotent final save: PlayerRemoving and BindToClose can both call it, only one save happens.
local function finalSave(player: Player)
	local state = finalState[player]
	if state == "done" then
		return
	end
	if state == "running" then
		local t = 0
		while finalState[player] == "running" and t < 30 do
			task.wait(0.25)
			t += 0.25
		end
		return
	end
	finalState[player] = "running"
	local waited = 0
	while saving[player] and waited < 10 do
		task.wait(0.25)
		waited += 0.25
	end
	pcall(DataService.savePlayer, player)
	finalState[player] = "done"
end

function DataService.init()
	if initialized then
		return
	end
	initialized = true

	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok and ds then
		store = ds
	else
		switchToMemory()
	end

	task.spawn(function()
		while true do
			task.wait(60)
			for _, player in Players:GetPlayers() do
				if loaded[player] and not finalState[player] then
					task.spawn(DataService.savePlayer, player)
				end
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		finalSave(player)
		cache[player] = nil
		loaded[player] = nil
		saving[player] = nil
		countedLoad[player] = nil
		finalState[player] = nil
	end)

	game:BindToClose(function()
		local list = {}
		for player in loaded do
			if finalState[player] ~= "done" then
				table.insert(list, player)
			end
		end
		local pending = #list
		for _, player in list do
			task.spawn(function()
				finalSave(player)
				pending -= 1
			end)
		end
		local t = 0
		while pending > 0 and t < 25 do
			task.wait(0.25)
			t += 0.25
		end
	end)
end

return DataService
