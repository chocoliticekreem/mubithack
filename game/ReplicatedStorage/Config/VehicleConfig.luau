--!strict
-- VehicleConfig [owner: Vehicle agent]. Truck numbers (v2: one truck per player, docs/game/08 "Vehicles").
-- Read at use time so DevHook ".Set" live-tuning works (server copy for VehicleService; the driver's
-- client copy drives the physics).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TruckNumber = 67,
	HomeLocation = "Station", -- where TruckBay parts / the reserve parking are looked up first

	Drivable = true, -- false = static trucks (no seat prompts, stay anchored)
	PerPlayerTrucks = true, -- v2: FireTruck_<UserId> per player at their TruckBay
	PerMissionTrucks = false, -- v1 fallback: MissionService:ParkAt(instanceId) builds a truck inside the instance
	OwnerOnlyDrives = true, -- others can still ride the back benches

	-- Parking
	ReserveAhead = 46, -- studs in front of the station anchor for the reserve row
	ReserveSpacing = 15, -- studs between reserve spots
	RespawnCooldown = 4, -- seconds between RespawnTruck calls per player
	UnflipRange = 150, -- R within this many studs of your truck = flip it upright in place; farther = back to bay
	LostBelowY = -60, -- chassis below this = lost, rebuilt at the bay

	-- Driving (client-simulated by the driver, who owns the truck's physics). Units: studs, seconds.
	-- Arcade bicycle model (ClientLib/TruckDrive): springs carry the body, two axles make tyre forces.
	MaxSpeed = 72, -- studs/s forward top speed (the torque curve fades to 0 here)
	Accel = 46, -- studs/s^2 peak engine pull (TruckDrive.torqueCurve shapes it over speed)
	Brake = 110, -- studs/s^2 when pressing against the motion
	ReverseSpeed = 28, -- studs/s
	ReverseAccel = 34,
	RollDrag = 5, -- studs/s^2 coasting drag
	AeroDrag = 0.0025, -- per (studs/s)^2 (top-speed coast ~18 studs/s^2)
	StopBelow = 1.2, -- no input + slower than this = parking brake (no creeping)
	DriveFront = 0.3, -- share of engine pull through the front axle (rest = rear: a little power-oversteer)
	BrakeFront = 0.6, -- share of braking on the front axle
	-- Axles (studs from the chassis centre along the truck; the bicycle model's wheelbase)
	FrontAxle = 8, -- ahead
	RearAxle = 5, -- behind
	ForceHeight = 1.1, -- tyre forces act this far below the centre -> weight transfer (roll/pitch)
	-- Steering
	SteerLow = 0.72, -- rad max front-wheel angle at a crawl (tight turns in the station)
	SteerHigh = 0.13, -- rad at top speed (stable on the avenue)
	SteerRate = 3.6, -- rad/s the front wheels turn
	SteerReturn = 6, -- rad/s back to centre
	CounterSteer = 0.9, -- assist: extra front angle per rad of body slip (catches slides)
	CounterSteerMax = 0.45,
	-- Tyres
	Grip = 0.95, -- mu (front); lateral force cap = Grip * axle load
	RearGrip = 1.05, -- rear mu multiplier (>1 = stable, <1 = loose)
	SlipPeak = 0.14, -- rad slip angle where the tyre lets go
	SlideGrip = 0.72, -- fraction of grip left once sliding
	GripStiff = 0.9, -- 0..1 of the slide a gripping tyre cancels per step (1 = on rails)
	DriftGrip = 0.32, -- rear grip multiplier while the handbrake (Space) is held
	HandbrakeDrag = 26, -- studs/s^2 the handbrake bleeds off (rear axle)
	DriftKick = 1.1, -- rad/s yaw kick when you pull the handbrake while steering at speed
	YawDamp = 0.6, -- 1/s yaw damping while sliding (keeps spins catchable)
	AirControl = 0.15, -- fraction of steer yaw while airborne
	-- Engine note (only if EngineSoundId is set): virtual gears for pitch drops on shifts
	GearShifts = { 0.2, 0.42, 0.68, 1.0 },

	-- Suspension: four raycasts from the chassis corners. Lower damping = bouncier.
	RideRest = 3.4, -- ray length from chassis centre (chassis centre sits ~2.4 studs up at rest)
	Spring = 260, -- accel per stud of compression (gravity is 196 -> ~0.75 stud sag)
	Damping = 15, -- accel per stud/s of vertical speed (~0.45 of critical: one goofy bounce, no float)
	AntiRoll = 9, -- 1/s extra roll-rate damping (no wallowing after a slalom)
	PitchTransfer = 5, -- extra nose dive/squat from braking/throttle (visual + shifts grip front/back)
	WheelieKick = 1.2, -- rad/s pitch-up when you floor it from a standstill
	BumpKick = 0.05, -- rad/s pitch-up per stud/s of sudden front compression (wheelies on bumps)
	BumpThreshold = 9, -- front compression speed (studs/s) that counts as a bump
	SquashSeconds = 0.3, -- spring goes soft this long after a hard landing (cartoon squash + rebound)
	SquashSoften = 0.55, -- spring multiplier at the bottom of the squash
	SelfRightAfter = 2.5, -- seconds upside-down before the truck pops back upright on its own

	-- Doors (physical, HingeConstraint "DoorHinge"; positive angle = open when DoorDir = 1)
	DoorDir = 1, -- flip to -1 if a live test shows the doors swinging INTO the cab
	DoorOpenAngle = 95, -- degrees; also the hinge limit, so an opening door slams into it and wobbles
	DoorRestitution = 0.45, -- bounce off the hinge limits (overshoot + wobble)
	DoorSpeed = 9, -- rad/s servo speed
	DoorTorque = 4000, -- servo torque (low enough that physics hands can yank a door)
	DoorSwingSpeed = 7, -- studs/s: drive off faster than this with a door open and it swings free...
	DoorFreeSeconds = 1.4, -- ...then SLAMS shut after this long at most
	DoorBonkPush = 38, -- studs/s knockback for anyone a slamming door hits
	DoorBreakDv = 48, -- studs/s sudden speed change (a hard ram) that can knock a door off
	DoorBreakClosedChance = 0.3, -- chance a CLOSED door also flies off on such a ram (open ones always do)
	DoorSlamSoundId = "rbxasset://sounds/action_jump_land.mp3", -- built-in; pitched down = THUNK
	BonkSoundId = "rbxasset://sounds/uuhhh.mp3", -- built-in

	-- Keys (Enum.KeyCode names)
	KeyEnter = "F", -- seat prompts (Drive / Ride shotgun / Hop on)
	KeyDoor = "E", -- door handle prompt
	KeyExit = "F",
	KeySiren = "G",
	KeyHorn = "H",
	KeyCam = "V", -- chase <-> cab view
	KeyRespawn = "R",
	DefaultCam = "chase", -- "chase" | "cab"

	-- Camera (driver)
	CamDistance = 30,
	CamHeight = 15, -- high enough to see the road over the 9.6-stud truck
	CamLookAhead = 16,
	CamStiffness = 7, -- 1/s position follow
	CamYawLag = 4.5, -- 1/s the chase cam swings round behind the nose (lower = more drift angle on screen)
	CamSpeedPull = 6, -- extra studs of distance at top speed
	FovBase = 72,
	FovAdd = 18, -- extra FOV at top speed
	FovKick = 7, -- extra FOV while accelerating hard
	ShakeSpeed = 0.06, -- studs of camera shake at top speed (road rumble)
	CabEye = Vector3.new(0, 3.7, -0.8), -- cab view eye, relative to the DriveSeat (driver's eyes, over the wheel)
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
	EngineSoundId = "",
	BoingSoundId = "rbxasset://sounds/action_jump.mp3", -- built-in, pitched for the landing squash
})
