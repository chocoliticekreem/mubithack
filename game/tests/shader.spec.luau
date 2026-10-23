--!strict
-- PostFx + ShaderConfig: tier detection / adapt, preset mods, grade blending, weights, grain keypoints.
local Spec = require("./Spec")
local PostFx = require("../StarterPlayerScripts/ClientLib/PostFx")
local Cfg = require("../ReplicatedStorage/Config/ShaderConfig") :: any

local D = Cfg.Detect

-- detectTier -------------------------------------------------------------------------------------------

Spec.test("slider maps to tiers", function()
	Spec.eq(PostFx.detectTier({ savedQuality = 1 }, D), "Low")
	Spec.eq(PostFx.detectTier({ savedQuality = 3 }, D), "Low")
	Spec.eq(PostFx.detectTier({ savedQuality = 5 }, D), "High")
	Spec.eq(PostFx.detectTier({ savedQuality = 8 }, D), "Ultra")
	Spec.eq(PostFx.detectTier({ savedQuality = 10 }, D), "Ultra")
end)

Spec.test("automatic: desktop Ultra, mobile and console High", function()
	Spec.eq(PostFx.detectTier({ savedQuality = 0 }, D), "Ultra")
	Spec.eq(PostFx.detectTier({ savedQuality = 0, isMobile = true }, D), "High")
	Spec.eq(PostFx.detectTier({ savedQuality = 0, isConsole = true }, D), "High")
end)

Spec.test("phones never auto-pick Ultra unless MobileUltra", function()
	Spec.eq(PostFx.detectTier({ savedQuality = 10, isMobile = true }, D), "High")
	Spec.eq(PostFx.detectTier({ savedQuality = 10, isMobile = true }, { MobileUltra = true }), "Ultra")
end)

Spec.test("measured fps caps the tier", function()
	Spec.eq(PostFx.detectTier({ savedQuality = 10, fps = 45 }, D), "High")
	Spec.eq(PostFx.detectTier({ savedQuality = 10, fps = 20 }, D), "Low")
	Spec.eq(PostFx.detectTier({ savedQuality = 0, fps = 60 }, D), "Ultra")
	Spec.eq(PostFx.detectTier({ savedQuality = 2, fps = 144 }, D), "Low") -- fps never raises the slider
end)

Spec.test("resolveTier: forced setting wins, Auto/junk uses detection", function()
	Spec.eq(PostFx.resolveTier(1, "Ultra"), "Low")
	Spec.eq(PostFx.resolveTier(2, "Low"), "High")
	Spec.eq(PostFx.resolveTier(3, "Low"), "Ultra")
	Spec.eq(PostFx.resolveTier(0, "High"), "High")
	Spec.eq(PostFx.resolveTier(nil, "Low"), "Low")
	Spec.eq(PostFx.resolveTier(7, "High"), "High")
end)

-- adaptTier ----------------------------------------------------------------------------------------------

local function run(st: any, tier: string, fps: number, seconds: number, ceiling: string?): string?
	local out: string? = nil
	for _ = 1, math.floor(seconds * 10) do
		local r = PostFx.adaptTier(st, tier :: any, fps, 0.1, Cfg.Adapt, ceiling :: any)
		if r then
			out = r
			tier = r
		end
	end
	return out
end

Spec.test("slow fps steps down after DownSeconds, not before", function()
	local st = PostFx.newAdaptState()
	Spec.eq(run(st, "Ultra", 25, Cfg.Adapt.DownSeconds - 1), nil)
	Spec.eq(run(st, "Ultra", 25, 1.5), "High")
end)

Spec.test("never below Low, never above the ceiling", function()
	local st = PostFx.newAdaptState()
	Spec.eq(run(st, "Low", 10, 60), nil)
	st = PostFx.newAdaptState()
	Spec.eq(run(st, "High", 120, Cfg.Adapt.UpSeconds + 1, "High"), nil)
	st = PostFx.newAdaptState()
	Spec.eq(run(st, "High", 120, Cfg.Adapt.UpSeconds + 1, "Ultra"), "Ultra")
end)

Spec.test("a brief dip does not downgrade", function()
	local st = PostFx.newAdaptState()
	Spec.eq(run(st, "Ultra", 25, 3), nil)
	Spec.eq(run(st, "Ultra", 50, 10), nil)
	Spec.eq(run(st, "Ultra", 25, 3), nil)
end)

-- applyMods ----------------------------------------------------------------------------------------------

local function preset(): any
	return {
		Lighting = { GlobalShadows = true, EnvironmentSpecularScale = 0.4, EnvironmentDiffuseScale = 0.6, ShadowSoftness = 0.3 },
		Bloom = { Enabled = true, Intensity = 0.6, Size = 28, Threshold = 1.6 },
		SunRays = { Enabled = true, Intensity = 0.08, Spread = 0.6 },
		Atmosphere = { Density = 0.3, Glare = 0.45, Haze = 1.8 },
		Clouds = { Density = 0.6 },
		DepthOfField = { Enabled = true, FarIntensity = 0.06 },
	}
end

Spec.test("Low mods turn off the heavy effects and shadows", function()
	local v = preset()
	PostFx.applyMods(v, Cfg.TierMods.Low)
	Spec.eq(v.Bloom.Enabled, false)
	Spec.eq(v.SunRays.Enabled, false)
	Spec.eq(v.DepthOfField.Enabled, false)
	Spec.eq(v.Lighting.GlobalShadows, false)
	Spec.near(v.Lighting.EnvironmentSpecularScale, 0.2)
end)

Spec.test("High leaves the preset as authored", function()
	local v = preset()
	PostFx.applyMods(v, Cfg.TierMods.High)
	Spec.eq(v.Bloom.Intensity, 0.6)
	Spec.eq(v.Bloom.Enabled, true)
end)

Spec.test("Ultra boosts bloom for fire glow, mul then add", function()
	local v = preset()
	PostFx.applyMods(v, Cfg.TierMods.Ultra)
	Spec.near(v.Bloom.Intensity, 0.6 * 1.3)
	Spec.near(v.Bloom.Size, 36)
	Spec.near(v.Bloom.Threshold, 1.45)
	Spec.near(v.Atmosphere.Glare, 0.6)
	Spec.near(v.DepthOfField.FarIntensity, 0.12)
end)

Spec.test("mods respect ranges and weights", function()
	local v = { Bloom = { Intensity = 2.8, Threshold = 0.9 }, Atmosphere = { Density = 0.98 } }
	PostFx.applyMods(v, { Bloom = { mul = { Intensity = 2 }, add = { Threshold = -1 } }, Atmosphere = { add = { Density = 0.5 } } } :: any)
	Spec.eq(v.Bloom.Intensity, 3)
	Spec.eq(v.Bloom.Threshold, 0.8)
	Spec.eq(v.Atmosphere.Density, 1)
	local w = { Bloom = { Intensity = 1, Enabled = true } }
	PostFx.applyMods(w, { Bloom = { mul = { Intensity = 2 }, set = { Enabled = false } } } :: any, 0.25)
	Spec.near(w.Bloom.Intensity, 1.25)
	Spec.eq(w.Bloom.Enabled, true) -- non-numeric set only at weight >= 0.5
end)

Spec.test("mods skip missing kinds and non-number props", function()
	local v: any = { Bloom = { Intensity = "x" } }
	PostFx.applyMods(v, { Bloom = { mul = { Intensity = 2 } }, SunRays = { set = { Enabled = false } } } :: any)
	Spec.eq(v.Bloom.Intensity, "x")
	Spec.eq(v.SunRays, nil)
end)

-- grades -----------------------------------------------------------------------------------------------------

Spec.test("every AtmosphereConfig preset has a grade with sane values", function()
	local names = { "StationGolden", "DuskSuburb", "NightStreet", "SchoolInterior", "GoldenFarm", "FireGlow", "StorageOvercast", "DamNight", "ZooDay", "Default" }
	for _, n in names do
		local raw = Cfg.Grades[n]
		Spec.truthy(raw, n)
		local g = PostFx.grade(raw)
		Spec.truthy(g.lift.contrast <= 0, n .. " lift contrast lifts blacks")
		Spec.truthy(g.filmic.contrast > 0, n .. " filmic contrast")
		for _, k in { "vignette", "fringe", "lens", "grain" } do
			local x = (g :: any)[k]
			Spec.truthy(x >= 0 and x <= 1, n .. "." .. k)
		end
	end
end)

Spec.test("hex parsing", function()
	local c = PostFx.hex("#FF8000")
	Spec.near(c.r, 1)
	Spec.near(c.g, 128 / 255)
	Spec.near(c.b, 0)
	local bad = PostFx.hex("nope")
	Spec.eq(bad.r, 1)
end)

Spec.test("blendGrade endpoints, midpoint and wet snap", function()
	local a = PostFx.grade(Cfg.Grades.DuskSuburb)
	local b = PostFx.grade(Cfg.Grades.NightStreet)
	local g0 = PostFx.blendGrade(a, b, 0)
	local g1 = PostFx.blendGrade(a, b, 1)
	Spec.near(g0.filmic.contrast, a.filmic.contrast)
	Spec.near(g1.filmic.contrast, b.filmic.contrast)
	local mid = PostFx.blendGrade(a, b, 0.5)
	Spec.near(mid.vignette, (a.vignette + b.vignette) / 2)
	Spec.near(mid.lift.tint.b, (a.lift.tint.b + b.lift.tint.b) / 2)
	Spec.eq(PostFx.blendGrade(a, b, 0.4).wet, false)
	Spec.eq(PostFx.blendGrade(a, b, 0.6).wet, true)
	Spec.near(PostFx.blendGrade(a, b, 5).vignette, b.vignette) -- t is clamped
end)

Spec.test("scaleGrade fades to neutral", function()
	local g = PostFx.grade(Cfg.Grades.FireGlow)
	local z = PostFx.scaleGrade(g, 0)
	Spec.eq(z.filmic.contrast, 0)
	Spec.eq(z.lift.tint.r, 1)
	Spec.eq(z.vignette, 0)
	local h = PostFx.scaleGrade(g, 0.6)
	Spec.near(h.filmic.contrast, g.filmic.contrast * 0.6)
end)

-- weights -----------------------------------------------------------------------------------------------------

Spec.test("motionWeight ramps smoothly", function()
	Spec.eq(PostFx.motionWeight(5, 16, 70), 0)
	Spec.eq(PostFx.motionWeight(100, 16, 70), 1)
	Spec.near(PostFx.motionWeight(43, 16, 70), 0.5)
	Spec.eq(PostFx.motionWeight(20, 20, 20), 1)
end)

Spec.test("lensWeight only when facing a visible light", function()
	Spec.eq(PostFx.lensWeight(-0.5, 1, 6), 0)
	Spec.eq(PostFx.lensWeight(1, 0, 6), 0)
	Spec.near(PostFx.lensWeight(1, 1, 6), 1)
	Spec.truthy(PostFx.lensWeight(0.8, 1, 6) < 0.3)
end)

Spec.test("fireGlow sums falloff-weighted lights and clamps", function()
	Spec.eq(PostFx.fireGlow({}, Cfg.FireGlow), 0)
	local one = PostFx.fireGlow({ { 0, 3 } }, Cfg.FireGlow)
	Spec.near(one, 3 / Cfg.FireGlow.GlowFullAt)
	local far = PostFx.fireGlow({ { 54, 3 } }, Cfg.FireGlow)
	Spec.truthy(far < one * 0.2)
	Spec.eq(PostFx.fireGlow({ { 0, 5 }, { 0, 5 } }, Cfg.FireGlow), 1)
end)

Spec.test("grain keypoints: 0..1, strictly increasing, bounded alpha", function()
	local seed = 1
	local function rand(): number
		seed = (seed * 1103515245 + 12345) % 2147483648
		return seed / 2147483648
	end
	for _ = 1, 50 do
		local k = PostFx.grainKeypoints(rand, 18, 0.07)
		Spec.eq(#k, 18)
		Spec.eq(k[1][1], 0)
		Spec.eq(k[#k][1], 1)
		for i = 2, #k do
			Spec.truthy(k[i][1] > k[i - 1][1], "increasing")
		end
		for _, p in k do
			Spec.truthy(p[2] >= 0.93 and p[2] <= 1, "alpha")
		end
	end
	Spec.eq(#PostFx.grainKeypoints(rand, 99, 1), 20)
	Spec.eq(#PostFx.grainKeypoints(rand, 0, 1), 2)
end)

-- settings + budgets -------------------------------------------------------------------------------------------

Spec.test("settings cycle and label", function()
	Spec.eq(PostFx.nextSetting(0), 1)
	Spec.eq(PostFx.nextSetting(3), 0)
	Spec.eq(PostFx.nextSetting(nil), 1)
	Spec.eq(PostFx.settingLabel(0, "Ultra"), "GRAPHICS: AUTO (ULTRA)")
	Spec.eq(PostFx.settingLabel(1, "Ultra"), "GRAPHICS: LOW")
end)

Spec.test("Low budget disables everything heavy; budgets grow with tier", function()
	local L, H, U = Cfg.Budgets.Low, Cfg.Budgets.High, Cfg.Budgets.Ultra
	Spec.eq(L.overlays, false)
	Spec.eq(L.haze, false)
	Spec.eq(L.motionDof, false)
	Spec.eq(L.shafts, 0)
	Spec.eq(L.wetRoads, false)
	Spec.eq(L.fireGlow, false)
	Spec.truthy(L.gradeWeight <= H.gradeWeight and H.gradeWeight <= U.gradeWeight)
	Spec.truthy(L.shafts <= H.shafts and H.shafts <= U.shafts)
	Spec.truthy(U.shafts <= 4, "shaft cap (2 beams each)")
end)

Spec.test("ShaderConfig.Set rejects unknown keys", function()
	Cfg.Set("GrainFps", 24)
	Spec.errors(function()
		Cfg.Set("GrainFPS", 1)
	end, "unknown key")
end)

return Spec.finish()
