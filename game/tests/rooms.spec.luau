--!strict
-- Rooms: walls rasterized onto a grid, flood fill into rooms vs outside, door sides, layer boxes, storeys.
local Spec = require("./Spec")
local Rooms = require("../ServerScriptService/Lib/Fire/Rooms")

-- A 20 x 10 house (x -10..10, z 0..10), 1-stud walls, a partition at x = 2 with a door (door panel
-- = a blocker too, like the game: doors are links, not holes), a front door at x = -5.
local function house(withPartitionGap: boolean?): { Rooms.Rect }
	local function wall(cx: number, cz: number, alongX: boolean, len: number): Rooms.Rect
		if alongX then
			return { cx = cx, cz = cz, ax = 1, az = 0, hx = len / 2, hz = 0.5 }
		end
		return { cx = cx, cz = cz, ax = 0, az = 1, hx = len / 2, hz = 0.5 }
	end
	local rects = {
		wall(0, 0, true, 21), -- front (the front door panel fills its gap)
		wall(0, 10, true, 21), -- back
		wall(-10, 5, false, 10), -- left
		wall(10, 5, false, 10), -- right
	}
	if withPartitionGap then
		table.insert(rects, wall(2, 2, false, 4)) -- partition with a 4-stud open gap at z 4..8
		table.insert(rects, wall(2, 9, false, 2))
	else
		table.insert(rects, wall(2, 5, false, 10)) -- partition incl. its door panel
	end
	return rects
end

local function build(rects: { Rooms.Rect })
	local g = Rooms.grid(-10.5, -0.5, 10.5, 10.5, 1.5, 3)
	local blocked = Rooms.rasterize(g, rects, 0.75)
	local labels, rooms = Rooms.flood(g, blocked, 6)
	return g, labels, rooms
end

Spec.test("a partition splits the house into two rooms, the rest is outside", function()
	local g, labels, rooms = build(house())
	Spec.eq(#rooms, 2, "rooms")
	local west = Rooms.labelAt(g, labels, -5, 5, 0)
	local east = Rooms.labelAt(g, labels, 6, 5, 0)
	Spec.truthy(west and west > 0, "west room")
	Spec.truthy(east and east > 0 and east ~= west, "east room differs")
	Spec.eq(Rooms.labelAt(g, labels, 0, -3, 0), 0, "in front of the house is outside")
	Spec.eq(Rooms.labelAt(g, labels, 50, 50, 0), 0, "off the grid is outside")
end)

Spec.test("an open gap in the partition makes one room", function()
	local _, _, rooms = build(house(true))
	Spec.eq(#rooms, 1, "rooms")
end)

Spec.test("door sides: sampling across a wall finds the room on each side", function()
	local g, labels = build(house())
	-- the partition door at (2, 5), normal along X
	local a = Rooms.labelAt(g, labels, 2 - 2, 5, 1)
	local b = Rooms.labelAt(g, labels, 2 + 2, 5, 1)
	Spec.truthy(a and b and a > 0 and b > 0 and a ~= b, "door joins the two rooms")
	-- the front door at (-5, 0), normal along Z: room inside, outside in front
	Spec.truthy((Rooms.labelAt(g, labels, -5, 2, 1) or 0) > 0, "inside")
	Spec.eq(Rooms.labelAt(g, labels, -5, -2, 1), 0, "outside")
end)

Spec.test("a wall cell reaches out to the nearest room", function()
	local g, labels = build(house())
	Spec.truthy((Rooms.labelAt(g, labels, -10, 5, 2) or 0) >= 0, "something found")
	Spec.truthy((Rooms.labelAt(g, labels, -5, 9.9, 2) or 0) > 0, "back wall belongs to the room inside")
end)

Spec.test("rotated blockers are rasterized along their own axis", function()
	local g = Rooms.grid(-10, -10, 10, 10, 1, 0)
	local s = math.sqrt(0.5)
	local blocked = Rooms.rasterize(g, { { cx = 0, cz = 0, ax = s, az = s, hx = 5, hz = 0.2 } }, 0.3)
	local i, k = Rooms.cellOf(g, 2.5, 2.5)
	Spec.truthy(blocked[Rooms.idx(g, i :: number, k :: number)], "on the diagonal")
	local i2, k2 = Rooms.cellOf(g, 2.5, -2.5)
	Spec.eq(blocked[Rooms.idx(g, i2 :: number, k2 :: number)], nil, "off the diagonal")
end)

Spec.test("layer boxes cover every cell of a room exactly once", function()
	local g, labels, rooms = build(house())
	for _, r in rooms do
		local boxes = Rooms.rects(g, labels, r.id, 99)
		local covered = 0
		for _, b in boxes do
			covered += (b.i1 - b.i0 + 1) * (b.k1 - b.k0 + 1)
		end
		Spec.eq(covered, r.cells, `room {r.id} cells`)
		Spec.eq(#boxes, 1, "a rectangular room is one box")
	end
end)

Spec.test("an L-shaped room needs two boxes, capped by maxRects", function()
	local g = Rooms.grid(0, 0, 6, 6, 1, 0)
	local labels: { [number]: number } = {}
	for k = 1, 6 do
		for i = 1, 6 do
			labels[Rooms.idx(g, i, k)] = if i <= 2 or k <= 2 then 1 else 0
		end
	end
	Spec.eq(#Rooms.rects(g, labels, 1, 9), 2, "two boxes")
	Spec.eq(#Rooms.rects(g, labels, 1, 1), 1, "capped")
end)

Spec.test("storey levels come from wall bottoms; heights stop at the next floor", function()
	local walls = {}
	for _ = 1, 4 do
		table.insert(walls, { bottom = 1, top = 12 })
		table.insert(walls, { bottom = 12.02, top = 23 })
	end
	table.insert(walls, { bottom = 30, top = 36 }) -- a lone shed wall: not a storey
	local levels = Rooms.levels(walls, 0.5, 2)
	Spec.eq(#levels, 2, "levels")
	Spec.near(levels[1].y, 1, 1e-9)
	Spec.near(levels[1].h, 11, 1e-6, "capped by the next floor")
	Spec.near(levels[2].h, 10.98, 1e-6)
	Spec.eq(Rooms.storeyOf(levels, 5), 1)
	Spec.eq(Rooms.storeyOf(levels, 15), 2)
	Spec.eq(Rooms.storeyOf(levels, 40), nil)
end)

return Spec.finish()
