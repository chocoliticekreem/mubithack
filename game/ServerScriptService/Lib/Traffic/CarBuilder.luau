--!strict
-- CarBuilder [owner: Traffic]. Chunky low-poly cartoon traffic with googly-eyed headlights.
--   CarBuilder.Build(kind, cf, rng) -> (Model, Info)   -- unparented; caller parents it
--   CarBuilder.Kinds = { "sedan", "taxi", "van", "bus", "icecream" }
-- cf = ground point under the car's centre; the car faces -Z of cf.
-- Structure (what TrafficService / TrafficController rely on):
--   PrimaryPart "Hitbox": invisible box W x H x L centred H/2 above the ground point, ANCHORED,
--     CanCollide/CanQuery/CanTouch false on the server (the client turns CanCollide on locally).
--   Every visual part is welded (WeldConstraint) to the Hitbox, unanchored, Massless and
--     non-colliding, so moving the Hitbox's CFrame moves the whole car (one CFrame per car per frame).
--   "DriverHead": the driver's head in the cab (hidden when the driver pops out).
-- Model attributes: Kind, RootY (= H/2), HalfLen.
-- Sedans and taxis reuse PropKit.car when it is available.
local ServerScriptService = game:GetService("ServerScriptService")

local V = Vector3.new
local CF = CFrame.new
local hex = Color3.fromHex
local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.fromHex("#111111")

local C = {
	Tyre = hex("#26232A"),
	Chrome = hex("#D6D8DC"),
	Glass = hex("#A8D5E2"),
	Lamp = hex("#FFF1D6"),
	Tail = hex("#B83A2E"),
	Ink = hex("#1E1A22"),
	Skin = { hex("#D98A4E"), hex("#F0C49C"), hex("#8A5A3A"), hex("#C9875A") },
	Taxi = hex("#F2C230"),
	BusOrange = hex("#E8913A"),
	Cream = hex("#FFF1D6"),
	Pink = hex("#E86A92"),
	Mint = hex("#9EE0C4"),
	Waffle = hex("#D9A050"),
}

local SEDAN_COLORS = {
	hex("#2A9D8F"), hex("#3A7FD0"), hex("#CF442B"), hex("#7A4E9A"), hex("#6BCB5A"),
	hex("#E9C46A"), hex("#F2B07E"), hex("#E86A92"), hex("#4F8A85"), hex("#9EC1CC"),
}
local VAN_COLORS = { hex("#F2EDE4"), hex("#9DB38A"), hex("#D98B6F"), hex("#3A7FD0"), hex("#E8D3A8") }

export type Info = { halfLen: number, height: number, width: number, speedMul: number }

local CarBuilder = {}
CarBuilder.Kinds = { "sedan", "taxi", "van", "bus", "icecream" }

local PropKit: any = nil
do
	local ok, mod = pcall(function()
		local lib = ServerScriptService:FindFirstChild("Lib")
		local map = lib and lib:FindFirstChild("Map")
		local props = map and map:FindFirstChild("Props")
		local pk = props and props:FindFirstChild("PropKit")
		return if pk then require(pk :: ModuleScript) else nil
	end)
	if ok and type(mod) == "table" and type((mod :: any).car) == "function" then
		PropKit = mod
	end
end

local function part(m: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, shape: Enum.PartType?, mat: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = mat or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Parent = m
	return p
end

local function wheel(m: Instance, cf: CFrame, d: number)
	part(m, "Wheel", cf, V(1.3, d, d), C.Tyre, Enum.PartType.Cylinder)
	part(m, "Hub", cf, V(1.4, d * 0.45, d * 0.45), C.Chrome, Enum.PartType.Cylinder)
end

-- Big googly eyes that ARE the headlights: white ball, off-centre pupil (looks derpy), lamp glow.
local function googlyHeadlights(m: Instance, cf: CFrame, gap: number, size: number, rng: Random)
	for i, side in { -1, 1 } do
		local eyeCf = cf * CF(side * gap, 0, 0)
		local eye = part(m, `HeadlightEye{i}`, eyeCf, V(size, size, size), WHITE, Enum.PartType.Ball)
		eye.Material = Enum.Material.Neon
		eye.Color = C.Lamp
		local px = (rng:NextNumber() - 0.5) * size * 0.3
		local py = (rng:NextNumber() - 0.5) * size * 0.3
		part(m, `Pupil{i}`, eyeCf * CF(px, py, -size * 0.4), V(size, size, size) * 0.42, BLACK, Enum.PartType.Ball)
	end
	local glow = Instance.new("SpotLight")
	glow.Name = "Beam"
	glow.Range = 28
	glow.Angle = 70
	glow.Brightness = 1.6
	glow.Color = C.Lamp
	glow.Face = Enum.NormalId.Front
	glow.Parent = m:FindFirstChild("HeadlightEye1")
end

local function driverHead(m: Instance, cf: CFrame, rng: Random, hat: Color3?)
	local skin = C.Skin[rng:NextInteger(1, #C.Skin)]
	local head = part(m, "DriverHead", cf, V(1.6, 1.6, 1.6), skin, Enum.PartType.Ball)
	part(m, "DriverEyeL", cf * CF(-0.35, 0.15, -0.7), V(0.45, 0.45, 0.45), WHITE, Enum.PartType.Ball)
	part(m, "DriverEyeR", cf * CF(0.35, 0.15, -0.7), V(0.45, 0.45, 0.45), WHITE, Enum.PartType.Ball)
	if hat then
		part(m, "DriverHat", cf * CF(0, 0.8, 0), V(1.7, 0.5, 1.7), hat)
	end
	head:SetAttribute("Driver", true)
end

-- A boxy body: wheels, chassis, cabin box, glass, bumpers, taillights. Returns nothing; dims by args.
local function boxBody(m: Instance, cf: CFrame, W: number, L: number, H: number, col: Color3, rng: Random)
	local wheelD = 2.8
	local wz = L / 2 - 2.6
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			wheel(m, cf * CF(sx * (W / 2 - 0.2), wheelD / 2, sz * wz), wheelD)
		end
	end
	part(m, "Chassis", cf * CF(0, 1.5, 0), V(W - 0.4, 0.6, L - 0.6), C.Ink)
	part(m, "Body", cf * CF(0, 1.8 + (H - 2.2) / 2, 0), V(W, H - 2.2, L), col)
	part(m, "Roof", cf * CF(0, H - 0.2, 0), V(W - 0.3, 0.4, L - 0.3), col:Lerp(WHITE, 0.2))
	part(m, "Windshield", cf * CF(0, H - 1.7, -L / 2 - 0.05), V(W - 1.2, 2.0, 0.3), C.Glass, nil, Enum.Material.Glass).Transparency = 0.2
	for _, sz in { -1, 1 } do
		part(m, "Bumper", cf * CF(0, 1.4, sz * (L / 2 + 0.2)), V(W + 0.2, 0.7, 0.5), C.Chrome)
	end
	for _, sx in { -1, 1 } do
		part(m, "Taillight", cf * CF(sx * (W / 2 - 0.9), 2.4, L / 2 + 0.1), V(1.0, 0.7, 0.3), C.Tail, nil, Enum.Material.Neon)
	end
	part(m, "Grille", cf * CF(0, 2.2, -L / 2 - 0.1), V(W * 0.4, 0.8, 0.3), C.Ink)
	googlyHeadlights(m, cf * CF(0, 2.6, -L / 2 - 0.35), W / 2 - 1.1, 1.5, rng)
end

local builders: { [string]: (m: Model, cf: CFrame, rng: Random) -> Info } = {}

builders.sedan = function(m, cf, rng)
	local col = SEDAN_COLORS[rng:NextInteger(1, #SEDAN_COLORS)]
	if PropKit then
		local ok = pcall(function()
			PropKit.car(m, cf, { color = col })
		end)
		if ok then
			-- PropKit's headlights become googly eyes
			local inner = m:FindFirstChild("Car")
			if inner then
				for _, d in inner:GetChildren() do
					if d.Name == "Headlight" then
						d:Destroy()
					end
				end
			end
			googlyHeadlights(m, cf * CF(0, 2.4, -5.9), 2.0, 1.3, rng)
			driverHead(m, cf * CF(-1.2, 4.0, 0.2), rng, nil)
			return { halfLen = 5.9, height = 5.6, width = 6.6, speedMul = 1 }
		end
	end
	boxBody(m, cf, 6.4, 11, 5.4, col, rng)
	driverHead(m, cf * CF(-1.2, 4.0, -1), rng, nil)
	return { halfLen = 5.8, height = 5.6, width = 6.6, speedMul = 1 }
end

builders.taxi = function(m, cf, rng)
	local info: Info
	if PropKit and pcall(function()
		PropKit.car(m, cf, { color = C.Taxi })
	end) then
		local inner = m:FindFirstChild("Car")
		if inner then
			for _, d in inner:GetChildren() do
				if d.Name == "Headlight" then
					d:Destroy()
				end
			end
		end
		googlyHeadlights(m, cf * CF(0, 2.4, -5.9), 2.0, 1.3, rng)
		info = { halfLen = 5.9, height = 6.6, width = 6.6, speedMul = 1.15 }
	else
		boxBody(m, cf, 6.4, 11, 5.4, C.Taxi, rng)
		info = { halfLen = 5.8, height = 6.6, width = 6.6, speedMul = 1.15 }
	end
	-- checker stripe + roof sign
	for i = -4, 4 do
		local c = if i % 2 == 0 then C.Ink else WHITE
		part(m, "Checker", cf * CF(-3.35, 2.3, i * 1.1), V(0.2, 0.55, 1.1), c)
		part(m, "Checker", cf * CF(3.35, 2.3, i * 1.1), V(0.2, 0.55, 1.1), c)
	end
	local sign = part(m, "TaxiSign", cf * CF(0, 5.95, 0.8), V(2.8, 0.9, 1.0), C.Cream, nil, Enum.Material.Neon)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.CanvasSize = Vector2.new(140, 45)
	gui.Parent = sign
	local t = Instance.new("TextLabel")
	t.Size = UDim2.fromScale(1, 1)
	t.BackgroundTransparency = 1
	t.Text = "TAXI"
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = C.Ink
	t.Parent = gui
	driverHead(m, cf * CF(-1.2, 4.0, 0.2), rng, C.Ink)
	return info
end

builders.van = function(m, cf, rng)
	local col = VAN_COLORS[rng:NextInteger(1, #VAN_COLORS)]
	boxBody(m, cf, 6.8, 13, 7.6, col, rng)
	-- side windows on the front third, a goofy side stripe
	for _, sx in { -1, 1 } do
		part(m, "SideWindow", cf * CF(sx * 3.45, 5.6, -4.2), V(0.2, 1.8, 3.2), C.Glass, nil, Enum.Material.Glass)
		part(m, "Stripe", cf * CF(sx * 3.45, 3.4, 1.2), V(0.2, 0.8, 9.5), col:Lerp(BLACK, 0.35))
	end
	part(m, "RoofRack", cf * CF(0, 7.7, 1), V(5.4, 0.3, 7), C.Chrome)
	driverHead(m, cf * CF(-1.4, 5.6, -4.6), rng, nil)
	return { halfLen = 6.7, height = 7.8, width = 7, speedMul = 0.95 }
end

builders.bus = function(m, cf, rng)
	local W, L, H = 7.6, 24, 9.4
	boxBody(m, cf, W, L, H, C.BusOrange, rng)
	for _, sx in { -1, 1 } do
		for i = 0, 5 do
			part(m, "BusWindow", cf * CF(sx * (W / 2 + 0.05), 6.4, -8.4 + i * 3.4), V(0.2, 2.2, 2.8), C.Glass, nil, Enum.Material.Glass)
		end
		part(m, "BusStripe", cf * CF(sx * (W / 2 + 0.05), 3.4, 0), V(0.2, 0.9, L - 1), C.Cream)
	end
	part(m, "RouteSign", cf * CF(0, H - 0.9, -L / 2 - 0.1), V(W - 2, 1, 0.3), C.Ink, nil, Enum.Material.Neon).Color =
		hex("#FFC531")
	driverHead(m, cf * CF(-2, 6.4, -10.4), rng, hex("#3A7FD0"))
	return { halfLen = 12.3, height = 9.6, width = 7.8, speedMul = 0.8 }
end

builders.icecream = function(m, cf, rng)
	local W, L, H = 7, 14, 8.6
	boxBody(m, cf, W, L, H, C.Cream, rng)
	for _, sx in { -1, 1 } do
		part(m, "Serving", cf * CF(sx * (W / 2 + 0.05), 5.2, 1.5), V(0.2, 2.6, 5), C.Glass, nil, Enum.Material.Glass)
		part(m, "Awning", cf * CF(sx * (W / 2 + 0.5), 6.9, 1.5), V(1.2, 0.3, 5.6), C.Pink)
		for i = 0, 6 do
			part(m, "Drip", cf * CF(sx * (W / 2 + 0.05), 2.8, -5.5 + i * 1.9), V(0.2, 1.4, 1.2), if i % 2 == 0 then C.Pink else C.Mint, Enum.PartType.Ball)
		end
	end
	-- the giant cone on the roof
	local top = cf * CF(0, H + 1.6, 2)
	part(m, "IceCreamTop", top * CFrame.Angles(math.pi, 0, 0), V(2.6, 3.2, 2.6), C.Waffle, nil, Enum.Material.Sand)
	part(m, "Scoop1", top * CF(0, 2.0, 0), V(3, 3, 3), C.Pink, Enum.PartType.Ball)
	part(m, "Scoop2", top * CF(0, 3.9, 0), V(2.4, 2.4, 2.4), C.Mint, Enum.PartType.Ball)
	part(m, "Cherry", top * CF(0, 5.3, 0), V(0.9, 0.9, 0.9), C.Tail, Enum.PartType.Ball)
	driverHead(m, cf * CF(-1.4, 5.8, -4.6), rng, WHITE)
	return { halfLen = 7.2, height = H + 7, width = 7.2, speedMul = 0.7 }
end

function CarBuilder.Build(kind: string, cf: CFrame, rng: Random): (Model, Info)
	local build = builders[kind] or builders.sedan
	local m = Instance.new("Model")
	m.Name = `TrafficCar_{kind}`
	local info = build(m, cf, rng)
	local H = math.min(info.height, 9.6)
	local root = Instance.new("Part")
	root.Name = "Hitbox"
	root.Transparency = 1
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Size = V(info.width, H, info.halfLen * 2)
	root.CFrame = cf * CF(0, H / 2, 0)
	root.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.4, 0.5)
	root.Parent = m
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Massless = true
			d.Anchored = false
			local w = Instance.new("WeldConstraint")
			w.Part0 = root
			w.Part1 = d
			w.Parent = d
			for _, tag in d:GetTags() do
				d:RemoveTag(tag) -- PropKit might tag Flammable: traffic is not fire fuel
			end
		end
	end
	m.PrimaryPart = root
	m:SetAttribute("Kind", kind)
	m:SetAttribute("RootY", H / 2)
	m:SetAttribute("HalfLen", info.halfLen)
	pcall(function()
		m.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end)
	return m, info
end

return CarBuilder
