--!strict
-- DailyChest: one free chest per UTC day after a completed call; the streak grows 1..7 and wraps.
local Spec = require("./Spec")
local DailyChest = require("../ReplicatedStorage/Lib/Retention/DailyChest")

Spec.test("first chest ever is day 1, once per day", function()
	local d = DailyChest.blank()
	Spec.eq(DailyChest.canClaim(d, 20000), true)
	local ok, day = DailyChest.claim(d, 20000)
	Spec.eq(ok, true)
	Spec.eq(day, 1)
	Spec.eq(DailyChest.canClaim(d, 20000), false, "already opened today")
	local again = DailyChest.claim(d, 20000)
	Spec.eq(again, false, "idempotent per day")
	Spec.eq(d.total, 1)
end)

Spec.test("coming back the next day grows the streak, 7 wraps to 1, a missed day restarts", function()
	local d = DailyChest.blank()
	for i = 1, 7 do
		local _, day = DailyChest.claim(d, 100 + i)
		Spec.eq(day, i)
	end
	local _, day8 = DailyChest.claim(d, 108)
	Spec.eq(day8, 1, "after day 7 the week starts over")
	local _, day9 = DailyChest.claim(d, 109)
	Spec.eq(day9, 2)
	local _, gap = DailyChest.claim(d, 111)
	Spec.eq(gap, 1, "skipped a day: back to day 1")
	Spec.eq(DailyChest.nextStreak(d, 112), 2)
	Spec.eq(DailyChest.nextStreak(d, 111), 1, "today: the streak it is")
end)

Spec.test("rewards: small, fixed, XP every day, cosmetics on days 3/5/7, owned cosmetic -> bonus XP", function()
	for day = 1, 7 do
		local r = DailyChest.reward(day, {})
		Spec.truthy(r.xp > 0 and r.xp <= 200, `day {day} xp {r.xp}`)
	end
	Spec.eq(DailyChest.reward(1, {}).cosmetic, nil)
	Spec.eq(DailyChest.reward(3, {}).cosmetic, "helmet_yellow")
	local owned = DailyChest.reward(3, { helmet_yellow = true })
	Spec.eq(owned.cosmetic, nil)
	Spec.eq(owned.xp, 50 + DailyChest.OwnedBonusXp)
	Spec.eq(DailyChest.reward(99, {}).day, 7, "clamped")
	Spec.eq(DailyChest.dayOf(86400 * 3 + 5), 3)
end)

return Spec.finish()
