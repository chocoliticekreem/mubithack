--!strict
-- WeatherController [owner: CityBuilder / map variety]. Client-only weather effects for the server's
-- map weather (Workspace attr MapWeather, rolled per server by MapService / Lib/Map/City/MapVariant).
-- The lighting side (fog, overcast, rain darkening) is GraphicsController's AtmosphereConfig.Weather
-- overlay; this adds what lighting can't:
--   Rain: a sheet of rain streaks (ParticleEmitter, AtmosphereConfig.Rain) that follows the camera,
--         paused while the camera is under a roof (indoors / in the truck cab under the station roof).
-- The emitter part lives under the CurrentCamera (local, never replicated, not a map part).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AtmosphereConfig") :: ModuleScript) :: any

local WeatherController = {}
WeatherController.Priority = 25

local rainPart: Part? = nil
local emitter: ParticleEmitter? = nil
local indoors = false

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude
params.IgnoreWater = true

local function makeRain(): (Part, ParticleEmitter)
	local rc = Cfg.Rain or {}
	local area = rc.Area or 140
	local p = Instance.new("Part")
	p.Name = "ForgeRain"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = Vector3.new(area, 1, area)
	local e = Instance.new("ParticleEmitter")
	e.Name = "Rain"
	e.EmissionDirection = Enum.NormalId.Bottom
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.Rate = rc.Rate or 500
	e.Lifetime = NumberRange.new(rc.Lifetime or 1.1)
	e.Speed = NumberRange.new(rc.Speed or 95)
	e.Orientation = Enum.ParticleOrientation.FacingCameraWorldUp
	e.Size = NumberSequence.new(rc.Size or 0.5)
	e.Squash = NumberSequence.new(1.5) -- squashed sideways, stretched down: streaks
	e.Color = ColorSequence.new(rc.Color or Color3.fromRGB(201, 216, 238))
	e.Transparency = NumberSequence.new(rc.Transparency or 0.45)
	e.LightEmission = 0.15
	e.LightInfluence = 0.8
	e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	e.Parent = p
	return p, e
end

local function setWeather()
	local w = workspace:GetAttribute("MapWeather")
	if w == "Rain" then
		if not rainPart then
			rainPart, emitter = makeRain()
		end
	elseif rainPart then
		rainPart:Destroy()
		rainPart, emitter = nil, nil
	end
end

function WeatherController:Init(_controllers: { [string]: any }) end

function WeatherController:Start()
	setWeather()
	workspace:GetAttributeChangedSignal("MapWeather"):Connect(setWeather)
	local lastRoof = 0
	RunService.RenderStepped:Connect(function()
		local p, e = rainPart, emitter
		local cam = workspace.CurrentCamera
		if not (p and e and cam) then
			return
		end
		local pos = cam.CFrame.Position
		local rc = Cfg.Rain or {}
		p.CFrame = CFrame.new(pos + Vector3.new(0, rc.Height or 45, 0) + cam.CFrame.LookVector * 20)
		if p.Parent ~= cam then
			p.Parent = cam
		end
		if os.clock() - lastRoof > 0.5 then
			lastRoof = os.clock()
			local ignore: { Instance } = { p }
			for _, pl in Players:GetPlayers() do
				if pl.Character then
					table.insert(ignore, pl.Character)
				end
			end
			params.FilterDescendantsInstances = ignore
			local hit = workspace:Raycast(pos, Vector3.new(0, Cfg.RoofCheck or 45, 0), params)
			indoors = hit ~= nil and hit.Instance.Transparency < 0.9
			e.Enabled = not indoors
		end
	end)
end

function WeatherController:IsIndoors(): boolean
	return indoors
end

return WeatherController
