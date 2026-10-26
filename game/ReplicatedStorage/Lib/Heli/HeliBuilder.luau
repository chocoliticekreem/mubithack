--!strict
-- HeliBuilder [owner: Heli]. Builds the cartoon FIRE HELICOPTER from parts (no assets): red + white
-- cabin with open doors (you can see who's riding), glass bubble nose, "STATION 67" on both sills, tail
-- boom with a "67" fin, spinning main + tail rotors, skids, and an orange bambi bucket on a rope.
-- Shared (ReplicatedStorage) so the server spawns it and the store draws the same model in a
-- ViewportFrame. Pure construction: no prompts, no physics movers (HeliService adds those).
--
--   HeliBuilder.build(cfg) -> Model   cfg = HeliConfig. The model sits at the origin, nose = -Z.
--     PrimaryPart "Root" (invisible collision hull; every other part welds to it). Parts:
--     "PilotSeat" (Seat), "RideSeat1".."RideSeat3" (Seat), "Rotor" + Motor6D "RotorMotor" (spin about Y),
--     "TailRotor" + Motor6D "TailMotor" (spin about X), "Bucket" + Motor6D "BucketMotor" (rope drop / sway),
--     "BucketWater" (welded in the bucket; shown when full), RopeConstraint "Rope", Attachments
--     "BellyAtt" / "BucketTop", ParticleEmitter "Bucket.Pour" (disabled; client bursts it on a drop).
--   HeliBuilder.SkidDepth  studs from the Root centre down to the bottom of the skids
--   HeliBuilder.BellyY     Root-space Y of the rope's top
local HeliBuilder = {}

HeliBuilder.SkidDepth = 4.45
HeliBuilder.BellyY = -2.6

local INK = Color3.fromHex("#2A1410")

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

local function part(model: Model, root: BasePart?, name: string, cf: CFrame, size: Vector3, color: Color3, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.Shape = o.shape or Enum.PartType.Block
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Transparency = o.transparency or 0
	p.CanCollide = o.collide == true
	p.CanTouch = false
	p.CanQuery = o.query == true
	p.Massless = true
	p.CastShadow = o.shadow ~= false
	p.Anchored = false
	p.Parent = model
	if root and o.noWeld ~= true then
		weld(root, p)
	end
	return p
end

local function text(p: BasePart, face: Enum.NormalId, str: string, color: Color3, ppsU: number?)
	local g = Instance.new("SurfaceGui")
	g.Name = "Decal" .. face.Name
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = ppsU or 40
	g.LightInfluence = 0.4
	g.Parent = p
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(0.94, 0.86)
	l.Position = UDim2.fromScale(0.03, 0.07)
	l.Font = Enum.Font.LuckiestGuy
	l.TextScaled = true
	l.Text = str
	l.TextColor3 = color
	l.Parent = g
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = INK
	s.Parent = l
end

local function motor(name: string, p0: BasePart, p1: BasePart, c0: CFrame, c1: CFrame?): Motor6D
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = p0
	m.Part1 = p1
	m.C0 = c0
	m.C1 = c1 or CFrame.identity
	m.Parent = p0
	return m
end

function HeliBuilder.build(cfg: any): Model
	local RED: Color3 = cfg.BodyColor or Color3.fromHex("#D9372A")
	local WHITE: Color3 = cfg.StripeColor or Color3.fromHex("#FFF6EA")
	local DARK: Color3 = cfg.TrimColor or Color3.fromHex("#2A2A30")
	local ORANGE: Color3 = cfg.BucketColor or Color3.fromHex("#FF8A1F")
	local WATER: Color3 = cfg.WaterColor or Color3.fromHex("#4FB3D9")
	local rope: number = tonumber(cfg.RopeLength) or 11
	local C = CFrame.new
	local Z90 = CFrame.Angles(0, 0, math.rad(90)) -- cylinder axis X -> Y (upright)
	local Y90 = CFrame.Angles(0, math.rad(90), 0) -- cylinder axis X -> Z (fore-aft)

	local m = Instance.new("Model")
	m.Name = "FireHeli"

	-- the collision hull: what bumps into buildings / sits on the ground
	local root = part(m, nil, "Root", C(0, 0, 0.4), Vector3.new(6.4, 5.6, 10), RED, { collide = true, transparency = 1, shadow = false })
	root.Massless = false
	root.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.3, 0.2)
	m.PrimaryPart = root

	-- cabin shell (open doors both sides)
	part(m, root, "Floor", C(0, -2.25, 0.6), Vector3.new(6, 0.7, 8.6), RED)
	part(m, root, "Belly", C(0, -2.75, 0.6), Vector3.new(5.2, 0.5, 7.6), DARK)
	part(m, root, "Roof", C(0, 2.55, 0.9), Vector3.new(6, 0.8, 7.2), RED)
	part(m, root, "RoofStripe", C(0, 2.15, 0.9), Vector3.new(6.1, 0.25, 7.3), WHITE)
	part(m, root, "BackWall", C(0, 0.15, 4.6), Vector3.new(6, 5.6, 0.7), RED)
	part(m, root, "Dash", C(0, -1.1, -3.4), Vector3.new(6, 2, 1.6), RED)
	part(m, root, "Nose", C(0, -0.7, -4.15) * Z90, Vector3.new(3.4, 4.2, 4.2), RED, { shape = Enum.PartType.Cylinder })
	part(m, root, "Glass", C(0, 0.55, -3.7), Vector3.new(6.1, 6.1, 6.1), Color3.fromHex("#BDEBFF"), {
		shape = Enum.PartType.Ball,
		material = Enum.Material.Glass,
		transparency = 0.55,
		shadow = false,
	})
	for _, sx in { -1, 1 } do
		local sill = part(m, root, if sx < 0 then "SillL" else "SillR", C(sx * 3.05, -1.25, 0.6), Vector3.new(0.3, 1.7, 8.6), WHITE)
		text(sill, if sx < 0 then Enum.NormalId.Left else Enum.NormalId.Right, "STATION 67", RED, 60)
		part(m, root, "Pillar", C(sx * 2.85, 0.9, -2.1), Vector3.new(0.35, 3.3, 0.35), RED)
		part(m, root, "Pillar", C(sx * 2.85, 0.9, 0.9), Vector3.new(0.35, 3.3, 0.35), RED)
		part(m, root, "Pillar", C(sx * 2.85, 0.9, 4.1), Vector3.new(0.35, 3.3, 0.35), RED)
		part(m, root, "Step", C(sx * 3.3, -2.9, -0.4), Vector3.new(0.7, 0.25, 3), DARK)
		-- skids + struts
		part(m, root, "Skid", C(sx * 2.7, -4.2, 0.4) * Y90, Vector3.new(10, 0.5, 0.5), DARK, { shape = Enum.PartType.Cylinder, collide = true })
		part(m, root, "SkidTip", C(sx * 2.7, -3.95, -4.6) * CFrame.Angles(math.rad(-35), 0, 0), Vector3.new(0.5, 0.5, 1.4), DARK)
		for _, sz in { -2.2, 3 } do
			part(m, root, "Strut", C(sx * 2.55, -3.45, sz), Vector3.new(0.35, 1.5, 0.35), DARK)
		end
	end
	-- seats (inside the open cabin, all facing the nose)
	local seatPos = {
		{ "PilotSeat", -1.35, -1.2 },
		{ "RideSeat1", 1.35, -1.2 },
		{ "RideSeat2", -1.35, 2.2 },
		{ "RideSeat3", 1.35, 2.2 },
	}
	for _, s in seatPos do
		local seat = Instance.new("Seat")
		seat.Name = s[1]
		seat.Size = Vector3.new(2, 0.6, 2)
		seat.CFrame = C(s[2], -1.6, s[3])
		seat.Color = DARK
		seat.Material = Enum.Material.Fabric
		seat.TopSurface = Enum.SurfaceType.Smooth
		seat.CanCollide = false
		seat.CanTouch = false -- only HeliService seats you (no sitting by bumping into it)
		seat.Massless = true
		seat.Parent = m
		weld(root, seat)
		part(m, root, "SeatBack", C(s[2], -0.4, s[3] + 1.05), Vector3.new(2, 2, 0.35), DARK)
	end
	part(m, root, "Stick", C(-1.35, -1.3, -2.4) * CFrame.Angles(math.rad(-20), 0, 0), Vector3.new(0.25, 1.4, 0.25), DARK)

	-- tail
	part(m, root, "Boom", C(0, 1.0, 10.2) * Y90, Vector3.new(11.6, 1.7, 1.7), RED, { shape = Enum.PartType.Cylinder, collide = true })
	part(m, root, "BoomStripe", C(0, 1.0, 8.2) * Y90, Vector3.new(1.2, 1.78, 1.78), WHITE, { shape = Enum.PartType.Cylinder })
	part(m, root, "BoomStripe2", C(0, 1.0, 11.6) * Y90, Vector3.new(1.2, 1.78, 1.78), WHITE, { shape = Enum.PartType.Cylinder })
	local fin = part(m, root, "Fin", C(0, 2.9, 15.4), Vector3.new(0.45, 3.6, 2.2), RED)
	text(fin, Enum.NormalId.Left, "67", WHITE, 50)
	text(fin, Enum.NormalId.Right, "67", WHITE, 50)
	part(m, root, "Stabilizer", C(0, 1.1, 14.6), Vector3.new(4, 0.3, 1.3), WHITE)
	part(m, root, "TailBeacon", C(0, 4.8, 15.6), Vector3.new(0.6, 0.6, 0.6), Color3.fromHex("#FF2A2A"), {
		shape = Enum.PartType.Ball,
		material = Enum.Material.Neon,
	})
	part(m, root, "Beacon", C(0, 3.1, 3.4), Vector3.new(0.8, 0.8, 0.8), Color3.fromHex("#FF2A2A"), {
		shape = Enum.PartType.Ball,
		material = Enum.Material.Neon,
	})

	-- main rotor: mast + hub + 4 blades on a Motor6D (the client spins Transform)
	part(m, root, "Mast", C(0, 3.4, 0.6) * Z90, Vector3.new(1.4, 0.9, 0.9), DARK, { shape = Enum.PartType.Cylinder })
	local hub = part(m, nil, "Rotor", C(0, 4.2, 0.6) * Z90, Vector3.new(0.7, 1.8, 1.8), DARK, { shape = Enum.PartType.Cylinder })
	motor("RotorMotor", root, hub, C(0, 4.2, 0.2), Z90:Inverse())
	for i, sz in { Vector3.new(26, 0.22, 1.4), Vector3.new(1.4, 0.22, 26) } do
		local blade = part(m, nil, "Blade" .. i, hub.CFrame * Z90:Inverse(), sz, WHITE, { noWeld = true })
		weld(hub, blade)
		for _, tip in { -1, 1 } do
			local off = if sz.X > sz.Z then Vector3.new(tip * 12.2, 0, 0) else Vector3.new(0, 0, tip * 12.2)
			local tipSize = if sz.X > sz.Z then Vector3.new(1.6, 0.24, 1.42) else Vector3.new(1.42, 0.24, 1.6)
			local t = part(m, nil, "BladeTip", hub.CFrame * Z90:Inverse() * CFrame.new(off), tipSize, RED, { noWeld = true })
			weld(hub, t)
		end
	end

	-- tail rotor (spins about X)
	local tail = part(m, nil, "TailRotor", C(0.55, 2.9, 15.6), Vector3.new(0.3, 0.5, 0.5), DARK)
	motor("TailMotor", root, tail, C(0.55, 2.9, 15.2))
	for i, sz in { Vector3.new(0.18, 3.4, 0.45), Vector3.new(0.18, 0.45, 3.4) } do
		local b = part(m, nil, "TailBlade" .. i, tail.CFrame, sz, WHITE, { noWeld = true })
		weld(tail, b)
	end

	-- bambi bucket on a rope (Motor6D so the client can drop it to the ground / sway it)
	local bellyAtt = Instance.new("Attachment")
	bellyAtt.Name = "BellyAtt"
	bellyAtt.Position = Vector3.new(0, HeliBuilder.BellyY - 0.4, 0.2)
	bellyAtt.Parent = root
	local bucketY = HeliBuilder.BellyY - rope - 1.6
	local bucket = part(m, nil, "Bucket", C(0, bucketY, 0.6) * Z90, Vector3.new(3.2, 4, 4), ORANGE, {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.Fabric,
	})
	motor("BucketMotor", root, bucket, C(0, bucketY, 0.2), Z90:Inverse())
	local rim = part(m, nil, "BucketRim", bucket.CFrame * C(1.55, 0, 0), Vector3.new(0.35, 4.3, 4.3), DARK, {
		shape = Enum.PartType.Cylinder,
		noWeld = true,
	})
	weld(bucket, rim)
	local band = part(m, nil, "BucketBand", bucket.CFrame * C(0.2, 0, 0), Vector3.new(0.6, 4.08, 4.08), WHITE, {
		shape = Enum.PartType.Cylinder,
		noWeld = true,
	})
	weld(bucket, band)
	local water = part(m, nil, "BucketWater", bucket.CFrame * C(1.45, 0, 0), Vector3.new(0.3, 3.5, 3.5), WATER, {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.Glass,
		transparency = 1,
		noWeld = true,
	})
	weld(bucket, water)
	local top = Instance.new("Attachment")
	top.Name = "BucketTop"
	top.Position = Vector3.new(1.7, 0, 0) -- the cylinder's +X is world up
	top.Parent = bucket
	local r = Instance.new("RopeConstraint")
	r.Name = "Rope"
	r.Attachment0 = bellyAtt
	r.Attachment1 = top
	r.Length = rope + 2
	r.Visible = true
	r.Thickness = 0.22
	r.Color = BrickColor.new("Really black")
	r.Parent = root

	local pour = Instance.new("ParticleEmitter")
	pour.Name = "Pour"
	pour.Enabled = false
	pour.Texture = "rbxasset://textures/particles/smoke_main.dds"
	pour.Color = ColorSequence.new(WATER, Color3.fromHex("#E8F8FF"))
	pour.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 7) })
	pour.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 1) })
	pour.Lifetime = NumberRange.new(0.6, 1.1)
	pour.Speed = NumberRange.new(30, 45)
	pour.Acceleration = Vector3.new(0, -60, 0)
	pour.SpreadAngle = Vector2.new(18, 18)
	pour.EmissionDirection = Enum.NormalId.Left -- the cylinder's -X = world down
	pour.Rate = 0
	pour.Parent = bucket

	-- everything but the hull: no collisions, no raycast hits (crosshairs, hose aim, ground rays)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d ~= root and d.Name ~= "Skid" and d.Name ~= "Boom" then
			d.CanCollide = false
			d.CanQuery = false
		end
	end
	return m
end

return HeliBuilder
