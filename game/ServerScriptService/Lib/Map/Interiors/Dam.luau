--!strict
-- Interiors/Dam [owner: interiors]. Mill Creek Dam dressing for dam_finale, built when a run binds the dam
-- district (Interiors/Furnish -> Interiors/Districts.Dam). The finale itself happens outdoors (charges on
-- the deck, civilians walked to high ground), so this adds the dam's CONTROL HOUSE on the east plateau
-- beside the squad spawn: DamBuilder local frame (origin = slot centre, +X east, +Z south), plateau top
-- y 60 for x 150..200; truck spot (170, -20), squad spawn (168, -4) 16 x 8, charge crate (184, -6),
-- hydrant (162, -32), the city road comes up the cliff ramp at x 138..150. The house stands at
-- x 178..192, z 8..26 (front door facing the dam, west), clear of all of those.
--   Inside: a console bank under the front windows (buttons, sliders, two operator chairs), a wall of
--   screens (water level, the burning city map, spillway CCTV), three big levers (SPILLWAY / TURBINE /
--   DO NOT PULL), a row of pressure gauges, pipes along the ceiling and down the back corner with valve
--   wheels, a turbine-hall hatch, a coffee corner, an EXIT sign. Outside: a roof catwalk with a railing,
--   a radio mast with a beacon, a big penstock pipe running off toward the dam, and a fenced transformer
--   (the escalation's "transformer by the dam") on a striped pad.
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Dam = {}

local C = Kit.C
local P = Kit.part
local CF = CFrame.new
local V = Vector3.new
local ANG = CFrame.Angles
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0
local hex = Color3.fromHex

local CONCRETE = hex("#B89A7E")
local CONCRETE_DARK = hex("#9A7E66")
local CONSOLE = hex("#3D5A80")
local PIPE = hex("#2A9D8F")
local PIPE_RED = hex("#C8232B")
local HAZ = hex("#FFC531")

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

-- cylinder along local X
local function pipe(parent: Instance, name: string, cf: CFrame, len: number, dia: number, color: Color3, o: any?): Part
	local op = table.clone(o or {})
	op.shape = Enum.PartType.Cylinder
	return P(parent, name, cf, V(len, dia, dia), color, op)
end

local function stripes(p: BasePart, face: Enum.NormalId)
	local g = Kit.gui(p, face, 8)
	Kit.rect(g, 0, 0, 1, 1, HAZ)
	for i = -2, 12 do
		Kit.rect(g, i / 10, -0.5, 0.05, 2, C.Black, nil, 35)
	end
end

---------------------------------------------------------------------------------------------------
-- control-room props (cf = floor point, faces -Z)
---------------------------------------------------------------------------------------------------
-- Console desk: a body with a sloped control panel drawn with buttons and sliders. o.w (5).
local function console(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local w = o.w or 5
	local m = model("Console")
	local body = P(m, "ConsoleBody", cf * CF(0, 1.5, 0.2), V(w, 3, 2.2), CONSOLE, { solid = true, fuel = 12 })
	local panel = P(m, "ConsolePanel", cf * CF(0, 3.25, 0.55) * ANG(math.rad(-25), 0, 0), V(w, 0.2, 1.8), C.Iron)
	local g = Kit.gui(panel, Enum.NormalId.Top, 30, true)
	for k = 0, 7 do
		Kit.rect(g, 0.06 + k * 0.115, 0.15, 0.07, 0.2, pick(rng, { C.Red, C.Green, C.Mustard, C.Blue, C.White }), 1)
	end
	for k = 0, 4 do
		Kit.rect(g, 0.08 + k * 0.18, 0.5, 0.03, 0.38, C.Steel)
		Kit.rect(g, 0.06 + k * 0.18, 0.5 + rng:NextNumber(0, 0.3), 0.07, 0.08, C.White)
	end
	local scr = P(m, "ConsoleScreen", cf * CF(0, 4.3, 1.15) * ANG(math.rad(-10), 0, 0), V(w * 0.45, 1.3, 0.15), C.Ink)
	local sg = Kit.gui(scr, Enum.NormalId.Front, 30, true)
	Kit.rect(sg, 0.05, 0.08, 0.9, 0.84, hex("#0F2A2A"))
	for k = 0, 5 do
		local h = rng:NextNumber(0.2, 0.7)
		Kit.rect(sg, 0.1 + k * 0.13, 0.85 - h, 0.08, h, C.ExitGreen)
	end
	-- the operator's chair (walk-through) on -Z
	P(m, "ChairSeat", cf * CF(0, 1.6, -1.8), V(1.8, 0.4, 1.7), C.Ink, { fuel = 4 })
	P(m, "ChairBack", cf * CF(0, 2.7, -2.65), V(1.7, 1.8, 0.3), C.Ink, { fuel = 3 })
	P(m, "ChairPost", cf * CF(0, 0.7, -1.8), V(0.35, 1.4, 0.35), C.Iron)
	return done(m, parent, body)
end

-- Wall screen (cf = wall face): o.kind "level" | "city" | "cctv", o.w, o.h, o.y.
local function wallScreen(parent: Instance, cf: CFrame, o: any): Model
	local m = model("WallScreen")
	local w, h = o.w or 5, o.h or 3
	P(m, "ScreenBezel", cf * CF(0, o.y or 6, -0.1), V(w + 0.4, h + 0.4, 0.15), C.Ink)
	local s = P(m, "Screen", cf * CF(0, o.y or 6, -0.2), V(w, h, 0.08), hex("#0F2A2A"), { neon = true })
	local g = Kit.gui(s, Enum.NormalId.Front, 30, true)
	if o.kind == "level" then
		Kit.text(g, 0.05, 0.04, 0.9, 0.16, "RESERVOIR LEVEL", C.White)
		Kit.rect(g, 0.3, 0.25, 0.4, 0.68, hex("#24242A"))
		Kit.rect(g, 0.3, 0.27, 0.4, 0.66, hex("#3E8C9E"))
		Kit.text(g, 0.72, 0.25, 0.26, 0.2, "98%", C.Red)
		Kit.text(g, 0.72, 0.5, 0.26, 0.2, "!!", C.Red)
	elseif o.kind == "city" then
		Kit.text(g, 0.05, 0.04, 0.9, 0.16, "MILL CREEK  -  FIRE MAP", C.White)
		for k = 0, 11 do
			Kit.rect(g, 0.08 + (k % 4) * 0.22, 0.28 + (k // 4) * 0.22, 0.16, 0.16, hex("#2F5F5A"))
		end
		for _, f in { { 0.15, 0.35 }, { 0.6, 0.55 }, { 0.38, 0.72 }, { 0.8, 0.32 } } do
			Kit.rect(g, f[1], f[2], 0.07, 0.1, C.Orange, 1)
		end
	else
		for i = 0, 3 do
			local f = Kit.rect(g, 0.04 + (i % 2) * 0.48, 0.05 + (i // 2) * 0.47, 0.44, 0.42, hex("#3E5A48"))
			Kit.rect(f, 0, 0.6, 1, 0.4, hex("#3E8C9E"))
			Kit.text(f, 0.03, 0.03, 0.6, 0.25, `SPILL {i + 1}`, C.White)
		end
	end
	return done(m, parent, s)
end

-- A giant lever on a base box (cf = floor point by a wall). o.label, o.color, o.down.
local function lever(parent: Instance, cf: CFrame, o: any): Model
	local m = model("BigLever")
	local base = P(m, "LeverBase", cf * CF(0, 1.4, 0), V(2.2, 2.8, 1.6), C.Steel, { solid = true })
	local tilt = if o.down then math.rad(40) else math.rad(-40)
	local pivot = cf * CF(0, 2.9, -0.2)
	P(m, "LeverSlot", cf * CF(0, 2.82, -0.2), V(0.4, 0.05, 1.4), C.Black)
	P(m, "LeverRod", pivot * ANG(tilt, 0, 0) * CF(0, 1.6, 0), V(0.3, 3.2, 0.3), C.Chrome)
	ball(m, "LeverKnob", pivot * ANG(tilt, 0, 0) * CF(0, 3.3, 0), 0.9, o.color or C.Red)
	local lab = P(m, "LeverLabel", cf * CF(0, 1.9, -0.82), V(1.9, 0.7, 0.05), C.White)
	Kit.text(Kit.gui(lab, Enum.NormalId.Front, 40), 0.03, 0.05, 0.94, 0.9, o.label or "LEVER", C.Ink)
	return done(m, parent, base)
end

-- Round pressure gauge on a wall (cf = wall face). o.y, o.angle (needle degrees).
local function gauge(parent: Instance, cf: CFrame, o: any): Model
	local m = model("Gauge")
	local rim = P(m, "GaugeRim", cf * CF(0, o.y or 6, -0.1) * ANG(0, R90, 0), V(0.2, 1.8, 1.8), C.Gold, { shape = Enum.PartType.Cylinder })
	local face = P(m, "GaugeFace", cf * CF(0, o.y or 6, -0.22) * ANG(0, R90, 0), V(0.06, 1.5, 1.5), C.White, { shape = Enum.PartType.Cylinder })
	local g = Kit.gui(face, Enum.NormalId.Right, 40)
	Kit.rect(g, 0.15, 0.15, 0.7, 0.7, C.White, 1)
	Kit.rect(g, 0.62, 0.2, 0.2, 0.2, C.Red, 1).BackgroundTransparency = 0.4
	Kit.rect(g, 0.5, 0.48, 0.34, 0.05, C.Ink, nil, o.angle or -30)
	local _ = rim
	return done(m, parent, face)
end

-- Valve wheel on a pipe (cf = wheel centre, axis along local Z).
local function valve(parent: Instance, cf: CFrame, color: Color3)
	P(parent, "ValveWheel", cf * ANG(0, R90, 0), V(0.25, 1.6, 1.6), color, { shape = Enum.PartType.Cylinder })
	P(parent, "ValveSpoke", cf, V(1.5, 0.15, 0.2), color)
	P(parent, "ValveSpoke", cf, V(0.15, 1.5, 0.2), color)
end

---------------------------------------------------------------------------------------------------
-- the control house (cf = front-centre on the plateau, -Z = the front wall, faces the dam)
-- building frame: x across the front (-9..9), z 0 (front) .. 14 (back), floor top y 0.42
---------------------------------------------------------------------------------------------------
local BW, BD, BH = 18, 14, 10

local function controlHouse(root: Instance, F: CFrame, rng: Random)
	local m = model("ControlHouse")
	m.Parent = root
	local fy = 0.42
	local t = 0.8
	local function at(x: number, y: number, z: number, yaw: number?): CFrame
		return F * CF(x, y, z) * ANG(0, yaw or 0, 0)
	end
	local function wall(name: string, cx: number, cy: number, cz: number, sx: number, sy: number, sz: number, col: Color3?)
		return P(m, name, at(cx, cy, cz), V(sx, sy, sz), col or CONCRETE, { solid = true })
	end
	P(m, "HouseSlab", at(0, 0.22, BD / 2), V(BW + 1, 0.4, BD + 1), CONCRETE_DARK, { solid = true })
	local floorTop = P(m, "HouseFloor", at(0, fy + 0.04, BD / 2), V(BW - 2 * t, 0.06, BD - 2 * t), hex("#5A6370"))
	Kit.rect(Kit.gui(floorTop, Enum.NormalId.Top, 4), 0.05, 0.05, 0.9, 0.9, hex("#4A525E")).BackgroundTransparency = 0.5
	-- back + side walls (solid concrete), front: door gap x 4.5..8.5, window band y 3.5..7
	wall("HouseWall", 0, fy + BH / 2, BD - t / 2, BW, BH, t)
	wall("HouseWall", -BW / 2 + t / 2, fy + BH / 2, BD / 2, t, BH, BD - 2 * t)
	wall("HouseWall", BW / 2 - t / 2, fy + BH / 2, BD / 2, t, BH, BD - 2 * t)
	local dx0, dx1 = 4.5, 8.5
	wall("HouseFront", (-BW / 2 + dx0) / 2, fy + 1.75, t / 2, dx0 + BW / 2, 3.5, t)
	wall("HouseFront", (dx1 + BW / 2) / 2, fy + 1.75, t / 2, BW / 2 - dx1, 3.5, t)
	wall("HouseFront", (-BW / 2 + dx0) / 2, fy + (7 + BH) / 2, t / 2, dx0 + BW / 2, BH - 7, t)
	wall("HouseFront", (dx1 + BW / 2) / 2, fy + (7 + BH) / 2, t / 2, BW / 2 - dx1, BH - 7, t)
	wall("HouseFront", (dx1 + BW / 2) / 2, fy + 5.25, t / 2, BW / 2 - dx1, 3.5, t)
	wall("HouseLintel", (dx0 + dx1) / 2, fy + (7.5 + BH) / 2, t / 2, dx1 - dx0, BH - 7.5, t)
	for _, x in { -5.5, -0.5 } do
		wall("Mullion", x, fy + 5.25, t / 2, 0.5, 3.5, t, CONCRETE_DARK)
	end
	P(m, "HouseWindow", at((-BW / 2 + dx0) / 2, fy + 5.25, t / 2), V(dx0 + BW / 2 - 0.1, 3.45, 0.2), C.Glass, { solid = true, mat = Enum.Material.Glass, tr = 0.5 })
	P(m, "HouseRoof", at(0, fy + BH + 0.3, BD / 2), V(BW + 1.2, 0.6, BD + 1.2), CONCRETE_DARK, { solid = true })
	local sign = P(m, "HouseSign", at(-3, fy + 8.6, -0.12), V(8, 1.4, 0.2), C.Navy)
	Kit.text(Kit.gui(sign, Enum.NormalId.Front, 30), 0.03, 0.1, 0.94, 0.8, "DAM CONTROL", C.White)
	local warn = P(m, "DoorSign", at(6.5, fy + 8.6, -0.12), V(3.6, 1, 0.15), HAZ)
	Kit.text(Kit.gui(warn, Enum.NormalId.Front, 30), 0.03, 0.1, 0.94, 0.8, "STAFF ONLY", C.Ink)
	-- consoles under the window band, facing the window (operators look out at the dam)
	for _, x in { -6, -1 } do
		console(m, at(x, fy, 2.4, S), { w = 4.6, rng = rng })
	end
	-- screens on the back wall
	local bz = BD - t
	for i, k in { "level", "city", "cctv" } do
		wallScreen(m, at(-6 + (i - 1) * 5.2, fy, bz, N), { kind = k, w = 4.6, h = 2.8, y = 6.2 })
	end
	-- big levers on the west (left) wall, gauges on the east (right) wall
	for i, l in { { "SPILLWAY", C.Red, false }, { "TURBINE 1", C.Mustard, true }, { "DO NOT\nPULL", C.Pink, false } } do
		lever(m, at(-BW / 2 + t + 1, fy, 4 + i * 2.6, E), { label = l[1], color = l[2], down = l[3] })
	end
	for i = 0, 3 do
		gauge(m, at(BW / 2 - t, fy, 5 + i * 2.2, W), { y = 5.6 + (i % 2) * 1.6, angle = -60 + i * 35 })
	end
	-- pipes: along the ceiling and down the back-right corner, valve wheels
	pipe(m, "Pipe", at(0, fy + BH - 1.1, BD - t - 0.8), BW - 2 * t, 1, PIPE)
	pipe(m, "Pipe", at(0, fy + BH - 2.05, BD - t - 0.7), BW - 2 * t, 0.7, PIPE_RED)
	pipe(m, "Pipe", at(BW / 2 - t - 0.8, fy + (BH - 1.1) / 2, BD - t - 0.8) * ANG(0, 0, R90), BH - 1.1, 1, PIPE)
	valve(m, at(BW / 2 - t - 0.8, fy + 5, BD - t - 1.6), C.Red)
	valve(m, at(-2, fy + BH - 2.05, BD - t - 1.45), C.Mustard)
	-- turbine-hall hatch in the floor (back-left), with a striped rim and a sign
	local hatch = P(m, "TurbineHatch", at(1.5, fy + 0.1, 9.6), V(3.4, 0.08, 2.8), C.Steel)
	local hg = Kit.gui(hatch, Enum.NormalId.Top, 12)
	for k = 0, 5 do
		Kit.rect(hg, 0, 0.08 + k * 0.16, 1, 0.04, C.Iron)
	end
	local rim = P(m, "HatchRim", at(1.5, fy + 0.08, 9.6), V(4.2, 0.06, 3.6), HAZ)
	stripes(rim, Enum.NormalId.Top)
	local hs = P(m, "HatchSign", at(1.5, fy + 3.4, BD - t - 0.06), V(3, 0.8, 0.1), C.White)
	Kit.text(Kit.gui(hs, Enum.NormalId.Front, 30), 0.03, 0.05, 0.94, 0.9, "TURBINE HALL  v", C.Ink)
	-- coffee corner on the back-right, an EXIT sign over the door, a ceiling light
	local cc = P(m, "CoffeeCart", at(5.5, fy + 1.4, BD - t - 1.2), V(2.6, 2.8, 1.6), C.Steel, { solid = true, fuel = 6 })
	local _ = cc
	P(m, "CoffeeMachine", at(5, fy + 3.5, BD - t - 1.2), V(1.1, 1.4, 1), C.Ink)
	Kit.cylY(m, "CoffeeMug", at(6.1, fy + 3.1, BD - t - 1.2), 0.5, 0.45, C.Red)
	P(m, "Papers", at(-3.5, fy + 3.55, 2.7) * ANG(0, 0.3, 0), V(1.2, 0.1, 0.9), C.White, { fuel = 2 })
	Kit.exitSign(m, at((dx0 + dx1) / 2, fy, t, S), { y = 8.2 })
	Kit.ceilingLight(m, at(-2, fy + BH, 6), { len = 8, range = 20 })
	Kit.ceilingLight(m, at(5, fy + BH, 6), { len = 4, range = 14, light = false })
	-- roof catwalk railing + a radio mast with a beacon
	local ry = fy + BH + 0.6
	for _, e in { { 0, -0.2, BW + 1.2, 0.2 }, { 0, BD + 0.2, BW + 1.2, 0.2 }, { -BW / 2 - 0.2, BD / 2, 0.2, BD + 1.2 }, { BW / 2 + 0.2, BD / 2, 0.2, BD + 1.2 } } do
		P(m, "CatwalkRail", at(e[1], ry + 2.4, e[2]), V(e[3], 0.2, e[4]), HAZ)
	end
	for _, c in { { -BW / 2 - 0.2, -0.2 }, { BW / 2 + 0.2, -0.2 }, { -BW / 2 - 0.2, BD + 0.2 }, { BW / 2 + 0.2, BD + 0.2 } } do
		P(m, "RailPost", at(c[1], ry + 1.2, c[2]), V(0.25, 2.4, 0.25), C.Iron)
	end
	P(m, "RadioMast", at(6, ry + 6, 10), V(0.4, 12, 0.4), C.Steel)
	local beacon = ball(m, "MastBeacon", at(6, ry + 12.3, 10), 0.9, C.Red, { neon = true })
	local l = Instance.new("PointLight")
	l.Color = C.Red
	l.Range = 16
	l.Brightness = 1.2
	l.Shadows = false
	l.Parent = beacon
	m.PrimaryPart = floorTop
end

function Dam.district(_model: Model, origin: CFrame, root: Model, rng: Random)
	local CREST = 60
	-- the control house: front (door) faces west, toward the dam
	local F = origin * CF(178, CREST, 17) * ANG(0, W, 0)
	controlHouse(root, F, rng)
	-- penstock pipes along the house's back (east) wall, on saddles (walk-through)
	local pen = origin * CF(194.4, CREST + 1.6, 17) * ANG(0, R90, 0)
	pipe(root, "Penstock", pen, 22, 2.6, PIPE)
	pipe(root, "Penstock", pen * CF(0, 2.6, 0.2), 22, 1.4, PIPE_RED)
	for _, x in { -8, 0, 8 } do
		P(root, "PipeSaddle", pen * CF(x, -0.85, 0), V(0.8, 1.5, 2.8), CONCRETE_DARK)
	end
	valve(root, pen * CF(-11.2, 0, 0) * ANG(0, R90, 0), C.Red)
	-- fenced transformer on a striped pad south of the house
	local tcf = origin * CF(186, CREST, 34)
	local pad = P(root, "TransformerPad", tcf * CF(0, 0.07, 0), V(9, 0.1, 7), HAZ)
	stripes(pad, Enum.NormalId.Top)
	P(root, "Transformer", tcf * CF(0, 2.6, 0), V(4.4, 5, 3), hex("#6B705C"), { solid = true })
	for k = -1, 1 do
		P(root, "Insulator", tcf * CF(k * 1.4, 5.8, 0), V(0.5, 1.4, 0.5), C.White)
	end
	local tw = P(root, "TransformerSign", tcf * CF(0, 3, -1.56), V(2.6, 1.3, 0.1), C.White)
	local g = Kit.gui(tw, Enum.NormalId.Front, 30)
	Kit.rect(g, 0, 0, 1, 0.35, C.Red)
	Kit.text(g, 0.05, 0.02, 0.9, 0.31, "DANGER", C.White)
	Kit.text(g, 0.05, 0.4, 0.9, 0.55, "10,000 VOLTS\n(probably)", C.Ink)
	for _, e in { { 0, -3.4, 8.6, 0.2 }, { 0, 3.4, 8.6, 0.2 }, { -4.3, 0, 0.2, 6.6 }, { 4.3, 0, 0.2, 6.6 } } do
		P(root, "TransformerFence", tcf * CF(e[1], 2.2, e[2]), V(e[3], 4.4, e[4]), C.Steel, { mat = Enum.Material.DiamondPlate, tr = 0.5 })
	end
end

return Dam
