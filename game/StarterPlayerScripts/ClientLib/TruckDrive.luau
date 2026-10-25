--!strict
-- TruckDrive [owner: Vehicle agent]. Pure driving maths for the fire trucks (no Roblox APIs;
-- spec: game/tests/truck_drive.spec.luau). VehicleController runs these every physics step on the
-- driver's client (the driver owns the truck).
--   TruckDrive.spring(hitDist, restLen, vel, k, damping): number  -- upward accel (studs/s^2) for one corner
--   TruckDrive.drive(throttle, fwdSpeed, maxSpeed, accel, brake): number  -- forward accel
--   TruckDrive.steerRate(steer, fwdSpeed, turnSpeed, maxSpeed): number   -- yaw rate (rad/s), reverses in reverse
--   TruckDrive.grip(lateralSpeed, grip): number                         -- sideways accel that cancels sliding
--   TruckDrive.rollTarget(steer, fwdSpeed, maxSpeed, maxRoll): number   -- body lean (rad, + = right side down)
--   TruckDrive.wheelie(throttle, prevThrottle, fwdSpeed, maxSpeed, kick): number -- pitch-up rate on launch
--   TruckDrive.bump(compressionRate, threshold, gain): number           -- pitch-up rate on a front bump
--   TruckDrive.squash(airTime, impactSpeed): number                     -- 0..1 landing squash strength
--   TruckDrive.squashSpring(t, seconds, soften): number                 -- spring multiplier t s after landing
--   TruckDrive.sirenPitch(speed, maxSpeed, t, wailHz, base, perSpeed, wail): number
--   TruckDrive.fov(speed, maxSpeed, base, add): number
--   TruckDrive.stepDt(dt, maxDt): number                 -- frame dt clamped for impulses/accels (low FPS)
--   TruckDrive.servoGain(gain, dt, maxFraction): number  -- P gain that can't overshoot within one frame
--   TruckDrive.capRate(rate, dt, maxAnglePerFrame): number -- angular rate limited to an angle per frame
--   TruckDrive.cornerDist(rayDist, lift): number         -- lifted suspension ray -> distance from the centre plane
--   TruckDrive.sinkDepth(cornerDist, halfHeight): number -- > 0 = chassis bottom under the surface (sunk)
--   TruckDrive.capVelocity(x, y, z, maxFall, maxSpeed): (x, y, z) -- fall + fling speed caps (anti-tunnel)
-- Arcade handling (v3, "grips like a Jailbreak car"):
--   TruckDrive.arcadeDrive(throttle, fwdSpeed, maxSpeed, accel, brake, coast): number -- forward accel;
--       |throttle| sets the target speed (half stick = half speed), letting go brakes to a stop
--   TruckDrive.arcadeYaw(steer, fwdSpeed, maxSpeed, rLow, rHigh, maxYaw): number -- yaw rate (rad/s):
--       tight turning circle when slow, wide when fast, 0 when standing, flips in reverse
--   TruckDrive.approach(cur, want, dt, rise, fall): number -- rate-limited input smoothing
--   TruckDrive.touchStick(x, y, fwdSpeed, deadzone, expo, cruise): (steer, throttle) -- kid-proof touch stick
--   TruckDrive.alignAngle(fx, fz, rx, rz): number -- signed angle (rad, + = road is to the right) from
--       the truck's heading to a road direction (either way along the road, whichever is closer)
local TruckDrive = {}

-- Spring-damper on one suspension ray. hitDist = nil means the wheel is in the air.
-- Low damping on purpose: the truck should bounce like a jelly.
function TruckDrive.spring(hitDist: number?, restLen: number, vel: number, k: number, damping: number): number
	if hitDist == nil or hitDist >= restLen then
		return 0
	end
	local compression = restLen - hitDist
	local a = compression * k - vel * damping
	if a < 0 then
		return 0 -- springs push, never pull
	end
	return a
end

function TruckDrive.drive(throttle: number, fwdSpeed: number, maxSpeed: number, accel: number, brake: number): number
	if throttle == 0 then
		-- coast: gentle engine drag
		return -fwdSpeed * 0.6
	end
	if fwdSpeed * throttle < 0 then
		-- pressing against the current motion = braking
		return throttle * brake
	end
	local cap = if throttle > 0 then maxSpeed else maxSpeed * 0.5
	if math.abs(fwdSpeed) >= cap then
		return 0
	end
	return throttle * accel
end

function TruckDrive.steerRate(steer: number, fwdSpeed: number, turnSpeed: number, maxSpeed: number): number
	-- full turn rate from ~25% of max speed; a tiny turn when barely rolling; flips when reversing
	local f = math.clamp(math.abs(fwdSpeed) / math.max(maxSpeed * 0.25, 1), 0, 1)
	local dir = if fwdSpeed < -0.5 then -1 else 1
	return -steer * turnSpeed * f * dir
end

function TruckDrive.grip(lateralSpeed: number, grip: number): number
	return -lateralSpeed * grip
end

-- Lean out of the turn: steering right (steer > 0) going forward puts the LEFT side down (negative).
function TruckDrive.rollTarget(steer: number, fwdSpeed: number, maxSpeed: number, maxRoll: number): number
	local f = math.clamp(math.abs(fwdSpeed) / math.max(maxSpeed, 1), 0, 1)
	return -steer * f * maxRoll
end

-- Floor it from (nearly) standing still and the nose pops up. Only on the press, fades with speed.
function TruckDrive.wheelie(throttle: number, prevThrottle: number, fwdSpeed: number, maxSpeed: number, kick: number): number
	if throttle <= 0 or prevThrottle > 0 then
		return 0
	end
	local f = 1 - math.clamp(math.abs(fwdSpeed) / math.max(maxSpeed * 0.4, 1), 0, 1)
	return kick * f
end

-- Front suspension slammed upwards fast (a kerb, a ramp, a hose reel...) -> extra nose-up rate.
function TruckDrive.bump(compressionRate: number, threshold: number, gain: number): number
	if compressionRate <= threshold then
		return 0
	end
	return (compressionRate - threshold) * gain
end

-- How hard a landing was, 0..1 (needs a real hop and a real downward speed).
function TruckDrive.squash(airTime: number, impactSpeed: number): number
	if airTime < 0.25 then
		return 0
	end
	return math.clamp((impactSpeed - 12) / 45, 0, 1)
end

-- Spring multiplier t seconds after a hard landing: soft at first (deep squash), then back to 1.
function TruckDrive.squashSpring(t: number, seconds: number, soften: number): number
	if t < 0 or t >= seconds then
		return 1
	end
	local u = t / seconds
	return soften + (1 - soften) * u * u
end

-- Wailing siren that climbs with speed.
function TruckDrive.sirenPitch(
	speed: number,
	maxSpeed: number,
	t: number,
	wailHz: number,
	base: number,
	perSpeed: number,
	wail: number
): number
	local f = math.clamp(math.abs(speed) / math.max(maxSpeed, 1), 0, 1)
	return base + perSpeed * f + wail * math.sin(t * wailHz * 2 * math.pi)
end

function TruckDrive.fov(speed: number, maxSpeed: number, base: number, add: number): number
	local f = math.clamp(math.abs(speed) / math.max(maxSpeed, 1), 0, 1)
	return base + add * f * f
end

-- Low frame rates. The driver's client sets the truck's velocities once per FRAME, and they then
-- hold for the whole frame. At 60 fps that is smooth; at 2-10 fps (a laggy client, a busy Studio)
-- a whole frame of spring impulse, wheelie kick or roll correction flung or flipped the truck.

-- dt for per-frame impulses and accelerations, clamped so one slow frame can't deliver a huge kick.
function TruckDrive.stepDt(dt: number, maxDt: number): number
	return math.clamp(dt, 0, maxDt)
end

-- A proportional gain (rate = gain * error) held for dt overshoots once gain * dt > 1 and oscillates
-- divergently past 2. Cap it so one frame closes at most maxFraction of the error.
function TruckDrive.servoGain(gain: number, dt: number, maxFraction: number): number
	if dt <= 0 then
		return gain
	end
	return math.min(gain, maxFraction / dt)
end

-- Limit an angular rate so that, held for one frame, it turns the body by at most maxAngle radians.
function TruckDrive.capRate(rate: number, dt: number, maxAngle: number): number
	if dt <= 0 then
		return rate
	end
	local cap = maxAngle / dt
	return math.clamp(rate, -cap, cap)
end

-- Anti-tunnel. Suspension rays start `lift` studs above each corner (a ray never hits a part it starts
-- inside), so a corner that sank into the road still measures it: rayDist = distance from the lifted
-- origin. Returns the corner's distance to the surface measured from the chassis centre plane (can be
-- negative: the surface is above the centre).
function TruckDrive.cornerDist(rayDist: number, lift: number): number
	return rayDist - lift
end

-- How far the chassis bottom (halfHeight below the centre) sits under the surface at cornerDist; > 0 = sunk.
function TruckDrive.sinkDepth(cornerDist: number, halfHeight: number): number
	return halfHeight - cornerDist
end

-- Speed caps: never fall faster than maxFall (a box moving more than its thickness a physics step
-- tunnels through thin parts), never move faster than maxSpeed overall (crash flings). Returns x, y, z.
function TruckDrive.capVelocity(x: number, y: number, z: number, maxFall: number, maxSpeed: number): (number, number, number)
	y = math.max(y, -maxFall)
	local m = math.sqrt(x * x + y * y + z * z)
	if m > maxSpeed and m > 0 then
		local k = maxSpeed / m
		return x * k, y * k, z * k
	end
	return x, y, z
end

-- Arcade throttle. |throttle| picks the target speed (a half-pushed touch stick cruises at half speed);
-- pushing against the motion brakes; no throttle = strong coast-down braking to a stop. The caller
-- clamps the result so one frame never pushes the speed past zero.
function TruckDrive.arcadeDrive(
	throttle: number,
	fwdSpeed: number,
	maxSpeed: number,
	accel: number,
	brake: number,
	coast: number
): number
	if math.abs(throttle) < 0.02 then
		if math.abs(fwdSpeed) < 0.05 then
			return 0
		end
		return -math.sign(fwdSpeed) * coast
	end
	if fwdSpeed * throttle < -0.5 then
		return throttle * brake
	end
	local cap = (if throttle > 0 then maxSpeed else maxSpeed * 0.5) * math.min(1, math.abs(throttle))
	local speed = math.abs(fwdSpeed)
	local dir = if throttle > 0 then 1 else -1
	if speed > cap then
		-- eased off the stick: slow down gently to the new target speed
		return -dir * math.min(coast, (speed - cap) * 2)
	end
	-- full pull until the last ~8 studs/s, then ease into the target (no lurch at top speed)
	return dir * accel * math.clamp((cap - speed) / 8, 0, 1)
end

-- Arcade steering: yaw rate = speed / turning radius. The radius grows with speed (rLow standing,
-- rHigh at maxSpeed), so the truck turns tight in a car park and gently on the avenue; standing
-- still it can't spin; capped at maxYaw; reversing flips it like a real car.
function TruckDrive.arcadeYaw(steer: number, fwdSpeed: number, maxSpeed: number, rLow: number, rHigh: number, maxYaw: number): number
	local speed = math.abs(fwdSpeed)
	local k = math.clamp(speed / math.max(maxSpeed, 1), 0, 1)
	local radius = rLow + (rHigh - rLow) * k * k
	local rate = math.min(speed / math.max(radius, 1), maxYaw)
	local dir = if fwdSpeed < -0.5 then -1 else 1
	return -steer * rate * dir
end

-- Move cur toward want by at most rise/s (growing in magnitude) or fall/s (shrinking / reversing).
function TruckDrive.approach(cur: number, want: number, dt: number, rise: number, fall: number): number
	local growing = math.abs(want) > math.abs(cur) and want * cur >= 0
	local rate = if growing then rise else fall
	local d = want - cur
	local maxStep = rate * dt
	if math.abs(d) <= maxStep then
		return want
	end
	return cur + math.sign(d) * maxStep
end

-- Touch stick -> (steer, throttle). Dead zone on both, expo curve on the steering so a wobbly thumb
-- doesn't jerk the wheel; pushing the stick SIDEWAYS (not pulled back) still drives forward at
-- `cruise` x the sideways push (a sensible cornering speed), so a kid who only steers neither rolls
-- to a stop mid-corner nor takes it flat out; pulling back brakes / reverses.
function TruckDrive.touchStick(x: number, y: number, fwdSpeed: number, deadzone: number, expo: number, cruise: number): (number, number)
	local function shape(v: number, e: number): number
		local a = math.abs(v)
		if a <= deadzone then
			return 0
		end
		local u = math.clamp((a - deadzone) / (1 - deadzone), 0, 1)
		return math.sign(v) * u ^ e
	end
	local steer = shape(x, expo) -- expo: fine steering near the centre
	local throttle = shape(y, 1) -- linear: half a push = half speed
	if throttle > -0.3 and fwdSpeed > -2 then
		throttle = math.max(throttle, cruise * math.abs(steer))
	end
	return steer, throttle
end

function TruckDrive.alignAngle(fx: number, fz: number, rx: number, rz: number): number
	if fx * rx + fz * rz < 0 then
		rx, rz = -rx, -rz
	end
	-- right of the heading (fx, fz) is (-fz, fx)
	local side = rx * -fz + rz * fx
	local ahead = rx * fx + rz * fz
	return math.atan2(side, ahead)
end

return TruckDrive
