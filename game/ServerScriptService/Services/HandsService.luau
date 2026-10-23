--!strict
-- HandsService [owner: Hands agent]. Server side of the physics hands (ClientLib/PhysicsHands):
-- validates grabs, slaps, shoves and axe-head impacts that the client's local hand physics detects,
-- hands network ownership of grabbed props to the grabber, and relays every player's hand pose to
-- everyone else at HandsConfig.PoseHz so other clients can aim that player's arms.
--
-- Public API:
--   HandsService:GetHolder(part: BasePart): Player?   -- who is holding this assembly, if anyone
--   HandsService:ReleaseAll(player: Player)           -- drop everything (death, ragdoll, leave)
-- Signals:
--   Slapped(slapper: Player, victim: Player?, model: Model, kind: "hand" | "axe")  -- landed slap/bonk
--   Grabbed(player: Player, part: BasePart)  Released(player: Player, part: BasePart)
-- Remotes (namespace Hands):
--   Pose    (Unreliable C->S, packet = HandsMath.encodePose, ~15/s)
--   Poses   (Unreliable S->C all, flat {userId, 7 numbers, userId, ...}, PoseHz)
--   Grab    (RemoteFunction C->S: part, side "L"|"R" -> "ok" | "heavy" | false)
--   Release (C->S: part, side)
--   Slap    (C->S: victim Model, hand velocity Vector3, kind "hand"|"axe")
--   Push    (C->S: part, hand velocity Vector3)          -- loose props get shoved; unlocked doors open
--   AxeHit  (C->S: door BasePart, head speed number)     -- swing speed = door damage (HandsMath.axeHits)
--   Fx      (S->C all: kind "slap"|"bonk"|"tonk"|"heavy", position, victimUserId | 0) (door hits pop via ToolService)
-- Writes: part attr HeldBy (UserId) on grabbed assemblies; NPC attr Slapped = true.
-- Calls (nil-guarded): PhysicsFxService:Impulse(target, vector, player) for slaps and prop shoves
--   (else Shared/Ragdoll / ApplyImpulse),
--   ToolService:HitDoor(player, door, hits) / ToolService:PushDoor(door), SquadService:Revive(victim,
--   by, "slap") for a Downed teammate, InventoryService:GetHand(player).
-- Counters: hands_grabs, hands_grab_denied, hands_slaps, hands_slap_revives, hands_axe_bonks,
--   hands_axe_hits, hands_axe_tonks, hands_pushes, hands_doors_pushed

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local HandsMath = require(ReplicatedStorage:WaitForChild("HandsMath") :: ModuleScript)
local HandsConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HandsConfig") :: ModuleScript) :: any

local HandsService = {}
HandsService.Priority = 60
HandsService.Slapped = Signal.new() :: Signal.Signal<Player, Player?, Model, string>
HandsService.Grabbed = Signal.new() :: Signal.Signal<Player, BasePart>
HandsService.Released = Signal.new() :: Signal.Signal<Player, BasePart>

local ATTR_HELD = "HeldBy"

type Hold = { player: Player, sides: { [string]: boolean }, token: number }

local services: { [string]: any } = {}
local held: { [BasePart]: Hold } = {}
local latest: { [Player]: { number } } = {}
local dirty: { [Player]: boolean } = {}
local lastGrab: { [Player]: number } = {}
local lastPush: { [Player]: number } = {}
local lastAxe: { [Player]: number } = {}
local lastSlap: { [Player]: { [Model]: number } } = {}

local function slapTimes(player: Player): { [Model]: number }
	local t = lastSlap[player]
	if not t then
		t = setmetatable({}, { __mode = "k" }) :: any
		lastSlap[player] = t
	end
	return t :: { [Model]: number }
end
local FxRemote: RemoteEvent? = nil
local PosesRemote: any = nil

local function call(serviceName: string, method: string, ...: any): (boolean, any)
	local svc = services[serviceName]
	local fn = svc and svc[method]
	if type(fn) ~= "function" then
		return false, nil
	end
	local ok, res = pcall(fn, svc, ...)
	if not ok then
		warn(`[HandsService] {serviceName}:{method} failed: {res}`)
		return false, nil
	end
	return true, res
end

local function fx(kind: string, position: Vector3, extra: number?)
	if FxRemote then
		FxRemote:FireAllClients(kind, position, extra or 0)
	end
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function blocked(player: Player): boolean
	local carrying = player:GetAttribute(Names.Attr.Carrying)
	if (type(carrying) == "string" and carrying ~= "") or player:GetAttribute(Names.Attr.Downed) == true then
		return true
	end
	local char = player.Character
	return char == nil or Ragdoll.isRagdolled(char)
end

local function holdsAxe(player: Player): boolean
	local char = player.Character
	local t = char and char:FindFirstChild("Axe")
	if t and t:IsA("Tool") then
		return true
	end
	local ok, hand = call("InventoryService", "GetHand", player)
	return ok and type(hand) == "string" and string.find(string.lower(hand), "axe") ~= nil
end

local function vec(v: any): Vector3?
	if typeof(v) ~= "Vector3" then
		return nil
	end
	local m = (v :: Vector3).Magnitude
	if m ~= m or m == math.huge then
		return nil
	end
	return v :: Vector3
end

-- grabbing -------------------------------------------------------------------------------------
-- Things hands never pick up: characters/NPCs (slap them instead), trucks, rescue targets (RescueService
-- carries those), anything anchored or flagged NoGrab.
local function forbidden(part: BasePart): boolean
	if part:GetAttribute("NoGrab") == true or CollectionService:HasTag(part, Names.Tag.Door) then
		return true
	end
	local node: Instance? = part.Parent
	while node and node ~= workspace do
		if node:IsA("Model") then
			if node:FindFirstChildOfClass("Humanoid") then
				return true
			end
			if node:GetAttribute("OwnerUserId") ~= nil or node:GetAttribute("NoGrab") == true then
				return true
			end
			if CollectionService:HasTag(node, Names.Tag.Truck) or CollectionService:HasTag(node, Names.Tag.Rescuable) then
				return true
			end
		end
		node = node.Parent
	end
	return false
end

local function assemblyOf(part: BasePart): BasePart
	local root = part.AssemblyRootPart
	return if root then root else part
end

local function handsOn(root: BasePart, player: Player): number
	local h = held[root]
	if not h or h.player ~= player then
		return 0
	end
	local n = 0
	for _ in h.sides do
		n += 1
	end
	return n
end

local function restoreOwnership(root: BasePart, token: number)
	task.delay(HandsConfig.ReleaseOwnerSeconds, function()
		local h = held[root]
		if h and h.token ~= token then
			return -- grabbed again since
		end
		if h and next(h.sides) ~= nil then
			return
		end
		held[root] = nil
		if root.Parent and root:IsDescendantOf(workspace) and not root.Anchored then
			pcall(function()
				if root:CanSetNetworkOwnership() then
					root:SetNetworkOwnershipAuto()
				end
			end)
		end
	end)
end

local function release(player: Player, root: BasePart, side: string?)
	local h = held[root]
	if not h or h.player ~= player then
		return
	end
	if side then
		h.sides[side] = nil
	else
		table.clear(h.sides)
	end
	if next(h.sides) == nil then
		h.token += 1
		if root.Parent then
			root:SetAttribute(ATTR_HELD, nil)
		end
		HandsService.Released:Fire(player, root)
		restoreOwnership(root, h.token)
	end
end

local function onGrab(player: Player, rawPart: any, rawSide: any): any
	local side = if rawSide == "L" or rawSide == "R" then rawSide else nil
	if not side or typeof(rawPart) ~= "Instance" or not (rawPart :: Instance):IsA("BasePart") then
		return false
	end
	local now = os.clock()
	if now - (lastGrab[player] or 0) < HandsConfig.GrabCooldown * 0.5 then
		return false
	end
	lastGrab[player] = now
	local part = rawPart :: BasePart
	if not part:IsDescendantOf(workspace) or part.Anchored or forbidden(part) or blocked(player) then
		Telemetry.count("hands_grab_denied")
		return false
	end
	local root = assemblyOf(part)
	if root.Anchored or not Net.near(player, part.Position, HandsConfig.ServerGrabReach) then
		Telemetry.count("hands_grab_denied")
		return false
	end
	local h = held[root]
	if h and h.player ~= player and next(h.sides) ~= nil then
		Telemetry.count("hands_grab_denied")
		return false -- a teammate has it (tug of war is a v3 feature)
	end
	local hands = handsOn(root, player) + (if h and h.player == player and h.sides[side] then 0 else 1)
	local verdict = HandsMath.grabVerdict(root.AssemblyMass, hands, HandsConfig)
	if verdict == "no" then
		fx("heavy", part.Position, 0)
		Telemetry.count("hands_grab_denied")
		return false
	end
	local okOwner = pcall(function()
		if root:CanSetNetworkOwnership() then
			root:SetNetworkOwner(player)
		end
	end)
	if not okOwner then
		return false
	end
	local hold: Hold = if h and h.player == player
		then h
		else { player = player, sides = {}, token = if h then h.token + 1 else 0 }
	held[root] = hold
	hold.sides[side] = true
	root:SetAttribute(ATTR_HELD, player.UserId)
	Telemetry.count("hands_grabs")
	HandsService.Grabbed:Fire(player, root)
	return verdict
end

local function onRelease(player: Player, rawPart: any, rawSide: any)
	if typeof(rawPart) ~= "Instance" or not (rawPart :: Instance):IsA("BasePart") then
		return
	end
	local side = if rawSide == "L" or rawSide == "R" then rawSide else nil
	release(player, assemblyOf(rawPart :: BasePart), side)
end

-- slaps ------------------------------------------------------------------------------------------
local function knock(model: Model, impulse: Vector3, by: Player)
	local ok, res = call("PhysicsFxService", "Impulse", model, impulse, by)
	if ok and res ~= false then
		return
	end
	Ragdoll.knockback(model, impulse)
end

local function onSlap(player: Player, rawModel: any, rawVel: any, rawKind: any)
	if typeof(rawModel) ~= "Instance" or not (rawModel :: Instance):IsA("Model") then
		return
	end
	local model = rawModel :: Model
	local vel = vec(rawVel)
	local kind = if rawKind == "axe" then "axe" else "hand"
	if not vel or model == player.Character or not model:IsDescendantOf(workspace) or blocked(player) then
		return
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	local vroot = model:FindFirstChild("HumanoidRootPart") :: BasePart?
	local root = rootOf(player)
	if not (hum and vroot and root) or hum.Health <= 0 then
		return
	end
	if (vroot.Position - root.Position).Magnitude > HandsConfig.SlapReach then
		return
	end
	if kind == "axe" and not holdsAxe(player) then
		return
	end
	local times = slapTimes(player)
	local now = os.clock()
	if now - (times[model] or 0) < HandsConfig.SlapCooldown then
		return
	end
	local speed = math.min(vel.Magnitude, HandsConfig.SlapMaxReportedSpeed)
	local push, lift, rag
	if kind == "axe" then
		push, lift, rag = HandsConfig.AxeBonkPush, HandsConfig.AxeBonkLift, false
		if speed < HandsConfig.AxeMinSpeed then
			return
		end
	else
		push, lift, rag = HandsMath.slap(speed, HandsConfig)
		if push <= 0 then
			return -- a friendly pat
		end
	end
	times[model] = now

	-- direction: mostly from slapper to victim (the client only steers it a little)
	local away = vroot.Position - root.Position
	away = Vector3.new(away.X, 0, away.Z)
	away = if away.Magnitude > 1e-3 then away.Unit else root.CFrame.LookVector
	local flat = Vector3.new(vel.X, 0, vel.Z)
	local dir = if flat.Magnitude > 1e-3 and flat.Unit:Dot(away) > 0 then (away * 0.6 + flat.Unit * 0.4).Unit else away
	local impulse = dir * push + Vector3.new(0, lift, 0)

	local victim = Players:GetPlayerFromCharacter(model)
	local hit = vroot.Position + Vector3.new(0, 1.5, 0)
	if victim and victim:GetAttribute(Names.Attr.Downed) == true and kind == "hand" then
		-- the trailer gag: slap a downed teammate awake (SquadService charges the blame point)
		local ok = call("SquadService", "Revive", victim, player, "slap")
		if ok then
			Telemetry.count("hands_slap_revives")
			fx("slap", hit, victim.UserId)
			HandsService.Slapped:Fire(player, victim, model, kind)
			return
		end
	end
	knock(model, impulse, player)
	if rag then
		Ragdoll.enable(model, HandsConfig.SlapRagdollSeconds)
	end
	if not victim then
		model:SetAttribute("Slapped", true) -- dazed NPCs snap out of it (HazardService reads this)
	end
	Telemetry.count(if kind == "axe" then "hands_axe_bonks" else "hands_slaps")
	fx(if kind == "axe" then "bonk" else "slap", hit, if victim then victim.UserId else 0)
	if victim then
		-- the SLAP!/BONK! word is Hands/Fx; this small line just says who
		Popup.show(victim, `{player.DisplayName} {if kind == "axe" then "bonked" else "slapped"} {victim.DisplayName}`, "blame", player)
	end
	HandsService.Slapped:Fire(player, victim, model, kind)
end

-- pushes and doors ---------------------------------------------------------------------------------
local function onPush(player: Player, rawPart: any, rawVel: any)
	if typeof(rawPart) ~= "Instance" or not (rawPart :: Instance):IsA("BasePart") then
		return
	end
	local part = rawPart :: BasePart
	local vel = vec(rawVel)
	if not vel or not part:IsDescendantOf(workspace) or blocked(player) then
		return
	end
	local now = os.clock()
	if now - (lastPush[player] or 0) < HandsConfig.PushCooldown then
		return
	end
	if not Net.near(player, part.Position, HandsConfig.ServerGrabReach) then
		return
	end
	local speed = math.min(vel.Magnitude, HandsConfig.SlapMaxReportedSpeed)
	if CollectionService:HasTag(part, Names.Tag.Door) then
		if speed >= HandsConfig.PushDoorSpeed then
			lastPush[player] = now
			local ok, opened = call("ToolService", "PushDoor", part)
			if ok and opened then
				Telemetry.count("hands_doors_pushed")
			end
		end
		return
	end
	if part.Anchored or forbidden(part) then
		return
	end
	local root = assemblyOf(part)
	local h = held[root]
	if root.Anchored or (h and h.player ~= player and next(h.sides) ~= nil) then
		return
	end
	local dv = HandsMath.push(speed, HandsConfig.PushMinSpeed, HandsConfig.PushPerSpeed, HandsConfig.PushMax)
	if dv <= 0 or vel.Magnitude < 1e-3 then
		return
	end
	lastPush[player] = now
	local ok, res = call("PhysicsFxService", "Impulse", part, vel.Unit * dv, player)
	if not (ok and res ~= false) then
		pcall(function()
			root:ApplyImpulse(vel.Unit * dv * root.AssemblyMass)
		end)
	end
	Telemetry.count("hands_pushes")
end

local function onAxeHit(player: Player, rawDoor: any, rawSpeed: any)
	local door = Net.tagged(rawDoor, Names.Tag.Door)
	if not door or door:GetAttribute(Names.Attr.Broken) == true then
		return
	end
	if type(rawSpeed) ~= "number" or not HandsMath.finite(rawSpeed) then
		return
	end
	if blocked(player) or not holdsAxe(player) then
		return
	end
	local reach = HandsConfig.AxeReach + math.max(door.Size.X, door.Size.Y, door.Size.Z) * 0.5
	if not Net.near(player, door.Position, reach) then
		return
	end
	local now = os.clock()
	if now - (lastAxe[player] or 0) < HandsConfig.AxeHitCooldown then
		return
	end
	lastAxe[player] = now
	local speed = math.clamp(rawSpeed, 0, HandsConfig.AxeMaxSpeed)
	local hits = HandsMath.axeHits(speed, HandsConfig)
	if hits <= 0 then
		Telemetry.count("hands_axe_tonks")
		fx("tonk", door.Position, 0)
		return
	end
	Telemetry.count("hands_axe_hits")
	local ok = call("ToolService", "HitDoor", player, door, hits)
	if not ok then
		call("ToolService", "_doorPrompt", player, door) -- older ToolService: one hit on a locked door
	end
end

-- pose relay ---------------------------------------------------------------------------------------
local function onPose(player: Player, raw: any)
	local l, r, flags = HandsMath.decodePose(raw, HandsConfig.PoseMaxOffset)
	if not (l and r) then
		return
	end
	latest[player] = HandsMath.encodePose(l, r, flags, HandsConfig.PoseMaxOffset)
	dirty[player] = true
end

local function relayLoop()
	while true do
		task.wait(1 / math.max(1, HandsConfig.PoseHz))
		if next(dirty) == nil or not PosesRemote then
			continue
		end
		local flat: { number } = {}
		for player in dirty do
			local pkt = latest[player]
			if pkt and player.Parent then
				table.insert(flat, player.UserId)
				for _, n in pkt do
					table.insert(flat, n)
				end
			end
		end
		table.clear(dirty)
		if #flat > 0 then
			PosesRemote:FireAllClients(flat)
		end
	end
end

-- service ----------------------------------------------------------------------------------------
local function unreliable(folder: Instance, name: string): any
	local found = folder:FindFirstChild(name)
	if found then
		return found
	end
	local r = Instance.new("UnreliableRemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end

function HandsService:Init(all: { [string]: any })
	services = all
end

function HandsService:Start()
	FxRemote = Net.event("Hands", "Fx")
	local releaseRemote = Net.event("Hands", "Release")
	local folder = releaseRemote.Parent :: Instance
	local poseRemote = unreliable(folder, "Pose")
	PosesRemote = unreliable(folder, "Poses")

	Net.onServer(poseRemote :: any, { rate = HandsConfig.PoseHz + 5, burst = 5 }, onPose)
	Net.onServer(releaseRemote, { rate = 10, burst = 6 }, onRelease)
	Net.onServer(Net.event("Hands", "Slap"), { rate = 6, burst = 3 }, onSlap)
	Net.onServer(Net.event("Hands", "Push"), { rate = 10, burst = 4 }, onPush)
	Net.onServer(Net.event("Hands", "AxeHit"), { rate = 6, burst = 2 }, onAxeHit)
	local grab = Net.func("Hands", "Grab")
	grab.OnServerInvoke = function(player: Player, part: any, side: any): any
		local ok, res = pcall(onGrab, player, part, side)
		if not ok then
			warn(`[HandsService] Grab: {res}`)
			return false
		end
		return res
	end

	local function hookPlayer(player: Player)
		player.CharacterRemoving:Connect(function()
			HandsService:ReleaseAll(player)
		end)
		player:GetAttributeChangedSignal(Names.Attr.Downed):Connect(function()
			if player:GetAttribute(Names.Attr.Downed) == true then
				HandsService:ReleaseAll(player)
			end
		end)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		HandsService:ReleaseAll(player)
		latest[player] = nil
		dirty[player] = nil
		lastGrab[player] = nil
		lastPush[player] = nil
		lastAxe[player] = nil
		lastSlap[player] = nil
	end)
	task.spawn(relayLoop)
end

function HandsService:GetHolder(part: BasePart): Player?
	local h = held[assemblyOf(part)]
	return if h and next(h.sides) ~= nil then h.player else nil
end

function HandsService:ReleaseAll(player: Player)
	for root, h in held do
		if h.player == player then
			release(player, root, nil)
		end
	end
end

-- test hooks (DevHook only) ------------------------------------------------------------------------
function HandsService:_grab(player: Player, part: BasePart, side: string): any
	lastGrab[player] = nil
	return onGrab(player, part, side)
end

function HandsService:_slap(player: Player, model: Model, velocity: Vector3, kind: string?)
	slapTimes(player)[model] = nil
	onSlap(player, model, velocity, kind or "hand")
end

function HandsService:_axeHit(player: Player, door: BasePart, speed: number)
	lastAxe[player] = nil
	onAxeHit(player, door, speed)
end

return HandsService
