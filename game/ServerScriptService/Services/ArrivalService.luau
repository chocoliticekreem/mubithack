--!strict
-- ArrivalService [owner: G1]. The first seconds on scene (docs/game/21-phone-first-fire.md). Live funnel, 7 days:
-- 23.6% of phone players (9.5% of PC) arrived on scene and left before putting out a single fire.
--   * SPRAY is always there: the first time you stand on your feet on scene (out of the truck), your kit is
--     made spray-ready once (InventoryService:ReadySpray, rules Lib/Fire/SprayAssist.ready): an empty hand
--     gets an extinguisher, a sprayer on your back comes to your hand, an empty extinguisher is refilled.
--     An axe in hand is left alone (CHOP is a choice). Every device.
--   * Telemetry (FunnelService:LogCustomFields, mirrored to TrackService): ArrivalToFireOut (value = seconds
--     from the run going Active to YOUR first fire out on the call; F1 device, F2 rookie | call, F3 touch
--     auto-aim lock bucket) and ArrivalNoFireOut (value = seconds on scene; F2 ended | left; F3 locks) when
--     the call ends or you leave without one. Locks = ToolService.SprayLocked (new burning part locked).
-- Reads: workspace.Runs.<InstanceId> attrs RoundState, Rookie; Player attrs InstanceId, Device;
--   FireService.Extinguished, ToolService.SprayLocked. Training fires (workspace.TrainingFires) never count.
-- Counters: arrival_ready_<action>, arrival_fire_out, arrival_no_fire_out, arrival_locks
-- Test hooks (DevHook only): _state(player) -> JSON
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Lib = ReplicatedStorage:WaitForChild("Lib")
local Funnel = require(Lib:WaitForChild("Onboarding"):WaitForChild("Funnel") :: ModuleScript) :: any
local SprayAssist = require(Lib:WaitForChild("Fire"):WaitForChild("SprayAssist") :: ModuleScript)

local ArrivalService = {}
ArrivalService.Priority = 96 -- after FunnelService (95), ToolService, FireService, InventoryService

type State = {
	run: string,
	at: number, -- os.clock() the run went Active
	rookie: boolean,
	locks: number,
	ready: string?, -- ReadySpray's answer, once
	out: number?, -- seconds to the first fire out
	logged: boolean,
}

local services: { [string]: any } = {}
local states: { [Player]: State } = {}

local function call(name: string, method: string, ...: any): any
	local svc = services[name]
	local f = svc and svc[method]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, svc, ...)
	if not ok then
		warn(`[ArrivalService] {name}:{method} failed: {res}`)
		return nil
	end
	return res
end

local function device(player: Player): string
	local d = call("FunnelService", "DeviceOf", player)
	return if type(d) == "string" then d else "Unknown"
end

local function finish(player: Player, s: State, how: string)
	if s.logged then
		return
	end
	s.logged = true
	if s.out then
		return
	end
	local secs = math.floor((os.clock() - s.at) * 10 + 0.5) / 10
	Telemetry.count("arrival_no_fire_out")
	call("FunnelService", "LogCustomFields", player, Funnel.Events.ArrivalNoFireOut, secs, device(player), how, SprayAssist.lockBucket(s.locks))
end

local function onActive(run: Instance)
	local id = run.Name
	for _, p in Players:GetPlayers() do
		local cur = states[p]
		if p:GetAttribute("InstanceId") == id and not (cur and cur.run == id) then
			if cur then
				finish(p, cur, "ended")
			end
			states[p] = { run = id, at = os.clock(), rookie = run:GetAttribute("Rookie") == true, locks = 0, logged = false }
		end
	end
end

local function watchRun(run: Instance)
	local function check()
		if run:GetAttribute("RoundState") == "Active" then
			onActive(run)
		end
	end
	run:GetAttributeChangedSignal("RoundState"):Connect(check)
	check()
end

local function seatedOrGone(player: Player): boolean
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return not hum or hum.Health <= 0 or hum.SeatPart ~= nil
end

local function step()
	for player, s in states do
		if s.logged then
			continue
		end
		if player:GetAttribute("InstanceId") ~= s.run then
			finish(player, s, "ended")
			continue
		end
		if not s.ready and not seatedOrGone(player) then
			local r = call("InventoryService", "ReadySpray", player)
			if r ~= "busy" then
				s.ready = if type(r) == "string" then r else "none"
				Telemetry.count(`arrival_ready_{s.ready}`)
			end
		end
	end
end

function ArrivalService:Init(all: { [string]: any })
	services = all
end

function ArrivalService:Start()
	local Fire = services.FireService
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(part: BasePart, by: Player?)
			local s = by and states[by]
			if not by or not s or s.out or s.logged then
				return
			end
			local training = workspace:FindFirstChild("TrainingFires")
			if training and part:IsDescendantOf(training) then
				return
			end
			s.out = math.floor((os.clock() - s.at) * 10 + 0.5) / 10
			s.logged = true
			Telemetry.count("arrival_fire_out")
			call(
				"FunnelService",
				"LogCustomFields",
				by,
				Funnel.Events.ArrivalToFireOut,
				s.out,
				device(by),
				if s.rookie then "rookie" else "call",
				SprayAssist.lockBucket(s.locks)
			)
		end)
	end
	local Tool = services.ToolService
	if Tool and Tool.SprayLocked then
		Tool.SprayLocked:Connect(function(player: Player)
			local s = states[player]
			if s and not s.logged then
				s.locks += 1
				Telemetry.count("arrival_locks")
			end
		end)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local s = states[player]
		if s then
			finish(player, s, "left")
		end
		states[player] = nil
	end)
	task.spawn(function()
		local runs = workspace:WaitForChild("Runs", 120)
		if not runs then
			warn("[ArrivalService] no workspace.Runs")
			return
		end
		runs.ChildAdded:Connect(watchRun)
		for _, r in runs:GetChildren() do
			watchRun(r)
		end
	end)
	while true do
		task.wait(0.25)
		local ok, err = pcall(step)
		if not ok then
			warn(`[ArrivalService] step: {err}`)
		end
	end
end

function ArrivalService:_state(player: Player): string
	local s = states[player]
	return HttpService:JSONEncode(s or {})
end

return ArrivalService
