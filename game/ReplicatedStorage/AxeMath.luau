--!strict
-- AxeMath [owner: Hands agent / axe]. Pure maths for the ONE physical axe (no Roblox APIs, so
-- game/tests/axe.spec.luau runs it under the `luau` CLI). Used by ClientLib/AxeArm (swing state,
-- arm IK, arm packets) and Services/HandsService (packet validation).
--
-- The axe is the real Tool: its Handle is welded to the R15 RightHand, its metal Head hangs on a
-- BallSocketConstraint at the top of the handle and is simulated by the holder. The holder's arm is
-- posed by Motor6D transforms from a GRIP pose: the RightGripAttachment frame in AIM space
-- (origin at the character's head, root yaw, camera pitch; x right, y up, -z forward; angles in
-- degrees applied as CFrame.Angles(rx, ry, rz)). The same pose drives the arm on every client, so
-- first and third person show the same arm, and the head flop is the holder's physics, replicated.

local AxeMath = {}

export type Vec = { x: number, y: number, z: number }
export type Pose = { x: number, y: number, z: number, rx: number, ry: number, rz: number }
export type Swing = {
	windStart: number?, -- clock when the button went down (nil = not winding)
	strikeT: number, -- seconds since release, -1 = not striking
	from: number, -- wind-up charge at release (0..1)
}
export type Poses = { Ready: Pose, Windup: Pose, Strike: Pose }
export type SwingCfg = {
	WindupSeconds: number,
	StrikeSeconds: number,
	RecoverSeconds: number,
	MinCharge: number,
}

local function finite(n: any): boolean
	return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end
AxeMath.finite = finite

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function AxeMath.blend(a: Pose, b: Pose, t: number): Pose
	return {
		x = lerp(a.x, b.x, t),
		y = lerp(a.y, b.y, t),
		z = lerp(a.z, b.z, t),
		rx = lerp(a.rx, b.rx, t),
		ry = lerp(a.ry, b.ry, t),
		rz = lerp(a.rz, b.rz, t),
	}
end

-- swing state ------------------------------------------------------------------------------------
function AxeMath.newSwing(): Swing
	return { windStart = nil, strikeT = -1, from = 0 }
end

-- Wind-up charge 0..1 for seconds held (eased out: the first bit of hold matters most).
function AxeMath.charge(held: number, full: number): number
	if full <= 0 then
		return 1
	end
	local t = math.clamp(held / full, 0, 1)
	return 1 - (1 - t) * (1 - t)
end

-- Button down: start winding unless the chop itself is still running (recovering is fine).
function AxeMath.press(s: Swing, now: number, cfg: SwingCfg): boolean
	if s.strikeT >= 0 and s.strikeT < cfg.StrikeSeconds then
		return false
	end
	s.windStart = now
	return true
end

-- Button up: release the chop. Returns the charge it was released with (nil if not winding). A tap
-- still chops, with at least MinCharge.
function AxeMath.release(s: Swing, now: number, cfg: SwingCfg): number?
	local start = s.windStart
	if not start then
		return nil
	end
	s.windStart = nil
	s.from = math.max(cfg.MinCharge, AxeMath.charge(now - start, cfg.WindupSeconds))
	s.strikeT = 0
	return s.from
end

-- Advance the chop timer; returns the phase: "ready" | "windup" | "strike" | "recover".
function AxeMath.step(s: Swing, dt: number, cfg: SwingCfg): string
	if s.strikeT >= 0 then
		s.strikeT += math.max(dt, 0)
		if s.strikeT >= cfg.StrikeSeconds + cfg.RecoverSeconds then
			s.strikeT = -1
		end
	end
	if s.windStart then
		return "windup"
	elseif s.strikeT >= 0 then
		return if s.strikeT < cfg.StrikeSeconds then "strike" else "recover"
	end
	return "ready"
end

-- The grip pose the arm aims for right now. Strike: wind-up -> strike with a little overshoot
-- (easeOutBack), then back to ready.
function AxeMath.pose(s: Swing, now: number, poses: Poses, cfg: SwingCfg): Pose
	if s.windStart then
		local c = AxeMath.charge(now - s.windStart, cfg.WindupSeconds)
		return AxeMath.blend(poses.Ready, poses.Windup, smoothstep(c))
	end
	if s.strikeT < 0 then
		return poses.Ready
	end
	local start = AxeMath.blend(poses.Ready, poses.Windup, smoothstep(s.from))
	if s.strikeT < cfg.StrikeSeconds then
		local t = math.clamp(s.strikeT / cfg.StrikeSeconds, 0, 1)
		local k = 1.4
		local u = t - 1
		local e = 1 + (k + 1) * u * u * u + k * u * u -- easeOutBack
		return AxeMath.blend(start, poses.Strike, e)
	end
	local back = (s.strikeT - cfg.StrikeSeconds) / math.max(cfg.RecoverSeconds, 1e-3)
	return AxeMath.blend(poses.Strike, poses.Ready, smoothstep(back))
end

-- Running bob added to the grip (studs): a bounce at the footstep rate, scaled by speed 0..1.
function AxeMath.runBob(phase: number, speed01: number, amount: number): (number, number)
	local s = math.clamp(speed01, 0, 1.3) * amount
	return math.cos(phase) * 0.5 * s, -math.abs(math.sin(phase)) * s
end

-- arm IK ---------------------------------------------------------------------------------------
local function sub(a: Vec, b: Vec): Vec
	return { x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }
end
local function add(a: Vec, b: Vec): Vec
	return { x = a.x + b.x, y = a.y + b.y, z = a.z + b.z }
end
local function mul(a: Vec, k: number): Vec
	return { x = a.x * k, y = a.y * k, z = a.z * k }
end
local function dot(a: Vec, b: Vec): number
	return a.x * b.x + a.y * b.y + a.z * b.z
end
local function len(a: Vec): number
	return math.sqrt(dot(a, a))
end
AxeMath.len = len

-- Two-bone IK. Shoulder `s`, wanted wrist `w`, bone lengths `a` (upper) and `b` (lower), `pole` a
-- direction the elbow bends toward. Returns (elbow, wrist): the wrist is pulled in when the target is
-- out of reach (or pushed out when too close), so both bones always keep their lengths.
function AxeMath.solveElbow(s: Vec, w: Vec, a: number, b: number, pole: Vec): (Vec, Vec)
	local d = sub(w, s)
	local dist = len(d)
	local maxR = (a + b) * 0.999
	local minR = math.max(math.abs(a - b) * 1.001, 1e-3)
	local dir: Vec
	if dist < 1e-6 then
		dir = { x = 0, y = -1, z = 0 }
	else
		dir = mul(d, 1 / dist)
	end
	local r = math.clamp(dist, minR, maxR)
	local wrist = add(s, mul(dir, r))
	-- law of cosines: distance along dir to the elbow's foot, and the elbow's height off the line
	local x = (a * a - b * b + r * r) / (2 * r)
	local h = math.sqrt(math.max(a * a - x * x, 0))
	-- the pole, made perpendicular to dir
	local p = sub(pole, mul(dir, dot(pole, dir)))
	local pl = len(p)
	if pl < 1e-6 then
		-- pole along the arm: pick any perpendicular
		local alt = if math.abs(dir.y) < 0.9 then { x = 0, y = -1, z = 0 } else { x = 1, y = 0, z = 0 }
		p = sub(alt, mul(dir, dot(alt, dir)))
		pl = len(p)
	end
	p = mul(p, 1 / pl)
	local elbow = add(add(s, mul(dir, x)), mul(p, h))
	return elbow, wrist
end

-- replication --------------------------------------------------------------------------------------
-- Arm packet: {x, y, z, rx, ry, rz, pitch, flags}: the sprung grip pose (studs, 0.02 steps, +-MaxPos)
-- and angles (degrees, whole, +-180; pitch +-80), flags bit 0 winding, bit 1 striking.
AxeMath.PacketSize = 8
AxeMath.MaxPos = 4
AxeMath.Flag = table.freeze({ Windup = 1, Strike = 2 })

local function qp(n: number): number
	return math.round(math.clamp(n, -AxeMath.MaxPos, AxeMath.MaxPos) * 50) / 50
end
local function qa(n: number, lim: number): number
	return math.round(math.clamp(n, -lim, lim))
end

function AxeMath.encode(p: Pose, pitch: number, flags: number): { number }
	return {
		qp(p.x),
		qp(p.y),
		qp(p.z),
		qa(p.rx, 180),
		qa(p.ry, 180),
		qa(p.rz, 180),
		qa(pitch, 80),
		math.clamp(math.floor(flags), 0, 3),
	}
end

-- Validates an untrusted packet: (pose, pitch, flags) or nil.
function AxeMath.decode(raw: any): (Pose?, number, number)
	if type(raw) ~= "table" or #raw ~= AxeMath.PacketSize then
		return nil, 0, 0
	end
	for i = 1, AxeMath.PacketSize do
		if not finite(raw[i]) then
			return nil, 0, 0
		end
	end
	return {
		x = qp(raw[1]),
		y = qp(raw[2]),
		z = qp(raw[3]),
		rx = qa(raw[4], 180),
		ry = qa(raw[5], 180),
		rz = qa(raw[6], 180),
	},
		qa(raw[7], 80),
		math.clamp(math.floor(raw[8]), 0, 3)
end

-- Shortest signed difference between two angles in degrees (for smoothing replicated angles).
function AxeMath.angleDelta(from: number, to: number): number
	local d = (to - from) % 360
	if d > 180 then
		d -= 360
	end
	return d
end

-- server check: is a point within `slack` studs of a box (centre-relative point, half sizes)?
function AxeMath.nearBox(local_: Vec, half: Vec, slack: number): boolean
	local dx = math.max(math.abs(local_.x) - half.x, 0)
	local dy = math.max(math.abs(local_.y) - half.y, 0)
	local dz = math.max(math.abs(local_.z) - half.z, 0)
	return dx * dx + dy * dy + dz * dz <= slack * slack
end

return AxeMath
