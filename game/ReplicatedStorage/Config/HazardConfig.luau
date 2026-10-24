--!strict
-- HazardConfig [owner: GF]. Hazard numbers (docs/game/01 §8; HazardService, v1.5). Read at use time so
-- DevHook ".Set" live-tuning works. "Damage" is Heat (HeatService:AddHeat; 100 = Downed).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- electrocution (wet floor + fuse box)
	ZapDamage = 40,
	ZapRagdollSeconds = 2,
	ZapTickSeconds = 0.5,
	ZapRadius = 80, -- WetFloor parts within this many studs of a powered FuseBox are live
	ZapStandHeight = 5, -- how far above a WetFloor part a player's root still counts as "standing on it"
	ZapCooldown = 3, -- seconds before the same player can be zapped again by a live puddle
	-- explosion
	ExplosionRadius = 15,
	ExplosionDamage = 60, -- at the centre, linear falloff to 0 at the radius
	ExplosionKnockback = 90, -- studs/s at the centre (edge keeps ExplosionKnockbackMin)
	ExplosionKnockbackMin = 35,
	ExplosionRagdollSeconds = 2.5,
	ExplosionIgnite = 6, -- flammable parts lit by one blast
	ExplosionDebris = 10,
	GasTankFuseSeconds = 3, -- a gas tank (Hazard, HazardId explosion) blows after burning this long nearby
	-- fire tornado
	TornadoRadius = 12,
	TornadoHeight = 60,
	TornadoSpeed = 8, -- studs/s random walk, biased toward the nearest player
	TornadoBias = 0.4,
	TornadoLeash = 90, -- studs from its field centre before it turns home
	TornadoSeconds = 45,
	TornadoDelay = 25, -- seconds into a fire_tornado mission before it spawns (scripted beat)
	TornadoSuckRadius = 30, -- loose parts / NPCs inside this get pulled in
	TornadoIgniteEvery = 0.6,
	TornadoWaterToKill = 300, -- litres (reserved; water-kill not wired yet)
	TornadoFlingSpeed = 100,
	TornadoRagdollSeconds = 3,
	TornadoHeat = 15,
	-- tidal wave
	WaveSeconds = 6,
	WaveHeight = 40,
	WaveThickness = 30, -- depth of the wall that ragdolls whoever it passes
	WaveKnockback = 70,
	WaveRagdollSeconds = 3,
	WaveFloodDepth = 3, -- shallow terrain water left behind (0 = none)
	DetonatorNeedsCharges = false, -- true = only FinaleService:Detonate (all charges planted) may start the wave
	-- backdraft (extra hazard id "backdraft")
	BackdraftRange = 22,
	BackdraftHalfAngle = 35, -- degrees
	BackdraftDamage = 50,
	BackdraftMinBurning = 2, -- burning parts within 14 studs of a door when it breaks
	-- ceiling collapse (extra hazard id "ceiling_collapse")
	CollapseThreshold = 0.5, -- share of a building's ceiling/roof parts Charred before it falls
	CollapseWarnSeconds = 2.5,
	CollapseDamage = 25,
	-- cigarette (farm)
	CigaretteRelightSeconds = 12,
	CigaretteRadius = 16,
	-- v3 mission twists (Lib/Hazard/Twists). Scripted fires (the fryer) carry the Burning tag + FireLevel
	-- like FireService fires, so the HUD, heat, FX and the mission's "all out" count see them.
	TwistSprayRange = 30, -- studs: a hose/extinguisher Tool/Spray event reaches a twist target this far
	TwistSprayCos = 0.82, -- aim cone (~35 degrees; a little wider than FireConfig.HoseConeCos)
	TwistHoseHit = 0.12, -- scripted-fire "hp" removed per hose spray event (~10/s)
	TwistFoamHit = 0.22, -- ...per extinguisher spray event
	GreaseHp = 4, -- the deep fryer: ~2 s of extinguisher
	GreaseFlareCooldown = 2.5, -- s between grease fireballs (water on grease)
	GreaseFlareRadius = 12, -- explosion radius of a grease flare
	GreaseLidHold = 1.5, -- s to hold E on the fryer to slam the lid on
	LeakSeconds = 75, -- gas_leak: countdown from arrival until the tanker blows
	ValveHoldSeconds = 2.5, -- hold E on a pump valve wheel to shut it
	TankerBlastRadius = 26,
	PryHoldSeconds = 1.6, -- pileup: hold E on a jammed car door (with a pry tool or axe in hand)
	CatTreeHeight = 18, -- cat_tree: trunk height (GearConfig.LadderMaxHeight 34 reaches the branch)
	CatPunEvery = 9, -- s between cat puns
	-- sounds ("" = silent; asset ids can't be verified offline)
	ZapSoundId = "",
	ExplosionSoundId = "",
	TornadoSoundId = "",
	WaveSoundId = "",
	CreakSoundId = "",
})
