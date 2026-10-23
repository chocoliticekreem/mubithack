--!strict
-- ShaderConfig [owner: Graphics/shader lane]. The "shader pack" for ShaderController (client): graphics
-- quality tiers, per-tier preset modifiers, cinematic grades per atmosphere preset, screen overlays
-- (vignette, chromatic fringe, lens dirt, film grain, heat shimmer), motion feel, wet roads, light
-- shafts and the fire-glow grade. docs/game/09-graphics-ultra.md explains every block.
--
-- DATA ONLY: no requires, no Roblox APIs (colours are "#RRGGBB" strings) so game/tests/shader.spec.luau
-- can load it with the `luau` CLI. Tune live on the client:
--   require(game.ReplicatedStorage.Config.ShaderConfig).Set("GrainFps", 12)
-- Read values at use time (ShaderConfig.X), never cache them in module locals.

local ShaderConfig = {
	-- Persisted setting (ProfileSchema.Settings.graphicsQuality via Data/Setting; DataService mirrors it
	-- to the Player attr below). 0 = Auto, 1 = Low, 2 = High, 3 = Ultra.
	SettingKey = "graphicsQuality",
	SettingAttr = "GraphicsQuality",
	TierAttr = "GraphicsTier", -- LocalPlayer attr (client-local) with the effective tier, for tests / HUD

	-- Auto-detect (PostFx.detectTier) -------------------------------------------------------------------
	Detect = {
		LowMaxQuality = 3, -- Roblox graphics slider 1..3 -> Low
		UltraMinQuality = 8, -- slider 8..10 -> Ultra (Automatic = Ultra on desktop, High on mobile)
		MobileUltra = false, -- phones never auto-pick Ultra (they can still choose it in the menu)
		LowFps = 30, -- measured fps below this -> Low
		UltraFps = 50, -- below this -> at most High
		SampleSeconds = 4, -- fps is measured this long after spawn before the first real pick
	},
	-- Auto mode keeps watching fps (PostFx.adaptTier); a forced tier never changes by itself.
	Adapt = {
		DownFps = 38,
		DownSeconds = 8,
		UpFps = 58,
		UpSeconds = 30,
	},

	-- Per-tier feature budget. Low disables everything heavy (and global shadows).
	Budgets = {
		Low = {
			gradeWeight = 0, -- layered lift/filmic CC off
			overlays = false, -- vignette / fringe / lens / grain ScreenGui off
			grain = false,
			lens = false,
			haze = false, -- heat shimmer near fires
			motionDof = false, -- DoF pulse when moving fast
			driveFov = 0, -- extra FOV at full truck speed
			wetRoads = false,
			shafts = 0, -- volumetric light shafts through smoke (each = 2 Beams)
			fireGlow = false, -- screen grade flickering with FireFx lights
		},
		High = {
			gradeWeight = 0.6,
			overlays = true,
			grain = false,
			lens = false,
			haze = false,
			motionDof = false,
			driveFov = 8,
			wetRoads = true,
			shafts = 0,
			fireGlow = true,
		},
		Ultra = {
			gradeWeight = 1,
			overlays = true,
			grain = true,
			lens = true,
			haze = true,
			motionDof = true,
			driveFov = 12,
			wetRoads = true,
			shafts = 3,
			fireGlow = true,
		},
	} :: { [string]: { [string]: any } },

	-- Modifiers applied on top of the AtmosphereConfig preset GraphicsController is blending
	-- (PostFx.applyMods: mul, then add, then set). High = the preset as authored.
	TierMods = {
		Low = {
			Lighting = { set = { GlobalShadows = false }, mul = { EnvironmentSpecularScale = 0.5 } },
			Bloom = { set = { Enabled = false } },
			SunRays = { set = { Enabled = false } },
			DepthOfField = { set = { Enabled = false } },
			Clouds = { mul = { Density = 0.8 } },
		},
		High = {},
		Ultra = {
			-- fire glow: a lower threshold lets flames (LightEmission/Neon) bloom, walls stay clean
			Bloom = { mul = { Intensity = 1.3 }, add = { Size = 8, Threshold = -0.15 } },
			SunRays = { mul = { Intensity = 1.6 }, add = { Spread = 0.05 } },
			Atmosphere = { mul = { Haze = 1.15 }, add = { Glare = 0.15, Density = 0.03 } },
			Clouds = { add = { Density = 0.08 } },
			Lighting = { add = { EnvironmentSpecularScale = 0.25, EnvironmentDiffuseScale = 0.1 }, mul = { ShadowSoftness = 0.8 } },
			DepthOfField = { set = { Enabled = true }, add = { FarIntensity = 0.06 } },
		},
	} :: { [string]: any },

	-- Cinematic grade per AtmosphereConfig preset name. Two stacked ColorCorrections:
	--   Lift   (first)  = negative contrast + a little brightness lifts the blacks; its tint colours them.
	--   Filmic (second) = positive contrast (S-curve), saturation, warm highlight tint.
	-- Vignette/Fringe/Lens/Grain are 0..1 overlay strengths; FireTint is where fire glow pushes the grade;
	-- Shaft is the light-shaft colour; Wet = glossy wet-road reflections (night / rain looks).
	Grades = {
		Default = {
			Lift = { Brightness = 0.015, Contrast = -0.05, Saturation = 0, TintColor = "#F6F8FF" },
			Filmic = { Brightness = -0.01, Contrast = 0.12, Saturation = 0.08, TintColor = "#FFF8EE" },
			Vignette = 0.35,
			Fringe = 0.25,
			Lens = 0.5,
			Grain = 0.35,
			FireTint = "#FFB070",
			Shaft = "#FFD8A8",
			Wet = false,
		},
		StationGolden = {
			Lift = { Brightness = 0.02, Contrast = -0.06, Saturation = 0, TintColor = "#F2F4FF" },
			Filmic = { Brightness = -0.01, Contrast = 0.14, Saturation = 0.1, TintColor = "#FFF1DE" },
			Vignette = 0.3,
			Fringe = 0.2,
			Lens = 0.7,
			Grain = 0.3,
			FireTint = "#FFB070",
			Shaft = "#FFD39A",
			Wet = false,
		},
		DuskSuburb = { -- teal shadows / orange highlights, the trailer look
			Lift = { Brightness = 0.02, Contrast = -0.08, Saturation = 0, TintColor = "#E8F4FF" },
			Filmic = { Brightness = -0.015, Contrast = 0.16, Saturation = 0.12, TintColor = "#FFEBD6" },
			Vignette = 0.4,
			Fringe = 0.3,
			Lens = 0.8,
			Grain = 0.35,
			FireTint = "#FFA860",
			Shaft = "#FFC890",
			Wet = false,
		},
		NightStreet = { -- blue night, fires are the key light, wet asphalt
			Lift = { Brightness = 0.025, Contrast = -0.1, Saturation = 0, TintColor = "#DCE8FF" },
			Filmic = { Brightness = -0.02, Contrast = 0.2, Saturation = 0.12, TintColor = "#F4F2FF" },
			Vignette = 0.55,
			Fringe = 0.35,
			Lens = 0.6,
			Grain = 0.5,
			FireTint = "#FF9A50",
			Shaft = "#9FB8FF",
			Wet = true,
		},
		SchoolInterior = {
			Lift = { Brightness = 0.01, Contrast = -0.04, Saturation = 0, TintColor = "#F4F8FF" },
			Filmic = { Brightness = 0, Contrast = 0.1, Saturation = 0.04, TintColor = "#FAFCFF" },
			Vignette = 0.25,
			Fringe = 0.15,
			Lens = 0.3,
			Grain = 0.25,
			FireTint = "#FFB878",
			Shaft = "#F4F0E0",
			Wet = false,
		},
		GoldenFarm = {
			Lift = { Brightness = 0.02, Contrast = -0.06, Saturation = 0, TintColor = "#F6F2FF" },
			Filmic = { Brightness = -0.01, Contrast = 0.14, Saturation = 0.14, TintColor = "#FFEED2" },
			Vignette = 0.35,
			Fringe = 0.25,
			Lens = 0.9,
			Grain = 0.35,
			FireTint = "#FFAA5A",
			Shaft = "#FFD08A",
			Wet = false,
		},
		FireGlow = { -- smoky burning forest: crushed warm blacks, heavy glow
			Lift = { Brightness = 0.015, Contrast = -0.05, Saturation = 0, TintColor = "#FFE8DC" },
			Filmic = { Brightness = -0.02, Contrast = 0.18, Saturation = 0.1, TintColor = "#FFDCC0" },
			Vignette = 0.5,
			Fringe = 0.35,
			Lens = 1,
			Grain = 0.45,
			FireTint = "#FF8A40",
			Shaft = "#FFB070",
			Wet = false,
		},
		StorageOvercast = {
			Lift = { Brightness = 0.02, Contrast = -0.06, Saturation = 0, TintColor = "#EEF4F8" },
			Filmic = { Brightness = -0.01, Contrast = 0.14, Saturation = -0.04, TintColor = "#F2F6FA" },
			Vignette = 0.4,
			Fringe = 0.25,
			Lens = 0.3,
			Grain = 0.45,
			FireTint = "#FFB070",
			Shaft = "#E0E6EE",
			Wet = true, -- damp overcast concrete
		},
		DamNight = {
			Lift = { Brightness = 0.025, Contrast = -0.1, Saturation = 0, TintColor = "#D8F0F4" },
			Filmic = { Brightness = -0.02, Contrast = 0.22, Saturation = 0.08, TintColor = "#EEF8FF" },
			Vignette = 0.55,
			Fringe = 0.35,
			Lens = 0.6,
			Grain = 0.5,
			FireTint = "#FF9050",
			Shaft = "#A8D0E0",
			Wet = true,
		},
		ZooDay = {
			Lift = { Brightness = 0.01, Contrast = -0.04, Saturation = 0, TintColor = "#F4FAFF" },
			Filmic = { Brightness = 0, Contrast = 0.1, Saturation = 0.1, TintColor = "#FFFBF0" },
			Vignette = 0.25,
			Fringe = 0.15,
			Lens = 0.7,
			Grain = 0.2,
			FireTint = "#FFB878",
			Shaft = "#FFF0C8",
			Wet = false,
		},
	} :: { [string]: any },
	GradeBlendSeconds = 2.5, -- matches AtmosphereConfig.TweenSeconds so grade and lighting move together

	-- Screen overlays (ScreenGui "ShaderFx", below the HUD) ------------------------------------------------
	OverlayDisplayOrder = -10,
	VignetteColor = "#0A0608",
	VignetteMaxAlpha = 0.55, -- edge opacity at Vignette = 1
	VignetteDepth = 0.28, -- fraction of the screen each edge gradient covers
	FringeMaxAlpha = 0.12, -- red (left/right) + cyan (top/bottom) edge fringe opacity at Fringe = 1
	LensBlobs = 7, -- procedural lens-dirt smudges (ignored when Images.LensDirt is set)
	LensMaxAlpha = 0.22,
	LensPower = 6, -- higher = only when looking almost straight at the sun
	LensFireBoost = 0.6, -- fire glow also lights up the dirt
	GrainFps = 24, -- how often the grain pattern re-rolls
	GrainKeypoints = 18,
	GrainMaxAlpha = 0.07, -- per-keypoint opacity at Grain = 1 (subtle!)
	-- Optional image ids (rbxassetid://...). Empty = procedural fallback (no assets needed).
	Images = {
		LensDirt = "", -- full-screen lens dirt texture
		Grain = "", -- tileable noise texture
	} :: { [string]: string },

	-- Heat shimmer near fires (Ultra) ---------------------------------------------------------------------
	HazeRadius = 20, -- camera within this of a Burning part starts the shimmer
	HazeFullAt = 6, -- that many close fires = full shimmer
	HazeBlur = 2.5, -- BlurEffect size at full shimmer (oscillates)
	HazeHz = 7,
	HazeTint = "#FFB070",
	HazeMaxAlpha = 0.12, -- warm wavy band at the bottom of the screen

	-- Fire glow grade (CC "Shader_FireGlow", flickers with FireFxController's own PointLights) -----------
	FireGlow = {
		Radius = 60, -- lights considered (read-only: FireFx owns and flickers them; we never add lights)
		MaxLights = 6,
		GlowFalloff = 18,
		GlowFullAt = 6,
		TintStrength = 0.35, -- how far white -> FireTint at full glow
		Brightness = 0.05,
	},

	-- Motion feel ---------------------------------------------------------------------------------------------
	MotionFrom = 16, -- camera studs/s where motion blur starts (sprint ~20, truck up to ~90)
	MotionFull = 70,
	MotionResponse = 4, -- per-second smoothing
	MotionDof = { FarIntensity = 0.4, FocusDistance = 35, InFocusRadius = 25, NearIntensity = 0.15 },
	DriveFovFrom = 10, -- truck speed (studs/s) where the driving FOV kick starts
	DriveFovFull = 80,

	-- Wet roads (night grades, High+) -------------------------------------------------------------------------
	WetReflectance = 0.14,
	WetMaxParts = 600,
	WetScanSeconds = 20, -- rescan Workspace.Map for new road parts this often
	WetNamePatterns = { "road", "street", "asphalt", "avenue", "lane", "intersection", "crosswalk", "parking" } :: { string },

	-- Volumetric light shafts through smoke (Ultra) -------------------------------------------------------
	ShaftRadius = 150, -- fires within this of the camera can get a shaft
	ShaftCluster = 30, -- fires closer than this share one shaft
	ShaftHeight = 22, -- shaft top above the fire, along the light direction
	ShaftWidth0 = 5,
	ShaftWidth1 = 12,
	ShaftAlpha = 0.16, -- peak opacity in the middle of the beam (gradient fades both ends)
	ShaftNightScale = 0.5, -- moonlight shafts are dimmer

	SampleHz = 4, -- fires / lights / shafts re-sampled this often
}

-- Same contract as Shared/Config.define (kept inline so this module has no requires).
;(ShaderConfig :: any).Set = function(key: string, value: any)
	if (ShaderConfig :: any)[key] == nil then
		error(`[Config] unknown key {key}`)
	end
	(ShaderConfig :: any)[key] = value
end

return ShaderConfig
