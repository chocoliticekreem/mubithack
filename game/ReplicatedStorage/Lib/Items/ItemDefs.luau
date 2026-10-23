--!strict
-- ItemDefs [owner: Inventory]. Every physical gear item plus the pure slot/state rules of the goofy
-- inventory (docs/game/08 "Inventory"). Shared by InventoryService (server) and InventoryController
-- (client hotbar). Pure Luau: no Roblox API at all, so game/tests/inventory.spec.luau runs it in the
-- luau CLI. Colours are hex strings (Color3.fromHex at the call site).
--
-- Slots: hand (one held item, a Tool under the character), back (one backable item, oxygen tank by
-- default), carry (a physics prop held in both arms; NPC carry belongs to RescueService), face (a worn
-- item: the gas mask; a grab straps it on, it never leaves by G/Q/fumble, only when you go down).
-- Progression data (unlockLevel, axe tiers, pry/cut times) is read by Lib/Items/Progression.
--
--   ItemDefs.Items[id] -> Def
--   ItemDefs.get(id) -> Def?
--   ItemDefs.grab(state, id, ctx?) -> (ok, newState, plan)   plan = { slot, stowed?, dropped?, reason? }
--                                     a face item: slot "face", dropped = the mask it replaced
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
	unlockLevel: number?, -- player level that unlocks it in the locker (nil = 1)
	wear: string?, -- "face": goes in the face slot instead of the hand
	axe: AxeTier?, -- an axe tier: the Tool is always named "Axe" (PhysicsHands/HandsService key on it)
	pry: number?, -- seconds to pry a locked door open quietly (Halligan, Crowbar)
	cut: number?, -- seconds to cut through a door or a wall chunk (Rescue Saw)
	smash: boolean?, -- breaks windows and weak wall chunks (Sledgehammer)
	blurb: string?, -- one line for the locker card
}

-- damage multiplies the door hits of every swing; swing divides the cooldown. Colours are hex,
-- material is an Enum.Material name (ItemDefs stays free of Roblox APIs).
export type AxeTier = { damage: number, swing: number, head: string, material: string, reflect: number? }

export type State = { hand: string?, back: string?, carry: string?, face: string? }

export type Plan = {
	slot: string?, -- "hand" | "back" | "carry" | "face"
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
		name = "Rusty Axe",
		short = "AXE",
		color = "#C0301E",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = true,
		unlockLevel = 1,
		axe = { damage = 1, swing = 1, head = "#9A6B4F", material = "CorrodedMetal" },
		blurb = "Chops doors. Slowly. It has seen things.",
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
	FireAxe = {
		id = "FireAxe",
		name = "Fire Axe",
		short = "F.AXE",
		color = "#E0452F",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = true,
		unlockLevel = 4,
		axe = { damage = 2, swing = 1.35, head = "#D6D8DC", material = "Metal" },
		blurb = "Faster swings, double door damage.",
	},
	GoldenAxe = {
		id = "GoldenAxe",
		name = "Golden Axe",
		short = "GOLD",
		color = "#F2C14E",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = true,
		unlockLevel = 10,
		axe = { damage = 3, swing = 1.7, head = "#F2C14E", material = "Foil", reflect = 0.25 },
		blurb = "Best axe in the city. Extremely shiny.",
	},
	GasMask = {
		id = "GasMask",
		name = "Gas Mask",
		short = "MASK",
		color = "#3A3F44",
		backable = false,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 2,
		wear = "face",
		blurb = "See through smoke, 40% less smoke heat. O2 tank on your back = air.",
	},
	Crowbar = {
		id = "Crowbar",
		name = "Crowbar",
		short = "CROW",
		color = "#B8322A",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 1,
		pry = 2.6,
		blurb = "Pry locked doors open. Quiet, but slow.",
	},
	Halligan = {
		id = "Halligan",
		name = "Halligan Bar",
		short = "HALI",
		color = "#8C9096",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 3,
		pry = 1.2,
		blurb = "The pro's pry bar. Pops locked doors and roof hatches fast.",
	},
	Flashlight = {
		id = "Flashlight",
		name = "Flashlight",
		short = "LITE",
		color = "#F7D046",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 1,
		blurb = "Click to toggle. Cuts through dark smoky rooms.",
	},
	Ladder = {
		id = "Ladder",
		name = "Ladder",
		short = "LADR",
		color = "#C9CCD0",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 5,
		blurb = "Click a wall to stand it up. Climb to windows and roofs.",
	},
	ThermalCam = {
		id = "ThermalCam",
		name = "Thermal Camera",
		short = "THRM",
		color = "#E86A2C",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 6,
		blurb = "Hold it: trapped people glow through walls.",
	},
	Sledgehammer = {
		id = "Sledgehammer",
		name = "Sledgehammer",
		short = "SLDG",
		color = "#5A5E66",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 8,
		smash = true,
		blurb = "Smash windows and weak walls into new doorways.",
	},
	RescueSaw = {
		id = "RescueSaw",
		name = "Rescue Saw",
		short = "SAW",
		color = "#F28C28",
		backable = true,
		prefersBack = false,
		throwable = true,
		tethered = false,
		stocked = true,
		tool = false,
		unlockLevel = 12,
		cut = 0.8,
		blurb = "Cuts through doors and walls in a second. LOUD.",
	},
}
ItemDefs.Items = Items

-- Stable order for UI and the station rack fallback (GearRack attr Slot 1..n -> this list).
ItemDefs.RackOrder = { "Axe", "Extinguisher", "OxygenTank" }

-- Locker / unlock order (Lib/Items/Progression, GearController's locker cards).
ItemDefs.GearOrder = {
	"Hose",
	"Axe",
	"Extinguisher",
	"OxygenTank",
	"Crowbar",
	"Flashlight",
	"GasMask",
	"Halligan",
	"FireAxe",
	"Ladder",
	"ThermalCam",
	"Sledgehammer",
	"GoldenAxe",
	"RescueSaw",
}

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
	return { hand = s.hand, back = s.back, carry = s.carry, face = s.face }
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
	if def.wear == "face" then
		-- worn, not held: a second mask swaps with the one on your face (the old one drops)
		local old = s.face
		s.face = id
		return true, s, { slot = "face", dropped = old }
	end
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
