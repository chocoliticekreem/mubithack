--!strict
-- PassRules [owner: BattlePass]. PURE battle pass rules, shared by BattlePassService (authority) and
-- BattlePassController (what to draw). No Roblox APIs, so `luau game/tests/battlepass.spec.luau` runs it.
--
-- Pass data (lives in the player profile, ProfileSchema v6 `pass`):
--   { season: string, xp: number, free: { number }, premium: { number }, equipped: { [slot]: id }, legacy: boolean,
--     curve: number? }   -- curve = the XP curve version the xp was earned under (nil = 1: 20 x 100 XP)
-- Tiers = { { Free = id, Premium = id } } (index = tier); Rewards = { [id] = { Slot, Name, Pct?, ... } }.
-- `opts` = { perTier: number, maxTier: number, needs: { number }?, tiers: Tiers, rewards: Rewards, boostCap: number? }
--   needs[t] = XP from tier t-1 to tier t (a curve); without it every tier costs perTier.
--
--   PassRules.blank(season) -> Pass
--   PassRules.reconcile(pass, season) -> (Pass, reset: boolean)   -- fixes types; a new season starts over
--   PassRules.tierOf(xp, opts) -> number
--   PassRules.xpAt(tier, opts) -> number                      -- total XP needed to reach `tier`
--   PassRules.need(tier, opts) -> number                      -- XP from tier-1 to tier (0 past the max)
--   PassRules.remapXp(xp, from, to) -> number                 -- same tier + same fraction on another curve
--   PassRules.migrateCurve(pass, version, from, to) -> boolean   -- once per curve version; never loses a tier
--   PassRules.variant(code, palette) -> (id?, def?)           -- "helmet:mint:neon" -> "helmet_mint", def
--   PassRules.progress(xp, opts) -> (tier, into, need)        -- need = 0 at the max tier
--   PassRules.gain(amount, premium, premiumMult, boostPct) -> number   -- whole XP actually given (>= 1)
--   PassRules.addXp(pass, gained, opts) -> (added, tierBefore, tierAfter)
--   PassRules.canClaim(pass, tier, track, premium, opts) -> (ok, reason?)   -- "locked" | "claimed" | "premium" | "bad"
--   PassRules.claim(pass, tier, track, premium, opts) -> (ok, reason?, rewardId?)   -- idempotent
--   PassRules.claimAll(pass, premium, opts, freeOnly?) -> { { tier, track, id } }   -- every claim it made
--   PassRules.claimable(pass, premium, opts) -> number
--   PassRules.owned(pass, premium, opts) -> { [id]: true }
--   PassRules.owns(pass, id, premium, opts) -> boolean
--   PassRules.boostPct(pass, premium, opts) -> number
--   PassRules.equip(pass, id, premium, opts) -> (ok, reason?)   -- slot comes from the reward
--   PassRules.unequip(pass, slot) -> boolean
--   PassRules.sanitizeEquipped(pass, premium, opts) -> boolean   -- drops what you no longer own
--   PassRules.mergeLegacy(pass, legacy, opts, legacyOpts?) -> boolean   -- one-time import of the old store
--   PassRules.countdown(seconds) -> "12d 4h" | "3h 20m" | "4m 10s" | "ENDED"

export type Pass = {
	season: string,
	xp: number,
	free: { number },
	premium: { number },
	equipped: { [string]: string },
	legacy: boolean,
	curve: number?,
}
export type Opts = {
	perTier: number,
	maxTier: number,
	needs: { number }?,
	tiers: { { Free: string, Premium: string } },
	rewards: { [string]: { [string]: any } },
	boostCap: number?,
}
export type Claim = { tier: number, track: string, id: string }

local PassRules = {}

PassRules.Slots = { "helmet", "title", "hose", "truck", "nozzle", "emote" }
local EQUIPPABLE: { [string]: boolean } = {}
for _, s in PassRules.Slots do
	EQUIPPABLE[s] = true
end

local function num(v: any, fallback: number): number
	if type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge then
		return v
	end
	return fallback
end

-- cumulative XP per tier, cached per curve table (Config tables live for the whole session)
local cumCache: { [any]: { number } } = setmetatable({}, { __mode = "k" }) :: any

local function cumOf(needs: { number }): { number }
	local c = cumCache[needs]
	if c then
		return c
	end
	c = {}
	local total = 0
	for i, n in needs do
		total += math.max(1, math.floor(num(n, 1)))
		c[i] = total
	end
	cumCache[needs] = c
	return c
end

function PassRules.xpAt(tier: number, opts: Opts): number
	local t = math.clamp(math.floor(num(tier, 0)), 0, math.max(1, opts.maxTier))
	if t <= 0 then
		return 0
	end
	local needs = opts.needs
	if needs and #needs >= t then
		return cumOf(needs)[t]
	end
	return math.max(1, opts.perTier) * t
end

function PassRules.need(tier: number, opts: Opts): number
	local t = math.floor(num(tier, 0))
	if t < 1 or t > opts.maxTier then
		return 0
	end
	return PassRules.xpAt(t, opts) - PassRules.xpAt(t - 1, opts)
end

local function maxXp(opts: Opts): number
	return PassRules.xpAt(math.max(1, opts.maxTier), opts)
end

local function has(list: { number }, tier: number): boolean
	return table.find(list, tier) ~= nil
end

local function tierList(v: any, maxTier: number?): { number }
	local out: { number } = {}
	if type(v) ~= "table" then
		return out
	end
	for _, t in v do
		if type(t) == "number" and t == t and t % 1 == 0 and t >= 1 and (maxTier == nil or t <= maxTier) and not has(out, t) then
			table.insert(out, t)
		end
	end
	table.sort(out)
	return out
end

function PassRules.blank(season: string): Pass
	return { season = season, xp = 0, free = {}, premium = {}, equipped = {}, legacy = false }
end

function PassRules.reconcile(p: any, season: string): (Pass, boolean)
	if type(p) ~= "table" then
		return PassRules.blank(season), false
	end
	if type(p.season) ~= "string" or p.season == "" then
		p.season = season -- a fresh v6 profile: this season, nothing to reset
	elseif p.season ~= season then
		local legacy = p.legacy == true
		local fresh = PassRules.blank(season)
		fresh.legacy = legacy
		return fresh, true
	end
	p.xp = math.max(0, math.floor(num(p.xp, 0)))
	p.free = tierList(p.free)
	p.premium = tierList(p.premium)
	local eq: { [string]: string } = {}
	if type(p.equipped) == "table" then
		for slot, id in p.equipped do
			if type(slot) == "string" and EQUIPPABLE[slot] and type(id) == "string" then
				eq[slot] = id
			end
		end
	end
	p.equipped = eq
	p.legacy = p.legacy == true
	local cv = p.curve
	p.curve = if type(cv) == "number" and cv == cv and cv % 1 == 0 and cv >= 1 then cv else nil
	return p :: Pass, false
end

function PassRules.tierOf(xp: number, opts: Opts): number
	local x = math.max(0, num(xp, 0))
	local needs = opts.needs
	if needs and #needs >= opts.maxTier then
		-- binary search: the highest tier whose cumulative XP is <= x
		local c = cumOf(needs)
		local lo, hi = 0, opts.maxTier
		while lo < hi do
			local mid = (lo + hi + 1) // 2
			if c[mid] <= x then
				lo = mid
			else
				hi = mid - 1
			end
		end
		return lo
	end
	return math.clamp(math.floor(x / math.max(1, opts.perTier)), 0, opts.maxTier)
end

function PassRules.progress(xp: number, opts: Opts): (number, number, number)
	local tier = PassRules.tierOf(xp, opts)
	if tier >= opts.maxTier then
		return tier, 0, 0
	end
	return tier, math.floor(math.max(0, num(xp, 0)) - PassRules.xpAt(tier, opts)), PassRules.need(tier + 1, opts)
end

-- The same tier and the same fraction of the way to the next one, on another curve. A tier never drops
-- (unless the new curve has fewer tiers than the one you reached).
function PassRules.remapXp(xp: number, from: Opts, to: Opts): number
	local tier, into, need = PassRules.progress(xp, from)
	local t = math.min(tier, to.maxTier)
	local base = PassRules.xpAt(t, to)
	if need > 0 and t < to.maxTier then
		base += math.floor(math.clamp(into / need, 0, 0.999) * PassRules.need(t + 1, to))
	end
	return base
end

-- Moves a pass earned under an older XP curve onto `to` (once: pass.curve = version afterwards).
-- from = the curve pass.curve names (nil -> the caller passes curve 1). Returns true when it changed.
function PassRules.migrateCurve(p: Pass, version: number, from: Opts?, to: Opts): boolean
	if p.curve == version then
		return false
	end
	if from then
		p.xp = math.min(maxXp(to), PassRules.remapXp(p.xp, from, to))
	end
	p.curve = version
	return true
end

-- Cosmetic variants drawn from a colour palette (no new assets). code = "<slot>:<colour>[:<pattern>]":
--   helmet:<c>:plain|twotone|metal|neon|sparkle   hose:<c>   truck:<c>[:pulse]   nozzle:<c>[:sparkle]
-- palette[c] = { Name, Color, Trim }. id = "<slot>_<c>" (patterns aren't part of the id: one per colour).
local SUFFIX = { helmet = "Helmet", hose = "Hose", truck = "Underglow", nozzle = "Nozzle" }

function PassRules.variant(code: string, palette: { [string]: { [string]: any } }): (string?, { [string]: any }?)
	local slot, c, pat = string.match(code, "^(%a+):(%a+):?(%a*)$")
	local col = c and palette[c]
	if not slot or not col or not SUFFIX[slot] then
		return nil, nil
	end
	local def: { [string]: any } = { Slot = slot, Name = `{col.Name} {SUFFIX[slot]}`, Color = col.Color }
	if slot == "helmet" then
		if pat ~= "plain" and pat ~= "" then
			def.Trim = col.Trim
		end
		if pat == "metal" then
			def.Metal = true
		elseif pat == "neon" then
			def.Neon = true
		elseif pat == "sparkle" then
			def.Sparkle = true
		end
	elseif slot == "hose" then
		def.Stripe = col.Trim
	elseif slot == "truck" then
		if pat == "pulse" then
			def.Pulse = col.Trim
		end
	elseif slot == "nozzle" then
		if pat == "sparkle" then
			def.Sparkle = true
		end
	end
	return `{slot}_{c}`, def
end

function PassRules.gain(amount: number, premium: boolean, premiumMult: number, boostPct: number): number
	local a = num(amount, 0)
	if a <= 0 then
		return 0
	end
	local mult = 1 + math.max(0, num(boostPct, 0)) / 100
	if premium then
		mult *= math.max(1, num(premiumMult, 1))
	end
	return math.max(1, math.floor(a * mult + 0.5))
end

function PassRules.addXp(p: Pass, gained: number, opts: Opts): (number, number, number)
	local before = PassRules.tierOf(p.xp, opts)
	local g = math.max(0, math.floor(num(gained, 0)))
	local newXp = math.min(maxXp(opts), p.xp + g)
	local added = newXp - p.xp
	p.xp = newXp
	return added, before, PassRules.tierOf(p.xp, opts)
end

local function trackKey(track: any): string?
	if type(track) ~= "string" then
		return nil
	end
	local t = string.lower(track)
	if t == "free" or t == "premium" then
		return t
	end
	return nil
end

local function rewardId(tier: number, track: string, opts: Opts): string?
	local row = opts.tiers[tier]
	if type(row) ~= "table" then
		return nil
	end
	local id = if track == "free" then row.Free else row.Premium
	if type(id) == "string" and opts.rewards[id] ~= nil then
		return id
	end
	return nil
end

function PassRules.canClaim(p: Pass, tier: any, track: any, premium: boolean, opts: Opts): (boolean, string?)
	local key = trackKey(track)
	if key == nil or type(tier) ~= "number" or tier ~= tier or tier % 1 ~= 0 or tier < 1 or tier > opts.maxTier then
		return false, "bad"
	end
	if rewardId(tier, key, opts) == nil then
		return false, "bad"
	end
	local list = if key == "free" then p.free else p.premium
	if has(list, tier) then
		return false, "claimed"
	end
	if tier > PassRules.tierOf(p.xp, opts) then
		return false, "locked"
	end
	if key == "premium" and not premium then
		return false, "premium"
	end
	return true, nil
end

function PassRules.claim(p: Pass, tier: any, track: any, premium: boolean, opts: Opts): (boolean, string?, string?)
	local ok, why = PassRules.canClaim(p, tier, track, premium, opts)
	if not ok then
		return false, why, nil
	end
	local key = trackKey(track) :: string
	local list = if key == "free" then p.free else p.premium
	table.insert(list, tier :: number)
	table.sort(list)
	return true, nil, rewardId(tier :: number, key, opts)
end

function PassRules.claimAll(p: Pass, premium: boolean, opts: Opts, freeOnly: boolean?): { Claim }
	local made: { Claim } = {}
	local top = PassRules.tierOf(p.xp, opts)
	for t = 1, top do
		for _, track in { "free", "premium" } do
			if track == "premium" and freeOnly then
				continue
			end
			local ok, _, id = PassRules.claim(p, t, track, premium, opts)
			if ok and id then
				table.insert(made, { tier = t, track = track, id = id })
			end
		end
	end
	return made
end

function PassRules.claimable(p: Pass, premium: boolean, opts: Opts): number
	local n = 0
	local top = PassRules.tierOf(p.xp, opts)
	for t = 1, top do
		if PassRules.canClaim(p, t, "free", premium, opts) then
			n += 1
		end
		if PassRules.canClaim(p, t, "premium", premium, opts) then
			n += 1
		end
	end
	return n
end

function PassRules.owned(p: Pass, premium: boolean, opts: Opts): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, t in p.free do
		local id = rewardId(t, "free", opts)
		if id then
			out[id] = true
		end
	end
	if premium then
		for _, t in p.premium do
			local id = rewardId(t, "premium", opts)
			if id then
				out[id] = true
			end
		end
	end
	return out
end

function PassRules.owns(p: Pass, id: string, premium: boolean, opts: Opts): boolean
	return PassRules.owned(p, premium, opts)[id] == true
end

function PassRules.boostPct(p: Pass, premium: boolean, opts: Opts): number
	local total = 0
	for id in PassRules.owned(p, premium, opts) do
		local r = opts.rewards[id]
		if r and r.Slot == "boost" then
			total += math.max(0, num(r.Pct, 0))
		end
	end
	return math.min(total, num(opts.boostCap, math.huge))
end

function PassRules.equip(p: Pass, id: any, premium: boolean, opts: Opts): (boolean, string?)
	if type(id) ~= "string" then
		return false, "bad"
	end
	local r = opts.rewards[id]
	if not r or not EQUIPPABLE[r.Slot] then
		return false, "bad"
	end
	if not PassRules.owns(p, id, premium, opts) then
		return false, "notOwned"
	end
	p.equipped[r.Slot] = id
	return true, nil
end

function PassRules.unequip(p: Pass, slot: any): boolean
	if type(slot) ~= "string" or not EQUIPPABLE[slot] or p.equipped[slot] == nil then
		return false
	end
	p.equipped[slot] = nil
	return true
end

function PassRules.sanitizeEquipped(p: Pass, premium: boolean, opts: Opts): boolean
	local owned = PassRules.owned(p, premium, opts)
	local changed = false
	for slot, id in p.equipped do
		local r = opts.rewards[id]
		if not owned[id] or not r or r.Slot ~= slot then
			p.equipped[slot] = nil
			changed = true
		end
	end
	return changed
end

-- legacy = the old BattlePass_S1 store value { xp, free = { tier }, premium = { tier } }.
-- legacyOpts = the curve that store's xp was earned under (curve 1); omitted = the same as opts.
function PassRules.mergeLegacy(p: Pass, legacy: any, opts: Opts, legacyOpts: Opts?): boolean
	if p.legacy then
		return false
	end
	p.legacy = true
	if type(legacy) ~= "table" then
		return true
	end
	local lx = math.max(0, math.floor(num(legacy.xp, 0)))
	if legacyOpts then
		lx = PassRules.remapXp(lx, legacyOpts, opts)
	end
	p.xp = math.min(maxXp(opts), math.max(p.xp, lx))
	for _, t in tierList(legacy.free, opts.maxTier) do
		if not has(p.free, t) then
			table.insert(p.free, t)
		end
	end
	for _, t in tierList(legacy.premium, opts.maxTier) do
		if not has(p.premium, t) then
			table.insert(p.premium, t)
		end
	end
	table.sort(p.free)
	table.sort(p.premium)
	return true
end

function PassRules.countdown(seconds: number): string
	local s = math.floor(num(seconds, 0))
	if s <= 0 then
		return "ENDED"
	end
	local d, h, m = s // 86400, (s % 86400) // 3600, (s % 3600) // 60
	if d > 0 then
		return `{d}d {h}h`
	elseif h > 0 then
		return `{h}h {m}m`
	end
	return `{m}m {s % 60}s`
end

return PassRules
