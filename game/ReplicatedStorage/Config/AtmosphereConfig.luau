--!strict
-- AtmosphereConfig [owner: G2 / AV lane]. Lighting presets (docs/game/02-art-feel-ui.md §2) and the
-- client graphics settings (GraphicsController).
--
-- Each preset is a plain table of property -> value per instance kind. AtmosphereService (server) and
-- GraphicsController (client) apply them to game.Lighting, its effect children (Forge_Atmosphere,
-- Forge_Sky, Forge_ColorCorrection, Forge_Bloom, Forge_SunRays, Forge_DepthOfField) and
-- Workspace.Terrain.Forge_Clouds. Every preset sets the same full property list, so switching presets
-- (or blending between two on the client) never leaves values from the previous one behind.
-- Values marked "(doc)" are copied from docs/game/02; the rest are tuned by eye to match.
--
-- Per-location looks: GraphicsController picks LocationPresets[<the location the player is in>]
-- (instance Model attr LocationId via Player.InstanceId, else the Workspace.Map location around the
-- camera) and blends to it locally, so parallel squads each see their own mission's look.
-- Graphics tiers (ShaderController / ShaderConfig.TierMods) modify these on each client: High = the
-- preset as written here, Low strips shadows/bloom/sunrays/DoF, Ultra boosts bloom/haze/glare and adds
-- the layered cinematic grade (ShaderConfig.Grades[<preset name>]). Keep preset names in sync with Grades.
-- Tune live (client copy): require(game.ReplicatedStorage.Config.AtmosphereConfig).Set("TweenSeconds", 1)
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local hex = Color3.fromHex

export type Props = { [string]: any }
export type Preset = {
	Lighting: Props,
	Atmosphere: Props,
	Sky: Props,
	Clouds: Props,
	ColorCorrection: Props,
	Bloom: Props,
	SunRays: Props,
	DepthOfField: Props,
}

-- Legacy fog stays out of the way in every preset: Atmosphere does the haze.
local NO_FOG = 100000

-- Subtle far-only blur: softens the horizon, never blurs what you play near (research: DoF off in
-- gameplay; this keeps it barely-there). InFocusRadius maxes out at 50 in the engine (150 was silently
-- clamped), so the focus sits further out: sharp to ~160 studs. ShaderController pulses it with speed.
local function dof(far: number): Props
	return { Enabled = true, FarIntensity = far, FocusDistance = 110, InFocusRadius = 50, NearIntensity = 0 }
end

local Presets: { [string]: Preset } = {
	-- Fire Station 67 / lobby: golden hour, warm and welcoming, long soft shadows through the bay doors.
	StationGolden = {
		Lighting = {
			ClockTime = 17.0,
			GeographicLatitude = 35,
			Brightness = 2.6,
			ExposureCompensation = 0.05,
			Ambient = hex("4A3A36"),
			OutdoorAmbient = hex("A08070"),
			ColorShift_Top = hex("FFC890"),
			ColorShift_Bottom = hex("4A5A7A"),
			EnvironmentDiffuseScale = 0.7,
			EnvironmentSpecularScale = 0.4,
			ShadowSoftness = 0.3,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.27, Offset = 0.18, Color = hex("F0B680"), Decay = hex("7A5050"), Glare = 0.5, Haze = 1.4 },
		Sky = { SunAngularSize = 14, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true },
		Clouds = { Enabled = true, Cover = 0.5, Density = 0.55, Color = hex("FFE0C0") },
		ColorCorrection = { Enabled = true, Brightness = 0.02, Contrast = 0.1, Saturation = 0.15, TintColor = hex("FFF2E0") },
		Bloom = { Enabled = true, Intensity = 0.5, Size = 26, Threshold = 1.7 },
		SunRays = { Enabled = true, Intensity = 0.1, Spread = 0.55 },
		DepthOfField = dof(0.05),
	},

	-- Town (house_fire): dusk suburb (s2 c5-6, s6 c2) [v1]. Teal sky, orange horizon, warm low sun.
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
			EnvironmentSpecularScale = 0.4, -- (doc 0.25) more sheen on windows/cars under the low sun
			ShadowSoftness = 0.3, -- (doc 0.35) slightly crisper sunset shadows
			GlobalShadows = true, -- (doc)
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.30, Offset = 0.20, Color = hex("E8A46E"), Decay = hex("5A3D52"), Glare = 0.45, Haze = 1.8 }, -- (doc)
		Sky = { SunAngularSize = 16, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true }, -- (doc)
		Clouds = { Enabled = true, Cover = 0.55, Density = 0.6, Color = hex("E8B8A0") },
		ColorCorrection = { Enabled = true, Brightness = 0.02, Contrast = 0.12, Saturation = 0.18, TintColor = hex("FFF0DE") }, -- (doc)
		Bloom = { Enabled = true, Intensity = 0.6, Size = 28, Threshold = 1.6 }, -- (doc) only Neon/fire blooms
		SunRays = { Enabled = true, Intensity = 0.08, Spread = 0.6 }, -- (doc)
		DepthOfField = dof(0.06),
	},

	-- Apartment block at night (s2 c7-8, s4 c2-5) [v1]. Fires are the key light.
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
			EnvironmentSpecularScale = 0.6, -- wet-road reflections (ShaderController) need specular
			ShadowSoftness = 0.25,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.36, Offset = 0.10, Color = hex("2D3E66"), Decay = hex("0B1530"), Glare = 0, Haze = 0.8 }, -- (doc)
		Sky = { SunAngularSize = 16, MoonAngularSize = 11, StarCount = 3000, CelestialBodiesShown = true }, -- big cartoon moon
		Clouds = { Enabled = true, Cover = 0.35, Density = 0.4, Color = hex("3A4366") },
		ColorCorrection = { Enabled = true, Brightness = 0, Contrast = 0.15, Saturation = 0.10, TintColor = hex("DCE4FF") }, -- (doc)
		Bloom = { Enabled = true, Intensity = 0.95, Size = 34, Threshold = 1.15 }, -- (doc 0.9/32/1.2) fire is the key light
		SunRays = { Enabled = true, Intensity = 0, Spread = 0.6 }, -- (doc)
		DepthOfField = dof(0.05),
	},

	-- School: bright afternoon seen through windows, interiors lit flat and cool like fluorescent tubes.
	SchoolInterior = {
		Lighting = {
			ClockTime = 14.2,
			GeographicLatitude = 30,
			Brightness = 2.0,
			ExposureCompensation = 0.35,
			Ambient = hex("5A5E66"),
			OutdoorAmbient = hex("9AA0A8"),
			ColorShift_Top = hex("FFF4E0"),
			ColorShift_Bottom = hex("5A6070"),
			EnvironmentDiffuseScale = 0.8,
			EnvironmentSpecularScale = 0.4,
			ShadowSoftness = 0.5,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.22, Offset = 0.05, Color = hex("C8D0D8"), Decay = hex("808890"), Glare = 0, Haze = 0.6 },
		Sky = { SunAngularSize = 12, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true },
		Clouds = { Enabled = true, Cover = 0.7, Density = 0.5, Color = hex("F0F0F0") },
		ColorCorrection = { Enabled = true, Brightness = 0.02, Contrast = 0.08, Saturation = -0.05, TintColor = hex("F4F8FF") },
		Bloom = { Enabled = true, Intensity = 0.4, Size = 24, Threshold = 1.8 },
		SunRays = { Enabled = true, Intensity = 0.03, Spread = 0.5 },
		DepthOfField = dof(0.04),
	},

	-- Farm / field: golden late afternoon (s5 c2-4, s6 c7) [v2] -- (doc) "Golden Farm".
	GoldenFarm = {
		Lighting = {
			ClockTime = 16.3, -- (doc)
			GeographicLatitude = 30,
			Brightness = 2.6, -- (doc)
			ExposureCompensation = 0.05,
			Ambient = hex("4A3A2A"), -- (doc)
			OutdoorAmbient = hex("B08A60"), -- (doc)
			ColorShift_Top = hex("FFC27A"),
			ColorShift_Bottom = hex("6A5A3A"),
			EnvironmentDiffuseScale = 0.65,
			EnvironmentSpecularScale = 0.3,
			ShadowSoftness = 0.3,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.28, Offset = 0.25, Color = hex("F2C38A"), Decay = hex("8A5A3A"), Glare = 0.6, Haze = 1.2 }, -- (doc)
		Sky = { SunAngularSize = 18, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true },
		Clouds = { Enabled = true, Cover = 0.45, Density = 0.5, Color = hex("FFE6C0") },
		ColorCorrection = { Enabled = true, Brightness = 0, Contrast = 0.10, Saturation = 0.22, TintColor = hex("FFF2D8") }, -- (doc)
		Bloom = { Enabled = true, Intensity = 0.5, Size = 24, Threshold = 1.8 }, -- (doc)
		SunRays = { Enabled = true, Intensity = 0.12, Spread = 0.5 }, -- (doc)
		DepthOfField = dof(0.07),
	},

	-- Forest: smoky dusk, orange smoke-haze sky, everything warm, fires glow hard.
	-- The doc's "Burning Forest" preset [v2] (lighting/atmosphere/CC/bloom are (doc) from there).
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
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.48, Offset = 0.0, Color = hex("E07A3A"), Decay = hex("6A2A1A"), Glare = 0.2, Haze = 3.0 }, -- (doc)
		Sky = { SunAngularSize = 20, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true }, -- swollen red sun
		Clouds = { Enabled = true, Cover = 0.8, Density = 0.75, Color = hex("8A5A48") },
		ColorCorrection = { Enabled = true, Brightness = 0, Contrast = 0.08, Saturation = 0.05, TintColor = hex("FFD2A8") }, -- (doc)
		Bloom = { Enabled = true, Intensity = 1.0, Size = 36, Threshold = 1.1 }, -- (doc)
		SunRays = { Enabled = true, Intensity = 0.14, Spread = 0.55 }, -- god rays through the smoke
		DepthOfField = dof(0.1),
	},

	-- Storage units: flat grey overcast afternoon, desaturated, heavy cloud. The fuse box sparks pop.
	StorageOvercast = {
		Lighting = {
			ClockTime = 15.5,
			GeographicLatitude = 45,
			Brightness = 1.3,
			ExposureCompensation = 0.15,
			Ambient = hex("4A4E55"),
			OutdoorAmbient = hex("7E848C"),
			ColorShift_Top = hex("C8D0D8"),
			ColorShift_Bottom = hex("3A4048"),
			EnvironmentDiffuseScale = 0.7,
			EnvironmentSpecularScale = 0.3,
			ShadowSoftness = 0.6,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.4, Offset = 0.12, Color = hex("A0A8B0"), Decay = hex("5A6068"), Glare = 0, Haze = 1.6 },
		Sky = { SunAngularSize = 10, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true },
		Clouds = { Enabled = true, Cover = 0.95, Density = 0.85, Color = hex("B4B8BE") },
		ColorCorrection = { Enabled = true, Brightness = 0, Contrast = 0.1, Saturation = -0.15, TintColor = hex("E8EEF4") },
		Bloom = { Enabled = true, Intensity = 0.5, Size = 28, Threshold = 1.5 },
		SunRays = { Enabled = true, Intensity = 0, Spread = 0.5 },
		DepthOfField = dof(0.06),
	},

	-- Dam finale: cold blue night, distant city fires glow hard (s7 c2-8) [v2] -- (doc) "Dam Night".
	DamNight = {
		Lighting = {
			ClockTime = 20.5, -- (doc)
			GeographicLatitude = 30,
			Brightness = 0.9, -- (doc)
			ExposureCompensation = 0.2,
			Ambient = hex("1A2A33"), -- (doc)
			OutdoorAmbient = hex("24414A"), -- (doc)
			ColorShift_Top = hex("6A90B0"),
			ColorShift_Bottom = hex("000000"),
			EnvironmentDiffuseScale = 0.4,
			EnvironmentSpecularScale = 0.55, -- wet concrete / water sheen
			ShadowSoftness = 0.25,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.35, Offset = 0.15, Color = hex("1E3A44"), Decay = hex("0D1C24"), Glare = 0, Haze = 1.2 }, -- (doc)
		Sky = { SunAngularSize = 16, MoonAngularSize = 10, StarCount = 2500, CelestialBodiesShown = true },
		Clouds = { Enabled = true, Cover = 0.4, Density = 0.5, Color = hex("2A3A48") },
		ColorCorrection = { Enabled = true, Brightness = 0, Contrast = 0.18, Saturation = 0.05, TintColor = hex("CFEFF0") }, -- (doc)
		Bloom = { Enabled = true, Intensity = 1.0, Size = 40, Threshold = 1.0 }, -- (doc)
		SunRays = { Enabled = true, Intensity = 0, Spread = 0.5 },
		DepthOfField = dof(0.08),
	},

	-- Zoo: bright late-morning day, saturated and cheerful (panda rescue).
	ZooDay = {
		Lighting = {
			ClockTime = 11.5,
			GeographicLatitude = 25,
			Brightness = 3.0,
			ExposureCompensation = 0,
			Ambient = hex("5A5A50"),
			OutdoorAmbient = hex("A0A090"),
			ColorShift_Top = hex("FFF4D8"),
			ColorShift_Bottom = hex("5A7A50"),
			EnvironmentDiffuseScale = 0.8,
			EnvironmentSpecularScale = 0.5,
			ShadowSoftness = 0.25,
			GlobalShadows = true,
			FogEnd = NO_FOG,
			FogStart = 0,
		},
		Atmosphere = { Density = 0.24, Offset = 0.1, Color = hex("C8E0F0"), Decay = hex("7A9AB0"), Glare = 0.3, Haze = 0.8 },
		Sky = { SunAngularSize = 12, MoonAngularSize = 8, StarCount = 0, CelestialBodiesShown = true },
		Clouds = { Enabled = true, Cover = 0.45, Density = 0.4, Color = hex("FFFFFF") },
		ColorCorrection = { Enabled = true, Brightness = 0.02, Contrast = 0.1, Saturation = 0.25, TintColor = hex("FFFCF2") },
		Bloom = { Enabled = true, Intensity = 0.35, Size = 22, Threshold = 2.0 },
		SunRays = { Enabled = true, Intensity = 0.08, Spread = 0.4 },
		DepthOfField = dof(0.03),
	},
}

-- Client overlays blended on top of the current preset by GraphicsController (weight 0..1).
-- Only the listed keys are touched. docs/game/02 §2 "Interior overlays".
local Overlays = {
	-- Camera indoors next to fires (doc: "Smoke-filled room", inferred from nearby Burning parts +
	-- a roof raycast instead of hand-placed BurningRoom zones).
	Smoke = {
		Atmosphere = { Density = 0.62, Color = hex("6A645C"), Decay = hex("3A3530"), Haze = 2.5, Glare = 0 }, -- (doc)
		ColorCorrection = { Saturation = -0.2, Brightness = -0.05, Contrast = 0.18, TintColor = hex("E8DCCC") }, -- (doc) sat/brightness
		Bloom = { Intensity = 1.1, Threshold = 1.0 }, -- flames bleed through the smoke
	},
	-- Player attr Heat (HeatService) -> warm grade (doc: "Heat: CC TintColor -> #FFD9B0").
	Heat = {
		ColorCorrection = { TintColor = hex("FFC9A0"), Contrast = 0.2, Saturation = 0.25 },
	},
}

return Config.define({
	Default = "StationGolden", -- server-side preset at boot (the lobby look; clients refine per location)
	-- Location -> preset. Keys are LocationIds (MissionCatalog `locationId`, Workspace.Map children).
	-- A MissionCatalog entry's own `atmosphere` wins over this table (AtmosphereService:ApplyMission).
	LocationPresets = {
		Station = "StationGolden",
		Town = "DuskSuburb",
		Apartment = "NightStreet",
		School = "SchoolInterior",
		Farm = "GoldenFarm",
		Field = "GoldenFarm",
		Forest = "FireGlow",
		Storage = "StorageOvercast",
		Dam = "DamNight",
		Zoo = "ZooDay",
	} :: { [string]: string },
	-- Lighting engine: `Lighting.Technology` (Future) is deprecated by Unified Lighting and neither it
	-- nor `LightingStyle`/`PrioritizeLightingQuality` is settable from game scripts. The service tries
	-- them in a pcall and warns once; set them in Studio (Lighting > LightingStyle = Realistic,
	-- PrioritizeLightingQuality = true; or Technology = Future on older Studio). Realistic/Future is
	-- what makes fire PointLights cast shadows. Fall back to ShadowMap if fps < 50 with 10+ fires.
	Technology = "Future",
	LightingStyle = "Realistic",
	Presets = Presets,
	Overlays = Overlays,

	-- GraphicsController (client) ------------------------------------------------------------------
	TweenSeconds = 2.5, -- blend time when the player's preset changes (teleport into a mission)
	LocationHz = 2, -- how often the player's location is re-resolved
	LocationMargin = 40, -- studs around a Workspace.Map location's bounding box that still count as "in" it
	SmokeHz = 5, -- how often nearby fires are counted
	SmokeRadius = 22, -- Burning parts within this of the camera count toward the smoke overlay
	SmokeFullAt = 5, -- that many nearby fires indoors = full smoke overlay
	RoofCheck = 45, -- studs straight up from the camera; a hit = "indoors"
	OverlayResponse = 2.5, -- per-second smoothing rate for overlay weights (higher = snappier)
	HeatOverlay = false, -- FirstPersonController's FirstPersonHeatCC already tints for Heat; true = also blend Overlays.Heat
	HeatFrom = 25, -- Heat below this adds no tint; at 100 the Heat overlay is full

	-- Client material pass: upgrades SmoothPlastic parts in the player's location to real materials.
	-- MaterialVariants can't be authored from scripts (their texture maps are not scriptable), so this
	-- only swaps the built-in Enum.Material, which already looks far less "plastic" under Realistic
	-- lighting. A part's own attribute `MaterialHint` (an Enum.Material name) wins over the name rules.
	-- Rules match the part Name (case-insensitive substring, first match wins). Client-local only.
	MaterialPass = {
		Enabled = true,
		PerFrame = 250, -- parts examined per frame (pass is chunked so it never hitches)
		Rules = {
			{ "road", "Asphalt" },
			{ "asphalt", "Asphalt" },
			{ "street", "Asphalt" },
			{ "sidewalk", "Pavement" },
			{ "pavement", "Pavement" },
			{ "kerb", "Concrete" },
			{ "curb", "Concrete" },
			{ "driveway", "Concrete" },
			{ "foundation", "Concrete" },
			{ "grass", "Grass" },
			{ "lawn", "Grass" },
			{ "hedge", "LeafyGrass" },
			{ "bush", "LeafyGrass" },
			{ "roof", "RoofShingles" },
			{ "floor", "WoodPlanks" },
			{ "plank", "WoodPlanks" },
			{ "deck", "WoodPlanks" },
			{ "fence", "WoodPlanks" },
			{ "picket", "Wood" },
			{ "post", "Wood" },
			{ "rug", "Fabric" },
			{ "carpet", "Carpet" },
			{ "sofa", "Fabric" },
			{ "couch", "Fabric" },
			{ "bed", "Fabric" },
			{ "brick", "Brick" },
			{ "chimney", "Brick" },
			{ "coping", "Concrete" },
			{ "poolfloor", "CeramicTiles" },
			{ "tile", "CeramicTiles" },
			{ "wall", "Plaster" },
			{ "rollup", "CorrodedMetal" },
			{ "garage", "Concrete" },
		} :: { { string } },
	},
})
