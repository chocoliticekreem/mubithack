--!strict
-- TeamRules [owner: Social]. PURE rules for "10x more fun with friends" (Tizyz rule #3): the COMBO hose
-- bonus, the TEAMWORK rescue bonus, the squad streak, BEST TEAMMATE and the lobby hero board's daily key.
-- No Roblox APIs, so `luau game/tests/team.spec.luau` runs it in CI. Bonuses only ADD: a solo player
-- never sees a number get worse (comboMult(1) == 1, no escort = the normal carry speed).
--
--   TeamRules.Cfg                                -- every number (one frozen table)
--   TeamRules.comboMult(hoses) -> number         -- cooling multiplier per hose when `hoses` spray one fire
--   TeamRules.activeSprayers(last, now) -> n     -- distinct sprayers inside ComboWindow (last: { [any]: time })
--   TeamRules.squadKey(userIds) -> string        -- order-free id of a group of players
--   TeamRules.nextStreak(prev, prevKey, key, won) -> number
--   TeamRules.score(row) -> number               -- BEST TEAMMATE score of one results row
--   TeamRules.best(rows) -> userId?              -- top score (> 0) of 2+ rows, ties: more rescues, then lower id
--   TeamRules.dayId(unixSeconds) -> number       -- UTC day number: the hero board's daily OrderedDataStore key
--   TeamRules.mergeTop(rows, n) -> rows          -- sort by value desc (ties: lower userId), first n
local TeamRules = {}

TeamRules.Cfg = table.freeze({
	-- COMBO: two or more hoses on the same burning part at once
	ComboWindow = 0.5, -- s: a hose "is on" a part if it hit it this recently (hoses send 10 sprays/s)
	ComboPerExtraHose = 0.5, -- each extra hose adds +50% cooling to EVERY hose on that part (2 hoses: x1.5 each)
	ComboMaxMult = 2.5, -- cap (5+ hoses)
	ComboPopSeconds = 2.5, -- one COMBO! pop per part per this long
	ComboXp = 5, -- XP to each hose in the combo...
	ComboXpCooldown = 8, -- ...at most once per player per this long
	ComboXpPerRun = 40, -- ...and at most this much per call
	-- TEAMWORK: a squadmate walks with the carrier, or sprays fires while the carry is on
	EscortRadius = 14, -- studs from the carrier
	EscortSpeedMult = 1.2, -- the carrier walks 20% faster while escorted (never slower than solo)
	ClearPathRadius = 60, -- studs: a squadmate spraying fire this close to the carrier "clears the path"
	TeamworkXp = 10, -- XP to the rescuer and each helper
	-- SQUAD STREAK: calls finished (1+ star) in a row with the same squad (2+ players)
	StreakXp = 5, -- XP x min(streak, StreakXpCap) to each member from streak 2
	StreakXpCap = 5,
	-- BEST TEAMMATE weights (results screen)
	ScoreCombo = 3,
	ScoreTeamwork = 4,
	ScoreRescue = 2,
	ScoreFire = 1,
	-- Hero board
	HeroTopN = 5,
})

local Cfg = TeamRules.Cfg

function TeamRules.comboMult(hoses: number): number
	if hoses <= 1 then
		return 1
	end
	return math.min(1 + Cfg.ComboPerExtraHose * (hoses - 1), Cfg.ComboMaxMult)
end

function TeamRules.activeSprayers(last: { [any]: number }, now: number): number
	local n = 0
	for _, t in last do
		if now - t <= Cfg.ComboWindow then
			n += 1
		end
	end
	return n
end

function TeamRules.squadKey(userIds: { number }): string
	local ids = table.clone(userIds)
	table.sort(ids)
	local parts = {}
	for _, id in ids do
		table.insert(parts, tostring(id))
	end
	return table.concat(parts, ",")
end

-- prev: the player's streak so far; prevKey: the squad it was with; key: this call's squad.
function TeamRules.nextStreak(prev: number, prevKey: string?, key: string, won: boolean): number
	if not won then
		return 0
	end
	if prevKey == key then
		return prev + 1
	end
	return 1
end

export type Row = { userId: number, name: string?, rescued: number?, firesOut: number?, combos: number?, teamwork: number? }

function TeamRules.score(row: Row): number
	return (row.combos or 0) * Cfg.ScoreCombo
		+ (row.teamwork or 0) * Cfg.ScoreTeamwork
		+ (row.rescued or 0) * Cfg.ScoreRescue
		+ (row.firesOut or 0) * Cfg.ScoreFire
end

function TeamRules.best(rows: { Row }): number?
	if #rows < 2 then
		return nil
	end
	local bestRow: Row? = nil
	local bestScore = 0
	for _, r in rows do
		local s = TeamRules.score(r)
		if s > 0 then
			local b = bestRow
			if
				b == nil
				or s > bestScore
				or (s == bestScore and (r.rescued or 0) > (b.rescued or 0))
				or (s == bestScore and (r.rescued or 0) == (b.rescued or 0) and r.userId < b.userId)
			then
				bestRow, bestScore = r, s
			end
		end
	end
	return if bestRow then bestRow.userId else nil
end

function TeamRules.dayId(unixSeconds: number): number
	return math.floor(unixSeconds / 86400)
end

export type TopRow = { userId: number, value: number, name: string? }

function TeamRules.mergeTop(rows: { TopRow }, n: number): { TopRow }
	local out = {}
	for _, r in rows do
		if r.value > 0 then
			table.insert(out, r)
		end
	end
	table.sort(out, function(a, b)
		if a.value ~= b.value then
			return a.value > b.value
		end
		return a.userId < b.userId
	end)
	while #out > n do
		table.remove(out)
	end
	return out
end

return TeamRules
