--!strict
-- Interiors/Office [owner: interiors]. The Sky Tower (BlockFiller skyscraper) fitted out when a run binds it
-- (Interiors/Furnish). Building frame: x across the front (-w/2..w/2), z from the front wall (0) to the
-- back (d); the stair lanes run up the left wall (x < -w/2 + 9.5, flights z 2..18).
--   Lobby (storey 1): marble floor, a reception desk with the SKY TOWER feature wall (on the builder's
--     LobbyDesk spot), two elevators on the right wall, a waiting area, directory board, big plants.
--   Offices (storeys 2..n): every floor keeps a front strip (ladder rescues at the windows), a main aisle
--     from the stair landing across the floor (z 19.5..24.5) and a cross aisle (x -1.5..3.5), plus a
--     strip from every rescue spot to the cross aisle. The four quadrants round them get a per-floor mix
--     (Office.FLOORS): cubicle pods, a glass meeting room, a break room, an exec office, a lounge, the
--     print corner, the server corner. Each floor has its own carpet, a FLOOR n sign over the stairs, a
--     hanging STAIRS / EXIT sign at the landing and ceiling panels.
-- The builder's Desk placeholders (they carry the desk FireStarts) are cleared; the fire lights the
-- nearest Flammable within GameConfig.FireStartSearch, which is now office furniture.
local Plan = require(script.Parent:WaitForChild("Plan") :: ModuleScript)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Office = {}

local C = Kit.C
local P = Kit.part
local CF = CFrame.new
local V = Vector3.new
local ANG = CFrame.Angles
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0
local hex = Color3.fromHex

type Ctx = any
type Q = { x0: number, x1: number, z0: number, z1: number, side: string }

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

---------------------------------------------------------------------------------------------------
-- office props (cf = floor point under the centre, the item faces -Z)
---------------------------------------------------------------------------------------------------
local SCREENS = { C.Sky, C.PaleBlue, C.Mustard, hex("#B6FF3B"), C.Lilac }

-- Monitor on a desk top (cf = the desk surface): one glowing part with a drawn spreadsheet / chart.
local function monitor(m: Instance, cf: CFrame, rng: Random)
	local s = P(m, "Monitor", cf * CF(0, 0.66, 0), V(1.9, 1.3, 0.2), C.Ink)
	local g = Kit.gui(s, Enum.NormalId.Front, 30, true)
	Kit.rect(g, 0.05, 0.08, 0.9, 0.84, pick(rng, SCREENS))
	if rng:NextNumber() < 0.5 then
		for k = 0, 3 do
			local h = rng:NextNumber(0.15, 0.6)
			Kit.rect(g, 0.15 + k * 0.18, 0.85 - h, 0.12, h, pick(rng, { C.Red, C.Teal, C.Navy, C.Orange }))
		end
	else
		for k = 0, 4 do
			Kit.rect(g, 0.1, 0.15 + k * 0.15, 0.8, 0.04, C.Ink).BackgroundTransparency = 0.5
		end
		Kit.text(g, 0.1, 0.02, 0.8, 0.14, pick(rng, { "Q3 REPORT", "TPS", "EMAIL (9999)", "FIRE DRILL?!", "MEETING 2PM" }), C.Ink)
	end
end

-- Swivel chair (2 parts, walk-through so it never boxes anyone in). Faces -Z.
local function chair(parent: Instance, cf: CFrame, col: Color3)
	P(parent, "OfficeChairSeat", cf * CF(0, 1.55, 0), V(1.8, 0.4, 1.7), col, { fuel = 5 })
	P(parent, "OfficeChairBack", cf * CF(0, 2.75, 0.85), V(1.7, 2, 0.3), col:Lerp(C.Black, 0.15), { fuel = 4 })
	P(parent, "OfficeChairPost", cf * CF(0, 0.7, 0), V(0.35, 1.4, 0.35), C.Iron)
end

-- Cubicle pod: four desks round a cross of low flammable dividers (desks on z = +-1.4 facing outward,
-- chairs beyond them). ~8.6 x 9.4. o.color (dividers), o.chair.
local function pod(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("CubiclePod")
	local div = o.color or C.TealDark
	local first = P(m, "CubicleDivider", cf * CF(0, 2.1, 0), V(8.6, 4.2, 0.3), div, { solid = true, fuel = 10 })
	P(m, "CubicleDivider", cf * CF(0, 1.9, 0), V(0.3, 3.8, 5.6), div:Lerp(C.White, 0.15), { solid = true, fuel = 8 })
	for _, sz in { -1, 1 } do
		for _, sx in { -1, 1 } do
			local dcf = cf * CF(sx * 2.15, 0, sz * 1.4) * ANG(0, if sz < 0 then 0 else math.pi, 0) -- -Z faces away from the divider
			local dt = P(m, "DeskTop", dcf * CF(0, 2.6, 0), V(3.9, 0.25, 2.4), C.WoodPale, { solid = true, fuel = 10 })
			Kit.rect(Kit.gui(dt, Enum.NormalId.Top, 10), 0.3, 0.55, 0.4, 0.18, C.Ink, 0.1) -- keyboard
			P(m, "DeskPedestal", dcf * CF(sx * sz * -1.25, 1.24, 0.1), V(1.2, 2.47, 2), C.Steel, { solid = true })
			monitor(m, dcf * CF(0, 2.73, 0.6), rng)
			chair(m, dcf * CF(0, 0, -2.0) * ANG(0, math.pi, 0), o.chair or C.Navy)
			if rng:NextNumber() < 0.35 then
				Kit.cylY(m, "Mug", dcf * CF(1.3, 2.97, 0.1), 0.45, 0.45, pick(rng, Kit.Bright))
			end
		end
	end
	return done(m, parent, first)
end

-- Water cooler with a blue bottle and a cup dispenser.
local function cooler(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("WaterCooler")
	local b = P(m, "CoolerBase", cf * CF(0, 1.6, 0), V(1.5, 3.2, 1.5), C.White, { solid = true })
	Kit.cylY(m, "CoolerBottle", cf * CF(0, 4.15, 0), 1.9, 1.3, C.PaleBlue, { mat = Enum.Material.Glass, tr = 0.35 })
	P(m, "CoolerTap", cf * CF(0.3, 2.6, -0.8), V(0.25, 0.3, 0.2), C.Blue)
	P(m, "CoolerTap", cf * CF(-0.3, 2.6, -0.8), V(0.25, 0.3, 0.2), C.Red)
	Kit.cylY(m, "CupStack", cf * CF(0.95, 2.4, 0), 1.2, 0.35, C.Cream, { fuel = 2 })
	return done(m, parent, b)
end

-- Big copier: body, glowing panel, paper tray, a jammed sheet. ~3.4 x 2.4.
local function printer(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("Printer")
	local b = P(m, "CopierBody", cf * CF(0, 1.8, 0), V(3.4, 3.6, 2.4), C.Cream, { solid = true, fuel = 12 })
	local panel = P(m, "CopierPanel", cf * CF(1, 3.75, -0.7) * ANG(math.rad(20), 0, 0), V(1, 0.15, 0.7), C.Green, { neon = true })
	panel.CastShadow = false
	P(m, "CopierLid", cf * CF(-0.3, 3.7, 0.1), V(2.4, 0.2, 2), C.Steel)
	P(m, "PaperTray", cf * CF(-1.95, 2.3, 0), V(0.5, 0.15, 1.6), C.White, { fuel = 2 })
	P(m, "JammedPaper", cf * CF(-0.4, 3.9, -1.25) * ANG(math.rad(-50), 0, 0.2), V(1.2, 0.05, 1.5), C.White, { fuel = 2 })
	local g = Kit.gui(b, Enum.NormalId.Front, 24)
	Kit.text(g, 0.1, 0.1, 0.8, 0.2, "OUT OF ORDER", C.Red)
	return done(m, parent, b)
end

-- Rolling whiteboard (stand + board with a doodled chart). Faces -Z.
local function whiteboard(parent: Instance, cf: CFrame, o: any): Model
	local m = model("Whiteboard")
	local b = P(m, "Whiteboard", cf * CF(0, 4.6, 0), V(5, 3, 0.2), C.White, { fuel = 4 })
	local g = Kit.gui(b, Enum.NormalId.Front, 30)
	Kit.text(g, 0.05, 0.05, 0.9, 0.22, o.text or "SYNERGY!!", C.Blue, Enum.Font.PermanentMarker)
	for k = 0, 3 do
		Kit.rect(g, 0.15 + k * 0.18, 0.85 - 0.12 * (k + 1), 0.1, 0.12 * (k + 1), Kit.Bright[k + 1])
	end
	Kit.rect(g, 0.1, 0.86, 0.8, 0.02, C.Ink)
	for _, x in { -2.3, 2.3 } do
		P(m, "BoardLeg", cf * CF(x, 2.1, 0.15), V(0.2, 4.2, 0.2), C.Steel)
		P(m, "BoardFoot", cf * CF(x, 0.15, 0.15), V(0.3, 0.3, 2), C.Iron)
	end
	return done(m, parent, b)
end

-- Conference table along local X with chairs on both long sides. o.len (10).
local function confTable(parent: Instance, cf: CFrame, o: any): Model
	local len = o.len or 10
	local m = model("ConferenceTable")
	local tops = Kit.chunked(m, "ConferenceTop", cf * CF(0, 2.65, 0), V(len, 0.3, 4), hex("#5A3A22"), { solid = true, fuel = 16 })
	P(m, "TableBase", cf * CF(0, 1.25, 0), V(len - 2, 2.5, 1.4), C.Iron, { solid = true })
	local n = math.max(2, math.floor(len / 3))
	for k = 1, n do
		local x = -len / 2 + (k - 0.5) * len / n
		for _, sz in { -1, 1 } do
			chair(m, cf * CF(x, 0, sz * 3) * ANG(0, if sz < 0 then math.pi else 0, 0), o.chair or C.Navy)
		end
	end
	P(m, "SpeakerPhone", cf * CF(0, 2.9, 0), V(1.2, 0.2, 1.2), C.Ink)
	return done(m, parent, tops[1])
end

-- Coffee machine + microwave for a counter top (cf = the worktop).
local function coffeeCorner(m: Instance, cf: CFrame)
	P(m, "CoffeeMachine", cf * CF(-1, 1.1, 0.3), V(1.4, 2.2, 1.4), C.Ink)
	Kit.cylY(m, "CoffeePot", cf * CF(-1, 0.45, -0.5), 0.9, 0.7, C.Glass, { mat = Enum.Material.Glass, tr = 0.3 })
	local mw = P(m, "Microwave", cf * CF(1.4, 0.75, 0.2), V(2.2, 1.5, 1.6), C.White)
	local g = Kit.gui(mw, Enum.NormalId.Front, 24)
	Kit.rect(g, 0.06, 0.12, 0.62, 0.76, C.Ink, 0.1)
	Kit.text(g, 0.72, 0.15, 0.24, 0.3, "12:00", C.Green)
end

-- Snack vending machine (glowing front).
local function vending(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("VendingMachine")
	local b = P(m, "VendingBody", cf * CF(0, 3.6, 0.1), V(3.4, 7.2, 2.4), C.Red, { solid = true, fuel = 10 })
	local glass = P(m, "VendingGlass", cf * CF(-0.4, 4, -1.05), V(2.2, 5, 0.1), C.PaleBlue, { neon = true, tr = 0.25 })
	local g = Kit.gui(glass, Enum.NormalId.Front, 16, true)
	for r = 0, 4 do
		for c = 0, 3 do
			Kit.rect(g, 0.06 + c * 0.23, 0.05 + r * 0.19, 0.17, 0.12, pick(rng, Kit.Bright), 0.2)
		end
	end
	return done(m, parent, b)
end

-- Server rack: blinking lights drawn on a glowing front.
local function serverRack(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local m = model("ServerRack")
	local b = P(m, "ServerRack", cf * CF(0, 3.5, 0), V(2.6, 7, 2.6), C.Iron, { solid = true, fuel = 14 })
	local g = Kit.gui(b, Enum.NormalId.Front, 20, true)
	for r = 0, 9 do
		Kit.rect(g, 0.06, 0.04 + r * 0.095, 0.88, 0.07, hex("#24242A"))
		for k = 0, 3 do
			if rng:NextNumber() < 0.7 then
				Kit.rect(g, 0.1 + k * 0.08, 0.06 + r * 0.095, 0.04, 0.03, pick(rng, { C.Green, C.ExitGreen, C.Mustard, C.Red, C.Blue }), 1)
			end
		end
	end
	return done(m, parent, b)
end

-- Ping-pong table along local X.
local function pingPong(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("PingPong")
	local t = P(m, "PingPongTop", cf * CF(0, 2.5, 0), V(8, 0.25, 4.4), hex("#2F7A4A"), { solid = true, fuel = 12 })
	local g = Kit.gui(t, Enum.NormalId.Top, 10)
	Kit.rect(g, 0.497, 0, 0.006, 1, C.White)
	Kit.rect(g, 0, 0.49, 1, 0.02, C.White)
	P(m, "PingPongNet", cf * CF(0, 2.95, 0), V(0.1, 0.7, 4.6), C.White, { tr = 0.3 })
	P(m, "PingPongLegs", cf * CF(0, 1.2, 0), V(6.5, 2.4, 0.4), C.Iron)
	Kit.cylY(m, "Paddle", cf * CF(-2.5, 2.7, 1), 0.1, 1, C.Red)
	return done(m, parent, t)
end

-- Sign hanging from the ceiling (cf = the ceiling point), readable from both sides.
local function hangSign(parent: Instance, cf: CFrame, o: any): Model
	local m = model("HangingSign")
	local w = o.w or 6
	local s = P(m, "HangingSign", cf * CF(0, -1.6, 0), V(w, 1.4, 0.2), o.bg or C.TealDark)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		Kit.text(Kit.gui(s, face, 30, o.glow == true), 0.04, 0.08, 0.92, 0.84, o.text or "", o.fg or C.White)
	end
	for _, x in { -w / 2 + 0.5, w / 2 - 0.5 } do
		P(m, "SignWire", cf * CF(x, -0.45, 0), V(0.08, 0.9, 0.08), C.Iron)
	end
	return done(m, parent, s)
end

-- Elevator doors on a wall (cf = wall face, -Z into the room): frame, doors, buttons, floor display.
local function elevator(parent: Instance, cf: CFrame, o: any): Model
	local m = model("Elevator")
	local frame = P(m, "ElevatorFrame", cf * CF(0, 4, -0.12), V(5, 8, 0.2), C.Iron)
	for _, x in { -0.9, 0.9 } do
		P(m, "ElevatorDoor", cf * CF(x, 3.6, -0.3), V(1.78, 7, 0.16), C.Chrome, { refl = 0.25 })
	end
	local disp = P(m, "FloorDisplay", cf * CF(0, 8.6, -0.3), V(1.6, 0.8, 0.15), C.Ink)
	Kit.text(Kit.gui(disp, Enum.NormalId.Front, 40, true), 0.1, 0.05, 0.8, 0.9, o.floor or "6", C.Orange)
	local btn = P(m, "CallButtons", cf * CF(3.1, 4, -0.2), V(0.6, 1.2, 0.15), C.Steel)
	local g = Kit.gui(btn, Enum.NormalId.Front, 40, true)
	Kit.rect(g, 0.3, 0.12, 0.4, 0.3, C.Mustard, 1)
	Kit.rect(g, 0.3, 0.58, 0.4, 0.3, C.White, 1)
	P(m, "ElevatorSign", cf * CF(3.1, 5.4, -0.2), V(1.2, 0.5, 0.1), C.Red)
	return done(m, parent, frame)
end

---------------------------------------------------------------------------------------------------
-- floor plans
---------------------------------------------------------------------------------------------------
-- per-floor mix of the quadrants: q1 front-left (by the stair foot), q2 front-right, q3 back-left, q4 back-right
Office.FLOORS = {
	{ q1 = "print", q2 = "pods", q3 = "break", q4 = "meeting", carpet = hex("#5C6B8A") },
	{ q1 = "cooler", q2 = "pods", q3 = "pods", q4 = "exec", carpet = hex("#6B5C7A") },
	{ q1 = "print", q2 = "meeting", q3 = "pods", q4 = "break", carpet = hex("#4F7A72") },
	{ q1 = "servers", q2 = "pods", q3 = "meeting", q4 = "pods", carpet = hex("#7A5C4F") },
	{ q1 = "cooler", q2 = "lounge", q3 = "break", q4 = "exec", carpet = hex("#5A6E4A") },
}
local DIVIDERS = { C.TealDark, C.Navy, hex("#8E5572"), C.Terracotta, hex("#5B8E7D") }
local CHAIRS = { C.Navy, C.Red, C.Teal, C.Ink, C.Orange }

local function ceilY(ctx: Ctx, s: number): number
	return ctx.floors[s] + ctx.H - 0.6
end

-- Put the first candidate (x, z) that fits; returns its spot or nil.
local function tryPut(ctx: Ctx, s: number, fn: any, cands: { { number } }, yaw: number, fw: number, fd: number, opts: any?): { number }?
	for _, c in cands do
		if ctx:put(s, fn, c[1], c[2], yaw, fw, fd, if opts then table.clone(opts) else {}) then
			return c
		end
	end
	return nil
end

-- Glass panes (to the ceiling) closing a quadrant on its two aisle sides, with a 4-stud doorway on the
-- main-aisle side by the cross-aisle corner. Builds nothing (false) when a pane would cross a keep-out.
local function glassRoom(ctx: Ctx, s: number, q: Q): boolean
	local y = ctx.floors[s]
	local h = ceilY(ctx, s) - y
	local front = q.z0 < ctx.d / 2
	local xEdge = if q.side == "L" then q.x1 - 0.2 else q.x0 + 0.2 -- cross-aisle side
	local zEdge = if front then q.z1 - 0.2 else q.z0 + 0.2 -- main-aisle side
	local outerX = if q.side == "L" then q.x0 else q.x1
	local outerZ = if front then q.z0 else q.z1
	local doorC = if q.side == "L" then xEdge - 3 else xEdge + 3
	local runs = {
		Plan.span(outerX, zEdge - 0.15, doorC + (if q.side == "L" then -2 else 2), zEdge + 0.15),
		Plan.span(doorC + (if q.side == "L" then 2 else -2), zEdge - 0.15, xEdge, zEdge + 0.15),
		Plan.span(xEdge - 0.15, zEdge, xEdge + 0.15, outerZ),
	}
	local placer = ctx.placers[s]
	for _, r in runs do
		if not placer:fits(r) then
			return false
		end
	end
	local glass = hex("#BFE3EE")
	for _, r in runs do
		local alongX = r.x1 - r.x0 > r.z1 - r.z0
		local len = if alongX then r.x1 - r.x0 else r.z1 - r.z0
		if len > 0.3 then
			local n = math.max(1, math.ceil(len / 8))
			for i = 1, n do
				local m = (if alongX then r.x0 else r.z0) + (i - 0.5) * len / n
				local cx = if alongX then m else (r.x0 + r.x1) / 2
				local cz = if alongX then (r.z0 + r.z1) / 2 else m
				local size = if alongX then V(len / n - 0.1, h - 0.1, 0.3) else V(0.3, h - 0.1, len / n - 0.1)
				P(ctx.root, "GlassPane", ctx:at(cx, y + h / 2, cz), size, glass, { solid = true, mat = Enum.Material.Glass, tr = 0.55 })
			end
			placer:take(r)
		end
	end
	-- mullions at the door jambs + the corner
	for _, x in { doorC - 2, doorC + 2, xEdge } do
		P(ctx.root, "Mullion", ctx:at(x, y + (h - 0.1) / 2, zEdge), V(0.45, h - 0.1, 0.45), C.Iron, { solid = true })
	end
	return true
end

local Q: { [string]: (Ctx, number, Q, Random) -> () } = {}

function Q.pods(ctx: Ctx, s: number, q: Q, rng: Random)
	local fi = (s - 2) % #DIVIDERS + 1
	local opts = { color = DIVIDERS[fi], chair = CHAIRS[fi] }
	local cz = (q.z0 + q.z1) / 2
	local cells = { { q.x0 + 4.5, cz }, { q.x1 - 4.5, cz } }
	for _, c in cells do
		if not ctx:put(s, pod, c[1], c[2], N, 8.8, 9.6, table.clone(opts)) then
			-- squeezed by a rescue strip: a single desk instead
			tryPut(ctx, s, Kit.desk, { { c[1], c[2] - 2.5 }, { c[1], c[2] + 2.5 } }, N, 4.4, 4.6, { w = 4, chair = opts.chair })
		end
	end
	ctx:put(s, Kit.plant, q.x1 - 1, q.z1 - 1, N, 1.8, 1.8, { size = 0.9 })
	ctx:put(s, Kit.trashCan, q.x0 + 0.9, q.z1 - 0.9, N, 1.6, 1.6, { color = C.Steel })
end

function Q.meeting(ctx: Ctx, s: number, q: Q, rng: Random)
	local walled = glassRoom(ctx, s, q)
	local cx, cz = (q.x0 + q.x1) / 2, (q.z0 + q.z1) / 2
	tryPut(ctx, s, confTable, { { cx, cz }, { cx, cz + 1.5 }, { cx, cz - 1.5 } }, N, 11, 8.6, { len = 10, chair = pick(rng, CHAIRS) })
	local far = if q.side == "L" then q.x0 + 1.2 else q.x1 - 1.2
	tryPut(ctx, s, whiteboard, { { far, cz }, { far, cz + 2 } }, if q.side == "L" then E else W, 5.2, 2.2, { text = pick(rng, { "SYNERGY!!", "Q4 GOALS", "DON'T PANIC", "FIRE DRILL\n= 2PM" }) })
	ctx:put(s, Kit.plant, if q.side == "L" then q.x0 + 1.2 else q.x1 - 1.2, if q.z0 < ctx.d / 2 then q.z0 + 1.2 else q.z1 - 1.2, N, 1.8, 1.8, { size = 1.1 })
	if walled then
		local lab = Kit.part(ctx.root, "MeetingSign", ctx:at((q.x0 + q.x1) / 2, ctx.floors[s] + 9.5, if q.z0 < ctx.d / 2 then q.z1 else q.z0), V(5, 0.9, 0.08), C.Ink)
		for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
			Kit.text(Kit.gui(lab, face, 30, true), 0.05, 0.1, 0.9, 0.8, pick(rng, { "BOARDROOM", "MEETING ROOM", "IDEA LAB", "BRAINSTORM" }), C.White)
		end
	end
end

function Q.breakRoom(ctx: Ctx, s: number, q: Q, rng: Random)
	local y = ctx.floors[s]
	local back = q.z0 > ctx.d / 2
	local wallZ = if back then q.z1 - 1.3 else q.z0 + 1.3
	local yaw = if back then N else S
	local cx = (q.x0 + q.x1) / 2
	local c = tryPut(ctx, s, Kit.counter, { { cx, wallZ }, { cx - 2, wallZ }, { cx + 2, wallZ }, { cx - 4, wallZ }, { cx + 4, wallZ } }, yaw, 8.4, 2.8, { len = 8, sink = true, sinkX = 2, color = pick(rng, { C.Cream, C.PaleBlue, C.Mustard }), top = C.WoodPale })
	if c then
		local top = ctx:at(c[1], y + 3.45, c[2], yaw)
		coffeeCorner(ctx.root, top * CF(-1.5, 0, 0))
		tryPut(ctx, s, Kit.fridge, { { c[1] - 5.8, c[2] }, { c[1] + 5.8, c[2] } }, yaw, 3.2, 2.8, { color = C.White })
	end
	local sideX = if q.side == "L" then q.x0 + 1.5 else q.x1 - 1.5
	if not tryPut(ctx, s, vending, { { q.x1 - 2, wallZ }, { q.x0 + 2, wallZ } }, yaw, 3.6, 2.8, { rng = rng }) then
		tryPut(ctx, s, vending, { { sideX, (q.z0 + q.z1) / 2 - 3 }, { sideX, (q.z0 + q.z1) / 2 + 3 } }, if q.side == "L" then E else W, 3.6, 2.8, { rng = rng })
	end
	tryPut(ctx, s, Kit.roundTable, { { cx, (q.z0 + q.z1) / 2 }, { cx + 2, (q.z0 + q.z1) / 2 }, { cx - 2, (q.z0 + q.z1) / 2 } }, N, 7.6, 7.6, { n = 3, color = C.White })
	tryPut(ctx, s, cooler, { { if q.side == "L" then q.x0 + 1.2 else q.x1 - 1.2, (q.z0 + q.z1) / 2 } }, if q.side == "L" then E else W, 2.2, 2.2, {})
	ctx:add(hangSign, ctx:at(cx, ceilY(ctx, s), if back then q.z0 + 1 else q.z1 - 1), { text = "BREAK ROOM", w = 5, bg = C.Mustard, fg = C.Ink })
end

function Q.exec(ctx: Ctx, s: number, q: Q, rng: Random)
	local cx, cz = (q.x0 + q.x1) / 2, (q.z0 + q.z1) / 2
	local back = q.z0 > ctx.d / 2
	ctx:add(Kit.rug, ctx:at(cx, ctx.floors[s], cz), { w = 10, d = 8, color = pick(rng, { C.Red, C.Navy, C.TealDark }), pattern = "border" })
	-- the boss sits with their back to the window, facing the room
	local deskZ = if back then q.z1 - 3.5 else q.z0 + 3.5
	local d = tryPut(ctx, s, Kit.desk, { { cx, deskZ }, { cx - 2.5, deskZ }, { cx + 2.5, deskZ }, { cx - 4, deskZ } }, if back then N else S, 6.4, 4.6, { w = 6, color = C.Wood, chair = C.Ink })
	if d then
		ctx:add(Kit.globe, ctx:at(d[1] - 2, ctx.floors[s] + 2.78, d[2], N), {})
	end
	for _, dx in { -2.4, 2.4 } do
		ctx:put(s, Kit.armchair, cx + dx, if back then deskZ - 6 else deskZ + 6, if back then S else N, 3.4, 3.2, { color = C.Terracotta })
	end
	local side = if q.side == "L" then q.x0 + 1 else q.x1 - 1
	tryPut(ctx, s, Kit.bookshelf, { { side, cz }, { side, cz + 2 }, { side, cz - 2 } }, if q.side == "L" then E else W, 5.2, 1.6, { w = 5, h = 6.5 })
	ctx:put(s, Kit.plant, side, if back then q.z0 + 1.2 else q.z1 - 1.2, N, 1.8, 1.8, { size = 1.2, color = C.Pink })
	ctx:put(s, Kit.flag, if q.side == "L" then q.x1 - 1 else q.x0 + 1, deskZ, N, 1.6, 1.6, { color = C.Navy })
end

function Q.lounge(ctx: Ctx, s: number, q: Q, rng: Random)
	local cx, cz = (q.x0 + q.x1) / 2, (q.z0 + q.z1) / 2
	ctx:add(Kit.rug, ctx:at(cx - 3, ctx.floors[s], cz), { w = 8, d = 7, color = C.Mustard, pattern = "stripes" })
	tryPut(ctx, s, Kit.sofa, { { cx - 3, cz + 3 }, { cx - 3, cz + 2 } }, N, 7.2, 3.4, { color = C.Teal })
	ctx:put(s, Kit.coffeeTable, cx - 3, cz - 0.6, N, 4.2, 2.6, {})
	ctx:put(s, Kit.beanBag, cx - 6, cz - 3.6, N, 3, 3, { color = C.Pink })
	ctx:put(s, Kit.beanBag, cx - 1.5, cz - 3.8, N, 3, 3, { color = C.Orange })
	tryPut(ctx, s, pingPong, { { cx + 4.5, cz }, { q.x1 - 4.5, cz } }, W, 8.4, 4.8, {})
	ctx:put(s, Kit.floorLamp, q.x1 - 1, q.z0 + 1, N, 1.4, 1.4, {})
end

-- q1 is a narrow strip (x ~ -6..-1.5) between the stair walkway and the cross aisle: a line of items
-- facing the stairs.
function Q.print(ctx: Ctx, s: number, q: Q, _rng: Random)
	local cx = (q.x0 + q.x1) / 2
	ctx:put(s, printer, cx, q.z0 + 2, E, 3.6, 2.6, {})
	ctx:put(s, Kit.filingCabinet, cx, q.z0 + 5, E, 2.2, 2.6, { color = C.Steel })
	ctx:put(s, Kit.filingCabinet, cx, q.z0 + 7.3, E, 2.2, 2.6, { color = C.Mustard })
	ctx:put(s, Kit.boxes, cx, q.z1 - 1.5, E, 3.6, 2.6, {})
end

function Q.cooler(ctx: Ctx, s: number, q: Q, rng: Random)
	local cx = (q.x0 + q.x1) / 2
	ctx:put(s, cooler, cx, q.z0 + 1.5, E, 2.2, 2.2, {})
	ctx:put(s, Kit.plant, cx, q.z0 + 4, N, 1.8, 1.8, { size = 1.3 })
	ctx:put(s, Kit.armchair, cx, q.z0 + 7.5, E, 3.4, 3.2, { color = pick(rng, Kit.Bright) })
	ctx:put(s, Kit.trashCan, cx, q.z1 - 1, N, 1.6, 1.6, {})
end

function Q.servers(ctx: Ctx, s: number, q: Q, rng: Random)
	local cx = (q.x0 + q.x1) / 2
	for k = 0, 2 do
		ctx:put(s, serverRack, cx, q.z0 + 1.5 + k * 2.8, E, 2.8, 2.8, { rng = rng })
	end
	ctx:put(s, Kit.boxes, cx, q.z1 - 1.5, E, 3.6, 2.6, {})
end

local KINDNAME = { pods = Q.pods, meeting = Q.meeting, ["break"] = Q.breakRoom, exec = Q.exec, lounge = Q.lounge, print = Q.print, cooler = Q.cooler, servers = Q.servers }

-- Strips every storey keeps clear: the window strip, the main + cross aisles, and a lane from every
-- rescue spot to the cross aisle.
local AISLE_X0, AISLE_X1 = -1.5, 3.5
local function keepAisles(ctx: Ctx)
	local w, d = ctx.w, ctx.d
	for s = 1, ctx.storeys do
		local p = ctx.placers[s]
		p:keep(Plan.span(-w / 2, 0, w / 2, 4.5))
		p:keep(Plan.span(-w / 2 + 9.5, 19.5, w / 2, 24.5))
		p:keep(Plan.span(AISLE_X0, 0, AISLE_X1, d - 0.5))
		-- the walk from one flight's landing (back) round to the next flight's foot (front)
		p:keep(Plan.span(-w / 2 + 9.5, 0, -w / 2 + 15.5, 24.5))
	end
	local inv = ctx.F:Inverse()
	local mid = (AISLE_X0 + AISLE_X1) / 2
	for _, p in ctx.site:GetChildren() do
		-- the builder's filing cabinets carry upper-floor FireStarts: keep room to walk up to them
		if p:IsA("BasePart") and p.Name == "Cabinet" then
			local l = inv * p.CFrame
			for s = ctx.storeys, 1, -1 do
				if l.Position.Y - p.Size.Y / 2 >= ctx.floors[s] - 0.75 then
					ctx.placers[s]:keep(Plan.span(l.Position.X - 2.6, l.Position.Z - 4.6, l.Position.X + 2.6, l.Position.Z))
					break
				end
			end
		end
	end
	for _, p in ctx.site:GetDescendants() do
		if p:IsA("BasePart") and p:HasTag("RescueSpawn") then
			local l = inv * p.CFrame
			for s = ctx.storeys, 1, -1 do
				local y0 = ctx.floors[s]
				if l.Position.Y - 1 >= y0 - 0.75 and l.Position.Y - 1 < y0 + ctx.H then
					ctx.placers[s]:keep(Plan.span(math.min(l.Position.X, mid) - 1.6, l.Position.Z - 1.8, math.max(l.Position.X, mid) + 1.6, l.Position.Z + 1.8))
					break
				end
			end
		end
	end
end

local function lobby(ctx: Ctx)
	local w, d = ctx.w, ctx.d
	local y = ctx.floors[1]
	local inv = ctx.F:Inverse()
	-- marble floor (skip the stair lane strip so the flight's foot stays readable)
	local f = ctx:add(Kit.floorFinish, ctx:at(4.75, y, d / 2), { w = w - 10.5, d = d - 1, color = hex("#E9E4DA"), grid = 4, lines = hex("#BDB5A6") })
	local _ = f
	-- reception on the builder's LobbyDesk spot
	local rx, rz = w * 0.2, d * 0.5
	local desk = ctx.site:FindFirstChild("LobbyDesk")
	if desk and desk:IsA("BasePart") then
		local l = inv * desk.CFrame
		rx, rz = l.Position.X, l.Position.Z
		desk:Destroy()
	end
	local rec = model("Reception")
	local rcf = ctx:at(rx, y, rz)
	local body = Kit.chunked(rec, "ReceptionDesk", rcf * CF(0, 1.9, 0), V(9, 3.8, 2.6), hex("#2F3A4A"), { solid = true, fuel = 18 })
	P(rec, "ReceptionTop", rcf * CF(0, 3.92, -0.1), V(9.4, 0.25, 3.0), C.Chrome, { solid = true })
	local band = P(rec, "ReceptionGlow", rcf * CF(0, 2.6, -1.35), V(8.6, 0.25, 0.1), hex("#2FE6FF"), { neon = true })
	band.CastShadow = false
	local logo = Kit.gui(body[1], Enum.NormalId.Front, 20)
	Kit.text(logo, 0.1, 0.05, 0.8, 0.35, "WELCOME", C.White)
	monitor(rec, rcf * CF(2.5, 4.05, 0.5) * ANG(0, math.pi, 0), ctx.rng)
	P(rec, "Bell", rcf * CF(-2.5, 4.2, -0.6), V(0.6, 0.35, 0.6), C.Gold)
	chair(rec, rcf * CF(0, 0, 2.6), C.Ink)
	rec.PrimaryPart = body[1]
	rec.Parent = ctx.root
	ctx.placers[1]:take(Plan.rect(rx, rz, 9.6, 3.2))
	-- feature wall behind the receptionist (stops short of the side windows' z band)
	local fw = P(ctx.root, "FeatureWall", ctx:at(rx, y + 4.5, rz + 4.6), V(12, 9, 0.6), hex("#1F2A3A"), { solid = true, fuel = 20 })
	ctx.placers[1]:take(Plan.rect(rx, rz + 4.6, 12, 0.8))
	local fg = Kit.gui(fw, Enum.NormalId.Front, 20, true)
	Kit.text(fg, 0.05, 0.25, 0.9, 0.35, "SKY TOWER", hex("#2FE6FF"))
	Kit.text(fg, 0.1, 0.62, 0.8, 0.15, "PENGUIN INDUSTRIES  -  FLOORS 1-6", C.White)
	-- elevators on the right wall, clear of its window (z ~ d/2)
	for i, z in { d * 0.7, d * 0.86 } do
		ctx:add(elevator, ctx:at(w / 2 - 0.5, y, z, W), { floor = tostring(i * 3) })
		ctx.placers[1]:keep(Plan.span(w / 2 - 5, z - 3, w / 2, z + 3))
	end
	-- waiting area
	local wx = w / 2 - 9
	ctx:add(Kit.rug, ctx:at(wx, y, 10.5), { w = 8, d = 7, color = C.Teal, pattern = "border" })
	ctx:put(1, Kit.sofa, wx, 13.6, N, 7.2, 3.4, { color = C.Terracotta, w = 7 })
	ctx:put(1, Kit.coffeeTable, wx, 10.2, N, 4.2, 2.6, {})
	ctx:put(1, Kit.armchair, wx, 6.8, S, 3.4, 3.2, { color = C.Mustard })
	-- plants by the doors + corners, a directory on the left wall behind the stairs
	for _, p in { { -4, 6 }, { w / 2 - 1.5, 6 }, { w / 2 - 1.5, d - 1.5 }, { -2, d - 1.5 }, { -w / 2 + 1.5, d - 1.5 } } do
		ctx:put(1, Kit.plant, p[1], p[2], N, 1.8, 1.8, { size = 1.4 })
	end
	local dir = P(ctx.root, "Directory", ctx:at(-w / 2 + 0.6, y + 5.5, d * 0.75) * ANG(0, E, 0), V(4.4, 5, 0.12), C.Ink)
	local dg = Kit.gui(dir, Enum.NormalId.Front, 30, true)
	Kit.text(dg, 0.05, 0.02, 0.9, 0.14, "DIRECTORY", C.Mustard)
	for k, line in { "6  PENTHOUSE LOUNGE", "5  SERVERS + CODERS", "4  BOARDROOM", "3  THE BOSS", "2  ACCOUNTING", "1  LOBBY" } do
		Kit.text(dg, 0.08, 0.16 + (k - 1) * 0.135, 0.84, 0.11, line, C.White)
	end
	for _, lx in { -4, 10 } do
		for _, lz in { 10, 28 } do
			ctx:add(Kit.ceilingLight, ctx:at(lx, ceilY(ctx, 1), lz), { len = 6, range = 18 })
		end
	end
end

local function officeFloor(ctx: Ctx, s: number)
	local w, d = ctx.w, ctx.d
	local y = ctx.floors[s]
	local spec = Office.FLOORS[(s - 2) % #Office.FLOORS + 1]
	local rng = Random.new(ctx.rng:NextInteger(1, 1e6) + s)
	-- carpet over the office part of the slab (the stair lanes keep their bare concrete)
	ctx:add(Kit.floorFinish, ctx:at(-w / 2 + 9.5 + (w - 10) / 2, y, d / 2), { w = w - 10, d = d - 1, color = spec.carpet })
	local quads: { [string]: Q } = {
		q1 = { x0 = -w / 2 + 15.5, x1 = AISLE_X0, z0 = 5, z1 = 18.5, side = "L" },
		q2 = { x0 = AISLE_X1, x1 = w / 2 - 0.5, z0 = 4.5, z1 = 19.5, side = "R" },
		q3 = { x0 = -w / 2 + 0.5, x1 = AISLE_X0, z0 = 24.5, z1 = d - 0.5, side = "L" },
		q4 = { x0 = AISLE_X1, x1 = w / 2 - 0.5, z0 = 24.5, z1 = d - 0.5, side = "R" },
	}
	for _, key in { "q2", "q3", "q4", "q1" } do
		local fn = KINDNAME[spec[key]]
		if fn then
			local ok, err = pcall(fn, ctx, s, quads[key], rng)
			if not ok then
				warn(`[Office] floor {s} {key} ({spec[key]}): {err}`)
			end
		end
	end
	-- the floor number over the stairs (header band on the left wall), STAIRS + EXIT at the landing
	local num = P(ctx.root, "FloorNumber", ctx:at(-w / 2 + 0.6, y + 10.4, 10) * ANG(0, E, 0), V(6, 2.2, 0.1), C.Mustard)
	Kit.text(Kit.gui(num, Enum.NormalId.Front, 30), 0.03, 0.05, 0.94, 0.9, `FLOOR {s}`, C.Ink)
	ctx:add(hangSign, ctx:at(-w / 2 + 9.8, ceilY(ctx, s), 22) * ANG(0, W, 0), { text = "STAIRS  ^ v", w = 5, bg = C.Red })
	ctx:add(Kit.exitSign, ctx:at(-w / 2 + 9.8, ceilY(ctx, s) - 0.5, 17.6) * ANG(0, W, 0), { y = 0, hang = true })
	for _, lx in { -4, 12 } do
		for _, lz in { 12, 31 } do
			ctx:add(Kit.ceilingLight, ctx:at(lx, ceilY(ctx, s), lz), { len = 6, range = 18, light = lz < 20 })
		end
	end
end

local function skyscraper(ctx: Ctx)
	-- the builder's desk placeholders (FireStarts stay where they are)
	for _, p in ctx.site:GetChildren() do
		if p:IsA("BasePart") and p.Name == "Desk" then
			p:Destroy()
		end
	end
	keepAisles(ctx)
	lobby(ctx)
	for s = 2, ctx.storeys do
		officeFloor(ctx, s)
	end
end

function Office.register(Furnish: any)
	Furnish.Layouts.skyscraper = skyscraper
end

-- exposed for the nightclub / other layouts
Office.monitor = monitor
Office.chair = chair
Office.cooler = cooler
Office.printer = printer
Office.hangSign = hangSign

return Office
