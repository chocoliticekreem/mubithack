--!strict
-- ColdOpen: Onboarding v3's cutscene timing, what skips it, and the HUD reveal schedule.
local Spec = require("./Spec")
local ColdOpen = require("../ReplicatedStorage/Lib/Onboarding/ColdOpen")

Spec.test("the cutscene is 6-8 s and its shots run in order", function()
	Spec.eq(ColdOpen.Length >= 6 and ColdOpen.Length <= 8, true)
	Spec.eq((ColdOpen.shotAt(0)), "house")
	Spec.eq((ColdOpen.shotAt(2.3)), "house")
	Spec.eq((ColdOpen.shotAt(2.5)), "truck")
	Spec.eq((ColdOpen.shotAt(5)), "title")
	Spec.eq((ColdOpen.shotAt(7)), "end")
	Spec.eq((ColdOpen.shotAt(99)), "end")
	local _, a = ColdOpen.shotAt(1.2)
	Spec.eq(math.abs(a - 0.5) < 1e-6, true) -- halfway through the 2.4 s house shot
end)

Spec.test("skippable only after the minimum", function()
	Spec.eq(ColdOpen.canSkip(1.9, 2), false)
	Spec.eq(ColdOpen.canSkip(2, 2), true)
end)

Spec.test("any tap / key / button skips; moves, wheel and the Roblox menu don't", function()
	Spec.eq(ColdOpen.isSkipInput("Touch", "Unknown"), true)
	Spec.eq(ColdOpen.isSkipInput("MouseButton1", "Unknown"), true)
	Spec.eq(ColdOpen.isSkipInput("Keyboard", "Space"), true)
	Spec.eq(ColdOpen.isSkipInput("Keyboard", "W"), true)
	Spec.eq(ColdOpen.isSkipInput("Gamepad1", "ButtonA"), true)
	Spec.eq(ColdOpen.isSkipInput("Gamepad1", "ButtonR2"), true)
	Spec.eq(ColdOpen.isSkipInput("Keyboard", "Escape"), false)
	Spec.eq(ColdOpen.isSkipInput("Gamepad1", "ButtonStart"), false)
	Spec.eq(ColdOpen.isSkipInput("Gamepad1", "Thumbstick1"), false)
	Spec.eq(ColdOpen.isSkipInput("MouseMovement", "Unknown"), false)
	Spec.eq(ColdOpen.isSkipInput("MouseWheel", "Unknown"), false)
end)

local function f(o: any): ColdOpen.Facts
	return {
		gated = o.gated ~= false,
		phase = o.phase,
		onCall = o.onCall == true,
		callDone = o.callDone == true,
		xp = o.xp == true,
		cutscene = o.cutscene == true,
	}
end

Spec.test("stages: cold -> saved -> on call -> done", function()
	Spec.eq(ColdOpen.stage(f({ phase = "burning" })), ColdOpen.Stage.Cold)
	Spec.eq(ColdOpen.stage(f({ phase = "panda" })), ColdOpen.Stage.Cold)
	Spec.eq(ColdOpen.stage(f({})), ColdOpen.Stage.Cold) -- before the server says anything
	Spec.eq(ColdOpen.stage(f({ phase = "done" })), ColdOpen.Stage.Saved)
	Spec.eq(ColdOpen.stage(f({ phase = "queued" })), ColdOpen.Stage.Saved)
	Spec.eq(ColdOpen.stage(f({ phase = "open" })), ColdOpen.Stage.Saved) -- NOT YET / no pad free
	Spec.eq(ColdOpen.stage(f({ phase = "launched", onCall = true })), ColdOpen.Stage.OnCall)
	Spec.eq(ColdOpen.stage(f({ phase = "launched", callDone = true })), ColdOpen.Stage.Done)
	Spec.eq(ColdOpen.stage(f({ phase = "skipped" })), ColdOpen.Stage.Done) -- SKIP TUTORIAL
	Spec.eq(ColdOpen.stage(f({ gated = false })), ColdOpen.Stage.Done) -- returning player
end)

Spec.test("returning players see the whole HUD", function()
	for _, k in ColdOpen.HudKeys do
		Spec.eq(ColdOpen.hudVisible(k, f({ gated = false })), true)
	end
end)

Spec.test("nothing over the cold open, then one piece at a time", function()
	for _, k in ColdOpen.HudKeys do
		Spec.eq(ColdOpen.hudVisible(k, f({ phase = "burning", cutscene = true, xp = true })), false)
		Spec.eq(ColdOpen.hudVisible(k, f({ phase = "burning" })), false) -- spraying: minimal UI
	end
	-- the first XP shows the XP bar, nothing else
	Spec.eq(ColdOpen.hudVisible("xp", f({ phase = "panda", xp = true })), true)
	Spec.eq(ColdOpen.hudVisible("help", f({ phase = "panda", xp = true })), false)
	-- the panda is saved: XP, HELP and the D-pad legend (GO NOW on the first-call card)
	local saved = f({ phase = "queued", xp = true })
	Spec.eq(ColdOpen.hudVisible("xp", saved), true)
	Spec.eq(ColdOpen.hudVisible("help", saved), true)
	Spec.eq(ColdOpen.hudVisible("dpad", saved), true)
	Spec.eq(ColdOpen.hudVisible("minimap", saved), false)
	Spec.eq(ColdOpen.hudVisible("store", saved), false)
	-- on the call: the minimap for the drive
	local onCall = f({ phase = "launched", onCall = true, xp = true })
	Spec.eq(ColdOpen.hudVisible("minimap", onCall), true)
	Spec.eq(ColdOpen.hudVisible("pass", onCall), false)
	Spec.eq(ColdOpen.hudVisible("offer", onCall), false)
	-- the first call is complete: everything
	for _, k in ColdOpen.HudKeys do
		Spec.eq(ColdOpen.hudVisible(k, f({ phase = "launched", callDone = true })), true)
	end
end)

Spec.test("offers, the like ask and news never before the first call is complete", function()
	for _, phase in { "burning", "panda", "done", "queued", "open", "launched" } do
		for _, onCall in { false, true } do
			local x = f({ phase = phase, onCall = onCall, xp = true })
			Spec.eq(ColdOpen.hudVisible("offer", x), false)
			Spec.eq(ColdOpen.hudVisible("invite", x), false)
			Spec.eq(ColdOpen.hudVisible("news", x), false)
		end
	end
end)

return Spec.finish()
