--!strict
-- MissionFlow [owner: G3]. PURE per-instance mission state machine + star scoring. No Roblox APIs, no
-- requires, so game/tests/mission.spec.luau runs it with the `luau` CLI. MissionService owns one Run per
-- instanceId, feeds it clock + observations, and performs the side effects for the events it returns.
--
--   local run = MissionFlow.new({ seconds = 180, alarm = 6, intro = 3, results = 15, grace = 10 }, now)
--   for _, ev in MissionFlow.tick(run, now, obs) do ... end
--     events, in order: "teleport" (intro starts), "count3", "count2", "count1", "active" (ROLL OUT),
--                       "ended" (run.outcome set), "done" (results over: tear down)
--   MissionFlow.finish(run, now, "forced")         -- end now from Alarm or Active
--   MissionFlow.stars(rules, summary) -> (stars, { earned rule ids })
--   MissionFlow.endReason(outcome) -> Types.EndReason
--   MissionFlow.assignRescues(markerKinds, rescues) -> { kind | false } per marker
-- v2 dispatch (docs/game/08 "Dispatch missions"):
--   local run = MissionFlow.newDispatch({ seconds = 180, travel = 60, fastArrival = 45, arrivalBonus = 20,
--                                         alarm = 0, intro = 0, results = 15, grace = 10 }, now)
--   MissionFlow.tick(run, now, obs)   -- obs.arrived = a squad member or their truck is in the ArrivalZone
--     events: "arrived" (Dispatched -> Active; run.fast + bonus seconds when quick), "ended", "done"
--   MissionFlow.siteSupports(missionTypes, missionId) -> boolean     -- "house_fire, school_alarm"
--   MissionFlow.pickSite(sites, missionId, tieStuds?, roll?) -> siteId?   -- nearest free site first
--   MissionFlow.travelAllowance(studs, { speed, min, max }) -> seconds
--   MissionFlow.sinceDispatch(run, now) -> seconds since the call came in
-- squad-size scaling:
--   MissionFlow.scaledFires(base, players, perPlayer, minimum?) -> fires on scene
--   MissionFlow.scaledRescues(rescues, players, perExtra) -> rescue list (+1 per perExtra extra players)
--   MissionFlow.spreadPick(cands, taken, avoid, avoidRadius, n) -> candidate indices, spread apart
--
-- States follow Types.RoundState: Alarm -> Active -> Results; "Done" after results (instance destroyed).
-- v2 dispatch runs: Dispatched -> Active (on arrival) -> Results -> Done; the timer starts at dispatch.

export type State = "Alarm" | "Dispatched" | "Active" | "Results" | "Done"
export type Outcome = "success" | "time" | "wiped" | "forced"
export type Timing = {
	seconds: number,
	alarm: number,
	intro: number,
	results: number,
	grace: number,
	travel: number?, -- v2: driving allowance added to the timer at dispatch
	fastArrival: number?, -- v2: arrive within this many seconds of dispatch for the bonus
	arrivalBonus: number?, -- v2: seconds added to the timer on a fast arrival
}
export type Obs = {
	burning: number, -- burning parts in the instance
	rescued: number, -- rescues delivered
	trapped: number, -- rescues not delivered yet (Trapped/Carried/Downed)
	players: number, -- squad members still in the server
	alive: number, -- squad members not Downed
	arrived: boolean?, -- v2: a squad member or their truck is inside the site's ArrivalZone
}
export type Run = {
	state: State,
	timing: Timing,
	startedAt: number,
	alarmEndsAt: number, -- Active starts here (ROLL OUT)
	introAt: number, -- teleport + 3-2-1 start here
	endsAt: number, -- round timer end; 0 until Active
	activeSince: number,
	endedAt: number,
	resultsEndsAt: number,
	outcome: Outcome?,
	countdown: number, -- next countdown number still to emit (3..1), 0 = done
	teleported: boolean,
	dispatch: boolean, -- v2 dispatch run (no alarm/intro; Dispatched until arrival)
	arrivedAt: number, -- 0 until arrival
	fast: boolean, -- arrived within timing.fastArrival
}
export type StarRule = { id: string, text: string?, seconds: number?, min: number? } -- min: buildingSaved integrity
export type Summary = {
	outcome: Outcome,
	burningAtEnd: number,
	rescued: number,
	trapped: number,
	lost: number?, -- toasted rescues
	elapsed: number, -- seconds the Active phase lasted
	downs: number, -- times any squad member was downed
	hadFires: boolean?, -- false when nothing was ever lit (stubs): allOut still counts
	integrity: number?, -- building integrity 0..100 at the end (StructureService); nil = never burned
}

local MissionFlow = {}

function MissionFlow.new(timing: Timing, now: number): Run
	local intro = math.clamp(timing.intro, 0, math.max(timing.alarm, 0))
	local alarmEndsAt = now + math.max(timing.alarm, 0)
	return {
		state = "Alarm",
		timing = timing,
		startedAt = now,
		alarmEndsAt = alarmEndsAt,
		introAt = alarmEndsAt - intro,
		endsAt = 0,
		activeSince = 0,
		endedAt = 0,
		resultsEndsAt = 0,
		outcome = nil,
		countdown = math.min(3, math.floor(intro)),
		teleported = false,
		dispatch = false,
		arrivedAt = 0,
		fast = false,
	}
end

-- v2: the squad is dispatched now; the timer (seconds + travel allowance) is already running.
function MissionFlow.newDispatch(timing: Timing, now: number): Run
	return {
		state = "Dispatched",
		timing = timing,
		startedAt = now,
		alarmEndsAt = now,
		introAt = now,
		endsAt = now + math.max(timing.seconds, 0) + math.max(timing.travel or 0, 0),
		activeSince = 0,
		endedAt = 0,
		resultsEndsAt = 0,
		outcome = nil,
		countdown = 0,
		teleported = true,
		dispatch = true,
		arrivedAt = 0,
		fast = false,
	}
end

-- Seconds since the call came in (dispatch), frozen once the run ended.
function MissionFlow.sinceDispatch(run: Run, now: number): number
	local stop = if run.endedAt > 0 then run.endedAt else now
	return math.max(0, stop - run.startedAt)
end

-- Every objective done: nothing burning and nobody left to deliver.
function MissionFlow.objectivesDone(obs: Obs): boolean
	return obs.burning == 0 and obs.trapped == 0
end

local function finishInto(run: Run, now: number, outcome: Outcome, out: { string })
	run.state = "Results"
	run.outcome = outcome
	run.endedAt = now
	run.resultsEndsAt = now + math.max(run.timing.results, 0)
	table.insert(out, "ended")
end

-- End now (forced/abort). No-op unless Alarm, Dispatched or Active. Returns the events ({"ended"} or {}).
function MissionFlow.finish(run: Run, now: number, outcome: Outcome): { string }
	local out = {}
	if run.state == "Alarm" or run.state == "Dispatched" or run.state == "Active" then
		finishInto(run, now, outcome, out)
	end
	return out
end

-- Seconds of Active play so far (or total, once ended).
function MissionFlow.elapsed(run: Run, now: number): number
	if run.activeSince == 0 then
		return 0
	end
	local stop = if run.endedAt > 0 then run.endedAt else now
	local cap = run.timing.seconds
	if run.dispatch then
		cap += math.max(run.timing.travel or 0, 0) + math.max(run.timing.arrivalBonus or 0, 0)
	end
	return math.clamp(stop - run.activeSince, 0, cap)
end

function MissionFlow.tick(run: Run, now: number, obs: Obs?): { string }
	local out: { string } = {}
	if run.state == "Alarm" then
		if not run.teleported and now >= run.introAt then
			run.teleported = true
			table.insert(out, "teleport")
		end
		-- countdown n fires at alarmEndsAt - n
		while run.countdown > 0 and now >= run.alarmEndsAt - run.countdown do
			table.insert(out, `count{run.countdown}`)
			run.countdown -= 1
		end
		if now >= run.alarmEndsAt then
			run.countdown = 0
			run.state = "Active"
			run.activeSince = now
			run.endsAt = now + run.timing.seconds
			table.insert(out, "active")
		end
		return out
	end
	if run.state == "Dispatched" then
		if obs and obs.players <= 0 then
			finishInto(run, now, "forced", out)
		elseif obs and obs.alive <= 0 then
			finishInto(run, now, "wiped", out)
		elseif now >= run.endsAt then
			finishInto(run, now, "time", out)
		elseif obs and obs.arrived then
			run.state = "Active"
			run.activeSince = now
			run.arrivedAt = now
			local fastIn = run.timing.fastArrival or 0
			if fastIn > 0 and now - run.startedAt <= fastIn then
				run.fast = true
				run.endsAt += math.max(run.timing.arrivalBonus or 0, 0)
			end
			table.insert(out, "arrived")
		end
		return out
	end
	if run.state == "Active" then
		if obs and obs.alive <= 0 then
			finishInto(run, now, if obs.players <= 0 then "forced" else "wiped", out)
		elseif now >= run.endsAt then
			finishInto(run, now, "time", out)
		elseif obs and now - run.activeSince >= run.timing.grace and MissionFlow.objectivesDone(obs) then
			finishInto(run, now, "success", out)
		end
		return out
	end
	if run.state == "Results" and now >= run.resultsEndsAt then
		run.state = "Done"
		table.insert(out, "done")
	end
	return out
end

function MissionFlow.endReason(outcome: Outcome?): "time" | "allOut" | "forced"
	if outcome == "success" then
		return "allOut"
	elseif outcome == "time" then
		return "time"
	end
	return "forced"
end

-- One star per satisfied rule. Unknown rule ids never earn a star.
--   finish     the squad finished the shift (success or timer), not wiped or aborted
--   allOut     nothing burning at the end
--   allRescued at least one rescue delivered and nobody left behind
--   underTime  finished successfully within rule.seconds
--   noDowns    nobody in the squad was downed
function MissionFlow.starEarned(rule: StarRule, s: Summary): boolean
	local finished = s.outcome == "success" or s.outcome == "time"
	if rule.id == "finish" then
		return finished
	elseif rule.id == "allOut" then
		return finished and s.burningAtEnd == 0
	elseif rule.id == "allRescued" then
		return finished and s.rescued > 0 and s.trapped == 0 and (s.lost or 0) == 0
	elseif rule.id == "underTime" then
		return s.outcome == "success" and s.elapsed <= (rule.seconds or math.huge)
	elseif rule.id == "buildingSaved" then
		return finished and (s.integrity == nil or s.integrity >= (rule.min or 50))
	elseif rule.id == "noDowns" then
		return finished and s.downs == 0
	end
	return false
end

function MissionFlow.stars(rules: { StarRule }, s: Summary): (number, { string })
	local earned: { string } = {}
	for _, rule in rules do
		if MissionFlow.starEarned(rule, s) then
			table.insert(earned, rule.id)
		end
	end
	return #earned, earned
end

-- Match the mission's rescue list onto the location's RescueSpawn markers. `markerKinds` is each
-- marker's Kind attr (any case, "" if none); the result gives the RescueKind to spawn at each marker,
-- or false to leave it empty. Markers whose Kind matches a wanted kind get it first; leftovers fill
-- the remaining markers in order.
function MissionFlow.assignRescues(markerKinds: { string }, rescues: { { kind: string, count: number } }): { string | false }
	local wanted: { string } = {}
	for _, r in rescues do
		for _ = 1, math.max(0, math.floor(r.count)) do
			table.insert(wanted, r.kind)
		end
	end
	local out: { string | false } = {}
	for i = 1, #markerKinds do
		out[i] = false
	end
	-- pass 1: exact kind matches
	for i, mk in markerKinds do
		local lower = string.lower(mk)
		for w, kind in wanted do
			if string.lower(kind) == lower then
				out[i] = kind
				table.remove(wanted, w)
				break
			end
		end
	end
	-- pass 2: anything left goes to empty markers in order
	for i = 1, #markerKinds do
		if out[i] == false and #wanted > 0 then
			out[i] = table.remove(wanted, 1) :: string
		end
	end
	return out
end

-- v2 dispatch: incident site selection ------------------------------------------------------------

local function trim(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

-- `missionTypes` is an IncidentSite's MissionTypes attr: comma-separated MissionCatalog ids.
function MissionFlow.siteSupports(missionTypes: string?, missionId: string): boolean
	if type(missionTypes) ~= "string" or missionTypes == "" then
		return false
	end
	local want = string.lower(missionId)
	for part in string.gmatch(missionTypes, "[^,]+") do
		if string.lower(trim(part)) == want then
			return true
		end
	end
	return false
end

export type SiteInfo = {
	id: string,
	types: string?, -- MissionTypes attr
	busy: boolean, -- Busy attr, or already claimed by a run
	dist: number, -- studs from the station
}

-- The nearest free site that can host `missionId`. Sites within `tieStuds` of the nearest one tie, and
-- `roll(n) -> 1..n` picks among them (random in the service, fixed in tests); without `roll` the nearest
-- wins (lowest id on an exact tie). nil when every matching site is busy, or none matches.
function MissionFlow.pickSite(sites: { SiteInfo }, missionId: string, tieStuds: number?, roll: ((n: number) -> number)?, minStuds: number?): string?
	local free: { SiteInfo } = {}
	for _, s in sites do
		if not s.busy and MissionFlow.siteSupports(s.types, missionId) then
			table.insert(free, s)
		end
	end
	if #free == 0 then
		return nil
	end
	-- prefer sites at least `minStuds` from the station (a real drive); all of them tie, picked by roll
	if minStuds and minStuds > 0 then
		local far: { SiteInfo } = {}
		for _, s in free do
			if s.dist >= minStuds then
				table.insert(far, s)
			end
		end
		if #far > 0 then
			table.sort(far, function(a, b)
				return a.id < b.id
			end)
			if roll and #far > 1 then
				return far[math.clamp(math.floor(roll(#far)), 1, #far)].id
			end
			return far[1].id
		end
	end
	table.sort(free, function(a, b)
		if a.dist ~= b.dist then
			return a.dist < b.dist
		end
		return a.id < b.id
	end)
	local band = free[1].dist + math.max(tieStuds or 0, 0)
	local tied = 0
	for _, s in free do
		if s.dist <= band then
			tied += 1
		end
	end
	if roll and tied > 1 then
		return free[math.clamp(math.floor(roll(tied)), 1, tied)].id
	end
	return free[1].id
end

-- squad-size scaling (GameConfig.FireScalePerPlayer / MinArrivalFires / RescuesPerExtraPlayers) -----

-- Fires a call should have burning once the squad is on scene: max(base, minimum) * (1 + perPlayer *
-- (players - 1)), rounded. Solo = the base; 4 players at 0.35 = x2.05.
function MissionFlow.scaledFires(base: number, players: number, perPlayer: number, minimum: number?): number
	local b = math.max(base, minimum or 0)
	local n = math.max(1, math.floor(players))
	return math.max(0, math.floor(b * (1 + math.max(perPlayer, 0) * (n - 1)) + 0.5))
end

-- The mission's rescue list for a squad of `players`: +1 extra rescuable per `perExtra` extra players
-- (added to the first entry's kind, "Civilian" usually). Solo (or perExtra <= 0) = the list unchanged.
function MissionFlow.scaledRescues(rescues: { { kind: string, count: number } }, players: number, perExtra: number): { { kind: string, count: number } }
	local out = {}
	for _, r in rescues do
		table.insert(out, table.clone(r))
	end
	local extra = if perExtra > 0 then math.floor(math.max(math.floor(players) - 1, 0) / perExtra) else 0
	if extra > 0 then
		if #out > 0 then
			out[1].count += extra
		else
			table.insert(out, { kind = "Civilian", count = extra })
		end
	end
	return out
end

export type P3 = { x: number, y: number, z: number }

local function d2(a: P3, b: P3): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Pick up to `n` candidates spread round a site: each pick is the candidate farthest from every fire
-- already burning (`taken`) and every earlier pick (3D, so other rooms and floors win), skipping any
-- within `avoidRadius` of an `avoid` point (rescue spawns: never light someone's feet). Ties keep the
-- caller's order (shuffle the candidates for variety). Returns candidate indices in pick order.
function MissionFlow.spreadPick(cands: { P3 }, taken: { P3 }, avoid: { P3 }, avoidRadius: number, n: number): { number }
	local r2 = avoidRadius * avoidRadius
	local best: { number } = {}
	local ok: { boolean } = {}
	for i, c in cands do
		local fine = true
		for _, a in avoid do
			if d2(c, a) < r2 then
				fine = false
				break
			end
		end
		ok[i] = fine
		local m = math.huge
		for _, t in taken do
			m = math.min(m, d2(c, t))
		end
		best[i] = m
	end
	local out: { number } = {}
	while #out < n do
		local pick, far = 0, -1
		for i in cands do
			if ok[i] and best[i] > far then
				pick, far = i, best[i]
			end
		end
		if pick == 0 then
			break
		end
		table.insert(out, pick)
		ok[pick] = false
		local p = cands[pick]
		for i, c in cands do
			if ok[i] then
				best[i] = math.min(best[i], d2(c, p))
			end
		end
	end
	return out
end

-- Extra timer seconds for the drive: studs / speed, clamped to [min, max].
function MissionFlow.travelAllowance(studs: number, cfg: { speed: number, min: number, max: number }): number
	local raw = if cfg.speed > 0 then math.ceil(math.max(studs, 0) / cfg.speed) else cfg.max
	return math.clamp(raw, cfg.min, cfg.max)
end

return MissionFlow
