--!strict
-- ItemProps [owner: Inventory]. Builds the chunky physical look of each gear item (ItemDefs ids), in
-- one of four modes, always as parts welded to a part named "Handle":
--   ItemProps.build(id, "world", scale?)  -> Model  loose physics prop (Handle collides, light, bouncy)
--   ItemProps.build(id, "display", scale?)-> Model  rack / compartment display (massless, no collision)
--   ItemProps.build(id, "back", scale?)   -> Model  strapped on a character's back (massless, no collision)
--   ItemProps.tool(id) -> Tool                       a plain hand Tool for items ToolService doesn't make
-- The Hose nozzle has an Attachment "HoseEnd" at the tail of its Handle (the reel line ties on there).
-- The Flashlight has an Attachment "Beam" on its lens (GearService hangs the SpotLight there).
-- Axe tiers (Axe = Rusty, FireAxe, GoldenAxe) share one shape with tier colours from ItemDefs.axe.
--   ItemProps.build(id, "face", scale?)   -> Model  worn on the face (gas mask; like "back")
--   ItemProps.paintAxe(container, id)                 recolour an axe Tool/Model's Head to its tier
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
	transparency: number?,
	reflect: number?,
}

local ROT_UP = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y
local ROT_FWD = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis X -> Z (round faces look along -Z)

local function axeSpecs(id: string, handle: string, handleMat: Enum.Material, back: string): { PartSpec }
	local def = ItemDefs.get(id)
	local tier = def and def.axe
	local head = if tier then tier.head else "#D6D8DC"
	local mat = (tier and (Enum.Material :: any)[tier.material]) or Enum.Material.Metal
	return {
		{ name = "Handle", size = Vector3.new(0.45, 3.4, 0.45), at = CFrame.new(), color = handle, material = handleMat },
		{ name = "Head", size = Vector3.new(0.35, 1.0, 1.5), at = CFrame.new(0, 1.35, -0.55), color = head, material = mat, reflect = tier and tier.reflect },
		{ name = "Back", size = Vector3.new(0.4, 0.55, 0.55), at = CFrame.new(0, 1.35, 0.4), color = back },
		{ name = "Grip", size = Vector3.new(0.55, 0.9, 0.55), at = CFrame.new(0, -1.3, 0), color = "#1A1210" },
	}
end

local SPECS: { [string]: { PartSpec } } = {
	Axe = {
		-- same look as the held axe (Lib/Tools/AxeBuilder): red head, silver edge, red pick
		{ name = "Handle", size = Vector3.new(0.3, 3.2, 0.3), at = CFrame.new(), color = "#8A4A28", material = Enum.Material.Wood },
		{ name = "Head", size = Vector3.new(0.32, 0.56, 0.62), at = CFrame.new(0, 1.43, -0.12), color = "#C0301E", material = Enum.Material.Metal },
		{ name = "Edge", size = Vector3.new(0.18, 0.86, 0.26), at = CFrame.new(0, 1.43, -0.55), color = "#D6D8DC", material = Enum.Material.Metal },
		{ name = "Back", size = Vector3.new(0.22, 0.26, 0.45), at = CFrame.new(0, 1.48, 0.4), color = "#C0301E", material = Enum.Material.Metal },
		{ name = "Grip", size = Vector3.new(0.36, 0.8, 0.36), at = CFrame.new(0, -1.15, 0), color = "#1A1210" },
	},
	FireAxe = axeSpecs("FireAxe", "#C0301E", Enum.Material.SmoothPlastic, "#E8B83A"),
	GoldenAxe = axeSpecs("GoldenAxe", "#3A2416", Enum.Material.Wood, "#F2C14E"),
	GasMask = {
		-- rubber face plate, two round lenses, a fat filter canister on the chin, head straps
		{ name = "Handle", size = Vector3.new(1.35, 1.25, 0.4), at = CFrame.new(0, 0, 0), color = "#2B2E33" },
		{ name = "Brow", size = Vector3.new(1.45, 0.3, 0.5), at = CFrame.new(0, 0.55, -0.02), color = "#202326" },
		{ name = "RimL", size = Vector3.new(0.14, 0.62, 0.62), at = CFrame.new(-0.32, 0.18, -0.24) * ROT_FWD, color = "#121416", shape = Enum.PartType.Cylinder },
		{ name = "RimR", size = Vector3.new(0.14, 0.62, 0.62), at = CFrame.new(0.32, 0.18, -0.24) * ROT_FWD, color = "#121416", shape = Enum.PartType.Cylinder },
		{ name = "LensL", size = Vector3.new(0.08, 0.48, 0.48), at = CFrame.new(-0.32, 0.18, -0.3) * ROT_FWD, color = "#9EE6F0", material = Enum.Material.Glass, shape = Enum.PartType.Cylinder, transparency = 0.25, reflect = 0.3 },
		{ name = "LensR", size = Vector3.new(0.08, 0.48, 0.48), at = CFrame.new(0.32, 0.18, -0.3) * ROT_FWD, color = "#9EE6F0", material = Enum.Material.Glass, shape = Enum.PartType.Cylinder, transparency = 0.25, reflect = 0.3 },
		{ name = "Snout", size = Vector3.new(0.6, 0.5, 0.35), at = CFrame.new(0, -0.38, -0.28), color = "#202326" },
		{ name = "Filter", size = Vector3.new(0.6, 0.72, 0.72), at = CFrame.new(0, -0.45, -0.68) * ROT_FWD, color = "#5A6B3A", shape = Enum.PartType.Cylinder },
		{ name = "FilterCap", size = Vector3.new(0.14, 0.78, 0.78), at = CFrame.new(0, -0.45, -1.0) * ROT_FWD, color = "#C8A23C", material = Enum.Material.Metal, shape = Enum.PartType.Cylinder },
		{ name = "StrapL", size = Vector3.new(0.12, 0.28, 1.3), at = CFrame.new(-0.72, 0.15, 0.55), color = "#1A1A1A" },
		{ name = "StrapR", size = Vector3.new(0.12, 0.28, 1.3), at = CFrame.new(0.72, 0.15, 0.55), color = "#1A1A1A" },
	},
	Halligan = {
		{ name = "Handle", size = Vector3.new(0.3, 3.8, 0.3), at = CFrame.new(), color = "#8C9096", material = Enum.Material.DiamondPlate },
		{ name = "Adz", size = Vector3.new(0.28, 0.32, 1.3), at = CFrame.new(0, 1.85, -0.45), color = "#B0B4BA", material = Enum.Material.Metal },
		{ name = "Pick", size = Vector3.new(0.24, 1.0, 0.24), at = CFrame.new(0, 2.05, 0.35) * CFrame.Angles(math.rad(-35), 0, 0), color = "#B0B4BA", material = Enum.Material.Metal },
		{ name = "ForkL", size = Vector3.new(0.14, 0.7, 0.2), at = CFrame.new(-0.12, -2.15, -0.1), color = "#B0B4BA", material = Enum.Material.Metal },
		{ name = "ForkR", size = Vector3.new(0.14, 0.7, 0.2), at = CFrame.new(0.12, -2.15, -0.1), color = "#B0B4BA", material = Enum.Material.Metal },
		{ name = "Band", size = Vector3.new(0.36, 0.5, 0.36), at = CFrame.new(0, -0.6, 0), color = "#E8B83A" },
	},
	Crowbar = {
		{ name = "Handle", size = Vector3.new(0.26, 3.0, 0.26), at = CFrame.new(), color = "#B8322A", material = Enum.Material.Metal },
		{ name = "Hook", size = Vector3.new(0.26, 0.26, 0.9), at = CFrame.new(0, 1.55, -0.32), color = "#B8322A", material = Enum.Material.Metal },
		{ name = "HookTip", size = Vector3.new(0.26, 0.5, 0.26), at = CFrame.new(0, 1.35, -0.66), color = "#B8322A", material = Enum.Material.Metal },
		{ name = "Claw", size = Vector3.new(0.3, 0.22, 0.7), at = CFrame.new(0, -1.55, -0.25), color = "#D6D8DC", material = Enum.Material.Metal },
	},
	Sledgehammer = {
		{ name = "Handle", size = Vector3.new(0.38, 3.8, 0.38), at = CFrame.new(), color = "#8A5A33", material = Enum.Material.Wood },
		{ name = "Head", size = Vector3.new(0.95, 0.95, 2.0), at = CFrame.new(0, 1.9, 0), color = "#5A5E66", material = Enum.Material.Metal },
		{ name = "FaceF", size = Vector3.new(1.05, 1.05, 0.12), at = CFrame.new(0, 1.9, -1.02), color = "#8C9096", material = Enum.Material.Metal },
		{ name = "Grip", size = Vector3.new(0.48, 1.0, 0.48), at = CFrame.new(0, -1.45, 0), color = "#1A1210" },
	},
	Ladder = {
		{ name = "Handle", size = Vector3.new(1.9, 0.22, 0.22), at = CFrame.new(), color = "#C9CCD0", material = Enum.Material.Metal },
		{ name = "RailL", size = Vector3.new(0.28, 6.2, 0.32), at = CFrame.new(-1.05, 0, 0), color = "#D6D8DC", material = Enum.Material.Metal },
		{ name = "RailR", size = Vector3.new(0.28, 6.2, 0.32), at = CFrame.new(1.05, 0, 0), color = "#D6D8DC", material = Enum.Material.Metal },
		{ name = "Rung1", size = Vector3.new(1.9, 0.22, 0.22), at = CFrame.new(0, -2.4, 0), color = "#C9CCD0", material = Enum.Material.Metal },
		{ name = "Rung2", size = Vector3.new(1.9, 0.22, 0.22), at = CFrame.new(0, -1.2, 0), color = "#C9CCD0", material = Enum.Material.Metal },
		{ name = "Rung3", size = Vector3.new(1.9, 0.22, 0.22), at = CFrame.new(0, 1.2, 0), color = "#C9CCD0", material = Enum.Material.Metal },
		{ name = "Rung4", size = Vector3.new(1.9, 0.22, 0.22), at = CFrame.new(0, 2.4, 0), color = "#C9CCD0", material = Enum.Material.Metal },
		{ name = "Foot", size = Vector3.new(2.5, 0.3, 0.5), at = CFrame.new(0, -3.1, 0), color = "#E8B83A" },
	},
	ThermalCam = {
		{ name = "Handle", size = Vector3.new(0.45, 1.0, 0.45), at = CFrame.new(), color = "#1A1A1A" },
		{ name = "Body", size = Vector3.new(1.3, 1.0, 1.2), at = CFrame.new(0, 0.85, -0.2), color = "#E86A2C" },
		{ name = "Screen", size = Vector3.new(1.0, 0.72, 0.06), at = CFrame.new(0, 0.9, 0.42), color = "#FF8A3C", material = Enum.Material.Neon },
		{ name = "Lens", size = Vector3.new(0.4, 0.62, 0.62), at = CFrame.new(0, 0.9, -0.95) * ROT_FWD, color = "#121416", shape = Enum.PartType.Cylinder },
		{ name = "Visor", size = Vector3.new(1.4, 0.12, 0.5), at = CFrame.new(0, 1.42, 0.5), color = "#1A1A1A" },
	},
	Flashlight = {
		{ name = "Handle", size = Vector3.new(0.42, 0.42, 1.8), at = CFrame.new(), color = "#F7D046" },
		{ name = "Head", size = Vector3.new(0.5, 0.72, 0.72), at = CFrame.new(0, 0, -1.05) * ROT_FWD, color = "#2B2E33", shape = Enum.PartType.Cylinder },
		{ name = "Lens", size = Vector3.new(0.08, 0.6, 0.6), at = CFrame.new(0, 0, -1.33) * ROT_FWD, color = "#FFF6D8", material = Enum.Material.Neon, shape = Enum.PartType.Cylinder },
		{ name = "Button", size = Vector3.new(0.2, 0.12, 0.3), at = CFrame.new(0, 0.24, -0.2), color = "#C8232B" },
	},
	RescueSaw = {
		{ name = "Handle", size = Vector3.new(0.9, 1.0, 1.6), at = CFrame.new(), color = "#F28C28" },
		{ name = "TopGrip", size = Vector3.new(0.3, 0.3, 1.3), at = CFrame.new(0, 0.8, 0.1), color = "#1A1A1A" },
		{ name = "Engine", size = Vector3.new(0.7, 0.7, 0.7), at = CFrame.new(-0.2, 0, 0.9), color = "#2B2E33" },
		{ name = "Guard", size = Vector3.new(0.25, 1.2, 1.2), at = CFrame.new(0.55, 0.25, -1.0), color = "#F28C28" },
		{ name = "Blade", size = Vector3.new(0.1, 2.1, 2.1), at = CFrame.new(0.5, -0.15, -1.4), color = "#D6D8DC", material = Enum.Material.DiamondPlate, shape = Enum.PartType.Cylinder },
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
	p.Transparency = spec.transparency or 0
	p.Reflectance = spec.reflect or 0
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
	elseif id == "Flashlight" then
		local a = Instance.new("Attachment")
		a.Name = "Beam"
		a.Position = Vector3.new(0, 0, -1.4 * scale)
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

-- Where the hand closes on each plain tool (Tool.Grip). Shafts are held low; the rest at the Handle.
local GRIPS: { [string]: CFrame } = {
	OxygenTank = CFrame.new(0, 0, 0.3) * CFrame.Angles(0, 0, math.rad(90)),
	Halligan = CFrame.new(0, -1.1, 0),
	Crowbar = CFrame.new(0, -0.8, 0),
	Sledgehammer = CFrame.new(0, -1.3, 0),
	Ladder = CFrame.new(-1.05, -0.6, 0),
	GasMask = CFrame.new(0, 0, 0.3),
}

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
	tool.Grip = GRIPS[id] or CFrame.new()
	if def and def.wear == "face" then
		tool.ToolTip = `{def.name} (click to put it on)`
	end
	return tool
end

-- Recolour an axe (ToolService's Axe Tool or a built model) to its tier: head colour/material/shine.
function ItemProps.paintAxe(container: Instance, id: string)
	local def = ItemDefs.get(id)
	local tier = def and def.axe
	local head = container:FindFirstChild("Head")
	if not tier or not (head and head:IsA("BasePart")) then
		return
	end
	head.Color = Color3.fromHex(tier.head)
	local ok, mat = pcall(function()
		return (Enum.Material :: any)[tier.material]
	end)
	if ok and mat then
		head.Material = mat
	end
	head.Reflectance = tier.reflect or 0
	local back = container:FindFirstChild("Back")
	local spec = SPECS[id]
	if back and back:IsA("BasePart") and spec and spec[3] then
		back.Color = Color3.fromHex(spec[3].color)
	end
	local handle = container:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") and spec and spec[1] then
		handle.Color = Color3.fromHex(spec[1].color)
		handle.Material = spec[1].material or handle.Material
	end
end

return ItemProps
