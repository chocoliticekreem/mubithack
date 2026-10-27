--!strict
-- FireConfig [owner: G1]. Every fire number lives here (docs/game/03-tech-architecture.md §3, §5).
-- Read at use time (FireConfig.X) so DevHook:Invoke("FireConfig", ".Set", key, value) live-tunes.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TickHz = 5, -- simulation steps per second
	TickBudgetMs = 2, -- step() slower than this bumps fire_tick_over_budget
	MaxBurningPerLocation = 120, -- per mission instance; spread pauses at the cap for that instance only
	MaxBurning = 480, -- server-wide safety net (parallel instances each get their own 120 first)
	SpreadRadius = 8, -- studs; also the spatial-hash cell size
	SpreadHeatPerSecond = 1.5, -- heat a burning part adds to each idle neighbour
	GrowPerSecond = 2,
	IgniteAt = 40,
	ExtinguishAt = 10,
	DefaultFuel = 150, -- seconds a part burns before it is Charred
	CharredColor = Color3.fromRGB(35, 30, 28),
	CharredMaterial = Enum.Material.Slate,
	HoseRange = 42, -- = where the visible stream lands (ToolConfig StreamSpeed x StreamMaxTime, ~45): if the water reaches it, it counts
	HoseConeCos = 0.86, -- ~30 degree cone, measured to the NEAREST point of the burning part
	HoseNearRadius = 9, -- studs: anything burning this close and roughly in front gets hit (point-blank spraying)
	HoseNearFrontDot = -0.1, -- "roughly in front": flat direction dot >= this
	TrainingCoolMultiplier = 3, -- the tutorial's training fire goes out 3x faster
	CoolPerLitre = 9,
	-- juice (2026-10-26, "fires just sit there, then come back"): every hose tick shows, put out = stays out
	HpStep = 0.05, -- FireHP replicates in steps this big (one hose tick at full pressure = ~0.12)
	DousedStaysOut = true, -- a part put out by water never re-lights (spread, flare-ups, wind); fresh parts still burn
	FxHitSeconds = 1.2, -- client: HP ring + hit steam show this long after the last hp drop
	FxMaxRings = 3, -- client: at most this many HP rings (nearest hit fires)
	-- client effects budget (FireFxController)
	MaxClientFx = 40, -- burning parts with emitters, nearest first
	MaxClientLights = 10, -- of those, how many get a flickering PointLight
	MaxShadowLights = 4, -- of those, how many cast shadows
	FxLightClusterRadius = 10, -- one light per cluster of burning parts this close together
	FxDistance = 180, -- no effects beyond this (studs from the camera)
	FxLodDistance = 90, -- beyond this: cheap tier (no embers/haze, quarter rate)
	FxScorchSeconds = 30, -- a burning part darkens toward CharredWarm over this long (client only)
	FxWispSeconds = 8, -- "recently out" wisps after a put-out or burn-out
	FxPoofChance = 0.2, -- chance a put-out fire does a tiny cartoon "poof" smoke ring
	FxFlameFlipbook = "", -- optional rbxassetid of a 4x4 flame flipbook for the core layer ("" = built-in sprite)
	-- sounds (unverified asset ids stay empty; set them live with .Set)
	SfxIgnite = "",
	SfxHiss = "",
	SfxCrackle = "",
	MaxCrackles = 6, -- nearest fires with a crackle loop
})
