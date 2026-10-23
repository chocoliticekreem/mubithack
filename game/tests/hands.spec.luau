--!strict
-- HandsMath: pose springs, poses, axe swing timing, slap/push, grab limits, pose packets.
local Spec = require("./Spec")
local H = require("../ReplicatedStorage/HandsMath")

local AXE = { AxeMinSpeed = 22, AxeStrongSpeed = 38, AxeCritSpeed = 55 }
local SLAP = { SlapMinSpeed = 18, SlapPerSpeed = 1.1, SlapMax = 55, SlapLift = 14, SlapRagdollSpeed = 45 }
local GRAB = { OneHandMaxMass = 25, TwoHandMaxMass = 120 }

local function run(hz: number, zeta: number, seconds: number): (number, number, number)
	local k, c = H.springCoeffs(hz, zeta)
	local x, v, peak = 0, 0, 0
	local t = 0
	while t < seconds do
		x, v = H.springStep(x, v, 1, k, c, 1 / 60)
		peak = math.max(peak, x)
		t += 1 / 60
	end
	return x, v, peak
end

Spec.test("spring settles on the target", function()
	local x, v = run(4.5, 0.42, 3)
	Spec.near(x, 1, 1e-3)
	Spec.near(v, 0, 1e-2)
end)

Spec.test("underdamped spring overshoots (the wobble), critical one doesn't", function()
	local _, _, wobbly = run(4.5, 0.42, 2)
	Spec.truthy(wobbly > 1.15, "underdamped overshoot")
	local _, _, critical = run(4.5, 1, 2)
	Spec.truthy(critical <= 1 + 1e-6, "critical never overshoots")
end)

Spec.test("spring lags behind a moving target", function()
	local k, c = H.springCoeffs(4.5, 0.42)
	local x = H.springStep(0, 0, 1, k, c, 1 / 60)
	Spec.truthy(x > 0 and x < 0.2, "one frame only moves a little")
end)

Spec.test("spring is stable at huge frame times and zero dt is a no-op", function()
	local k, c = H.springCoeffs(9, 0.55)
	local x, v = H.springStep(0, 0, 1, k, c, 0.5)
	Spec.truthy(math.abs(x - 1) < 0.5 and v == v, "sub-stepped, no blow-up")
	local x2, v2 = H.springStep(0.3, 2, 1, k, c, 0)
	Spec.eq(x2, 0.3)
	Spec.eq(v2, 2)
end)

Spec.test("springStep3 moves each axis independently", function()
	local k, c = H.springCoeffs(5, 1)
	local p, v = H.springStep3({ x = 0, y = 0, z = 0 }, { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = -1 }, k, c, 1)
	Spec.near(p.x, 1, 0.05)
	Spec.near(p.y, 0, 1e-9)
	Spec.near(p.z, -1, 0.05)
	Spec.truthy(v.y == 0)
end)

Spec.test("left poses mirror the right ones", function()
	local r = H.pose("idle", "R")
	local l = H.pose("idle", "L")
	Spec.eq(l.x, -r.x)
	Spec.eq(l.y, r.y)
	Spec.eq(l.ry, -r.ry)
	Spec.eq(l.rz, -r.rz)
	Spec.eq(H.pose("nope", "R"), H.Poses.idle)
end)

Spec.test("idle gloves sit low in the corners, not over the crosshair", function()
	local p = H.Poses.idle
	-- at FOV 80 the half-height at depth z is |z| * tan(40deg); gloves start below 55% of it
	local half = math.abs(p.z) * math.tan(math.rad(40))
	Spec.truthy(p.y < -0.55 * half, "low")
	Spec.truthy(math.abs(p.x) > 0.8, "out to the side")
end)

Spec.test("blendPose hits both ends", function()
	local a, b = H.Poses.axeReady, H.Poses.axeWindup
	Spec.eq(H.blendPose(a, b, 0).rx, a.rx)
	Spec.eq(H.blendPose(a, b, 1).rx, b.rx)
	Spec.near(H.blendPose(a, b, 0.5).y, (a.y + b.y) / 2)
end)

Spec.test("reach distance stops short of walls and is capped", function()
	Spec.eq(H.reachDistance(nil, 6, 0.4), 6)
	Spec.near(H.reachDistance(3, 6, 0.4), 2.6)
	Spec.eq(H.reachDistance(100, 6, 0.4), 6)
	Spec.eq(H.reachDistance(0.1, 6, 0.4), 0.8)
end)

Spec.test("reach pose goes from rest to the point", function()
	local rest = H.Poses.idle
	local pt = { x = 0.2, y = -0.3, z = -5 }
	local p0 = H.reachPose(rest, pt, 0)
	local p1 = H.reachPose(rest, pt, 1)
	Spec.eq(p0.z, rest.z)
	Spec.eq(p1.z, -5)
	Spec.eq(p1.ry, 0)
end)

Spec.test("wind-up charge eases in and saturates", function()
	Spec.eq(H.windupCharge(0, 0.6), 0)
	Spec.truthy(H.windupCharge(0.3, 0.6) > 0.5, "half the time is more than half the charge")
	Spec.eq(H.windupCharge(5, 0.6), 1)
	Spec.eq(H.windupCharge(1, 0), 1)
end)

Spec.test("axe pose: windup, strike overshoot, recover", function()
	local ready = H.axePose(0, nil, 0.22)
	Spec.eq(ready.rx, H.Poses.axeReady.rx)
	local wound = H.axePose(1, nil, 0.22)
	Spec.eq(wound.rx, H.Poses.axeWindup.rx)
	-- mid-strike the easeOutBack carries past the strike pose
	local over = H.axePose(1, 0.18, 0.22, 1)
	Spec.truthy(over.rx > H.Poses.axeStrike.rx, "overshoots the strike pitch")
	local done = H.axePose(0, 0.22 * 3 + 0.01, 0.22, 1)
	Spec.near(done.rx, H.Poses.axeReady.rx, 1e-6)
end)

Spec.test("axe damage needs swing speed", function()
	Spec.eq(H.axeHits(5, AXE), 0)
	Spec.eq(H.axeHits(25, AXE), 1)
	Spec.eq(H.axeHits(40, AXE), 2)
	Spec.eq(H.axeHits(80, AXE), 3)
	Spec.eq(H.axeHits(0 / 0, AXE), 0)
end)

Spec.test("slap: pat below min, capped knockback, ragdoll when huge", function()
	local p, l, r = H.slap(10, SLAP)
	Spec.eq(p, 0)
	Spec.eq(l, 0)
	Spec.eq(r, false)
	local p2, l2, r2 = H.slap(25, SLAP)
	Spec.truthy(p2 > 0 and p2 < SLAP.SlapMax and l2 > 0 and not r2)
	local p3, _, r3 = H.slap(500, SLAP)
	Spec.eq(p3, SLAP.SlapMax)
	Spec.eq(r3, true)
end)

Spec.test("push scales with hand speed", function()
	Spec.eq(H.push(4, 8, 0.6, 30), 0)
	Spec.near(H.push(20, 8, 0.6, 30), 12)
	Spec.eq(H.push(200, 8, 0.6, 30), 30)
end)

Spec.test("grab verdicts: light ok, heavy needs two hands, huge never", function()
	Spec.eq(H.grabVerdict(5, 1, GRAB), "ok")
	Spec.eq(H.grabVerdict(60, 1, GRAB), "heavy")
	Spec.eq(H.grabVerdict(60, 2, GRAB), "ok")
	Spec.eq(H.grabVerdict(500, 2, GRAB), "no")
	Spec.eq(H.grabVerdict(0 / 0, 1, GRAB), "no")
end)

Spec.test("lift force: two hands share, one hand can't lift heavy", function()
	local g = 196.2
	local one = H.liftForce(10, 1, g, GRAB)
	Spec.truthy(one > 10 * g, "light thing lifts with margin")
	local heavyOne = H.liftForce(60, 1, g, GRAB)
	Spec.truthy(heavyOne < 60 * g, "one hand can't hold up a heavy thing")
	local heavyTwo = H.liftForce(60, 2, g, GRAB)
	Spec.truthy(heavyTwo * 2 > 60 * g, "two hands can")
	Spec.eq(H.liftForce(999, 2, g, GRAB), 0)
end)

Spec.test("hose kick pushes back and up, scales with pressure", function()
	local x0, y0, z0, p0 = H.hoseKick(1.3, 0, 1)
	Spec.eq(x0, 0)
	Spec.eq(y0 + z0 + p0, 0)
	for _, t in { 0.1, 0.7, 2.2, 3.9 } do
		local _, y, z, pitch = H.hoseKick(t, 1, 1)
		Spec.truthy(y >= 0 and z >= 0 and pitch >= 0, "never pulls forward")
	end
end)

Spec.test("extinguisher sputters more when nearly empty", function()
	local fullOn, lowOn = 0, 0
	for i = 1, 600 do
		local t = i / 60
		if H.sputter(t, 1) > 0 then
			fullOn += 1
		end
		if H.sputter(t, 0.05) > 0 then
			lowOn += 1
		end
	end
	Spec.truthy(fullOn > lowOn, "a full can sprays more of the time")
	Spec.truthy(lowOn > 0, "an empty-ish can still coughs")
end)

Spec.test("pose packets round-trip, quantize and clamp", function()
	local pkt = H.encodePose({ x = -1.234, y = 0.5, z = -2 }, { x = 99, y = -0.01, z = 0.026 }, 2 + 8, 7)
	Spec.eq(#pkt, H.PacketSize)
	local l, r, flags = H.decodePose(pkt, 7)
	Spec.truthy(l and r)
	Spec.near((l :: any).x, -1.25, 1e-9)
	Spec.eq((r :: any).x, 7)
	Spec.near((r :: any).z, 0.05, 1e-9)
	Spec.truthy(H.hasFlag(flags, H.Flag.RightGrip))
	Spec.truthy(H.hasFlag(flags, H.Flag.Reach))
	Spec.truthy(not H.hasFlag(flags, H.Flag.LeftGrip))
end)

Spec.test("decodePose rejects junk", function()
	Spec.eq((H.decodePose(nil, 7)), nil)
	Spec.eq((H.decodePose({ 1, 2, 3 }, 7)), nil)
	Spec.eq((H.decodePose({ 1, 2, 3, 4, 5, 0 / 0, 0 }, 7)), nil)
	Spec.eq((H.decodePose({ 1, 2, 3, 4, 5, "6", 0 }, 7)), nil)
	Spec.eq((H.decodePose({ 1, 2, 3, 4, 5, math.huge, 0 }, 7)), nil)
	local _, _, f = H.decodePose({ 0, 0, 0, 0, 0, 0, 9999 }, 7)
	Spec.eq(f, 255)
end)

Spec.test("rotationBetween: perpendicular, same and opposite", function()
	local axis, ang = H.rotationBetween({ x = 0, y = -1, z = 0 }, { x = 0, y = 0, z = -1 })
	Spec.near(ang, math.pi / 2, 1e-9)
	Spec.near(math.abs(axis.x), 1, 1e-9)
	local _, same = H.rotationBetween({ x = 1, y = 0, z = 0 }, { x = 3, y = 0, z = 0 })
	Spec.eq(same, 0)
	local oaxis, opp = H.rotationBetween({ x = 1, y = 0, z = 0 }, { x = -1, y = 0, z = 0 })
	Spec.near(opp, math.pi, 1e-9)
	Spec.near(oaxis.x, 0, 1e-9) -- perpendicular to the input
end)

Spec.test("snap when stuck far away for long enough", function()
	Spec.eq(H.shouldSnap(2, 10, 4.5, 0.35), false)
	Spec.eq(H.shouldSnap(5, 0.1, 4.5, 0.35), false)
	Spec.eq(H.shouldSnap(5, 0.4, 4.5, 0.35), true)
	Spec.eq(H.shouldSnap(20, 0, 4.5, 0.35), true)
end)

return Spec.finish()
