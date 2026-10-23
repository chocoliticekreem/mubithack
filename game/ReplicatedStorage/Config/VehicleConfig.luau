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
	MaxSpeed = 70, -- studs/s forward; reverse is half
	Accel = 42, -- studs/s^2 under throttle
	Brake = 95, -- studs/s^2 when pressing against the motion
	TurnSpeed = 1.55, -- rad/s at speed
	Grip = 5.5, -- 1/s; lower = more drifty
	DriftGrip = 0.9, -- grip while the handbrake (Space) is held
	DriftTurn = 1.7, -- yaw multiplier while drifting
	HandbrakeDrag = 18, -- studs/s^2 the handbrake bleeds off
	AirControl = 0.15, -- fraction of drive/steer while airborne

	-- Bouncy suspension: four raycasts from the chassis corners. Low damping = jelly truck.
	RideRest = 3.4, -- ray length from chassis centre (chassis centre sits ~2.4 studs up at rest)
	Spring = 240, -- accel per stud of compression (gravity is 196 -> ~0.8 stud sag)
	Damping = 6, -- accel per stud/s of vertical speed (raise to calm the bounce)
	BodyRoll = 0.16, -- radians of lean at full steer + speed
	RollStiffness = 7, -- how fast the body leans into the target roll (1/s)
	WheelieKick = 1.6, -- rad/s pitch-up when you floor it from a standstill
	BumpKick = 0.05, -- rad/s pitch-up per stud/s of sudden front compression (wheelies on bumps)
	BumpThreshold = 9, -- front compression speed (studs/s) that counts as a bump
	SquashSeconds = 0.3, -- spring goes soft this long after a hard landing (cartoon squash + rebound)
	SquashSoften = 0.55, -- spring multiplier at the bottom of the squash
	SelfRightAfter = 2.5, -- seconds upside-down before the truck pops back upright on its own

	-- Camera (driver)
	CamDistance = 30,
	CamHeight = 11,
	CamLookAhead = 12,
	CamStiffness = 7, -- 1/s follow lerp
	FovBase = 72,
	FovAdd = 22, -- extra FOV at top speed

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
	HornSoundId = "",
	SirenSoundId = "",
	EngineSoundId = "",
	BoingSoundId = "",
})
