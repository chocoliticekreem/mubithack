--!strict
-- PostHogSink [owner: Analytics]. Durable event sink: batches events and POSTs them to PostHog's
-- /batch/ endpoint (HttpService). Used only by Services/TrackService.
--   mode "off"    no key (live server) or HTTP disabled: push() drops at once, nothing is buffered
--   mode "dryrun" Studio without a key: batches are built, JSON-encoded and printed, never sent
--   mode "live"   key found: <= BatchSize events per POST, a partial batch after FlushSeconds
-- Failures: HTTP error / 429 / 5xx retry with backoff (Schema.backoff) up to MaxRetries; other 4xx are
-- dropped (bad payload). A batch that runs out of retries, or is still waiting when the server closes,
-- is spilled to a MemoryStore queue (Config.Spill) that every live server drains one item at a time.
-- The token is read from the ServerStorage attribute Config.KeyAttr, else the DataStore Config.KeyStore
-- (live only), re-checked every KeyRecheckSeconds. It never leaves the server, and it goes in the JSON
-- body because PostHog takes it only there (a Roblox Secret can only be used in a Url / header).
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local MemoryStoreService = game:GetService("MemoryStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Schema = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Analytics"):WaitForChild("Schema") :: ModuleScript)

export type Event = { event: string, properties: { [string]: any }, timestamp: string }
type Pending = { events: { Event }, attempts: number, nextAt: number }
export type Hooks = { count: (string, number?) -> (), log: (string) -> () }

local PostHogSink = {}
PostHogSink.__index = PostHogSink

export type Sink = typeof(setmetatable(
	{} :: {
		cfg: any,
		hooks: Hooks,
		key: string?,
		host: string,
		mode: string,
		keyCheckedAt: number,
		buffer: Schema.Buffer<Event>,
		pending: { Pending },
		lastFlush: number,
		lastDrain: number,
		busy: boolean,
		payloads: { string },
		stats: { [string]: number },
		warned: { [string]: boolean },
	},
	PostHogSink
))

function PostHogSink.new(cfg: any, hooks: Hooks): Sink
	local self = setmetatable({
		cfg = cfg,
		hooks = hooks,
		key = nil,
		host = cfg.Host,
		mode = "off",
		keyCheckedAt = -math.huge,
		buffer = Schema.buffer(cfg.BufferCap),
		pending = {},
		lastFlush = os.clock(),
		lastDrain = os.clock(),
		busy = false,
		payloads = {},
		stats = { sent = 0, batches = 0, failed = 0, retried = 0, dropped = 0, spilled = 0, drained = 0, dryrun = 0 },
		warned = {},
	}, PostHogSink)
	return self
end

local function httpEnabled(): boolean
	local ok, v = pcall(function()
		return HttpService.HttpEnabled
	end)
	-- unreadable: assume on and let RequestAsync say otherwise
	return not ok or v == true
end

function PostHogSink.warnOnce(self: Sink, id: string, text: string)
	if not self.warned[id] then
		self.warned[id] = true
		warn(`[Analytics] {text}`)
	end
end

-- (re)reads the key; sets mode. Yields (DataStore) in live servers.
function PostHogSink.resolveKey(self: Sink)
	self.keyCheckedAt = os.clock()
	local cfg = self.cfg
	local key: string? = nil
	local attr = ServerStorage:GetAttribute(cfg.KeyAttr)
	if type(attr) == "string" and #attr >= 8 then
		key = attr
	end
	if not key and not RunService:IsStudio() then
		local ok, v = pcall(function()
			return DataStoreService:GetDataStore(cfg.KeyStore):GetAsync(cfg.KeyName)
		end)
		if ok and type(v) == "string" and #v >= 8 then
			key = v
		end
	end
	local host = ServerStorage:GetAttribute(cfg.HostAttr)
	self.host = if type(host) == "string" and string.match(host, "^https://") then string.gsub(host, "/+$", "") else cfg.Host
	self.key = key
	local before = self.mode
	if key and httpEnabled() then
		self.mode = "live"
	elseif key then
		self.mode = "off"
		self:warnOnce("http", "PostHog key found but HTTP requests are off (Game Settings > Security > Allow HTTP Requests)")
	elseif RunService:IsStudio() and cfg.DryRunInStudio then
		self.mode = "dryrun"
	else
		self.mode = "off"
	end
	if before ~= self.mode then
		print(`[Analytics] PostHog sink: {self.mode}{if self.mode == "live" then " -> " .. self.host else ""}`)
	end
end

function PostHogSink.push(self: Sink, ev: Event)
	if self.mode == "off" then
		return
	end
	if not Schema.push(self.buffer, ev) then
		self.stats.dropped += 1
		self.hooks.count("analytics_dropped", 1)
	end
end

function PostHogSink.size(self: Sink): number
	return Schema.size(self.buffer)
end

local function encode(value: any): string?
	local ok, json = pcall(HttpService.JSONEncode, HttpService, value)
	return if ok then json else nil
end

function PostHogSink.remember(self: Sink, json: string)
	table.insert(self.payloads, json)
	if #self.payloads > 5 then
		table.remove(self.payloads, 1)
	end
end

-- one POST. "ok" | "retry" | "drop"
function PostHogSink.post(self: Sink, events: { Event }): string
	local body = encode({ api_key = self.key, historical_migration = false, batch = events })
	if not body then
		return "drop"
	end
	local logged = string.gsub(body, '"api_key":"[^"]*"', '"api_key":"<redacted>"')
	self:remember(logged)
	if RunService:IsStudio() and self.cfg.LogBatchesInStudio then
		print(`[Analytics] POST {#events} events ({#body} B): {string.sub(logged, 1, self.cfg.LogChars)}`)
	end
	local ok, res = pcall(HttpService.RequestAsync, HttpService, {
		Url = self.host .. "/batch/",
		Method = "POST",
		Headers = { ["Content-Type"] = "application/json" },
		Body = body,
	})
	if not ok then
		self:warnOnce("post_err", `PostHog POST failed: {res}`)
		return "retry"
	end
	local code = (res :: any).StatusCode
	if (res :: any).Success then
		return "ok"
	end
	self:warnOnce("post_" .. tostring(code), `PostHog POST -> HTTP {code}: {string.sub(tostring((res :: any).Body), 1, 200)}`)
	if code == 429 or code >= 500 then
		return "retry"
	end
	return "drop"
end

function PostHogSink.spill(self: Sink, events: { Event }): boolean
	if not self.cfg.Spill or RunService:IsStudio() or #events == 0 then
		return false
	end
	local sizes = {}
	for i, e in events do
		sizes[i] = #(encode(e) or "") + 1
	end
	local queue = MemoryStoreService:GetQueue(self.cfg.SpillQueue, 30)
	local allOk = true
	for _, group in Schema.chunkBySize(events, sizes, self.cfg.SpillItemBytes) do
		local json = encode(group)
		local ok = json ~= nil and #(json :: string) < 32000 and pcall(function()
			queue:AddAsync(json, self.cfg.SpillExpireSeconds)
		end)
		if ok then
			self.stats.spilled += #group
			self.hooks.count("analytics_spilled", #group)
		else
			allOk = false
			self.stats.dropped += #group
			self.hooks.count("analytics_dropped", #group)
		end
	end
	return allOk
end

function PostHogSink.giveUp(self: Sink, events: { Event })
	if not self:spill(events) then
		self.stats.dropped += #events
		self.hooks.count("analytics_dropped", #events)
	end
end

function PostHogSink.sendBatch(self: Sink, events: { Event }, attempts: number)
	if self.mode == "dryrun" then
		local json = encode({ api_key = "<none: dry run>", batch = events }) or "?"
		self:remember(json)
		self.stats.dryrun += 1
		self.stats.batches += 1
		self.hooks.count("analytics_dryrun_batches", 1)
		if self.cfg.LogBatchesInStudio then
			print(`[Analytics] dry-run batch {#events} events ({#json} B): {string.sub(json, 1, self.cfg.LogChars)}`)
		end
		return
	end
	local r = self:post(events)
	if r == "ok" then
		self.stats.sent += #events
		self.stats.batches += 1
		self.hooks.count("analytics_sent", #events)
		return
	end
	self.stats.failed += 1
	self.hooks.count("analytics_post_failed", 1)
	if r == "retry" and attempts < self.cfg.MaxRetries and #self.pending < self.cfg.MaxPendingBatches then
		self.stats.retried += 1
		table.insert(self.pending, { events = events, attempts = attempts + 1, nextAt = os.clock() + Schema.backoff(attempts + 1) })
	elseif r == "retry" then
		self:giveUp(events)
	else
		self.stats.dropped += #events
		self.hooks.count("analytics_dropped", #events)
	end
end

function PostHogSink.drain(self: Sink)
	if self.mode ~= "live" or not self.cfg.Spill or RunService:IsStudio() then
		return
	end
	local queue = MemoryStoreService:GetQueue(self.cfg.SpillQueue, 30)
	local ok, items, id = pcall(function()
		return queue:ReadAsync(1, false, 0)
	end)
	if not ok or type(items) ~= "table" or #items == 0 then
		return
	end
	local dok, events = pcall(HttpService.JSONDecode, HttpService, items[1])
	if not dok or type(events) ~= "table" then
		pcall(queue.RemoveAsync, queue, id) -- unreadable: drop it
		return
	end
	if self:post(events) == "ok" then
		pcall(queue.RemoveAsync, queue, id)
		self.stats.drained += #events
		self.stats.sent += #events
		self.hooks.count("analytics_drained", #events)
	end -- else it becomes visible again after the invisibility timeout
end

-- called every second from TrackService's loop (yields while posting)
function PostHogSink.tick(self: Sink)
	if self.busy then
		return
	end
	self.busy = true
	local now = os.clock()
	if now - self.keyCheckedAt >= self.cfg.KeyRecheckSeconds then
		pcall(self.resolveKey, self)
	end
	for i, p in self.pending do
		if p.nextAt <= now then
			table.remove(self.pending, i)
			self:sendBatch(p.events, p.attempts)
			break -- one retry per tick
		end
	end
	local n = Schema.size(self.buffer)
	if n >= self.cfg.BatchSize or (n > 0 and now - self.lastFlush >= self.cfg.FlushSeconds) then
		self.lastFlush = now
		self:sendBatch(Schema.take(self.buffer, self.cfg.BatchSize), 0)
	elseif n == 0 then
		self.lastFlush = now
	end
	if now - self.lastDrain >= self.cfg.SpillDrainSeconds then
		self.lastDrain = now
		self:drain()
	end
	self.busy = false
end

-- BindToClose: send what is buffered until the deadline, spill the rest
function PostHogSink.close(self: Sink, deadline: number)
	local waited = 0
	while self.busy and waited < 5 do
		task.wait(0.1)
		waited += 0.1
	end
	self.busy = true
	for _, p in self.pending do
		self:giveUp(p.events)
	end
	self.pending = {}
	while Schema.size(self.buffer) > 0 do
		local batch = Schema.take(self.buffer, self.cfg.BatchSize)
		if os.clock() < deadline and self.mode ~= "off" then
			self:sendBatch(batch, self.cfg.MaxRetries) -- no retries now: a failure spills at once
		else
			self:giveUp(batch)
		end
	end
	for _, p in self.pending do
		self:giveUp(p.events)
	end
	self.pending = {}
	self.busy = false
end

function PostHogSink.state(self: Sink): { [string]: any }
	return {
		mode = self.mode,
		host = self.host,
		hasKey = self.key ~= nil,
		buffered = Schema.size(self.buffer),
		pending = #self.pending,
		stats = self.stats,
	}
end

return PostHogSink
