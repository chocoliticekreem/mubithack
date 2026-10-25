--!strict
-- MissionFlow: per-instance state machine (Alarm -> Active -> Results -> Done), early ends, stars,
-- rescue marker assignment, and the catalog's star rules all being scorable.
local Spec = require("./Spec")
local Flow = require("../ServerScriptService/Lib/Mission/MissionFlow")
local Missions = require("../ReplicatedStorage/Config/MissionCatalog") :: { any }

local T = { seconds = 180, alarm = 6, intro = 3, results = 15, grace = 10 }
local BUSY = { burning = 3, rescued = 0, trapped = 5, players = 2, alive = 2 }
local CLEAR = { burning = 0, rescued = 5, trapped = 0, players = 2, alive = 2 }

local function joined(t: { string }): string
	return table.concat(t, ",")
end

Spec.test("starts in Alarm", function()
	local run = Flow.new(T, 100)
	Spec.eq(run.state, "Alarm")
	Spec.eq(run.alarmEndsAt, 106)
	Spec.eq(run.introAt, 103)
	Spec.eq(joined(Flow.tick(run, 101, BUSY)), "", "nothing before the intro")
end)

Spec.test("intro: teleport, 3-2-1, ROLL OUT -> Active", function()
	local run = Flow.new(T, 0)
	Spec.eq(joined(Flow.tick(run, 3, BUSY)), "teleport,count3")
	Spec.eq(joined(Flow.tick(run, 4, BUSY)), "count2")
	Spec.eq(joined(Flow.tick(run, 5, BUSY)), "count1")
	Spec.eq(joined(Flow.tick(run, 6, BUSY)), "active")
	Spec.eq(run.state, "Active")
	Spec.eq(run.endsAt, 186)
end)

Spec.test("a late tick still emits every intro event once, in order", function()
	local run = Flow.new(T, 0)
	Spec.eq(joined(Flow.tick(run, 50, BUSY)), "teleport,count3,count2,count1,active")
	Spec.eq(joined(Flow.tick(run, 51, BUSY)), "")
end)

Spec.test("timer runs out -> Results(time) -> Done", function()
	local run = Flow.new(T, 0)
	Flow.tick(run, 6, BUSY)
	Spec.eq(joined(Flow.tick(run, 185, BUSY)), "")
	Spec.eq(joined(Flow.tick(run, 186, BUSY)), "ended")
	Spec.eq(run.state, "Results")
	Spec.eq(run.outcome, "time")
	Spec.eq(Flow.endReason(run.outcome), "time")
	Spec.eq(Flow.elapsed(run, 999), 180)
	Spec.eq(joined(Flow.tick(run, 200, BUSY)), "")
	Spec.eq(joined(Flow.tick(run, 201, BUSY)), "done")
	Spec.eq(run.state, "Done")
end)

Spec.test("all clear ends early, but not inside the grace window", function()
	local run = Flow.new(T, 0)
	Flow.tick(run, 6, CLEAR)
	Spec.eq(joined(Flow.tick(run, 10, CLEAR)), "", "grace")
	Spec.eq(joined(Flow.tick(run, 16, CLEAR)), "ended")
	Spec.eq(run.outcome, "success")
	Spec.eq(Flow.endReason(run.outcome), "allOut")
	Spec.eq(Flow.elapsed(run, 100), 10)
end)

Spec.test("escalation still to come holds the all clear", function()
	local run = Flow.new(T, 0)
	Flow.tick(run, 6, CLEAR)
	local held = { burning = 0, rescued = 5, trapped = 0, players = 2, alive = 2, held = true }
	Spec.eq(joined(Flow.tick(run, 30, held)), "", "held: no success while a wave is pending")
	Spec.eq(joined(Flow.tick(run, 31, CLEAR)), "ended")
	Spec.eq(run.outcome, "success")
end)

Spec.test("escalationDue: on schedule, early after a quiet lull, never twice", function()
	local esc = { { at = 90 }, { at = 180 } }
	local o = { lull = 10, minGap = 30 }
	Spec.eq(Flow.escalationDue(esc, 0, 89, 0, 0, o), false, "not yet")
	Spec.eq(Flow.escalationDue(esc, 0, 90, 0, 0, o), true, "wave 1 on time")
	Spec.eq(Flow.escalationDue(esc, 1, 100, 0, 90, o), false, "wave 2 not yet")
	Spec.eq(Flow.escalationDue(esc, 1, 115, 12, 90, o), false, "quiet, but too soon after wave 1")
	Spec.eq(Flow.escalationDue(esc, 1, 125, 12, 90, o), true, "quiet lull pulls wave 2 forward")
	Spec.eq(Flow.escalationDue(esc, 2, 999, 99, 125, o), false, "every wave fired")
	Spec.eq(Flow.escalationDue(esc, 0, 40, 12, 0, o), true, "all out on arrival: wave 1 comes early")
end)

Spec.test("everyone downed -> wiped; everyone left -> forced", function()
	local run = Flow.new(T, 0)
	Flow.tick(run, 6, BUSY)
	Flow.tick(run, 20, { burning = 3, rescued = 0, trapped = 5, players = 2, alive = 0 })
	Spec.eq(run.outcome, "wiped")
	Spec.eq(Flow.endReason(run.outcome), "forced")
	local gone = Flow.new(T, 0)
	Flow.tick(gone, 6, BUSY)
	Flow.tick(gone, 7, { burning = 3, rescued = 0, trapped = 5, players = 0, alive = 0 })
	Spec.eq(gone.outcome, "forced")
end)

Spec.test("finish() works from Alarm and Active, not after", function()
	local run = Flow.new(T, 0)
	Spec.eq(joined(Flow.finish(run, 2, "forced")), "ended")
	Spec.eq(run.state, "Results")
	Spec.eq(joined(Flow.finish(run, 3, "forced")), "", "already ended")
	Spec.eq(Flow.elapsed(run, 3), 0, "never went active")
	Spec.eq(joined(Flow.tick(run, 17, nil)), "done")
end)

Spec.test("parallel runs are independent", function()
	local a = Flow.new(T, 0)
	local b = Flow.new({ seconds = 60, alarm = 2, intro = 1, results = 5, grace = 0 }, 10)
	Flow.tick(a, 6, BUSY)
	Flow.tick(b, 12, BUSY)
	Flow.tick(b, 72, BUSY)
	Spec.eq(b.state, "Results")
	Spec.eq(a.state, "Active")
	Spec.eq(a.endsAt, 186)
end)

Spec.test("stars: house_fire rules (finish, allOut, allRescued)", function()
	local rules = { { id = "finish" }, { id = "allOut" }, { id = "allRescued" } }
	local n, ids = Flow.stars(rules, { outcome = "success", burningAtEnd = 0, rescued = 5, trapped = 0, elapsed = 90, downs = 2 })
	Spec.eq(n, 3)
	Spec.eq(joined(ids), "finish,allOut,allRescued")
	n = Flow.stars(rules, { outcome = "time", burningAtEnd = 0, rescued = 0, trapped = 1, elapsed = 180, downs = 0, firesOut = 6 })
	Spec.eq(n, 1, "time-out: no finish star, but the fires the squad put out count")
	n = Flow.stars(rules, { outcome = "time", burningAtEnd = 4, rescued = 2, trapped = 3, elapsed = 180, downs = 0 })
	Spec.eq(n, 0, "timer ran out with work left")
	n = Flow.stars(rules, { outcome = "time", burningAtEnd = 0, rescued = 0, trapped = 2, elapsed = 180, downs = 0, firesOut = 0 })
	Spec.eq(n, 0, "time-out with nothing done (the fires burned out on their own) is 0 stars")
	local house = { { id = "allRescued" }, { id = "allOut" }, { id = "buildingSaved", min = 50 } }
	n = Flow.stars(house, { outcome = "time", burningAtEnd = 3, rescued = 0, trapped = 5, elapsed = 300, downs = 0, firesOut = 0 })
	Spec.eq(n, 0, "house_fire time-out with nothing done: no buildingSaved freebie")
	n = Flow.stars(rules, { outcome = "wiped", burningAtEnd = 0, rescued = 5, trapped = 0, elapsed = 50, downs = 4 })
	Spec.eq(n, 0, "a wiped squad earns nothing")
	n = Flow.stars(rules, { outcome = "success", burningAtEnd = 0, rescued = 2, trapped = 0, lost = 1, elapsed = 90, downs = 0 })
	Spec.eq(n, 2, "a toasted animal costs the rescue star")
end)

Spec.test("stars: underTime and noDowns", function()
	local rules = { { id = "finish" }, { id = "underTime", seconds = 150 }, { id = "noDowns" } }
	Spec.eq((Flow.stars(rules, { outcome = "success", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 150, downs = 0 })), 3)
	Spec.eq((Flow.stars(rules, { outcome = "success", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 151, downs = 1 })), 1)
	Spec.eq((Flow.stars(rules, { outcome = "time", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 100, downs = 0 })), 0)
	Spec.eq((Flow.stars({ { id = "bogus" } }, { outcome = "success", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 1, downs = 0 })), 0)
end)

Spec.test("every catalog star rule is one MissionFlow can score; a perfect run earns 3", function()
	local perfect = { outcome = "success", burningAtEnd = 0, rescued = 9, trapped = 0, elapsed = 60, downs = 0 }
	for _, m in Missions do
		local n = Flow.stars(m.stars, perfect :: any)
		Spec.eq(n, 3, `{m.id} perfect stars`)
	end
end)

Spec.test("assignRescues matches marker kinds first, then fills in order", function()
	local markers = { "civilian", "cat", "dog", "floatguy", "dog" }
	local kinds = Flow.assignRescues(markers, {
		{ kind = "Civilian", count = 2 },
		{ kind = "Cat", count = 1 },
		{ kind = "Dog", count = 1 },
		{ kind = "Panda", count = 1 },
	})
	Spec.eq(kinds[1], "Civilian")
	Spec.eq(kinds[2], "Cat")
	Spec.eq(kinds[3], "Dog")
	Spec.eq(kinds[4], "Civilian", "floatguy marker takes the leftover civilian")
	Spec.eq(kinds[5], "Panda", "last leftover")
	local few = Flow.assignRescues({ "", "" }, { { kind = "Dog", count = 1 } })
	Spec.eq(few[1], "Dog")
	Spec.eq(few[2], false, "more markers than rescues")
	local many = Flow.assignRescues({ "cat" }, { { kind = "Civilian", count = 3 } })
	Spec.eq(#many, 1, "more rescues than markers are dropped")
end)

-- v2 dispatch -----------------------------------------------------------------------------------------

local D = { seconds = 180, travel = 60, fastArrival = 45, arrivalBonus = 20, alarm = 0, intro = 0, results = 15, grace = 10 }
local function obsAt(arrived: boolean, o: { [string]: any }?): any
	local base = table.clone(BUSY) :: any
	base.arrived = arrived
	for k, v in o or {} do
		base[k] = v
	end
	return base
end

Spec.test("siteSupports parses comma lists (spaces, case)", function()
	Spec.eq(Flow.siteSupports("house_fire", "house_fire"), true)
	Spec.eq(Flow.siteSupports(" school_alarm , House_Fire ", "house_fire"), true)
	Spec.eq(Flow.siteSupports("house_fire_big", "house_fire"), false, "no prefix match")
	Spec.eq(Flow.siteSupports("", "house_fire"), false)
	Spec.eq(Flow.siteSupports(nil, "house_fire"), false)
end)

Spec.test("pickSite: nearest free matching site", function()
	local sites = {
		{ id = "far", types = "house_fire", busy = false, dist = 900 },
		{ id = "near", types = "house_fire", busy = false, dist = 200 },
		{ id = "school", types = "school_alarm", busy = false, dist = 50 },
		{ id = "busy", types = "house_fire", busy = true, dist = 10 },
	}
	Spec.eq(Flow.pickSite(sites, "house_fire"), "near")
	Spec.eq(Flow.pickSite(sites, "school_alarm"), "school")
	Spec.eq(Flow.pickSite(sites, "panda_zoo"), nil, "no site for the mission")
	sites[2].busy = true
	Spec.eq(Flow.pickSite(sites, "house_fire"), "far", "next nearest once the nearest is busy")
	sites[1].busy = true
	Spec.eq(Flow.pickSite(sites, "house_fire"), nil, "all busy")
	Spec.eq(Flow.pickSite({}, "house_fire"), nil)
end)

Spec.test("pickSite: ties inside the band go to roll; outside it never", function()
	local sites = {
		{ id = "b", types = "house_fire", busy = false, dist = 105 },
		{ id = "a", types = "house_fire", busy = false, dist = 100 },
		{ id = "c", types = "house_fire", busy = false, dist = 500 },
	}
	Spec.eq(Flow.pickSite(sites, "house_fire", 10), "a", "no roll: nearest")
	local seen = 0
	Spec.eq(
		Flow.pickSite(sites, "house_fire", 10, function(n)
			seen = n
			return n
		end),
		"b"
	)
	Spec.eq(seen, 2, "c is outside the tie band")
	Spec.eq(Flow.pickSite(sites, "house_fire", 0, function(n)
		return n
	end), "a", "no band, no tie")
	Spec.eq(Flow.pickSite(sites, "house_fire", 1000, function(_n)
		return 99
	end), "c", "roll is clamped")
	local exact = { { id = "y", types = "house_fire", busy = false, dist = 5 }, { id = "x", types = "house_fire", busy = false, dist = 5 } }
	Spec.eq(Flow.pickSite(exact, "house_fire"), "x", "exact tie, no roll: lowest id")
end)

Spec.test("travelAllowance clamps distance / speed", function()
	local cfg = { speed = 40, min = 20, max = 90 }
	Spec.eq(Flow.travelAllowance(0, cfg), 20)
	Spec.eq(Flow.travelAllowance(2000, cfg), 50)
	Spec.eq(Flow.travelAllowance(99999, cfg), 90)
	Spec.eq(Flow.travelAllowance(100, { speed = 0, min = 0, max = 60 }), 60)
end)

Spec.test("dispatch: timer runs from dispatch, Dispatched until arrival", function()
	local run = Flow.newDispatch(D, 100)
	Spec.eq(run.state, "Dispatched")
	Spec.eq(run.endsAt, 340, "180 + 60 travel")
	Spec.eq(joined(Flow.tick(run, 110, obsAt(false))), "")
	Spec.eq(joined(Flow.tick(run, 130, obsAt(false, { burning = 0, trapped = 0 }))), "", "no all-clear before arrival")
	Spec.eq(run.state, "Dispatched")
	Spec.eq(Flow.elapsed(run, 130), 0)
	Spec.eq(Flow.sinceDispatch(run, 130), 30)
end)

Spec.test("dispatch: slow arrival -> Active, no bonus", function()
	local run = Flow.newDispatch(D, 0)
	Spec.eq(joined(Flow.tick(run, 90, obsAt(true))), "arrived")
	Spec.eq(run.state, "Active")
	Spec.eq(run.fast, false)
	Spec.eq(run.arrivedAt, 90)
	Spec.eq(run.endsAt, 240)
	Spec.eq(joined(Flow.tick(run, 91, obsAt(true))), "", "arrived fires once")
	Spec.eq(joined(Flow.tick(run, 240, obsAt(true))), "ended")
	Spec.eq(run.outcome, "time")
	Spec.eq(Flow.elapsed(run, 999), 150)
	Spec.eq(joined(Flow.tick(run, 255, nil)), "done")
end)

Spec.test("dispatch: fast arrival adds the bonus; all clear after grace", function()
	local run = Flow.newDispatch(D, 0)
	Spec.eq(joined(Flow.tick(run, 45, obsAt(true))), "arrived")
	Spec.eq(run.fast, true)
	Spec.eq(run.endsAt, 260, "240 + 20 bonus")
	local clear = table.clone(CLEAR) :: any
	clear.arrived = true
	Spec.eq(joined(Flow.tick(run, 50, clear)), "", "grace")
	Spec.eq(joined(Flow.tick(run, 55, clear)), "ended")
	Spec.eq(run.outcome, "success")
	Spec.eq(Flow.elapsed(run, 99), 10)
	Spec.eq(Flow.sinceDispatch(run, 999), 55)
end)

Spec.test("dispatch: never arriving runs out the clock; leaving or wiping ends it", function()
	local run = Flow.newDispatch(D, 0)
	Spec.eq(joined(Flow.tick(run, 239, obsAt(false))), "")
	Spec.eq(joined(Flow.tick(run, 240, obsAt(false))), "ended")
	Spec.eq(run.outcome, "time")
	Spec.eq(Flow.elapsed(run, 300), 0, "never active")
	local gone = Flow.newDispatch(D, 0)
	Flow.tick(gone, 5, obsAt(false, { players = 0, alive = 0 }))
	Spec.eq(gone.outcome, "forced")
	local wiped = Flow.newDispatch(D, 0)
	Flow.tick(wiped, 5, obsAt(true, { alive = 0 }))
	Spec.eq(wiped.outcome, "wiped", "wipe beats arrival")
	local aborted = Flow.newDispatch(D, 0)
	Spec.eq(joined(Flow.finish(aborted, 3, "forced")), "ended", "finish works from Dispatched")
end)

Spec.test("dispatch and instance runs coexist", function()
	local a = Flow.newDispatch(D, 0)
	local b = Flow.newDispatch(D, 10)
	Flow.tick(a, 20, obsAt(true))
	Flow.tick(b, 20, obsAt(false))
	Spec.eq(a.state, "Active")
	Spec.eq(b.state, "Dispatched")
	local v1 = Flow.new(T, 0)
	Spec.eq(v1.dispatch, false)
	Spec.eq(joined(Flow.tick(v1, 6, BUSY)), "teleport,count3,count2,count1,active", "v1.5 path unchanged")
end)

-- squad-size scaling (GameConfig.FireScalePerPlayer = 0.35, MinArrivalFires = 3, RescuesPerExtraPlayers = 2)
Spec.test("scaledFires: solo keeps the catalog count, bigger squads get more fire zones", function()
	Spec.eq(Flow.scaledFires(4, 1, 0.35, 3), 4, "solo house fire")
	Spec.eq(Flow.scaledFires(2, 1, 0.35, 3), 3, "minimum fire zones on arrival")
	Spec.eq(Flow.scaledFires(4, 2, 0.35, 3), 5, "duo: 4 * 1.35 = 5.4")
	Spec.eq(Flow.scaledFires(4, 4, 0.35, 3), 8, "4 players: 4 * 2.05 = 8.2")
	Spec.eq(Flow.scaledFires(4, 8, 0.35, 3), 14, "8 players: 4 * 3.45 = 13.8")
	Spec.eq(Flow.scaledFires(4, 0, 0.35, 3), 4, "0 players counts as solo")
	Spec.eq(Flow.scaledFires(4, 6, 0, 3), 4, "scaling off")
	local prev = 0
	for n = 1, 8 do
		local f = Flow.scaledFires(3, n, 0.35, 3)
		Spec.truthy(f >= prev, `monotonic at {n}`)
		prev = f
	end
end)

Spec.test("scaledRescues: +1 per 2 extra players on the first kind, never mutates the catalog", function()
	local base = { { kind = "Civilian", count = 2 }, { kind = "Cat", count = 1 } }
	local solo = Flow.scaledRescues(base, 1, 2)
	Spec.eq(solo[1].count, 2, "solo unchanged")
	Spec.eq(Flow.scaledRescues(base, 2, 2)[1].count, 2, "one extra player: no extra rescue yet")
	Spec.eq(Flow.scaledRescues(base, 3, 2)[1].count, 3, "two extra players: +1")
	Spec.eq(Flow.scaledRescues(base, 8, 2)[1].count, 5, "seven extra players: +3")
	Spec.eq(Flow.scaledRescues(base, 8, 2)[2].count, 1, "other kinds untouched")
	Spec.eq(base[1].count, 2, "catalog entry not mutated")
	Spec.eq(Flow.scaledRescues({}, 5, 2)[1].kind, "Civilian", "empty list gets civilians")
	Spec.eq(#Flow.scaledRescues(base, 8, 0), 2, "scaling off")
	Spec.eq(Flow.scaledRescues(base, 8, 0)[1].count, 2, "scaling off: same count")
end)

Spec.test("spreadPick: far from burning fires and each other, never on a rescue spawn", function()
	local function p(x: number, y: number, z: number)
		return { x = x, y = y, z = z }
	end
	-- a two-floor building: ground floor x 0..40, upper floor (y 12) same footprint
	local cands = { p(2, 0, 0), p(4, 0, 0), p(38, 0, 0), p(2, 12, 0), p(38, 12, 0), p(20, 0, 0) }
	local burning = { p(0, 0, 0) }
	local rescue = { p(38, 12, 0) }
	local picks = Flow.spreadPick(cands, burning, rescue, 8, 3)
	Spec.eq(#picks, 3, "three picks")
	Spec.eq(picks[1], 3, "first pick: the far ground-floor corner")
	Spec.truthy(not table.find(picks, 5), "never next to the rescue spawn")
	Spec.truthy(table.find(picks, 4) ~= nil, "uses the other floor")
	Spec.truthy(not table.find(picks, 2) or not table.find(picks, 1), "doesn't stack two picks by the burning fire")
	Spec.eq(#Flow.spreadPick(cands, burning, rescue, 8, 99), 5, "every allowed candidate at most once")
	Spec.eq(#Flow.spreadPick({}, burning, rescue, 8, 3), 0, "no candidates")
	Spec.eq(Flow.spreadPick(cands, {}, {}, 8, 1)[1], 1, "nothing burning: ties keep the caller's order")
end)

Spec.test("capRescues: rookie calls keep at most N, round robin over the kinds", function()
	local list = { { kind = "Civilian", count = 2 }, { kind = "Cat", count = 1 }, { kind = "Dog", count = 1 } }
	local two = Flow.capRescues(list, 2)
	Spec.eq(#two, 2)
	Spec.eq(two[1].kind .. two[1].count .. two[2].kind .. two[2].count, "Civilian1Cat1", "one of each, catalog order")
	local four = Flow.capRescues(list, 4)
	local n = 0
	for _, r in four do
		n += r.count
	end
	Spec.eq(n, 4, "all four when the cap allows")
	Spec.eq(#Flow.capRescues(list, 0), 0, "cap 0 = nobody")
	Spec.eq(Flow.capRescues({ { kind = "Panda", count = 1 } }, 5)[1].count, 1, "never more than the catalog")
	Spec.eq(list[1].count, 2, "input untouched")
end)

return Spec.finish()
