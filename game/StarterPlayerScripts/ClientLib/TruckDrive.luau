--!strict
-- TruckDrive [owner: G2]. Pure driving maths for truck 67 (no Roblox APIs; spec: game/tests/truck_drive.spec.luau).
-- VehicleController runs these every physics step on the driver's client (the driver owns the truck).
--   TruckDrive.spring(hitDist, restLen, vel, k, damping): number  -- upward accel (studs/s^2) for one corner
--   TruckDrive.drive(throttle, fwdSpeed, maxSpeed, accel, brake): number  -- forward accel
--   TruckDrive.steerRate(steer, fwdSpeed, turnSpeed, maxSpeed): number   -- yaw rate (rad/s), reverses in reverse
--   TruckDrive.grip(lateralSpeed, grip): number                         -- sideways accel that cancels sliding
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

return TruckDrive
