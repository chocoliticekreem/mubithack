--!strict
-- OnboardingService [owner: Onboarding]. Server half of the first-join flow
-- (Controllers/OnboardingController draws it; copy in Config/OnboardingConfig):
--   * Player attr "Onboarded" (OnboardingConfig.DoneAttr): true = returning player, skip the tutorial.
--     Read from the DataService profile (settings.onboarded, or anyone who has played a mission
--     before this flag existed); false while unknown is never written, so the client waits for it.
--   * Onboarding/Done (C->S, none, 1/s): the tutorial finished (or was skipped) -> settings.onboarded.
--   * Client handshake: Onboarding/Ready (C->S, none, 1/s) once OnboardingController has booted (every
--     controller's Start has run, so their OnClientEvent handlers are connected). Sets Player attr
--     ClientReady = true and fires .ClientReady. FirstFireService waits for it before lighting the training
--     fire, LobbyService / BattlePassService re-send their state on it: a slow phone load (30k-part map)
--     never misses a tutorial card, the board or the pass state.
--   * Onboarding/Seen (C->S, step: string, 2/s): the client actually drew a tutorial card. Only ids in
--     SEEN_STEPS are accepted (fires .Seen(player, step)); FunnelService logs "Saw Fire Card" from it.
--   * Onboarding/Skip (C->S, none, 1/s): SKIP TUTORIAL -> MarkDone + .Skipped(player) (FirstFireService
--     puts the training fire away). Onboarding/SkipCall (C->S, none, 1/s): NOT YET on the auto-queued
--     first call -> .CallDeclined(player) (FirstFireService steps them off the pad).
--   * SpawnCFrame(player | slot): the player's StationSpawn pad (by Helmet), standing on it and turned
--     to face the apparatus floor (the TruckBay for that helmet), so you spawn looking at the trucks
--     instead of the locker room's back wall. LobbyService / SquadService use it (nil-guarded).
--
-- Public API:
--   OnboardingService:SpawnCFrame(who: Player | number): CFrame?
--   OnboardingService:IsOnboarded(player): boolean
--   OnboardingService:MarkDone(player)
--   OnboardingService:WaitForClient(player, timeout: number): boolean   -- true once ClientReady
-- Signals: ClientReady(player), Seen(player, step), Skipped(player), CallDeclined(player)
-- Counters: onboarding_started, onboarding_done, onboarding_skipped (returning player), client_ready,
--   client_ready_seconds (sum: join -> handshake), tutorial_skipped, first_call_declined
-- Test hooks (DevHook only): _reset(player) (fresh first-join next time), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local OnboardingConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local OnboardingFlow = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("OnboardingFlow") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)

local OnboardingService = {}
OnboardingService.Priority = 25 -- after DataService (20)
OnboardingService.ClientReady = Signal.new() :: Signal.Signal<Player>
OnboardingService.Seen = Signal.new() :: Signal.Signal<Player, string>
OnboardingService.Skipped = Signal.new() :: Signal.Signal<Player>
OnboardingService.CallDeclined = Signal.new() :: Signal.Signal<Player>

local READY_ATTR = "ClientReady" -- Player attr: the client booted and connected its remote handlers
local SEEN_STEPS = { firecard = true } -- Onboarding/Seen ids the server accepts (constant set)

local services: { [string]: any } = {}
local joinedAt: { [Player]: number } = {}
local TRUCK_BAY_TAG: string = (Names.Tag :: any).TruckBay or "TruckBay"

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function doneAttr(): string
	return OnboardingConfig.DoneAttr or "Onboarded"
end

------------------------------------------------------------------------------------------ spawn

local function bayFor(slot: number): BasePart?
	local best: BasePart? = nil
	for _, b in CollectionService:GetTagged(TRUCK_BAY_TAG) do
		if b:IsA("BasePart") and b:IsDescendantOf(workspace) then
			if b:GetAttribute("Bay") == slot then
				return b
			end
			best = best or b
		end
	end
	return best
end

function OnboardingService:SpawnCFrame(who: any): CFrame?
	local slot = 1
	if typeof(who) == "Instance" and who:IsA("Player") then
		local Squad = services.SquadService
		local ok, h = pcall(function()
			return Squad and Squad:GetHelmet(who)
		end)
		slot = if ok and type(h) == "number" then h else tonumber(who:GetAttribute(Names.Attr.Helmet)) or 1
	elseif type(who) == "number" then
		slot = who
	end
	slot = ((math.floor(slot) - 1) % 8) + 1 -- 8 racks + spawn pads (squads of up to 8)
	local Map = services.MapService
	local ok, cf = pcall(function()
		return Map and Map:GetSpawnCFrame(slot)
	end)
	if not ok or typeof(cf) ~= "CFrame" then
		return nil
	end
	local base = cf :: CFrame
	if OnboardingConfig.SpawnFaceBays == false then
		return base
	end
	-- the front yard's START row (tag OutsideSpawn) already faces the squad pads: keep that facing; only
	-- the locker-room pads (the fallback) get turned toward the bays
	for _, sp in CollectionService:GetTagged("OutsideSpawn") do
		if sp:IsA("BasePart") then
			local d = sp.Position - base.Position
			if d.X * d.X + d.Z * d.Z < 1 then
				return base
			end
		end
	end
	local bay = bayFor(slot)
	if not bay then
		return base
	end
	local p, t = base.Position, bay.Position
	return CFrame.new(p) * CFrame.Angles(0, OnboardingFlow.yawToward(p.X, p.Z, t.X, t.Z), 0)
end

------------------------------------------------------------------------------------------ flag

local function profileSaysDone(profile: any): boolean
	if type(profile) ~= "table" then
		return false
	end
	local settings = profile.settings
	if type(settings) == "table" and settings.onboarded == true then
		return true
	end
	return (tonumber(profile.missionsPlayed) or 0) > 0
end

function OnboardingService:IsOnboarded(player: Player): boolean
	return player:GetAttribute(doneAttr()) == true
end

function OnboardingService:MarkDone(player: Player)
	if player:GetAttribute(doneAttr()) == true then
		return
	end
	player:SetAttribute(doneAttr(), true)
	count("onboarding_done")
	local Data = services.DataService
	if Data and type(Data.Update) == "function" then
		pcall(Data.Update, Data, player, function(p: any)
			if type(p.settings) == "table" then
				p.settings.onboarded = true
			end
		end)
	end
end

function OnboardingService:WaitForClient(player: Player, timeout: number): boolean
	local t0 = os.clock()
	while player.Parent == Players and player:GetAttribute(READY_ATTR) ~= true and os.clock() - t0 < timeout do
		task.wait(0.1)
	end
	return player:GetAttribute(READY_ATTR) == true
end

local function onReady(player: Player)
	if player:GetAttribute(READY_ATTR) == true then
		return
	end
	player:SetAttribute(READY_ATTR, true)
	count("client_ready")
	count("client_ready_seconds", math.floor(os.clock() - (joinedAt[player] or os.clock()) + 0.5))
	OnboardingService.ClientReady:Fire(player)
end

local function onPlayer(player: Player)
	joinedAt[player] = joinedAt[player] or os.clock()
	task.spawn(function()
		local Data = services.DataService
		local profile: any = nil
		if Data and type(Data.WaitForProfile) == "function" then
			local ok, p = pcall(Data.WaitForProfile, Data, player, 8)
			profile = if ok then p else nil
		end
		if player.Parent ~= Players then
			return
		end
		local done = profileSaysDone(profile)
		player:SetAttribute(doneAttr(), done)
		count(if done then "onboarding_skipped" else "onboarding_started")
	end)
end

------------------------------------------------------------------------------------------ lifecycle

function OnboardingService:Init(all: { [string]: any })
	services = all
end

function OnboardingService:Start()
	if OnboardingConfig.Enabled == false then
		return
	end
	local done = Net.event("Onboarding", "Done")
	Net.onServer(done, { rate = 1, burst = 1 }, function(player: Player)
		OnboardingService:MarkDone(player)
	end)
	Net.onServer(Net.event("Onboarding", "Ready"), { rate = 1, burst = 2 }, onReady)
	Net.onServer(Net.event("Onboarding", "Seen"), { rate = 2, burst = 2 }, function(player: Player, step: any)
		if type(step) == "string" and SEEN_STEPS[step] then
			OnboardingService.Seen:Fire(player, step)
		end
	end)
	Net.onServer(Net.event("Onboarding", "Skip"), { rate = 1, burst = 1 }, function(player: Player)
		if player:GetAttribute(doneAttr()) == true then
			return
		end
		count("tutorial_skipped")
		OnboardingService.Skipped:Fire(player)
		OnboardingService:MarkDone(player)
		pcall(Net.notify, player, OnboardingConfig.SkippedText or "Tutorial skipped. Step on a glowing pad to roll out. H = help.", "info")
	end)
	Net.onServer(Net.event("Onboarding", "SkipCall"), { rate = 1, burst = 1 }, function(player: Player)
		count("first_call_declined")
		OnboardingService.CallDeclined:Fire(player)
	end)
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		joinedAt[p] = nil
	end)
end

------------------------------------------------------------------------------------------ test hooks

function OnboardingService:_reset(player: Player)
	player:SetAttribute(doneAttr(), false)
	local Data = services.DataService
	if Data and type(Data.Update) == "function" then
		pcall(Data.Update, Data, player, function(p: any)
			if type(p.settings) == "table" then
				p.settings.onboarded = false
			end
		end)
	end
end

function OnboardingService:_selftest(): (boolean, string)
	local cf = self:SpawnCFrame(1)
	if not cf then
		return false, "no spawn cframe (MapService missing?)"
	end
	local bay = bayFor(1)
	if bay then
		local to = (bay.Position - cf.Position) * Vector3.new(1, 0, 1)
		if to.Magnitude > 0.1 and cf.LookVector:Dot(to.Unit) < 0.99 then
			return false, `spawn not facing bay 1 (dot {cf.LookVector:Dot(to.Unit)})`
		end
	end
	return true, `spawn {cf.Position} facing {cf.LookVector}`
end

return OnboardingService
