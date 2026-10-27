--!strict
-- FunnelService [owner: Onboarding]. Sends the tutorial and mission funnels OUT of live servers through
-- Roblox AnalyticsService, so drop-off shows in Creator Dashboard -> Analytics -> Funnels (ForgeTelemetry
-- only counts inside one server). Step names / event names: Lib/Onboarding/Funnel (constants only).
--   * Onboarding funnel (LogOnboardingFunnelStepEvent), brand-new players only (Player attr Onboarded
--     false; steps seen before it is known are held and flushed once it resolves):
--       1 Joined, 2 Spawned, 3 Saw Fire Card (the client drew it: OnboardingService.Seen "firecard"),
--       4 First Spray (attr SecondsToFirstSpray), 5 Fire Out (attr FirstFire "done"), 6 Auto Queued
--       ("queued"), 7 Mission Launched (InstanceId set), 8 In Truck (seated in a Truck), 9 Arrived On
--       Scene (the run's RoundState Active), 10 First Mission Fire Out (FireService.Extinguished by you
--       on a call), 11 Mission Complete (MissionService.MissionEnded), 12 Back In Lobby (InstanceId "").
--   * Onboarding v3 funnel "OnboardingV3" (LogFunnelStepEvent, funnelSessionId = one GUID per join),
--     brand-new players only, 17 steps (Lib/Onboarding/Funnel.OnboardingV3): 1 Joined, 2 Spawned,
--     3 Cutscene Shown (Seen coldopen), 4 Cutscene Ended (Seen coldopen_end), 5 Fire Card Shown (Seen
--     firecard), 6 First Spray, 7 Fire Out (FirstFire "panda"), 8 Panda Picked Up (RescueService.Picked on the
--     cold-open panda), 9 Panda Saved (FirstFire "done"), 10 HUD Revealed (Seen hud), 11 Pad Stepped
--     (SquadId set), 12 Call Launched, 13 In Truck, 14 Arrived On Scene, 15 First Fire Out On Call,
--     16 Call Complete, 17 Back In Lobby.
--   * Device: every onboarding step (legacy and v3) carries CustomField01 = the Player attr Device
--     (Phone | Tablet | PC | Console | Unknown; OnboardingService, from the client's Onboarding/Ready). Steps
--     wait for it (at most DEVICE_WAIT s, then "Unknown") so a funnel can be split by device.
--   * Mission funnel "Mission" (LogFunnelStepEvent, funnelSessionId = the run's InstanceId), everyone,
--     every call: Dispatched, In Truck, Arrived On Scene, First Fire Out, Mission Complete, Back In Lobby.
--     Every step: CustomField01 = device (as OnboardingV3), Mission Complete: CustomField02 = end reason.
--   * Custom events (LogCustomEvent): FirstSpraySeconds (CustomField01 New | Returning),
--     SessionMinutes (on leave, CustomField01 New | Returning), OnboardingQuitStep (new players on leave:
--     value = furthest step number, CustomField01 = its step name), TutorialSkipped, FirstCallDeclined.
--     UpdateLogShown, NotifyPrompted, NotifyAccepted, FavoritePrompted, FavoriteAccepted (UpdateLogService
--     through FunnelService:LogCustom). ColdOpenSkipped (value = seconds into the cutscene, CustomField01 =
--     device), OnboardingV3QuitStep (new players on leave: value = furthest v3 step, CustomField01 = its
--     name, CustomField02 = device).
-- Public API: FunnelService:LogCustom(player, event, value, field?) -- event must be a Funnel.Events name
--             FunnelService:LogDevice(player, event, value, kind?)  -- CustomField01 = device, 02 = kind
--             FunnelService:DeviceOf(player): string               -- Phone | Tablet | PC | Console | Unknown
--             FunnelService:LogCustomFields(player, event, value, f1?, f2?, f3?) -- CustomField01..03 (constant sets)
-- Server-side only; every AnalyticsService call is pcall'd (a failing call counts analytics_error).
-- Counters: analytics_onboarding_step, analytics_mission_step, analytics_custom, analytics_error
-- Test hooks (DevHook only): _state(player) -> JSON, _log() -> JSON (last 60 calls made)
local AnalyticsService = game:GetService("AnalyticsService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local OnboardingConfig = require(ConfigDir:WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local FirstFireConfig = require(ConfigDir:WaitForChild("FirstFireConfig") :: ModuleScript) :: any
local Funnel = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("Funnel") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)

local FunnelService = {}
FunnelService.Priority = 95 -- after OnboardingService (25), FireService (50), MissionService (60), FirstFireService (60)

local TRUCK_TAG: string = (Names.Tag :: any).Truck or "Truck"
local FIELD1 = Enum.AnalyticsCustomFieldKeys.CustomField01.Name
local FIELD2 = Enum.AnalyticsCustomFieldKeys.CustomField02.Name
local DEVICE_ATTR = "Device" -- OnboardingService, from the client's Onboarding/Ready
local DEVICE_WAIT = 15 -- s after joining: onboarding steps wait this long for the device, then "Unknown"
local V3 = Funnel.OnboardingV3
local END_REASONS = { time = "Time", allOut = "All Out", forced = "Forced" } -- constant field values

type State = {
	t0: number,
	isNew: boolean?, -- nil until OnboardingService resolves Onboarded
	pending: { string }, -- onboarding steps seen before isNew / the device was known (legacy or v3 names)
	onb: Funnel.Track,
	v3: Funnel.Track,
	v3Session: string, -- funnelSessionId of this join's OnboardingV3 funnel
	device: string?, -- nil until the client said (or DEVICE_WAIT ran out)
	runs: { [string]: Funnel.Track }, -- mission funnel per run (InstanceId)
	run: string, -- current (or last) run id
	spawned: boolean,
	skipLogged: boolean?,
}

local services: { [string]: any } = {}
local states: { [Player]: State } = {}
local recent: { string } = {}

local function count(name: string)
	pcall(Telemetry.count, name, 1)
end

local function note(line: string)
	table.insert(recent, line)
	if #recent > 60 then
		table.remove(recent, 1)
	end
end

local function analytics(method: string, ...: any)
	local track = services.TrackService -- every Roblox event is also stored durably (docs/game/20-analytics.md)
	if track and type(track.Mirror) == "function" then
		pcall(track.Mirror, track, method, ...)
	end
	local ok, err = pcall((AnalyticsService :: any)[method], AnalyticsService, ...)
	if not ok then
		count("analytics_error")
		note(`error {method}: {err}`)
	end
end

local function instanceId(player: Player): string
	local id = player:GetAttribute(Names.Attr.InstanceId)
	return if type(id) == "string" then id else ""
end

-- legacy step name -> its v3 name, where the two funnels share a step under different names
local V3_NAME: { [string]: string } = {
	["Saw Fire Card"] = "Fire Card Shown",
	["Mission Launched"] = "Call Launched",
	["First Mission Fire Out"] = "First Fire Out On Call",
	["Mission Complete"] = "Call Complete",
}

------------------------------------------------------------------------------------------ steps

local function deviceFields(s: State): { [string]: string }
	return { [FIELD1] = s.device or "Unknown" }
end

-- one name may be a legacy step, a v3 step or both (same meaning): each funnel only takes its own names
local function sendOnboarding(player: Player, s: State, name: string)
	local idx = Funnel.reach(s.onb, Funnel.Onboarding, name)
	if idx then
		count("analytics_onboarding_step")
		note(`onboarding {player.UserId} {idx} {name} {s.device}`)
		analytics("LogOnboardingFunnelStepEvent", player, idx, name, deviceFields(s))
	end
	local v3 = V3_NAME[name] or name
	local i3 = Funnel.reach(s.v3, V3, v3)
	if i3 then
		count("analytics_onboarding_v3_step")
		note(`onboardingV3 {player.UserId} {i3} {v3} {s.device}`)
		analytics("LogFunnelStepEvent", player, Funnel.V3FunnelName, s.v3Session, i3, v3, deviceFields(s))
	end
end

local function ready(s: State): boolean
	return s.isNew ~= nil and s.device ~= nil
end

local function onboarding(player: Player, name: string)
	local s = states[player]
	if not s then
		return
	end
	if not ready(s) then
		table.insert(s.pending, name)
	elseif s.isNew then
		sendOnboarding(player, s, name)
	end
end

local function deviceOf(player: Player): string
	local s = states[player]
	if s and s.device then
		return s.device
	end
	local d = player:GetAttribute(DEVICE_ATTR)
	return if Funnel.isDevice(d) then d :: string else "Unknown"
end

local function mission(player: Player, name: string, reason: string?)
	local fields: { [string]: string } = { [FIELD1] = deviceOf(player) }
	if reason then
		fields[FIELD2] = reason
	end
	local s = states[player]
	local run = if s then s.run else ""
	if not s or run == "" then
		return
	end
	local track = s.runs[run]
	if not track then
		track = Funnel.new()
		s.runs[run] = track
	end
	local idx = Funnel.reach(track, Funnel.Mission, name)
	if idx then
		count("analytics_mission_step")
		note(`mission {player.UserId} {run} {idx} {name} {fields[FIELD1]}`)
		analytics("LogFunnelStepEvent", player, Funnel.MissionFunnelName, run, idx, name, fields)
	end
end

local function custom(player: Player, event: string, value: number, field: string?)
	count("analytics_custom")
	note(`custom {player.UserId} {event} {value} {field or ""}`)
	analytics("LogCustomEvent", player, event, value, if field then { [FIELD1] = field } else nil)
end

local function cohort(s: State?): string
	return if s and s.isNew == true then "New" elseif s and s.isNew == false then "Returning" else "Unknown"
end

------------------------------------------------------------------------------------------ watchers

local function flush(player: Player)
	local s = states[player]
	if not s or not ready(s) then
		return
	end
	local pending = s.pending
	s.pending = {}
	if s.isNew then
		for _, name in pending do
			sendOnboarding(player, s, name)
		end
	end
end

local function resolveNew(player: Player)
	local s = states[player]
	local v = player:GetAttribute(OnboardingConfig.DoneAttr or "Onboarded")
	if not s or s.isNew ~= nil or v == nil then
		return
	end
	s.isNew = v == false
	flush(player)
end

local function resolveDevice(player: Player, force: boolean?)
	local s = states[player]
	if not s or s.device ~= nil then
		return
	end
	local d = player:GetAttribute(DEVICE_ATTR)
	if Funnel.isDevice(d) then
		s.device = d :: string
	elseif force then
		s.device = "Unknown"
	else
		return
	end
	flush(player)
end

local function watchCharacter(player: Player, char: Model)
	local s = states[player]
	if s and not s.spawned then
		s.spawned = true
		onboarding(player, "Spawned")
	end
	local hum = char:WaitForChild("Humanoid", 10)
	if not hum or not hum:IsA("Humanoid") then
		return
	end
	hum.Seated:Connect(function(active: boolean, seat: Instance?)
		if not active or not seat or instanceId(player) == "" then
			return
		end
		local node: Instance? = seat
		while node and node ~= workspace do
			if CollectionService:HasTag(node, TRUCK_TAG) then
				onboarding(player, "In Truck")
				mission(player, "In Truck")
				return
			end
			node = node.Parent
		end
	end)
end

local function onInstanceChanged(player: Player)
	local s = states[player]
	if not s then
		return
	end
	local id = instanceId(player)
	if id ~= "" then
		s.run = id
		onboarding(player, "Mission Launched")
		mission(player, "Dispatched")
	elseif s.run ~= "" then
		onboarding(player, "Back In Lobby")
		mission(player, "Back In Lobby")
	end
end

local function onPlayer(player: Player)
	if states[player] then
		return
	end
	states[player] = {
		t0 = os.clock(),
		isNew = nil,
		pending = {},
		onb = Funnel.new(),
		v3 = Funnel.new(),
		v3Session = HttpService:GenerateGUID(false),
		device = nil,
		runs = {},
		run = "",
		spawned = false,
	}
	onboarding(player, "Joined")
	player:GetAttributeChangedSignal(DEVICE_ATTR):Connect(function()
		resolveDevice(player)
	end)
	resolveDevice(player)
	task.delay(DEVICE_WAIT, resolveDevice, player, true)
	local attr = OnboardingConfig.DoneAttr or "Onboarded"
	player:GetAttributeChangedSignal(attr):Connect(function()
		resolveNew(player)
	end)
	resolveNew(player)
	player:GetAttributeChangedSignal(FirstFireConfig.FirstSprayAttr):Connect(function()
		local secs = player:GetAttribute(FirstFireConfig.FirstSprayAttr)
		if type(secs) == "number" then
			onboarding(player, "First Spray")
			custom(player, Funnel.Events.FirstSpraySeconds, secs, cohort(states[player]))
		end
	end)
	player:GetAttributeChangedSignal(FirstFireConfig.PhaseAttr):Connect(function()
		local phase = player:GetAttribute(FirstFireConfig.PhaseAttr)
		if phase == "panda" then
			onboarding(player, "Fire Out") -- the house fire is out (legacy step 5, v3 step 7)
		elseif phase == "done" then
			onboarding(player, "Fire Out") -- (a shared house: someone else finished the fire)
			onboarding(player, "Panda Saved")
		elseif phase == "queued" then
			onboarding(player, "Auto Queued")
		end
	end)
	player:GetAttributeChangedSignal(Names.Attr.SquadId):Connect(function()
		local sid = player:GetAttribute(Names.Attr.SquadId)
		if type(sid) == "string" and sid ~= "" then
			onboarding(player, "Pad Stepped")
		end
	end)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		onInstanceChanged(player)
	end)
	player.CharacterAdded:Connect(function(c: Model)
		watchCharacter(player, c)
	end)
	if player.Character then
		task.spawn(watchCharacter, player, player.Character)
	end
end

local function onLeave(player: Player)
	local s = states[player]
	states[player] = nil
	if not s then
		return
	end
	local secs = os.clock() - s.t0
	custom(player, Funnel.Events.SessionMinutes, Funnel.minutes(secs), cohort(s))
	if s.isNew == true then
		-- where a brand-new player was when they left (the rage-quit question)
		custom(player, Funnel.Events.OnboardingQuitStep, s.onb.last, Funnel.lastName(s.onb, Funnel.Onboarding))
		count("analytics_custom")
		note(`custom {player.UserId} {Funnel.Events.OnboardingV3QuitStep} {s.v3.last} {s.device}`)
		analytics("LogCustomEvent", player, Funnel.Events.OnboardingV3QuitStep, s.v3.last, {
			[FIELD1] = Funnel.lastName(s.v3, V3),
			[FIELD2] = s.device or "Unknown",
		})
	end
end

-- arrival: the run's RoundState goes Dispatched -> Active (MissionService v2 dispatch runs)
local function arrivalLoop()
	while true do
		task.wait(1)
		local runs = workspace:FindFirstChild("Runs")
		if not runs then
			continue
		end
		for player, s in states do
			local id = instanceId(player)
			if id == "" then
				continue
			end
			local run = runs:FindFirstChild(id)
			if run and run:GetAttribute("RoundState") == "Active" then
				onboarding(player, "Arrived On Scene")
				mission(player, "Arrived On Scene")
			end
		end
	end
end

-- Other services log their own custom events here (only Funnel.Events names: AnalyticsService caps
-- distinct event names). field = CustomField01 (keep it a small constant set too).
function FunnelService:LogCustom(player: Player, event: string, value: number?, field: string?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") or (Funnel.Events :: any)[event] ~= event then
		return false
	end
	custom(player, event, tonumber(value) or 1, if type(field) == "string" and field ~= "" then field else nil)
	return true
end

-- Device-tagged custom event (CustomField01 = device, the OnboardingV3 helper; CustomField02 = kind, a
-- small constant set). Used by LobbyService (pad wait / left), ResultsController via Dispatch, DailyChest.
function FunnelService:LogDevice(player: Player, event: string, value: number?, kind: string?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") or (Funnel.Events :: any)[event] ~= event then
		return false
	end
	local fields: { [string]: string } = { [FIELD1] = deviceOf(player) }
	if type(kind) == "string" and kind ~= "" and #kind <= 40 then
		fields[FIELD2] = kind
	end
	count("analytics_custom")
	note(`custom {player.UserId} {event} {value} {fields[FIELD1]} {fields[FIELD2] or ""}`)
	analytics("LogCustomEvent", player, event, tonumber(value) or 1, fields)
	return true
end

function FunnelService:DeviceOf(player: Player): string
	return deviceOf(player)
end

-- Same, with up to three custom fields (DriveService: device, role, detail). Keep each a small constant set.
function FunnelService:LogCustomFields(player: Player, event: string, value: number?, f1: string?, f2: string?, f3: string?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") or (Funnel.Events :: any)[event] ~= event then
		return false
	end
	local fields: { [string]: string } = {}
	for i, v in { f1, f2, f3 } :: { any } do
		if type(v) == "string" and v ~= "" then
			fields[Enum.AnalyticsCustomFieldKeys["CustomField0" .. i].Name] = v
		end
	end
	local n = tonumber(value) or 1
	count("analytics_custom")
	note(`custom {player.UserId} {event} {n} {f1 or ""} {f2 or ""} {f3 or ""}`)
	analytics("LogCustomEvent", player, event, n, fields)
	return true
end

------------------------------------------------------------------------------------------ lifecycle

function FunnelService:Init(all: { [string]: any })
	services = all
end

function FunnelService:Start()
	local Onboarding = services.OnboardingService
	if Onboarding and Onboarding.Seen then
		Onboarding.Seen:Connect(function(player: Player, step: string, value: number?)
			if step == "firecard" then
				onboarding(player, "Saw Fire Card")
			elseif step == "coldopen" then
				onboarding(player, "Cutscene Shown")
			elseif step == "coldopen_end" then
				onboarding(player, "Cutscene Ended")
			elseif step == "coldopen_skip" then
				local s = states[player]
				if s and not s.skipLogged then
					s.skipLogged = true
					custom(player, Funnel.Events.ColdOpenSkipped, math.floor((value or 0) * 10 + 0.5) / 10, s.device or "Unknown")
				end
			elseif step == "hud" then
				onboarding(player, "HUD Revealed")
			end
		end)
	end
	if Onboarding and Onboarding.Skipped then
		Onboarding.Skipped:Connect(function(player: Player)
			local s = states[player]
			custom(player, Funnel.Events.TutorialSkipped, if s then s.onb.last else 0, nil)
		end)
	end
	if Onboarding and Onboarding.CallDeclined then
		Onboarding.CallDeclined:Connect(function(player: Player)
			custom(player, Funnel.Events.FirstCallDeclined, 1, nil)
		end)
	end
	local Fire = services.FireService
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(part: BasePart, by: Player?)
			if not by or instanceId(by) == "" then
				return
			end
			local training = workspace:FindFirstChild("TrainingFires")
			if training and part:IsDescendantOf(training) then
				return
			end
			onboarding(by, "First Mission Fire Out")
			mission(by, "First Fire Out")
		end)
	end
	local Rescue = services.RescueService
	if Rescue and Rescue.Picked then
		Rescue.Picked:Connect(function(player: Player, rescueId: string, _kind: string)
			if player:GetAttribute(FirstFireConfig.PandaAttr) == rescueId then
				onboarding(player, "Panda Picked Up")
			end
		end)
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(id: string, payload: any)
			local reason = type(payload) == "table" and END_REASONS[payload.reason] or "Other"
			for player, s in states do
				if s.run == id then
					onboarding(player, "Mission Complete")
					mission(player, "Mission Complete", reason)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(onLeave)
	task.spawn(arrivalLoop)
end

------------------------------------------------------------------------------------------ test hooks

function FunnelService:_state(player: Player): string
	local s = states[player]
	if not s then
		return "{}"
	end
	local runs = {}
	for id, t in s.runs do
		runs[id] = Funnel.lastName(t, Funnel.Mission)
	end
	return HttpService:JSONEncode({
		isNew = s.isNew,
		device = s.device,
		onboarding = s.onb.last,
		onboardingStep = Funnel.lastName(s.onb, Funnel.Onboarding),
		v3 = s.v3.last,
		v3Step = Funnel.lastName(s.v3, V3),
		pending = s.pending,
		run = s.run,
		runs = runs,
	})
end

function FunnelService:_log(): string
	return HttpService:JSONEncode(recent)
end

return FunnelService
