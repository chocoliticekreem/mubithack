--!strict
-- HudRules: the decluttered HUD (☰ menu grid, call timer, squad strip, chest pill).
local Spec = require("./Spec")
local R = require("../StarterPlayerScripts/Lib/HudRules")

Spec.test("one chip shows alone, two or more fold into the menu", function()
	Spec.eq(R.menuMode(0), "none")
	Spec.eq(R.menuMode(1), "single")
	Spec.eq(R.menuMode(2), "menu")
	Spec.eq(R.menuMode(7), "menu")
end)

Spec.test("grid: 2 columns up to 4 chips, then 3", function()
	local g = R.grid(4, 150, 52, 8)
	Spec.eq(g.cols, 2)
	Spec.eq(g.rows, 2)
	Spec.eq(g.w, 8 + 2 * 158)
	Spec.eq(g.h, 8 + 2 * 60)
	Spec.eq(g.cells[1].x, 8)
	Spec.eq(g.cells[2].x, 166)
	Spec.eq(g.cells[3].y, 68)
	local six = R.grid(6, 150, 52, 8)
	Spec.eq(six.cols, 3)
	Spec.eq(six.rows, 2)
	local seven = R.grid(7, 150, 52, 8)
	Spec.eq(seven.rows, 3)
	Spec.eq(#seven.cells, 7)
	Spec.eq(seven.cells[7].x, 8)
	Spec.eq(seven.cells[7].y, 8 + 2 * 60)
end)

Spec.test("grid of one or none never divides by zero", function()
	Spec.eq(R.grid(1, 150, 52, 8).cols, 1)
	Spec.eq(R.grid(0, 150, 52, 8).rows, 0)
end)

Spec.test("the call timer only shows on your own call", function()
	Spec.eq(R.timerShown("", "Active"), false) -- lobby: another squad's call summary on Workspace
	Spec.eq(R.timerShown(nil, "Active"), false)
	Spec.eq(R.timerShown("run1", "Active"), true)
	Spec.eq(R.timerShown("run1", "Alarm"), true)
	Spec.eq(R.timerShown("run1", "Results"), false)
end)

Spec.test("the squad strip only shows on a call with 2+ players", function()
	Spec.eq(R.squadShown("", 5), false) -- the lobby is not a squad
	Spec.eq(R.squadShown("run1", 1), false) -- solo
	Spec.eq(R.squadShown("run1", 2), true)
end)

Spec.test("the chest pill expands until its timer runs out", function()
	Spec.eq(R.pillExpanded(10, 15), true)
	Spec.eq(R.pillExpanded(15, 15), false)
end)

return Spec.finish()
