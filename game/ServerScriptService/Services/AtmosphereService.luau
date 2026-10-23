--!strict
-- AtmosphereService [owner: G2]. Applies lighting presets from Config/AtmosphereConfig to game.Lighting.
-- API:
--   AtmosphereService:Apply(presetName: string, tweenTime: number?): boolean
--   AtmosphereService.ApplyPreset(presetName: string, tweenTime: number?): boolean
--     Pure function on Lighting, no yields, works in the Edit datamodel (preview the look in Studio):
--       require(game.ServerScriptService.Services.AtmosphereService).ApplyPreset("DuskSuburb")
--   AtmosphereService:GetPreset(): string?   current preset name (also Lighting attribute "AtmospherePreset")
-- Effects live under Lighting as Forge_Atmosphere, Forge_Sky, Forge_ColorCorrection, Forge_Bloom,
-- Forge_SunRays, Forge_DepthOfField. Created idempotently: an existing Forge_<Kind> is reused, and a
-- Studio default with the plain name (e.g. "Bloom", "Sky") is adopted and renamed instead of doubled.
-- Lighting.Technology = Future is attempted in a pcall (needs plugin identity; see AtmosphereConfig).
-- Priority 1: Start applies AtmosphereConfig.Default right after MapService begins.
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local AtmosphereConfig =
	require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AtmosphereConfig") :: ModuleScript)

local AtmosphereService = {}
AtmosphereService.Priority = 1

local PRESET_ATTR = "AtmospherePreset"

-- Kind (preset table key) -> ClassName. Order = apply order.
local KINDS: { { kind: string, class: string } } = {
	{ kind = "Atmosphere", class = "Atmosphere" },
	{ kind = "Sky", class = "Sky" },
	{ kind = "ColorCorrection", class = "ColorCorrectionEffect" },
	{ kind = "Bloom", class = "BloomEffect" },
	{ kind = "SunRays", class = "SunRaysEffect" },
	{ kind = "DepthOfField", class = "DepthOfFieldEffect" },
}

-- Find Forge_<Kind>, else adopt a Studio default (named like the kind or its class), else create.
local function ensure(kind: string, class: string): Instance
	local name = "Forge_" .. kind
	local existing = Lighting:FindFirstChild(name)
	if existing and existing:IsA(class) then
		return existing
	end
	for _, child in Lighting:GetChildren() do
		if child:IsA(class) and (child.Name == kind or child.Name == class) then
			child.Name = name
			return child
		end
	end
	local inst = Instance.new(class)
	inst.Name = name
	inst.Parent = Lighting
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

local function trySetTechnology()
	local tech = AtmosphereConfig.Technology
	if type(tech) ~= "string" then
		return
	end
	local ok, enumItem = pcall(function()
		return (Enum.Technology :: any)[tech]
	end)
	if not ok or enumItem == nil or Lighting.Technology == enumItem then
		return
	end
	local set = pcall(function()
		(Lighting :: any).Technology = enumItem
	end)
	if not set then
		warn(
			`[AtmosphereService] Lighting.Technology is {Lighting.Technology.Name}; scripts cannot set it. `
				.. `Set it to {tech} in Studio (Lighting > Technology) for fire point-light shadows.`
		)
	end
end

-- Pure (no yields, no service state). Safe from the command bar / execute_luau in Edit mode.
function AtmosphereService.ApplyPreset(presetName: string, tweenTime: number?): boolean
	local preset = AtmosphereConfig.Presets[presetName]
	if not preset then
		warn(`[AtmosphereService] unknown preset {presetName}`)
		return false
	end
	trySetTechnology()
	setProps(Lighting, preset.Lighting, tweenTime)
	for _, k in KINDS do
		local props = (preset :: any)[k.kind]
		if props then
			setProps(ensure(k.kind, k.class), props, tweenTime)
		end
	end
	Lighting:SetAttribute(PRESET_ATTR, presetName)
	return true
end

function AtmosphereService:Apply(presetName: string, tweenTime: number?): boolean
	return AtmosphereService.ApplyPreset(presetName, tweenTime)
end

function AtmosphereService:GetPreset(): string?
	local v = Lighting:GetAttribute(PRESET_ATTR)
	return if type(v) == "string" then v else nil
end

function AtmosphereService:Start()
	local name = AtmosphereConfig.Default
	if AtmosphereService.ApplyPreset(name) then
		print(`[AtmosphereService] applied {name}`)
	end
end

function AtmosphereService._selftest(): boolean
	return Lighting:GetAttribute(PRESET_ATTR) ~= nil and Lighting:FindFirstChild("Forge_Atmosphere") ~= nil
end

return AtmosphereService
