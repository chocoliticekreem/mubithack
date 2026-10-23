--!strict
-- Junction [owner: Traffic]. PURE right-of-way + unsticking rules (no Roblox APIs;
-- spec: game/tests/traffic.spec.luau). TrafficService keeps the per-junction state; this decides.
--
-- Every car crossing a junction RESERVES its connector (RoadNet.connector) first. Two connectors
-- conflict when their swept paths come within `clearance` studs, or they end in the same lane;
-- connectors leaving the same lane never conflict (those cars simply follow each other).
-- A car may enter when no ACTIVE reservation conflicts with it and no older eligible REQUEST
-- conflicts with it (first come first served; the through road gets a head start at unsignalled
-- junctions). Requests are only eligible while they could go themselves (green light, room on
-- the exit lane), so a car that can't move never blocks anyone: waits form a DAG, never a cycle.
--
--   Junction.poly(seg) -> { number }                         -- x,z samples along a connector
--   Junction.conflicts(a, b, clearance) -> boolean           -- cached on the segs
--   Junction.mayEnter(mine, active, waiting, clearance) -> boolean
--       mine = { seg, t }, active = { Seg }, waiting = { { seg, t } } (other cars only)
--   Junction.lightState(phase, hx, hz) -> "green" | "yellow" | "red" | nil
--       phase = CityBuilder TrafficPhase "XGreen" | "XAmber" | "ZGreen" | "ZAmber"
--   Junction.room(laneLen, rears, need) -> boolean           -- space at the start of the exit lane
--   Junction.unstick(why, waited, stopped, cfg) -> "wait" | "reroute" | "force" | "pass" | "ghost"
--   Junction.blink(turn) -> "L" | "R" | ""
local Junction = {}

local SAMPLES = 9

local function bez(p: { number }, t: number): (number, number)
	local u = 1 - t
	local a, b, c, d = u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t
	return a * p[1] + b * p[4] + c * p[7] + d * p[10], a * p[3] + b * p[6] + c * p[9] + d * p[12]
end

function Junction.poly(seg: any): { number }
	local cached = seg.poly
	if cached then
		return cached
	end
	local out: { number } = {}
	local p = seg.p :: { number }
	for i = 0, SAMPLES - 1 do
		local x, z = bez(p, i / (SAMPLES - 1))
		table.insert(out, x)
		table.insert(out, z)
	end
	seg.poly = out
	return out
end

function Junction.conflicts(a: any, b: any, clearance: number): boolean
	if a == b or a.from == b.from then
		return false
	end
	if a.to == b.to then
		return true
	end
	local ca = a.conflict
	if ca and ca[b] ~= nil then
		return ca[b]
	end
	local pa, pb = Junction.poly(a), Junction.poly(b)
	local c2 = clearance * clearance
	local hit = false
	for i = 1, #pa, 2 do
		for j = 1, #pb, 2 do
			if (pa[i] - pb[j]) ^ 2 + (pa[i + 1] - pb[j + 1]) ^ 2 < c2 then
				hit = true
				break
			end
		end
		if hit then
			break
		end
	end
	a.conflict = a.conflict or {}
	b.conflict = b.conflict or {}
	a.conflict[b] = hit
	b.conflict[a] = hit
	return hit
end

export type Request = { seg: any, t: number }

function Junction.mayEnter(mine: Request, active: { any }, waiting: { Request }, clearance: number): boolean
	for _, seg in active do
		if Junction.conflicts(mine.seg, seg, clearance) then
			return false
		end
	end
	for _, w in waiting do
		if w.t < mine.t and Junction.conflicts(mine.seg, w.seg, clearance) then
			return false
		end
	end
	return true
end

function Junction.lightState(phase: any, hx: number, hz: number): string?
	if type(phase) ~= "string" or #phase < 2 then
		return nil
	end
	local axis = if math.abs(hx) >= math.abs(hz) then "X" else "Z"
	local p = string.upper(string.sub(phase, 1, 1))
	if p ~= "X" and p ~= "Z" then
		return nil
	end
	if p ~= axis then
		return "red"
	end
	local rest = string.lower(string.sub(phase, 2))
	if string.find(rest, "green", 1, true) then
		return "green"
	end
	if string.find(rest, "amber", 1, true) or string.find(rest, "yellow", 1, true) then
		return "yellow"
	end
	return "red"
end

-- rears: s - halfLen of every car already on (or heading into) the exit lane
function Junction.room(laneLen: number, rears: { number }, need: number): boolean
	local free = laneLen
	for _, r in rears do
		if r < free then
			free = r
		end
	end
	return free >= math.min(need, laneLen - 1)
end

-- why: what is holding the car this step ("red" | "yield" | "junction" | "leader" | "obstacle" | "")
-- waited: seconds held at the junction line; stopped: seconds at ~0 speed without an excuse
function Junction.unstick(why: string, waited: number, stopped: number, cfg: any): string
	if why == "red" or why == "yield" then
		return "wait"
	end
	if stopped >= cfg.GhostAfter then
		return "ghost"
	end
	if why == "junction" then
		if waited >= cfg.ForceAfter then
			return "force"
		end
		if waited >= cfg.RerouteAfter then
			return "reroute"
		end
		return "wait"
	end
	if why == "obstacle" and stopped >= cfg.PassAfter then
		return "pass"
	end
	if why == "leader" and stopped >= cfg.PassStalledAfter then
		return "pass"
	end
	return "wait"
end

function Junction.blink(turn: string?): string
	if turn == "left" or turn == "uturn" then
		return "L"
	elseif turn == "right" then
		return "R"
	end
	return ""
end

return Junction
