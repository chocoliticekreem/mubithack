--!strict
-- AchievementRules [owner: Achievements]. PURE: counting, progress and unlock decisions for the
-- achievements (Config/AchievementConfig). No Roblox APIs and no requires, so game/tests/achievements.spec
-- runs it with the `luau` CLI. AchievementService (server) owns the saved data, AchievementController
-- (client) uses progress() / visible() to draw the panel.
--
-- Data = profile.achievements (ProfileSchema, added inside v8 without a bump):
--   { stats = { [stat] = number }, unlocked = { [id] = unixSeconds }, sites = { [siteId] = true } }
--
--   Rules.empty() -> Data
--   Rules.value(data, stat) -> number                      -- "sites" = distinct places in data.sites
--   Rules.add(data, stat, n, kind) -> boolean              -- kind "sum" adds n (> 0), "max" keeps the best
--   Rules.addSite(data, siteId, maxSites) -> boolean       -- true = a place never worked before
--   Rules.seed(data, from, kinds) -> boolean               -- old profiles: raise stats to the profile's own
--                                                             lifetime counters (never lowers anything)
--   Rules.progress(def, data) -> (current, goal, done)     -- current is capped at goal
--   Rules.newlyUnlocked(defs, data) -> { Def }             -- reached the goal, not unlocked yet (config order)
--   Rules.unlock(data, id, now) -> boolean                 -- false = already unlocked (idempotent)
--   Rules.visible(def, maxPassTier?) -> boolean            -- off defs and pass tiers past the season hide
--   Rules.count(defs, data, maxPassTier?) -> (unlocked, total)   -- over visible defs (+ any unlocked one)
--   Rules.snapshot(defs, data) -> { unlocked, stats }      -- what the client gets (stats incl. sites)

local Rules = {}

export type Data = { stats: { [string]: number }, unlocked: { [string]: number }, sites: { [string]: boolean } }

local function num(v: any): number
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return 0
end

function Rules.empty(): Data
	return { stats = {}, unlocked = {}, sites = {} }
end

local function siteCount(data: Data): number
	local n = 0
	for _, v in data.sites do
		if v == true then
			n += 1
		end
	end
	return n
end

function Rules.value(data: Data, stat: string): number
	if stat == "sites" then
		return math.max(siteCount(data), num(data.stats.sites))
	end
	return math.max(0, math.floor(num(data.stats[stat])))
end

function Rules.add(data: Data, stat: string, n: number, kind: string?): boolean
	n = math.floor(num(n))
	if type(stat) ~= "string" or stat == "" then
		return false
	end
	local cur = math.max(0, math.floor(num(data.stats[stat])))
	if kind == "max" then
		if n > cur then
			data.stats[stat] = n
			return true
		end
		return false
	end
	if n <= 0 then
		return false
	end
	data.stats[stat] = cur + n
	return true
end

function Rules.addSite(data: Data, siteId: string, maxSites: number): boolean
	if type(siteId) ~= "string" or siteId == "" or #siteId > 64 or data.sites[siteId] then
		return false
	end
	if siteCount(data) >= maxSites then
		-- full: still counts toward "sites" through the stat, so the number never goes down
		Rules.add(data, "sites", siteCount(data) + 1, "max")
		return false
	end
	data.sites[siteId] = true
	return true
end

function Rules.seed(data: Data, from: { [string]: number }, kinds: { [string]: string }): boolean
	local changed = false
	for stat, v in from do
		if kinds[stat] ~= nil and Rules.add(data, stat, v, "max") then
			changed = true
		end
	end
	return changed
end

function Rules.progress(def: any, data: Data): (number, number, boolean)
	local goal = math.max(1, math.floor(num(def.goal)))
	local done = data.unlocked[def.id] ~= nil
	local cur = Rules.value(data, def.stat)
	if done then
		cur = goal
	end
	return math.min(cur, goal), goal, done
end

function Rules.newlyUnlocked(defs: { any }, data: Data): { any }
	local out = {}
	for _, def in defs do
		if def.off ~= true and data.unlocked[def.id] == nil and Rules.value(data, def.stat) >= math.max(1, num(def.goal)) then
			table.insert(out, def)
		end
	end
	return out
end

function Rules.unlock(data: Data, id: string, now: number): boolean
	if type(id) ~= "string" or data.unlocked[id] ~= nil then
		return false
	end
	data.unlocked[id] = math.floor(num(now))
	return true
end

function Rules.visible(def: any, maxPassTier: number?): boolean
	if def.off == true then
		return false
	end
	if def.stat == "passTier" and maxPassTier and num(def.goal) > maxPassTier then
		return false -- this season's pass doesn't go that high (yet)
	end
	return true
end

function Rules.count(defs: { any }, data: Data, maxPassTier: number?): (number, number)
	local got, total = 0, 0
	for _, def in defs do
		local done = data.unlocked[def.id] ~= nil
		if done or Rules.visible(def, maxPassTier) then
			total += 1
			if done then
				got += 1
			end
		end
	end
	return got, total
end

function Rules.snapshot(defs: { any }, data: Data): { unlocked: { [string]: number }, stats: { [string]: number } }
	local unlocked: { [string]: number } = {}
	for id, t in data.unlocked do
		unlocked[id] = t
	end
	local stats: { [string]: number } = {}
	for _, def in defs do
		stats[def.stat] = Rules.value(data, def.stat)
	end
	return { unlocked = unlocked, stats = stats }
end

return Rules
