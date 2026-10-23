--!strict
-- PopupLogic: feedback modes, per-subject replace, global cap, dedupe window, screen-toast stack.
local Spec = require("./Spec")
local P = require("../StarterPlayerScripts/Lib/PopupLogic")

local function world()
	return P.new({ cap = 6, perSubject = 1, dedupeSeconds = 2, lifeSeconds = 1 })
end

Spec.test("mode parses numbers and strings, defaults to Normal", function()
	Spec.eq(P.mode(0), "Normal")
	Spec.eq(P.mode(1), "Minimal")
	Spec.eq(P.mode(2), "Off")
	Spec.eq(P.mode(9), "Off")
	Spec.eq(P.mode("minimal"), "Minimal")
	Spec.eq(P.mode("OFF"), "Off")
	Spec.eq(P.mode(nil), "Normal")
	Spec.eq(P.mode("loud"), "Normal")
	Spec.eq(P.index("Minimal"), 1)
end)

Spec.test("Off shows nothing, Minimal only your own", function()
	local s = world()
	Spec.eq(P.admit(s, 0, "a", "BONK!", "Off", true).show, false)
	Spec.eq(P.admit(s, 0, "a", "BONK!", "Minimal", false).reason, "mode")
	Spec.eq(P.admit(s, 0, "a", "BONK!", "Minimal", true).show, true)
	Spec.eq(P.admit(s, 0, "b", "OOF!", "Normal", false).show, true)
end)

Spec.test("newest replaces the old popup over the same subject", function()
	local s = world()
	local first = P.admit(s, 0, "npc1", "HELP!")
	local second = P.admit(s, 0.1, "npc1", "AAAH!")
	Spec.eq(second.show, true)
	Spec.eq(#second.evict, 1)
	Spec.eq(second.evict[1], first.id)
	Spec.eq(P.count(s), 1)
end)

Spec.test("global cap evicts the oldest", function()
	local s = world()
	local ids = {}
	for i = 1, 6 do
		local d = P.admit(s, i * 0.01, `s{i}`, "x")
		table.insert(ids, d.id)
		Spec.eq(#d.evict, 0)
	end
	local d = P.admit(s, 0.1, "s7", "x")
	Spec.eq(d.show, true)
	Spec.eq(#d.evict, 1)
	Spec.eq(d.evict[1], ids[1], "oldest evicted")
	Spec.eq(P.count(s), 6)
end)

Spec.test("repeats within 2 s are dropped, after 2 s they show again", function()
	local s = world()
	Spec.eq(P.admit(s, 0, "a", "SLAP!").show, true)
	Spec.eq(P.admit(s, 1.9, "a", "SLAP!").reason, "dupe")
	Spec.eq(P.admit(s, 1.0, "b", "SLAP!").show, true, "other subject is not a dupe")
	Spec.eq(P.admit(s, 1.0, "a", "OOF!").show, true, "other text is not a dupe")
	Spec.eq(P.admit(s, 2.1, "a", "SLAP!").show, true)
end)

Spec.test("a dropped repeat does not extend the dedupe window", function()
	local s = world()
	P.admit(s, 0, "a", "HONK!")
	P.admit(s, 1.5, "a", "HONK!") -- dropped
	Spec.eq(P.admit(s, 2.05, "a", "HONK!").show, true)
end)

Spec.test("release frees a slot; stale entries expire without a release", function()
	local s = world()
	local d = P.admit(s, 0, "a", "x")
	P.admit(s, 0, "b", "y")
	P.release(s, d.id)
	Spec.eq(P.count(s), 1)
	P.admit(s, 5, "c", "z") -- "b" is long past its life
	Spec.eq(P.count(s), 1)
end)

Spec.test("screen toasts: max 2 visible, oldest goes, dupes dropped", function()
	local s = P.new({ cap = 2, perSubject = 2, dedupeSeconds = 2, lifeSeconds = 2.5 })
	local a = P.admit(s, 0, "screen", "DISPATCH: Kitchen fire")
	local b = P.admit(s, 0.2, "screen", "ROLL OUT!")
	Spec.eq(#b.evict, 0)
	Spec.eq(P.admit(s, 0.3, "screen", "ROLL OUT!").reason, "dupe")
	local c = P.admit(s, 0.4, "screen", "ON SCENE!")
	Spec.eq(#c.evict, 1)
	Spec.eq(c.evict[1], a.id)
	Spec.eq(P.count(s), 2)
end)

return Spec.finish()
