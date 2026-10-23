--!strict
-- HeatMath: proximity gain (inverse-square-ish, FireLevel weighted, wall reduced), cooling, stages.
local Spec = require("./Spec")
local HeatMath = require("../ServerScriptService/Lib/Heat/HeatMath")

local cfg: HeatMath.Cfg = {
	DownAt = 100,
	RisePerSecond = 14,
	RefDistance = 6,
	Radius = 20,
	LevelWeight = { 0.6, 1, 1.5 },
	OccludedFactor = 0.25,
	MaxRisePerSecond = 40,
	CoolPerSecond = 6,
	HoseCoolPerSecond = 45,
	WaterCoolPerSecond = 25,
	WarmAt = 60,
	SweatyAt = 85,
	SweatyWalkMultiplier = 0.65,
}

Spec.test("closer fire heats faster (inverse-square-ish)", function()
	local near = HeatMath.sourceRate(2, 2, false, cfg)
	local mid = HeatMath.sourceRate(6, 2, false, cfg)
	local far = HeatMath.sourceRate(18, 2, false, cfg)
	Spec.truthy(near > mid and mid > far, "monotonic falloff")
	Spec.near(mid, cfg.RisePerSecond / 2, 1e-9, "half gain at RefDistance")
	Spec.near(far, cfg.RisePerSecond / 10, 1e-9, "1/(1+3^2) at 3x RefDistance")
end)

Spec.test("distance 0 is finite and equals RisePerSecond x weight", function()
	Spec.near(HeatMath.sourceRate(0, 2, false, cfg), cfg.RisePerSecond, 1e-9)
end)

Spec.test("beyond Radius and NaN distance add nothing", function()
	Spec.eq(HeatMath.sourceRate(21, 3, false, cfg), 0)
	Spec.eq(HeatMath.sourceRate(0 / 0, 3, false, cfg), 0)
end)

Spec.test("FireLevel weights the rate and is clamped to 1..3", function()
	local l1 = HeatMath.sourceRate(4, 1, false, cfg)
	local l3 = HeatMath.sourceRate(4, 3, false, cfg)
	Spec.near(l3 / l1, 1.5 / 0.6, 1e-9)
	Spec.near(HeatMath.sourceRate(4, 9, false, cfg), l3, 1e-9, "level 9 clamps to 3")
	Spec.near(HeatMath.sourceRate(4, 0, false, cfg), l1, 1e-9, "level 0 clamps to 1")
end)

Spec.test("a wall between you and the fire reduces heat", function()
	local open = HeatMath.sourceRate(4, 2, false, cfg)
	local walled = HeatMath.sourceRate(4, 2, true, cfg)
	Spec.near(walled, open * cfg.OccludedFactor, 1e-9)
end)

Spec.test("gainRate sums sources and caps at MaxRisePerSecond", function()
	local one = HeatMath.gainRate({ { dist = 6, level = 2 } }, cfg)
	local two = HeatMath.gainRate({ { dist = 6, level = 2 }, { dist = 6, level = 2 } }, cfg)
	Spec.near(two, 2 * one, 1e-9)
	local many = {}
	for _ = 1, 20 do
		table.insert(many, { dist = 1, level = 3 })
	end
	Spec.eq(HeatMath.gainRate(many, cfg), cfg.MaxRisePerSecond)
	Spec.eq(HeatMath.gainRate({}, cfg), 0)
end)

Spec.test("step cools passively and clamps to 0..DownAt", function()
	Spec.near(HeatMath.step(50, 0, 1, nil, cfg), 44, 1e-9)
	Spec.eq(HeatMath.step(2, 0, 1, nil, cfg), 0)
	Spec.eq(HeatMath.step(95, 100, 1, nil, cfg), 100)
end)

Spec.test("a teammate's hose cools much faster than waiting; water helps too", function()
	local idle = HeatMath.step(90, 0, 1, nil, cfg)
	local hosed = HeatMath.step(90, 0, 1, { sprayed = true }, cfg)
	local wet = HeatMath.step(90, 0, 1, { inWater = true }, cfg)
	local both = HeatMath.step(90, 0, 1, { sprayed = true, inWater = true }, cfg)
	Spec.truthy(hosed < wet and wet < idle, "hose < water < idle")
	Spec.near(both, 90 - 6 - 45 - 25, 1e-9)
end)

Spec.test("stages: 60 warm, 85 sweaty, 100 overheated", function()
	Spec.eq(HeatMath.stage(0, cfg), 0)
	Spec.eq(HeatMath.stage(59.9, cfg), 0)
	Spec.eq(HeatMath.stage(60, cfg), 1)
	Spec.eq(HeatMath.stage(85, cfg), 2)
	Spec.eq(HeatMath.stage(99.99, cfg), 2)
	Spec.eq(HeatMath.stage(100, cfg), 3)
end)

Spec.test("sweaty slows the walk, below that it does not", function()
	Spec.eq(HeatMath.walkMultiplier(84, cfg), 1)
	Spec.eq(HeatMath.walkMultiplier(85, cfg), cfg.SweatyWalkMultiplier)
end)

Spec.test("tuning: hugging a big fire overheats in ~5-20 s, a small fire far away never does", function()
	local hug = HeatMath.secondsToOverheat(4, 3, cfg)
	Spec.truthy(hug > 5 and hug < 20, `hug={hug}`)
	Spec.eq(HeatMath.secondsToOverheat(12, 1, cfg), math.huge)
end)

Spec.test("simulated: walk in, overheat, get hosed back below warm in a few seconds", function()
	local heat = 0
	local t = 0
	while HeatMath.stage(heat, cfg) < 3 and t < 60 do
		heat = HeatMath.step(heat, HeatMath.gainRate({ { dist = 3, level = 3 }, { dist = 5, level = 2 } }, cfg), 0.2, nil, cfg)
		t += 0.2
	end
	Spec.eq(HeatMath.stage(heat, cfg), 3, "overheated")
	Spec.truthy(t < 15, `took {t}s`)
	local cool = 0
	while heat >= cfg.WarmAt do
		heat = HeatMath.step(heat, 0, 0.2, { sprayed = true }, cfg)
		cool += 0.2
	end
	Spec.truthy(cool <= 1.2, `hosing took {cool}s`)
end)

return Spec.finish()
