-- PropKit [owner: props]. Chunky cartoon props built from anchored Parts (palette: docs/game/02 §1).
-- Every function: PropKit.<name>(parent: Instance, cf: CFrame, opts: {[string]: any}?) -> Model
--   cf = base point on the floor/ground under the prop's centre; the prop FACES -Z of cf.
--   The Model is parented to `parent` last and has a PrimaryPart.
-- Common opts: color (main colour), flammable = false (disable fire tags on furniture/wood).
-- Wood/fabric/foliage parts are tagged Flammable (Names.Tag.Flammable) with a Fuel attribute (seconds).
--
-- Sizes (W x H x D studs, default) and extra opts:
--   sofa         8 x 3.9 x 3.4      opts.width, opts.color                         ~16 parts
--   bookshelf    4 x 7 x 1.4        opts.width, opts.height, opts.seed (books)     ~22 parts
--   bed          5 x 4.2 x 8        opts.width, opts.length, opts.color (blanket)  ~12 parts
--   table        6 x 3 x 4          opts.width, opts.depth, opts.height (1.6 = coffee table)
--   chair        2.4 x 4.6 x 2.4    opts.color (cushion)
--   plant        2 x 4.8 x 2        potted flower; opts.color (petals)
--   tv           5 x 4.5 x 1.8      opts.stand = false (TV only, 2.7 tall), opts.on = false (dark screen)
--   fridge       3 x 7 x 2.6        opts.color
--   counter      6 x 3.6 x 2.6      opts.length, opts.color (cabinets), opts.sink, opts.stove
--   locker       3 x 7.5 x 2        open station cubby w/ jacket, helmet, boots; opts.helmet (number), opts.door = true (closed)
--   bench        10 x 1.8 x 1.9     opts.length
--   hoseReel     3.6 x 4.2 x 2.4    standing reel w/ coiled yellow hose + brass nozzle
--   axeRack      3.4 x 7.9 x 0.9    WALL mount: cf = floor point at the wall face, back at local z=0; board y 2.8..7.2; red axe in sub-model "Axe"
--   extinguisher 1.3 x 3.6 x 1.3    opts.color
--   oxygenTank   1.4 x 4.0 x 1.4    opts.color
--   trampoline   8 x 2.6 x 8 (dia)  blue rescue trampoline; opts.size (diameter)
--   alarmLight   1.8 x 1.7 x 1.8    CEILING mount: cf = ceiling point, hangs down (-Y); opts.mount = "floor" flips; opts.on = false; PointLight + SpotLight "Spin"
--   streetLamp   1.6 x 12 x 3.1     opts.height; arm + lamp head reach toward -Z; PointLight #FFC97A
--   tree         ~7 x 12 x 7        opts.size (scale), opts.color (foliage), opts.variant (1..3), opts.kind = "pine"
--   bush         ~4.5 x 3 x 3.5     opts.size (scale), opts.color, opts.flowers = true
--   fence        L x 3.4 x 0.8      runs along local X centred on cf; opts.length (8), opts.style = "picket"|"rail", opts.color
--   mailbox      1.5 x 4.9 x 2.5    opts.color
--   car          6.6 x 5.5 x 11.4   parked cartoon car, front at -Z; opts.color, opts.eyes = true (googly eyes)
--   pool         12 x 3 x 18        opts.size (Vector3 W,depth,L or number = square side), opts.sunken = true (dug below cf; needs a hole in the ground slab); Water part "Water"
--   haystack     6.3 x 7.4 x 6.3    opts.size (scale)
--   ladder       2.6 x 12 x 0.5     opts.height, opts.width, opts.wood = true (wooden, flammable)
local ServerScriptService = game:GetService("ServerScriptService")

local MapKit = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Map"):WaitForChild("MapKit") :: ModuleScript)

local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local hex = Color3.fromHex
local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

local C = {
	TruckRed = hex("#C8232B"),
	TruckChrome = hex("#D6D8DC"),
	HoseYellow = hex("#E8B83A"),
	HoseRed = hex("#B83A2E"),
	Brass = hex("#C89A3C"),
	LockerGrey = hex("#6E6A6E"),
	CoatYellow = hex("#D9A030"),
	CoatShadow = hex("#9A6A30"),
	ReflectLime = hex("#E8E25A"),
	ReflectSilver = hex("#C9CCD0"),
	HelmetRed = hex("#C0301E"),
	HelmetShield = hex("#E8C24A"),
	NumberInk = hex("#1A1210"),
	BookshelfWood = hex("#8A4A28"),
	WoodFloor = hex("#C8683A"),
	TrimWhite = hex("#F2EDE4"),
	SidingCream = hex("#E8D3A8"),
	SidingSalmon = hex("#D98B6F"),
	SidingSage = hex("#9DB38A"),
	RoomTeal = hex("#4F8A85"),
	FenceWood = hex("#6B4A35"),
	TrunkBrown = hex("#7A3A1E"),
	PineFoliage = hex("#2F4A3A"),
	LawnGreen = hex("#7FAF4A"),
	Leaf1 = hex("#6F9A3A"),
	Leaf2 = hex("#8AAF4A"),
	Hay = hex("#E3AB56"),
	PoolTile = hex("#7FC4D0"),
	Water = hex("#4FB3D9"),
	Sidewalk = hex("#C9B8A8"),
	AlarmRed = hex("#FF2A2A"),
	LampWarm = hex("#FFC97A"),
	Glass = hex("#A8D5E2"),
	UiCream = hex("#FFF1D6"),
	Ink = hex("#1E1A22"),
	Tyre = hex("#26232A"),
	Terracotta = Color3.fromRGB(231, 111, 81),
	Soil = hex("#4A2E1E"),
	Sofa = hex("#6E8A6A"),
	Pink = hex("#E86A92"),
	Mustard = Color3.fromRGB(233, 196, 106),
	Teal = Color3.fromRGB(42, 157, 143),
	TrampBlue = hex("#3A7FD0"),
	TrampBlueLit = hex("#5B9BE6"),
	PoleDark = hex("#2F3A3A"),
}

local BOOK_COLORS = {
	hex("#CF442B"), hex("#E8B83A"), hex("#2A9D8F"), hex("#3A7FD0"), hex("#F2B07E"),
	hex("#7A4E9A"), hex("#6BCB5A"), hex("#F2EDE4"), hex("#C0342A"), hex("#4F8A85"),
}

local PropKit = {}

PropKit.List = {
	"sofa", "bookshelf", "bed", "table", "chair", "plant", "tv", "fridge", "counter", "locker",
	"bench", "hoseReel", "axeRack", "extinguisher", "oxygenTank", "trampoline", "alarmLight",
	"streetLamp", "tree", "bush", "fence", "mailbox", "car", "pool", "haystack", "ladder",
}

-- helpers ---------------------------------------------------------------------------------------

local function lighten(c: Color3, t: number): Color3
	return c:Lerp(WHITE, t)
end

local function darken(c: Color3, t: number): Color3
	return c:Lerp(BLACK, t)
end

local function newModel(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local function finish(m: Model, parent: Instance, primary: BasePart): Model
	m.PrimaryPart = primary
	m.Parent = parent
	return m
end

-- Flammable opts unless the caller disabled fire (opts.flammable == false).
local function burn(o: { [string]: any }, fuel: number): { [string]: any }?
	if o.flammable == false then
		return nil
	end
	return { flammable = true, fuel = fuel }
end

local function P(m: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.color = color
	return MapKit.part(m, name, cf, size, o :: any)
end

-- Upright cylinder centred at cf (height along Y).
local function vcyl(m: Instance, name: string, cf: CFrame, h: number, d: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.shape = CYL
	return P(m, name, cf * ANG(0, 0, math.pi / 2), V(h, d, d), color, o)
end

-- Cylinder along local X centred at cf.
local function xcyl(m: Instance, name: string, cf: CFrame, len: number, d: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.shape = CYL
	return P(m, name, cf, V(len, d, d), color, o)
end

local function ball(m: Instance, name: string, cf: CFrame, d: number, color: Color3, extra: { [string]: any }?): Part
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.shape = BALL
	return P(m, name, cf, V(d, d, d), color, o)
end

local function noCollide(extra: { [string]: any }?): { [string]: any }
	local o: { [string]: any } = if extra then table.clone(extra) else {}
	o.collide = false
	return o
end

-- Big text on the Front (-Z) face of a part.
local function label(part: BasePart, text: string, color: Color3, bg: Color3?)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 1
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = if bg then 0 else 1
	t.BackgroundColor3 = bg or WHITE
	t.Text = text
	t.TextScaled = true
	t.Font = Enum.Font.FredokaOne
	t.TextColor3 = color
	t.Parent = gui
	gui.Parent = part
end

local function at(cf: CFrame, x: number, y: number, z: number): CFrame
	return cf * CF(x, y, z)
end

-- furniture -------------------------------------------------------------------------------------

function PropKit.sofa(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Sofa")
	local col: Color3 = o.color or C.Sofa
	local w: number = o.width or 8
	local F = burn(o, 60)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(m, "Leg", at(cf, sx * (w / 2 - 0.6), 0.25, sz * 1.2), V(0.6, 0.5, 0.6), darken(C.BookshelfWood, 0.3), burn(o, 15))
		end
	end
	local base = P(m, "Base", at(cf, 0, 1.1, 0), V(w, 1.2, 3.4), darken(col, 0.15), F)
	P(m, "Back", at(cf, 0, 2.6, 1.25), V(w, 2.6, 0.9), col, F)
	for _, sx in { -1, 1 } do
		P(m, "Arm", at(cf, sx * (w / 2 - 0.45), 2.2, 0), V(0.9, 1.6, 3.4), col, F)
		ball(m, "ArmRoll", at(cf, sx * (w / 2 - 0.45), 3.0, -1.2), 0.9, lighten(col, 0.08), F)
	end
	local inner = w - 1.8
	local n = math.max(1, math.floor(inner / 2.1 + 0.5))
	local cw = inner / n
	for i = 1, n do
		local x = -inner / 2 + (i - 0.5) * cw
		P(m, "Cushion", at(cf, x, 2.1, -0.3), V(cw - 0.12, 0.8, 2.6), lighten(col, 0.12), F)
		P(m, "BackCushion", at(cf, x, 3.0, 0.55), V(cw - 0.12, 1.6, 0.6), lighten(col, 0.06), F)
	end
	return finish(m, parent, base)
end

function PropKit.bookshelf(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Bookshelf")
	local wood: Color3 = o.color or C.BookshelfWood
	local w: number = o.width or 4
	local h: number = o.height or 7
	local d = 1.4
	local F = burn(o, 50)
	local rng: Random = o.rng or Random.new(o.seed or 67)
	local back = P(m, "Back", at(cf, 0, h / 2, d / 2 - 0.2), V(w, h, 0.4), darken(wood, 0.2), F)
	for _, sx in { -1, 1 } do
		P(m, "Side", at(cf, sx * (w / 2 - 0.2), h / 2, 0), V(0.4, h, d), wood, F)
	end
	P(m, "Top", at(cf, 0, h - 0.2, -0.05), V(w + 0.4, 0.4, d + 0.1), lighten(wood, 0.08), F)
	P(m, "Plinth", at(cf, 0, 0.3, 0), V(w, 0.6, d), darken(wood, 0.25), F)
	local compH = (h - 1.0) / 3
	for i = 1, 2 do
		P(m, "Shelf", at(cf, 0, 0.6 + i * compH, -0.15), V(w - 0.8, 0.4, d - 0.3), wood, F)
	end
	local limit = w / 2 - 0.4
	for k = 0, 2 do
		local floorY = 0.6 + k * compH + (if k > 0 then 0.2 else 0)
		local ceilY = if k < 2 then 0.6 + (k + 1) * compH - 0.2 else h - 0.4
		local maxH = ceilY - floorY - 0.15
		local x = -limit
		while true do
			local bw = rng:NextNumber(0.4, 0.7)
			if x + bw > limit then
				break
			end
			local bh = maxH * rng:NextNumber(0.62, 0.95)
			P(m, "Book", at(cf, x + bw / 2, floorY + bh / 2, -0.15), V(bw, bh, 0.95), BOOK_COLORS[rng:NextInteger(1, #BOOK_COLORS)], burn(o, 20))
			x += bw + (if rng:NextNumber() < 0.15 then 0.35 else 0.03)
		end
	end
	return finish(m, parent, back)
end

function PropKit.bed(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Bed")
	local w: number = o.width or 5
	local l: number = o.length or 8
	local wood = C.BookshelfWood
	local blanket: Color3 = o.color or C.SidingSalmon
	local F = burn(o, 60)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(m, "Leg", at(cf, sx * (w / 2 - 0.4), 0.3, sz * (l / 2 - 0.5)), V(0.6, 0.6, 0.6), darken(wood, 0.3), F)
		end
	end
	local frame = P(m, "Frame", at(cf, 0, 0.9, 0), V(w, 0.6, l), wood, F)
	local mz = -0.15
	local ml = l - 1.0
	P(m, "Mattress", at(cf, 0, 1.65, mz), V(w - 0.4, 0.9, ml), C.TrimWhite, F)
	local front = mz - ml / 2
	local bl = ml * 0.64
	P(m, "Blanket", at(cf, 0, 2.0, front + bl / 2 - 0.05), V(w - 0.2, 0.5, bl), blanket, F)
	P(m, "Fold", at(cf, 0, 2.05, front + bl - 0.4), V(w - 0.1, 0.55, 0.8), lighten(blanket, 0.35), F)
	P(m, "Pillow", at(cf, 0, 2.35, mz + ml / 2 - 1.0), V(w - 1.6, 0.6, 1.4), lighten(C.UiCream, 0.2), F)
	P(m, "Headboard", at(cf, 0, 1.9, l / 2 - 0.3), V(w + 0.4, 3.8, 0.6), wood, F)
	xcyl(m, "HeadboardTop", at(cf, 0, 3.8, l / 2 - 0.3), w + 0.6, 0.8, lighten(wood, 0.1), F)
	P(m, "Footboard", at(cf, 0, 1.0, -l / 2 + 0.25), V(w + 0.4, 2.0, 0.5), wood, F)
	return finish(m, parent, frame)
end

function PropKit.table(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Table")
	local w: number = o.width or 6
	local d: number = o.depth or 4
	local h: number = o.height or 3
	local wood: Color3 = o.color or C.WoodFloor
	local F = burn(o, 40)
	local top = P(m, "Top", at(cf, 0, h - 0.3, 0), V(w, 0.6, d), wood, F)
	P(m, "Apron", at(cf, 0, h - 0.8, 0), V(w - 0.8, 0.4, d - 0.8), darken(wood, 0.2), F)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(m, "Leg", at(cf, sx * (w / 2 - 0.6), (h - 0.6) / 2, sz * (d / 2 - 0.6)), V(0.6, h - 0.6, 0.6), darken(wood, 0.15), F)
		end
	end
	return finish(m, parent, top)
end

function PropKit.chair(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Chair")
	local wood = C.WoodFloor
	local F = burn(o, 25)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			P(m, "Leg", at(cf, sx * 0.9, 0.75, sz * 0.9), V(0.4, 1.5, 0.4), darken(wood, 0.2), F)
		end
	end
	local seat = P(m, "Seat", at(cf, 0, 1.75, 0), V(2.4, 0.5, 2.4), wood, F)
	P(m, "Cushion", at(cf, 0, 2.1, -0.1), V(2.0, 0.4, 2.0), o.color or C.HoseRed, F)
	P(m, "Back", at(cf, 0, 3.3, 0.95), V(2.4, 2.6, 0.5), wood, F)
	xcyl(m, "BackTop", at(cf, 0, 4.6, 0.95), 2.6, 0.6, lighten(wood, 0.1), F)
	return finish(m, parent, seat)
end

function PropKit.plant(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Plant")
	local petal: Color3 = o.color or C.Pink
	local F = burn(o, 10)
	local pot = vcyl(m, "Pot", at(cf, 0, 0.8, 0), 1.6, 1.6, C.Terracotta)
	vcyl(m, "Rim", at(cf, 0, 1.55, 0), 0.5, 2.0, darken(C.Terracotta, 0.1))
	vcyl(m, "Soil", at(cf, 0, 1.6, 0), 0.6, 1.6, C.Soil)
	P(m, "Stem", at(cf, 0, 2.95, 0), V(0.4, 2.3, 0.4), C.Leaf1, F)
	P(m, "LeafL", at(cf, -0.55, 2.6, 0) * ANG(0, 0, 0.5), V(1.2, 0.4, 0.7), C.Leaf2, F)
	P(m, "LeafR", at(cf, 0.55, 3.15, 0) * ANG(0, 0, -0.5), V(1.2, 0.4, 0.7), C.Leaf1, F)
	local fy = 4.25
	for i = 0, 4 do
		local a = i * 2 * math.pi / 5 + math.pi / 2
		ball(m, "Petal", at(cf, math.cos(a) * 0.55, fy + math.sin(a) * 0.55, 0.05), 0.75, petal, F)
	end
	ball(m, "FlowerCentre", at(cf, 0, fy, -0.15), 0.8, C.HoseYellow, F)
	return finish(m, parent, pot)
end

function PropKit.tv(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("TV")
	local y0 = 0
	local primary: BasePart? = nil
	if o.stand ~= false then
		local wood: Color3 = o.color or C.BookshelfWood
		primary = P(m, "Stand", at(cf, 0, 0.9, 0), V(5, 1.8, 1.8), wood, burn(o, 40))
		for _, sx in { -1, 1 } do
			P(m, "Drawer", at(cf, sx * 1.2, 0.9, -0.85), V(2.1, 1.1, 0.4), lighten(wood, 0.12), burn(o, 20))
			P(m, "Knob", at(cf, sx * 1.2, 0.9, -1.1), V(0.4, 0.4, 0.4), C.Brass)
		end
		y0 = 1.8
	end
	local foot = P(m, "Foot", at(cf, 0, y0 + 0.2, 0), V(1.6, 0.4, 1.0), C.Ink)
	P(m, "Neck", at(cf, 0, y0 + 0.6, 0.1), V(0.6, 0.6, 0.4), C.Ink)
	P(m, "Body", at(cf, 0, y0 + 2.3, 0), V(4.6, 2.8, 0.6), C.Ink)
	P(m, "BackBox", at(cf, 0, y0 + 2.3, 0.5), V(3.0, 2.0, 0.6), darken(C.Ink, 0.1))
	local on = o.on ~= false
	P(m, "Screen", at(cf, 0, y0 + 2.35, -0.15), V(4.0, 2.2, 0.4), if on then hex("#7FC4D0") else hex("#2A2826"), { neon = on })
	P(m, "Led", at(cf, 1.9, y0 + 1.05, -0.15), V(0.4, 0.4, 0.4), if on then hex("#6BCB5A") else C.HoseRed, { neon = true })
	return finish(m, parent, primary or foot)
end

function PropKit.fridge(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Fridge")
	local col: Color3 = o.color or C.TrimWhite
	local w, h, d = 3, 7, 2.6
	local body = P(m, "Body", at(cf, 0, h / 2, 0), V(w, h, d), col)
	local fz = -d / 2 - 0.1
	P(m, "Kick", at(cf, 0, 0.2, fz + 0.05), V(w - 0.2, 0.4, 0.4), C.Ink)
	P(m, "Door", at(cf, 0, 2.5, fz), V(w - 0.2, 4.2, 0.4), lighten(col, 0.3))
	P(m, "FreezerDoor", at(cf, 0, 5.8, fz), V(w - 0.2, 2.0, 0.4), lighten(col, 0.3))
	P(m, "Handle", at(cf, w / 2 - 0.55, 3.6, fz - 0.35), V(0.4, 1.6, 0.4), C.TruckChrome)
	P(m, "FreezerHandle", at(cf, w / 2 - 0.55, 5.4, fz - 0.35), V(0.4, 1.0, 0.4), C.TruckChrome)
	P(m, "Drawing", at(cf, -0.4, 3.3, fz - 0.25), V(1.0, 1.2, 0.4), C.UiCream)
	P(m, "Magnet", at(cf, -0.4, 3.85, fz - 0.4), V(0.4, 0.4, 0.4), C.TruckRed)
	P(m, "Magnet", at(cf, 0.5, 2.1, fz - 0.3), V(0.4, 0.4, 0.4), C.Teal)
	P(m, "Magnet", at(cf, -0.7, 5.9, fz - 0.3), V(0.4, 0.4, 0.4), C.HoseYellow)
	return finish(m, parent, body)
end

function PropKit.counter(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Counter")
	local L: number = o.length or 6
	local d = 2.6
	local col: Color3 = o.color or C.SidingSage
	local F = burn(o, 45)
	P(m, "Toe", at(cf, 0, 0.2, 0.2), V(L - 0.2, 0.4, d - 0.4), C.Ink)
	-- cabinets in <= 8-stud chunks so fire stays local
	local chunks = math.max(1, math.ceil(L / 8))
	local cl = L / chunks
	local first: BasePart? = nil
	for i = 1, chunks do
		local x = -L / 2 + (i - 0.5) * cl
		local c = P(m, "Cabinet", at(cf, x, 1.8, 0), V(cl, 2.8, d), col, F)
		first = first or c
		P(m, "Top", at(cf, x, 3.4, -0.1), V(cl + 0.1, 0.4, d + 0.2), hex("#E8D9B0"))
	end
	local n = math.max(1, math.floor(L / 2))
	local dw = L / n
	for i = 1, n do
		local x = -L / 2 + (i - 0.5) * dw
		P(m, "Door", at(cf, x, 1.75, -d / 2 - 0.1), V(dw - 0.3, 2.3, 0.4), lighten(col, 0.15), F)
		local side = if i % 2 == 0 then -1 else 1
		P(m, "Knob", at(cf, x + side * (dw / 2 - 0.55), 2.5, -d / 2 - 0.45), V(0.4, 0.4, 0.4), C.Brass)
	end
	if o.sink then
		local sx = if o.stove then -L / 4 else 0
		P(m, "Sink", at(cf, sx, 3.42, -0.1), V(2.4, 0.45, 1.6), hex("#9A9CA0"))
		P(m, "Faucet", at(cf, sx, 4.1, 0.85), V(0.4, 1.2, 0.4), C.TruckChrome)
		P(m, "Spout", at(cf, sx, 4.6, 0.5), V(0.4, 0.4, 0.9), C.TruckChrome)
	end
	if o.stove then
		local sx = if o.sink then L / 4 else 0
		P(m, "Hob", at(cf, sx, 3.42, -0.1), V(2.6, 0.45, 2.0), C.Ink)
		for _, bx in { -0.6, 0.6 } do
			for _, bz in { -0.5, 0.5 } do
				vcyl(m, "Burner", at(cf, sx + bx, 3.5, -0.1 + bz), 0.4, 0.8, hex("#3A2A22"))
			end
		end
	end
	return finish(m, parent, first :: BasePart)
end

-- fire station ----------------------------------------------------------------------------------

function PropKit.locker(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Locker")
	local col: Color3 = o.color or C.LockerGrey
	local w, h, d = 3, 7.5, 2
	local back = P(m, "Back", at(cf, 0, h / 2, d / 2 - 0.2), V(w, h, 0.4), darken(col, 0.2))
	for _, sx in { -1, 1 } do
		P(m, "Side", at(cf, sx * (w / 2 - 0.2), h / 2, 0), V(0.4, h, d), col)
	end
	P(m, "Top", at(cf, 0, h - 0.2, 0), V(w, 0.4, d), lighten(col, 0.08))
	P(m, "Bottom", at(cf, 0, 0.2, 0), V(w, 0.4, d), darken(col, 0.1))
	if o.door then
		P(m, "Door", at(cf, 0, h / 2, -d / 2 + 0.1), V(w - 0.4, h - 0.6, 0.4), darken(col, 0.12))
		for i = 0, 2 do
			P(m, "Vent", at(cf, 0, h - 1.2 - i * 0.6, -d / 2 - 0.1), V(1.6, 0.4, 0.4), C.Ink)
		end
		P(m, "Handle", at(cf, w / 2 - 0.7, h / 2, -d / 2 - 0.15), V(0.4, 1.0, 0.4), C.TruckChrome)
		return finish(m, parent, back)
	end
	-- helmet on the top shelf
	local shelfY = h - 1.8
	P(m, "Shelf", at(cf, 0, shelfY, -0.1), V(w - 0.8, 0.4, d - 0.2), col)
	local sTop = shelfY + 0.2
	ball(m, "HelmetDome", at(cf, 0, sTop + 0.5, 0), 1.3, C.HelmetRed)
	vcyl(m, "HelmetBrim", at(cf, 0, sTop + 0.25, 0.05), 0.4, 2.0, darken(C.HelmetRed, 0.15))
	local badge = P(m, "HelmetBadge", at(cf, 0, sTop + 0.65, -0.65), V(0.6, 0.6, 0.4), C.HelmetShield)
	if o.helmet then
		label(badge, string.format("%02d", o.helmet :: number), C.NumberInk)
	end
	-- jacket on a hook
	local hookY = shelfY - 0.6
	P(m, "Hook", at(cf, 0, hookY, 0.45), V(0.4, 0.4, 0.8), C.TruckChrome)
	local F = burn(o, 20)
	P(m, "Collar", at(cf, 0, hookY - 0.3, 0.15), V(1.2, 0.4, 0.9), C.CoatShadow, F)
	local torsoTop = hookY - 0.4
	local torsoH = 2.6
	local ty = torsoTop - torsoH / 2
	P(m, "Jacket", at(cf, 0, ty, 0.15), V(1.4, torsoH, 0.8), C.CoatYellow, F)
	for _, sx in { -1, 1 } do
		P(m, "Sleeve", at(cf, sx * 0.85, ty + 0.1, 0.15), V(0.5, torsoH - 0.2, 0.7), C.CoatShadow, F)
	end
	local bandY = ty - 0.5
	P(m, "BandLime", at(cf, 0, bandY - 0.4, 0.15), V(1.45, 0.4, 0.85), C.ReflectLime)
	P(m, "BandSilver", at(cf, 0, bandY, 0.15), V(1.45, 0.4, 0.85), C.ReflectSilver)
	P(m, "BandLime", at(cf, 0, bandY + 0.4, 0.15), V(1.45, 0.4, 0.85), C.ReflectLime)
	-- boots
	for _, sx in { -1, 1 } do
		P(m, "Boot", at(cf, sx * 0.45, 0.85, -0.2), V(0.6, 0.9, 1.0), C.Ink)
		P(m, "BootToe", at(cf, sx * 0.45, 0.6, -0.75), V(0.6, 0.4, 0.4), C.Ink)
	end
	return finish(m, parent, back)
end

function PropKit.bench(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Bench")
	local L: number = o.length or 10
	local h = 1.8
	local wood: Color3 = o.color or C.WoodFloor
	local F = burn(o, 30)
	local chunks = math.max(1, math.ceil(L / 8))
	local cl = L / chunks
	local first: BasePart? = nil
	for i = 1, chunks do
		local x = -L / 2 + (i - 0.5) * cl
		for j, z in { -0.5, 0.5 } do
			local p = P(m, "Plank", at(cf, x, h - 0.25, z), V(cl - 0.05, 0.5, 0.9), if j == 1 then wood else darken(wood, 0.08), F)
			first = first or p
		end
	end
	local legs = math.max(2, math.ceil(L / 5) + 1)
	for i = 0, legs - 1 do
		local x = -L / 2 + 0.6 + i * (L - 1.2) / (legs - 1)
		P(m, "Leg", at(cf, x, (h - 0.5) / 2, 0), V(0.6, h - 0.5, 1.8), darken(wood, 0.3), F)
	end
	return finish(m, parent, first :: BasePart)
end

function PropKit.hoseReel(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("HoseReel")
	local frame: Color3 = o.color or C.TruckRed
	local base = P(m, "Base", at(cf, 0, 0.2, 0), V(3.6, 0.4, 2.4), C.Ink)
	for _, sx in { -1, 1 } do
		P(m, "SidePlate", at(cf, sx * 1.6, 2.0, 0), V(0.4, 3.6, 1.4), frame)
		xcyl(m, "Flange", at(cf, sx * 1.25, 2.4, 0), 0.4, 3.6, darken(frame, 0.1))
	end
	local cy = 2.4
	for i, x in { -0.75, 0, 0.75 } do
		xcyl(m, "Coil", at(cf, x, cy, 0), 0.75, if i == 2 then 2.9 else 3.05, if i == 2 then C.HoseRed else C.HoseYellow, burn(o, 15))
	end
	xcyl(m, "Hub", at(cf, 0, cy, 0), 3.8, 0.8, C.Brass)
	P(m, "Crank", at(cf, 2.0, cy - 0.3, 0), V(0.4, 1.0, 0.4), C.Brass)
	P(m, "CrankKnob", at(cf, 2.2, cy - 0.7, 0), V(0.6, 0.4, 0.4), C.Ink)
	P(m, "HoseEnd", at(cf, 0.3, 1.3, -1.35), V(0.6, 1.6, 0.6), C.HoseYellow, burn(o, 10))
	vcyl(m, "Nozzle", at(cf, 0.3, 0.6, -1.35), 0.8, 0.6, C.Brass)
	vcyl(m, "NozzleTip", at(cf, 0.3, 0.4, -1.35), 0.4, 0.8, C.Ink)
	return finish(m, parent, base)
end

function PropKit.axeRack(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("AxeRack")
	local frame = P(m, "Frame", at(cf, 0, 5.0, -0.2), V(3.4, 4.8, 0.4), C.TruckRed)
	P(m, "Board", at(cf, 0, 5.0, -0.3), V(3.0, 4.4, 0.4), C.UiCream, burn(o, 20))
	local sign = P(m, "Sign", at(cf, 0, 7.75, -0.2), V(2.8, 0.7, 0.4), C.TruckRed)
	label(sign, "FIRE AXE", C.TrimWhite)
	for _, y in { 3.9, 6.1 } do
		P(m, "Hook", at(cf, -0.3, y, -0.6), V(0.4, 0.4, 0.6), C.TruckChrome)
	end
	local axe = newModel("Axe")
	local acf = at(cf, 0, 5.0, -0.75) * ANG(0, 0, math.rad(-22))
	local handle = P(axe, "Handle", acf, V(0.4, 4.0, 0.4), C.WoodFloor, burn(o, 15))
	P(axe, "Grip", acf * CF(0, -1.5, 0), V(0.5, 1.0, 0.5), C.Ink)
	P(axe, "Head", acf * CF(0.45, 1.6, 0), V(1.3, 1.0, 0.5), o.color or C.TruckRed)
	P(axe, "Blade", acf * CF(1.25, 1.6, 0), V(0.4, 1.4, 0.5), C.TruckChrome)
	P(axe, "Spike", acf * CF(-0.45, 1.6, 0), V(0.6, 0.4, 0.4), darken(C.TruckRed, 0.3))
	axe.PrimaryPart = handle
	axe.Parent = m
	return finish(m, parent, frame)
end

function PropKit.extinguisher(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Extinguisher")
	local col: Color3 = o.color or C.TruckRed
	vcyl(m, "Foot", at(cf, 0, 0.2, 0), 0.4, 1.3, C.Ink)
	local body = vcyl(m, "Body", at(cf, 0, 1.3, 0), 2.2, 1.2, col)
	vcyl(m, "Label", at(cf, 0, 1.3, 0), 0.6, 1.25, C.TrimWhite)
	ball(m, "Dome", at(cf, 0, 2.4, 0), 1.2, col)
	vcyl(m, "Neck", at(cf, 0, 3.1, 0), 0.5, 0.5, C.Ink)
	P(m, "Lever", at(cf, 0, 3.45, -0.2) * ANG(math.rad(-15), 0, 0), V(0.4, 0.4, 1.3), C.Ink)
	P(m, "Gauge", at(cf, 0, 3.05, -0.35), V(0.4, 0.4, 0.4), C.TrimWhite)
	P(m, "HoseTop", at(cf, 0.45, 3.0, 0.3), V(0.4, 0.4, 0.6), C.Ink)
	P(m, "Hose", at(cf, 0.75, 2.0, 0.45), V(0.4, 2.0, 0.4), C.Ink)
	P(m, "HoseNozzle", at(cf, 0.75, 0.8, 0.45), V(0.5, 0.6, 0.5), C.Ink)
	return finish(m, parent, body)
end

function PropKit.oxygenTank(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("OxygenTank")
	local col: Color3 = o.color or C.ReflectSilver
	vcyl(m, "Foot", at(cf, 0, 0.2, 0), 0.4, 1.4, C.Ink)
	local body = vcyl(m, "Body", at(cf, 0, 1.8, 0), 3.2, 1.3, col)
	ball(m, "Shoulder", at(cf, 0, 3.4, 0), 1.3, col)
	vcyl(m, "Band", at(cf, 0, 2.4, 0), 0.6, 1.35, C.HoseYellow)
	local tag = P(m, "Tag", at(cf, 0, 1.4, -0.55), V(0.8, 0.8, 0.4), C.TrimWhite)
	label(tag, "O2", hex("#2A9D8F"))
	vcyl(m, "Valve", at(cf, 0, 4.15, 0), 0.5, 0.5, C.Brass)
	vcyl(m, "Knob", at(cf, 0, 4.0, 0), 0.4, 0.9, C.Ink)
	return finish(m, parent, body)
end

function PropKit.trampoline(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Trampoline")
	local R: number = (o.size or 8) / 2
	local col: Color3 = o.color or C.TrampBlue
	local rr = R - 0.6
	local n = 12
	local segL = 2 * math.pi * rr / n + 0.35
	for i = 0, n - 1 do
		local a = i * 2 * math.pi / n
		P(m, "Rim", at(cf, math.sin(a) * rr, 2.15, math.cos(a) * rr) * ANG(0, a, 0), V(segL, 0.9, 1.2), if i % 2 == 0 then col else lighten(col, 0.18))
	end
	local mat = vcyl(m, "Mat", at(cf, 0, 2.2, 0), 0.4, 2 * (R - 1.1) + 0.4, C.Ink)
	vcyl(m, "Ring", at(cf, 0, 2.22, 0), 0.4, math.min(3.2, R), C.TrimWhite)
	vcyl(m, "Bullseye", at(cf, 0, 2.24, 0), 0.4, math.min(1.6, R / 2), C.HoseYellow)
	for i = 0, 5 do
		local a = i * 2 * math.pi / 6 + math.pi / 6
		P(m, "Leg", at(cf, math.sin(a) * rr, 0.9, math.cos(a) * rr) * ANG(0, a, 0), V(0.6, 1.8, 0.6), darken(C.LockerGrey, 0.2))
	end
	return finish(m, parent, mat)
end

function PropKit.alarmLight(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("AlarmLight")
	local s = if o.mount == "floor" then 1 else -1
	local housing = vcyl(m, "Housing", at(cf, 0, s * 0.3, 0), 0.6, 1.8, C.LockerGrey, noCollide())
	local bulb = ball(m, "Bulb", at(cf, 0, s * 1.0, 0), 1.4, C.AlarmRed, noCollide({ neon = true }))
	for _, sx in { -1, 1 } do
		P(m, "Cage", at(cf, sx * 0.75, s * 1.0, 0), V(0.4, 1.0, 0.4), C.LockerGrey, noCollide())
	end
	local on = o.on ~= false
	local pl = Instance.new("PointLight")
	pl.Color = C.AlarmRed
	pl.Range = 20
	pl.Brightness = 3
	pl.Shadows = false
	pl.Enabled = on
	pl.Parent = bulb
	local sl = Instance.new("SpotLight")
	sl.Name = "Spin"
	sl.Color = C.AlarmRed
	sl.Angle = 45
	sl.Range = 30
	sl.Brightness = 2
	sl.Face = Enum.NormalId.Front
	sl.Enabled = on
	sl.Parent = bulb
	return finish(m, parent, housing)
end

function PropKit.streetLamp(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("StreetLamp")
	local h: number = o.height or 12
	local col: Color3 = o.color or C.PoleDark
	local base = vcyl(m, "Base", at(cf, 0, 0.4, 0), 0.8, 1.6, darken(col, 0.2))
	vcyl(m, "Pole", at(cf, 0, h / 2, 0), h, 0.6, col)
	ball(m, "PoleCap", at(cf, 0, h, 0), 0.8, col)
	P(m, "Arm", at(cf, 0, h - 0.25, -1.0), V(0.5, 0.5, 2.6), col, noCollide())
	P(m, "Head", at(cf, 0, h - 0.3, -2.2), V(1.8, 0.6, 1.8), col, noCollide())
	local bulb = P(m, "Bulb", at(cf, 0, h - 0.75, -2.2), V(1.2, 0.4, 1.2), C.LampWarm, noCollide({ neon = true }))
	local pl = Instance.new("PointLight")
	pl.Color = C.LampWarm
	pl.Range = 24
	pl.Brightness = 1.5
	pl.Enabled = o.on ~= false
	pl.Parent = bulb
	return finish(m, parent, base)
end

-- outdoors --------------------------------------------------------------------------------------

local ROUND_LAYOUTS = {
	{ { 0, 7.5, 0, 7 }, { 1.8, 9.5, 0.6, 5.5 }, { -1.6, 8.8, -0.8, 5.5 } },
	{ { 0, 8, 0, 8 }, { -0.6, 10.4, 0.4, 5 } },
	{ { 0, 7.2, 0, 6.5 }, { 1.4, 9, -1, 5.2 }, { -1.4, 9.3, 1.1, 5 }, { 0, 11, 0, 3.8 } },
}

function PropKit.tree(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Tree")
	local s: number = o.size or 1
	local variant: number = o.variant or 1
	local Ftrunk = burn(o, 60)
	local Fleaf = burn(o, 30)
	if o.kind == "pine" then
		local col: Color3 = o.color or C.PineFoliage
		local trunk = vcyl(m, "Trunk", at(cf, 0, 2.5 * s, 0), 5 * s, 1.2 * s, C.TrunkBrown, Ftrunk)
		local tiers = { { 3.8, 7.5 }, { 6.0, 5.8 }, { 8.0, 4.0 } }
		for i, t in tiers do
			local y, d = t[1] * s, t[2] * s
			local c = if i % 2 == 0 then lighten(col, 0.1) else col
			vcyl(m, "Needles", at(cf, 0, y, 0), 1.2 * s, d, c, Fleaf)
			vcyl(m, "Needles", at(cf, 0, y + 1.1 * s, 0), 1.0 * s, d * 0.65, darken(c, 0.05), Fleaf)
		end
		ball(m, "Tip", at(cf, 0, 10.4 * s, 0), 1.6 * s, lighten(col, 0.1), Fleaf)
		return finish(m, parent, trunk)
	end
	local greens = { C.Leaf1, C.Leaf2, C.LawnGreen }
	local col: Color3 = o.color or greens[(variant - 1) % 3 + 1]
	vcyl(m, "Roots", at(cf, 0, 0.3 * s, 0), 0.6 * s, 1.9 * s, darken(C.TrunkBrown, 0.15), Ftrunk)
	local trunk = vcyl(m, "Trunk", at(cf, 0, 3.5 * s, 0), 7 * s, 1.2 * s, C.TrunkBrown, Ftrunk)
	local layout = ROUND_LAYOUTS[(variant - 1) % #ROUND_LAYOUTS + 1]
	for i, b in layout do
		local c = if i == 1 then col elseif i % 2 == 0 then lighten(col, 0.12) else darken(col, 0.1)
		ball(m, "Canopy", at(cf, b[1] * s, b[2] * s, b[3] * s), b[4] * s, c, Fleaf)
	end
	return finish(m, parent, trunk)
end

function PropKit.bush(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Bush")
	local s: number = o.size or 1
	local col: Color3 = o.color or C.Leaf1
	local F = burn(o, 15)
	local main = ball(m, "Leaves", at(cf, 0, 1.2 * s, 0), 3 * s, col, F)
	ball(m, "Leaves", at(cf, 1.15 * s, 0.95 * s, 0.3 * s), 2.3 * s, lighten(col, 0.12), F)
	ball(m, "Leaves", at(cf, -1.05 * s, 0.95 * s, -0.2 * s), 2.3 * s, darken(col, 0.08), F)
	ball(m, "Leaves", at(cf, 0.2 * s, 2.0 * s, 0.25 * s), 1.8 * s, lighten(col, 0.06), F)
	if o.flowers then
		local fc: Color3 = if typeof(o.flowers) == "Color3" then o.flowers else C.Pink
		for _, p in { { -0.6, 2.2, -1.0 }, { 0.9, 1.8, -1.0 }, { 0.1, 2.75, -0.6 }, { -1.6, 1.4, -0.7 } } do
			ball(m, "Flower", at(cf, p[1] * s, p[2] * s, p[3] * s), math.max(0.5, 0.55 * s), fc, F)
		end
	end
	return finish(m, parent, main)
end

function PropKit.fence(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Fence")
	local L: number = o.length or 8
	local F = burn(o, 20)
	local first: BasePart? = nil
	if o.style == "rail" then
		local col: Color3 = o.color or C.FenceWood
		local gaps = math.max(1, math.ceil(L / 4))
		local seg = L / gaps
		for i = 0, gaps do
			local p = P(m, "Post", at(cf, -L / 2 + i * seg, 1.8, 0), V(0.8, 3.6, 0.8), darken(col, 0.1), F)
			first = first or p
		end
		for i = 1, gaps do
			local x = -L / 2 + (i - 0.5) * seg
			for _, y in { 1.4, 2.8 } do
				P(m, "Rail", at(cf, x, y, -0.1), V(seg, 0.6, 0.4), col, F)
			end
		end
	else
		local col: Color3 = o.color or C.TrimWhite
		local chunks = math.max(1, math.ceil(L / 8))
		local cl = L / chunks
		for i = 1, chunks do
			local x = -L / 2 + (i - 0.5) * cl
			for _, y in { 1.0, 2.2 } do
				local r = P(m, "Rail", at(cf, x, y, 0.35), V(cl, 0.5, 0.4), darken(col, 0.08), F)
				first = first or r
			end
		end
		local count = math.max(2, math.floor(L / 1.4) + 1)
		local step = (L - 0.8) / (count - 1)
		for i = 0, count - 1 do
			local x = -L / 2 + 0.4 + i * step
			P(m, "Picket", at(cf, x, 1.5, 0), V(0.8, 3.0, 0.4), col, F)
			P(m, "PicketTip", at(cf, x, 3.0, 0) * ANG(0, 0, math.pi / 4), V(0.57, 0.57, 0.4), col, F)
		end
	end
	return finish(m, parent, first :: BasePart)
end

function PropKit.mailbox(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Mailbox")
	local col: Color3 = o.color or hex("#3E6A9A")
	local post = P(m, "Post", at(cf, 0, 1.6, 0), V(0.6, 3.2, 0.6), C.FenceWood, burn(o, 20))
	P(m, "Box", at(cf, 0, 3.7, -0.3), V(1.4, 1.0, 2.4), col)
	P(m, "BoxTop", at(cf, 0, 4.2, -0.3) * ANG(0, math.pi / 2, 0), V(2.4, 1.4, 1.4), col, { shape = CYL })
	P(m, "Lid", at(cf, 0, 3.95, -1.55), V(1.5, 1.4, 0.4), darken(col, 0.15))
	P(m, "FlagPost", at(cf, 0.9, 4.0, 0.2), V(0.4, 1.2, 0.4), C.TruckRed)
	P(m, "Flag", at(cf, 0.9, 4.45, -0.25), V(0.4, 0.6, 0.8), C.TruckRed)
	return finish(m, parent, post)
end

function PropKit.car(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Car")
	local col: Color3 = o.color or C.Teal
	local W, L = 6, 11
	local F = if o.flammable then { flammable = true, fuel = 40 } else nil
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			xcyl(m, "Wheel", at(cf, sx * 2.7, 1.3, sz * 3.4), 1.2, 2.6, C.Tyre)
			xcyl(m, "Hub", at(cf, sx * 2.7, 1.3, sz * 3.4), 1.3, 1.2, C.TruckChrome)
		end
	end
	local body = P(m, "Body", at(cf, 0, 2.0, 0), V(W, 2.0, L), col, F)
	P(m, "Skirt", at(cf, 0, 1.2, 0), V(W - 0.4, 0.4, L - 0.6), darken(col, 0.3))
	P(m, "Cabin", at(cf, 0, 4.1, 0.8), V(W - 0.6, 2.2, 5.6), col, F)
	P(m, "Roof", at(cf, 0, 5.3, 0.8), V(W - 0.4, 0.4, 5.8), lighten(col, 0.15), F)
	P(m, "Windshield", at(cf, 0, 4.1, -2.05), V(W - 1.4, 1.6, 0.4), C.Glass, { material = Enum.Material.Glass, transparency = 0.15 })
	P(m, "RearWindow", at(cf, 0, 4.1, 3.65), V(W - 1.4, 1.6, 0.4), C.Glass, { material = Enum.Material.Glass, transparency = 0.15 })
	for _, sx in { -1, 1 } do
		for _, z in { -0.5, 2.1 } do
			P(m, "SideWindow", at(cf, sx * 2.75, 4.2, z), V(0.4, 1.4, 2.2), C.Glass, { material = Enum.Material.Glass, transparency = 0.15 })
		end
		P(m, "Headlight", at(cf, sx * 2.0, 2.4, -L / 2 - 0.1), V(1.1, 0.8, 0.4), C.UiCream)
		P(m, "Taillight", at(cf, sx * 2.2, 2.4, L / 2 + 0.1), V(0.9, 0.6, 0.4), C.HoseRed)
		P(m, "Mirror", at(cf, sx * 3.1, 3.4, -1.7), V(0.5, 0.4, 0.4), col)
	end
	P(m, "Grille", at(cf, 0, 2.2, -L / 2 - 0.1), V(2.0, 0.6, 0.4), C.Ink)
	for _, sz in { -1, 1 } do
		P(m, "Bumper", at(cf, 0, 1.2, sz * (L / 2 + 0.1)), V(W + 0.2, 0.6, 0.6), C.TruckChrome)
	end
	if o.eyes then
		MapKit.googlyEyes(m, at(cf, 0, 4.2, -2.4), 1.2, 0.9)
	end
	return finish(m, parent, body)
end

function PropKit.pool(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Pool")
	local sz = o.size
	local W, D, Lz
	if typeof(sz) == "Vector3" then
		W, D, Lz = sz.X, sz.Y, sz.Z
	elseif typeof(sz) == "number" then
		W, D, Lz = sz, 3, sz
	else
		W, D, Lz = 12, 3, 18
	end
	local base = if o.sunken then -D else 0
	local top = if o.sunken then 0 else D
	local wallH = top - base
	local wallCol = if o.sunken then C.PoolTile else C.TrimWhite
	local floor = P(m, "Floor", at(cf, 0, base + 0.2, 0), V(W, 0.4, Lz), C.PoolTile)
	P(m, "Lane", at(cf, 0, base + 0.25, 0), V(0.8, 0.42, math.max(1, Lz - 4)), hex("#3E8C9E"))
	local my = base + wallH / 2
	P(m, "WallN", at(cf, 0, my, -Lz / 2 + 0.5), V(W, wallH, 1), wallCol)
	P(m, "WallS", at(cf, 0, my, Lz / 2 - 0.5), V(W, wallH, 1), wallCol)
	P(m, "WallW", at(cf, -W / 2 + 0.5, my, 0), V(1, wallH, Lz - 2), wallCol)
	P(m, "WallE", at(cf, W / 2 - 0.5, my, 0), V(1, wallH, Lz - 2), wallCol)
	if not o.sunken then
		P(m, "Stripe", at(cf, 0, top - 0.6, 0), V(W + 0.1, 0.4, Lz + 0.1), C.Water)
	end
	local cy = top + 0.2
	P(m, "CopingN", at(cf, 0, cy, -Lz / 2 + 0.5), V(W + 0.4, 0.4, 1.4), C.Sidewalk)
	P(m, "CopingS", at(cf, 0, cy, Lz / 2 - 0.5), V(W + 0.4, 0.4, 1.4), C.Sidewalk)
	P(m, "CopingW", at(cf, -W / 2 + 0.5, cy, 0), V(1.4, 0.4, Lz - 2.4), C.Sidewalk)
	P(m, "CopingE", at(cf, W / 2 - 0.5, cy, 0), V(1.4, 0.4, Lz - 2.4), C.Sidewalk)
	local waterTop = top - 0.4
	local waterH = waterTop - (base + 0.4)
	P(m, "Water", at(cf, 0, base + 0.4 + waterH / 2, 0), V(W - 2, waterH, Lz - 2), C.Water, { transparency = 0.45, collide = false })
	ball(m, "BeachBall", at(cf, W / 4, waterTop + 0.3, Lz / 5), 1.4, C.Pink, { collide = false })
	-- ladder at the -Z end
	for _, sx in { -0.8, 0.8 } do
		P(m, "LadderRail", at(cf, sx, top + 0.7, -Lz / 2 + 1.3), V(0.4, 1.4, 0.4), C.TruckChrome)
		P(m, "LadderRail", at(cf, sx, (base + top) / 2 + 0.6, -Lz / 2 + 1.3), V(0.4, wallH, 0.4), C.TruckChrome)
	end
	return finish(m, parent, floor)
end

function PropKit.haystack(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Haystack")
	local s: number = o.size or 1
	local F = burn(o, 40)
	local fab = Enum.Material.Fabric
	local function hay(extra: { [string]: any }?): { [string]: any }
		local t: { [string]: any } = if extra then table.clone(extra) else {}
		t.material = fab
		return t
	end
	vcyl(m, "Skirt", at(cf, 0, 0.4 * s, 0), 0.8 * s, 6.3 * s, darken(C.Hay, 0.12), hay(F))
	local body = vcyl(m, "Stack", at(cf, 0, 2.5 * s, 0), 5 * s, 6 * s, C.Hay, hay(F))
	ball(m, "Top", at(cf, 0, 4.4 * s, 0), 6 * s, lighten(C.Hay, 0.08), hay(F))
	P(m, "Straw", at(cf, 0.3 * s, 7.4 * s, 0) * ANG(0, 0, 0.35), V(0.4, 1.4 * s, 0.4), lighten(C.Hay, 0.15), hay(F))
	P(m, "Straw", at(cf, -0.3 * s, 7.3 * s, 0.2 * s) * ANG(0.3, 0, -0.4), V(0.4, 1.2 * s, 0.4), C.Hay, hay(F))
	return finish(m, parent, body)
end

function PropKit.ladder(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local m = newModel("Ladder")
	local h: number = o.height or 12
	local w: number = o.width or 2.6
	local col: Color3 = o.color or (if o.wood then C.FenceWood else C.TruckChrome)
	local F = if o.wood then burn(o, 25) else nil
	local first: BasePart? = nil
	for _, sx in { -1, 1 } do
		local r = P(m, "Rail", at(cf, sx * w / 2, h / 2, 0), V(0.5, h, 0.5), col, F)
		first = first or r
		P(m, "Foot", at(cf, sx * w / 2, 0.2, 0), V(0.7, 0.4, 0.7), C.Ink)
	end
	local y = 1.0
	while y < h - 0.3 do
		P(m, "Rung", at(cf, 0, y, 0), V(w, 0.4, 0.4), if o.wood then lighten(col, 0.1) else darken(col, 0.1), F)
		y += 1.2
	end
	return finish(m, parent, first :: BasePart)
end

return PropKit
