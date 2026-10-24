--!strict
-- PlotBuilder: builds the baseplate and one tycoon plot per slot, entirely from parts.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))

local BASE_THICKNESS = 1
local LIFT = 0.05 -- plot sits slightly above the baseplate top so surfaces are never coplanar
local SPAWN_LOCAL = Vector3.new(0, 3, 12)
local CONVEYOR_Z = -8

export type Plot = {
	origin: CFrame,
	spawnCFrame: CFrame,
	conveyor: Part,
	conveyorDir: Vector3,
	droppers: { Part },
	dropperSlot2: Part,
	collector: Part,
	dropperButton: Part,
	conveyorButton: Part,
}

local PlotBuilder = {}

local plotsFolder: Folder? = nil

local function getPlotsFolder(): Folder
	if plotsFolder and plotsFolder.Parent then
		return plotsFolder
	end
	local existing = Workspace:FindFirstChild("Plots")
	if existing and existing:IsA("Folder") then
		plotsFolder = existing
		return existing
	end
	local f = Instance.new("Folder")
	f.Name = "Plots"
	f.Parent = Workspace
	plotsFolder = f
	return f
end

local function plotX(index: number): number
	return (index - 1) * Config.PLOT_SPACING
end

local function surfaceY(): number
	return LIFT + Config.PLOT_SIZE.Y
end

local function makePart(name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, parent: Instance): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function addLabel(button: Part, text: string, guiName: string?, textColor: Color3?)
	local gui = Instance.new("BillboardGui")
	gui.Name = guiName or "CostLabel"
	gui.Size = UDim2.fromOffset(240, 70)
	gui.StudsOffset = Vector3.new(0, 3.5, 0)
	gui.MaxDistance = 120
	gui.AlwaysOnTop = true
	gui.Adornee = button
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	label.BackgroundTransparency = 0.15
	label.TextColor3 = textColor or Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.Parent = gui
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = label
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 10)
	corner.Parent = label
	gui.Parent = button
end

-- Marks a buy pad as purchased: recolors it and updates its label.
-- Can be called directly, or triggered by setting the pad attribute "Bought" = true.
function PlotBuilder.markPadBought(pad: Part)
	pad.Color = Config.BOUGHT_COLOR
	pad.Material = Enum.Material.SmoothPlastic
	local gui = pad:FindFirstChild("CostLabel")
	if gui then
		local tl = gui:FindFirstChild("Text")
		if tl and tl:IsA("TextLabel") then
			tl.Text = "Bought!"
		end
	end
end

-- Reveals the second dropper after purchase.
-- Can be called directly, or triggered by setting the dropper attribute "Unlocked" = true.
function PlotBuilder.unlockDropper(dropper: Part)
	dropper.Transparency = 0
	dropper.CanCollide = true
	local gui = dropper:FindFirstChild("LockLabel")
	if gui then
		gui:Destroy()
	end
end

local function watchBought(pad: Part)
	pad:GetAttributeChangedSignal("Bought"):Connect(function()
		if pad:GetAttribute("Bought") == true then
			PlotBuilder.markPadBought(pad)
		end
	end)
end

local function watchUnlocked(dropper: Part)
	dropper:GetAttributeChangedSignal("Unlocked"):Connect(function()
		if dropper:GetAttribute("Unlocked") == true then
			PlotBuilder.unlockDropper(dropper)
		end
	end)
end

function PlotBuilder.buildBase(): Part
	local existing = Workspace:FindFirstChild("Baseplate")
	if existing and existing:IsA("Part") then
		return existing
	end

	local width = Config.MAX_PLOTS * Config.PLOT_SPACING + 80
	local base = makePart(
		"Baseplate",
		Vector3.new(width, BASE_THICKNESS, 220),
		CFrame.new((Config.MAX_PLOTS - 1) * Config.PLOT_SPACING / 2, -BASE_THICKNESS / 2, 0),
		Color3.fromRGB(235, 240, 250),
		Enum.Material.SmoothPlastic,
		Workspace
	)

	-- Invisible default spawn near plot 1 so early joins land on a plot.
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "DefaultSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(6, 0.2, 6)
	spawn.CFrame = CFrame.new(plotX(1) + SPAWN_LOCAL.X, surfaceY() + 0.1, SPAWN_LOCAL.Z)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Neutral = true
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Parent = Workspace

	return base
end

function PlotBuilder.buildPlot(index: number): Plot
	local idx = math.clamp(math.floor(index), 1, Config.MAX_PLOTS)
	local x = plotX(idx)
	local top = surfaceY()
	local origin = CFrame.new(x, top, 0)

	local model = Instance.new("Model")
	model.Name = "Plot" .. idx

	local function at(lx: number, ly: number, lz: number): CFrame
		return origin * CFrame.new(lx, ly, lz)
	end

	-- Ground
	makePart("PlotFloor", Config.PLOT_SIZE, CFrame.new(x, LIFT + Config.PLOT_SIZE.Y / 2, 0),
		Config.PLOT_COLOR, Enum.Material.SmoothPlastic, model)

	-- Spawn mat (slightly raised, not coplanar)
	makePart("SpawnMat", Vector3.new(8, 0.1, 8), at(SPAWN_LOCAL.X, 0.12, SPAWN_LOCAL.Z),
		Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic, model)

	-- Conveyor (thin, long; top surface at +0.65 above plot surface)
	local len = Config.CONVEYOR_LENGTH
	local conveyor = makePart("Conveyor", Vector3.new(len, 0.6, 4), at(0, 0.35, CONVEYOR_Z),
		Config.CONVEYOR_COLOR, Enum.Material.Metal, model)

	-- Rails keep cubes on the belt
	for i, side in ipairs({ -1, 1 }) do
		makePart("Rail" .. i, Vector3.new(len, 2, 0.4), at(0, 1.05, CONVEYOR_Z + side * 2.2),
			Color3.fromRGB(200, 200, 210), Enum.Material.SmoothPlastic, model)
	end

	-- Droppers hover above the belt start
	local d1 = makePart("Dropper1", Vector3.new(3, 3, 3), at(-len / 2 + 2, 6, CONVEYOR_Z),
		Config.DROPPER_COLOR, Enum.Material.SmoothPlastic, model)
	local d2 = makePart("Dropper2", Vector3.new(3, 3, 3), at(-len / 2 + 8, 6, CONVEYOR_Z),
		Config.BOUGHT_COLOR, Enum.Material.SmoothPlastic, model)
	d2.Transparency = 0.6
	d2.CanCollide = false
	addLabel(d2, "LOCKED - buy 2nd Dropper", "LockLabel", Color3.fromRGB(255, 210, 120))
	watchUnlocked(d2)

	-- Collector at the belt end
	local collector = makePart("Collector", Vector3.new(3, 3, 4), at(len / 2 + 1.5, 1.55, CONVEYOR_Z),
		Config.COLLECTOR_COLOR, Enum.Material.Neon, model)

	-- Buy pads on the sides, far from spawn and the belt
	local dropperButton = makePart("DropperButton", Vector3.new(6, 0.4, 6), at(-15, 0.25, 14),
		Config.BUTTON_COLOR, Enum.Material.Neon, model)
	addLabel(dropperButton, "2nd Dropper $" .. Config.DROPPER_COST)
	watchBought(dropperButton)
	local conveyorButton = makePart("ConveyorButton", Vector3.new(6, 0.4, 6), at(15, 0.25, 14),
		Config.BUTTON_COLOR, Enum.Material.Neon, model)
	addLabel(conveyorButton, "Fast Belt $" .. Config.CONVEYOR_COST)
	watchBought(conveyorButton)

	model.Parent = getPlotsFolder()

	return {
		origin = origin,
		spawnCFrame = origin * CFrame.new(SPAWN_LOCAL),
		conveyor = conveyor,
		conveyorDir = Vector3.new(1, 0, 0),
		droppers = { d1, d2 },
		dropperSlot2 = d2,
		collector = collector,
		dropperButton = dropperButton,
		conveyorButton = conveyorButton,
	}
end

return PlotBuilder
