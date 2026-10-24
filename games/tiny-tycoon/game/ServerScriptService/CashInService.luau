--!strict
-- CashInService: server-side owner of cash-in / purchase feedback.
-- Sends display data only to clients; never changes cash.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

local CashInConfig = require(ReplicatedStorage:WaitForChild("CashInConfig", 10))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 10))
local TutorialService = require(script.Parent:WaitForChild("TutorialService", 10))

local Cfg: any = CashInConfig

local FLASH_COLOR = Color3.fromRGB(255, 214, 64)
local FLASH_TIME = 0.15
local IMMEDIATE_SENDS = 5 -- first cubes per player always send immediately (never throttled)

-- Optional GameAssets (burst at the intake); never required to succeed.
local GameAssets: any = nil
do
	local mod = ReplicatedStorage:FindFirstChild("GameAssets")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok then
			GameAssets = res
		end
	end
end

local function getOrCreateRemote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = ReplicatedStorage
	return remote
end

local CashInRemote = getOrCreateRemote(Cfg.CASHIN_REMOTE or "CashInFX")
local PurchaseRemote = getOrCreateRemote(Cfg.PURCHASE_REMOTE or "PurchaseFX")

local CashInService = {}

type CollectorInfo = {
	part: BasePart,
	baseColor: Color3,
	emitter: ParticleEmitter,
	tween: Tween?,
}

local collectors: { CollectorInfo } = {}
local sendLog: { [Player]: { number } } = {}
local sentTotal: { [Player]: number } = {}
local lastScan = 0

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

local function toSoundIdString(v: any): string
	if type(v) == "string" then
		return v
	elseif type(v) == "number" and v > 0 then
		return "rbxassetid://" .. tostring(math.floor(v))
	elseif type(v) == "table" then
		local inner = v.SoundId or v.Id or v.id or v.soundId
		if inner ~= nil and inner ~= v then
			return toSoundIdString(inner)
		end
	end
	return ""
end

-- Try to find the sound id for a director sound name (e.g. "Coin") in GameAssets.
local function assetSoundId(name: string): string
	if GameAssets == nil then
		return ""
	end
	local ok, res = pcall(function(): string
		local ga: any = GameAssets
		for _, key in ipairs({ "Sounds", "sounds", "SOUNDS" }) do
			local tbl = ga[key]
			if type(tbl) == "table" then
				local s = toSoundIdString(tbl[name])
				if s ~= "" then
					return s
				end
			end
		end
		return ""
	end)
	if ok and type(res) == "string" then
		return res
	end
	return ""
end

local function configSoundId(): string
	local s = toSoundIdString(Cfg.CASHIN_SOUND_ID)
	if s ~= "" then
		return s
	end
	return assetSoundId("Coin")
end

local function pitchForTier(tier: number): number
	local fn = Cfg.pitchForTier
	if type(fn) == "function" then
		local ok, res = pcall(fn, tier)
		if ok and isFiniteNumber(res) then
			return res
		end
	end
	return math.clamp(1 + 0.12 * (tier - 1), 0.5, 2)
end

local function isRegistered(part: BasePart): boolean
	for _, info in ipairs(collectors) do
		if info.part == part then
			return true
		end
	end
	return false
end

-- Fallback discovery: decorate any workspace part that looks like a collector
-- if nothing has been registered through decorateCollector yet.
local function scanForCollectors()
	local now = os.clock()
	if now - lastScan < 2 then
		return
	end
	lastScan = now
	for _, d in ipairs(workspace:GetDescendants()) do
		if d:IsA("BasePart") and string.find(string.lower(d.Name), "collector", 1, true) then
			if not string.find(d.Name, "CashIn", 1, true) and not isRegistered(d) then
				CashInService.decorateCollector(d)
			end
		end
	end
end

local function findCollector(pos: Vector3): CollectorInfo?
	local best: CollectorInfo? = nil
	local bestDist = math.huge
	for i = #collectors, 1, -1 do
		local info = collectors[i]
		if info.part.Parent == nil then
			table.remove(collectors, i)
		else
			local d = (info.part.Position - pos).Magnitude
			if d < bestDist then
				bestDist = d
				best = info
			end
		end
	end
	if best == nil and #collectors > 0 then
		best = collectors[#collectors]
	end
	return best
end

local function playCoin(part: BasePart, pitch: number)
	local snd = part:FindFirstChild("CashInSound")
	if not (snd and snd:IsA("Sound")) then
		local s = Instance.new("Sound")
		s.Name = "CashInSound"
		s.Volume = 0.5
		s.SoundId = configSoundId()
		s.Parent = part
		snd = s
	end
	local sound = snd :: Sound
	if sound.SoundId == "" then
		local id = configSoundId()
		if id ~= "" then
			sound.SoundId = id
		end
	end
	if sound.SoundId ~= "" then
		sound.PlaybackSpeed = pitch
		local ok = pcall(function()
			sound:Play()
		end)
		if ok then
			ForgeTelemetry.count("sounds_played", 1)
			return
		end
	end
	-- Fallback: let GameAssets play the Coin tick.
	if GameAssets and type(GameAssets.play) == "function" then
		local ok = pcall(function()
			GameAssets.play("Coin")
		end)
		if ok then
			ForgeTelemetry.count("sounds_played", 1)
			return
		end
	end
	ForgeTelemetry.count("cashin_sound_missing", 1)
end

local function flashCollector(info: CollectorInfo, pitch: number)
	local part = info.part
	if part.Parent == nil then
		return
	end
	if info.tween then
		info.tween:Cancel()
	end
	part.Color = FLASH_COLOR
	local tween = TweenService:Create(part, TweenInfo.new(FLASH_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = info.baseColor,
	})
	info.tween = tween
	tween:Play()
	info.emitter:Emit(4)

	-- Pitched Coin tick on the collector itself.
	playCoin(part, pitch)
end

local function allowSend(player: Player): boolean
	local maxPerSec: number = 8
	if isFiniteNumber(Cfg.MAX_POPUPS_PER_SECOND) and Cfg.MAX_POPUPS_PER_SECOND > 0 then
		maxPerSec = Cfg.MAX_POPUPS_PER_SECOND
	end
	local now = os.clock()
	local log = sendLog[player]
	if not log then
		log = {}
		sendLog[player] = log
	end
	local kept: { number } = {}
	for _, ts in ipairs(log) do
		if now - ts < 1 then
			table.insert(kept, ts)
		end
	end
	if #kept >= maxPerSec then
		sendLog[player] = kept
		return false
	end
	table.insert(kept, now)
	sendLog[player] = kept
	return true
end

Players.PlayerRemoving:Connect(function(p)
	sendLog[p] = nil
	sentTotal[p] = nil
end)

function CashInService.decorateCollector(collectorPart: BasePart)
	if typeof(collectorPart) ~= "Instance" or not collectorPart:IsA("BasePart") then
		return
	end
	if isRegistered(collectorPart) then
		return
	end

	-- Particle emitter used for the per-collect sparkle (created first so it always exists).
	local emitter = collectorPart:FindFirstChild("CashInEmitter")
	if not (emitter and emitter:IsA("ParticleEmitter")) then
		local e = Instance.new("ParticleEmitter")
		e.Name = "CashInEmitter"
		e.Rate = 0
		e.Enabled = false
		e.Lifetime = NumberRange.new(0.4, 0.8)
		e.Speed = NumberRange.new(6, 12)
		e.SpreadAngle = Vector2.new(60, 60)
		e.Acceleration = Vector3.new(0, -8, 0)
		e.Color = ColorSequence.new(FLASH_COLOR)
		e.LightEmission = 1
		e.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 0),
		})
		e.Parent = collectorPart
		emitter = e
	end

	-- Register right away so a later error can't leave the collector unflashed.
	table.insert(collectors, {
		part = collectorPart,
		baseColor = collectorPart.Color,
		emitter = emitter :: ParticleEmitter,
		tween = nil,
	})

	if not collectorPart:FindFirstChild("CashInLight") then
		local light = Instance.new("PointLight")
		light.Name = "CashInLight"
		light.Color = if typeof(Cfg.LIGHT_COLOR) == "Color3" then Cfg.LIGHT_COLOR else FLASH_COLOR
		light.Brightness = if isFiniteNumber(Cfg.LIGHT_BRIGHTNESS) then Cfg.LIGHT_BRIGHTNESS else 1.5
		light.Range = if isFiniteNumber(Cfg.LIGHT_RANGE) then Cfg.LIGHT_RANGE else 12
		light.Parent = collectorPart
	end

	-- Sound object on the collector (pitched by tier when a cube is cashed in).
	if not collectorPart:FindFirstChild("CashInSound") then
		local snd = Instance.new("Sound")
		snd.Name = "CashInSound"
		local id = configSoundId()
		if id ~= "" then
			snd.SoundId = id
		end
		snd.Volume = 0.5
		snd.Parent = collectorPart
	end

	local ring = Instance.new("Part")
	ring.Name = "CashInRing"
	ring.Shape = Enum.PartType.Cylinder
	-- Cylinder axis is X; rotate so the ring lies flat (axis pointing up).
	local diameter = math.max(collectorPart.Size.X, collectorPart.Size.Z) + 2
	ring.Size = Vector3.new(0.3, diameter, diameter)
	ring.CFrame = CFrame.new(collectorPart.Position + Vector3.new(0, collectorPart.Size.Y / 2 + 1.5, 0))
		* CFrame.Angles(0, 0, math.rad(90))
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = FLASH_COLOR
	ring.Parent = collectorPart.Parent or workspace
	local ringTag = Cfg.RING_TAG
	if type(ringTag) == "string" and ringTag ~= "" then
		CollectionService:AddTag(ring, ringTag)
	end

	collectorPart.AncestryChanged:Connect(function(_, parent)
		if parent == nil and ring.Parent then
			ring:Destroy()
		end
	end)
end

function CashInService.cashIn(player: Player, amount: number, tier: number, collectorPosition: Vector3)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player.Parent ~= Players then
		return
	end
	if not isFiniteNumber(amount) then
		ForgeTelemetry.count("cashin_bad_amount", 1)
		return
	end
	local t = if isFiniteNumber(tier) then tier else 1
	local pos = if typeof(collectorPosition) == "Vector3" then collectorPosition else Vector3.zero
	local pitch = pitchForTier(t)

	-- Verifiable juice counter: one event per collected cube.
	ForgeTelemetry.count("juice_events", 1)

	-- Send the reward popup FIRST so later cosmetic errors can never swallow it.
	local sent = sentTotal[player] or 0
	sentTotal[player] = sent + 1
	allowSend(player) -- keep the rate log updated, but never drop a cash-in popup
	local fired = pcall(function()
		CashInRemote:FireClient(player, amount, t, pos, pitch)
	end)
	if fired then
		ForgeTelemetry.count("cashin_fx_sent", 1)
	else
		ForgeTelemetry.count("cashin_fx_failed", 1)
	end

	-- Collector flash + sparkle on every collected cube (cheap, not throttled).
	local info: CollectorInfo? = nil
	local fxOk = pcall(function()
		if #collectors == 0 then
			scanForCollectors()
		end
		info = findCollector(pos)
		if info == nil then
			lastScan = 0
			scanForCollectors()
			info = findCollector(pos)
		end
		if info then
			flashCollector(info, pitch)
		end
	end)
	if not fxOk then
		ForgeTelemetry.count("cashin_collector_fx_failed", 1)
	end

	-- Burst at the intake, isolated so a failure never blocks anything else.
	local burstInfo = info
	if burstInfo then
		local burstDone = false
		if GameAssets and type(GameAssets.burst) == "function" then
			local burstOk = pcall(function()
				GameAssets.burst(burstInfo.part.Position)
			end)
			if burstOk then
				burstDone = true
			else
				ForgeTelemetry.count("cashin_burst_failed", 1)
			end
		end
		if not burstDone then
			-- Fallback: bigger sparkle from the collector's own emitter.
			local emitOk = pcall(function()
				burstInfo.emitter:Emit(8)
			end)
			burstDone = emitOk
		end
		if burstDone then
			ForgeTelemetry.count("bursts", 1)
		end
	end

	-- Tutorial: a cube's value was credited to its owner (TutorialService ignores repeats).
	local ok = pcall(function()
		TutorialService.notify(player, "cashed")
	end)
	if not ok then
		ForgeTelemetry.count("cashin_tutorial_notify_failed", 1)
	end
end

-- magnitude: 1 for a normal buy, 2 for an ore tier or multiplier (client scales shake/FOV/ring).
-- tierColor: optional colour for the shockwave ring / popup.
function CashInService.purchase(player: Player, position: Vector3, upgradeName: string?, magnitude: number?, tierColor: Color3?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player.Parent ~= Players then
		return
	end
	local pos = if typeof(position) == "Vector3" then position else Vector3.zero
	local name = if type(upgradeName) == "string" then upgradeName else ""
	local mag = if isFiniteNumber(magnitude) then math.clamp(magnitude :: number, 1, 3) else 1
	local color = if typeof(tierColor) == "Color3" then tierColor else FLASH_COLOR
	ForgeTelemetry.count("juice_events", 1)
	local ok = pcall(function()
		PurchaseRemote:FireClient(player, pos, name, mag, color, "buy")
	end)
	if ok then
		ForgeTelemetry.count("purchase_fx_sent", 1)
	else
		ForgeTelemetry.count("purchase_fx_failed", 1)
	end
end

-- Failed purchase: client plays the Error buzz and flashes the pad red.
function CashInService.purchaseError(player: Player, position: Vector3, message: string?)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if player.Parent ~= Players then
		return
	end
	local pos = if typeof(position) == "Vector3" then position else Vector3.zero
	local msg = if type(message) == "string" then message else ""
	local ok = pcall(function()
		PurchaseRemote:FireClient(player, pos, msg, 1, Color3.fromRGB(255, 70, 70), "error")
	end)
	if ok then
		ForgeTelemetry.count("purchase_error_fx_sent", 1)
	else
		ForgeTelemetry.count("purchase_fx_failed", 1)
	end
end

return CashInService
