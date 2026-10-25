--!strict
-- PadNav: which button a gamepad lands on when a menu opens, which menu owns the cursor.
local Spec = require("./Spec")
local P = require("../StarterPlayerScripts/Lib/PadNav")

Spec.test("close buttons are recognised by name or text", function()
	Spec.truthy(P.closeLike("Close", "X"))
	Spec.truthy(P.closeLike("Foo", " CLOSE "))
	Spec.truthy(P.closeLike("No", "No thanks"))
	Spec.truthy(not P.closeLike("NextCallButton", "NEXT CALL!"))
	Spec.truthy(not P.closeLike("Buy", "BUY  R$ 149"))
end)

Spec.test("a menu opens on its first real button, never on CLOSE", function()
	local cands = {
		{ name = "Close", text = "X", x = 600, y = 10 },
		{ name = "ItemB", text = "BUY", x = 300, y = 120 },
		{ name = "ItemA", text = "BUY", x = 100, y = 130 }, -- same row as ItemB (within RowPx): left wins
		{ name = "Footer", text = "MORE", x = 50, y = 400 },
	}
	Spec.eq(P.pickDefault(cands), 3)
end)

Spec.test("an explicit default wins; only a close button left -> close", function()
	Spec.eq(P.pickDefault({ { name = "A", x = 0, y = 0 }, { name = "Next", x = 9, y = 9, default = true } }), 2)
	Spec.eq(P.pickDefault({ { name = "Close", text = "GOT IT", x = 0, y = 0 } }), 1)
	Spec.eq(P.pickDefault({}), nil)
end)

Spec.test("HUD focus prefers the call to action, else top-left", function()
	local cands = { { name = "StoreChip", x = 300, y = 20 }, { name = "HelpChip", x = 16, y = 680 }, { name = "Accept", x = 500, y = 140 } }
	Spec.eq(P.pickHud(cands, { "Accept", "GoNow" }), 3)
	Spec.eq(P.pickHud(cands, { "Nope" }), 1)
end)

Spec.test("the top menu: higher DisplayOrder, then the newest", function()
	Spec.eq(P.topMenu({ { order = 50, opened = 1 }, { order = 60, opened = 0 } }), 2)
	Spec.eq(P.topMenu({ { order = 50, opened = 1 }, { order = 50, opened = 2 } }), 2)
	Spec.eq(P.topMenu({}), nil)
end)

Spec.finish()
