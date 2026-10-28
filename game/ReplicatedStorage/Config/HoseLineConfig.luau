--!strict
-- HoseLineConfig [owner: G1 / hose lines]. Numbers for the physical hose line (Lib/Tools/HoseLine)
-- and its client renderer (HoseLineController). Read at use time so DevHook ".Set" tuning applies.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- length and chain
	LengthTruck = 200, -- studs of hose from a truck reel (any source not tagged Hydrant)
	LengthHydrant = 120, -- studs of hose from a hydrant
	SegmentTarget = 6, -- preferred studs per physical segment
	MinSegments = 4,
	MaxSegments = 32, -- hard cap per hose (performance)
	MaxHosesPerInstance = 6, -- cap per mission instance (Player attr InstanceId; "" = lobby), held + lying
	MaxHoses = 24, -- cap per server; attach() returns false beyond either cap
	Thickness = 0.55, -- segment diameter (physics part)
	Density = 0.35, -- light: the hose drapes, it doesn't anchor you
	Friction = 0.8,
	HandRopeLength = 1.5, -- normal slack between the chain's tip and the hand (no rope: nothing ties you to the hose)
	-- dropped: the line stays lying from the source to the nozzle (HoseLine.release) until someone picks
	-- it up, the truck drives off, the call ends or nobody touched it for LyingSeconds
	LyingRopeLength = 2, -- the lying chain's tip is tied this close to the dropped nozzle
	LyingSeconds = 120, -- a dropped nozzle (and its line) reels itself back in after this long
	LyingStowSpeed = 6, -- (legacy) lying lines now go back on the reel as soon as their truck drives (TruckMoveSpeed)
	TruckMoveSpeed = 3, -- studs/s: a truck rolling faster (or anyone in its driver seat) is "driving": its held
	-- hoses are stowed (counter hose_detached_truck_moving) and no hose can be grabbed off it
	FollowForce = 8000, -- pull on the hose tip toward the hand (never on the holder); 2500 stalled the tip ~100 studs out
	FollowResponsiveness = 30,
	OwnerSplit = 0.5, -- segments [1..N*split] stay server-owned, the rest are owned by the holder

	-- tug of war
	YankSpeed = 14, -- studs/s tugged back toward the source when you run out of hose (no knockdown)
	YankUp = 0,
	YankGap = 1e9, -- off: a chain dragging behind you while you walk is not taut (it yanked every step)
	YankCooldown = 0.7,
	SnapFactor = 1.9, -- straight distance > length * this (a teleport) => the hose detaches
	SnapGap = 100, -- hand this far past the chain's tip for 0.25 s (teleport, Truck reset!, a snag) => you let go of the line (a walking tip lags up to ~50)

	-- stepping on hoses
	StandRadius = 1.4, -- feet within this of a segment = standing on it
	KinkDelay = 0.35, -- seconds standing on it before it kinks
	KinkCooldown = 3, -- seconds before the same culprit can be blamed again for the same hose
	KinkLoss = 0.45, -- pressure lost per player standing on your hose
	TangleLoss = 0.15, -- pressure lost per crossing with another hose
	TangleMaxDy = 2.5, -- crossing only counts if the two hoses are this close vertically
	MinPressure = 0.1,
	OwnerIgnoreSegments = 2, -- the holder's own feet don't kink the last N segments

	-- tripping
	TripSpeed = 22, -- horizontal studs/s; only a full sprint across someone else's hose trips you
	TripCooldown = 2.5,
	TripPush = 18, -- forward stumble velocity
	TripUp = 8,
	TripSeconds = 0.9, -- FallingDown duration on the client

	TickHz = 10, -- server checks per second

	-- client rendering
	RenderDistance = 250,
	BeamSegments = 8, -- curve resolution per segment
	KinkWidthScale = 0.45, -- a kinked segment pinches to this fraction of the width
	YankFov = 8, -- FOV punch on a yank
	SoundYank = "rbxassetid://9113611449", -- (PSE) whip swish
	SoundTrip = "rbxassetid://2772396665", -- cartoon boing
	SoundKink = "rbxassetid://9118737438", -- (PSE) rubber squeak
})
