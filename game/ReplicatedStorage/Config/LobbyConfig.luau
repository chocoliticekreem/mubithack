--!strict
-- LobbyConfig [owner: G3]. Station lobby, squads and parallel mission instances (v1.5).
-- Sound ids are unverified on purpose: leave "" (silent) until someone pastes a vetted
-- rbxassetid://..., then tune live: DevHook:Invoke("LobbyConfig", ".Set", "BellSoundId", "rbxassetid://...").
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	UseLobby = true, -- true = board + queue pads + instances (the product's entry point); false = v1 auto-round
	LobbyLocation = "Station", -- players spawn and return here
	MaxSquadSize = 8, -- 4 trucks; crew 5..8 ride along
	SquadPads = 3, -- queue pads LobbyService builds on the apron (attr PadId 1..N) when StationBuilder has none
	CountdownSeconds = 15, -- starts when the first player steps on a pad
	FullCountdownSeconds = 5, -- when the squad is full
	LaunchCountdown = 5, -- leader's "GO NOW" (Lobby/Launch) cuts the countdown to this
	AlarmFromSeconds = 3, -- station alarm lamps flash + siren at 3..2..1
	BigCountdownFrom = 5, -- the client shows the big centre number from here down
	ReturnSeconds = 20, -- safety net: after MissionEnded, bring home anyone MissionService didn't (its results take 15 s)
	PadRadius = 7.5, -- studs (horizontal) from the pad centre that count as "on the pad" (14-stud pads)
	PadHeight = 40, -- studs above the pad that still count: membership is really horizontal-only (kids jump
	--                 constantly; the old 7 dropped anyone at the top of a jump off their squad)
	PadGraceSeconds = 1.5, -- off the pad this briefly (a stumble, a knockback, a ragdoll) doesn't leave the squad
	-- LOCK IN + BOARD (LobbyService): at LockSeconds left the squad can't walk off its pad any more (an
	-- invisible fence goes up and anyone outside LockRadius is pulled back in); at 0 everyone is put
	-- straight into a seat of the squad's truck (leader drives) behind a quick fade, no running to a bay.
	LockSeconds = 5,
	LockRadius = 7, -- studs: a locked member's root further than this from the pad centre is pulled back (the fence stops walkers at ~6.3)
	LockText = "LOCKED IN!",
	BoardIntoTruck = true, -- false = the old "run to your bay and get in" launch
	BoardFadeSeconds = 0.25, -- client fade to black before the seat teleport (then it fades back in)
	TruckWaitSeconds = 8, -- wait this long for a squad truck to exist before giving up (old run-to-bay)
	PollHz = 10,
	AfkSeconds = 45, -- standing still this long in the lobby -> "on coffee break"
	AliveEvery = 5, -- s: the client's Lobby/Alive input ping (any key, tap, camera drag) at most this often
	BellCooldown = 1.5,
	HonkCooldown = 1.2,
	PoleSlideSeconds = 1.3,
	BoardPixelsPerStud = 50,
	-- sounds (SoundService-style ids; "" = silent)
	TickSoundId = "rbxassetid://134410911353980",
	GoSoundId = "rbxassetid://9117265660", -- (PSE) referee whistle
	SirenSoundId = "rbxassetid://530137633",
	AlarmSoundId = "",
	BellSoundId = "rbxassetid://6786936397",
	HonkSoundId = "rbxassetid://107056835646946",
	WhooshSoundId = "rbxassetid://9120972321", -- (PSE) wood whoosh
	WelcomeText = "Welcome back, heroes (mostly)",
})
