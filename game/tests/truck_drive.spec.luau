--!strict
-- TruckDrive: suspension, torque curve, brakes/reverse, speed-sensitive steering, tyres, gears.
local Spec = require("./Spec")
local D = require("../StarterPlayerScripts/ClientLib/TruckDrive")

Spec.test("spring pushes when compressed, never pulls, 0 in the air", function()
	Spec.eq(D.spring(nil, 4, 0, 100, 5), 0)
	Spec.eq(D.spring(5, 4, 0, 100, 5), 0)
	Spec.eq(D.spring(3, 4, 0, 100, 5), 100)
	Spec.eq(D.spring(3, 4, 100, 100, 5), 0) -- rushing down hard is damped, not negative
end)

local CFG = { MaxSpeed = 70, Accel = 40, Brake = 100, ReverseSpeed = 28, ReverseAccel = 30, RollDrag = 5, AeroDrag = 0.002 }

Spec.test("torque curve: strong launch, peak mid-range, fades to 0 at top speed", function()
	Spec.near(D.torqueCurve(0), 0.85)
	Spec.truthy(D.torqueCurve(0.3) > D.torqueCurve(0))
	Spec.truthy(D.torqueCurve(0.8) < D.torqueCurve(0.3))
	Spec.near(D.torqueCurve(1), 0)
	Spec.near(D.torqueCurve(2), 0)
end)

Spec.test("drive: throttle pulls, pressing against motion brakes, reverse works, coast drags", function()
	Spec.near(D.drive(1, 0, CFG), 40 * 0.85)
	Spec.near(D.drive(1, 70, CFG), 0)
	Spec.eq(D.drive(-1, 20, CFG), -100) -- S while rolling forward = brake
	Spec.eq(D.drive(1, -20, CFG), 100) -- W while rolling back = brake
	Spec.near(D.drive(-1, 0, CFG), -30 * 0.85) -- S from a stop = reverse
	Spec.near(D.drive(-1, -28, CFG), 0) -- reverse top speed
	Spec.near(D.drive(0, 10, CFG), -(5 + 0.2))
	Spec.near(D.drive(0, -10, CFG), 5 + 0.2)
	Spec.near(D.drive(0.5, 0, CFG), 20 * 0.85) -- analogue throttle scales
end)

Spec.test("steering: tight at a crawl, calm at speed, rate limited, snaps back", function()
	Spec.near(D.steerMax(0, 0.7, 0.13, 70), 0.7)
	Spec.near(D.steerMax(70, 0.7, 0.13, 70), 0.13)
	Spec.near(D.steerMax(-70, 0.7, 0.13, 70), 0.13)
	Spec.truthy(D.steerMax(20, 0.7, 0.13, 70) < 0.6)
	Spec.near(D.steerToward(0, 1, 0.1, 3, 6), 0.3)
	Spec.near(D.steerToward(0.5, 0, 0.05, 3, 6), 0.2) -- returns at the faster rate
	Spec.eq(D.steerToward(0.25, 0.3, 0.1, 3, 6), 0.3)
end)

Spec.test("counter-steer turns into the slide, only when rolling forward", function()
	Spec.near(D.counterSteer(0.2, 30, 1, 0.5), 0.2)
	Spec.near(D.counterSteer(-0.9, 30, 1, 0.5), -0.5)
	Spec.eq(D.counterSteer(0.3, 2, 1, 0.5), 0)
	Spec.eq(D.counterSteer(0.3, -20, 1, 0.5), 0)
end)

Spec.test("tyre: grips up to the peak slip, then slides at a fraction", function()
	Spec.near(D.tyreCurve(0.07, 0.14, 0.7), 0.5)
	Spec.near(D.tyreCurve(0.14, 0.14, 0.7), 1)
	Spec.near(D.tyreCurve(-1, 0.14, 0.7), 0.7)
	Spec.truthy(D.tyreCurve(0.2, 0.14, 0.7) < 1)
end)

Spec.test("axle impulse opposes the slide, never overshoots, capped by grip", function()
	-- gripping: cancels stiff * slide
	Spec.near(D.axleImpulse(1, 30, 1000, 1, 10, 1 / 60, 0.14, 0.7, 0.9), -9)
	Spec.near(D.axleImpulse(-1, 30, 1000, 1, 10, 1 / 60, 0.14, 0.7, 0.9), 9)
	-- big slide: capped by grip * load * dt * slide fraction
	Spec.near(D.axleImpulse(30, 30, 600, 1, 100, 1 / 60, 0.14, 0.7, 0.9), -600 / 60 * 0.7)
	Spec.eq(D.axleImpulse(5, 30, 0, 1, 10, 1 / 60, 0.14, 0.7, 0.9), 0) -- airborne
	Spec.eq(D.axleImpulse(0, 30, 100, 1, 10, 1 / 60, 0.14, 0.7, 0.9), 0)
end)

Spec.test("friction circle: braking/driving eats cornering grip", function()
	Spec.eq(D.frictionCircle(0, 100), 100)
	Spec.near(D.frictionCircle(60, 100), 80)
	Spec.truthy(D.frictionCircle(500, 100) > 0) -- never all of it
	Spec.eq(D.frictionCircle(10, 0), 0)
end)

Spec.test("virtual gears: rpm climbs and drops on each shift", function()
	local g1, r1 = D.gear(0, 70, { 0.25, 0.5, 1 })
	Spec.eq(g1, 1)
	Spec.near(r1, 0)
	local g2, r2 = D.gear(17.5, 70, { 0.25, 0.5, 1 })
	Spec.eq(g2, 1)
	Spec.near(r2, 1)
	local g3, r3 = D.gear(21, 70, { 0.25, 0.5, 1 })
	Spec.eq(g3, 2)
	Spec.truthy(r3 < 0.3)
	local g4 = D.gear(200, 70, { 0.25, 0.5, 1 })
	Spec.eq(g4, 3)
	Spec.truthy(D.enginePitch(1, 1) > D.enginePitch(0, 0))
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

Spec.test("chase FOV widens with speed and kicks on acceleration", function()
	Spec.eq(D.fov(0, 70, 72, 20), 72)
	Spec.eq(D.fov(140, 70, 72, 20), 92)
	Spec.truthy(D.fov(35, 70, 72, 20) < 82)
	Spec.near(D.fovKick(20, 40, 8), 4)
	Spec.eq(D.fovKick(-50, 40, 8), 0)
	Spec.eq(D.fovKick(400, 40, 8), 8)
end)

return Spec.finish()
