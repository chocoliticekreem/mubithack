--!strict
-- Lib/Social/TeamRules: COMBO / TEAMWORK / squad streak / BEST TEAMMATE / hero board maths.
local Spec = require("./Spec")
local TeamRules = require("../ReplicatedStorage/Lib/Social/TeamRules")

Spec.test("comboMult: solo is untouched, each extra hose +50%, capped", function()
	Spec.eq(TeamRules.comboMult(0), 1)
	Spec.eq(TeamRules.comboMult(1), 1, "solo never changes")
	Spec.eq(TeamRules.comboMult(2), 1.5)
	Spec.eq(TeamRules.comboMult(3), 2)
	Spec.eq(TeamRules.comboMult(4), 2.5)
	Spec.eq(TeamRules.comboMult(8), 2.5, "cap")
end)

Spec.test("activeSprayers: only hoses inside the combo window", function()
	local w = TeamRules.Cfg.ComboWindow
	Spec.eq(TeamRules.activeSprayers({}, 10), 0)
	Spec.eq(TeamRules.activeSprayers({ a = 10, b = 10 - w / 2 }, 10), 2)
	Spec.eq(TeamRules.activeSprayers({ a = 10, b = 10 - w - 0.01 }, 10), 1, "b stopped spraying")
end)

Spec.test("squadKey is order-free", function()
	Spec.eq(TeamRules.squadKey({ 3, 1, 2 }), "1,2,3")
	Spec.eq(TeamRules.squadKey({ 2, 3, 1 }), TeamRules.squadKey({ 1, 2, 3 }))
	Spec.eq(TeamRules.squadKey({}), "")
end)

Spec.test("nextStreak: same squad + win grows, new squad restarts, a loss resets", function()
	Spec.eq(TeamRules.nextStreak(0, nil, "1,2", true), 1)
	Spec.eq(TeamRules.nextStreak(1, "1,2", "1,2", true), 2)
	Spec.eq(TeamRules.nextStreak(4, "1,2", "1,2,3", true), 1, "someone joined: a new squad")
	Spec.eq(TeamRules.nextStreak(4, "1,2", "1,2", false), 0)
end)

Spec.test("best: needs 2+ players and a positive score; teamwork and combos count most", function()
	Spec.eq(TeamRules.best({ { userId = 1, rescued = 5 } }), nil, "solo: no BEST TEAMMATE")
	Spec.eq(TeamRules.best({ { userId = 1 }, { userId = 2 } }), nil, "nobody did anything")
	Spec.eq(TeamRules.best({ { userId = 1, firesOut = 3 }, { userId = 2, combos = 1 } }), 1, "1 combo = 3 fires: a tie goes to the lower id")
	Spec.eq(TeamRules.best({ { userId = 1, firesOut = 3 }, { userId = 2, combos = 2 } }), 2)
	Spec.eq(TeamRules.best({ { userId = 1, firesOut = 2 }, { userId = 2, teamwork = 1 } }), 2)
	Spec.eq(TeamRules.best({ { userId = 5, rescued = 1, firesOut = 1 }, { userId = 2, firesOut = 3 } }), 5, "tie: more rescues")
	Spec.eq(TeamRules.score({ userId = 1, combos = 1, teamwork = 1, rescued = 1, firesOut = 1 }), 3 + 4 + 2 + 1)
end)

Spec.test("dayId: one key per UTC day", function()
	Spec.eq(TeamRules.dayId(0), 0)
	Spec.eq(TeamRules.dayId(86399), 0)
	Spec.eq(TeamRules.dayId(86400), 1)
end)

Spec.test("mergeTop: value desc, zeroes dropped, ties by lower id, first n", function()
	local top = TeamRules.mergeTop({
		{ userId = 9, value = 3 },
		{ userId = 2, value = 7 },
		{ userId = 4, value = 0 },
		{ userId = 1, value = 3 },
	}, 2)
	Spec.eq(#top, 2)
	Spec.eq(top[1].userId, 2)
	Spec.eq(top[2].userId, 1)
end)

return Spec.finish()
