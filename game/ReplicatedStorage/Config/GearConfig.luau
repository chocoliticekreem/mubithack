--!strict
-- GearConfig [owner: Gear]. Numbers for GearService / GearController: the breaching tools (Halligan,
-- Crowbar, Sledgehammer, Rescue Saw), the ladder, thermal camera, flashlight, gas mask, door kicks,
-- climbing in through windows, roof hatches and the station locker. Unlock levels and axe tiers are
-- item data (Lib/Items/ItemDefs + Progression). Read at use time so DevHook ".Set" tuning applies.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- reach (studs from HumanoidRootPart) for every tool verb
	Reach = 9,
	FacingDot = 0.25, -- the target must be roughly in front of you

	-- pry bars (Halligan / Crowbar: ItemDefs.pry seconds); the player must stay near while prying
	PryStayStuds = 11,

	-- sledgehammer: hits to break a weak wall chunk (a window always goes in one)
	SledgeCooldown = 0.9,
	SledgeWallHits = 3,
	WeakWallMaxSize = 9, -- a "Wall"/"Partition" chunk of an IncidentSite this wide or narrower can be breached
	BreachHealSeconds = 240, -- breached chunks outside StructureService's reset come back after this
	SawCooldown = 0.3,

	-- kicks (no tool): chance from Progression.kickChance; a failed kick ragdolls you backwards
	KickCooldown = 1.4,
	KickFailRagdoll = 1.4,
	KickFailPush = 38,
	KickFailLift = 22,
	KickKey = Enum.KeyCode.F,

	-- broken windows: "Climb in" puts you this far past the pane
	ClimbThrough = 3.2,
	ClimbPromptDistance = 7,

	-- ladder: a TrussPart stood against the wall in front of you
	LadderMaxHeight = 34,
	LadderMinHeight = 8,
	LadderWidth = 2.2,
	LadderLean = 0.9, -- studs out from the wall at the base
	MaxLadders = 12,

	-- roof hatches on IncidentSite buildings (opened by anyone; faster with a pry bar)
	HatchSize = Vector3.new(4, 0.5, 4),
	HatchOpenSeconds = 2.5, -- prompt hold without a pry bar
	HatchPrySeconds = 0.6,

	-- thermal camera (client): Rescuable NPCs within this range glow through walls
	ThermalRange = 160,
	ThermalHot = Color3.fromHex("#FFB23A"),
	ThermalCold = Color3.fromHex("#3B2A7A"),

	-- flashlight
	FlashRange = 60,
	FlashAngle = 48,
	FlashBrightness = 4,
	FlashColor = Color3.fromHex("#FFF2D0"),

	-- gas mask (client overlay + breathing; server sets the GasMask player attr)
	BreathSound = "", -- rbxassetid://... breathing loop; "" = the synthesized fallback (filtered noise pulse)
	BreathVolume = 0.35,
	MuffleHighGain = -18, -- dB on the world's highs while masked (EqualizerSoundEffect)

	-- locker / rack pegs
	PegRestockSeconds = 0.3, -- infinite stock
	LockerDistance = 9,
})
