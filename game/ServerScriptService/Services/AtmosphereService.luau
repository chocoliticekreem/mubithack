--!strict
-- AtmosphereService [owner: G2 / AV lane]. Applies lighting presets from Config/AtmosphereConfig to
-- game.Lighting. The server only sets the *baseline* look (the lobby, plus whatever a v1 caller asks
-- for); GraphicsController on each client then blends to the preset of the location that player is
-- in, so parallel squads each see their own mission's look (Lighting is server-global).
-- API:
--   AtmosphereService:Apply(presetName: string, tweenTime: number?): boolean
--   AtmosphereService.ApplyPreset(presetName: string, tweenTime: number?): boolean
--     Pure function on Lighting, no yields, works in the Edit datamodel (preview the look in Studio):
--       require(game.ServerScriptService.Services.AtmosphereService).ApplyPreset("DuskSuburb")
--   AtmosphereService:GetPreset(): string?   current preset name (also Lighting attribute "AtmospherePreset")
--   v1.5 additions:
--   AtmosphereService:ApplyLocation(locationId: string, tweenTime: number?): boolean
--     preset = AtmosphereConfig.LocationPresets[locationId] or Default; sets Lighting attr LocationPreset
--   AtmosphereService:ApplyMission(missionId: string, tweenTime: number?): boolean
--     preset = MissionCatalog entry's `atmosphere` (else its location's); sets LocationPreset
--   AtmosphereService:SetPlayerPreset(player: Player, presetName: string?)   [AV addition]
--     per-player override (Player attr AtmospherePreset; nil/"" clears). GraphicsController prefers it
--     over the location look (e.g. a cutscene or the results podium).
-- At runtime the server applies instantly: a server tween replicates every step and would fight the
-- clients' own blends. tweenTime is honoured only in the Edit datamodel (previewing).
-- Effects live under Lighting as Forge_Atmosphere, Forge_Sky, Forge_ColorCorrection, Forge_Bloom,
-- Forge_SunRays, Forge_DepthOfField, plus Workspace.Terrain.Forge_Clouds. Created idempotently: an
-- existing Forge_<Kind> is reused, and a Studio default with the plain name (e.g. "Bloom", "Sky") is
-- adopted and renamed instead of doubled.
-- Lighting engine (LightingStyle Realistic / Technology Future) is attempted in a pcall; it needs
-- Studio identity, so set it once in Studio (see AtmosphereConfig.Technology).
-- Priority 1: Start applies AtmosphereConfig.Default right after MapService begins.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local AtmosphereConfig =
	require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AtmosphereConfig") :: ModuleScript) :: any

local AtmosphereService = {}
AtmosphereService.Priority = 1

local PRESET_ATTR = "AtmospherePreset"
local LOCATION_ATTR = "LocationPreset" -- Names.Attr.LocationPreset

-- Kind (preset table key) -> ClassName. Order = apply order. Clouds live under Terrain.
local KINDS: { { kind: string, class: string } } = {
	{ kind = "Atmosphere", class = "Atmosphere" },
	{ kind = "Sky", class = "Sky" },
	{ kind = "Clouds", class = "Clouds" },
	{ kind = "ColorCorrection", class = "ColorCorrectionEffect" },
	{ kind = "Bloom", class = "BloomEffect" },
	{ kind = "SunRays", class = "SunRaysEffect" },
	{ kind = "DepthOfField", class = "DepthOfFieldEffect" },
}

local function parentFor(class: string): Instance?
	if class == "Clouds" then
		return workspace:FindFirstChildOfClass("Terrain")
	end
	return Lighting
end

-- Find Forge_<Kind>, else adopt a Studio default (named like the kind or its class), else create.
local function ensure(kind: string, class: string): Instance?
	local parent = parentFor(class)
	if not parent then
		return nil
	end
	local name = "Forge_" .. kind
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA(class) then
		return existing
	end
	for _, child in parent:GetChildren() do
		if child:IsA(class) and (child.Name == kind or child.Name == class) then
			child.Name = name
			return child
		end
	end
	local inst = Instance.new(class)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function tweenable(v: any): boolean
	local t = typeof(v)
	return t == "number" or t == "Color3"
end

local function setProps(inst: Instance, props: { [string]: any }, tweenTime: number?)
	local goals: { [string]: any } = {}
	for prop, value in props do
		if tweenTime and tweenTime > 0 and tweenable(value) and not inst:IsA("Sky") then
			goals[prop] = value
		else
			local ok, err = pcall(function()
				(inst :: any)[prop] = value
			end)
			if not ok then
				warn(`[AtmosphereService] {inst.Name}.{prop}: {err}`)
			end
		end
	end
	if next(goals) ~= nil then
		local ok, err = pcall(function()
			TweenService:Create(inst, TweenInfo.new(tweenTime :: number, Enum.EasingStyle.Sine), goals):Play()
		end)
		if not ok then
			warn(`[AtmosphereService] tween {inst.Name}: {err}`)
		end
	end
end

local engineTried = false

-- Try the Unified Lighting settings (LightingStyle + PrioritizeLightingQuality); only if this engine
-- has no LightingStyle, fall back to the legacy Technology. Every read and write is pcall'd: game
-- scripts usually lack the identity for these. Tried once per VM; a failure is a print (not a warn,
-- so ForgeProbe stays clean) with the manual Studio fix.
local function trySetEngine()
	if engineTried then
		return
	end
	engineTried = true
	local style = AtmosphereConfig.LightingStyle
	local hasStyle = pcall(function()
		return (Enum :: any).LightingStyle
	end) and (Enum :: any).LightingStyle ~= nil
	if hasStyle and type(style) == "string" then
		local ok = pcall(function()
			local item = (Enum :: any).LightingStyle[style]
			if (Lighting :: any).LightingStyle ~= item then
				(Lighting :: any).LightingStyle = item
			end
			if (Lighting :: any).PrioritizeLightingQuality ~= true then
				(Lighting :: any).PrioritizeLightingQuality = true
			end
		end)
		if not ok then
			print(
				`[AtmosphereService] note: set Lighting.LightingStyle = {style} and PrioritizeLightingQuality = true `
					.. `in Studio (not settable from scripts) for fire point-light shadows.`
			)
		end
		return
	end
	local tech = AtmosphereConfig.Technology
	if type(tech) == "string" then
		local ok = pcall(function()
			local item = (Enum.Technology :: any)[tech]
			if (Lighting :: any).Technology ~= item then
				(Lighting :: any).Technology = item
			end
		end)
		if not ok then
			print(`[AtmosphereService] note: set Lighting.Technology = {tech} in Studio (not settable from scripts).`)
		end
	end
end

local function isEditPreview(): boolean
	return not RunService:IsRunning()
end

-- Pure (no yields, no service state). Safe from the command bar / execute_luau in Edit mode.
function AtmosphereService.ApplyPreset(presetName: string, tweenTime: number?): boolean
	local preset = AtmosphereConfig.Presets[presetName]
	if not preset then
		warn(`[AtmosphereService] unknown preset {presetName}`)
		return false
	end
	trySetEngine()
	setProps(Lighting, preset.Lighting, tweenTime)
	for _, k in KINDS do
		local props = (preset :: any)[k.kind]
		local inst = props and ensure(k.kind, k.class)
		if inst then
			setProps(inst, props, tweenTime)
		end
	end
	Lighting:SetAttribute(PRESET_ATTR, presetName)
	return true
end

local function runtimeTween(tweenTime: number?): number?
	return if isEditPreview() then tweenTime else nil
end

function AtmosphereService:Apply(presetName: string, tweenTime: number?): boolean
	return AtmosphereService.ApplyPreset(presetName, runtimeTween(tweenTime))
end

function AtmosphereService:GetPreset(): string?
	local v = Lighting:GetAttribute(PRESET_ATTR)
	return if type(v) == "string" then v else nil
end

function AtmosphereService:ApplyLocation(locationId: string, tweenTime: number?): boolean
	local presets = AtmosphereConfig.LocationPresets or {}
	local name = presets[locationId] or AtmosphereConfig.Default
	local ok = AtmosphereService.ApplyPreset(name, runtimeTween(tweenTime))
	if ok then
		Lighting:SetAttribute(LOCATION_ATTR, locationId)
	end
	return ok
end

function AtmosphereService:ApplyMission(missionId: string, tweenTime: number?): boolean
	local catalog = ReplicatedStorage:WaitForChild("Config"):FindFirstChild("MissionCatalog")
	if not catalog then
		return false
	end
	for _, m in require(catalog :: ModuleScript) :: { any } do
		if m.id == missionId then
			if type(m.atmosphere) == "string" and AtmosphereConfig.Presets[m.atmosphere] then
				AtmosphereService.ApplyPreset(m.atmosphere, runtimeTween(tweenTime))
				Lighting:SetAttribute(LOCATION_ATTR, m.locationId)
				return true
			end
			return AtmosphereService:ApplyLocation(m.locationId, tweenTime)
		end
	end
	warn(`[AtmosphereService] unknown mission {missionId}`)
	return false
end

function AtmosphereService:SetPlayerPreset(player: Player, presetName: string?)
	if presetName and presetName ~= "" and not AtmosphereConfig.Presets[presetName] then
		warn(`[AtmosphereService] SetPlayerPreset: unknown preset {presetName}`)
		return
	end
	player:SetAttribute(PRESET_ATTR, if presetName == "" then nil else presetName)
end

function AtmosphereService:Start()
	local name = AtmosphereConfig.Default
	if AtmosphereService.ApplyPreset(name) then
		Lighting:SetAttribute(LOCATION_ATTR, "Station")
		print(`[AtmosphereService] applied {name}`)
	end
end

function AtmosphereService._selftest(): (boolean, string)
	local preset = Lighting:GetAttribute(PRESET_ATTR)
	local ok = preset ~= nil and Lighting:FindFirstChild("Forge_Atmosphere") ~= nil
	-- every location maps to a real preset, and every preset sets every kind
	for loc, name in AtmosphereConfig.LocationPresets do
		if not AtmosphereConfig.Presets[name] then
			return false, `location {loc} -> unknown preset {name}`
		end
	end
	for name, p in AtmosphereConfig.Presets do
		for _, k in KINDS do
			if (p :: any)[k.kind] == nil then
				return false, `preset {name} misses {k.kind}`
			end
		end
	end
	return ok, `preset {tostring(preset)}`
end

return AtmosphereService
