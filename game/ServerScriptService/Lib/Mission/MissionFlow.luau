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
--
-- States follow Types.RoundState: Alarm -> Active -> Results; "Done" after results (instance destroyed).

export type State = "Alarm" | "Active" | "Results" | "Done"
export type Outcome = "success" | "time" | "wiped" | "forced"
export type Timing = { seconds: number, alarm: number, intro: number, results: number, grace: number }
export type Obs = {
	burning: number, -- burning parts in the instance
	rescued: number, -- rescues delivered
	trapped: number, -- rescues not delivered yet (Trapped/Carried/Downed)
	players: number, -- squad members still in the server
	alive: number, -- squad members not Downed
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
}
export type StarRule = { id: string, text: string?, seconds: number? }
export type Summary = {
	outcome: Outcome,
	burningAtEnd: number,
	rescued: number,
	trapped: number,
	elapsed: number, -- seconds the Active phase lasted
	downs: number, -- times any squad member was downed
	hadFires: boolean?, -- false when nothing was ever lit (stubs): allOut still counts
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
	}
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

-- End now (forced/abort). No-op unless Alarm or Active. Returns the events ({"ended"} or {}).
function MissionFlow.finish(run: Run, now: number, outcome: Outcome): { string }
	local out = {}
	if run.state == "Alarm" or run.state == "Active" then
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
	return math.clamp(stop - run.activeSince, 0, run.timing.seconds)
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
		return finished and s.rescued > 0 and s.trapped == 0
	elseif rule.id == "underTime" then
		return s.outcome == "success" and s.elapsed <= (rule.seconds or math.huge)
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

return MissionFlow
