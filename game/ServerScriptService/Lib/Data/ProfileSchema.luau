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
--   ProfileSchema.unlockGear(p, ids): { string }            -- newly unlocked gear ids (v3)
--   ProfileSchema.setLoadout(p, ids): boolean               -- locker picks (GearService validates ids)
--   ProfileSchema.setEquipped(p, eq): boolean              -- the LOCKER loadout { hand, back, face } ("" = empty);
--                                                           GearService restores it on spawn / rejoin
--   ProfileSchema.setSetting(p, key, value): boolean
--   ProfileSchema.guideSeen(p, missionId): boolean          -- v4: first-time mission guide done
--   ProfileSchema.markGuideSeen(p, missionId): boolean      -- true = newly marked
--   ProfileSchema.hasReceipt(p, purchaseId): boolean         -- v5: donation receipt already applied
--   ProfileSchema.addDonation(p, purchaseId, robux): boolean -- v5: false = duplicate receipt (idempotent)
--   p.pass (v6): battle pass season data; BattlePassService owns it through Lib/BattlePass/PassRules
--   ProfileSchema.giftPass(p, key, byUserId, at): boolean   -- v7: owner-gifted in-game pass entitlement
--   ProfileSchema.revokePass(p, key): boolean                -- v7: false = wasn't gifted
--   ProfileSchema.hasGift(p, key): boolean / giftedPasses(p): { string }   -- v7 (MonetizationService)
--   p.updates (v8): { lastSeen, prompted } = UpdateLog versions (Config/UpdateLog, Services/UpdateLogService)
--   ProfileSchema.markUpdateSeen(p, version): boolean        -- v8: true = newly seen (the WHAT'S NEW panel)
--   ProfileSchema.markNotifyPrompted(p, version): boolean    -- v8: true = first opt-in prompt for this version
--   ProfileSchema.markLikeAsked(p): number                   -- updates.likeAsks += 1 (the "Having fun? 👍" card,
--                                                               Services/SocialAskService); returns the new count
--   ProfileSchema.xpForLevel(level): number                  -- lifetime XP at the start of `level`
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
	gear: { unlocked: { [string]: boolean }, loadout: { string }, equipped: Equipped }, -- v3: locker (Lib/Items/Progression); equipped: filled by reconcile
	guides: { seen: { [string]: boolean } }, -- v4: MissionCatalog ids whose first-time guide ran (MissionGuideService)
	donations: Donations, -- v5: Robux donated through developer products (MonetizationService)
	pass: PassData, -- v6: battle pass (BattlePassService, ReplicatedStorage/Lib/BattlePass/PassRules)
	gifts: Gifts, -- v7: owner-gifted in-game entitlements (AdminService :giftpass -> MonetizationService)
	updates: Updates, -- v8: WHAT'S NEW panel (UpdateLogService)
	daily: Daily, -- (inside v8, no bump) DAILY CHEST streak (Services/ResultsFlowService, Lib/Retention/DailyChest)
	weekly: Weekly,
	meta: { created: number, lastSeen: number, sessions: number },
}
-- the station LOCKER loadout (GearService): item ids, "" = empty. Restored on every spawn and rejoin.
export type Equipped = { hand: string, back: string, face: string }
-- receipts = the newest MaxReceipts PurchaseIds already applied (oldest first), so a re-sent receipt
-- is never counted twice even if the global purchase ledger write failed.
export type Donations = { robux: number, count: number, receipts: { string } }
-- free/premium = claimed tiers; equipped = slot -> reward id; legacy = old BattlePass_S1 store imported
export type PassData = { season: string, xp: number, free: { number }, premium: { number }, equipped: { [string]: string }, legacy: boolean }
-- passes[key] = who gifted it and when. An in-game entitlement only: it is not a Roblox game pass.
export type Gifts = { passes: { [string]: { by: number, at: number } } }
-- lastSeen = newest Config/UpdateLog version this player closed the panel for ("" = never);
-- prompted = the version we last showed the "get notified" opt-in prompt for ("" = never)
-- likeAsks = how many times the "Having fun? 👍" card was shown (capped by Lib/Social/AskRules MaxEver).
-- Added inside v8 without a bump (a missing count is 0), so older servers never refuse these saves.
export type Updates = { lastSeen: string, prompted: string, likeAsks: number }
-- DAILY CHEST: lastDay = UTC day number (unix // 86400) of the last chest, streak = its day 1..7, total = chests
-- ever. Added inside v8 without a bump (missing = never opened), so older servers never refuse these saves.
export type Daily = { lastDay: number, streak: number, total: number }
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

ProfileSchema.Version = 8
ProfileSchema.MaxReceipts = 50 -- donation PurchaseIds remembered per profile
ProfileSchema.MaxLoadout = 6 -- stored picks cap (Progression.LoadoutSize uses fewer)

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
	effects = { default = 0, kind = "number", min = 0, max = 2 }, -- 0 Auto, 1 Calm, 2 Full (ClientLib/Calm)
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
		gear = { unlocked = {}, loadout = {}, equipped = { hand = "", back = "", face = "" } },
		guides = { seen = {} },
		donations = { robux = 0, count = 0, receipts = {} },
		pass = { season = "", xp = 0, free = {}, premium = {}, equipped = {}, legacy = false },
		gifts = { passes = {} },
		updates = { lastSeen = "", prompted = "", likeAsks = 0 },
		daily = { lastDay = 0, streak = 0, total = 0 },
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

-- Lifetime XP at the very start of `level` (levelForXp(xpForLevel(L)) == L).
function ProfileSchema.xpForLevel(level: number): number
	local c = ProfileSchema.Curve
	local target = math.clamp(math.floor(num(level, 1)), 1, c.MaxLevel)
	local xp = 0
	for l = 1, target - 1 do
		xp += c.Base + c.Step * (l - 1)
	end
	return xp
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
	-- v2 -> v3: gear progression (unlocked gear ids + the locker loadout). Unlocks are re-derived from
	-- the level by GearService on load, so an empty map is the right start.
	[2] = function(t: any, _now: number)
		t.gear = { unlocked = {}, loadout = {} }
		t.version = 3
	end,
	-- v3 -> v4: first-time mission guides. A mission you've already played counts as seen, so
	-- veterans only get the one-line tip (MissionGuideService).
	[3] = function(t: any, _now: number)
		local seen: { [string]: boolean } = {}
		if type(t.missions) == "table" then
			for id, m in t.missions do
				if type(id) == "string" and type(m) == "table" and (tonumber(m.played) or 0) > 0 then
					seen[id] = true
				end
			end
		end
		t.guides = { seen = seen }
		t.version = 4
	end,
	-- v4 -> v5: Robux donations (developer products). Nobody had donated before v5.
	[4] = function(t: any, _now: number)
		t.donations = { robux = 0, count = 0, receipts = {} }
		t.version = 5
	end,
	-- v5 -> v6: the battle pass moves into the profile (it had its own BattlePass_S1 store, which
	-- BattlePassService imports once: legacy = false). season "" = "the current one" on first load.
	[5] = function(t: any, _now: number)
		t.pass = { season = "", xp = 0, free = {}, premium = {}, equipped = {}, legacy = false }
		t.version = 6
	end,
	-- v6 -> v7: owner-gifted pass entitlements (:giftpass). Nobody had a gift before v7.
	[6] = function(t: any, _now: number)
		t.gifts = { passes = {} }
		t.version = 7
	end,
	-- v7 -> v8: the WHAT'S NEW panel. Everyone starts having seen nothing, so the newest update shows once.
	[7] = function(t: any, _now: number)
		t.updates = { lastSeen = "", prompted = "" }
		t.version = 8
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

	fillMap(p, "gear")
	fillMap(p.gear, "unlocked")
	for id, v in p.gear.unlocked do
		if type(id) ~= "string" or v ~= true then
			p.gear.unlocked[id] = nil
		end
	end
	local loadout: { string } = {}
	if type(p.gear.loadout) == "table" then
		for _, id in p.gear.loadout do
			if type(id) == "string" and #loadout < ProfileSchema.MaxLoadout then
				table.insert(loadout, id)
			end
		end
	end
	p.gear.loadout = loadout
	local eq = if type(p.gear.equipped) == "table" then p.gear.equipped else {}
	local cleanEq = { hand = "", back = "", face = "" }
	for slot in cleanEq do
		local id = eq[slot]
		if type(id) == "string" and #id <= 40 then
			cleanEq[slot] = id
		end
	end
	p.gear.equipped = cleanEq :: any

	fillMap(p, "guides")
	fillMap(p.guides, "seen")
	for id, v in p.guides.seen do
		if type(id) ~= "string" or v ~= true then
			p.guides.seen[id] = nil
		end
	end

	fillMap(p, "donations")
	p.donations.robux = count(p.donations.robux)
	p.donations.count = count(p.donations.count)
	local receipts: { string } = {}
	if type(p.donations.receipts) == "table" then
		for _, id in p.donations.receipts do
			if type(id) == "string" then
				table.insert(receipts, id)
			end
		end
	end
	while #receipts > ProfileSchema.MaxReceipts do
		table.remove(receipts, 1)
	end
	p.donations.receipts = receipts

	fillMap(p, "pass")
	local pass = p.pass
	pass.season = if type(pass.season) == "string" then pass.season else ""
	pass.xp = count(pass.xp)
	for _, key in { "free", "premium" } do
		local tiers: { number } = {}
		if type(pass[key]) == "table" then
			for _, t in pass[key] do
				if type(t) == "number" and t == t and t % 1 == 0 and t >= 1 and not table.find(tiers, t) then
					table.insert(tiers, t)
				end
			end
		end
		pass[key] = tiers
	end
	local equipped: { [string]: string } = {}
	if type(pass.equipped) == "table" then
		for slot, id in pass.equipped do
			if type(slot) == "string" and type(id) == "string" then
				equipped[slot] = id
			end
		end
	end
	pass.equipped = equipped
	pass.legacy = pass.legacy == true

	fillMap(p, "gifts")
	local passes: { [string]: { by: number, at: number } } = {}
	if type(p.gifts.passes) == "table" then
		for key, g in p.gifts.passes do
			if type(key) == "string" and key ~= "" and type(g) == "table" then
				passes[key] = { by = math.floor(num(g.by, 0)), at = math.floor(num(g.at, 0)) }
			end
		end
	end
	p.gifts.passes = passes

	fillMap(p, "updates")
	for _, key in { "lastSeen", "prompted" } do
		local v = p.updates[key]
		p.updates[key] = if type(v) == "string" and #v <= 32 then v else ""
	end
	p.updates.likeAsks = math.min(count(p.updates.likeAsks), 1000)
	for key in p.updates do
		if key ~= "lastSeen" and key ~= "prompted" and key ~= "likeAsks" then
			p.updates[key] = nil
		end
	end

	fillMap(p, "daily")
	p.daily = {
		lastDay = count(p.daily.lastDay),
		streak = math.clamp(count(p.daily.streak), 0, 7),
		total = count(p.daily.total),
	}

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

------------------------------------------------------------------------------------------- gear

function ProfileSchema.unlockGear(p: Profile, ids: { string }): { string }
	local new: { string } = {}
	for _, id in ids do
		if type(id) == "string" and not p.gear.unlocked[id] then
			p.gear.unlocked[id] = true
			table.insert(new, id)
		end
	end
	return new
end

function ProfileSchema.setLoadout(p: Profile, ids: any): boolean
	if type(ids) ~= "table" then
		return false
	end
	local out: { string } = {}
	for _, id in ids do
		if type(id) == "string" and #out < ProfileSchema.MaxLoadout then
			table.insert(out, id)
		end
	end
	p.gear.loadout = out
	return true
end

-- The LOCKER loadout: { hand, back, face } item ids (nil / "" = empty). GearService validates the ids.
function ProfileSchema.setEquipped(p: Profile, eq: any): boolean
	if type(eq) ~= "table" then
		return false
	end
	local out = { hand = "", back = "", face = "" }
	for slot in out do
		local id = eq[slot]
		if type(id) == "string" and #id <= 40 then
			out[slot] = id
		end
	end
	p.gear.equipped = out :: any
	return true
end

------------------------------------------------------------------------------------------ guides

function ProfileSchema.guideSeen(p: Profile, missionId: string): boolean
	return type(p.guides) == "table" and type(p.guides.seen) == "table" and p.guides.seen[missionId] == true
end

function ProfileSchema.markGuideSeen(p: Profile, missionId: string): boolean
	if type(missionId) ~= "string" or missionId == "" then
		return false
	end
	if type(p.guides) ~= "table" then
		p.guides = { seen = {} }
	end
	if type(p.guides.seen) ~= "table" then
		p.guides.seen = {}
	end
	if p.guides.seen[missionId] == true then
		return false
	end
	p.guides.seen[missionId] = true
	return true
end

------------------------------------------------------------------------------------- donations

function ProfileSchema.hasReceipt(p: Profile, purchaseId: string): boolean
	local d = (p :: any).donations
	return type(d) == "table" and type(d.receipts) == "table" and table.find(d.receipts, purchaseId) ~= nil
end

-- Applies one donation receipt. Idempotent: the same PurchaseId never counts twice.
function ProfileSchema.addDonation(p: Profile, purchaseId: string, robux: number): boolean
	if type(purchaseId) ~= "string" or purchaseId == "" then
		return false
	end
	local amount = count(robux)
	if amount <= 0 then
		return false
	end
	if type((p :: any).donations) ~= "table" then
		(p :: any).donations = { robux = 0, count = 0, receipts = {} }
	end
	if ProfileSchema.hasReceipt(p, purchaseId) then
		return false
	end
	local d = p.donations
	d.robux += amount
	d.count += 1
	table.insert(d.receipts, purchaseId)
	while #d.receipts > ProfileSchema.MaxReceipts do
		table.remove(d.receipts, 1)
	end
	return true
end

----------------------------------------------------------------------------------------- gifts

local function giftsOf(p: Profile): { [string]: { by: number, at: number } }
	local g = (p :: any).gifts
	if type(g) ~= "table" then
		g = { passes = {} };
		(p :: any).gifts = g
	end
	if type(g.passes) ~= "table" then
		g.passes = {}
	end
	return g.passes
end

function ProfileSchema.hasGift(p: Profile, key: string): boolean
	local g = (p :: any).gifts
	return type(g) == "table" and type(g.passes) == "table" and g.passes[key] ~= nil
end

-- true = newly gifted; false = bad key or already gifted.
function ProfileSchema.giftPass(p: Profile, key: string, byUserId: number, at: number): boolean
	if type(key) ~= "string" or key == "" then
		return false
	end
	local passes = giftsOf(p)
	if passes[key] then
		return false
	end
	passes[key] = { by = math.floor(num(byUserId, 0)), at = math.floor(num(at, 0)) }
	return true
end

function ProfileSchema.revokePass(p: Profile, key: string): boolean
	local passes = giftsOf(p)
	if type(key) ~= "string" or passes[key] == nil then
		return false
	end
	passes[key] = nil
	return true
end

function ProfileSchema.giftedPasses(p: Profile): { string }
	local out: { string } = {}
	local g = (p :: any).gifts
	if type(g) == "table" and type(g.passes) == "table" then
		for key in g.passes do
			table.insert(out, key)
		end
	end
	table.sort(out)
	return out
end

--------------------------------------------------------------------------------------- updates

local function updatesOf(p: Profile): Updates
	local u = (p :: any).updates
	if type(u) ~= "table" then
		u = { lastSeen = "", prompted = "", likeAsks = 0 };
		(p :: any).updates = u
	end
	return u
end

local function validVersion(version: any): boolean
	return type(version) == "string" and version ~= "" and #version <= 32
end

function ProfileSchema.markUpdateSeen(p: Profile, version: string): boolean
	if not validVersion(version) then
		return false
	end
	local u = updatesOf(p)
	if u.lastSeen == version then
		return false
	end
	u.lastSeen = version
	return true
end

function ProfileSchema.markNotifyPrompted(p: Profile, version: string): boolean
	if not validVersion(version) then
		return false
	end
	local u = updatesOf(p)
	if u.prompted == version then
		return false
	end
	u.prompted = version
	return true
end

function ProfileSchema.markLikeAsked(p: Profile): number
	local u = updatesOf(p)
	u.likeAsks = math.min(count(u.likeAsks) + 1, 1000)
	return u.likeAsks
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
