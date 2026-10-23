--!strict
-- LeaderboardService [owner: Data]. Weekly + all-time OrderedDataStore boards for rescues, blame
-- points and missions played, shown on a physical board (SurfaceGui) in the station lobby and
-- refreshed every DataConfig.Leaderboard.RefreshSeconds. Contract: docs/game/06-data.md.
--
-- Public API:
--   LeaderboardService:GetTop(stat: string, period: "all" | "week"): { { userId: number, name: string, value: number } }
--   LeaderboardService:Refresh()                       -- flush pending scores + re-read the boards now
-- Consumes (nil-guarded): DataService.StatsChanged / .ProfileLoaded / :GetProfile / :IsPersistent,
--   MapService.LocationBuilt / :GetLocation
-- Writes: Model "Leaderboard" (part "Board" + SurfaceGui) inside the lobby location Model;
--         OrderedDataStores <StorePrefix><stat>_all and <StorePrefix><stat>_w<weekId>
-- Counters: leaderboard_refreshes, leaderboard_writes
-- Test hooks (DevHook only): _refresh(), _selftest()

local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = ReplicatedStorage:WaitForChild("Config")
local DataConfig = require(Config:WaitForChild("DataConfig") :: ModuleScript) :: any
local MapConfig = require(Config:WaitForChild("MapConfig") :: ModuleScript) :: any
local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Schema = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

type Row = { userId: number, name: string, value: number }
type Board = {
	set: (key: string, value: number) -> boolean,
	top: (n: number) -> { { key: string, value: number } }?,
}

local LeaderboardService = {}
LeaderboardService.Priority = 80

local services: { [string]: any } = {}
local persistent = false
local boards: { [string]: Board } = {} -- by store name
local memoryBoards: { [string]: { [string]: number } } = {}
local pending: { [number]: { week: number, all: { [string]: number }, weekly: { [string]: number } } } = {}
local cache: { all: { [string]: { Row } }, week: { [string]: { Row } } } = { all = {}, week = {} }
local names: { [number]: string } = {}
local period: "all" | "week" = "week"
local refreshing = false

-- Board UI handles (rebuilt with the lobby location).
local ui: { period: TextLabel?, cols: { [string]: { TextLabel } } } = { period = nil, cols = {} }

----------------------------------------------------------------------------------------- stores

local function storeName(stat: string, which: "all" | "week", week: number): string
	local L = DataConfig.Leaderboard
	return if which == "all" then `{L.StorePrefix}{stat}_all` else `{L.StorePrefix}{stat}_w{week}`
end

local function budget(kind: Enum.DataStoreRequestType)
	if not persistent then
		return
	end
	local deadline = os.clock() + 5
	while os.clock() < deadline do
		local ok, b = pcall(function()
			return DataStoreService:GetRequestBudgetForRequestType(kind)
		end)
		if not ok or b >= 1 then
			return
		end
		task.wait(0.5)
	end
end

local function board(name: string): Board
	local b = boards[name]
	if b then
		return b
	end
	if persistent then
		local ods = DataStoreService:GetOrderedDataStore(name)
		b = {
			set = function(key: string, value: number): boolean
				budget(Enum.DataStoreRequestType.SetIncrementSortedAsync)
				local ok, err = pcall(function()
					ods:SetAsync(key, value)
				end)
				if not ok then
					warn(`[LeaderboardService] {name} set: {err}`)
				end
				return ok
			end,
			top = function(n: number)
				budget(Enum.DataStoreRequestType.GetSortedAsync)
				local ok, page = pcall(function()
					return ods:GetSortedAsync(false, n):GetCurrentPage()
				end)
				if not ok then
					warn(`[LeaderboardService] {name} read: {page}`)
					return nil
				end
				return page :: any
			end,
		}
	else
		local mem = memoryBoards[name] or {}
		memoryBoards[name] = mem
		b = {
			set = function(key: string, value: number): boolean
				mem[key] = value
				return true
			end,
			top = function(n: number)
				local list = {}
				for k, v in mem do
					table.insert(list, { key = k, value = v })
				end
				table.sort(list, function(a, c)
					return a.value > c.value
				end)
				while #list > n do
					table.remove(list)
				end
				return list
			end,
		}
	end
	boards[name] = b :: Board
	return b :: Board
end

------------------------------------------------------------------------------------------ scores

local function statsOf(p: Schema.Profile): ({ [string]: number }, { [string]: number })
	local rescues = 0
	for _, n in p.rescued do
		rescues += n
	end
	return { rescues = rescues, blamePoints = p.blamePoints, missions = p.missionsPlayed },
		{ rescues = p.weekly.rescues, blamePoints = p.weekly.blamePoints, missions = p.weekly.missions }
end

local function snapshot(player: Player)
	local Data = services.DataService
	local p = Data and Data:GetProfile(player)
	if not p then
		return
	end
	names[player.UserId] = player.DisplayName
	local all, weekly = statsOf(p)
	pending[player.UserId] = { week = p.weekly.week, all = all, weekly = weekly }
end

local function nameOf(userId: number): string
	local n = names[userId]
	if n then
		return n
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		n = player.DisplayName
	elseif userId > 0 then
		local ok, res = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		n = if ok then res else nil
	end
	n = n or `Firefighter {userId}`
	names[userId] = n
	return n :: string
end

local function flush()
	local toWrite = pending
	pending = {}
	for userId, entry in toWrite do
		local key = tostring(userId)
		for _, stat in DataConfig.Leaderboard.Stats do
			if (entry.all[stat] or 0) > 0 then
				board(storeName(stat, "all", 0)).set(key, entry.all[stat])
				Telemetry.count("leaderboard_writes")
			end
			if (entry.weekly[stat] or 0) > 0 then
				board(storeName(stat, "week", entry.week)).set(key, entry.weekly[stat])
				Telemetry.count("leaderboard_writes")
			end
		end
	end
end

local function read()
	local week = Schema.weekId(os.time())
	for _, which in { "all", "week" } :: { "all" | "week" } do
		for _, stat in DataConfig.Leaderboard.Stats do
			local page = board(storeName(stat, which, week)).top(DataConfig.Leaderboard.TopN)
			if page then
				local rows: { Row } = {}
				for _, item in page do
					local userId = tonumber(item.key)
					if userId then
						table.insert(rows, { userId = userId, name = nameOf(userId), value = item.value })
					end
				end
				cache[which][stat] = rows
			end
		end
	end
end

-------------------------------------------------------------------------------------------- UI

local function render()
	if ui.period then
		ui.period.Text = if period == "week" then "THIS WEEK" else "ALL TIME"
	end
	for stat, labels in ui.cols do
		local rows = cache[period][stat] or {}
		for i, label in labels do
			local r = rows[i]
			local safe = if r then string.gsub(string.gsub(r.name, "&", "&amp;"), "<", "&lt;") else ""
			label.Text = if r then `{i}. {safe}  <b>{r.value}</b>` else (if i == 1 then "nobody yet!" else "")
		end
	end
end

local function text(parent: Instance, name: string, t: string, size: UDim2, pos: UDim2, font: Enum.Font, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = font
	l.TextScaled = true
	l.RichText = true
	l.TextColor3 = color
	l.Text = t
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Parent = parent
	return l
end

local function buildBoard(location: Model?)
	local L = DataConfig.Leaderboard
	local parent: Instance = location or workspace
	local old = parent:FindFirstChild("Leaderboard")
	if old then
		old:Destroy()
	end
	local origin = MapConfig.SlotOrigin(L.Slot) * L.Offset

	local model = Instance.new("Model")
	model.Name = "Leaderboard"
	local part = Instance.new("Part")
	part.Name = "Board"
	part.Anchored = true
	part.Size = L.Size
	part.CFrame = origin
	part.Color = Palette.UiPanelDark
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = model
	local frame = Instance.new("Part")
	frame.Name = "Frame"
	frame.Anchored = true
	frame.CanCollide = false
	frame.Size = L.Size + Vector3.new(0.8, 0.8, -0.2)
	frame.CFrame = origin * CFrame.new(0, 0, 0.2)
	frame.Color = Palette.BookshelfWood
	frame.Parent = model
	for _, sx in { -1, 1 } do
		local leg = Instance.new("Part")
		leg.Name = "Leg"
		leg.Anchored = true
		leg.Size = Vector3.new(0.6, origin.Position.Y, 0.6)
		leg.CFrame = origin * CFrame.new(sx * (L.Size.X / 2 - 1), -origin.Position.Y / 2 + 0.3, 0.4)
		leg.Color = Palette.TruckChrome
		leg.Parent = model
	end

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 50
	gui.LightInfluence = 0
	gui.Parent = part

	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0.03, 0)
	pad.PaddingRight = UDim.new(0.03, 0)
	pad.PaddingTop = UDim.new(0.03, 0)
	pad.Parent = gui

	local title = text(gui, "Title", "STATION 67 LEGENDS", UDim2.fromScale(0.65, 0.13), UDim2.fromScale(0, 0), Enum.Font.LuckiestGuy, Palette.UiCream)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local per = text(gui, "Period", "THIS WEEK", UDim2.fromScale(0.33, 0.1), UDim2.fromScale(0.65, 0.02), Enum.Font.LuckiestGuy, Palette.HelmetShield)
	per.TextXAlignment = Enum.TextXAlignment.Right
	ui.period = per
	ui.cols = {}

	local stats = L.Stats
	local colW = 1 / #stats
	for c, stat in stats do
		local col = Instance.new("Frame")
		col.Name = stat
		col.BackgroundTransparency = 1
		col.Size = UDim2.fromScale(colW - 0.02, 0.82)
		col.Position = UDim2.fromScale((c - 1) * colW, 0.16)
		col.Parent = gui
		local head = text(col, "Head", L.Titles[stat] or stat, UDim2.fromScale(1, 0.12), UDim2.fromScale(0, 0), Enum.Font.LuckiestGuy,
			if stat == "blamePoints" then Palette.UiRed else Palette.UiWater)
		head.TextXAlignment = Enum.TextXAlignment.Center
		local labels: { TextLabel } = {}
		local rowH = 0.84 / L.TopN
		for i = 1, L.TopN do
			table.insert(labels, text(col, `Row{i}`, "", UDim2.fromScale(1, rowH * 0.9), UDim2.fromScale(0, 0.15 + (i - 1) * rowH), Enum.Font.FredokaOne, Palette.UiCream))
		end
		ui.cols[stat] = labels
	end

	model.Parent = parent
	render()
end

------------------------------------------------------------------------------------------- API

function LeaderboardService:GetTop(stat: string, which: "all" | "week"): { Row }
	return (cache[which] or {})[stat] or {}
end

function LeaderboardService:Refresh()
	if refreshing then
		return
	end
	refreshing = true
	local ok, err = pcall(function()
		for _, player in Players:GetPlayers() do
			snapshot(player)
		end
		flush()
		read()
	end)
	refreshing = false
	if not ok then
		warn(`[LeaderboardService] refresh: {err}`)
	end
	Telemetry.count("leaderboard_refreshes")
	render()
end

function LeaderboardService:Init(all: { [string]: any })
	services = all
end

function LeaderboardService:Start()
	local Data = services.DataService
	persistent = Data ~= nil and type(Data.IsPersistent) == "function" and Data:IsPersistent()
	if Data then
		if Data.StatsChanged then
			Data.StatsChanged:Connect(snapshot)
		end
		if Data.ProfileLoaded then
			Data.ProfileLoaded:Connect(snapshot)
		end
	end
	Players.PlayerRemoving:Connect(snapshot) -- last scores before DataService drops the profile

	local L = DataConfig.Leaderboard
	local Map = services.MapService
	if Map then
		if Map.LocationBuilt then
			Map.LocationBuilt:Connect(function(model: Model, id: string)
				if id == L.LocationId then
					buildBoard(model)
				end
			end)
		end
		local existing = type(Map.GetLocation) == "function" and Map:GetLocation(L.LocationId)
		if existing then
			buildBoard(existing)
		end
	else
		buildBoard(nil)
	end

	task.spawn(function()
		while true do
			task.wait(L.CycleSeconds)
			period = if period == "week" then "all" else "week"
			render()
		end
	end)

	task.wait(5) -- let profiles load so the first board isn't empty
	while true do
		self:Refresh()
		task.wait(L.RefreshSeconds)
	end
end

function LeaderboardService:_refresh(): string
	self:Refresh()
	local out = {}
	for _, which in { "week", "all" } do
		for _, stat in DataConfig.Leaderboard.Stats do
			local rows = cache[which][stat] or {}
			table.insert(out, `{which}.{stat}={#rows}` .. (if rows[1] then `({rows[1].name}:{rows[1].value})` else ""))
		end
	end
	return table.concat(out, " ")
end

function LeaderboardService:_selftest(): (boolean, string)
	-- Memory board ordering (never touches real stores).
	local wasPersistent = persistent
	persistent = false
	local b = board("__selftest")
	b.set("1", 5)
	b.set("2", 50)
	b.set("3", 20)
	local top = b.top(2)
	persistent = wasPersistent
	boards["__selftest"] = nil
	memoryBoards["__selftest"] = nil
	if not top or #top ~= 2 or top[1].key ~= "2" or top[2].key ~= "3" then
		return false, "memory board order wrong"
	end
	local hasBoard = false
	for _, d in workspace:GetDescendants() do
		if d.Name == "Leaderboard" and d:IsA("Model") then
			hasBoard = true
			break
		end
	end
	return hasBoard, if hasBoard then `ok persistent={persistent}` else "no Leaderboard model in Workspace"
end

return LeaderboardService
