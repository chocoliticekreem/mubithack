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
--   InventoryService:GetHand(player): string?   GetBack(player): string?   GetFace(player): string?
--   InventoryService:Clear(player)                      -- silently empties every slot (no drops)
--   InventoryService:TakeHand(player, id): boolean      -- gear: the hand item was used up (placed ladder)
--   InventoryService:Equip(player, { hand, back, face }): (boolean, reason?)  -- the station LOCKER menu
--                                                       (GearService): exact slots, silent, no drops
--   InventoryService:ReadySpray(player): string        -- on arrival at a call (ArrivalService): make SPRAY
--                                                       available (Lib/Fire/SprayAssist.ready): "keep" | "swap"
--                                                       (sprayer on your back) | "give" (a fresh extinguisher:
--                                                       empty hands, or a tank that goes on the free back) |
--                                                       "refill" (empty extinguisher) | "none" | "busy". Never drops
--                                                       anything. Counter inv_ready_<action>
-- Signals: Changed(player), Bonked(thrower: Player, victim: Player, what: string),
--          Fumbled(player, itemId: string)
-- Remotes: Inventory/Drop (C->S, none, 4/s), Inventory/Throw (C->S, aim: unit Vector3, charge: 0..1, 3/s),
--          Inventory/Swap (C->S, none, 4/s), Inventory/Fx (S->C all, kind: string, pos: Vector3, text: string),
--          Inventory/Reel (C->S, prompt: one of our hose prompts, 3/s): the touch HOSE button / bubble. Roblox
--          only lets a client trigger a prompt whose spot is on its screen, and the truck's hose prompt sits
--          in the middle of the chassis (behind the camera from half the truck's sides), so phones grab and
--          stow the hose through this instead; onReel checks the reach like the prompt does.
--          kinds: "grab", "drop", "throw", "bonk", "fumble", "stow"
-- World (reads): parts tagged GearRack (attr Item, or Slot -> ItemDefs.RackOrder), TruckCompartment
--   (attr Item), TruckRefill (the reel: nozzle; anyone's, Cfg.HosesPerTruck nozzles each, grabbed and
--   stowed with [T] from any side of the truck via a "TruckHosePrompt" on its PrimaryPart; holding the
--   extinguisher, [T] swaps it for the hose), Truck (attrs OwnerUserId,
--   Driver), CarryTag props. A truck with no TruckCompartment parts gets its "Locker_*" doors tagged.
-- Water: a truck's hose NEVER runs out (no truck tank, no refills, no supply lines). Street hydrants
--   (MapKit.hydrant: a Model with Body tagged Hydrant + Cap + nozzles, not station ones, not ponds/pools/
--   creeks that share the tag) get a "HydrantHosePrompt" on the Body ([T] / ButtonY / tap, attrs InvPrompt
--   + InvHydrant): the SAME hose as the truck's reel (endless water, HoseLine kind "Hydrant",
--   HoseLineConfig.LengthHydrant), HosesPerTruck nozzles per hydrant; holding the extinguisher it swaps,
--   holding another source's hose it swaps lines. HydrantController relabels it locally and hides it
--   while you drive.
-- Hose model: one hose per player, in the HAND or slung on the BACK (1/2, D-pad up, SWAP, a hotbar tap;
--   grabbing another item while holding it slings it, the old back item drops). Either way its line
--   stays hooked to you (syncHoseLine). Let go of it (G, Q, fumble, death, sitting in a vehicle via
--   HoseLine.Stranded) and the nozzle drops with the SAME line lying from the source to it
--   (HoseLine.release); anyone grabs it and carries on (HoseLine.adopt). A dropped nozzle reels in
--   (removeLoose -> HoseLine.discard) after HoseLineConfig.LyingSeconds, when its truck drives off
--   (HoseLine.isSourceMoving), when the call ends (StowHose) or when the reel reclaims it. 2 per source still
--   counts held + slung + lying nozzles.
-- Trucks and hoses never touch physically: the HoseTether hangs off HoseLine.anchorFor(reel) (an anchored
--   stand-in, never the truck), dropped nozzles are in the HoseLine collision group (no truck contact), a
--   held truck hose is stowed the moment its truck drives (HoseLine.Stranded "truck"), and grabbing a hose
--   (reel or a lying nozzle) off a driving truck says "Wait for the truck to stop!" (inv_hose_refused_moving).
-- FACE slot (gear v2): a worn item (the gas mask), a model "InvFace" welded to the Head; it only
--   leaves when you die (spill) or swap it for another mask.
-- Writes: Player attrs InvHand, InvBack, InvCarry, InvFace ("" = empty), GasMask (bool), OxygenAir, Foam/FoamSize (extinguisher
--   in the hand), FoamBack (the one on your back, nil if none),
--   Water/TankSize (always full while you hold the nozzle: endless water);
--   workspace.LooseItems (Models tagged InventoryItem,
--   attr Item); prompts with attr InvPrompt (Style Custom: InventoryController draws them).
-- Calls (nil-guarded): ToolService:CreateTool, HeatService:GetHeat/Cool,
--   Lib/Tools/HoseLine attach/detach, Shared/Ragdoll.
-- Counters: inv_hose_hydrant, inv_grabs, inv_drops, inv_throws, inv_bonks, inv_fumbles, inv_swaps, inv_hose_out,
--   inv_hose_stowed, inv_props_carried, inv_restocks, inv_locker_equips
-- Thrown: Cfg.ThrowSpinItems (axes, bars) tomahawk end over end at Cfg.AxeThrowSpin rad/s; the rest tumble.
-- One hand Tool at a time: any other inventory Tool (attr InvItem) under the character or in the
--   Backpack is destroyed on every apply; a Tool knocked into the Backpack (UnequipTools) comes back to
--   the hand once you are not downed or carrying (hooked per character, the Backpack is new each spawn).
-- Test hooks (DevHook only): _selftest(), _state(player), _give(player, id), _throw(player, charge?),
--   _fumble(player), _reel(player, reel?, from?: Vector3)  (reel may be a hydrant Body),
--   _grabLoose(player, model?) (the nearest loose item by default)

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("InventoryConfig") :: ModuleScript) :: any
local ToolConfig = require(ConfigFolder:WaitForChild("ToolConfig") :: ModuleScript) :: any
local HoseLineConfig = require(ConfigFolder:WaitForChild("HoseLineConfig") :: ModuleScript) :: any
local ItemDefs = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript)
local SprayAssist = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Fire"):WaitForChild("SprayAssist") :: ModuleScript)
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

-- reel: the hose's source (truck reel / hydrant Body); lyingAt: picked up off the ground, its line is
-- still lying there (HoseLine.adopt takes it over instead of laying a new one)
type Data = { foam: number?, air: number?, reel: BasePart?, lyingAt: BasePart? }
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
	face: Held?,
	faceModel: Model?,
	faceFor: Held?,
	lastNotify: number,
	bpConn: RBXScriptConnection?,
}
type Loose = { id: string, data: Data, born: number, rope: RopeConstraint? }
type Flyer = { part: BasePart, thrower: Player, born: number, hit: { [Player]: true }, what: string }

local services: { [string]: any } = {}
local states: { [Player]: PState } = {}
local loose: { [Model]: Loose } = {}
local looseOrder: { Model } = {}
local reelLoose: { [BasePart]: { Model } } = {} -- nozzles lying on the ground, still tethered to the reel
local flyers: { Flyer } = {}
local stockHooked: { [BasePart]: true } = setmetatable({}, { __mode = "k" }) :: any
-- stock prompt -> its locker / rack part + display, for Inventory/Take (the touch GRAB bubble)
local stockOf: { [ProximityPrompt]: { part: BasePart, display: Model? } } = setmetatable({}, { __mode = "k" }) :: any
local promptHooked: { [ProximityPrompt]: true } = setmetatable({}, { __mode = "k" }) :: any
-- hose prompt -> its reel / hydrant body. Strong keys (an Instance key in a weak table can vanish while the
-- Instance lives), dropped when the prompt is destroyed.
local hoseSource: { [ProximityPrompt]: BasePart } = {}
local function setHoseSource(p: ProximityPrompt, src: BasePart)
	hoseSource[p] = src
	p.Destroying:Connect(function()
		hoseSource[p] = nil
	end)
end
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
local function hoseLineMod(): any
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
	return hoseLineCache
end

local function hoseLine(fn: string, ...: any): any
	local mod = hoseLineMod()
	local f = mod and mod[fn]
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
		face = ps.face and ps.face.id,
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
	Popup.show(player, text, kind or "info", player) -- small, over you (was a screen toast)
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

-- trucks and reels ----------------------------------------------------------------------------
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

-- The tether's reel end hangs off HoseLine.anchorFor(reel): an anchored stand-in that follows a truck
-- reel, never the truck itself (a rope into the truck put the truck in the nozzle's physics mechanism, and
-- the nozzle's SetNetworkOwner(nil) took the truck away from its driver mid-drive).
local function reelAttachment(reel: BasePart): Attachment
	local anchor = hoseLine("anchorFor", reel)
	local host: BasePart = if typeof(anchor) == "Instance" and anchor:IsA("BasePart") then anchor else reel
	local a = host:FindFirstChild("InvReelAtt") :: Attachment?
	if a then
		return a
	end
	local na = Instance.new("Attachment")
	na.Name = "InvReelAtt"
	na.Parent = host
	return na
end

-- A truck reel whose truck is driving (someone in the driver seat, or rolling): no hose off it.
local function reelMoving(reel: BasePart?): boolean
	return reel ~= nil and hoseLine("isSourceMoving", reel) == true
end

local function isHydrantSource(part: BasePart): boolean
	return part:HasTag(Names.Tag.Hydrant)
end

local function hoseLength(reel: BasePart): number
	return tonumber(reel:GetAttribute("HoseLength"))
		or (if isHydrantSource(reel) then HoseLineConfig.LengthHydrant else HoseLineConfig.LengthTruck)
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
	local list = info and info.data.reel and reelLoose[info.data.reel]
	if list then
		local j = table.find(list, m)
		if j then
			table.remove(list, j)
		end
		if #list == 0 then
			reelLoose[info.data.reel :: BasePart] = nil
		end
	end
	-- its line lying on the ground goes back on the reel with it (a no-op once someone adopted it)
	local handle = m.PrimaryPart
	if handle then
		hoseLine("discard", handle)
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
	if reel and reel:IsDescendantOf(workspace) and reelMoving(reel) then
		say(player, stateOf(player), "Wait for the truck to stop!")
		return
	end
	if reel and not reel:IsDescendantOf(workspace) then
		held.data = {} -- the truck is gone: just a loose nozzle now
	elseif reel and hoseLine("isLying", handle) then
		held.data.lyingAt = handle -- pick the line up off the ground (HoseLine.adopt), not a new one
	end
	local ok = giveHeld(player, held)
	held.data.lyingAt = nil
	if ok then
		removeLoose(m)
		Telemetry.count("inv_grabs")
		fx("grab", handle.Position, displayName(info.id))
	end
end

-- `owner`: who let go of it. A hose nozzle keeps that player's line: the chain stays lying on the
-- ground from the source to the nozzle (HoseLine.release) instead of vanishing.
local function spawnLoose(held: Held, cf: CFrame, velocity: Vector3, thrower: Player?, owner: Player?): Model?
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
	if held.id == "Hose" then
		-- a dropped nozzle never bumps (or gets wedged under) a truck either
		local group = hoseLineMod() and hoseLineMod().GROUP
		if type(group) == "string" then
			for _, d in m:GetDescendants() do
				if d:IsA("BasePart") then
					pcall(function()
						d.CollisionGroup = group
					end)
				end
			end
		end
	end
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
			-- the real line stays on the ground; this rope is then only the invisible leash (max length)
			local by = owner or thrower
			if by and hoseLine("release", by, handle, hoseEnd) then
				rope.Visible = false
			end
		end
		local list = reelLoose[reel] or {}
		reelLoose[reel] = list
		table.insert(list, m)
	end
	pcall(function()
		handle:SetNetworkOwner(nil)
	end)
	handle.AssemblyLinearVelocity = velocity
	if thrower then
		local flat = Vector3.new(velocity.X, 0, velocity.Z)
		if ItemDefs.spinsWhenThrown(held.id, Cfg.ThrowSpinItems) and flat.Magnitude > 1e-3 then
			-- tomahawk: spin around the sideways axis so the head goes over the top, toward the target
			handle.AssemblyAngularVelocity = Vector3.yAxis:Cross(flat.Unit) * Cfg.AxeThrowSpin
		else
			local r = Random.new()
			handle.AssemblyAngularVelocity = Vector3.new(r:NextNumber(-1, 1), r:NextNumber(-1, 1), r:NextNumber(-1, 1)) * Cfg.ThrowSpin
		end
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

-- The hose you have, in your hand or slung on your back (never both: one line per firefighter).
local function hoseOf(ps: PState): (Held?, string?)
	if ps.hand and ps.hand.id == "Hose" then
		return ps.hand, "hand"
	elseif ps.back and ps.back.id == "Hose" then
		return ps.back, "back"
	end
	return nil, nil
end

-- One line per player, hooked to wherever the hose is (HoseLine finds the tool or the back coil).
-- Hand <-> back keeps the same line. Losing the hose detaches it on the next step, so a drop in this
-- same step (spawnLoose -> HoseLine.release) leaves the line lying on the ground instead.
local function syncHoseLine(player: Player, ps: PState)
	local held = hoseOf(ps)
	local reel = held and held.data.reel
	if held and reel and reel:IsDescendantOf(workspace) then
		local _, _, hum = charOf(player)
		if hum and hum.SeatPart then
			return
		end
		local from = held.data.lyingAt
		held.data.lyingAt = nil
		if from and hoseLine("adopt", player, from) then
			return
		end
		local _, root = charOf(player)
		local near = root ~= nil and (root.Position - reel.Position).Magnitude <= hoseLength(reel)
		if not hoseLine("attach", player, reel) and near and not reelMoving(reel) then
			-- (far from its source, e.g. the truck drove off or was reset: no line, and never one
			-- laid across the map toward you)
			Popup.show(player, "Hose tangled, try again", "info", player)
		end
		return
	end
	task.defer(function()
		local now = states[player]
		if not (now and hoseOf(now)) then
			hoseLine("detach", player)
		end
	end)
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
	if old and old ~= ps.hand and old.id == "Hose" then
		player:SetAttribute(Names.Attr.Spraying, false) -- the line itself is syncHoseLine's
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
		-- trucks have endless water: the nozzle is always full (ToolService and the HUD read these)
		player:SetAttribute(Names.Attr.TankSize, ToolConfig.TankSize)
		player:SetAttribute(Names.Attr.Water, ToolConfig.TankSize)
	end
end

local BACK_TILT: { [string]: CFrame } = {
	Axe = CFrame.Angles(0, math.rad(90), math.rad(35)),
	FireAxe = CFrame.Angles(0, math.rad(90), math.rad(35)),
	GoldenAxe = CFrame.Angles(0, math.rad(90), math.rad(35)),
	Halligan = CFrame.Angles(0, math.rad(90), math.rad(-30)),
	Crowbar = CFrame.Angles(0, math.rad(90), math.rad(-30)),
	Sledgehammer = CFrame.Angles(0, math.rad(90), math.rad(30)),
	RescueSaw = CFrame.Angles(0, math.rad(90), 0),
	Extinguisher = CFrame.Angles(0, 0, math.rad(-12)),
	OxygenTank = CFrame.new(),
	Hose = CFrame.Angles(0, math.rad(90), math.rad(-40)), -- nozzle over the shoulder
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
	m:SetAttribute("Item", held.id) -- HoseLine hooks a slung hose's line to this coil ("HoseEnd")
	m:PivotTo(torso.CFrame * CFrame.new(0, 0.1, torso.Size.Z / 2 + 0.6) * (BACK_TILT[held.id] or CFrame.new()))
	local w = Instance.new("WeldConstraint")
	w.Part0 = torso
	w.Part1 = m.PrimaryPart
	w.Parent = m
	m.Parent = char
	ps.backModel = m
end

-- The worn item (gas mask) sits over the face, welded to the Head.
local function equipFace(player: Player, ps: PState)
	if ps.faceFor == ps.face and (ps.faceModel == nil or ps.faceModel.Parent ~= nil) then
		return
	end
	if ps.faceModel then
		ps.faceModel:Destroy()
		ps.faceModel = nil
	end
	-- bring back whatever the mask hid (the penguin's beak and googly eyes)
	for part, t in (ps :: any).faceHidden or {} do
		if part.Parent then
			part.Transparency = t
		end
	end
	(ps :: any).faceHidden = nil
	ps.faceFor = ps.face
	local held = ps.face
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not held or not char or not head then
		return
	end
	-- penguins wear a big HeadBlob over the rig head: size the mask to it, line the lenses up with the
	-- googly eyes, and hide the beak + eyes while it's on so nothing pokes through
	local blob = char:FindFirstChild("HeadBlob", true) :: BasePart?
	local scale, at = 0.8, head.CFrame * CFrame.new(0, 0.05, -(head.Size.Z / 2 + 0.12))
	if blob then
		scale = 0.62 * blob.Size.X
		local rel = head.CFrame:ToObjectSpace(blob.CFrame).Position
		at = head.CFrame * CFrame.new(0, rel.Y - 0.15 * blob.Size.Y, rel.Z - blob.Size.Z / 2 - 0.05)
		local hidden: { [BasePart]: number } = {}
		for _, d in blob.Parent:GetChildren() do
			if d:IsA("BasePart") and (string.match(d.Name, "^Beak") or string.match(d.Name, "^Eye%d") or string.match(d.Name, "^Pupil%d")) then
				hidden[d] = d.Transparency
				d.Transparency = 1
			end
		end
		(ps :: any).faceHidden = hidden
	end
	local m = ItemProps.build(held.id, "face", scale)
	m.Name = "InvFace"
	m:PivotTo(at)
	local w = Instance.new("WeldConstraint")
	w.Part0 = head
	w.Part1 = m.PrimaryPart
	w.Parent = m
	m.Parent = char
	ps.faceModel = m
end

local function writeAttrs(player: Player, ps: PState)
	player:SetAttribute("InvFace", if ps.face then ps.face.id else "")
	player:SetAttribute("GasMask", ps.face ~= nil and ps.face.id == "GasMask")
	player:SetAttribute("InvHand", if ps.hand then ps.hand.id else "")
	player:SetAttribute("InvBack", if ps.back then ps.back.id else "")
	player:SetAttribute("InvCarry", if ps.carry then ps.carry.Name else "")
	-- the back extinguisher keeps its own charge (Foam is always the one in your hand)
	player:SetAttribute("FoamBack", if ps.back and ps.back.id == "Extinguisher" then ps.back.data.foam or ToolConfig.FoamSize else nil)
	local o2 = if ps.back and ps.back.id == "OxygenTank" then ps.back else (if ps.hand and ps.hand.id == "OxygenTank" then ps.hand else nil)
	player:SetAttribute("OxygenAir", if o2 then o2.data.air or 0 else nil)
end

-- At most ONE inventory Tool: anything else carrying our InvItem attr (a stale copy left in the
-- Backpack by UnequipTools, a duplicate from a swap race) goes. The real one comes back to the hand.
local function busyHands(player: Player): boolean
	return player:GetAttribute(Names.Attr.Downed) == true or ((player:GetAttribute(Names.Attr.Carrying) :: string?) or "") ~= ""
end

local function sweepTools(player: Player, ps: PState)
	local char = player.Character
	for _, holder in { char, player:FindFirstChildOfClass("Backpack") } do
		if holder then
			for _, c in holder:GetChildren() do
				if c:IsA("Tool") and c ~= ps.tool and c:GetAttribute("InvItem") ~= nil then
					c:Destroy()
				end
			end
		end
	end
	local t = ps.tool
	if t and char and t.Parent ~= char and t.Parent ~= nil and not busyHands(player) then
		t.Parent = char
	end
end

local function apply(player: Player, ps: PState)
	equipHand(player, ps)
	sweepTools(player, ps)
	equipBack(player, ps)
	equipFace(player, ps)
	syncHoseLine(player, ps)
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
	return spawnLoose(held, at, velocity, thrower, player)
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
	local oldHand, oldBack = ps.hand, ps.back
	if plan.slot == "face" then
		local oldFace = ps.face
		ps.face = held
		apply(player, ps)
		if oldFace then
			dropHeldAt(player, oldFace, nil, Vector3.new(0, 6, 0), nil)
		end
		return true, plan
	end
	if plan.slot == "back" then
		ps.back = held
	else
		if plan.stowed then
			ps.back = oldHand
		end
		ps.hand = held
	end
	apply(player, ps)
	local gone = if plan.droppedSlot == "back" then oldBack else oldHand
	if plan.dropped and gone then
		dropHeldAt(player, gone, nil, Vector3.new(0, 6, 0), nil)
		say(player, ps, `Juggled! You dropped the {displayName(gone.id)}`)
	elseif plan.stowed == "Hose" then
		say(player, ps, "Hose on your back. SWAP to spray again", "hint")
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
	apply(player, ps) -- a hose keeps its line either way (syncHoseLine)
	Telemetry.count("inv_swaps")
	if ps.back and ps.back.id == "Hose" then
		Telemetry.count("inv_hose_slung")
		say(player, ps, "Hose on your back. SWAP to spray again", "hint")
	end
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

-- Got in a vehicle with the hose (hand or back): the nozzle drops where the line ends (outside the cab),
-- and the line stays lying there for whoever grabs it next (HoseLine.Stranded).
-- Its truck drove off (HoseLine.Stranded "truck"): the hose goes back on the reel, no line left lying
-- (HoseLine pops "The truck drove off — hose stowed!").
local function stowDriven(player: Player)
	local ps = states[player]
	if not ps then
		return
	end
	local held, slot = hoseOf(ps)
	if not held then
		return
	end
	if slot == "hand" then
		ps.hand = nil
	else
		ps.back = nil
	end
	apply(player, ps)
	Telemetry.count("inv_hose_stowed")
end

local function leaveHose(player: Player)
	local ps = states[player]
	if not ps then
		return
	end
	local held, slot = hoseOf(ps)
	if not held then
		return
	end
	local tip = hoseLine("tipPosition", player)
	if slot == "hand" then
		ps.hand = nil
	else
		ps.back = nil
	end
	apply(player, ps)
	local cf = if typeof(tip) == "Vector3"
		then CFrame.new(tip + Vector3.new(0, 0.6, 0)) * CFrame.Angles(0, math.random() * math.pi * 2, math.rad(80))
		else nil
	dropHeldAt(player, held, cf, Vector3.zero, nil)
	Telemetry.count("inv_hose_left")
end

-- Death: everything you had spills on the floor.
local function spill(player: Player)
	local ps = stateOf(player)
	syncHeld(player, ps)
	if ps.carry then
		releaseProp(player, ps, scatter(), nil)
	end
	local list = { ps.hand, ps.back, ps.face }
	ps.hand, ps.back, ps.face = nil, nil, nil
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
			Popup.show(victim, `{f.thrower.DisplayName}'s {f.what}!`, "blame", f.thrower)
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
	if not id then
		return
	end
	if not Net.near(player, part.Position, Cfg.GrabDistance + 6) then
		say(player, stateOf(player), "Too far! Get closer", "hint")
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
	-- station racks restock at once (unlimited); a truck compartment takes a while to regenerate
	local restock = if truckOf(part) then (Cfg.TruckRestockSeconds or 30) else Cfg.RestockSeconds
	task.delay(restock, function()
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
	stockOf[prompt] = { part = part, display = display }
	prompt.Triggered:Connect(function(player: Player)
		onStock(player, part, prompt, display)
	end)
end

-- A truck with no TruckCompartment parts: its side lockers become compartments.
local function setupTruck(truck: Instance)
	if not truck:IsA("Model") or not truck:IsDescendantOf(workspace) then
		return
	end
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
-- Who holds a nozzle off this reel right now (the hand slot is the single source of truth).
local function holdersOf(reel: BasePart, except: Player?): { Player }
	local list = {}
	for p, ps in states do
		local held = hoseOf(ps) -- in the hand or slung on the back: still out
		if p ~= except and p.Parent and held and held.data.reel == reel then
			table.insert(list, p)
		end
	end
	return list
end

local function lyingOf(reel: BasePart): { Model }
	local list = reelLoose[reel]
	if not list then
		return {}
	end
	for i = #list, 1, -1 do
		if not list[i].Parent then
			table.remove(list, i)
		end
	end
	return list
end

local function capOf(reel: BasePart): number
	return Cfg.HosesPerTruck or 2
end

local function namesOf(list: { Player }): string
	local names = {}
	for _, p in list do
		table.insert(names, p.DisplayName)
	end
	return table.concat(names, " and ")
end

-- Close enough to work the reel: within TruckHoseReach of the truck's box (any side), else of the
-- reel part itself (a reel with no truck).
local function nearSource(player: Player, reel: BasePart): boolean
	local _, root = charOf(player)
	if not root then
		return false
	end
	local truck = truckOf(reel)
	if truck then
		local cf, size = truck:GetBoundingBox()
		local p = cf:PointToObjectSpace(root.Position)
		local pad = (Cfg.TruckHoseReach or 7) + 4 -- + the server's lag slack
		return math.abs(p.X) <= size.X / 2 + pad and math.abs(p.Z) <= size.Z / 2 + pad and math.abs(p.Y) <= size.Y / 2 + pad
	end
	return Net.near(player, reel.Position, Cfg.ReelReturnDistance + 4)
end

local function onReel(player: Player, reel: BasePart)
	local ps = stateOf(player)
	syncHeld(player, ps)
	local _, _, hum = charOf(player)
	if hum and hum.SeatPart then
		return
	end
	if not nearSource(player, reel) then
		say(player, ps, "Too far! Get closer to the hose", "hint")
		return
	end
	local hydrant = isHydrantSource(reel)
	local hand = ps.hand
	local hose, hoseSlot = hoseOf(ps) -- [T] stows it from the hand or from your back
	if hose then
		local from = hose.data.reel
		local other = from ~= nil and from ~= reel and from:IsDescendantOf(workspace)
		if other and not hydrant and not isHydrantSource(from :: BasePart) then
			say(player, ps, "That hose belongs to another truck!")
			return
		end
		if hoseSlot == "hand" then
			ps.hand = nil
			hand = nil
		else
			ps.back = nil
		end
		if other then
			-- a hydrant in the mix: drop the old line, take this one (same endless hose)
		else
			apply(player, ps)
			Telemetry.count("inv_hose_stowed")
			fx("stow", reel.Position, "Hose")
			say(player, ps, if hydrant then "Hose back on the hydrant" else "Hose back on the reel")
			return
		end
	end
	-- Holding the extinguisher (everyone does after the training fire): [T] at the truck swaps it for the
	-- hose. It used to refill the foam instead, so "GRAB THE HOSE: press T" did nothing on a kid's first
	-- call. The extinguisher goes back in the truck (its compartments still hand out fresh ones).
	if not hydrant and reelMoving(reel) then
		-- a hose off a driving truck got dragged along / handed the truck's physics to the holder
		Telemetry.count("inv_hose_refused_moving")
		say(player, ps, "Wait for the truck to stop!")
		return
	end
	local swapped = false
	if hand and hand.id == "Extinguisher" then
		ps.hand = nil
		swapped = true
	end
	-- anyone's truck: its hose has endless water
	local holders = holdersOf(reel, player)
	local lying = lyingOf(reel)
	local slot = ItemDefs.reelSlot(#holders, #lying, capOf(reel))
	if slot == "full" then
		if swapped then
			ps.hand = hand -- no free hose: keep the extinguisher, topped up
			if hand then
				hand.data.foam = ToolConfig.FoamSize
			end
			player:SetAttribute("FoamSize", ToolConfig.FoamSize)
			player:SetAttribute("Foam", ToolConfig.FoamSize)
		end
		local one = #holders == 1
		local what = if hydrant then "hydrant" else "truck"
		say(player, ps, `{namesOf(holders)} {if one then "has" else "have"} this {what}'s hose{if one then "" else "s"}!`)
		return
	end
	local reclaim = if slot == "reclaim" then lying[1] else nil
	local ok = giveHeld(player, { id = "Hose", data = { reel = reel } })
	if ok then
		if reclaim then
			removeLoose(reclaim)
		end
		Telemetry.count("inv_hose_out")
		if hydrant then
			Telemetry.count("inv_hose_hydrant")
		end
		if swapped then
			Telemetry.count("inv_hose_swapped")
			say(player, ps, "HOSE! Endless water. Spray the fire!", "good")
		end
		fx("grab", reel.Position, "Hose")
	elseif swapped then
		ps.hand = hand
		apply(player, ps)
	end
end

local function hookTruckHose(reel: BasePart): boolean
	local truck = truckOf(reel)
	local base = truck and truck.PrimaryPart
	if not truck or not base or base:FindFirstChild("TruckHosePrompt") then
		return false
	end
	local _, size = truck:GetBoundingBox()
	local p = Instance.new("ProximityPrompt")
	p.Name = "TruckHosePrompt"
	p.ActionText = "Grab Hose"
	p.ObjectText = "Fire truck"
	p.KeyboardKeyCode = Cfg.TruckHoseKey or Enum.KeyCode.T
	p.GamepadKeyCode = Enum.KeyCode.ButtonY
	p.HoldDuration = 0
	-- measured from the chassis centre: the far end of the truck plus a few steps out
	p.MaxActivationDistance = math.max(size.X, size.Z) / 2 + (Cfg.TruckHoseReach or 7)
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom
	p:SetAttribute(ATTR_PROMPT, true)
	p:SetAttribute("InvReel", true) -- InventoryController relabels it locally (Grab / Stow Hose)
	p.Parent = base
	promptHooked[p] = true
	setHoseSource(p, reel)
	p.Triggered:Connect(function(player: Player)
		onReel(player, reel)
	end)
	return true
end

local function hookReel(inst: Instance)
	if not inst:IsA("BasePart") then
		return
	end
	local reel = inst :: BasePart
	local prompt = reel:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.HoldDuration = 0
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
	setHoseSource(p, reel)
	p.ActionText = "Grab Hose"
	-- same chunky "[E] Grab Hose" sticker as the lockers (InventoryController), instant
	p.Style = Enum.ProximityPromptStyle.Custom
	p:SetAttribute(ATTR_PROMPT, true)
	p.HoldDuration = 0
	p.MaxActivationDistance = math.max(p.MaxActivationDistance, 12)
	p:SetAttribute("InvReel", true) -- InventoryController relabels it locally (Grab / Stow Hose)
	p.Triggered:Connect(function(player: Player)
		onReel(player, reel)
	end)
	-- on a truck the hose works from ANY side: one [T] prompt on the chassis covers the whole truck,
	-- so the tailgate-only [E] reel prompt goes quiet
	task.delay(0.6, function() -- the builder finishes the model (PrimaryPart) first
		if reel.Parent and hookTruckHose(reel) then
			p.Enabled = false
		end
	end)
end

-- hydrants: the same hose as the truck reel ----------------------------------------------------------
-- Only real street hydrants (MapKit.hydrant's Body + Cap + nozzles): ponds, pools and creeks share the
-- Hydrant tag but stay scenery, and the station's hydrants (inside the StationOrigin model) stay props.
local function hydrantBody(inst: Instance): BasePart?
	if not inst:IsA("BasePart") or inst.Name ~= "Body" then
		return nil
	end
	local m = inst.Parent
	if not m or not m:IsA("Model") or not m:FindFirstChild("Cap") or not m:FindFirstChild("NozzleL") then
		return nil
	end
	local cur: Instance? = m
	while cur and cur ~= workspace do
		if cur:GetAttribute("StationOrigin") ~= nil then
			return nil
		end
		cur = cur.Parent
	end
	return inst
end

local function hookHydrant(inst: Instance)
	local body = hydrantBody(inst)
	if not body or body:FindFirstChild("HydrantHosePrompt") then
		return
	end
	local p = Instance.new("ProximityPrompt")
	p.Name = "HydrantHosePrompt"
	p.ActionText = "Grab Hose"
	p.ObjectText = "Hydrant"
	p.KeyboardKeyCode = Cfg.TruckHoseKey or Enum.KeyCode.T
	p.GamepadKeyCode = Enum.KeyCode.ButtonY
	p.HoldDuration = 0
	p.MaxActivationDistance = Cfg.HydrantHoseReach or 10
	p.RequiresLineOfSight = false
	p.Style = Enum.ProximityPromptStyle.Custom
	p:SetAttribute(ATTR_PROMPT, true)
	p:SetAttribute("InvHydrant", true) -- HydrantController relabels it locally (Grab / Stow Hose)
	p.Parent = body
	promptHooked[p] = true
	setHoseSource(p, body)
	p.Triggered:Connect(function(player: Player)
		onReel(player, body)
	end)
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
			-- a dropped nozzle (and its line lying on the ground) reels itself in after LyingSeconds, or as
			-- soon as its truck drives off
			local tooOld = now - info.born > (if reel then HoseLineConfig.LyingSeconds or Cfg.LooseSeconds else Cfg.LooseSeconds)
			local stray = reel ~= nil
				and (
					not reel:IsDescendantOf(workspace)
					or (reel.Position - handle.Position).Magnitude > hoseLength(reel) * 2.5
					or reel.AssemblyLinearVelocity.Magnitude > (HoseLineConfig.LyingStowSpeed or 6)
					or reelMoving(reel)
				)
			if tooOld or stray then
				removeLoose(m)
			end
		end
	end
end

-- players ------------------------------------------------------------------------------------------
-- Something unequipped our tool into the Backpack (RescueService carry, SquadService downed): put it
-- back in the hand once the hands are free. The Backpack is a new instance every spawn, so this is
-- hooked per character (the old once-per-player hook went dead after the first respawn).
local function hookBackpack(player: Player, ps: PState)
	if ps.bpConn then
		ps.bpConn:Disconnect()
		ps.bpConn = nil
	end
	local backpack = player:FindFirstChildOfClass("Backpack") or player:WaitForChild("Backpack", 10)
	if not backpack or states[player] ~= ps then
		return
	end
	ps.bpConn = backpack.ChildAdded:Connect(function(child: Instance)
		if child == ps.tool and not busyHands(player) then
			task.defer(function()
				if child.Parent == backpack and player.Character and not busyHands(player) then
					child.Parent = player.Character
				end
			end)
		end
	end)
end

local function hookCharacter(player: Player, char: Model)
	local ps = stateOf(player)
	task.spawn(hookBackpack, player, ps)
	-- Death already spilled the old kit; a respawn without dying (LoadCharacter) keeps it on the new body.
	if ps.carry then
		releaseProp(player, ps, Vector3.zero, nil)
	end
	ps.tool, ps.toolFor, ps.backModel, ps.backFor = nil, nil, nil, nil
	ps.faceModel, ps.faceFor = nil, nil
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
		if ps then
			sweepTools(player, ps) -- hands free again: the tool comes back out of the Backpack
		end
	end)
	player:GetAttributeChangedSignal(Names.Attr.Downed):Connect(function()
		local ps = states[player]
		if ps then
			sweepTools(player, ps)
		end
	end)
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
	Net.onServer(Net.event("Inventory", "Reel"), { rate = 3, burst = 2 }, function(player: Player, prompt: any)
		local src = if typeof(prompt) == "Instance" and prompt:IsA("ProximityPrompt") then hoseSource[prompt] else nil
		if src and prompt.Enabled and src:IsDescendantOf(workspace) then
			Telemetry.count("inv_hose_tap")
			onReel(player, src)
		end
	end)
	-- the touch GRAB bubble on a truck locker / gear rack (TapUseController): straight to the server, like
	-- Inventory/Reel. Roblox ignores InputHoldBegin on a prompt it isn't showing (off screen, or picked up
	-- from the truck's own list while you stand at its back), so a tap on GRAB did nothing there.
	-- onStock re-checks stock, Enabled and distance.
	Net.onServer(Net.event("Inventory", "Take"), { rate = 3, burst = 2 }, function(player: Player, prompt: any)
		local st = if typeof(prompt) == "Instance" and prompt:IsA("ProximityPrompt") then stockOf[prompt] else nil
		if st and st.part:IsDescendantOf(workspace) then
			local _, _, hum = charOf(player)
			if hum and hum.SeatPart then
				return
			end
			Telemetry.count("inv_take_tap")
			onStock(player, st.part, prompt, st.display)
		end
	end)
	folder()
	local hl = hoseLineMod()
	if hl and hl.Stranded then
		hl.Stranded:Connect(function(player: Player, why: string)
			if why == "truck" then
				stowDriven(player)
			else
				leaveHose(player)
			end
		end)
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
			hoseLine("detach", player)
		end
		if ps and ps.bpConn then
			ps.bpConn:Disconnect()
		end
		states[player] = nil
	end)

	RunService.Heartbeat:Connect(bonkTick)
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

-- Gear: the hand item is used up in the world (a placed ladder). Silent, no drop. true = it was `id`.
function InventoryService:TakeHand(player: Player, id: string): boolean
	local ps = states[player]
	if not ps or not ps.hand or ps.hand.id ~= id then
		return false
	end
	ps.hand = nil
	apply(player, ps)
	return true
end

-- The station LOCKER (GearService validates ids, unlocks and the cooldown): set the hand / back / face
-- slots to exactly `eq` ({ hand, back, face }, nil = empty). Silent: whatever leaves a slot goes back in
-- the locker (no drop), an item that stays (or moves hand <-> back) keeps its charge. Refused while
-- downed, carrying a person, or holding the hose (that goes back to the truck).
function InventoryService:Equip(player: Player, eq: { hand: string?, back: string?, face: string? }): (boolean, string?)
	local ps = stateOf(player)
	if busyHands(player) then
		return false, "busy"
	end
	syncHeld(player, ps)
	local cur, curSlot = hoseOf(ps)
	if cur and (eq :: any)[curSlot :: string] ~= cur.id then
		return false, "hose"
	end
	local pool: { [string]: Held } = {}
	for _, h in { ps.hand, ps.back, ps.face } do
		if h and not pool[h.id] then
			pool[h.id] = h
		end
	end
	local function pick(id: string?): Held?
		if not id or not ItemDefs.get(id) then
			return nil
		end
		local h = pool[id]
		if h then
			pool[id] = nil
			return h
		end
		return { id = id, data = fresh(id) }
	end
	ps.hand = pick(eq.hand)
	ps.back = pick(eq.back)
	ps.face = pick(eq.face)
	apply(player, ps)
	Telemetry.count("inv_locker_equips")
	return true, nil
end

function InventoryService:ReadySpray(player: Player): string
	local ps = states[player]
	if not ps or busyHands(player) or not player.Character then
		return "busy"
	end
	syncHeld(player, ps)
	local hand, back = ps.hand, ps.back
	local plan = SprayAssist.ready(
		if hand then hand.id else nil,
		if hand then hand.data.foam else nil,
		if back then back.id else nil,
		if back then back.data.foam else nil
	)
	if plan == "swap" then
		if not doSwap(player) then
			plan = "none"
		end
	elseif plan == "give" then
		local ok, how = giveHeld(player, { id = "Extinguisher", data = fresh("Extinguisher") })
		if not ok or (how and how.dropped) then
			plan = "none"
		end
	elseif plan == "refill" and hand then
		hand.data.foam = ToolConfig.FoamSize
		player:SetAttribute("Foam", ToolConfig.FoamSize)
	end
	Telemetry.count(`inv_ready_{plan}`)
	return plan
end

function InventoryService:GetFace(player: Player): string?
	local ps = states[player]
	return ps and ps.face and ps.face.id
end

function InventoryService:Clear(player: Player)
	local ps = states[player]
	if not ps then
		return
	end
	if ps.carry then
		releaseProp(player, ps, Vector3.zero, nil)
	end
	ps.hand, ps.back, ps.face = nil, nil, nil
	apply(player, ps)
end

-- Put the player's hose back on their truck reel: the held nozzle and any nozzle they left lying
-- on the ground tethered to their truck (mission over, so the next call starts with a rolled-up hose).
function InventoryService:StowHose(player: Player): boolean
	local stowed = false
	local ps = states[player]
	local slot: string? = nil
	if ps then
		_, slot = hoseOf(ps)
	end
	if ps and slot then
		if slot == "hand" then
			ps.hand = nil
		else
			ps.back = nil
		end
		apply(player, ps)
		stowed = true
	end
	for reel, list in reelLoose do
		local truck = truckOf(reel)
		if truck and truck:GetAttribute("OwnerUserId") == player.UserId then
			for _, m in table.clone(list) do
				removeLoose(m)
			end
			stowed = true
		end
	end
	if stowed then
		Telemetry.count("inv_hose_stowed")
	end
	return stowed
end

-- test hooks ---------------------------------------------------------------------------------------
function InventoryService:_state(player: Player): { [string]: any }
	local ps = states[player]
	return {
		hand = ps and ps.hand and ps.hand.id,
		back = ps and ps.back and ps.back.id,
		face = ps and ps.face and ps.face.id,
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

-- Pick up a loose item (default: the nearest), as its [E] prompt would.
function InventoryService:_grabLoose(player: Player, m: Model?): boolean
	local _, root = charOf(player)
	local pick = m
	if not pick and root then
		local best = math.huge
		for lm in loose do
			local h = lm.PrimaryPart
			if h and (h.Position - root.Position).Magnitude < best then
				best, pick = (h.Position - root.Position).Magnitude, lm
			end
		end
	end
	if not pick then
		return false
	end
	grabLoose(player, pick)
	return loose[pick] == nil
end

-- `from` (optional): stand there first (tests grab the hose from the side or the front of a truck).
function InventoryService:_reel(player: Player, reel: BasePart?, from: Vector3?): boolean
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
	if root and typeof(from) == "Vector3" then
		root.CFrame = CFrame.new(from)
	elseif root and not nearSource(player, r) then
		root.CFrame = CFrame.new(r.Position + Vector3.new(0, 3, 6))
	end
	onReel(player, r)
	return InventoryService:GetHand(player) == "Hose"
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
