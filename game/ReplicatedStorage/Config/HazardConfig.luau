--!strict
-- HazardConfig [owner: GF]. Hazard numbers (docs/game/01 §8; HazardService, v1.5). Read at use time so
-- DevHook ".Set" live-tuning works. "Damage" is Heat (HeatService:AddHeat; 100 = Downed).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- electrocution (wet floor + fuse box)
	ZapDamage = 40, -- (legacy) heat from a zap; the two below replace it
	ZapStunHeat = 8, -- first touch: you're stuck buzzing, can stagger off the puddle
	ZapStunSeconds = 1.6,
	ZapStunWalkSpeed = 5,
	ZapKnockHeat = 25, -- touch it again within ZapKnockWindow: knocked flat
	ZapKnockWindow = 6,
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
	ExplosionDownShare = 0.45, -- only players inside this share of the radius are Downed (the rest are flung)
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
	LeakSeconds = 150, -- gas_leak: countdown from arrival until the tanker blows
	ValveHoldSeconds = 1.5, -- hold E on a pump valve wheel to shut it
	LeakFirstPumps = 2, -- pumps leaking on arrival (the rest rupture at LeakSecondAt)
	LeakSecondAt = 60, -- s after arrival: the second leak (the remaining pumps rupture)
	LeakSecondPumps = 1, -- how many more pumps rupture (extra ones are added if the site has too few)
	GasCloudMax = 46, -- studs: the gas cloud over the pumps grows to this diameter by the countdown's end
	GasCloudHeat = 2, -- heat per second inside the cloud's core in its last 30 s (coughing)
	TankerBlastRadius = 60, -- the tanker: huge blast (knockback reaches 1.4x this)
	TankerBlastDamage = 70, -- heat at the centre (linear falloff)
	TankerIgnite = 16, -- flammable parts lit by the blast itself
	TankerDebris = 18, -- flaming chunks that fly out and set fire to what they land on
	TankerDebrisSpeed = 95,
	TankerScorch = 34, -- studs: the scorch mark / crater left under the tanker
	PryHoldSeconds = 1.6, -- pileup: hold E on a jammed car door (with a pry tool or axe in hand)
	CatTreeHeight = 18, -- cat_tree: trunk height (GearConfig.LadderMaxHeight 34 reaches the branch)
	CatPunEvery = 9, -- s between cat puns
	-- sounds ("" = silent; asset ids can't be verified offline)
	ZapSoundId = "rbxassetid://9114277757", -- (PSE) electric zap
	ExplosionSoundId = "rbxasset://sounds/impact_explosion_03.mp3", -- built-in
	HissSoundId = "rbxassetid://4772620521", -- Steam Hiss (AudioConfig.Steam), looped on each leaking pump ("" = silent)
	WarnBeepSoundId = "rbxassetid://9113084849", -- alarm bell (AudioConfig.Alarm): the tanker's last 15 s
	TornadoSoundId = "rbxassetid://9125742262", -- (PSE) airy whooshing wind loop
	WaveSoundId = "rbxassetid://9120619377", -- (PSE) wave crashing
	CreakSoundId = "rbxassetid://9126282061", -- (PSE) wood strain creak
})
