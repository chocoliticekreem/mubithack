--!strict
-- First-time mission guides: Config/MissionGuides data, Lib/Onboarding/GuideFlow, ProfileSchema v4 guides.
local Spec = require("./Spec")
local Guides = require("../ReplicatedStorage/Config/MissionGuides")
local Catalog = require("../ReplicatedStorage/Config/MissionCatalog")
local Flow = require("../ReplicatedStorage/Lib/Onboarding/GuideFlow")
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema")

local NOW = 1_792_800_000

Spec.test("every catalog mission has a valid guide", function()
	local problems = Flow.validate(Guides, Catalog :: any)
	Spec.eq(#problems, 0, table.concat(problems, "; "))
end)

Spec.test("validate catches a missing guide and a bad step", function()
	local g = {
		Common = Guides.Common,
		Missions = { a = { tip = "x", steps = { { id = "s", head = "H", sub = "S", done = { kind = "nope" } } } } },
	}
	local problems = Flow.validate(g, { { id = "a" }, { id = "b" } } :: any)
	Spec.eq(#problems, 2)
end)

Spec.test("common steps resolve and overrides win", function()
	local steps = Flow.steps(Guides, "storage_fusebox")
	Spec.eq(steps[1].id, "fuse")
	Spec.eq(steps[2].id, "hose")
	Spec.eq(steps[2].head, Guides.Common.hose.head, "head kept")
	Spec.truthy(steps[2].sub ~= Guides.Common.hose.sub, "sub overridden")
	Spec.eq(steps[2].done.item, "Hose")
	Spec.eq(#Flow.steps(Guides, "no_such_mission"), 0)
	Spec.truthy(Flow.tip(Guides, "panda_zoo"))
end)

Spec.test("anyone new in the squad -> everyone gets the full guide", function()
	Spec.eq(Flow.modeFor({ true, true }), "tip")
	Spec.eq(Flow.modeFor({ true, false, true }), "full")
	Spec.eq(Flow.modeFor({ false }), "full")
	Spec.eq(Flow.modeFor({}), "tip")
end)

local function mk(): { any }
	return {
		{ id = "a", head = "A", sub = "a", done = { kind = "carrying" } },
		{ id = "b", head = "B", sub = "b", done = { kind = "near", studs = 5 }, optional = true },
		{ id = "c", head = "C", sub = "c", done = { kind = "fireOut" }, maxSeconds = 10 },
	}
end

Spec.test("steps advance on done, skip a missing optional target, time out", function()
	local s = Flow.new(mk() :: any, 0, 4)
	local step, why = Flow.tick(s, { found = true, done = false }, 1)
	Spec.eq((step :: any).id, "a")
	Spec.eq(why, nil)
	step, why = Flow.tick(s, { found = true, done = true }, 2)
	Spec.eq((step :: any).id, "b")
	Spec.eq(why, "done")
	step = Flow.tick(s, { found = false, done = false }, 3)
	Spec.eq((step :: any).id, "b", "grace not over yet")
	step, why = Flow.tick(s, { found = false, done = false }, 7.5)
	Spec.eq((step :: any).id, "c")
	Spec.eq(why, "missing")
	step, why = Flow.tick(s, { found = true, done = false }, 17.6)
	Spec.eq(step, nil)
	Spec.eq(why, "timeout")
	Spec.truthy(s.finished)
end)

Spec.test("a non-optional step waits for its target forever (until maxSeconds)", function()
	local s = Flow.new(mk() :: any, 0, 4)
	local step = Flow.tick(s, { found = false, done = false }, 100)
	Spec.eq((step :: any).id, "a")
end)

Spec.test("skip finishes the guide", function()
	local s = Flow.new(mk() :: any, 0)
	Flow.skip(s)
	Spec.eq(Flow.tick(s, { found = true, done = true }, 1), nil)
end)

Spec.test("profile v4: guides.seen defaults empty, mark/seen round-trip", function()
	local p = Schema.default(NOW)
	Spec.eq(Schema.Version, 4)
	Spec.eq(Schema.guideSeen(p, "storage_fusebox"), false)
	Spec.eq(Schema.markGuideSeen(p, "storage_fusebox"), true)
	Spec.eq(Schema.markGuideSeen(p, "storage_fusebox"), false, "second mark is a no-op")
	Spec.eq(Schema.guideSeen(p, "storage_fusebox"), true)
	Spec.eq(Schema.markGuideSeen(p, ""), false)
end)

Spec.test("migrate v3 -> v4 seeds seen from missions already played", function()
	local v3 = {
		version = 3,
		xp = 120,
		missions = { house_fire = { played = 2, won = 1, bestStars = 2, bestSeconds = 90 }, panda_zoo = { played = 0 } },
		gear = { unlocked = { Axe = true }, loadout = { "Axe" } },
	}
	local p = Schema.migrate(v3, NOW) :: any
	Spec.eq(p.version, 4)
	Spec.eq(p.guides.seen.house_fire, true)
	Spec.eq(p.guides.seen.panda_zoo, nil, "never played -> still new")
	Spec.eq(p.gear.unlocked.Axe, true, "v3 data kept")
end)

Spec.test("reconcile drops junk in guides.seen", function()
	local p = Schema.migrate({ version = 4, guides = { seen = { house_fire = true, [3] = true, zoo = "yes" } } }, NOW) :: any
	Spec.eq(p.guides.seen.house_fire, true)
	Spec.eq(p.guides.seen[3], nil)
	Spec.eq(p.guides.seen.zoo, nil)
	local q = Schema.migrate({ version = 4, guides = "broken" }, NOW) :: any
	Spec.eq(type(q.guides.seen), "table")
end)

return Spec.finish()
