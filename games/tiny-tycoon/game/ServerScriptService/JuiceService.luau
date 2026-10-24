--!strict
-- JuiceService: server side of the juice/polish pass.
-- Sets up lighting, the JuiceFx / JuiceAck remotes, and fires juice events to clients.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")

local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets"))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))

local JuiceService = {}

local ACK_COOLDOWN = 5

local inited = false
local fxRemote: RemoteEvent? = nil
local ackRemote: RemoteEvent? = nil
local lastAck: { [Player]: number } = {}

local function ensureRemote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = ReplicatedStorage
	return r
end

local function fire(player: Player, payload: { [string]: any })
	if not fxRemote or not player or player.Parent ~= Players then
		return
	end
	fxRemote:FireClient(player, payload)
	ForgeTelemetry.count("juice_events", 1)
end

local function toPart(inst: any): BasePart?
	if typeof(inst) ~= "Instance" then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
		return inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- Adds a Sky (if none), a SunRaysEffect and softer environment lighting.
-- Runs after GameAssets.styleLighting.
local function applySkyAndRays()
	if not Lighting:FindFirstChildOfClass("Sky") then
		local sky = Instance.new("Sky")
		sky.Name = "ForgeSky"
		sky.SunAngularSize = 14
		sky.MoonAngularSize = 11
		sky.StarCount = 3000
		sky.CelestialBodiesShown = true
		sky.Parent = Lighting
	end

	local rays = Lighting:FindFirstChildOfClass("SunRaysEffect")
	if not rays then
		local newRays = Instance.new("SunRaysEffect")
		newRays.Name = "ForgeSunRays"
		newRays.Intensity = 0.06
		newRays.Spread = 0.6
		newRays.Parent = Lighting
	else
		rays.Intensity = 0.06
		rays.Spread = 0.6
	end

	Lighting.EnvironmentDiffuseScale = 0.5
	Lighting.EnvironmentSpecularScale = 0.5
end

function JuiceService.init()
	if inited then
		return
	end
	inited = true

	local ok, err = pcall(function()
		GameAssets.styleLighting()
	end)
	if not ok then
		warn("[JuiceService] styleLighting failed: " .. tostring(err))
	end

	local okSky, errSky = pcall(applySkyAndRays)
	if not okSky then
		warn("[JuiceService] sky setup failed: " .. tostring(errSky))
	end

	fxRemote = ensureRemote("JuiceFx")
	local ack = ensureRemote("JuiceAck")
	ackRemote = ack

	ack.OnServerEvent:Connect(function(player: Player, payload: any)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		if type(payload) ~= "table" or payload.kind ~= "income" then
			return
		end
		local now = os.clock()
		local last = lastAck[player]
		if last and now - last < ACK_COOLDOWN then
			return
		end
		lastAck[player] = now
		ForgeTelemetry.count("income_shown", 1)
	end)

	Players.PlayerRemoving:Connect(function(player: Player)
		lastAck[player] = nil
	end)
end

-- upgrade: entry from Upgrades data. padPart: the pad touched. newDropperModel: the dropper
-- that was just unlocked (Model or BasePart) or nil.
function JuiceService.onPurchase(player: Player, upgrade: any, padPart: any, newDropperModel: any)
	if type(upgrade) ~= "table" then
		return
	end
	local dropperPart = toPart(newDropperModel)
	if dropperPart then
		local ok, err = pcall(function()
			GameAssets.popIn(dropperPart)
		end)
		if not ok then
			warn("[JuiceService] popIn failed: " .. tostring(err))
		end
	end

	local name = tostring(upgrade.name or upgrade.id or "Upgrade")
	local pos: Vector3? = nil
	if typeof(padPart) == "Instance" and padPart:IsA("BasePart") then
		pos = padPart.Position
	end
	fire(player, { kind = "buy", name = name, pos = pos })

	local isOre = upgrade.ore or upgrade.oreTier or upgrade.isOre
	if isOre then
		local value = upgrade.oreValue or upgrade.value or 0
		fire(player, { kind = "ore", name = name, value = value })
	end
end

function JuiceService.onInsufficient(player: Player, upgrade: any, shortfall: number)
	if type(shortfall) ~= "number" or shortfall ~= shortfall then
		return
	end
	fire(player, { kind = "poor", need = math.max(0, math.ceil(shortfall)) })
end

function JuiceService.onRebirth(player: Player)
	fire(player, { kind = "rebirth" })
end

function JuiceService.pushGoal(player: Player, name: string?, cost: number?)
	if name == nil or cost == nil then
		fire(player, { kind = "goal" })
		return
	end
	fire(player, { kind = "goal", name = name, cost = cost })
end

return JuiceService
