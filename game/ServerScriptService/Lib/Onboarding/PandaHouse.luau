--!strict
-- PandaHouse [owner: Onboarding]. The cold-open set for Onboarding v3 (Services/FirstFireService):
-- a small cottage on fire with a panda trapped at its front window, and a parked fire truck.
-- Built from parts only (MapKit, TruckBuilder): no paid or uploaded assets.
--
--   PandaHouse.build(index: number, cf: CFrame, truckCf: CFrame?) -> Model
--       cf = the ground point in the middle of the house's FRONT wall; the house faces -Z of cf and
--       reaches 16 studs back (+Z). truckCf = where the prop truck parks (ground under its centre,
--       facing -Z of truckCf), or nil for no truck.
--   The model (Name "Spot<index>", attr TrainingFire = true) holds:
--     * fuel items, each in its own sub-model "Fuel_<name>" (one FireService location each, so what you
--       put out stays out): RoofFire (on the roof), Sofa (inside, back left), Crates (porch, outside left),
--       Bin (outside right). Every fuel part: tag Flammable, attr Fuel, attr NoHeat (HeatService skips it).
--       All of them are >= 8 studs from the panda (RescueConfig.FireHurtRadius is 5).
--     * "PandaSpot": invisible RescueSpawn-style marker (feet 1 stud below its centre, facing -Z = out of
--       the window), attr Kind "Panda", Pose "sitting". RescueService:SpawnAt puts the panda there.
--     * "SafeSpot": invisible marker on the lawn in front (where the guide arrow points while you carry
--       the panda; RescueService's "outside is safe" rule rescues it anywhere outside).
--     * "CamHouse", "CamTruck", "CamPanda", "LookHouse", "LookPanda": invisible camera markers for the
--       cold-open cutscene (Controllers/ColdOpenController reads them by name).
--     * "PropTruck": TruckBuilder's truck with every tag, prompt and collision stripped (it's scenery:
--       no seats, no hose reel, no rescue drop-off, no traffic hits). attr ParkedCFrame = truckCf.
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapLib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Map")
local MapKit = require(MapLib:WaitForChild("MapKit") :: ModuleScript)

local PandaHouse = {}

local WALL = Color3.fromRGB(244, 162, 97) -- peach
local TRIM = Color3.fromRGB(240, 236, 228)
local ROOF = Color3.fromRGB(150, 62, 52)
local FLOOR = Color3.fromRGB(150, 100, 60)
local SOFA = Color3.fromRGB(42, 157, 143)
local CRATE = Color3.fromRGB(160, 116, 70)
local BIN = Color3.fromRGB(46, 102, 62)

local W = 11 -- half width (x -11..11)
local D = 16 -- depth (z 0..16)
local H = 10 -- wall height

local function solid(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material?): Part
	return MapKit.part(parent, name, cf, size, { color = color, material = material, flammable = false })
end

local function marker(parent: Instance, name: string, cf: CFrame): Part
	local p = MapKit.part(parent, name, cf, Vector3.new(1, 1, 1), { transparency = 1, collide = false, flammable = false })
	p.CanQuery = false
	return p
end

-- one fuel item = its own sub-model (FireService location)
local function fuel(model: Model, name: string, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material, fuelSeconds: number, shape: Enum.PartType?): Part
	local holder = Instance.new("Model")
	holder.Name = `Fuel_{name}`
	holder.Parent = model
	local p = MapKit.part(holder, name, cf, size, {
		color = color,
		material = material,
		flammable = true,
		fuel = fuelSeconds,
		shape = shape,
		collide = false,
	})
	p:SetAttribute("NoHeat", true) -- HeatService: a newbie reading the card must not get cooked
	return p
end

local function strip(model: Instance)
	for _, d in model:GetDescendants() do
		for _, t in CollectionService:GetTags(d) do
			CollectionService:RemoveTag(d, t)
		end
		if d:IsA("ProximityPrompt") or d:IsA("Seat") or d:IsA("VehicleSeat") or d:IsA("Sound") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
	for _, t in CollectionService:GetTags(model) do
		CollectionService:RemoveTag(model, t)
	end
end

local function truck(parent: Instance, cf: CFrame): Model?
	local ok, TruckBuilder = pcall(require, MapLib:WaitForChild("Props"):WaitForChild("TruckBuilder") :: ModuleScript)
	if not ok then
		return nil
	end
	local holder = Instance.new("Model") -- built unparented: no tag-added signals fire for it
	local okBuild, t = pcall((TruckBuilder :: any).Build, holder, cf)
	if not okBuild or typeof(t) ~= "Instance" or not t:IsA("Model") then
		return nil
	end
	local m = t :: Model
	m.Name = "PropTruck"
	strip(m)
	m:SetAttribute("ParkedCFrame", cf)
	m.Parent = parent
	holder:Destroy()
	return m
end

function PandaHouse.build(index: number, cf: CFrame, truckCf: CFrame?): Model
	local m = Instance.new("Model")
	m.Name = `Spot{index}`
	m:SetAttribute("TrainingFire", true)
	local shell = Instance.new("Model")
	shell.Name = "House"
	shell.Parent = m
	local function L(x: number, y: number, z: number): CFrame
		return cf * CFrame.new(x, y, z)
	end

	-- floor + porch step
	local floor = solid(shell, "Floor", L(0, 0.15, D / 2), Vector3.new(W * 2, 0.3, D), FLOOR, Enum.Material.WoodPlanks)
	m.PrimaryPart = floor
	solid(shell, "Porch", L(-6, 0.15, -2), Vector3.new(8, 0.3, 4), TRIM, Enum.Material.WoodPlanks)

	-- back + side walls
	solid(shell, "WallBack", L(0, H / 2, D - 0.5), Vector3.new(W * 2, H, 1), WALL)
	solid(shell, "WallL", L(-W + 0.5, H / 2, D / 2), Vector3.new(1, H, D), WALL)
	solid(shell, "WallR", L(W - 0.5, H / 2, D / 2), Vector3.new(1, H, D), WALL)
	-- front wall (z = 0): a wide open doorway at x -8.5..-3.5 (no door to fumble with), the panda window at
	-- x 0..6, y 3..9
	solid(shell, "FrontA", L(-9.75, H / 2, 0.5), Vector3.new(2.5, H, 1), WALL) -- -11..-8.5
	solid(shell, "DoorTop", L(-6, 8.5, 0.5), Vector3.new(5, 3, 1), WALL) -- over the door (7..10)
	solid(shell, "FrontB", L(-1.75, H / 2, 0.5), Vector3.new(3.5, H, 1), WALL) -- -3.5..0
	solid(shell, "Sill", L(3, 1.5, 0.5), Vector3.new(6, 3, 1), WALL) -- under the window
	solid(shell, "WinTop", L(3, 9.5, 0.5), Vector3.new(6, 1, 1), WALL) -- over the window
	solid(shell, "FrontC", L(8.5, H / 2, 0.5), Vector3.new(5, H, 1), WALL) -- 6..11
	-- white trim round the window and the door
	solid(shell, "SillTrim", L(3, 3.1, -0.2), Vector3.new(7, 0.4, 0.8), TRIM)
	solid(shell, "WinTrimTop", L(3, 9.1, -0.1), Vector3.new(7, 0.4, 0.4), TRIM)
	solid(shell, "WinTrimL", L(-0.1, 6, -0.1), Vector3.new(0.4, 6.4, 0.4), TRIM)
	solid(shell, "WinTrimR", L(6.1, 6, -0.1), Vector3.new(0.4, 6.4, 0.4), TRIM)
	solid(shell, "DoorTrim", L(-6, 7.1, -0.1), Vector3.new(5.8, 0.4, 0.4), TRIM)

	-- gable roof: ridge along X over the middle of the house
	local pitch = math.rad(32)
	local half = D / 2 + 1.2
	local slope = half / math.cos(pitch)
	local rise = half * math.tan(pitch)
	solid(shell, "RoofFront", L(0, H + rise / 2, D / 2 - half / 2) * CFrame.Angles(pitch, 0, 0), Vector3.new(W * 2 + 2, 0.8, slope), ROOF, Enum.Material.Slate)
	solid(shell, "RoofBack", L(0, H + rise / 2, D / 2 + half / 2) * CFrame.Angles(-pitch, 0, 0), Vector3.new(W * 2 + 2, 0.8, slope), ROOF, Enum.Material.Slate)
	-- gable ends (two stacked steps each side: chunky, reads as a triangle from the street)
	for _, side in { -1, 1 } do
		solid(shell, `Gable{side}a`, L(side * (W - 0.5), H + rise * 0.25, D / 2), Vector3.new(1, rise * 0.5, D * 0.75), WALL)
		solid(shell, `Gable{side}b`, L(side * (W - 0.5), H + rise * 0.7, D / 2), Vector3.new(1, rise * 0.4, D * 0.35), WALL)
	end
	solid(shell, "Chimney", L(-6, H + rise + 1, D / 2 + 2), Vector3.new(2.4, 5, 2.4), Color3.fromRGB(120, 60, 50), Enum.Material.Brick)

	-- inside: a tall toy chest under the window (the panda sits on it, head in the window). Its top is 2.6
	-- above the floor, more than RescueConfig.StepDown (2.2), so the panicking panda stays up there in
	-- the window instead of waddling off into the house
	solid(shell, "ToyChest", L(3, 1.6, 2.4), Vector3.new(5.6, 2.6, 3.6), Color3.fromRGB(231, 111, 81))
	solid(shell, "Rug", L(0, 0.35, 9), Vector3.new(10, 0.1, 7), Color3.fromRGB(205, 180, 219), Enum.Material.Fabric)
	-- a mailbox and a little picket fence bit, so it reads as a home from the street
	solid(shell, "MailPost", L(9, 1.6, -5), Vector3.new(0.4, 3.2, 0.4), CRATE, Enum.Material.Wood)
	solid(shell, "Mailbox", L(9, 3.5, -5), Vector3.new(1.2, 1, 2), MapKit.Red)
	for i = 0, 3 do
		solid(shell, `Picket{i}`, L(-11 + i * 1.4, 1.2, -6), Vector3.new(0.4, 2.4, 0.3), TRIM)
	end
	solid(shell, "PicketRail", L(-8.9, 1.6, -6), Vector3.new(4.6, 0.3, 0.2), TRIM)

	-- the fire (four fuel items; FirstFireService ignites every Flammable part under each holder)
	fuel(m, "RoofFire", L(-5, H + rise * 0.55, D / 2 - half * 0.45) * CFrame.Angles(pitch, 0, 0), Vector3.new(6, 1.2, 4), ROOF, Enum.Material.Slate, 100000)
	fuel(m, "Sofa", L(-7, 1.6, 12.5), Vector3.new(5, 2.6, 2.6), SOFA, Enum.Material.Fabric, 100000)
	fuel(m, "Crates", L(-10, 1.6, -3.5), Vector3.new(2.8, 2.8, 2.8), CRATE, Enum.Material.WoodPlanks, 100000)
	local bin = fuel(m, "Bin", L(14, 1.4, 4), Vector3.new(2.8, 2.4, 2.4), BIN, Enum.Material.Metal, 100000, Enum.PartType.Cylinder)
	bin.CFrame = L(14, 1.4, 4) * CFrame.Angles(0, 0, math.rad(90)) -- a cylinder's axis is X: stand it up

	-- markers
	local panda = marker(m, "PandaSpot", L(3, 2.9 + 1, 2.4)) -- feet on the toy chest, facing out (-Z)
	panda:SetAttribute(Names.Attr.Kind, "Panda")
	panda:SetAttribute("Pose", "sitting")
	marker(m, "SafeSpot", L(-2, 1, -12))
	marker(m, "LookHouse", L(0, 6, 4))
	marker(m, "LookPanda", L(3, 6.8, 2.4))
	marker(m, "CamHouse", L(-22, 13, -30))
	marker(m, "CamPanda", L(4.5, 7.2, -9))
	if truckCf then
		-- beside the road the truck comes in on, ahead of where it parks: it drives up past the camera
		marker(m, "CamTruck", truckCf * CFrame.new(-24, 5, 14))
		truck(m, truckCf)
	end
	return m
end

return PandaHouse
