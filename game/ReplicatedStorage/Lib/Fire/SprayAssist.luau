--!strict
-- SprayAssist [owner: G1]. Pure rules (no Roblox APIs, spec: game/tests/spray_assist.spec.luau) for the
-- phone "first fire" fix (docs/game/21-phone-first-fire.md). Live funnel, 7 days: PHONE 369 arrived on
-- scene -> 282 put out a fire (23.6% quit), PC 42 -> 38 (9.5%).
--
--   SprayAssist.Cfg                                   tuning (read at use time)
--   SprayAssist.pick(fires, hx, hy, hz, lx, lz) -> number?
--       touch auto-aim: index of the burning part to lock onto. fires = { {x, y, z} }, (hx, hy, hz) = head,
--       (lx, lz) = the camera's flat heading. In range (Cfg.LockRange) and inside the wide flat cone
--       (Cfg.LockHalfDeg each side); most centred first, then nearest.
--   SprayAssist.validLock(dist, offDeg) -> boolean
--       server: a client's lock is believable (distance to the part's nearest point, angle between the
--       aim the client sent and the head -> part direction)
--   SprayAssist.launch(dx, dy, dz, speed, g) -> (ux, uy, uz)?
--       the stream's launch direction (low arc) that lands at (dx, dy, dz) from the nozzle; nil = out of reach
--   SprayAssist.ready(hand, handFoam, back, backFoam) -> "keep" | "swap" | "give" | "refill" | "none"
--       on arrival: what makes SPRAY available. keep = already sprayable (or an axe: CHOP is a choice);
--       swap = the sprayer is on your back; give = empty hands / a non-tool (oxygen tank) in hand and a free
--       back: a fresh extinguisher; refill = an empty extinguisher in hand; none = leave it
--   SprayAssist.lockBucket(n) -> string               "lock0" | "lock1-3" | "lock4+" (a small constant set)
local SprayAssist = {}

SprayAssist.Cfg = {
	LockRange = 40, -- studs: touch auto-aim reach (the old assist: 30)
	LockHalfDeg = 50, -- each side of the camera's flat heading: a 100 degree cone (the old assist: 40 each side, 30 studs)
	ServerRangeSlack = 1.2, -- the server accepts a lock up to LockRange x this (HoseRange 42 -> ~48 on touch)
	ServerMaxOffDeg = 50, -- and only if the aim the client sent points within this of the part
	WaterLandsShort = 8, -- studs: a lock beyond the hose's reach lands its water from this far in front of the part
}

local function dot2(ax: number, az: number, bx: number, bz: number): number
	return ax * bx + az * bz
end

function SprayAssist.pick(fires: { { number } }, hx: number, hy: number, hz: number, lx: number, lz: number): number?
	local Cfg = SprayAssist.Cfg
	local lm = math.sqrt(lx * lx + lz * lz)
	if lm < 1e-3 then
		return nil
	end
	lx, lz = lx / lm, lz / lm
	local minDot = math.cos(math.rad(Cfg.LockHalfDeg))
	local best: number? = nil
	local bestScore = -math.huge
	for i, f in fires do
		local dx, dy, dz = f[1] - hx, f[2] - hy, f[3] - hz
		local dist = math.sqrt(dx * dx + dy * dy + dz * dz)
		if dist > 0.5 and dist <= Cfg.LockRange then
			local fm = math.sqrt(dx * dx + dz * dz)
			local d = if fm > 1e-3 then dot2(dx / fm, dz / fm, lx, lz) else 1
			if d >= minDot then
				local score = d * 2 - dist / Cfg.LockRange -- centred first, then nearest
				if score > bestScore then
					bestScore, best = score, i
				end
			end
		end
	end
	return best
end

function SprayAssist.validLock(dist: number, offDeg: number): boolean
	local Cfg = SprayAssist.Cfg
	return type(dist) == "number"
		and type(offDeg) == "number"
		and dist == dist
		and dist >= 0
		and dist <= Cfg.LockRange * Cfg.ServerRangeSlack
		and offDeg <= Cfg.ServerMaxOffDeg
end

function SprayAssist.launch(dx: number, dy: number, dz: number, speed: number, g: number): (number?, number?, number?)
	local r = math.sqrt(dx * dx + dz * dz)
	if speed <= 0 then
		return nil
	end
	if r < 1e-3 or g <= 0 then
		local m = math.sqrt(dx * dx + dy * dy + dz * dz)
		if m < 1e-3 then
			return nil
		end
		return dx / m, dy / m, dz / m
	end
	local v2 = speed * speed
	local disc = v2 * v2 - g * (g * r * r + 2 * dy * v2)
	if disc < 0 then
		return nil
	end
	local theta = math.atan((v2 - math.sqrt(disc)) / (g * r)) -- the low arc
	local c, s = math.cos(theta), math.sin(theta)
	return dx / r * c, s, dz / r * c
end

local SPRAYS = { Hose = true, Extinguisher = true }
local AXES = { Axe = true, FireAxe = true, GoldenAxe = true }

function SprayAssist.ready(hand: string?, handFoam: number?, back: string?, backFoam: number?): string
	hand = if hand == "" then nil else hand
	back = if back == "" then nil else back
	local function sprays(id: string?, foam: number?): boolean
		return id ~= nil and SPRAYS[id] == true and (id == "Hose" or (foam or 0) > 0)
	end
	if sprays(hand, handFoam) then
		return "keep"
	end
	if hand and AXES[hand] then
		return "keep" -- the axe is a choice (CHOP); the SWAP / HOSE buttons are right there
	end
	if sprays(back, backFoam) then
		return "swap"
	end
	if hand == "Extinguisher" then
		return "refill"
	end
	if hand == nil or back == nil then
		return "give" -- empty hands, or a non-tool in hand that goes on the free back
	end
	return "none"
end

function SprayAssist.lockBucket(n: number): string
	if n <= 0 then
		return "lock0"
	elseif n <= 3 then
		return "lock1-3"
	end
	return "lock4+"
end

return SprayAssist
