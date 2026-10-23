--!strict
-- Traffic: lane building/following (RoadNet) and driving + emergency-yield decisions (Driver).
local Spec = require("./Spec")
local RoadNet = require("../ServerScriptService/Lib/Traffic/RoadNet")
local Driver = require("../ServerScriptService/Lib/Traffic/Driver")

local CFG = {
	LaneOffset = 6,
	RoadWidth = 24,
	SpeedLimit = 32,
	IntersectionTrim = 13,
	BendTrim = 6,
	MinGap = 5,
	Headway = 0.9,
	LookAhead = 48,
	LeaderLateral = 3.6,
	PedLateral = 4.6,
	YieldRadius = 120,
	OncomingRadius = 55,
	YieldBehindSlack = 8,
	PassClear = 18,
	RamSpeed = 18,
	RamLookahead = 0.28,
	TruckFront = 14,
	TruckHalfWidth = 5,
	CarRadius = 3.4,
}

-- A plus-shaped junction: centre C, arms N (-Z), S (+Z), E (+X), W (-X), 100 studs each.
local function plus(): any
	return {
		nodes = {
			C = { x = 0, y = 0, z = 0 },
			N = { x = 0, y = 0, z = -100 },
			S = { x = 0, y = 0, z = 100 },
			E = { x = 100, y = 0, z = 0 },
			W = { x = -100, y = 0, z = 0 },
		},
		edges = { { a = "S", b = "C" }, { a = "C", b = "N" }, { a = "C", b = "E" }, { a = "W", b = "C" } },
	}
end

local function laneFrom(net: any, from: string, to: string): any
	for _, l in net.lanes do
		if l.from == from and l.to == to then
			return l
		end
	end
	return nil
end

Spec.test("parse: default two-way lanes, right-hand traffic, trimmed at the junction", function()
	local net = RoadNet.parse(plus(), CFG) :: any
	Spec.truthy(net, "net")
	Spec.eq(#net.lanes, 8, "2 lanes x 4 edges")
	Spec.eq(net.degree.C, 4)
	-- northbound S->C: heading -Z, right of that is +X, so the lane sits at x = +6
	local nb = laneFrom(net, "S", "C")
	Spec.near(nb.hz, -1)
	Spec.near(nb.ax, 6)
	Spec.near(nb.bx, 6)
	Spec.near(nb.az, 100 - 6, 1e-6, "dead end S trimmed by BendTrim")
	Spec.near(nb.bz, 13, 1e-6, "junction C trimmed by IntersectionTrim")
	-- southbound C->S is on the other side
	local sb = laneFrom(net, "C", "S")
	Spec.near(sb.ax, -6)
	Spec.near(sb.hz, 1)
end)

Spec.test("parse: array nodes, JSON-ish vectors, per-edge lane data and speed limit", function()
	local net = RoadNet.parse({
		nodes = { { id = 1, pos = { 0, 2, 0 } }, { id = 2, X = 200, Y = 2, Z = 0 } },
		edges = { { 1, 2, lanes = { count = 4, direction = "both", speedLimit = 40 } } },
	}, CFG) :: any
	Spec.eq(#net.lanes, 4)
	local offs = {}
	for _, l in net.lanes do
		Spec.eq(l.speed, 40)
		Spec.near(l.ay, 2)
		table.insert(offs, if l.hx > 0 then l.az else -l.az)
	end
	-- eastbound lanes (+X heading, right = +Z) at z = 3 and 9; westbound mirrored
	table.sort(offs)
	Spec.near(offs[1], 3)
	Spec.near(offs[4], 9)
end)

Spec.test("parse: one-way edges, explicit offsets + lane records", function()
	local net = RoadNet.parse({
		nodes = { a = { x = 0, z = 0 }, b = { x = 0, z = -80 } },
		edges = {
			{ a = "a", b = "b", lanes = { offsets = { -3, 3 }, direction = "forward" } },
			{ A = "b", B = "a", lanes = { { offset = 2, dir = "BA", speed = 12 } } },
		},
	}, CFG) :: any
	Spec.eq(#net.lanes, 3)
	Spec.eq(#(net.outOf.a or {}), 3, "both forward lanes of edge 1 + the BA lane of edge 2 leave a")
	local rec = net.lanes[3]
	Spec.eq(rec.from, "a")
	Spec.eq(rec.speed, 12)
end)

Spec.test("parse: garbage in, nil out", function()
	Spec.eq(RoadNet.parse(nil, CFG), nil)
	Spec.eq(RoadNet.parse({ nodes = {}, edges = {} }, CFG), nil)
	Spec.eq(RoadNet.parse({ nodes = { a = { x = 0, z = 0 } }, edges = { { "a", "zzz" } } }, CFG), nil)
end)

Spec.test("turns: straight/left/right, no U-turn unless dead end", function()
	local net = RoadNet.parse(plus(), CFG) :: any
	local nb = laneFrom(net, "S", "C")
	Spec.eq(RoadNet.turn(nb, laneFrom(net, "C", "N")), "straight")
	Spec.eq(RoadNet.turn(nb, laneFrom(net, "C", "E")), "right")
	Spec.eq(RoadNet.turn(nb, laneFrom(net, "C", "W")), "left")
	Spec.eq(RoadNet.turn(nb, laneFrom(net, "C", "S")), "uturn")
	local opts = RoadNet.nextLanes(net, nb.id)
	Spec.eq(#opts, 3, "N, E, W but not back to S")
	-- dead end at N: the only way on is the U-turn
	local deadEnd = RoadNet.nextLanes(net, laneFrom(net, "C", "N").id)
	Spec.eq(#deadEnd, 1)
	Spec.eq(net.lanes[deadEnd[1]].to, "C")
end)

Spec.test("pickNext covers every option and biases straight", function()
	local net = RoadNet.parse(plus(), CFG) :: any
	local nb = laneFrom(net, "S", "C")
	local seen: { [string]: number } = {}
	for i = 0, 99 do
		local lid = RoadNet.pickNext(net, nb.id, i / 100, 2) :: number
		local to = net.lanes[lid].to
		seen[to] = (seen[to] or 0) + 1
	end
	Spec.truthy(seen.N and seen.E and seen.W, "all three reachable")
	Spec.eq(seen.S, nil)
	Spec.eq(seen.N, 50, "straight weight 2 of 4")
end)

Spec.test("lane following: points stay on the centreline, heading along the lane", function()
	local net = RoadNet.parse(plus(), CFG) :: any
	local nb = laneFrom(net, "S", "C")
	local seg = RoadNet.laneSeg(net, nb.id)
	Spec.eq(seg.len, nb.len)
	local x, _, z, hx, hz = RoadNet.point(seg, 10)
	Spec.near(x, 6)
	Spec.near(z, 94 - 10)
	Spec.near(hx, 0)
	Spec.near(hz, -1)
	local _, _, zEnd = RoadNet.point(seg, 99999)
	Spec.near(zEnd, 13, 1e-6, "clamped at the stop line")
end)

Spec.test("connector: right turn curves from stop line to the next lane, heading turns", function()
	local net = RoadNet.parse(plus(), CFG) :: any
	local nb = laneFrom(net, "S", "C")
	local eb = laneFrom(net, "C", "E")
	local c = RoadNet.connector(net, nb.id, eb.id)
	Spec.eq(c.node, "C")
	Spec.truthy(c.len > 5 and c.len < 25, `short tight right turn, got {c.len}`)
	local x0, _, z0, hx0, hz0 = RoadNet.point(c, 0)
	Spec.near(x0, nb.bx, 1e-3)
	Spec.near(z0, nb.bz, 1e-3)
	Spec.near(hz0, -1, 0.05)
	local x1, _, z1, hx1 = RoadNet.point(c, c.len)
	Spec.near(x1, eb.ax, 1e-3)
	Spec.near(z1, eb.az, 1e-3)
	Spec.near(hx1, 1, 0.05)
	-- midway the heading is between north and east
	local _, _, _, hxm, hzm = RoadNet.point(c, c.len / 2)
	Spec.truthy(hxm > 0.3 and hzm < -0.3, "diagonal at the middle")
	Spec.eq(RoadNet.connector(net, nb.id, eb.id), c, "cached")
	local left = RoadNet.connector(net, nb.id, laneFrom(net, "C", "W").id)
	Spec.truthy(left.len > c.len, "left turns are wider than right turns")
	Spec.truthy(hx0 == hx0)
end)

Spec.test("speed control: approach, follow gap, stop line", function()
	Spec.eq(Driver.approach(0, 30, 10, 20, 0.5), 5)
	Spec.eq(Driver.approach(30, 0, 10, 20, 0.5), 20)
	Spec.eq(Driver.approach(29, 30, 10, 20, 0.5), 30)
	Spec.eq(Driver.followSpeed(4, 30, CFG), 0, "inside min gap -> stop")
	Spec.near(Driver.followSpeed(14, 30, CFG), 10)
	Spec.eq(Driver.followSpeed(500, 30, CFG), 30, "capped at the limit")
	Spec.eq(Driver.stopSpeed(0, 30), 0)
	Spec.near(Driver.stopSpeed(15, 30), 30)
end)

Spec.test("traffic lights: normalise and decide", function()
	Spec.eq(Driver.light("Green"), "green")
	Spec.eq(Driver.light("AMBER"), "yellow")
	Spec.eq(Driver.light("Red"), "red")
	Spec.eq(Driver.light(false), "red")
	Spec.eq(Driver.light(nil), nil)
	Spec.eq(Driver.mustStopForLight("red", 10, 30, 34), true)
	Spec.eq(Driver.mustStopForLight("green", 10, 30, 34), false)
	Spec.eq(Driver.mustStopForLight("yellow", 40, 20, 34), true, "plenty of room: stop")
	Spec.eq(Driver.mustStopForLight("yellow", 3, 30, 34), false, "too close: run it")
	Spec.eq(Driver.mustStopForLight(nil, 3, 30, 34), false)
end)

Spec.test("leaders: same lane ahead and same direction only", function()
	-- me at origin heading -Z
	local fwd, right = Driver.relative(0, 0, 0, -1, 1, -20)
	Spec.near(fwd, 20)
	Spec.near(right, 1)
	Spec.near(Driver.leaderGap(fwd, right, 0, -1, 0, -1, 5, 5, CFG) :: number, 10)
	Spec.eq(Driver.leaderGap(fwd, right, 0, -1, 0, 1, 5, 5, CFG), nil, "oncoming")
	Spec.eq(Driver.leaderGap(fwd, right, 0, -1, 1, 0, 5, 5, CFG), nil, "crossing")
	Spec.eq(Driver.leaderGap(-10, 0, 0, -1, 0, -1, 5, 5, CFG), nil, "behind")
	Spec.eq(Driver.leaderGap(20, 8, 0, -1, 0, -1, 5, 5, CFG), nil, "next lane over")
	Spec.near(Driver.pedGap(12, 2, 5, CFG) :: number, 5.5)
	Spec.eq(Driver.pedGap(12, 9, 5, CFG), nil, "on the sidewalk")
end)

Spec.test("emergency yield: siren truck from behind within ~120 studs", function()
	Spec.eq(Driver.shouldYield(-60, 0, 20, true, CFG), true, "behind, closing")
	Spec.eq(Driver.shouldYield(-60, 0, 20, false, CFG), false, "no siren")
	Spec.eq(Driver.shouldYield(-130, 0, 30, true, CFG), false, "too far")
	Spec.eq(Driver.shouldYield(-80, 0, -30, true, CFG), false, "behind but driving away")
	Spec.eq(Driver.shouldYield(-10, 4, 0, true, CFG), true, "parked right behind us")
	Spec.eq(Driver.shouldYield(40, 0, 25, true, CFG), true, "oncoming close")
	Spec.eq(Driver.shouldYield(90, 0, 25, true, CFG), false, "oncoming but far")
	Spec.eq(Driver.shouldYield(40, 0, -25, true, CFG), false, "ahead, going away")
	Spec.eq(Driver.truckPassed(-5, 3, CFG), false)
	Spec.eq(Driver.truckPassed(25, 0, CFG), true)
	Spec.eq(Driver.truckPassed(-160, 0, CFG), true, "gone out of range")
end)

Spec.test("ram: truck front hit box grows with speed", function()
	Spec.eq(Driver.rammed(0, -15, 10, CFG), false, "too slow")
	Spec.eq(Driver.rammed(0, -15, 30, CFG), true)
	Spec.eq(Driver.rammed(0, 10, 30, CFG), false, "behind the truck")
	Spec.eq(Driver.rammed(12, -15, 30, CFG), false, "off to the side")
	Spec.eq(Driver.rammed(0, -30, 20, CFG), false, "slow: short reach")
	Spec.eq(Driver.rammed(0, -30, 60, CFG), true, "fast: long reach")
end)

Spec.test("panic wobble settles, weighted pick is total", function()
	local l0 = Driver.panicWobble(0.1, 3)
	local l1 = Driver.panicWobble(3.5, 3)
	Spec.truthy(math.abs(l0) > 0)
	Spec.near(l1, 0, 1e-6)
	local w = { sedan = 3, bus = 1 }
	Spec.eq(Driver.pickWeighted(w, 0), "bus")
	Spec.eq(Driver.pickWeighted(w, 0.99), "sedan")
	Spec.eq(Driver.pickWeighted({}, 0.5), nil)
end)

Spec.test("driving a 4x4 grid for a long time: continuous path, never stuck without a way on", function()
	local nodes, edges = {}, {}
	for i = 0, 3 do
		for j = 0, 3 do
			nodes[`{i}_{j}`] = { x = i * 200, y = 0, z = j * 200 }
			if i < 3 then
				table.insert(edges, { `{i}_{j}`, `{i + 1}_{j}` })
			end
			if j < 3 then
				table.insert(edges, { `{i}_{j}`, `{i}_{j + 1}` })
			end
		end
	end
	local net = RoadNet.parse({ nodes = nodes, edges = edges }, CFG) :: any
	Spec.eq(#net.lanes, 48)
	local laneId = 1
	local seg = RoadNet.laneSeg(net, laneId)
	local nextLane = RoadNet.pickNext(net, laneId, 0.3, 1.6)
	local s = 0
	local px, _, pz = RoadNet.point(seg, 0)
	local seed = 1
	local turns = 0
	for _ = 1, 5000 do
		s += 1.5 -- 30 studs/s at 20 Hz
		while s >= seg.len do
			s -= seg.len
			if seg.kind == "lane" then
				Spec.truthy(nextLane, "always somewhere to go")
				seg = RoadNet.connector(net, laneId, nextLane :: number)
				turns += 1
			else
				laneId = seg.to
				seg = RoadNet.laneSeg(net, laneId)
				seed = (seed * 1103515245 + 12345) % 2147483648
				nextLane = RoadNet.pickNext(net, laneId, seed / 2147483648, 1.6)
			end
		end
		local x, _, z = RoadNet.point(seg, s)
		local jump = math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
		Spec.truthy(jump < 2.5, `no teleport (jumped {jump})`)
		px, pz = x, z
	end
	Spec.truthy(turns > 20, "visited many junctions")
end)

return Spec.finish()
