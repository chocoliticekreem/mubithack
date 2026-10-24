--!strict
-- MissionCatalog [owner: G3]. DATA ONLY: every mission from the trailer (docs/game/01 §0.1, §14).
-- Each entry has the shape Types.MissionDef (ReplicatedStorage/Shared/Types.luau). Pure Luau: no
-- requires, no Roblox APIs, so game/tests/mission_catalog.spec.luau can load it with the `luau` CLI.
-- Readers: LobbyService / LobbyController (Mission Board), MissionService:StartMission,
-- AtmosphereService:ApplyMission. A mission stays `enabled = false` until the MapService builder for
-- its `locationId` exists; flipping it on is a one-line PR by the lane that ships the builder.
-- v1 ships house_fire only.
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
		fires = { count = 3, starts = "FireStart" },
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
		enabled = false,
		players = { min = 2, max = 8 }, -- the trampoline needs two holders
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
		enabled = false,
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
		enabled = false,
		players = { min = 1, max = 8 },
		seconds = 200,
		atmosphere = "FireGlow",
		objectives = {
			{ kind = "custom", text = "Slap the cigarette out of the farmer's hand" },
			{ kind = "extinguish", text = "Save the hay" },
			{ kind = "rescue", count = 2, text = "Get the farmer and his dog clear" },
		},
		fires = { count = 2, starts = "Scripted" }, -- the cigarette relights hay until confiscated
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
		enabled = false,
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
		enabled = false,
		players = { min = 1, max = 8 },
		seconds = 180,
		atmosphere = "NightStreet",
		objectives = {
			{ kind = "custom", text = "Cut the power at the fuse box" },
			{ kind = "extinguish", text = "Put out every fire" },
			{ kind = "rescue", count = 2, text = "Get the night guard and his dog out" },
		},
		fires = { count = 3, starts = "FireStart" },
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
		enabled = false,
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
		enabled = false,
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
		enabled = false,
		players = { min = 2, max = 8 }, -- the panda is a 2-carrier
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
}

return Missions
