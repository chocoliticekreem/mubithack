--!strict
-- TrackService [owner: Analytics]. The ONE place analytics events are recorded (docs/game/20-analytics.md).
-- Every event goes to:
--   1. a durable sink: Lib/Analytics/PostHogSink (batched HTTP POST to PostHog when a key is configured;
--      Studio without a key prints the batches instead; live without a key does nothing)
--   2. a per-day aggregate: Lib/Analytics/DailyAggregate (counts per event per device in a DataStore)
--   3. Roblox AnalyticsService:LogCustomEvent, only for the few events in Schema.Roblox (Roblox caps
--      event names at 100), under a per-server budget (Config.RobloxPerMinute*)
-- Record shape (PostHog): event, timestamp, properties { distinct_id (UserId, or "server:<JobId>"),
--   session_id (GUID per join), server_id (JobId), place_version, device (Phone | Tablet | PC | Console |
--   Unknown | server), locale, schema, studio, ...props }. No names, no chat, nothing typed by players.
-- Existing Roblox funnels / custom events are NOT duplicated: FunnelService's single AnalyticsService
-- helper calls :Mirror, so each one is also stored durably (funnel steps as funnel_step).
-- What it watches by itself (no calls needed from those systems): players (session_start / _end),
-- Player attrs Device, Onboarded, InstanceId, InvHand, Spraying, PassClaimable; signals MissionService
-- MissionStarted / MissionEnded, FireService.Extinguished, RescueService.Delivered, VehicleService.Entered,
-- BattlePassService TierUp / XpGained, AchievementService.Unlocked, DataService.LevelUp, SquadService
-- Downed / Revived; MarketplaceService.PromptGamePassPurchaseFinished; ScriptContext.Error (server);
-- ForgeTelemetry counters (server_counters deltas); the client's AnalyticsController (Analytics/Client).
-- Public API (nil-guarded callers):
--   TrackService:Event(player, name, props?) -> boolean   -- a player event (Schema.validName name)
--   TrackService:Server(name, props?) -> boolean           -- a server event (distinct_id server:<JobId>)
--   TrackService:Mirror(method, ...)                       -- FunnelService: an AnalyticsService call it made
--   TrackService:Receipt(receipt, decision)                -- MonetizationService.ProcessReceipt result
-- Remotes: Analytics/Client (C->S: kind "ui" | "error" | "perf", data table; 2/s burst 10)
-- Writes: Player attr AnalyticsPerf (seconds between perf samples; nil = this session sends none)
-- Counters: analytics_events, analytics_invalid, analytics_dropped, analytics_sent, analytics_post_failed,
--   analytics_spilled, analytics_drained, analytics_dryrun_batches, analytics_roblox, analytics_roblox_throttled,
--   analytics_errors_repeat
-- Test hooks (DevHook only): _recent(n?) -> JSON, _state() -> JSON, _flush() -> JSON, _payloads() -> JSON,
--   _rekey() -> JSON (re-reads the PostHog key)
local AnalyticsService = game:GetService("AnalyticsService")
local HttpService = game:GetService("HttpService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ScriptContext = game:GetService("ScriptContext")
local ServerScriptService = game:GetService("ServerScriptService")
local Stats = game:GetService("Stats")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local OnboardingConfig = require(ConfigDir:WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local MonetizationConfig = require(ConfigDir:WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local Schema = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Analytics"):WaitForChild("Schema") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Lib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Analytics")
local Config = require(Lib:WaitForChild("AnalyticsConfig") :: ModuleScript) :: any
local PostHogSink = require(Lib:WaitForChild("PostHogSink") :: ModuleScript)
local DailyAggregate = require(Lib:WaitForChild("DailyAggregate") :: ModuleScript)

local TrackService = {}
TrackService.Priority = 10 -- early: other services' Start may record events

local IS_STUDIO = RunService:IsStudio()
local JOB_ID = if game.JobId ~= "" then game.JobId else "studio-" .. HttpService:GenerateGUID(false)
local DEVICE_ATTR = "Device" -- OnboardingService (Lib/Onboarding/Funnel.Devices)
local HAND_ATTR = "InvHand" -- InventoryService
local TWIST_ATTR = "Twist" -- TwistService (Player and Workspace.Runs.<id>)
local CLAIMABLE_ATTR = "PassClaimable" -- BattlePassService
local PERF_ATTR = "AnalyticsPerf"

type Ctx = {
	sid: string,
	t0: number,
	isNew: boolean?,
	device: string?,
	locale: string,
	started: boolean,
	sampled: boolean,
	screen: string,
	funnel: { [string]: string },
	missions: number,
	sprayS: number,
	sprayOn: number?,
	bpXp: number,
	firesOut: number,
	run: string,
	runT0: number,
	runArrived: number?,
	runTruck: boolean,
	runFires: number,
	runRescues: number,
	runSpray: number,
	runEnded: boolean,
	hand: string,
	claimable: number,
	errors: number,
	errSeen: { [string]: boolean },
	events: number,
}

local services: { [string]: any } = {}
local ctxs: { [Player]: Ctx } = {}
local missionOf: { [string]: string } = {} -- run id -> MissionCatalog id
local recent: { any } = {}
local robloxBucket = Schema.bucket(Config.RobloxPerMinuteBase)
local sink: PostHogSink.Sink
local agg: DailyAggregate.Agg
local startedAt = os.clock()
local totalEvents = 0
local passPrice: { [number]: number } = {}
local errWindow = { at = 0, n = 0, seen = {} :: { [string]: boolean }, repeats = 0 }

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function ensureSinks()
	if not sink then
		sink = PostHogSink.new(Config, { count = count, log = print })
		sink.mode = "pending" -- buffer until Start resolves the key
	end
	if not agg then
		agg = DailyAggregate.new(Config, JOB_ID, true) -- Studio: memory only unless Config.AggregateInStudio
	end
end

local function attrDevice(player: Player): string
	local d = player:GetAttribute(DEVICE_ATTR)
	return if type(d) == "string" and d ~= "" then d else "Unknown"
end

local function distinctId(userId: number): string
	if Config.HashUserIds then
		return Schema.hash64(`{Config.HashSalt}:{userId}`)
	end
	return tostring(userId)
end

local function instanceId(player: Player): string
	local id = player:GetAttribute(Names.Attr.InstanceId)
	return if type(id) == "string" then id else ""
end

local function runModel(id: string): Instance?
	local runs = workspace:FindFirstChild("Runs")
	return runs and runs:FindFirstChild(id)
end

local function remember(rec: any)
	table.insert(recent, rec)
	if #recent > 150 then
		table.remove(recent, 1)
	end
end

local function forwardRoblox(player: Player, name: string, props: { [string]: any }, device: string)
	local event, value, fields = Schema.robloxArgs(name, props, device)
	if not event then
		return
	end
	local perMinute = Config.RobloxPerMinuteBase + Config.RobloxPerMinutePerPlayer * #Players:GetPlayers()
	if not Schema.allow(robloxBucket, os.clock(), perMinute) then
		count("analytics_roblox_throttled")
		return
	end
	local custom: { [string]: string } = {}
	for i, v in fields do
		custom[Enum.AnalyticsCustomFieldKeys["CustomField0" .. i].Name] = v
	end
	local ok = pcall(AnalyticsService.LogCustomEvent, AnalyticsService, player, event :: string, value, custom)
	count(if ok then "analytics_roblox" else "analytics_error")
end

-- the one recording path. player nil = a server event.
local function record(player: Player?, name: string, props: any?, forward: boolean?, userId: number?): boolean
	if not Config.Enabled then
		return false
	end
	if not Schema.validName(name) then
		count("analytics_invalid")
		return false
	end
	ensureSinks()
	local clean = Schema.sanitize(props, if name == "server_counters" then 300 else nil) -- counters: one prop each
	local ctx = if player then ctxs[player] else nil
	local uid = userId or (if player then player.UserId else 0)
	local device = if ctx then (ctx.device or attrDevice(player :: Player)) elseif player then attrDevice(player) else "server"
	local ms = DateTime.now().UnixTimestampMillis
	totalEvents += 1
	count("analytics_events")
	agg:add(name, device, ms / 1000)
	if ctx then
		ctx.events += 1
	end
	if player and forward ~= false then
		forwardRoblox(player, name, clean, device)
	end
	local base = clean
	base.distinct_id = if uid ~= 0 then distinctId(uid) else "server:" .. JOB_ID
	base.server_id = JOB_ID
	base.place_version = game.PlaceVersion
	base.device = device
	base.schema = Schema.Version
	base.studio = IS_STUDIO
	base["$lib"] = "forge-roblox"
	if uid == 0 then
		base["$process_person_profile"] = false
	end
	if ctx then
		base.session_id = ctx.sid
		base.locale = ctx.locale
	elseif player then
		base.locale = player.LocaleId
	end
	remember({ t = ms, name = name, uid = uid, props = base })
	if ctx and not ctx.sampled then
		return true
	end
	sink:push({
		event = name,
		properties = base,
		timestamp = DateTime.fromUnixTimestampMillis(ms):ToIsoDate(),
		uuid = string.lower(HttpService:GenerateGUID(false)), -- PostHog drops a retried duplicate
	} :: any)
	return true
end

------------------------------------------------------------------------------------------ sessions

local function cohort(ctx: Ctx): string
	return if ctx.isNew == true then "New" elseif ctx.isNew == false then "Returning" else "Unknown"
end

local function sessionStart(player: Player, force: boolean?)
	local ctx = ctxs[player]
	if not ctx or ctx.started then
		return
	end
	if not force and (ctx.device == nil or ctx.isNew == nil) then
		return
	end
	ctx.started = true
	ctx.device = ctx.device or attrDevice(player)
	local okJoin, joinData = pcall(function()
		return (player :: any):GetJoinData()
	end)
	local join = if okJoin and type(joinData) == "table" then joinData else {} :: any
	record(player, "session_start", {
		is_new = ctx.isNew,
		cohort = cohort(ctx),
		locale = ctx.locale,
		account_age_days = player.AccountAge,
		premium = player.MembershipType == Enum.MembershipType.Premium,
		referred = type(join.ReferredByPlayerId) == "number" and join.ReferredByPlayerId ~= 0,
		teleported = type(join.SourcePlaceId) == "number" and join.SourcePlaceId ~= 0,
		players_in_server = #Players:GetPlayers(),
		private_server = game.PrivateServerId ~= "",
		["$set"] = { device = ctx.device, locale = ctx.locale, last_place_version = game.PlaceVersion },
		["$set_once"] = { first_device = ctx.device, first_place_version = game.PlaceVersion },
	})
end

local function sprayStop(ctx: Ctx)
	if ctx.sprayOn then
		local s = os.clock() - ctx.sprayOn
		ctx.sprayOn = nil
		ctx.sprayS += s
		if ctx.run ~= "" then
			ctx.runSpray += s
		end
	end
end

local function round1(x: number): number
	return math.floor(x * 10 + 0.5) / 10
end

local function onInstance(player: Player)
	local ctx = ctxs[player]
	if not ctx then
		return
	end
	local id = instanceId(player)
	if id ~= "" and id ~= ctx.run then
		ctx.run, ctx.runT0, ctx.runArrived, ctx.runTruck = id, os.clock(), nil, false
		ctx.runFires, ctx.runRescues, ctx.runSpray, ctx.runEnded = 0, 0, 0, false
		ctx.missions += 1
		local squad = 0
		for _, p in Players:GetPlayers() do
			if instanceId(p) == id then
				squad += 1
			end
		end
		record(player, "mission_dispatch", {
			run = id,
			mission_id = missionOf[id],
			squad_size = squad,
			call_number = ctx.missions,
			twist = player:GetAttribute(TWIST_ATTR),
		})
	elseif id == "" and ctx.run ~= "" then
		sprayStop(ctx)
		record(player, "mission_return", {
			run = ctx.run,
			mission_id = missionOf[ctx.run],
			seconds = math.floor(os.clock() - ctx.runT0),
			ended = ctx.runEnded,
			abandoned = not ctx.runEnded,
		})
		ctx.run = ""
	end
end

local function onSprayingChanged(player: Player)
	local ctx = ctxs[player]
	if not ctx then
		return
	end
	if player:GetAttribute(Names.Attr.Spraying) == true then
		ctx.sprayOn = ctx.sprayOn or os.clock()
	else
		sprayStop(ctx)
	end
end

local function onHand(player: Player)
	local ctx = ctxs[player]
	if not ctx then
		return
	end
	local v = player:GetAttribute(HAND_ATTR)
	local now = if type(v) == "string" and v ~= "" then v else "none"
	if now == ctx.hand then
		return
	end
	local prev = ctx.hand
	ctx.hand = now
	record(player, "tool_equip", {
		item = now,
		prev = prev,
		action = if now == "none" then "stow" elseif prev == "none" then "grab" else "swap",
		in_call = ctx.run ~= "",
	})
end

local function onClaimable(player: Player)
	local ctx = ctxs[player]
	if not ctx then
		return
	end
	local v = tonumber(player:GetAttribute(CLAIMABLE_ATTR)) or 0
	if v < ctx.claimable then
		record(player, "bp_claim", { claimed = ctx.claimable - v, waiting = v })
	end
	ctx.claimable = v
end

local function onPlayer(player: Player)
	if ctxs[player] then
		return
	end
	local ctx: Ctx = {
		sid = HttpService:GenerateGUID(false),
		t0 = os.clock(),
		isNew = nil,
		device = nil,
		locale = player.LocaleId,
		started = false,
		sampled = math.random() < Config.SampleRate,
		screen = "world",
		funnel = {},
		missions = 0,
		sprayS = 0,
		sprayOn = nil,
		bpXp = 0,
		firesOut = 0,
		run = "",
		runT0 = 0,
		runArrived = nil,
		runTruck = false,
		runFires = 0,
		runRescues = 0,
		runSpray = 0,
		runEnded = false,
		hand = "none",
		claimable = tonumber(player:GetAttribute(CLAIMABLE_ATTR)) or 0,
		errors = 0,
		errSeen = {},
		events = 0,
	}
	ctxs[player] = ctx
	if ctx.sampled and math.random() < Config.PerfSampleRate then
		player:SetAttribute(PERF_ATTR, Config.PerfSeconds)
	end
	local doneAttr = OnboardingConfig.DoneAttr or "Onboarded"
	local function resolve()
		local d = player:GetAttribute(DEVICE_ATTR)
		if ctx.device == nil and type(d) == "string" and d ~= "" then
			ctx.device = d
		end
		local o = player:GetAttribute(doneAttr)
		if ctx.isNew == nil and type(o) == "boolean" then
			ctx.isNew = o == false
		end
		sessionStart(player)
	end
	player:GetAttributeChangedSignal(DEVICE_ATTR):Connect(resolve)
	player:GetAttributeChangedSignal(doneAttr):Connect(resolve)
	resolve()
	task.delay(Config.SessionStartWait, sessionStart, player, true)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		onInstance(player)
	end)
	player:GetAttributeChangedSignal(Names.Attr.Spraying):Connect(function()
		onSprayingChanged(player)
	end)
	player:GetAttributeChangedSignal(HAND_ATTR):Connect(function()
		onHand(player)
	end)
	player:GetAttributeChangedSignal(CLAIMABLE_ATTR):Connect(function()
		onClaimable(player)
	end)
	onInstance(player)
end

local function onLeave(player: Player)
	local ctx = ctxs[player]
	if not ctx then
		return
	end
	sprayStop(ctx)
	if not ctx.started then
		sessionStart(player, true)
	end
	local secs = os.clock() - ctx.t0
	record(player, "session_end", {
		seconds = math.floor(secs),
		minutes = math.floor(secs / 60 + 0.5),
		is_new = ctx.isNew,
		cohort = cohort(ctx),
		missions = ctx.missions,
		in_call = ctx.run ~= "",
		call_seconds = if ctx.run ~= "" then math.floor(os.clock() - ctx.runT0) else nil,
		last_screen = ctx.screen,
		onboarding_step = ctx.funnel.OnboardingV3,
		mission_step = ctx.funnel.Mission,
		spray_seconds = round1(ctx.sprayS),
		fires_out = ctx.firesOut,
		bp_xp = ctx.bpXp,
		level = player:GetAttribute("Level"),
		hand = ctx.hand,
		events = ctx.events,
	})
	ctxs[player] = nil
end

------------------------------------------------------------------------------------------ missions

local function arrivalLoop()
	while true do
		task.wait(1)
		for player, ctx in ctxs do
			if ctx.run == "" or ctx.runArrived then
				continue
			end
			local run = runModel(ctx.run)
			if run and run:GetAttribute(Names.Attr.RoundState) == "Active" then
				ctx.runArrived = os.clock()
				record(player, "mission_arrive", {
					run = ctx.run,
					mission_id = missionOf[ctx.run],
					seconds = math.floor(os.clock() - ctx.runT0),
					rode_truck = ctx.runTruck,
					twist = run:GetAttribute(TWIST_ATTR),
				})
			end
		end
	end
end

local function onMissionEnded(id: string, payload: any)
	if type(payload) ~= "table" then
		payload = {}
	end
	local run = runModel(id)
	local twist = run and run:GetAttribute(TWIST_ATTR)
	for player, ctx in ctxs do
		if ctx.run ~= id or ctx.runEnded then
			continue
		end
		ctx.runEnded = true
		sprayStop(ctx)
		if player:GetAttribute(Names.Attr.Spraying) == true then
			ctx.sprayOn = os.clock()
		end
		local stars = tonumber(payload.stars) or 0
		record(player, "mission_end", {
			run = id,
			mission_id = payload.missionId or missionOf[id],
			location = payload.locationId,
			reason = payload.reason,
			success = payload.reason == "allOut" or payload.rookieWin == true,
			stars = stars,
			stars_text = tostring(stars),
			seconds = tonumber(payload.seconds),
			arrival_seconds = tonumber(payload.arrivalSeconds),
			fires_out_team = tonumber(payload.firesOut),
			rescued_team = tonumber(payload.rescued),
			trapped = tonumber(payload.trapped),
			lost = tonumber(payload.lost),
			burning_at_end = tonumber(payload.burningAtEnd),
			integrity = tonumber(payload.buildingIntegrity),
			squad_size = tonumber(payload.squadSize),
			rookie = payload.rookie == true,
			rookie_win = payload.rookieWin == true,
			new_record = payload.newRecord == true,
			twist = if type(twist) == "string" then twist else (player:GetAttribute(TWIST_ATTR) or "none"),
			my_fires_out = ctx.runFires,
			my_rescues = ctx.runRescues,
			my_spray_seconds = round1(ctx.runSpray),
			rode_truck = ctx.runTruck,
		})
	end
	task.delay(600, function()
		missionOf[id] = nil
	end)
end

------------------------------------------------------------------------------------------ purchases

local function passKey(id: number): string
	for k, v in MonetizationConfig.GamePasses or {} do
		if v == id then
			return k
		end
	end
	return "unknown"
end

local function productKey(id: number): string
	for _, p in MonetizationConfig.DonationProducts or {} do
		if type(p) == "table" and p.id == id then
			return `donation_{p.robux}`
		end
	end
	return "unknown"
end

local function priceOfPass(id: number): number?
	if passPrice[id] then
		return passPrice[id]
	end
	local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, id, Enum.InfoType.GamePass)
	if ok and type(info) == "table" and type(info.PriceInRobux) == "number" then
		passPrice[id] = info.PriceInRobux
		return info.PriceInRobux
	end
	return nil
end

local function onPassFinished(player: Player, passId: number, purchased: boolean)
	record(player, "purchase", {
		kind = "pass",
		id = passId,
		key = passKey(passId),
		purchased = purchased == true,
		price = priceOfPass(passId),
		in_call = instanceId(player) ~= "",
		screen = ctxs[player] and ctxs[player].screen,
	})
end

------------------------------------------------------------------------------------------ errors

local function serverError(message: string, trace: string, scr: Instance?)
	local now = os.clock()
	if now - errWindow.at >= 60 then
		errWindow.at, errWindow.n, errWindow.seen = now, 0, {}
	end
	local where = if scr then scr:GetFullName() else "?"
	local key = where .. "|" .. string.sub(message, 1, 80)
	if errWindow.seen[key] or errWindow.n >= Config.ServerErrorsPerMinute then
		errWindow.repeats += 1
		count("analytics_errors_repeat")
		return
	end
	errWindow.seen[key] = true
	errWindow.n += 1
	local names = {}
	for _, p in Players:GetPlayers() do
		table.insert(names, p.Name)
		table.insert(names, p.DisplayName)
	end
	record(nil, "error", {
		side = "server",
		message = Schema.scrub(message, names, 300),
		script = Schema.scrub(where, names, 150),
		trace = Schema.scrub(trace or "", names, 400),
	})
end

------------------------------------------------------------------------------------------ client

local function onClient(player: Player, kind: any, data: any)
	local ctx = ctxs[player]
	if not ctx or type(data) ~= "table" then
		return
	end
	if kind == "ui" then
		local screen = data.screen
		if not Schema.isScreen(screen) then
			return
		end
		if data.open == true then
			ctx.screen = screen
			record(player, "ui_open", { screen = screen, in_call = ctx.run ~= "" })
		else
			if ctx.screen == screen then
				ctx.screen = "world"
			end
			local secs = tonumber(data.seconds)
			record(player, "ui_close", {
				screen = screen,
				seconds = if secs then math.clamp(round1(secs), 0, 86400) else nil,
				in_call = ctx.run ~= "",
			})
		end
	elseif kind == "error" then
		if ctx.errors >= Config.ClientErrorsPerSession or type(data.message) ~= "string" then
			return
		end
		local names = { player.Name, player.DisplayName }
		local msg = Schema.scrub(data.message, names, 300)
		local src = Schema.scrub(if type(data.source) == "string" then data.source else "?", names, 150)
		local key = src .. "|" .. string.sub(msg, 1, 80)
		if ctx.errSeen[key] then
			return
		end
		ctx.errSeen[key] = true
		ctx.errors += 1
		record(player, "error", {
			side = "client",
			message = msg,
			script = src,
			trace = Schema.scrub(if type(data.trace) == "string" then data.trace else "", names, 400),
		})
	elseif kind == "perf" then
		if player:GetAttribute(PERF_ATTR) == nil then
			return
		end
		local fps = tonumber(data.fps)
		local ping = tonumber(data.ping)
		if not fps or fps ~= fps or fps < 0 or fps > 1000 then
			return
		end
		local pingMs = if ping and ping == ping then math.clamp(math.floor(ping), 0, 60000) else nil
		local mem = tonumber(data.mem)
		local quality = tonumber(data.quality)
		local low = tonumber(data.fps_low)
		record(player, "perf", {
			fps = round1(fps),
			fps_low = if low and low == low then math.clamp(round1(low), 0, 1000) else nil,
			fps_bucket = Schema.fpsBucket(fps),
			ping_ms = pingMs,
			ping_bucket = if pingMs then Schema.pingBucket(pingMs) else "none",
			server_ping_ms = (function(): number?
				local ok, v = pcall(player.GetNetworkPing, player)
				return if ok and type(v) == "number" then math.floor(v * 1000) else nil
			end)(),
			mem_mb = if mem and mem == mem then math.clamp(math.floor(mem), 0, 100000) else nil,
			quality = if quality and quality == quality then math.clamp(math.floor(quality), 0, 21) else nil,
			in_call = ctx.run ~= "",
			screen = ctx.screen,
		})
	end
end

------------------------------------------------------------------------------------------ server loops

local function heartbeat()
	local runs = workspace:FindFirstChild("Runs")
	local s = sink:state()
	record(nil, "server_heartbeat", {
		players = #Players:GetPlayers(),
		uptime_s = math.floor(os.clock() - startedAt),
		server_fps = round1(workspace:GetRealPhysicsFPS()),
		heartbeat_ms = round1(Stats.HeartbeatTimeMs),
		mem_mb = math.floor(Stats:GetTotalMemoryUsageMb()),
		runs = if runs then #runs:GetChildren() else 0,
		events_total = totalEvents,
		buffered = s.buffered,
		dropped = s.stats.dropped,
		errors_repeat = errWindow.repeats,
	})
end

local lastCounters: { [string]: number } = {}
local function counters()
	local cur = Telemetry.get()
	local delta = Schema.counterDelta(lastCounters, cur)
	lastCounters = cur
	if next(delta) ~= nil then
		record(nil, "server_counters", delta)
	end
end

local function loop()
	local lastBeat, lastCount, lastAgg = os.clock(), os.clock(), os.clock()
	while true do
		task.wait(1)
		local now = os.clock()
		if now - lastBeat >= Config.HeartbeatSeconds then
			lastBeat = now
			pcall(heartbeat)
		end
		if now - lastCount >= Config.CountersSeconds then
			lastCount = now
			pcall(counters)
		end
		if now - lastAgg >= Config.AggregateSeconds then
			lastAgg = now
			task.spawn(function()
				pcall(agg.flush, agg)
			end)
		end
		pcall(sink.tick, sink)
	end
end

------------------------------------------------------------------------------------------ public API

function TrackService:Event(player: Player, name: string, props: { [string]: any }?): boolean
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false
	end
	return record(player, name, props)
end

function TrackService:Server(name: string, props: { [string]: any }?): boolean
	return record(nil, name, props)
end

-- FunnelService: one AnalyticsService call it made (already sent to Roblox; stored durably here)
function TrackService:Mirror(method: string, ...: any)
	local args = table.pack(...)
	local player = args[1]
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	local perMinute = Config.RobloxPerMinuteBase + Config.RobloxPerMinutePerPlayer * #Players:GetPlayers()
	Schema.allow(robloxBucket, os.clock(), perMinute) -- it used Roblox budget too
	local function positional(f: any): { [number]: any }
		local out = {}
		if type(f) == "table" then
			for i = 1, 3 do
				out[i] = f["CustomField0" .. i]
			end
		end
		return out
	end
	local ctx = ctxs[player]
	if method == "LogCustomEvent" then
		local event = args[2]
		if type(event) == "string" then
			record(player, event, Schema.mirrorProps(event, args[3], positional(args[4])), false)
		end
	elseif method == "LogFunnelStepEvent" or method == "LogOnboardingFunnelStepEvent" then
		local funnel, session, step, stepName, fields
		if method == "LogFunnelStepEvent" then
			funnel, session, step, stepName, fields = args[2], args[3], args[4], args[5], args[6]
		else
			funnel, session, step, stepName, fields = "Onboarding", nil, args[2], args[3], args[4]
		end
		local f = positional(fields)
		if ctx and type(funnel) == "string" then
			ctx.funnel[funnel] = `{step} {stepName}`
		end
		record(player, "funnel_step", {
			funnel = funnel,
			funnel_session = session,
			step = tonumber(step),
			step_name = stepName,
			field1 = f[1],
			reason = f[2],
			rbx = true,
		}, false)
	end
end

function TrackService:Receipt(receipt: any, decision: any)
	if type(receipt) ~= "table" or decision ~= Enum.ProductPurchaseDecision.PurchaseGranted then
		return
	end
	local player = Players:GetPlayerByUserId(tonumber(receipt.PlayerId) or 0)
	local id = tonumber(receipt.ProductId) or 0
	local props = {
		kind = "product",
		id = id,
		key = productKey(id),
		purchased = true,
		price = tonumber(receipt.CurrencySpent),
	}
	if player then
		record(player, "purchase", props)
	else
		record(nil, "purchase", props, false, tonumber(receipt.PlayerId))
	end
end

------------------------------------------------------------------------------------------ lifecycle

function TrackService:Init(all: { [string]: any })
	services = all
end

function TrackService:Start()
	ensureSinks()
	local buffered = sink:size()
	pcall(sink.resolveKey, sink)
	if sink.mode == "off" and buffered > 0 then
		Schema.take(sink.buffer, buffered) -- no sink: forget what was held
	end
	record(nil, "server_start", {
		studio = IS_STUDIO,
		private_server = game.PrivateServerId ~= "",
		max_players = Players.MaxPlayers,
		posthog = sink.mode,
	})

	local remote = Net.event("Analytics", "Client")
	Net.onServer(remote, { rate = 2, burst = 10 }, onClient)

	local function connect(serviceName: string, signal: string, fn: (...any) -> ())
		local svc = services[serviceName]
		if svc and svc[signal] and type(svc[signal].Connect) == "function" then
			svc[signal]:Connect(function(...)
				local ok, err = pcall(fn, ...)
				if not ok then
					warn(`[Analytics] {serviceName}.{signal}: {err}`)
				end
			end)
		end
	end
	connect("MissionService", "MissionStarted", function(id: string, missionId: string)
		missionOf[id] = missionId
	end)
	connect("MissionService", "MissionEnded", onMissionEnded)
	connect("FireService", "Extinguished", function(part: BasePart, by: Player?)
		local ctx = by and ctxs[by]
		if not ctx then
			return
		end
		ctx.firesOut += 1
		local training = workspace:FindFirstChild("TrainingFires")
		if ctx.run == "" or (training and part:IsDescendantOf(training)) then
			return
		end
		ctx.runFires += 1
		if ctx.runFires == 1 then
			record(by :: Player, "mission_first_fire_out", {
				run = ctx.run,
				mission_id = missionOf[ctx.run],
				seconds = math.floor(os.clock() - ctx.runT0),
				seconds_on_scene = if ctx.runArrived then math.floor(os.clock() - ctx.runArrived) else nil,
			})
		end
	end)
	connect("RescueService", "Delivered", function(player: Player, _id: string, kind: string)
		local ctx = ctxs[player]
		if not ctx then
			return
		end
		if ctx.run ~= "" then
			ctx.runRescues += 1
		end
		record(player, "mission_rescue", { run = ctx.run, kind = kind, in_call = ctx.run ~= "" })
	end)
	connect("VehicleService", "Entered", function(player: Player, _truck: Model)
		local ctx = ctxs[player]
		if not ctx or ctx.run == "" or ctx.runTruck then
			return
		end
		ctx.runTruck = true
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		record(player, "mission_in_truck", {
			run = ctx.run,
			role = if seat and seat:IsA("VehicleSeat") then "driver" else "passenger",
			seconds = math.floor(os.clock() - ctx.runT0),
		})
	end)
	connect("BattlePassService", "TierUp", function(player: Player, tier: number)
		record(player, "bp_tier_up", { tier = tier, premium = player:GetAttribute("PassPremium") == true })
	end)
	connect("BattlePassService", "XpGained", function(player: Player, amount: number)
		local ctx = ctxs[player]
		if ctx and type(amount) == "number" then
			ctx.bpXp += amount
		end
	end)
	connect("AchievementService", "Unlocked", function(player: Player, id: string, xp: number)
		record(player, "achievement", { id = id, xp = xp })
	end)
	connect("DataService", "LevelUp", function(player: Player, level: number)
		record(player, "level_up", { level = level })
	end)
	connect("SquadService", "Downed", function(player: Player, cause: string, culprit: Player?)
		local ctx = ctxs[player]
		record(player, "player_downed", { cause = cause, by_player = culprit ~= nil, run = ctx and ctx.run })
	end)
	connect("SquadService", "Revived", function(player: Player, by: Player?, how: string)
		record(player, "player_revived", { how = how, by_player = by ~= nil })
	end)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player: Player, passId: number, purchased: boolean)
		pcall(onPassFinished, player, passId, purchased)
	end)
	ScriptContext.Error:Connect(function(message: string, trace: string, scr: Instance?)
		pcall(serverError, message, trace, scr)
	end)

	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(onPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		pcall(onLeave, p)
	end)
	task.spawn(arrivalLoop)
	task.spawn(loop)

	game:BindToClose(function()
		task.wait(0.5) -- let PlayerRemoving handlers record session_end
		for _, p in Players:GetPlayers() do
			pcall(onLeave, p)
		end
		pcall(counters)
		record(nil, "server_close", {
			uptime_s = math.floor(os.clock() - startedAt),
			events_total = totalEvents,
			dropped = sink.stats.dropped,
		})
		local deadline = os.clock() + (if IS_STUDIO then 3 else 20)
		task.spawn(function()
			pcall(agg.flush, agg)
		end)
		pcall(sink.close, sink, deadline)
	end)
end

------------------------------------------------------------------------------------------ test hooks

function TrackService:_recent(n: number?): string
	local out = {}
	local k = math.clamp(tonumber(n) or 30, 1, #recent)
	for i = math.max(1, #recent - k + 1), #recent do
		table.insert(out, recent[i])
	end
	return HttpService:JSONEncode(out)
end

function TrackService:_state(): string
	ensureSinks()
	local players = {}
	for p, c in ctxs do
		players[tostring(p.UserId)] = {
			session = c.sid,
			device = c.device,
			isNew = c.isNew,
			started = c.started,
			sampled = c.sampled,
			screen = c.screen,
			run = c.run,
			missions = c.missions,
			spray = round1(c.sprayS),
			hand = c.hand,
			funnel = c.funnel,
			events = c.events,
		}
	end
	return HttpService:JSONEncode({
		events = totalEvents,
		sink = sink:state(),
		aggregate = agg:state(),
		players = players,
		jobId = JOB_ID,
	})
end

function TrackService:_flush(): string
	ensureSinks()
	sink.lastFlush = -math.huge
	sink:tick()
	return HttpService:JSONEncode(sink:state())
end

function TrackService:_payloads(): string
	ensureSinks()
	return HttpService:JSONEncode(sink.payloads)
end

function TrackService:_rekey(): string
	ensureSinks()
	sink:resolveKey()
	return HttpService:JSONEncode(sink:state())
end

return TrackService
