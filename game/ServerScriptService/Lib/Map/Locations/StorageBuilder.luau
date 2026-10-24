-- StorageBuilder [owner: G2]. STOR-MOR SELF STORAGE: the trailer's storage units (t=48-49,
-- docs/game/05 §2.3): red roll-up doors, a fuse box with a lever and a warning sign, a puddle with a
-- live cable in it (the electrocution gag), garage fires inside the units.
-- Slot 6. Local frame: origin = slot centre on the ground, +X east, +Z south (unit fronts face +Z,
-- toward the default preview camera). Every gameplay hook is found by tag/attribute.
--   Road Z 110..126, driveway + gate X -12..12 at the front fence Z 96, lot X -100..100 Z -50..96.
--   Strip A (U1..U8): X -48..48, units Z -22..-10, fronts face +Z. Locked (axe): U2, U5, U7.
--   Strip B (B1..B5): X 64..76, Z -34..26, fronts face -X. B3 = open garage.
--   Strip C (C1..C5): X -88..-76, Z 26..-34, fronts face +X (decor + two open units).
--   Fuse box at the west end of strip A (-54, -4); wet floor + live cable on the apron in front of U1..U3.
--   Office by the gate (X -66..-40, Z 58..80).
-- Fire starts F1..F4 (tag FireStart on a Flammable part, attr FireId + BuildingId): U3 paint shelf,
--   U5 fireworks crate, U7 mattress, B3 garage workbench.
-- Rescue spawns (invisible 2x2x2, tag RescueSpawn, attr Kind/SpawnId/BuildingId/Pose; -Z = facing):
--   R1 Civilian in U5 ("was looking for his fireworks"), R2 Dog in U7.
-- FuseBox: tag FuseBox, attr Power = true (live), child part "Lever"; HazardService adds the breaker
--   prompt and zaps anyone on a WetFloor puddle while it is live. FLAMMABLE drums = Hazard "explosion".
-- WetFloor: 5 puddle discs (tag WetFloor). The live cable ends in "LiveWire" (attr LiveWire = true).
-- TruckSpot (attr LocationId, LookVector = truck forward) and PlayerSpawn (attr LocationId) markers.
-- PropKit is optional: every prop call falls back to a local box model (or is skipped).
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local StorageBuilder = {}
StorageBuilder.Id = "Storage"
StorageBuilder.Slot = 6

local TAG: any = Names.Tag
local T_TRUCKSPOT = TAG.TruckSpot or "TruckSpot"
local T_PLAYERSPAWN = TAG.PlayerSpawn or "PlayerSpawn"
local T_HAZARD = TAG.Hazard or "Hazard"
local A_HAZARDID = (Names.Attr :: any).HazardId or "HazardId"
local A_POWER = (Names.Attr :: any).Power or "Power"
local BID = "Storage"

local hex = Color3.fromHex
local C = {
	Grass = hex("#6E8C3E"),
	Verge = hex("#8AAF4A"),
	Asphalt = hex("#4A4650"),
	Lot = hex("#5A5660"),
	LineYellow = hex("#E3B23C"),
	LineWhite = hex("#F2EDE4"),
	Wall = hex("#E3D3B8"),
	WallB = hex("#D9C29E"),
	Plinth = hex("#B3A291"),
	Floor = hex("#B8B2A6"),
	Plywood = hex("#C9A06A"),
	Roof = hex("#4E4A5A"),
	Fascia = hex("#2A9D8F"),
	DoorRed = hex("#C8232B"),
	DoorRib = hex("#A51C24"),
	Drum = hex("#8E1A20"),
	Chrome = hex("#D6D8DC"),
	Steel = hex("#8A8C90"),
	SteelDark = hex("#3A3A40"),
	Mustard = hex("#E9C46A"),
	Terracotta = hex("#E76F51"),
	Teal = hex("#2A9D8F"),
	TealDark = hex("#2F5F5A"),
	Cream = hex("#FFF1D6"),
	Box = hex("#C9A06A"),
	Box2 = hex("#B98E57"),
	Tape = hex("#E8D3A8"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	FuseRed = hex("#C0342A"),
	Warn = hex("#FFC531"),
	Ink = hex("#1A1210"),
	Puddle = hex("#7FC8D8"),
	Electric = hex("#7FF5F0"),
	Lamp = hex("#FFC97A"),
	Black = hex("#1A1714"),
	White = hex("#F7F4EE"),
	Pink = hex("#FF7FB0"),
	Blue = hex("#3F6FB0"),
	Leaf = hex("#6F9A3A"),
	Trunk = hex("#7A3A1E"),
	Fence = hex("#9AA0A6"),
	Mattress = hex("#DCE6EE"),
	Stripe = hex("#9EC1CC"),
}

local CYL, BALL = Enum.PartType.Cylinder, Enum.PartType.Ball
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- cylinder axis X -> Y
local ALONG_Z = CFrame.Angles(0, math.pi / 2, 0) -- cylinder axis X -> Z

-- Build-time context (Build is synchronous; set at the top of Build).
local O: CFrame = CFrame.identity
local PropKit: any = nil

local function V(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- Slot-local CFrame at (x,y,z) whose -Z (front) faces direction (dx, 0, dz).
local function facing(x: number, y: number, z: number, dx: number, dz: number): CFrame
	local p = V(x, y, z)
	return CFrame.lookAt(p, p + V(dx, 0, dz))
end

-- Every cf below is slot-local; O is applied here.
local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, opts: { [string]: any }?): Part
	local o: any = if opts then table.clone(opts) else {}
	o.color = color
	if o.flammable == nil then
		o.flammable = false
	end
	return MapKit.part(parent, name, O * cf, size, o)
end

local function cyl(parent: Instance, name: string, cf: CFrame, axis: string, length: number, dia: number, color: Color3, opts: { [string]: any }?): Part
	local rot = if axis == "y" then UPRIGHT elseif axis == "z" then ALONG_Z else CFrame.identity
	local o: any = if opts then table.clone(opts) else {}
	o.shape = CYL
	return part(parent, name, cf * rot, V(length, dia, dia), color, o)
end

local function ball(parent: Instance, name: string, cf: CFrame, dia: number, color: Color3, opts: { [string]: any }?): Part
	local o: any = if opts then table.clone(opts) else {}
	o.shape = BALL
	return part(parent, name, cf, Vector3.one * dia, color, o)
end

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

-- Text on the Front (-Z) face of a part.
local function label(p: BasePart, text: string, color: Color3, stroke: Color3?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
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

-- Sign board w x h at cf (its -Z faces the reader), with text.
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

-- cf = ground/seat point (slot-local), facing -Z; the marker centre is 1 stud above it.
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

-- Straight run of <= 8-stud chunks from a to b (base points, slot-local), height h, 1 thick.
local function wallRun(parent: Instance, name: string, a: Vector3, b: Vector3, h: number, color: Color3, opts: { [string]: any }?)
	local d = b - a
	local len = d.Magnitude
	if len < 0.05 or h < 0.05 then
		return
	end
	local dir = d.Unit
	local n = math.max(1, math.ceil(len / 8 - 1e-6))
	for i = 1, n do
		local mid = a + dir * ((i - 0.5) * len / n) + V(0, h / 2, 0)
		part(parent, `{name}_{i}`, CFrame.lookAt(mid, mid + dir), V(1, h, len / n), color, opts)
	end
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
	warn(`[StorageBuilder] {name} unavailable: {if ok then "not a table" else mod}`)
	return nil
end

-- PropKit call (cf slot-local ground point, prop faces -Z). Falls back to `fallback` if given.
local function prop(kind: string, parent: Instance, cf: CFrame, opts: { [string]: any }?, fallback: (() -> ())?)
	if PropKit and type(PropKit[kind]) == "function" then
		local ok, err = pcall(PropKit[kind], parent, O * cf, opts)
		if ok then
			return
		end
		warn(`[StorageBuilder] PropKit.{kind} failed: {err}`)
	end
	if fallback then
		fallback()
	end
end

------------------------------------------------------------------------------------------------
-- Small props
------------------------------------------------------------------------------------------------

-- Cardboard box sitting on cf (ground point). Flammable.
local function cbox(parent: Instance, cf: CFrame, sx: number, sy: number, sz: number, alt: boolean?): Part
	local b = part(parent, "Box", cf * CFrame.new(0, sy / 2, 0), V(sx, sy, sz), if alt then C.Box2 else C.Box, { flammable = true, fuel = 20 })
	part(parent, "Tape", cf * CFrame.new(0, sy + 0.03, 0), V(0.5, 0.06, sz + 0.02), C.Tape, { collide = false })
	return b
end

local function boxStack(parent: Instance, cf: CFrame)
	cbox(parent, cf * CFrame.new(-0.9, 0, 0), 2.6, 2.2, 2.4)
	cbox(parent, cf * CFrame.new(1.4, 0, 0.2), 2, 1.8, 2, true)
	cbox(parent, cf * CFrame.new(-0.6, 2.2, 0) * CFrame.Angles(0, 0.2, 0), 2.2, 1.8, 2)
	cbox(parent, cf * CFrame.new(1.3, 1.8, 0.1) * CFrame.Angles(0, -0.15, 0), 1.6, 1.4, 1.6, true)
end

-- Oil drum. A "FLAMMABLE" one is its own Model tagged Hazard (HazardId "explosion"): HazardService
-- blows it (and destroys just this Model) when fire sits next to it.
local function drum(parent: Instance, cf: CFrame, color: Color3, text: string?)
	if text then
		local holder = folder(parent, "GasDrum")
		CollectionService:AddTag(holder, T_HAZARD)
		holder:SetAttribute(A_HAZARDID, "explosion")
		parent = holder
	end
	local d = cyl(parent, "OilDrum", cf * CFrame.new(0, 1.6, 0), "y", 3.2, 2.2, color)
	if text then
		(parent :: Model).PrimaryPart = d
	end
	part(parent, "DrumRing", cf * CFrame.new(0, 1.0, 0) * UPRIGHT, V(0.2, 2.3, 2.3), C.SteelDark, { shape = CYL, collide = false })
	part(parent, "DrumRing", cf * CFrame.new(0, 2.2, 0) * UPRIGHT, V(0.2, 2.3, 2.3), C.SteelDark, { shape = CYL, collide = false })
	if text then
		local s = part(parent, "DrumLabel", cf * CFrame.new(0, 1.6, -1.12), V(1.4, 0.8, 0.05), C.Warn, { collide = false })
		label(s, text, C.Ink)
	end
	return d
end

local function bike(parent: Instance, cf: CFrame, color: Color3)
	for _, z in { -1.3, 1.3 } do
		part(parent, "Wheel", cf * CFrame.new(0, 1.1, z), V(0.25, 2.2, 2.2), C.Black, { shape = CYL, collide = false })
	end
	part(parent, "Frame", cf * CFrame.new(0, 1.6, 0) * CFrame.Angles(math.rad(-20), 0, 0), V(0.25, 0.25, 2.6), color, { collide = false })
	part(parent, "Seat", cf * CFrame.new(0, 2.5, 0.6), V(0.4, 0.25, 0.8), C.Black, { collide = false })
	part(parent, "Bars", cf * CFrame.new(0, 2.5, -1.1), V(1.4, 0.2, 0.2), C.Chrome, { collide = false })
	part(parent, "Stem", cf * CFrame.new(0, 1.9, -1.15), V(0.2, 1.2, 0.2), color, { collide = false })
end

local function shelf(parent: Instance, cf: CFrame, w: number): Part
	local top: Part
	for k, y in { 0.6, 2.4, 4.2 } do
		local b = part(parent, "ShelfBoard", cf * CFrame.new(0, y, 0), V(w, 0.3, 1.6), C.WoodLight, { flammable = true, fuel = 25 })
		if k == 2 then
			top = b
		end
	end
	for _, x in { -w / 2 + 0.2, w / 2 - 0.2 } do
		part(parent, "ShelfPost", cf * CFrame.new(x, 2.4, 0), V(0.3, 4.8, 1.6), C.Wood, { flammable = true })
	end
	return top :: Part
end

local function fallbackSofa(parent: Instance, cf: CFrame, color: Color3)
	part(parent, "Sofa", cf * CFrame.new(0, 0.9, 0.1), V(7, 1.8, 2.8), color, { flammable = true })
	part(parent, "SofaBack", cf * CFrame.new(0, 2.3, 1.1), V(7, 2.8, 0.8), color:Lerp(C.Black, 0.15), { flammable = true })
end

------------------------------------------------------------------------------------------------
-- Unit strip. F = strip frame (slot-local): units run along +X from 0 to 12n, depth z -12 (back)
-- .. 0 (front), fronts face +Z of F.
------------------------------------------------------------------------------------------------
local UW, UH = 12, 10 -- unit width, wall height
local FL = 0.5 -- unit floor top

type DoorKind = "open" | "closed" | "locked"

local function rollUpClosed(parent: Instance, F: CFrame, cx: number): Part
	local d = part(parent, "RollUpDoor", F * CFrame.new(cx, FL + 4.1, -0.2), V(10.4, 8.2, 0.4), C.DoorRed, { material = Enum.Material.Metal })
	for k = 1, 5 do
		part(d, "Rib", F * CFrame.new(cx, FL + k * 1.4, 0.06), V(10.2, 0.22, 0.22), C.DoorRib, { collide = false })
	end
	part(d, "Handle", F * CFrame.new(cx, FL + 0.7, 0.1), V(2.4, 0.3, 0.3), C.Chrome, { collide = false })
	return d
end

local function unitDoor(m: Model, F: CFrame, i: number, kind: DoorKind, name: string)
	local cx = UW * (i - 0.5)
	if kind == "open" then
		cyl(m, "DoorDrum", F * CFrame.new(cx, FL + 7.7, -0.9), "x", 10.4, 1.3, C.Drum)
		part(m, "DoorBar", F * CFrame.new(cx, FL + 7.1, -0.35), V(10.4, 0.6, 0.4), C.DoorRed)
	elseif kind == "closed" then
		rollUpClosed(m, F, cx)
	else
		-- Locked roll-up = a MapKit Door (axe to break), resized to the 10.4 x 8.2 opening.
		local d = MapKit.door(m, name, O * F * CFrame.new(cx, FL + 4.1, -0.2), true)
		d.Size = V(10.4, 8.2, 0.5)
		d.CFrame = O * F * CFrame.new(cx, FL + 4.1, -0.2)
		d.Color = C.DoorRed
		d.Material = Enum.Material.Metal
		d:SetAttribute(Names.Attr.BuildingId, BID)
		local prompt = d:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.ObjectText = `Unit {name}`
			prompt.MaxActivationDistance = 10
		end
		-- ribs + padlock ride on the door part so they vanish with it when it breaks
		for k = 1, 5 do
			part(d, "Rib", F * CFrame.new(cx, FL + k * 1.4, 0.1), V(10.2, 0.22, 0.22), C.DoorRib, { collide = false })
		end
		part(d, "Hasp", F * CFrame.new(cx, FL + 0.8, 0.12), V(1.4, 0.4, 0.2), C.Steel, { collide = false })
		part(d, "Padlock", F * CFrame.new(cx, FL + 0.4, 0.3), V(0.8, 0.9, 0.4), C.Mustard, { collide = false, material = Enum.Material.Metal })
		part(d, "Shackle", F * CFrame.new(cx, FL + 1.0, 0.3), V(0.5, 0.4, 0.15), C.Chrome, { collide = false })
	end
end

local function strip(parent: Instance, F: CFrame, n: number, prefix: string, wallColor: Color3, doors: { DoorKind }, bulbs: { [number]: boolean }): Model
	local m = folder(parent, `{prefix}Strip`)
	m:SetAttribute(Names.Attr.BuildingId, BID)
	local W = n * UW
	-- floor, plinth step, back + end walls (block, not flammable), plywood partitions (flammable)
	part(m, "UnitFloor", F * CFrame.new(W / 2, FL - 0.35, -6), V(W, 0.7, 12), C.Floor)
	part(m, "BackWall", F * CFrame.new(W / 2, FL + UH / 2, -12.5), V(W + 2, UH, 1), wallColor)
	part(m, "Plinth", F * CFrame.new(W / 2, 0.6, -13.1), V(W + 2.4, 1.2, 0.3), C.Plinth)
	for _, ex in { -0.5, W + 0.5 } do
		part(m, "EndWall", F * CFrame.new(ex, FL + UH / 2, -6.5), V(1, UH, 13), wallColor)
		part(m, "EndPlinth", F * CFrame.new(ex + (if ex < 0 then -0.6 else 0.6), 0.6, -6.5), V(0.3, 1.2, 13.2), C.Plinth)
	end
	for k = 1, n - 1 do
		local x = UW * k
		wallRun(m, "Partition", (F * CFrame.new(x, FL, -12)).Position, (F * CFrame.new(x, FL, -0.7)).Position, UH, C.Plywood, { flammable = true, fuel = 30 })
	end
	-- facade: pilasters, door headers, unit numbers, wall-pack lamps
	for k = 0, n do
		part(m, "Pilaster", F * CFrame.new(UW * k, (FL + UH) / 2, -0.1), V(1.6, FL + UH, 1.2), wallColor)
		local pack = part(m, "WallPack", F * CFrame.new(UW * k, FL + 8.9, 0.75), V(0.9, 0.6, 0.5), C.Lamp, { neon = true, collide = false })
		if k % 2 == 0 then
			light(pack, C.Lamp, 16, 0.9)
		end
	end
	for i = 1, n do
		local cx = UW * (i - 0.5)
		part(m, "Header", F * CFrame.new(cx, FL + 9.1, -0.2), V(10.4, 1.8, 0.8), wallColor)
		sign(m, "UnitNumber", F * CFrame.new(cx, FL + 9.1, 0.42) * CFrame.Angles(0, math.pi, 0), 2.6, 1.3, C.Mustard, `{prefix}{i}`, C.Ink)
		unitDoor(m, F, i, doors[i], `{prefix}{i}`)
		if bulbs[i] then
			part(m, "BulbCord", F * CFrame.new(cx, FL + UH - 0.6, -6), V(0.2, 1.2, 0.2), C.Black, { collide = false })
			local bulb = ball(m, "Bulb", F * CFrame.new(cx, FL + UH - 1.5, -6), 0.8, C.Lamp, { neon = true, collide = false })
			light(bulb, C.Lamp, 14, 0.8)
		end
	end
	-- roof slab, teal fascia, gutter + downspouts
	part(m, "Roof", F * CFrame.new(W / 2, FL + UH + 0.5, -6), V(W + 3, 1, 15.5), C.Roof)
	part(m, "Fascia", F * CFrame.new(W / 2, FL + UH + 0.5, 1.85), V(W + 3.2, 1.6, 0.4), C.Fascia)
	part(m, "Gutter", F * CFrame.new(W / 2, FL + UH - 0.4, 2.1), V(W + 3, 0.4, 0.5), C.Steel, { collide = false })
	for _, dx in { -1.2, W + 1.2 } do
		part(m, "Downspout", F * CFrame.new(dx, (FL + UH) / 2, 2.1), V(0.5, FL + UH, 0.5), C.Steel, { collide = false })
	end
	return m
end

-- Unit-local CFrame: unit i of strip F, x across the unit (-5.5..5.5), z from back (-5.5) to front
-- (5.4), y above the unit floor, yaw in degrees.
local function U(F: CFrame, i: number, x: number, y: number, z: number, yaw: number?): CFrame
	return F * CFrame.new(UW * (i - 0.5) + x, FL + y, -6 + z) * CFrame.Angles(0, math.rad(yaw or 0), 0)
end

------------------------------------------------------------------------------------------------
-- Unit contents (strip A + B3/B5)
------------------------------------------------------------------------------------------------
local function contentsA(m: Model, F: CFrame)
	local stuff = folder(m, "Contents")
	-- U1: junk room — sofa, boxes, bike
	prop("sofa", stuff, U(F, 1, 0, 0, -3.6, 180), { color = C.Teal }, function()
		fallbackSofa(stuff, U(F, 1, 0, 0, -3.6, 180), C.Teal)
	end)
	boxStack(stuff, U(F, 1, -3.4, 0, 1.6, 90))
	bike(stuff, U(F, 1, 4, 0, 1.2, 10), C.Terracotta)
	-- U2 (locked): fridge, boxes, standing lamp
	prop("fridge", stuff, U(F, 2, -3.8, 0, -4.2, 180), { color = C.Mustard }, function()
		part(stuff, "Fridge", U(F, 2, -3.8, 3, -4.2), V(3, 6, 2.6), C.Mustard)
	end)
	boxStack(stuff, U(F, 2, 2.4, 0, -3.8))
	cbox(stuff, U(F, 2, 2.6, 0, 0.6, 15), 3, 2, 2.4, true)
	-- U3 (open): paint store — shelf of paint cans, boxes, spilled paint. F1.
	local sh = shelf(stuff, U(F, 3, 0, 0, -4.6), 9)
	fireStart(sh, "F1", BID)
	local paints = { C.Terracotta, C.Teal, C.Mustard, C.Pink, C.Blue, C.White }
	for k = 0, 5 do
		for row, y in { 0.75, 2.55, 4.35 } do
			if (k + row) % 3 ~= 0 then
				cyl(stuff, "PaintCan", U(F, 3, -3.6 + k * 1.45, y + 0.6, -4.6), "y", 1.2, 1.1, paints[(k + row) % #paints + 1], { collide = false })
			end
		end
	end
	cbox(stuff, U(F, 3, -3.5, 0, 0.5, 20), 2.6, 2, 2.4)
	cbox(stuff, U(F, 3, -3.4, 2, 0.4, -10), 2, 1.6, 1.8, true)
	part(stuff, "PaintSpill", U(F, 3, 2, 0.05, 1.5) * UPRIGHT, V(0.1, 4.5, 4.5), C.Teal, { shape = CYL, collide = false })
	cyl(stuff, "PaintCanTipped", U(F, 3, 0.9, 0.55, 0.8, 30), "x", 1.2, 1.1, C.Teal, { collide = false })
	part(stuff, "Ladder", U(F, 3, 4.6, 3.2, -1, 0) * CFrame.Angles(math.rad(-12), 0, 0), V(1.8, 6.4, 0.3), C.Steel, { collide = false })
	-- U4 (open): the garage — old car, pegboard, drum
	prop("car", stuff, U(F, 4, 0, 0, 0, 180), { color = C.Mustard, eyes = true, flammable = true }, function()
		part(stuff, "Car", U(F, 4, 0, 1.9, -0.4), V(6, 2, 10), C.Mustard, { flammable = true })
		part(stuff, "CarTop", U(F, 4, 0, 3.7, 0.2), V(5.4, 1.8, 5.5), C.Mustard, { flammable = true })
	end)
	part(stuff, "Pegboard", U(F, 4, 0, 6.6, -5.8), V(8, 3.6, 0.2), C.Plywood, { flammable = true })
	for k = 0, 3 do
		part(stuff, "Tool", U(F, 4, -2.7 + k * 1.8, 6.7, -5.6), V(0.3, 2 - (k % 2) * 0.6, 0.2), if k % 2 == 0 then C.Terracotta else C.SteelDark, { collide = false })
	end
	drum(stuff, U(F, 4, -4.6, 0, 4), C.Blue)
	-- U5 (locked): fireworks stash + R1 civilian. F2.
	local crateColors = { C.DoorRed, C.Mustard, C.DoorRed, C.Teal }
	local crate: Part? = nil
	for k, spec in { { -3.2, -4, 0 }, { 0, -4.2, 8 }, { 3.2, -3.9, -6 }, { -2.2, -1.2, 25 } } do
		local cf = U(F, 5, spec[1], 0, spec[2], spec[3])
		local c = part(stuff, "FireworkCrate", cf * CFrame.new(0, 1.2, 0), V(2.8, 2.4, 2.4), crateColors[k], { flammable = true, fuel = 25 })
		part(stuff, "CrateStripe", cf * CFrame.new(0, 1.2, -1.22), V(2.82, 0.6, 0.05), C.White, { collide = false })
		if k == 2 then
			crate = c
			local s = part(stuff, "CrateLabel", cf * CFrame.new(0, 1.9, -1.24), V(2.6, 0.7, 0.05), C.Ink, { collide = false })
			label(s, "FIREWORKS", C.Warn)
		end
	end
	if crate then
		fireStart(crate, "F2", BID)
	end
	for k = 0, 4 do
		local cf = U(F, 5, -2.4 + k * 1.1, 2.4, -4.2)
		local col = if k % 2 == 0 then C.Pink else C.Blue
		cyl(stuff, "Rocket", cf * CFrame.new(0, 1.1, 0), "y", 2.2, 0.6, col, { collide = false })
		wedge(stuff, "RocketTip", cf * CFrame.new(0, 2.5, 0), V(0.6, 0.6, 0.6), C.Mustard)
	end
	rescueSpawn(stuff, "R1", "Civilian", BID, U(F, 5, 1.2, 0, 1.4, 0), "sitting")
	-- U6 (open): holiday decorations, snowman, bookshelf
	prop("bookshelf", stuff, U(F, 6, -3.2, 0, -4.8, 180), nil, function()
		part(stuff, "Bookshelf", U(F, 6, -3.2, 3.5, -4.8), V(4, 7, 1.4), C.Wood, { flammable = true })
	end)
	ball(stuff, "SnowmanBase", U(F, 6, 2.6, 1.6, -3), 3.2, C.White)
	ball(stuff, "SnowmanMid", U(F, 6, 2.6, 3.9, -3), 2.4, C.White)
	ball(stuff, "SnowmanHead", U(F, 6, 2.6, 5.6, -3), 1.7, C.White)
	part(stuff, "SnowmanNose", U(F, 6, 2.6, 5.6, -2.0), V(0.3, 0.3, 0.8), C.Terracotta, { collide = false })
	part(stuff, "SnowmanHat", U(F, 6, 2.6, 6.7, -3), V(1.2, 1.1, 1.2), C.Black, { collide = false })
	MapKit.googlyEyes(stuff, O * U(F, 6, 2.6, 5.9, -2.3, 180), 0.55)
	cbox(stuff, U(F, 6, 0, 0, 1.4, -8), 3.2, 1.8, 2.6)
	for k = 0, 4 do
		ball(stuff, "Ornament", U(F, 6, -0.9 + k * 0.45, 1.95, 1.3 + (k % 2) * 0.4), 0.5, if k % 2 == 0 then C.DoorRed else C.Mustard, { collide = false })
	end
	-- U7 (locked): bedroom store — mattress, dog bed, boxes. F3 + R2 dog.
	local mattress = part(stuff, "Mattress", U(F, 7, -3.6, 3.4, -4.4) * CFrame.Angles(math.rad(-14), 0, 0), V(4.4, 6.6, 1), C.Mattress, { flammable = true, fuel = 30 })
	for k = -1, 1 do
		part(stuff, "MattressStripe", U(F, 7, -3.6 + k * 1.3, 3.4, -4.4) * CFrame.Angles(math.rad(-14), 0, 0) * CFrame.new(0, 0, -0.52), V(0.3, 6.4, 0.05), C.Stripe, { collide = false })
	end
	fireStart(mattress, "F3", BID)
	boxStack(stuff, U(F, 7, 2.6, 0, -3.8))
	cyl(stuff, "DogBed", U(F, 7, 1.6, 0.3, 1.6), "y", 0.6, 3.6, C.Terracotta, { flammable = true })
	cyl(stuff, "DogBedCushion", U(F, 7, 1.6, 0.65, 1.6), "y", 0.2, 3, C.Cream, { collide = false })
	part(stuff, "DogBowl", U(F, 7, -1.4, 0.25, 3.6) * UPRIGHT, V(0.5, 1.2, 1.2), C.Blue, { shape = CYL, collide = false })
	rescueSpawn(stuff, "R2", "Dog", BID, U(F, 7, 1.6, 0.7, 1.6, 0), "sitting")
	-- U8 (open): band gear — drum kit, amp, guitar case
	cyl(stuff, "BassDrum", U(F, 8, 0, 1.4, -2.8), "z", 1.6, 2.8, C.DoorRed)
	cyl(stuff, "BassDrumHead", U(F, 8, 0, 1.4, -1.98), "z", 0.05, 2.6, C.White, { collide = false })
	for _, sx in { -2, 2 } do
		cyl(stuff, "Tom", U(F, 8, sx, 2.6, -2.2), "y", 1, 1.6, C.DoorRed)
		part(stuff, "Stand", U(F, 8, sx * 1.4, 1.6, -3.8), V(0.15, 3.2, 0.15), C.Chrome, { collide = false })
		cyl(stuff, "Cymbal", U(F, 8, sx * 1.4, 3.25, -3.8), "y", 0.08, 2, C.Mustard, { collide = false })
	end
	local amp = part(stuff, "Amp", U(F, 8, 4, 1.6, -4.4), V(2.6, 3.2, 1.8), C.Black)
	part(stuff, "AmpGrill", U(F, 8, 4, 1.4, -3.48), V(2.2, 2.2, 0.05), C.SteelDark, { collide = false })
	amp:SetAttribute("Note", "turn it up to 11")
	part(stuff, "GuitarCase", U(F, 8, -4.4, 2.2, -3.6) * CFrame.Angles(0, 0, math.rad(8)), V(1.4, 4.4, 0.8), C.Black, { flammable = true })
	cbox(stuff, U(F, 8, 3.6, 0, 1.8, 10), 2.4, 1.6, 2)
end

local function contentsB(m: Model, F: CFrame)
	local stuff = folder(m, "Contents")
	-- B3: the garage fire — workbench, drums, tyres, a covered classic car. F4.
	local bench = part(stuff, "Workbench", U(F, 3, 0, 1.5, -4.6), V(9, 0.6, 2.4), C.WoodLight, { flammable = true, fuel = 30 })
	part(stuff, "BenchBase", U(F, 3, 0, 0.6, -4.6), V(8.4, 1.2, 2), C.Wood, { flammable = true })
	part(stuff, "BenchBack", U(F, 3, 0, 3.6, -5.6), V(9, 3.6, 0.3), C.Plywood, { flammable = true })
	part(stuff, "Vice", U(F, 3, -3, 2.2, -4.2), V(1.2, 0.8, 1), C.Teal, { collide = false })
	part(stuff, "Toolbox", U(F, 3, 2.2, 2.2, -4.4), V(2, 0.9, 1), C.DoorRed, { collide = false })
	fireStart(bench, "F4", BID)
	part(stuff, "CarCover", U(F, 3, -0.6, 1.6, 0.8), V(5.6, 2.4, 6.6), C.Stripe, { flammable = true, fuel = 20 })
	part(stuff, "CarCoverTop", U(F, 3, -0.6, 3.5, 1.2), V(4.8, 1.4, 3.8), C.Stripe, { flammable = true, fuel = 20 })
	for _, z in { -1.6, 3.4 } do
		for _, x in { -3.5, 2.3 } do
			cyl(stuff, "CarWheel", U(F, 3, x, 0.9, z), "x", 0.8, 1.8, C.Black, { collide = false })
		end
	end
	drum(stuff, U(F, 3, 4.4, 0, 2.4), C.DoorRed, "FLAMMABLE")
	for k = 0, 2 do
		cyl(stuff, "Tyre", U(F, 3, -4.6, 0.4 + k * 0.8, 3.4), "y", 0.8, 2.2, C.Black, { collide = false })
	end
	-- B5: overflow boxes
	boxStack(stuff, U(F, 5, -2.6, 0, -3.6))
	boxStack(stuff, U(F, 5, 2.4, 0, -3.8, 180))
	cbox(stuff, U(F, 5, 0.4, 0, 1, 30), 3, 2.4, 3)
end

local function contentsC(m: Model, F: CFrame)
	local stuff = folder(m, "Contents")
	-- C2: somebody's college dorm
	boxStack(stuff, U(F, 2, -3, 0, -3.8))
	bike(stuff, U(F, 2, 3.6, 0, 0.4, -20), C.Teal)
	prop("plant", stuff, U(F, 2, 0.6, 0, -4.6))
	part(stuff, "Poster", U(F, 2, 0.6, 5.4, -5.85), V(3, 2, 0.1), C.Pink, { collide = false, flammable = true })
	-- C5: grandma's furniture
	prop("tv", stuff, U(F, 5, -3, 0, -4.4, 180), { on = false }, function()
		part(stuff, "TV", U(F, 5, -3, 1.6, -4.4), V(4, 3.2, 1.6), C.Black)
	end)
	prop("chair", stuff, U(F, 5, 2.6, 0, -3.6, 160), { color = C.Pink })
	cbox(stuff, U(F, 5, 0.6, 0, 1.4, 12), 3, 2, 2.6, true)
	part(stuff, "RugRoll", U(F, 5, 3.2, 0.7, 2.4) * ALONG_Z, V(6, 1.4, 1.4), C.Terracotta, { shape = CYL, flammable = true })
end

-- Wavy inflatable tube man at the gate, with googly eyes. Pure decoration.
local function tubeMan(parent: Instance, x: number, z: number)
	local m = folder(parent, "TubeMan")
	cyl(m, "Blower", CFrame.new(x, 0.9, z), "y", 1.6, 2.6, C.SteelDark)
	local cf = CFrame.new(x, 1.7, z)
	local cols = { C.DoorRed, C.Mustard, C.DoorRed, C.Mustard, C.DoorRed }
	for k, tilt in { 6, -10, 14, -8, 4 } do
		cf = cf * CFrame.Angles(0, 0, math.rad(tilt))
		part(m, "Tube", cf * CFrame.new(0, 1.3, 0), V(1.5, 2.6, 1.5), cols[k], { collide = false })
		cf = cf * CFrame.new(0, 2.6, 0)
	end
	ball(m, "Head", cf * CFrame.new(0, 0.9, 0), 2, C.Mustard, { collide = false })
	MapKit.googlyEyes(m, O * cf * CFrame.new(0, 1.1, 0.85) * CFrame.Angles(0, math.pi, 0), 0.8)
	part(m, "ArmL", cf * CFrame.new(-1.8, -2.4, 0) * CFrame.Angles(0, 0, math.rad(50)), V(0.7, 3, 0.7), C.Mustard, { collide = false })
	part(m, "ArmR", cf * CFrame.new(1.8, -1.6, 0) * CFrame.Angles(0, 0, math.rad(-65)), V(0.7, 3, 0.7), C.Mustard, { collide = false })
end

------------------------------------------------------------------------------------------------
-- Fuse box, live cable, wet floor (the electrocution gag)
------------------------------------------------------------------------------------------------
local function fuseBox(parent: Instance)
	local m = folder(parent, "FuseBoxStand")
	local x, z = -54, -4
	part(m, "Pad", CFrame.new(x, 0.3, z), V(5, 0.3, 3.4), C.Floor)
	for _, dx in { -1.8, 1.8 } do
		part(m, "Post", CFrame.new(x + dx, 3.6, z - 0.6), V(0.4, 6.6, 0.4), C.SteelDark)
	end
	part(m, "Backboard", CFrame.new(x, 4.6, z - 0.7), V(4.6, 4.8, 0.3), C.Stripe)

	local fb = folder(m, "FuseBox")
	-- Live at round start (Power = true). HazardService owns the breaker prompt ("Power OFF"/"Power ON")
	-- and the zapping; a second prompt here would double up.
	local body = part(fb, "Box", CFrame.new(x, 4.4, z - 0.05), V(2.8, 3.4, 1), C.FuseRed, { tags = { Names.Tag.FuseBox } })
	body:SetAttribute(A_POWER, true)
	body:SetAttribute(Names.Attr.BuildingId, BID)
	fb.PrimaryPart = body
	part(fb, "DoorSeam", CFrame.new(x, 4.4, z + 0.47), V(2.4, 3, 0.05), C.FuseRed:Lerp(C.Black, 0.25), { collide = false })
	part(fb, "DoorPanel", CFrame.new(x, 4.4, z + 0.5), V(2.2, 2.8, 0.05), C.FuseRed, { collide = false })
	local warn = part(fb, "Sticker", CFrame.new(x - 0.3, 5.1, z + 0.54) * CFrame.Angles(0, math.pi, 0), V(1.2, 1, 0.05), C.Warn, { collide = false })
	label(warn, "!", C.Ink)
	local lamp = ball(fb, "PowerLamp", CFrame.new(x + 0.7, 5.5, z + 0.55), 0.4, hex("#6BCB5A"), { neon = true, collide = false })
	light(lamp, hex("#6BCB5A"), 6, 1)
	-- the lever on the right side: hub + handle pointing up (= ON) + red knob
	cyl(fb, "LeverHub", CFrame.new(x + 1.55, 4.2, z - 0.05), "x", 0.3, 0.8, C.SteelDark)
	local lever = part(fb, "Lever", CFrame.new(x + 1.75, 5.1, z - 0.05) * CFrame.Angles(math.rad(15), 0, 0), V(0.3, 2, 0.3), C.Chrome, { collide = false })
	lever:SetAttribute("On", true)
	ball(fb, "LeverKnob", CFrame.new(x + 1.75, 6.05, z + 0.21), 0.6, C.DoorRed, { collide = false })
	-- warning sign over it
	part(m, "SignPost", CFrame.new(x, 8.2, z - 0.85), V(0.3, 3.2, 0.3), C.SteelDark)
	local s = sign(m, "WarningSign", CFrame.new(x, 8.6, z - 0.4) * CFrame.Angles(0, math.pi, 0), 4.4, 1.9, C.Warn, "DANGER! HIGH VOLTAGE", C.Ink)
	part(m, "SignBorder", CFrame.new(x, 8.6, z - 0.62), V(4.7, 2.2, 0.2), C.Ink, { collide = false })
	s:SetAttribute("Note", "do not flip with wet feet")
	-- conduit: up from the box, over to the strip, along the facade under the eave
	part(m, "Conduit", CFrame.new(x + 0.8, 7.9, z - 0.3), V(0.4, 3.6, 0.4), C.SteelDark, { collide = false })
	part(m, "Conduit", CFrame.new(x + 0.8, 9.9, (z - 0.3 - 8.9) / 2), V(0.4, 0.4, math.abs(z - 0.3 + 8.9)), C.SteelDark, { collide = false })
	part(m, "Conduit", CFrame.new((x + 0.8 + 48) / 2, 9.9, -8.9), V(48 - x - 0.8, 0.4, 0.4), C.SteelDark, { collide = false })
	-- live cable on the ground from the box into the puddles, frayed sparking end
	local pts = { V(x + 0.6, 0.35, z + 0.6), V(-48, 0.35, 0), V(-40, 0.35, 3.5), V(-31, 0.35, 1.5), V(-25, 0.35, 5) }
	local last: Part? = nil
	for k = 1, #pts - 1 do
		local a, b = pts[k], pts[k + 1]
		local mid = (a + b) / 2
		last = part(m, "LiveCable", CFrame.lookAt(mid, b), V(0.35, 0.35, (b - a).Magnitude + 0.3), C.Black, { collide = false })
	end
	if last then
		last.Name = "LiveWire"
		last:SetAttribute("LiveWire", true)
	end
	local tip = pts[#pts]
	for k, off in { V(0, 0.3, 0), V(0.4, 0.6, 0.3), V(-0.3, 0.5, -0.3) } do
		local spark = ball(m, "Spark", CFrame.new(tip + off), 0.35 - k * 0.05, C.Electric, { neon = true, collide = false })
		if k == 1 then
			light(spark, C.Electric, 8, 1.4)
		end
	end
end

local function wetFloor(parent: Instance)
	local m = folder(parent, "WetFloor")
	for i, d in { { -46, 1, 8 }, { -39, 4.5, 9 }, { -31, 0.5, 8 }, { -25, 5.5, 6 }, { -42, -4.5, 6 } } do
		local p = part(m, `Puddle{i}`, CFrame.new(d[1], 0.2, d[2]) * UPRIGHT, V(0.1, d[3], d[3]), C.Puddle, {
			shape = CYL,
			material = Enum.Material.Glass,
			transparency = 0.25,
			collide = false,
			tags = { Names.Tag.WetFloor },
		})
		p.Reflectance = 0.15
		p:SetAttribute(Names.Attr.BuildingId, BID)
	end
	-- source of the water: a leaky blue barrel tipped over, plus a forgotten yellow hose
	cyl(m, "Barrel", CFrame.new(-19, 1.3, 8) * CFrame.Angles(0, math.rad(25), 0), "x", 3.2, 2.4, C.Blue)
	for k, seg in { { V(-21, 0.3, 7.4), V(-24, 0.3, 4) }, { V(-24, 0.3, 4), V(-28, 0.3, 3.2) }, { V(-28, 0.3, 3.2), V(-30, 0.3, -1) } } do
		local mid = (seg[1] + seg[2]) / 2
		part(m, `Hose{k}`, CFrame.lookAt(mid, seg[2]), V(0.5, 0.5, (seg[2] - seg[1]).Magnitude + 0.3), hex("#E8B83A"), { collide = false })
	end
	part(m, "Nozzle", CFrame.new(-30, 0.35, -1.6), V(0.6, 0.6, 1.2), hex("#C89A3C"), { collide = false })
	-- yellow A-frame "WET FLOOR" sign right next to the fuse box. Nobody reads it.
	local a = CFrame.new(-49, 0.15, 6)
	for _, s in { 1, -1 } do
		-- south board turned to face +Z; both tops lean in to meet over the middle
		local yaw = if s == 1 then CFrame.Angles(0, math.pi, 0) else CFrame.identity
		local board = part(m, "WetSignBoard", a * CFrame.new(0, 1.55, s * 0.4) * yaw * CFrame.Angles(math.rad(14), 0, 0), V(2, 3.2, 0.15), C.Warn, { collide = false })
		label(board, "CAUTION\nWET FLOOR", C.Ink)
	end
end

------------------------------------------------------------------------------------------------
-- Office by the gate
------------------------------------------------------------------------------------------------
local function office(parent: Instance)
	local m = folder(parent, "Office")
	m:SetAttribute(Names.Attr.BuildingId, "Storage.Office")
	local x0, x1, z0, z1, h = -66, -40, 58, 80, 10
	local y0 = 0.6
	part(m, "Foundation", CFrame.new((x0 + x1) / 2, 0.25, (z0 + z1) / 2), V(x1 - x0 + 0.6, 0.5, z1 - z0 + 0.6), C.Plinth)
	for i = 0, 2 do
		for j = 0, 1 do
			part(m, "Floor", CFrame.new(x0 + 0.5 + (i + 0.5) * 25 / 3, y0 - 0.1, z0 + 0.5 + (j + 0.5) * 10.5), V(25 / 3, 0.2, 10.5), if (i + j) % 2 == 0 then C.Cream else C.Stripe)
		end
	end
	local wopt = { flammable = true, fuel = 30 }
	-- back + sides solid, front (z1) with a door and two windows
	wallRun(m, "Wall", V(x0, y0, z0), V(x1, y0, z0), h, C.WallB, wopt)
	wallRun(m, "Wall", V(x0, y0, z0 + 0.5), V(x0, y0, z1 - 0.5), h, C.WallB, wopt)
	wallRun(m, "Wall", V(x1, y0, z0 + 0.5), V(x1, y0, z1 - 0.5), h, C.WallB, wopt)
	local doorX = -47
	local spans = { { x0, -63.5 }, { -56.5, -54.5 }, { -49, doorX - 2 }, { doorX + 2, x1 } }
	for _, sp in spans do
		wallRun(m, "Wall", V(sp[1], y0, z1), V(sp[2], y0, z1), h, C.WallB, wopt)
	end
	-- big shop windows (sill 2.5, top 8) between -63.5..-56.5 and -54.5..-49
	for _, w in { { -63.5, -56.5 }, { -54.5, -49 } } do
		local cx, ww = (w[1] + w[2]) / 2, w[2] - w[1]
		wallRun(m, "Wall", V(w[1], y0, z1), V(w[2], y0, z1), 2.5, C.WallB, wopt)
		wallRun(m, "Wall", V(w[1], y0 + 8, z1), V(w[2], y0 + 8, z1), h - 8, C.WallB, wopt)
		local win = part(m, "ShopWindow", CFrame.new(cx, y0 + 5.25, z1), V(ww, 5.5, 0.3), hex("#B4DCF0"), {
			material = Enum.Material.Glass,
			transparency = 0.45,
			tags = { Names.Tag.Window },
		})
		win:SetAttribute(Names.Attr.BuildingId, "Storage.Office")
		part(m, "Sill", CFrame.new(cx, y0 + 2.4, z1 + 0.6), V(ww + 0.6, 0.4, 1), C.LineWhite, { collide = false })
	end
	wallRun(m, "Wall", V(doorX - 2, y0 + 7, z1), V(doorX + 2, y0 + 7, z1), h - 7, C.WallB, wopt)
	local door = MapKit.door(m, "OfficeDoor", O * CFrame.new(doorX, y0 + 3.5, z1), false)
	door:SetAttribute(Names.Attr.BuildingId, "Storage.Office")
	-- flat roof + parapet + awning + sign
	part(m, "Roof", CFrame.new((x0 + x1) / 2, y0 + h + 0.5, (z0 + z1) / 2), V(x1 - x0 + 1, 1, z1 - z0 + 1), C.Roof)
	part(m, "Parapet", CFrame.new((x0 + x1) / 2, y0 + h + 1.6, z1 + 0.3), V(x1 - x0 + 1.2, 1.4, 0.6), C.Fascia)
	part(m, "AC", CFrame.new(-60, y0 + h + 2, 66), V(4, 2.2, 3), C.Steel)
	part(m, "ACFan", CFrame.new(-60, y0 + h + 3.15, 66) * UPRIGHT, V(0.1, 2.4, 2.4), C.SteelDark, { shape = CYL, collide = false })
	for k = 0, 5 do
		part(m, "Awning", CFrame.new(-64 + k * 3.3 + 1.65, y0 + 8.6, z1 + 1.6) * CFrame.Angles(math.rad(20), 0, 0), V(3.3, 0.3, 3.2), if k % 2 == 0 then C.DoorRed else C.White, { collide = false })
	end
	sign(m, "OfficeSign", CFrame.new(-53, y0 + h + 1.6, z1 + 0.85) * CFrame.Angles(0, math.pi, 0), 12, 1.3, C.Fascia, "OFFICE  -  RENT A UNIT", C.Cream)
	-- interior: counter, chair, rack of packing boxes, plant, key board
	prop("counter", m, CFrame.new(-56, y0, 70) * CFrame.Angles(0, math.pi, 0), { length = 10, color = C.Teal }, function()
		part(m, "Counter", CFrame.new(-56, y0 + 1.6, 70), V(10, 3.2, 2.4), C.Teal)
	end)
	prop("chair", m, CFrame.new(-56, y0, 66.6) * CFrame.Angles(0, math.pi, 0), { color = C.Terracotta })
	prop("plant", m, CFrame.new(-64.4, y0, 78))
	prop("bookshelf", m, CFrame.new(-50, y0, 59.4) * CFrame.Angles(0, math.pi, 0), nil)
	boxStack(m, CFrame.new(-62, y0, 61.6))
	local board = part(m, "KeyBoard", CFrame.new(-58, y0 + 5.2, 58.65), V(5, 3, 0.2), C.Plywood, { flammable = true })
	for k = 0, 5 do
		part(m, "Key", CFrame.new(-60 + k * 0.8, y0 + 5.2 + (k % 2) * 0.6, 58.85), V(0.25, 0.6, 0.1), C.Mustard, { collide = false })
	end
	board:SetAttribute("Note", "U5 key is missing")
	local lamp = part(m, "CeilingLight", CFrame.new(-53, y0 + h - 0.3, 69), V(6, 0.3, 1.2), hex("#FFF4D6"), { neon = true, collide = false })
	light(lamp, hex("#FFE2B8"), 18, 0.9)
end

------------------------------------------------------------------------------------------------
-- Lot, fence, road, signage, dressing
------------------------------------------------------------------------------------------------
local function chainFence(parent: Instance, a: Vector3, b: Vector3)
	local d = b - a
	local len = d.Magnitude
	local dir = d.Unit
	local n = math.max(1, math.ceil(len / 12 - 1e-6))
	for k = 0, n do
		local q = a + dir * (k * len / n)
		part(parent, "FencePost", CFrame.new(q + V(0, 3.6, 0)), V(0.5, 7.2, 0.5), C.Steel)
	end
	for k = 1, n do
		local mid = a + dir * ((k - 0.5) * len / n)
		part(parent, "ChainLink", CFrame.lookAt(mid + V(0, 3.4, 0), mid + V(0, 3.4, 0) + dir), V(0.1, 6.2, len / n), C.Fence, {
			material = Enum.Material.DiamondPlate,
			transparency = 0.55,
		})
	end
	local mid = (a + b) / 2
	part(parent, "TopRail", CFrame.lookAt(mid + V(0, 6.9, 0), mid + V(0, 6.9, 0) + dir), V(0.3, 0.3, len), C.Steel, { collide = false })
	part(parent, "BarbedWire", CFrame.lookAt(mid + V(0, 7.6, 0), mid + V(0, 7.6, 0) + dir), V(0.15, 0.15, len), C.SteelDark, { collide = false })
end

local function lamp(parent: Instance, x: number, z: number, dx: number, dz: number)
	prop("streetLamp", parent, facing(x, 0.15, z, dx, dz), { height = 14 }, function()
		part(parent, "LampPole", CFrame.new(x, 7, z), V(0.6, 14, 0.6), C.SteelDark)
		local head = part(parent, "LampHead", CFrame.new(x, 14, z), V(1.6, 0.8, 1.6), C.Lamp, { neon = true, collide = false })
		light(head, C.Lamp, 30, 1.2)
	end)
end

local function movingTruck(parent: Instance, cf: CFrame)
	local m = folder(parent, "RentalTruck")
	part(m, "Cargo", cf * CFrame.new(0, 4.6, 2.5), V(7, 7, 13), C.White)
	part(m, "CargoStripe", cf * CFrame.new(0, 4.6, 2.5), V(7.1, 1.4, 13.1), C.Terracotta, { collide = false })
	local s = part(m, "CargoSign", cf * CFrame.new(3.56, 6.2, 2.5) * CFrame.Angles(0, -math.pi / 2, 0), V(10, 1.8, 0.05), C.White, { collide = false })
	label(s, "U-STOR-IT", C.Terracotta)
	part(m, "Cab", cf * CFrame.new(0, 3.3, -6.2), V(6.6, 4.6, 4.4), C.Terracotta)
	part(m, "Windshield", cf * CFrame.new(0, 4.4, -8.42), V(5.6, 2, 0.05), hex("#A8D5E2"), { collide = false })
	part(m, "Chassis", cf * CFrame.new(0, 1.3, -0.5), V(6.2, 1, 17), C.SteelDark)
	for _, z in { -6, 5.5 } do
		for _, x in { -3.2, 3.2 } do
			cyl(m, "Wheel", cf * CFrame.new(x, 1.3, z), "x", 1, 2.6, C.Black)
		end
	end
	MapKit.googlyEyes(m, O * cf * CFrame.new(0, 3.6, -8.6), 1.3)
end

local function grounds(model: Model, rng: Random)
	local g = folder(model, "Grounds")
	-- grass, lot, road, driveway
	part(g, "Grass", CFrame.new(0, -1, 0), V(400, 2, 400), C.Grass)
	part(g, "Lot", CFrame.new(0, -0.1, 23), V(200, 0.5, 146), C.Lot)
	part(g, "Verge", CFrame.new(0, 0.05, 103), V(400, 0.1, 14), C.Verge)
	part(g, "Road", CFrame.new(0, -0.18, 118), V(400, 0.6, 16), C.Asphalt)
	part(g, "Driveway", CFrame.new(0, -0.1, 103), V(24, 0.5, 14.2), C.Lot)
	for x = -196, 196, 10 do
		part(g, "LaneDash", CFrame.new(x, 0.13, 118), V(5, 0.05, 0.5), C.LineYellow, { collide = false })
	end
	for _, z in { 110.8, 125.2 } do
		part(g, "EdgeLine", CFrame.new(0, 0.13, z), V(400, 0.05, 0.4), C.LineWhite, { collide = false })
	end
	-- parking bays in front of the office + arrows
	for k = 0, 4 do
		part(g, "BayLine", CFrame.new(-36 + k * 8, 0.16, 88), V(0.4, 0.05, 10), C.LineWhite, { collide = false })
	end
	-- perimeter chain-link fence with the gate gap at X -12..12
	local fence = folder(g, "Fence")
	chainFence(fence, V(-100, 0.15, -50), V(100, 0.15, -50))
	chainFence(fence, V(-100, 0.15, -50), V(-100, 0.15, 96))
	chainFence(fence, V(100, 0.15, -50), V(100, 0.15, 96))
	chainFence(fence, V(-100, 0.15, 96), V(-12, 0.15, 96))
	chainFence(fence, V(12, 0.15, 96), V(100, 0.15, 96))
	-- rolling gate parked open behind the east fence, keypad post
	part(fence, "GateFrame", CFrame.new(26, 3.6, 94.6), V(26, 6.2, 0.3), C.Steel, { material = Enum.Material.DiamondPlate, transparency = 0.4 })
	part(fence, "GateRail", CFrame.new(26, 6.6, 94.6), V(26, 0.5, 0.5), C.Mustard)
	part(fence, "GateRail", CFrame.new(26, 0.7, 94.6), V(26, 0.5, 0.5), C.Mustard)
	part(fence, "KeypadPost", CFrame.new(-15, 2, 100), V(0.6, 4, 0.6), C.SteelDark)
	part(fence, "Keypad", CFrame.new(-15, 4.3, 100), V(1.4, 1.6, 1), C.Mustard)
	local pad = part(fence, "KeypadScreen", CFrame.new(-15, 4.6, 100.52) * CFrame.Angles(0, math.pi, 0), V(1, 0.5, 0.05), hex("#6BCB5A"), { neon = true, collide = false })
	pad:SetAttribute("Code", "6767")
	-- pylon sign
	for _, x in { 25, 37 } do
		part(g, "SignPost", CFrame.new(x, 7.5, 104), V(1, 15, 1), C.SteelDark)
	end
	sign(g, "PylonSign", CFrame.new(31, 13.5, 104) * CFrame.Angles(0, math.pi, 0), 14, 4.4, C.Teal, "STOR-MOR", C.Cream, C.Ink)
	sign(g, "PylonSign2", CFrame.new(31, 10.2, 104) * CFrame.Angles(0, math.pi, 0), 14, 1.8, C.Mustard, "SELF STORAGE", C.Ink)
	sign(g, "PylonSign3", CFrame.new(31, 8.1, 104) * CFrame.Angles(0, math.pi, 0), 10, 1.4, C.DoorRed, "UNITS AVAILABLE!", C.White)
	local cap = part(g, "SignCap", CFrame.new(31, 16, 104), V(14.6, 0.6, 1.2), C.Lamp, { neon = true, collide = false })
	light(cap, C.Lamp, 14, 0.8)
	-- lot lamps
	for _, l in { { -90, 10, 1, 0 }, { -10, 30, 0, -1 }, { 50, -2, 1, 0 }, { 30, 70, 0, -1 }, { -88, -40, 1, 0 } } do
		lamp(g, l[1], l[2], l[3], l[4])
	end
	-- hydrants
	for i, h in { { -34, 74 }, { 56, 40 } } do
		local hy = MapKit.hydrant(g, O * CFrame.new(h[1], 0.15, h[2]))
		hy.Name = `H{i}`
		hy:SetAttribute("HydrantId", `H{i}`)
	end
	-- dressing: dumpster, pallets, cones, drums, rental truck
	local dcf = CFrame.new(84, 0.15, -42)
	part(g, "Dumpster", dcf * CFrame.new(0, 2.2, 0), V(9, 4.4, 5), C.TealDark)
	part(g, "DumpsterLid", dcf * CFrame.new(0, 4.6, 0.4) * CFrame.Angles(math.rad(-8), 0, 0), V(9.2, 0.3, 5.2), C.Teal)
	cbox(g, dcf * CFrame.new(-2, 4.4, -0.6) * CFrame.Angles(0, 0.4, 0), 2, 1.4, 2)
	for k = 0, 2 do
		local pcf = CFrame.new(86, 0.15 + k * 0.7, -24 + (k % 2) * 0.4)
		part(g, "Pallet", pcf * CFrame.new(0, 0.35, 0), V(5, 0.7, 4), C.WoodLight, { flammable = true, fuel = 20 })
	end
	for _, c in { { -18, 12 }, { -12, 9 }, { -54, 6 } } do
		local ccf = CFrame.new(c[1], 0.15, c[2])
		part(g, "ConeBase", ccf * CFrame.new(0, 0.15, 0), V(1.6, 0.3, 1.6), hex("#F2762E"))
		part(g, "Cone", ccf * CFrame.new(0, 1.2, 0) * UPRIGHT, V(1.8, 0.9, 0.9), hex("#F2762E"), { shape = CYL })
		part(g, "ConeBand", ccf * CFrame.new(0, 1.3, 0) * UPRIGHT, V(0.4, 0.95, 0.95), C.White, { shape = CYL, collide = false })
	end
	drum(g, CFrame.new(60, 0.15, 6), C.DoorRed, "FLAMMABLE")
	drum(g, CFrame.new(60.4, 0.15, 9), C.Mustard)
	movingTruck(g, CFrame.new(40, 0.15, 14) * CFrame.Angles(0, math.rad(-90), 0))
	-- trees and bushes outside the fence
	for _, tx in { -170, -140, -110, 120, 150, 178 } do
		prop("tree", g, CFrame.new(tx, 0, -70 - rng:NextInteger(0, 12)), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	for _, tz in { -30, 10, 50 } do
		prop("tree", g, CFrame.new(-125 - rng:NextInteger(0, 10), 0, tz), { variant = rng:NextInteger(1, 3), flammable = false })
		prop("tree", g, CFrame.new(125 + rng:NextInteger(0, 10), 0, tz), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	for _, bx in { -80, -55, -30, 50, 70, 90 } do
		prop("bush", g, CFrame.new(bx, 0.1, 100), { flammable = false })
	end
	for _, tx in { -150, -90, 80, 160 } do
		prop("tree", g, CFrame.new(tx, 0, 140 + rng:NextInteger(0, 10)), { variant = rng:NextInteger(1, 3), flammable = false })
	end
end

------------------------------------------------------------------------------------------------

function StorageBuilder.Build(model: Model, origin: CFrame, rng: Random)
	O = origin
	local mapDir = script.Parent.Parent
	PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	model:SetAttribute("DisplayName", "Stor-Mor Self Storage")
	model:SetAttribute("InteriorOrigin", origin) -- Lib/Map/Interiors/Depot dresses the yard + office per run

	grounds(model, rng)

	-- Strip A: U1..U8, fronts face +Z. Locked: U2, U5, U7.
	local FA = CFrame.new(-48, 0, -10)
	local a = strip(model, FA, 8, "U", C.Wall, { "open", "locked", "open", "open", "locked", "open", "locked", "open" }, {
		[1] = true,
		[3] = true,
		[4] = true,
		[6] = true,
		[8] = true,
	})
	contentsA(a, FA)

	-- Strip B: B1..B5 along Z -34..26, fronts face -X.
	local FB = CFrame.new(64, 0, -34) * CFrame.Angles(0, -math.pi / 2, 0)
	local b = strip(model, FB, 5, "B", C.WallB, { "closed", "closed", "open", "closed", "open" }, { [3] = true, [5] = true })
	contentsB(b, FB)

	-- Strip C: C1..C5 along Z 26..-34 on the west side, fronts face +X.
	local FC = CFrame.new(-76, 0, 26) * CFrame.Angles(0, math.pi / 2, 0)
	local c = strip(model, FC, 5, "C", C.WallB, { "closed", "open", "closed", "closed", "open" }, { [2] = true, [5] = true })
	contentsC(c, FC)
	tubeMan(model, -16, 78)

	fuseBox(model)
	wetFloor(model)
	office(model)

	-- where truck 67 parks (lot centre, facing west along the strip) + the squad spawn beside it
	marker(model, "TruckSpot", facing(8, 0.15, 44, -1, 0), V(4, 1, 4), T_TRUCKSPOT, { [Names.Attr.LocationId] = "Storage" })
	marker(model, "PlayerSpawn", facing(8, 0.65, 56, 0, -1), V(18, 1, 8), T_PLAYERSPAWN, { [Names.Attr.LocationId] = "Storage" })
end

return StorageBuilder
