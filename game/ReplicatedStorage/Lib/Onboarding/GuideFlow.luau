--!strict
-- GuideFlow [owner: Onboarding]. Pure logic for the first-time mission guides (no Roblox APIs:
-- spec-tested in game/tests/mission_guide.spec.luau). Data: Config/MissionGuides.
-- MissionGuideService picks the mode; MissionGuideController feeds `tick` what it sees in the world.
--
--   GuideFlow.modeFor(seen: { boolean }) -> "full" | "tip"
--       one flag per squad member (true = has seen this mission's guide). Anyone new -> "full".
--   GuideFlow.steps(guides, missionId) -> { Step }   -- Common refs resolved, overrides applied
--   GuideFlow.tip(guides, missionId) -> string?
--   GuideFlow.new(steps, now) -> State                 -- { index = 1, steps, stepStart, missingSince, finished }
--   GuideFlow.tick(state, facts, now) -> (Step?, string?)
--       facts: { found: boolean, done: boolean }  (about the CURRENT step's target / condition)
--       Returns the step to show (nil = guide over) and, when the step changed this tick, why the
--       last one ended: "done" | "timeout" | "missing".
--   GuideFlow.skip(state)                              -- the player skipped: finished
--   GuideFlow.validate(guides, catalog) -> { string } -- problems (empty = fine)
local GuideFlow = {}

export type Step = {
	id: string,
	head: string,
	sub: string,
	target: { [string]: any }?,
	done: { [string]: any },
	optional: boolean?,
	maxSeconds: number?,
}
export type State = {
	steps: { Step },
	index: number,
	stepStart: number,
	missingSince: number?,
	finished: boolean,
	grace: number,
}

GuideFlow.TargetKinds = table.freeze({ none = true, truck = true, tag = true, rescue = true, burning = true, named = true })
GuideFlow.DoneKinds = table.freeze({
	hand = true,
	attr = true,
	carrying = true,
	rescued = true,
	fireOut = true,
	slapped = true,
	pair = true,
	near = true,
	prompt = true,
	appeared = true,
	gone = true,
	hazard = true,
	seconds = true,
})

function GuideFlow.modeFor(seen: { boolean }): string
	for _, s in seen do
		if s ~= true then
			return "full"
		end
	end
	return "tip"
end

local function copy(t: { [string]: any }): { [string]: any }
	local out = {}
	for k, v in t do
		out[k] = v
	end
	return out
end

local function resolveStep(guides: any, raw: any): Step?
	local common = guides.Common or {}
	if type(raw) == "string" then
		local c = common[raw]
		return if type(c) == "table" then copy(c) :: any else nil
	end
	if type(raw) ~= "table" then
		return nil
	end
	local base: { [string]: any } = {}
	if type(raw.use) == "string" then
		local c = common[raw.use]
		if type(c) ~= "table" then
			return nil
		end
		base = copy(c)
	end
	for k, v in raw do
		if k ~= "use" then
			base[k] = v
		end
	end
	return base :: any
end

function GuideFlow.steps(guides: any, missionId: string): { Step }
	local m = guides.Missions and guides.Missions[missionId]
	local out: { Step } = {}
	if type(m) ~= "table" or type(m.steps) ~= "table" then
		return out
	end
	for _, raw in m.steps do
		local s = resolveStep(guides, raw)
		if s then
			table.insert(out, s)
		end
	end
	return out
end

function GuideFlow.tip(guides: any, missionId: string): string?
	local m = guides.Missions and guides.Missions[missionId]
	return if type(m) == "table" and type(m.tip) == "string" then m.tip else nil
end

function GuideFlow.new(steps: { Step }, now: number, grace: number?): State
	return {
		steps = steps,
		index = 1,
		stepStart = now,
		missingSince = nil,
		finished = #steps == 0,
		grace = grace or 4,
	}
end

function GuideFlow.current(state: State): Step?
	if state.finished then
		return nil
	end
	return state.steps[state.index]
end

local function advance(state: State, now: number)
	state.index += 1
	state.stepStart = now
	state.missingSince = nil
	if state.index > #state.steps then
		state.finished = true
	end
end

function GuideFlow.tick(state: State, facts: { found: boolean, done: boolean }, now: number): (Step?, string?)
	local step = GuideFlow.current(state)
	if not step then
		return nil, nil
	end
	local why: string? = nil
	if facts.done then
		why = "done"
	elseif step.maxSeconds and now - state.stepStart >= step.maxSeconds then
		why = if step.done.kind == "seconds" then "done" else "timeout"
	elseif step.optional and not facts.found then
		state.missingSince = state.missingSince or now
		if now - (state.missingSince :: number) >= state.grace then
			why = "missing"
		end
	else
		state.missingSince = nil
	end
	if why then
		advance(state, now)
		return GuideFlow.current(state), why
	end
	return step, nil
end

function GuideFlow.skip(state: State)
	state.finished = true
end

function GuideFlow.validate(guides: any, catalog: { any }): { string }
	local problems: { string } = {}
	local function bad(msg: string)
		table.insert(problems, msg)
	end
	for name, c in guides.Common or {} do
		if type(c) ~= "table" or c.id == nil then
			bad(`Common.{name}: needs an id`)
		end
	end
	for id, h in guides.Hints or {} do
		if type(h) ~= "table" or type(h.head) ~= "string" or type(h.sub) ~= "string" or #h.sub > 90 then
			bad(`Hints.{id}: needs head + a short sub`)
		end
	end
	for _, def in catalog do
		local m = guides.Missions and guides.Missions[def.id]
		if type(m) ~= "table" then
			bad(`{def.id}: no guide`)
			continue
		end
		if type(m.tip) ~= "string" or #m.tip == 0 or #m.tip > 110 then
			bad(`{def.id}: tip must be one short line`)
		end
		if type(m.steps) ~= "table" or #m.steps == 0 then
			bad(`{def.id}: no steps`)
			continue
		end
		for i, raw in m.steps do
			local s = resolveStep(guides, raw)
			local at = `{def.id} step {i}`
			if not s then
				bad(`{at}: unknown common step {tostring(if type(raw) == "table" then raw.use else raw)}`)
				continue
			end
			local step = s :: Step
			if type(step.id) ~= "string" then
				bad(`{at}: no id`)
			end
			if type(step.head) ~= "string" or #step.head == 0 or #step.head > 28 then
				bad(`{at}: head must be 1-28 chars`)
			end
			if type(step.sub) ~= "string" or #step.sub == 0 or #step.sub > 90 then
				bad(`{at}: sub must be 1-90 chars ({#tostring(step.sub)})`)
			end
			local t = step.target
			if t ~= nil and (type(t) ~= "table" or not GuideFlow.TargetKinds[t.kind]) then
				bad(`{at}: bad target kind {tostring(t and t.kind)}`)
			end
			if type(step.done) ~= "table" or not GuideFlow.DoneKinds[step.done.kind] then
				bad(`{at}: bad done kind {tostring(step.done and step.done.kind)}`)
			elseif step.done.kind == "seconds" and not step.maxSeconds then
				bad(`{at}: done "seconds" needs maxSeconds`)
			end
			if (step.done and (step.done.kind == "near" or step.done.kind == "appeared" or step.done.kind == "gone" or step.done.kind == "prompt"))
				and (t == nil or t.kind == "none")
			then
				bad(`{at}: done {step.done.kind} needs a target`)
			end
		end
	end
	return problems
end

return GuideFlow
