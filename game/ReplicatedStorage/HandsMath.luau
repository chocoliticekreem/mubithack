--!strict
-- HandsMath [owner: Hands agent]. Pure maths for the physics hands (no Roblox APIs, so
-- game/tests/hands.spec.luau runs it under the `luau` CLI). Used by ClientLib/PhysicsHands (poses,
-- springs, axe/slap feel, pose packing) and Services/HandsService (validation of the same numbers).
--
-- Space conventions: poses are wrist frames in CAMERA space (x right, y up, -z forward), angles in
-- degrees (rx pitch, ry yaw, rz roll, applied as CFrame.Angles(rx, ry, rz)). Vectors are plain
-- tables {x, y, z}.

local HandsMath = {}

export type Vec = { x: number, y: number, z: number }
export type Pose = { x: number, y: number, z: number, rx: number, ry: number, rz: number }

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
HandsMath.finite = finite

-- springs ------------------------------------------------------------------------------------
-- Stiffness/damping for a unit-mass spring with natural frequency `hz` and damping ratio `zeta`
-- (zeta < 1 overshoots and wobbles, 1 = critically damped, > 1 sluggish).
function HandsMath.springCoeffs(hz: number, zeta: number): (number, number)
	local w = 2 * math.pi * math.max(hz, 0)
	return w * w, 2 * math.max(zeta, 0) * w
end

-- One scalar spring step (semi-implicit Euler, sub-stepped so big frame times stay stable).
function HandsMath.springStep(x: number, v: number, target: number, k: number, c: number, dt: number): (number, number)
	if dt <= 0 then
		return x, v
	end
	local steps = math.max(1, math.ceil(dt / (1 / 240)))
	local h = dt / steps
	for _ = 1, steps do
		local a = k * (target - x) - c * v
		v += a * h
		x += v * h
	end
	return x, v
end

-- Vector spring: returns new position and velocity tables (inputs are not mutated).
function HandsMath.springStep3(p: Vec, v: Vec, t: Vec, k: number, c: number, dt: number): (Vec, Vec)
	local x, vx = HandsMath.springStep(p.x, v.x, t.x, k, c, dt)
	local y, vy = HandsMath.springStep(p.y, v.y, t.y, k, c, dt)
	local z, vz = HandsMath.springStep(p.z, v.z, t.z, k, c, dt)
	return { x = x, y = y, z = z }, { x = vx, y = vy, z = vz }
end

-- poses --------------------------------------------------------------------------------------
-- Right-hand wrist poses; the left hand mirrors (HandsMath.mirror). Small, low, in the bottom
-- corners so the gloves frame the screen instead of covering it.
HandsMath.Poses = {
	idle = { x = 1.05, y = -1.2, z = -2.05, rx = 8, ry = 6, rz = -6 },
	hose = { x = 0.7, y = -0.95, z = -1.75, rx = 4, ry = 4, rz = 0 },
	hoseSupport = { x = -0.35, y = -1.0, z = -2.6, rx = 4, ry = -8, rz = 60 },
	extinguisher = { x = 0.75, y = -1.15, z = -1.9, rx = 6, ry = 4, rz = -4 },
	axeReady = { x = 0.95, y = -1.05, z = -1.95, rx = 28, ry = 6, rz = -10 },
	axeWindup = { x = 1.25, y = -0.15, z = -0.9, rx = -55, ry = 12, rz = -22 },
	axeStrike = { x = 0.45, y = -1.35, z = -3.1, rx = 85, ry = -6, rz = 4 },
	carry = { x = 1.15, y = -0.6, z = -2.3, rx = 35, ry = -18, rz = -40 },
	item = { x = 0.9, y = -1.05, z = -2.0, rx = 15, ry = 8, rz = -8 },
	lowered = { x = 1.15, y = -1.6, z = -1.7, rx = 5, ry = 10, rz = -6 },
}

function HandsMath.mirror(p: Pose): Pose
	return { x = -p.x, y = p.y, z = p.z, rx = p.rx, ry = -p.ry, rz = -p.rz }
end

-- Pose for a side ("R" | "L"); unknown names fall back to idle.
function HandsMath.pose(name: string, side: string): Pose
	local p = HandsMath.Poses[name] or HandsMath.Poses.idle
	return if side == "L" then HandsMath.mirror(p) else p
end

function HandsMath.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

function HandsMath.blendPose(a: Pose, b: Pose, t: number): Pose
	local l = HandsMath.lerp
	return {
		x = l(a.x, b.x, t),
		y = l(a.y, b.y, t),
		z = l(a.z, b.z, t),
		rx = l(a.rx, b.rx, t),
		ry = l(a.ry, b.ry, t),
		rz = l(a.rz, b.rz, t),
	}
end

-- easeOutBack: overshoots past 1 then settles (the axe "snap" through the strike).
function HandsMath.easeOutBack(t: number, s: number?): number
	local k = s or 1.70158
	t = math.clamp(t, 0, 1) - 1
	return 1 + (k + 1) * t * t * t + k * t * t
end

function HandsMath.smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Reach: how far forward (studs from the camera) a reaching hand goes. A wall closer than the max
-- stops the palm just short of it.
function HandsMath.reachDistance(rayDist: number?, maxReach: number, palmGap: number): number
	local d = if rayDist and finite(rayDist) then rayDist - palmGap else maxReach
	return math.clamp(d, 0.8, maxReach)
end

-- The reach pose: from `rest` toward a camera-space point, `t` 0..1 (eased).
function HandsMath.reachPose(rest: Pose, point: Vec, t: number): Pose
	local e = HandsMath.smoothstep(t)
	return {
		x = HandsMath.lerp(rest.x, point.x, e),
		y = HandsMath.lerp(rest.y, point.y, e),
		z = HandsMath.lerp(rest.z, point.z, e),
		rx = HandsMath.lerp(rest.rx, -5, e),
		ry = rest.ry * (1 - e),
		rz = rest.rz * (1 - e),
	}
end

-- axe ----------------------------------------------------------------------------------------
-- Wind-up charge 0..1 from seconds held (eased so the first bit of hold matters most).
function HandsMath.windupCharge(heldSeconds: number, fullSeconds: number): number
	if fullSeconds <= 0 then
		return 1
	end
	local t = math.clamp(heldSeconds / fullSeconds, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

-- Axe pose: `charge` while holding the button (ready -> windup); after release `strikeT` seconds
-- run windup -> strike (overshooting) -> back to ready. `fromCharge` is the charge at release.
function HandsMath.axePose(charge: number, strikeT: number?, strikeSeconds: number, fromCharge: number?): Pose
	local P = HandsMath.Poses
	if strikeT == nil or strikeT < 0 then
		return HandsMath.blendPose(P.axeReady, P.axeWindup, HandsMath.smoothstep(charge))
	end
	local start = HandsMath.blendPose(P.axeReady, P.axeWindup, HandsMath.smoothstep(fromCharge or 1))
	if strikeT < strikeSeconds then
		return HandsMath.blendPose(start, P.axeStrike, HandsMath.easeOutBack(strikeT / strikeSeconds, 1.2))
	end
	local back = math.clamp((strikeT - strikeSeconds) / (strikeSeconds * 2), 0, 1)
	return HandsMath.blendPose(P.axeStrike, P.axeReady, HandsMath.smoothstep(back))
end

export type AxeCfg = { AxeMinSpeed: number, AxeStrongSpeed: number, AxeCritSpeed: number }

-- Door hits from axe-head speed (studs/s): a lazy tap does nothing, a real swing is 1, a big
-- wound-up swing 2, a perfect one 3 (enough to break a 3-hit door at once).
function HandsMath.axeHits(speed: number, cfg: AxeCfg): number
	if not finite(speed) or speed < cfg.AxeMinSpeed then
		return 0
	elseif speed < cfg.AxeStrongSpeed then
		return 1
	elseif speed < cfg.AxeCritSpeed then
		return 2
	end
	return 3
end

-- slap / push ----------------------------------------------------------------------------------
export type SlapCfg = {
	SlapMinSpeed: number,
	SlapPerSpeed: number,
	SlapMax: number,
	SlapLift: number,
	SlapRagdollSpeed: number,
}

-- Knockback for a slap at relative hand speed (studs/s): (horizontal studs/s, lift studs/s, ragdoll?).
-- Below SlapMinSpeed it's a pat on the back: (0, 0, false).
function HandsMath.slap(speed: number, cfg: SlapCfg): (number, number, boolean)
	if not finite(speed) or speed < cfg.SlapMinSpeed then
		return 0, 0, false
	end
	local push = math.min(cfg.SlapMax, (speed - cfg.SlapMinSpeed) * cfg.SlapPerSpeed + cfg.SlapMax * 0.25)
	local lift = cfg.SlapLift * math.clamp(push / cfg.SlapMax, 0.3, 1)
	return push, lift, speed >= cfg.SlapRagdollSpeed
end

-- Impulse velocity change for a hand shove on a loose prop (studs/s), 0 below the minimum.
function HandsMath.push(speed: number, minSpeed: number, perSpeed: number, maxPush: number): number
	if not finite(speed) or speed < minSpeed then
		return 0
	end
	return math.min(maxPush, speed * perSpeed)
end

-- grab ---------------------------------------------------------------------------------------
export type GrabCfg = { OneHandMaxMass: number, TwoHandMaxMass: number }

-- "ok" (liftable with these hands), "heavy" (grabbable but too heavy to lift with one hand: it
-- drags), or "no" (too heavy for anything).
function HandsMath.grabVerdict(mass: number, hands: number, cfg: GrabCfg): string
	if not finite(mass) or mass < 0 or mass > cfg.TwoHandMaxMass then
		return "no"
	end
	if hands >= 2 or mass <= cfg.OneHandMaxMass then
		return "ok"
	end
	return "heavy"
end

-- Extra AlignPosition force per hand to carry `mass` (shared by `hands`); a "heavy" one-hand grab
-- only gets half of what lifting needs, so the thing drags along the floor.
function HandsMath.liftForce(mass: number, hands: number, gravity: number, cfg: GrabCfg): number
	local verdict = HandsMath.grabVerdict(mass, hands, cfg)
	if verdict == "no" then
		return 0
	end
	local share = mass * gravity / math.max(1, hands)
	return share * (if verdict == "ok" then 1.6 else 0.5)
end

-- held tool feel -----------------------------------------------------------------------------
-- Hose kick: camera-space offset (x, y, z studs) and pitch (degrees) at time t while spraying at
-- `pressure` 0..1. Deterministic sines instead of noise so it is testable; bucks up and back.
function HandsMath.hoseKick(t: number, pressure: number, amount: number): (number, number, number, number)
	local p = math.clamp(pressure, 0, 1) * amount
	local x = (math.sin(t * 23.1) * 0.6 + math.sin(t * 41.7) * 0.4) * 0.12 * p
	local y = (0.5 + 0.5 * math.sin(t * 17.3)) * 0.18 * p
	local z = (0.6 + 0.4 * math.sin(t * 29.9)) * 0.3 * p
	local pitch = (0.5 + 0.5 * math.sin(t * 19.7)) * 9 * p
	return x, y, z, pitch
end

-- Extinguisher sputter: 0..1 burst strength at time t. Full can = a steady hiss with small
-- hiccups; nearly empty = mostly coughs.
function HandsMath.sputter(t: number, fill: number): number
	local f = math.clamp(fill, 0, 1)
	local wave = 0.5 + 0.5 * math.sin(t * 13.0) * math.sin(t * 5.3 + 1.1)
	local threshold = 0.25 + 0.6 * (1 - f)
	return if wave > threshold then (wave - threshold) / (1 - threshold) else 0
end

-- replication --------------------------------------------------------------------------------
-- Pose packet: {lx, ly, lz, rx, ry, rz, flags}, hand positions relative to the HumanoidRootPart in
-- studs, quantized to 0.05 and clamped to +-maxOffset. Flags: bit 0 left grip, 1 right grip,
-- 2 axe wind-up, 3 reaching.
HandsMath.Flag = table.freeze({ LeftGrip = 1, RightGrip = 2, Windup = 4, Reach = 8 })
HandsMath.PacketSize = 7

local function q(n: number, maxOffset: number): number
	return math.round(math.clamp(n, -maxOffset, maxOffset) * 20) / 20
end

function HandsMath.encodePose(l: Vec, r: Vec, flags: number, maxOffset: number): { number }
	return {
		q(l.x, maxOffset),
		q(l.y, maxOffset),
		q(l.z, maxOffset),
		q(r.x, maxOffset),
		q(r.y, maxOffset),
		q(r.z, maxOffset),
		math.clamp(math.floor(flags), 0, 255),
	}
end

-- Validates an untrusted packet. Returns (left, right, flags) or nil.
function HandsMath.decodePose(raw: any, maxOffset: number): (Vec?, Vec?, number)
	if type(raw) ~= "table" or #raw ~= HandsMath.PacketSize then
		return nil, nil, 0
	end
	for i = 1, HandsMath.PacketSize do
		if not finite(raw[i]) then
			return nil, nil, 0
		end
	end
	local l = { x = q(raw[1], maxOffset), y = q(raw[2], maxOffset), z = q(raw[3], maxOffset) }
	local r = { x = q(raw[4], maxOffset), y = q(raw[5], maxOffset), z = q(raw[6], maxOffset) }
	return l, r, math.clamp(math.floor(raw[7]), 0, 255)
end

function HandsMath.hasFlag(flags: number, flag: number): boolean
	return math.floor(flags / flag) % 2 == 1
end

-- Axis (unit) and angle (radians) of the shortest rotation taking direction a onto direction b.
-- Used to aim a remote player's shoulder joint at their replicated hand.
function HandsMath.rotationBetween(a: Vec, b: Vec): (Vec, number)
	local la = math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z)
	local lb = math.sqrt(b.x * b.x + b.y * b.y + b.z * b.z)
	if la < 1e-6 or lb < 1e-6 then
		return { x = 1, y = 0, z = 0 }, 0
	end
	local ax, ay, az = a.x / la, a.y / la, a.z / la
	local bx, by, bz = b.x / lb, b.y / lb, b.z / lb
	local dot = math.clamp(ax * bx + ay * by + az * bz, -1, 1)
	local cx, cy, cz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
	local cl = math.sqrt(cx * cx + cy * cy + cz * cz)
	if cl < 1e-6 then
		if dot > 0 then
			return { x = 1, y = 0, z = 0 }, 0
		end
		-- opposite: any axis perpendicular to a
		local px, py, pz = if math.abs(ax) < 0.9 then 1 else 0, if math.abs(ax) < 0.9 then 0 else 1, 0
		local ux, uy, uz = ay * pz - az * py, az * px - ax * pz, ax * py - ay * px
		local ul = math.sqrt(ux * ux + uy * uy + uz * uz)
		return { x = ux / ul, y = uy / ul, z = uz / ul }, math.pi
	end
	return { x = cx / cl, y = cy / cl, z = cz / cl }, math.acos(dot)
end

-- Hand stuck behind a wall (or left behind by a teleport): snap it back after a while, or at once
-- when it is absurdly far.
function HandsMath.shouldSnap(dist: number, stuckFor: number, snapDistance: number, snapAfter: number): boolean
	return dist > snapDistance * 3 or (dist > snapDistance and stuckFor >= snapAfter)
end

return HandsMath
