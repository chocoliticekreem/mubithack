--!strict
-- AudioConfig [owner: AV lane]. Every sound the game plays, by name (docs/game/02-art-feel-ui.md §11).
-- AudioController (client) plays them; AudioService (server) only says *which* name to play, where.
--
-- Ids: found with the Studio MCP `search_asset` (Audio, Creator Store, free) and preloaded OK in
-- Studio Edit (ContentProvider:PreloadAsync -> Success) on 23 Oct 2026. Ones marked (PSE) are
-- "Courtesy of Pro Sound Effects", (APM) are APM Music, (DK) are DistrokidOfficial: Roblox-licensed,
-- public, safe in any experience. Ones marked (3p) are third-party uploads: they loaded for the
-- place owner, but audio privacy can block them for other players -> swap if the ForgeProbe report
-- shows "failed to load" for them. An empty id ("") is skipped silently, so a bad id can be blanked
-- live: ServerStorage.DevHook is server-only, so on the client run
--   require(game.ReplicatedStorage.Config.AudioConfig).Sounds.Siren.id = ""
--
-- Tune live (server copy only matters for AudioService, client copy for everything audible):
--   require(game.ReplicatedStorage.Config.AudioConfig).Set("CrackleMax", 4)
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

export type Group = "Music" | "SFX" | "Ambience" | "UI" | "Voice"

export type SoundDef = {
	id: string, -- "rbxassetid://..." or "" (skip)
	group: Group,
	volume: number,
	pitchVar: number?, -- one-shots: PlaybackSpeed 1 +/- pitchVar (default PitchVar)
	looped: boolean?,
	minDist: number?, -- 3D RollOffMinDistance (default RollOffMin)
	maxDist: number?, -- 3D RollOffMaxDistance (default RollOffMax)
	startAt: number?, -- TimePosition to start from (skip a silent intro)
}

local function id(n: number): string
	return "rbxassetid://" .. tostring(n)
end

local Sounds: { [string]: SoundDef } = {
	-- Fire -------------------------------------------------------------------------------------
	Crackle = { id = id(131047015635480), group = "Ambience", volume = 0.7, looped = true, minDist = 6, maxDist = 70 }, -- (DK) Fire Crackle Ambient
	FireRoar = { id = id(2787093357), group = "Ambience", volume = 0.0, looped = true }, -- (3p) "forest fire"; 2D bed, volume driven by burning count
	Ignite = { id = id(135097195613949), group = "SFX", volume = 0.6, pitchVar = 0.12, maxDist = 90 }, -- (3p) Fire_ignition
	Steam = { id = id(4772620521), group = "SFX", volume = 0.55, pitchVar = 0.15, maxDist = 80 }, -- (3p) Steam Hiss (extinguish)

	-- Water ------------------------------------------------------------------------------------
	HoseLoop = { id = id(9126200774), group = "SFX", volume = 0.55, looped = true, minDist = 4, maxDist = 60 }, -- (PSE) spluttery hose spray 8.1 s
	Splash = { id = id(9125703162), group = "SFX", volume = 0.6, pitchVar = 0.15, maxDist = 70 }, -- (PSE) puddle splash
	CartoonSplash = { id = id(140727221118804), group = "SFX", volume = 0.7, pitchVar = 0.1 }, -- (3p) teammate soaked

	-- Station / truck --------------------------------------------------------------------------
	Alarm = { id = id(9113084849), group = "SFX", volume = 0.6, looped = true, minDist = 12, maxDist = 160 }, -- (PSE) alarm bell, constant ring
	Siren = { id = id(530137633), group = "SFX", volume = 0.65, looped = true, minDist = 15, maxDist = 260 }, -- (3p) fire truck siren LOOP
	Horn = { id = id(107056835646946), group = "SFX", volume = 0.8, pitchVar = 0.05, maxDist = 140 }, -- (3p) party horn (comedic honk)

	-- Breaking things ----------------------------------------------------------------------------
	DoorBreak = { id = id(9120957636), group = "SFX", volume = 0.8, pitchVar = 0.1, maxDist = 110 }, -- (PSE) wood roof crash
	GlassShatter = { id = id(9118763343), group = "SFX", volume = 0.7, pitchVar = 0.1, maxDist = 110 }, -- (PSE) safety glass

	-- Comedic stingers (2D, UI group) -----------------------------------------------------------
	SadTrombone = { id = id(840996075), group = "UI", volume = 0.8 }, -- (3p) fail trombone: time's up / mission failed
	Fanfare = { id = id(1836473422), group = "UI", volume = 0.7 }, -- (APM) Victory Fanfare Sting: mission complete
	RecordScratch = { id = id(112792997660073), group = "UI", volume = 0.8 }, -- (3p) blame card / friendly fire
	SlideWhistle = { id = id(9119198140), group = "UI", volume = 0.7, pitchVar = 0.08 }, -- (PSE) fall / ragdoll
	Ding = { id = id(79138466370636), group = "UI", volume = 0.6 }, -- (3p) rescue / room cleared, pitch rises per streak
	Sting = { id = id(1841391669), group = "UI", volume = 0.6 }, -- (APM) Wipsy La La Sting: blame award reveal
	Click = { id = id(88442833509532), group = "UI", volume = 0.5, pitchVar = 0.05 }, -- (3p) UI click
	LevelUp = { id = id(112485797063762), group = "UI", volume = 0.7 }, -- (3p) "UI - Level Up" jingle, 1.5 s

	-- Music (2D) ---------------------------------------------------------------------------------
	LobbyMusic = { id = id(1839296911), group = "Music", volume = 0.5, looped = true }, -- (APM) Funk Master
	MissionMusic = { id = id(1836080007), group = "Music", volume = 0.45, looped = true }, -- (APM) Martial Brass And Beats (Alt 2)
	ResultsMusic = { id = id(1842224477), group = "Music", volume = 0.5, looped = true }, -- (APM) Shaft (retro funk brass)

	-- Location ambience beds (2D) -------------------------------------------------------------------
	NightCrickets = { id = id(9112764573), group = "Ambience", volume = 0.35, looped = true }, -- (PSE) crickets, suburban night
	FarmEvening = { id = id(9112777821), group = "Ambience", volume = 0.35, looped = true }, -- (PSE) farmland presence
}

return Config.define({
	Sounds = Sounds,

	-- SoundGroup volumes under SoundService.Master (doc §11 mixing).
	GroupVolume = { Master = 1, Music = 0.35, SFX = 0.8, Ambience = 0.5, UI = 0.7, Voice = 0.9 } :: { [string]: number },

	PitchVar = 0.08, -- default +/- PlaybackSpeed jitter for one-shots
	RollOffMin = 8,
	RollOffMax = 120,

	-- Budgets (docs/game/02 §12: <= 24 sounds playing, crackles capped at 6 nearest).
	MaxPlaying = 24, -- one-shots beyond this are dropped (loops are budgeted separately)
	CrackleMax = 6, -- nearest Burning parts that get a crackle loop
	CrackleRadius = 110, -- studs from the camera; farther fires are silent
	CrackleClusterRadius = 10, -- one crackle per cluster: skip a fire within this of an already-picked one
	CrackleHz = 3, -- how often the nearest set is re-picked
	SteamPerSecond = 4, -- extinguish hiss rate limit
	RoarFullAt = 30, -- burning parts in my instance for the 2D roar bed to hit RoarMaxVolume
	RoarMaxVolume = 0.6,

	-- Music ducking for stingers (v1: tween Music group down, then back).
	DuckVolume = 0.12,
	DuckSeconds = 1.6,
	MusicFade = 1.2, -- crossfade between music tracks
	TensionSeconds = 30, -- last N seconds of a round: mission music PlaybackSpeed -> TensionSpeed
	TensionSpeed = 1.06,

	AlarmSeconds = 4, -- Mission/Alarm: bell at the nearest AlarmLamps (+ quiet 2D copy)
	SirenSeconds = 8, -- Mission/Alarm: truck siren while the crew gears up
	ArriveSirenSeconds = 5, -- siren burst when my instance goes Active (truck arrives on scene)

	RescueDingStep = 0.05, -- +5% pitch per consecutive rescue
	RescueStreakReset = 12, -- seconds without a rescue before the streak resets

	-- Location -> ambience bed name (nil = none). Keys are the instance Model's LocationId.
	LocationAmbience = {
		Town = "NightCrickets",
		Apartment = "NightCrickets",
		Farm = "FarmEvening",
		Forest = "FarmEvening",
		Dam = "NightCrickets",
	} :: { [string]: string },

	-- Blame / feel event kind -> stinger name (AudioService maps server events onto these).
	Stingers = {
		RoundFailed = "SadTrombone",
		RoundComplete = "Fanfare",
		Blame = "RecordScratch",
		FriendlyFire = "RecordScratch",
		Ragdoll = "SlideWhistle",
		Rescue = "Ding",
		Award = "Sting",
		Honk = "Horn",
		LevelUp = "LevelUp",
	} :: { [string]: string },
})
