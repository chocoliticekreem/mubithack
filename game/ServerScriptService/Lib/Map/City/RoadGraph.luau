--!strict
-- RoadGraph [owner: CityBuilder]. PURE (no Roblox APIs): the city's streets as a graph for GPS,
-- traffic and road drawing. Points are { x: number, z: number } on the ground plane (world studs,
-- +Z = south). Right-hand traffic.
--
-- Grid helpers (cfg: Blocks, BlockSize, AvenueWidth, StreetWidth, Avenues) for a uniform block grid:
--   RoadGraph.width(cfg, i) / isAvenue(cfg, i) / extent(cfg) / line(cfg, i) / blockCenter(cfg, b)
--   RoadGraph.nodeId(i, j) / grid(cfg, isInternal?)  -- "N<i>_<j>" crossings, every segment not internal
-- Roads:
--   RoadGraph.roadInfo(cfg, kind, style?): RoadInfo -- kind "highway" | "avenue" | "street" | "spur" | "builder";
--       style "asphalt" | "concrete" | "dirt" | "cobble" (how CityBuilder paints it)
-- Graph:
--   RoadGraph.addNode(g, id, x, z) / addEdge(g, a, b, info?) / removeEdge(g, a, b)
--   RoadGraph.splitEdge(g, a, b, id, x, z): boolean   -- a-b becomes a-id-b with the same RoadInfo
--   RoadGraph.splitAtPoint(g, x, z, id): string?      -- splits whichever edge passes through (x, z)
--   RoadGraph.computeHalves(g)              -- sets every node's halfX / halfZ from its drawn roads
--   RoadGraph.axisAligned(g): boolean       -- every drawn edge runs along X or Z
--   RoadGraph.removeOrphans(g) / degree(g, id) / edgeInfo(g, a, b)
--   RoadGraph.nearest(g, x, z): (string?, number)
--   RoadGraph.shortestPath(g, from, to): ({ string }?, number)   -- Dijkstra over edge lengths
--   RoadGraph.connected(g): boolean
--   RoadGraph.lanes(info): { Lane }         -- lane centre offsets, see below
--   RoadGraph.export(g, y): JSON-ready table (Workspace.Map.City.RoadGraphJson):
--     { nodes = { [id] = { x, y, z } },
--       pairs = { { a, b } },                              -- plain adjacency, same order as edges
--       edges = { { a, b, kind, style, width, speedLimit, laneCount, drawn, length,
--                   lanes = { { offset, dir, width } } } } }
--   Lane offset: studs from the edge centreline, measured to the RIGHT of the a -> b direction
--   (right of unit direction (dx, dz) is (-dz, dx)). dir = 1 drives a -> b, dir = -1 drives b -> a.
--   Right-hand traffic: dir 1 lanes have positive offsets.
-- A node's halfX / halfZ: how far a road drawn along X / Z stops short of it = half the width of the
-- widest drawn road crossing it along Z / X (0 when there is none). Both > 0: a crossing square.

export type Point = { x: number, z: number, halfX: number, halfZ: number }
export type RoadInfo = { kind: string, style: string, width: number, laneCount: number, laneWidth: number, speedLimit: number, drawn: boolean }
export type Edge = { a: string, b: string, info: RoadInfo }
export type Lane = { offset: number, dir: number, width: number }
export type Graph = {
	nodes: { [string]: Point },
	edges: { Edge },
	adj: { [string]: { [string]: number } },
}

local RoadGraph = {}

local function avenues(cfg: any): { [number]: boolean }
	local set = {}
	for _, i in cfg.Avenues or {} do
		set[i] = true
	end
	return set
end

function RoadGraph.isAvenue(cfg: any, i: number): boolean
	return avenues(cfg)[i] == true
end

function RoadGraph.width(cfg: any, i: number): number
	return if RoadGraph.isAvenue(cfg, i) then cfg.AvenueWidth else cfg.StreetWidth
end

function RoadGraph.extent(cfg: any): number
	local sum = cfg.Blocks * cfg.BlockSize
	for i = 0, cfg.Blocks do
		sum += RoadGraph.width(cfg, i)
	end
	return sum
end

function RoadGraph.line(cfg: any, i: number): number
	local pos = -RoadGraph.extent(cfg) / 2
	for k = 0, i - 1 do
		pos += RoadGraph.width(cfg, k) + cfg.BlockSize
	end
	return pos + RoadGraph.width(cfg, i) / 2
end

function RoadGraph.blockCenter(cfg: any, b: number): number
	return RoadGraph.line(cfg, b) + RoadGraph.width(cfg, b) / 2 + cfg.BlockSize / 2
end

function RoadGraph.roadInfo(cfg: any, kind: string, style: string?): RoadInfo
	local st = style or "asphalt"
	if kind == "highway" then
		return { kind = kind, style = st, width = cfg.HighwayWidth or 48, laneCount = 4, laneWidth = 12, speedLimit = cfg.HighwaySpeed or 80, drawn = true }
	elseif kind == "avenue" then
		return { kind = kind, style = st, width = cfg.AvenueWidth or 48, laneCount = 4, laneWidth = 12, speedLimit = cfg.AvenueSpeed or 60, drawn = true }
	elseif kind == "street" then
		return { kind = kind, style = st, width = cfg.StreetWidth or 32, laneCount = 2, laneWidth = 14, speedLimit = cfg.StreetSpeed or 45, drawn = true }
	elseif kind == "spur" then
		return { kind = kind, style = st, width = cfg.SpurWidth or 32, laneCount = 2, laneWidth = 14, speedLimit = cfg.SpurSpeed or 30, drawn = true }
	end
	-- "builder": a reused location builder's own road (it draws it)
	return { kind = kind, style = st, width = 12, laneCount = 2, laneWidth = 6, speedLimit = cfg.SpurSpeed or 30, drawn = false }
end

function RoadGraph.lanes(info: RoadInfo): { Lane }
	local out: { Lane } = {}
	local perSide = info.laneCount // 2
	for k = 1, perSide do
		local off = (k - 0.5) * info.laneWidth
		table.insert(out, { offset = off, dir = 1, width = info.laneWidth })
		table.insert(out, { offset = -off, dir = -1, width = info.laneWidth })
	end
	return out
end

function RoadGraph.nodeId(i: number, j: number): string
	return `N{i}_{j}`
end

function RoadGraph.new(): Graph
	return { nodes = {}, edges = {}, adj = {} }
end

function RoadGraph.addNode(g: Graph, id: string, x: number, z: number, halfX: number?, halfZ: number?)
	g.nodes[id] = { x = x, z = z, halfX = halfX or 0, halfZ = halfZ or 0 }
	g.adj[id] = g.adj[id] or {}
end

local function dist(a: Point, b: Point): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

local DEFAULT_INFO: RoadInfo = { kind = "street", style = "asphalt", width = 32, laneCount = 2, laneWidth = 14, speedLimit = 45, drawn = true }

function RoadGraph.addEdge(g: Graph, a: string, b: string, info: RoadInfo?)
	assert(g.nodes[a] and g.nodes[b], `edge {a}-{b}: unknown node`)
	if a == b or g.adj[a][b] then
		return
	end
	local d = dist(g.nodes[a], g.nodes[b])
	g.adj[a][b] = d
	g.adj[b][a] = d
	table.insert(g.edges, { a = a, b = b, info = info or DEFAULT_INFO })
end

function RoadGraph.edgeInfo(g: Graph, a: string, b: string): RoadInfo?
	for _, e in g.edges do
		if (e.a == a and e.b == b) or (e.a == b and e.b == a) then
			return e.info
		end
	end
	return nil
end

function RoadGraph.removeEdge(g: Graph, a: string, b: string): RoadInfo?
	for k, e in g.edges do
		if (e.a == a and e.b == b) or (e.a == b and e.b == a) then
			table.remove(g.edges, k)
			g.adj[a][b] = nil
			g.adj[b][a] = nil
			return e.info
		end
	end
	return nil
end

function RoadGraph.splitEdge(g: Graph, a: string, b: string, id: string, x: number, z: number): boolean
	local na = g.nodes[a]
	local info = RoadGraph.removeEdge(g, a, b)
	if not info or not na then
		return false
	end
	RoadGraph.addNode(g, id, x, z)
	RoadGraph.addEdge(g, a, id, info)
	RoadGraph.addEdge(g, id, b, info)
	return true
end

-- Splits the edge that passes through (x, z) (axis-aligned edges). Returns the node id at that
-- point (an existing node there is reused), or nil when no edge passes through it.
function RoadGraph.splitAtPoint(g: Graph, x: number, z: number, id: string): string?
	local eps = 0.01
	for nid, p in g.nodes do
		if math.abs(p.x - x) < eps and math.abs(p.z - z) < eps then
			return nid
		end
	end
	for _, e in g.edges do
		local a, b = g.nodes[e.a], g.nodes[e.b]
		local onX = math.abs(a.z - z) < eps and math.abs(b.z - z) < eps and x > math.min(a.x, b.x) and x < math.max(a.x, b.x)
		local onZ = math.abs(a.x - x) < eps and math.abs(b.x - x) < eps and z > math.min(a.z, b.z) and z < math.max(a.z, b.z)
		if onX or onZ then
			RoadGraph.splitEdge(g, e.a, e.b, id, x, z)
			return id
		end
	end
	return nil
end

function RoadGraph.computeHalves(g: Graph)
	for _, p in g.nodes do
		p.halfX, p.halfZ = 0, 0
	end
	for _, e in g.edges do
		if e.info.drawn then
			local a, b = g.nodes[e.a], g.nodes[e.b]
			local alongX = math.abs(b.x - a.x) > math.abs(b.z - a.z)
			for _, p in { a, b } do
				if alongX then
					p.halfZ = math.max(p.halfZ, e.info.width / 2)
				else
					p.halfX = math.max(p.halfX, e.info.width / 2)
				end
			end
		end
	end
end

function RoadGraph.axisAligned(g: Graph): boolean
	for _, e in g.edges do
		local a, b = g.nodes[e.a], g.nodes[e.b]
		if e.info.drawn and math.abs(a.x - b.x) > 0.01 and math.abs(a.z - b.z) > 0.01 then
			return false
		end
	end
	return true
end

function RoadGraph.degree(g: Graph, id: string): number
	local n = 0
	for _ in g.adj[id] or {} do
		n += 1
	end
	return n
end

function RoadGraph.removeOrphans(g: Graph)
	for id in g.nodes do
		if RoadGraph.degree(g, id) == 0 then
			g.nodes[id] = nil
			g.adj[id] = nil
		end
	end
end

function RoadGraph.grid(cfg: any, isInternal: ((kind: string, i: number, j: number) -> boolean)?): Graph
	local g = RoadGraph.new()
	local n = cfg.Blocks
	for i = 0, n do
		for j = 0, n do
			RoadGraph.addNode(g, RoadGraph.nodeId(i, j), RoadGraph.line(cfg, i), RoadGraph.line(cfg, j), RoadGraph.width(cfg, i) / 2, RoadGraph.width(cfg, j) / 2)
		end
	end
	local function info(line: number): RoadInfo
		return RoadGraph.roadInfo(cfg, if RoadGraph.isAvenue(cfg, line) then "avenue" else "street")
	end
	for i = 0, n do
		for j = 0, n - 1 do
			-- x-line i (runs north-south) between z-lines j and j+1
			if not (isInternal and isInternal("x", i, j)) then
				RoadGraph.addEdge(g, RoadGraph.nodeId(i, j), RoadGraph.nodeId(i, j + 1), info(i))
			end
			-- z-line i (runs east-west) between x-lines j and j+1
			if not (isInternal and isInternal("z", j, i)) then
				RoadGraph.addEdge(g, RoadGraph.nodeId(j, i), RoadGraph.nodeId(j + 1, i), info(i))
			end
		end
	end
	RoadGraph.removeOrphans(g)
	return g
end

function RoadGraph.nearest(g: Graph, x: number, z: number): (string?, number)
	local best, bestD = nil, math.huge
	for id, p in g.nodes do
		local d = math.sqrt((p.x - x) ^ 2 + (p.z - z) ^ 2)
		if d < bestD or (d == bestD and best and id < best) then
			best, bestD = id, d
		end
	end
	return best, bestD
end

function RoadGraph.shortestPath(g: Graph, from: string, to: string): ({ string }?, number)
	if not (g.nodes[from] and g.nodes[to]) then
		return nil, math.huge
	end
	local distTo: { [string]: number } = { [from] = 0 }
	local prev: { [string]: string } = {}
	local done: { [string]: boolean } = {}
	while true do
		local u, ud = nil, math.huge
		for id, d in distTo do
			if not done[id] and d < ud then
				u, ud = id, d
			end
		end
		if u == nil then
			return nil, math.huge
		end
		if u == to then
			break
		end
		done[u] = true
		for v, w in g.adj[u] do
			local nd = ud + w
			if not done[v] and nd < (distTo[v] or math.huge) then
				distTo[v] = nd
				prev[v] = u
			end
		end
	end
	local path = { to }
	local cur = to
	while cur ~= from do
		cur = prev[cur]
		table.insert(path, 1, cur)
	end
	return path, distTo[to]
end

function RoadGraph.connected(g: Graph): boolean
	local start = next(g.nodes)
	if start == nil then
		return true
	end
	local seen = { [start] = true }
	local stack = { start }
	while #stack > 0 do
		local u = table.remove(stack) :: string
		for v in g.adj[u] do
			if not seen[v] then
				seen[v] = true
				table.insert(stack, v)
			end
		end
	end
	for id in g.nodes do
		if not seen[id] then
			return false
		end
	end
	return true
end

function RoadGraph.export(g: Graph, y: number): { [string]: any }
	local nodes = {}
	for id, p in g.nodes do
		nodes[id] = { p.x, y, p.z }
	end
	local edges = {}
	local pairs_ = {}
	for _, e in g.edges do
		if g.nodes[e.a] and g.nodes[e.b] then
			local lanes = {}
			for _, l in RoadGraph.lanes(e.info) do
				table.insert(lanes, { offset = l.offset, dir = l.dir, width = l.width })
			end
			table.insert(edges, {
				a = e.a,
				b = e.b,
				kind = e.info.kind,
				style = e.info.style,
				length = g.adj[e.a][e.b],
				width = e.info.width,
				speedLimit = e.info.speedLimit,
				laneCount = e.info.laneCount,
				drawn = e.info.drawn,
				lanes = lanes,
			})
			table.insert(pairs_, { e.a, e.b })
		end
	end
	return { nodes = nodes, edges = edges, pairs = pairs_ }
end

return RoadGraph
