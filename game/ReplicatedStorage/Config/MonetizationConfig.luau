--!strict
-- MonetizationConfig [owner: Monetization]. THE one place Robux ids live. Data only, no logic.
-- Replicated (the store UI reads it), so nothing secret goes here.
--
-- Live ids: universe 10772606251 ("Station 67"). Plugging in / changing ids (Creator Dashboard ->
-- your experience -> Monetization):
--   * Passes:   GamePasses.UnlimitedFoam = 123456789        (Passes tab, the pass's "ID")
--   * Donations: DonationProducts[1].id = 987654321          (Developer Products tab)
-- 0 = not configured: the store shows "COMING SOON", the server never prompts, nothing errors.
-- BattlePassService unlocks the premium track from Player attr Pass_PremiumPass (GamePasses.PremiumPass).
--
-- Studio testing without real ids (server side, e.g. execute_luau on the Server datamodel):
--   player:SetAttribute("PassDebug_UnlimitedFoam", true)   -- Studio only; MonetizationService mirrors
--                                                           -- it into Pass_UnlimitedFoam
--   ServerStorage.DevHook:Invoke("MonetizationService", "_fakeReceipt", player, 100, "test-1")
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	-- Game pass ids by key. Keys are the attribute suffix: owning a pass sets Player attr Pass_<Key> = true.
	GamePasses = {
		UnlimitedFoam = 2053193383, -- 149 R$
		PremiumPass = 2053853337, -- 299 R$; the battle pass premium track (BattlePassService)
		-- FIRE HELICOPTER (HeliService / HeliController, Config/HeliConfig). 0 = not created yet: the store
		-- card says COMING SOON, it is never offered or prompted, nobody owns it (Studio: PassDebug_Helicopter).
		Helicopter = 0, -- TODO: the real pass id (suggested 399 R$; art: marketing/passes/helicopter.json)
	},

	-- How each pass shows in the store (order = card order). price = the R$ shown until
	-- MarketplaceService:GetProductInfo answers (and always while the id is 0). icon = a glyph used
	-- when the pass has no icon image yet.
	Passes = {
		{
			key = "UnlimitedFoam",
			name = "UNLIMITED FOAM",
			blurb = "Your extinguishers never run dry. Foam forever!",
			perk = "Unlimited Foam: your extinguisher never runs out!", -- the gift fanfare tells the receiver this
			price = 149,
			icon = "∞",
			color = Color3.fromHex("#4FB3D9"),
		},
		{
			key = "PremiumPass",
			name = "PREMIUM PASS",
			blurb = "Unlock the premium battle pass track: gold helmets, titles, XP boosts.",
			perk = "the Premium Pass: the gold battle pass track with gold helmets, titles and XP boosts!",
			price = 299,
			icon = "★",
			color = Color3.fromHex("#FFC531"),
		},
		{
			key = "Helicopter",
			name = "FIRE HELICOPTER",
			blurb = "Fly your own fire helicopter! Fill the bucket and drop water on fires. Friends ride too!",
			perk = "the Fire Helicopter: fly it, fill the bucket at water and drop it on fires!",
			price = 399,
			icon = "🚁",
			color = Color3.fromHex("#D9372A"),
			hero = true, -- the store draws it as the big card on top with a 3D render (HeliBuilder)
		},
	},

	-- Donation developer products (order = button order). robux = the amount shown and recorded.
	DonationProducts = {
		{ id = 3721797853, robux = 10 },
		{ id = 3721797933, robux = 50 },
		{ id = 3721798027, robux = 100 },
		{ id = 3721798140, robux = 500 },
	},

	-- Player attributes MonetizationService writes / reads.
	Attr = {
		PassPrefix = "Pass_", -- Pass_<Key> = true when owned (server-authoritative)
		GiftedPrefix = "PassGifted_", -- owner-gifted in-game entitlement (not the real Roblox pass): the store says GIFTED
		DebugPrefix = "PassDebug_", -- Studio only: set PassDebug_<Key> = true on the server to fake ownership
		Donated = "RobuxDonated", -- all-time R$ this player donated (from their profile)
	},

	-- Purchase idempotency ledger (DataStore; in-memory in Studio like DataService).
	LedgerStore = "FlameAndBlamePurchases",
	-- Donor board (OrderedDataStore key = UserId, value = all-time R$ donated).
	DonorStore = "FlameAndBlameDonors_all",
	DonorTopN = 8,
	DonorRefreshSeconds = 90,

	-- The physical Donation Board in the station lobby, in StationBuilder's local studs (the same
	-- space as the mission board: the plaza west of it, facing the queue pads / +Z).
	Board = {
		LocationId = "Station",
		Center = Vector3.new(-28, 0.5, 38.5), -- floor point under the board's centre: east end of the plaza, clear of the front door (x -56..-50)
		Width = 8,
		Height = 7,
		Lift = 1.6, -- gap between the floor and the board's bottom edge (the donate buttons sit here)
		PixelsPerStud = 50,
	},

	-- Store UI
	StoreKey = Enum.KeyCode.B,
	ThankYouSeconds = 4,

	-- Pass offers (Services/OfferService decides, rules in Lib/Monetization/OfferRules; drawn by
	-- ClientLib/OfferCard on the results screen and as a small lobby card after a level up).
	-- Honest by design: real price on the BUY button, no timers, no "limited", no random rewards,
	-- never for a pass you own / that isn't for sale, never on a rookie call. NEXT CALL stays primary.
	Offers = {
		ResultsEvery = 2, -- results offer on every Nth completed (non-rookie) call this session: 2nd, 4th, ...
		MaxPerSession = 4, -- offers shown per session, all moments together
		MinGapSeconds = 150, -- at least this long between two offers
		MaxDeclines = 2, -- "No thanks" this many times to one pass = stop offering it this session
		LobbyCardsPerSession = 1, -- the lobby level-up card
		LobbyCardSeconds = 12, -- it hides itself after this
		DecideDelay = 2.5, -- s after MissionEnded (XP / level / pass XP land just after the results go out)
		ClickWindow = 600, -- s: a pass bought this soon after tapping its offer counts as an offer purchase
		RescueHero = 2, -- rescued at least this many this call = the "HERO RESCUE!" reason
		BigFire = 12, -- fires out + parts burnt on a call at least this many = the "BIG FIRE!" reason (Helicopter)
		-- what the card says, by pass key then reason (OfferRules reasons: foam, level, rescue, passxp, default)
		Headlines = {
			UnlimitedFoam = { foam = "OUT OF FOAM?", default = "NEVER RUN DRY!" },
			PremiumPass = { level = "LEVEL UP!", rescue = "HERO RESCUE!", passxp = "GO GOLD!", default = "GO GOLD!" },
			Helicopter = { bigfire = "WANT A FIRE HELICOPTER?", default = "FLY A FIRE HELICOPTER!" },
		},
		Short = { -- one line under the pass name (what you actually get)
			UnlimitedFoam = "Foam never runs out!",
			PremiumPass = "Gold helmets + titles",
			Helicopter = "Drop water from the sky!",
		},
		-- the owned-perks tag beside the helmet number over a player's head (everyone else sees it)
		PerkTag = { Px = 26, Gap = 4 },
	},
})
