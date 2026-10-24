--!strict
-- EventConfig [owner: GF]. Random "crazy events" during any call (EventService). Read at use time, so
-- DevHook ".Set" live-tuning works: ServerStorage.DevHook:Invoke("EventConfig", ".Set", "Chance", 1)
local Config = require(script.Parent.Parent:WaitForChild("Shared"):WaitForChild("Config") :: ModuleScript)

return Config.define({
	Enabled = true,
	Chance = 0.7, -- per call: the odds that it gets a crazy event at all (calls run 4-7 minutes now)
	FirstAfter = { min = 40, max = 110 }, -- seconds after the squad arrives (RoundState Active)
	MaxPerMission = 2, -- a second one can follow 60 s after the first
	-- which events can roll, and how likely each one is (0 = off)
	Weights = {
		news_heli = 1,
		geyser_hydrant = 1,
		raccoon = 1,
		rainstorm = 1,
		wind_gust = 1,
		ice_cream = 1,
	},
	-- news helicopter: circles the site, spotlight + beam on one squad member (switches every few s)
	HeliSeconds = 40,
	HeliHeight = 70,
	HeliRadius = 45,
	HeliSwitchSeconds = 8,
	-- geyser hydrant: the site's hydrant erupts; launches whoever stands on it, waters fires nearby
	GeyserSeconds = 20,
	GeyserHeight = 45,
	GeyserLaunch = 95, -- studs/s up
	GeyserWaterRadius = 26,
	GeyserLitres = 3, -- per burning part per second within the radius (FireConfig.CoolPerLitre 9: ~4 s to out)
	-- raccoon: runs at a hose holder and steals the nozzle (InventoryService:StowHose puts it on the reel)
	RaccoonSpeed = 18,
	-- rainstorm: a cloud over the site; fires get cooled, players too
	RainSeconds = 25,
	RainLitres = 1, -- per burning part every RainEvery seconds (helps, never a free win)
	RainEvery = 2,
	RainCool = 8, -- heat removed from each squad member every RainEvery
	RainScripted = 0.6, -- scripted-fire hp removed every RainEvery (Lib/Hazard/Twists.douse)
	-- wind gusts: fire jumps downwind, players get shoved
	WindSeconds = 24,
	WindEvery = 3,
	WindSpreadPerTick = 3,
	WindPush = 28,
	-- ice-cream truck: drives up, parks by the apron; a sundae (prompt) and the cold aura cool heat
	IceCreamSeconds = 26,
	IceCreamPark = 12, -- seconds parked
	IceCreamCool = 60, -- heat removed by a sundae
	IceCreamAura = 18, -- studs: the cold aura
	IceCreamAuraCool = 6, -- heat removed per second in the aura
})
