--!strict
-- HoseLine pure maths: segment caps, spawn layout, feet-on-hose distance, tangles, pressure,
-- kink timing, stretch (yank/snap) and trips.
local Spec = require("./Spec")
local HoseLine = require("../ServerScriptService/Lib/Tools/HoseLine") :: any

local cfg = {
	KinkLoss = 0.45,
	TangleLoss = 0.15,
	MinPressure = 0.1,
	SnapFactor = 1.9,
	SnapGap = 100,
	YankGap = 3.5,
	TripSpeed = 13,
	StandRadius = 1.4,
}

local function P(x: number, y: number, z: number)
	return { X = x, Y = y, Z = z }
end

Spec.test("segment count is capped", function()
	Spec.eq(HoseLine.segmentCount(60, 4, 4, 16), 15)
	Spec.eq(HoseLine.segmentCount(500, 4, 4, 16), 16, "max cap")
	Spec.eq(HoseLine.segmentCount(5, 4, 4, 16), 4, "min cap")
	Spec.eq(HoseLine.segmentCount(35, 4, 4, 16), 9)
end)

Spec.test("zigzag keeps every segment exactly segLen and ends at the target", function()
	for _, dist in { 0, 3, 20, 35, 80 } do
		local n, segLen = 9, 35 / 9
		local pts = HoseLine.zigzag(n, segLen, dist)
		Spec.eq(#pts, n + 1)
		for i = 1, n do
			local df, dl = pts[i + 1].f - pts[i].f, pts[i + 1].l - pts[i].l
			Spec.near(math.sqrt(df * df + dl * dl), segLen, 1e-6, `dist {dist} seg {i}`)
		end
		Spec.near(pts[n + 1].f, math.min(dist, 35), 1e-6, `end at {dist}`)
	end
end)

Spec.test("pointSegDist: perpendicular, clamped ends, degenerate", function()
	local d, t = HoseLine.pointSegDist(P(5, 1, 0), P(0, 0, 0), P(10, 0, 0))
	Spec.near(d, 1)
	Spec.near(t, 0.5)
	d, t = HoseLine.pointSegDist(P(-3, 0, 4), P(0, 0, 0), P(10, 0, 0))
	Spec.near(d, 5)
	Spec.near(t, 0)
	d = HoseLine.pointSegDist(P(0, 2, 0), P(1, 2, 0), P(1, 2, 0))
	Spec.near(d, 1)
end)

Spec.test("nearestSegment honours the first..last window (owner ignores own end)", function()
	local pts = { P(0, 0, 0), P(4, 0, 0), P(8, 0, 0), P(12, 0, 0) }
	local d, i = HoseLine.nearestSegment(P(10, 0.3, 0), pts, 1, 3)
	Spec.near(d, 0.3)
	Spec.eq(i, 3)
	d, i = HoseLine.nearestSegment(P(10, 0.3, 0), pts, 1, 1)
	Spec.near(d, 6 + 0.0075, 0.01)
	Spec.eq(i, 1)
	d, i = HoseLine.nearestSegment(P(10, 0, 0), pts, 1, 0)
	Spec.eq(d, math.huge, "empty window")
	Spec.eq(i, 0)
end)

Spec.test("crossXZ: an X crosses, parallel and apart don't, height gap reported", function()
	local crossed, dy = HoseLine.crossXZ(P(-1, 0, 0), P(1, 0, 0), P(0, 3, -1), P(0, 3, 1))
	Spec.truthy(crossed)
	Spec.near(dy, 3)
	crossed = HoseLine.crossXZ(P(0, 0, 0), P(1, 0, 0), P(0, 0, 1), P(1, 0, 1))
	Spec.eq(crossed, false, "parallel")
	crossed = HoseLine.crossXZ(P(0, 0, 0), P(1, 0, 0), P(5, 0, -1), P(5, 0, 1))
	Spec.eq(crossed, false, "apart")
end)

Spec.test("countCrossings: two lines wrapped round each other cross twice", function()
	local a = { P(0, 0, 0), P(10, 0, 0) }
	local b = { P(2, 0, -2), P(4, 0, 2), P(6, 0, -2) }
	Spec.eq(HoseLine.countCrossings(a, b, 2.5), 2)
	local high = { P(2, 9, -2), P(4, 9, 2), P(6, 9, -2) } -- a hose overhead isn't a tangle
	Spec.eq(HoseLine.countCrossings(a, high, 2.5), 0)
end)

Spec.test("pressure: full, kinked, tangled, floored", function()
	Spec.eq(HoseLine.pressureFor(0, 0, cfg), 1)
	Spec.near(HoseLine.pressureFor(1, 0, cfg), 0.55)
	Spec.near(HoseLine.pressureFor(0, 2, cfg), 0.7)
	Spec.eq(HoseLine.pressureFor(3, 5, cfg), 0.1, "floor")
end)

Spec.test("stepContact fires a kink exactly once when the delay is crossed", function()
	local t, started = 0, false
	local fired = 0
	for _ = 1, 10 do
		t, started = HoseLine.stepContact(t, true, 0.1, 0.35)
		if started then
			fired += 1
		end
	end
	Spec.eq(fired, 1)
	t, started = HoseLine.stepContact(t, false, 0.1, 0.35)
	Spec.eq(t, 0, "stepping off resets")
	Spec.eq(started, false)
end)

Spec.test("stretchState: slack, end of the line, wrapped taut, snapped", function()
	Spec.eq(HoseLine.stretchState(20, 35, 0, cfg), "none")
	Spec.eq(HoseLine.stretchState(36, 35, 0, cfg), "yank")
	Spec.eq(HoseLine.stretchState(10, 35, 5, cfg), "yank", "taut round a pole")
	Spec.eq(HoseLine.stretchState(80, 35, 0, cfg), "snap")
end)

Spec.test("stretchState: the hand far past the tip lets go of the line (never pulls you back)", function()
	-- regression: a RopeConstraint from the chain to the hand teleported/dragged the holder whenever
	-- the hand ended up past it (teleport, Truck reset!). Now that case is a snap, inside the hose length.
	Spec.eq(HoseLine.stretchState(150, 200, 160, cfg), "snap", "teleported 160 past the tip")
	Spec.truthy(HoseLine.stretchState(150, 200, 60, cfg) ~= "snap", "a lagging tip is fine")
	Spec.truthy(HoseLine.stretchState(150, 200, 160, { SnapFactor = 1.9, YankGap = 1e9 }) ~= "snap", "no SnapGap: off")
end)

Spec.test("canReach: never lay a line toward a hand the hose can't reach", function()
	local size = P(2, 2, 2)
	Spec.truthy(HoseLine.canReach(P(0, 0, 0), P(150, 0, 0), size, 200))
	Spec.truthy(HoseLine.canReach(P(0, 0, 0), P(200.5, 0, 0), size, 200), "box radius counts")
	Spec.eq(HoseLine.canReach(P(0, 0, 0), P(0, 0, 700), size, 200), false, "truck reset across the map")
end)

Spec.test("shouldTrip: running across trips, walking or far away doesn't", function()
	Spec.truthy(HoseLine.shouldTrip(16, 0.5, cfg))
	Spec.eq(HoseLine.shouldTrip(8, 0.5, cfg), false, "walking")
	Spec.eq(HoseLine.shouldTrip(20, 3, cfg), false, "not on the hose")
end)

Spec.test("truckDriving: only rolling = hoses come off, none go on", function()
	local c = { TruckMoveSpeed = 3 }
	Spec.eq(HoseLine.truckDriving(0, 0, c), false, "parked, nobody driving")
	Spec.eq(HoseLine.truckDriving(nil, 2.9, c), false, "nudged by a bump")
	Spec.truthy(HoseLine.truckDriving(0, 3.5, c), "rolling away with nobody in the seat")
	Spec.eq(HoseLine.truckDriving(12345, 0, c), false, "a driver sitting in a parked truck keeps teammates' hoses")
	Spec.truthy(HoseLine.truckDriving(12345, 5, c), "a driver pulling away")
	Spec.truthy(HoseLine.truckDriving(nil, 3.5, {}), "default 3 studs/s")
end)

return Spec.finish()
