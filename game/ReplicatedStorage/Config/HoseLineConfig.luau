--!strict
-- HoseLineConfig [owner: G1 / hose lines]. Numbers for the physical hose line (Lib/Tools/HoseLine)
-- and its client renderer (HoseLineController). Read at use time so DevHook ".Set" tuning applies.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- length and chain
	LengthTruck = 60, -- studs of hose from a truck reel (any source not tagged Hydrant)
	LengthHydrant = 35, -- studs of hose from a hydrant
	SegmentTarget = 4, -- preferred studs per physical segment
	MinSegments = 4,
	MaxSegments = 16, -- hard cap per hose (performance)
	MaxHosesPerInstance = 4, -- cap per mission instance (Player attr InstanceId; "" = lobby)
	MaxHoses = 24, -- cap per server; attach() returns false beyond either cap
	Thickness = 0.55, -- segment diameter (physics part)
	Density = 0.35, -- light: the hose drapes, it doesn't anchor you
	Friction = 0.8,
	HandRopeLength = 1.5, -- rope from the last segment to the holder's hand
	OwnerSplit = 0.5, -- segments [1..N*split] stay server-owned, the rest are owned by the holder

	-- tug of war
	YankSpeed = 38, -- studs/s pulled back toward the source when you hit the end
	YankUp = 14, -- a little hop so the tug reads as funny, not as a wall
	YankGap = 3.5, -- the chain end is this far from your hand => it's taut (wrapped round a pole)
	YankCooldown = 0.7,
	SnapFactor = 1.9, -- straight distance > length * this (a teleport) => the hose detaches

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
	TripSpeed = 13, -- horizontal studs/s; running across a hose trips you, walking doesn't
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
	SoundYank = "", -- rbxassetid://... (unverified ids stay empty)
	SoundTrip = "",
	SoundKink = "",
})
