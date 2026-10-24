--!strict
-- StreetLampService. Crash a fire truck into a street lamp and it topples over: the lamp is welded
-- into one piece, unanchored, tipped along the truck's direction, the bulb goes dark with a spark +
-- "CRASH!" pop, and the truck loses a little speed. After RestoreSeconds (once nobody is close) the
-- lamp stands back up, lit, exactly where it was.
-- Lamps: Models named "StreetLamp" (CityBuilder) or tagged "KnockableLamp" anywhere in Workspace.Map.
-- Trucks: Models tagged Truck (VehicleService), checked ~10x/s against the lamp poles in front of them.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any

local StreetLampService = {}
StreetLampService.Priority = 60

local HIT_SPEED = 16 -- studs/s: slower bumps don't knock a lamp over
local RESTORE_SECONDS = 45
local RESTORE_CLEAR = 30 -- nobody within this many studs before it pops back up
local TICK = 0.1
local TRUCK_SLOWDOWN = 0.8 -- the truck keeps this much of its horizontal speed

type Lamp = {
	model: Model,
	pole: BasePart,
	home: { [BasePart]: CFrame },
	welds: { WeldConstraint },
	down: boolean,
	downAt: number,
	lights: { [Light]: boolean },
	heads: { [BasePart]: Enum.Material },
}

local services: { [string]: any } = {}
local lamps: { [BasePart]: Lamp } = {} -- by pole
local poles: { BasePart } = {}

local function isLamp(inst: Instance): boolean
	return inst:IsA("Model") and (inst.Name == "StreetLamp" or inst:HasTag("KnockableLamp"))
end

local function register(model: Model)
	local pole = (model:FindFirstChild("Pole") or model.PrimaryPart) :: BasePart?
	if not pole or not pole:IsA("BasePart") or lamps[pole] then
		return
	end
	local l: Lamp = { model = model, pole = pole, home = {}, welds = {}, down = false, downAt = 0, lights = {}, heads = {} }
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			l.home[d] = d.CFrame
		end
	end
	lamps[pole] = l
	table.insert(poles, pole)
end

local function knock(l: Lamp, truckRoot: BasePart, vel: Vector3)
	l.down = true
	l.downAt = os.clock()
	-- one rigid piece
	for part in l.home do
		if part ~= l.pole and part.Parent then
			local w = Instance.new("WeldConstraint")
			w.Part0 = l.pole
			w.Part1 = part
			w.Parent = l.pole
			table.insert(l.welds, w)
		end
	end
	for part in l.home do
		if part.Parent then
			part.Anchored = false
		end
	end
	pcall(function()
		l.pole:SetNetworkOwner(nil)
	end)
	-- tip over along the truck's direction: spin about the horizontal axis across its path
	local dir = Vector3.new(vel.X, 0, vel.Z)
	dir = if dir.Magnitude > 0.1 then dir.Unit else truckRoot.CFrame.LookVector
	local axis = dir:Cross(Vector3.yAxis)
	l.pole.AssemblyAngularVelocity = -axis * 1.6 -- a lean, then gravity does the rest
	l.pole.AssemblyLinearVelocity = dir * math.min(vel.Magnitude * 0.25, 10)
	-- the bulb dies
	for _, d in l.model:GetDescendants() do
		if d:IsA("Light") then
			l.lights[d] = d.Enabled
			d.Enabled = false
		elseif d:IsA("BasePart") and d.Material == Enum.Material.Neon then
			l.heads[d] = d.Material
			d.Material = Enum.Material.SmoothPlastic
		end
	end
	-- sparks + pop
	local spark = Instance.new("Attachment")
	spark.Name = "LampSpark"
	spark.Position = Vector3.new(0, l.pole.Size.Y * 0.4, 0)
	spark.Parent = l.pole
	local pe = Instance.new("ParticleEmitter")
	pe.Color = ColorSequence.new(Color3.fromRGB(255, 220, 120))
	pe.LightEmission = 1
	pe.Size = NumberSequence.new(0.25, 0)
	pe.Speed = NumberRange.new(14, 26)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Lifetime = NumberRange.new(0.3, 0.6)
	pe.Rate = 0
	pe.Parent = spark
	pe:Emit(40)
	task.delay(1.5, function()
		spark:Destroy()
	end)
	local Fx = services.PhysicsFxService
	if Fx and type(Fx.Pop) == "function" then
		pcall(Fx.Pop, Fx, "land", l.pole.Position + Vector3.new(0, 6, 0), "CRASH!")
	end
	-- the truck feels it
	local v = truckRoot.AssemblyLinearVelocity
	truckRoot.AssemblyLinearVelocity = Vector3.new(v.X * TRUCK_SLOWDOWN, v.Y, v.Z * TRUCK_SLOWDOWN)
	local Tel = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if Tel then
		pcall(function()
			(require(Tel :: ModuleScript) :: any).count("lamps_knocked", 1)
		end)
	end
end

local function restore(l: Lamp)
	for _, w in l.welds do
		w:Destroy()
	end
	table.clear(l.welds)
	for part, cf in l.home do
		if part.Parent then
			part.Anchored = true
			part.AssemblyLinearVelocity = Vector3.zero
			part.AssemblyAngularVelocity = Vector3.zero
			part.CFrame = cf
		end
	end
	for light, on in l.lights do
		if light.Parent then
			light.Enabled = on
		end
	end
	for head, mat in l.heads do
		if head.Parent then
			head.Material = mat
		end
	end
	table.clear(l.lights)
	table.clear(l.heads)
	l.down = false
end

local function someoneNear(pos: Vector3): boolean
	for _, p in Players:GetPlayers() do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root and (root.Position - pos).Magnitude < RESTORE_CLEAR then
			return true
		end
	end
	return false
end

local function step()
	if #poles == 0 then
		return
	end
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Include
	op.FilterDescendantsInstances = poles
	for _, truck in CollectionService:GetTagged(Names.Tag.Truck or "Truck") do
		if not truck:IsA("Model") or not truck:IsDescendantOf(workspace) then
			continue
		end
		local root = truck.PrimaryPart
		if not root then
			continue
		end
		local vel = root.AssemblyLinearVelocity
		if Vector3.new(vel.X, 0, vel.Z).Magnitude < HIT_SPEED then
			continue
		end
		local cf, size = truck:GetBoundingBox()
		for _, hit in workspace:GetPartBoundsInBox(cf, size + Vector3.new(2, 0, 2), op) do
			local l = lamps[hit :: BasePart]
			if l and not l.down then
				knock(l, root, vel)
			end
		end
	end
	local now = os.clock()
	for _, l in lamps do
		if l.down and now - l.downAt > RESTORE_SECONDS and not someoneNear(l.pole.Position) then
			restore(l)
		end
	end
end

function StreetLampService:Init(all: { [string]: any })
	services = all
end

function StreetLampService:Start()
	task.spawn(function()
		while workspace:GetAttribute(Names.Attr.MapReady or "MapReady") ~= true do
			task.wait(0.5)
		end
		local map = workspace:FindFirstChild("Map")
		if map then
			for _, d in map:GetDescendants() do
				if isLamp(d) then
					register(d :: Model)
				end
			end
			map.DescendantAdded:Connect(function(d)
				if isLamp(d) then
					task.defer(register, d :: Model)
				end
			end)
		end
		local acc = 0
		RunService.Heartbeat:Connect(function(dt)
			acc += dt
			if acc >= TICK then
				acc = 0
				local ok, err = pcall(step)
				if not ok then
					warn(`[StreetLampService] {err}`)
				end
			end
		end)
	end)
end

function StreetLampService:_knockNearest(pos: Vector3): boolean
	local best, bd = nil, math.huge
	for _, l in lamps do
		local d = (l.pole.Position - pos).Magnitude
		if d < bd and not l.down then
			best, bd = l, d
		end
	end
	if not best then
		return false
	end
	knock(best, best.pole, Vector3.new(30, 0, 0))
	return true
end

function StreetLampService:_count(): (number, number)
	local down = 0
	for _, l in lamps do
		if l.down then
			down += 1
		end
	end
	return #poles, down
end

return StreetLampService
