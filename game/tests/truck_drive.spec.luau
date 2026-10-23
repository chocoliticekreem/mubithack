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

return Spec.finish()
