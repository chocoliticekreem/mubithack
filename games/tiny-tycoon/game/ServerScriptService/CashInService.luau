--!strict
-- CashInService: server-side owner of cash-in / purchase feedback.
-- Sends display data only to clients; never changes cash.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")
local Debris = game:GetService("Debris")

local CashInConfig = require(ReplicatedStorage:WaitForChild("CashInConfig", 10))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 10))

-- Guarded lookup: a missing/broken TutorialService must never stop this service.
local TutorialService: any = nil
do
	local ok, res = pcall(function()
		local m = script.Parent:WaitForChild("TutorialService", 10)
		if m and m:IsA("ModuleScript") then
			return require(m)
		end
		return nil
	end)
	if ok then
		TutorialService = res
	else
		ForgeTelemetry.count("cashin_tutorial_missing", 1)
	end
end

local Cfg: any = CashInConfig

local FLASH_COLOR = Color3.fromRGB(255, 214, 64)
local FLASH_TIME = 0.15
local PULSE_SCALE = 1.15
local PULSE_HALF_TIME = 0.075 -- up + back = 0.15s
local AGGREGATE_DELAY = 0.25 -- over-limit cash-ins are merged into one popup this often
local COMBO_WINDOW = 3 -- seconds between cubes that keep a streak alive
local MILESTONES: { [number]: boolean } = { [1] = true, [10] = true, [50] = true, [100] = true }
local CASH_MILESTONES: { number } = { 50, 100, 500, 1000, 5000 }
local COIN_VOLUME = 0.8
local FX_THROTTLE = 0.15 -- min seconds between coin sounds / bursts per player
local DEFAULT_POPUPS_PER_SECOND = 4

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
	baseSize: Vector3,
	baseMaterial: Enum.Material,
	emitter: ParticleEmitter,
	tween: Tween?,
	pulse: Tween?,
}

type Pending = {
	amount: number,
	cubes: number,
	tier: number,
	pos: Vector3,
	pitch: number,
}

local collectors: { CollectorInfo } = {}
local sendLog: { [Player]: { number } } = {}
local sentTotal: { [Player]: number } = {}
local cashTotal: { [Player]: number } = {}
local pendingPopups: { [Player]: Pending } = {}
local streaks: { [Player]: { count: number, last: number } } = {}
local lastSoundAt: { [Player]: number } = {}
local lastBurstAt: { [Player]: number } = {}
local lastScan = 0

local function isFiniteNumber(v: any): boolean
	return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Per-player throttle gate: returns true (and stamps) if enough time has passed.
local function gate(tbl: { [Player]: number }, player: Player?): boolean
	if player == nil then
		return true
	end
	local now = os.clock()
	local last = tbl[player]
	if last and now - last < FX_THROTTLE then
		return false
	end
	tbl[player] = now
	return true
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
	-- Prefer the verified GameAssets coin id, then the config id.
	local a = assetSoundId("Coin")
	if a ~= "" then
		return a
	end
	return toSoundIdString(Cfg.CASHIN_SOUND_ID)
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

local function tierColorFor(tier: number): Color3
	local tc: any = Cfg.TIER_COLORS
	if type(tc) == "table" then
		local c = tc[tier]
		if typeof(c) == "Color3" then
			return c
		end
	end
	return FLASH_COLOR
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

-- Plays a non-positional (2D) sound for exactly one player by parenting a Sound
-- to their PlayerGui. Returns true if it was started. Always cleaned up via Debris.
local function playForPlayer(player: Player, soundId: string, volume: number, pitch: number): boolean
	if soundId == "" then
		return false
	end
	if player.Parent ~= Players then
		return false
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui then
		return false
	end
	local ok = pcall(function()
		local s = Instance.new("Sound")
		s.Name = "CashInLocalSound"
		s.SoundId = soundId
		s.Volume = volume
		s.PlaybackSpeed = math.clamp(pitch, 0.5, 2)
		s.RollOffMaxDistance = 10000
		s.Parent = gui
		s.Ended:Once(function()
			s:Destroy()
		end)
		s:Play()
		Debris:AddItem(s, 4)
	end)
	return ok
end

local function playCoin(part: BasePart, pitch: number, player: Player?)
	-- Primary: 2D sound for the player who cashed in.
	if player then
		if playForPlayer(player, configSoundId(), COIN_VOLUME, pitch) then
			ForgeTelemetry.count("sounds_played", 1)
			ForgeTelemetry.count("cashin_local_sounds", 1)
			return
		end
	end

	-- Fallback: Sound on the collector.
	local snd = part:FindFirstChild("CashInSound")
	if not (snd and snd:IsA("Sound")) then
		local s = Instance.new("Sound")
		s.Name = "CashInSound"
		s.Volume = COIN_VOLUME
		s.SoundId = configSoundId()
		s.Parent = part
		snd = s
	end
	local sound = snd :: Sound
	sound.Volume = COIN_VOLUME
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

-- Milestone Win sting (2D for the player, collector sound as fallback).
local function playWin(part: BasePart?, player: Player?)
	local id = assetSoundId("Win")
	if id ~= "" and player then
		if playForPlayer(player, id, 0.9, 1) then
			ForgeTelemetry.count("sounds_played", 1)
			ForgeTelemetry.count("cashin_local_sounds", 1)
			return
		end
	end
	if id ~= "" and part then
		local ok = pcall(function()
			local snd = part:FindFirstChild("CashInWinSound")
			if not (snd and snd:IsA("Sound")) then
				local s = Instance.new("Sound")
				s.Name = "CashInWinSound"
				s.Volume = 0.8
				s.SoundId = id
				s.Parent = part
				snd = s
			end
			(snd :: Sound):Play()
		end)
		if ok then
			ForgeTelemetry.count("sounds_played", 1)
			return
		end
	end
	if GameAssets and type(GameAssets.play) == "function" then
		local ok = pcall(function()
			GameAssets.play("Win")
		end)
		if ok then
			ForgeTelemetry.count("sounds_played", 1)
		end
	end
end

-- Popup rate limiting (per player, sliding one-second window).
local function popupLimit(): number
	local v = Cfg.POPUPS_PER_SECOND
	if isFiniteNumber(v) and v > 0 then
		return v
	end
	return DEFAULT_POPUPS_PER_SECOND
end

local function pruneLog(player: Player): { number }
	local log = sendLog[player]
	if not log then
		log = {}
		sendLog[player] = log
	end
	local now = os.clock()
	while #log > 0 and now - log[1] > 1 do
		table.remove(log, 1)
	end
	return log
end

local function allowSend(player: Player): boolean
	return #pruneLog(player) < popupLimit()
end

local function recordSend(player: Player)
	local log = pruneLog(player)
	table.insert(log, os.clock())
end

-- Sends the floating +$N popup data to one client.
local function sendPopup(
	player: Player,
	amount: number,
	tier: number,
	pos: Vector3,
	pitch: number,
	scale: number,
	big: boolean,
	cubes: number
)
	if player.Parent ~= Players then
		return
	end
	local ok = pcall(function()
		CashInRemote:FireClient(player, amount, tier, pos, pitch, scale, big, cubes)
	end)
	if ok then
		recordSend(player)
		ForgeTelemetry.count("cashin_popups_sent", 1)
	else
		ForgeTelemetry.count("cashin_popup_failed", 1)
	end
end

-- Over-limit cash-ins are merged and flushed as one summed popup.
local function queuePopup(player: Player, amount: number, tier: number, pos: Vector3, pitch: number)
	local pending = pendingPopups[player]
	if pending then
		pending.amount += amount
		pending.cubes += 1
		pending.tier = math.max(pending.tier, tier)
		pending.pos = pos
		pending.pitch = pitch
		return
	end
	pendingPopups[player] = {
		amount = amount,
		cubes = 1,
		tier = tier,
		pos = pos,
		pitch = pitch,
	}
	ForgeTelemetry.count("cashin_popups_aggregated", 1)
	task.delay(AGGREGATE_DELAY, function()
		local p = pendingPopups[player]
		pendingPopups[player] = nil
		if p and player.Parent == Players then
			local s = math.clamp(1 + 0.1 * (p.tier - 1) + 0.05 * p.cubes, 1, 1.8)
			sendPopup(player, p.amount, p.tier, p.pos, p.pitch, s, false, p.cubes)
		end
	end)
end

-- Collector flash + Neon size pulse + sparkle + (throttled) coin sound.
local function flashCollector(info: CollectorInfo, pitch: number, player: Player?)
	local part = info.part
	if part.Parent == nil then
		return
	end

	-- Colour flash.
	if info.tween then
		info.tween:Cancel()
	end
	part.Color = FLASH_COLOR
	local colorTween = TweenService:Create(part, TweenInfo.new(FLASH_TIME), { Color = info.baseColor })
	info.tween = colorTween
	colorTween:Play()

	-- Neon pulse: Size 1.0 -> 1.15 -> 1.0 in 0.15s.
	if info.pulse then
		info.pulse:Cancel()
	end
	part.Size = info.baseSize
	part.Material = Enum.Material.Neon
	local pulse = TweenService:Create(
		part,
		TweenInfo.new(PULSE_HALF_TIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true),
		{ Size = info.baseSize * PULSE_SCALE }
	)
	info.pulse = pulse
	pulse.Completed:Once(function()
		if part.Parent ~= nil then
			part.Size = info.baseSize
			part.Material = info.baseMaterial
		end
	end)
	pulse:Play()

	-- Tiny sparkle.
	pcall(function()
		info.emitter:Emit(6)
	end)

	if gate(lastSoundAt, player) then
		playCoin(part, pitch, player)
	end
end

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
		baseSize = collectorPart.Size,
		baseMaterial = collectorPart.Material,
		emitter = emitter :: ParticleEmitter,
		tween = nil,
		pulse = nil,
	})

	if not collectorPart:FindFirstChild("CashInLight") then
		local light = Instance.new("PointLight")
		light.Name = "CashInLight"
		light.Color = if typeof(Cfg.LIGHT_COLOR) == "Color3" then Cfg.LIGHT_COLOR else FLASH_COLOR
		light.Brightness = if isFiniteNumber(Cfg.LIGHT_BRIGHTNESS) then Cfg.LIGHT_BRIGHTNESS else 1.5
		light.Range = if isFiniteNumber(Cfg.LIGHT_RANGE) then Cfg.LIGHT_RANGE else 12
		light.Parent = collectorPart
	end

	-- Sound object on the collector (fallback; the main coin sound is played 2D per player).
	if not collectorPart:FindFirstChild("CashInSound") then
		local snd = Instance.new("Sound")
		snd.Name = "CashInSound"
		local id = configSoundId()
		if id ~= "" then
			snd.SoundId = id
		end
		snd.Volume = COIN_VOLUME
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

	-- Combo streak: cubes cashed in quick succession raise the pitch.
	local now = os.clock()
	local streak = streaks[player]
	if streak and now - streak.last <= COMBO_WINDOW then
		streak.count += 1
		streak.last = now
	else
		streak = { count = 1, last = now }
		streaks[player] = streak
	end
	local pitch = pitchForTier(t + math.min(streak.count - 1, 8))

	-- Verifiable juice counter: one event per collected cube.
	ForgeTelemetry.count("juice_events", 1)

	local total = (sentTotal[player] or 0) + 1
	sentTotal[player] = total
	-- Every 10th cube is a bigger moment (plus the early/round-number milestones).
	local tenth = total % 10 == 0
	local milestone = MILESTONES[total] == true or tenth

	-- Cash-threshold milestones ($50, $100, $500, ...): bigger moment when crossed.
	local prevCash = cashTotal[player] or 0
	local newCash = prevCash + math.max(amount, 0)
	cashTotal[player] = newCash
	local cashMilestone = false
	for _, threshold in ipairs(CASH_MILESTONES) do
		if prevCash < threshold and newCash >= threshold then
			cashMilestone = true
			break
		end
	end
	if cashMilestone then
		milestone = true
	end
	if milestone then
		ForgeTelemetry.count("cashin_milestones", 1)
	end

	-- Popup scale grows with cube value, tier and current combo.
	local valueScale = 0.15 * math.log10(math.max(amount, 1) + 1)
	local comboScale = 0.03 * math.min(streak.count - 1, 10)
	local normalScale = math.clamp(1 + 0.1 * (t - 1) + valueScale + comboScale, 1, 1.6)

	-- Send the reward popup FIRST so later cosmetic errors can never swallow it.
	-- Milestones are always sent immediately, larger. Over-limit popups are
	-- aggregated into one summed popup instead of being dropped.
	if milestone then
		recordSend(player)
		local big = if cashMilestone then 2.2 elseif tenth then 2 else 1.6
		sendPopup(player, amount, t, pos, pitch, big, true, 1)
	elseif pendingPopups[player] == nil and allowSend(player) then
		sendPopup(player, amount, t, pos, pitch, normalScale, false, 1)
	else
		queuePopup(player, amount, t, pos, pitch)
	end

	-- Collector flash + pulse + sparkle + (throttled) coin sound.
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
			flashCollector(info, pitch, player)
		end
	end)
	if not fxOk then
		ForgeTelemetry.count("cashin_collector_fx_failed", 1)
	end
	if info == nil then
		-- No collector found: still make the reward audible (throttled).
		if gate(lastSoundAt, player) and playForPlayer(player, configSoundId(), COIN_VOLUME, pitch) then
			ForgeTelemetry.count("sounds_played", 1)
			ForgeTelemetry.count("cashin_local_sounds", 1)
		end
	end

	-- Burst at the intake, isolated so a failure never blocks anything else.
	-- Throttled per player; milestones always burst.
	local burstInfo = info
	if burstInfo and (milestone or gate(lastBurstAt, player)) then
		if milestone then
			lastBurstAt[player] = os.clock()
		end
		local burstDone = false
		-- Every 10th cube gets a big gold sparkle.
		local tierColor = if tenth then FLASH_COLOR else tierColorFor(t)
		if GameAssets and type(GameAssets.burst) == "function" then
			local burstOk = pcall(function()
				if milestone then
					GameAssets.burst(burstInfo.part.Position, tierColor, 30)
				else
					GameAssets.burst(burstInfo.part.Position)
				end
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
				burstInfo.emitter:Emit(if milestone then 30 else 8)
			end)
			burstDone = emitOk
		end
		if burstDone then
			ForgeTelemetry.count("bursts", 1)
		end
	end

	if milestone then
		local part: BasePart? = if burstInfo then burstInfo.part else nil
		pcall(playWin, part, player)
	end

	-- Tutorial: a cube's value was credited to its owner (TutorialService ignores repeats).
	if TutorialService and type(TutorialService.notify) == "function" then
		local ok = pcall(function()
			TutorialService.notify(player, "cashed")
		end)
		if not ok then
			ForgeTelemetry.count("cashin_tutorial_notify_failed", 1)
		end
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

Players.PlayerRemoving:Connect(function(player)
	sendLog[player] = nil
	sentTotal[player] = nil
	cashTotal[player] = nil
	pendingPopups[player] = nil
	streaks[player] = nil
	lastSoundAt[player] = nil
	lastBurstAt[player] = nil
end)

return CashInService
