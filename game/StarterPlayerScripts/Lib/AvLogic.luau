--!strict
-- AvLogic [owner: AV lane]. Pure helpers for GraphicsController / AudioController (no Roblox APIs,
-- so game/tests/av.spec.luau runs them under the `luau` CLI). Positions are plain {x, y, z} tables.

local AvLogic = {}

export type P3 = { x: number, y: number, z: number }

local function dist2(a: P3, b: P3): number
	local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
	return dx * dx + dy * dy + dz * dz
end

-- Which preset a player should see. Priority: an explicit per-player override, then the instance's
-- location mapped through `byLocation`, then the server-wide default, then `fallback`.
-- `exists(name)` filters out typos so a bad attribute can never blank the lighting.
function AvLogic.pickPreset(
	override: string?,
	locationId: string?,
	byLocation: { [string]: string },
	serverDefault: string?,
	fallback: string,
	exists: (string) -> boolean
): string
	if override and override ~= "" and exists(override) then
		return override
	end
	if locationId then
		local mapped = byLocation[locationId]
		if mapped and exists(mapped) then
			return mapped
		end
	end
	if serverDefault and exists(serverDefault) then
		return serverDefault
	end
	return fallback
end

-- Nearest-first pick of up to `max` points within `radius` of `from`, skipping any point within
-- `cluster` studs of one already picked (one crackle per fire cluster). Returns indices into `pts`.
function AvLogic.pickNearest(from: P3, pts: { P3 }, max: number, radius: number, cluster: number): { number }
	local r2 = radius * radius
	local cands: { { i: number, d: number } } = {}
	for i, p in pts do
		local d = dist2(from, p)
		if d <= r2 then
			table.insert(cands, { i = i, d = d })
		end
	end
	table.sort(cands, function(a, b)
		return a.d < b.d
	end)
	local picked: { number } = {}
	local c2 = cluster * cluster
	for _, c in cands do
		if #picked >= max then
			break
		end
		local near = false
		for _, j in picked do
			if dist2(pts[c.i], pts[j]) < c2 then
				near = true
				break
			end
		end
		if not near then
			table.insert(picked, c.i)
		end
	end
	return picked
end

-- 0..1 smoke-overlay weight from nearby fire count and whether the camera is under a roof.
-- Outdoors the smoke only thickens a little; indoors next to several fires it goes full "smoke room".
function AvLogic.smokeWeight(nearbyFires: number, indoors: boolean, fullAt: number): number
	if nearbyFires <= 0 then
		return 0
	end
	local w = math.clamp(nearbyFires / math.max(1, fullAt), 0, 1)
	if not indoors then
		w *= 0.35
	end
	return w
end

-- Linear blend of two numbers.
function AvLogic.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- 2D roar bed volume from burning count.
function AvLogic.roarVolume(burning: number, fullAt: number, maxVolume: number): number
	if burning <= 0 then
		return 0
	end
	return maxVolume * math.clamp(burning / math.max(1, fullAt), 0, 1)
end

-- Rescue ding pitch: rises `step` per consecutive rescue, capped at +50%.
function AvLogic.streakPitch(streak: number, step: number): number
	return 1 + math.min(0.5, math.max(0, streak - 1) * step)
end

-- Token-bucket style limiter state for "at most n per second". Returns (allowed, newState).
export type Rate = { tokens: number, stamp: number }
function AvLogic.rateAllow(state: Rate?, now: number, perSecond: number): (boolean, Rate)
	local s: Rate = state or { tokens = perSecond, stamp = now }
	local tokens = math.min(perSecond, s.tokens + (now - s.stamp) * perSecond)
	if tokens < 1 then
		return false, { tokens = tokens, stamp = now }
	end
	return true, { tokens = tokens - 1, stamp = now }
end

-- Music track for a Types.RoundState ("Lobby" | "Alarm" | "Active" | "Results"; nil = lobby).
function AvLogic.musicFor(roundState: string?): string
	if roundState == "Results" then
		return "ResultsMusic"
	end
	if roundState == "Alarm" or roundState == "Active" then
		return "MissionMusic"
	end
	return "LobbyMusic"
end

-- True when a world point is inside an axis-aligned box given by centre and half-size (plus margin).
function AvLogic.inBox(p: P3, centre: P3, half: P3, margin: number): boolean
	return math.abs(p.x - centre.x) <= half.x + margin
		and math.abs(p.y - centre.y) <= half.y + margin
		and math.abs(p.z - centre.z) <= half.z + margin
end

return AvLogic
