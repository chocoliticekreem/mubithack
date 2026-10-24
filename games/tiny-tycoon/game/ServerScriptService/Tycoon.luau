--!strict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(ReplicatedStorage:WaitForChild("Config")) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry")) :: any

local Tycoon = {}
Tycoon.__index = Tycoon

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

function Tycoon.new(player: Player, plot: any): any
	local self: any = setmetatable({}, Tycoon)
	self.player = player
	self.plot = plot
	self.destroyed = false
	self.speed = Config.CONVEYOR_SPEED
	self.cubes = {} :: { [Instance]: boolean }
	self.cubeCount = 0
	self.connections = {} :: { RBXScriptConnection }
	self.bought = { dropper = false, conveyor = false }
	self.notify = getNotifyRemote()

	-- Starting bankroll so the first upgrade is reachable within ~30s.
	if not player:GetAttribute("StartCashGranted") then
		local startCash = Config.START_CASH
		if type(startCash) ~= "number" then
			startCash = 10
		end
		local cash = getCash(player)
		if cash and cash.Value == 0 then
			cash.Value = startCash
		end
		player:SetAttribute("StartCashGranted", true)
	end

	local flat = Vector3.new(plot.conveyorDir.X, 0, plot.conveyorDir.Z)
	self.dir = if flat.Magnitude > 0.001 then flat.Unit else Vector3.new(0, 0, 1)

	local folder = Instance.new("Folder")
	folder.Name = "Cubes_" .. player.UserId
	folder.Parent = Workspace
	self.folder = folder

	self.activeDroppers = { plot.droppers[1] }

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

	self:_wireButton(plot.dropperButton, "dropper", Config.DROPPER_COST, function(): string
		local slot2 = plot.droppers[2] or plot.dropperSlot2
		if slot2 then
			slot2.Transparency = 0
			slot2.Color = Config.DROPPER_COLOR
			table.insert(self.activeDroppers, slot2)
		end
		Telemetry.count("dropper_bought", 1)
		return "Second dropper bought!"
	end)
	self:_wireButton(plot.conveyorButton, "conveyor", Config.CONVEYOR_COST, function(): string
		self.speed = Config.FAST_CONVEYOR_SPEED
		Telemetry.count("conveyor_bought", 1)
		return "Faster conveyor bought!"
	end)

	task.spawn(function()
		while not self.destroyed do
			for _, dropper in ipairs(self.activeDroppers) do
				self:_spawnCube(dropper)
			end
			task.wait(Config.DROP_INTERVAL)
		end
	end)

	return self
end

function Tycoon._spawnCube(self: any, dropper: BasePart)
	if self.destroyed or self.cubeCount >= Config.MAX_CUBES_PER_PLOT then
		return
	end
	local conveyor: BasePart = self.plot.conveyor
	local dir: Vector3 = self.dir
	local half: number = Config.CONVEYOR_LENGTH / 2 - 2
	local t = math.clamp((dropper.Position - conveyor.Position):Dot(dir), -half, half)
	local pos = conveyor.Position + dir * t
	local y = conveyor.Position.Y + conveyor.Size.Y / 2 + Config.CUBE_SIZE.Y / 2 + 0.5
	local cube = Instance.new("Part")
	cube.Name = "Cube"
	cube.Size = Config.CUBE_SIZE
	cube.Color = Config.CUBE_COLOR
	cube.Material = Enum.Material.Neon
	cube.Anchored = false
	cube.CanCollide = true
	cube.CFrame = CFrame.new(Vector3.new(pos.X, y, pos.Z))
	cube:SetAttribute("Value", Config.CUBE_VALUE)
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
	if self.destroyed or not self.cubes[cube] or cube:GetAttribute("Collected") then
		return
	end
	cube:SetAttribute("Collected", true)
	local raw = cube:GetAttribute("Value")
	local value: number = Config.CUBE_VALUE
	if type(raw) == "number" then
		value = raw
	end
	local cash = getCash(self.player)
	if cash then
		cash.Value += value
	end
	Telemetry.count("cubes_collected", 1)
	self:_removeCube(cube)
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
			if part.Position.Y < conveyor.Position.Y - 30 or (type(born) == "number" and now - born > 40) then
				self:_removeCube(part)
			elseif rel:Dot(dir) >= endT then
				self:_collect(part)
			else
				local v = part.AssemblyLinearVelocity
				part.AssemblyLinearVelocity = Vector3.new(dir.X * self.speed, v.Y, dir.Z * self.speed)
			end
		end
	end
end

function Tycoon._wireButton(self: any, button: BasePart, key: string, cost: number, onBuy: () -> string)
	local busy = false
	table.insert(self.connections, button.Touched:Connect(function(hit: BasePart)
		if busy or self.destroyed or self.bought[key] then
			return
		end
		local touchPlayer = Players:GetPlayerFromCharacter(hit.Parent)
		if touchPlayer ~= self.player then
			return
		end
		busy = true
		local cooldown = 0
		local ok = pcall(function()
			local cash = getCash(self.player)
			if cash and cash.Value >= cost then
				self.bought[key] = true
				cash.Value -= cost
				button.Color = Config.BOUGHT_COLOR
				local msg = onBuy()
				self.notify:FireClient(self.player, msg)
			else
				cooldown = 1.5
				self.notify:FireClient(self.player, "Need $" .. tostring(cost))
			end
		end)
		if not ok then
			cooldown = 1
		end
		-- single exit point: busy is always reset
		if cooldown > 0 then
			task.delay(cooldown, function()
				busy = false
			end)
		else
			busy = false
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
	end
end

return Tycoon
