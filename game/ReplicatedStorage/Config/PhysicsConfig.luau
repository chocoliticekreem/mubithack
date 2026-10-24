--!strict
-- PhysicsConfig [owner: G1 / Physics]. First-person camera feel, ragdoll/knockback limits (v1.5) and the
-- v2 goofy physics (docs/game/08 "Goofy physics"): knockable props, truck plough, hard landings,
-- banana-peel slips, comedic pops. Read by FirstPersonController, PhysicsFxController, Ragdoll and
-- PhysicsFxService (+ Lib/Physics/PropPhysics via arguments).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	FirstPerson = false, -- no camera lock: players zoom freely (scroll all the way in = first person, the FP effects follow the zoom)
	FieldOfView = 80,
	HeadBobAmplitude = 0.12, -- studs at walk speed
	HeadBobHz = 1.8, -- steps per second at walk speed
	ViewmodelGloves = true, -- gloves + sleeves viewmodel (Palette.GloveOlive / CoatYellow)
	RagdollMaxSeconds = 4, -- longest single ragdoll
	MaxImpulse = 120, -- studs/s cap on one knockback (tornado fling ~100)
	HoseHitImpulse = 25, -- studs/s per friendly-fire hose hit (docs/game/01 §7.5)
	SlapImpulse = 8,
	ExplosionImpulse = 80,

	-- knockable props (PhysicsFxService) -----------------------------------------------------------
	-- Models/Folders (or single parts) under Workspace.Map whose normalized name ENDS with one of these
	-- become physics props; builders can also tag anything "Knockable" (attr Knockable = false opts out).
	KnockableNames = {
		"trashcan", "trash", "trashbin", "wheeliebin", "recyclebin", "garbagecan", "cone", "mailbox",
		"bench", "chair", "stool", "box", "crate", "duck", "duckling", "hydrantcap", "barrel", "bucket",
		"ball", "pumpkin", "pallet", "tire",
	} :: { string },
	-- normalized-name fragments that are never props even if they end with a known name
	KnockableExclude = {
		"fusebox", "hitbox", "volume", "zone", "truckspot", "marker", "dropoff", "lightbox", "skybox",
		"jukebox", "duckpond", "firebox", "sandbox",
	} :: { string },
	PropMaxExtent = 12, -- studs: bigger bounding boxes are scenery, not props
	PropMaxParts = 40,
	PropDensity = 0.35, -- light and floaty, so they really fly
	PropElasticity = 0.55, -- bouncy
	PropFriction = 0.35,

	-- budgets
	PropAreaStuds = 200, -- "area" = a square cell of this size (home position)
	MaxAwakePerArea = 60,
	MaxAwakeServer = 300,
	GridCellStuds = 32, -- spatial hash for wake queries

	-- wake / sleep / ownership
	WakeRadius = 22, -- a player this close wakes a sleeping prop
	WakeLookahead = 0.6, -- s of player velocity added to the wake radius (fast trucks wake ahead)
	SleepRadius = 90, -- nobody this close for SleepAfter seconds (and slow) -> anchor where it lies
	ForceSleepRadius = 220, -- nobody this close -> anchor now, even mid-flight
	SleepSpeed = 2, -- studs/s
	SleepAfter = 3,
	OwnerRadius = 45, -- nearest player within this owns the prop's physics (smooth pushing)
	ServerHoldSeconds = 1.2, -- after a server fling the server keeps ownership this long
	FallResetDepth = 60, -- studs below home: put it back home on sleep
	TickHz = 4, -- wake/sleep/ownership scan rate
	TruckHz = 15, -- truck plough scan rate

	-- truck plough
	TruckFlingSpeed = 14, -- studs/s truck speed needed to send props flying
	TruckFlingCarry = 1.35,
	TruckFlingUp = 30,
	TruckFlingSide = 18,
	TruckFrontReach = 14, -- studs ahead of the chassis centre the plough box reaches
	TruckHalfWidth = 7,
	MaxPropSpeed = 160,
	PropHitCooldown = 0.6,

	-- tools on props
	HosePropImpulse = 35, -- studs/s along the aim per spray tick
	HosePropReach = 45,
	AxePropImpulse = 60,
	AxePropReach = 9,
	AxePropCooldown = 0.45,
	BlastPropPower = 110, -- engine Explosion instances (HazardService) also fling props
	BlastRadiusScale = 1.3,

	-- player impulses (PhysicsFxService:Impulse on a character)
	ImpulseRagdollAt = 55, -- a shove at least this hard also ragdolls
	ImpulseRagdollMin = 0.8,
	ImpulseRagdollMax = 2.5,

	-- hard landings (client detects, server ragdolls)
	HardLandingSpeed = 75, -- studs/s downward at touchdown (a normal jump lands at ~50)
	SplatLandingSpeed = 160,
	LandingRagdollMin = 1.0,
	LandingRagdollMax = 3.0,
	-- fall damage (on top of the hard-landing ragdoll). ~20 studs of drop hits 85 studs/s.
	FallDamageSpeed = 85, -- studs/s at touchdown before a landing hurts
	FallDamagePerSpeed = 1.1, -- HP per stud/s above that (30-stud drop ~25 HP, 50 ~60, 70+ downs you)
	BreakLegSpeed = 115, -- studs/s (~35-stud drop): CRUNCH, a broken leg
	BrokenLegSeconds = 30, -- heals on its own after this, or a teammate splints it
	BrokenLegWalkSpeed = 7, -- limping (normal 16), and no jumping
	SplintSeconds = 2, -- hold time for a teammate's "Splint leg" prompt

	-- banana-peel slips on WetFloor puddles
	SlipSpeed = 14, -- horizontal studs/s needed to slip
	SlipChancePerSecond = 0.55,
	SlipCooldown = 4,
	SlipSeconds = 1.6,
	SlipSpin = 14, -- rad/s feet-over-head spin
	SlipHop = 26, -- studs/s up

	-- wobbly carry (client: a stumbling side-to-side sway while you carry someone and walk)
	CarryWobble = 5, -- studs/s sideways nudge
	CarryWobbleHz = 1.3, -- sway cycles per second

	-- comedic pops
	PopsPerSecond = 8, -- server-wide cap
	PopSeconds = 0.9,
	PopSoundId = "rbxassetid://131916027000817", -- rbxassetid://N for the boing; "" = silent (AudioController owns the stingers)
	PopMaxDistance = 220, -- clients skip pops farther than this from the camera
	PopMaxOnScreen = 12,
})
