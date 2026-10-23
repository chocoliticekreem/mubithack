--!strict
-- SquadRules: helmets, wipe, revive checks, slap blame, emotes, orbits, lobby detection.
local Spec = require("./Spec")
local R = require("../ServerScriptService/Lib/Squad/SquadRules")

Spec.test("pickHelmet takes the lowest free number", function()
	Spec.eq(R.pickHelmet({}, 4), 1)
	Spec.eq(R.pickHelmet({ [1] = true }, 4), 2)
	Spec.eq(R.pickHelmet({ [1] = true, [2] = true, [4] = true }, 4), 3)
end)

Spec.test("pickHelmet wraps when the squad is full", function()
	local n = R.pickHelmet({ [1] = true, [2] = true, [3] = true, [4] = true }, 4)
	Spec.truthy(n >= 1 and n <= 4, "in range")
end)

Spec.test("badge and tag are two digits", function()
	Spec.eq(R.badge(1), "01")
	Spec.eq(R.badge(4), "04")
	Spec.eq(R.tag(2), "Firefighter 02")
	Spec.eq(R.badge(67), "67")
end)

Spec.test("isWiped needs everyone downed and enough players", function()
	Spec.eq(R.isWiped({ true, true }, 2), true)
	Spec.eq(R.isWiped({ true, false }, 2), false)
	Spec.eq(R.isWiped({ true }, 2), false, "solo below min")
	Spec.eq(R.isWiped({ true }, 1), true, "solo at min 1")
	Spec.eq(R.isWiped({}, 1), false, "empty")
end)

local function check(over: { [string]: any }): (boolean, string)
	local r = { self = false, victimDowned = true, reviverDowned = false, sameGroup = true, distance = 3, maxDistance = 9 }
	for k, v in over do
		(r :: any)[k] = v
	end
	return R.canRevive(r)
end

Spec.test("canRevive accepts a nearby healthy teammate", function()
	Spec.eq((check({})), true)
end)

Spec.test("canRevive rejects self, standing victims, downed revivers, other squads, distance", function()
	Spec.eq(select(2, check({ self = true })), "self")
	Spec.eq(select(2, check({ victimDowned = false })), "not downed")
	Spec.eq(select(2, check({ reviverDowned = true })), "reviver downed")
	Spec.eq(select(2, check({ sameGroup = false })), "other squad")
	Spec.eq(select(2, check({ distance = 20 })), "too far")
end)

Spec.test("slap revive is cheap health plus blame; oxygen is free", function()
	local cfg = { ReviveHealth = 50, SlapReviveHealth = 20, SlapBlame = 1 }
	local h, b = R.reviveOutcome("slap", cfg)
	Spec.eq(h, 20)
	Spec.eq(b, 1)
	h, b = R.reviveOutcome("oxygen", cfg)
	Spec.eq(h, 50)
	Spec.eq(b, 0)
end)

Spec.test("causeDowns follows the table and defaults to true", function()
	local causes = { heat = true, tidal_wave = false }
	Spec.eq(R.causeDowns("heat", causes), true)
	Spec.eq(R.causeDowns("tidal_wave", causes), false)
	Spec.eq(R.causeDowns("brand_new_hazard", causes), true)
end)

Spec.test("remaining counts down and floors at 0", function()
	Spec.eq(R.remaining(100, 105, 25), 20)
	Spec.eq(R.remaining(100, 200, 25), 0)
end)

Spec.test("isEmote only accepts listed strings", function()
	local emotes = { "wave", "facepalm", "blame" }
	Spec.eq(R.isEmote("wave", emotes), true)
	Spec.eq(R.isEmote("dab", emotes), false)
	Spec.eq(R.isEmote(3, emotes), false)
end)

Spec.test("orbit spaces items round the circle and spins with time", function()
	local x1, z1 = R.orbit(1, 4, 0, 2, 1)
	Spec.near(x1, 2)
	Spec.near(z1, 0)
	local x2, z2 = R.orbit(2, 4, 0, 2, 1)
	Spec.near(x2, 0, 1e-6)
	Spec.near(z2, 2)
	local x3, _ = R.orbit(1, 4, 0.5, 2, 1) -- half a turn later
	Spec.near(x3, -2)
end)

Spec.test("groupKey: instance first, v1 round second, lobby nil", function()
	Spec.eq(R.groupKey("I1", true, nil), "I1")
	Spec.eq(R.groupKey("", false, "Active"), "round")
	Spec.eq(R.groupKey("", false, "Lobby"), nil)
	Spec.eq(R.groupKey("", true, "Active"), nil, "lobby mode ignores the global round")
	Spec.eq(R.groupKey(nil, false, nil), nil)
end)

Spec.test("inLobby: emotes in the station only", function()
	Spec.eq(R.inLobby("", true, nil), true)
	Spec.eq(R.inLobby("I1", true, nil), false)
	Spec.eq(R.inLobby("", false, "Lobby"), true)
	Spec.eq(R.inLobby("", false, "Results"), true)
	Spec.eq(R.inLobby("", false, "Alarm"), false)
	Spec.eq(R.inLobby("", false, "Active"), false)
end)

return Spec.finish()
