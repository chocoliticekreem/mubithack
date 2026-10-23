--!strict
-- DataConfig [owner: Data]. Player profiles (DataService), leaderboards (LeaderboardService) and the
-- lobby XP bar (ProfileController). Replicated, so nothing secret goes here. docs/game/06-data.md.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- Storage
	StoreName = "FlameAndBlameProfiles", -- bump the suffix to wipe everyone (never in prod)
	KeyPrefix = "u_", -- key = KeyPrefix .. UserId
	-- Studio: true = always use the in-memory store (nothing persists between playtests). false = try
	-- the real DataStore; needs Game Settings -> Security -> "Enable Studio Access to API Services",
	-- and falls back to memory (with a warning) if that's off.
	UseMemoryInStudio = true,

	-- Session lock + saving
	AutosaveSeconds = 60,
	LockTtlSeconds = 300, -- a crashed server's lock expires after this; autosave refreshes ours
	LoadAttempts = 6, -- UpdateAsync tries while another server holds the lock / requests fail
	RetryBaseSeconds = 1, -- backoff: base * 2^(attempt-1), capped
	RetryMaxSeconds = 16,
	SaveAttempts = 4,
	BudgetWaitSeconds = 10, -- max wait for request budget before trying anyway
	BindToCloseSeconds = 25, -- Roblox gives 30 s; stop waiting a bit before that
	KickOnLoadFail = false, -- true: kick if the profile can't be locked; false: play unsaved

	-- XP (ProfileSchema.xpForMission)
	Xp = {
		Played = 25,
		Won = 50,
		PerStar = 20,
		PerRescue = 15,
		PerPanda = 40,
		PerFireOut = 2,
		PerAward = 10,
		MaxPerMission = 400,
	},
	WinStars = 2, -- stars >= this (and not a forced end) = mission won
	-- Blame points (funny leaderboard): per stat unit, plus per blame award received
	BlamePoints = { firesStarted = 3, downedOthers = 5, teammateSprayed = 1, blameAward = 10 },

	-- Cosmetics: slot "helmet" | "hose"; unlocked automatically at `level`. Robux/game passes are v2.
	Cosmetics = {
		{ id = "helmet_red", slot = "helmet", level = 1, name = "Classic Red", color = Color3.fromHex("#C0301E") },
		{ id = "helmet_yellow", slot = "helmet", level = 3, name = "Rookie Yellow", color = Color3.fromHex("#E8B83A") },
		{ id = "helmet_black", slot = "helmet", level = 6, name = "Chief Black", color = Color3.fromHex("#1E1A22") },
		{ id = "helmet_pink", slot = "helmet", level = 10, name = "Flamingo", color = Color3.fromHex("#FF7AB6") },
		{ id = "helmet_gold", slot = "helmet", level = 20, name = "Gold", color = Color3.fromHex("#FFC531") },
		{ id = "hose_blue", slot = "hose", level = 1, name = "Water", color = Color3.fromHex("#A9E3F0") },
		{ id = "hose_green", slot = "hose", level = 4, name = "Slime", color = Color3.fromHex("#7FE05A") },
		{ id = "hose_orange", slot = "hose", level = 8, name = "Orange Soda", color = Color3.fromHex("#FF9A2E") },
		{ id = "hose_purple", slot = "hose", level = 12, name = "Grape", color = Color3.fromHex("#A06BFF") },
		{ id = "hose_rainbow", slot = "hose", level = 15, name = "Rainbow", color = Color3.fromHex("#FFFFFF") },
	},

	-- Player attributes DataService writes (read by ProfileController and anyone who wants them).
	-- Not in Shared/Names yet (frozen); proposed there in the data PR.
	Attr = {
		Level = "Level",
		Xp = "XpIntoLevel", -- XP inside the current level
		XpNext = "XpForNext", -- XP the current level needs (0 at max level)
		XpTotal = "XpTotal",
		HelmetCosmetic = "HelmetCosmetic", -- equipped cosmetic id (DataConfig.Cosmetics)
		HoseCosmetic = "HoseCosmetic",
		ProfileReady = "ProfileReady", -- boolean
	},

	-- Leaderboards (LeaderboardService)
	Leaderboard = {
		StorePrefix = "FlameAndBlameLB_", -- OrderedDataStore names: <prefix><stat>_all, <prefix><stat>_w<week>
		Stats = { "rescues", "blamePoints", "missions" }, -- order = board columns
		Titles = { rescues = "RESCUES", blamePoints = "BLAME POINTS", missions = "MISSIONS" },
		RefreshSeconds = 120,
		TopN = 8,
		CycleSeconds = 12, -- the board alternates THIS WEEK / ALL TIME
		LocationId = "Station", -- the board is parented into this location (rebuilt with it)
		Slot = 0, -- that location's MapConfig slot (Station = 0); origin = MapConfig.SlotOrigin(Slot)
		-- Board centre in the location's local space (Station: locker room, facing the spawn pads).
		Offset = CFrame.new(-20, 7.4, 17), -- identity rotation: the Front face looks -Z, at the pads
		Size = Vector3.new(15, 8, 0.6),
	},

	-- Lobby XP bar + popups (ProfileController)
	Ui = {
		PopupSeconds = 1.6,
		LevelUpSeconds = 2.5,
	},
})
