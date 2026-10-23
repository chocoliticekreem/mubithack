-- ApartmentBuilder [owner: G2]. ELM COURT: the trailer's burning brick apartment block at night
-- (docs/game/05 §2.4, docs/game/02 ApartmentBlock kit + Night Street lighting, trailer s2 c7-8).
-- Slot 2. Local frame: origin = slot centre on the ground, +X east, +Z south. The block faces the
-- street on the +Z side (toward the default preview camera). The road continues the Town road
-- (centre z = 56), so the station -> town -> apartment street reads as one line.
--
--   Road Z 48..64, sidewalks Z 34..48 (forecourt) and 64..70, pocket park + shops south of it.
--   Elm Court X -24..24, Z 6..34, 5 storeys x 12 (floor surfaces y 1, 13, 25, 37, 49; roof 61).
--     Floor 1: lobby (locked front door), laundry, boiler room, stairwell.
--     Floors 3 + 4: explorable. Corridor Z 18.5..22.5, flats x01/x02 front, x03/x04 back.
--     Floors 2 + 5: sealed (curtained windows).
--     Stairwell X -4.5..4.5, Z 7..17.5, switchback flights from the lobby to a roof headhouse.
--     Fire escape on the east face (X 24..29.5) with climbable truss ladders at both ends.
--   Roof: water tower, AC units, washing line. Neighbour blocks either side, skyline behind.
--
-- Gameplay hooks (find them by tag/attribute, never by coordinate):
--   FireStart F1..F3: Flammable parts in 301 (curtain), 302 (sofa), 303 (stove counter); attr FireId.
--   RescueSpawn R1..R5: invisible 2x2x2, attr Kind (Civilian|Cat|Dog), Pose, SpawnId, BuildingId;
--     -Z of the part is the facing. R1/R2 are window jumpers on floor 4 (Pose "window") at the
--     open windows tagged Window with attr Jump = true; TrampolineZone parts (12x12) mark the catch area.
--   TruckSpot: one part in the street, LookVector = truck forward. PlayerSpawn: pad beside it.
--   Doors: lobby front + 302 + 402 are locked (axe). Hydrants H1..H3.
--   Model attrs: DisplayName, Atmosphere = "NightStreet".
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local ApartmentBuilder = {}
ApartmentBuilder.Id = "Apartment"
ApartmentBuilder.Slot = 2

local TAG_TRUCKSPOT = (Names.Tag :: any).TruckSpot or "TruckSpot"
local TAG_PLAYERSPAWN = (Names.Tag :: any).PlayerSpawn or "PlayerSpawn"
local BID = "Apartment.ElmCourt"

local H = 12 -- storey height
local SY = { 1, 13, 25, 37, 49 } -- floor surface of storey 1..5
local ROOF = 61
local EXPLORE = { [3] = true, [4] = true }

local hex = Color3.fromHex
local C = {
	Brick = hex("#9C4A36"),
	BrickDark = hex("#7A3828"),
	BrickTrim = hex("#B86A50"),
	Stone = hex("#D9C9B0"),
	Ground = hex("#3E4A3A"),
	Lawn = hex("#5E7A44"),
	Asphalt = hex("#4A4650"),
	AsphaltDark = hex("#3A3640"),
	Sidewalk = hex("#C9B8A8"),
	Paving = hex("#B5A595"),
	Kerb = hex("#B3A291"),
	LineYellow = hex("#E3B23C"),
	Trim = hex("#F2EDE4"),
	White = hex("#F7F4EE"),
	Black = hex("#1A1714"),
	Iron = hex("#2E2B30"),
	IronLit = hex("#4A4550"),
	Concrete = hex("#B8B2A6"),
	ConcreteDark = hex("#8E897F"),
	RoofTar = hex("#3A3640"),
	Red = hex("#C8232B"),
	Lamp = hex("#FFC97A"),
	Fire = hex("#FFB347"),
	WoodFloor = hex("#C8683A"),
	WoodFloor2 = hex("#B8794A"),
	Tile = hex("#EFE7D8"),
	TileB = hex("#BFD8D8"),
	TileC = hex("#E9C46A"),
	Corridor = hex("#E8D9B0"),
	CorridorLow = hex("#7A9A6A"),
	Peach = hex("#F2D2B0"),
	Lilac = hex("#D9C6E3"),
	RoomTeal = hex("#4F8A85"),
	Cream = hex("#F3E3C3"),
	Sage = hex("#9DB38A"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Pink = hex("#FF7FB0"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	Cardboard = hex("#C9A06A"),
	Chrome = hex("#D6D8DC"),
	Brass = hex("#C89A3C"),
	WinDark = hex("#2B3558"),
	Curtain1 = hex("#6A3A5A"),
	Curtain2 = hex("#3A4A6A"),
	Curtain3 = hex("#7A5A3A"),
	CurtainRed = hex("#B83A2E"),
	Leaf = hex("#4F7A34"),
	Leaf2 = hex("#6F9A3A"),
	Trunk = hex("#7A3A1E"),
}

local Ball, Cyl = Enum.PartType.Ball, Enum.PartType.Cylinder
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y

------------------------------------------------------------------------------------------------
-- Helpers (local coords are relative to the slot origin O, set in Build)
------------------------------------------------------------------------------------------------
local O = CFrame.identity

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function at(x: number, y: number, z: number, yaw: number?): CFrame
	return CFrame.new(x, y, z) * CFrame.Angles(0, math.rad(yaw or 0), 0)
end

local function part(parent: Instance, name: string, cfLocal: CFrame, size: Vector3, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = { color = color }
	if extra then
		for k, val in extra do
			o[k] = val
		end
	end
	return MapKit.part(parent, name, O * cfLocal, size, o :: any)
end

local function box(parent: Instance, name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, color: Color3, extra: { [string]: any }?): Part
	return part(parent, name, CFrame.new(x, y, z), v(sx, sy, sz), color, extra)
end

-- Upright cylinder with its base at y.
local function cylY(parent: Instance, name: string, x: number, y: number, z: number, h: number, dia: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = { shape = Cyl }
	if extra then
		for k, val in extra do
			o[k] = val
		end
	end
	return part(parent, name, CFrame.new(x, y + h / 2, z) * UPRIGHT, v(h, dia, dia), color, o)
end

local function ball(parent: Instance, name: string, x: number, y: number, z: number, dia: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = { shape = Ball }
	if extra then
		for k, val in extra do
			o[k] = val
		end
	end
	return part(parent, name, CFrame.new(x, y, z), v(dia, dia, dia), color, o)
end

local function folder(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function light(p: BasePart, range: number, brightness: number, color: Color3?)
	local l = Instance.new("PointLight")
	l.Color = color or C.Lamp
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
end

local function label(p: BasePart, face: Enum.NormalId, text: string, color: Color3, font: Enum.Font?, glow: boolean?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 40
	if glow then
		gui.LightInfluence = 0
	end
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.Font = font or Enum.Font.FredokaOne
	t.TextColor3 = color
	t.Parent = gui
	gui.Parent = p
end

-- Rect slab (x0..x1, z0..z1) with its top at `top`. Tiled into <= 8-stud chunks when flammable or
-- checkered; otherwise a single part.
local function rect(parent: Instance, name: string, x0: number, x1: number, z0: number, z1: number, top: number, thick: number, color: Color3, flam: boolean?, checker: Color3?, material: Enum.Material?)
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
			box(parent, name, x0 + (i - 0.5) * sx, top - thick / 2, z0 + (j - 0.5) * sz, sx, thick, sz, col, {
				flammable = flam,
				fuel = if flam then 35 else nil,
				material = material,
			})
		end
	end
end

-- Axis-aligned wall from (ax, az) to (bx, bz), base y0, height h, thickness 1, with rectangular
-- holes { c = coordinate along the wall, w, b, t } (b/t relative to y0). Flammable walls are split
-- into <= 8-stud chunks.
type Hole = { c: number, w: number, b: number, t: number }
local function wall(parent: Instance, name: string, ax: number, az: number, bx: number, bz: number, y0: number, h: number, holes: { Hole }?, opts: { [string]: any })
	local alongX = math.abs(bx - ax) > math.abs(bz - az)
	local len = if alongX then math.abs(bx - ax) else math.abs(bz - az)
	local sgn = if alongX then math.sign(bx - ax) else math.sign(bz - az)
	local dx, dz = if alongX then sgn else 0, if alongX then 0 else sgn
	local flam = opts.flammable == true
	local thick = opts.thick or 1
	local function seg(s0: number, s1: number, yb: number, hh: number)
		if s1 - s0 < 0.05 or hh < 0.05 then
			return
		end
		local L = s1 - s0
		local n = if flam then math.max(1, math.ceil(L / 8 - 1e-6)) else 1
		for i = 1, n do
			local m = s0 + (i - 0.5) * L / n
			local px, pz = ax + dx * m, az + dz * m
			local size = if alongX then v(L / n, hh, thick) else v(thick, hh, L / n)
			box(parent, name, px, y0 + yb + hh / 2, pz, size.X, size.Y, size.Z, opts.color, {
				flammable = flam,
				fuel = opts.fuel,
				material = opts.material,
			})
		end
	end
	local ops = {}
	for _, hole in holes or {} do
		local s = (hole.c - (if alongX then ax else az)) * sgn
		table.insert(ops, { s = s, w = hole.w, b = hole.b, t = hole.t })
	end
	table.sort(ops, function(p, q)
		return p.s < q.s
	end)
	local cur = 0
	for _, op in ops do
		local l, r = op.s - op.w / 2, op.s + op.w / 2
		seg(cur, l, 0, h)
		seg(l, r, 0, math.min(op.b, h))
		seg(l, r, op.t, h - op.t)
		cur = r
	end
	seg(cur, len, 0, h)
end

------------------------------------------------------------------------------------------------
-- Props (PropKit when present, else simple local boxes) and NPCs (NpcBuilder, optional)
------------------------------------------------------------------------------------------------
local PropKit: any = nil
local NpcBuilder: any = nil

local function tryRequire(dir: Instance?, name: string): any
	local ms = dir and dir:FindFirstChild(name)
	if not ms or not ms:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, ms)
	if ok and type(mod) == "table" then
		return mod
	end
	warn(`[ApartmentBuilder] {name} unavailable: {if ok then "not a table" else mod}`)
	return nil
end

-- Fallback silhouettes: { offset, size, colour, flammable? }
local FALLBACK: { [string]: { { any } } } = {
	sofa = { { v(0, 1.2, 0), v(8, 2.4, 3), C.Sage, true }, { v(0, 2.6, 1.2), v(8, 2.6, 0.8), C.TealDark, true } },
	bookshelf = { { v(0, 3.5, 0), v(4, 7, 1.4), C.Wood, true } },
	bed = { { v(0, 1, 0), v(5, 2, 8), C.Wood, true }, { v(0, 2.2, -0.6), v(4.6, 0.6, 6.4), C.Terracotta, true } },
	table = { { v(0, 1.4, 0), v(4, 2.8, 3), C.WoodLight, true } },
	chair = { { v(0, 1.2, 0), v(2, 2.4, 2), C.WoodLight, true } },
	plant = { { v(0, 0.7, 0), v(1.4, 1.4, 1.4), C.Terracotta }, { v(0, 2.4, 0), v(2.4, 2.4, 2.4), C.Leaf2, true } },
	tv = { { v(0, 0.8, 0), v(4, 1.6, 1.6), C.Wood, true }, { v(0, 3, 0), v(3.8, 2.4, 0.4), C.Black } },
	fridge = { { v(0, 3.5, 0), v(3, 7, 2.6), C.White } },
	counter = { { v(0, 1.8, 0), v(6, 3.6, 2.6), C.Sage, true } },
	bench = { { v(0, 1, 0), v(6, 2, 1.8), C.WoodLight, true } },
	extinguisher = { { v(0, 1.8, 0), v(1.2, 3.6, 1.2), C.Red } },
	streetLamp = { { v(0, 6, 0), v(0.6, 12, 0.6), C.Iron }, { v(0, 11.6, -1.4), v(1.4, 0.8, 1.4), C.Lamp } },
	tree = { { v(0, 3, 0), v(1.4, 6, 1.4), C.Trunk }, { v(0, 8, 0), v(8, 8, 8), C.Leaf } },
	bush = { { v(0, 1.4, 0), v(3.6, 2.8, 3.6), C.Leaf } },
	car = { { v(0, 1.9, 0), v(6, 2, 11), C.Teal }, { v(0, 3.7, 0.6), v(5.4, 1.8, 6), C.Teal } },
	trampoline = { { v(0, 1.2, 0), v(8, 2.4, 8), hex("#3A7FD0") } },
	mailbox = { { v(0, 2, 0), v(1.2, 4, 1.4), hex("#2C5F9E") } },
	ladder = { { v(0, 6, 0), v(2.6, 12, 0.5), C.Chrome } },
}

local function prop(kind: string, parent: Instance, cfLocal: CFrame, opts: { [string]: any }?): Model?
	if PropKit and type(PropKit[kind]) == "function" then
		local holder = Instance.new("Model")
		local ok, res = pcall(PropKit[kind], holder, O * cfLocal, opts)
		if ok and typeof(res) == "Instance" then
			res.Parent = parent
			holder:Destroy()
			return res :: Model
		end
		holder:Destroy()
		if not ok then
			warn(`[ApartmentBuilder] PropKit.{kind} failed: {res}`)
		end
	end
	local fb = FALLBACK[kind]
	if not fb then
		return nil
	end
	local m = Instance.new("Model")
	m.Name = kind
	for i, b in fb do
		local p = part(m, kind, cfLocal * CFrame.new(b[1]), b[2], if i == 1 and opts and opts.color then opts.color else b[3], { flammable = b[4] })
		if i == 1 then
			m.PrimaryPart = p
		end
	end
	m.Parent = parent
	return m
end

local function npc(kind: string, parent: Instance, cfLocal: CFrame, opts: { [string]: any }?)
	if NpcBuilder and type(NpcBuilder.Build) == "function" then
		local ok, res = pcall(NpcBuilder.Build, kind, O * cfLocal, opts)
		if ok and typeof(res) == "Instance" then
			res:SetAttribute("Bystander", true)
			res.Parent = parent
			return
		end
		warn(`[ApartmentBuilder] NpcBuilder {kind} failed: {res}`)
	end
	-- fallback: a little pyjama person
	local m = folder(parent, kind)
	local col = opts and opts.color or C.Lilac
	part(m, "Body", cfLocal * CFrame.new(0, 2.2, 0), v(2, 2.4, 1.2), col, { collide = false })
	part(m, "Legs", cfLocal * CFrame.new(0, 0.6, 0), v(1.8, 1.2, 1), C.TealDark, { collide = false })
	part(m, "Head", cfLocal * CFrame.new(0, 4.2, 0), v(2.2, 2.2, 2.2), C.Peach, { shape = Ball, collide = false })
	MapKit.googlyEyes(m, O * cfLocal * CFrame.new(0, 4.4, -1), 0.8)
end

-- Biggest Flammable BasePart inside a model (to hang a FireStart on a prop).
local function firstFlammable(m: Instance?): BasePart?
	if not m then
		return nil
	end
	local best: BasePart? = nil
	local bestVol = 0
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Flammable) then
			local vol = d.Size.X * d.Size.Y * d.Size.Z
			if vol > bestVol then
				best, bestVol = d, vol
			end
		end
	end
	return best
end

------------------------------------------------------------------------------------------------
-- Gameplay markers
------------------------------------------------------------------------------------------------
local function fireStart(p: BasePart?, id: string)
	if not p then
		warn(`[ApartmentBuilder] no flammable part for {id}`)
		return
	end
	CollectionService:AddTag(p, Names.Tag.Flammable)
	CollectionService:AddTag(p, Names.Tag.FireStart)
	p:SetAttribute("FireId", id)
	p:SetAttribute(Names.Attr.BuildingId, BID)
end

-- cfLocal = ground/sill point, facing -Z of cfLocal. Part centre 1 stud above it.
local function rescueSpawn(parent: Instance, id: string, kind: string, cfLocal: CFrame, pose: string): Part
	local p = part(parent, id, cfLocal * CFrame.new(0, 1, 0), v(2, 2, 2), C.Mustard, {
		transparency = 1,
		collide = false,
		tags = { Names.Tag.RescueSpawn },
	})
	p.CanQuery = false
	p:SetAttribute(Names.Attr.Kind, kind)
	p:SetAttribute("SpawnId", id)
	p:SetAttribute(Names.Attr.BuildingId, BID)
	p:SetAttribute("Pose", pose)
	return p
end

------------------------------------------------------------------------------------------------
-- Elm Court: facades
------------------------------------------------------------------------------------------------
-- Facade op kinds: win, jump (open window, rescue), door, lock, firedoor, stairwin, gap.
type Op = { kind: string, c: number, name: string? }

local SIDE = {
	-- a = start, b = end (wall centre line), n = outward normal, rot = window rotation
	front = { ax = -24, az = 33.5, bx = 24, bz = 33.5, nx = 0, nz = 1, alongX = true },
	back = { ax = -24, az = 6.5, bx = 24, bz = 6.5, nx = 0, nz = -1, alongX = true },
	west = { ax = -23.5, az = 7, bx = -23.5, bz = 33, nx = -1, nz = 0, alongX = false },
	east = { ax = 23.5, az = 7, bx = 23.5, bz = 33, nx = 1, nz = 0, alongX = false },
}

local HOLE = {
	win = { w = 4, b = 3, t = 7 },
	jump = { w = 4, b = 3, t = 7 },
	door = { w = 4, b = 0, t = 7 },
	lock = { w = 4, b = 0, t = 7 },
	firedoor = { w = 4, b = 0, t = 7 },
	stairwin = { w = 3, b = 7.5, t = 11 },
	gap = { w = 8, b = 0, t = 9 },
}

local CURTAINS = { C.Curtain1, C.Curtain2, C.Curtain3, C.TealDark }

local function facade(bld: Model, rng: Random, storey: number, sideName: string, ops: { Op })
	local s = SIDE[sideName]
	local fy = SY[storey]
	-- the ground storey wall starts at y 0 so there is no gap under the floor slab
	local y0 = if storey == 1 then 0 else fy
	local lift = fy - y0
	local holes: { Hole } = {}
	for _, op in ops do
		local hs = HOLE[op.kind]
		table.insert(holes, { c = op.c, w = hs.w, b = hs.b + lift, t = hs.t + lift })
	end
	wall(bld, "BrickWall", s.ax, s.az, s.bx, s.bz, y0, H + lift, holes, { color = C.Brick, material = Enum.Material.Brick })

	local rot = if s.alongX then CFrame.identity else CFrame.Angles(0, math.pi / 2, 0)
	local sealed = storey == 2 or storey == 5
	for _, op in ops do
		local px = if s.alongX then op.c else s.ax
		local pz = if s.alongX then s.az else op.c
		local base = CFrame.new(px, fy, pz) * rot
		local nOut = if s.alongX then s.nz else s.nx -- outward along the rotated local Z
		local hs = HOLE[op.kind]
		if op.kind == "win" or op.kind == "jump" or op.kind == "stairwin" then
			local w = MapKit.window(bld, op.name or "Window", O * base * CFrame.new(0, (hs.b + hs.t) / 2, 0))
			if op.kind == "stairwin" then
				w.Size = v(3, 3.5, 0.3)
			end
			w:SetAttribute(Names.Attr.BuildingId, BID)
			if op.kind == "jump" then
				-- open window: the jumper leans out of it; trampoline target
				w.Transparency = 0.85
				w.CanCollide = false
				w:SetAttribute("Jump", true)
				w:SetAttribute("Open", true)
			end
			part(bld, "Sill", base * CFrame.new(0, hs.b - 0.25, nOut * 0.6), v(hs.w + 1.4, 0.5, 1.2), C.Stone, { collide = false })
			part(bld, "Lintel", base * CFrame.new(0, hs.t + 0.35, nOut * 0.45), v(hs.w + 1.4, 0.7, 0.9), C.Stone, { collide = false })
			if sealed and op.kind == "win" then
				-- sealed floors: a backing panel inside each window (lit room or drawn curtain)
				local lit = rng:NextNumber() < 0.35
				part(bld, "Backing", base * CFrame.new(0, (hs.b + hs.t) / 2, -nOut * 1.2), v(4.4, 4.4, 0.2), if lit then C.Lamp else MapKit.pick(rng, CURTAINS), { neon = lit, collide = false })
			end
		elseif op.kind == "door" or op.kind == "lock" or op.kind == "firedoor" then
			local d = MapKit.door(bld, op.name or "Door", O * base * CFrame.new(0, 3.5, 0), op.kind == "lock")
			d:SetAttribute(Names.Attr.BuildingId, BID)
			part(bld, "DoorHead", base * CFrame.new(0, 7.35, nOut * 0.5), v(5.6, 0.7, 1), C.Stone, { collide = false })
		end
	end
end

local function shell(bld: Model, rng: Random)
	for storey = 1, 5 do
		local front: { Op }
		if storey == 1 then
			front = { { kind = "win", c = -18 }, { kind = "win", c = -10 }, { kind = "lock", c = 0, name = "LobbyDoor" }, { kind = "win", c = 10 }, { kind = "win", c = 18 } }
		elseif storey == 4 then
			front = { { kind = "win", c = -18 }, { kind = "jump", c = -8, name = "JumpWindow401" }, { kind = "jump", c = 8, name = "JumpWindow402" }, { kind = "win", c = 18 } }
		else
			front = { { kind = "win", c = -18 }, { kind = "win", c = -8 }, { kind = "win", c = 8 }, { kind = "win", c = 18 } }
		end
		facade(bld, rng, storey, "front", front)
		facade(bld, rng, storey, "back", { { kind = "win", c = -18 }, { kind = "win", c = -11 }, { kind = "stairwin", c = 0 }, { kind = "win", c = 11 }, { kind = "win", c = 18 } })
		facade(bld, rng, storey, "west", { { kind = "win", c = 12 }, { kind = "win", c = 28 } })
		if EXPLORE[storey] then
			facade(bld, rng, storey, "east", { { kind = "win", c = 12 }, { kind = "firedoor", c = 31, name = `FireEscapeDoor{storey}` } })
		else
			facade(bld, rng, storey, "east", { { kind = "win", c = 12 }, { kind = "win", c = 28 } })
		end
	end
	-- plinth, storey cornices, top cornice + parapet
	box(bld, "Plinth", -13.15, 1.25, 34.15, 22.3, 2.5, 0.3, C.BrickDark, { material = Enum.Material.Brick })
	box(bld, "Plinth", 13.15, 1.25, 34.15, 22.3, 2.5, 0.3, C.BrickDark, { material = Enum.Material.Brick })
	box(bld, "Plinth", 0, 1.25, 5.85, 48.6, 2.5, 0.3, C.BrickDark, { material = Enum.Material.Brick })
	box(bld, "Plinth", -24.15, 1.25, 20, 0.3, 2.5, 28, C.BrickDark, { material = Enum.Material.Brick })
	box(bld, "Plinth", 24.15, 1.25, 20, 0.3, 2.5, 28, C.BrickDark, { material = Enum.Material.Brick })
	for storey = 2, 5 do
		local y = SY[storey] - 0.2
		box(bld, "Cornice", 0, y, 34.3, 49, 0.8, 0.6, C.BrickTrim, { collide = false })
		box(bld, "Cornice", 0, y, 5.7, 49, 0.8, 0.6, C.BrickTrim, { collide = false })
		box(bld, "Cornice", -24.3, y, 20, 0.6, 0.8, 28, C.BrickTrim, { collide = false })
		box(bld, "Cornice", 24.3, y, 20, 0.6, 0.8, 28, C.BrickTrim, { collide = false })
	end
	-- parapet
	wall(bld, "Parapet", -24, 33.5, 24, 33.5, ROOF, 2.5, nil, { color = C.Brick, material = Enum.Material.Brick })
	wall(bld, "Parapet", -24, 6.5, 24, 6.5, ROOF, 2.5, nil, { color = C.Brick, material = Enum.Material.Brick })
	wall(bld, "Parapet", -23.5, 7, -23.5, 33, ROOF, 2.5, nil, { color = C.Brick, material = Enum.Material.Brick })
	wall(bld, "Parapet", 23.5, 7, 23.5, 33, ROOF, 2.5, nil, { color = C.Brick, material = Enum.Material.Brick })
	box(bld, "TopCornice", 0, ROOF + 2.8, 33.6, 49.4, 0.6, 1.6, C.Stone)
	box(bld, "TopCornice", 0, ROOF + 2.8, 6.4, 49.4, 0.6, 1.6, C.Stone)
	box(bld, "TopCornice", -23.6, ROOF + 2.8, 20, 1.6, 0.6, 25.6, C.Stone)
	box(bld, "TopCornice", 23.6, ROOF + 2.8, 20, 1.6, 0.6, 25.6, C.Stone)
	box(bld, "Frieze", 0, ROOF - 0.6, 34.25, 49, 1.2, 0.5, C.BrickTrim, { collide = false })

	-- entrance canopy + name sign + steps
	box(bld, "Step", 0, 0.8, 34.9, 8, 0.4, 1.8, C.Concrete)
	box(bld, "Canopy", 0, 9.4, 37, 10, 0.6, 6, C.TealDark)
	box(bld, "CanopyEdge", 0, 9.0, 39.9, 10.2, 0.6, 0.3, C.Mustard, { collide = false })
	for _, sx in { -4.6, 4.6 } do
		cylY(bld, "CanopyPost", sx, 0.6, 39.5, 8.5, 0.5, C.Iron)
	end
	local lamp = ball(bld, "CanopyLamp", 0, 8.6, 36.5, 0.9, C.Lamp, { neon = true, collide = false })
	light(lamp, 16, 1.4)
	local sign = box(bld, "NameSign", 0, 10.6, 39.6, 9, 1.8, 0.4, C.TealDark, { collide = false })
	label(sign, Enum.NormalId.Back, "ELM COURT", C.Mustard, Enum.Font.LuckiestGuy, true)
	local num = box(bld, "HouseNumber", -3.6, 6, 34.1, 1.6, 1.2, 0.2, C.Brass, { collide = false })
	label(num, Enum.NormalId.Back, "67", C.Black, Enum.Font.FredokaOne)
end

------------------------------------------------------------------------------------------------
-- Floors, stairwell, interiors
------------------------------------------------------------------------------------------------
local function floors(bld: Model)
	-- ground floor (top y 1): lobby tile, back rooms concrete
	rect(bld, "LobbyFloor", -23, 23, 17.5, 33, 1, 1, C.Tile, false, C.TileB)
	rect(bld, "BackFloor", -23, -4.5, 7, 17.5, 1, 1, C.ConcreteDark)
	rect(bld, "BackFloor", 4.5, 23, 7, 17.5, 1, 1, C.ConcreteDark)
	rect(bld, "StairFloor", -4.5, 4.5, 7, 17.5, 1, 1, C.Concrete)
	-- upper slabs (top = floor surface), hole over the stairwell flights (x -4.5..4.5, z 7..15)
	for storey = 2, 5 do
		local top = SY[storey]
		local wood = EXPLORE[storey] == true
		local fcol = if wood then C.WoodFloor else C.Concrete
		rect(bld, "Floor", -23, 0, 22.5, 33, top, 1, fcol, wood)
		rect(bld, "Floor", 0, 23, 22.5, 33, top, 1, if wood then C.WoodFloor2 else C.Concrete, wood)
		rect(bld, "Floor", -23, -4.5, 7, 17.5, top, 1, if wood then C.WoodFloor2 else C.Concrete, wood)
		rect(bld, "Floor", 4.5, 23, 7, 17.5, top, 1, fcol, wood)
		rect(bld, "CorridorFloor", -23, 23, 17.5, 22.5, top, 1, if wood then hex("#9A6A4A") else C.Concrete)
		rect(bld, "StairLanding", -4.5, 4.5, 15, 17.5, top, 1, C.Concrete)
	end
	-- roof slab
	rect(bld, "Roof", -23, 23, 15, 33, ROOF, 1, C.RoofTar)
	rect(bld, "Roof", -23, -4.5, 7, 15, ROOF, 1, C.RoofTar)
	rect(bld, "Roof", 4.5, 23, 7, 15, ROOF, 1, C.RoofTar)
end

local function stairwell(bld: Model)
	local sw = folder(bld, "Stairwell")
	-- shaft walls (x = +-5) run lobby -> top of the roof headhouse
	box(sw, "ShaftWall", -5, 35.5, 12.25, 1, 71, 10.5, C.Concrete)
	box(sw, "ShaftWall", 5, 35.5, 12.25, 1, 71, 10.5, C.Concrete)
	local d = (15 - 9.5) / 6
	for storey = 1, 5 do
		local y = SY[storey]
		-- flight A (west lane) rises north from the landing strip to the half landing
		for i = 1, 6 do
			local z = 15 - (i - 0.5) * d
			box(sw, "Step", -2.375, y + i / 2, z, 4.25, i, d, if i % 2 == 0 then C.Concrete else C.ConcreteDark)
		end
		box(sw, "HalfLanding", 0, y + 5.5, 8.25, 9, 1, 2.5, C.Concrete)
		-- flight B (east lane) rises south from the half landing to the next floor
		for i = 1, 6 do
			local z = 9.5 + (i - 0.5) * d
			box(sw, "Step", 2.375, y + 6 + i / 2, z, 4.25, i, d, if i % 2 == 0 then C.Concrete else C.ConcreteDark)
		end
		box(sw, "Divider", 0, y + 6, 12.25, 0.5, 12, 5.5, C.ConcreteDark)
		box(sw, "SafetyStripe", 0, y + 3, 12.25, 0.7, 0.5, 5.7, C.Red, { collide = false })
		-- floor number on the landing wall
		local plate = box(sw, "FloorNo", -4.45, y + 6, 16.2, 0.2, 2, 2, C.Mustard, { collide = false })
		label(plate, Enum.NormalId.Right, tostring(storey), C.Black, Enum.Font.LuckiestGuy)
		local lamp = box(sw, "StairLamp", 0, y + 10.7, 16.5, 2, 0.3, 1, C.Lamp, { neon = true, collide = false })
		if storey % 2 == 1 then
			light(lamp, 14, 0.8)
		end
	end
	-- roof headhouse
	box(sw, "HeadhouseBack", 0, ROOF + 4.5, 6.5, 11, 9, 1, C.Brick, { material = Enum.Material.Brick })
	wall(sw, "HeadhouseFront", -5.5, 18, 5.5, 18, ROOF, 9, { { c = 0, w = 4, b = 0, t = 7 } }, { color = C.Brick, material = Enum.Material.Brick })
	local rd = MapKit.door(sw, "RoofDoor", O * CFrame.new(0, ROOF + 3.5, 18), false)
	rd:SetAttribute(Names.Attr.BuildingId, BID)
	box(sw, "HeadhouseRoof", 0, ROOF + 9.5, 12.25, 12, 1, 13.5, C.RoofTar)
	local exit = box(sw, "ExitLamp", 0, ROOF + 7.8, 18.6, 2, 0.6, 0.2, hex("#3AD07A"), { neon = true, collide = false })
	label(exit, Enum.NormalId.Back, "ROOF", C.White, Enum.Font.FredokaOne)
end

-- Interior walls of one storey. Explorable floors get the corridor + four flats; sealed floors only
-- close the stairwell.
local function storeyWalls(bld: Model, storey: number)
	local y = SY[storey]
	local h = H - 1
	if storey == 1 then
		wall(bld, "LobbyWall", -23, 18, -5.5, 18, y, h, { { c = -14, w = 4, b = 0, t = 8 } }, { color = C.Corridor, flammable = true })
		wall(bld, "LobbyWall", 5.5, 18, 23, 18, y, h, { { c = 14, w = 4, b = 0, t = 8 } }, { color = C.Corridor, flammable = true })
		wall(bld, "StairFront", -4.5, 18, 4.5, 18, y, h, { { c = 0, w = 8, b = 0, t = 9 } }, { color = C.Concrete })
		return
	end
	if not EXPLORE[storey] then
		wall(bld, "StairFront", -4.5, 18, 4.5, 18, y, h, nil, { color = C.Concrete })
		local plate = box(bld, "NoEntry", 0, y + 4, 17.45, 4, 1.4, 0.1, C.Red, { collide = false })
		label(plate, Enum.NormalId.Front, "NO ENTRY", C.White, Enum.Font.FredokaOne)
		return
	end
	local n = storey * 100
	-- corridor walls: front (z 23) to flats x01/x02, back (z 18) to x03/x04, stair opening
	wall(bld, "CorridorWall", -23, 23, 23, 23, y, h, { { c = -4, w = 4, b = 0, t = 7 }, { c = 4, w = 4, b = 0, t = 7 } }, { color = C.Corridor, flammable = true, fuel = 30 })
	wall(bld, "CorridorWall", -23, 18, -5.5, 18, y, h, { { c = -14, w = 4, b = 0, t = 7 } }, { color = C.Corridor, flammable = true, fuel = 30 })
	wall(bld, "CorridorWall", 5.5, 18, 23, 18, y, h, { { c = 14, w = 4, b = 0, t = 7 } }, { color = C.Corridor, flammable = true, fuel = 30 })
	wall(bld, "StairFront", -4.5, 18, 4.5, 18, y, h, { { c = 0, w = 8, b = 0, t = 9 } }, { color = C.Concrete })
	-- party wall between the front flats
	wall(bld, "PartyWall", 0, 23.5, 0, 33, y, h, nil, { color = if storey == 3 then C.Peach else C.Lilac, flammable = true, fuel = 30 })
	-- dado rail along the corridor (cosmetic)
	box(bld, "Dado", 0, y + 3.5, 22.4, 46, 0.4, 0.2, C.CorridorLow, { collide = false })
	box(bld, "Dado", -14.25, y + 3.5, 18.6, 17.5, 0.4, 0.2, C.CorridorLow, { collide = false })
	box(bld, "Dado", 14.25, y + 3.5, 18.6, 17.5, 0.4, 0.2, C.CorridorLow, { collide = false })
	-- flat doors (x02 locked: the axe moment) + number plates
	local doors = {
		{ x = -4, z = 23, no = n + 1, locked = false },
		{ x = 4, z = 23, no = n + 2, locked = true },
		{ x = -14, z = 18, no = n + 3, locked = false },
		{ x = 14, z = 18, no = n + 4, locked = false },
	}
	for _, dd in doors do
		local d = MapKit.door(bld, `Door{dd.no}`, O * CFrame.new(dd.x, y + 3.5, dd.z), dd.locked)
		d:SetAttribute(Names.Attr.BuildingId, BID)
		local face = if dd.z > 20 then -1 else 1 -- corridor side
		local plate = box(bld, "FlatNo", dd.x + (if dd.x < 0 then -3 else 3), y + 5.5, dd.z + face * 0.6, 1.6, 0.9, 0.2, C.Brass, { collide = false })
		label(plate, if face < 0 then Enum.NormalId.Front else Enum.NormalId.Back, tostring(dd.no), C.Black, Enum.Font.FredokaOne)
	end
	-- corridor lights + extinguisher + a plant at each end
	for _, lx in { -12, 12 } do
		local lamp = box(bld, "CorridorLamp", lx, y + 10.75, 20.5, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
		light(lamp, 16, 0.9)
	end
	prop("extinguisher", bld, at(21.6, y, 20.5, 90))
	prop("plant", bld, at(-21.6, y, 20.5, -90))
	local fno = box(bld, "FloorSign", 0, y + 9.8, 18.6, 3, 1.2, 0.2, C.TealDark, { collide = false })
	label(fno, Enum.NormalId.Back, `FLOOR {storey}`, C.Mustard, Enum.Font.FredokaOne)
end

local function curtains(bld: Model, x: number, y: number, z: number, nIn: number, color: Color3): Part
	-- two curtains inside a front/back window at x (window spans x-2..x+2), flammable
	local l = box(bld, "Curtain", x - 2.6, y + 5, z + nIn * 0.75, 1.2, 5.6, 0.3, color, { flammable = true, fuel = 25, collide = false })
	box(bld, "Curtain", x + 2.6, y + 5, z + nIn * 0.75, 1.2, 5.6, 0.3, color, { flammable = true, fuel = 25, collide = false })
	box(bld, "CurtainRod", x, y + 7.95, z + nIn * 0.75, 6.6, 0.3, 0.3, C.Brass, { collide = false })
	return l
end

local function ceilingLamp(bld: Model, x: number, y: number, z: number, lit: boolean)
	box(bld, "LampCord", x, y + 10.4, z, 0.3, 1.2, 0.3, C.Black, { collide = false })
	local b = ball(bld, "LampShade", x, y + 9.4, z, 1.6, C.Lamp, { neon = true, collide = false })
	if lit then
		light(b, 16, 0.8)
	end
end

local function rug(bld: Model, x: number, y: number, z: number, w: number, d: number, color: Color3)
	box(bld, "Rug", x, y + 0.1, z, w, 0.2, d, color, { flammable = true, collide = false })
end

local function cardboard(bld: Model, x: number, y: number, z: number, s: number)
	box(bld, "Box", x, y + s / 2, z, s, s, s, C.Cardboard, { flammable = true, fuel = 20 })
	box(bld, "BoxTape", x, y + s + 0.02, z, 0.4, 0.1, s, hex("#E8D9B0"), { collide = false })
end

local function interiors(bld: Model)
	local fires: { [string]: BasePart? } = {}
	for _, storey in { 3, 4 } do
		local y = SY[storey]
		local flat = folder(bld, `Floor{storey}`)
		local wallc = if storey == 3 then C.Peach else C.Lilac
		local _ = wallc

		-- x01 (front west): living + kitchenette
		prop("counter", flat, at(-21.7, y, 26.6, -90), { length = 6, sink = true, color = C.Sage })
		prop("fridge", flat, at(-21.6, y, 31.5, -90))
		prop("sofa", flat, at(-12.5, y, 26.2, 180), { color = if storey == 3 then C.Teal else C.Mustard })
		prop("table", flat, at(-12.5, y, 29, 0), { width = 4, depth = 2.5, height = 1.6 })
		prop("tv", flat, at(-12.5, y, 32.1, 0))
		prop("bookshelf", flat, at(-1.3, y, 27.5, 90))
		prop("plant", flat, at(-3, y, 31.6, 0))
		rug(flat, -12.5, y, 29, 8, 5, C.Terracotta)
		ceilingLamp(flat, -12, y, 28, true)
		local c1 = curtains(flat, -18, y, 33, -1, C.CurtainRed)
		if storey == 3 then
			curtains(flat, -8, y, 33, -1, C.CurtainRed)
			fires.F1 = c1
		end

		-- x02 (front east, locked): bed-sit
		prop("bed", flat, at(19, y, 26, 90), { color = if storey == 3 then C.Teal else C.Pink })
		local sofa2 = prop("sofa", flat, at(10.5, y, 27, 180), { color = if storey == 3 then C.Terracotta else C.Sage })
		prop("tv", flat, at(13, y, 32.1, 0))
		prop("plant", flat, at(2, y, 31.6, 0))
		rug(flat, 9, y, 29, 8, 4, C.Mustard)
		ceilingLamp(flat, 12, y, 28, storey == 3)
		curtains(flat, 18, y, 33, -1, C.Curtain2)
		if storey == 3 then
			curtains(flat, 8, y, 33, -1, C.Curtain2)
			fires.F2 = firstFlammable(sofa2)
		end

		-- x03 (back west): kitchen + dining
		prop("counter", flat, at(-19.5, y, 8.3, 180), { length = 6, sink = true, color = C.Cream })
		local stove = prop("counter", flat, at(-13.5, y, 8.3, 180), { length = 4, stove = true, color = C.Cream })
		prop("fridge", flat, at(-8.5, y, 8.4, 180))
		prop("table", flat, at(-14, y, 12.5, 0), { width = 4, depth = 3 })
		prop("chair", flat, at(-16.8, y, 12.5, -90))
		prop("chair", flat, at(-11.2, y, 12.5, 90))
		ceilingLamp(flat, -14, y, 12.5, storey == 3)
		if storey == 3 then
			fires.F3 = firstFlammable(stove)
		end

		-- x04 (back east)
		if storey == 3 then
			-- bedroom; the cat sits on the back window sill
			prop("bed", flat, at(19.5, y, 11, 180), { color = C.Lilac })
			prop("bookshelf", flat, at(8, y, 16.8, 0))
			prop("plant", flat, at(6.6, y, 8.2, 0))
			rug(flat, 16, y, 15.6, 6, 2.6, C.Teal)
			box(flat, "CatSill", 11, y + 2.7, 7.6, 5, 0.6, 1.2, C.Trim)
		else
			-- box room
			cardboard(flat, 8, y, 9, 2.4)
			cardboard(flat, 8.2, y + 2.4, 9.1, 2)
			cardboard(flat, 11, y, 8.6, 2.6)
			cardboard(flat, 20.5, y, 15.5, 2.4)
			prop("bookshelf", flat, at(22.3, y, 10, 90))
		end
		ceilingLamp(flat, 14, y, 12.5, false)

		-- x03 kid's toys on floor 4 (overrides nothing: the kitchen is the same layout)
		if storey == 4 then
			box(flat, "Toy", -20, y + 0.6, 15.5, 1.2, 1.2, 1.2, C.Red)
			box(flat, "Toy", -18.8, y + 0.6, 16, 1.2, 1.2, 1.2, C.Teal)
			box(flat, "Toy", -19.4, y + 1.8, 15.8, 1.2, 1.2, 1.2, C.Mustard)
		end
	end
	return fires
end

local function lobby(bld: Model)
	local lb = folder(bld, "Lobby")
	local y = SY[1]
	-- mailboxes on the west wall
	box(lb, "Mailboxes", -22.4, y + 4, 22.5, 1, 4, 7, C.Brass)
	for i = 1, 3 do
		box(lb, "MailboxLine", -21.85, y + 2 + i, 22.5, 0.1, 0.15, 6.8, hex("#8A6A2A"), { collide = false })
	end
	for i = 1, 3 do
		box(lb, "MailboxLine", -21.85, y + 4, 22.5 + (i - 2) * 1.75, 0.1, 3.8, 0.15, hex("#8A6A2A"), { collide = false })
	end
	prop("bench", lb, at(14, y, 31.6, 0), { length = 6 })
	prop("plant", lb, at(-4.4, y, 31.8, 0))
	prop("plant", lb, at(4.4, y, 31.8, 0))
	prop("plant", lb, at(21.5, y, 19.6, 0))
	rug(lb, 0, y, 22.25, 4.5, 6.5, C.Red)
	rug(lb, 0, y, 28.75, 4.5, 6.5, C.Red)
	for _, lx in { -12, 12 } do
		local lamp = box(lb, "LobbyLamp", lx, y + 10.75, 26, 4, 0.3, 1.6, C.Lamp, { neon = true, collide = false })
		light(lamp, 18, 1)
	end
	local nb = box(lb, "NoticeBoard", 22.9, y + 5.5, 21.5, 0.3, 3, 4.5, hex("#B08A5A"), { collide = false, flammable = true })
	label(nb, Enum.NormalId.Left, "PLEASE DO NOT\nMICROWAVE\nFORKS", C.Black, Enum.Font.FredokaOne)
	-- laundry (back west): three washers
	for i, wx in { -20, -16, -12 } do
		box(lb, "Washer", wx, y + 1.7, 8.6, 3.2, 3.4, 2.8, C.White)
		part(lb, "WasherDoor", CFrame.new(wx, y + 1.7, 10.05) * CFrame.Angles(0, math.pi / 2, 0), v(0.2, 2, 2), if i == 2 then C.Teal else hex("#A8D5E2"), { shape = Cyl, collide = false })
	end
	box(lb, "Basket", -8, y + 0.8, 14, 2.2, 1.6, 1.6, C.WoodLight, { flammable = true })
	box(lb, "LaundryPile", -8, y + 1.8, 14, 1.8, 0.6, 1.2, C.Pink, { flammable = true, collide = false })
	-- boiler room (back east)
	cylY(lb, "Boiler", 18, y, 11, 8, 5, C.ConcreteDark)
	cylY(lb, "BoilerBand", 18, y + 2, 11, 0.5, 5.2, C.Red)
	box(lb, "Pipe", 18, y + 9.4, 14.5, 0.8, 0.8, 7, C.Chrome, { collide = false })
	box(lb, "Pipe", 18, y + 8.6, 11, 0.8, 2.4, 0.8, C.Chrome, { collide = false })
	cardboard(lb, 9, y, 9, 2.6)
	cardboard(lb, 9.2, y + 2.6, 9.2, 2)
	cardboard(lb, 12, y, 9, 2.4)
end

------------------------------------------------------------------------------------------------
-- Fire escape (east face) and roof
------------------------------------------------------------------------------------------------
local function fireEscape(model: Model)
	local fe = folder(model, "FireEscape")
	local mat = { material = Enum.Material.DiamondPlate }
	for storey = 2, 5 do
		local y = SY[storey]
		box(fe, "Landing", 25.375, y - 0.2, 21, 2.75, 0.4, 24, C.Iron, mat)
		box(fe, "Pad", 28.125, y - 0.2, 10.25, 2.75, 0.4, 2.5, C.Iron, mat)
		box(fe, "Pad", 28.125, y - 0.2, 31.75, 2.75, 0.4, 2.5, C.Iron, mat)
		box(fe, "EndRail", 26.75, y + 3, 9.1, 5.5, 0.3, 0.3, C.IronLit, { collide = false })
		box(fe, "EndRail", 26.75, y + 3, 32.9, 5.5, 0.3, 0.3, C.IronLit, { collide = false })
		if storey ~= 2 then -- the street ladder arrives at the north end of the first landing
			box(fe, "Guard", 26.75, y + 1.5, 9.1, 5.5, 3, 0.2, C.Iron, { transparency = 1 })
		end
		if storey ~= 5 then -- the roof ladder leaves from the south end of the top landing
			box(fe, "Guard", 26.75, y + 1.5, 32.9, 5.5, 3, 0.2, C.Iron, { transparency = 1 })
		end
		for _, pz in { 9.2, 32.8 } do
			box(fe, "Post", 29.35, y + 1.5, pz, 0.3, 3, 0.3, C.IronLit, { collide = false })
		end
		-- brackets back to the wall
		for _, bz in { 12, 30 } do
			part(fe, "Bracket", CFrame.new(25.2, y - 1.6, bz) * CFrame.Angles(0, 0, math.rad(-35)), v(3.2, 0.3, 0.3), C.Iron, { collide = false })
		end
	end
	-- outer rail along the full height of the outer lane
	for storey = 2, 5 do
		box(fe, "OuterRail", 29.4, SY[storey] + 3, 21, 0.3, 0.3, 24, C.IronLit, { collide = false })
	end
	box(fe, "OuterGuard", 29.6, 37, 21, 0.2, 48, 22, C.Iron, { transparency = 1 })
	-- flights (outer lane x 26.75..29.5): every flight rises north from the south pad to the north
	-- pad of the next landing, stacked exactly one storey apart (full headroom); walk back south
	-- along the landing to the next flight.
	local function flight(y0: number, zLow: number, zHigh: number)
		local p0 = v(28.125, y0, zLow)
		local p1 = v(28.125, y0 + 12, zHigh)
		local dir = (p1 - p0).Unit
		local L = (p1 - p0).Magnitude
		local mid = (p0 + p1) / 2
		local cf = CFrame.lookAt(mid, mid + dir)
		part(fe, "Flight", cf * CFrame.new(0, -0.3, 0), v(2.6, 0.5, L), C.Iron, mat)
		for i = 1, 8 do
			local q = p0 + (p1 - p0) * (i - 0.5) / 8
			box(fe, "Tread", q.X, q.Y + 0.05, q.Z, 2.6, 0.15, 0.5, C.IronLit, { collide = false })
		end
		part(fe, "FlightRail", cf * CFrame.new(1.25, 3, 0), v(0.25, 0.25, L), C.IronLit, { collide = false })
	end
	for storey = 2, 4 do
		flight(SY[storey], 30.5, 11.5)
	end
	-- climbable trusses: street -> first landing, top landing -> roof parapet
	local t1 = Instance.new("TrussPart")
	t1.Name = "LadderTruss"
	t1.Anchored = true
	t1.Size = v(2, 12, 2)
	t1.CFrame = O * CFrame.new(28.1, 0.6 + 6, 8)
	t1.Color = C.Iron
	t1.Parent = fe
	local t2 = Instance.new("TrussPart")
	t2.Name = "RoofTruss"
	t2.Anchored = true
	t2.Size = v(2, 16, 2)
	t2.CFrame = O * CFrame.new(25.1, SY[5] + 8, 34.1)
	t2.Color = C.Iron
	t2.Parent = fe
end

local function waterTower(parent: Instance, x: number, y: number, z: number, s: number)
	local wt = folder(parent, "WaterTower")
	for _, d in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
		cylY(wt, "Leg", x + d[1] * 3 * s, y, z + d[2] * 3 * s, 7 * s, 0.6 * s, C.Iron)
	end
	box(wt, "Brace", x, y + 3.5 * s, z - 3 * s, 6.4 * s, 0.3, 0.3, C.Iron, { collide = false })
	box(wt, "Brace", x, y + 3.5 * s, z + 3 * s, 6.4 * s, 0.3, 0.3, C.Iron, { collide = false })
	box(wt, "Deck", x, y + 7 * s, z, 8.6 * s, 0.5, 8.6 * s, C.Iron)
	cylY(wt, "Tank", x, y + 7.25 * s, z, 8 * s, 8 * s, hex("#8A5A3A"), { flammable = true, fuel = 60 })
	cylY(wt, "Hoop", x, y + 9 * s, z, 0.4, 8.25 * s, C.Iron, { collide = false })
	cylY(wt, "Hoop", x, y + 12.5 * s, z, 0.4, 8.25 * s, C.Iron, { collide = false })
	cylY(wt, "Cap", x, y + 15.25 * s, z, 0.6, 8.8 * s, hex("#5A3A2A"))
	cylY(wt, "Cap", x, y + 15.85 * s, z, 1 * s, 6 * s, hex("#5A3A2A"))
	cylY(wt, "Cap", x, y + 15.85 * s + 1 * s, z, 1 * s, 3.2 * s, hex("#5A3A2A"))
	ball(wt, "Finial", x, y + 18.3 * s, z, 0.9 * s, C.Iron)
end

local function roofStuff(model: Model)
	local rf = folder(model, "Roof")
	waterTower(rf, 14, ROOF, 13, 1)
	-- AC units
	for _, a in { { -16, 12 }, { -10, 28 } } do
		box(rf, "ACUnit", a[1], ROOF + 1.5, a[2], 4, 3, 3, C.Concrete)
		part(rf, "ACFan", CFrame.new(a[1], ROOF + 3.05, a[2]) * UPRIGHT, v(0.2, 2.4, 2.4), C.Iron, { shape = Cyl, collide = false })
	end
	cylY(rf, "Vent", -20, ROOF, 20, 3, 1.2, C.Chrome)
	cylY(rf, "Antenna", 20, ROOF, 30, 9, 0.3, C.Iron)
	box(rf, "AntennaBar", 20, ROOF + 8, 30, 3, 0.2, 0.2, C.Iron, { collide = false })
	-- washing line with laundry
	cylY(rf, "LinePole", -20, ROOF, 31, 5, 0.3, C.Iron)
	cylY(rf, "LinePole", 6, ROOF, 31, 5, 0.3, C.Iron)
	box(rf, "Line", -7, ROOF + 4.8, 31, 26, 0.1, 0.1, C.White, { collide = false })
	local cols = { C.Pink, C.Teal, C.Mustard, C.White, C.Terracotta, C.Lilac }
	for i = 1, 6 do
		box(rf, "Laundry", -18 + i * 3.6, ROOF + 3.7, 31, 2, 2.2, 0.1, cols[i], { collide = false, flammable = true })
	end
	-- a rooftop chair + plant (someone's secret garden)
	prop("chair", rf, at(-4, ROOF, 26, 160), { color = C.Teal })
	prop("plant", rf, at(-1.8, ROOF, 27.5, 0))
end

------------------------------------------------------------------------------------------------
-- City: neighbours, skyline, street
------------------------------------------------------------------------------------------------
-- A plain block with a window grid on the street face. face = 1 -> front at z1 (+Z), -1 -> at z0.
local function cityBlock(parent: Instance, rng: Random, name: string, x0: number, x1: number, z0: number, z1: number, h: number, color: Color3, face: number, shop: { [string]: any }?, tower: boolean?, sparse: boolean?, backLit: boolean?)
	local b = folder(parent, name)
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	local w, d = x1 - x0, z1 - z0
	box(b, "Body", cx, h / 2, cz, w, h, d, color, { material = Enum.Material.Brick })
	box(b, "Cornice", cx, h + 0.4, cz, w + 1, 0.8, d + 1, color:Lerp(C.Black, 0.25))
	local fz = if face > 0 then z1 else z0
	local firstRow = if shop then 2 else 1
	local rows = math.floor(h / 12)
	local cols = math.max(1, math.floor((w - 4) / 8))
	local span = (w - 4) / cols
	for r = firstRow, rows do
		local wy = (r - 1) * 12 + 6.5
		for c = 1, cols do
			local wx = x0 + 2 + (c - 0.5) * span
			local lit = rng:NextNumber() < 0.3
			if sparse then
				-- far away: only the lit windows (dark ones read as the dark body)
				if lit then
					box(b, "Win", wx, wy, fz + face * 0.1, 3, 4.5, 0.3, C.Lamp, { neon = true, collide = false })
				end
			else
				box(b, "Win", wx, wy, fz + face * 0.1, 3, 4.5, 0.3, if lit then C.Lamp else C.WinDark, { neon = lit, collide = false })
				box(b, "WinSill", wx, wy - 2.5, fz + face * 0.35, 3.6, 0.4, 0.6, color:Lerp(C.White, 0.3), { collide = false })
			end
		end
	end
	if backLit then
		-- the face we see from across the street: lit windows only
		local bz = if face > 0 then z0 else z1
		for r = 1, rows do
			for c = 1, cols do
				if rng:NextNumber() < 0.35 then
					box(b, "Win", x0 + 2 + (c - 0.5) * span, (r - 1) * 12 + 6.5, bz - face * 0.1, 3, 4.5, 0.3, C.Lamp, { neon = true, collide = false })
				end
			end
		end
		box(b, "RoofBox", cx - w * 0.25, h + 1.8, cz, 4, 2.8, 4, C.Concrete)
	end
	if shop then
		local win = box(b, "Shopfront", cx, 4, fz + face * 0.15, w - 6, 5.5, 0.3, shop.glow or C.Lamp, { neon = true, transparency = 0.2, collide = false })
		local _ = win
		local cols2 = shop.awning or { C.Teal, C.Cream }
		local n = math.max(2, math.floor((w - 4) / 4))
		for i = 1, n do
			local ax = x0 + 2 + (i - 0.5) * (w - 4) / n
			part(b, "Awning", CFrame.new(ax, 8.4, fz + face * 1.6) * CFrame.Angles(face * math.rad(20), 0, 0), v((w - 4) / n, 0.3, 3.4), cols2[(i % #cols2) + 1], { collide = false })
		end
		local sign = box(b, "ShopSign", cx, 10.6, fz + face * 0.3, math.min(w - 8, 18), 2, 0.3, shop.signColor or C.TealDark, { collide = false })
		label(sign, if face > 0 then Enum.NormalId.Back else Enum.NormalId.Front, shop.text, shop.textColor or C.Mustard, Enum.Font.LuckiestGuy, true)
		local lamp = box(b, "ShopLight", cx, 3, fz + face * 3, 1, 1, 1, C.Lamp, { transparency = 1, collide = false })
		light(lamp, 18, 1.2, shop.glow or C.Lamp)
	end
	if tower then
		waterTower(b, cx + w * 0.2, h + 0.8, cz, 0.8)
	end
	return b
end

local function city(model: Model, rng: Random)
	local ct = folder(model, "City")
	-- neighbours either side of Elm Court
	cityBlock(ct, rng, "BakeryBlock", -70, -31, 4, 34, 48, hex("#6E5E78"), 1, { text = "HOT BREAD", awning = { C.Teal, C.Cream } }, true)
	cityBlock(ct, rng, "LaundromatBlock", 33, 73, 2, 34, 72, hex("#4F5A6E"), 1, { text = "LAUNDRO-MAT 24H", glow = hex("#9EE6F0"), signColor = hex("#3A2A4A"), textColor = C.Pink, awning = { C.Pink, C.White } })
	cityBlock(ct, rng, "CornerShop", -124, -76, 6, 34, 36, hex("#7A5A4A"), 1, { text = "PIZZA", awning = { C.Red, C.White } }, true)
	cityBlock(ct, rng, "DinerBlock", 79, 128, 8, 34, 24, hex("#5A6A5E"), 1, { text = "DINER", glow = hex("#FFB0C8"), signColor = C.Red, textColor = C.White, awning = { C.Red, C.Cream } })
	cityBlock(ct, rng, "WestEnd", -190, -130, 4, 34, 60, hex("#5A4E5E"), 1, nil, true, true)
	cityBlock(ct, rng, "EastEnd", 134, 190, 4, 34, 48, hex("#6A4E44"), 1, nil, false, true)
	-- skyline behind
	local sky = {
		{ -170, -110, 140, hex("#3E4660") },
		{ -105, -60, 96, hex("#4A4058") },
		{ -55, -10, 120, hex("#3A4A58") },
		{ -5, 40, 84, hex("#4E445A") },
		{ 45, 100, 132, hex("#38425A") },
		{ 105, 165, 104, hex("#463E52") },
	}
	for i, s in sky do
		cityBlock(ct, rng, `Skyline{i}`, s[1], s[2], -70, -36, s[3], s[4], 1, nil, i % 2 == 0, true)
	end
	-- across the street (south): two-storey shops facing the block (north)
	cityBlock(ct, rng, "SouthShops", -150, -60, 74, 104, 26, hex("#7A6A5A"), -1, { text = "VIDEO RENTAL", glow = hex("#C9A6FF"), signColor = hex("#2A2A4A"), textColor = C.Mustard, awning = { C.Lilac, C.White } }, false, false, true)
	cityBlock(ct, rng, "SouthOffice", 96, 160, 74, 104, 30, hex("#5E6A72"), -1, { text = "BANK", awning = { C.TealDark, C.Cream } }, true, false, true)
end

local function street(model: Model, rng: Random)
	local s = folder(model, "Street")
	-- ground
	rect(s, "Ground", -200, 200, -200, 200, 0, 2, C.Ground)
	rect(s, "Alley", -200, 200, -36, 6, 0.1, 0.2, C.AsphaltDark)
	rect(s, "Road", -200, 200, 48, 64, 0.12, 0.6, C.Asphalt)
	rect(s, "Sidewalk", -200, 200, 34, 48, 0.6, 1, C.Sidewalk)
	rect(s, "Sidewalk", -200, 200, 64, 70, 0.6, 1, C.Sidewalk)
	rect(s, "Kerb", -200, 200, 47.2, 48, 0.66, 1, C.Kerb)
	rect(s, "Kerb", -200, 200, 64, 64.8, 0.66, 1, C.Kerb)
	rect(s, "ParkLawn", -50, 90, 70, 110, 0.3, 0.6, C.Lawn)
	rect(s, "SouthLot", -200, 200, 104, 200, 0.15, 0.4, C.AsphaltDark)
	for x = -196, 196, 10 do
		if math.abs(x - 40) > 16 then
			box(s, "LaneDash", x, 0.12, 56, 5, 0.2, 0.5, C.LineYellow, { collide = false })
		end
	end
	box(s, "EdgeLine", 0, 0.12, 49.2, 400, 0.2, 0.4, C.Trim, { collide = false })
	box(s, "EdgeLine", 0, 0.12, 62.8, 400, 0.2, 0.4, C.Trim, { collide = false })
	for k = 0, 4 do
		box(s, "Zebra", -40, 0.13, 49.6 + k * 3.2, 6, 0.2, 1.6, C.White, { collide = false })
	end
	-- forecourt paving in front of Elm Court
	rect(s, "Forecourt", -24, 24, 34, 46, 0.65, 0.2, C.Paving, false, hex("#A89888"))
	-- fire lane: red kerb + yellow box where truck 67 parks
	box(s, "FireLaneKerb", 34, 0.7, 47.6, 28, 0.1, 0.8, C.Red, { collide = false })
	box(s, "FireLaneBox", 34, 0.13, 48.6, 28, 0.2, 0.4, C.LineYellow, { collide = false })
	box(s, "FireLaneBox", 34, 0.13, 57.4, 28, 0.2, 0.4, C.LineYellow, { collide = false })
	box(s, "FireLaneBox", 20.2, 0.13, 53, 0.4, 0.2, 9.2, C.LineYellow, { collide = false })
	box(s, "FireLaneBox", 47.8, 0.13, 53, 0.4, 0.2, 9.2, C.LineYellow, { collide = false })
	local fl = box(s, "FireLaneText", 34, 0.14, 53, 12, 0.1, 3, C.Asphalt, { collide = false, transparency = 1 })
	label(fl, Enum.NormalId.Top, "FIRE LANE", C.LineYellow, Enum.Font.LuckiestGuy)

	-- street lamps: building side (arm reaches over the road) and the far side
	for _, lx in { -150, -100, -50, -28, 28, 60, 100, 150 } do
		prop("streetLamp", s, at(lx, 0.6, 46.4, 180))
	end
	for _, lx in { -170, -110, -60, -10, 40, 90, 140, 180 } do
		prop("streetLamp", s, at(lx, 0.6, 65.6, 0))
	end
	-- hydrants
	for i, hp in { { -36, 46.6 }, { 52, 46.6 }, { 10, 65.4 } } do
		local h = MapKit.hydrant(s, O * CFrame.new(hp[1], 0.6, hp[2]))
		h.Name = `H{i}`
		h:SetAttribute("HydrantId", `H{i}`)
	end
	-- parked cars (south lane + one on the building side, away from the truck spot)
	prop("car", s, at(-70, 0.12, 60, -90), { color = C.Teal })
	prop("car", s, at(-104, 0.12, 52, 90), { color = C.Lilac })
	prop("car", s, at(80, 0.12, 60, -90), { color = C.Mustard, eyes = true })
	prop("car", s, at(150, 0.12, 60, -90), { color = C.Terracotta })
	-- bus shelter on the south sidewalk
	local bs = folder(s, "BusStop")
	box(bs, "ShelterRoof", -86, 9, 67.5, 10, 0.5, 4, C.TealDark)
	box(bs, "ShelterBack", -86, 4.8, 69.2, 10, 8, 0.3, hex("#A8D5E2"), { material = Enum.Material.Glass, transparency = 0.5 })
	for _, sx in { -90.8, -81.2 } do
		box(bs, "ShelterPost", sx, 4.8, 69, 0.4, 8.4, 0.4, C.Iron)
	end
	prop("bench", bs, at(-86, 0.6, 68, 0), { length = 6 })
	local stop = box(bs, "StopSign", -92, 8, 65.6, 1.6, 1.6, 0.2, C.Mustard, { collide = false })
	label(stop, Enum.NormalId.Front, "BUS", C.Black, Enum.Font.LuckiestGuy)
	box(bs, "StopPole", -92, 3.8, 65.6, 0.3, 6.4, 0.3, C.Iron)
	-- alley clutter: dumpsters + bins behind and beside the block
	for _, dpos in { { -27.5, 10 }, { 31, 4 }, { -20, 1 } } do
		box(s, "Dumpster", dpos[1], 2.1, dpos[2], 3, 3.6, 5, C.TealDark)
		box(s, "DumpsterLid", dpos[1], 4.1, dpos[2], 3.2, 0.4, 5.2, C.Iron)
	end
	for i = 1, 3 do
		box(s, "TrashBag", -27.2 + (i - 2) * 0.4, 0.8, 15 + i * 1.6, 1.6, 1.4, 1.4, C.Black, { collide = false })
	end
	-- pocket park across the road: trees, bushes, benches, a little fountain
	for _, t in { { -40, 84 }, { -22, 98 }, { 8, 86 }, { 30, 100 }, { 62, 88 }, { 84, 100 } } do
		prop("tree", s, at(t[1], 0.3, t[2], rng:NextInteger(0, 359)), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	for _, b in { { -46, 73.5 }, { 72, 73.5 }, { -10, 108 } } do
		prop("bush", s, at(b[1], 0.3, b[2], 0), { flammable = false })
	end
	prop("bench", s, at(-12, 0.3, 74, 180), { length = 6 })
	prop("bench", s, at(30, 0.3, 74, 180), { length = 6 })
	cylY(s, "FountainBase", 10, 0.3, 90, 1.2, 10, C.Concrete)
	cylY(s, "FountainWater", 10, 1.4, 90, 0.2, 8.6, hex("#4FB3D9"), { collide = false, transparency = 0.2 })
	cylY(s, "FountainPillar", 10, 1.4, 90, 3, 1.2, C.Concrete)
	ball(s, "FountainTop", 10, 4.8, 90, 1.6, C.Concrete)
	-- sidewalk trees in grates either side of the block
	for _, tx in { -90, -64, 66, 92 } do
		box(s, "TreeGrate", tx, 0.62, 41, 4, 0.1, 4, C.Iron, { collide = false })
		prop("tree", s, at(tx, 0.6, 41, rng:NextInteger(0, 359)), { variant = rng:NextInteger(1, 3), size = 0.9, flammable = false })
	end
end

------------------------------------------------------------------------------------------------
-- Scene dressing: trampoline zones, truck spot, player spawn, bystanders
------------------------------------------------------------------------------------------------
local function scene(model: Model)
	local sc = folder(model, "Scene")
	-- trampoline catch zones under the two jump windows (12 x 12 on the forecourt)
	for _, zx in { -8, 8 } do
		local zone = box(sc, "TrampolineZone", zx, 0.8, 40.5, 12, 0.4, 11, C.LineYellow, { transparency = 1, collide = false })
		zone.CanQuery = false
		zone:SetAttribute("WindowId", if zx < 0 then "JumpWindow401" else "JumpWindow402")
		CollectionService:AddTag(zone, "TrampolineZone")
		-- painted corner brackets
		for _, cx in { -1, 1 } do
			for _, cz in { -1, 1 } do
				box(sc, "ZoneMark", zx + cx * 5.4, 0.68, 40.5 + cz * 4.9, 1.6, 0.05, 0.4, C.LineYellow, { collide = false })
				box(sc, "ZoneMark", zx + cx * 5.8, 0.68, 40.5 + cz * 4.5, 0.4, 0.05, 1.6, C.LineYellow, { collide = false })
			end
		end
	end
	-- the rescue trampoline (display) ready under 401
	local tr = prop("trampoline", sc, at(-8, 0.65, 41, 0))
	if tr then
		tr:SetAttribute("Display", true)
	end

	-- TruckSpot: road lane in front of the fire lane, truck 67 nose west (-X)
	local spot = Vector3.new(34, 0.22, 53)
	local tcf = CFrame.lookAt(spot, spot + Vector3.new(-1, 0, 0))
	local ts = part(sc, "TruckSpot", tcf, v(10, 0.2, 26), C.Red, { transparency = 1, collide = false, tags = { TAG_TRUCKSPOT } })
	ts.CanQuery = false
	ts:SetAttribute(Names.Attr.LocationId, ApartmentBuilder.Id)

	-- PlayerSpawn: sidewalk pad beside the truck, facing the building
	local ps = part(sc, "PlayerSpawn", CFrame.lookAt(v(34, 0.8, 42), v(34, 0.8, 30)), v(12, 0.2, 8), C.Teal, { transparency = 1, collide = false, tags = { TAG_PLAYERSPAWN } })
	ps.CanQuery = false
	ps:SetAttribute(Names.Attr.LocationId, ApartmentBuilder.Id)

	-- pyjama bystanders watching from across the road (display only, not rescues)
	local by = folder(sc, "Bystanders")
	npc("Civilian", by, at(-22, 0.6, 67.2, 10), { color = C.Lilac })
	npc("Civilian", by, at(-17.5, 0.6, 67.6, -5), { color = C.Pink })
	npc("Dog", by, at(-19.5, 0.6, 66.8, 0))
	npc("Civilian", by, at(18, 0.6, 67.4, -15), { color = C.Mustard })
end

------------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------------
function ApartmentBuilder.Build(model: Model, origin: CFrame, rng: Random)
	O = origin
	local mapDir = script.Parent.Parent
	PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	local libDir = mapDir.Parent
	NpcBuilder = tryRequire(libDir and libDir:FindFirstChild("Rescue"), "NpcBuilder")

	model:SetAttribute("DisplayName", "Elm Court Apartments")
	model:SetAttribute("Atmosphere", "NightStreet")

	street(model, rng)
	city(model, rng)

	local bld = folder(model, "ElmCourt")
	bld:SetAttribute(Names.Attr.BuildingId, BID)
	shell(bld, rng)
	floors(bld)
	stairwell(bld)
	for storey = 1, 5 do
		storeyWalls(bld, storey)
	end
	lobby(bld)
	local fires = interiors(bld)
	fireStart(fires.F1, "F1")
	fireStart(fires.F2, "F2")
	fireStart(fires.F3, "F3")
	fireEscape(model)
	roofStuff(model)
	scene(model)

	-- rescues: two window jumpers on floor 4, unconscious neighbour in 302, cat on the 304 sill,
	-- dog in 403 (all facing out / toward the door)
	local rs = folder(bld, "RescueSpawns")
	rescueSpawn(rs, "R1", "Civilian", at(-8, SY[4], 32.4, 180), "window")
	rescueSpawn(rs, "R2", "Civilian", at(8, SY[4], 32.4, 180), "window")
	rescueSpawn(rs, "R3", "Civilian", at(12.5, SY[3], 29.5, 90), "lying")
	rescueSpawn(rs, "R4", "Cat", at(11, SY[3] + 3, 7.3, 0), "sitting")
	rescueSpawn(rs, "R5", "Dog", at(-12, SY[4], 15, 180), "sitting")

	bld.PrimaryPart = bld:FindFirstChild("LobbyFloor") :: BasePart?
end

return ApartmentBuilder
