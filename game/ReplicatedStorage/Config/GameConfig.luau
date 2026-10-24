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
	-- v2 dispatch (docs/game/08): squads drive their trucks to an IncidentSite in the shared city.
	UseInstances = false, -- true = v1.5 path (build a copy of the location and teleport the squad)
	InstanceFallback = true, -- dispatch found no free IncidentSite for the mission: use the v1.5 instance path
	DispatchFires = 1, -- fires lit at dispatch (smouldering while you drive); the rest flare up on arrival
	-- squad scaling: fires on scene = max(fires.count, MinArrivalFires) * (1 + FireScalePerPlayer * (players - 1)),
	-- rounded (solo = the catalog count; 4 players ~x2). Fires beyond the site's FireStart markers go on
	-- Flammable parts spread round the site, never within FireAvoidRescueStuds of a RescueSpawn.
	FireScalePerPlayer = 0.35,
	MinArrivalFires = 3,
	FireAvoidRescueStuds = 8,
	RescuesPerExtraPlayers = 2, -- +1 rescuable per 2 extra players (where the site has spawn markers)
	RekindleSeconds = 4, -- nothing has burned at the site this long after arrival: light the site's FireStart markers
	MinDispatchStuds = 700, -- dispatch prefers sites at least this far from the station (a real drive)
	SiteTieStuds = 60, -- free sites within this of the nearest one are a tie, picked at random
	TravelSpeed = 45, -- studs/s used to size the driving allowance added to the timer
	TravelMinSeconds = 20,
	TravelMaxSeconds = 90,
	FastArrivalSeconds = 0, -- arrive within this long of dispatch (0 = travel allowance * 0.75) for the bonus
	ArrivalBonusSeconds = 20, -- timer seconds added on a fast arrival
	ArrivalRadius = 40, -- studs from TruckSpot/site centre when a site has no ArrivalZone part
	ArrivalMargin = 4, -- studs of slack around the ArrivalZone box
	DispatchResultsSeconds = 15, -- results screen; keep below LobbyConfig.ReturnSeconds (its safety net teleports)
	-- Sound ids are unverified, so they default to "" (silent). Set rbxassetid://... to enable.
	Sounds = {
		Alarm = "",
		Countdown = "",
		RollOut = "",
		Success = "",
		Fail = "",
	},
})
