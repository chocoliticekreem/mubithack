--!strict
-- RetentionConfig [owner: Retention]. Data only. Replicated (the client draws the asks), so NOTHING secret
-- goes here: the Open Cloud API key lives in the experience's Secrets store (docs/game/21-retention.md).
--
--   Notify      the "remind me tomorrow" opt-in (Controllers/RetentionController asks, Roblox's own
--               ExperienceNotificationService:PromptOptIn answers) and the next-day notification
--               (Services/RetentionService sends it through Open Cloud). MessageId "" = never sends.
--   RookiePack  the one-time R$49 starter developer product (Services/RookiePackService, offered by
--               Services/OfferService on the results screen of the player's 2nd call). ProductId 0 = not
--               created yet: never offered, never prompted, nothing errors.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Notify = {
		Ask = true, -- show the in-game "remind me" card (false = never ask)
		AskDelay = 5, -- s back at the station after a call before the card may open (PopupGate decides too)
		MaxAsks = 2, -- ever, per player (NOT NOW once = asked again in a later session, then never)
		-- Creator Dashboard -> your experience -> Engagement -> Notifications -> notification string's
		-- "asset id" (a UUID). "" = never send (the opt-in ask still works and is counted).
		MessageId = "",
		-- Creator Dashboard -> your experience -> Secrets: the secret holding the Open Cloud API key
		-- (scope: user.user-notification:write). Read on the server with HttpService:GetSecret(SecretName).
		SecretName = "OpenCloudNotify",
		LaunchData = "daily_chest", -- Player:GetJoinData().LaunchData when they tap the notification
		Category = "DailyChest", -- analytics_data.category (Creator Dashboard notification analytics)
		MinHoursAfterLeave = 20, -- never sooner than this after they left...
		-- ...and never before the next UTC day (the chest resets at 00:00 UTC, Lib/Retention/DailyChest)
		QueueMap = "RetentionNotify_v1", -- MemoryStore sorted map: userId -> { due, day }, sort key = due
		QueueDays = 3, -- an unsent entry expires after this (MemoryStore max 45)
		SweepSeconds = 300, -- every server checks the queue this often
		SweepBatch = 25, -- entries per sweep
	},

	RookiePack = {
		ProductId = 0, -- Creator Dashboard -> Monetization -> Developer Products -> ROOKIE PACK's ID. 0 = off.
		Price = 49, -- R$ shown until GetProductInfo answers (the prompt always shows Roblox's real price)
		Name = "ROOKIE PACK",
		Headline = "ROOKIE PACK!",
		Short = "2x XP 30 min + helmet + truck paint",
		Icon = "🎒",
		Color = "#FF8A1F",
		AfterCalls = 2, -- offered on the results of the player's Nth finished call ever (profile missionsPlayed)
		MaxShows = 1, -- shown at most this many times ever (it is a starter pack, not a nag)
		BoostMinutes = 30, -- minutes of PLAY time (only counts while in the game)
		XpMultiplier = 2, -- mission XP x this while the boost runs
		Helmet = "helmet_rookie", -- BattlePassConfig.Rewards ids, granted as pass "extra" rewards
		Paint = "paint_rookie",
	},
})
