--!strict
-- SprayAssist: the phone first-fire rules (touch auto-aim lock, server bounds, stream arc, arrival kit).
local Spec = require("./Spec")
local A = require("../ReplicatedStorage/Lib/Fire/SprayAssist")

Spec.test("locks onto a fire 45 degrees off the camera's heading, 35 studs away (the old assist missed both)", function()
	local a = math.rad(45)
	local fires = { { math.sin(a) * 20, 0, -math.cos(a) * 20 } }
	Spec.eq(A.pick(fires, 0, 0, 0, 0, -1), 1) -- old: 40 degrees each side
	local c = math.rad(60)
	Spec.eq(A.pick({ { math.sin(c) * 20, 0, -math.cos(c) * 20 } }, 0, 0, 0, 0, -1), nil) -- past 50 each side
	local b = math.rad(38)
	fires = { { math.sin(b) * 35, 0, -math.cos(b) * 35 } } -- 35 studs: past the old 30-stud assist
	Spec.eq(A.pick(fires, 0, 0, 0, 0, -1), 1)
end)

Spec.test("prefers the centred fire, then the nearer one; ignores fires behind and out of range", function()
	local fires = {
		{ 0, 0, 30 }, -- behind
		{ 0, 0, -45 }, -- dead ahead but past LockRange 40
		{ 10, 0, -20 }, -- off to the side
		{ 1, 0, -25 }, -- nearly centred
	}
	Spec.eq(A.pick(fires, 0, 0, 0, 0, -1), 4)
	Spec.eq(A.pick({ { 0, 0, 30 } }, 0, 0, 0, 0, -1), nil)
	Spec.eq(A.pick(fires, 0, 0, 0, 0, 0), nil) -- no heading
end)

Spec.test("server bounds", function()
	Spec.eq(A.validLock(40, 10), true)
	Spec.eq(A.validLock(47.9, 49), true)
	Spec.eq(A.validLock(49, 0), false) -- past LockRange x 1.2
	Spec.eq(A.validLock(10, 60), false) -- the aim points somewhere else
	Spec.eq(A.validLock(0 / 0, 0), false)
end)

Spec.test("launch: the low arc lands on the target", function()
	local speed, g = 70, 55
	local ux, uy, uz = A.launch(30, -2, 0, speed, g)
	assert(ux and uy and uz)
	-- fly it: x(t) = ux*v*t, y(t) = uy*v*t - g t^2 / 2
	local t = 30 / ((ux :: number) * speed)
	local y = (uy :: number) * speed * t - g * t * t / 2
	Spec.near(y, -2, 0.05, "landed")
	Spec.eq(A.launch(500, 0, 0, 32, 30), nil) -- out of reach
	local sx, sy, sz = A.launch(0, -5, 0, 32, 30) -- straight down
	Spec.eq(sx, 0)
	Spec.eq(sy, -1)
	Spec.eq(sz, 0)
end)

Spec.test("arrival kit: SPRAY is always there", function()
	Spec.eq(A.ready("Hose", nil, nil, nil), "keep")
	Spec.eq(A.ready("Extinguisher", 12, "OxygenTank", nil), "keep")
	Spec.eq(A.ready("Axe", nil, "Extinguisher", 20), "keep") -- CHOP is a choice
	Spec.eq(A.ready("OxygenTank", nil, "Extinguisher", 20), "swap")
	Spec.eq(A.ready("", nil, "Hose", nil), "swap")
	Spec.eq(A.ready("Extinguisher", 0, "OxygenTank", nil), "refill")
	Spec.eq(A.ready("", nil, "", nil), "give")
	Spec.eq(A.ready(nil, nil, "OxygenTank", nil), "give")
	Spec.eq(A.ready("OxygenTank", nil, nil, nil), "give") -- the tank goes on the free back
	Spec.eq(A.ready("OxygenTank", nil, "Axe", nil), "none") -- would drop something
	Spec.eq(A.ready("Extinguisher", 0, "Extinguisher", 0), "refill")
end)

Spec.test("lock buckets", function()
	Spec.eq(A.lockBucket(0), "lock0")
	Spec.eq(A.lockBucket(3), "lock1-3")
	Spec.eq(A.lockBucket(9), "lock4+")
end)

return Spec.finish()
