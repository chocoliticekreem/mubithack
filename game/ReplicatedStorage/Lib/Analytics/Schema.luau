--!strict
-- Analytics/Schema [owner: Analytics]. Pure rules for the analytics pipeline (no Roblox APIs, so
-- game/tests/analytics.spec.luau runs it with the luau CLI). Services/TrackService records events,
-- Lib/Analytics/PostHogSink and DailyAggregate store them; StarterPlayerScripts AnalyticsController
-- uses the client parts (Screens, buckets). Full event list: docs/game/20-analytics.md.
--
--   Schema.Version                          -- bumps when a prop changes meaning (sent as `schema`)
--   Schema.Events                           -- snake_case events TrackService records itself (name -> when)
--   Schema.validName(name) -> boolean       -- ^[%a][%w_]*$, <= 48 chars
--   Schema.sanitize(props, maxKeys?) -> (clean, dropped)  -- flat string/number/boolean props only
--   Schema.Roblox                           -- which events ALSO go to Roblox AnalyticsService (100-name cap)
--   Schema.robloxArgs(name, props, device) -> (event, value, { f1, f2, f3 })?
--   Schema.FieldLabels, Schema.mirrorProps(event, value, fields) -- Roblox custom event -> durable props
--   Schema.Screens, Schema.isScreen(name)   -- popup / panel ScreenGuis the client reports open / closed
--   Schema.fpsBucket(fps), Schema.pingBucket(ms)
--   Schema.buffer(cap), Schema.push(buf, x) -> boolean, Schema.take(buf, n) -> { x }  -- drop-newest FIFO
--   Schema.backoff(attempt) -> seconds      -- 2, 4, 8, 16, 32, 60, 60 ...
--   Schema.bucket(perMinute), Schema.allow(bucket, now, perMinute) -> boolean  -- token bucket
--   Schema.dayKey(unixSeconds) -> "YYYY-MM-DD" (UTC)
--   Schema.shard(text, n) -> 0..n-1, Schema.hash64(text) -> 16 hex chars (FNV-1a, two seeds)
--   Schema.aggAdd(agg, name, device, n?), Schema.aggMerge(stored, delta) -> stored
--   Schema.counterDelta(prev, cur) -> { [name]: number }  -- ForgeTelemetry counters that moved
--   Schema.scrub(text, names, maxLen?) -> string -- error text without player names, capped
--   Schema.chunkBySize(items, sizes, maxBytes) -> { { item } }
local Schema = {}

Schema.Version = 1

-- Events TrackService records itself. Roblox custom events / funnel steps made by FunnelService are
-- mirrored under their own names too (see docs/game/20-analytics.md, "Mirrored Roblox events").
Schema.Events = table.freeze({
	server_start = "a server booted (server event)",
	server_heartbeat = "every Config.HeartbeatSeconds: players, server fps, memory, uptime (server event)",
	server_counters = "every Config.CountersSeconds: ForgeTelemetry counters that moved (server event)",
	server_close = "BindToClose: uptime, events recorded, dropped (server event)",
	session_start = "the player's device + new/returning are known (or 15 s passed)",
	session_end = "PlayerRemoving: seconds, missions, last screen, furthest onboarding step, in a call?",
	funnel_step = "every Roblox funnel step (Onboarding, OnboardingV3, Mission) FunnelService logs",
	mission_dispatch = "InstanceId set: the player was launched onto a call",
	mission_in_truck = "first time in a truck on this call (driver | passenger)",
	mission_arrive = "the call's run went Active (on scene)",
	mission_first_fire_out = "first fire this player put out on this call",
	mission_rescue = "the player carried a rescue in (RescueService.Delivered)",
	mission_end = "MissionService.MissionEnded: reason, success, stars, seconds, twist, my fires / rescues / spray",
	mission_return = "InstanceId back to \"\": ended (results seen) or abandoned",
	tool_equip = "the item in hand changed (InvHand): grab, swap or put away",
	purchase = "game pass prompt finished (purchased or not) or a developer product was granted",
	bp_tier_up = "battle pass tier up",
	bp_claim = "battle pass rewards claimed (PassClaimable went down)",
	achievement = "achievement unlocked",
	level_up = "player level up",
	player_downed = "downed on a call (cause)",
	player_revived = "revived (how)",
	ui_open = "a popup / panel opened on the client (screen)",
	ui_close = "it closed (screen, seconds open)",
	perf = "sampled client performance: fps, fps bucket, ping, memory, graphics quality",
	error = "a script error (side server | client), rate-limited and deduplicated",
})

local NAME_PATTERN = "^[%a][%w_]*$"
local MAX_NAME = 48
local MAX_STRING = 200
local MAX_KEY = 40

function Schema.validName(name: any): boolean
	return type(name) == "string" and #name <= MAX_NAME and string.match(name, NAME_PATTERN) ~= nil
end

-- Flat, JSON-safe props: string (capped), finite number, boolean. Nested tables, Instances, NaN and
-- odd keys are dropped (counted). Keys starting "$" are kept (PostHog's $set / $set_once use tables:
-- only those two may be one level deep).
function Schema.sanitize(props: any, maxKeys: number?): ({ [string]: any }, number)
	local out: { [string]: any } = {}
	local dropped = 0
	if type(props) ~= "table" then
		return out, 0
	end
	local cap = maxKeys or 40
	local n = 0
	for k, v in props do
		if type(k) ~= "string" or #k == 0 or #k > MAX_KEY then
			dropped += 1
			continue
		end
		local t = type(v)
		local clean: any = nil
		if t == "string" then
			clean = string.sub(v, 1, MAX_STRING)
		elseif t == "number" then
			if v == v and v ~= math.huge and v ~= -math.huge then
				clean = v
			end
		elseif t == "boolean" then
			clean = v
		elseif t == "table" and (k == "$set" or k == "$set_once") then
			local inner = Schema.sanitize(v, 20)
			clean = inner
		end
		if clean == nil then
			dropped += 1
			continue
		end
		n += 1
		if n > cap then
			dropped += 1
			continue
		end
		out[k] = clean
	end
	return out, dropped
end

------------------------------------------------------------------------------------- Roblox forwarding

-- Events TrackService ALSO sends to Roblox AnalyticsService:LogCustomEvent (the Creator Dashboard).
-- Roblox allows 100 custom event names per game and 3 custom fields (8,000 value combinations), so only
-- these few go there, every field is a small constant set, and FunnelService's events (already sent by
-- FunnelService) are never sent twice. value = a number prop (default 1); fields = props (f1 = device).
export type RobloxMap = { event: string, value: string?, fields: { string } }
Schema.Roblox = table.freeze({
	session_start = { event = "SessionStart", fields = { "device", "cohort" } },
	mission_end = { event = "MissionEnd", value = "seconds", fields = { "device", "reason", "stars_text" } },
	tool_equip = { event = "ToolEquip", fields = { "device", "item" } },
	purchase = { event = "PurchaseDone", value = "price", fields = { "device", "kind", "key" } },
	bp_tier_up = { event = "BattlePassTierUp", value = "tier", fields = { "device" } },
	achievement = { event = "AchievementUnlocked", fields = { "device", "id" } },
	ui_open = { event = "UiOpen", fields = { "device", "screen" } },
	perf = { event = "PerfSample", value = "fps", fields = { "device", "fps_bucket", "ping_bucket" } },
	error = { event = "ScriptError", fields = { "device", "side" } },
} :: { [string]: RobloxMap })

function Schema.robloxArgs(name: string, props: { [string]: any }, device: string): (string?, number, { string })
	local map = (Schema.Roblox :: any)[name] :: RobloxMap?
	if not map then
		return nil, 0, {}
	end
	if name == "purchase" and props.purchased ~= true then
		return nil, 0, {} -- only completed purchases go to Roblox
	end
	local value = if map.value then tonumber(props[map.value]) else 1
	local fields: { string } = {}
	for i, key in map.fields do
		local v = if key == "device" then device else props[key]
		if v == nil then
			v = "none"
		end
		fields[i] = string.sub(tostring(v), 1, 50)
	end
	return map.event, value or 0, fields
end

-- Labels for the custom fields of Roblox events FunnelService sends (mirrored to the durable sink with
-- readable prop names). Unlisted events use field1..field3.
Schema.FieldLabels = table.freeze({
	FirstSpraySeconds = { "cohort" },
	SessionMinutes = { "cohort" },
	OnboardingQuitStep = { "step_name" },
	ColdOpenSkipped = { "device" },
	OnboardingV3QuitStep = { "step_name", "device" },
	UpdateLogShown = { "version" },
	NotifyPrompted = { "where" },
	NotifyAccepted = { "where" },
	FavoritePrompted = { "where" },
	FavoriteAccepted = { "where" },
	OfferShown = { "offer" },
	OfferClicked = { "offer" },
	OfferDeclined = { "offer" },
	OfferPurchased = { "offer" },
	PassPurchased = { "offer" },
	LikeAskShown = { "where" },
	LikeAskClosed = { "how" },
	InviteAskShown = { "where" },
	InvitePrompted = { "where" },
	InviteSent = { "where" },
	TwistRolled = { "twist" },
	TwistCompleted = { "twist" },
	CallTime = { "twist" },
	PadWaitSeconds = { "device", "kind" },
	PadLeftBeforeLaunch = { "device", "kind" },
	ResultsChoice = { "device", "kind" },
	DailyChestOpened = { "device", "reward" },
	DriveStart = { "device", "role", "context" },
	DriveArrive = { "device", "role", "context" },
	DriveQuit = { "device", "role", "detail" },
	TruckReset = { "device", "why", "context" },
	TruckStuck = { "device", "role", "why" },
} :: { [string]: { string } })

-- fields: positional custom field values (1..3)
function Schema.mirrorProps(event: string, value: any, fields: { [number]: any }): { [string]: any }
	local labels = (Schema.FieldLabels :: any)[event] or {}
	local props: { [string]: any } = { value = tonumber(value) or 0, rbx = true }
	for i = 1, 3 do
		local v = fields[i]
		if v ~= nil then
			props[labels[i] or ("field" .. i)] = tostring(v)
		end
	end
	return props
end

------------------------------------------------------------------------------------------- client

-- ScreenGuis (UiKit.screen names) whose big panel opening counts as a popup / screen. Constant set:
-- they become a Roblox custom field and the "last screen" of a quit.
Schema.Screens = table.freeze({
	"Achievements",
	"BattlePassGui",
	"DailyChest",
	"DispatchGui",
	"GearLocker",
	"GraphicsSettingsUI",
	"OfferGui",
	"Results",
	"SocialAsk",
	"StoreGui",
	"TwistGui",
	"UpdateLog",
	"ColdOpen",
	"Onboarding",
	"LobbyUI",
	"FanfareGui",
})

function Schema.isScreen(name: any): boolean
	return type(name) == "string" and table.find(Schema.Screens, name) ~= nil
end

function Schema.fpsBucket(fps: number): string
	if fps < 20 then
		return "lt20"
	elseif fps < 30 then
		return "20to30"
	elseif fps < 45 then
		return "30to45"
	elseif fps < 58 then
		return "45to58"
	end
	return "ge58"
end

function Schema.pingBucket(ms: number): string
	if ms < 80 then
		return "lt80"
	elseif ms < 150 then
		return "80to150"
	elseif ms < 300 then
		return "150to300"
	end
	return "ge300"
end

------------------------------------------------------------------------------------------- buffers

export type Buffer<T> = { items: { T }, head: number, cap: number, dropped: number }

function Schema.buffer<T>(cap: number): Buffer<T>
	return { items = {}, head = 1, cap = cap, dropped = 0 }
end

function Schema.size<T>(buf: Buffer<T>): number
	return #buf.items - buf.head + 1
end

-- false (and dropped += 1) when full: the newest event is dropped, older ones keep their order
function Schema.push<T>(buf: Buffer<T>, x: T): boolean
	if Schema.size(buf) >= buf.cap then
		buf.dropped += 1
		return false
	end
	table.insert(buf.items, x)
	return true
end

function Schema.take<T>(buf: Buffer<T>, n: number): { T }
	local out: { T } = {}
	while #out < n and buf.head <= #buf.items do
		table.insert(out, buf.items[buf.head])
		buf.items[buf.head] = nil :: any
		buf.head += 1
	end
	if buf.head > #buf.items then
		buf.items = {}
		buf.head = 1
	end
	return out
end

function Schema.backoff(attempt: number): number
	return math.min(60, 2 ^ math.max(1, attempt))
end

export type Bucket = { tokens: number, at: number }

function Schema.bucket(perMinute: number): Bucket
	return { tokens = perMinute, at = 0 }
end

function Schema.allow(b: Bucket, now: number, perMinute: number): boolean
	if b.at > 0 then
		b.tokens = math.min(perMinute, b.tokens + (now - b.at) * perMinute / 60)
	end
	b.at = now
	if b.tokens < 1 then
		return false
	end
	b.tokens -= 1
	return true
end

------------------------------------------------------------------------------------------- aggregates

function Schema.dayKey(unixSeconds: number): string
	return os.date("!%Y-%m-%d", math.floor(unixSeconds)) :: string
end

-- FNV-1a 32-bit. 16777619 = 2^24 + 403, so h * p = h * 403 + (h << 24) (mod 2^32), exact in doubles.
local function fnv1a(text: string, seed: number): number
	local h = seed
	for i = 1, #text do
		h = bit32.bxor(h, string.byte(text, i))
		h = (h * 403 + bit32.lshift(h, 24)) % 4294967296
	end
	return h
end

function Schema.shard(text: string, n: number): number
	return fnv1a(text, 2166136261) % math.max(1, n)
end

function Schema.hash64(text: string): string
	return string.format("%08x%08x", fnv1a(text, 2166136261), fnv1a(text, 3735928559))
end

export type Agg = { [string]: number } -- "event|device" -> count

function Schema.aggAdd(agg: Agg, name: string, device: string, n: number?)
	local k = name .. "|" .. device
	agg[k] = (agg[k] or 0) + (n or 1)
end

function Schema.aggMerge(stored: any, delta: Agg): { v: number, counts: Agg }
	local out: { v: number, counts: Agg } = { v = 1, counts = {} }
	if type(stored) == "table" and type(stored.counts) == "table" then
		for k, v in stored.counts do
			if type(k) == "string" and type(v) == "number" then
				out.counts[k] = v
			end
		end
	end
	for k, v in delta do
		out.counts[k] = (out.counts[k] or 0) + v
	end
	return out
end

function Schema.counterDelta(prev: { [string]: number }, cur: { [string]: number }): { [string]: number }
	local d: { [string]: number } = {}
	for k, v in cur do
		local change = v - (prev[k] or 0)
		if change ~= 0 then
			d[k] = change
		end
	end
	return d
end

-- error text without player names (Players.<name>.PlayerGui... paths, display names), capped
function Schema.scrub(text: string, names: { string }, maxLen: number?): string
	local out = string.gsub(text, "Players%.[^%.%s:]+", "Players.<player>")
	for _, n in names do
		if #n >= 3 then
			local esc = string.gsub(n, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")
			out = string.gsub(out, esc, "<player>")
		end
	end
	return string.sub(out, 1, maxLen or 300)
end

-- split items into groups whose summed size stays <= maxBytes (an item bigger than that goes alone)
function Schema.chunkBySize<T>(items: { T }, sizes: { number }, maxBytes: number): { { T } }
	local out: { { T } } = {}
	local cur: { T } = {}
	local used = 0
	for i, item in items do
		local s = sizes[i] or 0
		if #cur > 0 and used + s > maxBytes then
			table.insert(out, cur)
			cur = {}
			used = 0
		end
		table.insert(cur, item)
		used += s
	end
	if #cur > 0 then
		table.insert(out, cur)
	end
	return out
end

return Schema
