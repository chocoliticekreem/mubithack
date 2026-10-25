--!strict
-- TwistRules [owner: Twists]. Pure rules for the per-call twist (Services/TwistService) and the squad speed
-- run, spec-tested in game/tests/twist.spec.luau.
--   TwistRules.order(weights) -> { string }                 -- ids with weight > 0, sorted (stable odds)
--   TwistRules.pick(weights, r01, avoid?) -> string?        -- weighted pick; `avoid` (last twist) is skipped
--                                                             when anything else can roll
--   TwistRules.builtIn(hazards, builtIn) -> string?         -- the mission's own twist (catalog hazards)
--   TwistRules.record(best, seconds, won) -> (best, isNew)  -- server best per site: only all-clear calls
--                                                             count, lower is better
--   TwistRules.clock(seconds) -> "2:05"
local TwistRules = {}

function TwistRules.order(weights: { [string]: number }): { string }
	local ids = {}
	for id, w in weights do
		if type(w) == "number" and w > 0 then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

function TwistRules.pick(weights: { [string]: number }, r01: number, avoid: string?): string?
	local ids = TwistRules.order(weights)
	if avoid and #ids > 1 then
		local i = table.find(ids, avoid)
		if i then
			table.remove(ids, i)
		end
	end
	local total = 0
	for _, id in ids do
		total += weights[id]
	end
	if total <= 0 then
		return nil
	end
	local r = math.clamp(r01, 0, 0.999999) * total
	for _, id in ids do
		r -= weights[id]
		if r < 0 then
			return id
		end
	end
	return ids[#ids]
end

function TwistRules.builtIn(hazards: { string }?, builtIn: { string }): string?
	for _, h in hazards or {} do
		if table.find(builtIn, h) then
			return h
		end
	end
	return nil
end

function TwistRules.record(best: number?, seconds: number, won: boolean): (number?, boolean)
	if not won or seconds <= 0 then
		return best, false
	end
	if best == nil or seconds < best then
		return seconds, true
	end
	return best, false
end

function TwistRules.clock(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

return TwistRules
