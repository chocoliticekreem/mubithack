--!strict
-- Awards [owner: G3]. Pure Blame-award selection, stars and blame callout lines. No Roblox APIs, so the
-- `luau` CLI tests it (game/tests/awards.spec.luau). Sources: docs/game/05-content-missions.md §7,
-- docs/game/01-gameplay-systems.md §10.
--
--   Awards.build(stats: { PlayerStats }, maxPerPlayer: number): { Award }
--       Catalog in priority order (funny first). Each award goes to the player with the highest stat (>= its
--       minimum; ties -> lower helmet, then lower userId), skipping players who already hold maxPerPlayer.
--       Players left with nothing get "Somehow Competent" (did something, blamed for nothing) or
--       "Moral Support". The last entry is always the Scapegoat line (highest blameScore):
--       "Firefighter 0X is to blame." or, solo, "You are to blame.".
--   Awards.stars(burningAtEnd: number, rescued: number, trapped: number): number   -- 1..3
--   Awards.blameScore(s: PlayerStats): number
--   Awards.catalog(): { { id: string, title: string, blame: boolean } }            -- for tests / docs
--   Awards.callout(event: string, actor: number, victim: number?, roll: number?): string
--       Kill-feed line for a blame event ("hose" | "down" | "drop" | "door" | "zap" | "boom" | "overheat" |
--       "spread"). actor/victim are helmet numbers; roll (any integer) picks the variant deterministically.
--
-- Stats: the frozen Types.PlayerStats fields plus optional ledger extras (missing extras read as 0), so the
-- ledger can grow without a Types change: hosedBy, drops, cats, dogs, overheats, zapped, zappedOthers,
-- explosions, refills, revives, carrySeconds.

export type PlayerStats = {
	userId: number,
	helmet: number,
	name: string,
	firesOut: number,
	firesStarted: number,
	water: number,
	doors: number,
	rescued: number,
	pandas: number,
	downedOthers: number,
	timesDowned: number,
	teammateSprayed: number,
}
export type Award = { id: string, title: string, userId: number, value: number, blurb: string, blame: boolean }

type Entry = {
	id: string,
	title: string,
	blame: boolean,
	min: number,
	stat: string,
	blurb: (number) -> string,
}

local Awards = {}

local function num(s: any, field: string): number
	local v = s[field]
	return if type(v) == "number" then v else 0
end

local function plural(v: number, one: string, many: string): string
	return if v == 1 then one else many
end

-- Priority order: rare + funny first, "good job" awards last so the roasts show first.
local CATALOG: { Entry } = {
	{
		id = "panda",
		title = "Panda Whisperer",
		blame = false,
		min = 1,
		stat = "pandas",
		blurb = function(_v)
			return "Carried the panda to safety. It is still confused."
		end,
	},
	{
		id = "shocking",
		title = "Shocking Development",
		blame = true,
		min = 1,
		stat = "zappedOthers",
		blurb = function(v)
			return `Electrocuted {v} {plural(v, "teammate", "teammates")}. Hair is permanent now.`
		end,
	},
	{
		id = "kaboom",
		title = "Kaboom Club",
		blame = true,
		min = 1,
		stat = "explosions",
		blurb = function(v)
			return `Was nearest to {v} {plural(v, "explosion", "explosions")}. Coincidence.`
		end,
	},
	{
		id = "friendly_hose",
		title = "Friendly Fire Department",
		blame = true,
		min = 3,
		stat = "teammateSprayed",
		blurb = function(v)
			return `Hosed a teammate {v} times. On purpose, probably.`
		end,
	},
	{
		id = "arsonist",
		title = "Arsonist (Probably)",
		blame = true,
		min = 3,
		stat = "firesStarted",
		blurb = function(v)
			return `Was standing right there when {v} fires spread.`
		end,
	},
	{
		id = "hot_potato",
		title = "Hot Potato",
		blame = true,
		min = 2,
		stat = "drops",
		blurb = function(v)
			return `Dropped {v} people. They will remember this.`
		end,
	},
	{
		id = "cat",
		title = "Cat Got Your Hose",
		blame = false,
		min = 1,
		stat = "cats",
		blurb = function(_v)
			return "Saved the cat. The cat is not grateful."
		end,
	},
	{
		id = "human_torch",
		title = "Human Torch",
		blame = true,
		min = 1,
		stat = "overheats",
		blurb = function(v)
			return if v == 1 then "Overheated once. Smells like barbecue." else `Overheated {v} times. Fully grilled.`
		end,
	},
	{
		id = "crispy",
		title = "Crispy Critter",
		blame = true,
		min = 1,
		stat = "timesDowned",
		blurb = function(v)
			return if v == 1 then "Got toasted once. Medium rare." else `Got toasted {v} times. Well done.`
		end,
	},
	{
		id = "lightning_rod",
		title = "Lightning Rod",
		blame = false,
		min = 1,
		stat = "zapped",
		blurb = function(v)
			return `Got zapped {v} {plural(v, "time", "times")}. Now glows in the dark.`
		end,
	},
	{
		id = "car_wash",
		title = "Human Car Wash",
		blame = false,
		min = 3,
		stat = "hosedBy",
		blurb = function(v)
			return `Got hosed by the team {v} times. Extremely hydrated.`
		end,
	},
	{
		id = "door_hater",
		title = "Door Hater",
		blame = true,
		min = 2,
		stat = "doors",
		blurb = function(v)
			return `Broke {v} doors. Some were even locked.`
		end,
	},
	{
		id = "good_boy",
		title = "Good Boy Express",
		blame = false,
		min = 1,
		stat = "dogs",
		blurb = function(_v)
			return "Rescued the dog. Who's a good firefighter? You are."
		end,
	},
	{
		id = "medic",
		title = "Breath of Fresh Air",
		blame = false,
		min = 1,
		stat = "revives",
		blurb = function(v)
			return `Revived {v} {plural(v, "teammate", "teammates")}. Mostly by yelling.`
		end,
	},
	{
		id = "hero",
		title = "Hero of Maple Street",
		blame = false,
		min = 2,
		stat = "rescued",
		blurb = function(v)
			return `Carried {v} lives to the truck.`
		end,
	},
	{
		id = "lift_legs",
		title = "Lift With Your Legs",
		blame = false,
		min = 40,
		stat = "carrySeconds",
		blurb = function(v)
			return `Carried someone for {v} seconds. Back is gone.`
		end,
	},
	{
		id = "pit_stop",
		title = "Pit Stop Pro",
		blame = false,
		min = 4,
		stat = "refills",
		blurb = function(v)
			return `Refilled {v} times. Knows every hydrant by name.`
		end,
	},
	{
		id = "hydrant_hugger",
		title = "Hydrant Hugger",
		blame = false,
		min = 150,
		stat = "water",
		blurb = function(v)
			return `Sprayed {v} litres. The lawn has never been greener.`
		end,
	},
	{
		id = "pro",
		title = "Professional Firefighter",
		blame = false,
		min = 5,
		stat = "firesOut",
		blurb = function(v)
			return `Put out {v} fires. Technically the job.`
		end,
	},
}

local CREDIT_FIELDS = { "firesOut", "rescued", "doors", "water", "refills", "revives", "pandas", "cats", "dogs" }

local SCAPEGOAT_LINES = {
	"Blame score {v}. The evidence is overwhelming.",
	"Blame score {v}. Witnesses are still wet.",
	"Blame score {v}. Please return your helmet.",
	"Blame score {v}. The chief would like a word.",
}

function Awards.catalog(): { { id: string, title: string, blame: boolean } }
	local out = {}
	for _, e in CATALOG do
		table.insert(out, { id = e.id, title = e.title, blame = e.blame })
	end
	table.insert(out, { id = "somehow_competent", title = "Somehow Competent", blame = false })
	table.insert(out, { id = "moral_support", title = "Moral Support", blame = false })
	table.insert(out, { id = "scapegoat", title = "Scapegoat", blame = true })
	return out
end

function Awards.blameScore(s: PlayerStats): number
	return num(s, "firesStarted")
		+ 2 * num(s, "downedOthers")
		+ num(s, "teammateSprayed")
		+ num(s, "timesDowned")
		+ 2 * num(s, "drops")
		+ 5 * num(s, "zappedOthers")
		+ 3 * num(s, "explosions")
		+ num(s, "overheats")
end

-- true if a ranks above b: higher value, then lower helmet, then lower userId
local function better(av: number, a: PlayerStats, bv: number, b: PlayerStats): boolean
	if av ~= bv then
		return av > bv
	end
	if a.helmet ~= b.helmet then
		return a.helmet < b.helmet
	end
	return a.userId < b.userId
end

function Awards.build(stats: { PlayerStats }, maxPerPlayer: number): { Award }
	local out: { Award } = {}
	if #stats == 0 then
		return out
	end
	local held: { [number]: number } = {}
	for _, entry in CATALOG do
		local best: PlayerStats? = nil
		local bestV = 0
		for _, s in stats do
			local v = math.floor(num(s, entry.stat))
			if v >= entry.min and (held[s.userId] or 0) < maxPerPlayer then
				if best == nil or better(v, s, bestV, best) then
					best, bestV = s, v
				end
			end
		end
		if best then
			held[best.userId] = (held[best.userId] or 0) + 1
			table.insert(out, {
				id = entry.id,
				title = entry.title,
				userId = best.userId,
				value = bestV,
				blurb = entry.blurb(bestV),
				blame = entry.blame,
			})
		end
	end
	for _, s in stats do
		if (held[s.userId] or 0) == 0 then
			local didSomething = false
			for _, f in CREDIT_FIELDS do
				if num(s, f) > 0 then
					didSomething = true
					break
				end
			end
			if didSomething and Awards.blameScore(s) == 0 then
				table.insert(out, {
					id = "somehow_competent",
					title = "Somehow Competent",
					userId = s.userId,
					value = 0,
					blurb = "Did the job and blamed for nothing. Suspicious.",
					blame = false,
				})
			else
				table.insert(out, {
					id = "moral_support",
					title = "Moral Support",
					userId = s.userId,
					value = 0,
					blurb = "Was definitely there.",
					blame = false,
				})
			end
		end
	end
	local goat = stats[1]
	local goatV = Awards.blameScore(goat)
	local total = goatV
	for i = 2, #stats do
		local v = Awards.blameScore(stats[i])
		total += v
		if better(v, stats[i], goatV, goat) then
			goat, goatV = stats[i], v
		end
	end
	local blurb
	if goatV == 0 then
		blurb = if #stats == 1
			then "You won't have anyone else to blame."
			else "Nobody did anything wrong. Suspicious."
	elseif #stats == 1 then
		blurb = (string.gsub(SCAPEGOAT_LINES[(goatV % #SCAPEGOAT_LINES) + 1], "{v}", tostring(goatV)))
	else
		blurb = `{math.floor(goatV / total * 100 + 0.5)}% of the blame. Blame score {goatV}.`
	end
	table.insert(out, {
		id = "scapegoat",
		title = if #stats == 1 then "You are to blame." else string.format("Firefighter %02d is to blame.", goat.helmet),
		userId = goat.userId,
		value = goatV,
		blurb = blurb,
		blame = true,
	})
	return out
end

function Awards.stars(burningAtEnd: number, rescued: number, trapped: number): number
	local stars = 1
	if burningAtEnd == 0 then
		stars += 1
	end
	if trapped == 0 and rescued > 0 then
		stars += 1
	end
	return stars
end

-- Kill-feed lines. {a} = actor tag ("02"), {b} = victim tag.
local CALLOUTS: { [string]: { string } } = {
	hose = {
		"{a} just hosed {b} into next week!",
		"{a} power-washed {b}. Squeaky clean.",
		"{a} mistook {b} for a fire!",
		"{a} hosed {b} into a pool!",
	},
	down = {
		"{a} got {b} toasted!",
		"{b} is down. {a} was RIGHT there.",
		"{a} let {b} become a crouton!",
	},
	drop = {
		"{a} dropped a civilian! Butterfingers!",
		"{a} yeeted someone onto the lawn.",
		"{a} dropped the rescue. Oops.",
	},
	door = {
		"{a} destroyed a door. It was probably open.",
		"{a} vs door: door lost.",
		"{a} said HERE'S JOHNNY to a door.",
	},
	zap = {
		"{a} electrocuted {b}! Shocking!",
		"{b} got zapped. Thanks, {a}.",
		"{a} turned {b} into a lightbulb!",
	},
	boom = {
		"KABOOM! {a} was nearest. Just saying.",
		"{a} and the explosion: a love story.",
	},
	overheat = {
		"{a} is OVERHEATING! Somebody hose them!",
		"{a} is well done. Medium well at best.",
		"{a} is cooking. Literally.",
	},
	spread = {
		"The fire spread next to {a}. Suspicious.",
		"{a} is 'helping' the fire spread.",
	},
}

local function tag(helmet: number?): string
	return string.format("%02d", helmet or 0)
end

function Awards.callout(event: string, actor: number, victim: number?, roll: number?): string
	local lines = CALLOUTS[event]
	if not lines then
		return `{tag(actor)} did something blameworthy.`
	end
	local i = ((math.floor(roll or 0) % #lines) + #lines) % #lines + 1
	local text = string.gsub(lines[i], "{a}", tag(actor))
	text = string.gsub(text, "{b}", if victim then tag(victim) else "someone")
	return text
end

return Awards
