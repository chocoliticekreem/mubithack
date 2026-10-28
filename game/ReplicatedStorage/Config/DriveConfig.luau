--!strict
-- DriveConfig [owner: Drive]. The drive from the station to a call (Services/DriveService,
-- Controllers/DriveController, Lib/Vehicle/DriveMath). Live funnel: 28-35% of players quit between
-- "In Truck" and "Arrived On Scene", so the drive gets telemetry, things for riders to do, a road
-- route you can't miss and a quicker truck on straight roads. NO autopilot: a kid always drives.
-- Read at use time so DevHook ".Set" tuning applies (client copies are separate).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- telemetry (server)
	TickSeconds = 0.5, -- how often DriveService looks at every drive
	RouteRefresh = 3, -- seconds between server route recomputes (distance left, wrong way)
	OffRoute = 35, -- studs off the server route = recompute now
	StuckSeconds = 5, -- the truck got no closer than StuckStuds in this long = one "stuck" episode
	StuckStuds = 4,
	WrongWayMinSpeed = 8, -- studs/s: moving at least this fast while the road distance left grows = wrong way

	-- straight-road boost (driver's client, VehicleController): top speed x this on a straight road
	-- while dispatched, and only the top speed (accel / steering / turning circle stay PR #253's)
	StraightBoostRookie = 1.3, -- rookie calls (run attr Rookie)
	StraightBoostCall = 1.12, -- every other call
	StraightMaxDeg = 12, -- truck within this many degrees of the road's direction ...
	StraightMaxSteer = 0.25, -- ... and the stick / keys steering less than this
	StraightRoadRange = 26, -- studs from the road's centre line
	BoostRise = 0.8, -- 1/s: the boost eases in ...
	BoostFall = 2.5, -- ... and back out (into a turn) faster

	-- practice fires along the route (riders spray them with the roof water cannon)
	Targets = false, -- off: burning bins along every squad's route cluttered the streets for everyone
	TargetMax = 6, -- per call
	TargetSpacing = 55, -- studs along the route between two
	TargetSkipStart = 35, -- none this close to the start ...
	TargetSkipEnd = 50, -- ... or the call
	TargetCurbOffset = 4, -- studs past the road edge (half the road width), on the sidewalk
	TargetHits = 3, -- spray hits to put one out (the client sends one hit per HitInterval)
	HitInterval = 0.25,
	TargetXp = 5, -- per practice fire, to whoever finished it
	TargetRange = 120, -- studs from the rider's truck to the target (server check)
	CannonRange = 110, -- client: auto-aim reaches this far
	CannonCone = 0.2, -- client: auto-aim takes targets in front of the camera (look dot > this)

	-- HUD (client)
	EtaMinSpeed = 30, -- studs/s: the ETA never assumes slower than this (a parked truck still says ~Ns)
	EtaSmoothing = 2, -- 1/s
	TurnShowStuds = 110, -- the big TURN arrow shows when the next turn is this close ...
	TurnHideStuds = 6, -- ... until you're this close to it
	WrongWaySeconds = 1.5, -- facing back along the route this long while moving = "WRONG WAY!"
	NoDriverSeconds = 3, -- a rider on a call with an empty driver seat this long = "NOBODY'S DRIVING!"
	TouchTurnAlways = true, -- touch drivers on a call: the turn card never hides (TURN / STRAIGHT ON / WRONG WAY)

	-- auto-unstick (driver's client, VehicleController; any device). Live: phones/tablets logged TruckStuck about
	-- as often as DriveStart, and the server's "Truck reset!" net needs the seat throttle >= 0.5, which a
	-- thumb pushing sideways (TruckDrive.touchStick cruise) never reports. NOT autopilot: only a held push.
	Unstick = true,
	UnstickSeconds = 3, -- pushing this long ...
	UnstickStuds = 2.5, -- ... without getting this far = stuck: lift, back off a few studs, nose toward the route
	UnstickCooldown = 4, -- seconds between two (the server's Truck reset! net catches what this can't)
	UnstickLift = 1.2, -- studs over the ground the spot is checked / placed at
	UnstickClearance = 0.6, -- studs shaved off the truck box for the "is this spot free?" check

	-- touch route assist (driver's client, touch only, on a call). Not autopilot: it only bends the truck's
	-- turn toward the GPS line while the kid is pushing forward with the stick (nearly) centred.
	Assist = true,
	AssistLookAhead = 26, -- studs ahead on the route the nose is pulled toward
	AssistGain = 1.4, -- rad/s per rad of heading error
	AssistMaxSteer = 0.35, -- stick steering past this = the kid is turning: no assist (fades out up to it)
	AssistMaxDeg = 50, -- only when the route is within this many degrees of the nose (never fights a U-turn)
	AssistMaxOff = 40, -- ... and the truck is within this many studs of the route line
	AssistMinSpeed = 5, -- studs/s forward
})
