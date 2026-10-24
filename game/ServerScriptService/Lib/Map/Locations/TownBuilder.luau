-- TownBuilder [owner: G2]. MAPLE STREET: the v1 suburban block (docs/game/05 §2.2, docs/game/02 §4).
-- Slot 1. Local frame: origin = block centre on the ground, +X east, +Z south. Houses face the street
-- on the +Z side (mirrored from the doc ASCII so the fronts face the default preview camera; every
-- gameplay hook is found by tag/attribute, never by coordinate). Coordinates below are in the block
-- frame = slot origin shifted 8 north, so the road centre lands on slot z=56 and continues the
-- station road at slot x=-200 (world x=200).
--   Road Z 56..72, sidewalks Z 50..56 / 72..78, front lawns Z 36..50, houses Z -4..36,
--   backyards to the back fence at Z -40. Houses A..D = House1..4 at X -92, -28, 36, 100.
-- Fire points F1..F12: invisible 2x2x2, tag FireStart, attr FireId + BuildingId.
-- Rescue spawns R1..R5: invisible 2x2x2, tag RescueSpawn, attr Kind (civilian|cat|dog|floatguy),
--   SpawnId, BuildingId, Pose; -Z of the part is the facing direction.
-- PropKit / furniture is optional: every prop falls back to a local box model.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local TownBuilder = {}
TownBuilder.Id = "Town"
TownBuilder.Slot = 1

local H = 12 -- wall height per storey
local FY0 = 1.15 -- ground floor surface
local FY1 = 13 -- upper floor surface

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

local C = {
	Grass = hex("#5E8C3E"),
	Lawn = hex("#7FAF4A"),
	Asphalt = hex("#4A4650"),
	Sidewalk = hex("#C9B8A8"),
	Kerb = hex("#B3A291"),
	Patio = hex("#D9CBB8"),
	LineYellow = hex("#E3B23C"),
	Trim = hex("#F2EDE4"),
	Cream = hex("#E8D3A8"),
	Salmon = hex("#D98B6F"),
	Sage = hex("#9DB38A"),
	PaleBlue = hex("#9EC1CC"),
	RoofBrown = hex("#5A3A32"),
	RoofSlate = hex("#4E4A5A"),
	RoofTerra = hex("#8A4A35"),
	Foundation = hex("#7A6A62"),
	WoodFloor = hex("#C8683A"),
	WoodFloor2 = hex("#B8794A"),
	Tile = hex("#EFE7D8"),
	TileB = hex("#BFD8D8"),
	TileC = hex("#E9C46A"),
	RoomTeal = hex("#4F8A85"),
	Peach = hex("#F2D2B0"),
	Lilac = hex("#D9C6E3"),
	CreamIn = hex("#F3E3C3"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	Fence = hex("#6B4A35"),
	FenceDark = hex("#553826"),
	Brick = hex("#BF4835"),
	Concrete = hex("#B8B2A6"),
	PoolTile = hex("#7FC4D0"),
	PoolDeep = hex("#5FA9B8"),
	Water = hex("#61A8B6"),
	Pink = hex("#FF7FB0"),
	White = hex("#F7F4EE"),
	Black = hex("#1A1714"),
	Chrome = hex("#D6D8DC"),
	Sofa = hex("#6E8A6A"),
	SofaDark = hex("#5A7357"),
	Leaf = hex("#6F9A3A"),
	Leaf2 = hex("#8AAF4A"),
	Trunk = hex("#7A3A1E"),
	Lamp = hex("#FFC97A"),
	Red = hex("#C8232B"),
}

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

local function wedge(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, flam: boolean?): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.CanTouch = false
	w.Size = size
	w.CFrame = cf
	w.Material = Enum.Material.SmoothPlastic
	w.Color = color
	w.TopSurface = Enum.SurfaceType.Smooth
	w.BottomSurface = Enum.SurfaceType.Smooth
	if flam then
		CollectionService:AddTag(w, Names.Tag.Flammable)
	end
	w.Parent = parent
	return w
end

local function light(p: BasePart, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = C.Lamp
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
end

-- Rect slab with top at `top`, chunked into <= 8-stud tiles when flammable. Optional checker colour.
local function rect(parent: Instance, name: string, cf: CFrame, x0: number, x1: number, z0: number, z1: number, top: number, thick: number, color: Color3, flam: boolean?, checker: Color3?)
	if x1 - x0 < 0.05 or z1 - z0 < 0.05 then
		return
	end
	local tiled = flam or checker ~= nil
	local nx = if tiled then math.max(1, math.ceil((x1 - x0) / 8 - 1e-6)) else 1
	local nz = if tiled then math.max(1, math.ceil((z1 - z0) / 8 - 1e-6)) else 1
	local sx, sz = (x1 - x0) / nx, (z1 - z0) / nz
	for i = 1, nx do
		for j = 1, nz do
			local col = if checker and (i + j) % 2 == 0 then checker else color
			part(parent, name, cf * CFrame.new(x0 + (i - 0.5) * sx, top - thick / 2, z0 + (j - 0.5) * sz), v(sx, thick, sz), col, { flammable = flam })
		end
	end
end

-- Four rects covering (x0..x1, z0..z1) minus the hole (hx0..hx1, hz0..hz1).
local function rectHole(parent: Instance, name: string, cf: CFrame, x0: number, x1: number, z0: number, z1: number, hx0: number, hx1: number, hz0: number, hz1: number, top: number, thick: number, color: Color3)
	rect(parent, name, cf, x0, hx0, z0, z1, top, thick, color)
	rect(parent, name, cf, hx1, x1, z0, z1, top, thick, color)
	rect(parent, name, cf, hx0, hx1, z0, hz0, top, thick, color)
	rect(parent, name, cf, hx0, hx1, hz1, z1, top, thick, color)
end

-- Straight wall run from a to b (base points), height h, 1 thick, split into <= 8-stud chunks.
-- (Local helper: orients the long axis along a->b.)
local function wallRun(parent: Instance, name: string, cf: CFrame, a: Vector3, b: Vector3, h: number, opts: { [string]: any })
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 or h < 0.05 then
		return
	end
	local dir = d.Unit
	local n = math.max(1, math.ceil(len / 8 - 1e-6))
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * len / n) + v(0, h / 2, 0)
		MapKit.part(parent, `{name}_{i}`, cf * CFrame.lookAt(mid, mid + dir), v(1, h, len / n), opts :: any)
	end
end

------------------------------------------------------------------------------------------------
-- Props: PropKit when present, else a local box model. cf = ground point, prop faces -Z.
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
				warn(`[TownBuilder] PropKit unavailable: {res}`)
			end
		end
	end
	return propKit
end

type Box = { any } -- { offset, size, color, flammable?, shape?, neon?, rotation? }
local Ball, Cyl = Enum.PartType.Ball, Enum.PartType.Cylinder
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y

local FALLBACK: { [string]: { Box } } = {
	sofa = {
		{ v(0, 0.9, 0.1), v(8, 1.8, 2.8), C.Sofa, true },
		{ v(0, 2.3, 1.1), v(8, 2.8, 0.8), C.SofaDark, true },
		{ v(-3.7, 1.6, 0), v(0.8, 1.6, 3), C.SofaDark, true },
		{ v(3.7, 1.6, 0), v(0.8, 1.6, 3), C.SofaDark, true },
	},
	bookshelf = {
		{ v(0, 3.5, 0), v(4, 7, 1.4), C.Wood, true },
		{ v(0, 1.4, -0.55), v(3.4, 1.4, 0.4), C.Terracotta, true },
		{ v(0, 3.5, -0.55), v(3.4, 1.4, 0.4), C.Teal, true },
		{ v(0, 5.6, -0.55), v(3.4, 1.4, 0.4), C.Mustard, true },
	},
	bed = {
		{ v(0, 0.8, 0), v(5, 1.6, 8), C.Wood, true },
		{ v(0, 2, 0.2), v(4.6, 0.8, 7.4), C.White, true },
		{ v(0, 2.1, -1.4), v(4.8, 1, 4.8), C.Terracotta, true },
		{ v(0, 2.7, 2.8), v(3, 0.6, 1.4), C.White, true },
		{ v(0, 1.9, 3.8), v(5, 3.8, 0.6), C.Wood, true },
	},
	table = {
		{ v(0, 2.3, 0), v(4, 0.5, 3), C.WoodLight, true },
		{ v(0, 1, 0), v(1, 2, 1), C.Wood, true },
	},
	chair = {
		{ v(0, 1.5, 0), v(1.8, 0.4, 1.8), C.WoodLight, true },
		{ v(0, 2.6, 0.7), v(1.8, 2, 0.4), C.WoodLight, true },
		{ v(0, 0.65, 0), v(1.2, 1.3, 1.2), C.Wood, true },
	},
	plant = {
		{ v(0, 0.7, 0), v(1.4, 1.4, 1.4), C.Terracotta },
		{ v(0, 2.4, 0), v(2.4, 2.4, 2.4), C.Leaf, true, Ball },
	},
	tv = {
		{ v(0, 0.8, 0), v(4, 1.6, 1.6), C.Wood, true },
		{ v(0, 3, 0.1), v(3.8, 2.4, 0.4), C.Black },
		{ v(0, 3, -0.15), v(3.4, 2, 0.1), hex("#3A6A8A"), false, nil, true },
	},
	fridge = {
		{ v(0, 3, 0), v(3, 6, 2.6), C.White },
		{ v(1, 3.8, -1.4), v(0.4, 2, 0.4), C.Chrome },
	},
	counter = {
		{ v(0, 1.5, 0), v(4, 3, 2.4), C.CreamIn, true },
		{ v(0, 3.2, 0), v(4.2, 0.4, 2.6), C.Wood, true },
	},
	bench = {
		{ v(0, 1.6, 0), v(5, 0.5, 1.6), C.WoodLight, true },
		{ v(0, 2.7, 0.7), v(5, 1.6, 0.4), C.WoodLight, true },
		{ v(-2, 0.7, 0), v(0.5, 1.4, 1.4), C.Black },
		{ v(2, 0.7, 0), v(0.5, 1.4, 1.4), C.Black },
	},
	streetLamp = {
		{ v(0, 0.4, 0), v(1.4, 0.8, 1.4), C.Black },
		{ v(0, 6, 0), v(0.6, 12, 0.6), hex("#3A3A40") },
		{ v(0, 12.2, 0), v(1.8, 0.6, 1.8), hex("#3A3A40") },
		{ v(0, 11.5, 0), v(1.3, 1.3, 1.3), C.Lamp, false, Ball, true },
	},
	tree = {
		{ v(0, 3, 0), v(6, 1.4, 1.4), C.Trunk, false, Cyl, false, UPRIGHT },
		{ v(0, 8, 0), v(8, 8, 8), C.Leaf, false, Ball },
		{ v(1.6, 10.2, 1), v(6, 6, 6), C.Leaf2, false, Ball },
		{ v(-1.8, 9.4, -1.2), v(5.5, 5.5, 5.5), C.Leaf2, false, Ball },
	},
	bush = {
		{ v(0, 1.3, 0), v(3.4, 3.4, 3.4), C.Leaf, false, Ball },
		{ v(1.2, 1.1, 0.4), v(2.6, 2.6, 2.6), C.Leaf2, false, Ball },
	},
	mailbox = {
		{ v(0, 1.6, 0), v(0.5, 3.2, 0.5), C.Wood },
		{ v(0, 3.6, 0), v(1.2, 1.1, 2), hex("#2C5F9E") },
		{ v(0.75, 3.9, 0.4), v(0.2, 1.2, 0.4), C.Red },
	},
	car = {
		{ v(0, 1.9, 0), v(6, 2, 11), C.Teal },
		{ v(0, 3.7, 0.6), v(5.4, 1.8, 6), C.Teal },
		{ v(0, 3.7, -2.45), v(5, 1.4, 0.2), hex("#A8D5E2") },
		{ v(-2.9, 1.2, -3.4), v(1, 2.4, 2.4), C.Black, false, Cyl },
		{ v(2.9, 1.2, -3.4), v(1, 2.4, 2.4), C.Black, false, Cyl },
		{ v(-2.9, 1.2, 3.4), v(1, 2.4, 2.4), C.Black, false, Cyl },
		{ v(2.9, 1.2, 3.4), v(1, 2.4, 2.4), C.Black, false, Cyl },
		{ v(-1.8, 2, -5.55), v(1, 0.6, 0.2), C.Lamp, false, nil, true },
		{ v(1.8, 2, -5.55), v(1, 0.6, 0.2), C.Lamp, false, nil, true },
	},
}

local function boxModel(parent: Instance, name: string, cf: CFrame, boxes: { Box }, color: Color3?): Model
	local m = Instance.new("Model")
	m.Name = name
	for i, b in boxes do
		local c = if i == 1 and color then color else b[3]
		local p = part(m, name .. i, cf * CFrame.new(b[1]) * (b[7] or CFrame.identity), b[2], c, {
			flammable = b[4],
			shape = b[5],
			neon = b[6],
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
		local holder = Instance.new("Model")
		local ok, res = pcall(pk[kind], holder, cf, opts)
		if ok then
			for _, ch in holder:GetChildren() do
				ch.Parent = parent
			end
			holder:Destroy()
			return if typeof(res) == "Instance" then res :: Model else holder
		end
		holder:Destroy()
		warn(`[TownBuilder] PropKit.{kind} failed: {res}`)
	end
	local fb = FALLBACK[kind]
	if fb then
		return boxModel(parent, kind, cf, fb, opts and opts.color)
	end
	return nil
end

-- Local furniture that PropKit does not provide.
local function stove(parent: Instance, cf: CFrame)
	boxModel(parent, "Stove", cf, {
		{ v(0, 1.5, 0), v(3, 3, 2.6), C.White },
		{ v(0, 3.15, 0), v(3.1, 0.3, 2.7), C.Black },
		{ v(-0.7, 3.3, -0.5), v(0.2, 0.9, 0.9), hex("#FF5A1F"), false, Cyl, true, UPRIGHT },
		{ v(0.7, 3.3, 0.5), v(0.2, 0.9, 0.9), hex("#FF5A1F"), false, Cyl, true, UPRIGHT },
		{ v(0, 1.4, -1.35), v(2.4, 1.6, 0.2), hex("#3A3A40") },
		{ v(0, 3.9, 1.1), v(3, 1.2, 0.4), C.White },
	})
end

local function tub(parent: Instance, cf: CFrame)
	boxModel(parent, "Tub", cf, {
		{ v(0, 1.1, 0), v(4, 2.2, 7.4), C.White },
		{ v(0, 2.15, 0), v(3.2, 0.4, 6.6), C.PoolTile },
		{ v(0, 2.8, 3.3), v(0.4, 1.2, 0.4), C.Chrome },
	})
end

local function toilet(parent: Instance, cf: CFrame)
	boxModel(parent, "Toilet", cf, {
		{ v(0, 0.9, -0.2), v(1.6, 1.8, 2.2), C.White },
		{ v(0, 2.1, 0.9), v(1.8, 2.2, 0.8), C.White },
		{ v(0, 1.85, -0.3), v(1.4, 0.3, 1.8), hex("#BFD8D8") },
	})
end

local function sink(parent: Instance, cf: CFrame)
	boxModel(parent, "Sink", cf, {
		{ v(0, 1.4, 0), v(2.6, 2.8, 1.8), C.White },
		{ v(0, 2.9, 0), v(2.2, 0.3, 1.4), C.TileB },
		{ v(0, 3.4, 0.6), v(0.4, 1, 0.4), C.Chrome },
		{ v(0, 5.4, 0.8), v(2, 2.4, 0.2), hex("#A8D5E2") },
	})
end

local function dresser(parent: Instance, cf: CFrame, color: Color3?)
	boxModel(parent, "Dresser", cf, {
		{ v(0, 1.5, 0), v(4, 3, 1.6), color or C.WoodLight, true },
		{ v(0, 2.2, -0.85), v(3.4, 0.5, 0.2), C.Wood },
		{ v(0, 1.0, -0.85), v(3.4, 0.5, 0.2), C.Wood },
		{ v(-1, 3.6, 0), v(1, 1.2, 1), C.Lamp, false, Ball, true },
	})
end

local function rug(parent: Instance, cf: CFrame, w: number, d: number, color: Color3)
	part(parent, "Rug", cf * CFrame.new(0, 0.1, 0), v(w, 0.2, d), color, { flammable = true, collide = false })
end

local function flowerPot(parent: Instance, cf: CFrame)
	boxModel(parent, "FlowerPot", cf, {
		{ v(0, 0.4, 0), v(0.9, 0.8, 0.9), C.Terracotta },
		{ v(0, 1.2, 0), v(0.9, 0.9, 0.9), C.Pink, false, Ball },
		{ v(0.35, 1.0, 0.3), v(0.6, 0.6, 0.6), C.Mustard, false, Ball },
		{ v(-0.35, 1.0, -0.2), v(0.6, 0.6, 0.6), C.Leaf2, false, Ball },
	})
end

local function ceilingLamp(parent: Instance, cf: CFrame, ceiling: number, lit: boolean)
	part(parent, "LampCord", cf * CFrame.new(0, ceiling - 0.6, 0), v(0.4, 1.2, 0.4), C.Black, { collide = false })
	local bulb = part(parent, "LampShade", cf * CFrame.new(0, ceiling - 1.6, 0), v(1.6, 1.6, 1.6), C.Lamp, { shape = Ball, neon = true, collide = false })
	if lit then
		light(bulb, 18, 0.9)
	end
end

local function workbench(parent: Instance, cf: CFrame)
	boxModel(parent, "Workbench", cf, {
		{ v(0, 1.4, 0), v(7, 2.8, 2.6), C.Wood, true },
		{ v(0, 3.05, 0), v(8, 0.5, 3), C.WoodLight, true },
		{ v(0, 6, 1.3), v(8, 4, 0.4), hex("#C9A06A"), true },
		{ v(-2.5, 3.8, 0), v(1.8, 1, 1.2), C.Red },
		{ v(1.5, 6, 1), v(0.4, 2.4, 0.4), C.Black },
		{ v(2.5, 6.4, 1), v(1.6, 0.4, 0.4), C.Chrome },
		{ v(3.3, 0.9, -2.2), v(1.8, 1.8, 1.8), hex("#3F6FB0"), false, Cyl, false, UPRIGHT },
	})
end

local function shelfRack(parent: Instance, cf: CFrame)
	boxModel(parent, "Rack", cf, {
		{ v(0, 3.5, 0), v(5, 0.4, 1.8), C.Chrome },
		{ v(0, 1, 0), v(5, 0.4, 1.8), C.Chrome },
		{ v(0, 6, 0), v(5, 0.4, 1.8), C.Chrome },
		{ v(-2.3, 3.2, 0), v(0.4, 6.4, 1.8), hex("#8A8C90") },
		{ v(2.3, 3.2, 0), v(0.4, 6.4, 1.8), hex("#8A8C90") },
		{ v(-1, 4.5, 0), v(1.8, 1.6, 1.4), hex("#C9A06A"), true },
		{ v(1.2, 2, 0), v(2, 1.6, 1.4), hex("#C9A06A"), true },
		{ v(0.8, 7, 0), v(1.6, 1.6, 1.4), C.Teal },
	})
end

------------------------------------------------------------------------------------------------
-- Gameplay markers
------------------------------------------------------------------------------------------------
local function firePoint(parent: Instance, id: string, bid: string, cf: CFrame)
	local p = part(parent, id, cf, v(2, 2, 2), C.Red, { transparency = 1, collide = false, tags = { Names.Tag.FireStart } })
	p.CanQuery = false
	p:SetAttribute("FireId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
end

local function rescueSpawn(parent: Instance, id: string, kind: string, bid: string, cf: CFrame, pose: string)
	-- cf = ground/seat point, facing -Z; part centre 1 stud above it.
	local p = part(parent, id, cf * CFrame.new(0, 1, 0), v(2, 2, 2), C.Mustard, { transparency = 1, collide = false, tags = { Names.Tag.RescueSpawn } })
	p.CanQuery = false
	p:SetAttribute(Names.Attr.Kind, kind)
	p:SetAttribute("SpawnId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
	p:SetAttribute("Pose", pose)
end

------------------------------------------------------------------------------------------------
-- House kit
------------------------------------------------------------------------------------------------
type Ctx = {
	p: Model,
	hcf: CFrame,
	bid: string,
	siding: Color3,
	inner: Color3,
	shutter: Color3,
	roof: Color3,
}

local OPEN = {
	win = { w = 4, b = 3, t = 7 },
	door = { w = 4, b = 0, t = 7 },
	lock = { w = 4, b = 0, t = 7 },
	gap = { w = 4, b = 0, t = 8 },
	wide = { w = 8, b = 0, t = 8 },
	garage = { w = 12, b = 0, t = 9 },
}

local function trimPart(ctx: Ctx, name: string, cf: CFrame, size: Vector3, color: Color3)
	part(ctx.p, name, cf, size, color, { collide = false })
end

-- Wall spec: { x0, z0, x1, z1, ops = { {kind, coord, name?} }, ext = bool?, c = Vector3? (centre for trim normal) }
local function buildWall(ctx: Ctx, w: { [any]: any }, y0: number)
	local a = v(w[1], y0, w[2])
	local b = v(w[3], y0, w[4])
	local d = b - a
	local len = d.Magnitude
	local dir = d.Unit
	local alongX = math.abs(d.X) > math.abs(d.Z)
	local opts = { color = w.color or (if w.ext then ctx.siding else ctx.inner), flammable = true }
	local name = if w.ext then "Wall" else "Partition"
	local ops = {}
	for _, op in w.ops or {} do
		local s = if alongX then (op[2] - w[1]) * math.sign(d.X) else (op[2] - w[2]) * math.sign(d.Z)
		table.insert(ops, { kind = op[1], s = s, spec = OPEN[op[1]], name = op[3] })
	end
	table.sort(ops, function(p, q)
		return p.s < q.s
	end)
	local function seg(s0: number, s1: number, yb: number, h: number)
		if s1 - s0 > 0.05 and h > 0.05 then
			wallRun(ctx.p, name, ctx.hcf, a + dir * s0 + v(0, yb, 0), a + dir * s1 + v(0, yb, 0), h, opts)
		end
	end
	local cur = 0
	for _, op in ops do
		local l, r = op.s - op.spec.w / 2, op.s + op.spec.w / 2
		seg(cur, l, 0, H)
		seg(l, r, 0, op.spec.b)
		seg(l, r, op.spec.t, H - op.spec.t)
		cur = r
	end
	seg(cur, len, 0, H)

	local rot = if alongX then CFrame.identity else CFrame.Angles(0, math.pi / 2, 0)
	local c = w.c or Vector3.zero
	local n = if not w.ext then 0 elseif alongX then math.sign(w[2] - c.Z) else math.sign(w[1] - c.X)
	for _, op in ops do
		local pos = a + dir * op.s
		local base = ctx.hcf * CFrame.new(pos.X, y0, pos.Z) * rot
		if op.kind == "win" then
			local win = MapKit.window(ctx.p, op.name or "Window", base * CFrame.new(0, 5, 0))
			if op.name then
				win:SetAttribute("WindowId", op.name)
			end
			if n ~= 0 then
				trimPart(ctx, "Sill", base * CFrame.new(0, 2.75, n * 0.6), v(5.6, 0.5, 1.2), C.Trim)
				trimPart(ctx, "Header", base * CFrame.new(0, 7.3, n * 0.55), v(5.6, 0.6, 1.1), C.Trim)
				trimPart(ctx, "Shutter", base * CFrame.new(-2.95, 5, n * 0.7), v(1.5, 4.4, 0.4), ctx.shutter)
				trimPart(ctx, "Shutter", base * CFrame.new(2.95, 5, n * 0.7), v(1.5, 4.4, 0.4), ctx.shutter)
			end
		elseif op.kind == "door" or op.kind == "lock" then
			local door = MapKit.door(ctx.p, op.name or "Door", base * CFrame.new(0, 3.5, 0), op.kind == "lock")
			door:SetAttribute(Names.Attr.BuildingId, ctx.bid)
			if n ~= 0 then
				trimPart(ctx, "DoorHeader", base * CFrame.new(0, 7.35, n * 0.55), v(5.6, 0.7, 1.1), C.Trim)
				trimPart(ctx, "DoorTrim", base * CFrame.new(-2.3, 3.5, n * 0.55), v(0.6, 7, 1.1), C.Trim)
				trimPart(ctx, "DoorTrim", base * CFrame.new(2.3, 3.5, n * 0.55), v(0.6, 7, 1.1), C.Trim)
			end
		end
	end
end

local function extWalls(front: { any }, back: { any }, left: { any }, right: { any }): { { [any]: any } }
	return {
		{ -18, 19.5, 18, 19.5, ops = front, ext = true },
		{ -18, -19.5, 18, -19.5, ops = back, ext = true },
		{ -17.5, -19, -17.5, 19, ops = left, ext = true },
		{ 17.5, -19, 17.5, 19, ops = right, ext = true },
	}
end

local function storey(ctx: Ctx, walls: { { [any]: any } }, y0: number)
	for _, w in walls do
		buildWall(ctx, w, y0)
	end
end

-- Gable roof over (cx, cz) with footprint sx x sz, ridge along X (or Z), base at `top`.
local function roof(ctx: Ctx, cx: number, cz: number, sx: number, sz: number, top: number, rise: number, alongX: boolean)
	local rcf = ctx.hcf * CFrame.new(cx, 0, cz) * (if alongX then CFrame.identity else CFrame.Angles(0, math.pi / 2, 0))
	local W = if alongX then sx else sz
	local D = if alongX then sz else sx
	local half = D / 2
	wedge(ctx.p, "Gable", rcf * CFrame.new(0, top + rise / 2, half / 2) * CFrame.Angles(0, math.pi, 0), v(W, rise, half), ctx.siding)
	wedge(ctx.p, "Gable", rcf * CFrame.new(0, top + rise / 2, -half / 2), v(W, rise, half), ctx.siding)
	local theta = math.atan2(rise, half)
	local L = math.sqrt(half * half + rise * rise)
	local ov = 2
	local len = L + ov + 0.6
	local Wr = W + 2
	local n = math.ceil(Wr / 8)
	local pw = Wr / n
	for _, side in { 1, -1 } do
		local c0 = rcf * CFrame.new(0, top + rise / 2, side * half / 2) * CFrame.Angles(side * theta, 0, 0)
		for i = 1, n do
			part(ctx.p, "Roof", c0 * CFrame.new(-Wr / 2 + (i - 0.5) * pw, 0.5, side * (ov - 0.6) / 2), v(pw, 1, len), ctx.roof, { flammable = true, fuel = 40 })
		end
		-- fascia board along the eave
		local eave = rcf * CFrame.new(0, top - ov * math.sin(theta) + 0.1, side * (half + ov * math.cos(theta)))
		part(ctx.p, "Fascia", eave, v(Wr, 0.8, 0.5), C.Trim, { collide = false })
	end
	part(ctx.p, "Ridge", rcf * CFrame.new(0, top + rise + 0.75, 0), v(Wr + 0.4, 1, 2.2), ctx.roof:Lerp(C.Black, 0.3))
end

local function foundation(ctx: Ctx, x0: number, x1: number, z0: number, z1: number): Part
	return part(ctx.p, "Foundation", ctx.hcf * CFrame.new((x0 + x1) / 2, 0.5, (z0 + z1) / 2), v(x1 - x0 + 0.6, 1, z1 - z0 + 0.6), C.Foundation)
end

local function porch(ctx: Ctx, dx: number)
	local cf = ctx.hcf
	part(ctx.p, "Porch", cf * CFrame.new(dx, 0.5, 22.25), v(8, 1, 4.5), C.WoodLight)
	part(ctx.p, "PorchStep", cf * CFrame.new(dx, 0.25, 25), v(5, 0.5, 1.2), C.Concrete)
	for _, sx in { -3.6, 3.6 } do
		part(ctx.p, "PorchPost", cf * CFrame.new(dx + sx, 5.1, 24), v(0.8, 8.2, 0.8), C.Trim)
	end
	part(ctx.p, "PorchRoof", cf * CFrame.new(dx, 9.5, 22.3), v(9.4, 0.7, 5.4), ctx.roof)
	local lamp = part(ctx.p, "PorchLight", cf * CFrame.new(dx + 3, 7.8, 20.2), v(0.8, 0.8, 0.8), C.Lamp, { shape = Ball, neon = true, collide = false })
	light(lamp, 12, 1.2)
end

-- Doorway (x) in the ground-floor z = 0 wall that leads into the stair hall: lined up with the
-- flight (x 12..17) so a player walks straight onto the first step instead of squeezing past the wall.
local STAIR_GAP = 13.5

local function stairs(ctx: Ctx)
	-- 12 steps of 1 x 1.5, x 12..17, rising from z -1 (ground, hall side) to z -19 (upper landing).
	for i = 1, 12 do
		local z = -1 - (i - 0.5) * 1.5
		local h = (FY0 - 1) + i - 0.15
		part(ctx.p, "Stair", ctx.hcf * CFrame.new(14.5, 1 + h / 2, z), v(5, h, 1.5), if i % 2 == 0 then C.WoodFloor2 else C.WoodFloor, { flammable = i % 3 == 0 })
	end
	part(ctx.p, "StairRail", ctx.hcf * CFrame.new(11.2, FY1 + 1.6, -7.25), v(0.5, 3.2, 13.5), C.Trim)
	part(ctx.p, "StairRailPost", ctx.hcf * CFrame.new(11.2, FY1 + 1.9, -0.9), v(0.8, 3.8, 0.8), C.Wood)
end

local function upperFloor(ctx: Ctx)
	rect(ctx.p, "Floor2", ctx.hcf, -17, 11.5, -19, 19, FY1, 1, C.WoodFloor, true)
	rect(ctx.p, "Floor2", ctx.hcf, 11.5, 17, 0, 19, FY1, 1, C.WoodFloor, true)
end

local function newHouse(model: Model, origin: CFrame, idx: number, nick: string, cx: number, cz: number, look: { [string]: Color3 }): Ctx
	local house = Instance.new("Model")
	house.Name = `House{idx}`
	house:SetAttribute(Names.Attr.BuildingId, `Town.House{idx}`)
	house:SetAttribute("Nickname", nick)
	house.Parent = model
	return {
		p = house,
		hcf = origin * CFrame.new(cx, 0, cz),
		bid = `Town.House{idx}`,
		siding = look.siding,
		inner = look.inner,
		shutter = look.shutter,
		roof = look.roof,
	}
end

local CTR = { length = 4 }
local CTR_SINK = { length = 4, sink = true }
local COFFEE = { width = 4, depth = 2.5, height = 1.6 }
local DINING = { width = 4, depth = 3 }

local function put(ctx: Ctx, kind: string, x: number, y: number, z: number, yaw: number?, opts: { [string]: any }?)
	return prop(kind, ctx.p, at(ctx.hcf, x, y, z, yaw), opts)
end

local function chimney(ctx: Ctx, x: number, z: number, top: number)
	part(ctx.p, "Chimney", ctx.hcf * CFrame.new(x, top / 2 + 4, z), v(3, top - 8, 3), C.Brick, { material = Enum.Material.Brick })
	part(ctx.p, "ChimneyCap", ctx.hcf * CFrame.new(x, top - 3.7, z), v(3.8, 0.6, 3.8), C.Concrete)
end

------------------------------------------------------------------------------------------------
-- House A: "Kitchen fire" (1 storey)
------------------------------------------------------------------------------------------------
local function houseA(model: Model, origin: CFrame)
	local ctx = newHouse(model, origin, 1, "Kitchen fire", -92, 16, {
		siding = C.Cream,
		inner = C.Peach,
		shutter = C.Teal,
		roof = C.RoofBrown,
	})
	local p, cf = ctx.p, ctx.hcf
	p.PrimaryPart = foundation(ctx, -18, 18, -20, 20)
	-- floors: kitchen | living / bath | bedroom
	rect(p, "Floor", cf, -17, -4, 0, 19, FY0, 0.5, C.Tile, false, C.TileC)
	rect(p, "Floor", cf, -4, 17, 0, 19, FY0, 0.5, C.WoodFloor, true)
	rect(p, "Floor", cf, -17, -8, -19, 0, FY0, 0.5, C.Tile, false, C.TileB)
	rect(p, "Floor", cf, -8, 17, -19, 0, FY0, 0.5, C.WoodFloor2, true)

	local walls = extWalls(
		{ { "win", -11 }, { "win", 2 }, { "door", 12, "D1" } },
		{ { "win", -4 }, { "lock", 12, "D2" } },
		{ { "win", 10 }, { "win", -10 } },
		{ { "win", 10 }, { "win", -10, "W2" } }
	)
	table.insert(walls, { -17, 0, 17, 0, ops = { { "gap", -12 }, { "gap", 2 } } })
	table.insert(walls, { -4, 0.5, -4, 19, ops = { { "wide", 10 } } })
	table.insert(walls, { -8, -19, -8, -0.5 })
	storey(ctx, walls, 1)
	roof(ctx, 0, 0, 36, 40, 13, 9, true)
	chimney(ctx, -12, -8, 24)
	porch(ctx, 12)

	-- kitchen
	put(ctx, "counter", -15.6, FY0, 3, -90, CTR_SINK)
	stove(p, at(cf, -15.6, FY0, 7, -90))
	put(ctx, "counter", -15.6, FY0, 11, -90, CTR)
	put(ctx, "fridge", -15.4, FY0, 16.6, -90)
	put(ctx, "table", -9, FY0, 12, 0, DINING)
	put(ctx, "chair", -9, FY0, 9.6, 180)
	put(ctx, "chair", -9, FY0, 14.6, 0)
	ceilingLamp(p, at(cf, -10, 0, 10), 13, false)
	firePoint(p, "F1", ctx.bid, at(cf, -15.6, FY0 + 4.2, 7))
	-- living
	put(ctx, "bookshelf", -2.8, FY0, 14, -90)
	put(ctx, "sofa", 4.5, FY0, 5, -90)
	put(ctx, "table", 10, FY0, 5, 0, COFFEE)
	put(ctx, "tv", 16, FY0, 5, 90)
	rug(p, at(cf, 10, FY0, 5), 10, 7, C.Terracotta)
	put(ctx, "plant", 15.8, FY0, 2)
	put(ctx, "plant", -1.6, FY0, 17.6)
	ceilingLamp(p, at(cf, 8, 0, 7), 13, true)
	firePoint(p, "F2", ctx.bid, at(cf, 4.5, FY0 + 2, 5))
	-- bath
	tub(p, at(cf, -14.8, FY0, -14, 0))
	toilet(p, at(cf, -10.4, FY0, -17.6, 180))
	sink(p, at(cf, -9.4, FY0, -7, 90))
	-- bedroom
	put(ctx, "bed", 4, FY0, -14.6, 180)
	dresser(p, at(cf, -4, FY0, -18, 180))
	rug(p, at(cf, 4, FY0, -8), 7, 4, C.Mustard)
	put(ctx, "plant", 16, FY0, -2)
	ceilingLamp(p, at(cf, 4, 0, -9), 13, false)
	firePoint(p, "F3", ctx.bid, at(cf, 4, FY0 + 2.5, -14.6))
	rescueSpawn(p, "R1", "civilian", ctx.bid, at(cf, 10.5, FY0, -11, 0), "lying")
	-- garden
	put(ctx, "bush", -14, 0.2, 21.8, 0, { flowers = true })
	put(ctx, "bush", 4, 0.2, 21.8, 0, { flowers = true })
	put(ctx, "tree", -14, 0.2, -30)
	put(ctx, "bench", 6, 0.2, -30, 180, { length = 6, flammable = false })
end

------------------------------------------------------------------------------------------------
-- House B: "Cat house" (2 storey, ceiling-collapse living room, cat in upper window W3)
------------------------------------------------------------------------------------------------
local function houseB(model: Model, origin: CFrame)
	local ctx = newHouse(model, origin, 2, "Cat house", -28, 16, {
		siding = C.Salmon,
		inner = C.RoomTeal,
		shutter = C.TealDark,
		roof = C.RoofSlate,
	})
	local p, cf = ctx.p, ctx.hcf
	p.PrimaryPart = foundation(ctx, -18, 18, -20, 20)
	rect(p, "Floor", cf, -17, 4, 0, 19, FY0, 0.5, C.WoodFloor, true) -- living
	rect(p, "Floor", cf, 4, 17, 0, 19, FY0, 0.5, C.WoodFloor2, true) -- hall
	rect(p, "Floor", cf, -17, 4, -19, 0, FY0, 0.5, C.Tile, false, C.TileB) -- kitchen
	rect(p, "Floor", cf, 4, 17, -19, 0, FY0, 0.5, C.WoodFloor2, true) -- stairs

	local g = extWalls(
		{ { "win", -13 }, { "win", -3 }, { "lock", 11, "D4" } },
		{ { "win", -12 }, { "win", -2 } },
		{ { "door", 10, "D3" }, { "win", -10 } },
		{ { "win", 10 } }
	)
	table.insert(g, { -17, 0, 17, 0, ops = { { "gap", -8 }, { "gap", STAIR_GAP } } })
	table.insert(g, { 4, 0.5, 4, 19, ops = { { "gap", 10 } } })
	table.insert(g, { 4, -19, 4, -0.5, ops = { { "gap", -5 } } })
	storey(ctx, g, 1)
	stairs(ctx)
	upperFloor(ctx)

	ctx.inner = C.Lilac
	local u = extWalls(
		{ { "win", -12 }, { "win", -3 }, { "win", 10, "W3" } },
		{ { "win", -10 }, { "win", 0 } },
		{ { "win", 10 }, { "win", -10 } },
		{ { "win", 10 } }
	)
	table.insert(u, { -17, 0, 17, 0, ops = { { "gap", -8 }, { "gap", 6 } } })
	table.insert(u, { 2, 0.5, 2, 19 })
	storey(ctx, u, FY1)
	roof(ctx, 0, 0, 36, 40, 25, 10, true)
	chimney(ctx, -10, -9, 37)
	porch(ctx, 11)

	-- living (ceiling collapse room)
	put(ctx, "sofa", -7, FY0, 2.2, 180)
	put(ctx, "table", -7, FY0, 8, 0, COFFEE)
	flowerPot(p, at(cf, -7, FY0 + 1.6, 8))
	put(ctx, "tv", -8, FY0, 17.6, 0)
	put(ctx, "bookshelf", 2.8, FY0, 8, 90)
	put(ctx, "bookshelf", 2.8, FY0, 14, 90)
	rug(p, at(cf, -7, FY0, 9), 10, 8, C.Red)
	put(ctx, "plant", -15.8, FY0, 2)
	ceilingLamp(p, at(cf, -7, 0, 10), 12, true)
	firePoint(p, "F4", ctx.bid, at(cf, -7, FY0 + 2, 2.4))
	-- hall
	put(ctx, "bench", 16, FY0, 10, 90, { length = 6 })
	rug(p, at(cf, 10.5, FY0, 10), 3.5, 12, C.Mustard)
	put(ctx, "plant", 16, FY0, 17.5)
	firePoint(p, "F6", ctx.bid, at(cf, 9, FY0 + 1, 7))
	-- kitchen
	put(ctx, "counter", -14.5, FY0, -17.6, 180, CTR)
	stove(p, at(cf, -10.5, FY0, -17.6, 180))
	put(ctx, "counter", -6.5, FY0, -17.6, 180, CTR_SINK)
	put(ctx, "fridge", 1.8, FY0, -17.4, 180)
	put(ctx, "table", -8, FY0, -8, 0, DINING)
	put(ctx, "chair", -8, FY0, -5.6, 0)
	put(ctx, "chair", -8, FY0, -10.4, 180)
	ceilingLamp(p, at(cf, -8, 0, -9), 12, false)
	firePoint(p, "F5", ctx.bid, at(cf, -10.5, FY0 + 4.2, -17.6))
	put(ctx, "plant", 6, FY0, -17.5)
	-- upper: bedroom 1
	put(ctx, "bed", -12.5, FY1, 4, -90, { color = C.Teal })
	dresser(p, at(cf, -7.5, FY1, 17.9, 0))
	put(ctx, "bookshelf", 0.8, FY1, 10, 90)
	rug(p, at(cf, -5, FY1, 8), 6, 6, C.Mustard)
	firePoint(p, "F7", ctx.bid, at(cf, -5, FY1 + 1, 8))
	-- upper: bedroom 2 (cat window W3)
	put(ctx, "bed", 13, FY1, 4.5, 90, { color = C.Pink })
	part(p, "CatSill", cf * CFrame.new(10, FY1 + 2.7, 18.3), v(5, 0.6, 1.8), C.Trim)
	part(p, "CatShelf", cf * CFrame.new(10, FY1 + 1.2, 18.3), v(4, 2.4, 1.6), C.WoodLight)
	rescueSpawn(p, "R2", "cat", ctx.bid, at(cf, 10, FY1 + 3, 18.3, 180), "sitting")
	put(ctx, "plant", 4, FY1, 17.5)
	-- landing
	dresser(p, at(cf, -14, FY1, -18.4, 180), C.Wood)
	put(ctx, "plant", -16, FY1, -2)
	rug(p, at(cf, -3, FY1, -10), 12, 5, C.Teal)
	ceilingLamp(p, at(cf, -3, 0, -10), 24, false)
	firePoint(p, "F8", ctx.bid, at(cf, 0, FY1 + 1, -10))
	-- garden
	put(ctx, "bush", -14, 0.2, 21.8, 0, { flowers = true })
	put(ctx, "bush", 3, 0.2, 21.8, 0, { flowers = true })
	put(ctx, "tree", 12, 0.2, -32)
end

------------------------------------------------------------------------------------------------
-- House C: "Garage house" (1 storey + attached garage 16 x 12 x 20, dog + car inside)
------------------------------------------------------------------------------------------------
local function houseC(model: Model, origin: CFrame)
	local ctx = newHouse(model, origin, 3, "Garage house", 36, 16, {
		siding = C.Sage,
		inner = C.CreamIn,
		shutter = C.Mustard,
		roof = C.RoofTerra,
	})
	local p, cf = ctx.p, ctx.hcf
	p.PrimaryPart = foundation(ctx, -18, 18, -20, 20)
	part(p, "GarageFoundation", cf * CFrame.new(26, 0.5, 10), v(16.6, 1, 20.6), C.Foundation)
	rect(p, "Floor", cf, -17, 4, 0, 19, FY0, 0.5, C.WoodFloor, true)
	rect(p, "Floor", cf, 4, 17, 0, 19, FY0, 0.5, C.Tile, false, C.TileC)
	rect(p, "Floor", cf, -17, 2, -19, 0, FY0, 0.5, C.WoodFloor2, true)
	rect(p, "Floor", cf, 2, 17, -19, 0, FY0, 0.5, C.Tile, false, C.TileB)
	rect(p, "GarageFloor", cf, 18.5, 33, 1, 19, FY0, 0.5, C.Concrete)
	part(p, "OilStain", cf * CFrame.new(27, FY0 + 0.05, 9), v(3, 0.2, 4), hex("#6E6A62"), { collide = false })

	local walls = extWalls(
		{ { "win", -13 }, { "door", -6, "Front" }, { "win", 0 }, { "win", 11 } },
		{ { "win", -14 }, { "win", 10 } },
		{ { "win", 10 }, { "win", -10 } },
		{ { "door", 10, "GarageInner" }, { "win", -10 } }
	)
	table.insert(walls, { -17, 0, 17, 0, ops = { { "gap", -8 }, { "gap", 10 } } })
	table.insert(walls, { 4, 0.5, 4, 19, ops = { { "gap", 10 } } })
	table.insert(walls, { 2, -19, 2, -0.5 })
	local gc = v(26, 0, 10)
	table.insert(walls, { 18, 19.5, 34, 19.5, ops = { { "garage", 26 } }, ext = true, c = gc })
	table.insert(walls, { 33.5, 1, 33.5, 19, ops = { { "lock", 10, "GarageSide" } }, ext = true, c = gc })
	table.insert(walls, { 18, 0.5, 34, 0.5, ext = true, c = gc })
	storey(ctx, walls, 1)
	roof(ctx, 0, 0, 36, 40, 13, 9, true)
	roof(ctx, 26, 10, 16, 20, 13, 6, false)
	porch(ctx, -6)

	-- roll-up garage door (closed, not a Door: go in through the house or axe the side door)
	part(p, "RollUpDoor", cf * CFrame.new(26, 1 + 4.5, 19.5), v(12, 9, 0.6), C.White, { flammable = true, fuel = 40 })
	for i = 1, 4 do
		part(p, "RollUpRib", cf * CFrame.new(26, 1 + i * 1.8, 19.9), v(11.6, 0.4, 0.4), C.Trim:Lerp(C.Black, 0.12), { collide = false })
	end
	part(p, "RollUpHandle", cf * CFrame.new(26, 1.9, 20.05), v(2, 0.4, 0.4), C.Black, { collide = false })
	part(p, "GarageLamp", cf * CFrame.new(26, 10.8, 20.3), v(1, 1, 1), C.Lamp, { shape = Ball, neon = true, collide = false })

	-- living
	put(ctx, "tv", -16, FY0, 5, -90)
	put(ctx, "sofa", -5, FY0, 5, 90, { color = C.Terracotta })
	put(ctx, "table", -10.5, FY0, 5, 0, COFFEE)
	put(ctx, "bookshelf", -11, FY0, 1.3, 180)
	rug(p, at(cf, -10, FY0, 5), 9, 7, C.Teal)
	put(ctx, "plant", 2.4, FY0, 2)
	ceilingLamp(p, at(cf, -8, 0, 10), 13, true)
	-- kitchen
	put(ctx, "counter", 7.5, FY0, 17.6, 0, CTR_SINK)
	put(ctx, "counter", 11.5, FY0, 17.6, 0, CTR)
	stove(p, at(cf, 15.3, FY0, 17.6, 0))
	put(ctx, "fridge", 6, FY0, 1.9, 180)
	put(ctx, "table", 10, FY0, 7, 0, DINING)
	put(ctx, "chair", 10, FY0, 4.6, 180)
	-- bedroom
	put(ctx, "bed", -6, FY0, -14.6, 180, { color = C.Mustard })
	dresser(p, at(cf, -16.2, FY0, -4, -90))
	put(ctx, "plant", 0.4, FY0, -17.6)
	rug(p, at(cf, -6, FY0, -8), 6, 4, C.Terracotta)
	-- bath
	tub(p, at(cf, 9, FY0, -16.8, 90))
	toilet(p, at(cf, 15.6, FY0, -11, -90))
	sink(p, at(cf, 4, FY0, -8, -90))
	-- garage
	put(ctx, "car", 27.5, FY0, 9, 180, { color = C.Red, flammable = true })
	workbench(p, at(cf, 26, FY0, 2.4, 180))
	shelfRack(p, at(cf, 19.6, FY0, 15.5, -90))
	firePoint(p, "F9", ctx.bid, at(cf, 26, FY0 + 4, 2.4))
	firePoint(p, "F10", ctx.bid, at(cf, 27.5, FY0 + 2.5, 9))
	rescueSpawn(p, "R3", "dog", ctx.bid, at(cf, 21, FY0, 6, 180), "sitting")
	-- garden + doghouse
	put(ctx, "bush", -14, 0.2, 21.8, 0, { flowers = true })
	put(ctx, "bush", 8, 0.2, 21.8, 0, { flowers = true })
	local dh = at(cf, 10, 0.2, -32, 180)
	part(p, "Doghouse", dh * CFrame.new(0, 1.8, 0), v(4, 3.6, 5), C.Red, { flammable = true })
	wedge(p, "DoghouseRoof", dh * CFrame.new(0, 4.6, 1.3), v(4.8, 2, 2.6), C.RoofBrown)
	wedge(p, "DoghouseRoof", dh * CFrame.new(0, 4.6, -1.3) * CFrame.Angles(0, math.pi, 0), v(4.8, 2, 2.6), C.RoofBrown)
	part(p, "DoghouseHole", dh * CFrame.new(0, 1.3, -2.45), v(2, 2.4, 0.2), C.Black, { collide = false })
	part(p, "DogBowl", dh * CFrame.new(2.6, 0.3, -3), v(0.6, 1.4, 1.4), C.Teal, { shape = Cyl, collide = false }).CFrame = dh
		* CFrame.new(2.6, 0.3, -3)
		* UPRIGHT
	put(ctx, "tree", -12, 0.2, -30)
end

------------------------------------------------------------------------------------------------
-- House D: "Pool house" (2 storey, locked upstairs bedroom with float guy + dog)
------------------------------------------------------------------------------------------------
local function houseD(model: Model, origin: CFrame)
	local ctx = newHouse(model, origin, 4, "Pool house", 100, 16, {
		siding = C.PaleBlue,
		inner = C.CreamIn,
		shutter = C.Terracotta,
		roof = C.RoofBrown,
	})
	local p, cf = ctx.p, ctx.hcf
	p.PrimaryPart = foundation(ctx, -18, 18, -20, 20)
	rect(p, "Floor", cf, -17, 6, 0, 19, FY0, 0.5, C.WoodFloor, true)
	rect(p, "Floor", cf, 6, 17, 0, 19, FY0, 0.5, C.WoodFloor2, true)
	rect(p, "Floor", cf, -17, 4, -19, 0, FY0, 0.5, C.Tile, false, C.TileB)
	rect(p, "Floor", cf, 4, 17, -19, 0, FY0, 0.5, C.WoodFloor2, true)

	local g = extWalls(
		{ { "win", -12 }, { "win", -2 }, { "door", 12, "Front" } },
		{ { "door", -8, "Patio" }, { "win", 0 } },
		{ { "win", 10 }, { "win", -10 } },
		{ { "win", 10 } }
	)
	table.insert(g, { -17, 0, 17, 0, ops = { { "gap", -8 }, { "gap", STAIR_GAP } } })
	table.insert(g, { 6, 0.5, 6, 19, ops = { { "gap", 10 } } })
	table.insert(g, { 4, -19, 4, -0.5, ops = { { "gap", -5 } } })
	storey(ctx, g, 1)
	stairs(ctx)
	upperFloor(ctx)

	ctx.inner = C.Lilac
	local u = extWalls(
		{ { "win", -12 }, { "win", -2 }, { "win", 12 } },
		{ { "win", -10 }, { "win", 0 } },
		{ { "win", 10 }, { "win", -10 } },
		{ { "win", 10 } }
	)
	table.insert(u, { -17, 0, 17, 0, ops = { { "lock", -6, "BedroomDoor" }, { "gap", 8 } } })
	table.insert(u, { 6, 0.5, 6, 19 })
	storey(ctx, u, FY1)
	roof(ctx, 0, 0, 36, 40, 25, 10, true)
	porch(ctx, 12)

	-- living
	put(ctx, "sofa", -7, FY0, 2.2, 180, { color = C.Mustard })
	put(ctx, "tv", -7, FY0, 17.6, 0)
	put(ctx, "table", -7, FY0, 8, 0, COFFEE)
	put(ctx, "bookshelf", 4.8, FY0, 14, 90)
	rug(p, at(cf, -7, FY0, 9), 10, 7, C.Teal)
	put(ctx, "plant", -15.8, FY0, 17.6)
	ceilingLamp(p, at(cf, -7, 0, 10), 12, true)
	-- entry / dining
	put(ctx, "table", 12, FY0, 8, 90, DINING)
	put(ctx, "chair", 9.6, FY0, 8, 90)
	put(ctx, "chair", 14.4, FY0, 8, -90)
	put(ctx, "plant", 16, FY0, 1.8)
	-- kitchen
	put(ctx, "counter", -15.6, FY0, -16, -90, CTR_SINK)
	stove(p, at(cf, -15.6, FY0, -12, -90))
	put(ctx, "counter", -15.6, FY0, -8, -90, CTR)
	put(ctx, "fridge", -15.4, FY0, -3, -90)
	put(ctx, "table", -4, FY0, -10, 0, DINING)
	put(ctx, "chair", -4, FY0, -7.6, 0)
	-- upstairs bedroom (locked door, F11 at the door, F12 bed, float guy + dog)
	put(ctx, "bed", -7, FY1, 14.6, 0, { color = C.Pink })
	dresser(p, at(cf, -15.9, FY1, 5, -90))
	put(ctx, "tv", -15.9, FY1, 15, -90)
	put(ctx, "plant", 4, FY1, 2)
	rug(p, at(cf, -6, FY1, 7), 8, 5, C.Mustard)
	ceilingLamp(p, at(cf, -6, 0, 9), 24, true)
	firePoint(p, "F11", ctx.bid, at(cf, -6, FY1 + 1, 1.8))
	firePoint(p, "F12", ctx.bid, at(cf, -7, FY1 + 2.5, 14.6))
	rescueSpawn(p, "R4", "floatguy", ctx.bid, at(cf, -7, FY1 + 2.5, 14, 0), "sitting")
	rescueSpawn(p, "R5", "dog", ctx.bid, at(cf, -11, FY1, 12, 0), "sitting")
	-- upstairs bath
	tub(p, at(cf, 14.6, FY1, 12, 0))
	toilet(p, at(cf, 8.5, FY1, 17.6, 0))
	sink(p, at(cf, 8, FY1, 6, -90))
	-- landing
	dresser(p, at(cf, -14, FY1, -18.4, 180), C.Wood)
	put(ctx, "plant", -16, FY1, -2)
	rug(p, at(cf, -3, FY1, -10), 12, 5, C.Terracotta)
	-- garden
	put(ctx, "bush", -14, 0.2, 21.8, 0, { flowers = true })
	put(ctx, "bush", 4, 0.2, 21.8, 0, { flowers = true })
end

------------------------------------------------------------------------------------------------
-- Backyard pool behind House D (24 x 14 x 4 deep, infinite hose refill)
------------------------------------------------------------------------------------------------
local POOL = { x0 = 90, x1 = 114, z0 = -29, z1 = -15 }

local function pool(model: Model, origin: CFrame)
	local m = Instance.new("Model")
	m.Name = "Pool"
	m:SetAttribute(Names.Attr.BuildingId, "Town.House4")
	m.Parent = model
	local x0, x1, z0, z1 = POOL.x0, POOL.x1, POOL.z0, POOL.z1
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	-- patio + coping
	rectHole(m, "Patio", origin, 86, 118, -34, -4, x0 - 1, x1 + 1, z0 - 1, z1 + 1, 0.35, 0.6, C.Patio)
	part(m, "Coping", origin * CFrame.new(cx, 0.2, z1 + 0.5), v(x1 - x0 + 2, 0.5, 1), C.White)
	part(m, "Coping", origin * CFrame.new(cx, 0.2, z0 - 0.5), v(x1 - x0 + 2, 0.5, 1), C.White)
	part(m, "Coping", origin * CFrame.new(x0 - 0.5, 0.2, cz), v(1, 0.5, z1 - z0), C.White)
	part(m, "Coping", origin * CFrame.new(x1 + 0.5, 0.2, cz), v(1, 0.5, z1 - z0), C.White)
	-- basin
	part(m, "PoolFloor", origin * CFrame.new(cx, -4.5, cz), v(x1 - x0, 1, z1 - z0), C.PoolDeep)
	part(m, "PoolWall", origin * CFrame.new(cx, -2, z1 - 0.5), v(x1 - x0, 4, 1), C.PoolTile)
	part(m, "PoolWall", origin * CFrame.new(cx, -2, z0 + 0.5), v(x1 - x0, 4, 1), C.PoolTile)
	part(m, "PoolWall", origin * CFrame.new(x0 + 0.5, -2, cz), v(1, 4, z1 - z0 - 2), C.PoolTile)
	part(m, "PoolWall", origin * CFrame.new(x1 - 0.5, -2, cz), v(1, 4, z1 - z0 - 2), C.PoolTile)
	part(m, "PoolStripe", origin * CFrame.new(cx, -3.95, cz), v(x1 - x0 - 4, 0.2, 0.8), C.TealDark, { collide = false })
	local water = part(m, "Water", origin * CFrame.new(cx, -2.3, cz), v(x1 - x0 - 2, 3.4, z1 - z0 - 2), C.Water, {
		transparency = 0.3,
		collide = false,
		tags = { Names.Tag.Hydrant },
	})
	water.CanQuery = true
	water:SetAttribute("Pool", true)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Refill"
	prompt.ObjectText = "Pool"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = water
	-- ladder
	for _, dz in { -1, 1 } do
		part(m, "LadderRail", origin * CFrame.new(x1 - 1.2, -0.4, z1 - 4 + dz), v(0.4, 4, 0.4), C.Chrome, { collide = false })
	end
	part(m, "LadderTop", origin * CFrame.new(x1 - 0.8, 1.6, z1 - 4), v(1.2, 0.4, 2.4), C.Chrome, { collide = false })
	-- pink donut float (8 balls in a ring) + beach ball
	local fc = origin * CFrame.new(cx - 5, -0.55, cz + 1)
	for i = 0, 7 do
		local a = i * math.pi / 4
		part(m, "Float", fc * CFrame.new(math.cos(a) * 1.9, 0, math.sin(a) * 1.9), v(1.7, 1.7, 1.7), C.Pink, { shape = Ball, collide = false })
	end
	part(m, "BeachBall", origin * CFrame.new(cx + 6, -0.3, cz - 2), v(1.8, 1.8, 1.8), C.Mustard, { shape = Ball, collide = false })
	-- loungers + umbrella on the patio
	for _, lx in { 95, 101 } do
		local lc = origin * CFrame.new(lx, 0.35, -9) * CFrame.Angles(0, math.pi, 0)
		part(m, "Lounger", lc * CFrame.new(0, 0.9, 0.8), v(2.6, 0.5, 4.4), C.White)
		part(m, "LoungerLegs", lc * CFrame.new(0, 0.4, 0.8), v(2.2, 0.8, 3.6), C.Chrome)
		wedge(m, "LoungerBack", lc * CFrame.new(0, 1.9, 2.0), v(2.6, 1.8, 2.2), C.Teal)
	end
	local uc = origin * CFrame.new(107, 0.35, -9)
	part(m, "UmbrellaPole", uc * CFrame.new(0, 4, 0), v(0.4, 8, 0.4), C.White)
	part(m, "Umbrella", uc * CFrame.new(0, 7.8, 0) * UPRIGHT, v(0.8, 8, 8), C.Terracotta, { shape = Cyl, collide = false })
	part(m, "UmbrellaTop", uc * CFrame.new(0, 8.4, 0), v(1, 1, 1), C.White, { shape = Ball, collide = false })
	part(m, "PoolTable", uc * CFrame.new(0, 1.4, 0) * UPRIGHT, v(0.4, 3, 3), C.White, { shape = Cyl })
end

------------------------------------------------------------------------------------------------
-- Street, lawns, fences, street furniture
------------------------------------------------------------------------------------------------
local function picketFence(parent: Instance, origin: CFrame, x0: number, x1: number, z: number)
	local len = x1 - x0
	if len < 1 then
		return
	end
	local n = math.max(2, math.floor(len / 1.8) + 1)
	local step = len / (n - 1)
	for i = 0, n - 1 do
		part(parent, "Picket", origin * CFrame.new(x0 + i * step, 0.2 + 1.5, z), v(0.6, 3, 0.4), C.Trim)
	end
	part(parent, "FenceRail", origin * CFrame.new((x0 + x1) / 2, 2.4, z + 0.4), v(len, 0.5, 0.4), C.Trim)
	part(parent, "FenceRail", origin * CFrame.new((x0 + x1) / 2, 1.0, z + 0.4), v(len, 0.5, 0.4), C.Trim)
end

local function boardFence(parent: Instance, origin: CFrame, a: Vector3, b: Vector3, h: number)
	local d = b - a
	local len = d.Magnitude
	local dir = d.Unit
	local n = math.ceil(len / 8 - 1e-6)
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * len / n) + v(0, h / 2, 0)
		part(parent, "FenceBoard", origin * CFrame.lookAt(mid, mid + dir), v(0.6, h, len / n), C.Fence)
	end
	for i = 0, n do
		local q = a + dir * (i * len / n) + v(0, (h + 0.6) / 2, 0)
		part(parent, "FencePost", origin * CFrame.new(q), v(1, h + 0.6, 1), C.FenceDark)
	end
end

local function streetSign(parent: Instance, cf: CFrame)
	part(parent, "SignPost", cf * CFrame.new(0, 5, 0), v(0.5, 10, 0.5), hex("#3A3A40"))
	local board = part(parent, "StreetSign", cf * CFrame.new(0, 9.6, 0), v(8, 1.6, 0.4), hex("#2F7A4A"))
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		local gui = Instance.new("SurfaceGui")
		gui.Face = face
		gui.CanvasSize = Vector2.new(400, 80)
		local t = Instance.new("TextLabel")
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundTransparency = 1
		t.Text = "MAPLE ST"
		t.TextScaled = true
		t.Font = Enum.Font.FredokaOne
		t.TextColor3 = Color3.new(1, 1, 1)
		t.Parent = gui
		gui.Parent = board
	end
end

local function street(model: Model, origin: CFrame, rng: Random)
	local s = Instance.new("Model")
	s.Name = "Street"
	s.Parent = model
	local px0, px1, pz0, pz1 = POOL.x0, POOL.x1, POOL.z0, POOL.z1
	-- ground: base grass for the whole slot, block lawn on top; both leave the pool hole open
	rectHole(s, "Ground", origin, -200, 200, -200, 200, px0, px1, pz0, pz1, 0, 2, C.Grass)
	rectHole(s, "Lawn", origin, -130, 130, -40, 50, px0, px1, pz0, pz1, 0.2, 0.4, C.Lawn)
	rect(s, "Verge", origin, -200, 200, 78, 108, 0.2, 0.4, C.Lawn)
	-- road + sidewalks + kerbs
	rect(s, "Road", origin, -200, 200, 56, 72, 0.12, 0.6, C.Asphalt)
	rect(s, "Sidewalk", origin, -200, 200, 50, 56, 0.6, 1, C.Sidewalk)
	rect(s, "Sidewalk", origin, -200, 200, 72, 78, 0.6, 1, C.Sidewalk)
	rect(s, "Kerb", origin, -200, 200, 55.2, 56, 0.66, 1, C.Kerb)
	rect(s, "Kerb", origin, -200, 200, 72, 72.8, 0.66, 1, C.Kerb)
	for x = -196, 196, 10 do
		if math.abs(x + 60) > 6 then
			part(s, "LaneDash", origin * CFrame.new(x, 0.12, 64), v(5, 0.2, 0.5), C.LineYellow, { collide = false })
		end
	end
	part(s, "EdgeLine", origin * CFrame.new(0, 0.12, 57.2), v(400, 0.2, 0.4), C.Trim, { collide = false })
	part(s, "EdgeLine", origin * CFrame.new(0, 0.12, 70.8), v(400, 0.2, 0.4), C.Trim, { collide = false })
	for k = 0, 4 do
		part(s, "Zebra", origin * CFrame.new(-60, 0.13, 57.6 + k * 3.2), v(6, 0.2, 1.6), C.White, { collide = false })
	end
	-- front paths (porch -> sidewalk) and House C driveway
	for _, px in { -80, -17, 30, 112 } do
		rect(s, "Path", origin, px - 1.6, px + 1.6, 40.5, 50, 0.3, 0.4, C.Patio)
	end
	rect(s, "Driveway", origin, 56, 68, 36, 50, 0.3, 0.4, C.Concrete)
	-- front picket fences (gaps at paths and the driveway)
	for _, seg in { { -116, -82 }, { -78, -68 }, { -52, -19 }, { -15, -4 }, { 12, 28 }, { 32, 54 }, { 76, 110 }, { 114, 124 } } do
		picketFence(s, origin, seg[1], seg[2], 49.2) -- local: ~half the parts of PropKit.fence
	end
	-- back fence, block ends and backyard dividers
	boardFence(s, origin, v(-130, 0.2, -40), v(130, 0.2, -40), 6)
	boardFence(s, origin, v(-130, 0.2, -40), v(-130, 0.2, -4), 6)
	boardFence(s, origin, v(130, 0.2, -40), v(130, 0.2, -4), 6)
	for _, fx in { -60, 4, 74 } do
		boardFence(s, origin, v(fx, 0.2, -40), v(fx, 0.2, -4), 5)
	end
	-- hydrants H1..H3 on the house-side kerb
	for i, hx in { -90, 10, 100 } do
		local h = MapKit.hydrant(s, origin * CFrame.new(hx, 0.6, 54.4))
		h.Name = `H{i}`
		h:SetAttribute("HydrantId", `H{i}`)
	end
	-- mailboxes
	for _, px in { -80, -17, 30, 112 } do
		prop("mailbox", s, origin * CFrame.new(px + 3.5, 0.6, 51.2) * CFrame.Angles(0, math.pi, 0))
	end
	-- street lamps (both sides)
	for _, lx in { -170, -124, -60, 4, 74, 140 } do
		prop("streetLamp", s, origin * CFrame.new(lx, 0.6, 54.8) * CFrame.Angles(0, math.pi, 0))
	end
	for _, lx in { -92, -28, 36, 100, 170 } do
		prop("streetLamp", s, origin * CFrame.new(lx, 0.6, 73.2))
	end
	streetSign(s, origin * CFrame.new(-128, 0.6, 52.6))
	-- parked cars
	prop("car", s, origin * CFrame.new(-22, 0.12, 68) * CFrame.Angles(0, math.rad(-90), 0), { color = C.Teal, eyes = true })
	prop("car", s, origin * CFrame.new(86, 0.12, 60.2) * CFrame.Angles(0, math.rad(90), 0), { color = C.Mustard })
	-- trees: front lawns, behind the back fence, across the street
	for _, t in { { -112, 44 }, { -48, 44 }, { 16, 44 }, { 120, 44 }, { -150, 30 }, { 150, 30 } } do
		prop("tree", s, origin * CFrame.new(t[1], 0.2, t[2]), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	for _, tx in { -150, -110, -70, -25, 20, 60, 130, 165 } do
		prop("tree", s, origin * CFrame.new(tx, 0, -50 - rng:NextInteger(0, 8)), { variant = rng:NextInteger(1, 3), size = rng:NextNumber(1, 1.3), flammable = false })
	end
	for _, tx in { -165, -120, 60, 120, 175 } do
		prop("tree", s, origin * CFrame.new(tx, 0.2, 96), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	for _, b in { { -140, 84 }, { -70, 83 }, { -10, 84 }, { 40, 83 }, { 90, 84 }, { -128, -36 }, { 126, -36 } } do
		prop("bush", s, origin * CFrame.new(b[1], 0.2, b[2]), { flammable = false })
	end
	prop("bench", s, origin * CFrame.new(-30, 0.2, 81))
	prop("bench", s, origin * CFrame.new(80, 0.2, 81))
end

function TownBuilder.Build(model: Model, origin: CFrame, rng: Random)
	model:SetAttribute("DisplayName", "Maple Street")
	-- Shift 8 north so the road centre sits on slot z=56 and joins the station road (world x=200).
	local o = origin * CFrame.new(0, 0, -8)
	street(model, o, rng) -- rng only varies cosmetic trees; the gameplay layout is fixed
	houseA(model, o)
	houseB(model, o)
	houseC(model, o)
	houseD(model, o)
	pool(model, o)
end

return TownBuilder
