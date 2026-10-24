--!strict
-- RescueConfig [owner: G3]. Civilians and pets (docs/game/01 §6, §7.1). Read on the server by
-- RescueService and on the client by RescueController (hold-to-throw, voices, confetti).
-- Sound ids are left "" on purpose: drop in rbxassetid://... values you have permission to use.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Count = 5, -- NPCs spawned per round (one per RescueSpawn marker, up to this many)
	CarryReach = 12, -- studs: a Pick up prompt trigger further away than this is ignored
	CarryHold = 0.5, -- seconds to hold the Pick up prompt
	PromptDistance = 8, -- ProximityPrompt MaxActivationDistance
	WalkSpeed = 16, -- normal speed restored after a drop or delivery
	-- carrier speed multiplier per kind (the panda is heavy)
	SpeedCivilian = 0.75,
	SpeedDog = 0.95,
	SpeedCat = 0.95,
	SpeedPanda = 0.85, -- one penguin carries the panda (kids: no pairing needed)
	SpeedPandaPair = 0.6, -- each of the two carriers
	PandaCarriers = 1, -- players needed to lift the panda (was 2: too hard for kids)
	PandaPairWindow = 2.5, -- s: both "Pick up" triggers must land within this window
	PandaSoloIfAlone = true, -- a lone player may drag the panda (at SpeedPanda) so solo runs can finish
	PandaPairSnap = 16, -- studs: carriers further apart than this drop the panda
	-- hold point in front of the carrier's HumanoidRootPart (studs: up, forward)
	HoldUp = 0.6,
	HoldForward = 3.2,
	HoldForwardPanda = 4.5,
	HoldResponsiveness = 28, -- AlignPosition: lower = more wobble/lag
	HoldTwistResponsiveness = 9, -- AlignOrientation: lower = more swing
	DeliverPad = 14, -- studs added around the RescueDropoff box: anywhere NEAR the truck delivers (no need to get inside it)
	-- throwing (hold Q while carrying, release to YEET)
	ThrowChargeTime = 1.0, -- s of holding for a full-power throw
	ThrowMin = 25, -- studs/s forward at zero charge
	ThrowMax = 70, -- studs/s forward at full charge
	ThrowUp = 28, -- studs/s upward at full charge
	ThrowPandaMult = 0.6, -- the panda is heavy but you can still yeet it
	ThrowSpin = 12, -- rad/s random tumble
	DownedImpact = 55, -- studs/s: a landing faster than this knocks the NPC out (Downed, X eyes)
	LandRagdoll = 1.4, -- s an NPC lies flopped after landing before it gets up
	BlameWindow = 8, -- s after a throw/drop that the thrower/dropper is blamed for a toasting
	-- fire
	Health = 100,
	PanicRadius = 20, -- studs to a Burning part that starts a panic
	PanicCircle = 4, -- studs: radius of the panic circle
	PanicSpeed = 12, -- studs/s while running in circles
	PanicCalm = 3, -- s with no fire near before the panic stops
	-- panic brain v2: steered, wall-aware movement (every step is shapecast before it's taken)
	PanicLeash = 14, -- studs from its spawn spot an NPC may run (stays in its room/flat)
	PanicSpeedDog = 17, -- zoomies
	PanicSpeedCat = 15,
	PanicSpeedPanda = 5, -- waddle
	BodyRadius = 0.9, -- spherecast radius (civilian/panda); pets use PetRadius
	PetRadius = 0.6,
	WallGap = 0.6, -- studs kept between the body and a wall
	StepUp = 1.6, -- studs an NPC can step up (stairs, rugs)
	StepDown = 2.2, -- studs it will step down; bigger drops (balcony, stairwell) are refused
	SeeRadius = 26, -- studs: a firefighter in line of sight this close = "a firefighter came in"
	HearRadius = 45, -- studs: a firefighter this close but out of sight = "HELP! IN HERE!"
	ApproachStop = 4.5, -- studs from the firefighter an approaching NPC stops and waves
	HelpEvery = 3.5, -- s between "HELP! IN HERE!" shouts
	CoughEvery = 2.6, -- s between coughs in smoke
	SmokeAttr = "Smoke", -- room/part attribute (bool, 0..1, 0..100 or "light"/"heavy"); optional
	SmokeFireRadius = 9, -- studs: a FireLevel>=2 fire this close counts as smoke without the attribute
	HideReach = 7, -- studs a cat searches for something to hide under
	CowerDrop = 0.7, -- studs a cowering NPC crouches
	FireHurtRadius = 5, -- studs to a Burning part that hurts
	FireDps = 2.5, -- HP/s at FireLevel 2, point blank (~40 s next to a fire, ~27 s in a blaze)
	CarriedFireMult = 0.5, -- damage multiplier while being carried
	LandInFireDamage = 30, -- HP lost when yeeted into a burning spot
	TickHz = 8, -- AI / fire / delivery tick
	-- sounds (client side; "" = silent)
	SoundScream = "rbxassetid://9125905021", -- (PSE) scream pass-by
	SoundWoof = "rbxassetid://135016436724006",
	SoundMeow = "rbxassetid://134699420140804",
	SoundPanda = "",
	SoundCheer = "rbxassetid://113203014154811", -- "woohoo!"
	SoundWhoosh = "rbxassetid://9120972321", -- (PSE) wood whoosh
	SoundThud = "rbxassetid://9113479635", -- (PSE) body fall on carpet
	SoundSizzle = "rbxassetid://4772620521", -- steam hiss (same as AudioConfig.Steam)
	VoiceInterval = 1.6, -- s between screams while carried / flying
	Confetti = 90, -- particles in the delivery burst
})
