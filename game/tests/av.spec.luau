--!strict
-- AvLogic: preset choice, crackle budget, smoke weight, roar volume, rate limit, music choice.
local Spec = require("./Spec")
local AvLogic = require("../StarterPlayerScripts/Lib/AvLogic")

local known = { DuskSuburb = true, NightStreet = true, StationGolden = true }
local function exists(n: string): boolean
	return known[n] == true
end
local byLoc = { Town = "DuskSuburb", Apartment = "NightStreet", Bogus = "Nope" }

Spec.test("override wins when it exists", function()
	Spec.eq(AvLogic.pickPreset("NightStreet", "Town", byLoc, "StationGolden", "DuskSuburb", exists), "NightStreet")
end)

Spec.test("bad override falls through to the location", function()
	Spec.eq(AvLogic.pickPreset("Typo", "Apartment", byLoc, nil, "DuskSuburb", exists), "NightStreet")
end)

Spec.test("unknown location mapping falls to the server default, then fallback", function()
	Spec.eq(AvLogic.pickPreset(nil, "Bogus", byLoc, "StationGolden", "DuskSuburb", exists), "StationGolden")
	Spec.eq(AvLogic.pickPreset("", nil, byLoc, nil, "DuskSuburb", exists), "DuskSuburb")
end)

local function p(x: number, y: number?, z: number?): AvLogic.P3
	return { x = x, y = y or 0, z = z or 0 }
end

Spec.test("pickNearest caps, sorts nearest first and respects radius", function()
	local pts = { p(50), p(5), p(500), p(20), p(35) }
	local got = AvLogic.pickNearest(p(0), pts, 2, 100, 0)
	Spec.eq(#got, 2)
	Spec.eq(got[1], 2)
	Spec.eq(got[2], 4)
	local all = AvLogic.pickNearest(p(0), pts, 10, 100, 0)
	Spec.eq(#all, 4, "500 is out of radius")
end)

Spec.test("pickNearest keeps one per cluster", function()
	local pts = { p(10), p(12), p(14), p(40) }
	local got = AvLogic.pickNearest(p(0), pts, 6, 100, 8)
	Spec.eq(#got, 2)
	Spec.eq(got[1], 1)
	Spec.eq(got[2], 4)
end)

Spec.test("smokeWeight: none, outdoor damped, indoor full", function()
	Spec.eq(AvLogic.smokeWeight(0, true, 4), 0)
	Spec.near(AvLogic.smokeWeight(4, false, 4), 0.35)
	Spec.eq(AvLogic.smokeWeight(10, true, 4), 1)
	Spec.near(AvLogic.smokeWeight(2, true, 4), 0.5)
end)

Spec.test("roarVolume scales and caps", function()
	Spec.eq(AvLogic.roarVolume(0, 30, 0.6), 0)
	Spec.near(AvLogic.roarVolume(15, 30, 0.6), 0.3)
	Spec.near(AvLogic.roarVolume(90, 30, 0.6), 0.6)
end)

Spec.test("streakPitch rises and caps at +50%", function()
	Spec.eq(AvLogic.streakPitch(1, 0.05), 1)
	Spec.near(AvLogic.streakPitch(3, 0.05), 1.1)
	Spec.near(AvLogic.streakPitch(40, 0.05), 1.5)
end)

Spec.test("rateAllow lets perSecond through then blocks, refills over time", function()
	local s: AvLogic.Rate? = nil
	local okCount = 0
	for _ = 1, 10 do
		local ok
		ok, s = AvLogic.rateAllow(s, 0, 4)
		if ok then
			okCount += 1
		end
	end
	Spec.eq(okCount, 4)
	local ok2 = AvLogic.rateAllow(s, 0.5, 4)
	Spec.truthy(ok2, "refilled after 0.5 s")
end)

Spec.test("musicFor maps round states", function()
	Spec.eq(AvLogic.musicFor(nil), "LobbyMusic")
	Spec.eq(AvLogic.musicFor("Lobby"), "LobbyMusic")
	Spec.eq(AvLogic.musicFor("Alarm"), "MissionMusic")
	Spec.eq(AvLogic.musicFor("Active"), "MissionMusic")
	Spec.eq(AvLogic.musicFor("Results"), "ResultsMusic")
end)

Spec.test("inBox with margin", function()
	Spec.truthy(AvLogic.inBox(p(10, 0, 0), p(0), p(8, 8, 8), 4))
	Spec.eq(AvLogic.inBox(p(13, 0, 0), p(0), p(8, 8, 8), 4), false)
end)

return Spec.finish()
