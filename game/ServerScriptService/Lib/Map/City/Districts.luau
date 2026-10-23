--!strict
-- Districts [owner: CityBuilder]. PURE (no Roblox APIs): the city plan. Where every neighbourhood,
-- road, river, bridge, incident site, truck spot and signpost goes. CityBuilder turns it into parts;
-- game/tests/city.spec.luau tests it as data.
--
-- Layout (world studs, +X east, +Z SOUTH, north = -Z): a 3 x 3 grid of CellSize cells. The fire
-- station hub is the centre cell; the 8 other cells each hold one district (Layout). Road lines run
-- between the cells at -1350, -450, 450, 1350: the outer square is Highway 67 (4 lanes), the inner
-- lines are 4-lane avenues (the ring road round the hub). Every district is a DistrictHalf square:
--   core   (CoreHalf = 200, the 400 x 400 footprint of a v1 location builder): the builder's own
--          location, or a procedural core (4 sub-blocks with a cross of streets, a zoo, a dam, the station)
--   loop   a 2-lane street round the core (centreline LoopOffset = 216 from the centre)
--   band   lots facing the loop (out to DistrictHalf): the neighbourhood (suburb houses, downtown
--          towers, farmland, woods, industrial yards, park) with a few incident sites of its own
--   gates  a connector street from each loop side out to the road line between cells (~230 studs of
--          driving, through a welcome arch), so neighbourhoods are clearly apart.
-- Mill Creek leaves the dam (north-east), runs along the east greenbelt to the south edge; every road
-- crossing it is a bridge.
--
--   Districts.Layout / Districts.Spurs / Districts.StreetNames
--   Districts.rng(seed): Rng                            -- deterministic LCG (Random is not pure)
--   Districts.lots(theme, rng, cfg, size?): { Lot }     -- lots of one square sub-block (local, +-size/2)
--   Districts.bandLots(theme, rng, cfg, d, gateWidth?): { Lot } -- lots round one district's loop (world)
--   Districts.subtractRects(rect, holes): { Rect }      -- ground minus the river
--   Districts.planCity(cfg, available, catalog, seed): CityPlan
--     available = { [builderId]: true } location builders that exist; catalog = MissionCatalog list
-- Lots: { kind, x, z, w, d, face, site }: face "N" = the front looks north (-Z), "S", "E" (+X), "W".
local RoadGraph = if (script :: any) ~= nil
	then require((script :: any).Parent:WaitForChild("RoadGraph"))
	else require("./RoadGraph")

export type Lot = { kind: string, x: number, z: number, w: number, d: number, face: string, site: boolean }
export type Rect = { x0: number, z0: number, x1: number, z1: number }
export type Site = {
	siteId: string,
	kind: string, -- procedural kind, or "district" for a reused location builder
	missionTypes: string,
	district: string,
	locationId: string?,
	x: number,
	z: number,
	face: string,
	truck: { x: number, z: number, yaw: number }?, -- nil: the builder places its own TruckSpot
	roadNode: string,
	displayName: string,
	lot: Lot?,
	world: boolean?, -- lot coordinates are world (band lots) rather than sub-block local
	block: any?,
}
export type Block = { id: string, x: number, z: number, size: number, theme: string, district: string, lots: { Lot } }
export type DistrictInfo = {
	id: string,
	cell: { number },
	builder: string?,
	useBuilder: boolean,
	x: number,
	z: number,
	sign: string,
	band: string,
	road: string,
	street: string,
	core: any,
	landmark: string,
	entries: { string },
	gates: { { side: string, node: string, x: number, z: number } },
	target: string, -- road node GPS/signposts aim for
}
export type Signpost = { node: string, x: number, z: number, arms: { { dx: number, dz: number, names: { string } } } }
export type CityPlan = {
	districts: { DistrictInfo },
	blocks: { Block },
	bandLots: { { district: string, lot: Lot } },
	sites: { Site },
	graph: RoadGraph.Graph,
	river: { Rect },
	lake: Rect?, -- Mill Pond (part of river), nil when cfg.MillPond is unset
	bridges: { { x0: number, z0: number, x1: number, z1: number, alongX: boolean } },
	signposts: { Signpost },
	bounds: { minX: number, maxX: number, minZ: number, maxZ: number },
	lines: { number },
}

local Districts = {}

-- cell = { column 0..2 (west..east), row 0..2 (north..south) }. core: a list of 4 sub-block themes
-- (NW, NE, SW, SE) used when the builder is missing, or "station" | "zoo" | "dam".
Districts.Layout = {
	{ id = "Farm", cell = { 0, 0 }, builder = "Farm", sign = "SUNNY ACRES FARM", band = "farmland", road = "dirt", street = "Hayfield Rd", core = { "farmland", "farmland", "farmland", "park" }, landmark = "silo" },
	{ id = "Town", cell = { 1, 0 }, builder = "Town", sign = "WELCOME TO MAPLE STREET", band = "suburb", road = "asphalt", street = "Maple Loop", core = { "suburb", "suburb", "suburb", "suburb" }, landmark = "watertower" },
	{ id = "Dam", cell = { 2, 0 }, builder = "Dam", sign = "MILL CREEK DAM", band = "woods", road = "concrete", street = "Creek Rd", core = "dam", landmark = "dam" },
	{ id = "Storage", cell = { 0, 1 }, builder = "Storage", sign = "RUST BELT INDUSTRIAL", band = "industrial", road = "concrete", street = "Rust St", core = { "industrial", "parking", "industrial", "industrial" }, landmark = "smokestacks" },
	{ id = "Station", cell = { 1, 1 }, builder = nil, sign = "FIRE STATION 67  ·  DOWNTOWN", band = "downtown", road = "asphalt", street = "Main St", core = "station", landmark = "hosetower" },
	{ id = "Forest", cell = { 2, 1 }, builder = "Forest", sign = "PINE RIDGE FOREST", band = "woods", road = "dirt", street = "Pine Trail", core = { "woods", "woods", "woods", "woods" }, landmark = "lookout" },
	{ id = "School", cell = { 0, 2 }, builder = "School", sign = "MAPLEWOOD SCHOOL CAMPUS", band = "suburb", road = "asphalt", street = "Campus Dr", core = { "school", "schoolyard", "suburb", "park" }, landmark = "belltower" },
	{ id = "Apartment", cell = { 1, 2 }, builder = "Apartment", sign = "DOWNTOWN HEIGHTS", band = "downtown", road = "asphalt", street = "Tower Ave", core = { "downtown", "downtown", "commercial", "downtown" }, landmark = "skyscraper" },
	{ id = "Zoo", cell = { 2, 2 }, builder = "Zoo", sign = "CITY ZOO", band = "park", road = "cobble", street = "Safari Way", core = "zoo", landmark = "ferriswheel" },
}

-- How a reused builder's own roads meet the loop. Offsets from the district centre (builder frame =
-- world axes). entries: { side, offset } on the loop (W/E: offset along z, N/S: offset along x); each
-- gets a "door" node at the core edge. through: link the first two doors. inner: an extra node off
-- door 1. chain: nodes after door 1 ({ x, z, drawn? }; drawn = CityBuilder paves it). truck: TruckSpot
-- to add when the builder has none ({ x, z, yawDeg }).
Districts.Spurs = {
	Town = { entries = { { "W", 56 }, { "E", 56 } }, through = true, inner = { 0, 56 }, truck = { 0, 60, 90 } },
	Apartment = { entries = { { "W", 56 }, { "E", 56 } }, through = true, inner = { 0, 56 } },
	School = { entries = { { "W", 56 }, { "E", 56 } }, through = true, inner = { 0, 56 } },
	Storage = { entries = { { "W", 118 }, { "E", 118 } }, through = true, inner = { 0, 118 } },
	Zoo = { entries = { { "W", 180 }, { "E", 180 } }, through = true, inner = { 0, 180 } },
	Farm = { entries = { { "W", 70 }, { "E", 70 } }, through = true, inner = { 15, 70 } },
	Forest = { entries = { { "W", 66 } }, inner = { 14, 42 } },
	-- dam: over the river to the riverside road, east to the foot of the ramp, up to the plateau pull-out
	Dam = { entries = { { "S", 0 } }, chain = { { 0, 152, true }, { 144, 152 }, { 170, -20 } } },
}

Districts.StreetNames = {
	lineX = { "Highway 67", "Cedar Ave", "Elm Ave", "Highway 67" }, -- x-lines (run north-south)
	lineZ = { "Highway 67", "Oak Blvd", "Ash Blvd", "Highway 67" }, -- z-lines (run east-west)
}

---------------------------------------------------------------------------------------------------
-- deterministic RNG
---------------------------------------------------------------------------------------------------
export type Rng = {
	int: (a: number, b: number) -> number,
	num: (a: number, b: number) -> number,
	pick: <T>(list: { T }) -> T,
}

function Districts.rng(seed: number): Rng
	local state = math.floor(math.abs(seed)) % 2147483647
	if state == 0 then
		state = 1
	end
	local function nextFloat(): number
		state = (state * 48271) % 2147483647
		return state / 2147483647
	end
	local r = {}
	function r.int(a: number, b: number): number
		return a + math.floor(nextFloat() * (b - a + 1))
	end
	function r.num(a: number, b: number): number
		return a + nextFloat() * (b - a)
	end
	function r.pick<T>(list: { T }): T
		return list[r.int(1, #list)]
	end
	return r :: any
end

---------------------------------------------------------------------------------------------------
-- lots
---------------------------------------------------------------------------------------------------
local SITE_KINDS = {
	house = true,
	shop = true,
	diner = true,
	gas = true,
	apartment = true,
	school = true,
	storage = true,
	zoo = true,
}
Districts.SiteKinds = SITE_KINDS

local function lot(kind: string, x: number, z: number, w: number, d: number, face: string): Lot
	return { kind = kind, x = x, z = z, w = w, d = d, face = face, site = SITE_KINDS[kind] == true }
end

local function row(out: { Lot }, kinds: { string }, half: number, north: boolean)
	local n = #kinds
	local w = 2 * half / n
	local z = if north then -half / 2 else half / 2
	for k, kind in kinds do
		table.insert(out, lot(kind, -half + (k - 0.5) * w, z, w, half, if north then "N" else "S"))
	end
end

local function limitSites(out: { Lot }, r: Rng, want: number)
	local idx = {}
	for i, l in out do
		if l.site then
			table.insert(idx, i)
		end
	end
	for i = #idx, 2, -1 do
		local j = r.int(1, i)
		idx[i], idx[j] = idx[j], idx[i]
	end
	for k, i in idx do
		if k > want then
			out[i].site = false
		end
	end
end

-- Lots of one square sub-block of side `size` (block-local coords, inner area +-(size/2 - sidewalk)).
function Districts.lots(theme: string, r: Rng, cfg: any, size: number?): { Lot }
	local half = (size or cfg.SubBlockSize or 184) / 2 - cfg.SidewalkWidth
	local out: { Lot } = {}
	if theme == "suburb" then
		row(out, { "house", "house" }, half, true)
		row(out, { "house", "house" }, half, false)
		limitSites(out, r, cfg.SitesPerSuburbBlock or 2)
	elseif theme == "downtown" then
		local north = { r.pick({ "apartment", "tower", "shops" }), r.pick({ "tower", "apartment", "plaza" }) }
		if north[1] ~= "apartment" and north[2] ~= "apartment" then
			north[1] = "apartment"
		end
		for k, p in north do
			local x = if k == 1 then -half / 2 else half / 2
			if p == "shops" then
				table.insert(out, lot("shop", x - half / 4, -half / 2, half / 2, half, "N"))
				table.insert(out, lot("shop", x + half / 4, -half / 2, half / 2, half, "N"))
			else
				table.insert(out, lot(p, x, -half / 2, half, half, "N"))
			end
		end
		row(out, { r.pick({ "tower", "plaza", "tower" }), "shop" }, half, false)
	elseif theme == "commercial" then
		local flip = r.int(0, 1) == 1
		row(out, { "diner", "shop" }, half, not flip)
		row(out, { "gas", "parking" }, half, flip)
	elseif theme == "industrial" then
		local flip = r.int(0, 1) == 1
		row(out, { "storage" }, half, not flip)
		row(out, { "warehouse", r.pick({ "tanks", "parking", "warehouse" }) }, half, flip)
	elseif theme == "parking" then
		row(out, { "parking", "warehouse" }, half, true)
		row(out, { "parking" }, half, false)
	elseif theme == "farmland" or theme == "woods" then
		row(out, { theme }, half, true)
		row(out, { theme }, half, false)
	elseif theme == "school" or theme == "schoolyard" or theme == "park" or theme == "zoo" then
		local kind = if theme == "schoolyard" then "field" else theme
		table.insert(out, lot(kind, 0, 0, 2 * half, 2 * half, if theme == "school" then "S" else "N"))
	end
	return out
end

local BAND_KINDS = {
	suburb = { "house" },
	downtown = { "shop", "tower", "apartment", "shop", "tower", "plaza", "diner" },
	industrial = { "warehouse", "tanks", "storage", "parking", "warehouse" },
	farmland = { "farmland", "farmland", "barn", "farmland" },
	woods = { "woods" },
	park = { "grove", "woods", "grove" },
}
local BAND_SITES = { suburb = 4, downtown = 3, industrial = 2 }

-- Lots round a district's loop (world coords). Each side has two runs either side of the gate.
function Districts.bandLots(theme: string, r: Rng, cfg: any, d: any, gateWidth: number?): { Lot }
	local out: { Lot } = {}
	local kinds = BAND_KINDS[theme] or { "woods" }
	local outer = cfg.LoopOffset + cfg.StreetWidth / 2 + cfg.SidewalkWidth -- band starts here
	local depth = cfg.DistrictHalf - outer
	local gate = (gateWidth or cfg.StreetWidth) / 2 + 6
	local runLen = cfg.LoopOffset + cfg.StreetWidth / 2 - gate
	local per = math.max(1, math.floor(runLen / (cfg.BandLotWidth or 70)))
	local w = runLen / per
	for _, side in { "N", "S", "W", "E" } do
		for _, sgn in { -1, 1 } do
			for k = 1, per do
				local along = sgn * (gate + (k - 0.5) * w)
				local across = outer + depth / 2
				local x, z, face
				if side == "N" then
					x, z, face = d.x + along, d.z - across, "S"
				elseif side == "S" then
					x, z, face = d.x + along, d.z + across, "N"
				elseif side == "W" then
					x, z, face = d.x - across, d.z + along, "E"
				else
					x, z, face = d.x + across, d.z + along, "W"
				end
				table.insert(out, lot(r.pick(kinds), x, z, w, depth, face))
			end
		end
	end
	limitSites(out, r, BAND_SITES[theme] or 0)
	return out
end

---------------------------------------------------------------------------------------------------
-- geometry helpers
---------------------------------------------------------------------------------------------------
function Districts.subtractRects(rect: Rect, holes: { Rect }): { Rect }
	local pieces = { rect }
	for _, h in holes do
		local nextPieces = {}
		for _, p in pieces do
			local ix0, iz0 = math.max(p.x0, h.x0), math.max(p.z0, h.z0)
			local ix1, iz1 = math.min(p.x1, h.x1), math.min(p.z1, h.z1)
			if ix0 >= ix1 or iz0 >= iz1 then
				table.insert(nextPieces, p)
			else
				if p.z0 < iz0 then
					table.insert(nextPieces, { x0 = p.x0, z0 = p.z0, x1 = p.x1, z1 = iz0 })
				end
				if iz1 < p.z1 then
					table.insert(nextPieces, { x0 = p.x0, z0 = iz1, x1 = p.x1, z1 = p.z1 })
				end
				if p.x0 < ix0 then
					table.insert(nextPieces, { x0 = p.x0, z0 = iz0, x1 = ix0, z1 = iz1 })
				end
				if ix1 < p.x1 then
					table.insert(nextPieces, { x0 = ix1, z0 = iz0, x1 = p.x1, z1 = iz1 })
				end
			end
		end
		pieces = nextPieces
	end
	return pieces
end

local function join(list: { string }): string
	return table.concat(list, ",")
end

function Districts.missionTypesForDistrict(locationId: string, catalog: { any }, cfg: any): string
	local ids: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, m in catalog do
		if m.locationId == locationId and not seen[m.id] then
			seen[m.id] = true
			table.insert(ids, m.id)
		end
	end
	for _, id in (cfg.DistrictExtraMissions or {})[locationId] or {} do
		if not seen[id] then
			seen[id] = true
			table.insert(ids, id)
		end
	end
	return join(ids)
end

function Districts.missionTypesForKind(kind: string, cfg: any): string
	return join((cfg.KindMissions or {})[kind] or {})
end

local FACE_DIR = { N = { 0, -1 }, S = { 0, 1 }, E = { 1, 0 }, W = { -1, 0 } }
Districts.FaceDir = FACE_DIR

---------------------------------------------------------------------------------------------------
-- avenue corridors
---------------------------------------------------------------------------------------------------
-- The greenbelt strip between an avenue and the neighbourhood next to it gets a row of frontage
-- lots facing the avenue, themed by that neighbourhood. Filler lots are cheap low-detail facades
-- (BlockFiller "facade", "duplex", "shed", "cropfield", "copse", "grove"); a few are incident sites.
-- Lots run from the district's gate street out to its edge (|along| <= DistrictHalf), so the corners
-- where two strips meet stay open. The creek side of the east avenue stays a greenbelt.
Districts.CorridorStyle = {
	downtown = { lotW = 68, kinds = { "facade", "facade", "midrise", "facade", "plaza", "carpark" }, sites = { "apartment", "shop", "apartment", "diner", "gas" } },
	suburb = { lotW = 54, kinds = { "duplex", "duplex", "duplex", "grove" }, sites = { "house" } },
	industrial = { lotW = 92, kinds = { "warehouse", "shed", "tanks", "warehouse", "carpark" }, sites = { "storage" } },
	farmland = { lotW = 130, kinds = { "cropfield", "cropfield", "barn" }, sites = { "house" } },
	woods = { lotW = 130, kinds = { "copse" }, sites = {} },
	park = { lotW = 130, kinds = { "grove", "copse" }, sites = {} },
}
-- incident sites per corridor run side (a district's frontage on one avenue); the hub's own frontage
-- has none (dispatch wants a real drive from the station)
Districts.CorridorSites = { Station = 0, Farm = 1, Town = 1, Storage = 1, School = 1, Apartment = 1 }
-- a whole corridor run becomes one big site (a second school campus etc.), far from the station
Districts.CorridorBigSites = { Town = "school", School = "school", Storage = "apartment" }

export type Corridor = {
	district: string,
	theme: string,
	axis: string, -- "x": the avenue is an x-line (runs north-south); "z": a z-line (runs east-west)
	line: number, -- the avenue centreline coordinate
	side: number, -- -1 / 1: which side of the line the lots are on
	street: string,
	a0: number, -- along range (world)
	a1: number,
	near: number, -- across: the avenue kerb (road edge)
	far: number, -- across: the back of the lots
	lots: { Lot },
}

function Districts.corridors(cfg: any, r: Rng, districts: { DistrictInfo }, lines: { number }, river: { Rect }): { Corridor }
	local out: { Corridor } = {}
	local cell = cfg.CellSize
	local H = cfg.DistrictHalf
	local roadHalf = (cfg.AvenueWidth or 48) / 2
	local sw = cfg.SidewalkWidth
	local depth = cell / 2 - roadHalf - sw - H - 6
	if depth < 40 then
		return out
	end
	local function wet(x0: number, z0: number, x1: number, z1: number): boolean
		for _, rv in river do
			if x1 > rv.x0 - 6 and x0 < rv.x1 + 6 and z1 > rv.z0 - 6 and z0 < rv.z1 + 6 then
				return true
			end
		end
		return false
	end
	for _, d in districts do
		local style = Districts.CorridorStyle[d.band]
		if style then
			local gateHalf = (if d.id == "Station" then cfg.AvenueWidth else cfg.StreetWidth) / 2
			local sides: { Corridor } = {}
			for _, side in { "W", "E", "N", "S" } do
				local dir = FACE_DIR[side]
				local axis = if side == "W" or side == "E" then "x" else "z"
				local centre = if axis == "x" then d.x else d.z
				local along = if axis == "x" then d.z else d.x
				local line = centre + (dir[1] + dir[2]) * cell / 2
				-- only the inner avenues (not Highway 67)
				local idx = table.find(lines, line)
				if idx and idx ~= 1 and idx ~= #lines then
					local s = -(dir[1] + dir[2]) -- lots sit on the district's side of the line
					local near = line + s * (roadHalf)
					local front = near + s * sw
					local back = front + s * depth
					local names = if axis == "x" then Districts.StreetNames.lineX else Districts.StreetNames.lineZ
					for _, sgn in { -1, 1 } do
						local a0 = along + sgn * (gateHalf + 20)
						local a1 = along + sgn * (H - 4)
						if a0 > a1 then
							a0, a1 = a1, a0
						end
						local x0, x1, z0, z1
						if axis == "x" then
							x0, x1, z0, z1 = math.min(near, back), math.max(near, back), a0, a1
						else
							x0, x1, z0, z1 = a0, a1, math.min(near, back), math.max(near, back)
						end
						if not wet(x0, z0, x1, z1) then
							local run: Corridor = {
								district = d.id,
								theme = d.band,
								axis = axis,
								line = line,
								side = s,
								street = names[idx],
								a0 = a0,
								a1 = a1,
								near = near,
								far = back,
								lots = {},
							}
							local len = a1 - a0
							local per = math.max(1, math.floor(len / style.lotW))
							local w = len / per
							local face = if axis == "x" then (if s < 0 then "E" else "W") else (if s < 0 then "S" else "N")
							local ac = front + s * depth / 2
							for k = 1, per do
								local t = a0 + (k - 0.5) * w
								local kind = r.pick(style.kinds)
								local lx, lz = if axis == "x" then ac else t, if axis == "x" then t else ac
								table.insert(run.lots, { kind = kind, x = lx, z = lz, w = w, d = depth, face = face, site = false })
							end
							table.insert(sides, run)
							table.insert(out, run)
						end
					end
				end
			end
			-- one run becomes a single big site: the longest run furthest from the hub
			local big = Districts.CorridorBigSites[d.id]
			local bigRun: Corridor? = nil
			if big then
				local best = -math.huge
				for _, run in sides do
					local mid = (run.a0 + run.a1) / 2
					local cx = if run.axis == "x" then (run.near + run.far) / 2 else mid
					local cz = if run.axis == "x" then mid else (run.near + run.far) / 2
					local score = (run.a1 - run.a0) * 4 + math.abs(cx) + math.abs(cz)
					if run.a1 - run.a0 >= 200 and score > best then
						best, bigRun = score, run
					end
				end
				if bigRun then
					local l = bigRun.lots[1]
					local len = bigRun.a1 - bigRun.a0
					local t = (bigRun.a0 + bigRun.a1) / 2
					local ac = if bigRun.axis == "x" then l.x else l.z
					bigRun.lots = {
						{
							kind = big,
							x = if bigRun.axis == "x" then ac else t,
							z = if bigRun.axis == "x" then t else ac,
							w = len,
							d = l.d,
							face = l.face,
							site = true,
						},
					}
				end
			end
			-- incident sites: pick lots across this district's runs
			local want = Districts.CorridorSites[d.id] or 0
			if want > 0 and #style.sites > 0 then
				local pool = {}
				for _, run in sides do
					for _, l in (if run == bigRun then {} else run.lots) do
						if l.w >= 40 then
							table.insert(pool, l)
						end
					end
				end
				-- `want` per avenue the district fronts, never more than half its lots
				local nSides = 0
				local seenLine: { [string]: boolean } = {}
				for _, run in sides do
					local key = `{run.axis}{run.line}`
					if not seenLine[key] then
						seenLine[key] = true
						nSides += 1
					end
				end
				local n = math.min(want * nSides, #pool // 2)
				for i = #pool, 2, -1 do
					local j = r.int(1, i)
					pool[i], pool[j] = pool[j], pool[i]
				end
				-- one site per run at most
				local used: { [any]: boolean } = {}
				local placed = 0
				for _, l in pool do
					if placed >= n then
						break
					end
					local owner
					for _, run in sides do
						if table.find(run.lots, l) then
							owner = run
						end
					end
					if owner and not used[owner] then
						used[owner] = true
						l.kind = style.sites[(placed % #style.sites) + 1]
						l.site = true
						placed += 1
					end
				end
			end
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------
-- city plan
---------------------------------------------------------------------------------------------------
function Districts.planCity(cfg: any, available: { [string]: boolean }, catalog: { any }, seed: number): CityPlan
	local r = Districts.rng(seed)
	local cell = cfg.CellSize
	local L = cfg.LoopOffset
	local lines = { -1.5 * cell, -cell / 2, cell / 2, 1.5 * cell } -- -1350 -450 450 1350
	local centres = { -cell, 0, cell }
	local g = RoadGraph.new()

	-- 1. road lines between the cells: highway outside, avenues inside
	local function gid(i: number, j: number): string
		return `G{i}_{j}`
	end
	for i = 1, 4 do
		for j = 1, 4 do
			RoadGraph.addNode(g, gid(i, j), lines[i], lines[j])
		end
	end
	for i = 1, 4 do
		local outer = i == 1 or i == 4
		for j = 1, 3 do
			RoadGraph.addEdge(g, gid(i, j), gid(i, j + 1), RoadGraph.roadInfo(cfg, if outer then "highway" else "avenue"))
			RoadGraph.addEdge(g, gid(j, i), gid(j + 1, i), RoadGraph.roadInfo(cfg, if outer then "highway" else "avenue"))
		end
	end

	-- 2. districts: loop, core streets, gates
	local districts: { DistrictInfo } = {}
	local blocks: { Block } = {}
	local sites: { Site } = {}
	local bandLots: { { district: string, lot: Lot } } = {}
	for _, p in Districts.Layout do
		local cx, cz = centres[p.cell[1] + 1], centres[p.cell[2] + 1]
		local d: DistrictInfo = {
			id = p.id,
			cell = p.cell,
			builder = p.builder,
			useBuilder = p.builder ~= nil and available[p.builder] == true,
			x = cx,
			z = cz,
			sign = p.sign,
			band = p.band,
			road = p.road,
			street = p.street,
			core = p.core,
			landmark = p.landmark,
			entries = {},
			gates = {},
			target = "",
		}
		table.insert(districts, d)
		local street = RoadGraph.roadInfo(cfg, "street", p.road)
		local function nid(s: string): string
			return `{p.id}_{s}`
		end
		local pts = {
			NW = { -L, -L },
			N = { 0, -L },
			NE = { L, -L },
			E = { L, 0 },
			SE = { L, L },
			S = { 0, L },
			SW = { -L, L },
			W = { -L, 0 },
		}
		for name, o in pts do
			RoadGraph.addNode(g, nid(name), cx + o[1], cz + o[2])
		end
		local ring = { "NW", "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
		for k = 1, 8 do
			RoadGraph.addEdge(g, nid(ring[k]), nid(ring[k + 1]), street)
		end
		-- gates: loop mid-side -> the road line between cells
		local isHub = p.id == "Station"
		local gateInfo = if isHub then RoadGraph.roadInfo(cfg, "avenue", p.road) else RoadGraph.roadInfo(cfg, "street", p.road)
		for _, side in { "N", "S", "W", "E" } do
			local dir = FACE_DIR[side]
			local gx, gz = cx + dir[1] * cell / 2, cz + dir[2] * cell / 2
			local node = RoadGraph.splitAtPoint(g, gx, gz, `J{math.floor(gx)}_{math.floor(gz)}`)
			if node then
				RoadGraph.addEdge(g, nid(side), node, gateInfo)
				table.insert(d.gates, { side = side, node = node, x = gx, z = gz })
			end
		end
		-- what GPS aims for: the loop side facing the hub (the hub: its station driveway)
		if isHub then
			d.target = "Station"
		else
			local best, bd = "S", math.huge
			for _, side in { "N", "S", "W", "E" } do
				local o = pts[side]
				local dd = (cx + o[1]) ^ 2 + (cz + o[2]) ^ 2
				if dd < bd then
					best, bd = side, dd
				end
			end
			d.target = nid(best)
		end
		-- core
		if d.useBuilder then
			local spur = Districts.Spurs[p.builder :: string] or { entries = { { "S", 0 } } }
			local doors: { string } = {}
			for k, e in spur.entries do
				local side, off = e[1], e[2]
				local dir = FACE_DIR[side]
				local lx, lz, dx, dz
				if side == "W" or side == "E" then
					lx, lz = cx + dir[1] * L, cz + off
					dx, dz = cx + dir[1] * cfg.CoreHalf, cz + off
				else
					lx, lz = cx + off, cz + dir[2] * L
					dx, dz = cx + off, cz + dir[2] * cfg.CoreHalf
				end
				local entry = RoadGraph.splitAtPoint(g, lx, lz, nid(`{side}{k}in`)) :: string
				local door = nid(`{side}{k}door`)
				RoadGraph.addNode(g, door, dx, dz)
				RoadGraph.addEdge(g, entry, door, street)
				table.insert(d.entries, entry)
				table.insert(doors, door)
			end
			local own = RoadGraph.roadInfo(cfg, "builder", p.road)
			if spur.through and #doors >= 2 then
				RoadGraph.addEdge(g, doors[1], doors[2], own)
			end
			local candidates = table.clone(doors)
			if spur.inner then
				local id = nid("In")
				RoadGraph.addNode(g, id, cx + spur.inner[1], cz + spur.inner[2])
				RoadGraph.addEdge(g, id, doors[1], own)
				table.insert(candidates, id)
			end
			local chainEnd: string? = nil
			if spur.chain then
				local prev = doors[1]
				for k, c in spur.chain do
					local id = nid(`Ch{k}`)
					RoadGraph.addNode(g, id, cx + c[1], cz + c[2])
					RoadGraph.addEdge(g, prev, id, if c[3] then street else own)
					prev = id
				end
				chainEnd = prev
			end
			local truck = nil
			if spur.truck then
				truck = { x = cx + spur.truck[1], z = cz + spur.truck[2], yaw = spur.truck[3] }
			end
			local tx, tz = if truck then truck.x else cx, if truck then truck.z else cz
			local node, best = candidates[1], math.huge
			for _, id in candidates do
				local q = g.nodes[id]
				local dd = (q.x - tx) ^ 2 + (q.z - tz) ^ 2
				if dd < best then
					node, best = id, dd
				end
			end
			node = chainEnd or node
			table.insert(sites, {
				siteId = p.builder :: string,
				kind = "district",
				missionTypes = Districts.missionTypesForDistrict(p.builder :: string, catalog, cfg),
				district = p.id,
				locationId = p.builder,
				x = cx,
				z = cz,
				face = "S",
				truck = truck,
				roadNode = node,
				displayName = p.sign,
			})
		elseif type(p.core) == "table" then
			-- 4 sub-blocks with a cross of streets
			RoadGraph.addNode(g, nid("C"), cx, cz)
			for _, side in { "N", "S", "W", "E" } do
				RoadGraph.addEdge(g, nid("C"), nid(side), street)
			end
			local sb = cfg.SubBlockSize
			local off = (sb + cfg.StreetWidth) / 2
			for k = 1, 4 do
				local bxs = if k % 2 == 1 then -1 else 1
				local bzs = if k <= 2 then -1 else 1
				table.insert(blocks, {
					id = `{p.id}{k}`,
					x = cx + bxs * off,
					z = cz + bzs * off,
					size = sb,
					theme = p.core[k],
					district = p.id,
					lots = Districts.lots(p.core[k], r, cfg, sb),
				})
			end
		elseif p.core == "zoo" then
			local half = cfg.CoreHalf
			local zlot = lot("zoo", 0, 0, 2 * half - 2 * cfg.SidewalkWidth, 2 * half - 2 * cfg.SidewalkWidth, "N")
			table.insert(blocks, { id = `{p.id}1`, x = cx, z = cz, size = 2 * half, theme = "zoo", district = p.id, lots = { zlot } })
		elseif p.core == "dam" then
			table.insert(sites, {
				siteId = "dam",
				kind = "dam",
				missionTypes = Districts.missionTypesForKind("dam", cfg),
				district = p.id,
				x = cx,
				z = cz,
				face = "S",
				truck = { x = cx + 7, z = cz + 60, yaw = 0 },
				roadNode = nid("Spill"),
				displayName = p.sign,
			})
			-- the dam road runs from the loop's south side up to the hamlet under the spillway
			RoadGraph.addNode(g, nid("Spill"), cx, cz + 40)
			RoadGraph.addEdge(g, nid("S"), nid("Spill"), RoadGraph.roadInfo(cfg, "spur", p.road))
		elseif p.core == "station" then
			-- StationBuilder paves its own apron from the bays down to the loop's south side
			local sd = cfg.StationDriveway
			local kerb = RoadGraph.splitAtPoint(g, sd.x, cz + L, nid("Bays")) :: string
			RoadGraph.addNode(g, "Station", sd.x, sd.z)
			RoadGraph.addEdge(g, "Station", kerb, RoadGraph.roadInfo(cfg, "builder", p.road))
		end
		-- the neighbourhood round the loop
		for _, l in Districts.bandLots(p.band, r, cfg, d, gateInfo.width) do
			table.insert(bandLots, { district = p.id, lot = l })
		end
	end

	-- 3. sites on lots (procedural cores + bands)
	local counter: { [string]: number } = {}
	local byId: { [string]: DistrictInfo } = {}
	for _, d in districts do
		byId[d.id] = d
	end
	local function addLotSite(dist: DistrictInfo, l: Lot, wx: number, wz: number, world: boolean, block: any?, streetName: string?, node: string?)
		local dir = FACE_DIR[l.face]
		-- the apron sits at the lot front (toward its street)
		local frontX, frontZ = wx + dir[1] * l.d / 2, wz + dir[2] * l.d / 2
		local tx, tz = frontX - dir[1] * cfg.ApronDepth / 2, frontZ - dir[2] * cfg.ApronDepth / 2
		counter[dist.id] = (counter[dist.id] or 0) + 1
		local n = counter[dist.id]
		node = node or RoadGraph.nearest(g, frontX + dir[1] * 22, frontZ + dir[2] * 22)
		local num = 2 * (10 + n * 7) + (if l.face == "N" or l.face == "E" then 1 else 0)
		table.insert(sites, {
			siteId = `{l.kind}-{dist.id}-{n}`,
			kind = l.kind,
			missionTypes = Districts.missionTypesForKind(l.kind, cfg),
			district = dist.id,
			x = wx,
			z = wz,
			face = l.face,
			truck = { x = tx, z = tz, yaw = if l.face == "N" or l.face == "S" then 90 else 0 },
			roadNode = node :: string,
			displayName = `{num} {streetName or dist.street}`,
			lot = l,
			world = world,
			block = block,
		})
	end
	for _, b in blocks do
		for _, l in b.lots do
			if l.site then
				addLotSite(byId[b.district], l, b.x + l.x, b.z + l.z, false, b)
			end
		end
	end
	for _, bl in bandLots do
		if bl.lot.site then
			addLotSite(byId[bl.district], bl.lot, bl.lot.x, bl.lot.z, true, nil)
		end
	end

	-- 4. Mill Creek: the dam's own river (DamRiverZ below the dam) leaves the dam core westward, then
	-- runs down the east greenbelt to the south edge
	local dam = byId.Dam
	local rw = cfg.RiverWidth / 2
	local rx = cell / 2 + cfg.RiverInset -- east greenbelt, between the avenue and the east districts
	local rz = dam.z + cfg.DamRiverZ
	local river: { Rect } = {
		{ x0 = rx - rw, z0 = rz - rw, x1 = dam.x - cfg.CoreHalf + 2, z1 = rz + rw }, -- west out of the dam
	}
	-- Mill Pond: the creek widens into a lake in the east greenbelt (cfg.MillPond, world rect)
	local lake: Rect? = nil
	local mp = cfg.MillPond
	if mp and mp.x0 < rx - rw and mp.x1 > rx + rw and mp.z0 > rz + rw and mp.z1 < cfg.Bounds.maxZ then
		lake = { x0 = mp.x0, z0 = mp.z0, x1 = mp.x1, z1 = mp.z1 }
		table.insert(river, { x0 = rx - rw, z0 = rz + rw, x1 = rx + rw, z1 = mp.z0 }) -- down to the pond
		table.insert(river, lake :: Rect)
		table.insert(river, { x0 = rx - rw, z0 = mp.z1, x1 = rx + rw, z1 = cfg.Bounds.maxZ }) -- on south
	else
		table.insert(river, { x0 = rx - rw, z0 = rz + rw, x1 = rx + rw, z1 = cfg.Bounds.maxZ }) -- south to the edge
	end
	-- no band lots in the water
	for i = #bandLots, 1, -1 do
		local l = bandLots[i].lot
		for _, rv in river do
			if l.x + l.w / 2 > rv.x0 and l.x - l.w / 2 < rv.x1 and l.z + l.d / 2 > rv.z0 and l.z - l.d / 2 < rv.z1 then
				table.remove(bandLots, i)
				break
			end
		end
	end

	-- 4b. avenue corridors: frontage lots along both sides of the avenue ring (cheap facades + a few
	-- incident sites), so the city runs on between the neighbourhoods
	local corridors = Districts.corridors(cfg, r, districts, lines, river)
	for _, run in corridors do
		for _, l in run.lots do
			if l.site then
				-- a kerb node on the avenue right in front of the apron: GPS ends at the site
				local dir = FACE_DIR[l.face]
				local fx, fz = l.x + dir[1] * l.d / 2, l.z + dir[2] * l.d / 2
				local nx = if run.axis == "x" then run.line else fx
				local nz = if run.axis == "x" then fz else run.line
				local node = RoadGraph.splitAtPoint(g, nx, nz, `A{math.floor(nx)}_{math.floor(nz)}`)
				addLotSite(byId[run.district], l, l.x, l.z, true, nil, run.street, node)
			end
		end
	end

	RoadGraph.computeHalves(g)

	-- bridges: every drawn road crossing the creek
	local bridges = {}
	for _, e in g.edges do
		if e.info.drawn then
			local a, b = g.nodes[e.a], g.nodes[e.b]
			local alongX = math.abs(b.x - a.x) > math.abs(b.z - a.z)
			local hw = e.info.width / 2
			local ex0 = math.min(a.x, b.x) - (if alongX then 0 else hw)
			local ex1 = math.max(a.x, b.x) + (if alongX then 0 else hw)
			local ez0 = math.min(a.z, b.z) - (if alongX then hw else 0)
			local ez1 = math.max(a.z, b.z) + (if alongX then hw else 0)
			for _, rv in river do
				local ix0, iz0 = math.max(ex0, rv.x0), math.max(ez0, rv.z0)
				local ix1, iz1 = math.min(ex1, rv.x1), math.min(ez1, rv.z1)
				if ix0 < ix1 and iz0 < iz1 then
					table.insert(bridges, { x0 = ix0, z0 = iz0, x1 = ix1, z1 = iz1, alongX = alongX })
				end
			end
		end
	end

	-- 5. signposts at junctions between the districts: which way to every district
	local signposts: { Signpost } = {}
	for id, n in g.nodes do
		local c = string.sub(id, 1, 1)
		if (c == "G" or c == "J") and RoadGraph.degree(g, id) >= 3 then
			local arms: { [string]: { dx: number, dz: number, names: { string } } } = {}
			for _, d in districts do
				local path = RoadGraph.shortestPath(g, id, d.target)
				if path and #path >= 2 then
					local nx = g.nodes[path[2]]
					local dx, dz = nx.x - n.x, nx.z - n.z
					local len = math.sqrt(dx * dx + dz * dz)
					dx, dz = math.floor(dx / len + 0.5), math.floor(dz / len + 0.5)
					local key = `{dx},{dz}`
					arms[key] = arms[key] or { dx = dx, dz = dz, names = {} }
					table.insert(arms[key].names, d.sign)
				end
			end
			local list = {}
			for _, a in arms do
				table.sort(a.names)
				table.insert(list, a)
			end
			table.sort(list, function(a, b)
				return a.dx * 10 + a.dz < b.dx * 10 + b.dz
			end)
			table.insert(signposts, { node = id, x = n.x, z = n.z, arms = list })
		end
	end
	table.sort(signposts, function(a, b)
		return a.node < b.node
	end)

	return {
		districts = districts,
		blocks = blocks,
		bandLots = bandLots,
		corridors = corridors,
		sites = sites,
		graph = g,
		river = river,
		lake = lake,
		bridges = bridges,
		signposts = signposts,
		bounds = cfg.Bounds,
		lines = lines,
	}
end

return Districts
