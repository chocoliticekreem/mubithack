-- DamBuilder [owner: G2]. MILL CREEK DAM + the burning city below: the trailer's night finale
-- (t=56-62, docs/game/05 §2.8, docs/game/02 "Dam" kit + "Dam Night" lighting).
-- Slot 7. Local frame: origin = slot centre on the ground, +X east, +Z south. The reservoir is north
-- (-Z), the city south (+Z), so the default preview camera looks up at the dam over the city.
--   Dam: curved arch (12 segments, R 572.5 around (0, 532.5)), crest Y 60 from X -150 to 150, crown at
--     Z -40, road on top (16 wide), buttress fins, two outlet jets into a plunge pool.
--   Reservoir: water surface Y 54 behind the dam (X -150..150, Z -200..dam), intake tower, buoys.
--   Plateaus (rock, top Y 60) on both sides; the east one has the truck pull-out + a ramp road down
--     the east cliff (X 138..150, Z -12..150) to the city. The west one has a road tunnel.
--   City: 11 blocky buildings (X -120..120, Z 50..140) of <= 8-stud Flammable wall chunks, fire-lit
--     windows (folder "FireGlow", attr Glow), streets, lamps; a river at Z 160..176 and low silhouettes beyond it.
-- Gameplay hooks (all found by tag/attribute):
--   Detonator: tags "Detonator" + Hazard (HazardId "tidal_wave"; HazardService adds the DETONATE
--     prompt), attr ChargesNeeded = 3 (crown of the dam).
--   DetonatorSocket x3 (D1..D3, attr SocketId, Filled = false) on the deck, wired to the plunger.
--   WaveVolume-tagged invisible parts: the part NAMED "WaveVolume" (Role "Path", LookVector = wave
--     direction, dam toe -> river) is what HazardService sweeps; WaveStart/WaveEnd mark the ends.
--   Propane tanks x3 (Model tagged Hazard, HazardId "explosion") beside city buildings.
--   FireStart C1..C11 (one Flammable wall chunk per city building, attr FireId + BuildingId).
--   RescueSpawn R0 Panda on the rooftop garden of building 11 (exterior stairs on its east side),
--     R1..R6 Civilians in the streets / on a roof (dam_finale: "move civilians to high ground").
--   TruckSpot + PlayerSpawn on the east plateau, facing the dam road. Hydrants: plateau + city.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("MapKit") :: ModuleScript)

local DamBuilder = {}
DamBuilder.Id = "Dam"
DamBuilder.Slot = 7

local TAG: any = Names.Tag
local T_TRUCKSPOT = TAG.TruckSpot or "TruckSpot"
local T_PLAYERSPAWN = TAG.PlayerSpawn or "PlayerSpawn"
local T_DETONATOR = TAG.Detonator or "Detonator"
local T_SOCKET = TAG.DetonatorSocket or "DetonatorSocket"
local T_WAVE = TAG.WaveVolume or "WaveVolume"
local T_HAZARD = TAG.Hazard or "Hazard"
local A_HAZARDID = (Names.Attr :: any).HazardId or "HazardId"
local BID = "Dam"

local hex = Color3.fromHex
local C = {
	DamConcrete = hex("#B89A7E"),
	DamShadow = hex("#9A7E66"),
	DamWalkway = hex("#3D5A58"),
	Parapet = hex("#CDB49A"),
	LineYellow = hex("#E3B23C"),
	Water = hex("#3E8C9E"),
	WaterMid = hex("#61A8B6"),
	Foam = hex("#DDF3F5"),
	Bed = hex("#2E4A48"),
	Rock = hex("#6A5448"),
	RockDark = hex("#4E3E36"),
	RockLight = hex("#8A6A55"),
	Valley = hex("#3E5A3A"),
	PlateauTop = hex("#4E6A3E"),
	Asphalt = hex("#3A3742"),
	Block = hex("#8A8478"),
	Kerb = hex("#A89C8C"),
	Navy = hex("#24414A"),
	NightInk = hex("#14363A"),
	Moon = hex("#E8F4F0"),
	FireWin = hex("#FF8A1F"),
	LitWin = hex("#FFD58A"),
	DarkWin = hex("#1E3A44"),
	FireLight = hex("#FF7A2A"),
	Lamp = hex("#CFEFF0"),
	LampWarm = hex("#FFC97A"),
	Detonator = hex("#F12A1F"),
	Dynamite = hex("#C0342A"),
	Wood = hex("#8A4A28"),
	WoodLight = hex("#B07A4A"),
	Hazard = hex("#FFC531"),
	Ink = hex("#1A1210"),
	White = hex("#F2EDE4"),
	Steel = hex("#8A8C90"),
	SteelDark = hex("#3A3A40"),
	Orange = hex("#F2762E"),
	Bamboo = hex("#7FAF4A"),
	BambooDark = hex("#5E8C3E"),
	Terracotta = hex("#E76F51"),
	-- building sidings (02 palette)
	AptBrick = hex("#9C4A36"),
	Cream = hex("#E8D3A8"),
	PaleBlue = hex("#9EC1CC"),
	Salmon = hex("#D98B6F"),
	Sage = hex("#9DB38A"),
	Mustard = hex("#D2A54A"),
	Teal = hex("#4F8A85"),
	Lilac = hex("#B9A6C9"),
	Roof = hex("#4E4A5A"),
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
local function wedge(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3): WedgePart
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

local function label(p: BasePart, text: string, color: Color3, stroke: Color3?)
	local sg = Instance.new("SurfaceGui")
	sg.Face = Enum.NormalId.Front
	sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sg.PixelsPerStud = 30
	sg.LightInfluence = 0.2
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

local function sign(parent: Instance, name: string, cf: CFrame, w: number, h: number, color: Color3, text: string, textColor: Color3, opts: { [string]: any }?): Part
	local p = part(parent, name, cf, V(w, h, 0.4), color, opts)
	label(p, text, textColor)
	return p
end

local function marker(parent: Instance, name: string, cf: CFrame, size: Vector3, tag: string, attrs: { [string]: any }): Part
	local p = part(parent, name, cf, size, C.Hazard, { transparency = 1, collide = false, tags = { tag } })
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
	local p = part(parent, id, cf * CFrame.new(0, 1, 0), V(2, 2, 2), C.Hazard, {
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

-- Straight run of <= 8-stud chunks from a to b (base points), height h, 1 thick. Returns the chunks.
local function wallRun(parent: Instance, name: string, a: Vector3, b: Vector3, h: number, color: Color3, opts: { [string]: any }?): { Part }
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
		table.insert(out, part(parent, `{name}_{i}`, CFrame.lookAt(mid, mid + dir), V(1, h, len / n), color, opts))
	end
	return out
end

-- Axis-aligned slab with its top at `top`; tiled into <= 8-stud pieces when flammable.
local function rect(parent: Instance, name: string, x0: number, x1: number, z0: number, z1: number, top: number, thick: number, color: Color3, opts: { [string]: any }?)
	local tiled = opts ~= nil and opts.flammable == true
	local nx = if tiled then math.max(1, math.ceil((x1 - x0) / 8 - 1e-6)) else 1
	local nz = if tiled then math.max(1, math.ceil((z1 - z0) / 8 - 1e-6)) else 1
	local sx, sz = (x1 - x0) / nx, (z1 - z0) / nz
	for i = 1, nx do
		for j = 1, nz do
			part(parent, name, CFrame.new(x0 + (i - 0.5) * sx, top - thick / 2, z0 + (j - 0.5) * sz), V(sx, thick, sz), color, opts)
		end
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
	warn(`[DamBuilder] {name} unavailable: {if ok then "not a table" else mod}`)
	return nil
end

local function prop(kind: string, parent: Instance, cf: CFrame, opts: { [string]: any }?, fallback: (() -> ())?)
	if PropKit and type(PropKit[kind]) == "function" then
		local ok, err = pcall(PropKit[kind], parent, O * cf, opts)
		if ok then
			return
		end
		warn(`[DamBuilder] PropKit.{kind} failed: {err}`)
	end
	if fallback then
		fallback()
	end
end

local function lamp(parent: Instance, cf: CFrame)
	prop("streetLamp", parent, cf, nil, function()
		part(parent, "LampPole", cf * CFrame.new(0, 6, 0), V(0.6, 12, 0.6), C.SteelDark)
		local head = part(parent, "LampHead", cf * CFrame.new(0, 12, -1), V(1.4, 0.6, 2.4), C.LampWarm, { neon = true, collide = false })
		light(head, C.LampWarm, 26, 1.2)
	end)
end

------------------------------------------------------------------------------------------------
-- Dam geometry
------------------------------------------------------------------------------------------------
local R = 572.5 -- crest centreline radius
local ZC = 532.5 -- arc centre Z (downstream, far south)
local PHI = math.asin(150 / R) -- half-angle: the arc ends at X = +-150
local NSEG = 12
local DPHI = 2 * PHI / NSEG
local CREST = 60
local WATER = 54

local function arcXZ(phi: number, r: number): (number, number)
	return r * math.sin(phi), ZC - r * math.cos(phi)
end

-- CFrame on the arc at angle phi, radius r, height y; -Z faces downstream (toward the city).
local function arcCF(phi: number, r: number, y: number): CFrame
	local x, z = arcXZ(phi, r)
	local p = V(x, y, z)
	return CFrame.lookAt(p, p + V(-math.sin(phi), 0, math.cos(phi)))
end

local function chord(r: number): number
	return 2 * r * math.sin(DPHI / 2)
end

local function dam(model: Model)
	local m = folder(model, "Dam")
	m:SetAttribute(Names.Attr.BuildingId, "Dam.Wall")
	local deck = folder(m, "Deck")
	for k = 1, NSEG do
		local phi = -PHI + (k - 0.5) * DPHI
		-- body: lower (24 thick) and upper (16 thick), both flush with the upstream face (R + 8)
		part(m, "DamLower", arcCF(phi, R - 4, CREST / 4), V(chord(R + 8) + 0.4, CREST / 2, 24), if k % 2 == 0 then C.DamConcrete else C.DamShadow)
		part(m, "DamUpper", arcCF(phi, R, CREST * 3 / 4), V(chord(R + 8) + 0.4, CREST / 2, 16), C.DamConcrete)
		-- seam line on the downstream face
		part(m, "Seam", arcCF(phi, R - 16.1, CREST / 4 + 4), V(chord(R - 16) + 0.4, 0.4, 0.3), C.DamShadow, { collide = false })
		-- deck: road, centre dash, parapets
		part(deck, "Road", arcCF(phi, R, CREST + 0.2), V(chord(R + 8) + 0.4, 0.4, 16), C.DamWalkway)
		part(deck, "Dash", arcCF(phi, R, CREST + 0.42), V(6, 0.05, 0.5), C.LineYellow, { collide = false })
		for _, side in { -1, 1 } do
			local r = R + side * 7.5
			part(deck, "Parapet", arcCF(phi, r, CREST + 1.7), V(chord(r) + 0.3, 2.6, 1), C.Parapet)
			part(deck, "ParapetCap", arcCF(phi, r, CREST + 3.1), V(chord(r) + 0.3, 0.3, 1.4), C.White)
		end
		-- lamps on the downstream parapet, arms reaching over the road
		if k % 2 == 1 then
			local x, z = arcXZ(phi, R - 6.4)
			local ox, oz = arcXZ(phi, R + 10)
			lamp(deck, CFrame.lookAt(V(x, CREST + 0.4, z), V(ox, CREST + 0.4, oz)))
		end
	end
	-- buttress fins on the downstream face (skip the middle, where the outlets are)
	for k = 1, NSEG - 1 do
		if k ~= NSEG / 2 then
			local phi = -PHI + k * DPHI
			wedge(m, "Buttress", arcCF(phi, R - 23, 26), V(3, 52, 14), C.DamShadow)
		end
	end
	-- abutments where the arch meets the cliffs
	for _, sx in { -1, 1 } do
		if sx < 0 then
			part(m, "Abutment", CFrame.new(-146, CREST / 2, -16), V(10, CREST, 30), C.DamShadow)
		else
			part(m, "Abutment", CFrame.new(146, CREST / 2, -21.5), V(10, CREST, 19), C.DamShadow) -- stops where the ramp starts
		end
	end
	-- name plate under the crest, facing the city
	sign(m, "DamName", arcCF(0, R - 8.3, CREST - 4), 44, 4, C.DamShadow, "MILL CREEK DAM  -  EST. 1967", C.White)
	-- two outlet portals + water jets into the plunge pool
	local jets = folder(m, "Outlets")
	for _, sx in { -12, 12 } do
		local phi = math.asin(sx / (R - 16))
		part(jets, "OutletFrame", arcCF(phi, R - 16.6, 18), V(8, 8, 1.2), C.SteelDark)
		part(jets, "OutletHole", arcCF(phi, R - 17.1, 18), V(6, 6, 0.4), C.Ink, { collide = false })
		local x, z = arcXZ(phi, R - 17)
		local a, b = V(x, 17, z), V(x, 1, z + 16)
		local mid = (a + b) / 2
		part(jets, "Jet", CFrame.lookAt(mid, b), V(5, 3, (b - a).Magnitude), C.WaterMid, { transparency = 0.35, collide = false })
		for f = 0, 3 do
			ball(jets, "Foam", CFrame.new(x - 3 + f * 2, 1.4, z + 16 + (f % 2) * 1.5), 3.4 - (f % 2), C.Foam, { collide = false })
		end
	end
	-- plunge pool at the toe
	part(jets, "PlungePool", CFrame.new(0, 0.2, -9), V(80, 0.8, 28), C.WaterMid, { transparency = 0.25, collide = false, material = Enum.Material.Glass })
	part(jets, "PoolRim", CFrame.new(0, 0.5, 5.4), V(82, 1, 1.2), C.Kerb)
end

------------------------------------------------------------------------------------------------
-- Detonator, sockets, wires (the finale trigger)
------------------------------------------------------------------------------------------------
local function detonator(model: Model)
	local m = folder(model, "Detonator")
	-- plunger on the upstream side of the crown, facing the road (south)
	local x, z = arcXZ(0, R + 4.8)
	local base = CFrame.new(x, CREST + 0.4, z)
	-- Hazard "tidal_wave": HazardService adds the DETONATE prompt (and defers to FinaleService once
	-- charges are wired), so no prompt here.
	local box = part(m, "Detonator", base * CFrame.new(0, 0.9, 0), V(2.6, 1.8, 1.8), C.Wood, { tags = { T_DETONATOR, T_HAZARD } })
	box:SetAttribute(A_HAZARDID, "tidal_wave")
	box:SetAttribute("ChargesNeeded", 3)
	box:SetAttribute(Names.Attr.BuildingId, BID)
	part(m, "Band", base * CFrame.new(0, 0.9, 0), V(2.7, 0.4, 1.9), C.SteelDark, { collide = false })
	local tnt = part(m, "Label", base * CFrame.new(0, 1.2, 0.92) * CFrame.Angles(0, math.pi, 0), V(1.8, 0.7, 0.05), C.Hazard, { collide = false })
	label(tnt, "TNT", C.Ink)
	part(m, "Rod", base * CFrame.new(0, 2.6, 0), V(0.3, 1.8, 0.3), C.Steel, { collide = false })
	part(m, "Handle", base * CFrame.new(0, 3.5, 0), V(2.4, 0.4, 0.4), C.SteelDark, { collide = false })
	for _, sx in { -1.3, 1.3 } do
		ball(m, "Grip", base * CFrame.new(sx, 3.5, 0), 0.6, C.Detonator, { collide = false })
	end
	local bulb = ball(m, "ArmedLight", base * CFrame.new(0.9, 2, -0.5), 0.6, C.Detonator, { neon = true, collide = false })
	light(bulb, C.Detonator, 10, 2)
	-- sockets D1..D3 near the downstream parapet, wires back to the plunger
	for i, sx in { -80, 0, 80 } do
		local phi = math.asin(sx / R)
		local sock = folder(m, `D{i}`)
		local scf = arcCF(phi, R - 5, CREST + 0.4)
		local plate = part(sock, `D{i}`, scf * CFrame.new(0, 0.2, 0), V(3, 0.4, 3), C.Hazard, { tags = { T_SOCKET } })
		plate:SetAttribute("SocketId", `D{i}`)
		plate:SetAttribute("Filled", false)
		for s = -1, 1, 2 do
			part(sock, "Stripe", scf * CFrame.new(s * 0.75, 0.42, 0) * CFrame.Angles(0, math.rad(45), 0), V(0.4, 0.05, 3.2), C.Ink, { collide = false })
		end
		local tag = part(sock, "SocketSign", scf * CFrame.new(0, 3.6, -1.6) * CFrame.Angles(0, math.pi, 0), V(2, 1.2, 0.2), C.Ink, { collide = false })
		label(tag, `D{i}`, C.Hazard)
		part(sock, "SocketPost", scf * CFrame.new(0, 2.0, -1.75), V(0.3, 3.2, 0.3), C.SteelDark, { collide = false })
		-- wire: polyline along the deck from the socket to the plunger
		local steps = 8
		local prev: Vector3? = nil
		for s = 0, steps do
			local t = s / steps
			local ph = phi * (1 - t)
			local rr = (R - 4) * (1 - t) + (R + 3.6) * t
			local wx, wz = arcXZ(ph, rr)
			local p = V(wx + (if i == 2 then 0.6 * t else 0), CREST + 0.5, wz)
			if prev then
				local mid = (prev + p) / 2
				part(m, "Wire", CFrame.lookAt(mid, p), V(0.2, 0.2, (p - prev).Magnitude + 0.1), C.Detonator, { collide = false })
			end
			prev = p
		end
	end
end

------------------------------------------------------------------------------------------------
-- Reservoir, plateaus, cliffs, ramp, tunnel
------------------------------------------------------------------------------------------------
local function terrain(model: Model, rng: Random)
	local t = folder(model, "Terrain")
	part(t, "ValleyFloor", CFrame.new(0, -1, 0), V(400, 2, 400), C.Valley)
	-- plateaus: rock blocks with grassy tops
	for _, sx in { -1, 1 } do
		part(t, "Plateau", CFrame.new(sx * 175, CREST / 2 - 0.5, 0), V(50, CREST - 1, 400), C.Rock)
		part(t, "PlateauTop", CFrame.new(sx * 175, CREST - 0.5, 0), V(50, 1, 400), C.PlateauTop)
	end
	part(t, "NorthRim", CFrame.new(0, (CREST + 2) / 2, -195), V(300, CREST + 2, 10), C.RockDark)
	-- reservoir: bed + water strips that follow the curved upstream face
	part(t, "ReservoirBed", CFrame.new(0, 25, -114), V(300, 50, 172), C.Bed)
	local water = folder(t, "Reservoir")
	for k = 1, NSEG do
		local p0, p1 = -PHI + (k - 1) * DPHI, -PHI + k * DPHI
		local x0 = arcXZ(p0, R + 8)
		local x1 = arcXZ(p1, R + 8)
		local _, z0 = arcXZ(p0, R + 8)
		local _, z1 = arcXZ(p1, R + 8)
		local zEnd = math.max(z0, z1) + 2
		local w = part(water, "Water", CFrame.new((x0 + x1) / 2, WATER - 1, (-190 + zEnd) / 2), V(math.abs(x1 - x0) + 0.05, 2, zEnd + 190), C.Water, {
			transparency = 0.15,
			material = Enum.Material.Glass,
			collide = false,
		})
		w.Reflectance = 0.2
		w:SetAttribute("Reservoir", true)
	end
	-- buoy line across the reservoir
	for k = 0, 20 do
		ball(water, "Buoy", CFrame.new(-60 + k * 6, WATER + 0.3, -78), 1.6, if k % 2 == 0 then C.Orange else C.White, { collide = false })
	end
	part(water, "BuoyRope", CFrame.new(0, WATER + 0.3, -78), V(120, 0.2, 0.2), C.White, { collide = false })
	-- intake tower with a footbridge to the crest
	local tx, tz = 45, -66
	cyl(water, "IntakeTower", CFrame.new(tx, 40, tz), "y", 40, 10, C.DamConcrete)
	cyl(water, "IntakeCap", CFrame.new(tx, 60.3, tz), "y", 0.6, 11, C.White)
	part(water, "IntakeHut", CFrame.new(tx, 63, tz), V(6, 5, 6), C.Parapet)
	part(water, "IntakeRoof", CFrame.new(tx, 65.8, tz), V(7, 0.6, 7), C.Roof)
	local hutLight = part(water, "IntakeWindow", CFrame.new(tx, 63.4, tz + 3.05), V(2.4, 1.6, 0.1), C.LitWin, { neon = true, collide = false })
	light(hutLight, C.LampWarm, 14, 0.8)
	local _, bz = arcXZ(math.asin(tx / (R + 8)), R + 8)
	part(water, "Footbridge", CFrame.new(tx, CREST + 0.2, (tz + 3 + bz) / 2), V(4, 0.4, bz - tz - 3 + 1), C.DamWalkway)
	for _, sx in { -2, 2 } do
		part(water, "BridgeRail", CFrame.new(tx + sx, CREST + 1.4, (tz + 3 + bz) / 2), V(0.3, 2, bz - tz - 3 + 1), C.Steel, { collide = false })
	end
	-- moon over the reservoir
	local moon = ball(t, "Moon", CFrame.new(-110, 170, -190), 26, C.Moon, { neon = true, collide = false })
	light(moon, C.Lamp, 60, 0.6)
	-- chunky cliff outcrops on the west valley face (east face has the ramp)
	for k = 0, 8 do
		local h = rng:NextInteger(14, 34)
		local w = rng:NextInteger(5, 9)
		local d = rng:NextInteger(14, 24)
		local y = rng:NextInteger(4, 44)
		part(t, "Outcrop", CFrame.new(-150 + w / 2 - 1.5, math.min(y, CREST - h / 2) , -4 + k * 24), V(w, h, d), if k % 2 == 0 then C.RockLight else C.RockDark)
	end
	for k = 0, 2 do
		part(t, "Outcrop", CFrame.new(150 - 3, 20 + k * 9, 165 + k * 12), V(6, 24, 14), C.RockDark)
	end
	-- pines on the plateaus
	for _, p in { { -190, -120 }, { -170, -60 }, { -188, 40 }, { -165, 110 }, { -185, 170 }, { 185, -120 }, { 165, -70 }, { 190, 60 }, { 175, 130 }, { 160, 185 } } do
		prop("tree", t, CFrame.new(p[1], CREST, p[2]), { kind = "pine", size = rng:NextNumber(1.1, 1.5), flammable = false })
	end

	-- east plateau road (truck pull-out) + west road into a tunnel
	local roads = folder(t, "Roads")
	part(roads, "PlateauRoad", CFrame.new(175, CREST + 0.2, -20), V(50, 0.4, 16), C.Asphalt)
	part(roads, "PlateauRoad", CFrame.new(-167, CREST + 0.2, -20), V(34, 0.4, 16), C.Asphalt)
	for _, x in { 160, 172, 184, 196 } do
		part(roads, "Dash", CFrame.new(x, CREST + 0.42, -20), V(6, 0.05, 0.5), C.LineYellow, { collide = false })
	end
	part(roads, "TunnelMound", CFrame.new(-191.5, CREST + 12, -20), V(17, 24, 50), C.Rock)
	part(roads, "TunnelMound", CFrame.new(-195, CREST + 26, -14), V(12, 10, 34), C.RockDark)
	part(roads, "TunnelHole", CFrame.new(-182.9, CREST + 5.5, -20), V(0.4, 11, 13), C.Ink, { collide = false })
	part(roads, "TunnelArch", CFrame.new(-182.6, CREST + 12, -20), V(1.4, 2, 17), C.DamConcrete)
	for _, sz in { -7.5, 7.5 } do
		part(roads, "TunnelJamb", CFrame.new(-182.6, CREST + 5.5, -20 + sz), V(1.4, 11, 2), C.DamConcrete)
	end
	-- ramp road down the east cliff: a solid wedge whose slope is the road
	local rampLen = 162
	local rampCf = CFrame.new(144, CREST / 2, -12 + rampLen / 2) * CFrame.Angles(0, math.pi, 0)
	wedge(roads, "RampFill", rampCf, V(12, CREST, rampLen), C.RockLight)
	local top, bottom = V(144, CREST + 0.05, -12), V(144, 0.05, 150)
	local mid = (top + bottom) / 2
	local slope = CFrame.lookAt(mid, bottom)
	part(roads, "RampRoad", slope * CFrame.new(0, 0.2, 0), V(10, 0.3, (bottom - top).Magnitude), C.Asphalt)
	part(roads, "RampRail", slope * CFrame.new(-5.6, 1.6, 0), V(0.4, 0.4, (bottom - top).Magnitude), C.Steel, { collide = false })
	for k = 0, 10 do
		local p = top + (bottom - top) * (k / 10)
		part(roads, "RampPost", CFrame.new(p.X - 5.6, p.Y + 0.9, p.Z), V(0.4, 1.8, 0.4), C.Steel, { collide = false })
	end
	-- guard booth + boom at the east plateau
	part(roads, "Booth", CFrame.new(190, CREST + 3, -34), V(6, 6, 6), C.Cream)
	part(roads, "BoothRoof", CFrame.new(190, CREST + 6.3, -34), V(7, 0.6, 7), C.Roof)
	local win = part(roads, "BoothWindow", CFrame.new(190, CREST + 3.6, -30.95), V(4, 2, 0.1), C.LitWin, { neon = true, collide = false })
	light(win, C.LampWarm, 12, 0.8)
	part(roads, "BoomPost", CFrame.new(186, CREST + 1.5, -29), V(1, 3, 1), C.SteelDark)
	for k = 0, 3 do
		part(roads, "Boom", CFrame.new(186, CREST + 2.8, -25.5 + k * 3), V(0.5, 0.5, 3), if k % 2 == 0 then C.Detonator else C.White, { collide = false })
	end
end

------------------------------------------------------------------------------------------------
-- The burning city
------------------------------------------------------------------------------------------------
type Spec = { x0: number, x1: number, z0: number, z1: number, h: number, color: Color3, street: number, sign: string?, tank: boolean?, panda: boolean? }

local CITY: { Spec } = {
	{ x0 = -112, x1 = -88, z0 = 52, z1 = 76, h = 32, color = C.AptBrick, street = 1, tank = true },
	{ x0 = -82, x1 = -68, z0 = 58, z1 = 78, h = 16, color = C.Salmon, street = 1, sign = "DINER" },
	{ x0 = -48, x1 = -14, z0 = 50, z1 = 80, h = 24, color = C.Cream, street = 1, sign = "HOTEL" },
	{ x0 = 10, x1 = 30, z0 = 54, z1 = 78, h = 40, color = C.PaleBlue, street = 1, tank = true },
	{ x0 = 36, x1 = 52, z0 = 60, z1 = 80, h = 16, color = C.Mustard, street = 1 },
	{ x0 = 70, x1 = 96, z0 = 52, z1 = 80, h = 24, color = C.Teal, street = 1, sign = "BANK" },
	{ x0 = -112, x1 = -80, z0 = 112, z1 = 140, h = 16, color = C.Sage, street = -1 },
	{ x0 = -50, x1 = -26, z0 = 112, z1 = 136, h = 32, color = C.AptBrick, street = -1, tank = true },
	{ x0 = -20, x1 = -8, z0 = 114, z1 = 130, h = 16, color = C.Lilac, street = -1 },
	{ x0 = 12, x1 = 44, z0 = 112, z1 = 136, h = 24, color = C.Salmon, street = -1, sign = "CINEMA" },
	{ x0 = 72, x1 = 100, z0 = 112, z1 = 140, h = 16, color = C.Cream, street = -1, panda = true },
}

local function waterTank(parent: Instance, x: number, y: number, z: number)
	for _, o in { { -2, -2 }, { 2, -2 }, { -2, 2 }, { 2, 2 } } do
		part(parent, "TankLeg", CFrame.new(x + o[1], y + 2, z + o[2]), V(0.5, 4, 0.5), C.SteelDark)
	end
	cyl(parent, "Tank", CFrame.new(x, y + 7, z), "y", 6, 6.4, C.WoodLight, { flammable = true, fuel = 30 })
	cyl(parent, "TankCap", CFrame.new(x, y + 10.3, z), "y", 0.6, 7, C.Roof)
end

local function cityBuilding(parent: Instance, idx: number, s: Spec, rng: Random)
	local b = folder(parent, `Building{idx}`)
	local bid = `Dam.City{idx}`
	b:SetAttribute(Names.Attr.BuildingId, bid)
	local glowF = folder(b, "FireGlow")
	local base = 0.3
	local floors = math.floor(s.h / 8 + 0.5)
	local h = floors * 8
	local wopt = { flammable = true, fuel = 40 }
	local cx = (s.x0 + s.x1) / 2
	local sz = if s.street == 1 then s.z1 else s.z0 -- street-facing wall Z
	local fireChunk: Part? = nil
	for f = 0, floors - 1 do
		local y = base + f * 8
		local c = if f % 2 == 0 then s.color else s.color:Lerp(C.Ink, 0.08)
		local south = wallRun(b, "Wall", V(s.x0, y, s.z1), V(s.x1, y, s.z1), 8, c, wopt)
		local north = wallRun(b, "Wall", V(s.x0, y, s.z0), V(s.x1, y, s.z0), 8, c, wopt)
		wallRun(b, "Wall", V(s.x0, y, s.z0 + 0.5), V(s.x0, y, s.z1 - 0.5), 8, c, wopt)
		wallRun(b, "Wall", V(s.x1, y, s.z0 + 0.5), V(s.x1, y, s.z1 - 0.5), 8, c, wopt)
		if f == math.min(1, floors - 1) then
			local street = if s.street == 1 then south else north
			fireChunk = street[math.max(1, math.ceil(#street / 2))]
		end
		-- floor band
		part(b, "Band", CFrame.new(cx, y + 8, s.z1 + 0.6), V(s.x1 - s.x0 + 0.6, 0.5, 0.3), s.color:Lerp(C.White, 0.35), { collide = false })
		part(b, "Band", CFrame.new(cx, y + 8, s.z0 - 0.6), V(s.x1 - s.x0 + 0.6, 0.5, 0.3), s.color:Lerp(C.White, 0.35), { collide = false })
		-- windows on the north (dam-facing) and south faces; ground floor street side = shopfront
		local w = s.x1 - s.x0
		local n = math.max(1, math.floor((w - 4) / 5.5) + 1)
		for _, face in { { s.z1, 1 }, { s.z0, -1 } } do
			local fz, dir = face[1], face[2]
			local isShop = f == 0 and fz == sz
			if isShop then
				part(b, "Door", CFrame.new(cx, base + 3.5, fz + dir * 0.55), V(4, 7, 0.2), C.Wood, { collide = false })
				for _, sx in { -1, 1 } do
					if w > 14 then
						part(b, "ShopWindow", CFrame.new(cx + sx * (w / 4 + 1), base + 3.6, fz + dir * 0.6), V(w / 2 - 6, 4.4, 0.2), C.LitWin, { neon = true, collide = false })
					end
				end
				for k = 0, 3 do
					part(b, "Awning", CFrame.new(cx - w * 0.3 + (k + 0.5) * w * 0.15, base + 7.4, fz + dir * 1.6) * CFrame.Angles(dir * math.rad(18), 0, 0), V(w * 0.15, 0.3, 2.6), if k % 2 == 0 then C.Detonator else C.White, { collide = false })
				end
			else
				for k = 0, n - 1 do
					local wx = s.x0 + 2 + (k + 0.5) * (w - 4) / n
					local roll = rng:NextNumber()
					local col, neon = C.DarkWin, false
					if roll < 0.42 then
						col, neon = C.FireWin, true
					elseif roll < 0.62 then
						col, neon = C.LitWin, true
					end
					local win = part(if col == C.FireWin then glowF else b, "Window", CFrame.new(wx, base + f * 8 + 4.4, fz + dir * 0.6), V(3, 3.6, 0.2), col, {
						neon = neon,
						collide = false,
					})
					if col == C.FireWin then
						win:SetAttribute("Glow", true)
					end
				end
			end
		end
	end
	if fireChunk then
		fireStart(fireChunk, `C{idx}`, bid)
		-- one hot orange light per building so the city glows from the dam
		light(fireChunk, C.FireLight, 24, 2)
	end
	-- roof (walkable, flammable tiles) + parapet
	local top = base + h + 1
	rect(b, "Roof", s.x0 - 0.5, s.x1 + 0.5, s.z0 - 0.5, s.z1 + 0.5, top, 1, C.Roof, { flammable = true, fuel = 30 })
	for _, e in { { cx, s.z0 - 0.3, s.x1 - s.x0 + 1.6, 0.6 }, { cx, s.z1 + 0.3, s.x1 - s.x0 + 1.6, 0.6 } } do
		part(b, "RoofParapet", CFrame.new(e[1], top + 0.6, e[2]), V(e[3], 1.2, e[4]), s.color:Lerp(C.White, 0.2))
	end
	for _, x in (if s.panda then { s.x0 - 0.3 } else { s.x0 - 0.3, s.x1 + 0.3 }) do
		part(b, "RoofParapet", CFrame.new(x, top + 0.6, (s.z0 + s.z1) / 2), V(0.6, 1.2, s.z1 - s.z0 + 0.4), s.color:Lerp(C.White, 0.2))
	end
	if s.tank then
		waterTank(b, s.x0 + 6, top, (s.z0 + s.z1) / 2)
	end
	part(b, "RoofAC", CFrame.new(s.x1 - 5, top + 1, s.z0 + 5), V(4, 2, 3), C.Steel)
	if s.sign then
		local sgn = sign(b, "NeonSign", CFrame.new(cx, top + 2.2, sz + s.street * 0.9) * (if s.street == 1 then CFrame.Angles(0, math.pi, 0) else CFrame.identity), math.min(16, s.x1 - s.x0 - 2), 2.6, C.Ink, s.sign, C.LitWin)
		light(sgn, C.LampWarm, 14, 0.6)
	end
	if s.panda then
		-- rooftop bamboo garden: why the panda is up here. Exterior stairs on the east side.
		for k, p in { { -8, -6 }, { 7, -7 }, { -9, 8 } } do
			local px, pz = cx + p[1], (s.z0 + s.z1) / 2 + p[2]
			part(b, "Planter", CFrame.new(px, top + 0.8, pz), V(4, 1.6, 4), C.Terracotta)
			for st = 0, 2 do
				local hgt = 5 + ((k + st) % 3)
				part(b, "Bamboo", CFrame.new(px - 1 + st, top + 1.6 + hgt / 2, pz + (st % 2) * 0.8 - 0.4), V(0.5, hgt, 0.5), if st == 1 then C.BambooDark else C.Bamboo, { flammable = true, fuel = 15 })
				ball(b, "BambooLeaves", CFrame.new(px - 1 + st, top + 1.8 + hgt, pz + (st % 2) * 0.8 - 0.4), 2, C.Bamboo, { collide = false })
			end
		end
		rescueSpawn(b, "R0", "Panda", bid, facing(cx, top, (s.z0 + s.z1) / 2, 0, -1), "sitting")
		local steps = math.ceil(top)
		for k = 1, steps do
			local hgt = k * top / steps
			part(b, "Stair", CFrame.new(s.x1 + 2.5, hgt / 2, s.z1 - 2 - (k - 0.5) * 1.5), V(4, hgt, 1.5), if k % 2 == 0 then C.Steel else C.SteelDark)
		end
		local ra = V(s.x1 + 4.6, 3.2, s.z1 - 2)
		local rb = V(s.x1 + 4.6, top + 3.2, s.z1 - 2 - steps * 1.5)
		local rm = (ra + rb) / 2
		part(b, "StairRail", CFrame.lookAt(rm, rb), V(0.3, 0.3, (rb - ra).Magnitude), C.Hazard, { collide = false })
	end
end

local function city(model: Model, rng: Random)
	local c = folder(model, "City")
	-- streets: north road, main avenue, south (riverside) road; cross streets at X -60, 0, 60
	local streets = folder(c, "Streets")
	part(streets, "Street", CFrame.new(-7, 0.05, 35), V(286, 0.1, 10), C.Asphalt)
	part(streets, "Street", CFrame.new(-7, 0.05, 99), V(286, 0.1, 14), C.Asphalt)
	part(streets, "Street", CFrame.new(0, 0.05, 152), V(300, 0.1, 12), C.Asphalt)
	for _, x in { -60, 0, 60 } do
		part(streets, "Street", CFrame.new(x, 0.06, 93.5), V(12, 0.1, 117), C.Asphalt)
	end
	for x = -140, 130, 10 do
		if math.abs(x + 60) > 7 and math.abs(x) > 7 and math.abs(x - 60) > 7 then
			part(streets, "Dash", CFrame.new(x, 0.12, 99), V(5, 0.05, 0.5), C.LineYellow, { collide = false })
		end
	end
	-- block plazas (pavement, top 0.3)
	for _, bx in { { -150, -66 }, { -54, -6 }, { 6, 54 }, { 66, 136 } } do
		for _, bz in { { 40, 92 }, { 106, 146 } } do
			part(streets, "Pavement", CFrame.new((bx[1] + bx[2]) / 2, 0.15, (bz[1] + bz[2]) / 2), V(bx[2] - bx[1], 0.3, bz[2] - bz[1]), C.Block)
		end
	end
	-- buildings
	for i, s in CITY do
		cityBuilding(c, i, s, rng)
	end
	-- street lamps along the avenue, a few abandoned cars, hydrants
	for _, x in { -100, -30, 30, 100 } do
		lamp(c, facing(x, 0.3, 91, 0, 1))
		lamp(c, facing(x + 14, 0.3, 107, 0, -1))
	end
	prop("car", c, facing(-36, 0.1, 102, -1, 0), { color = C.Teal, eyes = true })
	prop("car", c, facing(42, 0.1, 96, 1, 0), { color = C.Mustard })
	prop("car", c, facing(-60, 0.1, 128, 0, 1) * CFrame.Angles(0, math.rad(12), 0), { color = C.Salmon })
	for i, h in { { -53, 90.6 }, { 67, 107.4 } } do
		local hy = MapKit.hydrant(c, O * CFrame.new(h[1], 0.3, h[2]))
		hy.Name = `H{i + 1}`
		hy:SetAttribute("HydrantId", `H{i + 1}`)
	end
	-- civilians to move to high ground (RescueService takes markers in name order: R0 panda, R1..R6)
	for i, r in { { -75, 0.3, 88, 0, 1, "stand" }, { -24, 0.3, 104, 1, 0, "sitting" }, { 46, 0.3, 90, 0, -1, "stand" }, { -14, 17.3, 122, 0, -1, "lying" }, { 104, 0.3, 104, -1, 0, "stand" }, { -96, 0.3, 146, 1, 0, "sitting" } } do
		rescueSpawn(c, `R{i}`, "Civilian", "Dam.City", facing(r[1], r[2], r[3], r[4], r[5]), r[6])
	end
	-- propane tanks next to three buildings: Hazard "explosion" (they blow when the fire reaches them)
	for _, t in { { -66, 0.3, 70 }, { -10, 0.3, 58 }, { 48, 0.3, 140 } } do
		local tank = folder(c, "PropaneTank")
		CollectionService:AddTag(tank, T_HAZARD)
		tank:SetAttribute(A_HAZARDID, "explosion")
		local body = cyl(tank, "Tank", CFrame.new(t[1], t[2] + 1.6, t[3]), "z", 5, 2.6, C.White)
		tank.PrimaryPart = body
		for _, dz in { -2.6, 2.6 } do
			ball(tank, "TankEnd", CFrame.new(t[1], t[2] + 1.6, t[3] + dz), 2.6, C.White, { collide = false })
		end
		part(tank, "TankLegs", CFrame.new(t[1], t[2] + 0.3, t[3]), V(2, 0.6, 4), C.SteelDark)
		local lbl = part(tank, "TankLabel", CFrame.new(t[1] + 1.32, t[2] + 1.6, t[3]) * CFrame.Angles(0, -math.pi / 2, 0), V(3, 0.8, 0.05), C.Detonator, { collide = false })
		label(lbl, "PROPANE", C.White)
	end
	-- park strip between the dam toe and the city
	for _, x in { -120, -90, -50, 50, 90, 120 } do
		prop("tree", c, CFrame.new(x, 0, 18 + (x % 3)), { variant = rng:NextInteger(1, 3), flammable = false })
	end
	-- the river the wave ends in, then low suburb silhouettes on the far bank
	local river = part(c, "River", CFrame.new(0, -0.1, 168), V(300, 0.6, 16), C.WaterMid, { transparency = 0.2, material = Enum.Material.Glass })
	river.Reflectance = 0.2
	for _, z in { 159.6, 176.4 } do
		part(c, "RiverBank", CFrame.new(0, 0.25, z), V(300, 0.5, 1.2), C.Kerb)
	end
	-- far-bank skyline silhouettes are a backdrop for the standalone map only: inside the city they
	-- land on the district loop road and the dam's entrance road (the real city is out there instead)
	local inCity = false
	pcall(function()
		local cfg = require(game:GetService("ReplicatedStorage"):WaitForChild("Config"):WaitForChild("CityConfig") :: ModuleScript) :: any
		inCity = cfg.Enabled ~= false
	end)
	if inCity then
		return
	end
	local sky = folder(c, "Skyline")
	local x = -146
	while x < 140 do
		local w = rng:NextInteger(14, 24)
		local h = rng:NextInteger(8, 22)
		local zz = 189 + rng:NextInteger(-2, 3)
		part(sky, "Tower", CFrame.new(x + w / 2, h / 2, zz), V(w - 2, h, 12), C.Navy)
		part(sky, "TowerRoof", CFrame.new(x + w / 2, h + 0.3, zz), V(w - 1.4, 0.6, 12.6), C.NightInk)
		for k = 1, 3 do
			part(sky, "Lit", CFrame.new(x + rng:NextNumber(3, w - 4), rng:NextNumber(3, h - 2), zz - 6.05), V(1.6, 2, 0.1), C.LitWin, { neon = true, collide = false })
		end
		x += w
	end
end

------------------------------------------------------------------------------------------------

function DamBuilder.Build(model: Model, origin: CFrame, rng: Random)
	O = origin
	local mapDir = script.Parent.Parent
	PropKit = tryRequire(mapDir:FindFirstChild("Props"), "PropKit")
	model:SetAttribute("DisplayName", "Mill Creek Dam")

	terrain(model, rng)
	dam(model)
	detonator(model)
	city(model, rng)

	-- tidal wave path: from the dam toe across the city to the skyline (invisible)
	local wave = folder(model, "Wave")
	marker(wave, "WaveStart", facing(0, 20, 8, 0, 1), V(300, 40, 20), T_WAVE, { Role = "Start", Speed = 40 })
	-- HazardService sweeps the part NAMED "WaveVolume" along its LookVector (floor = its bottom face)
	marker(wave, "WaveVolume", facing(0, 20, 89, 0, 1), V(300, 40, 182), T_WAVE, { Role = "Path" })
	marker(wave, "WaveEnd", facing(0, 20, 170, 0, 1), V(300, 40, 20), T_WAVE, { Role = "End" })

	-- truck pull-out on the east plateau, facing the dam road; squad spawn beside it
	local extras = folder(model, "PullOut")
	marker(extras, "TruckSpot", facing(170, CREST + 0.4, -20, -1, 0), V(4, 1, 4), T_TRUCKSPOT, { [Names.Attr.LocationId] = "Dam" })
	marker(extras, "PlayerSpawn", facing(168, CREST + 0.9, -4, -1, 0), V(16, 1, 8), T_PLAYERSPAWN, { [Names.Attr.LocationId] = "Dam" })
	local hy = MapKit.hydrant(extras, O * CFrame.new(162, CREST + 0.4, -32))
	hy.Name = "H1"
	hy:SetAttribute("HydrantId", "H1")
	-- crate of charges by the truck (carry them to D1..D3)
	local crate = part(extras, "ChargeCrate", CFrame.new(184, CREST + 1.4, -6), V(4, 2, 3), C.Wood)
	crate:SetAttribute("Charges", 3)
	local lbl = part(extras, "CrateLabel", CFrame.new(184, CREST + 1.4, -4.48) * CFrame.Angles(0, math.pi, 0), V(3.4, 1, 0.05), C.Hazard, { collide = false })
	label(lbl, "DYNAMITE", C.Ink)
	for k = 0, 2 do
		local dcf = CFrame.new(182.8 + k * 1.2, CREST + 2.9, -6)
		for s = -1, 1 do
			cyl(extras, "Stick", dcf * CFrame.new(0, 0, s * 0.42), "x", 1.6, 0.42, C.Dynamite, { collide = false })
		end
		part(extras, "Fuse", dcf * CFrame.new(0.9, 0.2, 0), V(0.6, 0.1, 0.1), C.Ink, { collide = false })
	end
end

return DamBuilder
