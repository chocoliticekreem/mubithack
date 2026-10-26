--!strict
-- DriveMath: telemetry buckets, ETA / progress, the straight-road check, practice-fire spacing.
-- Driver.slowBehind: traffic pulls over for a driven siren truck crawling right behind it.
local Spec = require("./Spec")
local DriveMath = require("../ReplicatedStorage/Lib/Vehicle/DriveMath")
local Driver = require("../ServerScriptService/Lib/Traffic/Driver")

Spec.test("metres use the GPS's 3.5 studs per metre", function()
	Spec.eq(DriveMath.metres(0), 0)
	Spec.eq(DriveMath.metres(35), 10)
	Spec.eq(DriveMath.metres(249), 71)
	Spec.eq(DriveMath.metres(-10), 0)
end)

Spec.test("buckets are a small constant set", function()
	Spec.eq(DriveMath.secondsBucket(3), "0-15")
	Spec.eq(DriveMath.secondsBucket(15), "15-30")
	Spec.eq(DriveMath.secondsBucket(59.9), "30-60")
	Spec.eq(DriveMath.secondsBucket(90), "60-120")
	Spec.eq(DriveMath.secondsBucket(400), "120+")
	Spec.eq(DriveMath.countBucket(0), "0")
	Spec.eq(DriveMath.countBucket(1), "1")
	Spec.eq(DriveMath.countBucket(7), "2+")
	Spec.eq(DriveMath.wrongBucket(0.4), "0")
	Spec.eq(DriveMath.wrongBucket(4), "1-10")
	Spec.eq(DriveMath.wrongBucket(12), "10+")
end)

Spec.test("quit field packs reason, time, resets, stuck and wrong-way time", function()
	Spec.eq(DriveMath.quitField("left", 42, 1, 0, 12), "left|t30-60|r1|s0|w10+")
	Spec.eq(DriveMath.quitField("cancel", 5, 0, 3, 0), "cancel|t0-15|r0|s2+|w0")
	Spec.eq(DriveMath.quitField("anything else", 5, 0, 0, 0), "left|t0-15|r0|s0|w0")
	-- AnalyticsService custom field values stay short
	Spec.eq(#DriveMath.quitField("cancel", 999, 9, 9, 99) <= 32, true)
end)

Spec.test("stuck cause", function()
	Spec.eq(DriveMath.stuckCause(false, 0, 0, false), "nodriver")
	Spec.eq(DriveMath.stuckCause(true, 0, 0, false), "idle")
	Spec.eq(DriveMath.stuckCause(true, 1, 0.5, false), "blocked")
	Spec.eq(DriveMath.stuckCause(true, 1, 20, true), "wrongway")
end)

Spec.test("eta never assumes a parked truck and is whole seconds", function()
	Spec.eq(DriveMath.eta(300, 0, 30), 10)
	Spec.eq(DriveMath.eta(300, 60, 30), 5)
	Spec.eq(DriveMath.eta(0, 60, 30), 0)
	Spec.eq(DriveMath.eta(-5, 60, 30), 0)
end)

Spec.test("progress is clamped 0..1", function()
	Spec.eq(DriveMath.progress(200, 200), 0)
	Spec.eq(DriveMath.progress(200, 50), 0.75)
	Spec.eq(DriveMath.progress(200, 400), 0)
	Spec.eq(DriveMath.progress(0, 10), 1)
end)

Spec.test("approach rises and falls at its own rates", function()
	Spec.eq(DriveMath.approach(1, 1.3, 0.1, 1, 2), 1.1)
	Spec.eq(DriveMath.approach(1.3, 1, 0.1, 1, 2), 1.1)
	Spec.eq(DriveMath.approach(1.29, 1.3, 1, 1, 2), 1.3)
end)

Spec.test("straight: aligned with the road either way, wheel nearly centred", function()
	Spec.eq(DriveMath.straight(0, -1, 0, 1, 0, 12, 0.25), true) -- driving 'backwards' along the edge still counts
	Spec.eq(DriveMath.straight(0, -1, 0, -1, 0.3, 12, 0.25), false) -- steering
	local a = math.rad(20)
	Spec.eq(DriveMath.straight(math.sin(a), -math.cos(a), 0, -1, 0, 12, 0.25), false) -- 20 degrees off
	Spec.eq(DriveMath.straight(0, 0, 0, 1, 0, 12, 0.25), false)
end)

Spec.test("practice fires are spaced along the route, never at the ends", function()
	local s = DriveMath.spaced(249, 35, 50, 55, 6)
	Spec.eq(#s, 3)
	Spec.eq(s[1], 35)
	Spec.eq(s[3], 145)
	Spec.eq(#DriveMath.spaced(2000, 35, 50, 55, 6), 6)
	Spec.eq(#DriveMath.spaced(60, 35, 50, 55, 6), 0)
	Spec.eq(#DriveMath.spaced(500, 35, 50, 0, 6), 0)
	Spec.eq(DriveMath.curbOffset(nil, 4), 16)
	Spec.eq(DriveMath.curbOffset(30, 4), 19)
end)

Spec.test("traffic pulls over for a slow driven siren truck right behind it", function()
	local cfg = { SlowYieldBehind = 32, SlowYieldLateral = 7 }
	Spec.eq(Driver.slowBehind(-15, 1, cfg), true)
	Spec.eq(Driver.slowBehind(-40, 1, cfg), false) -- too far back
	Spec.eq(Driver.slowBehind(10, 0, cfg), false) -- ahead of the car
	Spec.eq(Driver.slowBehind(-10, 12, cfg), false) -- other lane
	Spec.eq(Driver.slowBehind(-10, 0, { SlowYieldBehind = 0 }), false) -- off
end)

return Spec.finish()
