--!strict
-- HandsConfig [owner: Hands agent]. Physics hands (trailer-style big gloves that grab, push, slap
-- and hold floppy tools). Read on the client by ClientLib/PhysicsHands + FirstPersonController and
-- on the server by Services/HandsService. Read at use time so DevHook ".Set" live-tunes the server
-- copy (client copies are separate).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true, -- false = the simple camera-attached viewmodel everywhere (no grabbing)
	MobileEnabled = false, -- touch-only devices use the simple viewmodel unless this is true
	GloveScale = 0.6, -- glove rig size (1 = a 1-stud-wide palm); the collider palm matches it
	IdleCurl = 0.3, -- 0 open .. 1 fist: how curled the relaxed gloves' fingers are

	-- framing on top of the HandsMath poses (studs / degrees, right hand; the left mirrors).
	-- Live-tune in Studio with Camera attributes HandsTweak_<name> / HandsTweakRot_<name>.
	PoseTweak = {
		idle = { x = 0, y = 0, z = 0, rx = 0, ry = 0, rz = 0 },
	},

	-- hand springs: the target pose is sprung (lag, overshoot, wobble) and the physical palm is
	-- pulled to it by AlignPosition/AlignOrientation, so walls and props push back
	TargetHz = 4.5, -- natural frequency of the pose spring
	TargetDamping = 0.42, -- < 1 = overshoot and wobble
	StrikeHz = 10, -- stiffer spring while the axe strike runs
	StrikeDamping = 0.5,
	HandResponsiveness = 60, -- AlignPosition
	HandMaxForce = 2500, -- base pull (the palm itself is light); lift for held props is added on top
	HandMaxVelocity = 140,
	HandRotResponsiveness = 35, -- AlignOrientation
	HandMaxTorque = 4000,
	HandDensity = 0.6,
	SnapDistance = 4.5, -- studs from its target before a stuck hand teleports back ...
	SnapAfter = 0.35, -- ... after being stuck this long
	ShoulderX = 1.0, -- camera-space shoulder where the stretchy sleeve starts
	ShoulderY = -1.75,
	ShoulderZ = 0.3,

	-- reach and grab (LMB = left hand, RMB = right hand; holding a tool, LMB uses it and RMB is the
	-- free left hand). Hold to keep gripping, release to let go (throws keep their momentum).
	Reach = 6.5, -- studs from the camera
	ReachSeconds = 0.16,
	GrabSnap = 1.4, -- palm this close to the aimed point -> try to grab
	GrabRadius = 1.1, -- contact probe radius around the palm
	OneHandMaxMass = 25,
	TwoHandMaxMass = 120,
	GripBreakDistance = 6, -- a prop yanked this far from the hand slips out
	ThrowBoost = 1.3, -- velocity multiplier on release
	ServerGrabReach = 14, -- server: max studs from the HumanoidRootPart to a grabbed part
	ReleaseOwnerSeconds = 2.5, -- server: network ownership stays with the thrower this long
	GrabCooldown = 0.15,

	-- slap (trailer gag) and pushes
	SlapMinSpeed = 14, -- relative hand speed (studs/s) for a slap (a quick reach-jab is ~20-30)
	SlapPerSpeed = 1.1,
	SlapMax = 55, -- studs/s knockback cap
	SlapLift = 14,
	SlapRagdollSpeed = 45, -- a really hard slap ragdolls
	SlapRagdollSeconds = 1.2,
	SlapCooldown = 0.5,
	SlapReach = 10, -- server: max studs between slapper and victim roots
	SlapMaxReportedSpeed = 120,
	HitStopSeconds = 0.08, -- hand freeze on a landed slap / axe hit
	PushMinSpeed = 8,
	PushPerSpeed = 0.6,
	PushMax = 30,
	PushCooldown = 0.25,
	PushDoorSpeed = 10, -- shoving an unlocked closed door this hard swings it open

	-- the floppy axe: hold LMB to wind up, release to swing; the head is on a ball socket
	AxeWindupSeconds = 0.55,
	AxeStrikeSeconds = 0.22,
	AxeMinSpeed = 22, -- head speed (studs/s) for 1 door hit
	AxeStrongSpeed = 38, -- 2 hits
	AxeCritSpeed = 55, -- 3 hits (a perfect swing breaks a door outright)
	AxeMaxSpeed = 160, -- server clamp on reported speed
	AxeReach = 12, -- server: max studs root -> door centre
	AxeHitCooldown = 0.35,
	AxeHeadFlopDeg = 55, -- ball socket cone
	AxeHeadDensity = 2.5,
	AxeBonkPush = 32,
	AxeBonkLift = 18,

	-- held tools
	HoseKick = 1, -- recoil amount on the nozzle (x pressure)
	HoseKickImpulse = 0.9, -- random shove on the hand at HoseKickHz while spraying
	HoseKickHz = 9,
	ExtSputterKick = 1.2,

	-- replication
	PoseHz = 15, -- client send rate and server broadcast rate
	PoseMaxOffset = 7, -- studs from the root a replicated hand may be
	RemoteArmBlend = 0.85, -- how much a remote player's shoulder follows their replicated hand
	RemoteStaleSeconds = 1.0,

	-- sounds (rbxassetid://N; "" = silent)
	SoundSlap = "",
	SoundGrab = "",
	SoundThunk = "",
})
