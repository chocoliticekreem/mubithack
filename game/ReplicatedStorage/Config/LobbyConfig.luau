--!strict
-- LobbyConfig [owner: G3]. Station lobby, squads and parallel mission instances (v1.5).
-- Sound ids are unverified on purpose: leave "" (silent) until someone pastes a vetted
-- rbxassetid://..., then tune live: DevHook:Invoke("LobbyConfig", ".Set", "BellSoundId", "rbxassetid://...").
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	UseLobby = true, -- true = board + queue pads + instances (the product's entry point); false = v1 auto-round
	LobbyLocation = "Station", -- players spawn and return here
	MaxSquadSize = 4,
	SquadPads = 3, -- queue pads LobbyService builds on the apron (attr PadId 1..N) when StationBuilder has none
	CountdownSeconds = 15, -- starts when the first player steps on a pad
	FullCountdownSeconds = 5, -- when the squad is full
	LaunchCountdown = 5, -- leader's "GO NOW" (Lobby/Launch) cuts the countdown to this
	AlarmFromSeconds = 3, -- station alarm lamps flash + siren at 3..2..1
	BigCountdownFrom = 5, -- the client shows the big centre number from here down
	ReturnSeconds = 10, -- after MissionEnded (results shown), teleport the squad back to the station
	PadRadius = 4, -- studs (horizontal) from the pad centre that count as "on the pad"
	PadHeight = 7, -- studs above the pad top that still count (jumping)
	PollHz = 10,
	AfkSeconds = 45, -- standing still this long in the lobby -> "on coffee break"
	BellCooldown = 1.5,
	HonkCooldown = 1.2,
	PoleSlideSeconds = 1.3,
	BoardPixelsPerStud = 50,
	-- sounds (SoundService-style ids; "" = silent)
	TickSoundId = "",
	GoSoundId = "",
	SirenSoundId = "",
	AlarmSoundId = "",
	BellSoundId = "",
	HonkSoundId = "",
	WhooshSoundId = "",
	WelcomeText = "Welcome back, heroes (mostly)",
})
