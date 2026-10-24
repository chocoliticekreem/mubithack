--!strict
-- MissionGuides [owner: Onboarding]. DATA ONLY (pure Luau, no requires) so game/tests can load it.
-- The first time you play a mission type, MissionGuideController walks you through its special
-- mechanic, step by step: a card (head + sub), an arrow + highlight on a world target, and a
-- completion condition it watches. After that you only get the one-line `tip` at dispatch.
-- If ANYONE in the squad is new to the mission, everyone gets the guide (the veteran helps).
-- Server half: Services/MissionGuideService (profile flag guides.seen). Step logic: Lib/Onboarding/GuideFlow.
--
-- A mission = { tip: string, steps: { Step | string } }. A string step is a Common step by name; a
-- table with `use = "<common>"` is a Common step with those fields overridden.
-- Step = {
--   id: string, head: string, sub: string,
--   target: Target?,       -- what the arrow points at (nil / { kind = "none" } = no arrow)
--   done: Done,            -- when the step counts as done
--   optional: boolean?,    -- skip the step if its target can't be found (this site has no fuse box...)
--   maxSeconds: number?,   -- move on anyway after this long (mechanics that can stall: solo panda)
-- }
-- Target kinds (all scoped to YOUR run: its IncidentSite, its rescues, your truck):
--   { kind = "truck", tag = "TruckRefill" | "RescueDropoff" }            -- a tagged part on your truck
--   { kind = "tag", tag, attr?, value?, notValue?, prompt? }             -- nearest tagged part in the site
--        (attr/value filter; notValue = skip parts whose attr already equals it; prompt = needs a ProximityPrompt)
--   { kind = "rescue", rescueKind?, highest? }                           -- nearest (or highest) rescue still to save
--   { kind = "burning", highest? }                                       -- nearest (or highest) fire at the site
--   { kind = "named", name }                                             -- a descendant of the site by name
-- Done kinds:
--   { kind = "hand", item }                 -- your hand slot holds this item (InvHand)
--   { kind = "attr", tag, attr, value }     -- every `tag` part in the site has attr == value
--   { kind = "carrying", rescueKind? }      -- you are carrying someone (Player attr Carrying)
--   { kind = "rescued" }                    -- one more of the run's rescues reached a truck
--   { kind = "fireOut" }                    -- one fire at the site went out (or none are left)
--   { kind = "slapped", rescueKind? }       -- that rescue got slapped (attr Slapped) or picked up
--   { kind = "pair", rescueKind }           -- two players are carrying it (or it's already saved)
--   { kind = "near", studs }                -- you're within `studs` of the target
--   { kind = "prompt" }                     -- you used a ProximityPrompt on the target
--   { kind = "appeared" }                   -- the target exists (wait for the fire tornado)
--   { kind = "gone" }                       -- the target was there and now isn't
--   { kind = "hazard", hazardId }           -- a Hazard/Fx of that id fired (the dam wave)
--   { kind = "seconds" }                    -- informational: done after maxSeconds
return {
	SkipKey = "J", -- skip the whole guide (or click SKIP on the card)
	TipSeconds = 9, -- the returning-player tip card at dispatch
	GraceSeconds = 4, -- an optional step whose target never shows up is skipped after this
	DoneFlashSeconds = 0.9, -- the "NICE!" tick between steps
	ArrowHeight = 4.5,
	ArrowBob = 0.6,
	HighlightColor = "#5BE0FF", -- guide highlight (the station tutorial is yellow; this is a calmer cyan)
	ChipNew = "NEW CALL",
	RookieLine = "Rookie on the call: {names}. Show them how!",

	Common = {
		hose = {
			id = "hose",
			head = "GRAB THE HOSE",
			sub = "The reel on your truck. Press E. It's a leash, not a lasso.",
			target = { kind = "truck", tag = "TruckRefill" },
			done = { kind = "hand", item = "Hose" },
			maxSeconds = 60,
		},
		spray = {
			id = "spray",
			head = "SPRAY THE BASE",
			sub = "Aim low and hold click. Flames hate wet feet.",
			target = { kind = "burning" },
			done = { kind = "fireOut" },
			maxSeconds = 60,
		},
		carry = {
			id = "carry",
			head = "PICK SOMEONE UP",
			sub = "Walk up to them and press E. Gently. Ish.",
			target = { kind = "rescue" },
			done = { kind = "carrying" },
			optional = true,
			maxSeconds = 75,
		},
		deliver = {
			id = "deliver",
			head = "DROP THEM AT THE TRUCK",
			sub = "Walk into the glowing drop zone. Yeeting (hold Q) also counts. Probably.",
			target = { kind = "truck", tag = "RescueDropoff" },
			done = { kind = "rescued" },
			maxSeconds = 75,
		},
	},

	Missions = {
		house_fire = {
			tip = "Spray the BASE of the flames, then carry everyone to the truck.",
			steps = {
				"hose",
				"spray",
				{ use = "carry", sub = "Neighbours, a cat, a dog... E to pick up. The panda needs TWO of you." },
				"deliver",
			},
		},
		apartment_trampoline = {
			tip = "Kill the basement power before you splash around. The jumpers are up top.",
			steps = {
				{
					id = "fuse",
					head = "KILL THE BASEMENT POWER",
					sub = "Fuse box by the laundry puddle. Hold E on it. Dry feet only!",
					target = { kind = "tag", tag = "FuseBox" },
					done = { kind = "attr", tag = "FuseBox", attr = "Power", value = false },
					optional = true,
					maxSeconds = 70,
				},
				{
					use = "carry",
					id = "jumper",
					head = "JUMPERS ON THE TOP FLOOR",
					sub = "Take the stairs (or stand a ladder) and grab them before they get ideas.",
					target = { kind = "rescue", highest = true },
				},
				"deliver",
			},
		},
		school_alarm = {
			tip = "Nine to rescue: kids first, then the teacher. Out before the bell!",
			steps = {
				{
					id = "alarm",
					head = "PULL THE FIRE ALARM",
					sub = "The red box in the hallway. Make it official. Press E.",
					target = { kind = "tag", tag = "FireAlarm", prompt = true },
					done = { kind = "prompt" },
					optional = true,
					maxSeconds = 40,
				},
				{ use = "carry", id = "kid", head = "GRAB A KID", sub = "They're small and fast. E to scoop one up." },
				{ use = "deliver", head = "HEADCOUNT AT THE TRUCK", sub = "Drop them in the glowing zone. Eight more to go. No pressure." },
			},
		},
		farm_haystack = {
			tip = "Slap the farmer's cigarette first, or he'll keep relighting the hay.",
			steps = {
				{
					id = "slap",
					head = "SLAP THE CIGARETTE OUT",
					sub = "Empty hands, click to swing at the farmer. Fire safety is a contact sport.",
					target = { kind = "rescue", rescueKind = "Civilian" },
					done = { kind = "slapped", rescueKind = "Civilian" },
					optional = true,
					maxSeconds = 75,
				},
				"hose",
				{ use = "spray", head = "SAVE THE HAY", sub = "Hose every burning bale. Hay is basically kindling with ambition." },
				{ use = "carry", sub = "The farmer and his dog. E to pick up, then the truck." },
				"deliver",
			},
		},
		forest_walkie = {
			tip = "The campers are deep in the trees. Start at the RV camp and listen for the walkie.",
			steps = {
				{
					id = "camp",
					head = "HEAD FOR THE RV CAMP",
					sub = "Follow the smoke. The walkie by the campfire knows things.",
					target = { kind = "named", name = "WalkieTalkie" },
					done = { kind = "near", studs = 30 },
					optional = true,
					maxSeconds = 90,
				},
				{ use = "carry", id = "campers", head = "FIND THE CAMPERS", sub = "Lost campers and one very good dog. E to pick up." },
				"deliver",
				{ use = "spray", head = "HOLD THE FIRE LINE", sub = "Knock the fire down before it reaches the trees by the road." },
			},
		},
		storage_fusebox = {
			tip = "Power OFF at the fuse box before anyone steps in the puddles.",
			steps = {
				{
					id = "fuse",
					head = "CUT THE POWER FIRST",
					sub = "Fuse box on the wall. Hold E. Do NOT stand in the puddle while you do it.",
					target = { kind = "tag", tag = "FuseBox" },
					done = { kind = "attr", tag = "FuseBox", attr = "Power", value = false },
					optional = true,
					maxSeconds = 90,
				},
				{ use = "hose", sub = "Puddles are safe now. Grab the hose off your truck's reel (E)." },
				{ use = "spray", sub = "Hit the burning unit low. Water + no electricity = hero." },
				{ use = "carry", sub = "The night guard and his dog. E to pick them up." },
				"deliver",
			},
		},
		tornado_field = {
			tip = "A fire tornado spins up after a bit. Keep your distance and keep spraying.",
			steps = {
				"hose",
				{ use = "spray", head = "PUT OUT THE FIELD", sub = "Start with the fires nearest the truck." },
				{
					id = "tornado",
					head = "FIRE TORNADO INCOMING",
					sub = "Yes, really. It chases people and flings them. Don't be people.",
					target = { kind = "named", name = "FireTornado" },
					done = { kind = "appeared" },
					maxSeconds = 45,
				},
				{
					id = "dodge",
					head = "OUTRUN IT",
					sub = "Keep away until it fizzles out, then mop up what it lit.",
					target = { kind = "named", name = "FireTornado" },
					done = { kind = "gone" },
					optional = true,
					maxSeconds = 50,
				},
			},
		},
		dam_finale = {
			tip = "Get everyone up to the truck on high ground, then hit the plunger on the dam.",
			steps = {
				{ use = "carry", head = "MOVE PEOPLE TO HIGH GROUND", sub = "The city below is toast. Carry folks up (E)." },
				{ use = "deliver", head = "UP TO THE TRUCK", sub = "Your truck is on the plateau. Drop them there: that's high ground." },
				{
					id = "charges",
					head = "PLANT THE CHARGES",
					sub = "Three plates on the dam deck. One charge each.",
					target = { kind = "tag", tag = "DetonatorSocket", attr = "Filled", notValue = true, prompt = true },
					done = { kind = "attr", tag = "DetonatorSocket", attr = "Filled", value = true },
					optional = true, -- only once the plates take charges (prompt)
					maxSeconds = 120,
				},
				{
					id = "plunger",
					head = "PRESS THE BIG RED PLUNGER",
					sub = "On the dam crown. Hold E. Then run. Seriously, run.",
					target = { kind = "tag", tag = "Detonator" },
					done = { kind = "hazard", hazardId = "tidal_wave" },
					optional = true,
					maxSeconds = 150,
				},
			},
		},
		panda_zoo = {
			tip = "The panda is a two-person lift: both press E on it, then waddle to the truck.",
			steps = {
				{
					id = "panda",
					head = "THE PANDA NEEDS TWO",
					sub = "Both of you press E on the panda. Solo? Save the keepers and look sad.",
					target = { kind = "rescue", rescueKind = "Panda" },
					done = { kind = "pair", rescueKind = "Panda" },
					optional = true,
					maxSeconds = 45,
				},
				{ use = "deliver", head = "WADDLE IT TO THE TRUCK", sub = "Heavy panda, slow feet. Walk it into the drop zone together." },
				{ use = "carry", id = "keepers", head = "GRAB THE KEEPERS", sub = "Two zookeepers who refused to leave. E to pick up." },
				"deliver",
				"hose",
				{ use = "spray", head = "SAVE THE BAMBOO", sub = "The panda's lunch is on fire. Hose it." },
			},
		},
		nightclub_fire = {
			tip = "Hose anything burning near the fog machine, then herd the dancers out.",
			steps = {
				{
					id = "fog",
					head = "FOG MACHINE = BOMB",
					sub = "Its gas bottle blows if fire gets close. Find it, keep it wet.",
					target = { kind = "tag", tag = "Hazard", attr = "HazardId", value = "explosion" },
					done = { kind = "near", studs = 22 },
					optional = true,
					maxSeconds = 45,
				},
				"hose",
				{ use = "spray", sub = "Start with the flames near the DJ booth." },
				{ use = "carry", head = "GET THE DANCERS OUT", sub = "They won't stop dancing. Pick them up (E) mid-move." },
				"deliver",
			},
		},
		skyscraper_fire = {
			tip = "Stairs run up the left wall, all the way to the roof. Ladders reach floors 2-3.",
			steps = {
				{
					id = "climb",
					head = "UP THE STAIRS",
					sub = "Stairs zigzag up the left wall. Someone is waving on the roof.",
					target = { kind = "rescue", highest = true },
					done = { kind = "near", studs = 25 },
					optional = true,
					maxSeconds = 120,
				},
				{ use = "carry", sub = "E to pick them up. Yes, you have to walk them back down." },
				"deliver",
				{
					use = "spray",
					head = "THE ROOF IS ON FIRE",
					sub = "Drag the hose up (or grab the extinguisher). Let it burn is not a strategy.",
					target = { kind = "burning", highest = true },
				},
			},
		},
	},
}
