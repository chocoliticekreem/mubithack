--!strict
-- MissionGuideService [owner: Onboarding]. Server half of the first-time mission guides
-- (Controllers/MissionGuideController draws them; copy in Config/MissionGuides; logic in
-- Lib/Onboarding/GuideFlow). Remembers, per player, which mission types they've had the guide for
-- (DataService profile guides.seen, schema v4) and tells each squad member how to run this call:
--   * MissionService.MissionStarted(runId, missionId): every player in the run gets
--       GuideMode    = "full" if ANYONE in the squad is new to this mission (the veteran helps), else "tip"
--       GuideRookies = "Ana, Bo" (who is new; "" when nobody is)
--       GuideMission = missionId (set last: the client starts on this change)
--   * MissionService.MissionEnded(runId): everyone who played it is marked seen; the attrs clear.
--   * MissionGuide/Seen (C->S, missionId: string, 1/s): the guide finished or was skipped -> seen now.
--
-- Public API:
--   MissionGuideService:HasSeen(player, missionId): boolean
--   MissionGuideService:MarkSeen(player, missionId): boolean   -- true = newly marked
-- Counters: guide_full, guide_tip, guide_seen
-- Test hooks (DevHook only): _reset(player, missionId?) (forget one / every guide), _seen(player): string,
--   _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Guides = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MissionGuides") :: ModuleScript) :: any
local GuideFlow = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("GuideFlow") :: ModuleScript)
local Schema = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

local MissionGuideService = {}
MissionGuideService.Priority = 65 -- after MissionService (60)

local ATTR_MISSION = "GuideMission"
local ATTR_MODE = "GuideMode"
local ATTR_ROOKIES = "GuideRookies"

local services: { [string]: any } = {}
local runs: { [string]: { missionId: string, players: { Player } } } = {}
local pending: { [Player]: { [string]: boolean } } = {} -- seen marks made before the profile loaded

local function count(name: string)
	pcall(Telemetry.count, name, 1)
end

local function profileOf(player: Player, wait: number?): any
	local Data = services.DataService
	if not Data then
		return nil
	end
	if wait and type(Data.WaitForProfile) == "function" then
		local ok, p = pcall(Data.WaitForProfile, Data, player, wait)
		return if ok then p else nil
	end
	local ok, p = pcall(Data.GetProfile, Data, player)
	return if ok then p else nil
end

function MissionGuideService:HasSeen(player: Player, missionId: string): boolean
	if pending[player] and pending[player][missionId] then
		return true
	end
	local p = profileOf(player)
	return p ~= nil and Schema.guideSeen(p, missionId)
end

function MissionGuideService:MarkSeen(player: Player, missionId: string): boolean
	if type(missionId) ~= "string" or Guides.Missions[missionId] == nil then
		return false
	end
	if self:HasSeen(player, missionId) then
		return false
	end
	local Data = services.DataService
	local wrote = false
	if Data and type(Data.Update) == "function" then
		local ok, res = pcall(Data.Update, Data, player, function(p: any)
			Schema.markGuideSeen(p, missionId)
		end)
		wrote = ok and res == true
	end
	if not wrote then
		-- no profile (yet): remember for this session so the next run is a tip
		pending[player] = pending[player] or {}
		pending[player][missionId] = true
	end
	count("guide_seen")
	return true
end

local function onStarted(runId: string, missionId: string)
	local Mission = services.MissionService
	local ok, run = pcall(function()
		return Mission and Mission:GetMission(runId)
	end)
	local squad: { Player } = {}
	if ok and type(run) == "table" and type(run.players) == "table" then
		for _, uid in run.players do
			local p = Players:GetPlayerByUserId(uid)
			if p then
				table.insert(squad, p)
			end
		end
	end
	if #squad == 0 then
		return
	end
	runs[runId] = { missionId = missionId, players = squad }
	task.spawn(function()
		local seen: { boolean } = {}
		local rookies: { string } = {}
		for _, p in squad do
			profileOf(p, 5) -- make sure it's loaded before we decide
			local s = MissionGuideService:HasSeen(p, missionId)
			table.insert(seen, s)
			if not s then
				table.insert(rookies, p.DisplayName)
			end
		end
		local mode = GuideFlow.modeFor(seen)
		count(if mode == "full" then "guide_full" else "guide_tip")
		for _, p in squad do
			if p.Parent == Players and p:GetAttribute("InstanceId") == runId then
				p:SetAttribute(ATTR_MODE, mode)
				p:SetAttribute(ATTR_ROOKIES, table.concat(rookies, ", "))
				p:SetAttribute(ATTR_MISSION, missionId)
			end
		end
	end)
end

local function clear(p: Player)
	p:SetAttribute(ATTR_MISSION, "")
	p:SetAttribute(ATTR_MODE, "")
	p:SetAttribute(ATTR_ROOKIES, "")
end

local function onEnded(runId: string)
	local r = runs[runId]
	runs[runId] = nil
	if not r then
		return
	end
	for _, p in r.players do
		if p.Parent == Players then
			MissionGuideService:MarkSeen(p, r.missionId)
			if p:GetAttribute(ATTR_MISSION) == r.missionId then
				clear(p)
			end
		end
	end
end

function MissionGuideService:Init(all: { [string]: any })
	services = all
end

function MissionGuideService:Start()
	local Mission = services.MissionService
	if Mission and Mission.MissionStarted then
		Mission.MissionStarted:Connect(onStarted)
		Mission.MissionEnded:Connect(function(runId: string)
			onEnded(runId)
		end)
	end
	Net.onServer(Net.event("MissionGuide", "Seen"), { rate = 1, burst = 2 }, function(player: Player, missionId: any)
		if type(missionId) == "string" and player:GetAttribute(ATTR_MISSION) == missionId then
			MissionGuideService:MarkSeen(player, missionId)
		end
	end)
	Players.PlayerRemoving:Connect(function(p: Player)
		pending[p] = nil
	end)
end

------------------------------------------------------------------------------------------ test hooks

function MissionGuideService:_reset(player: Player, missionId: string?)
	pending[player] = nil
	local Data = services.DataService
	if Data and type(Data.Update) == "function" then
		pcall(Data.Update, Data, player, function(p: any)
			if type(p.guides) == "table" and type(p.guides.seen) == "table" then
				if missionId then
					p.guides.seen[missionId] = nil
				else
					p.guides.seen = {}
				end
			end
		end)
	end
end

function MissionGuideService:_seen(player: Player): string
	local out = {}
	for id in Guides.Missions do
		if self:HasSeen(player, id) then
			table.insert(out, id)
		end
	end
	table.sort(out)
	return table.concat(out, ",")
end

function MissionGuideService:_selftest(): (boolean, string)
	local Catalog = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MissionCatalog") :: ModuleScript) :: any
	local problems = GuideFlow.validate(Guides, Catalog)
	if #problems > 0 then
		return false, table.concat(problems, "; ")
	end
	return true, `{#Catalog} missions have guides`
end

return MissionGuideService
