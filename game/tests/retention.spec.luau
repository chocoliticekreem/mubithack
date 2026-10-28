--!strict
-- RetentionRules: tomorrow's chest preview, return buckets, notification timing, the remind-me ask and the
-- ROOKIE PACK offer rules (docs/game/21-retention.md).
local Spec = require("./Spec")
local R = require("../ReplicatedStorage/Lib/Retention/RetentionRules")
local DailyChest = require("../ReplicatedStorage/Lib/Retention/DailyChest")

local TODAY = 20389

Spec.test("chest preview: opened today -> tomorrow's streak day and its reward", function()
	local p = R.chestPreview({ lastDay = TODAY, streak = 1, total = 1 }, TODAY)
	Spec.eq(p.when, "tomorrow")
	Spec.eq(p.day, 2)
	Spec.eq(p.xp, DailyChest.Days[2].xp)
	Spec.eq(p.streak, 1)
	local p2 = R.chestPreview({ lastDay = TODAY, streak = 2, total = 2 }, TODAY)
	Spec.eq(p2.day, 3)
	Spec.eq(p2.cosmetic, "helmet_yellow")
	local p7 = R.chestPreview({ lastDay = TODAY, streak = 7, total = 7 }, TODAY)
	Spec.eq(p7.day, 1) -- the week starts over
end)

Spec.test("chest preview: not opened today", function()
	local fresh = R.chestPreview(nil, TODAY)
	Spec.eq(fresh.when, "today")
	Spec.eq(fresh.day, 1)
	Spec.eq(fresh.streak, 0)
	local yesterday = R.chestPreview({ lastDay = TODAY - 1, streak = 3, total = 3 }, TODAY)
	Spec.eq(yesterday.when, "today")
	Spec.eq(yesterday.day, 4)
	Spec.eq(yesterday.streak, 3) -- still alive until they miss today
	local broken = R.chestPreview({ lastDay = TODAY - 3, streak = 5, total = 5 }, TODAY)
	Spec.eq(broken.day, 1)
	Spec.eq(broken.streak, 0)
end)

Spec.test("chest preview: an owned cosmetic becomes bonus XP", function()
	local p = R.chestPreview({ lastDay = TODAY, streak = 2, total = 2 }, TODAY, { helmet_yellow = true })
	Spec.eq(p.cosmetic, nil)
	Spec.eq(p.xp, DailyChest.Days[3].xp + DailyChest.OwnedBonusXp)
end)

Spec.test("return gap buckets", function()
	Spec.eq(R.returnGap(0, TODAY), -1)
	Spec.eq(R.returnGap(nil, TODAY), -1)
	Spec.eq(R.returnGap(TODAY, TODAY), 0)
	Spec.eq(R.returnGap(TODAY - 1, TODAY), 1)
	Spec.eq(R.gapBucket(-1), "first")
	Spec.eq(R.gapBucket(0), "same_day")
	Spec.eq(R.gapBucket(1), "next_day")
	Spec.eq(R.gapBucket(4), "d2_6")
	Spec.eq(R.gapBucket(30), "d7plus")
	Spec.eq(R.ageBucket(TODAY, TODAY), "d0")
	Spec.eq(R.ageBucket(TODAY - 1, TODAY), "d1")
	Spec.eq(R.ageBucket(TODAY - 9, TODAY), "d7plus")
end)

Spec.test("notification due: >= MinHours after leaving and never before the next UTC day", function()
	local lateNight = TODAY * 86400 + 23 * 3600 -- 23:00 UTC
	Spec.eq(R.notifyDue(lateNight, 20), lateNight + 20 * 3600)
	local morning = TODAY * 86400 + 1 * 3600 -- 01:00 UTC: +20 h is still today
	Spec.eq(R.notifyDue(morning, 2), (TODAY + 1) * 86400)
	Spec.truthy(R.notifyDue(morning, 20) >= (TODAY + 1) * 86400, "next day")
end)

Spec.test("opt-in answer proxy", function()
	Spec.eq(R.optInAnswer(false), "accepted")
	Spec.eq(R.optInAnswer(true), "declined")
end)

local function ask(o: any): (boolean, string)
	local ctx = { enabled = true, canPrompt = true, firstCallDone = true, inLobby = true, asks = 0, maxAsks = 2, answer = "", askedThisSession = false }
	for k, v in o do
		ctx[k] = v
	end
	return R.shouldAsk(ctx)
end

Spec.test("remind-me ask: only after the first call, only if Roblox can prompt, capped", function()
	Spec.eq((ask({})), true)
	Spec.eq((ask({ firstCallDone = false })), false)
	Spec.eq((ask({ canPrompt = false })), false) -- under 13 / Studio / already opted in
	Spec.eq((ask({ answer = "accepted" })), false)
	Spec.eq((ask({ askedThisSession = true })), false)
	Spec.eq((ask({ asks = 2 })), false)
	Spec.eq((ask({ inLobby = false })), false)
	Spec.eq((ask({ enabled = false })), false)
end)

local function rookie(o: any): (boolean, string)
	local ctx = { productId = 123, bought = false, shows = 0, maxShows = 1, missionsPlayed = 2, afterCalls = 2, firstCallDone = true, rookieCall = false }
	for k, v in o do
		ctx[k] = v
	end
	return R.rookieOffer(ctx)
end

Spec.test("rookie pack: once, from the 2nd call, never without a product id or during onboarding", function()
	Spec.eq((rookie({})), true)
	Spec.eq((rookie({ productId = 0 })), false) -- not created on the dashboard yet: a no-op
	Spec.eq((rookie({ bought = true })), false)
	Spec.eq((rookie({ shows = 1 })), false)
	Spec.eq((rookie({ missionsPlayed = 1 })), false)
	Spec.eq((rookie({ missionsPlayed = 5 })), true) -- missed on call 2 (caps): the next results can show it
	Spec.eq((rookie({ firstCallDone = false })), false)
	Spec.eq((rookie({ rookieCall = true })), false)
end)

Spec.test("boost counts down with play time, never below 0", function()
	Spec.eq(R.boostLeft(1800, 10), 1790)
	Spec.eq(R.boostLeft(5, 10), 0)
	Spec.eq(R.boostLeft(100, -4), 100)
end)

return Spec.finish()
