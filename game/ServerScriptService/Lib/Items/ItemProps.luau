--!strict
-- ItemProps [owner: Inventory]. Builds the chunky physical look of each gear item (ItemDefs ids), in
-- one of four modes, always as parts welded to a part named "Handle":
--   ItemProps.build(id, "world", scale?)  -> Model  loose physics prop (Handle collides, light, bouncy)
--   ItemProps.build(id, "display", scale?)-> Model  rack / compartment display (massless, no collision)
--   ItemProps.build(id, "back", scale?)   -> Model  strapped on a character's back (massless, no collision)
--   ItemProps.tool(id) -> Tool                       a plain hand Tool for items ToolService doesn't make
-- The Hose nozzle has an Attachment "HoseEnd" at the tail of its Handle (the reel line ties on there).
-- Nothing runs at require time.

local ItemDefs = require(game:GetService("ReplicatedStorage"):WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript)

local ItemProps = {}

type PartSpec = {
	name: string,
	size: Vector3,
	at: CFrame,
	color: string,
	material: Enum.Material?,
	shape: Enum.PartType?,
}

local ROT_UP = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y

local SPECS: { [string]: { PartSpec } } = {
	Axe = {
		{ name = "Handle", size = Vector3.new(0.45, 3.4, 0.45), at = CFrame.new(), color = "#8A4A28", material = Enum.Material.Wood },
		{ name = "Head", size = Vector3.new(0.35, 1.0, 1.5), at = CFrame.new(0, 1.35, -0.55), color = "#D6D8DC", material = Enum.Material.Metal },
		{ name = "Back", size = Vector3.new(0.4, 0.55, 0.55), at = CFrame.new(0, 1.35, 0.4), color = "#C0301E" },
		{ name = "Grip", size = Vector3.new(0.55, 0.9, 0.55), at = CFrame.new(0, -1.3, 0), color = "#1A1210" },
	},
	Extinguisher = {
		{ name = "Handle", size = Vector3.new(1.0, 2.1, 1.0), at = CFrame.new(), color = "#C8232B" },
		{ name = "Band", size = Vector3.new(1.06, 0.45, 1.06), at = CFrame.new(0, 0.1, 0), color = "#F2EDE4" },
		{ name = "Cap", size = Vector3.new(0.6, 0.45, 0.6), at = CFrame.new(0, 1.25, 0), color = "#D6D8DC", material = Enum.Material.Metal },
		{ name = "Horn", size = Vector3.new(0.35, 0.35, 1.2), at = CFrame.new(0, 1.25, -0.8), color = "#1A1210" },
	},
	OxygenTank = {
		{ name = "Handle", size = Vector3.new(2.6, 1.25, 1.25), at = ROT_UP, color = "#C9CCD0", material = Enum.Material.Metal, shape = Enum.PartType.Cylinder },
		{ name = "Shoulder", size = Vector3.new(1.25, 1.25, 1.25), at = CFrame.new(0, 1.3, 0), color = "#C9CCD0", material = Enum.Material.Metal, shape = Enum.PartType.Ball },
		{ name = "Band", size = Vector3.new(0.45, 1.32, 1.32), at = CFrame.new(0, 0.5, 0) * ROT_UP, color = "#E8B83A", shape = Enum.PartType.Cylinder },
		{ name = "Valve", size = Vector3.new(0.5, 0.5, 0.5), at = CFrame.new(0, 1.95, 0), color = "#C89A3C", material = Enum.Material.Metal },
		{ name = "Tag", size = Vector3.new(0.7, 0.7, 0.1), at = CFrame.new(0, -0.2, -0.62), color = "#2A9D8F" },
	},
	Hose = {
		{ name = "Handle", size = Vector3.new(0.65, 0.65, 2.4), at = CFrame.new(), color = "#E8B83A" },
		{ name = "Tip", size = Vector3.new(0.8, 0.8, 0.6), at = CFrame.new(0, 0, -1.5), color = "#C89A3C", material = Enum.Material.Metal },
		{ name = "Grip", size = Vector3.new(0.35, 0.9, 0.35), at = CFrame.new(0, -0.6, 0.2), color = "#D6D8DC", material = Enum.Material.Metal },
	},
}

local function makePart(spec: PartSpec, scale: number): Part
	local p = Instance.new("Part")
	p.Name = spec.name
	p.Size = spec.size * scale
	p.Color = Color3.fromHex(spec.color)
	p.Material = spec.material or Enum.Material.SmoothPlastic
	if spec.shape then
		p.Shape = spec.shape
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CastShadow = true
	return p
end

-- Parts are laid out around the origin; the Handle's own rotation (OxygenTank) is part of its spec.
local function assemble(id: string, scale: number): (Model, BasePart)
	local m = Instance.new("Model")
	m.Name = id
	local specs = SPECS[id] or SPECS.Axe
	local handle: BasePart? = nil
	for _, spec in specs do
		local p = makePart(spec, scale)
		local at = spec.at
		p.CFrame = CFrame.new(at.Position * scale) * at.Rotation
		p.Parent = m
		if spec.name == "Handle" then
			handle = p
		end
	end
	local h = handle :: BasePart
	for _, p in m:GetChildren() do
		if p ~= h and p:IsA("BasePart") then
			local w = Instance.new("WeldConstraint")
			w.Part0 = h
			w.Part1 = p
			w.Parent = h
		end
	end
	m.PrimaryPart = h
	-- the model's pivot is always the upright item frame, even when the Handle is a rotated cylinder
	h.PivotOffset = h.CFrame.Rotation:Inverse()
	if id == "Hose" then
		local a = Instance.new("Attachment")
		a.Name = "HoseEnd"
		a.Position = Vector3.new(0, 0, h.Size.Z / 2)
		a.Parent = h
	end
	return m, h
end

function ItemProps.build(id: string, mode: string, scale: number?): Model
	local m, handle = assemble(id, scale or 1)
	for _, p in m:GetDescendants() do
		if p:IsA("BasePart") then
			p.Anchored = false
			if mode == "world" then
				p.CanCollide = p == handle
				p.CanQuery = true
				p.CanTouch = p == handle
				p.Massless = p ~= handle
			else
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.Massless = true
				p.CastShadow = mode == "display"
			end
		end
	end
	if mode == "world" then
		-- light and bouncy so throws tumble and skitter
		handle.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.5, 0.45, 1, 1)
	end
	m:SetAttribute("Item", id)
	return m
end

-- A plain hand Tool (no behaviour) for items without a ToolService tool, e.g. the oxygen tank.
function ItemProps.tool(id: string): Tool
	local def = ItemDefs.get(id)
	local tool = Instance.new("Tool")
	tool.Name = id
	tool.ToolTip = if def then `{def.name} (hold Q to throw)` else id
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	local m = ItemProps.build(id, "back", 1)
	for _, p in m:GetChildren() do
		p.Parent = tool
	end
	m:Destroy()
	tool.Grip = if id == "OxygenTank" then CFrame.new(0, 0, 0.3) * CFrame.Angles(0, 0, math.rad(90)) else CFrame.new()
	return tool
end

return ItemProps
