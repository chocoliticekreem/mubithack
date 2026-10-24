--!strict
-- Single source of truth for the battle pass. Data only, no logic.
-- Read values at use time (BattlePassConfig.XpPerTier), never copy them into module-level locals.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared", 10)
assert(Shared, "[BattlePassConfig] ReplicatedStorage.Shared missing")
local ConfigModule = Shared:WaitForChild("Config", 10)
assert(ConfigModule, "[BattlePassConfig] Shared.Config missing")
local Config = require(ConfigModule :: ModuleScript) :: any
-- the premium pass id lives in MonetizationConfig (one source of truth for every Robux id)
local MonetizationConfig = require(script.Parent:WaitForChild("MonetizationConfig") :: ModuleScript) :: any

local function title(id: string): { [string]: any }
	return { Kind = "Title", Id = id }
end

local function tint(name: string, r: number, g: number, b: number): { [string]: any }
	return { Kind = "HelmetTint", Id = name, Color = Color3.fromRGB(r, g, b) }
end

local function boost(pct: number): { [string]: any }
	return { Kind = "XpBoost", Id = "XpBoost" .. tostring(pct), Pct = pct }
end

local Tiers: { { [string]: any } } = {
	{ Tier = 1, Free = title("Rookie"), Premium = tint("Gold", 255, 200, 40) },
	{ Tier = 2, Free = tint("Red", 220, 40, 40), Premium = boost(5) },
	{ Tier = 3, Free = boost(3), Premium = title("Flame Fighter") },
	{ Tier = 4, Free = tint("Yellow", 255, 225, 60), Premium = tint("Cyan", 40, 220, 235) },
	{ Tier = 5, Free = title("Hose Hero"), Premium = boost(8) },
	{ Tier = 6, Free = tint("Blue", 50, 120, 235), Premium = title("Smoke Eater") },
	{ Tier = 7, Free = boost(4), Premium = tint("Magenta", 230, 60, 200) },
	{ Tier = 8, Free = tint("Green", 60, 200, 90), Premium = boost(10) },
	{ Tier = 9, Free = title("Axe Ace"), Premium = title("Blaze Breaker") },
	{ Tier = 10, Free = boost(5), Premium = tint("Chrome", 205, 210, 220) },
	{ Tier = 11, Free = tint("Orange", 255, 140, 30), Premium = boost(12) },
	{ Tier = 12, Free = title("Rescuer"), Premium = title("Hero of 67") },
	{ Tier = 13, Free = boost(6), Premium = tint("Violet", 150, 80, 235) },
	{ Tier = 14, Free = tint("Teal", 40, 180, 170), Premium = boost(14) },
	{ Tier = 15, Free = title("Station Star"), Premium = title("Inferno Tamer") },
	{ Tier = 16, Free = boost(7), Premium = tint("Rose Gold", 235, 150, 130) },
	{ Tier = 17, Free = tint("White", 245, 245, 245), Premium = boost(16) },
	{ Tier = 18, Free = title("Captain Material"), Premium = tint("Lava", 255, 80, 20) },
	{ Tier = 19, Free = boost(8), Premium = title("Legend of the Block") },
	{ Tier = 20, Free = title("Chief"), Premium = tint("Diamond", 150, 240, 255) },
}

return Config.define({
	SeasonId = "S1",
	GamePassId = MonetizationConfig.GamePasses.PremiumPass, -- set it in MonetizationConfig; 0 = not configured: prompts skipped, premium via debug attribute
	MaxTier = 20,
	XpPerTier = 50, -- tier 1 after ~25s of Active play (2 XP/s)
	PremiumXpMultiplier = 1.5,

	-- XP trickle while the round is Active
	XpPerActiveTick = 10,
	TickSeconds = 5,
	XpRoundStart = 10, -- optional one-time grant when a round goes Active (used if the service reads it)
	XpBonusRescue = 25,
	XpBonusRoundComplete = 50,

	-- Anti-abuse / persistence
	ClaimCooldownSeconds = 0.4,
	SaveRetries = 3,
	DataStoreName = "FlameAndBlamePass",

	-- Client
	UiToggleKey = Enum.KeyCode.P,

	-- Attributes the server sets on the player (and the debug override)
	PremiumDebugAttribute = "BattlePassPremiumDebug",
	AttributeNames = {
		Xp = "PassXp",
		Tier = "PassTier",
		Premium = "PassPremium",
		Title = "PassTitle",
		HelmetTint = "PassHelmetTint",
		XpBoost = "PassXpBoost",
	},
	-- Reward Kind -> player attribute set on claim
	RewardAttributes = {
		Title = "PassTitle",
		HelmetTint = "PassHelmetTint",
		XpBoost = "PassXpBoost",
	},

	-- Remote names (created by the server under ReplicatedStorage.Remotes)
	RemotesFolder = "Remotes",
	Remotes = {
		State = "BattlePassState",
		Claim = "BattlePassClaim",
		Result = "BattlePassClaimResult",
		Prompt = "BattlePassPrompt",
	},

	-- ForgeTelemetry counter names (server side only)
	Counters = {
		XpAwarded = "battlepass_xp_awarded",
		TierUp = "battlepass_tier_up",
		Claims = "battlepass_claims",
		Prompts = "battlepass_prompts",
	},

	Tiers = Tiers,
})
