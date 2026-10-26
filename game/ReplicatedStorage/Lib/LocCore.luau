--!strict
-- LocCore [owner: Localization]. Pure translation lookup (no Roblox APIs; spec: game/tests/loc.spec.luau).
-- The live side (which language, watching every label) is Lib/Loc + Controllers/LocalizationController.
--
-- Keys are the English text itself (Config/Translations/Keys). A key with {1} {2} ... is a TEMPLATE:
-- "FIRES LEFT  {1}" matches "FIRES LEFT  3" and gives "FUEGOS  3". Captured values are translated too
-- when they are keys themselves ("CARRYING: {1}" with "DOG" -> "PERRO").
--
--   LocCore.build(dict, lang) -> Index        dict = { [english] = translation } (English: identity)
--   LocCore.translate(index, text) -> (string?, "exact" | "template" | nil)
--   LocCore.format(template, args) -> string  "{1} of {2}" + { 3, 5 } -> "3 of 5"
--   LocCore.upper(s, lang?) -> string         UTF-8 aware (Latin-1/Ext-A, Turkish i, Cyrillic)
--   LocCore.isTemplate(key) -> boolean
--
-- A template whose fixed text has fewer than STRICT_LETTERS letters ("{1}: {2}", "+{1} XP", "TURN {1}")
-- is STRICT: every value it captures must be a number/symbol/short keycap or itself translatable, else
-- the match is refused (so "Meet: at the truck" never becomes half Spanish). Longer templates ("{1}'s
-- Truck") accept anything (player names).
local LocCore = {}

local STRICT_LETTERS = 5
local MAX_DEPTH = 2
local CACHE_MAX = 4000

export type Template = {
	key: string,
	out: string,
	pattern: string,
	slots: { number }, -- capture i fills placeholder slots[i]
	anchor: string, -- longest fixed chunk (plain find before the pattern runs)
	literal: number, -- fixed-text length (more fixed text = tried first)
	strict: boolean,
}

export type Index = {
	lang: string,
	exact: { [string]: string },
	keys: { [string]: string }, -- every key incl. templates -> its translation (Loc.t formats these)
	upperKeys: { [string]: string }, -- upper(key) -> key, for text the code upper-cased
	templates: { Template },
	cache: { [string]: any },
	cacheN: number,
}

function LocCore.isTemplate(key: string): boolean
	return string.find(key, "{%d}") ~= nil
end

local function escape(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function letters(s: string): number
	local _, n = string.gsub(s, "%a", "")
	return n
end

local function compile(key: string, out: string): Template
	local parts = {}
	local slots = {}
	local anchor = ""
	local literal = 0
	local fixedLetters = 0
	local pos = 1
	while true do
		local s, e, n = string.find(key, "{(%d)}", pos)
		local chunk = string.sub(key, pos, (s or (#key + 1)) - 1)
		if #chunk > #anchor then
			anchor = chunk
		end
		literal += #chunk
		fixedLetters += letters(chunk)
		table.insert(parts, escape(chunk))
		if not s then
			break
		end
		table.insert(parts, "(.-)")
		table.insert(slots, tonumber(n) :: number)
		pos = (e :: number) + 1
	end
	return {
		key = key,
		out = out,
		pattern = "^" .. table.concat(parts) .. "$",
		slots = slots,
		anchor = anchor,
		literal = literal,
		strict = fixedLetters < STRICT_LETTERS,
	}
end

------------------------------------------------------------------------------------------- upper

local function upperCode(c: number, lang: string): number
	if c >= 97 and c <= 122 then -- a-z
		if c == 105 and lang == "tr" then
			return 0x130 -- i -> İ
		end
		return c - 32
	elseif c >= 0xE0 and c <= 0xFE and c ~= 0xF7 then -- à..þ
		return c - 32
	elseif c == 0xFF then
		return 0x178
	elseif c == 0x131 then -- ı
		return 73
	elseif c >= 0x100 and c <= 0x17F then -- Latin Extended-A: alternating pairs
		if (c >= 0x100 and c <= 0x137) or (c >= 0x14A and c <= 0x177) then
			return if c % 2 == 1 then c - 1 else c
		elseif (c >= 0x139 and c <= 0x148) or (c >= 0x179 and c <= 0x17E) then
			return if c % 2 == 0 then c - 1 else c
		end
	elseif c >= 0x430 and c <= 0x44F then -- а..я
		return c - 32
	elseif c >= 0x450 and c <= 0x45F then -- ѐ..џ (ё і ї є ў ...)
		return c - 80
	elseif c == 0x491 then -- ґ
		return 0x490
	end
	return c
end

function LocCore.upper(s: string, lang: string?): string
	local l = lang or ""
	if l ~= "tr" and not string.find(s, "[\128-\255]") then
		return string.upper(s) -- plain ASCII (Turkish needs i -> İ below)
	end
	local ok, out = pcall(function()
		local buf = table.create(#s)
		for _, c in utf8.codes(s) do
			table.insert(buf, utf8.char(upperCode(c, l)))
		end
		return table.concat(buf)
	end)
	return if ok then out else string.upper(s)
end

-- "SAVE THE PANDA!" style text: has letters, no lowercase ASCII
local function isUpperText(s: string): boolean
	return string.find(s, "%a") ~= nil and string.find(s, "%l") == nil
end

------------------------------------------------------------------------------------------ build

function LocCore.build(dict: { [string]: string }, lang: string): Index
	local exact: { [string]: string } = {}
	local keys: { [string]: string } = {}
	local upperKeys: { [string]: string } = {}
	local templates: { Template } = {}
	for key, out in dict do
		if type(key) ~= "string" or type(out) ~= "string" or out == "" then
			continue
		end
		keys[key] = out
		if LocCore.isTemplate(key) then
			table.insert(templates, compile(key, out))
			-- the code upper-cases some templated text ("HOUSE FIRE AT 40 CEDAR LN"): match that too
			local u = string.upper(key)
			if u ~= key and dict[u] == nil then
				table.insert(templates, compile(u, LocCore.upper(out, lang)))
			end
		else
			exact[key] = out
			local u = string.upper(key)
			if u ~= key and upperKeys[u] == nil then
				upperKeys[u] = key
			end
		end
	end
	table.sort(templates, function(a: Template, b: Template): boolean
		if a.literal ~= b.literal then
			return a.literal > b.literal
		end
		return a.key < b.key
	end)
	return { lang = lang, exact = exact, keys = keys, upperKeys = upperKeys, templates = templates, cache = {}, cacheN = 0 }
end

function LocCore.format(template: string, args: { any }?): string
	if not args then
		return template
	end
	return (string.gsub(template, "{(%d)}", function(n: string): string?
		local v = (args :: { any })[tonumber(n) :: number]
		return if v ~= nil then tostring(v) else nil
	end))
end

-- a value that reads the same in every language: numbers, symbols, a keycap ("E", "R2")
local function plain(v: string): boolean
	if string.find(v, "%a") == nil then
		return true
	end
	return #v <= 3 and string.find(v, "%s") == nil
end

local translateAt: (Index, string, number) -> (string?, string?)

local function tryTemplate(index: Index, t: Template, text: string, depth: number): string?
	if t.anchor ~= "" and not string.find(text, t.anchor, 1, true) then
		return nil
	end
	local caps = { string.match(text, t.pattern) }
	if #caps == 0 then
		return nil
	end
	local vals: { [number]: string } = {}
	for i, cap in caps do
		local slot = t.slots[i]
		if vals[slot] ~= nil then
			continue -- the same {n} twice ("{2} ... {2}"): first capture wins
		end
		if cap == "" then
			if t.strict then
				return nil
			end
			vals[slot] = cap
		else
			local tr = if depth < MAX_DEPTH and string.find(cap, "%a") then translateAt(index, cap, depth + 1) else nil
			if tr then
				vals[slot] = tr
			elseif plain(cap) then
				vals[slot] = cap
			elseif t.strict then
				return nil
			else
				vals[slot] = cap
			end
		end
	end
	return (string.gsub(t.out, "{(%d)}", function(n: string): string?
		return vals[tonumber(n) :: number]
	end))
end

translateAt = function(index: Index, text: string, depth: number): (string?, string?)
	local hit = index.exact[text]
	if hit then
		return hit, "exact"
	end
	if string.find(text, "%a") == nil then
		return nil, nil -- "3:00", "+25", "★": nothing to say
	end
	if isUpperText(text) then
		local k = index.upperKeys[text]
		if k then
			return LocCore.upper(index.exact[k], index.lang), "exact"
		end
	end
	for _, t in index.templates do
		local out = tryTemplate(index, t, text, depth)
		if out then
			return out, "template"
		end
	end
	return nil, nil
end

function LocCore.translate(index: Index, text: string): (string?, string?)
	local c = index.cache[text]
	if c ~= nil then
		if c == false then
			return nil, nil
		end
		return c[1], c[2]
	end
	local out, kind = translateAt(index, text, 0)
	if index.cacheN >= CACHE_MAX then
		index.cache = {}
		index.cacheN = 0
	end
	index.cache[text] = if out then { out, kind } else false
	index.cacheN += 1
	return out, kind
end

return LocCore
