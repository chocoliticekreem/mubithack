--!strict
-- BattlePassConfig [owner: BattlePass]. Single source of truth for the battle pass. Data only, no logic.
-- Read values at use time (BattlePassConfig.XpPerTier), never copy them into module-level locals.
-- Pure rules: ReplicatedStorage/Lib/BattlePass/PassRules (specs: game/tests/battlepass.spec.luau).
--
-- Rewards (by id). Slot = where it goes when equipped:
--   helmet  recolours the penguin's helmet dome/comb/brim (Color, optional Trim, Neon, Sparkle, Chief)
--   title   BillboardGui over the head + the squad strip + the results cards
--   hose    the hose tool, the hose line beams and the first-person nozzle hose (Color, Stripe)
--   truck   neon underglow under your fire truck (Color, optional Pulse)
--   nozzle  the hose tool's tip (Color, Sparkle)
--   emote   [K] in the lobby, or DANCE in the panel's locker (Style "spin" | "flex")
--   boost   not equipped: every claimed boost adds Pct % to the pass XP you earn (capped)
-- Colours are hex strings so the pure rules / specs never touch Color3.
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

local Rewards: { [string]: { [string]: any } } = {
	-- titles
	title_rookie = { Slot = "title", Name = "Rookie", Color = "#FFF1D6" },
	title_flame = { Slot = "title", Name = "Flame Fighter", Color = "#FF8A1F" },
	title_hosehero = { Slot = "title", Name = "Hose Hero", Color = "#4FB3D9" },
	title_axeace = { Slot = "title", Name = "Axe Ace", Color = "#D9372A" },
	title_blaze = { Slot = "title", Name = "Blaze Breaker", Color = "#FFE45C" },
	title_rescuer = { Slot = "title", Name = "Rescuer", Color = "#6BCB5A" },
	title_star = { Slot = "title", Name = "Station Star", Color = "#FFC531" },
	title_captain = { Slot = "title", Name = "Captain Material", Color = "#7FF5F0" },
	title_legend = { Slot = "title", Name = "Legend of the Block", Color = "#E07BFF" },
	title_chief = { Slot = "title", Name = "Fire Chief", Color = "#FFD84A", Shine = true },
	-- helmets
	helmet_cherry = { Slot = "helmet", Name = "Cherry Helmet", Color = "#E8323A" },
	helmet_gold = { Slot = "helmet", Name = "Gold Rush Helmet", Color = "#FFC21F", Trim = "#FFF1A8", Sparkle = true },
	helmet_ice = { Slot = "helmet", Name = "Ice Helmet", Color = "#5FE3F2", Trim = "#E8FDFF" },
	helmet_ocean = { Slot = "helmet", Name = "Ocean Helmet", Color = "#2F7BEA" },
	helmet_chrome = { Slot = "helmet", Name = "Chrome Helmet", Color = "#D9DEE6", Trim = "#9AA3B0", Metal = true },
	helmet_teal = { Slot = "helmet", Name = "Teal Helmet", Color = "#24B5A8" },
	helmet_rose = { Slot = "helmet", Name = "Rose Gold Helmet", Color = "#EBA08A", Trim = "#FFE0D2", Metal = true },
	helmet_snow = { Slot = "helmet", Name = "Snow Helmet", Color = "#F6F6F2", Trim = "#B9C6D6" },
	helmet_lava = { Slot = "helmet", Name = "Lava Helmet", Color = "#FF4B12", Trim = "#FFD04A", Neon = true },
	helmet_chief = { Slot = "helmet", Name = "Fire Chief Helmet", Color = "#FFFFFF", Trim = "#FFC21F", Sparkle = true, Chief = true },
	-- hoses
	hose_lime = { Slot = "hose", Name = "Lime Hose", Color = "#8EE04A", Stripe = "#2E6B1A" },
	hose_bubblegum = { Slot = "hose", Name = "Bubblegum Hose", Color = "#FF7FC8", Stripe = "#FFFFFF" },
	hose_inferno = { Slot = "hose", Name = "Inferno Hose", Color = "#FF6A1A", Stripe = "#FFE45C" },
	hose_midnight = { Slot = "hose", Name = "Midnight Hose", Color = "#2A2F5A", Stripe = "#7FF5F0" },
	hose_gold = { Slot = "hose", Name = "Gold Hose", Color = "#FFC21F", Stripe = "#FFFFFF" },
	hose_diamond = { Slot = "hose", Name = "Diamond Hose", Color = "#BDF4FF", Stripe = "#4FB3D9" },
	-- truck underglow
	truck_blue = { Slot = "truck", Name = "Neon Blue Underglow", Color = "#2FA8FF" },
	truck_toxic = { Slot = "truck", Name = "Toxic Underglow", Color = "#6BFF3A" },
	truck_magenta = { Slot = "truck", Name = "Magenta Underglow", Color = "#FF2FD2" },
	truck_inferno = { Slot = "truck", Name = "Inferno Underglow", Color = "#FF5A1F", Pulse = "#FFE45C" },
	truck_gold = { Slot = "truck", Name = "Gold Underglow", Color = "#FFC21F" },
	-- nozzle
	nozzle_gold = { Slot = "nozzle", Name = "Golden Nozzle", Color = "#FFC21F", Sparkle = true },
	-- emotes
	emote_flex = { Slot = "emote", Name = "Hero Flex", Style = "flex" },
	emote_spin = { Slot = "emote", Name = "Victory Spin", Style = "spin" },
	-- xp boosts
	boost_5a = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5b = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5c = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5d = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_10a = { Slot = "boost", Name = "+10% Pass XP", Pct = 10 },
	boost_10b = { Slot = "boost", Name = "+10% Pass XP", Pct = 10 },
}

-- Tiers[n] = the rewards unlocked at tier n (index = tier). Every id is used once.
local Tiers: { { Free: string, Premium: string } } = {
	{ Free = "title_rookie", Premium = "helmet_gold" }, -- 1
	{ Free = "helmet_cherry", Premium = "hose_lime" }, -- 2
	{ Free = "boost_5a", Premium = "title_flame" }, -- 3
	{ Free = "hose_bubblegum", Premium = "truck_blue" }, -- 4
	{ Free = "title_hosehero", Premium = "helmet_ice" }, -- 5
	{ Free = "helmet_ocean", Premium = "boost_10a" }, -- 6
	{ Free = "truck_toxic", Premium = "emote_spin" }, -- 7
	{ Free = "boost_5b", Premium = "hose_inferno" }, -- 8
	{ Free = "title_axeace", Premium = "title_blaze" }, -- 9
	{ Free = "emote_flex", Premium = "helmet_chrome" }, -- 10
	{ Free = "hose_midnight", Premium = "truck_magenta" }, -- 11
	{ Free = "title_rescuer", Premium = "nozzle_gold" }, -- 12
	{ Free = "boost_5c", Premium = "helmet_lava" }, -- 13
	{ Free = "helmet_teal", Premium = "boost_10b" }, -- 14
	{ Free = "title_star", Premium = "truck_inferno" }, -- 15
	{ Free = "hose_gold", Premium = "helmet_rose" }, -- 16
	{ Free = "helmet_snow", Premium = "truck_gold" }, -- 17
	{ Free = "title_captain", Premium = "hose_diamond" }, -- 18
	{ Free = "boost_5d", Premium = "title_legend" }, -- 19
	{ Free = "title_chief", Premium = "helmet_chief" }, -- 20: the Fire Chief
}

return Config.define({
	SeasonId = "S1",
	SeasonName = "SEASON 1: HOT START",
	SeasonEndsAt = 1796083200, -- 2026-12-01 00:00 UTC (unix seconds); the panel counts down to it
	MaxTier = 20,
	XpPerTier = 100,
	PremiumXpMultiplier = 1.5, -- premium owners earn pass XP faster
	BoostCapPct = 50, -- claimed XP boosts add up to at most this

	-- XP sources
	XpPerActiveTick = 5, -- every TickSeconds while your run is Active (no popup: it just fills the bar)
	TickSeconds = 5,
	XpPerFireOut = 5, -- each fire you put out
	XpBonusRescue = 25, -- each person / pet you carry out
	XpBonusRoundComplete = 50, -- mission over (any outcome)
	XpPerStar = 25, -- + per star when a mission ends

	-- Client
	UiToggleKey = Enum.KeyCode.P,
	EmoteKey = Enum.KeyCode.K, -- J is the onboarding SKIP key
	EmoteCooldown = 2.5,

	-- Studio switch (server side): player:SetAttribute("BattlePassPremiumDebug", true) = premium.
	-- In Studio MonetizationService also mirrors PassDebug_PremiumPass into it.
	PremiumDebugAttribute = "BattlePassPremiumDebug",
	PremiumAttribute = "Pass_PremiumPass", -- MonetizationService: owns MonetizationConfig.GamePasses.PremiumPass

	-- Player attributes the server writes (HUD / tests / other services read these)
	Attr = {
		Xp = "PassXp", -- total pass XP this season
		Tier = "PassTier",
		Premium = "PassPremium",
		Boost = "PassXpBoost", -- total boost %
		RunXp = "PassRunXp", -- pass XP earned in the current mission run (Results screen); 0 in the lobby
		Title = "PassTitle", -- equipped title name ("" = none)
		TitleColor = "PassTitleColor", -- Color3
		Hose = "PassHose", -- Color3 of the equipped hose (nil = default yellow)
		HoseStripe = "PassHoseStripe",
		Nozzle = "PassNozzle", -- Color3 of the equipped nozzle (nil = brass)
		Claimable = "PassClaimable", -- rewards waiting for a Claim press
	},

	-- Legacy (pre-profile) store, imported once per player in live games
	LegacyStore = "BattlePass_S1",

	Tiers = Tiers,
	Rewards = Rewards,
})
