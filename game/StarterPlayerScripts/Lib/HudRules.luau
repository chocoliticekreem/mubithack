--!strict
-- HudRules [owner: G3]. Pure rules for the decluttered HUD (docs/game/22-declutter.md), spec-tested
-- (game/tests/hud_rules.spec.luau). No Instances here.
--   HudRules.menuMode(n) -> "none" | "single" | "menu"   lobby chips (PASS, NEWS, ...) available right now:
--                                                         none = no ☰, one = that chip alone where ☰ sits,
--                                                         more = one ☰ MENU chip that opens a grid
--   HudRules.grid(n, cellW, cellH, gap) -> { cols, rows, w, h, cells = { {x, y} } }   the ☰ panel's grid
--                                                         (2 columns up to 4 chips, then 3), cells from the
--                                                         panel's top-left, in chip order
--   HudRules.timerShown(instanceId, state) -> boolean     the call timer: only on YOUR call ("Active" /
--                                                         "Alarm" in your own run; the Workspace summary of
--                                                         somebody else's call never shows in the lobby)
--   HudRules.squadShown(instanceId, members) -> boolean   the squad strip: only on a call with 2+ of you
--   HudRules.pillExpanded(now, openUntil) -> boolean      the 🎁 chest pill shows its full card until then
local HudRules = {}

function HudRules.menuMode(n: number): string
	if n <= 0 then
		return "none"
	elseif n == 1 then
		return "single"
	end
	return "menu"
end

export type Grid = { cols: number, rows: number, w: number, h: number, cells: { { x: number, y: number } } }

function HudRules.grid(n: number, cellW: number, cellH: number, gap: number): Grid
	local count = math.max(0, n)
	local cols = if count <= 4 then 2 else 3
	cols = math.max(1, math.min(cols, count))
	local rows = if count == 0 then 0 else math.ceil(count / cols)
	local cells = {}
	for i = 0, count - 1 do
		local c, r = i % cols, i // cols
		table.insert(cells, { x = gap + c * (cellW + gap), y = gap + r * (cellH + gap) })
	end
	return {
		cols = cols,
		rows = rows,
		w = gap + cols * (cellW + gap),
		h = gap + rows * (cellH + gap),
		cells = cells,
	}
end

function HudRules.timerShown(instanceId: string?, state: string?): boolean
	if type(instanceId) ~= "string" or instanceId == "" then
		return false
	end
	return state == "Active" or state == "Alarm"
end

function HudRules.squadShown(instanceId: string?, members: number): boolean
	return type(instanceId) == "string" and instanceId ~= "" and members > 1
end

function HudRules.pillExpanded(now: number, openUntil: number): boolean
	return now < openUntil
end

return HudRules
