--!strict
-- HintText: keyboard hints rewritten for touch (the on-screen button that does it) and gamepad.
local Spec = require("./Spec")
local H = require("../StarterPlayerScripts/Lib/HintText")

local function touch(s: string, ctx: any?): string
	return H.format(s, "touch", ctx)
end

Spec.test("keyboard text is never touched", function()
	Spec.eq(H.format("Walk up and press E. [G] DROP", "keyboard"), "Walk up and press E. [G] DROP")
	Spec.eq(H.chip("P", "PASS", "keyboard"), "[P] PASS")
	Spec.eq(H.chip("J", "SKIP", "keyboard", true), "SKIP [J]")
	Spec.eq(H.label("hold Q", "keyboard"), "hold Q")
end)

Spec.test("prompt keys become the prompt's own button", function()
	Spec.eq(touch("Walk up and press E."), "Walk up and tap the button.")
	Spec.eq(touch("Out front by the bays. Press E to pick a call."), "Out front by the bays. Tap the button to pick a call.")
	Spec.eq(touch("Open YOUR truck's door (E)"), "Open YOUR truck's door (tap)")
	Spec.eq(touch("Driver's seat: press F"), "Driver's seat: tap the button")
	Spec.eq(touch("Fuse box on the wall. Hold E. Do NOT stand in it."), "Fuse box on the wall. Hold the button. Do NOT stand in it.")
	Spec.eq(touch("Too heavy! A buddy must hold [E] too"), "Too heavy! A buddy must hold the button too")
	Spec.eq(touch("Hydrant: press R to grab the supply line"), "Hydrant: tap the button to grab the supply line")
	Spec.eq(touch("Unhook it [R] before you drive off!"), "Unhook it (tap) before you drive off!")
end)

Spec.test("a bare key in a sentence", function()
	Spec.eq(touch("Neighbours, a cat... E to pick up."), "Neighbours, a cat... Tap to pick up.")
	Spec.eq(touch("Door's off: E to pick them up."), "Door's off: tap to pick them up.")
	Spec.eq(touch("Climb up, E on the cat."), "Climb up, tap the button on the cat.")
	Spec.eq(touch("Your arms are full! (G to drop)"), "Your arms are full! (tap DROP to drop)")
end)

Spec.test("keys with their own touch button use its title", function()
	Spec.eq(touch("Yeeting (hold Q) also counts."), "Yeeting (hold THROW) also counts.")
	Spec.eq(touch("[G] DROP   [hold Q] YEET", { Q = { touch = "YEET" } }), "(DROP) DROP   (hold YEET) YEET")
	Spec.eq(touch("Your back. Press 1 or 2 to swap it."), "Your back. Tap SWAP to swap it.")
	Spec.eq(touch("Pick it at your rack: LOCKER [R]"), "Pick it at your rack: LOCKER (tap)")
end)

Spec.test("click becomes tap, keys without a touch way are left alone", function()
	Spec.eq(touch("What you hold. CLICK to use it."), "What you hold. TAP to use it.")
	Spec.eq(touch("Click to toggle."), "Tap to toggle.")
	Spec.eq(touch("face the trunk and click."), "face the trunk and tap.")
	Spec.eq(touch("press V"), "press V")
	Spec.eq(touch("W/S drive"), "stick drive")
	Spec.eq(touch("(R$ 5) [Config] Plan B"), "(R$ 5) [Config] Plan B")
end)

Spec.test("no raw key token survives in the shipped hint copy", function()
	local lines = {
		"Your rack is #01 in the locker room. Walk up and press E.",
		"Stand by any side of your truck, press T. Or E on a hydrant. It's a leash.",
		"The city below is toast. Carry folks up (E).",
		"Both of you press E on the panda.",
		"Pick it in your locker (R), hold it, face the trunk and click.",
		"Hold E on each red valve wheel before the tanker timer hits zero.",
		"YOWCH! Hot handle. Feel the door first! (T)",
		"@_@  Crawl to a teammate! Oxygen (E) or SLAP (F)  5s",
	}
	for _, l in lines do
		local out = touch(l)
		Spec.truthy(string.find(out, "%[[%u;]%]") == nil, out)
		Spec.truthy(string.find(out, "%f[%a][Pp]ress %u%f[^%w]") == nil, out)
		Spec.truthy(string.find(out, "%f[%a][Hh]old %u%f[^%w]") == nil, out)
		Spec.truthy(string.find(out, "%(%u%)") == nil, out)
	end
end)

Spec.test("first-fire card: LEFT CLICK is the screen on a phone, R2 on a gamepad", function()
	Spec.eq(touch("Hold LEFT CLICK to spray your extinguisher at it"), "Hold the screen to spray your extinguisher at it")
	Spec.eq(H.format("Hold LEFT CLICK to spray", "gamepad"), "Hold R2 to spray")
	Spec.eq(touch("Hold left click to spray"), "Hold the screen to spray")
end)

Spec.test("keycaps and chips", function()
	Spec.eq(H.label("E", "touch"), "TAP")
	Spec.eq(H.label("hold Q", "touch"), "HOLD THROW")
	Spec.eq(H.label("G", "touch"), "DROP")
	Spec.eq(H.label("V", "touch"), nil)
	Spec.eq(H.label("Z", "touch"), nil)
	Spec.eq(H.label("WALK", "touch"), "WALK")
	Spec.eq(H.label("G", "touch", { G = { touch = "SIREN", pad = "X" } }), "SIREN")
	Spec.eq(H.chip("H", "HELP", "touch"), "HELP")
end)

Spec.test("gamepad uses the controller buttons", function()
	Spec.eq(H.format("Walk up and press E.", "gamepad"), "Walk up and press X.")
	Spec.eq(H.format("[G] DROP", "gamepad"), "(B) DROP")
	Spec.eq(H.format("click to stand it up", "gamepad"), "press R2 to stand it up")
	Spec.eq(H.label("G", "gamepad"), "B")
	Spec.eq(H.label("P", "gamepad"), nil)
end)

Spec.finish()
