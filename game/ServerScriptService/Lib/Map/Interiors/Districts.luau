--!strict
-- Interiors/Districts [owner: interiors]. Extra interior dressing for location-builder districts whose
-- builder has no Furnish of its own, built when a run binds the district (Interiors/Furnish). Each
-- entry places Kit pieces at fixed spots in the builder's own local frame (model attr InteriorOrigin =
-- the origin its Build got), checked by hand against the builder's furniture, doors, windows and
-- rescue spots (listed next to each block).
--   Forest: the ranger cabin (cabin frame = origin * (-14, 0, 4), floor y 1.2, room x -11..11, z -7..7)
--   Farm:   the farmhouse (origin * (-100, 0, 14), floor y 1.2, kitchen/living x -13..4, bedroom 4..13)
--           and the barn (origin * (40, 0, -2), dirt floor y 0.6, stalls x < -8, bales x > 10)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Districts = {}

local C = Kit.C
local CF = CFrame.new
local V = Vector3.new
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0

type Put = (fn: any, x: number, y: number, z: number, yaw: number?, opts: { [string]: any }?) -> Model

local function placer(root: Instance, frame: CFrame, rng: Random): Put
	return function(fn: any, x: number, y: number, z: number, yaw: number?, opts: { [string]: any }?): Model
		local o = opts or {}
		o.rng = rng
		return fn(root, frame * CF(x, y, z) * CFrame.Angles(0, yaw or 0, 0), o)
	end
end

-- small one-off props
local function coatRack(parent: Instance, cf: CFrame, o: any): Model
	local m = Instance.new("Model")
	m.Name = "CoatRack"
	Kit.part(m, "RackBase", cf * CF(0, 0.15, 0), V(1.4, 0.3, 1.4), C.Wood)
	local pole = Kit.part(m, "RackPole", cf * CF(0, 3, 0), V(0.3, 5.8, 0.3), C.Wood)
	Kit.part(m, "Coat", cf * CF(0.35, 3.9, 0), V(0.6, 2.4, 1.3), o.coat or C.Leaf, { fuel = 6 })
	Kit.cylY(m, "HatBrim", cf * CF(-0.2, 5.75, 0), 0.15, 1.6, Color3.fromHex("#8A6A45"))
	Kit.cylY(m, "HatCrown", cf * CF(-0.2, 6.05, 0), 0.5, 0.9, Color3.fromHex("#8A6A45"))
	m.PrimaryPart = pole
	m.Parent = parent
	return m
end

local function firstAid(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "FirstAid"
	local b = Kit.part(m, "AidBox", cf * CF(0, 5, -0.3), V(1.6, 1.2, 0.5), C.White)
	local g = Kit.gui(b, Enum.NormalId.Front, 40)
	Kit.rect(g, 0.42, 0.15, 0.16, 0.7, C.Red)
	Kit.rect(g, 0.3, 0.4, 0.4, 0.2, C.Red)
	m.PrimaryPart = b
	m.Parent = parent
	return m
end

local function rods(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "FishingRods"
	local a = Kit.part(m, "Rod", cf * CF(-0.3, 3.4, 0) * CFrame.Angles(0, 0, math.rad(-8)), V(0.15, 6.8, 0.15), C.Wood)
	Kit.part(m, "Rod", cf * CF(0.3, 3.4, 0) * CFrame.Angles(0, 0, math.rad(6)), V(0.15, 6.8, 0.15), C.Iron)
	Kit.part(m, "Reel", cf * CF(-0.15, 1.6, -0.2), V(0.5, 0.5, 0.3), C.Steel)
	m.PrimaryPart = a
	m.Parent = parent
	return m
end

local function petBed(parent: Instance, cf: CFrame, o: any): Model
	local m = Instance.new("Model")
	m.Name = "PetBed"
	local b = Kit.cylY(m, "PetCushion", cf * CF(0, 0.3, 0), 0.6, 2.6, o.color or C.Red, { fuel = 6 })
	Kit.cylY(m, "PetPillow", cf * CF(0, 0.65, 0), 0.2, 2, C.Cream)
	Kit.cylY(m, "FoodBowl", cf * CF(1.8, 0.2, 0.4), 0.4, 0.9, C.Steel)
	m.PrimaryPart = b
	m.Parent = parent
	return m
end

local function milkCans(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "MilkCans"
	local first
	for k = 0, 2 do
		local c = Kit.cylY(m, "MilkCan", cf * CF(k * 1.3, 1.1, 0), 2.2, 1.1, C.Steel, { solid = true })
		Kit.cylY(m, "MilkCanLid", cf * CF(k * 1.3, 2.35, 0), 0.3, 0.8, C.Chrome)
		first = first or c
	end
	m.PrimaryPart = first
	m.Parent = parent
	return m
end

local function feedSacks(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "FeedSacks"
	local burlap = Color3.fromHex("#C9A46A")
	local first
	for k, p in { { 0, 0.6, 0, 0 }, { 1.9, 0.6, 0.1, 0.2 }, { 0.9, 1.75, 0, -0.15 } } do
		local s = Kit.part(m, "FeedSack", cf * CF(p[1], p[2], p[3]) * CFrame.Angles(0, p[4], 0), V(1.8, 1.2, 1.2), burlap, { solid = k < 3, fuel = 12 })
		local g = Kit.gui(s, Enum.NormalId.Front, 30)
		Kit.text(g, 0.1, 0.25, 0.8, 0.5, "FEED", C.Red)
		first = first or s
	end
	m.PrimaryPart = first
	m.Parent = parent
	return m
end

local function saddle(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "Saddle"
	local beam = Kit.part(m, "SawhorseBeam", cf * CF(0, 2.6, 0), V(0.5, 0.4, 3.4), C.WoodLight, { solid = true, fuel = 8 })
	for _, z in { -1.4, 1.4 } do
		Kit.part(m, "SawhorseLegs", cf * CF(0, 1.2, z), V(1.6, 2.4, 0.3), C.WoodLight)
	end
	Kit.part(m, "SaddleSeat", cf * CF(0, 3.1, 0), V(1.8, 0.6, 2.2), Color3.fromHex("#7A3A1E"), { fuel = 10 })
	Kit.part(m, "SaddleHorn", cf * CF(0, 3.6, -0.8), V(0.4, 0.6, 0.4), Color3.fromHex("#5A2A12"))
	Kit.part(m, "SaddleBlanket", cf * CF(0, 2.75, 0), V(2.4, 0.2, 2.6), C.Red, { fuel = 5 })
	m.PrimaryPart = beam
	m.Parent = parent
	return m
end

-- pegboard with tool silhouettes on a wall (cf = wall face, -Z into the room)
local function toolBoard(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "ToolBoard"
	local b = Kit.part(m, "Pegboard", cf * CF(0, 5.5, -0.1), V(5, 3, 0.15), Color3.fromHex("#C99A62"), { fuel = 6 })
	local g = Kit.gui(b, Enum.NormalId.Front, 30)
	Kit.rect(g, 0.08, 0.15, 0.05, 0.6, C.Iron) -- rake handle
	Kit.rect(g, 0.03, 0.12, 0.15, 0.08, C.Iron)
	Kit.rect(g, 0.3, 0.2, 0.18, 0.12, C.Red) -- hammer
	Kit.rect(g, 0.37, 0.3, 0.04, 0.45, Color3.fromHex("#8A6A45"))
	Kit.rect(g, 0.55, 0.25, 0.3, 0.2, C.Steel, nil, -8) -- saw
	Kit.rect(g, 0.62, 0.55, 0.1, 0.35, C.Mustard) -- trowel
	Kit.rect(g, 0.85, 0.15, 0.06, 0.7, C.Leaf) -- hose coil-ish
	m.PrimaryPart = b
	m.Parent = parent
	return m
end

local function lantern(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "HangingLantern"
	Kit.part(m, "LanternChain", cf * CF(0, -0.6, 0), V(0.1, 1.2, 0.1), C.Iron)
	local glass = Kit.part(m, "LanternGlass", cf * CF(0, -1.7, 0), V(0.9, 1.2, 0.9), C.LampWarm, { neon = true })
	Kit.part(m, "LanternCap", cf * CF(0, -1, 0), V(1.1, 0.25, 1.1), C.Iron)
	local l = Instance.new("PointLight")
	l.Color = C.LampWarm
	l.Range = 14
	l.Brightness = 0.9
	l.Shadows = false
	l.Parent = glass
	m.PrimaryPart = glass
	m.Parent = parent
	return m
end

local function pie(parent: Instance, cf: CFrame, _o: any): Model
	local m = Instance.new("Model")
	m.Name = "Pie"
	local p = Kit.cylY(m, "PieCrust", cf * CF(0, 0.2, 0), 0.4, 1.6, Color3.fromHex("#D9A55A"), { fuel = 3 })
	Kit.cylY(m, "PieFilling", cf * CF(0, 0.42, 0), 0.06, 1.3, C.Red)
	Kit.cylY(m, "Kettle", cf * CF(-1.8, 0.45, 0.1), 0.9, 0.9, C.Teal)
	m.PrimaryPart = p
	m.Parent = parent
	return m
end

---------------------------------------------------------------------------------------------------
-- Pine Ridge ranger cabin. Builder: table (-7,-5.4) + chair, radio, map board (1,6,-6.9) on the
-- back wall, bed (6.5,-4.4) along X, stove (8,4.6), firewood (5,6.2), rug (-1,1), bookshelf
-- (-10.4,2), ranger R5 lying at (0.5,1); locked door (0,8); windows front x +-7, back x -5, sides z 0.
---------------------------------------------------------------------------------------------------
function Districts.Forest(model: Model, origin: CFrame, root: Model, rng: Random)
	local cf = origin * CF(-14, 0, 4)
	local FY = 1.2
	local put = placer(root, cf, rng)
	put(Kit.armchair, 4.4, FY, 1.4, E, { color = Color3.fromHex("#B83A2E") }) -- by the stove
	put(Kit.floorLamp, 3.2, FY, 4.2)
	put(coatRack, 2.8, FY, 6.4, N, { coat = Color3.fromHex("#4F7A3A") })
	put(firstAid, 10.9, FY, -3, W)
	put(rods, -2.8, FY, 6.6)
	put(pie, 8, FY + 3, 4.6) -- a kettle (and a pie) on the wood stove
	put(Kit.picture, -10.9, FY, -4, E, { y = 6, kind = "sea" })
	put(Kit.picture, 10.9, FY, 3.6, W, { y = 6, kind = "photo" })
	put(Kit.clock, 5.6, FY, -6.9, S, { y = 7.8, rim = C.Leaf })
	put(Kit.plant, -10, FY, 6.3, N, { size = 0.9 })
	put(lantern, -7, 10.6, -5)
end

---------------------------------------------------------------------------------------------------
-- Sunny Acres farmhouse + barn.
-- Farmhouse: counter (-9,-8.4) len 6, fridge (-12,-4), table (-6,0) + chairs z +-2.6, sofa (-2,7.6),
-- bookshelf (2.8,-6), bed (9,-5.4) toward the back wall, R4 lying (9,1.5); partition x 4 (gap z
-- 2.5..6.5); front door (0,10), back door (-3,-10); windows front x -8 / 8, back -8 / 9, sides z 0.
-- Barn: stalls x -15..-8 (z -11.5..4.5), dog R2 (-11.5,0.5), bales x 11.5 z -9..-2, ladder (3,-1.7),
-- loft z < -2 at y 9.5, opening x -6..6 on z 12, wheelbarrow (11,9), locked side door (15.5, 7.5).
---------------------------------------------------------------------------------------------------
function Districts.Farm(model: Model, origin: CFrame, root: Model, rng: Random)
	local hcf = origin * CF(-100, 0, 14)
	local FY = 1.2
	local put = placer(root, hcf, rng)
	put(Kit.pendant, -6, 12, 0, N, { color = C.Red })
	put(Kit.pendant, 9, 12, -3, N, { color = C.Mustard })
	put(Kit.floorLamp, -7.6, FY, 8.6)
	put(pie, -10.5, FY + 3.6, -8.4)
	put(Kit.picture, -12.9, FY, 5, E, { y = 6.5, kind = "photo" })
	put(Kit.picture, -12.9, FY, -7.6, E, { y = 6.6 })
	put(Kit.clock, 3.4, FY, 0, W, { y = 8.6, rim = C.Teal })
	put(petBed, -11, FY, 6.6, N, { color = C.Red })
	put(Kit.wardrobe, 12, FY, 4.3, W, { w = 4, h = 7, color = C.WoodLight })
	put(Kit.wardrobe, 11.5, FY, 8.4, S, { w = 3, h = 3.6, color = C.Cream })
	put(Kit.rug, 9, FY, 6.5, N, { w = 4, d = 2.4, color = C.Teal, pattern = "dots" })
	local bcf = origin * CF(40, 0, -2)
	local BY = 0.5
	local bput = placer(root, bcf, rng)
	bput(lantern, -4, BY + 7.6, -1.4)
	bput(lantern, 5, BY + 7.6, -1.4)
	bput(milkCans, 6.6, BY, 10.4)
	bput(feedSacks, -9.3, BY, 10.4)
	bput(saddle, 12, BY, 3, N)
	bput(toolBoard, 15, BY, 3, W)
end

---------------------------------------------------------------------------------------------------
-- Stor-Mor self storage: Interiors/Depot (warehouse yard, guard booth, office CCTV desk)
---------------------------------------------------------------------------------------------------
Districts.Storage = function(model: Model, origin: CFrame, root: Model, rng: Random)
	local Depot = require(script.Parent:WaitForChild("Depot") :: ModuleScript) :: any
	Depot.district(model, origin, root, rng)
end

return Districts
