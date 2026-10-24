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

-- panic brain v2 -------------------------------------------------------------------------------

local function moodOf(over: { [string]: any }): string
	local s: { [string]: any } = {
		kind = "Civilian",
		fireDist = 5,
		panicRadius = 20,
		sees = false,
		playerDist = 100,
		boxedIn = false,
		hideSpot = false,
		hidden = false,
		standing = true,
	}
	for k, v in over do
		s[k] = v
	end
	return R.mood(s)
end

Spec.test("mood: civilians flee fire, cower when boxed in, run to a firefighter", function()
	Spec.eq(moodOf({}), "flee")
	Spec.eq(moodOf({ boxedIn = true }), "cower")
	Spec.eq(moodOf({ sees = true, playerDist = 10 }), "approach")
	Spec.eq(moodOf({ sees = true, boxedIn = true }), "approach", "a firefighter beats cowering")
	Spec.eq(moodOf({ fireDist = 50 }), "idle", "calm when the fire is far / out")
	Spec.eq(moodOf({ fireDist = 50, sees = true }), "approach")
	Spec.eq(moodOf({ standing = false }), "idle", "KO'd NPCs don't run")
end)

Spec.test("mood: dogs zoom, cats hide, the panda waddles", function()
	Spec.eq(moodOf({ kind = "Dog" }), "zoom")
	Spec.eq(moodOf({ kind = "Cat" }), "zoom")
	Spec.eq(moodOf({ kind = "Cat", hideSpot = true }), "hide")
	Spec.eq(moodOf({ kind = "Cat", hidden = true, sees = true }), "hide", "a hidden cat stays hidden")
	Spec.eq(moodOf({ kind = "Cat", boxedIn = true }), "cower")
	Spec.eq(moodOf({ kind = "Panda" }), "flee")
	Spec.eq(moodOf({ kind = "Panda", boxedIn = true }), "cower")
	Spec.eq(moodOf({ kind = "Panda", fireDist = 50, sees = true }), "wave")
	Spec.eq(moodOf({ kind = "Cat", fireDist = 50, sees = true }), "wave")
end)

local function base(over: { [string]: any }): { [string]: any }
	local p: { [string]: any } = { x = 0, z = 0, fx = -5, fz = 0, hx = 0, hz = 0, leash = 14, t = 0, mood = "flee" }
	for k, v in over do
		p[k] = v
	end
	return p
end

Spec.test("desire: flee runs away from the fire, approach runs to the target", function()
	local dx, dz = R.desire(base({}))
	Spec.truthy(dx > 0.9 and math.abs(dz) < 1e-6, "away from a fire at -X")
	dx, dz = R.desire(base({ mood = "approach", tx = 0, tz = 8 }))
	Spec.truthy(dz > 0 and math.abs(dx) < 1e-6, "toward the firefighter")
end)

Spec.test("desire: the leash pulls it back home near the edge", function()
	-- at the leash edge, fleeing further out (+X) loses to the pull home (-X)
	local dx = R.desire(base({ x = 14, fx = 9 }))
	Spec.truthy(dx < 0, `pulled home, got {dx}`)
	-- well inside the leash there is no pull
	dx = R.desire(base({ x = 3, fx = -2 }))
	Spec.truthy(dx > 0.9)
end)

Spec.test("desire: zoomies run tangentially around home", function()
	local dx, dz = R.desire(base({ mood = "zoom", x = 14 * 0.35, z = 0 }))
	Spec.truthy(math.abs(dx) < 1e-6 and dz > 0.9, `tangent, got {dx},{dz}`)
end)

Spec.test("headings: wanted direction first, 8 distinct unit headings", function()
	local h = R.headings(0, 1)
	Spec.eq(#h, 8)
	Spec.near(h[1].x, 0, 1e-9)
	Spec.near(h[1].z, 1, 1e-9)
	Spec.near(h[8].z, -1, 1e-9, "the opposite way is tried last")
	for _, v in h do
		Spec.near(v.x * v.x + v.z * v.z, 1, 1e-9)
	end
end)

Spec.test("pickHeading: never into a wall; nil when boxed in", function()
	local cands = {
		{ x = 1, z = 0, clear = 0 }, -- wall straight ahead
		{ x = 0, z = 1, clear = 5 },
		{ x = 0, z = -1, clear = 1.2 },
		{ x = -1, z = 0, clear = 8 },
	}
	Spec.eq(R.pickHeading(cands, 1, 0, 1), 2, "side with more room beats the back")
	Spec.eq(R.pickHeading(cands, -1, 0, 1), 4)
	Spec.eq(R.pickHeading({ { x = 1, z = 0, clear = 0.3 }, { x = -1, z = 0, clear = 0 } }, 1, 0, 1), nil)
end)

Spec.test("stepOk: stairs yes, ledges and holes no", function()
	Spec.eq(R.stepOk(10, 11, 1.6, 2.2), true)
	Spec.eq(R.stepOk(10, 12, 1.6, 2.2), false, "too high")
	Spec.eq(R.stepOk(10, 7, 1.6, 2.2), false, "balcony drop")
	Spec.eq(R.stepOk(10, nil, 1.6, 2.2), false, "no floor")
end)

Spec.test("smokeLevel reads bools, fractions, percents and words", function()
	Spec.eq(R.smokeLevel(true), 1)
	Spec.eq(R.smokeLevel(false), 0)
	Spec.near(R.smokeLevel(0.5), 0.5)
	Spec.near(R.smokeLevel(80), 0.8)
	Spec.eq(R.smokeLevel("heavy"), 1)
	Spec.near(R.smokeLevel("light"), 0.4)
	Spec.eq(R.smokeLevel(nil), 0)
	Spec.eq(R.smokeLevel(0 / 0), 0)
end)

Spec.test("callForHelp: near but out of sight", function()
	Spec.eq(R.callForHelp(20, false, 45), true)
	Spec.eq(R.callForHelp(20, true, 45), false, "they can see you: wave instead")
	Spec.eq(R.callForHelp(60, false, 45), false, "too far to hear")
end)

Spec.test("new reaction lines exist for every kind", function()
	for _, kind in { "Civilian", "Dog", "Cat", "Panda" } do
		for _, mood in { "trapped", "wave", "cower", "cough", "calm" } do
			Spec.truthy(#R.line(kind, mood, 1) > 0, `{kind}.{mood}`)
		end
	end
	Spec.eq(R.line("Civilian", "trapped", 1), "HELP! IN HERE!")
end)

return Spec.finish()
