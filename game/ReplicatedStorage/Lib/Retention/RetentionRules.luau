--!strict
-- RetentionRules [owner: Retention]. PURE (no Roblox APIs; game/tests/retention.spec.luau runs it in the luau
-- CLI). The come-back rules: what tomorrow's chest is, when a "your chest is ready" notification may go out,
-- whether the ROOKIE PACK may be offered, and how to bucket a player's return for analytics.
-- Days are UTC day numbers (DailyChest.dayOf: unix // 86400), like the daily chest.
--
--   RetentionRules.chestPreview(daily, today, owned?) -> Preview
--       the next chest this player can open: "today" (not opened yet today) or "tomorrow", its streak day,
--       XP and cosmetic, plus the streak they are on now (0 = none / broken)
--   RetentionRules.returnGap(lastJoinDay, today) -> number      -- days since the last join day (-1 = first join)
--   RetentionRules.gapBucket(days) -> "first" | "same_day" | "next_day" | "d2_6" | "d7plus"
--   RetentionRules.ageBucket(createdDay, today) -> "d0" | "d1" | "d2_6" | "d7plus"   -- days since install
--   RetentionRules.notifyDue(leftAt, minHours) -> unix seconds  -- not before minHours after leaving, and
--       not before the next UTC day (that's when the next chest exists)
--   RetentionRules.optInAnswer(canPromptAfterClose) -> "accepted" | "declined"
--       Roblox doesn't tell a game the answer; after the prompt closes, "can't prompt any more" is the proxy
--       for "opted in" (Roblox itself only ever delivers to opted-in users).
--   RetentionRules.shouldAsk(ctx) -> (boolean, string)          -- the in-game "remind me" card
--   RetentionRules.rookieOffer(ctx) -> (boolean, string)        -- the ROOKIE PACK results offer
--   RetentionRules.boostLeft(left, dt) -> number                 -- seconds of 2x XP left after dt of play
-- in Roblox: the sibling ModuleScript; in the luau CLI (specs): the file next to this one
local DailyChest = if typeof(script) == "Instance"
	then require((script :: any).Parent:WaitForChild("DailyChest")) :: any
	else (require :: any)("./DailyChest")

local RetentionRules = {}

export type Daily = { lastDay: number, streak: number, total: number }
export type Preview = { when: string, day: number, xp: number, cosmetic: string?, streak: number }

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then v else default
end

function RetentionRules.chestPreview(daily: any, today: number, owned: { [string]: boolean }?): Preview
	local d: Daily = if type(daily) == "table"
		then { lastDay = math.floor(num(daily.lastDay, 0)), streak = math.floor(num(daily.streak, 0)), total = math.floor(num(daily.total, 0)) }
		else DailyChest.blank()
	local opened = d.lastDay == today and d.streak >= 1
	local when = if opened then "tomorrow" else "today"
	local day = if opened then DailyChest.nextStreak(d, today + 1) else DailyChest.nextStreak(d, today)
	local streak = 0
	if d.streak >= 1 and (d.lastDay == today or d.lastDay == today - 1) then
		streak = d.streak -- still alive: opened today, or yesterday and today's is waiting
	end
	local r = DailyChest.reward(day, owned)
	return { when = when, day = r.day, xp = r.xp, cosmetic = r.cosmetic, streak = streak }
end

function RetentionRules.returnGap(lastJoinDay: any, today: number): number
	local last = math.floor(num(lastJoinDay, 0))
	if last <= 0 then
		return -1
	end
	return math.max(0, today - last)
end

function RetentionRules.gapBucket(days: number): string
	if days < 0 then
		return "first"
	elseif days == 0 then
		return "same_day"
	elseif days == 1 then
		return "next_day"
	elseif days <= 6 then
		return "d2_6"
	end
	return "d7plus"
end

function RetentionRules.ageBucket(createdDay: number, today: number): string
	local age = math.max(0, today - math.floor(num(createdDay, today)))
	if age == 0 then
		return "d0"
	elseif age == 1 then
		return "d1"
	elseif age <= 6 then
		return "d2_6"
	end
	return "d7plus"
end

function RetentionRules.notifyDue(leftAt: number, minHours: number): number
	local soonest = math.floor(leftAt + math.max(0, num(minHours, 20)) * 3600)
	local nextDay = (DailyChest.dayOf(leftAt) + 1) * 86400
	return math.max(soonest, nextDay)
end

function RetentionRules.optInAnswer(canPromptAfterClose: boolean): string
	return if canPromptAfterClose then "declined" else "accepted"
end

-- ctx: { enabled, canPrompt (CanPromptOptInAsync), firstCallDone, inLobby, asks (ever), maxAsks,
--        answer ("" | "accepted" | "declined" | "no"), askedThisSession }
function RetentionRules.shouldAsk(ctx: { [string]: any }): (boolean, string)
	if ctx.enabled ~= true then
		return false, "off"
	end
	if ctx.firstCallDone ~= true then
		return false, "first call not done"
	end
	if ctx.canPrompt ~= true then
		return false, "can't prompt" -- under 13, already opted in, not eligible, or Studio
	end
	if ctx.answer == "accepted" then
		return false, "already opted in"
	end
	if ctx.askedThisSession == true then
		return false, "asked this session"
	end
	if num(ctx.asks, 0) >= num(ctx.maxAsks, 2) then
		return false, "asked enough"
	end
	if ctx.inLobby ~= true then
		return false, "not in the lobby"
	end
	return true, "ok"
end

-- ctx: { productId, bought, shows, maxShows, missionsPlayed, afterCalls, firstCallDone, rookieCall }
function RetentionRules.rookieOffer(ctx: { [string]: any }): (boolean, string)
	if num(ctx.productId, 0) <= 0 then
		return false, "no product id"
	end
	if ctx.bought == true then
		return false, "bought"
	end
	if ctx.firstCallDone ~= true then
		return false, "onboarding"
	end
	if ctx.rookieCall == true then
		return false, "rookie call"
	end
	if num(ctx.shows, 0) >= num(ctx.maxShows, 1) then
		return false, "shown enough"
	end
	if num(ctx.missionsPlayed, 0) < num(ctx.afterCalls, 2) then
		return false, "too early"
	end
	return true, "ok"
end

function RetentionRules.boostLeft(left: number, dt: number): number
	return math.max(0, math.floor(num(left, 0) - math.max(0, num(dt, 0))))
end

return RetentionRules
