--!strict
-- LocalizationController [owner: Localization]. Every TextLabel / TextButton the player can see, in their
-- language, with no per-controller code:
--   * watches PlayerGui and every BillboardGui / SurfaceGui in the Workspace; each time a label's Text
--     changes it looks the English up in Lib/Loc (hand-written tables in Config/Translations, templates
--     like "FIRES LEFT  {1}" included) and writes the translation back.
--   * AutoLocalize: a label we translated (or a templated English one, e.g. "FIRES LEFT  3") gets
--     AutoLocalize = false, so Roblox's automatic text capture doesn't log one entry per number and
--     doesn't re-translate our text. Everything we have no entry for keeps AutoLocalize on: Roblox's
--     automatic translation (dashboard) still covers it, and every language we don't hand-translate.
--   * fit: a translated label that no longer fits (and isn't TextScaled / AutomaticSize) is switched to
--     TextScaled with a UITextSizeConstraint capped at its old TextSize, so a longer word shrinks
--     instead of spilling out of a phone-sized button.
--   * Studio: Player attr LocaleOverride = "es" | "ru" | "th" | ... forces a language live (Lib/Loc), and
--     LocalPlayer.LocProbe (BindableFunction) answers Invoke("misses") with English text seen on screen
--     that had no translation, Invoke("stats") with counts.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local LocalizationController = {}
LocalizationController.Priority = 1 -- first: catch every label as the other controllers build their UI

local player = Players.LocalPlayer
local STUDIO = RunService:IsStudio()

type State = {
	src: string, -- the English the game last wrote
	out: string?, -- what we wrote over it
	conn: RBXScriptConnection,
	gone: RBXScriptConnection,
	fitted: boolean?,
	face: Font?, -- the game's own FontFace, when we swapped it for this language
	faceLang: string?,
}

local tracked: { [Instance]: State } = {}
local misses: { [string]: number } = {}
local stats = { translated = 0, templated = 0, missed = 0, fitted = 0, tracked = 0 }

local TEXT_CLASSES: { [string]: boolean } = { TextLabel = true, TextButton = true }
local WORLD_GUIS: { [string]: boolean } = { BillboardGui = true, SurfaceGui = true }

local function noteMiss(text: string)
	if not STUDIO or #text > 300 then
		return
	end
	if misses[text] == nil then
		stats.missed += 1
	end
	misses[text] = (misses[text] or 0) + 1
end

-- a translated label that overflows shrinks to fit (after layout, so TextFits is real)
local function fit(obj: TextLabel | TextButton, st: State)
	if st.fitted or obj.TextScaled or obj.AutomaticSize ~= Enum.AutomaticSize.None then
		return
	end
	local function check(): boolean
		if tracked[obj] ~= st or st.fitted or obj.TextScaled or not obj.Parent then
			return true
		end
		if obj.AbsoluteSize.X < 2 or obj.AbsoluteSize.Y < 2 or obj.TextFits then
			return false
		end
		st.fitted = true
		stats.fitted += 1
		if not obj:FindFirstChildOfClass("UITextSizeConstraint") then
			local c = Instance.new("UITextSizeConstraint")
			c.Name = "LocFit"
			c.MaxTextSize = math.max(1, math.floor(obj.TextSize))
			c.MinTextSize = math.max(6, math.floor(obj.TextSize * 0.45))
			c.Parent = obj
		end
		obj.TextScaled = true
		return true
	end
	-- cards pop in (UIScale / size tweens): look again after the animation settles
	task.spawn(function()
		for _, t in { 0.05, 0.4, 1.2 } do
			task.wait(t)
			if check() then
				return
			end
		end
	end)
end

-- Fonts: LuckiestGuy / FredokaOne / PermanentMarker have no Cyrillic or Thai. Roblox falls back to a
-- thin sans for those letters (checked in Studio), so Russian / Ukrainian get a heavy font with real
-- Cyrillic (Montserrat / Gotham) and Thai keeps the family at Bold weight (the fallback follows the weight).
local CARTOON: { [Enum.Font]: boolean } = {
	[Enum.Font.LuckiestGuy] = true,
	[Enum.Font.FredokaOne] = true,
	[Enum.Font.PermanentMarker] = true,
}
local CYRILLIC_HEAVY = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Heavy)
local CYRILLIC_BOLD = Font.new("rbxasset://fonts/families/Montserrat.json", Enum.FontWeight.Bold)

local function fontFor(obj: TextLabel | TextButton, st: State)
	local lang = Loc.lang()
	if st.face then
		if lang == st.faceLang then
			return
		end
		obj.FontFace = st.face -- language changed: back to the game's font first
		st.face = nil
	end
	if lang ~= "ru" and lang ~= "uk" and lang ~= "th" then
		return
	end
	local ok, enum = pcall(function()
		return obj.Font
	end)
	if not ok or not CARTOON[enum] then
		return
	end
	st.face = obj.FontFace
	st.faceLang = lang
	if lang == "th" then
		obj.FontFace = Font.new(obj.FontFace.Family, Enum.FontWeight.Bold, obj.FontFace.Style)
	elseif enum == Enum.Font.FredokaOne then
		obj.FontFace = CYRILLIC_BOLD
	else
		obj.FontFace = CYRILLIC_HEAVY
	end
end

local function apply(obj: TextLabel | TextButton, st: State)
	local text = obj.Text
	if st.out ~= nil and text == st.out then
		return -- our own write
	end
	st.src = text
	st.out = nil
	if text == "" then
		return
	end
	if Loc.isProduced(text) then
		-- built with Loc.t: already in this language
		obj.AutoLocalize = false
		st.out = text
		fontFor(obj, st)
		fit(obj, st)
		return
	end
	local out, kind = Loc.translate(text)
	if kind == "template" then
		stats.templated += 1
		obj.AutoLocalize = false -- "FIRES LEFT  3": one capture entry per number otherwise
	end
	if Loc.lang() == "en" then
		if st.face then
			obj.FontFace = st.face
			st.face = nil
		end
		return
	end
	if out and out ~= text then
		stats.translated += 1
		obj.AutoLocalize = false
		st.out = out
		obj.Text = out
		fontFor(obj, st)
		fit(obj, st)
	elseif not out then
		noteMiss(text)
	end
end

local function track(obj: Instance)
	if tracked[obj] or not TEXT_CLASSES[obj.ClassName] then
		return
	end
	local label = obj :: TextLabel
	local st: State
	st = {
		src = label.Text,
		out = nil,
		conn = label:GetPropertyChangedSignal("Text"):Connect(function()
			apply(label, st)
		end),
		gone = label.Destroying:Connect(function()
			local s = tracked[obj]
			if s then
				s.conn:Disconnect()
				s.gone:Disconnect()
				tracked[obj] = nil
				stats.tracked -= 1
			end
		end),
	}
	tracked[obj] = st
	stats.tracked += 1
	apply(label, st)
end

-- world signs: only text under a BillboardGui / SurfaceGui
local function worldAdded(obj: Instance)
	if TEXT_CLASSES[obj.ClassName] then
		local gui = obj:FindFirstAncestorWhichIsA("LayerCollector")
		if gui and WORLD_GUIS[gui.ClassName] then
			track(obj)
		end
	end
end

-- language changed: put every label back to its English, then translate again
local function retranslate()
	for obj, st in tracked do
		local label = obj :: TextLabel
		if st.out ~= nil and label.Text == st.out then
			st.out = nil
			label.Text = st.src -- fires apply() with the English
		else
			apply(label, st)
		end
	end
end

local function probe()
	if not STUDIO then
		return
	end
	local old = player:FindFirstChild("LocProbe")
	if old then
		old:Destroy()
	end
	local f = Instance.new("BindableFunction")
	f.Name = "LocProbe"
	f.OnInvoke = function(cmd: string?, arg: any?): any
		if cmd == "misses" then
			local list = {}
			for text, n in misses do
				table.insert(list, { text = text, n = n })
			end
			table.sort(list, function(a, b)
				return a.n > b.n
			end)
			return list
		elseif cmd == "clear" then
			table.clear(misses)
			stats.missed = 0
			return true
		elseif cmd == "translate" then
			return { Loc.translate(tostring(arg)) }
		end
		return { lang = Loc.lang(), stats = table.clone(stats) }
	end
	f.Parent = player
end

function LocalizationController:Init()
	local pg = player:WaitForChild("PlayerGui")
	pg.DescendantAdded:Connect(track)
	for _, d in pg:GetDescendants() do
		track(d)
	end
	workspace.DescendantAdded:Connect(worldAdded)
	Loc.Changed:Connect(retranslate)
	probe()
end

function LocalizationController:Start()
	-- world signs that existed before we connected (map, boards): chunked so a big map doesn't hitch
	local all = workspace:GetDescendants()
	for i, d in all do
		worldAdded(d)
		if i % 4000 == 0 then
			task.wait()
		end
	end
end

-- for other controllers / tests
function LocalizationController:Lang(): string
	return Loc.lang()
end

return LocalizationController
