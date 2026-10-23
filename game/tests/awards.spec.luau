--!strict
-- Awards: Blame awards, stars and callouts (docs/game/05-content-missions.md §7, docs/game/01-gameplay-systems.md §10).
local Spec = require("./Spec")
local Awards = require("../ServerScriptService/Lib/Blame/Awards")

local function stats(userId: number, helmet: number, over: { [string]: number }?): any
	local s: { [string]: any } = {
		userId = userId,
		helmet = helmet,
		name = `P{userId}`,
		firesOut = 0,
		firesStarted = 0,
		water = 0,
		doors = 0,
		rescued = 0,
		pandas = 0,
		downedOthers = 0,
		timesDowned = 0,
		teammateSprayed = 0,
	}
	for k, v in over or {} do
		s[k] = v
	end
	return s
end

local function byUser(awards: { any }, userId: number): { any }
	local out = {}
	for _, a in awards do
		if a.userId == userId and a.id ~= "scapegoat" then
			table.insert(out, a)
		end
	end
	return out
end

local function find(awards: { any }, id: string): any
	for _, a in awards do
		if a.id == id then
			return a
		end
	end
	return nil
end

Spec.test("no players -> no awards", function()
	Spec.eq(#Awards.build({}, 2), 0)
end)

Spec.test("catalog has 20+ awards with unique ids", function()
	local seen = {}
	local cat = Awards.catalog()
	Spec.truthy(#cat >= 20, `catalog size {#cat}`)
	for _, e in cat do
		Spec.eq(seen[e.id], nil, `duplicate {e.id}`)
		seen[e.id] = true
	end
end)

Spec.test("solo idle player gets Moral Support and 'You are to blame.'", function()
	local list = Awards.build({ stats(1, 1) }, 2)
	Spec.eq(#list, 2, "count")
	Spec.eq(list[1].id, "moral_support")
	Spec.eq(list[2].id, "scapegoat")
	Spec.eq(list[2].title, "You are to blame.")
	Spec.eq(list[2].blame, true)
end)

Spec.test("scapegoat names the helmet in multiplayer, with a blame %", function()
	local list = Awards.build({ stats(1, 1, { firesStarted = 1 }), stats(2, 2, { firesStarted = 3 }) }, 2)
	local s = find(list, "scapegoat")
	Spec.eq(s.title, "Firefighter 02 is to blame.")
	Spec.eq(s.userId, 2)
	Spec.eq(s.blurb, "75% of the blame. Blame score 3.")
	Spec.eq(list[#list].id, "scapegoat", "scapegoat is last")
end)

Spec.test("panda comes first (funniest first)", function()
	local list = Awards.build({ stats(1, 1, { pandas = 1, rescued = 3, firesOut = 9 }) }, 2)
	Spec.eq(list[1].id, "panda")
	Spec.eq(list[1].title, "Panda Whisperer")
end)

Spec.test("max awards per player (scapegoat not counted)", function()
	local s = stats(1, 1, {
		pandas = 1,
		teammateSprayed = 5,
		firesStarted = 5,
		timesDowned = 2,
		doors = 3,
		rescued = 4,
		water = 300,
		firesOut = 9,
		overheats = 2,
		zappedOthers = 1,
	})
	local list = Awards.build({ s }, 2)
	Spec.eq(#byUser(list, 1), 2, "regular awards")
	Spec.eq(list[1].id, "panda")
	Spec.eq(list[2].id, "shocking")
	Spec.truthy(find(list, "scapegoat"), "scapegoat present")
end)

Spec.test("awards spill over to the next best player once someone is full", function()
	local list = Awards.build({
		stats(1, 1, { pandas = 1, teammateSprayed = 9, firesStarted = 9 }),
		stats(2, 2, { firesStarted = 4 }),
	}, 2)
	Spec.eq(find(list, "panda").userId, 1)
	Spec.eq(find(list, "friendly_hose").userId, 1)
	Spec.eq(find(list, "arsonist").userId, 2, "player 1 already holds 2")
end)

Spec.test("every player gets at least one award", function()
	local list = Awards.build({ stats(1, 1, { pandas = 1, firesOut = 9 }), stats(2, 2), stats(3, 3) }, 2)
	for _, uid in { 1, 2, 3 } do
		Spec.truthy(#byUser(list, uid) >= 1, `player {uid}`)
	end
	Spec.eq(byUser(list, 2)[1].id, "moral_support")
end)

Spec.test("did a little and blamed for nothing -> Somehow Competent", function()
	local list = Awards.build({ stats(1, 1, { firesOut = 9 }), stats(2, 2, { firesOut = 2 }) }, 2)
	Spec.eq(byUser(list, 2)[1].id, "somehow_competent")
end)

Spec.test("thresholds: below the minimum gives nothing", function()
	local list = Awards.build({ stats(1, 1, { firesOut = 4, rescued = 1, doors = 1, teammateSprayed = 2, drops = 1 }) }, 2)
	Spec.eq(find(list, "pro"), nil, "pro needs 5")
	Spec.eq(find(list, "hero"), nil, "hero needs 2")
	Spec.eq(find(list, "door_hater"), nil, "door hater needs 2")
	Spec.eq(find(list, "friendly_hose"), nil, "friendly hose needs 3")
	Spec.eq(find(list, "hot_potato"), nil, "hot potato needs 2")
end)

Spec.test("extra ledger stats drive v1.5 awards", function()
	local list = Awards.build({
		stats(1, 1, { overheats = 1 }),
		stats(2, 2, { hosedBy = 4 }),
		stats(3, 3, { dogs = 1, cats = 1 }),
		stats(4, 4, { drops = 3 }),
	}, 2)
	Spec.eq(find(list, "human_torch").userId, 1)
	Spec.eq(find(list, "human_torch").blurb, "Overheated once. Smells like barbecue.")
	Spec.eq(find(list, "car_wash").userId, 2)
	Spec.eq(find(list, "cat").userId, 3)
	Spec.eq(find(list, "good_boy").userId, 3)
	Spec.eq(find(list, "hot_potato").userId, 4)
end)

Spec.test("highest wins; ties go to the lower helmet", function()
	local list = Awards.build({ stats(10, 2, { firesOut = 6 }), stats(11, 1, { firesOut = 6 }), stats(12, 3, { firesOut = 9 }) }, 2)
	Spec.eq(find(list, "pro").userId, 12)
	local tie = Awards.build({ stats(10, 2, { rescued = 3 }), stats(11, 1, { rescued = 3 }) }, 2)
	Spec.eq(find(tie, "hero").userId, 11)
end)

Spec.test("fractional water is floored", function()
	local list = Awards.build({ stats(1, 1, { water = 151.9 }) }, 2)
	Spec.eq(find(list, "hydrant_hugger").value, 151)
end)

Spec.test("blurb includes the value", function()
	local list = Awards.build({ stats(1, 1, { doors = 3 }) }, 2)
	Spec.eq(find(list, "door_hater").blurb, "Broke 3 doors. Some were even locked.")
end)

Spec.test("blame score", function()
	Spec.eq(Awards.blameScore(stats(1, 1, { firesStarted = 2, downedOthers = 1, teammateSprayed = 3, timesDowned = 1 })), 8)
	Spec.eq(Awards.blameScore(stats(1, 1, { drops = 1, zappedOthers = 1, explosions = 1, overheats = 1 })), 11)
end)

Spec.test("stars", function()
	Spec.eq(Awards.stars(4, 0, 5), 1, "burning and nobody saved")
	Spec.eq(Awards.stars(0, 0, 5), 2, "all fires out")
	Spec.eq(Awards.stars(3, 5, 0), 2, "everyone saved")
	Spec.eq(Awards.stars(0, 5, 0), 3, "perfect")
	Spec.eq(Awards.stars(0, 0, 0), 2, "nothing to save does not earn the rescue star")
end)

Spec.test("callouts name helmets and are deterministic", function()
	Spec.eq(Awards.callout("hose", 2, 3, 3), "02 hosed 03 into a pool!")
	Spec.eq(Awards.callout("hose", 2, 3, 3), Awards.callout("hose", 2, 3, 7), "roll wraps")
	Spec.eq(Awards.callout("drop", 1, nil, 0), "01 dropped a civilian! Butterfingers!")
	Spec.truthy(string.find(Awards.callout("zap", 4, 1, -1), "04"), "negative roll ok")
	Spec.eq(Awards.callout("nope", 1, nil, 0), "01 did something blameworthy.")
end)

return Spec.finish()
