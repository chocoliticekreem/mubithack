-- Upgrades: pure data for the dropper / ore tier / speed / cash multiplier tree.
-- No requires, no side effects. Returns { list = {...}, byId = {...}, ores = {...}, starterCash = n }.
--
-- This table is the SINGLE source of truth for upgrade prices. Shop cards, world pads, the
-- server purchase check, the tutorial text and the HUD "Next:" hint must all read cost from here.
-- Dropper 2 = 10, Speed 1 (Fast Belt) = 20 and Dropper 3 = 40, so a purchase lands roughly
-- every 8-10 s in the first minute. The player starts with 0 cash (Config.STARTING_CASH must
-- match), so the first two collected cubes earn the first purchase.
--
-- BUDGET MATH
--   The first cube (Bronze) is worth 5 cash. The player starts with 0 cash, so the first buy
--   (Dropper 2, 10 cash) is earned by the first two cubes, which fills the HUD goal bar before
--   the pad turns green. After Dropper 2, income is 5 cash/s (2 cubes per 2 s cycle x 5 cash).
--   Total cost of all 10 upgrades:
--     10 + 20 + 60 + 40 + 300 + 500 + 800 + 1300 + 2200 + 4000 = 9230 cash
--   Income after each milestone (cubes per 2 s cycle x ore value x cash multiplier, per second),
--   and the approximate wait for the NEXT purchase at that income:
--     base                        1 x 5  x 1.0 / 2 =   2.5 /s   (Dropper 2, 10 -> ~4 s)
--     dropper2                    2 x 5  x 1.0 / 2 =   5   /s   (Speed 1, 20  -> ~4 s)
--     speed1                                           5   /s   (Dropper 3, 40 -> ~8 s)
--     dropper3                    3 x 5  x 1.0 / 2 =   7.5 /s   (Silver, 60 -> ~8 s)
--     tier_silver                 3 x 12 x 1.0 / 2 =  18   /s   (Cash x1.5, 300 -> ~17 s)
--     mult1 (x1.5)                3 x 12 x 1.5 / 2 =  27   /s   (Gold, 500 -> ~18 s)
--     tier_gold                   3 x 30 x 1.5 / 2 =  67.5 /s   (Speed 2, 800 -> ~12 s)
--     speed2                                          67.5 /s   (Dropper 4, 1300 -> ~19 s)
--     dropper4                    4 x 30 x 1.5 / 2 =  90   /s   (Cash x2, 2200 -> ~24 s)
--     mult2 (x2)                  4 x 30 x 2.0 / 2 = 120   /s   (Diamond, 4000 -> ~33 s)
--     tier_diamond                4 x 75 x 2.0 / 2 = 300   /s
--   (speed upgrades only shorten the trip to the collector.)
--
-- Effect shapes:
--   { kind = "dropper",  slots = n }   total active dropper slots after purchase
--   { kind = "tier",     tier = n }    ore tier every dropper spits out (index into ores)
--   { kind = "speed",    mult = x }    conveyor speed multiplier
--   { kind = "cashMult", mult = x }    collector cash multiplier
--
-- Optional presentation fields (read by the client for the purchase celebration):
--   label  = short headline string
--   popup  = RewardPopup text (shown with Win sting, shockwave ring and FOV punch for ore tiers)
--   color  = Color3 for the shockwave ring / popup (ore tiers)
--
-- Every `requires` points at an existing id, so pads reveal progressively.

local list = {
	{ id = "dropper2", name = "Dropper 2", cost = 10, requires = nil, effect = { kind = "dropper", slots = 2 } },
	{ id = "speed1", name = "Speed 1", cost = 20, requires = "dropper2", effect = { kind = "speed", mult = 1.5 } },
	{
		id = "tier_silver",
		name = "Silver Ore",
		cost = 60,
		requires = "dropper2",
		effect = { kind = "tier", tier = 2 },
		label = "Silver Ore",
		popup = "SILVER ORE! $12 per cube",
		color = Color3.fromRGB(205, 210, 220),
	},
	{ id = "dropper3", name = "Dropper 3", cost = 40, requires = "dropper2", effect = { kind = "dropper", slots = 3 } },
	{ id = "mult1", name = "Cash x1.5", cost = 300, requires = "tier_silver", effect = { kind = "cashMult", mult = 1.5 } },
	{
		id = "tier_gold",
		name = "Gold Ore",
		cost = 500,
		requires = "tier_silver",
		effect = { kind = "tier", tier = 3 },
		label = "Gold Ore",
		popup = "GOLD ORE! $30 per cube",
		color = Color3.fromRGB(255, 205, 40),
	},
	{ id = "speed2", name = "Speed 2", cost = 800, requires = "speed1", effect = { kind = "speed", mult = 2 } },
	{ id = "dropper4", name = "Dropper 4", cost = 1300, requires = "dropper3", effect = { kind = "dropper", slots = 4 } },
	{ id = "mult2", name = "Cash x2", cost = 2200, requires = "mult1", effect = { kind = "cashMult", mult = 2 } },
	{
		id = "tier_diamond",
		name = "Diamond Ore",
		cost = 4000,
		requires = "tier_gold",
		effect = { kind = "tier", tier = 4 },
		label = "Diamond Ore",
		popup = "DIAMOND ORE! $75 per cube",
		color = Color3.fromRGB(80, 235, 255),
	},
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

-- Sanity check: every requirement must reference an existing upgrade id.
for _, upgrade in ipairs(list) do
	if upgrade.requires ~= nil and byId[upgrade.requires] == nil then
		warn("[Upgrades] " .. upgrade.id .. " requires unknown id " .. tostring(upgrade.requires))
	end
end

return {
	list = list,
	byId = byId,
	ores = ores,
	-- Starter grant: 0, so the first two collected $5 cubes earn Dropper 2 (10). Keep Config.STARTING_CASH in sync.
	starterCash = 0,
}
