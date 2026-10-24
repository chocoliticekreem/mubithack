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
	-- tutorial copy: head = header, sub = small line under it ({rack} {bay} {enter} {siren} {horn} are filled in).
	-- Key hints ("press E") are rewritten for touch / gamepad by ClientLib/InputHints; subTouch / subPad
	-- replace a line whole where that rewrite isn't enough.
	Steps = {
		gear = { head = "GRAB YOUR GEAR", sub = "Your rack is #{rack} in the locker room. Walk up and press E." },
		board = { head = "CHECK THE MISSION BOARD", sub = "Out front by the bays. Press E to pick a call." },
		pad = { head = "STEP ON A GLOWING PAD", sub = "Bring friends! Everyone on the pad rolls out together." },
		wait = { head = "ROLLING OUT SOON", sub = "Friends can still hop on your pad. Leader can hit GO NOW." },
	},
	Hints = {
		-- touch: one tap on the truck sits you in (Controllers/TapUseController), no door to open first
		door = { head = "RUN TO BAY {bay}", sub = "Open YOUR truck's door (E)", subTouch = "Tap YOUR truck to hop in" },
		seat = { head = "HOP IN!", sub = "Driver's seat: press {enter}", subTouch = "Tap the truck to hop in" },
		drive = {
			head = "FOLLOW THE GPS",
			sub = "W/S drive  -  A/D steer  -  {siren} siren  -  {horn} horn",
			-- phones / gamepads (ClientLib/InputHints): the truck's own on-screen buttons
			subTouch = "Stick to drive  -  SIREN and HONK buttons",
			subPad = "Stick to drive  -  X siren  -  Y horn",
		},
	},
	DriveHintSeconds = 8,
	ArrivedStuds = 150, -- within this of the GPS waypoint = at the scene: the RUN TO BAY / HOP IN cards stop
	DispatchHintDelay = 3.5, -- s after dispatch before "RUN TO BAY n" (the HUD ALARM banner goes first)
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
