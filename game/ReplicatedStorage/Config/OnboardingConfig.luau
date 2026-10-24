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
	TitleSeconds = 3.2, -- first join (returning players get a short 1.6 s version)
	ReturningTitleSeconds = 1.6,
	-- tutorial copy: head = header, sub = small line under it ({rack} {bay} {enter} {siren} {horn} are filled in)
	Steps = {
		gear = { head = "GRAB YOUR GEAR", sub = "Your rack is #{rack} in the locker room. Walk up and press E." },
		board = { head = "CHECK THE MISSION BOARD", sub = "Out front by the bays. Press E to pick a call." },
		pad = { head = "STEP ON A GLOWING PAD", sub = "Bring friends! Everyone on the pad rolls out together." },
		wait = { head = "ROLLING OUT SOON", sub = "Friends can still hop on your pad. Leader can hit GO NOW." },
	},
	Hints = {
		door = { head = "RUN TO BAY {bay}", sub = "Open YOUR truck's door (E)" },
		seat = { head = "HOP IN!", sub = "Driver's seat: press {enter}" },
		drive = { head = "FOLLOW THE GPS", sub = "W/S drive  -  A/D steer  -  {siren} siren  -  {horn} horn" },
	},
	DriveHintSeconds = 8,
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
	DoneAttr = "Onboarded", -- Player attr: true = skip the tutorial (DataService settings.onboarded)
})
