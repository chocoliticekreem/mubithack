--!strict
-- StructureConfig [owner: Structure agent]. Building integrity / collapse numbers (StructureService,
-- Lib/Fire/Structure, StructureFxController). Read at use time so DevHook ".Set" live-tunes.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Tag = "Structure", -- CollectionService tag on every indexed building Model (client FX + HUD find them)
	TickHz = 4,
	MinChunks = 6, -- a BuildingId Model with fewer wall/roof/floor parts is not a building (fields, woods)
	MaxPartsPerStructure = 2500, -- descendants scanned per building (budget)
	-- support graph (studs)
	GroundTolerance = 2.5, -- chunks whose bottom is this close to the lowest one stand on the ground
	SupportGap = 1.5, -- a support's top may poke this far above the chunk's bottom
	SupportDrop = 8, -- ...or sit this far below it (slanted roof slabs)
	SupportReach = 6, -- horizontal gap allowed between a chunk and its supports
	MaxSupports = 8, -- nearest supports kept per chunk
	-- integrity weights per kind (windows never count)
	Weight = { wall = 1, partition = 0.5, roof = 1, floor = 0.8, ground = 0.3, window = 0 },
	-- damage
	BurnRate = 0.008, -- hp/s per FireLevel while a chunk burns (level 3: ~17 s to nothing)
	CharredHp = 0.15, -- a burnt-out chunk keeps this much
	FailHp = { roof = 0.2, floor = 0.2 }, -- roofs cave in / upper floors give way at or below this hp
	SupportMin = 0.4, -- a chunk whose supports average below this falls
	CharredFallChance = { wall = 0.015, partition = 0.05 }, -- per second, for charred walls (not in a shell)
	WindowHeatRadius = 10,
	ShatterHeat = 6, -- sum of FireLevel-seconds nearby before a window blows out
	TotalLossAt = 15, -- integrity at/below this = TOTAL LOSS (snaps to 0, shell)
	SavedAt = 50, -- integrity at/above this at mission end = "saved the building" star
	-- collapse
	WarnSeconds = 2, -- timber creak + shake before a section falls
	ClusterRadius = 14, -- failures this close fall together (one creak, one crash)
	MaxCollapsesPerTick = 3, -- clusters started per structure per tick
	AttachMaxPerChunk = 14, -- trim/shutters/furniture riding down with a chunk
	MaxLooseDebris = 140, -- server-wide unanchored rubble; beyond it pieces crumble to dust instead
	SettleMinSeconds = 1.5, -- rubble re-anchors once it is this old and nearly still...
	SettleMaxSeconds = 6, -- ...or this old regardless
	SettleSpeed = 1.5,
	FallKick = 1.2, -- random angular velocity on fallen pieces (rad/s; they tip, they don't spin away)
	-- containment (Lib/Physics/Rubble): debris falls DOWN and stays on the plot
	RubbleFreshSeconds = 0.5, -- fresh pieces ignore other rubble (overlapping chunks would explode apart)
	RubbleMaxHorizontal = 10, -- studs/s sideways cap on every loose piece
	RubbleMaxUp = 6, -- studs/s upward cap (no bouncing up off the ground)
	RubbleMaxDown = 70, -- studs/s fall cap (softer landings, fewer deep overlaps)
	RubbleMaxSpin = 3, -- rad/s
	RubbleLeash = 8, -- + half its footprint: beyond this from where it let go it loses outward speed
	RubbleMaxDrift = 40, -- beyond this it crumbles to dust (never lands in the street)
	RubbleDensity = 0.9, -- sane, heavy-ish, no bounce
	RubbleFriction = 1.2,
	-- hurting people
	HurtRadius = 10, -- beyond the section's footprint
	PlayerHeat = 30, -- HeatService:AddHeat at the centre (100 = Downed)
	NpcDamage = 45, -- RescueService:Hurt at the centre (Health points)
	RagdollSeconds = 2,
	-- presentation
	NotifyRadius = 260, -- players this close (or in the run) get toasts / TOTAL LOSS
	SmokeLingerSeconds = 40, -- a building keeps smoking this long after its last flame
	-- client
	ClientSmokeMax = 40, -- window smoke emitters, nearest first
	ClientSmokeDistance = 260,
	HudDistance = 160, -- integrity bar shows for the nearest damaged building this close
	ShakeDistance = 60,
})
