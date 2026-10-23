--!strict
-- HazardConfig [owner: GF]. Hazard numbers (docs/game/01 §8; HazardService, v1.5).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- electrocution (wet floor + fuse box)
	ZapDamage = 40,
	ZapRagdollSeconds = 2,
	ZapTickSeconds = 0.5,
	-- explosion
	ExplosionRadius = 15,
	ExplosionDamage = 60, -- at the centre, linear falloff to 0 at the radius
	-- fire tornado
	TornadoRadius = 12,
	TornadoHeight = 60,
	TornadoSpeed = 8, -- studs/s random walk, biased toward the nearest player
	TornadoSeconds = 45,
	TornadoWaterToKill = 300, -- litres
	TornadoFlingSpeed = 100,
	-- tidal wave
	WaveSeconds = 6,
	-- cigarette (farm)
	CigaretteRelightSeconds = 12,
})
