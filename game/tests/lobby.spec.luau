--!strict
-- LobbyQueue: queue pads, countdowns (15 s, 5 s when full, reset when empty), parallel launches.
local Spec = require("./Spec")
local LobbyQueue = require("../ReplicatedStorage/Lobby/LobbyQueue")
local Missions = require("../ReplicatedStorage/Config/MissionCatalog") :: { any }

local byId: { [string]: any } = {}
for _, m in Missions do
	byId[m.id] = m
end

local function fresh()
	return LobbyQueue.new({
		pads = 3,
		maxSize = 4,
		countdown = 15,
		fullCountdown = 5,
		defaultMission = "house_fire",
		limits = function(id: string): (number, number)
			local m = byId[id]
			return m.players.min, m.players.max
		end,
	})
end

local function kinds(events: { any }, kind: string): { any }
	local out = {}
	for _, e in events do
		if e.kind == kind then
			table.insert(out, e)
		end
	end
	return out
end

Spec.test("first player on a pad starts a squad, leads it, and starts the 15 s countdown", function()
	local q = fresh()
	local ok, why = LobbyQueue.join(q, 1, 101)
	Spec.eq(ok, true, why)
	Spec.eq(q.pads[1].squadId, "S1", "squadId")
	Spec.eq(q.pads[1].leader, 101, "leader")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), 15, "countdown")
	Spec.eq(LobbyQueue.secondsLeft(q, 2), nil, "other pad idle")
	Spec.eq(LobbyQueue.readyText(#q.pads[1].members, LobbyQueue.capacity(q, 1)), "1/4 READY", "ready text")
end)

Spec.test("ticks emit one count per whole second and launch at 0", function()
	local q = fresh()
	LobbyQueue.join(q, 1, 101)
	local counts, launches = 0, {}
	for _ = 1, 160 do -- 16 s at 10 Hz
		local ev = LobbyQueue.tick(q, 0.1)
		counts += #kinds(ev, "count")
		for _, e in kinds(ev, "launch") do
			table.insert(launches, e)
		end
	end
	Spec.eq(counts, 14, "count events 14..1")
	Spec.eq(#launches, 1, "one launch")
	Spec.eq(launches[1].missionId, "house_fire", "mission")
	Spec.eq(launches[1].squadId, "S1", "squad")
	Spec.eq(launches[1].members[1], 101, "member")
	Spec.eq(#q.pads[1].members, 0, "pad freed after launch")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), nil, "pad idle after launch")
end)

Spec.test("a full squad shortens the countdown to 5 s", function()
	local q = fresh()
	for uid = 1, 3 do
		LobbyQueue.join(q, 2, uid)
	end
	Spec.eq(LobbyQueue.secondsLeft(q, 2), 15, "not full yet")
	LobbyQueue.join(q, 2, 4)
	Spec.eq(LobbyQueue.secondsLeft(q, 2), 5, "full -> 5")
	local ok, why = LobbyQueue.join(q, 2, 5)
	Spec.eq(ok, false, "fifth refused")
	Spec.eq(why, "full", "reason")
end)

Spec.test("the countdown keeps running on join/leave and resets when everyone leaves", function()
	local q = fresh()
	LobbyQueue.join(q, 1, 1)
	LobbyQueue.tick(q, 6)
	LobbyQueue.join(q, 1, 2)
	Spec.eq(LobbyQueue.secondsLeft(q, 1), 9, "join keeps the clock")
	LobbyQueue.leave(q, 1)
	Spec.eq(q.pads[1].leader, 2, "leadership passes on")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), 9, "leave keeps the clock")
	LobbyQueue.leave(q, 2)
	Spec.eq(LobbyQueue.secondsLeft(q, 1), nil, "empty pad stops")
	LobbyQueue.join(q, 1, 3)
	Spec.eq(LobbyQueue.secondsLeft(q, 1), 15, "restart from 15")
	Spec.eq(q.pads[1].squadId, "S2", "new squad id")
end)

Spec.test("several pads count down and launch in parallel", function()
	local q = fresh()
	LobbyQueue.join(q, 1, 1)
	LobbyQueue.tick(q, 4)
	LobbyQueue.join(q, 3, 2)
	local launched: { [number]: number } = {}
	local t = 4
	for _ = 1, 200 do
		t += 0.1
		for _, e in kinds(LobbyQueue.tick(q, 0.1), "launch") do
			launched[e.padId] = t
		end
	end
	Spec.truthy(launched[1], "pad 1 launched")
	Spec.truthy(launched[3], "pad 3 launched")
	Spec.near(launched[1], 15, 0.15, "pad 1 at 15 s")
	Spec.near(launched[3], 19, 0.15, "pad 3 at 19 s")
	Spec.eq(launched[2], nil, "empty pad never launches")
end)

Spec.test("switching pads moves the player and frees the old squad", function()
	local q = fresh()
	LobbyQueue.join(q, 1, 7)
	LobbyQueue.join(q, 2, 7)
	Spec.eq(LobbyQueue.padOf(q, 7), 2, "now on pad 2")
	Spec.eq(#q.pads[1].members, 0, "pad 1 empty")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), nil, "pad 1 stopped")
end)

Spec.test("apply() reconciles positions: join, move, step off, disconnect", function()
	local q = fresh()
	local changed = LobbyQueue.apply(q, { [1] = 1, [2] = 1 }, { 1, 2, 3 })
	Spec.truthy(changed[1], "pad 1 changed")
	Spec.eq(#q.pads[1].members, 2, "two on pad 1")
	LobbyQueue.apply(q, { [1] = 1, [2] = 3 }, { 1, 2, 3 })
	Spec.eq(LobbyQueue.padOf(q, 2), 3, "2 moved to pad 3")
	LobbyQueue.apply(q, { [2] = 3 }, { 1, 2, 3 })
	Spec.eq(LobbyQueue.padOf(q, 1), nil, "1 stepped off")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), nil, "pad 1 reset")
	LobbyQueue.apply(q, {}, { 1, 3 }) -- 2 left the lobby
	Spec.eq(LobbyQueue.padOf(q, 2), nil, "2 removed")
	Spec.eq(LobbyQueue.secondsLeft(q, 3), nil, "pad 3 reset")
end)

Spec.test("leader picks the mission; board pick off-pad is remembered for the next squad", function()
	local q = fresh()
	Spec.eq(LobbyQueue.choose(q, 9, "panda_zoo"), true, "off-pad pick stored")
	LobbyQueue.join(q, 1, 9)
	Spec.eq(q.pads[1].missionId, "panda_zoo", "pref applied on join")
	LobbyQueue.join(q, 1, 10)
	Spec.eq(LobbyQueue.choose(q, 10, "house_fire"), false, "non-leader refused")
	Spec.eq(LobbyQueue.choose(q, 9, "house_fire"), true, "leader allowed")
	Spec.eq(q.pads[1].missionId, "house_fire", "pad mission")
end)

Spec.test("a mission below its min players restarts the countdown instead of launching", function()
	local q = fresh()
	LobbyQueue.setPadMission(q, 1, nil, "panda_zoo") -- needs 2 carriers
	LobbyQueue.join(q, 1, 1)
	local ev = LobbyQueue.tick(q, 15.01)
	Spec.eq(#kinds(ev, "short"), 1, "short event")
	Spec.eq(#kinds(ev, "launch"), 0, "no launch")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), 15, "countdown restarted")
end)

Spec.test("2-player missions are full at their own max and hurry() cuts the clock", function()
	local q = fresh()
	LobbyQueue.join(q, 1, 1)
	Spec.eq(LobbyQueue.hurry(q, 1, 3), true, "hurry")
	Spec.eq(LobbyQueue.secondsLeft(q, 1), 3, "3 s left")
	Spec.eq(LobbyQueue.hurry(q, 2, 3), false, "idle pad cannot hurry")
end)

Spec.test("board helpers: difficulty, players text, pips", function()
	Spec.eq(LobbyQueue.difficulty(byId.house_fire), 1, "house_fire easy")
	Spec.eq(LobbyQueue.difficulty(byId.dam_finale), 5, "dam_finale hardest")
	Spec.eq(LobbyQueue.playersText(byId.house_fire), "1-4 players", "players text")
	Spec.eq(LobbyQueue.pips(2, 5), "**...", "pips")
	for _, m in Missions do
		local d = LobbyQueue.difficulty(m)
		Spec.truthy(d >= 1 and d <= 5, `{m.id} difficulty in 1..5`)
	end
end)

return Spec.finish()
