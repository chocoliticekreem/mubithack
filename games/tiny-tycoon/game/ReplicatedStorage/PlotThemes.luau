-- PlotThemes: shared config for the plaza, the 6-plot ring and the plot themes.
-- Pure data plus small helpers; safe to require from server or client.
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlotThemes = {}

PlotThemes.CLAIM_TIMEOUT = 20
PlotThemes.PLOT_COUNT = 6

-- Ring layout. Plot local space: front (toward the plaza) is -Z, back is +Z.
PlotThemes.Layout = {
	PlazaCenter = Vector3.new(0, 0, 0),
	PlazaRadius = 32,
	RingRadius = 85,
	PlotSize = Vector3.new(40, 1, 40),
	GroundY = 0,
	GateOffset = Vector3.new(0, 0, -17), -- claim gate position in plot local space
	GateSize = Vector3.new(12, 9, 1),
	SignOffset = Vector3.new(0, 7, -17),
}

PlotThemes.Plaza = {
	TileMaterial = Enum.Material.Cobblestone,
	TileColor = Color3.fromRGB(236, 214, 170),
	TileColorAlt = Color3.fromRGB(214, 184, 140),
	TileSize = 8,
	FountainBase = Color3.fromRGB(226, 196, 150),
	FountainWater = Color3.fromRGB(70, 190, 255),
	LampPost = Color3.fromRGB(120, 76, 50),
	LampLight = Color3.fromRGB(255, 226, 120),
	TreeTrunk = Color3.fromRGB(139, 90, 50),
	TreeLeaves = Color3.fromRGB(80, 200, 90),
	GroundColor = Color3.fromRGB(110, 205, 110),
	GroundMaterial = Enum.Material.Grass,
	LampCount = 8,
	TreeCount = 6,
}

-- Decor kinds: lollipop, crack, crystal, palm, neonstrip, cactus.
-- offset is in plot local space (y is height above the floor surface).
PlotThemes.Themes = {
	{
		name = "Candy",
		floorMaterial = Enum.Material.SmoothPlastic,
		floorColor = Color3.fromRGB(255, 176, 214),
		accent = Color3.fromRGB(150, 235, 200),
		rail = Color3.fromRGB(255, 120, 180),
		dropperBody = Color3.fromRGB(120, 220, 180),
		padColor = Color3.fromRGB(255, 92, 160),
		padBoughtColor = Color3.fromRGB(150, 235, 200),
		glow = Color3.fromRGB(255, 120, 200),
		decor = {
			{ kind = "lollipop", offset = Vector3.new(-16, 0, 14), color = Color3.fromRGB(255, 80, 150) },
			{ kind = "lollipop", offset = Vector3.new(16, 0, 15), color = Color3.fromRGB(120, 230, 190) },
			{ kind = "lollipop", offset = Vector3.new(-17, 0, 2), color = Color3.fromRGB(255, 210, 90) },
			{ kind = "lollipop", offset = Vector3.new(0, 0, 17), color = Color3.fromRGB(190, 120, 255) },
		},
	},
	{
		name = "Lava",
		floorMaterial = Enum.Material.Basalt,
		floorColor = Color3.fromRGB(70, 36, 30),
		accent = Color3.fromRGB(255, 120, 30),
		rail = Color3.fromRGB(190, 60, 30),
		dropperBody = Color3.fromRGB(255, 140, 40),
		padColor = Color3.fromRGB(255, 90, 20),
		padBoughtColor = Color3.fromRGB(255, 200, 60),
		glow = Color3.fromRGB(255, 110, 20),
		decor = {
			{ kind = "crack", offset = Vector3.new(-14, 0, 12), color = Color3.fromRGB(255, 120, 20) },
			{ kind = "crack", offset = Vector3.new(14, 0, 14), color = Color3.fromRGB(255, 160, 30) },
			{ kind = "crack", offset = Vector3.new(-15, 0, -2), color = Color3.fromRGB(255, 90, 20) },
			{ kind = "crack", offset = Vector3.new(4, 0, 17), color = Color3.fromRGB(255, 180, 40) },
		},
	},
	{
		name = "Ice",
		floorMaterial = Enum.Material.Ice,
		floorColor = Color3.fromRGB(170, 225, 255),
		accent = Color3.fromRGB(110, 190, 255),
		rail = Color3.fromRGB(90, 170, 240),
		dropperBody = Color3.fromRGB(140, 210, 255),
		padColor = Color3.fromRGB(70, 160, 255),
		padBoughtColor = Color3.fromRGB(190, 240, 255),
		glow = Color3.fromRGB(120, 220, 255),
		decor = {
			{ kind = "crystal", offset = Vector3.new(-16, 0, 14), color = Color3.fromRGB(120, 210, 255) },
			{ kind = "crystal", offset = Vector3.new(15, 0, 15), color = Color3.fromRGB(170, 150, 255) },
			{ kind = "crystal", offset = Vector3.new(-17, 0, 1), color = Color3.fromRGB(150, 240, 255) },
			{ kind = "crystal", offset = Vector3.new(2, 0, 17), color = Color3.fromRGB(100, 180, 255) },
			{ kind = "crystal", offset = Vector3.new(17, 0, 3), color = Color3.fromRGB(190, 230, 255) },
		},
	},
	{
		name = "Jungle",
		floorMaterial = Enum.Material.Grass,
		floorColor = Color3.fromRGB(60, 170, 70),
		accent = Color3.fromRGB(255, 210, 70),
		rail = Color3.fromRGB(150, 100, 50),
		dropperBody = Color3.fromRGB(40, 140, 80),
		padColor = Color3.fromRGB(255, 190, 50),
		padBoughtColor = Color3.fromRGB(120, 230, 100),
		glow = Color3.fromRGB(150, 255, 100),
		decor = {
			{ kind = "palm", offset = Vector3.new(-16, 0, 14), color = Color3.fromRGB(40, 190, 80) },
			{ kind = "palm", offset = Vector3.new(16, 0, 14), color = Color3.fromRGB(70, 210, 60) },
			{ kind = "palm", offset = Vector3.new(-17, 0, 0), color = Color3.fromRGB(30, 170, 100) },
			{ kind = "palm", offset = Vector3.new(0, 0, 17), color = Color3.fromRGB(90, 220, 70) },
		},
	},
	{
		name = "Neon City",
		floorMaterial = Enum.Material.Slate,
		floorColor = Color3.fromRGB(34, 28, 74),
		accent = Color3.fromRGB(255, 60, 220),
		rail = Color3.fromRGB(0, 220, 255),
		dropperBody = Color3.fromRGB(120, 60, 220),
		padColor = Color3.fromRGB(255, 50, 200),
		padBoughtColor = Color3.fromRGB(0, 240, 200),
		glow = Color3.fromRGB(0, 230, 255),
		decor = {
			{ kind = "neonstrip", offset = Vector3.new(-17, 0, 10), color = Color3.fromRGB(255, 60, 220) },
			{ kind = "neonstrip", offset = Vector3.new(17, 0, 10), color = Color3.fromRGB(0, 230, 255) },
			{ kind = "neonstrip", offset = Vector3.new(0, 0, 17), color = Color3.fromRGB(180, 255, 60) },
			{ kind = "neonstrip", offset = Vector3.new(-17, 0, -4), color = Color3.fromRGB(255, 160, 40) },
		},
	},
	{
		name = "Desert",
		floorMaterial = Enum.Material.Sand,
		floorColor = Color3.fromRGB(240, 200, 120),
		accent = Color3.fromRGB(230, 120, 60),
		rail = Color3.fromRGB(200, 120, 70),
		dropperBody = Color3.fromRGB(235, 140, 80),
		padColor = Color3.fromRGB(230, 90, 60),
		padBoughtColor = Color3.fromRGB(255, 220, 100),
		glow = Color3.fromRGB(255, 190, 80),
		decor = {
			{ kind = "cactus", offset = Vector3.new(-16, 0, 14), color = Color3.fromRGB(70, 170, 80) },
			{ kind = "cactus", offset = Vector3.new(16, 0, 13), color = Color3.fromRGB(90, 190, 90) },
			{ kind = "cactus", offset = Vector3.new(-17, 0, 1), color = Color3.fromRGB(60, 160, 100) },
			{ kind = "cactus", offset = Vector3.new(3, 0, 17), color = Color3.fromRGB(100, 200, 80) },
		},
	},
}

function PlotThemes.getTheme(index: number)
	local n = #PlotThemes.Themes
	local i = ((math.floor(tonumber(index) or 1) - 1) % n) + 1
	return PlotThemes.Themes[i]
end

-- World CFrame of a plot's center (top of the ground at GroundY), facing the plaza (-Z toward center).
function PlotThemes.getSlotCFrame(index: number): CFrame
	local L = PlotThemes.Layout
	local a = math.rad(((index - 1) % PlotThemes.PLOT_COUNT) * (360 / PlotThemes.PLOT_COUNT))
	local pos = L.PlazaCenter + Vector3.new(math.sin(a) * L.RingRadius, L.GroundY, math.cos(a) * L.RingRadius)
	local target = Vector3.new(L.PlazaCenter.X, pos.Y, L.PlazaCenter.Z)
	return CFrame.lookAt(pos, target)
end

-- Idempotency helper for builders: returns true the first time a key is seen
-- (e.g. PlotThemes.markBuilt("plot_" .. theme.name)), false afterwards.
local builtKeys: { [string]: boolean } = {}
function PlotThemes.markBuilt(key: string): boolean
	if builtKeys[key] then
		return false
	end
	builtKeys[key] = true
	return true
end

-- One-shot build counters can never exceed their expected total, even if a
-- builder accidentally runs twice.
local COUNTER_CAPS: { [string]: number } = {
	themes_built = PlotThemes.PLOT_COUNT,
	plaza_built = 1,
}
local counterTotals: { [string]: number } = {}

-- Server-only safe telemetry bump (plaza_built, themes_built, plots_claimed, auto_claims).
function PlotThemes.bump(name: string, n: number?)
	if not RunService:IsServer() then
		return
	end
	local amount = n or 1
	local cap = COUNTER_CAPS[name]
	if cap then
		local used = counterTotals[name] or 0
		local remaining = cap - used
		if remaining <= 0 then
			return
		end
		amount = math.min(amount, remaining)
		counterTotals[name] = used + amount
	end
	local mod = ReplicatedStorage:FindFirstChild("ForgeTelemetry")
	if not mod then
		return
	end
	local ok, tele = pcall(require, mod)
	if ok and type(tele) == "table" and type(tele.count) == "function" then
		pcall(tele.count, name, amount)
	end
end

return PlotThemes
