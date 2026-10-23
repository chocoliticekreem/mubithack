--!strict
-- LobbyConfig [owner: G3]. Station lobby, squads and parallel mission instances (v1.5).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	UseLobby = false, -- false = v1 single auto-round (GameConfig.AutoStart); true = board + squads + instances
	LobbyLocation = "Station", -- players spawn and return here
	MaxSquadSize = 4,
	SquadPads = 4, -- SquadPad parts StationBuilder makes (attr PadId 1..N)
	LaunchCountdown = 5, -- seconds from Launch to teleport, so late joiners can hop on the pad
	ReturnSeconds = 10, -- after MissionEnded (results shown), teleport the squad back to the station
})
