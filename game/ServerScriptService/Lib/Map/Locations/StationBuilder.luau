-- StationBuilder [owner: G2]. Fire Station 67, the hub (docs/game/05 §2.1, docs/game/02 FireStation kit).
-- Slot 0 at the world origin. Footprint 80 x 60 (X -40..40, Z -30..30), bay doors face +Z (south),
-- a road along Z = 56 runs +X toward the Town slot. Pure function of (origin, rng).
--
-- Layout (local studs):
--   Locker room  X -40..-8 : lockers 01-04 + crew lineup on the north wall, helmet rack, bench with
--                            hose coils, coat hooks, spawn pads s1..s4 (tagged StationSpawn), dog bed.
--                            Glass skylight roof so the room reads from the Studio camera.
--   Apparatus bay X -8..40 : two open roll-up bays (X 3..17, 21..35), truck 67 in bay 2, tool bench
--                            with axe rack, wall hose reels, fire pole, O2 tanks, hydrant H0.
--   Outside               : apron + driveway, road east, sidewalks, street lamps, flagpole, bushes,
--                            trees, lawn sign. "FIRE STATION" sign + "67" medallion on the facade.
-- Alarm lamps are Models named "AlarmLight" under the "AlarmLights" folder; each has a Neon part
-- "Bulb" with a disabled red PointLight for AlarmController to switch on.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local StationBuilder = {}
StationBuilder.Id = "Station"
StationBuilder.Slot = 0

local FLOOR = 0.6 -- station floor top (baseplate top is y=0)
local H = 16 -- wall height above FLOOR
local WALL_T = 1
local LAWN_Y = 0.3
local APRON_Y = 0.5
local ROAD_Y = 0.4
local WALK_Y = 0.7
local ROAD_Z = 56
local ROAD_END_X = 200 -- east edge of slot 0; Town (slot 1) starts here

local hex = Color3.fromHex
local C = {
	Brick = hex("BF4835"),
	BrickTrim = hex("A33C2C"),
	BrickDark = hex("8E3426"),
	Floor = hex("8A7470"),
	LockerFloor = hex("B9A898"),
	Line = hex("E3B23C"),
	Locker = hex("6E6A6E"),
	LockerDoor = hex("5A565B"),
	Trim = hex("F2EDE4"),
	Chrome = hex("D6D8DC"),
	Alarm = hex("FF2A2A"),
	TruckRed = hex("C8232B"),
	HoseYellow = hex("E8B83A"),
	HoseRed = hex("B83A2E"),
	Brass = hex("C89A3C"),
	Lawn = hex("7FAF4A"),
	Asphalt = hex("4A4650"),
	Sidewalk = hex("C9B8A8"),
	Concrete = hex("B5ACA2"),
	Wood = hex("8A4A28"),
	WoodLight = hex("B0804A"),
	Cork = hex("C9A26E"),
	Coat = hex("D9A030"),
	CoatShadow = hex("9A6A30"),
	Lime = hex("E8E25A"),
	Silver = hex("C9CCD0"),
	Helmet = hex("C0301E"),
	Shield = hex("E8C24A"),
	Ink = hex("1A1210"),
	Glass = hex("B4DCF0"),
	Ceiling = hex("D8CCBE"),
	Panel = hex("FFF4D6"),
	PanelLight = hex("FFE2B8"),
	Foliage = hex("5E8F3A"),
	FoliageDark = hex("4A7A32"),
	Trunk = hex("7A3A1E"),
	Cone = hex("F2762E"),
	Cream = hex("FFF1D6"),
	Steel = hex("4A4650"),
	DogBrown = hex("A0643A"),
	Skin = hex("D98A4E"),
}

-- Build-time context (Build is synchronous; set at the top of Build).
local O: CFrame = CFrame.identity

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- Local CFrame at (x,y,z) whose -Z (Front) faces direction (dx, 0, dz).
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

local function box(parent: Instance, name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, color: Color3, opts: { [string]: any }?): Part
	return part(parent, name, CFrame.new(x, y, z), V(sx, sy, sz), color, opts)
end

-- Cylinder: axis "x" | "y" | "z", length along the axis, dia across.
local function cyl(parent: Instance, name: string, cf: CFrame, axis: string, length: number, dia: number, color: Color3, opts: { [string]: any }?): Part
	local rot = if axis == "y" then CFrame.Angles(0, 0, math.pi / 2) elseif axis == "z" then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity
	local o: any = if opts then table.clone(opts) else {}
	o.shape = Enum.PartType.Cylinder
	return part(parent, name, cf * rot, V(length, dia, dia), color, o)
end

local function ball(parent: Instance, name: string, cf: CFrame, dia: number, color: Color3, opts: { [string]: any }?): Part
	local o: any = if opts then table.clone(opts) else {}
	o.shape = Enum.PartType.Ball
	return part(parent, name, cf, Vector3.one * dia, color, o)
end

local function folder(parent: Instance, name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

-- Text on a part face.
local function label(p: BasePart, face: Enum.NormalId, text: string, color: Color3, font: Enum.Font?, stroke: Color3?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 40
	sg.LightInfluence = 0.4
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = text
	t.TextScaled = true
	t.Font = font or Enum.Font.FredokaOne
	t.TextColor3 = color
	if stroke then
		t.TextStrokeColor3 = stroke
		t.TextStrokeTransparency = 0
	end
	t.Parent = sg
	sg.Parent = p
end

-- A flat sign board at (x,y,z) facing (dx,dz), w x h, with text on its front.
local function plate(parent: Instance, name: string, x: number, y: number, z: number, dx: number, dz: number, w: number, h: number, color: Color3, text: string?, textColor: Color3?, font: Enum.Font?, opts: { [string]: any }?): Part
	local p = part(parent, name, facing(x, y, z, dx, dz), V(w, h, 0.4), color, opts)
	if text then
		label(p, Enum.NormalId.Front, text, textColor or C.Ink, font)
	end
	return p
end

type Hole = { a: number, b: number, y0: number, y1: number }

-- Brick wall along the line p0 -> p1 (floor level), `outward` horizontal unit vector, with
-- rectangular openings (a..b along the wall from p0, y0..y1 above FLOOR).
local function wallRun(parent: Instance, name: string, p0: Vector3, p1: Vector3, outward: Vector3, holes: { Hole }, plinth: boolean, cornice: boolean)
	local d = p1 - p0
	local len = d.Magnitude
	local dir = d.Unit
	local n = 0
	local function piece(u0: number, u1: number, y0: number, y1: number)
		if u1 - u0 < 0.05 or y1 - y0 < 0.05 then
			return
		end
		n += 1
		local mid = p0 + dir * ((u0 + u1) / 2)
		local c = V(mid.X, FLOOR + (y0 + y1) / 2, mid.Z)
		part(parent, `{name}{n}`, CFrame.lookAt(c, c + outward), V(u1 - u0, y1 - y0, WALL_T), C.Brick, { material = Enum.Material.Brick })
		if plinth and y0 < 0.01 then
			local top = FLOOR + math.min(2, y1)
			local pc = mid + outward * (WALL_T / 2 + 0.25)
			pc = V(pc.X, top / 2, pc.Z)
			part(parent, `{name}Plinth{n}`, CFrame.lookAt(pc, pc + outward), V(u1 - u0, top, 0.5), C.BrickDark)
		end
	end
	table.sort(holes, function(h1, h2)
		return h1.a < h2.a
	end)
	local u = 0
	for _, hl in holes do
		piece(u, hl.a, 0, H)
		piece(hl.a, hl.b, 0, hl.y0)
		piece(hl.a, hl.b, hl.y1, H)
		u = hl.b
	end
	piece(u, len, 0, H)
	if cornice then
		local mid = p0 + dir * (len / 2)
		local c = V(mid.X, FLOOR + H + 0.3, mid.Z)
		part(parent, `{name}Cornice`, CFrame.lookAt(c, c + outward), V(len + 1.6, 1.4, WALL_T + 0.8), C.BrickDark)
	end
end

-- White-framed window glazed into a wall hole. (x,z) on the wall centre line, yc above FLOOR.
local function windowFrame(parent: Instance, x: number, yc: number, z: number, outward: Vector3, w: number, h: number)
	local m = folder(parent, "Window")
	local c = V(x, FLOOR + yc, z)
	local cf = CFrame.lookAt(c, c + outward)
	part(m, "Glass", cf, V(w, h, 0.4), C.Glass, { material = Enum.Material.Glass, transparency = 0.45 })
	local f = -(WALL_T / 2 + 0.2) -- just proud of the outer face
	part(m, "Top", cf * CFrame.new(0, h / 2 + 0.3, f), V(w + 1.2, 0.6, 0.6), C.Trim)
	part(m, "Sill", cf * CFrame.new(0, -h / 2 - 0.3, f - 0.3), V(w + 1.6, 0.6, 1.2), C.Trim)
	part(m, "L", cf * CFrame.new(-w / 2 - 0.3, 0, f), V(0.6, h, 0.6), C.Trim)
	part(m, "R", cf * CFrame.new(w / 2 + 0.3, 0, f), V(0.6, h, 0.6), C.Trim)
	part(m, "MullionV", cf * CFrame.new(0, 0, f + 0.1), V(0.4, h, 0.4), C.Trim)
	part(m, "MullionH", cf * CFrame.new(0, 0, f + 0.1), V(w, 0.4, 0.4), C.Trim)
end

local function fluoro(parent: Instance, x: number, y: number, z: number, alongZ: boolean?)
	local p = box(parent, "Fluoro", x, y, z, if alongZ then 1.6 else 8, 0.4, if alongZ then 8 else 1.6, C.Panel, { neon = true, collide = false })
	local l = Instance.new("SurfaceLight")
	l.Face = Enum.NormalId.Bottom
	l.Range = 16
	l.Brightness = 1.2
	l.Color = C.PanelLight
	l.Parent = p
end

-- Alarm lamp. Hanging from a ceiling at yBase, or standing on a surface at yBase.
local function alarmLight(parent: Instance, x: number, yBase: number, z: number, hanging: boolean)
	local m = folder(parent, "AlarmLight")
	local s = if hanging then -1 else 1
	cyl(m, "Housing", CFrame.new(x, yBase + s * 0.4, z), "y", 0.8, 2.2, C.Locker)
	local bulb = ball(m, "Bulb", CFrame.new(x, yBase + s * 1.4, z), 1.8, C.Alarm, { neon = true, collide = false })
	cyl(m, "Cage", CFrame.new(x, yBase + s * 1.4, z), "y", 0.4, 2.0, C.Locker, { collide = false })
	local pl = Instance.new("PointLight")
	pl.Name = "AlarmGlow"
	pl.Color = C.Alarm
	pl.Range = 28
	pl.Brightness = 4
	pl.Enabled = false
	pl.Parent = bulb
	m.PrimaryPart = bulb
end

local function hoseCoil(parent: Instance, x: number, yBottom: number, z: number)
	local m = folder(parent, "HoseCoil")
	for i = 0, 2 do
		cyl(m, `Ring{i}`, CFrame.new(x, yBottom + 0.25 + i * 0.5, z), "y", 0.5, 2.4 - i * 0.15, if i % 2 == 0 then C.HoseYellow else C.HoseRed)
	end
	box(m, "Nozzle", x + 1.2, yBottom + 1.5, z, 1.2, 0.4, 0.4, C.Brass)
end

local function helmet(parent: Instance, x: number, yBottom: number, z: number, faceZ: number)
	local m = folder(parent, "Helmet")
	cyl(m, "Brim", CFrame.new(x, yBottom + 0.2, z), "y", 0.4, 2.4, C.Helmet)
	ball(m, "Dome", CFrame.new(x, yBottom + 0.6, z), 1.8, C.Helmet)
	box(m, "Shield", x, yBottom + 1.0, z + faceZ * 0.95, 0.7, 0.8, 0.4, C.Shield)
end

------------------------------------------------------------------ fallbacks (used only if shared modules are missing)

local function fallbackTruck(parent: Instance, cfLocal: CFrame)
	local m = folder(parent, "Truck67")
	local function p(name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, col: Color3, o: any?)
		return part(m, name, cfLocal * CFrame.new(x, y, z), V(sx, sy, sz), col, o)
	end
	p("Body", 0, 4.5, 3, 9, 6, 16, C.TruckRed)
	p("Cab", 0, 4.5, -8.5, 9, 7, 6, C.TruckRed)
	p("Windshield", 0, 6, -11.6, 7.6, 2.6, 0.4, C.Glass, { material = Enum.Material.Glass, transparency = 0.3 })
	p("Stripe", 0, 3.4, -2, 9.2, 0.8, 27.2, C.Trim)
	p("Bumper", 0, 1.6, -11.8, 9.6, 1, 0.8, C.Chrome)
	p("Ladder", 0, 8.1, 3, 3, 0.6, 18, C.Chrome)
	local light = p("Lightbar", 0, 8.3, -8.5, 6, 0.6, 1.2, C.Alarm, { neon = true })
	light.Name = "Lightbar"
	for _, wz in { -8, 4, 9 } do
		for _, sx in { -1, 1 } do
			part(m, "Wheel", cfLocal * CFrame.new(sx * 4.4, 1.6, wz), V(1.4, 3.2, 3.2), C.Ink, { shape = Enum.PartType.Cylinder })
		end
	end
	local num = p("Number", 4.62, 5.5, 3, 0.4, 3, 5, C.TruckRed, { transparency = 1, collide = false })
	label(num, Enum.NormalId.Right, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
end

local function fallbackFirefighter(parent: Instance, cfLocal: CFrame, n: number?)
	local m = folder(parent, "Firefighter")
	local function at(x: number, y: number, z: number)
		return cfLocal * CFrame.new(x, y, z)
	end
	cyl(m, "Legs", at(0, 1, 0), "y", 2, 2, C.CoatShadow)
	cyl(m, "Coat", at(0, 3, 0), "y", 2.4, 2.8, C.Coat)
	cyl(m, "Band", at(0, 2.6, 0), "y", 0.4, 2.9, C.Lime)
	ball(m, "Head", at(0, 5, 0), 2.4, C.Skin)
	cyl(m, "Brim", at(0, 5.9, 0), "y", 0.4, 3, C.Helmet)
	ball(m, "Dome", at(0, 6.1, 0), 2.4, C.Helmet)
	local eyes = folder(m, "Eyes")
	MapKit.googlyEyes(eyes, O * at(0, 5.2, -1.1), 0.9)
	if n then
		local num = part(m, "Number", at(0, 6.6, -1.05), V(1.2, 0.8, 0.4), C.Shield)
		label(num, Enum.NormalId.Front, string.format("%02d", n), C.Ink, Enum.Font.LuckiestGuy)
	end
end

local function fallbackDog(parent: Instance, cfLocal: CFrame)
	local m = folder(parent, "Dog")
	local function at(x: number, y: number, z: number)
		return cfLocal * CFrame.new(x, y, z)
	end
	part(m, "Body", at(0, 1.6, 0), V(1.8, 1.6, 3), C.DogBrown)
	ball(m, "Head", at(0, 2.6, -1.7), 1.8, C.DogBrown)
	part(m, "Snout", at(0, 2.3, -2.6), V(0.8, 0.6, 0.8), C.Ink)
	for _, lx in { -0.6, 0.6 } do
		for _, lz in { -1, 1 } do
			part(m, "Leg", at(lx, 0.4, lz), V(0.5, 0.8, 0.5), C.DogBrown)
		end
	end
	local eyes = folder(m, "Eyes")
	MapKit.googlyEyes(eyes, O * at(0, 3, -2.4), 0.7)
end

local function fallbackTree(parent: Instance, x: number, z: number, rng: Random)
	local m = folder(parent, "Tree")
	local s = 0.8 + rng:NextNumber() * 0.5
	cyl(m, "Trunk", CFrame.new(x, LAWN_Y + 3 * s, z), "y", 6 * s, 1.4 * s, C.Trunk)
	ball(m, "Crown", CFrame.new(x, LAWN_Y + 8 * s, z), 8 * s, if rng:NextNumber() < 0.5 then C.Foliage else C.FoliageDark)
	ball(m, "Crown2", CFrame.new(x + 1.5 * s, LAWN_Y + 10.5 * s, z - 1 * s), 5 * s, C.Foliage)
end

local function fallbackLamp(parent: Instance, x: number, y: number, z: number, armDz: number)
	local m = folder(parent, "StreetLamp")
	cyl(m, "Base", CFrame.new(x, y + 0.4, z), "y", 0.8, 1.4, C.Steel)
	cyl(m, "Pole", CFrame.new(x, y + 6, z), "y", 12, 0.6, C.Steel)
	box(m, "Arm", x, y + 12, z + armDz * 1.5, 0.4, 0.4, 3.4, C.Steel)
	local b = ball(m, "Bulb", CFrame.new(x, y + 11.6, z + armDz * 3), 1.4, C.Panel, { neon = true, collide = false })
	local pl = Instance.new("PointLight")
	pl.Color = C.PanelLight
	pl.Range = 24
	pl.Brightness = 1.5
	pl.Parent = b
end

------------------------------------------------------------------ module loading

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
	warn(`[StationBuilder] {name} unavailable: {if ok then "not a table" else mod}`)
	return nil
end

------------------------------------------------------------------ Build

function StationBuilder.Build(model: Model, origin: CFrame, rng: Random)
	O = origin
	local mapDir = script.Parent.Parent
	local PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	local TruckBuilder = tryRequire(mapDir:FindFirstChild("Props"), "TruckBuilder")
	local libDir = mapDir.Parent
	local NpcBuilder = tryRequire(libDir and libDir:FindFirstChild("Rescue"), "NpcBuilder")

	-- PropKit call with graceful fallback. cfLocal = ground point, facing -Z.
	local function prop(kind: string, parent: Instance, cfLocal: CFrame, opts: { [string]: any }?, fallback: (() -> ())?)
		if PropKit and type(PropKit[kind]) == "function" then
			local ok, err = pcall(PropKit[kind], parent, O * cfLocal, opts)
			if ok then
				return
			end
			warn(`[StationBuilder] PropKit.{kind} failed: {err}`)
		end
		if fallback then
			fallback()
		end
	end

	local function npc(kind: string, parent: Instance, cfLocal: CFrame, opts: { [string]: any }?, fallback: () -> ())
		if NpcBuilder and type(NpcBuilder.Build) == "function" then
			local ok, res = pcall(NpcBuilder.Build, kind, O * cfLocal, opts)
			if ok and typeof(res) == "Instance" then
				res.Parent = parent
				return
			end
			warn(`[StationBuilder] NpcBuilder {kind} failed: {res}`)
		end
		fallback()
	end

	local ground = folder(model, "Ground")
	local building = folder(model, "Building")
	building:SetAttribute(Names.Attr.BuildingId, "Station67")
	local interior = folder(model, "Interior")
	local lights = folder(model, "Lights")
	local alarms = folder(model, "AlarmLights")
	local spawns = folder(model, "Spawns")
	local crew = folder(model, "Crew")
	local outside = folder(model, "Outside")

	------------------------------------------------------------ ground, roads
	-- Lawn lot around the station and a strip south of the road (tops above the y=0 baseplate).
	box(ground, "Lawn", -8, LAWN_Y - 0.5, -6, 144, 1, 100, C.Lawn)
	box(ground, "LawnSouth", -8, LAWN_Y - 0.5, 82, 144, 1, 28, C.Lawn)
	box(ground, "VergeNorth", 132, LAWN_Y - 0.5, 37, 136, 1, 14, C.Lawn)
	box(ground, "VergeSouth", 132, LAWN_Y - 0.5, 79, 136, 1, 22, C.Lawn)
	-- Road (16 wide) from the west end of the lot to the slot edge, heading +X toward Town.
	local roadX0, roadX1 = -80, ROAD_END_X
	box(ground, "Road", (roadX0 + roadX1) / 2, ROAD_Y - 0.5, ROAD_Z, roadX1 - roadX0, 1, 16, C.Asphalt)
	for x = roadX0 + 4, roadX1 - 4, 10 do
		box(ground, "Dash", x, ROAD_Y - 0.15, ROAD_Z, 5, 0.4, 0.6, C.Trim)
	end
	-- Sidewalks (raised kerb). The north one dips to apron height across the driveway.
	box(ground, "WalkNW", -44, WALK_Y - 0.5, 46, 72, 1, 4, C.Sidewalk)
	box(ground, "WalkNE", (44 + roadX1) / 2, WALK_Y - 0.5, 46, roadX1 - 44, 1, 4, C.Sidewalk)
	box(ground, "WalkS", (roadX0 + roadX1) / 2, WALK_Y - 0.5, 66, roadX1 - roadX0, 1, 4, C.Sidewalk)
	-- Apron + driveway in front of the bays, and the front path.
	box(ground, "Apron", 18, APRON_Y - 0.5, 39, 52, 1, 18, C.Concrete)
	box(ground, "Path", -24, APRON_Y - 0.5, 37, 5, 1, 14, C.Concrete)
	for _, lx in { 3, 17, 21, 35 } do
		box(ground, "ApronLine", lx, APRON_Y - 0.15, 37.5, 0.4, 0.4, 15, C.Line)
	end

	------------------------------------------------------------ floor
	box(building, "BayFloor", 16, FLOOR - 0.5, 0, 48, 1, 60, C.Floor)
	box(building, "LockerFloor", -24, FLOOR - 0.5, 0, 32, 1, 60, C.LockerFloor)
	for _, c in { 10, 28 } do
		for _, s in { -7, 7 } do
			box(building, "BayLine", c + s, FLOOR - 0.15, 0.5, 0.4, 0.4, 57, C.Line)
		end
		box(building, "StopLine", c, FLOOR - 0.15, -13, 14, 0.4, 0.6, C.Line)
	end
	local stencil = box(building, "Stencil67", 10, FLOOR - 0.15, 8, 9, 0.4, 7, C.Floor, { transparency = 1, collide = false })
	label(stencil, Enum.NormalId.Top, "67", C.Line, Enum.Font.LuckiestGuy)

	------------------------------------------------------------ walls
	local DOOR_H = 13
	wallRun(building, "WallS", V(-40, 0, 29.5), V(40, 0, 29.5), V(0, 0, 1), {
		{ a = 3, b = 9, y0 = 4, y1 = 10 }, -- window x -37..-31
		{ a = 13, b = 19, y0 = 0, y1 = 9 }, -- front door x -27..-21
		{ a = 24, b = 30, y0 = 4, y1 = 10 }, -- window x -16..-10
		{ a = 43, b = 57, y0 = 0, y1 = DOOR_H }, -- bay 1 x 3..17
		{ a = 61, b = 75, y0 = 0, y1 = DOOR_H }, -- bay 2 x 21..35
	}, true, true)
	wallRun(building, "WallN", V(-40, 0, -29.5), V(40, 0, -29.5), V(0, 0, -1), {}, true, true)
	wallRun(building, "WallW", V(-39.5, 0, -29), V(-39.5, 0, 29), V(-1, 0, 0), {
		{ a = 8, b = 14, y0 = 4, y1 = 10 }, -- z -21..-15
		{ a = 22, b = 28, y0 = 4, y1 = 10 }, -- z -7..-1
		{ a = 38, b = 44, y0 = 4, y1 = 10 }, -- z 9..15
	}, true, true)
	wallRun(building, "WallE", V(39.5, 0, -29), V(39.5, 0, 29), V(1, 0, 0), {
		{ a = 8, b = 14, y0 = 6, y1 = 11 },
		{ a = 20, b = 26, y0 = 6, y1 = 11 },
	}, true, true)
	wallRun(building, "Partition", V(-8, 0, -29), V(-8, 0, 29), V(1, 0, 0), {
		{ a = 31, b = 37, y0 = 0, y1 = 9 }, -- door z 2..8
	}, false, false)

	windowFrame(building, -34, 7, 29.5, V(0, 0, 1), 6, 6)
	windowFrame(building, -13, 7, 29.5, V(0, 0, 1), 6, 6)
	for _, z in { -18, -4, 12 } do
		windowFrame(building, -39.5, 7, z, V(-1, 0, 0), 6, 6)
	end
	for _, z in { -18, -6 } do
		windowFrame(building, 39.5, 8.5, z, V(1, 0, 0), 6, 5)
	end

	-- Corner piers and facade pilasters.
	for _, cx in { -40, 40 } do
		for _, cz in { -30, 30 } do
			box(building, "Corner", cx, (FLOOR + H + 1.2) / 2, cz, 2.4, FLOOR + H + 1.2, 2.4, C.BrickDark)
		end
	end
	for _, px in { -8, 2, 36 } do
		box(building, "Pilaster", px, (FLOOR + H - 0.4) / 2, 30.4, 2, FLOOR + H - 0.4, 0.8, C.BrickTrim, { material = Enum.Material.Brick })
	end
	box(building, "PierPilaster", 19, (FLOOR + DOOR_H) / 2, 30.4, 3, FLOOR + DOOR_H, 0.8, C.BrickTrim, { material = Enum.Material.Brick })

	-- "FIRE STATION" board over the bays.
	local sign = plate(building, "StationSign", 19, FLOOR + 14.4, 30.3, 0, 1, 30, 2.2, C.Trim)
	label(sign, Enum.NormalId.Front, "FIRE STATION", C.TruckRed, Enum.Font.LuckiestGuy, C.Ink)

	-- Roll-up doors, rolled up (open bay): roll housing inside + the door's bottom edge showing.
	for i, c in { 10, 28 } do
		cyl(building, `DoorRoll{i}`, CFrame.new(c, FLOOR + 14.6, 27.6), "x", 14.6, 2.4, C.Locker)
		box(building, `BayDoor{i}`, c, FLOOR + DOOR_H - 0.6, 28.9, 14, 1.2, 0.4, C.Ceiling, { collide = false })
		box(building, `BayDoorEdge{i}`, c, FLOOR + DOOR_H - 1.35, 28.9, 14, 0.4, 0.5, C.TruckRed, { collide = false })
	end

	------------------------------------------------------------ roof
	-- Bay: solid flat roof with a parapet and the raised "67" medallion over the doors.
	box(building, "BayRoof", 16, FLOOR + H + 0.5, 0, 48, 1, 60, C.Ceiling)
	local PT = FLOOR + H + 1 -- parapet base
	box(building, "ParapetS", 16, PT + 1.25, 29.5, 49, 2.5, 1, C.Brick, { material = Enum.Material.Brick })
	box(building, "ParapetN", 16, PT + 1.25, -29.5, 49, 2.5, 1, C.Brick, { material = Enum.Material.Brick })
	box(building, "ParapetE", 39.5, PT + 1.25, 0, 1, 2.5, 58, C.Brick, { material = Enum.Material.Brick })
	box(building, "ParapetW", -7.5, PT + 1.25, 0, 1, 2.5, 58, C.Brick, { material = Enum.Material.Brick })
	box(building, "ParapetCapS", 16, PT + 2.7, 29.5, 49.6, 0.4, 1.6, C.BrickDark)
	box(building, "Gable", 19, PT + 4.5, 29.5, 16, 4, 1, C.Brick, { material = Enum.Material.Brick })
	box(building, "GableCap", 19, PT + 6.7, 29.5, 16.6, 0.4, 1.6, C.BrickDark)
	cyl(building, "MedallionRim", CFrame.new(19, PT + 3.6, 30.1), "z", 0.6, 6.6, C.Shield)
	cyl(building, "Medallion", CFrame.new(19, PT + 3.6, 30.35), "z", 0.6, 5.6, C.TruckRed)
	local med = box(building, "MedallionText", 19, PT + 3.6, 30.8, 4.6, 3.8, 0.4, C.TruckRed, { transparency = 1, collide = false })
	label(med, Enum.NormalId.Back, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	-- Rooftop units.
	for i, p in { V(30, 0, -18), V(4, 0, -20) } do
		box(building, `RoofUnit{i}`, p.X, PT + 1.5, p.Z, 6, 3, 5, C.Silver)
		cyl(building, `RoofFan{i}`, CFrame.new(p.X, PT + 3.1, p.Z), "y", 0.4, 3.6, C.Locker)
	end
	-- Locker room: glass skylight on steel beams (lets the Studio camera see the crew).
	for _, z in { -20, -10, 0, 10, 20 } do
		box(building, "Beam", -23.75, FLOOR + H - 0.5, z, 31.5, 1, 1, C.Steel)
	end
	box(building, "Skylight", -23.75, FLOOR + H + 0.2, 0, 31.5, 0.4, 58, C.Glass, { material = Enum.Material.Glass, transparency = 0.6 })

	------------------------------------------------------------ lights + alarms
	for _, x in { 10, 28 } do
		for _, z in { -16, 0, 16 } do
			fluoro(lights, x, FLOOR + H - 0.2, z)
		end
	end
	for _, x in { -32, -17 } do
		for _, z in { -10, 10 } do
			fluoro(lights, x, FLOOR + H - 1.2, z)
		end
	end
	alarmLight(alarms, 0, FLOOR + H, 0, true) -- the doc's beacon (0,15,0)
	alarmLight(alarms, 20, FLOOR + H, -20, true)
	alarmLight(alarms, -24, FLOOR + H - 1, 0, true)
	alarmLight(alarms, -5.5, PT + 2.9, 29.5, false)
	alarmLight(alarms, 37.5, PT + 2.9, 29.5, false)
	alarmLight(alarms, -24, FLOOR + 11.8, 29.5 + 1.4, false) -- over the front door awning

	------------------------------------------------------------ locker room
	local lockers = folder(interior, "Lockers")
	local lockerX = { -36.4, -33, -29.6, -26.2, -22.8, -19.4 }
	for i, x in lockerX do
		local m = folder(lockers, if i <= 4 then `Locker{i}` else "Locker")
		box(m, "Body", x, FLOOR + 3.75, -28, 3, 7.5, 2, C.Locker)
		box(m, "Door", x, FLOOR + 3.6, -26.8, 2.6, 6.8, 0.4, C.LockerDoor)
		for v = 0, 2 do
			box(m, "Vent", x, FLOOR + 5.6 + v * 0.6, -26.5, 1.6, 0.4, 0.4, C.Ink)
		end
		box(m, "Handle", x + 0.9, FLOOR + 3.6, -26.5, 0.4, 1.2, 0.4, C.Chrome)
		if i <= 4 then
			local np = box(m, "NumberPlate", x, FLOOR + 4.3, -26.5, 1.8, 1.1, 0.4, C.Trim)
			label(np, Enum.NormalId.Back, string.format("%02d", i), C.Ink, Enum.Font.LuckiestGuy)
		end
	end
	plate(interior, "CrewBanner", -28, FLOOR + 10.5, -28.8, 0, 1, 16, 2.6, C.Cream, "CREW OF 67", C.TruckRed, Enum.Font.LuckiestGuy)

	-- Crew lineup in front of their lockers, facing the room.
	for i = 1, 4 do
		local x = lockerX[i]
		local cf = facing(x, FLOOR, -23.5, 0, 1)
		npc("Firefighter", crew, cf, { helmet = i, pose = "stand" }, function()
			fallbackFirefighter(crew, cf, i)
		end)
	end

	-- Helmet rack ("suit up").
	local rack = folder(interior, "HelmetRack")
	for _, sx in { -16.4, -10.6 } do
		box(rack, "Post", sx, FLOOR + 4, -28, 0.6, 8, 2, C.Wood, { flammable = true })
	end
	for s, sy in { 1.6, 4.4, 7.2 } do
		box(rack, `Shelf{s}`, -13.5, FLOOR + sy, -28, 5.2, 0.4, 2, C.WoodLight, { flammable = true })
	end
	for _, sy in { 4.6, 7.4 } do
		for _, hx in { -14.9, -12.1 } do
			helmet(rack, hx, FLOOR + sy, -28, 1)
		end
	end
	for _, hx in { -14.6, -12.4 } do
		cyl(rack, "HoseRoll", CFrame.new(hx, FLOOR + 2.6, -28), "x", 1.4, 1.6, C.HoseYellow)
	end
	plate(rack, "SuitUp", -13.5, FLOOR + 9.2, -28.8, 0, 1, 6, 1.4, C.TruckRed, "SUIT UP", C.Trim, Enum.Font.LuckiestGuy)

	-- Gear bench with hose coils and a spare helmet.
	local bench = folder(interior, "Bench")
	box(bench, "Seat", -28, FLOOR + 1.8, -17, 12, 0.8, 2.2, C.WoodLight, { flammable = true, fuel = 30 })
	for _, lx in { -33, -28, -23 } do
		box(bench, "Leg", lx, FLOOR + 0.7, -17, 0.8, 1.4, 1.8, C.Wood, { flammable = true })
	end
	hoseCoil(bench, -32, FLOOR + 2.2, -17)
	hoseCoil(bench, -24.5, FLOOR + 2.2, -17)
	helmet(bench, -28.6, FLOOR + 2.2, -17, 1)

	-- Coats on hooks (partition wall, locker side).
	local coats = folder(interior, "CoatHooks")
	box(coats, "Rail", -8.8, FLOOR + 7.6, -19.5, 0.6, 0.6, 12, C.Wood)
	for _, z in { -24, -21, -18, -15 } do
		box(coats, "Coat", -9.4, FLOOR + 5.4, z, 0.8, 3.8, 2.4, C.Coat, { collide = false })
		box(coats, "BandLime", -9.45, FLOOR + 4.4, z, 0.9, 0.5, 2.5, C.Lime, { collide = false })
		box(coats, "BandSilver", -9.45, FLOOR + 3.9, z, 0.9, 0.4, 2.5, C.Silver, { collide = false })
	end

	-- Mission whiteboard on the west wall.
	local wb = plate(interior, "MissionBoard", -38.8, FLOOR + 6.5, -11, 1, 0, 7, 4, C.Trim)
	label(wb, Enum.NormalId.Front, "TODAY:\nSAVE THE CAT\n(again)", C.Ink, Enum.Font.FredokaOne)
	box(interior, "BoardFrame", -38.9, FLOOR + 6.5, -11, 0.4, 4.6, 7.6, C.Wood)

	-- Spawn pads s1..s4 (tagged StationSpawn, attribute Helmet = 1..4).
	for i = 1, 4 do
		local x = -31 + (i - 1) * 5
		local pad = box(spawns, `SpawnPad{i}`, x, FLOOR - 0.1, 8, 4, 0.4, 4, C.Line)
		CollectionService:AddTag(pad, Names.Tag.StationSpawn)
		pad:SetAttribute(Names.Attr.Helmet, i)
		local inner = box(spawns, `SpawnPadInner{i}`, x, FLOOR, 8, 3, 0.4, 3, C.TruckRed)
		label(inner, Enum.NormalId.Top, string.format("%02d", i), C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	end

	-- Station dog with its bed and bowl.
	local dogArea = folder(interior, "DogCorner")
	cyl(dogArea, "DogBed", CFrame.new(-35, FLOOR + 0.4, 24), "y", 0.8, 4.6, C.HoseRed)
	cyl(dogArea, "Cushion", CFrame.new(-35, FLOOR + 0.5, 24), "y", 0.8, 3.6, C.Cream)
	cyl(dogArea, "Bowl", CFrame.new(-31, FLOOR + 0.3, 26.5), "y", 0.6, 1.4, hex("4FB3D9"))
	local dogCf = facing(-30.5, FLOOR, 22.5, -0.45, 1)
	npc("Dog", dogArea, dogCf, { pose = "stand" }, function()
		fallbackDog(dogArea, dogCf)
	end)

	------------------------------------------------------------ apparatus bay
	-- Truck 67 in bay 2, nose toward the open door.
	local truckCf = facing(28, FLOOR, 3, 0, 1)
	local truckOk = false
	if TruckBuilder and type(TruckBuilder.Build) == "function" then
		local ok, err = pcall(TruckBuilder.Build, model, O * truckCf)
		truckOk = ok
		if not ok then
			warn(`[StationBuilder] TruckBuilder failed: {err}`)
		end
	end
	if not truckOk then
		fallbackTruck(interior, truckCf)
	end

	-- Tool bench + pegboard + axe rack (north wall, bay 1).
	local tools = folder(interior, "ToolBench")
	box(tools, "Top", 9, FLOOR + 3, -27, 14, 0.8, 3.2, C.WoodLight, { flammable = true, fuel = 30 })
	box(tools, "Cabinet", 9, FLOOR + 1.3, -27.4, 13.2, 2.6, 2.4, C.TruckRed)
	for _, dx in { -4.4, 0, 4.4 } do
		box(tools, "Drawer", 9 + dx, FLOOR + 1.4, -26.1, 3.8, 1.8, 0.4, C.HoseRed)
		box(tools, "Pull", 9 + dx, FLOOR + 1.8, -25.8, 1.4, 0.4, 0.4, C.Chrome)
	end
	plate(tools, "Pegboard", 9, FLOOR + 7, -28.8, 0, 1, 14, 6, C.Cork, nil, nil, nil, { flammable = true })
	plate(tools, "ToolsSign", 9, FLOOR + 10.8, -28.8, 0, 1, 6, 1.4, C.TruckRed, "TOOLS", C.Trim, Enum.Font.LuckiestGuy)
	local axes = folder(tools, "AxeRack")
	for i, ax in { 4.5, 7.5 } do
		box(axes, `Handle{i}`, ax, FLOOR + 7, -28.3, 0.5, 4.4, 0.5, C.Wood)
		box(axes, `Head{i}`, ax + 0.6, FLOOR + 8.8, -28.3, 1.6, 1.1, 0.4, C.TruckRed)
		box(axes, `Edge{i}`, ax + 1.5, FLOOR + 8.8, -28.3, 0.4, 1.3, 0.4, C.Chrome)
		box(axes, `Peg{i}`, ax, FLOOR + 9.6, -28.4, 0.6, 0.4, 0.6, C.Steel)
	end
	-- Hand tools on the pegboard: flashlight and wrench silhouettes.
	box(tools, "Flashlight", 11, FLOOR + 7.4, -28.4, 0.8, 2.6, 0.6, C.Shield)
	box(tools, "FlashlightLens", 11, FLOOR + 8.9, -28.4, 1.1, 0.5, 0.7, C.Panel, { neon = true })
	box(tools, "Wrench", 13.5, FLOOR + 7, -28.4, 0.5, 3.4, 0.4, C.Chrome)
	hoseCoil(tools, 5, FLOOR + 3.4, -26.8)
	hoseCoil(tools, 13, FLOOR + 3.4, -26.8)
	prop("extinguisher", tools, facing(17.4, FLOOR, -27.3, 0, 1), nil, function()
		cyl(tools, "Extinguisher", CFrame.new(17.4, FLOOR + 1.3, -27.3), "y", 2.6, 1.2, C.TruckRed)
		box(tools, "ExtHead", 17.4, FLOOR + 2.8, -27.3, 0.6, 0.6, 0.6, C.Ink)
	end)

	-- Wall hose reels (north wall behind the truck): "hose coils on a red brick wall".
	local reels = folder(interior, "HoseReels")
	for i, rx in { 23.5, 28.5, 33.5 } do
		local m = folder(reels, `HoseReel{i}`)
		local y = FLOOR + 6.2
		cyl(m, "Backplate", CFrame.new(rx, y, -28.8), "z", 0.4, 4.2, C.TruckRed)
		cyl(m, "Coil", CFrame.new(rx, y, -28), "z", 1.4, 3.6, if i == 2 then C.HoseRed else C.HoseYellow)
		cyl(m, "Hub", CFrame.new(rx, y, -27.4), "z", 0.6, 1.4, C.TruckRed)
		box(m, "Nozzle", rx + 1.3, y - 2.4, -27.6, 0.5, 1.6, 0.5, C.Brass)
	end

	-- Oxygen tanks in the NE corner.
	for i = 0, 2 do
		local tz = -27 + i * 1.8
		prop("oxygenTank", interior, facing(37.6, FLOOR, tz, -1, 0), nil, function()
			cyl(interior, "OxygenTank", CFrame.new(37.6, FLOOR + 1.6, tz), "y", 3.2, 1.4, hex("4F9A5A"))
			box(interior, "TankValve", 37.6, FLOOR + 3.4, tz, 0.5, 0.5, 0.5, C.Chrome)
		end)
	end

	-- Fire pole (from the [v2] dorm above), with mat and ceiling hole.
	local pole = folder(interior, "FirePole")
	cyl(pole, "Pole", CFrame.new(-3.5, FLOOR + H / 2, -22), "y", H, 0.8, C.Chrome)
	cyl(pole, "Mat", CFrame.new(-3.5, FLOOR + 0.1, -22), "y", 0.4, 5, C.HoseRed)
	cyl(pole, "MatRing", CFrame.new(-3.5, FLOOR + 0.05, -22), "y", 0.4, 5.8, C.Line)
	cyl(pole, "HoleRing", CFrame.new(-3.5, FLOOR + H - 0.2, -22), "y", 0.4, 4.6, C.Chrome)
	cyl(pole, "Hole", CFrame.new(-3.5, FLOOR + H - 0.25, -22), "y", 0.4, 3.8, C.Ink)

	-- Bay 1 kit: rescue trampoline and traffic cones.
	prop("trampoline", interior, facing(10, FLOOR, -6, 0, 1))
	for i, cx in { 6, 10, 14 } do
		local cz = if i == 2 then 17 else 15
		local cone = folder(interior, "Cone")
		box(cone, "Base", cx, FLOOR + 0.2, cz, 1.8, 0.4, 1.8, C.Cone)
		cyl(cone, "Body", CFrame.new(cx, FLOOR + 1.3, cz), "y", 1.8, 1.0, C.Cone)
		cyl(cone, "Band", CFrame.new(cx, FLOOR + 1.4, cz), "y", 0.4, 1.06, C.Trim)
	end

	-- Hydrant H0 just inside the bay, by the east wall.
	MapKit.hydrant(interior, O * CFrame.new(37, FLOOR, 25))

	------------------------------------------------------------ outside
	-- Front entrance: door frame, awning, wall lamps.
	box(outside, "DoorTop", -24, FLOOR + 9.3, 30.2, 7.2, 0.6, 0.6, C.Trim)
	box(outside, "DoorL", -27.3, FLOOR + 4.5, 30.2, 0.6, 9, 0.6, C.Trim)
	box(outside, "DoorR", -20.7, FLOOR + 4.5, 30.2, 0.6, 9, 0.6, C.Trim)
	part(outside, "Awning", CFrame.new(-24, FLOOR + 10.4, 31.6) * CFrame.Angles(math.rad(12), 0, 0), V(10, 0.5, 3.4), C.TruckRed)
	box(outside, "AwningTrim", -24, FLOOR + 10.0, 33.2, 10, 0.6, 0.4, C.Trim)
	for _, lx in { -29, -19 } do
		box(outside, "SconceBack", lx, FLOOR + 7, 30.2, 0.8, 1.2, 0.4, C.Steel)
		local b = ball(outside, "Sconce", CFrame.new(lx, FLOOR + 7, 30.7), 0.9, C.Panel, { neon = true, collide = false })
		local pl = Instance.new("PointLight")
		pl.Color = C.PanelLight
		pl.Range = 12
		pl.Brightness = 1
		pl.Parent = b
	end

	-- Bollards either side of the bays.
	for _, bx in { 2, 19, 36 } do
		cyl(outside, "Bollard", CFrame.new(bx, APRON_Y + 1.5, 32), "y", 3, 1.2, C.Line)
		cyl(outside, "BollardBand", CFrame.new(bx, APRON_Y + 2.2, 32), "y", 0.5, 1.26, C.Ink)
	end

	-- Flagpole on the front lawn.
	local flag = folder(outside, "Flagpole")
	box(flag, "Base", -35, LAWN_Y + 0.4, 38, 3, 0.8, 3, C.Concrete)
	cyl(flag, "Pole", CFrame.new(-35, LAWN_Y + 0.8 + 14, 38), "y", 28, 0.6, C.Chrome)
	ball(flag, "Finial", CFrame.new(-35, LAWN_Y + 29.4, 38), 1.2, C.Shield)
	local cloth = box(flag, "Flag", -35 + 0.3 + 3.6, LAWN_Y + 26.4, 38, 7.2, 4.4, 0.4, C.TruckRed, { collide = false })
	label(cloth, Enum.NormalId.Back, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	label(cloth, Enum.NormalId.Front, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	box(flag, "FlagStripe", -35 + 0.3 + 3.6, LAWN_Y + 24.45, 38, 7.2, 0.5, 0.45, C.Trim, { collide = false })

	-- Lawn sign by the path.
	box(outside, "SignBase", -14.5, LAWN_Y + 0.8, 40, 9.4, 1.6, 1.8, C.Brick, { material = Enum.Material.Brick })
	plate(outside, "LawnSign", -14.5, LAWN_Y + 3.3, 40, 0, 1, 8.4, 3.2, C.Cream, "STATION 67", C.TruckRed, Enum.Font.LuckiestGuy)
	box(outside, "SignCap", -14.5, LAWN_Y + 5.1, 40, 9.4, 0.5, 1, C.BrickDark)

	-- Bushes along the front and west walls.
	local bushes = folder(outside, "Bushes")
	local bushSpots = {
		V(-38, 0, 32), V(-35, 0, 32.2), V(-32, 0, 32),
		V(-17.5, 0, 32), V(-14, 0, 32.2), V(-10.5, 0, 32),
		V(-42, 0, -22), V(-42, 0, -11), V(-42, 0, 4), V(-42, 0, 20),
	}
	for _, b in bushSpots do
		prop("bush", bushes, facing(b.X, LAWN_Y, b.Z, 0, 1), nil, function()
			local d = 3 + rng:NextNumber() * 0.8
			ball(bushes, "Bush", CFrame.new(b.X, LAWN_Y + d * 0.3, b.Z), d, if rng:NextNumber() < 0.5 then C.Foliage else C.FoliageDark)
		end)
	end

	-- Trees framing the lot.
	local trees = folder(outside, "Trees")
	local treeSpots = {
		V(-62, 0, -40), V(-66, 0, -16), V(-60, 0, 8), V(-68, 0, 30),
		V(-28, 0, -46), V(4, 0, -48), V(34, 0, -45),
		V(54, 0, -30), V(57, 0, -4), V(52, 0, 20),
		V(-62, 0, 84), V(-24, 0, 86), V(18, 0, 82), V(52, 0, 86),
	}
	for _, t in treeSpots do
		local jx = (rng:NextNumber() - 0.5) * 3
		local jz = (rng:NextNumber() - 0.5) * 3
		local yaw = rng:NextNumber() * math.pi * 2
		local cf = CFrame.new(t.X + jx, LAWN_Y, t.Z + jz) * CFrame.Angles(0, yaw, 0)
		prop("tree", trees, cf, nil, function()
			fallbackTree(trees, t.X + jx, t.Z + jz, rng)
		end)
	end

	-- Street lamps every 30 studs along both sidewalks, arms over the road.
	local lamps = folder(outside, "StreetLamps")
	for x = -70, roadX1 - 10, 30 do
		if x < -10 or x > 46 then -- keep the driveway clear
			prop("streetLamp", lamps, facing(x, WALK_Y, 45, 0, 1), nil, function()
				fallbackLamp(lamps, x, WALK_Y, 45, 1)
			end)
		end
		local sx = x + 15
		prop("streetLamp", lamps, facing(sx, WALK_Y, 67, 0, -1), nil, function()
			fallbackLamp(lamps, sx, WALK_Y, 67, -1)
		end)
	end
	-- A second hydrant on the kerb for the driveway.
	MapKit.hydrant(outside, O * CFrame.new(48, WALK_Y, 46))
end

return StationBuilder
