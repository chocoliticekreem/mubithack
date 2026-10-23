--!strict
-- GameConfig [owner: G3]. Round flow numbers. Other lanes may read these, never redefine them.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	DefaultMission = "Town", -- location Id the v1 auto round uses (StartRound(nil))
	DefaultMissionId = "house_fire", -- MissionCatalog id the v1 auto round plays
	LocationName = "12 Maple St", -- shown on the alarm banner when a mission has no title
	AutoStart = true, -- v1 (LobbyConfig.UseLobby = false): Lobby -> Alarm automatically when >= 1 player is in
	LobbySeconds = 10,
	AlarmSeconds = 6, -- alarm in the station, ending with the IntroSeconds 3-2-1 at the scene
	IntroSeconds = 3, -- teleport to the scene, then "3", "2", "1", "ROLL OUT!" before the timer starts
	RoundSeconds = 180, -- fallback when a mission has no seconds
	ResultsSeconds = 15,
	StartFires = 3, -- fallback when a mission has no fires.count
	MaxPlayers = 4,
	AllOutGraceSeconds = 10, -- "allOut" (no fires, no trapped) can't end a round in its first N s
	TickSeconds = 0.25, -- how often each running mission instance re-checks its objectives
	SpawnSpread = 4, -- studs between squad members at the instance's PlayerSpawn
	FireStartSearch = 24, -- studs: a non-Flammable FireStart marker lights the nearest Flammable part within this
	-- Sound ids are unverified, so they default to "" (silent). Set rbxassetid://... to enable.
	Sounds = {
		Alarm = "",
		Countdown = "",
		RollOut = "",
		Success = "",
		Fail = "",
	},
})
