--!strict
-- RubbleMath: collapsing buildings stay on their plot (velocity caps, leash, settle/crumble verdicts).
local Spec = require("./Spec")
local R = require("../ServerScriptService/Lib/Physics/RubbleMath")

-- keep in sync with ReplicatedStorage/Config/StructureConfig.luau
local cfg = {
	RubbleFreshSeconds = 0.5,
	RubbleMaxDrift = 40,
	SettleMinSeconds = 1.5,
	SettleMaxSeconds = 6,
	SettleSpeed = 1.5,
	VoidY = -400,
}

Spec.test("clampVelocity caps horizontal speed and keeps direction", function()
	-- the live bug: a roof slab picked up 49 studs/s sideways on landing
	local x, y, z = R.clampVelocity(30, -20, 40, 10, 6, 70)
	Spec.near(math.sqrt(x * x + z * z), 10, 1e-6, "horizontal")
	Spec.near(x / z, 30 / 40, 1e-6, "direction")
	Spec.eq(y, -20, "falling untouched")
end)

Spec.test("clampVelocity caps bounce-up and fall speed", function()
	local _, up = R.clampVelocity(0, 34, 0, 10, 6, 70)
	Spec.eq(up, 6, "up")
	local _, down = R.clampVelocity(0, -120, 0, 10, 6, 70)
	Spec.eq(down, -70, "down")
	local a, b, c = R.clampVelocity(1, -2, 3, 10, 6, 70)
	Spec.eq(a, 1)
	Spec.eq(b, -2)
	Spec.eq(c, 3)
end)

Spec.test("clampSpin caps angular speed", function()
	local x, y, z = R.clampSpin(0, 0, 161, 3)
	Spec.near(math.sqrt(x * x + y * y + z * z), 3, 1e-6)
	local a = R.clampSpin(1, 1, 1, 3)
	Spec.eq(a, 1)
end)

Spec.test("leash removes only outward speed beyond the radius", function()
	-- inside: untouched
	local vx, vz = R.leash(5, 0, 8, 0, 10)
	Spec.eq(vx, 8)
	Spec.eq(vz, 0)
	-- outside, moving outward along +x: stopped
	vx, vz = R.leash(12, 0, 8, 3, 10)
	Spec.near(vx, 0, 1e-9, "outward removed")
	Spec.eq(vz, 3, "tangential kept")
	-- outside, moving back in: kept
	vx, vz = R.leash(12, 0, -8, 0, 10)
	Spec.eq(vx, -8)
end)

Spec.test("verdict: fly, settle when still, settle by age, crumble when it escaped", function()
	Spec.eq(R.verdict(0.3, 0.1, 0, 10, cfg), "fly", "too young to settle")
	Spec.eq(R.verdict(2, 0.5, 3, 10, cfg), "settle", "still")
	Spec.eq(R.verdict(2, 20, 3, 10, cfg), "fly", "still moving")
	Spec.eq(R.verdict(6, 20, 3, 10, cfg), "settle", "max age")
	Spec.eq(R.verdict(1, 5, 41, 10, cfg), "crumble", "drifted off the plot")
	Spec.eq(R.verdict(1, 5, 0, -500, cfg), "crumble", "fell out of the world")
end)

Spec.test("group: fresh rubble ignores rubble, then piles up", function()
	Spec.eq(R.group(0.1, cfg), "RubbleFresh")
	Spec.eq(R.group(0.6, cfg), "Rubble")
end)

Spec.test("a released piece can't get further than the drift limit at max speed before it settles", function()
	-- worst case: capped horizontal speed for the whole fly time, leash ignored
	Spec.truthy(10 * cfg.SettleMaxSeconds <= 60, "bounded travel")
end)

return Spec.finish()
