--!strict
-- BlameConfig [owner: G3]. Award thresholds, blame attribution, kill-feed callouts and the Blame/HUD UI sounds.
-- Sound ids default to "" (silent): set a verified rbxassetid:// here, never a guessed one.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	MaxAwardsPerPlayer = 2,
	ArsonRadius = 30, -- studs: a fire that spreads within this distance of a player is "their" fire (Arsonist (Probably))
	BoomRadius = 30, -- studs: nearest player to an explosion gets the blame (Kaboom Club)
	KillFeed = true, -- BlameService announces blame events as Shared/Notify "blame" toasts
	KillFeedRepeatSeconds = 4, -- the same (event, actor, victim) line is not repeated within this many seconds
	CarryTickSeconds = 1, -- how often carry time is sampled for "Lift With Your Legs"
	Sounds = {
		Tick = "", -- count-up tick
		CardFlip = "",
		Stamp = "", -- BLAME! stamp thud
		Star = "",
		Fanfare = "", -- mission complete
		Trombone = "", -- time's up
		Click = "",
		Toast = "", -- HUD toast pop
		BlameToast = "", -- HUD blame callout (record scratch)
		TimerTick = "", -- HUD under 30 s
		HeatAlarm = "", -- HUD heat >= 85
	},
})
