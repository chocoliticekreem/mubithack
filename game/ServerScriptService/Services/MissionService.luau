--!strict
-- MissionService [owner: G3]. Runs missions. v1.5: every mission is its own run in its own copy of the
-- location (MapService:BuildInstance), so several squads play different missions in parallel. One run
-- table per instanceId; the per-run state machine is the pure Lib/Mission/MissionFlow (spec-tested).
-- Run flow: Alarm (station, AlarmSeconds) -> intro at the scene (teleport, 3-2-1, ROLL OUT) -> Active
-- (MissionCatalog seconds; ends early on all clear or when the whole squad is downed) -> Results
-- (ResultsSeconds) -> instance destroyed, squad handed back to LobbyService.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   MissionService:StartRound(locationId: string?, seconds: number?)   -- v1: everyone in the lobby plays
--   MissionService:EndRound(reason: Types.EndReason)                   -- v1: ends every running mission
--   MissionService:GetState(): Types.RoundState                        -- summary of the newest run
-- v1.5 (parallel squads; each mission runs in its own MapService instance):
--   MissionService:StartMission(squad: { Player }, missionId: string, seconds: number?): string?  -- instanceId
--   MissionService:EndMission(instanceId: string, reason: Types.EndReason)
--   MissionService:GetMission(instanceId: string): Types.MissionRun?
--   MissionService:GetMissions(): { Types.MissionRun }
-- Signals: RoundStarted(locationId: string)                 -- a run went Active (ROLL OUT)
--          RoundEnded(payload: Types.ResultsPayload)          -- every run's results (v1 listeners)
--          MissionStarted(instanceId: string, missionId: string)
--          MissionEnded(instanceId: string, results: Types.ResultsPayload)
-- Remotes: Mission/Alarm (S->C squad: missionId, title), Mission/Results (S->C squad: ResultsPayload)
-- Writes: instance Model attrs InstanceId (MapService), MissionId (catalog id), RoundState, RoundEndsAt;
--         Player attr InstanceId (id while in a mission, "" after); Workspace attrs RoundState,
--         RoundEndsAt, MissionId (location id) as a SUMMARY of the newest run only;
--         counters missions_started, missions_completed, rounds_started, rounds_completed
-- Consumes (all nil-guarded; missing peers/methods just skip that step):
--   MapService:BuildInstance/DestroyInstance/GetSpawnCFrame, VehicleService:ParkAt(instanceId),
--   ToolService:GiveLoadout, FireService:Ignite + .Extinguished, RescueService:SpawnAt(instanceId,
--   marker, kind) (else :Spawn(instanceId, count)), RescueService:ClearInstance(instanceId)?,
--   FireService:ClearInstance(instanceId)?, SquadService.Downed + :GetHelmet,
--   BlameService:Reset/ResetPlayers?/GetStats/BuildAwards, LobbyService:ReturnToLobby,
--   tags FireStart, Flammable, Burning, Rescuable, RescueSpawn, TruckSpot; attrs RescueState, Downed, Charred.
-- Test hooks (DevHook only): _startRound(locationId, seconds), _startMission(userIds|nil, missionId, seconds),
--   _endMission(instanceId), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local GameConfig = require(ConfigFolder:WaitForChild("GameConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigFolder:WaitForChild("MissionCatalog") :: ModuleScript) :: { any }
local MissionFlow = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Mission"):WaitForChild("MissionFlow") :: ModuleScript)

local MissionService = {}
MissionService.Priority = 60
MissionService.RoundStarted = Signal.new() :: Signal.Signal<string>
MissionService.RoundEnded = Signal.new() :: Signal.Signal<Types.ResultsPayload>
MissionService.MissionStarted = Signal.new() :: Signal.Signal<string, string>
MissionService.MissionEnded = Signal.new() :: Signal.Signal<string, Types.ResultsPayload>

type Live = {
	id: string,
	seq: number,
	def: any, -- Types.MissionDef
	missionId: string,
	locationId: string,
	model: Model,
	squadId: string?,
	players: { Player },
	flow: MissionFlow.Run,
	firesOut: number,
	firesLit: number,
	downs: number,
	payload: Types.ResultsPayload?,
}

local services: { [string]: any } = {}
local alarmRemote: RemoteEvent? = nil
local resultsRemote: RemoteEvent? = nil
local runs: { [string]: Live } = {}
local seq = 0
local started = false

-- helpers ----------------------------------------------------------------------------------------

local function now(): number
	return workspace:GetServerTimeNow()
end

local function count(name: string, n: number?)
	pcall(function()
		(require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any).count(name, n or 1)
	end)
end

-- Run one side-effect step; a broken peer warns instead of killing the mission.
local function safe(label: string, fn: () -> ())
	local ok, err = pcall(fn)
	if not ok then
		warn(`[MissionService] {label} failed: {err}`)
	end
end

local function lobbyConfig(): any
	local m = ConfigFolder:FindFirstChild("LobbyConfig")
	if m and m:IsA("ModuleScript") then
		local ok, cfg = pcall(require, m)
		if ok then
			return cfg
		end
	end
	return nil
end

local function findDef(missionId: string): any
	for _, m in MissionCatalog do
		if m.id == missionId then
			return m
		end
	end
	return nil
end

local function defForLocation(locationId: string): any
	local default = findDef(GameConfig.DefaultMissionId)
	if default and default.locationId == locationId then
		return default
	end
	for _, m in MissionCatalog do
		if m.locationId == locationId and m.enabled then
			return m
		end
	end
	return nil
end

local function isActiveRun(run: Live?): boolean
	return run ~= nil and run.flow.state ~= "Done"
end

local function runOf(player: Player): Live?
	local id = player:GetAttribute(Names.Attr.InstanceId)
	if type(id) == "string" and id ~= "" then
		return runs[id]
	end
	return nil
end

local function tagged(tag: string, model: Model): { Instance }
	local out = {}
	for _, inst in CollectionService:GetTagged(tag) do
		if inst:IsDescendantOf(model) then
			table.insert(out, inst)
		end
	end
	return out
end

local function byName(a: Instance, b: Instance): boolean
	return a.Name < b.Name
end

local function playSound(players: { Player }, key: string)
	local id = GameConfig.Sounds and GameConfig.Sounds[key]
	if type(id) ~= "string" or id == "" then
		return
	end
	for _, p in players do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root then
			local s = Instance.new("Sound")
			s.SoundId = id
			s.Parent = root
			s:Play()
			s.Ended:Once(function()
				s:Destroy()
			end)
		end
	end
end

local function notify(players: { Player }, text: string, kind: Types.NotifyKind)
	for _, p in players do
		pcall(Net.notify, p, text, kind)
	end
end

local function setAnchored(players: { Player }, anchored: boolean)
	for _, p in players do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			root.Anchored = anchored
		end
	end
end

-- Workspace attrs = a summary of the newest live run (v1 HUD/Alarm controllers read these).
local function summarize()
	local newest: Live? = nil
	for _, run in runs do
		if isActiveRun(run) and (newest == nil or run.seq > newest.seq) then
			newest = run
		end
	end
	if newest then
		workspace:SetAttribute(Names.Attr.RoundState, newest.flow.state)
		workspace:SetAttribute(Names.Attr.MissionId, newest.locationId)
		local endsAt = if newest.flow.endsAt > 0
			then newest.flow.endsAt
			else newest.flow.alarmEndsAt + newest.flow.timing.seconds
		workspace:SetAttribute(Names.Attr.RoundEndsAt, endsAt)
	else
		workspace:SetAttribute(Names.Attr.RoundState, "Lobby")
		workspace:SetAttribute(Names.Attr.RoundEndsAt, nil)
	end
end

local function publish(run: Live)
	local state = run.flow.state
	if state ~= "Done" then
		run.model:SetAttribute(Names.Attr.RoundState, state)
	end
	local endsAt = if run.flow.endsAt > 0 then run.flow.endsAt else run.flow.alarmEndsAt + run.flow.timing.seconds
	run.model:SetAttribute(Names.Attr.RoundEndsAt, endsAt)
	summarize()
end

-- observation for MissionFlow.tick -----------------------------------------------------------------

local function rescueCounts(run: Live): (number, number)
	local rescued, trapped = 0, 0
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.InstanceId) == run.id or m:IsDescendantOf(run.model) then
			local state = m:GetAttribute(Names.Attr.RescueState)
			if state == "Rescued" then
				rescued += 1
			elseif state ~= "Toasted" then -- toasted NPCs are lost, not still trapped
				trapped += 1
			end
		end
	end
	return rescued, trapped
end

local function burningCount(run: Live): number
	if not run.model.Parent then
		return 0
	end
	return #tagged(Names.Tag.Burning, run.model)
end

local function prunePlayers(run: Live)
	for i = #run.players, 1, -1 do
		local p = run.players[i]
		if p.Parent ~= Players or p:GetAttribute(Names.Attr.InstanceId) ~= run.id then
			table.remove(run.players, i)
		end
	end
end

local function observe(run: Live): MissionFlow.Obs
	prunePlayers(run)
	local alive = 0
	for _, p in run.players do
		if p:GetAttribute(Names.Attr.Downed) ~= true then
			alive += 1
		end
	end
	local rescued, trapped = rescueCounts(run)
	return {
		burning = burningCount(run),
		rescued = rescued,
		trapped = trapped,
		players = #run.players,
		alive = alive,
	}
end

-- scene setup --------------------------------------------------------------------------------------

-- Where the squad lands: a part named "PlayerSpawn", else beside the TruckSpot, else above the model.
local function sceneSpawn(run: Live): CFrame
	local named = run.model:FindFirstChild("PlayerSpawn", true)
	if named and named:IsA("BasePart") then
		return named.CFrame * CFrame.new(0, 3, 0)
	end
	local spots = tagged(Names.Tag.TruckSpot, run.model)
	local spot = spots[1]
	if spot and spot:IsA("BasePart") then
		return spot.CFrame * CFrame.new(-12, 4, 0)
	end
	local cf, size = run.model:GetBoundingBox()
	return CFrame.new(cf.Position.X, cf.Position.Y + size.Y / 2 + 5, cf.Position.Z)
end

local function teleportSquad(run: Live)
	local base = sceneSpawn(run)
	local n = #run.players
	for i, p in run.players do
		local char = p.Character
		if char and char:FindFirstChild("HumanoidRootPart") then
			local offset = (i - (n + 1) / 2) * (GameConfig.SpawnSpread or 4)
			char:PivotTo(base * CFrame.new(offset, 0, 0))
		end
	end
end

local function flammables(model: Model): { BasePart }
	local list: { BasePart } = {}
	for _, inst in tagged(Names.Tag.Flammable, model) do
		if inst:IsA("BasePart") and inst:GetAttribute(Names.Attr.Charred) ~= true then
			table.insert(list, inst)
		end
	end
	return list
end

local function nearest(list: { BasePart }, pos: Vector3, within: number): BasePart?
	local best: BasePart? = nil
	local bestD = within
	for _, p in list do
		local d = (p.Position - pos).Magnitude
		if d <= bestD then
			best, bestD = p, d
		end
	end
	return best
end

local function lightFires(run: Live): number
	local Fire = services.FireService
	if not (Fire and type(Fire.Ignite) == "function") then
		return 0
	end
	local fires = run.def.fires or {}
	local want = fires.count or GameConfig.StartFires
	local mode = fires.starts or "FireStart"
	if mode == "Scripted" then
		return 0 -- the mission's hazard (cigarette, campfire) lights its own fires
	end
	local rng = Random.new()
	local pool = flammables(run.model)
	local lit = 0
	if mode == "FireStart" then
		local markers = tagged(Names.Tag.FireStart, run.model)
		table.sort(markers, byName)
		for i = #markers, 2, -1 do -- shuffle: different start points every run
			local j = rng:NextInteger(1, i)
			markers[i], markers[j] = markers[j], markers[i]
		end
		for _, m in markers do
			if lit >= want then
				break
			end
			if m:IsA("BasePart") then
				local target: BasePart? = if m:HasTag(Names.Tag.Flammable)
					then m
					else nearest(pool, m.Position, GameConfig.FireStartSearch or 24)
				if target and Fire:Ignite(target, nil) then
					lit += 1
				end
			end
		end
	end
	local tries = 0
	while lit < want and #pool > 0 and tries < 30 do
		tries += 1
		if Fire:Ignite(pool[rng:NextInteger(1, #pool)], nil) then
			lit += 1
		end
	end
	return lit
end

local function spawnRescues(run: Live)
	local Rescue = services.RescueService
	if not Rescue then
		return
	end
	local wanted = run.def.rescues or {}
	if type(Rescue.SpawnAt) == "function" then
		local markers = tagged(Names.Tag.RescueSpawn, run.model)
		table.sort(markers, byName)
		local kinds: { string } = {}
		for i, m in markers do
			kinds[i] = tostring(m:GetAttribute(Names.Attr.Kind) or "")
		end
		for i, kind in MissionFlow.assignRescues(kinds, wanted) do
			if kind then
				safe(`Rescue:SpawnAt {kind}`, function()
					Rescue:SpawnAt(run.id, markers[i], kind)
				end)
			end
		end
	elseif type(Rescue.Spawn) == "function" then
		local total = 0
		for _, r in wanted do
			total += r.count
		end
		Rescue:Spawn(run.id, total)
	end
end

-- results --------------------------------------------------------------------------------------------

local function buildPayload(run: Live): Types.ResultsPayload
	local rescued, trapped = rescueCounts(run)
	local burning = burningCount(run)
	local charred = 0
	if run.model.Parent then
		for _, d in run.model:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute(Names.Attr.Charred) == true then
				charred += 1
			end
		end
	end
	local stats: { Types.PlayerStats } = {}
	local awards: { Types.Award } = {}
	local inSquad: { [number]: boolean } = {}
	local downs = run.downs
	local Blame = services.BlameService
	local blameDowns = 0
	for _, p in run.players do
		inSquad[p.UserId] = true
		if Blame and type(Blame.GetStats) == "function" then
			local ok, s = pcall(Blame.GetStats, Blame, p)
			if ok and type(s) == "table" then
				table.insert(stats, s)
				blameDowns += tonumber(s.timesDowned) or 0
			end
		end
	end
	downs = math.max(downs, blameDowns)
	local buildFor = Blame and (Blame.BuildAwardsFor or Blame.BuildAwards)
	if type(buildFor) == "function" then
		local ok, list = pcall(buildFor, Blame, run.players)
		if ok and type(list) == "table" then
			for _, a in list do
				if inSquad[a.userId] then
					table.insert(awards, a)
				end
			end
		end
	end
	local outcome: MissionFlow.Outcome = run.flow.outcome or "forced"
	local elapsed = MissionFlow.elapsed(run.flow, now())
	local stars = MissionFlow.stars(run.def.stars or {}, {
		outcome = outcome,
		burningAtEnd = burning,
		rescued = rescued,
		trapped = trapped,
		elapsed = elapsed,
		downs = downs,
	})
	return {
		locationId = run.locationId,
		seconds = math.floor(elapsed),
		firesOut = run.firesOut,
		burnedParts = charred,
		rescued = rescued,
		trapped = trapped,
		burningAtEnd = burning,
		stars = stars,
		reason = MissionFlow.endReason(outcome),
		awards = awards,
		stats = stats,
		missionId = run.missionId,
		instanceId = run.id,
	}
end

local HEADLINE: { [string]: string } = {
	success = "ALL CLEAR!",
	time = "TIME'S UP!",
	wiped = "SQUAD WIPED!",
	forced = "MISSION ABORTED",
}

-- event handlers (side effects for MissionFlow events) ------------------------------------------------

local function onTeleport(run: Live)
	safe("ParkAt", function()
		local Vehicle = services.VehicleService
		if Vehicle and type(Vehicle.ParkAt) == "function" then
			Vehicle:ParkAt(run.id)
		end
	end)
	safe("teleport", function()
		teleportSquad(run)
		setAnchored(run.players, true) -- held for the 3-2-1
	end)
	safe("GiveLoadout", function()
		local Tool = services.ToolService
		if Tool and type(Tool.GiveLoadout) == "function" then
			for _, p in run.players do
				Tool:GiveLoadout(p)
			end
		end
	end)
	safe("spawn rescues", function()
		spawnRescues(run)
	end)
end

local function onActive(run: Live)
	safe("release", function()
		setAnchored(run.players, false)
	end)
	notify(run.players, "ROLL OUT!", "good")
	playSound(run.players, "RollOut")
	safe("start fires", function()
		run.firesLit = lightFires(run)
	end)
	MissionService.RoundStarted:Fire(run.locationId)
	count("rounds_started")
	print(`[MissionService] {run.id} ({run.missionId}) ACTIVE: {#run.players} players, {run.firesLit} fires lit`)
end

local function onEnded(run: Live)
	safe("release", function()
		setAnchored(run.players, false)
	end)
	local payload = buildPayload(run)
	run.payload = payload
	if resultsRemote then
		for _, p in run.players do
			resultsRemote:FireClient(p, payload)
		end
	end
	local outcome = run.flow.outcome or "forced"
	notify(run.players, `{HEADLINE[outcome] or "MISSION OVER"} {string.rep("*", payload.stars)}`, if outcome == "success" then "good" else "bad")
	playSound(run.players, if outcome == "success" or outcome == "time" then "Success" else "Fail")
	MissionService.MissionEnded:Fire(run.id, payload)
	MissionService.RoundEnded:Fire(payload)
	count("missions_completed")
	count("rounds_completed")
	print(
		`[MissionService] {run.id} ({run.missionId}) over ({outcome}): {payload.rescued} rescued, {payload.burningAtEnd} burning, {payload.stars} stars`
	)
end

local function onDone(run: Live)
	local players = table.clone(run.players)
	runs[run.id] = nil
	for _, p in players do
		if p.Parent == Players then
			p:SetAttribute(Names.Attr.InstanceId, "")
		end
	end
	safe("back to station", function()
		setAnchored(players, false)
		local Map = services.MapService
		local Squad = services.SquadService
		for i, p in players do
			local char = p.Character
			if Map and char and char:FindFirstChild("HumanoidRootPart") then
				local slot = if Squad and type(Squad.GetHelmet) == "function" then Squad:GetHelmet(p) else i
				char:PivotTo(Map:GetSpawnCFrame(slot))
			end
		end
	end)
	safe("ReturnToLobby", function()
		local Lobby = services.LobbyService
		if Lobby and type(Lobby.ReturnToLobby) == "function" then
			Lobby:ReturnToLobby(players)
		end
	end)
	safe("cleanup peers", function()
		local Rescue = services.RescueService
		if Rescue and type(Rescue.ClearInstance) == "function" then
			Rescue:ClearInstance(run.id)
		end
		local Fire = services.FireService
		if Fire and type(Fire.ClearInstance) == "function" then
			Fire:ClearInstance(run.id)
		end
	end)
	safe("DestroyInstance", function()
		local Map = services.MapService
		if Map and type(Map.DestroyInstance) == "function" then
			Map:DestroyInstance(run.id)
		elseif run.model.Parent then
			run.model:Destroy()
		end
	end)
	summarize()
end

local function handle(run: Live, events: { string })
	for _, ev in events do
		if ev == "teleport" then
			onTeleport(run)
		elseif ev == "count3" or ev == "count2" or ev == "count1" then
			notify(run.players, string.sub(ev, 6), "info")
			playSound(run.players, "Countdown")
		elseif ev == "active" then
			onActive(run)
		elseif ev == "ended" then
			onEnded(run)
		elseif ev == "done" then
			onDone(run)
			return
		end
	end
	if #events > 0 then
		publish(run)
	end
end

local function tickAll()
	local t = now()
	for _, run in runs do
		local ok, err = pcall(function()
			local obs = if run.flow.state == "Active" then observe(run) else nil
			handle(run, MissionFlow.tick(run.flow, t, obs))
		end)
		if not ok then
			warn(`[MissionService] tick {run.id} failed: {err}`)
		end
	end
end

-- lifecycle ------------------------------------------------------------------------------------------

function MissionService:Init(all: { [string]: any })
	services = all
end

function MissionService:Start()
	alarmRemote = Net.event("Mission", "Alarm")
	resultsRemote = Net.event("Mission", "Results")
	started = true
	summarize()

	local Fire = services.FireService
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(part: BasePart, _by: Player?)
			for _, run in runs do
				if run.flow.state == "Active" and part:IsDescendantOf(run.model) then
					run.firesOut += 1
					return
				end
			end
		end)
	end
	local Squad = services.SquadService
	if Squad and Squad.Downed then
		Squad.Downed:Connect(function(victim: Player, _cause: string, _culprit: Player?)
			local run = runOf(victim)
			if run and run.flow.state == "Active" then
				run.downs += 1
			end
		end)
	end
	Players.PlayerAdded:Connect(function(p: Player)
		p:SetAttribute(Names.Attr.InstanceId, "")
	end)
	for _, p in Players:GetPlayers() do
		if p:GetAttribute(Names.Attr.InstanceId) == nil then
			p:SetAttribute(Names.Attr.InstanceId, "")
		end
	end

	-- one driver loop for every run
	task.spawn(function()
		while true do
			task.wait(GameConfig.TickSeconds or 0.25)
			tickAll()
		end
	end)

	-- v1 auto round: only when the lobby/squad flow is off.
	task.spawn(function()
		local function lobbyPlayers(): { Player }
			local out = {}
			for _, p in Players:GetPlayers() do
				if runOf(p) == nil then
					table.insert(out, p)
				end
			end
			return out
		end
		local function wanted(): boolean
			local lc = lobbyConfig()
			if lc and lc.UseLobby == true then
				return false
			end
			return GameConfig.AutoStart == true and next(runs) == nil and #lobbyPlayers() > 0
		end
		while true do
			task.wait(1)
			if wanted() then
				local waited = 0
				while waited < GameConfig.LobbySeconds and wanted() do
					task.wait(0.5)
					waited += 0.5
				end
				if wanted() then
					MissionService:StartRound(nil, nil)
				end
			end
		end
	end)
end

-- public API -----------------------------------------------------------------------------------------

function MissionService:StartMission(squad: { Player }, missionId: string, seconds: number?): string?
	if not started then
		warn("[MissionService] StartMission before Start")
		return nil
	end
	local def = findDef(missionId)
	if not def then
		warn(`[MissionService] StartMission: unknown mission {missionId}`)
		return nil
	end
	if def.enabled ~= true then
		warn(`[MissionService] StartMission: {missionId} is not enabled`)
		return nil
	end
	local players: { Player } = {}
	for _, p in (if type(squad) == "table" then squad else {}) do
		if typeof(p) == "Instance" and p:IsA("Player") and p.Parent == Players and runOf(p) == nil then
			table.insert(players, p)
		end
	end
	if #players == 0 then
		warn(`[MissionService] StartMission {missionId}: nobody free to play`)
		return nil
	end
	local Map = services.MapService
	if not (Map and type(Map.BuildInstance) == "function") then
		warn("[MissionService] StartMission: MapService:BuildInstance unavailable")
		return nil
	end
	seq += 1
	local id = `M{seq}`
	local okBuild, model = pcall(Map.BuildInstance, Map, def.locationId, id)
	if not okBuild or not model then
		warn(`[MissionService] StartMission {missionId}: could not build {def.locationId} ({model})`)
		return nil
	end
	local t = now()
	local flow = MissionFlow.new({
		seconds = seconds or def.seconds or GameConfig.RoundSeconds,
		alarm = GameConfig.AlarmSeconds,
		intro = GameConfig.IntroSeconds,
		results = GameConfig.ResultsSeconds,
		grace = GameConfig.AllOutGraceSeconds,
	}, t)
	local squadId = players[1]:GetAttribute(Names.Attr.SquadId)
	local run: Live = {
		id = id,
		seq = seq,
		def = def,
		missionId = def.id,
		locationId = def.locationId,
		model = model,
		squadId = if type(squadId) == "string" and squadId ~= "" then squadId else nil,
		players = players,
		flow = flow,
		firesOut = 0,
		firesLit = 0,
		downs = 0,
		payload = nil,
	}
	model:SetAttribute(Names.Attr.InstanceId, id)
	model:SetAttribute(Names.Attr.MissionId, def.id)

	-- per-player blame ledger: a global Reset only when nobody else is mid-mission
	safe("Blame reset", function()
		local Blame = services.BlameService
		if not Blame then
			return
		end
		if type(Blame.ResetPlayers) == "function" then
			Blame:ResetPlayers(players)
		elseif next(runs) == nil and type(Blame.Reset) == "function" then
			Blame:Reset()
		end
	end)

	runs[id] = run
	for _, p in players do
		p:SetAttribute(Names.Attr.InstanceId, id)
	end
	publish(run)

	local title = def.title or GameConfig.LocationName
	if alarmRemote then
		for _, p in players do
			alarmRemote:FireClient(p, def.id, title)
		end
	end
	notify(players, `ALARM! Fire at {title}!`, "bad")
	playSound(players, "Alarm")
	MissionService.MissionStarted:Fire(id, def.id)
	count("missions_started")
	print(`[MissionService] {id} started: {def.id} at {def.locationId} for {#players} player(s)`)
	return id
end

function MissionService:EndMission(instanceId: string, reason: Types.EndReason)
	local run = runs[instanceId]
	if not run then
		return
	end
	local outcome: MissionFlow.Outcome = if reason == "allOut" then "success" elseif reason == "time" then "time" else "forced"
	handle(run, MissionFlow.finish(run.flow, now(), outcome))
end

function MissionService:GetMission(instanceId: string): Types.MissionRun?
	local run = runs[instanceId]
	if not run then
		return nil
	end
	local ids = {}
	for _, p in run.players do
		table.insert(ids, p.UserId)
	end
	local state = run.flow.state
	return {
		instanceId = run.id,
		missionId = run.missionId,
		locationId = run.locationId,
		squadId = run.squadId,
		players = ids,
		state = if state == "Done" then "Results" else state,
		endsAt = if run.flow.endsAt > 0 then run.flow.endsAt else run.flow.alarmEndsAt + run.flow.timing.seconds,
	}
end

function MissionService:GetMissions(): { Types.MissionRun }
	local out = {}
	for id in runs do
		local m = self:GetMission(id)
		if m then
			table.insert(out, m)
		end
	end
	table.sort(out, function(a, b)
		return a.instanceId < b.instanceId
	end)
	return out
end

-- v1 API: one round for everyone in the lobby, as a mission instance.
function MissionService:StartRound(locationId: string?, seconds: number?)
	local def = if locationId then defForLocation(locationId) else findDef(GameConfig.DefaultMissionId)
	if not def then
		warn(`[MissionService] StartRound: no enabled mission for {locationId or GameConfig.DefaultMissionId}`)
		return
	end
	local squad = {}
	for _, p in Players:GetPlayers() do
		if runOf(p) == nil then
			table.insert(squad, p)
		end
	end
	self:StartMission(squad, def.id, seconds)
end

function MissionService:EndRound(reason: Types.EndReason)
	for id in table.clone(runs) do
		self:EndMission(id, reason)
	end
end

function MissionService:GetState(): Types.RoundState
	return (workspace:GetAttribute(Names.Attr.RoundState) :: any) or "Lobby"
end

-- test hooks -----------------------------------------------------------------------------------------
function MissionService:_startRound(locationId: string, seconds: number)
	self:StartRound(locationId, seconds)
end

-- userIds nil = every player not already in a mission
function MissionService:_startMission(userIds: { number }?, missionId: string, seconds: number?): string?
	local squad = {}
	for _, p in Players:GetPlayers() do
		if userIds == nil or table.find(userIds, p.UserId) then
			table.insert(squad, p)
		end
	end
	return self:StartMission(squad, missionId, seconds)
end

function MissionService:_endMission(instanceId: string)
	self:EndMission(instanceId, "forced")
end

function MissionService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local mission = net and net:FindFirstChild("Mission")
	if not (mission and mission:FindFirstChild("Alarm") and mission:FindFirstChild("Results")) then
		return false, "Mission remotes missing"
	end
	-- the pure flow must still behave (cheap smoke test of the state machine)
	local f = MissionFlow.new({ seconds = 10, alarm = 2, intro = 1, results = 1, grace = 0 }, 0)
	local evs = table.concat(MissionFlow.tick(f, 2, nil), ",")
	if evs ~= "teleport,count1,active" then
		return false, `MissionFlow intro gave {evs}`
	end
	local live = 0
	for _, run in runs do
		live += 1
		if not run.model then
			return false, `{run.id} has no model`
		end
	end
	return true, `state {self:GetState()}, {live} running`
end

return MissionService
