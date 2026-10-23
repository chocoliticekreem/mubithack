--!strict
-- ProfileSchema [owner: Data]. PURE: the saved player profile, its migrations, the level curve, the
-- per-mission bookkeeping and the session-lock decisions. No Roblox APIs (no game, workspace, task,
-- Instance, Vector3, Color3, typeof, os.time) so `luau game/tests/data.spec.luau` can run it in CI.
-- DataService (the only writer) wraps it with DataStoreService. Contract: docs/game/06-data.md.
--
--   ProfileSchema.Version                                   -- current schema version (number)
--   ProfileSchema.default(now): Profile
--   ProfileSchema.migrate(raw: any, now): (Profile?, string?)  -- nil + reason if newer than Version
--   ProfileSchema.reconcile(p, now): Profile                -- fill missing keys, fix wrong types
--   ProfileSchema.levelForXp(xp): (level, intoLevel, needForNext)
--   ProfileSchema.addXp(p, amount): (gained, levelsGained)
--   ProfileSchema.weekId(unixSeconds): number               -- weeks since 1970-01-05 (Monday)
--   ProfileSchema.rollWeek(p, weekId)                       -- resets p.weekly when the week changed
--   ProfileSchema.blamePointsFor(stats, awards, weights): number
--   ProfileSchema.xpForMission(stats, results, won, rewards): (xp, { {reason, xp} })
--   ProfileSchema.applyMission(p, userId, missionId, results, opts): MissionSummary
--   ProfileSchema.addRescue(p, kind)
--   ProfileSchema.unlockCosmetics(p, catalog): { string }   -- newly owned ids
--   ProfileSchema.equip(p, slot, id): boolean
--   ProfileSchema.setSetting(p, key, value): boolean
--   ProfileSchema.tryLock(envelope, jobId, now, ttl): (Envelope?, string?)
--   ProfileSchema.release(envelope, jobId): (Envelope?, string?)
--   ProfileSchema.ownsLock(envelope, jobId, now): boolean

export type MissionStats = { played: number, won: number, bestStars: number, bestSeconds: number }
export type Weekly = { week: number, rescues: number, blamePoints: number, missions: number }
export type Profile = {
	version: number,
	xp: number, -- lifetime XP
	level: number, -- derived from xp, stored for leaderboards/readers
	missions: { [string]: MissionStats }, -- by MissionCatalog id
	missionsPlayed: number,
	missionsWon: number,
	rescued: { [string]: number }, -- by RescueKind: Civilian, Dog, Cat, Panda
	awards: { [string]: number }, -- award id -> times earned
	blamePoints: number,
	firesOut: number,
	cosmetics: {
		owned: { [string]: boolean }, -- cosmetic id -> true
		equipped: { helmet: string, hose: string },
	},
	settings: { [string]: any },
	weekly: Weekly,
	meta: { created: number, lastSeen: number, sessions: number },
}
export type Lock = { jobId: string, expires: number }
export type Envelope = { data: any, lock: Lock? }
export type CosmeticDef = { id: string, slot: string, level: number }
export type MissionSummary = {
	xp: number,
	breakdown: { { reason: string, xp: number } },
	won: boolean,
	stars: number,
	newBest: boolean,
	blamePoints: number,
	levelsGained: number,
}

local ProfileSchema = {}

ProfileSchema.Version = 2

-- Level curve: reaching level L+1 from L costs Base + Step * (L - 1) XP. Level 1 -> 2 = 100 XP.
ProfileSchema.Curve = { Base = 100, Step = 50, MaxLevel = 99 }

ProfileSchema.RescueKinds = { "Civilian", "Dog", "Cat", "Panda" }

ProfileSchema.DefaultCosmetics = { helmet = "helmet_red", hose = "hose_blue" }

-- Settings whitelist: default value + validation. Only these keys can be written by clients.
ProfileSchema.Settings = {
	cameraShake = { default = true, kind = "boolean" },
	sensitivity = { default = 1, kind = "number", min = 0.2, max = 3 },
	musicVolume = { default = 0.6, kind = "number", min = 0, max = 1 },
	sfxVolume = { default = 1, kind = "number", min = 0, max = 1 },
	showXpPopups = { default = true, kind = "boolean" },
	graphicsQuality = { default = 0, kind = "number", min = 0, max = 3 }, -- 0 Auto, 1 Low, 2 High, 3 Ultra (ShaderController)
	feedback = { default = 0, kind = "number", min = 0, max = 2 }, -- 0 Normal, 1 Minimal, 2 Off (ClientLib/WorldPopup)
	onboarded = { default = false, kind = "boolean" }, -- first-join tutorial finished (OnboardingService)
}

local SECONDS_PER_WEEK = 7 * 24 * 3600
local MONDAY_OFFSET = 4 * 24 * 3600 -- 1970-01-01 was a Thursday; 1970-01-05 is the first Monday

local function num(v: any, fallback: number): number
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return fallback
end

local function count(v: any): number
	return math.max(0, math.floor(num(v, 0)))
end

function ProfileSchema.weekId(unixSeconds: number): number
	return (math.floor(unixSeconds) - MONDAY_OFFSET) // SECONDS_PER_WEEK
end

function ProfileSchema.default(now: number): Profile
	local settings: { [string]: any } = {}
	for key, def in ProfileSchema.Settings do
		settings[key] = def.default
	end
	local rescued: { [string]: number } = {}
	for _, kind in ProfileSchema.RescueKinds do
		rescued[kind] = 0
	end
	return {
		version = ProfileSchema.Version,
		xp = 0,
		level = 1,
		missions = {},
		missionsPlayed = 0,
		missionsWon = 0,
		rescued = rescued,
		awards = {},
		blamePoints = 0,
		firesOut = 0,
		cosmetics = {
			owned = {
				[ProfileSchema.DefaultCosmetics.helmet] = true,
				[ProfileSchema.DefaultCosmetics.hose] = true,
			},
			equipped = { helmet = ProfileSchema.DefaultCosmetics.helmet, hose = ProfileSchema.DefaultCosmetics.hose },
		},
		settings = settings,
		weekly = { week = ProfileSchema.weekId(now), rescues = 0, blamePoints = 0, missions = 0 },
		meta = { created = math.floor(now), lastSeen = math.floor(now), sessions = 0 },
	}
end

------------------------------------------------------------------------------------------- level

function ProfileSchema.levelForXp(xp: number): (number, number, number)
	local c = ProfileSchema.Curve
	local level = 1
	local left = math.max(0, math.floor(num(xp, 0)))
	while level < c.MaxLevel do
		local need = c.Base + c.Step * (level - 1)
		if left < need then
			return level, left, need
		end
		left -= need
		level += 1
	end
	return c.MaxLevel, 0, 0
end

function ProfileSchema.addXp(p: Profile, amount: number): (number, number)
	local gained = math.max(0, math.floor(num(amount, 0)))
	if gained == 0 then
		return 0, 0
	end
	local before = p.level
	p.xp += gained
	p.level = (ProfileSchema.levelForXp(p.xp))
	return gained, p.level - before
end

-------------------------------------------------------------------------------------- migrations

-- MIGRATIONS[v] turns a version-v table into version v+1 (in place). Add one per schema bump and
-- never edit an old one: live saves at that version depend on it.
local MIGRATIONS: { [number]: (any, number) -> () } = {
	-- v1 (the first draft shape): petsRescued was one number, cosmetics were a flat list of owned ids
	-- with equippedHelmet/equippedHose, there were no settings or weekly counters.
	[1] = function(t: any, now: number)
		local rescued: { [string]: number } = {}
		for _, kind in ProfileSchema.RescueKinds do
			rescued[kind] = 0
		end
		if type(t.petsRescued) == "number" then
			rescued.Dog = count(t.petsRescued) -- the only pet v1 had
		end
		rescued.Civilian = count(t.civiliansRescued)
		t.rescued = rescued
		t.petsRescued = nil
		t.civiliansRescued = nil

		local owned: { [string]: boolean } = {}
		if type(t.cosmetics) == "table" then
			for _, id in t.cosmetics do
				if type(id) == "string" then
					owned[id] = true
				end
			end
		end
		t.cosmetics = {
			owned = owned,
			equipped = {
				helmet = if type(t.equippedHelmet) == "string" then t.equippedHelmet else ProfileSchema.DefaultCosmetics.helmet,
				hose = if type(t.equippedHose) == "string" then t.equippedHose else ProfileSchema.DefaultCosmetics.hose,
			},
		}
		t.equippedHelmet = nil
		t.equippedHose = nil
		t.weekly = { week = ProfileSchema.weekId(now), rescues = 0, blamePoints = 0, missions = 0 }
		t.version = 2
	end,
}

local function fillMap(t: any, key: string)
	if type(t[key]) ~= "table" then
		t[key] = {}
	end
end

function ProfileSchema.reconcile(p: any, now: number): Profile
	local d = ProfileSchema.default(now)
	p.version = ProfileSchema.Version
	p.xp = count(p.xp)
	p.level = (ProfileSchema.levelForXp(p.xp))
	p.missionsPlayed = count(p.missionsPlayed)
	p.missionsWon = count(p.missionsWon)
	p.blamePoints = count(p.blamePoints)
	p.firesOut = count(p.firesOut)

	fillMap(p, "missions")
	for id, m in p.missions do
		if type(id) ~= "string" or type(m) ~= "table" then
			p.missions[id] = nil
		else
			m.played = count(m.played)
			m.won = count(m.won)
			m.bestStars = count(m.bestStars)
			m.bestSeconds = count(m.bestSeconds)
		end
	end

	fillMap(p, "rescued")
	for _, kind in ProfileSchema.RescueKinds do
		p.rescued[kind] = count(p.rescued[kind])
	end

	fillMap(p, "awards")
	for id, n in p.awards do
		if type(id) ~= "string" then
			p.awards[id] = nil
		else
			p.awards[id] = count(n)
		end
	end

	fillMap(p, "cosmetics")
	fillMap(p.cosmetics, "owned")
	fillMap(p.cosmetics, "equipped")
	for slot, id in d.cosmetics.equipped :: any do
		p.cosmetics.owned[id] = true -- defaults are always owned
		local cur = p.cosmetics.equipped[slot]
		if type(cur) ~= "string" or not p.cosmetics.owned[cur] then
			p.cosmetics.equipped[slot] = id
		end
	end

	fillMap(p, "settings")
	for key, def in ProfileSchema.Settings do
		local v = p.settings[key]
		if type(v) ~= def.kind then
			p.settings[key] = def.default
		end
	end
	for key in p.settings do
		if ProfileSchema.Settings[key] == nil then
			p.settings[key] = nil
		end
	end

	if type(p.weekly) ~= "table" then
		p.weekly = d.weekly
	else
		p.weekly.week = math.floor(num(p.weekly.week, d.weekly.week))
		p.weekly.rescues = count(p.weekly.rescues)
		p.weekly.blamePoints = count(p.weekly.blamePoints)
		p.weekly.missions = count(p.weekly.missions)
	end

	if type(p.meta) ~= "table" then
		p.meta = d.meta
	else
		p.meta.created = math.floor(num(p.meta.created, d.meta.created))
		p.meta.lastSeen = math.floor(num(p.meta.lastSeen, d.meta.lastSeen))
		p.meta.sessions = count(p.meta.sessions)
	end
	return p :: Profile
end

-- raw = whatever the DataStore held (nil for a new player). Returns a current-version profile, or
-- nil + reason when the save comes from a NEWER schema (an old server must not overwrite it).
function ProfileSchema.migrate(raw: any, now: number): (Profile?, string?)
	if type(raw) ~= "table" then
		return ProfileSchema.default(now), nil
	end
	local v = math.floor(num(raw.version, 1))
	if v > ProfileSchema.Version then
		return nil, `newer schema v{v} (this server knows v{ProfileSchema.Version})`
	end
	if v < 1 then
		v = 1
	end
	while v < ProfileSchema.Version do
		local step = MIGRATIONS[v]
		if not step then
			return nil, `no migration from v{v}`
		end
		step(raw, now)
		v += 1
		raw.version = v
	end
	return ProfileSchema.reconcile(raw, now), nil
end

---------------------------------------------------------------------------------------- weekly

function ProfileSchema.rollWeek(p: Profile, weekId: number)
	if p.weekly.week ~= weekId then
		p.weekly = { week = weekId, rescues = 0, blamePoints = 0, missions = 0 }
	end
end

function ProfileSchema.addRescue(p: Profile, kind: string)
	if p.rescued[kind] == nil then
		return
	end
	p.rescued[kind] += 1
	p.weekly.rescues += 1
end

---------------------------------------------------------------------------------------- missions

-- weights: { firesStarted, downedOthers, teammateSprayed, blameAward } points each.
function ProfileSchema.blamePointsFor(stats: any, awards: { any }?, weights: { [string]: number }): number
	local pts = 0
	if type(stats) == "table" then
		pts += count(stats.firesStarted) * num(weights.firesStarted, 0)
		pts += count(stats.downedOthers) * num(weights.downedOthers, 0)
		pts += count(stats.teammateSprayed) * num(weights.teammateSprayed, 0)
	end
	if awards then
		for _, a in awards do
			if type(a) == "table" and a.blame == true then
				pts += num(weights.blameAward, 0)
			end
		end
	end
	return math.max(0, math.floor(pts))
end

-- rewards: { Played, Won, PerStar, PerRescue, PerPanda, PerFireOut, PerAward, MaxPerMission }
function ProfileSchema.xpForMission(stats: any, results: any, won: boolean, rewards: { [string]: number }, awardCount: number): (number, { { reason: string, xp: number } })
	local parts: { { reason: string, xp: number } } = {}
	local function add(reason: string, xp: number)
		xp = math.floor(xp)
		if xp > 0 then
			table.insert(parts, { reason = reason, xp = xp })
		end
	end
	add("Mission played", num(rewards.Played, 0))
	if won then
		add("Mission won", num(rewards.Won, 0))
	end
	add("Stars", count(results.stars) * num(rewards.PerStar, 0))
	if type(stats) == "table" then
		add("Rescues", count(stats.rescued) * num(rewards.PerRescue, 0))
		add("Panda!", count(stats.pandas) * num(rewards.PerPanda, 0))
		add("Fires out", count(stats.firesOut) * num(rewards.PerFireOut, 0))
	end
	add("Awards", awardCount * num(rewards.PerAward, 0))
	local total = 0
	for _, part in parts do
		total += part.xp
	end
	local cap = num(rewards.MaxPerMission, math.huge)
	if total > cap then
		total = math.floor(cap)
	end
	return total, parts
end

-- opts: { rewards, blameWeights, winStars, weekId }. Mutates p; returns what happened.
function ProfileSchema.applyMission(p: Profile, userId: number, missionId: string, results: any, opts: any): MissionSummary
	local stats: any = nil
	for _, s in (if type(results.stats) == "table" then results.stats else {}) :: { any } do
		if type(s) == "table" and s.userId == userId then
			stats = s
			break
		end
	end
	local mine: { any } = {}
	for _, a in (if type(results.awards) == "table" then results.awards else {}) :: { any } do
		if type(a) == "table" and a.userId == userId and type(a.id) == "string" then
			table.insert(mine, a)
		end
	end

	ProfileSchema.rollWeek(p, opts.weekId)
	local stars = count(results.stars)
	local won = stars >= num(opts.winStars, 2) and results.reason ~= "forced"

	local m = p.missions[missionId]
	if not m then
		m = { played = 0, won = 0, bestStars = 0, bestSeconds = 0 }
		p.missions[missionId] = m
	end
	m.played += 1
	p.missionsPlayed += 1
	p.weekly.missions += 1
	local newBest = stars > m.bestStars
	if newBest then
		m.bestStars = stars
	end
	if won then
		m.won += 1
		p.missionsWon += 1
		local secs = count(results.seconds)
		if secs > 0 and (m.bestSeconds == 0 or secs < m.bestSeconds) then
			m.bestSeconds = secs
		end
	end

	for _, a in mine do
		p.awards[a.id] = (p.awards[a.id] or 0) + 1
	end
	local blame = ProfileSchema.blamePointsFor(stats, mine, opts.blameWeights or {})
	p.blamePoints += blame
	p.weekly.blamePoints += blame
	if stats then
		p.firesOut += count(stats.firesOut)
	end

	local xp, breakdown = ProfileSchema.xpForMission(stats, results, won, opts.rewards or {}, #mine)
	local _, levels = ProfileSchema.addXp(p, xp)
	return {
		xp = xp,
		breakdown = breakdown,
		won = won,
		stars = stars,
		newBest = newBest,
		blamePoints = blame,
		levelsGained = levels,
	}
end

--------------------------------------------------------------------------------------- cosmetics

function ProfileSchema.unlockCosmetics(p: Profile, catalog: { CosmeticDef }): { string }
	local new: { string } = {}
	for _, c in catalog do
		if c.level <= p.level and not p.cosmetics.owned[c.id] then
			p.cosmetics.owned[c.id] = true
			table.insert(new, c.id)
		end
	end
	return new
end

function ProfileSchema.equip(p: Profile, slot: string, id: string): boolean
	if (slot ~= "helmet" and slot ~= "hose") or type(id) ~= "string" then
		return false
	end
	if not p.cosmetics.owned[id] then
		return false
	end
	(p.cosmetics.equipped :: any)[slot] = id
	return true
end

function ProfileSchema.setSetting(p: Profile, key: string, value: any): boolean
	local def = ProfileSchema.Settings[key]
	if not def or type(value) ~= def.kind then
		return false
	end
	if def.kind == "number" then
		if value ~= value then
			return false
		end
		value = math.clamp(value, def.min, def.max)
	end
	p.settings[key] = value
	return true
end

------------------------------------------------------------------------------------ session lock

-- The DataStore value is an Envelope { data = Profile, lock = { jobId, expires } }. A server may
-- use a profile only while it holds an unexpired lock; autosaves refresh it.
local function asEnvelope(old: any): Envelope
	if type(old) ~= "table" then
		return { data = nil, lock = nil }
	end
	if old.data == nil and old.lock == nil and old.version ~= nil then
		return { data = old, lock = nil } -- a bare profile saved without an envelope
	end
	return { data = old.data, lock = old.lock }
end

local function lockValid(lock: any, now: number): boolean
	return type(lock) == "table" and type(lock.jobId) == "string" and num(lock.expires, 0) > now
end

function ProfileSchema.ownsLock(envelope: any, jobId: string, now: number): boolean
	local env = asEnvelope(envelope)
	return lockValid(env.lock, now) and (env.lock :: Lock).jobId == jobId
end

-- Acquire or refresh. Refuses ("locked by <job>") only while ANOTHER server's lock is unexpired.
function ProfileSchema.tryLock(old: any, jobId: string, now: number, ttl: number): (Envelope?, string?)
	local env = asEnvelope(old)
	if lockValid(env.lock, now) and (env.lock :: Lock).jobId ~= jobId then
		return nil, `locked by {(env.lock :: Lock).jobId}`
	end
	env.lock = { jobId = jobId, expires = now + ttl }
	return env, nil
end

-- Drop our lock. Refuses if someone else holds a valid lock (we lost the session; don't clobber).
function ProfileSchema.release(old: any, jobId: string, now: number?): (Envelope?, string?)
	local env = asEnvelope(old)
	if env.lock and (env.lock :: Lock).jobId ~= jobId and lockValid(env.lock, now or 0) then
		return nil, `locked by {(env.lock :: Lock).jobId}`
	end
	env.lock = nil
	return env, nil
end

return ProfileSchema
