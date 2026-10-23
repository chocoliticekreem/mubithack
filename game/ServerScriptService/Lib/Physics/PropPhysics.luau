--!strict
-- PropPhysics [owner: Physics]. Pure maths and bookkeeping for PhysicsFxService (spec-tested by
-- game/tests/physics.spec.luau). NO Roblox APIs (no Vector3, Instance, task); numbers and tables only.
--
--   PropPhysics.normalize(name): string                         -- "Park_Bench2" -> "parkbench"
--   PropPhysics.isKnockableName(name, names, exclude): boolean  -- suffix match on normalized names
--   PropPhysics.cellKey(x, z, cell): number                     -- integer key for a 2D grid cell
--   PropPhysics.Grid.new(cell) -> grid:insert(id, x, z), :remove(id), :query(x, z, r): {id}
--   PropPhysics.Budget.new(perArea, perServer) -> budget:canWake(area), :wake(id, area, t),
--     :sleep(id), :touch(id, t), :evict(area, isPinned?): id?, :count(area?), :isAwake(id)
--   PropPhysics.shouldSleep(dist, speed, idle, dt, cfg): (sleepNow: boolean, idle': number)
--   PropPhysics.landingSeconds(fallSpeed, cfg): number          -- 0 = no ragdoll
--   PropPhysics.slipRoll(speed, dt, roll, cfg): boolean
--   PropPhysics.clamp3(x, y, z, max): (x, y, z)
--   PropPhysics.truckFling(vx, vy, vz, cfg, spin): (x, y, z)     -- velocity for a ploughed prop
--   PropPhysics.blast(dx, dy, dz, radius, power): (x, y, z)     -- prop velocity from a blast offset
--   PropPhysics.impulseRagdollSeconds(mag, cfg): number          -- 0 = just a shove
--   PropPhysics.popWord(kind, roll): string                      -- comedic pop text

local PropPhysics = {}

-- names -------------------------------------------------------------------------------------------
function PropPhysics.normalize(name: string): string
	local s = string.lower(name)
	s = string.gsub(s, "[^%a]", "") -- drop digits, underscores, spaces, punctuation
	return s
end

-- `names` and `exclude` are arrays of already-normalized strings. A name matches when its
-- normalized form ENDS with a known name ("parkbench" -> "bench") unless it contains an excluded
-- fragment ("fusebox", "hitbox").
function PropPhysics.isKnockableName(name: string, names: { string }, exclude: { string }?): boolean
	local n = PropPhysics.normalize(name)
	if n == "" then
		return false
	end
	if exclude then
		for _, bad in exclude do
			if string.find(n, bad, 1, true) then
				return false
			end
		end
	end
	for _, k in names do
		if #n >= #k and string.sub(n, #n - #k + 1) == k then
			return true
		end
	end
	return false
end

-- spatial grid ------------------------------------------------------------------------------------
local OFFSET = 1048576 -- 2^20: cells in [-2^20, 2^20) per axis fit an exact double key

function PropPhysics.cellKey(x: number, z: number, cell: number): number
	local cx = math.floor(x / cell) + OFFSET
	local cz = math.floor(z / cell) + OFFSET
	return cx * (OFFSET * 2) + cz
end

export type Grid = {
	cell: number,
	cells: { [number]: { [any]: boolean } },
	where: { [any]: number },
	insert: (self: Grid, id: any, x: number, z: number) -> (),
	remove: (self: Grid, id: any) -> (),
	query: (self: Grid, x: number, z: number, r: number) -> { any },
}

local Grid = {}
Grid.__index = Grid
PropPhysics.Grid = Grid

function Grid.new(cell: number): Grid
	return setmetatable({ cell = cell, cells = {}, where = {} }, Grid) :: any
end

function Grid.insert(self: Grid, id: any, x: number, z: number)
	Grid.remove(self, id)
	local k = PropPhysics.cellKey(x, z, self.cell)
	local bucket = self.cells[k]
	if not bucket then
		bucket = {}
		self.cells[k] = bucket
	end
	bucket[id] = true
	self.where[id] = k
end

function Grid.remove(self: Grid, id: any)
	local k = self.where[id]
	if k == nil then
		return
	end
	self.where[id] = nil
	local bucket = self.cells[k]
	if bucket then
		bucket[id] = nil
		if next(bucket) == nil then
			self.cells[k] = nil
		end
	end
end

-- Every id in a cell overlapping the square [x-r, x+r] x [z-r, z+r] (callers do the exact distance).
function Grid.query(self: Grid, x: number, z: number, r: number): { any }
	local out = {}
	local c = self.cell
	for cx = math.floor((x - r) / c), math.floor((x + r) / c) do
		for cz = math.floor((z - r) / c), math.floor((z + r) / c) do
			local bucket = self.cells[(cx + OFFSET) * (OFFSET * 2) + (cz + OFFSET)]
			if bucket then
				for id in bucket do
					table.insert(out, id)
				end
			end
		end
	end
	return out
end

-- awake-prop budget -------------------------------------------------------------------------------
export type Budget = {
	perArea: number,
	perServer: number,
	total: number,
	areas: { [any]: number },
	awake: { [any]: { area: any, t: number } },
	canWake: (self: Budget, area: any) -> boolean,
	wake: (self: Budget, id: any, area: any, t: number) -> boolean,
	sleep: (self: Budget, id: any) -> boolean,
	touch: (self: Budget, id: any, t: number) -> (),
	evict: (self: Budget, area: any?, isPinned: ((id: any) -> boolean)?) -> any?,
	count: (self: Budget, area: any?) -> number,
	isAwake: (self: Budget, id: any) -> boolean,
}

local Budget = {}
Budget.__index = Budget
PropPhysics.Budget = Budget

function Budget.new(perArea: number, perServer: number): Budget
	return setmetatable({ perArea = perArea, perServer = perServer, total = 0, areas = {}, awake = {} }, Budget) :: any
end

function Budget.canWake(self: Budget, area: any): boolean
	return self.total < self.perServer and (self.areas[area] or 0) < self.perArea
end

-- Marks `id` awake in `area`. False (and no change) when a cap is full; true when already awake.
function Budget.wake(self: Budget, id: any, area: any, t: number): boolean
	local cur = self.awake[id]
	if cur then
		cur.t = t
		return true
	end
	if not Budget.canWake(self, area) then
		return false
	end
	self.awake[id] = { area = area, t = t }
	self.areas[area] = (self.areas[area] or 0) + 1
	self.total += 1
	return true
end

function Budget.sleep(self: Budget, id: any): boolean
	local cur = self.awake[id]
	if not cur then
		return false
	end
	self.awake[id] = nil
	local n = (self.areas[cur.area] or 1) - 1
	self.areas[cur.area] = if n > 0 then n else nil
	self.total -= 1
	return true
end

function Budget.touch(self: Budget, id: any, t: number)
	local cur = self.awake[id]
	if cur then
		cur.t = t
	end
end

-- The least recently touched awake id (in `area` when the AREA cap is the problem, else anywhere),
-- skipping ids `isPinned` says must stay awake. Does not sleep it; the caller does.
function Budget.evict(self: Budget, area: any?, isPinned: ((id: any) -> boolean)?): any?
	local best, bestT = nil, math.huge
	for id, rec in self.awake do
		if (area == nil or rec.area == area) and rec.t < bestT and not (isPinned and isPinned(id)) then
			best, bestT = id, rec.t
		end
	end
	return best
end

function Budget.count(self: Budget, area: any?): number
	if area == nil then
		return self.total
	end
	return self.areas[area] or 0
end

function Budget.isAwake(self: Budget, id: any): boolean
	return self.awake[id] ~= nil
end

-- sleeping ----------------------------------------------------------------------------------------
-- cfg: SleepRadius, ForceSleepRadius, SleepSpeed, SleepAfter. `dt` is the time since the last check.
-- Returns whether to sleep now and the new idle time.
function PropPhysics.shouldSleep(dist: number, speed: number, idle: number, dt: number, cfg: any): (boolean, number)
	if dist >= cfg.ForceSleepRadius then
		return true, 0
	end
	if dist < cfg.SleepRadius or speed > cfg.SleepSpeed then
		return false, 0
	end
	local nextIdle = idle + dt
	if nextIdle >= cfg.SleepAfter then
		return true, 0
	end
	return false, nextIdle
end

-- players -----------------------------------------------------------------------------------------
-- cfg: HardLandingSpeed, SplatLandingSpeed, LandingRagdollMin, LandingRagdollMax.
-- Linear from Min seconds at HardLandingSpeed to Max seconds at SplatLandingSpeed and beyond.
function PropPhysics.landingSeconds(fallSpeed: number, cfg: any): number
	if fallSpeed ~= fallSpeed or fallSpeed < cfg.HardLandingSpeed then
		return 0
	end
	local span = math.max(1e-3, cfg.SplatLandingSpeed - cfg.HardLandingSpeed)
	local t = math.clamp((fallSpeed - cfg.HardLandingSpeed) / span, 0, 1)
	return cfg.LandingRagdollMin + (cfg.LandingRagdollMax - cfg.LandingRagdollMin) * t
end

-- cfg: SlipSpeed, SlipChancePerSecond. `roll` is a uniform [0, 1) sample.
function PropPhysics.slipRoll(speed: number, dt: number, roll: number, cfg: any): boolean
	if speed < cfg.SlipSpeed then
		return false
	end
	local p = 1 - (1 - math.clamp(cfg.SlipChancePerSecond, 0, 1)) ^ math.max(dt, 0)
	return roll < p
end

-- cfg: ImpulseRagdollAt, ImpulseRagdollMin, ImpulseRagdollMax, MaxImpulse.
function PropPhysics.impulseRagdollSeconds(mag: number, cfg: any): number
	if mag ~= mag or mag < cfg.ImpulseRagdollAt then
		return 0
	end
	local span = math.max(1e-3, cfg.MaxImpulse - cfg.ImpulseRagdollAt)
	local t = math.clamp((mag - cfg.ImpulseRagdollAt) / span, 0, 1)
	return cfg.ImpulseRagdollMin + (cfg.ImpulseRagdollMax - cfg.ImpulseRagdollMin) * t
end

-- vectors as numbers --------------------------------------------------------------------------------
function PropPhysics.clamp3(x: number, y: number, z: number, max: number): (number, number, number)
	if x ~= x or y ~= y or z ~= z then
		return 0, 0, 0
	end
	local m = math.sqrt(x * x + y * y + z * z)
	if m > max and m > 0 then
		local s = max / m
		return x * s, y * s, z * s
	end
	return x, y, z
end

-- A prop hit by a truck moving at (vx, vy, vz): carried forward faster than the truck, kicked up,
-- with a sideways wobble from `spin` in [-1, 1]. cfg: TruckFlingCarry, TruckFlingUp, TruckFlingSide,
-- MaxPropSpeed.
function PropPhysics.truckFling(vx: number, vy: number, vz: number, cfg: any, spin: number): (number, number, number)
	local h = math.sqrt(vx * vx + vz * vz)
	local sx, sz = 0, 0
	if h > 1e-3 then
		-- sideways = forward rotated 90 degrees in the ground plane
		sx, sz = -vz / h, vx / h
	end
	local side = cfg.TruckFlingSide * spin
	local x = vx * cfg.TruckFlingCarry + sx * side
	local z = vz * cfg.TruckFlingCarry + sz * side
	local y = math.max(vy, 0) + cfg.TruckFlingUp + h * 0.25
	return PropPhysics.clamp3(x, y, z, cfg.MaxPropSpeed)
end

-- Velocity for a prop at offset (dx, dy, dz) from a blast centre: away and up, full power at the
-- centre, falling to 25% at the edge, 0 outside.
function PropPhysics.blast(dx: number, dy: number, dz: number, radius: number, power: number): (number, number, number)
	local d = math.sqrt(dx * dx + dy * dy + dz * dz)
	if radius <= 0 or d >= radius then
		return 0, 0, 0
	end
	local s = power * (1 - 0.75 * d / radius)
	local ux, uy, uz = 0, 1, 0
	if d > 1e-3 then
		ux, uy, uz = dx / d, dy / d, dz / d
	end
	uy += 0.8 -- comedic lift
	local m = math.sqrt(ux * ux + uy * uy + uz * uz)
	return ux / m * s, uy / m * s, uz / m * s
end

-- pops ----------------------------------------------------------------------------------------------
local WORDS: { [string]: { string } } = {
	truck = { "BOING!", "YEET!", "BONK!", "WHEEE!" },
	runover = { "BOING!", "BOING!", "SPLAT!" },
	axe = { "BONK!", "THWACK!", "BONK!" },
	hose = { "SPLOOSH!", "WHOOSH!" },
	blast = { "KABOOM!", "BOING!", "YEET!" },
	land = { "OOF!", "SPLAT!", "BONK!" },
	slip = { "WHOOPS!", "WAAH!", "SLIP!" },
	shove = { "BOING!", "BONK!" },
}

function PropPhysics.popWord(kind: string, roll: number): string
	local list = WORDS[kind] or WORDS.shove
	local i = math.clamp(math.floor(roll * #list) + 1, 1, #list)
	return list[i]
end

return PropPhysics
