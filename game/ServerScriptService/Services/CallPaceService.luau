--!strict
-- CallPaceService [owner: G1 fire]. Measures how a call FEELS to fight, per player and device, so "the
-- fires sit there, nothing happens, then they come back" can be checked in live data:
--   hit ticks   spray ticks that hit a burning part (FireService.Doused)
--   fires out   burning parts this player put out (FireService.Extinguished by them)
--   reignites   put-out parts at the call's site that caught again (FireService.Relit; 0 while
--               FireConfig.DousedStaysOut is on)
--   idle        seconds on scene (run Active) with no burning fire within IdleRadius of the player
-- At MissionEnded every squad member gets four FunnelService:LogCustomFields events (Funnel.Events
-- FireHitTicks / FiresOutOnCall / ReignitesOnCall / IdleSecondsOnCall; CustomField01 = device,
-- CustomField02 = rookie | call), plus ForgeTelemetry counters call_fire_hit_ticks, call_fires_out,
-- call_reignites, call_idle_seconds, calls_paced.
-- Consumes (nil-guarded): FireService.Doused/.Extinguished/.Relit, MissionService:GetMissions +
--   .MissionEnded, MapService:GetInstance, FunnelService:LogCustomFields/DeviceOf.
-- Test hooks (DevHook only): _stats() -> JSON of the live runs and the last 5 finished ones.
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)

local CallPaceService = {}
CallPaceService.Priority = 96 -- after FireService (50), MissionService (60), FunnelService (95)
CallPaceService.IdleRadius = 70 -- studs: a fire this close counts as "something to do"
CallPaceService.SampleSeconds = 1

type PlayerStat = { hits: number, outs: number, idle: number }
type RunStat = {
	id: string,
	rookie: boolean,
	reignites: number,
	players: { [number]: PlayerStat },
}

local services: { [string]: any } = {}
local live: { [string]: RunStat } = {}
local finished: { any } = {}

local function runOf(player: Player): RunStat?
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local r = live[id]
	if not r then
		r = { id = id, rookie = false, reignites = 0, players = {} }
		live[id] = r
	end
	return r
end

local function statOf(r: RunStat, userId: number): PlayerStat
	local s = r.players[userId]
	if not s then
		s = { hits = 0, outs = 0, idle = 0 }
		r.players[userId] = s
	end
	return s
end

local function sample()
	local Mission, Map = services.MissionService, services.MapService
	if not (Mission and Map and type(Mission.GetMissions) == "function" and type(Map.GetInstance) == "function") then
		return
	end
	local ok, list = pcall(Mission.GetMissions, Mission)
	if not ok or type(list) ~= "table" then
		return
	end
	local dt = CallPaceService.SampleSeconds
	local r2 = CallPaceService.IdleRadius ^ 2
	for _, m in list do
		local id = m.instanceId
		if type(id) ~= "string" then
			continue
		end
		local r = live[id]
		if not r then
			r = { id = id, rookie = m.rookie == true, reignites = 0, players = {} }
			live[id] = r
		end
		r.rookie = m.rookie == true
		if m.roundState ~= "Active" then
			continue
		end
		local okSite, site = pcall(Map.GetInstance, Map, id)
		local fires: { Vector3 } = {}
		if okSite and typeof(site) == "Instance" then
			for _, b in CollectionService:GetTagged(Names.Tag.Burning) do
				if b:IsA("BasePart") and b:IsDescendantOf(site) then
					table.insert(fires, b.Position)
				end
			end
		end
		for _, uid in m.players or {} do
			local p = Players:GetPlayerByUserId(uid)
			local root = p and p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root then
				continue
			end
			local near = false
			for _, pos in fires do
				local d = pos - root.Position
				if d:Dot(d) <= r2 then
					near = true
					break
				end
			end
			if not near then
				statOf(r, uid).idle += dt
			end
		end
	end
end

local function finish(instanceId: string)
	local r = live[instanceId]
	live[instanceId] = nil
	if not r then
		return
	end
	local Funnel = services.FunnelService
	local kind = if r.rookie then "rookie" else "call"
	local summary = { id = instanceId, rookie = r.rookie, reignites = r.reignites, players = {} }
	Telemetry.count("calls_paced")
	Telemetry.count("call_reignites", r.reignites)
	for uid, s in r.players do
		local idle = math.floor(s.idle + 0.5)
		Telemetry.count("call_fire_hit_ticks", s.hits)
		Telemetry.count("call_fires_out", s.outs)
		Telemetry.count("call_idle_seconds", idle)
		local p = Players:GetPlayerByUserId(uid)
		local device = "Unknown"
		if p and Funnel and type(Funnel.LogCustomFields) == "function" then
			pcall(function()
				device = Funnel:DeviceOf(p)
				Funnel:LogCustomFields(p, "FireHitTicks", s.hits, device, kind)
				Funnel:LogCustomFields(p, "FiresOutOnCall", s.outs, device, kind)
				Funnel:LogCustomFields(p, "ReignitesOnCall", r.reignites, device, kind)
				Funnel:LogCustomFields(p, "IdleSecondsOnCall", idle, device, kind)
			end)
		end
		summary.players[tostring(uid)] = { hits = s.hits, outs = s.outs, idle = idle, device = device }
	end
	table.insert(finished, 1, summary)
	if #finished > 5 then
		table.remove(finished)
	end
end

function CallPaceService:Init(all: { [string]: any })
	services = all
end

function CallPaceService:Start()
	local Fire = services.FireService
	if Fire then
		if Fire.Doused then
			Fire.Doused:Connect(function(player: Player, hits: number)
				local r = runOf(player)
				if r then
					statOf(r, player.UserId).hits += 1
				end
			end)
		end
		if Fire.Extinguished then
			Fire.Extinguished:Connect(function(_part: BasePart, by: Player?)
				local r = by and runOf(by)
				if r and by then
					statOf(r, by.UserId).outs += 1
				end
			end)
		end
		if Fire.Relit then
			Fire.Relit:Connect(function(part: BasePart)
				local Map = services.MapService
				for id, r in live do
					local ok, site = pcall(function()
						return Map and Map:GetInstance(id)
					end)
					if ok and typeof(site) == "Instance" and part:IsDescendantOf(site) then
						r.reignites += 1
						return
					end
				end
			end)
		end
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string)
			finish(instanceId)
		end)
	end
	task.spawn(function()
		while true do
			task.wait(CallPaceService.SampleSeconds)
			local ok, err = pcall(sample)
			if not ok then
				warn(`[CallPaceService] sample failed: {err}`)
			end
		end
	end)
end

function CallPaceService:_stats(): string
	local out = {}
	for id, r in live do
		local ps = {}
		for uid, s in r.players do
			ps[tostring(uid)] = { hits = s.hits, outs = s.outs, idle = math.floor(s.idle) }
		end
		out[id] = { rookie = r.rookie, reignites = r.reignites, players = ps }
	end
	return HttpService:JSONEncode({ live = out, finished = finished })
end

return CallPaceService
