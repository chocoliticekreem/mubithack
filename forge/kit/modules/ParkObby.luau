--!nonstrict
-- ParkObby (Forge kit, prebuilt): the whole wiring of a themed park obby, tested once, so a first build
-- works end to end: WorldKit builds the park (lobby, START stairs, one ride per zone), ObbyKit lays the
-- course into it (ObbyThemes dresses every piece), the lobby has a working changing room (Cosmetics), music
-- follows the zone (MusicPlayer), and the HUD shows zone, stage, progress and coins. A game supplies only content:
--   Config (ReplicatedStorage/Config.luau) = {
--     Title = "Funfair Frenzy",
--     Zones = { { name = "Candy Carousel", theme = "carousel", palette = { "#FF7EB6", "#FFD23F" }, mood = "carnival" }, ... },
--     Costumes = { "MouseEars", "TopHat", ... }, Prices = { TopHat = 0, ClownWig = 10 }, Rewards = { "ChampionCape" },
--     AutoEquip = "MouseEars", FinishReward = "ChampionCape", Seed = 7, ParkSize = 1600, AllowSkip = false,
--   }
--   ServerScriptService/Game.server.luau: ParkObby.startServer(require(ReplicatedStorage.Config))
--   StarterPlayerScripts/Game.client.luau: ParkObby.startClient(require(ReplicatedStorage.Config))
-- Every kit it uses is required. A park obby that boots without its park, its costumes or its music is the
-- failure this module exists to prevent, so a missing or broken kit stops the game at boot and names the kit.
-- One coin ledger (ObbyKit's): Cosmetics spends through ObbyKit.coins/spend. One zone table (Config.Zones):
-- the HUD and the music read the zone number ObbyKit publishes and take the name from Config.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ParkObby = {}

local function kit(name: string): any
	local folder = ReplicatedStorage:FindFirstChild("Kit") or ReplicatedStorage:WaitForChild("Kit", 10)
	local mod = folder and (folder:FindFirstChild(name) or folder:WaitForChild(name, 10))
	if not mod then
		error("[ParkObby] missing kit module ReplicatedStorage.Kit." .. name .. " (the park obby needs it)")
	end
	local ok, res = pcall(require, mod)
	if not ok then
		error("[ParkObby] kit module " .. name .. " failed to load: " .. tostring(res))
	end
	return res
end

local function telemetry(name: string, n: number?)
	local mod = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if mod then
		local ok, T = pcall(require, mod)
		if ok and T and T.count then
			pcall(T.count, name, n or 1)
		end
	end
end

local function hex(s: any, fallback: Color3): Color3
	if typeof(s) == "Color3" then
		return s
	end
	local ok, c = pcall(Color3.fromHex, tostring(s or ""))
	return if ok then c else fallback
end

-- ------------------------------------------------------------------------------------------------ server

-- WorldKit makes the park's one spawn ("ParkSpawn", in the lobby); any other spawn (a template baseplate's)
-- would drop new players outside the park.
local function onlyParkSpawn()
	for _, other in workspace:GetDescendants() do
		if other:IsA("SpawnLocation") and other.Name ~= "ParkSpawn" then
			other.Enabled = false
		end
	end
end

local function fireworks(at: Vector3, colors: { Color3 })
	for i = 1, 14 do
		task.delay(i * 0.12, function()
			local spark = Instance.new("Part")
			spark.Shape = Enum.PartType.Ball
			spark.Anchored = true
			spark.CanCollide, spark.CanTouch, spark.CanQuery = false, false, false
			spark.Material = Enum.Material.Neon
			spark.Color = colors[(i - 1) % #colors + 1]
			spark.Size = Vector3.one * 1.5
			local angle = i * 2.4
			local target = at + Vector3.new(math.cos(angle) * 18, 26 + (i % 4) * 6, math.sin(angle) * 18)
			spark.Position = at
			spark.Parent = workspace
			local up = TweenService:Create(spark, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ Position = target })
			up:Play()
			up.Completed:Connect(function()
				TweenService:Create(spark, TweenInfo.new(0.6), { Size = Vector3.one * 9, Transparency = 1 }):Play()
			end)
			Debris:AddItem(spark, 1.6)
		end)
	end
end

function ParkObby.startServer(config: { [string]: any }?)
	assert(RunService:IsServer(), "ParkObby.startServer runs on the server")
	local cfg = config or {}
	local zones = cfg.Zones or {}
	if #zones == 0 then
		error("[ParkObby] Config.Zones is empty: list one { name, theme } per obby zone, in course order")
	end
	local World, Obby, Themes, Cos = kit("WorldKit"), kit("ObbyKit"), kit("ObbyThemes"), kit("Cosmetics")
	if not (Obby.coins and Obby.spend) then
		error("[ParkObby] ObbyKit has no coins/spend ledger API: the kit install is out of date")
	end

	local zoneOpts = {}
	for i, z in zones do
		zoneOpts[i] = { name = z.name, theme = z.theme, palette = z.palette }
	end
	local park = World.buildPark({ zones = zoneOpts, seed = cfg.Seed or 7, size = cfg.ParkSize })
	onlyParkSpawn()

	local info = Obby.start({
		themes = Themes,
		anchors = park.anchors,
		origin = park.anchors[1],
		spawn = park.spawn, -- a new player (stage 0) starts in the lobby and walks up the START stairs
		allowSkip = cfg.AllowSkip == true,
	})
	local levelZones = select(1, Obby.zoneOf(Obby.stageCount()))
	if levelZones ~= #zones then
		error(string.format("[ParkObby] Config.Zones lists %d zones but the level data builds %d: they must match "
			.. "one to one, in course order", #zones, levelZones))
	end

	Cos.start({
		currency = "Coins",
		costumes = cfg.Costumes,
		prices = cfg.Prices,
		rewards = cfg.Rewards,
		autoEquip = cfg.AutoEquip,
		balance = Obby.coins, -- one ledger: a purchase spends the coins the course pays out
		spend = Obby.spend,
	})
	Cos.buildChangingRoom({
		cframe = (park.lots and park.lots.changingRoom) or park.lobby * CFrame.new(-34, 0, 6),
		title = "👕 CHANGING ROOM",
	})

	local colors = {}
	for _, z in zones do
		table.insert(colors, hex(z.palette and z.palette[1], Color3.fromRGB(255, 196, 41)))
	end
	Obby.onFinish(function(player)
		telemetry("park_finished", 1)
		if cfg.FinishReward then
			Cos.grant(player, cfg.FinishReward)
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			fireworks(root.Position, colors)
		end
	end)
	workspace:SetAttribute("ParkTitle", cfg.Title or "Park Obby")
	return { park = park, course = info }
end

-- ------------------------------------------------------------------------------------------------ client

local AREA, LOBBY = "ParkArea", "lobby"
local INK = Color3.fromRGB(28, 22, 38)
local CREAM = Color3.fromRGB(255, 248, 232)

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function stroke(parent: Instance, t: number, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Color = color or INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function chunky(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size, l.Position = size, pos
	l.Font = Enum.Font.FredokaOne
	l.TextScaled = true
	l.TextColor3 = color or CREAM
	l.Text = text
	local s = Instance.new("UIStroke")
	s.Thickness = 2.5
	s.Color = INK
	s.Parent = l
	l.Parent = parent
	return l
end

local function pop(gui: GuiObject)
	local scale = gui:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
	scale.Parent = gui
	scale.Scale = 1.25
	TweenService:Create(scale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function buildHud(cfg: { [string]: any })
	local player = Players.LocalPlayer
	local gui = Instance.new("ScreenGui")
	gui.Name = "ParkHud"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local top = Instance.new("Frame")
	top.Name = "Top"
	top.AnchorPoint = Vector2.new(0.5, 0)
	top.Position = UDim2.new(0.5, 0, 0, 8)
	top.Size = UDim2.fromOffset(420, 82)
	top.BackgroundTransparency = 1
	top.Parent = gui

	local zonePill = Instance.new("Frame")
	zonePill.Name = "Zone"
	zonePill.Size = UDim2.new(1, 0, 0, 44)
	zonePill.BackgroundColor3 = Color3.fromRGB(255, 79, 109)
	zonePill.Parent = top
	corner(zonePill, 14)
	stroke(zonePill, 3)
	local zoneText = chunky(zonePill, "THE FRONT GATE", UDim2.new(1, -20, 1, -8), UDim2.fromOffset(10, 4))

	local bar = Instance.new("Frame")
	bar.Name = "Progress"
	bar.Position = UDim2.fromOffset(20, 52)
	bar.Size = UDim2.new(1, -40, 0, 24)
	bar.BackgroundColor3 = INK
	bar.Parent = top
	corner(bar, 12)
	stroke(bar, 2)
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Color3.fromRGB(88, 214, 92)
	fill.Parent = bar
	corner(fill, 12)
	local stageText = chunky(bar, "STAGE 0", UDim2.new(1, 0, 1, -4), UDim2.fromOffset(0, 2))

	local coins = Instance.new("Frame")
	coins.Name = "Coins"
	coins.AnchorPoint = Vector2.new(1, 0)
	coins.Position = UDim2.new(1, -12, 0, 12)
	coins.Size = UDim2.fromOffset(150, 48)
	coins.BackgroundColor3 = Color3.fromRGB(255, 196, 41)
	coins.Parent = gui
	corner(coins, 14)
	stroke(coins, 3)
	local coinText = chunky(coins, "🪙 0", UDim2.new(1, -16, 1, -8), UDim2.fromOffset(8, 4), INK)
	coinText:FindFirstChildOfClass("UIStroke").Color = CREAM

	local banner = chunky(gui, "", UDim2.fromOffset(700, 90), UDim2.new(0.5, -350, 0.28, 0))
	banner.Visible = false

	local zoneColors: { [string]: Color3 } = {}
	for _, z in cfg.Zones or {} do
		zoneColors[tostring(z.name)] = hex(z.palette and z.palette[1], Color3.fromRGB(255, 79, 109))
	end

	local function total(): number
		local folder = workspace:FindFirstChild("Obby")
		return (folder and folder:GetAttribute("Stages")) or 0
	end

	local lastStage = -1
	local function refreshStage()
		local ls = player:FindFirstChild("leaderstats")
		local st = ls and ls:FindFirstChild("Stage")
		local n = st and st.Value or 0
		local t = math.max(1, total())
		stageText.Text = string.format("STAGE %d / %d", n, t)
		TweenService:Create(fill, TweenInfo.new(0.4, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(math.clamp(n / t, 0, 1), 1) }):Play()
		if lastStage >= 0 and n > lastStage then
			pop(bar)
		end
		lastStage = n
	end

	local lastCoins = -1
	local function refreshCoins()
		local ls = player:FindFirstChild("leaderstats")
		local c = ls and ls:FindFirstChild("Coins")
		local n = c and c.Value or 0
		coinText.Text = "🪙 " .. tostring(n)
		if lastCoins >= 0 and n ~= lastCoins then
			pop(coins)
		end
		lastCoins = n
	end

	local function showBanner(text: string, color: Color3)
		banner.Text = text
		banner.TextColor3 = color
		banner.Visible = true
		pop(banner)
		task.delay(2.4, function()
			if banner.Text == text then
				banner.Visible = false
			end
		end)
	end

	local function refreshZone()
		local name = player:GetAttribute(AREA)
		if name == nil or name == LOBBY then
			zoneText.Text = string.upper(cfg.Title or "THE FRONT GATE")
			zonePill.BackgroundColor3 = Color3.fromRGB(255, 79, 109)
			return
		end
		local color = zoneColors[name] or Color3.fromRGB(255, 79, 109)
		zoneText.Text = string.upper(name)
		zonePill.BackgroundColor3 = color
		showBanner(string.upper(name), color)
	end

	local function hook()
		local ls = player:WaitForChild("leaderstats", 30)
		if not ls then
			return
		end
		for _, name in { "Stage", "Coins" } do
			local v = ls:WaitForChild(name, 10)
			if v then
				v.Changed:Connect(if name == "Stage" then refreshStage else refreshCoins)
			end
		end
		refreshStage()
		refreshCoins()
	end
	task.spawn(hook)
	player:GetAttributeChangedSignal(AREA):Connect(refreshZone)
	refreshZone()
	return gui
end

-- The area a player is in, as a Config zone name (or LOBBY before the first checkpoint). ObbyKit publishes
-- the player's Stage and Zone numbers; the name always comes from Config.Zones, never from the level data.
local function trackArea(cfg: { [string]: any })
	local player = Players.LocalPlayer
	local function refresh()
		local stage = tonumber(player:GetAttribute("Stage")) or 0
		local zone = cfg.Zones[tonumber(player:GetAttribute("Zone")) or 0]
		local area = if stage > 0 and zone then tostring(zone.name) else LOBBY
		if player:GetAttribute(AREA) ~= area then
			player:SetAttribute(AREA, area) -- client-local: drives this player's HUD and music only
		end
	end
	player:GetAttributeChangedSignal("Stage"):Connect(refresh)
	player:GetAttributeChangedSignal("Zone"):Connect(refresh)
	refresh()
end

function ParkObby.startClient(config: { [string]: any }?)
	assert(RunService:IsClient(), "ParkObby.startClient runs in a LocalScript")
	local cfg = config or {}
	cfg.Zones = cfg.Zones or {}
	local Music, CC = kit("MusicPlayer"), kit("CosmeticsClient")
	trackArea(cfg)
	local areas = { [LOBBY] = "lobby" }
	for _, z in cfg.Zones do
		areas[tostring(z.name)] = z.mood or z.theme
	end
	Music.start({ areas = areas, attribute = AREA, default = LOBBY, muteButton = true })
	CC.start({ button = true, title = "COSTUMES" })
	return buildHud(cfg)
end

return ParkObby
