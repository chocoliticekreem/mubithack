--!strict
-- DataService [owner: Data]. The game's "DB": one versioned profile per player on DataStoreService,
-- with a session lock so two servers never write the same player. Contract: docs/game/06-data.md.
--
-- Public API (call through services.DataService, nil-guarded):
--   DataService:GetProfile(player): ProfileSchema.Profile?     -- LIVE table; read it, don't mutate it
--   DataService:WaitForProfile(player, timeout: number?): Profile?
--   DataService:Update(player, fn: (Profile) -> ()): boolean   -- the only way to change a profile
--   DataService:AddXp(player, amount: number, reason: string?): number   -- XP actually given
--   DataService:RecordMission(player, missionId: string, results: Types.ResultsPayload): MissionSummary?
--   DataService:Equip(player, slot: "helmet" | "hose", id: string): boolean
--   DataService:IsPersistent(): boolean                        -- false = in-memory store (Studio)
-- Signals (pure Signal, the live profile is never copied):
--   ProfileLoaded(player), XpGained(player, amount, reason), LevelUp(player, level),
--   MissionRecorded(player, missionId, summary), StatsChanged(player)  -- leaderboard stats moved
-- Consumes (Start, nil-guarded): MissionService.MissionEnded / .RoundEnded, RescueService.Rescued
-- Remotes: Data/XpGained (S->C owner: amount, reason, level, levelsGained)
--          Data/Equip (C->S: slot, id; 2/s), Data/Setting (C->S: key, value; 4/s)
-- Writes: Player attrs DataConfig.Attr.* (Level, XpIntoLevel, XpForNext, XpTotal, HelmetCosmetic,
--         HoseCosmetic, ProfileReady)
-- Counters: data_loaded, data_load_failed, data_saved, data_save_failed, data_session_lost,
--           data_missions_recorded, xp_awarded
-- Test hooks (DevHook only): _addXp(player, n), _record(player, missionId, stars), _dump(player),
--           _save(player), _selftest()

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local DataConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DataConfig") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Schema = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

type Profile = Schema.Profile
type Store = {
	kind: "datastore" | "memory",
	update: (key: string, fn: (old: any) -> (any, { number }?)) -> (boolean, any),
}
type Session = {
	profile: Profile?,
	loading: boolean,
	persist: boolean, -- false = never written (memory fallback, lock failure, newer schema)
	saving: boolean,
	lost: boolean, -- another server took our lock; stop saving
}

local DataService = {}
DataService.Priority = 20
DataService.ProfileLoaded = Signal.new() :: Signal.Signal<Player>
DataService.XpGained = Signal.new() :: Signal.Signal<Player, number, string>
DataService.LevelUp = Signal.new() :: Signal.Signal<Player, number>
DataService.MissionRecorded = Signal.new() :: Signal.Signal<Player, string, Schema.MissionSummary>
DataService.StatsChanged = Signal.new() :: Signal.Signal<Player>

local services: { [string]: any } = {}
local sessions: { [Player]: Session } = {}
local store: Store? = nil
local jobId = ""
local closing = false
local xpRemote: RemoteEvent? = nil
local recorded = setmetatable({}, { __mode = "k" }) :: { [any]: boolean } -- results tables already recorded

------------------------------------------------------------------------------------------ stores

local function deepCopy(v: any): any
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in v do
		out[k] = deepCopy(x)
	end
	return out
end

-- Same contract as GlobalDataStore:UpdateAsync, kept in this server's memory. Copies in and out so
-- code behaves as if the value were serialized (no shared references with the live profile).
local function memoryStore(): Store
	local data: { [string]: any } = {}
	return {
		kind = "memory",
		update = function(key: string, fn: (any) -> (any, { number }?)): (boolean, any)
			local ok, new = pcall(fn, deepCopy(data[key]))
			if not ok then
				return false, new
			end
			if new ~= nil then
				data[key] = deepCopy(new)
			end
			return true, deepCopy(new)
		end,
	}
end

local function dataStore(ds: GlobalDataStore): Store
	return {
		kind = "datastore",
		update = function(key: string, fn: (any) -> (any, { number }?)): (boolean, any)
			return pcall(function()
				return ds:UpdateAsync(key, function(old: any)
					return fn(old)
				end)
			end)
		end,
	}
end

local function chooseStore(): Store
	if RunService:IsStudio() and DataConfig.UseMemoryInStudio then
		print("[DataService] Studio: in-memory profiles (DataConfig.UseMemoryInStudio)")
		return memoryStore()
	end
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(DataConfig.StoreName)
	end)
	if ok and RunService:IsStudio() then
		-- In Studio without "Enable Studio Access to API Services" every request errors; probe once.
		ok = pcall(function()
			return (ds :: GlobalDataStore):GetAsync("__probe")
		end)
	end
	if not ok then
		warn(
			"[DataService] DataStores unavailable; profiles are in memory and WILL NOT SAVE. In Studio enable "
				.. "Game Settings -> Security -> Enable Studio Access to API Services."
		)
		return memoryStore()
	end
	return dataStore(ds :: GlobalDataStore)
end

local function waitBudget(requestType: Enum.DataStoreRequestType)
	local s = store
	if not s or s.kind ~= "datastore" then
		return
	end
	local deadline = os.clock() + (if closing then 1 else DataConfig.BudgetWaitSeconds)
	while os.clock() < deadline do
		local ok, budget = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(requestType)
		end)
		if not ok or budget >= 1 then
			return
		end
		task.wait(0.5)
	end
end

local function backoff(attempt: number)
	task.wait(math.min(DataConfig.RetryMaxSeconds, DataConfig.RetryBaseSeconds * 2 ^ (attempt - 1)))
end

local function keyFor(player: Player): string
	return DataConfig.KeyPrefix .. tostring(player.UserId)
end

--------------------------------------------------------------------------------------- replication

local function refresh(player: Player)
	local s = sessions[player]
	local p = s and s.profile
	if not p then
		return
	end
	local A = DataConfig.Attr
	local level, into, need = Schema.levelForXp(p.xp)
	player:SetAttribute(A.Level, level)
	player:SetAttribute(A.Xp, into)
	player:SetAttribute(A.XpNext, need)
	player:SetAttribute(A.XpTotal, p.xp)
	player:SetAttribute(A.HelmetCosmetic, p.cosmetics.equipped.helmet)
	player:SetAttribute(A.HoseCosmetic, p.cosmetics.equipped.hose)
	player:SetAttribute("GraphicsQuality", math.floor(tonumber(p.settings.graphicsQuality) or 0)) -- ShaderController
	player:SetAttribute("Feedback", math.floor(tonumber(p.settings.feedback) or 0)) -- ClientLib/WorldPopup
	player:SetAttribute(A.ProfileReady, true)
end

local function cosmeticName(id: string): string
	for _, c in DataConfig.Cosmetics do
		if c.id == id then
			return c.name
		end
	end
	return id
end

local function afterXp(player: Player, gained: number, levels: number, reason: string)
	if gained <= 0 then
		return
	end
	local p = (sessions[player] :: Session).profile :: Profile
	Telemetry.count("xp_awarded", gained)
	DataService.XpGained:Fire(player, gained, reason)
	if xpRemote then
		xpRemote:FireClient(player, gained, reason, p.level, levels)
	end
	if levels > 0 then
		DataService.LevelUp:Fire(player, p.level)
		local unlocked = Schema.unlockCosmetics(p, DataConfig.Cosmetics)
		for _, id in unlocked do
			Net.notify(player, `Unlocked: {cosmeticName(id)}!`, "good")
		end
	end
	refresh(player)
end

------------------------------------------------------------------------------------- load / save

local function now(): number
	return os.time()
end

local function save(player: Player, release: boolean): boolean
	local s = sessions[player]
	if not s or not s.profile or not s.persist or s.lost or not store then
		return true
	end
	while s.saving do
		task.wait(0.1)
	end
	s.saving = true
	local profile = s.profile :: Profile
	profile.meta.lastSeen = now()
	local userId = player.UserId
	local key = keyFor(player)
	local saved = false
	for attempt = 1, DataConfig.SaveAttempts do
		waitBudget(Enum.DataStoreRequestType.UpdateAsync)
		local lostWhy: string? = nil
		local ok, res = (store :: Store).update(key, function(old: any)
			lostWhy = nil
			local env, why
			if release then
				env, why = Schema.release(old, jobId, now())
			else
				env, why = Schema.tryLock(old, jobId, now(), DataConfig.LockTtlSeconds)
			end
			if not env then
				lostWhy = why
				return nil
			end
			env.data = profile
			return env, { userId }
		end)
		if lostWhy then
			s.lost = true
			Telemetry.count("data_session_lost")
			warn(`[DataService] {player.Name}: not saving, session lost ({lostWhy})`)
			break
		elseif ok then
			saved = true
			Telemetry.count("data_saved")
			break
		else
			warn(`[DataService] save {player.Name} attempt {attempt}: {res}`)
			if attempt < DataConfig.SaveAttempts and not closing then
				backoff(attempt)
			end
		end
	end
	if not saved and not s.lost then
		Telemetry.count("data_save_failed")
	end
	s.saving = false
	return saved
end

local function load(player: Player)
	local s: Session = { profile = nil, loading = true, persist = false, saving = false, lost = false }
	sessions[player] = s
	local userId = player.UserId
	local key = keyFor(player)
	local profile: Profile? = nil

	for attempt = 1, DataConfig.LoadAttempts do
		if not player.Parent then
			break
		end
		waitBudget(Enum.DataStoreRequestType.UpdateAsync)
		local denied: string? = nil
		local newer: string? = nil
		local ok, res = (store :: Store).update(key, function(old: any)
			denied, newer = nil, nil
			local env, why = Schema.tryLock(old, jobId, now(), DataConfig.LockTtlSeconds)
			if not env then
				denied = why
				return nil
			end
			local p, err = Schema.migrate(env.data, now())
			if not p then
				newer = err
				return nil
			end
			p.meta.lastSeen = now()
			p.meta.sessions += 1
			env.data = p
			return env, { userId }
		end)
		if ok and type(res) == "table" and type(res.data) == "table" then
			profile = Schema.reconcile(res.data, now())
			s.persist = true
			break
		elseif newer then
			warn(`[DataService] {player.Name}: {newer}; playing on a temporary profile`)
			break
		else
			warn(`[DataService] load {player.Name} attempt {attempt}: {denied or res}`)
			if attempt < DataConfig.LoadAttempts then
				backoff(attempt)
			end
		end
	end

	if not player.Parent then
		-- Left while loading: hand the lock straight back.
		if s.persist and profile then
			s.profile = profile
			s.loading = false
			save(player, true)
		end
		sessions[player] = nil
		return
	end
	if not profile then
		Telemetry.count("data_load_failed")
		if DataConfig.KickOnLoadFail then
			player:Kick("Couldn't load your save (another server still has it). Please rejoin in a minute.")
			sessions[player] = nil
			return
		end
		profile = Schema.default(now())
		s.persist = false
		Net.notify(player, "Progress won't save this session (save busy).", "bad")
	end

	local p = profile :: Profile
	Schema.rollWeek(p, Schema.weekId(now()))
	Schema.unlockCosmetics(p, DataConfig.Cosmetics)
	s.profile = p
	s.loading = false
	refresh(player)
	Telemetry.count("data_loaded")
	DataService.ProfileLoaded:Fire(player)
end

------------------------------------------------------------------------------------------ API

function DataService:GetProfile(player: Player): Profile?
	local s = sessions[player]
	return s and s.profile
end

function DataService:WaitForProfile(player: Player, timeout: number?): Profile?
	local deadline = os.clock() + (timeout or 30)
	while os.clock() < deadline and player.Parent do
		local s = sessions[player]
		if s and s.profile then
			return s.profile
		end
		task.wait(0.2)
	end
	return self:GetProfile(player)
end

function DataService:IsPersistent(): boolean
	return store ~= nil and (store :: Store).kind == "datastore"
end

function DataService:Update(player: Player, fn: (Profile) -> ()): boolean
	local s = sessions[player]
	local p = s and s.profile
	if not p then
		return false
	end
	local levelBefore = p.level
	local ok, err = pcall(fn, p)
	if not ok then
		warn(`[DataService] Update {player.Name}: {err}`)
	end
	p.level = (Schema.levelForXp(p.xp))
	if p.level > levelBefore then
		DataService.LevelUp:Fire(player, p.level)
		Schema.unlockCosmetics(p, DataConfig.Cosmetics)
	end
	refresh(player)
	return ok
end

function DataService:AddXp(player: Player, amount: number, reason: string?): number
	local s = sessions[player]
	local p = s and s.profile
	if not p then
		return 0
	end
	local gained, levels = Schema.addXp(p, amount)
	afterXp(player, gained, levels, reason or "XP")
	return gained
end

function DataService:RecordMission(player: Player, missionId: string, results: Types.ResultsPayload): Schema.MissionSummary?
	local s = sessions[player]
	local p = s and s.profile
	if not p or type(missionId) ~= "string" or type(results) ~= "table" then
		return nil
	end
	local summary = Schema.applyMission(p, player.UserId, missionId, results, {
		rewards = DataConfig.Xp,
		blameWeights = DataConfig.BlamePoints,
		winStars = DataConfig.WinStars,
		weekId = Schema.weekId(now()),
	})
	Telemetry.count("data_missions_recorded")
	afterXp(player, summary.xp, summary.levelsGained, if summary.won then "Mission complete" else "Mission played")
	refresh(player)
	DataService.MissionRecorded:Fire(player, missionId, summary)
	DataService.StatsChanged:Fire(player)
	return summary
end

function DataService:Equip(player: Player, slot: string, id: string): boolean
	local s = sessions[player]
	local p = s and s.profile
	if not p or not Schema.equip(p, slot, id) then
		return false
	end
	refresh(player)
	return true
end

-- Record every player in a results payload who is still in the server. Each payload once.
local function recordResults(results: any, missionId: string?)
	if type(results) ~= "table" or recorded[results] then
		return
	end
	recorded[results] = true
	local id = missionId or results.missionId or results.locationId or "unknown"
	for _, st in (if type(results.stats) == "table" then results.stats else {}) :: { any } do
		local player = type(st) == "table" and Players:GetPlayerByUserId(st.userId)
		if player then
			DataService:RecordMission(player, id, results)
		end
	end
end

------------------------------------------------------------------------------------- lifecycle

function DataService:Init(all: { [string]: any })
	services = all
end

function DataService:Start()
	jobId = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
	store = chooseStore()

	xpRemote = Net.event("Data", "XpGained")
	local equip = Net.event("Data", "Equip")
	Net.onServer(equip, { rate = 2, burst = 2 }, function(player: Player, slot: any, id: any)
		if type(slot) == "string" and type(id) == "string" and #id <= 64 then
			DataService:Equip(player, slot, id)
		end
	end)
	local setting = Net.event("Data", "Setting")
	Net.onServer(setting, { rate = 4, burst = 4 }, function(player: Player, key: any, value: any)
		if type(key) ~= "string" then
			return
		end
		DataService:Update(player, function(p)
			Schema.setSetting(p, key, value)
		end)
	end)

	local Mission = services.MissionService
	if Mission then
		if Mission.MissionEnded then
			Mission.MissionEnded:Connect(function(instanceId: string, results: Types.ResultsPayload)
				local run = type(Mission.GetMission) == "function" and Mission:GetMission(instanceId)
				recordResults(results, results and results.missionId or (run and run.missionId) or nil)
			end)
		end
		if Mission.RoundEnded then
			-- v1 single auto-round (LobbyConfig.UseLobby = false). Lobby missions come via MissionEnded.
			Mission.RoundEnded:Connect(function(results: Types.ResultsPayload)
				if type(results) == "table" and results.instanceId == nil then
					recordResults(results, results.missionId)
				end
			end)
		end
	end
	local Rescue = services.RescueService
	if Rescue and Rescue.Rescued then
		Rescue.Rescued:Connect(function(player: Player, _rescueId: string, kind: string)
			if typeof(player) == "Instance" and player:IsA("Player") then
				DataService:Update(player, function(p)
					Schema.rollWeek(p, Schema.weekId(now()))
					Schema.addRescue(p, kind)
				end)
				DataService.StatsChanged:Fire(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(load)
	for _, player in Players:GetPlayers() do
		if not sessions[player] then
			task.spawn(load, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local s = sessions[player]
		if not s or s.loading then
			return -- load() notices the player left and releases the lock itself
		end
		save(player, true)
		sessions[player] = nil
	end)

	game:BindToClose(function()
		closing = true
		local pending = 0
		for player, s in sessions do
			if s.profile and not s.loading then
				pending += 1
				task.spawn(function()
					save(player, true)
					pending -= 1
				end)
			end
		end
		local deadline = os.clock() + DataConfig.BindToCloseSeconds
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
	end)

	while true do
		task.wait(DataConfig.AutosaveSeconds)
		for player, s in sessions do
			if s.profile and s.persist and not s.loading and not s.lost and not closing then
				task.spawn(save, player, false)
				task.wait(0.25) -- spread the requests
			end
		end
	end
end

----------------------------------------------------------------------------------- test hooks

function DataService:_addXp(player: Player, n: number): number
	return self:AddXp(player, n, "Test")
end

function DataService:_record(player: Player, missionId: string, stars: number): any
	return self:RecordMission(player, missionId, {
		locationId = "Town",
		missionId = missionId,
		seconds = 100,
		firesOut = 3,
		burnedParts = 0,
		rescued = 1,
		trapped = 0,
		burningAtEnd = 0,
		stars = stars,
		reason = "allOut",
		awards = {},
		stats = {
			{ userId = player.UserId, helmet = 1, name = player.Name, firesOut = 3, firesStarted = 1, water = 50, doors = 0, rescued = 1, pandas = 0, downedOthers = 0, timesDowned = 0, teammateSprayed = 2 },
		},
	} :: any)
end

function DataService:_dump(player: Player): string
	local p = self:GetProfile(player)
	return if p then HttpService:JSONEncode(p) else "null"
end

function DataService:_save(player: Player): boolean
	return save(player, false)
end

function DataService:_selftest(): (boolean, string)
	-- Lock + migrate round trip on a private memory store (never touches the real DataStore).
	local mem = memoryStore()
	local t = now()
	local ok1, env = mem.update("selftest", function(old)
		local e = Schema.tryLock(old, "A", t, 60)
		if e then
			e.data = Schema.migrate(e.data, t)
		end
		return e
	end)
	if not ok1 or type(env) ~= "table" or type(env.data) ~= "table" then
		return false, "memory store / lock acquire failed"
	end
	local refused = false
	mem.update("selftest", function(old)
		local e = Schema.tryLock(old, "B", t, 60)
		refused = e == nil
		return e
	end)
	if not refused then
		return false, "second server was not refused"
	end
	local ok, json = pcall(HttpService.JSONEncode, HttpService, env.data)
	if not ok or #json < 10 then
		return false, "profile is not serializable"
	end
	local loaded = 0
	for _, s in sessions do
		if s.profile then
			loaded += 1
		end
	end
	return true, `store={store and (store :: Store).kind or "none"} profiles={loaded}`
end

return DataService
