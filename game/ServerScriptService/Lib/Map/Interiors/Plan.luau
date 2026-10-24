--!strict
-- Interiors/Plan [owner: interiors]. Pure layout maths for the mission-site interiors that
-- Interiors/Furnish builds when MapService:BindSite hands a site to a run. No Roblox APIs (specced in
-- game/tests/interiors.spec.luau). All coordinates are on a building's floor plane: x across the
-- front (-w/2..w/2), z from the front wall (0) to the back wall (d); -Z faces the street.
--
--   Plan.rect(cx, cz, sx, sz) -> Rect                     centre + size
--   Plan.span(x0, z0, x1, z1) -> Rect                     corners (any order)
--   Plan.overlap(a, b, pad?) -> boolean                   true when a and b (grown by pad) intersect
--   Plan.placer(keep) -> Placer                           p:fits(r) / p:take(r) -> boolean / p:keep(r)
--   Plan.split(x0, x1, rooms, avoid, wallPad?) -> { Room } rooms left -> right; walls nudged off `avoid`
--       rooms: { { kind, weight, min, keep? } } (keep: never dropped); avoid: { { x0, x1 } }
--       Rooms that can't fit their minimum width are dropped (keep = true ones last).
--   Plan.grid(x0, x1, z0, z1, cellW, cellD, maxCols?, maxRows?) -> { { x, z } }  cell centres, centred
--   Plan.school(w, d, storeys) -> SchoolPlan                the procedural school (BlockFiller school)
--       floors[s] = { rooms = { Room }, corridor = Rect, wallZ = number }, stairEdge, fires, rescues
--       Room = { kind, x0, x1, z0, z1, door = x of its doorway in the corridor wall (nil = open) }
--       fires = { { id, floor, x, z, room } }, rescues = { { id, floor, x, z, variant, pose } },
--       gasTank = { floor, x, z } (the chem-lab hazard)
local Plan = {}

export type Rect = { x0: number, z0: number, x1: number, z1: number }
export type Room = { kind: string, x0: number, x1: number, z0: number, z1: number, door: number? }
export type Spot = { id: string, floor: number, x: number, z: number, room: string?, variant: string?, pose: string? }
export type SchoolPlan = {
	w: number,
	d: number,
	storeys: number,
	stairEdge: number,
	floors: { { rooms: { Room }, corridor: Rect, wallZ: number } },
	fires: { Spot },
	rescues: { Spot },
	gasTank: Spot,
}

function Plan.rect(cx: number, cz: number, sx: number, sz: number): Rect
	return { x0 = cx - sx / 2, z0 = cz - sz / 2, x1 = cx + sx / 2, z1 = cz + sz / 2 }
end

function Plan.span(ax: number, az: number, bx: number, bz: number): Rect
	return { x0 = math.min(ax, bx), z0 = math.min(az, bz), x1 = math.max(ax, bx), z1 = math.max(az, bz) }
end

function Plan.overlap(a: Rect, b: Rect, pad: number?): boolean
	local p = pad or 0
	return a.x0 < b.x1 + p and b.x0 < a.x1 + p and a.z0 < b.z1 + p and b.z0 < a.z1 + p
end

export type Placer = {
	keeps: { Rect },
	taken: { Rect },
	fits: (self: Placer, r: Rect) -> boolean,
	take: (self: Placer, r: Rect) -> boolean,
	keep: (self: Placer, r: Rect) -> (),
}

-- Keep-out zones (doors, stairs, rescue spots, aisles) plus everything placed so far. take() only
-- claims a rect that touches neither.
function Plan.placer(keep: { Rect }?): Placer
	local p = { keeps = table.clone(keep or {}), taken = {} } :: any
	function p.fits(self: Placer, r: Rect): boolean
		for _, k in self.keeps do
			if Plan.overlap(r, k) then
				return false
			end
		end
		for _, t in self.taken do
			if Plan.overlap(r, t) then
				return false
			end
		end
		return true
	end
	function p.take(self: Placer, r: Rect): boolean
		if not self:fits(r) then
			return false
		end
		table.insert(self.taken, r)
		return true
	end
	function p.keep(self: Placer, r: Rect)
		table.insert(self.keeps, r)
	end
	return p :: Placer
end

-- Nearest x to `x` that is at least `pad` from every avoid range and inside [lo, hi] (x if none).
local function nudge1(x: number, avoid: { { number } }, pad: number, lo: number, hi: number): (number, boolean)
	local function clear(c: number): boolean
		if c < lo or c > hi then
			return false
		end
		for _, a in avoid do
			if c > a[1] - pad and c < a[2] + pad then
				return false
			end
		end
		return true
	end
	if clear(x) then
		return x, true
	end
	for k = 1, 80 do
		local s = k * 0.25
		if clear(x - s) then
			return x - s, true
		end
		if clear(x + s) then
			return x + s, true
		end
	end
	return x, false
end

-- nudge1 with a shrinking clearance (pad, then 1, then 0.6) before giving up.
local function nudge(x: number, avoid: { { number } }, pad: number, lo: number, hi: number): number
	for _, p in { pad, 1, 0.6 } do
		local nx, ok = nudge1(x, avoid, math.min(p, pad), lo, hi)
		if ok then
			return nx
		end
	end
	return x
end

function Plan.split(x0: number, x1: number, rooms: { any }, avoid: { { number } }?, wallPad: number?): { Room }
	local list = table.clone(rooms)
	local total = x1 - x0
	-- drop rooms that can't have their minimum width (droppable ones first, from the right)
	while #list > 0 do
		local need = 0
		for _, r in list do
			need += r.min
		end
		if need <= total then
			break
		end
		local drop = nil
		for i = #list, 1, -1 do
			if not list[i].keep then
				drop = i
				break
			end
		end
		table.remove(list, drop or #list)
	end
	if #list == 0 then
		return {}
	end
	local need, wsum = 0, 0
	for _, r in list do
		need += r.min
		wsum += r.weight or 1
	end
	local extra = total - need
	local out: { Room } = {}
	local cursor = x0
	for i, r in list do
		local width = r.min + extra * (r.weight or 1) / wsum
		local right = if i == #list then x1 else cursor + width
		if i < #list and avoid then
			-- the wall between this room and the next: off windows, never squeezing a room below its min
			right = nudge(right, avoid, wallPad or 2.5, cursor + r.min, x1 - list[i + 1].min)
		end
		table.insert(out, { kind = r.kind, x0 = cursor, x1 = right, z0 = 0, z1 = 0 })
		cursor = right
	end
	return out
end

function Plan.grid(x0: number, x1: number, z0: number, z1: number, cellW: number, cellD: number, maxCols: number?, maxRows: number?): { { number } }
	local cols = math.max(0, math.floor((x1 - x0) / cellW))
	local rows = math.max(0, math.floor((z1 - z0) / cellD))
	if maxCols then
		cols = math.min(cols, maxCols)
	end
	if maxRows then
		rows = math.min(rows, maxRows)
	end
	local ox = (x0 + x1) / 2 - cols * cellW / 2
	local oz = (z0 + z1) / 2 - rows * cellD / 2
	local out = {}
	for r = 1, rows do
		for c = 1, cols do
			table.insert(out, { ox + (c - 0.5) * cellW, oz + (r - 0.5) * cellD })
		end
	end
	return out
end

---------------------------------------------------------------------------------------------------
-- The procedural school (BlockFiller Build.school): a corridor along the back wall (the lockers),
-- rooms along the front. Stairs (BlockFiller shell) run up the left wall: x < -w/2 + 9.5, so the
-- first wall stands at stairEdge and the stair hall stays open to the corridor.
--   Ground: cafeteria + office | lobby (front doors, open to the corridor) | gym + restroom
--   Upper:  classroom, classroom, restroom, library, science lab (the chem-lab gas tank), ...
---------------------------------------------------------------------------------------------------
Plan.SchoolCorridor = 8 -- clear corridor depth behind the rooms
Plan.SchoolLobbyHalf = 8 -- lobby x -8..8 (front doors at +-0.03 w)

-- Front windows (BlockFiller: evenly(w, 8) along the front wall): walls never end on a pane.
function Plan.schoolWindows(w: number): { { number } }
	local out = {}
	for k = 1, 8 do
		local x = -w / 2 + w * k / 9
		table.insert(out, { x - 2, x + 2 })
	end
	return out
end

function Plan.school(w: number, d: number, storeys: number): SchoolPlan
	local stairEdge = -w / 2 + 10.5
	local east = w / 2 - 0.5
	local wallZ = d - 0.5 - Plan.SchoolCorridor - 0.5 -- corridor wall centre line
	local z0, z1 = 0.5, wallZ - 0.5
	local windows = Plan.schoolWindows(w)
	-- lobby walls: just outside the front doors (+-0.03 w, 4 wide), off the panes either side
	local L = nudge(math.max(Plan.SchoolLobbyHalf, 0.03 * w + 3), windows, 1, 0.03 * w + 3, 16)
	local plan: SchoolPlan = { w = w, d = d, storeys = storeys, stairEdge = stairEdge, floors = {}, fires = {}, rescues = {}, gasTank = { id = "GasTank", floor = 1, x = 0, z = 0 } }
	local function finish(rooms: { Room }): { Room }
		for _, r in rooms do
			r.z0, r.z1 = z0, z1
			-- doorways (and the aisle from them) by the east end of a room, so the desk rows / tables keep
			-- the middle; the gym keeps a centred door, small rooms too
			if r.kind == "gym" or r.x1 - r.x0 < 18 then
				r.door = (r.x0 + r.x1) / 2
			elseif r.kind ~= "lobby" then
				r.door = r.x1 - 4.5
			end
		end
		return rooms
	end
	for s = 1, storeys do
		local rooms: { Room }
		if s == 1 then
			local west = Plan.split(stairEdge, -L, {
				{ kind = "cafeteria", weight = 2, min = 16, keep = true },
				{ kind = "office", weight = 1, min = 10 },
			}, windows)
			local eastRooms = Plan.split(L, east, {
				{ kind = "gym", weight = 3, min = 22, keep = true },
				{ kind = "restroom", weight = 0, min = 10 },
			}, windows)
			rooms = west
			table.insert(rooms, { kind = "lobby", x0 = -L, x1 = L, z0 = 0, z1 = 0 })
			for _, r in eastRooms do
				table.insert(rooms, r)
			end
		else
			local seq = if s == 2
				then {
					{ kind = "classroom", weight = 2, min = 20, keep = true },
					{ kind = "classroom", weight = 2, min = 20 },
					{ kind = "restroom", weight = 0, min = 10 },
					{ kind = "library", weight = 2, min = 18 },
					{ kind = "science", weight = 2, min = 20, keep = true },
				}
				else {
					{ kind = "classroom", weight = 1, min = 20, keep = true },
					{ kind = "art", weight = 1, min = 20 },
					{ kind = "classroom", weight = 1, min = 20 },
					{ kind = "music", weight = 1, min = 18 },
				}
			rooms = Plan.split(stairEdge, east, seq, windows)
		end
		table.insert(plan.floors, {
			rooms = finish(rooms),
			corridor = Plan.span(-w / 2 + 0.5, wallZ + 0.5, w / 2 - 0.5, d - 0.5),
			wallZ = wallZ,
		})
	end
	-- fire starts (the hero piece of a room) and rescue spots, in a stable order
	local fireAt: { [string]: (Room) -> (number, number) } = {
		cafeteria = function(r)
			return r.x0 + 2.5, z0 + 8 -- the stove on the kitchen line
		end,
		lobby = function(r)
			return r.x0 + 2, (z0 + z1) / 2 -- the trophy case
		end,
		office = function(r)
			return (r.x0 + r.x1) / 2, z0 + 7 -- the principal's desk
		end,
		gym = function(r)
			return r.x1 - 5, z0 + 5 -- the mat stack
		end,
		classroom = function(r)
			return r.x0 + 6, (z0 + z1) / 2 -- the teacher's desk (board on the west wall)
		end,
		art = function(r)
			return r.x0 + 6, (z0 + z1) / 2
		end,
		music = function(r)
			return r.x0 + 6, (z0 + z1) / 2
		end,
		library = function(r)
			return r.x1 - 2, (z0 + z1) / 2 -- the big bookcase
		end,
		science = function(r)
			return (r.x0 + r.x1) / 2, z0 + 9 -- the demo lab bench
		end,
	}
	fireAt.restroom = function(r)
		return r.x1 - 2, z0 + 3 -- the paper-towel bin
	end
	-- the kitchen and the chem lab always burn; the restroom only when the school is small
	local PRIORITY = { cafeteria = 1, science = 2, office = 3, classroom = 4, library = 5, gym = 6, art = 7, music = 8, lobby = 9, restroom = 10 }
	local cands = {}
	for s, f in plan.floors do
		for i, r in f.rooms do
			local fn = fireAt[r.kind]
			if fn then
				local x, z = fn(r)
				table.insert(cands, { pri = PRIORITY[r.kind] or 99, order = s * 100 + i, floor = s, x = x, z = z, room = r.kind })
			end
		end
	end
	table.sort(cands, function(a, b)
		if a.pri ~= b.pri then
			return a.pri < b.pri
		end
		return a.order < b.order
	end)
	for i = 1, math.min(8, #cands) do
		local c = cands[i]
		table.insert(plan.fires, { id = `F{i}`, floor = c.floor, x = c.x, z = c.z, room = c.room })
	end
	-- 8 kids + the teacher, then two spares upstairs (escalation "two kids hiding upstairs")
	-- one by every room's doorway first, then a second one in the bigger rooms (by the front windows)
	local kids: { Spot } = {}
	for pass = 1, 2 do
		for s, f in plan.floors do
			for _, r in f.rooms do
				if r.kind ~= "lobby" and r.kind ~= "restroom" then
					local cx = (r.x0 + r.x1) / 2
					if pass == 1 then
						table.insert(kids, { id = "", floor = s, x = (r.door or cx) - 3.5, z = z1 - 3.5, room = r.kind, variant = "Kid" })
					elseif r.x1 - r.x0 >= 24 then
						table.insert(kids, { id = "", floor = s, x = cx - 3, z = z0 + 3.5, room = r.kind, variant = "Kid" })
					end
				end
			end
		end
	end
	local k = 0
	for _, spot in kids do
		if k >= 8 then
			break
		end
		k += 1
		spot.id = `R{k}`
		spot.pose = if k % 3 == 0 then "sitting" else "stand"
		table.insert(plan.rescues, spot)
	end
	-- the teacher: in the last room upstairs (the science lab), away from the kids' spots
	local top = math.min(2, storeys)
	local tf = plan.floors[top]
	local last = tf.rooms[#tf.rooms]
	-- the chem-lab gas tank (school_alarm's explosion set piece): the science lab's front corner
	local lab = last
	for _, r in tf.rooms do
		if r.kind == "science" then
			lab = r
		end
	end
	plan.gasTank = { id = "GasTank", floor = top, x = lab.x1 - 1.7, z = z0 + 3, room = lab.kind }
	table.insert(plan.rescues, { id = `R{k + 1}`, floor = top, x = last.x1 - 7, z = (z0 + z1) / 2 + 3, variant = "Teacher", pose = "stand" })
	-- spares at the far ends of the top corridor
	local cz = (tf.corridor.z0 + tf.corridor.z1) / 2
	table.insert(plan.rescues, { id = `R{k + 2}`, floor = top, x = stairEdge + 5, z = cz, variant = "Kid", pose = "sitting" })
	table.insert(plan.rescues, { id = `R{k + 3}`, floor = top, x = w / 2 - 7, z = cz, variant = "Kid", pose = "sitting" })
	return plan
end

return Plan
