--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

-- Guard: the world (plaza + plot ring) and all services must be started exactly once.
-- A duplicate start is benign, so it returns without a warning, but it is counted for diagnosis.
if workspace:GetAttribute("ForgeWorldBuilt") == true then
	local okT, telem = pcall(function()
		return require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 5))
	end)
	if okT and type(telem) == "table" and type(telem.count) == "function" then
		pcall(telem.count, "duplicate_start", 1)
	end
	return
end
workspace:SetAttribute("ForgeWorldBuilt", true)

-- Diagnostic output about optional hooks is only shown when this attribute is set on workspace.
local function debugEnabled(): boolean
	return workspace:GetAttribute("ForgeDebug") == true
end

local Config: any = require(ReplicatedStorage:WaitForChild("Config"))
local ForgeTelemetry: any = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local PlotBuilder: any = require(ServerScriptService:WaitForChild("PlotBuilder"))
local PlazaBuilder: any = require(ServerScriptService:WaitForChild("PlazaBuilder"))
local PlotClaimService: any = require(ServerScriptService:WaitForChild("PlotClaimService"))
local UpgradeService: any = require(ServerScriptService:WaitForChild("UpgradeService"))
local RebirthService: any = require(ServerScriptService:WaitForChild("RebirthService"))
local TutorialService: any = require(ServerScriptService:WaitForChild("TutorialService"))
local DataService: any = require(ServerScriptService:WaitForChild("DataService"))
local JuiceService: any = require(ServerScriptService:WaitForChild("JuiceService"))

-- CashInService runs the collector (cube -> Cash, cubes_collected); it must be started.
local CashInService: any = nil
do
	local cashInModule = ServerScriptService:WaitForChild("CashInService", 5)
	if cashInModule and cashInModule:IsA("ModuleScript") then
		local okReq, result = pcall(require, cashInModule)
		if okReq then
			CashInService = result
		else
			warn("CashInService require failed: " .. tostring(result))
		end
	end
end

----------------------------------------------------------------------
-- Helpers
----------------------------------------------------------------------

-- Calls the first function found under any of the given names.
-- Hooks are optional: a module that does not implement one is silently skipped
-- (a note is printed only when the ForgeDebug workspace attribute is true).
local missingLogged: { [string]: boolean } = {}
local function callFirst(module: any, names: { string }, ...: any): (boolean, any)
	if type(module) ~= "table" then
		return false, nil
	end
	for _, name in names do
		local fn = module[name]
		if type(fn) == "function" then
			local ok, result = pcall(fn, ...)
			if not ok then
				warn(name .. " failed: " .. tostring(result))
			end
			return ok, result
		end
	end
	if debugEnabled() then
		local key = table.concat(names, "/")
		if not missingLogged[key] then
			missingLogged[key] = true
			print("[Forge] optional hook not implemented: " .. key)
		end
	end
	return false, nil
end

-- Remotes
local remotes = ReplicatedStorage:FindFirstChild(Config.REMOTES_FOLDER)
if not remotes then
	local f = Instance.new("Folder")
	f.Name = Config.REMOTES_FOLDER
	f.Parent = ReplicatedStorage
	remotes = f
end
if not (remotes :: Instance):FindFirstChild(Config.REMOTE_NOTIFY) then
	local ev = Instance.new("RemoteEvent")
	ev.Name = Config.REMOTE_NOTIFY
	ev.Parent = remotes
end

----------------------------------------------------------------------
-- World build (base, plaza, plots; each exactly once)
----------------------------------------------------------------------

local built = false
local plazaCenter = Vector3.new(0, 4, 0)
local plots: { any } = {}

local function buildWorld()
	if built then
		return
	end
	built = true

	callFirst(PlotBuilder, { "buildBase" })

	-- Baseplate styling (no default grey)
	local baseplate = workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		if typeof(Config.BASEPLATE_COLOR) == "Color3" then
			baseplate.Color = Config.BASEPLATE_COLOR
		end
		if typeof(Config.BASEPLATE_MATERIAL) == "EnumItem" then
			baseplate.Material = Config.BASEPLATE_MATERIAL
		end
	end

	local okPlaza, plaza = callFirst(PlazaBuilder, { "buildPlaza", "build", "create" })
	if okPlaza and plaza ~= nil then
		if typeof(plaza) == "CFrame" then
			plazaCenter = (plaza :: CFrame).Position
		elseif typeof(plaza) == "Vector3" then
			plazaCenter = plaza :: Vector3
		elseif type(plaza) == "table" then
			local c = plaza.spawnCFrame or plaza.centerCFrame or plaza.center or plaza.spawn
			if typeof(c) == "CFrame" then
				plazaCenter = c.Position
			elseif typeof(c) == "Vector3" then
				plazaCenter = c
			end
		end
	end

	local plotCount: number = Config.PLOT_COUNT or Config.MAX_PLOTS or 6
	for i = 1, plotCount do
		local ok, plot = pcall(PlotBuilder.buildPlot, i)
		if ok and plot ~= nil then
			table.insert(plots, plot)
		else
			warn("Plot build failed: " .. tostring(plot))
		end
	end

	ForgeTelemetry.count("map_built", 1)
end

----------------------------------------------------------------------
-- ClaimWatcher: detects plot claims (manual and auto-claim) and notifies services.
-- PlotClaimService remains the single authority for claiming; this only observes.
----------------------------------------------------------------------

local ClaimWatcher = {}
local notifiedPlot: { [Player]: any } = {}
local highlightedPads: { [Instance]: boolean } = {}

-- Resolves the plot currently owned by a player (nil if none).
function ClaimWatcher.getPlot(player: Player): any?
	if type(PlotClaimService) == "table" then
		local getter = PlotClaimService.getPlot or PlotClaimService.getPlotFor
		if type(getter) == "function" then
			local ok, result = pcall(getter, player)
			if ok and result ~= nil then
				if type(result) == "number" then
					return plots[result]
				end
				return result
			end
		end
	end
	local idx = player:GetAttribute("PlotIndex") or player:GetAttribute("ClaimedPlot")
	if type(idx) == "number" then
		return plots[idx]
	end
	return nil
end

function ClaimWatcher.hasPlot(player: Player): boolean
	if ClaimWatcher.getPlot(player) ~= nil then
		return true
	end
	return player:GetAttribute("PlotIndex") ~= nil or player:GetAttribute("ClaimedPlot") ~= nil
end

-- Makes the Dropper 2 pad easy to see (accent colour + Neon pulse, green when affordable)
-- and easy to hit (>= 8x2x8, CanTouch on).
local function highlightDropperPad(player: Player)
	local pad: BasePart? = nil
	for _ = 1, 40 do
		if player.Parent ~= Players then
			return
		end
		local folder = workspace:FindFirstChild("UpgradePads_" .. player.Name)
		local found = folder and folder:FindFirstChild("UpgradePad_dropper2")
		if found and found:IsA("BasePart") then
			pad = found
			break
		end
		task.wait(0.25)
	end
	local d = pad
	if not d or highlightedPads[d] then
		return
	end
	if string.sub(d.Name, 1, 11) ~= "UpgradePad_" then
		return
	end
	highlightedPads[d] = true

	local accent: Color3 = Color3.fromHex("FFD23F")
	if typeof(Config.ACCENT_COLOR) == "Color3" then
		accent = Config.ACCENT_COLOR
	end
	local green: Color3 = Color3.fromRGB(76, 217, 100)

	-- Larger hitbox, keeping the bottom of the pad flush with the ground.
	local s = d.Size
	local newSize = Vector3.new(math.max(s.X, 8), math.max(s.Y, 2), math.max(s.Z, 8))
	local lift = (newSize.Y - s.Y) / 2
	d.Size = newSize
	if lift ~= 0 then
		d.Position = d.Position + Vector3.new(0, lift, 0)
	end
	d.CanTouch = true
	d.Material = Enum.Material.Neon
	d.Color = accent

	local costAttr = d:GetAttribute("Cost")
	local cost: number = if type(costAttr) == "number" then costAttr else 10

	local currentTween: Tween? = nil
	local currentAffordable: boolean? = nil
	local pulseOk = false
	local function setPulse(affordable: boolean)
		if currentAffordable == affordable or d.Parent == nil then
			return
		end
		currentAffordable = affordable
		if currentTween then
			currentTween:Cancel()
			currentTween = nil
		end
		local base = if affordable then green else accent
		d.Color = base
		local ok = pcall(function()
			local tween = TweenService:Create(
				d,
				TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ Color = base:Lerp(Color3.new(1, 1, 1), 0.45) }
			)
			currentTween = tween
			tween:Play()
		end)
		if ok then
			pulseOk = true
		end
	end

	local function currentCash(): number
		local ls = player:FindFirstChild("leaderstats")
		local cashV = ls and ls:FindFirstChild("Cash")
		if cashV and cashV:IsA("IntValue") then
			return cashV.Value
		end
		return 0
	end

	setPulse(currentCash() >= cost)
	local ls = player:FindFirstChild("leaderstats")
	local cashV = ls and ls:FindFirstChild("Cash")
	if cashV and cashV:IsA("IntValue") then
		cashV.Changed:Connect(function()
			if d.Parent ~= nil then
				setPulse(cashV.Value >= cost)
			end
		end)
	end

	pcall(function()
		local bb = Instance.new("BillboardGui")
		bb.Name = "StepHereArrow"
		bb.Size = UDim2.fromScale(7, 2.6)
		bb.StudsOffset = Vector3.new(0, d.Size.Y / 2 + 5, 0)
		bb.AlwaysOnTop = true
		bb.MaxDistance = 400
		bb.LightInfluence = 0
		bb.Adornee = d
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromScale(1, 1)
		l.BackgroundTransparency = 1
		l.Text = "Step here! $10\nv"
		l.Font = Enum.Font.LuckiestGuy
		l.TextScaled = true
		l.TextColor3 = Color3.fromRGB(88, 214, 92)
		local st = Instance.new("UIStroke")
		st.Thickness = 3
		st.Color = Color3.fromRGB(28, 22, 38)
		st.Parent = l
		l.Parent = bb
		bb.Parent = d
		TweenService:Create(
			bb,
			TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ StudsOffset = Vector3.new(0, d.Size.Y / 2 + 6.5, 0) }
		):Play()
	end)
	if pulseOk then
		ForgeTelemetry.count("pad_highlighted", 1)
	end
end

-- Notifies services once per claimed plot (covers manual and auto-claim paths).
function ClaimWatcher.check(player: Player)
	local plot = ClaimWatcher.getPlot(player)
	if plot == nil then
		notifiedPlot[player] = nil
		return
	end
	if notifiedPlot[player] == plot then
		return
	end
	notifiedPlot[player] = plot
	callFirst(UpgradeService, { "onPlotClaimed", "onClaimed", "onPlotClaim", "claimPlot" }, player, plot)
	callFirst(CashInService, { "onPlotClaimed", "onClaimed", "onPlotClaim" }, player, plot)
	-- Give the pads a moment to be created by UpgradeService, then highlight Dropper 2.
	task.delay(0.5, function()
		if player.Parent == Players then
			local ok, err = pcall(highlightDropperPad, player)
			if not ok then
				warn("highlightDropperPad failed: " .. tostring(err))
			end
		end
	end)
	-- Tell the tutorial the plot was claimed so its guide beam appears.
	callFirst(TutorialService, { "onPlotClaimed", "onClaimed" }, player, plot)
end

-- Starts watching a player's claim state (attribute changes + a slow poll as a safety net).
function ClaimWatcher.watch(player: Player)
	player:GetAttributeChangedSignal("PlotIndex"):Connect(function()
		ClaimWatcher.check(player)
	end)
	player:GetAttributeChangedSignal("ClaimedPlot"):Connect(function()
		ClaimWatcher.check(player)
	end)
	task.spawn(function()
		while player.Parent == Players do
			ClaimWatcher.check(player)
			task.wait(0.5)
		end
	end)
end

function ClaimWatcher.forget(player: Player)
	notifiedPlot[player] = nil
end

----------------------------------------------------------------------
-- Player setup
----------------------------------------------------------------------

-- Moves an unclaimed player to the plaza center; claimed players are never teleported.
local function spawnAtPlaza(player: Player, character: Model)
	local hrp = character:WaitForChild("HumanoidRootPart", 5)
	if not hrp or not hrp:IsA("BasePart") then
		return
	end
	if ClaimWatcher.hasPlot(player) then
		return
	end
	local offset = Vector3.new(math.random(-6, 6), 4, math.random(-6, 6))
	character:PivotTo(CFrame.new(plazaCenter + offset))
end

local setupDone: { [Player]: boolean } = {}

local function setupPlayer(player: Player)
	if setupDone[player] then
		return
	end
	setupDone[player] = true

	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		ls = folder
	end
	if not (ls :: Instance):FindFirstChild("Cash") then
		local cash = Instance.new("IntValue")
		cash.Name = "Cash"
		cash.Value = 0
		cash.Parent = ls
	end

	-- Load saved data and re-apply it BEFORE the tycoon / claim / tutorial wiring starts
	callFirst(DataService, { "loadPlayer" }, player)
	if player.Parent ~= Players then
		return
	end
	callFirst(DataService, { "applyPlayer" }, player)

	player.CharacterAdded:Connect(function(character)
		spawnAtPlaza(player, character)
	end)
	if player.Character then
		local character = player.Character
		task.spawn(spawnAtPlaza, player, character)
	end

	ClaimWatcher.watch(player)
end

----------------------------------------------------------------------
-- Bootstrap: start services in order
----------------------------------------------------------------------

-- Data and juice are initialised once at startup (before any player is handled)
callFirst(DataService, { "init" })
callFirst(JuiceService, { "init" })

buildWorld()

-- PlotClaimService is the single authority for claiming and auto-claiming.
callFirst(PlotClaimService, { "init", "start", "setup" }, plots)
callFirst(UpgradeService, { "init" })
callFirst(RebirthService, { "init" })
callFirst(CashInService, { "init", "start", "setup" }, plots)

Players.PlayerAdded:Connect(function(player)
	task.spawn(setupPlayer, player)
end)
for _, player in Players:GetPlayers() do
	task.spawn(setupPlayer, player)
end

Players.PlayerRemoving:Connect(function(player)
	ClaimWatcher.forget(player)
	setupDone[player] = nil
	callFirst(UpgradeService, { "onPlayerRemoving" }, player)
	callFirst(CashInService, { "onPlayerRemoving" }, player)
end)

-- Tutorial: started once after all other services are wired
callFirst(TutorialService, { "start" })
