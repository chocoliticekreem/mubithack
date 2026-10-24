--!strict
-- FirstFireService [owner: Onboarding]. A brand-new player sprays a real fire within seconds of joining
-- (copy + tuning: Config/FirstFireConfig; pure rules: Lib/Onboarding/FirstFire, spec-tested):
--   1. Player attr Onboarded == false (OnboardingService, from the profile) and in the lobby: a training
--      fire (a dumpster of burning trash + crates, Workspace.TrainingFires.Spot<n>, its own FireService
--      location "training:<n>", fuel that never runs out) lights at the spot's fire position, and the
--      newbie stands at the station's front door facing it with an Extinguisher in hand (InventoryService).
--   2. Their first spray that hits ANY burning part (FireService.Doused) sets Player attr
--      SecondsToFirstSpray (seconds since they joined). Returning players get it too (their first call).
--   3. Fire out: reward pop (Popup + DataService:AddXp), Player attr FirstFire "done" + FirstFireDoneAt.
--   4. AutoQueueDelay s later: LobbyService:QuickJoin onto a pad with FirstFireConfig.FirstCall and the
--      countdown cut to QueueCountdown (FirstFire "queued"). The existing onboarding / dispatch hints
--      take it from there. Joining a call any other way first ends it quietly (FirstFire "skipped").
-- Returning players (Onboarded true) never see any of this.
-- Handshake: nothing lights until the client said it's ready (OnboardingService Onboarding/Ready, Player attr
-- ClientReady; at most ClientReadyTimeout s): on a slow phone load the whole tutorial used to run (fire, pop,
-- auto-queue, even the dispatch) before the client had a single handler connected.
-- The training fire never leaves you stuck: endless foam while it burns, and each fuel item is its own
-- FireService location (no spread), so whatever you've put out stays out.
-- Player control: SKIP TUTORIAL (OnboardingService.Skipped) puts the fire away; NOT YET on the first call
-- (OnboardingService.CallDeclined) steps you off the pad (FirstFire "open": the board -> pad tutorial).
--
-- Public API: none (it reacts to OnboardingService's attr, FireService, LobbyService).
-- Writes: Player attrs FirstFire, FirstFireSpot, FirstFireDoneAt, SecondsToFirstSpray; Workspace.TrainingFires
-- Counters: first_fire_started, first_fire_spray, first_fire_out, first_fire_out_seconds (sum),
--   first_fire_skipped, first_call_queued, first_call_queue_failed, first_call_launched, first_spray (everyone),
--   first_spray_seconds (sum), first_spray_new, first_spray_new_seconds (sum), first_spray_new_le30s,
--   first_spray_new_gt30s, first_spray_returning, first_fire_no_handshake, first_call_declined_left
-- Test hooks (DevHook only): _run(player), _state(player) -> JSON, _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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

local FirstFireService = {}
FirstFireService.Priority = 60 -- after OnboardingService (25), FireService (50)

type Spot = { index: number, model: Model?, locationId: string, fuels: number, players: { [Player]: boolean }, lit: number }

local services: { [string]: any } = {}
local joinedAt: { [Player]: number } = {}
local sprayed: { [Player]: boolean } = {}
local requeues: { [Player]: number } = {} -- safety-net re-queues of the first call (FirstFireConfig.QueueRetries)
local spotOf: { [Player]: Spot } = {}
local spots: { [number]: Spot } = {}
local runs = 0
local folder: Folder? = nil

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

------------------------------------------------------------------------------------------ the fire

local function part(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, flammable: boolean, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = not flammable
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	if flammable then
		-- each fuel item in its own sub-model = its own FireService location (indexed one by one in
		-- lightSpot): no neighbours, so a bag you've put out STAYS out instead of catching again from
		-- the crate next to it while you're still spraying (a kid's "it won't go out!")
		local holder = Instance.new("Model")
		holder.Name = `Fuel_{name}`
		holder.Parent = model
		model = holder
		CollectionService:AddTag(p, Names.Tag.Flammable)
		p:SetAttribute(Names.Attr.Fuel, Cfg.FireFuel)
		p:SetAttribute("NoHeat", true) -- HeatService: a newbie reading the card must not get cooked
	end
	p.Parent = model
	return p
end

local function buildProps(index: number, at: Vector3): Model
	local m = Instance.new("Model")
	m.Name = `Spot{index}`
	m:SetAttribute("TrainingFire", true)
	local base = CFrame.new(at)
	local green = Color3.fromRGB(46, 102, 62)
	local wood = Color3.fromRGB(160, 116, 70)
	local bag = Color3.fromRGB(28, 28, 32)
	local body = part(m, "Dumpster", Vector3.new(6, 3.6, 4), base * CFrame.new(0, 1.8, 0), green, Enum.Material.Metal, false)
	part(m, "Lid", Vector3.new(6.2, 0.3, 2), base * CFrame.new(0, 3.9, 2.4) * CFrame.Angles(math.rad(-70), 0, 0), green, Enum.Material.Metal, false)
	part(m, "TrashBag1", Vector3.new(2.6, 2.6, 2.6), base * CFrame.new(-1.3, 4.2, 0), bag, Enum.Material.SmoothPlastic, true, Enum.PartType.Ball)
	part(m, "TrashBag2", Vector3.new(2.3, 2.3, 2.3), base * CFrame.new(1.4, 4.1, 0.3), bag, Enum.Material.SmoothPlastic, true, Enum.PartType.Ball)
	part(m, "Crate1", Vector3.new(2.6, 2.6, 2.6), base * CFrame.new(4.8, 1.3, 0.6), wood, Enum.Material.WoodPlanks, true)
	part(m, "Crate2", Vector3.new(2, 2, 2), base * CFrame.new(4.6, 3.6, 0.5) * CFrame.Angles(0, math.rad(25), 0), wood, Enum.Material.WoodPlanks, true)
	part(m, "Pallet", Vector3.new(3, 0.5, 3), base * CFrame.new(-4.6, 0.25, 0.8), wood, Enum.Material.Wood, false)
	part(m, "TrashPile", Vector3.new(2.4, 1.6, 2.4), base * CFrame.new(-4.6, 1.3, 0.8), Color3.fromRGB(120, 104, 80), Enum.Material.Fabric, true)
	m.PrimaryPart = body
	return m
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

local function spotDef(index: number): any
	return (Cfg.Spots :: { any })[index]
end

local function lightSpot(index: number): Spot?
	local def = spotDef(index)
	if not def then
		return nil
	end
	local s = spots[index]
	if not s then
		s = { index = index, model = nil, locationId = `training:{index}`, fuels = 0, players = {}, lit = 0 }
		spots[index] = s
	end
	local spot = s :: Spot
	local Fire = services.FireService
	if spot.model and spot.model.Parent and Fire and burningAt(spot) > 0 then
		return spot -- already burning: share it
	end
	if spot.model then
		spot.model:Destroy()
	end
	if not folder or not folder.Parent then
		local f = Instance.new("Folder")
		f.Name = "TrainingFires"
		f.Parent = workspace
		folder = f
	end
	local model = buildProps(index, def.fire)
	model.Parent = folder
	spot.model = model
	spot.fuels = 0
	for _, holder in model:GetChildren() do
		if holder:IsA("Model") then
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
			model:Destroy()
		end
	end)
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
	if phase == "burning" or phase == "done" then
		setPhase(player, "skipped")
		count("first_fire_skipped")
	end
	leaveSpot(player)
end

local function autoQueue(player: Player)
	if Cfg.AutoQueue == false or player.Parent ~= Players or inMission(player) then
		return
	end
	if player:GetAttribute(Cfg.PhaseAttr) ~= "done" then
		return -- skipped the tutorial (or anything else) during the reward pop
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

local function finish(spot: Spot)
	local now = os.clock()
	for player in spot.players do
		if player.Parent ~= Players or player:GetAttribute(Cfg.PhaseAttr) ~= "burning" then
			continue
		end
		spotOf[player] = nil
		setPhase(player, "done")
		player:SetAttribute(Cfg.DoneAtAttr, workspace:GetServerTimeNow())
		count("first_fire_out")
		count("first_fire_out_seconds", math.floor(now - (joinedAt[player] or now) + 0.5))
		local xp = Cfg.XpReward or 0
		if xp > 0 then
			call("DataService", "AddXp", player, xp, "First fire out!")
		end
		pcall(Popup.show, player, `FIRE OUT! +{xp} XP`, "good")
		task.delay(Cfg.AutoQueueDelay or 3, autoQueue, player)
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
	local look = Vector3.new(def.fire.X, stand.Y, def.fire.Z)
	char:PivotTo(CFrame.lookAt(stand, look))
end

local function equip(player: Player, spot: Spot)
	standAt(player, spot)
	local okHand, hand = call("InventoryService", "GetHand", player)
	if not okHand or hand == nil or hand == "" then
		call("InventoryService", "Give", player, Cfg.GiveItem or "Extinguisher")
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
	-- wait for the client's handshake so the PUT OUT THE FIRE card is on screen when the fire is
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
	runs += 1
	local index = FirstFire.slotFor(runs, #(Cfg.Spots :: { any }))
	local spot = lightSpot(index)
	if not spot then
		return
	end
	spot.players[player] = true
	spotOf[player] = spot
	player:SetAttribute(Cfg.SpotAttr, index)
	setPhase(player, "burning")
	count("first_fire_started")
	-- wait for the character (and LobbyService's own spawn pivot), then the door + the extinguisher
	local char = player.Character or player.CharacterAdded:Wait()
	task.wait(Cfg.StandDelay or 0.6)
	if player.Parent ~= Players or player.Character ~= char or spotOf[player] ~= spot then
		return
	end
	equip(player, spot)
	-- foam never runs dry on the training fire: a newbie who sprays the grass for 5 s (one can) must not
	-- be left clicking an empty extinguisher with the fire still burning
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
	-- respawned (or downed and bled out) before it's out: back to the door with a fresh extinguisher
	local conn: RBXScriptConnection? = nil
	conn = player.CharacterAdded:Connect(function(c: Model)
		task.wait(Cfg.StandDelay or 0.6)
		if spotOf[player] ~= spot or player:GetAttribute(Cfg.PhaseAttr) ~= "burning" then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if player.Character == c then
			equip(player, spot)
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

local function onPlayer(player: Player)
	joinedAt[player] = joinedAt[player] or os.clock()
	local attr = OnboardingConfig.DoneAttr or "Onboarded"
	if player:GetAttribute(attr) ~= nil then
		task.spawn(run, player)
	else
		local conn: RBXScriptConnection? = nil
		conn = player:GetAttributeChangedSignal(attr):Connect(function()
			if player:GetAttribute(attr) ~= nil then
				if conn then
					conn:Disconnect()
				end
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
	-- it straight back in the squad: walk them back out to the lawn by the front door instead
	local def = spotDef(tonumber(player:GetAttribute(Cfg.SpotAttr)) or 1)
	local char = player.Character
	if def and char then
		local stand: Vector3 = def.stand
		char:PivotTo(CFrame.lookAt(stand, Vector3.new(def.fire.X, stand.Y, def.fire.Z)))
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
	local Fire = services.FireService
	if Fire and Fire.Doused then
		Fire.Doused:Connect(onDoused)
	end
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(p: BasePart, _by: Player?)
			for _, spot in spots do
				if spot.model and p:IsDescendantOf(spot.model) then
					if burningAt(spot) == 0 and next(spot.players) ~= nil then
						finish(spot)
					end
					return
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
	end)
end

------------------------------------------------------------------------------------------ test hooks

-- Re-run the first fire for a player as if they just joined (fresh clock, no first spray yet).
function FirstFireService:_run(player: Player)
	leaveSpot(player)
	joinedAt[player] = os.clock()
	sprayed[player] = nil
	player:SetAttribute(Cfg.FirstSprayAttr, nil)
	player:SetAttribute(Cfg.PhaseAttr, nil)
	task.spawn(run, player)
end

function FirstFireService:_state(player: Player): string
	local spot = spotOf[player]
	local Fire = services.FireService
	return HttpService:JSONEncode({
		phase = player:GetAttribute(Cfg.PhaseAttr),
		spot = player:GetAttribute(Cfg.SpotAttr),
		burning = if spot and Fire then burningAt(spot) else 0,
		firstSpray = player:GetAttribute(Cfg.FirstSprayAttr),
		since = os.clock() - (joinedAt[player] or os.clock()),
	})
end

function FirstFireService:_selftest(): (boolean, string)
	local spot = lightSpot(#(Cfg.Spots :: { any }))
	local Fire = services.FireService
	if not spot or not Fire then
		return false, "no spot / FireService"
	end
	local n = burningAt(spot)
	if n == 0 then
		return false, "training fire did not light"
	end
	if next(spot.players) == nil then
		clearSpot(spot, 0)
	end
	return true, `training fire lit {n} parts`
end

return FirstFireService
