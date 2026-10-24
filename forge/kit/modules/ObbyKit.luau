--!nonstrict
-- ObbyKit: prebuilt by Forge (forge/kit/modules/ObbyKit.luau). Do not rewrite it; require it.
-- A server-authoritative obby engine: checkpoints (Stage leaderstat, saved, respawn there), kill parts,
-- ten obstacle kinds driven by ONE Heartbeat loop, and LevelBuilder, which builds stages from level data
-- (ReplicatedStorage/Levels/ZoneNN.luau, written by `forge levels`) and checks every jump with the same
-- rules as forge/obby.py. Everything is tagged (CollectionService) and attributed so checks can find it.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local ObbyKit = {}
ObbyKit.VERSION = 1

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
}
R.JUMP_SPEED = math.sqrt(2 * R.GRAVITY * R.JUMP_HEIGHT)
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
	platform = { size = { 8, 1, 8 }, min = { 2, 0.5, 2 }, max = { 40, 4, 40 }, params = { { "shape", "block", { "block", "round" } } } },
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
	end
	return out
end

local function normalizeStage(raw: any, number: number): { [string]: any }
	raw = if type(raw) == "table" then raw else {}
	local out: { [string]: any } = {
		stage = trunc(num(raw.stage, number)),
		name = string.sub(strip(tostring(raw.name or "")), 1, 60),
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

local function newSurface(piece, kind, x, z, top, w, l, rnd, standable)
	return {
		piece = piece, kind = kind, x = x, z = z, top = top, w = w, l = l, round = rnd, standable = standable,
		tile = -1, move = nil, period = 0, phase = 0, launch = R.JUMP_SPEED, walk = R.WALK_SPEED, launched = false,
	}
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
		for axis, name in { "width", "height", "length" } do
			local v, lo, hi = p.size[axis], spec.min[axis], spec.max[axis]
			if not (lo <= v and v <= hi) then
				table.insert(out, problem(n, i, "param", where .. " size " .. name .. " " .. g(v) .. " out of range " .. rangeText(lo, hi)))
			end
		end
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
	local surfaces = { newSurface(0, "pad", 0, 0, 0, P, P, false, true) }
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
		if kind == "disappearing" then
			for j = 0, trunc(p.count) - 1 do
				local s = newSurface(i, kind, p.side, near + l / 2, top, w, l, rnd, standable)
				s.tile = j
				table.insert(surfaces, s)
				near = near + l + p.spacing
			end
			cursorZ = near - p.spacing
		else
			local s = newSurface(i, kind, p.side, near + l / 2, top, w, l, rnd, standable)
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
	local rise = by - ay
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
				local dx = math.abs(mx - ox) - (m.w + o.w) / 2
				local dz = math.abs(mz - oz) - (m.l + o.l) / 2
				if dx < 0 and dz < 0 and math.abs(my - oy) < R.CRUSH_HEIGHT then
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
			floor = math.min(prev.top, nxt.top)
		elseif prev or nxt then
			floor = (prev or nxt).top
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
	local ok, c = pcall(Color3.fromHex, tostring(s))
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
	else
		part = block("Platform", p.size, cf, th.main, th.material, m)
	end
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

local course = { origin = nil, stages = 0, info = {}, checkpoints = {}, coins = 0, folder = nil, start = nil, errors = {} }

-- Build one stage from data at `origin` (the TOP CENTER of the pad it starts on, LookVector = forward).
-- opts: { parent, zone, zoneName, palette, material, validate = true }.
-- Returns the stage Model, its checkpoint Part (nil if the data has none) and the path points (rest top centers).
function LevelBuilder.build(stageData, origin: CFrame, opts: { [string]: any }?)
	assert(RunService:IsServer(), "ObbyKit.LevelBuilder.build runs on the server")
	opts = opts or {}
	local st = normalizeStage(stageData, num(type(stageData) == "table" and stageData.stage, 0))
	local n = st.stage
	local surfaces = layout(st)
	local look = theme(opts.zone, opts.palette, opts.material)
	local model = Instance.new("Model")
	model.Name = string.format("Stage%03d", n)
	model:SetAttribute("Stage", n)
	model:SetAttribute("StageName", st.name)
	model:SetAttribute("Zone", opts.zone or 0)
	model:SetAttribute("ZoneName", opts.zoneName or "")
	model:SetAttribute("Origin", origin)
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
		local m = builder(model, cf, raw, look)
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
	local isCyl = part:IsA("Part") and part.Shape == Enum.PartType.Cylinder
	local thick = if isCyl then part.Size.X else part.Size.Y
	local lp = origin:PointToObjectSpace(cf.Position + origin.UpVector * (thick / 2))
	local w, l = part.Size.X, part.Size.Z
	if isCyl then
		w, l = part.Size.Y, part.Size.Y
	end
	local model = part:FindFirstAncestorOfClass("Model")
	local kind = model and model:GetAttribute("Kind") or "?"
	local s = newSurface(part:GetAttribute("Piece") or 0, kind, lp.X, -lp.Z, lp.Y, w, l, isCyl,
		CollectionService:HasTag(part, "ObbyStandable"))
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
		local surfaces = { newSurface(0, "pad", 0, 0, 0, P, P, false, true) }
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

local function spawnFrame(stage: number): CFrame?
	local cp = course.checkpoints[stage]
	local pad = if stage > 0 then cp else course.start
	if not pad then
		return nil
	end
	local top = pad.CFrame * CFrame.new(0, pad.Size.Y / 2, 0)
	local fwd = if course.origin then course.origin.LookVector else top.LookVector
	local pos = top.Position + Vector3.new(0, 3.2, 0)
	return CFrame.lookAt(pos, pos + Vector3.new(fwd.X, 0, fwd.Z))
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

local function respawn(player: Player)
	local char = player.Character
	local cf = spawnFrame((data[player] and data[player].stage) or 0)
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
	data[player] = { stage = 0, coins = 0, finishes = 0, loaded = false }
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
	local n = part:GetAttribute("Stage")
	if type(n) ~= "number" or n <= d.stage then
		return
	end
	if n == d.stage + 1 or opts0.allowSkip then
		setStage(player, n, true)
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
end

-- Falls: a player below the stage they're on (inside its corridor) goes back to their checkpoint.
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
		local lp = course.origin:PointToObjectSpace(hrp.Position)
		local x, y, z = lp.X, lp.Y, -lp.Z
		for _, s in { d.stage, d.stage + 1 } do
			local info = course.info[s]
			if info and z >= info.zMin - 20 and z <= info.zMax + 20 and x >= info.xMin - 30 and x <= info.xMax + 30 then
				if y < info.minTop - FALL_DEPTH and not d.returning then
					count("player_fell")
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

-- Build every zone (ReplicatedStorage.Levels ModuleScripts, or a list of zone tables) end to end from the
-- start pad. -> { stages = n, errors = { ... } }. Called by ObbyKit.start unless opts.levels == false.
function ObbyKit.buildLevels(source: any?, opts: { [string]: any }?)
	assert(RunService:IsServer(), "ObbyKit.buildLevels runs on the server")
	opts = opts or {}
	ensureRuntime()
	local origin = opts.origin or course.origin or CFrame.new(0, 60, 0)
	course.origin = origin
	local folder = course.folder or Instance.new("Folder")
	folder.Name = "Obby"
	folder.Parent = opts.parent or workspace
	course.folder = folder
	if not course.start then
		local startModel = Obstacles.checkpoint(folder, origin, { stage = 0 }, theme(1))
		startModel.Name = "Start"
		local pad = startModel:FindFirstChild("Checkpoint")
		CollectionService:RemoveTag(pad, "Checkpoint")
		CollectionService:AddTag(pad, "ObbyStart")
		pad.Color = COLORS.start
		pad.Name = "StartPad"
		course.start = pad
	end
	local stagesFolder = folder:FindFirstChild("Stages") or Instance.new("Folder")
	stagesFolder.Name = "Stages"
	stagesFolder.Parent = folder
	local cursor = origin
	local built = 0
	for _, z in loadZones(source) do
		local zd = z.data
		local look = theme(z.n, zd.palette, zd.material)
		local name = tostring(zd.name or "")
		for i, raw in (if type(zd.stages) == "table" then zd.stages else {}) do
			local expect = course.stages + 1
			local model, cp = LevelBuilder.build(raw, cursor, { parent = stagesFolder, zone = z.n, zoneName = name,
				palette = zd.palette, material = zd.material, validate = opts.validate })
			local n = model:GetAttribute("Stage")
			if n ~= expect then
				local msg = string.format("stage %s follows stage %d (expected %d)", tostring(n), course.stages, expect)
				warn("[ObbyKit] " .. msg)
				table.insert(course.errors, msg)
			end
			if i == 1 then
				zoneGate(model, cursor, z.n, name, look)
			end
			local lp = { zMin = math.huge, zMax = -math.huge, xMin = math.huge, xMax = -math.huge, minTop = math.huge }
			for _, d in model:GetDescendants() do
				if d:IsA("BasePart") and CollectionService:HasTag(d, "ObbyStandable") then
					local p = origin:PointToObjectSpace((d:GetAttribute("Rest") or d.CFrame).Position)
					lp.zMin, lp.zMax = math.min(lp.zMin, -p.Z), math.max(lp.zMax, -p.Z)
					lp.xMin, lp.xMax = math.min(lp.xMin, p.X), math.max(lp.xMax, p.X)
					lp.minTop = math.min(lp.minTop, p.Y)
				end
			end
			local o = origin:PointToObjectSpace(cursor.Position)
			lp.zMin, lp.minTop = math.min(lp.zMin, -o.Z), math.min(lp.minTop, o.Y)
			course.info[n] = { zone = z.n, zoneName = name, zMin = lp.zMin, zMax = lp.zMax, xMin = lp.xMin, xMax = lp.xMax,
				minTop = lp.minTop }
			if model:GetAttribute("Valid") == false then
				for _, e in string.split(model:GetAttribute("Errors") or "", "\n") do
					table.insert(course.errors, e)
				end
			end
			if cp then
				course.checkpoints[n] = cp
				cursor = cp.CFrame * CFrame.new(0, cp.Size.Y / 2, 0)
				cursor = CFrame.new(cursor.Position) * origin.Rotation
			end
			course.stages = math.max(course.stages, n)
			built += 1
			if built % 5 == 0 then
				task.wait()
			end
		end
	end
	folder:SetAttribute("Stages", course.stages)
	folder:SetAttribute("Invalid", #course.errors)
	count("stages_built", built)
	return { stages = course.stages, built = built, errors = course.errors }
end

-- ============================================================== public API

-- Call once from one server Script. opts: origin (CFrame of the START pad's top center; the course runs along its
-- LookVector; default CFrame.new(0, 60, 0)), levels (Folder or zone tables; false = build nothing), respawnTime (1.5),
-- allowSkip (false), dataStore ("ObbyKit"), coinRespawn (20). -> { stages, built, errors }
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
	local info = { stages = 0, built = 0, errors = {} }
	if opts.levels ~= false then
		info = ObbyKit.buildLevels(opts.levels, { origin = course.origin })
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
