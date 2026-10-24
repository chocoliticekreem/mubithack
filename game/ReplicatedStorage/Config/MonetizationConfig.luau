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
	},

	-- How each pass shows in the store (order = card order). price = the R$ shown until
	-- MarketplaceService:GetProductInfo answers (and always while the id is 0). icon = a glyph used
	-- when the pass has no icon image yet.
	Passes = {
		{
			key = "UnlimitedFoam",
			name = "UNLIMITED FOAM",
			blurb = "Your extinguishers never run dry. Foam forever!",
			price = 149,
			icon = "∞",
			color = Color3.fromHex("#4FB3D9"),
		},
		{
			key = "PremiumPass",
			name = "PREMIUM PASS",
			blurb = "Unlock the premium battle pass track: gold helmets, titles, XP boosts.",
			price = 299,
			icon = "★",
			color = Color3.fromHex("#FFC531"),
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
})
