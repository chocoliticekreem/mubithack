--!strict
-- MomentRules [owner: Clippable]. Pure rules for big moments (Controllers/MomentController, Config/MomentConfig).
-- No Roblox APIs, so game/tests/moment.spec.luau runs it with the `luau` CLI.
--
--   MomentRules.new() -> State
--   MomentRules.admit(state, now, kind, ctx, cfg) -> { show: boolean, reason: string, calm: boolean }
--     ctx = { involved: boolean (you are the actor / victim), distance: number (studs from you),
--             popups: "Normal" | "Minimal" | "Off" (WorldPopup mode), calm: boolean (ClientLib/Calm),
--             busy: boolean (results / a modal is up), driveSpeed: number (0 unless seated in a vehicle),
--             noCooldown: boolean? (Studio test only) }
--     Reasons, in check order: "disabled", "kind" (unknown), "popups" (POP-UPS: OFF), "busy", "driving",
--     "far" (not involved and out of the kind's range, or Minimal and not involved), "cooldown", "ok".
--     A shown moment starts the per-player cooldown (cfg.CooldownSeconds).
--   MomentRules.beat(cfg, calm) -> { seconds, fov, shake, captionSize, slow: boolean, ooohVolume }
--   MomentRules.classifyHazard(hazardId, params) -> kind?   Hazard/Fx -> moment kind
--     "backdraft" with a direction = a real backdraft (HazardService); without = MissionService's flashover
--     set piece. "explosion" -> "kaboom", "ceiling_collapse" -> "collapse".
export type State = { last: number? }
export type Ctx = {
	involved: boolean,
	distance: number,
	popups: string,
	calm: boolean,
	busy: boolean,
	driveSpeed: number,
	noCooldown: boolean?,
}
export type Verdict = { show: boolean, reason: string, calm: boolean }

local MomentRules = {}

function MomentRules.new(): State
	return { last = nil }
end

local function no(reason: string, calm: boolean): Verdict
	return { show = false, reason = reason, calm = calm }
end

function MomentRules.admit(state: State, now: number, kind: string, ctx: Ctx, cfg: any): Verdict
	local calm = ctx.calm == true
	if cfg.Enabled == false then
		return no("disabled", calm)
	end
	local def = type(cfg.Kinds) == "table" and cfg.Kinds[kind] or nil
	if type(def) ~= "table" then
		return no("kind", calm)
	end
	if ctx.popups == "Off" then
		return no("popups", calm)
	end
	if ctx.busy then
		return no("busy", calm)
	end
	if (ctx.driveSpeed or 0) > (tonumber(cfg.DriveSpeed) or 22) then
		return no("driving", calm)
	end
	if not ctx.involved then
		if ctx.popups == "Minimal" or ctx.distance > (tonumber(def.range) or 40) then
			return no("far", calm)
		end
	end
	if not ctx.noCooldown and state.last ~= nil and now - state.last < (tonumber(cfg.CooldownSeconds) or 20) then
		return no("cooldown", calm)
	end
	state.last = now
	return { show = true, reason = "ok", calm = calm }
end

function MomentRules.beat(cfg: any, calm: boolean): { [string]: any }
	local fx = if calm then 0.35 else 1
	return {
		seconds = if calm then (tonumber(cfg.CalmBeatSeconds) or 0.6) else (tonumber(cfg.BeatSeconds) or 1),
		fov = (tonumber(cfg.FovPunch) or -12) * fx,
		shake = (tonumber(cfg.Shake) or 0.45), -- FirstPersonController:Shake applies Calm itself
		captionSize = if calm then (tonumber(cfg.CalmCaptionTextSize) or 60) else (tonumber(cfg.CaptionTextSize) or 96),
		slow = not calm,
		ooohVolume = if calm then (tonumber(cfg.CalmOoohVolume) or 0.35) else (tonumber(cfg.OoohVolume) or 0.7),
	}
end

function MomentRules.classifyHazard(hazardId: string, params: any): string?
	if hazardId == "backdraft" then
		local p = if type(params) == "table" then params else {}
		return if p.direction ~= nil then "backdraft" else "flashover"
	elseif hazardId == "explosion" then
		return "kaboom"
	elseif hazardId == "ceiling_collapse" then
		return "collapse"
	end
	return nil
end

return MomentRules
