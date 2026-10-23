--!strict
-- ToolMath: hose cone, pressure, recoil, push, arcs, wet-floor slide, door hits, puddles, shake.
local Spec = require("./Spec")
local M = require("../ReplicatedStorage/ToolMath")

Spec.test("inCone: straight ahead in range", function()
	Spec.eq(M.inCone(0, 0, -10, 0, 0, -1, 20, 0.9), true)
end)

Spec.test("inCone: out of range", function()
	Spec.eq(M.inCone(0, 0, -25, 0, 0, -1, 20, 0.9), false)
end)

Spec.test("inCone: behind the sprayer", function()
	Spec.eq(M.inCone(0, 0, 10, 0, 0, -1, 20, 0.9), false)
end)

Spec.test("inCone: just outside a 25 degree cone", function()
	-- 30 degrees off axis
	Spec.eq(M.inCone(math.sin(math.rad(30)) * 10, 0, -math.cos(math.rad(30)) * 10, 0, 0, -1, 20, 0.9), false)
	Spec.eq(M.inCone(math.sin(math.rad(20)) * 10, 0, -math.cos(math.rad(20)) * 10, 0, 0, -1, 20, 0.9), true)
end)

Spec.test("inCone: zero aim never hits", function()
	Spec.eq(M.inCone(0, 0, -5, 0, 0, 0, 20, 0.9), false)
end)

Spec.test("pressure: full tank is 1, empty is 0, low sputters", function()
	Spec.near(M.pressure(100, 100), 1)
	Spec.eq(M.pressure(0, 100), 0)
	Spec.near(M.pressure(10, 100), 0.595)
end)

Spec.test("pressure: a kinked hose line scales the tank pressure, clamped", function()
	Spec.near(M.pressure(100, 100, 0.8), 0.8)
	Spec.near(M.pressure(10, 100, 0.5), 0.2975)
	Spec.near(M.pressure(100, 100, 3), 1)
	Spec.near(M.pressure(100, 100, -1), 0)
	Spec.eq(M.pressure(0, 100, 1), 0)
end)

Spec.test("recoil scales with pressure and crouching", function()
	Spec.near(M.recoilSpeed(9, 1, false), 9)
	Spec.near(M.recoilSpeed(9, 0.5, false), 4.5)
	Spec.near(M.recoilSpeed(9, 1, true), 3)
end)

Spec.test("push is horizontal along the aim plus lift", function()
	local x, y, z = M.push(0, -2, 30, 6)
	Spec.near(x, 0)
	Spec.near(y, 6)
	Spec.near(z, -30)
	local x2, y2, z2 = M.push(0, 0, 30, 6) -- straight down: only lift
	Spec.near(x2, 0)
	Spec.near(y2, 6)
	Spec.near(z2, 0)
end)

Spec.test("clampMagnitude caps long vectors only", function()
	local x, y, z = M.clampMagnitude(300, 0, 400, 100)
	Spec.near(x, 60)
	Spec.near(y, 0)
	Spec.near(z, 80)
	local a, b, c = M.clampMagnitude(3, 4, 0, 100)
	Spec.near(a, 3)
	Spec.near(b, 4)
	Spec.near(c, 0)
end)

Spec.test("arcPoint falls with gravity", function()
	local x, y, z = M.arcPoint(0, 10, 0, 10, 0, 0, 50, 1)
	Spec.near(x, 10)
	Spec.near(y, -15)
	Spec.near(z, 0)
end)

Spec.test("arcBezier endpoints and tangents match the arc", function()
	local c = M.arcBezier(0, 0, 0, 30, 20, 0, 40, 1)
	local x3, y3 = M.arcPoint(0, 0, 0, 30, 20, 0, 40, 1)
	Spec.near(c[3][1], x3)
	Spec.near(c[3][2], y3)
	-- p1 lies along the launch velocity
	Spec.near(c[1][1], 10)
	Spec.near(c[1][2], 20 / 3)
	-- p2 lies back along the landing velocity (vy(T) = 20 - 40 = -20)
	Spec.near(c[2][1], x3 - 10)
	Spec.near(c[2][2], y3 + 20 / 3)
	-- midpoint of the Bezier equals the arc at T/2
	local function bez(i: number, t: number): number
		local p0 = 0
		local u = 1 - t
		return u * u * u * p0 + 3 * u * u * t * c[1][i] + 3 * u * t * t * c[2][i] + t * t * t * c[3][i]
	end
	local mx, my = M.arcPoint(0, 0, 0, 30, 20, 0, 40, 0.5)
	Spec.near(bez(1, 0.5), mx, 1e-6)
	Spec.near(bez(2, 0.5), my, 1e-6)
end)

Spec.test("slide keeps most momentum on a wet floor", function()
	local x, z = M.slide(20, 0, 0, 0, 1.5, 1 / 60)
	Spec.truthy(x > 19 and x < 20, "keeps speed")
	Spec.near(z, 0)
	local x2 = M.slide(20, 0, 0, 0, 1000, 1 / 60) -- infinite grip snaps
	Spec.near(x2, 0)
end)

Spec.test("doorHit breaks on the third hit and resets", function()
	local h, broke = M.doorHit(0, 3)
	Spec.eq(h, 1)
	Spec.eq(broke, false)
	h, broke = M.doorHit(h, 3)
	Spec.eq(broke, false)
	h, broke = M.doorHit(h, 3)
	Spec.eq(broke, true)
	Spec.eq(h, 0)
end)

Spec.test("puddleRadius grows and clamps", function()
	Spec.near(M.puddleRadius(0, 1.5, 4), 1.5)
	Spec.truthy(M.puddleRadius(4, 1.5, 4) > 1.5)
	Spec.near(M.puddleRadius(1000, 1.5, 4), 4)
end)

Spec.test("shake scales with pressure and clamps", function()
	Spec.near(M.shake(1, 0.1, 0.3), 0.4)
	Spec.near(M.shake(0, 0.1, 0.3), 0.1)
	Spec.near(M.shake(1, 0.9, 0.9), 1)
end)

Spec.test("clamp01 handles NaN", function()
	Spec.eq(M.clamp01(0 / 0), 0)
end)

return Spec.finish()
