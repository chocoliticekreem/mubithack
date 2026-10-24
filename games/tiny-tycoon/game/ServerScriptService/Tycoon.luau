--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")

local Config = require(ReplicatedStorage:WaitForChild("Config")) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry")) :: any

local Tycoon = {}
Tycoon.__index = Tycoon

local NEED_TOAST_INTERVAL = 3
local CUBE_LIFETIME = 30
local CUBE_GROUP = "TycoonCubes"
local PLAYER_GROUP = "TycoonPlayers"

-- Running tycoons keyed by plot (so stopPlot(plot) can find them).
local activeByPlot: { [any]: any } = {}

-- Per-player upgrade modifiers (written by UpgradeService via Tycoon.setModifiers).
local modsByPlayer: { [Player]: any } = {}
local function mergeMods(mods: any): any
	local out: any = { slots = 1, ore = 1, speedMult = 1, cashMult = 1 }
	if type(mods) == "table" then
		for k, v in pairs(mods) do
			out[k] = v
		end
	end
	return out
end
local function getOres(): any
	local mod = ReplicatedStorage:FindFirstChild("Upgrades")
	if not mod or not mod:IsA("ModuleScript") then
		return nil
	end
	local ok, res = pcall(require, mod)
	if ok and type(res) == "table" then
		return (res :: any).ores
	end
	return nil
end

-- Collision groups: cubes never collide with players or each other (they still hit the conveyor/collector).
local groupsReady = false
local groupsOk = false
local function setupCollisionGroups()
	if groupsReady then
		return
	end
	groupsReady = true
	local ok, err = pcall(function()
		pcall(function()
			PhysicsService:RegisterCollisionGroup(CUBE_GROUP)
		end)
		pcall(function()
			PhysicsService:RegisterCollisionGroup(PLAYER_GROUP)
		end)
		PhysicsService:CollisionGroupSetCollidable(CUBE_GROUP, PLAYER_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(CUBE_GROUP, CUBE_GROUP, false)
	end)
	if not ok then
		warn("Tycoon: collision group setup failed: " .. tostring(err))
		return
	end
	groupsOk = true

	local function applyToCharacter(character: Model)
		local function setPart(inst: Instance)
			if inst:IsA("BasePart") then
				inst.CollisionGroup = PLAYER_GROUP
			end
		end
		for _, d in ipairs(character:GetDescendants()) do
			setPart(d)
		end
		character.DescendantAdded:Connect(setPart)
	end
	local function hookPlayer(p: Player)
		if p.Character then
			applyToCharacter(p.Character)
		end
		p.CharacterAdded:Connect(applyToCharacter)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in ipairs(Players:GetPlayers()) do
		hookPlayer(p)
	end
end

-- PlotClaimService is required lazily: it requires this module, so a top-level require would be circular.
local claimService: any = nil
local function isOwner(player: Player, plot: any): boolean
	if claimService == nil then
		local mod = ServerScriptService:FindFirstChild("PlotClaimService")
		if not mod or not mod:IsA("ModuleScript") then
			return false
		end
		local ok, result = pcall(require, mod)
		if not ok then
			warn("Tycoon: could not require PlotClaimService: " .. tostring(result))
			return false
		end
		claimService = result
	end
	local ok, res = pcall(function()
		return claimService.isOwner(player, plot)
	end)
	return ok and res == true
end

-- CashInService is required lazily and guarded so a failure there can never block payouts.
local cashInService: any = nil
local function sendCashIn(player: Player, amount: number, tier: number, position: Vector3)
	if cashInService == nil then
		local mod = ServerScriptService:FindFirstChild("CashInService")
		if not mod or not mod:IsA("ModuleScript") then
			return
		end
		local ok, result = pcall(require, mod)
		if not ok then
			warn("Tycoon: could not require CashInService: " .. tostring(result))
			return
		end
		cashInService = result
	end
	local ok, err = pcall(function()
		cashInService.cashIn(player, amount, tier, position)
	end)
	if not ok then
		warn("Tycoon: cashIn failed: " .. tostring(err))
	end
end

local function getNotifyRemote(): RemoteEvent
	local folder = ReplicatedStorage:FindFirstChild(Config.REMOTES_FOLDER)
	if not folder then
		local newFolder = Instance.new("Folder")
		newFolder.Name = Config.REMOTES_FOLDER
		newFolder.Parent = ReplicatedStorage
		folder = newFolder
	end
	local f = folder :: Instance
	local remote = f:FindFirstChild(Config.REMOTE_NOTIFY)
	if not remote then
		local newRemote = Instance.new("RemoteEvent")
		newRemote.Name = Config.REMOTE_NOTIFY
		newRemote.Parent = f
		remote = newRemote
	end
	return remote :: RemoteEvent
end

local function getCash(player: Player): IntValue?
	if not player.Parent then
		return nil
	end
	local stats: Instance? = player:FindFirstChild("leaderstats")
	if not stats then
		local newStats = Instance.new("Folder")
		newStats.Name = "leaderstats"
		newStats.Parent = player
		stats = newStats
	end
	local s = stats :: Instance
	local cash: Instance? = s:FindFirstChild("Cash")
	if not cash then
		local newCash = Instance.new("IntValue")
		newCash.Name = "Cash"
		newCash.Value = 0
		newCash.Parent = s
		cash = newCash
	end
	if cash and cash:IsA("IntValue") then
		return cash
	end
	return nil
end

-- Constructor only: nothing runs until start() (called via Tycoon.startPlot on claim).
function Tycoon.new(player: Player, plot: any): any
	local self: any = setmetatable({}, Tycoon)
	self.player = player
	self.plot = plot
	self.destroyed = false
	self.started = false
	self.speed = Config.CONVEYOR_SPEED
	self.mods = mergeMods(modsByPlayer[player])
	self.cubes = {} :: { [Instance]: boolean }
	self.cubeCount = 0
	self.connections = {} :: { RBXScriptConnection }
	self.bought = { dropper = false, conveyor = false }
	self.restore = {} :: { () -> () }
	self.notify = getNotifyRemote()

	local flat = Vector3.new(plot.conveyorDir.X, 0, plot.conveyorDir.Z)
	self.dir = if flat.Magnitude > 0.001 then flat.Unit else Vector3.new(0, 0, 1)
	self.activeDroppers = { plot.droppers[1] }
	return self
end

function Tycoon.start(self: any)
	if self.started or self.destroyed then
		return
	end
	self.started = true
	setupCollisionGroups()
	local player: Player = self.player
	local plot: any = self.plot

	-- Starting bankroll so the first upgrade is reachable within ~30s.
	if not player:GetAttribute("StartCashGranted") then
		local startCash = Config.START_CASH
		if type(startCash) ~= "number" then
			startCash = 10
		end
		local cash = getCash(player)
		if cash then
			cash.Value += startCash
		end
		player:SetAttribute("StartCashGranted", true)
	end

	local folder = Instance.new("Folder")
	folder.Name = "Cubes_" .. player.UserId
	folder.Parent = Workspace
	self.folder = folder

	-- Heartbeat: drive cubes along the conveyor, collect at the end, clean up strays.
	table.insert(self.connections, RunService.Heartbeat:Connect(function()
		self:_step()
	end))

	-- Collector touch
	table.insert(self.connections, plot.collector.Touched:Connect(function(hit: BasePart)
		if hit:IsA("Part") and self.cubes[hit] then
			self:_collect(hit)
		end
	end))




	task.spawn(function()
		while not self.destroyed do
			local slots = math.max(1, math.floor(tonumber(self.mods.slots) or 1))
			for i = 1, slots do
				local d: BasePart? = plot.droppers[i]
				local off = 0
				if not d then
					d = plot.droppers[1]
					off = (i - 1) * 3
				end
				if d then
					self:_spawnCube(d, off)
				end
			end
			task.wait(Config.DROP_INTERVAL)
		end
	end)
end

function Tycoon._spawnCube(self: any, dropper: BasePart, offset: number?)
	if self.destroyed or self.cubeCount >= Config.MAX_CUBES_PER_PLOT then
		return
	end
	local ores: any = getOres()
	local ore: any = nil
	if type(ores) == "table" then
		ore = ores[self.mods.ore]
	end
	local conveyor: BasePart = self.plot.conveyor
	local dir: Vector3 = self.dir
	local half: number = Config.CONVEYOR_LENGTH / 2 - 2
	local t = math.clamp((dropper.Position - conveyor.Position):Dot(dir) + (offset or 0), -half, half)
	local pos = conveyor.Position + dir * t
	local y = conveyor.Position.Y + conveyor.Size.Y / 2 + Config.CUBE_SIZE.Y / 2 + 0.5
	local cube = Instance.new("Part")
	cube.Name = "Cube"
	cube.Size = Config.CUBE_SIZE
	cube.Color = if ore then ore.color else Config.CUBE_COLOR
	cube.Material = if ore then ore.material else Enum.Material.Neon
	if ore and ore.sparkles then
		local sp = Instance.new("Sparkles")
		sp.Parent = cube
	end
	cube.Anchored = false
	cube.CanCollide = true
	if groupsOk then
		cube.CollisionGroup = CUBE_GROUP
	end
	cube.CFrame = CFrame.new(Vector3.new(pos.X, y, pos.Z))
	cube:SetAttribute("Value", if ore then ore.value else Config.CUBE_VALUE)
	cube:SetAttribute("OwnerId", (self.player :: Player).UserId)
	cube:SetAttribute("Born", os.clock())
	cube.Parent = self.folder
	pcall(function()
		cube:SetNetworkOwner(nil)
	end)
	self.cubes[cube] = true
	self.cubeCount += 1
	Telemetry.count("cubes_dropped", 1)
end

function Tycoon._removeCube(self: any, cube: BasePart)
	if self.cubes[cube] then
		self.cubes[cube] = nil
		self.cubeCount = math.max(0, self.cubeCount - 1)
	end
	cube:Destroy()
end

function Tycoon._collect(self: any, cube: BasePart)
	-- Idempotent: the Collected attribute and the cubes registry are both checked and set before paying out.
	if self.destroyed or not self.cubes[cube] or cube:GetAttribute("Collected") then
		return
	end
	cube:SetAttribute("Collected", true)
	self.cubes[cube] = nil
	self.cubeCount = math.max(0, self.cubeCount - 1)
	local raw = cube:GetAttribute("Value")
	local value: number = Config.CUBE_VALUE
	if type(raw) == "number" then
		value = raw
	end
	local cash = getCash(self.player)
	if cash then
		local rebirthMult = tonumber((self.player :: Player):GetAttribute("RebirthMult")) or 1
		local amount = math.floor(value * (tonumber(self.mods.cashMult) or 1) * rebirthMult + 0.5)
		cash.Value += amount
		sendCashIn(self.player :: Player, amount, tonumber(self.mods.ore) or 1, (self.plot.collector :: BasePart).Position)
	end
	Telemetry.count("cubes_collected", 1)
	cube:Destroy()
end

function Tycoon._step(self: any)
	if self.destroyed then
		return
	end
	local conveyor: BasePart = self.plot.conveyor
	local dir: Vector3 = self.dir
	local endT: number = Config.CONVEYOR_LENGTH / 2 + 1
	local now = os.clock()
	for cube in pairs(self.cubes) do
		local part = cube :: BasePart
		if not part.Parent then
			self.cubes[part] = nil
			self.cubeCount = math.max(0, self.cubeCount - 1)
		else
			local born = part:GetAttribute("Born")
			local rel = part.Position - conveyor.Position
			if part.Position.Y < conveyor.Position.Y - 30 or (type(born) == "number" and now - born > CUBE_LIFETIME) then
				self:_removeCube(part)
			elseif rel:Dot(dir) >= endT then
				self:_collect(part)
			else
				local v = part.AssemblyLinearVelocity
				local spd: number = self.speed * (tonumber(self.mods.speedMult) or 1)
				part.AssemblyLinearVelocity = Vector3.new(dir.X * spd, v.Y, dir.Z * spd)
			end
		end
	end
end

function Tycoon._wireButton(self: any, button: BasePart, key: string, cost: number, onBuy: () -> string)
	local lastNeedToast = 0
	local originalColor = button.Color
	table.insert(self.restore, function()
		button.Color = originalColor
	end)
	table.insert(self.connections, button.Touched:Connect(function(hit: BasePart)
		-- Already bought or torn down: ignore every further touch.
		if self.destroyed or self.bought[key] then
			return
		end
		local model = hit:FindFirstAncestorOfClass("Model")
		if not model then
			return
		end
		local touchPlayer = Players:GetPlayerFromCharacter(model)
		if touchPlayer == nil or touchPlayer ~= self.player then
			return
		end
		-- Only the plot's owner may use its pads.
		if not isOwner(touchPlayer, self.plot) then
			return
		end
		local cash = getCash(self.player)
		if not cash then
			return
		end
		if cash.Value >= cost then
			-- Mark bought BEFORE deducting so re-entrant touches cannot double-buy.
			self.bought[key] = true
			cash.Value -= cost
			button.Color = Config.BOUGHT_COLOR
			local ok, msg = pcall(onBuy)
			if ok then
				self.notify:FireClient(self.player, tostring(msg))
			else
				-- Refund and allow retry if the purchase effect failed.
				self.bought[key] = false
				cash.Value += cost
				button.Color = originalColor
				warn("Tycoon buy failed for " .. key .. ": " .. tostring(msg))
			end
		else
			local now = os.clock()
			if now - lastNeedToast >= NEED_TOAST_INTERVAL then
				lastNeedToast = now
				self.notify:FireClient(self.player, "Need $" .. tostring(cost))
			end
		end
	end))
end

function Tycoon.destroy(self: any)
	if self.destroyed then
		return
	end
	self.destroyed = true
	for _, c in ipairs(self.connections) do
		(c :: RBXScriptConnection):Disconnect()
	end
	self.connections = {}
	self.cubes = {}
	self.cubeCount = 0
	if self.folder then
		(self.folder :: Instance):Destroy()
		self.folder = nil
	end
	for _, fn in ipairs(self.restore) do
		pcall(fn)
	end
	self.restore = {}
	if activeByPlot[self.plot] == self then
		activeByPlot[self.plot] = nil
	end
end

-- Called by PlotClaimService when a player claims a plot: starts dropper loop, collector and pads.
function Tycoon.startPlot(player: Player, plot: any): any
	local existing = activeByPlot[plot]
	if existing then
		if existing.player == player and not existing.destroyed then
			return existing
		end
		existing:destroy()
	end
	local tycoon = Tycoon.new(player, plot)
	activeByPlot[plot] = tycoon
	tycoon:start()
	return tycoon
end

-- Stores a player's upgrade modifiers and applies them to their running tycoon (called by UpgradeService).
function Tycoon.setModifiers(player: Player, mods: any)
	local merged = mergeMods(mods)
	modsByPlayer[player] = merged
	for _, t in pairs(activeByPlot) do
		if t.player == player and not t.destroyed then
			t.mods = merged
		end
	end
end

Players.PlayerRemoving:Connect(function(p: Player)
	modsByPlayer[p] = nil
end)

-- Halts a plot's dropper loop and clears its cubes (e.g. when its owner leaves).
function Tycoon.stopPlot(plot: any)
	local existing = activeByPlot[plot]
	if existing then
		existing:destroy()
	end
	activeByPlot[plot] = nil
end

return Tycoon
