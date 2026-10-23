--!strict
-- studio_graphics_setup.luau: run ONCE in Roblox Studio, in the EDIT datamodel (Command Bar, or
-- StudioMCP execute_luau with datamodel "Edit"), then save/publish the place.
-- Sets the place-level graphics settings that game scripts cannot change at runtime (they need plugin /
-- command-bar security): lighting engine, PBR materials, terrain water + grass, streaming tuning.
-- Everything per-location (ClockTime, Atmosphere, Bloom, grading...) is applied at runtime by
-- AtmosphereService / GraphicsController / ShaderController, so it is NOT set here.
-- Idempotent: safe to run again. Each setting is pcall'd; the returned report says what stuck.
-- Docs: docs/game/09-graphics-ultra.md §"One-time Studio setup".

-- Streaming changes how much of the map exists on each client. Our client code (GraphicsController map
-- boxes, minimap, wet roads) expects the whole small map, so we leave StreamingEnabled as it is unless
-- this is flipped on deliberately (e.g. the 1200x1200 v2 city gets heavy on phones).
local ENABLE_STREAMING = false

local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local Workspace = game:GetService("Workspace")

local report: { string } = {}

local function try(label: string, fn: () -> ())
	local ok, err = pcall(fn)
	table.insert(report, (if ok then "ok   " else "FAIL ") .. label .. (if ok then "" else ": " .. tostring(err)))
end

-- 1. Lighting engine -------------------------------------------------------------------------------------
-- Unified Lighting: LightingStyle Realistic = Future-quality local lights + shadows from fire PointLights.
-- PrioritizeLightingQuality keeps shadows/shading quality on weak devices (they drop view distance first).
try("Lighting.LightingStyle = Realistic", function()
	(Lighting :: any).LightingStyle = (Enum :: any).LightingStyle.Realistic
end)
try("Lighting.PrioritizeLightingQuality = true", function()
	(Lighting :: any).PrioritizeLightingQuality = true
end)
-- Older Studio builds without Unified Lighting: Technology = Future does the same job.
if not table.find(report, "ok   Lighting.LightingStyle = Realistic") then
	try("Lighting.Technology = Future (fallback)", function()
		(Lighting :: any).Technology = Enum.Technology.Future
	end)
end
-- Baselines (runtime presets override these per location; set so Edit mode previews look right).
try("Lighting.GlobalShadows = true", function()
	Lighting.GlobalShadows = true
end)
try("Lighting.ShadowSoftness = 0.25", function()
	Lighting.ShadowSoftness = 0.25
end)
try("Lighting.EnvironmentDiffuseScale = 0.7", function()
	Lighting.EnvironmentDiffuseScale = 0.7
end)
try("Lighting.EnvironmentSpecularScale = 0.6", function()
	Lighting.EnvironmentSpecularScale = 0.6
end)

-- 2. Materials ----------------------------------------------------------------------------------------------
-- 2022 PBR materials: Asphalt/Concrete/Brick/WoodPlanks get real normal + roughness maps (the biggest
-- single "not plastic" upgrade; also what makes the wet-road reflectance read as glossy asphalt).
try("MaterialService.Use2022Materials = true", function()
	(MaterialService :: any).Use2022Materials = true
end)

-- 3. Terrain: water + grass decoration ------------------------------------------------------------------------
local terrain = Workspace:FindFirstChildOfClass("Terrain")
if terrain then
	try("Terrain.Decoration = true (animated grass)", function()
		(terrain :: any).Decoration = true
	end)
	try("Terrain water (reflective, gentle waves)", function()
		terrain.WaterColor = Color3.fromRGB(32, 74, 88)
		terrain.WaterReflectance = 1
		terrain.WaterTransparency = 0.35
		terrain.WaterWaveSize = 0.12
		terrain.WaterWaveSpeed = 8
	end)
else
	table.insert(report, "skip Terrain (none)")
end

-- 4. Workspace / streaming ------------------------------------------------------------------------------------
if ENABLE_STREAMING then
	try("Workspace.StreamingEnabled = true", function()
		Workspace.StreamingEnabled = true
	end)
end
if Workspace.StreamingEnabled then
	try("Streaming radii (min 192, target 768) + Opportunistic stream-out", function()
		Workspace.StreamingMinRadius = 192
		Workspace.StreamingTargetRadius = 768
		Workspace.StreamOutBehavior = Enum.StreamOutBehavior.Opportunistic
	end)
else
	table.insert(report, "skip streaming radii (StreamingEnabled is off; flip ENABLE_STREAMING to enable)")
end

-- 5. Leftover Studio defaults that fight the runtime look ------------------------------------------------------
-- A default "Sky"/"Atmosphere"/"Bloom" etc. is adopted (renamed Forge_*) by AtmosphereService, so we keep
-- them. Legacy fog is disabled by every preset. Nothing to delete here.

print("[studio_graphics_setup]\n" .. table.concat(report, "\n"))
return table.concat(report, "\n")
