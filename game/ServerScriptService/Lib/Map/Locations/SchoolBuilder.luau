-- SchoolBuilder [owner: G2]. MAPLE ELEMENTARY: the trailer's school (docs/game/05 §2.5, docs/game/02
-- SchoolHallway kit, trailer s1 c4-5): a long hallway of red lockers with mustard lower walls, teal
-- pilasters and fluorescent panels, a red FIRE pull station on the wall, classrooms full of desks,
-- a cafeteria with its kitchen, and a gym with a stage.
-- Slot 3. Local frame: origin = slot centre on the ground, +X east, +Z south. The school faces the
-- street on the +Z side; the road continues the Town/Apartment road (centre z = 56).
--
--   Main block X -64..40, Z -28..30, one storey (floor y 1, walls to 15, roof 15..16).
--     Hallway Z 0.5..10 (X -63..39.5), skylit (glass roof strip) so it reads from the camera.
--     North: Class 1 (X -63..-36), Class 2 (-36..-8), Class 3 (-8..20), Library (20..39.5).
--     South: Kitchen (-63..-48), Cafeteria (-48..-20), Lobby (-20..-4, front doors),
--            Office (-4..14), Class 4 (14..39.5).
--   Gym X 40..84, Z -28..30, walls to 25, stage on the north end, double doors from the hallway.
--   Outside: front lawn + entrance canopy + flagpole + bus, playground behind, playing field across
--   the road, parking lot east of the gym.
--
-- Gameplay hooks (find them by tag/attribute, never by coordinate):
--   FireStart F1..F3: Flammable parts: kitchen stove counter (F1), Class 3 teacher desk (F2),
--     gym stage curtain (F3); attr FireId.
--   RescueSpawn R1..R5: invisible 2x2x2, attr Kind (Civilian|Cat), Pose, SpawnId, BuildingId,
--     Variant ("Kid" | "Teacher" | "ClassPet"); -Z of the part is the facing.
--   FireAlarm: pull stations (tag "FireAlarm", ProximityPrompt "Pull alarm"); alarm bells/lamps
--     tagged "SchoolAlarmLamp" (off until someone switches them on).
--   Doors: west fire exit + gym fire exit are locked (axe). Hydrants H1..H3.
--   TruckSpot: one part in the street, LookVector = truck forward. PlayerSpawn: pad beside it.
--   Model attrs: DisplayName, Atmosphere = "Default".
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)
local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local SchoolBuilder = {}
SchoolBuilder.Id = "School"
SchoolBuilder.Slot = 3

local TAG_TRUCKSPOT = (Names.Tag :: any).TruckSpot or "TruckSpot"
local TAG_PLAYERSPAWN = (Names.Tag :: any).PlayerSpawn or "PlayerSpawn"
local TAG_FIREALARM = "FireAlarm"
local TAG_ALARMLAMP = "SchoolAlarmLamp"
local BID = "School.MapleElementary"
local GYM_BID = "School.Gym"

local FY = 1 -- floor surface
local H = 14 -- main block storey (floor 1 -> ceiling 15)
local ROOF = 15
local GYM_ROOF = 25

local hex = Color3.fromHex
local C = {
	-- docs/game/02 palette
	SchoolLocker = hex("#CD5528"),
	SchoolWall = hex("#D2A54A"),
	SchoolWallUp = hex("#E8D9B0"),
	SchoolPillar = hex("#2F5F5A"),
	SchoolFloor = hex("#C88A54"),
	SchoolFloorB = hex("#BE8048"),
	AlarmRed = hex("#FF2A2A"),
	Brick = hex("#B5573A"),
	BrickDark = hex("#8E3F2A"),
	Stucco = hex("#E8D3A8"),
	Grass = hex("#5E8C3E"),
	Lawn = hex("#7FAF4A"),
	Asphalt = hex("#4A4650"),
	AsphaltDark = hex("#3E3A44"),
	Sidewalk = hex("#C9B8A8"),
	Kerb = hex("#B3A291"),
	LineYellow = hex("#E3B23C"),
	Trim = hex("#F2EDE4"),
	White = hex("#F7F4EE"),
	Black = hex("#1A1714"),
	Iron = hex("#3A3A40"),
	Steel = hex("#8A8C90"),
	Chrome = hex("#D6D8DC"),
	Concrete = hex("#B8B2A6"),
	ConcreteDark = hex("#8E897F"),
	RoofTar = hex("#4E4A52"),
	Glass = hex("#A8D5E2"),
	Red = hex("#C8232B"),
	Lamp = hex("#FFF4D6"),
	LampWarm = hex("#FFE2B8"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	GymFloor = hex("#D9A066"),
	GymLine = hex("#F7F4EE"),
	Tile = hex("#EFE7D8"),
	TileB = hex("#BFD8D8"),
	TileC = hex("#E9C46A"),
	Lino = hex("#D9CBB8"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Peach = hex("#F2D2B0"),
	Lilac = hex("#D9C6E3"),
	Sky = hex("#9EC1CC"),
	Pink = hex("#FF7FB0"),
	Blue = hex("#3A7FD0"),
	Green = hex("#6BCB5A"),
	Chalk = hex("#2F4F3A"),
	Cork = hex("#B08A5A"),
	DeskBlue = hex("#5E7FA0"),
	Bus = hex("#F2B630"),
	Curtain = hex("#B83A2E"),
	CurtainDark = hex("#8A2A22"),
	Gold = hex("#E8C24A"),
	Leaf = hex("#6F9A3A"),
	Leaf2 = hex("#8AAF4A"),
	Trunk = hex("#7A3A1E"),
	Sand = hex("#E3CB8A"),
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
	l.Color = color or C.LampWarm
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

local function rect(parent: Instance, name: string, x0: number, x1: number, z0: number, z1: number, top: number, thick: number, color: Color3, flam: boolean?, checker: Color3?, extra: { [string]: any }?)
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
			local o: { [string]: any } = { flammable = flam, fuel = if flam then 35 else nil }
			if extra then
				for k, val in extra do
					o[k] = val
				end
			end
			box(parent, name, x0 + (i - 0.5) * sx, top - thick / 2, z0 + (j - 0.5) * sz, sx, thick, sz, col, o)
		end
	end
end

-- Axis-aligned wall from (ax, az) to (bx, bz), base y0, height h, 1 thick, with holes
-- { c = coordinate along the wall, w, b, t } (b/t relative to y0). Flammable walls are split into
-- <= 8-stud chunks.
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
				transparency = opts.transparency,
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

-- Two-tone interior wall (floor -> 4 lower colour, 4 -> ceiling upper colour), flammable.
local function wall2(parent: Instance, name: string, ax: number, az: number, bx: number, bz: number, holes: { Hole }?, low: Color3, high: Color3)
	wall(parent, name, ax, az, bx, bz, FY, 4, holes, { color = low, flammable = true, fuel = 30 })
	local up: { Hole } = {}
	for _, hh in holes or {} do
		table.insert(up, { c = hh.c, w = hh.w, b = hh.b - 4, t = hh.t - 4 })
	end
	wall(parent, name, ax, az, bx, bz, FY + 4, H - 4, up, { color = high, flammable = true, fuel = 30 })
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
	warn(`[SchoolBuilder] {name} unavailable: {if ok then "not a table" else mod}`)
	return nil
end

local FALLBACK: { [string]: { { any } } } = {
	plant = { { v(0, 0.7, 0), v(1.4, 1.4, 1.4), C.Terracotta }, { v(0, 2.4, 0), v(2.4, 2.4, 2.4), C.Leaf2, true } },
	fridge = { { v(0, 3.5, 0), v(3, 7, 2.6), C.White } },
	counter = { { v(0, 1.8, 0), v(6, 3.6, 2.6), C.Tile, true } },
	bench = { { v(0, 1, 0), v(6, 2, 1.8), C.WoodLight, true } },
	extinguisher = { { v(0, 1.8, 0), v(1.2, 3.6, 1.2), C.Red } },
	streetLamp = { { v(0, 6, 0), v(0.6, 12, 0.6), C.Iron }, { v(0, 11.6, -1.4), v(1.4, 0.8, 1.4), C.Lamp } },
	tree = { { v(0, 3, 0), v(1.4, 6, 1.4), C.Trunk }, { v(0, 8, 0), v(8, 8, 8), C.Leaf } },
	bush = { { v(0, 1.4, 0), v(3.6, 2.8, 3.6), C.Leaf } },
	car = { { v(0, 1.9, 0), v(6, 2, 11), C.Teal }, { v(0, 3.7, 0.6), v(5.4, 1.8, 6), C.Teal } },
	alarmLight = { { v(0, -1, 0), v(1.4, 1.4, 1.4), C.AlarmRed } },
	chair = { { v(0, 1.2, 0), v(2, 2.4, 2), C.WoodLight, true } },
	table = { { v(0, 1.4, 0), v(4, 2.8, 3), C.WoodLight, true } },
	fence = { { v(0, 1.7, 0), v(8, 3.4, 0.4), C.Trim } },
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
			warn(`[SchoolBuilder] PropKit.{kind} failed: {res}`)
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
		warn(`[SchoolBuilder] NpcBuilder {kind} failed: {res}`)
	end
	local m = folder(parent, kind)
	part(m, "Body", cfLocal * CFrame.new(0, 2.2, 0), v(2, 2.4, 1.2), opts and opts.color or C.Teal, { collide = false })
	part(m, "Legs", cfLocal * CFrame.new(0, 0.6, 0), v(1.8, 1.2, 1), C.TealDark, { collide = false })
	part(m, "Head", cfLocal * CFrame.new(0, 4.2, 0), v(2.2, 2.2, 2.2), C.Peach, { shape = Ball, collide = false })
	MapKit.googlyEyes(m, O * cfLocal * CFrame.new(0, 4.4, -1), 0.8)
end

local function biggestFlammable(m: Instance?): BasePart?
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
local function fireStart(p: BasePart?, id: string, bid: string)
	if not p then
		warn(`[SchoolBuilder] no flammable part for {id}`)
		return
	end
	CollectionService:AddTag(p, Names.Tag.Flammable)
	CollectionService:AddTag(p, Names.Tag.FireStart)
	p:SetAttribute("FireId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
end

local function rescueSpawn(parent: Instance, id: string, kind: string, variant: string, bid: string, cfLocal: CFrame, pose: string)
	local p = part(parent, id, cfLocal * CFrame.new(0, 1, 0), v(2, 2, 2), C.Mustard, {
		transparency = 1,
		collide = false,
		tags = { Names.Tag.RescueSpawn },
	})
	p.CanQuery = false
	p:SetAttribute(Names.Attr.Kind, kind)
	p:SetAttribute("Variant", variant)
	p:SetAttribute("SpawnId", id)
	p:SetAttribute(Names.Attr.BuildingId, bid)
	p:SetAttribute("Pose", pose)
end

local function door(parent: Instance, name: string, x: number, z: number, alongZ: boolean, locked: boolean, bid: string): Part
	local cf = CFrame.new(x, FY + 3.5, z) * (if alongZ then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity)
	local d = MapKit.door(parent, name, O * cf, locked)
	d:SetAttribute(Names.Attr.BuildingId, bid)
	return d
end

-- Glass pane (not a rescue Window) in a hole: centre (x, yc, z), along X unless alongZ.
local function pane(parent: Instance, x: number, yc: number, z: number, w: number, h: number, alongZ: boolean, frame: Color3?, nOut: number?)
	local rot = if alongZ then CFrame.Angles(0, math.pi / 2, 0) else CFrame.identity
	part(parent, "Glass", CFrame.new(x, yc, z) * rot, v(w, h, 0.3), C.Glass, { material = Enum.Material.Glass, transparency = 0.45 })
	if frame then
		local n = nOut or 1
		part(parent, "Sill", CFrame.new(x, yc - h / 2 - 0.2, z) * rot * CFrame.new(0, 0, n * 0.6), v(w + 1, 0.4, 1.2), frame, { collide = false })
		part(parent, "Mullion", CFrame.new(x, yc, z) * rot, v(0.3, h, 0.5), frame, { collide = false })
		part(parent, "Header", CFrame.new(x, yc + h / 2 + 0.25, z) * rot * CFrame.new(0, 0, n * 0.45), v(w + 1, 0.5, 0.9), frame, { collide = false })
	end
end

------------------------------------------------------------------------------------------------
-- Shell: exterior walls, floors, roofs
------------------------------------------------------------------------------------------------
local function shell(model: Model, bld: Model, gym: Model)
	local brick = { color = C.Brick, material = Enum.Material.Brick }
	-- main block exterior (0 -> 15), floor at 1
	local frontHoles = {
		{ c = -56, w = 4, b = 5, t = 9 }, -- kitchen
		{ c = -42, w = 8, b = 5, t = 10 }, -- cafeteria
		{ c = -30, w = 8, b = 5, t = 10 },
		{ c = -17.5, w = 2, b = 1, t = 9 }, -- lobby sidelight
		{ c = -12, w = 8, b = 1, t = 8.5 }, -- double front door
		{ c = -6.5, w = 2, b = 1, t = 9 }, -- lobby sidelight
		{ c = 1, w = 6, b = 5, t = 10 }, -- office
		{ c = 9, w = 6, b = 5, t = 10 },
		{ c = 22, w = 8, b = 5, t = 10 }, -- class 4
		{ c = 32, w = 8, b = 5, t = 10 },
	}
	wall(bld, "ExtWall", -64, 29.5, 39.5, 29.5, 0, ROOF, frontHoles, brick)
	local backHoles = {}
	-- classroom windows flank the chalkboards (board = room centre +- 6)
	for _, x in { -59, -40, -31.5, -12.5, -3.5, 15.5, 26, 34 } do
		table.insert(backHoles, { c = x, w = 6, b = 5, t = 10 })
	end
	wall(bld, "ExtWall", -64, -27.5, 39.5, -27.5, 0, ROOF, backHoles, brick)
	wall(bld, "ExtWall", -63.5, -27, -63.5, 29, 0, ROOF, {
		{ c = -14, w = 8, b = 5, t = 10 }, -- class 1
		{ c = 5.25, w = 4, b = 1, t = 8 }, -- hallway fire exit
		{ c = 20, w = 4, b = 5, t = 9 }, -- kitchen
	}, brick)
	-- shared main/gym wall (0 -> 25), double doors from the hallway
	wall(bld, "ExtWall", 40, -28, 40, 30, 0, GYM_ROOF, { { c = 5.25, w = 8, b = 1, t = 8.5 } }, brick)
	-- windows + doors in the main shell
	for _, hh in frontHoles do
		if hh.b > 1 then
			pane(bld, hh.c, (hh.b + hh.t) / 2, 29.5, hh.w, hh.t - hh.b, false, C.Trim, 1)
		elseif hh.w == 2 then
			pane(bld, hh.c, (hh.b + hh.t) / 2, 29.5, hh.w, hh.t - hh.b, false)
		end
	end
	for _, hh in backHoles do
		pane(bld, hh.c, (hh.b + hh.t) / 2, -27.5, hh.w, hh.t - hh.b, false, C.Trim, -1)
	end
	pane(bld, -63.5, 7.5, -14, 8, 5, true, C.Trim, 1)
	pane(bld, -63.5, 7, 20, 4, 4, true, C.Trim, 1)
	door(bld, "FrontDoorL", -14, 29.5, false, false, BID)
	door(bld, "FrontDoorR", -10, 29.5, false, false, BID)
	box(bld, "FrontDoorHead", -12, 8.25, 29.5, 8, 0.5, 1, C.Trim)
	door(bld, "FireExitWest", -63.5, 5.25, true, true, BID)
	local ex = box(bld, "ExitSign", -62.9, 9, 5.25, 0.2, 0.8, 2.4, hex("#3AD07A"), { neon = true, collide = false })
	label(ex, Enum.NormalId.Right, "EXIT", C.White, Enum.Font.FredokaOne)
	door(gym, "GymDoorL", 40, 3.25, true, false, GYM_BID)
	door(gym, "GymDoorR", 40, 7.25, true, false, GYM_BID)
	box(gym, "GymDoorHead", 40, 8.25, 5.25, 1, 0.5, 8, C.Trim)
	local gs = box(gym, "GymSign", 39.4, 10.5, 5.25, 0.2, 1.6, 6, C.TealDark, { collide = false })
	label(gs, Enum.NormalId.Left, "GYM", C.Mustard, Enum.Font.LuckiestGuy)

	-- gym exterior (0 -> 25), clerestory windows
	local gymFront = { { c = 62, w = 4, b = 1, t = 8 }, { c = 48, w = 8, b = 15, t = 21 }, { c = 76, w = 8, b = 15, t = 21 } }
	wall(gym, "GymWall", 40.5, 29.5, 84, 29.5, 0, GYM_ROOF, gymFront, brick)
	local gymBack = { { c = 52, w = 8, b = 15, t = 21 }, { c = 72, w = 8, b = 15, t = 21 } }
	wall(gym, "GymWall", 40.5, -27.5, 84, -27.5, 0, GYM_ROOF, gymBack, brick)
	local gymEast = { { c = -12, w = 8, b = 15, t = 21 }, { c = 4, w = 8, b = 15, t = 21 }, { c = 20, w = 8, b = 15, t = 21 } }
	wall(gym, "GymWall", 83.5, -27, 83.5, 29, 0, GYM_ROOF, gymEast, brick)
	for _, hh in { gymFront[2], gymFront[3] } do
		pane(gym, hh.c, 18, 29.5, 8, 6, false, C.Trim, 1)
	end
	for _, hh in gymBack do
		pane(gym, hh.c, 18, -27.5, 8, 6, false, C.Trim, -1)
	end
	for _, hh in gymEast do
		pane(gym, 83.5, 18, hh.c, 8, 6, true, C.Trim, 1)
	end
	door(gym, "GymFireExit", 62, 29.5, false, true, GYM_BID)
	local gx = box(gym, "ExitSign", 62, 9, 28.9, 2.4, 0.8, 0.2, hex("#3AD07A"), { neon = true, collide = false })
	label(gx, Enum.NormalId.Front, "EXIT", C.White, Enum.Font.FredokaOne)

	-- plinths + stucco bands + parapets
	for _, p in {
		{ -12, 29.5, 104.6, true },
		{ -12, -27.5, 104.6, true },
		{ 62, 29.5, 44.6, true },
		{ 62, -27.5, 44.6, true },
	} do
		local z = p[2] + (if p[2] > 0 then 0.65 else -0.65)
		box(model, "Plinth", p[1], 0.9, z, p[3], 1.8, 0.3, C.BrickDark, { material = Enum.Material.Brick, collide = false })
		local top = if p[1] > 40 then GYM_ROOF else ROOF
		box(model, "Band", p[1], top - 0.8, z, p[3], 1.6, 0.4, C.Stucco, { collide = false })
	end
	box(model, "Plinth", -64.15, 0.9, 1, 0.3, 1.8, 57, C.BrickDark, { material = Enum.Material.Brick, collide = false })
	box(model, "Band", -64.2, ROOF - 0.8, 1, 0.4, 1.6, 57, C.Stucco, { collide = false })
	box(model, "Plinth", 84.15, 0.9, 1, 0.3, 1.8, 57, C.BrickDark, { material = Enum.Material.Brick, collide = false })
	box(model, "Band", 84.2, GYM_ROOF - 0.8, 1, 0.4, 1.6, 57, C.Stucco, { collide = false })
	-- floors
	rect(bld, "HallFloor", -63, 39.5, 0.5, 10, FY, 1, C.SchoolFloor, false, C.SchoolFloorB)
	rect(bld, "ClassFloor", -63, 39.5, -27, 0.5, FY, 1, C.Lino)
	rect(bld, "KitchenFloor", -63, -48, 10, 29, FY, 1, C.Tile, false, C.TileB)
	rect(bld, "CafeFloor", -48, -20, 10, 29, FY, 1, C.Tile, false, C.TileC)
	rect(bld, "LobbyFloor", -20, -4, 10, 29, FY, 1, C.SchoolFloor, false, C.SchoolFloorB)
	rect(bld, "OfficeFloor", -4, 39.5, 10, 29, FY, 1, C.Lino)
	rect(gym, "GymFloor", 40.5, 83, -27, 29, FY, 1, C.GymFloor)
	-- roofs: glass skylight strip over the hallway so the lockers read from outside
	rect(bld, "Roof", -64, 40, -28, 0, ROOF + 1, 1, C.RoofTar)
	rect(bld, "Roof", -64, 40, 10.5, 30, ROOF + 1, 1, C.RoofTar)
	rect(bld, "Skylight", -64, 40, 0, 10.5, ROOF + 1, 0.6, C.Glass, false, nil, { material = Enum.Material.Glass, transparency = 0.55 })
	for x = -56, 32, 8 do
		box(bld, "SkylightRib", x, ROOF + 0.85, 5.25, 0.5, 0.6, 10.5, C.Trim, { collide = false })
	end
	rect(gym, "GymRoof", 40, 84, -28, 30, GYM_ROOF + 1, 1, C.RoofTar)
	-- parapets
	for _, pp in {
		{ -64, 29.5, 40, 29.5, ROOF + 1 },
		{ -64, -27.5, 40, -27.5, ROOF + 1 },
		{ -63.5, -27, -63.5, 29, ROOF + 1 },
		{ 40.5, 29.5, 84, 29.5, GYM_ROOF + 1 },
		{ 40.5, -27.5, 84, -27.5, GYM_ROOF + 1 },
		{ 83.5, -27, 83.5, 29, GYM_ROOF + 1 },
	} do
		wall(model, "Parapet", pp[1], pp[2], pp[3], pp[4], pp[5], 1.5, nil, brick)
	end
	-- roof kit: AC units + vents
	for _, a in { { -40, -14 }, { -10, 20 }, { 20, -16 } } do
		box(model, "ACUnit", a[1], ROOF + 2.5, a[2], 5, 3, 4, C.Concrete)
		part(model, "ACFan", CFrame.new(a[1], ROOF + 4.05, a[2]) * UPRIGHT, v(0.2, 3, 3), C.Iron, { shape = Cyl, collide = false })
	end
	cylY(model, "Vent", 62, GYM_ROOF + 1, -8, 2.5, 2, C.Chrome)
	cylY(model, "Vent", 70, GYM_ROOF + 1, 14, 2.5, 2, C.Chrome)
end

------------------------------------------------------------------------------------------------
-- Hallway: lockers, pilasters, fluorescent panels, the FIRE pull station
------------------------------------------------------------------------------------------------
local function lockerBank(parent: Instance, x: number, z: number, face: number, n: number)
	-- n lockers (2 wide x 6.5 high x 1.5 deep) centred at x, against a wall, opening toward +Z*face
	local w = n * 2
	local body = box(parent, "Lockers", x, FY + 3.25, z, w, 6.5, 1.5, C.SchoolLocker, { flammable = true, fuel = 25 })
	body:SetAttribute("Lockers", n)
	local fz = z + face * 0.8
	for i = 1, n do
		local lx = x - w / 2 + (i - 0.5) * 2
		box(parent, "Vent", lx, FY + 5.6, fz, 1.2, 0.8, 0.1, C.SchoolLocker:Lerp(C.Black, 0.45), { collide = false })
		box(parent, "Handle", lx + 0.6, FY + 3.4, fz + face * 0.05, 0.25, 0.8, 0.2, C.Chrome, { collide = false })
	end
	for i = 1, n - 1 do
		box(parent, "Seam", x - w / 2 + i * 2, FY + 3.25, fz, 0.08, 6.4, 0.1, C.SchoolLocker:Lerp(C.Black, 0.3), { collide = false })
	end
end

local function pullStation(parent: Instance, x: number, z: number, face: number, alongZ: boolean?): Part
	-- red FIRE pull station on a wall; face = outward (+1/-1) along Z (or X when alongZ)
	local function p(dx: number, dy: number, dn: number): CFrame
		if alongZ then
			return CFrame.new(x + face * dn, FY + dy, z + dx) * CFrame.Angles(0, math.pi / 2, 0)
		end
		return CFrame.new(x + dx, FY + dy, z + face * dn)
	end
	local st = part(parent, "PullStation", p(0, 4.6, 0.25), v(1.3, 1.8, 0.5), C.AlarmRed, { tags = { TAG_FIREALARM } })
	st:SetAttribute(Names.Attr.BuildingId, BID)
	local lbl = part(parent, "PullLabel", p(0, 5.15, 0.52), v(1.1, 0.5, 0.05), C.White, { collide = false })
	label(lbl, if face > 0 then Enum.NormalId.Back else Enum.NormalId.Front, "FIRE", C.AlarmRed, Enum.Font.LuckiestGuy)
	part(parent, "PullHandle", p(0, 4.4, 0.6), v(0.8, 0.35, 0.3), C.White, { collide = false })
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pull alarm"
	prompt.ObjectText = "Fire alarm"
	prompt.HoldDuration = 0.3
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = st
	-- alarm bell above
	local bell = part(parent, "AlarmBell", p(0, 9.5, 0.3) * CFrame.Angles(0, math.pi / 2, 0), v(0.5, 1.8, 1.8), C.AlarmRed, { shape = Cyl, collide = false, tags = { TAG_ALARMLAMP } })
	bell:SetAttribute("On", false)
	part(parent, "BellClapper", p(0, 9.5, 0.65), v(0.5, 0.5, 0.5), C.Gold, { shape = Ball, collide = false })
	return st
end

local function hallway(bld: Model, rng: Random)
	local hw = folder(bld, "Hallway")
	-- hallway walls (two-tone, flammable). North: classroom doors at -42, -18, 6, 30.
	local northDoors = { -42, -18, 6, 30 }
	local nh: { Hole } = {}
	for _, x in northDoors do
		table.insert(nh, { c = x, w = 4, b = 0, t = 7 })
	end
	wall2(hw, "HallWall", -63, 0, 39.5, 0, nh, C.SchoolWall, C.SchoolWallUp)
	-- South: cafeteria opening -30, lobby opening -12 (12 wide), office door 6, class 4 door 30.
	local sh: { Hole } = {
		{ c = -30, w = 8, b = 0, t = 9 },
		{ c = -12, w = 12, b = 0, t = 10 },
		{ c = 6, w = 4, b = 0, t = 7 },
		{ c = 30, w = 4, b = 0, t = 7 },
	}
	wall2(hw, "HallWall", -63, 10.5, 39.5, 10.5, sh, C.SchoolWall, C.SchoolWallUp)
	for _, x in northDoors do
		door(hw, `ClassDoor{x}`, x, 0, false, false, BID)
	end
	door(hw, "OfficeDoor", 6, 10.5, false, false, BID)
	door(hw, "Class4Door", 30, 10.5, false, false, BID)

	-- teal pilasters every 12 (both sides; the south one at -12 sits in the lobby opening)
	for x = -60, 36, 12 do
		box(hw, "Pilaster", x, FY + H / 2, 1.4, 1.2, H, 1.8, C.SchoolPillar)
		if x ~= -12 then
			box(hw, "Pilaster", x, FY + H / 2, 9.1, 1.2, H, 1.8, C.SchoolPillar)
		end
	end
	-- lockers: full banks in the open bays, single lockers beside the doors
	-- banks of 4 (8 x 6.5 x 1.5): the unit that topples when it burns (docs/game/05 §2.5)
	for _, bx in { -54, -6, 18 } do
		lockerBank(hw, bx, 1.25, 1, 4)
	end
	for _, bx in { -54, -42, 18 } do
		lockerBank(hw, bx, 9.25, -1, 4)
	end
	for _, dx in northDoors do
		lockerBank(hw, dx - 3.5, 1.25, 1, 1)
		lockerBank(hw, dx + 3.5, 1.25, 1, 1)
	end
	for _, dx in { 6, 30 } do
		lockerBank(hw, dx - 3.5, 9.25, -1, 1)
		lockerBank(hw, dx + 3.5, 9.25, -1, 1)
	end
	-- the trailer's pull station (bay -30 north) + notice board + water fountain
	pullStation(hw, -30, 0.5, 1)
	local nb = box(hw, "NoticeBoard", -33.2, FY + 6, 0.6, 3.6, 3, 0.2, C.Cork, { flammable = true, collide = false })
	label(nb, Enum.NormalId.Back, "FIRE DRILL\nTODAY!\n(not a drill)", C.Black, Enum.Font.FredokaOne)
	for i, col in { C.Pink, C.Sky, C.Mustard } do
		box(hw, "Flyer", -27.6 + (i - 2) * 1.0, FY + 6.3 + (i % 2) * 0.6, 0.62, 0.8, 1.0, 0.05, col, { collide = false })
	end
	box(hw, "Fountain", -26.5, FY + 2.6, 1.1, 1.6, 0.6, 1.2, C.Chrome)
	box(hw, "FountainStem", -26.5, FY + 1.2, 0.8, 0.6, 2.4, 0.6, C.Steel)
	-- banner over the lobby opening
	local banner = box(hw, "Banner", -12, FY + 11.5, 9.85, 8, 1.6, 0.1, C.TealDark, { collide = false, flammable = true })
	label(banner, Enum.NormalId.Front, "GO FIREFLIES!", C.Mustard, Enum.Font.LuckiestGuy)
	-- fluorescent panels every 10 (Neon + SurfaceLight), alarm lamps at both ends
	for x = -58, 32, 10 do
		local panel = box(hw, "Fluoro", x, ROOF - 0.35, 5.25, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
		local sl = Instance.new("SurfaceLight")
		sl.Face = Enum.NormalId.Bottom
		sl.Range = 16
		sl.Brightness = 1.2
		sl.Color = C.LampWarm
		sl.Shadows = false
		sl.Parent = panel
		box(hw, "FluoroHousing", x, ROOF - 0.12, 5.25, 4.4, 0.25, 1.8, C.Steel, { collide = false })
	end
	for _, ax in { -50, 24 } do
		local lamp = prop("alarmLight", hw, at(ax, ROOF, 5.25, 0), { on = false })
		if lamp then
			for _, d in lamp:GetDescendants() do
				if d:IsA("BasePart") and d.Name == "Bulb" then
					CollectionService:AddTag(d, TAG_ALARMLAMP)
				end
			end
		end
	end
	-- a dropped backpack and some papers (kids left in a hurry)
	box(hw, "Backpack", -16, FY + 0.9, 6.5, 1.6, 1.8, 1.0, C.Blue, { flammable = true })
	box(hw, "BackpackFlap", -16, FY + 1.5, 6.0, 1.6, 0.8, 0.1, C.Mustard, { collide = false })
	for i = 1, 4 do
		part(hw, "Paper", CFrame.new(-20 + i * 1.6 + rng:NextNumber(-0.4, 0.4), FY + 0.06, 4.5 + rng:NextNumber(-1.5, 1.5)) * CFrame.Angles(0, rng:NextNumber(0, math.pi), 0), v(1, 0.05, 1.3), C.White, { collide = false, flammable = true })
	end
end

------------------------------------------------------------------------------------------------
-- Rooms
------------------------------------------------------------------------------------------------
local function deskSet(parent: Instance, x: number, z: number, color: Color3)
	-- student desk + chair, desk faces -Z (toward the board), chair on +Z
	box(parent, "DeskTop", x, FY + 2.7, z, 3, 0.35, 2.2, C.WoodLight, { flammable = true, fuel = 20 })
	box(parent, "DeskFrame", x, FY + 1.25, z + 0.3, 2.6, 2.5, 1.2, C.DeskBlue)
	box(parent, "Seat", x, FY + 1.6, z + 2, 1.9, 0.35, 1.8, color, { flammable = true, fuel = 15 })
	box(parent, "SeatBack", x, FY + 2.7, z + 2.8, 1.9, 1.9, 0.3, color, { collide = false })
	box(parent, "SeatLegs", x, FY + 0.7, z + 2, 1.4, 1.4, 1.4, C.Steel)
end

local function chalkboard(parent: Instance, x: number, z: number, face: number, text: string)
	-- on a wall at z, facing +Z*face
	local b = box(parent, "Chalkboard", x, FY + 6.5, z + face * 0.15, 12, 5, 0.2, C.Chalk, { collide = false })
	label(b, if face > 0 then Enum.NormalId.Back else Enum.NormalId.Front, text, C.White, Enum.Font.PermanentMarker)
	box(parent, "BoardFrame", x, FY + 9.15, z + face * 0.2, 12.6, 0.4, 0.4, C.WoodLight, { collide = false })
	box(parent, "ChalkTray", x, FY + 3.9, z + face * 0.35, 12.6, 0.3, 0.7, C.WoodLight, { collide = false })
	local abc = box(parent, "Alphabet", x, FY + 11, z + face * 0.15, 20, 1.2, 0.1, C.Mustard, { collide = false })
	label(abc, if face > 0 then Enum.NormalId.Back else Enum.NormalId.Front, "Aa Bb Cc Dd Ee Ff Gg Hh", C.Red, Enum.Font.FredokaOne)
end

local function teacherDesk(parent: Instance, x: number, z: number): Part
	local top = box(parent, "TeacherDesk", x, FY + 1.6, z, 6, 3.2, 3, C.Wood, { flammable = true, fuel = 40 })
	box(parent, "Apple", x + 2, FY + 3.6, z, 0.8, 0.8, 0.8, C.Red, { shape = Ball, collide = false })
	box(parent, "Papers", x - 1, FY + 3.3, z, 1.6, 0.3, 1.2, C.White, { collide = false, flammable = true })
	return top
end

local function shelf(parent: Instance, x: number, z: number, alongZ: boolean, rng: Random)
	local sx, sz = if alongZ then 1.4 else 6, if alongZ then 6 else 1.4
	box(parent, "Shelf", x, FY + 3, z, sx, 6, sz, C.WoodLight, { flammable = true, fuel = 35 })
	local cols = { C.Red, C.Teal, C.Mustard, C.Blue, C.Pink, C.Green }
	for r = 1, 2 do
		local col = cols[rng:NextInteger(1, #cols)]
		box(parent, "Books", x, FY + 1.2 + (r - 1) * 2.4 + 0.9, z, if alongZ then 1.5 else 5.2, 1.6, if alongZ then 5.2 else 1.5, col, { flammable = true, collide = false })
	end
end

local KID_COLORS = { C.Red, C.Teal, C.Mustard, C.Blue, C.Pink, C.Green, C.Terracotta, C.Lilac }

local function classroom(parent: Instance, rng: Random, name: string, x0: number, x1: number, wallColor: Color3, board: string, rows: number, cols: number): { [string]: any }
	local cr = folder(parent, name)
	local cx = (x0 + x1) / 2
	-- the board hangs on the north exterior wall between the two windows; desks face north (-Z)
	chalkboard(cr, cx, -27, 1, board)
	local tdesk = teacherDesk(cr, cx + 6, -22.5)
	local out = { desk = tdesk, desks = {} }
	local w = x1 - x0
	for r = 1, rows do
		for c = 1, cols do
			local dx = x0 + (c - 0.5) * w / cols
			local dz = -17 + (r - 1) * 4.2
			deskSet(cr, dx, dz, KID_COLORS[rng:NextInteger(1, #KID_COLORS)])
			table.insert(out.desks, Vector3.new(dx, FY, dz))
		end
	end
	shelf(cr, x0 + 1.2, -12, true, rng)
	box(cr, "Globe", x0 + 1.2, FY + 7, -8.5, 1.6, 1.6, 1.6, C.Sky, { shape = Ball, collide = false })
	box(cr, "GlobeStand", x0 + 1.2, FY + 6.2, -8.5, 0.6, 0.4, 0.6, C.Wood, { collide = false })
	part(cr, "Clock", CFrame.new(cx, FY + 11.6, -0.55) * CFrame.Angles(0, math.pi / 2, 0), v(0.2, 1.6, 1.6), C.White, { shape = Cyl, collide = false })
	box(cr, "Poster", x1 - 0.6, FY + 6.5, -10, 0.1, 3, 2.4, wallColor:Lerp(C.White, 0.5), { collide = false, flammable = true })
	local lampA = box(cr, "Fluoro", cx - 6, ROOF - 0.35, -14, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	box(cr, "Fluoro", cx + 6, ROOF - 0.35, -14, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	light(lampA, 20, 0.8)
	prop("plant", cr, at(x1 - 1.6, FY, -25.4, 0))
	return out
end

local function northRooms(bld: Model, rng: Random)
	-- partitions (two-tone, flammable)
	for _, x in { -36, -8, 20 } do
		wall2(bld, "Partition", x, -27, x, -0.5, nil, C.Peach:Lerp(C.SchoolWall, 0.3), C.SchoolWallUp)
	end
	local c1 = classroom(bld, rng, "Class1", -63, -36, C.Sky, "2 + 2 = 4\nSTOP DROP\n& ROLL", 4, 4)
	classroom(bld, rng, "Class2", -36, -8, C.Lilac, "FIRE DRILL\nWALK, DON'T\nRUN", 4, 4)
	local c3 = classroom(bld, rng, "Class3", -8, 20, C.Peach, "SCIENCE:\nFIRE NEEDS\nAIR + FUEL", 3, 4)
	-- class pet corner in Class 3 (the cat)
	box(bld, "PetTable", -5, FY + 1.5, -24.5, 5, 3, 3, C.WoodLight, { flammable = true })
	box(bld, "PetBasket", -5, FY + 3.4, -24.5, 2.6, 0.8, 2, C.Terracotta, { collide = false })
	-- library (20..39.5)
	local lib = folder(bld, "Library")
	shelf(lib, 21.2, -20, true, rng)
	shelf(lib, 38.3, -20, true, rng)
	shelf(lib, 38.3, -12, true, rng)
	for _, t in { { 26, -12 }, { 33, -6 } } do
		cylY(lib, "RoundTable", t[1], FY, t[2], 2.6, 4.4, C.WoodLight, { flammable = true })
		for _, a in { 0, 2.1, 4.2 } do
			box(lib, "Stool", t[1] + math.cos(a) * 3, FY + 0.9, t[2] + math.sin(a) * 3, 1.4, 1.8, 1.4, KID_COLORS[rng:NextInteger(1, #KID_COLORS)], { flammable = true })
		end
	end
	ball(lib, "BeanBag", 24, FY + 1, -4, 3, C.Pink, { flammable = true })
	ball(lib, "BeanBag", 28, FY + 1, -3.4, 3, C.Teal, { flammable = true })
	box(lib, "Rug", 27, FY + 0.1, -5, 8, 0.2, 5, C.Mustard, { collide = false, flammable = true })
	local rd = box(lib, "ReadSign", 30, FY + 10, -26.9, 8, 1.4, 0.1, C.Teal, { collide = false })
	label(rd, Enum.NormalId.Back, "READ!", C.White, Enum.Font.LuckiestGuy)
	local ll = box(lib, "Fluoro", 30, ROOF - 0.35, -14, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	light(ll, 18, 0.7)
	return c1, c3
end

local function kitchenAndCafe(bld: Model, rng: Random): BasePart?
	local k = folder(bld, "Kitchen")
	-- serving wall (x -48) with a hatch and a door into the kitchen
	wall(k, "ServeWall", -48, 11, -48, 29, FY, H, { { c = 16, w = 8, b = 3, t = 7 }, { c = 25, w = 4, b = 0, t = 7 } }, { color = C.Tile, flammable = true, fuel = 30 })
	door(k, "KitchenDoor", -48, 25, true, false, BID)
	box(k, "ServeCounter", -46.6, FY + 1.6, 16, 1.8, 3.2, 8.6, C.Steel)
	box(k, "SneezeGuard", -46.2, FY + 4.6, 16, 0.2, 2.2, 8, C.Glass, { material = Enum.Material.Glass, transparency = 0.5, collide = false })
	for i, col in { C.Mustard, C.Green, C.Terracotta } do
		box(k, "FoodTray", -46.6, FY + 3.4, 13 + i * 1.6, 1.4, 0.4, 1.2, col, { collide = false })
	end
	local menu = box(k, "MenuBoard", -47.4, FY + 10, 16, 0.2, 2.4, 7, C.Chalk, { collide = false })
	label(menu, Enum.NormalId.Right, "TODAY:\nFISH STICKS", C.White, Enum.Font.PermanentMarker)
	-- kitchen line along the west wall (stoves face east)
	local stove = prop("counter", k, at(-61.6, FY, 14, -90), { length = 6, stove = true, color = C.Steel })
	prop("counter", k, at(-61.6, FY, 23, -90), { length = 6, sink = true, color = C.Steel })
	prop("fridge", k, at(-61.4, FY, 27.5, -90))
	-- deep fryer + big pots
	box(k, "Fryer", -61.4, FY + 1.8, 18.6, 2.6, 3.6, 2.6, C.Steel)
	box(k, "FryerOil", -61.4, FY + 3.65, 18.6, 2.2, 0.1, 2.2, C.Mustard, { collide = false })
	cylY(k, "Pot", -55, FY + 3.2, 13, 1.8, 2.2, C.Chrome)
	cylY(k, "Pot", -52, FY + 3.2, 13, 1.4, 1.8, C.Chrome)
	box(k, "PrepTable", -53.5, FY + 1.6, 13, 6, 3.2, 3, C.Steel)
	box(k, "Shelf", -55, FY + 6.5, 11.6, 10, 0.4, 1.2, C.Steel, { collide = false })
	for i = 1, 6 do
		cylY(k, "Can", -59 + i * 1.4, FY + 6.7, 11.6, 1.2, 0.9, KID_COLORS[i], { collide = false })
	end
	local kl = box(k, "Fluoro", -55, ROOF - 0.35, 20, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	light(kl, 18, 0.8)
	-- cafeteria: three long tables with benches
	local cf = folder(bld, "Cafeteria")
	for i, tz in { 16, 21, 26 } do
		for _, hx in { -37, -29 } do -- two 8-stud halves so fire stays local
			box(cf, "CafeTable", hx, FY + 2.5, tz, 8, 0.4, 2.6, C.Sky:Lerp(C.White, 0.3), { flammable = true })
			box(cf, "CafeBench", hx, FY + 1.3, tz - 2.1, 7.5, 0.4, 1.2, C.Teal, { flammable = true })
			box(cf, "CafeBench", hx, FY + 1.3, tz + 2.1, 7.5, 0.4, 1.2, C.Teal, { flammable = true })
		end
		box(cf, "CafeTableLeg", -38, FY + 1.15, tz, 0.6, 2.3, 1.6, C.Steel)
		box(cf, "CafeTableLeg", -28, FY + 1.15, tz, 0.6, 2.3, 1.6, C.Steel)
		for j = 1, 3 do
			local trayX = -39 + j * 3.6 + rng:NextNumber(-0.5, 0.5)
			box(cf, "Tray", trayX, FY + 2.8, tz + (if (i + j) % 2 == 0 then -0.6 else 0.6), 1.6, 0.2, 1.1, KID_COLORS[rng:NextInteger(1, #KID_COLORS)], { collide = false })
		end
	end
	box(cf, "MilkCrate", -22, FY + 1, 27.4, 2, 2, 2, C.Red)
	cylY(cf, "TrashCan", -22, FY, 12.4, 3, 2, C.TealDark)
	for _, lx in { -40, -28 } do
		local l = box(cf, "Fluoro", lx, ROOF - 0.35, 20, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
		light(l, 20, 0.8)
	end
	pullStation(cf, -20.5, 27, -1, true)
	return biggestFlammable(stove)
end

local function lobbyOfficeClass4(bld: Model, rng: Random)
	-- partitions on the south side (two-tone)
	wall2(bld, "Partition", -20, 11, -20, 29, { { c = 20, w = 10, b = 0, t = 9 } }, C.SchoolWall, C.SchoolWallUp)
	wall2(bld, "Partition", -4, 11, -4, 29, { { c = 24, w = 4, b = 0, t = 7 } }, C.SchoolWall, C.SchoolWallUp)
	wall2(bld, "Partition", 14, 11, 14, 29, nil, C.SchoolWall, C.SchoolWallUp)
	door(bld, "OfficeSideDoor", -4, 24, true, false, BID)
	local lb = folder(bld, "Lobby")
	-- trophy case on the east wall, facing the lobby
	box(lb, "TrophyCase", -5.4, FY + 3.5, 16, 1.8, 7, 7, C.Wood, { flammable = true })
	box(lb, "TrophyGlass", -6.4, FY + 4.4, 16, 0.2, 4.6, 6.4, C.Glass, { material = Enum.Material.Glass, transparency = 0.5, collide = false })
	for i = 1, 3 do
		cylY(lb, "Trophy", -5.6, FY + 3.2, 14.2 + (i - 1) * 1.8, 1.4, 0.8, C.Gold, { collide = false })
		ball(lb, "TrophyCup", -5.6, FY + 4.9, 14.2 + (i - 1) * 1.8, 1.1, C.Gold, { collide = false })
	end
	prop("plant", lb, at(-18.4, FY, 27.6, 0))
	prop("plant", lb, at(-5.6, FY, 27.6, 0))
	box(lb, "WelcomeMat", -12, FY + 0.1, 27, 8, 0.2, 3, C.Red, { collide = false })
	local ws = box(lb, "Welcome", -12, FY + 11, 28.9, 10, 1.6, 0.1, C.Mustard, { collide = false })
	label(ws, Enum.NormalId.Front, "WELCOME, FIREFLIES!", C.TealDark, Enum.Font.FredokaOne)
	local ll = box(lb, "Fluoro", -12, ROOF - 0.35, 20, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	light(ll, 20, 0.9)
	-- office: principal's desk, filing cabinet, PA mic
	local of = folder(bld, "Office")
	box(of, "OfficeDesk", 5, FY + 1.6, 22, 7, 3.2, 3, C.Wood, { flammable = true })
	box(of, "Computer", 5, FY + 4.4, 22.6, 2, 1.6, 0.4, C.Iron, { collide = false })
	box(of, "Screen", 5, FY + 4.4, 22.85, 1.7, 1.2, 0.1, C.Sky, { neon = true, collide = false })
	box(of, "PAMic", 7.5, FY + 3.8, 21.8, 0.3, 1.2, 0.3, C.Iron, { collide = false })
	ball(of, "PAMicHead", 7.5, FY + 4.5, 21.8, 0.6, C.Black, { collide = false })
	prop("chair", of, at(5, FY, 25, 0))
	box(of, "Filing", 12.4, FY + 2.5, 13, 2, 5, 2.4, C.Steel)
	shelf(of, -2.8, 15, true, rng)
	prop("plant", of, at(12.2, FY, 27.6, 0))
	local sign = box(of, "OfficeSign", 6, FY + 8.2, 9.95, 4, 1, 0.1, C.TealDark, { collide = false })
	label(sign, Enum.NormalId.Front, "OFFICE", C.White, Enum.Font.FredokaOne)
	local ol = box(of, "Fluoro", 5, ROOF - 0.35, 20, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	light(ol, 18, 0.8)
	-- class 4 (art room): desks + easels + paint splats
	local c4 = folder(bld, "Class4")
	for r = 1, 2 do
		for c = 1, 3 do
			deskSet(c4, 14 + c * 6.4, 12 + r * 5, KID_COLORS[rng:NextInteger(1, #KID_COLORS)])
		end
	end
	for _, ex in { 18, 23, 36 } do
		box(c4, "Easel", ex, FY + 3.4, 26.8, 3, 4, 0.3, C.White, { flammable = true })
		box(c4, "EaselLegs", ex, FY + 1.6, 27.2, 2.4, 3.2, 0.4, C.WoodLight, { flammable = true })
		box(c4, "Paint", ex + 0.3, FY + 3.8, 26.6, 1.4, 1.2, 0.05, KID_COLORS[rng:NextInteger(1, #KID_COLORS)], { collide = false })
	end
	for i = 1, 4 do
		cylY(c4, "Splat", 20 + i * 4 + rng:NextNumber(-1, 1), FY + 0.01, 17 + rng:NextNumber(-2, 2), 0.05, 1.6, KID_COLORS[rng:NextInteger(1, #KID_COLORS)], { collide = false })
	end
	local cl = box(c4, "Fluoro", 27, ROOF - 0.35, 20, 4, 0.3, 1.4, C.Lamp, { neon = true, collide = false })
	light(cl, 20, 0.8)
end

local function gymInterior(gym: Model): BasePart?
	local g = folder(gym, "GymInterior")
	-- court lines
	local CZ = 11 -- court centre line (sidelines z 0 / 22, baselines x 43 / 81)
	box(g, "CourtLine", 62, FY + 0.06, 0, 38, 0.1, 0.4, C.GymLine, { collide = false })
	box(g, "CourtLine", 62, FY + 0.06, 22, 38, 0.1, 0.4, C.GymLine, { collide = false })
	box(g, "CourtLine", 43, FY + 0.06, CZ, 0.4, 0.1, 22.4, C.GymLine, { collide = false })
	box(g, "CourtLine", 81, FY + 0.06, CZ, 0.4, 0.1, 22.4, C.GymLine, { collide = false })
	box(g, "CourtLine", 62, FY + 0.06, CZ, 0.4, 0.1, 22.4, C.GymLine, { collide = false })
	cylY(g, "CenterCircle", 62, FY, CZ, 0.1, 9, C.GymLine, { collide = false })
	cylY(g, "CenterDot", 62, FY + 0.02, CZ, 0.1, 8.2, C.Red, { collide = false })
	for _, kx in { 47.5, 76.5 } do
		box(g, "Key", kx, FY + 0.05, CZ, 9, 0.1, 8, C.Teal, { collide = false })
	end
	-- hoops on the west/east ends (court runs along X)
	for _, hd in { { 43.4, 1 }, { 82.6, -1 } } do
		local hx, s = hd[1], hd[2]
		box(g, "HoopPole", hx - s * 1.2, FY + 6, CZ, 0.8, 12, 0.8, C.Steel)
		box(g, "Backboard", hx, FY + 12, CZ, 0.3, 4, 6, C.White)
		box(g, "BackboardBox", hx + s * 0.18, FY + 11.4, CZ, 0.05, 1.6, 2.2, C.Red, { collide = false })
		part(g, "Rim", CFrame.new(hx + s * 1.3, FY + 10.4, CZ) * UPRIGHT, v(0.25, 2, 2), C.Terracotta, { shape = Cyl, collide = false })
	end
	-- bleachers along the front wall (flammable wood tiers)
	for _, bx in { 50, 74 } do
		for t = 1, 3 do
			for _, hx in { -3.5, 3.5 } do
				box(g, "Bleacher", bx + hx, FY + t * 0.6, 29 - t * 1.8, 7, t * 1.2, 1.8, if t % 2 == 0 then C.WoodLight else C.Wood, { flammable = true, fuel = 40 })
			end
		end
	end
	-- mats, ball cart, climbing rope, scoreboard
	for i, mz in { -6, -1 } do
		box(g, "Mat", 47 + i * 0.3, FY + 0.4, mz, 6, 0.8, 4, C.Blue, { flammable = true })
	end
	box(g, "BallCart", 80, FY + 1.4, 18, 3, 2.4, 2, C.Steel)
	for i = 1, 4 do
		ball(g, "Ball", 79 + (i % 2) * 1.6, FY + 3.2, 17.5 + (i // 3) * 1, 1.4, if i % 2 == 0 then C.Terracotta else C.Red, { collide = false })
	end
	cylY(g, "Rope", 70, FY + 6, -6, GYM_ROOF - FY - 6, 0.5, C.Sand, { collide = false })
	local sb = box(g, "Scoreboard", 82.9, FY + 17, 12, 0.4, 4, 8, C.Black, { collide = false })
	label(sb, Enum.NormalId.Left, "HOME 67  GUEST 0", C.Mustard, Enum.Font.LuckiestGuy, true)
	-- stage at the north end (x 41..83, z -27..-16), curtains open
	rect(g, "Stage", 41, 83, -27, -16, FY + 3.5, 3.5, C.Wood, true)
	box(g, "StageSkirt", 62, FY + 1.75, -15.9, 42, 3.5, 0.2, C.CurtainDark, { collide = false })
	for _, sx in { 46, 78 } do
		for st = 1, 3 do
			box(g, "StageStep", sx, FY + st * 1.15 - 0.55, -15 + (3 - st) * 1.2 + 0.6, 4, st * 1.15, 1.2, C.WoodLight)
		end
	end
	-- proscenium + valance + drapes (8-wide chunks)
	box(g, "Proscenium", 41.5, FY + 11, -16, 1, 16, 1.4, C.TealDark)
	box(g, "Proscenium", 82.5, FY + 11, -16, 1, 16, 1.4, C.TealDark)
	box(g, "Proscenium", 62, GYM_ROOF - 3, -16, 42, 4, 1.4, C.TealDark)
	local drapes: { BasePart } = {}
	for i, cx in { 45, 51, 73, 79 } do
		local d = box(g, "Curtain", cx, FY + 3.5 + 7.5, -16.8, 6, 15, 0.6, if i % 2 == 0 then C.CurtainDark else C.Curtain, { flammable = true, fuel = 25, collide = false })
		table.insert(drapes, d)
	end
	for i = 1, 5 do
		box(g, "Valance", 41.5 + (i - 0.5) * 8.2, GYM_ROOF - 5.6, -16.7, 8.2, 2, 0.6, C.Curtain, { flammable = true, fuel = 25, collide = false })
	end
	for i = 1, 5 do
		box(g, "Backdrop", 41.5 + (i - 0.5) * 8.2, FY + 3.5 + 9, -26.6, 8.2, 18, 0.4, C.CurtainDark, { flammable = true, fuel = 25, collide = false })
	end
	box(g, "Podium", 62, FY + 3.5 + 2, -20, 2.6, 4, 2, C.WoodLight, { flammable = true })
	box(g, "PodiumMic", 62, FY + 3.5 + 4.6, -20.6, 0.2, 1.2, 0.2, C.Iron, { collide = false })
	local banner = box(g, "StageBanner", 62, GYM_ROOF - 8.4, -26.3, 20, 2.2, 0.1, C.Mustard, { collide = false })
	label(banner, Enum.NormalId.Back, "SCHOOL PLAY: THE LITTLE MATCH GIRL", C.Red, Enum.Font.FredokaOne)
	-- gym lights: hanging cage lamps
	for _, lp in { { 52, -4 }, { 72, -4 }, { 52, 18 }, { 72, 18 } } do
		box(g, "LampCord", lp[1], GYM_ROOF - 1.5, lp[2], 0.3, 3, 0.3, C.Iron, { collide = false })
		local l = ball(g, "GymLamp", lp[1], GYM_ROOF - 3.6, lp[2], 1.8, C.Lamp, { neon = true, collide = false })
		light(l, 32, 1)
	end
	pullStation(g, 40.5, 16, 1, true)
	prop("extinguisher", g, at(41.4, FY, 18, 90))
	return drapes[2]
end

------------------------------------------------------------------------------------------------
-- Outside: front yard, bus, playground, street, field, neighbours
------------------------------------------------------------------------------------------------
local function schoolBus(parent: Instance, cf: CFrame)
	-- cf = ground point, bus faces -Z of cf. ~8 W x 9 H x 28 L
	local b = folder(parent, "SchoolBus")
	local function bp(name: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, col: Color3, extra: { [string]: any }?): Part
		return part(b, name, cf * CFrame.new(x, y, z), v(sx, sy, sz), col, extra)
	end
	local body = bp("Body", 0, 4.6, 1.5, 8, 6.4, 23, C.Bus)
	b.PrimaryPart = body
	bp("Hood", 0, 3.2, -11.5, 7.6, 3.6, 4, C.Bus)
	bp("Roof", 0, 8.0, 1.5, 7.6, 0.5, 22.6, C.Bus:Lerp(C.White, 0.2))
	bp("Stripe", 0, 3.4, 1.5, 8.1, 0.4, 23.1, C.Black, { collide = false })
	bp("Stripe", 0, 2.6, 1.5, 8.1, 0.25, 23.1, C.Black, { collide = false })
	bp("WindowsL", -4.02, 6.2, 2.5, 0.1, 2, 19, C.Glass, { collide = false })
	bp("WindowsR", 4.02, 6.2, 2.5, 0.1, 2, 19, C.Glass, { collide = false })
	bp("Windshield", 0, 6.2, -9.95, 7, 2.6, 0.1, C.Glass, { collide = false })
	bp("Bumper", 0, 1.6, -13.6, 8, 0.8, 0.6, C.Black)
	bp("Bumper", 0, 1.6, 13.1, 8, 0.8, 0.6, C.Black)
	bp("Headlight", -2.6, 3.6, -13.55, 1, 1, 0.1, C.Lamp, { neon = true, collide = false })
	bp("Headlight", 2.6, 3.6, -13.55, 1, 1, 0.1, C.Lamp, { neon = true, collide = false })
	bp("StopArm", -4.4, 5.6, -7, 0.2, 1.6, 1.6, C.Red, { collide = false })
	for _, w in { { -3.8, -9 }, { 3.8, -9 }, { -3.8, 8 }, { 3.8, 8 } } do
		part(b, "Wheel", cf * CFrame.new(w[1], 1.5, w[2]), v(1.2, 3, 3), C.Black, { shape = Cyl })
	end
	local sign = bp("BusSign", 0, 8.6, -9.6, 6, 1, 0.2, C.Bus, { collide = false })
	label(sign, Enum.NormalId.Front, "SCHOOL BUS", C.Black, Enum.Font.LuckiestGuy)
	MapKit.googlyEyes(b, O * cf * CFrame.new(0, 4.6, -13.7), 1.6, 1.4)
end

local function outside(model: Model, rng: Random)
	local s = folder(model, "Outside")
	-- ground
	rect(s, "Ground", -200, 200, -200, 200, 0, 2, C.Grass)
	rect(s, "FrontLawn", -90, 90, 30, 42, 0.3, 0.6, C.Lawn)
	rect(s, "Road", -200, 200, 48, 64, 0.12, 0.6, C.Asphalt)
	rect(s, "Sidewalk", -200, 200, 42, 48, 0.6, 1, C.Sidewalk)
	rect(s, "Sidewalk", -200, 200, 64, 70, 0.6, 1, C.Sidewalk)
	rect(s, "Kerb", -200, 200, 47.2, 48, 0.66, 1, C.Kerb)
	rect(s, "Kerb", -200, 200, 64, 64.8, 0.66, 1, C.Kerb)
	for x = -196, 196, 10 do
		if math.abs(x - 36) > 16 and math.abs(x + 12) > 6 then
			box(s, "LaneDash", x, 0.12, 56, 5, 0.2, 0.5, C.LineYellow, { collide = false })
		end
	end
	box(s, "EdgeLine", 0, 0.12, 49.2, 400, 0.2, 0.4, C.Trim, { collide = false })
	box(s, "EdgeLine", 0, 0.12, 62.8, 400, 0.2, 0.4, C.Trim, { collide = false })
	for k = 0, 4 do
		box(s, "Zebra", -12, 0.13, 49.6 + k * 3.2, 6, 0.2, 1.6, C.White, { collide = false })
	end
	local slow = box(s, "SchoolText", -30, 0.14, 59, 14, 0.1, 4, C.Asphalt, { collide = false, transparency = 1 })
	label(slow, Enum.NormalId.Top, "SCHOOL", C.White, Enum.Font.LuckiestGuy)
	-- entrance path, steps, canopy, sign
	rect(s, "Path", -16, -8, 30, 42, 0.62, 0.2, C.Concrete)
	box(s, "Step", -12, 0.8, 30.6, 10, 0.4, 1.2, C.Concrete)
	box(s, "Canopy", -12, 11.2, 33, 16, 0.6, 7, C.TealDark)
	for _, cx in { -19, -5 } do
		cylY(s, "Column", cx, 0.6, 35.8, 10.3, 1, C.Trim)
	end
	local sign = box(s, "SchoolSign", -12, 12.8, 36.3, 15, 2.4, 0.4, C.Bus, { collide = false })
	label(sign, Enum.NormalId.Back, "MAPLE ELEMENTARY", C.TealDark, Enum.Font.LuckiestGuy)
	local mascot = box(s, "Mascot", -12, 15.5, 30.1, 6, 3, 0.2, C.Red, { collide = false })
	label(mascot, Enum.NormalId.Back, "HOME OF THE FIREFLIES", C.White, Enum.Font.FredokaOne)
	-- flagpole + flag
	cylY(s, "FlagBase", 6, 0.3, 38, 0.8, 2.4, C.Concrete)
	cylY(s, "Flagpole", 6, 1.1, 38, 22, 0.4, C.Chrome)
	ball(s, "FlagTop", 6, 23.3, 38, 0.7, C.Gold)
	box(s, "Flag", 8.1, 21, 38, 4, 2.6, 0.1, C.Teal, { collide = false })
	box(s, "FlagStripe", 8.1, 21, 38.06, 4, 0.6, 0.05, C.Mustard, { collide = false })
	-- bike rack + bench + flower beds
	for i = 0, 4 do
		part(s, "BikeHoop", CFrame.new(-34 + i * 1.6, 1.6, 36.5) * CFrame.Angles(0, math.pi / 2, 0) * UPRIGHT, v(0.2, 2.4, 2.4), C.Teal, { shape = Cyl, collide = false })
	end
	box(s, "BikeRackRail", -30.8, 0.75, 36.5, 7.6, 0.3, 0.3, C.Iron)
	prop("bench", s, at(18, 0.3, 36, 180), { length = 6 })
	for _, fb in { { -40, 31.6 }, { 16, 31.6 }, { 30, 31.6 } } do
		box(s, "FlowerBed", fb[1], 0.7, fb[2], 8, 0.8, 2.4, C.Trunk:Lerp(C.Black, 0.3))
		for i = 1, 4 do
			ball(s, "Flower", fb[1] - 4 + i * 1.6, 1.5, fb[2], 1.1, KID_COLORS[(i % #KID_COLORS) + 1], { collide = false })
		end
	end
	for _, t in { { -60, 37 }, { 52, 38 }, { 74, 38 }, { -80, 10 }, { 90, -24 }, { -80, -20 } } do
		prop("tree", s, at(t[1], 0.3, t[2], rng:NextInteger(0, 359)), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	-- school bus parked at the kerb (south lane), heading east
	schoolBus(s, at(-58, 0.12, 92, -90)) -- clear of the entrance road (it used to park across it)
	-- street lamps, hydrants, school zone sign
	for _, lx in { -150, -100, -50, 10, 60, 110, 160 } do
		prop("streetLamp", s, at(lx, 0.6, 46.4, 180))
	end
	for _, lx in { -170, -120, -70, -20, 30, 80, 130, 180 } do
		prop("streetLamp", s, at(lx, 0.6, 65.6, 0))
	end
	for i, hp in { { -30, 46.6 }, { 56, 46.6 }, { 100, 65.4 } } do
		local h = MapKit.hydrant(s, O * CFrame.new(hp[1], 0.6, hp[2]))
		h.Name = `H{i}`
		h:SetAttribute("HydrantId", `H{i}`)
	end
	box(s, "ZonePost", -76, 4.2, 46.4, 0.3, 7.2, 0.3, C.Iron)
	local zs = part(s, "ZoneSign", CFrame.new(-76, 7.4, 46.2) * CFrame.Angles(0, 0, math.rad(45)), v(2.6, 2.6, 0.2), C.Mustard, { collide = false })
	local zl = box(s, "ZoneText", -76, 7.4, 46.05, 2.6, 1.4, 0.05, C.Mustard, { collide = false, transparency = 1 })
	label(zl, Enum.NormalId.Back, "SCHOOL\nZONE", C.Black, Enum.Font.FredokaOne)
	local _ = zs

	-- playground behind the school
	local pg = folder(s, "Playground")
	rect(pg, "Sandpit", -60, -20, -64, -36, 0.35, 0.7, C.Sand)
	-- slide: tower + ladder + chute
	for _, c in { { -54, -58 }, { -50, -58 }, { -54, -54 }, { -50, -54 } } do
		box(pg, "TowerPost", c[1], 4, c[2], 0.6, 8, 0.6, C.Red)
	end
	box(pg, "TowerDeck", -52, 6, -56, 5, 0.5, 5, C.Mustard)
	box(pg, "TowerRoof", -52, 8.3, -56, 5.6, 0.4, 5.6, C.Teal)
	part(pg, "Chute", CFrame.new(-52, 3.3, -48.2) * CFrame.Angles(math.rad(32), 0, 0), v(2.6, 0.4, 11), C.Blue)
	local lad = Instance.new("TrussPart")
	lad.Name = "SlideLadder"
	lad.Anchored = true
	lad.Size = v(2, 6, 2)
	lad.CFrame = O * CFrame.new(-52, 3.35, -59.6)
	lad.Color = C.Steel
	lad.Parent = pg
	-- swings
	box(pg, "SwingBar", -32, 9, -50, 14, 0.6, 0.6, C.Teal)
	for _, sx in { -38.6, -25.4 } do
		part(pg, "SwingLeg", CFrame.new(sx, 4.5, -50) * CFrame.Angles(math.rad(18), 0, 0), v(0.6, 9.4, 0.6), C.Teal)
		part(pg, "SwingLeg", CFrame.new(sx, 4.5, -50) * CFrame.Angles(math.rad(-18), 0, 0), v(0.6, 9.4, 0.6), C.Teal)
	end
	for i, sx in { -35, -29 } do
		box(pg, "SwingChain", sx - 0.8, 5.6, -50, 0.15, 6.2, 0.15, C.Steel, { collide = false })
		box(pg, "SwingChain", sx + 0.8, 5.6, -50, 0.15, 6.2, 0.15, C.Steel, { collide = false })
		box(pg, "SwingSeat", sx, 2.4, -50, 2, 0.3, 1, if i == 1 then C.Red else C.Mustard)
	end
	-- seesaw
	box(pg, "SeesawPivot", -26, 1.2, -40, 1, 1.6, 1, C.Steel)
	part(pg, "Seesaw", CFrame.new(-26, 1.9, -40) * CFrame.Angles(0, 0, math.rad(12)), v(10, 0.4, 1.2), C.Pink)
	-- back fence + hopscotch on the asphalt
	rect(pg, "Blacktop", -16, 30, -66, -36, 0.3, 0.6, C.AsphaltDark)
	for i = 1, 6 do
		box(pg, "Hopscotch", -6, 0.32, -40 - i * 2.2, 2, 0.05, 2, KID_COLORS[i], { collide = false })
	end
	for i = 0, 5 do
		prop("fence", pg, at(-56 + i * 16, 0, -72, 0), { length = 16, style = "picket" })
	end

	-- playing field across the road
	local fd = folder(s, "Field")
	for i = 0, 6 do -- mown stripes
		box(fd, "Pitch", 0, 0.0, 85 + i * 10, 140, 0.5, 10, if i % 2 == 0 then C.Lawn else C.Lawn:Lerp(C.Grass, 0.35))
	end
	box(fd, "Line", 0, 0.27, 80.5, 140, 0.05, 0.5, C.White, { collide = false })
	box(fd, "Line", 0, 0.27, 149.5, 140, 0.05, 0.5, C.White, { collide = false })
	box(fd, "Line", -69.5, 0.27, 115, 0.5, 0.05, 70, C.White, { collide = false })
	box(fd, "Line", 69.5, 0.27, 115, 0.5, 0.05, 70, C.White, { collide = false })
	box(fd, "Line", 0, 0.27, 115, 0.5, 0.05, 70, C.White, { collide = false })
	cylY(fd, "Circle", 0, 0.25, 115, 0.04, 18, C.White, { collide = false })
	cylY(fd, "CircleIn", 0, 0.26, 115, 0.04, 17, C.Lawn, { collide = false })
	for _, gx in { -68, 68 } do
		local sgn = if gx < 0 then -1 else 1
		box(fd, "GoalPost", gx, 3.25, 109, 0.5, 6.5, 0.5, C.White)
		box(fd, "GoalPost", gx, 3.25, 121, 0.5, 6.5, 0.5, C.White)
		box(fd, "Crossbar", gx, 6.5, 115, 0.5, 0.5, 12.5, C.White)
		box(fd, "Net", gx + sgn * 2, 3.25, 115, 0.2, 6.5, 12, C.White, { transparency = 0.6, collide = false })
	end
	for _, t in { { -90, 90 }, { -90, 130 }, { 90, 95 }, { 90, 135 }, { -40, 165 }, { 30, 165 } } do
		prop("tree", fd, at(t[1], 0.3, t[2], rng:NextInteger(0, 359)), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	-- parking lot east of the gym
	local pk = folder(s, "Parking")
	rect(pk, "Lot", 92, 150, -10, 40, 0.3, 0.6, C.AsphaltDark)
	for i = 0, 5 do
		box(pk, "Bay", 96 + i * 9, 0.32, 10, 0.4, 0.05, 12, C.White, { collide = false })
	end
	prop("car", pk, at(100.5, 0.3, 12, 180), { color = C.Teal })
	prop("car", pk, at(118.5, 0.3, 12, 180), { color = C.Mustard, eyes = true })
	prop("car", pk, at(127.5, 0.3, 12, 180), { color = C.Lilac })

	-- simple neighbour houses either side
	for _, hx in { -150, -118, 162, 186 } do
		local hcol = KID_COLORS[rng:NextInteger(1, #KID_COLORS)]:Lerp(C.White, 0.45)
		local hm = folder(s, "House")
		box(hm, "HouseBody", hx, 6, 18, 22, 12, 18, hcol)
		local rw = Instance.new("WedgePart")
		rw.Name = "Roof"
		rw.Anchored = true
		rw.Size = v(23, 6, 10)
		rw.CFrame = O * CFrame.new(hx, 15, 22.5) * CFrame.Angles(0, math.pi, 0)
		rw.Color = C.Wood:Lerp(C.Black, 0.3)
		rw.Parent = hm
		local rw2 = Instance.new("WedgePart")
		rw2.Name = "Roof"
		rw2.Anchored = true
		rw2.Size = v(23, 6, 10)
		rw2.CFrame = O * CFrame.new(hx, 15, 13.5)
		rw2.Color = C.Wood:Lerp(C.Black, 0.3)
		rw2.Parent = hm
		box(hm, "HouseDoor", hx, 3.5, 27.05, 4, 7, 0.2, C.Wood, { collide = false })
		box(hm, "HouseWin", hx - 6, 6, 27.05, 4, 4, 0.2, C.Glass, { collide = false })
		box(hm, "HouseWin", hx + 6, 6, 27.05, 4, 4, 0.2, C.Glass, { collide = false })
		prop("bush", hm, at(hx - 8, 0, 30, 0), { flammable = false })
	end
end

------------------------------------------------------------------------------------------------
-- Scene markers + extras
------------------------------------------------------------------------------------------------
local function scene(model: Model)
	local sc = folder(model, "Scene")
	-- TruckSpot: north lane in front of the gym, truck 67 nose west (-X)
	local spot = Vector3.new(36, 0.22, 53)
	local ts = part(sc, "TruckSpot", CFrame.lookAt(spot, spot + Vector3.new(-1, 0, 0)), v(10, 0.2, 26), C.Red, { transparency = 1, collide = false, tags = { TAG_TRUCKSPOT } })
	ts.CanQuery = false
	ts:SetAttribute(Names.Attr.LocationId, SchoolBuilder.Id)
	box(sc, "FireLaneKerb", 36, 0.7, 47.6, 28, 0.1, 0.8, C.Red, { collide = false })
	-- PlayerSpawn on the front lawn beside it, facing the school
	local ps = part(sc, "PlayerSpawn", CFrame.lookAt(v(36, 0.75, 38), v(36, 0.75, 20)), v(12, 0.2, 7), C.Teal, { transparency = 1, collide = false, tags = { TAG_PLAYERSPAWN } })
	ps.CanQuery = false
	ps:SetAttribute(Names.Attr.LocationId, SchoolBuilder.Id)
	-- evacuated class lined up on the field side of the road with their teacher (display only)
	local by = folder(sc, "Bystanders")
	for i = 0, 3 do
		npc("Civilian", by, at(-40 + i * 3.2, 0.6, 67.6, 0), { color = KID_COLORS[(i % #KID_COLORS) + 1] })
	end
	npc("Civilian", by, at(-46, 0.6, 67.6, 20), { color = C.TealDark })
end

------------------------------------------------------------------------------------------------
-- Build
------------------------------------------------------------------------------------------------
function SchoolBuilder.Build(model: Model, origin: CFrame, rng: Random)
	O = origin
	local mapDir = script.Parent.Parent
	PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	local libDir = mapDir.Parent
	NpcBuilder = tryRequire(libDir and libDir:FindFirstChild("Rescue"), "NpcBuilder")

	model:SetAttribute("DisplayName", "Maple Elementary")
	model:SetAttribute("Atmosphere", "Default")

	outside(model, rng)
	local bld = folder(model, "School")
	bld:SetAttribute(Names.Attr.BuildingId, BID)
	local gym = folder(model, "Gym")
	gym:SetAttribute(Names.Attr.BuildingId, GYM_BID)
	shell(model, bld, gym)
	hallway(bld, rng)
	local c1, c3 = northRooms(bld, rng)
	local f1 = kitchenAndCafe(bld, rng)
	lobbyOfficeClass4(bld, rng)
	local f3 = gymInterior(gym)
	scene(model)

	fireStart(f1, "F1", BID)
	fireStart(c3.desk, "F2", BID)
	fireStart(f3, "F3", GYM_BID)

	-- rescues: a kid hiding under a desk in Class 1, a kid frozen by the lockers, a kid in the
	-- cafeteria, the teacher knocked out on the stage, and the class cat in Class 3
	local rs = folder(bld, "RescueSpawns")
	local hide = c1.desks[#c1.desks]
	rescueSpawn(rs, "R1", "Civilian", "Kid", BID, at(hide.X, FY, hide.Z - 0.2, 0), "sitting")
	rescueSpawn(rs, "R2", "Civilian", "Kid", BID, at(-48, FY, 5.2, 90), "stand")
	rescueSpawn(rs, "R3", "Civilian", "Kid", BID, at(-23, FY, 20, -90), "stand")
	rescueSpawn(rs, "R4", "Civilian", "Teacher", GYM_BID, at(56, FY + 3.5, -21, 90), "lying")
	rescueSpawn(rs, "R5", "Cat", "ClassPet", BID, at(-5, FY + 3.8, -24.5, 180), "sitting")

	bld.PrimaryPart = bld:FindFirstChild("HallFloor") :: BasePart?
end

return SchoolBuilder
