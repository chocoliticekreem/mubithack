--!strict
-- LocTableService [owner: Localization]. Builds one LocalizationTable ("ForgeStrings") from the hand-written
-- Config/Translations/<lang>.luau tables at server start and parents it under LocalizationService, the
-- place Roblox's own AutoLocalize reads from. That makes the same translations reach text our client
-- watcher never sees (anything Roblox renders itself) and keeps one source of truth: the Luau tables.
-- Only plain keys go in (Roblox matches whole strings); templates ("FIRES LEFT  {1}") are matched by
-- Controllers/LocalizationController on each client. game/tools/loc_csv.py exports the same data as a CSV
-- for the Creator Dashboard (Localization -> upload), so the cloud table can carry it too.
local LocalizationService = game:GetService("LocalizationService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LocTableService = {}
LocTableService.Priority = 5

local TABLE_NAME = "ForgeStrings"

local built = 0

local function build(): number
	local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript) :: any
	local LocCore = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("LocCore") :: ModuleScript) :: any
	local folder = ReplicatedStorage:WaitForChild("Config"):WaitForChild("Translations")
	local keys = require(folder:WaitForChild("Keys") :: ModuleScript) :: { string }
	local dicts: { [string]: { [string]: string } } = {}
	for _, lang in Loc.Languages do
		local m = folder:FindFirstChild(lang)
		if m and m:IsA("ModuleScript") then
			local ok, d = pcall(require, m)
			if ok and type(d) == "table" then
				dicts[lang] = d :: any
			end
		end
	end
	local entries = {}
	for _, key in keys do
		if LocCore.isTemplate(key) then
			continue
		end
		local values: { [string]: string } = {}
		local any = false
		for lang, d in dicts do
			local v = d[key]
			if type(v) == "string" and v ~= "" and v ~= key then
				values[lang] = v
				any = true
			end
		end
		if any then
			table.insert(entries, { Key = "", Context = "", Example = "", Source = key, Values = values })
		end
	end
	local old = LocalizationService:FindFirstChild(TABLE_NAME)
	if old then
		old:Destroy()
	end
	local t = Instance.new("LocalizationTable")
	t.Name = TABLE_NAME
	t.SourceLocaleId = "en-us"
	t:SetEntries(entries)
	t.Parent = LocalizationService
	return #entries
end

function LocTableService:Init() end

function LocTableService:Start()
	local ok, n = pcall(build)
	if ok then
		built = n :: number
	else
		warn(`[LocTableService] build failed: {n}`)
	end
end

function LocTableService:Count(): number
	return built
end

return LocTableService
