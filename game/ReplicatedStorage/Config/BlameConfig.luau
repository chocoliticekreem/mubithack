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
		Tick = "rbxassetid://134410911353980", -- count-up tick
		CardFlip = "rbxassetid://3456145589",
		Stamp = "rbxassetid://9114026047", -- BLAME! stamp thud (PSE date stamp)
		Star = "rbxassetid://6786936397",
		Fanfare = "", -- mission complete
		Trombone = "", -- time's up
		Click = "rbxassetid://87437544236708",
		Toast = "rbxassetid://140323850218372", -- HUD toast pop
		BlameToast = "", -- HUD blame callout (record scratch)
		TimerTick = "rbxassetid://7743999789", -- HUD under 30 s
		HeatAlarm = "rbxassetid://117751546358455", -- HUD heat >= 85
	},
})
