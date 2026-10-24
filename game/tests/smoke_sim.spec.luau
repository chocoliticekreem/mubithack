--!strict
-- SmokeSim: smoke + heat build-up per room, venting, seeping under doors, backdraft pressure.
local Spec = require("./Spec")
local SmokeSim = require("../ServerScriptService/Lib/Fire/SmokeSim")

-- mirrors ReplicatedStorage/Config/SmokeConfig
local cfg: SmokeSim.Cfg = {
	RefArea = 300,
	MinArea = 60,
	FireCap = 24,
	SmokePerLevel = 0.012,
	HeatPerLevel = 1.4,
	Leak = 0.012,
	HeatLoss = 0.03,
	OpenDoorFlow = 0.6,
	SeepFlow = 0.012,
	OpenWindowFlow = 0.7,
	ClosedWindowFlow = 0.003,
	StairFlow = 0.5,
	SinkFactor = 0.25,
	HeatFlowFactor = 0.6,
	OpenFlowAt = 0.2,
	PressureSmoke = 0.4,
	PressureFire = 3,
	PressureRate = 0.04,
	PressureFireBoost = 2,
	PressureDecay = 0.02,
	VentRelief = 0.25,
	WarnAt = 0.4,
	ArmedAt = 0.75,
	BackdraftSmokeKeep = 0.3,
	BackdraftHeat = 25,
	VentPuffSmoke = 0.25,
	SpreadHeat = 45,
	SpreadOpenRate = 0.08,
	SpreadSeepRate = 0.025,
	SpreadSkipFire = 6,
	SmokeHurtsAt = 0.2,
	SmokeHeatPerSecond = 14,
	RoomHeatAt = 30,
	RoomHeatPerSecond = 8,
	MaskFactor = 0.2,
	MaskAirFactor = 0.08,
	ChokeAt = 0.45,
	ChokeDps = 1.2,
	LayerMaxFill = 0.9,
	LayerClear = 0.6,
	LayerThick = 0.04,
}

-- Room 1 (fire) and room 2 joined by a door; room 1 has a window and a front door to the outside.
local function scene(fire: number)
	local rooms = { SmokeSim.newRoom(300), SmokeSim.newRoom(300) }
	rooms[1].fire = fire
	local links = {
		SmokeSim.newLink(1, 2, "door", false), -- 1: inner door
		SmokeSim.newLink(1, 0, "window", false), -- 2: window
		SmokeSim.newLink(1, 0, "door", false), -- 3: front door
	}
	return rooms, links
end

local function run(rooms, links, seconds: number): { SmokeSim.Event }
	local all = {}
	for _ = 1, math.floor(seconds * 3) do
		for _, e in SmokeSim.step(rooms, links, 1 / 3, cfg) do
			table.insert(all, e)
		end
	end
	return all
end

local function has(events: { SmokeSim.Event }, kind: string): boolean
	for _, e in events do
		if e.kind == kind then
			return true
		end
	end
	return false
end

Spec.test("a fire fills its room with smoke and heat", function()
	local rooms, links = scene(4)
	run(rooms, links, 30)
	Spec.truthy(rooms[1].smoke > 0.6, `smoke {rooms[1].smoke}`)
	Spec.truthy(rooms[1].heat > 50, `heat {rooms[1].heat}`)
	Spec.truthy(rooms[2].smoke > 0 and rooms[2].smoke < rooms[1].smoke * 0.5, "a little seeps next door")
end)

Spec.test("no fire, no smoke", function()
	local rooms, links = scene(0)
	run(rooms, links, 20)
	Spec.eq(rooms[1].smoke, 0)
	Spec.eq(rooms[1].pressure, 0)
end)

Spec.test("an open window vents the room", function()
	local rooms, links = scene(4)
	run(rooms, links, 30)
	links[2].open = true
	run(rooms, links, 10)
	Spec.truthy(rooms[1].smoke < 0.15, `vented smoke {rooms[1].smoke}`)
	Spec.truthy(links[2].flow > 0, "smoke flows out of the window")
end)

Spec.test("smoke seeps under a closed door slower than through an open one", function()
	local r1, l1 = scene(4)
	run(r1, l1, 20)
	local r2, l2 = scene(4)
	l2[1].open = true
	run(r2, l2, 20)
	Spec.truthy(r1[2].smoke > 0.01, "closed door still seeps")
	Spec.truthy(r2[2].smoke > r1[2].smoke * 3, `open door much faster ({r2[2].smoke} vs {r1[2].smoke})`)
end)

Spec.test("sealed + heavy fire builds pressure: warn first, then armed", function()
	local rooms, links = scene(6)
	local events = run(rooms, links, 120)
	Spec.truthy(has(events, "warn"), "warned")
	Spec.truthy(has(events, "armed"), "armed")
	local warnAt, armedAt = 0, 0
	for i, e in events do
		if e.kind == "warn" and warnAt == 0 then
			warnAt = i
		elseif e.kind == "armed" and armedAt == 0 then
			armedAt = i
		end
	end
	Spec.truthy(warnAt < armedAt, "warning comes before it's armed")
	Spec.eq(rooms[1].stage, 2)
end)

Spec.test("a bigger sealed fire pressurizes faster, capped", function()
	local function armedAfter(fire: number): number
		local rooms, links = scene(fire)
		for n = 1, 900 do
			SmokeSim.step(rooms, links, 1 / 3, cfg)
			if rooms[1].stage == 2 then
				return n / 3
			end
		end
		return math.huge
	end
	local small, big, huge = armedAfter(4), armedAfter(18), armedAfter(200)
	Spec.truthy(big < small, `big {big} s < small {small} s`)
	Spec.truthy(huge > 10, `still telegraphed ({huge} s)`)
end)

Spec.test("a vented room never builds pressure", function()
	local rooms, links = scene(6)
	links[2].open = true
	local events = run(rooms, links, 120)
	Spec.truthy(not has(events, "warn"), "no warning")
	Spec.eq(rooms[1].pressure, 0)
end)

Spec.test("opening the door on an armed room = backdraft", function()
	local rooms, links = scene(6)
	run(rooms, links, 120)
	links[3].open = true
	local outcome, room = SmokeSim.onOpened(rooms, links, 3, cfg)
	Spec.eq(outcome, "backdraft")
	Spec.eq(room, 1)
	Spec.eq(rooms[1].pressure, 0)
	Spec.truthy(rooms[1].smoke < 0.4, "the fireball burns the smoke off")
end)

Spec.test("venting a window first relieves it, then the door is safe", function()
	local rooms, links = scene(6)
	run(rooms, links, 120)
	links[2].open = true
	local outcome = SmokeSim.onOpened(rooms, links, 2, cfg)
	Spec.eq(outcome, "relief")
	Spec.truthy(rooms[1].stage == 0 and rooms[1].pressure < cfg.WarnAt, "pressure let out")
	links[3].open = true
	local again = SmokeSim.onOpened(rooms, links, 3, cfg)
	Spec.truthy(again ~= "backdraft", "no backdraft after venting")
end)

Spec.test("a window relieves the whole compartment (stairwell to the room upstairs)", function()
	local rooms = { SmokeSim.newRoom(300), SmokeSim.newRoom(300) }
	rooms[1].fire = 6
	local links = {
		SmokeSim.newLink(1, 2, "stair", true),
		SmokeSim.newLink(2, 0, "window", false), -- upstairs window
		SmokeSim.newLink(1, 0, "door", false), -- front door downstairs
	}
	run(rooms, links, 150)
	Spec.eq(rooms[1].stage, 2, "downstairs armed")
	Spec.truthy(rooms[2].smoke > rooms[1].smoke * 0.5, "smoke rose upstairs")
	links[2].open = true
	Spec.eq(SmokeSim.onOpened(rooms, links, 2, cfg), "relief")
	links[3].open = true
	Spec.truthy(SmokeSim.onOpened(rooms, links, 3, cfg) ~= "backdraft", "safe now")
end)

Spec.test("a window on a calm smoky room is just a vent puff", function()
	local rooms, links = scene(2)
	run(rooms, links, 40)
	links[2].open = true
	Spec.eq(SmokeSim.onOpened(rooms, links, 2, cfg), "vent")
end)

Spec.test("fire creeps under a closed door; faster when it's open", function()
	local function firstSpread(open: boolean): number
		local rooms, links = scene(8)
		links[1].open = open
		for n = 1, 600 do
			for _, e in SmokeSim.step(rooms, links, 1 / 3, cfg) do
				if e.kind == "spread" then
					Spec.eq(e.from, 1)
					Spec.eq(e.to, 2)
					return n / 3
				end
			end
		end
		return math.huge
	end
	local closed, open = firstSpread(false), firstSpread(true)
	Spec.truthy(closed < 200, `closed door spreads eventually ({closed} s)`)
	Spec.truthy(open < closed, `open faster ({open} s vs {closed} s)`)
end)

Spec.test("smoke rises: up a stairwell fast, down it slowly", function()
	local up = { SmokeSim.newRoom(300), SmokeSim.newRoom(300) }
	up[1].smoke = 1
	SmokeSim.step(up, { SmokeSim.newLink(1, 2, "stair", true) }, 1, cfg)
	local down = { SmokeSim.newRoom(300), SmokeSim.newRoom(300) }
	down[2].smoke = 1
	SmokeSim.step(down, { SmokeSim.newLink(1, 2, "stair", true) }, 1, cfg)
	Spec.truthy(up[2].smoke > down[1].smoke * 2, "rises faster than it sinks")
end)

Spec.test("player heat: smoke hurts, the gas mask protects, room heat still warms", function()
	local bare = SmokeSim.playerHeatRate(1, 0, false, false, cfg)
	local masked = SmokeSim.playerHeatRate(1, 0, true, false, cfg)
	local air = SmokeSim.playerHeatRate(1, 0, true, true, cfg)
	Spec.near(bare, 14, 1e-9)
	Spec.truthy(bare > 6, "beats HeatService's own cooling")
	Spec.truthy(masked < 6 and air < masked, "mask protects, air more")
	Spec.eq(SmokeSim.playerHeatRate(0.1, 0, false, false, cfg), 0, "light haze is harmless")
	Spec.near(SmokeSim.playerHeatRate(0, 100, true, true, cfg), 8, 1e-9, "a hot room heats even masked")
end)

Spec.test("NPCs choke slowly in heavy smoke only", function()
	Spec.eq(SmokeSim.chokeDps(0.3, cfg), 0)
	Spec.near(SmokeSim.chokeDps(1, cfg), 1.2, 1e-9)
end)

Spec.test("the smoke layer grows from the ceiling and thickens", function()
	local d0, t0 = SmokeSim.layer(0, 10, cfg)
	local d1, t1 = SmokeSim.layer(1, 10, cfg)
	Spec.eq(d0, 0)
	Spec.near(d1, 9, 1e-9, "leaves a crawl gap")
	Spec.truthy(t1 < t0, "thicker = less transparent")
end)

Spec.test("door state: seep amount, direction and heat", function()
	local seep, dir, heat = SmokeSim.doorState(0.8, 0.1, 70, 10)
	Spec.near(seep, 0.7, 1e-9)
	Spec.eq(dir, 1)
	Spec.near(heat, 0.7, 1e-9)
	local _, dir2 = SmokeSim.doorState(0, 0.5, 0, 0)
	Spec.eq(dir2, -1)
end)

return Spec.finish()
