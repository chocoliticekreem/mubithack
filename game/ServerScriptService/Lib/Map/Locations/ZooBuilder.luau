-- ZooBuilder [owner: G2]. CITY ZOO at sunset: the trailer's panda grab (t=21-22, docs/game/05 §1,
-- docs/game/02 Pets). Slot 8. Local frame: origin = slot centre on the ground, +X east, +Z south
-- (the gate faces +Z, toward the road and the default preview camera).
--   Road Z 172..188, entrance plaza Z 140..170, gate + arch at Z 140 (X -14..14), perimeter fence
--   X -170..170, Z -170..140. Main path north from the gate to the fountain plaza (0, 85) and on to
--   the giraffes; side paths west to the panda deck, east to the elephants.
--   PANDA bamboo enclosure X -150..-60, Z -40..60 (stone wall + bamboo fence, glass on the viewing
--     side, locked keeper door on the east wall at Z 40, hut, bamboo grove, pond, climbing deck).
--   ELEPHANTS X 60..150, Z -40..60. GIRAFFES X -50..50, Z -150..-70 (+ feeding platform).
--   FLAMINGO pond (32, 90). PENGUINS X 70..150 / MONKEY ISLAND X -150..-70, both Z -150..-80. GIFT SHOP X 50..86, Z 98..126 (front door faces the path, -X).
--   SNACK kiosk X -80..-64, Z 102..118.
-- Fire starts Z1..Z4 (tag FireStart on a Flammable part, attr FireId + BuildingId): gift shop shelf,
--   bamboo grove beside the panda, panda hut, snack kiosk.
-- Rescue spawns (tag RescueSpawn, attr Kind/SpawnId/BuildingId/Pose; -Z = facing): R1 Panda in the
--   bamboo grove, R2 Civilian cashier in the gift shop, R3 Civilian zookeeper in the panda hut.
-- TruckSpot (outside the gate, facing west) + PlayerSpawn (in front of the gate). Hydrants x3.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local ZooBuilder = {}
ZooBuilder.Id = "Zoo"
ZooBuilder.Slot = 8

local TAG: any = Names.Tag
local T_TRUCKSPOT = TAG.TruckSpot or "TruckSpot"
local T_PLAYERSPAWN = TAG.PlayerSpawn or "PlayerSpawn"

local hex = Color3.fromHex
local C = {
	Grass = hex("#5E8C3E"),
	Lawn = hex("#7FAF4A"),
	Lush = hex("#6F9A3A"),
	Sand = hex("#E3C08A"),
	Savanna = hex("#D2B36A"),
	Path = hex("#D9CBB8"),
	Plaza = hex("#C9B8A8"),
	Asphalt = hex("#4A4650"),
	LineYellow = hex("#E3B23C"),
	Stone = hex("#A89C8C"),
	StoneDark = hex("#857A6E"),
	Bamboo = hex("#8AAF4A"),
	BambooDark = hex("#5E8C3E"),
	Leaf = hex("#6F9A3A"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	Thatch = hex("#C9A06A"),
	Straw = hex("#E3AB56"),
	Water = hex("#61A8B6"),
	WaterDeep = hex("#3E8C9E"),
	Glass = hex("#B4DCF0"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Peach = hex("#F4A261"),
	Lilac = hex("#CDB4DB"),
	Pink = hex("#FF7FB0"),
	Cream = hex("#FFF1D6"),
	White = hex("#F7F4EE"),
	PandaWhite = hex("#F4F1EA"),
	PandaBlack = hex("#1E1B1D"),
	Ink = hex("#1A1210"),
	Steel = hex("#8A8C90"),
	SteelDark = hex("#3A3A40"),
	FenceGreen = hex("#2F5F5A"),
	Elephant = hex("#9AA0A8"),
	ElephantEar = hex("#B8A0A8"),
	Giraffe = hex("#E3AB56"),
	GiraffeSpot = hex("#8A4A28"),
	Red = hex("#C8232B"),
	Lamp = hex("#FFC97A"),
	Tile = hex("#EFE7D8"),
	TileB = hex("#BFD8D8"),
	Roof = hex("#5A3A32"),
}

local CYL, BALL = Enum.PartType.Cylinder, Enum.PartType.Ball
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2)

local O: CFrame = CFrame.identity
local PropKit: any = nil

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

local function facing(x: number, y: number, z: number, dx: number, dz: number): CFrame
	local p = V(x, y, z)
	return CFrame.lookAt(p, p + V(dx, 0, dz))
end

local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, opts: { [string]: any }?): Part
	local o: any = if opts then table.clone(opts) else {}
	o.color = color
	if o.flammable == nil then
		o.flammable = false
	end
	return MapKit.part(parent, name, O * cf, size, o)
end

local function cyl(parent: Instance, name: string, cf: CFrame, axis: string, length: number, dia: number, color: Color3, opts: { [string]: any }?): Part
	local rot = if axis == "y" then UPRIGHT elseif axis == "z" then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity
	local o: any = if opts then table.clone(opts) else {}
	o.shape = CYL
	return part(parent, name, cf * rot, V(length, dia, dia), color, o)
end

local function ball(parent: Instance, name: string, cf: CFrame, dia: number, color: Color3, opts: { [string]: any }?): Part
	local o: any = if opts then table.clone(opts) else {}
	o.shape = BALL
	return part(parent, name, cf, Vector3.one * dia, color, o)
end

-- WedgePart: high edge at local +Z, slope falls toward -Z.
local function wedge(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, flam: boolean?): WedgePart
	local w = Instance.new("WedgePart")
	w.Name = name
	w.Anchored = true
	w.CanTouch = false
	w.Size = size
	w.CFrame = O * cf
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

local function folder(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function light(p: BasePart, color: Color3, range: number, brightness: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = p
end

local function label(p: BasePart, text: string, color: Color3, stroke: Color3?, face: Enum.NormalId?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = face or Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.LightInfluence = 0.4
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.Font = Enum.Font.FredokaOne
	t.TextColor3 = color
	if stroke then
		t.TextStrokeColor3 = stroke
		t.TextStrokeTransparency = 0
	end
	t.Parent = sg
	sg.Parent = p
end

-- Sign board w x h; cf's -Z faces the reader.
local function sign(parent: Instance, name: string, cf: CFrame, w: number, h: number, color: Color3, text: string, textColor: Color3, stroke: Color3?): Part
	local p = part(parent, name, cf, V(w, h, 0.4), color)
	label(p, text, textColor, stroke)
	return p
end

local function marker(parent: Instance, name: string, cf: CFrame, size: Vector3, tag: string, attrs: { [string]: any }): Part
	local p = part(parent, name, cf, size, C.Mustard, { transparency = 1, collide = false, tags = { tag } })
	p.CanQuery = false
	for k, val in attrs do
		p:SetAttribute(k, val)
	end
	return p
end

local function fireStart(p: BasePart, id: string, bid: string)
	if not CollectionService:HasTag(p, Names.Tag.Flammable) then
		CollectionService:AddTag(p, Names.Tag.Flammable)
	end
	CollectionService:AddTag(p, Names.Tag.FireStart)
	p:SetAttribute("FireId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
end

local function rescueSpawn(parent: Instance, id: string, kind: string, bid: string, cf: CFrame, pose: string)
	local p = part(parent, id, cf * CFrame.new(0, 1, 0), V(2, 2, 2), C.Mustard, {
		transparency = 1,
		collide = false,
		tags = { Names.Tag.RescueSpawn },
	})
	p.CanQuery = false
	p:SetAttribute(Names.Attr.Kind, kind)
	p:SetAttribute("SpawnId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
	p:SetAttribute("Pose", pose)
end

-- Straight run of <= 8-stud chunks from a to b (base points), height h, thickness t. Returns chunks.
local function wallRun(parent: Instance, name: string, a: Vector3, b: Vector3, h: number, color: Color3, opts: { [string]: any }?, t: number?): { Part }
	local out = {}
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 or h < 0.05 then
		return out
	end
	local dir = d.Unit
	local n = math.max(1, math.ceil(len / 8 - 1e-6))
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * len / n) + V(0, h / 2, 0)
		table.insert(out, part(parent, `{name}_{i}`, CFrame.lookAt(mid, mid + dir), V(t or 1, h, len / n), color, opts))
	end
	return out
end

-- One long (non-chunked) bar from a to b with a square cross-section.
local function bar(parent: Instance, name: string, a: Vector3, b: Vector3, thick: number, color: Color3, opts: { [string]: any }?): Part
	local mid = (a + b) / 2
	return part(parent, name, CFrame.lookAt(mid, b), V(thick, thick, (b - a).Magnitude), color, opts)
end

local function disc(parent: Instance, name: string, x: number, y: number, z: number, dia: number, thick: number, color: Color3, opts: { [string]: any }?): Part
	return cyl(parent, name, CFrame.new(x, y, z), "y", thick, dia, color, opts)
end

local function tryRequire(dir: Instance?, name: string): any
	if not dir then
		return nil
	end
	local ms = dir:FindFirstChild(name)
	if not ms or not ms:IsA("ModuleScript") then
		return nil
	end
	local ok, mod = pcall(require, ms)
	if ok and type(mod) == "table" then
		return mod
	end
	warn(`[ZooBuilder] {name} unavailable: {if ok then "not a table" else mod}`)
	return nil
end

local function prop(kind: string, parent: Instance, cf: CFrame, opts: { [string]: any }?, fallback: (() -> ())?)
	if PropKit and type(PropKit[kind]) == "function" then
		local ok, err = pcall(PropKit[kind], parent, O * cf, opts)
		if ok then
			return
		end
		warn(`[ZooBuilder] PropKit.{kind} failed: {err}`)
	end
	if fallback then
		fallback()
	end
end

local function tree(parent: Instance, x: number, z: number, rng: Random, opts: { [string]: any }?)
	local o: { [string]: any } = { variant = rng:NextInteger(1, 3), flammable = false }
	for k, v in opts or {} do
		o[k] = v
	end
	prop("tree", parent, CFrame.new(x, 0.2, z), o, function()
		cyl(parent, "Trunk", CFrame.new(x, 3, z), "y", 6, 1.4, hex("#7A3A1E"))
		ball(parent, "Leaves", CFrame.new(x, 8, z), 8, C.Leaf)
	end)
end

local function lamp(parent: Instance, cf: CFrame)
	prop("streetLamp", parent, cf, nil, function()
		part(parent, "LampPole", cf * CFrame.new(0, 5, 0), V(0.5, 10, 0.5), C.SteelDark)
		local head = ball(parent, "LampHead", cf * CFrame.new(0, 10.2, 0), 1.4, C.Lamp, { neon = true, collide = false })
		light(head, C.Lamp, 22, 1)
	end)
end

------------------------------------------------------------------------------------------------
-- Animals (static statues for the non-panda enclosures; all face -Z of cf)
------------------------------------------------------------------------------------------------
local function pandaHead(parent: Instance, cf: CFrame, s: number)
	ball(parent, "PandaHead", cf, 6 * s, C.PandaWhite)
	for _, sx in { -1, 1 } do
		ball(parent, "PandaEar", cf * CFrame.new(sx * 2.3 * s, 2.3 * s, 0.4 * s), 2.4 * s, C.PandaBlack)
		part(parent, "EyePatch", cf * CFrame.new(sx * 1.2 * s, 0.35 * s, -2.55 * s) * CFrame.Angles(0, 0, sx * math.rad(-25)), V(1.6, 2.1, 0.8) * s, C.PandaBlack, { collide = false })
	end
	MapKit.googlyEyes(parent, O * cf * CFrame.new(0, 0.45 * s, -3 * s), 1.1 * s, 1.2 * s)
	ball(parent, "PandaNose", cf * CFrame.new(0, -0.7 * s, -2.9 * s), 0.9 * s, C.PandaBlack, { collide = false })
	part(parent, "PandaMouth", cf * CFrame.new(0, -1.35 * s, -2.75 * s), V(1.2, 0.18, 0.3) * s, C.PandaBlack, { collide = false })
end

local function elephant(parent: Instance, cf: CFrame, s: number)
	local m = folder(parent, "Elephant")
	part(m, "Body", cf * CFrame.new(0, 7.6 * s, 0.6 * s), V(7, 6.4, 11) * s, C.Elephant)
	for _, lx in { -2.3, 2.3 } do
		for _, lz in { -3.6, 4.4 } do
			part(m, "Leg", cf * CFrame.new(lx * s, 2.4 * s, lz * s), V(2.4, 4.8, 2.4) * s, C.Elephant)
			part(m, "Toe", cf * CFrame.new(lx * s, 0.35 * s, (lz - 1.1) * s), V(2, 0.7, 0.4) * s, C.White, { collide = false })
		end
	end
	part(m, "Head", cf * CFrame.new(0, 9.4 * s, -6.6 * s), V(5.6, 5.4, 4.4) * s, C.Elephant)
	for _, sx in { -1, 1 } do
		part(m, "Ear", cf * CFrame.new(sx * 3.4 * s, 9.6 * s, -5.6 * s) * CFrame.Angles(0, sx * math.rad(-25), 0), V(0.6, 5.6, 4.6) * s, C.ElephantEar, { collide = false })
		part(m, "Tusk", cf * CFrame.new(sx * 1.4 * s, 7.4 * s, -9.2 * s) * CFrame.Angles(math.rad(-25), 0, 0), V(0.6, 0.6, 2.4) * s, C.White, { collide = false })
	end
	part(m, "Trunk1", cf * CFrame.new(0, 7.2 * s, -9 * s), V(1.8, 3.4, 1.8) * s, C.Elephant, { collide = false })
	part(m, "Trunk2", cf * CFrame.new(0, 4.4 * s, -9.6 * s) * CFrame.Angles(math.rad(12), 0, 0), V(1.4, 3, 1.4) * s, C.Elephant, { collide = false })
	part(m, "TrunkTip", cf * CFrame.new(0, 2.9 * s, -10.6 * s) * CFrame.Angles(math.rad(50), 0, 0), V(1.2, 1.8, 1.2) * s, C.Elephant, { collide = false })
	part(m, "Tail", cf * CFrame.new(0, 7.4 * s, 6.4 * s) * CFrame.Angles(math.rad(15), 0, 0), V(0.4, 3, 0.4) * s, C.Elephant, { collide = false })
	MapKit.googlyEyes(m, O * cf * CFrame.new(0, 10.6 * s, -8.9 * s), 1.3 * s, 1.5 * s)
end

local function giraffe(parent: Instance, cf: CFrame, s: number)
	local m = folder(parent, "Giraffe")
	for _, lx in { -1.3, 1.3 } do
		for _, lz in { -2.4, 2.4 } do
			part(m, "Leg", cf * CFrame.new(lx * s, 4 * s, lz * s), V(0.8, 8, 0.8) * s, C.Giraffe)
			part(m, "Hoof", cf * CFrame.new(lx * s, 0.3 * s, lz * s), V(0.9, 0.6, 0.9) * s, C.GiraffeSpot, { collide = false })
		end
	end
	part(m, "Body", cf * CFrame.new(0, 9.6 * s, 0), V(3.6, 3.4, 7) * s, C.Giraffe)
	for _, sp in { { 1, 9.9, -1.6 }, { 1, 9.2, 1.8 }, { -1, 10, 0.4 }, { -1, 9.1, -2.2 } } do
		part(m, "Spot", cf * CFrame.new(sp[1] * 1.82 * s, sp[2] * s, sp[3] * s), V(0.1, 1.2, 1.5) * s, C.GiraffeSpot, { collide = false })
	end
	-- neck leans forward (toward -Z)
	local base = cf * CFrame.new(0, 11 * s, -3.2 * s) * CFrame.Angles(math.rad(-20), 0, 0)
	part(m, "Neck", base * CFrame.new(0, 5.5 * s, 0), V(1.4, 11, 1.4) * s, C.Giraffe)
	part(m, "NeckSpot", base * CFrame.new(0.71 * s, 4 * s, 0), V(0.1, 1.4, 1) * s, C.GiraffeSpot, { collide = false })
	part(m, "NeckSpot", base * CFrame.new(-0.71 * s, 7.4 * s, 0), V(0.1, 1.4, 1) * s, C.GiraffeSpot, { collide = false })
	part(m, "Mane", base * CFrame.new(0, 5.5 * s, 0.8 * s), V(0.4, 10, 0.4) * s, C.GiraffeSpot, { collide = false })
	local top = base * CFrame.new(0, 11 * s, 0) * CFrame.Angles(math.rad(20), 0, 0)
	part(m, "Head", top * CFrame.new(0, 0.6 * s, -1.2 * s), V(1.6, 1.6, 3.4) * s, C.Giraffe)
	part(m, "Snout", top * CFrame.new(0, 0.4 * s, -2.9 * s), V(1.3, 1.2, 0.6) * s, C.Peach, { collide = false })
	for _, sx in { -0.5, 0.5 } do
		part(m, "Ossicone", top * CFrame.new(sx * s, 1.9 * s, -0.4 * s), V(0.3, 1, 0.3) * s, C.Giraffe, { collide = false })
		ball(m, "OssiconeTip", top * CFrame.new(sx * s, 2.45 * s, -0.4 * s), 0.5 * s, C.GiraffeSpot, { collide = false })
	end
	MapKit.googlyEyes(m, O * top * CFrame.new(0, 1.45 * s, -2 * s), 0.9 * s, 0.6 * s)
	part(m, "Tail", cf * CFrame.new(0, 8.6 * s, 3.6 * s), V(0.3, 3.6, 0.3) * s, C.Giraffe, { collide = false })
end

local function flamingo(parent: Instance, cf: CFrame, oneLeg: boolean)
	local m = folder(parent, "Flamingo")
	part(m, "LegL", cf * CFrame.new(-0.3, 2, 0), V(0.2, 4, 0.2), C.Pink, { collide = false })
	if oneLeg then
		part(m, "LegR", cf * CFrame.new(0.3, 3.3, 0.4) * CFrame.Angles(math.rad(60), 0, 0), V(0.2, 2, 0.2), C.Pink, { collide = false })
	else
		part(m, "LegR", cf * CFrame.new(0.3, 2, 0), V(0.2, 4, 0.2), C.Pink, { collide = false })
	end
	part(m, "Body", cf * CFrame.new(0, 4.6, 0.2), V(1.8, 1.5, 3), C.Pink, { collide = false })
	part(m, "Neck", cf * CFrame.new(0, 6.3, -1.1) * CFrame.Angles(math.rad(-12), 0, 0), V(0.35, 3, 0.35), C.Pink, { collide = false })
	part(m, "Head", cf * CFrame.new(0, 7.9, -1.5), V(0.8, 0.8, 1.1), C.Pink, { collide = false })
	part(m, "Beak", cf * CFrame.new(0, 7.6, -2.3) * CFrame.Angles(math.rad(30), 0, 0), V(0.3, 0.3, 0.9), C.Ink, { collide = false })
end

local function bambooStalk(parent: Instance, x: number, z: number, h: number, flam: boolean): Part
	local opts = { flammable = flam, fuel = 15 }
	local h1 = h * 0.55
	local lower = cyl(parent, "Bamboo", CFrame.new(x, 0.3 + h1 / 2, z), "y", h1, 0.7, C.Bamboo, opts)
	cyl(parent, "Bamboo", CFrame.new(x, 0.3 + h1 + (h - h1) / 2, z), "y", h - h1, 0.6, C.BambooDark, opts)
	cyl(parent, "BambooNode", CFrame.new(x, 0.3 + h1, z), "y", 0.25, 0.85, C.Mustard, { collide = false })
	ball(parent, "BambooLeaves", CFrame.new(x + 0.6, 0.3 + h + 0.4, z - 0.4), 3, C.Leaf, { collide = false })
	return lower
end

local function bambooCluster(parent: Instance, x: number, z: number, rng: Random): Part
	local first: Part? = nil
	for k = 0, 6 do
		local a = k * 2.4 + rng:NextNumber(0, 0.8)
		local r = if k == 0 then 0 else rng:NextNumber(1.2, 3.2)
		local stalk = bambooStalk(parent, x + math.cos(a) * r, z + math.sin(a) * r, rng:NextInteger(10, 17), true)
		first = first or stalk
	end
	return first :: Part
end

local function boulder(parent: Instance, x: number, z: number, d: number, color: Color3?)
	ball(parent, "Boulder", CFrame.new(x, d * 0.3, z), d, color or C.Stone)
end

------------------------------------------------------------------------------------------------
-- Panda enclosure (the star): X -150..-60, Z -40..60
------------------------------------------------------------------------------------------------
local function pandaEnclosure(model: Model, rng: Random)
	local m = folder(model, "PandaEnclosure")
	local bid = "Zoo.Panda"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	local x0, x1, z0, z1 = -150, -60, -40, 60
	part(m, "Ground", CFrame.new((x0 + x1) / 2, 0.15, (z0 + z1) / 2), V(x1 - x0, 0.3, z1 - z0), C.Lush)
	-- stone wall all round (3 high); gap on the east wall for the keeper door at Z 38..42
	local wopt = { material = Enum.Material.Cobblestone }
	wallRun(m, "StoneWall", V(x0, 0, z0), V(x1, 0, z0), 3, C.Stone, wopt, 2)
	wallRun(m, "StoneWall", V(x0, 0, z1), V(x1, 0, z1), 3, C.Stone, wopt, 2)
	wallRun(m, "StoneWall", V(x0, 0, z0), V(x0, 0, z1), 3, C.Stone, wopt, 2)
	wallRun(m, "StoneWall", V(x1, 0, z0), V(x1, 0, 38), 3, C.Stone, wopt, 2)
	wallRun(m, "StoneWall", V(x1, 0, 42), V(x1, 0, z1), 3, C.Stone, wopt, 2)
	-- bamboo fence on three sides: poles every 3 studs + two rails
	local function bambooFence(a: Vector3, b: Vector3)
		local d = b - a
		local n = math.floor(d.Magnitude / 3)
		for k = 0, n do
			local p = a + d * (k / n)
			cyl(m, "FencePole", CFrame.new(p.X, 3 + 3, p.Z), "y", 6, 0.6, if k % 3 == 0 then C.BambooDark else C.Bamboo)
		end
		bar(m, "FenceRail", a + V(0, 5, 0), b + V(0, 5, 0), 0.35, C.Thatch, { collide = false })
		bar(m, "FenceRail", a + V(0, 7.6, 0), b + V(0, 7.6, 0), 0.35, C.Thatch, { collide = false })
	end
	bambooFence(V(x0, 0, z0), V(x1, 0, z0))
	bambooFence(V(x0, 0, z1), V(x1, 0, z1))
	bambooFence(V(x0, 0, z0), V(x0, 0, z1))
	-- east (viewing) side: glass panels above the wall, the keeper door at Z 40
	for _, seg in { { z0, 38 }, { 42, z1 } } do
		local len = seg[2] - seg[1]
		local n = math.max(1, math.ceil(len / 12))
		for k = 1, n do
			local zc = seg[1] + (k - 0.5) * len / n
			part(m, "ViewGlass", CFrame.new(x1, 6, zc), V(0.4, 6, len / n - 0.4), C.Glass, { material = Enum.Material.Glass, transparency = 0.6 })
			part(m, "GlassPost", CFrame.new(x1, 6, seg[1] + k * len / n), V(0.8, 6, 0.8), C.TealDark)
		end
		part(m, "GlassCap", CFrame.new(x1, 9.2, (seg[1] + seg[2]) / 2), V(1, 0.4, len), C.TealDark)
	end
	local door = MapKit.door(m, "KeeperDoor", O * CFrame.new(x1, 3.5, 40) * CFrame.Angles(0, math.pi / 2, 0), true)
	door:SetAttribute(Names.Attr.BuildingId, bid)
	door.Color = C.WoodLight
	part(m, "DoorLintel", CFrame.new(x1, 8, 40), V(1.2, 2, 6), C.TealDark)
	local keep = sign(m, "KeeperSign", facing(x1 + 0.9, 8, 40, 1, 0), 4.6, 1.4, C.Mustard, "KEEPERS ONLY", C.Ink)
	keep:SetAttribute("Note", "the axe is a key, technically")

	-- hut (flammable wood, open front toward the visitors), Z3 fire + R3 zookeeper inside
	local hut = folder(m, "PandaHut")
	hut:SetAttribute(Names.Attr.BuildingId, bid)
	local hx0, hx1, hz0, hz1, hh = -140, -124, 0, 16, 8
	local hopt = { flammable = true, fuel = 30 }
	for i = 0, 1 do
		for j = 0, 1 do
			part(hut, "HutFloor", CFrame.new(hx0 + (i + 0.5) * 8, 0.45, hz0 + (j + 0.5) * 8), V(8, 0.3, 8), C.Straw, { flammable = true, fuel = 15 })
		end
	end
	local back = wallRun(hut, "HutWall", V(hx0, 0.3, hz0), V(hx0, 0.3, hz1), hh, C.WoodLight, hopt)
	wallRun(hut, "HutWall", V(hx0, 0.3, hz0), V(hx1, 0.3, hz0), hh, C.WoodLight, hopt)
	wallRun(hut, "HutWall", V(hx0, 0.3, hz1), V(hx1, 0.3, hz1), hh, C.WoodLight, hopt)
	wallRun(hut, "HutWall", V(hx1, 0.3, hz0), V(hx1, 0.3, hz0 + 4), hh, C.WoodLight, hopt)
	wallRun(hut, "HutWall", V(hx1, 0.3, hz1 - 4), V(hx1, 0.3, hz1), hh, C.WoodLight, hopt)
	wallRun(hut, "HutWall", V(hx1, 0.3 + 6.5, hz0 + 4), V(hx1, 0.3 + 6.5, hz1 - 4), hh - 6.5, C.WoodLight, hopt)
	fireStart(back[1], "Z3", bid)
	for _, side in { -1, 1 } do
		-- thatch roof: two wedges, ridge along Z over the hut centre
		local cx = (hx0 + hx1) / 2 + side * 4.5
		for k = 0, 2 do
			local zc = hz0 - 1 + (k + 0.5) * (hz1 - hz0 + 2) / 3
			wedge(hut, "Thatch", CFrame.new(cx, 0.3 + hh + 2, zc) * CFrame.Angles(0, -side * math.pi / 2, 0), V((hz1 - hz0 + 2) / 3, 4, 9), C.Thatch, true)
		end
	end
	sign(hut, "HutSign", facing(hx1 + 0.4, 7.6, (hz0 + hz1) / 2, 1, 0), 6, 1.4, C.Cream, "MEI MEI", C.Ink)
	cyl(hut, "FoodBowl", CFrame.new(-128, 0.8, 4), "y", 0.6, 2, C.Red)
	rescueSpawn(hut, "R3", "Civilian", bid, facing(-134, 0.6, 9, 1, 0), "sitting")

	-- bamboo grove, pond, boulders, climbing deck
	for i, c in { { -142, -30 }, { -118, -30 }, { -144, 42 }, { -120, 50 }, { -78, 50 }, { -96, -10 }, { -144, 22 }, { -144, -10 }, { -130, 30 }, { -98, 52 } } do
		local stalk = bambooCluster(m, c[1], c[2], rng)
		if i == 6 then
			fireStart(stalk, "Z2", bid) -- the grove next to the panda: "the bamboo is burning"
		end
	end
	disc(m, "Pond", -80, 0.35, -22, 18, 0.2, C.Water, { material = Enum.Material.Glass, transparency = 0.2 })
	disc(m, "PondRim", -80, 0.3, -22, 20, 0.2, C.StoneDark)
	for k = 0, 5 do
		local a = k * math.pi / 3
		boulder(m, -80 + math.cos(a) * 10, -22 + math.sin(a) * 10, 2 + (k % 2), C.StoneDark)
	end
	boulder(m, -110, 28, 6)
	boulder(m, -106, 31, 4, C.StoneDark)
	boulder(m, -135, -10, 5)
	local deckTop = 6
	for _, o in { { -4.5, 27.5 }, { 4.5, 27.5 }, { -4.5, 36.5 }, { 4.5, 36.5 } } do
		part(m, "DeckPost", CFrame.new(-100 + o[1], deckTop / 2, o[2]), V(1, deckTop, 1), C.Wood)
	end
	part(m, "ClimbDeck", CFrame.new(-100, deckTop - 0.5, 32), V(10, 1, 10), C.WoodLight)
	wedge(m, "ClimbRamp", CFrame.new(-100, (deckTop - 0.2) / 2 + 0.2, 22), V(4, deckTop - 0.2, 10), C.WoodLight)
	cyl(m, "Tyre", CFrame.new(-102, deckTop + 0.4, 34), "y", 0.8, 3, C.Ink)
	-- the panda itself is spawned by RescueService here; a snack bundle beside it
	rescueSpawn(m, "R1", "Panda", bid, facing(-104, 0.3, 4, 1, 0), "sitting")
	for k = 0, 2 do
		cyl(m, "BambooSnack", CFrame.new(-101.5, 0.6 + k * 0.4, 7 + k * 0.3) * CFrame.Angles(0, math.rad(20 + k * 25), 0), "z", 4, 0.5, C.Bamboo, { collide = false })
	end

	-- visitor deck outside the glass + the big sign
	local deck = folder(m, "ViewingDeck")
	part(deck, "Deck", CFrame.new(-53, 0.6, 10), V(12, 1.2, 40), C.WoodLight)
	for _, z in { -10, 30 } do
		part(deck, "DeckRail", CFrame.new(-53, 2.6, z), V(12, 0.4, 0.4), C.Wood, { collide = false })
		for _, x in { -58.6, -47.4 } do
			part(deck, "RailPost", CFrame.new(x, 2.2, z), V(0.5, 2.4, 0.5), C.Wood)
		end
	end
	for _, z in { -6, 26 } do
		part(deck, "SignLeg", CFrame.new(-57.4, 6.5, z), V(0.6, 11, 0.6), C.TealDark)
	end
	sign(deck, "PandaSign", facing(-57.2, 12, 10, 1, 0), 30, 4, C.Mustard, "GIANT PANDA", C.Ink, C.Cream)
	pandaHead(deck, facing(-57.6, 17.4, 10, 1, 0), 0.6)
	for _, z in { -2, 22 } do
		prop("bench", deck, facing(-50, 1.2, z, -1, 0), { length = 8 })
	end
end

-- Stone wall (3 high) + steel rail fence around an axis-aligned rectangle.
local function railFence(m: Instance, x0: number, x1: number, z0: number, z1: number)
	local wopt = { material = Enum.Material.Cobblestone }
	for _, w in { { V(x0, 0, z0), V(x1, 0, z0) }, { V(x0, 0, z1), V(x1, 0, z1) }, { V(x0, 0, z0), V(x0, 0, z1) }, { V(x1, 0, z0), V(x1, 0, z1) } } do
		wallRun(m, "StoneWall", w[1], w[2], 3, C.Stone, wopt, 2)
		local d = w[2] - w[1]
		local n = math.ceil(d.Magnitude / 10)
		for k = 0, n do
			local p = w[1] + d * (k / n)
			part(m, "RailPost", CFrame.new(p.X, 5.5, p.Z), V(0.6, 5, 0.6), C.SteelDark)
		end
		bar(m, "Rail", w[1] + V(0, 6, 0), w[2] + V(0, 6, 0), 0.4, C.Steel, { collide = false })
		bar(m, "Rail", w[1] + V(0, 7.8, 0), w[2] + V(0, 7.8, 0), 0.4, C.Steel, { collide = false })
	end
end

local function penguin(parent: Instance, cf: CFrame)
	local m = folder(parent, "Penguin")
	part(m, "Body", cf * CFrame.new(0, 1.5, 0), V(1.6, 2.4, 1.4), C.PandaBlack)
	part(m, "Belly", cf * CFrame.new(0, 1.4, -0.71), V(1.2, 1.9, 0.1), C.White, { collide = false })
	ball(m, "Head", cf * CFrame.new(0, 3.2, 0), 1.4, C.PandaBlack, { collide = false })
	part(m, "Beak", cf * CFrame.new(0, 3.1, -0.85), V(0.35, 0.3, 0.6), C.Peach, { collide = false })
	for _, sx in { -0.4, 0.4 } do
		part(m, "Foot", cf * CFrame.new(sx, 0.1, -0.4), V(0.5, 0.2, 0.7), C.Peach, { collide = false })
		part(m, "Flipper", cf * CFrame.new(sx * 2.2, 1.6, 0) * CFrame.Angles(0, 0, sx * math.rad(30)), V(0.25, 1.6, 0.8), C.PandaBlack, { collide = false })
	end
	MapKit.googlyEyes(m, O * cf * CFrame.new(0, 3.45, -0.6), 0.55, 0.32)
end

local function monkey(parent: Instance, cf: CFrame)
	local m = folder(parent, "Monkey")
	local brown, tan = hex("#8A5A3A"), hex("#E0B080")
	ball(m, "Body", cf * CFrame.new(0, 1.2, 0), 2.2, brown, { collide = false })
	ball(m, "Head", cf * CFrame.new(0, 2.9, -0.2), 1.6, brown, { collide = false })
	part(m, "Face", cf * CFrame.new(0, 2.8, -0.85), V(1.1, 0.9, 0.3), tan, { collide = false })
	for _, sx in { -1, 1 } do
		ball(m, "Ear", cf * CFrame.new(sx * 0.85, 3.0, -0.1), 0.6, tan, { collide = false })
		part(m, "Arm", cf * CFrame.new(sx * 1.2, 2.1, -0.2) * CFrame.Angles(0, 0, sx * math.rad(-140)), V(0.4, 1.8, 0.4), brown, { collide = false })
	end
	part(m, "Tail", cf * CFrame.new(0, 1.6, 1.4) * CFrame.Angles(math.rad(-40), 0, 0), V(0.3, 0.3, 2.4), brown, { collide = false })
	MapKit.googlyEyes(m, O * cf * CFrame.new(0, 3.25, -0.95), 0.5, 0.3)
end

local function palm(parent: Instance, x: number, y: number, z: number)
	local cf = CFrame.new(x, y, z)
	for k = 0, 4 do
		part(parent, "PalmTrunk", cf * CFrame.new(k * 0.35, 1.2 + k * 2.2, 0) * CFrame.Angles(0, 0, math.rad(-8)), V(1.1 - k * 0.08, 2.3, 1.1 - k * 0.08), if k % 2 == 0 then hex("#9A6A3A") else hex("#7A4A2A"))
	end
	local top = cf * CFrame.new(1.8, 11.6, 0)
	for k = 0, 5 do
		part(parent, "PalmLeaf", top * CFrame.Angles(0, k * math.pi / 3, 0) * CFrame.new(0, -0.5, -2.6) * CFrame.Angles(math.rad(-20), 0, 0), V(1.6, 0.2, 5), C.Lush, { collide = false })
	end
	ball(parent, "Coconut", top * CFrame.new(0.4, -0.6, 0.3), 0.8, hex("#5A3A22"), { collide = false })
end

local function northExhibits(model: Model, rng: Random)
	-- link path along Z -62 between the two north exhibits (crosses the main path)
	local paths = folder(model, "NorthPath")
	part(paths, "Path", CFrame.new(0, 0.1, -62), V(220, 0.2, 6), C.Path)

	-- PENGUINS: X 70..150, Z -150..-80
	local pg = folder(model, "PenguinPool")
	pg:SetAttribute(Names.Attr.BuildingId, "Zoo.Penguins")
	part(pg, "Snow", CFrame.new(110, 0.15, -115), V(80, 0.3, 70), hex("#EEF4F6"))
	railFence(pg, 70, 150, -150, -80)
	part(pg, "Pool", CFrame.new(105, 0.35, -112), V(40, 0.2, 28), C.WaterDeep, { material = Enum.Material.Glass, transparency = 0.15 })
	part(pg, "PoolEdge", CFrame.new(105, 0.3, -112), V(42, 0.25, 30), hex("#BFD8D8"))
	for k, b in { { 135, -140, 10, 8 }, { 140, -128, 6, 5 }, { 80, -140, 8, 6 }, { 132, -95, 7, 4 } } do
		part(pg, "Iceberg", CFrame.new(b[1], b[4] / 2, b[2]) * CFrame.Angles(0, math.rad(k * 23), 0), V(b[3], b[4], b[3] * 0.8), if k % 2 == 0 then hex("#DDF3F5") else hex("#BFE4EC"))
	end
	wedge(pg, "IceSlide", CFrame.new(135, 4, -128) * CFrame.Angles(0, math.pi / 2, 0), V(4, 7.6, 14), hex("#BFE4EC"))
	for k = 0, 5 do
		local a = k * 1.1
		penguin(pg, facing(118 + math.cos(a) * 9, 0.3, -96 + math.sin(a) * 3, 0.2 * (k - 2.5), 1))
	end
	for _, z in { -118, -94 } do
		part(pg, "SignLeg", CFrame.new(67.4, 5, z), V(0.6, 10, 0.6), C.TealDark)
	end
	sign(pg, "PenguinSign", facing(67.2, 10, -106, -1, 0), 26, 3.4, hex("#4FB3D9"), "PENGUINS", C.Cream, C.Ink)

	-- MONKEY ISLAND: X -150..-70, Z -150..-80 (moat + island + palm + climbing frame)
	local mk = folder(model, "MonkeyIsland")
	mk:SetAttribute(Names.Attr.BuildingId, "Zoo.Monkeys")
	railFence(mk, -150, -70, -150, -80)
	part(mk, "Moat", CFrame.new(-110, 0.2, -115), V(78, 0.3, 68), C.Water, { material = Enum.Material.Glass, transparency = 0.2 })
	disc(mk, "Island", -110, 0.9, -115, 44, 1.6, C.Lush)
	disc(mk, "Beach", -110, 0.6, -115, 48, 1.1, C.Sand)
	boulder(mk, -120, -125, 7, C.StoneDark)
	boulder(mk, -98, -108, 5)
	palm(mk, -116, 1.7, -108)
	palm(mk, -100, 1.7, -124)
	-- climbing frame
	for _, o in { { -4, -4 }, { 4, -4 }, { -4, 4 }, { 4, 4 } } do
		part(mk, "FramePost", CFrame.new(-110 + o[1], 1.7 + 5, -115 + o[2]), V(0.8, 10, 0.8), C.Wood)
	end
	for _, y in { 5, 9.6 } do
		part(mk, "FrameBeam", CFrame.new(-110, 1.7 + y, -119), V(9, 0.6, 0.6), C.WoodLight)
		part(mk, "FrameBeam", CFrame.new(-110, 1.7 + y, -111), V(9, 0.6, 0.6), C.WoodLight)
	end
	part(mk, "FrameRope", CFrame.new(-110, 1.7 + 6.5, -115), V(0.2, 6, 0.2), C.Straw, { collide = false })
	monkey(mk, facing(-110, 1.7 + 10, -111, 0, 1))
	monkey(mk, facing(-104, 1.7, -112, 0.4, 1))
	monkey(mk, facing(-117, 1.7, -103, -0.3, 1))
	cyl(mk, "Banana", CFrame.new(-103, 2.1, -110) * CFrame.Angles(0, 0.5, 0), "x", 1.4, 0.4, C.Mustard, { collide = false })
	for _, z in { -118, -94 } do
		part(mk, "SignLeg", CFrame.new(-67.4, 5, z), V(0.6, 10, 0.6), C.TealDark)
	end
	sign(mk, "MonkeySign", facing(-67.2, 10, -106, 1, 0), 26, 3.4, C.Terracotta, "MONKEY ISLAND", C.Cream, C.Ink)
	tree(mk, -160, -60, rng)
	tree(mk, 160, -60, rng)
end

------------------------------------------------------------------------------------------------
-- Elephants: X 60..150, Z -40..60
------------------------------------------------------------------------------------------------
local function elephantEnclosure(model: Model, rng: Random)
	local m = folder(model, "ElephantEnclosure")
	m:SetAttribute(Names.Attr.BuildingId, "Zoo.Elephants")
	local x0, x1, z0, z1 = 60, 150, -40, 60
	part(m, "Sand", CFrame.new((x0 + x1) / 2, 0.15, (z0 + z1) / 2), V(x1 - x0, 0.3, z1 - z0), C.Sand)
	railFence(m, x0, x1, z0, z1)
	-- pool, shade shelter, hay feeder, boulders
	part(m, "Pool", CFrame.new(124, 0.35, 34), V(30, 0.2, 20), C.WaterDeep, { material = Enum.Material.Glass, transparency = 0.2 })
	part(m, "PoolRim", CFrame.new(124, 0.3, 34), V(32, 0.25, 22), C.StoneDark)
	for _, o in { { -7, -7 }, { 7, -7 }, { -7, 7 }, { 7, 7 } } do
		part(m, "ShadePost", CFrame.new(130 + o[1], 6, -22 + o[2]), V(1, 12, 1), C.Wood)
	end
	for i = -1, 1 do
		for j = -1, 1 do
			part(m, "ShadeRoof", CFrame.new(130 + i * 6, 12.4, -22 + j * 6), V(6, 0.8, 6), C.Thatch, { flammable = true, fuel = 20 })
		end
	end
	local feeder = part(m, "HayFeeder", CFrame.new(112, 1.6, -28), V(8, 2.6, 4), C.Wood, { flammable = true })
	feeder:SetAttribute("Note", "elephant salad")
	part(m, "Hay", CFrame.new(112, 3.3, -28), V(7.4, 1, 3.4), C.Straw, { flammable = true, fuel = 15 })
	boulder(m, 140, 10, 7)
	boulder(m, 136, 15, 4, C.StoneDark)
	boulder(m, 80, -30, 5)
	-- mum + baby
	elephant(m, facing(98, 0.3, 4, -1, 0), 1)
	elephant(m, facing(108, 0.3, 22, -1, -0.5), 0.55)
	-- sign + viewing rail on the west side
	for _, z in { -2, 22 } do
		part(m, "SignLeg", CFrame.new(57.4, 6.5, z), V(0.6, 11, 0.6), C.TealDark)
	end
	sign(m, "ElephantSign", facing(57.2, 12, 10, -1, 0), 30, 4, C.Teal, "ELEPHANTS", C.Cream, C.Ink)
	tree(m, 145, 52, rng, { size = 1.4 })
	tree(m, 70, 50, rng)
end

------------------------------------------------------------------------------------------------
-- Giraffes: X -50..50, Z -150..-70, + feeding platform at the south fence
------------------------------------------------------------------------------------------------
local function acacia(parent: Instance, x: number, z: number)
	cyl(parent, "AcaciaTrunk", CFrame.new(x, 6, z), "y", 12, 1.6, hex("#7A3A1E"))
	part(parent, "AcaciaBranch", CFrame.new(x + 2, 11, z) * CFrame.Angles(0, 0, math.rad(-40)), V(1, 6, 1), hex("#7A3A1E"))
	part(parent, "AcaciaBranch", CFrame.new(x - 2, 11.5, z) * CFrame.Angles(0, 0, math.rad(35)), V(1, 6, 1), hex("#7A3A1E"))
	disc(parent, "AcaciaCanopy", x, 14.5, z, 18, 2.4, C.Leaf)
	disc(parent, "AcaciaCanopy", x + 1, 16, z - 1, 11, 1.6, C.Lush)
end

local function giraffeEnclosure(model: Model, rng: Random)
	local m = folder(model, "GiraffeEnclosure")
	m:SetAttribute(Names.Attr.BuildingId, "Zoo.Giraffes")
	local x0, x1, z0, z1 = -50, 50, -150, -70
	part(m, "Savanna", CFrame.new(0, 0.15, (z0 + z1) / 2), V(x1 - x0, 0.3, z1 - z0), C.Savanna)
	-- tall wooden fence (the giraffes can't jump anyway)
	for _, w in { { V(x0, 0, z0), V(x1, 0, z0) }, { V(x0, 0, z1), V(x1, 0, z1) }, { V(x0, 0, z0), V(x0, 0, z1) }, { V(x1, 0, z0), V(x1, 0, z1) } } do
		local d = w[2] - w[1]
		local n = math.ceil(d.Magnitude / 8)
		for k = 0, n do
			local p = w[1] + d * (k / n)
			part(m, "FencePost", CFrame.new(p.X, 3.5, p.Z), V(1, 7, 1), C.Wood)
		end
		for _, y in { 2, 4.4, 6.6 } do
			bar(m, "FenceRail", w[1] + V(0, y, 0), w[2] + V(0, y, 0), 0.5, C.WoodLight)
		end
	end
	giraffe(m, facing(-14, 0.3, -108, 0, 1), 1)
	giraffe(m, facing(18, 0.3, -126, 0.3, 1), 0.9)
	giraffe(m, facing(-30, 0.3, -134, 0.6, 1), 0.6)
	acacia(m, -36, -140)
	acacia(m, 32, -96)
	acacia(m, 38, -142)
	boulder(m, 5, -145, 5, C.Stone)
	-- feeding platform: stairs up from the main path to a deck at head height
	local plat = folder(m, "FeedingPlatform")
	local top = 14
	local steps = 14
	for k = 1, steps do
		local h = k * top / steps
		part(plat, "Step", CFrame.new(0, h / 2, -40 - (k - 0.5) * 1.6), V(6, h, 1.6), if k % 2 == 0 then C.WoodLight else C.Wood)
	end
	local zEnd = -40 - steps * 1.6
	part(plat, "PlatformDeck", CFrame.new(0, top - 0.5, zEnd - 4), V(14, 1, 8), C.WoodLight)
	for _, sx in { -6.5, 6.5 } do
		part(plat, "PlatformPost", CFrame.new(sx, (top - 1) / 2, zEnd - 4), V(1, top - 1, 1), C.Wood)
		part(plat, "PlatformRail", CFrame.new(sx, top + 1.5, zEnd - 4), V(0.5, 3, 8), C.Wood, { collide = false })
	end
	part(plat, "PlatformRail", CFrame.new(0, top + 1.5, zEnd - 7.9), V(14, 0.5, 0.5), C.Wood, { collide = false })
	sign(plat, "GiraffeSign", facing(0, top + 4.6, zEnd - 0.4, 0, 1), 14, 2.4, C.Mustard, "FEED THE GIRAFFES", C.Ink)
	part(plat, "SignPost", CFrame.new(0, top + 2.4, zEnd - 0.6), V(0.5, 3, 0.5), C.Wood, { collide = false })
	-- a leafy snack bucket on the deck
	cyl(plat, "Bucket", CFrame.new(4, top + 0.8, zEnd - 6), "y", 1.6, 1.6, C.Teal)
	ball(plat, "Leaves", CFrame.new(4, top + 1.8, zEnd - 6), 1.6, C.Leaf, { collide = false })
end

------------------------------------------------------------------------------------------------
-- Gift shop (the fire), snack kiosk, flamingo pond, fountain plaza
------------------------------------------------------------------------------------------------
local function plush(parent: Instance, cf: CFrame, kind: number)
	if kind == 1 then
		ball(parent, "PandaPlush", cf * CFrame.new(0, 0.6, 0), 1.2, C.PandaWhite, { flammable = true, collide = false })
		for _, sx in { -0.45, 0.45 } do
			ball(parent, "PlushEar", cf * CFrame.new(sx, 1.15, 0), 0.45, C.PandaBlack, { collide = false })
		end
	elseif kind == 2 then
		ball(parent, "Plush", cf * CFrame.new(0, 0.55, 0), 1.1, C.Pink, { flammable = true, collide = false })
	else
		ball(parent, "Plush", cf * CFrame.new(0, 0.55, 0), 1.1, C.Mustard, { flammable = true, collide = false })
	end
end

local function giftShop(model: Model)
	local m = folder(model, "GiftShop")
	local bid = "Zoo.GiftShop"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	local x0, x1, z0, z1, h = 50, 86, 98, 126, 12
	local y0 = 0.6
	part(m, "Foundation", CFrame.new((x0 + x1) / 2, 0.25, (z0 + z1) / 2), V(x1 - x0 + 0.6, 0.5, z1 - z0 + 0.6), C.StoneDark)
	for i = 0, 3 do
		for j = 0, 2 do
			part(m, "Floor", CFrame.new(x0 + 0.5 + (i + 0.5) * 8.75, y0 - 0.1, z0 + 0.5 + (j + 0.5) * 9), V(8.75, 0.2, 9), if (i + j) % 2 == 0 then C.Tile else C.TileB)
		end
	end
	local wopt = { flammable = true, fuel = 35 }
	local siding = C.Peach
	-- back (east) wall: Z2 fire on it
	wallRun(m, "Wall", V(x1, y0, z0), V(x1, y0, z1), h, siding, wopt)
	-- north wall solid
	wallRun(m, "Wall", V(x0, y0, z0), V(x1, y0, z0), h, siding, wopt)
	-- south wall with a big display window X 60..76
	wallRun(m, "Wall", V(x0, y0, z1), V(60, y0, z1), h, siding, wopt)
	wallRun(m, "Wall", V(76, y0, z1), V(x1, y0, z1), h, siding, wopt)
	wallRun(m, "Wall", V(60, y0, z1), V(76, y0, z1), 2.5, siding, wopt)
	wallRun(m, "Wall", V(60, y0 + 9, z1), V(76, y0 + 9, z1), h - 9, siding, wopt)
	local sw = part(m, "DisplayWindow", CFrame.new(68, y0 + 5.75, z1), V(16, 6.5, 0.3), C.Glass, { material = Enum.Material.Glass, transparency = 0.45, tags = { Names.Tag.Window } })
	sw:SetAttribute(Names.Attr.BuildingId, bid)
	-- front (west) wall: door at Z 112 + windows Z 101..108 and 116..123
	local function frontSeg(za: number, zb: number, yb: number, hh: number)
		wallRun(m, "Wall", V(x0, y0 + yb, za), V(x0, y0 + yb, zb), hh, siding, wopt)
	end
	frontSeg(z0, 101, 0, h)
	frontSeg(108, 110, 0, h)
	frontSeg(114, 116, 0, h)
	frontSeg(123, z1, 0, h)
	frontSeg(110, 114, 7, h - 7)
	for _, w in { { 101, 108 }, { 116, 123 } } do
		frontSeg(w[1], w[2], 0, 2.5)
		frontSeg(w[1], w[2], 9, h - 9)
		local win = part(m, "DisplayWindow", CFrame.new(x0, y0 + 5.75, (w[1] + w[2]) / 2), V(0.3, 6.5, w[2] - w[1]), C.Glass, {
			material = Enum.Material.Glass,
			transparency = 0.45,
			tags = { Names.Tag.Window },
		})
		win:SetAttribute(Names.Attr.BuildingId, bid)
	end
	local door = MapKit.door(m, "ShopDoor", O * CFrame.new(x0, y0 + 3.5, 112) * CFrame.Angles(0, math.pi / 2, 0), false)
	door:SetAttribute(Names.Attr.BuildingId, bid)
	door.Color = C.Teal
	-- striped awning over the front, roof, parapet, sign, giant panda head on the roof
	for k = 0, 7 do
		part(m, "Awning", CFrame.new(x0 - 1.6, y0 + 9.6, z0 + 1 + (k + 0.5) * 3.25) * CFrame.Angles(0, 0, math.rad(20)), V(3.4, 0.3, 3.25), if k % 2 == 0 then C.Teal else C.White, { collide = false })
	end
	for i = 0, 4 do
		for j = 0, 3 do
			part(m, "Roof", CFrame.new(x0 - 0.5 + (i + 0.5) * 7.4, y0 + h + 0.5, z0 - 0.5 + (j + 0.5) * 7.25), V(7.4, 1, 7.25), C.Roof, { flammable = true, fuel = 30 })
		end
	end
	part(m, "Parapet", CFrame.new(x0 - 0.3, y0 + h + 1.8, (z0 + z1) / 2), V(0.6, 1.6, z1 - z0 + 1.2), C.Lilac)
	sign(m, "ShopSign", facing(x0 - 0.8, y0 + h + 1.8, (z0 + z1) / 2, -1, 0), 22, 2.2, C.Lilac, "ZOO GIFT SHOP", C.Ink, C.Cream)
	pandaHead(m, facing((x0 + x1) / 2 + 2, y0 + h + 1 + 4.2, (z0 + z1) / 2, -1, 0), 1.3)
	-- interior: shelves of plushies (Z1 fire), counter + cashier (R2), balloon bunch
	local inside = folder(m, "Interior")
	local shelfTop: Part? = nil
	for _, sz in { z0 + 1.6, z1 - 1.6 } do
		for k = 0, 2 do
			local sx = 58 + k * 9
			part(inside, "ShelfBack", CFrame.new(sx, y0 + 3.5, sz + (if sz < 110 then -0.6 else 0.6)), V(8, 7, 0.4), C.WoodLight, { flammable = true, fuel = 25 })
			for r, y in { 1, 3.4, 5.8 } do
				local board = part(inside, "Shelf", CFrame.new(sx, y0 + y, sz), V(8, 0.3, 1.6), C.Wood, { flammable = true, fuel = 25 })
				if k == 1 and r == 2 and sz < 110 then
					shelfTop = board
				end
				for q = 0, 3 do
					plush(inside, CFrame.new(sx - 3 + q * 2, y0 + y + 0.15, sz), (q + r + k) % 3 + 1)
				end
			end
		end
	end
	if shelfTop then
		fireStart(shelfTop, "Z1", bid)
	end
	prop("counter", inside, facing(78, y0, 112, -1, 0), { length = 8, color = C.Teal }, function()
		part(inside, "Counter", CFrame.new(78, y0 + 1.6, 112), V(2.6, 3.2, 8), C.Teal, { flammable = true })
	end)
	part(inside, "Register", CFrame.new(78, y0 + 4.1, 110), V(1.6, 1.2, 1.4), C.SteelDark, { collide = false })
	rescueSpawn(inside, "R2", "Civilian", bid, facing(82, y0, 113, -1, 0), "lying")
	for k, col in { C.Red, C.Mustard, C.Teal, C.Pink } do
		local bx = 56 + (k % 2) * 1.2
		local bz = 112 + math.floor((k - 1) / 2) * 1.2 - 0.6
		ball(inside, "Balloon", CFrame.new(bx, y0 + 8 + k * 0.3, bz), 1.6, col, { collide = false })
		part(inside, "String", CFrame.new(bx, y0 + 4 + k * 0.15, bz), V(0.08, 8, 0.08), C.White, { collide = false })
	end
	local l = part(inside, "CeilingLight", CFrame.new(68, y0 + h - 0.3, 112), V(10, 0.3, 1.2), hex("#FFF4D6"), { neon = true, collide = false })
	light(l, hex("#FFE2B8"), 22, 0.9)
	prop("plant", inside, facing(53, y0, 100, 1, 0))
end

local function kiosk(model: Model)
	local m = folder(model, "SnackKiosk")
	local bid = "Zoo.Kiosk"
	m:SetAttribute(Names.Attr.BuildingId, bid)
	local x0, x1, z0, z1, h = -80, -64, 102, 118, 9
	local y0 = 0.4
	part(m, "KioskFloor", CFrame.new((x0 + x1) / 2, 0.2, (z0 + z1) / 2), V(x1 - x0, 0.4, z1 - z0), C.StoneDark)
	local wopt = { flammable = true, fuel = 30 }
	local back = wallRun(m, "Wall", V(x0, y0, z0), V(x0, y0, z1), h, C.Mustard, wopt)
	fireStart(back[1], "Z4", bid)
	wallRun(m, "Wall", V(x0, y0, z0), V(x1, y0, z0), h, C.Mustard, wopt)
	wallRun(m, "Wall", V(x0, y0, z1), V(x1, y0, z1), h, C.Mustard, wopt)
	-- front: serving hatch Z 104..116 between Y 3.5 and 7
	wallRun(m, "Wall", V(x1, y0, z0), V(x1, y0, z1), 3.5, C.Mustard, wopt)
	wallRun(m, "Wall", V(x1, y0 + 7, z0), V(x1, y0 + 7, z1), h - 7, C.Mustard, wopt)
	wallRun(m, "Wall", V(x1, y0 + 3.5, z0), V(x1, y0 + 3.5, 104), 3.5, C.Mustard, wopt)
	wallRun(m, "Wall", V(x1, y0 + 3.5, 116), V(x1, y0 + 3.5, z1), 3.5, C.Mustard, wopt)
	part(m, "ServingLedge", CFrame.new(x1 + 0.9, y0 + 3.6, 110), V(1.8, 0.3, 12), C.WoodLight, { flammable = true })
	for k = 0, 5 do
		part(m, "Awning", CFrame.new(x1 + 1.8, y0 + 7.8, z0 + 0.5 + (k + 0.5) * 2.5) * CFrame.Angles(0, 0, math.rad(-20)), V(3.6, 0.3, 2.5), if k % 2 == 0 then C.Red else C.White, { collide = false })
	end
	for i = 0, 2 do
		for j = 0, 2 do
			part(m, "Roof", CFrame.new(x0 - 0.5 + (i + 0.5) * 17 / 3, y0 + h + 0.4, z0 - 0.5 + (j + 0.5) * 17 / 3), V(17 / 3, 0.8, 17 / 3), C.Teal, { flammable = true, fuel = 20 })
		end
	end
	-- giant ice-cream cone on the roof
	local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
	cyl(m, "Cone", CFrame.new(cx, y0 + h + 3.3, cz), "y", 5, 2.6, C.Straw)
	cyl(m, "ConeTip", CFrame.new(cx, y0 + h + 1.2, cz), "y", 1.2, 1.4, C.Straw)
	ball(m, "Scoop", CFrame.new(cx, y0 + h + 6.8, cz), 4, C.Pink)
	ball(m, "Scoop", CFrame.new(cx, y0 + h + 9.2, cz), 3.4, C.Cream)
	ball(m, "Cherry", CFrame.new(cx, y0 + h + 11.2, cz), 1, C.Red)
	sign(m, "KioskSign", facing(x1 + 0.4, y0 + h + 1.5, cz, 1, 0), 12, 1.4, C.Cream, "SNACKS", C.Red)
	-- picnic tables with umbrellas
	for _, z in { 98, 124 } do
		local t = CFrame.new(-50, 0.2, z)
		part(m, "PicnicTable", t * CFrame.new(0, 2.4, 0), V(6, 0.4, 3), C.WoodLight)
		for _, sz in { -2.4, 2.4 } do
			part(m, "PicnicBench", t * CFrame.new(0, 1.4, sz), V(6, 0.4, 1.2), C.WoodLight)
		end
		part(m, "PicnicLegs", t * CFrame.new(0, 1.1, 0), V(0.6, 2.2, 3), C.Wood)
		part(m, "UmbrellaPole", t * CFrame.new(0, 4.5, 0), V(0.3, 9, 0.3), C.White, { collide = false })
		cyl(m, "Umbrella", t * CFrame.new(0, 8.6, 0), "y", 0.6, 8, if z < 110 then C.Teal else C.Terracotta, { collide = false })
		ball(m, "UmbrellaTop", t * CFrame.new(0, 9.1, 0), 0.8, C.White, { collide = false })
	end
end

local function flamingoPond(model: Model)
	local m = folder(model, "FlamingoPond")
	local px, pz = 32, 90
	disc(m, "PondRim", px, 0.25, pz, 24, 0.3, C.StoneDark)
	disc(m, "Pond", px, 0.35, pz, 22, 0.2, C.Water, { material = Enum.Material.Glass, transparency = 0.15 })
	for k, f in { { -5, -4, 20 }, { -1, 2, -30 }, { 4, -5, 70 }, { 6, 4, 160 }, { -6, 5, -100 } } do
		flamingo(m, facing(px + f[1], 0.3, pz + f[2], math.sin(math.rad(f[3])), -math.cos(math.rad(f[3]))), k % 2 == 0)
	end
	for k = 0, 7 do
		local a = k * math.pi / 4 + 0.3
		part(m, "Reed", CFrame.new(px + math.cos(a) * 11.6, 1.8, pz + math.sin(a) * 11.6), V(0.3, 3.6, 0.3), C.BambooDark, { collide = false })
	end
	sign(m, "FlamingoSign", facing(px - 13.5, 2.6, pz, -1, 0), 8, 1.2, C.Pink, "FLAMINGOS", C.Ink)
	part(m, "FlamingoSignPost", CFrame.new(px - 13.3, 1.2, pz), V(0.4, 2.4, 0.4), C.Wood, { collide = false })
end

local function plaza(model: Model, rng: Random)
	local m = folder(model, "Paths")
	-- main path, side paths, plaza disc
	part(m, "Path", CFrame.new(0, 0.1, 103), V(10, 0.2, 74), C.Path) -- gate -> plaza (Z 66..140)
	part(m, "Path", CFrame.new(0, 0.1, 3), V(10, 0.2, 126), C.Path) -- plaza -> giraffes (Z -60..66)
	part(m, "Path", CFrame.new(-25.5, 0.1, 10), V(41, 0.2, 10), C.Path) -- west to the panda deck
	part(m, "Path", CFrame.new(27.5, 0.1, 10), V(45, 0.2, 10), C.Path) -- east to the elephants
	part(m, "Path", CFrame.new(27.5, 0.1, 112), V(45, 0.2, 6), C.Path) -- to the gift shop door
	part(m, "Path", CFrame.new(-34.5, 0.1, 110), V(59, 0.2, 6), C.Path) -- to the kiosk
	part(m, "ViewPad", CFrame.new(54, 0.1, 10), V(8, 0.2, 30), C.Path) -- elephant viewing strip
	disc(m, "Plaza", 0, 0.13, 85, 38, 0.26, C.Plaza)
	-- fountain
	disc(m, "FountainBasin", 0, 0.9, 85, 14, 1.6, C.Stone)
	disc(m, "FountainWater", 0, 1.6, 85, 12.4, 0.3, C.Water, { material = Enum.Material.Glass, transparency = 0.15, collide = false })
	cyl(m, "FountainColumn", CFrame.new(0, 3.4, 85), "y", 4, 1.6, C.Stone)
	disc(m, "FountainBowl", 0, 5.6, 85, 5, 0.6, C.Stone)
	ball(m, "Spout", CFrame.new(0, 6.6, 85), 1.6, hex("#A9E3F0"), { transparency = 0.3, collide = false })
	-- direction signpost
	local sp = CFrame.new(9, 0.2, 62)
	part(m, "SignPost", sp * CFrame.new(0, 5, 0), V(0.6, 10, 0.6), C.Wood)
	for k, d in { { "PANDAS", -1, 0, C.Mustard }, { "ELEPHANTS", 1, 0, C.Teal }, { "GIRAFFES", 0, -1, C.Terracotta } } do
		local p = sp * CFrame.new(d[2] * 2.6, 9.6 - k * 1.5, d[3] * 2.6)
		local board = part(m, "Arrow", CFrame.lookAt(p.Position, p.Position + V(d[2], 0, d[3])) * CFrame.Angles(0, math.pi / 2, 0), V(5, 1.2, 0.3), d[4])
		label(board, d[1], C.Ink)
		label(board, d[1], C.Ink, nil, Enum.NormalId.Back)
	end
	-- lamps, benches, bins, trees
	for _, z in { 125, 45, 0, -40 } do
		lamp(m, facing(7, 0.2, z, -1, 0))
	end
	for _, z in { 30, -20 } do
		lamp(m, facing(-7, 0.2, z, 1, 0))
	end
	for _, b in { { -7, 120, 1, 0 }, { 7, 30, -1, 0 }, { -7, -10, 1, 0 }, { 12, 75, -1, 0 }, { -12, 95, 1, 0 } } do
		prop("bench", m, facing(b[1], 0.2, b[2], b[3], b[4]), { length = 6 })
	end
	for _, t in { { -25, 125 }, { 22, 135 }, { -40, 70 }, { 30, 72 }, { -30, 40 }, { 32, 40 }, { -25, -40 }, { 25, -45 }, { -160, 120 }, { 160, 125 }, { -160, -150 }, { 160, -150 }, { 120, -110 }, { -110, -110 }, { -150, 90 }, { 150, 90 } } do
		tree(m, t[1], t[2], rng)
	end
	for _, b in { { -18, 135 }, { 18, 128 }, { -45, 85 }, { 45, 80 }, { -100, 80 }, { 100, 80 } } do
		prop("bush", m, CFrame.new(b[1], 0.1, b[2]), { flammable = false, flowers = true })
	end
end

------------------------------------------------------------------------------------------------
-- Gate, perimeter fence, outside plaza, road
------------------------------------------------------------------------------------------------
local function gate(model: Model)
	local m = folder(model, "Gate")
	for _, sx in { -1, 1 } do
		part(m, "Pillar", CFrame.new(sx * 17, 10, 140), V(6, 20, 6), C.Stone, { material = Enum.Material.Cobblestone })
		part(m, "PillarCap", CFrame.new(sx * 17, 20.6, 140), V(7, 1.2, 7), C.TealDark)
		ball(m, "PillarBall", CFrame.new(sx * 17, 22.4, 140), 2.6, C.Mustard)
		-- iron gates swung open against the fence line
		local hinge = CFrame.new(sx * 14, 0, 140) * CFrame.Angles(0, sx * math.rad(70), 0)
		for k = 0, 6 do
			part(m, "GateBar", hinge * CFrame.new(-sx * (0.6 + k * 1.15), 5, 0), V(0.3, 10, 0.3), C.FenceGreen, { collide = false })
		end
		for _, y in { 1, 9.6 } do
			part(m, "GateRail", hinge * CFrame.new(-sx * 4, y, 0), V(8, 0.4, 0.4), C.FenceGreen, { collide = false })
		end
	end
	part(m, "Arch", CFrame.new(0, 19, 140), V(40, 3, 4), C.Teal)
	sign(m, "ZooSign", facing(0, 19, 142.2, 0, 1), 28, 3.6, C.Mustard, "CITY ZOO", C.Ink, C.Cream)
	pandaHead(m, facing(0, 24.6, 140, 0, 1), 1.25)
	-- ticket booth outside, to the east of the gate
	local tb = CFrame.new(30, 0.15, 150)
	part(m, "Booth", tb * CFrame.new(0, 4, 0), V(6, 8, 6), C.Lilac)
	part(m, "BoothRoof", tb * CFrame.new(0, 8.4, 0), V(7.4, 0.8, 7.4), C.Teal)
	part(m, "BoothWindow", tb * CFrame.new(0, 4.6, 3.02), V(4, 2.4, 0.1), C.Glass, { collide = false })
	sign(m, "TicketSign", facing(0, 0, 0, 0, 1) + V(30, 7, 153.3), 4.6, 1, C.Cream, "TICKETS", C.Red)
	part(m, "Ledge", tb * CFrame.new(0, 3.3, 3.5), V(5, 0.3, 1), C.WoodLight)
end

local function perimeter(model: Model)
	local m = folder(model, "Perimeter")
	local function fence(a: Vector3, b: Vector3)
		local d = b - a
		local n = math.ceil(d.Magnitude / 10)
		for k = 0, n do
			local p = a + d * (k / n)
			part(m, "FencePost", CFrame.new(p.X, 4, p.Z), V(0.8, 8, 0.8), C.FenceGreen)
			ball(m, "PostCap", CFrame.new(p.X, 8.3, p.Z), 1, C.Mustard, { collide = false })
		end
		for _, y in { 1.2, 4, 6.8 } do
			bar(m, "FenceRail", a + V(0, y, 0), b + V(0, y, 0), 0.4, C.FenceGreen)
		end
	end
	fence(V(-170, 0, -170), V(170, 0, -170))
	fence(V(-170, 0, -170), V(-170, 0, 140))
	fence(V(170, 0, -170), V(170, 0, 140))
	fence(V(-170, 0, 140), V(-20, 0, 140))
	fence(V(20, 0, 140), V(170, 0, 140))
end

local function outside(model: Model, rng: Random)
	local m = folder(model, "Outside")
	part(m, "Grass", CFrame.new(0, -1, 0), V(400, 2, 400), C.Grass)
	part(m, "Lawn", CFrame.new(0, 0.05, -15), V(340, 0.1, 310), C.Lawn)
	part(m, "EntrancePlaza", CFrame.new(0, 0.07, 155), V(200, 0.14, 30), C.Plaza)
	part(m, "Road", CFrame.new(0, 0.06, 180), V(400, 0.12, 16), C.Asphalt)
	for x = -196, 196, 10 do
		part(m, "LaneDash", CFrame.new(x, 0.13, 180), V(5, 0.05, 0.5), C.LineYellow, { collide = false })
	end
	for _, c in { { -60, C.Teal }, { -74, C.Red }, { 66, C.Mustard } } do
		prop("car", m, facing(c[1], 0.14, 160, 0, -1), { color = c[2] })
	end
	for _, x in { -90, -40, 50, 90 } do
		lamp(m, facing(x, 0.14, 168, 0, -1))
	end
	for _, x in { -150, -120, 120, 150, 185 } do
		tree(m, x, 196 - (x % 5), rng)
	end
	for _, b in { { -40, 143 }, { -30, 143 }, { 40, 143 }, { 55, 143 } } do
		prop("bush", m, CFrame.new(b[1], 0.1, b[2]), { flammable = false, flowers = true })
	end
	-- hydrants: outside the gate, in the plaza, by the gift shop
	for i, h in { { -26, 0.14, 150 }, { 12, 0.2, 98 }, { 46, 0.2, 128 } } do
		local hy = MapKit.hydrant(m, O * CFrame.new(h[1], h[2], h[3]))
		hy.Name = `H{i}`
		hy:SetAttribute("HydrantId", `H{i}`)
	end
end

------------------------------------------------------------------------------------------------

function ZooBuilder.Build(model: Model, origin: CFrame, rng: Random)
	O = origin
	model:SetAttribute("InteriorOrigin", origin) -- Lib/Map/Interiors/Zoo dresses the panda house + gift shop per run
	local mapDir = script.Parent.Parent
	PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	model:SetAttribute("DisplayName", "City Zoo")

	outside(model, rng)
	perimeter(model)
	gate(model)
	plaza(model, rng)
	pandaEnclosure(model, rng)
	elephantEnclosure(model, rng)
	giraffeEnclosure(model, rng)
	northExhibits(model, rng)
	flamingoPond(model)
	giftShop(model)
	kiosk(model)

	-- truck parks across the entrance plaza facing west; the squad spawns between it and the gate
	marker(model, "TruckSpot", facing(10, 0.14, 161, -1, 0), V(4, 1, 4), T_TRUCKSPOT, { [Names.Attr.LocationId] = "Zoo" })
	marker(model, "PlayerSpawn", facing(0, 0.64, 149, 0, -1), V(16, 1, 6), T_PLAYERSPAWN, { [Names.Attr.LocationId] = "Zoo" })
end

return ZooBuilder
