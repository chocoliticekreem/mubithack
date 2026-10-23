--!strict
-- HazardMath [owner: GF/hazards]. Pure maths for HazardService (no Roblox APIs, so `luau` specs run in CI).
-- Every vector is plain numbers (x, z or x, y, z) so this stays free of Vector3.
--   HazardMath.falloff(d, radius): number                         -- 1 at the centre, 0 at/after radius
--   HazardMath.knockback(d, radius, maxSpeed, minSpeed?): number  -- speed for a blast at distance d
--   HazardMath.blastDamage(d, radius, maxDamage): number          -- rounded, 0 outside
--   HazardMath.tornadoStep(x, z, heading, tx?, tz?, bias, speed, dt, rand, cx, cz, leash): (x, z, heading)
--   HazardMath.inBox(px, py, pz, cx, cy, cz, hx, hy, hz): boolean -- axis-aligned (box-local coords)
--   HazardMath.waveFront(t, speed, length): number               -- distance of the wall along its path
--   HazardMath.waveHit(along, front, thickness): boolean         -- is a point at `along` inside the wall
--   HazardMath.inCone(dx, dy, dz, fx, fy, fz, range, cosHalf): boolean  -- backdraft fireball cone
--   HazardMath.collapseShouldFall(supportsCharred, supportsTotal, threshold): boolean
local HazardMath = {}

local function clamp(v: number, lo: number, hi: number): number
	if v < lo then
		return lo
	elseif v > hi then
		return hi
	end
	return v
end
HazardMath.clamp = clamp

function HazardMath.falloff(d: number, radius: number): number
	if radius <= 0 then
		return 0
	end
	return clamp(1 - d / radius, 0, 1)
end

-- Knockback keeps a floor (minSpeed) anywhere inside the radius so even the edge of a blast is funny.
function HazardMath.knockback(d: number, radius: number, maxSpeed: number, minSpeed: number?): number
	if d >= radius then
		return 0
	end
	local lo = minSpeed or 0
	return lo + (maxSpeed - lo) * HazardMath.falloff(d, radius)
end

function HazardMath.blastDamage(d: number, radius: number, maxDamage: number): number
	return math.floor(maxDamage * HazardMath.falloff(d, radius) + 0.5)
end

-- One step of the fire tornado's wander. `heading` is radians in the XZ plane. With a target
-- (nearest player), the heading turns toward it by `bias` (0..1); `rand()` in [0, 1) adds jitter.
-- If the tornado drifts beyond `leash` studs from its field centre (cx, cz), it turns home.
function HazardMath.tornadoStep(
	x: number,
	z: number,
	heading: number,
	tx: number?,
	tz: number?,
	bias: number,
	speed: number,
	dt: number,
	rand: () -> number,
	cx: number,
	cz: number,
	leash: number
): (number, number, number)
	local h = heading + (rand() - 0.5) * 1.2 -- wobble
	local function turnToward(ax: number, az: number, amount: number)
		local want = math.atan2(az - z, ax - x)
		local diff = (want - h + math.pi) % (2 * math.pi) - math.pi
		h += diff * amount
	end
	if tx and tz then
		turnToward(tx, tz, clamp(bias, 0, 1))
	end
	local dx, dz = x - cx, z - cz
	if dx * dx + dz * dz > leash * leash then
		turnToward(cx, cz, 0.8)
	end
	local nx = x + math.cos(h) * speed * dt
	local nz = z + math.sin(h) * speed * dt
	return nx, nz, h
end

function HazardMath.inBox(px: number, py: number, pz: number, cx: number, cy: number, cz: number, hx: number, hy: number, hz: number): boolean
	return math.abs(px - cx) <= hx and math.abs(py - cy) <= hy and math.abs(pz - cz) <= hz
end

function HazardMath.waveFront(t: number, speed: number, length: number): number
	return clamp(t * speed, 0, length)
end

-- The wall is `thickness` studs deep and its leading face is at `front`.
function HazardMath.waveHit(along: number, front: number, thickness: number): boolean
	return along <= front and along >= front - thickness
end

-- (dx, dy, dz) = target - origin; (fx, fy, fz) = unit forward. cosHalf = cos(half-angle).
function HazardMath.inCone(dx: number, dy: number, dz: number, fx: number, fy: number, fz: number, range: number, cosHalf: number): boolean
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if d > range then
		return false
	end
	if d < 1e-4 then
		return true
	end
	return (dx * fx + dy * fy + dz * fz) / d >= cosHalf
end

function HazardMath.collapseShouldFall(charred: number, total: number, threshold: number): boolean
	if total <= 0 then
		return false
	end
	return charred / total >= threshold
end

return HazardMath
