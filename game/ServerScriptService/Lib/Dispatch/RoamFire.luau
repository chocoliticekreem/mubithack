--!strict
-- RoamFire [owner: Dispatch]. A small free-roam fire for the DISPATCH radio's "small jobs": a wheelie bin
-- with burning trash bags and a crate on a street corner. Built server-side by DispatchService, indexed
-- as its own FireService location (FireService:IndexLocation), so it burns, spreads a little and goes
-- out like any other fire. NoHeat: free roam has no medic, so it never cooks anyone.
--   RoamFire.build(groundCf: CFrame, fuelSeconds: number) -> Model   (flammable parts tagged Flammable)
--   RoamFire.findSpot(nodes, heads, origin, minStuds, maxStuds, clear, roll) -> CFrame?
--       a spot on the pavement beside a road node minStuds..maxStuds from origin; clear(cf) returns the
--       ground CFrame there, or nil when it's blocked (walls, cars, props)
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)

local RoamFire = {}

local function part(m: Model, name: string, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material, fuel: number?, ball: boolean?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat
	p.Anchored = true
	p.CanCollide = fuel == nil
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if ball then
		p.Shape = Enum.PartType.Ball
	end
	if fuel then
		CollectionService:AddTag(p, Names.Tag.Flammable)
		p:SetAttribute(Names.Attr.Fuel, fuel)
		p:SetAttribute("NoHeat", true)
	end
	p.Parent = m
	return p
end

function RoamFire.build(ground: CFrame, fuelSeconds: number): Model
	local m = Instance.new("Model")
	m.Name = "RoamFire"
	m:SetAttribute("RoamFire", true)
	local bin = Color3.fromRGB(52, 92, 60)
	local bag = Color3.fromRGB(30, 30, 34)
	local wood = Color3.fromRGB(160, 116, 70)
	local body = part(m, "Bin", Vector3.new(3.4, 4, 3.4), ground * CFrame.new(0, 2, 0), bin, Enum.Material.Metal)
	part(m, "Lid", Vector3.new(3.6, 0.3, 3.6), ground * CFrame.new(0, 4.6, -1.6) * CFrame.Angles(math.rad(70), 0, 0), bin, Enum.Material.Metal)
	part(m, "Trash", Vector3.new(2.6, 2.6, 2.6), ground * CFrame.new(0, 4.4, 0), bag, Enum.Material.SmoothPlastic, fuelSeconds, true)
	part(m, "Bag1", Vector3.new(2.2, 2.2, 2.2), ground * CFrame.new(2.8, 1.1, 0.6), bag, Enum.Material.SmoothPlastic, fuelSeconds, true)
	part(m, "Bag2", Vector3.new(1.9, 1.9, 1.9), ground * CFrame.new(-2.6, 0.95, -0.4), bag, Enum.Material.SmoothPlastic, fuelSeconds, true)
	part(m, "Crate", Vector3.new(2.2, 2.2, 2.2), ground * CFrame.new(0.4, 1.1, 2.9) * CFrame.Angles(0, math.rad(20), 0), wood, Enum.Material.WoodPlanks, fuelSeconds)
	m.PrimaryPart = body
	return m
end

function RoamFire.findSpot(
	nodes: { Vector3 },
	heads: { Vector3 },
	origin: Vector3,
	minStuds: number,
	maxStuds: number,
	clear: (CFrame) -> CFrame?,
	roll: (n: number) -> number
): CFrame?
	local band: { number } = {}
	for i, p in nodes do
		local d = Vector3.new(p.X - origin.X, 0, p.Z - origin.Z).Magnitude
		if d >= minStuds and d <= maxStuds then
			table.insert(band, i)
		end
	end
	for _ = 1, math.min(12, #band) do
		local k = roll(#band)
		local i = band[k]
		table.remove(band, k)
		local p = nodes[i]
		local h = heads[i] or Vector3.new(0, 0, -1)
		local flat = Vector3.new(h.X, 0, h.Z)
		flat = if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)
		local side = Vector3.new(-flat.Z, 0, flat.X) -- across the road
		for _, s in { 15, -15, 19, -19 } do
			local at = p + side * s
			local cf = clear(CFrame.lookAt(at, at - side * math.sign(s)))
			if cf then
				return cf
			end
		end
	end
	return nil
end

return RoamFire
