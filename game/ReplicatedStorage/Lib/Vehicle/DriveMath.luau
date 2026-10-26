--!strict
-- DriveMath [owner: Drive]. PURE maths for the drive to a call (Services/DriveService telemetry and
-- practice fires, Controllers/DriveController HUD, VehicleController straight-road boost). No Roblox
-- APIs, so game/tests/drive.spec.luau runs it under the plain `luau` CLI.
--
--   DriveMath.metres(studs) -> number                         -- whole metres (3.5 studs = 1 m, like the GPS)
--   DriveMath.secondsBucket(s) -> "0-15" | "15-30" | "30-60" | "60-120" | "120+"
--   DriveMath.countBucket(n) -> "0" | "1" | "2+"
--   DriveMath.wrongBucket(s) -> "0" | "1-10" | "10+"
--   DriveMath.quitField(reason, seconds, resets, stuck, wrongSeconds) -> string
--       CustomField03 of DriveQuit, a small constant set: "left|t30-60|r1|s0|w10+"
--   DriveMath.stuckCause(hasDriver, throttle, speed, wrongWay) -> "nodriver" | "idle" | "blocked" | "wrongway"
--   DriveMath.eta(leftStuds, speed, minSpeed) -> whole seconds (>= 0)
--   DriveMath.progress(total, left) -> 0..1
--   DriveMath.approach(v, target, dt, rise, fall) -> number   -- rate-limited ease toward target
--   DriveMath.straight(fx, fz, rx, rz, steer, maxDeg, maxSteer) -> boolean   -- on a straight stretch?
--   DriveMath.spaced(total, skipStart, skipEnd, spacing, max) -> { number }  -- distances along a route
--   DriveMath.curbOffset(width, extra) -> studs from the centre line to the curb spot
local DriveMath = {}

local STUDS_PER_M = 3.5

function DriveMath.metres(studs: number): number
	return math.max(0, math.floor(studs / STUDS_PER_M + 0.5))
end

function DriveMath.secondsBucket(s: number): string
	if s < 15 then
		return "0-15"
	elseif s < 30 then
		return "15-30"
	elseif s < 60 then
		return "30-60"
	elseif s < 120 then
		return "60-120"
	end
	return "120+"
end

function DriveMath.countBucket(n: number): string
	if n <= 0 then
		return "0"
	elseif n == 1 then
		return "1"
	end
	return "2+"
end

function DriveMath.wrongBucket(s: number): string
	if s < 1 then
		return "0"
	elseif s < 10 then
		return "1-10"
	end
	return "10+"
end

-- reason: "left" (quit the game) | "cancel" (left the call before arriving)
function DriveMath.quitField(reason: string, seconds: number, resets: number, stuck: number, wrongSeconds: number): string
	local r = if reason == "cancel" then "cancel" else "left"
	return `{r}|t{DriveMath.secondsBucket(seconds)}|r{DriveMath.countBucket(resets)}|s{DriveMath.countBucket(stuck)}|w{DriveMath.wrongBucket(wrongSeconds)}`
end

-- Why a truck on a call got nowhere for a while.
function DriveMath.stuckCause(hasDriver: boolean, throttle: number, speed: number, wrongWay: boolean): string
	if not hasDriver then
		return "nodriver"
	end
	if wrongWay and speed > 4 then
		return "wrongway"
	end
	if math.abs(throttle) < 0.1 and speed < 4 then
		return "idle"
	end
	return "blocked"
end

function DriveMath.eta(left: number, speed: number, minSpeed: number): number
	local v = math.max(speed, minSpeed, 1)
	return math.max(0, math.floor(math.max(left, 0) / v + 0.5))
end

function DriveMath.progress(total: number, left: number): number
	if total <= 0 then
		return 1
	end
	return math.clamp(1 - left / total, 0, 1)
end

function DriveMath.approach(v: number, target: number, dt: number, rise: number, fall: number): number
	if v < target then
		return math.min(target, v + rise * dt)
	end
	return math.max(target, v - fall * dt)
end

-- fx, fz: the truck's flat forward; rx, rz: the road's direction (either way along it).
function DriveMath.straight(fx: number, fz: number, rx: number, rz: number, steer: number, maxDeg: number, maxSteer: number): boolean
	if math.abs(steer) >= maxSteer then
		return false
	end
	local lf = math.sqrt(fx * fx + fz * fz)
	local lr = math.sqrt(rx * rx + rz * rz)
	if lf < 1e-3 or lr < 1e-3 then
		return false
	end
	local dot = math.abs((fx * rx + fz * rz) / (lf * lr))
	return dot >= math.cos(math.rad(maxDeg))
end

function DriveMath.spaced(total: number, skipStart: number, skipEnd: number, spacing: number, max: number): { number }
	local out: { number } = {}
	if spacing <= 0 or max <= 0 then
		return out
	end
	local along = skipStart
	while along <= total - skipEnd and #out < max do
		table.insert(out, along)
		along += spacing
	end
	return out
end

function DriveMath.curbOffset(width: number?, extra: number): number
	local w = if type(width) == "number" and width > 0 then width else 24
	return w / 2 + extra
end

return DriveMath
