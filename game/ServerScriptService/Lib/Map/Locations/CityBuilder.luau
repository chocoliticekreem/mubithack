--!strict
-- CityBuilder [owner: CityBuilder]. THE v2 CITY, "Blazeville" (docs/game/08 "City"). Id "City", Slot 0.
-- ~3000 x 3000 studs centred on the world origin (+Z = south, NORTH = -Z; CityConfig.Bounds). The fire
-- station hub sits in the middle; 8 neighbourhoods sit apart in a 3 x 3 grid of cells joined by
-- Highway 67 (outer ring), an avenue ring road, 4-lane avenues radiating from the hub, and gate
-- streets into every neighbourhood (plan: Lib/Map/City/Districts.luau). Each neighbourhood: its v1
-- location builder (Town = Maple Street, Farm, Forest, and School / Storage / Apartment / Zoo / Dam
-- once they ship) called as XBuilder.Build(model, origin, rng) at its centre, or a procedural core;
-- a loop street; a themed band of lots round it (suburb, downtown, farmland, woods, industrial, park);
-- a welcome arch, a landmark visible from afar, and its own road style (asphalt / concrete / dirt /
-- cobble). Mill Creek runs from the dam down the east greenbelt under bridges. Signposts at the
-- junctions point to every neighbourhood. StationBuilder builds itself at CityConfig.StationOrigin.
--
-- Every building that can host a mission is an IncidentSite Model (SiteKit.newSite): attrs SiteId,
-- MissionTypes, Busy, DisplayName, SiteKind, District, RoadNode; children FireStart / RescueSpawn
-- markers, TruckSpot, ArrivalZone. Location-builder districts are one site each (the whole location
-- Model, which also keeps LocationId = <builder id>, so MapService:GetLocation("Town") still works).
--
-- Public (module state, valid after Build):
--   CityBuilder.Graph : { nodes = { [id] = Vector3 }, edges = { { a, b, kind, style, width, speedLimit,
--       laneCount, length, lanes } } } (edges[i][1] / [2] = a / b too). JSON copy (format in
--       Lib/Map/City/RoadGraph.luau): Workspace.Map.City.RoadGraphJson. Folder City.RoadGraph: RoadNode
--       parts (attr NodeId) + RoadEdge ObjectValues (attrs A, B, Kind, Style, Width, SpeedLimit, Lanes;
--       Value = node A part, child ObjectValue "B" = node B part).
--   CityBuilder.Plan (Districts.planCity result), CityBuilder.Sites : { [siteId]: Model } (as built;
--   MapService:GetSite / BindSite / RebuildSite own the live sites after that)
-- The city lays its own ground (with the creek carved out), so at run time it hides the place's
-- Workspace.Baseplate (Transparency 1, CanCollide false).
-- Writes on the City model: attrs PartCount, SiteCount, Parts_<section>, TrafficPhase ("XGreen" | "XAmber"
--   | "ZGreen" | "ZAmber"; X = traffic driving along X), TrafficPhaseEndsAt (server time). Each district
--   Folder: attrs DistrictId, DisplayName, Center (Vector3), Half. Counters city_parts, city_sites.
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local CityConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("CityConfig") :: ModuleScript) :: any
local MissionCatalog = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MissionCatalog") :: ModuleScript) :: any
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local CityDir = script.Parent.Parent:WaitForChild("City")
local RoadGraph = require(CityDir:WaitForChild("RoadGraph") :: ModuleScript) :: any
local Districts = require(CityDir:WaitForChild("Districts") :: ModuleScript) :: any
local SK = require(CityDir:WaitForChild("SiteKit") :: ModuleScript) :: any
local BlockFiller = require(CityDir:WaitForChild("BlockFiller") :: ModuleScript) :: any
local Greenbelt = require(CityDir:WaitForChild("Greenbelt") :: ModuleScript) :: any
local Highway = require(CityDir:WaitForChild("Highway") :: ModuleScript) :: any

local CityBuilder = {}
CityBuilder.Id = "City"
CityBuilder.Slot = 0
CityBuilder.Enabled = CityConfig.Enabled
CityBuilder.Graph = nil :: any
CityBuilder.Plan = nil :: any
CityBuilder.Sites = {} :: { [string]: Model }

local C = SK.C
local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local GY = 0.72


local SHORT = {
	Farm = "Sunny Acres Farm",
	Town = "Maple Street",
	Dam = "Mill Creek Dam",
	Storage = "Industrial Park",
	Station = "Fire Station 67",
	Forest = "Pine Ridge Forest",
	School = "School Campus",
	Apartment = "Downtown Heights",
	Zoo = "City Zoo",
}

local STYLE = {
	asphalt = { C.Asphalt, Enum.Material.SmoothPlastic, true },
	concrete = { Color3.fromHex("#8F8B84"), Enum.Material.Concrete, true },
	dirt = { Color3.fromHex("#8A6A45"), Enum.Material.Ground, false },
	cobble = { Color3.fromHex("#8C7F72"), Enum.Material.Cobblestone, false },
}

local function count(name: string, n: number)
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count(name, n)
	end)
end

local function partCount(root: Instance): number
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

local function findBuilders(): { [string]: any }
	local out = {}
	for _, id in CityConfig.ReplacedLocations do
		local mod = script.Parent:FindFirstChild(`{id}Builder`)
		if mod and mod:IsA("ModuleScript") then
			local ok, b = pcall(require, mod)
			if ok and type(b) == "table" and type(b.Build) == "function" then
				out[id] = b
			else
				warn(`[CityBuilder] {id}Builder unusable: {b}`)
			end
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------
-- context
---------------------------------------------------------------------------------------------------
type LampSet = { red: { BasePart }, amber: { BasePart }, green: { BasePart } }
type Ctx = {
	model: Model,
	plan: any,
	rng: Random,
	keepClear: { Vector3 },
	blocked: { any }, -- ground rects covered by set pieces (the tunnel hill): no lamps / trees
	lamps: { X: LampSet, Z: LampSet },
}

local LAMP_ON = {
	red = Color3.fromHex("#FF3B30"),
	amber = Color3.fromHex("#FFB020"),
	green = Color3.fromHex("#34D058"),
}
local LAMP_OFF = Color3.fromHex("#2B2B30")

local function inRiver(plan: any, p: Vector3, pad: number): boolean
	for _, r in plan.river do
		if p.X > r.x0 - pad and p.X < r.x1 + pad and p.Z > r.z0 - pad and p.Z < r.z1 + pad then
			return true
		end
	end
	return false
end

local function insideDistrict(plan: any, p: Vector3, pad: number): boolean
	local h = CityConfig.DistrictHalf + pad
	for _, d in plan.districts do
		if math.abs(p.X - d.x) < h and math.abs(p.Z - d.z) < h then
			return true
		end
	end
	return false
end

local function clear(ctx: Ctx, p: Vector3, r: number): boolean
	for _, k in ctx.keepClear do
		if (k - p).Magnitude < r then
			return false
		end
	end
	for _, b in ctx.blocked do
		if p.X > b.x0 and p.X < b.x1 and p.Z > b.z0 - 4 and p.Z < b.z1 + 4 then
			return false
		end
	end
	return not inRiver(ctx.plan, p, 6)
end

---------------------------------------------------------------------------------------------------
-- ground + creek + bridges
---------------------------------------------------------------------------------------------------
local function buildGround(ctx: Ctx, parent: Instance)
	local cfg = CityConfig
	local b = cfg.Bounds
	local m = Instance.new("Model")
	m.Name = "Ground"
	local top = cfg.GroundY
	local thick = cfg.RiverDepth + 4
	local pieces = Districts.subtractRects({ x0 = b.minX - 60, z0 = b.minZ - 60, x1 = b.maxX + 60, z1 = b.maxZ + 60 }, ctx.plan.river)
	for _, p in pieces do
		-- parts are capped at 2048 studs a side: tile
		local nx = math.ceil((p.x1 - p.x0) / 2000)
		local nz = math.ceil((p.z1 - p.z0) / 2000)
		for i = 0, nx - 1 do
			for k = 0, nz - 1 do
				local x0 = p.x0 + i * (p.x1 - p.x0) / nx
				local x1 = p.x0 + (i + 1) * (p.x1 - p.x0) / nx
				local z0 = p.z0 + k * (p.z1 - p.z0) / nz
				local z1 = p.z0 + (k + 1) * (p.z1 - p.z0) / nz
				SK.part(m, "Grass", CF((x0 + x1) / 2, top - thick / 2, (z0 + z1) / 2), V(x1 - x0, thick, z1 - z0), C.Grass, {
					material = Enum.Material.Grass,
				})
			end
		end
	end
	-- Mill Creek: muddy bed + water surface
	for i, r in ctx.plan.river do
		local nx = math.ceil((r.x1 - r.x0) / 2000)
		local nz = math.ceil((r.z1 - r.z0) / 2000)
		for a = 0, nx - 1 do
			for k = 0, nz - 1 do
				local x0 = r.x0 + a * (r.x1 - r.x0) / nx
				local x1 = r.x0 + (a + 1) * (r.x1 - r.x0) / nx
				local z0 = r.z0 + k * (r.z1 - r.z0) / nz
				local z1 = r.z0 + (k + 1) * (r.z1 - r.z0) / nz
				local cx, cz, sx, sz = (x0 + x1) / 2, (z0 + z1) / 2, x1 - x0, z1 - z0
				SK.part(m, "CreekBed", CF(cx, top - cfg.RiverDepth - 1, cz), V(sx, 2, sz), Color3.fromHex("#5C4A36"), { material = Enum.Material.Mud })
				local water = SK.part(m, `Creek{i}`, CF(cx, top - 2.2, cz), V(sx, 0.4, sz), C.Water, {
					material = Enum.Material.Glass,
					transparency = 0.3,
					collide = false,
					cast = false,
					tags = { Names.Tag.Hydrant },
				})
				water:SetAttribute("HydrantId", `Creek{i}_{a}{k}`)
				water:SetAttribute("Creek", true)
			end
		end
	end
	m.Parent = parent
end

local function buildBridges(ctx: Ctx, parent: Instance)
	local ry = CityConfig.RoadY
	for _, b in ctx.plan.bridges do
		local cx, cz = (b.x0 + b.x1) / 2, (b.z0 + b.z1) / 2
		local sx, sz = b.x1 - b.x0, b.z1 - b.z0
		local m = Instance.new("Model")
		m.Name = "Bridge"
		-- deck under the road + railings along the edges (the road part spans the gap)
		SK.part(m, "Deck", CF(cx, ry - 1.5, cz), V(sx + (if b.alongX then 6 else 0), 2.6, sz + (if b.alongX then 0 else 6)), Color3.fromHex("#9A958C"))
		for _, s in { -1, 1 } do
			if b.alongX then
				SK.part(m, "Railing", CF(cx, ry + 1.6, cz + s * (sz / 2 + 0.5)), V(sx + 8, 0.6, 0.6), C.Red)
				SK.part(m, "Kerb", CF(cx, ry + 0.6, cz + s * (sz / 2 + 0.5)), V(sx + 8, 1.2, 1), C.Concrete)
			else
				SK.part(m, "Railing", CF(cx + s * (sx / 2 + 0.5), ry + 1.6, cz), V(0.6, 0.6, sz + 8), C.Red)
				SK.part(m, "Kerb", CF(cx + s * (sx / 2 + 0.5), ry + 0.6, cz), V(1, 1.2, sz + 8), C.Concrete)
			end
			-- glowing newel posts on the four railing ends (neon, no PointLight)
			for _, e in { -1, 1 } do
				local px = if b.alongX then cx + e * (sx / 2 + 4) else cx + s * (sx / 2 + 0.5)
				local pz = if b.alongX then cz + s * (sz / 2 + 0.5) else cz + e * (sz / 2 + 4)
				SK.part(m, "NewelPost", CF(px, ry + 1.5, pz), V(1.2, 3, 1.2), C.Concrete)
				SK.ball(m, "NewelLamp", CF(px, ry + 3.5, pz), 1.4, Color3.fromHex("#FFE2A8"), { neon = true, collide = false, cast = false })
			end
		end
		m.Parent = parent
	end
end

---------------------------------------------------------------------------------------------------
-- roads
---------------------------------------------------------------------------------------------------
-- Lamp light budget: only every CityConfig.LampLightEvery-th lamp carries a (wider) PointLight; the
-- rest just glow (neon head). Keeps the city to ~100 street PointLights instead of ~300.
local lampCounter = 0

local function streetLamp(parent: Instance, cf: CFrame)
	-- cf: base on the ground, -Z = toward the road
	local m = Instance.new("Model")
	m.Name = "StreetLamp"
	SK.cyl(m, "Pole", cf * CF(0, 9, 0), 18, 0.7, C.MetalDark)
	SK.part(m, "Arm", cf * CF(0, 17.8, -2), V(0.4, 0.4, 4.4), C.MetalDark)
	local head = SK.part(m, "Head", cf * CF(0, 17.4, -4), V(1.6, 0.6, 2.4), Color3.fromHex("#FFE2A8"), { neon = true, collide = false, cast = false })
	lampCounter += 1
	local every = CityConfig.LampLightEvery or 1
	if lampCounter % every == 0 then
		local light = Instance.new("PointLight")
		light.Color = Color3.fromHex("#FFC97A")
		light.Range = math.min(60, 34 + 8 * (every - 1))
		light.Brightness = 1.4
		light.Shadows = false
		light.Parent = head
	end
	m.Parent = parent
end

local function drawEdge(ctx: Ctx, parent: Instance, g: any, e: any, idx: number)
	local info = e.info
	if not info.drawn then
		return
	end
	local a, b = g.nodes[e.a], g.nodes[e.b]
	local pa, pb = V(a.x, 0, a.z), V(b.x, 0, b.z)
	local dvec = pb - pa
	local len = dvec.Magnitude
	if len < 1 then
		return
	end
	local dir = dvec.Unit
	local alongX = math.abs(dir.X) > math.abs(dir.Z)
	local ta = if alongX then a.halfX else a.halfZ
	local tb = if alongX then b.halfX else b.halfZ
	local L = len - ta - tb
	if L <= 0.5 then
		return
	end
	local ry = CityConfig.RoadY
	local style = STYLE[info.style] or STYLE.asphalt
	local mid = pa + dir * (ta + L / 2)
	local rot = CFrame.lookAt(Vector3.zero, dir)
	local cf = CF(mid.X, 0, mid.Z) * rot
	local w = info.width
	SK.part(parent, "Road", cf * CF(0, (ry - 0.1) / 2, 0), V(w, ry + 0.1, L), style[1], { material = style[2] })
	if style[3] then
		local ly = ry + 0.03
		local function line(off: number, color: Color3, width: number?)
			SK.part(parent, "Line", cf * CF(off, ly, 0), V(width or 0.4, 0.06, L - 1), color, { collide = false, cast = false, query = false })
		end
		if info.kind == "avenue" or info.kind == "highway" then
			line(-0.45, C.LineYellow)
			line(0.45, C.LineYellow)
			line(-12, C.LineWhite, 0.3)
			line(12, C.LineWhite, 0.3)
			if info.kind == "highway" then
				line(-w / 2 + 1, C.LineWhite, 0.5)
				line(w / 2 - 1, C.LineWhite, 0.5)
			end
		else
			line(0, C.LineYellow)
		end
	end
	-- lamps (paved roads) and trees along the edges, alternating sides
	local right = V(-dir.Z, 0, dir.X)
	local rural = info.style == "dirt"
	local lampEvery = CityConfig.LampSpacing * (if info.kind == "highway" then 2 else 1)
	local k = 0
	local s = ta + 14
	while not rural and s < len - tb - 8 do
		local side = if (k + idx) % 2 == 0 then 1 else -1
		local p = pa + dir * s + right * side * (w / 2 + 1.6)
		if clear(ctx, p, 30) then
			streetLamp(parent, CFrame.lookAt(p, p - right * side))
		end
		k += 1
		s += lampEvery
	end
	k = 0
	local treeEvery = CityConfig.TreeSpacing * (if info.kind == "highway" then 2.5 elseif rural then 0.7 else 1)
	s = ta + 14 + treeEvery / 2
	while s < len - tb - 10 do
		local side = if (k + idx) % 2 == 0 then -1 else 1
		local p = pa + dir * s + right * side * (w / 2 + 4.3)
		if clear(ctx, p, 28) then
			local y = if insideDistrict(ctx.plan, p, -2) then CityConfig.SidewalkY else CityConfig.GroundY
			if rural or info.style == "concrete" and not insideDistrict(ctx.plan, p, 0) then
				BlockFiller.pine(parent, CF(p.X, y, p.Z), ctx.rng, 1.1)
			else
				BlockFiller.tree(parent, CF(p.X, y, p.Z), ctx.rng, 1.1)
			end
		end
		k += 1
		s += treeEvery
	end
end

-- Traffic signal: pole on the corner, mast arm out over the lanes, head hanging from the arm with
-- its bottom ~14.5 studs up (trucks are 9.6 tall + light bar) so it clears traffic and reads from a
-- distance; a dark backplate frames the lamps.
local SIGNAL_ARM_Y = 20.6 -- mast arm height above the ground
local SIGNAL_HEAD_Y = 17.6 -- head centre (head is 6.4 tall: 14.4 .. 20.8)

local function signalPole(ctx: Ctx, parent: Instance, base: Vector3, armDir: Vector3, armLen: number, face: Vector3, axis: string)
	local m = Instance.new("Model")
	m.Name = "TrafficLight"
	local y0 = CityConfig.GroundY
	SK.cyl(m, "Pole", CF(base.X, y0 + (SIGNAL_ARM_Y + 1) / 2, base.Z), SIGNAL_ARM_Y + 1, 1, C.MetalDark)
	local armMid = base + armDir * (armLen / 2 + 0.5)
	SK.part(m, "Arm", CFrame.lookAt(V(armMid.X, y0 + SIGNAL_ARM_Y, armMid.Z), V(armMid.X, y0 + SIGNAL_ARM_Y, armMid.Z) + armDir), V(0.6, 0.6, armLen + 1), C.MetalDark)
	local hp = base + armDir * armLen
	local headCf = CFrame.lookAt(V(hp.X, y0 + SIGNAL_HEAD_Y, hp.Z), V(hp.X, y0 + SIGNAL_HEAD_Y, hp.Z) + face)
	SK.part(m, "Head", headCf, V(2.4, 6.4, 1.6), Color3.fromHex("#2F3A2F"))
	SK.part(m, "Backplate", headCf * CF(0, 0, 0.9), V(3.8, 7.6, 0.2), Color3.fromHex("#1C1F1C"), { collide = false, cast = false, query = false })
	local set = (ctx.lamps :: any)[axis]
	for i, col in { "red", "amber", "green" } do
		local lamp = SK.part(m, `Lamp_{col}`, headCf * CF(0, 2 - (i - 1) * 2, -0.85), V(1.6, 1.6, 0.3), LAMP_OFF, { collide = false, cast = false, query = false })
		table.insert(set[col], lamp)
	end
	m.Parent = parent
end

local function drawCrossing(ctx: Ctx, parent: Instance, g: any, id: string)
	local n = g.nodes[id]
	if n.halfX <= 0 or n.halfZ <= 0 then
		return
	end
	local ry = CityConfig.RoadY
	local dirs: { Vector3 } = {}
	local styleName, highway = "asphalt", false
	for other in g.adj[id] do
		local info = RoadGraph.edgeInfo(g, id, other)
		if info and info.drawn then
			local o = g.nodes[other]
			local d = V(o.x - n.x, 0, o.z - n.z)
			if d.Magnitude > 0.5 then
				table.insert(dirs, d.Unit)
			end
			styleName = info.style
			highway = highway or info.kind == "highway"
		end
	end
	local style = STYLE[styleName] or STYLE.asphalt
	SK.part(parent, "Crossing", CF(n.x, (ry - 0.1) / 2, n.z), V(2 * n.halfX, ry + 0.1, 2 * n.halfZ), style[1], { material = style[2] })
	if #dirs < 3 then
		return
	end
	-- crosswalks on every arm (not on the highway, not on dirt)
	if CityConfig.Crosswalks and style[3] and not highway and string.sub(id, 1, 1) ~= "G" then
		for _, d in dirs do
			local alongX = math.abs(d.X) > 0.5
			local half = if alongX then n.halfX else n.halfZ
			local width = if alongX then 2 * n.halfZ else 2 * n.halfX
			local right = V(-d.Z, 0, d.X)
			local c = V(n.x, 0, n.z) + d * (half + 4)
			local nStripes = math.max(2, math.floor(width / 9.5)) -- wide bold stripes (fewer parts)
			local pitch = width / nStripes
			for k = 0, nStripes - 1 do
				local p = c + right * (-width / 2 + pitch * (k + 0.5))
				SK.part(parent, "Zebra", CFrame.lookAt(V(p.X, ry + 0.03, p.Z), V(p.X, ry + 0.03, p.Z) + d), V(5, 0.06, 6), C.LineWhite, {
					collide = false,
					cast = false,
					query = false,
				})
			end
		end
	end
	-- traffic lights at the big junctions (between and in the middle of the districts)
	local c1 = string.sub(id, 1, 1)
	-- 4-way crossings only (between and in the middle of the districts)
	local major = #dirs >= 4 and (c1 == "G" or c1 == "J" or string.match(id, "_C$") ~= nil)
	if CityConfig.TrafficLights and major and style[3] then
		-- stop lines across the incoming lanes of every arm, just behind the crosswalk (right-hand
		-- traffic: the incoming half is on the left of the outward arm direction)
		for _, d in dirs do
			local alongX = math.abs(d.X) > 0.5
			local half = if alongX then n.halfX else n.halfZ
			local width = if alongX then 2 * n.halfZ else 2 * n.halfX
			local right = V(-d.Z, 0, d.X)
			local p = V(n.x, 0, n.z) + d * (half + 9) - right * (width / 4)
			SK.part(parent, "StopLine", CFrame.lookAt(V(p.X, ry + 0.03, p.Z), V(p.X, ry + 0.03, p.Z) + d), V(width / 2 - 1.5, 0.06, 1.2), C.LineWhite, {
				collide = false,
				cast = false,
				query = false,
			})
		end
		local inset = 5
		for _, s in { { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } } do
			local corner = V(n.x + s[1] * (n.halfX + inset), 0, n.z + s[2] * (n.halfZ + inset))
			if not inRiver(ctx.plan, corner, 2) then
				if s[1] * s[2] > 0 then
					signalPole(ctx, parent, corner, V(-s[1], 0, 0), inset + n.halfX * 0.5, V(0, 0, s[2]), "Z")
				else
					signalPole(ctx, parent, corner, V(0, 0, -s[2]), inset + n.halfZ * 0.5, V(s[1], 0, 0), "X")
				end
			end
		end
	end
end

local function signposts(ctx: Ctx, parent: Instance, g: any)
	for _, sp in ctx.plan.signposts do
		local n = g.nodes[sp.node]
		local base = V(sp.x + n.halfX + 7, 0, sp.z + n.halfZ + 7)
		if inRiver(ctx.plan, base, 4) then
			base = V(sp.x - n.halfX - 7, 0, sp.z - n.halfZ - 7)
		end
		local m = Instance.new("Model")
		m.Name = "Signpost"
		local y0 = CityConfig.GroundY
		-- blades can reach over the road edge: keep the whole stack above truck height (9.6 + light bar)
		local stack = 0
		for _, arm in sp.arms do
			stack += 1.3 * #arm.names + 0.4 + 0.6
		end
		local top = y0 + math.max(15, 12.5 + stack)
		SK.part(m, "Post", CF(base.X, (y0 + top + 1) / 2, base.Z), V(0.8, top + 1 - y0, 0.8), C.MetalDark)
		for i, arm in sp.arms do
			local names = {}
			for _, full in arm.names do
				for id, sign in pairs(ctx.plan.signNames) do
					if sign == full then
						table.insert(names, SHORT[id] or id)
					end
				end
			end
			local text = table.concat(names, "\n")
			local h = 1.3 * #names + 0.4
			local dir = V(arm.dx, 0, arm.dz)
			local y = top - (i - 1) * (h + 0.6) - h / 2
			local centre = base + dir * 6.4
			-- blade's X axis points along the arm, so the arrow on the Front face reads correctly
			local cf = CFrame.lookAt(V(centre.X, y, centre.Z), V(centre.X, y, centre.Z) + V(-dir.Z, 0, dir.X))
			local blade = SK.part(m, "Blade", cf, V(12, h, 0.3), Color3.fromHex("#2E7D4F"))
			SK.sign(blade, `{text}  >`, Enum.NormalId.Front, C.Trim)
			SK.sign(blade, `<  {text}`, Enum.NormalId.Back, C.Trim)
		end
		m.Parent = parent
	end
end

local function exportGraph(model: Model, g: any)
	local ry = CityConfig.RoadY
	local ex = RoadGraph.export(g, ry)
	local nodes: { [string]: Vector3 } = {}
	for id, p in g.nodes do
		nodes[id] = V(p.x, ry, p.z)
	end
	local edges = {}
	for _, e in ex.edges do
		local copy = table.clone(e)
		copy[1] = e.a
		copy[2] = e.b
		table.insert(edges, copy)
	end
	CityBuilder.Graph = { nodes = nodes, edges = edges }
	local json = Instance.new("StringValue")
	json.Name = "RoadGraphJson"
	json.Value = HttpService:JSONEncode(ex)
	json.Parent = model
	local folder = Instance.new("Folder")
	folder.Name = "RoadGraph"
	local parts: { [string]: BasePart } = {}
	for id, p in nodes do
		parts[id] = SK.marker(folder, "RoadNode", CF(p), V(2, 2, 2), nil, { NodeId = id })
	end
	for _, e in ex.edges do
		local ov = Instance.new("ObjectValue")
		ov.Name = "RoadEdge"
		ov.Value = parts[e.a]
		ov:SetAttribute("A", e.a)
		ov:SetAttribute("B", e.b)
		ov:SetAttribute("Kind", e.kind)
		ov:SetAttribute("Style", e.style)
		ov:SetAttribute("Width", e.width)
		ov:SetAttribute("SpeedLimit", e.speedLimit)
		ov:SetAttribute("Lanes", e.laneCount)
		local ob = Instance.new("ObjectValue")
		ob.Name = "B"
		ob.Value = parts[e.b]
		ob.Parent = ov
		ov.Parent = folder
	end
	folder.Parent = model
end

---------------------------------------------------------------------------------------------------
-- districts: arches, landmarks, cores
---------------------------------------------------------------------------------------------------
local function arch(parent: Instance, at: Vector3, along: Vector3, span: number, text: string, color: Color3)
	-- along = the road's direction through the arch
	local across = V(-along.Z, 0, along.X)
	local y0 = CityConfig.GroundY
	for _, s in { -1, 1 } do
		local p = at + across * s * (span / 2 + 2)
		SK.part(parent, "ArchPillar", CF(p.X, y0 + 11, p.Z), V(4, 22, 4), C.Trim)
		SK.part(parent, "ArchCap", CF(p.X, y0 + 22.6, p.Z), V(5, 1.2, 5), color)
	end
	local beam = SK.part(parent, "ArchSign", CFrame.lookAt(V(at.X, y0 + 19, at.Z), V(at.X, y0 + 19, at.Z) + along), V(span + 8, 5, 1.2), color)
	SK.sign(beam, text, Enum.NormalId.Front, C.Trim)
	SK.sign(beam, text, Enum.NormalId.Back, C.Trim)
	-- polish (all above the beam, so the clearance under it is unchanged): a neon trim line on top,
	-- a crown with the town crest, glowing lanterns on the pillar caps, coloured pillar feet
	local face = CFrame.lookAt(V(at.X, 0, at.Z), V(at.X, 0, at.Z) + along)
	SK.part(parent, "ArchTrim", face * CF(0, y0 + 21.75, 0), V(span + 8, 0.5, 1.4), C.Trim, { neon = true, collide = false, cast = false })
	SK.part(parent, "ArchCrown", face * CF(0, y0 + 23.5, 0), V(10, 3, 1), color)
	SK.ball(parent, "ArchCrest", face * CF(0, y0 + 25, 0), 4.4, C.Trim, { collide = false })
	for _, s in { -1, 1 } do
		local p = at + across * s * (span / 2 + 2)
		SK.ball(parent, "ArchLantern", CF(p.X, y0 + 24.4, p.Z), 2.2, Color3.fromHex("#FFE2A8"), { neon = true, collide = false, cast = false })
		SK.part(parent, "ArchFoot", CF(p.X, y0 + 1.5, p.Z), V(5, 3, 5), color)
	end
end

local function gateSign(parent: Instance, at: Vector3, along: Vector3, text: string, color: Color3)
	local y0 = CityConfig.GroundY
	SK.part(parent, "SignPost", CF(at.X, y0 + 7, at.Z), V(0.8, 14, 0.8), C.Wood)
	local board = SK.part(parent, "Sign", CFrame.lookAt(V(at.X, y0 + 12.5, at.Z), V(at.X, y0 + 12.5, at.Z) + along), V(14, 4, 0.5), color)
	SK.sign(board, text, Enum.NormalId.Front, C.Trim)
	SK.sign(board, text, Enum.NormalId.Back, C.Trim)
end

local LANDMARK_COLOR = {
	Farm = Color3.fromHex("#C8232B"),
	Town = Color3.fromHex("#2A9D8F"),
	Dam = Color3.fromHex("#3D5A80"),
	Storage = Color3.fromHex("#6D6875"),
	Station = Color3.fromHex("#C8232B"),
	Forest = Color3.fromHex("#2F5D34"),
	School = Color3.fromHex("#E9C46A"),
	Apartment = Color3.fromHex("#6A4C93"),
	Zoo = Color3.fromHex("#E76F51"),
}

-- top of each landmark silhouette (studs above the ground) for its beacon + floating name
local LANDMARK_TOP = {
	watertower = 65,
	smokestacks = 91,
	silo = 69,
	hosetower = 71.5, -- its own red beacon sits at 74; ours overlaps it (adds the floating name)
	lookout = 72,
	belltower = 68,
	skyscraper = 222,
	ferriswheel = 64,
	dam = 60,
}

-- A tall silhouette in the band corner nearest the hub.
local function landmark(ctx: Ctx, parent: Instance, d: any)
	local h = CityConfig.DistrictHalf - 36
	local sx = if d.x > 0 then -1 elseif d.x < 0 then 1 else 1
	local sz = if d.z > 0 then -1 elseif d.z < 0 then 1 else -1
	if d.id == "Station" then
		sx, sz = 1, -1
	end
	local cf = CF(d.x + sx * h, GY, d.z + sz * h)
	local col = LANDMARK_COLOR[d.id] or C.Red
	local m = Instance.new("Model")
	m.Name = `Landmark_{d.landmark}`
	local kind = d.landmark
	if kind == "watertower" then
		for _, s in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			SK.part(m, "Leg", cf * CF(s[1] * 7, 22, s[2] * 7), V(1.4, 44, 1.4), C.MetalDark)
		end
		local tank = SK.cyl(m, "Tank", cf * CF(0, 52, 0), 18, 26, col)
		SK.cyl(m, "TankTop", cf * CF(0, 63, 0), 4, 18, col)
		local label = SK.part(m, "Label", cf * CF(0, 52, -12.9), V(18, 6, 0.3), col)
		SK.sign(label, "MAPLE ST", Enum.NormalId.Front, C.Trim)
		local _ = tank
	elseif kind == "smokestacks" then
		for k = -1, 1, 2 do
			SK.cyl(m, "Stack", cf * CF(k * 12, 45, 0), 90, 10, Color3.fromHex("#8A4A35"))
			SK.cyl(m, "StackBand", cf * CF(k * 12, 82, 0), 4, 10.4, C.Trim)
			local top = SK.part(m, "StackTop", cf * CF(k * 12, 90.5, 0), V(2, 1, 2), C.MetalDark, { transparency = 1, collide = false })
			local smoke = Instance.new("Smoke")
			smoke.Color = Color3.fromHex("#B8B2AA")
			smoke.Opacity = 0.25
			smoke.RiseVelocity = 6
			smoke.Size = 6
			smoke.Parent = top
		end
	elseif kind == "silo" then
		SK.cyl(m, "Silo", cf * CF(0, 30, 0), 60, 18, Color3.fromHex("#B7B1A8"))
		SK.ball(m, "Dome", cf * CF(0, 60, 0), 18, col)
		SK.part(m, "Windmill", cf * CF(22, 25, 0), V(3, 50, 3), C.Wood)
		for k = 0, 3 do
			SK.part(m, "Blade", cf * CF(22, 50, -2) * ANG(0, 0, math.rad(45 + k * 90)) * CF(0, 9, 0), V(3, 18, 0.4), C.Trim)
		end
	elseif kind == "hosetower" then
		SK.part(m, "Tower", cf * CF(0, 35, 0), V(14, 70, 14), Color3.fromHex("#A8322A"))
		SK.part(m, "Cap", cf * CF(0, 71, 0), V(17, 2, 17), C.Trim)
		local beacon = SK.ball(m, "Beacon", cf * CF(0, 74, 0), 4, C.Red, { neon = true })
		local light = Instance.new("PointLight")
		light.Color = C.Red
		light.Range = 40
		light.Parent = beacon
		local label = SK.part(m, "Label", cf * CF(0, 58, -7.2), V(12, 10, 0.3), C.Trim)
		SK.sign(label, "67", Enum.NormalId.Front, C.Red)
	elseif kind == "lookout" then
		for _, s in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
			SK.part(m, "Leg", cf * CF(s[1] * 5, 30, s[2] * 5), V(1.2, 60, 1.2), C.Wood)
		end
		SK.part(m, "Cabin", cf * CF(0, 64, 0), V(14, 8, 14), C.Wood)
		SK.wedge(m, "Roof1", cf * CF(0, 70, -3.5), V(16, 4, 7.5), C.RoofTerra)
		SK.wedge(m, "Roof2", cf * CF(0, 70, 3.5) * ANG(0, math.pi, 0), V(16, 4, 7.5), C.RoofTerra)
	elseif kind == "belltower" then
		SK.part(m, "Tower", cf * CF(0, 25, 0), V(12, 50, 12), Color3.fromHex("#C96F4A"))
		SK.part(m, "Belfry", cf * CF(0, 54, 0), V(13, 8, 13), C.Trim)
		SK.wedge(m, "Spire1", cf * CF(0, 63, -3.5), V(14, 10, 7.5), col)
		SK.wedge(m, "Spire2", cf * CF(0, 63, 3.5) * ANG(0, math.pi, 0), V(14, 10, 7.5), col)
	elseif kind == "skyscraper" then
		SK.part(m, "Tower", cf * CF(0, 90, 0), V(40, 180, 40), Color3.fromHex("#8E9AAF"))
		SK.part(m, "Glass", cf * CF(0, 92, -20.3), V(36, 170, 0.5), Color3.fromHex("#6FA8C8"), { material = Enum.Material.Glass })
		SK.part(m, "Crown", cf * CF(0, 184, 0), V(30, 8, 30), col)
		SK.cyl(m, "Spire", cf * CF(0, 205, 0), 34, 1.2, C.Trim)
	elseif kind == "dam" then
		-- the water-level gauge tower: a tall striped mast with a "HOW FULL IS IT?" board
		SK.part(m, "GaugeTower", cf * CF(0, 30, 0), V(8, 60, 8), Color3.fromHex("#A8A39A"), { material = Enum.Material.Concrete })
		for k = 1, 5 do
			SK.part(m, "GaugeBand", cf * CF(0, k * 10, -4.1), V(6, 1.2, 0.3), if k >= 4 then C.Red else C.Trim, { collide = false })
		end
		local board = SK.part(m, "GaugeBoard", cf * CF(0, 54, -4.3), V(12, 5, 0.4), col)
		SK.sign(board, "HOW FULL IS IT?", Enum.NormalId.Front, C.Trim)
	elseif kind == "ferriswheel" then
		local hub = cf * CF(0, 34, 0)
		SK.part(m, "Stand", hub * CF(-5, -17, 0) * ANG(0, 0, math.rad(-12)), V(2, 36, 2), C.Trim)
		SK.part(m, "Stand", hub * CF(5, -17, 0) * ANG(0, 0, math.rad(12)), V(2, 36, 2), C.Trim)
		for k = 0, 7 do
			local a = k * math.pi / 4
			SK.part(m, "Spoke", hub * ANG(a, 0, 0) * CF(0, 14, 0), V(0.8, 28, 0.8), C.Trim)
			local gp = hub * ANG(a, 0, 0) * CF(0, 28, 0)
			SK.part(m, "Gondola", CF(gp.Position) * CF(0, -2, 0), V(4, 4, 4), C.Awnings[(k % #C.Awnings) + 1])
		end
		SK.cyl(m, "Hub", hub * ANG(0, 0, math.rad(90)), 3, 4, col)
	end
	-- beacon + floating district name on top: find the neighbourhoods from anywhere in the city
	local top = LANDMARK_TOP[kind]
	if top then
		local beacon = SK.ball(m, "TopBeacon", cf * CF(0, top + 2.5, 0), 4, col, { neon = true, collide = false, cast = false })
		local bb = Instance.new("BillboardGui")
		bb.Name = "DistrictName"
		bb.Size = UDim2.new(48, 0, 9, 0) -- studs: shrinks with distance like the landmark itself
		bb.StudsOffset = V(0, 9, 0)
		bb.MaxDistance = 2600
		bb.LightInfluence = 0
		bb.AlwaysOnTop = false
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.TextScaled = true
		t.Font = Enum.Font.FredokaOne
		t.TextColor3 = C.Trim
		t.TextStrokeColor3 = col
		t.TextStrokeTransparency = 0
		t.Text = string.upper(SHORT[d.id] or d.id)
		t.Parent = bb
		bb.Parent = beacon
	end
	m.Parent = parent
end

local function districtSite(site: Model, info: any, truck: any?)
	CollectionService:AddTag(site, CityConfig.SiteTag)
	site:SetAttribute("SiteId", info.siteId)
	site:SetAttribute("MissionTypes", info.missionTypes)
	site:SetAttribute("Busy", false)
	site:SetAttribute("DisplayName", site:GetAttribute("DisplayName") or info.displayName)
	site:SetAttribute("SiteKind", "district")
	site:SetAttribute("District", info.district)
	site:SetAttribute("RoadNode", info.roadNode)
	site:SetAttribute(Names.Attr.LocationId, info.locationId)
	local spot: BasePart? = nil
	for _, d in site:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.TruckSpot) then
			spot = d
			break
		end
	end
	if not spot and truck then
		spot = SK.truckSpot(site, CF(truck.x, 0.3, truck.z) * ANG(0, math.rad(truck.yaw), 0))
	end
	if spot then
		spot:SetAttribute("SiteId", info.siteId)
		local p = spot.Position
		SK.arrival(site, CF(p.X, p.Y - 0.5, p.Z), V(48, 16, 48))
	end
end

-- Procedural dam core (until a DamBuilder ships): reservoir north, dam wall, a hamlet in the flood
-- path below it, the dam road up from the loop, Mill Creek leaving through the spillway.
local function buildDam(ctx: Ctx, parent: Instance, info: any): Model
	local rng = ctx.rng
	local o = CF(info.x, 0, info.z)
	local model = SK.newSite(parent, info, o)
	local wallZ = -70
	local sx = CityConfig.SpillwayOffset
	SK.part(model, "DamWall", o * CF((-200 + sx - 20) / 2, 22, wallZ), V(sx - 20 + 200, 44, 16), Color3.fromHex("#A8A39A"), { material = Enum.Material.Concrete })
	SK.part(model, "DamWallE", o * CF((sx + 20 + 200) / 2, 22, wallZ), V(200 - sx - 20, 44, 16), Color3.fromHex("#A8A39A"), { material = Enum.Material.Concrete })
	SK.part(model, "Spillway", o * CF(sx, 18, wallZ), V(40, 36, 16), Color3.fromHex("#9A958C"), { material = Enum.Material.Concrete })
	SK.part(model, "SpillWater", o * CF(sx, 20, wallZ + 8.4), V(38, 36, 0.6), C.Water, { material = Enum.Material.Glass, transparency = 0.2, collide = false })
	SK.part(model, "DamTop", o * CF(0, 44.6, wallZ), V(404, 1.2, 18), C.Concrete)
	for k = -3, 3 do
		if k ~= 1 then
			SK.part(model, "Buttress", o * CF(k * 55, 18, wallZ + 10), V(8, 36, 6), Color3.fromHex("#9A958C"))
		end
	end
	SK.part(model, "Reservoir", o * CF(0, 38, -140), V(400, 2, 120), C.Water, { material = Enum.Material.Glass, transparency = 0.25 })
	SK.part(model, "ReservoirBank", o * CF(0, 18, -140), V(400, 36, 120), Color3.fromHex("#6E8B4E"))
	local sign = SK.part(model, "DamSign", o * CF(-50, 30, wallZ + 8.2), V(70, 9, 0.4), Color3.fromHex("#3D5A80"))
	SK.sign(sign, "MILL CREEK DAM  (DO NOT EXPLODE)", Enum.NormalId.Back, C.Trim)
	for k = 1, 3 do
		local cs = SK.marker(model, `ChargeSpot{k}`, o * CF(-150 + k * 70, 8, wallZ + 9), V(4, 4, 2), nil, { ChargeSpot = k })
		cs.Transparency = 0.6
		cs.Color = C.Red
	end
	-- hamlet: wooden shacks in the flood path, west of the dam road (the creek runs east of it)
	local fires = 0
	local shacks = { { -150, -20 }, { -90, 30 }, { -40, 110 }, { -150, 120 }, { -80, 160 }, { -30, 175 } }
	for k, s in shacks do
		local sf = o * CF(s[1], 0, s[2]) * ANG(0, math.rad(rng:NextInteger(-20, 20)), 0)
		local col = Color3.fromHex(if k % 2 == 0 then "#9A6A40" else "#B5835A")
		SK.part(model, "ShackFloor", sf * CF(0, 0.3, 6), V(17, 0.6, 13), C.Wood)
		SK.wall(model, sf, V(-8, 0, 0), V(8, 0, 0), 0.6, 9, col, { { at = 8, w = 4, kind = "door" } }, info.siteId)
		SK.wall(model, sf, V(8, 0, 12), V(-8, 0, 12), 0.6, 9, col, { { at = 8, w = 4, kind = "window" } }, info.siteId)
		SK.wall(model, sf, V(-8, 0, 11.5), V(-8, 0, 0.5), 0.6, 9, col, {}, info.siteId)
		SK.wall(model, sf, V(8, 0, 0.5), V(8, 0, 11.5), 0.6, 9, col, {}, info.siteId)
		SK.part(model, "Roof", sf * CF(0, 10, 6), V(18, 0.8, 14), C.RoofTerra)
		local crate = SK.part(model, "Crates", sf * CF(4, 2, 8), V(4, 3, 4), C.Wood, { flammable = true, fuel = 25 })
		if fires < 4 then
			fires += 1
			SK.fireStart(model, `F{fires}`, crate.CFrame)
		end
		SK.rescue(model, `R{k}`, "Civilian", sf * CF(-3, 0.6, 6), if k % 3 == 0 then "lying" else "stand")
	end
	for _ = 1, 10 do
		BlockFiller.pine(model, o * CF(rng:NextNumber(-190, -20), GY - 0.7, rng:NextNumber(-40, 190)), rng)
	end
	local hg = SK.part(model, "HighGround", o * CF(-170, 6, 175), V(40, 12, 40), C.GrassDark)
	hg:SetAttribute("HighGround", true)
	local wave = SK.marker(model, "WaveVolume", o * CF(0, 15, 70), V(400, 30, 260), nil, nil)
	wave:SetAttribute("Direction", V(0, 0, 1))
	SK.truckSpot(model, CF(info.truck.x, CityConfig.RoadY, info.truck.z))
	SK.arrival(model, CF(info.truck.x, CityConfig.RoadY, info.truck.z), V(60, 20, 60))
	local h = MapKit.hydrant(model, CF(info.truck.x - 30, CityConfig.GroundY, info.truck.z))
	h:SetAttribute("HydrantId", "H_dam")
	return model
end

local function buildStationCore(ctx: Ctx, parent: Instance, d: any)
	-- the station and its grounds are StationBuilder's (lot local X -164..164, Z -164..68 round
	-- StationOrigin); lawn + trees on the rest of the hub core
	local so = CityConfig.StationOrigin.Position
	local h = CityConfig.CoreHalf
	local m = Instance.new("Model")
	m.Name = "HubGrounds"
	local back = so.Z - 164
	if back > d.z - h then
		SK.part(m, "Lawn", CF(d.x, -0.05, (d.z - h + back) / 2), V(2 * h, 0.2, back - (d.z - h)), C.Grass, { material = Enum.Material.Grass })
		for k = -3, 3 do
			BlockFiller.tree(m, CF(d.x + k * 50, 0.05, (d.z - h + back) / 2), ctx.rng, 1.2)
		end
		-- the station's drill tower out back: a 5-storey training tower with open window holes
		local tz = d.z - h + 30
		if tz < back - 10 then
			local t = CF(d.x - 120, 0, tz)
			SK.part(m, "DrillTower", t * CF(0, 24, 0), V(12, 48, 12), Color3.fromHex("#A8322A"))
			for k = 1, 4 do
				SK.part(m, "DrillWindow", t * CF(0, k * 10, -6.1), V(4, 5, 0.3), Color3.fromHex("#2B2B30"), { collide = false })
			end
			SK.part(m, "DrillRoof", t * CF(0, 48.6, 0), V(13.5, 1.2, 13.5), C.Trim)
			local sign = SK.part(m, "DrillSign", t * CF(0, 44, -6.2), V(10, 2.4, 0.3), C.Trim)
			SK.sign(sign, "DRILL TOWER", Enum.NormalId.Front, C.Red)
		end
	end
	for _, s in { -1, 1 } do
		local x0 = so.X + s * 164
		local x1 = d.x + s * h
		if math.abs(x1 - x0) > 2 then
			SK.part(m, "Lawn", CF((x0 + x1) / 2, -0.05, (back + d.z + h) / 2), V(math.abs(x1 - x0), 0.2, d.z + h - back), C.Grass, { material = Enum.Material.Grass })
		end
	end
	m.Parent = parent
end

---------------------------------------------------------------------------------------------------
-- traffic lights
---------------------------------------------------------------------------------------------------
local function setLamps(set: any, on: string)
	for _, col in { "red", "amber", "green" } do
		for _, lamp in set[col] do
			local lit = col == on
			lamp.Color = if lit then LAMP_ON[col] else LAMP_OFF
			lamp.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
		end
	end
end

local function runTraffic(model: Model, lamps: any)
	local phases = {
		{ name = "XGreen", x = "green", z = "red", long = true },
		{ name = "XAmber", x = "amber", z = "red", long = false },
		{ name = "ZGreen", x = "red", z = "green", long = true },
		{ name = "ZAmber", x = "red", z = "amber", long = false },
	}
	local function dur(p: any): number
		return if p.long then CityConfig.TrafficCycle else 1.5
	end
	local function apply(p: any)
		setLamps(lamps.X, p.x)
		setLamps(lamps.Z, p.z)
		model:SetAttribute("TrafficPhase", p.name)
		model:SetAttribute("TrafficPhaseEndsAt", workspace:GetServerTimeNow() + dur(p))
	end
	apply(phases[1])
	if not RunService:IsRunning() then
		return
	end
	task.spawn(function()
		local seen = false
		local i = 1
		while true do
			task.wait(dur(phases[i]))
			if model.Parent then
				seen = true
			elseif seen then
				return -- the city was destroyed / rebuilt
			end
			i = i % #phases + 1
			apply(phases[i])
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- build
---------------------------------------------------------------------------------------------------
-- the build takes several seconds: yield now and then on a live server so boot never hits
-- "Script timeout" (Edit-mode previews stay synchronous)
local lastYield = 0
local function breathe()
	if game:GetService("RunService"):IsRunning() and os.clock() - lastYield > 0.1 then
		task.wait()
		lastYield = os.clock()
	end
end

function CityBuilder.Build(model: Model, origin: CFrame, rng: Random)
	local t0 = os.clock()
	table.clear(CityBuilder.Sites)
	lampCounter = 0
	model:SetAttribute("DisplayName", "Blazeville")
	local cfg = CityConfig
	if origin.Position.Magnitude > 0.01 then
		warn("[CityBuilder] the city is laid out in world coordinates around (0, 0); origin ignored")
	end
	local builders = findBuilders()
	local available = {}
	for id in builders do
		available[id] = true
	end
	local seed = rng:NextInteger(1, 1000000)
	local plan = Districts.planCity(cfg, available, MissionCatalog, seed)
	plan.signNames = {}
	for _, d in plan.districts do
		plan.signNames[d.id] = d.sign
	end
	CityBuilder.Plan = plan
	local g = plan.graph
	local ctx: Ctx = {
		model = model,
		plan = plan,
		rng = rng,
		keepClear = {},
		blocked = Highway.blocked(cfg),
		lamps = { X = { red = {}, amber = {}, green = {} }, Z = { red = {}, amber = {}, green = {} } },
	}
	-- the station's front yard is the lobby (LobbyProps: START row, 3 squad pads, the mission board): no
	-- verge trees / lamps on it (one tree used to grow out of pad 1). Station-local X -112..-18, Z 26..60 (clear() pads it by 4: the sidewalk lamps stay).
	local so = CityConfig.StationOrigin
	if typeof(so) == "CFrame" then
		local a, b = so * V(-112, 0, 26), so * V(-18, 0, 60)
		table.insert(ctx.blocked, { x0 = math.min(a.X, b.X), z0 = math.min(a.Z, b.Z), x1 = math.max(a.X, b.X), z1 = math.max(a.Z, b.Z) })
	end
	-- keep lamps / trees out of curb cuts, gates and spur mouths
	for _, s in plan.sites do
		if s.lot and s.truck then
			table.insert(ctx.keepClear, V(s.truck.x, 0, s.truck.z))
		end
	end
	for id, p in g.nodes do
		if not string.match(id, "^G%d") then
			table.insert(ctx.keepClear, V(p.x, 0, p.z))
		end
	end
	-- highway service stops: no verge lamps/trees or outskirts fields on their lots
	for _, run in plan.corridors or {} do
		if run.highway then
			local c0, c1 = math.min(run.near, run.far), math.max(run.near, run.far)
			if run.axis == "x" then
				table.insert(ctx.blocked, { x0 = c0, z0 = run.a0, x1 = c1, z1 = run.a1 })
			else
				table.insert(ctx.blocked, { x0 = run.a0, z0 = c0, x1 = run.a1, z1 = c1 })
			end
		end
	end
	-- and off the exit gantry posts
	for _, sp in Highway.gantrySpots(cfg, plan.lines) do
		table.insert(ctx.keepClear, V(sp[1], 0, sp[2]))
	end
	local sections: { [string]: Instance } = {}

	lastYield = os.clock()
	buildGround(ctx, model)
	breathe()
	sections.Ground = model:FindFirstChild("Ground") :: Instance

	-- roads, crossings, bridges, signposts
	local roads = Instance.new("Model")
	roads.Name = "Roads"
	for idx, e in g.edges do
		drawEdge(ctx, roads, g, e, idx)
		breathe()
	end
	for id in g.nodes do
		drawCrossing(ctx, roads, g, id)
		breathe()
	end
	buildBridges(ctx, roads)
	signposts(ctx, roads, g)
	roads.Parent = model
	sections.Roads = roads

	breathe()
	-- the open ground between the neighbourhoods: Mill Pond, pocket parks, verges, outskirts fields
	local hok, hres = pcall(Highway.build, { cfg = cfg, plan = plan, rng = rng, streetNames = Districts.StreetNames }, model)
	if hok then
		sections.Highway = hres
	else
		warn(`[CityBuilder] highway failed: {hres}`)
	end
	local gok, gres = pcall(Greenbelt.build, {
		cfg = cfg,
		plan = plan,
		rng = Random.new(seed + 4242), -- its own stream: greenbelt tweaks never reshuffle the districts
		blocked = ctx.blocked,
		clear = function(p: Vector3, r: number): boolean
			return clear(ctx, p, r)
		end,
	}, model)
	breathe()
	if gok then
		sections.Greenbelt = gres
	else
		warn(`[CityBuilder] greenbelt failed: {gres}`)
	end

	-- sites lookup by lot
	local siteByLot: { [any]: any } = {}
	local siteById: { [string]: any } = {}
	for _, s in plan.sites do
		siteById[s.siteId] = s
		if s.lot then
			siteByLot[s.lot] = s
		end
	end
	local fillCtx = {
		cfg = cfg,
		rng = rng,
		siteFor = function(lot: any)
			return siteByLot[lot]
		end,
	}
	local bandByDistrict: { [string]: { any } } = {}
	for _, bl in plan.bandLots do
		bandByDistrict[bl.district] = bandByDistrict[bl.district] or {}
		table.insert(bandByDistrict[bl.district], bl.lot)
	end

	local districtsFolder = Instance.new("Folder")
	districtsFolder.Name = "Districts"
	for _, d in plan.districts do
		local folder = Instance.new("Folder")
		folder.Name = d.id
		folder:SetAttribute("DistrictId", d.id)
		folder:SetAttribute("DisplayName", SHORT[d.id] or d.id)
		folder:SetAttribute("Center", V(d.x, 0, d.z))
		folder:SetAttribute("Half", cfg.DistrictHalf)
		local col = LANDMARK_COLOR[d.id] or C.Red
		local gateHalf = (if d.id == "Station" then cfg.AvenueWidth else cfg.StreetWidth) / 2 + 6
		local ok, err = pcall(function()
			BlockFiller.fillBand(fillCtx, folder, d, bandByDistrict[d.id] or {}, gateHalf)
		end)
		if not ok then
			warn(`[CityBuilder] {d.id} band failed: {err}`)
		end
		-- avenue frontage between this neighbourhood and its avenues
		for _, run in plan.corridors or {} do
			if run.district == d.id then
				breathe()
				local cok, cerr = pcall(BlockFiller.fillCorridor, fillCtx, folder, run)
				if not cok then
					warn(`[CityBuilder] {d.id} corridor failed: {cerr}`)
				end
			end
		end
		-- core
		ok, err = pcall(function()
			if d.useBuilder then
				local loc = Instance.new("Model")
				loc.Name = d.builder
				loc:SetAttribute(Names.Attr.LocationId, d.builder)
				local bok, berr = pcall(builders[d.builder].Build, loc, CF(d.x, 0, d.z), Random.new(seed + MapKit.hash(d.builder)))
				if not bok then
					warn(`[CityBuilder] {d.builder}.Build failed: {berr}`)
				end
				if d.builder == "Farm" and not loc:FindFirstChild("TornadoField", true) then
					SK.marker(loc, "TornadoField", CF(d.x, 1, d.z - 83), V(300, 2, 94), nil, nil)
				end
				local info = siteById[d.builder]
				districtSite(loc, info, info.truck)
				loc.Parent = folder
			elseif d.core == "dam" then
				buildDam(ctx, folder, siteById.dam)
			elseif d.core == "station" then
				buildStationCore(ctx, folder, d)
			else
				for _, b in plan.blocks do
					if b.district == d.id then
						breathe()
						BlockFiller.fillBlock(fillCtx, folder, b)
					end
				end
			end
		end)
		if not ok then
			warn(`[CityBuilder] {d.id} core failed: {err}`)
		end
		-- welcome arch on the gate facing the hub, name boards on the others
		local scenery = Instance.new("Model")
		scenery.Name = `{d.id}_Gates`
		for _, gt in d.gates do
			local dir = Districts.FaceDir[gt.side]
			local at = V(d.x + dir[1] * (cfg.DistrictHalf + 12), 0, d.z + dir[2] * (cfg.DistrictHalf + 12))
			local along = V(dir[1], 0, dir[2])
			local facesHub = (string.sub(d.target, -2) == `_{gt.side}`) or d.id == "Station"
			if facesHub then
				arch(scenery, at, along, 2 * gateHalf, d.sign, col)
			else
				-- every other way in gets an arch too, with the neighbourhood's short name
				arch(scenery, at, along, 2 * gateHalf, string.upper(SHORT[d.id] or d.id), col)
			end
		end
		landmark(ctx, scenery, d)
		scenery.Parent = folder
		folder.Parent = districtsFolder
		breathe()
	end
	districtsFolder.Parent = model
	sections.Districts = districtsFolder

	exportGraph(model, g)

	local nSites = 0
	for _, d in model:GetDescendants() do
		if d:IsA("Model") and d:HasTag(cfg.SiteTag) then
			local id = d:GetAttribute("SiteId")
			if type(id) == "string" then
				CityBuilder.Sites[id] = d
				nSites += 1
			end
		end
	end
	-- the city lays its own ground (creek carved out): hide the place baseplate while playing
	if RunService:IsRunning() then
		local bp = workspace:FindFirstChild("Baseplate")
		if bp and bp:IsA("BasePart") then
			bp.Transparency = 1
			bp.CanCollide = false
			bp.CanQuery = false
			bp.CanTouch = false
		end
	end

	runTraffic(model, ctx.lamps)

	local total = partCount(model)
	model:SetAttribute("PartCount", total)
	model:SetAttribute("SiteCount", nSites)
	for name, inst in sections do
		model:SetAttribute(`Parts_{name}`, partCount(inst))
	end
	for _, d in districtsFolder:GetChildren() do
		model:SetAttribute(`Parts_{d.Name}`, partCount(d))
	end
	count("city_parts", total)
	count("city_sites", nSites)
	if total > cfg.PartBudget then
		warn(`[CityBuilder] {total} parts > budget {cfg.PartBudget}`)
	end
	print(`[CityBuilder] {nSites} incident sites, {total} parts in {math.floor((os.clock() - t0) * 1000)} ms`)
end

return CityBuilder
