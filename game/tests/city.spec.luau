--!strict
-- City plan (pure): hub + 8 separated neighbourhoods, road graph connectivity and GPS paths, lane
-- data, incident-site placement (unique ids, mission coverage, truck spots on aprons next to a road,
-- buildings off the roads), lots inside their sub-block, the creek + bridges, signposts, determinism.
local Spec = require("./Spec")
local RoadGraph = require("../ServerScriptService/Lib/Map/City/RoadGraph") :: any
local Districts = require("../ServerScriptService/Lib/Map/City/Districts") :: any
local Catalog = require("../ReplicatedStorage/Config/MissionCatalog") :: { any }

-- mirrors ReplicatedStorage/Config/CityConfig.luau (that module needs Roblox to load)
local cfg = {
	CellSize = 900,
	DistrictHalf = 310,
	CoreHalf = 200,
	LoopOffset = 216,
	SubBlockSize = 184,
	BandLotWidth = 70,
	Bounds = { minX = -1500, maxX = 1500, minZ = -1500, maxZ = 1500 },
	HighwayWidth = 48,
	AvenueWidth = 48,
	StreetWidth = 32,
	SpurWidth = 32,
	SidewalkWidth = 6,
	ApronDepth = 36,
	RiverWidth = 24,
	RiverInset = 80,
	DamRiverZ = 168,
	StationDriveway = { x = 20, z = 175 },
	SitesPerSuburbBlock = 2,
	KindMissions = {
		house = { "house_fire" },
		shop = { "house_fire" },
		diner = { "house_fire" },
		gas = { "house_fire" },
		apartment = { "apartment_trampoline", "house_fire" },
		school = { "school_alarm" },
		storage = { "storage_fusebox" },
		zoo = { "panda_zoo" },
		dam = { "dam_finale" },
	},
	DistrictExtraMissions = { Farm = { "tornado_field" } },
}

local ON_MAIN = { Town = true, Farm = true, Forest = true, Apartment = true, School = true, Storage = true, Zoo = true, Dam = true }

local function segDist(px: number, pz: number, a: any, b: any): number
	local dx, dz = b.x - a.x, b.z - a.z
	local t = math.clamp(((px - a.x) * dx + (pz - a.z) * dz) / (dx * dx + dz * dz), 0, 1)
	return math.sqrt((px - a.x - t * dx) ^ 2 + (pz - a.z - t * dz) ^ 2)
end

-- distance to the nearest drawn road's edge (negative = on the carriageway)
local function roadGap(g: any, x: number, z: number): number
	local best = math.huge
	for _, e in g.edges do
		local a, b = g.nodes[e.a], g.nodes[e.b]
		if e.info.drawn then
			best = math.min(best, segDist(x, z, a, b) - e.info.width / 2)
		end
	end
	return best
end

local plan = Districts.planCity(cfg, ON_MAIN, Catalog, 6767)
local g = plan.graph

Spec.test("layout: ~3000 studs, hub in the middle, 9 districts clearly apart", function()
	Spec.eq(#plan.districts, 9)
	local hub
	for _, d in plan.districts do
		if d.id == "Station" then
			hub = d
		end
		Spec.truthy(math.abs(d.x) + cfg.DistrictHalf <= cfg.Bounds.maxX, `{d.id} inside bounds`)
	end
	Spec.eq(hub.x, 0)
	Spec.eq(hub.z, 0)
	for i, a in plan.districts do
		for j, b in plan.districts do
			if i < j then
				local gap = math.max(math.abs(a.x - b.x), math.abs(a.z - b.z)) - 2 * cfg.DistrictHalf
				Spec.truthy(gap >= 250, `{a.id}-{b.id} gap {gap}`)
			end
		end
	end
	Spec.eq(cfg.Bounds.maxX - cfg.Bounds.minX, 3000)
end)

Spec.test("road graph: connected, axis-aligned, every district reachable from the station", function()
	Spec.truthy(RoadGraph.connected(g), "connected")
	Spec.truthy(RoadGraph.axisAligned(g), "axis aligned")
	for _, d in plan.districts do
		local path, len = RoadGraph.shortestPath(g, "Station", d.target)
		Spec.truthy(path, `route to {d.id}`)
		if d.id ~= "Station" then
			Spec.truthy(len >= 450, `{d.id} is a real drive ({len})`)
		end
	end
end)

Spec.test("roads: highway ring, avenues, the hub radiates 4-lane avenues", function()
	local kinds = {}
	for _, e in g.edges do
		kinds[e.info.kind] = (kinds[e.info.kind] or 0) + 1
	end
	Spec.truthy((kinds.highway or 0) >= 12, "highway ring")
	Spec.truthy((kinds.avenue or 0) >= 12, "avenues")
	for _, side in { "N", "S", "W", "E" } do
		local mid = `Station_{side}`
		local found = false
		for other in g.adj[mid] do
			local info = RoadGraph.edgeInfo(g, mid, other)
			if string.sub(other, 1, 1) == "J" and info.kind == "avenue" then
				found = true
			end
		end
		Spec.truthy(found, `hub radial {side}`)
	end
	-- dirt roads at the farm and forest, asphalt downtown
	Spec.eq(RoadGraph.edgeInfo(g, "Farm_N", "Farm_NE").style, "dirt")
	Spec.eq(RoadGraph.edgeInfo(g, "Station_N", "Station_NE").style, "asphalt")
end)

Spec.test("lanes: highway/avenue 4, street 2, right-hand offsets inside the road", function()
	for _, kind in { "highway", "avenue", "street" } do
		local info = RoadGraph.roadInfo(cfg, kind)
		local lanes = RoadGraph.lanes(info)
		Spec.eq(#lanes, info.laneCount)
		for _, l in lanes do
			Spec.truthy((l.dir == 1) == (l.offset > 0), "dir 1 on the right")
			Spec.truthy(math.abs(l.offset) + l.width / 2 <= info.width / 2, "inside the road")
		end
	end
	Spec.truthy(RoadGraph.roadInfo(cfg, "highway").speedLimit > RoadGraph.roadInfo(cfg, "street").speedLimit)
	Spec.truthy(RoadGraph.roadInfo(cfg, "street").width >= 32, "side streets >= 32")
end)

Spec.test("builder districts: no cross streets inside, their roads join the loop", function()
	Spec.eq(g.nodes["Town_C"], nil, "Town core is the builder's")
	Spec.eq(g.nodes["Apartment_C"], nil, "Apartment core is the builder's")
	-- the dam chain: over its river, along the riverside road, up the ramp to the pull-out
	Spec.truthy(g.nodes["Dam_Ch3"], "dam plateau node")
	Spec.truthy(RoadGraph.shortestPath(g, "Station", "Dam_Ch3"), "route up the dam")
	local inn = g.nodes["Town_W1in"]
	Spec.truthy(inn, "Town west entry")
	Spec.eq(inn.x, -216)
	Spec.eq(inn.z, -900 + 56)
	Spec.eq(RoadGraph.edgeInfo(g, "Town_W1door", "Town_E2door").drawn, false)
	Spec.eq(g.adj["Town_W"]["Town_SW"], nil, "split loop segment")
end)

Spec.test("sites: unique ids, attributes, every mission has a site", function()
	local seen: { [string]: boolean } = {}
	local cover: { [string]: number } = {}
	for _, s in plan.sites do
		Spec.truthy(not seen[s.siteId], `duplicate {s.siteId}`)
		seen[s.siteId] = true
		Spec.truthy(#s.missionTypes > 0, `{s.siteId} MissionTypes`)
		Spec.truthy(#s.displayName > 0, `{s.siteId} name`)
		Spec.truthy(g.nodes[s.roadNode], `{s.siteId} road node`)
		Spec.truthy(RoadGraph.shortestPath(g, "Station", s.roadNode), `route to {s.siteId}`)
		for id in string.gmatch(s.missionTypes, "[^,]+") do
			cover[id] = (cover[id] or 0) + 1
		end
	end
	for _, m in Catalog do
		Spec.truthy((cover[m.id] or 0) > 0, `no site for {m.id}`)
	end
	Spec.truthy((cover.house_fire or 0) >= 10, "plenty of house fires")
	Spec.truthy(seen.Town and seen.Farm and seen.Forest and seen.Dam and seen.Zoo, "district sites")
end)

Spec.test("truck spots: on the site's apron, beside a road; buildings off the roads", function()
	for _, s in plan.sites do
		if s.lot then
			local gap = roadGap(g, s.truck.x, s.truck.z)
			Spec.truthy(gap > 2, `{s.siteId} truck on the road ({gap})`)
			Spec.truthy(gap < cfg.SidewalkWidth + cfg.ApronDepth, `{s.siteId} truck far from the road ({gap})`)
			Spec.truthy(s.lot.w >= 34, `{s.siteId} apron too narrow for the truck`)
			Spec.truthy(roadGap(g, s.x, s.z) > 20, `{s.siteId} building on a road`)
		elseif s.truck then
			local n = g.nodes[s.roadNode]
			Spec.truthy(math.abs(n.x - s.truck.x) + math.abs(n.z - s.truck.z) < 30, `{s.siteId} truck far from its road node`)
		end
	end
end)

Spec.test("lots stay inside their sub-block", function()
	local half = cfg.SubBlockSize / 2 - cfg.SidewalkWidth
	local r = Districts.rng(3)
	for _, theme in { "suburb", "downtown", "commercial", "industrial", "parking", "school", "schoolyard", "park", "farmland", "woods" } do
		for _ = 1, 5 do
			local lots = Districts.lots(theme, r, cfg, cfg.SubBlockSize)
			Spec.truthy(#lots > 0, theme)
			for _, l in lots do
				Spec.truthy(math.abs(l.x) + l.w / 2 <= half + 1e-6, `{theme} {l.kind} x`)
				Spec.truthy(math.abs(l.z) + l.d / 2 <= half + 1e-6, `{theme} {l.kind} z`)
			end
		end
	end
end)

Spec.test("band lots stay off the loop street and inside the district", function()
	for _, bl in plan.bandLots do
		local l = bl.lot
		Spec.truthy(roadGap(g, l.x, l.z) >= l.d / 2 - 1, `band lot on a road ({bl.district} {l.kind})`)
	end
end)

Spec.test("creek: carved out of the ground; every road crossing it is a bridge", function()
	Spec.truthy(#plan.river >= 2, "creek segments")
	Spec.truthy(#plan.bridges >= 5, `bridges {#plan.bridges}`)
	local ground = Districts.subtractRects({ x0 = -1500, z0 = -1500, x1 = 1500, z1 = 1500 }, plan.river)
	local area = 0
	for _, p in ground do
		area += (p.x1 - p.x0) * (p.z1 - p.z0)
		for _, rv in plan.river do
			local ox = math.min(p.x1, rv.x1) - math.max(p.x0, rv.x0)
			local oz = math.min(p.z1, rv.z1) - math.max(p.z0, rv.z0)
			Spec.truthy(not (ox > 0.01 and oz > 0.01), "ground overlaps the creek")
		end
	end
	Spec.truthy(area < 3000 * 3000 and area > 3000 * 3000 * 0.9, "most of the map is ground")
	for _, d in plan.districts do
		if d.id ~= "Dam" then
			for _, rv in plan.river do
				local ox = math.min(d.x + 310, rv.x1) - math.max(d.x - 310, rv.x0)
				local oz = math.min(d.z + 310, rv.z1) - math.max(d.z - 310, rv.z0)
				Spec.truthy(not (ox > 0 and oz > 0), `creek runs through {d.id}`)
			end
		end
	end
end)

Spec.test("signposts at the junctions between districts point at every district", function()
	Spec.truthy(#plan.signposts >= 12, `signposts {#plan.signposts}`)
	for _, sp in plan.signposts do
		local n = 0
		for _, a in sp.arms do
			n += #a.names
			Spec.truthy(math.abs(a.dx) + math.abs(a.dz) == 1, "arms are axis directions")
		end
		Spec.eq(n, #plan.districts)
	end
end)

Spec.test("no builders: procedural cores everywhere, still connected", function()
	local p2 = Districts.planCity(cfg, {}, Catalog, 1)
	Spec.truthy(RoadGraph.connected(p2.graph))
	Spec.truthy(#p2.blocks >= 6 * 4, `blocks {#p2.blocks}`)
	local seen = {}
	for _, s in p2.sites do
		seen[s.kind] = true
	end
	Spec.truthy(seen.school and seen.storage and seen.apartment and seen.zoo and seen.dam, "procedural sites")
end)

Spec.test("deterministic for a seed", function()
	local a = Districts.planCity(cfg, ON_MAIN, Catalog, 42)
	local b = Districts.planCity(cfg, ON_MAIN, Catalog, 42)
	Spec.eq(#a.sites, #b.sites)
	for i, s in a.sites do
		Spec.eq(s.siteId, b.sites[i].siteId)
		Spec.eq(s.x, b.sites[i].x)
	end
end)

Spec.test("export is JSON-ready with lane data", function()
	local ex = RoadGraph.export(g, 0.3)
	Spec.eq(ex.nodes["Station"][2], 0.3)
	Spec.eq(#ex.edges, #g.edges)
	Spec.eq(#ex.pairs, #ex.edges)
	for _, e in ex.edges do
		Spec.truthy(type(e.a) == "string" and type(e.b) == "string", "edge ends")
		Spec.truthy(e.laneCount == #e.lanes and e.speedLimit > 0 and e.length > 0, "lane data")
	end
end)

return Spec.finish()
