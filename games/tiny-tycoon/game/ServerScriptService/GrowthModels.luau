--!nonstrict
-- GrowthModels: pure model builders for visible plot growth (no side effects, no telemetry).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local okGA, GameAssets = pcall(function()
	return require(ReplicatedStorage:WaitForChild("GameAssets", 10))
end)
if not okGA then
	GameAssets = nil
end

local GrowthModels = {}

local FALLBACKS = {
	accent = Color3.fromRGB(255, 200, 40),
	primary = Color3.fromRGB(80, 170, 255),
	floor = Color3.fromRGB(120, 220, 140),
}

-- Resolve a theme color, falling back to GameAssets.Palette, then a bright default (never grey).
local function themeColor(theme: any, key: string): Color3
	if type(theme) == "table" and typeof(theme[key]) == "Color3" then
		return theme[key]
	end
	if GameAssets and type(GameAssets.Palette) == "table" then
		local c = GameAssets.Palette[key]
		if typeof(c) == "Color3" then
			return c
		end
	end
	return FALLBACKS[key] or FALLBACKS.accent
end

local function mk(parent: Instance, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material?, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Parent = parent
	return p
end

local function newModel(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- turns an X-axis cylinder upright

function GrowthModels.dropperMachine(cf: CFrame, theme: any): Model
	local primary, accent, floor = themeColor(theme, "primary"), themeColor(theme, "accent"), themeColor(theme, "floor")
	local m = newModel("DropperMachine")
	local base = mk(m, Vector3.new(5, 1, 5), cf * CFrame.new(0, 0.5, 0), primary, Enum.Material.Metal)
	mk(m, Vector3.new(3.6, 3.4, 3.6), cf * CFrame.new(0, 2.7, 0), accent, Enum.Material.SmoothPlastic)
	mk(m, Vector3.new(0.8, 2.6, 2.6), cf * CFrame.new(0, 5.4, 0) * UPRIGHT, floor, Enum.Material.Metal, Enum.PartType.Cylinder)
	mk(m, Vector3.new(1.4, 1, 1), cf * CFrame.new(0, 1.4, -1.9) * UPRIGHT, primary, Enum.Material.Metal, Enum.PartType.Cylinder)
	mk(m, Vector3.new(3.8, 0.4, 3.8), cf * CFrame.new(0, 4.6, 0), accent, Enum.Material.Neon)
	m.PrimaryPart = base
	return m
end

function GrowthModels.chevrons(cf: CFrame, theme: any): Model
	local accent, primary = themeColor(theme, "accent"), themeColor(theme, "primary")
	local m = newModel("Chevrons")
	local len = 2.4
	local s = math.sin(math.rad(45))
	local first: Part? = nil
	-- apex points along cf.LookVector, arms trail behind (+Z)
	for i = 0, 2 do
		local color = (i % 2 == 0) and accent or primary
		local apex = cf * CFrame.new(0, 0.15, i * 3.2 - 3.2)
		for _, side in ipairs({ 1, -1 }) do
			local rot = CFrame.Angles(0, math.rad(45) * side, 0)
			local center = apex * CFrame.new(side * s * len / 2, 0, s * len / 2) * rot
			local p = mk(m, Vector3.new(0.7, 0.2, len), center, color, Enum.Material.Neon)
			first = first or p
		end
	end
	m.PrimaryPart = first
	return m
end

function GrowthModels.orePile(cf: CFrame, theme: any, tierColor: Color3?): Model
	local tier = (typeof(tierColor) == "Color3") and tierColor or themeColor(theme, "accent")
	local floor = themeColor(theme, "floor")
	local m = newModel("OrePile")
	local base = mk(m, Vector3.new(0.6, 5, 5), cf * CFrame.new(0, 0.3, 0) * UPRIGHT, floor, Enum.Material.Slate, Enum.PartType.Cylinder)
	mk(m, Vector3.new(2.6, 2.2, 2.6), cf * CFrame.new(0, 1.4, 0) * CFrame.Angles(0.3, 0.6, 0.2), tier, Enum.Material.Slate)
	mk(m, Vector3.new(2, 1.8, 2), cf * CFrame.new(1.3, 1, 0.8) * CFrame.Angles(0.1, 1.1, 0.4), tier, Enum.Material.Slate)
	mk(m, Vector3.new(1.8, 1.8, 1.8), cf * CFrame.new(-1.2, 0.9, -0.7), tier, Enum.Material.Slate, Enum.PartType.Ball)
	mk(m, Vector3.new(0.9, 2.2, 0.9), cf * CFrame.new(0.1, 3, 0.1) * CFrame.Angles(0.2, 0.4, 0.15), tier, Enum.Material.Neon)
	m.PrimaryPart = base
	return m
end

function GrowthModels.vault(cf: CFrame, theme: any, label: string?): Model
	local primary, accent = themeColor(theme, "primary"), themeColor(theme, "accent")
	local m = newModel("Vault")
	local body = mk(m, Vector3.new(5, 5, 4), cf * CFrame.new(0, 2.5, 0), primary, Enum.Material.Metal)
	body.CanCollide = true
	local door = mk(m, Vector3.new(0.4, 3.4, 3.4), cf * CFrame.new(0, 2.7, -2.1) * CFrame.Angles(math.pi / 2, 0, math.pi / 2), accent, Enum.Material.Metal, Enum.PartType.Cylinder)
	mk(m, Vector3.new(0.5, 0.5, 1.8), cf * CFrame.new(0, 2.7, -2.5), accent, Enum.Material.Neon)
	mk(m, Vector3.new(5.4, 0.5, 4.4), cf * CFrame.new(0, 5.2, 0), accent, Enum.Material.Neon)
	local gui = Instance.new("BillboardGui")
	gui.Name = "VaultLabel"
	gui.Size = UDim2.fromScale(7, 2)
	gui.StudsOffset = Vector3.new(0, 4, 0)
	gui.AlwaysOnTop = false
	gui.MaxDistance = 90
	local txt = Instance.new("TextLabel")
	txt.BackgroundTransparency = 1
	txt.Size = UDim2.fromScale(1, 1)
	txt.TextScaled = true
	txt.Font = Enum.Font.LuckiestGuy
	txt.Text = tostring(label or "Vault")
	txt.TextColor3 = Color3.fromRGB(255, 255, 255)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(30, 25, 50)
	stroke.Parent = txt
	txt.Parent = gui
	gui.Parent = door
	m.PrimaryPart = body
	return m
end

function GrowthModels.plotWall(plotCFrame: CFrame, size: any, theme: any): Model
	local accent, primary = themeColor(theme, "accent"), themeColor(theme, "primary")
	local sx, sz = 60, 60
	if typeof(size) == "Vector3" then
		sx, sz = size.X, size.Z
	elseif typeof(size) == "Vector2" then
		sx, sz = size.X, size.Y
	end
	local m = newModel("PlotWall")
	local hx, hz = sx / 2, sz / 2
	local first: Part? = nil
	-- thin low rails along the four edges
	local rails = {
		{ Vector3.new(sx, 0.4, 0.4), Vector3.new(0, 1.2, -hz) },
		{ Vector3.new(sx, 0.4, 0.4), Vector3.new(0, 1.2, hz) },
		{ Vector3.new(0.4, 0.4, sz), Vector3.new(-hx, 1.2, 0) },
		{ Vector3.new(0.4, 0.4, sz), Vector3.new(hx, 1.2, 0) },
	}
	for _, r in ipairs(rails) do
		local p = mk(m, r[1], plotCFrame * CFrame.new(r[2]), accent, Enum.Material.Neon)
		first = first or p
	end
	-- corner posts (solid) and mid-edge posts (decorative, non-colliding)
	local corners = { { -hx, -hz }, { hx, -hz }, { -hx, hz }, { hx, hz } }
	for _, c in ipairs(corners) do
		local post = mk(m, Vector3.new(1.4, 3, 1.4), plotCFrame * CFrame.new(c[1], 1.5, c[2]), primary, Enum.Material.Metal)
		post.CanCollide = true
		mk(m, Vector3.new(1.8, 0.4, 1.8), plotCFrame * CFrame.new(c[1], 3.2, c[2]), accent, Enum.Material.Neon)
	end
	local mids = { { 0, -hz }, { 0, hz }, { -hx, 0 }, { hx, 0 } }
	for _, c in ipairs(mids) do
		mk(m, Vector3.new(0.9, 2, 0.9), plotCFrame * CFrame.new(c[1], 1, c[2]), primary, Enum.Material.Metal)
	end
	m.PrimaryPart = first
	return m
end

return GrowthModels
