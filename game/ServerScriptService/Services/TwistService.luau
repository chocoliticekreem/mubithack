--!strict
-- TwistService [owner: Twists]. Every call feels different (Tizyz rule #4): each non-rookie call rolls ONE
-- twist at dispatch (Config/TwistConfig: Weights, Defs). Twists only reuse systems that already exist,
-- never block finishing the call, and a rookie call (GameConfig.Rookie, the first 2 calls) never has one.
--   cat      CAT IN A TREE: HazardService's cat_tree (a tree by the apron, a cat on the branch, ladder up).
--            Here the cat is a BONUS rescue (attr Bonus): MissionService doesn't wait for it.
--   windy    WINDY DAY: EventService wind_gust on arrival, again every TwistConfig.Events.windy.every s
--   rainy    RAINY DAY: EventService rainstorm (fires get water, the squad cools), repeating
--   night    NIGHT CALL: AtmosphereService:SetPlayerPreset(NightPreset) for the squad until the call ends;
--            TwistController lights a helmet torch
--   news     TV CREW IS HERE: EventService news_heli, repeating; an all-clear within NewsParSeconds gives
--            every squad member NewsBonusXp
--   raccoon  SNEAKY RACCOON: EventService raccoon (steals a nozzle), repeating
-- A call whose mission already has a twist (MissionCatalog hazards grease_fire / gas_leak / pileup /
-- cat_tree) announces that one instead of rolling a second.
-- Speed run: MissionService calls :OnResults(runId, payload) just before the results go out. It adds
--   payload.bestSeconds (this server's fastest all-clear at this site, this call included) and
--   payload.newRecord (this call set it); ResultsController shows one line under TIME.
-- Writes: Player attr Twist (id while on a twisted call, nil after); Workspace.Runs.<runId> attr Twist.
-- Consumes (nil-guarded): MissionService (MissionStarted, MissionEnded, GetMission), EventService:Force,
--   HazardService:_twist, AtmosphereService:SetPlayerPreset, DataService:AddXp, FunnelService:LogCustom
-- Counters: twist_rolled, twist_rolled_<id>, twist_completed, twist_completed_<id>, twist_rookie_skip,
--   twist_events, call_time (sum of seconds), calls_timed, call_records
-- Funnel custom events: TwistRolled / TwistCompleted (CustomField01 = twist id), CallTime (value =
--   seconds, CustomField01 = twist id or "none")
-- Test hooks (DevHook only): _force(twistId) (the next call gets it, rookie or not; "" clears),
--   _apply(runId?, twistId) (twist a live call now), _state() -> JSON, _selftest()
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local TwistConfig = require(ConfigDir:WaitForChild("TwistConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigDir:WaitForChild("MissionCatalog") :: ModuleScript) :: { any }
local TwistRules = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Twist"):WaitForChild("TwistRules") :: ModuleScript)

local TwistService = {}
TwistService.Priority = 80 -- after MissionService (60), EventService (75)

local ATTR = "Twist"

type Run = {
	id: string,
	twist: string,
	players: { Player },
	arrivedAt: number?,
	nextAt: number?,
	events: number,
}

local services: { [string]: any } = {}
local runs: { [string]: Run } = {}
local lastTwist: { [number]: string } = {} -- UserId -> the twist of their last call (no repeats)
local best: { [string]: number } = {} -- site (or mission) id -> fastest all-clear seconds on this server
local forcedNext: string? = nil
local rng = Random.new()

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function call(svc: string, method: string, ...: any): any
	local s = services[svc]
	if s and type(s[method]) == "function" then
		local ok, res = pcall(s[method], s, ...)
		if ok then
			return res
		end
		warn(`[TwistService] {svc}:{method} failed: {res}`)
	end
	return nil
end

local function funnel(players: { Player }, event: string, value: number, field: string)
	for _, p in players do
		call("FunnelService", "LogCustom", p, event, value, field)
	end
end

local function findDef(missionId: string?): any
	for _, m in MissionCatalog do
		if m.id == missionId then
			return m
		end
	end
	return nil
end

local function runFolder(runId: string): Instance?
	local f = workspace:FindFirstChild("Runs")
	return f and f:FindFirstChild(runId)
end

local function playersOf(m: any): { Player }
	local out = {}
	for _, uid in (m and m.players) or {} do
		local p = Players:GetPlayerByUserId(uid)
		if p then
			table.insert(out, p)
		end
	end
	return out
end

-- the cat the cat_tree hazard just spawned for this run: a bonus rescue
local function markBonusCat(runId: string): boolean
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.InstanceId) == runId and m:GetAttribute("Variant") == "TreeCat" then
			m:SetAttribute("Bonus", true)
			return true
		end
	end
	return false
end

local function catSaved(runId: string): boolean
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.InstanceId) == runId and m:GetAttribute("Variant") == "TreeCat" then
			return m:GetAttribute(Names.Attr.RescueState) == "Rescued"
		end
	end
	return false
end

local function release(r: Run, p: Player)
	if p.Parent and p:GetAttribute(ATTR) == r.twist then
		p:SetAttribute(ATTR, nil)
	end
	if r.twist == "night" then
		call("AtmosphereService", "SetPlayerPreset", p, nil)
	end
end

-- put a twist on a run (at dispatch, or live through the _apply hook)
local function apply(runId: string, twist: string, players: { Player }): boolean
	if not TwistConfig.Defs[twist] then
		return false
	end
	local old = runs[runId]
	if old then
		for _, p in old.players do
			release(old, p)
		end
	end
	local r: Run = { id = runId, twist = twist, players = players, events = 0 }
	runs[runId] = r
	local folder = runFolder(runId)
	if folder then
		folder:SetAttribute(ATTR, twist)
	end
	for _, p in players do
		p:SetAttribute(ATTR, twist)
		lastTwist[p.UserId] = twist
	end
	if twist == "cat" then
		if call("HazardService", "_twist", runId, "cat_tree") == true then
			markBonusCat(runId)
		else
			warn(`[TwistService] {runId}: cat tree didn't arm`)
		end
	elseif twist == "night" then
		for _, p in players do
			call("AtmosphereService", "SetPlayerPreset", p, TwistConfig.NightPreset)
		end
	end
	count("twist_rolled")
	count(`twist_rolled_{twist}`)
	funnel(players, "TwistRolled", 1, twist)
	print(`[TwistService] {runId}: twist {twist}`)
	return true
end

local function onDispatch(runId: string)
	if not TwistConfig.Enabled then
		return
	end
	local Mission = services.MissionService
	local m = if Mission and type(Mission.GetMission) == "function" then Mission:GetMission(runId) else nil
	if not m then
		return
	end
	local players = playersOf(m)
	if #players == 0 then
		return
	end
	local twist: string? = forcedNext
	forcedNext = nil
	if not twist then
		if (m :: any).rookie == true then
			count("twist_rookie_skip")
			return
		end
		local def = findDef(m.missionId)
		twist = TwistRules.builtIn(def and def.hazards, TwistConfig.BuiltIn)
			or TwistRules.pick(TwistConfig.Weights, rng:NextNumber(), lastTwist[players[1].UserId])
	end
	if twist then
		apply(runId, twist, players)
	end
end

-- repeating crazy events behind a twist; players who left the call drop the twist
local function tick()
	local Mission = services.MissionService
	local now = os.clock()
	for id, r in runs do
		for i = #r.players, 1, -1 do
			local p = r.players[i]
			if p.Parent == nil or p:GetAttribute(Names.Attr.InstanceId) ~= id then
				release(r, p)
				table.remove(r.players, i)
			end
		end
		local ev = TwistConfig.Events[r.twist]
		local m = if Mission and type(Mission.GetMission) == "function" then Mission:GetMission(id) else nil
		if not (ev and m) or tostring((m :: any).roundState) ~= "Active" then
			continue
		end
		if not r.arrivedAt then
			r.arrivedAt = now
			r.nextAt = now + (tonumber(ev.first) or 5)
		end
		if r.nextAt and now >= r.nextAt then
			local ok = call("EventService", "Force", id, ev.event)
			if ok == true then
				r.events += 1
				count("twist_events")
				r.nextAt = now + (tonumber(ev.every) or 45)
			else
				r.nextAt = now + TwistConfig.RetrySeconds
			end
		end
	end
end

local function onEnded(runId: string)
	local r = runs[runId]
	runs[runId] = nil
	if r then
		for _, p in r.players do
			release(r, p)
		end
	end
end

----------------------------------------------------------------------------------------------- public

-- Called by MissionService right before the results go out: the speed run + twist telemetry.
function TwistService:OnResults(runId: string, payload: any)
	if type(payload) ~= "table" then
		return
	end
	local Mission = services.MissionService
	local m = if Mission and type(Mission.GetMission) == "function" then Mission:GetMission(runId) else nil
	local players = playersOf(m)
	local seconds = tonumber(payload.seconds) or 0
	local won = payload.reason == "allOut" and (tonumber(payload.burningAtEnd) or 0) == 0
	local key = tostring(payload.siteId or payload.missionId or "?")
	local newBest, isNew = TwistRules.record(best[key], seconds, won)
	best[key] = newBest
	payload.bestSeconds = newBest
	payload.newRecord = isNew
	local r = runs[runId]
	payload.twist = if r then r.twist else nil
	count("call_time", seconds)
	count("calls_timed")
	if isNew then
		count("call_records")
	end
	funnel(players, "CallTime", seconds, if r then r.twist else "none")
	if not r then
		return
	end
	local done = won and (r.twist ~= "cat" or catSaved(runId))
	if done then
		count("twist_completed")
		count(`twist_completed_{r.twist}`)
		funnel(players, "TwistCompleted", 1, r.twist)
		if r.twist == "news" and seconds <= TwistConfig.NewsParSeconds then
			for _, p in players do
				call("DataService", "AddXp", p, TwistConfig.NewsBonusXp, "TV crew bonus")
			end
			payload.twistBonusXp = TwistConfig.NewsBonusXp
		end
	end
end

function TwistService:GetTwist(runId: string): string?
	local r = runs[runId]
	return r and r.twist
end

function TwistService:Init(all: { [string]: any })
	services = all
end

function TwistService:Start()
	local Mission = services.MissionService
	if Mission and Mission.MissionStarted then
		Mission.MissionStarted:Connect(function(runId: string)
			local ok, err = pcall(onDispatch, runId)
			if not ok then
				warn(`[TwistService] dispatch {runId}: {err}`)
			end
		end)
	end
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(runId: string)
			onEnded(runId)
		end)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		lastTwist[p.UserId] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(1)
			local ok, err = pcall(tick)
			if not ok then
				warn(`[TwistService] tick: {err}`)
			end
		end
	end)
end

------------------------------------------------------------------------------------------- test hooks

function TwistService:_force(twistId: string?): boolean
	if twistId == nil or twistId == "" then
		forcedNext = nil
		return true
	end
	if not TwistConfig.Defs[twistId] then
		return false
	end
	forcedNext = twistId
	return true
end

function TwistService:_apply(runId: string?, twistId: string): boolean
	local Mission = services.MissionService
	local list = if Mission and type(Mission.GetMissions) == "function" then Mission:GetMissions() else {}
	local id = runId
	if not id and #list > 0 then
		id = list[#list].instanceId
	end
	local m = if id and Mission then Mission:GetMission(id) else nil
	return m ~= nil and apply(id :: string, twistId, playersOf(m))
end

function TwistService:_state(): string
	local out = { forced = forcedNext, best = best, runs = {} }
	for id, r in runs do
		local names = {}
		for _, p in r.players do
			table.insert(names, p.Name)
		end
		out.runs[id] = { twist = r.twist, players = names, events = r.events, arrived = r.arrivedAt ~= nil }
	end
	return HttpService:JSONEncode(out)
end

function TwistService:_selftest(): (boolean, string)
	for id, w in TwistConfig.Weights do
		if w > 0 and not TwistConfig.Defs[id] then
			return false, `TwistConfig.Defs has no {id}`
		end
	end
	for _, ev in TwistConfig.Events do
		local E = services.EventService
		if E and type(E.Ids) == "table" and not table.find(E.Ids, ev.event) then
			return false, `EventService has no {ev.event}`
		end
	end
	return true, `{#TwistRules.order(TwistConfig.Weights)} twists wired`
end

return TwistService
