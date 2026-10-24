--!strict
-- ToolConfig [owner: G1]. Hose (endless water), extinguisher, axe, doors, friendly fire, puddles and feel.
-- Read at use time (ToolConfig.X) so DevHook:Invoke("ToolConfig", ".Set", key, value) live-tunes.
-- Sound ids default to "" (silent) because asset ids can't be vetted here; set them to rbxassetid://N.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- hose (G1.4, G1.5): trucks have endless water, so the hose never drains
	TankSize = 100, -- the hose's Water / TankSize attrs (always full; ToolMath.pressure reads them)
	LitresPerSpray = 1.2, -- per Tool/Spray event; the client sends SprayHz events/s -> 12 L/s
	SprayHz = 10, -- client send rate while the trigger is held
	SprayingClearSeconds = 0.25, -- Player attr Spraying goes false this long after the last spray
	LowWaterFraction = 0.2, -- under this the extinguisher sputters (client); the hose never gets low
	StreamSpeed = 70, -- studs/s of the visual + puddle arc (matches the particles)
	StreamGravity = 55, -- studs/s^2 pulling the arc down
	StreamMaxTime = 0.7, -- seconds of arc sampled for the impact point (~45 studs)
	-- recoil (v1.5): the hose shoves the sprayer backwards, harder at full pressure
	HoseRecoil = 3, -- studs/s per Tool/Spray event in the ToolService.HoseRecoil impulse (server signal)
	HoseRecoilSpeed = 10, -- studs/s client push-back while spraying at pressure 1 (a third when crouched)
	HoseRecoilForce = 900, -- per unit of mass; how hard the recoil mover fights your legs
	SprayWalkScale = 0.6, -- you walk slower while bracing a hose
	HoseRocketCos = 0.94, -- aim this close to straight down for HoseRocketSeconds and you lift off
	HoseRocketSeconds = 0.8,
	HoseRocketSpeed = 22, -- studs/s upwards at pressure 1
	-- spray feel (client)
	SprayFovKick = 5, -- degrees added on spray start, scaled by pressure
	SprayShakeBase = 0.08, -- continuous camera trauma while spraying ...
	SprayShakeExtra = 0.22, -- ... plus this much at pressure 1
	-- first person: keep the centre of the screen and the fire visible while spraying
	FpSprayStart = 2.4, -- stream particles are born this many studs out along the aim, not at the lens
	FpSprayStartCalm = 3.4, -- ... further out on phones / EFFECTS: CALM (ClientLib/Calm)
	SprayLensNear = 3, -- impact splash / douse steam shrink to nothing this close to the camera ...
	SprayLensFar = 12, -- ... and are full size from here on (ToolMath.lensFade)
	-- extinguisher (G1 extra)
	FoamSize = 20, -- charges per extinguisher
	FoamPerSpray = 0.4, -- charges per Tool/Spray event (4/s -> 5 s of foam)
	FoamEfficiency = 3, -- litres of "water" per charge handed to FireService:ApplyWater
	FoamRange = 12,
	FoamPush = 10, -- studs/s on a teammate (tiny), plus a 1.5 s white-out on their screen
	FoamCool = 25, -- HeatService:Cool amount per foam hit
	-- axe and doors (G1.6)
	AxeCooldown = 0.6, -- seconds between swings
	AxeReach = 8, -- studs from HumanoidRootPart to the door centre
	DoorHits = 3, -- axe hits to break a door
	DoorFlySpeed = 55, -- studs/s the broken planks fly along the swing
	DoorFlyLift = 22,
	DoorDebrisSeconds = 8,
	AxeBonkReach = 7, -- studs: teammates in front of the swing get bonked
	AxeBonkCos = 0.5,
	AxeBonkPush = 32, -- studs/s (small knockback, no damage)
	AxeBonkLift = 18,
	-- friendly fire (G1.7)
	HoseHitRange = 24, -- studs: teammates inside the spray cone within this range get pushed
	HoseHitCos = 0.9, -- ~25 degree cone for hitting players
	HosePush = 25, -- studs/s per push at pressure 1 (docs/game/01 §4.1)
	HosePushLift = 7,
	HosePushInterval = 0.2, -- seconds between pushes on the same victim
	HoseHitCooldown = 0.5, -- HoseHit signal / blame at most once per sprayer-victim pair per this
	HoseKnockdownSeconds = 0.6, -- this long under a teammate's stream -> ragdoll
	HoseRagdollSeconds = 1.5,
	HoseCool = 15, -- HeatService:Cool amount per hose push (water cools a hot teammate)
	-- puddles (WetFloor): floors you spray get slippery
	PuddleEvery = 3, -- one puddle sample per N spray events
	PuddleMax = 24,
	PuddleMinRadius = 1.6,
	PuddleMaxRadius = 4.5,
	PuddleMergeStuds = 3,
	PuddleSeconds = 20, -- after the last splash
	WetGrip = 1.2, -- per second: how fast you regain control on a wet floor (low = ice)
	WetMaxSpeed = 60,
	-- sounds (rbxassetid://N; "" = silent)
	SoundHoseLoop = "",
	SoundSplash = "",
	SoundAxeWhoosh = "rbxassetid://9120972444", -- (PSE) wood whoosh, quick swing
	SoundAxeThunk = "rbxassetid://9113225734", -- (PSE) axe impact on wood
	SoundDoorCrash = "rbxassetid://9113225986", -- (PSE) giant thuddy axe hit (door cracked, not broken)
	SoundBonk = "rbxassetid://3765689841", -- cartoon bonk
	SoundFoam = "",
	SoundRefill = "rbxassetid://9126206853", -- (PSE) water sloshing in bucket
})
