--!strict
-- FirstFire: the first-30-seconds training fire, the auto-queued first call and session buckets.
local Spec = require("./Spec")
local FirstFire = require("../ReplicatedStorage/Lib/Onboarding/FirstFire")

Spec.test("only brand-new players in the lobby get the training fire", function()
	Spec.eq(FirstFire.shouldRun(false, false, true), true)
	Spec.eq(FirstFire.shouldRun(true, false, true), false) -- returning player
	Spec.eq(FirstFire.shouldRun(nil, false, true), false) -- profile not loaded yet
	Spec.eq(FirstFire.shouldRun(false, true, true), false) -- already on a call
	Spec.eq(FirstFire.shouldRun(false, false, false), false) -- feature off
end)

Spec.test("slots wrap round robin", function()
	Spec.eq(FirstFire.slotFor(1, 3), 1)
	Spec.eq(FirstFire.slotFor(3, 3), 3)
	Spec.eq(FirstFire.slotFor(4, 3), 1)
	Spec.eq(FirstFire.slotFor(0, 3), 1)
	Spec.eq(FirstFire.slotFor(5, 0), 1)
end)

Spec.test("first call prefers an empty pad, lowest id", function()
	local pads = {
		{ padId = 1, members = 2, capacity = 8 },
		{ padId = 3, members = 0, capacity = 8 },
		{ padId = 2, members = 0, capacity = 8 },
	}
	Spec.eq(FirstFire.pickPad(pads), 2)
end)

Spec.test("no empty pad: join the fullest pad that has room", function()
	local pads = {
		{ padId = 1, members = 8, capacity = 8 },
		{ padId = 2, members = 3, capacity = 8 },
		{ padId = 3, members = 1, capacity = 8 },
	}
	Spec.eq(FirstFire.pickPad(pads), 2)
end)

Spec.test("every pad full: nil", function()
	Spec.eq(FirstFire.pickPad({ { padId = 1, members = 4, capacity = 4 } }), nil)
	Spec.eq(FirstFire.pickPad({}), nil)
end)

Spec.test("session buckets", function()
	Spec.eq(FirstFire.bucket(0), "lt1m")
	Spec.eq(FirstFire.bucket(59.9), "lt1m")
	Spec.eq(FirstFire.bucket(60), "1to5m")
	Spec.eq(FirstFire.bucket(899), "5to15m")
	Spec.eq(FirstFire.bucket(1800), "30to60m")
	Spec.eq(FirstFire.bucket(99999), "ge60m")
end)

Spec.test("cards: fire while burning, reward pop for a few seconds after", function()
	Spec.eq(FirstFire.card("burning", 0, 3), "fire")
	Spec.eq(FirstFire.card("done", 1, 3), "done")
	Spec.eq(FirstFire.card("done", 10, 3), "done") -- not queued yet: keep the pop up
	Spec.eq(FirstFire.card("open", 1, 3), nil) -- no pad free: the regular tutorial takes over
	Spec.eq(FirstFire.card("queued", 2.9, 3), "done")
	Spec.eq(FirstFire.card("queued", 3.1, 3), "call") -- on the pad: what's happening + GO NOW / NOT YET
	Spec.eq(FirstFire.card("launched", 5, 3), nil)
	Spec.eq(FirstFire.card(nil, 0, 3), nil)
	Spec.eq(FirstFire.card("skipped", 0, 3), nil)
end)

return Spec.finish()
