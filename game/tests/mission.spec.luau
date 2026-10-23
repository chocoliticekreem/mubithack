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
	n = Flow.stars(rules, { outcome = "time", burningAtEnd = 0, rescued = 0, trapped = 0, elapsed = 180, downs = 0 })
	Spec.eq(n, 2, "no rescue star when nobody was rescued")
	n = Flow.stars(rules, { outcome = "time", burningAtEnd = 4, rescued = 2, trapped = 3, elapsed = 180, downs = 0 })
	Spec.eq(n, 1, "timer ran out with work left")
	n = Flow.stars(rules, { outcome = "wiped", burningAtEnd = 0, rescued = 5, trapped = 0, elapsed = 50, downs = 4 })
	Spec.eq(n, 0, "a wiped squad earns nothing")
end)

Spec.test("stars: underTime and noDowns", function()
	local rules = { { id = "finish" }, { id = "underTime", seconds = 150 }, { id = "noDowns" } }
	Spec.eq((Flow.stars(rules, { outcome = "success", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 150, downs = 0 })), 3)
	Spec.eq((Flow.stars(rules, { outcome = "success", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 151, downs = 1 })), 1)
	Spec.eq((Flow.stars(rules, { outcome = "time", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 100, downs = 0 })), 2)
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

return Spec.finish()
