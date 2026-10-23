--!strict
-- AxeMath: swing state machine, grip poses, two-bone arm IK, arm packets, server box check.
local Spec = require("./Spec")
local A = require("../ReplicatedStorage/AxeMath")

local CFG = { WindupSeconds = 0.5, StrikeSeconds = 0.3, RecoverSeconds = 0.3, MinCharge = 0.35 }
local POSES = {
	Ready = { x = 1, y = -1, z = -2, rx = -30, ry = 0, rz = 15 },
	Windup = { x = 1.2, y = 0, z = -0.8, rx = 60, ry = 0, rz = 10 },
	Strike = { x = 0.4, y = -1.4, z = -2.4, rx = -100, ry = 0, rz = 0 },
}

local function dist(a: A.Vec, b: A.Vec): number
	return A.len({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z })
end

Spec.test("hold winds up, release chops, then recovers to ready", function()
	local s = A.newSwing()
	Spec.eq(A.step(s, 0, CFG), "ready")
	Spec.truthy(A.press(s, 10, CFG))
	Spec.eq(A.step(s, 0.1, CFG), "windup")
	local mid = A.pose(s, 10.5, POSES, CFG)
	Spec.near(mid.rx, POSES.Windup.rx, 1e-6, "full charge = wind-up pose")
	local from = A.release(s, 10.5, CFG)
	Spec.near(from :: number, 1, 1e-6)
	Spec.eq(A.step(s, 0.1, CFG), "strike")
	Spec.eq(A.step(s, 0.25, CFG), "recover")
	Spec.eq(A.step(s, 0.3, CFG), "ready")
	Spec.eq(s.strikeT, -1)
end)

Spec.test("a tap still chops with the minimum charge; release without press does nothing", function()
	local s = A.newSwing()
	Spec.eq(A.release(s, 1, CFG), nil)
	A.press(s, 1, CFG)
	Spec.near(A.release(s, 1.01, CFG) :: number, CFG.MinCharge, 1e-6)
end)

Spec.test("can't re-wind mid-chop, can during recovery", function()
	local s = A.newSwing()
	A.press(s, 0, CFG)
	A.release(s, 0.5, CFG)
	A.step(s, 0.1, CFG)
	Spec.eq(A.press(s, 0.6, CFG), false)
	A.step(s, 0.25, CFG)
	Spec.eq(A.press(s, 0.85, CFG), true)
end)

Spec.test("strike overshoots past the strike pose then returns", function()
	local s = A.newSwing()
	A.press(s, 0, CFG)
	A.release(s, 0.5, CFG)
	local lowest = 0
	for _ = 1, 18 do
		A.step(s, 1 / 60, CFG)
		local p = A.pose(s, 0, POSES, CFG)
		lowest = math.min(lowest, p.rx)
	end
	Spec.truthy(lowest < POSES.Strike.rx, "overshoot")
	for _ = 1, 40 do
		A.step(s, 1 / 60, CFG)
	end
	Spec.near(A.pose(s, 0, POSES, CFG).rx, POSES.Ready.rx, 1e-6)
end)

Spec.test("IK keeps both bone lengths and bends toward the pole", function()
	local s = { x = 1, y = 0, z = 0 }
	local w = { x = 1.2, y = -1.2, z = -1.4 }
	local e, w2 = A.solveElbow(s, w, 1.1, 1.2, { x = 0.5, y = -1, z = 0.4 })
	Spec.near(dist(s, e), 1.1, 1e-6, "upper")
	Spec.near(dist(e, w2), 1.2, 1e-6, "lower")
	Spec.near(dist(w, w2), 0, 1e-6, "reachable target is hit")
	Spec.truthy(e.y < -0.3, "elbow drops toward the pole")
end)

Spec.test("IK clamps an out-of-reach target and survives degenerate input", function()
	local s = { x = 0, y = 0, z = 0 }
	local e, w = A.solveElbow(s, { x = 0, y = 0, z = -10 }, 1, 1, { x = 0, y = -1, z = 0 })
	Spec.truthy(dist(s, w) <= 2 and dist(s, w) > 1.99)
	Spec.near(dist(e, w), 1, 1e-6)
	local e2, w3 = A.solveElbow(s, s, 1, 1.2, { x = 0, y = -1, z = 0 })
	Spec.truthy(e2.x == e2.x and w3.y == w3.y, "no NaN")
	Spec.near(dist(e2, w3), 1.2, 1e-6)
	local e3 = A.solveElbow(s, { x = 0, y = -1.5, z = 0 }, 1, 1, { x = 0, y = -1, z = 0 })
	Spec.truthy(e3.x == e3.x, "pole parallel to the arm still bends")
end)

Spec.test("arm packets round-trip, quantize and reject junk", function()
	local raw = A.encode({ x = 1.234, y = -9, z = -2, rx = -400, ry = 12.4, rz = 3 }, 100, 3)
	Spec.eq(#raw, A.PacketSize)
	local p, pitch, flags = A.decode(raw)
	Spec.truthy(p ~= nil)
	local pose = p :: A.Pose
	Spec.near(pose.x, 1.24, 1e-9)
	Spec.eq(pose.y, -A.MaxPos)
	Spec.eq(pose.rx, -180)
	Spec.eq(pose.ry, 12)
	Spec.eq(pitch, 80)
	Spec.eq(flags, 3)
	Spec.eq((A.decode({ 1, 2, 3 })), nil)
	Spec.eq((A.decode({ 0, 0, 0, 0, 0, 0, 0 / 0, 0 })), nil)
	Spec.eq((A.decode("x")), nil)
end)

Spec.test("angleDelta wraps; nearBox measures distance to a box", function()
	Spec.eq(A.angleDelta(170, -170), 20)
	Spec.eq(A.angleDelta(-170, 170), -20)
	local half = { x = 2, y = 4, z = 0.25 }
	Spec.truthy(A.nearBox({ x = 0, y = 0, z = 2 }, half, 2))
	Spec.eq(A.nearBox({ x = 0, y = 0, z = 3 }, half, 2), false)
end)

Spec.test("run bob is zero standing and bounded running", function()
	local x, y = A.runBob(1.3, 0, 0.1)
	Spec.eq(x, 0)
	Spec.eq(y, 0)
	local _, y2 = A.runBob(math.pi / 2, 1, 0.1)
	Spec.near(y2, -0.1, 1e-9)
end)

return Spec.finish()
