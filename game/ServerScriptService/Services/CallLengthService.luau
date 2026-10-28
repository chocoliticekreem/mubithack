--!strict
-- CallLengthService [owner: G3 mission]. How long calls take, per player, by their lifetime call number and
-- device, and who quits in the middle of one (Config/CallRampConfig sizes the early calls to fix that):
--   CallDuration  value = seconds from dispatch (or late join) to the results
--                 F1 device, F2 call bucket (CallRamp.bucket: "1".."5", "6-10", "11+"), F3 win | timeout | fail
--   QuitMidCall   value = seconds since dispatch when the player left the GAME (or the call) with it still on
--                 F1 device, F2 call bucket, F3 drive | scene | left_drive | left_scene
--                 (a quit on the results screen is not mid-call)
-- Both through FunnelService:LogCustomFields (Creator Dashboard custom events; TrackService mirrors them to
-- PostHog with labels device / call / how). Counters: call_length_logged, call_quit_mid.
-- The call number is the player's own: profile missionsPlayed + 1 when they joined the run.
-- Consumes (nil-guarded): MissionService.MissionEnded, DataService:GetProfile, FunnelService:LogCustomFields /
--   DeviceOf; Player attr InstanceId; Workspace.Runs.<id> attrs DispatchedAt / RoundState.
-- Test hooks (DevHook only): _state() -> JSON of live trackers and the last 10 logged rows.
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local CallRamp = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Mission"):WaitForChild("CallRamp") :: ModuleScript)

local CallLengthService = {}
CallLengthService.Priority = 97 -- after MissionService (60), FunnelService (95)

type Tracker = { run: string, t0: number, index: number, ended: boolean }

local services: { [string]: any } = {}
local live: { [Player]: Tracker } = {}
local logged: { any } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function runFolder(id: string): Instance?
	local runs = workspace:FindFirstChild("Runs")
	return runs and runs:FindFirstChild(id)
end

local function callIndexOf(player: Player): number
	local Data = services.DataService
	if Data and type(Data.GetProfile) == "function" then
		local ok, profile = pcall(Data.GetProfile, Data, player)
		if ok and type(profile) == "table" then
			return (tonumber(profile.missionsPlayed) or 0) + 1
		end
	end
	return 1
end

local function log(player: Player, event: string, seconds: number, index: number, how: string)
	local Funnel = services.FunnelService
	local device = "Unknown"
	if Funnel and type(Funnel.LogCustomFields) == "function" then
		pcall(function()
			device = Funnel:DeviceOf(player)
			Funnel:LogCustomFields(player, event, math.floor(seconds + 0.5), device, CallRamp.bucket(index), how)
		end)
	end
	table.insert(logged, 1, { event = event, user = player.UserId, seconds = math.floor(seconds + 0.5), call = index, device = device, how = how })
	if #logged > 10 then
		table.remove(logged)
	end
end

local function onInstance(player: Player)
	local id = player:GetAttribute(Names.Attr.InstanceId)
	local cur = live[player]
	if cur and cur.run ~= id then
		live[player] = nil
		if not cur.ended then -- left the call before it finished (results never came)
			local f = runFolder(cur.run)
			local state = f and f:GetAttribute(Names.Attr.RoundState)
			log(player, "QuitMidCall", now() - cur.t0, cur.index, if state == "Dispatched" then "left_drive" else "left_scene")
			Telemetry.count("call_quit_mid")
		end
	end
	if type(id) == "string" and id ~= "" and (live[player] == nil) then
		local f = runFolder(id)
		local at = f and f:GetAttribute("DispatchedAt")
		live[player] = {
			run = id,
			t0 = if type(at) == "number" then math.min(at, now()) else now(),
			index = callIndexOf(player),
			ended = false,
		}
	end
end

local function watch(player: Player)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		onInstance(player)
	end)
	onInstance(player)
end

function CallLengthService:Init(all: { [string]: any })
	services = all
end

function CallLengthService:Start()
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string, payload: any)
			local p = if type(payload) == "table" then payload else {}
			local how = if p.reason == "allOut" then "win" elseif p.rookieWin == true then "timeout" else "fail"
			for player, tr in live do
				if tr.run == instanceId and not tr.ended then
					tr.ended = true
					log(player, "CallDuration", now() - tr.t0, tr.index, how)
					Telemetry.count("call_length_logged")
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local tr = live[player]
		live[player] = nil
		if not tr then
			return
		end
		if tr.ended then
			return -- quit on the results screen: not mid-call (ResultsChoice covers it)
		end
		local f = runFolder(tr.run)
		local state = f and f:GetAttribute(Names.Attr.RoundState)
		log(player, "QuitMidCall", now() - tr.t0, tr.index, if state == "Dispatched" then "drive" else "scene")
		Telemetry.count("call_quit_mid")
	end)
end

function CallLengthService:_state(): string
	local rows = {}
	for p, tr in live do
		table.insert(rows, { user = p.UserId, run = tr.run, seconds = math.floor(now() - tr.t0), call = tr.index, ended = tr.ended })
	end
	return HttpService:JSONEncode({ live = rows, logged = logged })
end

return CallLengthService
