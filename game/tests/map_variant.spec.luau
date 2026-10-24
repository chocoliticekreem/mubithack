--!strict
-- Map variety (Lib/Map/City/MapVariant + the seeded city plan): the same seed always gives the same
-- layout and look; different seeds give different layouts (lot kinds, which lots are incident sites)
-- and looks (season / sky / weather); every seed still has a site for every mission and a route to it.
local Spec = require("./Spec")
local RoadGraph = require("../ServerScriptService/Lib/Map/City/RoadGraph") :: any
local Districts = require("../ServerScriptService/Lib/Map/City/Districts") :: any
local MapVariant = require("../ServerScriptService/Lib/Map/City/MapVariant") :: any
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
	MillPond = { x0 = 488, z0 = 110, x1 = 580, z1 = 330 },
	Tunnel = { x = -1350, z0 = -840, z1 = -570 },
	HighwaySites = {
		{ side = "S", at = -675, kind = "gas" },
		{ side = "N", at = 675, kind = "diner" },
		{ side = "E", at = 675, kind = "storage", w = 120 },
		{ side = "W", at = 675, kind = "reststop" },
	},
	StationDriveway = { x = 20, z = 175 },
	SitesPerSuburbBlock = 2,
	KindMissions = {
		house = { "house_fire", "cat_tree" },
		shop = { "house_fire" },
		diner = { "house_fire", "diner_grease" },
		gas = { "house_fire", "gas_leak" },
		apartment = { "apartment_trampoline", "house_fire" },
		school = { "school_alarm" },
		storage = { "storage_fusebox" },
		zoo = { "panda_zoo" },
		dam = { "dam_finale" },
		nightclub = { "nightclub_fire" },
		skyscraper = { "skyscraper_fire" },
		reststop = { "highway_pileup" }, -- v3: the Highway 67 rest stop (BlockFiller reststop)
	},
	DistrictExtraMissions = { Farm = { "tornado_field" } },
}

local ON_MAIN = { Town = true, Farm = true, Forest = true, Apartment = true, School = true, Storage = true, Zoo = true, Dam = true }

-- one string per layout: every lot kind (blocks, band, corridors) + which lots are incident sites
local function signature(p: any): string
	local out = {}
	for _, b in p.blocks do
		for _, l in b.lots do
			table.insert(out, `{b.id}:{l.kind}{if l.site then "*" else ""}`)
		end
	end
	for _, bl in p.bandLots do
		table.insert(out, `{math.floor(bl.lot.x)},{math.floor(bl.lot.z)}:{bl.lot.kind}{if bl.lot.site then "*" else ""}`)
	end
	for _, run in p.corridors do
		for _, l in run.lots do
			table.insert(out, `{math.floor(l.x)},{math.floor(l.z)}:{l.kind}{if l.site then "*" else ""}`)
		end
	end
	return table.concat(out, ";")
end

local function siteSet(p: any): string
	local ids = {}
	for _, s in p.sites do
		table.insert(ids, `{s.siteId}@{math.floor(s.x)},{math.floor(s.z)}`)
	end
	table.sort(ids)
	return table.concat(ids, ";")
end

local SEEDS = { 1, 7, 42, 6767, 1234, 99999, 31337, 424242, 777777, 999999 }

Spec.test("same seed: identical layout, sites and look", function()
	for _, seed in { 42, 6767, 999999 } do
		local a = Districts.planCity(cfg, ON_MAIN, Catalog, seed)
		local b = Districts.planCity(cfg, ON_MAIN, Catalog, seed)
		Spec.eq(signature(a), signature(b), `layout {seed}`)
		Spec.eq(siteSet(a), siteSet(b), `sites {seed}`)
		local va, vb = MapVariant.pick(seed), MapVariant.pick(seed)
		Spec.eq(`{va.season}/{va.sky}/{va.weather}`, `{vb.season}/{vb.sky}/{vb.weather}`, `look {seed}`)
	end
end)

Spec.test("different seeds: different layouts and incident sites", function()
	local layouts: { [string]: boolean } = {}
	local sites: { [string]: boolean } = {}
	local nl, ns = 0, 0
	for _, seed in SEEDS do
		local p = Districts.planCity(cfg, ON_MAIN, Catalog, seed)
		local sig, ss = signature(p), siteSet(p)
		if not layouts[sig] then
			layouts[sig] = true
			nl += 1
		end
		if not sites[ss] then
			sites[ss] = true
			ns += 1
		end
	end
	Spec.eq(nl, #SEEDS, "every seed its own layout")
	Spec.eq(ns, #SEEDS, "every seed its own set of incident sites")
	-- and not just one lot: two seeds differ in a good share of the lots
	local a = string.split(signature(Districts.planCity(cfg, ON_MAIN, Catalog, 1)), ";")
	local b = string.split(signature(Districts.planCity(cfg, ON_MAIN, Catalog, 2)), ";")
	Spec.eq(#a, #b, "same lot grid")
	local diff = 0
	for i = 1, #a do
		if a[i] ~= b[i] then
			diff += 1
		end
	end
	Spec.truthy(diff >= #a // 5, `only {diff} of {#a} lots differ`)
end)

Spec.test("every seed: a site for every mission, every site routable from the station", function()
	for seed = 1, 4000, 97 do
		local p = Districts.planCity(cfg, ON_MAIN, Catalog, seed)
		local cover: { [string]: number } = {}
		local seen: { [string]: boolean } = {}
		for _, s in p.sites do
			Spec.truthy(not seen[s.siteId], `duplicate {s.siteId} ({seed})`)
			seen[s.siteId] = true
			Spec.truthy(RoadGraph.shortestPath(p.graph, "Station", s.roadNode), `route to {s.siteId} ({seed})`)
			for id in string.gmatch(s.missionTypes, "[^,]+") do
				cover[id] = (cover[id] or 0) + 1
			end
		end
		for _, m in Catalog do
			Spec.truthy((cover[m.id] or 0) > 0, `no site for {m.id} ({seed})`)
		end
		Spec.truthy((cover.house_fire or 0) >= 10, `house fires ({seed})`)
	end
end)

Spec.test("look: every season, sky and weather turns up; no night fog/rain, no winter rain", function()
	local seen: { [string]: number } = {}
	for seed = 1, 600 do
		local v = MapVariant.pick(seed)
		seen[v.season] = (seen[v.season] or 0) + 1
		seen[v.sky] = (seen[v.sky] or 0) + 1
		seen[v.weather] = (seen[v.weather] or 0) + 1
		Spec.truthy(not (v.sky == "Night" and (v.weather == "Fog" or v.weather == "Rain")), `night {v.weather} ({seed})`)
		Spec.truthy(not (v.season == "Winter" and v.weather == "Rain"), `winter rain ({seed})`)
	end
	for _, list in { MapVariant.Seasons, MapVariant.Skies, MapVariant.Weathers } do
		for _, e in list do
			Spec.truthy((seen[e[1]] or 0) >= 15, `{e[1]} only {seen[e[1]] or 0} of 600`)
		end
	end
end)

Spec.test("look: overrides win, junk overrides are ignored", function()
	local v = MapVariant.pick(5, { season = "Winter", sky = "Night", weather = "Fog" })
	Spec.eq(v.season, "Winter")
	Spec.eq(v.sky, "Night")
	Spec.eq(v.weather, "Fog")
	local base = MapVariant.pick(5)
	local w = MapVariant.pick(5, { season = "Monsoon", sky = 3 })
	Spec.eq(w.season, base.season)
	Spec.eq(w.sky, base.sky)
end)

Spec.test("season roles: plants and lawns only", function()
	local G = { 0.37, 0.62, 0.24 } -- a canopy green
	Spec.eq(MapVariant.role("Canopy", "SmoothPlastic", 7, 7, 7, G[1], G[2], G[3]), "foliage")
	Spec.eq(MapVariant.role("Grass", "Grass", 2000, 10, 2000, 0.43, 0.62, 0.27), "ground")
	Spec.eq(MapVariant.role("Lawn", "Grass", 300, 0.2, 80, 0.43, 0.62, 0.27), "ground")
	Spec.eq(MapVariant.role("PineCrown", "SmoothPlastic", 6, 12, 6, 0.2, 0.4, 0.25), "evergreen")
	Spec.eq(MapVariant.role("TopiaryElephant", "Grass", 10, 10, 10, G[1], G[2], G[3]), "foliage")
	-- a sage-green wall, a green sofa, a red canopy awning: untouched
	Spec.eq(MapVariant.role("Wall", "SmoothPlastic", 8, 10, 1, 0.62, 0.7, 0.54), nil)
	Spec.eq(MapVariant.role("Sofa", "Fabric", 7, 3, 3, 0.36, 0.56, 0.49), nil)
	Spec.eq(MapVariant.role("CanopyRoof", "SmoothPlastic", 30, 1, 20, 0.78, 0.14, 0.17), nil)
end)

Spec.test("season colours: autumn warm, winter snow, summer untouched", function()
	local r, g, b = 0.37, 0.62, 0.24
	local ar, ag, _, asnow = MapVariant.recolour("Autumn", "foliage", r, g, b, 1)
	Spec.truthy(ar > ag and not asnow, "autumn leaves turn warm")
	local wr, wg, wb, snow = MapVariant.recolour("Winter", "ground", r, g, b, 1)
	Spec.truthy(snow and wr > 0.85 and wg > 0.85 and wb > 0.85, "winter lawn is snow")
	local sr, sg, sb = MapVariant.recolour("Summer", "foliage", r, g, b, 1)
	Spec.eq(sr, r)
	Spec.eq(sg, g)
	Spec.eq(sb, b)
	-- deterministic per hash, and the hash varies the palette
	local x1 = table.pack(MapVariant.recolour("Autumn", "foliage", r, g, b, 3))
	local x2 = table.pack(MapVariant.recolour("Autumn", "foliage", r, g, b, 3))
	Spec.eq(x1[1], x2[1])
	local tones: { [number]: boolean } = {}
	local n = 0
	for h = 1, 12 do
		local c = MapVariant.recolour("Autumn", "foliage", r, g, b, h)
		local k = math.floor(c * 1000)
		if not tones[k] then
			tones[k] = true
			n += 1
		end
	end
	Spec.truthy(n >= 4, "several autumn tones")
end)

return Spec.finish()
