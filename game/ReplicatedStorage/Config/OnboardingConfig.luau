--!strict
-- OnboardingConfig [owner: Onboarding]. First-join title card, the 3-step station tutorial, the
-- contextual dispatch hints and the lobby HUD declutter (Services/OnboardingService,
-- Controllers/OnboardingController, pure logic in Lib/Onboarding/OnboardingFlow).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	Title = "STATION 67",
	Subtitle = "Flame and Blame",
	Tagline = "Save the day. Blame your friends.",
	TitleSeconds = 2.2, -- first join (returning players get a short 1.6 s version); short: the training fire is waiting
	ReturningTitleSeconds = 1.6,
	-- tutorial copy: head = header, sub = small line under it ({bay} {enter} {siren} {horn} are filled in).
	-- Key hints ("press E") are rewritten for touch / gamepad by ClientLib/InputHints; subTouch / subPad
	-- replace a line whole where that rewrite isn't enough.
	Steps = {
		gear = { head = "GRAB YOUR GEAR", sub = "In the LOCKER door, then the big red locker. Walk up and press E.", subTouch = "In the LOCKER door, then the big red locker. Walk up and tap it!" },
		board = { head = "PICK A MISSION", sub = "The big board out front, past the pads. Press E to pick a call.", subTouch = "The big board out front, past the pads. Tap it to pick a call!" },
		pad = { head = "STEP ON A GLOWING PAD", sub = "Out front, right by the door. Everyone on the pad rolls out together!" },
		wait = { head = "ROLLING OUT SOON", sub = "Stay on the pad: at 0 you start IN your fire truck. Leader can hit GO NOW." },
	},
	Hints = {
		-- The squad starts IN its truck (LobbyService boards everyone at launch): no bay run, no door.
		-- "seat" is only for someone who got out on the way. Touch: one tap on the truck sits you in
		-- (Controllers/TapUseController); keyboard: the seat prompt, no door to open first.
		seat = { head = "HOP BACK IN!", sub = "Walk up to the truck and press {enter}", subTouch = "Tap the truck to hop in" },
		ride = { head = "YOU'RE IN THE TRUCK!", sub = "Your driver follows the GPS. Hang on!" },
		drive = {
			head = "HIT THE SIREN! FOLLOW THE GPS",
			sub = "{siren} siren  -  W/S drive  -  A/D steer  -  {horn} horn",
			-- phones / gamepads (ClientLib/InputHints): the truck's own on-screen buttons
			subTouch = "Tap SIREN!  Stick to drive, follow the arrow",
			subPad = "X siren!  Stick to drive  -  Y horn",
		},
	},
	DriveHintSeconds = 8,
	ArrivedStuds = 150, -- within this of the GPS waypoint = at the scene: the IN THE TRUCK / HOP BACK IN cards stop
	DispatchHintDelay = 1.5, -- s after dispatch before the truck card (the boarding fade goes first)
	HelpKey = "H", -- replay the tutorial / show controls
	BoardLookDistance = 16, -- studs: close enough to "look at" the board
	BoardLookDot = 0.75, -- camera look . (board - camera) to count as looking at it
	BoardLookSeconds = 0.8,
	ArrowBob = 0.6, -- studs the world arrow bobs
	ArrowHeight = 4.5, -- studs above the target
	HighlightColor = Color3.fromHex("#FFC531"),
	-- lobby HUD declutter (client-side, only while InstanceId == ""): hide these ScreenGuis / labels.
	-- Graphics stays reachable from the Help (H) panel.
	LobbyHiddenGuis = { "GraphicsSettingsUI", "FeedbackSettingsUI" },
	FadeInSeconds = 0.9,
	SpawnFaceBays = true, -- spawn pads face the apparatus floor (TruckBay parts) instead of the back wall
	SkippedText = "Tutorial skipped. Step on a glowing pad to roll out. H = help.", -- toast after SKIP TUTORIAL
	DoneAttr = "Onboarded", -- Player attr: true = skip the tutorial (DataService settings.onboarded)
})
