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
	MinArrivalFires = 5,
	-- escalation (MissionService): every call grows while the squad works it. Phases come from the
	-- catalog's `escalation`, else Default; each fires `at` s after arrival, or early once nothing has
	-- burned for LullSeconds (but at least MinGapSeconds after the previous phase). "All clear" can't end
	-- a call while a phase is still to come. Phase fires scale with the squad like the arrival fires.
	-- 2026-10-26 "fires out, then nothing happens, wait, it comes back is boring": the lull was 8 s with a
	-- 30 s minimum gap, so a fast squad stood around for up to ~30 s. Now the next wave lands 3 s after
	-- the last fire goes out (with a "More fire is coming" heads-up), at least 10 s after the previous one.
	Escalation = {
		LullSeconds = 3,
		MinGapSeconds = 10,
		Default = {
			{ at = 90, fires = 4, up = true, text = "The fire's spreading to the upper floor!" },
			{ at = 180, fires = 4, setPiece = "flashover", text = "FLASHOVER! A whole room just went up!" },
		},
	},
	-- ROOKIE CALLS (MissionService): while anyone in the squad has played fewer than `Calls` calls, the call is
	-- short and kind. Live funnel: a far first call (40-65 s drive), 120 burning parts and 5 rescues lost
	-- 29% on the drive, 42% before the first fire out, and most of the rest before "complete".
	Rookie = {
		Calls = 2, -- profile missionsPlayed below this = rookie
		NearestSite = true, -- the nearest free site (no MinDispatchStuds): a short drive
		ArrivalFires = 3, -- fires lit on arrival (instead of the catalog/scaled count)
		FireCap = 10, -- burning parts the site may hold (FireService:SetLocationCap): spread can't snowball
		MaxRescues = 2, -- people/pets to carry out (round robin over the catalog's kinds)
		NoEscalation = true, -- no "spreading upstairs" / flashover phases
		TimeoutIsWin = true, -- time runs out: "CALL COMPLETE!" with at least 1 star, never TIME'S UP
	},
	-- a squad of one is never "wiped": a downed solo player respawns at the truck (SquadConfig.SoloBleedOutSeconds)
	SoloNeverWipes = true,
	FireAvoidRescueStuds = 8,
	RescuesPerExtraPlayers = 2, -- +1 rescuable per 2 extra players (where the site has spawn markers)
	RekindleSeconds = 4, -- nothing has burned at the site this long after arrival: light the site's FireStart markers
	MinDispatchStuds = 700, -- dispatch prefers sites at least this far from the station (a real drive)
	-- ...except these calls, which go to the nearest free site: the gas_leak call is the QUICK STOP on the
	-- hub's own avenue frontage (Districts.CorridorSpecial.Station), a short siren run from the station
	NearDispatch = { gas_leak = true },
	SiteTieStuds = 60, -- free sites within this of the nearest one are a tie, picked at random
	TravelSpeed = 45, -- studs/s used to size the driving allowance added to the timer
	TravelMinSeconds = 20,
	TravelMaxSeconds = 90,
	FastArrivalSeconds = 0, -- arrive within this long of dispatch (0 = travel allowance * 0.75) for the bonus
	ArrivalBonusSeconds = 20, -- timer seconds added on a fast arrival
	ArrivalRadius = 40, -- studs from TruckSpot/site centre when a site has no ArrivalZone part
	ArrivalMargin = 4, -- studs of slack around the ArrivalZone box
	-- ...and arrived anyway within this flat distance of the zone's centre: the GPS says "YOU'RE HERE!" at
	-- NavigationConfig.ArriveRadius (45) and its road route ends on the road, which for some sites is 30+
	-- studs from the zone (playtest: a truck parked where the GPS said YOU'RE HERE never started the call)
	ArrivalGpsRadius = 50,
	DispatchResultsSeconds = 15, -- results screen; keep below LobbyConfig.ReturnSeconds (its safety net teleports)
	-- Sound ids are unverified, so they default to "" (silent). Set rbxassetid://... to enable.
	Sounds = {
		Alarm = "",
		Countdown = "rbxassetid://7743999789",
		RollOut = "",
		Success = "",
		Fail = "",
	},
})
