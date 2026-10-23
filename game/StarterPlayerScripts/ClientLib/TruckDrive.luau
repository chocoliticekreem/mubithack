--!strict
-- TruckDrive [owner: Vehicle agent]. Pure driving maths for the fire trucks (no Roblox APIs;
-- spec: game/tests/truck_drive.spec.luau). VehicleController runs these every physics step on the
-- driver's client (the driver owns the truck).
--
-- Model: an arcade "bicycle" car. Raycast springs carry the body (their loads give real weight
-- transfer); two axles (front steered, rear driven) each make a tyre force from their slip angle,
-- capped by grip * load and never more than the impulse that would cancel the slide (so it can't
-- jitter). Handbrake = rear grip drops + rear brake -> the tail steps out; counter-steer assist
-- turns the front wheels into the slide so a held drift stays controllable.
--
--   TruckDrive.spring(hitDist, restLen, vel, k, damping): number    -- upward accel (studs/s^2), one corner
--   TruckDrive.torqueCurve(s): number                                -- 0..~1 engine pull at speed fraction s
--   TruckDrive.drive(throttle, fwdSpeed, c: DriveCfg): number        -- forward accel (throttle/brake/reverse/coast)
--   TruckDrive.steerMax(speed, low, high, maxSpeed): number          -- speed-sensitive max steer angle (rad)
--   TruckDrive.steerToward(cur, want, dt, rate, returnRate): number  -- rate-limited steering wheel
--   TruckDrive.counterSteer(bodySlip, fwdSpeed, assist, maxAngle): number -- extra steer into a slide (rad)
--   TruckDrive.tyreCurve(slipAngle, peak, slide): number            -- 0..1 lateral grip vs |slip angle|
--   TruckDrive.axleImpulse(vLat, vLong, load, mu, mEff, dt, peak, slide, stiff): number -- lateral impulse
--   TruckDrive.frictionCircle(longForce, maxForce): number          -- lateral force budget left (0..maxForce)
--   TruckDrive.gear(speed, maxSpeed, shifts): (number, number)      -- virtual gear + rpm 0..1 (engine pitch)
--   TruckDrive.enginePitch(rpm, throttle): number
--   TruckDrive.wheelie(throttle, prevThrottle, fwdSpeed, maxSpeed, kick): number
--   TruckDrive.bump(compressionRate, threshold, gain): number
--   TruckDrive.squash(airTime, impactSpeed): number
--   TruckDrive.squashSpring(t, seconds, soften): number
--   TruckDrive.sirenPitch(speed, maxSpeed, t, wailHz, base, perSpeed, wail): number
--   TruckDrive.fov(speed, maxSpeed, base, add): number
--   TruckDrive.fovKick(longAccel, accel, kick): number               -- extra FOV while surging forward
local TruckDrive = {}

export type DriveCfg = {
	MaxSpeed: number,
	Accel: number, -- peak engine pull (studs/s^2)
	Brake: number, -- studs/s^2 when pressing against the motion
	ReverseSpeed: number,
	ReverseAccel: number,
	RollDrag: number, -- studs/s^2 coasting drag
	AeroDrag: number, -- per (studs/s)^2
}

-- Spring-damper on one suspension ray. hitDist = nil means the wheel is in the air.
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

-- Engine pull vs speed fraction: a strong shove off the line, peak around 1/3 of top speed, then it
-- fades to nothing at top speed (no hard limiter feel).
function TruckDrive.torqueCurve(s: number): number
	s = math.clamp(s, 0, 1)
	return (0.85 + 0.6 * s) * (1 - s ^ 2.5)
end

function TruckDrive.drive(throttle: number, fwdSpeed: number, c: DriveCfg): number
	local mag = math.abs(throttle)
	if mag < 0.05 then
		-- coast: rolling + air drag, never pushing past standstill
		local drag = c.RollDrag + c.AeroDrag * fwdSpeed * fwdSpeed
		return -math.sign(fwdSpeed) * drag
	end
	if throttle > 0 then
		if fwdSpeed < -1 then
			return c.Brake * mag -- rolling backwards: brake first
		end
		return c.Accel * mag * TruckDrive.torqueCurve(fwdSpeed / math.max(c.MaxSpeed, 1))
	end
	if fwdSpeed > 1 then
		return -c.Brake * mag
	end
	return -c.ReverseAccel * mag * TruckDrive.torqueCurve(-fwdSpeed / math.max(c.ReverseSpeed, 1))
end

-- Lock-to-lock shrinks with speed: tight in the station, calm on the avenue.
function TruckDrive.steerMax(speed: number, low: number, high: number, maxSpeed: number): number
	local f = math.clamp(math.abs(speed) / math.max(maxSpeed, 1), 0, 1)
	f = 1 - (1 - f) * (1 - f) -- drops quickly at first, then levels off
	return low + (high - low) * f
end

-- Steering wheel moves at `rate` rad/s, snaps back to centre faster (`returnRate`).
function TruckDrive.steerToward(cur: number, want: number, dt: number, rate: number, returnRate: number): number
	local r = if math.abs(want) < math.abs(cur) or want * cur < 0 then returnRate else rate
	local step = r * dt
	if math.abs(want - cur) <= step then
		return want
	end
	return cur + math.sign(want - cur) * step
end

-- Body slip (rad, + = sliding to the right of the nose) -> extra front-wheel angle toward the slide.
function TruckDrive.counterSteer(bodySlip: number, fwdSpeed: number, assist: number, maxAngle: number): number
	if fwdSpeed < 4 then
		return 0
	end
	return math.clamp(bodySlip * assist, -maxAngle, maxAngle)
end

-- Lateral grip vs slip angle: linear up to `peak` (rad), then falls off to `slide` (0..1) when sliding.
function TruckDrive.tyreCurve(slipAngle: number, peak: number, slide: number): number
	local a = math.abs(slipAngle)
	if a <= peak then
		return a / math.max(peak, 1e-3)
	end
	local over = math.clamp((a - peak) / math.max(peak * 2, 1e-3), 0, 1)
	return 1 - (1 - slide) * over
end

-- Signed lateral impulse for one axle (studs/s * mass). Opposes vLat; at most grip * load * dt, and at
-- most `stiff` (0..1) of what cancels the slide outright (mEff = effective mass at that axle).
function TruckDrive.axleImpulse(
	vLat: number,
	vLong: number,
	load: number,
	mu: number,
	mEff: number,
	dt: number,
	peak: number,
	slide: number,
	stiff: number
): number
	if load <= 0 or vLat == 0 then
		return 0
	end
	local slip = math.atan2(math.abs(vLat), math.max(math.abs(vLong), 3))
	local maxJ = mu * load * dt * TruckDrive.tyreCurve(slip, peak, slide)
	-- below the peak the tyre simply holds (kinematic, no wobble); the curve only matters once sliding
	if slip <= peak then
		maxJ = mu * load * dt
	end
	local cancel = math.abs(vLat) * mEff * stiff
	return -math.sign(vLat) * math.min(maxJ, cancel)
end

-- Grip used by braking/driving leaves less for cornering (friction circle).
function TruckDrive.frictionCircle(longForce: number, maxForce: number): number
	if maxForce <= 0 then
		return 0
	end
	local u = math.clamp(math.abs(longForce) / maxForce, 0, 0.95)
	return maxForce * math.sqrt(1 - u * u)
end

-- Virtual gearbox for the engine note: shifts = speed fractions where each gear tops out.
function TruckDrive.gear(speed: number, maxSpeed: number, shifts: { number }): (number, number)
	local s = math.clamp(math.abs(speed) / math.max(maxSpeed, 1), 0, 1)
	local lo = 0
	for i, top in shifts do
		if s <= top or i == #shifts then
			return i, math.clamp((s - lo) / math.max(top - lo, 1e-3), 0, 1)
		end
		lo = top
	end
	return 1, 0
end

function TruckDrive.enginePitch(rpm: number, throttle: number): number
	return 0.75 + rpm * 0.65 + (if math.abs(throttle) > 0.05 then 0.08 else 0)
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

-- Punch of FOV while the truck is surging forward (accelerating), none while braking.
function TruckDrive.fovKick(longAccel: number, accel: number, kick: number): number
	return kick * math.clamp(longAccel / math.max(accel, 1), 0, 1)
end

return TruckDrive
