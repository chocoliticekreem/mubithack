--!strict
-- RetentionService [owner: Retention]. Reasons to come back tomorrow, and knowing whether players do
-- (docs/game/21-retention.md; rules: ReplicatedStorage/Lib/Retention/RetentionRules, config: Config/RetentionConfig).
--   * Return-day analytics: on every join (profile loaded) the gap since the previous join DAY (profile
--     retention.lastJoinDay, UTC days) -> FunnelService:LogCustomFields "ReturnGap" (value = days, -1 first join;
--     F1 device, F2 gap bucket first | same_day | next_day | d2_6 | d7plus, F3 days since install d0 | d1 | d2_6 |
--     d7plus). next_day + F3 d1 = a Day-1 return. Counters return_<bucket>.
--   * The "remind me tomorrow" opt-in: Controllers/RetentionController shows the card (after the first finished
--     call, through ClientLib/PopupGate) and Roblox's ExperienceNotificationService:PromptOptIn; this service
--     only records it: Retention/Notify (C->S: action "shown" | "yes" | "no" | "closed", canPromptAfter?: boolean;
--     2/s). Saved in profile retention.notify { asks, answer, at }; Player attrs NotifyAsks, NotifyAnswer.
--     Roblox never tells a game the answer: after the prompt closes, "can't prompt any more" = accepted (proxy).
--   * The next-day notification ("Your Day N chest is ready!"): when a player who ACCEPTED leaves, an entry
--     { day } goes into the MemoryStore sorted map Notify.QueueMap (key = UserId, sort key = due time:
--     RetentionRules.notifyDue, >= MinHoursAfterLeave and the next UTC day). Every server sweeps due entries
--     every SweepSeconds, claims each one (UpdateAsync) and sends it through Open Cloud
--     (POST https://apis.roblox.com/cloud/v2/users/<id>/notifications, x-api-key = the Secrets-store secret
--     Notify.SecretName). Rejoining removes the entry. OFF until Notify.MessageId is set (and the secret exists);
--     Roblox itself only delivers to opted-in users (13+ for personalised moments) and at most 1 a day.
-- Analytics: NotifyAsk (value 1; field shown | yes | no), NotifyPrompted / NotifyAccepted (field "retention"),
--   ReturnGap (above). Sends have no player in the server: counters notify_sent / notify_send_failed only.
-- Writes: Player attrs NotifyAsks (number), NotifyAnswer ("" | no | accepted | declined), RetentionReady (true)
-- Counters: return_<bucket>, notify_ask_shown, notify_ask_yes, notify_ask_no, notify_optin_accepted,
--   notify_optin_declined, notify_queued, notify_sent, notify_send_failed
-- Test hooks (DevHook only): _state(player) -> JSON, _reset(player), _setLastJoin(player, daysAgo),
--   _queue(player) -> string (what leaving would queue), _sweep() -> string (one sweep now), _payload(userId, day)
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RetentionConfig") :: ModuleScript) :: any
local RetLib = ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Retention")
local Rules = require(RetLib:WaitForChild("RetentionRules") :: ModuleScript)
local DailyChest = require(RetLib:WaitForChild("DailyChest") :: ModuleScript)

local RetentionService = {}
RetentionService.Priority = 97 -- after DataService (20) and FunnelService (95)

local IS_STUDIO = RunService:IsStudio()
local ACTIONS = { shown = true, yes = true, no = true, closed = true }

local services: { [string]: any } = {}
local logged: { [Player]: boolean } = {}
local secret: any = nil
local secretState = "unchecked" -- unchecked | ok | missing
local queueMap: MemoryStoreSortedMap? = nil

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function N(): any
	return Cfg.Notify
end

local function today(): number
	return DailyChest.dayOf(os.time())
end

local function profileOf(player: Player): any
	local Data = services.DataService
	return Data and type(Data.GetProfile) == "function" and Data:GetProfile(player) or nil
end

local function update(player: Player, fn: (any) -> ()): boolean
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" then
		return false
	end
	local ok, res = pcall(Data.Update, Data, player, function(p: any)
		if type(p.retention) == "table" then
			fn(p.retention)
		end
	end)
	return ok and res == true
end

local function funnel(method: string, player: Player, ...: any)
	local F = services.FunnelService
	if F and type(F[method]) == "function" then
		pcall(F[method], F, player, ...)
	end
end

local function deviceOf(player: Player): string
	local F = services.FunnelService
	if F and type(F.DeviceOf) == "function" then
		local ok, d = pcall(F.DeviceOf, F, player)
		if ok and type(d) == "string" then
			return d
		end
	end
	return "Unknown"
end

local function setAttrs(player: Player)
	local p = profileOf(player)
	local n = p and p.retention and p.retention.notify
	player:SetAttribute("NotifyAsks", if n then n.asks else 0)
	player:SetAttribute("NotifyAnswer", if n then n.answer else "")
end

------------------------------------------------------------------------------- the notification queue

local function sendingOn(): boolean
	return type(N().MessageId) == "string" and N().MessageId ~= ""
end

local function map(): MemoryStoreSortedMap?
	if queueMap then
		return queueMap
	end
	local ok, m = pcall(MemoryStoreService.GetSortedMap, MemoryStoreService, N().QueueMap)
	if ok then
		queueMap = m
	end
	return queueMap
end

local function getSecret(): any
	if secretState == "unchecked" then
		local ok, s = pcall(HttpService.GetSecret, HttpService, N().SecretName)
		if ok and s ~= nil then
			secret, secretState = s, "ok"
		else
			secretState = "missing"
			warn(`[RetentionService] no secret "{N().SecretName}" in this experience's Secrets store: notifications are not sent`)
		end
	end
	return if secretState == "ok" then secret else nil
end

local function payloadFor(userId: number, day: number): { [string]: any }
	return {
		source = { universe = `universes/{game.GameId}` },
		payload = {
			message_id = N().MessageId,
			type = "MOMENT",
			parameters = { day = { string_value = tostring(day) } },
		},
		join_experience = { launch_data = N().LaunchData },
		analytics_data = { category = N().Category },
	}
end

local function send(userId: number, day: number): (boolean, string)
	local key = getSecret()
	if not key then
		return false, "no secret"
	end
	local ok, res = pcall(HttpService.RequestAsync, HttpService, {
		Url = `https://apis.roblox.com/cloud/v2/users/{userId}/notifications`,
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json", ["x-api-key"] = key },
		Body = HttpService:JSONEncode(payloadFor(userId, day)),
	})
	if not ok then
		return false, tostring(res)
	end
	local r = res :: any
	return r.Success == true, `{r.StatusCode} {string.sub(tostring(r.Body), 1, 120)}`
end

local function enqueue(player: Player): string
	local p = profileOf(player)
	local n = p and p.retention and p.retention.notify
	if not n or n.answer ~= "accepted" then
		return "not opted in"
	end
	if not sendingOn() then
		return "sending off (Notify.MessageId empty)"
	end
	local now = os.time()
	local due = Rules.notifyDue(now, N().MinHoursAfterLeave)
	local day = DailyChest.nextStreak(p.daily or DailyChest.blank(), DailyChest.dayOf(due))
	local m = map()
	if not m then
		return "no memory store"
	end
	local ttl = math.clamp(due - now + (tonumber(N().QueueDays) or 3) * 86400, 60, 45 * 86400)
	local ok, err = pcall(function()
		(m :: any):SetAsync(tostring(player.UserId), { due = due, day = day }, ttl, due)
	end)
	if not ok then
		return `queue failed: {err}`
	end
	count("notify_queued")
	return `queued day {day} chest for {due} (in {math.floor((due - now) / 3600)} h)`
end

local function dequeue(userId: number)
	if not sendingOn() then
		return
	end
	local m = map()
	if m then
		pcall(function()
			(m :: any):RemoveAsync(tostring(userId))
		end)
	end
end

local function sweep(): string
	if not sendingOn() then
		return "sending off"
	end
	local m = map()
	if not m then
		return "no memory store"
	end
	local now = os.time()
	local ok, items = pcall(function()
		return (m :: any):GetRangeAsync(Enum.SortDirection.Ascending, math.clamp(tonumber(N().SweepBatch) or 25, 1, 200), nil, { sortKey = now })
	end)
	if not ok or type(items) ~= "table" then
		return `range failed: {items}`
	end
	local sent, failed = 0, 0
	for _, item in items :: { any } do
		local userId = tonumber(item.key)
		local value = item.value
		if not userId or type(value) ~= "table" or (tonumber(value.due) or math.huge) > now then
			continue
		end
		if Players:GetPlayerByUserId(userId) then
			dequeue(userId) -- they're here: no "come back" ping
			continue
		end
		-- claim it: only the server whose RemoveAsync-by-update wins sends (Roblox also caps 1 / day / user)
		local claimed = false
		pcall(function()
			(m :: any):UpdateAsync(tostring(userId), function(old: any)
				if type(old) ~= "table" or old.claimed then
					return nil
				end
				old.claimed = game.JobId
				claimed = true
				return old
			end, 600)
		end)
		if claimed then
			local okS, why = send(userId, tonumber(value.day) or 1)
			if okS then
				sent += 1
				count("notify_sent")
			else
				failed += 1
				count("notify_send_failed")
				warn(`[RetentionService] notification to {userId}: {why}`)
			end
			dequeue(userId)
		end
	end
	return `sent {sent}, failed {failed}, looked at {#(items :: any)}`
end

------------------------------------------------------------------------------------ players

local function onProfile(player: Player)
	if logged[player] then
		return
	end
	logged[player] = true
	local p = profileOf(player)
	if type(p) ~= "table" or type(p.retention) ~= "table" then
		return
	end
	local day = today()
	local gap = Rules.returnGap(p.retention.lastJoinDay, day)
	local created = DailyChest.dayOf(tonumber(p.meta and p.meta.created) or os.time())
	local bucket = Rules.gapBucket(gap)
	funnel("LogCustomFields", player, "ReturnGap", gap, deviceOf(player), bucket, Rules.ageBucket(created, day))
	count(`return_{bucket}`)
	update(player, function(r: any)
		r.lastJoinDay = day
	end)
	setAttrs(player)
	player:SetAttribute("RetentionReady", true)
	task.spawn(dequeue, player.UserId)
end

local function onNotify(player: Player, action: any, canPromptAfter: any)
	if type(action) ~= "string" or not ACTIONS[action] then
		return
	end
	if action == "shown" then
		update(player, function(r: any)
			r.notify.asks += 1
		end)
		count("notify_ask_shown")
		funnel("LogCustom", player, "NotifyAsk", 1, "shown")
	elseif action == "yes" then
		count("notify_ask_yes")
		funnel("LogCustom", player, "NotifyAsk", 1, "yes")
		funnel("LogCustom", player, "NotifyPrompted", 1, "retention")
	elseif action == "no" then
		update(player, function(r: any)
			r.notify.answer = "no"
			r.notify.at = os.time()
		end)
		count("notify_ask_no")
		funnel("LogCustom", player, "NotifyAsk", 1, "no")
	elseif action == "closed" then
		local answer = Rules.optInAnswer(canPromptAfter == true)
		update(player, function(r: any)
			r.notify.answer = answer
			r.notify.at = os.time()
		end)
		count(`notify_optin_{answer}`)
		if answer == "accepted" then
			funnel("LogCustom", player, "NotifyAccepted", 1, "retention")
		end
	end
	setAttrs(player)
end

function RetentionService:Init(all: { [string]: any })
	services = all
end

function RetentionService:Start()
	Net.onServer(Net.event("Retention", "Notify"), { rate = 2, burst = 4 }, onNotify)
	local Data = services.DataService
	if Data and Data.ProfileLoaded then
		Data.ProfileLoaded:Connect(onProfile)
		for _, p in Players:GetPlayers() do
			if profileOf(p) then
				task.spawn(onProfile, p)
			end
		end
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		logged[player] = nil
		local ok, res = pcall(enqueue, player)
		if ok and string.sub(res, 1, 6) == "queued" then
			print(`[RetentionService] {player.Name}: {res}`)
		end
	end)
	if sendingOn() and not IS_STUDIO then
		task.spawn(function()
			task.wait(math.random(5, 60)) -- spread servers out
			while true do
				local ok, res = pcall(sweep)
				if not ok then
					warn(`[RetentionService] sweep: {res}`)
				end
				task.wait(math.max(60, tonumber(N().SweepSeconds) or 300))
			end
		end)
	end
end

------------------------------------------------------------------------------------------ test hooks

function RetentionService:_state(player: Player): string
	local p = profileOf(player)
	return HttpService:JSONEncode({
		retention = p and p.retention,
		today = today(),
		created = p and p.meta and p.meta.created,
		sending = sendingOn(),
		secret = secretState,
	})
end

function RetentionService:_reset(player: Player): boolean
	local ok = update(player, function(r: any)
		r.notify = { asks = 0, answer = "", at = 0 }
	end)
	setAttrs(player)
	return ok
end

function RetentionService:_setLastJoin(player: Player, daysAgo: number): boolean
	return update(player, function(r: any)
		r.lastJoinDay = today() - math.floor(daysAgo)
	end)
end

function RetentionService:_queue(player: Player): string
	return enqueue(player)
end

function RetentionService:_sweep(): string
	return sweep()
end

function RetentionService:_payload(userId: number, day: number): string
	return HttpService:JSONEncode(payloadFor(userId, day))
end

return RetentionService
