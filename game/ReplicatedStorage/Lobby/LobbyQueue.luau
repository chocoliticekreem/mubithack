--!strict
-- LobbyQueue [owner: G3]. PURE queue-pad + countdown logic for the station lobby (no Roblox APIs,
-- so game/tests/lobby.spec.luau runs it with the `luau` CLI). LobbyService owns one State and feeds
-- it who stands on which pad; LobbyController uses the text helpers for the Mission Board UI.
--
--   local q = LobbyQueue.new({ pads = 3, maxSize = 4, countdown = 15, fullCountdown = 5 })
--   LobbyQueue.join(q, 1, userId)               -- first on an empty pad leads; countdown starts
--   LobbyQueue.apply(q, { [userId] = padId }, { userIds in the lobby })  -- poll reconcile
--   for _, e in LobbyQueue.tick(q, dt) do ... end  -- "count" each whole second, "launch" at 0,
--                                                    -- "short" when below the mission's min players
-- Rules: countdown starts when a pad gets its first member, drops to `fullCountdown` once the squad
-- is full, keeps running when members join/leave, and resets when the pad empties. Launching frees
-- the pad at once, so other pads keep counting and launching in parallel.
-- LOCK: with opts.lockSeconds set, a pad whose countdown is at or under it is LOCKED: `apply` never
-- takes a member off it for standing elsewhere (LobbyService also walls + clamps them onto the pad),
-- only for leaving the lobby. Before that, stepping off leaves as usual. A "short" reset unlocks it.
-- HOLD: LobbyQueue.hold(q, userId) pins ONE member for the whole countdown (the auto-queued first call:
-- a newbie wandering off must never cancel it); only an explicit leave() (NOT YET) takes them off.

export type Options = {
	pads: number,
	maxSize: number,
	countdown: number,
	fullCountdown: number,
	defaultMission: string?,
	limits: ((missionId: string) -> (number, number))?, -- (minPlayers, maxPlayers) for a mission
	lockSeconds: number?, -- at/under this many seconds left the squad is locked onto its pad (nil = never)
}

export type Pad = {
	padId: number,
	squadId: string?,
	members: { number },
	leader: number?,
	missionId: string?,
	remaining: number?, -- nil = not counting
}

export type State = {
	opts: Options,
	pads: { Pad },
	nextSquad: number,
	prefs: { [number]: string }, -- userId -> mission picked on the board before joining a pad
	held: { [number]: boolean }, -- userIds pinned to their pad for the whole countdown (hold)
}

export type Event = {
	kind: string, -- "count" | "launch" | "short"
	padId: number,
	squadId: string?,
	seconds: number?,
	members: { number }?,
	missionId: string?,
}

local LobbyQueue = {}

function LobbyQueue.new(opts: Options): State
	local pads: { Pad } = {}
	for i = 1, opts.pads do
		pads[i] = { padId = i, squadId = nil, members = {}, leader = nil, missionId = opts.defaultMission, remaining = nil }
	end
	return { opts = opts, pads = pads, nextSquad = 0, prefs = {}, held = {} }
end

local function limits(state: State, missionId: string?): (number, number)
	local lo, hi = 1, state.opts.maxSize
	if missionId and state.opts.limits then
		local a, b = state.opts.limits(missionId)
		lo, hi = a or lo, b or hi
	end
	return lo, math.min(hi, state.opts.maxSize)
end

function LobbyQueue.capacity(state: State, padId: number): number
	local pad = state.pads[padId]
	local _, hi = limits(state, pad and pad.missionId)
	return hi
end

function LobbyQueue.minPlayers(state: State, padId: number): number
	local pad = state.pads[padId]
	local lo = limits(state, pad and pad.missionId)
	return lo
end

function LobbyQueue.isFull(state: State, padId: number): boolean
	local pad = state.pads[padId]
	return pad ~= nil and #pad.members >= LobbyQueue.capacity(state, padId)
end

function LobbyQueue.padOf(state: State, userId: number): number?
	for _, pad in state.pads do
		if table.find(pad.members, userId) then
			return pad.padId
		end
	end
	return nil
end

function LobbyQueue.padBySquad(state: State, squadId: string): Pad?
	for _, pad in state.pads do
		if pad.squadId == squadId then
			return pad
		end
	end
	return nil
end

local function shortenIfFull(state: State, pad: Pad)
	if pad.remaining and #pad.members >= LobbyQueue.capacity(state, pad.padId) then
		pad.remaining = math.min(pad.remaining, state.opts.fullCountdown)
	end
end

local function reset(pad: Pad)
	pad.squadId = nil
	pad.members = {}
	pad.leader = nil
	pad.remaining = nil
end

-- Is the pad's squad locked in (countdown at/under opts.lockSeconds, someone on it)?
function LobbyQueue.isLocked(state: State, padId: number): boolean
	local pad = state.pads[padId]
	local lock = state.opts.lockSeconds
	return pad ~= nil and lock ~= nil and pad.remaining ~= nil and #pad.members > 0 and pad.remaining <= lock
end

-- Pin a member to their pad for the whole countdown (until they leave() or it launches).
function LobbyQueue.hold(state: State, userId: number): boolean
	if not LobbyQueue.padOf(state, userId) then
		return false
	end
	state.held[userId] = true
	return true
end

-- Is this user kept on their pad right now (held, or the pad is locked)?
function LobbyQueue.isHeld(state: State, userId: number): boolean
	local padId = LobbyQueue.padOf(state, userId)
	return padId ~= nil and (state.held[userId] == true or LobbyQueue.isLocked(state, padId))
end

-- Is this user on a locked pad?
function LobbyQueue.isLockedIn(state: State, userId: number): boolean
	local padId = LobbyQueue.padOf(state, userId)
	return padId ~= nil and LobbyQueue.isLocked(state, padId)
end

-- Leave whatever pad `userId` is on. Returns that padId (nil if none).
function LobbyQueue.leave(state: State, userId: number): number?
	state.held[userId] = nil
	for _, pad in state.pads do
		local i = table.find(pad.members, userId)
		if i then
			table.remove(pad.members, i)
			if #pad.members == 0 then
				reset(pad)
			elseif pad.leader == userId then
				pad.leader = pad.members[1]
			end
			return pad.padId
		end
	end
	return nil
end

-- Join pad `padId`. Returns (ok, reason): "ok" | "nopad" | "full" | "already".
function LobbyQueue.join(state: State, padId: number, userId: number): (boolean, string)
	local pad = state.pads[padId]
	if not pad then
		return false, "nopad"
	end
	if table.find(pad.members, userId) then
		return false, "already"
	end
	if #pad.members == 0 then
		local pref = state.prefs[userId]
		if pref then
			pad.missionId = pref
		end
	end
	if #pad.members >= LobbyQueue.capacity(state, padId) then
		return false, "full"
	end
	LobbyQueue.leave(state, userId)
	if #pad.members == 0 then
		state.nextSquad += 1
		pad.squadId = `S{state.nextSquad}`
		pad.leader = userId
		pad.remaining = state.opts.countdown
	end
	table.insert(pad.members, userId)
	shortenIfFull(state, pad)
	return true, "ok"
end

-- Board pick. On a pad only the leader changes the pad's mission; off a pad it is remembered and
-- applied when the player starts a new squad. The caller validates that missionId is enabled.
function LobbyQueue.choose(state: State, userId: number, missionId: string): boolean
	state.prefs[userId] = missionId
	local padId = LobbyQueue.padOf(state, userId)
	if not padId then
		return true
	end
	local pad = state.pads[padId]
	if pad.leader ~= userId then
		return false
	end
	pad.missionId = missionId
	shortenIfFull(state, pad)
	return true
end

-- Set an EMPTY pad's mission (anyone may), or any pad's mission by its leader.
function LobbyQueue.setPadMission(state: State, padId: number, userId: number?, missionId: string): boolean
	local pad = state.pads[padId]
	if not pad then
		return false
	end
	if #pad.members > 0 and pad.leader ~= userId then
		return false
	end
	pad.missionId = missionId
	shortenIfFull(state, pad)
	return true
end

-- Leader's "go now": cut the countdown to at most `seconds`.
function LobbyQueue.hurry(state: State, padId: number, seconds: number): boolean
	local pad = state.pads[padId]
	if not pad or not pad.remaining then
		return false
	end
	pad.remaining = math.min(pad.remaining, seconds)
	return true
end

-- Reconcile with who is standing where. `onPad[userId] = padId` for everyone on a pad; `present`
-- lists every lobby userId (anyone in it but not in onPad leaves their pad). A user who can't join
-- a full pad simply stays out. Returns the set of padIds whose roster changed.
function LobbyQueue.apply(state: State, onPad: { [number]: number }, present: { number }): { [number]: boolean }
	local changed: { [number]: boolean } = {}
	local seen: { [number]: boolean } = {}
	for _, uid in present do
		seen[uid] = true
		local want = onPad[uid]
		local have = LobbyQueue.padOf(state, uid)
		if have and want ~= have and LobbyQueue.isHeld(state, uid) then
			continue -- locked in / held: standing elsewhere (pulled back) doesn't take you off
		end
		if want ~= have then
			if want then
				local ok = LobbyQueue.join(state, want, uid)
				if ok then
					changed[want] = true
					if have then
						changed[have] = true
					end
				end
			elseif have then
				LobbyQueue.leave(state, uid)
				changed[have] = true
			end
		end
	end
	-- Anyone queued who is no longer in the lobby at all (left the game, launched elsewhere).
	for _, pad in state.pads do
		for i = #pad.members, 1, -1 do
			local uid = pad.members[i]
			if not seen[uid] then
				LobbyQueue.leave(state, uid)
				changed[pad.padId] = true
			end
		end
	end
	return changed
end

-- Advance every counting pad by dt seconds.
function LobbyQueue.tick(state: State, dt: number): { Event }
	local events: { Event } = {}
	for _, pad in state.pads do
		local r = pad.remaining
		if r == nil then
			continue
		end
		local before = math.ceil(r)
		r -= dt
		if r <= 0 then
			if #pad.members < LobbyQueue.minPlayers(state, pad.padId) then
				pad.remaining = state.opts.countdown
				table.insert(events, { kind = "short", padId = pad.padId, squadId = pad.squadId, missionId = pad.missionId })
			else
				table.insert(events, {
					kind = "launch",
					padId = pad.padId,
					squadId = pad.squadId,
					members = table.clone(pad.members),
					missionId = pad.missionId,
					seconds = 0,
				})
				for _, uid in pad.members do
					state.held[uid] = nil
				end
				reset(pad)
			end
		else
			pad.remaining = r
			local after = math.ceil(r)
			if after ~= before then
				table.insert(events, { kind = "count", padId = pad.padId, squadId = pad.squadId, seconds = after })
			end
		end
	end
	return events
end

-- Whole seconds left on a pad (nil = not counting).
function LobbyQueue.secondsLeft(state: State, padId: number): number?
	local pad = state.pads[padId]
	return if pad and pad.remaining then math.ceil(pad.remaining) else nil
end

------------------------------------------------------------------ board text helpers

-- 1..5 "chili" rating from a Types.MissionDef: hazards, fire count, co-op requirement, length.
function LobbyQueue.difficulty(def: any): number
	local d = 1 + #(def.hazards or {})
	-- (every call is now big and escalating: these thresholds mark the biggest/longest ones)
	if def.fires and (def.fires.count or 0) >= 7 then
		d += 1
	end
	if def.players and (def.players.min or 1) >= 2 then
		d += 1
	end
	if (def.seconds or 0) >= 400 then
		d += 1
	end
	return math.clamp(d, 1, 5)
end

function LobbyQueue.playersText(def: any): string
	local p = def.players or { min = 1, max = 4 }
	if p.min == p.max then
		return `{p.min} players`
	end
	return `{p.min}-{p.max} players`
end

function LobbyQueue.readyText(count: number, capacity: number): string
	return `{count}/{capacity} READY`
end

function LobbyQueue.pips(n: number, total: number?): string
	local t = total or 5
	return string.rep("*", n) .. string.rep(".", math.max(0, t - n))
end

return LobbyQueue
