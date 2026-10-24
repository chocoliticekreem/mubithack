--!strict
-- Gear progression (ReplicatedStorage/Lib/Items/Progression + ItemDefs gear data): level-gated unlocks,
-- the locker loadout rules, axe tier stats, kicks and the gas mask's smoke heat factor.
local Spec = require("./Spec")
local D = require("../ReplicatedStorage/Lib/Items/ItemDefs") :: any
local P = require("../ReplicatedStorage/Lib/Items/Progression") :: any
local Schema = require("../ServerScriptService/Lib/Data/ProfileSchema") :: any

local function has(list: { string }, id: string): boolean
	return table.find(list, id) ~= nil
end

Spec.test("every gear id is in GearOrder exactly once and is a real item", function()
	local seen = {}
	for _, id in D.GearOrder do
		Spec.truthy(D.Items[id], `GearOrder {id} is an item`)
		Spec.eq(seen[id], nil, `{id} listed twice`)
		seen[id] = true
	end
	for id in D.Items do
		Spec.truthy(seen[id], `{id} missing from GearOrder`)
	end
end)

Spec.test("the unlock ladder matches the design", function()
	local want = {
		Axe = 1,
		Hose = 1,
		GasMask = 2,
		Halligan = 3,
		FireAxe = 4,
		Ladder = 1,
		ThermalCam = 6,
		Sledgehammer = 8,
		GoldenAxe = 10,
		RescueSaw = 12,
	}
	for id, lvl in want do
		Spec.eq(P.unlockLevel(id), lvl, id)
	end
	Spec.eq(P.unlockLevel("Banana"), math.huge)
end)

Spec.test("level 1 has the starter kit only", function()
	local l1 = P.unlockedAt(1)
	Spec.truthy(has(l1, "Axe"))
	Spec.truthy(has(l1, "Hose"))
	Spec.truthy(has(l1, "Ladder"))
	Spec.eq(has(l1, "GasMask"), false)
	Spec.eq(has(l1, "GoldenAxe"), false)
	Spec.eq(P.isUnlocked("Halligan", 2), false)
	Spec.eq(P.isUnlocked("Halligan", 3), true)
	Spec.eq(#P.unlockedAt(99), #D.GearOrder, "everything at max level")
end)

Spec.test("level ups list exactly the new unlocks", function()
	local new = P.newUnlocks(3, 5)
	Spec.eq(#new, 1)
	Spec.truthy(has(new, "FireAxe"))
	Spec.eq(#P.newUnlocks(6, 7), 0, "nothing at 7")
	Spec.eq(#P.newUnlocks(5, 5), 0)
	local id, at = P.nextUnlock(6)
	Spec.eq(id, "Sledgehammer")
	Spec.eq(at, 8)
	Spec.eq((P.nextUnlock(12)), nil)
end)

Spec.test("loadouts: deduped, unlocked, rack-able, capped", function()
	local l = P.sanitizeLoadout({ "Axe", "Axe", "GoldenAxe", "Hose", "Banana", 7, "Crowbar", "Flashlight", "OxygenTank" }, 3)
	Spec.eq(#l, P.LoadoutSize)
	Spec.eq(l[1], "Axe")
	Spec.eq(l[2], "Crowbar", "GoldenAxe is locked at 3, Hose is tethered, junk dropped")
	Spec.eq(l[3], "Flashlight")
	Spec.eq(#P.sanitizeLoadout("nope", 5), 0)
	local d = P.defaultLoadout(1)
	Spec.truthy(#d >= 1)
	for _, id in d do
		Spec.truthy(P.isUnlocked(id, 1), id)
	end
end)

Spec.test("axe tiers get better with level", function()
	local d1, s1 = P.axeStats("Axe")
	local d2, s2 = P.axeStats("FireAxe")
	local d3, s3 = P.axeStats("GoldenAxe")
	Spec.truthy(d1 < d2 and d2 < d3, "damage climbs")
	Spec.truthy(s1 < s2 and s2 < s3, "swing speed climbs")
	Spec.eq(P.axeStats("Crowbar"), 1, "non-axes are neutral")
	Spec.eq(P.doorHits(1, "Axe", 3), 1)
	Spec.eq(P.doorHits(1, "FireAxe", 3), 2)
	Spec.eq(P.doorHits(1, "GoldenAxe", 3), 3)
	Spec.eq(P.doorHits(2, "GoldenAxe", 3), 3, "capped at a door's hits")
	Spec.truthy(P.swingCooldown(0.6, "GoldenAxe") < P.swingCooldown(0.6, "Axe"))
	for _, id in { "Axe", "FireAxe", "GoldenAxe" } do
		local tier = D.Items[id].axe
		Spec.eq(D.Items[id].tool, true, `{id} is a ToolService tool`)
		Spec.truthy(string.match(tier.head, "^#%x%x%x%x%x%x$"), `{id} head colour`)
		Spec.eq(type(tier.material), "string")
	end
end)

Spec.test("kicks: a coin flip that improves with level and retries", function()
	local c1 = P.kickChance(1, 0)
	Spec.truthy(c1 > 0.2 and c1 < 0.5)
	Spec.truthy(P.kickChance(10, 0) > c1)
	Spec.truthy(P.kickChance(1, 2) > c1)
	Spec.eq(P.kickChance(99, 9), P.Kick.Max)
end)

Spec.test("gas mask: ~40% less smoke heat, more with an O2 tank", function()
	Spec.eq(P.smokeHeatMultiplier(false, 90), 1)
	Spec.eq(P.smokeHeatMultiplier(true, nil), 0.6)
	Spec.eq(P.smokeHeatMultiplier(true, 0), 0.6, "an empty tank only gives the filter")
	Spec.truthy(P.smokeHeatMultiplier(true, 30) < 0.6)
end)

Spec.test("the mask goes on your face and stays through drops and fumbles", function()
	local ok, s, plan = D.grab({ hand = "Axe" }, "GasMask")
	Spec.eq(ok, true)
	Spec.eq(plan.slot, "face")
	Spec.eq(s.face, "GasMask")
	Spec.eq(s.hand, "Axe", "hand untouched")
	local s2, what = D.drop(s)
	Spec.eq(what, "Axe")
	Spec.eq(s2.face, "GasMask")
	local s3 = D.fumble(s)
	Spec.eq(s3.face, "GasMask")
	local _, s4, plan2 = D.grab(s, "GasMask")
	Spec.eq(s4.face, "GasMask")
	Spec.eq(plan2.dropped, "GasMask", "a second mask swaps")
end)

Spec.test("profile v3 stores gear unlocks and loadout; v2 saves migrate", function()
	local p = Schema.default(1_700_000_000)
	Spec.eq(p.version, Schema.Version) -- v3 added gear (v4: guides)
	Spec.eq(type(p.gear.unlocked), "table")
	Spec.eq(type(p.gear.loadout), "table")
	local m = Schema.migrate({ version = 2, xp = 400 }, 1_700_000_000)
	Spec.eq(m.version, Schema.Version)
	Spec.eq(#m.gear.loadout, 0)
	local junk = Schema.migrate({ version = 3, gear = { unlocked = { Axe = true, [4] = true, Halligan = "yes" }, loadout = { "Axe", 5, "Ladder" } } }, 1_700_000_000)
	Spec.eq(junk.gear.unlocked.Axe, true)
	Spec.eq(junk.gear.unlocked[4], nil)
	Spec.eq(junk.gear.unlocked.Halligan, nil)
	Spec.eq(#junk.gear.loadout, 2)
	local got = Schema.unlockGear(p, { "Axe", "Hose" })
	Spec.eq(#got, 2)
	Spec.eq(#Schema.unlockGear(p, { "Axe", "GasMask" }), 1, "only the new one")
	Spec.eq(Schema.setLoadout(p, { "Axe", "Crowbar" }), true)
	Spec.eq(p.gear.loadout[2], "Crowbar")
	Spec.eq(Schema.setLoadout(p, "nope"), false)
end)

return Spec.finish()
