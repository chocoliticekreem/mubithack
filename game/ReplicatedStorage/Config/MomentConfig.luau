--!strict
-- MomentConfig [owner: Clippable]. Big moments (Tizyz rule #5, docs/research/marketing/tizyz-5-viral-applied.md):
-- the funny / dramatic beats a YouTuber clips get a short client-only cinematic (Controllers/MomentController):
-- FOV punch + camera shake + slowed nearby particles / sounds + one big caption + a crowd "OOOH".
-- The server sim never slows. Rules (who sees what, cooldown, driving, popups / calm): Lib/MomentRules.
-- Read at use time so ".Set" live-tunes it.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	CooldownSeconds = 20, -- at most one moment per player per this many seconds
	DriveSpeed = 22, -- studs/s: seated in a vehicle faster than this = no moment (never block the road)
	BeatSeconds = 1.0, -- the slow-mo beat (calm: CalmBeatSeconds)
	CalmBeatSeconds = 0.6,
	FovPunch = -12, -- degrees added at the start of the beat (negative = zoom in), eased back to 0
	Shake = 0.45, -- FirstPersonController:Shake trauma (Calm.fx scales it)
	SlowTimeScale = 0.3, -- ParticleEmitter.TimeScale near the moment during the beat (Full effects only)
	SlowPitch = 0.75, -- PlaybackSpeed multiplier for sounds near the moment during the beat (Full only)
	SlowRadius = 40, -- studs around the moment whose particles / sounds get stretched
	CaptionTextSize = 96, -- px at 1280x720 (calm: CalmCaptionTextSize)
	CalmCaptionTextSize = 60,
	OoohSoundId = "rbxassetid://129780458701452", -- sitcom crowd "ooooh", 2 s, Creator Store (loads in Studio)
	OoohVolume = 0.7,
	CalmOoohVolume = 0.35,

	-- kind -> caption, range (studs from you; involved players always see it), whether "involved"
	-- matters. Order is just for docs. Captions are one style (MomentController.caption).
	Kinds = {
		backdraft = { caption = "BACKDRAFT!!", range = 50 },
		flashover = { caption = "FLASHOVER!", range = 45 },
		kaboom = { caption = "KABOOM!", range = 70 },
		collapse = { caption = "CEILING CAVE-IN!", range = 45 },
		yeet = { caption = "YEET!", range = 40 },
		slap = { caption = "SLAPPED!", range = 30 },
		blamed = { caption = "BLAMED!", range = 40 },
	},
})
