--!strict
-- InventoryConfig [owner: Inventory]. Numbers for the physical, goofy inventory (InventoryService /
-- InventoryController, item data in ReplicatedStorage/Lib/Items/ItemDefs). Read at use time so
-- DevHook ".Set" tuning applies.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- prompts
	GrabDistance = 9, -- ProximityPrompt MaxActivationDistance on items, racks and compartments
	PropGrabDistance = 8,
	RestockSeconds = 0.3, -- station racks: unlimited, the slot refills right after someone grabs from it
	TruckRestockSeconds = 30, -- truck compartments: an item grows back on the truck after this long

	-- drop and throw
	DropForward = 2.5, -- studs in front of you a dropped item lands
	ThrowChargeSeconds = 0.9, -- hold Q this long for a full-power throw (client)
	ThrowMinSpeed = 28,
	ThrowMaxSpeed = 88,
	ThrowLift = 18, -- extra upward speed so throws arc
	ThrowSpin = 16, -- rad/s tumble on a thrown item
	BonkSeconds = 1.6, -- a thrown item can bonk people for this long after leaving your hand
	BonkMinSpeed = 16, -- ...while it still moves at least this fast
	BonkPush = 34, -- knockback on the bonked player
	BonkLift = 16,
	BonkRagdollSeconds = 1.1,
	FumbleSpeed = 14, -- ragdoll fumble: the hand item pops out at this speed
	MaxLooseItems = 40, -- dropped/thrown items in the world (server); the oldest is removed beyond
	LooseSeconds = 240, -- an untouched loose item despawns (a dropped nozzle reels itself back in)

	-- carry (props tagged CarryTag; NPCs belong to RescueService)
	CarryTag = "Carryable",
	CarryMaxMass = 250, -- heavier assemblies can't be picked up
	CarryOffset = Vector3.new(0, 0.6, -2.6), -- held in front of the chest (root space)

	-- the truck tank (truck attrs Water / TankSize) and hydrant supply lines
	TruckTankSize = 600, -- litres
	SupplyLength = 45, -- studs of supply line from hydrant to truck
	SupplySnapFactor = 1.5, -- the truck drove off: the line pops off past length * this
	SupplyRate = 40, -- litres per second into the truck tank
	SupplyTickHz = 4,

	-- oxygen tank (back slot)
	OxygenAir = 90, -- seconds of air in a full tank
	OxygenCool = 4, -- HeatService:Cool per second while wearing it and hot
	OxygenMinHeat = 15, -- only breathes (and drains) above this Heat

	-- hose nozzle
	ReelReturnDistance = 12, -- hand the nozzle back at the reel within this many studs
	HosesPerTruck = 2, -- nozzles one truck reel can have out at once (held or lying), anyone's truck
	HosesPerHydrant = 1,
	TruckHoseReach = 7, -- [T] Grab / Stow Hose works this far out from any side of the truck
	TruckHoseKey = Enum.KeyCode.T, -- its own key, so it never hides the [E] locker and door prompts

	-- thrown axes (and the other long tools) tomahawk end over end
	ThrowSpinItems = { "Axe", "FireAxe", "GoldenAxe", "Halligan", "Sledgehammer", "Crowbar" },
	AxeThrowSpin = 24, -- rad/s around the sideways axis (~4 turns a second)

	-- UI (client)
	HotbarSlotSize = 72, -- keeps the row under HudController's toast stack
	HighlightColor = Color3.fromHex("#FFE15A"),
	SoundGrab = "", -- rbxassetid://... (unverified ids stay empty)
	SoundDrop = "",
	SoundThrow = "",
	SoundBonk = "",
})
