--!strict
-- TrafficConfig [owner: Traffic]. City traffic numbers (docs/game/08 "City"). Read at use time so
-- DevHook ".Set" live-tuning works. Server copy drives TrafficService; client copy drives
-- TrafficController (interpolation, honk visuals). Units: studs, seconds, studs/s.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true, -- false = no traffic at all

	-- Population (spawn and despawn near players only)
	MaxCars = 40, -- hard cap on live cars (30-60 is the budget)
	CarsPerPlayer = 14, -- target cars per player, capped by MaxCars
	SpawnMin = 110, -- never spawn closer than this to any player (no pop-in in your face)
	SpawnMax = 360, -- spawn within this of some player
	DespawnRadius = 460, -- cars farther than this from every player vanish
	SpawnClear = 22, -- no other car within this of a spawn point
	SpawnPerSecond = 4, -- max new cars per second
	-- weights per kind (Lib/Traffic/CarBuilder kinds)
	KindWeights = { sedan = 40, taxi = 18, van = 20, bus = 7, icecream = 5 } :: { [string]: number },

	-- Road graph (Workspace.Map.City.RoadGraphJson / RoadGraph folder). Defaults when an edge has no lane data.
	GraphWaitSeconds = 90, -- keep polling for the road graph this long after MapReady, then give up
	RoadWidth = 24, -- curb to curb
	LaneOffset = 6, -- default lane centre offset from the road centreline (right-hand traffic)
	IntersectionTrim = 13, -- lanes stop this far from a junction node (stop line); turns curve through it
	BendTrim = 6, -- trim at degree-2 nodes (bends) and dead ends
	SnapToGround = true, -- raycast each node down to the road surface at load

	-- Driving
	SpeedLimit = 32, -- default when an edge has no speed limit
	Accel = 14,
	Brake = 34,
	SimHz = 20, -- server simulation steps per second
	PublishHz = 10, -- pose attribute updates per second (client interpolates)
	MinGap = 5, -- bumper-to-bumper studs when stopped behind someone
	Headway = 0.9, -- seconds of following distance
	LookAhead = 48, -- how far ahead a car looks for leaders and pedestrians
	LeaderLateral = 3.6, -- |side offset| for another car to count as "in my lane"
	StraightBias = 1.6, -- weight of going straight vs turning at junctions
	StopWait = 0.7, -- stop-sign: seconds stopped at the line before going
	StopSignCap = 1, -- cars inside an unsignalled junction at once
	LightCap = 4, -- cars inside a signalled junction at once
	LightMatchRadius = 42, -- a light within this of a junction node can control it
	StuckDespawn = 18, -- seconds stopped (not at a light) before an unseen car is recycled
	UnseenRadius = 170, -- "unseen" = farther than this from every player

	-- Pedestrians in the road
	PedLateral = 4.6,
	HonkDistance = 30,
	HonkCooldown = 2.2,

	-- Emergency yield (fire truck with SirenOn)
	YieldRadius = 120, -- a siren truck within this, coming from behind -> pull over
	OncomingRadius = 55, -- a siren truck ahead coming at us this close -> pull over too
	YieldBehindSlack = 8, -- "behind" = no more than this far ahead along my heading
	PassClear = 18, -- truck this far ahead of me (and going away) = it has passed
	ResumeDelay = 1.2, -- seconds after the truck passes before driving on
	PullOverOffset = 4.2, -- studs toward the curb
	LateralSpeed = 5, -- studs/s sideways while pulling over
	YieldBrake = 45,
	PanicChance = 0.18, -- some drivers panic-swerve instead (comedy)
	PanicSeconds = 1.6,

	-- Getting rammed
	RamSpeed = 18, -- a truck faster than this flings cars it hits
	RamLookahead = 0.28, -- seconds of truck travel added to the hit box (hit before the anchored bump)
	TruckFront = 14, -- truck centre to front bumper
	TruckHalfWidth = 5,
	CarRadius = 3.4,
	FlingUp = 55,
	FlingCarry = 1.15, -- fraction of truck velocity given to the car
	FlingSpin = 6,
	WreckSeconds = 7, -- wrecked car is removed after this
	DriverPopUp = 45,
	DriverSeconds = 4,
	RamToastCooldown = 5,
	Yells = {
		"MY CAR!!",
		"I JUST WASHED IT!",
		"INSURANCE!!!",
		"HEY! I'M DRIVING HERE!",
		"NOT AGAIN!",
		"MY ICE CREAM!",
		"I'M TELLING YOUR CAPTAIN!",
		"WORTH IT?!",
	} :: { string },

	-- Client
	InterpDelay = 0.16, -- render this far in the past (1.5 x publish interval)
	MaxExtrapolate = 0.3,
	RenderRadius = 520, -- cars farther than this are not moved on the client
	HonkSound = "Horn", -- AudioConfig sound name
	BobAmplitude = 0.12,
})
