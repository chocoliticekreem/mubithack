--!strict
-- Rooms [owner: Smoke agent]. PURE room finding for SmokeService (no Roblox APIs, no requires, so
-- game/tests/rooms.spec.luau runs it with the `luau` CLI). Everything is in one building's local XZ
-- plane (SmokeService turns parts into that frame first).
--
-- A storey is a grid of square cells over the building. Walls, doors and windows crossing the
-- storey's sample height are rasterized as blocked cells (fattened by `pad` so a 1-stud wall can't
-- slip between two cell centres), then a 4-connected flood fill splits the free cells: whatever
-- touches the grid border is OUTSIDE (label 0), every other pocket of at least `minCells` is a room.
--
--   Rooms.grid(minX, minZ, maxX, maxZ, cell, margin): Grid
--   Rooms.idx(g, i, k): number                       -- 1-based cell index
--   Rooms.centre(g, i, k): (number, number)          -- cell centre (x, z)
--   Rooms.cellOf(g, x, z): (number?, number?)        -- nil outside the grid
--   Rooms.rasterize(g, rects, pad): { [number]: true }
--   Rooms.flood(g, blocked, minCells): ({ [number]: number }, { Room })   -- labels: 0 outside, >0 room
--   Rooms.labelAt(g, labels, x, z, reach): number?   -- room id, 0 = outside, nil = only walls nearby
--   Rooms.rects(g, labels, id, maxRects): { CellRect } -- greedy boxes covering a room (largest first)
--   Rooms.levels(walls, tol, minCount): { Level }    -- storey floors from wall bottoms
--   Rooms.storeyOf(levels, y): number?               -- index of the storey containing height y

local Rooms = {}

-- A blocker in local XZ: centre, unit vector of its own X axis (ax, az), half size along it (hx)
-- and across it (hz).
export type Rect = { cx: number, cz: number, ax: number, az: number, hx: number, hz: number }
export type Grid = { x0: number, z0: number, cell: number, nx: number, nz: number }
export type Room = { id: number, cells: number, i0: number, k0: number, i1: number, k1: number, cx: number, cz: number }
export type CellRect = { i0: number, k0: number, i1: number, k1: number }
export type Level = { y: number, h: number }
export type Wall = { bottom: number, top: number }

function Rooms.grid(minX: number, minZ: number, maxX: number, maxZ: number, cell: number, margin: number): Grid
	local x0, z0 = minX - margin, minZ - margin
	return {
		x0 = x0,
		z0 = z0,
		cell = cell,
		nx = math.max(1, math.ceil((maxX + margin - x0) / cell)),
		nz = math.max(1, math.ceil((maxZ + margin - z0) / cell)),
	}
end

function Rooms.idx(g: Grid, i: number, k: number): number
	return (k - 1) * g.nx + i
end

function Rooms.centre(g: Grid, i: number, k: number): (number, number)
	return g.x0 + (i - 0.5) * g.cell, g.z0 + (k - 0.5) * g.cell
end

function Rooms.cellOf(g: Grid, x: number, z: number): (number?, number?)
	local i = math.floor((x - g.x0) / g.cell) + 1
	local k = math.floor((z - g.z0) / g.cell) + 1
	if i < 1 or k < 1 or i > g.nx or k > g.nz then
		return nil, nil
	end
	return i, k
end

function Rooms.rasterize(g: Grid, rects: { Rect }, pad: number): { [number]: true }
	local blocked: { [number]: true } = {}
	for _, r in rects do
		local hx, hz = r.hx + pad, r.hz + pad
		local ax, az = r.ax, r.az
		-- axis-aligned extent of the (rotated) rect
		local ex = math.abs(ax) * hx + math.abs(az) * hz
		local ez = math.abs(az) * hx + math.abs(ax) * hz
		local i0 = math.max(1, math.floor((r.cx - ex - g.x0) / g.cell) + 1)
		local i1 = math.min(g.nx, math.floor((r.cx + ex - g.x0) / g.cell) + 1)
		local k0 = math.max(1, math.floor((r.cz - ez - g.z0) / g.cell) + 1)
		local k1 = math.min(g.nz, math.floor((r.cz + ez - g.z0) / g.cell) + 1)
		for k = k0, k1 do
			for i = i0, i1 do
				local px, pz = Rooms.centre(g, i, k)
				local dx, dz = px - r.cx, pz - r.cz
				local u = dx * ax + dz * az
				local v = -dx * az + dz * ax
				if math.abs(u) <= hx and math.abs(v) <= hz then
					blocked[Rooms.idx(g, i, k)] = true
				end
			end
		end
	end
	return blocked
end

function Rooms.flood(g: Grid, blocked: { [number]: true }, minCells: number): ({ [number]: number }, { Room })
	local labels: { [number]: number } = {}
	local nx, nz = g.nx, g.nz
	local function fill(si: number, sk: number, label: number): { number }
		local cells: { number } = {}
		local stack = { si, sk }
		labels[Rooms.idx(g, si, sk)] = label
		while #stack > 0 do
			local k = table.remove(stack) :: number
			local i = table.remove(stack) :: number
			table.insert(cells, Rooms.idx(g, i, k))
			for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
				local ni, nk = i + d[1], k + d[2]
				if ni >= 1 and nk >= 1 and ni <= nx and nk <= nz then
					local id = Rooms.idx(g, ni, nk)
					if not blocked[id] and labels[id] == nil then
						labels[id] = label
						table.insert(stack, ni)
						table.insert(stack, nk)
					end
				end
			end
		end
		return cells
	end
	-- outside: everything reachable from the border
	for i = 1, nx do
		for _, k in { 1, nz } do
			local id = Rooms.idx(g, i, k)
			if not blocked[id] and labels[id] == nil then
				fill(i, k, 0)
			end
		end
	end
	for k = 1, nz do
		for _, i in { 1, nx } do
			local id = Rooms.idx(g, i, k)
			if not blocked[id] and labels[id] == nil then
				fill(i, k, 0)
			end
		end
	end
	local rooms: { Room } = {}
	local nextId = 1
	for k = 1, nz do
		for i = 1, nx do
			local id = Rooms.idx(g, i, k)
			if not blocked[id] and labels[id] == nil then
				local label = nextId
				local cells = fill(i, k, label)
				if #cells < minCells then
					for _, c in cells do
						labels[c] = -1 -- a pocket too small to be a room
					end
					continue
				end
				nextId += 1
				local i0, k0, i1, k1 = nx, nz, 1, 1
				local sx, sz = 0, 0
				for _, c in cells do
					local ci = (c - 1) % nx + 1
					local ck = (c - ci) // nx + 1
					i0, i1 = math.min(i0, ci), math.max(i1, ci)
					k0, k1 = math.min(k0, ck), math.max(k1, ck)
					local x, z = Rooms.centre(g, ci, ck)
					sx += x
					sz += z
				end
				table.insert(rooms, {
					id = label,
					cells = #cells,
					i0 = i0,
					k0 = k0,
					i1 = i1,
					k1 = k1,
					cx = sx / #cells,
					cz = sz / #cells,
				})
			end
		end
	end
	return labels, rooms
end

-- The room at (x, z), searching rings of cells up to `reach` around it when that cell is a wall.
-- A room beats outside at the same ring; nil when only walls / tiny pockets are nearby.
function Rooms.labelAt(g: Grid, labels: { [number]: number }, x: number, z: number, reach: number): number?
	local ci, ck = Rooms.cellOf(g, x, z)
	if not ci or not ck then
		return 0 -- off the grid = outside the building
	end
	for r = 0, reach do
		local sawOutside = false
		for k = ck - r, ck + r do
			for i = ci - r, ci + r do
				if math.max(math.abs(i - ci), math.abs(k - ck)) == r and i >= 1 and k >= 1 and i <= g.nx and k <= g.nz then
					local l = labels[Rooms.idx(g, i, k)]
					if l and l > 0 then
						return l
					elseif l == 0 then
						sawOutside = true
					end
				end
			end
		end
		if sawOutside then
			return 0
		end
	end
	return nil
end

function Rooms.rects(g: Grid, labels: { [number]: number }, id: number, maxRects: number): { CellRect }
	local used: { [number]: true } = {}
	local out: { CellRect } = {}
	local function free(i: number, k: number): boolean
		local c = Rooms.idx(g, i, k)
		return labels[c] == id and not used[c]
	end
	for k = 1, g.nz do
		for i = 1, g.nx do
			if free(i, k) then
				local i1 = i
				while i1 + 1 <= g.nx and free(i1 + 1, k) do
					i1 += 1
				end
				local k1 = k
				while k1 + 1 <= g.nz do
					local ok = true
					for ii = i, i1 do
						if not free(ii, k1 + 1) then
							ok = false
							break
						end
					end
					if not ok then
						break
					end
					k1 += 1
				end
				for kk = k, k1 do
					for ii = i, i1 do
						used[Rooms.idx(g, ii, kk)] = true
					end
				end
				table.insert(out, { i0 = i, k0 = k, i1 = i1, k1 = k1 })
			end
		end
	end
	table.sort(out, function(a, b)
		return (a.i1 - a.i0 + 1) * (a.k1 - a.k0 + 1) > (b.i1 - b.i0 + 1) * (b.k1 - b.k0 + 1)
	end)
	while #out > maxRects do
		table.remove(out)
	end
	return out
end

-- Storey floors: wall bottoms clustered within `tol`; a cluster needs `minCount` walls. A storey's
-- height is its walls' tallest span, capped by the next storey's floor.
function Rooms.levels(walls: { Wall }, tol: number, minCount: number): { Level }
	local sorted = table.clone(walls)
	table.sort(sorted, function(a, b)
		return a.bottom < b.bottom
	end)
	local clusters: { { Wall } } = {}
	for _, w in sorted do
		local last = clusters[#clusters]
		if last and w.bottom - last[1].bottom <= tol then
			table.insert(last, w)
		else
			table.insert(clusters, { w })
		end
	end
	local out: { Level } = {}
	for _, c in clusters do
		if #c >= minCount then
			local h = 0
			for _, w in c do
				h = math.max(h, w.top - w.bottom)
			end
			table.insert(out, { y = c[1].bottom, h = h })
		end
	end
	for n = 1, #out - 1 do
		out[n].h = math.min(out[n].h, out[n + 1].y - out[n].y)
	end
	return out
end

function Rooms.storeyOf(levels: { Level }, y: number): number?
	for n = #levels, 1, -1 do
		local l = levels[n]
		if y >= l.y - 0.5 and y < l.y + l.h + 0.5 then
			return n
		end
	end
	return nil
end

return Rooms
