--!strict
-- FirstFireConfig [owner: Onboarding]. The first 30 seconds of a brand-new player
-- (Services/FirstFireService, Controllers/OnboardingController, pure logic in Lib/Onboarding/FirstFire):
-- spawn at the station's front door with an extinguisher in hand, facing a burning training fire,
-- put it out (reward pop + XP), then get auto-queued onto a pad for a short real call.
-- Session-length counters: Services/SessionService.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	-- Training fire spots on the lawn just west of the front door (the station front faces +Z, the door is
	-- at x -53, the west wall at x -60). Each spot: where the fire burns and where the newbie stands
	-- (facing it, a clear line of sight, open ground behind for the camera). Several newbies at once get the next spot round robin (a spot
	-- that is already burning is shared).
	Spots = {
		{ fire = Vector3.new(-82, 0, 150), stand = Vector3.new(-70, 3.5, 163) },
		{ fire = Vector3.new(-94, 0, 160), stand = Vector3.new(-80, 3.5, 163) },
		{ fire = Vector3.new(-96, 0, 140), stand = Vector3.new(-84, 3.5, 150) },
	},
	CameraZoom = 12, -- studs: the client pulls the third-person camera back to this once, so you see the fire
	StandDelay = 0.6, -- s after CharacterAdded before we move you (after LobbyService's spawn pivot)
	GiveItem = "Extinguisher", -- in your hand from second one (InventoryService:Give)
	FireFuel = 100000, -- s: the training fire never burns out on its own
	XpReward = 50, -- profile XP (DataService:AddXp) for putting it out
	ClearDelay = 6, -- s after it's out before the burnt props vanish
	-- the first real call, straight after: auto-join a pad with this mission and cut the countdown
	AutoQueue = true,
	AutoQueueDelay = 3, -- s after the fire is out (the reward pop owns the screen first)
	FirstCall = "gas_leak", -- GameConfig.NearDispatch: the QUICK STOP a short drive from the station
	QueueCountdown = 8, -- s on the pad before it rolls (friends can still hop on)
	CelebrateSeconds = 3, -- the client's "FIRE OUT!" card
	-- client copy
	FireCard = { head = "PUT OUT THE FIRE!", sub = "Hold {click} to spray your extinguisher at it" },
	DoneCard = { head = "FIRE OUT! +{xp} XP", sub = "You're a natural. A real call is coming in..." },
	FirstSprayAttr = "SecondsToFirstSpray", -- Player attr: seconds from joining to your first spray on a fire
	PhaseAttr = "FirstFire", -- Player attr: "burning" | "done" | "queued" | "open" | "launched" | "skipped" (nil = never had one)
	SpotAttr = "FirstFireSpot", -- Player attr: the spot index (client finds workspace.TrainingFires.Spot<n>)
	DoneAtAttr = "FirstFireDoneAt", -- Player attr: workspace:GetServerTimeNow() when it went out
})
