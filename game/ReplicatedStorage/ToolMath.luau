--!strict
-- ToolMath [owner: G1]. Pure maths for the hose, extinguisher, axe and knockbacks, shared by
-- ToolService (server), ToolController (client) and Ragdoll. NO Roblox APIs (no Vector3, CFrame,
-- game, task), so game/tests/tools.spec.luau runs it with the `luau` CLI. Vectors are plain numbers.
--
--   ToolMath.clamp01(x): number
--   ToolMath.inCone(dx, dy, dz, ax, ay, az, range, minCos): boolean   -- d = target - origin, a = unit aim
--   ToolMath.pressure(water, tankSize, linePressure?): number          -- 0..1, drives recoil/push/shake
--   ToolMath.recoilSpeed(base, pressure, crouched): number             -- studs/s push-back on the sprayer
--   ToolMath.push(ax, az, speed, lift): (x, y, z)                      -- horizontal shove along the aim + lift
--   ToolMath.clampMagnitude(x, y, z, max): (x, y, z)
--   ToolMath.arcPoint(ox, oy, oz, vx, vy, vz, g, t): (x, y, z)         -- gravity arc, g > 0 pulls down
--   ToolMath.arcBezier(ox, oy, oz, vx, vy, vz, g, t): { p1, p2, p3 }   -- cubic control points of the arc to time t
--   ToolMath.slide(vx, vz, wantX, wantZ, grip, dt): (x, z)             -- wet-floor ice: blend toward the wanted velocity
--   ToolMath.doorHit(hits, needed): (newHits, broke)
--   ToolMath.puddleRadius(litres, minR, maxR): number
--   ToolMath.shake(pressure, base, extra): number                      -- trauma 0..1 while spraying

local ToolMath = {}

function ToolMath.clamp01(x: number): number
	if x ~= x then
		return 0
	end
	return math.clamp(x, 0, 1)
end

function ToolMath.inCone(dx: number, dy: number, dz: number, ax: number, ay: number, az: number, range: number, minCos: number): boolean
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if d > range then
		return false
	end
	if d < 1e-3 then
		return true
	end
	local a = math.sqrt(ax * ax + ay * ay + az * az)
	if a < 1e-6 then
		return false
	end
	return (dx * ax + dy * ay + dz * az) / (d * a) >= minCos
end

-- The backpack tank's fill sets the base: a full tank blasts at 1.0, a nearly empty one sputters at
-- ~0.55, an empty one is 0. A hose line (HoseLine.getPressure, 1 = unkinked or no line) multiplies it,
-- so a teammate standing on your hose really does weaken your stream.
function ToolMath.pressure(water: number, tankSize: number, linePressure: number?): number
	if water <= 0 or tankSize <= 0 then
		return 0
	end
	local tank = 0.55 + 0.45 * ToolMath.clamp01(water / tankSize)
	return tank * ToolMath.clamp01(if linePressure == nil then 1 else linePressure)
end

function ToolMath.recoilSpeed(base: number, pressure: number, crouched: boolean): number
	local s = base * ToolMath.clamp01(pressure)
	return if crouched then s / 3 else s
end

function ToolMath.push(ax: number, az: number, speed: number, lift: number): (number, number, number)
	local m = math.sqrt(ax * ax + az * az)
	if m < 1e-3 then
		return 0, lift, 0
	end
	return ax / m * speed, lift, az / m * speed
end

function ToolMath.clampMagnitude(x: number, y: number, z: number, max: number): (number, number, number)
	local m = math.sqrt(x * x + y * y + z * z)
	if m <= max or m < 1e-9 then
		return x, y, z
	end
	local k = max / m
	return x * k, y * k, z * k
end

function ToolMath.arcPoint(ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, g: number, t: number): (number, number, number)
	return ox + vx * t, oy + vy * t - 0.5 * g * t * t, oz + vz * t
end

-- The arc p(t) is a quadratic; as a cubic Bezier from p(0) to p(T) its inner control points are
-- p0 + v*T/3 and p3 - v(T)*T/3, where v(T) = v - g*T (vertical). Beams use them as CurveSize0/1.
function ToolMath.arcBezier(ox: number, oy: number, oz: number, vx: number, vy: number, vz: number, g: number, t: number): { { number } }
	local x3, y3, z3 = ToolMath.arcPoint(ox, oy, oz, vx, vy, vz, g, t)
	local k = t / 3
	local p1 = { ox + vx * k, oy + vy * k, oz + vz * k }
	local p2 = { x3 - vx * k, y3 - (vy - g * t) * k, z3 - vz * k }
	return { p1, p2, { x3, y3, z3 } }
end

function ToolMath.slide(vx: number, vz: number, wantX: number, wantZ: number, grip: number, dt: number): (number, number)
	local a = ToolMath.clamp01(grip * dt)
	return vx + (wantX - vx) * a, vz + (wantZ - vz) * a
end

function ToolMath.doorHit(hits: number, needed: number): (number, boolean)
	local n = hits + 1
	if n >= needed then
		return 0, true
	end
	return n, false
end

function ToolMath.puddleRadius(litres: number, minR: number, maxR: number): number
	return math.clamp(minR + math.sqrt(math.max(litres, 0)) * 0.6, minR, maxR)
end

function ToolMath.shake(pressure: number, base: number, extra: number): number
	return ToolMath.clamp01(base + extra * ToolMath.clamp01(pressure))
end

-- 0 when `dist` <= near, 1 when >= far, smooth in between: how much of a spray / steam effect may
-- show this close to the camera (first-person stream, impact splash, douse steam).
function ToolMath.lensFade(dist: number, near: number, far: number): number
	if far <= near then
		return if dist >= far then 1 else 0
	end
	local t = ToolMath.clamp01((dist - near) / (far - near))
	return t * t * (3 - 2 * t)
end

return ToolMath
