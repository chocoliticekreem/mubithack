--!strict
-- AchievementService [owner: Achievements]. Server-authoritative achievements (Config/AchievementConfig,
-- pure rules in ReplicatedStorage/Lib/Achievements/AchievementRules). Counters are kept in the player
-- profile (profile.achievements, ProfileSchema v8 without a bump, saved by DataService in
-- FlameAndBlameProfiles). Each unlock gives a small XP reward (DataService:AddXp, never Robux), a toast
-- through the one HUD toast queue (Shared/Notify: "🏆 ACHIEVEMENT! FIRST RESCUE +50 XP"), and a Roblox
-- badge when AchievementConfig.BadgeIds has an id for it (missing / 0 = no-op).
--
-- Counting (all nil-guarded; every bump is batched per player and saved every FlushSeconds):
--   MissionService.MissionEnded   calls (not "forced"), threeStars, fastArrivals, records (TwistService
--                                 payload.newRecord), nightWins (payload.twist "night", all out), blamed
--                                 (a blame award with your userId), sites (payload.siteId)
--   FireService.Extinguished      fires; hydrantFires when the putter-out's Player attr HoseKind = "Hydrant"
--   FireService.Combo             combos (every hose on it)
--   RescueService.Rescued         rescues; pets (Dog/Cat); pandas; treeCats (the rescuable's Variant TreeCat)
--   RescueService.Delivered       pandas (each carrier of the two-player panda, once per panda)
--   RescueService.Escorted        teamwork (the helper, and the carrier once per rescue)
--   RescueService.Thrown          yeets
--   SmokeService.Backdraft / HazardService.Caused("backdraft")   backdrafts (once per 3 s per player)
--   VehicleService.Driven         drives (>= DriveMinStuds)
--   ToolService.DoorBroken        doors
--   DataService.LevelUp, BattlePassService.TierUp, Player attrs SquadStreak / PassTier / DailyStreak (the
--   DAILY CHEST, ResultsFlowService)   max stats
-- Old profiles: on load the stats are raised to the profile's own counters (missionsPlayed, firesOut,
--   rescued, level) and anything already earned unlocks at once (one summary toast past RetroToastMax).
--
-- Public API (nil-guarded callers):
--   AchievementService:Record(player, stat, value, mode?)   -- mode "sum" | "max" (default: Stats kind).
--   AchievementService:GetState(player) -> { unlocked, stats }?
--   AchievementService:IsUnlocked(player, id) -> boolean
-- Signals: Unlocked(player, id, xp)
-- Remotes: Achievements/State (S->C owner: { unlocked = { id = unix }, stats = { stat = n } })
--          Achievements/Unlocked (S->C owner: id, xp) the moment its toast shows (chip punch + chime)
--          Achievements/Request (C->S: "state"; 2/s)
-- Writes: Player attrs AchievementCount, AchievementTotal
-- Counters: achievements_unlocked, achievement_<id>, achievements_retro, achievement_badges_awarded,
--   achievement_badge_failed
-- Test hooks (DevHook only; player = Player | name | UserId): _bump(player, stat, n), _unlock(player, id),
--   _state(player) -> JSON, _reset(player), _selftest()
local BadgeService = game:GetService("BadgeService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AchievementConfig") :: ModuleScript) :: any
local Rules = require(
	ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Achievements"):WaitForChild("AchievementRules") :: ModuleScript
)

local AchievementService = {}
AchievementService.Priority = 80
AchievementService.Unlocked = Signal.new() :: Signal.Signal<Player, string, number>

type Pending = { sums: { [string]: number }, maxes: { [string]: number }, sites: { string } }
type PState = {
	pending: Pending,
	dirty: boolean,
	seeded: boolean,
	credited: { [string]: boolean }, -- "panda:<rescueId>", "team:<rescueId>" already counted
	backdraftAt: number,
	toasts: { { text: string, id: string?, xp: number? } },
	toasting: boolean,
	badgesChecked: boolean,
}

local services: { [string]: any } = {}
local states: { [Player]: PState } = {}
local stateRemote: RemoteEvent? = nil
local unlockedRemote: RemoteEvent? = nil
local defsById: { [string]: any } = {}
for _, d in Cfg.Defs do
	defsById[d.id] = d
end

local function count(name: string, n: number?)
	Telemetry.count(name, n or 1)
end

local function isPlayer(v: any): boolean
	return typeof(v) == "Instance" and v:IsA("Player") and v.Parent ~= nil
end

local function stateOf(player: Player): PState
	local s = states[player]
	if not s then
		s = {
			pending = { sums = {}, maxes = {}, sites = {} },
			dirty = false,
			seeded = false,
			credited = {},
			backdraftAt = -math.huge,
			toasts = {},
			toasting = false,
			badgesChecked = false,
		}
		states[player] = s
	end
	return s
end

local function maxPassTier(): number?
	local ok, bp = pcall(function()
		return require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BattlePassConfig") :: ModuleScript) :: any
	end)
	return if ok and type(bp) == "table" then tonumber(bp.MaxTier) else nil
end

-- the live profile's achievements table (ProfileSchema reconciles it; old in-memory profiles get one here)
local function dataOf(p: any): Rules.Data
	if type(p.achievements) ~= "table" then
		p.achievements = Rules.empty()
	end
	local a = p.achievements
	a.stats = if type(a.stats) == "table" then a.stats else {}
	a.unlocked = if type(a.unlocked) == "table" then a.unlocked else {}
	a.sites = if type(a.sites) == "table" then a.sites else {}
	return a
end

local function profileOf(player: Player): any
	local Data = services.DataService
	if not Data or type(Data.GetProfile) ~= "function" then
		return nil
	end
	return Data:GetProfile(player)
end

------------------------------------------------------------------------------------------ record

local function record(player: Player, stat: string, value: number, mode: string?)
	if not isPlayer(player) or type(stat) ~= "string" then
		return
	end
	local kind = mode or Cfg.Stats[stat] or "sum"
	local s = stateOf(player)
	local v = math.floor(tonumber(value) or 0)
	if kind == "max" then
		if v > (s.pending.maxes[stat] or 0) then
			s.pending.maxes[stat] = v
			s.dirty = true
		end
	elseif v > 0 then
		s.pending.sums[stat] = (s.pending.sums[stat] or 0) + v
		s.dirty = true
	end
end

local function recordSite(player: Player, siteId: any)
	if not isPlayer(player) or type(siteId) ~= "string" or siteId == "" then
		return
	end
	local s = stateOf(player)
	table.insert(s.pending.sites, siteId)
	s.dirty = true
end

------------------------------------------------------------------------------------------ output

local function sendState(player: Player)
	local p = profileOf(player)
	if not p then
		return
	end
	local data = dataOf(p)
	local got, total = Rules.count(Cfg.Defs, data, maxPassTier())
	player:SetAttribute(Cfg.Attr.Count, got)
	player:SetAttribute(Cfg.Attr.Total, total)
	if stateRemote then
		stateRemote:FireClient(player, Rules.snapshot(Cfg.Defs, data))
	end
end

local function awardBadge(player: Player, id: string)
	local badgeId = tonumber((Cfg.BadgeIds :: any)[id])
	if not badgeId or badgeId <= 0 then
		return -- no badge for this one (yet): no-op
	end
	task.spawn(function()
		local ok, err = pcall(function()
			if not BadgeService:UserHasBadgeAsync(player.UserId, badgeId) then
				BadgeService:AwardBadge(player.UserId, badgeId)
				count("achievement_badges_awarded")
			end
		end)
		if not ok then
			count("achievement_badge_failed")
			warn(`[AchievementService] badge {id} ({badgeId}) for {player.Name}: {err}`)
		end
	end)
end

-- Player attrs other services own -> "max" stats
local WATCHED: { [string]: string } = { SquadStreak = "streak", PassTier = "passTier", DailyStreak = "dailyStreak" }

local TUTORIAL_PHASES = { burning = true, done = true } -- FirstFire tutorial cards on screen

-- one toast at a time per player, ToastGapSeconds apart, through Shared/Notify (the HUD's toast queue)
local function pumpToasts(player: Player)
	local s = stateOf(player)
	if s.toasting then
		return
	end
	s.toasting = true
	task.spawn(function()
		while #s.toasts > 0 and player.Parent do
			local held = 0
			while held < Cfg.ToastHoldMax and player.Parent do
				local phase = player:GetAttribute("FirstFire")
				if not (type(phase) == "string" and TUTORIAL_PHASES[phase]) then
					break
				end
				task.wait(0.5)
				held += 0.5
			end
			local t = table.remove(s.toasts, 1)
			if t and player.Parent then
				Net.notify(player, t.text, "good")
				if unlockedRemote and t.id then
					unlockedRemote:FireClient(player, t.id, t.xp or 0)
				end
			end
			task.wait(Cfg.ToastGapSeconds)
		end
		s.toasting = false
	end)
end

local function toastFor(def: any): string
	return (string.gsub(string.gsub(Cfg.Toast, "{1}", def.name), "{2}", tostring(def.xp)))
end

------------------------------------------------------------------------------------------ flush

-- apply the batched bumps to the profile, unlock what's reached, reward it. retro = first flush after load.
local function flush(player: Player)
	local s = states[player]
	if not s or not s.dirty then
		return
	end
	local Data = services.DataService
	if not Data or type(Data.Update) ~= "function" or not profileOf(player) then
		return -- profile not loaded yet: keep the bumps
	end
	local retro = not s.seeded
	local pending = s.pending
	s.pending = { sums = {}, maxes = {}, sites = {} }
	s.dirty = false
	local newly: { any } = {}
	Data:Update(player, function(p: any)
		local data = dataOf(p)
		if retro then
			local rescued = if type(p.rescued) == "table" then p.rescued else {}
			Rules.seed(data, {
				calls = tonumber(p.missionsPlayed) or 0,
				fires = tonumber(p.firesOut) or 0,
				rescues = (tonumber(rescued.Civilian) or 0) + (tonumber(rescued.Dog) or 0) + (tonumber(rescued.Cat) or 0)
					+ (tonumber(rescued.Panda) or 0),
				pandas = tonumber(rescued.Panda) or 0,
				pets = (tonumber(rescued.Dog) or 0) + (tonumber(rescued.Cat) or 0),
				level = tonumber(p.level) or 1,
			}, Cfg.Stats)
		end
		for stat, n in pending.sums do
			Rules.add(data, stat, n, "sum")
		end
		for stat, n in pending.maxes do
			Rules.add(data, stat, n, "max")
		end
		for _, site in pending.sites do
			Rules.addSite(data, site, Cfg.MaxSites)
		end
		local now = os.time()
		for _, def in Rules.newlyUnlocked(Cfg.Defs, data) do
			if Rules.unlock(data, def.id, now) then
				table.insert(newly, def)
			end
		end
	end)
	s.seeded = true

	if #newly > 0 then
		local summary = retro and #newly > Cfg.RetroToastMax
		if summary then
			count("achievements_retro", #newly)
			table.insert(s.toasts, { text = (string.gsub(Cfg.ToastMany, "{1}", tostring(#newly))) })
		end
		for _, def in newly do
			count("achievements_unlocked")
			count(`achievement_{def.id}`)
			if not summary then
				table.insert(s.toasts, { text = toastFor(def), id = def.id, xp = def.xp })
			end
			awardBadge(player, def.id)
			AchievementService.Unlocked:Fire(player, def.id, def.xp)
		end
		-- XP after the unlocks are saved: a level-up it causes comes back as a "level" bump next flush
		for _, def in newly do
			if type(Data.AddXp) == "function" and def.xp > 0 then
				Data:AddXp(player, def.xp, Cfg.XpReason)
			end
		end
		pumpToasts(player)
	end
	sendState(player)
end

-- badges for achievements unlocked before their badge id existed (once per session)
local function catchUpBadges(player: Player)
	local s = stateOf(player)
	if s.badgesChecked then
		return
	end
	s.badgesChecked = true
	local p = profileOf(player)
	if not p then
		return
	end
	for id in dataOf(p).unlocked do
		awardBadge(player, id)
	end
end

local function onProfile(player: Player)
	local s = stateOf(player)
	s.dirty = true -- the first flush seeds old profiles
	for attr, stat in WATCHED do
		local v = tonumber(player:GetAttribute(attr))
		if v then
			record(player, stat, v, "max")
		end
	end
	flush(player)
	catchUpBadges(player)
end

------------------------------------------------------------------------------------------ hooks

local function rescuableVariant(rescueId: string): string?
	local folder = workspace:FindFirstChild("Rescuables")
	local m = folder and folder:FindFirstChild(rescueId)
	if not m then
		for _, inst in CollectionService:GetTagged("Rescuable") do
			if inst:GetAttribute("RescueId") == rescueId then
				m = inst
				break
			end
		end
	end
	local v = m and m:GetAttribute("Variant")
	return if type(v) == "string" then v else nil
end

local function credit(player: Player, key: string): boolean
	local s = stateOf(player)
	if s.credited[key] then
		return false
	end
	s.credited[key] = true
	return true
end

local function onMissionEnded(_instanceId: string, payload: any)
	if type(payload) ~= "table" or type(payload.stats) ~= "table" then
		return
	end
	if payload.reason == "forced" then
		return -- aborted (squad left / admin): not a finished call
	end
	local stars = tonumber(payload.stars) or 0
	local won = payload.reason == "allOut" and (tonumber(payload.burningAtEnd) or 0) == 0
	local blamed: { [number]: boolean } = {}
	if type(payload.awards) == "table" then
		for _, a in payload.awards do
			if type(a) == "table" and a.blame == true and type(a.userId) == "number" then
				blamed[a.userId] = true
			end
		end
	end
	for _, st in payload.stats do
		local player = type(st) == "table" and type(st.userId) == "number" and Players:GetPlayerByUserId(st.userId)
		if player then
			record(player, "calls", 1)
			if stars >= 3 then
				record(player, "threeStars", 1)
			end
			if payload.fastArrival == true then
				record(player, "fastArrivals", 1)
			end
			if payload.newRecord == true then
				record(player, "records", 1)
			end
			if payload.twist == "night" and won then
				record(player, "nightWins", 1)
			end
			if blamed[player.UserId] then
				record(player, "blamed", 1)
			end
			recordSite(player, payload.siteId or payload.missionId)
		end
	end
end

local function onBackdraft(player: any)
	if not isPlayer(player) then
		return
	end
	local s = stateOf(player)
	local now = os.clock()
	if now - s.backdraftAt < 3 then
		return -- SmokeService and HazardService both saw the same one
	end
	s.backdraftAt = now
	record(player, "backdrafts", 1)
end

local function connect(serviceName: string, signalName: string, fn: (...any) -> ())
	local svc = services[serviceName]
	local sig = svc and svc[signalName]
	if sig and type(sig.Connect) == "function" then
		sig:Connect(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				warn(`[AchievementService] {serviceName}.{signalName}: {err}`)
			end
		end)
	end
end

local function hookAll()
	connect("MissionService", "MissionEnded", onMissionEnded)
	connect("FireService", "Extinguished", function(_part: any, by: any)
		if isPlayer(by) then
			record(by, "fires", 1)
			if by:GetAttribute("HoseKind") == "Hydrant" then
				record(by, "hydrantFires", 1)
			end
		end
	end)
	connect("FireService", "Combo", function(_part: any, hoses: any)
		if type(hoses) == "table" then
			for _, p in hoses do
				if isPlayer(p) then
					record(p, "combos", 1)
				end
			end
		end
	end)
	connect("RescueService", "Rescued", function(player: any, rescueId: any, kind: any)
		if not isPlayer(player) then
			return
		end
		record(player, "rescues", 1)
		if kind == "Dog" or kind == "Cat" then
			record(player, "pets", 1)
		end
		if kind == "Panda" and credit(player, `panda:{rescueId}`) then
			record(player, "pandas", 1)
		end
		if kind == "Cat" and type(rescueId) == "string" and rescuableVariant(rescueId) == "TreeCat" then
			record(player, "treeCats", 1)
		end
	end)
	connect("RescueService", "Delivered", function(player: any, rescueId: any, kind: any)
		if isPlayer(player) and kind == "Panda" and credit(player, `panda:{rescueId}`) then
			record(player, "pandas", 1)
		end
	end)
	connect("RescueService", "Escorted", function(helper: any, carrier: any, rescueId: any)
		if isPlayer(helper) and credit(helper, `team:{rescueId}`) then
			record(helper, "teamwork", 1)
		end
		if isPlayer(carrier) and credit(carrier, `team:{rescueId}`) then
			record(carrier, "teamwork", 1)
		end
	end)
	connect("RescueService", "Thrown", function(player: any)
		if isPlayer(player) then
			record(player, "yeets", 1)
		end
	end)
	connect("SmokeService", "Backdraft", function(opener: any)
		onBackdraft(opener)
	end)
	connect("HazardService", "Caused", function(culprit: any, what: any)
		if what == "backdraft" then
			onBackdraft(culprit)
		end
	end)
	connect("VehicleService", "Driven", function(driver: any, studs: any)
		if isPlayer(driver) and (tonumber(studs) or 0) >= Cfg.DriveMinStuds then
			record(driver, "drives", 1)
		end
	end)
	connect("ToolService", "DoorBroken", function(player: any)
		if isPlayer(player) then
			record(player, "doors", 1)
		end
	end)
	connect("DataService", "LevelUp", function(player: any, level: any)
		if isPlayer(player) then
			record(player, "level", tonumber(level) or 0, "max")
		end
	end)
	connect("DataService", "ProfileLoaded", function(player: any)
		if isPlayer(player) then
			onProfile(player)
		end
	end)
	connect("BattlePassService", "TierUp", function(player: any, tier: any)
		if isPlayer(player) then
			record(player, "passTier", tonumber(tier) or 0, "max")
		end
	end)
end

local function watchPlayer(player: Player)
	stateOf(player)
	for attr, stat in WATCHED do
		player:GetAttributeChangedSignal(attr):Connect(function()
			record(player, stat, tonumber(player:GetAttribute(attr)) or 0, "max")
		end)
	end
	-- a profile that loaded before this service started (boot order) still gets seeded
	if profileOf(player) then
		task.defer(onProfile, player)
	end
end

------------------------------------------------------------------------------------------ public

function AchievementService:Record(player: Player, stat: string, value: number, mode: string?)
	record(player, stat, value, mode)
end

function AchievementService:GetState(player: Player): any
	local p = profileOf(player)
	return if p then Rules.snapshot(Cfg.Defs, dataOf(p)) else nil
end

function AchievementService:IsUnlocked(player: Player, id: string): boolean
	local p = profileOf(player)
	return p ~= nil and dataOf(p).unlocked[id] ~= nil
end

------------------------------------------------------------------------------------------ lifecycle

function AchievementService:Init(all: { [string]: any })
	services = all
end

function AchievementService:Start()
	stateRemote = Net.event("Achievements", "State")
	unlockedRemote = Net.event("Achievements", "Unlocked")
	local request = Net.event("Achievements", "Request")
	Net.onServer(request, { rate = 2, burst = 2 }, function(player: Player, what: any)
		if what == "state" then
			sendState(player)
		end
	end)
	hookAll()
	Players.PlayerAdded:Connect(watchPlayer)
	for _, p in Players:GetPlayers() do
		watchPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		flush(player) -- before DataService's save on the same event (it yields first)
		states[player] = nil
	end)
	while true do
		task.wait(Cfg.FlushSeconds)
		for player, s in states do
			if s.dirty and player.Parent then
				local ok, err = pcall(flush, player)
				if not ok then
					warn(`[AchievementService] flush {player.Name}: {err}`)
				end
			end
		end
	end
end

----------------------------------------------------------------------------------- test hooks

local function resolve(who: any): Player?
	if typeof(who) == "Instance" and who:IsA("Player") then
		return who
	end
	if type(who) == "number" then
		return Players:GetPlayerByUserId(who)
	end
	if type(who) == "string" then
		return Players:FindFirstChild(who) :: Player?
	end
	return Players:GetPlayers()[1]
end

function AchievementService:_bump(who: any, stat: string, n: number?): string
	local player = resolve(who)
	if not player then
		return "no player"
	end
	record(player, stat, n or 1)
	flush(player)
	return self:_state(player)
end

function AchievementService:_unlock(who: any, id: string): string
	local player = resolve(who)
	local def = defsById[id]
	if not player or not def then
		return "no player / unknown id"
	end
	record(player, def.stat, def.goal, if Cfg.Stats[def.stat] == "max" or def.stat == "sites" then "max" else "sum")
	if def.stat == "sites" then
		for i = 1, def.goal do
			recordSite(player, `devsite_{i}`)
		end
	end
	flush(player)
	return self:_state(player)
end

function AchievementService:_state(who: any): string
	local player = resolve(who)
	local st = player and self:GetState(player)
	return if st then HttpService:JSONEncode(st) else "null"
end

function AchievementService:_reset(who: any): boolean
	local player = resolve(who)
	local Data = services.DataService
	if not player or not Data then
		return false
	end
	Data:Update(player, function(p: any)
		p.achievements = Rules.empty()
	end)
	local s = stateOf(player)
	s.seeded = true -- don't re-seed from the profile counters
	s.credited = {}
	sendState(player)
	return true
end

function AchievementService:_selftest(): (boolean, string)
	local seen: { [string]: boolean } = {}
	for _, d in Cfg.Defs do
		if seen[d.id] then
			return false, `duplicate id {d.id}`
		end
		seen[d.id] = true
		if Cfg.Stats[d.stat] == nil then
			return false, `{d.id}: unknown stat {d.stat}`
		end
	end
	for id in Cfg.BadgeIds do
		if not seen[id] then
			return false, `badge for unknown achievement {id}`
		end
	end
	local n = 0
	for _ in states do
		n += 1
	end
	return true, `{#Cfg.Defs} achievements, {n} players tracked`
end

return AchievementService
