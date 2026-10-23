-- ForestBuilder [owner: G2]. PINE RIDGE: burning pine forest at dusk (docs/game/05 §2.7,
-- docs/game/02 "Burning Forest"). Slot 5. Local frame: origin = slot centre on the ground, +X east,
-- +Z south (toward the default preview camera). Gameplay hooks are found by tag/attribute only.
--   Dirt road       from the west edge (Z ~66) east to the clearing, wooden bridge over the creek.
--   Clearing        centre (12, 24), r 40: ranger cabin (log walls, locked door, radio desk), the
--                   hikers' abandoned campfire (F1), TruckSpot + squad spawns.
--   Radio tower     (52, -24), 46 tall lattice, red beacon; scorched patch with dead snags (F3).
--   Creek           winds north-south at X ~ -95; three wide pools are refills (tag Hydrant).
--   Tent camp       (-140, -118): two tents, hiker R1 down in the smoke + dog R2 (F2 log).
--   Bamboo grove    (150, -50): the escaped panda R4 (F4 log). Hiker R3 sits on a creek rock.
--   ~120 low-poly pines (PropKit.tree kind "pine"), logs, rocks, bushes, dry grass tufts (<= 4 studs).
-- Fire starts (tag FireStart on Flammable parts, attr FireId, SmokeHeavy = true): F1..F5, all on logs.
-- Rescue spawns (tag RescueSpawn, attrs Kind/Pose/SpawnId/BuildingId): R1 Civilian lying, R2 Dog,
--   R3 Civilian sitting, R4 Panda, R5 Civilian (the ranger, Variant "Ranger") lying in the cabin.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local ForestBuilder = {}
ForestBuilder.Id = "Forest"
ForestBuilder.Slot = 5

local LOCATION = "Forest"
local TAG_TRUCKSPOT = (Names.Tag :: any).TruckSpot or "TruckSpot"
local TAG_PLAYERSPAWN = (Names.Tag :: any).PlayerSpawn or "PlayerSpawn"
local ATTR_SLOT = (Names.Attr :: any).Slot or "Slot"

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

local C = {
	Floor = hex("#A8743E"),
	Needles = hex("#6E4E2E"),
	Moss = hex("#6A7A3A"),
	DryGrass = hex("#C9893F"),
	DryGrass2 = hex("#B8783A"),
	DryGrass3 = hex("#D9A055"),
	DryGrass4 = hex("#9A8A44"),
	Dirt = hex("#9A7048"),
	Rut = hex("#7A5638"),
	ClearingDirt = hex("#B08A5E"),
	Pine = hex("#2F4A3A"),
	Pine2 = hex("#3A5A40"),
	Pine3 = hex("#2A4434"),
	Trunk = hex("#7A3A1E"),
	Log = hex("#7A4E32"),
	Log2 = hex("#8A5A3A"),
	LogEnd = hex("#C9A06A"),
	Bark = hex("#5A3A26"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	RoofGreen = hex("#3F5F4A"),
	Stone = hex("#8A8076"),
	Stone2 = hex("#9A9086"),
	Stone3 = hex("#6E6660"),
	Concrete = hex("#B8B2A6"),
	Metal = hex("#8A9094"),
	MetalDark = hex("#5A6064"),
	TowerRed = hex("#C8232B"),
	White = hex("#F7F4EE"),
	Trim = hex("#F2EDE4"),
	Black = hex("#1A1714"),
	Charred = hex("#1F1A19"),
	CharredWarm = hex("#3A2A22"),
	Scorch = hex("#2A2422"),
	Ember = hex("#FF5A1F"),
	FireBody = hex("#FFB12B"),
	Water = hex("#4FA3B8"),
	CreekBed = hex("#8A7A5A"),
	Lamp = hex("#FFC97A"),
	RadioGreen = hex("#6BE36B"),
	TentOrange = hex("#E8873A"),
	TentTeal = hex("#2A9D8F"),
	Bamboo = hex("#8AB04A"),
	Bamboo2 = hex("#7A9A3A"),
	BambooLeaf = hex("#5E8C3E"),
	Autumn = hex("#C8782E"),
	Autumn2 = hex("#B8562A"),
	Autumn3 = hex("#D9A030"),
	Bush = hex("#4A6A3A"),
	Deer = hex("#A0663A"),
	DeerBelly = hex("#E8D3A8"),
	MushroomRed = hex("#C8232B"),
	Plaid = hex("#CF442B"),
	Mustard = hex("#E9C46A"),
	SignGreen = hex("#2F5F4A"),
}

local Ball, Cyl = Enum.PartType.Ball, Enum.PartType.Cylinder
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y
local FABRIC = Enum.Material.Fabric
local PLANKS = Enum.Material.WoodPlanks

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function at(cf: CFrame, x: number, y: number, z: number, yaw: number?): CFrame
	return cf * CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw or 0), 0)
end

local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = { color = color }
	if extra then
		for k, val in extra do
			o[k] = val
		end
	end
	return MapKit.part(parent, name, cf, size, o :: any)
end

local function vcyl(parent: Instance, name: string, cf: CFrame, h: number, d: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.shape = Cyl
	return part(parent, name, cf * UPRIGHT, v(h, d, d), color, o)
end

local function ball(parent: Instance, name: string, cf: CFrame, d: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.shape = Ball
	return part(parent, name, cf, v(d, d, d), color, o)
end

local function shaped(className: string, parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, extra: { [string]: any }?): BasePart
	local o = extra or {}
	local p = Instance.new(className) :: BasePart
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if o.collide == false then
		p.CanCollide = false
	end
	if o.flammable then
		CollectionService:AddTag(p, Names.Tag.Flammable)
		if o.fuel then
			p:SetAttribute(Names.Attr.Fuel, o.fuel)
		end
	end
	p.Parent = parent
	return p
end

local function light(p: BasePart, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
end

local function sign(p: BasePart, text: string, color: Color3, faces: { Enum.NormalId }?)
	for _, face in faces or { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		gui.PixelsPerStud = 40
		gui.LightInfluence = 1
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.Text = text
		t.TextScaled = true
		t.Font = Enum.Font.FredokaOne
		t.TextColor3 = color
		t.Parent = gui
		gui.Parent = p
	end
end

local function rect(parent: Instance, name: string, cf: CFrame, x0: number, x1: number, z0: number, z1: number, top: number, thick: number, color: Color3, flam: boolean?, extra: { [string]: any }?)
	local nx = if flam then math.max(1, math.ceil((x1 - x0) / 8 - 1e-6)) else 1
	local nz = if flam then math.max(1, math.ceil((z1 - z0) / 8 - 1e-6)) else 1
	local sx, sz = (x1 - x0) / nx, (z1 - z0) / nz
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.flammable = flam
	for i = 1, nx do
		for j = 1, nz do
			part(parent, name, cf * CFrame.new(x0 + (i - 0.5) * sx, top - thick / 2, z0 + (j - 0.5) * sz), v(sx, thick, sz), color, o)
		end
	end
end

local function disc(parent: Instance, name: string, cf: CFrame, x: number, z: number, d: number, top: number, thick: number, color: Color3, extra: { [string]: any }?): Part
	return vcyl(parent, name, cf * CFrame.new(x, top - thick / 2, z), thick, d, color, extra)
end

local function beam(parent: Instance, name: string, cf: CFrame, a: Vector3, b: Vector3, w: number, color: Color3, extra: { [string]: any }?): Part
	local mid = (a + b) / 2
	return part(parent, name, cf * CFrame.lookAt(mid, b), v(w, w, (b - a).Magnitude), color, extra)
end

-- Gable triangle in rcf's X-Y plane at z = zc: full height at x = xTall, zero at x = xZero.
local function gableTri(parent: Instance, name: string, rcf: CFrame, xTall: number, xZero: number, y0: number, y1: number, zc: number, thick: number, color: Color3, extra: { [string]: any }?)
	local yaw = if xZero > xTall then -math.pi / 2 else math.pi / 2
	shaped("WedgePart", parent, name, rcf * CFrame.new((xTall + xZero) / 2, (y0 + y1) / 2, zc) * CFrame.Angles(0, yaw, 0), v(thick, y1 - y0, math.abs(xZero - xTall)), color, extra)
end

-- Sloped roof panel in rcf's X-Y profile from (xa, ya) to (xb, yb) (xa < xb), running z0..z1.
local function slopePanel(parent: Instance, name: string, rcf: CFrame, xa: number, ya: number, xb: number, yb: number, z0: number, z1: number, extA: number, extB: number, thick: number, color: Color3, extra: { [string]: any }?)
	local dx, dy = xb - xa, yb - ya
	local L = math.sqrt(dx * dx + dy * dy)
	local ux, uy = dx / L, dy / L
	local nx, ny = -uy, ux
	local phi = math.atan2(dy, dx)
	local total = L + extA + extB
	local sx, sy = xa - ux * extA, ya - uy * extA
	local ns = math.max(1, math.ceil(total / 8 - 1e-6))
	local nz = math.max(1, math.ceil((z1 - z0) / 8 - 1e-6))
	local ls, lz = total / ns, (z1 - z0) / nz
	for i = 1, ns do
		local t = (i - 0.5) * ls
		local cx, cy = sx + ux * t + nx * thick / 2, sy + uy * t + ny * thick / 2
		for j = 1, nz do
			part(parent, name, rcf * CFrame.new(cx, cy, z0 + (j - 0.5) * lz) * CFrame.Angles(0, 0, phi), v(ls, thick, lz), color, extra)
		end
	end
end

------------------------------------------------------------------------------------------------
-- Props: PropKit when present, else a small local box model. cf = ground point, prop faces -Z.
------------------------------------------------------------------------------------------------
local propKit: any = nil
local propKitTried = false
local function getPropKit(): any
	if not propKitTried then
		propKitTried = true
		local props = script.Parent.Parent:FindFirstChild("Props")
		local mod = props and props:FindFirstChild("PropKit")
		if mod and mod:IsA("ModuleScript") then
			local ok, res = pcall(require, mod)
			if ok and type(res) == "table" then
				propKit = res
			else
				warn(`[ForestBuilder] PropKit unavailable: {res}`)
			end
		end
	end
	return propKit
end

type Box = { any } -- { offset, size, color, flammable?, shape?, rotation? }

local FALLBACK: { [string]: { Box } } = {
	pine = {
		{ v(0, 2.5, 0), v(5, 1.2, 1.2), C.Trunk, true, Cyl, UPRIGHT },
		{ v(0, 4.4, 0), v(2.4, 7.5, 7.5), C.Pine, true, Cyl, UPRIGHT },
		{ v(0, 6.6, 0), v(2.2, 5.8, 5.8), C.Pine2, true, Cyl, UPRIGHT },
		{ v(0, 8.6, 0), v(2, 4, 4), C.Pine, true, Cyl, UPRIGHT },
		{ v(0, 10.4, 0), v(1.6, 1.6, 1.6), C.Pine2, true, Ball },
	},
	tree = {
		{ v(0, 3.5, 0), v(7, 1.2, 1.2), C.Trunk, true, Cyl, UPRIGHT },
		{ v(0, 8, 0), v(8, 8, 8), C.Autumn, true, Ball },
		{ v(1.6, 10, 1), v(5.5, 5.5, 5.5), C.Autumn3, true, Ball },
	},
	bush = {
		{ v(0, 1.2, 0), v(3, 3, 3), C.Bush, true, Ball },
		{ v(1.1, 1, 0.3), v(2.3, 2.3, 2.3), C.Bush, true, Ball },
	},
	table = {
		{ v(0, 2.8, 0), v(6, 0.5, 4), C.WoodLight, true },
		{ v(0, 1.3, 0), v(1, 2.6, 1), C.Wood, true },
	},
	chair = {
		{ v(0, 1.6, 0), v(2, 0.4, 2), C.WoodLight, true },
		{ v(0, 2.8, 0.8), v(2, 2, 0.4), C.WoodLight, true },
		{ v(0, 0.7, 0), v(1.2, 1.4, 1.2), C.Wood, true },
	},
	bed = {
		{ v(0, 0.8, 0), v(5, 1.6, 8), C.Wood, true },
		{ v(0, 2, 0.2), v(4.6, 0.8, 7.4), C.White, true },
		{ v(0, 2.1, -1.4), v(4.8, 1, 4.8), C.Plaid, true },
	},
	bookshelf = {
		{ v(0, 3.5, 0), v(4, 7, 1.4), C.Wood, true },
	},
}

local function boxModel(parent: Instance, name: string, cf: CFrame, boxes: { Box }, opts: { [string]: any }?): Model
	local m = Instance.new("Model")
	m.Name = name
	local s: number = (opts and opts.size) or 1
	for i, b in boxes do
		local flam = b[4] and not (opts and opts.flammable == false)
		local col = if i > 1 and opts and opts.color then opts.color else b[3]
		local p = part(m, name, cf * CFrame.new(b[1] * s) * (b[6] or CFrame.identity), b[2] * s, col, {
			flammable = flam,
			shape = b[5],
		})
		if i == 1 then
			m.PrimaryPart = p
		end
	end
	m.Parent = parent
	return m
end

local function prop(kind: string, parent: Instance, cf: CFrame, opts: { [string]: any }?): Model?
	local pk = getPropKit()
	if pk and type(pk[kind]) == "function" then
		local ok, res = pcall(pk[kind], parent, cf, opts)
		if ok and typeof(res) == "Instance" then
			return res :: Model
		end
		warn(`[ForestBuilder] PropKit.{kind} failed: {res}`)
	end
	local key = if kind == "tree" and opts and opts.kind == "pine" then "pine" else kind
	local fb = FALLBACK[key]
	if fb then
		return boxModel(parent, key, cf, fb, opts)
	end
	return nil
end

------------------------------------------------------------------------------------------------
-- Gameplay markers
------------------------------------------------------------------------------------------------
local function marker(parent: Instance, name: string, cf: CFrame, size: Vector3, tag: string, attrs: { [string]: any }?): Part
	local p = part(parent, name, cf, size, C.Mustard, { transparency = 1, collide = false, tags = { tag } })
	p.CanQuery = false
	for k, val in attrs or {} do
		p:SetAttribute(k, val)
	end
	return p
end

-- Tags an existing Flammable part as a (smoky) fire start.
local function fireStart(p: BasePart?, id: string, bid: string)
	if not p then
		return
	end
	if not CollectionService:HasTag(p, Names.Tag.Flammable) then
		CollectionService:AddTag(p, Names.Tag.Flammable)
	end
	CollectionService:AddTag(p, Names.Tag.FireStart)
	p:SetAttribute("FireId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
	p:SetAttribute(Names.Attr.LocationId, LOCATION)
	p:SetAttribute("SmokeHeavy", true)
end

local function rescueSpawn(parent: Instance, id: string, kind: string, bid: string, cf: CFrame, pose: string, extra: { [string]: any }?): Part
	local attrs: { [string]: any } = {
		[Names.Attr.Kind] = kind,
		SpawnId = id,
		[Names.Attr.BuildingId] = bid,
		[Names.Attr.LocationId] = LOCATION,
		Pose = pose,
	}
	for k, val in extra or {} do
		attrs[k] = val
	end
	return marker(parent, id, cf * CFrame.new(0, 1, 0), v(2, 2, 2), Names.Tag.RescueSpawn, attrs)
end

-- Water part that refills hoses (tag Hydrant + prompt, like the town pool).
local function refill(p: BasePart, id: string)
	CollectionService:AddTag(p, Names.Tag.Hydrant)
	p:SetAttribute("HydrantId", id)
	p:SetAttribute("Creek", true)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Refill"
	prompt.ObjectText = "Creek"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = p
end

------------------------------------------------------------------------------------------------
-- Layout geometry (shared by the scatter passes)
------------------------------------------------------------------------------------------------
local function creekX(z: number): number
	return -95 + 12 * math.sin(z / 50)
end

local BRIDGE_Z = 50
local BRIDGE_X = creekX(BRIDGE_Z)
local ROAD = {
	{ -200, 66 },
	{ -160, 62 },
	{ -124, 54 },
	{ BRIDGE_X - 13, BRIDGE_Z },
	{ BRIDGE_X + 13, BRIDGE_Z },
	{ -44, 52 },
	{ -14, 46 },
	{ 14, 42 },
	{ 40, 40 },
}
local BRIDGE_SEG = 4

local CLEARING = { 12, 24, 40 }
local CAMP = { -140, -118 }
local TOWER = { 52, -24 }
local BAMBOO = { 150, -50 }
local SCORCH = { 36, -36 }

local function dist2(x: number, z: number, p: { number }): number
	return math.sqrt((x - p[1]) ^ 2 + (z - p[2]) ^ 2)
end

local function roadDist(x: number, z: number): number
	local best = math.huge
	for i = 1, #ROAD - 1 do
		local ax, az, bx, bz = ROAD[i][1], ROAD[i][2], ROAD[i + 1][1], ROAD[i + 1][2]
		local dx, dz = bx - ax, bz - az
		local t = math.clamp(((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz), 0, 1)
		best = math.min(best, math.sqrt((x - ax - t * dx) ^ 2 + (z - az - t * dz) ^ 2))
	end
	return best
end

-- true when (x, z) is free for trees/scenery (pad = extra margin).
local function open(x: number, z: number, pad: number): boolean
	if math.abs(x) > 194 or math.abs(z) > 194 then
		return false
	end
	if dist2(x, z, CLEARING) < CLEARING[3] + 4 + pad then
		return false
	end
	if roadDist(x, z) < 9 + pad then
		return false
	end
	if math.abs(x - creekX(z)) < 10 + pad then
		return false
	end
	if dist2(x, z, CAMP) < 20 + pad or dist2(x, z, TOWER) < 14 + pad or dist2(x, z, BAMBOO) < 24 + pad or dist2(x, z, SCORCH) < 14 + pad then
		return false
	end
	return true
end

------------------------------------------------------------------------------------------------
-- Small builders
------------------------------------------------------------------------------------------------
local TUFT_COLORS = { C.DryGrass, C.DryGrass2, C.DryGrass3, C.DryGrass4 }
local function tuft(parent: Instance, cf: CFrame, rng: Random): BasePart
	local w, h, d = rng:NextNumber(1.6, 3.2), rng:NextNumber(1.2, 2.6), rng:NextNumber(1.6, 3.2)
	return shaped(
		"CornerWedgePart",
		parent,
		"GrassTuft",
		cf * CFrame.new(0, h / 2, 0) * CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0),
		v(w, h, d),
		TUFT_COLORS[rng:NextInteger(1, #TUFT_COLORS)],
		{ flammable = true, fuel = 8, collide = false, material = FABRIC }
	)
end

-- Fallen log lying along cf's X axis on the ground. Returns the (flammable) trunk.
local function fallenLog(parent: Instance, cf: CFrame, len: number, d: number, flammable: boolean?): Part
	local trunk = part(parent, "FallenLog", cf * CFrame.new(0, d / 2, 0), v(len, d, d), C.Bark, {
		shape = Cyl,
		flammable = flammable ~= false,
		fuel = 45,
	})
	for _, s in { -1, 1 } do
		part(parent, "LogEnd", cf * CFrame.new(s * (len / 2 + 0.02), d / 2, 0), v(0.1, d * 0.82, d * 0.82), C.LogEnd, { shape = Cyl, collide = false })
	end
	part(parent, "Branch", cf * CFrame.new(len * 0.15, d * 0.95, 0) * CFrame.Angles(0, 0, math.rad(55)), v(0.45, d * 1.1, 0.45), C.Bark, { collide = false })
	return trunk
end

local ROCK_COLORS = { C.Stone, C.Stone2, C.Stone3 }
local function rock(parent: Instance, cf: CFrame, s: number, rng: Random): Part
	local main = part(parent, "Rock", cf * CFrame.new(0, s * 0.35, 0) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), rng:NextNumber(0, 6.28), rng:NextNumber(-0.3, 0.3)), v(s * rng:NextNumber(1, 1.5), s * rng:NextNumber(0.7, 1), s), ROCK_COLORS[rng:NextInteger(1, 3)])
	if s > 2.5 then
		part(parent, "Rock", cf * CFrame.new(s * 0.55, s * 0.2, s * 0.3) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0.3), v(s * 0.6, s * 0.5, s * 0.6), ROCK_COLORS[rng:NextInteger(1, 3)])
	end
	return main
end

local PINE_COLORS = { C.Pine, C.Pine2, C.Pine3 }
local function pine(parent: Instance, cf: CFrame, s: number, rng: Random)
	prop("tree", parent, cf * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), { kind = "pine", size = s, color = PINE_COLORS[rng:NextInteger(1, 3)] })
end

------------------------------------------------------------------------------------------------
-- Ground, road, bridge, creek
------------------------------------------------------------------------------------------------
local function ground(model: Model, o: CFrame, rng: Random)
	local g = Instance.new("Model")
	g.Name = "Ground"
	g.Parent = model
	g.PrimaryPart = part(g, "ForestFloor", o * CFrame.new(0, -1, 0), v(400, 2, 400), C.Floor)
	-- needle carpets and mossy patches under the canopy
	for i = 1, 26 do
		local x, z = rng:NextNumber(-180, 180), rng:NextNumber(-180, 180)
		if dist2(x, z, CLEARING) > 50 then
			local col = if i % 3 == 0 then C.Moss elseif i % 3 == 1 then C.Needles else C.DryGrass2
			disc(g, "FloorPatch", o, x, z, rng:NextNumber(18, 42), 0.06 + (i % 4) * 0.005, 0.1, col)
		end
	end
	-- the clearing
	disc(g, "Clearing", o, CLEARING[1], CLEARING[2], CLEARING[3] * 2, 0.12, 0.2, C.ClearingDirt)
	-- scorched ground where the fire already passed (by the tower)
	disc(g, "Scorch", o, SCORCH[1], SCORCH[2], 30, 0.14, 0.1, C.Scorch)
	disc(g, "ScorchEdge", o, SCORCH[1] - 3, SCORCH[2] + 2, 36, 0.11, 0.1, C.CharredWarm)
end

local function road(model: Model, o: CFrame)
	local r = Instance.new("Model")
	r.Name = "DirtRoad"
	r.Parent = model
	for i = 1, #ROAD - 1 do
		if i ~= BRIDGE_SEG then
			local a = v(ROAD[i][1], 0, ROAD[i][2])
			local b = v(ROAD[i + 1][1], 0, ROAD[i + 1][2])
			local mid = (a + b) / 2
			local len = (b - a).Magnitude + 4
			local cf = o * CFrame.lookAt(mid, mid + (b - a).Unit)
			part(r, "Road", cf * CFrame.new(0, 0.09, 0), v(12, 0.2, len), C.Dirt)
			part(r, "Rut", cf * CFrame.new(-3.2, 0.1, 0), v(2, 0.2, len), C.Rut)
			part(r, "Rut", cf * CFrame.new(3.2, 0.1, 0), v(2, 0.2, len), C.Rut)
		end
	end
	-- wooden bridge over the creek
	local b = Instance.new("Model")
	b.Name = "Bridge"
	b:SetAttribute(Names.Attr.BuildingId, "Forest.Bridge")
	b.Parent = r
	local bcf = o * CFrame.new(BRIDGE_X, 0, BRIDGE_Z)
	for i = 0, 15 do
		part(b, "Plank", bcf * CFrame.new(-11.25 + i * 1.5, 0.7, 0), v(1.4, 0.6, 13), if i % 2 == 0 then C.WoodLight else C.Wood, {
			flammable = true,
			fuel = 25,
			material = PLANKS,
		})
	end
	for _, z in { -5, 5 } do
		part(b, "Stringer", bcf * CFrame.new(0, 0.2, z), v(27, 0.8, 1), C.Bark, { shape = Cyl })
	end
	for _, z in { -6.6, 6.6 } do
		for _, x in { -12, -4, 4, 12 } do
			part(b, "RailPost", bcf * CFrame.new(x, 2.6, z), v(0.8, 3.4, 0.8), C.Log)
		end
		for _, x in { -8, 0, 8 } do
			part(b, "Rail", bcf * CFrame.new(x, 4, z), v(8.4, 0.6, 0.6), C.Log2, { shape = Cyl, flammable = true, fuel = 20 })
		end
	end
	b.PrimaryPart = b:FindFirstChild("Plank") :: BasePart
end

local function creek(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "Creek"
	m:SetAttribute(Names.Attr.BuildingId, "Forest.Creek")
	m.Parent = model
	for z0 = -200, 175, 25 do
		local z1 = z0 + 25
		local a = v(creekX(z0), 0, z0)
		local b = v(creekX(z1), 0, z1)
		local mid = (a + b) / 2
		local len = (b - a).Magnitude + 3
		local cf = o * CFrame.lookAt(mid, mid + (b - a).Unit)
		part(m, "CreekBed", cf * CFrame.new(0, 0.03, 0), v(15, 0.1, len), C.CreekBed)
		local w = part(m, "Water", cf * CFrame.new(0, 0.2, 0), v(10, 0.3, len), C.Water, { transparency = 0.25, collide = false })
		w.Reflectance = 0.15
	end
	-- three wide pools: hose refills
	for i, z in { -120, 10, 150 } do
		local x = creekX(z)
		disc(m, "PoolBed", o, x, z, 24, 0.07, 0.1, C.CreekBed)
		local pool = disc(m, "Pool", o, x, z, 20, 0.4, 0.4, C.Water, { transparency = 0.2, collide = false })
		pool.Reflectance = 0.15
		pool.Name = `CreekPool{i}`
		refill(pool, `Creek{i}`)
		for k = 0, 5 do
			local ang = k * math.pi / 3 + 0.3
			rock(m, at(o, x + math.cos(ang) * 11.5, 0, z + math.sin(ang) * 11.5), rng:NextNumber(1.4, 2.4), rng)
		end
	end
	-- pebbles and stepping stones along the banks
	for _ = 1, 26 do
		local z = rng:NextNumber(-190, 190)
		local side = if rng:NextNumber() < 0.5 then -1 else 1
		local x = creekX(z) + side * rng:NextNumber(5.5, 8)
		ball(m, "Pebble", o * CFrame.new(x, 0.2, z), rng:NextNumber(0.8, 1.8), ROCK_COLORS[rng:NextInteger(1, 3)])
	end
	for _, z in { -60, -54, 88, 94 } do
		disc(m, "SteppingStone", o, creekX(z) + (if z % 2 == 0 then -1.5 else 1.5), z, 2.6, 0.5, 0.6, C.Stone2)
	end
end

------------------------------------------------------------------------------------------------
-- Ranger cabin (log walls, ridge along X, porch facing the clearing +Z)
------------------------------------------------------------------------------------------------
type Hole = { number } -- { s0, s1, row0, row1 }

local function logWall(parent: Instance, cf: CFrame, a: Vector3, b: Vector3, base: number, rows: number, d: number, holes: { Hole })
	local dv = b - a
	local len = dv.Magnitude
	local dir = dv.Unit
	local rot = CFrame.fromMatrix(Vector3.zero, dir, Vector3.yAxis)
	for r = 1, rows do
		local y = base + (r - 0.5) * d
		local spans = { { -1.2, len + 1.2 } }
		for _, h in holes do
			if r >= h[3] and r <= h[4] then
				local nsp = {}
				for _, sp in spans do
					if h[2] <= sp[1] or h[1] >= sp[2] then
						table.insert(nsp, sp)
					else
						if h[1] > sp[1] then
							table.insert(nsp, { sp[1], h[1] })
						end
						if h[2] < sp[2] then
							table.insert(nsp, { h[2], sp[2] })
						end
					end
				end
				spans = nsp
			end
		end
		for _, sp in spans do
			local L = sp[2] - sp[1]
			if L > 0.2 then
				local n = math.max(1, math.ceil(L / 8 - 1e-6))
				local l = L / n
				for i = 1, n do
					local p = a + dir * (sp[1] + (i - 0.5) * l)
					part(parent, "Log", cf * CFrame.new(p.X, y, p.Z) * rot, v(l, d, d), if r % 2 == 0 then C.Log else C.Log2, {
						shape = Cyl,
						flammable = true,
						fuel = 40,
					})
				end
			end
		end
	end
end

local function cabin(model: Model, o: CFrame)
	local m = Instance.new("Model")
	m.Name = "RangerCabin"
	local bid = "Forest.Cabin"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	m.Parent = model
	local cf = o * CFrame.new(-14, 0, 4)
	local FY = 1.2
	m.PrimaryPart = part(m, "Foundation", cf * CFrame.new(0, 0.5, 0), v(26, 1, 18), C.Stone)
	rect(m, "Floor", cf, -11, 11, -7, 7, FY, 0.4, C.WoodLight, true, { material = PLANKS })
	-- log walls: 5 rows of 2-stud logs, base y 1, top y 11
	local B, R, D = 1, 5, 2
	logWall(m, cf, v(-12, 0, 8), v(12, 0, 8), B, R, D, { { 2.8, 7.2, 2, 3 }, { 9.8, 14.2, 1, 4 }, { 16.8, 21.2, 2, 3 } })
	logWall(m, cf, v(-12, 0, -8), v(12, 0, -8), B, R, D, { { 4.8, 9.2, 2, 3 } })
	logWall(m, cf, v(-12, 0, -8), v(-12, 0, 8), B, R, D, { { 5.8, 10.2, 2, 3 } })
	logWall(m, cf, v(12, 0, -8), v(12, 0, 8), B, R, D, { { 5.8, 10.2, 2, 3 } })
	-- windows (glass + sill) and the locked front door
	local T = { collide = false }
	for _, x in { -7, 7 } do
		MapKit.window(m, "Window", cf * CFrame.new(x, 5, 8))
		part(m, "Sill", cf * CFrame.new(x, 2.85, 9.2), v(5, 0.4, 1), C.WoodLight, T)
	end
	MapKit.window(m, "Window", cf * CFrame.new(-5, 5, -8))
	part(m, "Sill", cf * CFrame.new(-5, 2.85, -9.2), v(5, 0.4, 1), C.WoodLight, T)
	for _, x in { -12, 12 } do
		MapKit.window(m, "Window", cf * CFrame.new(x, 5, 0) * CFrame.Angles(0, math.pi / 2, 0))
		part(m, "Sill", cf * CFrame.new(x + (if x > 0 then 1.2 else -1.2), 2.85, 0), v(1, 0.4, 5), C.WoodLight, T)
	end
	local door = MapKit.door(m, "CabinDoor", cf * CFrame.new(0, B + 3.5, 8), true)
	door:SetAttribute(Names.Attr.BuildingId, bid)
	part(m, "Lintel", cf * CFrame.new(0, 8.5, 8), v(4.6, 1, 2), C.WoodLight, { flammable = true, fuel = 20 })
	-- gable roof, ridge along X, green metal
	local rcf = cf * CFrame.Angles(0, math.pi / 2, 0)
	local top = B + R * D
	for _, z in { -12, 12 } do
		gableTri(m, "Gable", rcf, 0, -9, top, top + 6, z, 1.6, C.Log, { flammable = true, fuel = 30, material = PLANKS })
		gableTri(m, "Gable", rcf, 0, 9, top, top + 6, z, 1.6, C.Log, { flammable = true, fuel = 30, material = PLANKS })
	end
	local RF = { flammable = true, fuel = 35, material = Enum.Material.DiamondPlate }
	slopePanel(m, "Roof", rcf, -9, top, 0, top + 6, -14, 14, 2.4, 0.4, 0.8, C.RoofGreen, RF)
	slopePanel(m, "Roof", rcf, 0, top + 6, 9, top, -14, 14, 0.4, 2.4, 0.8, C.RoofGreen, RF)
	part(m, "Ridge", rcf * CFrame.new(0, top + 6.7, 0), v(1.8, 0.7, 28.4), C.RoofGreen:Lerp(C.Black, 0.35))
	-- stone chimney on the east end, stove flue through the roof
	part(m, "Chimney", cf * CFrame.new(13.9, 10, -3), v(3, 20, 3.4), C.Stone, { material = Enum.Material.Slate })
	part(m, "ChimneyCap", cf * CFrame.new(13.9, 20.3, -3), v(3.6, 0.6, 4), C.Stone3)
	-- porch facing the clearing
	rect(m, "Porch", cf, -10, 10, 9, 15, 1, 1, C.WoodLight, true, { material = PLANKS })
	part(m, "PorchStep", cf * CFrame.new(0, 0.25, 15.7), v(5, 0.5, 1.4), C.Stone2)
	for _, x in { -9.4, 9.4 } do
		part(m, "PorchPost", cf * CFrame.new(x, 5, 14.5), v(1, 8, 1), C.Log2, { flammable = true, fuel = 25 })
	end
	part(m, "PorchRoof", cf * CFrame.new(0, 9.4, 12.2) * CFrame.Angles(math.rad(8), 0, 0), v(21.4, 0.6, 7.2), C.RoofGreen)
	part(m, "PorchBench", cf * CFrame.new(-5, 2.2, 10.2), v(5, 0.4, 1.6), C.Wood, { flammable = true })
	part(m, "PorchBenchLegs", cf * CFrame.new(-5, 1.6, 10.2), v(4.4, 0.8, 1.2), C.Wood, { collide = false })
	local lantern = ball(m, "PorchLantern", cf * CFrame.new(3.4, 7.8, 9.2), 0.9, C.Lamp, { neon = true, collide = false })
	light(lantern, C.Lamp, 16, 1.2)
	-- interior: radio desk (the walkie-talkie glows green), bunk, stove, map board
	prop("table", m, at(cf, -7, FY, -5.4, 0), { width = 5, depth = 2.6 })
	prop("chair", m, at(cf, -7, FY, -2.6, 0))
	part(m, "RadioSet", cf * CFrame.new(-8, FY + 3.6, -6), v(2.4, 1.6, 1.4), C.MetalDark)
	part(m, "RadioDial", cf * CFrame.new(-8.4, FY + 3.7, -5.25), v(1, 0.6, 0.1), C.RadioGreen, { neon = true, collide = false })
	part(m, "RadioAntenna", cf * CFrame.new(-7.2, FY + 5.4, -6.2), v(0.15, 2.4, 0.15), C.Black, { collide = false })
	local walkie = part(m, "WalkieTalkie", cf * CFrame.new(-5.6, FY + 3.4, -5), v(0.6, 1.2, 0.4), C.Black, { collide = false })
	walkie:SetAttribute("Walkie", true)
	part(m, "WalkieLight", cf * CFrame.new(-5.6, FY + 3.7, -5.22), v(0.4, 0.3, 0.05), C.RadioGreen, { neon = true, collide = false })
	part(m, "WalkieAntenna", cf * CFrame.new(-5.45, FY + 4.4, -5), v(0.12, 0.9, 0.12), C.Black, { collide = false })
	light(walkie, C.RadioGreen, 6, 0.8)
	local board = part(m, "MapBoard", cf * CFrame.new(1, 6, -6.9), v(5, 3.4, 0.2), C.Mustard, { flammable = true, collide = false })
	sign(board, "TRAIL MAP", C.SignGreen, { Enum.NormalId.Back })
	prop("bed", m, at(cf, 6.5, FY, -4.4, 90), { color = C.Plaid })
	part(m, "Stove", cf * CFrame.new(8, FY + 1.5, 4.6), v(2.6, 3, 2.6), C.Black)
	vcyl(m, "StoveFlue", cf * CFrame.new(8, 10.5, 4.6), 15.6, 0.8, C.MetalDark)
	part(m, "Firewood", cf * CFrame.new(5, FY + 0.6, 6.2), v(3, 1.2, 1.2), C.Log2, { flammable = true, fuel = 30 })
	part(m, "Rug", cf * CFrame.new(-1, FY + 0.1, 1), v(8, 0.2, 5), C.Plaid, { flammable = true, collide = false })
	prop("bookshelf", m, at(cf, -10.4, FY, 2, -90), { width = 3 })
	local bulb = ball(m, "CabinBulb", cf * CFrame.new(0, 10.2, 0), 1.2, C.Lamp, { neon = true, collide = false })
	light(bulb, C.Lamp, 18, 0.9)
	rescueSpawn(m, "R5", "Civilian", bid, at(cf, 0.5, FY, 1, 90), "lying", { Variant = "Ranger" })
	-- welcome sign at the clearing edge
	local s = at(o, -32, 0.1, 40, 20)
	for _, x in { -4.4, 4.4 } do
		part(m, "SignPost", s * CFrame.new(x, 3.4, 0), v(0.8, 6.8, 0.8), C.Log)
	end
	local sb = part(m, "Sign", s * CFrame.new(0, 5, 0), v(10, 3.2, 0.5), C.SignGreen)
	sign(sb, "PINE RIDGE RANGER STATION", C.Mustard)
end

------------------------------------------------------------------------------------------------
-- Campfire (F1), radio tower + scorch (F3), tent camp (F2), bamboo grove (F4)
------------------------------------------------------------------------------------------------
local function campfire(model: Model, o: CFrame)
	local m = Instance.new("Model")
	m.Name = "Campfire"
	local bid = "Forest.Clearing"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	m.Parent = model
	local cf = o * CFrame.new(22, 0.12, 16)
	for i = 0, 8 do
		local a = i * math.pi * 2 / 9
		ball(m, "FireRing", cf * CFrame.new(math.cos(a) * 2.6, 0.5, math.sin(a) * 2.6), 1.4, if i % 2 == 0 then C.Stone else C.Stone3)
	end
	local first: BasePart? = nil
	for i = 0, 2 do
		local a = i * math.pi * 2 / 3
		local p = part(m, "CampLog", cf * CFrame.new(math.cos(a) * 0.9, 0.9, math.sin(a) * 0.9) * CFrame.Angles(0, -a, 0) * CFrame.Angles(0, 0, math.rad(35)), v(3.4, 0.7, 0.7), C.Bark, {
			shape = Cyl,
			flammable = true,
			fuel = 45,
		})
		first = first or p
	end
	fireStart(first, "F1", bid)
	local ember = ball(m, "Embers", cf * CFrame.new(0, 0.4, 0), 1.8, C.Ember, { neon = true, collide = false })
	ember.CanQuery = false
	light(ember, C.Ember, 18, 2)
	local flame = Instance.new("Fire")
	flame.Size = 3
	flame.Heat = 6
	flame.Color = C.FireBody
	flame.SecondaryColor = C.Ember
	flame.Parent = ember
	local smoke = Instance.new("Smoke")
	smoke.Color = hex("#5E5A55")
	smoke.Opacity = 0.2
	smoke.Size = 2.5
	smoke.RiseVelocity = 4
	smoke.Parent = ember
	-- log seats, cooler, marshmallow stick
	for _, a in { 30, 150, 260 } do
		local r = math.rad(a)
		part(m, "SeatLog", cf * CFrame.new(math.cos(r) * 6, 0.8, math.sin(r) * 6) * CFrame.Angles(0, -r + math.pi / 2, 0), v(5.5, 1.6, 1.6), C.Log2, {
			shape = Cyl,
			flammable = true,
			fuel = 35,
		})
	end
	part(m, "Cooler", cf * CFrame.new(-6.5, 0.9, -3), v(2.6, 1.8, 1.8), C.TentTeal)
	part(m, "CoolerLid", cf * CFrame.new(-6.5, 1.9, -3), v(2.7, 0.3, 1.9), C.White)
	part(m, "Stick", cf * CFrame.new(2.6, 1.4, 3.2) * CFrame.Angles(math.rad(40), 0, 0), v(0.15, 0.15, 4), C.WoodLight, { collide = false })
	ball(m, "Marshmallow", cf * CFrame.new(2.6, 2.6, 1.6), 0.5, C.White, { collide = false })
end

local function radioTower(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "RadioTower"
	m.Parent = model
	local cf = o * CFrame.new(TOWER[1], 0, TOWER[2])
	local H = 46
	m.PrimaryPart = part(m, "Pad", cf * CFrame.new(0, 0.25, 0), v(13, 0.5, 13), C.Concrete)
	local function w(y: number): number
		return 5 - 3.8 * y / H
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			beam(m, "Leg", cf, v(sx * 5, 0.5, sz * 5), v(sx * 1.2, H, sz * 1.2), 0.7, C.TowerRed)
		end
	end
	local levels = { 0.5, 8, 16, 24, 32, 40 }
	for k, y in levels do
		if k > 1 then
			local wy = w(y)
			local col = if k % 2 == 0 then C.White else C.TowerRed
			for _, s in { -1, 1 } do
				part(m, "Ring", cf * CFrame.new(0, y, s * wy), v(2 * wy, 0.4, 0.4), col)
				part(m, "Ring", cf * CFrame.new(s * wy, y, 0), v(0.4, 0.4, 2 * wy), col)
			end
			local y0 = levels[k - 1]
			local w0, w1 = w(y0), wy
			local f = if k % 2 == 0 then 1 else -1
			beam(m, "Brace", cf, v(-f * w0, y0, w0), v(f * w1, y, w1), 0.3, C.MetalDark)
			beam(m, "Brace", cf, v(f * w0, y0, -w0), v(-f * w1, y, -w1), 0.3, C.MetalDark)
			beam(m, "Brace", cf, v(w0, y0, -f * w0), v(w1, y, f * w1), 0.3, C.MetalDark)
			beam(m, "Brace", cf, v(-w0, y0, f * w0), v(-w1, y, -f * w1), 0.3, C.MetalDark)
		end
	end
	part(m, "Platform", cf * CFrame.new(0, H, 0), v(3.6, 0.5, 3.6), C.MetalDark)
	vcyl(m, "Mast", cf * CFrame.new(0, H + 5, 0), 10, 0.5, C.White)
	local beacon = ball(m, "Beacon", cf * CFrame.new(0, H + 10.4, 0), 1.2, C.TowerRed, { neon = true, collide = false })
	light(beacon, C.TowerRed, 30, 1.5)
	ball(m, "MidBeacon", cf * CFrame.new(1.8, 32.4, 1.8), 0.7, C.TowerRed, { neon = true, collide = false })
	for _, s in { -1, 1 } do
		part(m, "Dish", cf * CFrame.new(s * 2.8, 38, 0), v(0.5, 3.2, 3.2), C.White, { shape = Cyl })
		part(m, "DishFeed", cf * CFrame.new(s * 3.4, 38, 0), v(0.9, 0.3, 0.3), C.MetalDark, { collide = false })
	end
	part(m, "Cable", cf * CFrame.new(4.5, 0.7, 4), v(0.3, 0.3, 6), C.Black, { collide = false })
	-- equipment shed
	local sc = cf * CFrame.new(9.5, 0, 6)
	part(m, "Shed", sc * CFrame.new(0, 2.8, 0), v(6, 5.6, 8), C.Metal)
	part(m, "ShedRoof", sc * CFrame.new(0, 5.85, 0), v(6.8, 0.5, 8.8), C.MetalDark)
	part(m, "ShedDoor", sc * CFrame.new(-3.02, 2.4, 1), v(0.1, 4.6, 2.6), C.MetalDark, { collide = false })
	local shedSign = part(m, "ShedSign", sc * CFrame.new(-3.06, 4.4, -2), v(0.1, 1.2, 2.4), C.Mustard, { collide = false })
	sign(shedSign, "DANGER", C.Black, { Enum.NormalId.Left })
	part(m, "ACUnit", sc * CFrame.new(1, 1, -4.8), v(2.4, 2, 1.6), C.Concrete)

	-- scorch patch west of the tower: dead snags + smouldering log (F3)
	local s = Instance.new("Model")
	s.Name = "Scorch"
	s:SetAttribute(Names.Attr.BuildingId, "Forest.Tower")
	s.Parent = model
	local scf = o * CFrame.new(SCORCH[1], 0.14, SCORCH[2])
	for _, p in { { -8, -4, 9 }, { 5, -7, 7 }, { -3, 7, 11 }, { 9, 4, 6 }, { -10, 6, 5 } } do
		local snag = vcyl(s, "Snag", scf * CFrame.new(p[1], p[3] / 2, p[2]), p[3], 1.3, C.Charred)
		snag:SetAttribute(Names.Attr.Charred, true)
		part(s, "SnagBranch", scf * CFrame.new(p[1] + 0.8, p[3] * 0.7, p[2]) * CFrame.Angles(0, 0, math.rad(-50)), v(0.35, 2.4, 0.35), C.Charred, { collide = false })
	end
	local f3 = fallenLog(s, scf * CFrame.new(1, 0, 1) * CFrame.Angles(0, math.rad(25), 0), 9, 2)
	f3.Color = C.CharredWarm
	fireStart(f3, "F3", "Forest.Tower")
	for _ = 1, 7 do
		local e = part(s, "Ember", scf * CFrame.new(rng:NextNumber(-9, 9), 0.05, rng:NextNumber(-9, 9)) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0), v(rng:NextNumber(0.4, 1), 0.15, rng:NextNumber(0.3, 0.6)), C.Ember, {
			neon = true,
			collide = false,
		})
		e.CanQuery = false
	end
	for _ = 1, 10 do
		local a = rng:NextNumber(0, 6.28)
		tuft(s, scf * CFrame.new(math.cos(a) * rng:NextNumber(12, 17), -0.04, math.sin(a) * rng:NextNumber(12, 17)), rng)
	end
end

local function tent(parent: Instance, cf: CFrame, color: Color3)
	local F = { flammable = true, fuel = 15, material = FABRIC }
	gableTri(parent, "Tent", cf, 0, -3.6, 0, 5, 0, 8, color, F)
	gableTri(parent, "Tent", cf, 0, 3.6, 0, 5, 0, 8, color, F)
	local dark = color:Lerp(C.Black, 0.55)
	gableTri(parent, "TentDoor", cf, 0, -1.6, 0, 3.4, 4.05, 0.15, dark, { collide = false })
	gableTri(parent, "TentDoor", cf, 0, 1.6, 0, 3.4, 4.05, 0.15, dark, { collide = false })
	part(parent, "TentPole", cf * CFrame.new(0, 5.05, 0), v(0.25, 0.25, 9), C.MetalDark, { collide = false })
	for _, s in { -1, 1 } do
		beam(parent, "GuyLine", cf, v(0, 5, s * 4.4), v(0, 0, s * 7), 0.08, C.White, { collide = false })
	end
end

local function camp(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "TentCamp"
	local bid = "Forest.Camp"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	m.Parent = model
	local cf = o * CFrame.new(CAMP[1], 0, CAMP[2])
	disc(m, "CampDirt", cf, 0, 0, 30, 0.1, 0.1, C.ClearingDirt)
	tent(m, cf * CFrame.new(-4, 0, -2), C.TentOrange)
	tent(m, cf * CFrame.new(8, 0, -4) * CFrame.Angles(0, math.rad(-25), 0), C.TentTeal)
	m.PrimaryPart = m:FindFirstChild("Tent") :: BasePart
	-- sleeping bag, backpack, lantern, camp chair, dead campfire
	part(m, "SleepingBag", cf * CFrame.new(-9, 0.5, 5) * CFrame.Angles(0, math.rad(20), 0), v(2.2, 1, 6), C.Plaid, { flammable = true, fuel = 15, material = FABRIC })
	part(m, "Backpack", cf * CFrame.new(2.4, 1.4, 4), v(2, 2.8, 1.4), C.Mustard, { flammable = true, fuel = 15 })
	part(m, "BedRoll", cf * CFrame.new(2.4, 3, 4), v(2.4, 0.9, 0.9), C.TentTeal, { shape = Cyl, collide = false })
	local lamp = part(m, "Lantern", cf * CFrame.new(0.5, 0.7, 6), v(0.8, 1.4, 0.8), C.Lamp, { neon = true, collide = false })
	light(lamp, C.Lamp, 14, 1.2)
	part(m, "ChairSeat", cf * CFrame.new(6, 1.6, 6), v(2, 0.3, 2), C.TentTeal, { flammable = true })
	part(m, "ChairBack", cf * CFrame.new(6, 2.8, 6.9), v(2, 2.2, 0.3), C.TentTeal, { flammable = true })
	part(m, "ChairLegs", cf * CFrame.new(6, 0.75, 6), v(1.6, 1.5, 1.6), C.MetalDark, { transparency = 0.5, collide = false })
	for i = 0, 5 do
		local a = i * math.pi / 3
		ball(m, "AshRing", cf * CFrame.new(-2 + math.cos(a) * 1.8, 0.4, 10 + math.sin(a) * 1.8), 1, C.Stone3)
	end
	disc(m, "Ash", cf, -2, 10, 3, 0.2, 0.1, C.Charred)
	-- R1 hiker down in the smoke in front of the orange tent, R2 their dog beside them
	rescueSpawn(m, "R1", "Civilian", bid, at(cf, -3, 0.1, 6, 180), "lying", { Variant = "Hiker" })
	rescueSpawn(m, "R2", "Dog", bid, at(cf, -7, 0.1, 9, 160), "sitting")
	-- F2: a fallen log at the camp's edge in the dry grass
	local f2 = fallenLog(m, cf * CFrame.new(10, 0.1, 12) * CFrame.Angles(0, math.rad(-30), 0), 9, 2.2)
	fireStart(f2, "F2", bid)
	for _ = 1, 14 do
		local a = rng:NextNumber(0, 6.28)
		local r = rng:NextNumber(11, 19)
		tuft(m, cf * CFrame.new(math.cos(a) * r, 0, math.sin(a) * r), rng)
	end
end

local function bambooGrove(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "BambooGrove"
	local bid = "Forest.Bamboo"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	m.Parent = model
	local cf = o * CFrame.new(BAMBOO[1], 0, BAMBOO[2])
	local placed = 0
	local tries = 0
	while placed < 34 and tries < 400 do
		tries += 1
		local a = rng:NextNumber(0, 6.28)
		local r = rng:NextNumber(5.5, 20)
		local x, z = math.cos(a) * r, math.sin(a) * r
		if not (z > 4 and math.abs(x) < 4) then -- keep a path open toward the clearing (+Z)
			local h = rng:NextNumber(11, 19)
			local d = rng:NextNumber(0.7, 1.1)
			local col = if placed % 2 == 0 then C.Bamboo else C.Bamboo2
			local stalk = vcyl(m, "Bamboo", cf * CFrame.new(x, h / 2, z), h, d, col, { flammable = true, fuel = 15 })
			if placed == 0 then
				m.PrimaryPart = stalk
			end
			part(m, "BambooNode", cf * CFrame.new(x, h * 0.55, z) * UPRIGHT, v(0.3, d + 0.2, d + 0.2), col:Lerp(C.Black, 0.2), { shape = Cyl, collide = false })
			ball(m, "BambooLeaves", cf * CFrame.new(x + rng:NextNumber(-0.8, 0.8), h + 0.6, z + rng:NextNumber(-0.8, 0.8)), rng:NextNumber(2.4, 3.6), C.BambooLeaf, {
				flammable = true,
				fuel = 10,
				collide = false,
			})
			placed += 1
		end
	end
	rescueSpawn(m, "R4", "Panda", bid, at(cf, 0, 0.1, 0, 180), "sitting")
	-- chewed bamboo snack next to the panda + a warning sign
	part(m, "Snack", cf * CFrame.new(2, 0.4, 1.5) * CFrame.Angles(0, 0.6, 0), v(3, 0.5, 0.5), C.Bamboo, { shape = Cyl, collide = false })
	local s = at(o, BAMBOO[1] - 8, 0.1, BAMBOO[2] + 26, 200)
	part(m, "SignPost", s * CFrame.new(0, 3, 0), v(0.7, 6, 0.7), C.Log)
	local sb = part(m, "Sign", s * CFrame.new(0, 5.4, 0), v(6, 2.6, 0.4), C.Mustard)
	sign(sb, "CAUTION: PANDA", C.Black)
	-- F4: the log on the trail into the grove
	local f4 = fallenLog(m, at(o, BAMBOO[1] - 16, 0.1, BAMBOO[2] + 18, 70), 8, 2)
	fireStart(f4, "F4", bid)
end

------------------------------------------------------------------------------------------------
-- Scatter: pines, autumn trees, logs, rocks, bushes, tufts, critters
------------------------------------------------------------------------------------------------
local function deer(parent: Instance, cf: CFrame)
	local m = Instance.new("Model")
	m.Name = "Deer"
	local nc = { collide = false }
	local body = part(m, "Body", cf * CFrame.new(0, 4.2, 0), v(2.2, 2.2, 4.6), C.Deer, nc)
	part(m, "Belly", cf * CFrame.new(0, 3.4, 0), v(1.8, 0.6, 3.6), C.DeerBelly, nc)
	part(m, "Neck", cf * CFrame.new(0, 5.6, -2) * CFrame.Angles(math.rad(-25), 0, 0), v(1.1, 2.4, 1.1), C.Deer, nc)
	part(m, "Head", cf * CFrame.new(0, 6.8, -2.8), v(1.4, 1.4, 2), C.Deer, nc)
	part(m, "Nose", cf * CFrame.new(0, 6.6, -3.85), v(0.6, 0.5, 0.2), C.Black, nc)
	for _, s in { -1, 1 } do
		part(m, "Ear", cf * CFrame.new(s * 0.9, 7.5, -2.4), v(0.9, 0.5, 0.2), C.Deer, nc)
		part(m, "Antler", cf * CFrame.new(s * 0.5, 8.2, -2.6) * CFrame.Angles(0, 0, s * math.rad(-20)), v(0.2, 1.6, 0.2), C.LogEnd, nc)
		part(m, "AntlerTine", cf * CFrame.new(s * 0.85, 8.6, -2.6), v(0.6, 0.2, 0.2), C.LogEnd, nc)
		for _, z in { -1.7, 1.7 } do
			part(m, "Leg", cf * CFrame.new(s * 0.7, 1.55, z), v(0.5, 3.1, 0.5), C.Deer, nc)
		end
	end
	part(m, "Tail", cf * CFrame.new(0, 4.8, 2.4), v(0.6, 0.8, 0.3), C.White, nc)
	MapKit.googlyEyes(m, cf * CFrame.new(0, 7.1, -3.7), 0.7)
	m.PrimaryPart = body
	m.Parent = parent
end

local function scatter(model: Model, o: CFrame, rng: Random)
	local trees = Instance.new("Model")
	trees.Name = "Trees"
	trees:SetAttribute(Names.Attr.BuildingId, "Forest.Woods")
	trees.Parent = model
	local pts: { { number } } = {}
	local function spaced(x: number, z: number, gap: number): boolean
		for _, p in pts do
			if math.abs(p[1] - x) < gap and math.abs(p[2] - z) < gap and dist2(x, z, p) < gap then
				return false
			end
		end
		return true
	end
	-- dense dark ring of big pines near the slot edge (the forest wall)
	local ring = 0
	local tries = 0
	while ring < 36 and tries < 600 do
		tries += 1
		local side = rng:NextInteger(1, 4)
		local t = rng:NextNumber(-190, 190)
		local d = rng:NextNumber(172, 192)
		local x, z = if side == 1 then d elseif side == 2 then -d else t, if side == 3 then d elseif side == 4 then -d else t
		if open(x, z, 0) and spaced(x, z, 10) then
			table.insert(pts, { x, z })
			pine(trees, at(o, x, 0, z), rng:NextNumber(2.3, 3), rng)
			ring += 1
		end
	end
	-- the forest itself
	local n = 0
	tries = 0
	while n < 88 and tries < 2000 do
		tries += 1
		local x, z = rng:NextNumber(-172, 172), rng:NextNumber(-172, 172)
		if open(x, z, 0) and spaced(x, z, 11) then
			table.insert(pts, { x, z })
			n += 1
			if n % 9 == 0 then
				local cols = { C.Autumn, C.Autumn2, C.Autumn3 }
				prop("tree", trees, at(o, x, 0, z, rng:NextNumber(0, 360)), { variant = rng:NextInteger(1, 3), size = rng:NextNumber(1.1, 1.5), color = cols[rng:NextInteger(1, 3)] })
			else
				pine(trees, at(o, x, 0, z), rng:NextNumber(1.5, 2.7), rng)
			end
		end
	end
	-- a few pines framing the clearing edge
	for _, a in { 200, 230, 300, 330, 20, 100, 130 } do
		local r = math.rad(a)
		local x, z = CLEARING[1] + math.cos(r) * (CLEARING[3] + 7), CLEARING[2] + math.sin(r) * (CLEARING[3] + 7)
		if roadDist(x, z) > 10 and dist2(x, z, TOWER) > 15 and dist2(x, z, SCORCH) > 15 then
			pine(trees, at(o, x, 0, z), rng:NextNumber(1.8, 2.4), rng)
		end
	end

	local floor = Instance.new("Model")
	floor.Name = "Undergrowth"
	floor:SetAttribute(Names.Attr.BuildingId, "Forest.Woods")
	floor.Parent = model
	local function freeSpot(pad: number): (number, number)
		for _ = 1, 40 do
			local x, z = rng:NextNumber(-185, 185), rng:NextNumber(-185, 185)
			if open(x, z, pad) and spaced(x, z, 3) then
				return x, z
			end
		end
		return 170, 170
	end
	-- fallen logs (not fire starts)
	for _ = 1, 9 do
		local x, z = freeSpot(0)
		fallenLog(floor, at(o, x, 0, z, rng:NextNumber(0, 360)), rng:NextNumber(6, 9), rng:NextNumber(1.6, 2.2))
	end
	-- F5: log by the creek's east bank, next to the bridge
	local f5 = fallenLog(floor, at(o, BRIDGE_X + 17, 0, BRIDGE_Z - 14, 100), 8, 2)
	fireStart(f5, "F5", "Forest.Creek")
	-- rocks and boulders
	for i = 1, 28 do
		local x, z = freeSpot(-2)
		rock(floor, at(o, x, 0, z), if i % 5 == 0 then rng:NextNumber(3, 4.5) else rng:NextNumber(1.2, 2.6), rng)
	end
	-- R3: hiker resting on a creek-side boulder
	local rz = -40
	local rx = creekX(rz) + 10.5
	part(floor, "HikerRock", o * CFrame.new(rx, 1, rz) * CFrame.Angles(0, 0.4, 0), v(4.4, 2, 3.6), C.Stone2)
	part(floor, "HikerRock", o * CFrame.new(rx + 2.2, 0.7, rz + 1.6) * CFrame.Angles(0, 1.1, 0.2), v(2.4, 1.4, 2.2), C.Stone3)
	rescueSpawn(floor, "R3", "Civilian", "Forest.Creek", at(o, rx, 2, rz, 200), "sitting", { Variant = "Hiker" })
	part(floor, "HikerPack", o * CFrame.new(rx - 2.4, 0.9, rz + 0.6), v(1.8, 1.8, 1.2), C.Plaid, { flammable = true, fuel = 15 })
	-- bushes
	for _ = 1, 22 do
		local x, z = freeSpot(-2)
		prop("bush", floor, at(o, x, 0, z, rng:NextNumber(0, 360)), { color = C.Bush, size = rng:NextNumber(1, 1.5) })
	end
	-- stumps + red mushrooms
	for _ = 1, 8 do
		local x, z = freeSpot(-2)
		local cf = at(o, x, 0, z)
		vcyl(floor, "Stump", cf * CFrame.new(0, 0.7, 0), 1.4, 2.2, C.Bark)
		vcyl(floor, "StumpTop", cf * CFrame.new(0, 1.42, 0), 0.05, 1.8, C.LogEnd, { collide = false })
	end
	for _ = 1, 10 do
		local x, z = freeSpot(-4)
		local cf = at(o, x, 0, z)
		vcyl(floor, "MushroomStem", cf * CFrame.new(0, 0.5, 0), 1, 0.5, C.White, { collide = false })
		ball(floor, "MushroomCap", cf * CFrame.new(0, 1.05, 0), 1.3, C.MushroomRed, { collide = false })
		ball(floor, "MushroomSpot", cf * CFrame.new(0.3, 1.55, -0.25), 0.3, C.White, { collide = false })
	end
	-- dry grass tufts: dense near the logs/clearing edge/creek banks, sparse elsewhere
	local tufts = Instance.new("Model")
	tufts.Name = "DryGrass"
	tufts:SetAttribute(Names.Attr.BuildingId, "Forest.Woods")
	tufts.Parent = model
	local count = 0
	tries = 0
	while count < 170 and tries < 3000 do
		tries += 1
		local x, z = rng:NextNumber(-188, 188), rng:NextNumber(-188, 188)
		if open(x, z, -3) then
			tuft(tufts, at(o, x, 0, z), rng)
			count += 1
		end
	end
	for _ = 1, 40 do -- ring of dry grass round the clearing (fire path between the cabin and the woods)
		local a = rng:NextNumber(0, 6.28)
		local r = CLEARING[3] + rng:NextNumber(-3, 6)
		local x, z = CLEARING[1] + math.cos(a) * r, CLEARING[2] + math.sin(a) * r
		if roadDist(x, z) > 8 then
			tuft(tufts, at(o, x, 0.1, z), rng)
		end
	end
	for _ = 1, 16 do -- creek banks
		local z = rng:NextNumber(-190, 190)
		local x = creekX(z) + (if rng:NextNumber() < 0.5 then -1 else 1) * rng:NextNumber(8, 11)
		if roadDist(x, z) > 9 then
			tuft(tufts, at(o, x, 0, z), rng)
		end
	end
	deer(model, at(o, creekX(-160) + 14, 0, -160, 140))
	deer(model, at(o, 120, 0, 120, 250))
end

local function markers(model: Model, o: CFrame)
	-- Truck 67 parks at the end of the road in the clearing, facing east (+X).
	marker(model, "TruckSpot", o * CFrame.lookAt(v(24, 0.2, 41), v(34, 0.2, 41)), v(4, 1, 4), TAG_TRUCKSPOT, {
		[Names.Attr.LocationId] = LOCATION,
	})
	for i = 1, 4 do
		marker(model, `PlayerSpawn{i}`, at(o, 12 + i * 4, 0.6, 31, 180), v(3, 1, 3), TAG_PLAYERSPAWN, {
			[ATTR_SLOT] = i,
			[Names.Attr.LocationId] = LOCATION,
		})
	end
end

function ForestBuilder.Build(model: Model, origin: CFrame, rng: Random)
	model:SetAttribute("DisplayName", "Pine Ridge Forest")
	model:SetAttribute("AtmospherePreset", "FireGlow") -- AtmosphereConfig's "Burning Forest" preset
	model:SetAttribute("SmokeHeavy", true)
	ground(model, origin, rng)
	road(model, origin)
	creek(model, origin, rng)
	cabin(model, origin)
	campfire(model, origin)
	radioTower(model, origin, rng)
	camp(model, origin, rng)
	bambooGrove(model, origin, rng)
	scatter(model, origin, rng)
	markers(model, origin)
end

return ForestBuilder
