--!strict
-- VehicleConfig [owner: G2]. Truck 67 numbers. Read at use time so DevHook ".Set" live-tuning works
-- (server copy for VehicleService; the driver's client copy drives the physics).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	TruckNumber = 67,
	HomeLocation = "Station", -- ResetTruck() parks here

	Drivable = true, -- false = the v1 static truck (no seat prompts, stays anchored)

	-- Driving (client-simulated by the driver, who owns the truck's physics). Units: studs, seconds.
	MaxSpeed = 70, -- studs/s forward; reverse is half
	Accel = 38, -- studs/s^2 under throttle
	Brake = 90, -- studs/s^2 when pressing against the motion
	TurnSpeed = 1.5, -- rad/s at speed
	Grip = 5, -- 1/s; lower = more drifty
	AirControl = 0.15, -- fraction of drive/steer while airborne

	-- Bouncy suspension: four raycasts from the chassis corners. Low damping = jelly truck.
	RideRest = 3.2, -- ray length from chassis centre (chassis centre sits ~2.4 studs up at rest)
	Spring = 250, -- accel per stud of compression (gravity is 196 -> ~0.8 stud sag)
	Damping = 7, -- accel per stud/s of vertical speed (raise to calm the bounce)
	SelfRightAfter = 1.5, -- seconds upside-down before the truck pops back upright

	-- Comedy
	HonkCooldown = 0.35,
	RunOverSpeed = 22, -- studs/s: faster than this and a player in front gets bowled over
	RunOverLaunch = 70, -- launch speed for the victim
	RunOverCooldown = 2,

	-- Sounds. Asset ids are not verifiable offline: "" = silent. Set e.g. "rbxassetid://..." here.
	HornSoundId = "rbxassetid://107056835646946", -- AudioConfig.Sounds.Horn
	SirenSoundId = "rbxassetid://530137633", -- AudioConfig.Sounds.Siren (loop)
	EngineSoundId = "",
	BoingSoundId = "",
})
