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
--   Granted ranks (:admin / :mod / :unadmin / :setrank / the console's PLAYERS list) are saved in the
--   DataStore RankStore keyed by UserId and override these lists (an :unadmin'd config Admin stays a
--   Player). In Studio (DataService not persistent) the store lives in memory for the session.
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
		Inverted = "TrollInverted", -- :invert: TrollController flips the local controls while true
		Jailed = "TrollJailed",
	},

	ChatPrefix = ":", -- chat commands (TextChatService, or legacy Player.Chatted)
	ConsoleKey = Enum.KeyCode.Semicolon, -- opens the admin console (staff only)

	-- Rate limit per player, shared by chat and console: `Rate` commands/s sustained, `Burst` in a row.
	Rate = 2,
	Burst = 5,

	BanStore = "Station67AdminBans",
	RankStore = "Station67AdminRanks", -- granted ranks: one key "staff" = { [UserId] = { rank, name, by, at } }
	RankRefreshSeconds = 60, -- re-read the rank store (other servers' grants) this often
	RankTopic = "Station67AdminRanks", -- MessagingService: a grant tells the other servers to re-read at once -- DataStore (memory only in Studio / when DataService isn't persistent)
	LogSize = 300, -- commands kept in the server log (:logs)
	LogShow = 20, -- :logs default count

	MessageSeconds = 7, -- :m banner
	HintSeconds = 6, -- :h hint
	MaxMessageLength = 200,

	FlySpeed = 60,
	FireRadius = 90, -- :fire lights the nearest flammable part within this many studs of the target

	-- Troll commands (TrollService). Rank rules: Lib/Admin/AdminRules.canTroll / massTarget.
	-- Everything here reverts on its own; :normal reverts every troll on a player at once.
	Troll = {
		Rate = 1, -- troll commands per second per caller (on top of Rate / Burst above)
		Burst = 4,
		FlingSpeed = 110, -- studs/s (Ragdoll clamps to PhysicsConfig.MaxImpulse)
		FlingLift = 60,
		RocketSpeed = 85, -- studs/s straight up
		RocketSeconds = 2,
		RocketFallSpeed = 18, -- parachute: studs/s down (under PhysicsConfig.HardLandingSpeed)
		RocketMaxSeconds = 12, -- the parachute lets go after this no matter what
		SpinSeconds = 5,
		SpinSpeed = 18, -- rad/s
		ScaleSeconds = 30, -- :tiny / :giant revert after this
		TinyScale = 0.5,
		GiantScale = 2,
		BigHeadScale = 2.4,
		BigHeadSeconds = 20,
		RagdollSeconds = 4,
		ExplodeSpeed = 120,
		JailSeconds = 60,
		InvertSeconds = 10,
		FakeBanSeconds = 3,
		DanceSeconds = 8,
		DanceAnim = "rbxassetid://507771019", -- Roblox's own R15 dance
		WalkAnim = "rbxassetid://913402848", -- Roblox's own R15 walk (the clone waddles)
		NoodleSeconds = 10,
		CloneSeconds = 20,
		MaxClones = 6, -- whole server
		PenguinCount = 12,
		PenguinSeconds = 12,
		MaxPenguins = 60, -- whole server
		ConfettiSeconds = 4,
		SparkleSeconds = 15,
	},
})
