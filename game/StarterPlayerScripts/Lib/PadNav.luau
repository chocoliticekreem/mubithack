--!strict
-- PadNav: pure rules for gamepad menu focus (no Roblox APIs; spec: game/tests/pad_nav.spec.luau). The live
-- side (GuiService.SelectedObject, ButtonB, D-pad) is ClientLib/GamepadNav.
--
--   PadNav.closeLike(name, text) -> boolean      a CLOSE / X / BACK / No thanks button
--   PadNav.pickDefault(cands) -> number?         which button a menu selects when it opens:
--                                                an explicit default, else the first non-close button
--                                                reading top-left to bottom-right, else the close button
--   PadNav.pickHud(cands, priority) -> number?   which HUD button D-pad left lands on: a named
--                                                call-to-action first (ACCEPT, GO NOW...), else top-left
--   PadNav.topMenu(menus) -> number?             the menu that owns the cursor: highest DisplayOrder,
--                                                then the one opened last
local PadNav = {}

export type Cand = {
	name: string,
	text: string?,
	x: number,
	y: number,
	default: boolean?,
}

export type MenuState = { order: number, opened: number }

PadNav.RowPx = 24 -- buttons within this many px of each other vertically read as one row

local CLOSE_NAMES = { close = true, closebutton = true, x = true, back = true, no = true, nothanks = true, cancel = true }
local CLOSE_TEXT = { ["x"] = true, ["close"] = true, ["back"] = true, ["no thanks"] = true, ["cancel"] = true, ["✕"] = true }

function PadNav.closeLike(name: string, text: string?): boolean
	if CLOSE_NAMES[string.lower(name)] then
		return true
	end
	local t = string.lower(string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
	return CLOSE_TEXT[t] == true
end

local function readingOrder(a: Cand, b: Cand): boolean
	local ra, rb = math.floor(a.y / PadNav.RowPx), math.floor(b.y / PadNav.RowPx)
	if ra ~= rb then
		return ra < rb
	end
	return a.x < b.x
end

local function best(cands: { Cand }, keep: (Cand) -> boolean): number?
	local bestI: number? = nil
	for i, c in cands do
		if keep(c) and (bestI == nil or readingOrder(c, cands[bestI :: number])) then
			bestI = i
		end
	end
	return bestI
end

function PadNav.pickDefault(cands: { Cand }): number?
	for i, c in cands do
		if c.default then
			return i
		end
	end
	local i = best(cands, function(c)
		return not PadNav.closeLike(c.name, c.text)
	end)
	if i then
		return i
	end
	return best(cands, function()
		return true
	end)
end

function PadNav.pickHud(cands: { Cand }, priority: { string }): number?
	for _, want in priority do
		for i, c in cands do
			if c.name == want then
				return i
			end
		end
	end
	return best(cands, function()
		return true
	end)
end

function PadNav.topMenu(menus: { MenuState }): number?
	local bestI: number? = nil
	for i, m in menus do
		local b = if bestI then menus[bestI :: number] else nil
		if b == nil or m.order > b.order or (m.order == b.order and m.opened > b.opened) then
			bestI = i
		end
	end
	return bestI
end

return PadNav
