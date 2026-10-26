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
		Spec.eq(string.match(v, "^%a%w*$") ~= nil, true)
	end
end)

Spec.test("minutes rounds and clamps", function()
	Spec.eq(Funnel.minutes(0), 0)
	Spec.eq(Funnel.minutes(29), 0)
	Spec.eq(Funnel.minutes(31), 1)
	Spec.eq(Funnel.minutes(600), 10)
	Spec.eq(Funnel.minutes(-5), 0)
end)

Spec.test("onboarding v3 funnel: its own name, 17 constant steps, legacy funnel untouched", function()
	Spec.eq(Funnel.V3FunnelName, "OnboardingV3")
	Spec.eq(#Funnel.OnboardingV3, 17)
	Spec.eq(Funnel.OnboardingV3[3], "Cutscene Shown")
	Spec.eq(Funnel.OnboardingV3[9], "Panda Saved")
	Spec.eq(Funnel.OnboardingV3[10], "HUD Revealed")
	Spec.eq(Funnel.OnboardingV3[17], "Back In Lobby")
	Spec.eq(#Funnel.Onboarding, 12) -- the legacy funnel keeps its numbers
	local seen = {}
	for _, n in Funnel.OnboardingV3 do
		Spec.eq(seen[n], nil)
		seen[n] = true
		Spec.eq(string.match(n, "^[%a ]+$") ~= nil, true)
	end
	local t = Funnel.new()
	Spec.eq(Funnel.reach(t, Funnel.OnboardingV3, "Cutscene Ended"), 4)
	Spec.eq(Funnel.reach(t, Funnel.OnboardingV3, "Cutscene Shown"), nil)
	Spec.eq(Funnel.reach(t, Funnel.OnboardingV3, "Auto Queued"), nil) -- a legacy-only step
end)

Spec.test("device: phone / tablet / PC / console", function()
	local function d(o: any): string
		return Funnel.device({
			touch = o.touch == true,
			keyboard = o.keyboard == true,
			mouse = o.mouse == true,
			gamepad = o.gamepad == true,
			tenFoot = o.tenFoot == true,
			viewportX = o.x or 1280,
			viewportY = o.y or 720,
		})
	end
	Spec.eq(d({ touch = true, x = 844, y = 390 }), "Phone")
	Spec.eq(d({ touch = true, x = 1180, y = 820 }), "Tablet")
	Spec.eq(d({ keyboard = true, mouse = true }), "PC")
	Spec.eq(d({ keyboard = true, mouse = true, gamepad = true }), "PC") -- a pad plugged into a PC
	Spec.eq(d({ touch = true, keyboard = true, mouse = true }), "PC") -- touch-screen laptop
	Spec.eq(d({ gamepad = true, tenFoot = true }), "Console")
	Spec.eq(d({ gamepad = true }), "Console")
	Spec.eq(Funnel.isDevice("Phone"), true)
	Spec.eq(Funnel.isDevice("Unknown"), true)
	Spec.eq(Funnel.isDevice("Toaster"), false)
	Spec.eq(Funnel.isDevice(nil), false)
end)

Spec.test("pad / results / chest events are constant names", function()
	for _, n in { "PadWaitSeconds", "PadLeftBeforeLaunch", "ResultsChoice", "DailyChestOpened" } do
		Spec.eq((Funnel.Events :: any)[n], n)
	end
end)

return Spec.finish()
