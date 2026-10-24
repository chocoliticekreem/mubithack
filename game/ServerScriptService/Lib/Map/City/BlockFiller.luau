--!strict
-- BlockFiller [owner: CityBuilder]. Builds one procedural city block from its Districts plan: the
-- kerb ring (rounded corners, curb cuts at incident-site aprons) and every lot on it.
--
--   BlockFiller.base(parent, cx, cz, half, gaps, grass)      -- sidewalk ring + rounded corners
--       gaps: { { side = "N"|"S"|"E"|"W", at = offset along the side from its centre, w, cut = "drive"|"road" } }
--   BlockFiller.fillBlock(ctx, parent, block) -> Model        -- ctx: { cfg, rng: Random, siteFor(block, lot) -> Site?, onSite(model, site) }
--   BlockFiller.buildSiteLot(ctx, parent, site, lotFrame, lot) -> Model   -- (re)builds one incident site
--   BlockFiller.tree(parent, cf, rng) / car(parent, cf, color, eyes?)
-- Lot kinds: house (site or LOD shell), apartment, shop, diner, gas, storage, school, zoo, nightclub, skyscraper, reststop (sites);
-- tower, warehouse, tanks, parking, plaza, park, field (scenery). Only site buildings carry
-- Flammable chunks; scenery is a few big anchored parts (LOD-friendly).
-- Lot frame: centre of the lot on the ground, -Z = toward its street. Building frame F: the middle of
-- the building's front wall on the ground; the building extends toward +Z.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local SK = require(script.Parent:WaitForChild("SiteKit") :: ModuleScript) :: any
local SchoolPlan = require(script.Parent.Parent:WaitForChild("Interiors"):WaitForChild("Plan") :: ModuleScript) :: any
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local BlockFiller = {}

local C = SK.C
local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local GY = 0.72 -- lot ground top (sidewalk is 0.7)
local FLIP = ANG(0, math.pi, 0)
local YAW90 = ANG(0, math.rad(90), 0)

local SHOP_NAMES = {
	"MEGA DONUT", "PIZZA PALS", "TOY BOX", "BOOK NOOK", "TACO TOWN", "PET PALACE", "LUCKY LAUNDRY",
	"BARGAIN BIN", "HAIR FORCE ONE", "CUP O' JOE", "SOCK SHOP", "NOODLE HUT", "GLITTER GYM", "FISH & QUIPS",
	"BEST BAGELS", "TOTALLY TOOLS", "SPUD BUDS", "CHEESE PLEASE",
}

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function box(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, flammable: boolean?): Part
	return SK.part(parent, name, cf * CF(0, size.Y / 2, 0), size, color, { flammable = flammable, fuel = 30 })
end

---------------------------------------------------------------------------------------------------
-- scenery helpers
---------------------------------------------------------------------------------------------------
function BlockFiller.tree(parent: Instance, cf: CFrame, rng: Random, scale: number?)
	local s = (scale or 1) * rng:NextNumber(0.85, 1.25)
	local m = Instance.new("Model")
	m.Name = "Tree"
	SK.cyl(m, "Trunk", cf * CF(0, 2.6 * s, 0), 5.2 * s, 1.3 * s, C.Trunk)
	local leaf = pick(rng, C.Leaf)
	SK.ball(m, "Canopy", cf * CF(0, 7 * s, 0), 7.5 * s, leaf, { cast = true })
	if rng:NextNumber() < 0.3 then
		SK.ball(m, "Canopy", cf * CF(1.6 * s, 9.2 * s, 0.8 * s), 5 * s, leaf)
	end
	m.Parent = parent
end

function BlockFiller.car(parent: Instance, cf: CFrame, color: Color3, eyes: boolean?)
	local m = Instance.new("Model")
	m.Name = "ParkedCar"
	SK.part(m, "Body", cf * CF(0, 1.7, 0), V(6.2, 2.2, 11), color)
	SK.part(m, "Cabin", cf * CF(0, 3.6, 0.6), V(5.4, 1.8, 5.8), C.GlassDark, { material = Enum.Material.Glass, transparency = 0.15 })
	for _, w in { { -3.1, -3.4 }, { 3.1, -3.4 }, { -3.1, 3.4 }, { 3.1, 3.4 } } do
		SK.part(m, "Wheel", cf * CF(w[1], 1.15, w[2]) * ANG(0, 0, 0), V(1.2, 2.3, 2.3), C.MetalDark, { shape = Enum.PartType.Cylinder })
	end
	if eyes then
		MapKit.googlyEyes(m, cf * CF(0, 3.9, -2.4), 1.2, 0.9)
	end
	m.Parent = parent
end

local function bench(parent: Instance, cf: CFrame)
	SK.part(parent, "Bench", cf * CF(0, 1.2, 0), V(6, 0.6, 2), C.Wood)
	SK.part(parent, "BenchBack", cf * CF(0, 2.2, 0.8), V(6, 1.6, 0.4), C.Wood)
end

local hydrantCount = 0
local function hydrant(parent: Instance, cf: CFrame)
	hydrantCount += 1
	local h = MapKit.hydrant(parent, cf)
	h:SetAttribute("HydrantId", `H_{parent.Name}_{hydrantCount}`)
end
BlockFiller.hydrant = hydrant

---------------------------------------------------------------------------------------------------
-- street furniture: knockable (PhysicsFxService turns models named *TrashCan / *Bench / *Cone into
-- props; the "Knockable" tag says so explicitly), hydrants are decoration (MapKit.hydrant: tag Hydrant,
-- no prompt). cf: base on the sidewalk, -Z = toward the road.
---------------------------------------------------------------------------------------------------
local KNOCKABLE = "Knockable"

function BlockFiller.trashCan(parent: Instance, cf: CFrame, color: Color3?)
	local m = Instance.new("Model")
	m.Name = "TrashCan"
	SK.cyl(m, "Can", cf * CF(0, 1.6, 0), 3.2, 2.2, color or Color3.fromHex("#2F6B4F"))
	SK.cyl(m, "Lid", cf * CF(0, 3.35, 0), 0.3, 2.5, C.MetalDark)
	m:AddTag(KNOCKABLE)
	m.Parent = parent
	return m
end

function BlockFiller.parkBench(parent: Instance, cf: CFrame)
	local m = Instance.new("Model")
	m.Name = "Bench"
	SK.part(m, "Seat", cf * CF(0, 1.4, 0), V(6, 0.5, 2), C.Wood)
	SK.part(m, "Back", cf * CF(0, 2.5, 0.9), V(6, 1.6, 0.3), C.Wood)
	for _, x in { -2.6, 2.6 } do
		SK.part(m, "Leg", cf * CF(x, 0.6, 0), V(0.4, 1.2, 1.8), C.MetalDark)
	end
	m:AddTag(KNOCKABLE)
	m.Parent = parent
	return m
end

-- Bus shelter: roof, glass back, a knockable bench inside, a stop sign on a post.
function BlockFiller.busStop(parent: Instance, cf: CFrame, name: string?)
	local m = Instance.new("Model")
	m.Name = "BusStop"
	SK.part(m, "Roof", cf * CF(0, 8.2, 0.2), V(12, 0.5, 4.2), C.MetalDark)
	SK.part(m, "BackPanel", cf * CF(0, 4.3, 1.9), V(12, 7.2, 0.3), C.Glass, { material = Enum.Material.Glass, transparency = 0.45 })
	SK.part(m, "Post", cf * CF(-5.8, 4.1, 1.9), V(0.4, 8.2, 0.4), C.MetalDark)
	SK.part(m, "Post", cf * CF(5.8, 4.1, 1.9), V(0.4, 8.2, 0.4), C.MetalDark)
	BlockFiller.parkBench(m, cf * CF(0, 0, 0.6))
	-- a lit ad panel at the shelter's end (glows at night)
	local ad = SK.part(m, "AdPanel", cf * CF(-5.4, 4.3, 0.2), V(0.4, 6, 3.4), C.Awnings[1 + math.floor(math.abs(cf.X + cf.Z)) % #C.Awnings], { neon = true, collide = false, cast = false })
	SK.sign(ad, "MEGA DONUT", Enum.NormalId.Left, C.Trim)
	SK.part(m, "SignPole", cf * CF(8.5, 4.5, -0.5), V(0.35, 9, 0.35), C.MetalDark)
	local sign = SK.part(m, "StopSign", cf * CF(8.5, 8.4, -0.5), V(2.6, 2.6, 0.2), Color3.fromHex("#2A6FBB"))
	SK.sign(sign, "BUS", Enum.NormalId.Front, C.Trim)
	SK.sign(sign, "BUS", Enum.NormalId.Back, C.Trim)
	if name then
		m:SetAttribute("StopName", name)
	end
	m.Parent = parent
	return m
end

-- A row of kerbside furniture along a straight stretch. along(t) -> CFrame on the kerb line facing
-- the road; marks: sorted positions along the stretch (lot boundaries); skip(t) -> true for aprons.
function BlockFiller.furnish(parent: Instance, rng: Random, along: (number) -> CFrame, marks: { number }, skip: (number) -> boolean, opts: any?)
	local o = opts or {}
	local n = #marks
	if n == 0 then
		return
	end
	local stopAt = if o.busStop then math.max(1, (n + 1) // 2) else -1
	local hydrantAt = if n >= 2 then 1 else (if stopAt == 1 then -1 else 1)
	for k, t in marks do
		if not skip(t) then
			local cf = along(t)
			if k == stopAt then
				BlockFiller.busStop(parent, cf, o.street)
			elseif k == hydrantAt or (o.hydrantEvery and k % o.hydrantEvery == 0) then
				hydrant(parent, cf)
			elseif rng:NextNumber() < 0.55 then
				BlockFiller.trashCan(parent, cf * CF(rng:NextNumber(-1, 1), 0, 0), o.canColor)
			elseif o.benches then
				BlockFiller.parkBench(parent, cf)
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- block base: sidewalk ring, rounded kerbs, grass
---------------------------------------------------------------------------------------------------
function BlockFiller.base(parent: Instance, cfg: any, cx: number, cz: number, half: number, gaps: { any }, grass: boolean)
	local R, sw = cfg.CornerRadius, cfg.SidewalkWidth
	local sy, ry = cfg.SidewalkY, cfg.RoadY
	local base = Instance.new("Model")
	base.Name = "Kerbs"
	-- rounded corners: asphalt square under a sidewalk-height disc
	for _, s in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		local ax, az = cx + s[1] * (half - R / 2), cz + s[2] * (half - R / 2)
		SK.part(base, "CornerRoad", CF(ax, (ry - 0.1) / 2, az), V(R, ry + 0.1, R), C.Asphalt)
		SK.cyl(base, "Corner", CF(cx + s[1] * (half - R), (sy - 0.1) / 2, cz + s[2] * (half - R)), sy + 0.1, 2 * R, C.Sidewalk)
	end
	-- straight runs, split at gaps
	local function run(side: string)
		local horizontal = side == "N" or side == "S"
		local sign = if side == "N" or side == "W" then -1 else 1
		local list = {}
		for _, g in gaps do
			if g.side == side then
				table.insert(list, g)
			end
		end
		table.sort(list, function(a, b)
			return a.at < b.at
		end)
		local lo, hi = -(half - R), half - R
		local cursor = lo
		local function seg(a: number, b: number, top: number, color: Color3, name: string)
			if b - a < 0.1 then
				return
			end
			local m = (a + b) / 2
			local fixed = sign * (half - sw / 2)
			local cf = if horizontal then CF(cx + m, (top - 0.1) / 2, cz + fixed) else CF(cx + fixed, (top - 0.1) / 2, cz + m)
			local size = if horizontal then V(b - a, top + 0.1, sw) else V(sw, top + 0.1, b - a)
			SK.part(base, name, cf, size, color)
		end
		for _, g in list do
			local a, b = math.max(lo, g.at - g.w / 2), math.min(hi, g.at + g.w / 2)
			seg(cursor, a, sy, C.Sidewalk, "Sidewalk")
			if g.cut == "drive" then
				seg(a, b, ry + 0.15, C.Concrete, "CurbCut")
			end
			cursor = b
		end
		seg(cursor, hi, sy, C.Sidewalk, "Sidewalk")
	end
	for _, side in { "N", "S", "E", "W" } do
		run(side)
	end
	if grass then
		local inner = half - sw
		local c = R - sw
		local top = GY
		SK.part(base, "Lawn", CF(cx, (top - 0.1) / 2, cz), V(2 * inner, top + 0.1, 2 * (inner - c)), C.Grass)
		for _, s in { -1, 1 } do
			SK.part(base, "Lawn", CF(cx, (top - 0.1) / 2, cz + s * (inner - c / 2)), V(2 * (inner - c), top + 0.1, c), C.Grass)
		end
	end
	base.Parent = parent
	return base
end

---------------------------------------------------------------------------------------------------
-- building shells
---------------------------------------------------------------------------------------------------
local function evenly(len: number, n: number, kind: string, w: number?): { any }
	local out = {}
	for k = 1, n do
		table.insert(out, { at = len * k / (n + 1), w = w or 4, kind = kind })
	end
	return out
end

-- Walls, floors, stairs and roof of a box building. spec: { w, d, storeys, H, color, roof = "gable"|"flat",
-- roofColor, front(s, w) -> openings, back(s, w) -> openings, side(s, d) -> openings, ceiling = bool }
-- Returns the y of each floor surface.
-- Stairs (walkable to every floor): one wedge flight per storey along the left wall, rising toward
-- +Z, alternating between two 4.5-stud lanes (floor 2 lane A by the wall, floor 3 lane B beside it,
-- floor 4 lane A ...) so no flight runs under the one above it: full headroom (H - 0.6) everywhere.
-- Each slab has a hole only over the flight arriving there. Arrive at the back of a flight, walk
-- round to the front strip (z < z0) of the other lane and climb on. Same scheme as the Sky Tower.
local function shell(site: Instance, F: CFrame, spec: any): { number }
	local w, d, H = spec.w, spec.d, spec.H
	local bid = site.Name
	SK.part(site, "Foundation", F * CF(0, GY + 0.5, d / 2), V(w + 1, 1, d + 1), C.Concrete)
	local fy = GY + 1
	local floors = {}
	local L = math.min(H * 1.35, d - 4)
	-- a walk-in strip in front of each flight (up to 3 studs) and a landing behind it (>= 1 stud)
	local z0 = math.clamp(d - 3 - L, 2, 3.5)
	local z1 = z0 + L
	local lanes = {
		A = { x0 = -w / 2 + 0.5, x1 = -w / 2 + 5 },
		B = { x0 = -w / 2 + 5, x1 = -w / 2 + 9.5 },
	}
	local function slab(y: number, lane: any)
		local xl, xr, zf, zb = -w / 2 + 0.5, w / 2 - 0.5, 0.5, d - 0.5
		local function piece(ax: number, bx: number, az: number, bz: number)
			if bx - ax > 0.2 and bz - az > 0.2 then
				SK.part(site, "Floor", F * CF((ax + bx) / 2, y - 0.3, (az + bz) / 2), V(bx - ax, 0.6, bz - az), C.Wood)
			end
		end
		piece(xl, lane.x0, zf, zb)
		piece(lane.x1, xr, zf, zb)
		piece(lane.x0, lane.x1, zf, z0)
		piece(lane.x0, lane.x1, z1, zb)
	end
	for s = 0, spec.storeys - 1 do
		local y0 = fy + s * H
		floors[s + 1] = y0
		SK.wall(site, F, V(-w / 2, 0, 0), V(w / 2, 0, 0), y0, H, spec.color, spec.front(s, w), bid)
		SK.wall(site, F, V(w / 2, 0, d), V(-w / 2, 0, d), y0, H, spec.color, spec.back(s, w), bid)
		SK.wall(site, F, V(-w / 2, 0, d - 0.5), V(-w / 2, 0, 0.5), y0, H, spec.color, spec.side(s, d - 1), bid)
		SK.wall(site, F, V(w / 2, 0, 0.5), V(w / 2, 0, d - 0.5), y0, H, spec.color, spec.side(s, d - 1), bid)
		if s > 0 then
			-- the flight arriving at this floor (storey s + 1): lane A on even floors, lane B on odd ones
			local lane = if (s + 1) % 2 == 0 then lanes.A else lanes.B
			slab(y0, lane)
			SK.wedge(site, "Stairs", F * CF((lane.x0 + lane.x1) / 2, y0 - H / 2, (z0 + z1) / 2), V(lane.x1 - lane.x0, H, L), C.Wood)
		end
	end
	local top = fy + spec.storeys * H
	if spec.ceiling then
		local nx, nz = math.ceil(w / 8), math.ceil(d / 8)
		for i = 1, nx do
			for k = 1, nz do
				local p = SK.part(site, "Ceiling", F * CF(-w / 2 + (i - 0.5) * w / nx, top - 0.25, (k - 0.5) * d / nz), V(w / nx, 0.5, d / nz), C.Trim, {
					flammable = true,
					fuel = 20,
				})
				p:SetAttribute(Names.Attr.BuildingId, bid)
			end
		end
	end
	if spec.roof == "gable" then
		local rise = math.min(9, d * 0.4)
		local rc = spec.roofColor or C.RoofBrown
		local r1 = SK.wedge(site, "Roof1", F * CF(0, top + rise / 2, (d / 2 - 1) / 2), V(w + 2, rise, d / 2 + 1), rc)
		local r2 = SK.wedge(site, "Roof2", F * CF(0, top + rise / 2, d / 2 + (d / 2 + 1) / 2) * FLIP, V(w + 2, rise, d / 2 + 1), rc)
		r1:SetAttribute(Names.Attr.BuildingId, bid)
		r2:SetAttribute(Names.Attr.BuildingId, bid)
	elseif spec.roof ~= "none" then -- "none": the caller stacks more storeys on top
		local roof = SK.part(site, "Roof", F * CF(0, top + 0.5, d / 2), V(w + 1, 1, d + 1), spec.roofColor or C.Concrete)
		roof:SetAttribute(Names.Attr.BuildingId, bid)
		SK.part(site, "Parapet", F * CF(0, top + 1.75, -0.25), V(w + 1, 1.5, 0.5), spec.trim or C.Trim)
		SK.part(site, "Parapet", F * CF(0, top + 1.75, d + 0.25), V(w + 1, 1.5, 0.5), spec.trim or C.Trim)
	end
	floors.top = top
	return floors
end

-- Interior opt-in (Lib/Map/Interiors/Furnish builds the layout `kind` when a run binds the site).
local function interior(site: Instance, kind: string, F: CFrame, w: number, d: number, H: number, storeys: number, fy: number)
	site:SetAttribute("Interior", kind)
	site:SetAttribute("InteriorFrame", F)
	site:SetAttribute("InteriorW", w)
	site:SetAttribute("InteriorD", d)
	site:SetAttribute("InteriorH", H)
	site:SetAttribute("InteriorStoreys", storeys)
	site:SetAttribute("InteriorFloorY", fy)
end

-- Five rescue markers for house_fire (2 civilians, cat, dog, panda) spread over the floors.
local function houseRescues(site: Model, F: CFrame, w: number, d: number, floors: { number }, prefix: string?)
	local p = prefix or "R"
	local up = floors[#floors]
	SK.rescue(site, `{p}1`, "Civilian", F * CF(w * 0.22, floors[1], d * 0.55) * FLIP, "lying")
	SK.rescue(site, `{p}2`, "Civilian", F * CF(-w * 0.2, up, d * 0.7), "stand")
	SK.rescue(site, `{p}3`, "Cat", F * CF(w * 0.3, up, d * 0.3), "sitting")
	SK.rescue(site, `{p}4`, "Dog", F * CF(-w * 0.1, floors[1], d * 0.35), "sitting")
	SK.rescue(site, `{p}5`, "Panda", F * CF(w * 0.05, up, d * 0.5), "sitting")
end

---------------------------------------------------------------------------------------------------
-- lot builders (site)
---------------------------------------------------------------------------------------------------
local Build = {}

function Build.house(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	-- every call house is a proper two-storey family home: several rooms a floor for the fire to spread through
	local w = math.min(maxW, rng:NextInteger(30, 36))
	local d = math.min(maxD, rng:NextInteger(24, 28))
	local storeys = 2
	local color = pick(rng, C.Walls)
	local floors = shell(site, F, {
		w = w,
		d = d,
		H = 11,
		storeys = storeys,
		color = color,
		roof = "gable",
		roofColor = pick(rng, { C.RoofBrown, C.RoofSlate, C.RoofTerra }),
		ceiling = true,
		front = function(s, ww)
			local ops = { { at = ww / 2 - ww * 0.3, w = 4, kind = "window" }, { at = ww / 2 + ww * 0.3, w = 4, kind = "window" } }
			if s == 0 then
				table.insert(ops, { at = ww / 2, w = 4, kind = "door", locked = rng:NextNumber() < 0.35 })
			end
			return ops
		end,
		back = function(_s, ww)
			return { { at = ww * 0.3, w = 4, kind = "window" }, { at = ww * 0.7, w = 4, kind = "window" } }
		end,
		side = function(_s, dd)
			return { { at = dd / 2, w = 4, kind = "window" } }
		end,
	})
	local fy = floors[1]
	interior(site, "house", F, w, d, 11, storeys, fy)
	-- ground floor: living room + kitchen
	local sofa = box(site, "Sofa", F * CF(w * 0.2, fy, d * 0.45), V(7, 3, 3), pick(rng, C.Furniture), true)
	box(site, "Table", F * CF(-w * 0.05, fy, d * 0.45), V(4, 2.6, 3), C.Wood, true)
	local counter = box(site, "Counter", F * CF(w * 0.1, fy, d - 2), V(9, 3.6, 2.6), C.Trim, true)
	box(site, "Fridge", F * CF(w * 0.1 + 6, fy, d - 2), V(3, 7, 2.6), C.Trim)
	SK.fireStart(site, "F1", counter.CFrame * CF(0, 2.5, 0))
	SK.fireStart(site, "F2", sofa.CFrame * CF(0, 2.5, 0))
	local shelf = box(site, "Bookshelf", F * CF(-w * 0.3, fy, d - 1.8), V(5, 7, 1.6), C.Wood, true)
	SK.fireStart(site, "F4", shelf.CFrame * CF(0, 1, -2))
	local up = floors[2]
	local bed = box(site, "Bed", F * CF(w * 0.25, up, d * 0.6), V(5, 2.2, 8), pick(rng, C.Furniture), true)
	box(site, "Dresser", F * CF(0, up, d - 2), V(5, 4, 2), C.Wood, true)
	SK.fireStart(site, "F3", bed.CFrame * CF(0, 2.5, 0))
	-- the kids' room / study at the other end of the landing
	-- (clear of the stair hole: lane A runs along the left wall, x < -w/2 + 5)
	local bunk = box(site, "BunkBed", F * CF(-w / 2 + 9.5, up, d - 3), V(7, 5, 4), pick(rng, C.Furniture), true)
	box(site, "Desk", F * CF(-w * 0.1, up, 2.5), V(5, 2.6, 2), C.Wood, true)
	SK.fireStart(site, "F5", bunk.CFrame * CF(0, 3, 0))
	houseRescues(site, F, w, d, floors)
	-- nobody's spawned here on the call: an escalation phase can find someone upstairs
	SK.rescue(site, "R6", "Civilian", F * CF(-w * 0.15, up, d * 0.55), "lying")
	-- chimney + front path
	SK.part(site, "Chimney", F * CF(w * 0.3, floors.top + 5, d * 0.7), V(3, 10, 3), C.Brick)
end

function Build.apartment(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w = math.min(maxW, 60)
	local d = math.min(maxD, 30)
	local storeys = rng:NextInteger(3, 4)
	local color = pick(rng, { C.Brick, C.BrickDark, C.Walls[1], C.Walls[4] })
	local floors = shell(site, F, {
		w = w,
		d = d,
		H = 10,
		storeys = storeys,
		color = color,
		roof = "flat",
		trim = C.Trim,
		front = function(s, ww)
			if s == 0 then
				return {
					{ at = ww * 0.2, w = 8, kind = "glass" },
					{ at = ww * 0.5, w = 4, kind = "door" },
					{ at = ww * 0.8, w = 8, kind = "glass" },
				}
			end
			return evenly(ww, 4, "window")
		end,
		back = function(s, ww)
			if s == 0 then
				return { { at = ww * 0.75, w = 4, kind = "door", locked = true }, { at = ww * 0.3, w = 4, kind = "window" } }
			end
			return evenly(ww, 2, "window")
		end,
		side = function(_s, dd)
			return { { at = dd / 2, w = 4, kind = "window" } }
		end,
	})
	interior(site, "apartment", F, w, d, 10, storeys, floors[1])
	-- balconies under the upper front windows (the jumpers stand on them)
	for s = 2, storeys do
		SK.part(site, "Balcony", F * CF(0, floors[s] - 0.3, -1.5), V(w * 0.7, 0.6, 2.5), C.Concrete)
	end
	-- ground floor laundry: fuse box + wet floor (electrocution hazard)
	local fy = floors[1]
	box(site, "Washer", F * CF(w / 2 - 4, fy, d - 2.5), V(3, 3.5, 3), C.Trim)
	box(site, "Washer", F * CF(w / 2 - 8, fy, d - 2.5), V(3, 3.5, 3), C.Trim)
	local fuse = SK.part(site, "FuseBox", F * CF(w / 2 - 1.2, fy + 4.5, d - 6), V(0.8, 2.4, 1.8), C.MetalDark, {
		tags = { Names.Tag.FuseBox },
	})
	fuse:SetAttribute(Names.Attr.Power, true)
	SK.hazard(fuse, "electrocution")
	SK.part(site, "Puddle", F * CF(w / 2 - 7, fy + 0.05, d - 7), V(8, 0.1, 5), C.Water, {
		transparency = 0.35,
		collide = false,
		tags = { Names.Tag.WetFloor },
	})
	-- furniture + fires per floor
	for s = 1, storeys do
		local y = floors[s]
		local sofa = box(site, "Sofa", F * CF(w * 0.15, y, d * 0.55), V(7, 3, 3), pick(rng, C.Furniture), true)
		box(site, "Table", F * CF(-w * 0.15, y, d * 0.5), V(4, 2.6, 3), C.Wood, true)
		if s <= 4 then
			SK.fireStart(site, `F{s}`, sofa.CFrame * CF(0, 2.5, 0))
		end
	end
	-- rescues: jumpers at upper front windows, the rest inside
	local top = floors[storeys]
	local second = floors[math.max(2, storeys - 1)]
	SK.rescue(site, "R1", "Civilian", F * CF(-w * 0.3, top, 2) * FLIP, "stand", "Jumper")
	SK.rescue(site, "R2", "Civilian", F * CF(w * 0.3, second, 2) * FLIP, "stand", "Jumper")
	SK.rescue(site, "R3", "Civilian", F * CF(0, floors[2], d * 0.7), "lying")
	SK.rescue(site, "R4", "Civilian", F * CF(w * 0.25, fy, d * 0.7), "stand")
	SK.rescue(site, "R5", "Cat", F * CF(w * 0.1, top, 1.5) * FLIP, "sitting", "Windowsill")
	SK.rescue(site, "R6", "Dog", F * CF(-w * 0.2, fy, d * 0.3), "sitting")
	SK.rescue(site, "R7", "Panda", F * CF(-w * 0.1, second, d * 0.6), "sitting")
	-- rooftop water tank
	SK.cyl(site, "WaterTank", F * CF(w * 0.25, floors.top + 4, d * 0.6), 6, 6, C.Wood)
end

local function storefront(ctx: any, site: Model, F: CFrame, w: number, d: number, color: Color3, name: string, awning: Color3, neon: boolean?)
	local rng: Random = ctx.rng
	local floors = shell(site, F, {
		w = w,
		d = d,
		H = 12,
		storeys = 1,
		color = color,
		roof = "flat",
		front = function(_s, ww)
			return {
				{ at = ww * 0.22, w = 8, kind = "glass" },
				{ at = ww * 0.5, w = 4, kind = "door" },
				{ at = ww * 0.78, w = 8, kind = "glass" },
			}
		end,
		back = function(_s, ww)
			return { { at = ww * 0.3, w = 4, kind = "door", locked = true } }
		end,
		side = function(_s, dd)
			return if dd > 20 then { { at = dd * 0.6, w = 4, kind = "window" } } else {}
		end,
	})
	local fy, top = floors[1], floors.top
	interior(site, "shop", F, w, d, 12, 1, fy)
	-- striped awning sloping toward the street
	local n = 6
	for k = 1, n do
		local x = -w / 2 + (k - 0.5) * w / n
		SK.wedge(site, "Awning", F * CF(x, fy + 9.2, -2.6), V(w / n, 1.6, 5), if k % 2 == 1 then awning else C.Trim, { collide = false })
	end
	-- sign over the awning
	local signPart = SK.part(site, "Sign", F * CF(0, top + 2.5, -0.9), V(w * 0.85, 3.6, 0.6), if neon then C.Trim else awning, {
		neon = neon,
	})
	SK.sign(signPart, name, Enum.NormalId.Front, if neon then C.Red else C.Trim)
	-- interior
	local counter = box(site, "Counter", F * CF(-w * 0.25, fy, d * 0.6), V(8, 3.6, 2.6), C.Wood, true)
	local shelf1 = box(site, "Shelf", F * CF(w * 0.3, fy, d - 1.8), V(8, 6, 1.6), pick(rng, C.Furniture), true)
	local shelf2 = box(site, "Shelf", F * CF(w * 0.3, fy, d * 0.45), V(8, 5, 1.6), pick(rng, C.Furniture), true)
	box(site, "Crates", F * CF(-w * 0.35, fy, d - 2.5), V(3, 3, 3), C.Wood, true)
	SK.fireStart(site, "F1", counter.CFrame * CF(0, 2.5, 0))
	SK.fireStart(site, "F2", shelf1.CFrame * CF(0, 1, -2))
	SK.fireStart(site, "F3", shelf2.CFrame * CF(0, 1, -2))
	houseRescues(site, F, w, d, floors)
	return floors
end

function Build.shop(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	storefront(ctx, site, F, math.min(maxW, 40), math.min(maxD, 24), pick(rng, C.Walls), pick(rng, SHOP_NAMES), pick(rng, C.Awnings))
end

function Build.diner(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW, 46), math.min(maxD, 26)
	local floors = storefront(ctx, site, F, w, d, Color3.fromHex("#D6D8DC"), "DINER", Color3.fromHex("#C8232B"), true)
	site:SetAttribute("Interior", "diner")
	-- booths along the front glass
	for k = -1, 1 do
		box(site, "Booth", F * CF(k * w * 0.28, floors[1], 3), V(6, 2.8, 2.5), C.Red, true)
	end
	-- a giant goofy burger on the roof
	SK.cyl(site, "BunTop", F * CF(w * 0.3, floors.top + 5.6, d * 0.5), 2.4, 8, Color3.fromHex("#D9A55A"))
	SK.cyl(site, "Patty", F * CF(w * 0.3, floors.top + 3.8, d * 0.5), 1.2, 8.6, Color3.fromHex("#5A3A28"))
	SK.cyl(site, "BunBottom", F * CF(w * 0.3, floors.top + 2.3, d * 0.5), 1.8, 8, Color3.fromHex("#D9A55A"))
	if rng:NextNumber() < 0.7 then
		MapKit.googlyEyes(site, F * CF(w * 0.3, floors.top + 6, d * 0.5 - 3.6), 1.6)
	end
end

function Build.gas(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	-- a wide canopy over two rows of pumps (3 islands, 6 pumps: the gas_leak call shuts each valve),
	-- room behind the back row for the tanker (Twists gas_leak), the kiosk behind that
	local cw = math.min(maxW, 58)
	local canopyD = 24
	for _, s in { { -1, 1 }, { 1, 1 }, { -1, -1 }, { 1, -1 }, { 0, 1 }, { 0, -1 } } do
		SK.part(site, "Pillar", F * CF(s[1] * (cw / 2 - 3), GY + 7, canopyD / 2 + s[2] * (canopyD / 2 - 3)), V(1.6, 14, 1.6), C.Trim)
	end
	SK.part(site, "Canopy", F * CF(0, GY + 14.6, canopyD / 2), V(cw, 1.2, canopyD), C.Trim)
	local band = SK.part(site, "CanopyBand", F * CF(0, GY + 14.6, -0.1), V(cw, 2, 0.4), C.Red)
	SK.sign(band, "GAS  ·  SNACKS  ·  NO SMOKING (PLEASE)", Enum.NormalId.Front, C.Trim)
	local k = 0
	for _, z in { 5.5, 14 } do
		for _, x in { -cw * 0.32, 0, cw * 0.32 } do
			k += 1
			SK.part(site, "Island", F * CF(x, GY + 0.25, z), V(4.5, 0.5, 3), C.Concrete)
			local pump = SK.part(site, "Pump", F * CF(x, GY + 2.5, z), V(2.4, 5, 1.6), C.Red)
			SK.part(site, "PumpTop", F * CF(x, GY + 5.4, z), V(2.6, 0.8, 1.8), C.Trim)
			pump:SetAttribute("Pump", true)
			pump:SetAttribute("PumpNo", k)
			if k == 2 or k == 5 then
				local tank = SK.part(site, `GasTank{k}`, F * CF(x + 3.2, GY + 0.6, z), V(2, 1.2, 3), Color3.fromHex("#E9C46A"))
				SK.hazard(tank, "explosion")
			end
		end
	end
	-- oil-drum stack + tyre rack by the canopy edge: something for the blast to set alight
	for j = 0, 2 do
		box(site, "OilDrums", F * CF(cw / 2 - 2, GY, canopyD - 3 - j * 3.2), V(2.6, 3.4, 2.6), Color3.fromHex("#3D5A80"), true)
	end
	box(site, "TyreRack", F * CF(-cw / 2 + 2, GY, canopyD - 5), V(2.6, 4, 7), C.MetalDark, true)
	local kw, kd = math.min(maxW, 34), math.clamp(maxD - canopyD - 6, 10, 18)
	storefront(ctx, site, F * CF(0, 0, canopyD + 6), kw, kd, pick(rng, C.Walls), "QUICK STOP", C.Red)
end

function Build.storage(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local units = 9
	local uw = 15
	local w = math.min(maxW - 20, units * uw)
	uw = w / units
	local d = math.min(maxD, 24)
	local H = 11
	local bid = site.Name
	local color = Color3.fromHex("#C9A227")
	SK.part(site, "Slab", F * CF(0, GY + 0.25, d / 2), V(w + 1, 0.5, d + 1), C.Concrete)
	local y0 = GY + 0.5
	local front = {}
	for k = 1, units do
		table.insert(front, { at = (k - 0.5) * uw, w = uw - 4, kind = "gap", top = 8 })
	end
	SK.wall(site, F, V(-w / 2, 0, 0), V(w / 2, 0, 0), y0, H, color, front, bid)
	SK.wall(site, F, V(w / 2, 0, d), V(-w / 2, 0, d), y0, H, color, {}, bid)
	SK.wall(site, F, V(-w / 2, 0, d - 0.5), V(-w / 2, 0, 0.5), y0, H, color, {}, bid)
	SK.wall(site, F, V(w / 2, 0, 0.5), V(w / 2, 0, d - 0.5), y0, H, color, {}, bid)
	for k = 1, units - 1 do
		local x = -w / 2 + k * uw
		SK.wall(site, F, V(x, 0, 0.5), V(x, 0, d - 0.5), y0, H, Color3.fromHex("#B08A1F"), {}, bid)
	end
	local fires = 0
	for k = 1, units do
		local x = -w / 2 + (k - 0.5) * uw
		-- half-open roll-up door (duck under it)
		SK.part(site, "RollDoor", F * CF(x, y0 + 6.5, -0.2), V(uw - 4, 3, 0.4), Color3.fromHex("#E76F51"))
		local junk = box(site, "Junk", F * CF(x + rng:NextNumber(-2, 2), y0, d * 0.65), V(4, rng:NextNumber(2, 5), 4), pick(rng, C.Furniture), true)
		if k % 3 == 2 and fires < 4 then
			fires += 1
			SK.fireStart(site, `F{fires}`, junk.CFrame * CF(0, 2, 0))
		end
	end
	local roof = SK.part(site, "Roof", F * CF(0, y0 + H + 0.4, d / 2), V(w + 2, 0.8, d + 2), C.MetalDark)
	roof:SetAttribute(Names.Attr.BuildingId, bid)
	-- fuse box on the east end wall, puddles out front
	local fuse = SK.part(site, "FuseBox", F * CF(w / 2 + 0.9, y0 + 4.5, d * 0.3), V(0.8, 2.6, 2), C.MetalDark, {
		tags = { Names.Tag.FuseBox },
	})
	fuse:SetAttribute(Names.Attr.Power, true)
	SK.hazard(fuse, "electrocution")
	local sparks = Instance.new("Sparkles")
	sparks.SparkleColor = Color3.fromHex("#9EC9FF")
	sparks.Parent = fuse
	for k, x in { -w * 0.25, w * 0.15, w * 0.42 } do
		SK.part(site, `Puddle{k}`, F * CF(x, GY + 0.08, -4), V(9, 0.1, 5), C.Water, {
			transparency = 0.35,
			collide = false,
			tags = { Names.Tag.WetFloor },
		})
	end
	-- guard booth
	local gx = -w / 2 - 6
	box(site, "Booth", F * CF(gx, GY, 4), V(6, 8, 6), C.Trim)
	SK.part(site, "BoothWindow", F * CF(gx, GY + 5, 0.9), V(4, 2.5, 0.3), C.Glass, { material = Enum.Material.Glass, transparency = 0.4 })
	SK.rescue(site, "R1", "Civilian", F * CF(gx, GY, -1.5) * FLIP, "lying", "Guard")
	SK.rescue(site, "R2", "Dog", F * CF(-w / 2 + uw * 2.5, y0, d * 0.4), "sitting")
	SK.rescue(site, "R3", "Cat", F * CF(-w / 2 + uw * 6.5, y0, d * 0.4), "sitting")
	local sign = SK.part(site, "Sign", F * CF(0, y0 + H + 2.5, -0.6), V(w * 0.5, 3.4, 0.6), C.Red)
	SK.sign(sign, "STUFF-IT SELF STORAGE", Enum.NormalId.Front, C.Trim)
	interior(site, "storage", F, w, d, H, 1, y0) -- Interiors/Depot: racks, forklifts, office, guard booth
end

function Build.school(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW - 40, 130), 40
	local floors = shell(site, F, {
		w = w,
		d = d,
		H = 12,
		storeys = 2,
		color = Color3.fromHex("#C96F4A"),
		roof = "flat",
		trim = C.Trim,
		front = function(s, ww)
			local ops = evenly(ww, 8, "window")
			if s == 0 then
				ops[4] = { at = ww * 0.47, w = 4, kind = "door" }
				ops[5] = { at = ww * 0.53, w = 4, kind = "door" }
			end
			return ops
		end,
		back = function(s, ww)
			local ops = evenly(ww, 4, "window")
			if s == 0 then
				table.insert(ops, { at = ww * 0.1, w = 4, kind = "door", locked = true })
			end
			return ops
		end,
		side = function(_s, dd)
			return evenly(dd, 2, "window")
		end,
	})
	-- rooms, corridor and furniture come from Interiors/Plan.school and are built when a run binds the
	-- site (Interiors/School via MapService:BindSite); the markers and the chem-lab gas tank sit where
	-- that plan puts each room's hero piece, so the idle school stays a cheap shell
	site:SetAttribute("Interior", "school")
	site:SetAttribute("InteriorFrame", F)
	site:SetAttribute("InteriorW", w)
	site:SetAttribute("InteriorD", d)
	site:SetAttribute("InteriorH", 12)
	site:SetAttribute("InteriorStoreys", 2)
	site:SetAttribute("InteriorFloorY", floors[1])
	local plan = SchoolPlan.school(w, d, 2)
	for _, f in plan.fires do
		SK.fireStart(site, f.id, F * CF(f.x, floors[f.floor] + 2.5, f.z))
	end
	for _, r in plan.rescues do
		local face = if r.x < 0 then ANG(0, -math.pi / 2, 0) else ANG(0, math.pi / 2, 0)
		SK.rescue(site, r.id, "Civilian", F * CF(r.x, floors[r.floor], r.z) * face, r.pose or "stand", r.variant)
	end
	local gt = plan.gasTank
	local tank = SK.part(site, "GasTank", F * CF(gt.x, floors[gt.floor] + 1.2, gt.z) * ANG(0, math.pi / 2, 0), V(4, 2.2, 2.2), Color3.fromHex("#E9C46A"), {
		shape = Enum.PartType.Cylinder,
	})
	SK.hazard(tank, "explosion")
	-- the locker block along the back wall (Interiors draws its doors)
	for s = 1, 2 do
		box(site, "Lockers", F * CF(0, floors[s], d - 1.5), V(20, 7, 1.6), Color3.fromHex("#3D5A80"))
	end
	-- bell tower, sign, flag
	SK.part(site, "BellTower", F * CF(0, floors.top + 6, d * 0.5), V(10, 12, 10), C.Trim)
	SK.wedge(site, "BellRoof1", F * CF(0, floors.top + 14, d * 0.5 - 2.6), V(11, 4, 5.5), C.Red)
	SK.wedge(site, "BellRoof2", F * CF(0, floors.top + 14, d * 0.5 + 2.6) * FLIP, V(11, 4, 5.5), C.Red)
	local clock = SK.part(site, "Clock", F * CF(0, floors.top + 8, d * 0.5 - 5.2), V(5, 5, 0.4), C.Trim)
	SK.sign(clock, "10:10", Enum.NormalId.Front, C.MetalDark)
	local sign = SK.part(site, "Sign", F * CF(0, floors.top + 2.6, -0.7), V(44, 3.6, 0.6), Color3.fromHex("#3D5A80"))
	SK.sign(sign, "MAPLEWOOD ELEMENTARY", Enum.NormalId.Front, C.Trim)
	SK.cyl(site, "Flagpole", F * CF(-w / 2 - 8, GY + 14, -4), 28, 0.6, C.Trim)
	SK.part(site, "Flag", F * CF(-w / 2 - 5.5, GY + 25.5, -4), V(5, 3, 0.2), C.Red)
	-- playground behind (a shallow lot: beside the building, no court)
	local deep = maxD >= d + 90
	local py = if deep then F * CF(0, GY, d + 30) else F * CF(w / 2 + 32, GY, d * 0.4)
	SK.wedge(site, "Slide", py * CF(-20, 3, 0), V(3, 6, 10), C.Red)
	SK.part(site, "SlideTop", py * CF(-20, 3, 6), V(4, 6, 4), Color3.fromHex("#E9C46A"))
	SK.part(site, "SwingBar", py * CF(10, 8, 0), V(14, 0.6, 0.6), C.MetalDark)
	for _, x in { 3, 17 } do
		SK.part(site, "SwingPost", py * CF(x, 4, 0), V(0.6, 8, 0.6), C.MetalDark)
	end
	if deep then
		SK.part(site, "Court", py * CF(0, 0.05, 34), V(60, 0.1, 34), Color3.fromHex("#B0553E"))
		SK.part(site, "CourtLine", py * CF(0, 0.11, 34), V(0.4, 0.1, 34), C.Trim)
	end
	if rng:NextNumber() < 0.5 then
		BlockFiller.tree(site, py * CF(40, 0, 10), rng)
	end
end

function Build.zoo(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local bid = site.Name
	local gate = F
	-- gate arch
	for _, x in { -12, 12 } do
		SK.part(site, "GatePost", gate * CF(x, GY + 7, 0), V(3, 14, 3), C.Wood)
	end
	local arch = SK.part(site, "GateSign", gate * CF(0, GY + 15, 0), V(30, 4, 1.2), Color3.fromHex("#2A9D8F"))
	SK.sign(arch, "CITY ZOO", Enum.NormalId.Front, C.Trim)
	SK.part(site, "Path", gate * CF(0, GY + 0.04, maxD / 2), V(10, 0.1, maxD - 4), Color3.fromHex("#D9C9A8"))
	local function fence(cx: number, cz: number, sx: number, sz: number)
		for _, e in { { 0, -1, sx, 0.5 }, { 0, 1, sx, 0.5 }, { -1, 0, 0.5, sz }, { 1, 0, 0.5, sz } } do
			SK.part(site, "Fence", gate * CF(cx + e[1] * sx / 2, GY + 2, cz + e[2] * sz / 2), V(e[3], 0.5, e[4]), C.Wood)
			SK.part(site, "Fence", gate * CF(cx + e[1] * sx / 2, GY + 3.6, cz + e[2] * sz / 2), V(e[3], 0.5, e[4]), C.Wood)
		end
	end
	-- panda enclosure (the mission): bamboo grove + keeper hut
	local px, pz = -maxW * 0.25, maxD * 0.45
	fence(px, pz, 70, 60)
	local fires = 0
	for k = 1, 18 do
		local bx, bz = px + rng:NextNumber(-30, 30), pz + rng:NextNumber(-26, 26)
		local stalk = SK.cyl(site, "Bamboo", gate * CF(bx, GY + 6, bz), 12, 0.9, Color3.fromHex("#7FB04A"), { flammable = true, fuel = 18 })
		stalk:SetAttribute(Names.Attr.BuildingId, bid)
		if k % 5 == 0 and fires < 4 then
			fires += 1
			SK.fireStart(site, `F{fires}`, stalk.CFrame)
		end
	end
	local hut = gate * CF(px + 20, 0, pz + 14)
	SK.part(site, "HutFloor", hut * CF(0, GY + 0.3, 5), V(15, 0.6, 11), C.Wood)
	SK.wall(site, hut, V(-7, 0, 0), V(7, 0, 0), GY + 0.6, 9, C.Wood, { { at = 7, w = 4, kind = "door" } }, bid)
	SK.wall(site, hut, V(7, 0, 10), V(-7, 0, 10), GY + 0.6, 9, C.Wood, {}, bid)
	SK.wall(site, hut, V(-7, 0, 9.5), V(-7, 0, 0.5), GY + 0.6, 9, C.Wood, { { at = 4.5, w = 4, kind = "window" } }, bid)
	SK.wall(site, hut, V(7, 0, 0.5), V(7, 0, 9.5), GY + 0.6, 9, C.Wood, {}, bid)
	SK.part(site, "Roof", hut * CF(0, GY + 10, 5), V(16, 0.8, 12), C.RoofTerra)
	SK.fireStart(site, "F5", hut * CF(0, GY + 2, 6))
	SK.rescue(site, "R1", "Panda", gate * CF(px - 6, GY, pz), "sitting")
	SK.rescue(site, "R2", "Civilian", hut * CF(-3, GY + 0.6, 6), "lying", "Keeper")
	SK.rescue(site, "R3", "Civilian", gate * CF(px + 8, GY, pz - 18), "stand", "Keeper")
	-- elephant + giraffe (goofy blobs with googly eyes)
	local ex, ez = maxW * 0.25, maxD * 0.3
	fence(ex, ez, 60, 50)
	local eb = gate * CF(ex, GY, ez)
	SK.part(site, "Elephant", eb * CF(0, 6, 0), V(9, 8, 14), Color3.fromHex("#9A9AA6"))
	SK.part(site, "ElephantHead", eb * CF(0, 8, -8), V(7, 7, 5), Color3.fromHex("#9A9AA6"))
	SK.part(site, "Trunk", eb * CF(0, 4.5, -11), V(1.6, 7, 1.6), Color3.fromHex("#8A8A96"))
	MapKit.googlyEyes(site, eb * CF(0, 9.5, -10.6), 1.8)
	local gx, gz = maxW * 0.25, maxD * 0.7
	fence(gx, gz, 60, 40)
	local gb = gate * CF(gx, GY, gz)
	SK.part(site, "Giraffe", gb * CF(0, 7, 0), V(5, 5, 9), Color3.fromHex("#E9C46A"))
	SK.part(site, "GiraffeNeck", gb * CF(0, 13, -3.5), V(2, 12, 2), Color3.fromHex("#E9C46A"))
	SK.part(site, "GiraffeHead", gb * CF(0, 19.5, -4.5), V(2.4, 2.4, 4), Color3.fromHex("#E9C46A"))
	MapKit.googlyEyes(site, gb * CF(0, 20.3, -6.6), 1)
	for _, l in { { -1.6, -3 }, { 1.6, -3 }, { -1.6, 3 }, { 1.6, 3 } } do
		SK.part(site, "GiraffeLeg", gb * CF(l[1], 2.3, l[2]), V(0.9, 4.6, 0.9), Color3.fromHex("#C9A227"))
	end
	-- penguin pool
	local pool = SK.cyl(site, "PenguinPool", gate * CF(-maxW * 0.25, GY + 0.1, maxD * 0.85), 0.3, 26, C.Water, {
		material = Enum.Material.Glass,
		transparency = 0.2,
		collide = false,
		tags = { Names.Tag.Hydrant },
	})
	pool:SetAttribute("HydrantId", `Pool_{bid}`)
	for k = 1, 3 do
		local pc = gate * CF(-maxW * 0.25 + k * 4 - 8, GY, maxD * 0.85 - 15)
		SK.ball(site, "Penguin", pc * CF(0, 1.6, 0), 3, Color3.fromHex("#2B2B30"))
		SK.ball(site, "PenguinBelly", pc * CF(0, 1.6, -0.6), 2.2, C.Trim)
	end
	for k = 1, 6 do
		BlockFiller.tree(site, gate * CF(rng:NextNumber(-maxW / 2 + 8, maxW / 2 - 8), 0, rng:NextNumber(10, maxD - 10)), rng)
	end
end

---------------------------------------------------------------------------------------------------
-- lot builders (scenery, cheap)
---------------------------------------------------------------------------------------------------
local Scenery = {}

-- Cheap facade detail for the filler buildings (no textures/decals/SurfaceGuis): one thin inset
-- window strip per floor per visible face (capped), a roof cap + parapet in a varied roof colour,
-- one rooftop feature (AC boxes / water tower / antenna), an entrance canopy, and optionally a
-- ground-floor shop front. Body spans x in [-w/2, w/2], z in [0, d], y in [y0, y0 + h] of frame F.
-- Roughly 8-20 parts per building; all non-colliding, non-queryable and shadowless except the cap.
local ROOF_COLORS = { C.RoofSlate, C.MetalDark, Color3.fromHex("#6B705C"), Color3.fromHex("#9AA0A6"), Color3.fromHex("#5C5470"), C.Concrete }
local DETAIL = { collide = false, query = false, cast = false }
local GLASS_DETAIL = { collide = false, query = false, cast = false, material = Enum.Material.Glass }

local function dress(m: Instance, F: CFrame, w: number, d: number, h: number, rng: Random, o: any)
	o = o or {}
	local y0 = o.y0 or GY
	local band = o.band or C.GlassDark
	local base = o.base or (if o.shop then 11 else 6)
	local fh = o.floor or 10
	local span = h - base - 3
	if span > 4 then
		local n = math.clamp(math.floor(span / fh), 1, o.maxBands or 6)
		local step = span / n
		local bh = math.min(3.2, step * 0.45)
		local sides = if o.sides == false then 0 else math.min(n, 4)
		for i = 1, n do
			local y = y0 + base + step * (i - 0.5)
			if o.front ~= false then
				SK.part(m, "WindowBand", F * CF(0, y, -0.15), V(w - 3, bh, 0.3), band, GLASS_DETAIL)
			end
			-- sides get fewer, evenly picked bands (they are seen at an angle)
			if sides > 0 and (i - 1) % math.max(1, math.round(n / sides)) == 0 then
				for _, sx in { -1, 1 } do
					SK.part(m, "WindowBand", F * CF(sx * (w / 2 + 0.15), y, d / 2), V(0.3, bh, d - 3), band, GLASS_DETAIL)
				end
			end
		end
	end
	local top = y0 + h
	if o.roof ~= false then
		local rc = o.roofColor or pick(rng, ROOF_COLORS)
		SK.part(m, "RoofCap", F * CF(0, top + 0.15, d / 2), V(w - 1.6, 0.3, d - 1.6), rc, { cast = false })
		if o.parapet ~= false then
			local pc = o.parapetColor or C.Trim
			SK.part(m, "Parapet", F * CF(0, top + 1, 0.4), V(w, 2, 0.8), pc, DETAIL)
			SK.part(m, "Parapet", F * CF(0, top + 1, d - 0.4), V(w, 2, 0.8), pc, DETAIL)
			SK.part(m, "Parapet", F * CF(-w / 2 + 0.4, top + 1, d / 2), V(0.8, 2, d - 1.6), pc, DETAIL)
			SK.part(m, "Parapet", F * CF(w / 2 - 0.4, top + 1, d / 2), V(0.8, 2, d - 1.6), pc, DETAIL)
		end
		local r = if o.kit == false then 1 else rng:NextNumber()
		if r < 0.4 then
			SK.part(m, "RoofAC", F * CF(-w * 0.2, top + 1.8, d * 0.4), V(math.min(8, w * 0.25), 3, 5), C.Metal, DETAIL)
			SK.part(m, "RoofAC", F * CF(w * 0.15, top + 1.3, d * 0.65), V(5, 2.2, math.min(7, d * 0.25)), C.Metal, DETAIL)
		elseif r < 0.7 and w > 18 and d > 18 then
			local tx, tz = w * 0.22 * (if rng:NextNumber() < 0.5 then -1 else 1), d * 0.6
			SK.part(m, "WaterTowerLegs", F * CF(tx, top + 2, tz), V(5, 4, 5), C.Wood, DETAIL)
			SK.cyl(m, "WaterTower", F * CF(tx, top + 7.5, tz), 7, 7, Color3.fromHex("#8A5A3C"), DETAIL)
			SK.cyl(m, "WaterTowerCap", F * CF(tx, top + 11.3, tz), 0.6, 7.8, C.RoofSlate, DETAIL)
		elseif r < 0.9 then
			SK.part(m, "RoofHut", F * CF(w * 0.2, top + 2.5, d * 0.55), V(math.min(10, w * 0.3), 5, math.min(8, d * 0.3)), C.MetalDark, DETAIL)
			SK.cyl(m, "Antenna", F * CF(-w * 0.2, top + 7, d * 0.5), 14, 0.5, C.Red, DETAIL)
		end
	end
	if o.shop then
		SK.part(m, "ShopGlass", F * CF(0, y0 + 3.6, -0.2), V(w - 4, 5.6, 0.3), C.GlassDark, GLASS_DETAIL)
		local aw = o.awning or pick(rng, C.Awnings)
		SK.wedge(m, "ShopAwning", F * CF(0, y0 + 8.2, -1.6), V(w - 2, 1.4, 3.2), aw, DETAIL)
		SK.part(m, "ShopSign", F * CF(0, y0 + 10, -0.25), V(math.min(w * 0.5, 24), 1.8, 0.4), C.Trim, DETAIL)
	elseif o.canopy ~= false then
		local cw = math.min(14, w * 0.4)
		SK.part(m, "Canopy", F * CF(0, y0 + 8, -2), V(cw, 0.5, 4), o.canopyColor or C.MetalDark, DETAIL)
		SK.part(m, "Entrance", F * CF(0, y0 + 3.6, -0.2), V(cw - 4, 7, 0.3), C.GlassDark, GLASS_DETAIL)
	end
end
BlockFiller._dress = dress

function Scenery.house(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW, rng:NextInteger(22, 30)), math.min(maxD, rng:NextInteger(18, 24))
	local h = if rng:NextNumber() < 0.5 then 11 else 20
	local m = Instance.new("Model")
	m.Name = "House"
	local color = pick(rng, C.Walls)
	SK.part(m, "Body", F * CF(0, GY + h / 2, d / 2), V(w, h, d), color)
	local rise = 7
	local rc = pick(rng, { C.RoofBrown, C.RoofSlate, C.RoofTerra })
	SK.wedge(m, "Roof1", F * CF(0, GY + h + rise / 2, d / 4 - 0.5), V(w + 2, rise, d / 2 + 1), rc)
	SK.wedge(m, "Roof2", F * CF(0, GY + h + rise / 2, 3 * d / 4 + 0.5) * FLIP, V(w + 2, rise, d / 2 + 1), rc)
	SK.part(m, "Door", F * CF(0, GY + 3.5, -0.35), V(4, 7, 0.4), C.Wood)
	SK.part(m, "Chimney", F * CF(w * 0.3, GY + h + 4, d * 0.7), V(2.6, 9, 2.6), C.BrickDark, DETAIL)
	-- windows as one dark strip per storey (cheap LOD shell)
	SK.part(m, "WindowFake", F * CF(0, GY + 5, -0.1), V(w * 0.8, 3.6, 0.3), C.GlassDark, { material = Enum.Material.Glass, collide = false, query = false })
	if h > 12 then
		SK.part(m, "WindowFake", F * CF(0, GY + 15, -0.1), V(w * 0.7, 4, 0.3), C.GlassDark, { material = Enum.Material.Glass, collide = false, query = false })
	end
	m.Parent = parent
	if rng:NextNumber() < 0.2 then
		BlockFiller.tree(parent, F * CF(w / 2 + 6, GY, -6), rng)
	end
	if rng:NextNumber() < 0.12 then
		BlockFiller.car(parent, F * CF(-w / 2 - 6, GY, -8), pick(rng, C.Awnings), rng:NextNumber() < 0.3)
	end
end

function Scenery.tower(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW - 6, rng:NextInteger(40, 70)), math.min(maxD - 10, rng:NextInteger(36, 56))
	local hubDist = Vector3.new(F.Position.X, 0, F.Position.Z).Magnitude
	local h = if hubDist < 650 then rng:NextInteger(80, 170) else rng:NextInteger(50, 130)
	local m = Instance.new("Model")
	m.Name = "Tower"
	local color = pick(rng, { Color3.fromHex("#8E9AAF"), Color3.fromHex("#CBC0D3"), Color3.fromHex("#DEE2FF"), Color3.fromHex("#B7B1A8"), C.Walls[4] })
	local glass = pick(rng, { Color3.fromHex("#4F7FA0"), Color3.fromHex("#5D7F99"), C.GlassDark, Color3.fromHex("#3F6E80") })
	local roofColor = pick(rng, ROOF_COLORS)
	-- tall towers step back: a full-footprint base and a narrower upper tier (one extra part)
	local h1 = if h > 95 then math.floor(h * 0.62) else h
	SK.part(m, "Body", F * CF(0, GY + h1 / 2, d / 2), V(w, h1, d), color)
	dress(m, F, w, d, h1, rng, { band = glass, floor = 7, maxBands = 8, roofColor = roofColor, parapet = h1 == h, kit = h1 == h, canopyColor = glass })
	if h1 < h then
		local w2, d2, h2 = math.floor(w * 0.72), math.floor(d * 0.72), h - h1
		local F2 = F * CF(0, 0, (d - d2) / 2)
		SK.part(m, "Upper", F2 * CF(0, GY + h1 + h2 / 2, d2 / 2), V(w2, h2, d2), color)
		dress(m, F2, w2, d2, h2, rng, { y0 = GY + h1, base = 2, band = glass, floor = 7, maxBands = 6, roofColor = roofColor, canopy = false })
	end
	m.Parent = parent
end

function Scenery.warehouse(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d, h = maxW - 12, math.min(maxD - 14, 50), rng:NextInteger(18, 26)
	local m = Instance.new("Model")
	m.Name = "Warehouse"
	SK.part(m, "Body", F * CF(0, GY + h / 2, d / 2), V(w, h, d), pick(rng, { Color3.fromHex("#8C9096"), Color3.fromHex("#A3B18A"), Color3.fromHex("#B5838D") }))
	SK.part(m, "Roof", F * CF(0, GY + h + 0.5, d / 2), V(w + 1, 1, d + 1), C.MetalDark)
	for k = -1, 1 do
		SK.part(m, "Dock", F * CF(k * w * 0.28, GY + 5, -0.2), V(10, 10, 0.4), Color3.fromHex("#5F6B73"))
	end
	dress(m, F, w, d, h, rng, { base = 11, floor = 20, maxBands = 1, sides = false, roof = false, canopy = false })
	SK.part(m, "RoofAC", F * CF(-w * 0.25, GY + h + 2.5, d * 0.5), V(8, 3, 6), C.Metal, DETAIL)
	SK.part(m, "Vent", F * CF(w * 0.2, GY + h + 2, d * 0.4), V(4, 2, 4), C.MetalDark, DETAIL)
	m.Parent = parent
end

function Scenery.tanks(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	for k = -1, 1 do
		local h = rng:NextInteger(18, 30)
		SK.cyl(parent, "Tank", F * CF(k * maxW * 0.28, GY + h / 2, maxD * 0.4), h, 20, Color3.fromHex("#D6D8DC"))
		SK.cyl(parent, "TankBand", F * CF(k * maxW * 0.28, GY + h * 0.7, maxD * 0.4), 2, 20.4, C.Red)
	end
end

function Scenery.parking(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = maxW - 6, maxD - 10
	SK.part(parent, "Lot", F * CF(0, GY + 0.03, d / 2), V(w, 0.1, d), C.AsphaltDark)
	local stalls = math.floor(w / 11)
	for row = 0, 1 do
		local z = if row == 0 then d * 0.25 else d * 0.75
		for k = 0, stalls do
			SK.part(parent, "Stripe", F * CF(-w / 2 + k * 11, GY + 0.1, z), V(0.4, 0.05, 14), C.LineWhite, { collide = false })
		end
		for k = 1, stalls do
			if rng:NextNumber() < 0.45 then
				local yaw = if row == 0 then 0 else math.pi
				BlockFiller.car(parent, F * CF(-w / 2 + (k - 0.5) * 11, GY, z) * ANG(0, yaw, 0), pick(rng, C.Awnings), rng:NextNumber() < 0.15)
			end
		end
	end
end

function Scenery.plaza(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = maxW - 6, maxD - 8
	SK.part(parent, "Paving", F * CF(0, GY + 0.04, d / 2), V(w, 0.1, d), Color3.fromHex("#D9CBB8"))
	local c = F * CF(0, GY, d / 2)
	SK.cyl(parent, "FountainRim", c * CF(0, 1, 0), 2, 22, C.Concrete)
	SK.cyl(parent, "FountainWater", c * CF(0, 1.6, 0), 1.4, 20, C.Water, { material = Enum.Material.Glass, transparency = 0.25 })
	-- a centrepiece in the fountain (so the plazas round downtown are not all the same)
	local piece = rng:NextInteger(1, 4)
	if piece == 1 then
		-- the statue of a firefighter who looks very sure of himself
		SK.part(parent, "Plinth", c * CF(0, 4, 0), V(4, 6, 4), C.Concrete)
		SK.part(parent, "Statue", c * CF(0, 9.5, 0), V(2.4, 5, 1.6), Color3.fromHex("#6D8F7A"))
		SK.ball(parent, "StatueHead", c * CF(0, 12.8, 0), 2, Color3.fromHex("#6D8F7A"))
		SK.part(parent, "StatueHelmet", c * CF(0, 13.8, 0), V(2.6, 0.8, 2.6), Color3.fromHex("#6D8F7A"))
	elseif piece == 2 then
		-- a giant rubber duck (googly eyes, obviously)
		SK.ball(parent, "GiantDuck", c * CF(0, 5, 0), 8, Color3.fromHex("#F2D13C"))
		SK.ball(parent, "GiantDuckHead", c * CF(0, 10, -2.4), 5, Color3.fromHex("#F2D13C"))
		SK.part(parent, "GiantDuckBeak", c * CF(0, 9.6, -5.2), V(2.4, 1, 2), Color3.fromHex("#E76F51"))
		MapKit.googlyEyes(parent, c * CF(0, 11, -4.6), 1.3)
	elseif piece == 3 then
		-- a golden fire hydrant on a plinth ("To Our Most Reliable Citizen")
		SK.part(parent, "Plinth", c * CF(0, 3, 0), V(5, 4, 5), C.Concrete)
		SK.cyl(parent, "GoldHydrant", c * CF(0, 8, 0), 6, 3.4, Color3.fromHex("#E9C46A"))
		SK.ball(parent, "GoldHydrantCap", c * CF(0, 11.2, 0), 3.4, Color3.fromHex("#E9C46A"))
	else
		-- an abstract donut sculpture nobody asked for
		SK.part(parent, "Plinth", c * CF(0, 3, 0), V(4, 4, 4), C.Concrete)
		SK.cyl(parent, "Donut", c * CF(0, 10, 0) * ANG(math.rad(90), 0, 0), 2.6, 9, Color3.fromHex("#D98B6F"))
		SK.cyl(parent, "DonutHole", c * CF(0, 10, 0) * ANG(math.rad(90), 0, 0), 2.8, 3.4, Color3.fromHex("#9EC9DA"))
	end
	for _, s in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		BlockFiller.tree(parent, c * CF(s[1] * w * 0.35, 0, s[2] * d * 0.32), rng)
		bench(parent, c * CF(s[1] * 16, 0, s[2] * 4) * ANG(0, math.rad(90 * s[1]), 0))
	end
end

function Scenery.park(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local c = F * CF(0, GY, maxD / 2)
	SK.part(parent, "PathNS", c * CF(0, 0.04, 0), V(8, 0.1, maxD - 4), Color3.fromHex("#D9C9A8"))
	SK.part(parent, "PathEW", c * CF(0, 0.04, 0), V(maxW - 4, 0.1, 8), Color3.fromHex("#D9C9A8"))
	-- duck pond
	local pc = c * CF(-maxW * 0.22, 0, maxD * 0.22)
	SK.cyl(parent, "PondRim", pc * CF(0, 0.2, 0), 0.4, 46, Color3.fromHex("#A89A86"))
	local pond = SK.cyl(parent, "Pond", pc * CF(0, 0.3, 0), 0.4, 44, C.Water, {
		material = Enum.Material.Glass,
		transparency = 0.2,
		collide = false,
		tags = { Names.Tag.Hydrant },
	})
	pond:SetAttribute("HydrantId", `Pond_{parent.Name}`)
	for k = 1, 4 do
		local dc = pc * CF(rng:NextNumber(-12, 12), 0.9, rng:NextNumber(-12, 12)) * ANG(0, rng:NextNumber(0, 6.28), 0)
		SK.ball(parent, "Duck", dc, 1.6, Color3.fromHex("#F2D13C"))
		SK.ball(parent, "DuckHead", dc * CF(0, 0.9, -0.6), 1, Color3.fromHex("#F2D13C"))
		SK.part(parent, "Beak", dc * CF(0, 0.85, -1.2), V(0.4, 0.2, 0.5), Color3.fromHex("#E76F51"))
	end
	-- gazebo
	local gz = c * CF(maxW * 0.25, 0, -maxD * 0.22)
	SK.cyl(parent, "GazeboFloor", gz * CF(0, 0.4, 0), 0.8, 18, C.Wood)
	for k = 0, 5 do
		local a = k * math.pi / 3
		SK.part(parent, "GazeboPost", gz * CF(math.cos(a) * 7.5, 5, math.sin(a) * 7.5), V(0.8, 9, 0.8), C.Trim)
	end
	SK.cyl(parent, "GazeboRoof", gz * CF(0, 10, 0), 1.2, 20, C.Red)
	for _ = 1, 14 do
		local x, z = rng:NextNumber(-maxW / 2 + 8, maxW / 2 - 8), rng:NextNumber(-maxD / 2 + 8, maxD / 2 - 8)
		if math.abs(x) > 8 and math.abs(z) > 8 then
			BlockFiller.tree(parent, c * CF(x, 0, z), rng, 1.2)
		end
	end
	for _, b in { { 10, 20, 0 }, { -10, -20, 180 }, { 20, -10, 90 }, { -20, 10, -90 } } do
		bench(parent, c * CF(b[1], 0, b[2]) * ANG(0, math.rad(b[3]), 0))
	end
end

function Scenery.field(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local c = F * CF(0, GY, maxD / 2)
	SK.part(parent, "Track", c * CF(0, 0.04, 0), V(maxW - 20, 0.1, maxD - 30), Color3.fromHex("#B0553E"))
	SK.part(parent, "Pitch", c * CF(0, 0.08, 0), V(maxW - 44, 0.1, maxD - 54), Color3.fromHex("#5E9E3E"))
	SK.part(parent, "Halfway", c * CF(0, 0.13, 0), V(maxW - 44, 0.05, 0.5), C.LineWhite, { collide = false })
	for _, s in { -1, 1 } do
		local g = c * CF(0, 0, s * (maxD / 2 - 30))
		SK.part(parent, "GoalBar", g * CF(0, 8, 0), V(24, 0.8, 0.8), C.Trim)
		for _, x in { -12, 12 } do
			SK.part(parent, "GoalPost", g * CF(x, 4, 0), V(0.8, 8, 0.8), C.Trim)
		end
	end
	SK.wedge(parent, "Bleachers", c * CF(maxW / 2 - 6, 4, 0) * ANG(0, math.rad(90), 0), V(60, 8, 8), Color3.fromHex("#3D5A80"))
end

local function pine(parent: Instance, cf: CFrame, rng: Random, scale: number?)
	local sc = (scale or 1) * rng:NextNumber(0.8, 1.4)
	local m = Instance.new("Model")
	m.Name = "Pine"
	SK.cyl(m, "Trunk", cf * CF(0, 2 * sc, 0), 4 * sc, 1.2 * sc, C.Trunk)
	local green = pick(rng, { Color3.fromHex("#2F5D34"), Color3.fromHex("#3B6B3A"), Color3.fromHex("#294F2E") })
	for t = 0, 1 do
		local w = (8 - t * 3.4) * sc
		SK.part(m, "Tier", cf * CF(0, (5 + t * 4.4) * sc, 0) * ANG(0, math.rad(45 * t), 0), V(w, 4.4 * sc, w), green)
	end
	m.Parent = parent
end
BlockFiller.pine = pine

function Scenery.woods(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local n = math.clamp(math.floor(maxW * maxD / 1200), 3, 5)
	for _ = 1, n do
		pine(parent, F * CF(rng:NextNumber(-maxW / 2 + 4, maxW / 2 - 4), GY, rng:NextNumber(4, math.max(5, maxD - 4))), rng)
	end
end

function Scenery.grove(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	for _ = 1, 3 do
		BlockFiller.tree(parent, F * CF(rng:NextNumber(-maxW / 2 + 6, maxW / 2 - 6), GY, rng:NextNumber(8, math.max(9, maxD - 6))), rng, 1.2)
	end
	bench(parent, F * CF(0, GY, 4) * FLIP)
end

function Scenery.farmland(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local crop = pick(rng, { Color3.fromHex("#E2C35A"), Color3.fromHex("#8DBE52"), Color3.fromHex("#D98B3A") })
	local rows = math.max(2, math.floor(maxW / 9))
	for k = 1, rows do
		local x = -maxW / 2 + (k - 0.5) * maxW / rows
		SK.part(parent, "CropRow", F * CF(x, GY + 1, maxD / 2), V(3.5, 2, maxD - 6), crop, { material = Enum.Material.Grass })
	end
	if rng:NextNumber() < 0.3 then
		SK.part(parent, "HayBale", F * CF(maxW * 0.3, GY + 1.6, 3), V(5, 3.2, 3.2), Color3.fromHex("#D9B44A"))
	end
end

function Scenery.barn(_ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local w, d = math.min(maxW - 6, 30), math.min(maxD - 6, 34)
	local m = Instance.new("Model")
	m.Name = "Barn"
	local red = Color3.fromHex("#A8322A")
	SK.part(m, "Body", F * CF(0, GY + 8, d / 2), V(w, 16, d), red)
	SK.wedge(m, "Roof1", F * CF(-w / 4, GY + 20, d / 2) * ANG(0, math.rad(90), 0), V(d + 1, 8, w / 2 + 1), C.RoofSlate)
	SK.wedge(m, "Roof2", F * CF(w / 4, GY + 20, d / 2) * ANG(0, math.rad(-90), 0), V(d + 1, 8, w / 2 + 1), C.RoofSlate)
	SK.part(m, "Door", F * CF(0, GY + 6, -0.2), V(10, 12, 0.4), C.Trim)
	m.Parent = parent
end

---------------------------------------------------------------------------------------------------
-- low-detail facades (avenue corridors): 2-4 big parts each, read as a skyline from the road
---------------------------------------------------------------------------------------------------
local FACADE_COLORS = {
	Color3.fromHex("#8E9AAF"),
	Color3.fromHex("#CBC0D3"),
	Color3.fromHex("#B7B1A8"),
	Color3.fromHex("#D9B99B"),
	Color3.fromHex("#A3B18A"),
	Color3.fromHex("#9EC1CC"),
	Color3.fromHex("#C9A9A6"),
	Color3.fromHex("#E8D3A8"),
}
local FACADE_GLASS = { Color3.fromHex("#6FA8C8"), Color3.fromHex("#88B9C4"), C.GlassDark, Color3.fromHex("#5D7F99") }

-- An office/apartment slab: body, a glass front, a coloured cornice. Height grows with lot depth.
function Scenery.facade(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.max(20, maxW - rng:NextInteger(4, 12)), math.max(16, maxD - rng:NextInteger(6, 24))
	-- a skyline: taller the closer to the hub (downtown round the station), lower out by the edges
	local hubDist = Vector3.new(F.Position.X, 0, F.Position.Z).Magnitude
	local h = if hubDist < 650 then rng:NextInteger(70, 160) else rng:NextInteger(36, 100)
	local m = Instance.new("Model")
	m.Name = "Facade"
	local color = pick(rng, FACADE_COLORS)
	local glass = pick(rng, FACADE_GLASS)
	-- downtown slabs get a shop-front ground floor; tall ones step back once
	local shop = hubDist < 900 and rng:NextNumber() < 0.6
	local h1 = if h > 95 then math.floor(h * 0.65) else h
	SK.part(m, "Body", F * CF(0, GY + h1 / 2, d / 2), V(w, h1, d), color)
	SK.part(m, "Cornice", F * CF(0, GY + h1 + 0.6, d / 2), V(w + 1.2, 1.2, d + 1.2), pick(rng, C.Awnings), { cast = false })
	dress(m, F, w, d, h1 + 1.2, rng, { band = glass, floor = 8, maxBands = 7, shop = shop, parapet = false, roof = h1 == h })
	if h1 < h then
		local w2, d2, h2 = math.floor(w * 0.7), math.floor(d * 0.7), h - h1
		local F2 = F * CF(0, 0, (d - d2) / 2)
		SK.part(m, "Upper", F2 * CF(0, GY + h1 + 1.2 + h2 / 2, d2 / 2), V(w2, h2, d2), color)
		dress(m, F2, w2, d2, h2, rng, { y0 = GY + h1 + 1.2, base = 2, band = glass, floor = 8, maxBands = 5, canopy = false })
	end
	m.Parent = parent
end

-- A shop-topped midrise: body, a storefront band with a sign colour, rows of windows as one strip.
function Scenery.midrise(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.max(20, maxW - 6), math.max(16, math.min(maxD - 8, 40))
	local h = rng:NextInteger(24, 44)
	local m = Instance.new("Model")
	m.Name = "Midrise"
	SK.part(m, "Body", F * CF(0, GY + h / 2, d / 2), V(w, h, d), pick(rng, C.Walls))
	dress(m, F, w, d, h, rng, { floor = 9, maxBands = 4, shop = true, parapetColor = pick(rng, { C.Trim, C.BrickDark, C.Concrete }) })
	m.Parent = parent
end

-- Suburban pair of houses under one gable (4 parts).
function Scenery.duplex(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW - 8, rng:NextInteger(26, 36)), math.min(maxD - 30, rng:NextInteger(18, 24))
	local h = if rng:NextNumber() < 0.5 then 11 else 18
	local setback = rng:NextInteger(10, 22)
	local G = F * CF(rng:NextNumber(-3, 3), 0, setback)
	local m = Instance.new("Model")
	m.Name = "Duplex"
	SK.part(m, "Body", G * CF(0, GY + h / 2, d / 2), V(w, h, d), pick(rng, C.Walls))
	local rc = pick(rng, { C.RoofBrown, C.RoofSlate, C.RoofTerra })
	SK.wedge(m, "Roof1", G * CF(0, GY + h + 3, d / 4 - 0.5), V(w + 2, 6, d / 2 + 1), rc)
	SK.wedge(m, "Roof2", G * CF(0, GY + h + 3, 3 * d / 4 + 0.5) * FLIP, V(w + 2, 6, d / 2 + 1), rc)
	-- two front doors under one porch canopy, a window strip per storey (front + both sides)
	for _, sx in { -1, 1 } do
		SK.part(m, "Door", G * CF(sx * w * 0.12, GY + 3.5, -0.2), V(3.6, 7, 0.4), pick(rng, { C.Wood, C.Red, Color3.fromHex("#3D5A80") }), DETAIL)
	end
	SK.part(m, "Porch", G * CF(0, GY + 7.6, -1.6), V(w * 0.45, 0.4, 3.2), C.Trim, DETAIL)
	dress(m, G, w, d, h, rng, { base = 9, floor = 7, maxBands = 1, roof = false, canopy = false })
	m.Parent = parent
	-- a knockable mailbox at the kerb (PhysicsFxService: name ends with "mailbox")
	local mb = Instance.new("Model")
	mb.Name = "Mailbox"
	SK.part(mb, "Post", F * CF(-w / 2 + 2, GY + 1.6, 2), V(0.4, 3.2, 0.4), C.Wood)
	SK.part(mb, "Box", F * CF(-w / 2 + 2, GY + 3.6, 2), V(1.2, 1.2, 2), pick(rng, C.Awnings))
	mb:AddTag("Knockable")
	mb.Parent = parent
	if rng:NextNumber() < 0.35 then
		BlockFiller.tree(parent, F * CF(w / 2 + 5, GY, 6), rng)
	end
end

-- Corrugated shed with a roll-up door (industrial filler, 3 parts).
function Scenery.shed(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d, h = math.max(20, maxW - 16), math.max(16, math.min(maxD - 12, 46)), rng:NextInteger(14, 22)
	local m = Instance.new("Model")
	m.Name = "Shed"
	SK.part(m, "Body", F * CF(0, GY + h / 2, d / 2 + 8), V(w, h, d), pick(rng, { Color3.fromHex("#8C9096"), Color3.fromHex("#A3B18A"), Color3.fromHex("#B08A1F"), Color3.fromHex("#5F7A8A") }), {
		material = Enum.Material.CorrodedMetal,
	})
	SK.part(m, "RollDoor", F * CF(0, GY + 6, 7.8), V(math.min(16, w - 6), 12, 0.4), Color3.fromHex("#E76F51"), { collide = false })
	SK.part(m, "Yard", F * CF(0, GY + 0.03, 4), V(w, 0.1, 8), C.AsphaltDark, { collide = false, cast = false })
	-- a clerestory strip, a door canopy over the roll door and a roof vent
	dress(m, F * CF(0, 0, 8), w, d, h, rng, { base = math.max(13, h - 6), floor = 20, maxBands = 1, sides = false, roof = false, canopy = false })
	SK.part(m, "Canopy", F * CF(0, GY + 12.6, 6.4), V(math.min(18, w - 4), 0.4, 3), C.MetalDark, DETAIL)
	SK.part(m, "Vent", F * CF(w * 0.2, GY + h + 1, d / 2 + 8), V(4, 2, 4), C.Metal, DETAIL)
	m.Parent = parent
end

-- A single crop field with a few furrows (cheaper than "farmland").
function Scenery.cropfield(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local crop = pick(rng, { Color3.fromHex("#E2C35A"), Color3.fromHex("#8DBE52"), Color3.fromHex("#D98B3A"), Color3.fromHex("#B5C95A") })
	SK.part(parent, "Field", F * CF(0, GY + 0.6, maxD / 2), V(maxW - 6, 1.2, maxD - 6), crop, { material = Enum.Material.Grass, cast = false })
	for k = -1, 1 do
		SK.part(parent, "Furrow", F * CF(k * maxW * 0.28, GY + 1.25, maxD / 2), V(2.5, 0.2, maxD - 10), Color3.fromHex("#8A6A45"), {
			material = Enum.Material.Ground,
			collide = false,
			cast = false,
		})
	end
	if rng:NextNumber() < 0.5 then
		SK.part(parent, "HayBale", F * CF(maxW * 0.3, GY + 1.8, 6), V(5, 3.2, 3.2), Color3.fromHex("#D9B44A"))
	elseif rng:NextNumber() < 0.6 then
		-- a scarecrow who has clearly given up
		local s = F * CF(rng:NextNumber(-maxW * 0.3, maxW * 0.3), GY + 1.2, maxD * 0.5) * ANG(0, 0, math.rad(rng:NextNumber(-12, 12)))
		SK.part(parent, "ScarecrowPole", s * CF(0, 4, 0), V(0.6, 8, 0.6), C.Wood)
		SK.part(parent, "ScarecrowArms", s * CF(0, 6, 0), V(7, 0.6, 0.6), Color3.fromHex("#3D5A80"))
		SK.ball(parent, "ScarecrowHead", s * CF(0, 8.6, 0), 2.2, Color3.fromHex("#E2C35A"))
	end
end

-- A surface car park (cheap): asphalt, two stall lines, an entrance sign and a few parked cars.
function Scenery.carpark(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = maxW - 4, math.min(maxD - 4, 60)
	SK.part(parent, "CarPark", F * CF(0, GY + 0.03, d / 2), V(w, 0.1, d), C.AsphaltDark, { cast = false })
	for _, z in { d * 0.3, d * 0.7 } do
		SK.part(parent, "StallLine", F * CF(0, GY + 0.1, z), V(w - 8, 0.05, 0.4), C.LineWhite, { collide = false, cast = false, query = false })
	end
	local sign = SK.part(parent, "ParkSign", F * CF(-w / 2 + 3, GY + 6, 1), V(3.2, 3.2, 0.3), Color3.fromHex("#2A6FBB"))
	SK.sign(sign, "P", Enum.NormalId.Front, C.Trim)
	SK.part(parent, "ParkSignPole", F * CF(-w / 2 + 3, GY + 2.2, 1.2), V(0.3, 4.4, 0.3), C.MetalDark)
	local stalls = math.max(1, math.floor((w - 10) / 11))
	for _, row in { { d * 0.15, 0 }, { d * 0.85, math.pi } } do
		for k = 1, stalls do
			if rng:NextNumber() < 0.35 then
				local x = -w / 2 + 5 + (k - 0.5) * (w - 10) / stalls
				BlockFiller.car(parent, F * CF(x, GY, row[1]) * ANG(0, row[2], 0), pick(rng, C.Awnings), rng:NextNumber() < 0.2)
			end
		end
	end
end

-- Blazeville City Hall: columned portico, a domed roof, a flag and a paved forecourt (~25 parts).
function Scenery.cityhall(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local m = Instance.new("Model")
	m.Name = "CityHall"
	m:SetAttribute("DisplayName", "Blazeville City Hall")
	local stone = Color3.fromHex("#E8E1D3")
	local w = math.min(maxW - 40, 100)
	local d = math.min(maxD - 30, 44)
	local z0 = math.max(16, maxD - d - 6) -- building front
	SK.part(m, "Forecourt", F * CF(0, GY + 0.04, z0 / 2), V(math.min(maxW - 4, w + 60), 0.1, z0), Color3.fromHex("#D9CBB8"), { cast = false })
	SK.part(m, "Plinth", F * CF(0, GY + 1, z0 + d / 2 - 4), V(w + 8, 2, d + 10), stone)
	SK.wedge(m, "Steps", F * CF(0, GY + 1, z0 - 11), V(w * 0.6, 2, 4) , stone)
	SK.part(m, "Body", F * CF(0, GY + 2 + 14, z0 + d / 2), V(w, 28, d), stone)
	SK.part(m, "Cornice", F * CF(0, GY + 2 + 28.75, z0 + d / 2), V(w + 2, 1.5, d + 2), C.Trim)
	-- portico: columns + pediment
	local pw = w * 0.55
	for k = 0, 5 do
		local x = -pw / 2 + k * pw / 5
		SK.cyl(m, "Column", F * CF(x, GY + 2 + 11, z0 - 5), 22, 2.4, C.Trim)
	end
	SK.part(m, "Entablature", F * CF(0, GY + 2 + 23, z0 - 4), V(pw + 4, 2, 9), stone)
	local ped = F * CF(0, GY + 2 + 26.5, z0 - 4)
	SK.wedge(m, "Pediment", ped * CF(-pw / 4 - 1, 0, 0) * ANG(0, math.rad(90), 0), V(9, 5, pw / 2 + 2), stone)
	SK.wedge(m, "Pediment", ped * CF(pw / 4 + 1, 0, 0) * ANG(0, math.rad(-90), 0), V(9, 5, pw / 2 + 2), stone)
	local sign = SK.part(m, "Sign", F * CF(0, GY + 2 + 23, z0 - 8.6), V(pw - 4, 1.6, 0.3), stone)
	SK.sign(sign, "BLAZEVILLE CITY HALL", Enum.NormalId.Front, Color3.fromHex("#3D5A80"))
	-- drum + dome + golden finial
	local top = F * CF(0, GY + 2 + 29.5, z0 + d / 2)
	SK.cyl(m, "Drum", top * CF(0, 4, 0), 8, 26, stone)
	SK.ball(m, "Dome", top * CF(0, 8, 0), 26, Color3.fromHex("#6FA08A"))
	SK.cyl(m, "Finial", top * CF(0, 23, 0), 6, 1, Color3.fromHex("#E9C46A"), { neon = true, collide = false })
	-- flagpole + flag, two trees on the forecourt
	SK.cyl(m, "Flagpole", F * CF(w / 2 + 12, GY + 16, z0 * 0.5), 32, 0.6, C.Trim)
	SK.part(m, "Flag", F * CF(w / 2 + 15, GY + 29.5, z0 * 0.5), V(6, 3.6, 0.2), C.Red)
	m.Parent = parent
	for _, s in { -1, 1 } do
		BlockFiller.tree(parent, F * CF(s * (w / 2 + 2), GY, z0 * 0.4), rng, 1.3)
	end
end

-- Zoo-side topiary: hedge animals (an elephant and a giraffe) on a lawn with a bench (~10 parts).
function Scenery.topiary(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local hedge = Color3.fromHex("#4F8A3A")
	local c = F * CF(-maxW * 0.2, GY, maxD * 0.5) * ANG(0, rng:NextNumber(-0.5, 0.5), 0)
	SK.ball(parent, "TopiaryElephant", c * CF(0, 6, 0), 10, hedge, { material = Enum.Material.Grass })
	SK.ball(parent, "TopiaryElephantHead", c * CF(0, 8, -6), 6, hedge, { material = Enum.Material.Grass })
	SK.part(parent, "TopiaryTrunk", c * CF(0, 4, -9), V(1.6, 7, 1.6), hedge, { material = Enum.Material.Grass })
	local gc = F * CF(maxW * 0.22, GY, maxD * 0.45)
	SK.ball(parent, "TopiaryGiraffe", gc * CF(0, 6, 0), 6, hedge, { material = Enum.Material.Grass })
	SK.part(parent, "TopiaryNeck", gc * CF(0, 11, -2) * ANG(math.rad(-15), 0, 0), V(1.8, 10, 1.8), hedge, { material = Enum.Material.Grass })
	SK.ball(parent, "TopiaryGiraffeHead", gc * CF(0, 16.5, -3.6), 3, hedge, { material = Enum.Material.Grass })
	MapKit.googlyEyes(parent, gc * CF(0, 17, -5), 0.9)
	BlockFiller.parkBench(parent, F * CF(0, GY, 6) * FLIP)
end

-- A loose clump of pines (woods filler, ~9 parts).
function Scenery.copse(ctx: any, parent: Instance, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	for _ = 1, 3 do
		BlockFiller.pine(parent, F * CF(rng:NextNumber(-maxW / 2 + 8, maxW / 2 - 8), GY, rng:NextNumber(10, math.max(11, maxD - 8))), rng, 1.3)
	end
end

---------------------------------------------------------------------------------------------------
-- big downtown sites: nightclub, skyscraper (after `dress`, which the tower reuses)
---------------------------------------------------------------------------------------------------
local NEON_PINK = Color3.fromHex("#FF3DAE")
local NEON_CYAN = Color3.fromHex("#2FE6FF")
local NEON_LIME = Color3.fromHex("#B6FF3B")
local NEON_GOLD = Color3.fromHex("#FFC53D")

-- Club Inferno: a windowless black box with a neon sign and marquee, a glowing dance floor, a DJ booth
-- with a fog machine (gas bottle: explosion hazard), a bar, a VIP couch and a crowd of partygoers.
function Build.nightclub(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW, 52), math.min(maxD, 42)
	local H = 16
	local floors = shell(site, F, {
		w = w,
		d = d,
		H = H,
		storeys = 1,
		color = Color3.fromHex("#241A33"),
		roof = "flat",
		roofColor = Color3.fromHex("#1A1424"),
		trim = NEON_PINK,
		front = function(_s, ww)
			return { { at = ww * 0.5, w = 6, kind = "gap", top = 9 } } -- wide entrance (no door to jam)
		end,
		back = function(_s, ww)
			return { { at = ww * 0.8, w = 4, kind = "door" } } -- fire exit
		end,
		side = function(_s, dd)
			return { { at = dd * 0.5, w = 4, kind = "window" } }
		end,
	})
	local fy, top = floors[1], floors.top
	-- neon sign, marquee canopy and a strip of neon along the parapet
	local sign = SK.part(site, "NeonSign", F * CF(0, top + 4.5, -0.9), V(w * 0.8, 6, 0.6), Color3.fromHex("#120C1A"))
	SK.sign(sign, "CLUB INFERNO", Enum.NormalId.Front, NEON_PINK)
	SK.part(site, "SignGlow", F * CF(0, top + 1.2, -1.3), V(w * 0.8, 0.5, 0.3), NEON_PINK, { neon = true, collide = false, cast = false })
	for _, sx in { -1, 1 } do -- neon pilasters on the front corners
		SK.part(site, "NeonStrip", F * CF(sx * (w / 2 - 0.6), fy + H / 2, -0.7), V(0.6, H, 0.4), if sx < 0 then NEON_CYAN else NEON_PINK, {
			neon = true,
			collide = false,
			cast = false,
		})
	end
	SK.part(site, "Marquee", F * CF(0, fy + 10, -3), V(14, 0.8, 6), Color3.fromHex("#120C1A"))
	SK.part(site, "MarqueeGlow", F * CF(0, fy + 9.5, -5.9), V(14, 0.5, 0.3), NEON_CYAN, { neon = true, collide = false, cast = false })
	-- velvet rope + bouncer stand out front
	for _, x in { -9, 9 } do
		SK.cyl(site, "RopePost", F * CF(x, GY + 1.6, -6), 3.2, 0.6, NEON_GOLD)
	end
	SK.part(site, "VelvetRope", F * CF(-5.5, GY + 2.6, -6), V(7, 0.4, 0.4), Color3.fromHex("#B0123C"), { collide = false })
	-- dance floor: 4 x 4 glowing tiles
	local colors = { NEON_PINK, NEON_CYAN, NEON_LIME, NEON_GOLD }
	local tile = 5
	local fz = d * 0.42
	for i = 0, 3 do
		for k = 0, 3 do
			SK.part(site, "DanceTile", F * CF((i - 1.5) * tile, fy + 0.1, fz + (k - 1.5) * tile), V(tile - 0.3, 0.2, tile - 0.3), colors[(i + k) % 4 + 1], {
				neon = true,
				cast = false,
			})
		end
	end
	local ball = SK.ball(site, "DiscoBall", F * CF(0, top - 3, fz), 3, Color3.fromHex("#D6D8DC"), { material = Enum.Material.Foil, collide = false })
	local light = Instance.new("PointLight")
	light.Color = NEON_PINK
	light.Range = 26
	light.Brightness = 2
	light.Parent = ball
	-- DJ booth + speakers at the back, fog machine with its gas bottle
	local booth = box(site, "DJBooth", F * CF(0, fy, d - 4), V(12, 4, 3), Color3.fromHex("#120C1A"), true)
	SK.part(site, "DJGlow", F * CF(0, fy + 2, d - 5.6), V(12, 0.4, 0.2), NEON_CYAN, { neon = true, collide = false, cast = false })
	local spk = box(site, "Speaker", F * CF(-w / 2 + 3.5, fy, d - 3.5), V(4, 9, 3.5), Color3.fromHex("#1B1B1F"), true)
	box(site, "Speaker", F * CF(w / 2 - 3.5, fy, d - 3.5), V(4, 9, 3.5), Color3.fromHex("#1B1B1F"), true)
	local fog = box(site, "FogMachine", F * CF(8.5, fy, d - 4), V(3, 2, 2.4), C.MetalDark)
	local bottle = SK.cyl(site, "FogGasBottle", F * CF(10.6, fy + 1.6, d - 4), 3.2, 1.4, Color3.fromHex("#E9C46A"))
	SK.hazard(bottle, "explosion")
	-- bar along the left wall, VIP couch on the right
	local bar = box(site, "Bar", F * CF(-w / 2 + 3, fy, d * 0.45), V(3, 4, 16), Color3.fromHex("#5A2A3A"), true)
	box(site, "BarShelf", F * CF(-w / 2 + 1.2, fy + 4.5, d * 0.45), V(1, 4, 14), C.Wood, true)
	local couch = box(site, "VIPCouch", F * CF(w / 2 - 3, fy, d * 0.45), V(4, 3, 12), Color3.fromHex("#8E1A5A"), true)
	local curtain = box(site, "Curtain", F * CF(w / 2 - 1.2, fy, d * 0.75), V(0.6, H - 1, 8), Color3.fromHex("#6A0F2E"), true)
	SK.fireStart(site, "F1", booth.CFrame * CF(0, 2.5, 0))
	SK.fireStart(site, "F2", spk.CFrame * CF(0, 1, 0))
	SK.fireStart(site, "F3", bar.CFrame * CF(0, 2.5, 0))
	SK.fireStart(site, "F4", couch.CFrame * CF(0, 2, 0))
	SK.fireStart(site, "F5", curtain.CFrame)
	SK.fireStart(site, "F6", fog.CFrame * CF(0, 1.5, 0))
	-- the crowd: still dancing on the floor, the DJ won't leave the decks, a very good dog by the couch
	for k = 1, 6 do
		local i, j = (k - 1) % 3, (k - 1) // 3
		local pose = if rng:NextNumber() < 0.25 then "sitting" else "stand"
		SK.rescue(site, `R{k}`, "Civilian", F * CF((i - 1) * 6, fy + 0.2, fz + (j - 0.5) * 7) * ANG(0, rng:NextNumber(0, 6.28), 0), pose, "Partygoer")
	end
	SK.rescue(site, "R7", "Civilian", F * CF(-3, fy, d - 7) * FLIP, "stand", "DJ")
	SK.rescue(site, "R8", "Dog", F * CF(w / 2 - 7, fy, d * 0.3), "sitting")
	SK.rescue(site, "R9", "Civilian", F * CF(-w / 2 + 6.5, fy, d * 0.6), "lying", "Partygoer")
	interior(site, "nightclub", F, w, d, H, 1, fy) -- Interiors/Club: bar, DJ booth, VIP, restrooms, coat check
end

-- Sky Tower: a 6-storey office block you can climb all the way to the roof, crowned by a tall cheap
-- tower + spire so it rules the skyline next to the station.
--   * Stairs: one 12-stud wedge flight per storey (~37 degrees, a Humanoid walks it), alternating
--     between two lanes along the left wall so no flight runs under the one above it (full headroom).
--     Flight to floor s rises toward +Z in lane A (s even) or lane B (s odd); each floor has a hole only
--     over the flight that arrives there. Arrive at the back of a flight, walk round to the front of the
--     other lane, climb on. The last flight (lane B) comes up through the roof into a stair hut.
--   * Breakable glass on every upper floor (Window tag): a Ladder from the street reaches floors 2-3.
--   * Roof deck: parapet railing, a helipad with a big H, a water tower, AC units, a crate stack that
--     is always one of the fires (FireStart attr Priority) and somebody stranded up there.
-- Fires start on floors 3-6 and the roof; people are trapped from floor 2 to the roof.
function Build.skyscraper(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW, 44), math.min(maxD, 40)
	local H, storeys = 12, 6
	local bid = site.Name
	local body = Color3.fromHex("#8E9AAF")
	local glass = Color3.fromHex("#6FA8C8")
	-- ground floor: a full flammable shell with the lobby doors
	local floors = shell(site, F, {
		w = w,
		d = d,
		H = H,
		storeys = 1,
		color = body,
		roof = "none",
		front = function(_s, ww)
			return {
				{ at = ww * 0.2, w = 8, kind = "glass" },
				{ at = ww * 0.44, w = 4, kind = "door" },
				{ at = ww * 0.56, w = 4, kind = "door" },
				{ at = ww * 0.8, w = 8, kind = "glass" },
			}
		end,
		back = function(_s, ww)
			return { { at = ww * 0.75, w = 4, kind = "door", locked = true } }
		end,
		side = function(_s, dd)
			return { { at = dd * 0.5, w = 4, kind = "window" } }
		end,
	})
	local fy = floors[1]
	local top = fy + storeys * H -- roof deck surface
	local L = 16 -- flight run (z 2 .. 18): 12 up over 16 along
	local z0, z1 = 2, 2 + L
	-- two stair lanes along the left wall (x ranges, building frame)
	local lanes = {
		A = { x0 = -w / 2 + 0.5, x1 = -w / 2 + 5 },
		B = { x0 = -w / 2 + 5, x1 = -w / 2 + 9.5 },
	}
	local function laneFor(s: number): any -- the flight arriving at floor s (2 .. storeys + 1 = roof)
		return if s % 2 == 0 then lanes.A else lanes.B
	end
	local function slab(y: number, hole: any, name: string)
		local xl, xr = -w / 2 + 0.5, w / 2 - 0.5
		local zf, zb = 0.5, d - 0.5
		local function piece(ax: number, bx: number, az: number, bz: number)
			if bx - ax > 0.2 and bz - az > 0.2 then
				SK.part(site, name, F * CF((ax + bx) / 2, y - 0.3, (az + bz) / 2), V(bx - ax, 0.6, bz - az), C.Concrete)
			end
		end
		piece(xl, hole.x0, zf, zb)
		piece(hole.x1, xr, zf, zb)
		piece(hole.x0, hole.x1, zf, z0)
		piece(hole.x0, hole.x1, z1, zb)
	end
	local function flight(s: number, yTop: number)
		local lane = laneFor(s)
		local cx = (lane.x0 + lane.x1) / 2
		SK.wedge(site, "Stairs", F * CF(cx, yTop - H / 2, (z0 + z1) / 2), V(lane.x1 - lane.x0, H, L), C.Metal)
		-- handrail on the open side of the flight (between the lanes for A, the room side for B)
		local railX = if lane == lanes.A then lane.x1 - 0.15 else lane.x1 + 0.15
		local rail = SK.part(site, "StairRail", F * CF(railX, yTop - H / 2 + 3, (z0 + z1) / 2) * ANG(-math.atan2(H, L), 0, 0), V(0.3, 0.3, math.sqrt(H * H + L * L)), C.MetalDark, {
			collide = false,
			cast = false,
		})
		rail:SetAttribute("Decor", true)
	end
	-- upper storeys, cheap: per face a spandrel + header (flammable cladding) and a band of breakable
	-- glass panes between them
	local ys = { fy }
	local faces = {
		{ cf = CF(0, 0, 0), len = w, panes = 3, rot = CFrame.identity },
		{ cf = CF(0, 0, d), len = w, panes = 3, rot = CFrame.identity },
		{ cf = CF(-w / 2, 0, d / 2), len = d - 1, panes = 2, rot = YAW90 },
		{ cf = CF(w / 2, 0, d / 2), len = d - 1, panes = 2, rot = YAW90 },
	}
	for s = 1, storeys - 1 do
		local y0 = fy + s * H
		ys[s + 1] = y0
		for _, f in faces do
			local base = F * f.cf * f.rot
			local sp = SK.part(site, "Spandrel", base * CF(0, y0 + 1.5, 0), V(f.len, 3, 1), body, { flammable = true, fuel = 25 })
			local hd = SK.part(site, "Header", base * CF(0, y0 + 10.5, 0), V(f.len, 3, 1), body, { flammable = true, fuel = 25 })
			sp:SetAttribute(Names.Attr.BuildingId, bid)
			hd:SetAttribute(Names.Attr.BuildingId, bid)
			local pw = f.len / f.panes
			for k = 1, f.panes do
				SK.part(site, "Window", base * CF(-f.len / 2 + (k - 0.5) * pw, y0 + 6, 0), V(pw - 0.2, 6, 0.4), glass, {
					material = Enum.Material.Glass,
					transparency = 0.35,
					tags = { Names.Tag.Window },
				})
			end
		end
		slab(y0, laneFor(s + 1), "Floor")
		flight(s + 1, y0)
	end
	-- the last flight comes up through the roof deck (lane B on a 6-storey tower)
	slab(top, laneFor(storeys + 1), "Roof")
	flight(storeys + 1, top)
	-- roof: parapet railing all round, a stair hut over the hatch with an open doorway at its back
	for _, e in { { 0, 0.25, w, 0.5 }, { 0, d - 0.25, w, 0.5 }, { -w / 2 + 0.25, d / 2, 0.5, d }, { w / 2 - 0.25, d / 2, 0.5, d } } do
		SK.part(site, "Parapet", F * CF(e[1], top + 1.75, e[2]), V(e[3], 3.5, e[4]), C.Trim)
	end
	local hut = laneFor(storeys + 1)
	local hx0, hx1 = hut.x0 - 0.5, hut.x1 + 0.5
	local hutH = 9
	SK.part(site, "HutWall", F * CF(hx0 + 0.25, top + hutH / 2, (z0 + z1) / 2 - 0.75), V(0.5, hutH, L + 2.5), C.Trim) -- left
	SK.part(site, "HutWall", F * CF(hx1 - 0.25, top + hutH / 2, (z0 + z1) / 2 - 0.75), V(0.5, hutH, L + 2.5), C.Trim) -- right
	SK.part(site, "HutWall", F * CF((hx0 + hx1) / 2, top + hutH / 2, z0 - 1.25), V(hx1 - hx0, hutH, 0.5), C.Trim) -- front
	SK.part(site, "HutRoof", F * CF((hx0 + hx1) / 2, top + hutH + 0.25, (z0 + z1) / 2 - 0.25), V(hx1 - hx0 + 1, 0.5, L + 4), C.MetalDark)
	local roofSign = SK.part(site, "RoofSign", F * CF((hx0 + hx1) / 2, top + hutH - 1, z1 + 0.6), V(hx1 - hx0 - 1, 1.4, 0.3), C.Red, { collide = false })
	SK.sign(roofSign, "ROOF", Enum.NormalId.Back, C.Trim)
	-- helipad (big H), water tower, AC units, a crate stack (the roof fire) and deck chairs
	local deckZ = d * 0.55 -- the tower above sits behind this line
	local pad = SK.cyl(site, "Helipad", F * CF(w * 0.18, top + 0.1, deckZ * 0.5 + 1), 0.2, math.min(17, deckZ - 2), Color3.fromHex("#3B3940"))
	pad:SetAttribute("Decor", true)
	local hc = F * CF(w * 0.18, top + 0.22, deckZ * 0.5 + 1)
	for _, x in { -2.6, 2.6 } do
		SK.part(site, "HelipadH", hc * CF(x, 0, 0), V(1.2, 0.05, 8), NEON_GOLD, { collide = false, cast = false })
	end
	SK.part(site, "HelipadH", hc, V(4, 0.05, 1.2), NEON_GOLD, { collide = false, cast = false })
	local wt = F * CF(w / 2 - 4.5, top, 4.5)
	for _, o in { { -1.6, -1.6 }, { 1.6, -1.6 }, { -1.6, 1.6 }, { 1.6, 1.6 } } do
		SK.part(site, "WaterTowerLeg", wt * CF(o[1], 3, o[2]), V(0.6, 6, 0.6), C.Wood)
	end
	SK.cyl(site, "WaterTower", wt * CF(0, 9, 0), 6, 6, Color3.fromHex("#8A5A3C"))
	SK.cyl(site, "WaterTowerCap", wt * CF(0, 12.3, 0), 0.6, 6.8, C.RoofSlate)
	for k, z in { deckZ * 0.45, deckZ * 0.75 } do -- along the right parapet, clear of the hut's doorway
		SK.part(site, `RoofAC{k}`, F * CF(w / 2 - 4.5, top + 1.5, z), V(5, 3, 3.5), C.Metal)
	end
	local crates = box(site, "RoofCrates", F * CF(-w * 0.12, top, 4), V(5, 3, 4), C.Wood, true)
	box(site, "DeckChair", F * CF(-w * 0.11, top, 9), V(2.4, 1.6, 4), C.Awnings[3], true)
	local roofFire = SK.fireStart(site, "F9", crates.CFrame * CF(0, 2, 0))
	roofFire:SetAttribute("Priority", true) -- lightFires lights Priority markers first: the roof always burns
	-- the cheap tower above the back of the deck (non-flammable, non-queryable scenery), spire on top
	local w2, d2 = math.floor(w * 0.62), math.floor(d - deckZ)
	local F2 = F * CF(0, 0, d - d2)
	local h2 = 128 -- taller than every skyline slab round the hub (they top out ~160 total)
	SK.part(site, "Tower", F2 * CF(0, top + h2 / 2, d2 / 2), V(w2, h2, d2), body, { query = false })
	dress(site, F2, w2, d2, h2, rng, { y0 = top, base = 4, band = glass, floor = 7, maxBands = 8, canopy = false, roof = false })
	local cap = F2 * CF(0, top + h2, d2 / 2)
	SK.part(site, "Crown", cap * CF(0, 2, 0), V(w2 - 4, 4, d2 - 4), C.MetalDark, { query = false })
	SK.part(site, "CrownGlow", cap * CF(0, 4.3, 0), V(w2 - 3.6, 0.6, d2 - 3.6), NEON_CYAN, { neon = true, collide = false, query = false, cast = false })
	SK.cyl(site, "Spire", cap * CF(0, 18, 0), 28, 1.2, C.Metal, { query = false })
	SK.ball(site, "SpireBeacon", cap * CF(0, 32.5, 0), 2, C.Red, { neon = true, collide = false, query = false })
	local sign = SK.part(site, "Sign", F * CF(0, top - 1.5, -0.9), V(w * 0.7, 3, 0.5), Color3.fromHex("#1F2A3A"))
	SK.sign(sign, "SKY TOWER", Enum.NormalId.Front, NEON_CYAN)
	-- offices (kept clear of the stair lanes, x > -w/2 + 10): desk, cabinet, plant; fires on floors 3-6
	local nf = 0
	for s = 2, storeys do
		local y = ys[s]
		local desk = box(site, "Desk", F * CF(w * 0.12, y, d * 0.5), V(7, 2.6, 3.5), C.Wood, true)
		local cab = box(site, "Cabinet", F * CF(w * 0.36, y, d - 2.2), V(4, 5, 2), C.MetalDark, true)
		box(site, "Plant", F * CF(-w * 0.08, y, d - 2.5), V(2, 4, 2), C.Leaf[1], true)
		if s >= 3 then
			nf += 1
			SK.fireStart(site, `F{nf}`, desk.CFrame * CF(0, 2, 0))
			if s >= 5 then
				nf += 1
				SK.fireStart(site, `F{nf}`, cab.CFrame * CF(0, 1, -1.5))
			end
		end
	end
	-- trapped: R1 on the roof by the helipad (always spawned: first marker), two at the 2nd/3rd-floor
	-- windows (ladder), the rest higher up (stairs), a cat on a 6th-floor sill
	SK.rescue(site, "R1", "Civilian", F * CF(w * 0.18, top + 0.2, deckZ - 2.5), "stand", "Office")
	SK.rescue(site, "R2", "Civilian", F * CF(-w * 0.05, ys[3], 1.6) * FLIP, "stand", "Office")
	SK.rescue(site, "R3", "Civilian", F * CF(w * 0.25, ys[2], 1.6) * FLIP, "stand", "Office")
	SK.rescue(site, "R4", "Civilian", F * CF(0, ys[4], d * 0.6), "lying", "Office")
	SK.rescue(site, "R5", "Civilian", F * CF(w * 0.2, ys[5], d * 0.4), "stand", "Office")
	SK.rescue(site, "R6", "Civilian", F * CF(w * 0.05, ys[6], d * 0.7), "sitting", "Office")
	SK.rescue(site, "R7", "Cat", F * CF(w * 0.3, ys[6], 1.5) * FLIP, "sitting", "Windowsill")
	-- a lobby desk downstairs
	box(site, "LobbyDesk", F * CF(w * 0.2, fy, d * 0.5), V(8, 3.4, 3), C.Trim)
	interior(site, "skyscraper", F, w, d, H, storeys, fy) -- Interiors/Office: lobby + an office fit-out per floor
end

-- v3: Highway 67 rest stop (CityConfig.HighwaySites, call highway_pileup). A paved lay-by: the WEST half
-- holds what burns (two parked cars, picnic tables, the restroom hut: Flammable, FireStart markers), the
-- EAST half holds four driver RescueSpawn markers >= 30 studs from anything flammable (RescueService
-- panics NPCs within 20 studs of fire). HazardService's "pileup" twist builds a crumpled car round each
-- spawned driver at dispatch time and pins them until a pry tool pops the door. ~35 parts.
local function burnCar(site: Instance, cf: CFrame, color: Color3, id: string)
	local body = SK.part(site, "WreckBody", cf * CF(0, 1.7, 0), V(6.2, 2.2, 11), color, { flammable = true, fuel = 45 })
	SK.part(site, "WreckCabin", cf * CF(0, 3.6, 0.6), V(5.4, 1.8, 5.8), C.GlassDark, { flammable = true, fuel = 30, material = Enum.Material.Glass })
	for _, w in { { -3.1, -3.4 }, { 3.1, -3.4 }, { -3.1, 3.4 }, { 3.1, 3.4 } } do
		SK.part(site, "Wheel", cf * CF(w[1], 1.15, w[2]), V(1.2, 2.3, 2.3), C.MetalDark, { shape = Enum.PartType.Cylinder })
	end
	SK.fireStart(site, id, body.CFrame * CF(0, 1.4, -2))
end

function Build.reststop(ctx: any, site: Model, F: CFrame, maxW: number, maxD: number)
	local rng: Random = ctx.rng
	local w, d = math.min(maxW, 100), math.min(maxD, 60)
	SK.part(site, "LayBy", F * CF(0, GY + 0.03, d * 0.4), V(w, 0.1, d * 0.8), C.Asphalt)
	for k = 0, 3 do
		SK.part(site, "BayLine", F * CF(10 + k * 12, GY + 0.1, d * 0.3), V(0.4, 0.05, d * 0.5), C.LineWhite, { collide = false })
	end
	-- sign at the entrance
	SK.part(site, "SignPost", F * CF(-4, GY + 4, 1.5), V(0.6, 8, 0.6), C.MetalDark)
	local board = SK.part(site, "RestStopSign", F * CF(-4, GY + 8.5, 1.5), V(16, 3.4, 0.4), Color3.fromHex("#2E6B3F"))
	SK.sign(board, "HWY 67 REST STOP · SCENIC VIEW · DRIVE SAFE (PLEASE)", Enum.NormalId.Front, C.Trim)
	-- west half: what burns
	burnCar(site, F * CF(-w * 0.4, GY, d * 0.25) * ANG(0, math.rad(15), 0), pick(rng, C.Awnings), "F1")
	burnCar(site, F * CF(-w * 0.24, GY, d * 0.3) * ANG(0, math.rad(-20), 0), pick(rng, C.Walls), "F2")
	for k, x in { -w * 0.38, -w * 0.2 } do
		local tf = F * CF(x, GY, d * 0.72)
		local top = box(site, "PicnicTable", tf * CF(0, 2.4, 0), V(7, 0.5, 3), C.Wood, true)
		box(site, "PicnicBench", tf * CF(0, 1.3, -2.6), V(7, 0.4, 1.2), C.Wood, true)
		box(site, "PicnicBench", tf * CF(0, 1.3, 2.6), V(7, 0.4, 1.2), C.Wood, true)
		SK.fireStart(site, `F{2 + k}`, top.CFrame * CF(0, 1, 0))
	end
	local hut = box(site, "Restrooms", F * CF(-w * 0.44, GY, d * 0.92 - 5), V(10, 9, 8), Color3.fromHex("#C9B79C"), true)
	SK.wedge(site, "RestroomRoof", hut.CFrame * CF(0, 5.2, 0), V(11, 1.6, 9), C.RoofBrown)
	SK.fireStart(site, "F5", hut.CFrame * CF(0, 0, -4.5))
	BlockFiller.trashCan(site, F * CF(-w * 0.1, GY, d * 0.55))
	-- east half: the pile-up lane (drivers; the twist adds the wrecks)
	local n = 0
	for _, z in { d * 0.2, d * 0.55 } do
		for _, x in { w * 0.2, w * 0.36 } do
			n += 1
			SK.rescue(site, `R{n}`, "Civilian", F * CF(x, GY, z), "sitting", "Driver")
		end
	end
	-- the view the stop is named for
	SK.part(site, "Viewpoint", F * CF(w * 0.3, GY + 1.2, d * 0.95), V(24, 2.4, 1), C.Wood)
end

---------------------------------------------------------------------------------------------------
-- block assembly
---------------------------------------------------------------------------------------------------
local FACE_YAW = { N = 0, S = math.pi, E = -math.pi / 2, W = math.pi / 2 }

-- Lot frame: lot centre on the ground, -Z toward the lot's street (face N/S/E/W).
function BlockFiller.lotFrame(x: number, z: number, face: string): CFrame
	return CF(x, 0, z) * ANG(0, FACE_YAW[face] or 0, 0)
end

local function lotFrame(block: any, lot: any): CFrame
	return BlockFiller.lotFrame(block.x + lot.x, block.z + lot.z, lot.face)
end

-- Builds the incident site for one lot (apron, truck spot, arrival zone, hydrant, building).
function BlockFiller.buildSiteLot(ctx: any, parent: Instance, site: any, lf: CFrame, lot: any): Model
	local cfg = ctx.cfg
	local apron = cfg.ApronDepth
	local d = lot.d
	local front = lf * CF(0, 0, -d / 2 + apron + 3)
	local model = SK.newSite(parent, site, front)
	local aw = math.min(lot.w - 6, 48)
	SK.part(model, "Apron", lf * CF(0, GY + 0.02, -d / 2 + apron / 2), V(aw, 0.1, apron), C.Concrete)
	for k = -1, 1, 2 do
		SK.part(model, "ApronLine", lf * CF(k * 7, GY + 0.08, -d / 2 + apron / 2), V(0.4, 0.05, apron - 4), C.LineYellow, { collide = false })
	end
	local spot = lf * CF(0, GY, -d / 2 + apron / 2) * YAW90
	SK.truckSpot(model, spot)
	SK.arrival(model, lf * CF(0, GY, -d / 2 + apron / 2 - 4))
	hydrant(model, lf * CF(math.min(lot.w / 2 - 3, aw / 2 + 3), GY, -d / 2 + 3))
	local builder = Build[lot.kind]
	if builder then
		local ok, err = pcall(builder, ctx, model, front, lot.w - 8, d - apron - 8)
		if not ok then
			warn(`[BlockFiller] {lot.kind} {site.siteId} failed: {err}`)
		end
	end
	if ctx.onSite then
		ctx.onSite(model, site)
	end
	return model
end

local function scenery(ctx: any, parent: Instance, lot: any, lf: CFrame, whole: boolean)
	local fn = Scenery[lot.kind]
	if not fn then
		return
	end
	local setback = if lot.kind == "house" then 14 elseif lot.kind == "tower" then 8 else 4
	local F = lf * CF(0, 0, -lot.d / 2 + setback)
	local ok, err = pcall(fn, ctx, parent, F, lot.w - 6, lot.d - setback - (if whole then 4 else 6))
	if not ok then
		warn(`[BlockFiller] {lot.kind} failed: {err}`)
	end
end

-- One square block (a procedural core sub-block, or the whole zoo core): kerb ring + lots.
function BlockFiller.fillBlock(ctx: any, parent: Instance, block: any): Model
	local cfg = ctx.cfg
	local m = Instance.new("Model")
	m.Name = `Block_{block.id}`
	m:SetAttribute("Theme", block.theme)
	m:SetAttribute("District", block.district)
	-- curb cuts in front of every site apron
	local gaps = {}
	for _, lot in block.lots do
		if lot.site then
			table.insert(gaps, {
				side = lot.face,
				at = if lot.face == "N" or lot.face == "S" then lot.x else lot.z,
				w = math.min(lot.w - 6, 48),
				cut = "drive",
			})
		end
	end
	BlockFiller.base(m, cfg, block.x, block.z, block.size / 2, gaps, true)
	for _, lot in block.lots do
		local lf = lotFrame(block, lot)
		local site = ctx.siteFor(lot)
		if lot.site and site then
			BlockFiller.buildSiteLot(ctx, m, site, lf, lot)
		else
			scenery(ctx, m, lot, lf, lot.d > block.size / 2)
		end
	end
	m.Parent = parent
	return m
end

local BAND_GROUND = {
	suburb = { Color3.fromHex("#7FAF4A"), Enum.Material.Grass },
	downtown = { Color3.fromHex("#CFC6B8"), Enum.Material.SmoothPlastic },
	industrial = { Color3.fromHex("#9A968E"), Enum.Material.Concrete },
	farmland = { Color3.fromHex("#C9B66B"), Enum.Material.Ground },
	woods = { Color3.fromHex("#4F7A3A"), Enum.Material.Grass },
	park = { Color3.fromHex("#6FA84A"), Enum.Material.Grass },
}
BlockFiller.BandGround = BAND_GROUND

-- kerbside furniture per neighbourhood theme (BlockFiller.furnish opts)
local FURNISH = {
	downtown = { busStop = true, benches = true, canColor = Color3.fromHex("#3B3940") },
	suburb = { busStop = true, canColor = Color3.fromHex("#2F6B4F") },
	industrial = { canColor = Color3.fromHex("#3D5A80") },
	park = { benches = true, canColor = Color3.fromHex("#6B4A2F") },
	farmland = { canColor = Color3.fromHex("#8A4A35") },
	woods = { canColor = Color3.fromHex("#6B4A2F") },
}

-- The neighbourhood round one district's loop: themed ground, the loop's outer sidewalk (curb cuts at
-- site aprons, gaps at the gates) and every band lot. gateHalf: half width of the gate gaps.
function BlockFiller.fillBand(ctx: any, parent: Instance, d: any, lots: { any }, gateHalf: number): Model
	local cfg = ctx.cfg
	local m = Instance.new("Model")
	m.Name = `{d.id}_Band`
	local cx, cz = d.x, d.z
	local outer = cfg.LoopOffset + cfg.StreetWidth / 2 -- loop's outer edge
	local inner = outer + cfg.SidewalkWidth -- band ground starts here
	local H = cfg.DistrictHalf
	local look = BAND_GROUND[d.band] or BAND_GROUND.park
	local function slab(x0: number, z0: number, x1: number, z1: number, top: number, color: Color3, mat: Enum.Material?, name: string)
		if x1 - x0 < 0.1 or z1 - z0 < 0.1 then
			return
		end
		SK.part(m, name, CF(cx + (x0 + x1) / 2, (top - 0.1) / 2, cz + (z0 + z1) / 2), V(x1 - x0, top + 0.1, z1 - z0), color, { material = mat })
	end
	-- ground: N/S strips span the corners, W/E strips between them; split at the gates
	for _, sgn in { -1, 1 } do
		local z0, z1 = if sgn < 0 then -H else inner, if sgn < 0 then -inner else H
		slab(-H, z0, -gateHalf, z1, GY, look[1], look[2], "BandGround")
		slab(gateHalf, z0, H, z1, GY, look[1], look[2], "BandGround")
		local x0, x1 = if sgn < 0 then -H else inner, if sgn < 0 then -inner else H
		slab(x0, -inner, x1, -gateHalf, GY, look[1], look[2], "BandGround")
		slab(x0, gateHalf, x1, inner, GY, look[1], look[2], "BandGround")
	end
	-- sidewalk round the loop's outer edge with gaps: gates + curb cuts
	local cuts: { [string]: { any } } = { N = {}, S = {}, W = {}, E = {} }
	local sideOf = { S = "N", N = "S", E = "W", W = "E" } -- a lot facing S sits on the loop's north side
	for _, lot in lots do
		if lot.site then
			local side = sideOf[lot.face]
			local at = if side == "N" or side == "S" then lot.x - cx else lot.z - cz
			table.insert(cuts[side], { at = at, w = math.min(lot.w - 6, 48) })
		end
	end
	local sy, ry = cfg.SidewalkY, cfg.RoadY
	for side, list in cuts do
		table.insert(list, { at = 0, w = 2 * gateHalf, gate = true })
		table.sort(list, function(a, b)
			return a.at < b.at
		end)
		local horizontal = side == "N" or side == "S"
		local sgn = if side == "N" or side == "W" then -1 else 1
		local fixedA, fixedB = sgn * outer, sgn * inner
		local f0, f1 = math.min(fixedA, fixedB), math.max(fixedA, fixedB)
		local function seg(a: number, b: number, top: number, color: Color3, name: string)
			if horizontal then
				slab(a, f0, b, f1, top, color, nil, name)
			else
				slab(f0, a, f1, b, top, color, nil, name)
			end
		end
		local cursor = -inner
		for _, c in list do
			local a, b = c.at - c.w / 2, c.at + c.w / 2
			seg(cursor, a, sy, C.Sidewalk, "Sidewalk")
			if not c.gate then
				seg(a, b, ry + 0.15, C.Concrete, "CurbCut")
			end
			cursor = b
		end
		seg(cursor, inner, sy, C.Sidewalk, "Sidewalk")
	end
	-- kerbside furniture along the band's lot fronts (one mark per lot, off the curb cuts)
	local furn = FURNISH[d.band]
	if furn then
		local outward = { N = V(0, 0, -1), S = V(0, 0, 1), W = V(-1, 0, 0), E = V(1, 0, 0) }
		for side, list in cuts do
			local marks = {}
			for _, lot in lots do
				if sideOf[lot.face] == side then
					local at = if side == "N" or side == "S" then lot.x - cx else lot.z - cz
					table.insert(marks, at - lot.w / 2 + 3)
				end
			end
			table.sort(marks)
			local o = outward[side]
			BlockFiller.furnish(m, ctx.rng, function(t: number): CFrame
				local across = inner + 1.4
				local p = if side == "N" or side == "S" then V(cx + t, GY, cz + o.Z * across) else V(cx + o.X * across, GY, cz + t)
				return CFrame.lookAt(p, p - o)
			end, marks, function(t: number): boolean
				for _, c in list do
					if t > c.at - c.w / 2 - 3 and t < c.at + c.w / 2 + 3 then
						return true
					end
				end
				return false
			end, (function() local o = table.clone(furn); o.street = d.street; return o end)())
		end
	end
	for _, lot in lots do
		local lf = BlockFiller.lotFrame(lot.x, lot.z, lot.face)
		local site = ctx.siteFor(lot)
		if lot.site and site then
			BlockFiller.buildSiteLot(ctx, m, site, lf, lot)
		else
			scenery(ctx, m, lot, lf, false)
		end
	end
	m.Parent = parent
	return m
end

-- One avenue corridor run (Districts.corridors): themed ground, the avenue's sidewalk (curb cuts at
-- site aprons) and its frontage lots.
function BlockFiller.fillCorridor(ctx: any, parent: Instance, run: any): Model
	local cfg = ctx.cfg
	local m = Instance.new("Model")
	m.Name = `Corridor_{run.district}`
	m:SetAttribute("Street", run.street)
	local look = BAND_GROUND[run.theme] or BAND_GROUND.park
	local s = run.side
	local sw = cfg.SidewalkWidth
	local front = run.near + s * sw
	local function slab(a0: number, a1: number, c0: number, c1: number, top: number, color: Color3, mat: Enum.Material?, name: string)
		if a1 - a0 < 0.1 or math.abs(c1 - c0) < 0.1 then
			return
		end
		local ac, cc = (a0 + a1) / 2, (c0 + c1) / 2
		local la, lc = a1 - a0, math.abs(c1 - c0)
		local cf = if run.axis == "x" then CF(cc, (top - 0.1) / 2, ac) else CF(ac, (top - 0.1) / 2, cc)
		local size = if run.axis == "x" then V(lc, top + 0.1, la) else V(la, top + 0.1, lc)
		SK.part(m, name, cf, size, color, { material = mat })
	end
	slab(run.a0, run.a1, front, run.far, GY, look[1], look[2], "CorridorGround")
	-- sidewalk along the avenue, cut at every site apron
	local cuts = {}
	for _, lot in run.lots do
		if lot.site then
			local at = if run.axis == "x" then lot.z else lot.x
			table.insert(cuts, { a = at - math.min(lot.w - 6, 48) / 2, b = at + math.min(lot.w - 6, 48) / 2 })
		end
	end
	table.sort(cuts, function(x, y)
		return x.a < y.a
	end)
	local cursor = run.a0
	for _, c in cuts do
		slab(cursor, c.a, run.near, front, cfg.SidewalkY, C.Sidewalk, nil, "Sidewalk")
		slab(c.a, c.b, run.near, front, cfg.RoadY + 0.15, C.Concrete, nil, "CurbCut")
		cursor = c.b
	end
	slab(cursor, run.a1, run.near, front, cfg.SidewalkY, C.Sidewalk, nil, "Sidewalk")
	-- highway service stop: a tall "67 SERVICES" pylon by the entrance, readable from the highway
	if run.highway then
		local at = run.a0 + 6
		local c = front + s * 4
		local p = if run.axis == "x" then V(c, 0, at) else V(at, 0, c)
		local toRoad = if run.axis == "x" then V(-s, 0, 0) else V(0, 0, -s)
		local cf = CFrame.lookAt(p, p + toRoad)
		SK.part(m, "PylonPole", cf * CF(0, GY + 10, 0), V(1.2, 20, 1.2), C.MetalDark)
		local board = SK.part(m, "Pylon", cf * CF(0, GY + 22, 0), V(10, 6, 1), C.Red)
		SK.sign(board, "67 SERVICES", Enum.NormalId.Front, C.Trim)
		SK.sign(board, "67 SERVICES", Enum.NormalId.Back, C.Trim)
	end
	-- kerbside furniture just inside the lot fronts (one mark per lot, off the aprons)
	local marks = {}
	for _, lot in run.lots do
		local at = if run.axis == "x" then lot.z else lot.x
		table.insert(marks, at - lot.w / 2 + 3)
	end
	table.sort(marks)
	local toRoad = -s
	BlockFiller.furnish(m, ctx.rng, function(t: number): CFrame
		local c = front + s * 1.4
		local p = if run.axis == "x" then V(c, GY, t) else V(t, GY, c)
		local look = if run.axis == "x" then V(toRoad, 0, 0) else V(0, 0, toRoad)
		return CFrame.lookAt(p, p + look)
	end, marks, function(t: number): boolean
		for _, c in cuts do
			if t > c.a - 3 and t < c.b + 3 then
				return true
			end
		end
		return false
	end, (function() local o = table.clone(FURNISH[run.theme] or {}); o.street = run.street; return o end)())
	for _, lot in run.lots do
		local lf = BlockFiller.lotFrame(lot.x, lot.z, lot.face)
		local site = ctx.siteFor(lot)
		if lot.site and site then
			BlockFiller.buildSiteLot(ctx, m, site, lf, lot)
		else
			scenery(ctx, m, lot, lf, false)
		end
	end
	m.Parent = parent
	return m
end

return BlockFiller
