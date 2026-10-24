--!strict
-- Interiors/Zoo [owner: interiors]. City Zoo dressing for panda_zoo, built when a run binds the zoo district
-- (Interiors/Furnish -> Interiors/Districts.Zoo). Fixed spots in ZooBuilder's local frame (origin = slot
-- centre on the ground, +X east, +Z south), each checked by hand against the builder's own pieces:
--   Panda house (PandaHut x -140..-124, z 0..16, floor top y 0.6, open front x -124 between z 4 and 12;
--     keeper R3 sitting at (-134, 9) facing +X, food bowl (-128, 4), fire Z3 on the back wall):
--     a straw bed and a bamboo bundle in the den half (north), rocks, the keeper's corner (south: a desk
--     with a clipboard and a radio, a feed bin, a broom, a shelf of snack jars, a PANDA FACTS poster),
--     a lantern. The lane from the opening to the keeper stays clear.
--   Enclosure (x -150..-60, z -40..60): a bamboo feeding rack and rock piles away from the carry line
--     panda (-104, 4) -> keeper door (-60, 40); a brass hand rail + info plaques along the viewing glass
--     on the visitor deck (x -59..-47, z -10..30, top y 1.2).
--   Gift shop (x 50..86, z 98..126, floor y 0.6; door (50, 112), counter (78, 112), cashier R2 (82, 113),
--     shelves along z 99.6 / 124.4): two display tables of plush + snow globes, a postcard spinner, a
--     T-shirt rail, a giant plush panda, a price sign over the till, a SALE banner. The aisle door ->
--     counter (z 109..115) stays clear.
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Zoo = {}

local C = Kit.C
local P = Kit.part
local CF = CFrame.new
local V = Vector3.new
local ANG = CFrame.Angles
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0
local hex = Color3.fromHex

local STRAW = hex("#E3AB56")
local BAMBOO = hex("#8AAF4A")
local BAMBOO_DARK = hex("#5E8C3E")
local STONE = hex("#A89C8C")
local STONE_DARK = hex("#857A6E")
local PANDA_W = hex("#F7F4EE")
local PANDA_B = hex("#1A1714")
local BRASS = hex("#C9A227")

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function model(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local function done(m: Model, parent: Instance, primary: BasePart): Model
	m.PrimaryPart = primary
	m.Parent = parent
	return m
end

local function ball(parent: Instance, name: string, cf: CFrame, dia: number, color: Color3, o: any?): Part
	local op = table.clone(o or {})
	op.shape = Enum.PartType.Ball
	return P(parent, name, cf, V(dia, dia, dia), color, op)
end

-- a cylinder lying along local X
local function log(parent: Instance, name: string, cf: CFrame, len: number, dia: number, color: Color3, o: any?): Part
	local op = table.clone(o or {})
	op.shape = Enum.PartType.Cylinder
	return P(parent, name, cf, V(len, dia, dia), color, op)
end

---------------------------------------------------------------------------------------------------
-- props (cf = floor point, faces -Z)
---------------------------------------------------------------------------------------------------
-- Straw bed: a flat straw pile with a few tufts (flammable, walk-through except the base).
local function strawBed(parent: Instance, cf: CFrame, o: any): Model
	local m = model("StrawBed")
	local w, d = o.w or 5.5, o.d or 4
	local base = P(m, "StrawPile", cf * CF(0, 0.3, 0), V(w, 0.6, d), STRAW, { fuel = 14 })
	for k, t in { { -1.6, -0.8 }, { 0.9, 0.9 }, { 1.8, -1.1 }, { -0.4, 1.2 } } do
		P(m, "StrawTuft", cf * CF(t[1], 0.75, t[2]) * ANG(0, k * 0.7, 0.2), V(1.6, 0.4, 1.1), STRAW:Lerp(C.White, 0.12), { fuel = 4 })
	end
	ball(m, "PandaPlush", cf * CF(w / 2 - 1, 1, d / 2 - 1), 1.1, PANDA_W)
	return done(m, parent, base)
end

-- Bundle of cut bamboo lying on the floor, tied with a strap.
local function bambooBundle(parent: Instance, cf: CFrame, o: any): Model
	local m = model("BambooBundle")
	local len = o.len or 4
	local first: BasePart? = nil
	for k, p in { { -0.45, 0.35 }, { 0.45, 0.35 }, { 0, 0.95 }, { -0.9, 0.35 }, { 0.9, 0.35 } } do
		local b = log(m, "BambooCane", cf * CF(0, p[2], p[1]), len + (k % 2) * 0.6, 0.6, if k % 2 == 0 then BAMBOO_DARK else BAMBOO, { fuel = 6 })
		first = first or b
	end
	P(m, "BundleStrap", cf * CF(0, 0.6, 0), V(0.35, 1.5, 2.3), hex("#B0123C"))
	return done(m, parent, first :: BasePart)
end

-- A pile of rounded rocks (solid).
local function rocks(parent: Instance, cf: CFrame, o: any): Model
	local m = model("RockPile")
	local s = o.size or 1
	local a = ball(m, "Rock", cf * CF(0, 0.7 * s, 0), 2.4 * s, STONE, { solid = true })
	ball(m, "Rock", cf * CF(1.5 * s, 0.45 * s, 0.6 * s), 1.6 * s, STONE_DARK, { solid = true })
	ball(m, "Rock", cf * CF(-1.2 * s, 0.35 * s, 0.9 * s), 1.2 * s, STONE, { solid = true })
	return done(m, parent, a)
end

-- Keeper's desk: small table, clipboard, radio, a stool.
local function keeperDesk(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("KeeperDesk")
	local top = P(m, "KeeperDeskTop", cf * CF(0, 2.6, 0), V(3, 0.25, 1.8), hex("#B07A4A"), { solid = true, fuel = 8 })
	for _, x in { -1.3, 1.3 } do
		P(m, "KeeperDeskLeg", cf * CF(x, 1.25, 0), V(0.25, 2.5, 1.5), hex("#8A4A28"))
	end
	local clip = P(m, "Clipboard", cf * CF(-0.6, 2.78, 0) * ANG(0, 0.3, 0), V(0.9, 0.1, 1.2), hex("#8A4A28"), { fuel = 2 })
	local g = Kit.gui(clip, Enum.NormalId.Top, 40)
	Kit.rect(g, 0.1, 0.12, 0.8, 0.8, C.White)
	Kit.text(g, 0.12, 0.15, 0.76, 0.3, "FEED MEI MEI", C.Ink)
	P(m, "Radio", cf * CF(0.8, 3.1, 0.2), V(0.6, 0.8, 0.35), C.Red)
	P(m, "RadioAntenna", cf * CF(0.95, 3.8, 0.2), V(0.08, 0.7, 0.08), C.Iron)
	Kit.cylY(m, "KeeperStool", cf * CF(0, 0.85, 1.6), 1.7, 1.3, C.Teal, { fuel = 4 })
	return done(m, parent, top)
end

-- Feed bin (barrel with a lid + label).
local function feedBin(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("FeedBin")
	local b = Kit.cylY(m, "FeedBin", cf * CF(0, 1.4, 0), 2.8, 2, C.Teal, { solid = true, fuel = 8 })
	Kit.cylY(m, "FeedBinLid", cf * CF(0, 2.9, 0), 0.25, 2.2, C.TealDark)
	local lab = P(m, "FeedLabel", cf * CF(0, 1.5, -1.02), V(1.2, 0.8, 0.05), C.White)
	Kit.text(Kit.gui(lab, Enum.NormalId.Front, 40), 0.05, 0.1, 0.9, 0.8, "BAMBOO\nSNACKS", C.Ink)
	return done(m, parent, b)
end

-- Broom leaning on a wall (cf = wall face).
local function broom(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("Broom")
	local h = P(m, "BroomHandle", cf * CF(0, 2.6, -0.5) * ANG(math.rad(12), 0, 0), V(0.18, 5, 0.18), hex("#B07A4A"))
	P(m, "BroomHead", cf * CF(0, 0.35, -0.95), V(1.4, 0.7, 0.4), STRAW, { fuel = 3 })
	return done(m, parent, h)
end

-- Wall shelf with jars (cf = wall face).
local function jarShelf(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("JarShelf")
	local s = P(m, "Shelf", cf * CF(0, o.y or 5, -0.5), V(o.w or 4, 0.2, 0.9), hex("#8A4A28"), { fuel = 4 })
	for k = 0, 3 do
		Kit.cylY(m, "Jar", cf * CF(-1.4 + k * 0.95, (o.y or 5) + 0.5, -0.5), 0.8, 0.6, pick(rng, { C.Mustard, C.Green, C.Red, C.Orange }), { tr = 0.2 })
	end
	return done(m, parent, s)
end

-- Lantern hanging on a short chain (cf = the point it hangs from).
local function lantern(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("Lantern")
	P(m, "LanternChain", cf * CF(0, -0.5, 0), V(0.1, 1, 0.1), C.Iron)
	local glass = P(m, "LanternGlass", cf * CF(0, -1.5, 0), V(0.9, 1.2, 0.9), C.LampWarm, { neon = true })
	P(m, "LanternCap", cf * CF(0, -0.8, 0), V(1.1, 0.25, 1.1), C.Iron)
	local l = Instance.new("PointLight")
	l.Color = C.LampWarm
	l.Range = 14
	l.Brightness = 0.9
	l.Shadows = false
	l.Parent = glass
	return done(m, parent, glass)
end

-- Bamboo feeding rack: a wooden trough on legs, full of cut bamboo.
local function feedingRack(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("FeedingRack")
	local t = P(m, "Trough", cf * CF(0, 1.6, 0), V(6, 1, 1.8), hex("#8A4A28"), { solid = true, fuel = 12 })
	for _, x in { -2.6, 2.6 } do
		P(m, "TroughLeg", cf * CF(x, 0.55, 0), V(0.4, 1.1, 1.4), hex("#5A3A22"))
	end
	for k = 0, 4 do
		log(m, "BambooCane", cf * CF(0, 2.25, -0.6 + k * 0.3) * ANG(0, (k - 2) * 0.06, 0.08 * (k % 2)), 6.4, 0.45, if k % 2 == 0 then BAMBOO else BAMBOO_DARK, { fuel = 5 })
	end
	local sign = P(m, "RackSign", cf * CF(0, 3.6, 0.95), V(2.6, 0.9, 0.1), C.Mustard)
	Kit.text(Kit.gui(sign, Enum.NormalId.Back, 30), 0.05, 0.1, 0.9, 0.8, "LUNCH", C.Ink)
	return done(m, parent, t)
end

-- Brass hand rail along local X with posts every ~8 studs (walk-through).
local function rail(parent: Instance, cf: CFrame, o: any): Model
	local m = model("ViewingRail")
	local len = o.len or 20
	local top = P(m, "HandRail", cf * CF(0, 3.3, 0), V(len, 0.3, 0.3), BRASS)
	local n = math.max(2, math.floor(len / 8) + 1)
	for k = 0, n - 1 do
		P(m, "RailPost", cf * CF(-len / 2 + k * len / (n - 1), 1.65, 0), V(0.25, 3.3, 0.25), BRASS)
	end
	return done(m, parent, top)
end

-- Info plaque on a slanted stand (cf = floor point, the reader stands on -Z).
local function plaque(parent: Instance, cf: CFrame, o: any): Model
	local m = model("InfoPlaque")
	P(m, "PlaqueStand", cf * CF(0, 1.4, 0), V(0.3, 2.8, 0.3), C.TealDark)
	local p = P(m, "Plaque", cf * CF(0, 2.9, 0) * ANG(math.rad(-35), 0, 0), V(2.4, 1.6, 0.12), C.Cream)
	local g = Kit.gui(p, Enum.NormalId.Front, 40)
	Kit.rect(g, 0, 0, 1, 0.25, C.TealDark)
	Kit.text(g, 0.05, 0.02, 0.9, 0.2, o.title or "GIANT PANDA", C.White)
	Kit.text(g, 0.06, 0.3, 0.88, 0.62, o.text or "", C.Ink)
	return done(m, parent, p)
end

-- Display table with plush pandas and snow globes.
local function displayTable(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("DisplayTable")
	local top = P(m, "DisplayTop", cf * CF(0, 2.5, 0), V(4.4, 0.3, 3), hex("#D9B27A"), { solid = true, fuel = 10 })
	P(m, "DisplayBase", cf * CF(0, 1.2, 0), V(3.6, 2.35, 2.2), C.TealDark, { solid = true })
	for k = 0, 3 do
		local x, z = -1.4 + (k % 2) * 2.8, -0.7 + (k // 2) * 1.4
		if k % 2 == 0 then
			local b = ball(m, "PlushPanda", cf * CF(x, 3.15, z), 1, PANDA_W, { fuel = 3 })
			ball(m, "PlushEar", b.CFrame * CF(0.35, 0.45, 0), 0.35, PANDA_B)
		else
			ball(m, "SnowGlobe", cf * CF(x, 3.05, z), 0.8, C.Glass, { tr = 0.3 })
			P(m, "GlobeBase", cf * CF(x, 2.75, z), V(0.7, 0.2, 0.7), pick(rng, { C.Red, C.Navy, C.Gold }))
		end
	end
	ball(m, "PlushBig", cf * CF(0, 3.4, 0), 1.6, PANDA_W, { fuel = 4 })
	return done(m, parent, top)
end

-- Postcard spinner (walk-through).
local function spinner(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("PostcardSpinner")
	P(m, "SpinnerPole", cf * CF(0, 2.6, 0), V(0.2, 5.2, 0.2), C.Steel)
	Kit.cylY(m, "SpinnerBase", cf * CF(0, 0.1, 0), 0.2, 1.4, C.Iron)
	local first: BasePart? = nil
	for k = 0, 3 do
		local face = cf * ANG(0, k * R90 + 0.3, 0)
		local card = P(m, "Postcards", face * CF(0, 3.2, -0.5), V(1.2, 3.2, 0.08), C.White, { fuel = 2 })
		local g = Kit.gui(card, Enum.NormalId.Front, 30)
		for r = 0, 2 do
			Kit.rect(g, 0.1, 0.05 + r * 0.32, 0.8, 0.27, pick(rng, { C.Sky, C.Green, C.Peach, C.Mustard }))
		end
		first = first or card
	end
	return done(m, parent, first :: BasePart)
end

-- T-shirt rail along local X.
local function shirtRail(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("ShirtRail")
	local len = o.len or 4
	local r = P(m, "ShirtRailBar", cf * CF(0, 4.6, 0), V(len, 0.15, 0.15), C.Chrome)
	for _, x in { -len / 2, len / 2 } do
		P(m, "ShirtRailPost", cf * CF(x, 2.3, 0), V(0.15, 4.6, 0.15), C.Chrome)
	end
	for k = 1, 5 do
		local x = -len / 2 + k * len / 6
		local s = P(m, "TShirt", cf * CF(x, 3.4, 0) * ANG(0, R90, 0), V(1.6, 2, 0.15), pick(rng, { C.Red, C.Teal, C.Mustard, C.Pink, C.White }), { fuel = 2 })
		if k == 3 then
			Kit.text(Kit.gui(s, Enum.NormalId.Front, 30), 0.1, 0.3, 0.8, 0.4, "I <3\nPANDAS", C.Ink)
		end
	end
	return done(m, parent, r)
end

-- Giant plush panda sitting in a corner.
local function giantPanda(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("GiantPlush")
	local body = ball(m, "PlushBody", cf * CF(0, 1.8, 0), 3.6, PANDA_W, { solid = true, fuel = 10 })
	ball(m, "PlushHead", cf * CF(0, 4.2, -0.2), 2.6, PANDA_W, { fuel = 6 })
	for _, x in { -1, 1 } do
		ball(m, "PlushEar", cf * CF(x, 5.3, -0.1), 0.9, PANDA_B)
		ball(m, "PlushEye", cf * CF(x * 0.5, 4.4, -1.35), 0.6, PANDA_B)
		ball(m, "PlushArm", cf * CF(x * 1.7, 2.2, -0.6), 1.2, PANDA_B)
	end
	local tag = P(m, "PriceTag", cf * CF(1.2, 1.4, -1.85) * ANG(0, 0, 0.3), V(0.9, 0.5, 0.05), C.Red)
	Kit.text(Kit.gui(tag, Enum.NormalId.Front, 40), 0, 0, 1, 1, "$67", C.White)
	return done(m, parent, body)
end

---------------------------------------------------------------------------------------------------
-- the zoo
---------------------------------------------------------------------------------------------------
function Zoo.district(_model: Model, origin: CFrame, root: Model, rng: Random)
	local function put(fn: any, x: number, y: number, z: number, yaw: number?, o: any?): Model
		local op = o or {}
		op.rng = rng
		return fn(root, origin * CF(x, y, z) * ANG(0, yaw or 0, 0), op)
	end
	-- panda house
	local HY = 0.6
	put(strawBed, -136, HY, 3.2, N, { w = 5.5, d = 4 })
	put(bambooBundle, -131, HY, 2, N, { len = 4 })
	put(rocks, -138.2, HY, 7.6, N, { size = 0.7 })
	put(keeperDesk, -137.6, HY, 13.4, W, {})
	put(feedBin, -126.6, HY, 14.2, N, {})
	put(broom, -129, HY, 15.5, N, {})
	put(jarShelf, -139.5, HY, 11.5, E, { y = 5.2, w = 4 })
	put(Kit.poster, -139.5, HY, 4.5, E, { w = 2.6, h = 3, y = 5.8, text = "PANDA\nFACTS:\nsleeps 12h\neats 12h", bg = C.PaleBlue })
	put(Kit.sign, -132, HY, 15.5, N, { text = "KEEPER'S CORNER", y = 6.8, w = 5, bg = C.TealDark })
	put(lantern, -132, HY + 8.9, 8, N, {})
	-- enclosure: feeding rack + rock piles off the panda -> keeper-door carry line
	put(feedingRack, -112, 0.3, -6, N, {})
	put(rocks, -126, 0.3, -24, N, { size = 1.3 })
	put(rocks, -88, 0.3, 50, N, { size = 1.1 })
	put(bambooBundle, -118, 0.3, 30, W, { len = 5 })
	-- viewing glass: brass rail on the deck + info plaques
	put(rail, -58.4, 1.2, 10, W, { len = 38 })
	put(plaque, -55.5, 1.2, -6, E, { title = "GIANT PANDA", text = "Eats 12 hours a day.\nRefuses to walk.\nTakes two to carry." })
	put(plaque, -55.5, 1.2, 26, E, { title = "MEI MEI", text = "Age 6. Likes bamboo,\nnaps, and firefighters." })
	-- gift shop
	local GY = 0.6
	put(displayTable, 64, GY, 105.2, N, {})
	put(displayTable, 64, GY, 118.8, N, {})
	put(spinner, 72.5, GY, 105, N, {})
	put(shirtRail, 72.5, GY, 119.5, N, { len = 4 })
	put(giantPanda, 83.2, GY, 102.2, S, {})
	put(Kit.sign, 85.5, GY, 112, W, { text = "PANDA PLUSH $6.70", y = 7.4, w = 6, bg = C.Red })
	local banner = P(root, "SaleBanner", origin * CF(68, GY + 10.2, 112) * ANG(0, W, 0), V(10, 1.4, 0.12), C.Mustard)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		Kit.text(Kit.gui(banner, face, 30), 0.03, 0.08, 0.94, 0.84, "MEGA SALE! EVERYTHING MUST GO", C.Red)
	end
	put(Kit.plant, 84.4, GY, 123.8, N, { size = 1.2, color = C.Pink })
end

return Zoo
