--!strict
-- Lib/Achievements/AchievementRules + Config/AchievementConfig + the profile's `achievements` (ProfileSchema).
local Spec = require("./Spec")
local R = require("../ReplicatedStorage/Lib/Achievements/AchievementRules")
local Cfg = require("../ReplicatedStorage/Config/AchievementConfig") :: any
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema")

local function def(id: string, stat: string, goal: number, extra: any?): any
	local d = { id = id, name = id, desc = id, stat = stat, goal = goal, xp = 10, tier = "bronze", icon = "*" }
	for k, v in (extra or {}) :: any do
		d[k] = v
	end
	return d
end

Spec.test("config: ids unique, stats known, goals and xp sane, ~30 visible", function()
	local seen = {}
	local visible = 0
	for _, d in Cfg.Defs do
		Spec.eq(seen[d.id], nil, `duplicate {d.id}`)
		seen[d.id] = true
		Spec.truthy(Cfg.Stats[d.stat] ~= nil, `{d.id}: unknown stat {d.stat}`)
		Spec.truthy(d.goal >= 1 and d.goal % 1 == 0, `{d.id}: goal`)
		Spec.truthy(d.xp > 0 and d.xp <= 1000, `{d.id}: xp`)
		Spec.truthy(d.tier == "bronze" or d.tier == "silver" or d.tier == "gold", `{d.id}: tier`)
		Spec.truthy(d.name == string.upper(d.name), `{d.id}: name is upper case`)
		Spec.truthy(#d.name <= 20, `{d.id}: name short`)
		if d.off ~= true then
			visible += 1
		end
	end
	Spec.truthy(visible >= 28, "about 30 achievements")
	local badges = 0
	for id, v in Cfg.BadgeIds do
		Spec.truthy(seen[id], `badge for unknown achievement {id}`)
		Spec.eq(type(v), "number")
		badges += 1
	end
	Spec.eq(badges, 10)
end)

Spec.test("config: every name, desc and toast template is a Translations key", function()
	local Keys = require("../ReplicatedStorage/Config/Translations/Keys") :: { string }
	local set = {}
	for _, k in Keys do
		set[k] = true
	end
	for _, d in Cfg.Defs do
		Spec.truthy(set[d.name], `missing key {d.name}`)
		Spec.truthy(set[d.desc], `missing key {d.desc}`)
	end
	Spec.truthy(set[Cfg.Toast], "toast template")
	Spec.truthy(set[Cfg.ToastMany], "summary toast template")
	Spec.truthy(set[Cfg.XpReason], "xp reason")
end)

Spec.test("add: sum adds positive amounts, max keeps the best", function()
	local d = R.empty()
	Spec.eq(R.add(d, "fires", 3, "sum"), true)
	Spec.eq(R.add(d, "fires", 2, "sum"), true)
	Spec.eq(R.add(d, "fires", 0, "sum"), false)
	Spec.eq(R.add(d, "fires", -5, "sum"), false)
	Spec.eq(R.value(d, "fires"), 5)
	Spec.eq(R.add(d, "level", 7, "max"), true)
	Spec.eq(R.add(d, "level", 4, "max"), false)
	Spec.eq(R.value(d, "level"), 7)
	Spec.eq(R.add(d, "fires", 0 / 0, "sum"), false, "NaN ignored")
	Spec.eq(R.value(d, "never"), 0)
end)

Spec.test("sites: distinct places, capped, never goes down", function()
	local d = R.empty()
	Spec.eq(R.addSite(d, "A", 3), true)
	Spec.eq(R.addSite(d, "A", 3), false)
	R.addSite(d, "B", 3)
	R.addSite(d, "C", 3)
	Spec.eq(R.value(d, "sites"), 3)
	Spec.eq(R.addSite(d, "D", 3), false, "full")
	Spec.eq(R.value(d, "sites"), 4, "still counted")
	Spec.eq(R.addSite(d, "", 3), false)
end)

Spec.test("newlyUnlocked + unlock: once, in config order, off defs never", function()
	local defs = { def("a", "fires", 1), def("b", "fires", 10), def("c", "fires", 1, { off = true }), def("d", "rescues", 1) }
	local d = R.empty()
	Spec.eq(#R.newlyUnlocked(defs, d), 0)
	R.add(d, "fires", 12, "sum")
	local n = R.newlyUnlocked(defs, d)
	Spec.eq(#n, 2)
	Spec.eq(n[1].id, "a")
	Spec.eq(n[2].id, "b")
	Spec.eq(R.unlock(d, "a", 100), true)
	Spec.eq(R.unlock(d, "a", 200), false, "idempotent")
	Spec.eq(d.unlocked.a, 100)
	R.unlock(d, "b", 100)
	Spec.eq(#R.newlyUnlocked(defs, d), 0)
end)

Spec.test("progress: capped at the goal, done shows full", function()
	local a = def("a", "fires", 10)
	local d = R.empty()
	R.add(d, "fires", 4, "sum")
	local cur, goal, done = R.progress(a, d)
	Spec.eq(cur, 4)
	Spec.eq(goal, 10)
	Spec.eq(done, false)
	R.add(d, "fires", 40, "sum")
	cur = R.progress(a, d)
	Spec.eq(cur, 10)
	R.unlock(d, "a", 1)
	local c2, _, d2 = R.progress(a, R.empty())
	Spec.eq(c2, 0)
	Spec.eq(d2, false)
end)

Spec.test("seed: old profiles raise stats, never lower them", function()
	local d = R.empty()
	R.add(d, "fires", 50, "sum")
	Spec.eq(R.seed(d, { fires = 20, calls = 3, bogus = 9 }, Cfg.Stats), true)
	Spec.eq(R.value(d, "fires"), 50)
	Spec.eq(R.value(d, "calls"), 3)
	Spec.eq(d.stats.bogus, nil, "unknown stats ignored")
end)

Spec.test("visible + count: pass tiers past the season and off defs hide, unlocked ones still count", function()
	local defs = { def("p25", "passTier", 25), def("p10", "passTier", 10), def("off", "x", 1, { off = true }) }
	Spec.eq(R.visible(defs[1], 20), false)
	Spec.eq(R.visible(defs[1], 100), true)
	Spec.eq(R.visible(defs[1], nil), true)
	Spec.eq(R.visible(defs[3], 100), false)
	local d = R.empty()
	local got, total = R.count(defs, d, 20)
	Spec.eq(got, 0)
	Spec.eq(total, 1)
	R.unlock(d, "p25", 1) -- earned in a longer season: keeps showing
	got, total = R.count(defs, d, 20)
	Spec.eq(got, 1)
	Spec.eq(total, 2)
end)

Spec.test("snapshot: copies unlocks, stats for every def stat incl. sites", function()
	local defs = { def("a", "fires", 1), def("s", "sites", 3) }
	local d = R.empty()
	R.add(d, "fires", 2, "sum")
	R.addSite(d, "X", 10)
	R.unlock(d, "a", 5)
	local s = R.snapshot(defs, d)
	Spec.eq(s.unlocked.a, 5)
	Spec.eq(s.stats.fires, 2)
	Spec.eq(s.stats.sites, 1)
	s.unlocked.a = 9
	Spec.eq(d.unlocked.a, 5, "a copy")
end)

Spec.test("profile: achievements default, survive reconcile, junk cleaned, old saves get one", function()
	local p = Schema.default(1000) :: any
	Spec.eq(type(p.achievements), "table")
	p.achievements.stats.fires = 12
	p.achievements.unlocked.fires_10 = 999
	p.achievements.sites.A = true
	p.achievements.stats[5] = 3
	p.achievements.stats.bad = "x"
	p.achievements.sites.B = "yes"
	p.achievements.extra = {}
	local q = Schema.reconcile(p, 1000) :: any
	Spec.eq(q.achievements.stats.fires, 12)
	Spec.eq(q.achievements.unlocked.fires_10, 999)
	Spec.eq(q.achievements.sites.A, true)
	Spec.eq(q.achievements.stats.bad, nil)
	Spec.eq(q.achievements.sites.B, nil)
	Spec.eq(q.achievements.extra, nil)
	Spec.eq(q.version, Schema.Version, "no schema bump")
	-- a v8 save from before achievements existed
	local old = Schema.default(1000) :: any
	old.achievements = nil
	local m = Schema.migrate(old, 1000) :: any
	Spec.eq(type(m.achievements.stats), "table")
	Spec.eq(next(m.achievements.unlocked), nil)
end)

return Spec.finish()
