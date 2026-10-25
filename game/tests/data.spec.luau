--!strict
-- ProfileSchema: defaults, migrations, level curve, mission bookkeeping, cosmetics, session lock.
local Spec = require("./Spec")
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema")

local NOW = 1_792_800_000 -- a fixed unix time (Oct 2026)

local REWARDS = { Played = 25, Won = 50, PerStar = 20, PerRescue = 15, PerPanda = 40, PerFireOut = 2, PerAward = 10, MaxPerMission = 400 }
local WEIGHTS = { firesStarted = 3, downedOthers = 5, teammateSprayed = 1, blameAward = 10 }

local function results(over: { [string]: any }?): any
	local r: any = {
		locationId = "Town",
		missionId = "house_fire",
		seconds = 120,
		firesOut = 5,
		burnedParts = 3,
		rescued = 2,
		trapped = 0,
		burningAtEnd = 0,
		stars = 3,
		reason = "allOut",
		awards = {
			{ id = "hero", title = "Hero", userId = 1, value = 5, blurb = "", blame = false },
			{ id = "arsonist", title = "Arsonist", userId = 1, value = 2, blurb = "", blame = true },
			{ id = "soggy", title = "Soggy", userId = 2, value = 9, blurb = "", blame = true },
		},
		stats = {
			{ userId = 1, helmet = 1, name = "A", firesOut = 5, firesStarted = 2, water = 100, doors = 1, rescued = 2, pandas = 1, downedOthers = 1, timesDowned = 0, teammateSprayed = 4 },
			{ userId = 2, helmet = 2, name = "B", firesOut = 0, firesStarted = 0, water = 10, doors = 0, rescued = 0, pandas = 0, downedOthers = 0, timesDowned = 1, teammateSprayed = 0 },
		},
	}
	for k, v in over or {} do
		r[k] = v
	end
	return r
end

local function opts(): any
	return { rewards = REWARDS, blameWeights = WEIGHTS, winStars = 2, weekId = Schema.weekId(NOW) }
end

Spec.test("default profile is current version and level 1", function()
	local p = Schema.default(NOW)
	Spec.eq(p.version, Schema.Version)
	Spec.eq(p.level, 1)
	Spec.eq(p.xp, 0)
	Spec.eq(p.rescued.Panda, 0)
	Spec.truthy(p.cosmetics.owned[p.cosmetics.equipped.helmet], "default helmet owned")
	Spec.eq(p.settings.cameraShake, true)
end)

Spec.test("migrate(nil) gives a fresh profile", function()
	local p = Schema.migrate(nil, NOW)
	Spec.truthy(p)
	Spec.eq((p :: any).version, Schema.Version)
end)

Spec.test("migrate v1 -> v2 keeps progress and reshapes pets/cosmetics", function()
	local v1 = {
		version = 1,
		xp = 260,
		petsRescued = 3,
		civiliansRescued = 7,
		cosmetics = { "helmet_gold" },
		equippedHelmet = "helmet_gold",
		missions = { house_fire = { played = 4, won = 2, bestStars = 2 } },
	}
	local p = Schema.migrate(v1, NOW) :: any
	Spec.eq(p.version, Schema.Version)
	Spec.eq(type(p.gear), "table", "v2 -> v3 adds gear")
	Spec.eq(p.xp, 260)
	Spec.eq(p.level, 3, "100 + 150 = 250 -> level 3")
	Spec.eq(p.rescued.Dog, 3)
	Spec.eq(p.rescued.Civilian, 7)
	Spec.eq(p.petsRescued, nil)
	Spec.truthy(p.cosmetics.owned.helmet_gold)
	Spec.eq(p.cosmetics.equipped.helmet, "helmet_gold")
	Spec.eq(p.cosmetics.equipped.hose, Schema.DefaultCosmetics.hose)
	Spec.eq(p.missions.house_fire.bestSeconds, 0, "missing field filled")
	Spec.eq(p.weekly.week, Schema.weekId(NOW))
end)

Spec.test("version-less blob is treated as v1", function()
	local p = Schema.migrate({ xp = 5, petsRescued = 1 }, NOW) :: any
	Spec.eq(p.version, Schema.Version)
	Spec.eq(p.rescued.Dog, 1)
end)

Spec.test("newer schema is refused, not overwritten", function()
	local p, why = Schema.migrate({ version = Schema.Version + 1, xp = 9 }, NOW)
	Spec.eq(p, nil)
	Spec.truthy(why and string.find(why, "newer"), "reason mentions newer")
end)

Spec.test("reconcile repairs junk types and drops unknown settings", function()
	local p = Schema.migrate({
		version = 2,
		xp = "lots",
		awards = { hero = -3, [5] = 1 },
		settings = { sensitivity = "fast", bogus = 1 },
		cosmetics = { owned = {}, equipped = { helmet = "helmet_unowned" } },
	}, NOW) :: any
	Spec.eq(p.xp, 0)
	Spec.eq(p.awards.hero, 0)
	Spec.eq(p.awards[5], nil)
	Spec.eq(p.settings.sensitivity, 1)
	Spec.eq(p.settings.bogus, nil)
	Spec.eq(p.cosmetics.equipped.helmet, Schema.DefaultCosmetics.helmet, "unowned equip reset")
end)

Spec.test("level curve", function()
	local l, into, need = Schema.levelForXp(0)
	Spec.eq(l, 1)
	Spec.eq(into, 0)
	Spec.eq(need, 100)
	l, into, need = Schema.levelForXp(99)
	Spec.eq(l, 1)
	l, into, need = Schema.levelForXp(100)
	Spec.eq(l, 2)
	Spec.eq(into, 0)
	Spec.eq(need, 150)
	l = Schema.levelForXp(10 ^ 9)
	Spec.eq(l, Schema.Curve.MaxLevel)
end)

Spec.test("addXp reports level ups and ignores junk", function()
	local p = Schema.default(NOW)
	local g, lv = Schema.addXp(p, 260)
	Spec.eq(g, 260)
	Spec.eq(lv, 2)
	Spec.eq(p.level, 3)
	g, lv = Schema.addXp(p, -50)
	Spec.eq(g, 0)
	Spec.eq(p.xp, 260)
	g = Schema.addXp(p, 0 / 0)
	Spec.eq(g, 0)
end)

Spec.test("weekId changes on Monday 00:00 UTC", function()
	local monday = 4 * 86400 + 7 * 86400 * 2900 -- some Monday 00:00 UTC
	Spec.eq(Schema.weekId(monday) - Schema.weekId(monday - 1), 1)
	Spec.eq(Schema.weekId(monday + 6 * 86400 + 86399), Schema.weekId(monday))
end)

Spec.test("applyMission records played/won/stars/awards/blame/xp", function()
	local p = Schema.default(NOW)
	local s = Schema.applyMission(p, 1, "house_fire", results(), opts())
	Spec.eq(s.won, true)
	Spec.eq(s.stars, 3)
	Spec.eq(s.newBest, true)
	Spec.eq(p.missions.house_fire.played, 1)
	Spec.eq(p.missions.house_fire.won, 1)
	Spec.eq(p.missions.house_fire.bestStars, 3)
	Spec.eq(p.missions.house_fire.bestSeconds, 120)
	Spec.eq(p.missionsPlayed, 1)
	Spec.eq(p.missionsWon, 1)
	Spec.eq(p.awards.hero, 1)
	Spec.eq(p.awards.arsonist, 1)
	Spec.eq(p.awards.soggy, nil, "other player's award")
	-- blame: firesStarted 2*3 + downedOthers 1*5 + sprayed 4*1 + 1 blame award * 10 = 25
	Spec.eq(s.blamePoints, 25)
	Spec.eq(p.blamePoints, 25)
	Spec.eq(p.weekly.blamePoints, 25)
	Spec.eq(p.weekly.missions, 1)
	Spec.eq(p.firesOut, 5)
	-- xp: 25 + 50 + 3*20 + 2*15 + 1*40 + 5*2 + 2*10 = 235
	Spec.eq(s.xp, 235)
	Spec.eq(p.xp, 235)
	Spec.eq(p.level, 2)
	Spec.eq(s.levelsGained, 1)
end)

Spec.test("applyMission: a worse run keeps the best, forced end is not a win", function()
	local p = Schema.default(NOW)
	Schema.applyMission(p, 1, "house_fire", results(), opts())
	local s = Schema.applyMission(p, 1, "house_fire", results({ stars = 3, reason = "forced", seconds = 30 }), opts())
	Spec.eq(s.won, false)
	Spec.eq(s.newBest, false)
	Spec.eq(p.missions.house_fire.played, 2)
	Spec.eq(p.missions.house_fire.won, 1)
	Spec.eq(p.missions.house_fire.bestSeconds, 120, "forced run time not recorded")
end)

Spec.test("applyMission for a player with no stats still counts played", function()
	local p = Schema.default(NOW)
	local s = Schema.applyMission(p, 99, "house_fire", results({ stars = 1, reason = "time" }), opts())
	Spec.eq(s.won, false)
	Spec.eq(s.xp, 25 + 20)
	Spec.eq(s.blamePoints, 0)
	Spec.eq(p.missionsPlayed, 1)
end)

Spec.test("xp is capped per mission", function()
	local r = results()
	r.stats[1].firesOut = 10000
	local xp = Schema.xpForMission(r.stats[1], r, true, REWARDS, 0)
	Spec.eq(xp, REWARDS.MaxPerMission)
end)

Spec.test("weekly counters roll over", function()
	local p = Schema.default(NOW)
	Schema.addRescue(p, "Panda")
	Spec.eq(p.weekly.rescues, 1)
	Schema.rollWeek(p, p.weekly.week + 1)
	Spec.eq(p.weekly.rescues, 0)
	Spec.eq(p.rescued.Panda, 1, "lifetime kept")
	Schema.addRescue(p, "Dragon")
	Spec.eq(p.weekly.rescues, 0, "unknown kind ignored")
end)

Spec.test("cosmetic unlocks by level and equip only owned", function()
	local p = Schema.default(NOW)
	local catalog = {
		{ id = "helmet_red", slot = "helmet", level = 1 },
		{ id = "helmet_gold", slot = "helmet", level = 3 },
		{ id = "hose_rainbow", slot = "hose", level = 2 },
	}
	Spec.eq(#Schema.unlockCosmetics(p, catalog), 0)
	Spec.eq(Schema.equip(p, "hose", "hose_rainbow"), false)
	Schema.addXp(p, 100)
	local new = Schema.unlockCosmetics(p, catalog)
	Spec.eq(#new, 1)
	Spec.eq(new[1], "hose_rainbow")
	Spec.eq(Schema.equip(p, "hose", "hose_rainbow"), true)
	Spec.eq(p.cosmetics.equipped.hose, "hose_rainbow")
	Spec.eq(Schema.equip(p, "boots", "hose_rainbow"), false)
end)

Spec.test("settings are whitelisted and clamped", function()
	local p = Schema.default(NOW)
	Spec.eq(Schema.setSetting(p, "sensitivity", 10), true)
	Spec.eq(p.settings.sensitivity, 3)
	Spec.eq(Schema.setSetting(p, "sensitivity", "x"), false)
	Spec.eq(Schema.setSetting(p, "admin", true), false)
	Spec.eq(Schema.setSetting(p, "sfxVolume", 0 / 0), false)
end)

Spec.test("session lock: acquire, refresh, refuse, steal expired, release", function()
	local env, why = Schema.tryLock(nil, "A", 100, 60)
	Spec.truthy(env)
	Spec.eq((env :: any).lock.jobId, "A")
	Spec.eq((env :: any).lock.expires, 160)
	Spec.truthy(Schema.ownsLock(env, "A", 120))
	Spec.eq(Schema.ownsLock(env, "B", 120), false)

	local again = Schema.tryLock(env, "A", 150, 60)
	Spec.eq((again :: any).lock.expires, 210, "own lock refreshed")

	local refused
	refused, why = Schema.tryLock(again, "B", 160, 60)
	Spec.eq(refused, nil)
	Spec.truthy(why and string.find(why, "locked by A"))

	local stolen = Schema.tryLock(again, "B", 211, 60)
	Spec.eq((stolen :: any).lock.jobId, "B", "expired lock taken over")

	local rel, relWhy = Schema.release(stolen, "A", 220)
	Spec.eq(rel, nil, "A lost the session and must not clobber B")
	Spec.truthy(relWhy)
	rel = Schema.release(stolen, "B", 220)
	Spec.eq((rel :: any).lock, nil)
end)

Spec.test("lock keeps the data and wraps a bare legacy profile", function()
	local env = Schema.tryLock({ version = 1, xp = 7 }, "A", 0, 60) :: any
	Spec.eq(env.data.xp, 7)
	local env2 = Schema.tryLock({ data = { xp = 3 }, lock = nil }, "A", 0, 60) :: any
	Spec.eq(env2.data.xp, 3)
end)

Spec.test("v7 -> v8 adds updates (nothing seen yet) and keeps gifts", function()
	local p = Schema.migrate({ version = 7, xp = 120, gifts = { passes = { vip = { by = 1, at = 2 } } } }, NOW) :: any
	Spec.eq(p.version, Schema.Version)
	Spec.eq(p.updates.lastSeen, "")
	Spec.eq(p.updates.prompted, "")
	Spec.truthy(p.gifts.passes.vip, "v7 data kept")
	Spec.eq(Schema.default(NOW).updates.lastSeen, "")
end)

Spec.test("markUpdateSeen / markNotifyPrompted are once per version and repair junk", function()
	local p = Schema.migrate({ version = 8, updates = { lastSeen = 5, prompted = string.rep("x", 40), junk = true } }, NOW) :: any
	Spec.eq(p.updates.lastSeen, "", "wrong type reset")
	Spec.eq(p.updates.prompted, "", "too long reset")
	Spec.eq(p.updates.junk, nil, "unknown key dropped")
	Spec.eq(Schema.markUpdateSeen(p, "2026.10.24"), true)
	Spec.eq(Schema.markUpdateSeen(p, "2026.10.24"), false, "second time is a no-op")
	Spec.eq(p.updates.lastSeen, "2026.10.24")
	Spec.eq(Schema.markUpdateSeen(p, ""), false)
	Spec.eq(Schema.markUpdateSeen(p, 7 :: any), false)
	Spec.eq(Schema.markNotifyPrompted(p, "2026.10.24"), true)
	Spec.eq(Schema.markNotifyPrompted(p, "2026.10.24"), false)
	Spec.eq(Schema.markNotifyPrompted(p, "2026.11.01"), true, "a new version may prompt once more")
	p.updates = nil
	Spec.eq(Schema.markUpdateSeen(p, "2026.11.01"), true, "missing table is recreated")
end)

Spec.test("updates.likeAsks: starts at 0, repairs junk, counts up", function()
	Spec.eq(Schema.default(NOW).updates.likeAsks, 0)
	local old = Schema.migrate({ version = 8, updates = { lastSeen = "2026.10.24", prompted = "" } }, NOW) :: any
	Spec.eq(old.updates.likeAsks, 0, "a v8 save without it reads as 0")
	Spec.eq(old.updates.lastSeen, "2026.10.24", "kept")
	local bad = Schema.migrate({ version = 8, updates = { likeAsks = "lots" } }, NOW) :: any
	Spec.eq(bad.updates.likeAsks, 0, "wrong type reset")
	local neg = Schema.migrate({ version = 8, updates = { likeAsks = -4 } }, NOW) :: any
	Spec.eq(neg.updates.likeAsks, 0, "negative clamped")
	Spec.eq(Schema.markLikeAsked(old), 1)
	Spec.eq(Schema.markLikeAsked(old), 2)
	Spec.eq(Schema.reconcile(old, NOW).updates.likeAsks, 2, "survives a reconcile")
	old.updates = nil
	Spec.eq(Schema.markLikeAsked(old), 1, "missing table is recreated")
end)

return Spec.finish()
