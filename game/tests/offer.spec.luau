--!strict
-- OfferRules: which pass to offer after a call, and the frequency caps.
local Spec = require("./Spec")
local Rules = require("../ServerScriptService/Lib/Monetization/OfferRules")

local CFG = { ResultsEvery = 2, MaxPerSession = 4, MinGapSeconds = 150, MaxDeclines = 2, LobbyCardsPerSession = 1, RescueHero = 2 }

local function ctx(over: { [string]: any }?): any
	local c: any = {
		moment = "results",
		passes = {
			{ key = "UnlimitedFoam", forSale = true, owned = false },
			{ key = "PremiumPass", forSale = true, owned = false },
		},
		rookie = false,
		completed = 2,
		shown = 0,
		lobbyShown = 0,
		sinceLast = math.huge,
		declined = {},
		rotation = 0,
		signals = { foamEmpty = false, rescued = 0, levelUp = false, passXp = 0 },
	}
	for k, v in over or {} do
		c[k] = v
	end
	return c
end

Spec.test("every 2nd call only", function()
	Spec.eq(Rules.pick(ctx({ completed = 1 }), CFG), nil)
	Spec.eq(Rules.pick(ctx({ completed = 2 }), CFG), "UnlimitedFoam")
	Spec.eq(Rules.pick(ctx({ completed = 3 }), CFG), nil)
	Spec.eq(Rules.pick(ctx({ completed = 4 }), CFG) ~= nil, true)
end)

Spec.test("never on a rookie call", function()
	Spec.eq(Rules.pick(ctx({ rookie = true }), CFG), nil)
end)

Spec.test("session cap and gap", function()
	Spec.eq(Rules.pick(ctx({ shown = 4 }), CFG), nil)
	Spec.eq(Rules.pick(ctx({ sinceLast = 60 }), CFG), nil)
	Spec.eq(Rules.pick(ctx({ sinceLast = 200 }), CFG) ~= nil, true)
end)

Spec.test("never offers an owned or unsold pass", function()
	local c = ctx({ passes = {
		{ key = "UnlimitedFoam", forSale = true, owned = true },
		{ key = "PremiumPass", forSale = false, owned = false },
	} })
	Spec.eq(Rules.pick(c, CFG), nil)
	local c2 = ctx({ passes = {
		{ key = "UnlimitedFoam", forSale = true, owned = true },
		{ key = "PremiumPass", forSale = true, owned = false },
	}, signals = { foamEmpty = true } })
	Spec.eq(Rules.pick(c2, CFG), "PremiumPass", "foam signal but foam owned")
end)

Spec.test("relevance: foam, level, rescue, pass xp", function()
	local k, r = Rules.pick(ctx({ signals = { foamEmpty = true, levelUp = true } }), CFG)
	Spec.eq(k, "UnlimitedFoam")
	Spec.eq(r, "foam")
	k, r = Rules.pick(ctx({ signals = { levelUp = true } }), CFG)
	Spec.eq(k, "PremiumPass")
	Spec.eq(r, "level")
	k, r = Rules.pick(ctx({ signals = { rescued = 3 } }), CFG)
	Spec.eq(r, "rescue")
	k, r = Rules.pick(ctx({ rotation = 1, signals = { passXp = 40 } }), CFG)
	Spec.eq(k, "PremiumPass")
	Spec.eq(r, "passxp")
end)

Spec.test("rotation and declines", function()
	Spec.eq(Rules.pick(ctx({ rotation = 0 }), CFG), "UnlimitedFoam")
	Spec.eq(Rules.pick(ctx({ rotation = 1 }), CFG), "PremiumPass")
	Spec.eq(Rules.pick(ctx({ rotation = 0, declined = { UnlimitedFoam = 2 } }), CFG), "PremiumPass")
	Spec.eq(Rules.pick(ctx({ declined = { UnlimitedFoam = 2, PremiumPass = 2 } }), CFG), nil)
end)

Spec.test("lobby card: level up only, once", function()
	Spec.eq(Rules.pick(ctx({ moment = "lobby" }), CFG), nil)
	local k, r = Rules.pick(ctx({ moment = "lobby", completed = 1, signals = { levelUp = true } }), CFG)
	Spec.eq(k, "PremiumPass")
	Spec.eq(r, "level")
	Spec.eq(Rules.pick(ctx({ moment = "lobby", lobbyShown = 1, signals = { levelUp = true } }), CFG), nil)
	Spec.eq(Rules.pick(ctx({ moment = "lobby", completed = 0, signals = { levelUp = true } }), CFG), nil)
end)

Spec.test("field is a constant pair", function()
	Spec.eq(Rules.field("PremiumPass", "results"), "PremiumPass_results")
end)

Spec.test("big fire -> Helicopter (results only, when on sale)", function()
	local passes = {
		{ key = "UnlimitedFoam", forSale = true, owned = false },
		{ key = "PremiumPass", forSale = true, owned = false },
		{ key = "Helicopter", forSale = true, owned = false },
	}
	local k, r = Rules.pick(ctx({ passes = passes, signals = { bigFire = true } }), CFG)
	Spec.eq(k, "Helicopter")
	Spec.eq(r, "bigfire")
	k = Rules.pick(ctx({ passes = passes, signals = { bigFire = true, foamEmpty = true } }), CFG)
	Spec.eq(k, "UnlimitedFoam", "foam ran out is more relevant")
	local unsold = table.clone(passes)
	unsold[3] = { key = "Helicopter", forSale = false, owned = false }
	k = Rules.pick(ctx({ passes = unsold, signals = { bigFire = true } }), CFG)
	Spec.eq(k ~= "Helicopter", true, "id 0 / not for sale: never offered")
	k = Rules.pick(ctx({ moment = "lobby", passes = passes, signals = { bigFire = true, levelUp = true } }), CFG)
	Spec.eq(k, "PremiumPass", "the lobby card stays the level-up card")
end)

return Spec.finish()
