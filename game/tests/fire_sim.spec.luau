--!strict
-- FireSim: neighbour hashing, spread timing, charring, cooling, levels, spray cone.
-- Numbers mirror ReplicatedStorage/Config/FireConfig.luau so the timings here are the in-game ones.
local Spec = require("./Spec")
local FireSim = require("../ServerScriptService/Lib/Fire/FireSim")

local P = {
	SpreadRadius = 8,
	SpreadHeatPerSecond = 14,
	GrowPerSecond = 6,
	IgniteAt = 40,
	ExtinguishAt = 10,
	CoolPerLitre = 9,
}

local function cell(state: number, heat: number, fuel: number): FireSim.Cell
	return { heat = heat, fuel = fuel, state = state, neighbors = {} }
end

local function sorted(list: { number }): string
	local copy = table.clone(list)
	table.sort(copy)
	return table.concat(copy, ",")
end

Spec.test("buildNeighbors links parts within the radius only", function()
	local n = FireSim.buildNeighbors({
		{ x = 0, y = 0, z = 0 },
		{ x = 8, y = 0, z = 0 },
		{ x = 20, y = 0, z = 0 },
	}, 8)
	Spec.eq(sorted(n[1]), "2", "neighbours of 1")
	Spec.eq(sorted(n[2]), "1", "neighbours of 2")
	Spec.eq(#n[3], 0, "neighbours of 3")
end)

Spec.test("buildNeighbors works across bucket edges and negative coordinates", function()
	local n = FireSim.buildNeighbors({
		{ x = -1, y = 0, z = 0 },
		{ x = 1, y = 0, z = 0 },
		{ x = -1, y = 7, z = 0 },
		{ x = 0, y = 0, z = -30 },
	}, 8)
	Spec.eq(sorted(n[1]), "2,3", "neighbours of 1")
	Spec.eq(sorted(n[2]), "1,3", "neighbours of 2")
	Spec.eq(#n[4], 0, "far cell")
end)

Spec.test("levelFor buckets heat into 1..3 and 0 when not burning", function()
	Spec.eq(FireSim.levelFor(FireSim.BURNING, 40), 1)
	Spec.eq(FireSim.levelFor(FireSim.BURNING, 51), 2)
	Spec.eq(FireSim.levelFor(FireSim.BURNING, 81), 3)
	Spec.eq(FireSim.levelFor(FireSim.IDLE, 90), 0)
	Spec.eq(FireSim.levelFor(FireSim.CHARRED, 90), 0)
end)

Spec.test("a fresh fire ignites an 8-stud neighbour after 15 ticks at 5 Hz (3.0 s)", function()
	local a = cell(FireSim.BURNING, 40, 45)
	local b = cell(FireSim.IDLE, 0, 45)
	a.neighbors = { b }
	b.neighbors = { a }
	local burning = { [a] = true }
	for tick = 1, 14 do
		local lit = FireSim.step(burning, 0.2, P)
		Spec.eq(#lit, 0, `tick {tick} ignitions`)
	end
	local lit = FireSim.step(burning, 0.2, P)
	Spec.eq(#lit, 1, "tick 15 ignitions")
	Spec.truthy(lit[1].from == a and lit[1].to == b, "edge is a -> b")
	Spec.eq(b.state, FireSim.IDLE, "step never changes state itself")
end)

Spec.test("burning cells grow toward 100 heat", function()
	local a = cell(FireSim.BURNING, 40, 45)
	FireSim.step({ [a] = true }, 1, P)
	Spec.near(a.heat, 46)
	for _ = 1, 20 do
		FireSim.step({ [a] = true }, 1, P)
	end
	Spec.eq(a.heat, 100)
end)

Spec.test("a cell out of fuel is reported charred and does not spread", function()
	local a = cell(FireSim.BURNING, 90, 0.1)
	local b = cell(FireSim.IDLE, 39, 45)
	a.neighbors = { b }
	local lit, charred = FireSim.step({ [a] = true }, 0.2, P)
	Spec.eq(#lit, 0, "ignitions")
	Spec.eq(#charred, 1, "charred")
	Spec.truthy(charred[1] == a, "a charred")
	Spec.eq(b.heat, 39, "b got no heat")
end)

Spec.test("two burning neighbours report an idle cell once", function()
	local a = cell(FireSim.BURNING, 40, 45)
	local c = cell(FireSim.BURNING, 40, 45)
	local b = cell(FireSim.IDLE, 39, 45)
	a.neighbors = { b }
	c.neighbors = { b }
	local lit = FireSim.step({ [a] = true, [c] = true }, 0.2, P)
	Spec.eq(#lit, 1, "deduped ignitions")
end)

Spec.test("cool lowers heat by CoolPerLitre and says when the fire is out", function()
	local a = cell(FireSim.BURNING, 40, 45)
	Spec.eq(FireSim.cool(a, 3, P), false, "27 off -> 13, still burning")
	Spec.near(a.heat, 13)
	Spec.eq(FireSim.cool(a, 1, P), true, "9 off -> 4, out")
end)

Spec.test("inCone: in front within range, not behind, not too far, not off-axis", function()
	Spec.eq(FireSim.inCone(10, 0, 0, 1, 0, 0, 28, 0.94), true, "ahead")
	Spec.eq(FireSim.inCone(-10, 0, 0, 1, 0, 0, 28, 0.94), false, "behind")
	Spec.eq(FireSim.inCone(40, 0, 0, 1, 0, 0, 28, 0.94), false, "out of range")
	Spec.eq(FireSim.inCone(10, 10, 0, 1, 0, 0, 28, 0.94), false, "45 degrees off")
	Spec.eq(FireSim.inCone(0, 0, 0, 1, 0, 0, 28, 0.94), true, "at the nozzle")
end)

Spec.test("canIgnite: each instance has its own cap, plus a global safety cap", function()
	Spec.eq(FireSim.canIgnite(0, 120, 0, 400), true, "empty")
	Spec.eq(FireSim.canIgnite(119, 120, 119, 400), true, "one under the instance cap")
	Spec.eq(FireSim.canIgnite(120, 120, 120, 400), false, "instance full")
	Spec.eq(FireSim.canIgnite(3, 120, 400, 400), false, "server full")
end)

Spec.test("a full instance does not stop another instance's fire from spreading", function()
	-- Two instances stepped separately (as FireService does): A is at its cap, B still lights.
	local cap = 2
	local counts = { A = 2, B = 1 }
	local b1 = cell(FireSim.BURNING, 40, 45)
	local b2 = cell(FireSim.IDLE, 39, 45)
	b1.neighbors = { b2 }
	local lit = FireSim.step({ [b1] = true }, 0.2, P)
	Spec.eq(#lit, 1, "B ignition proposed")
	Spec.eq(FireSim.canIgnite(counts.B, cap, counts.A + counts.B, 10), true, "B allowed")
	Spec.eq(FireSim.canIgnite(counts.A, cap, counts.A + counts.B, 10), false, "A blocked")
end)

Spec.test("a doused part is never re-heated by a burning neighbour (put out = stays out)", function()
	local a = cell(FireSim.BURNING, 90, 999)
	local b = cell(FireSim.IDLE, 0, 999)
	b.doused = true
	a.neighbors = { b }
	for _ = 1, 500 do -- 100 s next to a big fire
		local lit = FireSim.step({ [a] = true }, 0.2, P)
		Spec.eq(#lit, 0, "never relit")
	end
	Spec.eq(b.heat, 0, "no heat gained")
end)

Spec.test("hp is 1 at full heat, 0 at ExtinguishAt, and every litre shows", function()
	Spec.eq(FireSim.hp(100, P), 1)
	Spec.eq(FireSim.hp(10, P), 0)
	Spec.eq(FireSim.hp(5, P), 0)
	local c = cell(FireSim.BURNING, 100, 45)
	local before = FireSim.quantize(FireSim.hp(c.heat, P), 0.05)
	FireSim.cool(c, 1.2, P) -- one hose tick
	local after = FireSim.quantize(FireSim.hp(c.heat, P), 0.05)
	Spec.truthy(after < before, "one hose tick changes the replicated hp")
	Spec.eq(FireSim.quantize(0.001, 0.05), 0.05, "still burning never reads 0")
	Spec.eq(FireSim.quantize(0, 0.05), 0)
end)

return Spec.finish()
