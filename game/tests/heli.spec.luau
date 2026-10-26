--!strict
-- HeliRules: arcade flight targets, the bucket rope, filling at water and the drop checks.
local Spec = require("./Spec")
local Rules = require("../ReplicatedStorage/Lib/Heli/HeliRules")

local CFG = {
	Speed = 70,
	BoostSpeed = 95,
	AltitudeBoostAbove = 60,
	Accel = 2.6,
	ClimbSpeed = 34,
	TurnRate = 2.4,
	MinClearance = 3.2,
	MaxY = 260,
	BoundsMargin = 60,
	ObstacleLift = 26,
	TouchSpeedScale = 0.85,
	RopeLength = 11,
	FillSeconds = 2.2,
	FillReach = 7,
	FillMargin = 5,
	DropCooldown = 8,
	DropMaxHeight = 90,
}

local function settle(inp: any, st: any): (number, number, number)
	local vx, vy, vz = 0, 0, 0
	for _ = 1, 240 do -- 4 s at 60 Hz
		st.vx, st.vy, st.vz, st.dt = vx, vy, vz, 1 / 60
		vx, vy, vz = Rules.velocity(inp, st, CFG)
	end
	return vx, vy, vz
end

Spec.test("full stick reaches top speed, hover holds still", function()
	local vx, vy, vz = settle({ mx = 0, mz = -1, up = 0 }, { y = 40, clearance = 30 })
	Spec.near(vz, -70, 0.5, "forward")
	Spec.near(vx, 0, 1e-6)
	Spec.near(vy, 0, 1e-6)
	vx, vy, vz = settle({ mx = 0, mz = 0, up = 0 }, { y = 40, clearance = 30 })
	Spec.near(vx, 0, 1e-3)
	Spec.near(vz, 0, 1e-3)
end)

Spec.test("diagonal stick is not faster", function()
	local vx, _, vz = settle({ mx = 1, mz = 1, up = 0 }, { y = 40, clearance = 30 })
	Spec.near(math.sqrt(vx * vx + vz * vz), 70, 0.5)
end)

Spec.test("high up it boosts, touch is gentler", function()
	local _, _, vz = settle({ mx = 0, mz = -1, up = 0 }, { y = 120, clearance = 100 })
	Spec.near(vz, -95, 0.5)
	_, _, vz = settle({ mx = 0, mz = -1, up = 0, touch = true }, { y = 40, clearance = 30 })
	Spec.near(vz, -70 * 0.85, 0.5)
end)

Spec.test("never sinks under the hover floor, climbs out of it", function()
	local _, vy = settle({ mx = 0, mz = 0, up = -1 }, { y = 5, clearance = 3.2 })
	Spec.near(vy, 0, 0.01, "down at the floor")
	_, vy = settle({ mx = 0, mz = 0, up = 0 }, { y = 3, clearance = 1 })
	Spec.truthy(vy > 5, "climbs back up")
	_, vy = settle({ mx = 0, mz = 0, up = -1 }, { y = 50, clearance = 40 })
	Spec.near(vy, -34, 0.5, "free descent")
end)

Spec.test("ceiling", function()
	local _, vy = settle({ mx = 0, mz = 0, up = 1 }, { y = 260, clearance = 200 })
	Spec.near(vy, 0, 0.01)
	_, vy = settle({ mx = 0, mz = 0, up = 0 }, { y = 280, clearance = 200 })
	Spec.truthy(vy < -10, "pushed down from above MaxY")
end)

Spec.test("soft world bounds push back inside", function()
	local b = { minX = -1500, maxX = 1500, minZ = -1500, maxZ = 1500 }
	local vx = settle({ mx = 1, mz = 0, up = 0 }, { y = 40, clearance = 30, x = 1480, z = 0, bounds = b })
	Spec.truthy(vx < 0, "flying out east turns back west")
	vx = settle({ mx = 1, mz = 0, up = 0 }, { y = 40, clearance = 30, x = 0, z = 0, bounds = b })
	Spec.truthy(vx > 60, "inside: untouched")
end)

Spec.test("a wall ahead: slow and climb over", function()
	local _, vy, vz = settle({ mx = 0, mz = -1, up = 0 }, { y = 30, clearance = 20, blocked = true })
	Spec.truthy(math.abs(vz) < 11, "barely pushes in")
	Spec.near(vy, 26, 0.5, "lifts")
end)

Spec.test("yaw turns toward travel, keeps it while hovering", function()
	local yaw = 0
	for _ = 1, 600 do
		yaw = Rules.yawToward(yaw, 50, 0, 1 / 60, CFG) -- flying +X: look (-sin, -cos) = (1, 0) -> yaw = -pi/2
	end
	Spec.near(yaw, -math.pi / 2, 0.01)
	Spec.near(Rules.yawToward(1.2, 1, 1, 1 / 60, CFG), 1.2, 1e-9, "slow drift keeps heading")
end)

Spec.test("rope: full length in the air, rests on the ground when low", function()
	Spec.eq(Rules.ropeDrop(40, CFG), 11)
	Spec.near(Rules.ropeDrop(5, CFG), 6.2, 1e-9)
	Spec.eq(Rules.ropeDrop(0, CFG), 2)
end)

Spec.test("in water: footprint + margin, close above the surface", function()
	local pond = { minX = 0, maxX = 20, minZ = 0, maxZ = 20, top = 1 }
	Spec.eq(Rules.inWater(10, 3, 10, pond, CFG), true)
	Spec.eq(Rules.inWater(24, 3, 10, pond, CFG), true, "margin")
	Spec.eq(Rules.inWater(30, 3, 10, pond, CFG), false, "beside it")
	Spec.eq(Rules.inWater(10, 12, 10, pond, CFG), false, "too high")
	Spec.eq(Rules.inWater(10, -10, 10, pond, CFG), true, "dunked")
end)

Spec.test("fill takes FillSeconds and only in water", function()
	local f = 0
	for _ = 1, 11 do
		f = Rules.fill(f, 0.1, true, CFG)
	end
	Spec.near(f, 0.5, 1e-6)
	Spec.near(Rules.fill(f, 5, false, CFG), 0.5, 1e-6)
	Spec.eq(Rules.fill(f, 100, true, CFG), 1)
end)

Spec.test("drop checks", function()
	local base = { pilot = true, fill = 1, now = 100, last = 0, height = 20 }
	Spec.eq((Rules.canDrop(base, CFG)), true)
	local function why(over: { [string]: any }): string?
		local d = table.clone(base) :: any
		for k, v in over do
			d[k] = v
		end
		local _, r = Rules.canDrop(d, CFG)
		return r
	end
	Spec.eq(why({ pilot = false }), "not pilot")
	Spec.eq(why({ fill = 0.6 }), "empty")
	Spec.eq(why({ last = 95 }), "cooldown")
	Spec.eq(why({ height = 120 }), "too high")
end)

Spec.test("drop targets: radius, under the roof, nearest first, capped", function()
	local cfg = { DropRadius = 18, DropDepth = 45, DropAbove = 12, DropMaxParts = 3 }
	local fires = {
		{ x = 0, y = 15, z = 0 }, -- on the roof, right there
		{ x = 10, y = 2, z = 0 }, -- inside, ground floor
		{ x = 25, y = 2, z = 0 }, -- too far
		{ x = 0, y = 40, z = 5 }, -- way above the splash
		{ x = 5, y = 2, z = 5 },
		{ x = 12, y = 2, z = 12 },
	}
	local t = Rules.dropTargets(fires, { x = 0, y = 15, z = 0 }, cfg)
	Spec.eq(#t, 3, "capped")
	Spec.eq(t[1], 1)
	Spec.eq(t[2], 5)
	Spec.eq(t[3], 2)
	cfg.DropMaxParts = 10
	Spec.eq(#Rules.dropTargets(fires, { x = 0, y = 15, z = 0 }, cfg), 4, "17 studs diagonal still in")
end)

return Spec.finish()
