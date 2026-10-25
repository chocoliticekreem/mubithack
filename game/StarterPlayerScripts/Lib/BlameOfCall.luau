--!strict
-- BlameOfCall [owner: Clippable]. Picks the one funniest thing of the call for the results screen's
-- "BLAME OF THE CALL" card (ClientLib/BlameCard). Pure, so game/tests/blame_of_call.spec.luau runs it.
--
--   BlameOfCall.pick(stats, awards) -> Pick?
--     stats  = ResultsPayload.stats: BlameService ledger rows. Besides the counters it may carry
--              `pairs` = { ["hose:<victimUserId>"] = n, "down:", "slap:", "zap:" } and the extras
--              backdraftsCaused, yeets (BlameService counts them).
--     awards = ResultsPayload.awards (fallback: the first blame award that isn't the scapegoat line,
--              else the first award at all).
--   Each candidate scores weight * count; highest wins (ties: lower userId, then kind name). Hose sprays count once a
--   second, so they need at least HoseMin and weigh least.
export type Pick = { userId: number, kind: string, title: string, story: string }

local BlameOfCall = {}

BlameOfCall.HoseMin = 3

-- kind -> weight, silly title, story(actor, victim, n)
local PAIR: { [string]: { weight: number, title: string, story: (string, string, number) -> string } } = {
	down = {
		weight = 6,
		title = "Friendly Fire Champion",
		story = function(a, v, n)
			return if n == 1 then `{a} knocked out {v}. Oops.` else `{a} knocked out {v} {n} times. Oops.`
		end,
	},
	zap = {
		weight = 6,
		title = "Human Battery",
		story = function(a, v, n)
			return if n == 1 then `{a} zapped {v}. Hair still standing.` else `{a} zapped {v} {n} times!`
		end,
	},
	slap = {
		weight = 3,
		title = "Slap Happy",
		story = function(a, v, n)
			return if n == 1 then `{a} slapped {v} right in the helmet.` else `{a} slapped {v} {n} times!`
		end,
	},
	hose = {
		weight = 1,
		title = "Human Sprinkler",
		story = function(a, v, n)
			return `{a} sprayed {v} {n} times. {v} is very clean now.`
		end,
	},
}

local SOLO: { [string]: { weight: number, title: string, story: (string, number) -> string } } = {
	backdraftsCaused = {
		weight = 8,
		title = "Opened The Wrong Door",
		story = function(a, n)
			return if n == 1 then `{a} opened a door. BACKDRAFT!` else `{a} opened {n} wrong doors. BACKDRAFT x{n}!`
		end,
	},
	yeets = {
		weight = 2,
		title = "Yeet Master",
		story = function(a, n)
			return if n == 1 then `{a} YEETED someone to safety.` else `{a} YEETED {n} people to safety!`
		end,
	},
}

local function num(v: any): number
	return if type(v) == "number" then v else 0
end

function BlameOfCall.pick(stats: { any }?, awards: { any }?): Pick?
	local names: { [number]: string } = {}
	for _, s in stats or {} do
		if type(s) == "table" and type(s.userId) == "number" then
			names[s.userId] = if type(s.name) == "string" then s.name else "Someone"
		end
	end
	local best: Pick? = nil
	local bestScore = 0
	local function offer(userId: number, kind: string, title: string, story: string, score: number)
		local b = best
		local better = score > bestScore
			or (b ~= nil and score == bestScore and (userId < b.userId or (userId == b.userId and kind < b.kind)))
		if better then
			best = { userId = userId, kind = kind, title = title, story = story }
			bestScore = score
		end
	end
	for _, s in stats or {} do
		if type(s) ~= "table" or type(s.userId) ~= "number" then
			continue
		end
		local me = names[s.userId]
		for key, def in SOLO do
			local n = num(s[key])
			if n >= 1 then
				offer(s.userId, key, def.title, def.story(me, n), def.weight * n)
			end
		end
		if type(s.pairs) == "table" then
			for key, n in s.pairs do
				if type(key) ~= "string" or type(n) ~= "number" then
					continue
				end
				local kind, id = string.match(key, "^(%a+):(-?%d+)$")
				local def = kind and PAIR[kind]
				if not def or n < 1 or (kind == "hose" and n < BlameOfCall.HoseMin) then
					continue
				end
				local victim = names[tonumber(id) :: number] or "a teammate"
				offer(s.userId, kind :: string, def.title, def.story(me, victim, n), def.weight * n)
			end
		end
	end
	if best then
		return best
	end
	-- nothing funny happened between people: the call's first roast award
	local fallback: any = nil
	for _, a in awards or {} do
		if type(a) == "table" and a.id ~= "scapegoat" and type(a.userId) == "number" then
			if a.blame == true then
				fallback = a
				break
			end
			fallback = fallback or a
		end
	end
	if fallback then
		return {
			userId = fallback.userId,
			kind = "award",
			title = tostring(fallback.title),
			story = `{names[fallback.userId] or "Someone"}: {tostring(fallback.blurb)}`,
		}
	end
	return nil
end

return BlameOfCall
