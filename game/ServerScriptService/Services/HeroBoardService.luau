--!strict
-- HeroBoardService [owner: Social]. TODAY'S TOP HEROES: the big flex board on the station front (Tizyz
-- rule #3, "leaderboards, visible flex"). A 24 x 9.6 stud board on the west wing facade, over the
-- "STATION 67 - EST. 1967" sign and right of the LOCKER door, so it never blocks the pads, the PICK A
-- MISSION board or the door: seen from the START row and the pads, and walking back from a call. Two
-- columns, RESCUES and FIRES OUT, top TeamRules.Cfg.HeroTopN each, with avatar headshots and big numbers.
-- The subtitle alternates EVERY SERVER (OrderedDataStores with a daily UTC key, IncrementAsync so several
-- servers add up) and THIS SERVER (live counts of the players here).
-- Also classic leaderstats (Rescues, Fires = today's numbers), so the player list shows the flex.
-- Counts: RescueService.Rescued (the rescuer) and FireService.Extinguished (whoever put that part out).
--
-- Public API: HeroBoardService:GetToday(player): (rescues: number, fires: number)
--             HeroBoardService:GetTop(stat: "rescues" | "fires", which: "global" | "server"): { Row }
-- Consumes (nil-guarded): RescueService.Rescued, FireService.Extinguished, DataService:IsPersistent,
--   MapService.LocationBuilt / :GetLocation ("Station"; station model attr StationOrigin)
-- Writes: Model "HeroBoard" in the Station location; Player Folder "leaderstats" (IntValue Rescues, Fires);
--   OrderedDataStores FlameAndBlameHero_<stat>_d<dayId> (persistent servers only; Studio = memory)
-- Counters: hero_board_refreshes, hero_board_writes
-- Test hooks (DevHook only): _add(player, stat, n), _refresh(), _mode("global"|"server"),
--   _seed(stat, userId, value, name?) (memory board only), _selftest()
local DataStoreService = game:GetService("DataStoreService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local TeamRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Social"):WaitForChild("TeamRules") :: ModuleScript)

local HeroBoardService = {}
HeroBoardService.Priority = 80

local STORE_PREFIX = "FlameAndBlameHero_"
local STATS = { "rescues", "fires" }
local TITLES = { rescues = "RESCUES", fires = "FIRES OUT" }
local LEADERSTAT = { rescues = "Rescues", fires = "Fires" }
local REFRESH_SECONDS = 60
local CYCLE_SECONDS = 8
-- station-local placement (StationBuilder coords: wing facade at Z 29.5, street = +Z)
local BOARD_CF = CFrame.new(-35.5, 18.6, 31.0) * CFrame.Angles(0, math.pi, 0) -- Front face looks at the street
local BOARD_SIZE = Vector3.new(24, 9.6, 0.6)
local PPS = 40

type Row = { userId: number, value: number, name: string? }
type Today = { rescues: number, fires: number }
type RowUi = { frame: Frame, rank: TextLabel, face: ImageLabel, initial: TextLabel, name: TextLabel, value: TextLabel }

local services: { [string]: any } = {}
local persistent = false
local day = TeamRules.dayId(os.time())
local today: { [number]: Today } = {}
local pending: { [number]: Today } = {}
local global: { [string]: { Row } } = { rescues = {}, fires = {} }
local memory: { [string]: { [number]: number } } = {} -- non-persistent "global" store
local names: { [number]: string } = {}
local mode: "global" | "server" = "global"
local ui: { sub: TextLabel?, rows: { [string]: { RowUi } } } = { sub = nil, rows = {} }

----------------------------------------------------------------------------------------- counts

local function storeName(stat: string, d: number): string
	return `{STORE_PREFIX}{stat}_d{d}`
end

local function rollDay()
	local d = TeamRules.dayId(os.time())
	if d == day then
		return
	end
	day = d
	today, pending, memory = {}, {}, {}
	global = { rescues = {}, fires = {} }
	for _, p in Players:GetPlayers() do
		local ls = p:FindFirstChild("leaderstats")
		for _, stat in STATS do
			local v = ls and ls:FindFirstChild(LEADERSTAT[stat])
			if v and v:IsA("IntValue") then
				v.Value = 0
			end
		end
	end
end

local function todayOf(userId: number): Today
	local t = today[userId] or { rescues = 0, fires = 0 }
	today[userId] = t
	return t
end

local function add(player: Player, stat: string, n: number)
	rollDay()
	local t = todayOf(player.UserId) :: any
	t[stat] += n
	local p = pending[player.UserId] or { rescues = 0, fires = 0 }
	pending[player.UserId] = p;
	(p :: any)[stat] += n
	names[player.UserId] = player.DisplayName
	local ls = player:FindFirstChild("leaderstats")
	local v = ls and ls:FindFirstChild(LEADERSTAT[stat])
	if v and v:IsA("IntValue") then
		v.Value = t[stat]
	end
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
	n = n or "Firefighter"
	names[userId] = n
	return n :: string
end

local function flush()
	local toWrite = pending
	pending = {}
	for userId, delta in toWrite do
		for _, stat in STATS do
			local n = (delta :: any)[stat]
			if n > 0 then
				if persistent then
					local ok, err = pcall(function()
						DataStoreService:GetOrderedDataStore(storeName(stat, day)):IncrementAsync(tostring(userId), n)
					end)
					if not ok then
						warn(`[HeroBoardService] write {stat}: {err}`)
					end
				else
					local m = memory[stat] or {}
					memory[stat] = m
					m[userId] = (m[userId] or 0) + n
				end
				Telemetry.count("hero_board_writes")
			end
		end
	end
end

local function readGlobal()
	local n = TeamRules.Cfg.HeroTopN
	for _, stat in STATS do
		local rows: { Row } = {}
		if persistent then
			local ok, page = pcall(function()
				return DataStoreService:GetOrderedDataStore(storeName(stat, day)):GetSortedAsync(false, n):GetCurrentPage()
			end)
			if ok and type(page) == "table" then
				for _, item in page do
					local id = tonumber(item.key)
					if id then
						table.insert(rows, { userId = id, value = item.value })
					end
				end
			elseif not ok then
				warn(`[HeroBoardService] read {stat}: {page}`)
				continue
			end
		else
			for id, v in memory[stat] or {} do
				table.insert(rows, { userId = id, value = v })
			end
		end
		rows = TeamRules.mergeTop(rows, n) :: any
		for _, r in rows do
			r.name = nameOf(r.userId)
		end
		global[stat] = rows
	end
end

local function serverTop(stat: string): { Row }
	local rows: { Row } = {}
	for _, p in Players:GetPlayers() do
		local t = today[p.UserId]
		if t then
			table.insert(rows, { userId = p.UserId, value = (t :: any)[stat], name = p.DisplayName })
		end
	end
	return TeamRules.mergeTop(rows, TeamRules.Cfg.HeroTopN) :: any
end

-------------------------------------------------------------------------------------------- UI

local function render()
	if ui.sub then
		ui.sub.Text = if mode == "global" then "ALL SERVERS TODAY" else "THIS SERVER NOW"
	end
	for stat, rowsUi in ui.rows do
		local rows = if mode == "global" then global[stat] else serverTop(stat)
		for i, r in rowsUi do
			local row = rows[i]
			r.frame.Visible = row ~= nil or i == 1
			r.face.Visible = row ~= nil
			if row then
				r.rank.Text = tostring(i)
				r.name.Text = row.name or "Firefighter"
				r.value.Text = tostring(row.value)
				if row.userId > 0 then
					r.face.Image = `rbxthumb://type=AvatarHeadShot&id={row.userId}&w=150&h=150`
					r.initial.Text = ""
				else
					r.face.Image = "" -- Studio test players have no avatar: show their initial
					r.initial.Text = string.upper(string.sub(row.name or "?", 1, 1))
				end
			else
				r.rank.Text = ""
				r.face.Image = ""
				r.initial.Text = ""
				r.name.Text = "Be the first hero!"
				r.value.Text = ""
			end
		end
	end
end

local function label(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, font: Enum.Font, color: Color3, align: Enum.TextXAlignment?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = font
	l.TextScaled = true
	l.TextColor3 = color
	l.Text = text
	l.TextXAlignment = align or Enum.TextXAlignment.Left
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Palette.UiInk
	stroke.Parent = l
	l.Parent = parent
	return l
end

local function corner(parent: Instance, scale: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(scale, 0)
	c.Parent = parent
end

local function buildBoard(station: Model?)
	local parent: Instance = station or workspace
	local old = parent:FindFirstChild("HeroBoard")
	if old then
		old:Destroy()
	end
	local so = station and station:GetAttribute("StationOrigin")
	local origin: CFrame = if typeof(so) == "CFrame" then so else CFrame.new()
	local cf = origin * BOARD_CF

	local model = Instance.new("Model")
	model.Name = "HeroBoard"
	local frame = Instance.new("Part")
	frame.Name = "Frame"
	frame.Anchored = true
	frame.CanCollide = false
	frame.CastShadow = false
	frame.Size = BOARD_SIZE + Vector3.new(0.8, 0.8, -0.2)
	frame.CFrame = cf * CFrame.new(0, 0, 0.2) -- behind the face (towards the wall)
	frame.Color = Palette.HelmetShield
	frame.Material = Enum.Material.SmoothPlastic
	frame.Parent = model
	local part = Instance.new("Part")
	part.Name = "Board"
	part.Anchored = true
	part.CanCollide = false
	part.CastShadow = false
	part.Size = BOARD_SIZE
	part.CFrame = cf
	part.Color = Palette.UiPanelDark
	part.Material = Enum.Material.SmoothPlastic
	part.Parent = model

	local gui = Instance.new("SurfaceGui")
	gui.Name = "HeroGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = PPS
	gui.LightInfluence = 0
	gui.MaxDistance = 400
	gui.Parent = part

	local band = Instance.new("Frame")
	band.Name = "TitleBand"
	band.Size = UDim2.fromScale(1, 0.2)
	band.BackgroundColor3 = Palette.TruckRed
	band.BorderSizePixel = 0
	band.Parent = gui
	label(band, "Title", "TODAY'S TOP HEROES", UDim2.fromScale(0.64, 0.84), UDim2.fromScale(0.02, 0.08), Enum.Font.LuckiestGuy, Palette.UiCream)
	ui.sub = label(band, "Sub", "", UDim2.fromScale(0.32, 0.5), UDim2.fromScale(0.66, 0.25), Enum.Font.LuckiestGuy, Palette.HelmetShield, Enum.TextXAlignment.Right)
	ui.rows = {}

	for c, stat in STATS do
		local col = Instance.new("Frame")
		col.Name = stat
		col.BackgroundTransparency = 1
		col.Size = UDim2.fromScale(0.48, 0.78)
		col.Position = UDim2.fromScale(0.013 + (c - 1) * 0.495, 0.215)
		col.Parent = gui
		label(col, "Head", TITLES[stat], UDim2.fromScale(1, 0.15), UDim2.fromScale(0, 0), Enum.Font.LuckiestGuy,
			if stat == "rescues" then Palette.UiGood else Palette.FireEdge, Enum.TextXAlignment.Center)
		local list: { RowUi } = {}
		local n = TeamRules.Cfg.HeroTopN
		local rowH = 0.84 / n
		for i = 1, n do
			local f = Instance.new("Frame")
			f.Name = `Row{i}`
			f.Size = UDim2.fromScale(1, rowH * 0.9)
			f.Position = UDim2.fromScale(0, 0.16 + (i - 1) * rowH)
			f.BackgroundColor3 = if i == 1 then Palette.HelmetShield else Color3.new(1, 1, 1)
			f.BackgroundTransparency = if i == 1 then 0.55 else 0.9
			f.BorderSizePixel = 0
			corner(f, 0.25)
			f.Parent = col
			local rank = label(f, "Rank", "", UDim2.fromScale(0.08, 0.9), UDim2.fromScale(0.01, 0.05), Enum.Font.LuckiestGuy,
				if i == 1 then Palette.HelmetShield else Palette.UiCream, Enum.TextXAlignment.Center)
			local face = Instance.new("ImageLabel")
			face.Name = "Face"
			face.Position = UDim2.fromScale(0.1, 0.03)
			face.SizeConstraint = Enum.SizeConstraint.RelativeYY
			face.Size = UDim2.fromScale(0.94, 0.94)
			face.BackgroundColor3 = Palette.UiWater
			face.BorderSizePixel = 0
			corner(face, 0.5)
			face.Parent = f
			local initial = label(face, "Initial", "", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Enum.Font.LuckiestGuy, Palette.UiCream, Enum.TextXAlignment.Center)
			local name = label(f, "Name", "", UDim2.fromScale(0.54, 0.7), UDim2.fromScale(0.24, 0.15), Enum.Font.FredokaOne, Palette.UiCream)
			local value = label(f, "Value", "", UDim2.fromScale(0.2, 0.96), UDim2.fromScale(0.78, 0.02), Enum.Font.LuckiestGuy,
				if stat == "rescues" then Palette.UiGood else Palette.FireEdge, Enum.TextXAlignment.Right)
			table.insert(list, { frame = f, rank = rank, face = face, initial = initial, name = name, value = value })
		end
		ui.rows[stat] = list
	end
	model.Parent = parent
	render()
end

------------------------------------------------------------------------------------- players

local function setupPlayer(player: Player)
	if player:FindFirstChild("leaderstats") then
		return
	end
	local ls = Instance.new("Folder")
	ls.Name = "leaderstats"
	for _, stat in STATS do
		local v = Instance.new("IntValue")
		v.Name = LEADERSTAT[stat]
		v.Value = 0
		v.Parent = ls
	end
	ls.Parent = player
	names[player.UserId] = player.DisplayName
	if persistent and player.UserId > 0 then
		-- seed with what they did today on other servers
		task.spawn(function()
			for _, stat in STATS do
				local ok, v = pcall(function()
					return DataStoreService:GetOrderedDataStore(storeName(stat, day)):GetAsync(tostring(player.UserId))
				end)
				if ok and type(v) == "number" and v > 0 and player.Parent == Players then
					local t = todayOf(player.UserId) :: any
					local pend = (pending[player.UserId] or {}) :: any
					t[stat] = math.max(t[stat], v + (pend[stat] or 0)) -- v already holds what we flushed
					local iv = ls:FindFirstChild(LEADERSTAT[stat])
					if iv and iv:IsA("IntValue") then
						iv.Value = t[stat]
					end
				end
			end
		end)
	end
end

------------------------------------------------------------------------------------------- API

function HeroBoardService:GetToday(player: Player): (number, number)
	local t = today[player.UserId]
	return if t then t.rescues else 0, if t then t.fires else 0
end

function HeroBoardService:GetTop(stat: string, which: string): { Row }
	return if which == "server" then serverTop(stat) else (global[stat] or {})
end

function HeroBoardService:Refresh()
	rollDay()
	local ok, err = pcall(function()
		flush()
		readGlobal()
	end)
	if not ok then
		warn(`[HeroBoardService] refresh: {err}`)
	end
	Telemetry.count("hero_board_refreshes")
	render()
end

function HeroBoardService:Init(all: { [string]: any })
	services = all
end

function HeroBoardService:Start()
	local Data = services.DataService
	persistent = Data ~= nil and type(Data.IsPersistent) == "function" and Data:IsPersistent() == true
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(function(p: Player)
		task.defer(render)
	end)

	local Rescue = services.RescueService
	if Rescue and Rescue.Rescued then
		Rescue.Rescued:Connect(function(who: Player?)
			if who and who.Parent == Players then
				add(who, "rescues", 1)
				render()
			end
		end)
	end
	local Fire = services.FireService
	if Fire and Fire.Extinguished then
		Fire.Extinguished:Connect(function(_part: BasePart, by: Player?)
			if by and by.Parent == Players then
				add(by, "fires", 1)
				if mode == "server" then
					render()
				end
			end
		end)
	end

	local Map = services.MapService
	if Map and Map.LocationBuilt then
		Map.LocationBuilt:Connect(function(model: Model, id: string)
			if id == "Station" then
				buildBoard(model)
			end
		end)
	end
	local existing = Map and type(Map.GetLocation) == "function" and Map:GetLocation("Station")
	if existing then
		buildBoard(existing)
	elseif not Map then
		buildBoard(nil)
	end

	task.spawn(function()
		while true do
			task.wait(CYCLE_SECONDS)
			mode = if mode == "global" then "server" else "global"
			render()
		end
	end)
	game:BindToClose(function()
		pcall(flush)
	end)
	task.wait(5)
	while true do
		self:Refresh()
		task.wait(REFRESH_SECONDS)
	end
end

-------------------------------------------------------------------------------------- test hooks

function HeroBoardService:_add(player: Player, stat: string, n: number): string
	add(player, stat, n)
	render()
	local r, f = self:GetToday(player)
	return `{player.Name}: rescues={r} fires={f}`
end

function HeroBoardService:_refresh(): string
	self:Refresh()
	local out = {}
	for _, stat in STATS do
		local rows = global[stat]
		table.insert(out, `{stat}={#rows}` .. (if rows[1] then `({rows[1].name}:{rows[1].value})` else ""))
	end
	return table.concat(out, " ") .. ` persistent={persistent} day={day}`
end

-- fake heroes for screenshots / board layout checks (memory board only; never touches DataStores)
function HeroBoardService:_seed(stat: string, userId: number, value: number, name: string?): string
	if persistent then
		return "refused: persistent server"
	end
	local m = memory[stat] or {}
	memory[stat] = m
	m[userId] = value
	names[userId] = name or names[userId]
	readGlobal()
	render()
	return `{stat} {userId}={value}`
end

function HeroBoardService:_mode(m: string): string
	mode = if m == "server" then "server" else "global"
	render()
	return mode
end

function HeroBoardService:_selftest(): (boolean, string)
	local board = nil
	for _, d in workspace:GetDescendants() do
		if d.Name == "HeroBoard" and d:IsA("Model") then
			board = d
			break
		end
	end
	if not board then
		return false, "no HeroBoard in Workspace"
	end
	for _, p in Players:GetPlayers() do
		if not p:FindFirstChild("leaderstats") then
			return false, `{p.Name} has no leaderstats`
		end
	end
	return true, `ok persistent={persistent}`
end

return HeroBoardService
