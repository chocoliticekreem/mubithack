--!strict
-- TwistConfig [owner: Twists]. One twist per call so every call feels different (Tizyz rule #4, docs/research/
-- marketing/tizyz-5-viral-applied.md). TwistService rolls it at dispatch (never on a rookie call), the
-- TwistController card says it in 3-4 kid words with an icon, and it plays through systems that already
-- exist (EventService crazy events, HazardService's cat tree, AtmosphereService's per-player look).
-- Read at use time, so DevHook ".Set" live-tuning works:
--   ServerStorage.DevHook:Invoke("TwistConfig", ".Set", "Enabled", false)
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	-- odds: weight / sum of weights (6 x 1 = 1 in 6 each). 0 = off. A squad never gets the same twist twice
	-- in a row (one re-roll), and a call that already has a built-in twist (MissionCatalog hazards
	-- grease_fire / gas_leak / pileup / cat_tree) announces that one instead of rolling.
	Weights = {
		cat = 1,
		windy = 1,
		rainy = 1,
		night = 1,
		news = 1,
		raccoon = 1,
	},
	-- what the card says (icon + title + one short "what to do" line). Same icon = same twist everywhere.
	Defs = {
		cat = { icon = "🐱", title = "CAT IN A TREE!", hint = "Bonus: ladder up and grab it" },
		windy = { icon = "💨", title = "WINDY DAY!", hint = "Fire jumps with the wind" },
		rainy = { icon = "🌧", title = "RAINY DAY!", hint = "Rain helps you, spray fast" },
		night = { icon = "🌙", title = "NIGHT CALL!", hint = "It's dark. Your light is on" },
		news = { icon = "📺", title = "TV CREW IS HERE!", hint = "Be fast for bonus XP" },
		raccoon = { icon = "🦝", title = "SNEAKY RACCOON!", hint = "Hold on to your hose" },
		-- built-in mission twists (announced, not rolled)
		grease_fire = { icon = "🍳", title = "KITCHEN FIRE!", hint = "No water on the fryer" },
		gas_leak = { icon = "⛽", title = "GAS LEAK!", hint = "Shut the valves fast" },
		pileup = { icon = "🚗", title = "CAR CRASH!", hint = "Pry the doors open" },
		cat_tree = { icon = "🐱", title = "CAT IN A TREE!", hint = "Ladder up and grab it" },
	},
	BuiltIn = { "grease_fire", "gas_leak", "pileup", "cat_tree" },
	-- the crazy event behind a twist (EventService:Force), first after arrival, then again every N s
	Events = {
		windy = { event = "wind_gust", first = 10, every = 45 },
		rainy = { event = "rainstorm", first = 6, every = 35 },
		news = { event = "news_heli", first = 4, every = 50 },
		raccoon = { event = "raccoon", first = 20, every = 55 },
	},
	RetrySeconds = 8, -- an event that can't run yet (raccoon with no hose out) tries again this soon
	NightPreset = "NightStreet", -- AtmosphereConfig preset for NIGHT CALL (per player, cleared after)
	NewsParSeconds = 240, -- TV CREW: an all-clear at or under this many seconds gives NewsBonusXp each
	NewsBonusXp = 50,
	CardSeconds = 6, -- how long the twist card stays up (at dispatch, and again on arrival)
})
