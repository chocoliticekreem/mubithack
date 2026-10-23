--!strict
-- HeatConfig [owner: G1]. Player Heat numbers (HeatService, v1.5).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TickHz = 4,
	Radius = 14, -- studs; Burning parts further than this add no heat
	RisePerSecond = 10, -- per Burning part at distance 0, times its FireLevel (1..3)
	FalloffPower = 2, -- heat * (1 - d / Radius) ^ FalloffPower
	MaxRisePerSecond = 40, -- cap from all parts together
	CoolPerSecond = 8, -- when no Burning part is within Radius
	SprayCool = 12, -- per teammate hose hit (ToolService.HoseHit)
	ExtinguisherCool = 40,
	DownAt = 100,
	ResetAfterDown = 40,
})
