--!strict
-- Structure [owner: Structure agent]. PURE building-integrity maths for StructureService (no Roblox APIs,
-- no requires, so game/tests/structure.spec.luau runs it with the `luau` CLI).
-- A structure is a list of chunks (wall / partition / roof / floor / ground / window), each an
-- axis-aligned box in plain numbers with hp 0..1. Fire wears hp down, charring drops it to CharredHp,
-- and chunks fail when burnt through or when the chunks holding them up are gone.
--
--   Structure.classify(name, isWindow): Kind?            -- part name -> kind (nil = not structural)
--   Structure.new(boxes: { Box }, cfg): Struct            -- builds chunks, grounds and support links
--   Structure.setBurning(s, id, level)                    -- 0 = out
--   Structure.setCharred(s, id, cfg)
--   Structure.tick(s, dt, cfg)                            -- burn hp down, heat windows
--   Structure.supportRatio(s, id): number                 -- 0..1, 1 = grounded / needs no support
--   Structure.failures(s, cfg, roll, dt): { number }      -- chunk ids that should collapse now
--   Structure.windowsToShatter(s, cfg): { number }
--   Structure.collapse(s, id) / Structure.shatter(s, id)
--   Structure.integrity(s): number                        -- 0..100 integer, weighted by kind
--   Structure.isTotalLoss(integrity, cfg) / Structure.saved(integrity, cfg)
--   Structure.shellPlan(s): { number }                    -- total loss: roof, upper floors, partitions
--   Structure.cluster(s, ids, radius): { { number } }     -- group failures into one creak/crash each
--   Structure.hurtAmount(dist, radius, maxDamage): number
--   Structure.burningCount(s): number
-- cfg keys used (StructureConfig): GroundTolerance, SupportGap, SupportDrop, SupportReach, MaxSupports,
--   Weight { [Kind]: number }, BurnRate, CharredHp, FailHp { [Kind]: number }, SupportMin,
--   CharredFallChance { [Kind]: number }, WindowHeatRadius, ShatterHeat, TotalLossAt, SavedAt

export type Kind = "wall" | "partition" | "roof" | "floor" | "ground" | "window"

export type Box = { kind: Kind, x: number, y: number, z: number, hx: number, hy: number, hz: number }

export type Chunk = {
	id: number,
	kind: Kind,
	x: number,
	y: number,
	z: number,
	hx: number,
	hy: number,
	hz: number,
	weight: number,
	hp: number,
	burning: number, -- FireLevel 0..3
	charred: boolean,
	collapsed: boolean,
	shattered: boolean,
	heat: number, -- windows only
	grounded: boolean,
	supports: { number },
}

export type Struct = {
	chunks: { Chunk },
	totalWeight: number,
	minY: number,
	lost: boolean,
}

local Structure = {}

local function starts(s: string, prefix: string): boolean
	return string.sub(s, 1, #prefix) == prefix
end

function Structure.classify(name: string, isWindow: boolean): Kind?
	if isWindow then
		return "window"
	end
	local n = string.lower(name)
	if starts(n, "partition") then
		return "partition"
	elseif starts(n, "wall") then
		return "wall"
	elseif starts(n, "roof") or starts(n, "ceiling") or starts(n, "gable") or starts(n, "ridge") then
		return "roof"
	elseif starts(n, "floor") then
		return "floor" -- Structure.new turns the lowest floors into "ground"
	end
	return nil
end

-- Horizontal gap between two boxes (0 when they overlap in X/Z).
local function gapXZ(a: Chunk, b: Chunk): number
	local dx = math.max(0, math.abs(a.x - b.x) - a.hx - b.hx)
	local dz = math.max(0, math.abs(a.z - b.z) - a.hz - b.hz)
	return math.sqrt(dx * dx + dz * dz)
end
Structure.gapXZ = gapXZ

-- roofs only end up supporting things above them (a ridge cap on its slopes)
local CAN_SUPPORT: { [string]: boolean } = { wall = true, partition = true, floor = true, ground = true, roof = true }

function Structure.new(boxes: { Box }, cfg: any): Struct
	local chunks: { Chunk } = {}
	local minY = math.huge
	for _, b in boxes do
		if b.kind ~= "window" then
			minY = math.min(minY, b.y - b.hy)
		end
	end
	if minY == math.huge then
		minY = 0
	end
	local total = 0
	for i, b in boxes do
		local bottom = b.y - b.hy
		local grounded = bottom <= minY + cfg.GroundTolerance
		local kind: Kind = b.kind
		if kind == "floor" and grounded then
			kind = "ground"
		end
		local w = if kind == "window" then 0 else (cfg.Weight[kind] or 1)
		total += w
		chunks[i] = {
			id = i,
			kind = kind,
			x = b.x,
			y = b.y,
			z = b.z,
			hx = b.hx,
			hy = b.hy,
			hz = b.hz,
			weight = w,
			hp = 1,
			burning = 0,
			charred = false,
			collapsed = false,
			shattered = false,
			heat = 0,
			grounded = grounded and kind ~= "window",
			supports = {},
		}
	end
	-- Support links: anything off the ground rests on walls/floors whose top is near its bottom.
	for _, c in chunks do
		if c.grounded then
			continue
		end
		local bottom = c.y - c.hy
		local cand: { { id: number, d: number } } = {}
		if c.kind == "window" then
			-- a window hangs in its wall: the walls it touches are its frame
			for _, o in chunks do
				if (o.kind == "wall" or o.kind == "partition") and math.abs(o.y - c.y) < o.hy + c.hy then
					local g = gapXZ(c, o)
					if g <= 1 then
						table.insert(cand, { id = o.id, d = g })
					end
				end
			end
		else
			for _, o in chunks do
				if o == c or not CAN_SUPPORT[o.kind] or o.y >= c.y then
					continue
				end
				local top = o.y + o.hy
				if top < bottom - cfg.SupportDrop or top > bottom + cfg.SupportGap then
					continue
				end
				local g = gapXZ(c, o)
				if g <= cfg.SupportReach then
					table.insert(cand, { id = o.id, d = g + (bottom - top) * 0.1 })
				end
			end
		end
		table.sort(cand, function(a: { id: number, d: number }, b: { id: number, d: number }): boolean
			if a.d ~= b.d then
				return a.d < b.d
			end
			return a.id < b.id
		end)
		for k = 1, math.min(#cand, cfg.MaxSupports) do
			table.insert(c.supports, cand[k].id)
		end
	end
	return { chunks = chunks, totalWeight = total, minY = minY, lost = false }
end

function Structure.setBurning(s: Struct, id: number, level: number)
	local c = s.chunks[id]
	if c and not c.collapsed then
		c.burning = math.clamp(math.floor(level), 0, 3)
	end
end

function Structure.setCharred(s: Struct, id: number, cfg: any)
	local c = s.chunks[id]
	if c then
		c.charred = true
		c.burning = 0
		c.hp = math.min(c.hp, cfg.CharredHp)
	end
end

function Structure.burningCount(s: Struct): number
	local n = 0
	for _, c in s.chunks do
		if c.burning > 0 and not c.collapsed then
			n += 1
		end
	end
	return n
end

function Structure.tick(s: Struct, dt: number, cfg: any)
	local hot: { Chunk } = {}
	for _, c in s.chunks do
		if c.burning > 0 and not c.collapsed then
			c.hp = math.max(0, c.hp - cfg.BurnRate * c.burning * dt)
			table.insert(hot, c)
		end
	end
	if #hot == 0 then
		return
	end
	local r = cfg.WindowHeatRadius
	for _, w in s.chunks do
		if w.kind ~= "window" or w.shattered then
			continue
		end
		for _, c in hot do
			local dx, dy, dz = c.x - w.x, c.y - w.y, c.z - w.z
			if dx * dx + dy * dy + dz * dz <= r * r then
				w.heat += c.burning * dt
			end
		end
	end
end

function Structure.supportRatio(s: Struct, id: number): number
	local c = s.chunks[id]
	if not c or c.grounded or #c.supports == 0 then
		return 1
	end
	local sum = 0
	for _, sid in c.supports do
		local o = s.chunks[sid]
		if not o.collapsed then
			sum += o.hp
		end
	end
	return sum / #c.supports
end

-- `roll()` returns 0..1 (Random:NextNumber in the service, a stub in specs).
function Structure.failures(s: Struct, cfg: any, roll: () -> number, dt: number): { number }
	local out: { number } = {}
	for _, c in s.chunks do
		if c.collapsed or c.kind == "window" or c.kind == "ground" then
			continue
		end
		local fail = false
		local failHp = cfg.FailHp[c.kind]
		if failHp and c.hp <= failHp then
			fail = true
		elseif Structure.supportRatio(s, c.id) < cfg.SupportMin then
			fail = true
		elseif c.charred and not s.lost then
			local chance = cfg.CharredFallChance[c.kind] or 0
			if chance > 0 and roll() < chance * dt then
				fail = true
			end
		end
		if fail then
			table.insert(out, c.id)
		end
	end
	return out
end

function Structure.windowsToShatter(s: Struct, cfg: any): { number }
	local out: { number } = {}
	for _, w in s.chunks do
		if w.kind == "window" and not w.shattered then
			if w.heat >= cfg.ShatterHeat or (#w.supports > 0 and Structure.supportRatio(s, w.id) <= 0) then
				table.insert(out, w.id)
			end
		end
	end
	return out
end

function Structure.collapse(s: Struct, id: number)
	local c = s.chunks[id]
	if c then
		c.collapsed = true
		c.burning = 0
		c.hp = 0
		if c.kind == "window" then
			c.shattered = true
		end
	end
end

function Structure.shatter(s: Struct, id: number)
	local c = s.chunks[id]
	if c then
		c.shattered = true
	end
end

function Structure.integrity(s: Struct): number
	if s.lost then
		return 0
	end
	if s.totalWeight <= 0 then
		return 100
	end
	local sum = 0
	for _, c in s.chunks do
		if not c.collapsed then
			sum += c.weight * c.hp
		end
	end
	return math.clamp(math.floor(sum / s.totalWeight * 100 + 0.5), 0, 100)
end

function Structure.isTotalLoss(integrity: number, cfg: any): boolean
	return integrity <= cfg.TotalLossAt
end

-- Mission scoring: "save the building" star.
function Structure.saved(integrity: number, cfg: any): boolean
	return integrity >= cfg.SavedAt
end

-- Total loss: everything above ground except the exterior walls comes down (a blackened shell).
function Structure.shellPlan(s: Struct): { number }
	local out: { number } = {}
	for _, c in s.chunks do
		if not c.collapsed and (c.kind == "roof" or c.kind == "floor" or c.kind == "partition") then
			table.insert(out, c.id)
		end
	end
	return out
end

-- Greedy single-link clusters: ids whose centres are within `radius` of any member join one group.
function Structure.cluster(s: Struct, ids: { number }, radius: number): { { number } }
	local groups: { { number } } = {}
	local seen: { [number]: boolean } = {}
	local r2 = radius * radius
	for _, start in ids do
		if seen[start] then
			continue
		end
		seen[start] = true
		local g = { start }
		local i = 1
		while i <= #g do
			local a = s.chunks[g[i]]
			for _, other in ids do
				if not seen[other] then
					local b = s.chunks[other]
					local dx, dy, dz = a.x - b.x, a.y - b.y, a.z - b.z
					if dx * dx + dy * dy + dz * dz <= r2 then
						seen[other] = true
						table.insert(g, other)
					end
				end
			end
			i += 1
		end
		table.insert(groups, g)
	end
	return groups
end

function Structure.hurtAmount(dist: number, radius: number, maxDamage: number): number
	if radius <= 0 or dist >= radius then
		return 0
	end
	return math.floor(maxDamage * (1 - math.max(0, dist) / radius) + 0.5)
end

return Structure
