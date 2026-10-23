--!strict
-- MissionCatalog: every entry has the Types.MissionDef shape, ids are unique, v1 ships house_fire only.
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
}
local HAZARDS = { electrocution = true, fire_tornado = true, explosion = true, tidal_wave = true, cigarette = true }
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

Spec.test("v1 ships house_fire on Town only", function()
	Spec.eq(byId.house_fire.enabled, true, "house_fire.enabled")
	Spec.eq(byId.house_fire.locationId, "Town", "house_fire.locationId")
	for _, m in Missions do
		if m.id ~= "house_fire" then
			Spec.eq(m.enabled, false, `{m.id}.enabled`)
		end
	end
end)

Spec.test("every entry has the MissionDef shape", function()
	for _, m in Missions do
		local id = m.id
		Spec.eq(type(m.title), "string", `{id}.title`)
		Spec.eq(type(m.blurb), "string", `{id}.blurb`)
		Spec.eq(type(m.locationId), "string", `{id}.locationId`)
		Spec.truthy(PRESETS[m.atmosphere], `{id}.atmosphere`)
		Spec.truthy(m.players.min >= 1 and m.players.max <= 4 and m.players.min <= m.players.max, `{id}.players`)
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

return Spec.finish()
