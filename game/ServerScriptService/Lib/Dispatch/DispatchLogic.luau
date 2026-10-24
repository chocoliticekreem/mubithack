--!strict
-- DispatchLogic [owner: Dispatch]. Pure rules for the free-roam DISPATCH radio (DispatchService), no Roblox
-- APIs (positions are anything with .X / .Z: a Vector3 in the game, a plain table in the spec),
-- spec-tested in game/tests/dispatch.spec.luau.
--   DispatchLogic.meters(studs, perStud) -> "450 m" / "1.2 km"
--   DispatchLogic.pickSite(sites, missionId, origin, opts, supports, roll?) -> Site?
--       a free site hosting the mission: random among those NearStuds..FarStuds away, else the nearest
--   DispatchLogic.offer(sites, missions, origin, opts, supports, roll?) -> Call?   one random call with a site
--   DispatchLogic.list(sites, missions, origin, opts, supports, roll?) -> { Call }
--       one call per mission type (shuffled), `busy` when no free site hosts it, open calls first
--   DispatchLogic.isFree(p) -> boolean          may take a call: no mission, not on a pad, not in the tutorial
--   DispatchLogic.delay(min, max, r01) -> seconds
local DispatchLogic = {}

export type Pos = any -- Vector3, or { X: number, Z: number }
export type Site = { siteId: string, types: string, pos: Pos, address: string }
export type Mission = { id: string, call: string?, title: string?, enabled: boolean? }
export type Opts = { near: number, far: number, exclude: { [string]: boolean }?, size: number? }
export type Call = { missionId: string, call: string, site: Site?, dist: number, busy: boolean }
export type Roll = (n: number) -> number -- 1..n

local function flat(a: Pos, b: Pos): number
	local dx, dz = a.X - b.X, a.Z - b.Z
	return math.sqrt(dx * dx + dz * dz)
end

function DispatchLogic.meters(studs: number, perStud: number): string
	local m = math.max(0, studs) * perStud
	if m >= 1000 then
		return string.format("%.1f km", m / 1000)
	end
	return `{math.max(10, math.floor(m / 10 + 0.5) * 10)} m`
end

function DispatchLogic.pickSite(
	sites: { Site },
	missionId: string,
	origin: Pos,
	opts: Opts,
	supports: (string?, string) -> boolean,
	roll: Roll?
): Site?
	local band: { Site } = {}
	local best: Site? = nil
	local bestD = math.huge
	for _, s in sites do
		if not supports(s.types, missionId) then
			continue
		end
		local d = flat(s.pos, origin)
		if d >= opts.near and d <= opts.far then
			table.insert(band, s)
		end
		if d < bestD or (d == bestD and best and s.siteId < best.siteId) then
			best, bestD = s, d
		end
	end
	if #band > 0 then
		table.sort(band, function(a, b)
			return a.siteId < b.siteId
		end)
		return band[if roll then math.clamp(roll(#band), 1, #band) else 1]
	end
	return best
end

local function callables(missions: { Mission }, opts: Opts): { Mission }
	local out: { Mission } = {}
	for _, m in missions do
		if m.enabled ~= false and not (opts.exclude and opts.exclude[m.id]) then
			table.insert(out, m)
		end
	end
	return out
end

local function callOf(m: Mission, site: Site?, origin: Pos): Call
	return {
		missionId = m.id,
		call = m.call or m.title or m.id,
		site = site,
		dist = if site then flat(site.pos, origin) else 0,
		busy = site == nil,
	}
end

function DispatchLogic.offer(
	sites: { Site },
	missions: { Mission },
	origin: Pos,
	opts: Opts,
	supports: (string?, string) -> boolean,
	roll: Roll?
): Call?
	local open: { Call } = {}
	for _, m in callables(missions, opts) do
		local s = DispatchLogic.pickSite(sites, m.id, origin, opts, supports, roll)
		if s then
			table.insert(open, callOf(m, s, origin))
		end
	end
	if #open == 0 then
		return nil
	end
	return open[if roll then math.clamp(roll(#open), 1, #open) else 1]
end

function DispatchLogic.list(
	sites: { Site },
	missions: { Mission },
	origin: Pos,
	opts: Opts,
	supports: (string?, string) -> boolean,
	roll: Roll?
): { Call }
	local pool = callables(missions, opts)
	-- shuffle (Fisher-Yates with the injected roll) so the list isn't always the same five
	if roll then
		for i = #pool, 2, -1 do
			local j = math.clamp(roll(i), 1, i)
			pool[i], pool[j] = pool[j], pool[i]
		end
	end
	local open, busy = {}, {}
	local used: { [string]: boolean } = {} -- two calls never point at the same building
	for _, m in pool do
		local left: { Site } = {}
		for _, s in sites do
			if not used[s.siteId] then
				table.insert(left, s)
			end
		end
		local s = DispatchLogic.pickSite(left, m.id, origin, opts, supports, roll)
		if s then
			used[s.siteId] = true
		end
		local c = callOf(m, s, origin)
		table.insert(if c.busy then busy else open, c)
	end
	local out: { Call } = {}
	local size = opts.size or 5
	for _, group in { open, busy } do
		for _, c in group do
			if #out < size then
				table.insert(out, c)
			end
		end
	end
	return out
end

export type PlayerState = { instanceId: string?, queued: boolean?, tutorial: boolean?, downed: boolean? }

function DispatchLogic.isFree(p: PlayerState): boolean
	return (p.instanceId == nil or p.instanceId == "") and p.queued ~= true and p.tutorial ~= true and p.downed ~= true
end

function DispatchLogic.delay(min: number, max: number, r01: number): number
	local lo, hi = math.min(min, max), math.max(min, max)
	return lo + (hi - lo) * math.clamp(r01, 0, 1)
end

return DispatchLogic
