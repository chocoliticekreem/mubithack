--!strict
-- AlarmLogic [owner: Station]. Pure helpers for AlarmController (no Roblox APIs, so
-- game/tests/alarm.spec.luau runs them under the `luau` CLI).
--
-- An alarm "run" merges every trigger that arrives while it is going:
--   level 2 = FULL  (my squad was dispatched: loud siren, screen tint, my bays say GO)
--   level 1 = QUIET (someone else's squad: the lights spin, the siren is quieter, no screen tint)
-- A louder trigger upgrades a running alarm; a quieter one only extends it. Bays (1..4) union.
-- Stages of the dispatch sequence by elapsed seconds since the run started:
--   "tones" (attention tones, every lamp strobes) -> "wail" (siren + spinning beacons) -> "go"
--   (the dispatched bays' door lights turn green and the GO signs blink).

local AlarmLogic = {}

AlarmLogic.QUIET = 1
AlarmLogic.FULL = 2
AlarmLogic.TonesSeconds = 0.9
AlarmLogic.GoAfterSeconds = 1.6
AlarmLogic.QuietVolume = 0.25 -- fraction of the full siren volume heard by bystanders
AlarmLogic.BeaconRpm = 60

export type State = {
	level: number, -- 0 = idle
	startedAt: number,
	untilAt: number,
	bays: { [number]: boolean },
	title: string,
}

function AlarmLogic.new(): State
	return { level = 0, startedAt = 0, untilAt = 0, bays = {}, title = "" }
end

function AlarmLogic.active(s: State, now: number): boolean
	return s.level > 0 and now < s.untilAt
end

-- Valid bay numbers (integers 1..4), deduplicated, sorted.
function AlarmLogic.cleanBays(list: { any }?): { number }
	local seen: { [number]: boolean } = {}
	local out: { number } = {}
	for _, v in list or {} do
		local n = tonumber(v)
		if n and n == math.floor(n) and n >= 1 and n <= 4 and not seen[n] then
			seen[n] = true
			table.insert(out, n)
		end
	end
	table.sort(out)
	return out
end

-- Merge a trigger into the state. Returns true when this started a new run (was idle).
function AlarmLogic.trigger(s: State, now: number, level: number, seconds: number, bays: { any }?, title: string?): boolean
	local fresh = not AlarmLogic.active(s, now)
	if fresh then
		s.level = 0
		s.startedAt = now
		s.untilAt = now
		s.bays = {}
		s.title = ""
	end
	s.level = math.max(s.level, math.clamp(math.floor(level), 1, 2))
	s.untilAt = math.max(s.untilAt, now + math.max(0, seconds))
	for _, b in AlarmLogic.cleanBays(bays) do
		s.bays[b] = true
	end
	if title and title ~= "" then
		s.title = title
	end
	return fresh
end

-- Clears the state once it has run out. Returns true exactly when it just ended.
function AlarmLogic.expire(s: State, now: number): boolean
	if s.level > 0 and now >= s.untilAt then
		s.level = 0
		s.bays = {}
		s.title = ""
		return true
	end
	return false
end

function AlarmLogic.stage(s: State, now: number): string
	if not AlarmLogic.active(s, now) then
		return "idle"
	end
	local e = now - s.startedAt
	if e < AlarmLogic.TonesSeconds then
		return "tones"
	elseif e < AlarmLogic.GoAfterSeconds then
		return "wail"
	end
	return "go"
end

function AlarmLogic.volume(level: number, base: number): number
	if level >= AlarmLogic.FULL then
		return base
	elseif level >= AlarmLogic.QUIET then
		return base * AlarmLogic.QuietVolume
	end
	return 0
end

-- Beacon yaw (radians) at time t.
function AlarmLogic.beaconAngle(t: number): number
	return (t * AlarmLogic.BeaconRpm / 60) * 2 * math.pi % (2 * math.pi)
end

-- Attention tones: on/off strobe at 6 Hz.
function AlarmLogic.strobe(t: number): boolean
	return math.floor(t * 12) % 2 == 0
end

-- GO sign blink at 2 Hz (on 70% of the time).
function AlarmLogic.goBlink(t: number): boolean
	return (t * 2) % 1 < 0.7
end

-- Siren wail pitch (PlaybackSpeed) when the sound has no wail of its own: 0.9..1.15 over 2.4 s.
function AlarmLogic.wail(t: number): number
	return 1.025 + 0.125 * math.sin(t * 2 * math.pi / 2.4)
end

function AlarmLogic.sortedBays(s: State): { number }
	local out: { number } = {}
	for b in s.bays do
		table.insert(out, b)
	end
	table.sort(out)
	return out
end

return AlarmLogic
