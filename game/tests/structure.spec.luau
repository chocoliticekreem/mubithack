--!strict
-- Structure: classification, support graph, burn/char damage, failures, windows, integrity, shell.
local Spec = require("./Spec")
local S = require("../ServerScriptService/Lib/Fire/Structure")
local MissionFlow = require("../ServerScriptService/Lib/Mission/MissionFlow")

local cfg = {
	GroundTolerance = 2.5,
	SupportGap = 1.5,
	SupportDrop = 8,
	SupportReach = 6,
	MaxSupports = 8,
	Weight = { wall = 1, partition = 0.5, roof = 1, floor = 0.8, ground = 0.3, window = 0 },
	BurnRate = 0.02,
	CharredHp = 0.15,
	FailHp = { roof = 0.2, floor = 0.2 },
	SupportMin = 0.4,
	CharredFallChance = { wall = 0.015, partition = 0.05 },
	WindowHeatRadius = 10,
	ShatterHeat = 6,
	TotalLossAt = 15,
	SavedAt = 50,
}

local function box(kind: any, x: number, y: number, z: number, hx: number, hy: number, hz: number): S.Box
	return { kind = kind, x = x, y = y, z = z, hx = hx, hy = hy, hz = hz }
end

-- A one-room house: ground floor (1), two walls (2, 3) 12 tall, a roof slab (4) on top, a window (5)
-- in wall 2, an upper floor tile (6) on the walls.
local function house(): S.Struct
	return S.new({
		box("floor", 0, 0.5, 0, 8, 0.5, 8), -- 1 ground
		box("wall", -8, 7, 0, 0.5, 6, 8), -- 2
		box("wall", 8, 7, 0, 0.5, 6, 8), -- 3
		box("roof", 0, 15, 0, 9, 2, 8), -- 4
		box("window", -8, 6, 0, 0.15, 2, 2), -- 5
		box("floor", 0, 12.5, 0, 7.5, 0.5, 8), -- 6 upper floor
	}, cfg)
end

local function never(): number
	return 1
end

Spec.test("classify by part name", function()
	Spec.eq(S.classify("Wall_3", false), "wall")
	Spec.eq(S.classify("Partition_1", false), "partition")
	Spec.eq(S.classify("Roof", false), "roof")
	Spec.eq(S.classify("CeilingPanel", false), "roof")
	Spec.eq(S.classify("Gable", false), "roof")
	Spec.eq(S.classify("Floor2", false), "floor")
	Spec.eq(S.classify("Window", true), "window")
	Spec.eq(S.classify("Sofa", false), nil)
	Spec.eq(S.classify("Foundation", false), nil)
end)

Spec.test("lowest floor becomes ground; walls are grounded; roof rests on walls", function()
	local s = house()
	Spec.eq(s.chunks[1].kind, "ground")
	Spec.truthy(s.chunks[2].grounded, "wall grounded")
	Spec.eq(s.chunks[6].kind, "floor")
	Spec.truthy(not s.chunks[4].grounded, "roof not grounded")
	local sup = {}
	for _, id in s.chunks[4].supports do
		sup[id] = true
	end
	Spec.truthy(sup[2] and sup[3], "roof supported by both walls")
	Spec.truthy(sup[6], "and by the upper floor it sits on")
	Spec.eq(#s.chunks[5].supports, 1, "window framed by its wall only")
	Spec.eq(s.chunks[5].supports[1], 2)
	Spec.truthy(not sup[5], "windows never support")
end)

Spec.test("a ridge cap rests on its roof slopes and falls with them", function()
	local s = S.new({
		box("floor", 0, 0.5, 0, 8, 0.5, 8), -- 1
		box("wall", -8, 7, 0, 0.5, 6, 8), -- 2
		box("wall", 8, 7, 0, 0.5, 6, 8), -- 3
		box("roof", -4, 15, 0, 5, 2, 8), -- 4 slope
		box("roof", 4, 15, 0, 5, 2, 8), -- 5 slope
		box("roof", 0, 17.5, 0, 1, 0.5, 8), -- 6 ridge
	}, cfg)
	Spec.eq(#s.chunks[6].supports, 2)
	S.collapse(s, 4)
	S.collapse(s, 5)
	Spec.eq(S.supportRatio(s, 6), 0)
	Spec.eq(S.failures(s, cfg, never, 0.25)[1], 6)
end)

Spec.test("fresh building is 100, windows carry no weight", function()
	local s = house()
	Spec.eq(S.integrity(s), 100)
	Spec.near(s.totalWeight, 0.3 + 1 + 1 + 1 + 0.8, 1e-9)
end)

Spec.test("burning wears hp by BurnRate * level", function()
	local s = house()
	S.setBurning(s, 2, 3)
	S.tick(s, 2, cfg)
	Spec.near(s.chunks[2].hp, 1 - 0.02 * 3 * 2, 1e-9)
	S.setBurning(s, 2, 0)
	S.tick(s, 5, cfg)
	Spec.near(s.chunks[2].hp, 0.88, 1e-9, "no loss once out")
end)

Spec.test("charring caps hp and stops burning", function()
	local s = house()
	S.setBurning(s, 4, 2)
	S.setCharred(s, 4, cfg)
	Spec.eq(s.chunks[4].burning, 0)
	Spec.near(s.chunks[4].hp, 0.15, 1e-9)
end)

Spec.test("integrity is the weighted hp share", function()
	local s = house()
	S.setCharred(s, 2, cfg) -- wall weight 1 -> 0.15
	-- (0.3 + 0.15 + 1 + 1 + 0.8) / 4.1
	Spec.eq(S.integrity(s), math.floor((3.25 / 4.1) * 100 + 0.5))
	S.collapse(s, 4) -- roof gone
	Spec.eq(S.integrity(s), math.floor((2.25 / 4.1) * 100 + 0.5))
end)

Spec.test("charred roof caves in", function()
	local s = house()
	Spec.eq(#S.failures(s, cfg, never, 0.25), 0)
	S.setCharred(s, 4, cfg)
	local f = S.failures(s, cfg, never, 0.25)
	Spec.eq(#f, 1)
	Spec.eq(f[1], 4)
end)

Spec.test("supports failing drop the roof and the upper floor", function()
	local s = house()
	S.collapse(s, 2)
	-- roof rests on both walls and the upper floor: 2 of 3 left -> still standing
	Spec.near(S.supportRatio(s, 4), 2 / 3, 1e-9)
	Spec.eq(#S.failures(s, cfg, never, 0.25), 0)
	S.setCharred(s, 3, cfg)
	local f = S.failures(s, cfg, never, 0.25)
	local set = {}
	for _, id in f do
		set[id] = true
	end
	Spec.truthy(set[4], "roof falls")
	Spec.truthy(set[6], "upper floor gives way")
	Spec.truthy(not set[1], "ground floor never falls")
end)

Spec.test("charred walls fall by chance, never inside a shell", function()
	local s = house()
	S.setCharred(s, 2, cfg)
	local always = function()
		return 0
	end
	local f = S.failures(s, cfg, always, 1)
	Spec.eq(#f, 1)
	Spec.eq(f[1], 2)
	Spec.eq(#S.failures(s, cfg, never, 1), 0, "unlucky roll")
	s.lost = true
	Spec.eq(#S.failures(s, cfg, always, 1), 0, "shell walls stay up")
end)

Spec.test("windows shatter from nearby heat or a lost wall", function()
	local s = house()
	S.setBurning(s, 2, 3) -- wall right next to the window
	S.tick(s, 1, cfg)
	Spec.eq(#S.windowsToShatter(s, cfg), 0)
	S.tick(s, 1.1, cfg)
	local w = S.windowsToShatter(s, cfg)
	Spec.eq(#w, 1)
	Spec.eq(w[1], 5)
	S.shatter(s, 5)
	Spec.eq(#S.windowsToShatter(s, cfg), 0)

	local t = house()
	S.collapse(t, 2)
	S.collapse(t, 3)
	Spec.eq(#S.windowsToShatter(t, cfg), 1, "frame gone")
end)

Spec.test("total loss / saved thresholds", function()
	Spec.truthy(S.isTotalLoss(15, cfg))
	Spec.truthy(S.isTotalLoss(0, cfg))
	Spec.truthy(not S.isTotalLoss(16, cfg))
	Spec.truthy(S.saved(50, cfg))
	Spec.truthy(not S.saved(49, cfg))
	local s = house()
	s.lost = true
	Spec.eq(S.integrity(s), 0, "lost snaps to 0")
end)

Spec.test("shell plan keeps exterior walls and ground", function()
	local s = house()
	local plan = S.shellPlan(s)
	local set = {}
	for _, id in plan do
		set[id] = true
	end
	Spec.truthy(set[4] and set[6], "roof + upper floor")
	Spec.truthy(not set[1] and not set[2] and not set[3] and not set[5])
end)

Spec.test("cluster groups nearby failures", function()
	local s = S.new({
		box("wall", 0, 6, 0, 0.5, 6, 4),
		box("wall", 5, 6, 0, 0.5, 6, 4),
		box("wall", 100, 6, 0, 0.5, 6, 4),
	}, cfg)
	local g = S.cluster(s, { 1, 2, 3 }, 14)
	Spec.eq(#g, 2)
	Spec.eq(#g[1], 2)
	Spec.eq(#g[2], 1)
end)

Spec.test("hurt falls off linearly", function()
	Spec.eq(S.hurtAmount(0, 10, 40), 40)
	Spec.eq(S.hurtAmount(5, 10, 40), 20)
	Spec.eq(S.hurtAmount(10, 10, 40), 0)
	Spec.eq(S.hurtAmount(3, 0, 40), 0)
end)

Spec.test("burningCount ignores collapsed chunks", function()
	local s = house()
	S.setBurning(s, 2, 1)
	S.setBurning(s, 3, 2)
	Spec.eq(S.burningCount(s), 2)
	S.collapse(s, 3)
	Spec.eq(S.burningCount(s), 1)
end)

Spec.test("buildingSaved star: integrity at/above min, nil = never burned", function()
	local rule = { id = "buildingSaved", min = 50 }
	local base = { outcome = "success", burningAtEnd = 0, rescued = 1, trapped = 0, elapsed = 60, downs = 0 } :: any
	base.integrity = 50
	Spec.truthy(MissionFlow.starEarned(rule, base))
	base.integrity = 49
	Spec.truthy(not MissionFlow.starEarned(rule, base))
	base.integrity = nil
	Spec.truthy(MissionFlow.starEarned(rule, base))
	base.integrity = 90
	base.outcome = "wiped"
	Spec.truthy(not MissionFlow.starEarned(rule, base), "needs a finished shift")
end)

return Spec.finish()
