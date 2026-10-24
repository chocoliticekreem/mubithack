--!strict
-- MissionCatalog [owner: G3]. DATA ONLY: every mission from the trailer (docs/game/01 §0.1, §14).
-- Each entry has the shape Types.MissionDef (ReplicatedStorage/Shared/Types.luau). Pure Luau: no
-- requires, no Roblox APIs, so game/tests/mission_catalog.spec.luau can load it with the `luau` CLI.
-- Readers: LobbyService / LobbyController (Mission Board), MissionService:StartMission,
-- AtmosphereService:ApplyMission. A mission stays `enabled = false` until the MapService builder for
-- its `locationId` exists; flipping it on is a one-line PR by the lane that ships the builder.
-- v2: every mission is enabled; each one has IncidentSites in the city (CityConfig.KindMissions,
-- Districts). nightclub_fire / skyscraper_fire are city-only calls (their locationId has no standalone
-- builder; the sites are BlockFiller "nightclub" / "skyscraper" lots).
-- v2 dispatch: a mission runs at any IncidentSite whose MissionTypes attr lists its id; `call` is the
-- dispatch line ("DISPATCH: House fire at 12 Maple St"), `seconds` is the on-scene timer (MissionService
-- adds a driving allowance on top).

local Missions = {
	{
		id = "house_fire",
		title = "12 Maple Street",
		call = "House fire", -- v2 dispatch: "DISPATCH: <call> at <address>"
		blurb = "A kitchen fire on a sunset street. Two neighbours, a cat, a dog, and a confused panda.",
		locationId = "Town",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 180,
		atmosphere = "DuskSuburb",
		objectives = {
			{ kind = "extinguish", text = "Put out every fire" },
			{ kind = "rescue", count = 5, text = "Carry everyone to truck 67" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 2 },
			{ kind = "Cat", count = 1 },
			{ kind = "Dog", count = 1 },
			{ kind = "Panda", count = 1 },
		},
		hazards = {},
		tools = {},
		stars = {
			{ id = "allRescued", text = "Everyone delivered" },
			{ id = "allOut", text = "Every fire out" },
			{ id = "buildingSaved", text = "Save the house", min = 50 },
		},
	},
	{
		id = "apartment_trampoline",
		title = "Night Apartment",
		call = "Apartment fire",
		blurb = "Three floors of brick and bad wiring. Jumpers at the windows: hold the trampoline together.",
		locationId = "Apartment",
		enabled = true,
		players = { min = 1, max = 8 }, -- best with 2+ (the trampoline needs two holders); solo still rolls out
		seconds = 240,
		atmosphere = "NightStreet",
		objectives = {
			{ kind = "extinguish", text = "Put out every fire" },
			{ kind = "rescue", count = 5, text = "Catch the jumpers, carry the rest out" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 2, variant = "Jumper" },
			{ kind = "Civilian", count = 2 },
			{ kind = "Cat", count = 1, variant = "Windowsill" },
		},
		hazards = { "electrocution" }, -- fuse box in the basement laundry
		tools = { "Trampoline" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Nobody hit the pavement" },
			{ id = "noDowns", text = "Nobody got zapped" },
		},
	},
	{
		id = "school_alarm",
		title = "School Alarm",
		call = "School fire",
		blurb = "A kid pulled the alarm. This time it's real: smoke in the halls and a chem lab ready to pop.",
		locationId = "School",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 240,
		atmosphere = "DuskSuburb",
		objectives = {
			{ kind = "rescue", count = 9, text = "Get every kid and the teacher out" },
			{ kind = "extinguish", text = "Put out every fire" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 8, variant = "Kid" },
			{ kind = "Civilian", count = 1, variant = "Teacher" },
		},
		hazards = { "explosion" }, -- chem lab gas tank
		tools = {},
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Full attendance" },
			{ id = "underTime", text = "Out before the bell", seconds = 150 },
		},
	},
	{
		id = "farm_haystack",
		title = "Haystack Farm",
		call = "Barn fire",
		blurb = "The farmer is smoking next to the hay again. Slap the cigarette out before it all goes up.",
		locationId = "Farm",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 200,
		atmosphere = "FireGlow",
		objectives = {
			{ kind = "custom", text = "Slap the cigarette out of the farmer's hand" },
			{ kind = "extinguish", text = "Save the hay" },
			{ kind = "rescue", count = 2, text = "Get the farmer and his dog clear" },
		},
		fires = { count = 3, starts = "Scripted" }, -- the cigarette relights hay until confiscated
		rescues = {
			{ kind = "Civilian", count = 1, variant = "Farmer" },
			{ kind = "Dog", count = 1 },
		},
		hazards = { "cigarette" },
		tools = { "Slap" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allOut", text = "Not one bale lost" },
			{ id = "allRescued", text = "Farmer and dog safe" },
		},
	},
	{
		id = "forest_walkie",
		title = "Forest Wildfire",
		call = "Wildfire",
		blurb = "A campfire got away. No minimap out here: the walkie is how you find the campers.",
		locationId = "Forest",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 240,
		atmosphere = "FireGlow",
		objectives = {
			{ kind = "rescue", count = 3, text = "Find the campers and the lost dog" },
			{ kind = "survive", text = "Hold the fire line" },
		},
		fires = { count = 5, starts = "Scripted" }, -- spreads from the RV campsite
		rescues = {
			{ kind = "Civilian", count = 2, variant = "Camper" },
			{ kind = "Dog", count = 1 },
		},
		hazards = {},
		tools = { "Walkie" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Nobody left in the woods" },
			{ id = "noDowns", text = "Nobody got lost" },
		},
	},
	{
		id = "storage_fusebox",
		title = "Storage Units",
		call = "Storage unit fire",
		blurb = "Burst pipes, a burning unit, and a fuse box right above the puddle. Cut the power first.",
		locationId = "Storage",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 180,
		atmosphere = "NightStreet",
		objectives = {
			{ kind = "custom", text = "Cut the power at the fuse box" },
			{ kind = "extinguish", text = "Put out every fire" },
			{ kind = "rescue", count = 2, text = "Get the night guard and his dog out" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 1, variant = "Guard" },
			{ kind = "Dog", count = 1 },
		},
		hazards = { "electrocution" },
		tools = {},
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allOut", text = "Every fire out" },
			{ id = "noDowns", text = "Nobody got shocked" },
		},
	},
	{
		id = "tornado_field",
		title = "Fire Tornado",
		call = "Field fire",
		blurb = "The field fire got big enough to spin. Hose it down before it eats the truck.",
		locationId = "Field",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 180,
		atmosphere = "FireGlow",
		objectives = {
			{ kind = "custom", text = "Kill the fire tornado with water" },
			{ kind = "extinguish", text = "Put out the field" },
		},
		fires = { count = 6, starts = "Random" },
		rescues = {
			{ kind = "Civilian", count = 1, variant = "Farmer" },
		},
		hazards = { "fire_tornado" },
		tools = {},
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allOut", text = "Field saved" },
			{ id = "noDowns", text = "Nobody got flung" },
		},
	},
	{
		id = "dam_finale",
		title = "Dam Finale",
		call = "City-wide fire",
		blurb = "The city is too big to put out. Move everyone to high ground, plant the charges, press the button.",
		locationId = "Dam",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 300,
		atmosphere = "FireGlow",
		objectives = {
			{ kind = "rescue", count = 6, text = "Move civilians to high ground" },
			{ kind = "custom", text = "Plant 3 charges on the dam and detonate" },
		},
		fires = { count = 12, starts = "Random" },
		rescues = {
			{ kind = "Civilian", count = 6 },
		},
		hazards = { "explosion", "tidal_wave" },
		tools = { "Detonator" },
		stars = {
			{ id = "finish", text = "The city is out" },
			{ id = "allRescued", text = "Nobody in the flood path" },
			{ id = "underTime", text = "Blown in time", seconds = 240 },
		},
	},
	{
		id = "panda_zoo",
		title = "Panda Zoo",
		call = "Zoo fire",
		blurb = "The bamboo is burning and the panda will not walk. It takes two to carry a panda.",
		locationId = "Zoo",
		enabled = true,
		players = { min = 1, max = 8 }, -- best with 2+ (the panda is a 2-carrier); solo still rolls out
		seconds = 180,
		atmosphere = "DuskSuburb",
		objectives = {
			{ kind = "rescue", count = 3, text = "Carry the panda and the keepers out" },
			{ kind = "extinguish", text = "Save the enclosure" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Panda", count = 1 },
			{ kind = "Civilian", count = 2, variant = "Keeper" },
		},
		hazards = {},
		tools = {},
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Panda safe" },
			{ id = "allOut", text = "Bamboo saved" },
		},
	},
	{
		id = "nightclub_fire",
		title = "Club Inferno",
		call = "Nightclub fire",
		blurb = "The fog machine was a flamethrower. The DJ won't stop the set and the dance floor is packed.",
		locationId = "Nightclub",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 210,
		atmosphere = "NightStreet",
		objectives = {
			{ kind = "rescue", count = 8, text = "Get every partygoer and the DJ out" },
			{ kind = "extinguish", text = "Put out every fire" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 6, variant = "Partygoer" },
			{ kind = "Civilian", count = 1, variant = "DJ" },
			{ kind = "Dog", count = 1 },
		},
		hazards = { "explosion" }, -- the fog machine's gas bottle
		tools = {},
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Nobody left on the dance floor" },
			{ id = "underTime", text = "Out before the drop", seconds = 150 },
		},
	},
	{
		id = "skyscraper_fire",
		title = "Sky Tower",
		call = "High-rise fire",
		blurb = "Fire on the upper floors and the roof of the tallest tower downtown. Ladder the low windows, take the stairs all the way up.",
		locationId = "Skyscraper",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 300,
		atmosphere = "NightStreet",
		objectives = {
			{ kind = "rescue", count = 7, text = "Reach everyone trapped up high (one is on the roof)" },
			{ kind = "extinguish", text = "Put out the upper floors" },
		},
		fires = { count = 6, starts = "FireStart" }, -- the roof crate stack always burns (FireStart Priority)
		rescues = {
			{ kind = "Civilian", count = 6, variant = "Office" },
			{ kind = "Cat", count = 1, variant = "Windowsill" },
		},
		hazards = {},
		tools = { "Ladder" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Everyone down safe" },
			{ id = "noDowns", text = "Nobody fell" },
		},
	},
	-- v3 "crazy calls" (HazardService twists, Lib/Hazard/Twists): each has a twist mechanic and a `guide`
	-- ({ headline, steps }) the MissionGuide lane can show. City-only: their locationId has no standalone
	-- builder; they run at the IncidentSites in CityConfig.KindMissions (diner, gas, reststop, house).
	{
		id = "diner_grease",
		title = "Greasy Spoon",
		call = "Grease fire",
		blurb = "The deep fryer at the diner is on fire. Whatever you do, do NOT hose it.",
		locationId = "Diner",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 180,
		atmosphere = "NightStreet",
		objectives = {
			{ kind = "custom", text = "Smother the deep fryer (extinguisher or the lid, NOT water)" },
			{ kind = "extinguish", text = "Put out every fire" },
			{ kind = "rescue", count = 3, text = "Get the cook and the customers out" },
		},
		fires = { count = 3, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 1, variant = "Cook" },
			{ kind = "Civilian", count = 2, variant = "Customer" },
		},
		hazards = { "grease_fire" },
		tools = { "Extinguisher" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allOut", text = "Kitchen saved" },
			{ id = "noDowns", text = "Nobody got deep-fried" },
		},
		guide = {
			headline = "Water on a grease fire EXPLODES. Smother it instead.",
			steps = {
				"Grab the extinguisher from the truck compartment.",
				"Spray the burning deep fryer with the extinguisher, or walk up and hold E to slam the lid on it.",
				"Hose the fryer and it flares up in a fireball that lights the kitchen.",
				"Then hose the rest of the diner and carry the cook and the customers out.",
			},
		},
	},
	{
		id = "gas_leak",
		title = "Pump Panic",
		call = "Gas leak",
		blurb = "The pumps are spraying fuel and a tanker is parked right next to them. Shut the valves before it blows.",
		locationId = "GasStation",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 200,
		atmosphere = "DuskSuburb",
		objectives = {
			{ kind = "custom", text = "Shut every leaking pump valve before the tanker blows" },
			{ kind = "extinguish", text = "Put out every fire" },
			{ kind = "rescue", count = 3, text = "Get the clerk and the drivers clear" },
		},
		fires = { count = 3, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 1, variant = "Clerk" },
			{ kind = "Civilian", count = 1, variant = "Driver" },
			{ kind = "Dog", count = 1 },
		},
		hazards = { "gas_leak" },
		tools = {},
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allOut", text = "Station saved" },
			{ id = "noDowns", text = "Nobody went up with the tanker" },
		},
		guide = {
			headline = "Leaking pumps plus a tanker equals a countdown. Shut the valves!",
			steps = {
				"When you arrive a countdown starts over the tanker.",
				"Stand at each leaking pump and hold E on its red valve wheel to shut it. Split up: one pump each.",
				"Every valve shut before zero means the tanker is safe. Miss one and it explodes and lights the forecourt.",
				"Then put out the fires and get the clerk, the driver and the dog out.",
			},
		},
	},
	{
		id = "highway_pileup",
		title = "Pile-up on 67",
		call = "Highway pile-up",
		blurb = "A pile-up at the Highway 67 rest stop. Cars are burning, and the drivers are stuck behind crumpled doors.",
		locationId = "Highway",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 210,
		atmosphere = "DuskSuburb",
		objectives = {
			{ kind = "custom", text = "Pry the jammed doors open (Halligan, crowbar or axe)" },
			{ kind = "rescue", count = 3, text = "Carry the drivers to the truck" },
			{ kind = "extinguish", text = "Put out the burning cars" },
		},
		fires = { count = 4, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 3, variant = "Driver" },
		},
		hazards = { "pileup" },
		tools = { "Halligan" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Every driver out" },
			{ id = "underTime", text = "Cleared before rush hour", seconds = 150 },
		},
		guide = {
			headline = "The drivers are pinned. Pry the doors, then carry them out.",
			steps = {
				"Hold a pry tool in your hand: the Halligan or crowbar from the station rack, or your axe.",
				"Walk up to a crumpled car's door and hold E to pry it off.",
				"With the door gone you can pick the driver up and carry them to the truck.",
				"Hose down the burning cars at the other end of the lay-by.",
			},
		},
	},
	{
		id = "cat_tree",
		title = "Purr-ty Big Problem",
		call = "Cat up a tree",
		blurb = "A candle fire inside, and the cat that knocked it over is up the tree out front, making puns.",
		locationId = "Town",
		enabled = true,
		players = { min = 1, max = 8 },
		seconds = 180,
		atmosphere = "DuskSuburb",
		objectives = {
			{ kind = "rescue", count = 2, text = "Ladder the tree, get the cat down, get the owner out" },
			{ kind = "extinguish", text = "Put out the candle fire" },
		},
		fires = { count = 2, starts = "FireStart" },
		rescues = {
			{ kind = "Civilian", count = 1, variant = "Owner" },
		},
		hazards = { "cat_tree" },
		tools = { "Ladder" },
		stars = {
			{ id = "finish", text = "Finish the shift" },
			{ id = "allRescued", text = "Cat and owner safe" },
			{ id = "noDowns", text = "Nobody fell out of the tree" },
		},
		guide = {
			headline = "The cat is up the tree. Ladder up, grab it, come down (or yeet it gently).",
			steps = {
				"Equip the Ladder, walk up to the tree trunk and click to stand it against the trunk.",
				"Climb up to the branch, pick up the cat, then climb down or throw it to a teammate.",
				"Do not hose the cat. Cats hate water, and it will tell you so.",
				"Put out the candle fire inside and carry the owner out.",
			},
		},
	},
}

return Missions
