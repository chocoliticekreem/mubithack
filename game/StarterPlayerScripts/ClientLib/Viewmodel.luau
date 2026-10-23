--!strict
-- Viewmodel [owner: G1; v2 glove rig by the Hands agent]. Client-only first-person arms in the
-- trailer's look: chunky olive rubber work gloves (rounded palm, four two-jointed fingers and a
-- thumb that curl, a gauntlet cuff with a lime band) and tan turnout sleeves with two lime/silver/
-- lime reflective bands and a few soot smudges. Built from primitives (no mesh assets needed).
--
-- The glove "rig" is shared with ClientLib/PhysicsHands: there the physics palm is an invisible
-- collider and this rig is drawn on top of it every frame. Rig parts live in the Camera (local,
-- never simulated, CastShadow off) and move with one workspace:BulkMoveTo per frame.
--
-- This module is also the simple camera-attached fallback (touch devices, or
-- HandsConfig.Enabled = false):
--   local vm = Viewmodel.new()          -- builds the Model (call from Start, never at require time)
--   vm:SetParent(workspace.CurrentCamera)
--   vm:Update(dt, camCFrame, { pose = "hose", bob = Vector2, sway = Vector2, spraying = bool, dip = number })
--   vm:Swing()                          -- axe swing animation (windup, strike, recover)
--   vm:SetSoot(alpha)                   -- 0..1 darkens sleeves/gloves toward CharredWarm
--   vm:SetVisible(bool)  vm:Destroy()
--   vm:GetNozzle(): BasePart?           -- the nozzle tip while the hose pose shows (stream origin)
-- Rig API (PhysicsHands):
--   Viewmodel.newRig(parent, side, prefix, scale) -> Rig      side 1 = right, -1 = left
--   Viewmodel.poseRig(rig, wrist, shoulder, up, curl, t, parts, cframes)  -- appends to the lists
--   Viewmodel.setRigSoot(rig, alpha)
--   Viewmodel.Colors                    -- Glove / Sleeve / Cuff / Band / Silver / Soot

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local HandsMath = require(ReplicatedStorage:WaitForChild("HandsMath") :: ModuleScript)
local HandsConfig =
	require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HandsConfig") :: ModuleScript) :: any

local Viewmodel = {}
Viewmodel.__index = Viewmodel

export type Pose = "empty" | "hose" | "axe" | "carry" | "item"

export type Frame = {
	pose: Pose,
	bob: Vector2?, -- studs, already scaled
	sway: Vector2?, -- radians (pitch, yaw)
	spraying: boolean?,
	dip: number?, -- landing dip, studs (negative = down)
}

local function c(name: string, fallback: Color3): Color3
	local v = Palette[name]
	return if typeof(v) == "Color3" then v else fallback
end

-- Trailer colours: olive-green rubber gloves, tan turnout coat, lime + silver reflective tape.
local COLORS = {
	Glove = Color3.fromHex("#606C2B"),
	GloveDark = Color3.fromHex("#4C5622"),
	Patch = Color3.fromHex("#B59A55"),
	Sleeve = Color3.fromHex("#C4A050"),
	SleeveDark = Color3.fromHex("#A8894A"),
	Band = Color3.fromHex("#C6F04A"),
	Silver = Color3.fromHex("#D5D9DE"),
	Soot = Color3.fromHex("#3A2E26"),
	-- legacy names
	Knuckle = Color3.fromHex("#6B7A2A"),
	Cuff = Color3.fromHex("#55621F"),
}
Viewmodel.Colors = COLORS

local function cf(p: HandsMath.Pose): CFrame
	return CFrame.new(p.x, p.y, p.z) * CFrame.Angles(math.rad(p.rx), math.rad(p.ry), math.rad(p.rz))
end

local function pair(right: string, left: string?): { R: CFrame, L: CFrame }
	return { R = cf(HandsMath.pose(right, "R")), L = cf(HandsMath.pose(left or right, "L")) }
end

-- Wrist frames in camera space, from the shared pose table (left mirrors right unless given).
local POSES: { [string]: { R: CFrame, L: CFrame } } = {
	empty = pair("idle"),
	hose = { R = cf(HandsMath.Poses.hose), L = cf(HandsMath.Poses.hoseSupport) },
	axe = pair("axeReady", "lowered"),
	carry = pair("carry"),
	item = pair("item", "lowered"),
}

type PartRec = { part: BasePart, offset: CFrame, base: Color3 }
export type PartRecord = PartRec

local function block(
	model: Instance,
	name: string,
	size: Vector3,
	color: Color3,
	material: Enum.Material?,
	shape: Enum.PartType?
): BasePart
	local p = Instance.new("Part")
	p.Name = name
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

-- Rounded cartoon shapes: an ellipsoid (Sphere mesh) or a Y-axis cylinder that fills the part box.
local function round(p: BasePart, kind: Enum.MeshType): BasePart
	local m = Instance.new("SpecialMesh")
	m.MeshType = kind
	m.Parent = p
	return p
end
Viewmodel.round = round

local function scaled(offset: CFrame, s: number): CFrame
	return CFrame.new(offset.Position * s) * offset.Rotation
end

local function scale(): number
	local s = tonumber(HandsConfig.GloveScale) or 0.5
	return math.clamp(s, 0.2, 1.5)
end

-- glove rig ---------------------------------------------------------------------------------------
-- Wrist frame: origin at the wrist, fingers toward -Z, back of the hand up (+Y), sleeve toward +Z.
-- `side` 1 = right hand, -1 = left (the thumb is on the -X * side edge).
local X_TO_FWD = CFrame.Angles(0, math.rad(90), 0) -- a Part cylinder's X axis -> the frame's -Z

type Finger = {
	base: CFrame, -- wrist-relative frame at the knuckle, pointing along the finger (-Z)
	lens: { number },
	dia: number,
	curlMul: number,
	thumb: boolean,
	balls: { BasePart }, -- knuckle, middle joint, tip
	segs: { BasePart },
}

type Band = { part: BasePart, at: number }
type Soot = { part: BasePart, at: number, ang: number }

export type Rig = {
	model: Instance,
	side: number,
	s: number,
	static: { PartRec }, -- wrist-relative
	fingers: { Finger },
	sleeveEnd: number, -- wrist-space z where the coat sleeve starts
	rim: BasePart,
	body: BasePart,
	bands: { Band },
	soot: { Soot },
	all: { PartRec },
	sootAlpha: number,
}

local GLOVE_MAT = Enum.Material.SmoothPlastic
local SLEEVE_MAT = Enum.Material.SmoothPlastic

function Viewmodel.newRig(parent: Instance, side: number, prefix: string, s: number): Rig
	local rig: Rig = {
		model = parent,
		side = side,
		s = s,
		static = {},
		fingers = {},
		sleeveEnd = 0.5 * s,
		rim = nil :: any,
		body = nil :: any,
		bands = {},
		soot = {},
		all = {},
		sootAlpha = 0,
	}
	local function track(p: BasePart): BasePart
		table.insert(rig.all, { part = p, offset = CFrame.identity, base = p.Color })
		return p
	end
	local function static(p: BasePart, offset: CFrame): BasePart
		p.Size *= s
		table.insert(rig.static, { part = p, offset = scaled(offset, s), base = p.Color })
		return track(p)
	end
	local glove, dark = COLORS.Glove, COLORS.GloveDark

	-- palm: a rounded slab (core + edge cylinders + corner balls)
	local W, H, D, CZ = 1.0, 0.48, 0.86, -0.5
	local r = H / 2
	local a, d = W - H, D - H
	local function palmPart(name: string, size: Vector3, shape: Enum.PartType, offset: CFrame)
		local p = block(parent, prefix .. name, size, glove, GLOVE_MAT, shape)
		p.Reflectance = 0.02
		static(p, offset)
	end
	palmPart("Palm", Vector3.new(a, H, d), Enum.PartType.Block, CFrame.new(0, 0, CZ))
	for _, z in { -d / 2, d / 2 } do
		palmPart("PalmEdgeZ", Vector3.new(a, H, H), Enum.PartType.Cylinder, CFrame.new(0, 0, CZ + z))
	end
	for _, x in { -a / 2, a / 2 } do
		palmPart("PalmEdgeX", Vector3.new(d, H, H), Enum.PartType.Cylinder, CFrame.new(x, 0, CZ) * X_TO_FWD)
		for _, z in { -d / 2, d / 2 } do
			palmPart("PalmCorner", Vector3.new(H, H, H), Enum.PartType.Ball, CFrame.new(x, 0, CZ + z))
		end
	end
	-- tan patch on the back of the hand (trailer glove detail)
	local patch = block(parent, prefix .. "Patch", Vector3.new(0.5, 0.06, 0.4), COLORS.Patch, GLOVE_MAT)
	static(round(patch, Enum.MeshType.Sphere), CFrame.new(0.06 * side, r - 0.005, CZ + 0.02))

	-- fingers: index (thumb side) -> pinky; two segments each, ball joints for chunky knuckles
	local fingerSpec = {
		{ x = -0.36, len = 0.52, dia = 0.29, mul = 0.9 },
		{ x = -0.12, len = 0.58, dia = 0.3, mul = 1.0 },
		{ x = 0.12, len = 0.54, dia = 0.29, mul = 1.05 },
		{ x = 0.36, len = 0.43, dia = 0.27, mul = 1.15 },
	}
	for i, f in fingerSpec do
		local yaw = math.rad((2.5 - i) * 3.5 * side)
		local base = CFrame.new(f.x * side * s, -0.02 * s, (CZ - D / 2 + 0.06) * s) * CFrame.Angles(0, yaw, 0)
		local finger: Finger = {
			base = base,
			lens = { f.len * 0.55 * s, f.len * 0.45 * s },
			dia = f.dia * s,
			curlMul = f.mul,
			thumb = false,
			balls = {},
			segs = {},
		}
		for j = 1, 3 do
			local b = block(parent, prefix .. "Finger" .. i .. "J" .. j, Vector3.one * f.dia * s * (if j == 1 then 1.04 else 1), glove, GLOVE_MAT, Enum.PartType.Ball)
			b.Reflectance = 0.02
			table.insert(finger.balls, track(b))
		end
		for j = 1, 2 do
			local seg = block(parent, prefix .. "Finger" .. i .. "S" .. j, Vector3.new(finger.lens[j], f.dia * s, f.dia * s), glove, GLOVE_MAT, Enum.PartType.Cylinder)
			seg.Reflectance = 0.02
			table.insert(finger.segs, track(seg))
		end
		table.insert(rig.fingers, finger)
	end
	-- thumb: from the heel of the palm, angled forward and in
	do
		local base = CFrame.new(-0.44 * side * s, -0.1 * s, (CZ + 0.2) * s)
			* CFrame.Angles(0, math.rad(32 * side), 0)
			* CFrame.Angles(math.rad(-12), 0, math.rad(-20 * side))
		local thumb: Finger = {
			base = base,
			lens = { 0.34 * s, 0.28 * s },
			dia = 0.3 * s,
			curlMul = 1,
			thumb = true,
			balls = {},
			segs = {},
		}
		for j = 1, 3 do
			local b = block(parent, prefix .. "ThumbJ" .. j, Vector3.one * 0.3 * s * (if j == 1 then 1.15 else 1), glove, GLOVE_MAT, Enum.PartType.Ball)
			table.insert(thumb.balls, track(b))
		end
		for j = 1, 2 do
			local seg = block(parent, prefix .. "ThumbS" .. j, Vector3.new(thumb.lens[j], 0.3 * s, 0.3 * s), glove, GLOVE_MAT, Enum.PartType.Cylinder)
			table.insert(thumb.segs, track(seg))
		end
		table.insert(rig.fingers, thumb)
	end

	-- gauntlet cuff with a reflective band, flaring into the coat sleeve
	static(block(parent, prefix .. "Cuff", Vector3.new(0.62, 0.9, 0.9), dark, GLOVE_MAT, Enum.PartType.Cylinder), CFrame.new(0, 0, 0.22) * X_TO_FWD)
	static(block(parent, prefix .. "CuffFlare", Vector3.new(0.14, 0.98, 0.98), dark, GLOVE_MAT, Enum.PartType.Cylinder), CFrame.new(0, 0, 0.5) * X_TO_FWD)
	local cuffBand = block(parent, prefix .. "CuffBand", Vector3.new(0.09, 0.93, 0.93), COLORS.Band, GLOVE_MAT, Enum.PartType.Cylinder)
	cuffBand.Reflectance = 0.12
	static(cuffBand, CFrame.new(0, 0, 0.3) * X_TO_FWD)

	-- coat sleeve: a rim at the wrist end and a body stretched to the shoulder (see poseRig)
	rig.sleeveEnd = 0.42 * s
	rig.rim = track(block(parent, prefix .. "SleeveRim", Vector3.new(0.24, 1.24, 1.24) * s, COLORS.SleeveDark, SLEEVE_MAT, Enum.PartType.Cylinder))
	rig.body = track(block(parent, prefix .. "Sleeve", Vector3.new(2, 1.16, 1.16) * s, COLORS.Sleeve, SLEEVE_MAT, Enum.PartType.Cylinder))
	-- two lime / silver / lime reflective bands
	for _, g in { 0.45, 1.45 } do
		for k, spec in { { COLORS.Band, -0.13, 0.1 }, { COLORS.Silver, 0, 0.12 }, { COLORS.Band, 0.13, 0.1 } } do
			local band = block(parent, prefix .. "Band" .. k, Vector3.new(spec[3] :: number, 1.2, 1.2) * s, spec[1] :: Color3, Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
			band.Reflectance = if k == 2 then 0.25 else 0.1
			table.insert(rig.bands, { part = track(band), at = (g + (spec[2] :: number)) * s })
		end
	end
	-- soot smudges (flat ellipsoids sitting on the sleeve / glove)
	for _, sp in { { 0.95, 35, 0.42, 0.3 }, { 1.95, -25, 0.5, 0.34 }, { 2.4, 70, 0.3, 0.24 } } do
		local smudge = block(parent, prefix .. "Soot", Vector3.new(sp[3], 0.05, sp[4]) * s, COLORS.Soot, Enum.Material.SmoothPlastic)
		smudge.Transparency = 0.45
		round(smudge, Enum.MeshType.Sphere)
		table.insert(rig.soot, { part = track(smudge), at = sp[1] * s, ang = math.rad(sp[2] * side) })
	end
	local gloveSoot = block(parent, prefix .. "GloveSoot", Vector3.new(0.34, 0.05, 0.26), COLORS.Soot, Enum.Material.SmoothPlastic)
	gloveSoot.Transparency = 0.55
	static(round(gloveSoot, Enum.MeshType.Sphere), CFrame.new(-0.22 * side, r + 0.01, CZ - 0.2))
	return rig
end

-- Curl angles (radians) for a 0..1 grip amount: 0 = open hand, ~0.3 = relaxed, 1 = fist/wrapped.
local function curlAngles(f: Finger, curl: number): (CFrame, CFrame)
	if f.thumb then
		local a = (0.15 + 0.75 * curl)
		local rot = CFrame.Angles(-a * 0.35, 0, 0) * CFrame.Angles(0, -a * 0.9, 0)
		return rot, CFrame.Angles(-a * 0.5, 0, 0)
	end
	local m = f.curlMul
	local a1 = (0.12 + 1.35 * curl) * m
	local a2 = (0.18 + 1.5 * curl) * m
	return CFrame.Angles(-a1, 0, 0), CFrame.Angles(-a2, 0, 0)
end

local function thumbSide(f: Finger, rot: CFrame, side: number): CFrame
	-- the thumb's yaw curls toward the palm centre, which is +X for the right hand
	if f.thumb and side < 0 then
		local x, y, z = rot:ToEulerAnglesXYZ()
		return CFrame.Angles(x, -y, -z)
	end
	return rot
end

-- Appends every rig part and its world CFrame for this frame. `wrist` is the world wrist frame,
-- `shoulder` the world point the coat sleeve runs to, `up` the camera up vector.
function Viewmodel.poseRig(
	rig: Rig,
	wrist: CFrame,
	shoulder: Vector3,
	up: Vector3,
	curl: number,
	parts: { BasePart },
	cframes: { CFrame }
)
	for _, r in rig.static do
		table.insert(parts, r.part)
		table.insert(cframes, wrist * r.offset)
	end
	for _, f in rig.fingers do
		local r1, r2 = curlAngles(f, curl)
		r1 = thumbSide(f, r1, rig.side)
		local j0 = wrist * f.base * r1
		local j1 = j0 * CFrame.new(0, 0, -f.lens[1]) * r2
		local tip = j1 * CFrame.new(0, 0, -f.lens[2])
		table.insert(parts, f.balls[1])
		table.insert(cframes, j0)
		table.insert(parts, f.segs[1])
		table.insert(cframes, j0 * CFrame.new(0, 0, -f.lens[1] / 2) * X_TO_FWD)
		table.insert(parts, f.balls[2])
		table.insert(cframes, j1)
		table.insert(parts, f.segs[2])
		table.insert(cframes, j1 * CFrame.new(0, 0, -f.lens[2] / 2) * X_TO_FWD)
		table.insert(parts, f.balls[3])
		table.insert(cframes, tip)
	end
	-- sleeve: from just past the cuff to (a bit beyond) the shoulder
	local e = (wrist * CFrame.new(0, 0, rig.sleeveEnd)).Position
	local span = shoulder - e
	local len = span.Magnitude
	if len < 0.05 then
		span = wrist.LookVector * -1
		len = 1
	end
	local frame = CFrame.lookAt(e, e + span, up)
	local bodyLen = len + 0.6 * rig.s
	local body = rig.body
	if math.abs(body.Size.X - bodyLen) > 0.01 then
		body.Size = Vector3.new(bodyLen, body.Size.Y, body.Size.Z)
	end
	table.insert(parts, rig.rim)
	table.insert(cframes, frame * CFrame.new(0, 0, -rig.rim.Size.X / 2 + 0.02 * rig.s) * X_TO_FWD)
	table.insert(parts, body)
	table.insert(cframes, frame * CFrame.new(0, 0, -bodyLen / 2) * X_TO_FWD)
	for _, b in rig.bands do
		table.insert(parts, b.part)
		table.insert(cframes, frame * CFrame.new(0, 0, -math.min(b.at, len)) * X_TO_FWD)
	end
	local radius = body.Size.Y / 2
	for _, sm in rig.soot do
		table.insert(parts, sm.part)
		table.insert(cframes, frame * CFrame.new(0, 0, -math.min(sm.at, len)) * CFrame.Angles(0, 0, sm.ang) * CFrame.new(0, radius, 0))
	end
end

-- Soot: 0..1 darkens everything but the reflective tape; smudges get stronger.
function Viewmodel.setRigSoot(rig: Rig, alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	if math.abs(alpha - rig.sootAlpha) < 0.02 then
		return
	end
	rig.sootAlpha = alpha
	local dark = c("CharredWarm", Color3.fromHex("#3A2A22"))
	for _, r in rig.all do
		local n = r.part.Name
		if string.find(n, "Soot") then
			r.part.Transparency = 0.5 - 0.3 * alpha
		elseif not string.find(n, "Band") then
			r.part.Color = r.base:Lerp(dark, alpha * 0.45)
		end
	end
end

type Prop = { parts: { PartRec }, hand: string }

local function buildNozzle(model: Model): Prop
	local prop: Prop = { parts = {}, hand = "R" }
	local s = scale() * 1.15
	local function add(p: BasePart, offset: CFrame)
		p.Size *= s
		table.insert(prop.parts, { part = p, offset = scaled(offset, s), base = p.Color })
	end
	local brass = c("BrassCoupling", Color3.fromHex("#C89A3C"))
	add(block(model, "NozzleGrip", Vector3.new(0.5, 1.0, 0.5), Color3.fromHex("#2B2B2E")), CFrame.new(0, 0.1, -0.7))
	add(block(model, "NozzleBody", Vector3.new(1.6, 0.6, 0.6), brass, Enum.Material.Metal, Enum.PartType.Cylinder), CFrame.new(0, 0.65, -1.3) * CFrame.Angles(0, math.rad(90), 0))
	add(block(model, "NozzleTip", Vector3.new(0.5, 0.8, 0.8), Color3.fromHex("#1E1E22"), Enum.Material.Rubber, Enum.PartType.Cylinder), CFrame.new(0, 0.65, -2.25) * CFrame.Angles(0, math.rad(90), 0))
	add(block(model, "NozzleBail", Vector3.new(0.15, 0.6, 0.9), Color3.fromHex("#C8231B")), CFrame.new(0.35, 1.0, -1.3))
	add(block(model, "HoseTail", Vector3.new(2.4, 0.55, 0.55), c("HoseYellow", Color3.fromHex("#E8B83A")), Enum.Material.Fabric, Enum.PartType.Cylinder), CFrame.new(0, 0.55, 0.5) * CFrame.Angles(math.rad(-25), math.rad(90), 0))
	return prop
end

local function buildAxe(model: Model): Prop
	local prop: Prop = { parts = {}, hand = "R" }
	local s = scale() * 1.15
	local function add(p: BasePart, offset: CFrame)
		p.Size *= s
		table.insert(prop.parts, { part = p, offset = scaled(offset, s), base = p.Color })
	end
	add(block(model, "AxeHandle", Vector3.new(0.32, 3.4, 0.32), Color3.fromHex("#B5793F"), Enum.Material.Wood), CFrame.new(0, 1.2, -0.6))
	add(block(model, "AxeHead", Vector3.new(0.25, 0.8, 1.25), Color3.fromHex("#C8232B"), Enum.Material.Metal), CFrame.new(0, 2.65, -0.95))
	add(block(model, "AxeEdge", Vector3.new(0.27, 0.85, 0.2), Color3.fromHex("#D6D8DC"), Enum.Material.Metal), CFrame.new(0, 2.65, -1.62))
	add(block(model, "AxePick", Vector3.new(0.22, 0.3, 0.6), Color3.fromHex("#5A5A60"), Enum.Material.Metal), CFrame.new(0, 2.65, -0.1))
	return prop
end

local function setPartsVisible(parts: { PartRec }, on: boolean)
	for _, r in parts do
		r.part.LocalTransparencyModifier = if on then 0 else 1
	end
end

export type Viewmodel = typeof(setmetatable(
	{} :: {
		model: Model,
		rigs: { [string]: Rig },
		props: { [string]: Prop },
		current: { [string]: CFrame },
		pose: string,
		swingT: number,
		visible: boolean,
		soot: number,
		t: number,
	},
	Viewmodel
))

function Viewmodel.new(): Viewmodel
	local model = Instance.new("Model")
	model.Name = "Viewmodel"
	local s = scale()
	local self = setmetatable({
		model = model,
		rigs = { R = Viewmodel.newRig(model, 1, "Right", s), L = Viewmodel.newRig(model, -1, "Left", s) },
		props = { hose = buildNozzle(model), axe = buildAxe(model) },
		current = { R = POSES.empty.R, L = POSES.empty.L },
		pose = "empty",
		swingT = -1,
		visible = true,
		soot = 0,
		t = 0,
	}, Viewmodel)
	for _, prop in self.props do
		setPartsVisible(prop.parts, false)
	end
	return self
end

function Viewmodel.SetParent(self: Viewmodel, parent: Instance?)
	self.model.Parent = parent
end

function Viewmodel.Swing(self: Viewmodel)
	if self.swingT < 0 or self.swingT > 0.3 then
		self.swingT = 0
	end
end

function Viewmodel.SetVisible(self: Viewmodel, on: boolean)
	if self.visible == on then
		return
	end
	self.visible = on
	for _, rig in self.rigs do
		setPartsVisible(rig.all, on)
	end
	for name, prop in self.props do
		setPartsVisible(prop.parts, on and name == self.pose)
	end
end

function Viewmodel.SetSoot(self: Viewmodel, alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	if math.abs(alpha - self.soot) < 0.02 then
		return
	end
	self.soot = alpha
	for _, rig in self.rigs do
		Viewmodel.setRigSoot(rig, alpha)
	end
end

function Viewmodel.GetNozzle(self: Viewmodel): BasePart?
	if not self.visible or self.pose ~= "hose" then
		return nil
	end
	for _, r in self.props.hose.parts do
		if r.part.Name == "NozzleTip" then
			return r.part
		end
	end
	return nil
end

-- Axe swing offset for the right wrist: windup (-30 deg, 0.12 s), strike (+50, 0.08 s), recover 0.25 s.
local function swingOffset(t: number): CFrame
	if t < 0 then
		return CFrame.identity
	end
	local pitch
	if t < 0.12 then
		pitch = 30 * (t / 0.12)
	elseif t < 0.2 then
		pitch = 30 - 80 * ((t - 0.12) / 0.08)
	elseif t < 0.45 then
		pitch = -50 * (1 - (t - 0.2) / 0.25)
	else
		return CFrame.identity
	end
	return CFrame.new(0, 0, if pitch < 0 then -0.5 * (-pitch / 50) else 0) * CFrame.Angles(math.rad(pitch), 0, 0)
end

local parts: { BasePart } = {}
local cframes: { CFrame } = {}

function Viewmodel.Update(self: Viewmodel, dt: number, cam: CFrame, f: Frame)
	self.t += dt
	local pose = POSES[f.pose] and f.pose or "empty"
	if pose ~= self.pose then
		local old = self.props[self.pose]
		if old then
			setPartsVisible(old.parts, false)
		end
		self.pose = pose
		local new = self.props[pose]
		if new then
			setPartsVisible(new.parts, self.visible)
		end
	end
	if not self.visible then
		return
	end

	local target = POSES[pose]
	local a = 1 - math.exp(-14 * dt)
	self.current.R = self.current.R:Lerp(target.R, a)
	self.current.L = self.current.L:Lerp(target.L, a)

	local bob = f.bob or Vector2.zero
	local sway = f.sway or Vector2.zero
	local root = cam * CFrame.new(bob.X, bob.Y + (f.dip or 0), 0) * CFrame.Angles(sway.X, sway.Y, sway.Y * 0.6)

	local recoil = CFrame.identity
	if f.spraying and pose == "hose" then
		local x, y, z, pitch = HandsMath.hoseKick(self.t, 1, 0.4)
		recoil = CFrame.new(x, y, z) * CFrame.Angles(math.rad(pitch), 0, 0)
	end
	local swing = CFrame.identity
	if self.swingT >= 0 then
		self.swingT += dt
		swing = swingOffset(self.swingT)
		if self.swingT > 0.45 then
			self.swingT = -1
		end
	end

	local wrist = {
		R = root * recoil * self.current.R * (if pose == "axe" then swing else CFrame.identity),
		L = root * recoil * self.current.L,
	}

	table.clear(parts)
	table.clear(cframes)
	for side, rig in self.rigs do
		local sign = if side == "R" then 1 else -1
		local shoulder = root
			* Vector3.new(HandsConfig.ShoulderX * sign, HandsConfig.ShoulderY, HandsConfig.ShoulderZ)
		local holding = (side == "R" and pose ~= "empty") or (side == "L" and pose == "hose") or pose == "carry"
		local curl = if holding then 0.9 else 0.3 + 0.05 * math.sin(self.t * 1.6 + sign)
		Viewmodel.poseRig(rig, wrist[side], shoulder, cam.UpVector, curl, parts, cframes)
	end
	local prop = self.props[pose]
	if prop then
		local w = wrist[prop.hand]
		for _, r in prop.parts do
			table.insert(parts, r.part)
			table.insert(cframes, w * r.offset)
		end
	end
	workspace:BulkMoveTo(parts, cframes, Enum.BulkMoveMode.FireCFrameChanged)
end

function Viewmodel.Destroy(self: Viewmodel)
	self.model:Destroy()
end

-- Exposed for tuning from the command bar / tests.
Viewmodel.Poses = POSES

return Viewmodel
