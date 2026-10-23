--!strict
-- TruckDrive: suspension spring, throttle/brake, steering, grip.
local Spec = require("./Spec")
local D = require("../StarterPlayerScripts/ClientLib/TruckDrive")

Spec.test("spring pushes when compressed, never pulls, 0 in the air", function()
	Spec.eq(D.spring(nil, 4, 0, 100, 5), 0)
	Spec.eq(D.spring(5, 4, 0, 100, 5), 0)
	Spec.eq(D.spring(3, 4, 0, 100, 5), 100)
	Spec.eq(D.spring(3, 4, 100, 100, 5), 0) -- rushing down hard is damped, not negative
end)

Spec.test("drive accelerates up to the cap and brakes against motion", function()
	Spec.eq(D.drive(1, 0, 60, 30, 80), 30)
	Spec.eq(D.drive(1, 60, 60, 30, 80), 0)
	Spec.eq(D.drive(-1, 20, 60, 30, 80), -80)
	Spec.eq(D.drive(-1, -30, 60, 30, 80), 0) -- reverse cap is half
	Spec.near(D.drive(0, 10, 60, 30, 80), -6)
end)

Spec.test("steering is speed-scaled and flips in reverse", function()
	Spec.eq(D.steerRate(1, 0, 1.2, 60), 0)
	Spec.near(D.steerRate(1, 30, 1.2, 60), -1.2)
	Spec.near(D.steerRate(1, -30, 1.2, 60), 1.2)
end)

Spec.test("grip opposes sliding", function()
	Spec.eq(D.grip(10, 2), -20)
end)

Spec.test("body leans out of the turn, scaled by speed", function()
	Spec.eq(D.rollTarget(1, 0, 70, 0.2), 0)
	Spec.near(D.rollTarget(1, 70, 70, 0.2), -0.2)
	Spec.near(D.rollTarget(-1, 35, 70, 0.2), 0.1)
end)

Spec.test("wheelie only on the throttle press from low speed", function()
	Spec.near(D.wheelie(1, 0, 0, 70, 1.6), 1.6)
	Spec.eq(D.wheelie(1, 1, 0, 70, 1.6), 0) -- held, not pressed
	Spec.eq(D.wheelie(1, 0, 40, 70, 1.6), 0) -- already fast
	Spec.eq(D.wheelie(-1, 0, 0, 70, 1.6), 0)
end)

Spec.test("bumps kick the nose up above the threshold", function()
	Spec.eq(D.bump(5, 9, 0.05), 0)
	Spec.near(D.bump(29, 9, 0.05), 1)
end)

Spec.test("landing squash needs air time and impact speed, then the spring recovers", function()
	Spec.eq(D.squash(0.1, 80), 0)
	Spec.eq(D.squash(1, 5), 0)
	Spec.near(D.squash(1, 57), 1)
	Spec.near(D.squashSpring(0, 0.3, 0.5), 0.5)
	Spec.eq(D.squashSpring(0.3, 0.3, 0.5), 1)
	Spec.truthy(D.squashSpring(0.15, 0.3, 0.5) < 1)
end)

Spec.test("siren pitch climbs with speed and wails", function()
	Spec.near(D.sirenPitch(0, 70, 0, 0.5, 0.85, 0.35, 0.1), 0.85)
	Spec.near(D.sirenPitch(70, 70, 0, 0.5, 0.85, 0.35, 0.1), 1.2)
	Spec.near(D.sirenPitch(0, 70, 0.5, 0.5, 0.85, 0.35, 0.1), 0.95) -- quarter wail = peak
end)

Spec.test("chase FOV widens with speed", function()
	Spec.eq(D.fov(0, 70, 72, 20), 72)
	Spec.eq(D.fov(140, 70, 72, 20), 92)
	Spec.truthy(D.fov(35, 70, 72, 20) < 82)
end)

return Spec.finish()
