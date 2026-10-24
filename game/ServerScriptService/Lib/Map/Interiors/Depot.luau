--!strict
-- Interiors/Depot [owner: interiors]. Storage-unit warehouses for the storage_fusebox call, built when a run
-- binds the site (Interiors/Furnish):
--   Layouts.storage: BlockFiller's self-storage row (9 roll-door units, a fuse box on the east end
--     wall, a guard booth west of the row). Units get a theme each: the site office (desk, monitor,
--     filing cabinet, water cooler, calendar), pallet racks of boxes, forklifts with a loaded pallet,
--     crate stacks; the rescue units (dog / cat) only get boxes in the back corners. Every unit gets a
--     hazard-striped threshold, a ceiling bulb and a LOADING BAY plate over its door. The solid guard
--     booth becomes a hollow one (window desk with CCTV monitors, a coffee mug, a donut, a chair) and
--     the fuse box gets a striped backboard, a DANGER sign, a conduit and a striped ground mat.
--   Depot.district(model, origin, root, rng): the Stor-Mor district (StorageBuilder): a guard booth
--     by the gate, the office's CCTV desk + mug + water cooler + filing cabinet, a warehouse yard
--     behind strip A (pallet racks, a forklift, crates, a painted loading zone) and a striped mat
--     round the fuse-box pad.
-- The junk box in a fire unit (the FireStart's fuel) stays; the junk in the other units is swapped for
-- the unit's theme. Doors, rescue spots and the unit fronts stay clear.
local Plan = require(script.Parent:WaitForChild("Plan") :: ModuleScript)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Depot = {}

local C = Kit.C
local P = Kit.part
local CF = CFrame.new
local V = Vector3.new
local ANG = CFrame.Angles
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0
local hex = Color3.fromHex

local HAZ = hex("#FFC531")
local KRAFT = hex("#C99A62")
local RACK = hex("#E76F21")
local FRAME = hex("#3D5A80")
local PALLET = hex("#B07A4A")

type Ctx = any

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

-- Yellow / black diagonal stripes over a face.
local function stripes(p: BasePart, face: Enum.NormalId, n: number?)
	local g = Kit.gui(p, face, 8)
	Kit.rect(g, 0, 0, 1, 1, HAZ)
	local k = n or 8
	for i = -2, k + 2 do
		Kit.rect(g, i / k, -0.5, 0.5 / k, 2, C.Black, nil, 35)
	end
end

local function ball(parent: Instance, name: string, cf: CFrame, dia: number, color: Color3, o: any?): Part
	local op = table.clone(o or {})
	op.shape = Enum.PartType.Ball
	return P(parent, name, cf, V(dia, dia, dia), color, op)
end

local function tape(p: BasePart, label: string?)
	local g = Kit.gui(p, Enum.NormalId.Front, 16)
	Kit.rect(g, 0.44, 0, 0.12, 1, hex("#E8D3A8"))
	if label then
		Kit.text(g, 0.08, 0.35, 0.32, 0.3, label, C.Red)
	end
end

---------------------------------------------------------------------------------------------------
-- warehouse props (cf = floor point under the centre, faces -Z)
---------------------------------------------------------------------------------------------------
-- Pallet rack against a wall: two end frames, two beam levels with decks, boxes on every level.
-- o.len (8), o.h (7.5). Depth 2.4.
local function palletRack(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local len, h = o.len or 8, o.h or 7.5
	local m = model("PalletRack")
	local first: BasePart? = nil
	for _, x in { -len / 2 + 0.15, len / 2 - 0.15 } do
		local f = P(m, "RackFrame", cf * CF(x, h / 2, 0), V(0.3, h, 2.4), FRAME, { solid = true })
		local g = Kit.gui(f, Enum.NormalId.Right, 10)
		for k = 0, 3 do
			Kit.rect(g, -0.2, k * 0.25 + 0.1, 1.4, 0.03, C.Chrome, nil, 30)
		end
		first = first or f
	end
	local levels = { 0, h * 0.42, h * 0.84 }
	P(m, "Pallet", cf * CF(0, 0.3, 0), V(len - 0.6, 0.6, 2.2), PALLET, { fuel = 8 })
	for i, y in levels do
		if i > 1 then
			P(m, "RackBeam", cf * CF(0, y - 0.3, -1.05), V(len - 0.6, 0.45, 0.25), RACK)
			P(m, "RackDeck", cf * CF(0, y - 0.15, 0.1), V(len - 0.6, 0.15, 2), C.Steel)
		end
		local base = if i == 1 then 0.6 else y - 0.075
		local room = if i < #levels then levels[i + 1] - 0.45 - base - 0.2 else 1.8
		local bh = math.min(room, rng:NextNumber(1.4, 2.4))
		for _, side in { -1, 1 } do
			if rng:NextNumber() < 0.85 then
				local bw = len / 2 - 0.9
				local b = P(m, "RackBoxes", cf * CF(side * (len / 4 - 0.1), base + bh / 2, 0.05), V(bw, bh, 1.9), KRAFT:Lerp(C.Black, rng:NextNumber(0, 0.12)), { fuel = 10 })
				tape(b, if rng:NextNumber() < 0.3 then "FRAGILE" else nil)
			end
		end
	end
	return done(m, parent, first :: BasePart)
end

-- Forklift, forks toward -Z, a loaded pallet on the forks.
local function forklift(parent: Instance, cf: CFrame, o: any): Model
	local m = model("Forklift")
	local yellow = o.color or C.Mustard
	local body = P(m, "ForkliftBody", cf * CF(0, 1.7, 0.6), V(3, 2.2, 4.2), yellow, { solid = true, fuel = 15 })
	P(m, "Counterweight", cf * CF(0, 1.8, 3.15), V(3, 1.8, 1.1), C.Iron, { solid = true })
	P(m, "ForkliftSeat", cf * CF(0, 3.05, 1.5), V(1.4, 0.5, 1.2), C.Black, { fuel = 3 })
	P(m, "SeatBack", cf * CF(0, 3.7, 2.1), V(1.4, 1.3, 0.3), C.Black, { fuel = 2 })
	for _, x in { -1.35, 1.35 } do
		P(m, "GuardPost", cf * CF(x, 4.6, -0.9), V(0.25, 3.6, 0.25), C.Iron)
	end
	P(m, "GuardRoof", cf * CF(0, 6.5, 0.6), V(3, 0.25, 3.4), C.Iron)
	local mast = P(m, "Mast", cf * CF(0, 3.3, -1.85), V(2.4, 6, 0.4), C.Steel)
	local g = Kit.gui(mast, Enum.NormalId.Front, 10)
	Kit.rect(g, 0.05, 0, 0.12, 1, C.Iron)
	Kit.rect(g, 0.83, 0, 0.12, 1, C.Iron)
	Kit.cylY(m, "SteeringWheel", cf * CF(0, 3.4, 0.2) * ANG(math.rad(-30), 0, 0), 0.15, 1.1, C.Black)
	for _, x in { -0.7, 0.7 } do
		P(m, "Fork", cf * CF(x, 0.35, -3.6), V(0.4, 0.2, 3.4), C.Iron)
	end
	P(m, "Axle", cf * CF(0, 0.7, -0.8) * ANG(0, 0, R90), V(3.3, 1.4, 1.4), C.Black, { shape = Enum.PartType.Cylinder })
	P(m, "Axle", cf * CF(0, 0.6, 2.6) * ANG(0, 0, R90), V(3.1, 1.2, 1.2), C.Black, { shape = Enum.PartType.Cylinder })
	ball(m, "Beacon", cf * CF(1.2, 6.85, 2), 0.5, C.Orange, { neon = true })
	if o.load ~= false then
		P(m, "Pallet", cf * CF(0, 0.65, -3.6), V(2.6, 0.4, 2.6), PALLET, { fuel = 6 })
		local b = P(m, "PalletBoxes", cf * CF(0, 1.85, -3.6), V(2.3, 2, 2.3), KRAFT, { fuel = 10 })
		tape(b, "THIS WAY UP")
	end
	local _ = body
	return done(m, parent, body)
end

-- Wooden crate (planks drawn), o.size.
local function crate(parent: Instance, cf: CFrame, o: any): Model
	local m = model("Crate")
	local s = o.size or 2.6
	local c = P(m, "Crate", cf * CF(0, s / 2, 0), V(s, s, s), hex("#B5803E"), { solid = true, fuel = 14 })
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Right, Enum.NormalId.Top } do
		local g = Kit.gui(c, face, 12)
		for k = 0, 3 do
			Kit.rect(g, 0, k * 0.25 + 0.115, 1, 0.02, hex("#7A4E22"))
		end
		Kit.rect(g, 0, 0, 0.08, 1, hex("#7A4E22"))
		Kit.rect(g, 0.92, 0, 0.08, 1, hex("#7A4E22"))
		if face == Enum.NormalId.Front and o.label then
			Kit.text(g, 0.15, 0.35, 0.7, 0.3, o.label, C.Red, Enum.Font.PermanentMarker)
		end
	end
	return done(m, parent, c)
end

-- A stack of crates (2 on the floor, 1 on top). ~5.6 x 2.8.
local function crateStack(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("CrateStack")
	local labels = { "FRAGILE", "PENGUIN\nFOOD", "SNOW\nGLOBES", "XMAS", "DO NOT\nOPEN" }
	local a = crate(m, cf * CF(-1.4, 0, 0) * ANG(0, rng:NextNumber(-0.1, 0.1), 0), { label = pick(rng, labels) })
	crate(m, cf * CF(1.4, 0, 0.1) * ANG(0, rng:NextNumber(-0.1, 0.1), 0), { size = 2.4, label = pick(rng, labels) })
	crate(m, cf * CF(-0.9, 2.6, 0) * ANG(0, rng:NextNumber(-0.3, 0.3), 0), { size = 2.2 })
	return done(m, parent, a.PrimaryPart :: BasePart)
end

-- Pallet jack (walk-through).
local function palletJack(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("PalletJack")
	local b = P(m, "JackBody", cf * CF(0, 0.6, 1), V(1.4, 1, 0.8), C.Red)
	for _, x in { -0.5, 0.5 } do
		P(m, "JackFork", cf * CF(x, 0.2, -0.8), V(0.4, 0.25, 3.2), C.Red)
	end
	P(m, "JackHandle", cf * CF(0, 2.1, 1.3) * ANG(math.rad(-15), 0, 0), V(0.2, 3, 0.2), C.Iron)
	return done(m, parent, b)
end

-- CCTV monitor (one glowing part: four camera feeds).
local function cctv(parent: Instance, cf: CFrame, label: string)
	local s = P(parent, "CCTVMonitor", cf * CF(0, 0.75, 0), V(2, 1.5, 1.2), C.Ink)
	local g = Kit.gui(s, Enum.NormalId.Front, 30, true)
	for i = 0, 3 do
		local f = Kit.rect(g, 0.05 + (i % 2) * 0.47, 0.06 + (i // 2) * 0.46, 0.43, 0.4, hex("#3E5A48"))
		Kit.rect(f, 0.1, 0.55, 0.8, 0.3, hex("#5E7A62"))
		Kit.text(f, 0.02, 0.02, 0.6, 0.3, `{label}{i + 1}`, C.White)
	end
end

-- Coffee mug with a handle (+ a donut).
local function mug(parent: Instance, cf: CFrame, color: Color3)
	Kit.cylY(parent, "CoffeeMug", cf * CF(0, 0.3, 0), 0.6, 0.55, color)
	P(parent, "MugHandle", cf * CF(0.38, 0.3, 0), V(0.2, 0.35, 0.12), color)
	P(parent, "Donut", cf * CF(-0.9, 0.12, 0.1) * ANG(0, 0, R90), V(0.24, 0.8, 0.8), C.Pink, { shape = Enum.PartType.Cylinder })
end

-- CCTV desk (the guard sits on +Z, looking -Z at the monitors): top, side panels, two monitors, a mug,
-- a chair.
local function securityDesk(parent: Instance, cf: CFrame, o: any): Model
	local m = model("SecurityDesk")
	local top = P(m, "DeskTop", cf * CF(0, 2.65, 0), V(4.6, 0.25, 2.2), C.WoodPale, { solid = true, fuel = 10 })
	for _, x in { -2.1, 2.1 } do
		P(m, "DeskSide", cf * CF(x, 1.26, 0), V(0.3, 2.52, 2), C.Wood, { solid = true })
	end
	local t = cf * CF(0, 2.78, -0.3)
	cctv(m, t * CF(-1.1, 0, 0) * ANG(0, math.pi, 0), "CAM")
	cctv(m, t * CF(1.1, 0, 0) * ANG(0, math.pi, 0), "UNIT")
	mug(m, t * CF(0.3, 0, 0.8), o.mug or C.Red)
	P(m, "ChairSeat", cf * CF(0, 1.6, 2), V(1.8, 0.4, 1.7), C.Navy, { fuel = 4 })
	P(m, "ChairBack", cf * CF(0, 2.7, 2.85), V(1.7, 1.8, 0.3), C.Navy, { fuel = 3 })
	P(m, "ChairPost", cf * CF(0, 0.7, 2), V(0.35, 1.4, 0.35), C.Iron)
	return done(m, parent, top)
end

-- Hollow guard booth (cf = floor centre, -Z = the window side). 6 x 6, 8 tall, door on +X.
local function guardBooth(parent: Instance, cf: CFrame, o: any): Model
	local m = model("GuardBooth")
	local wall = o.color or C.Cream
	local h = 8
	local t = 0.4
	local back = P(m, "BoothPanel", cf * CF(0, h / 2, 3 - t / 2), V(6, h, t), wall, { solid = true, fuel = 18 })
	P(m, "BoothPanel", cf * CF(-3 + t / 2, h / 2, 0), V(t, h, 6 - 2 * t), wall, { solid = true, fuel = 18 })
	-- +X side: door gap z -0.6..1.9
	P(m, "BoothPanel", cf * CF(3 - t / 2, h / 2, -1.8), V(t, h, 2.4 - t), wall, { solid = true, fuel = 12 })
	P(m, "BoothPanel", cf * CF(3 - t / 2, h / 2, 2.25), V(t, h, 0.7), wall, { solid = true, fuel = 6 })
	P(m, "BoothLintel", cf * CF(3 - t / 2, h - 0.6, 0.65), V(t, 1.2, 2.5), wall)
	-- front: low wall, window, header, pillars
	P(m, "BoothPanel", cf * CF(0, 1.75, -3 + t / 2), V(6, 3.5, t), wall, { solid = true, fuel = 12 })
	P(m, "BoothHeader", cf * CF(0, 7.25, -3 + t / 2), V(6, 1.5, t), wall)
	for _, x in { -2.65, 2.65 } do
		P(m, "BoothPillar", cf * CF(x, 5, -3 + t / 2), V(0.7, 3, t), wall)
	end
	P(m, "BoothGlass", cf * CF(0, 5, -3 + t / 2), V(4.6, 3, 0.15), C.Glass, { solid = true, mat = Enum.Material.Glass, tr = 0.55 })
	P(m, "BoothRoof", cf * CF(0, h + 0.2, 0), V(6.8, 0.4, 6.8), C.TealDark)
	local sign = P(m, "BoothSign", cf * CF(0, h + 1, -3.3), V(4.6, 1.2, 0.2), C.Navy)
	Kit.text(Kit.gui(sign, Enum.NormalId.Front, 30), 0.05, 0.1, 0.9, 0.8, "SECURITY", C.White)
	-- inside: the window desk, CCTV, coffee, chair, a little lamp
	P(m, "BoothDesk", cf * CF(0, 3.3, -2.0), V(5.1, 0.25, 1.6), C.WoodLight, { solid = true, fuel = 8 })
	P(m, "BoothDeskLeg", cf * CF(-1.9, 1.6, -2.0), V(0.3, 3.2, 1.2), C.Wood)
	local top = cf * CF(0, 3.42, -2.1)
	cctv(m, top * CF(-1.2, 0, 0.2) * ANG(0, math.pi, 0), "CAM")
	cctv(m, top * CF(1.1, 0, 0.2) * ANG(0, math.pi, 0), "BAY")
	mug(m, top * CF(0.1, 0, -0.4) * CF(0, 0, 0), o.mug or C.Red)
	P(m, "BoothChairSeat", cf * CF(-0.3, 1.9, 0), V(1.8, 0.4, 1.7), C.Navy, { fuel = 4 })
	P(m, "BoothChairBack", cf * CF(-0.3, 3, 0.85), V(1.7, 1.8, 0.3), C.Navy, { fuel = 3 })
	P(m, "BoothChairPost", cf * CF(-0.3, 0.85, 0), V(0.35, 1.7, 0.35), C.Iron)
	local bulb = P(m, "BoothLight", cf * CF(0, h - 0.25, 0.5), V(2, 0.2, 1), C.Lamp, { neon = true })
	local l = Instance.new("PointLight")
	l.Color = C.LampWarm
	l.Range = 10
	l.Brightness = 1
	l.Shadows = false
	l.Parent = bulb
	return done(m, parent, back)
end

-- Ceiling bulb on a cord (cf = the ceiling point).
local function bulb(parent: Instance, cf: CFrame, lit: boolean)
	P(parent, "BulbCord", cf * CF(0, -0.6, 0), V(0.12, 1.2, 0.12), C.Black)
	local b = ball(parent, "Bulb", cf * CF(0, -1.5, 0), 0.8, C.Lamp, { neon = true })
	if lit then
		local l = Instance.new("PointLight")
		l.Color = C.LampWarm
		l.Range = 14
		l.Brightness = 0.8
		l.Shadows = false
		l.Parent = b
	end
end

-- Thin striped mat on the floor (walk-through). cf = floor point; o.w, o.d.
local function hazardMat(parent: Instance, cf: CFrame, o: any): Model
	local m = model("HazardStripe")
	local p = P(m, "HazardStripe", cf * CF(0, 0.04, 0), V(o.w or 4, 0.06, o.d or 1), HAZ)
	p.CastShadow = false
	stripes(p, Enum.NormalId.Top, math.max(4, math.floor((o.w or 4) / 0.8)))
	return done(m, parent, p)
end

-- Painted outline of a loading zone (four thin strips) + a stencil on the ground. cf = floor point.
local function zoneLines(parent: Instance, cf: CFrame, o: any): Model
	local m = model("LoadingZone")
	local w, d = o.w or 12, o.d or 10
	local first = P(m, "ZoneLine", cf * CF(0, 0.04, -d / 2), V(w, 0.06, 0.5), HAZ)
	P(m, "ZoneLine", cf * CF(0, 0.04, d / 2), V(w, 0.06, 0.5), HAZ)
	P(m, "ZoneLine", cf * CF(-w / 2, 0.04, 0), V(0.5, 0.06, d - 0.5), HAZ)
	P(m, "ZoneLine", cf * CF(w / 2, 0.04, 0), V(0.5, 0.06, d - 0.5), HAZ)
	local st = P(m, "ZoneStencil", cf * CF(0, 0.04, d / 2 - 1.6), V(w - 2, 0.06, 2), C.Black, { tr = 1 })
	Kit.text(Kit.gui(st, Enum.NormalId.Top, 12), 0, 0, 1, 1, o.text or "LOADING ZONE", HAZ)
	for _, p in m:GetChildren() do
		(p :: BasePart).CastShadow = false
	end
	return done(m, parent, first)
end

-- Small site office corner against a back wall (cf = the back-wall face at floor height, -Z into the
-- unit): desk + monitor + chair, filing cabinet, calendar, a coffee machine on the cabinet.
local function officeCorner(ctx: Ctx, xc: number, hw: number, rng: Random)
	local y = ctx.floors[1]
	local d = ctx.d
	local dw = math.min(4, 2 * hw - 2.6)
	ctx:put(1, Kit.desk, xc - hw + 0.3 + dw / 2, d - 1.6, S, dw + 0.2, 4.6, { w = dw, chair = C.Navy, color = C.WoodPale })
	if ctx:put(1, Kit.filingCabinet, xc + hw - 1.2, d - 1.8, N, 2.2, 2.6, { color = C.Mustard }) then
		P(ctx.root, "CoffeeMaker", ctx:at(xc + hw - 1.2, y + 5.6, d - 1.8), V(1.2, 1.2, 1.2), C.Ink)
	end
	ctx:put(1, Kit.plant, xc - hw + 0.9, 2.8, N, 1.8, 1.8, { size = 0.9 })
	ctx:add(Kit.poster, ctx:at(xc - hw, y, d * 0.55, E), { w = 2.2, h = 2.8, y = 6, text = "OCTOBER\n\n1 2 3 4 5\n6 7 8 ...", bg = C.White })
	ctx:add(Kit.poster, ctx:at(xc + hw, y, d * 0.5, W), { w = 2.4, h = 3, y = 6, text = "EMPLOYEE\nOF THE\nMONTH:\nBOB", bg = C.Mustard })
	ctx:put(1, Kit.trashCan, xc + hw - 0.9, d * 0.45, N, 1.6, 1.6, {})
	local _ = rng
end

---------------------------------------------------------------------------------------------------
-- BlockFiller storage row
---------------------------------------------------------------------------------------------------
local THEMES = { "office", "racks", "light", "forklift", "crates", "racks", "light", "racks", "forklift" }

local function storage(ctx: Ctx)
	local rng = ctx.rng
	local w, d, H = ctx.w, ctx.d, ctx.H
	local y = ctx.floors[1]
	local units = 9
	local uw = w / units
	local hw = uw / 2 - 0.5
	local placer = ctx.placers[1]
	local inv = ctx.F:Inverse()
	-- junk boxes: keep the fire units' (their FireStart burns them), swap the rest
	local fireUnit: { [number]: boolean } = {}
	local rescueUnit: { [number]: boolean } = {}
	local junk: { { part: BasePart, x: number, z: number, k: number } } = {}
	for _, p in ctx.site:GetDescendants() do
		if p:IsA("BasePart") then
			local l = (inv * p.CFrame).Position
			local k = math.clamp(math.floor((l.X + w / 2) / uw) + 1, 1, units)
			local inside = l.X > -w / 2 and l.X < w / 2 and l.Z > 0 and l.Z < d
			if not inside then
				continue
			elseif p:HasTag("FireStart") then
				fireUnit[k] = true
			elseif p:HasTag("RescueSpawn") then
				rescueUnit[k] = true
			elseif p.Name == "Junk" and p.Parent == ctx.site then
				table.insert(junk, { part = p, x = l.X, z = l.Z, k = k })
			end
		end
	end
	for _, j in junk do
		if not fireUnit[j.k] then
			-- drop its keep-out too
			for i = #placer.keeps, 1, -1 do
				local r = placer.keeps[i]
				if math.abs((r.x0 + r.x1) / 2 - j.x) < 0.05 and math.abs((r.z0 + r.z1) / 2 - j.z) < 0.05 then
					table.remove(placer.keeps, i)
				end
			end
			j.part:Destroy()
		end
	end
	-- every door gap + 3 studs inside stays clear
	for k = 1, units do
		local xc = -w / 2 + (k - 0.5) * uw
		placer:keep(Plan.span(xc - (uw - 4) / 2, 0, xc + (uw - 4) / 2, 3.5))
	end
	for k = 1, units do
		local xc = -w / 2 + (k - 0.5) * uw
		local theme = if rescueUnit[k] then "light" else THEMES[(k - 1) % #THEMES + 1]
		if theme == "light" and not rescueUnit[k] then
			theme = "crates"
		end
		if theme == "office" and fireUnit[k] then
			theme = "racks"
		end
		local ok, err = pcall(function()
			if theme == "office" then
				officeCorner(ctx, xc, hw, rng)
				ctx:add(Kit.sign, ctx:at(xc, y, 0.5, S), { text = "OFFICE", y = 9.2, w = 3.2, bg = C.Navy })
			elseif theme == "racks" then
				ctx:put(1, palletRack, xc, d - 1.8, N, math.min(2 * hw - 0.4, 10.4), 2.6, { len = math.min(2 * hw - 0.6, 10), h = math.min(H - 3, 7.5) })
				ctx:put(1, palletJack, xc - hw + 1.2, d * 0.45, N, 1.6, 3.4, {})
			elseif theme == "forklift" then
				if not ctx:put(1, forklift, xc, d * 0.5, N, 3.4, 7.6, { color = pick(rng, { C.Mustard, C.Orange }) }) then
					ctx:put(1, crateStack, xc, d - 2, N, 5.6, 2.8, {})
				end
				ctx:put(1, crate, xc + hw - 1.5, d - 1.8, N, 2.8, 2.8, { label = "PARTS" })
			elseif theme == "crates" then
				ctx:put(1, crateStack, xc, d - 2, N, 5.6, 2.8, {})
				ctx:put(1, Kit.boxes, xc - hw + 1.6, d * 0.42, N, 3.4, 2.6, {})
			else -- light: boxes in the back corners only, the middle stays clear
				ctx:put(1, Kit.boxes, xc - hw + 1.6, d - 1.6, N, 3.4, 2.6, {})
				ctx:put(1, crate, xc + hw - 1.5, d - 1.6, N, 2.8, 2.8, { label = "FRAGILE" })
			end
		end)
		if not ok then
			warn(`[Depot] unit {k} ({theme}): {err}`)
		end
		-- threshold stripe, ceiling bulb, bay plate on the lintel outside
		ctx:add(hazardMat, ctx:at(xc, y, 1.2), { w = uw - 4.2, d = 1.2 })
		bulb(ctx.root, ctx:at(xc, y + H, d * 0.5), k % 2 == 1)
		local plate = P(ctx.root, "BayPlate", ctx:at(xc, y + 9.4, -0.56), V(math.min(5, uw - 4), 1.1, 0.1), C.Navy)
		Kit.text(Kit.gui(plate, Enum.NormalId.Front, 30), 0.04, 0.1, 0.92, 0.8, `BAY {k}`, C.White)
	end
	-- guard booth: the builder's solid box becomes a hollow one on the same spot
	local booth = ctx.site:FindFirstChild("Booth")
	if booth and booth:IsA("BasePart") then
		local l = inv * booth.CFrame
		local bx, bz = l.Position.X, l.Position.Z
		local by = l.Position.Y - booth.Size.Y / 2
		booth:Destroy()
		local win = ctx.site:FindFirstChild("BoothWindow")
		if win then
			win:Destroy()
		end
		ctx:add(guardBooth, ctx:at(bx, by, bz), { mug = pick(rng, { C.Red, C.Teal, C.Mustard }) })
	end
	-- fuse box: striped backboard, DANGER sign, conduit up to the roof, a striped mat on the ground
	local fuse = ctx.site:FindFirstChild("FuseBox", true)
	if fuse and fuse:IsA("BasePart") then
		local l = inv * fuse.CFrame
		local fx, fyy, fz = w / 2 + 0.6, l.Position.Y, l.Position.Z
		local board = P(ctx.root, "FuseBackboard", ctx:at(fx, fyy, fz, W), V(3.4, 4.4, 0.1), HAZ)
		stripes(board, Enum.NormalId.Back, 6)
		stripes(board, Enum.NormalId.Front, 6)
		local s = P(ctx.root, "DangerSign", ctx:at(w / 2 + 0.56, fyy + 3.3, fz - 0.6, W), V(2.8, 1.6, 0.1), C.White)
		local g = Kit.gui(s, Enum.NormalId.Back, 30)
		Kit.rect(g, 0, 0, 1, 0.38, C.Red)
		Kit.text(g, 0.05, 0.03, 0.9, 0.32, "DANGER", C.White)
		Kit.text(g, 0.05, 0.45, 0.9, 0.45, "HIGH VOLTAGE\nKEEP FEET DRY", C.Ink)
		P(ctx.root, "Conduit", ctx:at(w / 2 + 0.75, (fyy - 0.8 + y + H) / 2, fz + 1.2), V(0.35, y + H - fyy + 0.8, 0.35), C.Iron)
		local rp = RaycastParams.new()
		rp.FilterType = Enum.RaycastFilterType.Exclude
		rp.FilterDescendantsInstances = { ctx.root, fuse }
		local origin = ctx:at(w / 2 + 3, y + 4, fz).Position
		local hit = workspace:Raycast(origin, Vector3.new(0, -12, 0), rp)
		if hit then
			local gy = (inv * CFrame.new(hit.Position)).Position.Y
			ctx:add(hazardMat, ctx:at(w / 2 + 3, gy, fz, W), { w = 4.4, d = 3.4 })
		end
	end
end

---------------------------------------------------------------------------------------------------
-- Stor-Mor district (StorageBuilder local frame: origin = slot centre, +X east, +Z south)
--   office x -66..-40, z 58..80 (door -47 on z 80; counter (-56, 70), chair, plant (-64.4, 78),
--   bookshelf (-50, 59.4), box stack (-62, 61.6)); gate x -12..12 on z 96, keypad (-15, 100);
--   strip A x -48..48, z -22..-10 (back wall z -22.5), fence z -50; fuse pad (-54, -4) 5 x 3.4.
---------------------------------------------------------------------------------------------------
function Depot.district(_model: Model, origin: CFrame, root: Model, rng: Random)
	local function at(x: number, y: number, z: number, yaw: number?): CFrame
		return origin * CF(x, y, z) * ANG(0, yaw or 0, 0)
	end
	local function put(fn: any, cf: CFrame, o: any?): Model
		local op = o or {}
		op.rng = rng
		return fn(root, cf, op)
	end
	-- guard booth inside the gate, window toward the driveway (-X)
	put(guardBooth, at(19, 0.15, 86, W), { color = C.Cream, mug = C.Teal })
	-- office: CCTV desk on the east wall, a water cooler, a filing cabinet, a calendar
	put(securityDesk, at(-41.7, 0.6, 63, E), { mug = C.Red })
	put(Kit.filingCabinet, at(-64.6, 0.6, 70.5, E), { color = C.Steel })
	put(Kit.filingCabinet, at(-64.6, 0.6, 73, E), { color = C.Mustard })
	put(Kit.poster, at(-40.5, 0.6, 70, W), { w = 2.6, h = 3.2, y = 6, text = "UNIT\nPRICES\nS $9\nM $19\nL $67", bg = C.White })
	put(Kit.clock, at(-53, 0.6, 58.5, S), { y = 8.2, rim = C.Teal })
	-- warehouse yard behind strip A: racks along the fence, a forklift, crates, a loading zone
	for _, x in { -30, -18 } do
		put(palletRack, at(x, 0.15, -47.2), { len = 10, h = 7.5 })
	end
	put(zoneLines, at(-8, 0.15, -38), { w = 14, d = 10 })
	put(forklift, at(-8, 0.15, -38, W), { color = C.Mustard })
	put(crateStack, at(8, 0.15, -46.6), {})
	put(crate, at(13, 0.15, -46.4), { label = "XMAS" })
	put(palletJack, at(-36, 0.15, -40, W), {})
	-- fuse pad: striped mat round it
	put(hazardMat, at(-54, 0.16, -4), { w = 7, d = 6 })
end

function Depot.register(Furnish: any)
	Furnish.Layouts.storage = storage
end

return Depot
