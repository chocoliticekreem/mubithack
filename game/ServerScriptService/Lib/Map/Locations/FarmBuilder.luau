-- FarmBuilder [owner: G2]. SUNNY ACRES: golden-hour farm (docs/game/05 §2.6, docs/game/02 "Golden Farm").
-- Slot 4. Local frame: origin = slot centre on the ground, +X east, +Z south (toward the default
-- preview camera). Everything gameplay-relevant is found by tag/attribute, never by coordinate.
--   Dirt road        Z 64..76 (whole slot width), entrance arch at X 15, TruckSpot on the road.
--   Farmyard         X -70..100, Z -28..62: haystacks HAY1..3, the smoking farmer, bale stack.
--   Red barn         32 x 24, centre (40, -2), gambrel roof, hayloft, stalls, locked east door.
--   Farmhouse        28 x 20, centre (-100, 14), porch facing the road.
--   Wheat field      X -150..150, Z -130..-36, behind a post-and-rail fence at Z -33.
--   Silo, windmill, chicken coop + pen, duck pond (refill, tagged Hydrant), tractor, scarecrow.
-- Fire starts (tag FireStart on Flammable parts, attr FireId): F1 haystack HAY1 (the cigarette),
--   F2 dry grass by the field fence, F3 wheat at the field edge, F4 bale stack by the barn.
-- Rescue spawns (invisible 2x2x2, tag RescueSpawn, attrs Kind/Pose/SpawnId/BuildingId):
--   R1 dazed farmer by HAY1 (Kind "Farmer" if NpcBuilder knows it else "Civilian", Smoking = true),
--   R2 Dog in a barn stall, R3 Cat in the hayloft, R4 Civilian lying in the farmhouse bedroom.
-- Lots of small Flammable dry-grass tufts (<= 4 studs) link the haystacks, fence, field and barn.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local FarmBuilder = {}
FarmBuilder.Id = "Farm"
FarmBuilder.Slot = 4

local LOCATION = "Farm"
local TAG_TRUCKSPOT = (Names.Tag :: any).TruckSpot or "TruckSpot"
local TAG_PLAYERSPAWN = (Names.Tag :: any).PlayerSpawn or "PlayerSpawn"
local ATTR_SLOT = (Names.Attr :: any).Slot or "Slot"

local function hex(s: string): Color3
	return Color3.fromHex(s)
end

local C = {
	Grass = hex("#8FA14A"),
	GrassDark = hex("#7A8E40"),
	Pasture = hex("#9DB04E"),
	Dirt = hex("#B08A5E"),
	DirtDark = hex("#8A6A48"),
	Road = hex("#A8825A"),
	Rut = hex("#8A6A48"),
	Soil = hex("#6E4A30"),
	Stubble = hex("#D9B46A"),
	Wheat = hex("#E3AB56"),
	WheatLight = hex("#EFC46E"),
	WheatDark = hex("#C98A3A"),
	DryGrass = hex("#C9893F"),
	DryGrass2 = hex("#D9A055"),
	DryGrass3 = hex("#B8783A"),
	BarnRed = hex("#A33A2A"),
	BarnRedDark = hex("#7E2A20"),
	Trim = hex("#F2EDE4"),
	BarnRoof = hex("#4E3A36"),
	RoofBrown = hex("#5A3A32"),
	Fence = hex("#6B4A35"),
	FenceDark = hex("#553826"),
	Hay = hex("#E3AB56"),
	HayDark = hex("#C9923F"),
	Siding = hex("#E8D3A8"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	WoodFloor = hex("#C8683A"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	Concrete = hex("#B8B2A6"),
	Foundation = hex("#7A6A62"),
	Metal = hex("#A8B4B8"),
	MetalDark = hex("#6E7A80"),
	Chrome = hex("#D6D8DC"),
	Water = hex("#61A8B6"),
	PondBed = hex("#4A6A5A"),
	Stone = hex("#9A9086"),
	StoneDark = hex("#7A7268"),
	Black = hex("#1A1714"),
	White = hex("#F7F4EE"),
	Lamp = hex("#FFC97A"),
	TractorGreen = hex("#4E8A3A"),
	TractorDark = hex("#3A6A2A"),
	Yellow = hex("#E8B83A"),
	Red = hex("#C8232B"),
	Brick = hex("#BF4835"),
	Orange = hex("#F28C28"),
	Leaf = hex("#6F9A3A"),
	Leaf2 = hex("#8AAF4A"),
	Trunk = hex("#7A3A1E"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Plaid = hex("#CF442B"),
	Denim = hex("#56688A"),
	Burlap = hex("#C9A06A"),
	Pink = hex("#F29A8A"),
	CattailBrown = hex("#6A4028"),
	Ember = hex("#FF5A1F"),
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

-- Upright cylinder centred at cf (height along Y).
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

-- WedgePart / CornerWedgePart with the same options as MapKit.part.
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

-- Rect slab with top at `top`, chunked into <= 8-stud tiles when flammable.
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

-- Flat disc (cylinder lying on the ground) with its top at `top`.
local function disc(parent: Instance, name: string, cf: CFrame, x: number, z: number, d: number, top: number, thick: number, color: Color3, extra: { [string]: any }?): Part
	return vcyl(parent, name, cf * CFrame.new(x, top - thick / 2, z), thick, d, color, extra)
end

-- Beam between two local points (square section `w`).
local function beam(parent: Instance, name: string, cf: CFrame, a: Vector3, b: Vector3, w: number, color: Color3, extra: { [string]: any }?): Part
	local mid = (a + b) / 2
	return part(parent, name, cf * CFrame.lookAt(mid, b), v(w, w, (b - a).Magnitude), color, extra)
end

-- Gable triangle in rcf's X-Y plane at z = zc: full height at x = xTall, zero at x = xZero.
local function gableTri(parent: Instance, name: string, rcf: CFrame, xTall: number, xZero: number, y0: number, y1: number, zc: number, thick: number, color: Color3, extra: { [string]: any }?)
	local yaw = if xZero > xTall then -math.pi / 2 else math.pi / 2
	shaped("WedgePart", parent, name, rcf * CFrame.new((xTall + xZero) / 2, (y0 + y1) / 2, zc) * CFrame.Angles(0, yaw, 0), v(thick, y1 - y0, math.abs(xZero - xTall)), color, extra)
end

-- Sloped roof panel in rcf's X-Y profile from (xa, ya) to (xb, yb) (xa < xb), running z0..z1 along
-- rcf Z. Underside sits on the profile line; extA / extB extend past each end. Chunked <= 8 studs.
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

-- Wall from a to b (local base points, a.Y = base) with openings. ops = { {s, w, bot, top, kind, name?} },
-- kind "win" | "door" | "lock" | "gap". n = +1/-1 picks the exterior side for trim (nil = no trim).
type Op = { s: number, w: number, bot: number, top: number, kind: string, name: string? }

local function buildWall(parent: Instance, name: string, cf: CFrame, a: Vector3, b: Vector3, h: number, opts: { [string]: any }, ops: { Op }, n: number?, trim: Color3?, shutter: Color3?, bid: string)
	local d = b - a
	local len = d.Magnitude
	local dir = d.Unit
	table.sort(ops, function(p, q)
		return p.s < q.s
	end)
	local function seg(s0: number, s1: number, yb: number, hh: number)
		if s1 - s0 > 0.05 and hh > 0.05 then
			MapKit.wall(parent, name, cf, a + dir * s0 + v(0, yb, 0), a + dir * s1 + v(0, yb, 0), hh, opts :: any)
		end
	end
	local cur = 0
	for _, op in ops do
		local l, r = op.s - op.w / 2, op.s + op.w / 2
		seg(cur, l, 0, h)
		seg(l, r, 0, op.bot)
		seg(l, r, op.top, h - op.top)
		cur = r
	end
	seg(cur, len, 0, h)

	local rot = CFrame.fromMatrix(Vector3.zero, dir, Vector3.yAxis)
	for _, op in ops do
		local base = cf * CFrame.new(a + dir * op.s) * rot
		if op.kind == "win" then
			MapKit.window(parent, op.name or "Window", base * CFrame.new(0, (op.bot + op.top) / 2, 0))
			if n and trim then
				part(parent, "Sill", base * CFrame.new(0, op.bot - 0.25, n * 0.6), v(op.w + 1.4, 0.5, 1.2), trim, { collide = false })
				part(parent, "Header", base * CFrame.new(0, op.top + 0.3, n * 0.55), v(op.w + 1.4, 0.6, 1.1), trim, { collide = false })
				if shutter then
					local mid = (op.bot + op.top) / 2
					local sh = op.top - op.bot + 0.4
					part(parent, "Shutter", base * CFrame.new(-(op.w / 2 + 0.95), mid, n * 0.7), v(1.5, sh, 0.4), shutter, { collide = false })
					part(parent, "Shutter", base * CFrame.new(op.w / 2 + 0.95, mid, n * 0.7), v(1.5, sh, 0.4), shutter, { collide = false })
				end
			end
		elseif op.kind == "door" or op.kind == "lock" then
			local door = MapKit.door(parent, op.name or "Door", base * CFrame.new(0, 3.5, 0), op.kind == "lock")
			door:SetAttribute(Names.Attr.BuildingId, bid)
			if n and trim then
				part(parent, "DoorHeader", base * CFrame.new(0, 7.35, n * 0.55), v(op.w + 1.6, 0.7, 1.1), trim, { collide = false })
				part(parent, "DoorTrim", base * CFrame.new(-(op.w / 2 + 0.3), 3.5, n * 0.55), v(0.6, 7, 1.1), trim, { collide = false })
				part(parent, "DoorTrim", base * CFrame.new(op.w / 2 + 0.3, 3.5, n * 0.55), v(0.6, 7, 1.1), trim, { collide = false })
			end
		end
	end
end

local function win(s: number, name: string?): Op
	return { s = s, w = 4, bot = 3, top = 7, kind = "win", name = name }
end
local function hiWin(s: number): Op
	return { s = s, w = 4, bot = 4, top = 8, kind = "win" }
end
local function door(s: number, locked: boolean?, name: string?): Op
	return { s = s, w = 4, bot = 0, top = 7, kind = if locked then "lock" else "door", name = name }
end
local function gap(s: number, w: number, top: number): Op
	return { s = s, w = w, bot = 0, top = top, kind = "gap" }
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
				warn(`[FarmBuilder] PropKit unavailable: {res}`)
			end
		end
	end
	return propKit
end

type Box = { any } -- { offset, size, color, flammable?, shape?, rotation? }

local FALLBACK: { [string]: { Box } } = {
	haystack = {
		{ v(0, 2.5, 0), v(5, 6, 6), C.Hay, true, Cyl, UPRIGHT },
		{ v(0, 4.4, 0), v(6, 6, 6), C.Hay, true, Ball },
	},
	tree = {
		{ v(0, 3.5, 0), v(7, 1.2, 1.2), C.Trunk, false, Cyl, UPRIGHT },
		{ v(0, 8, 0), v(8, 8, 8), C.Leaf, false, Ball },
		{ v(1.6, 10, 1), v(5.5, 5.5, 5.5), C.Leaf2, false, Ball },
	},
	bush = {
		{ v(0, 1.3, 0), v(3.4, 3.4, 3.4), C.Leaf, false, Ball },
	},
	ladder = {
		{ v(-1.3, 4.5, 0), v(0.5, 9, 0.5), C.Fence, true },
		{ v(1.3, 4.5, 0), v(0.5, 9, 0.5), C.Fence, true },
		{ v(0, 2, 0), v(2.6, 0.4, 0.4), C.WoodLight, true },
		{ v(0, 4.4, 0), v(2.6, 0.4, 0.4), C.WoodLight, true },
		{ v(0, 6.8, 0), v(2.6, 0.4, 0.4), C.WoodLight, true },
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
	sofa = {
		{ v(0, 0.9, 0.1), v(8, 1.8, 2.8), C.Teal, true },
		{ v(0, 2.3, 1.1), v(8, 2.8, 0.8), C.TealDark, true },
	},
	bed = {
		{ v(0, 0.8, 0), v(5, 1.6, 8), C.Wood, true },
		{ v(0, 2, 0.2), v(4.6, 0.8, 7.4), C.White, true },
		{ v(0, 2.1, -1.4), v(4.8, 1, 4.8), C.Plaid, true },
	},
	bookshelf = {
		{ v(0, 3.5, 0), v(4, 7, 1.4), C.Wood, true },
	},
	counter = {
		{ v(0, 1.6, 0), v(6, 3.2, 2.4), C.Siding, true },
		{ v(0, 3.4, 0), v(6.2, 0.4, 2.6), C.Wood, true },
	},
	fridge = {
		{ v(0, 3.5, 0), v(3, 7, 2.6), C.White },
	},
	mailbox = {
		{ v(0, 1.6, 0), v(0.5, 3.2, 0.5), C.Wood },
		{ v(0, 3.6, 0), v(1.2, 1.1, 2), C.Red },
	},
	plant = {
		{ v(0, 0.7, 0), v(1.4, 1.4, 1.4), C.Terracotta },
		{ v(0, 2.2, 0), v(2.2, 2.2, 2.2), C.Leaf, true, Ball },
	},
}

local function boxModel(parent: Instance, name: string, cf: CFrame, boxes: { Box }, opts: { [string]: any }?): Model
	local m = Instance.new("Model")
	m.Name = name
	local s: number = (opts and opts.size) or 1
	for i, b in boxes do
		local flam = b[4] and not (opts and opts.flammable == false)
		local p = part(m, name, cf * CFrame.new(b[1] * s) * (b[6] or CFrame.identity), b[2] * s, b[3], {
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
		warn(`[FarmBuilder] PropKit.{kind} failed: {res}`)
	end
	local fb = FALLBACK[kind]
	if fb then
		return boxModel(parent, kind, cf, fb, opts)
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

-- Tags an existing Flammable part as a fire start.
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
end

-- cf = ground/seat point, facing -Z.
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

-- "Farmer" when the NPC builder knows that kind, else "Civilian" (the farmer is dressed by attrs).
local function farmerKind(): string
	local lib = script.Parent.Parent.Parent
	local rescue = lib and lib:FindFirstChild("Rescue")
	local mod = rescue and rescue:FindFirstChild("NpcBuilder")
	if mod and mod:IsA("ModuleScript") then
		local ok, nb = pcall(require, mod)
		if ok and type(nb) == "table" and type(nb.Kinds) == "table" and table.find(nb.Kinds, "Farmer") then
			return "Farmer"
		end
	end
	return "Civilian"
end

------------------------------------------------------------------------------------------------
-- Small builders
------------------------------------------------------------------------------------------------
-- Post-and-rail fence from a to b (ground points). Flammable so fire runs along it.
local function railFence(parent: Instance, cf: CFrame, a: Vector3, b: Vector3)
	local d = b - a
	local len = d.Magnitude
	if len < 1 then
		return
	end
	local dir = d.Unit
	local n = math.max(1, math.ceil(len / 8 - 1e-6))
	local step = len / n
	local F = { flammable = true, fuel = 20 }
	for i = 0, n do
		local q = a + dir * (i * step)
		part(parent, "FencePost", cf * CFrame.new(q + v(0, 2, 0)), v(0.9, 4, 0.9), C.FenceDark, F)
	end
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * step)
		for _, y in { 1.5, 3.1 } do
			part(parent, "FenceRail", cf * CFrame.lookAt(mid + v(0, y, 0), mid + v(0, y, 0) + dir), v(0.4, 0.6, step + 0.6), C.Fence, F)
		end
	end
end

-- Small spiky dry-grass tuft (<= 4 studs), Flammable.
local TUFT_COLORS = { C.DryGrass, C.DryGrass2, C.DryGrass3, C.WheatDark }
local function tuft(parent: Instance, cf: CFrame, rng: Random): BasePart
	local w, h, d = rng:NextNumber(1.6, 3.2), rng:NextNumber(1.2, 2.4), rng:NextNumber(1.6, 3.2)
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

local function bale(parent: Instance, cf: CFrame, color: Color3?): Part
	local p = part(parent, "HayBale", cf * CFrame.new(0, 1.5, 0), v(4, 3, 3), color or C.Hay, { flammable = true, fuel = 30, material = FABRIC })
	part(parent, "Twine", cf * CFrame.new(-1, 1.5, 0), v(0.25, 3.1, 3.1), C.HayDark, { collide = false })
	part(parent, "Twine", cf * CFrame.new(1, 1.5, 0), v(0.25, 3.1, 3.1), C.HayDark, { collide = false })
	return p
end

local function roundBale(parent: Instance, cf: CFrame)
	part(parent, "RoundBale", cf * CFrame.new(0, 2.5, 0), v(4.4, 5, 5), C.Hay, { shape = Cyl, flammable = true, fuel = 30, material = FABRIC })
	part(parent, "BaleFace", cf * CFrame.new(0, 2.5, 0), v(4.6, 3.2, 3.2), C.HayDark, { shape = Cyl, collide = false, material = FABRIC })
end

local function chicken(parent: Instance, cf: CFrame, color: Color3)
	local m = Instance.new("Model")
	m.Name = "Chicken"
	local nc = { collide = false }
	local body = ball(m, "Body", cf * CFrame.new(0, 1.3, 0), 1.7, color, nc)
	ball(m, "Head", cf * CFrame.new(0, 2.3, -0.7), 1.05, color, nc)
	part(m, "Beak", cf * CFrame.new(0, 2.25, -1.3), v(0.35, 0.3, 0.45), C.Orange, nc)
	part(m, "Comb", cf * CFrame.new(0, 2.95, -0.7), v(0.2, 0.5, 0.7), C.Red, nc)
	part(m, "Wattle", cf * CFrame.new(0, 1.9, -1.2), v(0.2, 0.4, 0.2), C.Red, nc)
	shaped("WedgePart", m, "Tail", cf * CFrame.new(0, 1.9, 0.85), v(0.6, 1.1, 0.8), color, nc)
	part(m, "Legs", cf * CFrame.new(0, 0.25, 0), v(0.6, 0.5, 0.2), C.Orange, nc)
	m.PrimaryPart = body
	m.Parent = parent
end

local function duck(parent: Instance, cf: CFrame, mallard: boolean)
	local m = Instance.new("Model")
	m.Name = "Duck"
	local nc = { collide = false }
	local bodyC = if mallard then hex("#8A7A6A") else C.White
	local body = ball(m, "Body", cf * CFrame.new(0, 0.5, 0), 1.9, bodyC, nc)
	ball(m, "Head", cf * CFrame.new(0, 1.55, -0.75), 1.1, if mallard then hex("#2E7A4A") else C.White, nc)
	part(m, "Bill", cf * CFrame.new(0, 1.45, -1.45), v(0.6, 0.25, 0.7), C.Yellow, nc)
	shaped("WedgePart", m, "Tail", cf * CFrame.new(0, 0.9, 1.0), v(0.7, 0.7, 0.7), bodyC, nc)
	m.PrimaryPart = body
	m.Parent = parent
end

local function cow(parent: Instance, cf: CFrame)
	local m = Instance.new("Model")
	m.Name = "Cow"
	local nc = { collide = false }
	local body = part(m, "Body", cf * CFrame.new(0, 3.6, 0), v(3.2, 3, 5.6), C.White, nc)
	part(m, "Patch", cf * CFrame.new(1.62, 3.9, 0.8), v(0.1, 1.6, 2.2), C.Black, nc)
	part(m, "Patch", cf * CFrame.new(-1.62, 3.4, -1), v(0.1, 1.4, 1.8), C.Black, nc)
	part(m, "Patch", cf * CFrame.new(0.4, 5.12, 1.4), v(1.6, 0.1, 1.6), C.Black, nc)
	part(m, "Head", cf * CFrame.new(0, 4.6, -3.5), v(2.2, 2.2, 2), C.White, nc)
	part(m, "Muzzle", cf * CFrame.new(0, 4, -4.6), v(2, 1.1, 0.6), C.Pink, nc)
	part(m, "Horn", cf * CFrame.new(-1, 6, -3.4), v(0.4, 0.8, 0.4), C.Trim, nc)
	part(m, "Horn", cf * CFrame.new(1, 6, -3.4), v(0.4, 0.8, 0.4), C.Trim, nc)
	part(m, "Ear", cf * CFrame.new(-1.5, 5.3, -3.3), v(0.9, 0.4, 0.5), C.Black, nc)
	part(m, "Ear", cf * CFrame.new(1.5, 5.3, -3.3), v(0.9, 0.4, 0.5), C.Black, nc)
	for _, lx in { -1, 1 } do
		for _, lz in { -2, 2 } do
			part(m, "Leg", cf * CFrame.new(lx, 1.05, lz), v(0.8, 2.1, 0.8), C.White, nc)
		end
	end
	part(m, "Tail", cf * CFrame.new(0, 3.6, 2.9), v(0.25, 2.2, 0.25), C.Black, nc)
	MapKit.googlyEyes(m, cf * CFrame.new(0, 5.3, -4.55), 0.8)
	m.PrimaryPart = body
	m.Parent = parent
end

------------------------------------------------------------------------------------------------
-- Ground, road, entrance
------------------------------------------------------------------------------------------------
local function ground(model: Model, o: CFrame, rng: Random)
	local g = Instance.new("Model")
	g.Name = "Ground"
	g.Parent = model
	part(g, "Grass", o * CFrame.new(0, -1, 0), v(400, 2, 400), C.Grass)
	part(g, "Pasture", o * CFrame.new(0, 0.05, 140), v(400, 0.1, 120), C.Pasture)
	-- farmyard dirt and darker wheel-worn patches
	part(g, "Yard", o * CFrame.new(15, 0.05, 17), v(170, 0.1, 90), C.Dirt)
	part(g, "Yard", o * CFrame.new(-95, 0.05, 48), v(14, 0.1, 30), C.Dirt) -- farmhouse drive
	for _, p in { { -10, 40, 30, 16 }, { 40, 20, 26, 10 }, { 80, 52, 30, 12 } } do
		part(g, "YardWorn", o * CFrame.new(p[1], 0.08, p[2]), v(p[3], 0.1, p[4]), C.DirtDark)
	end
	-- dirt road with tyre ruts and a grass median
	part(g, "Road", o * CFrame.new(0, 0.1, 70), v(400, 0.2, 12), C.Road)
	part(g, "Rut", o * CFrame.new(0, 0.12, 66.6), v(400, 0.2, 2.2), C.Rut)
	part(g, "Rut", o * CFrame.new(0, 0.12, 73.4), v(400, 0.2, 2.2), C.Rut)
	part(g, "Median", o * CFrame.new(0, 0.14, 70), v(400, 0.2, 1.6), C.GrassDark)
	-- a few darker grass blotches for texture
	for _ = 1, 10 do
		local x, z = rng:NextNumber(-190, 190), rng:NextNumber(90, 190)
		disc(g, "GrassPatch", o, x, z, rng:NextNumber(14, 30), 0.12, 0.1, C.GrassDark)
	end
end

local function entrance(model: Model, o: CFrame)
	local m = Instance.new("Model")
	m.Name = "Entrance"
	m.Parent = model
	for _, x in { 5, 25 } do
		part(m, "ArchPost", o * CFrame.new(x, 7.5, 61), v(1.4, 15, 1.4), C.Wood)
	end
	part(m, "ArchBeam", o * CFrame.new(15, 14.6, 61), v(23, 1.2, 1.2), C.Wood)
	local board = part(m, "ArchSign", o * CFrame.new(15, 12.4, 61), v(16, 3, 0.5), C.Trim)
	sign(board, "SUNNY ACRES", C.BarnRed)
	part(m, "SignChain", o * CFrame.new(10, 13.9, 61), v(0.2, 1.2, 0.2), C.Black, { collide = false })
	part(m, "SignChain", o * CFrame.new(20, 13.9, 61), v(0.2, 1.2, 0.2), C.Black, { collide = false })
	-- roadside hydrant + mailbox
	local h = MapKit.hydrant(m, o * CFrame.new(32, 0.1, 61.5))
	h.Name = "H1"
	h:SetAttribute("HydrantId", "H1")
	prop("mailbox", m, at(o, -89, 0.1, 62, 180), { color = C.BarnRed })
end

local function markers(model: Model, o: CFrame)
	-- Truck 67 parks on the road in front of the arch, facing east (+X).
	marker(model, "TruckSpot", o * CFrame.lookAt(v(15, 0.2, 70), v(25, 0.2, 70)), v(4, 1, 4), TAG_TRUCKSPOT, {
		[Names.Attr.LocationId] = LOCATION,
	})
	-- Squad spawn pads on the yard side of the arch.
	for i = 1, 4 do
		marker(model, `PlayerSpawn{i}`, at(o, 6 + i * 4, 0.6, 55, 180), v(3, 1, 3), TAG_PLAYERSPAWN, {
			[ATTR_SLOT] = i,
			[Names.Attr.LocationId] = LOCATION,
		})
	end
end

------------------------------------------------------------------------------------------------
-- Wheat field + field fence + tractor + scarecrow
------------------------------------------------------------------------------------------------
local function inTractorPath(x: number): boolean
	return x > -67 and x < -53
end

local function field(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "WheatField"
	m:SetAttribute(Names.Attr.BuildingId, "Farm.Field")
	m.Parent = model
	part(m, "Soil", o * CFrame.new(0, 0.1, -83), v(306, 0.2, 98), C.Soil)
	part(m, "TractorTrack", o * CFrame.new(-60, 0.21, -83), v(12, 0.1, 98), C.Stubble, { collide = false })
	part(m, "Stubble", o * CFrame.new(92, 0.21, -54), v(60, 0.1, 36), C.Stubble, { collide = false })
	local row = 0
	local edgeTile: BasePart? = nil
	for z = -40, -128, -5 do
		row += 1
		for x = -147, 147, 6 do
			local harvested = x > 62 and x < 122 and z > -72
			local scare = math.abs(x + 21) < 4 and math.abs(z + 90) < 4
			if not (inTractorPath(x) or harvested or scare) then
				local h = rng:NextNumber(3.0, 4.4)
				local base = if row % 2 == 0 then C.Wheat else C.WheatLight
				local col = base:Lerp(C.WheatDark, rng:NextNumber(0, 0.3))
				local p = part(m, "Wheat", o * CFrame.new(x + rng:NextNumber(-0.4, 0.4), 0.2 + h / 2, z) * CFrame.Angles(0, math.rad(rng:NextNumber(-4, 4)), 0), v(5.6, h, 3.8), col, {
					flammable = true,
					fuel = 10,
					material = FABRIC,
				})
				if z == -40 and x == -45 then
					edgeTile = p
				end
			end
		end
	end
	fireStart(edgeTile, "F3", "Farm.Field")
	-- round bales on the harvested patch
	for _, b in { { 72, -44 }, { 84, -58 }, { 98, -46 }, { 110, -62 }, { 116, -44 } } do
		roundBale(m, at(o, b[1], 0.2, b[2], rng:NextNumber(-40, 40)))
	end
	-- fence along the field's yard edge (gate gap for the tractor path)
	railFence(m, o, v(-152, 0, -33), v(-67, 0, -33))
	railFence(m, o, v(-53, 0, -33), v(152, 0, -33))
	railFence(m, o, v(-152, 0, -33), v(-152, 0, -134))
	railFence(m, o, v(152, 0, -33), v(152, 0, -134))
	-- open gate leaning on its post
	part(m, "Gate", o * CFrame.new(-67, 2.2, -38) * CFrame.Angles(0, math.rad(90), 0), v(10, 0.5, 0.4), C.Fence)
	part(m, "Gate", o * CFrame.new(-67, 3.6, -38) * CFrame.Angles(0, math.rad(90), 0), v(10, 0.5, 0.4), C.Fence)

	-- scarecrow in the middle of the wheat
	local s = Instance.new("Model")
	s.Name = "Scarecrow"
	s.Parent = m
	local sc = at(o, -21, 0.2, -90, 180)
	local F = { flammable = true, fuel = 15 }
	part(s, "Pole", sc * CFrame.new(0, 4.5, 0), v(0.6, 9, 0.6), C.Wood, F)
	part(s, "Arms", sc * CFrame.new(0, 7, 0), v(8, 0.5, 0.5), C.Wood, F)
	part(s, "Shirt", sc * CFrame.new(0, 6.6, 0), v(3.2, 3, 1.4), C.Plaid, F)
	part(s, "Sleeves", sc * CFrame.new(0, 7, 0), v(6.4, 1, 1), C.Plaid, F)
	part(s, "Overalls", sc * CFrame.new(0, 4.8, 0), v(3, 1.4, 1.5), C.Denim, F)
	for _, x in { -3.4, 3.4 } do
		shaped("CornerWedgePart", s, "StrawHand", sc * CFrame.new(x, 6.8, 0), v(0.8, 1, 0.8), C.Hay, F)
	end
	ball(s, "Head", sc * CFrame.new(0, 9.2, 0), 2.4, C.Burlap, F)
	part(s, "HatBrim", sc * CFrame.new(0, 10.3, 0) * UPRIGHT, v(0.3, 4, 4), C.Hay, { shape = Cyl, flammable = true, fuel = 15 })
	part(s, "HatCrown", sc * CFrame.new(0, 11, 0) * UPRIGHT, v(1.4, 2.2, 2.2), C.Hay, { shape = Cyl, flammable = true, fuel = 15 })
	MapKit.googlyEyes(s, sc * CFrame.new(0, 9.4, -1.05), 0.8)
	part(s, "Smile", sc * CFrame.new(0, 8.6, -1.15), v(1, 0.2, 0.1), C.Black, { collide = false })

	-- crows on the arms (tiny)
	for _, x in { -3, 2.6 } do
		ball(s, "Crow", sc * CFrame.new(x, 7.8, 0), 0.9, C.Black, { collide = false })
	end
end

local function tractor(model: Model, cf: CFrame)
	local m = Instance.new("Model")
	m.Name = "Tractor"
	local G, D = C.TractorGreen, C.TractorDark
	local body = part(m, "Chassis", cf * CFrame.new(0, 2.6, 0.5), v(3.6, 1.6, 9), D)
	part(m, "Hood", cf * CFrame.new(0, 4.1, -2.2), v(3.4, 2.6, 5), G)
	part(m, "Grille", cf * CFrame.new(0, 3.9, -4.75), v(2.8, 2.2, 0.3), C.Chrome)
	for i = -1, 1 do
		part(m, "GrilleBar", cf * CFrame.new(0, 3.9 + i * 0.6, -4.95), v(2.6, 0.2, 0.2), C.Black, { collide = false })
	end
	part(m, "Body", cf * CFrame.new(0, 4.2, 2.2), v(3.8, 2.4, 3.6), G)
	part(m, "Seat", cf * CFrame.new(0, 5.8, 2.6), v(2.2, 0.6, 2), C.Black)
	part(m, "SeatBack", cf * CFrame.new(0, 6.9, 3.5), v(2.2, 2, 0.5), C.Black)
	part(m, "Column", cf * CFrame.new(0, 5.9, 0.6) * CFrame.Angles(math.rad(-25), 0, 0), v(0.4, 2.2, 0.4), C.Black)
	part(m, "SteeringWheel", cf * CFrame.new(0, 7, 1.1) * CFrame.Angles(math.rad(-25), 0, 0) * UPRIGHT, v(0.2, 1.8, 1.8), C.Black, { shape = Cyl })
	vcyl(m, "Exhaust", cf * CFrame.new(1, 6.4, -2.8), 3.6, 0.5, C.Black)
	vcyl(m, "ExhaustCap", cf * CFrame.new(1, 8.3, -2.8), 0.3, 0.7, C.Chrome)
	-- big rear wheels with yellow hubs and fenders
	for _, sx in { -1, 1 } do
		part(m, "RearWheel", cf * CFrame.new(sx * 3, 3, 2.6), v(1.8, 6, 6), C.Black, { shape = Cyl })
		part(m, "RearHub", cf * CFrame.new(sx * 3.05, 3, 2.6), v(1.9, 3.2, 3.2), C.Yellow, { shape = Cyl })
		part(m, "Fender", cf * CFrame.new(sx * 3, 6.3, 2.6), v(2.2, 0.4, 5), G)
		part(m, "FrontWheel", cf * CFrame.new(sx * 2.3, 1.6, -3.4), v(1.2, 3.2, 3.2), C.Black, { shape = Cyl })
		part(m, "FrontHub", cf * CFrame.new(sx * 2.35, 1.6, -3.4), v(1.3, 1.6, 1.6), C.Yellow, { shape = Cyl })
		local hl = part(m, "Headlight", cf * CFrame.new(sx * 1.2, 5.2, -4.8), v(0.7, 0.7, 0.3), C.Lamp, { neon = true, collide = false })
		if sx == 1 then
			light(hl, C.Lamp, 14, 0.8)
		end
	end
	MapKit.googlyEyes(m, cf * CFrame.new(0, 5.9, -4.4), 1.3)
	m.PrimaryPart = body
	m.Parent = model
end

------------------------------------------------------------------------------------------------
-- Barn (gambrel roof, ridge along Z, big doors facing +Z)
------------------------------------------------------------------------------------------------
local BH = 12 -- wall height
local BY = 0.5 -- wall base
local EAVE, KNEE, RIDGE = BY + BH, BY + BH + 6, BY + BH + 10

local function barnGable(b: Model, bcf: CFrame, z: number)
	local W = { flammable = true, fuel = 40, material = PLANKS }
	MapKit.wall(b, "Gable", bcf, v(-10, EAVE, z), v(10, EAVE, z), KNEE - EAVE, W :: any)
	gableTri(b, "Gable", bcf, -10, -16, EAVE, KNEE, z, 1, C.BarnRed, W)
	gableTri(b, "Gable", bcf, 10, 16, EAVE, KNEE, z, 1, C.BarnRed, W)
	gableTri(b, "Gable", bcf, 0, -10, KNEE, RIDGE, z, 1, C.BarnRed, W)
	gableTri(b, "Gable", bcf, 0, 10, KNEE, RIDGE, z, 1, C.BarnRed, W)
	-- white trim following the gambrel outline
	local s = if z > 0 then 1 else -1
	local T = { collide = false }
	-- (dropped below the roof line so the roof overhang doesn't swallow it)
	local z0, z1 = z + s * 0.5, z + s * 1.1
	local lo, hi = math.min(z0, z1), math.max(z0, z1)
	local dy = 0.9
	slopePanel(b, "GableTrim", bcf, -16, EAVE - dy, -10, KNEE - dy, lo, hi, 0.6, 0, 0.8, C.Trim, T)
	slopePanel(b, "GableTrim", bcf, 10, KNEE - dy, 16, EAVE - dy, lo, hi, 0, 0.6, 0.8, C.Trim, T)
	slopePanel(b, "GableTrim", bcf, -10, KNEE - dy, 0, RIDGE - dy, lo, hi, 0, 0.3, 0.8, C.Trim, T)
	slopePanel(b, "GableTrim", bcf, 0, RIDGE - dy, 10, KNEE - dy, lo, hi, 0.3, 0, 0.8, C.Trim, T)
end

local function barnDoorPanel(b: Model, cf: CFrame)
	-- 6 x 10 sliding door: red planks, white frame and a white X.
	part(b, "BarnDoor", cf * CFrame.new(0, 5, 0), v(6, 10, 0.5), C.BarnRed, { flammable = true, fuel = 30, material = PLANKS })
	local T = { collide = false }
	part(b, "DoorFrame", cf * CFrame.new(0, 9.7, 0.35), v(6, 0.6, 0.3), C.Trim, T)
	part(b, "DoorFrame", cf * CFrame.new(0, 0.3, 0.35), v(6, 0.6, 0.3), C.Trim, T)
	part(b, "DoorFrame", cf * CFrame.new(-2.7, 5, 0.35), v(0.6, 10, 0.3), C.Trim, T)
	part(b, "DoorFrame", cf * CFrame.new(2.7, 5, 0.35), v(0.6, 10, 0.3), C.Trim, T)
	local ang = math.atan2(9.4, 5.4)
	local len = math.sqrt(9.4 * 9.4 + 5.4 * 5.4) - 0.4
	part(b, "DoorX", cf * CFrame.new(0, 5, 0.35) * CFrame.Angles(0, 0, ang), v(len, 0.6, 0.3), C.Trim, T)
	part(b, "DoorX", cf * CFrame.new(0, 5, 0.35) * CFrame.Angles(0, 0, -ang), v(len, 0.6, 0.3), C.Trim, T)
end

local function barn(model: Model, o: CFrame, rng: Random)
	local b = Instance.new("Model")
	b.Name = "Barn"
	b:SetAttribute(Names.Attr.BuildingId, "Farm.Barn")
	b.Parent = model
	local bid = "Farm.Barn"
	local bcf = o * CFrame.new(40, 0, -2)
	b.PrimaryPart = part(b, "Foundation", bcf * CFrame.new(0, 0.25, 0), v(33, 0.5, 25), C.Foundation)
	part(b, "DirtFloor", bcf * CFrame.new(0, 0.55, 0), v(31, 0.1, 23), C.DirtDark)
	local W = { color = C.BarnRed, flammable = true, fuel = 40, material = PLANKS }
	-- walls: front (+Z) has the 12-wide main opening, east side a locked door
	buildWall(b, "BarnWall", bcf, v(-16, BY, 12), v(16, BY, 12), BH, W, { gap(16, 12, 10) }, nil, nil, nil, bid)
	buildWall(b, "BarnWall", bcf, v(-16, BY, -12), v(16, BY, -12), BH, W, { hiWin(8), hiWin(24) }, -1, C.Trim, nil, bid)
	buildWall(b, "BarnWall", bcf, v(-15.5, BY, -11.5), v(-15.5, BY, 11.5), BH, W, { hiWin(6), hiWin(17) }, 1, C.Trim, nil, bid)
	buildWall(b, "BarnWall", bcf, v(15.5, BY, -11.5), v(15.5, BY, 11.5), BH, W, { hiWin(6), door(19, true, "BarnSideDoor") }, -1, C.Trim, nil, bid)
	barnGable(b, bcf, 12)
	barnGable(b, bcf, -12)
	-- gambrel roof
	local R = { flammable = true, fuel = 40 }
	slopePanel(b, "Roof", bcf, -16, EAVE, -10, KNEE, -13.4, 13.4, 1.4, 0, 1, C.BarnRoof, R)
	slopePanel(b, "Roof", bcf, 10, KNEE, 16, EAVE, -13.4, 13.4, 0, 1.4, 1, C.BarnRoof, R)
	slopePanel(b, "Roof", bcf, -10, KNEE, 0, RIDGE, -13.4, 13.4, 0.2, 0.3, 1, C.BarnRoof, R)
	slopePanel(b, "Roof", bcf, 0, RIDGE, 10, KNEE, -13.4, 13.4, 0.3, 0.2, 1, C.BarnRoof, R)
	part(b, "Ridge", bcf * CFrame.new(0, RIDGE + 1, 0), v(2.2, 0.8, 27.2), C.BarnRoof:Lerp(C.Black, 0.3))
	for _, sx in { -1, 1 } do
		-- white corner posts
		for _, sz in { -1, 1 } do
			part(b, "CornerTrim", bcf * CFrame.new(sx * 16, BY + BH / 2, sz * 12), v(1.3, BH, 1.3), C.Trim)
		end
		-- open sliding doors either side of the opening
		barnDoorPanel(b, bcf * CFrame.new(sx * 9.4, BY, 12.85))
		part(b, "OpeningTrim", bcf * CFrame.new(sx * 6.3, BY + 5, 12.6), v(0.6, 10, 0.4), C.Trim, { collide = false })
	end
	part(b, "OpeningTrim", bcf * CFrame.new(0, BY + 10.3, 12.6), v(13.2, 0.6, 0.4), C.Trim, { collide = false })
	part(b, "DoorRail", bcf * CFrame.new(0, BY + 10.9, 13.2), v(31, 0.4, 0.4), C.Black, { collide = false })
	-- hayloft door + hay hood on the front gable
	part(b, "LoftDoor", bcf * CFrame.new(0, EAVE + 3.4, 12.7), v(5, 5, 0.3), C.BarnRedDark, { flammable = true, fuel = 20 })
	part(b, "LoftTrim", bcf * CFrame.new(0, EAVE + 6.1, 12.9), v(5.8, 0.5, 0.3), C.Trim, { collide = false })
	part(b, "LoftTrim", bcf * CFrame.new(0, EAVE + 0.7, 12.9), v(5.8, 0.5, 0.3), C.Trim, { collide = false })
	part(b, "LoftTrim", bcf * CFrame.new(-2.65, EAVE + 3.4, 12.9), v(0.5, 5.6, 0.3), C.Trim, { collide = false })
	part(b, "LoftTrim", bcf * CFrame.new(2.65, EAVE + 3.4, 12.9), v(0.5, 5.6, 0.3), C.Trim, { collide = false })
	part(b, "HayHood", bcf * CFrame.new(0, RIDGE - 0.6, 14.4), v(1, 1, 4), C.Wood)
	part(b, "PulleyRope", bcf * CFrame.new(0, RIDGE - 2.6, 16), v(0.2, 3.4, 0.2), C.Burlap, { collide = false })
	part(b, "Pulley", bcf * CFrame.new(0, RIDGE - 1.2, 16), v(0.4, 1, 1), C.Black, { shape = Cyl, collide = false })
	-- lantern over the opening
	local lamp = ball(b, "Lantern", bcf * CFrame.new(0, BY + 11.4, 13.3), 1.2, C.Lamp, { neon = true, collide = false })
	light(lamp, C.Lamp, 22, 1.4)
	-- weathervane rooster
	part(b, "VanePole", bcf * CFrame.new(0, RIDGE + 2.4, 6), v(0.3, 2.8, 0.3), C.Black, { collide = false })
	part(b, "VaneArrow", bcf * CFrame.new(0, RIDGE + 3.2, 6), v(0.2, 0.2, 3), C.Black, { collide = false })
	shaped("WedgePart", b, "VaneRooster", bcf * CFrame.new(0, RIDGE + 4.2, 6), v(0.2, 1.4, 1.6), C.Black, { collide = false })

	-- interior: stalls on the west side (dog in the middle one)
	local P = { color = C.Wood, flammable = true, fuel = 25, material = PLANKS }
	for _, z in { -11.5, -3.5, 4.5 } do
		MapKit.wall(b, "StallWall", bcf, v(-15, BY, z), v(-8, BY, z), 4.5, P :: any)
	end
	MapKit.wall(b, "StallFront", bcf, v(-8, BY, -11.5), v(-8, BY, -6.5), 4.5, P :: any)
	MapKit.wall(b, "StallFront", bcf, v(-8, BY, 0.5), v(-8, BY, 1.5), 4.5, P :: any)
	for _, z in { -7.5, 0.5, 8 } do
		rect(b, "Straw", bcf, -15, -8.5, z - 3.5, z + 3.5, BY + 0.35, 0.3, C.Hay, true, { collide = false, material = FABRIC })
	end
	part(b, "Trough", bcf * CFrame.new(-14, BY + 1, -2), v(1.6, 2, 2.8), C.Wood, { flammable = true })
	part(b, "TroughWater", bcf * CFrame.new(-14, BY + 2.05, -2), v(1.2, 0.1, 2.4), C.Water, { collide = false })
	rescueSpawn(b, "R2", "Dog", bid, at(bcf, -11.5, BY + 0.4, 0.5, 90), "sitting")

	-- hay bales stacked on the east side
	for i = 0, 2 do
		for j = 0, 2 - (if i == 2 then 1 else 0) do
			bale(b, at(bcf, 11.5, BY + j * 3, -9 + i * 3.4, 90))
		end
	end
	-- hayloft over the back half, ladder up
	rect(b, "LoftFloor", bcf, -15, 15, -11.5, -2, BY + 9, 0.6, C.WoodLight, true, { material = PLANKS })
	part(b, "LoftBeam", bcf * CFrame.new(0, BY + 8.1, -2.2), v(30, 1, 1), C.Wood, { flammable = true })
	for _, x in { -8, 8 } do
		part(b, "LoftPost", bcf * CFrame.new(x, BY + 4, -2.2), v(1, 8, 1), C.Wood, { flammable = true })
	end
	part(b, "LoftRail", bcf * CFrame.new(-8, BY + 11, -2.1), v(14, 0.5, 0.4), C.Wood, { flammable = true })
	part(b, "LoftRail", bcf * CFrame.new(10, BY + 11, -2.1), v(10, 0.5, 0.4), C.Wood, { flammable = true })
	prop("ladder", b, at(bcf, 3, BY, -1.7, 0), { height = 10, wood = true })
	for _, p in { { -12, -9 }, { -12, -5.5 }, { -7, -9 }, { 6, -9 }, { 10, -9 }, { 10, -5.5 } } do
		bale(b, at(bcf, p[1], BY + 9, p[2], 0))
	end
	bale(b, at(bcf, -12, BY + 12, -7.2, 0))
	rescueSpawn(b, "R3", "Cat", bid, at(bcf, -3, BY + 9, -6, 180), "sitting")
	local inner = ball(b, "BarnBulb", bcf * CFrame.new(0, BY + 8.6, 4), 1, C.Lamp, { neon = true, collide = false })
	light(inner, C.Lamp, 26, 1)
	-- pitchfork + wheelbarrow by the door
	part(b, "PitchforkHandle", bcf * CFrame.new(-13.5, BY + 3.4, 10.8) * CFrame.Angles(math.rad(-12), 0, 0), v(0.3, 6.6, 0.3), C.WoodLight, { collide = false })
	part(b, "PitchforkHead", bcf * CFrame.new(-13.5, BY + 6.9, 10.1), v(1.4, 1.2, 0.2), C.MetalDark, { collide = false })
	part(b, "Barrow", bcf * CFrame.new(11, BY + 1.6, 9) * CFrame.Angles(math.rad(-8), 0, 0), v(2.6, 1.4, 3.6), C.Teal)
	part(b, "BarrowWheel", bcf * CFrame.new(11, BY + 0.8, 7), v(0.5, 1.6, 1.6), C.Black, { shape = Cyl })
	part(b, "BarrowHay", bcf * CFrame.new(11, BY + 2.4, 9.2), v(2.2, 0.8, 3), C.Hay, { flammable = true, fuel = 10, material = FABRIC })

	-- outside: bale pyramid by the front-left corner (F4) and a water trough
	local pyr: BasePart? = nil
	for row = 0, 2 do
		for i = 0, 2 - row do
			local p = bale(b, at(bcf, -26 + i * 4.2 + row * 2.1, row * 3, 17, 0))
			if row == 0 and i == 2 then
				pyr = p
			end
		end
	end
	fireStart(pyr, "F4", bid)
	part(b, "WaterTrough", bcf * CFrame.new(22, 1, 15), v(6, 2, 2.4), C.Wood)
	part(b, "WaterTroughWater", bcf * CFrame.new(22, 2.05, 15), v(5.4, 0.1, 1.8), C.Water, { collide = false })
	-- straw scattered round the opening
	for _ = 1, 8 do
		tuft(b, at(bcf, rng:NextNumber(-12, 12), BY, rng:NextNumber(13, 18)), rng)
	end
end

------------------------------------------------------------------------------------------------
-- Silo and windmill
------------------------------------------------------------------------------------------------
local function silo(model: Model, o: CFrame)
	local m = Instance.new("Model")
	m.Name = "Silo"
	m.Parent = model
	local cf = o * CFrame.new(66, 0, -4)
	m.PrimaryPart = vcyl(m, "Tank", cf * CFrame.new(0, 15, 0), 30, 11, C.Metal)
	for _, y in { 4, 11, 18, 25 } do
		vcyl(m, "Band", cf * CFrame.new(0, y, 0), 0.6, 11.4, C.MetalDark)
	end
	ball(m, "Dome", cf * CFrame.new(0, 30, 0), 11, C.Chrome)
	vcyl(m, "Cap", cf * CFrame.new(0, 35.4, 0), 1, 1.6, C.MetalDark)
	vcyl(m, "Base", cf * CFrame.new(0, 0.4, 0), 0.8, 12.4, C.Concrete)
	prop("ladder", m, at(cf, 0, 0.8, 5.7, 180), { height = 28, flammable = false })
	part(m, "Chute", cf * CFrame.new(-5.6, 20, 0) * CFrame.Angles(0, 0, math.rad(-20)), v(1.4, 10, 1.4), C.MetalDark)
end

local function windmill(model: Model, o: CFrame)
	local m = Instance.new("Model")
	m.Name = "Windmill"
	m.Parent = model
	local cf = o * CFrame.new(120, 0, -20)
	local top = 30
	local legs = {}
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(legs, beam(m, "Leg", cf, v(sx * 4, 0, sz * 4), v(sx * 0.9, top, sz * 0.9), 0.6, C.MetalDark))
		end
	end
	m.PrimaryPart = legs[1]
	for _, y in { 8, 16, 24 } do
		local w = 4 - 3.1 * y / top
		for _, s in { -1, 1 } do
			part(m, "Brace", cf * CFrame.new(0, y, s * w), v(2 * w, 0.35, 0.35), C.Metal)
			part(m, "Brace", cf * CFrame.new(s * w, y, 0), v(0.35, 0.35, 2 * w), C.Metal)
		end
	end
	part(m, "Platform", cf * CFrame.new(0, top, 0), v(2.8, 0.5, 2.8), C.MetalDark)
	local hub = cf * CFrame.new(0, top + 1.4, -1.6)
	part(m, "Hub", hub * CFrame.Angles(0, math.rad(90), 0), v(1.6, 1.6, 1.6), C.Red, { shape = Cyl })
	for i = 0, 11 do
		local a = i * math.pi / 6
		part(m, "Blade", hub * CFrame.Angles(0, 0, a) * CFrame.new(0, 3.4, 0) * CFrame.Angles(0, math.rad(20), 0), v(1.5, 4.6, 0.2), if i % 2 == 0 then C.White else C.Red, { collide = false })
	end
	part(m, "Ring", hub * CFrame.Angles(0, math.rad(90), 0), v(0.3, 11.4, 11.4), C.MetalDark, { shape = Cyl, collide = false, transparency = 0.85 })
	part(m, "TailBoom", cf * CFrame.new(0, top + 1.4, 3), v(0.4, 0.4, 7), C.MetalDark)
	local vane = part(m, "TailVane", cf * CFrame.new(0, top + 1.8, 6.8), v(0.3, 3.2, 3.6), C.White)
	sign(vane, "67", C.Red, { Enum.NormalId.Left, Enum.NormalId.Right })
	part(m, "PumpRod", cf * CFrame.new(0, top / 2, 0), v(0.3, top, 0.3), C.Chrome)
	part(m, "Tank", cf * CFrame.new(7, 2, 3) * UPRIGHT, v(4, 7, 7), C.MetalDark, { shape = Cyl })
end

------------------------------------------------------------------------------------------------
-- Farmhouse (one storey, porch facing the road)
------------------------------------------------------------------------------------------------
local function farmhouse(model: Model, o: CFrame)
	local h = Instance.new("Model")
	h.Name = "Farmhouse"
	local bid = "Farm.House"
	h:SetAttribute(Names.Attr.BuildingId, bid)
	h.Parent = model
	local hcf = o * CFrame.new(-100, 0, 14)
	local FY = 1.2
	h.PrimaryPart = part(h, "Foundation", hcf * CFrame.new(0, 0.5, 0), v(28.6, 1, 21), C.Foundation)
	rect(h, "Floor", hcf, -13, 4, -9.5, 9.5, FY, 0.4, C.WoodFloor, true, { material = PLANKS })
	rect(h, "Floor", hcf, 4, 13, -9.5, 9.5, FY, 0.4, hex("#B8794A"), true, { material = PLANKS })
	local WA = { color = C.Siding, flammable = true, fuel = 40 }
	local IN = { color = hex("#F3E3C3"), flammable = true, fuel = 30 }
	buildWall(h, "Wall", hcf, v(-14, 1, 10), v(14, 1, 10), 11, WA, { win(6), door(14, false, "FrontDoor"), win(22) }, 1, C.Trim, C.Teal, bid)
	buildWall(h, "Wall", hcf, v(-14, 1, -10), v(14, 1, -10), 11, WA, { win(6), door(11, true, "BackDoor"), win(23) }, -1, C.Trim, C.Teal, bid)
	buildWall(h, "Wall", hcf, v(-13.5, 1, -9.5), v(-13.5, 1, 9.5), 11, WA, { win(9.5) }, 1, C.Trim, C.Teal, bid)
	buildWall(h, "Wall", hcf, v(13.5, 1, -9.5), v(13.5, 1, 9.5), 11, WA, { win(9.5) }, -1, C.Trim, C.Teal, bid)
	buildWall(h, "Partition", hcf, v(4, 1, -9.5), v(4, 1, 9.5), 11, IN, { gap(14, 4, 8) }, nil, nil, nil, bid)
	-- gable roof, ridge along X
	local rcf = hcf * CFrame.Angles(0, math.pi / 2, 0)
	local G = { flammable = true, fuel = 30 }
	for _, z in { -13.5, 13.5 } do
		gableTri(h, "Gable", rcf, 0, -10.5, 12, 19, z, 1, C.Siding, G)
		gableTri(h, "Gable", rcf, 0, 10.5, 12, 19, z, 1, C.Siding, G)
		part(h, "GableVent", rcf * CFrame.new(0, 15, z + (if z > 0 then 0.55 else -0.55)), v(2, 2, 0.2), C.Trim, { collide = false })
	end
	local R = { flammable = true, fuel = 40 }
	slopePanel(h, "Roof", rcf, -10.5, 12, 0, 19, -15.2, 15.2, 1.8, 0.4, 1, C.RoofBrown, R)
	slopePanel(h, "Roof", rcf, 0, 19, 10.5, 12, -15.2, 15.2, 0.4, 1.8, 1, C.RoofBrown, R)
	part(h, "Ridge", rcf * CFrame.new(0, 19.9, 0), v(2, 0.8, 30.8), C.RoofBrown:Lerp(C.Black, 0.3))
	part(h, "Chimney", hcf * CFrame.new(-9, 11, -4), v(3, 20, 3), C.Brick, { material = Enum.Material.Brick })
	part(h, "ChimneyCap", hcf * CFrame.new(-9, 21.3, -4), v(3.8, 0.6, 3.8), C.Concrete)
	-- porch across the front
	rect(h, "Porch", hcf, -14, 14, 10.5, 16.5, 1, 1, C.WoodLight, true, { material = PLANKS })
	part(h, "PorchStep", hcf * CFrame.new(0, 0.25, 17.2), v(5, 0.5, 1.4), C.Concrete)
	for _, x in { -13.4, -6.5, 6.5, 13.4 } do
		part(h, "PorchPost", hcf * CFrame.new(x, 5.3, 16), v(0.8, 8.6, 0.8), C.Trim)
	end
	part(h, "PorchRoof", hcf * CFrame.new(0, 10.2, 13.8) * CFrame.Angles(math.rad(8), 0, 0), v(29.6, 0.6, 7.6), C.RoofBrown)
	for _, seg in { { -13.4, -3 }, { 3, 13.4 } } do
		part(h, "PorchRail", hcf * CFrame.new((seg[1] + seg[2]) / 2, 3.6, 16), v(seg[2] - seg[1], 0.4, 0.4), C.Trim, { flammable = true })
		for x = seg[1] + 1.2, seg[2] - 0.6, 1.2 do
			part(h, "Baluster", hcf * CFrame.new(x, 2.3, 16), v(0.3, 2.4, 0.3), C.Trim, { collide = false })
		end
	end
	local pl = ball(h, "PorchLight", hcf * CFrame.new(3.2, 8.2, 10.8), 0.8, C.Lamp, { neon = true, collide = false })
	light(pl, C.Lamp, 14, 1.2)
	-- rocking chair + potted plants on the porch
	local rc = at(hcf, -9, 1, 13, 200)
	part(h, "RockerSeat", rc * CFrame.new(0, 1.6, 0), v(2.2, 0.4, 2.2), C.Wood, { flammable = true })
	part(h, "RockerBack", rc * CFrame.new(0, 3, 1), v(2.2, 2.8, 0.4), C.Wood, { flammable = true })
	for _, x in { -1, 1 } do
		part(h, "Rocker", rc * CFrame.new(x, 0.35, 0), v(0.3, 0.4, 3), C.Wood, { collide = false })
		part(h, "RockerLeg", rc * CFrame.new(x, 0.95, 0), v(0.3, 1, 1.6), C.Wood, { collide = false })
	end
	prop("plant", h, at(hcf, 5, 1, 11.4, 0), { color = C.Terracotta })
	prop("plant", h, at(hcf, -5, 1, 11.4, 0), { color = C.Mustard })
	-- interior: kitchen + living (west), bedroom (east)
	prop("counter", h, at(hcf, -9, FY, -8.4, 180), { length = 6, stove = true })
	prop("fridge", h, at(hcf, -12, FY, -4, -90))
	prop("table", h, at(hcf, -6, FY, 0, 0), { width = 5, depth = 3.5 })
	prop("chair", h, at(hcf, -6, FY, -2.6, 180))
	prop("chair", h, at(hcf, -6, FY, 2.6, 0))
	prop("sofa", h, at(hcf, -2, FY, 7.6, 0), { color = C.Teal })
	prop("bookshelf", h, at(hcf, 2.8, FY, -6, 90))
	part(h, "Rug", hcf * CFrame.new(-4, FY + 0.1, 4.5), v(9, 0.2, 5), C.Plaid, { flammable = true, collide = false })
	prop("bed", h, at(hcf, 9, FY, -5.4, 180), { color = C.Plaid })
	part(h, "Rug", hcf * CFrame.new(9, FY + 0.1, 2), v(6, 0.2, 4), C.Mustard, { flammable = true, collide = false })
	local cl = ball(h, "CeilingLamp", hcf * CFrame.new(-5, 10.6, 0), 1.4, C.Lamp, { neon = true, collide = false })
	light(cl, C.Lamp, 18, 0.9)
	rescueSpawn(h, "R4", "Civilian", bid, at(hcf, 9, FY, 1.5, 90), "lying")
	-- garden: trees, bushes, clothesline
	prop("tree", h, at(hcf, -22, 0, 4, 0), { variant = 2 })
	prop("tree", h, at(hcf, 22, 0, -8, 0), { variant = 3 })
	prop("bush", h, at(hcf, -10, 0, 17.5, 0), { flowers = true })
	prop("bush", h, at(hcf, 10, 0, 17.5, 0), { flowers = true })
	for _, x in { -6, 10 } do
		part(h, "LinePost", hcf * CFrame.new(x, 3.5, -18), v(0.5, 7, 0.5), C.Wood)
	end
	part(h, "Clothesline", hcf * CFrame.new(2, 6.6, -18), v(16, 0.1, 0.1), C.Trim, { collide = false })
	for i, col in { C.Plaid, C.Denim, C.Mustard, C.White } do
		part(h, "Laundry", hcf * CFrame.new(-3 + i * 2.8, 5.4, -18), v(2, 2.4, 0.15), col, { flammable = true, collide = false })
	end
end

------------------------------------------------------------------------------------------------
-- Haystacks, the farmer, chicken coop, duck pond, livestock
------------------------------------------------------------------------------------------------
local function haystacks(model: Model, o: CFrame)
	local m = Instance.new("Model")
	m.Name = "Haystacks"
	m:SetAttribute(Names.Attr.BuildingId, "Farm.Yard")
	m.Parent = model
	local hay1 = prop("haystack", m, at(o, -8, 0.1, 18, 0), { size = 1.25 })
	if hay1 then
		hay1.Name = "HAY1"
		fireStart(hay1.PrimaryPart, "F1", "Farm.Yard")
	end
	local hay2 = prop("haystack", m, at(o, -24, 0.1, 9, 40), { size = 1.1 })
	if hay2 then
		hay2.Name = "HAY2"
	end
	local hay3 = prop("haystack", m, at(o, -36, 0.1, 24, 80), { size = 1.35 })
	if hay3 then
		hay3.Name = "HAY3"
	end
	-- the dazed farmer leans on HAY1, smoking; the dropped cigarette smoulders in the straw
	rescueSpawn(m, "R1", farmerKind(), "Farm.Yard", at(o, -2.6, 0.1, 21.4, 200), "stand", {
		Smoking = true,
		Variant = "Farmer",
		Dazed = true,
	})
	local cig = part(m, "Cigarette", o * CFrame.new(-4.4, 0.25, 22.6) * CFrame.Angles(0, math.rad(30), 0), v(0.25, 0.25, 1), C.White, { collide = false })
	local tip = part(m, "CigaretteTip", cig.CFrame * CFrame.new(0, 0, -0.55), v(0.27, 0.27, 0.15), C.Ember, { neon = true, collide = false })
	local smoke = Instance.new("Smoke")
	smoke.Color = hex("#D9D2C8")
	smoke.Opacity = 0.12
	smoke.Size = 0.4
	smoke.RiseVelocity = 2
	smoke.Parent = tip
	-- loose hay round the stacks
	for _, b in { { -18, 26, 20 }, { -30, 14, -10 }, { 2, 10, 65 } } do
		bale(m, at(o, b[1], 0.1, b[2], b[3]))
	end
end

local function chickenCoop(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "ChickenCoop"
	local bid = "Farm.Coop"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	m.Parent = model
	local cf = o * CFrame.new(92, 0, 30)
	local F = { flammable = true, fuel = 25, material = PLANKS }
	m.PrimaryPart = part(m, "CoopBody", cf * CFrame.new(0, 3.2, 0), v(8, 4, 6), C.BarnRed, F)
	for _, x in { -3.6, 3.6 } do
		for _, z in { -2.6, 2.6 } do
			part(m, "CoopLeg", cf * CFrame.new(x, 0.6, z), v(0.6, 1.2, 0.6), C.Wood)
		end
	end
	slopePanel(m, "CoopRoof", cf * CFrame.Angles(0, math.pi / 2, 0), -3.4, 5.2, 0, 7.2, -4.6, 4.6, 0.8, 0.2, 0.5, C.BarnRoof, { flammable = true, fuel = 20 })
	slopePanel(m, "CoopRoof", cf * CFrame.Angles(0, math.pi / 2, 0), 0, 7.2, 3.4, 5.2, -4.6, 4.6, 0.2, 0.8, 0.5, C.BarnRoof, { flammable = true, fuel = 20 })
	for _, x in { -4.05, 4.05 } do
		gableTri(m, "CoopGable", cf * CFrame.Angles(0, math.pi / 2, 0), 0, -3, 5.2, 7.2, x, 0.4, C.BarnRed, F)
		gableTri(m, "CoopGable", cf * CFrame.Angles(0, math.pi / 2, 0), 0, 3, 5.2, 7.2, x, 0.4, C.BarnRed, F)
	end
	part(m, "CoopHole", cf * CFrame.new(-1.5, 2.6, 3.05), v(1.8, 1.8, 0.1), C.Black, { collide = false })
	part(m, "CoopTrim", cf * CFrame.new(0, 5.15, 3.1), v(8.2, 0.4, 0.2), C.Trim, { collide = false })
	part(m, "Ramp", cf * CFrame.new(-1.5, 0.9, 4.6) * CFrame.Angles(math.rad(-38), 0, 0), v(1.8, 0.2, 3.4), C.WoodLight)
	-- pen: wooden posts + see-through chicken wire
	local x0, x1, z0, z1 = 74, 104, 22, 46
	local function wire(a: Vector3, b: Vector3)
		local mid = (a + b) / 2
		part(m, "ChickenWire", o * CFrame.lookAt(mid + v(0, 1.6, 0), mid + v(0, 1.6, 0) + (b - a).Unit), v(0.1, 3.2, (b - a).Magnitude), C.Chrome, { transparency = 0.7, collide = true })
	end
	wire(v(x0, 0, z0), v(x1, 0, z0))
	wire(v(x0, 0, z1), v(84, 0, z1))
	wire(v(89, 0, z1), v(x1, 0, z1))
	wire(v(x0, 0, z0), v(x0, 0, z1))
	wire(v(x1, 0, z0), v(x1, 0, z1))
	for _, p in { { x0, z0 }, { x1, z0 }, { x0, z1 }, { x1, z1 }, { 84, z1 }, { 89, z1 }, { 89, z0 }, { x0, 34 }, { x1, 34 } } do
		part(m, "PenPost", o * CFrame.new(p[1], 1.9, p[2]), v(0.6, 3.8, 0.6), C.Wood)
	end
	part(m, "Feed", o * CFrame.new(82, 0.15, 36), v(6, 0.1, 4), C.Hay, { collide = false })
	part(m, "FeedTray", o * CFrame.new(80, 0.5, 28), v(4, 0.8, 1.6), C.MetalDark)
	local hens = { C.White, C.White, hex("#C8783A"), hex("#C8783A"), C.White, hex("#8A4A28"), C.White, hex("#C8783A") }
	for _, col in hens do
		chicken(m, at(o, rng:NextNumber(76, 87), 0.1, rng:NextNumber(26, 44), rng:NextNumber(0, 360)), col)
	end
	-- two escapees out in the yard
	chicken(m, at(o, 58, 0.1, 40, 200), C.White)
	chicken(m, at(o, 62, 0.1, 44, 150), hex("#C8783A"))
end

local function pond(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "DuckPond"
	m:SetAttribute(Names.Attr.BuildingId, "Farm.Pond")
	m.Parent = model
	local cx, cz = 140, 16
	disc(m, "PondBank", o, cx, cz, 34, 0.15, 0.2, hex("#8A7A5A"))
	disc(m, "PondBed", o, cx, cz, 29, 0.2, 0.1, C.PondBed)
	local water = disc(m, "Water", o, cx, cz, 28, 0.55, 0.4, C.Water, {
		transparency = 0.25,
		collide = false,
		tags = { Names.Tag.Hydrant },
	})
	water.Reflectance = 0.15
	water:SetAttribute("Pond", true)
	water:SetAttribute("HydrantId", "Pond")
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Refill"
	prompt.ObjectText = "Pond"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = water
	m.PrimaryPart = water
	-- rim stones
	for i = 0, 13 do
		local a = i * math.pi * 2 / 14 + rng:NextNumber(-0.1, 0.1)
		local r = 15 + rng:NextNumber(-0.5, 0.8)
		part(m, "RimStone", o * CFrame.new(cx + math.cos(a) * r, 0.4, cz + math.sin(a) * r) * CFrame.Angles(0, a, 0), v(rng:NextNumber(1.6, 2.6), rng:NextNumber(0.8, 1.4), rng:NextNumber(1.4, 2.2)), if i % 3 == 0 then C.StoneDark else C.Stone)
	end
	-- cattails on the west edge
	for i = 0, 6 do
		local a = math.pi * (0.75 + i * 0.08)
		local px, pz = cx + math.cos(a) * 13, cz + math.sin(a) * 13
		local hh = rng:NextNumber(3.5, 5.5)
		part(m, "Reed", o * CFrame.new(px, hh / 2, pz), v(0.25, hh, 0.25), C.Leaf, { collide = false })
		part(m, "Cattail", o * CFrame.new(px, hh + 0.4, pz), v(0.5, 1.2, 0.5), C.CattailBrown, { collide = false })
	end
	-- lily pads + ducks
	for _ = 1, 5 do
		disc(m, "LilyPad", o, cx + rng:NextNumber(-9, 9), cz + rng:NextNumber(-9, 9), rng:NextNumber(1.6, 2.6), 0.62, 0.05, C.Leaf2, { collide = false })
	end
	duck(m, at(o, cx - 4, 0.3, cz + 2, 60), true)
	duck(m, at(o, cx - 1.6, 0.3, cz + 4, 80), false)
	duck(m, at(o, cx + 0.6, 0.3, cz + 5.6, 90), false)
	duck(m, at(o, cx + 5, 0.3, cz - 3, 220), true)
	-- little jetty
	part(m, "Jetty", o * CFrame.new(cx - 2, 0.9, cz + 13), v(4, 0.4, 8), C.WoodLight, { flammable = true, material = PLANKS })
	for _, x in { -3.6, -0.4 } do
		part(m, "JettyPost", o * CFrame.new(cx + x, 0.6, cz + 9.6), v(0.6, 1.4, 0.6), C.Wood)
	end
end

local function pasture(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "Pasture"
	m.Parent = model
	railFence(m, o, v(-200, 0, 82), v(-12, 0, 82))
	railFence(m, o, v(42, 0, 82), v(200, 0, 82))
	cow(m, at(o, 70, 0.1, 110, 160))
	cow(m, at(o, 96, 0.1, 124, 230))
	cow(m, at(o, -60, 0.1, 118, 120))
	for _, t in { { -170, 100 }, { -120, 130 }, { -40, 160 }, { 30, 150 }, { 130, 160 }, { 175, 105 } } do
		prop("tree", m, at(o, t[1], 0.1, t[2], rng:NextNumber(0, 360)), { variant = rng:NextInteger(1, 3), size = rng:NextNumber(1, 1.4), flammable = false })
	end
	-- tree line behind the field
	for x = -180, 180, 30 do
		prop("tree", m, at(o, x + rng:NextNumber(-8, 8), 0, -160 - rng:NextNumber(0, 25), rng:NextNumber(0, 360)), {
			variant = rng:NextInteger(1, 3),
			size = rng:NextNumber(1.2, 1.7),
			flammable = false,
		})
	end
	for _, b in { { -185, 40 }, { -150, 50 }, { 180, 40 }, { 170, -20 } } do
		prop("bush", m, at(o, b[1], 0.1, b[2], 0), { flammable = false })
	end
end

------------------------------------------------------------------------------------------------
-- Dry grass: the fuse between haystacks, fence, field and barn
------------------------------------------------------------------------------------------------
local function dryGrass(model: Model, o: CFrame, rng: Random)
	local m = Instance.new("Model")
	m.Name = "DryGrass"
	m:SetAttribute(Names.Attr.BuildingId, "Farm.Yard")
	m.Parent = model
	local zones = {
		{ -48, 6, 2, 34, 46 }, -- round the haystacks
		{ -150, 150, -31, -22, 80 }, -- along the inside of the field fence
		{ -50, 12, -22, 2, 30 }, -- haystacks -> fence
		{ 12, 24, -14, 14, 12 }, -- toward the barn's west wall
		{ -125, -75, -8, 34, 20 }, -- farmhouse yard
		{ 100, 150, -30, 0, 14 }, -- windmill corner
	}
	local hay = { { -8, 18, 5 }, { -24, 9, 4.5 }, { -36, 24, 5.5 }, { -100, 14, 16 } }
	for _, zn in zones do
		local placed = 0
		local tries = 0
		while placed < zn[5] and tries < zn[5] * 6 do
			tries += 1
			local x, z = rng:NextNumber(zn[1], zn[2]), rng:NextNumber(zn[3], zn[4])
			local clear = not (z < -24 and inTractorPath(x))
			for _, h in hay do
				if math.abs(x - h[1]) < h[3] and math.abs(z - h[2]) < h[3] then
					clear = false
				end
			end
			if clear then
				tuft(m, at(o, x, 0.1, z), rng)
				placed += 1
			end
		end
	end
	-- F2: the clump by the fence the haystack fire jumps to
	local f2 = tuft(m, at(o, -26, 0.1, -26), rng)
	tuft(m, at(o, -28, 0.1, -24), rng)
	tuft(m, at(o, -23.5, 0.1, -27.5), rng)
	fireStart(f2, "F2", "Farm.Yard")
end

function FarmBuilder.Build(model: Model, origin: CFrame, rng: Random)
	model:SetAttribute("DisplayName", "Sunny Acres Farm")
	model:SetAttribute("InteriorOrigin", origin) -- Lib/Map/Interiors/Districts dresses the interiors per run
	model:SetAttribute("AtmospherePreset", "DuskSuburb") -- closest preset to 02's "Golden Farm"
	ground(model, origin, rng)
	entrance(model, origin)
	markers(model, origin)
	field(model, origin, rng)
	tractor(model, at(origin, -60, 0.2, -46, 0))
	barn(model, origin, rng)
	silo(model, origin)
	windmill(model, origin)
	farmhouse(model, origin)
	haystacks(model, origin)
	chickenCoop(model, origin, rng)
	pond(model, origin, rng)
	pasture(model, origin, rng)
	dryGrass(model, origin, rng)
end

return FarmBuilder
