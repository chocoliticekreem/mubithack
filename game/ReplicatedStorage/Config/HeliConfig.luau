--!strict
-- HeliConfig [owner: Heli]. The FIRE HELICOPTER game pass (MonetizationConfig key "Helicopter"): numbers
-- for flight (HeliController), the bucket (HeliService) and the station helipad. Data only, no logic.
-- Read at use time, so DevHook ".Set" live-tuning works:
--   ServerStorage.DevHook:Invoke("HeliConfig", ".Set", "DropRadius", 22)
-- Studio test without the real pass: on the server, player:SetAttribute("PassDebug_Helicopter", true)
-- (MonetizationService mirrors it into Pass_Helicopter, which is all the heli code reads).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	PassKey = "Helicopter", -- MonetizationConfig.GamePasses key; owning it = Player attr Pass_Helicopter

	-- Flight (client, the pilot owns the physics). Arcade: the stick / WASD moves you relative to the
	-- camera, the heli turns to face where it goes, it always hovers level (it can't flip).
	Speed = 70, -- studs/s top horizontal speed
	BoostSpeed = 95, -- high up (over AltitudeBoostAbove clearance) it may go this fast
	AltitudeBoostAbove = 60,
	Accel = 2.6, -- how fast the velocity catches up with the stick (per second, exponential)
	ClimbSpeed = 34, -- studs/s up / down
	TurnRate = 2.4, -- yaw catch-up (per second, exponential)
	TiltDegrees = 14, -- nose-down lean at full speed (visual; the hover stays level)
	BankDegrees = 10, -- lean into turns
	MinClearance = 3.2, -- skids above the ground (raycast) while flying: it never touches down by itself
	MaxY = 260, -- absolute ceiling (studs)
	BoundsMargin = 60, -- soft push back this far inside the world walls
	ObstacleProbe = 9, -- studs ahead: a wall there stops the forward push and lifts you over it
	ObstacleLift = 26, -- studs/s of free climb when something blocks you
	TouchSpeedScale = 0.85, -- phones: a little gentler

	-- Camera (Custom camera follows the heli body; you keep mouse / right stick / drag look)
	CamMinZoom = 34,
	CamMaxZoom = 90,

	-- Bucket (server-authoritative). Fill: hover low with the bucket in / over water (Hydrant-tagged ponds,
	-- pools, the creek, hydrants, terrain water, or the helipad's HeliWater tank). Drop: one big dump.
	RopeLength = 11, -- studs from the belly to the bucket
	FillSeconds = 2.2, -- empty -> full while the bucket is in the water
	FillReach = 7, -- bucket bottom within this many studs above the water surface counts as "in"
	FillMargin = 5, -- studs around a water part's footprint that still count
	DropRadius = 18, -- fires within ~this many studs (flat) of the splash point go out
	DropLitres = 40, -- per burning part hit (FireConfig.CoolPerLitre 9 -> 360 heat: any fire is out)
	DropDepth = 45, -- also fires this far under the splash point (inside the building under a roof)
	DropAbove = 12, -- ...and this far over it
	DropMaxParts = 14, -- at most this many burning parts per drop (strong, never a whole big call)
	DropMaxHeight = 90, -- bucket more than this above the ground = "Too high! Fly lower"
	DropCooldown = 8, -- seconds from one drop to the next (the refill cycle); RemoteEvent rate limited too
	ShakeRadius = 70, -- players this close to a splash get a little screen shake

	-- Spawning
	SummonCooldown = 12, -- seconds between summons / helipad calls per owner
	MaxPerOwner = 1,
	Passengers = 3, -- ride seats (friends!) besides the pilot
	SummonRange = 26, -- studs from you where a summoned heli lands (a clear spot)
	LandSpeed = 22, -- studs/s safe auto-land when the pilot leaves (or presses EXIT in the air)
	IdleDespawnSeconds = 600, -- an empty heli far from its owner for this long goes home (despawns)

	-- The station helipad (StationBuilder local studs; street = +Z). It sits on the lawn BEHIND the east
	-- parking lot (lot X 76..158, Z -50..54), so nothing on it is ever in a truck's way: the overflow
	-- trucks face the street and drive straight out (VehicleConfig.OverflowSpots). A paved path runs from
	-- the lot's back edge to the kiosk on the pad's front (+Z) edge.
	Pad = {
		LocationId = "Station",
		Center = Vector3.new(120, 0.5, -80), -- floor point under the H
		Radius = 13,
		WaterOffset = Vector3.new(0, 0, -28), -- the refill tank, from the pad centre (behind it, away from the lot)
		WaterRadius = 7,
		SpareOffsets = { Vector3.new(-28, 0, 0), Vector3.new(28, 0, 0) }, -- more landing spots beside the pad
	},

	-- Keys (doc 16 / 17): move = WASD / left stick, look = mouse / right stick.
	-- UP: Space / R2 or A.  DOWN: Q or Shift / L2.  DROP: click or G / X or R1.  OUT: F / B.
	-- (not E: E still triggers prompts, e.g. a truck door, while you hover low beside it)
	KeyUp = { Enum.KeyCode.Space },
	KeyDown = { Enum.KeyCode.Q, Enum.KeyCode.LeftShift },
	KeyDrop = { Enum.KeyCode.G },
	KeyExit = { Enum.KeyCode.F },
	KeySummon = Enum.KeyCode.U, -- on foot, owners: call your heli (H is HELP / horn, J skip guide, L/Y/N dispatch)
	PadUp = { Enum.KeyCode.ButtonR2, Enum.KeyCode.ButtonA },
	PadDown = { Enum.KeyCode.ButtonL2 },
	PadDrop = { Enum.KeyCode.ButtonX, Enum.KeyCode.ButtonR1 },
	PadExit = { Enum.KeyCode.ButtonB },

	-- Look
	BodyColor = Color3.fromHex("#D9372A"),
	StripeColor = Color3.fromHex("#FFF6EA"),
	TrimColor = Color3.fromHex("#2A2A30"),
	BucketColor = Color3.fromHex("#FF8A1F"),
	WaterColor = Color3.fromHex("#4FB3D9"),
	RotorRpm = 360, -- visual main-rotor spin, revolutions per minute (client only)

	-- Sounds (ids "" = none; same rule as AudioConfig)
	SplashSoundId = "rbxassetid://140727221118804", -- AudioConfig CartoonSplash (the big dump)
	FillSoundId = "rbxassetid://9125703162", -- AudioConfig Splash (the bucket dips in)
	RotorSoundId = "", -- no licensed rotor loop yet
})
