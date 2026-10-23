--!strict
-- Viewmodel [owner: G1; v2 glove look + fallback role by the Hands agent]. Client-only first-person
-- arms: olive/yellow gloves, yellow turnout sleeves with the lime/silver/lime reflective 3-band at
-- the wrist (the trailer's look), plus a client-only nozzle and axe prop. Built from blocks
-- (docs/game/02-art-feel-ui.md §7). Sized by HandsConfig.GloveScale and posed low in the bottom
-- corners (HandsMath.Poses) so the gloves frame the screen instead of covering it.
--
-- This is the simple camera-attached fallback (touch devices, or HandsConfig.Enabled = false).
-- The full game uses ClientLib/PhysicsHands, which builds its gloves with Viewmodel.buildArmParts.
--
--   local vm = Viewmodel.new()          -- builds the Model (call from Start, never at require time)
--   vm:SetParent(workspace.CurrentCamera)
--   vm:Update(dt, camCFrame, { pose = "hose", bob = Vector2, sway = Vector2, spraying = bool, dip = number })
--   vm:Swing()                          -- axe swing animation (windup, strike, recover)
--   vm:SetSoot(alpha)                   -- 0..1 darkens sleeves/gloves toward CharredWarm
--   vm:SetVisible(bool)  vm:Destroy()
--   vm:GetNozzle(): BasePart?           -- the nozzle tip while the hose pose shows (stream origin)
--   Viewmodel.buildArmParts(model, side, prefix, scale, withSleeve) -> { PartRec } (wrist-relative)
--   Viewmodel.Colors                    -- Glove / Sleeve / Cuff / Knuckle
--
-- Parts in the Camera aren't simulated, so welds don't apply: every part keeps an offset from its
-- arm's wrist frame and the whole thing moves with one workspace:BulkMoveTo per frame.

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

local OLIVE = c("GloveOlive", Color3.fromHex("#8C7A3A"))
local YELLOW = c("CoatYellow", Color3.fromHex("#D9A030"))
-- Trailer gloves read as a warm olive-yellow leather, sleeves as bright turnout yellow.
local SHADOW = c("CoatShadow", Color3.fromHex("#9A6A30"))
local COLORS = {
	Glove = OLIVE:Lerp(YELLOW, 0.5),
	Knuckle = OLIVE:Lerp(YELLOW, 0.3),
	Sleeve = YELLOW:Lerp(SHADOW, 0.25),
	Cuff = SHADOW,
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
type Arm = { parts: { PartRec }, wrist: CFrame }

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
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	if shape then
		p.Shape = shape
	end
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

local SPHERE = Enum.MeshType.Sphere
local CYL = Enum.MeshType.Cylinder
local ALONG_Z = CFrame.Angles(math.rad(90), 0, 0) -- a Y-axis cylinder lying along the arm (Z)

local function scaled(offset: CFrame, s: number): CFrame
	return CFrame.new(offset.Position * s) * offset.Rotation
end

local function scale(): number
	local s = tonumber(HandsConfig.GloveScale) or 0.5
	return math.clamp(s, 0.2, 1.5)
end

-- Arm-local frame: origin at the wrist, sleeve runs toward +Z (back to the camera), the glove sits
-- at -Z, back of the hand up (+Y). `side` is 1 for right, -1 for left (thumb points inward).
-- Every part is anchored/non-colliding; callers that want physics (PhysicsHands) re-flag them.
-- The first record is always the palm ("Glove").
function Viewmodel.buildArmParts(model: Instance, side: number, prefix: string, s: number, withSleeve: boolean): { PartRec }
	local parts: { PartRec } = {}
	local function add(p: BasePart, offset: CFrame)
		p.Size *= s
		table.insert(parts, { part = p, offset = scaled(offset, s), base = p.Color })
	end
	local glove, knuckle = COLORS.Glove, COLORS.Knuckle
	local mat = Enum.Material.SmoothPlastic
	-- puffy cartoon glove: ellipsoid palm, four sausage fingers, a thumb, a knuckle ridge
	add(round(block(model, prefix .. "Glove", Vector3.new(1.3, 0.8, 1.2), glove, mat), SPHERE), CFrame.new(0, 0, -0.55))
	add(round(block(model, prefix .. "Knuckles", Vector3.new(1.2, 0.4, 0.45), knuckle, mat), SPHERE), CFrame.new(0, 0.28, -0.9))
	for i = 1, 4 do
		local x = (-0.45 + (i - 1) * 0.3) * side
		local len = if i == 1 or i == 4 then 0.6 else 0.72
		add(
			round(block(model, prefix .. "Finger" .. i, Vector3.new(0.3, 0.32, len), glove, mat), SPHERE),
			CFrame.new(x, -0.04, -1.1 - len / 2 + 0.12) * CFrame.Angles(math.rad(-20), 0, 0)
		)
	end
	add(
		round(block(model, prefix .. "Thumb", Vector3.new(0.32, 0.34, 0.7), glove, mat), SPHERE),
		CFrame.new(-0.62 * side, -0.08, -0.62) * CFrame.Angles(0, math.rad(35 * side), 0)
	)
	-- gauntlet cuff + the reflective 3-band (lime / silver / lime), rings slightly proud of the sleeve
	add(round(block(model, prefix .. "Cuff", Vector3.new(1.1, 0.42, 1.0), COLORS.Cuff, mat), CYL), CFrame.new(0, 0, 0.1) * ALONG_Z)
	local lime = c("ReflectLime", Color3.fromHex("#E8E25A"))
	local silver = c("ReflectSilver", Color3.fromHex("#C9CCD0"))
	for i, b in { { lime, 0.5 }, { silver, 0.7 }, { lime, 0.9 } } do
		local band = block(model, prefix .. "Band" .. i, Vector3.new(1.0, 0.15, 1.0), b[1] :: Color3, mat)
		band.Reflectance = 0.15
		add(round(band, CYL), CFrame.new(0, 0, b[2] :: number) * ALONG_Z)
	end
	if withSleeve then
		local sleeveLen = 2.2
		add(
			round(block(model, prefix .. "Sleeve", Vector3.new(0.92, sleeveLen, 0.92), COLORS.Sleeve, Enum.Material.Fabric), CYL),
			CFrame.new(0, 0, 0.3 + sleeveLen / 2) * ALONG_Z
		)
	end
	return parts
end

local function buildArm(model: Model, side: number, prefix: string): Arm
	return { parts = Viewmodel.buildArmParts(model, side, prefix, scale(), true), wrist = CFrame.new() }
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
		arms: { [string]: Arm },
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
	local self = setmetatable({
		model = model,
		arms = { R = buildArm(model, 1, "Right"), L = buildArm(model, -1, "Left") },
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
	for _, arm in self.arms do
		setPartsVisible(arm.parts, on)
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
	local dark = c("CharredWarm", Color3.fromHex("#3A2A22"))
	for _, arm in self.arms do
		for _, r in arm.parts do
			if not string.find(r.part.Name, "Band") then
				r.part.Color = r.base:Lerp(dark, alpha * 0.55)
			end
		end
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
	for side, arm in self.arms do
		local w = wrist[side]
		for _, r in arm.parts do
			table.insert(parts, r.part)
			table.insert(cframes, w * r.offset)
		end
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
