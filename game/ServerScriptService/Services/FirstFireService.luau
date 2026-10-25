--!strict
-- FirstFireService [owner: Onboarding]. Onboarding v3: a brand-new player's first 90 seconds are about ONE
-- thing, saving a panda from a burning house (copy + tuning: Config/FirstFireConfig; pure rules:
-- Lib/Onboarding/FirstFire + ColdOpen, spec-tested; the set: Lib/Onboarding/PandaHouse):
--   1. Player attr Onboarded == false (OnboardingService, from the profile) and in the lobby: the panda house
--      (Workspace.TrainingFires.Spot<n>) is built across the road, its four fuel items lit (each its own
--      FireService location "training:<n>:<k>", fuel that never runs out), a panda (RescueService, scope
--      "training:<n>") sits at the front window with its Pick up prompt OFF, and a prop fire truck is parked
--      by it. The newbie stands on the pavement facing the house. Player attrs: FirstFire "burning",
--      ColdOpen true, ColdOpenAt, FirstFireSpot, FirstFirePanda.
--   2. The client plays the cold open (Controllers/ColdOpenController) and reports Onboarding/Seen
--      "coldopen_end" (watched or skipped); then the extinguisher goes in your hand (or after
--      ColdOpen.MaxWait s, whatever happens). One mechanic at a time: SPRAY THE FIRE.
--   3. The first spray that hits ANY burning part (FireService.Doused) sets SecondsToFirstSpray.
--   4. Fire out: "FIRE OUT!" popup, FirstFire "panda", the panda's prompt turns on: NOW SAVE THE PANDA.
--   5. The panda is rescued (RescueService.Rescued: carried OUTSIDE, its normal rule): FirstFire "done",
--      FirstFireDoneAt, +XpReward XP, the celebration; AutoQueueDelay s later LobbyService:QuickJoin onto a
--      pad with FirstFireConfig.FirstCall (FirstFire "queued"). Joining a call any other way first ends it
--      quietly (FirstFire "skipped").
--   * Player attr FirstCallDone: true for returning players (Onboarded true when we first see it), false
--     for newbies until their first call ends (MissionService.MissionEnded). HudRevealController, the
--     like-ask, the update log and pass offers wait for it.
-- Returning players (Onboarded true) never see any of this.
-- Handshake: nothing lights until the client said it's ready (OnboardingService Onboarding/Ready, Player attr
-- ClientReady; at most ClientReadyTimeout s), so the cold open is on screen when the fire is.
-- Never stuck: endless foam while it burns, the panda can't be picked up (or hurt: it sits 8+ studs from every
-- fuel item) until the fire is out, a toasted / lost panda is put back, SKIP TUTORIAL ends it.
-- Player control: SKIP TUTORIAL (OnboardingService.Skipped) puts the set away; NOT YET on the first call
-- (OnboardingService.CallDeclined) steps you off the pad (FirstFire "open": the board -> pad tutorial).
--
-- Public API: none (it reacts to OnboardingService, FireService, RescueService, LobbyService, MissionService).
-- Writes: Player attrs FirstFire, FirstFireSpot, FirstFirePanda, FirstFireDoneAt, SecondsToFirstSpray,
--   ColdOpen, ColdOpenAt, FirstCallDone; Workspace.TrainingFires
-- Counters: first_fire_started, first_fire_spray, first_fire_out, first_fire_out_seconds (sum),
--   first_panda_saved, first_panda_saved_seconds (sum), first_panda_respawned, cold_open_started,
--   cold_open_ended, cold_open_timeout, first_fire_skipped, first_call_queued, first_call_queue_failed,
--   first_call_launched, first_call_done, first_spray (everyone), first_spray_seconds (sum), first_spray_new,
--   first_spray_new_seconds (sum), first_spray_new_le30s, first_spray_new_gt30s, first_spray_returning,
--   first_fire_no_handshake, first_fire_no_spot, first_call_declined_left
-- Test hooks (DevHook only): _run(player), _state(player) -> JSON, _selftest(), _douse(player) (puts the
--   house fire out as if they sprayed it), _savePanda(player) (carries the panda outside for them)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigDir:WaitForChild("FirstFireConfig") :: ModuleScript) :: any
local OnboardingConfig = require(ConfigDir:WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local FirstFire = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("FirstFire") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local PandaHouse = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("PandaHouse") :: ModuleScript)
local NpcBuilder = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Rescue"):WaitForChild("RescueNpcBuilder") :: ModuleScript) :: any

local FirstFireService = {}
FirstFireService.Priority = 60 -- after OnboardingService (25), FireService (50), RescueService (50)

type Spot = {
	index: number,
	model: Model?,
	locationId: string,
	fuels: number,
	players: { [Player]: boolean },
	lit: number,
	panda: string?, -- RescueId
	out: boolean, -- the house fire is out
	saved: boolean, -- the panda is out
	blocked: boolean?, -- this map has something where the house would go
}

local services: { [string]: any } = {}
local joinedAt: { [Player]: number } = {}
local sprayed: { [Player]: boolean } = {}
local requeues: { [Player]: number } = {} -- safety-net re-queues of the first call (FirstFireConfig.QueueRetries)
local spotOf: { [Player]: Spot } = {}
local spots: { [number]: Spot } = {}
local coldOpenDone: { [Player]: boolean } = {}
local lastRun: { [Player]: string } = {}
local folder: Folder? = nil

local ColdCfg = Cfg.ColdOpen or {}
local COLD_ATTR: string = ColdCfg.Attr or "ColdOpen"
local CALL_DONE_ATTR: string = Cfg.FirstCallDoneAttr or "FirstCallDone"

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function call(service: string, method: string, ...: any): (boolean, any)
	local s = services[service]
	if not s or type(s[method]) ~= "function" then
		return false, nil
	end
	return pcall(s[method], s, ...)
end

local function inMission(player: Player): boolean
	local id = player:GetAttribute(Names.Attr.InstanceId)
	return type(id) == "string" and id ~= ""
end

local function setPhase(player: Player, phase: string?)
	player:SetAttribute(Cfg.PhaseAttr, phase)
end

local function spotDef(index: number): any
	return (Cfg.Spots :: { any })[index]
end

------------------------------------------------------------------------------------------ the set

local function setFolder(): Folder
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "TrainingFires"
		f.Parent = workspace
		folder = f
	end
	return folder :: Folder
end

local function ignore(): { Instance }
	local list: { Instance } = { setFolder() }
	local r = workspace:FindFirstChild("Rescuables")
	if r then
		table.insert(list, r)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

-- ground height under a point (the map's own ground, not our set or a player)
local function groundY(at: Vector3): number
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore()
	local hit = workspace:Raycast(Vector3.new(at.X, at.Y + 60, at.Z), Vector3.new(0, -140, 0), rp)
	return if hit then hit.Position.Y else at.Y
end

-- something of the map stands where the house would go (another map variant, a new prop): skip the spot
local function isBlocked(cf: CFrame): boolean
	local size: Vector3 = Cfg.SpotClearSize or Vector3.new(30, 12, 22)
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	op.FilterDescendantsInstances = ignore()
	local centre = cf * CFrame.new(0, size.Y / 2 + 1.2, 8)
	for _, p in workspace:GetPartBoundsInBox(centre, size, op) do
		if p.Transparency < 1 and p.Size.Y < 40 and p.CanCollide then
			return true
		end
	end
	return false
end

local function burningAt(spot: Spot): number
	local Fire = services.FireService
	if not Fire then
		return 0
	end
	local n = 0
	for k = 1, spot.fuels do
		local ok, c = pcall(Fire.CountBurning, Fire, `{spot.locationId}:{k}`)
		n += if ok and type(c) == "number" then c else 0
	end
	return n
end

local function pandaModel(spot: Spot): Model?
	local id = spot.panda
	local r = workspace:FindFirstChild("Rescuables")
	local m = id and r and r:FindFirstChild(id)
	return if m and m:IsA("Model") then m else nil
end

local function pandaPrompt(spot: Spot): ProximityPrompt?
	local m = pandaModel(spot)
	local p = m and m:FindFirstChild("Carry", true)
	return if p and p:IsA("ProximityPrompt") then p else nil
end

local function setPandaPrompt(spot: Spot, on: boolean)
	local p = pandaPrompt(spot)
	if p then
		p.Enabled = on
	end
end

local function spawnPanda(spot: Spot)
	local model = spot.model
	local marker = model and model:FindFirstChild("PandaSpot")
	if not marker or not marker:IsA("BasePart") then
		return
	end
	local ok, id = call("RescueService", "SpawnAt", spot.locationId, marker, "Panda")
	if ok and type(id) == "string" then
		spot.panda = id
		for p in spot.players do
			p:SetAttribute(Cfg.PandaAttr, id)
		end
		setPandaPrompt(spot, spot.out) -- one mechanic at a time: the fire first
		local m = pandaModel(spot)
		if m then
			m:SetAttribute("FirstFirePanda", true)
			pcall(NpcBuilder.shout, m, if spot.out then "Over here! Get me out!" else (ColdCfg.Help or "HELP! HELP!"))
		end
	end
end

local function lightSpot(index: number): Spot?
	local def = spotDef(index)
	if not def then
		return nil
	end
	local s = spots[index]
	if not s then
		s = { index = index, model = nil, locationId = `training:{index}`, fuels = 0, players = {}, lit = 0, panda = nil, out = false, saved = false, blocked = nil }
		spots[index] = s
	end
	local spot = s :: Spot
	if spot.model and spot.model.Parent and burningAt(spot) > 0 and not spot.saved then
		return spot -- already burning: share it
	end
	if spot.model then
		spot.model:Destroy()
		spot.model = nil
	end
	call("RescueService", "ClearInstance", spot.locationId)
	local house: Vector3 = def.house
	local hy = groundY(house)
	local cf = CFrame.new(house.X, hy, house.Z)
	if spot.blocked == nil then
		spot.blocked = isBlocked(cf)
		if spot.blocked then
			warn(`[FirstFireService] panda house spot {index} is blocked on this map; skipping it`)
			return nil
		end
	end
	local truckCf: CFrame? = nil
	if def.truck then
		local t: Vector3 = def.truck
		truckCf = CFrame.new(t.X, groundY(t), t.Z) * CFrame.Angles(0, math.rad(def.truckYaw or 0), 0)
	end
	local model = PandaHouse.build(index, cf, truckCf)
	model:SetAttribute("TruckFrom", def.truckFrom)
	model.Parent = setFolder()
	spot.model = model
	spot.fuels = 0
	spot.out = false
	spot.saved = false
	spot.panda = nil
	for _, holder in model:GetChildren() do
		if holder:IsA("Model") and string.sub(holder.Name, 1, 5) == "Fuel_" then
			spot.fuels += 1
			call("FireService", "IndexLocation", holder, `{spot.locationId}:{spot.fuels}`)
			for _, d in holder:GetChildren() do
				if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Flammable) then
					call("FireService", "Ignite", d, nil)
				end
			end
		end
	end
	spot.lit = os.clock()
	spawnPanda(spot)
	return spot
end

local function clearSpot(spot: Spot, delay: number)
	local model = spot.model
	if not model then
		return
	end
	task.delay(delay, function()
		if spot.model == model and next(spot.players) == nil then
			spot.model = nil
			for k = 1, spot.fuels do
				call("FireService", "ClearInstance", `{spot.locationId}:{k}`)
			end
			call("RescueService", "ClearInstance", spot.locationId)
			spot.panda = nil
			model:Destroy()
		end
	end)
end

local function pickSpot(): Spot?
	local infos = {}
	for i = 1, #(Cfg.Spots :: { any }) do
		local s = spots[i]
		table.insert(infos, {
			burning = s ~= nil and s.model ~= nil and s.model.Parent ~= nil and not s.out and not s.saved,
			busy = s ~= nil and (next(s.players) ~= nil or (s.model ~= nil and s.model.Parent ~= nil)),
			blocked = s ~= nil and s.blocked == true,
		})
	end
	local i = FirstFire.pickSpot(infos)
	while i do
		local spot = lightSpot(i)
		if spot then
			return spot
		end
		infos[i].blocked = true -- found blocked while building it: next
		i = FirstFire.pickSpot(infos)
	end
	return nil
end

------------------------------------------------------------------------------------------ flow

local function leaveSpot(player: Player)
	local spot = spotOf[player]
	spotOf[player] = nil
	if spot then
		spot.players[player] = nil
		if next(spot.players) == nil then
			clearSpot(spot, Cfg.ClearDelay)
		end
	end
end

local function skip(player: Player)
	local phase = player:GetAttribute(Cfg.PhaseAttr)
	if phase == "burning" or phase == "panda" or phase == "done" then
		setPhase(player, "skipped")
		count("first_fire_skipped")
	end
	player:SetAttribute(COLD_ATTR, false)
	leaveSpot(player)
end

local function autoQueue(player: Player)
	if Cfg.AutoQueue == false or player.Parent ~= Players or inMission(player) then
		return
	end
	if player:GetAttribute(Cfg.PhaseAttr) ~= "done" then
		return -- skipped the tutorial (or anything else) during the celebration
	end
	if (player:GetAttribute(Names.Attr.SquadId) or "") ~= "" then
		setPhase(player, "queued") -- already on a pad by themselves
		return
	end
	local ok, sid = call("LobbyService", "QuickJoin", player, Cfg.FirstCall, Cfg.QueueCountdown)
	if ok and type(sid) == "string" then
		setPhase(player, "queued")
		count("first_call_queued")
	else
		setPhase(player, "open") -- no pad free: the regular tutorial (board -> pad) takes over
		count("first_call_queue_failed")
	end
end

-- the house fire is out: one mechanic at a time, now the panda
local function fireOut(spot: Spot)
	if spot.out then
		return
	end
	spot.out = true
	local now = os.clock()
	setPandaPrompt(spot, true)
	for player in spot.players do
		if player.Parent ~= Players or player:GetAttribute(Cfg.PhaseAttr) ~= "burning" then
			continue
		end
		setPhase(player, "panda")
		count("first_fire_out")
		count("first_fire_out_seconds", math.floor(now - (joinedAt[player] or now) + 0.5))
		pcall(Popup.show, player, Cfg.FireOutPop or "FIRE OUT!", "good")
	end
	local m = pandaModel(spot)
	if m then
		pcall(NpcBuilder.shout, m, "Over here! Get me out!")
	end
end

-- the panda is out of the house: celebrate, then the first real call
local function pandaSaved(spot: Spot)
	if spot.saved then
		return
	end
	spot.saved = true
	local now = os.clock()
	for player in spot.players do
		local phase = player:GetAttribute(Cfg.PhaseAttr)
		if player.Parent ~= Players or (phase ~= "panda" and phase ~= "burning") then
			continue
		end
		spotOf[player] = nil
		setPhase(player, "done")
		player:SetAttribute(Cfg.DoneAtAttr, workspace:GetServerTimeNow())
		count("first_panda_saved")
		count("first_panda_saved_seconds", math.floor(now - (joinedAt[player] or now) + 0.5))
		local xp = Cfg.XpReward or 0
		if xp > 0 then
			call("DataService", "AddXp", player, xp, "Saved the panda!")
		end
		task.delay(Cfg.AutoQueueDelay or 3.5, autoQueue, player)
	end
	table.clear(spot.players)
	clearSpot(spot, Cfg.ClearDelay)
end

local function standAt(player: Player, spot: Spot)
	local def = spotDef(spot.index)
	local char = player.Character
	if not def or not char then
		return
	end
	local stand: Vector3 = def.stand
	local y = groundY(stand) + 3
	local house: Vector3 = def.house
	local at = Vector3.new(stand.X, y, stand.Z)
	char:PivotTo(CFrame.lookAt(at, Vector3.new(house.X, y, house.Z + 6)))
end

local function giveExtinguisher(player: Player)
	local okHand, hand = call("InventoryService", "GetHand", player)
	if not okHand or hand == nil or hand == "" then
		call("InventoryService", "Give", player, Cfg.GiveItem or "Extinguisher")
	end
end

-- the cutscene is over (or never ran): the extinguisher goes in your hand
local function waitColdOpen(player: Player, spot: Spot)
	if ColdCfg.Enabled == false or player:GetAttribute(COLD_ATTR) ~= true then
		return
	end
	local t0 = os.clock()
	local maxWait = ColdCfg.MaxWait or 14
	while player.Parent == Players and not coldOpenDone[player] and os.clock() - t0 < maxWait and spotOf[player] == spot do
		task.wait(0.1)
	end
	if not coldOpenDone[player] then
		count("cold_open_timeout")
	end
end

local function run(player: Player)
	if player.Parent ~= Players or spotOf[player] then
		return
	end
	local onboarded = player:GetAttribute(OnboardingConfig.DoneAttr or "Onboarded")
	if not FirstFire.shouldRun(onboarded, inMission(player), Cfg.Enabled ~= false) then
		return
	end
	-- wait for the client's handshake so the cold open is on screen when the fire is
	local Onboarding = services.OnboardingService
	if Onboarding and type(Onboarding.WaitForClient) == "function" then
		local okWait, ready = pcall(Onboarding.WaitForClient, Onboarding, player, Cfg.ClientReadyTimeout or 45)
		if not (okWait and ready) then
			count("first_fire_no_handshake")
		end
		onboarded = player:GetAttribute(OnboardingConfig.DoneAttr or "Onboarded")
		if player.Parent ~= Players or spotOf[player] or not FirstFire.shouldRun(onboarded, inMission(player), Cfg.Enabled ~= false) then
			return
		end
	end
	local spot = pickSpot()
	if not spot then
		count("first_fire_no_spot")
		setPhase(player, "open") -- every spot taken: the regular board -> pad tutorial
		return
	end
	spot.players[player] = true
	spotOf[player] = spot
	player:SetAttribute(Cfg.SpotAttr, spot.index)
	player:SetAttribute(Cfg.PandaAttr, spot.panda or "")
	coldOpenDone[player] = nil
	player:SetAttribute(COLD_ATTR, ColdCfg.Enabled ~= false)
	player:SetAttribute(Cfg.ColdOpenAtAttr, workspace:GetServerTimeNow())
	setPhase(player, "burning")
	count("first_fire_started")
	count("cold_open_started")
	-- wait for the character (and LobbyService's own spawn pivot), then out to the pavement
	local char = player.Character or player.CharacterAdded:Wait()
	task.wait(Cfg.StandDelay or 0.6)
	if player.Parent ~= Players or player.Character ~= char or spotOf[player] ~= spot then
		return
	end
	standAt(player, spot)
	waitColdOpen(player, spot)
	if player.Parent ~= Players or spotOf[player] ~= spot or player:GetAttribute(Cfg.PhaseAttr) ~= "burning" then
		return
	end
	standAt(player, spot) -- (a kid mashing keys in the cutscene may have walked off)
	giveExtinguisher(player)
	-- foam never runs dry on the house fire: a newbie who sprays the grass for 5 s (one can) must not be
	-- left clicking an empty extinguisher with the fire still burning
	local foamConn: RBXScriptConnection? = nil
	foamConn = player:GetAttributeChangedSignal("Foam"):Connect(function()
		if spotOf[player] ~= spot or player:GetAttribute(Cfg.PhaseAttr) ~= "burning" then
			if foamConn then
				foamConn:Disconnect()
			end
			return
		end
		local size = tonumber(player:GetAttribute("FoamSize")) or 20
		local foam = tonumber(player:GetAttribute("Foam")) or size
		if foam < size * 0.5 then
			task.defer(function()
				if spotOf[player] == spot then
					player:SetAttribute("Foam", size)
				end
			end)
		end
	end)
	-- respawned (or downed and bled out) before the panda is out: back to the pavement with an extinguisher
	local conn: RBXScriptConnection? = nil
	conn = player.CharacterAdded:Connect(function(c: Model)
		task.wait(Cfg.StandDelay or 0.6)
		local phase = player:GetAttribute(Cfg.PhaseAttr)
		if spotOf[player] ~= spot or (phase ~= "burning" and phase ~= "panda") then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if player.Character == c then
			standAt(player, spot)
			if phase == "burning" then
				giveExtinguisher(player)
			end
		end
	end)
end

local function onDoused(player: Player, _hits: number)
	if sprayed[player] then
		return
	end
	sprayed[player] = true
	local secs = os.clock() - (joinedAt[player] or os.clock())
	player:SetAttribute(Cfg.FirstSprayAttr, math.floor(secs * 10 + 0.5) / 10)
	local whole = math.floor(secs + 0.5)
	count("first_spray")
	count("first_spray_seconds", whole)
	if player:GetAttribute(OnboardingConfig.DoneAttr or "Onboarded") == true then
		count("first_spray_returning")
	else
		count("first_spray_new")
		count("first_spray_new_seconds", whole)
		count(if secs <= 30 then "first_spray_new_le30s" else "first_spray_new_gt30s")
	end
	if spotOf[player] then
		count("first_fire_spray")
	end
	print(`[FirstFireService] {player.Name} first spray on a fire after {string.format("%.1f", secs)} s`)
end

local function resolveCallDone(player: Player)
	if player:GetAttribute(CALL_DONE_ATTR) ~= nil then
		return
	end
	local onboarded = player:GetAttribute(OnboardingConfig.DoneAttr or "Onboarded")
	if onboarded ~= nil then
		player:SetAttribute(CALL_DONE_ATTR, onboarded == true)
	end
end

local function onPlayer(player: Player)
	joinedAt[player] = joinedAt[player] or os.clock()
	local attr = OnboardingConfig.DoneAttr or "Onboarded"
	resolveCallDone(player)
	if player:GetAttribute(attr) ~= nil then
		task.spawn(run, player)
	else
		local conn: RBXScriptConnection? = nil
		conn = player:GetAttributeChangedSignal(attr):Connect(function()
			if player:GetAttribute(attr) ~= nil then
				if conn then
					conn:Disconnect()
				end
				resolveCallDone(player)
				task.spawn(run, player)
			end
		end)
	end
	-- safety net: the auto-queued first call's squad dissolved (a failed dispatch, anything) while you're
	-- still "queued" in the lobby: queue you again (QueueRetries times), else the board -> pad tutorial
	-- card ("STEP ON A GLOWING PAD"), so a newbie is never left standing with nothing to do
	player:GetAttributeChangedSignal(Names.Attr.SquadId):Connect(function()
		if (player:GetAttribute(Names.Attr.SquadId) or "") ~= "" or player:GetAttribute(Cfg.PhaseAttr) ~= "queued" then
			return
		end
		task.delay(2, function() -- (a launch clears SquadId for a moment before InstanceId lands)
			if player.Parent ~= Players or inMission(player) or player:GetAttribute(Cfg.PhaseAttr) ~= "queued" then
				return
			end
			if (player:GetAttribute(Names.Attr.SquadId) or "") ~= "" then
				return
			end
			requeues[player] = (requeues[player] or 0) + 1
			local ok, sid = false, nil
			if requeues[player] <= (Cfg.QueueRetries or 2) then
				ok, sid = call("LobbyService", "QuickJoin", player, Cfg.FirstCall, Cfg.QueueCountdown)
			end
			if ok and type(sid) == "string" then
				count("first_call_requeued")
			else
				setPhase(player, "open")
				count("first_call_requeue_failed")
			end
		end)
	end)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		if inMission(player) then
			lastRun[player] = player:GetAttribute(Names.Attr.InstanceId) :: string
			skip(player)
			if player:GetAttribute(Cfg.PhaseAttr) == "queued" then
				count("first_call_launched")
				setPhase(player, "launched")
			end
		end
	end)
end

------------------------------------------------------------------------------------------ lifecycle

function FirstFireService:Init(all: { [string]: any })
	services = all
end

local function declineCall(player: Player)
	if player:GetAttribute(Cfg.PhaseAttr) ~= "queued" or inMission(player) then
		return
	end
	if player:GetAttribute("PadLocked") == true then
		return -- LOCKED IN (last 5 s, LobbyService): too late to back out, you're rolling
	end
	setPhase(player, "open") -- the regular tutorial (board -> pad) takes it from here, at their pace
	local okLeave = call("LobbyService", "Leave", player)
	if okLeave then
		count("first_call_declined_left")
	end
	-- LobbyService:Leave only steps you a few studs off the pad, and the pad poll puts anyone standing on
	-- it straight back in the squad: walk them back to the pavement by the (cleared) panda house instead
	local def = spotDef(tonumber(player:GetAttribute(Cfg.SpotAttr)) or 1)
	local char = player.Character
	if def and char then
		local stand: Vector3 = def.stand
		local y = groundY(stand) + 3
		char:PivotTo(CFrame.lookAt(Vector3.new(stand.X, y, stand.Z), Vector3.new(def.house.X, y, def.house.Z)))
	end
end

function FirstFireService:Start()
	local Onboarding = services.OnboardingService
	if Onboarding and Onboarding.Skipped then
		Onboarding.Skipped:Connect(function(player: Player)
			skip(player)
			if player:GetAttribute(Cfg.PhaseAttr) == "queued" then
				declineCall(player)
			end
		end)
	end
	if Onboarding and Onboarding.CallDeclined then
		Onboarding.CallDeclined:Connect(declineCall)
	end
	if Onboarding and Onboarding.Seen then
		Onboarding.Seen:Connect(function(player: Player, step: string)
			if step == "coldopen_end" and not coldOpenDone[player] then
				coldOpenDone[player] = true
				count("cold_open_ended")
			end
		end)
	end
	local Fire = services.FireService
	if Fire and Fire.Doused then
		Fire.Doused:Connect(onDoused)
	end
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(p: BasePart, _by: Player?)
			for _, spot in spots do
				if spot.model and p:IsDescendantOf(spot.model) then
					if burningAt(spot) == 0 and next(spot.players) ~= nil then
						fireOut(spot)
					end
					return
				end
			end
		end)
	end
	local Rescue = services.RescueService
	if Rescue and Rescue.Rescued then
		Rescue.Rescued:Connect(function(_who: Player, rescueId: string, _kind: string)
			for _, spot in spots do
				if spot.panda == rescueId and spot.model then
					pandaSaved(spot)
					return
				end
			end
		end)
	end
	if Rescue and Rescue.Toasted then
		-- (it sits 8+ studs from every fuel item, but a yeet back into the fire is possible): put it back
		Rescue.Toasted:Connect(function(rescueId: string)
			for _, spot in spots do
				if spot.panda == rescueId and spot.model and not spot.saved then
					task.delay(2, function()
						if spot.model and not spot.saved and spot.panda == rescueId then
							local m = pandaModel(spot)
							if m then
								m:Destroy()
							end
							spawnPanda(spot)
							count("first_panda_respawned")
						end
					end)
					return
				end
			end
		end)
	end
	local Mission = services.MissionService
	if Mission and Mission.MissionEnded then
		-- the first call is over (any ending): the rest of the HUD, offers and asks may show now
		Mission.MissionEnded:Connect(function(id: string, _payload: any)
			for _, p in Players:GetPlayers() do
				if p:GetAttribute(CALL_DONE_ATTR) == false and (lastRun[p] == id or p:GetAttribute(Names.Attr.InstanceId) == id) then
					p:SetAttribute(CALL_DONE_ATTR, true)
					count("first_call_done")
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(p: Player)
		requeues[p] = nil
		leaveSpot(p)
		joinedAt[p] = nil
		sprayed[p] = nil
		coldOpenDone[p] = nil
		lastRun[p] = nil
	end)
end

------------------------------------------------------------------------------------------ test hooks

-- Re-run the cold open for a player as if they just joined (fresh clock, no first spray yet).
function FirstFireService:_run(player: Player)
	leaveSpot(player)
	joinedAt[player] = os.clock()
	sprayed[player] = nil
	coldOpenDone[player] = nil
	player:SetAttribute(Cfg.FirstSprayAttr, nil)
	player:SetAttribute(Cfg.PhaseAttr, nil)
	player:SetAttribute(CALL_DONE_ATTR, false)
	task.spawn(run, player)
end

function FirstFireService:_state(player: Player): string
	local spot = spotOf[player]
	return HttpService:JSONEncode({
		phase = player:GetAttribute(Cfg.PhaseAttr),
		spot = player:GetAttribute(Cfg.SpotAttr),
		burning = if spot then burningAt(spot) else 0,
		out = if spot then spot.out else nil,
		saved = if spot then spot.saved else nil,
		panda = if spot then spot.panda else nil,
		pandaPrompt = if spot and pandaPrompt(spot) then (pandaPrompt(spot) :: ProximityPrompt).Enabled else nil,
		coldOpen = player:GetAttribute(COLD_ATTR),
		coldOpenDone = coldOpenDone[player] == true,
		firstSpray = player:GetAttribute(Cfg.FirstSprayAttr),
		firstCallDone = player:GetAttribute(CALL_DONE_ATTR),
		since = os.clock() - (joinedAt[player] or os.clock()),
	})
end

-- put the house fire out for this player's spot, as if they sprayed it (credit: them). Yields (<= 6 s).
function FirstFireService:_douse(player: Player): number
	local spot = spotOf[player]
	local Fire = services.FireService
	if not spot or not spot.model or not Fire then
		return -1
	end
	for _ = 1, 60 do
		local any = false
		for _, d in (spot.model :: Model):GetDescendants() do
			if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Burning) then
				any = true
				local from = d.Position + Vector3.new(0, 0, -8)
				pcall(Fire.ApplyWater, Fire, player, from, (d.Position - from).Unit, 50)
			end
		end
		if not any or not spot.model then
			break
		end
		task.wait(0.1)
	end
	return burningAt(spot)
end

-- pick up this player's panda and walk it out to the lawn: RescueService's own "outside is safe" rule
-- rescues it (the real path, not a forced deliver). Yields (<= 3 s).
function FirstFireService:_savePanda(player: Player): boolean
	local spot = spotOf[player]
	if not spot or not spot.panda or not spot.model then
		return false
	end
	local okCarry, carried = call("RescueService", "_carry", player, spot.panda)
	if not okCarry or not carried then
		return false
	end
	local safe = (spot.model :: Model):FindFirstChild("SafeSpot")
	local char = player.Character
	if safe and safe:IsA("BasePart") and char then
		char:PivotTo(CFrame.new(safe.Position + Vector3.new(0, 3, 0)))
	end
	local t0 = os.clock()
	while not spot.saved and os.clock() - t0 < 3 do
		task.wait(0.1)
	end
	return spot.saved
end

function FirstFireService:_selftest(): (boolean, string)
	local spot = lightSpot(#(Cfg.Spots :: { any }))
	if not spot or not services.FireService then
		return false, "no spot / FireService"
	end
	local n = burningAt(spot)
	if n == 0 then
		return false, "the panda house did not light"
	end
	local panda = spot.panda ~= nil
	if next(spot.players) == nil then
		clearSpot(spot, 0)
	end
	return panda, `panda house lit {n} parts, panda {panda}`
end

return FirstFireService
