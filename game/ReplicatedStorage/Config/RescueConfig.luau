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
	SpeedPanda = 0.4, -- solo (only allowed when nobody else is around to help)
	SpeedPandaPair = 0.6, -- each of the two carriers
	PandaCarriers = 2, -- players needed to lift the panda
	PandaPairWindow = 2.5, -- s: both "Pick up" triggers must land within this window
	PandaSoloIfAlone = true, -- a lone player may drag the panda (at SpeedPanda) so solo runs can finish
	PandaPairSnap = 16, -- studs: carriers further apart than this drop the panda
	-- hold point in front of the carrier's HumanoidRootPart (studs: up, forward)
	HoldUp = 0.6,
	HoldForward = 3.2,
	HoldForwardPanda = 4.5,
	HoldResponsiveness = 28, -- AlignPosition: lower = more wobble/lag
	HoldTwistResponsiveness = 9, -- AlignOrientation: lower = more swing
	DeliverPad = 2, -- studs added around the RescueDropoff box when checking delivery
	-- throwing (hold Q while carrying, release to YEET)
	ThrowChargeTime = 1.0, -- s of holding for a full-power throw
	ThrowMin = 25, -- studs/s forward at zero charge
	ThrowMax = 70, -- studs/s forward at full charge
	ThrowUp = 28, -- studs/s upward at full charge
	ThrowPandaMult = 0.35, -- the panda barely leaves your arms
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
	FireHurtRadius = 7, -- studs to a Burning part that hurts
	FireDps = 12, -- HP/s at FireLevel 2, point blank
	CarriedFireMult = 0.5, -- damage multiplier while being carried
	LandInFireDamage = 45, -- HP lost when yeeted into a burning spot
	TickHz = 8, -- AI / fire / delivery tick
	-- sounds (client side; "" = silent)
	SoundScream = "",
	SoundWoof = "",
	SoundMeow = "",
	SoundPanda = "",
	SoundCheer = "",
	SoundWhoosh = "",
	SoundThud = "",
	SoundSizzle = "",
	VoiceInterval = 1.6, -- s between screams while carried / flying
	Confetti = 90, -- particles in the delivery burst
})
