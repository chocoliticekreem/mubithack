--!strict
-- DailyAggregate [owner: Analytics]. Totals that survive without PostHog: counts per event per device
-- per UTC day, merged into a DataStore every Config.AggregateSeconds (and on close) with UpdateAsync.
--   DataStore Config.AggregateStore, key "<YYYY-MM-DD>/s<shard>" (shard = Schema.shard(JobId)),
--   value { v = 1, counts = { ["<event>|<device>"] = n } }. A day's total = the sum of its shards.
-- Studio (unless Config.AggregateInStudio) keeps totals in memory only. A failed write keeps the counts
-- for the next try. Used only by Services/TrackService.
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Schema = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Analytics"):WaitForChild("Schema") :: ModuleScript)

local DailyAggregate = {}
DailyAggregate.__index = DailyAggregate

export type Agg = typeof(setmetatable(
	{} :: {
		cfg: any,
		shard: number,
		persist: boolean,
		deltas: { [string]: Schema.Agg }, -- day -> counts not written yet
		totals: Schema.Agg, -- this server, all days (for the test hook)
		writes: number,
		failures: number,
		busy: boolean,
	},
	DailyAggregate
))

function DailyAggregate.new(cfg: any, jobId: string, persist: boolean): Agg
	return setmetatable({
		cfg = cfg,
		shard = Schema.shard(jobId, cfg.AggregateShards),
		persist = persist and cfg.Aggregate and (not RunService:IsStudio() or cfg.AggregateInStudio),
		deltas = {},
		totals = {},
		writes = 0,
		failures = 0,
		busy = false,
	}, DailyAggregate)
end

function DailyAggregate.add(self: Agg, name: string, device: string, unixSeconds: number)
	local day = Schema.dayKey(unixSeconds)
	local d = self.deltas[day]
	if not d then
		d = {}
		self.deltas[day] = d
	end
	Schema.aggAdd(d, name, device)
	Schema.aggAdd(self.totals, name, device)
end

function DailyAggregate.key(self: Agg, day: string): string
	return `{day}/s{self.shard}`
end

-- yields; returns the number of days written
function DailyAggregate.flush(self: Agg): number
	if not self.persist or self.busy then
		if not self.persist then
			self.deltas = {}
		end
		return 0
	end
	self.busy = true
	local deltas = self.deltas
	self.deltas = {}
	local written = 0
	local ok, store = pcall(DataStoreService.GetDataStore, DataStoreService, self.cfg.AggregateStore)
	for day, counts in deltas do
		local done = ok and pcall(function()
			(store :: DataStore):UpdateAsync(self:key(day), function(old: any)
				return Schema.aggMerge(old, counts)
			end)
		end)
		if done then
			written += 1
			self.writes += 1
		else
			self.failures += 1
			local back = self.deltas[day] or {}
			for k, v in counts do
				back[k] = (back[k] or 0) + v
			end
			self.deltas[day] = back
		end
	end
	self.busy = false
	return written
end

function DailyAggregate.state(self: Agg): { [string]: any }
	return { persist = self.persist, shard = self.shard, writes = self.writes, failures = self.failures, totals = self.totals }
end

return DailyAggregate
