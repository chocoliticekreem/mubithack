--!strict
-- FireSim [owner: G1]. Pure fire maths for FireService: no Roblox APIs, so game/tests/fire_sim.spec.luau
-- runs it under the plain `luau` CLI. FireService owns the Roblox side (tags, attributes, signals).
--
--   FireSim.buildNeighbors(positions: { Pos }, radius: number): { { number } }   -- spatial hash, O(n)
--   FireSim.step(burning: { [Cell]: true }, dt: number, p: Params): ({ Edge }, { Cell })
--       burns fuel, heats idle neighbours, grows heat. Returns (ignitions, charred). It never changes
--       `state` and never adds to `burning`: the caller applies both after the loop.
--   FireSim.cool(cell: Cell, litres: number, p: Params): boolean   -- true = the fire is out now
--   FireSim.levelFor(state: number, heat: number): number          -- 0 (not burning) or 1..3
--   FireSim.inCone(dx, dy, dz, ax, ay, az, range, cosMin): boolean -- is offset d inside the spray cone
--   FireSim.canIgnite(locCount, locCap, total, globalCap): boolean -- per-instance + global fire budget
--
-- A Cell may carry extra fields (FireService adds part, level, location, cause); FireSim only touches
-- heat, fuel, state and neighbors.

local FireSim = {}

FireSim.IDLE = 0
FireSim.BURNING = 1
FireSim.CHARRED = 2

export type Pos = { x: number, y: number, z: number }
export type Cell = { heat: number, fuel: number, state: number, neighbors: { Cell } }
export type Edge = { from: Cell, to: Cell }
export type Params = {
	SpreadRadius: number,
	SpreadHeatPerSecond: number,
	GrowPerSecond: number,
	IgniteAt: number,
	ExtinguishAt: number,
	CoolPerLitre: number,
}

local function bucket(v: number, size: number): number
	return math.floor(v / size)
end

function FireSim.buildNeighbors(positions: { Pos }, radius: number): { { number } }
	local grid: { [string]: { number } } = {}
	for i, p in positions do
		local key = `{bucket(p.x, radius)},{bucket(p.y, radius)},{bucket(p.z, radius)}`
		local list = grid[key]
		if not list then
			list = {}
			grid[key] = list
		end
		table.insert(list, i)
	end
	local r2 = radius * radius
	local out: { { number } } = {}
	for i, p in positions do
		local mine: { number } = {}
		local bx, by, bz = bucket(p.x, radius), bucket(p.y, radius), bucket(p.z, radius)
		for dx = -1, 1 do
			for dy = -1, 1 do
				for dz = -1, 1 do
					for _, j in grid[`{bx + dx},{by + dy},{bz + dz}`] or {} do
						if j ~= i then
							local q = positions[j]
							local ex, ey, ez = q.x - p.x, q.y - p.y, q.z - p.z
							if ex * ex + ey * ey + ez * ez <= r2 then
								table.insert(mine, j)
							end
						end
					end
				end
			end
		end
		out[i] = mine
	end
	return out
end

function FireSim.levelFor(state: number, heat: number): number
	if state ~= FireSim.BURNING then
		return 0
	elseif heat > 80 then
		return 3
	elseif heat > 50 then
		return 2
	end
	return 1
end

function FireSim.step(burning: { [Cell]: true }, dt: number, p: Params): ({ Edge }, { Cell })
	local lit: { Edge } = {}
	local charred: { Cell } = {}
	local seen: { [Cell]: true } = {}
	for c in burning do
		c.fuel -= dt
		if c.fuel <= 0 then
			table.insert(charred, c)
			continue
		end
		for _, n in c.neighbors do
			if n.state == FireSim.IDLE then
				n.heat += p.SpreadHeatPerSecond * dt
				if n.heat >= p.IgniteAt and not seen[n] then
					seen[n] = true
					table.insert(lit, { from = c, to = n })
				end
			end
		end
		c.heat = math.min(100, c.heat + p.GrowPerSecond * dt)
	end
	return lit, charred
end

function FireSim.cool(cell: Cell, litres: number, p: Params): boolean
	cell.heat -= p.CoolPerLitre * litres
	return cell.heat <= p.ExtinguishAt
end

function FireSim.inCone(dx: number, dy: number, dz: number, ax: number, ay: number, az: number, range: number, cosMin: number): boolean
	local m = math.sqrt(dx * dx + dy * dy + dz * dz)
	if m > range then
		return false
	end
	if m < 1e-3 then
		return true
	end
	local am = math.sqrt(ax * ax + ay * ay + az * az)
	if am < 1e-6 then
		return false
	end
	return (dx * ax + dy * ay + dz * az) / (m * am) >= cosMin
end

-- Fire budget: every location (mission instance) has its own cap, so one runaway fire in a parallel
-- mission can't use up the server-wide cap and freeze spread in everyone else's. The global cap is a
-- last-resort safety net above the sum of normal per-instance usage.
function FireSim.canIgnite(locCount: number, locCap: number, total: number, globalCap: number): boolean
	return locCount < locCap and total < globalCap
end

return FireSim
