--!strict
-- Lib/BattlePass/PassRules (tiers, XP, idempotent claims, equip, boosts, seasons) + ProfileSchema v6 `pass`.
local Spec = require("./Spec")
local R = require("../ReplicatedStorage/Lib/BattlePass/PassRules")
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema")

local REWARDS = {
	t1 = { Slot = "title", Name = "Rookie" },
	h1 = { Slot = "helmet", Name = "Gold", Color = "#FFC21F" },
	b5 = { Slot = "boost", Name = "+5%", Pct = 5 },
	b10 = { Slot = "boost", Name = "+10%", Pct = 10 },
	hose1 = { Slot = "hose", Name = "Lime" },
	e1 = { Slot = "emote", Name = "Spin", Style = "spin" },
	h2 = { Slot = "helmet", Name = "Chief", Chief = true },
	t2 = { Slot = "title", Name = "Chief" },
}
local OPTS: R.Opts = {
	perTier = 100,
	maxTier = 4,
	boostCap = 12,
	rewards = REWARDS,
	tiers = {
		{ Free = "t1", Premium = "h1" },
		{ Free = "b5", Premium = "b10" },
		{ Free = "hose1", Premium = "e1" },
		{ Free = "t2", Premium = "h2" },
	},
}

local function pass(xp: number): R.Pass
	local p = R.blank("S1")
	p.xp = xp
	return p
end

Spec.test("tiers and progress", function()
	Spec.eq(R.tierOf(0, OPTS), 0)
	Spec.eq(R.tierOf(99, OPTS), 0)
	Spec.eq(R.tierOf(100, OPTS), 1)
	Spec.eq(R.tierOf(99999, OPTS), 4, "capped at max tier")
	local t, into, need = R.progress(250, OPTS)
	Spec.eq(t, 2)
	Spec.eq(into, 50)
	Spec.eq(need, 100)
	local mt, mi, mn = R.progress(400, OPTS)
	Spec.eq(mt, 4)
	Spec.eq(mi, 0)
	Spec.eq(mn, 0, "max tier needs nothing")
end)

Spec.test("gain applies premium and boosts, never below 1", function()
	Spec.eq(R.gain(10, false, 1.5, 0), 10)
	Spec.eq(R.gain(10, true, 1.5, 0), 15)
	Spec.eq(R.gain(10, true, 1.5, 20), 18)
	Spec.eq(R.gain(0.2, false, 1, 0), 1)
	Spec.eq(R.gain(-5, true, 2, 0), 0)
	Spec.eq(R.gain(0 / 0, true, 2, 0), 0, "NaN")
end)

Spec.test("addXp caps at the last tier and reports tiers crossed", function()
	local p = pass(90)
	local added, before, after = R.addXp(p, 220, OPTS)
	Spec.eq(added, 220)
	Spec.eq(before, 0)
	Spec.eq(after, 3)
	added = R.addXp(p, 10000, OPTS)
	Spec.eq(p.xp, 400)
	Spec.eq(added, 90)
end)

Spec.test("claims are idempotent and gated", function()
	local p = pass(150)
	Spec.eq((R.claim(p, 2, "free", true, OPTS)), false, "tier 2 not reached")
	local ok, why, id = R.claim(p, 1, "Free", false, OPTS)
	Spec.eq(ok, true)
	Spec.eq(why, nil)
	Spec.eq(id, "t1")
	local again, why2 = R.claim(p, 1, "free", false, OPTS)
	Spec.eq(again, false)
	Spec.eq(why2, "claimed")
	Spec.eq(#p.free, 1, "no duplicate entry")
	local _, whyPrem = R.claim(p, 1, "premium", false, OPTS)
	Spec.eq(whyPrem, "premium")
	Spec.eq((R.claim(p, 1, "premium", true, OPTS)), true)
	Spec.eq(select(2, R.claim(p, 0, "free", true, OPTS)), "bad")
	Spec.eq(select(2, R.claim(p, 1.5, "free", true, OPTS)), "bad")
	Spec.eq(select(2, R.claim(p, 1, "gold", true, OPTS)), "bad")
	Spec.eq(select(2, R.claim(p, "1" :: any, "free", true, OPTS)), "bad")
end)

Spec.test("claimAll claims every reached reward once; freeOnly skips premium", function()
	local p = pass(250)
	local freeOnly = R.claimAll(p, true, OPTS, true)
	Spec.eq(#freeOnly, 2)
	Spec.eq(R.claimable(p, true, OPTS), 2, "premium still waiting")
	Spec.eq(R.claimable(p, false, OPTS), 0, "non-owner has nothing to press")
	local rest = R.claimAll(p, true, OPTS)
	Spec.eq(#rest, 2)
	Spec.eq(rest[1].track, "premium")
	Spec.eq(#R.claimAll(p, true, OPTS), 0, "second claim-all is a no-op")
	Spec.eq(R.claimable(p, true, OPTS), 0)
end)

Spec.test("owned / boosts follow premium ownership and the cap", function()
	local p = pass(400)
	R.claimAll(p, true, OPTS)
	local owned = R.owned(p, true, OPTS)
	Spec.eq(owned.h1, true)
	Spec.eq(owned.b10, true)
	Spec.eq(R.owned(p, false, OPTS).h1, nil, "premium rewards need the pass")
	Spec.eq(R.boostPct(p, false, OPTS), 5)
	Spec.eq(R.boostPct(p, true, OPTS), 12, "5 + 10 capped at 12")
end)

Spec.test("equip / unequip / sanitize", function()
	local p = pass(400)
	Spec.eq(select(2, R.equip(p, "h1", true, OPTS)), "notOwned")
	R.claimAll(p, true, OPTS)
	Spec.eq((R.equip(p, "h1", true, OPTS)), true)
	Spec.eq(p.equipped.helmet, "h1")
	Spec.eq((R.equip(p, "h2", true, OPTS)), true, "swap in the same slot")
	Spec.eq(p.equipped.helmet, "h2")
	Spec.eq(select(2, R.equip(p, "b5", true, OPTS)), "bad", "boosts are passive")
	Spec.eq(select(2, R.equip(p, "nope", true, OPTS)), "bad")
	Spec.eq(R.unequip(p, "helmet"), true)
	Spec.eq(p.equipped.helmet, nil)
	Spec.eq(R.unequip(p, "helmet"), false, "already empty")
	Spec.eq(R.unequip(p, "boost"), false)
	R.equip(p, "h1", true, OPTS)
	R.equip(p, "t1", true, OPTS)
	Spec.eq(R.sanitizeEquipped(p, false, OPTS), true, "lost premium -> premium helmet dropped")
	Spec.eq(p.equipped.helmet, nil)
	Spec.eq(p.equipped.title, "t1", "free title kept")
end)

Spec.test("reconcile fixes junk and resets on a new season", function()
	local junk: any = { season = "S1", xp = -5, free = { 1, 1, "x", 2.5, 3 }, premium = "no", equipped = { helmet = "h1", boost = "b5", [3] = "x" } }
	local p, reset = R.reconcile(junk, "S1")
	Spec.eq(reset, false)
	Spec.eq(p.xp, 0)
	Spec.eq(#p.free, 2)
	Spec.eq(#p.premium, 0)
	Spec.eq(p.equipped.helmet, "h1")
	Spec.eq(p.equipped.boost, nil)
	local old: any = { season = "S0", xp = 900, free = { 1 }, premium = {}, equipped = {}, legacy = true }
	local fresh, didReset = R.reconcile(old, "S1")
	Spec.eq(didReset, true)
	Spec.eq(fresh.xp, 0)
	Spec.eq(fresh.season, "S1")
	Spec.eq(fresh.legacy, true)
	local blankSeason, r2 = R.reconcile({ season = "", xp = 50 }, "S1")
	Spec.eq(r2, false)
	Spec.eq(blankSeason.season, "S1")
	Spec.eq(blankSeason.xp, 50)
end)

Spec.test("legacy store merges once", function()
	local p = pass(120)
	p.free = { 1 }
	Spec.eq(R.mergeLegacy(p, { xp = 300, free = { 1, 2 }, premium = { 1, 99 } }, OPTS), true)
	Spec.eq(p.xp, 300)
	Spec.eq(#p.free, 2)
	Spec.eq(#p.premium, 1, "out-of-range tier dropped")
	Spec.eq(R.mergeLegacy(p, { xp = 999 }, OPTS), false, "only once")
	Spec.eq(p.xp, 300)
end)

Spec.test("countdown text", function()
	Spec.eq(R.countdown(0), "ENDED")
	Spec.eq(R.countdown(3 * 86400 + 5 * 3600 + 7), "3d 5h")
	Spec.eq(R.countdown(2 * 3600 + 15 * 60), "2h 15m")
	Spec.eq(R.countdown(130), "2m 10s")
end)

Spec.test("ProfileSchema v6 adds an empty pass and migrates v5", function()
	Spec.eq(Schema.Version >= 6, true)
	local d = Schema.default(1_792_800_000) :: any
	Spec.eq(type(d.pass), "table")
	Spec.eq(d.pass.xp, 0)
	local m = Schema.migrate({ version = 5, xp = 50, donations = { robux = 0, count = 0, receipts = {} } }, 1_792_800_000) :: any
	Spec.eq(m.version, Schema.Version)
	Spec.eq(m.pass.xp, 0)
	Spec.eq(#m.pass.free, 0)
	local broken = Schema.migrate({ version = 6, pass = { xp = "lots", free = { 2, "x" }, equipped = { title = 5 } } }, 1_792_800_000) :: any
	Spec.eq(broken.pass.xp, 0)
	Spec.eq(#broken.pass.free, 1)
	Spec.eq(broken.pass.equipped.title, nil)
end)

-- the live shape: 100 tiers, the first 20 at 100 XP (unchanged from the 20-tier pass), then a ramp
local NEEDS: { number } = {}
for t = 1, 100 do
	NEEDS[t] = if t <= 20 then 100 else math.floor((100 + 1400 * ((t - 20) / 80) ^ 1.4) / 10 + 0.5) * 10
end
local CURVE: R.Opts = { perTier = 100, maxTier = 100, needs = NEEDS, tiers = {}, rewards = {} }
local V1: R.Opts = { perTier = 100, maxTier = 20, tiers = {}, rewards = {} }

Spec.test("100-tier curve: smooth, reachable, first 20 tiers unchanged", function()
	Spec.eq(R.xpAt(0, CURVE), 0)
	Spec.eq(R.xpAt(20, CURVE), 2000, "tier 20 costs what it always did")
	for t = 1, 20 do
		Spec.eq(R.xpAt(t, CURVE), R.xpAt(t, V1), `tier {t} same as the old pass`)
	end
	for t = 2, 100 do
		Spec.eq(R.need(t, CURVE) >= R.need(t - 1, CURVE), true, `tier {t} never cheaper than {t - 1}`)
		Spec.eq(R.need(t, CURVE) - R.need(t - 1, CURVE) <= 40, true, `no jump at tier {t}`)
	end
	Spec.eq(R.need(100, CURVE), 1500)
	Spec.eq(R.xpAt(100, CURVE), 57410, "season total")
	Spec.eq(R.need(101, CURVE), 0)
	Spec.eq(R.tierOf(0, CURVE), 0)
	Spec.eq(R.tierOf(1999, CURVE), 19)
	Spec.eq(R.tierOf(2000, CURVE), 20)
	Spec.eq(R.tierOf(R.xpAt(57, CURVE), CURVE), 57)
	Spec.eq(R.tierOf(R.xpAt(57, CURVE) - 1, CURVE), 56)
	Spec.eq(R.tierOf(10 ^ 9, CURVE), 100)
	local t, into, need = R.progress(R.xpAt(40, CURVE) + 7, CURVE)
	Spec.eq(t, 40)
	Spec.eq(into, 7)
	Spec.eq(need, R.need(41, CURVE))
	local mt, _, mn = R.progress(R.xpAt(100, CURVE), CURVE)
	Spec.eq(mt, 100)
	Spec.eq(mn, 0)
	local p = pass(0)
	R.addXp(p, 10 ^ 9, CURVE)
	Spec.eq(p.xp, 57410, "capped at the last tier")
end)

Spec.test("curve migration keeps every tier and claim (20 x 100 -> 100 tiers)", function()
	for _, xp in { 0, 50, 99, 100, 1234, 1999, 2000 } do
		local p = pass(xp)
		p.free = { 1, 2, 3 }
		p.premium = { 1 }
		Spec.eq(R.migrateCurve(p, 2, V1, CURVE), true)
		Spec.eq(R.tierOf(p.xp, CURVE), R.tierOf(xp, V1), `tier kept at xp {xp}`)
		Spec.eq(p.xp, xp, "first 20 tiers: xp unchanged")
		Spec.eq(p.curve, 2)
		Spec.eq(#p.free, 3, "claims untouched")
		Spec.eq(R.migrateCurve(p, 2, V1, CURVE), false, "runs once")
	end
	-- a steeper old curve: same tier + same fraction on the new one
	local OLD: R.Opts = { perTier = 1000, maxTier = 50, tiers = {}, rewards = {} }
	local x = R.remapXp(30500, OLD, CURVE)
	Spec.eq(R.tierOf(x, CURVE), 30)
	Spec.eq(x, R.xpAt(30, CURVE) + math.floor(0.5 * R.need(31, CURVE)))
	-- legacy store xp is curve-1 xp
	local lp = pass(0)
	R.mergeLegacy(lp, { xp = 1550, free = { 1, 15 } }, CURVE, V1)
	Spec.eq(lp.xp, 1550)
	Spec.eq(R.tierOf(lp.xp, CURVE), 15)
	-- reconcile keeps a valid stamp, drops junk
	local rp = R.reconcile({ season = "S1", xp = 10, curve = 2 }, "S1")
	Spec.eq(rp.curve, 2)
	local jp = R.reconcile({ season = "S1", xp = 10, curve = "x" }, "S1")
	Spec.eq(jp.curve, nil)
end)

Spec.test("curve 3 (4x harder): v2 -> v3 keeps every tier and claim", function()
	local N3: { number } = {}
	for t = 1, 100 do
		N3[t] = math.floor((150 + 5850 * ((t - 1) / 99) ^ 1.6) / 10 + 0.5) * 10
	end
	local V3: R.Opts = { perTier = 100, maxTier = 100, needs = N3, tiers = {}, rewards = {} }
	Spec.eq(R.xpAt(100, V3), 240700, "season total")
	for t = 2, 100 do
		Spec.eq(R.need(t, V3) >= R.need(t - 1, V3), true, `tier {t} never cheaper than {t - 1}`)
	end
	for _, xp in { 0, 99, 2000, 9620, 26940, 57410 } do
		local p = pass(xp)
		p.free = { 1, 2 }
		p.curve = 2
		Spec.eq(R.migrateCurve(p, 3, CURVE, V3), true)
		Spec.eq(R.tierOf(p.xp, V3), R.tierOf(xp, CURVE), `tier kept at v2 xp {xp}`)
		Spec.eq(#p.free, 2, "claims untouched")
		Spec.eq(R.migrateCurve(p, 3, CURVE, V3), false, "runs once")
	end
end)

Spec.test("palette variants", function()
	local PAL = { mint = { Name = "Mint", Color = "#6FE3B4", Trim = "#1E7A5A" } }
	local id, d = R.variant("helmet:mint:neon", PAL)
	Spec.eq(id, "helmet_mint")
	Spec.eq((d :: any).Name, "Mint Helmet")
	Spec.eq((d :: any).Neon, true)
	Spec.eq((d :: any).Trim, "#1E7A5A")
	local _, plain = R.variant("helmet:mint:plain", PAL)
	Spec.eq((plain :: any).Trim, nil)
	local hid, h = R.variant("hose:mint", PAL)
	Spec.eq(hid, "hose_mint")
	Spec.eq((h :: any).Stripe, "#1E7A5A")
	local _, tr = R.variant("truck:mint:pulse", PAL)
	Spec.eq((tr :: any).Name, "Mint Underglow")
	Spec.eq((tr :: any).Pulse, "#1E7A5A")
	local _, nz = R.variant("nozzle:mint:sparkle", PAL)
	Spec.eq((nz :: any).Sparkle, true)
	Spec.eq((R.variant("helmet:nope", PAL)), nil)
	Spec.eq((R.variant("cape:mint", PAL)), nil)
end)

Spec.test("claimable with 100 tiers stays cheap and correct", function()
	local tiers = {}
	local rewards = {}
	for t = 1, 100 do
		rewards[`f{t}`] = { Slot = "title", Name = `F{t}` }
		rewards[`p{t}`] = { Slot = "helmet", Name = `P{t}` }
		tiers[t] = { Free = `f{t}`, Premium = `p{t}` }
	end
	local o: R.Opts = { perTier = 100, maxTier = 100, needs = NEEDS, tiers = tiers, rewards = rewards }
	local p = pass(R.xpAt(60, o))
	Spec.eq(R.claimable(p, true, o), 120)
	Spec.eq(#R.claimAll(p, false, o, true), 60)
	Spec.eq(R.claimable(p, true, o), 60)
	Spec.eq(select(2, R.claim(p, 61, "free", true, o)), "locked")
end)

return Spec.finish()
