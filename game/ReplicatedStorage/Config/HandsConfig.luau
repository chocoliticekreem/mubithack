--!strict
-- HandsConfig [owner: Hands agent]. Physics hands (trailer-style big gloves that grab, push, slap
-- and hold floppy tools). Read on the client by ClientLib/PhysicsHands + FirstPersonController and
-- on the server by Services/HandsService. Read at use time so DevHook ".Set" live-tunes the server
-- copy (client copies are separate).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true, -- false = the simple camera-attached viewmodel everywhere (no grabbing)
	MobileEnabled = true, -- touch-only devices get the physics hands too (false = the simple viewmodel)
	GloveScale = 0.55, -- glove rig size (1 = a 1-stud-wide palm); the collider palm matches it
	GloveScaleTouch = 0.48, -- touch devices / phone-size screens: smaller gloves (built once, at spawn)
	IdleCurl = 0.24, -- 0 open .. 1 fist: how curled the relaxed gloves' fingers are

	-- framing on top of the HandsMath poses (studs / degrees, right hand; the left mirrors).
	-- Live-tune in Studio with Camera attributes HandsTweak_<name> / HandsTweakRot_<name>.
	-- The gloves sit low and out toward the bottom corners, so the ground ahead, the crosshair and
	-- the hotbar stay clear; the held tool still pokes up out of the right fist.
	PoseTweak = {
		idle = { x = 0.3, y = -0.05, z = 0.05, rx = 45, ry = 12, rz = -32 },
		lowered = { x = 0.35, y = 0.1, z = -0.1, rx = 35, ry = 10, rz = -25 },
		-- held tools: the fist rolls thumb-up so the handle stands up out of it
		hose = { x = 0.4, y = -0.25, z = -0.35, rx = 0, ry = 0, rz = -65 },
		hoseSupport = { x = 0, y = -0.25, z = 0, rx = 0, ry = 0, rz = 0 },
		extinguisher = { x = 0.35, y = -0.1, z = -0.2, rx = 0, ry = 0, rz = -80 },
		item = { x = 0.2, y = -0.15, z = 0, rx = 0, ry = 0, rz = -80 },
		axe = { x = 0, y = 0, z = 0, rx = 30, ry = 0, rz = -80 },
	},
	-- phones / iPads (touch) and phone-size screens: every pose (not carry / reach / grab) moves this much
	-- further out and down on top of PoseTweak (right hand; the left mirrors)
	TouchFrame = { x = 0.2, y = -0.15, z = 0 },

	-- hand springs: the target pose is sprung (lag, overshoot, wobble) and the physical palm is
	-- pulled to it by AlignPosition/AlignOrientation, so walls and props push back
	TargetHz = 4.5, -- natural frequency of the pose spring
	TargetDamping = 0.42, -- < 1 = overshoot and wobble
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
	TouchShoulder = { x = 0.3, y = -0.25 }, -- added on touch / phone-size screens: sleeves from the corners

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

	-- the ONE axe (ClientLib/AxeArm + AxeMath): the real Tool. Its metal Head hangs on a ball socket at
	-- the top of the handle (built by ToolService), the holder's R15 arm is posed by IK toward a GRIP
	-- pose in aim space (head origin, root yaw, camera pitch; x right, y up, -z forward; degrees).
	-- Hold the tool button to wind up, release to chop. Same pose on every client = same arm in 1P/3P.
	AxePoses = {
		Ready = { x = 1.3, y = -1.6, z = -2.0, rx = -65, ry = 30, rz = 4 }, -- low right, head right of the crosshair
		Windup = { x = 1.05, y = -0.8, z = -1.4, rx = -5, ry = 30, rz = -10 }, -- raised up top-right
		Strike = { x = 0.5, y = -1.5, z = -2.3, rx = -100, ry = 10, rz = 0 }, -- forward-down chop
	},
	AxeWindupSeconds = 0.5, -- hold this long for a full wind-up
	AxeStrikeSeconds = 0.3, -- the chop (wind-up -> strike)
	AxeRecoverSeconds = 0.35, -- strike -> ready
	AxeMinCharge = 0.35, -- a tap still chops a bit
	AxeArmHz = 7, -- grip pose spring (lag + a little overshoot)
	AxeArmDamping = 0.55,
	AxeArmStrikeHz = 18, -- stiffer while chopping
	AxeArmStrikeDamping = 0.6,
	AxeRunBob = 0.12, -- studs of grip bounce at full run (shakes the head)
	AxePitchScale = 0.85, -- how much the camera pitch tilts the arm
	AxeElbowPole = Vector3.new(0.8, -1, 0.6), -- root space: the elbow bends down, out and back
	AxeArmSendHz = 20, -- arm packet rate (client -> server -> others)
	AxeArmBlendSeconds = 0.15, -- fade the IK arm in/out on equip
	AxeHeadSlack = 4, -- server: studs between the replicated head and the door box
	-- head joint (Lib/Tools/AxeBuilder, read when a Tool is built)
	AxeHeadDeg = 40, -- ball socket cone
	AxeHeadTwistDeg = 12,
	AxeHeadRestitution = 0.25,
	AxeHeadSpring = 12, -- AlignOrientation responsiveness back to rest (weak: it still flops)
	AxeHeadSpringTorque = 40,
	AxeHeadDensity = 2.0, -- sane metal-ish weight: it lags and flops but never yanks the arm
	-- door hits from the head's speed relative to the body when it meets the door (measured live:
	-- a tapped chop ~40 studs/s, a full wind-up ~60, a running full chop more)
	AxeMinSpeed = 22, -- 1 door hit
	AxeStrongSpeed = 50, -- 2 hits
	AxeCritSpeed = 70, -- 3 hits (breaks a door outright)
	AxeMaxSpeed = 160, -- server clamp on reported speed
	AxeReach = 12, -- server: max studs root -> door centre
	AxeHitCooldown = 0.35,
	AxeBonkPush = 32,
	AxeBonkLift = 18,

	-- held tools
	HeldItemScale = 0.85, -- the first-person copy of the held hose / extinguisher, x the real tool's size
	HeldItemScaleTouch = 0.7, -- ... on touch / phone-size screens
	HoseKick = 1, -- recoil amount on the nozzle (x pressure)
	HoseKickImpulse = 0.9, -- random shove on the hand at HoseKickHz while spraying (x Calm.fx on phones)
	HoseKickHz = 9,
	ExtSputterKick = 1.2,

	-- replication
	PoseHz = 15, -- client send rate and server broadcast rate
	PoseMaxOffset = 7, -- studs from the root a replicated hand may be
	RemoteArmBlend = 0.85, -- how much a remote player's shoulder follows their replicated hand
	RemoteStaleSeconds = 1.0,

	-- sounds (rbxassetid://N; "" = silent)
	SoundSlap = "rbxassetid://511340819",
	SoundGrab = "",
	SoundThunk = "rbxassetid://9113225734", -- (PSE) wood impact
})
