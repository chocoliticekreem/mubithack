--!strict
-- DispatchLogic: the free-roam DISPATCH radio's call picking, distance text and "free" rule.
local Spec = require("./Spec")
local D = require("../ServerScriptService/Lib/Dispatch/DispatchLogic")
local MissionFlow = require("../ServerScriptService/Lib/Mission/MissionFlow")

local supports = MissionFlow.siteSupports
local function P(x: number, z: number): any
	return { X = x, Z = z }
end
local function site(id: string, types: string, x: number, z: number): any
	return { siteId = id, types = types, pos = P(x, z), address = `1 {id} St` }
end
local OPTS = { near = 250, far = 1600, exclude = { dam_finale = true }, size = 5 }
local MISSIONS = {
	{ id = "house_fire", call = "House fire", enabled = true },
	{ id = "gas_leak", call = "Gas leak", enabled = true },
	{ id = "dam_finale", call = "City-wide fire", enabled = true },
	{ id = "zoo", call = "Zoo fire", enabled = false },
}

Spec.test("meters reads like a radio call", function()
	Spec.eq(D.meters(1600, 0.28), "450 m")
	Spec.eq(D.meters(0, 0.28), "10 m")
	Spec.eq(D.meters(5000, 0.28), "1.4 km")
end)

Spec.test("pickSite prefers a site in the near..far band, else the nearest", function()
	local sites = {
		site("a", "house_fire", 50, 0), -- too close
		site("b", "house_fire", 600, 0), -- in band
		site("c", "gas_leak", 400, 0), -- wrong type
	}
	Spec.eq((D.pickSite(sites, "house_fire", P(0, 0), OPTS, supports) :: any).siteId, "b")
	local onlyClose = { site("a", "house_fire", 50, 0), site("z", "house_fire", 3000, 0) }
	Spec.eq((D.pickSite(onlyClose, "house_fire", P(0, 0), OPTS, supports) :: any).siteId, "a", "nearest when none in band")
	Spec.eq(D.pickSite(sites, "zoo", P(0, 0), OPTS, supports), nil)
end)

Spec.test("pickSite rolls among the band", function()
	local sites = { site("b", "house_fire", 600, 0), site("a", "house_fire", 0, 700) }
	local got = D.pickSite(sites, "house_fire", P(0, 0), OPTS, supports, function(n)
		return n
	end) :: any
	Spec.eq(got.siteId, "b", "sorted by id, roll picks the last")
end)

Spec.test("offer only picks callable missions that have a free site", function()
	local sites = { site("a", "gas_leak, dam_finale", 500, 0) }
	local c = D.offer(sites, MISSIONS, P(0, 0), OPTS, supports) :: any
	Spec.eq(c.missionId, "gas_leak")
	Spec.eq(c.busy, false)
	Spec.eq(c.call, "Gas leak")
	Spec.eq(math.floor(c.dist), 500)
	Spec.eq(D.offer({}, MISSIONS, P(0, 0), OPTS, supports), nil, "no free site: no call")
end)

Spec.test("list: one per callable mission, open first, busy flagged, never the same site twice", function()
	local sites = { site("a", "house_fire, gas_leak", 500, 0) }
	local l = D.list(sites, MISSIONS, P(0, 0), OPTS, supports)
	Spec.eq(#l, 2, "dam_finale excluded, zoo disabled")
	Spec.eq(l[1].busy, false)
	Spec.eq(l[2].busy, true, "the only site went to the first call")
end)

Spec.test("isFree: no mission, not queued, not in the tutorial, not downed", function()
	Spec.eq(D.isFree({ instanceId = "" }), true)
	Spec.eq(D.isFree({ instanceId = "M3" }), false)
	Spec.eq(D.isFree({ instanceId = "", queued = true }), false)
	Spec.eq(D.isFree({ instanceId = "", tutorial = true }), false)
	Spec.eq(D.isFree({ downed = true }), false)
end)

Spec.test("delay stays in its range", function()
	Spec.eq(D.delay(30, 60, 0), 30)
	Spec.eq(D.delay(30, 60, 1), 60)
	Spec.eq(D.delay(60, 30, 0.5), 45)
end)

return Spec.finish()
