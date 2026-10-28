--!strict
-- CallRamp (short early calls) + MissionFlow's "ALL DONE! 3..2..1" end (timing.doneDelay).
local Spec = require("./Spec")
local CallRamp = require("../ReplicatedStorage/Lib/Mission/CallRamp")
local Cfg = require("../ReplicatedStorage/Config/CallRampConfig") :: any
local Flow = require("../ServerScriptService/Lib/Mission/MissionFlow")
local Missions = require("../ReplicatedStorage/Config/MissionCatalog") :: { any }

Spec.test("index: the squad's newest player decides the call number", function()
	Spec.eq(CallRamp.index({ 0 }), 1)
	Spec.eq(CallRamp.index({ 5, 1, 9 }), 2)
	Spec.eq(CallRamp.index({}), 1, "no profile yet = a brand-new player")
end)

Spec.test("calls 1-3 are small and short; later calls ramp up; call 6+ is the catalog call", function()
	for i = 1, 3 do
		local t = CallRamp.tier(Cfg, i)
		Spec.truthy(t ~= nil, `tier {i}`)
		Spec.truthy(t.ArrivalFires >= 3 and t.ArrivalFires <= 5, "3-5 fires")
		Spec.truthy(t.FireCap <= 5, "never more than 5 burning")
		Spec.eq(t.MaxRescues, 1, "at most 1 rescue")
		Spec.truthy(t.Waves <= 1, "at most 1 wave")
		Spec.truthy(t.Seconds <= 100, "short on-scene timer")
		Spec.eq(t.TimeoutIsWin, true, "time out = CALL COMPLETE, never a fail")
		Spec.eq(t.NearestSite, true, "a short drive")
		Spec.eq(t.NoRegrow, true, "a fire put out is never replaced by spread")
	end
	local prev = 0
	for i = 1, #Cfg.Tiers do
		local t = CallRamp.tier(Cfg, i)
		Spec.truthy(t.Seconds >= prev, "timers only grow")
		prev = t.Seconds
	end
	Spec.eq(CallRamp.tier(Cfg, #Cfg.Tiers + 1), nil)
	Spec.eq(CallRamp.tier(Cfg, 0), nil)
end)

Spec.test("phases: a tier keeps at most Waves short waves, no surprise rescues, no set pieces unless asked", function()
	local house = nil
	for _, m in Missions do
		if m.id == "house_fire" then
			house = m
		end
	end
	Spec.truthy(house and #house.escalation >= 2, "house fire escalates")
	Spec.eq(#CallRamp.phases(CallRamp.tier(Cfg, 1), house.escalation), 0)
	local two = CallRamp.phases(CallRamp.tier(Cfg, 2), house.escalation)
	Spec.eq(#two, 1)
	Spec.truthy(two[1].fires <= 2, "2 fires")
	Spec.eq(two[1].at, 35)
	Spec.eq(two[1].rescue, nil)
	Spec.eq(two[1].setPiece, nil)
	Spec.truthy(house.escalation[1].fires ~= nil, "catalog untouched")
	local five = CallRamp.phases(CallRamp.tier(Cfg, 5), { { at = 90, fires = 6, setPiece = "flashover" }, { at = 200, fires = 6 }, { at = 300, fires = 6 } })
	Spec.eq(#five, 2)
	Spec.eq(five[1].setPiece, "flashover", "SetPieces keeps them")
	Spec.eq(five[2].at, 200)
end)

Spec.test("cap grows with the squad; bucket is a small constant set", function()
	Spec.eq(CallRamp.cap({ FireCap = 4 }, 1, 2), 4)
	Spec.eq(CallRamp.cap({ FireCap = 4 }, 3, 2), 8)
	Spec.eq(CallRamp.cap({}, 3, 2), nil)
	Spec.eq(CallRamp.bucket(1), "1")
	Spec.eq(CallRamp.bucket(5), "5")
	Spec.eq(CallRamp.bucket(6), "6-10")
	Spec.eq(CallRamp.bucket(40), "11+")
end)

Spec.test("chip: fires, then the rescue, then a coming wave, then ALL DONE countdown", function()
	Spec.eq(CallRamp.chip({ fires = 2, rescues = 1, wave = true, doneAt = 0, now = 0 }), "fires")
	local k, n = CallRamp.chip({ fires = 0, rescues = 1, wave = false, doneAt = 0, now = 0 })
	Spec.eq(k, "rescue")
	Spec.eq(n, 1)
	Spec.eq(CallRamp.chip({ fires = 0, rescues = 0, wave = true, doneAt = 0, now = 0 }), "wave")
	local d, left = CallRamp.chip({ fires = 0, rescues = 0, wave = false, doneAt = 13, now = 10.2 })
	Spec.eq(d, "done")
	Spec.eq(left, 3)
	Spec.eq(CallRamp.chip({ fires = 0, rescues = 0, wave = false, doneAt = 0, now = 0 }), "none")
end)

local CLEAR = { burning = 0, rescued = 1, trapped = 0, players = 1, alive = 1 }
local BUSY = { burning = 1, rescued = 0, trapped = 0, players = 1, alive = 1 }

Spec.test("doneDelay: all clear counts down, then success; a flare-up cancels it", function()
	local run = Flow.new({ seconds = 100, alarm = 0, intro = 0, results = 5, grace = 0, doneDelay = 3 }, 0)
	Flow.tick(run, 0, BUSY) -- Active
	Spec.eq(run.state, "Active")
	Spec.eq(table.concat(Flow.tick(run, 10, CLEAR), ","), "alldone")
	Spec.eq(run.doneAt, 13)
	Spec.eq(#Flow.tick(run, 11, CLEAR), 0, "counting")
	Spec.eq(table.concat(Flow.tick(run, 12, BUSY), ","), "notdone")
	Spec.eq(run.doneAt, 0)
	Flow.tick(run, 20, CLEAR)
	Spec.eq(table.concat(Flow.tick(run, 23, CLEAR), ","), "ended")
	Spec.eq(run.outcome, "success")
end)

Spec.test("doneDelay: the timer running out mid-countdown is still a success", function()
	local run = Flow.new({ seconds = 10, alarm = 0, intro = 0, results = 5, grace = 0, doneDelay = 3 }, 0)
	Flow.tick(run, 0, BUSY)
	Flow.tick(run, 9, CLEAR)
	Flow.tick(run, 10.5, CLEAR)
	Spec.eq(run.outcome, "success")
end)

Spec.test("no doneDelay: ends on the same tick as before", function()
	local run = Flow.new({ seconds = 10, alarm = 0, intro = 0, results = 5, grace = 0 }, 0)
	Flow.tick(run, 0, BUSY)
	Spec.eq(table.concat(Flow.tick(run, 2, CLEAR), ","), "ended")
end)

return Spec.finish()
