--!strict
-- OnboardingFlow: the 3-step first-join tutorial and the dispatch hints.
local Spec = require("./Spec")
local Flow = require("../ReplicatedStorage/Lib/Onboarding/OnboardingFlow")

local function facts(gear: boolean, board: boolean, pad: boolean, launched: boolean?)
	return { gear = gear, board = board, pad = pad, launched = launched == true }
end

Spec.test("fresh player starts at the gear step", function()
	local s = Flow.new()
	Spec.eq(Flow.advance(s, facts(false, false, false)), "gear")
end)

Spec.test("steps advance in order: gear -> board -> pad -> wait", function()
	local s = Flow.new()
	Spec.eq(Flow.advance(s, facts(true, false, false)), "board")
	Spec.eq(Flow.advance(s, facts(true, true, false)), "pad")
	Spec.eq(Flow.advance(s, facts(true, true, true)), "wait")
end)

Spec.test("dropping gear later does not send you back to the rack", function()
	local s = Flow.new()
	Flow.advance(s, facts(true, false, false))
	Spec.eq(Flow.advance(s, facts(false, false, false)), "board")
end)

Spec.test("stepping on a pad first skips the earlier steps", function()
	local s = Flow.new()
	Spec.eq(Flow.advance(s, facts(false, false, true)), "wait")
end)

Spec.test("stepping off the pad brings the pad step back", function()
	local s = Flow.new()
	Flow.advance(s, facts(true, true, true))
	Spec.eq(Flow.advance(s, facts(true, true, false)), "pad")
end)

Spec.test("launching finishes the tutorial for good", function()
	local s = Flow.new()
	Spec.eq(Flow.advance(s, facts(false, false, true, true)), nil)
	Spec.eq(s.done, true)
	Spec.eq(Flow.advance(s, facts(false, false, false)), nil)
end)

local function m(state: string?, opts: { [string]: boolean }?)
	local o = opts or {}
	return {
		state = state,
		hasTruck = o.hasTruck ~= false,
		seated = o.seated == true,
		driving = o.driving == true,
		doorOpen = o.doorOpen == true,
		arrived = o.arrived == true,
	}
end

Spec.test("dispatched on foot: open the door, then hop in", function()
	Spec.eq(Flow.missionHint(m("Dispatched")), "door")
	Spec.eq(Flow.missionHint(m("Dispatched", { doorOpen = true })), "seat")
end)

Spec.test("driving shows the drive hint; riding shotgun shows nothing", function()
	Spec.eq(Flow.missionHint(m("Dispatched", { seated = true, driving = true })), "drive")
	Spec.eq(Flow.missionHint(m("Dispatched", { seated = true })), nil)
end)

Spec.test("no hints outside dispatch, after arrival, or without a truck", function()
	Spec.eq(Flow.missionHint(m("Active")), nil)
	Spec.eq(Flow.missionHint(m(nil)), nil)
	Spec.eq(Flow.missionHint(m("Dispatched", { arrived = true })), nil)
	Spec.eq(Flow.missionHint(m("Dispatched", { hasTruck = false })), nil)
end)

Spec.test("yawToward faces the target (LookVector = -Z rotated)", function()
	-- facing +X: yaw = -pi/2 (LookVector of CFrame.Angles(0, -pi/2, 0) is (1, 0, 0))
	Spec.near(Flow.yawToward(0, 0, 10, 0), -math.pi / 2, 1e-9, "+X")
	Spec.near(Flow.yawToward(0, 0, 0, -10), 0, 1e-9, "-Z")
	Spec.near(math.abs(Flow.yawToward(0, 0, 0, 10)), math.pi, 1e-9, "+Z")
	Spec.eq(Flow.yawToward(1, 1, 1, 1), 0)
end)

return Spec.finish()
