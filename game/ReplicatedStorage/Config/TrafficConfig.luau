--!strict
-- TrafficConfig [owner: Traffic]. City traffic numbers (docs/game/08 "City"). Read at use time so
-- DevHook ".Set" live-tuning works. Server copy drives TrafficService; client copy drives
-- TrafficController (interpolation, honk visuals). Units: studs, seconds, studs/s.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true, -- false = no traffic at all

	-- Population (spawn and despawn near players only)
	MaxCars = 14, -- hard cap on live cars (was 44: too many, they bunched up and jammed)
	CarsPerPlayer = 5, -- target cars per player, capped by MaxCars
	SpawnMin = 110, -- never spawn closer than this to any player (no pop-in in your face)
	SpawnMax = 360, -- spawn within this of some player
	DespawnRadius = 460, -- cars farther than this from every player vanish
	SpawnClear = 70, -- no other car within this of a spawn point (spread out, no bunches)
	SpawnPerSecond = 1, -- max new cars per second
	-- weights per kind (Lib/Traffic/CarBuilder kinds)
	KindWeights = { sedan = 40, taxi = 18, van = 20, bus = 7, icecream = 5 } :: { [string]: number },

	-- Road graph (Workspace.Map.City.RoadGraphJson / RoadGraph folder). Defaults when an edge has no lane data.
	GraphWaitSeconds = 90, -- keep polling for the road graph this long after MapReady, then give up
	RoadWidth = 24, -- curb to curb (edges without a width)
	LaneOffset = 6, -- default lane centre offset from the road centreline (right-hand traffic)
	JunctionMargin = 9, -- lanes stop this far outside a junction's crossing box (behind crosswalk / stop line)
	StraightTrim = 2, -- trim at straight-through degree-2 nodes (bends trim to the crossing box)
	BendTrim = 6, -- trim at dead ends
	StubMaxLen = 40, -- a dead-end edge this short (site door spur) doesn't count as a junction arm
	StreetLaneFrac = 0.2, -- one lane each way: lane centre at least width x this off the centre line (46 -> 9.2)
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
	TurnAccel = 28, -- lateral accel through junction curves: speed = sqrt(TurnAccel x radius)
	MinTurnSpeed = 9,
	LightMatchRadius = 80, -- a TrafficLight model signals the nearest junction node within this

	-- Junction right-of-way (Lib/Traffic/Junction): reserve the connector, first come first served
	Clearance = 6.5, -- two junction paths closer than this conflict
	GrantTime = 1.3, -- a car reserves its path when it is this many seconds from the line
	GrantDist = 7, -- ... or this close
	MajorHeadStart = 2.5, -- through-road cars count as having arrived this much earlier (unsignalled)
	RerouteAfter = 4, -- waited this long at a free line: pick another exit
	ForceAfter = 9, -- waited this long: go anyway (deadlock breaker)
	GhostAfter = 5, -- stopped without excuse this long: drive through other cars for GhostSeconds
	GhostSeconds = 3,
	PassAfter = 1.5, -- blocked by a parked truck / person this long: drive round it
	PassStalledAfter = 3.5, -- blocked by a stalled car (not queueing) this long: drive round it
	PassOffset = 13, -- studs left into the next lane when passing
	PassLook = 90, -- oncoming lane must be clear this far ahead to pass
	PassMaxSeconds = 10,
	PassLateralSpeed = 9,
	StuckDespawn = 8, -- seconds stopped (no excuse) before an unseen car is recycled
	UnseenRadius = 170, -- "unseen" = farther than this from every player
	BlinkDistance = 45, -- indicators on this far before a turn

	-- Pedestrians in the road
	PedLateral = 4.6,
	HonkDistance = 30,
	HonkCooldown = 2.2,

	-- Emergency yield (fire truck with SirenOn, and moving)
	YieldMinSpeed = 6, -- a parked siren truck is an obstacle to drive round, not a reason to pull over
	SlowYieldBehind = 32, -- ...but a DRIVEN siren truck this close behind a car (any speed) makes it pull over
	SlowYieldLateral = 7, -- (and within this far to the side: same lane)
	YieldMax = 6, -- never sit pulled over longer than this
	YieldImmune = 8, -- after giving up, ignore sirens this long
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
