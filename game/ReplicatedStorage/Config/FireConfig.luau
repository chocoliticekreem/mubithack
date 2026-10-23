--!strict
-- FireConfig [owner: G1]. Every fire number lives here (docs/game/03-tech-architecture.md §3, §5).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TickHz = 5, -- simulation steps per second
	TickBudgetMs = 2, -- step() slower than this bumps fire_tick_over_budget
	MaxBurning = 120, -- hard cap; spread pauses at the cap
	SpreadRadius = 8, -- studs; also the spatial-hash cell size
	SpreadHeatPerSecond = 14, -- heat a burning part adds to each idle neighbour
	GrowPerSecond = 6,
	IgniteAt = 40,
	ExtinguishAt = 10,
	DefaultFuel = 45, -- seconds a part burns before it is Charred
	CharredColor = Color3.fromRGB(35, 30, 28),
	HoseRange = 28,
	HoseConeCos = 0.94, -- ~20 degree cone
	CoolPerLitre = 9,
	-- client effects budget
	MaxClientFx = 40,
	MaxClientLights = 10,
	FxDistance = 180,
})
