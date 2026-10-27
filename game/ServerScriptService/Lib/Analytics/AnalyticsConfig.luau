--!strict
-- AnalyticsConfig [owner: Analytics]. Server-only knobs for Services/TrackService and its sinks. Lives in
-- ServerScriptService so clients never see it. It holds NO keys: the PostHog project token is read at
-- run time (docs/game/20-analytics.md, "Turning on PostHog"):
--   1. ServerStorage attribute  PostHogKey   (string "phc_...", set in Studio, saved with the place)
--   2. DataStore  KeyStore / KeyName          (set once from the Studio command bar or Open Cloud)
-- An optional ServerStorage attribute PostHogHost overrides Host (EU projects: https://eu.i.posthog.com).
return table.freeze({
	Enabled = true, -- false: TrackService records nothing (Roblox funnels from FunnelService still run)

	-- PostHog sink -------------------------------------------------------------------------------
	Host = "https://us.i.posthog.com", -- POST <Host>/batch/
	KeyAttr = "PostHogKey", -- ServerStorage attribute
	HostAttr = "PostHogHost", -- ServerStorage attribute (optional)
	KeyStore = "ForgeAnalyticsConfig", -- DataStore (live servers only)
	KeyName = "posthog_key",
	KeyRecheckSeconds = 300, -- a key added later (DataStore) is picked up without a restart
	BatchSize = 100, -- events per POST (<= 100)
	FlushSeconds = 10, -- a partial batch goes out after this long
	BufferCap = 3000, -- events held in memory per server; more are dropped (counted)
	MaxRetries = 5, -- per batch (backoff 2, 4, 8, 16, 32 s); then it is spilled or dropped
	MaxPendingBatches = 8, -- batches waiting on a retry; more are spilled or dropped
	SampleRate = 1.0, -- share of player SESSIONS whose events go to PostHog (daily aggregates count all)

	-- MemoryStore spill: batches that could not be sent (PostHog down, server closing) wait in a
	-- MemoryStore queue and any server sends them later. Off = they are dropped.
	Spill = true,
	SpillQueue = "ForgeAnalyticsSpill_v1",
	SpillExpireSeconds = 6 * 3600,
	SpillItemBytes = 30000, -- MemoryStore queue items must stay under 32 KB
	SpillDrainSeconds = 30, -- every server takes one spilled item per this many seconds

	-- Studio: with no key the batches are built and printed ("dry run") instead of sent
	DryRunInStudio = true,
	LogBatchesInStudio = true, -- print every batch (truncated) in Studio, key or not
	LogChars = 1500,

	-- Daily aggregate (DataStore): counts per event per device per UTC day, always on in live servers
	Aggregate = true,
	AggregateStore = "ForgeAnalyticsDaily_v1", -- key "<YYYY-MM-DD>/s<shard>"; sum the shards to read a day
	AggregateShards = 16, -- servers spread over this many keys (DataStore: 1 write / 6 s per key)
	AggregateSeconds = 300,
	AggregateInStudio = false, -- Studio keeps the totals in memory only (TrackService:_state)

	-- Roblox AnalyticsService forwarding (Schema.Roblox): self-imposed budget per server
	RobloxPerMinuteBase = 120,
	RobloxPerMinutePerPlayer = 20,

	-- what gets recorded
	HashUserIds = false, -- true: distinct_id = Schema.hash64("<salt>:<UserId>") instead of the UserId
	HashSalt = "forge-analytics",
	SessionStartWait = 15, -- s: session_start waits this long for device + new/returning
	HeartbeatSeconds = 60,
	CountersSeconds = 300,
	PerfSeconds = 120, -- client perf sample period
	PerfSampleRate = 0.25, -- share of sessions that send perf samples
	ServerErrorsPerMinute = 20, -- distinct server errors recorded per minute (repeats are counted)
	ClientErrorsPerSession = 15,
})
