--!strict
-- RubbleMath [owner: Structure]. Pure maths for Lib/Physics/Rubble (spec-tested by game/tests/rubble.spec.luau).
-- NO Roblox APIs; numbers and tables only. Keeps collapsing buildings CONTAINED to their plot: debris
-- falls, never launches sideways or up, never drifts far from where it let go.
--
--   RubbleMath.clampVelocity(vx, vy, vz, maxH, maxUp, maxDown): (x, y, z)  -- horizontal / up / down caps
--   RubbleMath.clampSpin(wx, wy, wz, max): (x, y, z)
--   RubbleMath.leash(dx, dz, vx, vz, radius): (vx, vz)  -- past `radius` from home: no outward speed
--   RubbleMath.verdict(age, speed, drift, y, cfg): "fly" | "settle" | "crumble"
--   RubbleMath.group(age, cfg): "RubbleFresh" | "Rubble"
-- cfg keys: RubbleFreshSeconds, RubbleMaxDrift, SettleMinSeconds, SettleMaxSeconds, SettleSpeed, VoidY

local RubbleMath = {}

function RubbleMath.clampVelocity(vx: number, vy: number, vz: number, maxH: number, maxUp: number, maxDown: number): (number, number, number)
	local h = math.sqrt(vx * vx + vz * vz)
	if h > maxH and h > 0 then
		local k = maxH / h
		vx, vz = vx * k, vz * k
	end
	return vx, math.clamp(vy, -maxDown, maxUp), vz
end

function RubbleMath.clampSpin(wx: number, wy: number, wz: number, max: number): (number, number, number)
	local m = math.sqrt(wx * wx + wy * wy + wz * wz)
	if m > max and m > 0 then
		local k = max / m
		return wx * k, wy * k, wz * k
	end
	return wx, wy, wz
end

-- (dx, dz) = piece position - its release point. Beyond `radius`, the outward part of the horizontal
-- velocity is removed (it can still slide back in or along the leash circle).
function RubbleMath.leash(dx: number, dz: number, vx: number, vz: number, radius: number): (number, number)
	local d = math.sqrt(dx * dx + dz * dz)
	if d <= radius or d == 0 then
		return vx, vz
	end
	local ux, uz = dx / d, dz / d
	local out = vx * ux + vz * uz
	if out <= 0 then
		return vx, vz
	end
	return vx - ux * out, vz - uz * out
end

-- What to do with a loose piece this frame. drift = horizontal distance from its release point.
function RubbleMath.verdict(age: number, speed: number, drift: number, y: number, cfg: { [string]: any }): string
	if y < (cfg.VoidY or -400) or drift > cfg.RubbleMaxDrift then
		return "crumble" -- escaped the plot (or the world): it turns to dust, never lands in the street
	end
	if age >= cfg.SettleMaxSeconds then
		return "settle"
	end
	if age >= cfg.SettleMinSeconds and speed < cfg.SettleSpeed then
		return "settle"
	end
	return "fly"
end

-- Fresh rubble ignores other rubble (overlapping chunks released together would explode apart);
-- after RubbleFreshSeconds it piles up on other rubble again.
function RubbleMath.group(age: number, cfg: { [string]: any }): string
	return if age < cfg.RubbleFreshSeconds then "RubbleFresh" else "Rubble"
end

return RubbleMath
