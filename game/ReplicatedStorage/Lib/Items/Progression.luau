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

return Progression
