--!strict
-- Interiors/Kit [owner: interiors]. Cheap cartoon furniture for mission-site interiors (Interiors/Furnish
-- builds them when a run binds a site). Detail that would cost parts (book spines, locker doors, board
-- doodles, cubby bins, tiles) is drawn with SurfaceGui frames on one part instead.
--
-- Every function: Kit.<name>(parent, cf, opts?) -> Model. cf = the floor point under the item's centre;
-- the item FACES -Z of cf. Wall items (board, poster, clock, sign, hoop...) take cf = the wall face at
-- floor height with -Z pointing into the room, and never touch the wall plane (no coplanar faces).
-- Parts: anchored, SmoothPlastic. Big pieces (desks, beds, shelves, counters) collide; clutter is
-- CanCollide/CanQuery/CastShadow false. Burnable parts carry tag Flammable + attr Fuel (<= 8 studs
-- each, split when longer); Furnish stamps BuildingId on them.
-- Never name a part Wall* / Partition* / Stair* (SmokeService reads those as walls / stairs).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local Kit = {}

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local hex = Color3.fromHex
local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local UPRIGHT = ANG(0, 0, math.rad(90)) -- cylinder axis X -> Y
local FACE_OUT = ANG(0, math.rad(90), 0) -- cylinder axis X -> Z (round face toward -Z)

-- docs/game/02 palette + warm cartoon accents
Kit.C = {
	SchoolLocker = hex("#CD5528"),
	SchoolWall = hex("#D2A54A"),
	SchoolWallUp = hex("#E8D9B0"),
	SchoolPillar = hex("#2F5F5A"),
	SchoolFloor = hex("#C88A54"),
	WoodFloor = hex("#C8683A"),
	RoomTeal = hex("#4F8A85"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	WoodPale = hex("#D9B27A"),
	Steel = hex("#8A8C90"),
	Chrome = hex("#D6D8DC"),
	Iron = hex("#3A3A40"),
	White = hex("#F7F4EE"),
	Cream = hex("#F2EDE4"),
	Black = hex("#1A1714"),
	Ink = hex("#2B2B30"),
	Red = hex("#C8232B"),
	AlarmRed = hex("#FF2A2A"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Peach = hex("#F2D2B0"),
	Lilac = hex("#D9C6E3"),
	Sky = hex("#9EC1CC"),
	PaleBlue = hex("#A8DADC"),
	Pink = hex("#FF7FB0"),
	Blue = hex("#3A7FD0"),
	Navy = hex("#3D5A80"),
	Green = hex("#6BCB5A"),
	Leaf = hex("#6F9A3A"),
	Chalk = hex("#2F4F3A"),
	Cork = hex("#B08A5A"),
	Glass = hex("#A8D5E2"),
	Lamp = hex("#FFF4D6"),
	LampWarm = hex("#FFE2B8"),
	ExitGreen = hex("#3AD07A"),
	Gold = hex("#E8C24A"),
	Tile = hex("#EFE7D8"),
	TileB = hex("#BFD8D8"),
	GymFloor = hex("#D9A066"),
	Orange = hex("#F4A261"),
}
local C = Kit.C
Kit.Bright = { C.Red, C.Teal, C.Mustard, C.Blue, C.Pink, C.Green, C.Terracotta, C.Lilac, C.Orange }

export type Opts = { [string]: any }

---------------------------------------------------------------------------------------------------
-- part + gui helpers
---------------------------------------------------------------------------------------------------
-- o: fuel (number = Flammable), solid (collide + query), shape, mat, neon, tr (transparency), refl
local function P(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, o: Opts?): Part
	local op = o or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	p.Size = size
	if op.shape then
		p.Shape = op.shape
	end
	p.CFrame = cf
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = if op.neon then Enum.Material.Neon else (op.mat or Enum.Material.SmoothPlastic)
	p.Color = color
	p.Transparency = op.tr or 0
	p.Reflectance = op.refl or 0
	local solid = op.solid == true
	p.CanCollide = solid
	p.CanQuery = solid or op.fuel ~= nil
	if not solid and math.max(size.X, size.Y, size.Z) < 3 then
		p.CastShadow = false
	end
	if type(op.fuel) == "number" then
		CollectionService:AddTag(p, Names.Tag.Flammable)
		p:SetAttribute(Names.Attr.Fuel, op.fuel)
	end
	p.Parent = parent
	return p
end
Kit.part = P

local function cylY(parent: Instance, name: string, cf: CFrame, h: number, dia: number, color: Color3, o: Opts?): Part
	local op = table.clone(o or {})
	op.shape = CYL
	return P(parent, name, cf * UPRIGHT, V(h, dia, dia), color, op)
end
Kit.cylY = cylY

local function ball(parent: Instance, name: string, cf: CFrame, dia: number, color: Color3, o: Opts?): Part
	local op = table.clone(o or {})
	op.shape = BALL
	return P(parent, name, cf, V(dia, dia, dia), color, op)
end

local function model(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local function done(m: Model, parent: Instance, primary: BasePart?): Model
	if primary then
		m.PrimaryPart = primary
	end
	m.Parent = parent
	return m
end

local function gui(p: BasePart, face: Enum.NormalId, pps: number?, glow: boolean?): SurfaceGui
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pps or 24
	g.MaxDistance = 140
	g.LightInfluence = if glow then 0 else 1
	g.ClipsDescendants = true
	g.Parent = p
	return g
end
Kit.gui = gui

-- Frame at scale position/size; round = corner radius (scale), rot = degrees.
local function rect(parent: Instance, x: number, y: number, w: number, h: number, color: Color3, round: number?, rot: number?): Frame
	local f = Instance.new("Frame")
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color
	f.Position = UDim2.fromScale(x, y)
	f.Size = UDim2.fromScale(w, h)
	f.Rotation = rot or 0
	if round then
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(round, 0)
		c.Parent = f
	end
	f.Parent = parent
	return f
end
Kit.rect = rect

local function text(parent: Instance, x: number, y: number, w: number, h: number, s: string, color: Color3, font: Enum.Font?, rot: number?): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromScale(x, y)
	t.Size = UDim2.fromScale(w, h)
	t.Rotation = rot or 0
	t.Text = s
	t.TextScaled = true
	t.Font = font or Enum.Font.FredokaOne
	t.TextColor3 = color
	t.Parent = parent
	return t
end
Kit.text = text

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function rngOf(o: Opts): Random
	return o.rng or Random.new(7)
end

-- Splits a long flammable run into <= 8-stud chunks along local X (FireService: one cell per part).
local function chunked(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, o: Opts): { Part }
	local n = math.max(1, math.ceil(size.X / 8 - 1e-6))
	local out = {}
	for i = 1, n do
		local x = -size.X / 2 + (i - 0.5) * size.X / n
		table.insert(out, P(parent, name, cf * CF(x, 0, 0), V(size.X / n, size.Y, size.Z), color, o))
	end
	return out
end
Kit.chunked = chunked

---------------------------------------------------------------------------------------------------
-- school
---------------------------------------------------------------------------------------------------
-- Student desk + chair (chair on +Z, the kid faces -Z). ~2.8 x 4.6 footprint.
function Kit.studentDesk(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("StudentDesk")
	local top = P(m, "DeskTop", cf * CF(0, 2.65, 0), V(2.8, 0.3, 2), C.WoodPale, { solid = true, fuel = 10 })
	P(m, "DeskLeg", cf * CF(0, 1.25, 0.2), V(2.2, 2.5, 0.3), op.frame or C.Navy)
	local seat = op.color or pick(rng, Kit.Bright)
	P(m, "ChairSeat", cf * CF(0, 1.55, 1.95), V(1.8, 0.3, 1.6), seat, { solid = true, fuel = 8 })
	P(m, "ChairBack", cf * CF(0, 2.6, 2.7), V(1.8, 1.7, 0.25), seat, { fuel = 6 })
	P(m, "ChairLeg", cf * CF(0, 0.7, 1.95), V(0.35, 1.4, 0.35), C.Steel)
	local r = rng:NextNumber()
	if r < 0.3 then
		P(m, "Book", cf * CF(rng:NextNumber(-0.6, 0.6), 2.88, 0) * ANG(0, rng:NextNumber(-0.5, 0.5), 0), V(0.9, 0.16, 1.2), pick(rng, Kit.Bright), { fuel = 4 })
	elseif r < 0.5 then
		P(m, "Paper", cf * CF(rng:NextNumber(-0.5, 0.5), 2.83, 0) * ANG(0, rng:NextNumber(-0.6, 0.6), 0), V(0.9, 0.05, 1.15), C.White, { fuel = 3 })
	elseif r < 0.62 then
		cylY(m, "PencilCup", cf * CF(0.9, 2.8, -0.4), 0.6, 0.45, pick(rng, Kit.Bright))
	end
	return done(m, parent, top)
end

-- Teacher's desk with an apple, papers, a mug and a chair behind (chair on +Z). 6 x 6 footprint.
function Kit.teacherDesk(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("TeacherDesk")
	local body = P(m, "TeacherDesk", cf * CF(0, 1.45, 0), V(5.4, 2.9, 2.4), op.color or C.Wood, { solid = true, fuel = 30 })
	P(m, "DeskTop", cf * CF(0, 3.05, 0), V(6, 0.3, 3), C.WoodLight, { solid = true, fuel = 12 })
	ball(m, "Apple", cf * CF(2.1, 3.55, -0.5), 0.7, C.Red)
	P(m, "Papers", cf * CF(-1.2, 3.35, 0), V(1.6, 0.3, 1.2), C.White, { fuel = 4 })
	cylY(m, "Mug", cf * CF(0.6, 3.2, 0.6), 0.6, 0.55, op.mug or C.Teal)
	P(m, "ChairSeat", cf * CF(0, 1.7, 2.6), V(2.2, 0.35, 2), C.Navy, { solid = true, fuel = 8 })
	P(m, "ChairBack", cf * CF(0, 3, 3.5), V(2.2, 2.3, 0.3), C.Navy, { fuel = 6 })
	P(m, "ChairLeg", cf * CF(0, 0.8, 2.6), V(0.4, 1.6, 0.4), C.Iron)
	return done(m, parent, body)
end

local DOODLES = {
	"2 + 2 = 4", "STOP, DROP\n& ROLL!", "FIRE DRILL\nFRIDAY", "a + b = c", "3 x 4 = 12", "SPELLING:\nfire  hose  axe",
	"HOMEWORK:\npg 67", "NO RUNNING\n(walk fast)", "WATER\nBEATS\nFIRE", "HAPPY\nBIRTHDAY\nMIA!", "H2O",
}

-- Penguin doodle in a scale box (black body, white belly, orange beak + feet).
local function penguinDoodle(g: Instance, x: number, y: number, s: number, ink: Color3)
	rect(g, x, y, s * 0.7, s, ink, 0.5)
	rect(g, x + s * 0.14, y + s * 0.3, s * 0.42, s * 0.62, C.White, 0.5)
	rect(g, x + s * 0.18, y + s * 0.12, s * 0.1, s * 0.1, C.White, 1)
	rect(g, x + s * 0.42, y + s * 0.12, s * 0.1, s * 0.1, C.White, 1)
	rect(g, x + s * 0.28, y + s * 0.24, s * 0.14, s * 0.07, C.Orange, 0.3)
	rect(g, x + s * 0.1, y + s * 0.95, s * 0.2, s * 0.06, C.Orange, 0.3)
	rect(g, x + s * 0.42, y + s * 0.95, s * 0.2, s * 0.06, C.Orange, 0.3)
end

local function sunDoodle(g: Instance, x: number, y: number, s: number, col: Color3)
	for k = 0, 3 do
		rect(g, x - s * 0.15, y + s * 0.47, s * 1.3, s * 0.06, col, nil, k * 45)
	end
	rect(g, x + s * 0.15, y + s * 0.15, s * 0.7, s * 0.7, col, 1)
end

local function houseDoodle(g: Instance, x: number, y: number, s: number, col: Color3)
	rect(g, x + s * 0.1, y + s * 0.45, s * 0.8, s * 0.55, col)
	rect(g, x + s * 0.2, y + s * 0.2, s * 0.6, s * 0.6, col, nil, 45).BackgroundTransparency = 0.25
	rect(g, x + s * 0.42, y + s * 0.7, s * 0.18, s * 0.3, C.Ink)
end

-- White- or chalkboard on a wall with doodles, a frame and a tray. o.w (10), o.chalk, o.text, o.rng.
function Kit.board(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w = op.w or 10
	local chalk = op.chalk == true
	local m = model("Board")
	P(m, "BoardFrame", cf * CF(0, 6, -0.08), V(w + 0.6, 5.1, 0.15), C.WoodLight)
	local b = P(m, "BoardFace", cf * CF(0, 6, -0.2), V(w, 4.5, 0.2), if chalk then C.Chalk else C.White)
	P(m, "BoardTray", cf * CF(0, 3.55, -0.45), V(w, 0.2, 0.6), C.WoodLight)
	local ink = if chalk then C.White else (op.ink or C.Blue)
	local g = gui(b, Enum.NormalId.Front, 30)
	local words = op.text or pick(rng, DOODLES)
	text(g, 0.04, 0.08, 0.5, 0.6, words, ink, Enum.Font.PermanentMarker, rng:NextNumber(-4, 4))
	local doodle = rng:NextInteger(1, 3)
	if doodle == 1 then
		penguinDoodle(g, 0.62, 0.15, 0.6 * 4.5 / w, ink)
	elseif doodle == 2 then
		sunDoodle(g, 0.64, 0.12, 0.5 * 4.5 / w, if chalk then C.Mustard else C.Orange)
	else
		houseDoodle(g, 0.64, 0.12, 0.55 * 4.5 / w, if chalk then C.Pink else C.Red)
	end
	text(g, 0.55, 0.75, 0.42, 0.2, "smile :)", if chalk then C.Pink else C.Red, Enum.Font.PermanentMarker)
	-- marker/chalk + eraser on the tray
	P(m, "Eraser", cf * CF(w * 0.3, 3.8, -0.45), V(1, 0.3, 0.4), C.Mustard)
	P(m, "Marker", cf * CF(w * 0.2, 3.72, -0.45), V(0.7, 0.14, 0.14), if chalk then C.White else C.Red)
	return done(m, parent, b)
end

-- Alphabet / banner strip on a wall: o.text, o.w, o.y (bottom height), o.bg, o.fg.
function Kit.banner(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Banner")
	local w, h = op.w or 12, op.h or 1.2
	local b = P(m, "BannerStrip", cf * CF(0, (op.y or 9.2) + h / 2, -0.07), V(w, h, 0.1), op.bg or C.Mustard, { fuel = 4 })
	local g = gui(b, Enum.NormalId.Front, 30)
	text(g, 0.02, 0.05, 0.96, 0.9, op.text or "Aa Bb Cc Dd Ee Ff Gg Hh Ii", op.fg or C.Red)
	return done(m, parent, b)
end

-- Poster: o.w, o.h, o.y (centre height), o.text, o.bg, o.fg, o.kind ("text" | "planets" | "table" | "food" | "art")
function Kit.poster(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, h = op.w or 2.6, op.h or 3.4
	local m = model("Poster")
	local p = P(m, "PosterSheet", cf * CF(0, op.y or 6.5, -0.07), V(w, h, 0.1), op.bg or pick(rng, { C.Sky, C.Mustard, C.Peach, C.Lilac, C.PaleBlue, C.Cream }), { fuel = 4 })
	local g = gui(p, Enum.NormalId.Front, 30)
	local fg = op.fg or C.Ink
	local kind = op.kind or "text"
	if kind == "planets" then
		local cols = { C.Mustard, C.Terracotta, C.Blue, C.Red, C.Orange, C.Peach, C.PaleBlue, C.Navy }
		for i, col in cols do
			local s = 0.06 + (i % 4) * 0.025
			rect(g, 0.05 + (i - 1) * 0.115, 0.5 - s / 2, s, s * w / h, col, 1)
		end
		text(g, 0.05, 0.08, 0.9, 0.2, "OUR SOLAR SYSTEM", fg)
	elseif kind == "table" then
		text(g, 0.05, 0.03, 0.9, 0.14, "PERIODIC TABLE", fg)
		for r = 0, 5 do
			for c = 0, 8 do
				if not (r == 0 and c > 0 and c < 8) then
					rect(g, 0.05 + c * 0.1, 0.22 + r * 0.12, 0.085, 0.1, Kit.Bright[(r + c) % #Kit.Bright + 1])
				end
			end
		end
	elseif kind == "food" then
		text(g, 0.05, 0.03, 0.9, 0.16, "EAT YOUR\nVEGGIES!", fg)
		rect(g, 0.15, 0.45, 0.25, 0.25 * w / h, C.Green, 1)
		rect(g, 0.55, 0.45, 0.3, 0.12, C.Orange, 0.5)
		rect(g, 0.35, 0.72, 0.28, 0.28 * w / h, C.Red, 1)
	elseif kind == "art" then
		for _ = 1, 6 do
			local s = rng:NextNumber(0.12, 0.3)
			rect(g, rng:NextNumber(0, 0.8), rng:NextNumber(0, 0.8), s, s * w / h, pick(rng, Kit.Bright), rng:NextNumber(0, 1))
		end
	else
		rect(g, 0.04, 0.04, 0.92, 0.92, C.White, 0.06).BackgroundTransparency = 0.6
		text(g, 0.08, 0.1, 0.84, 0.8, op.text or "READ!", fg)
	end
	return done(m, parent, p)
end

-- Wall clock (face toward -Z). o.y = centre height.
function Kit.clock(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Clock")
	local c = P(m, "ClockFace", cf * CF(0, op.y or 10.5, -0.12) * FACE_OUT, V(0.2, 1.8, 1.8), C.White, { shape = CYL })
	P(m, "ClockRim", cf * CF(0, op.y or 10.5, -0.06) * FACE_OUT, V(0.1, 2.05, 2.05), op.rim or C.Red, { shape = CYL })
	local g = gui(c, Enum.NormalId.Left, 40)
	rect(g, 0.48, 0.2, 0.04, 0.32, C.Ink)
	local hand = rect(g, 0.5, 0.48, 0.3, 0.04, C.Ink)
	hand.Rotation = 30
	return done(m, parent, c)
end

-- Ceiling light: cf = the ceiling point, panel hangs below. o.len (4), o.light (SurfaceLight), o.range.
function Kit.ceilingLight(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local len = op.len or 4
	local m = model("CeilingLight")
	P(m, "LightHousing", cf * CF(0, -0.15, 0), V(len + 0.4, 0.3, 1.8), C.Chrome)
	local panel = P(m, "LightPanel", cf * CF(0, -0.42, 0), V(len, 0.25, 1.3), op.color or C.Lamp, { neon = true })
	if op.light ~= false then
		local l = Instance.new("SurfaceLight")
		l.Face = Enum.NormalId.Bottom
		l.Range = op.range or 16
		l.Brightness = op.brightness or 1.1
		l.Angle = 120
		l.Color = op.lightColor or C.LampWarm
		l.Shadows = false
		l.Parent = panel
	end
	return done(m, parent, panel)
end

-- Half-lowered blinds just inside a window: cf = window centre, -Z into the room. o.w, o.h.
function Kit.blinds(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w, h = op.w or 4, op.h or 4
	local m = model("Blinds")
	local drop = h * (op.drop or 0.45)
	local inset = op.inset or 0.75 -- just inside a 1-stud wall's room face
	local b = P(m, "BlindSlats", cf * CF(0, h / 2 - drop / 2, -inset), V(w + 0.2, drop, 0.08), op.color or C.Cream)
	local g = gui(b, Enum.NormalId.Front, 20)
	for k = 0, 7 do
		rect(g, 0, k / 8 + 0.1, 1, 0.025, C.Black).BackgroundTransparency = 0.8
	end
	P(m, "BlindRail", cf * CF(0, h / 2 + 0.1, -inset), V(w + 0.4, 0.25, 0.25), C.White)
	P(m, "BlindCord", cf * CF(w / 2 - 0.2, h / 2 - drop - 0.4, -inset - 0.05), V(0.06, 0.9, 0.06), C.Cream)
	return done(m, parent, b)
end

-- Cubby shelves with coloured bins (drawn) and a couple of backpacks on top. o.w (6), o.h (3.6).
function Kit.cubbies(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, h = op.w or 6, op.h or 3.6
	local m = model("Cubbies")
	local body = chunked(m, "CubbyUnit", cf * CF(0, h / 2, 0), V(w, h, 1.6), C.WoodPale, { solid = true, fuel = 18 })
	for _, part in body do
		local g = gui(part, Enum.NormalId.Front, 20)
		local cols = math.max(1, math.floor(part.Size.X / 1.5 + 0.5))
		for r = 0, 1 do
			for c = 0, cols - 1 do
				rect(g, c / cols + 0.06 / cols, r * 0.5 + 0.05, 0.88 / cols, 0.42, C.Wood, 0.08)
				rect(g, c / cols + 0.12 / cols, r * 0.5 + 0.18, 0.76 / cols, 0.29, pick(rng, Kit.Bright), 0.1)
			end
		end
	end
	for k = 1, rng:NextInteger(1, 3) do
		local x = -w / 2 + k * w / 4 + rng:NextNumber(-0.4, 0.4)
		local bp = P(m, "Backpack", cf * CF(x, h + 0.75, 0) * ANG(0, rng:NextNumber(-0.4, 0.4), 0), V(1.3, 1.5, 0.8), pick(rng, Kit.Bright), { fuel = 6 })
		local _ = bp
	end
	return done(m, parent, body[1])
end

local SPINES = { hex("#C8232B"), hex("#2A9D8F"), hex("#E9C46A"), hex("#3A7FD0"), hex("#FF7FB0"), hex("#6BCB5A"), hex("#E76F51"), hex("#3D5A80"), hex("#D9C6E3"), hex("#F2EDE4") }

-- Bookcase: one part, book spines drawn on its front. o.w (5), o.h (7), o.depth (1.4), o.color.
function Kit.bookshelf(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, h, dp = op.w or 5, op.h or 7, op.depth or 1.4
	local m = model("Bookshelf")
	local parts = chunked(m, "Bookcase", cf * CF(0, h / 2, 0), V(w, h, dp), op.color or C.Wood, { solid = true, fuel = 30 })
	for _, part in parts do
		local g = gui(part, Enum.NormalId.Front, 20)
		local rows = math.max(2, math.floor(h / 1.8))
		for r = 0, rows - 1 do
			local y0 = 0.05 + r * (0.92 / rows)
			local rh = 0.92 / rows - 0.05
			rect(g, 0.05, y0, 0.9, rh, hex("#4A2A18"))
			local x = 0.07
			while x < 0.9 do
				local bw = rng:NextNumber(0.035, 0.07) * 5 / part.Size.X
				local bh = rh * rng:NextNumber(0.65, 0.95)
				if rng:NextNumber() < 0.08 then
					x += bw -- a gap
				else
					rect(g, x, y0 + rh - bh, math.min(bw, 0.93 - x), bh, pick(rng, SPINES))
				end
				x += bw + 0.004
			end
		end
	end
	return done(m, parent, parts[1])
end

-- Desk / shelf-top globe. cf = the surface it stands on.
function Kit.globe(parent: Instance, cf: CFrame, o: Opts?): Model
	local m = model("Globe")
	cylY(m, "GlobeStand", cf * CF(0, 0.15, 0), 0.3, 1, C.WoodLight)
	P(m, "GlobePost", cf * CF(0, 0.6, 0), V(0.15, 0.7, 0.15), C.Gold)
	local g = ball(m, "GlobeBall", cf * CF(0, 1.55, 0), 1.6, C.Blue)
	ball(m, "GlobeLand", cf * CF(0.35, 1.75, -0.3), 0.9, C.Green)
	ball(m, "GlobeLand", cf * CF(-0.4, 1.35, 0.25), 0.8, C.Green)
	return done(m, parent, g)
end

-- Draws locker doors, vents, handles and the odd sticker on a locker part's front (-Z) face.
function Kit.decorateLockers(part: BasePart, color: Color3?)
	local col = color or part.Color
	local g = gui(part, Enum.NormalId.Front, 20)
	local k = math.max(1, math.floor(part.Size.X / 2 + 0.5))
	for i = 0, k - 1 do
		local x0 = i / k
		rect(g, x0 + 0.02 / k, 0.02, 0.96 / k, 0.96, col:Lerp(C.Black, 0.12), 0.02)
		for v = 0, 2 do
			rect(g, x0 + 0.25 / k, 0.08 + v * 0.035, 0.5 / k, 0.018, col:Lerp(C.Black, 0.45))
		end
		rect(g, x0 + 0.78 / k, 0.48, 0.08 / k, 0.1, C.Chrome, 0.3)
		if (i + math.floor(part.Position.X)) % 5 == 0 then
			rect(g, x0 + 0.2 / k, 0.62, 0.5 / k, 0.12, C.Mustard).Rotation = 6 -- a sticker
		end
	end
end

-- Bank of n school lockers (doors, vents and handles drawn on one part). Opens toward -Z.
function Kit.lockers(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local n = op.n or 4
	local col = op.color or C.SchoolLocker
	local m = model("LockerBank")
	local parts = chunked(m, "Lockers", cf * CF(0, 3.25, 0), V(n * 2, 6.5, 1.5), col, { solid = true, fuel = 25 })
	for _, part in parts do
		Kit.decorateLockers(part, col)
	end
	return done(m, parent, parts[1])
end

-- Trophy case: wooden cabinet, glass front, gold cups. o.w (6).
function Kit.trophyCase(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w = op.w or 6
	local m = model("TrophyCase")
	local body = P(m, "TrophyCabinet", cf * CF(0, 3.2, 0.1), V(w, 6.4, 1.8), C.Wood, { solid = true, fuel = 30 })
	P(m, "TrophyShelf", cf * CF(0, 3.6, -0.55), V(w - 0.6, 0.2, 0.7), C.WoodPale)
	P(m, "TrophyGlass", cf * CF(0, 3.6, -0.95), V(w - 0.4, 4.6, 0.12), C.Glass, { mat = Enum.Material.Glass, tr = 0.55 })
	for i = 1, 3 do
		local x = -w / 2 + i * w / 4
		cylY(m, "TrophyBase", cf * CF(x, 1.75, -0.5), 0.5, 0.8, C.Wood)
		ball(m, "TrophyCup", cf * CF(x, 2.45, -0.5), 0.9, C.Gold)
		cylY(m, "Trophy", cf * CF(x * 0.9, 3.75, -0.5), 1, 0.6, if i == 2 then C.Chrome else C.Gold)
	end
	local sign = P(m, "TrophySign", cf * CF(0, 6.7, 0), V(w * 0.8, 0.8, 0.2), C.TealDark)
	text(gui(sign, Enum.NormalId.Front, 30), 0, 0, 1, 1, op.text or "CHAMPIONS 67", C.Mustard, Enum.Font.LuckiestGuy)
	return done(m, parent, body)
end

-- Cork notice board with pinned flyers. o.w (4), o.h (3), o.y.
function Kit.noticeBoard(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, h = op.w or 4, op.h or 3
	local m = model("NoticeBoard")
	P(m, "NoticeFrame", cf * CF(0, op.y or 6, -0.06), V(w + 0.4, h + 0.4, 0.1), C.WoodLight)
	local b = P(m, "NoticeCork", cf * CF(0, op.y or 6, -0.15), V(w, h, 0.1), C.Cork, { fuel = 5 })
	local g = gui(b, Enum.NormalId.Front, 30)
	local flyers = op.flyers or { "BAKE\nSALE!", "LOST\nCAT", "CHESS\nCLUB", "FIRE\nDRILL", "SCIENCE\nFAIR", "BAND\nTRYOUTS", "SPIRIT\nWEEK" }
	for i = 1, 4 do
		local x, y = ((i - 1) % 2) * 0.48 + rng:NextNumber(0.02, 0.08), ((i - 1) // 2) * 0.48 + rng:NextNumber(0.02, 0.08)
		local f = rect(g, x, y, 0.4, 0.4, pick(rng, { C.White, C.Mustard, C.Pink, C.PaleBlue, C.Lilac }), nil, rng:NextNumber(-8, 8))
		text(f, 0.05, 0.1, 0.9, 0.8, pick(rng, flyers), C.Ink)
		rect(g, x + 0.18, y - 0.01, 0.04, 0.04 * w / h, C.Red, 1)
	end
	return done(m, parent, b)
end

-- Water fountain on a wall.
function Kit.fountain(parent: Instance, cf: CFrame): Model
	local m = model("WaterFountain")
	local basin = P(m, "FountainBasin", cf * CF(0, 2.8, -0.75), V(1.8, 0.6, 1.3), C.Chrome)
	P(m, "FountainStem", cf * CF(0, 1.25, -0.35), V(0.7, 2.5, 0.6), C.Steel)
	P(m, "FountainSpout", cf * CF(0.4, 3.2, -0.7), V(0.2, 0.3, 0.2), C.Steel)
	return done(m, parent, basin)
end

-- Red fire-alarm pull station + bell (decor: the mission doesn't need it pulled).
function Kit.pullStation(parent: Instance, cf: CFrame): Model
	local m = model("PullStation")
	local st = P(m, "PullBox", cf * CF(0, 4.6, -0.2), V(1.2, 1.6, 0.4), C.AlarmRed)
	local g = gui(st, Enum.NormalId.Front, 40)
	text(g, 0.05, 0.05, 0.9, 0.35, "FIRE", C.White, Enum.Font.LuckiestGuy)
	rect(g, 0.2, 0.55, 0.6, 0.18, C.White, 0.3)
	P(m, "AlarmBell", cf * CF(0, 9.5, -0.25) * FACE_OUT, V(0.5, 1.6, 1.6), C.AlarmRed, { shape = CYL })
	return done(m, parent, st)
end

-- Glowing EXIT sign: cf = wall face (or ceiling point with o.hang), o.y.
function Kit.exitSign(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("ExitSign")
	local s = P(m, "ExitBox", cf * CF(0, op.y or 9, if op.hang then 0 else -0.25), V(2.4, 0.9, 0.3), C.ExitGreen, { neon = true })
	text(gui(s, Enum.NormalId.Front, 40, true), 0.05, 0.05, 0.9, 0.9, "EXIT", C.White)
	if op.hang then
		text(gui(s, Enum.NormalId.Back, 40, true), 0.05, 0.05, 0.9, 0.9, "EXIT", C.White)
	end
	return done(m, parent, s)
end

-- Door / room sign on a wall: o.text, o.y, o.w, o.bg, o.fg.
function Kit.sign(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("RoomSign")
	local s = P(m, "SignPlate", cf * CF(0, op.y or 8.2, -0.07), V(op.w or 3.6, op.h or 0.9, 0.1), op.bg or C.TealDark)
	text(gui(s, Enum.NormalId.Front, 40), 0.04, 0.08, 0.92, 0.84, op.text or "ROOM", op.fg or C.White)
	return done(m, parent, s)
end

-- Trash can (flammable). o.color.
function Kit.trashCan(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Bin")
	local c = cylY(m, "BinCan", cf * CF(0, 1.1, 0), 2.2, 1.6, op.color or C.TealDark, { fuel = 8 })
	P(m, "BinTrash", cf * CF(0.15, 2.25, 0.1) * ANG(0.3, 0.5, 0.2), V(0.6, 0.5, 0.6), C.White)
	return done(m, parent, c)
end

-- Potted plant (foliage burns). o.size (1), o.color (flowers).
function Kit.plant(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local s = op.size or 1
	local m = model("Plant")
	local pot = cylY(m, "PlantPot", cf * CF(0, 0.7 * s, 0), 1.4 * s, 1.5 * s, op.pot or C.Terracotta)
	ball(m, "PlantLeaves", cf * CF(0, 2.3 * s, 0), 2.4 * s, C.Leaf, { fuel = 10 })
	if op.color then
		ball(m, "PlantFlower", cf * CF(0.6 * s, 3.1 * s, -0.4 * s), 0.8 * s, op.color)
	end
	return done(m, parent, pot)
end

-- Floor rug (flammable, walk-through) with a drawn border / stripes. o.w, o.d, o.color, o.pattern.
function Kit.rug(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, d = op.w or 6, op.d or 4
	local m = model("Rug")
	local col = op.color or pick(rng, Kit.Bright)
	local parts = chunked(m, "RugCloth", cf * CF(0, 0.08, 0), V(w, 0.12, d), col, { fuel = 10 })
	for _, r in parts do
		r.CanQuery = false
		local g = gui(r, Enum.NormalId.Top, 12)
		local pattern = op.pattern or pick(rng, { "border", "stripes", "dots" })
		local accent = op.accent or C.Cream
		if pattern == "stripes" then
			for k = 0, 4 do
				rect(g, 0, k * 0.2 + 0.05, 1, 0.08, accent).BackgroundTransparency = 0.3
			end
		elseif pattern == "dots" then
			for k = 0, 8 do
				rect(g, (k % 3) * 0.3 + 0.1, (k // 3) * 0.3 + 0.1, 0.12, 0.12 * r.Size.X / r.Size.Z, accent, 1)
			end
		else
			local f = rect(g, 0.06, 0.06, 0.88, 0.88, col)
			local s = Instance.new("UIStroke")
			s.Color = accent
			s.Thickness = 6
			s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
			s.Parent = f
		end
	end
	return done(m, parent, parts[1])
end

-- Floor finish over a room (walk-through, query-off): o.w, o.d, o.color, o.grid (tile lines), o.lines.
function Kit.floorFinish(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w, d = op.w or 10, op.d or 10
	local m = model("FloorFinish")
	local f = P(m, "FloorTop", cf * CF(0, 0.05, 0), V(w, 0.08, d), op.color or C.Tile, { mat = op.mat })
	f.CanQuery = false
	f.CastShadow = false
	if op.grid then
		local g = gui(f, Enum.NormalId.Top, 8)
		local n = math.floor(w / (op.grid :: number))
		for k = 1, n - 1 do
			rect(g, k / n, 0, 0.004, 1, op.lines or C.White).BackgroundTransparency = 0.35
		end
		local nz = math.floor(d / (op.grid :: number))
		for k = 1, nz - 1 do
			rect(g, 0, k / nz, 1, 0.004 * w / d, op.lines or C.White).BackgroundTransparency = 0.35
		end
	end
	return done(m, parent, f)
end

-- Wainscot band along a wall (below the window sills): cf = wall face point (centre of the run), o.w, o.h.
function Kit.wainscot(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Wainscot")
	local p = P(m, "WainscotBand", cf * CF(0, (op.h or 2.8) / 2 + 0.02, -0.07), V(op.w or 10, op.h or 2.8, 0.1), op.color or C.SchoolWall)
	p.CanQuery = false
	P(m, "WainscotRail", cf * CF(0, (op.h or 2.8) + 0.12, -0.13), V(op.w or 10, 0.25, 0.22), op.rail or C.Cream).CanQuery = false
	return done(m, parent, p)
end

---------------------------------------------------------------------------------------------------
-- cafeteria / kitchen
---------------------------------------------------------------------------------------------------
-- Long cafeteria table + two benches along local X, trays + milk cartons on top. o.len (8).
function Kit.cafeTable(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local len = op.len or 8
	local m = model("CafeTable")
	local tops = chunked(m, "CafeTop", cf * CF(0, 2.5, 0), V(len, 0.35, 2.8), op.color or C.PaleBlue, { solid = true, fuel = 12 })
	for _, x in { -len / 2 + 1, len / 2 - 1 } do
		P(m, "CafeLeg", cf * CF(x, 1.15, 0), V(0.5, 2.3, 1.8), C.Steel)
	end
	for _, z in { -2.2, 2.2 } do
		chunked(m, "CafeBench", cf * CF(0, 1.4, z), V(len - 0.5, 0.35, 1.1), op.bench or C.Teal, { solid = true, fuel = 10 })
		P(m, "BenchLeg", cf * CF(0, 0.6, z), V(len - 2, 1.2, 0.3), C.Steel)
	end
	local nTrays = math.floor(len / 2.6)
	for k = 1, nTrays do
		if rng:NextNumber() < 0.75 then
			local x = -len / 2 + (k - 0.5) * len / nTrays
			local z = if k % 2 == 0 then -0.6 else 0.6
			local tray = P(m, "Tray", cf * CF(x, 2.78, z) * ANG(0, rng:NextNumber(-0.2, 0.2), 0), V(1.6, 0.15, 1.1), pick(rng, Kit.Bright))
			local _ = tray
			if rng:NextNumber() < 0.6 then
				P(m, "Milk", cf * CF(x + 0.5, 3.15, z), V(0.4, 0.6, 0.4), C.White)
			end
		end
	end
	return done(m, parent, tops[1])
end

-- Serving counter: steel line with food pans, a sneeze guard and a tray stack. o.len (8). Faces -Z (diners).
function Kit.servingCounter(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local len = op.len or 8
	local m = model("ServingCounter")
	local body = chunked(m, "ServeCounter", cf * CF(0, 1.6, 0), V(len, 3.2, 2.6), C.Steel, { solid = true, fuel = 20 })
	P(m, "SneezeGuard", cf * CF(0, 4.4, -0.2), V(len - 0.4, 0.1, 1.6), C.Glass, { mat = Enum.Material.Glass, tr = 0.5 })
	P(m, "TraySlide", cf * CF(0, 2.9, -1.7), V(len, 0.2, 0.9), C.Chrome)
	local foods = { C.Mustard, C.Green, C.Terracotta, C.Orange, C.Cream }
	local n = math.max(2, math.floor(len / 2))
	for k = 1, n do
		P(m, "FoodPan", cf * CF(-len / 2 + (k - 0.5) * len / n, 3.25, 0.2), V(len / n - 0.3, 0.12, 1.4), foods[(k - 1) % #foods + 1])
	end
	P(m, "TrayStack", cf * CF(-len / 2 + 0.9, 3.5, -1.7), V(1.6, 1, 1.1), C.Red)
	local menu = P(m, "MenuBoard", cf * CF(0, 7.6, 1.2), V(math.min(len, 6), 2.2, 0.2), C.Chalk)
	text(gui(menu, Enum.NormalId.Front, 30), 0.03, 0.05, 0.94, 0.9, op.menu or "TODAY:\nFISH STICKS", C.White, Enum.Font.PermanentMarker)
	return done(m, parent, body[1])
end

-- Kitchen counter run: cabinets + worktop, optional stove (o.stove) / sink (o.sink). o.len (6), o.color.
function Kit.counter(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local len = op.len or 6
	local m = model("Counter")
	local body = chunked(m, "CounterBody", cf * CF(0, 1.6, 0), V(len, 3.2, 2.4), op.color or C.Cream, { solid = true, fuel = 30 })
	for _, part in body do
		local g = gui(part, Enum.NormalId.Front, 16)
		local k = math.max(1, math.floor(part.Size.X / 2))
		for i = 0, k - 1 do
			rect(g, i / k + 0.03 / k, 0.12, 0.94 / k, 0.82, (op.color or C.Cream):Lerp(C.Black, 0.1), 0.05)
			rect(g, i / k + 0.42 / k, 0.2, 0.16 / k, 0.05, C.Chrome, 0.5)
		end
	end
	P(m, "Worktop", cf * CF(0, 3.32, 0), V(len + 0.2, 0.25, 2.6), op.top or C.WoodPale, { solid = true })
	if op.stove then
		local st = P(m, "Stovetop", cf * CF(op.stoveX or 0, 3.48, 0), V(2.4, 0.1, 2), C.Ink)
		local g = gui(st, Enum.NormalId.Top, 20)
		for k = 0, 3 do
			rect(g, (k % 2) * 0.5 + 0.12, (k // 2) * 0.5 + 0.12, 0.26, 0.26, C.Terracotta, 1)
		end
		cylY(m, "Pot", cf * CF((op.stoveX or 0) - 0.5, 3.55, -0.3), 1.1, 1.2, C.Chrome)
		P(m, "Hood", cf * CF(op.stoveX or 0, 7.6, 0.4), V(3, 1.4, 1.8), C.Steel)
	end
	if op.sink then
		P(m, "Sink", cf * CF(op.sinkX or 0, 3.42, 0), V(2, 0.1, 1.5), C.Chrome)
		P(m, "Tap", cf * CF(op.sinkX or 0, 3.9, 0.85), V(0.2, 0.9, 0.2), C.Chrome)
	end
	return done(m, parent, body[1])
end

-- Fridge (door faces -Z). o.color, o.magnets.
function Kit.fridge(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("Fridge")
	local b = P(m, "FridgeBody", cf * CF(0, 3.5, 0), V(3, 7, 2.6), op.color or C.White, { solid = true })
	local g = gui(b, Enum.NormalId.Front, 20)
	rect(g, 0, 0.36, 1, 0.012, C.Black).BackgroundTransparency = 0.6
	rect(g, 0.85, 0.12, 0.05, 0.18, C.Chrome, 0.5)
	rect(g, 0.85, 0.45, 0.05, 0.25, C.Chrome, 0.5)
	for _ = 1, 4 do
		rect(g, rng:NextNumber(0.1, 0.7), rng:NextNumber(0.4, 0.9), 0.1, 0.06, pick(rng, Kit.Bright), 0.3, rng:NextNumber(-15, 15))
	end
	rect(g, 0.25, 0.42, 0.35, 0.2, C.White, nil, -4) -- a kid's drawing
	return done(m, parent, b)
end

---------------------------------------------------------------------------------------------------
-- library / office / science / gym / restroom / music / art
---------------------------------------------------------------------------------------------------
-- Bean bag (flammable, walk-through).
function Kit.beanBag(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("BeanBag")
	local b = ball(m, "BeanBag", cf * CF(0, 1.1, 0), 2.8, op.color or C.Pink, { fuel = 10 })
	b.Size = V(2.8, 2.8, 2.8)
	return done(m, parent, b)
end

-- Round table + stools round it (o.n stools).
function Kit.roundTable(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("RoundTable")
	local top = cylY(m, "TableTop", cf * CF(0, 2.6, 0), 0.3, 4.4, op.color or C.WoodPale, { solid = true, fuel = 14 })
	cylY(m, "TablePost", cf * CF(0, 1.25, 0), 2.5, 0.6, C.Steel)
	for k = 1, op.n or 3 do
		local a = (k / (op.n or 3)) * math.pi * 2 + 0.4
		cylY(m, "Stool", cf * CF(math.cos(a) * 3.1, 0.85, math.sin(a) * 3.1), 1.7, 1.4, pick(rng, Kit.Bright), { fuel = 6 })
	end
	if rng:NextNumber() < 0.7 then
		P(m, "OpenBook", cf * CF(0.6, 2.85, 0.2) * ANG(0, 0.4, 0), V(1.4, 0.12, 1), C.White, { fuel = 3 })
	end
	return done(m, parent, top)
end

-- Office / reading armchair (faces -Z). o.color.
function Kit.armchair(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local col = op.color or C.Terracotta
	local m = model("Armchair")
	local seat = P(m, "ChairSeat", cf * CF(0, 1, 0), V(3, 2, 2.8), col, { solid = true, fuel = 16 })
	P(m, "ChairBack", cf * CF(0, 2.6, 1.15), V(3, 2.2, 0.6), col, { fuel = 8 })
	for _, x in { -1.6, 1.6 } do
		P(m, "ChairArm", cf * CF(x, 1.7, 0.1), V(0.5, 1.2, 2.8), col:Lerp(C.Black, 0.12))
	end
	return done(m, parent, seat)
end

-- Filing cabinet (drawers drawn). o.color.
function Kit.filingCabinet(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("FilingCabinet")
	local b = P(m, "Cabinet", cf * CF(0, 2.5, 0), V(2, 5, 2.4), op.color or C.Steel, { solid = true, fuel = 20 })
	local g = gui(b, Enum.NormalId.Front, 20)
	for k = 0, 3 do
		rect(g, 0.06, 0.04 + k * 0.24, 0.88, 0.2, (op.color or C.Steel):Lerp(C.White, 0.15), 0.05)
		rect(g, 0.38, 0.1 + k * 0.24, 0.24, 0.04, C.Iron, 0.5)
	end
	return done(m, parent, b)
end

-- Flag on a floor stand. o.color.
function Kit.flag(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Flag")
	cylY(m, "FlagBase", cf * CF(0, 0.2, 0), 0.4, 1.4, C.Gold)
	local pole = cylY(m, "FlagPole", cf * CF(0, 4, 0), 7.4, 0.25, C.Gold)
	local f = P(m, "FlagCloth", cf * CF(1.3, 6.4, 0), V(2.4, 1.6, 0.08), op.color or C.Teal, { fuel = 4 })
	rect(gui(f, Enum.NormalId.Front, 20), 0, 0.4, 1, 0.2, C.Mustard)
	return done(m, parent, pole)
end

-- Lab bench: black-top cabinet run with a sink, beakers and two stools (on +Z). o.len (6).
function Kit.labBench(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local len = op.len or 6
	local m = model("LabBench")
	local body = chunked(m, "LabCabinet", cf * CF(0, 1.5, 0), V(len, 3, 2.4), C.WoodLight, { solid = true, fuel = 25 })
	P(m, "LabTop", cf * CF(0, 3.12, 0), V(len + 0.2, 0.25, 2.6), C.Ink, { solid = true })
	P(m, "LabSink", cf * CF(-len / 2 + 1, 3.28, 0), V(1.4, 0.1, 1.2), C.Chrome)
	P(m, "LabTap", cf * CF(-len / 2 + 1, 3.9, -0.8), V(0.15, 1.1, 0.15), C.Chrome)
	local glows = { C.Green, C.Pink, hex("#7FF5F0"), C.Mustard }
	for k = 1, 3 do
		local x = -len / 2 + 2 + k * (len - 3) / 4
		local col = pick(rng, glows)
		cylY(m, "Beaker", cf * CF(x, 3.25, rng:NextNumber(-0.5, 0.3)), 0.9, 0.6, C.Glass, { mat = Enum.Material.Glass, tr = 0.5 })
		cylY(m, "Potion", cf * CF(x, 3.25, rng:NextNumber(-0.5, 0.3)), 0.5, 0.45, col, { neon = true })
	end
	P(m, "BunsenBurner", cf * CF(len / 2 - 1, 3.6, -0.3), V(0.4, 0.7, 0.4), C.Steel)
	for _, x in { -len / 4, len / 4 } do
		cylY(m, "LabStool", cf * CF(x, 1, 2.1), 2, 1.3, C.Navy, { solid = true, fuel = 6 })
	end
	return done(m, parent, body[1])
end

-- Googly eyes (the game's running gag) on furniture mascots; small and non-colliding.
local function eyes(parent: Instance, cf: CFrame)
	for _, s in { -1, 1 } do
		local e = ball(parent, "Eye", cf * CF(s * 0.28, 0, 0), 0.42, C.White)
		e.CastShadow = false
		ball(parent, "Pupil", cf * CF(s * 0.28, -0.04, -0.16), 0.18, C.Black)
	end
end

-- Plastic skeleton model on a stand (science lab mascot, flammable it is not).
function Kit.skeleton(parent: Instance, cf: CFrame): Model
	local m = model("Skeleton")
	cylY(m, "SkelStand", cf * CF(0, 0.15, 0), 0.3, 1.6, C.Steel)
	P(m, "SkelPole", cf * CF(0, 3, 0.4), V(0.15, 6, 0.15), C.Steel)
	local skull = ball(m, "SkelSkull", cf * CF(0, 5.6, 0), 1.2, C.White)
	P(m, "SkelRibs", cf * CF(0, 4.3, 0), V(1.4, 1.4, 0.6), C.White)
	P(m, "SkelSpine", cf * CF(0, 2.9, 0), V(0.25, 2.4, 0.25), C.White)
	P(m, "SkelLegs", cf * CF(0, 1.3, 0), V(0.9, 2.2, 0.25), C.White)
	eyes(m, cf * CF(0, 5.7, -0.55))
	return done(m, parent, skull)
end

-- Basketball hoop on a wall (cf = wall face at floor height). o.y (rim height, 9).
function Kit.hoop(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local y = op.y or 9
	local m = model("Hoop")
	local bb = P(m, "Backboard", cf * CF(0, y + 1.6, -1.2), V(5, 3.4, 0.25), C.White)
	local g = gui(bb, Enum.NormalId.Front, 20)
	local f = rect(g, 0.32, 0.45, 0.36, 0.38, C.White)
	local s = Instance.new("UIStroke")
	s.Color = C.Red
	s.Thickness = 5
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	P(m, "HoopArm", cf * CF(0, y + 1.6, -0.6), V(0.5, 0.5, 1.2), C.Steel)
	P(m, "HoopRim", cf * CF(0, y, -2.4) * UPRIGHT, V(0.2, 2, 2), C.Terracotta, { shape = CYL })
	P(m, "HoopNet", cf * CF(0, y - 0.8, -2.4) * UPRIGHT, V(1.4, 1.7, 1.7), C.White, { shape = CYL, tr = 0.5 })
	return done(m, parent, bb)
end

-- Folding bleachers along local X (3 tiers rising toward +Z), flammable 8-stud chunks. o.len.
function Kit.bleachers(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local len = op.len or 14
	local tiers = op.tiers or 3
	local m = model("Bleachers")
	local first
	for t = 1, tiers do
		local parts = chunked(m, "BleacherTier", cf * CF(0, t * 0.5, (t - (tiers + 1) / 2) * 1.6), V(len, t * 1.0, 1.6), if t % 2 == 0 then C.WoodLight else C.Wood, { solid = true, fuel = 30 })
		first = first or parts[1]
	end
	return done(m, parent, first)
end

-- Stack of gym mats (flammable) + a ball cart beside it.
function Kit.gymMats(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("GymMats")
	local mats = {}
	for k = 0, 2 do
		table.insert(mats, P(m, "GymMat", cf * CF(k * 0.15, 0.4 + k * 0.8, 0) * ANG(0, k * 0.05, 0), V(6, 0.8, 4), if k % 2 == 0 then C.Blue else C.Red, { solid = true, fuel = 20 }))
	end
	if op.cart ~= false then
		P(m, "BallCart", cf * CF(4.6, 1.2, 0), V(2.6, 2, 2), C.Steel)
		for k = 0, 3 do
			ball(m, "Ball", cf * CF(4.0 + (k % 2) * 1.2, 2.9, -0.5 + (k // 2) * 1.1), 1.2, if k % 2 == 0 then C.Orange else C.Red)
		end
	end
	return done(m, parent, mats[1])
end

-- Scoreboard on a wall. o.y.
function Kit.scoreboard(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Scoreboard")
	local s = P(m, "ScoreBoard", cf * CF(0, op.y or 9.5, -0.25), V(6, 2.6, 0.4), C.Black)
	local g = gui(s, Enum.NormalId.Front, 30, true)
	text(g, 0.03, 0.05, 0.45, 0.4, "HOME", C.White)
	text(g, 0.52, 0.05, 0.45, 0.4, "GUEST", C.White)
	text(g, 0.03, 0.45, 0.45, 0.5, "67", C.Mustard, Enum.Font.LuckiestGuy)
	text(g, 0.52, 0.45, 0.45, 0.5, "0", C.Red, Enum.Font.LuckiestGuy)
	return done(m, parent, s)
end

-- Restroom stall run along local X: n stalls (doors ajar toward -Z), a toilet in each. 3.6 wide each.
function Kit.stalls(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local n = op.n or 2
	local dp = op.depth or 4.6
	local col = op.color or C.Teal
	local m = model("Stalls")
	local first
	for k = 0, n do
		local x = -n * 1.8 + k * 3.6
		local panel = P(m, "StallPanel", cf * CF(x, 3.5, 0), V(0.2, 5.6, dp), col, { solid = true })
		first = first or panel
	end
	for k = 0, n - 1 do
		local x = -n * 1.8 + (k + 0.5) * 3.6
		-- door hinged on the left, swung ~35 degrees open into the aisle
		P(m, "StallDoor", cf * CF(x - 1.6, 3.5, -dp / 2) * ANG(0, math.rad(-35), 0) * CF(1.5, 0, 0), V(3, 5.2, 0.15), col:Lerp(C.White, 0.15))
		cylY(m, "ToiletBowl", cf * CF(x, 0.75, 0.6), 1.5, 1.5, C.White, { solid = true })
		P(m, "ToiletTank", cf * CF(x, 1.9, dp / 2 - 0.5), V(1.4, 1.6, 0.7), C.White)
		P(m, "ToiletLid", cf * CF(x, 1.55, 0.6), V(1.4, 0.12, 1.4), C.Cream)
		P(m, "TPRoll", cf * CF(x + 1.45, 2.6, 0.4) * UPRIGHT, V(0.6, 0.5, 0.5), C.White, { shape = CYL, fuel = 3 })
	end
	return done(m, parent, first)
end

-- Sink counter with n basins + a mirror above (cf = wall face). o.n.
function Kit.sinks(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local n = op.n or 2
	local w = n * 2.6
	local m = model("Sinks")
	local c = P(m, "SinkCounter", cf * CF(0, 2.8, -1), V(w, 0.4, 1.8), C.Cream, { solid = true })
	P(m, "SinkApron", cf * CF(0, 2.2, -1.75), V(w, 0.8, 0.2), C.Cream)
	for k = 1, n do
		local x = -w / 2 + (k - 0.5) * 2.6
		P(m, "Basin", cf * CF(x, 2.97, -1.1), V(1.5, 0.08, 1.1), C.White)
		P(m, "SinkTap", cf * CF(x, 3.4, -0.4), V(0.2, 0.8, 0.2), C.Chrome)
	end
	P(m, "Mirror", cf * CF(0, 5.4, -0.12), V(w - 0.4, 2.8, 0.1), C.Glass, { refl = 0.35 })
	P(m, "Soap", cf * CF(w / 2 - 0.4, 3.3, -0.5), V(0.5, 0.7, 0.5), C.Pink)
	return done(m, parent, c)
end

-- Paper-towel dispenser / hand dryer on a wall.
function Kit.handDryer(parent: Instance, cf: CFrame): Model
	local m = model("HandDryer")
	local d = P(m, "Dryer", cf * CF(0, 4.6, -0.4), V(1.4, 1.2, 0.8), C.Chrome)
	return done(m, parent, d)
end

-- Upright piano (faces -Z) + bench.
function Kit.piano(parent: Instance, cf: CFrame): Model
	local m = model("Piano")
	local b = P(m, "PianoBody", cf * CF(0, 2.4, 0.4), V(5, 4.8, 1.8), C.Ink, { solid = true, fuel = 30 })
	local keys = P(m, "PianoKeys", cf * CF(0, 2.6, -0.8), V(4.6, 0.2, 0.9), C.White)
	local g = gui(keys, Enum.NormalId.Top, 30)
	for k = 0, 13 do
		if k % 7 ~= 2 and k % 7 ~= 6 then
			rect(g, k / 14 + 0.045, 0, 0.03, 0.6, C.Black)
		end
	end
	P(m, "PianoBench", cf * CF(0, 1.4, -2.4), V(3.4, 0.4, 1.2), C.Ink, { solid = true, fuel = 8 })
	return done(m, parent, b)
end

-- Drum kit (kick + two drums + cymbal).
function Kit.drums(parent: Instance, cf: CFrame): Model
	local m = model("Drums")
	local kick = P(m, "KickDrum", cf * CF(0, 1.3, 0) * FACE_OUT, V(1.6, 2.6, 2.6), C.Red, { shape = CYL, solid = true })
	cylY(m, "TomDrum", cf * CF(-1.8, 1.8, 0.5), 1.2, 1.6, C.Red)
	cylY(m, "SnareDrum", cf * CF(1.6, 1.9, 0.6), 0.9, 1.5, C.Chrome)
	cylY(m, "Cymbal", cf * CF(-2.3, 4, 1.3), 0.1, 1.8, C.Gold)
	P(m, "CymbalStand", cf * CF(-2.3, 2, 1.3), V(0.15, 4, 0.15), C.Steel)
	return done(m, parent, kick)
end

-- Music stand / art easel (flammable canvas) - small and walk-through.
function Kit.easel(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("Easel")
	P(m, "EaselLegs", cf * CF(0, 2.2, 0.3) * ANG(math.rad(-10), 0, 0), V(2.6, 4.4, 0.3), C.WoodLight)
	local canvas = P(m, "EaselCanvas", cf * CF(0, 3.9, 0) * ANG(math.rad(-10), 0, 0), V(2.6, 2.6, 0.15), C.White, { fuel = 6 })
	local g = gui(canvas, Enum.NormalId.Front, 24)
	for _ = 1, 4 do
		local s = rng:NextNumber(0.2, 0.45)
		rect(g, rng:NextNumber(0, 0.7), rng:NextNumber(0, 0.7), s, s, pick(rng, Kit.Bright), rng:NextNumber(0, 1))
	end
	return done(m, parent, canvas)
end

-- Paint splat on the floor (decal-thin, walk-through).
function Kit.splat(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("Splat")
	local dia = rng:NextNumber(1, 2)
	local s = P(m, "PaintSplat", cf * CF(0, 0.04, 0) * UPRIGHT, V(0.06, dia, dia), pick(rng, Kit.Bright), { shape = CYL })
	s.CanQuery = false
	return done(m, parent, s)
end

---------------------------------------------------------------------------------------------------
-- homes: living room, kitchen, bedrooms, bathroom
---------------------------------------------------------------------------------------------------
-- Sofa (faces -Z): seat, back, arms, two cushions. o.w (7), o.color.
function Kit.sofa(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w = op.w or 7
	local col = op.color or C.Teal
	local m = model("Sofa")
	local seat = P(m, "SofaSeat", cf * CF(0, 0.85, 0.15), V(w, 1.7, 3.1), col, { solid = true, fuel = 25 })
	P(m, "SofaBack", cf * CF(0, 2.35, 1.3), V(w, 1.9, 0.8), col:Lerp(C.Black, 0.1), { fuel = 15 })
	for _, x in { -w / 2 + 0.4, w / 2 - 0.4 } do
		P(m, "SofaArm", cf * CF(x, 2, 0.15), V(0.8, 1.2, 3.1), col:Lerp(C.Black, 0.15))
	end
	for _, x in { -w / 4, w / 4 } do
		P(m, "Cushion", cf * CF(x, 1.85, 0.1), V(w / 2 - 1, 0.4, 2.4), col:Lerp(C.White, 0.12), { fuel = 6 })
	end
	if op.pillow ~= false then
		P(m, "Pillow", cf * CF(-w / 2 + 1.3, 2.4, 0.6) * ANG(0.3, 0, 0.2), V(1.2, 1.2, 0.4), op.accent or C.Mustard, { fuel = 4 })
	end
	return done(m, parent, seat)
end

-- Low coffee table with a magazine and a mug. o.w (4), o.d (2.4).
function Kit.coffeeTable(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, d = op.w or 4, op.d or 2.4
	local m = model("CoffeeTable")
	local top = P(m, "TableTop", cf * CF(0, 1.5, 0), V(w, 0.3, d), op.color or C.WoodLight, { solid = true, fuel = 12 })
	P(m, "TableBase", cf * CF(0, 0.7, 0), V(w - 0.8, 1.3, d - 0.6), C.Wood)
	P(m, "Magazine", cf * CF(-0.6, 1.7, 0) * ANG(0, rng:NextNumber(-0.5, 0.5), 0), V(1.1, 0.08, 1.4), pick(rng, Kit.Bright), { fuel = 3 })
	cylY(m, "Mug", cf * CF(0.9, 1.65, 0.2), 0.5, 0.45, pick(rng, Kit.Bright))
	return done(m, parent, top)
end

-- TV on a low stand (screen faces -Z), glowing cartoon on screen. o.w (5).
function Kit.tv(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w = op.w or 5
	local m = model("TV")
	local stand = P(m, "TVStand", cf * CF(0, 1, 0), V(w + 1, 2, 1.8), op.color or C.Wood, { solid = true, fuel = 18 })
	P(m, "TVBody", cf * CF(0, 3.6, 0.2), V(w, 3, 0.35), C.Ink)
	local scr = P(m, "TVScreen", cf * CF(0, 3.6, 0.0), V(w - 0.4, 2.6, 0.06), C.Navy, { neon = true })
	local g = gui(scr, Enum.NormalId.Front, 20, true)
	rect(g, 0, 0.7, 1, 0.3, C.Green)
	sunDoodle(g, 0.65, 0.08, 0.3, C.Mustard)
	penguinDoodle(g, 0.15 + rng:NextNumber(0, 0.3), 0.3, 0.45, C.Ink)
	P(m, "GameConsole", cf * CF(w / 2 - 0.5, 2.15, -0.2), V(1, 0.3, 0.8), C.White)
	return done(m, parent, stand)
end

-- Floor lamp with a warm PointLight.
function Kit.floorLamp(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("FloorLamp")
	cylY(m, "LampBase", cf * CF(0, 0.15, 0), 0.3, 1.2, C.Iron)
	P(m, "LampPole", cf * CF(0, 2.6, 0), V(0.2, 4.8, 0.2), C.Iron)
	local shade = cylY(m, "LampShade", cf * CF(0, 5.4, 0), 1.2, 1.6, op.color or C.Cream, { fuel = 4 })
	local l = Instance.new("PointLight")
	l.Color = C.LampWarm
	l.Range = 12
	l.Brightness = 0.9
	l.Shadows = false
	l.Parent = shade
	return done(m, parent, shade)
end

-- Ceiling pendant (cf = ceiling point): cord + glowing shade + PointLight.
function Kit.pendant(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Pendant")
	P(m, "PendantCord", cf * CF(0, -0.9, 0), V(0.12, 1.8, 0.12), C.Iron)
	local bulb = ball(m, "PendantBulb", cf * CF(0, -2, 0), 0.9, C.Lamp, { neon = true })
	P(m, "PendantShade", cf * CF(0, -1.75, 0), V(1.6, 0.5, 1.6), op.color or C.Mustard)
	if op.light ~= false then
		local l = Instance.new("PointLight")
		l.Color = C.LampWarm
		l.Range = op.range or 16
		l.Brightness = 0.9
		l.Shadows = false
		l.Parent = bulb
	end
	return done(m, parent, bulb)
end

-- Dining table with chairs (chairs on +-X sides). o.w (5), o.n (chairs per side, 2).
function Kit.diningSet(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w = op.w or 5
	local m = model("DiningSet")
	local top = P(m, "DiningTop", cf * CF(0, 2.6, 0), V(w, 0.3, 3), op.color or C.WoodLight, { solid = true, fuel = 18 })
	P(m, "DiningLegs", cf * CF(0, 1.2, 0), V(w - 1, 2.4, 1.8), C.Wood)
	local seat = op.seat or pick(rng, Kit.Bright)
	local n = op.n or 2
	for k = 1, n do
		local x = -w / 2 + (k - 0.5) * w / n
		for _, sz in { -1, 1 } do
			P(m, "ChairSeat", cf * CF(x, 1.55, sz * 2.1), V(1.7, 0.3, 1.6), seat, { solid = true, fuel = 6 })
			P(m, "ChairBack", cf * CF(x, 2.6, sz * 2.8), V(1.7, 1.8, 0.25), C.Wood, { fuel = 4 })
		end
	end
	P(m, "FruitBowl", cf * CF(0, 2.9, 0), V(1.2, 0.3, 1.2), C.Cream)
	ball(m, "Fruit", cf * CF(0.2, 3.15, 0), 0.5, C.Red)
	ball(m, "Fruit", cf * CF(-0.25, 3.15, 0.15), 0.5, C.Orange)
	return done(m, parent, top)
end

-- Wall cabinets above a counter (cf = wall face at floor height). o.w, o.y (bottom), o.color.
function Kit.wallCabinets(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w = op.w or 6
	local m = model("WallCabinets")
	local c = P(m, "Cupboards", cf * CF(0, (op.y or 6.4) + 1, -0.8), V(w, 2, 1.4), op.color or C.Cream)
	local g = gui(c, Enum.NormalId.Front, 16)
	local k = math.max(1, math.floor(w / 2))
	for i = 0, k - 1 do
		rect(g, i / k + 0.03 / k, 0.08, 0.94 / k, 0.84, (op.color or C.Cream):Lerp(C.Black, 0.1), 0.05)
		rect(g, i / k + 0.45 / k, 0.7, 0.1 / k, 0.06, C.Chrome, 0.5)
	end
	return done(m, parent, c)
end

-- Bed (headboard on +Z, foot toward -Z): frame, mattress, blanket, pillows. o.w (5), o.l (8), o.color.
function Kit.bed(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, l = op.w or 5, op.l or 8
	local col = op.color or pick(rng, Kit.Bright)
	local m = model("Bed")
	local frame = P(m, "BedFrame", cf * CF(0, 0.6, 0), V(w, 1.2, l), op.frame or C.Wood, { solid = true, fuel = 20 })
	P(m, "Mattress", cf * CF(0, 1.55, 0), V(w - 0.2, 0.7, l - 0.2), C.White, { fuel = 10 })
	P(m, "Blanket", cf * CF(0, 1.95, -l * 0.12), V(w, 0.25, l * 0.72), col, { fuel = 8 })
	P(m, "Headboard", cf * CF(0, 2.2, l / 2 + 0.15), V(w + 0.2, 3.2, 0.4), op.frame or C.Wood, { fuel = 10 })
	for _, x in { -w / 4, w / 4 } do
		if w >= 4.5 or x < 0 then
			P(m, "BedPillow", cf * CF(x, 2.15, l / 2 - 1.1), V(w / 2 - 0.4, 0.5, 1.2), C.Cream, { fuel = 3 })
		end
	end
	if op.plush ~= false and rng:NextNumber() < 0.5 then
		local pc = cf * CF(w / 4, 2.6, l / 2 - 2)
		ball(m, "Plushie", pc, 0.9, pick(rng, { C.Pink, C.Mustard, C.Ink }))
	end
	return done(m, parent, frame)
end

-- Nightstand with a small glowing lamp.
function Kit.nightstand(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Nightstand")
	local b = P(m, "Nightstand", cf * CF(0, 1, 0), V(1.8, 2, 1.6), op.color or C.WoodLight, { solid = true, fuel = 10 })
	cylY(m, "LampFoot", cf * CF(0, 2.3, 0.2), 0.6, 0.4, C.Iron)
	local sh = cylY(m, "LampShade", cf * CF(0, 2.9, 0.2), 0.7, 0.9, op.shade or C.Mustard, { neon = true })
	local l = Instance.new("PointLight")
	l.Color = C.LampWarm
	l.Range = 8
	l.Brightness = 0.6
	l.Shadows = false
	l.Parent = sh
	return done(m, parent, b)
end

-- Wardrobe / dresser (drawers drawn). o.w (4), o.h (7 wardrobe | 3.6 dresser), o.color.
function Kit.wardrobe(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w, h = op.w or 4, op.h or 7
	local col = op.color or C.WoodLight
	local m = model(if h > 5 then "Wardrobe" else "Dresser")
	local b = P(m, "Cabinet", cf * CF(0, h / 2, 0), V(w, h, 2), col, { solid = true, fuel = 25 })
	local g = gui(b, Enum.NormalId.Front, 16)
	if h > 5 then
		rect(g, 0.04, 0.03, 0.44, 0.94, col:Lerp(C.Black, 0.1), 0.03)
		rect(g, 0.52, 0.03, 0.44, 0.94, col:Lerp(C.Black, 0.1), 0.03)
		rect(g, 0.42, 0.45, 0.03, 0.1, C.Chrome, 0.5)
		rect(g, 0.55, 0.45, 0.03, 0.1, C.Chrome, 0.5)
	else
		for k = 0, 2 do
			rect(g, 0.05, 0.05 + k * 0.31, 0.9, 0.27, col:Lerp(C.Black, 0.1), 0.05)
			rect(g, 0.42, 0.15 + k * 0.31, 0.16, 0.06, C.Chrome, 0.5)
		end
		if op.mirror ~= false then
			P(m, "Mirror", cf * CF(0, h + 1.6, 0.6), V(w * 0.6, 2.6, 0.15), C.Glass, { refl = 0.3 })
		end
		cylY(m, "Perfume", cf * CF(w * 0.3, h + 0.35, -0.2), 0.7, 0.4, C.Pink)
	end
	return done(m, parent, b)
end

-- Bunk bed along local X (ladder at +X end). o.color.
function Kit.bunkBed(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("BunkBed")
	local first
	for k, y in { 0.9, 4.2 } do
		local base = P(m, "BunkFrame", cf * CF(0, y, 0), V(7, 0.6, 3.6), C.WoodLight, { solid = true, fuel = 14 })
		first = first or base
		P(m, "BunkMattress", cf * CF(0, y + 0.55, 0), V(6.6, 0.5, 3.3), C.White, { fuel = 6 })
		P(m, "BunkBlanket", cf * CF(-0.6, y + 0.85, 0), V(5, 0.2, 3.4), if k == 1 then (op.color or pick(rng, Kit.Bright)) else pick(rng, Kit.Bright), { fuel = 5 })
	end
	for _, x in { -3.4, 3.4 } do
		for _, z in { -1.7, 1.7 } do
			P(m, "BunkPost", cf * CF(x, 2.8, z), V(0.35, 5.6, 0.35), C.Wood)
		end
	end
	P(m, "BunkRail", cf * CF(0, 5.4, -1.7), V(7, 0.3, 0.2), C.Wood)
	for k = 0, 3 do
		P(m, "LadderRung", cf * CF(3.65, 1 + k * 1.1, -0.6), V(0.2, 0.2, 1.4), C.Wood)
	end
	return done(m, parent, first)
end

-- Study desk against a wall (kid sits on +Z), lamp + laptop + chair. o.w (4).
function Kit.desk(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w = op.w or 4
	local m = model("Desk")
	local top = P(m, "DeskTop", cf * CF(0, 2.65, 0), V(w, 0.3, 2), op.color or C.WoodLight, { solid = true, fuel = 12 })
	P(m, "DeskDrawers", cf * CF(w / 2 - 0.8, 1.25, 0), V(1.4, 2.5, 1.8), C.Wood)
	P(m, "Laptop", cf * CF(-0.4, 2.9, -0.1), V(1.4, 0.1, 1), C.Ink)
	local scr = P(m, "LaptopScreen", cf * CF(-0.4, 3.45, -0.55) * ANG(math.rad(-15), 0, 0), V(1.4, 1, 0.08), C.Sky, { neon = true })
	scr.CastShadow = false
	cylY(m, "DeskLampShade", cf * CF(w / 2 - 0.5, 3.6, -0.4), 0.5, 0.7, op.lamp or pick(rng, Kit.Bright), { neon = true })
	P(m, "DeskLampArm", cf * CF(w / 2 - 0.5, 3.1, -0.4), V(0.12, 0.9, 0.12), C.Iron)
	P(m, "ChairSeat", cf * CF(0, 1.6, 1.8), V(1.8, 0.3, 1.7), op.chair or pick(rng, Kit.Bright), { solid = true, fuel = 6 })
	P(m, "ChairBack", cf * CF(0, 2.7, 2.6), V(1.8, 1.9, 0.25), op.chair or C.Navy, { fuel = 4 })
	P(m, "ChairLeg", cf * CF(0, 0.75, 1.8), V(0.35, 1.5, 0.35), C.Iron)
	return done(m, parent, top)
end

-- Toy box overflowing with toys (flammable).
function Kit.toyBox(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("ToyBox")
	local b = P(m, "ToyChest", cf * CF(0, 1, 0), V(3, 2, 1.8), op.color or C.Red, { solid = true, fuel = 15 })
	ball(m, "ToyBall", cf * CF(-0.6, 2.2, 0), 0.9, pick(rng, Kit.Bright))
	P(m, "ToyBlock", cf * CF(0.5, 2.2, 0.2) * ANG(0.3, 0.4, 0), V(0.8, 0.8, 0.8), pick(rng, Kit.Bright), { fuel = 3 })
	P(m, "ToyBlock", cf * CF(1.6, 0.4, -1.4) * ANG(0, 0.7, 0), V(0.8, 0.8, 0.8), pick(rng, Kit.Bright), { fuel = 3 })
	return done(m, parent, b)
end

-- Bathtub along local X (tap at -X end).
function Kit.bathtub(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Bathtub")
	local tub = P(m, "Tub", cf * CF(0, 1, 0), V(5.4, 2, 2.8), op.color or C.White, { solid = true })
	P(m, "TubWater", cf * CF(0, 1.85, 0), V(4.8, 0.2, 2.2), C.PaleBlue, { tr = 0.2 })
	P(m, "TubTap", cf * CF(-2.4, 2.4, 0), V(0.3, 0.6, 0.3), C.Chrome)
	ball(m, "RubberDuck", cf * CF(0.8, 2.15, 0.3), 0.5, C.Mustard)
	P(m, "BathCurtain", cf * CF(0, 4, -1.35), V(5.4, 4, 0.1), op.curtain or C.PaleBlue, { fuel = 5 }).Transparency = 0.15
	return done(m, parent, tub)
end

-- Toilet (seat toward -Z, tank on +Z).
function Kit.toilet(parent: Instance, cf: CFrame, o: Opts?): Model
	local m = model("Toilet")
	local bowl = cylY(m, "ToiletBowl", cf * CF(0, 0.75, -0.2), 1.5, 1.5, C.White, { solid = true })
	P(m, "ToiletTank", cf * CF(0, 1.9, 0.8), V(1.4, 1.6, 0.7), C.White)
	P(m, "ToiletLid", cf * CF(0, 1.55, -0.2), V(1.4, 0.12, 1.4), C.Cream)
	return done(m, parent, bowl)
end

-- Bathroom vanity (basin + mirror, cf = wall face).
function Kit.vanity(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Vanity")
	local c = P(m, "VanityCabinet", cf * CF(0, 1.4, -1), V(3, 2.8, 1.8), op.color or C.Cream, { solid = true, fuel = 10 })
	P(m, "VanityBasin", cf * CF(0, 2.85, -1.1), V(1.6, 0.1, 1.1), C.White)
	P(m, "VanityTap", cf * CF(0, 3.2, -0.4), V(0.2, 0.6, 0.2), C.Chrome)
	P(m, "VanityMirror", cf * CF(0, 4.9, -0.12), V(2.4, 2.4, 0.1), C.Glass, { refl = 0.35 })
	P(m, "Toothbrushes", cf * CF(1, 3.1, -0.6), V(0.4, 0.5, 0.4), C.Pink)
	return done(m, parent, c)
end

-- Picture frame on a wall: o.y, o.w, o.h, o.kind ("art" | "photo").
function Kit.picture(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, h = op.w or 2.4, op.h or 1.8
	local m = model("Picture")
	P(m, "PictureFrame", cf * CF(0, op.y or 6, -0.06), V(w + 0.3, h + 0.3, 0.1), op.frame or C.Wood)
	local p = P(m, "PictureCanvas", cf * CF(0, op.y or 6, -0.14), V(w, h, 0.08), C.Cream, { fuel = 3 })
	local g = gui(p, Enum.NormalId.Front, 24)
	if (op.kind or pick(rng, { "art", "photo", "sea" })) == "photo" then
		rect(g, 0, 0.6, 1, 0.4, C.Green)
		rect(g, 0, 0, 1, 0.6, C.Sky)
		penguinDoodle(g, 0.2, 0.3, 0.55, C.Ink)
		penguinDoodle(g, 0.55, 0.38, 0.45, C.Ink)
	elseif op.kind == "sea" or rng:NextNumber() < 0.4 then
		rect(g, 0, 0, 1, 0.55, C.Peach)
		rect(g, 0, 0.55, 1, 0.45, C.Blue)
		sunDoodle(g, 0.6, 0.12, 0.3, C.Orange)
	else
		for _ = 1, 4 do
			local s2 = rng:NextNumber(0.2, 0.45)
			rect(g, rng:NextNumber(0, 0.7), rng:NextNumber(0, 0.7), s2, s2 * w / h, pick(rng, Kit.Bright), rng:NextNumber(0, 1))
		end
	end
	return done(m, parent, p)
end

---------------------------------------------------------------------------------------------------
-- shops / diner
---------------------------------------------------------------------------------------------------
-- Goods shelf (gondola) along local X, goods drawn on both long faces. o.w (8), o.h (5), o.goods colours.
function Kit.shopShelf(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w, h = op.w or 8, op.h or 5
	local goods = op.goods or Kit.Bright
	local m = model("ShopShelf")
	local parts = chunked(m, "Gondola", cf * CF(0, h / 2, 0), V(w, h, op.depth or 1.6), op.color or C.Cream, { solid = true, fuel = 22 })
	for _, part in parts do
		for _, face in (if op.oneSided then { Enum.NormalId.Front } else { Enum.NormalId.Front, Enum.NormalId.Back }) do
			local g = gui(part, face, 16)
			local rows = math.max(2, math.floor(h / 1.4))
			for r = 0, rows - 1 do
				local y0 = 0.04 + r * (0.94 / rows)
				local rh = 0.94 / rows - 0.04
				rect(g, 0.02, y0 + rh, 0.96, 0.025, C.Steel)
				local x = 0.04
				while x < 0.92 do
					local bw = rng:NextNumber(0.05, 0.11) * 8 / part.Size.X
					local bh = rh * rng:NextNumber(0.55, 0.9)
					rect(g, x, y0 + rh - bh, math.min(bw, 0.95 - x), bh, pick(rng, goods), 0.15)
					x += bw + 0.012
				end
			end
		end
	end
	-- a few boxed goods stacked on top (reads from above / far away)
	for k = 1, math.max(2, math.floor(w / 2.5)) do
		local bx = -w / 2 + (k - 0.5) * w / math.max(2, math.floor(w / 2.5))
		local sz = V(rng:NextNumber(0.9, 1.5), rng:NextNumber(0.7, 1.3), rng:NextNumber(0.8, 1.2))
		P(m, "Goods", cf * CF(bx, h + sz.Y / 2, rng:NextNumber(-0.2, 0.2)) * ANG(0, rng:NextNumber(-0.3, 0.3), 0), sz, pick(rng, goods), { fuel = 4 })
	end
	return done(m, parent, parts[1])
end

-- Glass-front drinks cooler (glows). o.w (4).
function Kit.cooler(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w = op.w or 4
	local m = model("Cooler")
	local b = P(m, "CoolerBody", cf * CF(0, 3.5, 0.1), V(w, 7, 2.2), C.White, { solid = true })
	local glass = P(m, "CoolerGlass", cf * CF(0, 3.4, -1.0), V(w - 0.4, 6, 0.1), C.PaleBlue, { neon = true, tr = 0.3 })
	local g = gui(glass, Enum.NormalId.Front, 16, true)
	for r = 0, 3 do
		for c = 0, 5 do
			rect(g, 0.06 + c * 0.15, 0.08 + r * 0.23, 0.1, 0.16, pick(rng, { C.Red, C.Green, C.Orange, C.Blue, C.Mustard }), 0.3)
		end
	end
	return done(m, parent, b)
end

-- Checkout counter with a register, a candy rack and a tip jar (cashier on +Z). o.w (6), o.color.
function Kit.checkout(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local w = op.w or 6
	local m = model("Checkout")
	local body = chunked(m, "CheckoutCounter", cf * CF(0, 1.8, 0), V(w, 3.6, 2.4), op.color or C.Wood, { solid = true, fuel = 25 })
	P(m, "CounterTop", cf * CF(0, 3.7, 0), V(w + 0.2, 0.25, 2.6), C.Cream, { solid = true })
	local reg = P(m, "Register", cf * CF(w / 2 - 1.3, 4.3, 0.2), V(1.6, 1, 1.4), C.Ink)
	local disp = P(m, "RegisterScreen", cf * CF(w / 2 - 1.3, 5, 0.6) * ANG(math.rad(15), 0, 0), V(1.2, 0.7, 0.1), C.Green, { neon = true })
	disp.CastShadow = false
	local _ = reg
	P(m, "CandyRack", cf * CF(-w / 2 + 1, 4.6, -0.6), V(1.4, 1.6, 0.8), C.Red)
	for k = 0, 2 do
		P(m, "Candy", cf * CF(-w / 2 + 0.6 + k * 0.4, 4.6 + (k % 2) * 0.5, -1.05), V(0.3, 0.4, 0.1), pick(rng, Kit.Bright))
	end
	cylY(m, "TipJar", cf * CF(0, 4.1, -0.4), 0.8, 0.6, C.Glass, { mat = Enum.Material.Glass, tr = 0.4 })
	return done(m, parent, body[1])
end

-- Stack of cardboard boxes (flammable).
function Kit.boxes(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local rng = rngOf(op)
	local m = model("Boxes")
	local kraft = Color3.fromHex("#C99A62")
	local b = P(m, "CardBox", cf * CF(0, 1, 0), V(2.4, 2, 2.2), kraft, { solid = true, fuel = 12 })
	P(m, "CardBox", cf * CF(1.6, 0.8, 0.4) * ANG(0, 0.3, 0), V(2, 1.6, 1.8), kraft:Lerp(C.White, 0.1), { solid = true, fuel = 10 })
	P(m, "CardBox", cf * CF(0.2, 2.75, 0.1) * ANG(0, rng:NextNumber(-0.4, 0.4), 0), V(1.8, 1.5, 1.6), kraft:Lerp(C.Black, 0.08), { fuel = 8 })
	return done(m, parent, b)
end

-- Diner booth: table between two bench seats (seats on +-Z). o.color.
function Kit.booth(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local col = op.color or C.Red
	local m = model("Booth")
	local top = P(m, "BoothTable", cf * CF(0, 2.6, 0), V(4.4, 0.3, 2.4), C.Cream, { solid = true, fuel = 10 })
	P(m, "BoothPost", cf * CF(0, 1.25, 0), V(0.5, 2.5, 0.5), C.Chrome)
	for _, sz in { -1, 1 } do
		P(m, "BoothSeat", cf * CF(0, 1.1, sz * 2.3), V(5, 1.2, 1.8), col, { solid = true, fuel = 14 })
		P(m, "BoothBack", cf * CF(0, 2.7, sz * 3.05), V(5, 2.4, 0.5), col:Lerp(C.Black, 0.12), { fuel = 8 })
	end
	P(m, "Ketchup", cf * CF(1.6, 3.15, -0.3), V(0.35, 0.8, 0.35), C.Red)
	P(m, "Mustard", cf * CF(1.6, 3.15, 0.3), V(0.35, 0.8, 0.35), C.Mustard)
	P(m, "Plate", cf * CF(-0.8, 2.8, -0.5), V(1.2, 0.08, 1.2), C.White)
	return done(m, parent, top)
end

-- Wooden bench along local X (backrest on +Z). o.w (5).
function Kit.bench(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local w = op.w or 5
	local m = model("Bench")
	local seat = P(m, "BenchSeat", cf * CF(0, 1.5, 0), V(w, 0.4, 1.6), op.color or C.WoodLight, { solid = true, fuel = 12 })
	P(m, "BenchBack", cf * CF(0, 2.6, 0.7), V(w, 1.6, 0.3), op.color or C.WoodLight, { fuel = 8 })
	for _, x in { -w / 2 + 0.5, w / 2 - 0.5 } do
		P(m, "BenchLeg", cf * CF(x, 0.65, 0), V(0.4, 1.3, 1.4), C.Iron)
	end
	return done(m, parent, seat)
end

-- Counter stool (spins in spirit).
function Kit.stool(parent: Instance, cf: CFrame, o: Opts?): Model
	local op = o or {}
	local m = model("Stool")
	local seat = cylY(m, "StoolSeat", cf * CF(0, 2.6, 0), 0.5, 1.6, op.color or C.Red, { solid = true, fuel = 5 })
	P(m, "StoolPost", cf * CF(0, 1.2, 0), V(0.3, 2.4, 0.3), C.Chrome)
	cylY(m, "StoolFoot", cf * CF(0, 0.1, 0), 0.2, 1.2, C.Chrome)
	return done(m, parent, seat)
end

-- Jukebox (glows).
function Kit.jukebox(parent: Instance, cf: CFrame): Model
	local m = model("Jukebox")
	local b = P(m, "JukeBody", cf * CF(0, 2.5, 0), V(3, 5, 2), C.Red, { solid = true, fuel = 15 })
	local face = P(m, "JukeGlow", cf * CF(0, 3, -1.02), V(2.4, 3.4, 0.08), C.Mustard, { neon = true })
	local g = gui(face, Enum.NormalId.Front, 20, true)
	for k = 0, 4 do
		rect(g, 0.1, 0.1 + k * 0.17, 0.8, 0.08, Kit.Bright[k + 1], 0.5)
	end
	return done(m, parent, b)
end


return Kit
