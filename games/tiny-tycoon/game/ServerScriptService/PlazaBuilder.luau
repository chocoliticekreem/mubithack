--!nonstrict
-- PlazaBuilder: themed plaza, plot decoration, claim gates and owner signs (all built from parts).
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotThemes = require(ReplicatedStorage:WaitForChild("PlotThemes", 10))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 10))

local PlazaBuilder = {}

local M = Enum.Material
local function C(r, g, b) return Color3.fromRGB(r, g, b) end

-- name, floor material, floor color, accent1, accent2, rail/pad/dropper colors
local LOCAL = {
	{ name = "Candy", mat = M.SmoothPlastic, floor = C(255, 190, 220), a1 = C(255, 90, 160), a2 = C(120, 240, 190), rail = C(255, 120, 180), dark = C(190, 70, 130) },
	{ name = "Lava", mat = M.Basalt, floor = C(70, 40, 40), a1 = C(255, 110, 20), a2 = C(255, 200, 40), rail = C(230, 80, 30), dark = C(120, 30, 20) },
	{ name = "Ice", mat = M.Ice, floor = C(170, 225, 250), a1 = C(90, 190, 255), a2 = C(210, 245, 255), rail = C(80, 170, 240), dark = C(40, 110, 190) },
	{ name = "Jungle", mat = M.Grass, floor = C(70, 180, 80), a1 = C(40, 140, 60), a2 = C(250, 200, 60), rail = C(60, 150, 70), dark = C(30, 100, 45) },
	{ name = "Neon City", mat = M.Slate, floor = C(40, 36, 80), a1 = C(255, 40, 200), a2 = C(40, 240, 255), rail = C(180, 60, 255), dark = C(100, 30, 170) },
	{ name = "Desert", mat = M.Sand, floor = C(240, 205, 140), a1 = C(70, 170, 80), a2 = C(240, 130, 70), rail = C(220, 130, 60), dark = C(170, 90, 40) },
}

local function mk(parent, name, size, cf, color, mat, opts)
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or M.SmoothPlastic
	if opts then
		if opts.shape then p.Shape = opts.shape end
		if opts.t then p.Transparency = opts.t end
		if opts.collide == false then p.CanCollide = false end
	end
	p.Parent = parent
	return p
end

local UP = CFrame.Angles(0, 0, math.pi / 2)
local function cyl(parent, name, h, d, cf, color, mat, opts)
	return mk(parent, name, Vector3.new(h, d, d), cf * UP, color, mat, opts)
end
local function ball(parent, name, d, cf, color, mat)
	return mk(parent, name, Vector3.new(d, d, d), cf, color, mat, { shape = Enum.PartType.Ball })
end

local function resolveTheme(theme)
	local idx, name
	if type(theme) == "number" then
		idx = theme
	elseif type(theme) == "table" then
		idx = theme.Index or theme.index
		name = theme.Name or theme.name
	elseif type(theme) == "string" then
		name = theme
	end
	if not idx and name then
		for i, d in ipairs(LOCAL) do
			if d.name == name then idx = i end
		end
	end
	idx = math.clamp(math.floor(tonumber(idx) or 1), 1, #LOCAL)
	if type(name) ~= "string" then
		local ok, t = pcall(PlotThemes.getTheme, idx)
		if ok and type(t) == "table" and type(t.Name) == "string" then name = t.Name end
	end
	local d = LOCAL[idx]
	return idx, (name or d.name), d
end

local function folderIn(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

-- ===== Plaza =====
local plazaBuilt = false

function PlazaBuilder.buildPlaza()
	if plazaBuilt then return end
	plazaBuilt = true
	local count = PlotThemes.PLOT_COUNT or 6
	local sx, sz, n, ringSum, groundY = 0, 0, 0, 0, 0
	local pts = {}
	for i = 1, count do
		local ok, cf = pcall(PlotThemes.getSlotCFrame, i)
		if ok and typeof(cf) == "CFrame" then
			table.insert(pts, cf.Position)
			sx += cf.Position.X
			sz += cf.Position.Z
			n += 1
			if i == 1 then groundY = cf.Position.Y - 0.5 end
		end
	end
	local center = if n > 0 then Vector3.new(sx / n, groundY, sz / n) else Vector3.new(0, groundY, 0)
	for _, p in ipairs(pts) do
		ringSum += Vector3.new(p.X - center.X, 0, p.Z - center.Z).Magnitude
	end
	local ringR = if n > 0 then ringSum / n else 60
	local R = math.clamp(ringR - 24, 16, 30)

	local f = Instance.new("Folder")
	f.Name = "Plaza"
	local base = CFrame.new(center)
	local tileCols = { C(245, 232, 200), C(232, 214, 245) }
	for ix = -4, 4 do
		for iz = -4, 4 do
			if math.sqrt((ix * 8) ^ 2 + (iz * 8) ^ 2) <= R then
				mk(f, "Tile", Vector3.new(7.8, 0.4, 7.8), base * CFrame.new(ix * 8, 0.2, iz * 8), tileCols[(ix + iz) % 2 + 1], M.Limestone)
			end
		end
	end
	-- spawn
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "PlazaSpawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(8, 0.5, 8)
	spawn.CFrame = base * CFrame.new(0, 0.65, 13)
	spawn.Color = C(80, 220, 200)
	spawn.Material = M.SmoothPlastic
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.TopSurface = Enum.SurfaceType.Smooth
	spawn.Parent = f
	-- fountain
	cyl(f, "Basin", 1.2, 16, base * CFrame.new(0, 1.0, 0), C(250, 215, 160), M.Marble)
	cyl(f, "Water", 0.3, 14, base * CFrame.new(0, 1.7, 0), C(70, 190, 255), M.Neon, { collide = false })
	cyl(f, "Column", 5, 1.6, base * CFrame.new(0, 3.5, 0), C(250, 215, 160), M.Marble)
	cyl(f, "Bowl", 0.5, 5, base * CFrame.new(0, 6.2, 0), C(250, 215, 160), M.Marble)
	ball(f, "Spout", 2.4, base * CFrame.new(0, 7.2, 0), C(90, 210, 255), M.Neon).CanCollide = false
	-- lamp posts
	for k = 0, 7 do
		local a = math.rad(k * 45)
		local pos = Vector3.new(math.cos(a) * (R - 3), 0, math.sin(a) * (R - 3))
		local pc = base * CFrame.new(pos)
		cyl(f, "LampPole", 9, 0.7, pc * CFrame.new(0, 4.5 + 0.4, 0), C(140, 80, 60), M.Metal)
		local bulb = ball(f, "LampBulb", 2, pc * CFrame.new(0, 10.2, 0), C(255, 235, 120), M.Neon)
		local l = Instance.new("PointLight")
		l.Color = C(255, 230, 150)
		l.Range = 18
		l.Parent = bulb
	end
	-- trees
	for k = 0, 3 do
		local a = math.rad(22.5 + k * 90)
		local pc = base * CFrame.new(math.cos(a) * (R - 6), 0, math.sin(a) * (R - 6))
		cyl(f, "Trunk", 6, 1.6, pc * CFrame.new(0, 3.4, 0), C(130, 85, 45), M.Wood)
		ball(f, "Leaves", 7, pc * CFrame.new(0, 8, 0), C(70, 195, 90), M.Grass)
		ball(f, "Leaves", 5, pc * CFrame.new(2, 10.5, 1), C(100, 220, 110), M.Grass)
	end
	f.Parent = Workspace
	ForgeTelemetry.count("plaza_built", 1)
end

-- ===== Theme decoration =====
local props = {}

props[1] = function(f, b, d, i) -- lollipops
	cyl(f, "LollipopStick", 5, 0.4, b * CFrame.new(0, 2.5, 0), C(255, 250, 245), M.SmoothPlastic)
	local head = mk(f, "LollipopHead", Vector3.new(0.6, 3.4, 3.4), b * CFrame.Angles(0, i * 1.3, 0) * CFrame.new(0, 5.8, 0) * CFrame.Angles(0, 0, math.pi / 2) * CFrame.Angles(math.pi / 2, 0, 0), i % 2 == 0 and d.a1 or d.a2)
	head.Shape = Enum.PartType.Cylinder
	head.Size = Vector3.new(0.6, 3.4, 3.4)
end
props[2] = function(f, b, d, i) -- lava cracks + basalt
	for k = 0, 1 do
		mk(f, "LavaCrack", Vector3.new(8, 0.2, 0.6), b * CFrame.Angles(0, i + k * 1.1, 0) * CFrame.new(0, 0.1, 0), k == 0 and d.a1 or d.a2, M.Neon, { collide = false })
	end
	mk(f, "BasaltRock", Vector3.new(3, 2.6, 3), b * CFrame.new(2.5, 1.3, 2) * CFrame.Angles(0.2, i, 0.15), C(55, 32, 34), M.Basalt)
end
props[3] = function(f, b, d, i) -- crystals
	mk(f, "Crystal", Vector3.new(1.7, 6.5, 1.7), b * CFrame.new(0, 3, 0) * CFrame.Angles(0.15, i, 0.12), d.a1, M.Ice, { t = 0.15 })
	mk(f, "Crystal", Vector3.new(1.2, 4, 1.2), b * CFrame.new(1.8, 1.8, 0.8) * CFrame.Angles(-0.2, i * 2, -0.3), d.a2, M.Glass, { t = 0.2 })
end
props[4] = function(f, b, d, i) -- palm trees
	cyl(f, "PalmTrunk", 7, 1, b * CFrame.new(0, 3.5, 0), C(135, 90, 45), M.Wood)
	for k = 0, 3 do
		mk(f, "PalmLeaf", Vector3.new(6, 0.3, 1.8), b * CFrame.Angles(0, k * math.pi / 2 + i, 0) * CFrame.new(2.6, 7.2, 0) * CFrame.Angles(0, 0, -0.35), k % 2 == 0 and d.a1 or C(80, 205, 95), M.Grass)
	end
end
props[5] = function(f, b, d, i) -- neon strips
	mk(f, "NeonPillar", Vector3.new(0.6, 7, 0.6), b * CFrame.new(-2.5, 3.5, 0), d.a1, M.Neon)
	mk(f, "NeonPillar", Vector3.new(0.6, 7, 0.6), b * CFrame.new(2.5, 3.5, 0), d.a2, M.Neon)
	mk(f, "NeonBar", Vector3.new(5.6, 0.6, 0.6), b * CFrame.new(0, 7.3, 0), i % 2 == 0 and d.a1 or d.a2, M.Neon)
end
props[6] = function(f, b, d, i) -- cacti
	local g = d.a1
	cyl(f, "Cactus", 6, 1.4, b * CFrame.new(0, 3, 0), g, M.Grass)
	cyl(f, "CactusArm", 2.4, 0.9, b * CFrame.new(1.5, 3.6, 0) * CFrame.Angles(0, 0, math.pi / 2), g, M.Grass)
	cyl(f, "CactusArm", 2.5, 0.9, b * CFrame.new(2.4, 4.7, 0), g, M.Grass)
	cyl(f, "CactusArm", 2.2, 0.9, b * CFrame.new(-1.5, 2.4, 0) * CFrame.Angles(0, 0, math.pi / 2), g, M.Grass)
	cyl(f, "CactusArm", 2.2, 0.9, b * CFrame.new(-2.4, 3.4, 0), g, M.Grass)
end

local CORNERS = { Vector2.new(-16, -14), Vector2.new(16, -14), Vector2.new(-16, 15), Vector2.new(16, 15) }
local infos = {}

function PlazaBuilder.decoratePlot(plotModelOrFolder, themeIndex, plotCFrame)
	local idx, _, d = resolveTheme(themeIndex)
	local root = plotModelOrFolder
	local isInst = typeof(root) == "Instance"
	local parentFor = if isInst then root else Workspace
	local floorTop = plotCFrame.Position.Y + 0.5
	if isInst then
		infos[root] = { cf = plotCFrame, idx = idx }
		for _, o in ipairs(root:GetDescendants()) do
			if o:IsA("BasePart") then
				local ln = string.lower(o.Name)
				if o.Size.X >= 38 and o.Size.Z >= 38 and o.Size.Y <= 2 then
					o.Material = d.mat
					o.Color = d.floor
					floorTop = o.Position.Y + o.Size.Y / 2
				elseif string.find(ln, "rail") then
					o.Color = d.rail
				elseif string.find(ln, "dropper") and not string.find(ln, "slot") then
					o.Color = d.rail
				elseif string.find(ln, "button") or string.find(ln, "pad") then
					o.Color = d.a2
				end
			end
		end
	end
	local f = Instance.new("Folder")
	f.Name = "Decor"
	local fn = props[idx]
	local dy = floorTop - plotCFrame.Position.Y
	for i, c in ipairs(CORNERS) do
		fn(f, plotCFrame * CFrame.new(c.X, dy, c.Y), d, i)
	end
	f.Parent = parentFor
	ForgeTelemetry.count("themes_built", 1)
end

-- ===== Claim gates and signs =====
local gates = {}

function PlazaBuilder.buildClaimGate(plotCFrame, theme)
	local idx, name, d = resolveTheme(theme)
	local folder = folderIn(Workspace, "ClaimGates")
	local pos = plotCFrame * CFrame.new(0, 0.5 + 0.21, -22)
	local gate = mk(folder, "ClaimGate_" .. name, Vector3.new(12, 0.4, 5), pos, d.a1, M.Neon, { collide = false, t = 0.2 })
	gate:SetAttribute("ThemeName", name)
	local light = Instance.new("PointLight")
	light.Color = d.a1
	light.Range = 14
	light.Parent = gate
	local bb = Instance.new("BillboardGui")
	bb.Name = "ClaimSign"
	bb.Size = UDim2.fromScale(10, 3)
	bb.StudsOffset = Vector3.new(0, 4, 0)
	bb.AlwaysOnTop = false
	bb.MaxDistance = 200
	bb.Adornee = gate
	local lbl = Instance.new("TextLabel")
	lbl.Size = UDim2.fromScale(1, 1)
	lbl.BackgroundTransparency = 1
	lbl.Text = "Claim " .. name .. " Plot"
	lbl.Font = Enum.Font.LuckiestGuy
	lbl.TextScaled = true
	lbl.TextColor3 = C(255, 248, 232)
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = C(28, 22, 38)
	s.Parent = lbl
	lbl.Parent = bb
	bb.Parent = gate
	table.insert(gates, { gate = gate, cf = plotCFrame, bb = bb, light = light, idx = idx, d = d })
	return gate
end

local function resolveCF(plot)
	if typeof(plot) == "Instance" then
		if infos[plot] then return infos[plot].cf end
		if plot:IsA("Model") then return plot:GetPivot() end
	elseif type(plot) == "table" then
		if typeof(plot.origin) == "CFrame" then return plot.origin end
		if typeof(plot.model) == "Instance" and infos[plot.model] then return infos[plot.model].cf end
	end
	return nil
end

local function findGate(cf)
	local best, bd = nil, 8
	for _, g in ipairs(gates) do
		local a, b = g.cf.Position, cf.Position
		local dist = Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
		if dist < bd then best, bd = g, dist end
	end
	return best
end

function PlazaBuilder.setSign(plot, ownerNameOrNil, auto)
	local cf = resolveCF(plot)
	if not cf then return end
	local g = findGate(cf)
	if not g then return end
	local owner = if type(ownerNameOrNil) == "string" and ownerNameOrNil ~= "" then ownerNameOrNil else nil
	if g.sign then
		g.sign:Destroy()
		g.sign = nil
	end
	if owner then
		g.owner = owner
		g.gate.Transparency = 1
		g.gate.CanTouch = false
		g.bb.Enabled = false
		g.light.Enabled = false
		local sf = Instance.new("Folder")
		sf.Name = "OwnerSign"
		local c = g.cf * CFrame.new(-14, 0.5, -18)
		cyl(sf, "SignPost", 5, 0.6, c * CFrame.new(0, 2.5, 0), g.d.dark, M.Wood)
		local board = mk(sf, "SignBoard", Vector3.new(9, 3, 0.5), c * CFrame.new(0, 6.5, 0), g.d.a2, M.SmoothPlastic)
		local sg = Instance.new("SurfaceGui")
		sg.Face = Enum.NormalId.Front
		sg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		sg.PixelsPerStud = 50
		local lbl = Instance.new("TextLabel")
		lbl.Size = UDim2.fromScale(1, 1)
		lbl.BackgroundTransparency = 1
		lbl.Text = owner .. "'s Plot"
		lbl.Font = Enum.Font.LuckiestGuy
		lbl.TextScaled = true
		lbl.TextColor3 = C(255, 248, 232)
		local s = Instance.new("UIStroke")
		s.Thickness = 3
		s.Color = C(28, 22, 38)
		s.Parent = lbl
		lbl.Parent = sg
		sg.Parent = board
		sf.Parent = folderIn(Workspace, "PlotSigns")
		g.sign = sf
	else
		g.owner = nil
		g.gate.Transparency = 0.2
		g.gate.CanTouch = true
		g.bb.Enabled = true
		g.light.Enabled = true
	end
end

return PlazaBuilder
