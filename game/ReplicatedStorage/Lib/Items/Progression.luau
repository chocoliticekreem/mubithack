--!strict
-- Progression [owner: Gear]. PURE (no Roblox APIs; game/tests/gear.spec.luau runs it in the luau CLI):
-- which gear a level unlocks, the locker loadout rules, axe tier stats and the small numbers the gear
-- verbs share (kick chance, smoke heat with a mask). Item data lives in ItemDefs (unlockLevel, axe,
-- pry, cut, smash, wear). Used by GearService (server) and GearController (locker UI, toasts).
--
--   Progression.LoadoutSize                                  -- picks hung on your rack
--   Progression.unlockLevel(id) -> number                    -- 1 for items without one
--   Progression.isUnlocked(id, level) -> boolean
--   Progression.unlockedAt(level) -> { id }                  -- GearOrder order
--   Progression.newUnlocks(fromLevel, toLevel) -> { id }     -- unlocked by going from -> to
--   Progression.nextUnlock(level) -> (id?, level?)
--   Progression.lockable(id) -> boolean                      -- can sit on a rack peg (stocked items)
--   Progression.sanitizeLoadout(list, level) -> { id }       -- deduped, unlocked, lockable, capped
--   Progression.defaultLoadout(level) -> { id }
--   Progression.axeStats(id) -> (damage, swing)              -- 1, 1 for anything that isn't an axe tier
--   Progression.doorHits(hits, id, maxHits) -> number         -- a swing's door hits times the tier damage
--   Progression.swingCooldown(base, id) -> number
--   Progression.kickChance(level, tries) -> number           -- 0..1, better with level and each retry
--   Progression.smokeHeatMultiplier(masked, air) -> number   -- HeatService gain factor
-- The station LOCKER (one shared cabinet that opens a menu: GearService + GearController):
--   Progression.lockerItems() -> { id }                      -- the cards, GearOrder order (no fixtures)
--   Progression.lockerState(id, level) -> "open" | "locked" | "truck"   -- truck = lives on the fire truck
--   Progression.lockReason(id) -> string                     -- "Reach Level 4!" on a locked card
--   Progression.slotFor(id, want) -> "hand" | "back" | "face" | nil     -- where a tap puts it (nil = can't)
--   Progression.lockerTake(eq, id, want) -> (ok, eq', why?)   -- eq = { hand, back, face } (ids or nil)
--   Progression.lockerSwap(eq) -> (ok, eq', why?)            -- hand <-> back
--   Progression.lockerOff(eq, slot) -> (ok, eq')             -- put that slot back in the locker
--   Progression.sanitizeEquipped(raw, level) -> eq           -- saved loadout: only open, slot-legal ids
-- In Roblox `script` exists; the luau CLI (specs) has no `script` and resolves the relative path.
local ItemDefs = if (script :: any) ~= nil
	then require((script :: any).Parent:WaitForChild("ItemDefs")) :: any
	else (require :: any)("./ItemDefs") :: any

local Progression = {}

Progression.LoadoutSize = 3
-- picked for a fresh profile (each is filtered by level, so a Lv1 player gets the Lv1 ones)
Progression.DefaultPicks = { "Axe", "OxygenTank", "Flashlight" }

Progression.Kick = { Base = 0.35, PerLevel = 0.03, PerTry = 0.15, Max = 0.85 }
Progression.Mask = { Smoke = 0.6, WithAir = 0.3 } -- heat gain factor in smoke: masked, masked + O2 air

function Progression.unlockLevel(id: string): number
	local def = ItemDefs.get(id)
	if not def then
		return math.huge
	end
	return def.unlockLevel or 1
end

function Progression.isUnlocked(id: string, level: number): boolean
	return ItemDefs.get(id) ~= nil and Progression.unlockLevel(id) <= math.max(1, level)
end

function Progression.unlockedAt(level: number): { string }
	local out = {}
	for _, id in ItemDefs.GearOrder do
		if Progression.isUnlocked(id, level) then
			table.insert(out, id)
		end
	end
	return out
end

function Progression.newUnlocks(fromLevel: number, toLevel: number): { string }
	local out = {}
	for _, id in ItemDefs.GearOrder do
		local at = Progression.unlockLevel(id)
		if at > fromLevel and at <= toLevel then
			table.insert(out, id)
		end
	end
	return out
end

function Progression.nextUnlock(level: number): (string?, number?)
	local best: string?, bestAt = nil, math.huge
	for _, id in ItemDefs.GearOrder do
		local at = Progression.unlockLevel(id)
		if at > level and at < bestAt then
			best, bestAt = id, at
		end
	end
	return best, if best then bestAt else nil
end

function Progression.lockable(id: string): boolean
	local def = ItemDefs.get(id)
	return def ~= nil and def.stocked and not def.tethered
end

function Progression.sanitizeLoadout(list: any, level: number): { string }
	local out: { string } = {}
	local seen: { [string]: boolean } = {}
	if type(list) ~= "table" then
		return out
	end
	for _, id in list do
		if #out >= Progression.LoadoutSize then
			break
		end
		if type(id) == "string" and not seen[id] and Progression.lockable(id) and Progression.isUnlocked(id, level) then
			seen[id] = true
			table.insert(out, id)
		end
	end
	return out
end

function Progression.defaultLoadout(level: number): { string }
	return Progression.sanitizeLoadout(Progression.DefaultPicks, level)
end

function Progression.axeStats(id: string?): (number, number)
	local def = ItemDefs.get(id)
	local tier = def and def.axe
	if not tier then
		return 1, 1
	end
	return math.max(0.1, tier.damage), math.max(0.1, tier.swing)
end

function Progression.doorHits(hits: number, id: string?, maxHits: number): number
	local damage = Progression.axeStats(id)
	local n = math.floor(math.max(1, hits) * damage + 0.5)
	return math.clamp(n, 1, math.max(1, maxHits))
end

function Progression.swingCooldown(base: number, id: string?): number
	local _, swing = Progression.axeStats(id)
	return base / swing
end

function Progression.kickChance(level: number, tries: number): number
	local k = Progression.Kick
	local c = k.Base + k.PerLevel * (math.max(1, level) - 1) + k.PerTry * math.max(0, tries)
	return math.clamp(c, 0, k.Max)
end

function Progression.smokeHeatMultiplier(masked: boolean, air: number?): number
	if not masked then
		return 1
	end
	if type(air) == "number" and air > 0 then
		return Progression.Mask.WithAir
	end
	return Progression.Mask.Smoke
end

-- the locker ----------------------------------------------------------------------------------------
export type Equipped = { hand: string?, back: string?, face: string? }

function Progression.lockerItems(): { string }
	local out = {}
	for _, id in ItemDefs.GearOrder do
		local def = ItemDefs.get(id)
		if def and not def.fixture then
			table.insert(out, id)
		end
	end
	return out
end

function Progression.lockerState(id: string, level: number): string
	local def = ItemDefs.get(id)
	if not def or def.fixture then
		return "locked"
	end
	if def.tethered then
		return "truck"
	end
	if not Progression.isUnlocked(id, level) then
		return "locked"
	end
	return "open"
end

function Progression.lockReason(id: string): string
	local at = Progression.unlockLevel(id)
	if at == math.huge then
		return "Not in the locker"
	end
	return `Reach Level {at}!`
end

function Progression.slotFor(id: string, want: string?): string?
	local def = ItemDefs.get(id)
	if not def or def.fixture or def.tethered then
		return nil
	end
	if def.wear == "face" then
		return "face"
	end
	if want == "back" then
		return if def.backable then "back" else nil
	end
	return "hand"
end

local function eqCopy(eq: any): Equipped
	local e = if type(eq) == "table" then eq else {}
	local function v(x: any): string?
		return if type(x) == "string" and x ~= "" then x else nil
	end
	return { hand = v(e.hand), back = v(e.back), face = v(e.face) }
end

local function backable(id: string?): boolean
	local def = ItemDefs.get(id)
	return def ~= nil and def.backable == true
end

-- Tap a card: the item goes in your HAND (or on your BACK with want = "back"; a mask always on your face).
-- What was in that slot goes back in the locker. Taking the item that sits in the OTHER slot swaps the
-- two (the old hand item goes on the back only if it fits there, else back in the locker).
function Progression.lockerTake(eq: any, id: string, want: string?): (boolean, Equipped, string?)
	local e = eqCopy(eq)
	local slot = Progression.slotFor(id, want)
	if not slot then
		local def = ItemDefs.get(id)
		if def and def.tethered then
			return false, e, "truck"
		end
		if def and want == "back" then
			return false, e, "not backable"
		end
		return false, e, "unknown"
	end
	if slot == "face" then
		e.face = id
		return true, e, nil
	end
	if slot == "hand" then
		if e.hand == id then
			return true, e, nil
		end
		if e.back == id then
			e.back = if backable(e.hand) then e.hand else nil
		end
		e.hand = id
		return true, e, nil
	end
	if e.back == id then
		return true, e, nil
	end
	if e.hand == id then
		e.hand = e.back
	end
	e.back = id
	return true, e, nil
end

function Progression.lockerSwap(eq: any): (boolean, Equipped, string?)
	local e = eqCopy(eq)
	if e.hand == nil and e.back == nil then
		return false, e, "empty"
	end
	if e.hand ~= nil and not backable(e.hand) then
		return false, e, "not backable"
	end
	e.hand, e.back = e.back, e.hand
	return true, e, nil
end

function Progression.lockerOff(eq: any, slot: string): (boolean, Equipped)
	local e = eqCopy(eq)
	if slot ~= "hand" and slot ~= "back" and slot ~= "face" then
		return false, e
	end
	local had = (e :: any)[slot] ~= nil;
	(e :: any)[slot] = nil
	return had, e
end

function Progression.sanitizeEquipped(raw: any, level: number): Equipped
	local e = eqCopy(raw)
	local out: Equipped = {}
	for _, slot in { "hand", "back", "face" } do
		local id = (e :: any)[slot]
		local want = if slot == "back" then "back" else "hand"
		if id and Progression.lockerState(id, level) == "open" and Progression.slotFor(id, want) == slot then
			(out :: any)[slot] = id
		end
	end
	if out.hand ~= nil and out.hand == out.back then
		out.back = nil
	end
	return out
end

return Progression
