--!strict
-- HeatMath [owner: Heat lane]. Pure per-player heat maths (no Roblox APIs) so game/tests/heat.spec
-- can run it under the plain `luau` CLI. HeatService feeds it distances and flags; all numbers come
-- from Config/HeatConfig (passed in as `cfg`).
--
--   HeatMath.sourceRate(dist, fireLevel, occluded, cfg) -> heat/s from one Burning part
--   HeatMath.gainRate(sources, cfg)                     -> heat/s from all of them (capped)
--   HeatMath.step(heat, gain, dt, cooling, cfg)         -> new heat, clamped 0..cfg.DownAt
--   HeatMath.stage(heat, cfg)                           -> 0 ok, 1 warm, 2 sweaty, 3 overheated
--   HeatMath.walkMultiplier(heat, cfg)                  -> 1, or cfg.SweatyWalkMultiplier at >= Sweaty

local HeatMath = {}

export type Cfg = {
	DownAt: number,
	RisePerSecond: number, -- heat/s at the reference distance from a FireLevel-1 part in the open
	RefDistance: number, -- studs; rate = gain / (1 + (d / RefDistance)^2)
	Radius: number, -- studs; farther sources add nothing
	LevelWeight: { number }, -- index = FireLevel 1..3
	OccludedFactor: number, -- multiplier when a wall is between you and the fire
	MaxRisePerSecond: number,
	CoolPerSecond: number, -- always
	HoseCoolPerSecond: number, -- while a teammate's hose hits you
	WaterCoolPerSecond: number, -- while standing in water
	WarmAt: number,
	SweatyAt: number,
	SweatyWalkMultiplier: number,
}

export type Source = { dist: number, level: number, occluded: boolean? }

export type Cooling = { sprayed: boolean?, inWater: boolean? }

function HeatMath.sourceRate(dist: number, level: number, occluded: boolean?, cfg: Cfg): number
	if dist ~= dist or dist > cfg.Radius then
		return 0
	end
	local lvl = math.clamp(math.floor(level + 0.5), 1, #cfg.LevelWeight)
	local d = math.max(dist, 0) / cfg.RefDistance
	local rate = cfg.RisePerSecond * cfg.LevelWeight[lvl] / (1 + d * d)
	if occluded then
		rate *= cfg.OccludedFactor
	end
	return rate
end

function HeatMath.gainRate(sources: { Source }, cfg: Cfg): number
	local total = 0
	for _, s in sources do
		total += HeatMath.sourceRate(s.dist, s.level, s.occluded, cfg)
	end
	return math.min(total, cfg.MaxRisePerSecond)
end

function HeatMath.coolRate(cooling: Cooling?, cfg: Cfg): number
	local rate = cfg.CoolPerSecond
	if cooling then
		if cooling.sprayed then
			rate += cfg.HoseCoolPerSecond
		end
		if cooling.inWater then
			rate += cfg.WaterCoolPerSecond
		end
	end
	return rate
end

function HeatMath.step(heat: number, gain: number, dt: number, cooling: Cooling?, cfg: Cfg): number
	local nextHeat = heat + (gain - HeatMath.coolRate(cooling, cfg)) * dt
	return math.clamp(nextHeat, 0, cfg.DownAt)
end

function HeatMath.stage(heat: number, cfg: Cfg): number
	if heat >= cfg.DownAt then
		return 3
	elseif heat >= cfg.SweatyAt then
		return 2
	elseif heat >= cfg.WarmAt then
		return 1
	end
	return 0
end

function HeatMath.walkMultiplier(heat: number, cfg: Cfg): number
	return if heat >= cfg.SweatyAt then cfg.SweatyWalkMultiplier else 1
end

-- Seconds of standing still at `dist` from one fire of `level` (open air) until Overheated from 0,
-- or math.huge if it never gets there. Handy for tuning and for the spec.
function HeatMath.secondsToOverheat(dist: number, level: number, cfg: Cfg): number
	local net = math.min(HeatMath.sourceRate(dist, level, false, cfg), cfg.MaxRisePerSecond) - cfg.CoolPerSecond
	if net <= 0 then
		return math.huge
	end
	return cfg.DownAt / net
end

return HeatMath
