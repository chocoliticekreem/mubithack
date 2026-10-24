--!strict
-- Interiors/School [owner: interiors]. The procedural school's interior (site attr Interior = "school",
-- BlockFiller Build.school), laid out by Interiors/Plan.school, the same plan BlockFiller used for the
-- FireStart / RescueSpawn markers and the gas tank, so every fire start sits on its room's hero piece
-- (teacher's desk, stove, lab bench, bookcase, trophy case, mat stack...).
--   Corridor along the back wall: lockers, notice boards, pull stations, fountains, exit signs, room
--   signs over every doorway, ceiling panels. Rooms along the front, each with its own colour theme,
--   floor finish, wainscot under the windows, half-drawn blinds and lights:
--   classroom (board + doodles, alphabet strip, teacher's desk, desk rows facing the board, cubbies,
--   bookcase + globe, posters, clock), science lab, library, art room, music room, cafeteria + kitchen,
--   principal's office, lobby (trophy case), gym (court, hoops, bleachers, mats, scoreboard), restroom.
-- Walls: Partition (two-tone, flammable) between rooms and along the corridor, 5-stud open doorways.
local Plan = require(script.Parent:WaitForChild("Plan") :: ModuleScript)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local School = {}
local Furnish_partition: any = nil -- Furnish.partition (set by register: no require cycle)

local C = Kit.C
local CF = CFrame.new
local R90 = math.rad(90)
-- yaw so the item's -Z (its front) faces: E (+X), W (-X), S (+Z, toward the back), N (-Z, street)
local E, W, S, N = -R90, R90, math.pi, 0

local THEMES = {
	{ wall = C.PaleBlue, floor = Color3.fromHex("#D9CBB8"), accent = C.Blue },
	{ wall = C.Lilac, floor = Color3.fromHex("#E3D3C0"), accent = C.Pink },
	{ wall = C.Peach, floor = Color3.fromHex("#D8C3A5"), accent = C.Terracotta },
	{ wall = Color3.fromHex("#CDE3B0"), floor = Color3.fromHex("#D6CDB4"), accent = C.Green },
	{ wall = C.Mustard, floor = Color3.fromHex("#E0CFAE"), accent = C.Teal },
}

local ROOM_NAMES = {
	classroom = "ROOM", science = "SCIENCE LAB", library = "LIBRARY", art = "ART ROOM", music = "MUSIC",
	cafeteria = "CAFETERIA", office = "PRINCIPAL", gym = "GYM", restroom = "RESTROOMS",
}

type Room = Plan.Room
type Ctx = any

local function inner(r: Room): (number, number, number, number)
	return r.x0 + 0.5, r.x1 - 0.5, r.z0, r.z1
end

-- Wall items on the room's west partition / east wall / front wall / corridor wall (room side).
local function westCF(ctx: Ctx, r: Room, s: number, z: number): CFrame
	return ctx:at(r.x0 + 0.5, ctx.floors[s], z, E)
end
local function eastCF(ctx: Ctx, r: Room, s: number, z: number): CFrame
	return ctx:at(r.x1 - 0.5, ctx.floors[s], z, W)
end
local function backCF(ctx: Ctx, r: Room, s: number, x: number): CFrame
	return ctx:at(x, ctx.floors[s], r.z1, N)
end

-- room shell dressing: floor finish, wainscot along the front wall, blinds, ceiling lights
local function dressRoom(ctx: Ctx, r: Room, s: number, theme: any, opts: { [string]: any }?)
	local o = opts or {}
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	ctx:add(Kit.floorFinish, ctx:at((x0 + x1) / 2, y, (z0 + z1) / 2), { w = x1 - x0, d = z1 - z0, color = o.floor or theme.floor, grid = o.grid, lines = o.lines })
	ctx:add(Kit.wainscot, ctx:at((x0 + x1) / 2, y, z0, S), { w = x1 - x0, h = 2.8, color = o.wainscot or theme.wall, rail = C.Cream })
	if o.blinds ~= false then
		for _, win in Plan.schoolWindows(ctx.w) do
			local wx = (win[1] + win[2]) / 2
			if wx - 2 > x0 and wx + 2 < x1 then
				ctx:add(Kit.blinds, ctx:at(wx, y + 5, 0, S), { w = 4, h = 4, color = o.blindColor or C.Cream, drop = 0.35 + ctx.rng:NextNumber(0, 0.2) })
			end
		end
	end
	local cy = ctx:ceiling(s)
	local n = if x1 - x0 > 30 then 3 elseif x1 - x0 > 16 then 2 else 1
	for k = 1, n do
		local lx = x0 + k * (x1 - x0) / (n + 1)
		ctx:add(Kit.ceilingLight, ctx:at(lx, cy, (z0 + z1) / 2), { len = 4, light = k == math.ceil(n / 2) or n == 3, range = 18 })
	end
end

---------------------------------------------------------------------------------------------------
-- rooms
---------------------------------------------------------------------------------------------------
local Rooms: { [string]: (Ctx, Room, number, any, any) -> () } = {}

local POSTER_TEXT = { "BE KIND", "READ!", "WASH YOUR\nFLIPPERS", "STAY\nCOOL", "TEAMWORK!", "YOU CAN\nDO IT!", "MATH\nIS FUN", "DREAM\nBIG" }

local function classroomCore(ctx: Ctx, r: Room, s: number, theme: any, fire: any, deskFn: any?)
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	local zc = (z0 + z1) / 2
	-- board + alphabet on the west wall, teacher's desk in front of it (teacher faces the class)
	local bw = math.min(10, z1 - z0 - 8)
	ctx:add(Kit.board, westCF(ctx, r, s, zc), { w = bw, chalk = ctx.rng:NextNumber() < 0.4 })
	ctx:add(Kit.banner, westCF(ctx, r, s, zc), { w = bw + 2, y = 9.1, h = 1.1 })
	local tx, tz = if fire then fire.x else x0 + 5.5, if fire then fire.z else zc
	ctx.placers[s]:take(Plan.rect(tx - 0.5, tz, 6.5, 6.6))
	ctx:add(Kit.teacherDesk, ctx:at(tx, y, tz, E), { mug = theme.accent })
	-- desk rows facing the board (kids face -X: yaw W)
	local cells = Plan.grid(x0 + 8.4, x1 - 6.1, z0 + 1.2, z1 - 1.5, 4.8, 3.6)
	for _, c in cells do
		ctx:put(s, deskFn or Kit.studentDesk, c[1], c[2], W, 2.8, 4.6, {})
	end
	-- cubbies on the east wall (under the side windows), a bookcase + globe on the corridor wall
	local cw = math.min(10, z1 - z0 - 8)
	ctx:put(s, Kit.cubbies, x1 - 0.9, zc, W, cw, 1.6, { w = cw, h = 3 })
	local shelfX = x0 + 4
	if ctx:put(s, Kit.bookshelf, shelfX, z1 - 0.8, N, 5, 1.4, { w = 5, h = 5 }) then
		ctx:add(Kit.globe, ctx:at(shelfX + 1.2, y + 5, z1 - 0.8), {})
	end
	ctx:put(s, Kit.plant, x1 - 1.6, z0 + 1.6, N, 2.4, 2.4, { color = theme.accent })
	ctx:put(s, Kit.trashCan, (r.door or x1) - 5.8, z1 - 1.2, N, 1.8, 1.8, { color = theme.accent })
	ctx:add(Kit.clock, backCF(ctx, r, s, (r.door or (x0 + x1) / 2) - 6), { y = 10 })
	ctx:add(Kit.poster, eastCF(ctx, r, s, z0 + 4), { y = 6.5, text = POSTER_TEXT[ctx.rng:NextInteger(1, #POSTER_TEXT)] })
	ctx:add(Kit.poster, backCF(ctx, r, s, x1 - 3), { y = 6.8, kind = "planets", w = 4, h = 3 })
end

Rooms.classroom = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme)
	classroomCore(ctx, r, s, theme, fire)
	local x0, _x1, z0, _z1 = inner(r)
	ctx:put(s, Kit.rug, x0 + 8.5, z0 + 3, N, 5, 3.5, { w = 5, d = 3.5, color = theme.accent })
end

Rooms.art = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = Color3.fromHex("#E8DDC8") })
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	ctx:add(Kit.board, westCF(ctx, r, s, (z0 + z1) / 2), { w = 8, text = "DRAW A\nFIRE TRUCK!" })
	ctx.placers[s]:take(Plan.rect(fire.x - 0.5, fire.z, 6.5, 6.6))
	ctx:add(Kit.teacherDesk, ctx:at(fire.x, y, fire.z, E), {})
	for _, c in Plan.grid(x0 + 10, x1 - 7, z0 + 2, z1 - 3, 7, 6) do
		if ctx:put(s, Kit.roundTable, c[1], c[2], N, 6.8, 6.8, { n = 4, color = C.Cream }) then
			ctx:add(Kit.splat, ctx:at(c[1] + 3.4, y, c[2] - 2.5), {})
		end
	end
	for k = 1, 3 do
		ctx:put(s, Kit.easel, x0 + 8 + k * 3.4, z1 - 1.6, N, 2.8, 1.6, {})
	end
	for k = 1, 3 do
		ctx:add(Kit.poster, eastCF(ctx, r, s, z0 + 3 + k * 4.5), { y = 6.5, kind = "art", w = 3, h = 3 })
	end
	ctx:put(s, Kit.cubbies, x1 - 0.9, z1 - 5, W, 6, 1.6, { w = 6, h = 3 })
end

Rooms.music = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme)
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	ctx:add(Kit.board, westCF(ctx, r, s, (z0 + z1) / 2), { w = 8, text = "DO RE MI\nFA SOL LA TI" })
	ctx.placers[s]:take(Plan.rect(fire.x, fire.z, 5.4, 6))
	ctx:add(Kit.piano, ctx:at(fire.x, y, fire.z, E), {})
	ctx:put(s, Kit.drums, x1 - 4, z0 + 4, W, 5.5, 4.5, {})
	for _, c in Plan.grid(x0 + 10, x1 - 7, z0 + 3, z1 - 3, 5, 4.5) do
		ctx:put(s, Kit.studentDesk, c[1], c[2], W, 2.8, 4.6, {})
	end
	ctx:add(Kit.poster, eastCF(ctx, r, s, z1 - 5), { y = 6.5, text = "ROCK ON!" })
end

Rooms.science = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = Color3.fromHex("#CFD8D6"), grid = 2, lines = C.Steel })
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	local zc = (z0 + z1) / 2
	ctx:add(Kit.board, westCF(ctx, r, s, zc), { w = math.min(10, z1 - z0 - 8), text = "H2O + FIRE\n= STEAM!" })
	-- the demo bench on the fire spot, then rows of lab benches facing the board
	ctx.placers[s]:take(Plan.rect(fire.x, fire.z, 6.6, 3.2))
	ctx:add(Kit.labBench, ctx:at(fire.x, y, fire.z, N), { len = 6 })
	-- student benches behind it (facing the board), two columns where the room allows
	for _, bx in { x0 + 4.5, x0 + 10.5 } do
		for _, bz in { fire.z + 7, fire.z + 14.5 } do
			if bz + 3.2 < z1 then
				ctx:put(s, Kit.labBench, bx, bz, W, 6.4, 5, { len = 6 })
			end
		end
	end
	ctx:put(s, Kit.skeleton, x0 + 2, z0 + 2, E, 2, 2, {})
	ctx:add(Kit.poster, backCF(ctx, r, s, x0 + 5), { y = 6.8, kind = "table", w = 5, h = 3.4, bg = C.Cream })
	ctx:add(Kit.poster, eastCF(ctx, r, s, zc), { y = 6.6, text = "GOGGLES\nON!", bg = C.Mustard })
	ctx:put(s, Kit.bookshelf, x1 - 0.8, z1 - 4, W, 4, 1.4, { w = 4, h = 5 })
end

Rooms.library = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = Color3.fromHex("#C9A27A") })
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	local zc = (z0 + z1) / 2
	-- the big bookcase on the fire spot (east), more along the west wall
	ctx.placers[s]:take(Plan.rect(x1 - 0.8, fire.z, 1.6, 8))
	ctx:add(Kit.bookshelf, ctx:at(x1 - 0.8, y, fire.z, W), { w = 8, h = 8 })
	for k = 0, 2 do
		ctx:put(s, Kit.bookshelf, x0 + 0.8, z0 + 4 + k * 8.4, E, 8, 1.4, { w = 8, h = 8 })
	end
	-- two freestanding low stacks, a reading rug with bean bags, a table, the librarian's desk
	for k = 0, 1 do
		ctx:put(s, Kit.bookshelf, x0 + 7 + k * 5, z0 + 7, N, 4, 1.4, { w = 4, h = 4.5, color = C.WoodLight })
	end
	local rugX = (x0 + x1) / 2 + 2
	ctx:put(s, Kit.rug, rugX, zc + 3, N, 9, 6, { w = 9, d = 6, color = theme.accent, pattern = "border" })
	for k, col in { C.Pink, C.Teal, C.Mustard } do
		ctx:add(Kit.beanBag, ctx:at(rugX - 3.5 + k * 2.2, y, zc + 3 + (k % 2) * 1.5), { color = col })
	end
	ctx:put(s, Kit.roundTable, x0 + 9, zc + 7, N, 6.8, 6.8, { n = 3 })
	ctx:put(s, Kit.teacherDesk, (r.door or rugX) - 4.5, z0 + 5, S, 6, 6.2, { color = C.TealDark, mug = C.Mustard })
	ctx:add(Kit.globe, ctx:at(x0 + 7, y + 4.5, z0 + 7), {})
	ctx:add(Kit.banner, backCF(ctx, r, s, (x0 + x1) / 2), { w = 8, y = 9.4, h = 1.4, text = "READ!", bg = C.Teal, fg = C.White })
	ctx:put(s, Kit.plant, x1 - 1.6, z0 + 1.6, N, 2.4, 2.4, { size = 1.2 })
end

Rooms.cafeteria = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = C.Tile, grid = 3, lines = C.TileB, wainscot = C.Teal })
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	-- kitchen line along the west wall: the stove counter on the fire spot, fridge, sink counter
	ctx.placers[s]:take(Plan.rect(x0 + 1.3, fire.z, 2.6, 6.4))
	ctx:add(Kit.counter, ctx:at(x0 + 1.3, y, fire.z, E), { len = 6, stove = true, color = C.Steel, top = C.Chrome })
	ctx:put(s, Kit.fridge, x0 + 1.6, fire.z - 5.5, E, 3.2, 2.8, { color = C.Chrome })
	ctx:put(s, Kit.counter, x0 + 1.4, fire.z + 7, E, 6, 2.6, { len = 6, sink = true, color = C.Steel, top = C.Chrome })
	-- the serving line, open at both ends so the kitchen is reachable
	local sx = x0 + 7
	local len = math.max(6, z1 - z0 - 14)
	ctx:put(s, Kit.servingCounter, sx, (z0 + z1) / 2, E, len, 3.4, { len = len })
	-- long tables
	-- long tables running front-to-back between the serving line and the doorway aisle
	for _, c in Plan.grid(sx + 3.5, x1 - 6.1, z0 + 1, z1 - 1, 6.4, 9.6) do
		ctx:put(s, Kit.cafeTable, c[1], c[2], W, 8.4, 5.8, { len = 8 })
	end
	ctx:put(s, Kit.trashCan, x1 - 1.4, z1 - 1.4, N, 2, 2, { color = C.TealDark })
	ctx:put(s, Kit.trashCan, x1 - 1.4, z0 + 1.6, N, 2, 2, { color = C.Green })
	ctx:add(Kit.poster, eastCF(ctx, r, s, (z0 + z1) / 2), { y = 6.6, kind = "food", w = 3, h = 3.6 })
	ctx:add(Kit.clock, backCF(ctx, r, s, x1 - 4), { y = 10 })
end

Rooms.office = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = Color3.fromHex("#8E5A3C"), wainscot = C.TealDark })
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	-- the principal's desk on the fire spot (principal sits by the window, faces the door)
	ctx.placers[s]:take(Plan.rect(fire.x, fire.z - 0.8, 6.4, 6.6))
	ctx:add(Kit.teacherDesk, ctx:at(fire.x, y, fire.z, S), { color = C.Wood, mug = C.Red })
	ctx:add(Kit.rug, ctx:at(fire.x, y, fire.z + 5.5), { w = 7, d = 5, color = C.Red, pattern = "border", accent = C.Gold })
	for _, dx in { -4.6, 4.6 } do
		ctx:put(s, Kit.armchair, fire.x + dx, fire.z + 5.5, if dx < 0 then E else W, 3.2, 3, { color = C.TealDark })
	end
	ctx:put(s, Kit.filingCabinet, x0 + 1.4, z0 + 6, E, 2.2, 2.6, {})
	ctx:put(s, Kit.filingCabinet, x0 + 1.4, z0 + 8.6, E, 2.2, 2.6, { color = C.TealDark })
	ctx:put(s, Kit.bookshelf, x1 - 0.8, (z0 + z1) / 2, W, 6, 1.4, { w = 6, h = 7 })
	ctx:put(s, Kit.flag, x0 + 1.6, z0 + 1.8, N, 1.6, 1.6, { color = C.Teal })
	ctx:put(s, Kit.plant, x1 - 1.6, z0 + 1.6, N, 2.4, 2.4, { color = C.Pink })
	ctx:add(Kit.poster, westCF(ctx, r, s, (z0 + z1) / 2), { y = 6.5, text = "PRINCIPAL\nOF THE\nYEAR", bg = C.Cream, fg = C.TealDark, w = 2.4, h = 3 })
	ctx:add(Kit.poster, westCF(ctx, r, s, (z0 + z1) / 2 + 4), { y = 6.5, text = "NO\nRUNNING", bg = C.Mustard, w = 2.2, h = 2.6 })
	ctx:add(Kit.clock, backCF(ctx, r, s, x0 + 3), { y = 10, rim = C.TealDark })
end

Rooms.lobby = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = C.SchoolFloor, grid = 4, lines = Color3.fromHex("#BE8048"), blinds = false, wainscot = C.Teal })
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	ctx.placers[s]:take(Plan.rect(x0 + 1, fire.z, 2.2, 6.4))
	ctx:add(Kit.trophyCase, ctx:at(x0 + 1, y, fire.z, E), { w = 6, text = "GO PENGUINS!" })
	ctx:put(s, Kit.plant, x0 + 1.6, z0 + 1.8, N, 2.4, 2.4, { size = 1.3, color = C.Mustard })
	ctx:put(s, Kit.plant, x1 - 1.6, z0 + 1.8, N, 2.4, 2.4, { size = 1.3, color = C.Pink })
	ctx:add(Kit.rug, ctx:at((x0 + x1) / 2, y, z0 + 2.6), { w = math.min(9, x1 - x0 - 4), d = 3, color = C.Red, pattern = "stripes" })
	ctx:add(Kit.noticeBoard, eastCF(ctx, r, s, (z0 + z1) / 2 - 3), { w = 5, h = 3.4, y = 6 })
	ctx:add(Kit.pullStation, eastCF(ctx, r, s, (z0 + z1) / 2 + 2))
	ctx:add(Kit.banner, ctx:at((x0 + x1) / 2, y, z0, S), { w = math.min(12, x1 - x0 - 2), y = 9.4, h = 1.5, text = "WELCOME, PENGUINS!", bg = C.Teal, fg = C.White })
	ctx:add(Kit.exitSign, ctx:at((x0 + x1) / 2, y, z0, S), { y = 8.2 })
end

Rooms.gym = function(ctx, r, s, theme, fire)
	local x0, x1, z0, z1 = inner(r)
	local y = ctx.floors[s]
	local zc = (z0 + z1) / 2
	dressRoom(ctx, r, s, theme, { floor = C.GymFloor, wainscot = C.TealDark, blindColor = C.Mustard })
	-- court lines on a second, see-through finish
	local court = ctx:add(Kit.floorFinish, ctx:at((x0 + x1) / 2, y + 0.04, zc), { w = x1 - x0 - 4, d = z1 - z0 - 4, color = C.GymFloor })
	local top = court.PrimaryPart :: BasePart
	top.Transparency = 1
	local g = Kit.gui(top, Enum.NormalId.Top, 8)
	local function line(px: number, py: number, pw: number, ph: number)
		Kit.rect(g, px, py, pw, ph, C.White)
	end
	line(0, 0, 1, 0.012)
	line(0, 0.988, 1, 0.012)
	line(0, 0, 0.006, 1)
	line(0.994, 0, 0.006, 1)
	line(0.497, 0, 0.006, 1)
	local circle = Kit.rect(g, 0.44, 0.38, 0.12, 0.12 * (x1 - x0) / (z1 - z0), C.Red, 1)
	circle.BackgroundTransparency = 0.2
	Kit.rect(g, 0, 0.33, 0.14, 0.34, C.Teal).BackgroundTransparency = 0.3
	Kit.rect(g, 0.86, 0.33, 0.14, 0.34, C.Teal).BackgroundTransparency = 0.3
	-- hoops on the end walls (rim under the ground-floor ceiling)
	local rimY = math.min(8, ctx:ceiling(s) - y - 3.6)
	ctx:add(Kit.hoop, westCF(ctx, r, s, zc), { y = rimY })
	ctx:add(Kit.hoop, eastCF(ctx, r, s, zc), { y = rimY })
	-- bleachers along the front wall (under the sills), the mat stack on the fire spot
	ctx.placers[s]:take(Plan.rect(fire.x - 4, fire.z, 9.6, 4.4))
	ctx:add(Kit.gymMats, ctx:at(fire.x - 2.5, y, fire.z, S), {})
	local blen = math.min(16, (x1 - x0) - 18)
	if blen >= 8 then
		ctx:put(s, Kit.bleachers, x0 + 3 + blen / 2, z0 + 2.6, S, blen, 4.8, { len = blen })
	end
	ctx:add(Kit.scoreboard, backCF(ctx, r, s, (r.door or (x0 + x1) / 2) + 7), { y = 9.2 })
	ctx:add(Kit.banner, backCF(ctx, r, s, (r.door or (x0 + x1) / 2) - 8), { w = 8, y = 8.8, h = 1.6, text = "GO PENGUINS!", bg = C.Red, fg = C.Mustard })
end

Rooms.restroom = function(ctx, r, s, theme, fire)
	dressRoom(ctx, r, s, theme, { floor = C.White, grid = 1.5, lines = C.TileB, wainscot = C.PaleBlue, blinds = false })
	local x0, x1, z0, z1 = inner(r)
	local n = math.clamp(math.floor((z1 - z0 - 10) / 3.6), 1, 3)
	ctx:put(s, Kit.stalls, x0 + 2.4, z0 + 1 + n * 1.8, E, n * 3.6 + 0.2, 4.8, { n = n, color = theme.accent })
	ctx:add(Kit.sinks, eastCF(ctx, r, s, z1 - 6), { n = 2 })
	ctx.placers[s]:take(Plan.span(x1 - 2, z1 - 9, x1, z1 - 3))
	ctx:add(Kit.handDryer, eastCF(ctx, r, s, z1 - 2))
	ctx:put(s, Kit.trashCan, fire.x - 0.4, fire.z, N, 1.8, 1.8, { color = C.Steel })
end

---------------------------------------------------------------------------------------------------
-- corridor
---------------------------------------------------------------------------------------------------
local function corridor(ctx: Ctx, s: number, f: any, plan: any)
	local y = ctx.floors[s]
	local cz0, cz1 = f.corridor.z0, f.corridor.z1
	local wallZ = f.wallZ
	local west, east = -ctx.w / 2 + 0.5, ctx.w / 2 - 0.5
	ctx:add(Kit.floorFinish, ctx:at((plan.stairEdge + east) / 2, y, (cz0 + cz1) / 2), { w = east - plan.stairEdge, d = cz1 - cz0, color = C.SchoolFloor, grid = 4, lines = Color3.fromHex("#BE8048") })
	-- lockers along the back wall, off the back windows (BlockFiller: evenly(w, 4) from the east end)
	local backWins = {}
	for k = 1, 4 do
		local x = ctx.w / 2 - ctx.w * k / 5
		table.insert(backWins, { x - 2.6, x + 2.6 })
	end
	local x = plan.stairEdge + 1
	while x < east - 4 do
		local ok = true
		for _, wv in backWins do
			if x + 4 > wv[1] and x < wv[2] then
				ok = false
			end
		end
		if ok and ctx:put(s, Kit.lockers, x + 2, cz1 - 0.8, N, 4, 1.6, { n = 2 }) then
			x += 4
		else
			x += 1
		end
	end
	-- the corridor side of the corridor wall: room signs, notice boards, pull stations, a fountain
	local side = function(px: number): CFrame
		return ctx:at(px, y, wallZ + 0.5, S)
	end
	local used: { number } = {}
	for _, r in f.rooms do
		if r.door then
			ctx:add(Kit.sign, side(r.door), { y = 8.4, text = if r.kind == "classroom" then `ROOM {s}0{#used + 1}` else ROOM_NAMES[r.kind] or string.upper(r.kind), bg = C.TealDark, fg = C.White, w = 4.4 })
			table.insert(used, r.door)
		end
	end
	local function free(px: number, half: number): boolean
		if px - half < plan.stairEdge + 1 or px + half > east - 1 then
			return false
		end
		for _, dx in used do
			if math.abs(px - dx) < half + 3.2 then
				return false
			end
		end
		return true
	end
	local items = { "notice", "pull", "fountain", "poster", "notice", "poster", "pull", "poster" }
	local i = 0
	local px = plan.stairEdge + 4
	while px < east - 3 and i < 12 do
		if free(px, 2.6) then
			i += 1
			local kind = items[(i - 1) % #items + 1]
			if kind == "notice" then
				ctx:add(Kit.noticeBoard, side(px), { w = 4.4, h = 3, y = 6 })
			elseif kind == "pull" then
				ctx:add(Kit.pullStation, side(px))
			elseif kind == "fountain" then
				if ctx.placers[s]:take(Plan.rect(px, wallZ + 1.2, 2, 1.6)) then
					ctx:add(Kit.fountain, side(px))
				end
			else
				ctx:add(Kit.poster, side(px), { y = 6.6, text = POSTER_TEXT[ctx.rng:NextInteger(1, #POSTER_TEXT)] })
			end
			table.insert(used, px)
			px += 7
		else
			px += 1
		end
	end
	-- exit signs: over the stair hall, and over the back door / the far end
	ctx:add(Kit.exitSign, ctx:at((west + plan.stairEdge) / 2, ctx:ceiling(s) - 0.8, (cz0 + cz1) / 2), { y = -0.4, hang = true })
	ctx:add(Kit.exitSign, ctx:at(east, y, (cz0 + cz1) / 2, W), { y = 8.6 })
	-- ceiling panels every ~14 studs
	local cy = ctx:ceiling(s)
	local n = math.max(2, math.floor((east - west) / 14))
	for k = 1, n do
		ctx:add(Kit.ceilingLight, ctx:at(west + (k - 0.5) * (east - west) / n, cy, (cz0 + cz1) / 2), { len = 4, light = k % 2 == 1, range = 18 })
	end
	-- kids left in a hurry
	ctx:put(s, Kit.trashCan, plan.stairEdge + 2.5, wallZ + 1.4, N, 1.8, 1.8, { color = C.TealDark })
	local rng = ctx.rng
	for _ = 1, 2 do
		local bx = rng:NextNumber(plan.stairEdge + 6, east - 6)
		ctx:add(function(parent: Instance, cf: CFrame, o: any)
			local m = Instance.new("Model")
			m.Name = "DroppedBag"
			Kit.part(m, "Backpack", cf * CF(0, 0.5, 0) * CFrame.Angles(math.rad(80), rng:NextNumber(0, 6), 0), Vector3.new(1.3, 1.5, 0.8), Kit.Bright[rng:NextInteger(1, #Kit.Bright)], { fuel = 6 })
			Kit.part(m, "Paper", cf * CF(1.2, 0.04, 0.6) * CFrame.Angles(0, rng:NextNumber(0, 3), 0), Vector3.new(0.9, 0.05, 1.2), C.White, { fuel = 3 })
			m.Parent = parent
			return m
		end, ctx:at(bx, y, rng:NextNumber(cz0 + 2, cz1 - 3)), {})
	end
end

---------------------------------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------------------------------
local function layout(ctx: Ctx)
	local plan = Plan.school(ctx.w, ctx.d, ctx.storeys)
	-- the fire spot of a room (its hero piece goes there)
	local function fireFor(s: number, r: Room): any
		for _, f in plan.fires do
			if f.floor == s and f.x >= r.x0 and f.x <= r.x1 then
				return f
			end
		end
		return nil
	end
	-- the builder's own locker block gets doors drawn on it
	for _, p in ctx.site:GetChildren() do
		if p:IsA("BasePart") and p.Name == "Lockers" then
			Kit.decorateLockers(p)
		end
	end
	local themeN = 0
	for s, f in plan.floors do
		-- walls: every room boundary (once) + the corridor wall, open across the lobby and the stair hall
		local xs: { number } = {}
		local holes = {}
		for _, r in f.rooms do
			for _, x in (if r.kind == "lobby" then { r.x0, r.x1 } else { r.x0 }) do
				local dup = false
				for _, o in xs do
					dup = dup or math.abs(o - x) < 0.01
				end
				if not dup then
					table.insert(xs, x)
					Furnish_partition(ctx, s, x, r.z0, x, f.wallZ - 0.5, nil)
				end
			end
			if r.door then
				table.insert(holes, { c = r.door, w = 5, top = 7.5 })
			end
		end
		local cursor = plan.stairEdge - 0.5
		for _, r in f.rooms do
			if r.kind == "lobby" then
				Furnish_partition(ctx, s, cursor, f.wallZ, r.x0 + 0.5, f.wallZ, holes)
				cursor = r.x1 - 0.5
			end
		end
		Furnish_partition(ctx, s, cursor, f.wallZ, ctx.w / 2 - 0.5, f.wallZ, holes)
		-- keep every doorway's approach clear on both sides, an aisle from each doorway to the front
		-- windows, and a strip from every rescue spot to its room's aisle (rescue paths, hose routes)
		for _, h in holes do
			ctx.placers[s]:keep(Plan.rect(h.c, f.wallZ, 5.5, 9))
		end
		for _, r in f.rooms do
			if r.door then
				if r.kind ~= "gym" then -- the gym floor is open anyway (bleachers by the front wall)
					ctx.placers[s]:keep(Plan.span(r.door - 1.9, r.z0, r.door + 1.9, r.z1))
				end
				for _, sp in plan.rescues do
					if sp.floor == s and sp.x > r.x0 and sp.x < r.x1 then
						ctx.placers[s]:keep(Plan.span(math.min(sp.x, r.door), sp.z - 2, math.max(sp.x, r.door), sp.z + 2))
					end
				end
			end
		end
		for _, r in f.rooms do
			themeN += 1
			local theme = THEMES[(themeN - 1) % #THEMES + 1]
			local fn = Rooms[r.kind]
			if fn then
				local ok, err = pcall(fn, ctx, r, s, theme, fireFor(s, r) or { x = r.x0 + 6, z = (r.z0 + r.z1) / 2 })
				if not ok then
					warn(`[Interiors.School] {r.kind} on floor {s}: {err}`)
				end
			end
		end
		corridor(ctx, s, f, plan)
	end
end

function School.register(Furnish: any)
	Furnish_partition = Furnish.partition
	Furnish.Layouts.school = layout
end

return School
