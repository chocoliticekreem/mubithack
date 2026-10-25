--!strict
-- SquadBroadcastService [owner: Social]. SEE OTHERS (Tizyz rule #3: "other players zooming past you"):
-- when another squad's truck pulls out of the station on a call, everyone still at the station gets a
-- toast "SQUAD 2 IS HEADING TO SCHOOL ALARM!" (Lobby/Fx "toast", LobbyController draws it) and hears the
-- truck go: its siren is on (VehicleService turns it on for a driver with a call; we make sure of it) and
-- everyone's VehicleController plays it positionally. Cheap: one 0.5 s poll per run for up to WatchSeconds.
-- A call whose squad never drives (v1.5 instance teleport) is announced once after NoTruckSeconds.
--
-- Consumes (nil-guarded): MissionService.MissionStarted / :GetMission, LobbyService.Launched / :GetSquad,
--   Workspace.Trucks (attr Driver = UserId, SirenOn), MissionCatalog titles
-- Remotes used: Lobby/Fx (S->C: "toast", text) to lobby players (Player attr InstanceId "" ) not on that call
-- Counters: squad_broadcasts
-- Test hooks (DevHook only): _announce(text) -> number of players told, _label(instanceId)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local MissionCatalog = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MissionCatalog") :: ModuleScript) :: { any }

local SquadBroadcastService = {}
SquadBroadcastService.Priority = 90

local LEAVE_STUDS = 30 -- the truck has left its spot by this much = "heading out"
local WATCH_SECONDS = 120
local NO_TRUCK_SECONDS = 12

local services: { [string]: any } = {}
local padOf: { [string]: number } = {} -- instanceId -> lobby pad number (LobbyService.Launched)

local function inLobby(p: Player): boolean
	local v = p:GetAttribute(Names.Attr.InstanceId)
	return v == nil or v == ""
end

local function announce(text: string, except: { [number]: boolean }): number
	local fx = Net.event("Lobby", "Fx")
	local told = 0
	for _, p in Players:GetPlayers() do
		if not except[p.UserId] and inLobby(p) then
			fx:FireClient(p, "toast", text)
			told += 1
		end
	end
	if told > 0 then
		Telemetry.count("squad_broadcasts")
	end
	return told
end

local function titleOf(missionId: string): string
	for _, def in MissionCatalog do
		if type(def) == "table" and def.id == missionId then
			return string.upper(tostring(def.title or missionId))
		end
	end
	return "A CALL"
end

local function labelOf(instanceId: string, ids: { number }): string
	local pad = padOf[instanceId]
	if pad then
		return `SQUAD {pad}`
	end
	local lead = ids[1] and Players:GetPlayerByUserId(ids[1])
	if lead then
		return if #ids > 1 then `{string.upper(lead.DisplayName)}'S SQUAD` else string.upper(lead.DisplayName)
	end
	return "A SQUAD"
end

local function truckOf(ids: { [number]: boolean }): Model?
	local folder = workspace:FindFirstChild("Trucks")
	if not folder then
		return nil
	end
	for _, t in folder:GetChildren() do
		local d = t:GetAttribute("Driver")
		if t:IsA("Model") and type(d) == "number" and ids[d] then
			return t
		end
	end
	return nil
end

local function watch(instanceId: string, missionId: string)
	task.wait(0.5) -- let MissionService / LobbyService finish the launch (Launched, seats)
	local Mission = services.MissionService
	local run = Mission and type(Mission.GetMission) == "function" and Mission:GetMission(instanceId)
	if not run or type(run.players) ~= "table" or #run.players == 0 then
		return
	end
	local ids: { [number]: boolean } = {}
	for _, id in run.players do
		ids[id] = true
	end
	local text = `{labelOf(instanceId, run.players)} IS HEADING TO {titleOf(missionId)}!`
	local start: Vector3? = nil
	local t0 = os.clock()
	while os.clock() - t0 < WATCH_SECONDS do
		local truck = truckOf(ids)
		if truck then
			local pos = truck:GetPivot().Position
			start = start or pos
			if (pos - (start :: Vector3)).Magnitude >= LEAVE_STUDS then
				if truck:GetAttribute("SirenOn") ~= true then
					-- same as VehicleService's setSiren(true): attr (light bar, pitch) + the truck's siren Sound
					truck:SetAttribute("SirenOn", true)
					local snd = truck:FindFirstChild("SirenSound", true)
					if snd and snd:IsA("Sound") and not snd.IsPlaying then
						snd:Play()
					end
				end
				announce(text, ids)
				break
			end
		elseif start == nil and os.clock() - t0 >= NO_TRUCK_SECONDS then
			announce(text, ids) -- no truck to watch (teleported call): just say it
			break
		end
		if not Mission:GetMission(instanceId) then
			break
		end
		task.wait(0.5)
	end
	padOf[instanceId] = nil
end

function SquadBroadcastService:Init(all: { [string]: any })
	services = all
end

function SquadBroadcastService:Start()
	local Lobby = services.LobbyService
	if Lobby and Lobby.Launched then
		Lobby.Launched:Connect(function(squadId: string, _missionId: string, instanceId: string)
			local sq = type(Lobby.GetSquad) == "function" and Lobby:GetSquad(squadId)
			if sq and type(sq.padId) == "number" and type(instanceId) == "string" then
				padOf[instanceId] = sq.padId
			end
		end)
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionStarted then
		Mission.MissionStarted:Connect(function(instanceId: string, missionId: string)
			task.spawn(watch, instanceId, missionId)
		end)
	end
end

function SquadBroadcastService:_announce(text: string): number
	return announce(text, {})
end

function SquadBroadcastService:_label(instanceId: string): string
	local Mission = services.MissionService
	local run = Mission and Mission:GetMission(instanceId)
	return if run then labelOf(instanceId, run.players) else "no run"
end

return SquadBroadcastService
