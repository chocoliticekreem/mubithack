--!strict
-- Analytics/Schema: event names, prop sanitizing, Roblox forwarding limits, buffers, backoff, aggregates.
local Spec = require("./Spec")
local Schema = require("../ReplicatedStorage/Lib/Analytics/Schema")
local Funnel = require("../ReplicatedStorage/Lib/Onboarding/Funnel")

Spec.test("event names are valid identifiers", function()
	for name in Schema.Events do
		Spec.truthy(Schema.validName(name), name)
	end
	Spec.truthy(not Schema.validName("bad name"))
	Spec.truthy(not Schema.validName("1abc"))
	Spec.truthy(not Schema.validName(string.rep("a", 49)))
	Spec.truthy(not Schema.validName(nil))
	-- every Roblox custom event FunnelService sends is mirrored under its own name
	for name in Funnel.Events do
		Spec.truthy(Schema.validName(name), name)
	end
end)

Spec.test("sanitize keeps flat JSON-safe props only", function()
	local clean, dropped = Schema.sanitize({
		a = "x",
		n = 3,
		b = true,
		nan = 0 / 0,
		inf = math.huge,
		nested = { 1 },
		["$set"] = { device = "PC", bad = { 1 } },
		[5] = "numeric key",
		long = string.rep("z", 500),
	})
	Spec.eq(clean.a, "x")
	Spec.eq(clean.n, 3)
	Spec.eq(clean.b, true)
	Spec.eq(clean.nan, nil)
	Spec.eq(clean.inf, nil)
	Spec.eq(clean.nested, nil)
	Spec.eq(clean["$set"].device, "PC")
	Spec.eq(clean["$set"].bad, nil)
	Spec.eq(#clean.long, 200)
	Spec.eq(dropped, 4)
	local none, d0 = Schema.sanitize(nil)
	Spec.eq(next(none), nil)
	Spec.eq(d0, 0)
	local many = {}
	for i = 1, 60 do
		many["k" .. i] = i
	end
	local capped, d = Schema.sanitize(many, 40)
	local n = 0
	for _ in capped do
		n += 1
	end
	Spec.eq(n, 40)
	Spec.eq(d, 20)
end)

Spec.test("Roblox forwarding stays inside Roblox's limits", function()
	local names = 0
	local funnelNames = 0
	for _ in Funnel.Events do
		funnelNames += 1
	end
	for name, map in Schema.Roblox do
		names += 1
		Spec.truthy(Schema.Events[name] ~= nil, "forwarded event is a TrackService event: " .. name)
		Spec.truthy(#map.fields <= 3, "3 custom fields max: " .. name)
		Spec.eq(map.fields[1], "device")
		Spec.truthy(Funnel.Events[map.event] == nil, "never duplicates a FunnelService event: " .. map.event)
	end
	-- Roblox allows 100 custom event names per game; leave headroom
	Spec.truthy(names + funnelNames <= 80, `custom event names {names + funnelNames}`)
	local ev, value, fields = Schema.robloxArgs("mission_end", { seconds = 95, reason = "allOut", stars_text = "3" }, "Phone")
	Spec.eq(ev, "MissionEnd")
	Spec.eq(value, 95)
	Spec.eq(fields[1], "Phone")
	Spec.eq(fields[2], "allOut")
	Spec.eq(fields[3], "3")
	local e2, v2, f2 = Schema.robloxArgs("tool_equip", {}, "PC")
	Spec.eq(e2, "ToolEquip")
	Spec.eq(v2, 1)
	Spec.eq(f2[2], "none")
	Spec.eq((Schema.robloxArgs("session_end", {}, "PC")), nil) -- not forwarded
	Spec.eq((Schema.robloxArgs("purchase", { purchased = false }, "PC")), nil) -- only completed buys
	Spec.eq((Schema.robloxArgs("purchase", { purchased = true, price = 299, kind = "pass", key = "Helicopter" }, "PC")), "PurchaseDone")
end)

Spec.test("mirrored Roblox events get readable field names", function()
	local p = Schema.mirrorProps("DriveQuit", 120, { "Phone", "driver", "left|t30-60" })
	Spec.eq(p.value, 120)
	Spec.eq(p.device, "Phone")
	Spec.eq(p.role, "driver")
	Spec.eq(p.detail, "left|t30-60")
	Spec.eq(p.rbx, true)
	local q = Schema.mirrorProps("SomethingNew", "x", { "a" })
	Spec.eq(q.value, 0)
	Spec.eq(q.field1, "a")
	Spec.eq(q.field2, nil)
end)

Spec.test("screens and perf buckets", function()
	Spec.truthy(Schema.isScreen("StoreGui"))
	Spec.truthy(not Schema.isScreen("Hud"))
	Spec.truthy(not Schema.isScreen(42))
	Spec.eq(Schema.fpsBucket(12), "lt20")
	Spec.eq(Schema.fpsBucket(29.9), "20to30")
	Spec.eq(Schema.fpsBucket(60), "ge58")
	Spec.eq(Schema.pingBucket(50), "lt80")
	Spec.eq(Schema.pingBucket(400), "ge300")
end)

Spec.test("buffer drops the newest when full and keeps order", function()
	local b = Schema.buffer(3)
	Spec.truthy(Schema.push(b, 1))
	Spec.truthy(Schema.push(b, 2))
	Spec.truthy(Schema.push(b, 3))
	Spec.truthy(not Schema.push(b, 4))
	Spec.eq(b.dropped, 1)
	local first = Schema.take(b, 2)
	Spec.eq(first[1], 1)
	Spec.eq(first[2], 2)
	Spec.eq(Schema.size(b), 1)
	Spec.truthy(Schema.push(b, 5))
	local rest = Schema.take(b, 10)
	Spec.eq(#rest, 2)
	Spec.eq(rest[1], 3)
	Spec.eq(rest[2], 5)
	Spec.eq(Schema.size(b), 0)
end)

Spec.test("backoff and token bucket", function()
	Spec.eq(Schema.backoff(1), 2)
	Spec.eq(Schema.backoff(3), 8)
	Spec.eq(Schema.backoff(10), 60)
	local bucket = Schema.bucket(2)
	Spec.truthy(Schema.allow(bucket, 100, 2))
	Spec.truthy(Schema.allow(bucket, 100, 2))
	Spec.truthy(not Schema.allow(bucket, 100, 2))
	Spec.truthy(Schema.allow(bucket, 130, 2)) -- 30 s later: one token back
	Spec.truthy(not Schema.allow(bucket, 130, 2))
end)

Spec.test("daily aggregates", function()
	Spec.eq(Schema.dayKey(0), "1970-01-01")
	Spec.eq(Schema.dayKey(1792972800 + 3600), "2026-10-26")
	local a = {}
	Schema.aggAdd(a, "session_start", "Phone")
	Schema.aggAdd(a, "session_start", "Phone")
	Schema.aggAdd(a, "perf", "PC", 3)
	Spec.eq(a["session_start|Phone"], 2)
	local merged = Schema.aggMerge({ v = 1, counts = { ["session_start|Phone"] = 10, junk = "x" } }, a)
	Spec.eq(merged.counts["session_start|Phone"], 12)
	Spec.eq(merged.counts["perf|PC"], 3)
	Spec.eq(merged.counts.junk, nil)
	Spec.eq(Schema.aggMerge(nil, a).counts["perf|PC"], 3)
	local s = Schema.shard("2f0e6b2a-job", 16)
	Spec.truthy(s >= 0 and s < 16)
	Spec.eq(Schema.shard("2f0e6b2a-job", 16), s)
	Spec.eq(#Schema.hash64("forge:123"), 16)
	Spec.truthy(Schema.hash64("forge:123") ~= Schema.hash64("forge:124"))
	-- FNV-1a reference value ("a" -> 0xe40c292c)
	Spec.eq(string.sub(Schema.hash64("a"), 1, 8), "e40c292c")
end)

Spec.test("counter deltas", function()
	local d = Schema.counterDelta({ a = 1, b = 5 }, { a = 1, b = 7, c = 2 })
	Spec.eq(d.a, nil)
	Spec.eq(d.b, 2)
	Spec.eq(d.c, 2)
end)

Spec.test("scrub removes player names and caps length", function()
	local s = Schema.scrub("Players.CoolKid99.PlayerGui.Hud:12: CoolKid99 broke it (Cool.Kid)", { "CoolKid99", "Cool.Kid" })
	Spec.truthy(string.find(s, "CoolKid99", 1, true) == nil, s)
	Spec.truthy(string.find(s, "Cool.Kid", 1, true) == nil, s)
	Spec.truthy(string.find(s, "Players.<player>.PlayerGui", 1, true) ~= nil, s)
	Spec.eq(#Schema.scrub(string.rep("x", 1000), {}, 300), 300)
end)

Spec.test("chunkBySize keeps groups under the cap", function()
	local groups = Schema.chunkBySize({ "a", "b", "c", "d" }, { 10, 10, 25, 5 }, 25)
	Spec.eq(#groups, 3)
	Spec.eq(#groups[1], 2)
	Spec.eq(groups[2][1], "c")
	Spec.eq(groups[3][1], "d")
end)

return Spec.finish()
