--!strict
-- AdminConfig [owner: Admin]. Who is staff, and the admin system's knobs. Data only, no logic.
-- Replicated (the console reads the key and prefix), so nothing secret goes here: UserIds are public.
--
-- Ranks (Lib/Admin/AdminRules.rankOf): Owner 3 > Admin 2 > Mod 1 > Player 0.
--   Owner = the game's creator (game.CreatorType User + CreatorId), anyone in Owners, or (group game)
--   a group rank >= GroupRanks.owner. Admins / Mods = these lists or the group thresholds.
--   Studio only: StudioOwner makes the real Studio account (UserId > 0) Owner, because a local place has
--   CreatorId 0. Test clients (negative UserIds) stay Players.
--   Studio only test override (server side): player:SetAttribute("AdminRankDebug", 0) fakes a Player
--   (0..3); AdminService re-ranks at once.
-- Commands themselves live in ReplicatedStorage/Lib/Admin/AdminCommands (rank per command).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Owners = {} :: { number }, -- extra owners (UserIds) besides the creator
	Admins = {} :: { number },
	Mods = {} :: { number },

	-- Group-owned game: minimum rank in the creator group for each staff rank (0 = off).
	GroupRanks = { owner = 255, admin = 250, mod = 200 },

	StudioOwner = true, -- Studio dev override (see above); never applies in a live server
	DebugAttribute = "AdminRankDebug", -- Studio only; server side

	-- Player attrs AdminService writes (for the client UI only; the server never trusts them)
	Attr = {
		Rank = "AdminRank", -- 0..3
		RankName = "AdminRankName",
		Fly = "AdminFly", -- AdminController flies the local character while true
		Noclip = "AdminNoclip",
		God = "AdminGod",
		Frozen = "AdminFrozen",
		Invisible = "AdminInvisible",
		Muted = "AdminMuted",
	},

	ChatPrefix = ":", -- chat commands (TextChatService, or legacy Player.Chatted)
	ConsoleKey = Enum.KeyCode.Semicolon, -- opens the admin console (staff only)

	-- Rate limit per player, shared by chat and console: `Rate` commands/s sustained, `Burst` in a row.
	Rate = 2,
	Burst = 5,

	BanStore = "Station67AdminBans", -- DataStore (memory only in Studio / when DataService isn't persistent)
	LogSize = 300, -- commands kept in the server log (:logs)
	LogShow = 20, -- :logs default count

	MessageSeconds = 7, -- :m banner
	HintSeconds = 6, -- :h hint
	MaxMessageLength = 200,

	FlySpeed = 60,
	FireRadius = 90, -- :fire lights the nearest flammable part within this many studs of the target
})
