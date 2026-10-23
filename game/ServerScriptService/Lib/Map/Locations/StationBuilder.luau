-- StationBuilder [owner: Station v2]. Fire Station 67, the city firehouse and lobby
-- (docs/game/08-city-dispatch.md "Station v2", docs/game/05 §2.1, docs/game/02 FireStation kit).
-- Pure function of (origin, rng). Placed at CityConfig.StationOrigin when a CityConfig module exists
-- (ReplicatedStorage.Config.CityConfig or ServerScriptService.Lib.Map.CityConfig; CFrame or Vector3),
-- else at the MapService slot origin. The origin CFrame is written to the model as attribute
-- "StationOrigin" (LobbyProps reads it to place the board/pads/bell). Street side = local +Z.
--
-- Footprint (local studs): building X -60..60, Z -40..30, two storeys (24 studs to the roof),
-- hose-drying tower X 60..72, Z -38..-24 (46 tall). Lot X -84..84, Z -60..68; the street kerb is at
-- Z = 68 (CityBuilder's avenue runs along it; standalone, this builder draws its own road there).
--   Apparatus floor X -20..60 : 4 bays, roll-up doors 16 W x 16 H facing +Z, bay centres X -10/10/30/50.
--       TruckBay parts (tag TruckBay, attr Bay 1..4, LocationId "Station"): invisible, CFrame = ground
--       point under the truck centre (Z = 10), LookVector toward the street (truck nose). Bay 1 also has
--       a "TruckSpot" (tag TruckSpot) for the v1 VehicleService lobby truck.
--       Per bay: hanging AlarmLight beacon + AlarmSpeaker (attr Bay = i), "BayIndicator" boxes over the
--       door inside and out (LampRed / LampGreen with a "GO" SurfaceGui, attr Bay), neon "DoorStripe"
--       jamb strips (attr Bay). Painted bay numbers, back-wall "BAY n" plates, tool bench, hose reels,
--       axe rack, O2 tanks, trampoline, door to the hose tower.
--   West wing X -60..-20, ground floor:
--       Locker room (Z -40..6): 4 numbered gear racks on the west wall (part "GearRack", tag GearRack,
--       attr Slot 1..4, Attachments GearPoint_Hand / GearPoint_Back / GearPoint_Head), StationSpawn
--       pads in front of each (attrs Slot + Helmet 1..4), lockers, bench, stairs up, fire pole + Mat.
--       Watch room (X -60..-40, Z 6..30): dispatch desk + monitors, big "DispatchScreen" (SurfaceGui
--       "DispatchGui" > TextLabel "Text"; AlarmController writes DISPATCH on it), city map, front door.
--       Kitchen (X -40..-20, Z 6..30): counters, stove with the chili pot, fridge, table, coffee.
--   Upstairs (floor top F2 = FLOOR + 12): bunk room (4 numbered bunks), lounge, pole hole with rails,
--       interior window over the apparatus floor. The pole runs from the Mat to the upstairs floor
--       ("Pole", LobbyService slides from its top) and on to the roof ("PoleTop").
--   Roof: parapet, "67" medallion, rooftop siren horns (AlarmSpeaker, Bay 0), corner beacons.
--   Outside: apron with bay numbers, plaza for the lobby (LobbyProps puts the board + pads there),
--       "STATION 67" facade sign + lawn sign, flagpole, bollards, lamps, trees, bushes, hydrant.
-- Alarm parts (AlarmController drives them, client-side only):
--   Models "AlarmLight" (attr Bay, 0 = shared) with Neon "Bulb" (disabled PointLight "AlarmGlow"),
--   glass "Dome" and a "Reflector" the client spins. Parts "AlarmSpeaker" (tag StationAlarm, attrs Bay
--   and SoundId = "" -> AudioConfig.Sounds.Siren) each holding a looped Sound "Siren" at volume 0.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local TagAny = Names.Tag :: any
local AttrAny = Names.Attr :: any
local TAG_TRUCK_BAY = TagAny.TruckBay or "TruckBay"
local TAG_GEAR_RACK = TagAny.GearRack or "GearRack"
local TAG_STATION_ALARM = TagAny.StationAlarm or "StationAlarm"
local ATTR_BAY = AttrAny.Bay or "Bay"
local ATTR_SLOT = AttrAny.Slot or "Slot"

local StationBuilder = {}
StationBuilder.Id = "Station"
StationBuilder.Slot = 0

local FLOOR = 0.6 -- ground floor top (baseplate top is y = 0)
local H = 24 -- shell height above FLOOR (two storeys)
local F2 = FLOOR + 12 -- upstairs floor top
local WING_H = 11 -- ground-floor room height in the wing (to the slab underside)
local WALL_T = 1
local LAWN_Y = 0.3
local APRON_Y = 0.5
local ROAD_Y = 0.4
local WALK_Y = 0.7
local KERB_Z = 68
local DOOR_W = 16
local DOOR_H = 16
local BAY_X = { -10, 10, 30, 50 }
local BAY_Z = 10 -- truck centre
local TOWER_H = 46

-- Exported for other builders/tests: local layout numbers.
StationBuilder.Layout = table.freeze({
	BayX = BAY_X,
	BayZ = BAY_Z,
	KerbZ = KERB_Z,
	Floor = FLOOR,
	Upstairs = F2,
})

local hex = Color3.fromHex
local C = {
	Brick = hex("BF4835"),
	BrickTrim = hex("A33C2C"),
	BrickDark = hex("8E3426"),
	Plaster = hex("EFE4D2"),
	PlasterDark = hex("D9CBB4"),
	Floor = hex("8E8A86"),
	LockerFloor = hex("B9A898"),
	Carpet = hex("4F6B8A"),
	TileA = hex("F2EDE4"),
	TileB = hex("C8232B"),
	Wood = hex("8A4A28"),
	WoodLight = hex("B0804A"),
	Line = hex("E3B23C"),
	Locker = hex("6E6A6E"),
	Trim = hex("F2EDE4"),
	Chrome = hex("D6D8DC"),
	Alarm = hex("FF2A2A"),
	AlarmDark = hex("5A1010"),
	GoDark = hex("1F4A22"),
	TruckRed = hex("C8232B"),
	HoseYellow = hex("E8B83A"),
	HoseRed = hex("B83A2E"),
	Brass = hex("C89A3C"),
	Lawn = hex("7FAF4A"),
	Asphalt = hex("4A4650"),
	Sidewalk = hex("C9B8A8"),
	Concrete = hex("B5ACA2"),
	ConcreteDark = hex("9C948A"),
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
	Screen = hex("1B2A3A"),
	ScreenText = hex("7CE0FF"),
	Foliage = hex("5E8F3A"),
	FoliageDark = hex("4A7A32"),
	Trunk = hex("7A3A1E"),
	Cone = hex("F2762E"),
	Cream = hex("FFF1D6"),
	Steel = hex("4A4650"),
	DogBrown = hex("A0643A"),
	Chili = hex("8E1A1F"),
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

-- Axis-aligned box between two corners (x0..x1, y0..y1, z0..z1).
local function span(parent: Instance, name: string, x0: number, x1: number, y0: number, y1: number, z0: number, z1: number, color: Color3, opts: { [string]: any }?): Part?
	if x1 - x0 < 0.05 or y1 - y0 < 0.05 or z1 - z0 < 0.05 then
		return nil
	end
	return box(parent, name, (x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2, x1 - x0, y1 - y0, z1 - z0, color, opts)
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
local function label(p: BasePart, face: Enum.NormalId, text: string, color: Color3, font: Enum.Font?, stroke: Color3?, pps: number?): TextLabel
	local sg = Instance.new("SurfaceGui")
	sg.Face = face
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = pps or 40
	sg.LightInfluence = 0.4
	local t = Instance.new("TextLabel")
	t.Name = "Text"
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
	return t
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
type WallOpts = { plinth: boolean?, cornice: boolean?, height: number?, color: Color3?, material: Enum.Material?, thick: number? }

-- Wall along the line p0 -> p1 (y ignored), `outward` horizontal unit vector, rectangular openings
-- (a..b along the wall from p0, y0..y1 above FLOOR). Openings may share the exact same a..b (stacked
-- windows on two storeys); otherwise their a-ranges must not overlap.
local function wallRun(parent: Instance, name: string, p0: Vector3, p1: Vector3, outward: Vector3, holes: { Hole }, wo: WallOpts?)
	local o: WallOpts = wo or {}
	local height = o.height or H
	local color = o.color or C.Brick
	local mat = o.material or (if o.color then Enum.Material.SmoothPlastic else Enum.Material.Brick)
	local thick = o.thick or WALL_T
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
		part(parent, `{name}{n}`, CFrame.lookAt(c, c + outward), V(u1 - u0, y1 - y0, thick), color, { material = mat })
		if o.plinth and y0 < 0.01 then
			local top = FLOOR + math.min(2, y1)
			local pc = mid + outward * (thick / 2 + 0.25)
			pc = V(pc.X, top / 2, pc.Z)
			part(parent, `{name}Plinth{n}`, CFrame.lookAt(pc, pc + outward), V(u1 - u0, top, 0.5), C.BrickDark)
		end
	end
	-- group openings by identical a..b
	local groups: { { a: number, b: number, ys: { { number } } } } = {}
	for _, hl in holes do
		local g = nil
		for _, gg in groups do
			if gg.a == hl.a and gg.b == hl.b then
				g = gg
				break
			end
		end
		if not g then
			g = { a = hl.a, b = hl.b, ys = {} }
			table.insert(groups, g)
		end
		table.insert(g.ys, { hl.y0, hl.y1 })
	end
	table.sort(groups, function(g1, g2)
		return g1.a < g2.a
	end)
	local u = 0
	for _, g in groups do
		piece(u, g.a, 0, height)
		table.sort(g.ys, function(y1, y2)
			return y1[1] < y2[1]
		end)
		local y = 0
		for _, yy in g.ys do
			piece(g.a, g.b, y, yy[1])
			y = yy[2]
		end
		piece(g.a, g.b, y, height)
		u = g.b
	end
	piece(u, len, 0, height)
	if o.cornice then
		local mid = p0 + dir * (len / 2)
		local c = V(mid.X, FLOOR + height + 0.3, mid.Z)
		part(parent, `{name}Cornice`, CFrame.lookAt(c, c + outward), V(len + 1.6, 1.4, thick + 0.8), C.BrickDark)
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

local function fluoro(parent: Instance, x: number, y: number, z: number, alongZ: boolean?, range: number?)
	local p = box(parent, "Fluoro", x, y, z, if alongZ then 1.6 else 8, 0.4, if alongZ then 8 else 1.6, C.Panel, { neon = true, collide = false })
	p.CastShadow = false
	local l = Instance.new("SurfaceLight")
	l.Face = Enum.NormalId.Bottom
	l.Range = range or 16
	l.Brightness = 1.2
	l.Color = C.PanelLight
	l.Shadows = false
	l.Parent = p
end

-- Spinning alarm beacon. Hanging from a ceiling at yBase, or standing on a surface at yBase.
-- Model "AlarmLight" (attr Bay): Housing, Bulb (Neon, PointLight "AlarmGlow" off), Dome, Reflector.
local function alarmLight(parent: Instance, x: number, yBase: number, z: number, hanging: boolean, bay: number, lamp: boolean?)
	local m = folder(parent, "AlarmLight")
	m:SetAttribute(ATTR_BAY, bay)
	local s = if hanging then -1 else 1
	cyl(m, "Housing", CFrame.new(x, yBase + s * 0.4, z), "y", 0.8, 2.4, C.Locker)
	local bulb = ball(m, "Bulb", CFrame.new(x, yBase + s * 1.5, z), 1.2, C.Alarm, { neon = true, collide = false })
	bulb.CastShadow = false
	ball(m, "Dome", CFrame.new(x, yBase + s * 1.5, z), 2.2, C.Alarm, { material = Enum.Material.Glass, transparency = 0.45, collide = false }).CastShadow = false
	box(m, "Reflector", x + 0.55, yBase + s * 1.5, z, 0.2, 1.0, 0.9, C.Chrome, { collide = false, material = Enum.Material.Metal }).CastShadow = false
	local pl = Instance.new("PointLight")
	pl.Name = "AlarmGlow"
	pl.Color = C.Alarm
	pl.Range = 30
	pl.Brightness = 4
	pl.Shadows = false
	pl.Enabled = false
	pl.Parent = bulb
	bulb:SetAttribute(ATTR_BAY, bay)
	if lamp then
		CollectionService:AddTag(bulb, Names.Tag.AlarmLamp) -- AudioController rings its bell here
	end
	m.PrimaryPart = bulb
end

-- Siren speaker: part "AlarmSpeaker" (tag StationAlarm) whose front (-Z) is the horn mouth.
local function alarmSpeaker(parent: Instance, cf: CFrame, bay: number, maxDist: number, scale: number?)
	local k = scale or 1
	local sp = part(parent, "AlarmSpeaker", cf, V(1.8, 1.8, 1.4) * k, C.Steel)
	cyl(parent, "AlarmSpeakerHorn", cf * CFrame.new(0, 0, -1.0 * k), "z", 0.8 * k, 2.6 * k, C.Chrome, { collide = false })
	cyl(parent, "AlarmSpeakerMouth", cf * CFrame.new(0, 0, -1.42 * k), "z", 0.1, 2.0 * k, C.Ink, { collide = false })
	CollectionService:AddTag(sp, TAG_STATION_ALARM)
	sp:SetAttribute(ATTR_BAY, bay)
	sp:SetAttribute("SoundId", "") -- "" -> AudioConfig.Sounds.Siren (AlarmController)
	local s = Instance.new("Sound")
	s.Name = "Siren"
	s.Looped = true
	s.Volume = 0
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 14 * k
	s.RollOffMaxDistance = maxDist
	s.Parent = sp
	return sp
end

local function hoseCoil(parent: Instance, x: number, yBottom: number, z: number)
	local m = folder(parent, "HoseCoil")
	for i = 0, 2 do
		cyl(m, `Ring{i}`, CFrame.new(x, yBottom + 0.25 + i * 0.5, z), "y", 0.5, 2.4 - i * 0.15, if i % 2 == 0 then C.HoseYellow else C.HoseRed)
	end
	box(m, "Nozzle", x + 1.2, yBottom + 1.5, z, 1.2, 0.4, 0.4, C.Brass)
end

local function helmet(parent: Instance, x: number, yBottom: number, z: number, faceX: number, faceZ: number)
	local m = folder(parent, "Helmet")
	cyl(m, "Brim", CFrame.new(x, yBottom + 0.2, z), "y", 0.4, 2.4, C.Helmet)
	ball(m, "Dome", CFrame.new(x, yBottom + 0.6, z), 1.8, C.Helmet)
	box(m, "Shield", x + faceX * 0.95, yBottom + 1.0, z + faceZ * 0.95, if faceX ~= 0 then 0.4 else 0.7, 0.8, if faceX ~= 0 then 0.7 else 0.4, C.Shield)
end

------------------------------------------------------------------ fallbacks (used only if shared modules are missing)

local function fallbackFirefighter(parent: Instance, cfLocal: CFrame, n: number?)
	local m = folder(parent, "Firefighter")
	local function at(x: number, y: number, z: number)
		return cfLocal * CFrame.new(x, y, z)
	end
	cyl(m, "Legs", at(0, 1, 0), "y", 2, 2, C.CoatShadow)
	cyl(m, "Coat", at(0, 3, 0), "y", 2.4, 2.8, C.Coat)
	cyl(m, "Band", at(0, 2.6, 0), "y", 0.4, 2.9, C.Lime)
	ball(m, "Head", at(0, 5, 0), 2.4, hex("D98A4E"))
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
	local eyes = folder(m, "Eyes")
	MapKit.googlyEyes(eyes, O * at(0, 3, -2.4), 0.7)
end

local function fallbackTree(parent: Instance, x: number, z: number, rng: Random)
	local m = folder(parent, "Tree")
	local s = 0.8 + rng:NextNumber() * 0.5
	cyl(m, "Trunk", CFrame.new(x, LAWN_Y + 3 * s, z), "y", 6 * s, 1.4 * s, C.Trunk)
	ball(m, "Crown", CFrame.new(x, LAWN_Y + 8 * s, z), 8 * s, if rng:NextNumber() < 0.5 then C.Foliage else C.FoliageDark)
end

local function fallbackLamp(parent: Instance, x: number, y: number, z: number, armDz: number)
	local m = folder(parent, "StreetLamp")
	cyl(m, "Pole", CFrame.new(x, y + 6, z), "y", 12, 0.6, C.Steel)
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

-- CityConfig.StationOrigin (CFrame | Vector3 | () -> CFrame), or nil when there is no city.
function StationBuilder.CityOrigin(): CFrame?
	local cfgDir = ReplicatedStorage:FindFirstChild("Config")
	local lib = ServerScriptService:FindFirstChild("Lib")
	local mapDir = lib and lib:FindFirstChild("Map")
	local cfg = tryRequire(cfgDir, "CityConfig") or tryRequire(mapDir, "CityConfig")
	if not cfg then
		return nil
	end
	local so: any = cfg.StationOrigin
	if type(so) == "function" then
		local ok, res = pcall(so)
		so = if ok then res else nil
	end
	if typeof(so) == "CFrame" then
		return so
	elseif typeof(so) == "Vector3" then
		return CFrame.new(so)
	end
	return nil
end

------------------------------------------------------------------ Build

function StationBuilder.Build(model: Model, origin: CFrame, rng: Random)
	local cityOrigin = StationBuilder.CityOrigin()
	O = cityOrigin or origin
	model:SetAttribute("StationOrigin", O)
	local inCity = cityOrigin ~= nil

	local mapDir = script.Parent.Parent
	local PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	local libDir = mapDir.Parent
	local NpcBuilder = tryRequire(libDir and libDir:FindFirstChild("Rescue"), "NpcBuilder")

	-- PropKit call with graceful fallback. cfLocal = ground point, facing -Z.
	local function prop(kind: string, parent: Instance, cfLocal: CFrame, opts: { [string]: any }?, fallback: (() -> ())?)
		if PropKit and type(PropKit[kind]) == "function" then
			local o: any = if opts then table.clone(opts) else {}
			if o.flammable == nil then
				o.flammable = false
			end
			local ok, err = pcall(PropKit[kind], parent, O * cfLocal, o)
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
	local bays = folder(model, "Bays")
	local lockerRoom = folder(model, "LockerRoom")
	local watch = folder(model, "WatchRoom")
	local kitchen = folder(model, "Kitchen")
	local upstairs = folder(model, "Upstairs")
	local apparatus = folder(model, "ApparatusFloor")
	local lights = folder(model, "Lights")
	local alarms = folder(model, "Alarms")
	local spawns = folder(model, "Spawns")
	local tower = folder(model, "HoseTower")
	local roof = folder(model, "Roof")
	local outside = folder(model, "Outside")

	------------------------------------------------------------ ground, apron, street
	span(ground, "Lawn", -84, 84, LAWN_Y - 1, LAWN_Y, -60, KERB_Z - 4, C.Lawn)
	span(ground, "Apron", -22, 62, APRON_Y - 1, APRON_Y, 30, KERB_Z, C.Concrete)
	span(ground, "Plaza", -60, -22, APRON_Y - 1, APRON_Y, 30, KERB_Z - 4, C.ConcreteDark)
	span(ground, "YardBack", 20, 76, APRON_Y - 1, APRON_Y, -56, -40, C.Concrete) -- behind the hall, by the tower
	span(ground, "WalkW", -84, -22, WALK_Y - 1, WALK_Y, KERB_Z - 4, KERB_Z, C.Sidewalk)
	span(ground, "WalkE", 62, 84, WALK_Y - 1, WALK_Y, KERB_Z - 4, KERB_Z, C.Sidewalk)
	-- apron lane lines + bay numbers painted outside each door
	for i, c in BAY_X do
		for _, s in { -8.5, 8.5 } do
			span(ground, "ApronLine", c + s - 0.2, c + s + 0.2, APRON_Y, APRON_Y + 0.05, 31, KERB_Z - 1, C.Line, { collide = false })
		end
		local num = box(ground, `ApronNumber{i}`, c, APRON_Y + 0.03, 44, 8, 0.1, 9, C.Concrete, { transparency = 1, collide = false })
		label(num, Enum.NormalId.Top, tostring(i), C.Line, Enum.Font.LuckiestGuy, nil, 20)
	end
	local keep = box(ground, "KeepClear", 20, APRON_Y + 0.03, 58, 40, 0.1, 5, C.Concrete, { transparency = 1, collide = false })
	label(keep, Enum.NormalId.Top, "KEEP CLEAR - FIRE STATION", C.Trim, Enum.Font.LuckiestGuy, nil, 20)
	if not inCity then
		-- standalone: our own two-lane road along the kerb (CityBuilder draws the avenue otherwise)
		local rx0, rx1 = -120, 200
		span(ground, "Road", rx0, rx1, ROAD_Y - 1, ROAD_Y, KERB_Z, KERB_Z + 24, C.Asphalt)
		for x = rx0 + 4, rx1 - 4, 10 do
			box(ground, "Dash", x, ROAD_Y + 0.02, KERB_Z + 12, 5, 0.1, 0.6, C.Trim, { collide = false })
		end
		span(ground, "WalkS", rx0, rx1, WALK_Y - 1, WALK_Y, KERB_Z + 24, KERB_Z + 28, C.Sidewalk)
		span(ground, "LawnSouth", -84, 84, LAWN_Y - 1, LAWN_Y, KERB_Z + 28, KERB_Z + 48, C.Lawn)
	end

	------------------------------------------------------------ floors
	span(building, "HallFloor", -20, 60, FLOOR - 1, FLOOR, -40, 30, C.Floor)
	span(building, "LockerFloor", -60, -20, FLOOR - 1, FLOOR, -40, 6, C.LockerFloor)
	span(building, "WatchFloor", -60, -40, FLOOR - 1, FLOOR, 6, 30, C.Carpet)
	span(building, "KitchenFloor", -40, -20, FLOOR - 1, FLOOR, 6, 30, C.TileA)
	for ix = 0, 4 do
		for iz = 0, 5 do
			if (ix + iz) % 2 == 0 then
				local x0, z0 = -40 + ix * 4, 6 + iz * 4
				span(kitchen, "Tile", x0, x0 + 4, FLOOR, FLOOR + 0.02, z0, z0 + 4, C.TileB, { collide = false })
			end
		end
	end
	span(building, "TowerFloor", 60, 72, FLOOR - 1, FLOOR, -38, -24, C.Floor)

	------------------------------------------------------------ outer walls
	local function stacked(a: number, b: number, g0: number?, g1: number?): { Hole }
		local out: { Hole } = { { a = a, b = b, y0 = 15, y1 = 21 } }
		if g0 and g1 then
			table.insert(out, { a = a, b = b, y0 = g0, y1 = g1 })
		end
		return out
	end
	local function join(...: { Hole }): { Hole }
		local out: { Hole } = {}
		for _, list in { ... } do
			for _, h in list do
				table.insert(out, h)
			end
		end
		return out
	end

	-- South facade (a = x + 60): wing door + windows on two storeys, then the four bay doors.
	local southHoles = join(stacked(4, 10, 0, 9), stacked(13, 19, 3, 9), stacked(23, 29, 3, 9), stacked(31, 37, 3, 9))
	for _, c in BAY_X do
		table.insert(southHoles, { a = c - DOOR_W / 2 + 60, b = c + DOOR_W / 2 + 60, y0 = 0, y1 = DOOR_H })
	end
	wallRun(building, "WallS", V(-60, 0, 29.5), V(60, 0, 29.5), V(0, 0, 1), southHoles, { plinth = true, cornice = true })
	for _, x in { -44, -34, -26 } do
		windowFrame(building, x, 6, 29.5, V(0, 0, 1), 6, 6)
	end
	for _, x in { -53, -44, -34, -26 } do
		windowFrame(building, x, 18, 29.5, V(0, 0, 1), 6, 6)
	end

	-- North (a = x + 60): upstairs windows, high hall windows, the back door to the yard.
	local northHoles = join(stacked(8, 14), stacked(26, 32))
	for _, a in { 46, 86, 106 } do
		table.insert(northHoles, { a = a, b = a + 6, y0 = 13, y1 = 19 })
	end
	table.insert(northHoles, { a = 74, b = 80, y0 = 0, y1 = 10 })
	wallRun(building, "WallN", V(-60, 0, -39.5), V(60, 0, -39.5), V(0, 0, -1), northHoles, { plinth = true, cornice = true })
	for _, x in { -49, -31 } do
		windowFrame(building, x, 18, -39.5, V(0, 0, -1), 6, 6)
	end
	for _, a in { 46, 86, 106 } do
		windowFrame(building, a - 57, 16, -39.5, V(0, 0, -1), 6, 6)
	end

	-- West (a = z + 39).
	wallRun(building, "WallW", V(-59.5, 0, -39), V(-59.5, 0, 29), V(-1, 0, 0), stacked(50, 56, 3, 9), { plinth = true, cornice = true })
	windowFrame(building, -59.5, 18, 14, V(-1, 0, 0), 6, 6)
	windowFrame(building, -59.5, 6, 14, V(-1, 0, 0), 6, 6)

	-- East (a = z + 39): door into the hose tower, high hall windows.
	wallRun(building, "WallE", V(59.5, 0, -39), V(59.5, 0, 29), V(1, 0, 0), {
		{ a = 6, b = 12, y0 = 0, y1 = 9 },
		{ a = 22, b = 30, y0 = 12, y1 = 19 },
		{ a = 42, b = 50, y0 = 12, y1 = 19 },
	}, { plinth = true, cornice = true })
	windowFrame(building, 59.5, 15.5, -13, V(1, 0, 0), 8, 7)
	windowFrame(building, 59.5, 15.5, 7, V(1, 0, 0), 8, 7)

	-- Corner piers and facade pilasters between the bays.
	for _, cx in { -60, 60 } do
		for _, cz in { -40, 30 } do
			box(building, "Corner", cx, (FLOOR + H + 1.2) / 2, cz, 2.4, FLOOR + H + 1.2, 2.4, C.BrickDark)
		end
	end
	for _, px in { -20, 0, 20, 40 } do
		box(building, "Pilaster", px, (FLOOR + H) / 2, 30.4, 3, FLOOR + H, 0.8, C.BrickTrim, { material = Enum.Material.Brick })
	end
	-- belt course between the storeys on the wing
	span(building, "BeltCourse", -60, -20, F2 - 0.6, F2 + 0.4, 30, 30.8, C.BrickDark)

	------------------------------------------------------------ interior walls
	-- Partition between the wing and the apparatus floor (a = z + 39).
	wallRun(building, "Partition", V(-20, 0, -39), V(-20, 0, 29), V(1, 0, 0), {
		{ a = 15, b = 23, y0 = 0, y1 = 9 }, -- locker room door z -24..-16
		{ a = 55, b = 61, y0 = 0, y1 = 9 }, -- kitchen door z 16..22
		{ a = 30, b = 44, y0 = 15, y1 = 20 }, -- bunk-room window over the hall
	}, { color = C.Plaster })
	box(building, "BunkWindow", -20, FLOOR + 17.5, -2, 0.4, 5, 14, C.Glass, { material = Enum.Material.Glass, transparency = 0.55 })
	wallRun(building, "WallLockerFront", V(-59, 0, 6), V(-20.5, 0, 6), V(0, 0, 1), {
		{ a = 7, b = 12, y0 = 0, y1 = 9 }, -- watch room door x -52..-47
		{ a = 27, b = 32, y0 = 0, y1 = 9 }, -- kitchen door x -32..-27
	}, { height = WING_H, color = C.Plaster })
	wallRun(building, "WallWatchKitchen", V(-40, 0, 6.5), V(-40, 0, 29), V(1, 0, 0), {
		{ a = 1.5, b = 6.5, y0 = 0, y1 = 9 }, -- door z 8..13
	}, { height = WING_H, color = C.Plaster })

	------------------------------------------------------------ upstairs slab (holes: stairs, pole)
	local SLAB0 = F2 - 1
	span(building, "SlabMain", -59, -20.5, SLAB0, F2, -27, 29, C.Ceiling)
	span(building, "SlabPoleW", -59, -28, SLAB0, F2, -33, -27, C.Ceiling)
	span(building, "SlabPoleE", -22, -20.5, SLAB0, F2, -33, -27, C.Ceiling)
	span(building, "SlabStairE", -34, -20.5, SLAB0, F2, -39, -33, C.Ceiling)
	span(upstairs, "BunkCarpet", -59, -20.5, F2, F2 + 0.02, -27, 29, hex("8C5A4A"), { collide = false })

	-- Stairs along the north wall, rising toward +X: 12 steps of 1 x 2 studs.
	local stairs = folder(lockerRoom, "Stairs")
	for i = 1, 12 do
		local x0 = -58 + (i - 1) * 2
		span(stairs, `Step{i}`, x0, x0 + 2, FLOOR, FLOOR + i, -39, -33.5, if i % 2 == 0 then C.WoodLight else C.Wood)
	end
	span(stairs, "Landing", -59, -58, FLOOR, FLOOR + 0.2, -39, -33.5, C.Wood)
	-- railings: along the open side of the flight, and upstairs around the stair hole
	for i = 0, 5 do
		local x = -57 + i * 4
		local yTop = FLOOR + math.min(12, (x + 58) / 2) + 3.5
		box(stairs, "Baluster", x, (FLOOR + yTop) / 2 + 0.5, -33.6, 0.4, yTop - FLOOR - 1, 0.4, C.Steel)
	end
	part(stairs, "Handrail", CFrame.lookAt(V(-46, FLOOR + 3.5 + 6, -33.6), V(-34, FLOOR + 3.5 + 12, -33.6)), V(0.4, 0.4, 27), C.TruckRed)
	span(upstairs, "StairRail", -59, -34, F2 + 3.2, F2 + 3.6, -33.2, -32.8, C.TruckRed)
	for x = -58, -36, 4 do
		span(upstairs, "StairRailPost", x - 0.2, x + 0.2, F2, F2 + 3.2, -33.2, -32.8, C.Steel)
	end

	------------------------------------------------------------ roof
	local RT = FLOOR + H -- roof slab bottom
	span(roof, "RoofSlab", -60, 60, RT, RT + 1, -40, 30, C.Ceiling)
	local PT = RT + 1
	span(roof, "ParapetS", -60.5, 60.5, PT, PT + 2.5, 29, 30.2, C.Brick, { material = Enum.Material.Brick })
	span(roof, "ParapetN", -60.5, 60.5, PT, PT + 2.5, -40.2, -39, C.Brick, { material = Enum.Material.Brick })
	span(roof, "ParapetW", -60.5, -59.5, PT, PT + 2.5, -39, 29, C.Brick, { material = Enum.Material.Brick })
	span(roof, "ParapetE", 59.5, 60.5, PT, PT + 2.5, -39, 29, C.Brick, { material = Enum.Material.Brick })
	span(roof, "ParapetCapS", -61, 61, PT + 2.5, PT + 2.9, 28.8, 30.6, C.BrickDark)
	-- gable + "67" medallion over the bays
	span(roof, "Gable", 8, 32, PT + 2.5, PT + 7.5, 29, 30.2, C.Brick, { material = Enum.Material.Brick })
	span(roof, "GableCap", 7.4, 32.6, PT + 7.5, PT + 7.9, 28.8, 30.6, C.BrickDark)
	cyl(roof, "MedallionRim", CFrame.new(20, PT + 5, 30.3), "z", 0.6, 7.2, C.Shield)
	cyl(roof, "Medallion", CFrame.new(20, PT + 5, 30.55), "z", 0.6, 6.2, C.TruckRed)
	local med = box(roof, "MedallionText", 20, PT + 5, 31, 5, 4.2, 0.4, C.TruckRed, { transparency = 1, collide = false })
	label(med, Enum.NormalId.Back, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	-- rooftop units
	for i, p in { V(-44, 0, -20), V(-30, 0, 10), V(44, 0, -26) } do
		box(roof, `RoofUnit{i}`, p.X, PT + 1.5, p.Z, 7, 3, 5, C.Silver)
		cyl(roof, `RoofFan{i}`, CFrame.new(p.X, PT + 3.1, p.Z), "y", 0.4, 3.8, C.Locker)
	end
	-- rooftop siren mast: three horns (the whole neighbourhood hears it)
	local mastX, mastZ = 20, -6
	cyl(roof, "SirenMast", CFrame.new(mastX, PT + 5, mastZ), "y", 10, 0.9, C.Steel)
	box(roof, "SirenMastBase", mastX, PT + 0.4, mastZ, 3, 0.8, 3, C.Steel)
	for _, yaw in { 0, 2 * math.pi / 3, 4 * math.pi / 3 } do
		local dir = V(math.sin(yaw), 0, math.cos(yaw))
		local c = V(mastX, PT + 9.6, mastZ) + dir * 1.8
		alarmSpeaker(roof, CFrame.lookAt(c, c + dir), 0, 600, 1.6)
	end
	-- corner beacons on the roof + one on the gable
	alarmLight(alarms, -58, PT + 2.9, 28.4, false, 0)
	alarmLight(alarms, 58, PT + 2.9, 28.4, false, 0)
	alarmLight(alarms, 20, PT + 7.9, 29.6, false, 0)

	------------------------------------------------------------ STATION 67 signage
	local sign = plate(building, "StationSign", 20, FLOOR + 20.6, 31.0, 0, 1, 64, 4.4, C.Trim)
	label(sign, Enum.NormalId.Front, "FIRE STATION 67", C.TruckRed, Enum.Font.LuckiestGuy, C.Ink, 30)
	span(building, "SignTrimTop", -12.5, 52.5, FLOOR + 22.8, FLOOR + 23.3, 30.8, 31.4, C.TruckRed)
	span(building, "SignTrimBottom", -12.5, 52.5, FLOOR + 17.9, FLOOR + 18.4, 30.8, 31.4, C.TruckRed)
	local wingSign = plate(building, "WingSign", -37, FLOOR + 12, 31.0, 0, 1, 26, 1.6, C.TruckRed)
	label(wingSign, Enum.NormalId.Front, "STATION 67 - EST. 1967 - MOSTLY FIREPROOF", C.Trim, Enum.Font.FredokaOne)
	-- vertical blade sign at the wing corner
	local blade = part(building, "BladeSign", facing(-61.2, FLOOR + 16, 26, -1, 0), V(0.6, 12, 3), C.TruckRed)
	label(blade, Enum.NormalId.Left, "S\nT\nA\nT\nI\nO\nN", C.Trim, Enum.Font.LuckiestGuy)
	label(blade, Enum.NormalId.Right, "S\nT\nA\nT\nI\nO\nN", C.Trim, Enum.Font.LuckiestGuy)

	------------------------------------------------------------ apparatus floor: 4 bays
	for i, c in BAY_X do
		local bay = folder(bays, `Bay{i}`)
		bay:SetAttribute(ATTR_BAY, i)

		-- truck spot (the contract part)
		local spotCf = facing(c, FLOOR, BAY_Z, 0, 1)
		local tb = part(bay, `TruckBay{i}`, spotCf, V(14, 0.2, 30), C.Line, { transparency = 1, collide = false })
		tb.CanQuery = false
		CollectionService:AddTag(tb, TAG_TRUCK_BAY)
		tb:SetAttribute(ATTR_BAY, i)
		tb:SetAttribute(Names.Attr.LocationId, "Station")
		if i == 1 then
			-- v1 VehicleService parks its single lobby truck on the Station TruckSpot
			local ts = part(bay, "TruckSpot", spotCf, V(10, 0.2, 27), C.Line, { transparency = 1, collide = false })
			ts.CanQuery = false
			CollectionService:AddTag(ts, Names.Tag.TruckSpot)
			ts:SetAttribute(Names.Attr.LocationId, "Station")
		end

		-- painted lines, stop line, bay number
		for _, s in { -7.5, 7.5 } do
			span(bay, "BayLine", c + s - 0.2, c + s + 0.2, FLOOR, FLOOR + 0.03, -6, 29, C.Line, { collide = false })
		end
		span(bay, "StopLine", c - 7.5, c + 7.5, FLOOR, FLOOR + 0.03, -7, -6.4, C.Line, { collide = false })
		local fn = box(bay, "FloorNumber", c, FLOOR + 0.04, -12, 8, 0.1, 8, C.Floor, { transparency = 1, collide = false })
		label(fn, Enum.NormalId.Top, tostring(i), C.Line, Enum.Font.LuckiestGuy, nil, 20)
		plate(bay, "BayPlate", c, FLOOR + 10.5, -38.8, 0, 1, 8, 3, C.TruckRed, `BAY {i}`, C.Trim, Enum.Font.LuckiestGuy)
		local wheel = box(bay, "WheelStop", c, FLOOR + 0.3, -5.4, 8, 0.6, 0.8, C.Line)
		wheel.CanCollide = false

		-- roll-up door: drum housing, guide rails, rolled-up curtain edge
		cyl(bay, "DoorDrum", CFrame.new(c, FLOOR + DOOR_H + 1.6, 27.6), "x", DOOR_W + 0.6, 2.8, C.Locker)
		for _, s in { -1, 1 } do
			span(bay, "DoorRail", c + s * (DOOR_W / 2) - 0.3, c + s * (DOOR_W / 2) + 0.3, FLOOR, FLOOR + DOOR_H + 1, 28.2, 28.9, C.Steel)
		end
		for k = 0, 2 do
			span(bay, "DoorSlat", c - DOOR_W / 2, c + DOOR_W / 2, FLOOR + DOOR_H - 0.6 * (k + 1), FLOOR + DOOR_H - 0.6 * k - 0.08, 28.9, 29.3, if k == 2 then C.TruckRed else C.Ceiling, { collide = false })
		end

		-- door jamb stripes (red idle -> green GO)
		for _, s in { -1, 1 } do
			local x = c + s * (DOOR_W / 2 + 0.25)
			local stripe = span(bay, "DoorStripe", x - 0.25, x + 0.25, FLOOR + 0.5, FLOOR + DOOR_H - 0.5, 30.0, 30.4, C.AlarmDark, { neon = true, collide = false })
			if stripe then
				stripe:SetAttribute(ATTR_BAY, i)
			end
		end

		-- bay indicators: outside (facing the street) and inside (facing the cab)
		for side, dz in { 1, -1 } do
			local z = if dz > 0 then 30.3 else 28.7
			local y = if dz > 0 then FLOOR + 16.95 else FLOOR + 20.6
			local ind = folder(bay, "BayIndicator")
			ind:SetAttribute(ATTR_BAY, i)
			ind:SetAttribute("Side", if side == 1 then "Outside" else "Inside")
			local cx = c + 4.5
			part(ind, "Housing", facing(cx, y, z, 0, dz), V(4.4, 1.8, 0.6), C.Ink)
			local red = part(ind, "LampRed", facing(cx - 1.1, y, z + dz * 0.3, 0, dz), V(1.6, 1.6, 0.3), C.AlarmDark, { neon = true, collide = false })
			red:SetAttribute(ATTR_BAY, i)
			local green = part(ind, "LampGreen", facing(cx + 1.1, y, z + dz * 0.3, 0, dz), V(1.6, 1.6, 0.3), C.GoDark, { collide = false })
			green:SetAttribute(ATTR_BAY, i)
			local go = label(green, Enum.NormalId.Front, "GO", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
			go.TextTransparency = 1
			go.TextStrokeTransparency = 1
			local np = part(ind, "BayNumber", facing(c - 4.5, y, z, 0, dz), V(2.4, 1.8, 0.5), C.Trim)
			label(np, Enum.NormalId.Front, tostring(i), C.TruckRed, Enum.Font.LuckiestGuy)
		end

		-- beacon + speaker over the bay
		alarmLight(alarms, c, RT, BAY_Z, true, i, true)
		alarmSpeaker(alarms, facing(c, RT - 1.4, -12, 0, 1), i, 220)

		-- lights
		for _, z in { -24, -4, 18 } do
			fluoro(lights, c, RT - 0.3, z, true, 18)
		end
	end

	------------------------------------------------------------ apparatus floor: back of the hall
	-- tool bench + pegboard (behind bay 1/2)
	local tools = folder(apparatus, "ToolBench")
	box(tools, "Top", 0, FLOOR + 3, -37, 14, 0.8, 3.2, C.WoodLight)
	box(tools, "Cabinet", 0, FLOOR + 1.3, -37.4, 13.2, 2.6, 2.4, C.TruckRed)
	for _, dx in { -4.4, 0, 4.4 } do
		box(tools, "Drawer", dx, FLOOR + 1.4, -36.1, 3.8, 1.8, 0.4, C.HoseRed)
		box(tools, "Pull", dx, FLOOR + 1.8, -35.8, 1.4, 0.4, 0.4, C.Chrome)
	end
	plate(tools, "Pegboard", 0, FLOOR + 7, -38.8, 0, 1, 14, 6, hex("C9A26E"))
	plate(tools, "ToolsSign", 0, FLOOR + 10.8, -38.8, 0, 1, 6, 1.4, C.TruckRed, "TOOLS", C.Trim, Enum.Font.LuckiestGuy)
	box(tools, "Wrench", 3, FLOOR + 7, -38.4, 0.5, 3.4, 0.4, C.Chrome)
	box(tools, "Flashlight", -3, FLOOR + 7.4, -38.4, 0.8, 2.6, 0.6, C.Shield)
	hoseCoil(tools, -4.5, FLOOR + 3.4, -36.8)
	hoseCoil(tools, 4.5, FLOOR + 3.4, -36.8)
	prop("axeRack", apparatus, facing(-12, FLOOR, -39, 0, 1))
	prop("axeRack", apparatus, facing(12, FLOOR, -39, 0, 1))
	-- hose reels (behind bay 3)
	for _, x in { 25, 30, 35 } do
		prop("hoseReel", apparatus, facing(x, FLOOR, -36.5, 0, 1), nil, function()
			hoseCoil(apparatus, x, FLOOR, -36.5)
		end)
	end
	-- O2 tanks + extinguishers (behind bay 4, by the tower door)
	for k = 0, 3 do
		local tx = 46 + k * 1.8
		prop("oxygenTank", apparatus, facing(tx, FLOOR, -37.6, 0, 1), nil, function()
			cyl(apparatus, "OxygenTank", CFrame.new(tx, FLOOR + 2, -37.6), "y", 4, 1.4, hex("4F9A5A"))
		end)
	end
	for _, z in { -18, 4 } do
		prop("extinguisher", apparatus, facing(58.3, FLOOR, z, -1, 0), nil, function()
			cyl(apparatus, "Extinguisher", CFrame.new(58.3, FLOOR + 1.3, z), "y", 2.6, 1.2, C.TruckRed)
		end)
	end
	plate(apparatus, "TowerDoorSign", 59, FLOOR + 10.5, -30, -1, 0, 7, 1.4, C.TruckRed, "HOSE TOWER", C.Trim, Enum.Font.LuckiestGuy)
	prop("trampoline", apparatus, facing(40, FLOOR, -22, 0, 1))
	for k, cx in { 14, 16.5, 19 } do
		local cone = folder(apparatus, "Cone")
		local cz = -24 + (k % 2) * 1.5
		box(cone, "Base", cx, FLOOR + 0.2, cz, 1.8, 0.4, 1.8, C.Cone)
		cyl(cone, "Body", CFrame.new(cx, FLOOR + 1.3, cz), "y", 1.8, 1.0, C.Cone)
		cyl(cone, "Band", CFrame.new(cx, FLOOR + 1.4, cz), "y", 0.4, 1.06, C.Trim)
	end
	plate(apparatus, "SafetyBoard", -19.4, FLOOR + 6.5, -6, 1, 0, 10, 5, C.Cream, "DAYS WITHOUT\nAN INCIDENT:\n0", C.TruckRed, Enum.Font.LuckiestGuy)
	MapKit.hydrant(apparatus, O * CFrame.new(-17, FLOOR, -34))
	-- extra hall lights + a shared beacon at the back
	alarmLight(alarms, 20, RT, -24, true, 0)

	------------------------------------------------------------ hose-drying tower
	local TX0, TX1, TZ0, TZ1 = 60, 72, -38, -24
	wallRun(tower, "TowerS", V(TX0, 0, TZ1 - 0.5), V(TX1, 0, TZ1 - 0.5), V(0, 0, 1), {
		{ a = 5, b = 7, y0 = 28, y1 = 36 },
		{ a = 5, b = 7, y0 = 10, y1 = 18 },
	}, { height = TOWER_H, cornice = true, plinth = true })
	wallRun(tower, "TowerN", V(TX0, 0, TZ0 + 0.5), V(TX1, 0, TZ0 + 0.5), V(0, 0, -1), {}, { height = TOWER_H, cornice = true, plinth = true })
	wallRun(tower, "TowerE", V(TX1 - 0.5, 0, TZ0 + 1), V(TX1 - 0.5, 0, TZ1 - 1), V(1, 0, 0), {
		{ a = 5, b = 7, y0 = 30, y1 = 40 },
	}, { height = TOWER_H, cornice = true, plinth = true })
	span(tower, "TowerW", TX0, TX0 + 1, FLOOR + H, FLOOR + TOWER_H, TZ0 + 1, TZ1 - 1, C.Brick, { material = Enum.Material.Brick })
	span(tower, "TowerCap", TX0 - 1, TX1 + 1, FLOOR + TOWER_H, FLOOR + TOWER_H + 1.2, TZ0 - 1, TZ1 + 1, C.BrickDark)
	span(tower, "TowerRoof", TX0 + 1, TX1 - 1, FLOOR + TOWER_H + 1.2, FLOOR + TOWER_H + 3, TZ0 + 1, TZ1 - 1, C.TruckRed)
	local towerPlate = plate(tower, "TowerPlate", (TX0 + TX1) / 2, FLOOR + TOWER_H - 3, TZ1 + 0.1, 0, 1, 7, 3, C.Cream)
	label(towerPlate, Enum.NormalId.Front, "67", C.TruckRed, Enum.Font.LuckiestGuy, C.Ink)
	-- the drying hoses hanging from a beam with pulleys
	span(tower, "HoseBeam", TX0 + 1, TX1 - 1, FLOOR + TOWER_H - 2, FLOOR + TOWER_H - 1, -31.5, -30.5, C.Steel)
	for k, x in { 63, 66, 69 } do
		cyl(tower, "Pulley", CFrame.new(x, FLOOR + TOWER_H - 2.6, -31), "z", 0.6, 1.4, C.Chrome)
		local len = 26 + k * 2
		span(tower, "DryingHose", x - 0.35, x + 0.35, FLOOR + TOWER_H - 3 - len, FLOOR + TOWER_H - 3, -31.35, -30.65, if k == 2 then C.HoseRed else C.HoseYellow, { collide = false })
		box(tower, "HoseCoupling", x, FLOOR + TOWER_H - 3 - len - 0.4, -31, 1, 0.8, 1, C.Brass, { collide = false })
	end
	-- a ladder up the inside (cosmetic)
	for y = 2, TOWER_H - 6, 2 do
		box(tower, "Rung", 70.6, FLOOR + y, -27, 0.3, 0.3, 2.4, C.Steel)
	end

	------------------------------------------------------------ locker room
	-- gear racks 1..4 on the west wall, spawn pads in front of them
	for i = 1, 4 do
		local z = -24 + (i - 1) * 8
		local rack = folder(lockerRoom, `GearRack{i}`)
		rack:SetAttribute(ATTR_SLOT, i)
		local board = part(rack, "GearRack", facing(-58.7, FLOOR + 4.6, z, 1, 0), V(6, 7.6, 0.6), C.TruckRed)
		CollectionService:AddTag(board, TAG_GEAR_RACK)
		board:SetAttribute(ATTR_SLOT, i)
		board:SetAttribute(Names.Attr.Helmet, i)
		-- where InventoryService can hang grabbable gear (local -Z = into the room)
		for name, pos in {
			GearPoint_Hand = V(-1.6, -0.6, -1.2),
			GearPoint_Back = V(1.6, -0.2, -1.2),
			GearPoint_Head = V(0, 3.1, -1.0),
		} do
			local a = Instance.new("Attachment")
			a.Name = name
			a.Position = pos
			a.Parent = board
		end
		local np = plate(rack, "RackNumber", -58.3, FLOOR + 9.4, z, 1, 0, 3, 1.6, C.Trim, string.format("%02d", i), C.TruckRed, Enum.Font.LuckiestGuy)
		np.CanCollide = false
		box(rack, "Shelf", -57.6, FLOOR + 7.0, z, 2.2, 0.4, 6, C.WoodLight)
		helmet(rack, -57.6, FLOOR + 7.2, z, 1, 0)
		for _, dz in { -1.6, 0, 1.6 } do
			cyl(rack, "Hook", CFrame.new(-57.8, FLOOR + 5.4, z + dz), "x", 1.2, 0.3, C.Chrome)
		end
		box(rack, "Coat", -57.9, FLOOR + 3.6, z + 1.6, 0.8, 3.4, 2.2, C.Coat, { collide = false })
		box(rack, "CoatBand", -57.85, FLOOR + 2.7, z + 1.6, 0.9, 0.5, 2.3, C.Lime, { collide = false })
		box(rack, "BootL", -57.2, FLOOR + 0.8, z - 1, 1.6, 1.6, 1, C.Ink)
		box(rack, "BootR", -57.2, FLOOR + 0.8, z + 0.2, 1.6, 1.6, 1, C.Ink)
		-- spawn pad (StationSpawn)
		local pad = box(spawns, `SpawnPad{i}`, -51, FLOOR - 0.1, z, 4.4, 0.4, 4.4, C.Line)
		CollectionService:AddTag(pad, Names.Tag.StationSpawn)
		pad:SetAttribute(ATTR_SLOT, i)
		pad:SetAttribute(Names.Attr.Helmet, i)
		local inner = box(spawns, `SpawnPadInner{i}`, -51, FLOOR, z, 3.4, 0.4, 3.4, C.TruckRed)
		label(inner, Enum.NormalId.Top, string.format("%02d", i), C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	end
	plate(lockerRoom, "SuitUp", -59, FLOOR + 10, -12, 1, 0, 12, 1.4, C.TruckRed, "SUIT UP - GRAB YOUR GEAR", C.Trim, Enum.Font.LuckiestGuy)
	-- spare lockers on the front wall (between the doors), facing into the room
	for k, x in { -45.5, -42.5, -39.5, -36.5, -33.5 } do
		prop("locker", lockerRoom, facing(x, FLOOR, 4.6, 0, -1), { door = true, helmet = k }, function()
			box(lockerRoom, "Locker", x, FLOOR + 3.75, 4.6, 3, 7.5, 2, C.Locker)
		end)
	end
	prop("bench", lockerRoom, facing(-40, FLOOR, -14, 0, 1), { length = 12 }, function()
		box(lockerRoom, "Bench", -40, FLOOR + 1.4, -14, 12, 0.8, 2, C.WoodLight)
	end)
	hoseCoil(lockerRoom, -36, FLOOR, -20)
	-- fire pole: Mat at the bottom, "Pole" to just above the upstairs floor, "PoleTop" to the roof
	local pole = folder(lockerRoom, "FirePole")
	local px, pz = -25, -30
	local poleTop = F2 + 6.2
	cyl(pole, "Pole", CFrame.new(px, (FLOOR + poleTop) / 2, pz), "y", poleTop - FLOOR, 0.8, C.Chrome, { material = Enum.Material.Metal })
	cyl(pole, "PoleTop", CFrame.new(px, (poleTop + RT) / 2, pz), "y", RT - poleTop, 0.8, C.Chrome, { material = Enum.Material.Metal })
	cyl(pole, "Mat", CFrame.new(px, FLOOR + 0.15, pz), "y", 0.3, 5, C.HoseRed)
	cyl(pole, "MatRing", CFrame.new(px, FLOOR + 0.05, pz), "y", 0.3, 5.8, C.Line)
	-- rails around the upstairs pole hole (open on the +Z side to jump in)
	span(upstairs, "PoleRailN", -28.2, -21.8, F2 + 3.2, F2 + 3.6, -33.2, -32.8, C.TruckRed)
	span(upstairs, "PoleRailW", -28.4, -28, F2 + 3.2, F2 + 3.6, -33, -27, C.TruckRed)
	span(upstairs, "PoleRailE", -22, -21.6, F2 + 3.2, F2 + 3.6, -33, -27, C.TruckRed)
	for _, p in { V(-28.2, 0, -33), V(-21.8, 0, -33), V(-28.2, 0, -27.2), V(-21.8, 0, -27.2) } do
		span(upstairs, "PoleRailPost", p.X - 0.2, p.X + 0.2, F2, F2 + 3.4, p.Z - 0.2, p.Z + 0.2, C.Steel)
	end
	plate(upstairs, "PoleSign", -24, F2 + 8, -38.8, 0, 1, 6, 1.6, C.Line, "SLIDE, DON'T JUMP", C.Ink, Enum.Font.LuckiestGuy)
	-- dog corner
	local dogArea = folder(lockerRoom, "DogCorner")
	cyl(dogArea, "DogBed", CFrame.new(-30, FLOOR + 0.4, -6), "y", 0.8, 4.6, C.HoseRed)
	cyl(dogArea, "Cushion", CFrame.new(-30, FLOOR + 0.5, -6), "y", 0.8, 3.6, C.Cream)
	cyl(dogArea, "Bowl", CFrame.new(-26.5, FLOOR + 0.3, -4), "y", 0.6, 1.4, hex("4FB3D9"))
	local dogCf = facing(-30, FLOOR, -6, 1, 1)
	npc("Dog", dogArea, dogCf, { pose = "stand" }, function()
		fallbackDog(dogArea, dogCf)
	end)
	for _, x in { -50, -32 } do
		for _, z in { -28, -10 } do
			fluoro(lights, x, SLAB0 - 0.25, z)
		end
	end
	alarmLight(alarms, -40, SLAB0, -22, true, 0)
	alarmSpeaker(alarms, facing(-40, SLAB0 - 1.2, -4, 0, -1), 0, 140)

	------------------------------------------------------------ watch room
	local screen = part(watch, "DispatchScreen", facing(-40.7, FLOOR + 6.4, 20, -1, 0), V(14, 6.4, 0.3), C.Screen, { neon = true })
	do
		local sg = Instance.new("SurfaceGui")
		sg.Name = "DispatchGui"
		sg.Face = Enum.NormalId.Front
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 30
		sg.LightInfluence = 0
		local t = Instance.new("TextLabel")
		t.Name = "Text"
		t.Size = UDim2.fromScale(1, 1)
		t.BackgroundColor3 = C.Screen
		t.BackgroundTransparency = 0
		t.Text = "STATION 67\nALL QUIET (for now)"
		t.TextScaled = true
		t.Font = Enum.Font.LuckiestGuy
		t.TextColor3 = C.ScreenText
		t.Parent = sg
		sg.Parent = screen
	end
	span(watch, "ScreenFrame", -40.6, -40.4, FLOOR + 2.8, FLOOR + 10, 12.6, 27.4, C.Ink)
	-- dispatch desk with three monitors facing the dispatcher (who faces +X)
	span(watch, "Desk", -47, -44, FLOOR + 2.8, FLOOR + 3.4, 13, 27, C.WoodLight)
	span(watch, "DeskFront", -47, -46.6, FLOOR, FLOOR + 2.8, 13, 27, C.Wood)
	for k, z in { 16, 20, 24 } do
		local mon = part(watch, "Monitor", facing(-45, FLOOR + 5, z, -1, 0), V(3.4, 2.2, 0.3), C.Screen, { neon = true })
		label(mon, Enum.NormalId.Front, ({ "CAD", "MAP", "RADIO" })[k], C.ScreenText, Enum.Font.GothamBold)
		box(watch, "MonitorStand", -44.8, FLOOR + 3.8, z, 0.4, 0.8, 0.4, C.Steel)
	end
	box(watch, "Radio", -45.5, FLOOR + 3.8, 26, 1.4, 0.8, 1.6, C.Ink)
	box(watch, "RadioMic", -46.4, FLOOR + 3.6, 26, 0.4, 0.4, 0.4, C.Steel)
	prop("chair", watch, facing(-49.5, FLOOR, 20, 1, 0), { color = C.TruckRed }, function()
		box(watch, "Chair", -49.5, FLOOR + 1.6, 20, 2.4, 0.6, 2.4, C.TruckRed)
	end)
	local dispCf = facing(-51, FLOOR, 16, 1, 0)
	npc("Firefighter", watch, dispCf, { helmet = 67, pose = "stand" }, function()
		fallbackFirefighter(watch, dispCf, 67)
	end)
	-- city map board + "calls today" whiteboard on the west wall
	local mapBoard = plate(watch, "CityMap", -59, FLOOR + 6.5, 22, 1, 0, 8, 5, C.Cream)
	label(mapBoard, Enum.NormalId.Front, "CITY MAP\n(we're the red dot)", C.Ink, Enum.Font.FredokaOne)
	ball(watch, "MapDot", CFrame.new(-58.7, FLOOR + 7.6, 24.6), 0.6, C.Alarm, { neon = true, collide = false })
	plate(watch, "Whiteboard", -56.5, FLOOR + 6.5, 6.6, 0, 1, 4, 4, C.Trim, "TODAY:\nSAVE THE CAT\n(again)", C.Ink, Enum.Font.FredokaOne)
	fluoro(lights, -50, SLAB0 - 0.25, 18, true)
	alarmLight(alarms, -50, SLAB0, 10, true, 0)
	alarmSpeaker(alarms, facing(-58.6, FLOOR + 9.4, 27.5, 1, 0), 0, 120)
	-- front door frame + awning
	span(outside, "DoorTop", -56.6, -49.4, FLOOR + 9, FLOOR + 9.6, 30, 30.6, C.Trim)
	span(outside, "DoorL", -56.6, -56, FLOOR, FLOOR + 9, 30, 30.6, C.Trim)
	span(outside, "DoorR", -50, -49.4, FLOOR, FLOOR + 9, 30, 30.6, C.Trim)
	part(outside, "Awning", CFrame.new(-53, FLOOR + 10.4, 31.6) * CFrame.Angles(math.rad(12), 0, 0), V(10, 0.5, 3.4), C.TruckRed)
	local entry = plate(outside, "EntrySign", -53, FLOOR + 10.4, 33.3, 0, 1, 10, 0.9, C.TruckRed)
	label(entry, Enum.NormalId.Front, "WATCH DESK - PLEASE KNOCK", C.Trim, Enum.Font.FredokaOne)

	------------------------------------------------------------ kitchen
	prop("counter", kitchen, facing(-38.6, FLOOR, 16, 1, 0), { length = 6, sink = true }, function()
		box(kitchen, "Counter", -38.6, FLOOR + 1.8, 16, 2.6, 3.6, 6, C.Cream)
	end)
	prop("counter", kitchen, facing(-38.6, FLOOR, 22, 1, 0), { length = 6, stove = true }, function()
		box(kitchen, "Stove", -38.6, FLOOR + 1.8, 22, 2.6, 3.6, 6, C.Steel)
	end)
	prop("fridge", kitchen, facing(-38.4, FLOOR, 27.4, 1, 0), nil, function()
		box(kitchen, "Fridge", -38.4, FLOOR + 3.5, 27.4, 2.6, 7, 3, C.Trim)
	end)
	-- the famous chili (a little too spicy)
	cyl(kitchen, "ChiliPot", CFrame.new(-38.4, FLOOR + 4.4, 22.6), "y", 1.6, 2.2, C.Steel)
	cyl(kitchen, "Chili", CFrame.new(-38.4, FLOOR + 5.15, 22.6), "y", 0.2, 1.9, C.Chili, { neon = true, collide = false })
	box(kitchen, "CoffeeMachine", -38.6, FLOOR + 4.5, 13.8, 1.6, 1.8, 1.4, C.Ink)
	cyl(kitchen, "CoffeePot", CFrame.new(-38.2, FLOOR + 4.1, 13.8), "y", 1, 0.9, hex("4A2A1A"))
	prop("table", kitchen, facing(-29, FLOOR, 20, 0, 1), { width = 8, depth = 5 }, function()
		box(kitchen, "Table", -29, FLOOR + 2.8, 20, 8, 0.4, 5, C.WoodLight)
	end)
	for _, p in { V(-31.5, 0, 16.4), V(-26.5, 0, 16.4) } do
		prop("chair", kitchen, facing(p.X, FLOOR, p.Z, 0, 1), nil)
	end
	for _, p in { V(-31.5, 0, 23.6), V(-26.5, 0, 23.6) } do
		prop("chair", kitchen, facing(p.X, FLOOR, p.Z, 0, -1), nil)
	end
	plate(kitchen, "KitchenRules", -20.6, FLOOR + 7, 26, -1, 0, 6, 3, C.Cream, "RULE #1:\nDON'T BURN\nTHE KITCHEN", C.TruckRed, Enum.Font.LuckiestGuy)
	fluoro(lights, -30, SLAB0 - 0.25, 18, true)
	alarmLight(alarms, -30, SLAB0, 26, true, 0)

	------------------------------------------------------------ upstairs: bunk room + lounge
	for i = 1, 4 do
		local z = -24 + (i - 1) * 8
		prop("bed", upstairs, facing(-55.5, F2, z, 1, 0), { color = if i % 2 == 0 then C.Carpet else C.TruckRed }, function()
			box(upstairs, "Bed", -55.5, F2 + 1, z, 8, 2, 5, C.Cream)
		end)
		plate(upstairs, "BunkNumber", -59, F2 + 6.5, z, 1, 0, 2.6, 1.4, C.Trim, string.format("%02d", i), C.TruckRed, Enum.Font.LuckiestGuy)
		helmet(upstairs, -50.6, F2, z + 2.6, 1, 0)
	end
	prop("sofa", upstairs, facing(-36, F2, 16, 0, -1), { width = 10 }, function()
		box(upstairs, "Sofa", -36, F2 + 1.5, 16, 10, 3, 3.4, C.Carpet)
	end)
	prop("table", upstairs, facing(-36, F2, 11.5, 0, 1), { width = 5, depth = 2.6, height = 1.6 })
	prop("tv", upstairs, facing(-36, F2, 5, 0, 1), { on = true }, function()
		box(upstairs, "TV", -36, F2 + 3, 5, 5, 3, 0.6, C.Ink)
	end)
	prop("bookshelf", upstairs, facing(-58.6, F2, 24, 1, 0), { width = 6 })
	plate(upstairs, "BunkSign", -40, F2 + 10.5, 28.9, 0, -1, 14, 1.6, C.Cream, "BUNK ROOM - QUIET PLEASE", C.TruckRed, Enum.Font.LuckiestGuy)
	for _, x in { -50, -32 } do
		for _, z in { -18, 2, 20 } do
			fluoro(lights, x, RT - 0.25, z)
		end
	end
	alarmLight(alarms, -40, RT, -8, true, 0)
	alarmSpeaker(alarms, facing(-40, RT - 1.2, 8, 0, -1), 0, 120)

	------------------------------------------------------------ facade beacons (one per bay)
	for i, c in BAY_X do
		local bx = c - 9.5
		box(alarms, "BeaconShelf", bx, FLOOR + 16.6, 31, 2.4, 0.4, 2, C.Steel)
		alarmLight(alarms, bx, FLOOR + 16.8, 31, false, i)
	end

	------------------------------------------------------------ outside
	-- bollards between the bay doors
	for _, bx in { -20, 0, 20, 40, 60 } do
		cyl(outside, "Bollard", CFrame.new(bx, APRON_Y + 1.5, 32), "y", 3, 1.2, C.Line)
		cyl(outside, "BollardBand", CFrame.new(bx, APRON_Y + 2.2, 32), "y", 0.5, 1.26, C.Ink)
	end
	-- flagpole (west lawn)
	local flag = folder(outside, "Flagpole")
	local fx, fz = -74, 56
	box(flag, "Base", fx, LAWN_Y + 0.4, fz, 3, 0.8, 3, C.Concrete)
	cyl(flag, "Pole", CFrame.new(fx, LAWN_Y + 0.8 + 16, fz), "y", 32, 0.6, C.Chrome)
	ball(flag, "Finial", CFrame.new(fx, LAWN_Y + 33.4, fz), 1.2, C.Shield)
	local cloth = box(flag, "Flag", fx + 0.3 + 3.6, LAWN_Y + 30.4, fz, 7.2, 4.4, 0.4, C.TruckRed, { collide = false })
	label(cloth, Enum.NormalId.Back, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	label(cloth, Enum.NormalId.Front, "67", C.Trim, Enum.Font.LuckiestGuy, C.Ink)
	-- lawn sign (east of the apron)
	box(outside, "SignBase", 73, LAWN_Y + 0.8, 52, 12, 1.6, 1.8, C.Brick, { material = Enum.Material.Brick })
	plate(outside, "LawnSign", 73, LAWN_Y + 3.6, 52, 0, 1, 11, 3.8, C.Cream, "STATION 67", C.TruckRed, Enum.Font.LuckiestGuy)
	box(outside, "SignCap", 73, LAWN_Y + 5.7, 52, 12, 0.5, 1, C.BrickDark)
	-- bushes along the wing facade, trees around the lot
	for _, b in { V(-58, 0, 32), V(-47, 0, 32), V(-37, 0, 32), V(-29, 0, 32), V(-63, 0, -30), V(-63, 0, -6), V(-63, 0, 20) } do
		prop("bush", outside, facing(b.X, LAWN_Y, b.Z, 0, 1), nil, function()
			ball(outside, "Bush", CFrame.new(b.X, LAWN_Y + 1, b.Z), 3.4, C.Foliage)
		end)
	end
	for _, t in { V(-76, 0, -50), V(-76, 0, -20), V(-76, 0, 10), V(-40, 0, -52), V(-6, 0, -52), V(80, 0, -50), V(80, 0, -10), V(80, 0, 20), V(-78, 0, 40) } do
		local jx = (rng:NextNumber() - 0.5) * 3
		local jz = (rng:NextNumber() - 0.5) * 3
		local cf = CFrame.new(t.X + jx, LAWN_Y, t.Z + jz) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0)
		prop("tree", outside, cf, nil, function()
			fallbackTree(outside, t.X + jx, t.Z + jz, rng)
		end)
	end
	-- street lamps on the sidewalk, clear of the apron
	for _, x in { -76, -44, 72 } do
		prop("streetLamp", outside, facing(x, WALK_Y, KERB_Z - 2, 0, 1), nil, function()
			fallbackLamp(outside, x, WALK_Y, KERB_Z - 2, 1)
		end)
	end
	MapKit.hydrant(outside, O * CFrame.new(66, WALK_Y, KERB_Z - 2))
	prop("mailbox", outside, facing(-64, WALK_Y, KERB_Z - 2.5, 0, 1))
end

return StationBuilder
