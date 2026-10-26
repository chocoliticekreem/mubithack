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
--   truck   + Paint (hex): also repaints the truck's red body panels (PaintMetal = metal finish)
--   boost   not equipped: every claimed boost adds Pct % to the pass XP you earn (capped)
-- Colours are hex strings so the pure rules / specs never touch Color3.
--
-- 100 tiers. Tiers 1-20 are the original season-1 pass and must never change (players have claimed them:
-- claims are stored by tier number). Tiers 21-100 mix hand-made rewards with palette variants:
-- "helmet:mint:neon" = PassRules.variant (id "helmet_mint", name "Mint Helmet"), drawn from Palette below.
-- Never reorder or edit a shipped tier row; append-only. Every reward name is a Translations key.
--
-- XP curve (XpCurve[t] = XP from tier t-1 to t): curve 3 ramps from 150 XP to 6000 XP per tier, 240,700 XP
-- in total (about 4x curve 2): roughly 700 average missions for a free player with no boosts. CurveVersion stamps each pass; a pass from an older curve is
-- moved onto this one keeping its tier and fraction (PassRules.migrateCurve, BattlePassService.onProfile).
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)
local PassRules = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("BattlePass"):WaitForChild("PassRules") :: ModuleScript)

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

	------------------------------------------------------------------ tiers 21-100 (hand-made)
	-- milestones: 25 / 50 / 75 / 100
	title_super = { Slot = "title", Name = "Super Firefighter", Color = "#FFC531", Shine = true },
	helmet_golden = { Slot = "helmet", Name = "Golden Helmet", Color = "#FFC21F", Trim = "#FFF1A8", Metal = true, Sparkle = true, Glow = true },
	paint_silver = { Slot = "truck", Name = "Silver Truck Paint", Paint = "#C9CED6", PaintMetal = true, Color = "#E8F0FF" },
	paint_gold = { Slot = "truck", Name = "Gold Truck Paint", Paint = "#FFC21F", PaintMetal = true, Color = "#FFD84A", Pulse = "#FFFFFF" },
	helmet_hero = { Slot = "helmet", Name = "Hero Helmet", Color = "#FFFFFF", Trim = "#D9372A", Sparkle = true },
	helmet_diamond = { Slot = "helmet", Name = "Diamond Helmet", Color = "#BDF4FF", Trim = "#FFFFFF", Neon = true, Sparkle = true, Glow = true },
	title_legendary = { Slot = "title", Name = "LEGEND", Color = "#FFD84A", Shine = true },
	helmet_legend = { Slot = "helmet", Name = "Legend Helmet", Color = "#FFC21F", Trim = "#FF5A1F", Neon = true, Sparkle = true, Chief = true, Glow = true },
	-- truck paints (premium 70 / 90)
	paint_galaxy = { Slot = "truck", Name = "Galaxy Truck Paint", Paint = "#3B1E6B", Color = "#E07BFF", Pulse = "#2FA8FF" },
	paint_inferno = { Slot = "truck", Name = "Inferno Truck Paint", Paint = "#1E1B24", Color = "#FF5A1F", Pulse = "#FFE45C" },
	-- emotes: Style spin (Turns = full turns, classic 2) | flex (Hop = jump speed, classic 38); Shout = the text over your head; Fx = confetti colours
	emote_hop = { Slot = "emote", Name = "Happy Hop", Style = "flex", Hop = 30, Shout = "HAPPY HOP!", Fx = { "#6BCB5A", "#FFE45C", "#7EC8F5" } },
	emote_cheer = { Slot = "emote", Name = "Cheer Jump", Style = "flex", Hop = 44, Shout = "CHEER!", Fx = { "#FF7FC8", "#FFE45C", "#FFFFFF" } },
	emote_twirl = { Slot = "emote", Name = "Splash Twirl", Style = "spin", Turns = 3, Shout = "SPLASH TWIRL!", Fx = { "#4FB3D9", "#BDF4FF", "#FFFFFF" } },
	emote_firedance = { Slot = "emote", Name = "Fire Dance", Style = "spin", Turns = 2, Shout = "FIRE DANCE!", Fx = { "#FF4B12", "#FF8A1F", "#FFE45C" } },
	emote_tornado = { Slot = "emote", Name = "Tornado Spin", Style = "spin", Turns = 4, Shout = "TORNADO!", Fx = { "#C9D3DE", "#7EC8F5", "#FFFFFF" } },
	emote_superjump = { Slot = "emote", Name = "Super Jump", Style = "flex", Hop = 62, Shout = "SUPER JUMP!", Fx = { "#FFC21F", "#E07BFF", "#2FA8FF" } },
	-- xp boosts (free 23 38 57 83, premium 34 54; all boosts together stop at BoostCapPct)
	boost_5e = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5f = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5g = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5h = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5i = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	boost_5j = { Slot = "boost", Name = "+5% Pass XP", Pct = 5 },
	-- titles
	title_smokediver = { Slot = "title", Name = "Smoke Diver", Color = "#7FF5F0" },
	title_bucketboss = { Slot = "title", Name = "Bucket Boss", Color = "#FFE45C" },
	title_sirenstar = { Slot = "title", Name = "Siren Star", Color = "#FF8A1F" },
	title_sparkstopper = { Slot = "title", Name = "Spark Stopper", Color = "#6BCB5A" },
	title_ladderclimber = { Slot = "title", Name = "Ladder Climber", Color = "#4FB3D9" },
	title_emberhunter = { Slot = "title", Name = "Ember Hunter", Color = "#FF7FC8" },
	title_petprotector = { Slot = "title", Name = "Pet Protector", Color = "#E07BFF" },
	title_pandapal = { Slot = "title", Name = "Panda Pal", Color = "#FFC531" },
	title_hydranthero = { Slot = "title", Name = "Hydrant Hero", Color = "#7FF5F0" },
	title_roadruler = { Slot = "title", Name = "Road Ruler", Color = "#FFE45C" },
	title_foammaster = { Slot = "title", Name = "Foam Master", Color = "#FF8A1F" },
	title_heatseeker = { Slot = "title", Name = "Heat Seeker", Color = "#6BCB5A" },
	title_squadleader = { Slot = "title", Name = "Squad Leader", Color = "#4FB3D9" },
	title_nightwatch = { Slot = "title", Name = "Night Watch", Color = "#FF7FC8" },
	title_splashchamp = { Slot = "title", Name = "Splash Champ", Color = "#E07BFF" },
	title_fearless = { Slot = "title", Name = "Fearless", Color = "#FFC531" },
	title_firestorm = { Slot = "title", Name = "Firestorm", Color = "#7FF5F0" },
	title_bravest = { Slot = "title", Name = "Bravest", Color = "#FFE45C" },
	title_waterwizard = { Slot = "title", Name = "Water Wizard", Color = "#FF8A1F" },
	title_hotshot = { Slot = "title", Name = "Hot Shot", Color = "#6BCB5A" },
	title_lifesaver = { Slot = "title", Name = "Lifesaver", Color = "#4FB3D9" },
	title_flametamer = { Slot = "title", Name = "Flame Tamer", Color = "#FF7FC8" },
	title_blockguardian = { Slot = "title", Name = "Block Guardian", Color = "#E07BFF" },
	title_stationhero = { Slot = "title", Name = "Station Hero", Color = "#FFC531" },
}

-- Colours for the generated variants (key -> { Name, Color, Trim }). Append-only: ids come from the keys.
local Palette: { [string]: { [string]: any } } = {
	mint = { Name = "Mint", Color = "#6FE3B4", Trim = "#1E7A5A" },
	coral = { Name = "Coral", Color = "#FF7A6B", Trim = "#FFE0D2" },
	grape = { Name = "Grape", Color = "#8A4FD8", Trim = "#E0C8FF" },
	lemon = { Name = "Lemon", Color = "#FFE45C", Trim = "#B88A00" },
	cocoa = { Name = "Cocoa", Color = "#7A4A2E", Trim = "#E8C9A0" },
	berry = { Name = "Berry", Color = "#C2185B", Trim = "#FF9DC8" },
	sky = { Name = "Sky", Color = "#7EC8F5", Trim = "#FFFFFF" },
	forest = { Name = "Forest", Color = "#2E7D32", Trim = "#A6E39A" },
	peach = { Name = "Peach", Color = "#FFB38A", Trim = "#FF7A4A" },
	ruby = { Name = "Ruby", Color = "#D3123F", Trim = "#FFB3C1" },
	emerald = { Name = "Emerald", Color = "#1FBF6A", Trim = "#D6FFE6" },
	sapphire = { Name = "Sapphire", Color = "#1E4FD8", Trim = "#9EC1FF" },
	amber = { Name = "Amber", Color = "#FFB000", Trim = "#7A4A00" },
	pearl = { Name = "Pearl", Color = "#F3EEE6", Trim = "#C9B79C" },
	slate = { Name = "Slate", Color = "#5E6B7A", Trim = "#C9D3DE" },
	lilac = { Name = "Lilac", Color = "#C9A2F0", Trim = "#6B3FA0" },
	tangerine = { Name = "Tangerine", Color = "#FF8C1A", Trim = "#FFE0B0" },
	cobalt = { Name = "Cobalt", Color = "#0047AB", Trim = "#7FF5F0" },
	jade = { Name = "Jade", Color = "#00A86B", Trim = "#E6FFF5" },
	crimson = { Name = "Crimson", Color = "#B0102A", Trim = "#FFD84A" },
	galaxy = { Name = "Galaxy", Color = "#3B1E6B", Trim = "#E07BFF" },
	arctic = { Name = "Arctic", Color = "#CFF4FF", Trim = "#4FB3D9" },
	sunset = { Name = "Sunset", Color = "#FF5E3A", Trim = "#FFC531" },
	candy = { Name = "Candy", Color = "#FF6FB5", Trim = "#FFFFFF" },
	olive = { Name = "Olive", Color = "#7A8B2A", Trim = "#E8F0B0" },
	navy = { Name = "Navy", Color = "#1B2A5C", Trim = "#FFC21F" },
	plum = { Name = "Plum", Color = "#6B2D5C", Trim = "#F0A8D8" },
	copper = { Name = "Copper", Color = "#C46A2B", Trim = "#FFD0A8" },
	bronze = { Name = "Bronze", Color = "#A97142", Trim = "#E8C9A0" },
	silver = { Name = "Silver", Color = "#C9CED6", Trim = "#8A93A0" },
	obsidian = { Name = "Obsidian", Color = "#1E1B24", Trim = "#FF5A1F" },
	honey = { Name = "Honey", Color = "#F2A93B", Trim = "#FFF1A8" },
	blossom = { Name = "Blossom", Color = "#FFB7D5", Trim = "#FF6FB5" },
	aqua = { Name = "Aqua", Color = "#2FE0E0", Trim = "#E8FDFF" },
	watermelon = { Name = "Watermelon", Color = "#FF4F6D", Trim = "#4CC26A" },
	blueberry = { Name = "Blueberry", Color = "#4A5BE8", Trim = "#C8D0FF" },
	pumpkin = { Name = "Pumpkin", Color = "#FF7518", Trim = "#2A1410" },
	seafoam = { Name = "Seafoam", Color = "#8FE3C8", Trim = "#2F7BEA" },
	charcoal = { Name = "Charcoal", Color = "#3A3A40", Trim = "#FF8A1F" },
	sand = { Name = "Sand", Color = "#E8D3A2", Trim = "#A8843F" },
	rust = { Name = "Rust", Color = "#A8431F", Trim = "#FFB38A" },
	electric = { Name = "Electric", Color = "#3DF2FF", Trim = "#1E4FD8" },
	firefly = { Name = "Firefly", Color = "#D4FF3A", Trim = "#3B5A00" },
	marshmallow = { Name = "Marshmallow", Color = "#FFF6EE", Trim = "#FFB7D5" },
	royal = { Name = "Royal", Color = "#5B2FD8", Trim = "#FFD84A" },
	flamingo = { Name = "Flamingo", Color = "#FF8FB1", Trim = "#FFFFFF" },
	storm = { Name = "Storm", Color = "#6E7F99", Trim = "#E8F0FF" },
	volcano = { Name = "Volcano", Color = "#8B1A00", Trim = "#FF6A1A" },
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
	{ Free = "title_chief", Premium = "helmet_chief" }, -- 20: the Fire Chief (end of the original pass)
	-- 21-100: "<slot>:<colour>[:<pattern>]" codes become palette variants below
	{ Free = "helmet:mint:plain", Premium = "helmet:coral:neon" }, -- 21
	{ Free = "title_smokediver", Premium = "truck:plum" }, -- 22
	{ Free = "boost_5e", Premium = "hose:slate" }, -- 23
	{ Free = "hose:pearl", Premium = "helmet:grape:sparkle" }, -- 24
	{ Free = "title_super", Premium = "helmet_golden" }, -- 25
	{ Free = "truck:copper", Premium = "nozzle:lemon:sparkle" }, -- 26
	{ Free = "helmet:lemon:twotone", Premium = "truck:bronze" }, -- 27
	{ Free = "title_bucketboss", Premium = "title_sirenstar" }, -- 28
	{ Free = "hose:lilac", Premium = "hose:tangerine" }, -- 29
	{ Free = "nozzle:forest", Premium = "emote_firedance" }, -- 30
	{ Free = "truck:silver", Premium = "helmet:cocoa:metal" }, -- 31
	{ Free = "helmet:berry:metal", Premium = "truck:obsidian:pulse" }, -- 32
	{ Free = "title_sparkstopper", Premium = "hose:cobalt" }, -- 33
	{ Free = "hose:jade", Premium = "boost_5i" }, -- 34
	{ Free = "helmet:forest:plain", Premium = "helmet:sky:twotone" }, -- 35
	{ Free = "title_ladderclimber", Premium = "truck:honey" }, -- 36
	{ Free = "truck:blossom:pulse", Premium = "helmet:peach:neon" }, -- 37
	{ Free = "boost_5f", Premium = "nozzle:sapphire:sparkle" }, -- 38
	{ Free = "hose:crimson", Premium = "hose:galaxy" }, -- 39
	{ Free = "helmet:ruby:twotone", Premium = "truck:aqua" }, -- 40
	{ Free = "title_emberhunter", Premium = "helmet:emerald:sparkle" }, -- 41
	{ Free = "hose:arctic", Premium = "title_petprotector" }, -- 42
	{ Free = "truck:watermelon", Premium = "hose:sunset" }, -- 43
	{ Free = "nozzle:lilac:sparkle", Premium = "helmet:sapphire:metal" }, -- 44
	{ Free = "emote_hop", Premium = "truck:blueberry:pulse" }, -- 45
	{ Free = "helmet:amber:metal", Premium = "helmet:pearl:twotone" }, -- 46
	{ Free = "title_pandapal", Premium = "hose:olive" }, -- 47
	{ Free = "hose:candy", Premium = "nozzle:crimson:sparkle" }, -- 48
	{ Free = "helmet:slate:plain", Premium = "truck:pumpkin" }, -- 49
	{ Free = "paint_silver", Premium = "paint_gold" }, -- 50
	{ Free = "title_hydranthero", Premium = "helmet:lilac:neon" }, -- 51
	{ Free = "truck:seafoam", Premium = "hose:plum" }, -- 52
	{ Free = "hose:navy", Premium = "truck:charcoal" }, -- 53
	{ Free = "helmet:tangerine:twotone", Premium = "boost_5j" }, -- 54
	{ Free = "title_roadruler", Premium = "title_foammaster" }, -- 55
	{ Free = "truck:sand:pulse", Premium = "helmet:cobalt:sparkle" }, -- 56
	{ Free = "boost_5g", Premium = "hose:bronze" }, -- 57
	{ Free = "hose:copper", Premium = "truck:rust:pulse" }, -- 58
	{ Free = "helmet:jade:metal", Premium = "helmet:crimson:metal" }, -- 59
	{ Free = "title_heatseeker", Premium = "emote_tornado" }, -- 60
	{ Free = "nozzle:candy", Premium = "nozzle:copper:sparkle" }, -- 61
	{ Free = "helmet:galaxy:plain", Premium = "helmet:arctic:twotone" }, -- 62
	{ Free = "title_squadleader", Premium = "truck:electric" }, -- 63
	{ Free = "hose:silver", Premium = "hose:obsidian" }, -- 64
	{ Free = "emote_cheer", Premium = "helmet:sunset:neon" }, -- 65
	{ Free = "truck:firefly", Premium = "truck:marshmallow" }, -- 66
	{ Free = "helmet:candy:twotone", Premium = "title_splashchamp" }, -- 67
	{ Free = "title_nightwatch", Premium = "hose:blossom" }, -- 68
	{ Free = "hose:honey", Premium = "helmet:olive:sparkle" }, -- 69
	{ Free = "truck:royal", Premium = "paint_galaxy" }, -- 70
	{ Free = "helmet:navy:metal", Premium = "truck:flamingo:pulse" }, -- 71
	{ Free = "title_fearless", Premium = "nozzle:honey:sparkle" }, -- 72
	{ Free = "hose:aqua", Premium = "hose:watermelon" }, -- 73
	{ Free = "helmet:plum:plain", Premium = "helmet:copper:metal" }, -- 74
	{ Free = "helmet_hero", Premium = "helmet_diamond" }, -- 75
	{ Free = "title_firestorm", Premium = "truck:storm" }, -- 76
	{ Free = "nozzle:blueberry:sparkle", Premium = "helmet:bronze:twotone" }, -- 77
	{ Free = "truck:volcano:pulse", Premium = "hose:blueberry" }, -- 78
	{ Free = "hose:pumpkin", Premium = "truck:mint" }, -- 79
	{ Free = "helmet:silver:twotone", Premium = "helmet:obsidian:neon" }, -- 80
	{ Free = "title_bravest", Premium = "title_waterwizard" }, -- 81
	{ Free = "hose:seafoam", Premium = "hose:charcoal" }, -- 82
	{ Free = "boost_5h", Premium = "nozzle:sand:sparkle" }, -- 83
	{ Free = "truck:coral", Premium = "helmet:blossom:sparkle" }, -- 84
	{ Free = "helmet:honey:metal", Premium = "emote_superjump" }, -- 85
	{ Free = "title_hotshot", Premium = "truck:grape:pulse" }, -- 86
	{ Free = "hose:sand", Premium = "helmet:aqua:metal" }, -- 87
	{ Free = "helmet:watermelon:plain", Premium = "hose:rust" }, -- 88
	{ Free = "title_lifesaver", Premium = "truck:lemon" }, -- 89
	{ Free = "truck:cocoa", Premium = "paint_inferno" }, -- 90
	{ Free = "nozzle:marshmallow", Premium = "helmet:blueberry:twotone" }, -- 91
	{ Free = "hose:firefly", Premium = "hose:electric" }, -- 92
	{ Free = "helmet:pumpkin:twotone", Premium = "truck:berry" }, -- 93
	{ Free = "title_blockguardian", Premium = "title_flametamer" }, -- 94
	{ Free = "emote_twirl", Premium = "nozzle:volcano:sparkle" }, -- 95
	{ Free = "truck:sky:pulse", Premium = "helmet:seafoam:neon" }, -- 96
	{ Free = "hose:marshmallow", Premium = "hose:royal" }, -- 97
	{ Free = "helmet:charcoal:metal", Premium = "truck:forest:pulse" }, -- 98
	{ Free = "title_stationhero", Premium = "helmet:sand:sparkle" }, -- 99
	{ Free = "title_legendary", Premium = "helmet_legend" }, -- 100
}

-- expand the variant codes into Rewards (ids like "helmet_mint")
for _, row in Tiers do
	for _, key in { "Free", "Premium" } do
		local code = (row :: any)[key]
		if string.find(code, ":", 1, true) then
			local id, def = PassRules.variant(code, Palette)
			assert(id and def, `BattlePassConfig: bad variant code {code}`)
			assert(Rewards[id] == nil, `BattlePassConfig: {id} defined twice`)
			Rewards[id] = def
			;(row :: any)[key] = id
		end
	end
end

-- curve 2 (Oct 2026): 100 for the original 20 tiers, then a smooth ramp to 1500 at tier 100 (57,410 XP)
local XpCurveV2: { number } = {}
for t = 1, 100 do
	XpCurveV2[t] = if t <= 20 then 100 else math.floor((100 + 1400 * ((t - 20) / 80) ^ 1.4) / 10 + 0.5) * 10
end

-- curve 3 (current, ~4x harder): 150 XP for tier 1 ramping steeply to 6000 XP for tier 100.
-- Totals: tier 10 = 1,990 · 25 = 9,660 · 50 = 44,270 · 75 = 117,640 · 100 = 240,700 XP.
local XpCurve: { number } = {}
for t = 1, 100 do
	XpCurve[t] = math.floor((150 + 5850 * ((t - 1) / 99) ^ 1.6) / 10 + 0.5) * 10
end

return Config.define({
	SeasonId = "S1",
	SeasonName = "SEASON 1: HOT START",
	SeasonEndsAt = 1796083200, -- 2026-12-01 00:00 UTC (unix seconds); the panel counts down to it
	MaxTier = 100,
	XpPerTier = 100, -- curve 1 (the original 20 x 100) and the fallback when XpCurve is missing
	XpCurve = XpCurve,
	CurveVersion = 3,
	-- older curves by version, for PassRules.migrateCurve (a pass with no `curve` was earned under 1)
	CurveHistory = {
		[1] = { perTier = 100, maxTier = 20 },
		[2] = { perTier = 100, maxTier = 100, needs = XpCurveV2 },
	},
	Milestones = { 25, 50, 75, 100 }, -- the panel's gold columns + page markers
	PageSize = 10, -- tiers per page in the REWARDS tab
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
