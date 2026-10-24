--!strict
-- SessionService [owner: Onboarding]. Session-length telemetry (session length is our main growth
-- multiplier: every extra minute per player is about +1 CCU at our traffic). Counters only, no gameplay.
--   * session_started / session_started_new / session_started_returning on join (new = Onboarded false
--     once OnboardingService knows; resolved within a few seconds, else counted as unknown)
--   * session_minutes (+1 per player per full minute online; new players also session_minutes_new),
--     so minutes / sessions = average session length, live, even before anyone leaves
--   * on leave: session_ended, session_seconds (sum), session_seconds_new / _returning (sums),
--     session_<bucket> and session_new_<bucket> (Lib/Onboarding/FirstFire.bucket: lt1m, 1to5m, 5to15m,
--     15to30m, 30to60m, ge60m), session_missions_<0|1|2|3plus> (calls started this session)
-- Writes: Player attr SessionStartedAt (workspace:GetServerTimeNow() at join)
-- Test hooks (DevHook only): _seconds(player) -> number
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local OnboardingConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local FirstFire = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("FirstFire") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)

local SessionService = {}
SessionService.Priority = 90

type Session = { t0: number, isNew: boolean?, minutes: number, missions: number }
local sessions: { [Player]: Session } = {}

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function onboardedAttr(): string
	return OnboardingConfig.DoneAttr or "Onboarded"
end

local function resolveNew(player: Player, s: Session)
	local v = player:GetAttribute(onboardedAttr())
	if v == nil or s.isNew ~= nil then
		return
	end
	s.isNew = v == false
	count(if s.isNew then "session_started_new" else "session_started_returning")
end

local function onPlayer(player: Player)
	if sessions[player] then
		return
	end
	local s: Session = { t0 = os.clock(), isNew = nil, minutes = 0, missions = 0 }
	sessions[player] = s
	player:SetAttribute("SessionStartedAt", workspace:GetServerTimeNow())
	count("session_started")
	resolveNew(player, s)
	player:GetAttributeChangedSignal(onboardedAttr()):Connect(function()
		resolveNew(player, s)
	end)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		local id = player:GetAttribute(Names.Attr.InstanceId)
		if type(id) == "string" and id ~= "" then
			s.missions += 1
		end
	end)
end

local function onLeave(player: Player)
	local s = sessions[player]
	sessions[player] = nil
	if not s then
		return
	end
	local secs = os.clock() - s.t0
	local whole = math.floor(secs + 0.5)
	local bucket = FirstFire.bucket(secs)
	count("session_ended")
	count("session_seconds", whole)
	count(`session_{bucket}`)
	if s.isNew == true then
		count("session_seconds_new", whole)
		count(`session_new_{bucket}`)
	elseif s.isNew == false then
		count("session_seconds_returning", whole)
	end
	count(`session_missions_{if s.missions >= 3 then "3plus" else tostring(s.missions)}`)
end

function SessionService:Init(_all: { [string]: any }) end

function SessionService:Start()
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(onLeave)
	task.spawn(function()
		while true do
			task.wait(5)
			local now = os.clock()
			for player, s in sessions do
				local full = math.floor((now - s.t0) / 60)
				if full > s.minutes then
					local add = full - s.minutes
					s.minutes = full
					count("session_minutes", add)
					if s.isNew == true then
						count("session_minutes_new", add)
					end
				end
				if player.Parent ~= Players then
					onLeave(player)
				end
			end
		end
	end)
end

function SessionService:_seconds(player: Player): number
	local s = sessions[player]
	return if s then os.clock() - s.t0 else 0
end

return SessionService
