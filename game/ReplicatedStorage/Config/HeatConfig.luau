--!strict
-- HeatConfig [owner: G1]. Player Heat numbers (HeatService server, FirstPersonController client, v1.5).
-- Maths: ServerScriptService/Lib/Heat/HeatMath (pure); spec game/tests/heat.spec.luau mirrors these.
--   per Burning part: RisePerSecond * LevelWeight[FireLevel] / (1 + (dist / RefDistance)^2),
--   x OccludedFactor through a wall, 0 beyond Radius; all parts together capped at MaxRisePerSecond.
-- Feel: hugging a FireLevel-3 part (4 studs) overheats from 0 in ~12 s; a room of level-2 parts at
-- ~5 studs in ~5 s; a teammate's hose takes you from 100 to under 60 in < 1 s.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TickHz = 5,
	-- gain
	Radius = 20, -- studs; Burning parts further than this add no heat
	RisePerSecond = 14, -- heat/s from a FireLevel-2 part at distance 0
	RefDistance = 6, -- studs; a part this far gives half of RisePerSecond
	LevelWeight = { 0.6, 1, 1.5 }, -- by FireLevel 1..3
	OccludedFactor = 0.25, -- a wall between you and the fire
	MaxRisePerSecond = 40, -- cap from all parts together
	MaxSources = 12, -- closest Burning parts considered per player per tick
	MaxRaycasts = 6, -- of those, how many get a wall check (the rest count as open)
	-- cooling
	CoolPerSecond = 6, -- always
	SprayCool = 4, -- instant, per teammate hose hit (ToolService.HoseHit)
	HoseCoolPerSecond = 45, -- extra cooling while being hosed
	HoseCoolWindow = 0.4, -- seconds one HoseHit counts as "being hosed"
	WaterCoolPerSecond = 25, -- swimming, standing in water or on a WetFloor
	ExtinguisherCool = 40,
	-- thresholds
	WarmAt = 60, -- client: screen warms + heavy breathing
	SweatyAt = 85, -- client: sweat drops; server: walk slowed
	SweatyWalkMultiplier = 0.65,
	DownAt = 100, -- Overheated -> SquadService:Down(player, "heat")
	ResetAfterDown = 40,
	-- client audio: unvetted asset ids stay "" (no sound) until someone checks one in Studio
	BreathingSoundId = "",
})
