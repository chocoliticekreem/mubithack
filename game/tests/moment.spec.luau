--!strict
-- MomentRules: who sees a big moment, the per-player cooldown, driving / popups / calm, hazard mapping.
local Spec = require("./Spec")
local R = require("../StarterPlayerScripts/Lib/MomentRules")

local CFG = {
	Enabled = true,
	CooldownSeconds = 20,
	DriveSpeed = 22,
	BeatSeconds = 1,
	CalmBeatSeconds = 0.6,
	FovPunch = -12,
	Shake = 0.45,
	CaptionTextSize = 96,
	CalmCaptionTextSize = 60,
	OoohVolume = 0.7,
	CalmOoohVolume = 0.35,
	Kinds = { backdraft = { caption = "BACKDRAFT!!", range = 50 }, slap = { caption = "SLAPPED!", range = 30 } },
}

local function ctx(over: { [string]: any }?): any
	local c: { [string]: any } = { involved = false, distance = 10, popups = "Normal", calm = false, busy = false, driveSpeed = 0 }
	for k, v in over or {} do
		c[k] = v
	end
	return c
end

Spec.test("a nearby moment shows, then the 20 s cooldown blocks the next one", function()
	local s = R.new()
	Spec.eq(R.admit(s, 100, "backdraft", ctx(), CFG).show, true)
	Spec.eq(R.admit(s, 110, "slap", ctx({ involved = true }), CFG).reason, "cooldown")
	Spec.eq(R.admit(s, 119.9, "backdraft", ctx(), CFG).reason, "cooldown")
	Spec.eq(R.admit(s, 120, "backdraft", ctx(), CFG).show, true)
end)

Spec.test("blocked moments don't start the cooldown", function()
	local s = R.new()
	Spec.eq(R.admit(s, 0, "backdraft", ctx({ distance = 500 }), CFG).reason, "far")
	Spec.eq(R.admit(s, 1, "backdraft", ctx(), CFG).show, true)
end)

Spec.test("range: far away only shows when you're in it", function()
	local s = R.new()
	Spec.eq(R.admit(s, 0, "slap", ctx({ distance = 31 }), CFG).reason, "far")
	Spec.eq(R.admit(s, 0, "slap", ctx({ distance = 31, involved = true }), CFG).show, true)
end)

Spec.test("popups OFF = none, MINIMAL = only your own", function()
	local s = R.new()
	Spec.eq(R.admit(s, 0, "slap", ctx({ popups = "Off", involved = true }), CFG).reason, "popups")
	Spec.eq(R.admit(s, 0, "slap", ctx({ popups = "Minimal" }), CFG).reason, "far")
	Spec.eq(R.admit(s, 0, "slap", ctx({ popups = "Minimal", involved = true }), CFG).show, true)
end)

Spec.test("never while driving fast, over a modal / results, or for unknown kinds", function()
	local s = R.new()
	Spec.eq(R.admit(s, 0, "backdraft", ctx({ driveSpeed = 40 }), CFG).reason, "driving")
	Spec.eq(R.admit(s, 0, "backdraft", ctx({ busy = true }), CFG).reason, "busy")
	Spec.eq(R.admit(s, 0, "nope", ctx(), CFG).reason, "kind")
	Spec.eq(R.admit(s, 0, "backdraft", ctx({ driveSpeed = 10 }), CFG).show, true) -- parked / slow is fine
end)

Spec.test("Studio noCooldown skips the cooldown", function()
	local s = R.new()
	Spec.eq(R.admit(s, 0, "slap", ctx(), CFG).show, true)
	Spec.eq(R.admit(s, 1, "slap", ctx({ noCooldown = true }), CFG).show, true)
end)

Spec.test("calm beat is shorter, smaller, softer and skips slow-mo", function()
	local full, calm = R.beat(CFG, false), R.beat(CFG, true)
	Spec.eq(full.seconds, 1)
	Spec.eq(full.slow, true)
	Spec.eq(full.captionSize, 96)
	Spec.eq(calm.seconds, 0.6)
	Spec.eq(calm.slow, false)
	Spec.eq(calm.captionSize, 60)
	Spec.truthy(math.abs(calm.fov) < math.abs(full.fov), "calm fov punch smaller")
	Spec.truthy(calm.ooohVolume < full.ooohVolume, "calm oooh quieter")
end)

Spec.test("hazard fx map to moments", function()
	Spec.eq(R.classifyHazard("backdraft", { direction = 1 }), "backdraft")
	Spec.eq(R.classifyHazard("backdraft", {}), "flashover")
	Spec.eq(R.classifyHazard("explosion", { big = true }), "kaboom")
	Spec.eq(R.classifyHazard("ceiling_collapse", { warn = 2 }), "collapse")
	Spec.eq(R.classifyHazard("electrocution", {}), nil)
end)

return Spec.finish()
