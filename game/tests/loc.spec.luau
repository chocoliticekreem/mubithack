--!strict
-- LocCore lookup rules + the hand-written translation tables (Config/Translations).
local Spec = require("./Spec")
local LocCore = require("../ReplicatedStorage/Lib/LocCore")
local Keys = require("../ReplicatedStorage/Config/Translations/Keys")

local LANGS = { "es", "ru", "pt", "fr", "id", "th", "tr", "pl", "uk" }

local es = LocCore.build({
	["SAVE THE PANDA!"] = "¡SALVA AL PANDA!",
	["FIRES LEFT  {1}"] = "FUEGOS  {1}",
	["CARRYING: {1}\nGet them OUTSIDE or to the TRUCK!"] = "LLEVAS: {1}\n¡Sácalos AFUERA o al CAMIÓN!",
	["DOG"] = "PERRO",
	["12 Maple Street"] = "12 Maple Street",
	["Fire Axe"] = "Hacha",
	["{1}: {2}"] = "{1}: {2}",
	["Reach Level {1}!"] = "¡Llega al nivel {1}!",
	["{1}'s Truck"] = "Camión de {1}",
	["{1} rescued the {2}!"] = "¡{1} rescató: {2}!",
	["panda"] = "panda",
	["[{1}] {2}"] = "[{1}] {2}",
	["PASS"] = "PASE",
	["Hose"] = "Manguera",
}, "es")

Spec.test("exact keys", function()
	Spec.eq((LocCore.translate(es, "SAVE THE PANDA!")), "¡SALVA AL PANDA!")
	Spec.eq((LocCore.translate(es, "nope")), nil)
	Spec.eq((LocCore.translate(es, "3:00")), nil)
end)

Spec.test("templates fill numbers and translate nested keys", function()
	local out, kind = LocCore.translate(es, "FIRES LEFT  3")
	Spec.eq(out, "FUEGOS  3")
	Spec.eq(kind, "template")
	Spec.eq((LocCore.translate(es, "CARRYING: DOG\nGet them OUTSIDE or to the TRUCK!")), "LLEVAS: PERRO\n¡Sácalos AFUERA o al CAMIÓN!")
	Spec.eq((LocCore.translate(es, "Fire Axe: Reach Level 3!")), "Hacha: ¡Llega al nivel 3!")
	Spec.eq((LocCore.translate(es, "[P] PASS")), "[P] PASE")
end)

Spec.test("strict templates refuse untranslatable values", function()
	Spec.eq((LocCore.translate(es, "Thermal: nothing nearby")), nil)
	Spec.eq((LocCore.translate(es, "Pengu's Truck")), "Camión de Pengu") -- long template: names pass through
	Spec.eq((LocCore.translate(es, "Pengu rescued the panda!")), "¡Pengu rescató: panda!")
end)

Spec.test("upper-cased English finds its key", function()
	Spec.eq((LocCore.translate(es, "12 MAPLE STREET")), "12 MAPLE STREET")
	Spec.eq((LocCore.translate(es, "HOSE")), "MANGUERA")
	Spec.eq((LocCore.translate(es, "PENGU RESCUED THE PANDA!")), "¡PENGU RESCATÓ: PANDA!")
end)

Spec.test("utf8 upper", function()
	Spec.eq(LocCore.upper("пожарный ёж", "ru"), "ПОЖАРНЫЙ ЁЖ")
	Spec.eq(LocCore.upper("ґанок і їжак", "uk"), "ҐАНОК І ЇЖАК")
	Spec.eq(LocCore.upper("çiçek ığdır", "tr"), "ÇİÇEK IĞDIR")
	Spec.eq(LocCore.upper("żółć", "pl"), "ŻÓŁĆ")
	Spec.eq(LocCore.upper("¡camión!", "es"), "¡CAMIÓN!")
	Spec.eq(LocCore.upper("ดับไฟ", "th"), "ดับไฟ")
end)

Spec.test("format", function()
	Spec.eq(LocCore.format("{1} / {2} XP", { 3, 10 }), "3 / 10 XP")
	Spec.eq(LocCore.format("{2} before {1}", { "a", "b" }), "b before a")
end)

-- the tables --------------------------------------------------------------------------------------

local keySet: { [string]: boolean } = {}
Spec.test("Keys: unique, non-empty", function()
	for i, k in Keys do
		Spec.truthy(type(k) == "string" and k ~= "", `key {i}`)
		Spec.truthy(not keySet[k], `duplicate key {k}`)
		keySet[k] = true
	end
end)

local function placeholders(s: string): string
	local found = {}
	for n in string.gmatch(s, "{(%d)}") do
		found[n] = true
	end
	local list = {}
	for n in found do
		table.insert(list, n)
	end
	table.sort(list)
	return table.concat(list, ",")
end

local function count(s: string, pat: string): number
	local _, n = string.gsub(s, pat, "")
	return n
end

for _, lang in LANGS do
	local ok, dict = pcall(require, `../ReplicatedStorage/Config/Translations/{lang}`)
	if not ok then
		print(`  --   {lang}: no table yet`)
		continue
	end
	Spec.test(`{lang}: keys known, placeholders + line breaks kept`, function()
		local n = 0
		for k, v in dict :: { [string]: string } do
			Spec.truthy(keySet[k], `{lang} has a key not in Keys: {k}`)
			Spec.truthy(type(v) == "string" and v ~= "", `{lang} empty value for {k}`)
			Spec.eq(placeholders(v), placeholders(k), `{lang} placeholders of {k}`)
			Spec.eq(count(v, "\n"), count(k, "\n"), `{lang} line breaks of {k}`)
			for tag in string.gmatch(k, "</?%a+[^>]*>") do
				Spec.truthy(string.find(v, tag, 1, true) ~= nil, `{lang} lost {tag} in {k}`)
			end
			n += 1
		end
		print(`       {lang}: {n}/{#Keys} keys ({math.floor(n / #Keys * 100 + 0.5)}%)`)
	end)
end

return Spec.finish()
