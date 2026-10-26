--!strict
-- AchievementConfig [owner: Achievements]. Every achievement: what it counts, the goal, the small XP reward
-- (never Robux, never paid randomness) and the tier colour. Plain data, no requires and no Roblox APIs, so
-- game/tests/achievements.spec.luau loads it with the `luau` CLI. Rules: Lib/Achievements/AchievementRules.
-- Server: Services/AchievementService (counts stats from game signals, saves in the profile, awards badges).
-- Client: Controllers/AchievementController (the 🏆 chip + panel). Names / descs are Translations keys.
--
-- Def fields:
--   id     stable save key (never rename: profiles store unlocked[id])
--   name   SHORT, upper case (toast + card title)   desc  one kid-simple line
--   stat   which counter it reads (Stats below)     goal  unlocks when stat >= goal
--   xp     reward (DataService:AddXp)                tier  "bronze" | "silver" | "gold" (card colour)
--   icon   emoji on the card                         off   true = hidden and never unlocks (no source yet)
-- Badges: BadgeIds[id] = the Roblox badge asset id (Creator Dashboard). Missing / 0 = no badge, awarding
-- is a no-op. Icons + names for the dashboard: marketing/badges/out/<id>.png, marketing/badges/badges.json.

export type Tier = "bronze" | "silver" | "gold"
export type Def = {
	id: string,
	name: string,
	desc: string,
	stat: string,
	goal: number,
	xp: number,
	tier: Tier,
	icon: string,
	off: boolean?,
}

-- Counters kept in profile.achievements.stats. "max" stats keep the best value seen (level, pass tier,
-- squad streak); "sum" stats add up. sites is derived from the distinct places in achievements.sites.
local Stats: { [string]: "sum" | "max" } = {
	calls = "sum", -- calls finished (results screen)
	fires = "sum", -- burning parts you put out
	rescues = "sum", -- people / pets you rescued (RescueService.Rescued)
	pandas = "sum", -- pandas you helped carry out
	pets = "sum", -- dogs + cats you rescued
	treeCats = "sum", -- the CAT IN A TREE twist cat
	nightWins = "sum", -- NIGHT CALL twist calls won
	records = "sum", -- speed run records (TwistService newRecord)
	threeStars = "sum", -- 3-star calls
	fastArrivals = "sum", -- FAST RESPONSE arrivals
	combos = "sum", -- hose combos (FireService.Combo)
	teamwork = "sum", -- team rescues (RescueService.Escorted: helper or carrier)
	streak = "max", -- best squad streak (TeamBonusService Player attr SquadStreak)
	blamed = "sum", -- blame awards on the results screen
	yeets = "sum", -- rescues thrown (RescueService.Thrown)
	backdrafts = "sum", -- doors opened onto a backdraft (SmokeService.Backdraft)
	drives = "sum", -- truck drives of DriveMinStuds+ (VehicleService.Driven)
	hydrantFires = "sum", -- fires put out while your hose runs from a hydrant (Player attr HoseKind)
	doors = "sum", -- doors broken (ToolService.DoorBroken)
	sites = "max", -- different places you worked a call (derived)
	level = "max", -- player level (DataService)
	passTier = "max", -- battle pass tier (BattlePassService.TierUp / attr PassTier)
	dailyStreak = "max", -- daily chest streak day (ResultsFlowService Player attr DailyStreak)
}

local Defs: { Def } = {
	-- calls
	{ id = "first_call", name = "FIRST CALL", desc = "Finish your first call", stat = "calls", goal = 1, xp = 50, tier = "bronze", icon = "🚒" },
	{ id = "calls_25", name = "ON DUTY", desc = "Finish 25 calls", stat = "calls", goal = 25, xp = 150, tier = "silver", icon = "📟" },
	{ id = "calls_100", name = "STATION LEGEND", desc = "Finish 100 calls", stat = "calls", goal = 100, xp = 400, tier = "gold", icon = "🏛" },
	{ id = "three_stars", name = "3 STARS!", desc = "Get 3 stars on a call", stat = "threeStars", goal = 1, xp = 75, tier = "bronze", icon = "⭐" },
	{ id = "fast_response", name = "FAST RESPONSE", desc = "Get to a call super fast", stat = "fastArrivals", goal = 1, xp = 50, tier = "bronze", icon = "⏱" },
	{ id = "speed_run", name = "SPEED RUN RECORD", desc = "Set a new speed record", stat = "records", goal = 1, xp = 100, tier = "silver", icon = "🏁" },
	{ id = "explorer", name = "EXPLORER", desc = "Work calls at 3 different places", stat = "sites", goal = 3, xp = 75, tier = "bronze", icon = "🗺" },
	{ id = "city_tour", name = "CITY TOUR", desc = "Work calls at 10 different places", stat = "sites", goal = 10, xp = 250, tier = "silver", icon = "🏙" },
	-- fires
	{ id = "fires_10", name = "10 FIRES OUT", desc = "Put out 10 fires", stat = "fires", goal = 10, xp = 50, tier = "bronze", icon = "🔥" },
	{ id = "fires_100", name = "100 FIRES OUT", desc = "Put out 100 fires", stat = "fires", goal = 100, xp = 150, tier = "silver", icon = "🧯" },
	{ id = "fires_1000", name = "1000 FIRES OUT", desc = "Put out 1000 fires", stat = "fires", goal = 1000, xp = 500, tier = "gold", icon = "🌊" },
	{ id = "hydrant_hero", name = "HYDRANT HERO", desc = "Put out 10 fires with a hydrant hose", stat = "hydrantFires", goal = 10, xp = 150, tier = "silver", icon = "🚰" },
	{ id = "door_buster", name = "DOOR BUSTER", desc = "Break down 10 doors", stat = "doors", goal = 10, xp = 75, tier = "bronze", icon = "🪓" },
	{ id = "backdraft", name = "BACKDRAFT SURVIVOR", desc = "Open a door into a backdraft", stat = "backdrafts", goal = 1, xp = 75, tier = "silver", icon = "💥" },
	-- rescues
	{ id = "first_rescue", name = "FIRST RESCUE", desc = "Save someone from a fire", stat = "rescues", goal = 1, xp = 50, tier = "bronze", icon = "🛟" },
	{ id = "rescues_10", name = "10 RESCUES", desc = "Save 10 people or pets", stat = "rescues", goal = 10, xp = 100, tier = "bronze", icon = "🙌" },
	{ id = "rescues_50", name = "50 RESCUES", desc = "Save 50 people or pets", stat = "rescues", goal = 50, xp = 250, tier = "silver", icon = "🦸" },
	{ id = "rescues_250", name = "250 RESCUES", desc = "Save 250 people or pets", stat = "rescues", goal = 250, xp = 600, tier = "gold", icon = "👑" },
	{ id = "save_panda", name = "SAVE THE PANDA", desc = "Carry a panda to safety", stat = "pandas", goal = 1, xp = 50, tier = "bronze", icon = "🐼" },
	{ id = "panda_pal", name = "PANDA PAL", desc = "Save 10 pandas", stat = "pandas", goal = 10, xp = 200, tier = "silver", icon = "🎋" },
	{ id = "pet_pal", name = "PET PAL", desc = "Save 10 dogs and cats", stat = "pets", goal = 10, xp = 150, tier = "silver", icon = "🐶" },
	{ id = "cat_tree", name = "CAT IN A TREE", desc = "Get the cat down from the tree", stat = "treeCats", goal = 1, xp = 100, tier = "silver", icon = "🐱" },
	{ id = "night_hero", name = "NIGHT HERO", desc = "Win a night call", stat = "nightWins", goal = 1, xp = 100, tier = "silver", icon = "🌙" },
	{ id = "yeet", name = "YEET!", desc = "Throw someone to safety", stat = "yeets", goal = 1, xp = 25, tier = "bronze", icon = "🤾" },
	-- friends
	{ id = "first_combo", name = "COMBO!", desc = "Hose one fire with a friend", stat = "combos", goal = 1, xp = 50, tier = "bronze", icon = "💦" },
	{ id = "combo_master", name = "COMBO MASTER", desc = "Make 25 hose combos with friends", stat = "combos", goal = 25, xp = 200, tier = "silver", icon = "🌀" },
	{ id = "teamwork", name = "TEAMWORK", desc = "Team up on 10 rescues", stat = "teamwork", goal = 10, xp = 150, tier = "silver", icon = "🤝" },
	{ id = "squad_streak", name = "SQUAD STREAK 5", desc = "Win 5 calls in a row with your squad", stat = "streak", goal = 5, xp = 200, tier = "gold", icon = "🔗" },
	{ id = "blamed", name = "BLAMED!", desc = "Get blamed on the results screen", stat = "blamed", goal = 1, xp = 25, tier = "bronze", icon = "🙈" },
	-- truck
	{ id = "driver", name = "DRIVER", desc = "Drive the fire truck 10 times", stat = "drives", goal = 10, xp = 100, tier = "bronze", icon = "🛻" },
	-- progress
	{ id = "level_10", name = "LEVEL 10", desc = "Reach level 10", stat = "level", goal = 10, xp = 100, tier = "bronze", icon = "🥉" },
	{ id = "level_25", name = "LEVEL 25", desc = "Reach level 25", stat = "level", goal = 25, xp = 250, tier = "silver", icon = "🥈" },
	{ id = "level_50", name = "LEVEL 50", desc = "Reach level 50", stat = "level", goal = 50, xp = 600, tier = "gold", icon = "🥇" },
	{ id = "pass_25", name = "PASS TIER 25", desc = "Reach battle pass tier 25", stat = "passTier", goal = 25, xp = 150, tier = "silver", icon = "🎟" },
	{ id = "pass_50", name = "PASS TIER 50", desc = "Reach battle pass tier 50", stat = "passTier", goal = 50, xp = 300, tier = "gold", icon = "🎫" },
	{ id = "pass_100", name = "PASS TIER 100", desc = "Reach battle pass tier 100", stat = "passTier", goal = 100, xp = 600, tier = "gold", icon = "💎" },
	-- the DAILY CHEST (ResultsFlowService, Player attr DailyStreak = streak day 1..7)
	{ id = "daily_7", name = "DAILY STREAK 7", desc = "Open the daily chest 7 days in a row", stat = "dailyStreak", goal = 7, xp = 200, tier = "silver", icon = "📅" },
}

return {
	Defs = Defs,
	Stats = Stats,
	-- Roblox badge ids by achievement id. 0 / missing = no badge yet (awarding no-ops). The 10 badge
	-- achievements; fill the ids from the Creator Dashboard (Monetization -> Badges).
	BadgeIds = {
		first_call = 34249046836746,
		first_rescue = 3993048265763442,
		save_panda = 1110109702515702,
		fires_100 = 1327085210458047,
		cat_tree = 4098018697608399,
		night_hero = 0,
		speed_run = 0,
		combo_master = 0,
		yeet = 0,
		level_25 = 0,
	} :: { [string]: number },
	DriveMinStuds = 150, -- a truck drive shorter than this isn't a "drive" (parking shuffles)
	MaxSites = 64, -- distinct places remembered per profile
	FlushSeconds = 0.5, -- stat bumps are batched per player and saved into the profile this often
	ToastGapSeconds = 1.8, -- unlock toasts one after another, never stacked
	ToastHoldMax = 8, -- hold toasts while the first-fire tutorial cards are up, at most this long
	RetroToastMax = 2, -- joining with several old unlocks at once: one summary toast past this many
	XpReason = "Achievement",
	Attr = { Count = "AchievementCount", Total = "AchievementTotal" }, -- Player attrs (unlocked / enabled)
	Toast = "🏆 ACHIEVEMENT! {1} +{2} XP", -- Translations key; {1} = name (a key itself), {2} = XP
	ToastMany = "🏆 {1} ACHIEVEMENTS UNLOCKED!",
}
