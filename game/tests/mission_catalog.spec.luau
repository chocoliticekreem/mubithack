--!strict
-- MissionCatalog: every entry has the Types.MissionDef shape, ids are unique, every mission is enabled (v2 city dispatch).
local Spec = require("./Spec")
local Missions = require("../ReplicatedStorage/Config/MissionCatalog") :: { any }

local TRAILER_IDS = {
	"house_fire",
	"apartment_trampoline",
	"school_alarm",
	"farm_haystack",
	"forest_walkie",
	"storage_fusebox",
	"tornado_field",
	"dam_finale",
	"panda_zoo",
	"nightclub_fire", -- v2 city-only calls
	"skyscraper_fire",
	"diner_grease", -- v3 crazy calls (HazardService twists)
	"gas_leak",
	"highway_pileup",
	"cat_tree",
}
local TWISTS = { diner_grease = "grease_fire", gas_leak = "gas_leak", highway_pileup = "pileup", cat_tree = "cat_tree" }
local HAZARDS = {
	electrocution = true,
	fire_tornado = true,
	explosion = true,
	tidal_wave = true,
	cigarette = true,
	grease_fire = true, -- v3 twists (Lib/Hazard/Twists)
	gas_leak = true,
	pileup = true,
	cat_tree = true,
}
local KINDS = { Civilian = true, Dog = true, Cat = true, Panda = true }
local OBJECTIVES = { extinguish = true, rescue = true, survive = true, custom = true }
local STARTS = { FireStart = true, Random = true, Scripted = true }
local STARS = { finish = true, allOut = true, allRescued = true, underTime = true, noDowns = true, buildingSaved = true }
local PRESETS = { DuskSuburb = true, NightStreet = true, FireGlow = true } -- AtmosphereConfig.Presets

local byId: { [string]: any } = {}
for _, m in Missions do
	byId[m.id] = m
end

Spec.test("every trailer mission is listed once", function()
	Spec.eq(#Missions, #TRAILER_IDS, "mission count")
	for _, id in TRAILER_IDS do
		Spec.truthy(byId[id], id)
	end
end)

Spec.test("every mission is enabled and a solo player can roll out", function()
	Spec.eq(byId.house_fire.locationId, "Town", "house_fire.locationId")
	for _, m in Missions do
		Spec.eq(m.enabled, true, `{m.id}.enabled`)
		Spec.eq(m.players.min, 1, `{m.id}.players.min`)
		Spec.eq(type(m.call), "string", `{m.id}.call`)
	end
end)

Spec.test("every entry has the MissionDef shape", function()
	for _, m in Missions do
		local id = m.id
		Spec.eq(type(m.title), "string", `{id}.title`)
		Spec.eq(type(m.blurb), "string", `{id}.blurb`)
		Spec.eq(type(m.locationId), "string", `{id}.locationId`)
		Spec.truthy(PRESETS[m.atmosphere], `{id}.atmosphere`)
		Spec.truthy(m.players.min >= 1 and m.players.max <= 8 and m.players.min <= m.players.max, `{id}.players`)
		Spec.truthy(m.seconds >= 60 and m.seconds <= 600, `{id}.seconds`)
		Spec.truthy(#m.objectives >= 1, `{id}.objectives`)
		for _, o in m.objectives do
			Spec.truthy(OBJECTIVES[o.kind], `{id} objective kind {o.kind}`)
			Spec.eq(type(o.text), "string", `{id} objective text`)
		end
		Spec.truthy(m.fires.count >= 1 and STARTS[m.fires.starts], `{id}.fires`)
		for _, r in m.rescues do
			Spec.truthy(KINDS[r.kind], `{id} rescue kind {r.kind}`)
			Spec.truthy(r.count >= 1, `{id} rescue count`)
		end
		for _, h in m.hazards do
			Spec.truthy(HAZARDS[h], `{id} hazard {h}`)
		end
		Spec.eq(type(m.tools), "table", `{id}.tools`)
		Spec.eq(#m.stars, 3, `{id} star count`)
		for _, s in m.stars do
			Spec.truthy(STARS[s.id], `{id} star {s.id}`)
		end
	end
end)

Spec.test("every call is big and escalates: >= 4 fires, 2+ phases, enough time for them", function()
	local SET_PIECES = { flashover = true, explosion = true, collapse = true }
	for _, m in Missions do
		local id = m.id
		Spec.truthy(m.fires.count >= 4, `{id} starts with at least 4 fires`)
		Spec.truthy(m.seconds >= 240 and m.seconds <= 540, `{id}.seconds is a 4-9 minute call`)
		Spec.eq(type(m.escalation), "table", `{id}.escalation`)
		Spec.truthy(#m.escalation >= 2, `{id} has 2+ escalation phases`)
		local last = 0
		local setPiece = false
		for i, ph in m.escalation do
			Spec.truthy(type(ph.at) == "number" and ph.at > last, `{id} phase {i} after the previous one`)
			Spec.truthy(type(ph.fires) == "number" and ph.fires >= 1, `{id} phase {i} fires`)
			Spec.eq(type(ph.text), "string", `{id} phase {i} banner`)
			if ph.setPiece ~= nil then
				Spec.truthy(SET_PIECES[ph.setPiece], `{id} phase {i} setPiece {ph.setPiece}`)
				setPiece = true
			end
			last = ph.at
		end
		Spec.truthy(setPiece, `{id} has a set piece`)
		Spec.truthy(m.seconds >= last + 120, `{id}: 2+ minutes left after the last phase`)
		for _, s in m.stars do
			if s.id == "underTime" then
				Spec.truthy(s.seconds > last + 60, `{id} underTime is reachable after the last phase`)
			end
		end
	end
end)

Spec.test("v3 crazy calls: twist hazard, 1-8 players, a guide with steps", function()
	for id, hazard in TWISTS do
		local m = byId[id]
		Spec.truthy(m, id)
		Spec.truthy(table.find(m.hazards, hazard) ~= nil, `{id} arms {hazard}`)
		Spec.eq(m.players.max, 8, `{id}.players.max`)
		local custom = false
		for _, o in m.objectives do
			custom = custom or o.kind == "custom" or o.kind == "rescue"
		end
		Spec.truthy(custom, `{id} has a twist objective`)
		Spec.eq(type(m.guide), "table", `{id}.guide`)
		Spec.eq(type(m.guide.headline), "string", `{id}.guide.headline`)
		Spec.truthy(#m.guide.steps >= 3, `{id}.guide.steps`)
		for _, step in m.guide.steps do
			Spec.eq(type(step), "string", `{id} guide step`)
		end
	end
end)

return Spec.finish()
