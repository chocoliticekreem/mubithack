--!strict
-- PropPhysics: knockable names, spatial grid, awake budgets (per area / per server), sleeping,
-- landing / slip / impulse thresholds, truck fling and blast vectors, pops. Values mirror PhysicsConfig.
local Spec = require("./Spec")
local P = require("../ServerScriptService/Lib/Physics/PropPhysics")

-- keep in sync with ReplicatedStorage/Config/PhysicsConfig.luau (the config needs Roblox to load)
local NAMES = {
	"trashcan", "trash", "trashbin", "wheeliebin", "recyclebin", "garbagecan", "cone", "mailbox",
	"bench", "chair", "stool", "box", "crate", "duck", "duckling", "hydrantcap", "barrel", "bucket",
	"ball", "pumpkin", "pallet", "tire",
}
local EXCLUDE = {
	"fusebox", "hitbox", "volume", "zone", "truckspot", "marker", "dropoff", "lightbox", "skybox",
	"jukebox", "duckpond", "firebox", "sandbox",
}
local CFG = {
	SleepRadius = 90,
	ForceSleepRadius = 220,
	SleepSpeed = 2,
	SleepAfter = 3,
	HardLandingSpeed = 75,
	SplatLandingSpeed = 160,
	LandingRagdollMin = 1.0,
	LandingRagdollMax = 3.0,
	SlipSpeed = 14,
	SlipChancePerSecond = 0.55,
	ImpulseRagdollAt = 55,
	ImpulseRagdollMin = 0.8,
	ImpulseRagdollMax = 2.5,
	MaxImpulse = 120,
	TruckFlingCarry = 1.35,
	TruckFlingUp = 30,
	TruckFlingSide = 18,
	MaxPropSpeed = 160,
	MaxAwakePerArea = 60,
	MaxAwakeServer = 300,
}

local function len(x: number, y: number, z: number): number
	return math.sqrt(x * x + y * y + z * z)
end

-- names ---------------------------------------------------------------------------------------------
Spec.test("normalize strips case, digits and separators", function()
	Spec.eq(P.normalize("Park_Bench2"), "parkbench")
	Spec.eq(P.normalize("Trash Can #3"), "trashcan")
end)

Spec.test("known props are knockable (suffix match)", function()
	for _, n in { "TrashCan", "Cone", "TrafficCone", "Mailbox", "Bench", "ParkBench", "Chair", "Box",
		"CardboardBox", "Crate", "Duck", "RubberDuck", "HydrantCap", "Barrel_1", "Bucket", "BeachBall" } do
		Spec.truthy(P.isKnockableName(n, NAMES, EXCLUDE), n)
	end
end)

Spec.test("scenery and gameplay objects are not knockable", function()
	for _, n in { "FuseBox", "Hitbox", "WaveVolume", "TruckSpot", "RescueDropoff", "DuckPond", "House",
		"Cabin", "Road", "Wall", "Lightbox", "", "123" } do
		Spec.eq(P.isKnockableName(n, NAMES, EXCLUDE), false, n)
	end
end)

-- grid ------------------------------------------------------------------------------------------------
Spec.test("grid finds ids in nearby cells and forgets removed ones", function()
	local g = P.Grid.new(32)
	g:insert("a", 0, 0)
	g:insert("b", 40, 0)
	g:insert("c", 500, 500)
	g:insert("d", -10, -10)
	local function has(list: { any }, id: any): boolean
		return table.find(list, id) ~= nil
	end
	local q = g:query(0, 0, 20)
	Spec.truthy(has(q, "a"), "a")
	Spec.truthy(has(q, "d"), "d (negative cell)")
	Spec.eq(has(q, "c"), false, "far c")
	Spec.truthy(has(g:query(0, 0, 45), "b"), "b within 45")
	g:remove("a")
	Spec.eq(has(g:query(0, 0, 20), "a"), false, "removed")
	g:insert("b", 500, 490) -- re-insert moves it
	Spec.eq(has(g:query(40, 0, 5), "b"), false, "moved away")
	Spec.truthy(has(g:query(500, 500, 20), "b"), "moved here")
end)

Spec.test("cellKey separates neighbours and negatives", function()
	Spec.truthy(P.cellKey(0, 0, 200) ~= P.cellKey(-1, 0, 200))
	Spec.truthy(P.cellKey(0, 0, 200) ~= P.cellKey(0, 200, 200))
	Spec.eq(P.cellKey(10, 10, 200), P.cellKey(199, 199, 200))
end)

-- budgets -------------------------------------------------------------------------------------------
Spec.test("per-area cap holds at MaxAwakePerArea (60)", function()
	local b = P.Budget.new(CFG.MaxAwakePerArea, CFG.MaxAwakeServer)
	for i = 1, 80 do
		b:wake(i, "downtown", i)
	end
	Spec.eq(b:count("downtown"), 60)
	Spec.eq(b:count(nil), 60)
	Spec.eq(b:wake(999, "downtown", 100), false)
	Spec.truthy(b:wake(999, "park", 100), "another area still has room")
end)

Spec.test("server cap holds at MaxAwakeServer (300) across areas", function()
	local b = P.Budget.new(CFG.MaxAwakePerArea, CFG.MaxAwakeServer)
	local id = 0
	for area = 1, 8 do
		for _ = 1, 60 do
			id += 1
			b:wake(id, area, id)
		end
	end
	Spec.eq(b:count(nil), 300)
	Spec.eq(b:canWake(99), false)
end)

Spec.test("wake is idempotent and sleep frees a slot", function()
	local b = P.Budget.new(2, 10)
	Spec.truthy(b:wake("x", 1, 0))
	Spec.truthy(b:wake("x", 1, 1), "already awake -> true")
	Spec.eq(b:count(1), 1)
	b:wake("y", 1, 2)
	Spec.eq(b:wake("z", 1, 3), false)
	Spec.truthy(b:sleep("x"))
	Spec.eq(b:sleep("x"), false, "double sleep")
	Spec.truthy(b:wake("z", 1, 3))
	Spec.eq(b:count(1), 2)
end)

Spec.test("evict picks the least recently touched, honouring area and pins", function()
	local b = P.Budget.new(10, 10)
	b:wake("old", "A", 1)
	b:wake("mid", "A", 5)
	b:wake("other", "B", 0)
	b:touch("old", 9)
	Spec.eq(b:evict("A"), "mid")
	Spec.eq(b:evict(nil), "other")
	Spec.eq(b:evict("A", function(id)
		return id == "mid"
	end), "old")
	Spec.eq(P.Budget.new(1, 1):evict(nil), nil)
end)

-- sleeping -----------------------------------------------------------------------------------------
Spec.test("props sleep after SleepAfter idle seconds with nobody near", function()
	local s, idle = P.shouldSleep(100, 0, 0, 1, CFG)
	Spec.eq(s, false)
	s, idle = P.shouldSleep(100, 0, idle, 1, CFG)
	Spec.eq(s, false)
	s, idle = P.shouldSleep(100, 0, idle, 1, CFG)
	Spec.eq(s, true)
	Spec.eq(idle, 0)
end)

Spec.test("a nearby player or a moving prop resets the idle timer", function()
	local s, idle = P.shouldSleep(30, 0, 2.5, 1, CFG)
	Spec.eq(s, false)
	Spec.eq(idle, 0)
	s, idle = P.shouldSleep(100, 10, 2.5, 1, CFG)
	Spec.eq(s, false)
	Spec.eq(idle, 0)
end)

Spec.test("very far props sleep at once, even mid-flight", function()
	local s = P.shouldSleep(220, 80, 0, 0.25, CFG)
	Spec.eq(s, true)
end)

-- players -------------------------------------------------------------------------------------------
Spec.test("landing below HardLandingSpeed never ragdolls (normal jump ~50)", function()
	Spec.eq(P.landingSeconds(50, CFG), 0)
	Spec.eq(P.landingSeconds(74.9, CFG), 0)
	Spec.eq(P.landingSeconds(0 / 0, CFG), 0)
end)

Spec.test("landing ragdoll scales from min to max and clamps", function()
	Spec.near(P.landingSeconds(75, CFG), 1.0)
	Spec.near(P.landingSeconds(117.5, CFG), 2.0)
	Spec.near(P.landingSeconds(160, CFG), 3.0)
	Spec.near(P.landingSeconds(999, CFG), 3.0)
end)

Spec.test("slips need SlipSpeed and roll against the per-second chance", function()
	Spec.eq(P.slipRoll(10, 1, 0, CFG), false, "too slow")
	Spec.truthy(P.slipRoll(20, 1, 0.5, CFG), "0.5 < 0.55 over a second")
	Spec.eq(P.slipRoll(20, 1, 0.6, CFG), false)
	-- per-frame chance compounds to the per-second chance
	local frame = 1 - (1 - 0.55) ^ (1 / 60)
	Spec.near(1 - (1 - frame) ^ 60, 0.55, 1e-9)
	Spec.truthy(P.slipRoll(20, 1 / 60, frame * 0.99, CFG))
	Spec.eq(P.slipRoll(20, 1 / 60, frame * 1.01, CFG), false)
end)

Spec.test("impulses ragdoll only at ImpulseRagdollAt and above", function()
	Spec.eq(P.impulseRagdollSeconds(25, CFG), 0, "hose push")
	Spec.near(P.impulseRagdollSeconds(55, CFG), 0.8)
	Spec.near(P.impulseRagdollSeconds(120, CFG), 2.5)
	Spec.near(P.impulseRagdollSeconds(500, CFG), 2.5)
end)

-- vectors -------------------------------------------------------------------------------------------
Spec.test("clamp3 caps the magnitude and zeroes NaN", function()
	local x, y, z = P.clamp3(300, 400, 0, 100)
	Spec.near(len(x, y, z), 100, 1e-6)
	Spec.near(x / y, 0.75, 1e-9)
	x, y, z = P.clamp3(1, 2, 2, 100)
	Spec.eq(x + y + z, 5)
	x, y, z = P.clamp3(0 / 0, 1, 1, 10)
	Spec.eq(x + y + z, 0)
end)

Spec.test("a truck flings props forward, faster than itself, and up", function()
	local x, y, z = P.truckFling(0, 0, -40, CFG, 0)
	Spec.near(x, 0, 1e-9)
	Spec.near(z, -54, 1e-6)
	Spec.truthy(y >= CFG.TruckFlingUp, "kicked up")
	Spec.truthy(len(x, y, z) <= CFG.MaxPropSpeed + 1e-6, "capped")
	local sx = P.truckFling(0, 0, -40, CFG, 1)
	Spec.truthy(math.abs(sx) > 1, "spin adds sideways wobble")
	local bx, by, bz = P.truckFling(0, 0, -500, CFG, 1)
	Spec.near(len(bx, by, bz), CFG.MaxPropSpeed, 1e-6)
end)

Spec.test("blast pushes away and up, weaker at the edge, nothing outside", function()
	local x, y, z = P.blast(5, 0, 0, 20, 100)
	Spec.truthy(x > 0 and y > 0, "away and up")
	Spec.near(len(x, y, z), 100 * (1 - 0.75 * 5 / 20), 1e-6)
	local ex, ey, ez = P.blast(19, 0, 0, 20, 100)
	Spec.truthy(len(ex, ey, ez) < len(x, y, z), "weaker at the edge")
	local ox, oy, oz = P.blast(25, 0, 0, 20, 100)
	Spec.eq(ox + oy + oz, 0)
	local cx, cy, cz = P.blast(0, 0, 0, 20, 100)
	Spec.near(cy, 100, 1e-6, "dead centre goes straight up")
	Spec.eq(cx + cz, 0)
end)

Spec.test("pops are comedic words for every kind", function()
	for _, k in { "truck", "runover", "axe", "hose", "blast", "land", "slip", "shove", "unknown" } do
		for _, r in { 0, 0.5, 0.999 } do
			local w = P.popWord(k, r)
			Spec.truthy(#w > 0 and string.upper(w) == w, `{k} {r} -> {w}`)
		end
	end
	Spec.truthy(P.popWord("runover", 0) == "BOING!")
end)

return Spec.finish()
