--!strict
-- Funnel: Creator Dashboard funnel steps only move forward and every name is a constant.
local Spec = require("./Spec")
local Funnel = require("../ReplicatedStorage/Lib/Onboarding/Funnel")

Spec.test("onboarding funnel has the 12 tutorial steps in order", function()
	Spec.eq(#Funnel.Onboarding, 12)
	Spec.eq(Funnel.Onboarding[1], "Joined")
	Spec.eq(Funnel.Onboarding[3], "Saw Fire Card")
	Spec.eq(Funnel.Onboarding[6], "Auto Queued")
	Spec.eq(Funnel.Onboarding[12], "Back In Lobby")
	Spec.eq(Funnel.index(Funnel.Onboarding, "First Spray"), 4)
	Spec.eq(Funnel.index(Funnel.Onboarding, "nope"), 0)
end)

Spec.test("steps only move forward; a skipped step stays skipped", function()
	local t = Funnel.new()
	Spec.eq(Funnel.reach(t, Funnel.Onboarding, "Joined"), 1)
	Spec.eq(Funnel.reach(t, Funnel.Onboarding, "Joined"), nil) -- once
	Spec.eq(Funnel.reach(t, Funnel.Onboarding, "First Spray"), 4) -- card step never reported: skip it
	Spec.eq(Funnel.reach(t, Funnel.Onboarding, "Saw Fire Card"), nil) -- late report of an earlier step
	Spec.eq(Funnel.lastName(t, Funnel.Onboarding), "First Spray")
	Spec.eq(Funnel.reach(t, Funnel.Onboarding, "free-form text"), nil)
	Spec.eq(t.last, 4)
end)

Spec.test("lastName before any step", function()
	Spec.eq(Funnel.lastName(Funnel.new(), Funnel.Mission), "None")
end)

Spec.test("mission funnel", function()
	Spec.eq(Funnel.MissionFunnelName, "Mission")
	local t = Funnel.new()
	Spec.eq(Funnel.reach(t, Funnel.Mission, "Dispatched"), 1)
	Spec.eq(Funnel.reach(t, Funnel.Mission, "Arrived On Scene"), 3)
	Spec.eq(Funnel.reach(t, Funnel.Mission, "In Truck"), nil)
	Spec.eq(Funnel.reach(t, Funnel.Mission, "Back In Lobby"), 6)
end)

Spec.test("event names are constant identifiers", function()
	for k, v in Funnel.Events do
		Spec.eq(k, v)
		Spec.eq(string.match(v, "^[%a]+$") ~= nil, true)
	end
end)

Spec.test("minutes rounds and clamps", function()
	Spec.eq(Funnel.minutes(0), 0)
	Spec.eq(Funnel.minutes(29), 0)
	Spec.eq(Funnel.minutes(31), 1)
	Spec.eq(Funnel.minutes(600), 10)
	Spec.eq(Funnel.minutes(-5), 0)
end)

return Spec.finish()
