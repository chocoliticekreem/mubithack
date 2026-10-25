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


Spec.test("low frame rates: dt clamp, servo gain and rate cap keep one frame from flipping the truck", function()
	Spec.eq(D.stepDt(1 / 60, 1 / 30), 1 / 60)
	Spec.eq(D.stepDt(0.5, 1 / 30), 1 / 30)
	Spec.eq(D.stepDt(-1, 1 / 30), 0)
	Spec.eq(D.servoGain(7, 1 / 60, 0.5), 7) -- 60 fps: unchanged
	Spec.near(D.servoGain(7, 0.5, 0.5), 1) -- 2 fps: closes half the error per frame, no overshoot
	Spec.eq(D.servoGain(7, 0, 0.5), 7)
	Spec.eq(D.capRate(3, 1 / 60, 0.12), 3) -- 60 fps: a 3 rad/s wheelie is untouched
	Spec.near(D.capRate(3, 0.5, 0.12), 0.24) -- 2 fps: at most 0.12 rad of pitch per frame
	Spec.near(D.capRate(-3, 0.5, 0.12), -0.24)
end)

Spec.test("anti-tunnel: lifted rays still see a road the chassis sank into; sink depth and speed caps", function()
	-- at rest: centre 2.6 above the road; the ray from 2 studs higher hits after 4.6
	Spec.near(D.cornerDist(4.6, 2), 2.6)
	Spec.truthy(D.sinkDepth(D.cornerDist(4.6, 2), 0.6) < 0) -- not sunk
	-- centre 0.3 BELOW the road top (an unlifted ray would start inside the road and miss it)
	Spec.near(D.cornerDist(1.7, 2), -0.3)
	Spec.near(D.sinkDepth(-0.3, 0.6), 0.9) -- bottom 0.9 under the surface: lift it out
	local x, y, z = D.capVelocity(10, -300, 0, 120, 150)
	Spec.eq(x, 10)
	Spec.eq(y, -120)
	Spec.eq(z, 0)
	x, y, z = D.capVelocity(300, 0, 0, 120, 150)
	Spec.near(x, 150)
	x, y, z = D.capVelocity(40, -5, 30, 120, 150)
	Spec.eq(x, 40)
	Spec.eq(y, -5)
	Spec.eq(z, 30)
end)


Spec.test("arcade throttle: analog target speed, brakes against motion, coasts to a stop", function()
	Spec.eq(D.arcadeDrive(1, 0, 70, 40, 90, 30), 40)
	Spec.eq(D.arcadeDrive(1, 70, 70, 40, 90, 30), 0)
	Spec.near(D.arcadeDrive(1, 66, 70, 40, 90, 30), 20) -- eases in near the cap
	Spec.eq(D.arcadeDrive(0.5, 35, 70, 40, 90, 30), 0) -- half stick holds half speed
	Spec.truthy(D.arcadeDrive(0.5, 60, 70, 40, 90, 30) < 0) -- eased off: slows to the new target
	Spec.eq(D.arcadeDrive(-1, 20, 70, 40, 90, 30), -90)
	Spec.eq(D.arcadeDrive(0, 20, 70, 40, 90, 30), -30)
	Spec.eq(D.arcadeDrive(0, -20, 70, 40, 90, 30), 30)
	Spec.eq(D.arcadeDrive(0, 0, 70, 40, 90, 30), 0)
	Spec.eq(D.arcadeDrive(-1, -35, 70, 40, 90, 30), 0) -- reverse cap is half
end)

Spec.test("arcade steering: no spin standing, tight slow, gentle fast, flips in reverse", function()
	Spec.eq(D.arcadeYaw(1, 0, 70, 16, 80, 1.5), 0)
	Spec.near(D.arcadeYaw(1, 8, 70, 16, 80, 1.5), -8 / (16 + 64 * (8 / 70) ^ 2))
	local fast = D.arcadeYaw(1, 70, 70, 16, 80, 1.5)
	Spec.near(fast, -70 / 80)
	-- turning radius (speed / yaw) grows with speed
	Spec.truthy(10 / math.abs(D.arcadeYaw(1, 10, 70, 16, 80, 1.5)) < 70 / math.abs(fast))
	Spec.truthy(math.abs(D.arcadeYaw(1, 40, 70, 4, 80, 1.5)) <= 1.5) -- capped
	Spec.truthy(D.arcadeYaw(1, -10, 70, 16, 80, 1.5) > 0)
end)

Spec.test("approach: rate-limited both ways", function()
	Spec.near(D.approach(0, 1, 0.1, 4, 8), 0.4)
	Spec.near(D.approach(1, 0, 0.1, 4, 8), 0.2)
	Spec.eq(D.approach(0.9, 1, 0.1, 4, 8), 1)
end)

Spec.test("touch stick: dead zone, expo, sideways push keeps driving, pull back brakes", function()
	local s, t = D.touchStick(0.1, 0.05, 0, 0.15, 1.5, 0.8)
	Spec.eq(s, 0)
	Spec.eq(t, 0)
	s, t = D.touchStick(1, 0, 20, 0.15, 1.5, 0.45)
	Spec.near(s, 1)
	Spec.near(t, 0.45) -- only steering: still rolling forward, at cornering speed
	s, t = D.touchStick(0, 0.575, 20, 0.15, 1.5, 0.45)
	Spec.near(t, 0.5) -- throttle is linear past the dead zone
	s, t = D.touchStick(0.5, 1, 20, 0.15, 1.5, 0.8)
	Spec.truthy(s > 0 and s < 0.5) -- expo: half push is gentler than half lock
	Spec.near(t, 1)
	s, t = D.touchStick(0.6, -1, 20, 0.15, 1.5, 0.8)
	Spec.near(t, -1) -- pulled back = brake / reverse, even while steering
end)

Spec.test("alignAngle: signed, either way along the road", function()
	Spec.near(D.alignAngle(0, -1, 0, -1), 0)
	Spec.near(D.alignAngle(0, -1, 0, 1), 0) -- road runs both ways
	Spec.truthy(D.alignAngle(0, -1, 0.2, -1) > 0) -- facing -Z, road bends toward +X = right
	Spec.truthy(D.alignAngle(0, -1, -0.2, -1) < 0)
end)

return Spec.finish()
