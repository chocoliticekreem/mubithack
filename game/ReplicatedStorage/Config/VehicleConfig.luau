--!strict
-- VehicleConfig [owner: Vehicle agent]. Truck numbers (v2: one truck per player, docs/game/08 "Vehicles").
-- Read at use time so DevHook ".Set" live-tuning works (server copy for VehicleService; the driver's
-- client copy drives the physics).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TruckNumber = 67,
	HomeLocation = "Station", -- where TruckBay parts / the reserve parking are looked up first

	Drivable = true, -- false = static trucks (no seat prompts, stay anchored)
	PerPlayerTrucks = true, -- every player always owns at least one truck (spawned at the station)
	-- Shared trucks: ANYONE can drive ANY truck; whoever drove it last owns it ("<Name>'s Truck"). A player
	-- owns at most MaxOwned; the previous owner of a truck someone took gets a spare / a fresh one.
	MaxOwned = 2,
	TruckSlack = 2, -- trucks allowed beyond one per player (somebody's second truck)
	MaxTrucks = 10, -- hard cap (8 players + slack): bays 1-4, then the 6 OverflowSpots
	PerMissionTrucks = false, -- v1 fallback: MissionService:ParkAt(instanceId) builds a truck inside the instance
	OwnerOnlyDrives = false, -- true = only the owner may take the wheel (others ride)
	TapEnterRange = 22, -- studs from the chassis: a tap on the truck (touch) sits you straight in (Vehicle/Enter)

	-- Parking
	-- Overflow parking (truck numbers 5..): the station's empty east parking lot. One column of trucks
	-- side by side along its west edge (14 studs apart), noses east toward the open lane, which runs south
	-- to the lot drive. Each { x, z, yaw } is in bay 1's frame (x = truck-right, z = truck-back; bay 1
	-- faces out of its door), yaw in degrees (90 = facing east). World: X 108, Z 165 / 151 / ... / 95.
	OverflowSpots = {
		{ -118, -23, 90 },
		{ -118, -9, 90 },
		{ -118, 5, 90 },
		{ -118, 19, 90 },
		{ -118, 33, 90 },
		{ -118, 47, 90 },
	},
	-- past OverflowSpots (no station layout / past MaxTrucks): a row on the apron in front of the bays
	ReserveAhead = 46, -- studs in front of the station anchor for that row
	ReserveSpacing = 15, -- studs between its spots
	RespawnCooldown = 4, -- seconds between RespawnTruck calls per player
	UnflipRange = 150, -- R within this many studs of your truck = flip it upright in place; farther = back to bay
	LostBelowY = -60, -- chassis below this = lost, rebuilt at the bay
	-- Safety net: a truck that dropped under the map (chassis below RescueBelowY, or no ground under it
	-- for RescueNoGroundSeconds) is put back upright on the nearest road node, riders still inside.
	RescueBelowY = -20,
	RescueNoGroundSeconds = 1.5,
	RescueRayDepth = 150, -- studs: "no ground" = nothing this far below the chassis
	-- ...or SUNK: the top of an anchored, solid surface right over the chassis centre stands above the
	-- chassis bottom by RescueSinkDepth (the truck slid into / under the road), for RescueSinkSeconds;
	-- ...or STUCK: the driver holds the throttle and the truck moves under RescueStuckStuds in
	-- RescueStuckSeconds. All three: lifted onto a drivable surface nearby, upright, speed cleared
	-- ("Truck reset!" pop, telemetry truck_rescued + truck_rescued_<why>).
	RescueSinkDepth = 0.35,
	RescueSinkSeconds = 0.5,
	RescueStuckSeconds = 5,
	RescueStuckStuds = 3,
	RescueRoadRange = 160, -- studs: a rescued truck goes to the nearest road node within this, else its spot
	-- Driver's client (anti-tunnel): suspension rays start this far above the chassis centre, so a chassis
	-- that sank into a thin road top still finds the surface and springs out instead of falling through;
	-- if it sank deeper than SinkLift studs it is lifted back on top in the same frame.
	RayLift = 2,
	SinkLift = 0.25,
	MaxFallSpeed = 120, -- studs/s: downward speed cap (a faster box tunnels through thin parts)
	MaxFlingSpeed = 150, -- studs/s: total speed cap after a crash / fling

	-- Mass. The body parts are Massless, so the chassis carries the whole truck. Heavy enough that a
	-- character (~14 mass) standing, landing or jumping on it barely moves it; the driving code works
	-- in velocities and mass-scaled impulses, so this doesn't change how it drives.
	ChassisDensity = 5, -- ~1260 mass (was 1.2 -> ~300: a jumping player rocked it)
	DoorHingeSnap = 1.5, -- studs: a door pulled further than this off its hinge is put back on it

	-- Driving (client-simulated by the driver, who owns the truck's physics). Units: studs, seconds.
	-- ARCADE handling (v3): grips the road like a Jailbreak / ER:LC car. See VehicleController.step.
	MaxSpeed = 70, -- studs/s forward; reverse is half. A half-pushed stick cruises at half speed
	Accel = 40, -- studs/s^2 under throttle (eases in over the last 8 studs/s, no lurch at the cap)
	Brake = 90, -- studs/s^2 when pressing against the motion
	CoastBrake = 40, -- studs/s^2 when you let go: rolls to a stop (~2 s / 60 studs from top speed)
	HoldBelow = 2, -- studs/s: no throttle and slower than this = parked, holds still (even on slopes)
	ThrottleRise = 4, -- 1/s: throttle input ramps (0 -> full in 0.25 s) ...
	ThrottleFall = 8, -- ... and releases / reverses twice as fast
	SteerRate = 7, -- 1/s: keyboard steer ramps (no instant full lock)
	TurnRadiusLow = 16, -- studs: turning circle radius when slow (car park, bay doors)...
	TurnRadiusHigh = 80, -- ...growing to this at MaxSpeed (gentle on the avenue, no spin-outs)
	MaxYawRate = 1.5, -- rad/s cap
	YawResponse = 10, -- 1/s: how fast the truck's yaw follows the wheel (and recovers after a bump)
	Grip = 20, -- 1/s: sideways slide decay on the ground (higher = more planted; 5.5 was ice)
	UprightStiffness = 10, -- 1/s: pitch / roll follow the ground under the truck (no bob, no wobble)
	UprightAir = 3, -- 1/s: and level out in the air
	MaxClimb = 10, -- studs/s upward cap on the ground (or 0.45 x speed on a ramp): kerbs don't launch it
	AirDownforce = 60, -- studs/s^2 extra gravity once airborne (short hops, no gliding)
	AirControl = 0.15, -- fraction of drive/steer while airborne
	-- Touch (phones / iPads; InputHints.isTouch): kid-proof stick
	TouchMaxSpeed = 56, -- studs/s (PC 70)
	TouchDeadzone = 0.15, -- stick fraction ignored (a resting thumb doesn't steer)
	TouchSteerExpo = 1.5, -- steer = push ^ expo: fine control near the centre, full lock at the edge (throttle is linear)
	TouchCruise = 0.45, -- a sideways push (not pulled back) still drives, at this x the push (~25 studs/s: corners)
	TouchSteerRate = 4, -- 1/s: steer ramp (smoother than keyboard)
	TouchAlign = 1.2, -- rad/s per rad: stick let go = line up with the road you're on ...
	TouchAlignMaxDeg = 22, -- ... when within this many degrees of it ...
	TouchAlignRange = 30, -- ... and within this many studs of the road's centre line (lanes sit 7-16 off it)

	-- Suspension: four raycasts from the chassis corners carry the weight (through the centre of mass).
	RideRest = 3.4, -- ray length from chassis centre (chassis centre sits ~2.4 studs up at rest)
	Spring = 240, -- accel per stud of compression (gravity is 196 -> ~0.8 stud sag)
	Damping = 30, -- accel per stud/s of vertical speed (~critical: settles, no jelly bounce; was 6)
	SelfRightAfter = 2.5, -- seconds upside-down before the truck pops back upright on its own
	-- Low frame rates: the client sets velocities once per frame and they hold all frame long.
	MaxStepDt = 1 / 30, -- kicks/accelerations never use a longer frame than this
	MaxTiltPerFrame = 0.12, -- radians of pitch/roll the body may turn in one frame (7 rad/s at 60 fps)

	-- Wheels (visual only, each client animates the "WheelMotor"s of trucks near its camera; the
	-- suspension rays still carry the truck): the front pair steer with DriveSeat.SteerFloat, and all
	-- of them roll with the chassis' forward speed (backwards in reverse; radius = the Wheel_ part's).
	WheelSteerAngle = 30, -- degrees at full lock
	WheelSteerRate = 10, -- 1/s: how fast the front wheels follow the stick
	WheelAnimRange = 250, -- studs from the camera; farther trucks' wheels stay put

	-- Doors (physical, HingeConstraint "DoorHinge"; positive angle = open when DoorDir = 1)
	DoorDir = 1, -- flip to -1 if a live test shows the doors swinging INTO the cab
	DoorOpenAngle = 95, -- degrees; also the hinge limit, so an opening door slams into it and wobbles
	DoorRestitution = 0.45, -- bounce off the hinge limits (overshoot + wobble)
	DoorSpeed = 9, -- rad/s servo speed
	DoorTorque = 4000, -- servo torque (low enough that physics hands can yank a door)
	DoorSwingSpeed = 7, -- studs/s: drive off faster than this with a door open and it swings free...
	DoorFreeSeconds = 1.4, -- ...then SLAMS shut after this long at most
	DoorBonkPush = 38, -- studs/s knockback for anyone a slamming door hits (only with DoorBonks)
	DoorBonks = false, -- kids hated it: a swinging / slamming door never ragdolls anyone (still THUNKs)
	SeatNeedsOpenDoor = false, -- false: the Drive / Ride shotgun prompts show with the door shut (no door
	--                            dance to get in), and getting out doesn't swing the door open into you
	DoorBreakDv = 48, -- studs/s sudden speed change (a hard ram) that can knock a door off
	DoorBreakClosedChance = 0.3, -- chance a CLOSED door also flies off on such a ram (open ones always do)
	DoorSlamSoundId = "rbxasset://sounds/action_jump_land.mp3", -- built-in; pitched down = THUNK
	BonkSoundId = "rbxasset://sounds/uuhhh.mp3", -- built-in

	-- Keys (Enum.KeyCode names)
	KeyEnter = "F", -- seat prompts (Drive / Ride shotgun / Hop on)
	KeyDoor = "E", -- door handle prompt
	KeyExit = "Space", -- jump out (was F); there is no drift any more
	KeySiren = "G",
	KeyHorn = "H",
	KeyCam = "V", -- chase <-> cab view
	KeyRespawn = "R",
	DefaultCam = "chase", -- "chase" | "cab"

	-- Camera (driver)
	CamDistance = 30,
	CamHeight = 15, -- high enough to see the road over the 9.6-stud truck
	CamLookAhead = 16,
	CamStiffness = 7, -- 1/s follow lerp
	FovBase = 72,
	FovAdd = 22, -- extra FOV at top speed
	TouchCamDistance = 38, -- touch: further back ...
	TouchCamHeight = 18, -- ... higher ...
	TouchCamLookAhead = 28, -- ... and looking further down the road (phones)
	CabEye = Vector3.new(0, 3.05, -0.8), -- cab view eye, relative to the DriveSeat: mid-windshield, wheel lower-centre
	CabPitch = -0.08, -- rad; a touch down so the road ahead shows over the dash
	CabFov = 80,

	-- Siren
	SirenWailHz = 0.45, -- up/down wails per second
	SirenPitchBase = 0.85,
	SirenPitchSpeed = 0.35, -- added pitch at top speed
	SirenPitchWail = 0.12,

	-- Comedy
	HonkCooldown = 0.35,
	RunOverSpeed = 22, -- studs/s: faster than this and a player in front gets bowled over
	RunOverLaunch = 70, -- launch speed for the victim
	RunOverCooldown = 2,
	PropHitSpeed = 14, -- studs/s: faster than this and loose props in front go flying
	PropLaunch = 1.3, -- prop launch speed = truck speed * this (+ lift)
	PropMaxMass = 400,

	-- Sounds. "" = fall back to AudioConfig.Sounds.<Siren|Horn>.id when present, else silent.
	-- EngineSoundId: no vetted engine loop in AudioConfig yet; "" = no engine hum.
	HornSoundId = "rbxassetid://107056835646946",
	SirenSoundId = "rbxassetid://530137633",
	EngineSoundId = "rbxassetid://71482635231754", -- diesel idle loop
})
