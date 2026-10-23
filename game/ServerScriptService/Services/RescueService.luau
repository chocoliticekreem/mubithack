--!strict
-- RescueService [owner: G3]. Civilians and pets (docs/game/01 §6, §7.1): spawn at RescueSpawn markers,
-- "Pick up" ProximityPrompt, the NPC dangles (wobbly AlignPosition) in front of the carrier, carrying
-- slows you, G drops, hold-Q YEETs (arc, tumble, ragdoll on landing, KO on a hard landing), the panda
-- needs TWO players (both trigger its prompt) and is heavy, walking (or yeeting!) into the truck's
-- RescueDropoff delivers it (cheer + confetti). NPCs near fire panic and run in circles; fire drains
-- their Health and at 0 they are "Toasted" (sooty, lost).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 + v1.5):
--   RescueService:Spawn(locationOrInstanceId: string, count: number)   -- every RescueSpawn under it
--   RescueService:SpawnAt(instanceId: string, marker: BasePart, kind: string?): string?  -- one NPC; RescueId
--   RescueService:ClearInstance(instanceId: string)
--   RescueService:Clear()
--   RescueService:Deliver(player: Player): boolean       -- carrier reached a RescueDropoff volume
--   RescueService:Hurt(rescueId: string, amount: number, culprit: Player?): boolean  -- v2: collapse damage
-- Signals: Rescued(player, rescueId, kind)        -- once per NPC (objective count)
--          Dropped(player, rescueId)
--          Picked(player, rescueId, kind)         -- per carrier (two for the panda)
--          Delivered(player, rescueId, kind)      -- per carrier who brought it in (Blame credit)
--          Thrown(player, rescueId)               -- a YEET (Blame "Yeet")
--          Toasted(rescueId, kind, culprit: Player?)  -- culprit = recent thrower/dropper/carrier
-- Remotes: Rescue/Drop (C->S, none, 2/s), Rescue/Throw (C->S, aim: Vector3 unit, charge: number 0..1, 2/s),
--          Rescue/Fx (S->C all, kind: "delivered"|"landed"|"yeet"|"toasted"|"picked", pos: Vector3, data: table?)
-- Writes: workspace.Rescuables/<RescueId> Models (tag Rescuable; attrs RescueId, Kind, RescueState
--   ("Trapped"|"Carried"|"Downed"|"Rescued"|"Toasted"), CarriedBy, InstanceId, Health, Panicking,
--   Flying, Toasted); Player attr Carrying. Counters npcs_spawned, npcs_picked, rescued,
--   rescued_<kind>, rescued_pet, npcs_dropped, npcs_thrown, npcs_downed, npcs_toasted,
--   npcs_panicked, rescue_pair_lifts.
-- Consumes (nil-guarded): MapService:GetInstance/GetLocation, SquadService.Downed/:GetHelmet, tags
--   RescueDropoff, Burning (attr FireLevel), Shared/Ragdoll.isRagdolled.
-- Test hooks (DevHook only): _spawnAt(kind, pos): string, _carry(player, id), _deliver(player),
--   _drop(player), _throw(player, charge?), _toast(id), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local RescueConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RescueConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local RescueLib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Rescue")
local Builder = require(RescueLib:WaitForChild("RescueNpcBuilder") :: ModuleScript)
local Rules = require(RescueLib:WaitForChild("RescueRules") :: ModuleScript)

local RescueService = {}
RescueService.Priority = 50
RescueService.Rescued = Signal.new() :: Signal.Signal<Player, string, string>
RescueService.Dropped = Signal.new() :: Signal.Signal<Player, string>
RescueService.Picked = Signal.new() :: Signal.Signal<Player, string, string>
RescueService.Delivered = Signal.new() :: Signal.Signal<Player, string, string>
RescueService.Thrown = Signal.new() :: Signal.Signal<Player, string>
RescueService.Toasted = Signal.new() :: Signal.Signal<string, string, Player?>

type Npc = {
	id: string,
	kind: string,
	scope: string,
	model: Model,
	root: BasePart,
	prompt: ProximityPrompt,
	state: string,
	pose: string,
	health: number,
	home: CFrame, -- feet where it stands when idle
	carriers: { Player },
	align: AlignPosition?,
	orient: AlignOrientation?,
	pending: { [Player]: number },
	flying: boolean,
	releasedAt: number,
	peakSpeed: number,
	stillFor: number,
	settleAt: number?,
	landedInFire: boolean,
	panic: boolean,
	panicT: number,
	panicCentre: Vector3,
	calmFor: number,
	thrower: Player?,
	thrownAt: number?,
	dropper: Player?,
	droppedAt: number?,
	lastCarrier: Player?,
}

type Fire = { pos: Vector3, reach: number, level: number }

local services: { [string]: any } = {}
local npcs: { [string]: Npc } = {}
local nextId = 0
local deliveredCount = 0
local FxRemote: RemoteEvent? = nil

local PETS = { Dog = true, Cat = true, Panda = true }

-- helpers -------------------------------------------------------------------------------------

local function folder(): Folder
	local f = workspace:FindFirstChild("Rescuables")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Rescuables"
		f.Parent = workspace
	end
	return f :: Folder
end

local function fx(kind: string, pos: Vector3, data: { [string]: any }?)
	if FxRemote then
		FxRemote:FireAllClients(kind, pos, data or {})
	end
end

local function helmetTag(player: Player): string
	local n = 1
	local Squad = services.SquadService
	if Squad and type(Squad.GetHelmet) == "function" then
		local ok, h = pcall(Squad.GetHelmet, Squad, player)
		if ok and type(h) == "number" then
			n = h
		end
	end
	return string.format("%02d", n)
end

local function humanoid(player: Player): Humanoid?
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid")
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function carrying(player: Player): string
	local v = player:GetAttribute(Names.Attr.Carrying)
	return if type(v) == "string" then v else ""
end

local function restoreSpeed(player: Player)
	local hum = humanoid(player)
	if hum and player:GetAttribute(Names.Attr.Downed) ~= true then
		hum.WalkSpeed = RescueConfig.WalkSpeed
	end
end

local function setState(npc: Npc, state: string)
	npc.state = state
	npc.model:SetAttribute(Names.Attr.RescueState, state)
end

local function say(npc: Npc, mood: string)
	Builder.shout(npc.model, Rules.line(npc.kind, mood, math.random(1, 6)))
end

-- Players who share the NPC's mission instance (v1 single round: everyone).
local function squadOf(npc: Npc): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		local inst = p:GetAttribute(Names.Attr.InstanceId)
		if npc.scope == "" or inst == nil or inst == "" or inst == npc.scope then
			table.insert(out, p)
		end
	end
	return out
end

local function notifySquad(npc: Npc, text: string, kind: string)
	for _, p in squadOf(npc) do
		Net.notify(p, text, kind)
	end
end

local function rayParams(): RaycastParams
	local ignore: { Instance } = { folder() }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	rp.IgnoreWater = true
	return rp
end

-- Upright feet CFrame on the ground under `pos`, facing `look` (flattened).
local function groundFeet(pos: Vector3, look: Vector3): CFrame
	local hit = workspace:Raycast(pos + Vector3.new(0, 2, 0), Vector3.new(0, -60, 0), rayParams())
	local feet = if hit then hit.Position else pos - Vector3.new(0, 1.5, 0)
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(feet, feet + flat.Unit)
end

local function burningFires(): { Fire }
	local out: { Fire } = {}
	for _, p in CollectionService:GetTagged(Names.Tag.Burning) do
		if p:IsA("BasePart") and p:IsDescendantOf(workspace) then
			local lvl = p:GetAttribute(Names.Attr.FireLevel)
			table.insert(out, {
				pos = p.Position,
				reach = math.max(p.Size.X, p.Size.Y, p.Size.Z) / 2,
				level = if type(lvl) == "number" then lvl else 2,
			})
		end
	end
	return out
end

local function nearestFire(fires: { Fire }, pos: Vector3): (number, number)
	local best, level = math.huge, 0
	for _, f in fires do
		local d = math.max(0, (f.pos - pos).Magnitude - f.reach)
		if d < best then
			best, level = d, f.level
		end
	end
	return best, level
end

local function dropoffAt(pos: Vector3): BasePart?
	for _, d in CollectionService:GetTagged(Names.Tag.RescueDropoff) do
		if d:IsA("BasePart") and d:IsDescendantOf(workspace) then
			local p = d.CFrame:PointToObjectSpace(pos)
			local h = d.Size / 2
			if Rules.inBox(p.X, p.Y, p.Z, h.X, h.Y, h.Z, RescueConfig.DeliverPad) then
				return d
			end
		end
	end
	return nil
end

local function firstDropoff(): BasePart?
	for _, d in CollectionService:GetTagged(Names.Tag.RescueDropoff) do
		if d:IsA("BasePart") and d:IsDescendantOf(workspace) then
			return d
		end
	end
	return nil
end

local function holdAttachment(hrp: BasePart, kind: string): Attachment
	local found = hrp:FindFirstChild("RescueHold")
	local att: Attachment
	if found and found:IsA("Attachment") then
		att = found
	else
		att = Instance.new("Attachment")
		att.Name = "RescueHold"
		att.Parent = hrp
	end
	local fwd = if kind == "Panda" then RescueConfig.HoldForwardPanda else RescueConfig.HoldForward
	-- held facing the carrier so you get a face full of googly eyes
	att.CFrame = CFrame.new(0, RescueConfig.HoldUp, -fwd) * CFrame.Angles(0, math.pi, 0)
	return att
end

local function clearPhysics(npc: Npc)
	if npc.align then
		npc.align:Destroy()
		npc.align = nil
	end
	if npc.orient then
		npc.orient:Destroy()
		npc.orient = nil
	end
end

-- Stop carrying: clears the constraints and every carrier's Carrying/speed. Returns the carriers.
local function releaseCarry(npc: Npc): { Player }
	clearPhysics(npc)
	local was = npc.carriers
	npc.carriers = {}
	for _, p in was do
		if carrying(p) == npc.id then
			p:SetAttribute(Names.Attr.Carrying, "")
			restoreSpeed(p)
		end
	end
	npc.model:SetAttribute(Names.Attr.CarriedBy, 0)
	return was
end

-- Anchor the NPC upright at `feet` with a pose (rebuilds the body when the pose changes).
local function plant(npc: Npc, feet: CFrame, pose: string)
	npc.flying = false
	npc.settleAt = nil
	npc.model:SetAttribute("Flying", false)
	if pose ~= npc.pose then
		npc.root = Builder.rebuild(npc.model, npc.kind, feet, pose)
		npc.pose = pose
	else
		Builder.setFree(npc.model, false)
		npc.root.AssemblyLinearVelocity = Vector3.zero
		npc.root.AssemblyAngularVelocity = Vector3.zero
		npc.model:PivotTo(feet)
	end
	npc.home = feet
end

-- Let physics have it (drop / throw): unanchored, collidable, server-owned.
local function launch(npc: Npc, velocity: Vector3, spin: Vector3)
	Builder.setFree(npc.model, true)
	pcall(function()
		npc.root:SetNetworkOwner(nil)
	end)
	npc.root.AssemblyLinearVelocity = velocity
	npc.root.AssemblyAngularVelocity = spin
	npc.flying = true
	npc.releasedAt = os.clock()
	npc.peakSpeed = velocity.Magnitude
	npc.stillFor = 0
	npc.settleAt = nil
	npc.landedInFire = false
	npc.model:SetAttribute("Flying", true)
	npc.prompt.Enabled = true -- catch it mid-air if you can
end

-- carry --------------------------------------------------------------------------------------

local function canCarry(player: Player, npc: Npc, skipReach: boolean?): boolean
	if carrying(player) ~= "" or player:GetAttribute(Names.Attr.Downed) == true then
		return false
	end
	local hrp, hum = rootOf(player), humanoid(player)
	if not hrp or not hum or hum.Health <= 0 then
		return false
	end
	if player.Character and Ragdoll.isRagdolled(player.Character) then
		return false
	end
	return skipReach == true or Net.near(player, npc.root.Position, RescueConfig.CarryReach)
end

local function carry(list: { Player }, npc: Npc, skipReach: boolean?): boolean
	if not Rules.canPick(npc.state) then -- Trapped or Downed (also while flying: catch it!)
		return false
	end
	if #npc.carriers > 0 then
		return false
	end
	for _, p in list do
		if not canCarry(p, npc, skipReach) then
			return false
		end
	end
	local first = list[1]
	local hrp = rootOf(first) :: BasePart
	npc.panic = false
	npc.model:SetAttribute("Panicking", false)
	npc.flying = false
	npc.settleAt = nil
	npc.model:SetAttribute("Flying", false)
	for _, p in list do
		local hum = humanoid(p) :: Humanoid
		hum:UnequipTools()
		p:SetAttribute(Names.Attr.Carrying, npc.id)
		hum.WalkSpeed = Rules.speed(npc.kind, #list, RescueConfig)
	end
	npc.carriers = table.clone(list)
	npc.lastCarrier = first
	npc.pending = {}

	-- physics: free the assembly and hang it off the carrier(s) on soft constraints (the wobble)
	local grab = npc.root:FindFirstChild("Grab") :: Attachment
	local hold = holdAttachment(hrp, npc.kind)
	npc.model:PivotTo(hold.WorldCFrame * npc.root.PivotOffset) -- Root centre onto the hold point
	npc.root.Anchored = false
	npc.root.CanCollide = false
	local align = Instance.new("AlignPosition")
	align.Name = "CarryPos"
	align.Attachment0 = grab
	align.MaxForce = 1e7
	align.MaxVelocity = 200
	align.Responsiveness = RescueConfig.HoldResponsiveness
	local orient = Instance.new("AlignOrientation")
	orient.Name = "CarryTwist"
	orient.Attachment0 = grab
	orient.MaxTorque = 1e7
	orient.Responsiveness = RescueConfig.HoldTwistResponsiveness
	if #list == 1 then
		align.Attachment1 = hold
		orient.Attachment1 = hold
	else
		align.Mode = Enum.PositionAlignmentMode.OneAttachment
		align.Position = hold.WorldPosition
		orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
		orient.CFrame = hold.WorldCFrame.Rotation
	end
	align.Parent = npc.root
	orient.Parent = npc.root
	npc.align = align
	npc.orient = orient
	pcall(function()
		npc.root:SetNetworkOwner(if #list == 1 then first else nil)
	end)

	npc.prompt.Enabled = false
	setState(npc, "Carried")
	npc.model:SetAttribute(Names.Attr.CarriedBy, first.UserId)
	say(npc, "carried")
	for _, p in list do
		RescueService.Picked:Fire(p, npc.id, npc.kind)
	end
	Telemetry.count("npcs_picked")
	if #list > 1 then
		Telemetry.count("rescue_pair_lifts")
		notifySquad(npc, `{helmetTag(list[1])} and {helmetTag(list[2])} lifted the PANDA!`, "good")
	end
	fx("picked", npc.root.Position, { kind = npc.kind, id = npc.id })
	return true
end

-- Prompt handler: the panda needs PandaCarriers players who trigger within PandaPairWindow.
local function onPick(player: Player, npc: Npc)
	local need = if npc.kind == "Panda" then RescueConfig.PandaCarriers else 1
	if need <= 1 then
		carry({ player }, npc, false)
		return
	end
	if not canCarry(player, npc, false) then
		return
	end
	local now = os.clock()
	npc.pending[player] = now
	for p in npc.pending do
		if p.Parent ~= Players or not canCarry(p, npc, false) then
			npc.pending[p] = nil
		end
	end
	local group = Rules.pair(npc.pending, now, RescueConfig.PandaPairWindow, need)
	if #group >= need then
		carry(group :: { Player }, npc, false)
		return
	end
	if RescueConfig.PandaSoloIfAlone and #squadOf(npc) <= 1 then
		carry({ player }, npc, false)
		Net.notify(player, "Oof. This panda is HEAVY. (Bring a friend next time.)", "info")
		return
	end
	Builder.shout(npc.model, "??? (1/2)")
	Net.notify(player, "The PANDA is too heavy! A buddy must hold [E] on it too!", "info")
end

-- drop / throw / deliver ---------------------------------------------------------------------------

local function npcCarriedBy(player: Player): Npc?
	local id = carrying(player)
	if id == "" then
		return nil
	end
	local npc = npcs[id]
	if not npc then
		player:SetAttribute(Names.Attr.Carrying, "")
		restoreSpeed(player)
	end
	return npc
end

local function drop(player: Player, forced: boolean?): boolean
	local npc = npcCarriedBy(player)
	if not npc then
		return false
	end
	local hrp = rootOf(player)
	releaseCarry(npc)
	setState(npc, if npc.pose == "lying" then "Downed" else "Trapped")
	local look = if hrp then hrp.CFrame.LookVector else Vector3.zero
	launch(npc, look * 6 + Vector3.new(0, 6, 0), Vector3.new(math.random() - 0.5, 0, math.random() - 0.5) * 4)
	npc.dropper = player
	npc.droppedAt = os.clock()
	say(npc, "flying")
	RescueService.Dropped:Fire(player, npc.id)
	Telemetry.count("npcs_dropped")
	if forced then
		Builder.shout(npc.model, "BUTTERFINGERS!")
	end
	return true
end

local function throw(player: Player, aim: Vector3, charge: number): boolean
	local npc = npcCarriedBy(player)
	if not npc then
		return false
	end
	releaseCarry(npc)
	setState(npc, if npc.pose == "lying" then "Downed" else "Trapped")
	local forward, up = Rules.throwSpeed(charge, npc.kind, RescueConfig)
	local flat = Vector3.new(aim.X, math.max(aim.Y, -0.2), aim.Z)
	if flat.Magnitude < 0.05 then
		flat = Vector3.new(0, 0, -1)
	end
	local spin = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5).Unit * RescueConfig.ThrowSpin
	launch(npc, flat.Unit * forward + Vector3.new(0, up, 0), spin)
	npc.thrower = player
	npc.thrownAt = os.clock()
	say(npc, "flying")
	RescueService.Thrown:Fire(player, npc.id) -- not Dropped: BlameService counts those as fumbles
	Telemetry.count("npcs_thrown")
	fx("yeet", npc.root.Position, { kind = npc.kind, by = player.UserId, charge = charge })
	return true
end

local function deliverNpc(npc: Npc, credit: Player?, spot: BasePart?): boolean
	if npc.state == "Rescued" or npc.state == "Toasted" then
		return false
	end
	local helpers = releaseCarry(npc)
	if #helpers == 0 and credit then
		helpers = { credit }
	end
	local who = credit or helpers[1]
	deliveredCount += 1
	local at = spot or firstDropoff()
	local feet = if at
		then at.CFrame * CFrame.new(((deliveredCount - 1) % 3 - 1) * 3, -at.Size.Y / 2, 0)
		else groundFeet(npc.root.Position, npc.root.CFrame.LookVector)
	plant(npc, feet, if npc.kind == "Civilian" then "stand" else "sitting")
	npc.prompt.Enabled = false
	setState(npc, "Rescued")
	npc.panic = false
	npc.model:SetAttribute("Panicking", false)
	say(npc, "rescued")
	local model = npc.model
	task.delay(4, function()
		if model.Parent then
			Builder.shout(model, nil)
		end
	end)
	if who then
		RescueService.Rescued:Fire(who, npc.id, npc.kind)
	end
	for _, p in helpers do
		RescueService.Delivered:Fire(p, npc.id, npc.kind)
	end
	Telemetry.count("rescued")
	Telemetry.count(`rescued_{string.lower(npc.kind)}`)
	if PETS[npc.kind] then
		Telemetry.count("rescued_pet")
	end
	fx("delivered", npc.root.Position, { kind = npc.kind, id = npc.id, by = if who then who.UserId else 0 })
	local name = string.upper(npc.kind)
	local text = if not who
		then `The {string.lower(npc.kind)} is safe!`
		elseif #helpers >= 2 then `{helmetTag(helpers[1])} & {helmetTag(helpers[2])} SAVED THE {name}!`
		elseif npc.thrower == who and npc.thrownAt and os.clock() - npc.thrownAt < 4 then `{helmetTag(who)} YEETED the {string.lower(npc.kind)} to safety!`
		else `{helmetTag(who)} rescued the {string.lower(npc.kind)}!`
	notifySquad(npc, text, "good")
	return true
end

local function deliver(player: Player, spot: BasePart?): boolean
	local npc = npcCarriedBy(player)
	if not npc then
		return false
	end
	return deliverNpc(npc, player, spot)
end

local function toast(npc: Npc, culprit: Player?)
	if npc.state == "Rescued" or npc.state == "Toasted" then
		return
	end
	local carriers = releaseCarry(npc)
	local guilty = culprit or Rules.culprit(npc, os.clock(), RescueConfig.BlameWindow) or carriers[1]
	plant(npc, groundFeet(npc.root.Position, npc.root.CFrame.LookVector), "lying")
	Builder.toast(npc.model)
	npc.prompt.Enabled = false
	npc.panic = false
	npc.model:SetAttribute("Panicking", false)
	npc.health = 0
	npc.model:SetAttribute("Health", 0)
	setState(npc, "Toasted")
	say(npc, "toasted")
	RescueService.Toasted:Fire(npc.id, npc.kind, guilty)
	Telemetry.count("npcs_toasted")
	fx("toasted", npc.root.Position, { kind = npc.kind, id = npc.id })
	local what = string.lower(npc.kind)
	local text = if guilty and npc.landedInFire
		then `{helmetTag(guilty)} YEETED the {what} into the FIRE!`
		elseif guilty then `The {what} got TOASTED. Blame {helmetTag(guilty)}.`
		else `The {what} got TOASTED!`
	notifySquad(npc, text, if guilty then "blame" else "bad")
end

local function hurt(npc: Npc, amount: number, culprit: Player?)
	if amount <= 0 then
		return
	end
	npc.health = math.max(0, npc.health - amount)
	npc.model:SetAttribute("Health", math.floor(npc.health + 0.5))
	if npc.health <= 0 then
		toast(npc, culprit)
	end
end

-- spawn --------------------------------------------------------------------------------------------

local function spawnOne(kind: string, feet: CFrame, pose: string, scope: string): Npc
	nextId += 1
	local id = `R{nextId}`
	local model = Builder.build(kind, feet, pose)
	model.Name = id
	local root = model.PrimaryPart :: BasePart
	local state = Rules.initialState(pose)
	model:SetAttribute(Names.Attr.RescueId, id)
	model:SetAttribute(Names.Attr.Kind, kind)
	model:SetAttribute(Names.Attr.RescueState, state)
	model:SetAttribute(Names.Attr.CarriedBy, 0)
	model:SetAttribute(Names.Attr.InstanceId, scope)
	model:SetAttribute("Health", RescueConfig.Health)
	model:SetAttribute("Panicking", false)
	model:SetAttribute("Flying", false)
	CollectionService:AddTag(model, Names.Tag.Rescuable)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Carry"
	prompt.ActionText = "Pick up"
	prompt.ObjectText = if kind == "Panda" then "Panda (needs 2!)" else kind
	prompt.HoldDuration = if kind == "Panda" then RescueConfig.CarryHold * 2 else RescueConfig.CarryHold
	prompt.MaxActivationDistance = if kind == "Panda" then RescueConfig.PromptDistance + 3 else RescueConfig.PromptDistance
	prompt.RequiresLineOfSight = false
	prompt.Parent = root
	local npc: Npc = {
		id = id,
		kind = kind,
		scope = scope,
		model = model,
		root = root,
		prompt = prompt,
		state = state,
		pose = pose,
		health = RescueConfig.Health,
		home = feet,
		carriers = {},
		align = nil,
		orient = nil,
		pending = {},
		flying = false,
		releasedAt = 0,
		peakSpeed = 0,
		stillFor = 0,
		settleAt = nil,
		landedInFire = false,
		panic = false,
		panicT = 0,
		panicCentre = feet.Position,
		calmFor = 0,
		thrower = nil,
		thrownAt = nil,
		dropper = nil,
		droppedAt = nil,
		lastCarrier = nil,
	}
	prompt.Triggered:Connect(function(player: Player)
		local live = npcs[id]
		if live then
			onPick(player, live)
		end
	end)
	npcs[id] = npc
	say(npc, if state == "Downed" then "downed" else "idle")
	model.Parent = folder()
	Telemetry.count("npcs_spawned")
	return npc
end

local function markerFeet(marker: BasePart): CFrame
	-- marker centre is 1 stud above the ground/seat point; -Z of the marker is the facing
	local feet = marker.Position - Vector3.new(0, marker.Size.Y / 2, 0)
	local look = Vector3.new(marker.CFrame.LookVector.X, 0, marker.CFrame.LookVector.Z)
	return if look.Magnitude > 0.01 then CFrame.lookAt(feet, feet + look.Unit) else CFrame.new(feet)
end

local function scopeOf(container: Instance, fallback: string): string
	local v = container:GetAttribute(Names.Attr.InstanceId)
	if type(v) == "string" and v ~= "" then
		return v
	end
	return fallback
end

-- tick (AI, fire, landing, delivery) ---------------------------------------------------------------

local function validCarrier(p: Player): boolean
	if p.Parent ~= Players or p:GetAttribute(Names.Attr.Downed) == true then
		return false
	end
	local hum, hrp = humanoid(p), rootOf(p)
	if not hum or not hrp or hum.Health <= 0 then
		return false
	end
	return not (p.Character and Ragdoll.isRagdolled(p.Character))
end

local function tickCarried(npc: Npc, fires: { Fire }, dt: number)
	for _, p in npc.carriers do
		if not validCarrier(p) or carrying(p) ~= npc.id then
			-- forced drop (downed, ragdolled, left): drop() releases every carrier
			if carrying(p) ~= npc.id then
				p:SetAttribute(Names.Attr.Carrying, npc.id)
			end
			drop(p, true)
			return
		end
	end
	if #npc.carriers >= 2 then
		local a, b = rootOf(npc.carriers[1]) :: BasePart, rootOf(npc.carriers[2]) :: BasePart
		if (a.Position - b.Position).Magnitude > RescueConfig.PandaPairSnap then
			notifySquad(npc, "The panda slipped! Stay together!", "bad")
			drop(npc.carriers[1], true)
			return
		end
	end
	for _, p in npc.carriers do
		local hrp = rootOf(p)
		local spot = hrp and dropoffAt(hrp.Position)
		if spot then
			deliverNpc(npc, npc.carriers[1], spot)
			return
		end
	end
	if math.random() < dt / RescueConfig.VoiceInterval then
		say(npc, "carried") -- keeps screaming / meowing while dangling
	end
	local dist, level = nearestFire(fires, npc.root.Position)
	hurt(npc, Rules.fireDamage(dist, level, dt, RescueConfig) * RescueConfig.CarriedFireMult, npc.carriers[1])
end

local function tickFlying(npc: Npc, fires: { Fire }, dt: number)
	local now = os.clock()
	if npc.settleAt == nil and math.random() < dt / RescueConfig.VoiceInterval then
		say(npc, "flying")
	end
	if npc.root.Position.Y < workspace.FallenPartsDestroyHeight + 30 then
		plant(npc, npc.home, npc.pose) -- fell out of the world: pop back home
		return
	end
	local spot = dropoffAt(npc.root.Position)
	if spot then
		deliverNpc(npc, npc.thrower or npc.dropper, spot) -- YEETED into the truck!
		return
	end
	local speed = npc.root.AssemblyLinearVelocity.Magnitude
	if npc.settleAt == nil then
		npc.peakSpeed = math.max(npc.peakSpeed, speed)
		if now - npc.releasedAt > 0.3 and speed < 3 then
			npc.stillFor += dt
		else
			npc.stillFor = 0
		end
		if npc.stillFor >= 0.25 or now - npc.releasedAt > 6 then
			-- landed: lie there flopped (ragdoll) for a moment
			npc.settleAt = now + RescueConfig.LandRagdoll
			local hard = Rules.landing(npc.peakSpeed, RescueConfig) == "Downed"
			fx("landed", npc.root.Position, { kind = npc.kind, hard = hard, speed = npc.peakSpeed })
			local dist = nearestFire(fires, npc.root.Position)
			if dist <= RescueConfig.FireHurtRadius then
				npc.landedInFire = true
				hurt(npc, RescueConfig.LandInFireDamage, Rules.culprit(npc, now, RescueConfig.BlameWindow))
				if npc.state == "Toasted" then
					return
				end
			end
			say(npc, if hard then "downed" else "idle")
		end
	elseif now >= npc.settleAt then
		local hard = Rules.landing(npc.peakSpeed, RescueConfig) == "Downed"
		local pose = if hard or npc.pose == "lying" then "lying" else (if npc.kind == "Civilian" then "stand" else npc.pose)
		plant(npc, groundFeet(npc.root.Position, npc.root.CFrame.LookVector), pose)
		setState(npc, if pose == "lying" then "Downed" else "Trapped")
		if hard then
			Telemetry.count("npcs_downed")
		end
		say(npc, if pose == "lying" then "downed" else "idle")
	end
	local dist, level = nearestFire(fires, npc.root.Position)
	hurt(npc, Rules.fireDamage(dist, level, dt, RescueConfig), Rules.culprit(npc, now, RescueConfig.BlameWindow))
end

local function tickIdle(npc: Npc, fires: { Fire }, dt: number)
	local pos = npc.root.Position
	local dist, level = nearestFire(fires, pos)
	if npc.state == "Trapped" then
		if dist <= RescueConfig.PanicRadius then
			npc.calmFor = 0
			if not npc.panic then
				npc.panic = true
				npc.panicT = 0
				-- circle centre one radius off to the side, so the NPC starts on the circle
				npc.panicCentre = npc.home.Position - npc.home.RightVector * RescueConfig.PanicCircle
				npc.model:SetAttribute("Panicking", true)
				Telemetry.count("npcs_panicked")
				say(npc, "panic")
			elseif math.random() < 0.08 then
				say(npc, "panic")
			end
		elseif npc.panic then
			npc.calmFor += dt
			if npc.calmFor >= RescueConfig.PanicCalm then
				npc.panic = false
				npc.model:SetAttribute("Panicking", false)
				plant(npc, groundFeet(npc.root.Position, npc.root.CFrame.LookVector), npc.pose)
				say(npc, "idle")
			end
		end
	end
	hurt(npc, Rules.fireDamage(dist, level, dt, RescueConfig), Rules.culprit(npc, os.clock(), RescueConfig.BlameWindow))
end

local function tick(dt: number)
	local fires = burningFires()
	for _, npc in npcs do
		if not npc.model.Parent or npc.state == "Rescued" or npc.state == "Toasted" then
			continue
		end
		if #npc.carriers > 0 then
			tickCarried(npc, fires, dt)
		elseif npc.flying then
			tickFlying(npc, fires, dt)
		else
			tickIdle(npc, fires, dt)
		end
	end
end

-- every frame: panic circles and the two-carrier panda hold point
local function step(dt: number)
	for _, npc in npcs do
		if npc.panic and #npc.carriers == 0 and not npc.flying and npc.state == "Trapped" then
			npc.panicT += dt
			local speed = if npc.kind == "Panda" then RescueConfig.PanicSpeed * 0.4 else RescueConfig.PanicSpeed
			local x, z, yaw = Rules.panicPoint(npc.panicT, RescueConfig.PanicCircle, speed)
			local hop = math.abs(math.sin(npc.panicT * 11)) * 0.6
			local c = npc.panicCentre
			local cf = CFrame.new(c.X + x, c.Y + hop, c.Z + z) * CFrame.Angles(0, yaw, 0)
			npc.model:PivotTo(cf)
			npc.home = CFrame.new(c.X + x, c.Y, c.Z + z) * CFrame.Angles(0, yaw, 0)
		elseif #npc.carriers >= 2 and npc.align and npc.orient then
			local a, b = rootOf(npc.carriers[1]), rootOf(npc.carriers[2])
			if a and b then
				local mid = (a.Position + b.Position) / 2
				local look = a.CFrame.LookVector + b.CFrame.LookVector
				look = Vector3.new(look.X, 0, look.Z)
				if look.Magnitude < 0.05 then
					look = Vector3.new(0, 0, -1)
				end
				local front = mid + look.Unit * RescueConfig.HoldForward + Vector3.new(0, RescueConfig.HoldUp, 0)
				npc.align.Position = front
				npc.orient.CFrame = CFrame.lookAt(front, mid).Rotation
			end
		end
	end
end

-- lifecycle -------------------------------------------------------------------------------------

function RescueService:Init(all: { [string]: any })
	services = all
end

function RescueService:Start()
	local Drop = Net.event("Rescue", "Drop")
	local Throw = Net.event("Rescue", "Throw")
	FxRemote = Net.event("Rescue", "Fx")
	Net.onServer(Drop, { rate = 2, burst = 1 }, function(player: Player)
		drop(player, false)
	end)
	Net.onServer(Throw, { rate = 2, burst = 1 }, function(player: Player, aim: any, charge: any)
		local dir = Net.unit(aim)
		if not dir then
			local hrp = rootOf(player)
			dir = if hrp then hrp.CFrame.LookVector else nil
		end
		if not dir then
			return
		end
		local c = if type(charge) == "number" and charge == charge then math.clamp(charge, 0, 1) else 0
		throw(player, dir, c)
	end)

	local Squad = services.SquadService
	if Squad and Squad.Downed and type(Squad.Downed.Connect) == "function" then
		Squad.Downed:Connect(function(victim: Player)
			drop(victim, true)
		end)
	end
	Players.PlayerRemoving:Connect(function(player)
		drop(player, true)
	end)
	local function track(player: Player)
		player:SetAttribute(Names.Attr.Carrying, "")
		player.CharacterRemoving:Connect(function()
			drop(player, true)
			player:SetAttribute(Names.Attr.Carrying, "")
		end)
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end

	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			warn(`[RescueService] step: {err}`)
		end
	end)
	task.spawn(function()
		local last = os.clock()
		while true do
			task.wait(1 / RescueConfig.TickHz)
			local now = os.clock()
			local ok, err = pcall(tick, now - last)
			last = now
			if not ok then
				warn(`[RescueService] tick: {err}`)
			end
		end
	end)
end

-- public API ------------------------------------------------------------------------------------

function RescueService:SpawnAt(instanceId: string, marker: BasePart, kind: string?): string?
	if typeof(marker) ~= "Instance" or not marker:IsA("BasePart") then
		return nil
	end
	local k = Rules.kind(kind or marker:GetAttribute(Names.Attr.Kind))
	local pose = Rules.pose(marker:GetAttribute("Pose"))
	return spawnOne(k, markerFeet(marker), pose, instanceId or "").id
end

function RescueService:Spawn(locationId: string, count: number)
	local Map = services.MapService
	local container: Instance? = nil
	if Map then
		if type(Map.GetInstance) == "function" then
			container = Map:GetInstance(locationId)
		end
		if not container and type(Map.GetLocation) == "function" then
			container = Map:GetLocation(locationId)
		end
	end
	if not container then
		warn(`[RescueService] no location/instance {locationId}: nothing to rescue`)
		return
	end
	local scope = scopeOf(container, locationId)
	self:ClearInstance(scope)
	local markers: { BasePart } = {}
	for _, d in container:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.RescueSpawn) then
			table.insert(markers, d)
		end
	end
	table.sort(markers, function(a, b)
		if a.Name ~= b.Name then
			return a.Name < b.Name
		end
		return a.Position.X < b.Position.X
	end)
	for i = 1, math.min(count, #markers) do
		self:SpawnAt(scope, markers[i], nil)
	end
end

function RescueService:ClearInstance(instanceId: string)
	for id, npc in npcs do
		if npc.scope == instanceId then
			releaseCarry(npc)
			npc.model:Destroy()
			npcs[id] = nil
		end
	end
	if next(npcs) == nil then
		nextId = 0
		deliveredCount = 0
	end
end

function RescueService:Clear()
	for _, npc in npcs do
		releaseCarry(npc)
		npc.model:Destroy()
	end
	table.clear(npcs)
	for _, player in Players:GetPlayers() do
		if carrying(player) ~= "" then
			player:SetAttribute(Names.Attr.Carrying, "")
			restoreSpeed(player)
		end
	end
	nextId = 0
	deliveredCount = 0
end

function RescueService:Deliver(player: Player): boolean
	local hrp = rootOf(player)
	return deliver(player, if hrp then dropoffAt(hrp.Position) else nil)
end

-- test hooks -------------------------------------------------------------------------------------

-- v2 (StructureService): a collapse landed on them. Same Health as fire damage; 0 = Toasted.
function RescueService:Hurt(rescueId: string, amount: number, culprit: Player?): boolean
	local npc = npcs[rescueId]
	if not npc or type(amount) ~= "number" or npc.state == "Rescued" or npc.state == "Toasted" then
		return false
	end
	hurt(npc, amount, culprit)
	return true
end

function RescueService:_carry(player: Player, rescueId: string): boolean
	local npc = npcs[rescueId]
	return npc ~= nil and carry({ player }, npc, true)
end

function RescueService:_deliver(player: Player): boolean
	return deliver(player, firstDropoff())
end

function RescueService:_drop(player: Player): boolean
	return drop(player, false)
end

function RescueService:_throw(player: Player, charge: number?): boolean
	local hrp = rootOf(player)
	return hrp ~= nil and throw(player, hrp.CFrame.LookVector, charge or 1)
end

function RescueService:_toast(rescueId: string): boolean
	local npc = npcs[rescueId]
	if not npc then
		return false
	end
	toast(npc, nil)
	return npc.state == "Toasted"
end

function RescueService:_spawnAt(kind: string, pos: Vector3): string
	return spawnOne(Rules.kind(kind), groundFeet(pos + Vector3.new(0, 3, 0), Vector3.new(0, 0, -1)), "stand", "").id
end

function RescueService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Rescue")
	for _, name in { "Drop", "Throw", "Fx" } do
		if not (ns and ns:FindFirstChild(name)) then
			return false, `Rescue/{name} missing`
		end
	end
	if Rules.kind("panda") ~= "Panda" or Rules.speed("Panda", 2, RescueConfig) <= Rules.speed("Panda", 1, RescueConfig) then
		return false, "RescueRules broken"
	end
	local n = 0
	for _ in npcs do
		n += 1
	end
	return true, `{n} npcs`
end

return RescueService
