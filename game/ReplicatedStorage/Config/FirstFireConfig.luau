--!strict
-- FirstFireConfig [owner: Onboarding]. The first 90 seconds of a brand-new player, Onboarding v3
-- (Services/FirstFireService, Controllers/ColdOpenController + OnboardingController + HudRevealController,
-- pure logic in Lib/Onboarding/FirstFire + ColdOpen, the set in ServerScriptService/Lib/Onboarding/PandaHouse):
--   COLD OPEN (7 s cutscene, skippable after ColdOpen.MinSkip s): a house on fire across the road, a panda
--   waving HELP! in its window, the siren rising as a fire truck pulls up, "SAVE THE PANDA!"
--   -> SPRAY the fire (extinguisher in hand) -> FIRE OUT -> carry the panda OUTSIDE -> PANDA SAVED! (+XP)
--   -> the HUD starts to appear -> auto-queued onto a pad for a short real call.
-- Returning players (Onboarded true) never see any of this. Session-length counters: Services/SessionService.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	-- Panda house spots (PandaHouse.build), across the road from the station's front door, on the open band
	-- of ground north of it. house = the ground point in the middle of the house's front wall (y comes from a
	-- raycast); the house faces -Z (toward the road and the station). stand = where the newbie starts, facing
	-- the house. truck = where the prop truck parks (ground under its centre), truckYaw = its heading in
	-- degrees (0 faces -Z, 180 faces +Z), truckFrom = where the cutscene drives it in from. Several newbies at
	-- once: a spot whose house is still burning is shared, else the next free spot; a spot that is blocked on
	-- this map (anything in SpotClearSize around the house) is skipped.
	Spots = {
		{ house = Vector3.new(-53, 0, 252), stand = Vector3.new(-50, 3.5, 237), truck = Vector3.new(-30, 0, 262), truckYaw = 180, truckFrom = Vector3.new(-16, 0, 206) },
		{ house = Vector3.new(-108, 0, 252), stand = Vector3.new(-105, 3.5, 237), truck = Vector3.new(-86, 0, 262), truckYaw = 180, truckFrom = Vector3.new(-80, 0, 206) },
	},
	SpotClearSize = Vector3.new(30, 12, 22), -- studs: the house's box (front wall to back, plus the porch)
	-- the cutscene (Controllers/ColdOpenController; shot timings in Lib/Onboarding/ColdOpen)
	ColdOpen = {
		Enabled = true,
		MinSkip = 2, -- s: any tap / key / button skips after this
		MaxWait = 14, -- s: the server hands over the extinguisher at the latest this long after the cutscene starts
		Title = "SAVE THE PANDA!",
		Sub = "A panda is trapped in a burning house!",
		Help = "HELP! HELP!", -- the panda's speech bubble
		SkipTouch = "Tap to skip",
		SkipPad = "Press any button to skip",
		SkipKeys = "Press any key to skip",
		Siren = "rbxassetid://530137633", -- AudioConfig.Sounds.Siren (looped; the cutscene ramps it up)
		Crackle = "rbxassetid://131047015635480", -- AudioConfig.Sounds.Crackle (looped)
		Attr = "ColdOpen", -- Player attr: true = this player gets the cold open (brand-new, first join)
	},
	FirstCallDoneAttr = "FirstCallDone", -- Player attr: true = returning player, or a newbie whose first call ended
	CameraZoom = 12, -- studs: the client pulls the third-person camera back to this once, so you see the fire
	ShoulderOffset = Vector3.new(2, 2.8, 0), -- Humanoid.CameraOffset while the fire burns: over your
	-- right shoulder, so your own body doesn't hide the fire (the spray still goes where the camera looks)
	ClientReadyTimeout = 45, -- s: wait this long for the client's handshake (Onboarding/Ready) before lighting anyway
	StandDelay = 0.6, -- s after CharacterAdded before we move you (after LobbyService's spawn pivot)
	GiveItem = "Extinguisher", -- in your hand as the cutscene ends (InventoryService:Give)
	FireFuel = 100000, -- s: the house fire never burns out on its own
	XpReward = 50, -- profile XP (DataService:AddXp) for saving the panda
	ClearDelay = 8, -- s after the panda is saved before the set vanishes
	-- the first real call, straight after: auto-join a pad with this mission and cut the countdown
	AutoQueue = true,
	AutoQueueDelay = 3.5, -- s after the panda is saved (the celebration owns the screen first)
	FirstCall = "house_fire", -- the plain core loop (spray fires, carry people out): gas_leak's valves + tanker countdown was too much for a first call
	QueueCountdown = 7, -- s on the pad before it rolls (was 12: a dead wait right after the tutorial fire, where 2 players quit); GO NOW still skips it
	QueueRetries = 2, -- the first call's squad dissolved while you were still queued: queue you again this often
	CelebrateSeconds = 3.5, -- the client's "PANDA SAVED!" card
	-- client copy
	FireCard = {
		head = "SPRAY THE FIRE!",
		sub = "Hold {click} to spray your extinguisher at it",
		subTouch = "Hold the SPRAY button to put it out!", -- phones (InputHints; ToolController draws SPRAY)
		subPad = "Hold R2 to spray your extinguisher at it",
	},
	-- fire out: one mechanic at a time, now the panda (FirstFire "panda")
	FireOutPop = "FIRE OUT!", -- small popup over you when the house fire is out
	PandaCard = {
		head = "NOW SAVE THE PANDA!",
		sub = "Walk in the door, press E to pick it up",
		subTouch = "Walk in the door and tap the panda",
		subPad = "Walk in the door, press X to pick it up",
	},
	CarryCard = { head = "CARRY IT OUTSIDE!", sub = "Walk out the door. Outside is safe!" },
	DoneCard = { head = "PANDA SAVED! +{xp} XP", sub = "You're a real firefighter! A call is coming in..." },
	-- on the pad for the auto-queued first call ({title} = the call, {secs} = countdown)
	-- you stay on the pad (no walking off by accident); at 0 you're put straight into your truck
	CallCard = { head = "YOUR FIRST CALL: {title}", sub = "You'll be IN your fire truck in {secs}. Ready?" },
	-- the last LobbyConfig.LockSeconds: no NOT YET any more
	LockedCard = { head = "LOCKED IN! {secs}", sub = "Hold on: you're about to be in your truck!" },
	CallGo = "GO NOW!",
	CallWait = "NOT YET",
	-- after the first call, still out at the scene: what's next (OnboardingController)
	AwayStuds = 220, -- this far from the mission board = "out at the scene"
	AwayCard = { head = "GREAT JOB, ROOKIE!", sub = "Drive back to Station 67 for your next call." },
	AwayButton = "BACK TO STATION",
	SkipLabel = "SKIP TUTORIAL", -- small button under the tutorial card (OnboardingService Onboarding/Skip)
	FirstSprayAttr = "SecondsToFirstSpray", -- Player attr: seconds from joining to your first spray on a fire
	-- Player attr: "burning" (cold open + spray) | "panda" (fire out: carry the panda out) | "done" (panda
	-- saved: the celebration) | "queued" | "open" | "launched" | "skipped" (nil = never had one)
	PhaseAttr = "FirstFire",
	SpotAttr = "FirstFireSpot", -- Player attr: the spot index (client finds workspace.TrainingFires.Spot<n>)
	PandaAttr = "FirstFirePanda", -- Player attr: the panda's RescueId (workspace.Rescuables.<id>)
	DoneAtAttr = "FirstFireDoneAt", -- Player attr: workspace:GetServerTimeNow() when the panda was saved
	ColdOpenAtAttr = "ColdOpenAt", -- Player attr: workspace:GetServerTimeNow() when the set was ready (cutscene start)
})
