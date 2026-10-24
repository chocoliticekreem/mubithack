--!strict
-- LeaderboardService: lifetime-earnings tracking, leaderstats guarantees and the in-world TOP TYCOONS board.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local NumberFormat = require(ReplicatedStorage:WaitForChild("NumberFormat"))
local PlotThemes = require(ReplicatedStorage:WaitForChild("PlotThemes"))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme"))

local ROWS = 10
local REFRESH = 5
local WAIT_TIMEOUT = 10

local totals: { [Player]: number } = {}
local conns: { [Player]: RBXScriptConnection } = {}

local function ensureValue(folder: Instance, name: string): IntValue
	local v = folder:FindFirstChild(name)
	if v and v:IsA("IntValue") then
		return v
	end
	local nv = Instance.new("IntValue")
	nv.Name = name
	nv.Value = 0
	nv.Parent = folder
	return nv
end

local function setupPlayer(player: Player)
	if totals[player] ~= nil then
		return
	end
	totals[player] = 0
	player:SetAttribute("TotalEarned", 0)

	local stats = player:WaitForChild("leaderstats", WAIT_TIMEOUT)
	if player.Parent == nil then
		return
	end
	if not stats then
		local f = Instance.new("Folder")
		f.Name = "leaderstats"
		f.Parent = player
		stats = f
	end
	local s = stats :: Instance
	s:WaitForChild("Cash", WAIT_TIMEOUT)
	s:WaitForChild("Rebirths", WAIT_TIMEOUT)
	if player.Parent == nil then
		return
	end
	local cash = ensureValue(s, "Cash")
	ensureValue(s, "Rebirths")

	local last = cash.Value
	conns[player] = cash.Changed:Connect(function(newValue)
		local delta = newValue - last
		last = newValue
		if delta > 0 and totals[player] ~= nil then
			totals[player] += delta
			player:SetAttribute("TotalEarned", totals[player])
		end
	end)
end

local function cleanupPlayer(player: Player)
	totals[player] = nil
	local c = conns[player]
	if c then
		c:Disconnect()
		conns[player] = nil
	end
end

-- Find the plaza centre from the shared PlotThemes module.
local function getPlazaCenter(): Vector3
	local plaza: any = (PlotThemes :: any).Plaza
	if typeof(plaza) == "Vector3" then
		return plaza
	elseif typeof(plaza) == "CFrame" then
		return plaza.Position
	elseif type(plaza) == "table" then
		for _, key in { "center", "Center", "centre", "position", "Position", "origin" } do
			local v = plaza[key]
			if typeof(v) == "Vector3" then
				return v
			elseif typeof(v) == "CFrame" then
				return v.Position
			end
		end
	end
	return Vector3.new(0, 0, 0)
end

local function makePart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.CanCollide = true
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

type Row = { rank: TextLabel, name: TextLabel, rebirths: TextLabel, earned: TextLabel }

local function buildBoard(): { Row }
	local deadline = os.clock() + WAIT_TIMEOUT
	while not Workspace:FindFirstChild("Plaza") and os.clock() < deadline do
		task.wait(0.5)
	end
	local center = getPlazaCenter()
	-- off the spawn path, clear of fountain (centre) and gate ring
	local pos = center + Vector3.new(20, 0, 14)
	local cf = CFrame.lookAt(pos, Vector3.new(center.X, pos.Y, center.Z))

	local model = Instance.new("Model")
	model.Name = "LeaderboardStand"

	makePart("Base", Vector3.new(15, 1, 4), cf * CFrame.new(0, 0.5, 0), UiTheme.accent, Enum.Material.SmoothPlastic, model)
	makePart("PostL", Vector3.new(1, 3, 1), cf * CFrame.new(-6.5, 2.5, 0.4), UiTheme.info, Enum.Material.SmoothPlastic, model)
	makePart("PostR", Vector3.new(1, 3, 1), cf * CFrame.new(6.5, 2.5, 0.4), UiTheme.info, Enum.Material.SmoothPlastic, model)
	makePart("Frame", Vector3.new(15, 17, 0.6), cf * CFrame.new(0, 10, 0.3), UiTheme.accent, Enum.Material.SmoothPlastic, model)
	local panel = makePart("BackPanel", Vector3.new(14, 16, 0.4), cf * CFrame.new(0, 10, -0.1), UiTheme.ink, Enum.Material.SmoothPlastic, model)

	local gui = Instance.new("SurfaceGui")
	gui.Name = "BoardGui"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(700, 800)
	gui.LightInfluence = 0
	gui.Parent = panel

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.fromScale(0.96, 0.1)
	title.Position = UDim2.fromScale(0.02, 0.01)
	title.BackgroundTransparency = 1
	title.Text = "TOP TYCOONS"
	title.TextScaled = true
	title.Font = UiTheme.headerFont
	title.TextColor3 = UiTheme.accent
	title.Parent = gui

	local rows: { Row } = {}
	for i = 1, ROWS do
		local frame = Instance.new("Frame")
		frame.Name = "Row" .. i
		frame.Size = UDim2.fromScale(0.96, 0.077)
		frame.Position = UDim2.fromScale(0.02, 0.125 + (i - 1) * 0.085)
		frame.BackgroundColor3 = UiTheme.cream
		frame.BackgroundTransparency = if i % 2 == 0 then 0.85 else 0.92
		frame.BorderSizePixel = 0
		frame.Parent = gui
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 8)
		corner.Parent = frame

		local function label(n: string, x: number, w: number, align: Enum.TextXAlignment, color: Color3): TextLabel
			local l = Instance.new("TextLabel")
			l.Name = n
			l.Size = UDim2.fromScale(w, 0.8)
			l.Position = UDim2.fromScale(x, 0.1)
			l.BackgroundTransparency = 1
			l.Text = "-"
			l.TextScaled = true
			l.Font = UiTheme.font
			l.TextColor3 = color
			l.TextXAlignment = align
			l.Parent = frame
			return l
		end
		local rankColor = if i <= 3 then UiTheme.accent else UiTheme.cream
		rows[i] = {
			rank = label("Rank", 0.01, 0.1, Enum.TextXAlignment.Center, rankColor),
			name = label("Name", 0.13, 0.42, Enum.TextXAlignment.Left, UiTheme.cream),
			rebirths = label("Rebirths", 0.56, 0.14, Enum.TextXAlignment.Center, UiTheme.info),
			earned = label("Earned", 0.72, 0.26, Enum.TextXAlignment.Right, UiTheme.good),
		}
		rows[i].rank.Text = tostring(i)
	end

	model.Parent = Workspace
	return rows
end

local function refresh(rows: { Row })
	local list: { { player: Player, total: number } } = {}
	for player, total in totals do
		if player.Parent == Players then
			table.insert(list, { player = player, total = total })
		end
	end
	table.sort(list, function(a, b)
		if a.total ~= b.total then
			return a.total > b.total
		end
		return a.player.Name < b.player.Name
	end)
	for i = 1, ROWS do
		local row = rows[i]
		local entry = list[i]
		if entry then
			local stats = entry.player:FindFirstChild("leaderstats")
			local rb = stats and stats:FindFirstChild("Rebirths")
			local rebirths = if rb and rb:IsA("IntValue") then rb.Value else 0
			row.name.Text = entry.player.Name
			row.rebirths.Text = "R" .. tostring(rebirths)
			row.earned.Text = "$" .. NumberFormat.short(entry.total)
		else
			row.name.Text = "-"
			row.rebirths.Text = "-"
			row.earned.Text = "-"
		end
	end
	ForgeTelemetry.count("leaderboard_refresh", 1)
end

Players.PlayerAdded:Connect(function(player)
	task.spawn(setupPlayer, player)
end)
Players.PlayerRemoving:Connect(cleanupPlayer)
for _, player in Players:GetPlayers() do
	task.spawn(setupPlayer, player)
end

task.spawn(function()
	local rows = buildBoard()
	while true do
		local ok, err = pcall(refresh, rows)
		if not ok then
			warn("LeaderboardService refresh failed: " .. tostring(err))
		end
		task.wait(REFRESH)
	end
end)
