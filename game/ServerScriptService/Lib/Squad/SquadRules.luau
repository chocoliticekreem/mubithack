--!strict
-- SquadRules [owner: G3]. PURE squad maths for SquadService / SquadController, unit-tested by
-- game/tests/squad.spec.luau with the `luau` CLI. No Roblox APIs (no game, Instance, Vector3, task).
--   SquadRules.pickHelmet(taken: { [number]: boolean }, max: number): number
--   SquadRules.tag(helmet: number): string                       -- "Firefighter 02"
--   SquadRules.badge(helmet: number): string                     -- "02"
--   SquadRules.isWiped(downed: { boolean }, minPlayers: number): boolean
--   SquadRules.canRevive(r: ReviveCheck): (boolean, string)
--   SquadRules.reviveOutcome(method: string, cfg): (health: number, blame: number)
--   SquadRules.causeDowns(cause: string, causes: { [string]: boolean }): boolean
--   SquadRules.remaining(downedAt: number, now: number, seconds: number): number
--   SquadRules.isEmote(name: string, emotes: { string }): boolean
--   SquadRules.orbit(i: number, n: number, t: number, radius: number, rps: number): (number, number)
--   SquadRules.groupKey(instanceId: string?, useLobby: boolean, roundState: string?): string?
local SquadRules = {}

-- Lowest free helmet number 1..max. When every number is taken (more than `max` players share a
-- group), wrap round so the result is still a valid 1..max badge.
function SquadRules.pickHelmet(taken: { [number]: boolean }, max: number): number
	local count = 0
	for i = 1, max do
		if not taken[i] then
			return i
		end
		count += 1
	end
	return (count % max) + 1
end

function SquadRules.badge(helmet: number): string
	return string.format("%02d", math.clamp(math.floor(helmet), 0, 99))
end

function SquadRules.tag(helmet: number): string
	return "Firefighter " .. SquadRules.badge(helmet)
end

-- A group is wiped when it has at least `minPlayers` members and every one of them is downed.
function SquadRules.isWiped(downed: { boolean }, minPlayers: number): boolean
	if #downed < math.max(1, minPlayers) then
		return false
	end
	for _, d in downed do
		if not d then
			return false
		end
	end
	return true
end

export type ReviveCheck = {
	self: boolean, -- reviver == victim
	victimDowned: boolean,
	reviverDowned: boolean,
	sameGroup: boolean,
	distance: number,
	maxDistance: number,
}

function SquadRules.canRevive(r: ReviveCheck): (boolean, string)
	if r.self then
		return false, "self"
	end
	if not r.victimDowned then
		return false, "not downed"
	end
	if r.reviverDowned then
		return false, "reviver downed"
	end
	if not r.sameGroup then
		return false, "other squad"
	end
	if r.distance > r.maxDistance then
		return false, "too far"
	end
	return true, "ok"
end

export type ReviveCfg = {
	ReviveHealth: number,
	SlapReviveHealth: number,
	SlapBlame: number,
}

-- (health the victim gets back, blame points for the reviver). Slap is instant but costs blame.
function SquadRules.reviveOutcome(method: string, cfg: ReviveCfg): (number, number)
	if method == "slap" then
		return cfg.SlapReviveHealth, cfg.SlapBlame
	end
	return cfg.ReviveHealth, 0
end

-- Unknown causes default to "downs" so a new hazard can't silently fail to knock people over.
function SquadRules.causeDowns(cause: string, causes: { [string]: boolean }): boolean
	local v = causes[cause]
	if v == nil then
		return true
	end
	return v
end

function SquadRules.remaining(downedAt: number, now: number, seconds: number): number
	return math.max(0, seconds - (now - downedAt))
end

function SquadRules.isEmote(name: any, emotes: { string }): boolean
	if type(name) ~= "string" then
		return false
	end
	for _, e in emotes do
		if e == name then
			return true
		end
	end
	return false
end

-- Position of item i of n on a circle at time t (seconds), `rps` revolutions per second.
-- Returns local (x, z) offsets; used for dizzy stars and spiral (orbiting) pupils.
function SquadRules.orbit(i: number, n: number, t: number, radius: number, rps: number): (number, number)
	local a = (i - 1) / math.max(1, n) * math.pi * 2 + t * rps * math.pi * 2
	return math.cos(a) * radius, math.sin(a) * radius
end

-- Which "crew" a player belongs to for wipe checks. v1.5: their mission instance. v1 (no lobby):
-- everyone during an Active round. nil = not on a mission (lobby), so no wipe applies.
function SquadRules.groupKey(instanceId: string?, useLobby: boolean, roundState: string?): string?
	if instanceId and instanceId ~= "" then
		return instanceId
	end
	if not useLobby and roundState == "Active" then
		return "round"
	end
	return nil
end

-- The player is "in the lobby" (emotes allowed) when they're not on a mission.
function SquadRules.inLobby(instanceId: string?, useLobby: boolean, roundState: string?): boolean
	return SquadRules.groupKey(instanceId, useLobby, roundState) == nil and (useLobby or roundState ~= "Alarm")
end

return SquadRules
