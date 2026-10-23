--!strict
-- RoadNet [owner: Traffic]. PURE (no Roblox APIs; spec: game/tests/traffic.spec.luau).
-- Turns CityBuilder's road graph (decoded RoadGraphJson, or the same shape built from the RoadGraph
-- folder) into directed LANES and junction CONNECTORS that cars follow.
--
--   RoadNet.parse(data, cfg) -> Net?        -- nil when there is nothing drivable
--   RoadNet.nextLanes(net, laneId) -> {number}
--   RoadNet.pickNext(net, laneId, roll: number 0..1, straightBias) -> number?
--   RoadNet.turn(inLane, outLane) -> "straight" | "left" | "right" | "uturn"
--   RoadNet.connector(net, fromId, toId) -> Seg  (cached cubic Bezier through the junction)
--   RoadNet.laneSeg(net, laneId) -> Seg
--   RoadNet.point(seg, s) -> (x, y, z, hx, hz)  -- position s studs along a segment, unit heading
--
-- Accepted graph shapes (tolerant, CityBuilder is still settling it):
--   nodes: { [id] = {x,y,z} | {X=,Y=,Z=} | {x=,y=,z=} | {pos=...} }  or  { {id=, x=, y=, z=} | {id=, pos=} ... }
--   edges: { {a, b} | {a=, b=} | {A=, B=} | {from=, to=} ... }, each optionally with
--     speedLimit/speed/limit, width, and lanes as either
--       { count=, direction=, offsets={...} | centreOffsets= | centerOffsets=, directions={...}, speedLimit= }
--     or an array of lane records { offset= | centre= | center=, direction= | dir=, speed= }.
--   direction: 1/-1, "forward"/"AB"/"oneway" (A->B), "backward"/"BA" (B->A), "both"/"twoway".
--   Offsets are signed studs from the A->B centreline, + = right of A->B travel (right-hand traffic).
-- Coordinates: Roblox world (Y up). Right of a heading (hx, hz) is (-hz, hx).

export type Lane = {
	id: number,
	edge: number,
	from: string,
	to: string,
	ax: number,
	ay: number,
	az: number,
	bx: number,
	by: number,
	bz: number,
	hx: number,
	hz: number,
	len: number,
	speed: number,
}

export type Seg = {
	kind: "lane" | "conn",
	len: number,
	lane: Lane?, -- kind "lane"
	node: string?, -- kind "conn": the junction it crosses
	from: number?, -- kind "conn": lane ids
	to: number?,
	p: { number }?, -- kind "conn": 12 numbers, 4 control points x,y,z
	lut: { number }?, -- kind "conn": cumulative arc length at t = i/N
}

export type Node = { x: number, y: number, z: number }

export type Net = {
	nodes: { [string]: Node },
	degree: { [string]: number },
	lanes: { Lane },
	outOf: { [string]: { number } },
	conns: { [string]: Seg },
	segs: { [number]: Seg },
	edgeCount: number,
}

export type Cfg = {
	LaneOffset: number,
	RoadWidth: number,
	SpeedLimit: number,
	IntersectionTrim: number,
	BendTrim: number,
}

local RoadNet = {}

local LUT_N = 10

local function num(v: any): number?
	if type(v) == "number" and v == v then
		return v
	end
	if type(v) == "string" then
		return tonumber(v)
	end
	return nil
end

-- {x,y,z} | {X,Y,Z} | {[1],[2],[3]} | {pos=...} | {position=...} -> Node?
local function vec(v: any): Node?
	if type(v) ~= "table" then
		return nil
	end
	local inner = v.pos or v.position or v.Position or v.p
	if inner ~= nil and type(inner) == "table" then
		return vec(inner)
	end
	local x = num(v.x) or num(v.X) or num(v[1])
	local y = num(v.y) or num(v.Y) or num(v[2])
	local z = num(v.z) or num(v.Z) or num(v[3])
	if x and z then
		return { x = x, y = y or 0, z = z }
	end
	return nil
end
RoadNet.vec = vec

-- 1 = A->B, -1 = B->A, 0 = both ways, nil = unknown
function RoadNet.dir(v: any): number?
	if type(v) == "number" then
		return if v > 0 then 1 elseif v < 0 then -1 else 0
	end
	if type(v) == "boolean" then
		return if v then 1 else -1
	end
	if type(v) ~= "string" then
		return nil
	end
	local s = string.gsub(string.lower(v), "[%s_]", "")
	if s == "forward" or s == "fwd" or s == "ab" or s == "a->b" or s == "atob" or s == "oneway" or s == "+" or s == "1" or s == "+1" then
		return 1
	end
	if s == "backward" or s == "back" or s == "ba" or s == "b->a" or s == "btoa" or s == "reverse" or s == "rev" or s == "-" or s == "-1" then
		return -1
	end
	if s == "both" or s == "twoway" or s == "two-way" or s == "bi" or s == "bidirectional" or s == "0" then
		return 0
	end
	return nil
end

local function id(v: any): string?
	if type(v) == "string" or type(v) == "number" then
		return tostring(v)
	end
	return nil
end

-- {offset, dir, speed?} records for one edge
type LaneSpec = { off: number, dir: number, speed: number? }

local function laneSpecs(e: any, cfg: Cfg): { LaneSpec }
	local L = e.lanes or e.Lanes
	local out: { LaneSpec } = {}
	local width = num(e.width) or num(e.Width) or cfg.RoadWidth
	if type(L) == "table" and type(L[1]) == "table" then
		for _, rec in L :: { any } do
			local off = num(rec.offset) or num(rec.centre) or num(rec.center) or num(rec.o) or num(rec.Offset)
			local d = RoadNet.dir(rec.direction or rec.dir or rec.Direction)
			if off ~= nil then
				if d == nil or d == 0 then
					d = if off >= 0 then 1 else -1
				end
				table.insert(out, { off = off, dir = d :: number, speed = num(rec.speed) or num(rec.speedLimit) })
			end
		end
		return out
	end
	local count: number? = nil
	local offsets: any = nil
	local dirs: any = nil
	local scalarDir: number? = nil
	if type(L) == "table" then
		count = num(L.count) or num(L.Count) or num(L.n)
		offsets = L.offsets or L.centreOffsets or L.centerOffsets or L.laneOffsets or L.Offsets
		dirs = L.directions or L.dirs
		scalarDir = RoadNet.dir(L.direction or L.dir or L.Direction)
		width = num(L.width) or width
	elseif type(L) == "number" then
		count = L
	end
	scalarDir = scalarDir or RoadNet.dir(e.direction or e.dir) or (if e.oneway or e.oneWay then 1 else nil)
	if type(offsets) == "table" and #offsets > 0 then
		for i, o in offsets :: { any } do
			local off = num(o)
			if off == nil then
				continue
			end
			local d: number? = if type(dirs) == "table" then RoadNet.dir(dirs[i]) else scalarDir
			if d == nil or d == 0 then
				d = if off >= 0 then 1 else -1
			end
			table.insert(out, { off = off, dir = d :: number })
		end
		return out
	end
	local n = math.max(1, math.floor(count or 2))
	if scalarDir == 1 or scalarDir == -1 then
		-- one-way: n lanes spread across the road
		local w = width / n
		for i = 1, n do
			table.insert(out, { off = -width / 2 + w * (i - 0.5), dir = scalarDir :: number })
		end
		return out
	end
	if n == 1 then
		n = 2
	end
	local per = math.max(1, math.floor(n / 2))
	local w = if count then width / (per * 2) else cfg.LaneOffset * 2
	for i = 1, per do
		local off = w * (i - 0.5)
		table.insert(out, { off = off, dir = 1 })
		table.insert(out, { off = -off, dir = -1 })
	end
	return out
end

function RoadNet.parse(data: any, cfg: Cfg): Net?
	if type(data) ~= "table" then
		return nil
	end
	local rawNodes = data.nodes or data.Nodes
	local rawEdges = data.edges or data.Edges
	if type(rawNodes) ~= "table" or type(rawEdges) ~= "table" then
		return nil
	end
	local nodes: { [string]: Node } = {}
	for k, v in rawNodes :: { [any]: any } do
		local nid: string? = nil
		if type(v) == "table" and (v.id ~= nil or v.Id ~= nil or v.NodeId ~= nil) then
			nid = id(v.id or v.Id or v.NodeId)
		elseif type(k) == "string" then
			nid = k
		elseif type(k) == "number" then
			nid = tostring(k)
		end
		local p = vec(v)
		if nid and p then
			nodes[nid] = p
		end
	end

	type E = { a: string, b: string, raw: any }
	local edges: { E } = {}
	local degree: { [string]: number } = {}
	for _, e in rawEdges :: { any } do
		if type(e) ~= "table" then
			continue
		end
		local a = id(e.a or e.A or e.from or e.From or e[1])
		local b = id(e.b or e.B or e.to or e.To or e[2])
		if a and b and a ~= b and nodes[a] and nodes[b] then
			table.insert(edges, { a = a, b = b, raw = e })
			degree[a] = (degree[a] or 0) + 1
			degree[b] = (degree[b] or 0) + 1
		end
	end
	if #edges == 0 then
		return nil
	end

	local net: Net = { nodes = nodes, degree = degree, lanes = {}, outOf = {}, conns = {}, segs = {}, edgeCount = #edges }
	local function trimAt(n: string): number
		return if (degree[n] or 0) >= 3 then cfg.IntersectionTrim else cfg.BendTrim
	end
	for ei, e in edges do
		local A, B = nodes[e.a], nodes[e.b]
		local dx, dz = B.x - A.x, B.z - A.z
		local elen = math.sqrt(dx * dx + dz * dz)
		if elen < 1 then
			continue
		end
		dx, dz = dx / elen, dz / elen
		local rx, rz = -dz, dx
		local ta, tb = trimAt(e.a), trimAt(e.b)
		local maxTrim = math.max(0, elen - 4)
		if ta + tb > maxTrim then
			local k = maxTrim / (ta + tb)
			ta, tb = ta * k, tb * k
		end
		local espeed = num(e.raw.speedLimit) or num(e.raw.speed) or num(e.raw.limit) or num(e.raw.SpeedLimit)
		local L = e.raw.lanes
		if type(L) == "table" and type(L[1]) ~= "table" then
			espeed = num(L.speedLimit) or num(L.speed) or num(L.limit) or espeed
		end
		for _, spec in laneSpecs(e.raw, cfg) do
			local sx = A.x + rx * spec.off + dx * ta
			local sz = A.z + rz * spec.off + dz * ta
			local ex = B.x + rx * spec.off - dx * tb
			local ez = B.z + rz * spec.off - dz * tb
			local ya = A.y + (B.y - A.y) * (ta / elen)
			local yb = B.y + (A.y - B.y) * (tb / elen)
			local from, to = e.a, e.b
			local hx, hz = dx, dz
			if spec.dir < 0 then
				sx, sz, ex, ez = ex, ez, sx, sz
				ya, yb = yb, ya
				from, to = e.b, e.a
				hx, hz = -dx, -dz
			end
			local len = math.sqrt((ex - sx) ^ 2 + (ez - sz) ^ 2)
			if len < 1 then
				continue
			end
			local lane: Lane = {
				id = #net.lanes + 1,
				edge = ei,
				from = from,
				to = to,
				ax = sx,
				ay = ya,
				az = sz,
				bx = ex,
				by = yb,
				bz = ez,
				hx = hx,
				hz = hz,
				len = len,
				speed = spec.speed or espeed or cfg.SpeedLimit,
			}
			table.insert(net.lanes, lane)
			local list = net.outOf[from]
			if not list then
				list = {}
				net.outOf[from] = list
			end
			table.insert(list, lane.id)
		end
	end
	if #net.lanes == 0 then
		return nil
	end
	return net
end

function RoadNet.turn(a: Lane, b: Lane): string
	local cross = a.hx * b.hz - a.hz * b.hx
	local dot = a.hx * b.hx + a.hz * b.hz
	if dot < -0.7 then
		return "uturn"
	end
	if math.abs(cross) < 0.4 then
		return "straight"
	end
	-- right of (hx, hz) is (-hz, hx): turning toward it gives cross > 0
	return if cross > 0 then "right" else "left"
end

-- Lanes a car on `laneId` may continue onto. No U-turns unless it's a dead end.
function RoadNet.nextLanes(net: Net, laneId: number): { number }
	local lane = net.lanes[laneId]
	if not lane then
		return {}
	end
	local out: { number } = {}
	local uturns: { number } = {}
	for _, lid in net.outOf[lane.to] or {} do
		local cand = net.lanes[lid]
		if cand.edge == lane.edge then
			table.insert(uturns, lid)
		else
			table.insert(out, lid)
		end
	end
	if #out == 0 then
		return uturns
	end
	return out
end

function RoadNet.pickNext(net: Net, laneId: number, roll: number, straightBias: number?): number?
	local opts = RoadNet.nextLanes(net, laneId)
	if #opts == 0 then
		return nil
	end
	local lane = net.lanes[laneId]
	local weights: { number } = {}
	local total = 0
	for i, lid in opts do
		local w = if RoadNet.turn(lane, net.lanes[lid]) == "straight" then (straightBias or 1) else 1
		weights[i] = w
		total += w
	end
	local pick = math.clamp(roll, 0, 0.999999) * total
	for i, w in weights do
		pick -= w
		if pick < 0 then
			return opts[i]
		end
	end
	return opts[#opts]
end

local function bez(p: { number }, t: number): (number, number, number)
	local u = 1 - t
	local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
	return a * p[1] + b * p[4] + c * p[7] + d * p[10],
		a * p[2] + b * p[5] + c * p[8] + d * p[11],
		a * p[3] + b * p[6] + c * p[9] + d * p[12]
end

function RoadNet.laneSeg(net: Net, laneId: number): Seg
	local seg = net.segs[laneId]
	if seg then
		return seg
	end
	local lane = net.lanes[laneId]
	local made: Seg = { kind = "lane", len = lane.len, lane = lane }
	net.segs[laneId] = made
	return made
end

function RoadNet.connector(net: Net, fromId: number, toId: number): Seg
	local key = `{fromId}>{toId}`
	local hit = net.conns[key]
	if hit then
		return hit
	end
	local a, b = net.lanes[fromId], net.lanes[toId]
	local dist = math.sqrt((b.ax - a.bx) ^ 2 + (b.az - a.bz) ^ 2)
	local k = math.max(dist * 0.45, 3)
	if RoadNet.turn(a, b) == "uturn" then
		k = math.max(k, dist * 0.9, 6)
	end
	local p = {
		a.bx, a.by, a.bz,
		a.bx + a.hx * k, a.by, a.bz + a.hz * k,
		b.ax - b.hx * k, b.ay, b.az - b.hz * k,
		b.ax, b.ay, b.az,
	}
	local lut = { 0 }
	local px, _, pz = bez(p, 0)
	local acc = 0
	for i = 1, LUT_N do
		local x, _, z = bez(p, i / LUT_N)
		acc += math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
		lut[i + 1] = acc
		px, pz = x, z
	end
	local seg: Seg = { kind = "conn", len = math.max(acc, 0.5), node = a.to, from = fromId, to = toId, p = p, lut = lut }
	net.conns[key] = seg
	return seg
end

-- arc length -> Bezier t through the lookup table
local function tAt(lut: { number }, s: number): number
	if s <= 0 then
		return 0
	end
	for i = 2, #lut do
		if lut[i] >= s then
			local s0, s1 = lut[i - 1], lut[i]
			local f = if s1 > s0 then (s - s0) / (s1 - s0) else 0
			return ((i - 2) + f) / (#lut - 1)
		end
	end
	return 1
end

function RoadNet.point(seg: Seg, s: number): (number, number, number, number, number)
	if seg.kind == "lane" then
		local L = seg.lane :: Lane
		local f = math.clamp(s / L.len, 0, 1)
		return L.ax + (L.bx - L.ax) * f, L.ay + (L.by - L.ay) * f, L.az + (L.bz - L.az) * f, L.hx, L.hz
	end
	local p = seg.p :: { number }
	local t = tAt(seg.lut :: { number }, s)
	local x, y, z = bez(p, t)
	local t2 = math.min(t + 0.02, 1)
	local t1 = t2 - 0.02
	local x1, _, z1 = bez(p, t1)
	local x2, _, z2 = bez(p, t2)
	local hx, hz = x2 - x1, z2 - z1
	local m = math.sqrt(hx * hx + hz * hz)
	if m < 1e-6 then
		hx, hz = p[4] - p[1], p[6] - p[3]
		m = math.max(math.sqrt(hx * hx + hz * hz), 1e-6)
	end
	return x, y, z, hx / m, hz / m
end

-- Squared distance from (x, z) to a lane's centreline (for spawning near players).
function RoadNet.laneDist2(lane: Lane, x: number, z: number): number
	local vx, vz = lane.bx - lane.ax, lane.bz - lane.az
	local f = math.clamp(((x - lane.ax) * vx + (z - lane.az) * vz) / (lane.len * lane.len), 0, 1)
	local px, pz = lane.ax + vx * f, lane.az + vz * f
	return (x - px) ^ 2 + (z - pz) ^ 2
end

return RoadNet
