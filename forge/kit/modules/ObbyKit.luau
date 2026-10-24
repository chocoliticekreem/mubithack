--!nonstrict
-- ObbyKit: prebuilt by Forge (forge/kit/modules/ObbyKit.luau). Do not rewrite it; require it.
-- A server-authoritative obby engine: checkpoints (Stage leaderstat, saved, respawn there), kill parts,
-- ten obstacle kinds driven by ONE Heartbeat loop, and LevelBuilder, which builds stages from level data
-- (ReplicatedStorage/Levels/ZoneNN.luau, written by `forge levels`) and checks every jump with the same
-- rules as forge/obby.py. Everything is tagged (CollectionService) and attributed so checks can find it.
-- v2: the course lives in the world. Each zone can start at its own anchor (WorldKit.buildPark), stages turn
-- on their start pads, the last checkpoint of a zone has a ride gate (touch pad + prompt) to the next zone's
-- start, and an optional themes module (ObbyThemes) dresses every piece and stage without touching collision.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ObbyKit = {}
ObbyKit.VERSION = 2

-- ============================================================== rules (mirror forge/obby.py)

local R = {
	GRAVITY = 196.2,
	WALK_SPEED = 16,
	JUMP_HEIGHT = 7.2,
	EDGE_SLACK = 1.3,
	MAX_RISE = 6,
	RISE_MARGIN = 1.2,
	MIN_RISE = -20,
	MAX_GAP = 12,
	MAX_LAUNCH_GAP = 20,
	LAUNCH_HOLD = 0.12,
	PAD_SIZE = 10,
	PAD_THICK = 1,
	MAX_SIDE = 16,
	MAX_STAGE_LENGTH = 200,
	MIN_PIECES = 2,
	MAX_PIECES = 11,
	SAMPLE_DT = 0.1,
	SAMPLES = 240,
	MIN_RUN = 3,
	HOP_TIME = 0.6,
	CRUSH_HEIGHT = 5,
	BALL_CLEARANCE = 3,
	MAX_TURN = 90,
	LOG_MAX_DIAMETER = 8,
	LOG_STRIP = 0.5,
	RAMP_MAX_CLIMB = 8,
}
R.JUMP_SPEED = math.sqrt(2 * R.GRAVITY * R.JUMP_HEIGHT)
R.LOG_DROP = 1 - math.sqrt(3) / 2
ObbyKit.Rules = R

local P = R.PAD_SIZE
-- name, default, min, max (numbers); name, default, {choices} (strings); name, {x, y, z}, min, max (vectors)
local COMMON = {
	{ "gap", 6, 0, 30 },
	{ "rise", 0, R.MIN_RISE, 20 },
	{ "side", 0, -R.MAX_SIDE, R.MAX_SIDE },
	{ "coins", 0, 0, 3 },
}
local KIND_NAMES = {
	"platform", "checkpoint", "moving", "spinner", "turntable", "disappearing", "jumppad", "trampoline", "conveyor",
	"pendulum", "lava",
}
local KINDS = {
	platform = {
		size = { 8, 1, 8 }, min = { 2, 0.5, 2 }, max = { 40, 4, 40 },
		params = { { "shape", "block", { "block", "round", "cylinder", "wedge-ramp" } } },
	},
	checkpoint = { size = { P, R.PAD_THICK, P }, min = { P, R.PAD_THICK, P }, max = { P, R.PAD_THICK, P }, params = {} },
	moving = {
		size = { 7, 1, 7 }, min = { 5, 0.5, 5 }, max = { 16, 2, 16 },
		params = { { "move", { 0, 0, 8 }, -20, 20 }, { "period", 4, 2, 12 }, { "phase", 0, 0, 1 } },
	},
	spinner = {
		round = true, size = { 14, 1, 14 }, min = { 10, 0.5, 10 }, max = { 20, 2, 20 },
		params = { { "speed", 90, 30, 180 }, { "bar_height", 2, 1, 3 } },
	},
	turntable = { round = true, size = { 12, 1, 12 }, min = { 8, 0.5, 8 }, max = { 20, 2, 20 }, params = { { "speed", 45, 15, 120 } } },
	disappearing = {
		size = { 5, 1, 5 }, min = { 4, 0.5, 4 }, max = { 10, 2, 10 },
		params = { { "count", 3, 2, 6 }, { "spacing", 3, 0, 10 }, { "on", 2.5, 1.5, 6 }, { "off", 1.5, 0.5, 3 }, { "stagger", 0.6, 0, 2 } },
	},
	jumppad = { size = { 6, 1, 6 }, min = { 4, 0.5, 4 }, max = { 10, 2, 10 }, params = { { "power", 90, 60, 130 }, { "forward", 20, 0, 40 } } },
	trampoline = { size = { 8, 1, 8 }, min = { 5, 0.5, 5 }, max = { 12, 2, 12 }, params = { { "bounce", 70, 50, 110 } } },
	conveyor = {
		size = { 6, 1, 16 }, min = { 4, 0.5, 8 }, max = { 12, 2, 30 },
		params = { { "speed", 8, 2, 12 }, { "dir", "forward", { "forward", "back", "left", "right" } } },
	},
	pendulum = {
		size = { 6, 1, 14 }, min = { 4, 0.5, 10 }, max = { 10, 2, 24 },
		params = { { "swing", 60, 20, 75 }, { "period", 3, 2, 6 }, { "length", 10, 6, 16 }, { "phase", 0, 0, 1 } },
	},
	lava = { standable = false, size = { 8, 1, 4 }, min = { 2, 0.5, 1 }, max = { 30, 2, 8 }, params = {} },
}
ObbyKit.Kinds = KINDS
ObbyKit.KindNames = KIND_NAMES
ObbyKit.Common = COMMON

-- ============================================================== level data: normalize, layout, validate

local function num(v: any, default: number): number
	local x = tonumber(v)
	if x == nil or x ~= x or x == math.huge or x == -math.huge then
		return default
	end
	return x
end

local function trunc(x: number): number
	return if x >= 0 then math.floor(x) else math.ceil(x)
end

local function strip(s: string): string
	return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end

local function f1(x: number): string
	return string.format("%.1f", x)
end

local function g(x: number): string
	return string.format("%g", x)
end

local function rangeText(lo: number, hi: number): string
	return "[" .. g(lo) .. ", " .. g(hi) .. "]"
end

local function normalizePiece(raw: any): { [string]: any }
	raw = if type(raw) == "table" then raw else {}
	local kind = string.lower(strip(tostring(raw.kind or "")))
	local spec = KINDS[kind]
	local out: { [string]: any } = { kind = kind }
	for _, c in COMMON do
		if not (c[1] == "coins" and spec and spec.standable == false) then
			out[c[1]] = num(raw[c[1]], c[2])
		end
	end
	if not spec then
		return out
	end
	if kind ~= "checkpoint" then
		local size = if type(raw.size) == "table" then raw.size else {}
		out.size = { num(size[1], spec.size[1]), num(size[2], spec.size[2]), num(size[3], spec.size[3]) }
	end
	for _, p in spec.params do
		local name, d = p[1], p[2]
		if type(p[3]) == "table" then
			local v = raw[name]
			out[name] = string.lower(strip(tostring(if v ~= nil then v else d)))
		elseif type(d) == "table" then
			local v = if type(raw[name]) == "table" then raw[name] else {}
			out[name] = { num(v[1], d[1]), num(v[2], d[2]), num(v[3], d[3]) }
		else
			out[name] = num(raw[name], d)
		end
	end
	if spec.round or out.shape == "round" then
		out.size[3] = out.size[1]
	elseif out.shape == "cylinder" then
		out.size[2] = out.size[3]
	end
	return out
end

local function normalizeStage(raw: any, number: number): { [string]: any }
	raw = if type(raw) == "table" then raw else {}
	local out: { [string]: any } = {
		stage = trunc(num(raw.stage, number)),
		name = string.sub(strip(tostring(raw.name or "")), 1, 60),
		turn = num(raw.turn, 0),
		pieces = {},
	}
	if raw.fallback == true then
		out.fallback = true
	end
	for _, p in (if type(raw.pieces) == "table" then raw.pieces else {}) do
		table.insert(out.pieces, normalizePiece(p))
	end
	return out
end

-- landDrop / offDrop: where a jump lands on / leaves this surface sits that far under `top` (a ramp's low edge,
-- a log's strip); h: body thickness under `top`; bw, bl: body footprint when wider than the standable one.
local function newSurface(piece, kind, x, z, top, w, l, rnd, standable)
	return {
		piece = piece, kind = kind, x = x, z = z, top = top, w = w, l = l, round = rnd, standable = standable,
		tile = -1, move = nil, period = 0, phase = 0, launch = R.JUMP_SPEED, walk = R.WALK_SPEED, launched = false,
		landDrop = 0, offDrop = 0, h = 0, bw = w, bl = l,
	}
end

-- The pad a stage starts on, in the stage's (turned) frame: a turn that is not a multiple of 90 judges jumps from
-- the pad's inscribed disc and movers against its rotated bounding box.
local function padSurface(turn: number)
	local s = newSurface(0, "pad", 0, 0, 0, P, P, false, true)
	s.h = R.PAD_THICK
	if math.abs(turn) % 90 >= 1e-9 then
		local a = math.rad(turn)
		local box = P * (math.abs(math.cos(a)) + math.abs(math.sin(a)))
		s.round, s.bw, s.bl = true, box, box
	end
	return s
end

-- {min, max} per size axis (width, height, length); false = not checked (a log's height is its diameter).
local function sizeLimits(p)
	local spec = KINDS[p.kind]
	local lim = { { spec.min[1], spec.max[1] }, { spec.min[2], spec.max[2] }, { spec.min[3], spec.max[3] } }
	if p.shape == "cylinder" then
		lim[2], lim[3] = false, { spec.min[3], R.LOG_MAX_DIAMETER }
	elseif p.shape == "wedge-ramp" then
		lim[2] = { spec.min[2], R.RAMP_MAX_CLIMB }
	end
	return lim
end

local function label(s): string
	if s.piece == 0 then
		return "the start pad"
	end
	if s.tile >= 0 then
		return string.format("piece %d (%s tile %d)", s.piece, s.kind, s.tile + 1)
	end
	return string.format("piece %d (%s)", s.piece, s.kind)
end

local function at(s, t: number): (number, number, number)
	if not s.move then
		return s.x, s.top, s.z
	end
	local f = (1 - math.cos(2 * math.pi * (t / s.period + s.phase))) / 2
	return s.x + s.move[1] * f, s.top + s.move[2] * f, s.z + s.move[3] * f
end

local function launchSpeed(v: number): number
	return math.sqrt(v * v + 2 * R.GRAVITY * v * R.LAUNCH_HOLD)
end

local function problem(stage, piece, code, text)
	return { stage = stage, piece = piece, code = code, text = "stage " .. tostring(stage) .. " " .. text }
end

-- Under a turn that is not a multiple of 90 the start pad's corners reach past P / 2: a still piece whose body is level
-- with the pad must not start inside it (separating axes: the stage's x/z, then the pad's own).
local function padOverlaps(n, surfaces, turn, out)
	local a = math.rad(turn)
	local c, s = math.cos(a), math.sin(a)
	local half = P / 2
	local reach = half * (math.abs(c) + math.abs(s))
	local seen = {}
	for k = 2, #surfaces do
		local sf = surfaces[k]
		if sf.move ~= nil or seen[sf.piece] or not (sf.top - sf.h < 0 and sf.top > -R.PAD_THICK) then
			continue
		end
		local hx, hz = sf.bw / 2, sf.bl / 2
		if math.abs(sf.x) >= reach + hx or math.abs(sf.z) >= reach + hz then
			continue
		end
		if math.abs(sf.x * c + sf.z * s) >= half + hx * math.abs(c) + hz * math.abs(s) then
			continue
		end
		if math.abs(-sf.x * s + sf.z * c) >= half + hx * math.abs(s) + hz * math.abs(c) then
			continue
		end
		seen[sf.piece] = true
		table.insert(out, problem(n, sf.piece, "param", string.format(
			"%s overlaps the start pad, whose corners reach %s studs forward after the turn of %s: start it further out",
			label(sf), f1(reach), g(turn))))
	end
end

local function tileTiming(n, i, p, out)
	local on, stagger = p.on, p.stagger
	local cycle = on + p.off
	local land, close = 0, on
	for j = 1, trunc(p.count) - 1 do
		local t = land + R.HOP_TIME
		local start = j * stagger + math.floor((t - j * stagger) / cycle) * cycle
		local e
		if t < start + on then
			land, e = t, start + on
		else
			land, e = start + cycle, start + cycle + on
		end
		if land - R.HOP_TIME > close then
			table.insert(out, problem(n, i, "tiles", string.format(
				"piece %d (disappearing): tile %d is not solid in time to hop onto it from tile %d (on %s, off %s, stagger %s)",
				i, j + 1, j, g(on), g(p.off), g(stagger))))
			return
		end
		close = e
	end
end

local function checkParams(n, i, p, out)
	local kind = p.kind
	local spec = KINDS[kind]
	local where = string.format("piece %d (%s):", i, kind)
	for _, c in COMMON do
		local v = p[c[1]]
		if v ~= nil and not (c[3] <= v and v <= c[4]) then
			table.insert(out, problem(n, i, "param", where .. " " .. c[1] .. " " .. g(v) .. " out of range " .. rangeText(c[3], c[4])))
		end
	end
	if kind ~= "checkpoint" then
		local lims = sizeLimits(p)
		for axis, name in { "width", "height", "length" } do
			local v, lim = p.size[axis], lims[axis]
			if lim and not (lim[1] <= v and v <= lim[2]) then
				table.insert(out, problem(n, i, "param", where .. " size " .. name .. " " .. g(v) .. " out of range " .. rangeText(lim[1], lim[2])))
			end
		end
	end
	if p.shape == "wedge-ramp" and p.size[2] > p.size[3] then
		table.insert(out, problem(n, i, "param", where .. " wedge-ramp climbs " .. g(p.size[2]) .. " over length " .. g(p.size[3])
			.. "; keep its height at most its length (45 degrees)"))
	end
	for _, d in spec.params do
		local name = d[1]
		if type(d[3]) == "table" then
			if not table.find(d[3], p[name]) then
				table.insert(out, problem(n, i, "param", where .. " " .. name .. " '" .. tostring(p[name]) .. "' must be one of "
					.. table.concat(d[3], ", ")))
			end
		elseif type(d[2]) == "table" then
			for axis, v in p[name] do
				if not (d[3] <= v and v <= d[4]) then
					table.insert(out, problem(n, i, "param", where .. " " .. name .. "[" .. axis .. "] " .. g(v) .. " out of range "
						.. rangeText(d[3], d[4])))
				end
			end
		elseif not (d[3] <= p[name] and p[name] <= d[4]) then
			table.insert(out, problem(n, i, "param", where .. " " .. name .. " " .. g(p[name]) .. " out of range " .. rangeText(d[3], d[4])))
		end
	end
	if kind == "moving" then
		local m = p.move
		if math.sqrt(m[1] * m[1] + m[2] * m[2] + m[3] * m[3]) < 2 then
			table.insert(out, problem(n, i, "param", where .. " move must be at least 2 studs long"))
		end
	elseif kind == "pendulum" then
		local reach = p.length * math.sin(math.rad(p.swing))
		local need = p.size[1] / 2 + R.BALL_CLEARANCE
		if reach < need then
			table.insert(out, problem(n, i, "pendulum", where .. " the ball never clears the bridge (length*sin(swing) "
				.. f1(reach) .. " < " .. f1(need) .. ")"))
		end
	elseif kind == "disappearing" then
		tileTiming(n, i, p, out)
	end
end

-- Surfaces of a normalized stage in course order (the start pad first) and its structure/param problems.
local function layout(stage)
	local n = trunc(num(stage.stage, 0))
	local pieces = stage.pieces or {}
	local problems = {}
	if not (R.MIN_PIECES <= #pieces and #pieces <= R.MAX_PIECES) then
		table.insert(problems, problem(n, 0, "structure", string.format("has %d pieces; use %d to %d (the checkpoint included)",
			#pieces, R.MIN_PIECES, R.MAX_PIECES)))
	end
	local turn = num(stage.turn, 0)
	if not (-R.MAX_TURN <= turn and turn <= R.MAX_TURN) then
		table.insert(problems, problem(n, 0, "param", "turn " .. g(turn) .. " out of range " .. rangeText(-R.MAX_TURN, R.MAX_TURN)))
	end
	local surfaces = { padSurface(turn) }
	local cursorZ, cursorTop = P / 2, 0
	local checkpoints = 0
	for i, p in pieces do
		local kind = p.kind
		local spec = KINDS[kind]
		if not spec then
			table.insert(problems, problem(n, i, "param", string.format("piece %d: unknown kind '%s' (kinds: %s)", i, tostring(kind),
				table.concat(KIND_NAMES, ", "))))
			continue
		end
		checkParams(n, i, p, problems)
		local w, l
		if kind == "checkpoint" then
			checkpoints += 1
			w, l = P, P
		else
			w, l = p.size[1], p.size[3]
		end
		local rnd = spec.round == true or p.shape == "round"
		local standable = spec.standable ~= false
		local top = cursorTop + p.rise
		local near = cursorZ + p.gap
		local function shaped(s)
			s.h = if kind == "checkpoint" then R.PAD_THICK else p.size[2]
			if p.shape == "cylinder" then
				s.l, s.bl = l * R.LOG_STRIP, l
				s.landDrop, s.offDrop = l / 2 * R.LOG_DROP, l / 2 * R.LOG_DROP
			elseif p.shape == "wedge-ramp" then
				s.landDrop = p.size[2]
			end
			return s
		end
		if kind == "disappearing" then
			for j = 0, trunc(p.count) - 1 do
				local s = shaped(newSurface(i, kind, p.side, near + l / 2, top, w, l, rnd, standable))
				s.tile = j
				table.insert(surfaces, s)
				near = near + l + p.spacing
			end
			cursorZ = near - p.spacing
		else
			local s = shaped(newSurface(i, kind, p.side, near + l / 2, top, w, l, rnd, standable))
			if kind == "moving" then
				s.move, s.period, s.phase = { p.move[1], p.move[2], p.move[3] }, p.period, p.phase
			elseif kind == "jumppad" then
				s.launch, s.launched = math.max(R.JUMP_SPEED, launchSpeed(p.power)), true
			elseif kind == "trampoline" then
				s.launch, s.launched = math.max(R.JUMP_SPEED, launchSpeed(p.bounce)), true
			elseif kind == "conveyor" and p.dir == "back" then
				s.walk = R.WALK_SPEED - p.speed
			end
			table.insert(surfaces, s)
			cursorZ = near + l
		end
		cursorTop = top
	end
	if #pieces == 0 or pieces[#pieces].kind ~= "checkpoint" then
		table.insert(problems, problem(n, #pieces, "structure", "must end with a checkpoint piece"))
	end
	if checkpoints > 1 then
		table.insert(problems, problem(n, 0, "structure", string.format("has %d checkpoints; only the last piece may be one", checkpoints)))
	end
	if cursorZ > R.MAX_STAGE_LENGTH then
		table.insert(problems, problem(n, 0, "length", "is " .. f1(cursorZ) .. " studs long; keep it under " .. g(R.MAX_STAGE_LENGTH)))
	end
	if math.abs(turn) % 90 >= 1e-9 then
		padOverlaps(n, surfaces, turn, problems)
	end
	return surfaces, problems
end

local function footprintGap(a, ax, az, b, bx, bz): number
	local dx = math.abs(ax - bx)
	local dz = math.abs(az - bz)
	if a.round and b.round then
		return math.max(0, math.sqrt(dx * dx + dz * dz) - a.w / 2 - b.w / 2)
	end
	if a.round or b.round then
		local c, r = a, b
		if not a.round then
			c, r = b, a
		end
		local ex = math.max(0, dx - r.w / 2)
		local ez = math.max(0, dz - r.l / 2)
		return math.max(0, math.sqrt(ex * ex + ez * ez) - c.w / 2)
	end
	local ex = math.max(0, dx - (a.w + b.w) / 2)
	local ez = math.max(0, dz - (a.l + b.l) / 2)
	return math.sqrt(ex * ex + ez * ez)
end

local function maxRise(a): number
	if not a.launched then
		return R.MAX_RISE
	end
	return a.launch * a.launch / (2 * R.GRAVITY) - R.RISE_MARGIN
end

local function reach(a, rise: number): number?
	if rise > maxRise(a) then
		return nil
	end
	local v = a.launch
	local disc = v * v - 2 * R.GRAVITY * rise
	if disc < 0 then
		return nil
	end
	local t = (v + math.sqrt(disc)) / R.GRAVITY
	return math.min(if a.launched then R.MAX_LAUNCH_GAP else R.MAX_GAP, math.max(0, a.walk) * t + R.EDGE_SLACK)
end

local function jumpAt(a, b, t)
	local ax, ay, az = at(a, t)
	local bx, by, bz = at(b, t)
	local gap = footprintGap(a, ax, az, b, bx, bz)
	local rise = (by - b.landDrop) - (ay - a.offDrop)
	local lim = if rise >= R.MIN_RISE then reach(a, rise) else nil
	return lim ~= nil and gap <= lim, gap, rise, lim
end

local function why(a, gap, rise, lim, sep): string
	if rise < R.MIN_RISE then
		return "drop " .. f1(-rise) .. " > max " .. f1(-R.MIN_RISE)
	end
	if lim == nil then
		return "rise " .. f1(rise) .. " > max " .. f1(maxRise(a))
	end
	return "gap " .. f1(gap) .. " at rise " .. f1(rise) .. sep .. "max " .. f1(lim)
end

local function jumpProblem(n, a, b)
	local head = "jump from " .. label(a) .. " to " .. label(b) .. ":"
	if a.move == nil and b.move == nil then
		local ok, gap, rise, lim = jumpAt(a, b, 0)
		if ok then
			return nil
		end
		return problem(n, b.piece, if lim ~= nil then "jump" else "rise", head .. " " .. why(a, gap, rise, lim, " > "))
	end
	local run, bestRun = 0, 0
	local best
	for k = 0, R.SAMPLES - 1 do
		local ok, gap, rise, lim = jumpAt(a, b, k * R.SAMPLE_DT)
		run = if ok then run + 1 else 0
		bestRun = math.max(bestRun, run)
		local excess = if lim ~= nil then gap - lim else 1000 + math.abs(rise)
		if best == nil or excess < best[1] then
			best = { excess, gap, rise, lim }
		end
	end
	if bestRun >= R.MIN_RUN then
		return nil
	end
	return problem(n, b.piece, "jump", head .. " never in reach for " .. f1(R.MIN_RUN * R.SAMPLE_DT) .. "s (closest: "
		.. why(a, best[2], best[3], best[4], ", ") .. ")")
end

local function crushProblems(n, surfaces, out)
	for _, m in surfaces do
		if m.move == nil then
			continue
		end
		for _, o in surfaces do
			if o == m or not o.standable then
				continue
			end
			for k = 0, R.SAMPLES - 1, 2 do
				local mx, my, mz = at(m, k * R.SAMPLE_DT)
				local ox, oy, oz = at(o, k * R.SAMPLE_DT)
				local dx = math.abs(mx - ox) - (m.bw + o.bw) / 2
				local dz = math.abs(mz - oz) - (m.bl + o.bl) / 2
				if dx < 0 and dz < 0 and my - m.h < oy + R.CRUSH_HEIGHT and oy - o.h < my + R.CRUSH_HEIGHT then
					table.insert(out, problem(n, m.piece, "mover", string.format("piece %d (moving) passes through %s", m.piece, label(o))))
					break
				end
			end
		end
	end
end

local function lavaProblems(n, surfaces, out)
	for i, s in surfaces do
		if s.standable then
			continue
		end
		local prev, nxt
		for j = i - 1, 1, -1 do
			if surfaces[j].standable then
				prev = surfaces[j]
				break
			end
		end
		for j = i + 1, #surfaces do
			if surfaces[j].standable then
				nxt = surfaces[j]
				break
			end
		end
		local floor = s.top
		if prev and nxt then
			floor = math.min(prev.top - prev.offDrop, nxt.top - nxt.landDrop)
		elseif prev then
			floor = prev.top - prev.offDrop
		elseif nxt then
			floor = nxt.top - nxt.landDrop
		end
		if s.top > floor + 0.5 then
			table.insert(out, problem(n, s.piece, "lava", string.format("piece %d (lava): top %s is above the floor around it (%s); kill parts lie at floor level",
				s.piece, f1(s.top), f1(floor))))
		end
	end
end

-- All problems of a stage whose surfaces are known (data layout or built geometry).
local function surfaceProblems(n, surfaces, problems)
	local standable = {}
	for _, s in surfaces do
		if s.standable then
			table.insert(standable, s)
		end
	end
	for k = 1, #standable - 1 do
		local p = jumpProblem(n, standable[k], standable[k + 1])
		if p then
			table.insert(problems, p)
		end
	end
	lavaProblems(n, surfaces, problems)
	crushProblems(n, surfaces, problems)
	return problems
end

local LevelBuilder = {}
ObbyKit.LevelBuilder = LevelBuilder
LevelBuilder.normalizePiece = normalizePiece
LevelBuilder.normalizeStage = normalizeStage

function LevelBuilder.layout(stage)
	return layout(normalizeStage(stage, num(type(stage) == "table" and stage.stage, 0)))
end

-- Problems of one stage as text ("stage 41 jump from piece 2 (platform) to ...: gap 12.0 at rise 0.0 > max 10.0").
function LevelBuilder.validate(stage, number: number?): { string }
	local st = normalizeStage(stage, number or num(type(stage) == "table" and stage.stage, 0))
	local surfaces, problems = layout(st)
	local n = trunc(num(st.stage, 0))
	if number ~= nil and n ~= number then
		table.insert(problems, 1, problem(n, 0, "structure", "should be stage " .. tostring(number)))
	end
	surfaceProblems(n, surfaces, problems)
	local out = {}
	for _, p in problems do
		table.insert(out, p.text)
	end
	return out
end

-- Problems of a zone that should hold stages first..first+count-1 (default: the stages it has).
function LevelBuilder.validateZone(zone, first: number?, count: number?): { string }
	local stages = {}
	for i, raw in (type(zone) == "table" and type(zone.stages) == "table" and zone.stages or {}) do
		table.insert(stages, normalizeStage(raw, (first or 1) + i - 1))
	end
	if first == nil then
		first = if stages[1] then stages[1].stage else 1
		count = #stages
	end
	local last = first + count - 1
	local have = {}
	for _, s in stages do
		have[s.stage] = true
	end
	local errors = {}
	for k = first, last do
		if not have[k] then
			table.insert(errors, "stage " .. k .. " is missing")
		end
	end
	for _, s in stages do
		if not (first <= s.stage and s.stage <= last) then
			table.insert(errors, "stage " .. s.stage .. " is outside this zone's range " .. first .. "-" .. last)
		end
	end
	for _, s in stages do
		if first <= s.stage and s.stage <= last then
			for _, e in LevelBuilder.validate(s, s.stage) do
				table.insert(errors, e)
			end
		end
	end
	return errors
end

-- ============================================================== runtime helpers

local Telemetry
local function count(name: string, n: number?)
	if Telemetry == nil then
		local m = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		Telemetry = if ok and mod then mod else false
	end
	if Telemetry and RunService:IsServer() then
		pcall(Telemetry.count, name, n or 1)
	end
end

local Assets
local function juice(): any
	if Assets == nil then
		local m = ReplicatedStorage:FindFirstChild("GameAssets")
		local ok, mod = pcall(function()
			return m and require(m)
		end)
		Assets = if ok and mod then mod else false
	end
	return Assets or nil
end

local function play(name: string, parent: Instance?)
	local a = juice()
	if a and a.play then
		pcall(a.play, name, parent)
	end
end

local function burst(at: any, color: Color3?, n: number?)
	local a = juice()
	if a and a.burst then
		pcall(a.burst, at, color, n)
	end
end

local COLORS = {
	kill = Color3.fromRGB(255, 45, 45),
	lava = Color3.fromRGB(255, 92, 30),
	check = Color3.fromRGB(88, 214, 92),
	checkGlow = Color3.fromRGB(150, 255, 170),
	start = Color3.fromRGB(64, 170, 255),
	pad = Color3.fromRGB(64, 225, 255),
	tramp = Color3.fromRGB(255, 92, 200),
	belt = Color3.fromRGB(62, 66, 84),
	chevron = Color3.fromRGB(255, 214, 64),
	coin = Color3.fromRGB(255, 205, 50),
	warn = Color3.fromRGB(255, 236, 140),
	dark = Color3.fromRGB(40, 36, 52),
	rail = Color3.fromRGB(255, 255, 255),
}
local PALETTES = {
	{ "#4FC3F7", "#FFD54F", "#FF8A65" },
	{ "#81C784", "#FFF176", "#BA68C8" },
	{ "#F06292", "#4DD0E1", "#FFB74D" },
	{ "#9575CD", "#FFCC80", "#4DB6AC" },
	{ "#FF7043", "#FFE082", "#29B6F6" },
	{ "#26A69A", "#F48FB1", "#FFEE58" },
	{ "#5C6BC0", "#80DEEA", "#FFAB91" },
	{ "#EC407A", "#B39DDB", "#C5E1A5" },
	{ "#FFA726", "#90CAF9", "#CE93D8" },
	{ "#66BB6A", "#FF8A80", "#FFF59D" },
}

local function hex(s: any, fallback: Color3): Color3
	if type(s) ~= "string" then
		return fallback
	end
	local ok, c = pcall(Color3.fromHex, s)
	return if ok and c then c else fallback
end

local function theme(zone: number?, palette: any, material: any)
	local base = PALETTES[((zone or 1) - 1) % #PALETTES + 1]
	local pal = if type(palette) == "table" then palette else {}
	local mat = Enum.Material.SmoothPlastic
	pcall(function()
		if type(material) == "string" and material ~= "" then
			mat = (Enum.Material :: any)[material]
		end
	end)
	return {
		main = hex(pal[1], Color3.fromHex(base[1])),
		accent = hex(pal[2], Color3.fromHex(base[2])),
		highlight = hex(pal[3], Color3.fromHex(base[3])),
		material = mat,
	}
end

-- Piece k of a stage takes the zone's three colours rotated by k, so neighbouring pieces never share a colour and no
-- stage reads as one slab of the zone's main colour.
local function rotated(look, k: number)
	local c = { look.main, look.accent, look.highlight }
	local i = (k - 1) % 3
	return { main = c[i + 1], accent = c[(i + 1) % 3 + 1], highlight = c[(i + 2) % 3 + 1], material = look.material }
end

local function newPart(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	if props.Shape then
		p.Shape = props.Shape
	end
	for k, v in props do
		if k ~= "Parent" and k ~= "Shape" then
			(p :: any)[k] = v
		end
	end
	p.Parent = props.Parent
	return p
end

local function decor(props: { [string]: any }): Part
	props.CanCollide, props.CanTouch, props.CanQuery = false, false, false
	return newPart(props)
end

local CYL = CFrame.Angles(0, 0, math.rad(90)) -- a Cylinder's axis is local X: this stands it upright

local function disc(name: string, d: number, h: number, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	return newPart({ Name = name, Shape = Enum.PartType.Cylinder, Size = Vector3.new(h, d, d), CFrame = cf * CFrame.new(0, -h / 2, 0) * CYL,
		Color = color, Material = material, Parent = parent })
end

local function block(name: string, size: { number }, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	return newPart({ Name = name, Size = Vector3.new(size[1], size[2], size[3]), CFrame = cf * CFrame.new(0, -size[2] / 2, 0),
		Color = color, Material = material, Parent = parent })
end

local function standable(part: BasePart)
	CollectionService:AddTag(part, "ObbyStandable")
end

local function killPart(part: BasePart)
	CollectionService:AddTag(part, "KillPart")
end

local function obstacle(kind: string, parent: Instance?): Model
	local m = Instance.new("Model")
	m.Name = kind
	m:SetAttribute("Kind", kind)
	CollectionService:AddTag(m, "Obstacle")
	m.Parent = parent
	return m
end

local function billboard(adornee: BasePart, text: string, color: Color3, height: number, maxDistance: number?)
	local bb = Instance.new("BillboardGui")
	bb.Name = "Label"
	bb.Size = UDim2.fromScale(8, 2.2)
	bb.StudsOffset = Vector3.new(0, height, 0)
	bb.MaxDistance = maxDistance or 140
	bb.LightInfluence = 0
	bb.Adornee = adornee
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color
	t.TextStrokeTransparency = 0.2
	t.TextStrokeColor3 = COLORS.dark
	t.Parent = bb
	bb.Parent = adornee
	return bb
end

local function emitter(parent: BasePart, texture: string, color: Color3, rate: number, speed: number, lifetime: number)
	local e = Instance.new("ParticleEmitter")
	e.Texture = texture
	e.Color = ColorSequence.new(color)
	e.LightEmission = 0.8
	e.Rate = rate
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.Lifetime = NumberRange.new(lifetime * 0.6, lifetime)
	e.SpreadAngle = Vector2.new(15, 15)
	e.EmissionDirection = Enum.NormalId.Top
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.6), NumberSequenceKeypoint.new(1, 0) })
	e.Parent = parent
	return e
end

-- ============================================================== the one driver loop

local movers = {}  -- every animated thing: { center = Vector3, alive = BasePart, step = function(rec, t) }
local active = {}  -- the movers near a player, stepped every Heartbeat
local ACTIVE_RADIUS = 260
local EPOCH = 1700000000
local driverOn = false

local function clock(): number
	return workspace:GetServerTimeNow() - EPOCH
end

local function refreshActive()
	local roots = {}
	for _, pl in Players:GetPlayers() do
		local hrp = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
		if hrp then
			table.insert(roots, hrp.Position)
		end
	end
	local keep, now = {}, {}
	for _, rec in movers do
		if rec.alive.Parent == nil then
			continue
		end
		table.insert(keep, rec)
		for _, pos in roots do
			if (pos - rec.center).Magnitude <= ACTIVE_RADIUS then
				table.insert(now, rec)
				break
			end
		end
	end
	movers, active = keep, now
end

local function ensureDriver()
	if driverOn or not RunService:IsServer() then
		return
	end
	driverOn = true
	RunService.Heartbeat:Connect(function()
		local t = clock()
		for _, rec in active do
			rec.step(rec, t)
		end
	end)
	task.spawn(function()
		while true do
			refreshActive()
			task.wait(0.5)
		end
	end)
end

local function addMover(rec)
	table.insert(movers, rec)
	ensureDriver()
	rec.step(rec, clock())
end

-- ============================================================== obstacles: Obstacles.<kind>(parent, cframe, params, look?)
-- cframe is the piece's TOP CENTER at rest, facing along the course (LookVector forward).

local Obstacles = {}
ObbyKit.Obstacles = Obstacles

local function params(kind: string, raw: any)
	local t = {}
	for k, v in (if type(raw) == "table" then raw else {}) do
		t[k] = v
	end
	t.kind = kind
	return normalizePiece(t)
end

function Obstacles.platform(parent, cf: CFrame, raw, look)
	local p, th = params("platform", raw), look or theme()
	local m = obstacle("platform", parent)
	local part
	if p.shape == "round" then
		part = disc("Platform", p.size[1], p.size[2], cf, th.main, th.material, m)
	elseif p.shape == "cylinder" then -- a log across the course: its axis (a Cylinder's local X) runs sideways
		local d = p.size[3]
		part = newPart({ Name = "Platform", Shape = Enum.PartType.Cylinder, Size = Vector3.new(p.size[1], d, d),
			CFrame = cf * CFrame.new(0, -d / 2, 0), Color = th.main, Material = th.material, Parent = m })
	elseif p.shape == "wedge-ramp" then -- a WedgePart rises toward its back (+Z): turned so it climbs along the course
		part = Instance.new("WedgePart")
		part.Name, part.Anchored = "Platform", true
		part.Size = Vector3.new(p.size[1], p.size[2], p.size[3])
		part.CFrame = cf * CFrame.new(0, -p.size[2] / 2, 0) * CFrame.Angles(0, math.pi, 0)
		part.Color, part.Material = th.main, th.material
		part.Parent = m
	else
		part = block("Platform", p.size, cf, th.main, th.material, m)
	end
	part:SetAttribute("Shape", p.shape)
	standable(part)
	return m
end

function Obstacles.checkpoint(parent, cf: CFrame, raw, look)
	local stage = trunc(num(type(raw) == "table" and raw.stage, 0))
	local m = obstacle("checkpoint", parent)
	local pad = block("Checkpoint", { P, R.PAD_THICK, P }, cf, COLORS.check, Enum.Material.SmoothPlastic, m)
	pad:SetAttribute("Stage", stage)
	CollectionService:AddTag(pad, "Checkpoint")
	standable(pad)
	local glow = decor({ Name = "Glow", Size = Vector3.new(P - 1.6, 0.1, P - 1.6), CFrame = cf * CFrame.new(0, -0.04, 0),
		Color = COLORS.checkGlow, Material = Enum.Material.Neon, Parent = m })
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = COLORS.check, 12, 1.2
	light.Parent = glow
	local pole = decor({ Name = "Pole", Shape = Enum.PartType.Cylinder, Size = Vector3.new(9, 0.5, 0.5),
		CFrame = cf * CFrame.new(-P / 2 + 0.6, 4.5, P / 2 - 0.6) * CYL, Color = COLORS.rail, Parent = m })
	decor({ Name = "Flag", Size = Vector3.new(3, 2, 0.2), CFrame = cf * CFrame.new(-P / 2 + 2.2, 8, P / 2 - 0.6),
		Color = (look or theme()).highlight, Material = Enum.Material.Fabric, Parent = m })
	billboard(pole, if stage > 0 then "STAGE " .. stage else "START", Color3.new(1, 1, 1), 6.5)
	return m
end

function Obstacles.moving(parent, cf: CFrame, raw, look)
	local p, th = params("moving", raw), look or theme()
	local m = obstacle("moving", parent)
	local part = block("Mover", p.size, cf, th.accent, th.material, m)
	standable(part)
	local rest = part.CFrame
	local local3 = Vector3.new(p.move[1], p.move[2], -p.move[3])
	local move = cf:VectorToWorldSpace(local3)
	part:SetAttribute("Rest", rest)
	part:SetAttribute("Move", Vector3.new(p.move[1], p.move[2], p.move[3]))
	part:SetAttribute("Period", p.period)
	part:SetAttribute("Phase", p.phase)
	if move.Magnitude > 0.1 then
		local mid = rest.Position + move / 2
		local railCF = if math.abs(move.Unit:Dot(cf.UpVector)) > 0.99 then CFrame.new(mid) * cf.Rotation * CFrame.Angles(math.pi / 2, 0, 0)
			else CFrame.lookAt(mid, rest.Position + move, cf.UpVector) * CFrame.new(0, -p.size[2] / 2 - 0.3, 0)
		decor({ Name = "Rail", Size = Vector3.new(0.35, 0.35, move.Magnitude), Color = COLORS.rail, Transparency = 0.75,
			Material = Enum.Material.Neon, CFrame = railCF, Parent = m })
	end
	local period, phase = p.period, p.phase
	addMover({ center = rest.Position + move / 2, alive = part, step = function(_, t)
		local a = 2 * math.pi * (t / period + phase)
		part.CFrame = rest + move * ((1 - math.cos(a)) / 2)
		part.AssemblyLinearVelocity = move * (math.pi / period * math.sin(a))
	end })
	return m
end

function Obstacles.spinner(parent, cf: CFrame, raw, look)
	local p, th = params("spinner", raw), look or theme()
	local m = obstacle("spinner", parent)
	local d = p.size[1]
	local base = disc("Base", d, p.size[2], cf, th.main, th.material, m)
	standable(base)
	decor({ Name = "Hub", Shape = Enum.PartType.Cylinder, Size = Vector3.new(p.bar_height + 0.5, 2.2, 2.2),
		CFrame = cf * CFrame.new(0, (p.bar_height + 0.5) / 2, 0) * CYL, Color = th.accent, Material = Enum.Material.Metal, Parent = m })
	local bar = newPart({ Name = "Bar", Size = Vector3.new(d - 0.5, 1, 1), CFrame = cf * CFrame.new(0, p.bar_height, 0), Color = COLORS.kill,
		Material = Enum.Material.Neon, CanCollide = false, Parent = m })
	killPart(bar)
	local pivot = cf * CFrame.new(0, p.bar_height, 0)
	local w = math.rad(p.speed)
	addMover({ center = pivot.Position, alive = bar, step = function(_, t)
		bar.CFrame = pivot * CFrame.Angles(0, (w * t) % (2 * math.pi), 0)
	end })
	return m
end

function Obstacles.turntable(parent, cf: CFrame, raw, look)
	local p, th = params("turntable", raw), look or theme()
	local m = obstacle("turntable", parent)
	local d, h = p.size[1], p.size[2]
	local top = disc("Turntable", d, h, cf, th.accent, th.material, m)
	standable(top)
	top:SetAttribute("Speed", p.speed)
	local stripes = {}
	for k = 0, 1 do
		stripes[k + 1] = decor({ Name = "Stripe", Size = Vector3.new(d - 1, 0.06, 0.8), CFrame = cf * CFrame.Angles(0, k * math.pi / 2, 0),
			Color = th.highlight, Material = Enum.Material.Neon, Parent = m })
	end
	local w = math.rad(p.speed)
	local discCF = cf * CFrame.new(0, -h / 2, 0)
	addMover({ center = cf.Position, alive = top, step = function(_, t)
		local a = (w * t) % (2 * math.pi)
		top.CFrame = discCF * CFrame.Angles(0, a, 0) * CYL
		top.AssemblyAngularVelocity = cf.UpVector * w
		for k, s in stripes do
			s.CFrame = cf * CFrame.Angles(0, a + (k - 1) * math.pi / 2, 0) * CFrame.new(0, 0.02, 0)
		end
	end })
	return m
end

function Obstacles.disappearing(parent, cf: CFrame, raw, look)
	local p, th = params("disappearing", raw), look or theme()
	local m = obstacle("disappearing", parent)
	local l = p.size[3]
	local tiles = {}
	for j = 0, trunc(p.count) - 1 do
		local tile = block("Tile", p.size, cf * CFrame.new(0, 0, -j * (l + p.spacing)), th.highlight, th.material, m)
		tile:SetAttribute("Tile", j)
		standable(tile)
		tiles[j + 1] = { part = tile, offset = j * p.stagger, state = "" }
	end
	local on, cycle = p.on, p.on + p.off
	local warn = math.min(0.6, on / 2)
	addMover({ center = cf.Position, alive = tiles[1].part, step = function(_, t)
		for _, tl in tiles do
			local u = (t - tl.offset) % cycle
			local state = if u < on - warn then "solid" elseif u < on then (if math.floor(u * 8) % 2 == 0 then "warnA" else "warnB") else "gone"
			if state ~= tl.state then
				tl.state = state
				local part = tl.part
				part.CanCollide = state ~= "gone"
				part.CanTouch = state ~= "gone"
				part.Transparency = if state == "gone" then 1 elseif state == "warnB" then 0.55 else 0.05
				part.Color = if state == "solid" then th.highlight else COLORS.warn
			end
		end
	end })
	return m
end

function Obstacles.jumppad(parent, cf: CFrame, raw, look)
	local p = params("jumppad", raw)
	local m = obstacle("jumppad", parent)
	local pad = block("JumpPad", p.size, cf, COLORS.pad, Enum.Material.Neon, m)
	pad:SetAttribute("Power", p.power)
	pad:SetAttribute("Forward", p.forward)
	CollectionService:AddTag(pad, "JumpPad")
	standable(pad)
	emitter(pad, "rbxasset://textures/particles/sparkles_main.dds", COLORS.pad, 6, 14, 0.9)
	decor({ Name = "Arrow", Size = Vector3.new(1.2, 0.1, p.size[3] * 0.6), CFrame = cf * CFrame.new(0, 0.03, 0),
		Color = Color3.new(1, 1, 1), Material = Enum.Material.Neon, Parent = m })
	return m
end

function Obstacles.trampoline(parent, cf: CFrame, raw, look)
	local p = params("trampoline", raw)
	local m = obstacle("trampoline", parent)
	decor({ Name = "Frame", Size = Vector3.new(p.size[1] + 1, p.size[2] * 0.6, p.size[3] + 1), CFrame = cf * CFrame.new(0, -p.size[2] * 0.7, 0),
		Color = COLORS.dark, Material = Enum.Material.Metal, Parent = m })
	local pad = block("Trampoline", p.size, cf, COLORS.tramp, Enum.Material.Fabric, m)
	pad:SetAttribute("Bounce", p.bounce)
	CollectionService:AddTag(pad, "Trampoline")
	standable(pad)
	return m
end

local DIRS = { forward = Vector3.new(0, 0, -1), back = Vector3.new(0, 0, 1), left = Vector3.new(-1, 0, 0), right = Vector3.new(1, 0, 0) }

function Obstacles.conveyor(parent, cf: CFrame, raw, look)
	local p = params("conveyor", raw)
	local m = obstacle("conveyor", parent)
	local belt = block("Conveyor", p.size, cf, COLORS.belt, Enum.Material.DiamondPlate, m)
	belt:SetAttribute("Speed", p.speed)
	belt:SetAttribute("Dir", p.dir)
	CollectionService:AddTag(belt, "Conveyor")
	standable(belt)
	local dir = DIRS[p.dir] or DIRS.forward
	belt.AssemblyLinearVelocity = cf:VectorToWorldSpace(dir) * p.speed
	local face = CFrame.lookAt(Vector3.zero, dir)
	local along = if math.abs(dir.Z) > 0 then p.size[3] else p.size[1]
	for k = -1, 1 do
		local c = cf * CFrame.new(dir * (k * along / 4)) * face
		for s = -1, 1, 2 do
			decor({ Name = "Chevron", Size = Vector3.new(0.35, 0.06, 2), Color = COLORS.chevron, Material = Enum.Material.Neon,
				CFrame = c * CFrame.new(s * 0.6, 0.03, 0) * CFrame.Angles(0, s * math.rad(-40), 0), Parent = m })
		end
	end
	return m
end

function Obstacles.pendulum(parent, cf: CFrame, raw, look)
	local p, th = params("pendulum", raw), look or theme()
	local m = obstacle("pendulum", parent)
	local bridge = block("Bridge", p.size, cf, th.main, th.material, m)
	standable(bridge)
	local height = p.length + 3
	local half = p.size[1] / 2 + 0.8
	for s = -1, 1, 2 do
		decor({ Name = "Post", Size = Vector3.new(0.8, height + 1, 0.8), CFrame = cf * CFrame.new(s * half, (height + 1) / 2, 0),
			Color = th.accent, Material = Enum.Material.Metal, Parent = m })
	end
	decor({ Name = "Beam", Size = Vector3.new(half * 2 + 0.8, 0.8, 0.8), CFrame = cf * CFrame.new(0, height + 0.6, 0), Color = th.accent,
		Material = Enum.Material.Metal, Parent = m })
	local rod = decor({ Name = "Rod", Size = Vector3.new(0.35, p.length, 0.35), CFrame = cf, Color = COLORS.dark, Material = Enum.Material.Metal, Parent = m })
	local ball = newPart({ Name = "Ball", Shape = Enum.PartType.Ball, Size = Vector3.new(4, 4, 4), CFrame = cf, Color = COLORS.kill,
		Material = Enum.Material.Neon, CanCollide = false, Parent = m })
	killPart(ball)
	local pivot = cf * CFrame.new(0, height, 0)
	local amp, period, phase, length = math.rad(p.swing), p.period, p.phase, p.length
	addMover({ center = cf.Position, alive = ball, step = function(_, t)
		local arm = pivot * CFrame.Angles(0, 0, amp * math.sin(2 * math.pi * (t / period + phase)))
		ball.CFrame = arm * CFrame.new(0, -length, 0)
		rod.CFrame = arm * CFrame.new(0, -length / 2, 0)
	end })
	return m
end

function Obstacles.lava(parent, cf: CFrame, raw, look)
	local p = params("lava", raw)
	local m = obstacle("lava", parent)
	local slab = block("Lava", p.size, cf, COLORS.lava, Enum.Material.Neon, m)
	killPart(slab)
	emitter(slab, "rbxasset://textures/particles/fire_main.dds", COLORS.lava, 3, 3, 1.2)
	return m
end

local function coin(parent: Instance, pos: Vector3, rot: CFrame): Part
	local c = newPart({ Name = "Coin", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.4, 2.4, 2.4), CFrame = CFrame.new(pos) * rot,
		Color = COLORS.coin, Material = Enum.Material.Neon, CanCollide = false, Parent = parent })
	c:SetAttribute("Value", 1)
	c:SetAttribute("Available", true)
	CollectionService:AddTag(c, "Coin")
	local base = CFrame.new(pos) * rot
	addMover({ center = pos, alive = c, step = function(_, t)
		if c:GetAttribute("Available") ~= false then
			c.CFrame = base * CFrame.Angles(0, (t * 2.5) % (2 * math.pi), 0)
		end
	end })
	return c
end

-- ============================================================== LevelBuilder.build

-- info[n] = { zone, zoneName, theme, origin = the stage's (turned) frame, its corridor in that frame };
-- nextStart[n] = the next zone's start pad when stage n ends a zone; gates[zone] = that zone's ride gate.
-- world: the course stands in a world (anchors or a park spawn given): a player who has not reached the course yet
-- starts and respawns at `spawn` (the park's lobby), not on the start pad.
local course = { origin = nil, stages = 0, info = {}, checkpoints = {}, coins = 0, folder = nil, start = nil, errors = {},
	zoneStarts = {}, nextStart = {}, gates = {}, anchors = nil, themes = nil, zones = {}, entrances = {}, supports = 0,
	world = false, spawn = nil }

-- Decoration a themes module adds may never change what players collide with, stand on or touch: every part
-- it adds to `root` loses collision, touch and query and its mass (the validated footprint stays exact).
local function dressed(root: Instance, fn, ...)
	local before = {}
	for _, d in root:GetDescendants() do
		before[d] = true
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("[ObbyKit] themes: " .. tostring(err))
	end
	for _, d in root:GetDescendants() do
		if not before[d] and d:IsA("BasePart") then
			d.CanCollide, d.CanTouch, d.CanQuery, d.Massless = false, false, false, true
			for _, tag in { "ObbyStandable", "KillPart", "Checkpoint", "JumpPad", "Trampoline", "Conveyor", "Coin" } do
				CollectionService:RemoveTag(d, tag)
			end
		end
	end
end

-- Build one stage from data at `origin` (the TOP CENTER of the pad it starts on, LookVector = forward). The
-- stage's turn is the caller's (buildLevels turns `origin` before calling); it is recorded for the audit.
-- opts: { parent, zone, zoneName, palette, material, validate = true, themes, theme, rng }: themes.dress(kind,
-- model, params, theme, rng) runs on every piece and themes.stageDecor(stage, theme, rng, n) on the stage.
-- Returns the stage Model, its checkpoint Part (nil if the data has none) and the path points (rest top centers).
function LevelBuilder.build(stageData, origin: CFrame, opts: { [string]: any }?)
	assert(RunService:IsServer(), "ObbyKit.LevelBuilder.build runs on the server")
	opts = opts or {}
	local st = normalizeStage(stageData, num(type(stageData) == "table" and stageData.stage, 0))
	local n = st.stage
	local surfaces = layout(st)
	local look = theme(opts.zone, opts.palette, opts.material)
	local themes = if type(opts.themes) == "table" then opts.themes else nil
	local rng = opts.rng or Random.new(n * 7919 + 17)
	local model = Instance.new("Model")
	model.Name = string.format("Stage%03d", n)
	model:SetAttribute("Stage", n)
	model:SetAttribute("StageName", st.name)
	model:SetAttribute("Zone", opts.zone or 0)
	model:SetAttribute("ZoneName", opts.zoneName or "")
	model:SetAttribute("Origin", origin)
	model:SetAttribute("Turn", st.turn)
	if opts.theme then
		model:SetAttribute("Theme", opts.theme)
	end
	CollectionService:AddTag(model, "ObbyStage")
	local checkpoint, points, done = nil, {}, {}
	for _, s in surfaces do
		table.insert(points, (origin * CFrame.new(s.x, s.top, -s.z)).Position)
		if s.piece == 0 or done[s.piece] then
			continue
		end
		done[s.piece] = true
		local piece = st.pieces[s.piece]
		local builder = Obstacles[piece.kind]
		if not builder then
			continue
		end
		local raw = piece
		if piece.kind == "checkpoint" then
			raw = { stage = n }
		end
		local cf = origin * CFrame.new(s.x, s.top, -s.z)
		local m = builder(model, cf, raw, rotated(look, s.piece))
		m.Name = string.format("%02d_%s", s.piece, piece.kind)
		m:SetAttribute("Stage", n)
		m:SetAttribute("Piece", s.piece)
		for _, d in m:GetDescendants() do
			if d:IsA("BasePart") and (CollectionService:HasTag(d, "ObbyStandable") or CollectionService:HasTag(d, "KillPart")) then
				d:SetAttribute("Piece", s.piece)
			end
		end
		if piece.kind == "checkpoint" then
			checkpoint = m:FindFirstChild("Checkpoint")
		end
		local coins = trunc(piece.coins or 0)
		for k = 1, coins do
			coin(m, (cf * CFrame.new(0, 3.2, (k - (coins + 1) / 2) * 2.6)).Position, cf.Rotation)
			course.coins += 1
		end
		if themes and type(themes.dress) == "function" then
			dressed(m, themes.dress, piece.kind, m, piece, opts.theme, rng)
		end
	end
	if themes and type(themes.stageDecor) == "function" then
		dressed(model, themes.stageDecor, model, opts.theme, rng, n)
	end
	if opts.validate ~= false then
		local errors = LevelBuilder.validate(st, n)
		model:SetAttribute("Valid", #errors == 0)
		model:SetAttribute("Errors", string.sub(table.concat(errors, "\n"), 1, 1500))
		for _, e in errors do
			warn("[ObbyKit] " .. e)
		end
	end
	model.Parent = opts.parent or workspace
	return model, checkpoint, points
end

local function surfaceOf(part: BasePart, origin: CFrame)
	local cf = part:GetAttribute("Rest") or part.CFrame
	local shape = part:GetAttribute("Shape")
	local isDisc = part:IsA("Part") and part.Shape == Enum.PartType.Cylinder and shape ~= "cylinder"
	local thick = if isDisc then part.Size.X else part.Size.Y
	local lp = origin:PointToObjectSpace(cf.Position + origin.UpVector * (thick / 2))
	local w, l = part.Size.X, part.Size.Z
	if isDisc then
		w, l = part.Size.Y, part.Size.Y
	end
	local model = part:FindFirstAncestorOfClass("Model")
	local kind = model and model:GetAttribute("Kind") or "?"
	local s = newSurface(part:GetAttribute("Piece") or 0, kind, lp.X, -lp.Z, lp.Y, w, l, isDisc,
		CollectionService:HasTag(part, "ObbyStandable"))
	s.h = thick
	if shape == "cylinder" then
		s.l, s.bl = l * R.LOG_STRIP, l
		s.landDrop, s.offDrop = l / 2 * R.LOG_DROP, l / 2 * R.LOG_DROP
	elseif shape == "wedge-ramp" then
		s.landDrop = thick
	end
	s.tile = part:GetAttribute("Tile") or -1
	local move = part:GetAttribute("Move")
	if typeof(move) == "Vector3" and part:GetAttribute("Period") then
		s.move, s.period, s.phase = { move.X, move.Y, move.Z }, part:GetAttribute("Period"), part:GetAttribute("Phase") or 0
	end
	if CollectionService:HasTag(part, "JumpPad") then
		s.launch, s.launched = math.max(R.JUMP_SPEED, launchSpeed(part:GetAttribute("Power") or 0)), true
	elseif CollectionService:HasTag(part, "Trampoline") then
		s.launch, s.launched = math.max(R.JUMP_SPEED, launchSpeed(part:GetAttribute("Bounce") or 0)), true
	elseif CollectionService:HasTag(part, "Conveyor") and part:GetAttribute("Dir") == "back" then
		s.walk = R.WALK_SPEED - (part:GetAttribute("Speed") or 0)
	end
	return s
end

-- Re-check the BUILT course from its parts (positions, sizes, movers' rest frames): the same jump, lava
-- and mover rules as the data, so a builder bug can't hide behind valid data. -> { "stage N ...", ... }
function LevelBuilder.audit(root: Instance?): { string }
	local errors = {}
	for _, model in CollectionService:GetTagged("ObbyStage") do
		if root and not model:IsDescendantOf(root) then
			continue
		end
		local origin = model:GetAttribute("Origin")
		if typeof(origin) ~= "CFrame" then
			table.insert(errors, model.Name .. " has no Origin attribute")
			continue
		end
		local n = model:GetAttribute("Stage") or 0
		local surfaces = { padSurface(model:GetAttribute("Turn") or 0) }
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d:GetAttribute("Piece") and (CollectionService:HasTag(d, "ObbyStandable") or d.Name == "Lava") then
				table.insert(surfaces, surfaceOf(d, origin))
			end
		end
		table.sort(surfaces, function(a, b)
			if a.piece ~= b.piece then
				return a.piece < b.piece
			end
			return a.tile < b.tile
		end)
		local found = {}
		surfaceProblems(n, surfaces, found)
		for _, p in found do
			table.insert(errors, p.text)
		end
	end
	return errors
end

-- ============================================================== players: stage, saving, respawn

local data = {}       -- [Player] = { stage, coins, finishes, loaded, dirty, lastSave }
local memory = {}     -- [userId] = saved record (the whole store in Studio, a cache live)
local store = nil     -- DataStore, or nil (memory only)
local opts0 = {}
local stageHooks, finishHooks = {}, {}
local started = false
local SAVE_EVERY = 6
local FALL_DEPTH = 25

-- The pad a player at `stage` stands on: the pad stage+1 starts on (the next zone's start pad after a zone's last
-- checkpoint), facing the way that stage runs.
local function spawnPad(stage: number): BasePart?
	if stage <= 0 then
		return course.start
	end
	return course.nextStart[stage] or course.checkpoints[stage]
end

local function spawnFrame(stage: number): CFrame?
	local pad = spawnPad(stage)
	if not pad then
		return nil
	end
	local top = pad.CFrame * CFrame.new(0, pad.Size.Y / 2, 0)
	local nxt = course.info[stage + 1]
	local fwd = if nxt then nxt.origin.LookVector elseif course.origin then course.origin.LookVector else top.LookVector
	local flat = Vector3.new(fwd.X, 0, fwd.Z)
	local pos = top.Position + Vector3.new(0, 3.2, 0)
	return CFrame.lookAt(pos, pos + (if flat.Magnitude > 1e-3 then flat else Vector3.new(0, 0, -1)))
end

local function zoneFor(stage: number)
	local info = course.info[math.clamp(stage, 1, math.max(1, course.stages))]
	return info and info.zone or 0, info and info.zoneName or ""
end

local function publish(player: Player, d)
	local ls = player:FindFirstChild("leaderstats")
	local sv = ls and ls:FindFirstChild("Stage")
	if sv then
		sv.Value = d.stage
	end
	local cv = ls and ls:FindFirstChild("Coins")
	if cv then
		cv.Value = d.coins
	end
	player:SetAttribute("Stage", d.stage)
	local zone, name = zoneFor(if d.stage >= course.stages then d.stage else d.stage + 1)
	player:SetAttribute("Zone", zone)
	player:SetAttribute("ZoneName", name)
end

local function save(player: Player, force: boolean?)
	local d = data[player]
	if not d or not d.loaded then
		return
	end
	local rec = { stage = d.stage, coins = d.coins, finishes = d.finishes }
	memory[player.UserId] = rec
	if store == nil then
		player:SetAttribute("SavedStage", d.stage)
		return
	end
	if not force and os.clock() - (d.lastSave or 0) < SAVE_EVERY then
		d.dirty = true
		return
	end
	d.lastSave, d.dirty = os.clock(), false
	local ok = pcall(function()
		store:SetAsync("u" .. player.UserId, rec)
	end)
	if ok and player.Parent then
		player:SetAttribute("SavedStage", rec.stage)
	end
end

local function load(player: Player)
	local rec = memory[player.UserId]
	if rec == nil and store ~= nil then
		for _ = 1, 3 do
			local ok, res = pcall(function()
				return store:GetAsync("u" .. player.UserId)
			end)
			if ok then
				rec = res
				break
			end
			task.wait(1)
		end
	end
	rec = if type(rec) == "table" then rec else {}
	local d = data[player]
	d.stage = math.clamp(trunc(num(rec.stage, 0)), 0, math.max(0, course.stages))
	d.coins = math.max(0, trunc(num(rec.coins, 0)))
	d.finishes = math.max(0, trunc(num(rec.finishes, 0)))
	d.loaded = true
	publish(player, d)
	player:SetAttribute("SavedStage", d.stage)
end

local function fire(hooks, ...)
	for _, fn in hooks do
		task.spawn(fn, ...)
	end
end

local function finish(player: Player, d)
	d.finishes += 1
	player:SetAttribute("Finished", true)
	player:SetAttribute("Finishes", d.finishes)
	count("obby_finished")
	local cp = course.checkpoints[d.stage]
	play("Boom", cp)
	burst(cp or Vector3.zero, COLORS.coin, 60)
	fire(finishHooks, player)
end

local function setStage(player: Player, n: number, reached: boolean?)
	local d = data[player]
	if not d or not d.loaded then
		return
	end
	d.stage = math.clamp(trunc(n), 0, math.max(0, course.stages))
	publish(player, d)
	save(player)
	if reached then
		count("checkpoint_reached")
		local cp = course.checkpoints[d.stage]
		if cp then
			play("Win", cp)
			burst(cp, COLORS.check, 30)
		end
	end
	fire(stageHooks, player, d.stage)
	if reached and d.stage >= course.stages and course.stages > 0 then
		finish(player, d)
	end
end

local function teleport(player: Player, cf: CFrame?)
	local char = player.Character
	if char and cf then
		if workspace.StreamingEnabled then -- the checkpoint may not be streamed in on that client yet
			pcall(function()
				player:RequestStreamAroundAsync(cf.Position, 3)
			end)
		end
		char:PivotTo(cf)
		local hrp = char:FindFirstChild("HumanoidRootPart")
		if hrp then
			hrp.AssemblyLinearVelocity = Vector3.zero
		end
	end
end

-- Where a respawn puts this player: their checkpoint (the start pad at stage 0), except in a world for a player who
-- has not reached the course yet: the park spawn, so they walk in through the entrance and lobby (nil without one:
-- the character stays where Roblox spawned it).
local function homeFrame(player: Player): CFrame?
	local d = data[player]
	local stage = d and d.stage or 0
	if stage > 0 or not course.world or (d and d.started) then
		return spawnFrame(stage)
	end
	local at = course.spawn
	if typeof(at) ~= "CFrame" then
		return nil
	end
	local pos = at.Position + Vector3.new(0, 3.2, 0)
	local look = Vector3.new(at.LookVector.X, 0, at.LookVector.Z)
	return CFrame.lookAt(pos, pos + (if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)))
end

local function respawn(player: Player)
	teleport(player, homeFrame(player))
end

-- The player stood on the course (a start pad, a checkpoint, a ride gate) or fell off it: from now on a stage-0
-- respawn goes to the start pad.
local function onCourse(player: Player?)
	local d = player and data[player]
	if d and not d.started then
		d.started = true
		player:SetAttribute("OnCourse", true)
	end
end

local function onCharacter(player: Player, char: Model)
	local hum = char:WaitForChild("Humanoid", 10)
	if hum then
		hum.Died:Connect(function()
			count("player_died")
		end)
	end
	if not char:WaitForChild("HumanoidRootPart", 10) then
		return
	end
	local t0 = os.clock()
	while not (data[player] and data[player].loaded) and os.clock() - t0 < 15 do
		task.wait(0.1)
	end
	if not char:IsDescendantOf(workspace) then
		char.AncestryChanged:Wait()
	end
	task.wait(0.1)
	if player.Character == char then
		respawn(player)
	end
end

local function setupPlayer(player: Player)
	if data[player] then
		return
	end
	data[player] = { stage = 0, coins = 0, finishes = 0, loaded = false, started = false }
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		ls = Instance.new("Folder")
		ls.Name = "leaderstats"
		ls.Parent = player
	end
	if not ls:FindFirstChild("Stage") then
		local v = Instance.new("IntValue")
		v.Name = "Stage"
		v.Parent = ls
	end
	if course.coins > 0 and not ls:FindFirstChild("Coins") then
		local v = Instance.new("IntValue")
		v.Name = "Coins"
		v.Parent = ls
	end
	player.CharacterAdded:Connect(function(char)
		onCharacter(player, char)
	end)
	task.spawn(load, player)
	if player.Character then
		task.spawn(onCharacter, player, player.Character)
	end
end

local function playerFromHit(hit: BasePart)
	local model = hit and hit:FindFirstAncestorOfClass("Model")
	while model and not model:FindFirstChildOfClass("Humanoid") do
		model = model:FindFirstAncestorOfClass("Model")
	end
	if not model then
		return nil, nil, nil
	end
	local hum = model:FindFirstChildOfClass("Humanoid")
	return Players:GetPlayerFromCharacter(model), hum, model
end

local function wireTag(tag: string, onTouch)
	local conns = {}
	local function add(part)
		if part:IsA("BasePart") and not conns[part] then
			conns[part] = part.Touched:Connect(function(hit)
				onTouch(part, hit)
			end)
		end
	end
	for _, p in CollectionService:GetTagged(tag) do
		add(p)
	end
	CollectionService:GetInstanceAddedSignal(tag):Connect(add)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(p)
		if conns[p] then
			conns[p]:Disconnect()
			conns[p] = nil
		end
	end)
end

local recent = setmetatable({}, { __mode = "k" }) -- [character] = { [tag] = os.clock() } debounce

local function debounce(char: Model, key: string, secs: number): boolean
	local t = recent[char] or {}
	recent[char] = t
	if t[key] and os.clock() - t[key] < secs then
		return false
	end
	t[key] = os.clock()
	return true
end

local function launch(hrp: BasePart, vertical: number, forward: Vector3?)
	local att = Instance.new("Attachment")
	att.Name = "ObbyLaunch"
	att.Parent = hrp
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.MaxForce = math.huge
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	if forward then
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.VectorVelocity = Vector3.new(0, vertical, 0) + forward
	else
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Line
		lv.LineDirection = Vector3.yAxis
		lv.LineVelocity = vertical
	end
	lv.Parent = hrp
	task.delay(R.LAUNCH_HOLD, function()
		lv:Destroy()
		att:Destroy()
	end)
end

local function onKill(part, hit)
	local _, hum, char = playerFromHit(hit)
	if hum and hum.Health > 0 and debounce(char, "kill", 0.5) then
		hum.Health = 0
		play("Hurt", part)
		burst(hit.Position, COLORS.kill, 16)
	end
end

local function onJumpPad(part, hit)
	local _, hum, char = playerFromHit(hit)
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and hrp and debounce(char, "pad", 0.4) then
		launch(hrp, part:GetAttribute("Power") or 90, part.CFrame.LookVector * (part:GetAttribute("Forward") or 0))
		count("jump_pad_used")
		play("Whoosh", part)
		burst(part, COLORS.pad, 14)
	end
end

local function onTrampoline(part, hit)
	local _, hum, char = playerFromHit(hit)
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hum and hum.Health > 0 and hrp and debounce(char, "tramp", 0.3) then
		launch(hrp, part:GetAttribute("Bounce") or 70, nil)
		count("trampoline_bounce")
		play("Jump", part)
	end
end

local function onCoin(part, hit)
	if part:GetAttribute("Available") == false then
		return
	end
	local player, hum = playerFromHit(hit)
	local d = player and data[player]
	if not d or not d.loaded or not hum or hum.Health <= 0 then
		return
	end
	part:SetAttribute("Available", false)
	part.Transparency = 1
	d.coins += trunc(num(part:GetAttribute("Value"), 1))
	publish(player, d)
	save(player)
	count("coin_collected")
	play("Coin", part)
	burst(part.Position, COLORS.coin, 12)
	task.delay(opts0.coinRespawn or 20, function()
		if part.Parent then
			part:SetAttribute("Available", true)
			part.Transparency = 0
		end
	end)
end

local function onCheckpoint(part, hit)
	local player, hum = playerFromHit(hit)
	local d = player and data[player]
	if not d or not d.loaded or not hum or hum.Health <= 0 then
		return
	end
	onCourse(player)
	local n = part:GetAttribute("Stage")
	if type(n) ~= "number" or n <= d.stage then
		return
	end
	if n == d.stage + 1 or opts0.allowSkip then
		setStage(player, n, true)
	end
end

-- A ride gate at a zone's last checkpoint (touch pad or prompt): saves the stage and sends the player to the
-- next zone's start pad. A player one stage short is standing past the zone's last jump: that counts as reaching it.
local function rideGate(player: Player, gate: Instance)
	local d = data[player]
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not d or not d.loaded or not hum or hum.Health <= 0 or not debounce(char, "ride", 1.5) then
		return
	end
	local last = gate:GetAttribute("Stage")
	if type(last) ~= "number" then
		return
	end
	if d.stage < last then
		if d.stage ~= last - 1 and not opts0.allowSkip then
			return
		end
		setStage(player, last, true)
	end
	onCourse(player)
	save(player, true)
	count("ride_gate_used")
	play("Whoosh", gate:FindFirstChild("RidePad"))
	teleport(player, spawnFrame(last))
	player:SetAttribute("LastRide", gate:GetAttribute("NextZone"))
end

local function onRideGate(part, hit)
	local player = playerFromHit(hit)
	local gate = part:FindFirstAncestorOfClass("Model")
	if player and gate then
		rideGate(player, gate)
	end
end

local function onStartPad(_, hit)
	local player, hum = playerFromHit(hit)
	if player and hum and hum.Health > 0 then
		onCourse(player)
	end
end

-- A short message over `adornee` that only this player sees (a BillboardGui in their PlayerGui), for 3 seconds.
local function notify(player: Player, adornee: BasePart?, text: string)
	player:SetAttribute("RideNotice", text)
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if not gui or not adornee then
		return
	end
	local old = gui:FindFirstChild("ObbyNotice")
	if old then
		old:Destroy()
	end
	local bb = Instance.new("BillboardGui")
	bb.Name = "ObbyNotice"
	bb.Adornee = adornee
	bb.Size = UDim2.fromOffset(340, 60)
	bb.StudsOffset = Vector3.new(0, 7, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 120
	bb.ResetOnSpawn = false
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundColor3 = COLORS.dark
	t.BackgroundTransparency = 0.2
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = COLORS.warn
	t.Parent = bb
	local round = Instance.new("UICorner")
	round.CornerRadius = UDim.new(0, 14)
	round.Parent = t
	bb.Parent = gui
	task.delay(3, function()
		if bb.Parent then
			bb:Destroy()
		end
	end)
end

-- A ride entrance on the park's ground (WorldKit's gates[z], for z >= 2): a player who has finished the zone before it
-- rides up to zone z, to their own checkpoint while they are inside zone z, else to its start pad. Anyone else sees
-- which zone to finish first.
local function rideEntrance(player: Player, gate: Instance)
	local d = data[player]
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not d or not d.loaded or not hum or hum.Health <= 0 or not debounce(char, "entrance", 1.5) then
		return
	end
	local need, last = gate:GetAttribute("Stage"), gate:GetAttribute("LastStage")
	if type(need) ~= "number" or type(last) ~= "number" then
		return
	end
	local pad = gate:FindFirstChild("EntrancePad")
	if d.stage < need and not opts0.allowSkip then
		count("ride_entrance_locked")
		notify(player, pad, "Finish " .. tostring(gate:GetAttribute("FromZoneName") or "the zone before") .. " first")
		return
	end
	onCourse(player)
	count("ride_entrance_used")
	play("Whoosh", pad)
	teleport(player, spawnFrame(if d.stage < last then math.max(d.stage, need) else need))
	player:SetAttribute("LastRide", gate:GetAttribute("Zone"))
end

local function onRideEntrance(part, hit)
	local player = playerFromHit(hit)
	local gate = part:FindFirstAncestorOfClass("Model")
	if player and gate then
		rideEntrance(player, gate)
	end
end

local runtimeOn = false
local function ensureRuntime()
	if runtimeOn or not RunService:IsServer() then
		return
	end
	runtimeOn = true
	ensureDriver()
	wireTag("KillPart", onKill)
	wireTag("JumpPad", onJumpPad)
	wireTag("Trampoline", onTrampoline)
	wireTag("Coin", onCoin)
	wireTag("RideGatePad", onRideGate)
	wireTag("RideEntrancePad", onRideEntrance)
	wireTag("ObbyStart", onStartPad)
	wireTag("ObbyZoneStart", onStartPad)
end

-- Standing on something that is not the player's own part of the course: the park's ground, a stall roof, or, where
-- the route's runs stack, a stage of the run below (stage numbers other than `a` and `b`). In a world a fall often
-- ends there, long before FALL_DEPTH.
local function offCourse(hrp: BasePart, hum: Humanoid, a: number, b: number): boolean
	if hum.FloorMaterial == Enum.Material.Air then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { hrp.Parent }
	local hit = workspace:Raycast(hrp.Position, Vector3.new(0, -8, 0), params)
	if hit == nil then
		return false
	end
	if not (course.folder and hit.Instance:IsDescendantOf(course.folder)) then
		return true
	end
	local stage = hit.Instance:FindFirstAncestorWhichIsA("Model")
	while stage and not CollectionService:HasTag(stage, "ObbyStage") do
		stage = stage:FindFirstAncestorWhichIsA("Model")
	end
	local n = stage and stage:GetAttribute("Stage")
	return type(n) == "number" and n ~= a and n ~= b
end

-- Falls: a player below the stage they're on (inside its corridor, in that stage's own frame) goes back to their
-- checkpoint: FALL_DEPTH under its lowest piece, or standing anywhere under it past its start pad on something that is
-- not their stage (the ground, the run below).
local function catchFalls()
	if not course.origin then
		return
	end
	for player, d in data do
		local char = player.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (d.loaded and hrp and hum and hum.Health > 0) then
			continue
		end
		for _, s in { d.stage + 1, d.stage } do
			local info = course.info[s]
			local lp = info and info.origin:PointToObjectSpace(hrp.Position)
			local x, y, z = if lp then lp.X else 0, if lp then lp.Y else 0, if lp then -lp.Z else 0
			if info and z >= info.zMin - 20 and z <= info.zMax + 20 and x >= info.xMin - 30 and x <= info.xMax + 30 then
				local deep = y < info.minTop - FALL_DEPTH
				local grounded = not deep and z > P / 2 and y < info.minTop - 2 and offCourse(hrp, hum, d.stage, d.stage + 1)
				if (deep or grounded) and not d.returning then
					count("player_fell")
					onCourse(player)
					d.returning = true
					task.spawn(function()
						respawn(player)
						d.returning = false
					end)
				end
				break
			end
		end
	end
end

-- ============================================================== building the course

local function zoneNumber(mod: Instance, zoneData): number
	if type(zoneData) == "table" and tonumber(zoneData.zone) then
		return tonumber(zoneData.zone) :: number
	end
	return tonumber(string.match(mod.Name, "%d+") or "") or 0
end

local function loadZones(source): { any }
	local zones = {}
	if type(source) == "table" then
		for _, z in source do
			table.insert(zones, { n = num(z.zone, #zones + 1), data = z })
		end
	else
		local folder = source or ReplicatedStorage:FindFirstChild("Levels")
		for _, mod in (if folder then folder:GetChildren() else {}) do
			if mod:IsA("ModuleScript") then
				local ok, z = pcall(require, mod)
				if ok and type(z) == "table" then
					table.insert(zones, { n = zoneNumber(mod, z), data = z })
				else
					warn("[ObbyKit] could not load level module " .. mod:GetFullName() .. ": " .. tostring(z))
				end
			end
		end
	end
	table.sort(zones, function(a, b)
		return a.n < b.n
	end)
	return zones
end

local function zoneGate(parent: Instance, origin: CFrame, zone: number, name: string, look)
	for s = -1, 1, 2 do
		decor({ Name = "GatePillar", Size = Vector3.new(1.4, 14, 1.4), CFrame = origin * CFrame.new(s * 7.5, 7, -P / 2),
			Color = look.accent, Material = Enum.Material.SmoothPlastic, Parent = parent })
	end
	local beam = decor({ Name = "GateBeam", Size = Vector3.new(16.4, 2, 1.4), CFrame = origin * CFrame.new(0, 14.5, -P / 2),
		Color = look.highlight, Material = Enum.Material.Neon, Parent = parent })
	billboard(beam, "ZONE " .. zone .. (if name ~= "" then ": " .. name else ""), Color3.new(1, 1, 1), 3, 260)
end

-- The same spot, level and facing the same way (anchors may come tilted; a course always runs level).
local function levelFrame(cf: CFrame): CFrame
	local look = Vector3.new(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude < 1e-3 then
		return CFrame.new(cf.Position)
	end
	return CFrame.lookAt(cf.Position, cf.Position + look)
end

-- anchors[zone number], else anchors[theme id], else anchors[zone name] (WorldKit.buildPark's anchors).
local function anchorFor(anchors: any, n: number, zd): CFrame?
	if type(anchors) ~= "table" then
		return nil
	end
	for _, key in { n, zd.theme_id, zd.name } do
		local a = if key ~= nil then anchors[key] else nil
		if typeof(a) == "CFrame" then
			return a
		end
	end
	return nil
end

local function startPad(parent: Instance, cf: CFrame, look, name: string): BasePart
	local m = Obstacles.checkpoint(parent, cf, { stage = 0 }, look)
	m.Name = name
	local pad = m:FindFirstChild("Checkpoint")
	CollectionService:RemoveTag(pad, "Checkpoint")
	pad.Color = COLORS.start
	pad.Name = "StartPad"
	return pad
end

-- The ride gate on a zone's last checkpoint: a touch pad just past it (in the last stage's direction) under an
-- arch in the next zone's colours, and a prompt on the pad. Both call rideGate.
local function rideGateModel(parent: Instance, cp: BasePart, frame: CFrame, from, to): Model
	local top = cp.CFrame * CFrame.new(0, cp.Size.Y / 2, 0)
	local cf = CFrame.new(top.Position) * frame.Rotation * CFrame.new(0, 0, -(P / 2 + 4))
	local title = if to.name ~= "" then to.name else "Zone " .. to.n
	local m = Instance.new("Model")
	m.Name = "RideGate"
	m:SetAttribute("Zone", from.n)
	m:SetAttribute("Stage", from.last)
	m:SetAttribute("NextZone", to.n)
	m:SetAttribute("NextZoneName", to.name)
	CollectionService:AddTag(m, "RideGate")
	local pad = block("RidePad", { 8, 1, 8 }, cf, to.look.accent, Enum.Material.Neon, m)
	CollectionService:AddTag(pad, "RideGatePad")
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = to.look.highlight, 16, 1.5
	light.Parent = pad
	for k = -1, 1 do
		for s = -1, 1, 2 do
			decor({ Name = "Chevron", Size = Vector3.new(0.4, 0.08, 2.4), Color = Color3.new(1, 1, 1), Material = Enum.Material.Neon,
				CFrame = cf * CFrame.new(s * 0.75, 0.05, -k * 2.3) * CFrame.Angles(0, s * math.rad(-40), 0), Parent = m })
		end
	end
	for s = -1, 1, 2 do
		decor({ Name = "GatePost", Size = Vector3.new(1.2, 12, 1.2), CFrame = cf * CFrame.new(s * 4.6, 6, 0), Color = to.look.main,
			Material = Enum.Material.SmoothPlastic, Parent = m })
		decor({ Name = "GateLamp", Shape = Enum.PartType.Ball, Size = Vector3.new(2, 2, 2), CFrame = cf * CFrame.new(s * 4.6, 12.8, 0),
			Color = to.look.highlight, Material = Enum.Material.Neon, Parent = m })
	end
	local beam = decor({ Name = "GateBeam", Size = Vector3.new(10.4, 2.2, 1.2), CFrame = cf * CFrame.new(0, 11.4, 0),
		Color = to.look.highlight, Material = Enum.Material.Neon, Parent = m })
	billboard(beam, "RIDE TO " .. string.upper(title), Color3.new(1, 1, 1), 3, 220)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RidePrompt"
	prompt.ActionText = "Ride to " .. title
	prompt.ObjectText = "Ride gate"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad
	prompt.Triggered:Connect(function(player)
		rideGate(player, m)
	end)
	m.Parent = parent
	return m
end

-- The ride entrance to zone `to` on the park's ground at `cf` (WorldKit's gates[z], in front of the ride's arch): a
-- glowing pad with chevrons under a label, and a prompt on it. Both call rideEntrance.
local function rideEntranceModel(parent: Instance, cf: CFrame, from, to): Model
	local title = if to.name ~= "" then to.name else "Zone " .. to.n
	local m = Instance.new("Model")
	m.Name = string.format("Zone%02dEntrance", to.n)
	m:SetAttribute("Zone", to.n)
	m:SetAttribute("ZoneName", to.name)
	m:SetAttribute("Stage", from.last)
	m:SetAttribute("LastStage", to.last)
	m:SetAttribute("FromZone", from.n)
	m:SetAttribute("FromZoneName", if from.name ~= "" then from.name else "Zone " .. from.n)
	CollectionService:AddTag(m, "RideEntrance")
	local at = levelFrame(cf)
	local pad = block("EntrancePad", { 8, 1, 8 }, at, to.look.accent, Enum.Material.Neon, m)
	CollectionService:AddTag(pad, "RideEntrancePad")
	local light = Instance.new("PointLight")
	light.Color, light.Range, light.Brightness = to.look.highlight, 14, 1.2
	light.Parent = pad
	for k = -1, 1 do
		for s = -1, 1, 2 do
			decor({ Name = "Chevron", Size = Vector3.new(0.4, 0.08, 2.4), Color = Color3.new(1, 1, 1), Material = Enum.Material.Neon,
				CFrame = at * CFrame.new(s * 0.75, 0.05, -k * 2.3) * CFrame.Angles(0, s * math.rad(-40), 0), Parent = m })
		end
	end
	billboard(pad, "RIDE TO " .. string.upper(title), Color3.new(1, 1, 1), 5, 160)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "RidePrompt"
	prompt.ActionText = "Ride to " .. title
	prompt.ObjectText = "Ride gate"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = pad
	prompt.Triggered:Connect(function(player)
		rideEntrance(player, m)
	end)
	m.Parent = parent
	return m
end

-- A column under a pad that floats over open ground, from its underside down to whatever is below (the park's
-- ground), on a footing; decoration only. A pad over another part of the course (the column would stand on it or pass
-- beside it: 8 rays round the column's edge must reach the same ground), or one already sitting on something (a
-- WorldKit course tower), gets none. -> whether it built one.
local SUPPORT_REACH = 600
local SUPPORT_WIDTH = 2.4
local function support(pad: BasePart?, color: Color3, parent: Instance): boolean
	if not pad then
		return false
	end
	local bottom = pad.Position - Vector3.new(0, pad.Size.Y / 2, 0)
	local skip = { pad }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(skip, pl.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = skip
	local function courseHit(hit)
		return hit ~= nil and hit.Instance:IsDescendantOf(course.folder)
	end
	local hit = workspace:Raycast(pad.Position, Vector3.new(0, -SUPPORT_REACH, 0), params) -- from inside: a tower flush under it counts
	if not hit or courseHit(hit) or bottom.Y - hit.Position.Y < 2 then
		return false
	end
	local reach = Vector3.new(0, -(bottom.Y - hit.Position.Y + 1), 0)
	for k = 0, 7 do
		local a = k * math.pi / 4
		local edge = bottom + Vector3.new(math.cos(a), 0, math.sin(a)) * (SUPPORT_WIDTH / 2 + 1) + Vector3.new(0, -0.1, 0)
		if courseHit(workspace:Raycast(edge, reach, params)) then
			return false
		end
	end
	local len = bottom.Y - hit.Position.Y
	decor({ Name = "Support", Shape = Enum.PartType.Cylinder, Size = Vector3.new(len, SUPPORT_WIDTH, SUPPORT_WIDTH),
		CFrame = CFrame.new(bottom.X, (bottom.Y + hit.Position.Y) / 2, bottom.Z) * CYL, Color = color, Parent = parent })
	decor({ Name = "Footing", Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.8, 5.2, 5.2),
		CFrame = CFrame.new(hit.Position + Vector3.new(0, 0.4, 0)) * CYL, Color = Color3.fromRGB(232, 224, 208), Parent = parent })
	return true
end

-- Build every zone (ReplicatedStorage.Levels ModuleScripts, or a list of zone tables). opts: origin (the start
-- pad's top center), anchors ({[zone number | theme id | zone name] = CFrame}: a zone with one starts there on its
-- own start pad, the zone before it ends in a ride gate; a zone without one continues from the previous
-- checkpoint), gates (the same keys: a ride entrance on the ground to each zone with its own start pad, after the
-- first), themes (ObbyThemes), validate, parent. Each stage turns its frame by its `turn` on its start pad; every pad
-- floating over open ground gets a support column. Build the world first: the columns stand on what is under them.
-- -> { stages = n, built, errors = { ... }, zones, gates, entrances, supports }. Called by ObbyKit.start unless
-- opts.levels == false.
function ObbyKit.buildLevels(source: any?, opts: { [string]: any }?)
	assert(RunService:IsServer(), "ObbyKit.buildLevels runs on the server")
	opts = opts or {}
	ensureRuntime()
	local zones = loadZones(source)
	local anchors = if type(opts.anchors) == "table" then opts.anchors else course.anchors
	local themes = if type(opts.themes) == "table" then opts.themes else course.themes
	course.anchors, course.themes = anchors, themes
	local firstAnchor = if zones[1] then anchorFor(anchors, zones[1].n, zones[1].data) else nil
	local origin = levelFrame(firstAnchor or opts.origin or course.origin or CFrame.new(0, 60, 0))
	course.origin = origin
	local folder = course.folder or Instance.new("Folder")
	folder.Name = "Obby"
	folder.Parent = opts.parent or workspace
	course.folder = folder
	if not course.start then
		local pad = startPad(folder, origin, theme(1), "Start")
		CollectionService:AddTag(pad, "ObbyStart")
		course.start = pad
	end
	local stagesFolder = folder:FindFirstChild("Stages") or Instance.new("Folder")
	stagesFolder.Name = "Stages"
	stagesFolder.Parent = folder
	local cursor = origin
	local built = 0
	local list = {}
	for zi, z in zones do
		local zd = z.data
		local look = theme(z.n, zd.palette, zd.material)
		local name = tostring(zd.name or "")
		local themeId = if type(zd.theme_id) == "string" and zd.theme_id ~= "" then zd.theme_id else nil
		local anchor = if zi > 1 then anchorFor(anchors, z.n, zd) else nil
		local entry = { n = z.n, name = name, look = look, first = course.stages + 1, last = course.stages, data = zd }
		if anchor then
			cursor = levelFrame(anchor)
			local starts = folder:FindFirstChild("ZoneStarts") or Instance.new("Folder")
			starts.Name = "ZoneStarts"
			starts.Parent = folder
			local own = startPad(starts, cursor, look, string.format("Zone%02dStart", z.n))
			own:SetAttribute("Stage", nil)
			own:SetAttribute("Zone", z.n)
			own:SetAttribute("AfterStage", course.stages)
			CollectionService:AddTag(own, "ObbyZoneStart")
			course.zoneStarts[z.n] = own
			entry.start = own
		end
		for i, raw in (if type(zd.stages) == "table" then zd.stages else {}) do
			local expect = course.stages + 1
			local frame = cursor * CFrame.Angles(0, -math.rad(num(type(raw) == "table" and raw.turn, 0)), 0)
			local model, cp = LevelBuilder.build(raw, frame, { parent = stagesFolder, zone = z.n, zoneName = name,
				palette = zd.palette, material = zd.material, validate = opts.validate, themes = themes, theme = themeId })
			local n = model:GetAttribute("Stage")
			if n ~= expect then
				local msg = string.format("stage %s follows stage %d (expected %d)", tostring(n), course.stages, expect)
				warn("[ObbyKit] " .. msg)
				table.insert(course.errors, msg)
			end
			if i == 1 then
				zoneGate(model, frame, z.n, name, look)
			end
			local lp = { zMin = 0, zMax = 0, xMin = 0, xMax = 0, minTop = 0 } -- the start pad is the frame's origin
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") and CollectionService:HasTag(d, "ObbyStandable") then
					local p = frame:PointToObjectSpace((d:GetAttribute("Rest") or d.CFrame).Position)
					lp.zMin, lp.zMax = math.min(lp.zMin, -p.Z), math.max(lp.zMax, -p.Z)
					lp.xMin, lp.xMax = math.min(lp.xMin, p.X), math.max(lp.xMax, p.X)
					lp.minTop = math.min(lp.minTop, p.Y)
				end
			end
			course.info[n] = { zone = z.n, zoneName = name, theme = themeId, origin = frame, zMin = lp.zMin, zMax = lp.zMax,
				xMin = lp.xMin, xMax = lp.xMax, minTop = lp.minTop }
			if model:GetAttribute("Valid") == false then
				for _, e in string.split(model:GetAttribute("Errors") or "", "\n") do
					table.insert(course.errors, e)
				end
			end
			if cp then
				course.checkpoints[n] = cp
				local top = cp.CFrame * CFrame.new(0, cp.Size.Y / 2, 0)
				cursor = CFrame.new(top.Position) * frame.Rotation
			end
			course.stages = math.max(course.stages, n)
			entry.last, entry.frame, entry.model = course.stages, frame, model
			built += 1
			if built % 5 == 0 then
				task.wait()
			end
		end
		table.insert(list, entry)
	end
	local gates = 0
	for k = 1, #list - 1 do
		local a, b = list[k], list[k + 1]
		local cp = course.checkpoints[a.last]
		if b.start and cp and a.model then
			b.start:SetAttribute("AfterStage", a.last)
			course.nextStart[a.last] = b.start
			course.gates[a.n] = rideGateModel(a.model, cp, a.frame, a, b)
			gates += 1
		end
	end
	local ground = if type(opts.gates) == "table" then opts.gates else nil
	local entrances = 0
	for k = 2, #list do
		local a, b = list[k - 1], list[k]
		local at = anchorFor(ground, b.n, b.data)
		if at and b.start and course.nextStart[a.last] == b.start then
			course.entrances[b.n] = rideEntranceModel(folder, at, a, b)
			entrances += 1
		end
	end
	local supports = folder:FindFirstChild("Supports") or Instance.new("Folder")
	supports.Name = "Supports"
	supports.Parent = folder
	local columns = 0
	for k, e in list do
		local pads = { if k == 1 then course.start else e.start }
		for n = e.first, e.last do
			table.insert(pads, course.checkpoints[n])
		end
		local gate = course.gates[e.n]
		table.insert(pads, gate and gate:FindFirstChild("RidePad"))
		for _, pad in pads do
			if support(pad, e.look.main, supports) then
				columns += 1
			end
		end
	end
	course.zones, course.supports = list, columns
	folder:SetAttribute("Stages", course.stages)
	folder:SetAttribute("Zones", #list)
	folder:SetAttribute("RideGates", gates)
	folder:SetAttribute("RideEntrances", entrances)
	folder:SetAttribute("Supports", columns)
	folder:SetAttribute("Invalid", #course.errors)
	count("stages_built", built)
	return { stages = course.stages, built = built, errors = course.errors, zones = #list, gates = gates,
		entrances = entrances, supports = columns }
end

-- ============================================================== public API

-- Call once from one server Script. opts: origin (CFrame of the START pad's top center; the course runs along its
-- LookVector; default CFrame.new(0, 60, 0)), anchors ({[zone] = CFrame} from WorldKit.buildPark: zone 1 starts at its
-- anchor instead of origin, every later zone with one on its own start pad, reached by the ride gate on the zone
-- before), gates ({[zone] = CFrame}, WorldKit's: a ride entrance on the ground to every later zone), spawn (CFrame,
-- WorldKit's park spawn: with it, or with anchors, a player who has not reached the course yet starts and respawns
-- there instead of on the start pad), themes (the ObbyThemes module: dress + stageDecor, each call pcall-guarded),
-- levels (Folder or zone tables; false = build nothing), respawnTime (1.5), allowSkip (false), dataStore ("ObbyKit"),
-- coinRespawn (20). -> { stages, built, errors, zones, gates, entrances, supports }
function ObbyKit.start(opts: { [string]: any }?)
	assert(RunService:IsServer(), "ObbyKit.start runs on the server")
	opts = opts or {}
	if started then
		return { stages = course.stages, built = 0, errors = course.errors }
	end
	started = true
	opts0 = opts
	workspace.Gravity = R.GRAVITY
	StarterPlayer.CharacterUseJumpPower = false
	StarterPlayer.CharacterJumpHeight = R.JUMP_HEIGHT
	StarterPlayer.CharacterWalkSpeed = R.WALK_SPEED
	Players.RespawnTime = opts.respawnTime or 1.5
	for _, pl in Players:GetPlayers() do
		local hum = pl.Character and pl.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.UseJumpPower, hum.JumpHeight, hum.WalkSpeed = false, R.JUMP_HEIGHT, R.WALK_SPEED
		end
	end
	ensureRuntime()
	course.origin = opts.origin or CFrame.new(0, 60, 0)
	course.spawn = if typeof(opts.spawn) == "CFrame" then opts.spawn else nil
	course.world = course.spawn ~= nil or type(opts.anchors) == "table"
	local info = { stages = 0, built = 0, errors = {} }
	if opts.levels ~= false then
		info = ObbyKit.buildLevels(opts.levels, { origin = course.origin, anchors = opts.anchors, gates = opts.gates,
			themes = opts.themes })
	end
	if not RunService:IsStudio() or opts.saveInStudio then
		local ok, ds = pcall(function()
			return game:GetService("DataStoreService"):GetDataStore(opts.dataStore or "ObbyKit")
		end)
		store = if ok then ds else nil
	end
	wireTag("Checkpoint", onCheckpoint)
	Players.PlayerAdded:Connect(setupPlayer)
	for _, pl in Players:GetPlayers() do
		task.spawn(setupPlayer, pl)
	end
	Players.PlayerRemoving:Connect(function(pl)
		save(pl, true)
		data[pl] = nil
	end)
	game:BindToClose(function()
		for pl in data do
			save(pl, true)
		end
	end)
	task.spawn(function()
		local tick = 0
		while true do
			task.wait(0.25)
			tick += 1
			catchFalls()
			if tick % 24 == 0 then
				for pl, d in data do
					if d.dirty then
						save(pl, true)
					end
				end
			end
		end
	end)
	return info
end

function ObbyKit.getStage(player: Player): number
	return data[player] and data[player].stage or 0
end

function ObbyKit.setStage(player: Player, n: number)
	setStage(player, n, false)
end

function ObbyKit.respawn(player: Player)
	respawn(player)
end

function ObbyKit.stageCount(): number
	return course.stages
end

function ObbyKit.checkpoint(n: number): BasePart?
	return if n == 0 then course.start else course.checkpoints[n]
end

function ObbyKit.zoneOf(stage: number): (number, string)
	return zoneFor(stage)
end

function ObbyKit.onStage(fn: (Player, number) -> ())
	table.insert(stageHooks, fn)
end

function ObbyKit.onFinish(fn: (Player) -> ())
	table.insert(finishHooks, fn)
end

return ObbyKit
