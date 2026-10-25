--!strict
-- TwistRules: per-call twist pick (weighted, no repeats, built-in mission twists) and the speed-run record.
local Spec = require("./Spec")
local Rules = require("../ServerScriptService/Lib/Twist/TwistRules")

local W = { cat = 1, windy = 1, rainy = 1, night = 1, news = 1, raccoon = 1 }

Spec.test("order: only weights > 0, sorted", function()
	local o = Rules.order({ b = 1, a = 2, off = 0 })
	Spec.eq(#o, 2)
	Spec.eq(o[1], "a")
	Spec.eq(o[2], "b")
end)

Spec.test("pick covers every twist, equal odds", function()
	local seen: { [string]: number } = {}
	for i = 0, 599 do
		local id = Rules.pick(W, i / 600) :: string
		seen[id] = (seen[id] or 0) + 1
	end
	for id in W do
		Spec.eq(seen[id], 100, id)
	end
end)

Spec.test("pick never repeats the last twist when something else can roll", function()
	for i = 0, 99 do
		Spec.eq(Rules.pick(W, i / 100, "night") ~= "night", true)
	end
	Spec.eq(Rules.pick({ night = 1 }, 0.5, "night"), "night", "the only twist still rolls")
end)

Spec.test("pick: nothing enabled -> nil; r01 of 1 is safe", function()
	Spec.eq(Rules.pick({ cat = 0 }, 0.5), nil)
	Spec.eq(Rules.pick(W, 1) ~= nil, true)
end)

Spec.test("builtIn: a crazy call announces its own twist", function()
	local B = { "grease_fire", "gas_leak", "pileup", "cat_tree" }
	Spec.eq(Rules.builtIn({ "explosion", "gas_leak" }, B), "gas_leak")
	Spec.eq(Rules.builtIn({ "explosion" }, B), nil)
	Spec.eq(Rules.builtIn(nil, B), nil)
end)

Spec.test("record: only all-clear calls count, lower is better", function()
	local best, new = Rules.record(nil, 150, true)
	Spec.eq(best, 150)
	Spec.eq(new, true)
	best, new = Rules.record(150, 170, true)
	Spec.eq(best, 150)
	Spec.eq(new, false)
	best, new = Rules.record(150, 120, false)
	Spec.eq(best, 150, "a lost call never sets the record")
	Spec.eq(new, false)
	best, new = Rules.record(150, 120, true)
	Spec.eq(best, 120)
	Spec.eq(new, true)
	best, new = Rules.record(nil, 0, true)
	Spec.eq(best, nil)
	Spec.eq(new, false)
end)

Spec.test("clock", function()
	Spec.eq(Rules.clock(125), "2:05")
	Spec.eq(Rules.clock(-3), "0:00")
end)

return Spec.finish()
