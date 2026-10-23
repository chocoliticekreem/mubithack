--!strict
-- OnboardingFlow [owner: Onboarding]. Pure logic for the first-join tutorial and the contextual hints
-- (no Roblox APIs: spec-tested in game/tests/onboarding.spec.luau). OnboardingController feeds it
-- what it sees and renders whatever comes back.
--
--   OnboardingFlow.Steps                         -- ordered tutorial steps { id }
--   OnboardingFlow.new() -> State                -- { furthest = 0, done = false }
--   OnboardingFlow.advance(state, facts) -> string?   -- current step id, nil when the tutorial is over
--       facts: { gear: boolean, board: boolean, pad: boolean, launched: boolean }
--       A step counts once its fact is seen; skipping ahead (stepping on a pad first) skips the
--       earlier steps instead of nagging about them. Launching (countdown hit 0) finishes it.
--   OnboardingFlow.missionHint(facts) -> string?  -- contextual mission hint id (or nil = no hint)
--       facts: { state: string?, hasTruck: boolean, seated: boolean, driving: boolean,
--                doorOpen: boolean, arrived: boolean }
--       "door"  : dispatched, not in your truck, its door is shut  -> "open your truck door"
--       "seat"  : dispatched, not in your truck, door open         -> "hop in"
--       "drive" : dispatched and driving                           -> "follow the GPS, siren F"
--   OnboardingFlow.yawToward(fromX, fromZ, toX, toZ) -> number  -- Y rotation (radians) whose
--       LookVector (-Z forward) points from -> to on the ground plane.
local OnboardingFlow = {}

export type State = { furthest: number, done: boolean }
export type Facts = { gear: boolean, board: boolean, pad: boolean, launched: boolean }
export type MissionFacts = {
	state: string?,
	hasTruck: boolean,
	seated: boolean,
	driving: boolean,
	doorOpen: boolean,
	arrived: boolean,
}

OnboardingFlow.Steps = table.freeze({
	table.freeze({ id = "gear" }),
	table.freeze({ id = "board" }),
	table.freeze({ id = "pad" }),
})

function OnboardingFlow.new(): State
	return { furthest = 0, done = false }
end

function OnboardingFlow.indexOf(id: string?): number
	for i, s in OnboardingFlow.Steps do
		if s.id == id then
			return i
		end
	end
	return 0
end

function OnboardingFlow.advance(state: State, facts: Facts): string?
	if state.done then
		return nil
	end
	if facts.launched then
		state.done = true
		return nil
	end
	for i, s in OnboardingFlow.Steps do
		if (facts :: any)[s.id] == true and i > state.furthest then
			state.furthest = i
		end
	end
	local nextIndex = state.furthest + 1
	local step = OnboardingFlow.Steps[nextIndex]
	if step then
		return step.id
	end
	-- every step seen: you're on a pad waiting for the countdown (stepping off brings the pad step back)
	return if facts.pad then "wait" else "pad"
end

function OnboardingFlow.missionHint(f: MissionFacts): string?
	if f.state ~= "Dispatched" or f.arrived then
		return nil
	end
	if f.driving then
		return "drive"
	end
	if f.seated or not f.hasTruck then
		return nil
	end
	return if f.doorOpen then "seat" else "door"
end

function OnboardingFlow.yawToward(fromX: number, fromZ: number, toX: number, toZ: number): number
	local dx, dz = toX - fromX, toZ - fromZ
	if dx * dx + dz * dz < 1e-6 then
		return 0
	end
	return math.atan2(-dx, -dz)
end

return OnboardingFlow
