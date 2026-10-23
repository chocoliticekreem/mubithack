--!strict
-- InventoryService [owner: Inventory]. The physical, goofy inventory that replaces the Roblox backpack
-- (docs/game/08 "Inventory"). Gear is real stuff in the world: station GearRacks, truck compartments,
-- the truck's hose reel, and anything dropped or thrown. Slot rules live in ReplicatedStorage/Lib/Items/
-- ItemDefs (spec-tested); the item looks in Lib/Items/ItemProps.
--
-- Slots: HAND (one held item = a Tool under the character, made by ToolService:CreateTool so spraying
--   and the axe keep working), BACK (one backable item, the oxygen tank by default; a welded model on
--   your back), CARRY (a world prop tagged InventoryConfig.CarryTag held in both arms; NPC carry is
--   RescueService's).
--
-- Public API:
--   InventoryService:Give(player, itemId): boolean      -- a fresh item, by the ItemDefs grab rules
--   InventoryService:Drop(player): boolean              -- G: carried prop first, else the hand item
--   InventoryService:Throw(player, aim: Vector3, charge: number): boolean
--   InventoryService:Swap(player): boolean              -- hand <-> back
--   InventoryService:GetHand(player): string?   GetBack(player): string?
--   InventoryService:Clear(player)                      -- silently empties every slot (no drops)
-- Signals: Changed(player), Bonked(thrower: Player, victim: Player, what: string),
--          Fumbled(player, itemId: string)
-- Remotes: Inventory/Drop (C->S, none, 4/s), Inventory/Throw (C->S, aim: unit Vector3, charge: 0..1, 3/s),
--          Inventory/Swap (C->S, none, 4/s), Inventory/Fx (S->C all, kind: string, pos: Vector3, text: string)
--          kinds: "grab", "drop", "throw", "bonk", "fumble", "supply", "snap", "stow"
-- World (reads): parts tagged GearRack (attr Item, or Slot -> ItemDefs.RackOrder), TruckCompartment
--   (attr Item), TruckRefill (the reel: nozzle), Hydrant (supply line), Truck (attrs OwnerUserId, Water,
--   TankSize), CarryTag props. A truck with no TruckCompartment parts gets its "Locker_*" doors tagged.
-- Writes: Player attrs InvHand, InvBack, InvCarry ("" = empty), OxygenAir, Foam/FoamSize (extinguisher),
--   Water/TankSize (mirrors the hose's truck tank while you hold the nozzle);
--   truck attrs Water, TankSize, SupplyLine (bool); workspace.LooseItems (Models tagged InventoryItem,
--   attr Item); prompts with attr InvPrompt (Style Custom: InventoryController draws them).
-- Calls (nil-guarded): ToolService:CreateTool, ToolService.WaterUsed, HeatService:GetHeat/Cool,
--   Lib/Tools/HoseLine attach/detach, Shared/Ragdoll.
-- Counters: inv_grabs, inv_drops, inv_throws, inv_bonks, inv_fumbles, inv_swaps, inv_hose_out,
--   inv_hose_stowed, inv_supply_lines, inv_supply_snaps, inv_props_carried, inv_restocks
-- Test hooks (DevHook only): _selftest(), _state(player), _give(player, id), _throw(player, charge?),
--   _fumble(player), _reel(player, reel?), _hydrant(player, hydrant)

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
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("InventoryConfig") :: ModuleScript) :: any
local ToolConfig = require(ConfigFolder:WaitForChild("ToolConfig") :: ModuleScript) :: any
local HoseLineConfig = require(ConfigFolder:WaitForChild("HoseLineConfig") :: ModuleScript) :: any
local ItemDefs = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript)
local ItemProps = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemProps") :: ModuleScript)

local InventoryService = {}
InventoryService.Priority = 55
InventoryService.Changed = Signal.new() :: Signal.Signal<Player>
InventoryService.Bonked = Signal.new() :: Signal.Signal<Player, Player, string>
InventoryService.Fumbled = Signal.new() :: Signal.Signal<Player, string>

local TAG_ITEM = "InventoryItem"
local TAG_RACK = "GearRack"
local TAG_COMPARTMENT = "TruckCompartment"
local ATTR_PROMPT = "InvPrompt"

type Data = { foam: number?, air: number?, reel: BasePart? }
type Held = { id: string, data: Data }
type PState = {
	hand: Held?,
	back: Held?,
	carry: Instance?,
	carrySaved: { [BasePart]: { collide: boolean, massless: boolean } }?,
	carryWeld: WeldConstraint?,
	tool: Tool?,
	toolFor: Held?,
	backModel: Model?,
	backFor: Held?,
	lastNotify: number,
}
type Loose = { id: string, data: Data, born: number, rope: RopeConstraint? }
type Flyer = { part: BasePart, thrower: Player, born: number, hit: { [Player]: true }, what: string }
type Supply = { hydrant: BasePart, truck: Model, rope: RopeConstraint, a0: Attachment, a1: Attachment, by: Player }

local services: { [string]: any } = {}
local states: { [Player]: PState } = {}
local loose: { [Model]: Loose } = {}
local looseOrder: { Model } = {}
local reelHolder: { [BasePart]: Player } = {}
local reelLoose: { [BasePart]: Model } = {}
local flyers: { Flyer } = {}
local supplies: { [BasePart]: Supply } = {}
local stockHooked: { [BasePart]: true } = setmetatable({}, { __mode = "k" }) :: any
local promptHooked: { [ProximityPrompt]: true } = setmetatable({}, { __mode = "k" }) :: any
local looseFolder: Folder? = nil
local FxRemote: RemoteEvent? = nil

-- helpers ------------------------------------------------------------------------------------------
local function call(serviceName: string, method: string, ...: any): any
	local svc = services[serviceName]
	local f = svc and svc[method]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, svc, ...)
	if not ok then
		warn(`[InventoryService] {serviceName}:{method} failed: {res}`)
		return nil
	end
	return res
end

local hoseLineCache: any = nil
local function hoseLine(fn: string, ...: any): any
	if not hoseLineCache then
		local lib = ServerScriptService:FindFirstChild("Lib")
		local tools = lib and lib:FindFirstChild("Tools")
		local mod = tools and tools:FindFirstChild("HoseLine")
		if mod and mod:IsA("ModuleScript") then
			local ok, res = pcall(require, mod)
			if ok and type(res) == "table" then
				hoseLineCache = res
			end
		end
	end
	local f = hoseLineCache and hoseLineCache[fn]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, ...)
	return if ok then res else nil
end

local function fx(kind: string, pos: Vector3, text: string?)
	if FxRemote then
		FxRemote:FireAllClients(kind, pos, text or "")
	end
end

local function charOf(player: Player): (Model?, BasePart?, Humanoid?)
	local char = player.Character
	if not char then
		return nil, nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")
	return char, root, hum
end

local function stateOf(player: Player): PState
	local ps = states[player]
	if not ps then
		ps = { lastNotify = 0 }
		states[player] = ps
	end
	return ps :: PState
end

local function ruleState(ps: PState): ItemDefs.State
	return {
		hand = ps.hand and ps.hand.id,
		back = ps.back and ps.back.id,
		carry = if ps.carry then ItemDefs.PROP else nil,
	}
end

local function ctxOf(player: Player): ItemDefs.Ctx
	local carrying = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
	return { downed = player:GetAttribute(Names.Attr.Downed) == true, carryingNpc = carrying ~= "" }
end

local REASONS = {
	downed = "You're down! Can't grab that",
	["arms full"] = "Your arms are full! (G to drop)",
	["already holding"] = "You're already holding the hose",
	["not backable"] = "That won't fit on your back",
}

local function say(player: Player, ps: PState, text: string, kind: string?)
	local now = os.clock()
	if now - ps.lastNotify < 0.8 then
		return
	end
	ps.lastNotify = now
	Net.notify(player, text, kind or "info")
end

local function fresh(id: string): Data
	if id == "Extinguisher" then
		return { foam = ToolConfig.FoamSize }
	elseif id == "OxygenTank" then
		return { air = Cfg.OxygenAir }
	end
	return {}
end

local function displayName(id: string): string
	local def = ItemDefs.get(id)
	return if def then def.name else id
end

-- trucks, tanks and reels ----------------------------------------------------------------------------
local function truckOf(inst: Instance?): Model?
	local cur = inst
	while cur and cur ~= workspace do
		if cur:IsA("Model") and cur:HasTag(Names.Tag.Truck) then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

-- The water tank behind a reel: its truck, else the reel part itself.
local function tankOf(reel: BasePart): Instance
	return truckOf(reel) or reel
end

local function ensureTank(tank: Instance)
	if type(tank:GetAttribute(Names.Attr.TankSize)) ~= "number" then
		tank:SetAttribute(Names.Attr.TankSize, Cfg.TruckTankSize)
	end
	if type(tank:GetAttribute(Names.Attr.Water)) ~= "number" then
		tank:SetAttribute(Names.Attr.Water, tank:GetAttribute(Names.Attr.TankSize))
	end
end

local function reelOfTruck(truck: Model): BasePart?
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(Names.Tag.TruckRefill) then
			return d
		end
	end
	return nil
end

local function ownedTruck(player: Player): Model?
	for _, t in CollectionService:GetTagged(Names.Tag.Truck) do
		if t:IsA("Model") and t:GetAttribute("OwnerUserId") == player.UserId and t:IsDescendantOf(workspace) then
			return t
		end
	end
	return nil
end

-- While a player holds a nozzle, their Water/TankSize attrs mirror the truck tank (ToolService and the
-- HUD read those).
local function mirrorWater(player: Player)
	local ps = states[player]
	local held = ps and ps.hand
	local reel = held and held.id == "Hose" and held.data.reel
	if not reel then
		return
	end
	local tank = tankOf(reel)
	ensureTank(tank)
	player:SetAttribute(Names.Attr.TankSize, tank:GetAttribute(Names.Attr.TankSize))
	player:SetAttribute(Names.Attr.Water, tank:GetAttribute(Names.Attr.Water))
end

local function mirrorTank(tank: Instance)
	for player, ps in states do
		local held = ps.hand
		if held and held.id == "Hose" and held.data.reel and tankOf(held.data.reel) == tank then
			mirrorWater(player)
		end
	end
end

-- prompts ------------------------------------------------------------------------------------------
local function invPrompt(parent: Instance, action: string, object: string, dist: number): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = "InvPrompt"
	p.ActionText = action
	p.ObjectText = object
	p.HoldDuration = 0
	p.MaxActivationDistance = dist
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom
	p:SetAttribute(ATTR_PROMPT, true)
	p.Parent = parent
	return p
end

-- loose items --------------------------------------------------------------------------------------
local giveHeld: (player: Player, held: Held) -> (boolean, ItemDefs.Plan?)
local removeLoose: (m: Model) -> ()

local function folder(): Folder
	local f = looseFolder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "LooseItems"
	nf.Parent = workspace
	looseFolder = nf
	return nf
end

local function reelAttachment(reel: BasePart): Attachment
	local a = reel:FindFirstChild("InvReelAtt") :: Attachment?
	if a then
		return a
	end
	local na = Instance.new("Attachment")
	na.Name = "InvReelAtt"
	na.Parent = reel
	return na
end

local function hoseLength(reel: BasePart): number
	return tonumber(reel:GetAttribute("HoseLength")) or HoseLineConfig.LengthTruck
end

local function addFlyer(part: BasePart, thrower: Player, what: string)
	table.insert(flyers, { part = part, thrower = thrower, born = os.clock(), hit = {}, what = what })
end

removeLoose = function(m: Model)
	local info = loose[m]
	loose[m] = nil
	local i = table.find(looseOrder, m)
	if i then
		table.remove(looseOrder, i)
	end
	if info and info.data.reel and reelLoose[info.data.reel] == m then
		reelLoose[info.data.reel] = nil
	end
	m:Destroy()
end

local function grabLoose(player: Player, m: Model)
	local info = loose[m]
	local handle = m.PrimaryPart
	if not info or not handle then
		return
	end
	if not Net.near(player, handle.Position, Cfg.GrabDistance + 4) then
		return
	end
	local held: Held = { id = info.id, data = info.data }
	local reel = info.data.reel
	if reel and not reel:IsDescendantOf(workspace) then
		held.data = {} -- the truck is gone: just a loose nozzle now
	end
	local ok = giveHeld(player, held)
	if ok then
		removeLoose(m)
		Telemetry.count("inv_grabs")
		fx("grab", handle.Position, displayName(info.id))
	end
end

local function spawnLoose(held: Held, cf: CFrame, velocity: Vector3, thrower: Player?): Model?
	local def = ItemDefs.get(held.id)
	if not def then
		return nil
	end
	-- cap: recycle the oldest loose item (never a tethered nozzle if anything else can go)
	while #looseOrder >= Cfg.MaxLooseItems do
		local victim = looseOrder[1]
		for _, m in looseOrder do
			if not (loose[m] and loose[m].data.reel) then
				victim = m
				break
			end
		end
		removeLoose(victim)
	end
	local m = ItemProps.build(held.id, "world", 1.15)
	m.Name = `Loose_{held.id}`
	m:PivotTo(cf)
	m:AddTag(TAG_ITEM)
	local handle = m.PrimaryPart :: BasePart
	local prompt = invPrompt(handle, `Grab {def.name}`, "", Cfg.GrabDistance)
	m.Parent = folder()
	local info: Loose = { id = held.id, data = held.data, born = os.clock() }
	loose[m] = info
	table.insert(looseOrder, m)
	local reel = held.data.reel
	if reel and reel:IsDescendantOf(workspace) then
		local hoseEnd = handle:FindFirstChild("HoseEnd") :: Attachment?
		if hoseEnd then
			local rope = Instance.new("RopeConstraint")
			rope.Name = "HoseTether"
			rope.Attachment0 = reelAttachment(reel)
			rope.Attachment1 = hoseEnd
			rope.Length = hoseLength(reel)
			rope.Visible = true
			rope.Thickness = 0.45
			rope.Color = BrickColor.new("Bright yellow")
			rope.Parent = handle
			info.rope = rope
		end
		reelLoose[reel] = m
	end
	pcall(function()
		handle:SetNetworkOwner(nil)
	end)
	handle.AssemblyLinearVelocity = velocity
	if thrower then
		local r = Random.new()
		handle.AssemblyAngularVelocity = Vector3.new(r:NextNumber(-1, 1), r:NextNumber(-1, 1), r:NextNumber(-1, 1)) * Cfg.ThrowSpin
		addFlyer(handle, thrower, def.name)
	end
	prompt.Triggered:Connect(function(player: Player)
		grabLoose(player, m)
	end)
	return m
end

-- slots -> world -----------------------------------------------------------------------------------
-- Saves state that lives on the player while an item is held (extinguisher foam) back into the item.
local function syncHeld(player: Player, ps: PState)
	local hand = ps.hand
	if hand and hand.id == "Extinguisher" then
		hand.data.foam = (player:GetAttribute("Foam") :: number?) or hand.data.foam
	end
end

local function releaseHose(player: Player, held: Held?)
	local reel = held and held.id == "Hose" and held.data.reel
	if reel and reelHolder[reel] == player then
		reelHolder[reel] = nil
	end
	if held and held.id == "Hose" then
		hoseLine("detach", player)
		player:SetAttribute(Names.Attr.Spraying, false)
	end
end

local function equipHand(player: Player, ps: PState)
	if ps.toolFor == ps.hand and (ps.tool == nil or ps.tool.Parent ~= nil) then
		return
	end
	local old = ps.toolFor
	if ps.tool then
		local t = ps.tool
		ps.tool = nil
		t:Destroy()
	end
	if old and old ~= ps.hand then
		releaseHose(player, old)
	end
	ps.toolFor = ps.hand
	local held = ps.hand
	local char = player.Character
	if not held or not char then
		return
	end
	local def = ItemDefs.get(held.id)
	local tool: Tool? = nil
	if def and def.tool then
		local made = call("ToolService", "CreateTool", held.id, player)
		if typeof(made) == "Instance" and (made :: Instance):IsA("Tool") then
			tool = made :: Tool
		end
	end
	local t = tool or ItemProps.tool(held.id)
	t:SetAttribute("InvItem", held.id)
	ps.tool = t
	t.Parent = char
	if held.id == "Extinguisher" then
		player:SetAttribute("FoamSize", ToolConfig.FoamSize)
		player:SetAttribute("Foam", held.data.foam or ToolConfig.FoamSize)
	elseif held.id == "Hose" then
		local reel = held.data.reel
		if reel and reel:IsDescendantOf(workspace) then
			reelHolder[reel] = player
			mirrorWater(player)
			if not hoseLine("attach", player, reel) then
				Net.notify(player, "The hose is tangled up, try again", "info")
			end
		elseif type(player:GetAttribute(Names.Attr.Water)) ~= "number" then
			-- a loose nozzle with no truck behind it (Give without a truck): the old personal tank
			player:SetAttribute(Names.Attr.TankSize, ToolConfig.TankSize)
			player:SetAttribute(Names.Attr.Water, ToolConfig.TankSize)
		end
	end
end

local BACK_TILT: { [string]: CFrame } = {
	Axe = CFrame.Angles(0, math.rad(90), math.rad(35)),
	Extinguisher = CFrame.Angles(0, 0, math.rad(-12)),
	OxygenTank = CFrame.new(),
}

local function equipBack(player: Player, ps: PState)
	if ps.backFor == ps.back and (ps.backModel == nil or ps.backModel.Parent ~= nil) then
		return
	end
	if ps.backModel then
		ps.backModel:Destroy()
		ps.backModel = nil
	end
	ps.backFor = ps.back
	local held = ps.back
	local char = player.Character
	local torso = char and (char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")) :: BasePart?
	if not held or not char or not torso then
		return
	end
	local m = ItemProps.build(held.id, "back", 0.85)
	m.Name = "InvBack"
	m:PivotTo(torso.CFrame * CFrame.new(0, 0.1, torso.Size.Z / 2 + 0.6) * (BACK_TILT[held.id] or CFrame.new()))
	local w = Instance.new("WeldConstraint")
	w.Part0 = torso
	w.Part1 = m.PrimaryPart
	w.Parent = m
	m.Parent = char
	ps.backModel = m
end

local function writeAttrs(player: Player, ps: PState)
	player:SetAttribute("InvHand", if ps.hand then ps.hand.id else "")
	player:SetAttribute("InvBack", if ps.back then ps.back.id else "")
	player:SetAttribute("InvCarry", if ps.carry then ps.carry.Name else "")
	local o2 = if ps.back and ps.back.id == "OxygenTank" then ps.back else (if ps.hand and ps.hand.id == "OxygenTank" then ps.hand else nil)
	player:SetAttribute("OxygenAir", if o2 then o2.data.air or 0 else nil)
end

local function apply(player: Player, ps: PState)
	equipHand(player, ps)
	equipBack(player, ps)
	writeAttrs(player, ps)
	InventoryService.Changed:Fire(player)
end

local function feetCFrame(player: Player): CFrame?
	local _, root = charOf(player)
	if not root then
		return nil
	end
	local look = root.CFrame.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	flat = if flat.Magnitude > 1e-3 then flat.Unit else Vector3.new(0, 0, -1)
	return CFrame.new(root.Position + flat * Cfg.DropForward + Vector3.new(0, -1.2, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, math.rad(80))
end

local function dropHeldAt(player: Player, held: Held, cf: CFrame?, velocity: Vector3, thrower: Player?): Model?
	local at = cf or feetCFrame(player)
	if not at then
		return nil
	end
	return spawnLoose(held, at, velocity, thrower)
end

giveHeld = function(player: Player, held: Held): (boolean, ItemDefs.Plan?)
	local ps = stateOf(player)
	syncHeld(player, ps)
	local ok, _, plan = ItemDefs.grab(ruleState(ps), held.id, ctxOf(player))
	if not ok then
		local reason = plan.reason or ""
		if REASONS[reason] then
			say(player, ps, REASONS[reason])
		end
		return false, plan
	end
	local oldHand = ps.hand
	if plan.slot == "back" then
		ps.back = held
	else
		if plan.stowed then
			ps.back = oldHand
		end
		ps.hand = held
	end
	apply(player, ps)
	if plan.dropped and oldHand then
		dropHeldAt(player, oldHand, nil, Vector3.new(0, 6, 0), nil)
		say(player, ps, `Juggled! You dropped the {displayName(oldHand.id)}`)
	end
	return true, plan
end

-- carry (props) ------------------------------------------------------------------------------------
local function propRoot(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function propParts(inst: Instance): { BasePart }
	local list: { BasePart } = {}
	if inst:IsA("BasePart") then
		table.insert(list, inst)
	end
	for _, d in inst:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(list, d)
		end
	end
	return list
end

local function promptOf(inst: Instance): ProximityPrompt?
	for _, d in inst:GetDescendants() do
		if d:IsA("ProximityPrompt") and d:GetAttribute(ATTR_PROMPT) then
			return d
		end
	end
	return nil
end

local function pickupProp(player: Player, inst: Instance)
	local ps = stateOf(player)
	local root = propRoot(inst)
	local _, hrp = charOf(player)
	if not root or not hrp or root.Anchored or not inst:IsDescendantOf(workspace) then
		return
	end
	if not Net.near(player, root.Position, Cfg.PropGrabDistance + 4) then
		return
	end
	for _, other in states do
		if other.carry == inst then
			return -- someone else already has it
		end
	end
	if root.AssemblyMass > Cfg.CarryMaxMass then
		say(player, ps, `The {inst.Name} is way too heavy!`)
		return
	end
	local ok, _, why = ItemDefs.grabProp(ruleState(ps), ctxOf(player))
	if not ok then
		say(player, ps, REASONS[why or ""] or "Can't pick that up")
		return
	end
	local saved = {}
	for _, p in propParts(inst) do
		saved[p] = { collide = p.CanCollide, massless = p.Massless }
		p.CanCollide = false
		p.Massless = true
	end
	local target = hrp.CFrame * CFrame.new(Cfg.CarryOffset)
	if inst:IsA("Model") then
		inst:PivotTo(target)
	else
		root.CFrame = target
	end
	local w = Instance.new("WeldConstraint")
	w.Name = "InvCarryWeld"
	w.Part0 = hrp
	w.Part1 = root
	w.Parent = root
	ps.carry = inst
	ps.carrySaved = saved
	ps.carryWeld = w
	local prompt = promptOf(inst)
	if prompt then
		prompt.Enabled = false
	end
	Telemetry.count("inv_props_carried")
	fx("grab", root.Position, inst.Name)
	writeAttrs(player, ps)
	InventoryService.Changed:Fire(player)
end

local function releaseProp(player: Player, ps: PState, velocity: Vector3, thrower: Player?)
	local inst = ps.carry
	ps.carry = nil
	if ps.carryWeld then
		ps.carryWeld:Destroy()
		ps.carryWeld = nil
	end
	local saved = ps.carrySaved or {}
	ps.carrySaved = nil
	writeAttrs(player, ps)
	InventoryService.Changed:Fire(player)
	if not inst or not inst.Parent then
		return
	end
	for p, s in saved do
		if p.Parent then
			p.CanCollide = s.collide
			p.Massless = s.massless
		end
	end
	local root = propRoot(inst)
	if root then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
		root.AssemblyLinearVelocity = velocity
		if thrower then
			addFlyer(root, thrower, inst.Name)
		end
		task.delay(3, function()
			if root.Parent and not root.Anchored then
				pcall(function()
					root:SetNetworkOwnershipAuto()
				end)
			end
		end)
	end
	local prompt = promptOf(inst)
	if prompt then
		prompt.Enabled = true
	end
end

-- drop / throw / swap / fumble ---------------------------------------------------------------------
local function doDrop(player: Player): boolean
	local ps = stateOf(player)
	syncHeld(player, ps)
	local _, what, slot = ItemDefs.drop(ruleState(ps))
	local _, root = charOf(player)
	local fwd = if root then root.CFrame.LookVector * 4 else Vector3.zero
	if slot == "carry" then
		releaseProp(player, ps, fwd + Vector3.new(0, 3, 0), nil)
	elseif slot == "hand" and ps.hand then
		local held = ps.hand
		ps.hand = nil
		apply(player, ps)
		dropHeldAt(player, held, nil, fwd + Vector3.new(0, 4, 0), nil)
	else
		return false
	end
	Telemetry.count("inv_drops")
	if root then
		fx("drop", root.Position, if slot == "carry" then "" else displayName(what or ""))
	end
	return true
end

local function doThrow(player: Player, aim: Vector3, charge: number): boolean
	local ps = stateOf(player)
	syncHeld(player, ps)
	local char, root = charOf(player)
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not root or not head then
		return false
	end
	if player:GetAttribute(Names.Attr.Downed) == true or Ragdoll.isRagdolled(char :: Model) then
		return false
	end
	local _, what, slot = ItemDefs.throw(ruleState(ps))
	if not slot then
		return false
	end
	local speed = ItemDefs.throwSpeed(charge, Cfg.ThrowMinSpeed, Cfg.ThrowMaxSpeed)
	local vel = aim * speed + Vector3.new(0, Cfg.ThrowLift, 0) + root.AssemblyLinearVelocity * 0.5
	-- spawn in front of the face, but never through a wall
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char :: Model, folder() }
	local hit = workspace:Raycast(head.Position, aim * 2.8, rp)
	local at = if hit then hit.Position - aim * 1.2 else head.Position + aim * 2.8
	if slot == "carry" then
		local inst = ps.carry
		releaseProp(player, ps, vel, player)
		local r = inst and propRoot(inst)
		if r then
			r.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * Cfg.ThrowSpin
		end
	elseif ps.hand then
		local held = ps.hand
		ps.hand = nil
		apply(player, ps)
		spawnLoose(held, CFrame.lookAt(at, at + aim), vel, player)
	end
	Telemetry.count("inv_throws")
	fx("throw", at, if slot == "carry" then "" else displayName(what or ""))
	return true
end

local function doSwap(player: Player): boolean
	local ps = stateOf(player)
	syncHeld(player, ps)
	local ok, _, why = ItemDefs.swap(ruleState(ps))
	if not ok then
		if why and REASONS[why] then
			say(player, ps, REASONS[why])
		end
		return false
	end
	ps.hand, ps.back = ps.back, ps.hand
	apply(player, ps)
	Telemetry.count("inv_swaps")
	return true
end

local function scatter(): Vector3
	local r = Random.new()
	local a = r:NextNumber(0, math.pi * 2)
	return Vector3.new(math.cos(a) * Cfg.FumbleSpeed, Cfg.FumbleSpeed * 0.9, math.sin(a) * Cfg.FumbleSpeed)
end

local function fumble(player: Player)
	local ps = stateOf(player)
	syncHeld(player, ps)
	if not ps.hand and not ps.carry then
		return
	end
	local char, root = charOf(player)
	local handPos = root and root.Position + Vector3.new(0, 1, 0)
	local rh = char and (char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")) :: BasePart?
	if rh then
		handPos = rh.Position
	end
	if ps.carry then
		releaseProp(player, ps, scatter(), nil)
	end
	local held = ps.hand
	if held then
		ps.hand = nil
		apply(player, ps)
		local cf = if handPos then CFrame.new(handPos) else nil
		dropHeldAt(player, held, cf, scatter(), nil)
		Telemetry.count("inv_fumbles")
		InventoryService.Fumbled:Fire(player, held.id)
		say(player, ps, `Butterfingers! You fumbled the {displayName(held.id)}`, "blame")
		if handPos then
			fx("fumble", handPos, displayName(held.id))
		end
	end
end

-- Death: everything you had spills on the floor.
local function spill(player: Player)
	local ps = stateOf(player)
	syncHeld(player, ps)
	if ps.carry then
		releaseProp(player, ps, scatter(), nil)
	end
	local list = { ps.hand, ps.back }
	ps.hand, ps.back = nil, nil
	apply(player, ps)
	for _, held in list do
		if held then
			dropHeldAt(player, held, nil, scatter(), nil)
		end
	end
end

-- bonks --------------------------------------------------------------------------------------------
local function bonkTick()
	if #flyers == 0 then
		return
	end
	local now = os.clock()
	for i = #flyers, 1, -1 do
		local f = flyers[i]
		if now - f.born > Cfg.BonkSeconds or not f.part.Parent then
			table.remove(flyers, i)
			continue
		end
		local v = f.part.AssemblyLinearVelocity
		if not ItemDefs.bonkSpeed(v.Magnitude, Cfg.BonkMinSpeed) or now - f.born < 0.05 then
			continue
		end
		local reach = 2.2 + f.part.Size.Magnitude / 2
		for _, victim in Players:GetPlayers() do
			if victim == f.thrower or f.hit[victim] then
				continue
			end
			local vchar, vroot = charOf(victim)
			if not vchar or not vroot or (vroot.Position - f.part.Position).Magnitude > reach then
				continue
			end
			f.hit[victim] = true
			local flat = Vector3.new(v.X, 0, v.Z)
			local dir = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
			pcall(Ragdoll.enable, vchar :: Model, Cfg.BonkRagdollSeconds)
			pcall(Ragdoll.knockback, vchar :: Model, dir * Cfg.BonkPush + Vector3.new(0, Cfg.BonkLift, 0))
			f.part.AssemblyLinearVelocity = -v * 0.3 + Vector3.new(0, 12, 0) -- cartoon rebound
			Telemetry.count("inv_bonks")
			fx("bonk", vroot.Position + Vector3.new(0, 2.5, 0), f.what)
			InventoryService.Bonked:Fire(f.thrower, victim, f.what)
			Net.notify(victim, `BONK! {f.thrower.DisplayName} beaned you with the {f.what}`, "blame")
			Net.notify(f.thrower, `BONK! You beaned {victim.DisplayName} with the {f.what}`, "blame")
		end
	end
end

-- racks and compartments ---------------------------------------------------------------------------
local function outwardCFrame(part: BasePart, kind: string): CFrame
	local truck = if kind == TAG_COMPARTMENT then truckOf(part) else nil
	if truck then
		local pivot = truck:GetPivot()
		local rel = pivot:PointToObjectSpace(part.Position)
		local out = pivot.RightVector * (if rel.X >= 0 then 1 else -1)
		local pos = part.Position + out * 0.75
		return CFrame.lookAt(pos, pos + out)
	end
	local offset = part:GetAttribute("DisplayOffset")
	if typeof(offset) == "Vector3" then
		return part.CFrame * CFrame.new(offset)
	end
	return part.CFrame * CFrame.new(0, 0, -(part.Size.Z / 2 + 0.6))
end

local function onStock(player: Player, part: BasePart, prompt: ProximityPrompt, display: Model?)
	if part:GetAttribute("Stocked") == false or not prompt.Enabled then
		return
	end
	local id = ItemDefs.rackItem(part:GetAttribute("Item") :: string?, part:GetAttribute(Names.Attr.Slot) :: number?)
	if not id or not Net.near(player, part.Position, Cfg.GrabDistance + 6) then
		return
	end
	local ok = giveHeld(player, { id = id, data = fresh(id) })
	if not ok then
		return
	end
	Telemetry.count("inv_grabs")
	fx("grab", part.Position, displayName(id))
	part:SetAttribute("Stocked", false)
	prompt.Enabled = false
	local saved: { [BasePart]: number } = {}
	if display then
		for _, p in display:GetDescendants() do
			if p:IsA("BasePart") then
				saved[p] = p.Transparency
				p.Transparency = 1
			end
		end
	end
	task.delay(Cfg.RestockSeconds, function()
		if not part.Parent then
			return
		end
		part:SetAttribute("Stocked", true)
		prompt.Enabled = true
		for p, t in saved do
			if p.Parent then
				p.Transparency = t
			end
		end
		Telemetry.count("inv_restocks")
	end)
end

local function hookStock(inst: Instance, kind: string)
	if not inst:IsA("BasePart") or stockHooked[inst] or not inst:IsDescendantOf(workspace) then
		return
	end
	local part = inst :: BasePart
	local id = ItemDefs.rackItem(part:GetAttribute("Item") :: string?, part:GetAttribute(Names.Attr.Slot) :: number?)
	if not id then
		return
	end
	stockHooked[part] = true
	local display: Model? = part:FindFirstChild("InvDisplay") :: Model?
	if not display and part:GetAttribute("ShowItem") ~= false then
		local m = ItemProps.build(id, "display", 0.85)
		m.Name = "InvDisplay"
		m:PivotTo(outwardCFrame(part, kind))
		local w = Instance.new("WeldConstraint")
		w.Part0 = part
		w.Part1 = m.PrimaryPart
		w.Parent = m
		m.Parent = part
		display = m
	end
	local prompt = invPrompt(part, `Grab {displayName(id)}`, if kind == TAG_COMPARTMENT then "Truck" else "Gear Rack", Cfg.GrabDistance)
	part:SetAttribute("Stocked", true)
	prompt.Triggered:Connect(function(player: Player)
		onStock(player, part, prompt, display)
	end)
end

-- A truck with no TruckCompartment parts: its side lockers become compartments.
local function setupTruck(truck: Instance)
	if not truck:IsA("Model") or not truck:IsDescendantOf(workspace) then
		return
	end
	ensureTank(truck)
	truck:GetAttributeChangedSignal(Names.Attr.Water):Connect(function()
		mirrorTank(truck)
	end)
	local lockers: { BasePart } = {}
	for _, d in truck:GetDescendants() do
		if d:IsA("BasePart") and d:HasTag(TAG_COMPARTMENT) then
			return
		end
		if d:IsA("BasePart") and string.match(d.Name, "^Locker_") then
			table.insert(lockers, d)
		end
	end
	table.sort(lockers, function(a: BasePart, b: BasePart): boolean
		return a.Name < b.Name
	end)
	for i, p in lockers do
		if p:GetAttribute("Item") == nil then
			p:SetAttribute("Item", ItemDefs.RackOrder[((i - 1) % #ItemDefs.RackOrder) + 1])
		end
		p:AddTag(TAG_COMPARTMENT) -- hookStock runs from the tag signal
	end
end

-- the reel: nozzle out, nozzle back, foam refill --------------------------------------------------
local function onReel(player: Player, reel: BasePart)
	local ps = stateOf(player)
	syncHeld(player, ps)
	if not Net.near(player, reel.Position, Cfg.ReelReturnDistance + 4) then
		return
	end
	local hand = ps.hand
	if hand and hand.id == "Hose" and (hand.data.reel == reel or hand.data.reel == nil) then
		ps.hand = nil
		apply(player, ps)
		Telemetry.count("inv_hose_stowed")
		fx("stow", reel.Position, "Hose")
		say(player, ps, "Hose back on the reel")
		return
	end
	if hand and hand.id == "Extinguisher" then
		hand.data.foam = ToolConfig.FoamSize
		player:SetAttribute("FoamSize", ToolConfig.FoamSize)
		player:SetAttribute("Foam", ToolConfig.FoamSize)
		say(player, ps, "Extinguisher refilled!", "good")
		return
	end
	local truck = truckOf(reel)
	local owner = truck and truck:GetAttribute("OwnerUserId")
	if not ItemDefs.canUseReel(if type(owner) == "number" then owner else nil, player.UserId) then
		local who = Players:GetPlayerByUserId(owner :: number)
		local bay = who and who:GetAttribute(Names.Attr.Helmet)
		say(player, ps, `That's {if who then who.DisplayName else "someone"}'s truck! Use your own{if bay then ` (bay {bay})` else ""}`)
		return
	end
	local holder = reelHolder[reel]
	if holder and holder ~= player and holder.Parent then
		say(player, ps, `{holder.DisplayName} has this hose!`)
		return
	end
	local lying = reelLoose[reel]
	local ok = giveHeld(player, { id = "Hose", data = { reel = reel } })
	if ok then
		if lying then
			removeLoose(lying)
		end
		Telemetry.count("inv_hose_out")
		fx("grab", reel.Position, "Hose")
	end
end

local function hookReel(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	local reel = inst :: BasePart
	local prompt = reel:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.HoldDuration = 0.2
		prompt.MaxActivationDistance = 10
		prompt.RequiresLineOfSight = false
		prompt.ObjectText = "Hose reel"
		prompt.Parent = reel
	end
	local p = prompt :: ProximityPrompt
	if promptHooked[p] then
		return
	end
	promptHooked[p] = true
	p.ActionText = "Grab Hose"
	p:SetAttribute("InvReel", true) -- InventoryController relabels it locally (Stow Hose / Refill Foam)
	p.Triggered:Connect(function(player: Player)
		onReel(player, reel)
	end)
end

-- hydrant supply lines -----------------------------------------------------------------------------
local function disconnectSupply(hydrant: BasePart, text: string?, snapped: boolean?)
	local s = supplies[hydrant]
	if not s then
		return
	end
	supplies[hydrant] = nil
	s.rope:Destroy()
	s.a0:Destroy()
	s.a1:Destroy()
	if s.truck.Parent then
		s.truck:SetAttribute("SupplyLine", false)
	end
	if snapped then
		Telemetry.count("inv_supply_snaps")
		if hydrant.Parent then
			fx("snap", hydrant.Position, "")
		end
	end
	if text and s.by.Parent then
		Net.notify(s.by, text, if snapped then "bad" else "info")
	end
end

local function pickTruck(player: Player, hydrant: BasePart): Model?
	local best: Model?, bestD = nil, Cfg.SupplyLength
	local own = ownedTruck(player)
	if own then
		local d = (own:GetPivot().Position - hydrant.Position).Magnitude
		return if d <= Cfg.SupplyLength then own else nil
	end
	for _, t in CollectionService:GetTagged(Names.Tag.Truck) do
		if t:IsA("Model") and t:IsDescendantOf(workspace) then
			local owner = t:GetAttribute("OwnerUserId")
			if ItemDefs.canUseReel(if type(owner) == "number" then owner else nil, player.UserId) then
				local d = (t:GetPivot().Position - hydrant.Position).Magnitude
				if d <= bestD then
					best, bestD = t, d
				end
			end
		end
	end
	return best
end

local function onHydrant(player: Player, hydrant: BasePart)
	local ps = stateOf(player)
	if not Net.near(player, hydrant.Position, 14) then
		return
	end
	if supplies[hydrant] then
		disconnectSupply(hydrant, "Supply line disconnected")
		return
	end
	local truck = pickTruck(player, hydrant)
	if not truck then
		say(player, ps, `Park your truck within {Cfg.SupplyLength} studs of the hydrant first!`)
		return
	end
	for h, s in supplies do
		if s.truck == truck then
			disconnectSupply(h, nil)
		end
	end
	local anchorPart = reelOfTruck(truck) or truck.PrimaryPart
	if not anchorPart then
		return
	end
	ensureTank(truck)
	local a0 = Instance.new("Attachment")
	a0.Name = "InvSupplyA"
	a0.Parent = hydrant
	local a1 = Instance.new("Attachment")
	a1.Name = "InvSupplyB"
	a1.Parent = anchorPart
	local rope = Instance.new("RopeConstraint")
	rope.Name = "SupplyLine"
	rope.Attachment0 = a0
	rope.Attachment1 = a1
	-- slack past the snap distance, so a truck driving off pops the line instead of being leashed
	rope.Length = Cfg.SupplyLength * Cfg.SupplySnapFactor + 2
	rope.Visible = true
	rope.Thickness = 0.5
	rope.Color = BrickColor.new("Bright yellow")
	rope.Parent = hydrant
	supplies[hydrant] = { hydrant = hydrant, truck = truck, rope = rope, a0 = a0, a1 = a1, by = player }
	truck:SetAttribute("SupplyLine", true)
	Telemetry.count("inv_supply_lines")
	fx("supply", hydrant.Position, "")
	Net.notify(player, "Supply line connected! Filling the truck tank", "good")
end

local function hookHydrant(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	local hydrant = inst :: BasePart
	local prompt = hydrant:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		return
	end
	local p = prompt :: ProximityPrompt
	if promptHooked[p] then
		return
	end
	promptHooked[p] = true
	p.ActionText = "Supply line"
	p:SetAttribute("InvHydrant", true)
	p.Triggered:Connect(function(player: Player)
		onHydrant(player, hydrant)
	end)
end

local function supplyLoop()
	while true do
		local dt = 1 / math.max(1, Cfg.SupplyTickHz)
		task.wait(dt)
		for hydrant, s in supplies do
			if not hydrant:IsDescendantOf(workspace) or not s.truck:IsDescendantOf(workspace) or not s.a1.Parent then
				disconnectSupply(hydrant, nil)
				continue
			end
			local dist = (s.a0.WorldPosition - s.a1.WorldPosition).Magnitude
			if ItemDefs.supplyState(dist, Cfg.SupplyLength, Cfg.SupplySnapFactor) == "snap" then
				disconnectSupply(hydrant, "POP! The supply line ripped off the hydrant", true)
				continue
			end
			local size = (s.truck:GetAttribute(Names.Attr.TankSize) :: number?) or Cfg.TruckTankSize
			local water = (s.truck:GetAttribute(Names.Attr.Water) :: number?) or 0
			if water < size then
				s.truck:SetAttribute(Names.Attr.Water, ItemDefs.supplyStep(water, size, Cfg.SupplyRate, dt))
			end
		end
	end
end

-- carry props hook ---------------------------------------------------------------------------------
local function hookCarryable(inst: Instance)
	local root = propRoot(inst)
	if not root or promptOf(inst) then
		return
	end
	local prompt = invPrompt(root, `Pick up {inst.Name}`, "", Cfg.PropGrabDistance)
	prompt:SetAttribute("InvCarry", true)
	prompt.Triggered:Connect(function(player: Player)
		pickupProp(player, inst)
	end)
end

-- water, oxygen, upkeep ----------------------------------------------------------------------------
local function onWaterUsed(player: Player, litres: number)
	local ps = states[player]
	local held = ps and ps.hand
	local reel = held and held.id == "Hose" and held.data.reel
	if not reel then
		return
	end
	local tank = tankOf(reel)
	ensureTank(tank)
	local water = (tank:GetAttribute(Names.Attr.Water) :: number?) or 0
	local left = ItemDefs.drawWater(water, litres)
	tank:SetAttribute(Names.Attr.Water, left)
	mirrorTank(tank)
	if left <= 0 and water > 0 and ps then
		say(player, ps, "Truck tank empty! Hook a hydrant up to the truck", "bad")
	end
end

local function oxygenTick()
	for player, ps in states do
		local tank = ps.back
		if not tank or tank.id ~= "OxygenTank" then
			continue
		end
		local air = tank.data.air or 0
		if air <= 0 then
			continue
		end
		local heat = tonumber(call("HeatService", "GetHeat", player)) or 0
		if heat > Cfg.OxygenMinHeat then
			call("HeatService", "Cool", player, Cfg.OxygenCool, nil)
			tank.data.air = math.max(0, air - 1)
			player:SetAttribute("OxygenAir", tank.data.air)
			if tank.data.air <= 0 then
				Net.notify(player, "Your oxygen tank ran dry!", "bad")
			end
		end
	end
end

local function upkeepLoop()
	while true do
		task.wait(1)
		oxygenTick()
		local now = os.clock()
		for i = #looseOrder, 1, -1 do
			local m = looseOrder[i]
			local info = loose[m]
			local handle = m.PrimaryPart
			if not info or not m.Parent or not handle or not handle.Parent then
				removeLoose(m)
				continue
			end
			local reel = info.data.reel
			local tooOld = now - info.born > Cfg.LooseSeconds
			local stray = reel ~= nil and (not reel:IsDescendantOf(workspace) or (reel.Position - handle.Position).Magnitude > hoseLength(reel) * 2.5)
			if tooOld or stray then
				removeLoose(m)
			end
		end
	end
end

-- players ------------------------------------------------------------------------------------------
local function hookCharacter(player: Player, char: Model)
	local ps = stateOf(player)
	-- Death already spilled the old kit; a respawn without dying (LoadCharacter) keeps it on the new body.
	if ps.carry then
		releaseProp(player, ps, Vector3.zero, nil)
	end
	ps.tool, ps.toolFor, ps.backModel, ps.backFor = nil, nil, nil, nil
	char:WaitForChild("HumanoidRootPart", 10)
	apply(player, ps)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		hum.Died:Connect(function()
			if player.Character == char then
				spill(player)
			end
		end)
	end
	char:GetAttributeChangedSignal(Names.Attr.Ragdolled):Connect(function()
		if char:GetAttribute(Names.Attr.Ragdolled) == true and player.Character == char then
			fumble(player)
		end
	end)
end

local function hookPlayer(player: Player)
	stateOf(player)
	player.CharacterAdded:Connect(function(char: Model)
		hookCharacter(player, char)
	end)
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end
	-- carrying an NPC (RescueService) takes both arms: a carried prop falls
	player:GetAttributeChangedSignal(Names.Attr.Carrying):Connect(function()
		local ps = states[player]
		if ps and ps.carry and ((player:GetAttribute(Names.Attr.Carrying) :: string?) or "") ~= "" then
			releaseProp(player, ps, Vector3.new(0, 4, 0), nil)
		end
	end)
	-- something unequipped our tool into the Backpack: put it back in the hand
	local backpack = player:WaitForChild("Backpack", 10)
	if backpack then
		backpack.ChildAdded:Connect(function(child: Instance)
			local ps = states[player]
			if ps and child == ps.tool and player.Character then
				task.defer(function()
					if child.Parent == backpack and player.Character then
						child.Parent = player.Character
					end
				end)
			end
		end)
	end
end

local function watchTag(tag: string, fn: (Instance) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		task.defer(fn, inst) -- builders add prompts/attrs right after the tag
	end)
	for _, inst in CollectionService:GetTagged(tag) do
		task.spawn(fn, inst)
	end
end

-- service ------------------------------------------------------------------------------------------
function InventoryService:Init(all: { [string]: any })
	services = all
end

function InventoryService:Start()
	FxRemote = Net.event("Inventory", "Fx")
	local DropR = Net.event("Inventory", "Drop")
	local ThrowR = Net.event("Inventory", "Throw")
	local SwapR = Net.event("Inventory", "Swap")
	Net.onServer(DropR, { rate = 4, burst = 2 }, function(player: Player)
		doDrop(player)
	end)
	Net.onServer(ThrowR, { rate = 3, burst = 1 }, function(player: Player, rawAim: any, rawCharge: any)
		local aim = Net.unit(rawAim)
		local charge = if type(rawCharge) == "number" and rawCharge == rawCharge then math.clamp(rawCharge, 0, 1) else 0
		if aim then
			doThrow(player, aim, charge)
		end
	end)
	Net.onServer(SwapR, { rate = 4, burst = 2 }, function(player: Player)
		doSwap(player)
	end)
	folder()

	local tool = services.ToolService
	if tool and tool.WaterUsed then
		tool.WaterUsed:Connect(onWaterUsed)
	end

	watchTag(TAG_RACK, function(inst: Instance)
		hookStock(inst, TAG_RACK)
	end)
	watchTag(TAG_COMPARTMENT, function(inst: Instance)
		hookStock(inst, TAG_COMPARTMENT)
	end)
	watchTag(Names.Tag.Truck, function(inst: Instance)
		task.wait(0.5) -- let the builder finish the model
		setupTruck(inst)
	end)
	watchTag(Names.Tag.TruckRefill, hookReel)
	watchTag(Names.Tag.Hydrant, hookHydrant)
	watchTag(Cfg.CarryTag, hookCarryable)

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(hookPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local ps = states[player]
		if ps then
			if ps.carry then
				releaseProp(player, ps, Vector3.zero, nil)
			end
			releaseHose(player, ps.hand)
		end
		states[player] = nil
		for reel, holder in reelHolder do
			if holder == player then
				reelHolder[reel] = nil
			end
		end
	end)

	RunService.Heartbeat:Connect(bonkTick)
	task.spawn(supplyLoop)
	task.spawn(upkeepLoop)
end

function InventoryService:Give(player: Player, itemId: string): boolean
	if not ItemDefs.get(itemId) then
		return false
	end
	local data = fresh(itemId)
	if itemId == "Hose" then
		local truck = ownedTruck(player)
		data.reel = truck and reelOfTruck(truck) or nil
	end
	return (giveHeld(player, { id = itemId, data = data }))
end

function InventoryService:Drop(player: Player): boolean
	return doDrop(player)
end

function InventoryService:Throw(player: Player, aim: Vector3, charge: number): boolean
	local unit = Net.unit(aim)
	return if unit then doThrow(player, unit, charge) else false
end

function InventoryService:Swap(player: Player): boolean
	return doSwap(player)
end

function InventoryService:GetHand(player: Player): string?
	local ps = states[player]
	return ps and ps.hand and ps.hand.id
end

function InventoryService:GetBack(player: Player): string?
	local ps = states[player]
	return ps and ps.back and ps.back.id
end

function InventoryService:Clear(player: Player)
	local ps = states[player]
	if not ps then
		return
	end
	if ps.carry then
		releaseProp(player, ps, Vector3.zero, nil)
	end
	ps.hand, ps.back = nil, nil
	apply(player, ps)
end

-- test hooks ---------------------------------------------------------------------------------------
function InventoryService:_state(player: Player): { [string]: any }
	local ps = states[player]
	return {
		hand = ps and ps.hand and ps.hand.id,
		back = ps and ps.back and ps.back.id,
		carry = ps and ps.carry and ps.carry.Name,
		tool = ps and ps.tool and ps.tool.Name,
		loose = #looseOrder,
		flyers = #flyers,
	}
end

function InventoryService:_give(player: Player, id: string): boolean
	return InventoryService:Give(player, id)
end

function InventoryService:_throw(player: Player, charge: number?): boolean
	local _, root = charOf(player)
	return root ~= nil and doThrow(player, root.CFrame.LookVector, charge or 1)
end

function InventoryService:_fumble(player: Player)
	fumble(player)
end

function InventoryService:_reel(player: Player, reel: BasePart?): boolean
	local r = reel
	if not r then
		local truck = ownedTruck(player)
		r = truck and reelOfTruck(truck) or nil
		if not r then
			for _, t in CollectionService:GetTagged(Names.Tag.TruckRefill) do
				if t:IsA("BasePart") and t:IsDescendantOf(workspace) then
					r = t
					break
				end
			end
		end
	end
	if not r then
		return false
	end
	local _, root = charOf(player)
	if root and not Net.near(player, r.Position, Cfg.ReelReturnDistance) then
		root.CFrame = CFrame.new(r.Position + Vector3.new(0, 3, 6))
	end
	onReel(player, r)
	return InventoryService:GetHand(player) == "Hose"
end

function InventoryService:_hydrant(player: Player, hydrant: BasePart)
	onHydrant(player, hydrant)
end

function InventoryService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Inventory")
	for _, r in { "Drop", "Throw", "Swap", "Fx" } do
		if not (ns and ns:FindFirstChild(r)) then
			return false, `Inventory/{r} remote missing`
		end
	end
	for id in ItemDefs.Items do
		local m = ItemProps.build(id, "world")
		local ok = m.PrimaryPart ~= nil and m.PrimaryPart.Name == "Handle"
		m:Destroy()
		if not ok then
			return false, `ItemProps {id} has no Handle`
		end
	end
	local tool = services.ToolService
	if tool and type(tool.CreateTool) == "function" then
		local t = tool:CreateTool("Hose", nil)
		local ok = typeof(t) == "Instance" and t:IsA("Tool")
		if typeof(t) == "Instance" then
			t:Destroy()
		end
		if not ok then
			return false, "ToolService:CreateTool(Axe) gave no Tool"
		end
	end
	return true, "ok"
end

return InventoryService
