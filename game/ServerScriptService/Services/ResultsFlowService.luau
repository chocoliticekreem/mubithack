--!strict
-- ResultsFlowService [owner: Retention]. Keeps players for call #2 (OnboardingV3: 27% quit at / after the
-- results screen). Two jobs, both server-authoritative:
--   * DAILY CHEST (Lib/Retention/DailyChest): after a player's first completed call of the UTC day
--     (MissionService.MissionEnded, any end but "forced"), the chest is opened FOR them on the server: streak
--     day 1..7 in the profile (`daily`, ProfileSchema), its XP through DataService:AddXp, its cosmetic (days 3,
--     5, 7) into profile cosmetics.owned, then DataService:Save. The client only draws it:
--     DailyChest/Granted (S->C owner: { day, xp, cosmetic?, cosmeticName?, next }).
--     Free and fixed per streak day: no Robux, no random items.
--   * Results choice telemetry: Results/Choice (C->S kind: "tap" | "auto" | "stay", seconds: number; 1/s)
--     from ResultsController (NEXT CALL!, the NEXT CALL IN 5 auto-launch, STAY AT STATION). "stay" sets Player
--     attr ResultsStay = true until the player's next call (DispatchService's NEXT CALL leaves them out).
-- Telemetry: FunnelService:LogDevice (CustomField01 = device): ResultsChoice (value: seconds the results
--   were up, kind tap | auto | stay), DailyChestOpened (value: streak day, kind: reward id).
-- Writes: Player attrs DailyStreak (streak day of the last chest), DailyChestToday (true = opened today), and the
--   come-back preview (RetentionRules.chestPreview, drawn by ClientLib/ComeBack): DailyNextWhen ("today" |
--   "tomorrow"), DailyNextDay (streak day 1..7), DailyNextXp, DailyNextCosmetic ("" | DataConfig cosmetic id),
--   DailyStreakNow (the streak the player is on now, 0 = none)
-- Counters: daily_chest_opened, daily_chest_day<n>, daily_chest_xp, daily_chest_cosmetic,
--   results_choice_<kind>, results_choice_<kind>_<device>
-- Test hooks (DevHook only): _grant(player) -> JSON (opens today's chest if it can), _reset(player),
--   _state(player) -> JSON
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local DataConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DataConfig") :: ModuleScript) :: any
local DailyChest = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Retention"):WaitForChild("DailyChest") :: ModuleScript)
local RetentionRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Retention"):WaitForChild("RetentionRules") :: ModuleScript)

local ResultsFlowService = {}
ResultsFlowService.Priority = 96 -- after DataService (20), MissionService (60), FunnelService (95)

local STAY_ATTR = "ResultsStay"
local CHOICES = { tap = true, auto = true, stay = true }

local services: { [string]: any } = {}
local grantedRemote: RemoteEvent? = nil

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
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

local function logDevice(player: Player, event: string, value: number, kind: string)
	local F = services.FunnelService
	if F and type(F.LogDevice) == "function" then
		pcall(F.LogDevice, F, player, event, value, kind)
	end
end

local function cosmeticName(id: string): string
	for _, c in DataConfig.Cosmetics or {} do
		if c.id == id then
			return c.name
		end
	end
	return id
end

local function today(): number
	return DailyChest.dayOf(os.time())
end

local function setAttrs(player: Player, d: any, owned: any)
	if type(d) ~= "table" then
		return
	end
	player:SetAttribute("DailyStreak", d.streak or 0)
	player:SetAttribute("DailyChestToday", (d.lastDay or 0) == today())
	local pv = RetentionRules.chestPreview(d, today(), if type(owned) == "table" then owned else nil)
	player:SetAttribute("DailyNextWhen", pv.when)
	player:SetAttribute("DailyNextDay", pv.day)
	player:SetAttribute("DailyNextXp", pv.xp)
	player:SetAttribute("DailyNextCosmetic", pv.cosmetic or "")
	player:SetAttribute("DailyStreakNow", pv.streak)
end

local function ownedOf(p: any): any
	return type(p) == "table" and type(p.cosmetics) == "table" and p.cosmetics.owned or nil
end

-- Open today's chest for `player` if they haven't yet. Returns the payload sent to the client, or nil.
local function grant(player: Player): { [string]: any }?
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" or type(Data.GetProfile) ~= "function" then
		return nil
	end
	local profile = Data:GetProfile(player)
	if type(profile) ~= "table" then
		return nil
	end
	local day = today()
	local reward: DailyChest.Reward? = nil
	Data:Update(player, function(p: any)
		if type(p.daily) ~= "table" then
			p.daily = DailyChest.blank()
		end
		local ok, streak = DailyChest.claim(p.daily, day)
		if not ok then
			return
		end
		local owned = type(p.cosmetics) == "table" and p.cosmetics.owned or nil
		local r = DailyChest.reward(streak, owned)
		if r.cosmetic and type(p.cosmetics) == "table" and type(p.cosmetics.owned) == "table" then
			p.cosmetics.owned[r.cosmetic] = true
		end
		reward = r
	end)
	local r = reward
	if not r then
		return nil
	end
	if type(Data.AddXp) == "function" then
		pcall(Data.AddXp, Data, player, r.xp, "Daily chest")
	end
	if type(Data.Save) == "function" then
		task.spawn(function()
			pcall(Data.Save, Data, player)
		end)
	end
	local after = Data:GetProfile(player)
	setAttrs(player, after and after.daily, ownedOf(after))
	local nextDay = (r.day % DailyChest.MaxStreak) + 1
	local payload = {
		day = r.day,
		xp = r.xp,
		cosmetic = r.cosmetic,
		cosmeticName = if r.cosmetic then cosmeticName(r.cosmetic) else nil,
		next = nextDay,
		nextCosmetic = DailyChest.Days[nextDay].cosmetic ~= nil,
	}
	count("daily_chest_opened")
	count(`daily_chest_day{r.day}`)
	count("daily_chest_xp", r.xp)
	if r.cosmetic then
		count("daily_chest_cosmetic")
	end
	logDevice(player, "DailyChestOpened", r.day, r.id)
	if grantedRemote then
		grantedRemote:FireClient(player, payload)
	end
	print(`[ResultsFlowService] {player.Name}: daily chest day {r.day}: +{r.xp} XP{if r.cosmetic then " + " .. r.cosmetic else ""}`)
	return payload
end

local function onChoice(player: Player, kind: any, seconds: any)
	if type(kind) ~= "string" or not CHOICES[kind] then
		return
	end
	local secs = math.clamp(math.floor((tonumber(seconds) or 0) * 10 + 0.5) / 10, 0, 120)
	count(`results_choice_{kind}`)
	count(`results_choice_{kind}_{string.lower(deviceOf(player))}`)
	logDevice(player, "ResultsChoice", secs, kind)
	if kind == "stay" then
		player:SetAttribute(STAY_ATTR, true)
		task.delay(30, function()
			if player.Parent == Players then
				player:SetAttribute(STAY_ATTR, nil)
			end
		end)
	else
		player:SetAttribute(STAY_ATTR, nil)
	end
end

local function onPlayer(player: Player)
	-- a new call clears STAY AT STATION
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		local id = player:GetAttribute(Names.Attr.InstanceId)
		if type(id) == "string" and id ~= "" then
			player:SetAttribute(STAY_ATTR, nil)
		end
	end)
	task.spawn(function()
		local Data = services.DataService
		if Data and type(Data.WaitForProfile) == "function" then
			local ok, p = pcall(Data.WaitForProfile, Data, player, 30)
			if ok and type(p) == "table" and player.Parent == Players then
				setAttrs(player, p.daily, ownedOf(p))
			end
		end
	end)
end

function ResultsFlowService:Init(all: { [string]: any })
	services = all
end

function ResultsFlowService:Start()
	grantedRemote = Net.event("DailyChest", "Granted")
	Net.onServer(Net.event("Results", "Choice"), { rate = 1, burst = 2 }, onChoice)

	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		Mission.MissionEnded:Connect(function(instanceId: string, payload: any)
			if type(payload) == "table" and payload.reason == "forced" then
				return -- not a completed call (admin end, everyone left)
			end
			for _, p in Players:GetPlayers() do
				if p:GetAttribute(Names.Attr.InstanceId) == instanceId then
					-- after DataService records the call (XP, level-up), so the chest's XP lands on top
					task.delay(0.5, function()
						if p.Parent == Players then
							local ok, err = pcall(grant, p)
							if not ok then
								warn(`[ResultsFlowService] daily chest for {p.Name}: {err}`)
							end
						end
					end)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayer, p)
	end
end

------------------------------------------------------------------------------------------ test hooks

function ResultsFlowService:_grant(player: Player): string
	return HttpService:JSONEncode(grant(player) or { granted = false })
end

function ResultsFlowService:_reset(player: Player): boolean
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" then
		return false
	end
	local ok = Data:Update(player, function(p: any)
		p.daily = DailyChest.blank()
	end)
	player:SetAttribute("DailyStreak", 0)
	player:SetAttribute("DailyChestToday", false)
	setAttrs(player, DailyChest.blank(), nil)
	return ok
end

function ResultsFlowService:_state(player: Player): string
	local Data = services.DataService
	local p = Data and type(Data.GetProfile) == "function" and Data:GetProfile(player)
	return HttpService:JSONEncode({
		daily = p and p.daily,
		today = today(),
		stay = player:GetAttribute(STAY_ATTR),
		device = deviceOf(player),
	})
end

return ResultsFlowService
