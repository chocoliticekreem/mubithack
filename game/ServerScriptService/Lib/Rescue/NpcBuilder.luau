--!strict
-- NpcBuilder: part-built display models for the cast (docs/game/02 §3, docs/game/05).
-- NpcBuilder.Build(kind, cf, opts) -> Model (unparented; caller parents it).
--   cf   = ground point under the character; the character faces -Z of cf.
--   opts = { helmet: number? (firefighter badge, default 1), color: Color3? (civilian shirt),
--            pose: "stand" | "lying" | "sitting"? }
-- Everything is Anchored and CanCollide=false. PrimaryPart "Root" is an invisible box around the
-- body whose PivotOffset puts the model pivot on the ground point, so Model:PivotTo(groundCf) works.
-- Attributes: Kind (= kind), Pose, and Helmet for firefighters.
-- Poses: "lying" = knocked out (on the back for people, on the side for pets) with X eyes and
-- dizzy stars. "sitting" is built for civilians; cat and panda always sit; others ignore it.
-- No randomness: identical inputs give identical models.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("MapKit") :: ModuleScript)

local NpcBuilder = {}

NpcBuilder.Kinds = { "Firefighter", "Civilian", "Dog", "Cat", "Panda" }

export type Opts = {
	helmet: number?,
	color: Color3?,
	pose: string?,
}

local function hex(h: string): Color3
	return Color3.fromHex(h)
end

-- Palette (docs/game/02 §1).
local C = {
	CoatYellow = hex("#D9A030"),
	CoatShadow = hex("#9A6A30"),
	ReflectLime = hex("#E8E25A"),
	ReflectSilver = hex("#C9CCD0"),
	GloveOlive = hex("#8C7A3A"),
	HelmetRed = hex("#C0301E"),
	HelmetDark = hex("#962414"),
	HelmetShield = hex("#E8C24A"),
	NumberInk = hex("#1A1210"),
	SkinWarm = hex("#D98A4E"),
	SkinPale = hex("#F0C49C"),
	Blush = hex("#F29A8A"),
	EyeWhite = hex("#FFFFFF"),
	Pupil = hex("#111111"),
	CivTeeWhite = hex("#F2EEE6"),
	Jeans = hex("#56688A"),
	Shoe = hex("#3A2E2A"),
	Boot = hex("#2B2522"),
	Chrome = hex("#D6D8DC"),
	TruckRed = hex("#C8232B"),
	Soot = hex("#2A2826"),
	Tongue = hex("#E26A7A"),
	DogOrange = hex("#D9822B"),
	DogWhite = hex("#F6F0E4"),
	DogSaddle = hex("#4A3226"),
	CatOrange = hex("#E8873A"),
	CatStripe = hex("#B4561E"),
	CatCream = hex("#F6D9A8"),
	CatPink = hex("#F2A0A8"),
	Drool = hex("#CFEFFF"),
	PandaWhite = hex("#F4F1EA"),
	PandaBlack = hex("#1E1B1D"),
	PawPad = hex("#E9B7B0"),
	Bamboo = hex("#8DBB4A"),
	BambooDark = hex("#5E8A30"),
	Star = hex("#FFE45C"),
}

type Ctx = {
	m: Model,
	base: CFrame,
	s: number,
	ko: boolean,
}

-- Local (unscaled) CFrame -> world CFrame.
local function W(ctx: Ctx, lcf: CFrame): CFrame
	return ctx.base * (CFrame.new(lcf.Position * ctx.s) * lcf.Rotation)
end

type Extra = { neon: boolean?, transparency: number?, material: Enum.Material? }

local function finish(p: BasePart)
	p.CanCollide = false
	p.CanTouch = false
	p.Massless = true
end

local function box(ctx: Ctx, name: string, lcf: CFrame, size: Vector3, color: Color3, x: Extra?): Part
	local e = x or {} :: Extra
	local p = MapKit.part(ctx.m, name, W(ctx, lcf), size * ctx.s, {
		color = color,
		collide = false,
		neon = e.neon,
		transparency = e.transparency,
		material = e.material,
	})
	finish(p)
	return p
end

local function ball(ctx: Ctx, name: string, lcf: CFrame, d: number, color: Color3, x: Extra?): Part
	local e = x or {} :: Extra
	local p = MapKit.part(ctx.m, name, W(ctx, lcf), Vector3.one * d * ctx.s, {
		color = color,
		shape = Enum.PartType.Ball,
		collide = false,
		neon = e.neon,
		transparency = e.transparency,
	})
	finish(p)
	return p
end

-- Ellipsoid filling `size` (block part + sphere SpecialMesh).
local function blob(ctx: Ctx, name: string, lcf: CFrame, size: Vector3, color: Color3, x: Extra?): Part
	local p = box(ctx, name, lcf, size, color, x)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

-- Vertical elliptical cylinder: height h, diameters dx (X) and dz (Z), centred at lcf.
local function ecyl(ctx: Ctx, name: string, lcf: CFrame, h: number, dx: number, dz: number, color: Color3, x: Extra?): Part
	local p = box(ctx, name, lcf * CFrame.Angles(0, 0, math.pi / 2), Vector3.new(h, dx, dz), color, x)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Cylinder
	mesh.Parent = p
	return p
end

-- Round cylinder along the local Y axis of lcf.
local function cyl(ctx: Ctx, name: string, lcf: CFrame, len: number, d: number, color: Color3): Part
	local p = MapKit.part(ctx.m, name, W(ctx, lcf * CFrame.Angles(0, 0, math.pi / 2)), Vector3.new(len, d, d) * ctx.s, {
		color = color,
		shape = Enum.PartType.Cylinder,
		collide = false,
	})
	finish(p)
	return p
end

local function wedge(ctx: Ctx, name: string, lcf: CFrame, size: Vector3, color: Color3): WedgePart
	local p = Instance.new("WedgePart")
	p.Name = name
	p.Anchored = true
	p.Size = size * ctx.s
	p.CFrame = W(ctx, lcf)
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	finish(p)
	p.Parent = ctx.m
	return p
end

-- Triangle (ear) in the local XY plane of lcf, base `w` wide, `h` tall, `t` thick, peak up.
local function triangle(ctx: Ctx, name: string, lcf: CFrame, w: number, h: number, t: number, color: Color3)
	local rot = lcf * CFrame.Angles(0, math.pi / 2, 0)
	wedge(ctx, name .. "A", rot * CFrame.new(0, 0, -w / 4), Vector3.new(t, h, w / 2), color)
	wedge(ctx, name .. "B", rot * CFrame.new(0, 0, w / 4) * CFrame.Angles(0, math.pi, 0), Vector3.new(t, h, w / 2), color)
end

-- One googly eye at lcf (facing -Z). look = pupil drift in [-1, 1]; ko = X eyes.
local function eye(ctx: Ctx, name: string, lcf: CFrame, d: number, look: Vector2, pupilScale: number?)
	ball(ctx, name, lcf, d, C.EyeWhite)
	if ctx.ko then
		for i, a in { 45, -45 } do
			box(ctx, `{name}X{i}`, lcf * CFrame.new(0, 0, -d * 0.47) * CFrame.Angles(0, 0, math.rad(a)), Vector3.new(d * 0.72, d * 0.14, 0.08), C.Pupil)
		end
	else
		local ps = pupilScale or 0.42
		local off = Vector3.new(look.X * d * 0.2, look.Y * d * 0.2, -d * (0.5 - ps / 2) - d * 0.02)
		ball(ctx, name .. "Pupil", lcf * CFrame.new(off), d * ps, C.Pupil)
		-- tiny highlight so the eyes read glossy
		ball(ctx, name .. "Shine", lcf * CFrame.new(off + Vector3.new(d * 0.08, d * 0.09, -d * ps * 0.32)), d * 0.1, C.EyeWhite, { neon = true })
	end
end

-- Dizzy stars circling above a world point (KO only).
local function dizzy(ctx: Ctx, worldPos: Vector3)
	for i = 1, 5 do
		local a = (i - 1) * math.pi * 2 / 5
		local p = MapKit.part(ctx.m, `DizzyStar{i}`, CFrame.new(worldPos) * CFrame.Angles(0, a, 0) * CFrame.new(1.2 * ctx.s, 0.15 * math.sin(a * 2), 0) * CFrame.Angles(0, 0, math.rad(45)), Vector3.new(0.35, 0.35, 0.12) * ctx.s, {
			color = C.Star,
			collide = false,
			neon = true,
		})
		finish(p)
	end
end

-- Reflective lime/silver/lime band as stacked elliptical rings at height y (local), radii rx/rz.
local function band3(ctx: Ctx, name: string, lcf: CFrame, dx: number, dz: number)
	ecyl(ctx, name .. "1", lcf * CFrame.new(0, -0.14, 0), 0.14, dx, dz, C.ReflectLime)
	ecyl(ctx, name .. "2", lcf, 0.12, dx, dz, C.ReflectSilver)
	ecyl(ctx, name .. "3", lcf * CFrame.new(0, 0.14, 0), 0.14, dx, dz, C.ReflectLime)
end

-- Radius of an ellipsoid (centre cy, half-height hy, half-width r) at height y.
local function ellR(r: number, cy: number, hy: number, y: number): number
	local t = (y - cy) / hy
	return r * math.sqrt(math.max(0, 1 - t * t))
end

-- Dims: { w, h, d } unscaled; back = how far the back sticks out (+Z) for lying lift.
type Dims = { w: number, h: number, d: number, back: number, head: Vector3 }

---------------------------------------------------------------------------- Firefighter
local function buildFirefighter(ctx: Ctx, opts: Opts): Dims
	local num = math.clamp(math.floor(opts.helmet or 1), 0, 99)
	local ko = ctx.ko

	-- Boots and legs
	for i, side in { -1, 1 } do
		local x = side * 0.62
		box(ctx, `Boot{i}`, CFrame.new(x, 0.35, -0.05), Vector3.new(1.05, 0.7, 1.3), C.Boot)
		blob(ctx, `BootToe{i}`, CFrame.new(x, 0.32, -0.62), Vector3.new(1.05, 0.64, 0.9), C.Boot)
		box(ctx, `BootCuff{i}`, CFrame.new(x, 0.72, -0.05), Vector3.new(1.12, 0.14, 1.12), C.ReflectLime)
		box(ctx, `Leg{i}`, CFrame.new(x, 1.25, 0), Vector3.new(0.95, 1.1, 0.95), C.CoatShadow)
		box(ctx, `ShinBandA{i}`, CFrame.new(x, 1.0, 0), Vector3.new(1.0, 0.13, 1.0), C.ReflectLime)
		box(ctx, `ShinBandB{i}`, CFrame.new(x, 1.12, 0), Vector3.new(1.0, 0.11, 1.0), C.ReflectSilver)
		box(ctx, `ShinBandC{i}`, CFrame.new(x, 1.24, 0), Vector3.new(1.0, 0.13, 1.0), C.ReflectLime)
	end

	-- Bean body: coat ellipsoid + skin top, one blob, no neck.
	local BY, BH, BRX, BRZ = 3.1, 1.8, 1.55, 1.35
	blob(ctx, "Body", CFrame.new(0, BY, 0), Vector3.new(BRX * 2, BH * 2, BRZ * 2), C.CoatYellow)
	blob(ctx, "CoatHem", CFrame.new(0, 1.95, 0.02), Vector3.new(2.9, 1.3, 2.55), C.CoatShadow)
	local function bodyBand(y: number)
		return ellR(BRX, BY, BH, y) * 2 + 0.1, ellR(BRZ, BY, BH, y) * 2 + 0.1
	end
	local dx, dz = bodyBand(2.65)
	band3(ctx, "ChestBand", CFrame.new(0, 2.65, 0), dx, dz)
	-- Coat closure strip and toggles down the front
	for i, y in { 3.35, 3.0, 2.15 } do
		local z = -ellR(BRZ, BY, BH, y)
		box(ctx, `Toggle{i}`, CFrame.new(0, y, z - 0.02), Vector3.new(0.38, 0.14, 0.14), C.Boot)
	end
	-- Head (skin) rising out of the coat
	local HY, HH, HRX, HRZ = 4.5, 1.1, 1.35, 1.22
	blob(ctx, "Head", CFrame.new(0, HY, 0), Vector3.new(HRX * 2, HH * 2, HRZ * 2), C.SkinWarm)
	local cy = 3.8
	ecyl(ctx, "Collar", CFrame.new(0, cy, 0), 0.32, 3.0, 2.64, C.CoatYellow)
	ecyl(ctx, "CollarLine", CFrame.new(0, cy - 0.17, 0), 0.06, 3.04, 2.68, C.CoatShadow)
	-- Face: mouth, blush, soot
	local mz = -ellR(HRZ, HY, HH, 4.05)
	if ko then
		box(ctx, "Mouth", CFrame.new(0, 4.05, mz - 0.02) * CFrame.Angles(0, 0, math.rad(8)), Vector3.new(0.42, 0.08, 0.08), C.NumberInk)
	else
		blob(ctx, "Mouth", CFrame.new(0.05, 4.07, mz - 0.01), Vector3.new(0.28, 0.24, 0.12), C.NumberInk)
	end
	blob(ctx, "Soot", CFrame.new(0.82, 4.15, -ellR(HRZ, HY, HH, 4.15) * 0.72) * CFrame.Angles(0, math.rad(-40), math.rad(20)), Vector3.new(0.5, 0.26, 0.1), C.Soot)

	-- Googly eyes (MapKit), one pupil drifting outward for the derp look.
	local eyeY, eyeZ, eyeD = 4.62, -1.2, 1.15
	if ko then
		eye(ctx, "EyeL", CFrame.new(-0.6, eyeY, eyeZ), eyeD, Vector2.zero)
		eye(ctx, "EyeR", CFrame.new(0.6, eyeY, eyeZ), eyeD, Vector2.zero)
	else
		local folder = Instance.new("Model")
		folder.Name = "Eyes"
		folder.Parent = ctx.m
		MapKit.googlyEyes(folder, W(ctx, CFrame.new(0, eyeY, eyeZ)), eyeD * ctx.s, 0.6 * ctx.s)
		for _, c in folder:GetChildren() do
			if c:IsA("BasePart") then
				finish(c)
			end
		end
		local p1 = folder:FindFirstChild("Pupil1") :: BasePart?
		if p1 then
			p1.CFrame = p1.CFrame * CFrame.new(-0.18 * ctx.s, 0.12 * ctx.s, 0.04 * ctx.s)
		end
		local p2 = folder:FindFirstChild("Pupil2") :: BasePart?
		if p2 then
			p2.CFrame = p2.CFrame * CFrame.new(-0.06 * ctx.s, 0.02 * ctx.s, 0)
		end
	end

	-- Helmet: dome, rear-heavy brim, comb ridge, gold front shield with the number.
	local DY = 5.45
	ecyl(ctx, "Brim", CFrame.new(0, 5.22, 0.3), 0.2, 3.5, 4.1, C.HelmetDark)
	blob(ctx, "HelmetDome", CFrame.new(0, DY, 0.05), Vector3.new(2.9, 2.0, 3.05), C.HelmetRed)
	blob(ctx, "HelmetComb", CFrame.new(0, DY + 0.82, 0.15), Vector3.new(0.4, 0.5, 2.7), C.HelmetDark)
	box(ctx, "ShieldHolder", CFrame.new(0, DY + 0.55, -1.3) * CFrame.Angles(math.rad(25), 0, 0), Vector3.new(0.3, 0.35, 0.2), C.Chrome)
	local shield = box(ctx, "Shield", CFrame.new(0, DY + 0.1, -1.52) * CFrame.Angles(math.rad(15), 0, 0), Vector3.new(1.15, 1.0, 0.14), C.HelmetShield)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Number"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 100
	gui.LightInfluence = 1
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Position = UDim2.fromScale(0, 0)
	label.Font = Enum.Font.LuckiestGuy
	label.Text = string.format("%02d", num)
	label.TextColor3 = C.NumberInk
	label.TextScaled = true
	label.Parent = gui
	gui.Parent = shield

	-- Arms: left hangs, right waves (KO: both flopped out).
	for i, side in { -1, 1 } do
		local ang = if ko then 75 elseif side == 1 then 150 else 18
		local pivot = CFrame.new(side * 1.5, 3.75, 0) * CFrame.Angles(0, 0, math.rad(side * ang))
		box(ctx, `Arm{i}`, pivot * CFrame.new(0, -0.8, 0), Vector3.new(0.82, 1.6, 0.82), C.CoatYellow)
		box(ctx, `CuffA{i}`, pivot * CFrame.new(0, -1.25, 0), Vector3.new(0.88, 0.12, 0.88), C.ReflectLime)
		box(ctx, `CuffB{i}`, pivot * CFrame.new(0, -1.36, 0), Vector3.new(0.88, 0.1, 0.88), C.ReflectSilver)
		box(ctx, `CuffC{i}`, pivot * CFrame.new(0, -1.47, 0), Vector3.new(0.88, 0.12, 0.88), C.ReflectLime)
		blob(ctx, `Glove{i}`, pivot * CFrame.new(0, -1.9, 0), Vector3.new(1.0, 0.95, 0.9), C.GloveOlive)
		blob(ctx, `Thumb{i}`, pivot * CFrame.new(-side * 0.45, -1.75, -0.2), Vector3.new(0.35, 0.5, 0.35), C.GloveOlive)
		box(ctx, `Strap{i}`, CFrame.new(side * 0.75, 3.35, -ellR(BRZ, BY, BH, 3.35) - 0.02) * CFrame.Angles(0, 0, math.rad(-side * 8)), Vector3.new(0.28, 1.4, 0.1), C.Soot)
	end
	box(ctx, "SootSleeve", CFrame.new(-1.5, 3.75, 0) * CFrame.Angles(0, 0, math.rad(-18)) * CFrame.new(0, -0.55, -0.42), Vector3.new(0.45, 0.35, 0.04), C.Soot)

	-- Air tank on the back
	local tz = ellR(BRZ, BY, BH, 3.2) + 0.45
	cyl(ctx, "Tank", CFrame.new(0, 3.2, tz), 2.1, 0.95, C.Chrome)
	ball(ctx, "TankTop", CFrame.new(0, 4.25, tz), 0.95, C.Chrome)
	ball(ctx, "TankBottom", CFrame.new(0, 2.15, tz), 0.95, C.Chrome)
	cyl(ctx, "TankBand", CFrame.new(0, 3.2, tz), 0.35, 1.0, C.TruckRed)
	box(ctx, "TankValve", CFrame.new(0, 4.82, tz), Vector3.new(0.3, 0.3, 0.3), C.Boot)
	box(ctx, "Harness", CFrame.new(0, 3.2, tz - 0.4), Vector3.new(1.4, 0.25, 0.3), C.Soot)

	return { w = 3.6, h = 6.5, d = 3.3, back = tz + 0.5, head = Vector3.new(0, 6.6, 0) }
end

---------------------------------------------------------------------------- Civilian
local function buildCivilian(ctx: Ctx, opts: Opts): Dims
	local shirt = opts.color or C.CivTeeWhite
	local ko = ctx.ko
	local sitting = opts.pose == "sitting"
	local up = if sitting then -1.1 else 0 -- upper-body drop when sitting on the ground

	for i, side in { -1, 1 } do
		local x = side * 0.5
		if sitting then
			box(ctx, `Leg{i}`, CFrame.new(x, 0.43, -0.75), Vector3.new(0.85, 0.85, 1.7), C.Jeans)
			box(ctx, `Shoe{i}`, CFrame.new(x, 0.62, -1.8), Vector3.new(0.9, 1.2, 0.45), C.Shoe)
		else
			local spread = if ko then side * 12 else 0
			local hip = CFrame.new(x, 1.95, 0) * CFrame.Angles(0, 0, math.rad(spread))
			box(ctx, `Leg{i}`, hip * CFrame.new(0, -0.75, 0), Vector3.new(0.85, 1.5, 0.85), C.Jeans)
			box(ctx, `Shoe{i}`, hip * CFrame.new(0, -1.72, -0.12), Vector3.new(0.92, 0.45, 1.2), C.Shoe)
		end
	end
	local function U(x: number, y: number, z: number): CFrame
		return CFrame.new(x, y + up, z)
	end
	-- Blocky tee torso with a soft belly
	box(ctx, "Torso", U(0, 2.9, 0), Vector3.new(2.3, 1.9, 1.2), shirt)
	blob(ctx, "Belly", U(0, 2.65, -0.45), Vector3.new(1.9, 1.4, 0.7), shirt)
	box(ctx, "Belt", U(0, 2.0, 0), Vector3.new(2.32, 0.18, 1.22), C.Shoe)
	box(ctx, "Pocket", U(0.55, 3.25, -0.61), Vector3.new(0.45, 0.45, 0.04), shirt:Lerp(C.NumberInk, 0.18))

	-- Arms: sleeves + skin forearms + round hands
	for i, side in { -1, 1 } do
		local ang = if ko then 70 elseif side == 1 then 10 else 14
		local pivot = U(side * 1.15, 3.7, 0) * CFrame.Angles(0, 0, math.rad(side * ang))
		box(ctx, `Sleeve{i}`, pivot * CFrame.new(side * 0.35, -0.45, 0), Vector3.new(0.78, 0.9, 0.78), shirt)
		box(ctx, `Arm{i}`, pivot * CFrame.new(side * 0.35, -1.25, 0), Vector3.new(0.62, 0.9, 0.62), C.SkinPale)
		ball(ctx, `Hand{i}`, pivot * CFrame.new(side * 0.35, -1.8, 0), 0.72, C.SkinPale)
	end

	-- Bald round head, ears, shine, blush
	local HY = 4.85
	blob(ctx, "Head", U(0, HY, 0), Vector3.new(2.0, 2.0, 1.9), C.SkinPale)
	for i, side in { -1, 1 } do
		blob(ctx, `Ear{i}`, U(side * 1.0, HY - 0.05, 0.1), Vector3.new(0.3, 0.55, 0.4), C.SkinPale)
		blob(ctx, `Blush{i}`, U(side * 0.62, HY - 0.42, -0.72) * CFrame.Angles(0, math.rad(side * 30), 0), Vector3.new(0.38, 0.2, 0.08), C.Blush)
	end
	blob(ctx, "Shine", U(-0.35, HY + 0.85, -0.3) * CFrame.Angles(math.rad(-20), 0, math.rad(15)), Vector3.new(0.45, 0.12, 0.28), C.EyeWhite, { transparency = 0.25 })

	-- Eyes: big, wall-eyed. Mouth: little "o" (shock) or flat KO line.
	eye(ctx, "EyeL", U(-0.42, HY + 0.15, -0.92), 0.85, Vector2.new(-0.6, 0.3))
	eye(ctx, "EyeR", U(0.42, HY + 0.15, -0.92), 0.85, Vector2.new(0.5, -0.4))
	if ko then
		box(ctx, "Mouth", U(0, HY - 0.55, -0.85) * CFrame.Angles(0, 0, math.rad(-10)), Vector3.new(0.4, 0.08, 0.08), C.NumberInk)
		blob(ctx, "Tongue", U(0.12, HY - 0.66, -0.86), Vector3.new(0.2, 0.22, 0.08), C.Tongue)
	else
		blob(ctx, "Mouth", U(0, HY - 0.55, -0.86), Vector3.new(0.26, 0.3, 0.1), C.NumberInk)
	end

	return { w = 3.2, h = 5.9 + up, d = 1.9, back = 0.95, head = Vector3.new(0, HY + 1.2 + up, 0) }
end

---------------------------------------------------------------------------- Dog
local function buildDog(ctx: Ctx, _opts: Opts): Dims
	-- Legs and paws
	for i, p in { Vector2.new(-0.5, -0.85), Vector2.new(0.5, -0.85), Vector2.new(-0.5, 0.85), Vector2.new(0.5, 0.85) } do
		box(ctx, `Leg{i}`, CFrame.new(p.X, 0.6, p.Y), Vector3.new(0.5, 1.0, 0.5), C.DogWhite)
		blob(ctx, `Paw{i}`, CFrame.new(p.X, 0.2, p.Y - 0.12), Vector3.new(0.62, 0.4, 0.75), C.DogWhite)
	end
	-- Body: orange with white belly and dark saddle (beagle)
	blob(ctx, "Body", CFrame.new(0, 1.7, 0.1), Vector3.new(1.8, 1.55, 2.9), C.DogOrange)
	blob(ctx, "Belly", CFrame.new(0, 1.42, -0.1), Vector3.new(1.55, 1.05, 2.5), C.DogWhite)
	blob(ctx, "Saddle", CFrame.new(0, 2.15, 0.35), Vector3.new(1.6, 0.8, 1.9), C.DogSaddle)
	blob(ctx, "Chest", CFrame.new(0, 1.8, -1.05), Vector3.new(1.3, 1.3, 0.9), C.DogWhite)
	-- Tail up, white tip, happy wag angle
	local tail = CFrame.new(0, 2.15, 1.45) * CFrame.Angles(math.rad(35), 0, math.rad(15))
	box(ctx, "Tail", tail * CFrame.new(0, 0.5, 0), Vector3.new(0.26, 1.1, 0.26), C.DogOrange)
	ball(ctx, "TailTip", tail * CFrame.new(0, 1.1, 0), 0.4, C.DogWhite)
	-- Collar with a gold tag
	ecyl(ctx, "Collar", CFrame.new(0, 2.35, -1.15) * CFrame.Angles(math.rad(-25), 0, 0), 0.22, 1.35, 1.2, C.TruckRed)
	ball(ctx, "Tag", CFrame.new(0, 2.0, -1.72), 0.32, C.HelmetShield)
	-- Head
	local H = CFrame.new(0, 2.95, -1.55)
	blob(ctx, "Head", H, Vector3.new(1.8, 1.55, 1.6), C.DogOrange)
	box(ctx, "Blaze", H * CFrame.new(0, 0.35, -0.72) * CFrame.Angles(math.rad(-30), 0, 0), Vector3.new(0.3, 0.75, 0.1), C.DogWhite)
	blob(ctx, "Muzzle", H * CFrame.new(0, -0.35, -0.75), Vector3.new(1.15, 0.8, 1.0), C.DogWhite)
	blob(ctx, "Nose", H * CFrame.new(0, -0.12, -1.25), Vector3.new(0.45, 0.32, 0.3), C.PandaBlack)
	box(ctx, "MouthLine", H * CFrame.new(0, -0.58, -1.18), Vector3.new(0.7, 0.07, 0.1), C.PandaBlack)
	-- Tongue flopping out the side
	blob(ctx, "Tongue", H * CFrame.new(0.22, -0.88, -1.12) * CFrame.Angles(math.rad(-15), 0, math.rad(-12)), Vector3.new(0.42, 0.75, 0.14), C.Tongue)
	-- Floppy ears
	for i, side in { -1, 1 } do
		blob(ctx, `Ear{i}`, H * CFrame.new(side * 0.95, -0.2, 0.05) * CFrame.Angles(math.rad(10), 0, math.rad(side * 18)), Vector3.new(0.28, 1.35, 0.85), C.DogSaddle)
	end
	-- Googly eyes, slightly cross-eyed
	eye(ctx, "EyeL", H * CFrame.new(-0.36, 0.45, -0.68), 0.72, Vector2.new(0.55, -0.2))
	eye(ctx, "EyeR", H * CFrame.new(0.36, 0.45, -0.68), 0.72, Vector2.new(-0.3, 0.5))
	return { w = 2.0, h = 4.0, d = 3.8, back = 1.0, head = (H * CFrame.new(0, 1.0, 0)).Position }
end

---------------------------------------------------------------------------- Cat
local function buildCat(ctx: Ctx, _opts: Opts): Dims
	-- Chunky sitting pear
	local LY, LH, LRX, LRZ = 1.05, 1.05, 1.35, 1.25
	blob(ctx, "Body", CFrame.new(0, LY, 0.1), Vector3.new(LRX * 2, LH * 2, LRZ * 2), C.CatOrange)
	blob(ctx, "Chest", CFrame.new(0, 2.0, -0.15), Vector3.new(2.0, 1.9, 1.8), C.CatOrange)
	blob(ctx, "BellyFluff", CFrame.new(0, 1.55, -0.85), Vector3.new(1.35, 1.9, 0.7), C.CatCream)
	-- Tabby stripes wrapping the back
	for i, y in { 0.75, 1.15, 1.55 } do
		local rx, rz = ellR(LRX, LY, LH, y), ellR(LRZ, LY, LH, y)
		ecyl(ctx, `Stripe{i}`, CFrame.new(0, y, 0.1 + 0.3), 0.18, rx * 2 + 0.08, (rz - 0.26) * 2, C.CatStripe)
	end
	-- Front legs and paws
	for i, side in { -1, 1 } do
		blob(ctx, `FrontLeg{i}`, CFrame.new(side * 0.48, 0.85, -0.95), Vector3.new(0.6, 1.5, 0.6), C.CatOrange)
		blob(ctx, `Paw{i}`, CFrame.new(side * 0.5, 0.2, -1.2), Vector3.new(0.65, 0.4, 0.8), C.CatCream)
		blob(ctx, `Haunch{i}`, CFrame.new(side * 1.05, 0.5, 0.0), Vector3.new(0.9, 1.0, 1.6), C.CatOrange)
	end
	-- Tail curled round the right side on the ground
	for i = 1, 6 do
		local a = math.rad(117 - i * 27) -- from behind, round the right flank to the front
		local pos = Vector3.new(math.cos(a) * 1.45, 0.25, 0.1 + math.sin(a) * 1.35)
		ball(ctx, `Tail{i}`, CFrame.new(pos), if i == 6 then 0.5 else 0.6, if i % 2 == 0 then C.CatStripe else C.CatOrange)
	end
	-- Head
	local H = CFrame.new(0, 3.35, -0.35)
	blob(ctx, "Head", H, Vector3.new(2.35, 1.85, 1.9), C.CatOrange)
	blob(ctx, "CheekL", H * CFrame.new(-0.75, -0.4, -0.35), Vector3.new(1.0, 0.8, 1.0), C.CatOrange)
	blob(ctx, "CheekR", H * CFrame.new(0.75, -0.4, -0.35), Vector3.new(1.0, 0.8, 1.0), C.CatOrange)
	blob(ctx, "Muzzle", H * CFrame.new(0, -0.38, -0.82), Vector3.new(1.05, 0.6, 0.55), C.CatCream)
	-- Forehead "M"
	for i, x in { -0.3, 0, 0.3 } do
		box(ctx, `Mark{i}`, H * CFrame.new(x, 0.62, -0.78) * CFrame.Angles(math.rad(-35), 0, 0), Vector3.new(0.12, 0.4, 0.08), C.CatStripe)
	end
	-- Ears (triangles with pink insides)
	for i, side in { -1, 1 } do
		local ear = H * CFrame.new(side * 0.72, 0.95, -0.05) * CFrame.Angles(0, 0, math.rad(-side * 18))
		triangle(ctx, `Ear{i}`, ear, 0.95, 0.85, 0.22, C.CatOrange)
		triangle(ctx, `EarIn{i}`, ear * CFrame.new(0, -0.08, -0.1), 0.55, 0.55, 0.06, C.CatPink)
	end
	-- Nose, whiskers
	blob(ctx, "Nose", H * CFrame.new(0, -0.18, -1.08), Vector3.new(0.3, 0.2, 0.15), C.CatPink)
	for i, side in { -1, 1 } do
		for j, a in { -12, 0, 12 } do
			box(ctx, `Whisker{i}{j}`, H * CFrame.new(side * 0.85, -0.4 + j * 0.04 - 0.08, -0.95) * CFrame.Angles(0, 0, math.rad(side * a)), Vector3.new(0.9, 0.04, 0.04), C.NumberInk)
		end
	end
	-- One huge eye, one tiny eye; pupils pointing different ways (the trailer drooling cat).
	eye(ctx, "EyeBig", H * CFrame.new(-0.42, 0.25, -0.85), 1.05, Vector2.new(-0.5, 0.4), 0.28)
	eye(ctx, "EyeSmall", H * CFrame.new(0.5, 0.18, -0.82), 0.62, Vector2.new(0.6, -0.6), 0.5)
	-- Tongue out + drool string + puddle
	blob(ctx, "Tongue", H * CFrame.new(-0.12, -0.72, -0.98) * CFrame.Angles(math.rad(-20), 0, math.rad(10)), Vector3.new(0.38, 0.55, 0.12), C.Tongue)
	if not ctx.ko then
		for i = 1, 4 do
			local d = 0.24 - i * 0.03
			ball(ctx, `Drool{i}`, H * CFrame.new(0.28, -0.85 - i * 0.32, -1.02 - i * 0.04), d, C.Drool, { transparency = 0.25 })
		end
		local drip = ball(ctx, "DroolDrip", H * CFrame.new(0.28, -2.25, -1.2), 0.2, C.Drool, { transparency = 0.2 })
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "Drip"
		pe.Rate = 2
		pe.Lifetime = NumberRange.new(0.5, 0.7)
		pe.Speed = NumberRange.new(0)
		pe.Acceleration = Vector3.new(0, -25, 0)
		pe.Size = NumberSequence.new(0.15 * ctx.s)
		pe.Color = ColorSequence.new(C.EyeWhite)
		pe.LightEmission = 0.4
		pe.Parent = drip
		ecyl(ctx, "DroolPuddle", CFrame.new(0.3, 0.03, -1.75), 0.05, 1.1, 0.85, C.Drool, { transparency = 0.3 })
	end
	return { w = 2.8, h = 4.4, d = 2.8, back = 1.4, head = (H * CFrame.new(0, 1.3, 0)).Position }
end

---------------------------------------------------------------------------- Panda
local function buildPanda(ctx: Ctx, _opts: Opts): Dims
	local BY, BH, BRX, BRZ = 1.65, 1.6, 1.8, 1.6
	blob(ctx, "Body", CFrame.new(0, BY, 0.1), Vector3.new(BRX * 2, BH * 2, BRZ * 2), C.PandaWhite)
	-- Black shoulder band
	local y = 2.7
	ecyl(ctx, "Shoulders", CFrame.new(0, y, 0.1), 0.75, ellR(BRX, BY, BH, y) * 2 + 0.12, ellR(BRZ, BY, BH, y) * 2 + 0.12, C.PandaBlack)
	-- Legs stuck out forward with toe beans
	for i, side in { -1, 1 } do
		blob(ctx, `Leg{i}`, CFrame.new(side * 1.05, 0.55, -1.15), Vector3.new(1.2, 1.05, 1.7), C.PandaBlack)
		blob(ctx, `Sole{i}`, CFrame.new(side * 1.05, 0.6, -1.98), Vector3.new(0.75, 0.75, 0.12), C.PawPad)
		for j, o in { -0.25, 0, 0.25 } do
			ball(ctx, `Bean{i}{j}`, CFrame.new(side * 1.05 + o, 1.02 - math.abs(o) * 0.4, -1.98), 0.2, C.PawPad)
		end
	end
	-- Arms hugging a bamboo stalk
	for i, side in { -1, 1 } do
		local pivot = CFrame.new(side * 1.45, 2.85, -0.3) * CFrame.Angles(math.rad(55), 0, math.rad(side * -20))
		blob(ctx, `Arm{i}`, pivot * CFrame.new(0, -0.7, 0), Vector3.new(0.95, 1.8, 0.95), C.PandaBlack)
	end
	local stalk = CFrame.new(0.15, 2.2, -1.75) * CFrame.Angles(math.rad(-12), 0, math.rad(-20))
	cyl(ctx, "Bamboo", stalk, 2.8, 0.32, C.Bamboo)
	for i, o in { -0.8, 0.1, 0.9 } do
		cyl(ctx, `BambooNode{i}`, stalk * CFrame.new(0, o, 0), 0.12, 0.38, C.BambooDark)
	end
	for i, a in { 35, -40 } do
		blob(ctx, `Leaf{i}`, stalk * CFrame.new(0, 1.3, 0) * CFrame.Angles(0, 0, math.rad(a)) * CFrame.new(0, 0.35, 0), Vector3.new(0.3, 0.8, 0.08), C.Bamboo)
	end
	-- Head
	local H = CFrame.new(0, 4.15, -0.25)
	blob(ctx, "Head", H, Vector3.new(3.0, 2.5, 2.6), C.PandaWhite)
	for i, side in { -1, 1 } do
		ball(ctx, `Ear{i}`, H * CFrame.new(side * 1.12, 1.05, 0.15), 0.95, C.PandaBlack)
		blob(ctx, `Patch{i}`, H * CFrame.new(side * 0.58, 0.12, -1.08) * CFrame.Angles(0, math.rad(side * 20), math.rad(side * 28)), Vector3.new(0.9, 1.25, 0.4), C.PandaBlack)
		blob(ctx, `Blush{i}`, H * CFrame.new(side * 0.95, -0.45, -0.95) * CFrame.Angles(0, math.rad(side * 35), 0), Vector3.new(0.42, 0.22, 0.08), C.Blush)
	end
	blob(ctx, "Snout", H * CFrame.new(0, -0.5, -1.15), Vector3.new(1.1, 0.75, 0.6), C.PandaWhite)
	blob(ctx, "Nose", H * CFrame.new(0, -0.3, -1.45), Vector3.new(0.5, 0.3, 0.25), C.PandaBlack)
	blob(ctx, "Tongue", H * CFrame.new(0.1, -0.85, -1.38) * CFrame.Angles(math.rad(-15), 0, 0), Vector3.new(0.38, 0.4, 0.12), C.Tongue)
	eye(ctx, "EyeL", H * CFrame.new(-0.52, 0.2, -1.32), 0.82, Vector2.new(0.4, 0.5))
	eye(ctx, "EyeR", H * CFrame.new(0.52, 0.2, -1.32), 0.82, Vector2.new(0.6, -0.3))
	return { w = 3.8, h = 5.7, d = 4.0, back = 1.8, head = (H * CFrame.new(0, 1.5, 0)).Position }
end

local Builders: { [string]: (Ctx, Opts) -> Dims } = {
	Firefighter = buildFirefighter,
	Civilian = buildCivilian,
	Dog = buildDog,
	Cat = buildCat,
	Panda = buildPanda,
}

-- Uniform scale per kind (keeps hand-tuned numbers readable).
local Scale = { Firefighter = 0.9, Civilian = 0.9, Dog = 0.85, Cat = 0.8, Panda = 1.0 }

-- Pre-measured standing heights (unscaled) for the lying-pose offset.
local Height = { Firefighter = 6.5, Civilian = 5.9, Dog = 4.0, Cat = 4.4, Panda = 5.7 }
local Back = { Firefighter = 2.35, Civilian = 0.95, Dog = 1.0, Cat = 1.4, Panda = 2.0 }
local IsPet = { Dog = true, Cat = true, Panda = true }

function NpcBuilder.Build(kind: string, cf: CFrame, opts: Opts?): Model
	local o = opts or {} :: Opts
	local builder = Builders[kind]
	assert(builder, `NpcBuilder: unknown kind {kind}`)
	local pose = o.pose or "stand"
	local s = Scale[kind] or 1
	local ko = pose == "lying"

	local base = cf
	if ko then
		if IsPet[kind] then
			-- flopped on its side (paws toward +X), centred on cf
			base = cf * CFrame.new(0, Back[kind] * s, 0) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.new(0, -Height[kind] * s / 2, 0)
		else
			-- on the back, face up, centred on cf
			base = cf * CFrame.new(0, Back[kind] * s, -Height[kind] * s / 2) * CFrame.Angles(math.rad(90), 0, 0)
		end
	end

	local m = Instance.new("Model")
	m.Name = kind
	local ctx: Ctx = { m = m, base = base, s = s, ko = ko }
	local dims = builder(ctx, o)

	if ko then
		dizzy(ctx, (base * CFrame.new(dims.head * s)).Position + Vector3.new(0, 0.9 * s, 0))
	end

	-- Root: invisible box around the body, pivot on the ground point.
	local w, h, d = dims.w * s, dims.h * s, dims.d * s
	local rootSize, rootCf
	if ko and not IsPet[kind] then
		rootSize = Vector3.new(w, Back[kind] * s * 2, h)
		rootCf = cf * CFrame.new(0, Back[kind] * s, 0)
	elseif ko then
		rootSize = Vector3.new(h, w, d)
		rootCf = cf * CFrame.new(0, w / 2, 0)
	else
		rootSize = Vector3.new(w, h, d)
		rootCf = cf * CFrame.new(0, h / 2, 0)
	end
	local root = MapKit.part(m, "Root", rootCf, rootSize, { transparency = 1, collide = false })
	root.CanTouch = false
	root.CanQuery = true
	root.PivotOffset = rootCf:ToObjectSpace(cf)
	m.PrimaryPart = root

	m:SetAttribute(Names.Attr.Kind, kind)
	m:SetAttribute("Pose", pose)
	if kind == "Firefighter" then
		m:SetAttribute(Names.Attr.Helmet, math.floor(o.helmet or 1))
	end
	return m
end

return NpcBuilder
