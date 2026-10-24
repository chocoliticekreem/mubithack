--!strict
-- PlotBuilder: builds the baseplate and six themed tycoon plots on a ring around the plaza, entirely from parts.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Config"))
local PlotThemes: any = require(ReplicatedStorage:WaitForChild("PlotThemes"))
local CashInService: any = require(script.Parent:WaitForChild("CashInService"))

local BASE_THICKNESS = 1
local LIFT = 0.05 -- plot sits slightly above the baseplate top so surfaces are never coplanar
-- Post-claim teleport point only (players initially spawn in the plaza, never on a plot).
local SPAWN_LOCAL = Vector3.new(0, 3, 12)
local CONVEYOR_Z = -8
local DEFAULT_SLOTS = 6
local BOUGHT_GREEN = Color3.fromRGB(110, 220, 120)

export type Plot = {
	index: number,
	origin: CFrame,
	spawnCFrame: CFrame,
	conveyor: Part,
	conveyorDir: Vector3,
	droppers: { Part },
	dropperSlot2: Part,
	collector: Part,
	dropperButton: Part?,
	conveyorButton: Part?,
	model: Model,
	gate: BasePart?,
	theme: any,
}

local PlotBuilder = {}

local plotsFolder: Folder? = nil
local builtSlots: { Plot } = {}
local mapBuiltCounted = false

-- ---------- helpers for reading PlotThemes defensively ----------

local function pick(t: any, keys: { string }): any
	if type(t) ~= "table" then
		return nil
	end
	for _, k in ipairs(keys) do
		local v = t[k]
		if v ~= nil then
			return v
		end
	end
	return nil
end

local function pickColor(t: any, keys: { string }, default: Color3): Color3
	local v = pick(t, keys)
	if typeof(v) == "Color3" then
		return v
	end
	return default
end

local function pickMaterial(t: any, keys: { string }, default: Enum.Material): Enum.Material
	local v = pick(t, keys)
	if typeof(v) == "EnumItem" and v.EnumType == Enum.Material then
		return v :: any
	end
	return default
end

local function ringRadius(): number
	local v = pick(PlotThemes, { "RING_RADIUS", "RingRadius", "ringRadius", "RADIUS", "Radius" })
	if type(v) == "number" then
		return v
	end
	return 120
end

local function plazaCenter(): Vector3
	local v = pick(PlotThemes, { "PLAZA_CENTER", "PlazaCenter", "CENTER", "Center", "center" })
	if typeof(v) == "Vector3" then
		return v
	end
	return Vector3.zero
end

local function slotCount(): number
	local cfgCount: any = Config.PLOT_COUNT
	if type(cfgCount) == "number" then
		return math.max(1, math.floor(cfgCount))
	end
	local v = pick(PlotThemes, { "SLOT_COUNT", "SlotCount", "PLOT_COUNT", "PlotCount" })
	if type(v) == "number" then
		return math.max(1, math.floor(v))
	end
	return DEFAULT_SLOTS
end

local function plotSize(): Vector3
	local v = pick(PlotThemes, { "PLOT_SIZE", "PlotSize", "plotSize" })
	if typeof(v) == "Vector3" then
		return Vector3.new(v.X, Config.PLOT_SIZE.Y, v.Z)
	elseif type(v) == "number" then
		return Vector3.new(v, Config.PLOT_SIZE.Y, v)
	end
	return Config.PLOT_SIZE
end

local function themeList(): { any }
	local v = pick(PlotThemes, { "list", "List", "THEMES", "Themes", "themes", "ORDER", "Order" })
	if type(v) == "table" then
		return v :: { any }
	end
	return {}
end

local DEFAULT_THEME = {
	name = "Plot",
	floorColor = Color3.fromRGB(120, 200, 110),
	floorMaterial = Enum.Material.Grass,
	primary = Color3.fromRGB(255, 170, 60),
	secondary = Color3.fromRGB(90, 190, 255),
	accent = Color3.fromRGB(255, 90, 160),
}

local function getTheme(index: number): any
	local list = themeList()
	local t = list[index]
	if type(t) == "table" then
		return t
	end
	if #list > 0 then
		local wrapped = list[((index - 1) % #list) + 1]
		if type(wrapped) == "table" then
			return wrapped
		end
	end
	return DEFAULT_THEME
end

local function themeName(theme: any): string
	local n = pick(theme, { "name", "Name", "displayName", "DisplayName" })
	if type(n) == "string" then
		return n
	end
	return "Plot"
end

-- ---------- general helpers ----------

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

local function addLabel(button: BasePart, text: string, guiName: string?, textColor: Color3?)
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
	label.BackgroundColor3 = Color3.fromRGB(40, 28, 60)
	label.BackgroundTransparency = 0.15
	label.TextColor3 = textColor or Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.FredokaOne
	label.Text = text
	label.Parent = gui
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(28, 22, 38)
	stroke.Parent = label
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
	local c = pad:GetAttribute("BoughtColor")
	if typeof(c) == "Color3" then
		pad.Color = c
	else
		pad.Color = BOUGHT_GREEN
	end
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

local function loadPlaza(): any
	local sss = game:GetService("ServerScriptService")
	local m = sss:WaitForChild("PlazaBuilder", 5)
	if m and m:IsA("ModuleScript") then
		local ok, res = pcall(require, m)
		if ok then
			return res
		end
		warn("[PlotBuilder] PlazaBuilder require failed: " .. tostring(res))
	end
	return nil
end

local function toBasePart(v: any): BasePart?
	if typeof(v) ~= "Instance" then
		return nil
	end
	local inst = v :: Instance
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") then
		if inst.PrimaryPart then
			return inst.PrimaryPart
		end
		return inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

function PlotBuilder.buildBase(): Part
	local existing = Workspace:FindFirstChild("Baseplate")
	if existing and existing:IsA("Part") then
		return existing
	end

	local center = plazaCenter()
	local ps = plotSize()
	local extent = ringRadius() + math.max(ps.X, ps.Z) / 2 + 70
	local base = makePart(
		"Baseplate",
		Vector3.new(extent * 2, BASE_THICKNESS, extent * 2),
		CFrame.new(center.X, -BASE_THICKNESS / 2, center.Z),
		Color3.fromRGB(150, 220, 130),
		Enum.Material.Grass,
		Workspace
	)

	-- Boundary: invisible tall walls just inside the baseplate edge plus a low visible hedge on the same line.
	local edge = extent - 1
	local wallDefs = {
		{ "N", Vector3.new(extent * 2, 1, 2), Vector3.new(0, 0, edge) },
		{ "S", Vector3.new(extent * 2, 1, 2), Vector3.new(0, 0, -edge) },
		{ "E", Vector3.new(2, 1, extent * 2), Vector3.new(edge, 0, 0) },
		{ "W", Vector3.new(2, 1, extent * 2), Vector3.new(-edge, 0, 0) },
	}
	for _, def in ipairs(wallDefs) do
		local wname = def[1] :: string
		local wsize = def[2] :: Vector3
		local woff = def[3] :: Vector3
		local wall = makePart("BoundaryWall" .. wname, Vector3.new(wsize.X, 40, wsize.Z),
			CFrame.new(center.X + woff.X, 20, center.Z + woff.Z),
			Color3.fromRGB(255, 255, 255), Enum.Material.SmoothPlastic, Workspace)
		wall.Transparency = 1
		wall.CanCollide = true
		wall.CanTouch = false
		local hedge = makePart("BoundaryHedge" .. wname, Vector3.new(wsize.X, 3, wsize.Z),
			CFrame.new(center.X + woff.X, 1.5, center.Z + woff.Z),
			Color3.fromRGB(34, 94, 38), Enum.Material.Grass, Workspace)
		hedge.CanCollide = true
	end

	-- Invisible default spawn in the plaza (offset from the fountain at the center).
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "DefaultSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(6, 0.2, 6)
	spawn.CFrame = CFrame.new(center.X, surfaceY() + 0.1, center.Z - 22)
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Neutral = true
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.BottomSurface = Enum.SurfaceType.Smooth
	spawn.Parent = Workspace

	return base
end

local FLOOR_MATERIALS: { [string]: Enum.Material } = {
	Candy = Enum.Material.SmoothPlastic,
	Lava = Enum.Material.Basalt,
	Ice = Enum.Material.Glacier,
	Jungle = Enum.Material.Grass,
	["Neon City"] = Enum.Material.DiamondPlate,
	Desert = Enum.Material.Sand,
}

local function decorateFloor(model: Model, origin: CFrame, size: Vector3, theme: any)
	local tname = themeName(theme)
	local baseColor = pickColor(theme, { "floorColor", "floor", "groundColor", "ground" }, DEFAULT_THEME.floorColor)
	local accentColor = pickColor(theme, { "accent", "accentColor", "glow", "glowColor" }, DEFAULT_THEME.accent)
	local mat = FLOOR_MATERIALS[tname] or pickMaterial(theme, { "floorMaterial", "material", "groundMaterial" }, DEFAULT_THEME.floorMaterial)
	local shadeA = baseColor:Lerp(Color3.new(1, 1, 1), 0.15)
	local shadeB = baseColor:Lerp(Color3.new(0, 0, 0), 0.12)
	if tname == "Candy" then
		shadeB = baseColor:Lerp(Color3.fromRGB(150, 235, 200), 0.65)
	end

	local folder = Instance.new("Folder")
	folder.Name = "FloorDecor"
	local TILE = 8
	local TILE_H = 0.2
	local nx = math.ceil(size.X / TILE)
	local nz = math.ceil(size.Z / TILE)
	for ix = 0, nx - 1 do
		local x0 = -size.X / 2 + ix * TILE
		local w = math.min(TILE, size.X / 2 - x0)
		for iz = 0, nz - 1 do
			local z0 = -size.Z / 2 + iz * TILE
			local d = math.min(TILE, size.Z / 2 - z0)
			local shade = if (ix + iz) % 2 == 0 then shadeA else shadeB
			local tile = makePart("FloorTile", Vector3.new(w, TILE_H, d),
				origin * CFrame.new(x0 + w / 2, TILE_H / 2, z0 + d / 2),
				shade, mat, folder)
			tile.CanCollide = false
		end
	end

	local TRIM = 1
	local trimDefs = {
		{ Vector3.new(size.X, TRIM, TRIM), Vector3.new(0, TRIM / 2, size.Z / 2 - TRIM / 2) },
		{ Vector3.new(size.X, TRIM, TRIM), Vector3.new(0, TRIM / 2, -size.Z / 2 + TRIM / 2) },
		{ Vector3.new(TRIM, TRIM, size.Z - TRIM * 2), Vector3.new(size.X / 2 - TRIM / 2, TRIM / 2, 0) },
		{ Vector3.new(TRIM, TRIM, size.Z - TRIM * 2), Vector3.new(-size.X / 2 + TRIM / 2, TRIM / 2, 0) },
	}
	for i, def in ipairs(trimDefs) do
		local off = def[2] :: Vector3
		local trim = makePart("FloorTrim" .. i, def[1] :: Vector3, origin * CFrame.new(off.X, off.Y, off.Z),
			accentColor, Enum.Material.SmoothPlastic, folder)
		trim.CanCollide = false
	end
	folder.Parent = model
end

-- Adds decoration only; never moves, resizes or renames the existing machine parts.
local function dressMachines(model: Model, origin: CFrame, dropper: Part, conveyor: Part, collector: Part, theme: any)
	local primary = pickColor(theme, { "primary", "primaryColor", "colorA", "color1" }, DEFAULT_THEME.primary)
	local secondary = pickColor(theme, { "secondary", "secondaryColor", "colorB", "color2" }, DEFAULT_THEME.secondary)
	local accent = pickColor(theme, { "accent", "accentColor", "glow", "glowColor" }, DEFAULT_THEME.accent)
	local metalColor = secondary:Lerp(Color3.fromRGB(235, 235, 255), 0.35)
	local darkColor = secondary:Lerp(Color3.fromRGB(30, 26, 44), 0.5)
	local stripeColor = secondary:Lerp(Color3.new(1, 1, 1), 0.65)

	local folder = Instance.new("Folder")
	folder.Name = "MachineDecor"

	local function deco(pname: string, psize: Vector3, cf: CFrame, color: Color3, material: Enum.Material): Part
		local p = makePart(pname, psize, cf, color, material, folder)
		p.CanCollide = false
		p.CanTouch = false
		return p
	end

	-- Dropper: wider hopper bin on top, 4 thin legs to the floor, glowing nozzle ring under it
	local dcf = dropper.CFrame
	local dsz = dropper.Size
	deco("HopperBin", Vector3.new(4.8, 1.2, 4.8), dcf * CFrame.new(0, dsz.Y / 2 + 0.6, 0), primary:Lerp(Color3.new(1, 1, 1), 0.2), Enum.Material.SmoothPlastic)
	deco("HopperRim", Vector3.new(5.2, 0.3, 5.2), dcf * CFrame.new(0, dsz.Y / 2 + 1.35, 0), accent, Enum.Material.SmoothPlastic)
	local legH = math.max(dropper.Position.Y - dsz.Y / 2 - origin.Position.Y, 1)
	for _, sx in ipairs({ -1, 1 }) do
		for _, sz in ipairs({ -1, 1 }) do
			deco("DropperLeg", Vector3.new(0.4, legH, 0.4),
				dcf * CFrame.new(sx * 1.6, -dsz.Y / 2 - legH / 2, sz * 1.6),
				metalColor, Enum.Material.Metal)
		end
	end
	local ring = deco("NozzleRing", Vector3.new(0.3, 2.4, 2.4), dcf * CFrame.new(0, -dsz.Y / 2 - 0.15, 0) * CFrame.Angles(0, 0, math.pi / 2), accent, Enum.Material.Neon)
	ring.Shape = Enum.PartType.Cylinder

	-- Conveyor: metal side rails and lighter stripes every 3 studs
	local ccf = conveyor.CFrame
	local csz = conveyor.Size
	for _, side in ipairs({ -1, 1 }) do
		deco("BeltSideRail", Vector3.new(csz.X, 0.8, 0.3), ccf * CFrame.new(0, 0.1, side * (csz.Z / 2 + 0.6)), metalColor, Enum.Material.Metal)
	end
	local x = -csz.X / 2 + 1.5
	while x < csz.X / 2 - 0.5 do
		deco("BeltStripe", Vector3.new(0.5, 0.06, csz.Z - 0.6), ccf * CFrame.new(x, csz.Y / 2 + 0.03, 0), stripeColor, Enum.Material.SmoothPlastic)
		x += 3
	end

	-- Collector: funnel rim, Neon mouth facing the belt (local -X), small chimney
	local kcf = collector.CFrame
	local ksz = collector.Size
	deco("FunnelRim", Vector3.new(ksz.X + 1.4, 0.4, ksz.Z + 1.4), kcf * CFrame.new(0, ksz.Y / 2 + 0.2, 0), primary, Enum.Material.SmoothPlastic)
	deco("FunnelMouth", Vector3.new(0.3, ksz.Y - 0.8, ksz.Z - 0.8), kcf * CFrame.new(-(ksz.X / 2 + 0.15), 0, 0), accent:Lerp(Color3.new(1, 1, 1), 0.3), Enum.Material.Neon)
	deco("Chimney", Vector3.new(1, 2.5, 1), kcf * CFrame.new(0.8, ksz.Y / 2 + 0.4 + 1.25, 1.1), darkColor, Enum.Material.Metal)
	deco("ChimneyCap", Vector3.new(1.4, 0.3, 1.4), kcf * CFrame.new(0.8, ksz.Y / 2 + 0.4 + 2.65, 1.1), accent, Enum.Material.SmoothPlastic)

	folder.Parent = model
end

function PlotBuilder.buildPlot(index: number, themeIn: any?): Plot
	local count = slotCount()
	local idx = math.clamp(math.floor(index), 1, count)
	local theme: any = themeIn or getTheme(idx)
	local name = themeName(theme)

	local floorColor = pickColor(theme, { "floorColor", "floor", "groundColor", "ground" }, DEFAULT_THEME.floorColor)
	local floorMaterial = pickMaterial(theme, { "floorMaterial", "material", "groundMaterial" }, DEFAULT_THEME.floorMaterial)
	local primary = pickColor(theme, { "primary", "primaryColor", "colorA", "color1" }, DEFAULT_THEME.primary)
	local secondary = pickColor(theme, { "secondary", "secondaryColor", "colorB", "color2" }, DEFAULT_THEME.secondary)
	local accent = pickColor(theme, { "accent", "accentColor", "glow", "glowColor" }, DEFAULT_THEME.accent)
	-- Conveyor belt: dark shade of the theme's secondary color (never default grey)
	local beltColor = secondary:Lerp(Color3.fromRGB(30, 26, 44), 0.55)

	local center = plazaCenter()
	local angle = (idx - 1) / count * math.pi * 2
	local radius = ringRadius()
	local pos = Vector3.new(center.X + math.sin(angle) * radius, 0, center.Z + math.cos(angle) * radius)
	local top = surfaceY()
	-- local +Z (pads, claim gate) faces the plaza center
	local lookAtCenter = CFrame.lookAt(Vector3.new(pos.X, top, pos.Z), Vector3.new(center.X, top, center.Z))
	local origin = lookAtCenter * CFrame.Angles(0, math.pi, 0)

	local size = plotSize()
	local thickness = Config.PLOT_SIZE.Y
	local halfZ = size.Z / 2
	local halfX = size.X / 2

	local model = Instance.new("Model")
	model.Name = "Plot" .. idx
	model:SetAttribute("PlotIndex", idx)
	model:SetAttribute("ThemeName", name)
	model:SetAttribute("OwnerUserId", 0)

	local function at(lx: number, ly: number, lz: number): CFrame
		return origin * CFrame.new(lx, ly, lz)
	end

	-- Ground (theme material + color)
	local floor = makePart("PlotFloor", Vector3.new(size.X, thickness, size.Z), at(0, -thickness / 2, 0),
		floorColor, floorMaterial, model)
	model.PrimaryPart = floor
	decorateFloor(model, origin, size, theme)

	-- Conveyor (thin, long; top surface at +0.65 above plot surface)
	local len = Config.CONVEYOR_LENGTH
	local conveyor = makePart("Conveyor", Vector3.new(len, 0.6, 4), at(0, 0.35, CONVEYOR_Z),
		beltColor, Enum.Material.Metal, model)

	-- Rails keep cubes on the belt (theme colored)
	for i, side in ipairs({ -1, 1 }) do
		makePart("Rail" .. i, Vector3.new(len, 2, 0.4), at(0, 1.05, CONVEYOR_Z + side * 2.2),
			accent, Enum.Material.SmoothPlastic, model)
	end

	-- Droppers hover above the belt start
	local d1 = makePart("Dropper1", Vector3.new(3, 3, 3), at(-len / 2 + 2, 6, CONVEYOR_Z),
		primary, Enum.Material.SmoothPlastic, model)
	local d2 = makePart("Dropper2", Vector3.new(3, 3, 3), at(-len / 2 + 8, 6, CONVEYOR_Z),
		secondary, Enum.Material.SmoothPlastic, model)
	d2.Transparency = 0.6
	d2.CanCollide = false

	watchUnlocked(d2)

	-- Collector at the belt end
	local collector = makePart("Collector", Vector3.new(3, 3, 4), at(len / 2 + 1.5, 1.55, CONVEYOR_Z),
		accent, Enum.Material.Neon, model)
	CashInService.decorateCollector(collector)

	-- Legacy buy pads are removed (UpgradeService owns upgrade pads).

	model.Parent = getPlotsFolder()

	-- Decorations and claim gate come from the plaza builder
	local plaza = loadPlaza()
	if plaza and type(plaza.decoratePlot) == "function" then
		local ok, err = pcall(function()
			plaza.decoratePlot(model, theme, origin, size)
		end)
		if not ok then
			warn("[PlotBuilder] decoratePlot failed: " .. tostring(err))
		end
	end

	local gate: BasePart? = nil
	if plaza and type(plaza.buildClaimGate) == "function" then
		local ok, res = pcall(function()
			return plaza.buildClaimGate(origin, theme)
		end)
		if ok then
			gate = toBasePart(res)
		else
			warn("[PlotBuilder] buildClaimGate failed: " .. tostring(res))
		end
	end
	if gate == nil then
		local g = makePart("ClaimGate", Vector3.new(14, 0.6, 6), at(0, 0.35, math.max(halfZ - 5, 18)),
			accent, Enum.Material.Neon, model)
		g.CanCollide = false
		g:SetAttribute("PlotIndex", idx)
		addLabel(g, "Claim " .. name .. " Plot", "ClaimLabel", Color3.fromRGB(255, 248, 232))
		gate = g
	end
	if gate then
		gate:SetAttribute("PlotIndex", idx)
	end

	dressMachines(model, origin, d1, conveyor, collector, theme)

	return {
		index = idx,
		origin = origin,
		spawnCFrame = origin * CFrame.new(SPAWN_LOCAL),
		conveyor = conveyor,
		conveyorDir = origin.RightVector,
		droppers = { d1, d2 },
		dropperSlot2 = d2,
		collector = collector,
		dropperButton = nil,
		conveyorButton = nil,
		model = model,
		gate = gate,
		theme = theme,
	}
end

-- Builds every slot on the ring (one theme per slot) and returns the slot list.
function PlotBuilder.buildSlots(themes: { any }?): { Plot }
	if #builtSlots > 0 then
		return builtSlots
	end
	local count = slotCount()
	local slots: { Plot } = {}
	for i = 1, count do
		local theme: any = if themes then themes[i] else nil
		slots[i] = PlotBuilder.buildPlot(i, theme)
	end
	builtSlots = slots

	if not mapBuiltCounted then
		mapBuiltCounted = true
		local tel = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
		if tel then
			local ok, mod = pcall(require, tel)
			if ok and type(mod) == "table" and type(mod.count) == "function" then
				mod.count("map_built", 1)
			end
		end
	end
	return slots
end

function PlotBuilder.getSlots(): { Plot }
	return builtSlots
end

return PlotBuilder
