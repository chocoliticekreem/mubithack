--!strict
-- ItemDefs [owner: Inventory]. Every physical gear item plus the pure slot/state rules of the goofy
-- inventory (docs/game/08 "Inventory"). Shared by InventoryService (server) and InventoryController
-- (client hotbar). Pure Luau: no Roblox API at all, so game/tests/inventory.spec.luau runs it in the
-- luau CLI. Colours are hex strings (Color3.fromHex at the call site).
--
-- Slots: hand (one held item, a Tool under the character), back (one backable item, oxygen tank by
-- default), carry (a physics prop held in both arms; NPC carry belongs to RescueService).
--
--   ItemDefs.Items[id] -> Def
--   ItemDefs.get(id) -> Def?
--   ItemDefs.grab(state, id, ctx?) -> (ok, newState, plan)   plan = { slot, stowed?, dropped?, reason? }
--   ItemDefs.drop(state) -> (newState, what?, slot?)          carry first, else hand
--   ItemDefs.swap(state) -> (ok, newState, reason?)            hand <-> back
--   ItemDefs.fumble(state) -> (newState, dropped?)             ragdoll: the hand item flies off
--   ItemDefs.canUseReel(ownerUserId?, userId) -> boolean
--   ItemDefs.throwSpeed(charge, min, max) -> number
--   ItemDefs.drawWater(water, litres) -> (newWater, drawn)
--   ItemDefs.supplyStep(water, size, rate, dt) -> number
--   ItemDefs.supplyState(dist, length, snapFactor) -> "ok" | "taut" | "snap"
--   ItemDefs.bonkSpeed(speed, minSpeed) -> boolean

local ItemDefs = {}

export type Def = {
	id: string,
	name: string, -- shown in prompts ("Grab Axe") and the hotbar
	short: string, -- hotbar glyph text
	color: string, -- hex
	backable: boolean, -- may sit in the back slot
	prefersBack: boolean, -- a grab puts it on your back when the back is free
	throwable: boolean,
	tethered: boolean, -- the hose nozzle: comes from a truck reel and stays attached to it
	stocked: boolean, -- found in GearRacks / TruckCompartments
	tool: boolean, -- ToolService:CreateTool makes the Tool (else Inventory builds a plain one)
}

export type State = { hand: string?, back: string?, carry: string? }

export type Plan = {
	slot: string?, -- "hand" | "back" | "carry"
	stowed: string?, -- the old hand item moved to the back
	dropped: string?, -- the old hand item fell at your feet
	reason: string?, -- why a grab failed
}

export type Ctx = { downed: boolean?, carryingNpc: boolean? }

local Items: { [string]: Def } = {
	Hose = {
		id = "Hose",
		name = "Hose",
		short = "HOSE",
		color = "#E8B83A",
		backable = false,
		prefersBack = false,
		throwable = true,
		tethered = true,
		stocked = false,
		tool = true,
	},
	Axe = {
		id = "Axe",
		name = "Axe",
		short = "AXE",
		color = "#C0301E",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = true,
	},
	Extinguisher = {
		id = "Extinguisher",
		name = "Extinguisher",
		short = "FOAM",
		color = "#C8232B",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = true,
	},
	OxygenTank = {
		id = "OxygenTank",
		name = "Oxygen Tank",
		short = "O2",
		color = "#C9CCD0",
		backable = true,
		prefersBack = true,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
	},
}
ItemDefs.Items = Items

-- Stable order for UI and the station rack fallback (GearRack attr Slot 1..n -> this list).
ItemDefs.RackOrder = { "Axe", "Extinguisher", "OxygenTank" }

-- The prop carry slot holds a world prop, not an item def; its state value is this marker.
ItemDefs.PROP = "Prop"

function ItemDefs.get(id: string?): Def?
	if type(id) ~= "string" then
		return nil
	end
	return Items[id]
end

-- GearRack attr Item wins; else attr Slot indexes RackOrder (wrapping).
function ItemDefs.rackItem(item: string?, slot: number?): string?
	if ItemDefs.get(item) then
		return item
	end
	if type(slot) == "number" and slot >= 1 then
		local order = ItemDefs.RackOrder
		return order[((math.floor(slot) - 1) % #order) + 1]
	end
	return nil
end

local function copy(s: State): State
	return { hand = s.hand, back = s.back, carry = s.carry }
end

-- Where a freshly grabbed item goes. Never fails for a known item unless you are downed or busy:
--   prefersBack + free back       -> back
--   free hand                     -> hand
--   hand item backable + free back -> old hand item stowed on your back, new item in hand
--   otherwise                     -> old hand item dropped at your feet (goofy swap), new item in hand
function ItemDefs.grab(state: State, id: string, ctx: Ctx?): (boolean, State, Plan)
	local def = ItemDefs.get(id)
	if not def then
		return false, state, { reason = "unknown" }
	end
	local c: Ctx = ctx or {}
	if c.downed then
		return false, state, { reason = "downed" }
	end
	if c.carryingNpc or state.carry ~= nil then
		return false, state, { reason = "arms full" }
	end
	if state.hand == id and def.tethered then
		return false, state, { reason = "already holding" }
	end
	local s = copy(state)
	if def.prefersBack and s.back == nil then
		s.back = id
		return true, s, { slot = "back" }
	end
	if s.hand == nil then
		s.hand = id
		return true, s, { slot = "hand" }
	end
	local cur = ItemDefs.get(s.hand)
	if cur and cur.backable and s.back == nil then
		s.back = s.hand
		s.hand = id
		return true, s, { slot = "hand", stowed = s.back }
	end
	local old = s.hand
	s.hand = id
	return true, s, { slot = "hand", dropped = old }
end

-- Picking up a world prop into the carry slot (both arms). The hand item stays in your hand.
function ItemDefs.grabProp(state: State, ctx: Ctx?): (boolean, State, string?)
	local c: Ctx = ctx or {}
	if c.downed then
		return false, state, "downed"
	end
	if c.carryingNpc or state.carry ~= nil then
		return false, state, "arms full"
	end
	local s = copy(state)
	s.carry = ItemDefs.PROP
	return true, s, nil
end

-- G: the carried prop goes first, then the hand item. Returns what left and from which slot.
function ItemDefs.drop(state: State): (State, string?, string?)
	local s = copy(state)
	if s.carry ~= nil then
		local what = s.carry
		s.carry = nil
		return s, what, "carry"
	end
	if s.hand ~= nil then
		local what = s.hand
		s.hand = nil
		return s, what, "hand"
	end
	return s, nil, nil
end

-- Hold Q: same order as drop, but only throwable things leave.
function ItemDefs.throw(state: State): (State, string?, string?)
	if state.carry ~= nil then
		return ItemDefs.drop(state)
	end
	local def = ItemDefs.get(state.hand)
	if def and def.throwable then
		return ItemDefs.drop(state)
	end
	return state, nil, nil
end

-- Number key: swap hand and back. An empty side is fine (stow or draw), but the item that would
-- end up on your back must be backable.
function ItemDefs.swap(state: State): (boolean, State, string?)
	if state.hand == nil and state.back == nil then
		return false, state, "empty"
	end
	if state.carry ~= nil then
		return false, state, "arms full"
	end
	if state.hand ~= nil then
		local def = ItemDefs.get(state.hand)
		if not (def and def.backable) then
			return false, state, "not backable"
		end
	end
	local s = copy(state)
	s.hand, s.back = state.back, state.hand
	return true, s, nil
end

-- Ragdolled: you fumble the hand item (and a carried prop). The back item is strapped on.
function ItemDefs.fumble(state: State): (State, string?, string?)
	local s = copy(state)
	local hand, carry = s.hand, s.carry
	s.hand = nil
	s.carry = nil
	return s, hand, carry
end

-- The truck reel only hands its nozzle to the truck's owner. A truck with no owner (v1.5 lobby or
-- instance trucks) is anyone's.
function ItemDefs.canUseReel(ownerUserId: number?, userId: number): boolean
	if type(ownerUserId) ~= "number" or ownerUserId == 0 then
		return true
	end
	return ownerUserId == userId
end

function ItemDefs.throwSpeed(charge: number, minSpeed: number, maxSpeed: number): number
	local c = if charge ~= charge then 0 else math.clamp(charge, 0, 1)
	return minSpeed + (maxSpeed - minSpeed) * c
end

-- Spraying draws from the truck tank. Returns the new tank level and what was actually drawn.
function ItemDefs.drawWater(water: number, litres: number): (number, number)
	local w = math.max(0, water)
	local drawn = math.clamp(litres, 0, w)
	return w - drawn, drawn
end

-- A hydrant supply line tops the truck up at `rate` L/s.
function ItemDefs.supplyStep(water: number, size: number, rate: number, dt: number): number
	return math.clamp(water + rate * math.max(0, dt), 0, size)
end

-- Supply line (hydrant <-> truck) stretch: "snap" past length * snapFactor (truck drove off).
function ItemDefs.supplyState(dist: number, length: number, snapFactor: number): string
	if dist > length * snapFactor then
		return "snap"
	elseif dist > length then
		return "taut"
	end
	return "ok"
end

-- A thrown item only bonks while it is still flying fast.
function ItemDefs.bonkSpeed(speed: number, minSpeed: number): boolean
	return speed >= minSpeed
end

return ItemDefs
