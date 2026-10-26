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
--   MissionService:StartMission(squad: { Player }, missionId: string, seconds: number?, opts: StartOpts?): string?
--     -- instanceId. opts (v2 dispatch radio): siteId = that exact site, origin = measure distance/travel
--     -- from there (the caller's truck), noFallback = no v1.5 instance when no site is free (nil instead)
--   MissionService:FreeSites(): { { siteId, types, pos, address } }  -- IncidentSites nobody is working
--   MissionService:EndMission(instanceId: string, reason: Types.EndReason)
--   MissionService:GetMission(instanceId: string): Types.MissionRun?
--   MissionService:GetMissions(): { Types.MissionRun }
--   MissionService:LeaveResults(player): boolean  -- NEXT CALL!: leave a finished dispatch run's results now
--   MissionService:JoinRun(player, instanceId): boolean -- LATE JOIN (LobbyService): hop into a dispatch run
--     that is still Dispatched (driving), within its mission's max players
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
-- v2 DISPATCH (docs/game/08 "Flow" + "Dispatch missions"; default, GameConfig.UseInstances = false):
--   StartMission picks the nearest free IncidentSite (tag; attrs SiteId, MissionTypes, Busy, Address?)
--   whose MissionTypes lists the mission (ties within SiteTieStuds: random), claims it
--   (MapService:BindSite -> fresh copy, Busy, GetInstance(runId)), lights its FireStart markers and spawns
--   its rescues straight away, fires Mission/Alarm + "DISPATCH: <call> at <address>", and sets a waypoint
--   (NavigationService:SetWaypoint(squad, ArrivalZone|TruckSpot, label)). Nobody is teleported: the squad
--   drives. RoundState Dispatched -> Active when a squad member or their truck enters the ArrivalZone
--   (fast arrival = ArrivalBonusSeconds on the clock) -> Results -> done: ClearWaypoint,
--   Rescue/FireService:ClearInstance, MapService:RebuildSite, Busy cleared. Players stay where they are
--   (drive back, or BACK TO STATION on the results screen -> LobbyService:ReturnToLobby).
--   No free site for the mission -> the v1.5 instance path (GameConfig.InstanceFallback).
--   Run state: Workspace.Runs.<runId> Folder (attrs InstanceId, MissionId, RoundState, RoundEndsAt, SiteId,
--   LocationId, Address, Call; ObjectValue Site). Back-compat mirror Workspace.Instances.<runId> carries
--   the same attrs with RoundState "Active" while Dispatched (v1.5 readers: HUD, Audio, Blame, Graphics).
--   Remote added: Lobby/BackToStation (C->S, no args, 1/s; ResultsController already fires it).
--   Counters: missions_dispatched, missions_arrived, missions_fast_arrival, dispatch_no_site, missions_rekindled.
--   Every mission has something to do at its site: fires.starts "Scripted" lights FireStart markers too
--   (the hazard adds more), a run where nothing has burned GameConfig.RekindleSeconds after arrival
--   lights its FireStart markers once, and a site without RescueSpawn markers gets
--   invisible ones by its FireStarts.
--   ESCALATION: a call grows while the squad works it (catalog `escalation` phases, else
--   GameConfig.Escalation.Default): more fires on the upper floors, a flashover / explosion / collapse
--   set piece, extra people at spare RescueSpawn markers, each with a banner. A phase fires `at` s after
--   arrival or early after a quiet lull; "all clear" can't end the call while one is still to come.
--   Counter: escalations.
-- Test hooks (DevHook only): _startRound(locationId, seconds), _startMission(userIds|nil, missionId, seconds),
--   _endMission(instanceId), _escalate(instanceId), _runInfo(instanceId), _selftest()
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

-- v2 names from docs/game/08 (the frozen Names module doesn't carry them yet)
local SITE = {
	Tag = "IncidentSite",
	SiteId = "SiteId",
	MissionTypes = "MissionTypes",
	Busy = "Busy",
	Address = "Address",
	ArrivalZone = "ArrivalZone",
	TruckBay = "TruckBay",
	OwnerUserId = "OwnerUserId",
	Driver = "Driver",
}

type Live = {
	id: string,
	seq: number,
	def: any, -- Types.MissionDef
	missionId: string,
	locationId: string,
	model: Model, -- v1.5: the instance Model; v2: the bound IncidentSite Model
	mode: "instance" | "dispatch",
	siteId: string?,
	folder: Folder?, -- v2: Workspace.Runs.<id>
	mirror: Folder?, -- v2: Workspace.Instances.<id> (legacy readers)
	label: string, -- "House fire at 12 Maple St"
	squadId: string?,
	players: { Player },
	flow: MissionFlow.Run,
	firesOut: number,
	firesLit: number,
	rekindled: boolean?, -- the no-fire safety net already ran (rekindle)
	sawBurning: boolean?, -- something burned at this site during the run
	spareMarkers: { BasePart }?, -- RescueSpawn markers nobody was spawned at (escalation can use them)
	escFired: number?, -- escalation phases already fired (MissionCatalog `escalation`)
	escLastAt: number?, -- seconds after arrival when the last phase fired
	quietSince: number?, -- server time since when nothing has been burning (nil = something burns)
	downs: number,
	payload: Types.ResultsPayload?,
	rookie: boolean?, -- GameConfig.Rookie: someone in the squad is on one of their first calls
}

local services: { [string]: any } = {}
local alarmRemote: RemoteEvent? = nil
local resultsRemote: RemoteEvent? = nil
local runs: { [string]: Live } = {}
local claimed: { [string]: string } = {} -- v2: siteId -> runId
local seq = 0
local started = false
local rng = Random.new()

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

-- GameConfig.Rookie: anyone in the squad has played fewer than Rookie.Calls calls (profile missionsPlayed).
-- No profile yet (DataService missing / still loading) counts as a rookie: that is a brand-new player.
local function isRookieSquad(players: { Player }): boolean
	local cfg = GameConfig.Rookie
	if type(cfg) ~= "table" or (tonumber(cfg.Calls) or 0) <= 0 then
		return false
	end
	local Data = services.DataService
	for _, p in players do
		local played = 0
		if Data and type(Data.GetProfile) == "function" then
			local ok, profile = pcall(Data.GetProfile, Data, p)
			played = if ok and type(profile) == "table" then (tonumber(profile.missionsPlayed) or 0) else 0
		end
		if played < cfg.Calls then
			return true
		end
	end
	return false
end

local function rookieCfg(run: Live): any?
	return if run.rookie and type(GameConfig.Rookie) == "table" then GameConfig.Rookie else nil
end

-- The run's rescue list: the catalog's, squad-scaled, capped on rookie calls.
local function wantedRescues(run: Live): { { kind: string, count: number } }
	local wanted = MissionFlow.scaledRescues(run.def.rescues or {}, math.max(1, #run.players), GameConfig.RescuesPerExtraPlayers or 0)
	local rk = rookieCfg(run)
	if rk and tonumber(rk.MaxRescues) then
		wanted = MissionFlow.capRescues(wanted, rk.MaxRescues)
	end
	return wanted
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

-- v1/v1.5 readers only know Alarm/Active/Results: driving to the call counts as Active for them.
local function legacyState(state: string): string
	return if state == "Dispatched" then "Active" else state
end

local function childFolder(parent: Instance, name: string): Folder
	local f = parent:FindFirstChild(name)
	if not (f and f:IsA("Folder")) then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f :: Folder
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
		workspace:SetAttribute(Names.Attr.RoundState, legacyState(newest.flow.state))
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
	local endsAt = if run.flow.endsAt > 0 then run.flow.endsAt else run.flow.alarmEndsAt + run.flow.timing.seconds
	if run.mode == "dispatch" then
		local folder, mirror = run.folder, run.mirror
		if state ~= "Done" then
			if folder then
				folder:SetAttribute(Names.Attr.RoundState, state)
			end
			if mirror then
				mirror:SetAttribute(Names.Attr.RoundState, legacyState(state))
			end
		end
		if folder then
			folder:SetAttribute(Names.Attr.RoundEndsAt, endsAt)
		end
		if mirror then
			mirror:SetAttribute(Names.Attr.RoundEndsAt, endsAt)
		end
	else
		if state ~= "Done" then
			run.model:SetAttribute(Names.Attr.RoundState, state)
		end
		run.model:SetAttribute(Names.Attr.RoundEndsAt, endsAt)
	end
	summarize()
end

-- observation for MissionFlow.tick -----------------------------------------------------------------

local function rescueCounts(run: Live): (number, number, number)
	local rescued, trapped, lost = 0, 0, 0
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.InstanceId) == run.id or m:IsDescendantOf(run.model) then
			local state = m:GetAttribute(Names.Attr.RescueState)
			if state == "Rescued" then
				rescued += 1
			elseif m:GetAttribute("Bonus") == true then
				continue -- a twist's bonus rescue (TwistService cat): counts once saved, never holds the call
			elseif state == "Toasted" then -- lost, not still trapped (but still part of the total)
				lost += 1
			else
				trapped += 1
			end
		end
	end
	return rescued, trapped, lost
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

-- v2: the site's arrival target: ArrivalZone part, else its TruckSpot, else nil (use the pivot).
local function sitePart(site: Instance, name: string, tag: string?): BasePart?
	local named = site:FindFirstChild(name, true)
	if named and named:IsA("BasePart") then
		return named
	end
	if tag then
		for _, inst in CollectionService:GetTagged(tag) do
			if inst:IsA("BasePart") and inst:IsDescendantOf(site) then
				return inst
			end
		end
	end
	return nil
end

local function arrivalTarget(site: Instance): BasePart?
	return sitePart(site, SITE.ArrivalZone, nil) or sitePart(site, "TruckSpot", Names.Tag.TruckSpot)
end

local function sitePos(site: Instance): Vector3
	local target = arrivalTarget(site)
	if target then
		return target.Position
	end
	return if site:IsA("Model") then site:GetPivot().Position else Vector3.zero
end

local function inArrival(site: Instance, pos: Vector3): boolean
	local zone = sitePart(site, SITE.ArrivalZone, nil)
	local margin = GameConfig.ArrivalMargin or 4
	if zone then
		local rel = zone.CFrame:PointToObjectSpace(pos)
		local half = zone.Size / 2
		return math.abs(rel.X) <= half.X + margin
			and math.abs(rel.Z) <= half.Z + margin
			and math.abs(rel.Y) <= math.max(half.Y, 30) + margin
	end
	local centre = sitePos(site)
	local flat = Vector3.new(pos.X - centre.X, 0, pos.Z - centre.Z)
	return flat.Magnitude <= (GameConfig.ArrivalRadius or 40) and math.abs(pos.Y - centre.Y) <= 40
end

-- Every truck that belongs to (or is driven by) a squad member.
local function squadTrucks(players: { Player }): { Model }
	local ids: { [number]: boolean } = {}
	for _, p in players do
		ids[p.UserId] = true
	end
	local out: { Model } = {}
	local seen: { [Instance]: boolean } = {}
	for _, t in CollectionService:GetTagged(Names.Tag.Truck) do
		if t:IsA("Model") and t:IsDescendantOf(workspace) then
			local owner = t:GetAttribute(SITE.OwnerUserId)
			local driver = t:GetAttribute(SITE.Driver)
			if (type(owner) == "number" and ids[owner]) or (type(driver) == "number" and ids[driver]) then
				seen[t] = true
				table.insert(out, t)
			end
		end
	end
	local Vehicle = services.VehicleService
	if Vehicle and type(Vehicle.GetTruck) == "function" then
		for _, p in players do
			local ok, t = pcall(Vehicle.GetTruck, Vehicle, p)
			if ok and typeof(t) == "Instance" and t:IsA("Model") and not seen[t] and t:GetAttribute(SITE.OwnerUserId) == p.UserId then
				seen[t] = true
				table.insert(out, t)
			end
		end
	end
	return out
end

local function squadArrived(run: Live): boolean
	if not run.model.Parent then
		return false
	end
	for _, p in run.players do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and inArrival(run.model, root.Position) then
			return true
		end
	end
	for _, t in squadTrucks(run.players) do
		if inArrival(run.model, t:GetPivot().Position) then
			return true
		end
	end
	return false
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
		-- GameConfig.SoloNeverWipes: one downed player isn't a "squad wiped" (they respawn at the truck)
		alive = if GameConfig.SoloNeverWipes and #run.players == 1 then math.max(alive, 1) else alive,
		arrived = if run.flow.state == "Dispatched" then squadArrived(run) else nil,
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
			-- a seated character is welded to its truck seat: get out first or the pivot snaps back
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.SeatPart then
				local weld = hum.SeatPart:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
				hum.Sit = false
				task.wait()
			end
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

-- Fires the call should have burning on scene for this squad (docs/game/08 "squad scaling"):
-- max(fires.count, GameConfig.MinArrivalFires) * (1 + FireScalePerPlayer * (players - 1)), rounded.
local function fireTarget(run: Live): number
	local rk = rookieCfg(run)
	if rk and tonumber(rk.ArrivalFires) then
		return rk.ArrivalFires
	end
	local fires = run.def.fires or {}
	return MissionFlow.scaledFires(
		fires.count or GameConfig.StartFires or 3,
		math.max(1, #run.players),
		GameConfig.FireScalePerPlayer or 0,
		GameConfig.MinArrivalFires
	)
end

local function p3(v: Vector3): MissionFlow.P3
	return { x = v.X, y = v.Y, z = v.Z }
end

-- Light up to `want` fires: the site's FireStart markers first (shuffled), then extra Flammable parts
-- spread round the site (MissionFlow.spreadPick: far from every fire already burning, so other rooms /
-- floors, and never within GameConfig.FireAvoidRescueStuds of a RescueSpawn).
-- `force` overrides the mission's fires.starts. "Scripted" missions (cigarette, campfire) light the
-- site's FireStart markers like any other call; their hazard adds more fires on top, so a hazard that
-- never fires (no farmer near the hay, a city site without its prop) can't leave a call with nothing to do.
type SpreadOpts = { up: boolean?, near: Vector3?, radius: number? }
local spreadFires: (run: Live, need: number, pool: { BasePart }?, opts: SpreadOpts?) -> number

local function lightFires(run: Live, limit: number?, force: string?): number
	local Fire = services.FireService
	if not (Fire and type(Fire.Ignite) == "function") then
		return 0
	end
	local fires = run.def.fires or {}
	local want = fireTarget(run)
	if limit then
		want = math.min(want, limit)
	end
	if want <= 0 then
		return 0
	end
	local mode = force or fires.starts or "FireStart"
	if mode == "Scripted" then
		mode = "FireStart"
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
		-- markers with attr Priority (the Sky Tower's roof) always burn first
		local first, rest = {}, {}
		for _, m in markers do
			table.insert(if m:GetAttribute("Priority") == true then first else rest, m)
		end
		table.move(rest, 1, #rest, #first + 1, first)
		markers = first
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
	if lit >= want or #pool == 0 then
		return lit
	end
	return lit + spreadFires(run, want - lit, pool, nil)
end

-- Light `need` fires on Flammable parts spread round the site: far from every fire already burning (so
-- other rooms / floors), never within GameConfig.FireAvoidRescueStuds of a RescueSpawn.
--   opts.up: prefer parts well above the lowest fire / the ground floor ("spreading upstairs")
--   opts.near, opts.radius: only parts within radius of near (a flashover in one room)
spreadFires = function(run: Live, need: number, pool: { BasePart }?, opts: SpreadOpts?): number
	local Fire = services.FireService
	if need <= 0 or not (Fire and type(Fire.Ignite) == "function") then
		return 0
	end
	local o = opts or {}
	local all = pool or flammables(run.model)
	local lit = 0
	local rng = Random.new()
	-- extra fire zones: spread out, away from the people waiting to be rescued
	local cands: { BasePart } = {}
	for _, part in all do
		if not part:HasTag(Names.Tag.Burning) then
			if o.near and (part.Position - o.near).Magnitude > (o.radius or 20) then
				continue
			end
			table.insert(cands, part)
		end
	end
	if o.up and #cands > 0 then
		-- "upstairs": parts at least 7 studs above the site's lowest Flammable part
		local low = math.huge
		for _, part in all do
			low = math.min(low, part.Position.Y)
		end
		local upper: { BasePart } = {}
		for _, part in cands do
			if part.Position.Y >= low + 7 then
				table.insert(upper, part)
			end
		end
		if #upper >= need then
			cands = upper
		end
	end
	for i = #cands, 2, -1 do
		local j = rng:NextInteger(1, i)
		cands[i], cands[j] = cands[j], cands[i]
	end
	local maxCands = 600 -- big district sites hold ~1.7k Flammable parts: a random sample is plenty
	while #cands > maxCands do
		table.remove(cands)
	end
	local taken: { MissionFlow.P3 } = {}
	for _, part in all do
		if part:HasTag(Names.Tag.Burning) then
			table.insert(taken, p3(part.Position))
		end
	end
	local avoid: { MissionFlow.P3 } = {}
	for _, m in tagged(Names.Tag.RescueSpawn, run.model) do
		if m:IsA("BasePart") then
			table.insert(avoid, p3(m.Position))
		end
	end
	local pts: { MissionFlow.P3 } = {}
	for i, part in cands do
		pts[i] = p3(part.Position)
	end
	-- ask for a few spares: an Ignite can fail (cap, an odd part)
	for _, i in MissionFlow.spreadPick(pts, taken, avoid, GameConfig.FireAvoidRescueStuds or 8, need + 4) do
		if lit >= need then
			break
		end
		if Fire:Ignite(cands[i], nil) then
			lit += 1
		end
	end
	return lit
end

-- A site without RescueSpawn markers still gets its people: invisible markers by its FireStart markers
-- (else round its arrival target), one per wanted rescue. They live in the bound site copy, so the
-- site reset removes them.
local function fallbackRescueMarkers(run: Live): { Instance }
	local want = 0
	for _, r in wantedRescues(run) do
		want += r.count or 0
	end
	local anchors: { Vector3 } = {}
	for _, m in tagged(Names.Tag.FireStart, run.model) do
		if m:IsA("BasePart") then
			table.insert(anchors, m.Position)
		end
	end
	if #anchors == 0 then
		table.insert(anchors, sitePos(run.model))
	end
	local out: { Instance } = {}
	for i = 1, math.min(want, 12) do
		local base = anchors[(i - 1) % #anchors + 1]
		local a = i * 2.4
		local p = Instance.new("Part")
		p.Name = `FallbackRescue{i}`
		p.Anchored, p.CanCollide, p.CanQuery, p.CanTouch = true, false, false, false
		p.Transparency = 1
		p.Size = Vector3.new(2, 2, 2)
		p.CFrame = CFrame.new(base + Vector3.new(math.cos(a) * 6, 0, math.sin(a) * 6))
		p:AddTag(Names.Tag.RescueSpawn)
		p.Parent = run.model
		table.insert(out, p)
	end
	if #out > 0 then
		warn(`[MissionService] {run.id}: {run.siteId} has no RescueSpawn markers; made {#out}`)
	end
	return out
end

local function spawnRescues(run: Live)
	local Rescue = services.RescueService
	if not Rescue then
		return
	end
	-- bigger squads: +1 rescuable per GameConfig.RescuesPerExtraPlayers extra players (where markers allow)
	local wanted = wantedRescues(run)
	if type(Rescue.SpawnAt) == "function" then
		local markers = tagged(Names.Tag.RescueSpawn, run.model)
		if #markers == 0 then
			markers = fallbackRescueMarkers(run)
		end
		table.sort(markers, byName)
		local kinds: { string } = {}
		for i, m in markers do
			kinds[i] = tostring(m:GetAttribute(Names.Attr.Kind) or "")
		end
		run.spareMarkers = {}
		for i, kind in MissionFlow.assignRescues(kinds, wanted) do
			if kind then
				safe(`Rescue:SpawnAt {kind}`, function()
					Rescue:SpawnAt(run.id, markers[i], kind)
				end)
			elseif markers[i]:IsA("BasePart") then
				-- left empty: an escalation phase can find someone here later ("someone's still inside!")
				table.insert(run.spareMarkers :: { BasePart }, markers[i] :: BasePart)
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
	local rescued, trapped, lost = rescueCounts(run)
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
	local integrity: number? = nil
	local Structure = services.StructureService
	if Structure and type(Structure.GetIntegrity) == "function" then
		local ok, v = pcall(Structure.GetIntegrity, Structure, run.model)
		integrity = if ok and type(v) == "number" then v else nil
	end
	local stars = MissionFlow.stars(run.def.stars or {}, {
		outcome = outcome,
		burningAtEnd = burning,
		rescued = rescued,
		trapped = trapped,
		lost = lost,
		elapsed = elapsed,
		downs = downs,
		integrity = integrity,
		firesOut = run.firesOut,
	})
	-- rookie call that ran out of time: a win with what they did (at least 1 star), never TIME'S UP
	local rk = rookieCfg(run)
	local rookieWin = rk ~= nil and rk.TimeoutIsWin == true and outcome == "time"
	if rookieWin then
		stars = math.max(stars, 1)
	end
	return {
		locationId = run.locationId,
		seconds = math.floor(elapsed),
		firesOut = run.firesOut,
		burnedParts = charred,
		rescued = rescued,
		trapped = trapped,
		lost = lost, -- toasted: counts toward "RESCUED x / total"
		burningAtEnd = burning,
		stars = stars,
		reason = MissionFlow.endReason(outcome),
		awards = awards,
		stats = stats,
		missionId = run.missionId,
		instanceId = run.id,
		-- v2 extras (ResultsController ignores unknown fields)
		siteId = run.siteId,
		buildingIntegrity = integrity, -- StructureService; nil = no building burned
		arrivalSeconds = if run.flow.arrivedAt > 0 then math.floor(run.flow.arrivedAt - run.flow.startedAt) else nil,
		fastArrival = run.flow.fast,
		firesLit = run.firesLit, -- squad-scaled fire zones (ResultsController ignores unknown fields)
		squadSize = #run.players,
		rookie = run.rookie == true, -- ResultsController: "CALL COMPLETE!" instead of TIME'S UP
		rookieWin = rookieWin,
	} :: any
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

local function giveLoadout(players: { Player })
	safe("GiveLoadout", function()
		local Tool = services.ToolService
		if Tool and type(Tool.GiveLoadout) == "function" then
			for _, p in players do
				Tool:GiveLoadout(p)
			end
		end
	end)
end

-- v2: first squad member (or truck) inside the ArrivalZone.
local function onArrived(run: Live)
	local secs = math.floor(run.flow.arrivedAt - run.flow.startedAt)
	if run.flow.fast then
		notify(run.players, `ON SCENE in {secs}s! FAST RESPONSE +{GameConfig.ArrivalBonusSeconds}s`, "good")
		count("missions_fast_arrival")
	else
		notify(run.players, `ON SCENE! Grab your gear from the truck.`, "good")
	end
	playSound(run.players, "RollOut")
	safe("flare-up", function()
		local Fire = services.FireService
		local rk = rookieCfg(run)
		if rk and Fire and type(Fire.SetAreaCap) == "function" then
			Fire:SetAreaCap(run.model, tonumber(rk.FireCap)) -- again: the run's interior is furnished by now
		end
		local already = if Fire and type(Fire.CountBurning) == "function" then (Fire:CountBurning(run.id) or 0) else 0
		local want = fireTarget(run)
		if already < want then
			run.firesLit += lightFires(run, want - already)
		end
	end)
	-- v2 gear comes off the truck (InventoryService); until that lands, hand out the v1 loadout here
	if services.InventoryService == nil then
		giveLoadout(run.players)
	end
	MissionService.RoundStarted:Fire(run.locationId)
	count("rounds_started")
	count("missions_arrived")
	print(`[MissionService] {run.id} ({run.missionId}) ARRIVED at {run.siteId} after {secs}s (fast={run.flow.fast})`)
end

local function onEnded(run: Live)
	safe("release", function()
		if run.mode == "instance" then
			setAnchored(run.players, false)
		end
	end)
	local payload = buildPayload(run)
	run.payload = payload
	safe("twist results", function() -- speed run: bestSeconds / newRecord (TwistService)
		local Twist = services.TwistService
		if Twist and type(Twist.OnResults) == "function" then
			Twist:OnResults(run.id, payload)
		end
	end)
	if resultsRemote then
		for _, p in run.players do
			resultsRemote:FireClient(p, payload)
		end
	end
	local outcome = run.flow.outcome or "forced"
	local rookieWin = (payload :: any).rookieWin == true
	local headline = if rookieWin then "CALL COMPLETE!" else (HEADLINE[outcome] or "MISSION OVER")
	notify(run.players, `{headline} {string.rep("*", payload.stars)}`, if outcome == "success" or rookieWin then "good" else "bad")
	if run.rookie then
		count(if rookieWin or outcome == "success" then "rookie_calls_won" else "rookie_calls_lost")
	end
	playSound(run.players, if outcome == "success" or outcome == "time" then "Success" else "Fail")
	MissionService.MissionEnded:Fire(run.id, payload)
	MissionService.RoundEnded:Fire(payload)
	count("missions_completed")
	count("rounds_completed")
	print(
		`[MissionService] {run.id} ({run.missionId}) over ({outcome}): {payload.rescued} rescued, {payload.burningAtEnd} burning, {payload.stars} stars`
	)
end

-- v2: results over. Players stay where they are (they drive back); the site is reset and freed.
local function onDoneDispatch(run: Live)
	local players = table.clone(run.players)
	runs[run.id] = nil
	for _, p in players do
		if p.Parent == Players and p:GetAttribute(Names.Attr.InstanceId) == run.id then
			p:SetAttribute(Names.Attr.InstanceId, "")
		end
	end
	-- only the ones out in the city: a player already at the station (within ~150 studs of a TruckBay)
	-- doesn't need to be told to drive back
	local away = {}
	for _, p in players do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		local atStation = false
		if root and root:IsA("BasePart") then
			for _, bay in CollectionService:GetTagged(SITE.TruckBay) do
				if bay:IsA("BasePart") and (bay.Position - root.Position).Magnitude <= 150 then
					atStation = true
					break
				end
			end
		end
		if not atStation then
			table.insert(away, p)
		end
	end
	notify(away, "Call closed! Back on patrol: DISPATCH has more calls, or head back to the station.", "info")
	safe("StowHose", function()
		local Inv = services.InventoryService
		if Inv and type(Inv.StowHose) == "function" then
			for _, p in players do
				Inv:StowHose(p)
			end
		end
	end)
	safe("ClearWaypoint", function()
		local Nav = services.NavigationService
		if Nav and type(Nav.ClearWaypoint) == "function" then
			Nav:ClearWaypoint(players)
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
		if run.rookie and Fire and type(Fire.SetAreaCap) == "function" then
			Fire:SetAreaCap(run.model, nil) -- the site's next call (maybe not a rookie's) burns normally
		end
	end)
	local siteId = run.siteId
	safe("RebuildSite", function()
		local Map = services.MapService
		if siteId and Map and type(Map.RebuildSite) == "function" then
			Map:RebuildSite(siteId)
		elseif run.model.Parent then
			run.model:SetAttribute(SITE.Busy, false)
			run.model:SetAttribute(Names.Attr.InstanceId, nil)
		end
	end)
	if siteId and claimed[siteId] == run.id then
		claimed[siteId] = nil
	end
	if run.folder then
		run.folder:Destroy()
	end
	if run.mirror then
		run.mirror:Destroy()
	end
	summarize()
end

local function onDone(run: Live)
	if run.mode == "dispatch" then
		onDoneDispatch(run)
		return
	end
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
	safe("StowHose", function()
		local Inv = services.InventoryService
		if Inv and type(Inv.StowHose) == "function" then
			for _, p in players do
				Inv:StowHose(p)
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
		elseif ev == "arrived" then
			onArrived(run)
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

-- Safety net: a call must never be "all clear" before anything burned. If nothing has burned at all a
-- few seconds after arrival (the hazard that should light it
-- didn't, or every Ignite failed), light the site's FireStart markers (then random Flammable parts).
local function rekindle(run: Live, obs: MissionFlow.Obs, t: number)
	if obs.burning > 0 then
		run.sawBurning = true
	end
	-- only when nothing has burned at all: a call the squad (or a tidal wave) put out stays out
	if run.rekindled or run.sawBurning or run.firesOut > 0 or not run.model.Parent then
		return
	end
	local since = t - (if run.flow.arrivedAt > 0 then run.flow.arrivedAt else run.flow.activeSince)
	if since < (GameConfig.RekindleSeconds or 4) then
		return
	end
	run.rekindled = true
	local lit = lightFires(run, nil, "FireStart")
	run.firesLit += lit
	obs.burning += lit
	count("missions_rekindled")
	print(`[MissionService] {run.id} ({run.missionId}): nothing burning {math.floor(since)}s after arrival, lit {lit} fires`)
end

-- escalation -----------------------------------------------------------------------------------------
-- A call grows while the squad works it (MissionCatalog `escalation`, else GameConfig.Escalation.Default):
-- each phase lights more fires (scaled with the squad like the arrival fires), on the upper floors
-- (`up`) or as a set piece (`setPiece` = "flashover" | "explosion" | "collapse"), can turn up extra
-- people at RescueSpawn markers nobody was spawned at (`rescue`), and shouts its `text` banner. Phases
-- fire `at` seconds after arrival, or early once the scene has been quiet for Escalation.LullSeconds.
-- While a phase is still to come the call can't end "all clear" (obs.held).

local function escalationPhases(run: Live): { any }
	local rk = rookieCfg(run)
	if rk and rk.NoEscalation then
		return {}
	end
	local e = run.def.escalation
	if type(e) == "table" then
		return e
	end
	local cfg = GameConfig.Escalation
	return if type(cfg) == "table" and type(cfg.Default) == "table" then cfg.Default else {}
end

local function hazardFx(kind: string, pos: Vector3, params: { [string]: any }?)
	safe("hazard fx", function()
		Net.event("Hazard", "Fx"):FireAllClients(kind, pos, params or {})
	end)
end

-- A burning part to centre a set piece on (Priority / explosion props first), else any Flammable one.
local function setPieceSpot(run: Live, kind: string): BasePart?
	if kind == "explosion" then
		for _, inst in tagged(Names.Tag.Hazard, run.model) do
			if inst:IsA("BasePart") and inst:GetAttribute(Names.Attr.HazardId) == "explosion" then
				return inst
			end
		end
	end
	local burning = tagged(Names.Tag.Burning, run.model)
	if #burning > 0 then
		local b = burning[rng:NextInteger(1, #burning)]
		if b:IsA("BasePart") then
			return b
		end
	end
	local pool = flammables(run.model)
	return if #pool > 0 then pool[rng:NextInteger(1, #pool)] else nil
end

local function escalate(run: Live, phase: any, index: number)
	if not run.model.Parent then
		return
	end
	local n = MissionFlow.scaledFires(tonumber(phase.fires) or 0, math.max(1, #run.players), GameConfig.FireScalePerPlayer or 0, 0)
	local lit = 0
	local kind = phase.setPiece
	if kind == "flashover" or kind == "explosion" or kind == "collapse" then
		local spot = setPieceSpot(run, kind)
		if spot then
			local pos = spot.Position
			local Hazard = services.HazardService
			if kind == "explosion" and Hazard and type(Hazard.Trigger) == "function" then
				safe("set piece explosion", function()
					Hazard:Trigger(run.id, "explosion", { position = pos, radius = tonumber(phase.radius) or 18 })
				end)
			elseif kind == "collapse" and Hazard and type(Hazard.Trigger) == "function" then
				safe("set piece collapse", function()
					if not Hazard:Trigger(run.id, "ceiling_collapse", { position = pos, radius = tonumber(phase.radius) or 18 }) then
						hazardFx("backdraft", pos)
					end
				end)
			else
				hazardFx("backdraft", pos)
			end
			-- the room around the set piece goes up, then the rest spreads out
			local cluster = math.ceil(n * 0.6)
			lit += spreadFires(run, cluster, nil, { near = pos, radius = tonumber(phase.radius) or 22 })
		end
	end
	if lit < n then
		lit += spreadFires(run, n - lit, nil, { up = phase.up == true })
	end
	run.firesLit += lit
	-- somebody nobody knew about: spawn at markers left empty when the call came in
	local found = 0
	local want = tonumber(phase.rescue) or 0
	local Rescue = services.RescueService
	if want > 0 and run.spareMarkers and Rescue and type(Rescue.SpawnAt) == "function" then
		local spare = run.spareMarkers :: { BasePart }
		while found < want and #spare > 0 do
			local m = table.remove(spare, rng:NextInteger(1, #spare)) :: BasePart
			if m.Parent then
				safe("escalation rescue", function()
					if Rescue:SpawnAt(run.id, m, tostring(m:GetAttribute(Names.Attr.Kind) or "Civilian")) then
						found += 1
					end
				end)
			end
		end
	end
	local text = if type(phase.text) == "string" then phase.text else "The fire's spreading!"
	notify(run.players, text, "bad")
	if found > 0 then
		local who = if type(phase.rescueText) == "string" then phase.rescueText else "Someone's still inside!"
		task.delay(2.5, function()
			notify(run.players, who, "bad")
		end)
	end
	count("escalations")
	print(`[MissionService] {run.id} ({run.missionId}) ESCALATION {index}: {lit} fires, {found} more rescues ({tostring(kind or (if phase.up then "up" else "spread"))})`)
end

-- Fires the next phase when it's due; returns true while a phase is still to come (holds "all clear").
local function escalationTick(run: Live, obs: MissionFlow.Obs, t: number): boolean
	local phases = escalationPhases(run)
	local fired = run.escFired or 0
	if fired >= #phases then
		return false
	end
	if obs.burning > 0 then
		run.quietSince = nil
	elseif run.quietSince == nil then
		run.quietSince = t
		if run.firesOut > 0 then
			notify(run.players, "Looks clear... don't roll up the hose yet. Something's still smouldering.", "info")
		end
	end
	local since = t - (if run.flow.arrivedAt > 0 then run.flow.arrivedAt else run.flow.activeSince)
	local cfg = GameConfig.Escalation or {}
	local quiet = if run.quietSince then t - run.quietSince else 0
	if MissionFlow.escalationDue(phases, fired, since, quiet, run.escLastAt or 0, { lull = cfg.LullSeconds or 8, minGap = cfg.MinGapSeconds or 30 }) then
		run.escFired = fired + 1
		run.escLastAt = since
		run.quietSince = nil
		escalate(run, phases[fired + 1], fired + 1)
		obs.burning = burningCount(run)
		local _, trapped = rescueCounts(run)
		obs.trapped = trapped
		return (run.escFired or 0) < #phases
	end
	return true
end

local function tickAll()
	local t = now()
	for _, run in runs do
		local ok, err = pcall(function()
			local st = run.flow.state
			local obs = if st == "Active" or st == "Dispatched" then observe(run) else nil
			if obs and st == "Dispatched" and obs.burning > 0 then
				run.sawBurning = true
			elseif obs and st == "Active" then
				rekindle(run, obs, t)
				obs.held = escalationTick(run, obs, t)
			end
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

	-- v2: "BACK TO STATION" on the results screen (ResultsController fires Lobby/BackToStation). Dispatched
	-- squads aren't teleported home when a call closes, so this is their shortcut.
	Net.onServer(Net.event("Lobby", "BackToStation"), { rate = 1, burst = 1 }, function(player: Player)
		local run = runOf(player)
		if run and (run.flow.state == "Dispatched" or run.flow.state == "Active" or run.flow.state == "Alarm") then
			pcall(Net.notify, player, "Finish the call first!", "bad")
			return
		end
		-- the DISPATCH radio's BACK TO STATION: your truck (with you in it) comes home too
		local Dispatch = services.DispatchService
		if Dispatch and type(Dispatch.GoHome) == "function" then
			local ok = pcall(Dispatch.GoHome, Dispatch, player)
			if ok then
				return
			end
		end
		local Lobby = services.LobbyService
		if Lobby and type(Lobby.ReturnToLobby) == "function" then
			Lobby:ReturnToLobby({ player })
		end
	end)

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

-- run setup -----------------------------------------------------------------------------------------

-- per-player blame ledger: a global Reset only when nobody else is mid-mission
local function resetBlame(players: { Player })
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
end

-- Where dispatch distances are measured from: the truck bays, else the station spawn pads.
local function stationPos(): Vector3?
	for _, tag in { SITE.TruckBay, Names.Tag.StationSpawn } do
		local sum, n = Vector3.zero, 0
		for _, inst in CollectionService:GetTagged(tag) do
			if inst:IsA("BasePart") and inst:IsDescendantOf(workspace) then
				sum += inst.Position
				n += 1
			end
		end
		if n > 0 then
			return sum / n
		end
	end
	local Map = services.MapService
	if Map and type(Map.GetSpawnCFrame) == "function" then
		local ok, cf = pcall(Map.GetSpawnCFrame, Map, 1)
		if ok and typeof(cf) == "CFrame" then
			return cf.Position
		end
	end
	return nil
end

local function siteIdOf(site: Instance): string
	local v = site:GetAttribute(SITE.SiteId)
	return if type(v) == "string" and v ~= "" then v else site.Name
end

local function allSites(): { Model }
	local Map = services.MapService
	if Map and type(Map.GetSites) == "function" then
		local ok, list = pcall(Map.GetSites, Map)
		if ok and type(list) == "table" then
			return list
		end
	end
	local out: { Model } = {}
	for _, inst in CollectionService:GetTagged(SITE.Tag) do
		if inst:IsA("Model") and inst:IsDescendantOf(workspace) then
			table.insert(out, inst)
		end
	end
	return out
end

-- The nearest free IncidentSite for the mission (MissionFlow.pickSite), or nil.
-- from: measure from here instead of the station (a dispatch radio call taken out in the city).
-- want: that exact site (the one the radio offered), if it is still free and hosts the mission.
local function chooseSite(missionId: string, from: Vector3?, want: string?, nearest: boolean?): (Model?, string?)
	if want then
		for _, site in allSites() do
			if siteIdOf(site) == want then
				local types = site:GetAttribute(SITE.MissionTypes)
				local free = site:GetAttribute(SITE.Busy) ~= true and claimed[want] == nil
				if free and MissionFlow.siteSupports(if type(types) == "string" then types else nil, missionId) then
					return site, want
				end
				return nil, nil
			end
		end
		return nil, nil
	end
	-- GameConfig.NearDispatch: calls that go to the NEAREST free site (the gas station by the hub)
	local near = if type(GameConfig.NearDispatch) == "table" then GameConfig.NearDispatch else {}
	local origin = from or stationPos()
	local infos: { MissionFlow.SiteInfo } = {}
	local byId: { [string]: Model } = {}
	for _, site in allSites() do
		local sid = siteIdOf(site)
		if byId[sid] then
			continue -- duplicate SiteId: first one wins
		end
		byId[sid] = site
		local types = site:GetAttribute(SITE.MissionTypes)
		table.insert(infos, {
			id = sid,
			types = if type(types) == "string" then types else nil,
			busy = site:GetAttribute(SITE.Busy) == true or claimed[sid] ~= nil,
			dist = if origin then (sitePos(site) - origin).Magnitude else 0,
		})
	end
	local sid = MissionFlow.pickSite(infos, missionId, GameConfig.SiteTieStuds, function(n: number): number
		return rng:NextInteger(1, n)
	end, if near[missionId] or nearest then 0 else GameConfig.MinDispatchStuds)
	if not sid then
		return nil, nil
	end
	return byId[sid], sid
end

-- v2: dispatch the squad to a free IncidentSite. nil when no site can host the mission.
-- City sites have no Address attr yet: "house-Town-3" reads like a bug in the DISPATCH banner, so make a
-- stable, readable street address from the site id instead ("27 Maple St").
local STREETS = { "Maple St", "Oak Ave", "Elm St", "Birch Rd", "Cedar Ln", "Pine St", "Willow Way", "Main St", "Ash Ct", "Juniper Dr" }
local function friendlyAddress(siteId: string): string
	local h = 0
	for i = 1, #siteId do
		h = (h * 31 + string.byte(siteId, i)) % 1000003
	end
	return `{(h % 89) + 2} {STREETS[(h // 89) % #STREETS + 1]}`
end

export type StartOpts = { siteId: string?, origin: Vector3?, noFallback: boolean? }

local function startDispatch(players: { Player }, def: any, seconds: number?, opts: StartOpts?): string?
	local o: StartOpts = opts or {}
	local rookie = isRookieSquad(players)
	local rk = if rookie and type(GameConfig.Rookie) == "table" then GameConfig.Rookie else nil
	local site, siteId = chooseSite(def.id, o.origin, o.siteId, rk ~= nil and rk.NearestSite == true)
	if not (site and siteId) then
		return nil
	end
	seq += 1
	local id = `M{seq}`
	claimed[siteId] = id
	-- fresh copy of the site, scoped to this run (FireService indexes it under the run id)
	local Map = services.MapService
	if Map and type(Map.BindSite) == "function" then
		local ok, bound = pcall(Map.BindSite, Map, siteId, id)
		if ok and typeof(bound) == "Instance" and bound:IsA("Model") then
			site = bound
		elseif not ok then
			warn(`[MissionService] BindSite {siteId} failed: {bound}`)
		end
	end
	local model = site :: Model
	model:SetAttribute(SITE.Busy, true)
	model:SetAttribute(Names.Attr.InstanceId, id)

	local origin = o.origin or stationPos()
	local dist = if origin then (sitePos(model) - origin).Magnitude else 0
	local travel = MissionFlow.travelAllowance(dist, {
		speed = GameConfig.TravelSpeed,
		min = GameConfig.TravelMinSeconds,
		max = GameConfig.TravelMaxSeconds,
	})
	local fastIn = if (GameConfig.FastArrivalSeconds or 0) > 0 then GameConfig.FastArrivalSeconds else math.floor(travel * 0.75)
	local flow = MissionFlow.newDispatch({
		seconds = seconds or def.seconds or GameConfig.RoundSeconds,
		travel = travel,
		fastArrival = fastIn,
		arrivalBonus = GameConfig.ArrivalBonusSeconds,
		alarm = 0,
		intro = 0,
		results = GameConfig.DispatchResultsSeconds or GameConfig.ResultsSeconds,
		grace = GameConfig.AllOutGraceSeconds,
	}, now())

	local addr = model:GetAttribute(SITE.Address)
	local address = if type(addr) == "string" and addr ~= "" then addr else friendlyAddress(siteId)
	local call = def.call or def.title or "Fire"
	local siteLoc = model:GetAttribute(Names.Attr.LocationId)
	local locationId = if type(siteLoc) == "string" and siteLoc ~= "" then siteLoc else def.locationId

	local function runFolder(parent: Instance): Folder
		local old = parent:FindFirstChild(id)
		if old then
			old:Destroy()
		end
		local f = Instance.new("Folder")
		f.Name = id
		f:SetAttribute(Names.Attr.InstanceId, id)
		f:SetAttribute(Names.Attr.MissionId, def.id)
		f:SetAttribute(SITE.SiteId, siteId)
		f:SetAttribute(Names.Attr.LocationId, locationId)
		f:SetAttribute(SITE.Address, address)
		f:SetAttribute("Call", call)
		f:SetAttribute("DispatchedAt", flow.startedAt)
		local ref = Instance.new("ObjectValue")
		ref.Name = "Site"
		ref.Value = model
		ref.Parent = f
		f.Parent = parent
		return f
	end

	local squadId = players[1]:GetAttribute(Names.Attr.SquadId)
	local run: Live = {
		id = id,
		seq = seq,
		def = def,
		missionId = def.id,
		locationId = locationId,
		model = model,
		mode = "dispatch",
		siteId = siteId,
		folder = runFolder(childFolder(workspace, "Runs")),
		mirror = runFolder(childFolder(workspace, "Instances")),
		label = `{call} at {address}`,
		squadId = if type(squadId) == "string" and squadId ~= "" then squadId else nil,
		players = players,
		flow = flow,
		firesOut = 0,
		firesLit = 0,
		downs = 0,
		payload = nil,
		rookie = rookie,
	}
	resetBlame(players)
	if rk then
		count("rookie_calls")
		safe("rookie fire cap", function()
			local Fire = services.FireService
			if Fire and type(Fire.SetAreaCap) == "function" then
				Fire:SetAreaCap(model, tonumber(rk.FireCap))
			end
		end)
	end
	runs[id] = run
	for _, p in players do
		p:SetAttribute(Names.Attr.InstanceId, id)
	end
	publish(run)

	-- the call comes in: station alarm, banner, toast
	if alarmRemote then
		for _, p in players do
			alarmRemote:FireClient(p, def.id, address)
		end
	end
	notify(players, `DISPATCH: {run.label}`, "bad")
	playSound(players, "Alarm")
	safe("SetWaypoint", function()
		local Nav = services.NavigationService
		if Nav and type(Nav.SetWaypoint) == "function" then
			local target: any = arrivalTarget(model) or sitePos(model)
			Nav:SetWaypoint(players, target, run.label)
		end
	end)
	-- one small fire smoulders while you drive; the rest flare up when you arrive (GameConfig.DispatchFires)
	safe("start fires", function()
		run.firesLit = lightFires(run, GameConfig.DispatchFires or 1)
	end)
	safe("spawn rescues", function()
		spawnRescues(run)
	end)
	MissionService.MissionStarted:Fire(id, def.id)
	count("missions_started")
	count("missions_dispatched")
	print(
		`[MissionService] {id} DISPATCHED: {def.id} at {siteId} ({address}), {math.floor(dist)} studs, {travel}s travel, {run.firesLit} fires, {#players} player(s){if rookie then " ROOKIE" else ""}`
	)
	return id
end

-- public API -----------------------------------------------------------------------------------------

function MissionService:StartMission(squad: { Player }, missionId: string, seconds: number?, opts: StartOpts?): string?
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
	if GameConfig.UseInstances ~= true then
		local id = startDispatch(players, def, seconds, opts)
		if id then
			return id
		end
		count("dispatch_no_site")
		if opts and opts.noFallback then
			return nil -- the caller (DispatchService) tells the player the call is taken
		end
		if GameConfig.InstanceFallback ~= true then
			notify(players, `No free {def.call or def.title} call right now. Try another mission!`, "bad")
			return nil
		end
		warn(`[MissionService] no free IncidentSite for {missionId}: falling back to a mission instance`)
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
		-- city-only calls (nightclub, skyscraper) have no standalone builder to fall back on
		notify(players, `Every {def.call or def.title} crew is out right now. Try another call!`, "bad")
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
		mode = "instance",
		siteId = nil,
		folder = nil,
		mirror = nil,
		label = def.title or GameConfig.LocationName,
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

	resetBlame(players)

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

-- v2: every IncidentSite nobody is working right now (DispatchService builds radio calls from these).
function MissionService:FreeSites(): { { siteId: string, types: string, pos: Vector3, address: string } }
	local out = {}
	local seen: { [string]: boolean } = {}
	for _, site in allSites() do
		local sid = siteIdOf(site)
		if seen[sid] or site:GetAttribute(SITE.Busy) == true or claimed[sid] ~= nil then
			continue
		end
		seen[sid] = true
		local types = site:GetAttribute(SITE.MissionTypes)
		local addr = site:GetAttribute(SITE.Address)
		table.insert(out, {
			siteId = sid,
			types = if type(types) == "string" then types else "",
			pos = sitePos(site),
			address = if type(addr) == "string" and addr ~= "" then addr else friendlyAddress(sid),
		})
	end
	return out
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
		state = if state == "Done" then "Results" else legacyState(state),
		endsAt = if run.flow.endsAt > 0 then run.flow.endsAt else run.flow.alarmEndsAt + run.flow.timing.seconds,
		-- v2 extras
		siteId = run.siteId,
		roundState = state, -- raw: "Dispatched" while driving
		mode = run.mode,
		rookie = run.rookie == true, -- GameConfig.Rookie (TwistService: no twist on a rookie call)
	} :: any
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

-- NEXT CALL! on the results screen (DispatchService Dispatch/Next): step out of a finished dispatch run
-- now instead of waiting out its results timer. Only while that run shows Results; the run itself still
-- ends for everyone else on its own timer. true = the player is free of any run.
function MissionService:LeaveResults(player: Player): boolean
	local run = runOf(player)
	if run == nil then
		return true
	end
	if run.mode ~= "dispatch" or run.flow.state ~= "Results" then
		return false
	end
	local i = table.find(run.players, player)
	if i then
		table.remove(run.players, i)
	end
	player:SetAttribute(Names.Attr.InstanceId, "")
	safe("LeaveResults cleanup", function()
		local Inv = services.InventoryService
		if Inv and type(Inv.StowHose) == "function" then
			Inv:StowHose(player)
		end
		local Nav = services.NavigationService
		if Nav and type(Nav.ClearWaypoint) == "function" then
			Nav:ClearWaypoint({ player })
		end
	end)
	count("results_left_early")
	return true
end

-- LATE JOIN (LobbyService: stepped on the pad right after its squad rolled out). Only a dispatch run that is
-- still driving (Dispatched), only a player in no run, never past the mission's max players. The caller seats
-- them in the squad's truck. true = they are in the run now.
function MissionService:JoinRun(player: Player, instanceId: string): boolean
	local run = runs[instanceId]
	if not run or run.mode ~= "dispatch" or run.flow.state ~= "Dispatched" then
		return false
	end
	if typeof(player) ~= "Instance" or player.Parent ~= Players or runOf(player) ~= nil or table.find(run.players, player) then
		return false
	end
	local maxP = run.def and run.def.players and tonumber(run.def.players.max) or 8
	if #run.players >= maxP then
		return false
	end
	table.insert(run.players, player)
	resetBlame({ player })
	player:SetAttribute(Names.Attr.InstanceId, run.id)
	safe("JoinRun waypoint", function()
		local Nav = services.NavigationService
		if Nav and type(Nav.SetWaypoint) == "function" then
			local target: any = arrivalTarget(run.model) or sitePos(run.model)
			Nav:SetWaypoint({ player }, target, run.label)
		end
	end)
	notify({ player }, `DISPATCH: {run.label}`, "bad")
	count("missions_late_joins")
	return true
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

-- Fire the run's next escalation phase now. Returns phases fired / total.
function MissionService:_escalate(instanceId: string): (number, number)
	local run = runs[instanceId]
	if not run then
		return 0, 0
	end
	local phases = escalationPhases(run)
	local fired = run.escFired or 0
	if fired < #phases then
		run.escFired = fired + 1
		run.escLastAt = now() - (if run.flow.arrivedAt > 0 then run.flow.arrivedAt else run.flow.activeSince)
		escalate(run, phases[fired + 1], fired + 1)
	end
	return run.escFired or 0, #phases
end

-- Debug view of a run: state, seconds left, burning, rescues, escalation progress.
function MissionService:_runInfo(instanceId: string): { [string]: any }?
	local run = runs[instanceId]
	if not run then
		return nil
	end
	local rescued, trapped, lost = rescueCounts(run)
	return {
		state = run.flow.state,
		left = math.floor(run.flow.endsAt - now()),
		burning = burningCount(run),
		firesLit = run.firesLit,
		firesOut = run.firesOut,
		rescued = rescued,
		trapped = trapped,
		lost = lost,
		escFired = run.escFired or 0,
		escTotal = #escalationPhases(run),
		siteId = run.siteId,
		stars = if run.payload then run.payload.stars else nil,
		outcome = run.flow.outcome,
	}
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
	local d = MissionFlow.newDispatch({ seconds = 10, travel = 5, fastArrival = 3, arrivalBonus = 2, alarm = 0, intro = 0, results = 1, grace = 0 }, 0)
	local obs = { burning = 1, rescued = 0, trapped = 0, players = 1, alive = 1, arrived = true }
	evs = table.concat(MissionFlow.tick(d, 1, obs), ",")
	if evs ~= "arrived" or d.endsAt ~= 17 then
		return false, `MissionFlow dispatch gave {evs} (endsAt {d.endsAt})`
	end
	local live, sites = 0, 0
	for _, run in runs do
		live += 1
		if not run.model then
			return false, `{run.id} has no model`
		end
		if run.mode == "dispatch" then
			if not (run.folder and run.folder.Parent and run.mirror and run.mirror.Parent) then
				return false, `{run.id} lost its Runs/Instances folder`
			end
			if run.siteId and claimed[run.siteId] ~= run.id then
				return false, `{run.id} does not hold its site {run.siteId}`
			end
		end
	end
	for _ in allSites() do
		sites += 1
	end
	local mode = if GameConfig.UseInstances == true then "instances" else "dispatch"
	return true, `{mode}: state {self:GetState()}, {live} running, {sites} incident sites`
end

return MissionService
