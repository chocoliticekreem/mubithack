--!strict
-- GameConfig [owner: G3]. Round flow numbers. Other lanes may read these, never redefine them.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	DefaultMission = "Town", -- location Id the auto round uses
	LocationName = "12 Maple St", -- shown on the alarm banner
	AutoStart = true, -- Lobby -> Alarm automatically when >= 1 player is in
	LobbySeconds = 10,
	AlarmSeconds = 6,
	RoundSeconds = 180,
	ResultsSeconds = 15,
	StartFires = 3, -- FireStart parts first, then random Flammable parts up to this many
	MaxPlayers = 4,
	AllOutGraceSeconds = 10, -- "allOut" (no fires, no trapped) can't end a round in its first N s
})
