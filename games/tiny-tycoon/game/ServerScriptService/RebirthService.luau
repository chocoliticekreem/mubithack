-- RebirthService: server-authoritative rebirth system (altar, remotes, multiplier, leaderstat).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")

local RebirthConfig = require(ReplicatedStorage:WaitForChild("RebirthConfig"))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local UpgradeService: any = require(ServerScriptService:WaitForChild("UpgradeService"))

local RebirthService = {}

type State = {
	rebirths: number,
	last: number,
	altar: BasePart?,
	label: TextLabel?,
	stat: IntValue?,
}

local states: { [Player]: State } = {}
local requestRemote: RemoteEvent? = nil
local resultRemote: RemoteEvent? = nil
local started = false

local juiceService: any = nil
local juiceTried = false

-- Lazily resolves JuiceService (it may be created after this module loads).
local function getJuice(): any
	if juiceService then
		return juiceService
	end
	if juiceTried then
		return nil
	end
	local mod = ServerScriptService:FindFirstChild("JuiceService") or ServerScriptService:WaitForChild("JuiceService", 5)
	juiceTried = true
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod)
	if ok then
		juiceService = res
	else
		warn("RebirthService: could not require JuiceService: " .. tostring(res))
	end
	return juiceService
end

local function notifyJuice(player: Player)
	local juice = getJuice()
	if not juice then
		return
	end
	if type(juice.onRebirth) == "function" then
		local ok, err = pcall(juice.onRebirth, player)
		if not ok then
			warn("RebirthService: JuiceService.onRebirth failed: " .. tostring(err))
		end
	end
	if type(juice.pushGoal) == "function" then
		-- After a reset the cheapest unbought upgrade is Dropper 2.
		local goalName = "Dropper 2"
		local goalCost: number? = nil
		if type(UpgradeService.costOf) == "function" then
			local okCost, c = pcall(UpgradeService.costOf, goalName)
			if okCost and type(c) == "number" then
				goalCost = c
			end
		end
		local ok, err = pcall(juice.pushGoal, player, goalName, goalCost)
		if not ok then
			warn("RebirthService: JuiceService.pushGoal failed: " .. tostring(err))
		end
	end
end

local function getRemote(folder: Instance, name: string): RemoteEvent
	local existing = folder:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = folder
	return r
end

local function getCash(player: Player): IntValue?
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		return nil
	end
	local c = ls:FindFirstChild("Cash")
	if c and (c:IsA("IntValue") or c:IsA("NumberValue")) then
		return c :: any
	end
	return nil
end

local function ensureState(player: Player): State
	local s = states[player]
	if not s then
		s = { rebirths = 0, last = 0, altar = nil, label = nil, stat = nil }
		states[player] = s
		player:SetAttribute("RebirthMult", RebirthConfig.multiplierFor(0))
	end
	return s
end

local function syncStat(player: Player, s: State)
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		return
	end
	local stat = ls:FindFirstChild("Rebirths")
	if not (stat and stat:IsA("IntValue")) then
		stat = Instance.new("IntValue")
		stat.Name = "Rebirths"
		stat.Value = s.rebirths
		stat.Parent = ls
	end
	s.stat = stat :: IntValue
	(stat :: IntValue).Value = s.rebirths
end

local function updateLabel(s: State)
	if s.label then
		s.label.Text = "REBIRTH $" .. tostring(RebirthConfig.costFor(s.rebirths))
	end
end

local function fireResult(player: Player, ok: boolean, s: State, reason: string)
	if resultRemote then
		resultRemote:FireClient(player, ok, RebirthConfig.multiplierFor(s.rebirths), RebirthConfig.costFor(s.rebirths), reason)
	end
end

local plotGrowth: any = nil
local plotGrowthTried = false

-- Lazily resolves PlotGrowth (guarded; the module may be missing or fail to load).
local function getPlotGrowth(): any
	if plotGrowth then
		return plotGrowth
	end
	if plotGrowthTried then
		return nil
	end
	plotGrowthTried = true
	local mod = ServerScriptService:FindFirstChild("PlotGrowth")
	if not mod then
		return nil
	end
	local ok, res = pcall(require, mod)
	if ok then
		plotGrowth = res
	else
		warn("RebirthService: could not require PlotGrowth: " .. tostring(res))
	end
	return plotGrowth
end

function RebirthService.tryRebirth(player: Player)
	if not player or player.Parent ~= Players then
		return
	end
	local s = ensureState(player)
	local now = os.clock()
	if now - s.last < RebirthConfig.requestCooldown then
		return
	end
	s.last = now

	local cash = getCash(player)
	local cost = RebirthConfig.costFor(s.rebirths)
	local hasAll = false
	if type(UpgradeService.hasAll) == "function" then
		local okCall, res = pcall(UpgradeService.hasAll, player)
		hasAll = okCall and res == true
	end
	local eligible = hasAll or (cash ~= nil and cash.Value >= cost)
	if not eligible or cash == nil then
		fireResult(player, false, s, "Need $" .. tostring(cost) .. " or every upgrade")
		ForgeTelemetry.count("rebirth_denied", 1)
		return
	end

	cash.Value = 0
	if type(UpgradeService.resetPlayer) == "function" then
		local okReset, err = pcall(UpgradeService.resetPlayer, player)
		if not okReset then
			warn("RebirthService: resetPlayer failed: " .. tostring(err))
		end
	end
	local growth = getPlotGrowth()
	if growth and type(growth.clear) == "function" then
		local okClear, errClear = pcall(growth.clear, player)
		if not okClear then
			warn("RebirthService: PlotGrowth.clear failed: " .. tostring(errClear))
		end
	end
	s.rebirths += 1
	syncStat(player, s)
	player:SetAttribute("RebirthMult", RebirthConfig.multiplierFor(s.rebirths))
	updateLabel(s)
	fireResult(player, true, s, "ok")
	ForgeTelemetry.count("rebirths", 1)
	notifyJuice(player)
end

-- Silently sets the rebirth count (used when loading saved data): no banner, no cash reset.
function RebirthService.setRebirths(player: Player, n: number)
	if not player or player.Parent ~= Players then
		return
	end
	local count = 0
	if type(n) == "number" and n == n and n > 0 and n < math.huge then
		count = math.floor(n)
	end
	local s = ensureState(player)
	s.rebirths = count
	syncStat(player, s)
	player:SetAttribute("RebirthMult", RebirthConfig.multiplierFor(count))
	updateLabel(s)
end

function RebirthService.getRebirths(player: Player): number
	local s = states[player]
	if s then
		return s.rebirths
	end
	return 0
end

function RebirthService.onPlotClaimed(player: Player, plot: any)
	local s = ensureState(player)
	if s.altar then
		s.altar:Destroy()
		s.altar, s.label = nil, nil
	end
	if type(plot) ~= "table" then
		return
	end
	local origin = plot.origin
	local cf: CFrame
	if typeof(origin) == "CFrame" then
		cf = origin
	elseif typeof(origin) == "Vector3" then
		cf = CFrame.new(origin)
	else
		return
	end
	local size = RebirthConfig.altarSize
	local gold = Color3.fromRGB(255, 196, 48)
	local groundCF = cf * CFrame.new(-16, 0, 16)
	local cylRot = CFrame.Angles(0, 0, math.pi / 2)
	local altar = Instance.new("Part")
	altar.Name = "RebirthAltar_" .. player.Name
	altar.Shape = Enum.PartType.Cylinder
	altar.Size = Vector3.new(1, 8, 8)
	altar.Anchored = true
	altar.CanCollide = true
	altar.Material = Enum.Material.Foil
	altar.Color = gold
	altar.CFrame = groundCF * CFrame.new(0, 0.5, 0) * cylRot

	local step2 = Instance.new("Part")
	step2.Name = "AltarStep2"
	step2.Shape = Enum.PartType.Cylinder
	step2.Size = Vector3.new(1, 5.2, 5.2)
	step2.Anchored = true
	step2.CanCollide = true
	step2.Material = Enum.Material.Foil
	step2.Color = gold
	step2.CFrame = groundCF * CFrame.new(0, 1.5, 0) * cylRot
	step2.Parent = altar

	for i = 0, 3 do
		local ang = math.rad(i * 90 + 45)
		local pillar = Instance.new("Part")
		pillar.Name = "AltarPillar"
		pillar.Size = Vector3.new(0.8, 2.5, 0.8)
		pillar.Anchored = true
		pillar.CanCollide = true
		pillar.Material = Enum.Material.Foil
		pillar.Color = gold
		pillar.CFrame = groundCF * CFrame.new(math.cos(ang) * 2, 3.25, math.sin(ang) * 2)
		pillar.Parent = altar
	end

	local orbBase = groundCF * CFrame.new(0, 3.8, 0)
	local orb = Instance.new("Part")
	orb.Name = "AltarOrb"
	orb.Shape = Enum.PartType.Ball
	orb.Size = Vector3.new(1.8, 1.8, 1.8)
	orb.Anchored = true
	orb.CanCollide = false
	orb.CanQuery = false
	orb.Material = Enum.Material.Neon
	orb.Color = Color3.fromRGB(255, 214, 80)
	orb.CFrame = orbBase
	orb.Parent = altar

	local light = Instance.new("PointLight")
	light.Color = RebirthConfig.altarGlowColor
	light.Range = 18
	light.Brightness = 2
	light.Parent = orb

	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(RebirthConfig.altarGlowColor)
	sparks.Rate = 8
	sparks.Lifetime = NumberRange.new(1, 2)
	sparks.Speed = NumberRange.new(2, 4)
	sparks.Size = NumberSequence.new(0.4, 0)
	sparks.LightEmission = 1
	sparks.Parent = orb

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromScale(6, 2)
	bb.StudsOffset = Vector3.new(0, 5, 0)
	bb.AlwaysOnTop = false
	bb.MaxDistance = 45
	bb.Adornee = altar
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = RebirthConfig.altarGlowColor
	label.Text = ""
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(28, 22, 38)
	stroke.Parent = label
	label.Parent = bb
	bb.Parent = altar

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Rebirth"
	prompt.ObjectText = "Golden Altar"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Triggered:Connect(function(who: Player)
		if who == player then
			RebirthService.tryRebirth(player)
		end
	end)
	prompt.Parent = altar

	s.altar, s.label = altar, label
	updateLabel(s)
	altar.Parent = Workspace

	task.spawn(function()
		local t0 = os.clock()
		while orb.Parent do
			local t = os.clock() - t0
			orb.CFrame = orbBase * CFrame.new(0, math.sin(t * 2) * 0.4, 0) * CFrame.Angles(0, t * 1.5, 0)
			task.wait(0.05)
		end
	end)
end

function RebirthService.onPlotReleased(player: Player)
	local s = states[player]
	if s and s.altar then
		s.altar:Destroy()
		s.altar, s.label = nil, nil
	end
end

local function setupPlayer(player: Player)
	local s = ensureState(player)
	task.spawn(function()
		local ls = player:WaitForChild("leaderstats", 10)
		if not ls then
			local f = Instance.new("Folder")
			f.Name = "leaderstats"
			f.Parent = player
			ls = f
		end
		if player.Parent ~= Players or s.stat then
			return
		end
		local stat = ls:FindFirstChild("Rebirths")
		if not (stat and stat:IsA("IntValue")) then
			stat = Instance.new("IntValue")
			stat.Name = "Rebirths"
			stat.Value = s.rebirths
			stat.Parent = ls
		else
			stat.Value = s.rebirths
		end
		s.stat = stat :: IntValue
	end)
end

local function removePlayer(player: Player)
	RebirthService.onPlotReleased(player)
	states[player] = nil
end

function RebirthService.init()
	if started then
		return
	end
	started = true
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Remotes"
		folder.Parent = ReplicatedStorage
	end
	requestRemote = getRemote(folder, "RebirthRequest")
	resultRemote = getRemote(folder, "RebirthResult")
	if requestRemote then
		requestRemote.OnServerEvent:Connect(function(player: Player)
			RebirthService.tryRebirth(player)
		end)
	end
	Players.PlayerAdded:Connect(setupPlayer)
	Players.PlayerRemoving:Connect(removePlayer)
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
end

return RebirthService
