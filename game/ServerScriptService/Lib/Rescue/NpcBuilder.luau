--!strict
-- NpcBuilder: part-built display models for the cast (docs/game/02 §3, docs/game/05 §4).
-- NpcBuilder.Build(kind, cf, opts) -> Model (unparented; caller parents it).
--   kind = any entry of NpcBuilder.Kinds (case-insensitive; "floatguy" works too).
--   cf   = ground point under the character; the character faces -Z of cf.
--   opts = { helmet: number? (firefighter badge, default 1), color: Color3? (civilian shirt),
--            pose: "stand" | "lying" | "sitting" | "waving" | "panicking"?,
--            sooty: boolean? (burnt black, white eyes, smoke wisps; works for every kind) }
-- NpcBuilder.Lineup(parent, cf, opts?) -> Model: every kind in a row (+ a pose row) for previews.
-- Everything is Anchored and CanCollide=false. PrimaryPart "Root" is an invisible box around the
-- body whose PivotOffset puts the model pivot on the ground point, so Model:PivotTo(groundCf) works.
-- Attributes: Kind (= kind), Pose, Sooty (when sooty), and Helmet for firefighters.
-- Poses: "lying" = knocked out (on the back for people, on the side for animals) with X eyes and
-- dizzy stars. "sitting" = on the ground, legs forward. "waving" = both arms up (window rescue).
-- "panicking" = arms up, mouth wide open, "!" and sweat drops. Cat and panda always sit.
-- Kind "Sooty" = a sooty civilian sitting (the late-rescue state, docs/game/05 t=33).
-- The trailer cast beyond the original five lives in NpcVariants.luau (same helpers, same style).
-- No randomness: identical inputs give identical models.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local MapKit = require(script.Parent.Parent:WaitForChild("Map"):WaitForChild("MapKit") :: ModuleScript)

local NpcBuilder = {}

NpcBuilder.Kinds = {
	"Firefighter",
	"Civilian",
	"Dog",
	"Cat",
	"Panda",
	"Farmer",
	"Grandma",
	"Kid",
	"FloatGuy",
	"RainbowGuy",
	"Teacher",
	"Hiker",
	"Duck",
	"Duckling",
	"Chicken",
	"Deer",
	"Raccoon",
	"Sooty",
}

NpcBuilder.Poses = { "stand", "lying", "sitting", "waving", "panicking" }

export type Opts = {
	helmet: number?,
	color: Color3?,
	pose: string?,
	sooty: boolean?,
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
	ShieldRim = hex("#B8902A"),
	NumberInk = hex("#1A1210"),
	SkinWarm = hex("#D98A4E"),
	SkinPale = hex("#F0C49C"),
	Blush = hex("#F29A8A"),
	EyeWhite = hex("#FFFFFF"),
	Pupil = hex("#111111"),
	CivTeeWhite = hex("#F2EEE6"),
	CivShirtRed = hex("#CF442B"),
	Jeans = hex("#56688A"),
	Shoe = hex("#3A2E2A"),
	Boot = hex("#2B2522"),
	Chrome = hex("#D6D8DC"),
	TruckRed = hex("#C8232B"),
	Soot = hex("#2A2826"),
	Charred = hex("#1F1A19"),
	CharredWarm = hex("#3A2A22"),
	SmokeGrey = hex("#5E5A55"),
	SmokeWhite = hex("#EAE6DF"),
	Ember = hex("#FF5A1F"),
	FireBody = hex("#FFB12B"),
	Tongue = hex("#E26A7A"),
	MouthIn = hex("#5A1A1E"),
	Teeth = hex("#FFFDF5"),
	Sweat = hex("#A9E3F0"),
	Alert = hex("#FF3B30"),
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

-- Helmet stripe colour per crew number (docs/game/05 §5): 01 yellow, 02 orange, 03 white, 04 blue.
local HelmetStripe = {
	[1] = hex("#F2D04A"),
	[2] = hex("#F08A2A"),
	[3] = hex("#F4F1EA"),
	[4] = hex("#3A7BD5"),
}

type Ctx = {
	m: Model,
	base: CFrame,
	s: number,
	ko: boolean,
	pose: string,
	keep: { [Instance]: boolean }, -- parts that stay coloured when sooty (eye whites, highlights)
	lieBack: number, -- when lying on the back: local z of the ground plane (props can rest on it)
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
local function cyl(ctx: Ctx, name: string, lcf: CFrame, len: number, d: number, color: Color3, x: Extra?): Part
	local e = x or {} :: Extra
	local p = MapKit.part(ctx.m, name, W(ctx, lcf * CFrame.Angles(0, 0, math.pi / 2)), Vector3.new(len, d, d) * ctx.s, {
		color = color,
		shape = Enum.PartType.Cylinder,
		collide = false,
		neon = e.neon,
		transparency = e.transparency,
	})
	finish(p)
	return p
end

-- Round disc facing -Z (axis along the local Z of lcf), e.g. glasses rims.
local function zcyl(ctx: Ctx, name: string, lcf: CFrame, len: number, d: number, color: Color3, x: Extra?): Part
	return cyl(ctx, name, lcf * CFrame.Angles(math.pi / 2, 0, 0), len, d, color, x)
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
-- Panicking shrinks the pupils (pinprick terror) unless pupilScale is given.
local function eye(ctx: Ctx, name: string, lcf: CFrame, d: number, look: Vector2, pupilScale: number?)
	ctx.keep[ball(ctx, name, lcf, d, C.EyeWhite)] = true
	if ctx.ko then
		for i, a in { 45, -45 } do
			box(ctx, `{name}X{i}`, lcf * CFrame.new(0, 0, -d * 0.47) * CFrame.Angles(0, 0, math.rad(a)), Vector3.new(d * 0.72, d * 0.14, 0.08), C.Pupil)
		end
	else
		local ps = pupilScale or (if ctx.pose == "panicking" then 0.26 else 0.42)
		local off = Vector3.new(look.X * d * 0.2, look.Y * d * 0.2, -d * (0.5 - ps / 2) - d * 0.02)
		ball(ctx, name .. "Pupil", lcf * CFrame.new(off), d * ps, C.Pupil)
		-- tiny highlight so the eyes read glossy
		ctx.keep[ball(ctx, name .. "Shine", lcf * CFrame.new(off + Vector3.new(d * 0.08, d * 0.09, -d * ps * 0.32)), d * 0.1, C.EyeWhite, { neon = true })] = true
	end
end

-- Mouth centred at lcf (on the face surface, facing -Z); w = base width. Shape follows the pose:
-- KO flat line + tongue, panicking big screaming "O", waving open grin, otherwise style
-- ("o" small shocked o, "smile" closed smile, "grin" open grin with teeth).
local function mouth(ctx: Ctx, name: string, lcf: CFrame, w: number, style: string?)
	local pose = ctx.pose
	local st = style or "o"
	if ctx.ko then
		box(ctx, name, lcf * CFrame.Angles(0, 0, math.rad(-9)), Vector3.new(w * 1.5, 0.08, 0.08), C.NumberInk)
		blob(ctx, name .. "Tongue", lcf * CFrame.new(w * 0.35, -w * 0.38, 0), Vector3.new(w * 0.7, w * 0.8, 0.08), C.Tongue)
	elseif pose == "panicking" then
		blob(ctx, name, lcf * CFrame.new(0, -w * 0.25, 0), Vector3.new(w * 1.5, w * 2.1, 0.14), C.MouthIn)
		blob(ctx, name .. "Tongue", lcf * CFrame.new(0, -w * 0.95, -0.03), Vector3.new(w * 0.95, w * 0.5, 0.1), C.Tongue)
		box(ctx, name .. "Teeth", lcf * CFrame.new(0, w * 0.6, -0.04), Vector3.new(w * 0.8, w * 0.22, 0.06), C.Teeth)
	elseif pose == "waving" or st == "grin" then
		blob(ctx, name, lcf * CFrame.new(0, -w * 0.12, 0), Vector3.new(w * 1.9, w * 1.0, 0.12), C.MouthIn)
		box(ctx, name .. "Teeth", lcf * CFrame.new(0, w * 0.24, -0.04), Vector3.new(w * 1.3, w * 0.24, 0.06), C.Teeth)
		blob(ctx, name .. "Tongue", lcf * CFrame.new(0, -w * 0.38, -0.03), Vector3.new(w * 0.8, w * 0.36, 0.08), C.Tongue)
	elseif st == "smile" then
		for i, side in { -1, 0, 1 } do
			box(ctx, `{name}{i}`, lcf * CFrame.new(side * w * 0.42, math.abs(side) * w * 0.12, 0) * CFrame.Angles(0, 0, math.rad(side * 28)), Vector3.new(w * 0.5, 0.09, 0.08), C.NumberInk)
		end
	else
		blob(ctx, name, lcf, Vector3.new(w, w * 1.15, 0.1), C.NumberInk)
	end
end

-- Shoulder angles (degrees out from hanging, left/right) for the pose; stand values per kind.
local function armAngles(pose: string, standL: number, standR: number): (number, number)
	if pose == "lying" then
		return 72, 72
	elseif pose == "waving" then
		return 158, 146
	elseif pose == "panicking" then
		return 140, 166
	end
	return standL, standR
end

-- Pose extras around a person/animal: "!" + sweat for panicking, motion arcs for waving.
-- headTop = local point just above the head; hands = local hand CFrames (for wave arcs).
local function poseFx(ctx: Ctx, headTop: Vector3, hands: { CFrame }?)
	if ctx.pose == "panicking" then
		local p = CFrame.new(headTop + Vector3.new(0.15, 0.9, 0)) * CFrame.Angles(0, 0, math.rad(-8))
		box(ctx, "AlertBar", p * CFrame.new(0, 0.35, 0), Vector3.new(0.28, 0.8, 0.2), C.Alert, { neon = true })
		ball(ctx, "AlertDot", p * CFrame.new(0, -0.32, 0), 0.3, C.Alert, { neon = true })
		for i, side in { -1, 1 } do
			local d = CFrame.new(headTop + Vector3.new(side * 1.25, -0.65 - i * 0.15, -0.2)) * CFrame.Angles(0, 0, math.rad(side * 20))
			blob(ctx, `Sweat{i}`, d, Vector3.new(0.24, 0.38, 0.22), C.Sweat)
			ball(ctx, `SweatTip{i}`, d * CFrame.new(0, 0.16, 0), 0.12, C.Sweat)
		end
	elseif ctx.pose == "waving" and hands then
		for i, h in hands do
			local side = if i == 1 then -1 else 1
			for j = 1, 2 do
				local arc = CFrame.new(h.Position + Vector3.new(side * (0.55 + j * 0.28), 0.1, 0)) * CFrame.Angles(0, 0, math.rad(side * -12))
				box(ctx, `WaveLine{i}{j}`, arc, Vector3.new(0.08, 0.35 + j * 0.15, 0.08), C.EyeWhite)
			end
		end
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

-- Seven-segment digits built from parts (never blank, unlike a tiny SurfaceGui), centred at lcf on
-- a plate whose front is -Z. cell = digit height; ink stands `lift` proud of the plate.
local SEG: { [string]: string } = {
	["0"] = "abcdef",
	["1"] = "bc",
	["2"] = "abged",
	["3"] = "abgcd",
	["4"] = "fgbc",
	["5"] = "afgcd",
	["6"] = "afgedc",
	["7"] = "abc",
	["8"] = "abcdefg",
	["9"] = "abcdfg",
}
local function digits(ctx: Ctx, name: string, lcf: CFrame, text: string, h: number, color: Color3)
	local w = h * 0.6
	local t = h * 0.2
	local gap = h * 0.22
	local n = #text
	local total = n * w + (n - 1) * gap
	for i = 1, n do
		local ch = string.sub(text, i, i)
		local segs = SEG[ch]
		if segs then
			local cx = -total / 2 + (i - 1) * (w + gap) + w / 2
			if ch == "1" then
				cx -= w / 2 - t / 2 -- centre the lone stroke in its cell
			end
			local hw, hh = w / 2 - t / 2, h / 2 - t / 2
			local spots: { [string]: { Vector3 } } = {
				a = { Vector3.new(0, hh, 0), Vector3.new(w, t, 1) },
				g = { Vector3.new(0, 0, 0), Vector3.new(w, t, 1) },
				d = { Vector3.new(0, -hh, 0), Vector3.new(w, t, 1) },
				f = { Vector3.new(-hw, hh / 2, 0), Vector3.new(t, hh + t, 1) },
				b = { Vector3.new(hw, hh / 2, 0), Vector3.new(t, hh + t, 1) },
				e = { Vector3.new(-hw, -hh / 2, 0), Vector3.new(t, hh + t, 1) },
				c = { Vector3.new(hw, -hh / 2, 0), Vector3.new(t, hh + t, 1) },
			}
			if ch == "1" then
				spots.b = { Vector3.new(hw, 0, 0), Vector3.new(t, h, 1) }
				spots.c = nil
				-- little flag at the top so it reads as a 1, not an l
				box(ctx, `{name}{i}Flag`, lcf * CFrame.new(cx + hw - t * 0.9, hh - t * 0.1, 0) * CFrame.Angles(0, 0, math.rad(35)), Vector3.new(t * 1.6, t * 0.9, 0.06), color)
			end
			for j = 1, #segs do
				local key = string.sub(segs, j, j)
				local sp = spots[key]
				if sp then
					box(ctx, `{name}{i}{key}`, lcf * CFrame.new(cx + sp[1].X, sp[1].Y, 0), Vector3.new(sp[2].X, sp[2].Y, 0.06), color)
				end
			end
		end
	end
end

-- Dims: { w, h, d } unscaled; back = how far the back sticks out (+Z) for lying lift.
type Dims = { w: number, h: number, d: number, back: number, head: Vector3 }

---------------------------------------------------------------------------- Firefighter
local function buildFirefighter(ctx: Ctx, opts: Opts): Dims
	local num = math.clamp(math.floor(opts.helmet or 1), 0, 99)
	local ko = ctx.ko
	local pose = ctx.pose
	local sitting = pose == "sitting"
	local up = if sitting then -1.25 else 0
	local B = CFrame.new(0, up, 0) -- upper body (drops when sitting)

	-- Boots and legs
	for i, side in { -1, 1 } do
		local x = side * 0.62
		if sitting then
			box(ctx, `Leg{i}`, CFrame.new(x, 0.48, -0.85), Vector3.new(0.95, 0.95, 1.7), C.CoatShadow)
			box(ctx, `ShinBandA{i}`, CFrame.new(x, 0.48, -1.2), Vector3.new(1.0, 1.0, 0.13), C.ReflectLime)
			box(ctx, `ShinBandB{i}`, CFrame.new(x, 0.48, -1.32), Vector3.new(1.0, 1.0, 0.11), C.ReflectSilver)
			box(ctx, `ShinBandC{i}`, CFrame.new(x, 0.48, -1.44), Vector3.new(1.0, 1.0, 0.13), C.ReflectLime)
			box(ctx, `Boot{i}`, CFrame.new(x, 0.6, -1.95), Vector3.new(1.05, 1.2, 0.7), C.Boot)
			blob(ctx, `BootToe{i}`, CFrame.new(x, 1.0, -2.2), Vector3.new(1.05, 0.8, 0.6), C.Boot)
		else
			box(ctx, `Boot{i}`, CFrame.new(x, 0.35, -0.05), Vector3.new(1.05, 0.7, 1.3), C.Boot)
			blob(ctx, `BootToe{i}`, CFrame.new(x, 0.32, -0.62), Vector3.new(1.05, 0.64, 0.9), C.Boot)
			box(ctx, `BootCuff{i}`, CFrame.new(x, 0.72, -0.05), Vector3.new(1.12, 0.14, 1.12), C.ReflectLime)
			box(ctx, `Leg{i}`, CFrame.new(x, 1.25, 0), Vector3.new(0.95, 1.1, 0.95), C.CoatShadow)
			box(ctx, `ShinBandA{i}`, CFrame.new(x, 1.0, 0), Vector3.new(1.0, 0.13, 1.0), C.ReflectLime)
			box(ctx, `ShinBandB{i}`, CFrame.new(x, 1.12, 0), Vector3.new(1.0, 0.11, 1.0), C.ReflectSilver)
			box(ctx, `ShinBandC{i}`, CFrame.new(x, 1.24, 0), Vector3.new(1.0, 0.13, 1.0), C.ReflectLime)
		end
	end

	-- Bean body: coat ellipsoid + skin top, one blob, no neck.
	local BY, BH, BRX, BRZ = 3.1, 1.8, 1.55, 1.35
	blob(ctx, "Body", B * CFrame.new(0, BY, 0), Vector3.new(BRX * 2, BH * 2, BRZ * 2), C.CoatYellow)
	blob(ctx, "CoatHem", B * CFrame.new(0, 1.95, 0.02), Vector3.new(2.9, 1.3, 2.55), C.CoatShadow)
	local function bodyBand(y: number)
		return ellR(BRX, BY, BH, y) * 2 + 0.1, ellR(BRZ, BY, BH, y) * 2 + 0.1
	end
	local dx, dz = bodyBand(2.65)
	band3(ctx, "ChestBand", B * CFrame.new(0, 2.65, 0), dx, dz)
	-- Coat closure toggles down the front
	for i, y in { 3.35, 3.0, 2.15 } do
		local z = -ellR(BRZ, BY, BH, y)
		box(ctx, `Toggle{i}`, B * CFrame.new(0, y, z - 0.02), Vector3.new(0.38, 0.14, 0.14), C.Boot)
	end
	-- Head (skin) rising out of the coat
	local HY, HH, HRX, HRZ = 4.5, 1.1, 1.35, 1.22
	blob(ctx, "Head", B * CFrame.new(0, HY, 0), Vector3.new(HRX * 2, HH * 2, HRZ * 2), C.SkinWarm)
	local cy = 3.8
	ecyl(ctx, "Collar", B * CFrame.new(0, cy, 0), 0.32, 3.0, 2.64, C.CoatYellow)
	ecyl(ctx, "CollarLine", B * CFrame.new(0, cy - 0.17, 0), 0.06, 3.04, 2.68, C.CoatShadow)
	-- Face: mouth (pose-driven), soot smudge
	local mz = -ellR(HRZ, HY, HH, 4.05)
	if ko or pose == "panicking" or pose == "waving" then
		mouth(ctx, "Mouth", B * CFrame.new(0.05, 4.07, mz - 0.03), 0.3)
	else
		blob(ctx, "Mouth", B * CFrame.new(0.05, 4.07, mz - 0.01), Vector3.new(0.28, 0.24, 0.12), C.NumberInk)
	end
	blob(ctx, "Soot", B * CFrame.new(0.82, 4.15, -ellR(HRZ, HY, HH, 4.15) * 0.72) * CFrame.Angles(0, math.rad(-40), math.rad(20)), Vector3.new(0.5, 0.26, 0.1), C.Soot)

	-- Googly eyes (MapKit), one pupil drifting outward for the derp look.
	local eyeY, eyeZ, eyeD = 4.62, -1.2, 1.15
	if ko or pose == "panicking" then
		eye(ctx, "EyeL", B * CFrame.new(-0.6, eyeY, eyeZ), eyeD, Vector2.new(-0.3, 0.6))
		eye(ctx, "EyeR", B * CFrame.new(0.6, eyeY, eyeZ), eyeD, Vector2.new(0.4, 0.5))
	else
		local folder = Instance.new("Model")
		folder.Name = "Eyes"
		folder.Parent = ctx.m
		MapKit.googlyEyes(folder, W(ctx, B * CFrame.new(0, eyeY, eyeZ)), eyeD * ctx.s, 0.6 * ctx.s)
		for _, c in folder:GetChildren() do
			if c:IsA("BasePart") then
				finish(c)
				if string.sub(c.Name, 1, 3) == "Eye" then
					ctx.keep[c] = true
				end
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

	-- Helmet: dome, crew-colour stripe, rear-heavy brim, comb ridge, gold front shield + number.
	local DY = 5.45
	ecyl(ctx, "Brim", B * CFrame.new(0, 5.22, 0.3), 0.2, 3.5, 4.1, C.HelmetDark)
	blob(ctx, "HelmetDome", B * CFrame.new(0, DY, 0.05), Vector3.new(2.9, 2.0, 3.05), C.HelmetRed)
	local sy = DY + 0.32
	ecyl(ctx, "HelmetStripe", B * CFrame.new(0, sy, 0.05), 0.18, ellR(1.45, DY, 1.0, sy) * 2 + 0.06, ellR(1.525, DY, 1.0, sy) * 2 + 0.06, HelmetStripe[num] or HelmetStripe[1])
	blob(ctx, "HelmetComb", B * CFrame.new(0, DY + 0.82, 0.15), Vector3.new(0.4, 0.5, 2.7), C.HelmetDark)
	box(ctx, "ShieldHolder", B * CFrame.new(0, DY + 0.72, -1.25) * CFrame.Angles(math.rad(25), 0, 0), Vector3.new(0.32, 0.4, 0.22), C.Chrome)
	-- Badge plate stands clear of the dome, above the brim and the eyes, tilted up to the camera.
	local shieldCf = B * CFrame.new(0, DY + 0.28, -1.62) * CFrame.Angles(math.rad(14), 0, 0)
	box(ctx, "ShieldRim", shieldCf * CFrame.new(0, 0, 0.05), Vector3.new(1.42, 1.12, 0.12), C.ShieldRim)
	blob(ctx, "ShieldArch", shieldCf * CFrame.new(0, 0.55, 0.05), Vector3.new(1.42, 0.5, 0.12), C.ShieldRim)
	local shield = box(ctx, "Shield", shieldCf, Vector3.new(1.28, 1.0, 0.14), C.HelmetShield)
	blob(ctx, "ShieldTop", shieldCf * CFrame.new(0, 0.5, 0), Vector3.new(1.28, 0.4, 0.14), C.HelmetShield)
	digits(ctx, "Num", shieldCf * CFrame.new(0, -0.02, -0.09), string.format("%02d", num), 0.72, C.NumberInk)
	shield:SetAttribute("Number", string.format("%02d", num))

	-- Arms: stand = left hangs, right waves; other poses from armAngles (KO flops out).
	local angL, angR = armAngles(pose, 18, 150)
	local hands: { CFrame } = {}
	for i, side in { -1, 1 } do
		local ang = if side == 1 then angR else angL
		local pivot = B * CFrame.new(side * 1.5, 3.75, 0) * CFrame.Angles(0, 0, math.rad(side * ang))
		box(ctx, `Arm{i}`, pivot * CFrame.new(0, -0.8, 0), Vector3.new(0.82, 1.6, 0.82), C.CoatYellow)
		box(ctx, `CuffA{i}`, pivot * CFrame.new(0, -1.25, 0), Vector3.new(0.88, 0.12, 0.88), C.ReflectLime)
		box(ctx, `CuffB{i}`, pivot * CFrame.new(0, -1.36, 0), Vector3.new(0.88, 0.1, 0.88), C.ReflectSilver)
		box(ctx, `CuffC{i}`, pivot * CFrame.new(0, -1.47, 0), Vector3.new(0.88, 0.12, 0.88), C.ReflectLime)
		blob(ctx, `Glove{i}`, pivot * CFrame.new(0, -1.9, 0), Vector3.new(1.0, 0.95, 0.9), C.GloveOlive)
		blob(ctx, `Thumb{i}`, pivot * CFrame.new(-side * 0.45, -1.75, -0.2), Vector3.new(0.35, 0.5, 0.35), C.GloveOlive)
		hands[i] = pivot * CFrame.new(0, -1.9, 0)
		box(ctx, `Strap{i}`, B * CFrame.new(side * 0.75, 3.35, -ellR(BRZ, BY, BH, 3.35) - 0.02) * CFrame.Angles(0, 0, math.rad(-side * 8)), Vector3.new(0.28, 1.4, 0.1), C.Soot)
	end
	if pose == "stand" then
		box(ctx, "SootSleeve", B * CFrame.new(-1.5, 3.75, 0) * CFrame.Angles(0, 0, math.rad(-18)) * CFrame.new(0, -0.55, -0.42), Vector3.new(0.45, 0.35, 0.04), C.Soot)
	end

	-- Air tank on the back
	local tz = ellR(BRZ, BY, BH, 3.2) + 0.45
	cyl(ctx, "Tank", B * CFrame.new(0, 3.2, tz), 2.1, 0.95, C.Chrome)
	ball(ctx, "TankTop", B * CFrame.new(0, 4.25, tz), 0.95, C.Chrome)
	ball(ctx, "TankBottom", B * CFrame.new(0, 2.15, tz), 0.95, C.Chrome)
	cyl(ctx, "TankBand", B * CFrame.new(0, 3.2, tz), 0.35, 1.0, C.TruckRed)
	box(ctx, "TankValve", B * CFrame.new(0, 4.82, tz), Vector3.new(0.3, 0.3, 0.3), C.Boot)
	box(ctx, "Harness", B * CFrame.new(0, 3.2, tz - 0.4), Vector3.new(1.4, 0.25, 0.3), C.Soot)

	poseFx(ctx, Vector3.new(0, 6.5 + up, 0), hands)
	return { w = 3.6, h = 6.5 + up, d = if sitting then 4.4 else 3.3, back = tz + 0.5, head = Vector3.new(0, 6.6 + up, 0) }
end

---------------------------------------------------------------------------- Civilian
local function buildCivilian(ctx: Ctx, opts: Opts): Dims
	local shirt = opts.color or C.CivTeeWhite
	local ko = ctx.ko
	local sitting = ctx.pose == "sitting"
	local up = if sitting then -1.1 else 0 -- upper-body drop when sitting on the ground

	for i, side in { -1, 1 } do
		local x = side * 0.5
		if sitting then
			box(ctx, `Leg{i}`, CFrame.new(x, 0.43, -0.75), Vector3.new(0.85, 0.85, 1.7), C.Jeans)
			box(ctx, `Shoe{i}`, CFrame.new(x, 0.62, -1.8), Vector3.new(0.9, 1.2, 0.45), C.Shoe)
		else
			local spread = if ko then side * 12 elseif ctx.pose == "panicking" then side * 8 else 0
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
	local angL, angR = armAngles(ctx.pose, 14, 10)
	local hands: { CFrame } = {}
	for i, side in { -1, 1 } do
		local ang = if side == 1 then angR else angL
		local pivot = U(side * 1.15, 3.7, 0) * CFrame.Angles(0, 0, math.rad(side * ang))
		box(ctx, `Sleeve{i}`, pivot * CFrame.new(side * 0.35, -0.45, 0), Vector3.new(0.78, 0.9, 0.78), shirt)
		box(ctx, `Arm{i}`, pivot * CFrame.new(side * 0.35, -1.25, 0), Vector3.new(0.62, 0.9, 0.62), C.SkinPale)
		ball(ctx, `Hand{i}`, pivot * CFrame.new(side * 0.35, -1.8, 0), 0.72, C.SkinPale)
		hands[i] = pivot * CFrame.new(side * 0.35, -1.8, 0)
	end

	-- Bald round head, ears, shine, blush
	local HY = 4.85
	blob(ctx, "Head", U(0, HY, 0), Vector3.new(2.0, 2.0, 1.9), C.SkinPale)
	for i, side in { -1, 1 } do
		blob(ctx, `Ear{i}`, U(side * 1.0, HY - 0.05, 0.1), Vector3.new(0.3, 0.55, 0.4), C.SkinPale)
		blob(ctx, `Blush{i}`, U(side * 0.62, HY - 0.42, -0.72) * CFrame.Angles(0, math.rad(side * 30), 0), Vector3.new(0.38, 0.2, 0.08), C.Blush)
	end
	blob(ctx, "Shine", U(-0.35, HY + 0.85, -0.3) * CFrame.Angles(math.rad(-20), 0, math.rad(15)), Vector3.new(0.45, 0.12, 0.28), C.EyeWhite, { transparency = 0.25 })

	-- Eyes: big, wall-eyed. Mouth: little "o" (shock), KO line, screaming or grinning by pose.
	eye(ctx, "EyeL", U(-0.42, HY + 0.15, -0.92), 0.85, Vector2.new(-0.6, 0.3))
	eye(ctx, "EyeR", U(0.42, HY + 0.15, -0.92), 0.85, Vector2.new(0.5, -0.4))
	if ko then
		box(ctx, "Mouth", U(0, HY - 0.55, -0.85) * CFrame.Angles(0, 0, math.rad(-10)), Vector3.new(0.4, 0.08, 0.08), C.NumberInk)
		blob(ctx, "Tongue", U(0.12, HY - 0.66, -0.86), Vector3.new(0.2, 0.22, 0.08), C.Tongue)
	elseif ctx.pose == "panicking" or ctx.pose == "waving" then
		mouth(ctx, "Mouth", U(0, HY - 0.55, -0.88), 0.28)
	else
		blob(ctx, "Mouth", U(0, HY - 0.55, -0.86), Vector3.new(0.26, 0.3, 0.1), C.NumberInk)
	end
	poseFx(ctx, Vector3.new(0, HY + 1.0 + up, 0), hands)

	return { w = 3.2, h = 5.9 + up, d = if sitting then 2.2 else 1.9, back = 0.95, head = Vector3.new(0, HY + 1.2 + up, 0) }
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
	poseFx(ctx, (H * CFrame.new(0, 0.6, 0)).Position, nil)
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
	poseFx(ctx, (H * CFrame.new(0, 0.9, 0)).Position, nil)
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
	-- Arms: hugging a bamboo stalk, or thrown up when waving/panicking
	local armsUp = ctx.pose == "waving" or ctx.pose == "panicking"
	for i, side in { -1, 1 } do
		local pivot = if armsUp
			then CFrame.new(side * 1.45, 2.85, -0.1) * CFrame.Angles(0, 0, math.rad(side * (if side == 1 then 150 else 140)))
			else CFrame.new(side * 1.45, 2.85, -0.3) * CFrame.Angles(math.rad(55), 0, math.rad(side * -20))
		blob(ctx, `Arm{i}`, pivot * CFrame.new(0, -0.7, 0), Vector3.new(0.95, 1.8, 0.95), C.PandaBlack)
	end
	if not armsUp then
		local stalk = CFrame.new(0.15, 2.2, -1.75) * CFrame.Angles(math.rad(-12), 0, math.rad(-20))
		cyl(ctx, "Bamboo", stalk, 2.8, 0.32, C.Bamboo)
		for i, o in { -0.8, 0.1, 0.9 } do
			cyl(ctx, `BambooNode{i}`, stalk * CFrame.new(0, o, 0), 0.12, 0.38, C.BambooDark)
		end
		for i, a in { 35, -40 } do
			blob(ctx, `Leaf{i}`, stalk * CFrame.new(0, 1.3, 0) * CFrame.Angles(0, 0, math.rad(a)) * CFrame.new(0, 0.35, 0), Vector3.new(0.3, 0.8, 0.08), C.Bamboo)
		end
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
	poseFx(ctx, (H * CFrame.new(0, 1.2, 0)).Position, nil)
	return { w = 3.8, h = 5.7, d = 4.0, back = 1.8, head = (H * CFrame.new(0, 1.5, 0)).Position }
end

---------------------------------------------------------------------------- Registry
-- height = standing height and back = lying lift (both unscaled, used before the build);
-- pet = lies on its side when KO; sits = always sitting (ignores "sitting"/"stand").
export type Def = {
	build: (Ctx, Opts) -> Dims,
	scale: number,
	height: number,
	back: number,
	pet: boolean?,
}

local Defs: { [string]: Def } = {
	Firefighter = { build = buildFirefighter, scale = 0.9, height = 6.5, back = 2.35 },
	Civilian = { build = buildCivilian, scale = 0.9, height = 5.9, back = 0.95 },
	Dog = { build = buildDog, scale = 0.85, height = 4.0, back = 1.0, pet = true },
	Cat = { build = buildCat, scale = 0.8, height = 4.4, back = 1.4, pet = true },
	Panda = { build = buildPanda, scale = 1.0, height = 5.7, back = 2.0, pet = true },
}

-- Helper kit shared with NpcVariants (internal; not a public API).
NpcBuilder._kit = {
	C = C,
	hex = hex,
	box = box,
	ball = ball,
	blob = blob,
	ecyl = ecyl,
	cyl = cyl,
	zcyl = zcyl,
	wedge = wedge,
	triangle = triangle,
	eye = eye,
	mouth = mouth,
	armAngles = armAngles,
	poseFx = poseFx,
	ellR = ellR,
	finish = finish,
	W = W,
}

do
	local mod = script.Parent:FindFirstChild("NpcVariants")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok and type(res) == "table" and type(res.install) == "function" then
			local ok2, defs = pcall(res.install, NpcBuilder._kit)
			if ok2 and type(defs) == "table" then
				for k, d in defs do
					Defs[k] = d
				end
			else
				warn(`[NpcBuilder] NpcVariants.install failed: {defs}`)
			end
		else
			warn(`[NpcBuilder] NpcVariants unavailable: {res}`)
		end
	end
end

local PoseAlias = {
	stand = "stand",
	standing = "stand",
	idle = "stand",
	lying = "lying",
	ko = "lying",
	unconscious = "lying",
	sitting = "sitting",
	sit = "sitting",
	waving = "waving",
	wave = "waving",
	panicking = "panicking",
	panic = "panicking",
	sooty = "sitting",
}

-- Canonical kind name (case-insensitive lookup so RescueSpawn "floatguy" works).
local function canonical(kind: string): string?
	if Defs[kind] or kind == "Sooty" then
		return kind
	end
	local lower = string.lower(kind)
	for k in Defs do
		if string.lower(k) == lower then
			return k
		end
	end
	if lower == "sooty" then
		return "Sooty"
	end
	return nil
end

-- Burnt-to-soot look: everything charred except eye whites/highlights, plus smoke and embers.
local function sootify(ctx: Ctx, headWorld: Vector3)
	local shades = { C.Charred, C.CharredWarm, C.Soot, C.Charred }
	local i = 0
	for _, d in ctx.m:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "Root" and not ctx.keep[d] then
			i += 1
			d.Color = shades[(i % #shades) + 1]
			d.Material = Enum.Material.SmoothPlastic
			if d.Transparency > 0 and d.Transparency < 1 then
				d.Transparency = 0
			end
		elseif d:IsA("PointLight") or d:IsA("ParticleEmitter") then
			d:Destroy()
		end
	end
	local puff = MapKit.part(ctx.m, "SootPuff", CFrame.new(headWorld), Vector3.one * 0.4 * ctx.s, { transparency = 1, collide = false })
	finish(puff)
	local smoke = Instance.new("ParticleEmitter")
	smoke.Name = "SootSmoke"
	smoke.Rate = 4
	smoke.Lifetime = NumberRange.new(1.5, 2.5)
	smoke.Speed = NumberRange.new(1.5, 2.5)
	smoke.SpreadAngle = Vector2.new(15, 15)
	smoke.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4 * ctx.s), NumberSequenceKeypoint.new(1, 1.6 * ctx.s) })
	smoke.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.4), NumberSequenceKeypoint.new(1, 1) })
	smoke.Color = ColorSequence.new(C.SmokeGrey)
	smoke.Parent = puff
	local sparks = Instance.new("ParticleEmitter")
	sparks.Name = "SootSparks"
	sparks.Rate = 3
	sparks.Lifetime = NumberRange.new(0.6, 1.2)
	sparks.Speed = NumberRange.new(2, 4)
	sparks.SpreadAngle = Vector2.new(40, 40)
	sparks.Size = NumberSequence.new(0.12 * ctx.s)
	sparks.LightEmission = 1
	sparks.Color = ColorSequence.new(C.FireBody, C.Ember)
	sparks.Parent = puff
end

function NpcBuilder.Build(kind: string, cf: CFrame, opts: Opts?): Model
	local o = opts or {} :: Opts
	local requested = kind
	local k = canonical(kind)
	assert(k, `NpcBuilder: unknown kind {kind}`)
	local sooty = o.sooty == true or string.lower(o.pose or "") == "sooty"
	local pose = PoseAlias[string.lower(o.pose or "stand")] or "stand"
	if k == "Sooty" then
		k = "Civilian"
		sooty = true
		if o.pose == nil then
			pose = "sitting"
		end
	end
	local def = Defs[k]
	local bo: Opts = { helmet = o.helmet, color = o.color, pose = pose, sooty = sooty }
	local s = def.scale
	local ko = pose == "lying"

	local base = cf
	if ko then
		if def.pet then
			-- flopped on its side (paws toward +X), centred on cf
			base = cf * CFrame.new(0, def.back * s, 0) * CFrame.Angles(0, 0, math.rad(90)) * CFrame.new(0, -def.height * s / 2, 0)
		else
			-- on the back, face up, centred on cf
			base = cf * CFrame.new(0, def.back * s, -def.height * s / 2) * CFrame.Angles(math.rad(90), 0, 0)
		end
	end

	local m = Instance.new("Model")
	m.Name = if requested == "Sooty" or string.lower(requested) == "sooty" then "Sooty" else k
	local ctx: Ctx = { m = m, base = base, s = s, ko = ko, pose = pose, keep = {}, lieBack = def.back }
	local dims = def.build(ctx, bo)

	local headWorld = (base * CFrame.new(dims.head * s)).Position
	if ko then
		dizzy(ctx, headWorld + Vector3.new(0, 0.9 * s, 0))
	end
	if sooty then
		sootify(ctx, headWorld)
	end

	-- Root: invisible box around the body, pivot on the ground point.
	local w, h, d = dims.w * s, dims.h * s, dims.d * s
	local rootSize, rootCf
	if ko and not def.pet then
		rootSize = Vector3.new(w, def.back * s * 2, def.height * s)
		rootCf = cf * CFrame.new(0, def.back * s, 0)
	elseif ko then
		rootSize = Vector3.new(def.height * s, w, d)
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

	m:SetAttribute(Names.Attr.Kind, if m.Name == "Sooty" then "Sooty" else k)
	m:SetAttribute("Pose", pose)
	if sooty then
		m:SetAttribute("Sooty", true)
	end
	if k == "Firefighter" then
		m:SetAttribute(Names.Attr.Helmet, math.floor(o.helmet or 1))
	end
	return m
end

-- Width (studs, scaled) a kind takes in a lineup.
local function footprint(kind: string): number
	local k = canonical(kind) or "Civilian"
	local def = Defs[if k == "Sooty" then "Civilian" else k]
	return math.max(2.5, def.height * def.scale * 0.55) + 2
end

-- Name plate in front of a lineup entry (top face text, tilted up toward the camera).
local function plate(parent: Instance, cf: CFrame, text: string)
	local p = MapKit.part(parent, "Plate", cf * CFrame.new(0, 0.25, -3.2) * CFrame.Angles(math.rad(-25), 0, 0), Vector3.new(4, 0.3, 1.2), {
		color = hex("#2A2826"),
		collide = false,
	})
	p.CanTouch = false
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Label"
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(400, 120)
	gui.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.TextColor3 = C.Star
	t.Text = text
	t.Parent = gui
	gui.Parent = p
end

-- Every kind in a row along +X of cf (all facing -Z of cf), plus a second row behind (+Z) showing
-- each pose for a person, a firefighter and an animal. Returns the Model (parented to parent).
-- opts = { poses: boolean? (default true), plates: boolean? (default true) }
function NpcBuilder.Lineup(parent: Instance, cf: CFrame, opts: { [string]: any }?): Model
	local o = opts or {}
	local lineup = Instance.new("Model")
	lineup.Name = "NpcLineup"
	local entries: { { kind: string, opts: Opts, label: string } } = {}
	for n = 1, 4 do
		table.insert(entries, { kind = "Firefighter", opts = { helmet = n }, label = string.format("Firefighter %02d", n) })
	end
	for _, kind in NpcBuilder.Kinds do
		if kind ~= "Firefighter" and canonical(kind) then
			table.insert(entries, { kind = kind, opts = {}, label = kind })
		end
	end
	table.insert(entries, { kind = "Farmer", opts = { sooty = true }, label = "Farmer (sooty)" })

	local function row(list: { { kind: string, opts: Opts, label: string } }, z: number)
		local total = 0
		for _, e in list do
			total += footprint(e.kind)
		end
		local x = -total / 2
		for i, e in list do
			local wdt = footprint(e.kind)
			local at = cf * CFrame.new(x + wdt / 2, 0, z)
			x += wdt
			local ok, res = pcall(NpcBuilder.Build, e.kind, at, e.opts)
			if ok then
				res.Name = `{i}_{e.label}`
				res.Parent = lineup
				if o.plates ~= false then
					plate(lineup, at, e.label)
				end
			else
				warn(`[NpcBuilder.Lineup] {e.label}: {res}`)
			end
		end
	end
	row(entries, 0)

	if o.poses ~= false then
		local poseRow: { { kind: string, opts: Opts, label: string } } = {}
		for _, kind in { "Civilian", "Firefighter", "Raccoon" } do
			for _, pose in NpcBuilder.Poses do
				table.insert(poseRow, { kind = kind, opts = { pose = pose, helmet = 3 }, label = `{kind} {pose}` })
			end
		end
		row(poseRow, 14)
	end

	lineup.Parent = parent
	return lineup
end

return NpcBuilder
