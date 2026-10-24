-- Upgrades: pure data for the dropper / ore tier / speed / cash multiplier tree.
-- No requires, no side effects. Returns { list = {...}, byId = {...}, ores = {...}, starterCash = n }.
--
-- This table is the SINGLE source of truth for upgrade prices. Shop cards, world pads, the
-- server purchase check, the tutorial text and the HUD "Next:" hint must all read cost from here.
-- Dropper 2 = 10 and Speed 1 (Fast Belt) = 45, matching the design doc, Config.STARTING_CASH (10)
-- and the tutorial text ("the pad costs $10").
--
-- BUDGET MATH
--   The first cube (Bronze) is worth 5 cash. The player starts with 10 cash, so the first buy
--   (Dropper 2, 10 cash) is affordable immediately after claiming a plot. Speed 1 (45 cash) follows
--   after only a short wait (about 9 cubes' worth of income).
--   Total cost of all 10 upgrades:
--     10 + 60 + 45 + 250 + 500 + 900 + 1400 + 2200 + 4000 + 7000 = 16365 cash
--   Income after each milestone (cubes per 2 s cycle x ore value x cash multiplier, per second):
--     base                        1 x 5  x 1.0 / 2 =   2.5 /s
--     dropper2                    2 x 5  x 1.0 / 2 =   5   /s
--     tier_silver                 2 x 12 x 1.0 / 2 =  12   /s
--     dropper3                    3 x 12 x 1.0 / 2 =  18   /s
--     mult1 (x1.5)                3 x 12 x 1.5 / 2 =  27   /s
--     tier_gold                   3 x 30 x 1.5 / 2 =  67.5 /s
--     dropper4                    4 x 30 x 1.5 / 2 =  90   /s
--     mult2 (x2)                  4 x 30 x 2.0 / 2 = 120   /s
--     tier_diamond                4 x 75 x 2.0 / 2 = 300   /s
--   (speed upgrades only shorten the trip to the collector.)
--
-- Effect shapes:
--   { kind = "dropper",  slots = n }   total active dropper slots after purchase
--   { kind = "tier",     tier = n }    ore tier every dropper spits out (index into ores)
--   { kind = "speed",    mult = x }    conveyor speed multiplier
--   { kind = "cashMult", mult = x }    collector cash multiplier

local list = {
	{ id = "dropper2", name = "Dropper 2", cost = 10, requires = nil, effect = { kind = "dropper", slots = 2 } },
	{ id = "tier_silver", name = "Silver Ore", cost = 60, requires = "dropper2", effect = { kind = "tier", tier = 2 } },
	{ id = "speed1", name = "Speed 1", cost = 45, requires = "dropper2", effect = { kind = "speed", mult = 1.5 } },
	{ id = "dropper3", name = "Dropper 3", cost = 250, requires = "dropper2", effect = { kind = "dropper", slots = 3 } },
	{ id = "mult1", name = "Cash x1.5", cost = 500, requires = "tier_silver", effect = { kind = "cashMult", mult = 1.5 } },
	{ id = "tier_gold", name = "Gold Ore", cost = 900, requires = "tier_silver", effect = { kind = "tier", tier = 3 } },
	{ id = "speed2", name = "Speed 2", cost = 1400, requires = "speed1", effect = { kind = "speed", mult = 2 } },
	{ id = "dropper4", name = "Dropper 4", cost = 2200, requires = "dropper3", effect = { kind = "dropper", slots = 4 } },
	{ id = "mult2", name = "Cash x2", cost = 4000, requires = "mult1", effect = { kind = "cashMult", mult = 2 } },
	{ id = "tier_diamond", name = "Diamond Ore", cost = 7000, requires = "tier_gold", effect = { kind = "tier", tier = 4 } },
}

-- Indexed by tier.
local ores = {
	{ name = "Bronze", value = 5, color = Color3.fromRGB(205, 127, 50), material = Enum.Material.Metal, sparkles = false },
	{ name = "Silver", value = 12, color = Color3.fromRGB(205, 210, 220), material = Enum.Material.Metal, sparkles = false },
	{ name = "Gold", value = 30, color = Color3.fromRGB(255, 205, 40), material = Enum.Material.Foil, sparkles = false },
	{ name = "Diamond", value = 75, color = Color3.fromRGB(80, 235, 255), material = Enum.Material.Glass, sparkles = true },
}

local byId = {}
for _, upgrade in ipairs(list) do
	byId[upgrade.id] = upgrade
end

return {
	list = list,
	byId = byId,
	ores = ores,
	-- Starter grant: matches Config.STARTING_CASH so the first upgrade (Dropper 2, 10) is affordable immediately.
	starterCash = 10,
}
