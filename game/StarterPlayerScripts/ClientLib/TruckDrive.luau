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

return TruckDrive
