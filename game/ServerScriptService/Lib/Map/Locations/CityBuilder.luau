--!strict
-- CityBuilder [owner: CityBuilder]. THE v2 CITY (docs/game/08 "City"). Id "City", Slot 0.
-- A 1616 x 1616 stud street grid centred on the world origin (+Z = south, NORTH = -Z): 6 x 6 blocks,
-- 4-lane avenues (perimeter + Main Ave x = 0 + Willow St z = 0) and 2-lane streets, rounded kerbs,
-- crosswalks, cycling traffic lights, street lamps, trees and street-name signs. Nine 2 x 2 districts
-- (Lib/Map/City/Districts.luau): a district whose location builder exists (Town = Maple Street,
-- Farm, Forest, and School / Storage / Apartment / Zoo / Dam when they ship) is built by calling
-- XBuilder.Build(model, origin, rng) at its centre; the rest are procedural filler blocks
-- (Lib/Map/City/BlockFiller.luau). The station strip north of the grid (z < -808) is left empty for
-- StationBuilder (CityConfig.StationOrigin); a 48-stud driveway joins it to Main Ave.
--
-- Every building that can host a mission is an IncidentSite Model (SiteKit.newSite): attrs SiteId,
-- MissionTypes, Busy, DisplayName, SiteKind, District, RoadNode; children FireStart / RescueSpawn
-- markers, TruckSpot, ArrivalZone. District sites (Town, Farm, Forest...) are the whole district Model
-- (it also carries LocationId = <builder id>, so MapService:GetLocation("Town") still works).
--
-- Public (module state, valid after Build):
--   CityBuilder.Graph : { nodes = { [id] = Vector3 }, edges = { { a, b, kind, width, speedLimit, laneCount, lanes } } }
--       (edges[i][1] / [2] are also set = a / b). JSON copy: Workspace.Map.City.RoadGraphJson (StringValue,
--       format in Lib/Map/City/RoadGraph.luau: nodes, pairs, edges[i].lanes). Folder City.RoadGraph holds
--       RoadNode parts (attr NodeId) and RoadEdge ObjectValues (attrs A, B, Kind, Width, Lanes, SpeedLimit;
--       Value = node A part, child ObjectValue "B" = node B part).
--   CityBuilder.Sites : { [siteId]: Model }   CityBuilder.Plan (Districts.planCity result)
--   CityBuilder.RebuildSite(siteId): Model?   -- swaps the site for a pristine copy (fires, chars, rescues gone)
--   CityBuilder.GetSite(siteId): Model?
-- Writes on the City model: attrs PartCount, SiteCount, Parts_<section>, TrafficPhase ("XGreen" | "XAmber" |
--   "ZGreen" | "ZAmber": X = traffic driving along X), TrafficPhaseEndsAt (server time). Counter city_parts.
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

type Registry = { model: Model, snapshot: Model, parent: Instance }
local registry: { [string]: Registry } = {}

local function count(name: string, n: number)
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count(name, n)
	end)
end

local function hash(s: string): number
	return MapKit.hash(s)
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

---------------------------------------------------------------------------------------------------
-- builders the city can reuse
---------------------------------------------------------------------------------------------------
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
-- roads
---------------------------------------------------------------------------------------------------
type Ctx = {
	model: Model,
	plan: any,
	rng: Random,
	keepClear: { Vector3 },
	lamps: { X: { red: { BasePart }, amber: { BasePart }, green: { BasePart } }, Z: { red: { BasePart }, amber: { BasePart }, green: { BasePart } } },
}

local LAMP_ON = {
	red = Color3.fromHex("#FF3B30"),
	amber = Color3.fromHex("#FFB020"),
	green = Color3.fromHex("#34D058"),
}
local LAMP_OFF = Color3.fromHex("#2B2B30")

local function clear(ctx: Ctx, p: Vector3, r: number): boolean
	for _, k in ctx.keepClear do
		if (k - p).Magnitude < r then
			return false
		end
	end
	return true
end

local function streetLamp(parent: Instance, cf: CFrame)
	-- cf: base on the ground, -Z = toward the road
	local m = Instance.new("Model")
	m.Name = "StreetLamp"
	SK.cyl(m, "Pole", cf * CF(0, 7.5, 0), 15, 0.7, C.MetalDark)
	SK.part(m, "Arm", cf * CF(0, 14.8, -2), V(0.4, 0.4, 4.4), C.MetalDark)
	local head = SK.part(m, "Head", cf * CF(0, 14.4, -4), V(1.6, 0.6, 2.4), Color3.fromHex("#FFE2A8"), { neon = true, collide = false, cast = false })
	local light = Instance.new("PointLight")
	light.Color = Color3.fromHex("#FFC97A")
	light.Range = 30
	light.Brightness = 1.3
	light.Shadows = false
	light.Parent = head
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
	local mid = pa + dir * (ta + L / 2)
	local rot = CFrame.lookAt(Vector3.zero, dir)
	local cf = CF(mid.X, 0, mid.Z) * rot
	local w = info.width
	SK.part(parent, "Road", cf * CF(0, (ry - 0.1) / 2, 0), V(w, ry + 0.1, L), C.Asphalt)
	local ly = ry + 0.03
	local function line(off: number, color: Color3, width: number?)
		SK.part(parent, "Line", cf * CF(off, ly, 0), V(width or 0.4, 0.06, L - 1), color, { collide = false, cast = false, query = false })
	end
	if info.kind == "avenue" then
		line(-0.45, C.LineYellow)
		line(0.45, C.LineYellow)
		line(-12, C.LineWhite, 0.3)
		line(12, C.LineWhite, 0.3)
	else
		line(0, C.LineYellow)
	end
	-- lamps and trees along the kerbs (alternating sides), clear of curb cuts and spur mouths
	local right = V(-dir.Z, 0, dir.X)
	local lampEvery = CityConfig.LampSpacing
	local k = 0
	local s = ta + 14
	while s < len - tb - 8 do
		local side = if (k + idx) % 2 == 0 then 1 else -1
		local p = pa + dir * s + right * side * (w / 2 + 1.6)
		if clear(ctx, p, 30) then
			local face = CFrame.lookAt(p, p - right * side)
			streetLamp(parent, face)
		end
		k += 1
		s += lampEvery
	end
	k = 0
	s = ta + 14 + CityConfig.TreeSpacing / 2
	while s < len - tb - 10 do
		local side = if (k + idx) % 2 == 0 then -1 else 1
		local p = pa + dir * s + right * side * (w / 2 + 4.3)
		if clear(ctx, p, 28) then
			BlockFiller.tree(parent, CF(p.X, CityConfig.SidewalkY, p.Z), ctx.rng, 1.1)
		end
		k += 1
		s += CityConfig.TreeSpacing
	end
end

local function signalPole(ctx: Ctx, parent: Instance, base: Vector3, armDir: Vector3, armLen: number, face: Vector3, axis: string)
	local m = Instance.new("Model")
	m.Name = "TrafficLight"
	local y0 = CityConfig.SidewalkY
	SK.cyl(m, "Pole", CF(base.X, y0 + 8, base.Z), 16, 0.9, C.MetalDark)
	local armMid = base + armDir * (armLen / 2)
	SK.part(m, "Arm", CFrame.lookAt(V(armMid.X, y0 + 15.4, armMid.Z), V(armMid.X, y0 + 15.4, armMid.Z) + armDir), V(0.5, 0.5, armLen), C.MetalDark)
	local hp = base + armDir * armLen
	local headCf = CFrame.lookAt(V(hp.X, y0 + 13, hp.Z), V(hp.X, y0 + 13, hp.Z) + face)
	SK.part(m, "Head", headCf, V(2.2, 6.4, 1.6), Color3.fromHex("#2F3A2F"))
	local set = ctx.lamps[axis]
	for i, col in { "red", "amber", "green" } do
		local lamp = SK.part(m, `Lamp_{col}`, headCf * CF(0, 2 - (i - 1) * 2, -0.85), V(1.4, 1.4, 0.3), LAMP_OFF, { collide = false, cast = false, query = false })
		table.insert((set :: any)[col], lamp)
	end
	m.Parent = parent
	return m
end

local function streetSign(parent: Instance, base: Vector3, xName: string, zName: string)
	local y = CityConfig.SidewalkY + 10
	local bx = SK.part(parent, "StreetSign", CF(base.X, y, base.Z) * CF(4, 0, 0), V(8, 1.3, 0.2), Color3.fromHex("#2E7D4F"))
	SK.sign(bx, zName, Enum.NormalId.Front, C.Trim)
	SK.sign(bx, zName, Enum.NormalId.Back, C.Trim)
	local bz = SK.part(parent, "StreetSign", CF(base.X, y + 1.4, base.Z) * CF(0, 0, 4) * ANG(0, math.rad(90), 0), V(8, 1.3, 0.2), Color3.fromHex("#2E7D4F"))
	SK.sign(bz, xName, Enum.NormalId.Front, C.Trim)
	SK.sign(bz, xName, Enum.NormalId.Back, C.Trim)
end

local function drawCrossing(ctx: Ctx, parent: Instance, g: any, id: string)
	local n = g.nodes[id]
	local ry = CityConfig.RoadY
	SK.part(parent, "Crossing", CF(n.x, (ry - 0.1) / 2, n.z), V(2 * n.halfX, ry + 0.1, 2 * n.halfZ), C.Asphalt)
	local arms = 0
	local dirs: { Vector3 } = {}
	for other in g.adj[id] do
		local info = RoadGraph.edgeInfo(g, id, other)
		if info and info.drawn then
			local o = g.nodes[other]
			local d = V(o.x - n.x, 0, o.z - n.z)
			if d.Magnitude > 0.5 then
				table.insert(dirs, d.Unit)
				arms += 1
			end
		end
	end
	-- crosswalks on every arm
	if CityConfig.Crosswalks then
		for _, d in dirs do
			local alongX = math.abs(d.X) > 0.5
			local half = if alongX then n.halfX else n.halfZ
			local width = if alongX then 2 * n.halfZ else 2 * n.halfX
			local right = V(-d.Z, 0, d.X)
			local c = V(n.x, 0, n.z) + d * (half + 4)
			local stripes = math.floor(width / 7)
			for k = 0, stripes - 1 do
				local off = -width / 2 + 3.5 + k * 7
				local p = c + right * off
				SK.part(parent, "Zebra", CFrame.lookAt(V(p.X, ry + 0.03, p.Z), V(p.X, ry + 0.03, p.Z) + d), V(3, 0.06, 5), C.LineWhite, {
					collide = false,
					cast = false,
					query = false,
				})
			end
		end
	end
	if arms >= 3 and CityConfig.TrafficLights then
		local R = CityConfig.CornerRadius
		local inset = R - (R - 3) / math.sqrt(2)
		for _, s in { { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 } } do
			local corner = V(n.x + s[1] * (n.halfX + inset), 0, n.z + s[2] * (n.halfZ + inset))
			if s[1] * s[2] > 0 then
				-- arm over the north-south road, head faces traffic coming along Z from this side
				local len = inset + n.halfX * 0.5
				signalPole(ctx, parent, corner, V(-s[1], 0, 0), len, V(0, 0, s[2]), "Z")
			else
				local len = inset + n.halfZ * 0.5
				signalPole(ctx, parent, corner, V(0, 0, -s[2]), len, V(s[1], 0, 0), "X")
			end
		end
		local i, j = string.match(id, "^N(%d+)_(%d+)$")
		if i and j then
			local nw = V(n.x - n.halfX - inset, 0, n.z - n.halfZ - inset)
			streetSign(parent, nw, Districts.StreetNamesX[tonumber(i) :: number + 1], Districts.StreetNamesZ[tonumber(j) :: number + 1])
		end
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
		local np = SK.marker(folder, "RoadNode", CF(p), V(2, 2, 2), nil, { NodeId = id })
		parts[id] = np
	end
	for _, e in ex.edges do
		local ov = Instance.new("ObjectValue")
		ov.Name = "RoadEdge"
		ov.Value = parts[e.a]
		ov:SetAttribute("A", e.a)
		ov:SetAttribute("B", e.b)
		ov:SetAttribute("Kind", e.kind)
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
-- builder districts
---------------------------------------------------------------------------------------------------
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

local function buildDistrict(ctx: Ctx, parent: Instance, d: any, builder: any, info: any, seed: number)
	local cfg = CityConfig
	local i0 = 2 * d.macro[1]
	local j0 = 2 * d.macro[2]
	local halfX = (RoadGraph.line(cfg, i0 + 2) - RoadGraph.line(cfg, i0) - RoadGraph.width(cfg, i0) / 2 - RoadGraph.width(cfg, i0 + 2) / 2) / 2
	-- kerb ring with gaps where the builder's own roads come out
	local gaps = {}
	local spur = Districts.Spurs[d.builder] or { entries = { { "S", 0 } } }
	for _, e in spur.entries do
		table.insert(gaps, { side = e[1], at = e[2], w = cfg.SpurWidth + 4, cut = "road" })
	end
	local ring = Instance.new("Model")
	ring.Name = `{d.id}_Kerbs`
	BlockFiller.base(ring, cfg, d.x, d.z, halfX, gaps, false)
	ring.Parent = parent
	local _ = j0
	-- the location itself
	local model = Instance.new("Model")
	model.Name = d.builder
	model:SetAttribute(Names.Attr.LocationId, d.builder)
	local ok, err = pcall(builder.Build, model, CF(d.x, 0, d.z), Random.new(seed + hash(d.builder)))
	if not ok then
		warn(`[CityBuilder] {d.builder}.Build failed: {err}`)
	end
	if d.builder == "Farm" and not model:FindFirstChild("TornadoField", true) then
		SK.marker(model, "TornadoField", CF(d.x, 1, d.z - 83), V(300, 2, 94), nil, nil)
	end
	districtSite(model, info, info.truck)
	model.Parent = parent
	return model
end

---------------------------------------------------------------------------------------------------
-- dam (south outskirts; procedural until a DamBuilder exists)
---------------------------------------------------------------------------------------------------
local function buildDam(ctx: Ctx, parent: Instance, info: any): Model
	local rng = ctx.rng
	local dz = info.z
	local o = CF(info.x, 0, dz)
	local model = SK.newSite(parent, info, o)
	-- reservoir + dam wall to the south, a riverside hamlet north of it (the flood path)
	local wallZ = 60
	SK.part(model, "DamWall", o * CF(0, 22, wallZ), V(300, 44, 16), Color3.fromHex("#A8A39A"))
	SK.part(model, "DamTop", o * CF(0, 44.6, wallZ), V(304, 1.2, 18), C.Concrete)
	for k = -2, 2 do
		SK.part(model, "Buttress", o * CF(k * 60, 18, wallZ - 10), V(8, 36, 6), Color3.fromHex("#9A958C"))
	end
	SK.part(model, "Reservoir", o * CF(0, 38, wallZ + 100), V(400, 2, 180), C.Water, { material = Enum.Material.Glass, transparency = 0.25 })
	for _, s in { -1, 1 } do
		SK.part(model, "Hill", o * CF(s * 205, 23, wallZ + 60), V(30, 46, 260), C.GrassDark)
	end
	local sign = SK.part(model, "DamSign", o * CF(0, 30, wallZ - 8.2), V(60, 8, 0.4), Color3.fromHex("#3D5A80"))
	SK.sign(sign, "BIG DAM  (DO NOT EXPLODE)", Enum.NormalId.Front, C.Trim)
	-- 3 charge spots on the dam face (FinaleService plants here)
	for k = 1, 3 do
		local cs = SK.marker(model, `ChargeSpot{k}`, o * CF((k - 2) * 70, 8, wallZ - 9), V(4, 4, 2), nil, { ChargeSpot = k })
		cs.Transparency = 0.6
		cs.Color = C.Red
	end
	-- hamlet: wooden shacks in the flood path
	local fires = 0
	local shacks = { { -110, -120 }, { -60, -40 }, { 80, -110 }, { 120, -30 }, { -130, -10 }, { 60, -60 } }
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
	-- high ground the civilians must reach
	local hg = SK.part(model, "HighGround", o * CF(170, 6, -150), V(50, 12, 50), C.GrassDark)
	hg:SetAttribute("HighGround", true)
	-- the flood path the tidal wave sweeps
	local wave = SK.marker(model, "WaveVolume", o * CF(0, 15, -60), V(380, 30, 220), nil, nil)
	wave:SetAttribute("Direction", Vector3.new(0, 0, -1))
	-- road end, truck spot
	SK.truckSpot(model, CF(info.truck.x, CityConfig.RoadY, info.truck.z))
	SK.arrival(model, CF(info.truck.x, CityConfig.RoadY, info.truck.z), V(60, 20, 60))
	hydrantNear(model, CF(info.truck.x + 18, CityConfig.RoadY, info.truck.z))
	return model
end

function hydrantNear(parent: Instance, cf: CFrame)
	local h = MapKit.hydrant(parent, cf)
	h:SetAttribute("HydrantId", `H_{parent.Name}`)
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
		{ name = "XGreen", x = "green", z = "red", dur = function()
			return CityConfig.TrafficCycle
		end },
		{ name = "XAmber", x = "amber", z = "red", dur = function()
			return 1.5
		end },
		{ name = "ZGreen", x = "red", z = "green", dur = function()
			return CityConfig.TrafficCycle
		end },
		{ name = "ZAmber", x = "red", z = "amber", dur = function()
			return 1.5
		end },
	}
	local function apply(p: any)
		setLamps(lamps.X, p.x)
		setLamps(lamps.Z, p.z)
		model:SetAttribute("TrafficPhase", p.name)
		model:SetAttribute("TrafficPhaseEndsAt", workspace:GetServerTimeNow() + p.dur())
	end
	apply(phases[1])
	if not RunService:IsRunning() then
		return
	end
	task.spawn(function()
		local seen = false
		local i = 1
		while true do
			task.wait(phases[i].dur())
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
local function register(model: Model, parent: Instance, siteId: string)
	local snap = model:Clone()
	registry[siteId] = { model = model, snapshot = snap, parent = parent }
	CityBuilder.Sites[siteId] = model
end

function CityBuilder.Build(model: Model, origin: CFrame, rng: Random)
	local t0 = os.clock()
	table.clear(registry)
	table.clear(CityBuilder.Sites)
	model:SetAttribute("DisplayName", "Blazeville")
	local cfg = CityConfig
	local builders = findBuilders()
	local available = {}
	for id in builders do
		available[id] = true
	end
	local seed = rng:NextInteger(1, 1000000)
	local plan = Districts.planCity(cfg, available, MissionCatalog, seed)
	CityBuilder.Plan = plan
	local g = plan.graph
	local ox, oz = origin.Position.X, origin.Position.Z
	if math.abs(ox) > 0.01 or math.abs(oz) > 0.01 then
		warn("[CityBuilder] the city is laid out in world coordinates around (0, 0); origin ignored")
	end
	local ctx: Ctx = {
		model = model,
		plan = plan,
		rng = rng,
		keepClear = {},
		lamps = { X = { red = {}, amber = {}, green = {} }, Z = { red = {}, amber = {}, green = {} } },
	}
	-- keep lamps/trees out of curb cuts and spur mouths
	local ext = RoadGraph.extent(cfg)
	for _, s in plan.sites do
		if s.block then
			local north = s.face == "N"
			local bz = RoadGraph.blockCenter(cfg, s.block[2])
			table.insert(ctx.keepClear, V(s.x, 0, bz + (if north then -1 else 1) * cfg.BlockSize / 2))
		end
	end
	for id, p in g.nodes do
		if not string.match(id, "^N%d+_%d+$") then
			table.insert(ctx.keepClear, V(p.x, 0, p.z))
		end
	end

	-- ground: two slabs (a part side is capped at 2048 studs), top just under y = 0
	local ground = Instance.new("Model")
	ground.Name = "Ground"
	local zs, zn = -ext / 2 - 260, ext / 2 + 520
	local zmid = -ext / 2 + 900
	SK.part(ground, "Grass", CF(0, -1.1, (zs + zmid) / 2), V(2048, 2, zmid - zs), C.Grass)
	SK.part(ground, "Grass", CF(0, -1.1, (zmid + zn) / 2), V(2048, 2, zn - zmid), C.Grass)
	ground.Parent = model

	local sections: { [string]: Instance } = {}
	-- roads
	local roads = Instance.new("Model")
	roads.Name = "Roads"
	for idx, e in g.edges do
		drawEdge(ctx, roads, g, e, idx)
	end
	for id in g.nodes do
		if string.match(id, "^N%d+_%d+$") then
			drawCrossing(ctx, roads, g, id)
		end
	end
	roads.Parent = model
	sections.Roads = roads

	-- districts + filler blocks
	local blocksFolder = Instance.new("Folder")
	blocksFolder.Name = "Blocks"
	local districtsFolder = Instance.new("Folder")
	districtsFolder.Name = "Districts"
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
		siteFor = function(_block: any, lot: any)
			return siteByLot[lot]
		end,
		onSite = function(_m: Model, _s: any) end,
	}
	for _, b in plan.blocks do
		local ok, err = pcall(BlockFiller.fillBlock, fillCtx, blocksFolder, b)
		if not ok then
			warn(`[CityBuilder] block {b.bx},{b.bz} ({b.theme}) failed: {err}`)
		end
	end
	blocksFolder.Parent = model
	sections.Blocks = blocksFolder
	for _, d in plan.districts do
		if d.useBuilder then
			local info = siteById[d.builder]
			local ok, res = pcall(buildDistrict, ctx, districtsFolder, d, builders[d.builder], info, seed)
			if not ok then
				warn(`[CityBuilder] district {d.id} failed: {res}`)
			end
		end
	end
	-- dam
	local damInfo = siteById["dam-S"] or siteById["Dam"]
	if damInfo then
		if plan.dam.useBuilder and builders.Dam then
			local dm = Instance.new("Model")
			dm.Name = "Dam"
			dm:SetAttribute(Names.Attr.LocationId, "Dam")
			local ok, err = pcall(builders.Dam.Build, dm, CF(plan.dam.x, 0, plan.dam.z), Random.new(seed + hash("Dam")))
			if not ok then
				warn(`[CityBuilder] Dam.Build failed: {err}`)
			end
			districtSite(dm, damInfo, nil)
			dm.Parent = districtsFolder
		else
			local ok, err = pcall(buildDam, ctx, districtsFolder, damInfo)
			if not ok then
				warn(`[CityBuilder] dam failed: {err}`)
			end
		end
	end
	districtsFolder.Parent = model
	sections.Districts = districtsFolder

	-- station driveway apron (the strip north of the grid is StationBuilder's)
	local sd = cfg.StationDriveway
	SK.part(roads, "StationApron", CF(sd.x, (cfg.RoadY - 0.1) / 2, sd.z - 10), V(120, cfg.RoadY + 0.1, 20), C.Concrete)

	exportGraph(model, g)

	-- site registry (pristine snapshots for RebuildSite)
	local nSites = 0
	for _, m in CollectionService:GetTagged(cfg.SiteTag) do
		local _ = m -- tagged instances outside this unparented model are not ours
	end
	for _, d in model:GetDescendants() do
		if d:IsA("Model") and d:HasTag(cfg.SiteTag) then
			local id = d:GetAttribute("SiteId")
			if type(id) == "string" and d.Parent then
				register(d, d.Parent, id)
				nSites += 1
			end
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

function CityBuilder.GetSite(siteId: string): Model?
	local r = registry[siteId]
	return if r then r.model else nil
end

function CityBuilder.RebuildSite(siteId: string): Model?
	local r = registry[siteId]
	if not r then
		return nil
	end
	if not r.parent.Parent and not r.model.Parent then
		return nil
	end
	local fresh = r.snapshot:Clone()
	local old = r.model
	fresh.Parent = r.parent
	if old ~= fresh then
		old:Destroy()
	end
	r.model = fresh
	CityBuilder.Sites[siteId] = fresh
	count("city_site_rebuilds", 1)
	return fresh
end

return CityBuilder
