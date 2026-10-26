--!strict
-- HeliRules [owner: Heli]. PURE maths for the FIRE HELICOPTER (no Roblox APIs: numbers only, so
-- game/tests/heli.spec.luau runs it with the luau CLI). HeliController flies with it, HeliService
-- validates the bucket with it. cfg = HeliConfig (or a table with the same keys).
--
--   HeliRules.velocity(inp, st, cfg) -> (vx, vy, vz)
--     inp = { mx, mz (camera-relative world move, |m| <= 1), up (-1..1), touch: boolean? }
--     st  = { vx, vy, vz (current), dt, x, y, z, clearance (studs from skids to ground, math.huge = none),
--             blocked: boolean? (something solid ObstacleProbe ahead), bounds: { minX, maxX, minZ, maxZ }? }
--     Arcade: eases toward the stick, never sinks below MinClearance, never climbs past MaxY, pushes back
--     softly near the world walls, lifts over a wall in the way.
--   HeliRules.yawToward(yaw, vx, vz, dt, cfg) -> yaw      -- face where you fly (radians, Roblox yaw)
--   HeliRules.ropeDrop(clearance, cfg) -> studs           -- how far the bucket hangs below the belly
--   HeliRules.inWater(bx, by, bz, w, cfg) -> boolean      -- w = { minX, maxX, minZ, maxZ, top }
--   HeliRules.fill(fill, dt, inWater, cfg) -> number      -- 0..1
--   HeliRules.canDrop(d, cfg) -> (ok, reason?)            -- d = { pilot, fill, now, last, height }
--     reasons: "not pilot", "empty", "cooldown", "too high"
--   HeliRules.coneHeight(radius, coneCos) -> studs        -- FireService:ApplyWater origin height over the
--     splash point so its cone covers `radius` at the ground (the hose's cone, pointed straight down)
local HeliRules = {}

local function num(v: any, default: number): number
	return if type(v) == "number" and v == v then v else default
end

local function approach(cur: number, target: number, rate: number, dt: number): number
	local k = 1 - math.exp(-rate * dt)
	return cur + (target - cur) * k
end

function HeliRules.velocity(inp: any, st: any, cfg: any): (number, number, number)
	local dt = math.clamp(num(st.dt, 1 / 60), 0, 0.25)
	local mx, mz = num(inp.mx, 0), num(inp.mz, 0)
	local m = math.sqrt(mx * mx + mz * mz)
	if m > 1 then
		mx, mz, m = mx / m, mz / m, 1
	end
	local clearance = num(st.clearance, math.huge)
	local speed = num(cfg.Speed, 70)
	if clearance > num(cfg.AltitudeBoostAbove, 60) then
		speed = num(cfg.BoostSpeed, speed)
	end
	if inp.touch then
		speed *= num(cfg.TouchSpeedScale, 1)
	end
	local tx, tz = mx * speed, mz * speed
	local up = math.clamp(num(inp.up, 0), -1, 1)
	local ty = up * num(cfg.ClimbSpeed, 30)

	-- a wall ahead: stop pushing into it and climb over it
	if st.blocked and m > 0.1 then
		tx, tz = tx * 0.15, tz * 0.15
		ty = math.max(ty, num(cfg.ObstacleLift, 24))
	end

	-- soft world bounds: past (wall - margin) the target swings back inside
	local b = st.bounds
	if type(b) == "table" then
		local margin = num(cfg.BoundsMargin, 60)
		local x, z = num(st.x, 0), num(st.z, 0)
		local push = speed * 0.8
		if x < b.minX + margin then
			tx = math.max(tx, push * math.min(1, (b.minX + margin - x) / margin))
		elseif x > b.maxX - margin then
			tx = math.min(tx, -push * math.min(1, (x - (b.maxX - margin)) / margin))
		end
		if z < b.minZ + margin then
			tz = math.max(tz, push * math.min(1, (b.minZ + margin - z) / margin))
		elseif z > b.maxZ - margin then
			tz = math.min(tz, -push * math.min(1, (z - (b.maxZ - margin)) / margin))
		end
	end

	-- altitude: hover floor (MinClearance over the ground) and ceiling (MaxY)
	local minC = num(cfg.MinClearance, 3)
	if clearance < minC then
		ty = math.max(ty, math.min(num(cfg.ClimbSpeed, 30), (minC - clearance) * 6))
	elseif ty < 0 and clearance - minC < 6 then
		ty = ty * math.max(0, (clearance - minC) / 6) -- ease into the floor, no thud
	end
	local y = num(st.y, 0)
	local maxY = num(cfg.MaxY, 260)
	if y > maxY then
		ty = math.min(ty, -(y - maxY) * 2)
	elseif ty > 0 and maxY - y < 10 then
		ty = ty * math.max(0, (maxY - y) / 10)
	end

	local rate = num(cfg.Accel, 2.5)
	local vx = approach(num(st.vx, 0), tx, rate, dt)
	local vz = approach(num(st.vz, 0), tz, rate, dt)
	local vy = approach(num(st.vy, 0), ty, rate * 2, dt) -- up / down answers quicker
	return vx, vy, vz
end

-- Roblox yaw: CFrame.Angles(0, yaw, 0) looks along (-sin yaw, 0, -cos yaw)
function HeliRules.yawToward(yaw: number, vx: number, vz: number, dt: number, cfg: any): number
	if vx * vx + vz * vz < 16 then
		return yaw -- hovering (under 4 studs/s): keep the heading
	end
	local want = math.atan2(-vx, -vz)
	local d = (want - yaw + math.pi) % (2 * math.pi) - math.pi
	return yaw + d * (1 - math.exp(-num(cfg.TurnRate, 2.4) * math.clamp(dt, 0, 0.25)))
end

function HeliRules.ropeDrop(clearance: number, cfg: any): number
	local rope = num(cfg.RopeLength, 11)
	-- landed / low: the bucket rests on the ground (2 studs below the belly at least, never under it)
	return math.clamp(num(clearance, rope) + 1.2, 2, rope)
end

function HeliRules.inWater(bx: number, by: number, bz: number, w: any, cfg: any): boolean
	if type(w) ~= "table" then
		return false
	end
	local margin = num(cfg.FillMargin, 5)
	if bx < w.minX - margin or bx > w.maxX + margin or bz < w.minZ - margin or bz > w.maxZ + margin then
		return false
	end
	local top = num(w.top, 0)
	return by <= top + num(cfg.FillReach, 7) and by >= top - 30
end

function HeliRules.fill(fill: number, dt: number, inWater: boolean, cfg: any): number
	if not inWater then
		return math.clamp(num(fill, 0), 0, 1)
	end
	local secs = math.max(0.1, num(cfg.FillSeconds, 2.2))
	return math.clamp(num(fill, 0) + math.max(0, dt) / secs, 0, 1)
end

function HeliRules.canDrop(d: any, cfg: any): (boolean, string?)
	if not d.pilot then
		return false, "not pilot"
	end
	if num(d.fill, 0) < 0.999 then
		return false, "empty"
	end
	if num(d.now, 0) - num(d.last, -math.huge) < num(cfg.DropCooldown, 8) then
		return false, "cooldown"
	end
	if num(d.height, 0) > num(cfg.DropMaxHeight, 90) then
		return false, "too high"
	end
	return true, nil
end

function HeliRules.coneHeight(radius: number, coneCos: number): number
	local c = math.clamp(num(coneCos, 0.86), 0.05, 0.999)
	local tan = math.sqrt(1 - c * c) / c
	return num(radius, 18) / tan
end

return HeliRules
