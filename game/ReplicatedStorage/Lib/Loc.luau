--!strict
-- Loc [owner: Localization]. Translate player-facing text. English is the source AND the key:
--   Loc.t("SAVE THE PANDA!")                 -> "¡SALVA AL PANDA!" (es) / "SAVE THE PANDA!" (en, unknown)
--   Loc.t("FIRES LEFT  {1}", { n })          -> "FUEGOS  3"   (a template: never build UI text with ..)
--   Loc.translate(text) -> (string?, kind)   any finished English text, templates matched ("FIRES LEFT  3")
--   Loc.lang() -> "en" | "es" | "ru" | "pt" | "fr" | "id" | "th" | "tr" | "pl" | "uk"
--   Loc.upper(s)                             UTF-8 upper for the current language (Cyrillic, Turkish İ)
--   Loc.Changed: RBXScriptSignal(lang)       the language changed (LocaleOverride in Studio)
-- Hand-written tables: Config/Translations/<lang>.luau ({ [english] = translation }), key list:
-- Config/Translations/Keys.luau. Rules: Lib/LocCore. Most UI never calls this: the client's
-- Controllers/LocalizationController translates every TextLabel / TextButton as its Text changes. Call
-- Loc.t when you need the string itself (widths, chat, a template you format yourself).
-- Server: Loc.lang() is always "en" (text replicates in English; each client translates for itself).
local LocalizationService = game:GetService("LocalizationService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local LocCore = require(script.Parent:WaitForChild("LocCore") :: ModuleScript)

local Loc = {}

-- hand-translated languages (audience order). Anything else falls back to English + Roblox's own
-- automatic translation of captured text.
Loc.Languages = { "es", "ru", "pt", "fr", "id", "th", "tr", "pl", "uk" }
Loc.OverrideAttr = "LocaleOverride" -- Player attr (Studio only): "es", "ru", "th", ... forces a language

local SUPPORTED: { [string]: boolean } = {}
for _, l in Loc.Languages do
	SUPPORTED[l] = true
end

local changed = Instance.new("BindableEvent")
Loc.Changed = changed.Event

local current = "en"
local indexes: { [string]: LocCore.Index } = {}
local folder: Instance? = nil

local function translationsFolder(): Instance?
	if folder then
		return folder
	end
	local rs = game:GetService("ReplicatedStorage")
	local cfg = rs:FindFirstChild("Config")
	folder = cfg and cfg:FindFirstChild("Translations")
	return folder
end

local function dictFor(lang: string): { [string]: string }
	local f = translationsFolder()
	if lang == "en" then
		local m = f and f:FindFirstChild("Keys")
		local list = if m and m:IsA("ModuleScript") then (require(m) :: any) else {}
		local d = {}
		for _, k in list do
			d[k] = k
		end
		return d
	end
	local m = f and f:FindFirstChild(lang)
	if m and m:IsA("ModuleScript") then
		local ok, d = pcall(require, m)
		if ok and type(d) == "table" then
			return d :: any
		end
		warn(`[Loc] Translations/{lang} failed: {d}`)
	end
	return {}
end

function Loc.index(lang: string?): LocCore.Index
	local l = lang or current
	local idx = indexes[l]
	if not idx then
		idx = LocCore.build(dictFor(l), l)
		indexes[l] = idx
	end
	return idx
end

-- "es-mx" / "pt-br" / "uk-ua" -> "es" / "pt" / "uk"; unsupported -> "en"
function Loc.langOf(localeId: string?): string
	local l = string.lower(string.match(localeId or "", "^(%a+)") or "")
	return if SUPPORTED[l] then l else "en"
end

function Loc.lang(): string
	return current
end

function Loc.setLang(lang: string)
	local l = if SUPPORTED[lang] then lang else "en"
	if l == current then
		return
	end
	current = l
	changed:Fire(l)
end

function Loc.supported(lang: string): boolean
	return SUPPORTED[lang] == true
end

-- the local player's language: the Studio override, else the player's Roblox language setting
function Loc.detect(player: Player): string
	if RunService:IsStudio() then
		local o = player:GetAttribute(Loc.OverrideAttr)
		if type(o) == "string" and o ~= "" then
			return Loc.langOf(o)
		end
	end
	local ok, tr = pcall(function()
		return LocalizationService:GetTranslatorForPlayerAsync(player)
	end)
	if ok and tr then
		return Loc.langOf((tr :: Translator).LocaleId)
	end
	local ok2, rid = pcall(function()
		return LocalizationService.RobloxLocaleId
	end)
	if ok2 and type(rid) == "string" and rid ~= "" then
		return Loc.langOf(rid)
	end
	return Loc.langOf(player.LocaleId)
end

function Loc.translate(text: string, lang: string?): (string?, string?)
	return LocCore.translate(Loc.index(lang), text)
end

-- text Loc.t already translated: the label watcher leaves it alone instead of looking it up again
local produced: { [string]: boolean } = {}
local producedN = 0

local function mark(s: string): string
	if current ~= "en" and not produced[s] then
		if producedN > 3000 then
			table.clear(produced)
			producedN = 0
		end
		produced[s] = true
		producedN += 1
	end
	return s
end

-- text you assembled from Loc.t pieces yourself: tell the label watcher it is already translated
function Loc.mark(text: string): string
	return mark(text)
end

function Loc.isProduced(text: string): boolean
	return produced[text] == true
end

-- the translation of an English key (or template + args); English back when there is none
function Loc.t(text: string, args: { any }?): string
	local idx = Loc.index()
	local tmpl = if current == "en" then text else (idx.keys[text] or text)
	if not args then
		if tmpl ~= text then
			return mark(tmpl)
		end
		local tr = LocCore.translate(idx, text)
		return if tr then mark(tr) else text
	end
	local vals = table.create(#args)
	for i, v in args do
		local s = tostring(v)
		vals[i] = if current == "en" then s else ((LocCore.translate(idx, s)) or s)
	end
	return mark(LocCore.format(tmpl, vals))
end

function Loc.format(template: string, args: { any }?): string
	return LocCore.format(template, args)
end

function Loc.upper(s: string): string
	return LocCore.upper(s, current)
end

-- the client picks its language once the Players service has a LocalPlayer
if RunService:IsClient() then
	task.spawn(function()
		local lp = Players.LocalPlayer
		while not lp do
			task.wait()
			lp = Players.LocalPlayer
		end
		Loc.setLang(Loc.detect(lp))
		if RunService:IsStudio() then
			lp:GetAttributeChangedSignal(Loc.OverrideAttr):Connect(function()
				Loc.setLang(Loc.detect(lp))
			end)
		end
	end)
end

return Loc
