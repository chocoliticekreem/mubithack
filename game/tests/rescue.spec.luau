--!strict
-- RescueRules: kinds, states, carry speed, throw, landing, fire damage, panic circle, panda pairing.
local Spec = require("./Spec")
local R = require("../ServerScriptService/Lib/Rescue/RescueRules")

local cfg = {
	WalkSpeed = 16,
	SpeedCivilian = 0.75,
	SpeedDog = 0.95,
	SpeedCat = 0.95,
	SpeedPanda = 0.4,
	SpeedPandaPair = 0.6,
	ThrowMin = 25,
	ThrowMax = 70,
	ThrowUp = 28,
	ThrowPandaMult = 0.35,
	DownedImpact = 55,
	FireHurtRadius = 7,
	FireDps = 12,
}

Spec.test("kind normalises builder spellings", function()
	Spec.eq(R.kind("civilian"), "Civilian")
	Spec.eq(R.kind("Panda"), "Panda")
	Spec.eq(R.kind("cat"), "Cat")
	Spec.eq(R.kind("floatguy"), "Civilian")
	Spec.eq(R.kind(nil), "Civilian")
	Spec.eq(R.kind("dragon"), "Civilian")
end)

Spec.test("lying spawns are Downed, others Trapped", function()
	Spec.eq(R.initialState(R.pose("lying")), "Downed")
	Spec.eq(R.initialState(R.pose("sitting")), "Trapped")
	Spec.eq(R.pose("upside-down"), "stand")
end)

Spec.test("only Trapped and Downed can be picked up", function()
	Spec.truthy(R.canPick("Trapped"))
	Spec.truthy(R.canPick("Downed"))
	Spec.eq(R.canPick("Carried"), false)
	Spec.eq(R.canPick("Rescued"), false)
	Spec.eq(R.canPick("Toasted"), false)
end)

Spec.test("carry speed: panda is heavy, lighter with two", function()
	Spec.near(R.speed("Civilian", 1, cfg), 12)
	Spec.near(R.speed("Cat", 1, cfg), 15.2)
	Spec.near(R.speed("Panda", 1, cfg), 6.4)
	Spec.near(R.speed("Panda", 2, cfg), 9.6)
	Spec.near(R.speed("Unknown", 1, cfg), 12)
end)

Spec.test("throw scales with charge and the panda barely moves", function()
	local f0, u0 = R.throwSpeed(0, "Cat", cfg)
	local f1, u1 = R.throwSpeed(1, "Cat", cfg)
	Spec.near(f0, 25)
	Spec.near(f1, 70)
	Spec.truthy(u1 > u0, "up grows with charge")
	local fp = R.throwSpeed(1, "Panda", cfg)
	Spec.near(fp, 70 * 0.35)
	Spec.near((R.throwSpeed(5, "Cat", cfg)), 70, 1e-6, "clamped")
	Spec.near((R.throwSpeed(0 / 0, "Cat", cfg)), 25, 1e-6, "NaN is zero")
end)

Spec.test("hard landings knock out", function()
	Spec.eq(R.landing(70, cfg), "Downed")
	Spec.eq(R.landing(10, cfg), "Trapped")
end)

Spec.test("fire damage: none outside, more when closer and hotter", function()
	Spec.eq(R.fireDamage(8, 3, 1, cfg), 0)
	local edge = R.fireDamage(7, 2, 1, cfg)
	local close = R.fireDamage(0, 2, 1, cfg)
	Spec.near(close, 12)
	Spec.near(edge, 6)
	Spec.truthy(R.fireDamage(0, 3, 1, cfg) > close)
end)

Spec.test("panic circle stays on its radius and faces the tangent", function()
	for _, t in { 0, 0.3, 1.7, 5 } do
		local x, z, yaw = R.panicPoint(t, 4, 12)
		Spec.near(math.sqrt(x * x + z * z), 4, 1e-6)
		-- facing (-sin yaw, -cos yaw) must be perpendicular to the radius
		local fx, fz = -math.sin(yaw), -math.cos(yaw)
		Spec.near(fx * x + fz * z, 0, 1e-6, "tangent")
	end
end)

Spec.test("panda needs two recent grabbers", function()
	Spec.eq(#R.pair({ a = 10 }, 10.5, 2.5, 2), 0)
	Spec.eq(#R.pair({ a = 5, b = 10 }, 10.5, 2.5, 2), 0, "a is stale")
	local both = R.pair({ a = 9, b = 10, c = 10.2 }, 10.5, 2.5, 2)
	Spec.eq(#both, 2)
	Spec.eq(both[1], "a")
	Spec.eq(both[2], "b")
end)

Spec.test("inBox honours the pad", function()
	Spec.truthy(R.inBox(6.5, 0, 0, 6, 3.5, 3, 2))
	Spec.eq(R.inBox(9, 0, 0, 6, 3.5, 3, 2), false)
end)

Spec.test("blame goes to the recent thrower, then the dropper", function()
	Spec.eq(R.culprit({ thrower = "p1", thrownAt = 10 }, 12, 8), "p1")
	Spec.eq(R.culprit({ thrower = "p1", thrownAt = 1, dropper = "p2", droppedAt = 9 }, 12, 8), "p2")
	Spec.eq(R.culprit({ thrower = "p1", thrownAt = 1 }, 12, 8), nil)
end)

Spec.test("shout lines cycle and fall back", function()
	Spec.eq(R.line("Cat", "carried", 1), "MEOW!")
	Spec.eq(type(R.line("Dragon", "nope", 7)), "string")
end)

return Spec.finish()
