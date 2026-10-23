--!strict
-- PostFx [owner: Graphics/shader lane]. Pure maths for the "shader pack" (ShaderController): graphics
-- tier detection + adaptive downgrade, per-tier preset modifiers, cinematic grade blending, motion /
-- lens / fire-glow weights and procedural film-grain keypoints.
-- NO Roblox APIs (no Color3/Vector3/Instance/task): colours are { r, g, b } in 0..1 or "#RRGGBB" hex,
-- so game/tests/shader.spec.luau can run it with the `luau` CLI.
--
--   PostFx.detectTier(info, cfg) -> Tier               info = { savedQuality, isMobile, isConsole, fps }
--   PostFx.resolveTier(setting, detected) -> Tier      setting 0 = Auto, 1 Low, 2 High, 3 Ultra
--   PostFx.adaptTier(st, tier, fps, dt, cfg) -> Tier?  auto mode: step down when slow, up when fast
--   PostFx.applyMods(values, mods, weight?)            mutate a GraphicsController values table
--   PostFx.blendGrade(a, b, t) / PostFx.scaleGrade(g, w) / PostFx.neutralCC()
--   PostFx.motionWeight(speed, from, full) / PostFx.lensWeight(dot, visible, power)
--   PostFx.fireGlow(lights, cfg) / PostFx.grainKeypoints(rand, count, maxAlpha)
--   PostFx.settingLabel(setting, tier) / PostFx.nextSetting(setting)
local PostFx = {}

export type Tier = "Low" | "High" | "Ultra"
export type RGB = { r: number, g: number, b: number }

PostFx.Tiers = { "Low", "High", "Ultra" } :: { Tier }

local TIER_INDEX: { [string]: number } = { Low = 1, High = 2, Ultra = 3 }

function PostFx.tierIndex(t: string?): number
	return TIER_INDEX[t or ""] or 2
end

function PostFx.tierAt(i: number): Tier
	return PostFx.Tiers[math.clamp(math.floor(i), 1, 3)]
end

-- Basic maths -----------------------------------------------------------------------------------------

function PostFx.clamp01(x: number): number
	return if x < 0 then 0 elseif x > 1 then 1 else x
end

function PostFx.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function PostFx.smoothstep(t: number): number
	t = PostFx.clamp01(t)
	return t * t * (3 - 2 * t)
end

function PostFx.hex(h: string): RGB
	local s = string.gsub(h, "#", "")
	if #s ~= 6 then
		return { r = 1, g = 1, b = 1 }
	end
	local r = tonumber(string.sub(s, 1, 2), 16) or 255
	local g = tonumber(string.sub(s, 3, 4), 16) or 255
	local b = tonumber(string.sub(s, 5, 6), 16) or 255
	return { r = r / 255, g = g / 255, b = b / 255 }
end

local function asRgb(c: any): RGB
	if type(c) == "string" then
		return PostFx.hex(c)
	elseif type(c) == "table" then
		return { r = c.r or 1, g = c.g or 1, b = c.b or 1 }
	end
	return { r = 1, g = 1, b = 1 }
end

function PostFx.lerpRgb(a: any, b: any, t: number): RGB
	local x, y = asRgb(a), asRgb(b)
	return { r = PostFx.lerp(x.r, y.r, t), g = PostFx.lerp(x.g, y.g, t), b = PostFx.lerp(x.b, y.b, t) }
end

-- Tier detection ---------------------------------------------------------------------------------------

export type DeviceInfo = {
	savedQuality: number?, -- Roblox UserGameSettings.SavedQualityLevel: 0 = Automatic, 1..10 = slider
	isMobile: boolean?,
	isConsole: boolean?,
	fps: number?, -- measured average fps (nil = not sampled yet)
}

-- Picks a tier from the player's Roblox graphics slider, device class and measured fps.
-- Slider 1..LowMaxQuality = Low, >= UltraMinQuality = Ultra, between = High. Automatic (0) starts at
-- Ultra on desktop, High on mobile/console. Then fps caps it: < LowFps -> Low, < UltraFps -> at most High.
function PostFx.detectTier(info: DeviceInfo, cfg: any): Tier
	local q = math.floor(info.savedQuality or 0)
	local idx: number
	if q >= 1 then
		if q <= (cfg.LowMaxQuality or 3) then
			idx = 1
		elseif q >= (cfg.UltraMinQuality or 8) then
			idx = 3
		else
			idx = 2
		end
	else
		idx = if info.isMobile or info.isConsole then 2 else 3
	end
	if info.isMobile and not cfg.MobileUltra then
		idx = math.min(idx, 2)
	end
	local fps = info.fps
	if fps then
		if fps < (cfg.LowFps or 30) then
			idx = 1
		elseif fps < (cfg.UltraFps or 50) then
			idx = math.min(idx, 2)
		end
	end
	return PostFx.tierAt(idx)
end

-- Setting 1..3 forces a tier; 0 (Auto) or anything else uses the detected one.
function PostFx.resolveTier(setting: number?, detected: Tier): Tier
	local s = math.floor(tonumber(setting) or 0)
	if s >= 1 and s <= 3 then
		return PostFx.tierAt(s)
	end
	return detected
end

export type AdaptState = { slow: number, fast: number }

function PostFx.newAdaptState(): AdaptState
	return { slow = 0, fast = 0 }
end

-- Auto mode only. fps below DownFps for DownSeconds -> one tier down; above UpFps for UpSeconds -> one
-- tier up (never above `ceiling`, the tier detection allowed). Returns the new tier or nil (no change).
function PostFx.adaptTier(st: AdaptState, tier: Tier, fps: number, dt: number, cfg: any, ceiling: Tier?): Tier?
	local i = PostFx.tierIndex(tier)
	if fps < (cfg.DownFps or 38) then
		st.slow += dt
		st.fast = 0
	elseif fps > (cfg.UpFps or 58) then
		st.fast += dt
		st.slow = 0
	else
		st.slow = math.max(0, st.slow - dt)
		st.fast = math.max(0, st.fast - dt)
	end
	if st.slow >= (cfg.DownSeconds or 8) and i > 1 then
		st.slow, st.fast = 0, 0
		return PostFx.tierAt(i - 1)
	end
	local cap = PostFx.tierIndex(ceiling or "Ultra")
	if st.fast >= (cfg.UpSeconds or 30) and i < cap then
		st.slow, st.fast = 0, 0
		return PostFx.tierAt(i + 1)
	end
	return nil
end

-- Preset modifiers ---------------------------------------------------------------------------------------

-- Valid ranges for numbers we scale, so stacked mods never push a property out of range.
PostFx.Ranges = {
	["Bloom.Intensity"] = { 0, 3 },
	["Bloom.Size"] = { 0, 56 },
	["Bloom.Threshold"] = { 0.8, 4 },
	["SunRays.Intensity"] = { 0, 1 },
	["SunRays.Spread"] = { 0, 1 },
	["Atmosphere.Density"] = { 0, 1 },
	["Atmosphere.Offset"] = { 0, 1 },
	["Atmosphere.Glare"] = { 0, 10 },
	["Atmosphere.Haze"] = { 0, 10 },
	["Clouds.Cover"] = { 0, 1 },
	["Clouds.Density"] = { 0, 1 },
	["DepthOfField.FarIntensity"] = { 0, 1 },
	["DepthOfField.NearIntensity"] = { 0, 1 },
	["DepthOfField.FocusDistance"] = { 0, 200 },
	["DepthOfField.InFocusRadius"] = { 0, 50 },
	["ColorCorrection.Contrast"] = { -1, 1 },
	["ColorCorrection.Saturation"] = { -1, 1 },
	["Lighting.EnvironmentSpecularScale"] = { 0, 1 },
	["Lighting.EnvironmentDiffuseScale"] = { 0, 1 },
	["Lighting.ShadowSoftness"] = { 0, 1 },
} :: { [string]: { number } }

local function clampProp(kind: string, prop: string, v: number): number
	local r = PostFx.Ranges[kind .. "." .. prop]
	if r then
		return math.clamp(v, r[1], r[2])
	end
	return v
end

export type KindMods = { mul: { [string]: number }?, add: { [string]: number }?, set: { [string]: any }? }
export type Mods = { [string]: KindMods }

-- Applies `mods` to a values table ({ kind -> { prop -> value } }) in place: mul, then add, then set.
-- `weight` (0..1, default 1) fades numeric mods in (mul 1.5 at weight 0.5 = x1.25). mul/add only touch
-- props that exist and are numbers; `set` writes (and creates) props, but only on kinds that exist, and
-- only at weight >= 0.5 for non-numbers.
function PostFx.applyMods(values: { [string]: { [string]: any } }, mods: Mods?, weight: number?)
	if not mods then
		return
	end
	local w = PostFx.clamp01(weight or 1)
	if w <= 0 then
		return
	end
	for kind, m in mods do
		local t = values[kind]
		if t then
			if m.mul then
				for prop, f in m.mul do
					local v = t[prop]
					if type(v) == "number" then
						t[prop] = clampProp(kind, prop, v * PostFx.lerp(1, f, w))
					end
				end
			end
			if m.add then
				for prop, d in m.add do
					local v = t[prop]
					if type(v) == "number" then
						t[prop] = clampProp(kind, prop, v + d * w)
					end
				end
			end
			if m.set then
				for prop, v in m.set do
					local cur = t[prop]
					if type(v) == "number" and type(cur) == "number" then
						t[prop] = clampProp(kind, prop, PostFx.lerp(cur, v, w))
					elseif w >= 0.5 then
						t[prop] = if type(v) == "number" then clampProp(kind, prop, v) else v
					end
				end
			end
		end
	end
end

-- Cinematic grade ----------------------------------------------------------------------------------------

export type CC = { brightness: number, contrast: number, saturation: number, tint: RGB }
export type Grade = {
	lift: CC, -- first CC layer: raises/tints the blacks (negative contrast + brightness)
	filmic: CC, -- second CC layer: S-curve contrast, saturation, warm highlights
	vignette: number, -- 0..1 edge darkening
	fringe: number, -- 0..1 chromatic edge fringe
	lens: number, -- 0..1 lens dirt strength when facing the sun / fire
	grain: number, -- 0..1 film grain strength
	fireTint: RGB, -- tint the fire glow pushes the screen towards
	shaft: RGB, -- light shaft colour
	wet: boolean, -- wet-road reflections on
}

function PostFx.neutralCC(): CC
	return { brightness = 0, contrast = 0, saturation = 0, tint = { r = 1, g = 1, b = 1 } }
end

local function cc(raw: any): CC
	raw = raw or {}
	return {
		brightness = raw.Brightness or raw.brightness or 0,
		contrast = raw.Contrast or raw.contrast or 0,
		saturation = raw.Saturation or raw.saturation or 0,
		tint = asRgb(raw.TintColor or raw.tint or "#FFFFFF"),
	}
end

-- Turns a config grade (hex colours, Roblox-cased CC keys) into a Grade; missing fields are neutral.
function PostFx.grade(raw: any): Grade
	raw = raw or {}
	return {
		lift = cc(raw.Lift),
		filmic = cc(raw.Filmic),
		vignette = raw.Vignette or 0,
		fringe = raw.Fringe or 0,
		lens = raw.Lens or 0,
		grain = raw.Grain or 0,
		fireTint = asRgb(raw.FireTint or "#FFB070"),
		shaft = asRgb(raw.Shaft or "#FFD8A8"),
		wet = raw.Wet == true,
	}
end

local function blendCC(a: CC, b: CC, t: number): CC
	return {
		brightness = PostFx.lerp(a.brightness, b.brightness, t),
		contrast = PostFx.lerp(a.contrast, b.contrast, t),
		saturation = PostFx.lerp(a.saturation, b.saturation, t),
		tint = PostFx.lerpRgb(a.tint, b.tint, t),
	}
end

function PostFx.blendGrade(a: Grade, b: Grade, t: number): Grade
	t = PostFx.clamp01(t)
	return {
		lift = blendCC(a.lift, b.lift, t),
		filmic = blendCC(a.filmic, b.filmic, t),
		vignette = PostFx.lerp(a.vignette, b.vignette, t),
		fringe = PostFx.lerp(a.fringe, b.fringe, t),
		lens = PostFx.lerp(a.lens, b.lens, t),
		grain = PostFx.lerp(a.grain, b.grain, t),
		fireTint = PostFx.lerpRgb(a.fireTint, b.fireTint, t),
		shaft = PostFx.lerpRgb(a.shaft, b.shaft, t),
		wet = if t >= 0.5 then b.wet else a.wet,
	}
end

-- Fades a grade towards neutral (w = 0 -> no grading). Used for the High tier (lighter grade).
function PostFx.scaleGrade(g: Grade, w: number): Grade
	local n = PostFx.neutralCC()
	w = PostFx.clamp01(w)
	return {
		lift = blendCC(n, g.lift, w),
		filmic = blendCC(n, g.filmic, w),
		vignette = g.vignette * w,
		fringe = g.fringe * w,
		lens = g.lens * w,
		grain = g.grain * w,
		fireTint = g.fireTint,
		shaft = g.shaft,
		wet = g.wet,
	}
end

-- Weights -----------------------------------------------------------------------------------------------

-- 0 below `from` studs/s, 1 at `full`, smoothstepped between.
function PostFx.motionWeight(speed: number, from: number, full: number): number
	if full <= from then
		return if speed >= from then 1 else 0
	end
	return PostFx.smoothstep((speed - from) / (full - from))
end

-- Lens dirt / glare weight. dot = camera look . direction-to-light (-1..1); visible 0..1 (sun above the
-- horizon / not indoors). power sharpens the cone (higher = only when looking right at it).
function PostFx.lensWeight(dot: number, visible: number, power: number): number
	if dot <= 0 then
		return 0
	end
	return PostFx.clamp01(dot ^ math.max(1, power)) * PostFx.clamp01(visible)
end

-- Screen fire glow 0..1 from nearby fire lights: each light adds brightness / (1 + (d / falloff)^2),
-- the sum is normalised by FullAt. lights = { { dist, brightness } } (brightness already flickering:
-- it is FireFxController's own PointLight.Brightness, read each frame, so the grade flickers in sync).
function PostFx.fireGlow(lights: { { number } }, cfg: any): number
	local falloff = cfg.GlowFalloff or 18
	local sum = 0
	for _, l in lights do
		local d, b = l[1], l[2]
		sum += b / (1 + (d / falloff) ^ 2)
	end
	return PostFx.clamp01(sum / (cfg.GlowFullAt or 6))
end

-- Film grain: `count` (2..20) NumberSequence keypoints { time, transparency }, time strictly increasing
-- from 0 to 1, transparency in [1 - maxAlpha, 1]. rand() -> [0, 1).
function PostFx.grainKeypoints(rand: () -> number, count: number, maxAlpha: number): { { number } }
	local n = math.clamp(math.floor(count), 2, 20)
	local a = PostFx.clamp01(maxAlpha)
	local out: { { number } } = {}
	for i = 1, n do
		local t: number
		if i == 1 then
			t = 0
		elseif i == n then
			t = 1
		else
			-- jittered but strictly increasing: slot i of n-1 gaps, jitter inside the slot
			t = ((i - 1) + (rand() - 0.5) * 0.8) / (n - 1)
		end
		table.insert(out, { t, 1 - a * rand() })
	end
	return out
end

-- Settings UI -------------------------------------------------------------------------------------------

local SETTING_NAMES = { [0] = "AUTO", [1] = "LOW", [2] = "HIGH", [3] = "ULTRA" }

function PostFx.nextSetting(setting: number?): number
	return (math.floor(tonumber(setting) or 0) + 1) % 4
end

function PostFx.settingLabel(setting: number?, tier: Tier): string
	local s = math.floor(tonumber(setting) or 0)
	if s >= 1 and s <= 3 then
		return `GRAPHICS: {SETTING_NAMES[s]}`
	end
	return `GRAPHICS: AUTO ({string.upper(tier)})`
end

return PostFx
