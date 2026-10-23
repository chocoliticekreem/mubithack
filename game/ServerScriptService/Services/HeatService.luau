--!strict
-- HeatService [owner: G1]. Per-player body heat 0..100 (Player attr Heat).
--   Rises near Burning parts: inverse-square-ish, FireLevel weighted, reduced through walls.
--   Cools over time; fast while a teammate's hose hits you (ToolService.HoseHit) or in water.
--   60 = warm (client tint + heavy breathing), 85 = sweaty (client sweat drops + walk slowed here),
--   100 = Overheated -> SquadService:Down(player, "heat") (nil-guarded), "well done (steak)" toast,
--   Heat resets to ResetAfterDown.
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   HeatService:GetHeat(player: Player): number
--   HeatService:AddHeat(player: Player, amount: number, source: string?)
--   HeatService:Cool(player: Player, amount: number, by: Player?)  -- by = teammate who sprayed you
--   HeatService:Reset(player: Player?)                             -- nil = everyone (mission start/end)
-- Signals: Overheated(player: Player)
-- Writes: Player attr Heat (rounded to 0.5, only on change); Humanoid.WalkSpeed x
--         HeatConfig.SweatyWalkMultiplier while sweaty (divided back after); counters heat_downs,
--         heat_sweaty, heat_hose_cooled
-- Maths: Lib/Heat/HeatMath (pure, spec-tested in game/tests/heat.spec.luau).
-- Test hooks (DevHook only): _setHeat(player, value), _tick(dt), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local HeatConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HeatConfig") :: ModuleScript) :: any
local HeatMath =
	require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Heat"):WaitForChild("HeatMath") :: ModuleScript)

local HeatService = {}
HeatService.Priority = 55
HeatService.Overheated = Signal.new() :: Signal.Signal<Player>

type PState = {
	heat: number,
	stage: number,
	sprayedUntil: number,
	slowed: number?, -- WalkSpeed multiplier currently applied
	slowedHum: Humanoid?,
	written: number?,
}

local services: { [string]: any } = {}
local states: { [Player]: PState } = {}
local rayParams: RaycastParams? = nil

local STEAK_LINES = {
	"%s is well done (steak). Medium rare next time?",
	"%s overheated. Chef's kiss.",
	"%s got cooked. Somebody hose them!",
	"Order up: one %s, well done.",
}

local function cfg(): HeatMath.Cfg
	return HeatConfig :: any
end

local function state(player: Player): PState
	local s = states[player]
	if not s then
		s = { heat = 0, stage = 0, sprayedUntil = 0 }
		states[player] = s
	end
	return s
end

local function humanoidOf(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function write(player: Player, s: PState)
	local rounded = math.floor(s.heat * 2 + 0.5) / 2
	if rounded ~= s.written then
		s.written = rounded
		player:SetAttribute(Names.Attr.Heat, rounded)
	end
end

local function setSlow(player: Player, s: PState, on: boolean)
	local hum = humanoidOf(player)
	if s.slowed then
		if not on or s.slowedHum ~= hum then
			local old = s.slowedHum
			if old and old.Parent then
				old.WalkSpeed /= s.slowed :: number
			end
			s.slowed = nil
			s.slowedHum = nil
		end
	end
	if on and not s.slowed and hum then
		local m = HeatConfig.SweatyWalkMultiplier
		hum.WalkSpeed *= m
		s.slowed = m
		s.slowedHum = hum
	end
end

local function isActive(player: Player): boolean
	if player:GetAttribute(Names.Attr.Downed) == true then
		return false
	end
	local hum = humanoidOf(player)
	return hum ~= nil and hum.Health > 0
end

local function overheat(player: Player, s: PState)
	Telemetry.count("heat_downs")
	s.heat = math.min(s.heat, HeatConfig.ResetAfterDown)
	s.stage = HeatMath.stage(s.heat, cfg())
	setSlow(player, s, false)
	write(player, s)
	HeatService.Overheated:Fire(player)
	local squad = services.SquadService
	if squad then
		local fn = squad.SetDowned or squad.Down
		if type(fn) == "function" then
			local ok, err = pcall(fn, squad, player, "heat", nil)
			if not ok then
				warn(`[HeatService] SquadService down failed: {err}`)
			end
		end
	end
	-- your own overheat stays a screen toast; nearby players see a small popup over you
	local line = string.format(STEAK_LINES[math.random(1, #STEAK_LINES)], player.DisplayName)
	Net.notify(player, line, "bad")
	Popup.show(player, line, "blame")
end

-- Applies a new heat value and runs threshold transitions (sweaty slow-down, overheat).
local function apply(player: Player, s: PState, heat: number)
	local c = cfg()
	s.heat = math.clamp(heat, 0, c.DownAt)
	local active = isActive(player)
	local stage = HeatMath.stage(s.heat, c)
	if stage == 3 and active then
		overheat(player, s)
		return
	end
	if stage == 2 and s.stage < 2 then
		Telemetry.count("heat_sweaty")
	end
	s.stage = math.min(stage, 2)
	setSlow(player, s, active and s.stage == 2)
	write(player, s)
end

local function refreshRayParams()
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(skip, p.Character)
		end
	end
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		table.insert(skip, m)
	end
	params.FilterDescendantsInstances = skip
	params.IgnoreWater = true
	rayParams = params
end

local function occluded(from: Vector3, part: BasePart): boolean
	local hit = workspace:Raycast(from, part.Position - from, rayParams)
	if not hit then
		return false
	end
	local inst = hit.Instance
	return inst ~= part and not inst:HasTag(Names.Tag.Burning) and inst.Transparency < 0.9
end

local function inWater(hum: Humanoid?, root: BasePart): boolean
	if hum and (hum:GetState() == Enum.HumanoidStateType.Swimming or hum.FloorMaterial == Enum.Material.Water) then
		return true
	end
	local floor = workspace:Raycast(root.Position, Vector3.new(0, -4, 0), rayParams)
	return floor ~= nil and floor.Instance:HasTag(Names.Tag.WetFloor)
end

function HeatService:_tick(dt: number)
	local c = cfg()
	refreshRayParams()
	local burning: { BasePart } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
			table.insert(burning, inst)
		end
	end
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local s = state(player)
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		local head = char and char:FindFirstChild("Head") :: BasePart?
		local cooling: HeatMath.Cooling = { sprayed = now < s.sprayedUntil }
		local gain = 0
		if root and isActive(player) then
			local eye = (head or root).Position
			local near: { { part: BasePart, dist: number } } = {}
			for _, part in burning do
				-- distance to roughly the part's surface, not its centre
				local d = math.max(0, (part.Position - eye).Magnitude - part.Size.Magnitude * 0.35)
				if d <= c.Radius then
					table.insert(near, { part = part, dist = d })
				end
			end
			table.sort(near, function(a, b)
				return a.dist < b.dist
			end)
			local sources: { HeatMath.Source } = {}
			for i, n in near do
				if i > HeatConfig.MaxSources then
					break
				end
				local level = tonumber(n.part:GetAttribute(Names.Attr.FireLevel)) or 1
				local blocked = i <= HeatConfig.MaxRaycasts and occluded(eye, n.part)
				table.insert(sources, { dist = n.dist, level = level, occluded = blocked })
			end
			gain = HeatMath.gainRate(sources, c)
			cooling.inWater = inWater(humanoidOf(player), root)
		end
		apply(player, s, HeatMath.step(s.heat, gain, dt, cooling, c))
	end
end

function HeatService:Init(all: { [string]: any })
	services = all
end

function HeatService:Start()
	local tools = services.ToolService
	local hoseHit = tools and tools.HoseHit
	if hoseHit and type(hoseHit.Connect) == "function" then
		hoseHit:Connect(function(sprayer: Player, victim: Player)
			if typeof(victim) ~= "Instance" or not victim:IsA("Player") or victim == sprayer then
				return
			end
			HeatService:Cool(victim, HeatConfig.SprayCool, sprayer)
		end)
	end

	local function onPlayer(player: Player)
		player:SetAttribute(Names.Attr.Heat, 0)
		player.CharacterAdded:Connect(function()
			local s = state(player)
			s.slowed = nil -- new Humanoid, nothing to restore
			s.slowedHum = nil
			s.stage = 0
			s.heat = 0
			write(player, s)
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	local accum = 0
	RunService.Heartbeat:Connect(function(dt)
		accum += dt
		if accum < 1 / HeatConfig.TickHz then
			return
		end
		local step = math.min(accum, 0.5)
		accum = 0
		local ok, err = pcall(HeatService._tick, HeatService, step)
		if not ok then
			warn(`[HeatService] tick: {err}`)
		end
	end)
end

function HeatService:GetHeat(player: Player): number
	local s = states[player]
	return if s then s.heat else 0
end

function HeatService:AddHeat(player: Player, amount: number, _source: string?)
	local n = tonumber(amount)
	if not n or n ~= n then
		return
	end
	local s = state(player)
	apply(player, s, s.heat + n)
end

function HeatService:Cool(player: Player, amount: number, by: Player?)
	local n = math.max(0, tonumber(amount) or 0)
	local s = state(player)
	if by and by ~= player then
		s.sprayedUntil = os.clock() + HeatConfig.HoseCoolWindow
		if s.heat > 0 then
			Telemetry.count("heat_hose_cooled")
		end
	end
	apply(player, s, s.heat - n)
end

function HeatService:Reset(player: Player?)
	local list = if player then { player } else Players:GetPlayers()
	for _, p in list do
		local s = state(p)
		s.sprayedUntil = 0
		s.stage = 0
		apply(p, s, 0)
	end
end

function HeatService:_setHeat(player: Player, value: number)
	apply(player, state(player), tonumber(value) or 0)
end

function HeatService:_selftest(): (boolean, string)
	local c = cfg()
	local far = HeatMath.gainRate({ { dist = c.Radius + 1, level = 3 } }, c)
	local near = HeatMath.gainRate({ { dist = 1, level = 3 } }, c)
	local walled = HeatMath.gainRate({ { dist = 1, level = 3, occluded = true } }, c)
	if far ~= 0 or near <= walled or walled <= 0 then
		return false, `falloff/occlusion wrong: far={far} near={near} walled={walled}`
	end
	if HeatMath.step(90, 0, 1, { sprayed = true }, c) >= HeatMath.step(90, 0, 1, nil, c) then
		return false, "hose does not cool faster than waiting"
	end
	if HeatMath.stage(c.DownAt, c) ~= 3 or HeatMath.stage(c.SweatyAt, c) ~= 2 or HeatMath.stage(c.WarmAt, c) ~= 1 then
		return false, "stage thresholds wrong"
	end
	for _, p in Players:GetPlayers() do
		if type(p:GetAttribute(Names.Attr.Heat)) ~= "number" then
			return false, `{p.Name} has no Heat attribute`
		end
	end
	return true,
		`ok: hug a level-3 fire -> overheat in {string.format("%.1f", HeatMath.secondsToOverheat(4, 3, c))}s`
end

return HeatService
