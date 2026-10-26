--!strict
-- Driver [owner: Traffic]. PURE driving decisions (no Roblox APIs; spec: game/tests/traffic.spec.luau).
-- Every function takes plain numbers and a cfg table (TrafficConfig on the server).
--
--   Driver.approach(v, target, accel, brake, dt) -> v'            -- speed toward a target
--   Driver.followSpeed(gap, limit, cfg) -> number                  -- speed that keeps a safe gap
--   Driver.stopSpeed(dist, brake) -> number                        -- fastest speed that still stops in `dist`
--   Driver.light(value) -> "green" | "yellow" | "red" | nil        -- normalise a LightState attribute
--   Driver.mustStopForLight(state, dist, v, brake) -> boolean
--   Driver.relative(px, pz, hx, hz, ox, oz) -> (fwd, right)        -- (o - p) in a heading's frame
--   Driver.leaderGap(fwd, right, myHx, myHz, oHx, oHz, halfA, halfB, cfg) -> number?
--   Driver.pedGap(fwd, right, half, cfg) -> number?
--   Driver.shouldYield(fwd, right, closing, sirenOn, cfg) -> boolean   -- truck rel. to the car
--   Driver.truckPassed(fwd, right, cfg) -> boolean
--   Driver.slowBehind(fwd, right, cfg) -> boolean                  -- a slow truck right behind the car
--   Driver.rammed(relX, relZ, truckSpeed, cfg) -> boolean          -- car in the truck's local frame (-Z = forward)
--   Driver.panicWobble(t, seed) -> (lateral, yaw)                   -- comic swerve
--   Driver.pickWeighted(weights, roll) -> string?
--   Driver.turnSpeed(radius, limit, cfg) -> number                -- comfortable speed through a curve
--   Driver.entrySpeed(dist, vNext, brake) -> number                -- fastest speed now that still slows to vNext in dist
--   Driver.passClear(fwd, right, sameDir, cfg) -> boolean          -- another car leaves the passing corridor clear

local Driver = {}

function Driver.approach(v: number, target: number, accel: number, brake: number, dt: number): number
	if v < target then
		return math.min(target, v + accel * dt)
	end
	return math.max(target, v - brake * dt)
end

function Driver.followSpeed(gap: number, limit: number, cfg: any): number
	local free = gap - cfg.MinGap
	if free <= 0 then
		return 0
	end
	return math.min(limit, free / cfg.Headway)
end

function Driver.stopSpeed(dist: number, brake: number): number
	if dist <= 0 then
		return 0
	end
	return math.sqrt(2 * brake * dist)
end

function Driver.light(value: any): string?
	if type(value) == "boolean" then
		return if value then "green" else "red"
	end
	if type(value) ~= "string" then
		return nil
	end
	local s = string.lower(value)
	if string.find(s, "green", 1, true) or s == "g" or s == "go" then
		return "green"
	end
	if string.find(s, "yellow", 1, true) or string.find(s, "amber", 1, true) or s == "y" or s == "a" then
		return "yellow"
	end
	if string.find(s, "red", 1, true) or s == "r" or s == "stop" then
		return "red"
	end
	return nil
end

-- Red: stop. Yellow: stop only if we can do it comfortably. Green / unknown: go.
function Driver.mustStopForLight(state: string?, dist: number, v: number, brake: number): boolean
	if state == "red" then
		return dist > -1
	end
	if state == "yellow" then
		local need = (v * v) / (2 * brake)
		return dist > need + 1
	end
	return false
end

function Driver.relative(px: number, pz: number, hx: number, hz: number, ox: number, oz: number): (number, number)
	local dx, dz = ox - px, oz - pz
	-- right of (hx, hz) is (-hz, hx)
	return dx * hx + dz * hz, dx * -hz + dz * hx
end

-- Gap (bumper to bumper) to another car if it is ahead in our lane and going our way, else nil.
function Driver.leaderGap(
	fwd: number,
	right: number,
	myHx: number,
	myHz: number,
	oHx: number,
	oHz: number,
	halfA: number,
	halfB: number,
	cfg: any
): number?
	if fwd <= 0 or fwd > cfg.LookAhead or math.abs(right) > cfg.LeaderLateral then
		return nil
	end
	if myHx * oHx + myHz * oHz < 0.3 then
		return nil -- crossing or oncoming traffic is not our leader
	end
	return fwd - halfA - halfB
end

-- Gap to a pedestrian / obstacle standing in our path, else nil.
function Driver.pedGap(fwd: number, right: number, half: number, cfg: any): number?
	if fwd <= 0 or fwd > cfg.LookAhead or math.abs(right) > cfg.PedLateral then
		return nil
	end
	return fwd - half - 1.5
end

-- fwd/right: truck position relative to the car (car heading frame).
-- closing: how fast the truck approaches the car (studs/s, + = getting closer).
function Driver.shouldYield(fwd: number, right: number, closing: number, sirenOn: boolean, cfg: any): boolean
	if not sirenOn then
		return false
	end
	local dist = math.sqrt(fwd * fwd + right * right)
	if dist > cfg.YieldRadius then
		return false
	end
	if fwd <= cfg.YieldBehindSlack then
		-- behind us (or alongside): yield unless it is clearly driving away
		return closing > -4 or dist < 30
	end
	-- ahead of us: only an oncoming truck that is close and coming at us
	return dist <= cfg.OncomingRadius and closing > 4
end

-- A driven siren truck crawling right behind the car (slower than YieldMinSpeed): pull over anyway.
function Driver.slowBehind(fwd: number, right: number, cfg: any): boolean
	local behind = tonumber(cfg.SlowYieldBehind) or 0
	return behind > 0 and fwd < 0 and fwd > -behind and math.abs(right) < (tonumber(cfg.SlowYieldLateral) or 7)
end

function Driver.truckPassed(fwd: number, right: number, cfg: any): boolean
	local dist = math.sqrt(fwd * fwd + right * right)
	return fwd > cfg.PassClear or dist > cfg.YieldRadius + 30
end

-- relX/relZ: car centre in the truck's local frame (truck faces -Z). Hit = inside the truck's front
-- half, stretched forward by RamLookahead seconds of travel.
function Driver.rammed(relX: number, relZ: number, truckSpeed: number, cfg: any): boolean
	if truckSpeed < cfg.RamSpeed then
		return false
	end
	if math.abs(relX) > cfg.TruckHalfWidth + cfg.CarRadius then
		return false
	end
	local reach = cfg.TruckFront + cfg.CarRadius + truckSpeed * cfg.RamLookahead
	return relZ <= 2 and relZ >= -reach
end

function Driver.panicWobble(t: number, seed: number): (number, number)
	local w = 7 + (seed % 5)
	local lateral = math.sin(t * w) * 3.2 * math.max(0, 1 - t * 0.35)
	local yaw = math.sin(t * w * 1.3 + seed) * 0.6
	return lateral, yaw
end

function Driver.pickWeighted(weights: { [string]: number }, roll: number): string?
	local keys: { string } = {}
	local total = 0
	for k, w in weights do
		if w > 0 then
			table.insert(keys, k)
			total += w
		end
	end
	if total <= 0 then
		return nil
	end
	table.sort(keys)
	local pick = math.clamp(roll, 0, 0.999999) * total
	for _, k in keys do
		pick -= weights[k]
		if pick < 0 then
			return k
		end
	end
	return keys[#keys]
end

function Driver.turnSpeed(radius: number, limit: number, cfg: any): number
	if radius >= 1e6 then
		return limit
	end
	return math.clamp(math.sqrt(cfg.TurnAccel * radius), cfg.MinTurnSpeed, limit)
end

function Driver.entrySpeed(dist: number, vNext: number, brake: number): number
	return math.sqrt(vNext * vNext + 2 * brake * math.max(dist, 0))
end

-- Passing: I move PassOffset to my left. (fwd, right) = the other car in my heading frame.
-- Oncoming cars in the corridor up to PassLook ahead, or same-direction cars beside me, block it.
function Driver.passClear(fwd: number, right: number, sameDir: boolean, cfg: any): boolean
	local corridor = math.abs(right + cfg.PassOffset) < 6
	if not corridor then
		return true
	end
	if sameDir then
		return fwd < -18 or fwd > 30
	end
	return fwd < -8 or fwd > cfg.PassLook
end

return Driver
