--!strict
-- AtmosphereConfig [owner: G2]. Lighting presets (docs/game/02-art-feel-ui.md §2).
-- Each preset is a plain table of property -> value per instance kind. AtmosphereService applies
-- them to game.Lighting and to its effect children (Forge_Atmosphere, Forge_Sky, Forge_ColorCorrection,
-- Forge_Bloom, Forge_SunRays, Forge_DepthOfField). Every preset sets the full property list, so
-- switching presets never leaves values from the previous one behind.
-- Values marked "(doc)" are copied from docs/game/02; the rest are filled in by eye to match.
-- Tune live: ServerStorage.DevHook:Invoke("AtmosphereConfig", ".Set", "Default", "NightStreet")
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local hex = Color3.fromHex

export type Preset = {
	Lighting: { [string]: any },
	Atmosphere: { [string]: any },
	Sky: { [string]: any },
	ColorCorrection: { [string]: any },
	Bloom: { [string]: any },
	SunRays: { [string]: any },
	DepthOfField: { [string]: any },
}

local Presets: { [string]: Preset } = {
	-- Default mission look (s2 c5-6, s6 c2) [v1]. Teal sky, orange horizon, warm low sun.
	DuskSuburb = {
		Lighting = {
			ClockTime = 17.6, -- (doc)
			GeographicLatitude = 30, -- (doc)
			Brightness = 2.2, -- (doc)
			ExposureCompensation = 0.1, -- (doc)
			Ambient = hex("3A2A33"), -- (doc)
			OutdoorAmbient = hex("8A6A70"), -- (doc)
			ColorShift_Top = hex("FFB07A"), -- (doc)
			ColorShift_Bottom = hex("3A5A7A"), -- (doc)
			EnvironmentDiffuseScale = 0.6, -- (doc)
			EnvironmentSpecularScale = 0.25, -- (doc)
			ShadowSoftness = 0.35, -- (doc)
			GlobalShadows = true, -- (doc)
			FogEnd = 100000, -- Atmosphere does the fog; keep legacy fog out of the way
			FogStart = 0,
		},
		Atmosphere = {
			Density = 0.30, -- (doc)
			Offset = 0.20, -- (doc)
			Color = hex("E8A46E"), -- (doc)
			Decay = hex("5A3D52"), -- (doc)
			Glare = 0.45, -- (doc)
			Haze = 1.8, -- (doc)
		},
		Sky = {
			SunAngularSize = 16, -- (doc)
			MoonAngularSize = 8, -- (doc)
			StarCount = 0, -- (doc)
			CelestialBodiesShown = true, -- (doc)
		},
		ColorCorrection = {
			Enabled = true,
			Brightness = 0.02, -- (doc)
			Contrast = 0.12, -- (doc)
			Saturation = 0.18, -- (doc)
			TintColor = hex("FFF0DE"), -- (doc)
		},
		Bloom = {
			Enabled = true,
			Intensity = 0.6, -- (doc) only Neon/fire blooms at this threshold
			Size = 28, -- (doc)
			Threshold = 1.6, -- (doc)
		},
		SunRays = {
			Enabled = true,
			Intensity = 0.08, -- (doc)
			Spread = 0.6, -- (doc)
		},
		DepthOfField = {
			-- Doc calls DoF optional and gives no values: a faint far blur that softens the horizon
			-- without blurring anything you play near.
			Enabled = true,
			FarIntensity = 0.08,
			FocusDistance = 80,
			InFocusRadius = 140,
			NearIntensity = 0,
		},
	},

	-- Night street / apartment block (s2 c7-8, s4 c2-5) [v1]. Fires are the key light.
	NightStreet = {
		Lighting = {
			ClockTime = 21.5, -- (doc)
			GeographicLatitude = 30,
			Brightness = 0.8, -- (doc)
			ExposureCompensation = 0.2, -- (doc)
			Ambient = hex("1E2236"), -- (doc)
			OutdoorAmbient = hex("2B3558"), -- (doc)
			ColorShift_Top = hex("6A80C0"), -- (doc)
			ColorShift_Bottom = hex("000000"), -- (doc)
			EnvironmentDiffuseScale = 0.4,
			EnvironmentSpecularScale = 0.3,
			ShadowSoftness = 0.25,
			GlobalShadows = true,
			FogEnd = 100000,
			FogStart = 0,
		},
		Atmosphere = {
			Density = 0.36, -- (doc)
			Offset = 0.10, -- (doc)
			Color = hex("2D3E66"), -- (doc)
			Decay = hex("0B1530"), -- (doc)
			Glare = 0, -- (doc)
			Haze = 0.8, -- (doc)
		},
		Sky = {
			SunAngularSize = 16,
			MoonAngularSize = 11, -- a big cartoon moon
			StarCount = 3000, -- (doc)
			CelestialBodiesShown = true,
		},
		ColorCorrection = {
			Enabled = true,
			Brightness = 0,
			Contrast = 0.15, -- (doc)
			Saturation = 0.10, -- (doc)
			TintColor = hex("DCE4FF"), -- (doc)
		},
		Bloom = {
			Enabled = true,
			Intensity = 0.9, -- (doc)
			Size = 32, -- (doc)
			Threshold = 1.2, -- (doc)
		},
		SunRays = {
			Enabled = true,
			Intensity = 0, -- (doc)
			Spread = 0.6,
		},
		DepthOfField = {
			Enabled = true,
			FarIntensity = 0.06,
			FocusDistance = 80,
			InFocusRadius = 140,
			NearIntensity = 0,
		},
	},

	-- Big-blaze look: orange smoke-haze sky, everything warm, fires glow hard.
	-- Based on the doc's "Burning Forest" preset [v2] (lighting/atmosphere/CC/bloom are (doc) from there).
	FireGlow = {
		Lighting = {
			ClockTime = 18.4, -- (doc)
			GeographicLatitude = 30,
			Brightness = 1.6, -- (doc)
			ExposureCompensation = 0.1,
			Ambient = hex("4A2A20"), -- (doc)
			OutdoorAmbient = hex("8A4A30"), -- (doc)
			ColorShift_Top = hex("FF9A5A"),
			ColorShift_Bottom = hex("5A2A1A"),
			EnvironmentDiffuseScale = 0.5,
			EnvironmentSpecularScale = 0.25,
			ShadowSoftness = 0.4,
			GlobalShadows = true,
			FogEnd = 100000,
			FogStart = 0,
		},
		Atmosphere = {
			Density = 0.48, -- (doc)
			Offset = 0.0, -- (doc)
			Color = hex("E07A3A"), -- (doc)
			Decay = hex("6A2A1A"), -- (doc)
			Glare = 0.2, -- (doc)
			Haze = 3.0, -- (doc)
		},
		Sky = {
			SunAngularSize = 20, -- a swollen red sun through the smoke
			MoonAngularSize = 8,
			StarCount = 0,
			CelestialBodiesShown = true,
		},
		ColorCorrection = {
			Enabled = true,
			Brightness = 0,
			Contrast = 0.08, -- (doc)
			Saturation = 0.05, -- (doc)
			TintColor = hex("FFD2A8"), -- (doc)
		},
		Bloom = {
			Enabled = true,
			Intensity = 1.0, -- (doc)
			Size = 36, -- (doc)
			Threshold = 1.1, -- (doc)
		},
		SunRays = {
			Enabled = true,
			Intensity = 0.1,
			Spread = 0.5,
		},
		DepthOfField = {
			Enabled = true,
			FarIntensity = 0.12,
			FocusDistance = 70,
			InFocusRadius = 110,
			NearIntensity = 0,
		},
	},
}

return Config.define({
	Default = "DuskSuburb", -- preset AtmosphereService:Start applies
	-- Doc wants Future (fires cast point-light shadows). Lighting.Technology is not settable from
	-- game scripts (it needs plugin/command-bar identity), so the service tries it in a pcall; set it
	-- in Studio once (Lighting > Technology) or via execute_luau in Edit mode. Fall back to
	-- "ShadowMap" if a playtest drops below 50 fps with 10+ fires.
	Technology = "Future",
	Presets = Presets,
})
