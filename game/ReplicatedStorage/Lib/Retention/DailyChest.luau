--!strict
-- DailyChest [owner: Retention]. PURE (no Roblox APIs; game/tests/daily_chest.spec.luau runs it in the luau CLI).
-- The DAILY CHEST: after your first completed call of the (UTC) day you get a small FREE reward. Coming back
-- the next day grows the streak 1 -> 7 (then it starts over at 1); missing a day starts it over at 1.
-- Never Robux, never random, never a paid item: the reward of each streak day is fixed below.
-- Services/ResultsFlowService grants it server-side (profile `daily`, ProfileSchema); the results screen
-- (Controllers/ResultsController) only draws what the server granted.
--
--   DailyChest.Days                                   -- streak day -> { xp, cosmetic? } (cosmetic = DataConfig.Cosmetics id)
--   DailyChest.OwnedBonusXp                           -- extra XP instead of a cosmetic you already own
--   DailyChest.dayOf(unixSeconds) -> number           -- UTC day number
--   DailyChest.blank() -> Daily
--   DailyChest.canClaim(d, today) -> boolean          -- not opened yet today
--   DailyChest.nextStreak(d, today) -> number         -- the streak day a chest opened today would be
--   DailyChest.claim(d, today) -> (ok, streakDay)     -- mutates d; idempotent per day
--   DailyChest.reward(streakDay, owned) -> Reward     -- what that day gives (owned cosmetic -> bonus XP)
local DailyChest = {}

export type Daily = { lastDay: number, streak: number, total: number }
export type Reward = { day: number, xp: number, cosmetic: string?, id: string }

DailyChest.MaxStreak = 7
DailyChest.OwnedBonusXp = 25
-- small, free and the same for everyone: XP every day, a cosmetic on days 3, 5 and 7
DailyChest.Days = table.freeze({
	table.freeze({ xp = 25 }),
	table.freeze({ xp = 35 }),
	table.freeze({ xp = 50, cosmetic = "helmet_yellow" }),
	table.freeze({ xp = 60 }),
	table.freeze({ xp = 75, cosmetic = "hose_green" }),
	table.freeze({ xp = 90 }),
	table.freeze({ xp = 150, cosmetic = "helmet_pink" }),
})

function DailyChest.dayOf(unixSeconds: number): number
	return math.floor(unixSeconds / 86400)
end

function DailyChest.blank(): Daily
	return { lastDay = 0, streak = 0, total = 0 }
end

function DailyChest.canClaim(d: Daily, today: number): boolean
	return d.lastDay < today
end

function DailyChest.nextStreak(d: Daily, today: number): number
	if d.lastDay == today then
		return d.streak -- already opened today
	end
	if d.lastDay == today - 1 and d.streak >= 1 then
		return (d.streak % DailyChest.MaxStreak) + 1
	end
	return 1
end

function DailyChest.claim(d: Daily, today: number): (boolean, number)
	if not DailyChest.canClaim(d, today) then
		return false, d.streak
	end
	local streak = DailyChest.nextStreak(d, today)
	d.lastDay = today
	d.streak = streak
	d.total += 1
	return true, streak
end

function DailyChest.reward(streakDay: number, owned: { [string]: boolean }?): Reward
	local day = math.clamp(math.floor(streakDay), 1, DailyChest.MaxStreak)
	local def = DailyChest.Days[day]
	local xp = def.xp
	local cosmetic: string? = def.cosmetic
	if cosmetic and owned and owned[cosmetic] then
		xp += DailyChest.OwnedBonusXp
		cosmetic = nil
	end
	return { day = day, xp = xp, cosmetic = cosmetic, id = if cosmetic then cosmetic else `xp{xp}` }
end

return DailyChest
