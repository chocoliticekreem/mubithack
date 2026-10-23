--!strict
-- Pathfind [owner: Navigation]. PURE road-graph maths for the GPS (docs/game/08 "Navigation"):
-- graph decoding, nearest node / nearest point on a road, A* shortest path, polyline helpers for
-- the arrows on the road, turn hints, and the minimap rotation. No Roblox APIs (Vector3, game,
-- Instance...) so game/tests/nav.spec.luau runs it under the plain `luau` CLI.
-- Points are plain tables {x, y, z}. Node ids are always strings.
--
--   Pathfind.decode(data) -> Graph?              -- data = JSONDecode(RoadGraphJson): {nodes, edges}
--   Pathfind.build(nodes, edges) -> Graph        -- lenient (see decode)
--   Pathfind.nearestNode(g, x, z) -> (id?, dist)
--   Pathfind.nearestOnEdge(g, x, z) -> Snap?     -- closest point on any road segment
--   Pathfind.astar(g, startId, goalId) -> ({id}?, cost)
--   Pathfind.route(g, from, to) -> ({P}?, cost)  -- road polyline: snap(from) .. nodes .. snap(to)
--   Pathfind.length(poly), Pathfind.project(poly, x, z) -> (along, dist)
--   Pathfind.samples(poly, fromAlong, spacing, maxCount) -> {Sample}   -- arrow positions + headings
--   Pathfind.nextTurn(poly, along, minDeg) -> (kind?, dist)            -- "left" | "right" | "uturn"
--   Pathfind.heading(lx, lz) -> radians (0 = facing -Z "north", +pi/2 = facing +X "east")
--   Pathfind.toMap(dx, dz, heading, scale) -> (px, py)                 -- rotating minimap offset
--   Pathfind.clampRadius(px, py, r) -> (px, py, clamped)
--   Pathfind.compass(dx, dz) -> "N" | "NE" | ...

export type P = { x: number, y: number, z: number }
export type Graph = {
	pos: { [string]: P },
	adj: { [string]: { string } },
	ids: { string },
	edges: { { a: string, b: string } },
}
export type Snap = { a: string, b: string, t: number, x: number, y: number, z: number, dist: number }
export type Sample = { x: number, y: number, z: number, dx: number, dz: number, along: number }

local Pathfind = {}

local function point(v: any): P?
	if type(v) ~= "table" then
		return nil
	end
	local x = v.x or v.X or v[1]
	local y = v.y or v.Y or v[2]
	local z = v.z or v.Z or v[3]
	if type(x) == "number" and type(y) == "number" and type(z) == "number" then
		return { x = x, y = y, z = z }
	end
	-- 2D [x, z]
	if type(v[1]) == "number" and type(v[2]) == "number" and v[3] == nil then
		return { x = v[1], y = 0, z = v[2] }
	end
	-- {id = .., pos = {..}} / {position = ..}
	if v.pos ~= nil or v.position ~= nil or v.p ~= nil then
		return point(v.pos or v.position or v.p)
	end
	return nil
end

local function key(v: any): string?
	if type(v) == "string" then
		return v
	elseif type(v) == "number" then
		if v == math.floor(v) then
			return string.format("%d", v)
		end
		return tostring(v)
	end
	return nil
end

-- Lenient builder. nodes: {[id] = P} | {P} (ids 1..n) | {{id = .., x/pos ..}}.
-- edges: {{a, b}} | {{a = .., b = ..}} | {{A = .., B = ..}}. Duplicates and unknown ids are dropped.
function Pathfind.build(nodes: any, edges: any): Graph
	local g: Graph = { pos = {}, adj = {}, ids = {}, edges = {} }
	if type(nodes) ~= "table" then
		return g
	end
	local isArray = #nodes > 0
	for k, v in nodes do
		local id: string? = nil
		if type(v) == "table" and (v.id ~= nil or v.Id ~= nil or v.NodeId ~= nil) then
			id = key(v.id or v.Id or v.NodeId)
		else
			id = key(k)
		end
		local p = point(v)
		if id and p and not g.pos[id] then
			g.pos[id] = p
			g.adj[id] = {}
			table.insert(g.ids, id)
		end
	end
	table.sort(g.ids)
	-- an array of positions referenced by 0-based edge ids (JSON from a 0-based exporter)
	local shift = 0
	if isArray and type(edges) == "table" and type(nodes[1]) == "table" and nodes[1].id == nil then
		for _, e in edges do
			if type(e) == "table" and ((e[1] or e.a or e.A) == 0 or (e[2] or e.b or e.B) == 0) then
				shift = 1
				break
			end
		end
	end
	local seen: { [string]: boolean } = {}
	if type(edges) == "table" then
		for _, e in edges do
			if type(e) ~= "table" then
				continue
			end
			local ra, rb = e[1] or e.a or e.A, e[2] or e.b or e.B
			if shift == 1 then
				ra = if type(ra) == "number" then ra + 1 else ra
				rb = if type(rb) == "number" then rb + 1 else rb
			end
			local a, b = key(ra), key(rb)
			if not a or not b or a == b or not g.pos[a] or not g.pos[b] then
				continue
			end
			local k1 = if a < b then a .. "|" .. b else b .. "|" .. a
			if seen[k1] then
				continue
			end
			seen[k1] = true
			table.insert(g.adj[a], b)
			table.insert(g.adj[b], a)
			table.insert(g.edges, { a = a, b = b })
		end
	end
	return g
end

-- data = {nodes = .., edges = ..} (also accepts Nodes/Edges). nil if there is nothing usable.
function Pathfind.decode(data: any): Graph?
	if type(data) ~= "table" then
		return nil
	end
	local g = Pathfind.build(data.nodes or data.Nodes, data.edges or data.Edges)
	if #g.ids == 0 then
		return nil
	end
	return g
end

local function dist2(ax: number, az: number, bx: number, bz: number): number
	local dx, dz = ax - bx, az - bz
	return math.sqrt(dx * dx + dz * dz)
end

local function d3(a: P, b: P): number
	return dist2(a.x, a.z, b.x, b.z) -- roads are near-flat; planar distance keeps hills from skewing routes
end

function Pathfind.nearestNode(g: Graph, x: number, z: number): (string?, number)
	local best: string? = nil
	local bestD = math.huge
	for _, id in g.ids do
		local p = g.pos[id]
		local d = dist2(p.x, p.z, x, z)
		if d < bestD then
			best, bestD = id, d
		end
	end
	return best, bestD
end

-- Closest point on segment a-b to (x, z): t in [0, 1].
local function onSegment(a: P, b: P, x: number, z: number): (number, number, number, number, number)
	local ex, ez = b.x - a.x, b.z - a.z
	local len2 = ex * ex + ez * ez
	local t = 0
	if len2 > 1e-9 then
		t = math.clamp(((x - a.x) * ex + (z - a.z) * ez) / len2, 0, 1)
	end
	local px, pz = a.x + ex * t, a.z + ez * t
	local py = a.y + (b.y - a.y) * t
	return t, px, py, pz, dist2(px, pz, x, z)
end

function Pathfind.nearestOnEdge(g: Graph, x: number, z: number): Snap?
	local best: Snap? = nil
	for _, e in g.edges do
		local t, px, py, pz, d = onSegment(g.pos[e.a], g.pos[e.b], x, z)
		if not best or d < best.dist then
			best = { a = e.a, b = e.b, t = t, x = px, y = py, z = pz, dist = d }
		end
	end
	if not best then
		-- a graph with nodes but no edges: snap to the nearest node
		local id, d = Pathfind.nearestNode(g, x, z)
		if id then
			local p = g.pos[id]
			return { a = id, b = id, t = 0, x = p.x, y = p.y, z = p.z, dist = d }
		end
	end
	return best
end

-- Binary min-heap of {id, f}.
type Heap = { items: { { id: string, f: number } } }

local function push(h: Heap, id: string, f: number)
	local items = h.items
	table.insert(items, { id = id, f = f })
	local i = #items
	while i > 1 do
		local parent = i // 2
		if items[parent].f <= items[i].f then
			break
		end
		items[parent], items[i] = items[i], items[parent]
		i = parent
	end
end

local function pop(h: Heap): (string?, number)
	local items = h.items
	local n = #items
	if n == 0 then
		return nil, 0
	end
	local top = items[1]
	items[1] = items[n]
	items[n] = nil
	n -= 1
	local i = 1
	while true do
		local l, r = i * 2, i * 2 + 1
		local s = i
		if l <= n and items[l].f < items[s].f then
			s = l
		end
		if r <= n and items[r].f < items[s].f then
			s = r
		end
		if s == i then
			break
		end
		items[s], items[i] = items[i], items[s]
		i = s
	end
	return top.id, top.f
end

-- Multi-source A*: starts = {[id] = initial cost}, goals = {[id] = extra cost to finish from there},
-- goal = the point the heuristic aims at. Returns the node list and the total cost.
local function search(g: Graph, starts: { [string]: number }, goals: { [string]: number }, goal: P): ({ string }?, number)
	local gScore: { [string]: number } = {}
	local came: { [string]: string } = {}
	local closed: { [string]: boolean } = {}
	local open: Heap = { items = {} }
	for id, c in starts do
		if g.pos[id] and (gScore[id] == nil or c < gScore[id]) then
			gScore[id] = c
			push(open, id, c + d3(g.pos[id], goal))
		end
	end
	local bestGoal: string? = nil
	local bestCost = math.huge
	while true do
		local id, f = pop(open)
		if not id then
			break
		end
		if f >= bestCost then
			break -- nothing left can beat the best finish found
		end
		if closed[id] then
			continue
		end
		closed[id] = true
		local gs = gScore[id]
		local extra = goals[id]
		if extra ~= nil and gs + extra < bestCost then
			bestGoal, bestCost = id, gs + extra
		end
		local p = g.pos[id]
		for _, nb in g.adj[id] do
			if closed[nb] then
				continue
			end
			local q = g.pos[nb]
			local ng = gs + d3(p, q)
			if gScore[nb] == nil or ng < gScore[nb] then
				gScore[nb] = ng
				came[nb] = id
				push(open, nb, ng + d3(q, goal))
			end
		end
	end
	if not bestGoal then
		return nil, math.huge
	end
	local path = { bestGoal :: string }
	local cur = bestGoal :: string
	while came[cur] do
		cur = came[cur]
		table.insert(path, 1, cur)
	end
	return path, bestCost
end

function Pathfind.astar(g: Graph, startId: string, goalId: string): ({ string }?, number)
	if not g.pos[startId] or not g.pos[goalId] then
		return nil, math.huge
	end
	return search(g, { [startId] = 0 }, { [goalId] = 0 }, g.pos[goalId])
end

-- Road route from a world point to a world point. Both ends snap onto their nearest road segment;
-- the polyline runs snap(from) -> graph nodes -> snap(to). Cost is road length.
function Pathfind.route(g: Graph, from: P, to: P): ({ P }?, number)
	local s = Pathfind.nearestOnEdge(g, from.x, from.z)
	local e = Pathfind.nearestOnEdge(g, to.x, to.z)
	if not s or not e then
		return nil, math.huge
	end
	local sp: P = { x = s.x, y = s.y, z = s.z }
	local ep: P = { x = e.x, y = e.y, z = e.z }
	-- both ends on the same road segment: straight along it
	if (s.a == e.a and s.b == e.b) or (s.a == e.b and s.b == e.a) then
		return { sp, ep }, d3(sp, ep)
	end
	local starts = { [s.a] = d3(sp, g.pos[s.a]) }
	if starts[s.b] == nil or d3(sp, g.pos[s.b]) < starts[s.b] then
		starts[s.b] = d3(sp, g.pos[s.b])
	end
	local goals = { [e.a] = d3(g.pos[e.a], ep) }
	if goals[e.b] == nil or d3(g.pos[e.b], ep) < goals[e.b] then
		goals[e.b] = d3(g.pos[e.b], ep)
	end
	local ids, cost = search(g, starts, goals, ep)
	if not ids then
		return nil, math.huge
	end
	local poly: { P } = { sp }
	for _, id in ids do
		local p = g.pos[id]
		local last = poly[#poly]
		if dist2(last.x, last.z, p.x, p.z) > 0.01 then
			table.insert(poly, { x = p.x, y = p.y, z = p.z })
		end
	end
	local last = poly[#poly]
	if dist2(last.x, last.z, ep.x, ep.z) > 0.01 then
		table.insert(poly, ep)
	end
	return poly, cost
end

function Pathfind.length(poly: { P }): number
	local total = 0
	for i = 2, #poly do
		total += d3(poly[i - 1], poly[i])
	end
	return total
end

-- Distance along the polyline of the closest point to (x, z), and how far (x, z) is from the line.
function Pathfind.project(poly: { P }, x: number, z: number): (number, number)
	if #poly == 0 then
		return 0, math.huge
	end
	if #poly == 1 then
		return 0, dist2(poly[1].x, poly[1].z, x, z)
	end
	local bestAlong, bestD = 0, math.huge
	local acc = 0
	for i = 2, #poly do
		local a, b = poly[i - 1], poly[i]
		local seg = d3(a, b)
		local t, _, _, _, d = onSegment(a, b, x, z)
		if d < bestD then
			bestD, bestAlong = d, acc + seg * t
		end
		acc += seg
	end
	return bestAlong, bestD
end

-- Point and unit heading at distance `along` (clamped to the line).
function Pathfind.at(poly: { P }, along: number): (P, number, number)
	local acc = 0
	for i = 2, #poly do
		local a, b = poly[i - 1], poly[i]
		local seg = d3(a, b)
		if seg > 1e-6 and (along <= acc + seg or i == #poly) then
			local t = math.clamp((along - acc) / seg, 0, 1)
			return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t, z = a.z + (b.z - a.z) * t },
				(b.x - a.x) / seg,
				(b.z - a.z) / seg
		end
		acc += seg
	end
	local p = poly[#poly] or { x = 0, y = 0, z = 0 }
	return { x = p.x, y = p.y, z = p.z }, 0, -1
end

-- Evenly spaced samples (arrow spots) from `fromAlong` to the end, at most maxCount.
-- Sample spots are aligned to a fixed grid (multiples of spacing) so arrows don't slide as you move.
function Pathfind.samples(poly: { P }, fromAlong: number, spacing: number, maxCount: number): { Sample }
	local out: { Sample } = {}
	if #poly < 2 or spacing <= 0 then
		return out
	end
	local total = Pathfind.length(poly)
	local s = (math.floor(math.max(0, fromAlong) / spacing) + 1) * spacing
	while s < total and #out < maxCount do
		local p, dx, dz = Pathfind.at(poly, s)
		table.insert(out, { x = p.x, y = p.y, z = p.z, dx = dx, dz = dz, along = s })
		s += spacing
	end
	return out
end

-- Signed turn at a corner from direction (ax, az) to (bx, bz): +1 right, -1 left, in Roblox axes
-- (looking down -Z, +X is to the right). Returns the turn angle in degrees too.
function Pathfind.turn(ax: number, az: number, bx: number, bz: number): (number, number)
	local cross = ax * bz - az * bx
	local dot = ax * bx + az * bz
	local angle = math.deg(math.atan2(math.abs(cross), dot))
	return if cross > 0 then 1 elseif cross < 0 then -1 else 0, angle
end

-- The next corner sharper than minDeg after `along`: ("left" | "right" | "uturn", distance to it),
-- or (nil, distance to the end of the route).
function Pathfind.nextTurn(poly: { P }, along: number, minDeg: number?): (string?, number)
	local threshold = minDeg or 35
	local total = Pathfind.length(poly)
	local acc = 0
	for i = 2, #poly - 1 do
		local a, b, c = poly[i - 1], poly[i], poly[i + 1]
		local seg1 = d3(a, b)
		acc += seg1
		if acc <= along + 0.5 then
			continue
		end
		local seg2 = d3(b, c)
		if seg1 < 1e-6 or seg2 < 1e-6 then
			continue
		end
		local side, angle = Pathfind.turn((b.x - a.x) / seg1, (b.z - a.z) / seg1, (c.x - b.x) / seg2, (c.z - b.z) / seg2)
		if angle >= threshold then
			local kind = if angle >= 150 then "uturn" elseif side > 0 then "right" else "left"
			return kind, acc - along
		end
	end
	return nil, math.max(0, total - along)
end

-- Camera/character heading from a look vector: 0 = facing -Z (north), pi/2 = facing +X (east).
function Pathfind.heading(lx: number, lz: number): number
	return math.atan2(lx, -lz)
end

-- World offset (dx, dz) from the player -> minimap pixel offset (right, down) with the map rotated
-- so `heading` points up.
function Pathfind.toMap(dx: number, dz: number, heading: number, scale: number): (number, number)
	local c, s = math.cos(heading), math.sin(heading)
	-- rotate the world by -heading around Y so the facing direction lands on screen-up
	local right = dx * c + dz * s
	local fwd = dx * s - dz * c
	return right * scale, -fwd * scale
end

function Pathfind.clampRadius(px: number, py: number, r: number): (number, number, boolean)
	local d = math.sqrt(px * px + py * py)
	if d <= r or d < 1e-6 then
		return px, py, false
	end
	return px / d * r, py / d * r, true
end

local COMPASS = { "N", "NE", "E", "SE", "S", "SW", "W", "NW" }
function Pathfind.compass(dx: number, dz: number): string
	local deg = math.deg(math.atan2(dx, -dz)) % 360
	return COMPASS[(math.floor((deg + 22.5) / 45) % 8) + 1]
end

return Pathfind
