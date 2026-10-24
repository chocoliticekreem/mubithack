--!nonstrict
-- WorldKit: prebuilt by Forge (forge/kit/modules/WorldKit.luau). Do not rewrite it; require it.
-- Builds a whole amusement park from parts and Terrain (no asset ids): grass ground with paved paths and
-- ponds, a warm afternoon sky with haze and clouds, a fenced perimeter with a tree line, hills and mountains,
-- the entrance gate and lobby plaza, and one big animated landmark per obby zone, dressed with food stalls,
-- balloons, string lights, lamps, benches and trees. buildPark runs on the server; client() in a LocalScript
-- runs the rides' motion on each client.
--
-- Park-local frame: the origin is the hub on the ground, the entrance is at +Z, LookVector points into the park.
-- Zone 1 starts at the top of the START stairs beside the lobby; zones 2..n sit on a ring around the hub. Every
-- zone's course starts on the circle r = 0.64 * size / 2 and runs along its clockwise tangent (rides on the
-- course's right). The park is built around the courses themselves: each one is measured from the level data
-- ObbyKit will build (its turns included), kept clear (nothing taller than 6 studs within 40 studs of it, from
-- 24 studs behind its start to 40 past its end) and dressed from start to end, and the fence, the tree line and
-- the land beyond go round wherever a course leads (up to 12 zones at size 1600: more crowd the start towers).
local RunService = game:GetService("RunService")
local Lighting = game:GetService("Lighting")
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local WorldKit = {}
WorldKit.VERSION = 2

local TAU = math.pi * 2
local rgb = Color3.fromRGB
local v3 = Vector3.new
local M = Enum.Material
local CYL, BALL = Enum.PartType.Cylinder, Enum.PartType.Ball
local FRONT, BACK = Enum.NormalId.Front, Enum.NormalId.Back
local UPRIGHT = CFrame.Angles(0, 0, math.rad(90)) -- a Cylinder's axis is its local X: this stands it up
local ALONG_Z = CFrame.Angles(0, math.rad(90), 0) -- ... and this lays it along local Z

local C = {
	cream = rgb(255, 244, 224),
	white = rgb(250, 250, 252),
	gold = rgb(255, 196, 61),
	red = rgb(232, 52, 68),
	wood = rgb(170, 116, 74),
	darkWood = rgb(110, 72, 48),
	iron = rgb(44, 42, 54),
	metal = rgb(140, 146, 160),
	stone = rgb(208, 198, 182),
	paving = rgb(226, 198, 156),
	brick = rgb(198, 102, 78),
	soil = rgb(96, 66, 46),
	trunk = rgb(122, 86, 58),
	water = rgb(84, 198, 240),
	ink = rgb(38, 30, 52),
	warm = rgb(255, 236, 170),
	sawdust = rgb(226, 196, 146),
}
local BRIGHT = {
	rgb(255, 79, 109), rgb(255, 196, 41), rgb(62, 201, 245), rgb(88, 214, 92),
	rgb(155, 92, 255), rgb(255, 138, 61), rgb(255, 110, 199),
}
local GREENS = { rgb(80, 170, 74), rgb(56, 140, 64), rgb(120, 194, 84), rgb(96, 182, 98) }
local BULBS = { rgb(255, 240, 180), rgb(255, 96, 120), rgb(255, 214, 80), rgb(110, 210, 255), rgb(140, 255, 150) }

-- landmark kind -> sign, default zone name and palette, course start height above the ground, and footprint
-- at scale 1 (hx: half width along the ring, front: depth toward the hub, back: depth away from it)
local KINDS = {
	circus = { sign = "BIG TOP", name = "Grand Entrance", palette = { "#E63946", "#FFC23D", "#3A86FF" }, height = 32,
		hx = 52, front = 56, back = 52 },
	carousel = { sign = "CAROUSEL", name = "Carousel", palette = { "#FF5FA8", "#FFC23D", "#6EC6FF" }, height = 44,
		hx = 31, front = 31, back = 31 },
	bumper = { sign = "BUMPER CARS", name = "Bumper Cars", palette = { "#22B8EE", "#FFD23F", "#FF4F6D" }, height = 44,
		hx = 38, front = 34, back = 28 },
	teacups = { sign = "TEACUPS", name = "Teacups", palette = { "#A77BFF", "#5ED6B4", "#FF8EC2" }, height = 46,
		hx = 35, front = 35, back = 35 },
	ferris = { sign = "FERRIS WHEEL", name = "Ferris Wheel", palette = { "#FF7A2F", "#3FB8F5", "#FFE066" }, height = 64,
		hx = 48, front = 24, back = 18 },
	flume = { sign = "LOG FLUME", name = "Log Flume", palette = { "#1FA896", "#2F7BFF", "#F4D06F" }, height = 50,
		hx = 92, front = 40, back = 48 },
	haunted = { sign = "HAUNTED HOUSE", name = "Haunted House", palette = { "#6A3FB5", "#7CFF6B", "#FF8A3D" },
		height = 52, hx = 36, front = 30, back = 22 },
	pirate = { sign = "PIRATE SHIP", name = "Pirate Ship", palette = { "#D7263D", "#F2C14E", "#24407A" }, height = 52,
		hx = 40, front = 30, back = 22 },
	coaster = { sign = "ROLLER COASTER", name = "Roller Coaster", palette = { "#E63946", "#FFD23F", "#1D3557" },
		height = 60, hx = 92, front = 36, back = 40 },
	fireworks = { sign = "FIREWORKS", name = "Fireworks Finale", palette = { "#3A2E8F", "#FFC23D", "#FF4FA3" },
		height = 70, hx = 48, front = 38, back = 22 },
	droptower = { sign = "DROP TOWER", name = "Drop Tower", palette = { "#E63946", "#FFF4E0", "#3A86FF" }, height = 56,
		hx = 17, front = 17, back = 17 },
}
local THEME_KIND = {
	entrance = "circus", circus = "circus", carousel = "carousel", bumper = "bumper", teacups = "teacups",
	ferris = "ferris", flume = "flume", haunted = "haunted", pirate = "pirate", coaster = "coaster",
	finale = "fireworks", fireworks = "fireworks", droptower = "droptower",
}
local KEYWORDS = {
	{ "coaster", { "coaster", "roller" } }, { "ferris", { "ferris", "wheel" } },
	{ "carousel", { "carousel", "merry", "horse" } }, { "teacups", { "teacup", "tea", "cup" } },
	{ "bumper", { "bumper", "dodgem" } }, { "flume", { "flume", "log", "splash", "water", "river" } },
	{ "haunted", { "haunt", "ghost", "spook", "horror", "scary" } }, { "pirate", { "pirate", "ship", "boat", "sea" } },
	{ "fireworks", { "firework", "finale", "final", "rocket" } }, { "droptower", { "drop", "freefall", "tower" } },
	{ "circus", { "circus", "tent", "big top", "entrance", "gate", "welcome", "midway", "arcade" } },
}
local FALLBACK_KINDS = { "circus", "carousel", "teacups", "ferris", "droptower", "bumper", "pirate", "coaster" }
WorldKit.Themes = { "entrance", "carousel", "bumper", "teacups", "ferris", "flume", "haunted", "pirate", "coaster", "finale" }

-- ============================================================== parts

local made = 0 -- parts created since the last buildPark started

local function mk(class: string, parent: Instance?, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?,
	solid: boolean?, shape: Enum.PartType?): BasePart
	local p = Instance.new(class) :: any
	p.Anchored = true
	p.CanTouch = false
	p.CanCollide = solid == true
	p.CanQuery = solid == true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = mat or M.SmoothPlastic
	p.Color = color
	if shape then
		p.Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	if not solid and size.X * size.Y * size.Z < 6 then
		p.CastShadow = false
	end
	p.Parent = parent
	made += 1
	return p
end

local function block(parent, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, solid: boolean?)
	return mk("Part", parent, size, cf, color, mat, solid)
end

local function wedge(parent, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?, solid: boolean?)
	return mk("WedgePart", parent, size, cf, color, mat, solid)
end

local function ball(parent, d: number, pos: Vector3, color: Color3, mat: Enum.Material?, solid: boolean?)
	return mk("Part", parent, v3(d, d, d), CFrame.new(pos), color, mat, solid, BALL)
end

-- an upright cylinder centred on cf (its axis is cf.UpVector)
local function cyl(parent, d: number, h: number, cf: CFrame, color: Color3, mat: Enum.Material?, solid: boolean?)
	return mk("Part", parent, v3(h, d, d), cf * UPRIGHT, color, mat, solid, CYL)
end

-- an ellipsoid (a part with a sphere mesh), for cypress trees and clouds of candy floss
local function blob(parent, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?)
	local p = mk("Part", parent, size, cf, color, mat, false)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	return p
end

-- ============================================================== geometry

local function frameAlong(a: Vector3, b: Vector3, upHint: Vector3?): (CFrame, number)
	local d = b - a
	local len = d.Magnitude
	if len < 1e-4 then
		return CFrame.new(a), 0
	end
	local x = d / len
	local up = upHint or Vector3.yAxis
	if math.abs(x:Dot(up)) > 0.985 then
		up = if math.abs(x.X) > 0.9 then Vector3.zAxis else Vector3.xAxis
	end
	local y = (up - x * up:Dot(x)).Unit
	return CFrame.fromMatrix((a + b) / 2, x, y), len
end

-- a cylinder from a to b
local function rod(parent, a: Vector3, b: Vector3, d: number, color: Color3, mat: Enum.Material?, solid: boolean?)
	local cf, len = frameAlong(a, b)
	if len < 0.05 then
		return nil
	end
	return mk("Part", parent, v3(len, d, d), cf, color, mat, solid, CYL)
end

-- a box from a to b: w is its width (local Z), h its height (local Y, near upHint)
local function bar(parent, a: Vector3, b: Vector3, w: number, h: number, color: Color3, mat: Enum.Material?,
	solid: boolean?, upHint: Vector3?)
	local cf, len = frameAlong(a, b, upHint)
	if len < 0.05 then
		return nil
	end
	return mk("Part", parent, v3(len, h, w), cf, color, mat, solid)
end

-- a filled triangle from two wedges
local function tri(parent, a: Vector3, b: Vector3, c: Vector3, color: Color3, mat: Enum.Material?, thick: number?)
	local ab, ac, bc = b - a, c - a, c - b
	local abd, acd, bcd = ab:Dot(ab), ac:Dot(ac), bc:Dot(bc)
	if abd > acd and abd > bcd then
		c, a = a, c
	elseif acd > bcd and acd > abd then
		a, b = b, a
	end
	ab, ac, bc = b - a, c - a, c - b
	local n = ac:Cross(ab)
	if n.Magnitude < 1e-4 then
		return
	end
	local right = n.Unit
	local up = bc:Cross(right).Unit
	local back = bc.Unit
	local height = math.abs(ab:Dot(up))
	local d1, d2 = math.abs(ab:Dot(back)), math.abs(ac:Dot(back))
	local t = thick or 0.3
	if height < 0.02 then
		return
	end
	if d1 > 0.02 then
		mk("WedgePart", parent, v3(t, height, d1), CFrame.fromMatrix((a + b) / 2, right, up, back), color, mat)
	end
	if d2 > 0.02 then
		mk("WedgePart", parent, v3(t, height, d2), CFrame.fromMatrix((a + c) / 2, -right, up, -back), color, mat)
	end
end

local function circlePoint(base: CFrame, r: number, a: number, y: number?): Vector3
	return base * v3(math.cos(a) * r, y or 0, math.sin(a) * r)
end

-- distance from (px, pz) to the segment a-b in the XZ plane
local function segDist(px, pz, ax, az, bx, bz): number
	local dx, dz = bx - ax, bz - az
	local len2 = dx * dx + dz * dz
	local t = if len2 > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) else 0
	local qx, qz = ax + dx * t - px, az + dz * t - pz
	return math.sqrt(qx * qx + qz * qz)
end

-- the points of a polyline (Vector3s, judged in X and Z) a straight course needs: drops every point within
-- `tol` studs of the line through its kept neighbours (Douglas-Peucker)
local function simplify(pts, tol: number)
	local n = #pts
	if n <= 2 then
		return pts
	end
	local keep = { [1] = true, [n] = true }
	local stack = { { 1, n } }
	while #stack > 0 do
		local span = table.remove(stack)
		local a, b = span[1], span[2]
		local pa, pb = pts[a], pts[b]
		local best, at = tol, nil
		for i = a + 1, b - 1 do
			local d = segDist(pts[i].X, pts[i].Z, pa.X, pa.Z, pb.X, pb.Z)
			if d > best then
				best, at = d, i
			end
		end
		if at then
			keep[at] = true
			table.insert(stack, { a, at })
			table.insert(stack, { at, b })
		end
	end
	local out = {}
	for i = 1, n do
		if keep[i] then
			table.insert(out, pts[i])
		end
	end
	return out
end

-- a striped cone standing on base (its axis is base.UpVector); returns the apex
local function cone(parent, base: CFrame, r: number, h: number, n: number, colors, mat: Enum.Material?, a0: number?)
	local apex = base * v3(0, h, 0)
	for i = 0, n - 1 do
		local a, b = (a0 or 0) + i / n * TAU, (a0 or 0) + (i + 1) / n * TAU
		tri(parent, apex, circlePoint(base, r, a), circlePoint(base, r, b), colors[i % #colors + 1], mat)
	end
	return apex
end

-- a striped band of quads from radius r1 at the base up to radius r2 at height h
local function frustum(parent, base: CFrame, r1: number, r2: number, h: number, n: number, colors, mat, a0: number?)
	for i = 0, n - 1 do
		local a, b = (a0 or 0) + i / n * TAU, (a0 or 0) + (i + 1) / n * TAU
		local p0, p1 = circlePoint(base, r1, a), circlePoint(base, r1, b)
		local q0, q1 = circlePoint(base, r2, a, h), circlePoint(base, r2, b, h)
		local col = colors[i % #colors + 1]
		tri(parent, p0, p1, q1, col, mat)
		tri(parent, p0, q1, q0, col, mat)
	end
end

-- a ring of n straight segments in center's XZ plane (w: radial width, h: height along center.UpVector)
local function ring(parent, center: CFrame, r: number, n: number, w: number, h: number, color: Color3,
	mat: Enum.Material?, solid: boolean?)
	for i = 0, n - 1 do
		local p, q = circlePoint(center, r, i / n * TAU), circlePoint(center, r, (i + 1) / n * TAU)
		local d = (q - p).Unit
		bar(parent, p - d * w * 0.5, q + d * w * 0.5, w, h, color, mat, solid, center.UpVector)
	end
end

local function bulbRing(parent, center: CFrame, r: number, n: number, d: number, colors, a0: number?)
	for i = 0, n - 1 do
		ball(parent, d, circlePoint(center, r, (a0 or 0) + i / n * TAU), colors[i % #colors + 1], M.Neon)
	end
end

-- three helpers in a builder's own frame: at(x, y, z) -> CFrame, pt -> Vector3, S -> size, all scaled by s
local function space(cf: CFrame, s: number)
	return function(x, y, z)
		return cf * CFrame.new(x * s, y * s, z * s)
	end, function(x, y, z)
		return cf * v3(x * s, y * s, z * s)
	end, function(x, y, z)
		return v3(x * s, y * s, z * s)
	end
end

-- centripetal Catmull-Rom through points, sampled about every `step` studs; seg[k] = the span sample k is on
local function spline(points, closed: boolean, step: number)
	local n = #points
	local out, seg = {}, {}
	local function P(i)
		if closed then
			return points[(i - 1) % n + 1]
		end
		return points[math.clamp(i, 1, n)]
	end
	for i = 1, (if closed then n else n - 1) do
		local p0, p1, p2, p3 = P(i - 1), P(i), P(i + 1), P(i + 2)
		local t0 = 0
		local t1 = t0 + math.max((p1 - p0).Magnitude, 1e-3) ^ 0.5
		local t2 = t1 + math.max((p2 - p1).Magnitude, 1e-3) ^ 0.5
		local t3 = t2 + math.max((p3 - p2).Magnitude, 1e-3) ^ 0.5
		local count = math.max(2, math.ceil((p2 - p1).Magnitude / step))
		for k = 0, count - 1 do
			local t = t1 + (t2 - t1) * k / count
			local a1 = p0 * ((t1 - t) / (t1 - t0)) + p1 * ((t - t0) / (t1 - t0))
			local a2 = p1 * ((t2 - t) / (t2 - t1)) + p2 * ((t - t1) / (t2 - t1))
			local a3 = p2 * ((t3 - t) / (t3 - t2)) + p3 * ((t - t2) / (t3 - t2))
			local b1 = a1 * ((t2 - t) / (t2 - t0)) + a2 * ((t - t0) / (t2 - t0))
			local b2 = a2 * ((t3 - t) / (t3 - t1)) + a3 * ((t - t1) / (t3 - t1))
			table.insert(out, b1 * ((t2 - t) / (t2 - t1)) + b2 * ((t - t1) / (t2 - t1)))
			table.insert(seg, i)
		end
	end
	if not closed then
		table.insert(out, points[n])
		table.insert(seg, n - 1)
	end
	return out, seg
end

-- seconds at which a rider reaches each sample of a closed path, given speed(k) in studs/s
local function timetable(points, s: number, speed)
	local n = #points
	local times = { 0 }
	for k = 1, n do
		local ds = (points[k % n + 1] - points[k]).Magnitude * s
		times[k + 1] = times[k] + ds / math.max(speed(k), 0.5)
	end
	return times
end

-- ============================================================== text, wires, string lights

local function textOn(part: BasePart, face: Enum.NormalId, text: string, color: Color3, stroke: Color3?, font, pps)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.LightInfluence = 0
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pps or 24
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(0.92, 0.84)
	t.Position = UDim2.fromScale(0.04, 0.08)
	t.Font = font or Enum.Font.LuckiestGuy
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color
	t.Parent = g
	if stroke then
		local st = Instance.new("UIStroke")
		st.Color = stroke
		st.Thickness = 3
		st.Parent = t
	end
	g.Parent = part
	return g
end

local function attach(part: BasePart, at: Vector3, axis: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Parent = part
	local other = if math.abs(axis.X) > 0.9 then Vector3.zAxis else Vector3.xAxis
	a.WorldCFrame = CFrame.fromMatrix(at, axis, (other - axis * other:Dot(axis)).Unit)
	return a
end

-- a thin wire (Beam) from a to b that sags `sag` studs; returns the Bezier control points
local function wire(aPart: BasePart, a: Vector3, bPart: BasePart, b: Vector3, sag: number, color: Color3?, width: number?)
	local c = sag / 0.75
	local beam = Instance.new("Beam")
	beam.Attachment0 = attach(aPart, a, v3(0, -1, 0))
	beam.Attachment1 = attach(bPart, b, v3(0, 1, 0))
	beam.CurveSize0, beam.CurveSize1 = c, c
	beam.Width0, beam.Width1 = width or 0.14, width or 0.14
	beam.Segments = if sag > 0 then 16 else 1
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(color or rgb(52, 46, 58))
	beam.Parent = aPart
	return a - v3(0, c, 0), b - v3(0, c, 0)
end

local function bezier(a: Vector3, c0: Vector3, c1: Vector3, b: Vector3, t: number): Vector3
	local u = 1 - t
	return a * (u * u * u) + c0 * (3 * u * u * t) + c1 * (3 * u * t * t) + b * (t * t * t)
end

-- string lights: a sagging wire with n glowing bulbs
local function lights(parent, aPart: BasePart, a: Vector3, bPart: BasePart, b: Vector3, sag: number, n: number,
	colors, d: number?)
	local c0, c1 = wire(aPart, a, bPart, b, sag)
	for i = 1, n do
		local p = bezier(a, c0, c1, b, i / (n + 1))
		ball(parent, d or 0.8, p - v3(0, 0.32, 0), (colors or BULBS)[(i - 1) % #(colors or BULBS) + 1], M.Neon)
	end
end

-- bunting: a wire with triangular pennants hanging from it
local function bunting(parent, aPart: BasePart, a: Vector3, bPart: BasePart, b: Vector3, sag: number, n: number, colors)
	local c0, c1 = wire(aPart, a, bPart, b, sag, rgb(240, 240, 240), 0.1)
	for i = 1, n do
		local t0, t1 = (i - 0.85) / n, (i - 0.15) / n
		local p, q = bezier(a, c0, c1, b, t0), bezier(a, c0, c1, b, t1)
		tri(parent, p, q, (p + q) / 2 - v3(0, 2.4, 0), colors[(i - 1) % #colors + 1], M.SmoothPlastic, 0.12)
	end
end

local function pennant(parent, top: Vector3, dir: Vector3, len: number, color: Color3)
	tri(parent, top, top - v3(0, len * 0.55, 0), top - v3(0, len * 0.27, 0) + dir * len, color, M.SmoothPlastic, 0.12)
end

-- ============================================================== animation: motion as data, run on the clients

-- A moving root carries its motion as attributes: WKMotion (a STEPS kind), WKRest (the CFrame it was built at),
-- WKPivot and the kind's numbers. WorldKit.client() (a LocalScript) runs every mover near the camera once per
-- rendered frame. Until a client says it does (the WorldKitMotion remote), the server runs the movers that have a
-- player within SERVER_RANGE studs, 30 times a second; anchored CFrames are not smoothed on clients, so that is a
-- fallback, not the way to show the park.
local MOVER_TAG = "WorldKitMover"
local REMOTE = "WorldKitMotion"
local EPOCH = 1.7e9
local SERVER_RANGE = 400
local CLIENT_RANGE = 900
local STEP = 1 / 30

local STEPS = {} -- kind -> function(root, onClient) -> step(t), stop?
local PATHS = {} -- ride path name -> function(cf, s) -> frameAt, total, P, seg, U (filled in with the rides)
local pathCache = {}

-- one clock for the server and every client, so a ride is in the same place on all of them
local function now(): number
	return workspace:GetServerTimeNow() - EPOCH
end

-- an angle of t * w turns, folded into one turn: CFrame angles are 32-bit floats, and t is a large number of seconds
local function turnAt(t: number, w: number, phase: number?): number
	return (t * w + (phase or 0)) % TAU
end

local function pathOf(name: string, cf: CFrame, s: number)
	local key = name .. "|" .. tostring(cf) .. "|" .. tostring(s)
	local hit = pathCache[key]
	if not hit then
		hit = table.pack(PATHS[name](cf, s))
		pathCache[key] = hit
	end
	return table.unpack(hit, 1, hit.n)
end

local function wk(root: Instance, key: string): any
	return root:GetAttribute("WK" .. key)
end

local serverMovers = {}
local clientDriven = false
local loopOn = false

local function ensureLoop()
	if loopOn then
		return
	end
	loopOn = true
	local remote = ReplicatedStorage:FindFirstChild(REMOTE)
	if not remote then
		remote = Instance.new("RemoteEvent")
		remote.Name = REMOTE
		remote.Parent = ReplicatedStorage
	end
	remote.OnServerEvent:Connect(function()
		clientDriven = true
	end)
	local acc, nextScan = 0, 0
	local conn
	conn = RunService.Heartbeat:Connect(function(dt)
		if clientDriven then
			conn:Disconnect()
			for _, m in serverMovers do
				if m.stop then
					pcall(m.stop)
				end
			end
			return
		end
		acc += dt
		if acc < STEP then
			return
		end
		acc = 0
		if os.clock() >= nextScan then
			nextScan = os.clock() + 0.5
			local spots = {}
			for _, pl in Players:GetPlayers() do
				local hrp = pl.Character and pl.Character:FindFirstChild("HumanoidRootPart")
				if hrp then
					table.insert(spots, hrp.Position)
				end
			end
			for _, m in serverMovers do
				m.on = false
				for _, p in spots do
					if (p - m.at).Magnitude < SERVER_RANGE then
						m.on = true
						break
					end
				end
			end
		end
		local t = now()
		for i = #serverMovers, 1, -1 do
			local m = serverMovers[i]
			if m.root.Parent == nil then
				table.remove(serverMovers, i)
			elseif m.on and m.root:IsDescendantOf(workspace) then
				local ok, err = pcall(m.step, t)
				if not ok then
					table.remove(serverMovers, i)
					warn("[WorldKit] an animation stopped: " .. tostring(err))
				end
			end
		end
	end)
end

-- root moves as STEPS[kind] says; params (Pivot, Speed, ...) become its WK attributes. Built in Edit, it stays still.
local function motion(root: BasePart, kind: string, params)
	root:SetAttribute("WKMotion", kind)
	root:SetAttribute("WKRest", root.CFrame)
	for k, v in params do
		root:SetAttribute("WK" .. k, v)
	end
	CollectionService:AddTag(root, MOVER_TAG)
	if not (RunService:IsServer() and RunService:IsRunning()) then
		return
	end
	local ok, step, stop = pcall(STEPS[kind], root, false)
	if ok and step then
		local pivot = params.Pivot
		table.insert(serverMovers, { root = root, step = step, stop = stop, on = false,
			at = if typeof(pivot) == "CFrame" then pivot.Position else root.Position })
		ensureLoop()
	end
end

-- weld every part of model to root and make root the only anchored part: moving root then moves one CFrame
local function rig(model: Model, root: BasePart)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			if d ~= root then
				local w = Instance.new("WeldConstraint")
				w.Part0 = root
				w.Part1 = d
				w.Parent = d
				d.Anchored = false
				d.Massless = true
			end
		end
	end
	root.Anchored = true
	model.PrimaryPart = root
end

-- where a rider (cart, log) is on a closed sampled path at time tau: frameAt(tau, hint) -> (CFrame, hint)
local function pathFrames(cf: CFrame, s: number, P, U, times, lift: number?)
	local n = #P
	local function frameAt(tau: number, last: number): (CFrame, number)
		if tau < times[last] then
			last = 1
		end
		while times[last + 1] <= tau do
			last += 1
		end
		local k, k2 = last, last % n + 1
		local f = (tau - times[k]) / math.max(times[k + 1] - times[k], 1e-6)
		local p = P[k]:Lerp(P[k2], f)
		local tv = (P[k2] - P[k]).Unit
		local rg = tv:Cross(U[k]:Lerp(U[k2], f)).Unit
		local up = rg:Cross(tv).Unit
		return cf * CFrame.fromMatrix(p * s + up * (lift or 0), rg, up), last
	end
	return frameAt, times[n + 1]
end

-- turns round the pivot's Y (or Z) axis: carousel, teacup turntable, sky swings, Ferris wheel
function STEPS.spin(root)
	local pivot, w, axis = wk(root, "Pivot"), wk(root, "Speed"), wk(root, "Axis")
	local rel = pivot:ToObjectSpace(wk(root, "Rest"))
	return function(t)
		local a = turnAt(t, w)
		root.CFrame = pivot * (if axis == "Z" then CFrame.Angles(0, 0, a) else CFrame.Angles(0, a, 0)) * rel
	end
end

-- swings to and fro round the pivot's Z axis: the pirate ship
function STEPS.swing(root)
	local pivot, amp, period = wk(root, "Pivot"), wk(root, "Amp"), wk(root, "Period")
	local rel = pivot:ToObjectSpace(wk(root, "Rest"))
	return function(t)
		root.CFrame = pivot * CFrame.Angles(0, 0, math.sin(t * TAU / period) * amp) * rel
	end
end

-- a Ferris wheel gondola: its hanger goes round the axle and it stays level, swaying a little
function STEPS.orbit(root)
	local axle, r, a0, w, ph = wk(root, "Pivot"), wk(root, "Radius"), wk(root, "A0"), wk(root, "Speed"), wk(root, "Phase")
	local rel = (axle * CFrame.new(math.cos(a0) * r, math.sin(a0) * r, 0)):ToObjectSpace(wk(root, "Rest"))
	return function(t)
		local a = turnAt(t, w, a0)
		root.CFrame = axle * CFrame.new(math.cos(a) * r, math.sin(a) * r, 0) * CFrame.Angles(0, 0, math.sin(t * 1.3 + ph) * 0.05)
			* rel
	end
end

-- a teacup: rides the turntable round the ride's centre and spins on its saucer
function STEPS.cup(root)
	local cf, a0, w, r, h = wk(root, "Pivot"), wk(root, "A0"), wk(root, "Speed"), wk(root, "Radius"), wk(root, "Height")
	local spin, ph = wk(root, "Spin"), wk(root, "Phase")
	local rel = (cf * CFrame.Angles(0, a0, 0) * CFrame.new(r, h, 0)):ToObjectSpace(wk(root, "Rest"))
	return function(t)
		root.CFrame = cf * CFrame.Angles(0, turnAt(t, w, a0), 0) * CFrame.new(r, h, 0) * CFrame.Angles(0, turnAt(t, spin, ph), 0)
			* rel
	end
end

local function bumperAt(i: number, s: number, t: number): (number, number)
	local w1, w2 = 0.31 + i * 0.047, 0.23 + i * 0.061
	return math.sin(w1 * t + i * 1.7) * 26 * s, math.sin(w2 * t + i * 2.3 + 1) * 17 * s
end

-- a bumper car: wanders the floor on two sine waves, facing the way it goes
function STEPS.bumper(root)
	local cf, s, i = wk(root, "Pivot"), wk(root, "Scale"), wk(root, "Index")
	local x0, z0 = bumperAt(i, s, 0)
	local rel = (cf * CFrame.new(x0, 1.4 * s, z0)):ToObjectSpace(wk(root, "Rest"))
	return function(t)
		local x, z = bumperAt(i, s, t)
		local x2, z2 = bumperAt(i, s, t + 0.15)
		root.CFrame = cf * CFrame.new(x, 1.4 * s, z) * CFrame.Angles(0, math.atan2(-(x2 - x), -(z2 - z)), 0) * rel
	end
end

-- a rider on a closed track (coaster cart, flume log, train car): PATHS[WKPath] at WKOffset seconds ahead
function STEPS.ride(root)
	local frameAt, total = pathOf(wk(root, "Path"), wk(root, "Pivot"), wk(root, "Scale"))
	local offset = wk(root, "Offset") or 0
	local rel = (frameAt(offset % total, 1)):ToObjectSpace(wk(root, "Rest"))
	local last = 1
	return function(t)
		local f
		f, last = frameAt((t + offset) % total, last)
		root.CFrame = f * rel
	end
end

-- the drop tower's ring: waits, climbs for 8 s, hangs at the top, falls in 1.6 s
function STEPS.drop(root)
	local cf, s = wk(root, "Pivot"), wk(root, "Scale")
	local rel = cf:ToObjectSpace(wk(root, "Rest"))
	return function(t)
		local c = t % 16
		local y = 0
		if c >= 3 and c < 11 then
			y = (c - 3) / 8 * 102
		elseif c >= 11 and c < 13 then
			y = 102
		elseif c >= 13 and c < 14.6 then
			local f = (c - 13) / 1.6
			y = 102 * (1 - f * f)
		end
		root.CFrame = cf * CFrame.new(0, y * s, 0) * rel
	end
end

-- the haunted house's ghost: drifts to and fro and bobs
function STEPS.ghost(root)
	local cf, s = wk(root, "Pivot"), wk(root, "Scale")
	local rel = cf:ToObjectSpace(wk(root, "Rest"))
	return function(t)
		root.CFrame = cf * CFrame.new(math.sin(t * 0.4) * 4 * s, math.sin(t * 1.6) * 1.5 * s, 0)
			* CFrame.Angles(0, math.sin(t * 0.5) * 0.6, 0) * rel
	end
end

local function marked(model: Instance?, attr: string)
	local out = {}
	if model then
		for _, d in model:GetDescendants() do
			if d:GetAttribute(attr) ~= nil then
				table.insert(out, d)
			end
		end
	end
	return out
end

-- the haunted house's lit windows (WKGlass) flicker between their colours and dark
function STEPS.flicker(root)
	local glass, looks
	local nextAt = 0
	local rng = Random.new()
	return function(t)
		if t < nextAt then
			return
		end
		nextAt = t + rng:NextNumber(0.2, 0.8)
		if not glass then
			glass = marked(root.Parent, "WKGlass")
			looks = {}
			for _, g in glass do
				table.insert(looks, g.Color)
			end
			table.insert(looks, rgb(24, 20, 30))
		end
		if #glass > 0 then
			glass[rng:NextInteger(1, #glass)].Color = looks[rng:NextInteger(1, #looks)]
		end
	end
end

-- fireworks over the stage: one burst (WKBurst emitters) every 0.9 s. A client emits the burst itself; the
-- server can only switch an emitter on for a moment, which replicates.
function STEPS.bursts(root, onClient)
	local list
	local nextAt, offAt, cur = 0, math.huge, nil
	local function stop()
		for _, e in list or {} do
			e.Enabled = false
		end
	end
	return function(t)
		if not list then
			list = marked(root.Parent, "WKBurst")
		end
		if #list == 0 then
			return
		end
		if cur and t >= offAt then
			cur.Enabled = false
			cur = nil
		end
		if t >= nextAt then
			nextAt = t + 0.9
			local e = list[math.floor(t * 7) % #list + 1]
			if onClient then
				e:Emit(e:GetAttribute("WKBurst"))
				local twin = list[(math.floor(t * 7) + 3) % #list + 1]
				if twin ~= e then
					twin:Emit(math.floor(twin:GetAttribute("WKBurst") * 0.6))
				end
			else
				cur = e
				cur.Enabled = true
				offAt = t + 0.15
			end
		end
	end, stop
end

-- ============================================================== small pieces shared by landmarks

local function railRing(m, base: CFrame, r: number, n: number, s: number, post: Color3, rail: Color3, gap: number?)
	for i = 0, n - 1 do
		local a, b = i / n * TAU, (i + 1) / n * TAU
		local mid = (a + b) / 2
		if gap and math.abs(math.atan2(math.sin(mid - gap), math.cos(mid - gap))) < TAU / n then
			continue
		end
		local p, q = circlePoint(base, r, a), circlePoint(base, r, b)
		cyl(m, 0.7 * s, 3.8 * s, CFrame.new(p + v3(0, 1.9 * s, 0)), post, nil, true)
		ball(m, 1.1 * s, p + v3(0, 4 * s, 0), C.gold)
		bar(m, p + v3(0, 3.1 * s, 0), q + v3(0, 3.1 * s, 0), 0.35 * s, 0.5 * s, rail, nil, true)
		bar(m, p + v3(0, 1.5 * s, 0), q + v3(0, 1.5 * s, 0), 0.35 * s, 0.5 * s, rail, nil, true)
	end
end

local function signBoard(m, cf: CFrame, w: number, h: number, text: string, bg: Color3, fg: Color3, frame: Color3,
	both: boolean?, font)
	block(m, v3(w + 1, h + 1, 0.4), cf, frame)
	local board = block(m, v3(w, h, 0.8), cf, bg)
	-- TextScaled stops at 100 px, so big boards get fewer pixels per stud to keep the letters filling them
	local pps = math.clamp(96 / h, 8, 48)
	textOn(board, FRONT, text, fg, C.ink, font, pps)
	if both then
		textOn(board, BACK, text, fg, C.ink, font, pps)
	end
	return board
end

local function emitter(parent: BasePart, color: Color3, rate: number, speed: NumberRange, life: NumberRange, size: number,
	spread: number): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(color)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Rate = rate
	e.Speed = speed
	e.Lifetime = life
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size), NumberSequenceKeypoint.new(1, 0) })
	e.Parent = parent
	return e
end

local function anchorPart(parent, pos: Vector3): BasePart
	local p = mk("Part", parent, v3(0.4, 0.4, 0.4), CFrame.new(pos), C.white)
	p.Transparency = 1
	return p
end

-- ============================================================== landmarks

local LM = {}
local Dress = {} -- filled in below; landmarks use a few pieces of dressing
local frontSigns = true -- a ride's own name board out front; off inside the park, where its gate arch names it

local HORSES = { rgb(255, 250, 240), rgb(248, 228, 196), rgb(84, 62, 52), rgb(255, 255, 255), rgb(200, 162, 124) }

local function horse(parent, cf: CFrame, s: number, pal, i: number)
	local body = HORSES[i % #HORSES + 1]
	local mane = if i % #HORSES == 2 then C.cream else pal[3]
	local at, _, S = space(cf, s)
	block(parent, S(1.7, 1.9, 4.4), at(0, 0, 0), body)
	block(parent, S(1.3, 2.8, 1.3), at(0, 1.5, -1.9) * CFrame.Angles(math.rad(-28), 0, 0), body)
	block(parent, S(1.15, 1.2, 2.4), at(0, 2.75, -3.0) * CFrame.Angles(math.rad(-22), 0, 0), body)
	block(parent, S(0.4, 2.2, 0.9), at(0, 1.9, -1.35) * CFrame.Angles(math.rad(-28), 0, 0), mane)
	block(parent, S(0.3, 0.7, 0.3), at(0.32, 3.55, -2.45), body)
	block(parent, S(0.3, 0.7, 0.3), at(-0.32, 3.55, -2.45), body)
	for _, side in { -0.55, 0.55 } do
		block(parent, S(0.45, 2.4, 0.45), at(side, -1.5, -1.55) * CFrame.Angles(math.rad(40), 0, 0), body)
		block(parent, S(0.45, 2.6, 0.45), at(side, -1.75, 1.6) * CFrame.Angles(math.rad(-25), 0, 0), body)
	end
	block(parent, S(0.45, 2.2, 0.5), at(0, 0.1, 2.75) * CFrame.Angles(math.rad(-40), 0, 0), mane)
	block(parent, S(1.95, 1.2, 2.0), at(0, 0.55, 0.15), pal[2])
	block(parent, S(1.85, 0.4, 1.7), at(0, 1.1, 0.15), pal[1])
end

function LM.carousel(m, cf, pal, s)
	local at, pt = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	cyl(m, 56 * s, 1 * s, at(0, 0.5, 0), C.stone, M.Cobblestone, true)
	cyl(m, 50 * s, 0.8 * s, at(0, 1.2, 0), accent, nil, true)
	railRing(m, at(0, 0, 0), 27 * s, 20, s, C.white, main, -math.pi / 2)
	local spin = Instance.new("Model")
	spin.Name = "Carousel"
	local root = cyl(spin, 6 * s, 13 * s, at(0, 8.1, 0), C.gold)
	root.Reflectance = 0.2
	cyl(spin, 46 * s, 1.2 * s, at(0, 2.2, 0), C.cream, M.WoodPlanks)
	cyl(spin, 47.5 * s, 0.7 * s, at(0, 1.95, 0), main)
	for _, y in { 4.2, 11.8 } do
		cyl(spin, 7.4 * s, 1 * s, at(0, y, 0), main)
	end
	cyl(spin, 8.4 * s, 1.4 * s, at(0, 14.4, 0), accent)
	for i = 0, 11 do
		local a = i / 12 * TAU
		local x, z = math.cos(a) * 17, math.sin(a) * 17
		rod(spin, pt(x, 2.8, z), pt(x, 15.2, z), 0.55 * s, C.gold)
		horse(spin, at(x, 6.3 + (i % 2) * 1.4, z) * CFrame.Angles(0, -a, 0), s, pal, i)
	end
	cyl(spin, 50 * s, 0.5 * s, at(0, 15.4, 0), C.cream)
	ring(spin, at(0, 14.4, 0), 25.4 * s, 18, 0.6 * s, 2.4 * s, C.gold)
	bulbRing(spin, at(0, 14.4, 0), 26 * s, 18, 0.8 * s, { C.white, hi })
	for i = 0, 17 do
		local a = (i + 0.5) / 18 * TAU
		ball(spin, 2.6 * s, pt(math.cos(a) * 25.2, 12.7, math.sin(a) * 25.2), if i % 2 == 0 then main else C.cream)
	end
	local apex = cone(spin, at(0, 15.6, 0), 26.5 * s, 9 * s, 18, { main, C.cream }, M.SmoothPlastic)
	ball(spin, 2.6 * s, apex + v3(0, 1 * s, 0), C.gold)
	local tip = apex + v3(0, 6 * s, 0)
	rod(spin, apex, tip, 0.35 * s, C.gold)
	pennant(spin, tip, cf.RightVector, 3.5 * s, accent)
	rig(spin, root)
	spin.Parent = m
	motion(root, "spin", { Pivot = cf, Speed = 0.32, Axis = "Y" })
	if frontSigns then
		signBoard(m, at(0, 3.2, -30), 16 * s, 3.2 * s, KINDS.carousel.sign, C.cream, main, C.gold)
		for _, x in { -8.6, 8.6 } do
			cyl(m, 0.6 * s, 4.8 * s, at(x, 2.4, -30), C.gold)
		end
	end
end

local function gondola(parent, G: CFrame, s: number, color: Color3)
	local at, pt = space(G, s)
	local g = Instance.new("Model")
	g.Name = "Gondola"
	local root = rod(g, pt(0, 0, 0), pt(0, -2.4, 0), 0.4 * s, C.metal)
	cyl(g, 6.2 * s, 0.6 * s, at(0, -2.6, 0), color)
	ball(g, 1.3 * s, pt(0, -2.1, 0), C.gold)
	for k = 0, 3 do
		local a = k / 4 * TAU + math.pi / 4
		rod(g, pt(math.cos(a) * 2.3, -2.8, math.sin(a) * 2.3), pt(math.cos(a) * 2.3, -5.6, math.sin(a) * 2.3), 0.3 * s,
			C.white)
	end
	cyl(g, 5.6 * s, 3 * s, at(0, -7.1, 0), color)
	cyl(g, 6 * s, 0.45 * s, at(0, -5.6, 0), C.white)
	g.Parent = parent
	return g, root
end

function LM.ferris(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	local RW, H = 44, 54
	for _, z in { -1, 1 } do
		for _, x in { -1, 1 } do
			rod(m, pt(x * 24, 0, z * 15), pt(0, H, z * 6.5), 2.4 * s, C.white, M.Metal, true)
			block(m, S(4.5, 1.2, 4.5), at(x * 24, 0.6, z * 15), C.stone, M.Concrete, true)
		end
		bar(m, pt(-17.3, 15, z * 12.6), pt(17.3, 15, z * 12.6), 1.2 * s, 1.2 * s, main, M.Metal, true)
		bar(m, pt(-9.3, 33, z * 9.8), pt(9.3, 33, z * 9.8), 1 * s, 1 * s, main, M.Metal, true)
	end
	rod(m, pt(0, H, -8), pt(0, H, 8), 3 * s, C.metal, M.Metal, true)
	block(m, S(20, 2, 15), at(0, 1, 0), C.cream, M.WoodPlanks, true)
	for k = 0, 2 do
		block(m, S(8, 0.7 * (k + 1), 2), at(0, 0.35 * (k + 1), -12.5 + k * 2), C.stone, M.Concrete, true)
	end
	local axle = at(0, H, 0)
	local wheel = Instance.new("Model")
	wheel.Name = "Wheel"
	local hub = mk("Part", wheel, S(10, 8, 8), axle * ALONG_Z, accent, nil, false, CYL)
	mk("Part", wheel, S(11, 3, 3), axle * ALONG_Z, C.gold, M.Neon, false, CYL)
	local plane = axle * CFrame.Angles(math.rad(90), 0, 0)
	for _, z in { -4, 4 } do
		ring(wheel, plane * CFrame.new(0, z * s, 0), RW * s, 32, 1.3 * s, 1.3 * s, C.white, M.Metal)
		ring(wheel, plane * CFrame.new(0, z * s, 0), (RW - 7) * s, 24, 0.6 * s, 0.6 * s, main, M.Metal)
		for i = 0, 15 do
			local a = i / 16 * TAU
			rod(wheel, axle * v3(math.cos(a) * 4 * s, math.sin(a) * 4 * s, z * s),
				axle * v3(math.cos(a) * RW * s, math.sin(a) * RW * s, z * s), 0.5 * s, C.white, M.Metal)
		end
	end
	for i = 0, 15 do
		local a = i / 16 * TAU
		local x, y = math.cos(a) * RW * s, math.sin(a) * RW * s
		rod(wheel, axle * v3(x, y, -4.8 * s), axle * v3(x, y, 4.8 * s), 0.7 * s, main, M.Metal)
	end
	for i = 0, 31 do
		local a = (i + 0.5) / 32 * TAU
		ball(wheel, 0.9 * s, axle * v3(math.cos(a) * (RW + 0.9) * s, math.sin(a) * (RW + 0.9) * s, -4.2 * s),
			BULBS[i % #BULBS + 1], M.Neon)
	end
	rig(wheel, hub)
	wheel.Parent = m
	local w = 0.11
	motion(hub, "spin", { Pivot = axle, Speed = w, Axis = "Z" })
	for i = 0, 15 do
		local a0 = i / 16 * TAU
		local G0 = axle * CFrame.new(math.cos(a0) * RW * s, math.sin(a0) * RW * s, 0)
		local g, root = gondola(m, G0, s, BRIGHT[i % #BRIGHT + 1])
		rig(g, root)
		motion(root, "orbit", { Pivot = axle, Radius = RW * s, A0 = a0, Speed = w, Phase = i })
	end
	if frontSigns then
		signBoard(m, at(0, 7.4, -16), 18 * s, 3.4 * s, KINDS.ferris.sign, C.cream, main, hi)
		for _, x in { -9.6, 9.6 } do
			cyl(m, 0.7 * s, 9 * s, at(x, 4.5, -16), C.white, nil, true)
		end
	end
end

local COASTER = {
	v3(-56, 6, -26), v3(-22, 6, -26), v3(6, 10, -26), v3(40, 42, -26), v3(62, 58, -25), v3(80, 54, -16),
	v3(89, 38, 0), v3(82, 20, 17), v3(62, 8, 26), v3(22, 6, 26), v3(10.7, 10.7, 26.75), v3(6, 22, 27.5),
	v3(10.7, 33.3, 28.25), v3(22, 38, 29), v3(33.3, 33.3, 29.75), v3(38, 22, 30.5), v3(33.3, 10.7, 31.25),
	v3(22, 6, 32), v3(2, 6, 32), v3(-26, 22, 30), v3(-52, 8, 27), v3(-76, 14, 17), v3(-88, 12, 0), v3(-80, 8, -17),
}
local COASTER_LOOP = { 10, 17 } -- spans 10..17 run round the vertical loop (centre x 22, y 22)

local function trackFrames(P, seg, loop, loopCenter)
	local n = #P
	local U = table.create(n)
	for k = 1, n do
		local tv = (P[k % n + 1] - P[(k - 2) % n + 1]).Unit
		local up = Vector3.yAxis
		if loop and seg[k] >= loop[1] and seg[k] <= loop[2] then
			up = v3(loopCenter.X, loopCenter.Y, P[k].Z) - P[k]
		end
		up = up - tv * up:Dot(tv)
		U[k] = if up.Magnitude > 1e-3 then up.Unit else Vector3.yAxis
	end
	return U
end

local function coasterCart(parent, F: CFrame, s: number, pal)
	local at, pt, S = space(F, s)
	local cart = Instance.new("Model")
	cart.Name = "Cart"
	local body = block(cart, S(3.4, 1.4, 5.6), at(0, 1.7, 0), pal[1])
	wedge(cart, S(3.4, 1.4, 1.8), at(0, 1.7, -3.7), pal[1])
	block(cart, S(3.5, 0.4, 5.7), at(0, 2.2, 0), C.white)
	for _, z in { -1.2, 1.4 } do
		block(cart, S(3.0, 1.3, 0.5), at(0, 3.0, z), C.ink)
		rod(cart, pt(-1.4, 3.3, z - 0.9), pt(1.4, 3.3, z - 0.9), 0.3 * s, pal[2])
	end
	for _, x in { -1.6, 1.6 } do
		for _, z in { -1.9, 1.9 } do
			mk("Part", cart, S(0.5, 1, 1), at(x, 0.7, z), C.iron, nil, false, CYL)
		end
	end
	cart.Parent = parent
	return cart, body
end

function PATHS.coaster(cf: CFrame, s: number)
	local P, seg = spline(COASTER, true, 4.6)
	local U = trackFrames(P, seg, COASTER_LOOP, v3(22, 22, 0))
	local top = 58
	local times = timetable(P, s, function(k)
		if seg[k] == 3 or seg[k] == 4 then
			return 7
		elseif seg[k] == 1 then
			return 5
		end
		return math.clamp(math.sqrt(49 + 90 * (top - P[k].Y)), 7, 48)
	end)
	local frameAt, total = pathFrames(cf, s, P, U, times)
	return frameAt, total, P, seg, U
end

function LM.coaster(m, cf, pal, s)
	local _, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	local frameAt, _, P, seg, U = pathOf("coaster", cf, s)
	local n = #P
	local W = function(p)
		return cf * (p * s)
	end
	for k = 1, n do
		local k2 = k % n + 1
		local tv = (P[k2] - P[k]).Unit
		local rg, rg2 = tv:Cross(U[k]).Unit, tv:Cross(U[k2]).Unit
		for _, side in { -1.6, 1.6 } do
			local a, b = P[k] + rg * side + U[k] * 0.6, P[k2] + rg2 * side + U[k2] * 0.6
			rod(m, W(a - tv * 0.2), W(b + tv * 0.2), 1 * s, C.white, M.Metal)
		end
		bar(m, W(P[k] - rg * 2.2 + U[k] * 0.2), W(P[k] + rg * 2.2 + U[k] * 0.2), 0.8 * s, 0.4 * s, C.red, nil, false,
			cf:VectorToWorldSpace(U[k]))
		local inLoop = seg[k] >= COASTER_LOOP[1] and seg[k] <= COASTER_LOOP[2]
		if k % 3 == 0 and U[k].Y > 0.55 and P[k].Y > 3 and not inLoop then
			local top = P[k] - U[k] * 0.5
			local d = if top.Y > 24 then 2 else 1.3
			cyl(m, d * s, top.Y * s, cf * CFrame.new(top.X * s, top.Y * s / 2, top.Z * s), C.red, M.Metal, true)
			bar(m, W(top - rg * 1.8), W(top + rg * 1.8), 0.8 * s, 0.8 * s, C.red, M.Metal)
			block(m, S(2.4, 0.6, 2.4), cf * CFrame.new(top.X * s, 0.3 * s, top.Z * s), C.stone, M.Concrete, true)
		end
	end
	-- the loop's own tower and arms
	cyl(m, 2.6 * s, 40 * s, cf * CFrame.new(22 * s, 20 * s, 38 * s), C.red, M.Metal, true)
	bar(m, pt(22, 39.6, 38), pt(22, 39.6, 31), 1 * s, 1 * s, C.red, M.Metal)
	bar(m, pt(22, 22, 38), pt(8.2, 22, 29.8), 0.9 * s, 0.9 * s, C.red, M.Metal)
	bar(m, pt(22, 22, 38), pt(36.2, 22, 32.8), 0.9 * s, 0.9 * s, C.red, M.Metal)
	-- station
	block(m, S(36, 1, 7), cf * CFrame.new(-39 * s, 4.5 * s, -32 * s), C.cream, M.WoodPlanks, true)
	block(m, S(6, 4.6, 7), cf * CFrame.new(-39 * s, 2.2 * s, -32 * s), C.stone, M.Concrete, true)
	for _, x in { -56, -22 } do
		for _, z in { -35, -22.6 } do
			cyl(m, 0.9 * s, 15 * s, cf * CFrame.new(x * s, 7.5 * s, z * s), C.white, nil, true)
		end
	end
	for i = 0, 5 do
		block(m, S(6.4, 0.6, 14), cf * CFrame.new((-56.8 + i * 6.4 + 3.2) * s, 15.3 * s, -29 * s), if i % 2 == 0 then main else C.white,
			M.SmoothPlastic)
	end
	signBoard(m, cf * CFrame.new(-39 * s, 18.2 * s, -36 * s), 22 * s, 4 * s, KINDS.coaster.sign, C.cream, main, accent, true)
	local cart, body = coasterCart(m, (frameAt(0, 1)), s, { accent, hi })
	rig(cart, body)
	motion(body, "ride", { Path = "coaster", Pivot = cf, Scale = s, Offset = 0 })
end

function LM.teacups(m, cf, pal, s)
	local at, pt = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	cyl(m, 66 * s, 1 * s, at(0, 0.5, 0), C.cream, nil, true)
	cyl(m, 68 * s, 0.6 * s, at(0, 0.3, 0), accent, nil, true)
	railRing(m, at(0, 0, 0), 32.5 * s, 22, s, C.white, main, -math.pi / 2)
	local table_ = Instance.new("Model")
	table_.Name = "Turntable"
	local tt = cyl(table_, 58 * s, 0.6 * s, at(0, 1.3, 0), hi)
	cyl(table_, 50 * s, 0.1 * s, at(0, 1.65, 0), C.cream)
	cyl(table_, 34 * s, 0.1 * s, at(0, 1.72, 0), accent)
	cyl(table_, 16 * s, 0.1 * s, at(0, 1.79, 0), C.cream)
	-- the teapot in the middle
	cyl(table_, 10 * s, 3 * s, at(0, 3.1, 0), C.white)
	ball(table_, 11 * s, pt(0, 9.6, 0), main)
	cyl(table_, 6.5 * s, 1.2 * s, at(0, 15.2, 0), accent)
	ball(table_, 2 * s, pt(0, 16.5, 0), C.gold)
	rod(table_, pt(4.5, 8.5, 0), pt(10, 13.5, 0), 1.8 * s, main)
	ball(table_, 2 * s, pt(10.2, 13.8, 0), main)
	bar(table_, pt(-5, 12, 0), pt(-8.6, 12, 0), 1 * s, 1 * s, accent)
	bar(table_, pt(-8.6, 12.4, 0), pt(-8.6, 6.6, 0), 1 * s, 1 * s, accent)
	bar(table_, pt(-8.6, 7, 0), pt(-5.2, 7, 0), 1 * s, 1 * s, accent)
	rig(table_, tt)
	table_.Parent = m
	local w = 0.22
	motion(tt, "spin", { Pivot = cf, Speed = w, Axis = "Y" })
	-- umbrella over the middle (still)
	rod(m, pt(0, 16.5, 0), pt(0, 26, 0), 0.8 * s, C.white)
	local apex = cone(m, at(0, 24, 0), 17 * s, 6 * s, 12, { main, C.cream }, M.SmoothPlastic)
	ball(m, 1.8 * s, apex + v3(0, 0.6 * s, 0), C.gold)
	for i = 0, 11 do
		local a = (i + 0.5) / 12 * TAU
		ball(m, 2.2 * s, pt(math.cos(a) * 16.6, 23.4, math.sin(a) * 16.6), if i % 2 == 0 then main else C.cream, M.SmoothPlastic)
	end
	local cupColors = { rgb(255, 150, 196), rgb(126, 226, 196), rgb(186, 156, 255), rgb(255, 222, 110),
		rgb(130, 200, 255), rgb(255, 176, 130) }
	for i = 0, 5 do
		local a0 = i / 6 * TAU
		local home = cf * CFrame.Angles(0, a0, 0) * CFrame.new(18.5 * s, 1.6 * s, 0)
		local hat, hpt = space(home, s)
		local cup = Instance.new("Model")
		cup.Name = "Cup"
		local col = cupColors[i + 1]
		local saucer = cyl(cup, 12 * s, 0.6 * s, hat(0, 0.3, 0), col)
		cyl(cup, 7.6 * s, 1.8 * s, hat(0, 1.5, 0), col)
		cyl(cup, 9.4 * s, 2.6 * s, hat(0, 3.6, 0), col)
		cyl(cup, 9.9 * s, 0.5 * s, hat(0, 5.0, 0), C.gold)
		cyl(cup, 8.2 * s, 0.3 * s, hat(0, 4.9, 0), C.cream)
		rod(cup, hpt(0, 0.6, 0), hpt(0, 4.4, 0), 0.4 * s, C.white)
		cyl(cup, 2.6 * s, 0.3 * s, hat(0, 4.6, 0), C.ink)
		bar(cup, hpt(4.6, 4.3, 0), hpt(6.2, 4.3, 0), 0.6 * s, 0.6 * s, col)
		bar(cup, hpt(6.2, 4.5, 0), hpt(6.2, 2.4, 0), 0.6 * s, 0.6 * s, col)
		bar(cup, hpt(6.2, 2.6, 0), hpt(4.4, 2.6, 0), 0.6 * s, 0.6 * s, col)
		rig(cup, saucer)
		cup.Parent = m
		motion(saucer, "cup", { Pivot = cf, A0 = a0, Speed = w, Radius = 18.5 * s, Height = 1.6 * s,
			Spin = if i % 2 == 0 then 1.1 else -1.4, Phase = i })
	end
	for i = 0, 5 do
		local a = i / 6 * TAU
		local top = anchorPart(m, pt(math.cos(a) * 16.4, 23.6, math.sin(a) * 16.4))
		local post = anchorPart(m, pt(math.cos(a) * 32.5, 4.2, math.sin(a) * 32.5))
		lights(m, top, top.Position, post, post.Position, 2.4 * s, 7, nil, 0.7 * s)
	end
	if frontSigns then
		signBoard(m, at(0, 3, -35), 14 * s, 3 * s, KINDS.teacups.sign, C.cream, main, accent)
	end
end

local function bumperCar(parent, F: CFrame, s: number, color: Color3)
	local at, pt, S = space(F, s)
	local car = Instance.new("Model")
	car.Name = "BumperCar"
	local body = block(car, S(4, 1.6, 5.4), at(0, 1.5, 0), color)
	body.Reflectance = 0.1
	block(car, S(4.6, 0.9, 6), at(0, 0.75, 0), C.ink)
	block(car, S(2.8, 1.2, 1.4), at(0, 2.6, 1.2), C.ink)
	block(car, S(3.2, 1.8, 0.5), at(0, 3.0, 2.2), color)
	rod(car, pt(0, 2.3, -1.2), pt(0, 3.0, -0.9), 0.3 * s, C.iron)
	mk("Part", car, S(0.25, 1.4, 1.4), at(0, 3.1, -0.85) * CFrame.Angles(math.rad(-60), 0, 0) * UPRIGHT, C.iron,
		nil, false, CYL)
	rod(car, pt(0, 3.6, 2.4), pt(0, 16.8, 2.4), 0.25 * s, C.metal)
	ball(car, 0.7 * s, pt(0, 16.9, 2.4), C.warm, M.Neon)
	car.Parent = parent
	return car, body
end

function LM.bumper(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	block(m, S(74, 1, 54), at(0, 0.5, 0), C.stone, M.Concrete, true)
	block(m, S(66, 0.4, 46), at(0, 1.2, 0), rgb(70, 72, 84), M.DiamondPlate, true)
	local k = 0
	for _, side in { { -33, 33, -23, -23 }, { -33, 33, 23, 23 }, { -33, -33, -23, 23 }, { 33, 33, -23, 23 } } do
		local a, b = pt(side[1], 2, side[3]), pt(side[2], 2, side[4])
		local count = math.floor((b - a).Magnitude / (6 * s))
		for i = 0, count - 1 do
			k += 1
			bar(m, a:Lerp(b, i / count), a:Lerp(b, (i + 1) / count), 1.2 * s, 1.4 * s, if k % 2 == 0 then accent else C.ink,
				nil, true)
		end
	end
	for _, x in { -34, 0, 34 } do
		for _, z in { -24, 24 } do
			cyl(m, 1.4 * s, 18 * s, at(x, 9.5, z), accent, M.Metal, true)
		end
	end
	block(m, S(76, 1.2, 56), at(0, 19, 0), main, nil, true)
	block(m, S(70, 0.3, 50), at(0, 18.3, 0), rgb(60, 60, 72), M.DiamondPlate)
	local fascia = { { 0, -28.2, 76, 0 }, { 0, 28.2, 76, 0 }, { -38.2, 0, 56, 90 }, { 38.2, 0, 56, 90 } }
	for _, f in fascia do
		local len, rot = f[3], math.rad(f[4])
		local segs = math.floor(len / 7)
		for i = 0, segs - 1 do
			local off = -len / 2 + (i + 0.5) * len / segs
			local c = at(f[1], 17.6, f[2]) * CFrame.Angles(0, rot, 0) * CFrame.new(off * s, 0, 0)
			block(m, S(len / segs, 3.2, 0.6), c, if i % 2 == 0 then hi else C.cream)
			ball(m, 0.8 * s, (c * CFrame.new(0, 2.2 * s, -0.5 * s)).Position, BULBS[i % #BULBS + 1], M.Neon)
		end
	end
	signBoard(m, at(0, 24, 0), 34 * s, 6 * s, KINDS.bumper.sign, C.cream, main, accent, true)
	for _, x in { -12, 12 } do
		cyl(m, 0.8 * s, 4 * s, at(x, 21, 0), C.white)
	end
	for _, x in { -38, 38 } do
		for _, z in { -28, 28 } do
			ball(m, 2.2 * s, pt(x, 20.8, z), C.gold)
		end
	end
	local carColors = { rgb(255, 79, 109), rgb(62, 201, 245), rgb(255, 196, 41), rgb(88, 214, 92), rgb(155, 92, 255),
		rgb(255, 138, 61), rgb(255, 110, 199), rgb(250, 250, 252) }
	for i = 0, 7 do
		local x0, z0 = bumperAt(i, s, 0)
		local car, body = bumperCar(m, cf * CFrame.new(x0, 1.4 * s, z0), s, carColors[i + 1])
		rig(car, body)
		motion(body, "bumper", { Pivot = cf, Scale = s, Index = i })
	end
	block(m, S(8, 7, 6), at(-28, 3.5, -31), main, nil, true)
	cone(m, at(-28, 7, -31), 5.6 * s, 3.4 * s, 8, { accent, C.cream }, M.SmoothPlastic)
end

local FLUME = {
	v3(-64, 1.5, -22), v3(-36, 1.5, -24), v3(-20, 2.5, -24), v3(6, 26, -24), v3(22, 33, -22), v3(44, 33, -18),
	v3(60, 33, -4), v3(58, 33, 14), v3(40, 33, 24), v3(24, 32, 24), v3(-6, 1.5, 24), v3(-24, 0.4, 24),
	v3(-46, 0.6, 21), v3(-74, 1.5, 10), v3(-80, 1.5, -10),
}

local function inPool(p: Vector3): boolean
	return p.X > -36 and p.X < 2 and p.Z > 15 and p.Z < 33
end

local function flumeLog(parent, F: CFrame, s: number)
	local at, _, S = space(F, s)
	local log = Instance.new("Model")
	log.Name = "Log"
	local hull = mk("Part", log, S(7.5, 3.2, 3.2), at(0, 0.4, 0) * ALONG_Z, rgb(150, 98, 60), M.Wood, false, CYL)
	mk("Part", log, S(0.4, 3.3, 3.3), at(0, 0.4, -3.75) * ALONG_Z, rgb(214, 170, 120), M.Wood, false, CYL)
	block(log, S(2.6, 0.6, 5.2), at(0, 1.9, 0), C.ink)
	block(log, S(2.4, 1.1, 0.4), at(0, 2.4, -0.6), C.darkWood)
	block(log, S(2.4, 1.1, 0.4), at(0, 2.4, 1.6), C.darkWood)
	log.Parent = parent
	return log, hull
end

-- the trough is water-ride blue whatever the zone's colours, so it reads as water from the ground too
local TROUGH = rgb(36, 146, 222)

local function flumeChannel(m, cf, s, P, seg, U)
	local W = function(p)
		return cf * (p * s)
	end
	local n = #P
	for k = 1, n do
		local k2 = k % n + 1
		local a, b = P[k], P[k2]
		if inPool(a) and inPool(b) then
			continue
		end
		local tv = (b - a).Unit
		local up = U[k]
		local side = tv:Cross(up).Unit
		local upW = cf:VectorToWorldSpace(up)
		local ext = tv * 0.4
		bar(m, W(a - up * 1.3 - ext), W(b - up * 1.3 + ext), 7 * s, 0.6 * s, TROUGH, M.SmoothPlastic, true, upW)
		for _, sd in { -3.3, 3.3 } do
			bar(m, W(a + side * sd + up * 0.2 - ext), W(b + side * sd + up * 0.2 + ext), 0.6 * s, 3.4 * s, TROUGH,
				M.SmoothPlastic, true, upW)
			bar(m, W(a + side * sd + up * 2 - ext), W(b + side * sd + up * 2 + ext), 0.9 * s, 0.4 * s, C.cream, nil, false,
				upW)
		end
		local water = bar(m, W(a - up * 0.7 - ext), W(b - up * 0.7 + ext), 6 * s, 0.4 * s, rgb(70, 196, 255), M.Glass,
			false, upW)
		water.Transparency = 0.12
		if seg[k] == 10 then -- white water down the big drop
			for _, sd in { -1.8, 0.6 } do
				bar(m, W(a + side * sd - up * 0.45), W(b + side * sd - up * 0.45), 1.2 * s, 0.1 * s, C.white, M.SmoothPlastic,
					false, upW).Transparency = 0.2
			end
		end
		if seg[k] == 3 or seg[k] == 4 then
			bar(m, W(a - up * 0.45), W(b - up * 0.45), 1.2 * s, 0.3 * s, C.iron, M.DiamondPlate, false, upW)
		end
		if a.Y > 3 and k % 2 == 0 then
			for _, sd in { -2.8, 2.8 } do
				local top = a + side * sd - up * 1.6
				rod(m, cf * v3(top.X * s, 0, top.Z * s), W(top), 0.9 * s, C.darkWood, M.Wood, true)
			end
			bar(m, W(a - side * 3 - up * 2), W(a + side * 3 - up * 2), 0.6 * s, 0.6 * s, C.darkWood, M.Wood)
		end
	end
end

function PATHS.flume(cf: CFrame, s: number)
	local P, seg = spline(FLUME, true, 4.4)
	local U = table.create(#P, Vector3.yAxis)
	for k = 1, #P do
		local tv = (P[k % #P + 1] - P[(k - 2) % #P + 1]).Unit
		U[k] = (Vector3.yAxis - tv * tv.Y).Unit
	end
	local times = timetable(P, s, function(k)
		if seg[k] == 3 or seg[k] == 4 then
			return 6
		elseif seg[k] == 10 then
			return math.clamp(math.sqrt(81 + 120 * (33 - P[k].Y)), 9, 40)
		elseif seg[k] == 11 or seg[k] == 12 then
			return 7
		end
		return 9
	end)
	local frameAt, total = pathFrames(cf, s, P, U, times, -0.4 * s)
	return frameAt, total, P, seg, U
end

-- spray: big soft droplets thrown up and falling back, always on
local function spray(parent: BasePart, rate: number, size: number, speed: number)
	local e = emitter(parent, rgb(240, 252, 255), rate, NumberRange.new(speed * 0.6, speed), NumberRange.new(1.0, 1.6), size, 22)
	e.Acceleration = v3(0, -46, 0)
	e.LightEmission = 0.15
	e.LightInfluence = 0.6
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(1, 0.7) })
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	return e
end

function LM.flume(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent = pal[1], pal[2]
	local T = workspace.Terrain
	T:FillBall(cf * v3(44 * s, -16 * s, 4 * s), 46 * s, M.Grass)
	for _, rock in { { 44, 22, 4, 10 }, { 62, 14, -10, 9 }, { 30, 12, 26, 8 }, { 70, 8, 22, 8 } } do
		T:FillBall(cf * v3(rock[1] * s, rock[2] * s, rock[3] * s), rock[4] * s, M.Rock)
	end
	T:FillBlock(cf * CFrame.new(-17 * s, -3 * s, 24 * s), v3(38 * s, 6 * s, 18 * s), M.Air)
	T:FillBlock(cf * CFrame.new(-17 * s, -3.2 * s, 24 * s), v3(38 * s, 5.6 * s, 18 * s), M.Water)
	local frameAt, total, P, seg, U = pathOf("flume", cf, s)
	flumeChannel(m, cf, s, P, seg, U)
	-- boulders half sunk round the splash pool (the channel comes in and goes out at the two gaps)
	for i = 0, 13 do
		if i == 0 or i == 7 or i == 13 then
			continue
		end
		local a = i / 14 * TAU
		local r = (if i % 3 == 0 then 4.2 elseif i % 3 == 1 then 3.2 else 2.6) * s
		T:FillBall(cf * v3((-17 + math.cos(a) * 21.5) * s, -0.4 * r, (24 + math.sin(a) * 11) * s), r, M.Rock)
	end
	-- the splash where the logs land, and the spray the drop throws up
	spray(anchorPart(m, pt(-8, 1.2, 24)), 70, 3.4 * s, 30)
	spray(anchorPart(m, pt(-16, 0.8, 24)), 26, 2.4 * s, 16)
	-- station hut
	block(m, S(28, 1.4, 8), at(-50, 0.7, -32.5), C.cream, M.WoodPlanks, true)
	for _, x in { -63, -37 } do
		for _, z in { -36, -17 } do
			cyl(m, 0.9 * s, 9 * s, at(x, 4.5, z), C.darkWood, M.Wood, true)
		end
	end
	wedge(m, S(30, 4, 10.5), at(-50, 11, -31.75), main, M.WoodPlanks, true)
	wedge(m, S(30, 4, 10.5), at(-50, 11, -21.25) * CFrame.Angles(0, math.pi, 0), main, M.WoodPlanks, true)
	signBoard(m, at(-50, 10.6, -37.6), 18 * s, 3.4 * s, KINDS.flume.sign, C.cream, main, accent)
	-- pines on the far side of the mountain, clear of the channel
	for i, a in { -0.6, -0.1, 0.4, 0.9 } do
		local x, z = 44 + math.cos(a) * 36, 4 + math.sin(a) * 36
		local y = -16 + math.sqrt(46 * 46 - 36 * 36)
		cyl(m, 1.2 * s, 4 * s, at(x, y + 1, z), C.trunk, M.Wood)
		blob(m, S(5, 13, 5), at(x, y + 8, z), GREENS[i % #GREENS + 1], M.Grass)
	end
	for i = 0, 2 do
		local offset = total * i / 3
		local log, hull = flumeLog(m, (frameAt(offset, 1)), s)
		rig(log, hull)
		motion(hull, "ride", { Path = "flume", Pivot = cf, Scale = s, Offset = offset })
	end
end

local SPOOK = {
	wall = rgb(66, 60, 70), roof = rgb(34, 31, 40), trim = rgb(26, 23, 30), stone = rgb(88, 84, 90),
	board = rgb(112, 94, 74), bark = rgb(46, 38, 34), dark = rgb(20, 18, 26),
}

local function hauntedHouse(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local house = block(m, S(44, 26, 30), at(0, 13, 2), SPOOK.wall, M.WoodPlanks, true)
	block(m, S(45, 1, 31), at(0, 13, 2), SPOOK.trim, M.Wood, true)
	wedge(m, S(46, 13, 16.5), at(0, 32.5, -6.25), SPOOK.roof, M.Slate, true)
	wedge(m, S(46, 13, 16.5), at(0, 32.5, 10.25) * CFrame.Angles(0, math.pi, 0), SPOOK.roof, M.Slate, true)
	for _, x in { -12, 14 } do
		block(m, S(3, 9, 3), at(x, 36, 6) * CFrame.Angles(0, 0, math.rad(x / 4)), rgb(92, 70, 64), M.Brick, true)
	end
	for _, x in { -24, 24 } do
		cyl(m, 12 * s, 40 * s, at(x, 20, -14), SPOOK.stone, M.Cobblestone, true)
		cyl(m, 13 * s, 1.2 * s, at(x, 40.2, -14), SPOOK.trim)
		local apex = cone(m, at(x, 40.8, -14), 8 * s, 16 * s, 10, { SPOOK.roof, rgb(52, 40, 66) }, M.Slate)
		rod(m, apex, apex + v3(0, 4 * s, 0), 0.3 * s, C.iron)
		ball(m, 1 * s, apex + v3(0, 4.2 * s, 0), pal[2], M.Neon)
	end
	tri(m, pt(-9, 26, -13.6), pt(9, 26, -13.6), pt(0, 35, -13.6), SPOOK.wall, M.WoodPlanks, 1.6)
	-- loose, crooked boards on the walls
	for i, x in { -18, -11, 4, 12, 19 } do
		block(m, S(1.2, 7, 0.3), at(x, 6 + (i % 2) * 9, -13.25) * CFrame.Angles(0, 0, math.rad((i % 3 - 1) * 9)), rgb(84, 74, 66),
			M.WoodPlanks)
	end
	return house
end

local function deadTree(m, base: Vector3, h: number, s: number, seed: number)
	local trunkTop = base + v3(0.15 * h, h, 0.08 * h)
	rod(m, base, base + v3(0, 0.45 * h, 0), 2.6 * s, SPOOK.bark, M.Wood, true)
	rod(m, base + v3(0, 0.45 * h, 0), trunkTop, 1.7 * s, SPOOK.bark, M.Wood, true)
	for _, a in { 0.7, 2.6, 4.4 } do
		local root = base + v3(math.cos(a + seed) * 2.6 * s, 0, math.sin(a + seed) * 2.6 * s)
		rod(m, base + v3(0, 1.4 * s, 0), root - v3(0, 0.6 * s, 0), 1.1 * s, SPOOK.bark, M.Wood)
	end
	for k = 0, 5 do
		local from = base:Lerp(trunkTop, 0.4 + k * 0.11)
		local a = k * 2.3 + seed
		local tip = from + v3(math.cos(a) * 0.36 * h, (0.12 + (k % 2) * 0.16) * h, math.sin(a) * 0.36 * h)
		rod(m, from, tip, (0.9 - k * 0.08) * s, SPOOK.bark, M.Wood)
		local twig = tip + v3(math.cos(a + 1.1) * 0.14 * h, 0.12 * h, math.sin(a + 1.1) * 0.14 * h)
		rod(m, tip, twig, 0.4 * s, SPOOK.bark, M.Wood)
	end
end

-- the yard: an iron fence with a gate gap, graves, big dead trees and jack-o'-lanterns
local function hauntedYard(m, cf, s, rng)
	local at, pt, S = space(cf, s)
	for _, side in { -1, 1 } do
		local a, b = pt(side * 6, 0, -28), pt(side * 34, 0, -28)
		for i = 0, 7 do
			local p = a:Lerp(b, i / 7)
			rod(m, p, p + v3(0, 5 * s, 0), 0.35 * s, C.iron)
			ball(m, 0.6 * s, p + v3(0, 5.2 * s, 0), C.iron)
		end
		bar(m, a + v3(0, 4 * s, 0), b + v3(0, 4 * s, 0), 0.25 * s, 0.35 * s, C.iron)
		bar(m, a + v3(0, 1.4 * s, 0), b + v3(0, 1.4 * s, 0), 0.25 * s, 0.35 * s, C.iron)
	end
	for i = 1, 8 do
		local x = (if i % 2 == 0 then 1 else -1) * rng:NextNumber(12, 31)
		local f = at(x, 1.5, rng:NextNumber(-27, -22.5))
			* CFrame.Angles(math.rad(rng:NextNumber(-8, 8)), 0, math.rad(rng:NextNumber(-8, 8)))
		block(m, S(2.4, 3, 0.6), f, rgb(132, 132, 140), M.Slate, true)
		mk("Part", m, S(0.6, 2.4, 2.4), f * CFrame.new(0, 1.5 * s, 0) * ALONG_Z, rgb(132, 132, 140), M.Slate, true, CYL)
	end
	deadTree(m, pt(-31, 0, 10), 24 * s, s, 0.4)
	deadTree(m, pt(31, 0, -8), 28 * s, s, 2.1)
	deadTree(m, pt(30, 0, 17), 19 * s, s, 4.0)
	deadTree(m, pt(-30, 0, -14), 17 * s, s, 5.2)
	for i = 0, 5 do
		local p = pt(-14 + i * 5.6, 1.1, -22.5 - (i % 2) * 2)
		ball(m, 2.3 * s, p, rgb(255, 128, 32), M.SmoothPlastic, true)
		block(m, S(0.3, 0.7, 0.3), CFrame.new(p + v3(0, 1.3 * s, 0)), rgb(70, 130, 50))
		block(m, S(1.2, 0.5, 0.2), cf.Rotation + p + cf.LookVector * 1.12 * s, rgb(255, 230, 90), M.Neon)
	end
end

-- low purple mist rolling round the house
local function mist(parent: BasePart, s: number)
	local e = emitter(parent, rgb(150, 92, 220), 3, NumberRange.new(1, 3), NumberRange.new(7, 10), 22 * s, 180)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 10 * s), NumberSequenceKeypoint.new(1, 24 * s) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.3, 0.55),
		NumberSequenceKeypoint.new(1, 1) })
	e.Texture = "rbxasset://textures/particles/smoke_main.dds"
	e.LightEmission = 0.25
	e.LightInfluence = 0.5
	e.Acceleration = v3(0, 0.4, 0)
	e.RotSpeed = NumberRange.new(-12, 12)
	e.Drag = 0.4
	return e
end

function LM.haunted(m, cf, pal, s, rng)
	local at, pt, S = space(cf, s)
	local main, accent = pal[1], pal[2]
	block(m, S(76, 0.4, 60), at(0, 0.2, -2), rgb(56, 64, 48), M.Grass, true)
	block(m, S(6, 0.5, 14), at(0, 0.3, -25), rgb(104, 98, 92), M.Cobblestone, true)
	local house = hauntedHouse(m, cf, pal, s)
	-- most windows boarded up and dark; a few glow and flicker (WKGlass)
	local lit = { [2] = rgb(150, 255, 120), [7] = rgb(255, 150, 60), [11] = rgb(150, 255, 120), [15] = rgb(186, 120, 255),
		[19] = rgb(255, 150, 60) }
	local count = 0
	local function window(x, y, z, face)
		count += 1
		local f = at(x, y, z) * CFrame.Angles(0, face, 0)
		block(m, S(4.2, 5.6, 0.5), f, SPOOK.trim)
		local glow = lit[count]
		local g = block(m, S(3.4, 4.8, 0.6), f * CFrame.new(0, 0, -0.1 * s), glow or SPOOK.dark, if glow then M.Neon else M.Glass)
		if glow then
			g:SetAttribute("WKGlass", true)
		else
			for _, a in { 38, -32 } do
				block(m, S(4.6, 0.7, 0.25), f * CFrame.new(0, 0, -0.45 * s) * CFrame.Angles(0, 0, math.rad(a)), SPOOK.board, M.WoodPlanks)
			end
		end
	end
	for _, y in { 8, 19 } do
		for _, x in { -15, -7, 7, 15 } do
			window(x, y, -13.1, 0)
		end
	end
	for _, z in { -4, 6, 14 } do
		window(-22.1, 13, z, math.pi / 2)
		window(22.1, 13, z, math.pi / 2)
	end
	for _, x in { -24, 24 } do
		for _, y in { 12, 22, 31 } do
			window(x, y, -20.1, 0)
		end
	end
	block(m, S(5, 8, 0.6), at(0, 5, -13.3), rgb(70, 24, 30), M.Wood, true)
	block(m, S(20, 0.8, 7), at(0, 10, -16.5), SPOOK.trim, M.Wood, true)
	for _, x in { -9, -3, 3, 9 } do
		cyl(m, 1 * s, 9 * s, at(x, 5.5, -19.5), rgb(150, 144, 150), nil, true)
	end
	block(m, S(20, 1, 7), at(0, 0.5, -16.5), rgb(74, 70, 78), M.WoodPlanks, true)
	block(m, S(10, 0.5, 2), at(0, 0.25, -21), rgb(74, 70, 78), M.Cobblestone, true)
	signBoard(m, at(0, 12.6, -20.2), 18 * s, 3.4 * s, KINDS.haunted.sign, SPOOK.trim, accent, main, false, Enum.Font.Creepster)
	hauntedYard(m, cf, s, rng)
	local light = Instance.new("PointLight")
	light.Color, light.Brightness, light.Range = rgb(170, 90, 255), 4, 30
	light.Parent = house
	for _, p in { { -26, -24 }, { 26, -24 }, { -34, 6 }, { 34, 6 }, { 0, -26 } } do
		mist(anchorPart(m, pt(p[1], 1.5, p[2])), s)
	end
	local ghost = Instance.new("Model")
	ghost.Name = "Ghost"
	local gat, gpt = space(cf * CFrame.new(-31 * s, 30 * s, -22 * s), s)
	local head = ball(ghost, 3.4 * s, gpt(0, 0, 0), C.white)
	head.Transparency = 0.15
	local tail = cyl(ghost, 3 * s, 3.4 * s, gat(0, -1.8, 0), C.white)
	tail.Transparency = 0.25
	ball(ghost, 0.6 * s, gpt(-0.7, 0.3, -1.4), C.ink)
	ball(ghost, 0.6 * s, gpt(0.7, 0.3, -1.4), C.ink)
	rig(ghost, head)
	ghost.Parent = m
	motion(head, "ghost", { Pivot = cf * CFrame.new(-31 * s, 30 * s, -22 * s), Scale = s })
	motion(house, "flicker", {})
end

local function pirateHull(ship, F: CFrame, s: number, pal)
	local at, pt, S = space(F, s)
	local hullC, deckC = rgb(110, 68, 42), rgb(176, 128, 82)
	local shipX = F.RightVector
	for k = 0, 8 do
		local x = -28 + (k + 0.5) * (56 / 9)
		local u = x / 30
		local w = 7.4 * (1 - u * u) ^ 0.5 + 0.6
		local deck = -20 + 4 * u * u
		local depth = 6.5 + 2 * u * u
		local len = 56 / 9 + 0.4
		block(ship, S(len, 0.8, w * 1.1), at(x, deck - depth + 0.4, 0), hullC, M.Wood)
		for _, sd in { -1, 1 } do
			local a, b = pt(x, deck - depth + 0.4, sd * w * 0.55), pt(x, deck, sd * w)
			bar(ship, a, b, 0.8 * s, len * s, hullC, M.Wood, false, shipX)
			bar(ship, pt(x, deck - 1.4, sd * (w + 0.05)), pt(x, deck - 0.4, sd * (w + 0.12)), 0.5 * s, len * s, pal[1], nil,
				false, shipX)
			cyl(ship, 0.5 * s, 2.2 * s, at(x, deck + 1.1, sd * w), C.darkWood)
			bar(ship, pt(x - len / 2, deck + 2.2, sd * w), pt(x + len / 2, deck + 2.2, sd * w), 0.4 * s, 0.4 * s, C.darkWood)
		end
		block(ship, S(len, 0.5, w * 2 - 0.6), at(x, deck - 0.25, 0), deckC, M.WoodPlanks)
	end
	local tipTop, tipLow = pt(37, -14, 0), pt(33, -24, 0)
	for _, sd in { -1, 1 } do
		local top, low = pt(28, -16.8, sd * 3.4), pt(28, -24.4, sd * 1.9)
		tri(ship, top, low, tipTop, hullC, M.Wood, 0.6)
		tri(ship, low, tipLow, tipTop, hullC, M.Wood, 0.6)
	end
	tri(ship, pt(28, -16.8, -3.4), pt(28, -16.8, 3.4), tipTop, deckC, M.WoodPlanks, 0.5)
	rod(ship, tipTop, pt(46, -9, 0), 0.8 * s, C.darkWood)
	ball(ship, 2 * s, pt(36, -15, 0), pal[2])
	block(ship, S(9, 6, 8), at(-25, -13, 0), hullC, M.Wood)
	block(ship, S(9.6, 0.8, 8.6), at(-25, -9.6, 0), pal[2])
	for _, z in { -2.4, 0, 2.4 } do
		block(ship, S(0.4, 1.6, 1.4), at(-29.6, -13, z), C.warm, M.Neon)
	end
	for _, x in { -12, 0, 12 } do
		for _, sd in { -1, 1 } do
			mk("Part", ship, S(3, 1, 1), at(x, -22, sd * 7.9) * CFrame.Angles(0, math.rad(90), 0), C.iron, M.Metal, false, CYL)
		end
	end
end

function LM.pirate(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	local T = workspace.Terrain
	T:FillBlock(cf * CFrame.new(0, -2.5 * s, 0), v3(76 * s, 5 * s, 22 * s), M.Air)
	T:FillBlock(cf * CFrame.new(0, -2.8 * s, 0), v3(76 * s, 4.4 * s, 22 * s), M.Water)
	local H = 44
	for _, z in { -1, 1 } do
		for _, x in { -1, 1 } do
			rod(m, pt(x * 26, 0, z * 14), pt(0, H, z * 10.5), 2.2 * s, hi, M.Metal, true)
			block(m, S(4, 1.4, 4), at(x * 26, 0.7, z * 14), C.stone, M.Concrete, true)
		end
		bar(m, pt(-17.5, 14.5, z * 12.8), pt(17.5, 14.5, z * 12.8), 1.2 * s, 1.2 * s, accent, M.Metal, true)
		block(m, S(4, 4, 3), at(0, H, z * 10.5), hi, M.Metal, true)
	end
	rod(m, pt(0, H, -12), pt(0, H, 12), 2.4 * s, C.metal, M.Metal, true)
	local axle = at(0, H, 0)
	local ship = Instance.new("Model")
	ship.Name = "Ship"
	local hub = mk("Part", ship, S(6, 3.2, 3.2), axle * ALONG_Z, accent, M.Metal, false, CYL)
	pirateHull(ship, axle, s, pal)
	for _, z in { -9, 9 } do
		bar(ship, pt(0, H, z), pt(0, H - 19.5, z * 0.82), 1.2 * s, 1.2 * s, accent, M.Metal)
		bar(ship, pt(0, H, z), pt(-11, H - 19.5, z * 0.8), 1 * s, 1 * s, accent, M.Metal)
		bar(ship, pt(0, H, z), pt(11, H - 19.5, z * 0.8), 1 * s, 1 * s, accent, M.Metal)
	end
	for _, x in { -13, 13 } do
		rod(ship, pt(x, H - 20, 0), pt(x, H - 2.5, 0), 1.2 * s, C.darkWood, M.Wood)
		bar(ship, pt(x, H - 5, -6), pt(x, H - 5, 6), 0.5 * s, 0.5 * s, C.darkWood, M.Wood)
		bar(ship, pt(x, H - 15, -6.6), pt(x, H - 15, 6.6), 0.5 * s, 0.5 * s, C.darkWood, M.Wood)
		for b = 0, 2 do
			local y0 = H - 5.6 - b * 3.1
			block(ship, S(0.3, 3.1, 11.6), at(x + 0.5, y0 - 1.55, 0), if b % 2 == 0 then C.cream else main, M.SmoothPlastic)
		end
	end
	cyl(ship, 3 * s, 1.6 * s, at(13, H - 2.2, 0), C.darkWood, M.Wood)
	block(ship, S(0.2, 3.4, 5), at(13, H + 0.2, -2.6), C.ink, M.SmoothPlastic)
	ball(ship, 1.3 * s, pt(12.85, H + 0.5, -2.6), C.white)
	bar(ship, pt(12.8, H - 0.8, -3.6), pt(12.8, H + 0.6, -1.6), 0.2 * s, 0.3 * s, C.white)
	bar(ship, pt(12.8, H + 0.6, -3.6), pt(12.8, H - 0.8, -1.6), 0.2 * s, 0.3 * s, C.white)
	rig(ship, hub)
	ship.Parent = m
	motion(hub, "swing", { Pivot = axle, Amp = math.rad(42), Period = 7.5 })
	block(m, S(20, 3, 8), at(0, 1.5, -19), C.darkWood, M.WoodPlanks, true)
	for k = 0, 2 do
		block(m, S(8, 0.9 * (k + 1), 2), at(0, 0.45 * (k + 1), -27 + k * 2), C.wood, M.WoodPlanks, true)
	end
	if frontSigns then
		signBoard(m, at(0, 7, -23.2), 18 * s, 3.4 * s, KINDS.pirate.sign, C.cream, main, hi)
		for _, x in { -10, 10 } do
			cyl(m, 0.7 * s, 5 * s, at(x, 5.5, -23.2), C.darkWood, M.Wood)
		end
	end
	for i = 0, 3 do
		cyl(m, 2.2 * s, 3 * s, at(-34 + i * 2.8, 1.5, -18 - (i % 2) * 2.6), rgb(150, 98, 60), M.Wood, true)
	end
	block(m, S(4, 2.6, 2.6), at(30, 1.3, -18), rgb(130, 82, 48), M.Wood, true)
	block(m, S(4.2, 0.6, 2.8), at(30, 2.9, -18), accent, M.Metal)
end

function LM.circus(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	local n, rw, wh = 20, 40, 13
	local da = TAU / n
	local a0 = -math.pi / 2 - da / 2
	cyl(m, (2 * rw + 30) * s, 0.5 * s, at(0, 0.25, 0), C.sawdust, M.Sand, true)
	for i = 1, n - 1 do
		local a, b = a0 + i * da, a0 + (i + 1) * da
		local p, q = circlePoint(cf, rw * s, a, wh * s / 2), circlePoint(cf, rw * s, b, wh * s / 2)
		bar(m, p, q, 0.6 * s, wh * s, if i % 2 == 0 then main else C.cream, M.SmoothPlastic, true)
	end
	frustum(m, at(0, wh, 0), (rw + 1.5) * s, 15 * s, (31 - wh) * s, n, { main, C.cream }, M.SmoothPlastic, a0)
	local apex = cone(m, at(0, 31, 0), 15 * s, 14 * s, n, { main, C.cream }, M.SmoothPlastic, a0)
	for i = 0, n - 1 do
		local a = a0 + (i + 0.5) * da
		ball(m, 3.6 * s, circlePoint(cf, (rw + 1.3) * s, a, (wh - 0.4) * s), if i % 2 == 0 then accent else C.cream, M.SmoothPlastic)
	end
	cyl(m, 5 * s, 1.4 * s, CFrame.new(apex) * cf.Rotation, accent)
	-- the flag on the king pole turns slowly, like a weather vane
	local vane = Instance.new("Model")
	vane.Name = "Vane"
	local pole = rod(vane, apex, apex + v3(0, 12 * s, 0), 0.8 * s, C.white)
	ball(vane, 1.4 * s, apex + v3(0, 12.6 * s, 0), C.gold)
	pennant(vane, apex + v3(0, 12 * s, 0), cf.RightVector, 5 * s, hi)
	rig(vane, pole)
	vane.Parent = m
	motion(pole, "spin", { Pivot = CFrame.new(apex) * cf.Rotation, Speed = 0.35, Axis = "Y" })
	for i = 0, 3 do
		local a = a0 + (i * 5 + 2.5) * da
		local base = circlePoint(cf, 24 * s, a, 23.5 * s)
		rod(m, base, base + v3(0, 6 * s, 0), 0.4 * s, C.white)
		pennant(m, base + v3(0, 6 * s, 0), cf.RightVector, 2.6 * s, BRIGHT[i + 1])
	end
	-- the entrance awning over the doorway
	for _, x in { -6.5, 6.5 } do
		cyl(m, 1 * s, 11 * s, at(x, 5.5, -51), C.gold, nil, true)
		ball(m, 1.6 * s, pt(x, 11.4, -51), C.gold)
	end
	for _, sd in { -1, 1 } do
		block(m, S(7.8, 0.5, 14), at(sd * 3.6, 12.2, -45) * CFrame.Angles(0, 0, math.rad(-sd * 24)), if sd < 0 then main else C.cream,
			M.SmoothPlastic, true)
	end
	signBoard(m, at(0, 16.4, -52.4), 18 * s, 4 * s, KINDS.circus.sign, C.cream, main, accent, false)
	-- guy ropes
	for i = 0, 9 do
		local a = a0 + (i * 2 + 1) * da
		if i == 0 then
			continue
		end
		local stake = block(m, S(0.8, 1.6, 0.8), CFrame.new(circlePoint(cf, (rw + 12) * s, a, 0.8 * s)), C.darkWood, M.Wood)
		local top = anchorPart(m, circlePoint(cf, rw * s, a, wh * s))
		wire(top, top.Position, stake, stake.Position + v3(0, 0.6 * s, 0), 0, rgb(240, 230, 210), 0.1)
	end
end

function LM.fireworks(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	block(m, S(46, 4, 22), at(0, 2, 0), main, nil, true)
	block(m, S(46.6, 0.4, 22.6), at(0, 4.2, 0), C.darkWood, M.WoodPlanks, true)
	for k = 0, 1 do
		block(m, S(14, 1.3 * (k + 1), 2.4), at(0, 0.65 * (k + 1), -13.4 + k * 2.4), C.stone, M.Concrete, true)
	end
	for i = 0, 11 do
		ball(m, 0.9 * s, pt(-21 + i * 3.82, 3.4, -11.2), BULBS[i % #BULBS + 1], M.Neon)
	end
	for _, x in { -25, 25 } do
		block(m, S(6, 32, 4), at(x, 16, 8), accent, nil, true)
		ball(m, 3.4 * s, pt(x, 33.6, 8), C.gold)
	end
	block(m, S(56, 5, 4), at(0, 30.5, 8), accent, nil, true)
	signBoard(m, at(0, 30.5, 5.6), 40 * s, 4 * s, KINDS.fireworks.sign, rgb(30, 24, 70), C.gold, hi, false)
	for i = 0, 12 do
		local a = math.pi * i / 12
		local p = pt(-math.cos(a) * 19, 4.5 + math.sin(a) * 22, 6.2)
		ball(m, 1.1 * s, p, BULBS[i % #BULBS + 1], M.Neon)
		if i < 12 then
			local b = math.pi * (i + 1) / 12
			bar(m, p, pt(-math.cos(b) * 19, 4.5 + math.sin(b) * 22, 6.2), 0.6 * s, 0.6 * s, C.gold)
		end
	end
	local starC = pt(0, 40.5, 8)
	for i = 0, 4 do
		local a1, a2 = i / 5 * TAU + math.pi / 2, (i + 0.5) / 5 * TAU + math.pi / 2
		local tip = starC + (cf.RightVector * math.cos(a1) + cf.UpVector * math.sin(a1)) * 5 * s
		local inner = starC + (cf.RightVector * math.cos(a2) + cf.UpVector * math.sin(a2)) * 2 * s
		local prev = starC + (cf.RightVector * math.cos(a2 - TAU / 5) + cf.UpVector * math.sin(a2 - TAU / 5)) * 2 * s
		tri(m, starC, prev, tip, C.gold, M.Neon, 0.6)
		tri(m, starC, tip, inner, C.gold, M.Neon, 0.6)
	end
	for _, x in { -33, 33 } do
		for _, dx in { -2, 2 } do
			for _, dz in { -2, 2 } do
				rod(m, pt(x + dx, 0, 4 + dz), pt(x + dx, 34, 4 + dz), 0.45 * s, C.metal, M.Metal, true)
			end
		end
		for y = 0, 30, 6 do
			bar(m, pt(x - 2, y, 2), pt(x + 2, y + 6, 2), 0.3 * s, 0.3 * s, C.metal, M.Metal)
			bar(m, pt(x - 2, y, 6), pt(x + 2, y + 6, 6), 0.3 * s, 0.3 * s, C.metal, M.Metal)
		end
		block(m, S(5, 1, 5), at(x, 34.5, 4), C.iron, M.Metal)
		mk("Part", m, S(2.4, 1.8, 1.8), at(x, 36, 3) * CFrame.Angles(math.rad(20), math.rad(90), 0), C.iron, nil, false, CYL)
		block(m, S(4, 6, 3), at(x * 0.82, 3, -8), C.ink, nil, true)
		for i = 0, 5 do
			local tube = at(x * 1.27 + (i % 3 - 1) * 1.6, 2.4, 6 + math.floor(i / 3) * 1.8)
				* CFrame.Angles(math.rad(-12), 0, math.rad(x > 0 and 10 or -10))
			cyl(m, 1.2 * s, 4 * s, tube, if i % 2 == 0 then main else C.red)
		end
		block(m, S(6, 0.8, 5), at(x * 1.27, 0.4, 6.9), C.darkWood, M.Wood, true)
	end
	for i = 0, 7 do
		local x = -21 + i * 6
		local lamp = at(x, 32, 5.4) * CFrame.Angles(math.rad(-55), 0, 0)
		cyl(m, 1.6 * s, 2.2 * s, lamp, C.iron)
		cyl(m, 1.3 * s, 0.2 * s, lamp * CFrame.new(0, -1.15 * s, 0), BULBS[i % #BULBS + 1], M.Neon)
	end
	for i = 0, 7 do
		block(m, S(1.4, 1.4, 0.3), at(-19.25 + i * 5.5, 2, -11.1) * CFrame.Angles(0, 0, math.rad(45)), C.gold, M.Neon)
	end
	for row = 0, 2 do
		for col = -1, 1 do
			Dress.bench(m, at(col * 10, 0, -22 - row * 6), { main })
		end
	end
	for _, x in { -33, 33 } do
		pennant(m, pt(x, 38, 4), cf.RightVector * (if x > 0 then 1 else -1), 4 * s, accent)
		rod(m, pt(x, 34, 4), pt(x, 38.2, 4), 0.3 * s, C.white)
	end
	-- SHOW TONIGHT boards either side of the stage
	for _, x in { -42, 42 } do
		for _, dx in { -5, 5 } do
			cyl(m, 0.6 * s, 11 * s, at(x + dx, 5.5, -12), C.white, nil, true)
			ball(m, 1.2 * s, pt(x + dx, 11.4, -12), C.gold)
		end
		signBoard(m, at(x, 8.4, -12), 8.6 * s, 5 * s, "SHOW TONIGHT!", rgb(30, 24, 70), C.gold, hi, true)
	end
	-- the bursts: big, slow, streaking stars high over the stage, a new one every 0.9 s
	local SPARKS = { rgb(255, 80, 120), rgb(255, 214, 60), rgb(90, 220, 255), rgb(140, 255, 120), rgb(200, 120, 255),
		rgb(255, 150, 60) }
	local first
	for i = 0, 7 do
		local holder = anchorPart(m, pt(-42 + i * 12, 74 + (i % 3) * 18, 4 + (i % 2) * 18))
		first = first or holder
		local col = SPARKS[i % #SPARKS + 1]
		local e = emitter(holder, col, 260 / 0.15, NumberRange.new(30, 44), NumberRange.new(2, 3), 3.6 * s, 180)
		e.Color = ColorSequence.new({ ColorSequenceKeypoint.new(0, C.white), ColorSequenceKeypoint.new(0.15, col),
			ColorSequenceKeypoint.new(1, col) })
		e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 3.6 * s), NumberSequenceKeypoint.new(0.7, 2.4 * s),
			NumberSequenceKeypoint.new(1, 0) })
		e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(0.75, 0.15),
			NumberSequenceKeypoint.new(1, 1) })
		e.Orientation = Enum.ParticleOrientation.VelocityParallel
		e.Squash = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.2), NumberSequenceKeypoint.new(1, 0.6) })
		e.Drag = 1.4
		e.Acceleration = v3(0, -9, 0)
		e.Enabled = false
		e:SetAttribute("WKBurst", 260)
	end
	motion(first, "bursts", {})
end

function LM.droptower(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent, hi = pal[1], pal[2], pal[3]
	cyl(m, 30 * s, 2 * s, at(0, 1, 0), accent, nil, true)
	cyl(m, 32 * s, 0.8 * s, at(0, 0.4, 0), C.stone, M.Concrete, true)
	for i = 0, 12 do
		cyl(m, 7 * s, 10 * s, at(0, 7 + i * 10, 0), if i % 2 == 0 then main else C.cream, nil, true)
	end
	for i = 0, 3 do
		local a = i / 4 * TAU + math.pi / 4
		rod(m, pt(math.cos(a) * 4.2, 2, math.sin(a) * 4.2), pt(math.cos(a) * 4.2, 130, math.sin(a) * 4.2), 0.7 * s, C.metal, M.Metal)
	end
	cyl(m, 15 * s, 2 * s, at(0, 133, 0), hi)
	bulbRing(m, at(0, 133, 0), 7.6 * s, 18, 0.9 * s, BULBS)
	ball(m, 8 * s, pt(0, 136, 0), C.gold)
	rod(m, pt(0, 139, 0), pt(0, 148, 0), 0.6 * s, C.white)
	pennant(m, pt(0, 148, 0), cf.RightVector, 5 * s, main)
	for i = 0, 7 do
		local a = i / 8 * TAU
		pennant(m, pt(math.cos(a) * 3.6, 30 + i * 12, math.sin(a) * 3.6), v3(math.cos(a), 0, math.sin(a)), 2.8 * s,
			BRIGHT[i % #BRIGHT + 1])
	end
	railRing(m, at(0, 2, 0), 14 * s, 16, s, C.white, main, -math.pi / 2)
	for i = 0, 7 do
		local a = i / 8 * TAU + math.pi / 8
		local base = pt(math.cos(a) * 7.2, 134, math.sin(a) * 7.2)
		rod(m, base, base + v3(0, 4 * s, 0), 0.25 * s, C.white)
		pennant(m, base + v3(0, 4 * s, 0), v3(math.cos(a), 0, math.sin(a)), 2.4 * s, BRIGHT[i % #BRIGHT + 1])
	end
	local car = Instance.new("Model")
	car.Name = "DropCar"
	local ringPart = cyl(car, 13 * s, 1.4 * s, at(0, 8, 0), hi)
	for i = 0, 7 do
		local a = i / 8 * TAU
		local f = at(math.cos(a) * 7.6, 7.2, math.sin(a) * 7.6) * CFrame.Angles(0, -a + math.pi / 2, 0)
		block(car, S(2.2, 3, 0.6), f * CFrame.new(0, 0, -0.6 * s), accent)
		block(car, S(2.2, 0.5, 1.6), f * CFrame.new(0, -1.3 * s, 0.4 * s), C.ink)
		rod(car, (f * CFrame.new(-0.9 * s, 0.6 * s, 0.7 * s)).Position, (f * CFrame.new(0.9 * s, 0.6 * s, 0.7 * s)).Position,
			0.3 * s, C.gold)
	end
	rig(car, ringPart)
	car.Parent = m
	motion(ringPart, "drop", { Pivot = cf, Scale = s })
	signBoard(m, at(0, 3.6, -15.6), 14 * s, 3 * s, KINDS.droptower.sign, C.cream, main, accent)
end

-- ============================================================== dressing

local STALLS = {
	{ "POPCORN", "popcorn" }, { "ICE CREAM", "icecream" }, { "HOT DOGS", "hotdog" }, { "CANDY FLOSS", "candyfloss" },
	{ "LEMONADE", "drink" }, { "PRIZES", "prizes" }, { "HOOK A DUCK", "duck" }, { "BURGERS", "burger" },
	{ "RING TOSS", "prizes" },
}

local PROPS = {}
function PROPS.popcorn(m, cf)
	cyl(m, 3.2, 3.4, cf * CFrame.new(0, 1.7, 0), C.white)
	for i = 0, 3 do
		local a = i / 4 * TAU
		block(m, v3(0.6, 3.4, 0.3), cf * CFrame.Angles(0, a, 0) * CFrame.new(0, 1.7, -1.55), C.red)
	end
	for i = 0, 4 do
		local a = i / 5 * TAU
		ball(m, 1.5, (cf * CFrame.new(math.cos(a) * 0.9, 3.6 + (i % 2) * 0.4, math.sin(a) * 0.9)).Position, rgb(255, 240, 190))
	end
end
function PROPS.icecream(m, cf)
	cyl(m, 2, 3.4, cf * CFrame.new(0, 1.7, 0), rgb(214, 160, 90))
	ball(m, 2.6, (cf * CFrame.new(0, 3.8, 0)).Position, rgb(255, 170, 200))
	ball(m, 2.4, (cf * CFrame.new(0, 5.6, 0)).Position, rgb(150, 236, 200))
	ball(m, 0.9, (cf * CFrame.new(0, 7.1, 0)).Position, C.red)
end
function PROPS.hotdog(m, cf)
	for _, z in { -0.55, 0.55 } do
		mk("Part", m, v3(5.4, 1.5, 1.5), cf * CFrame.new(0, 1.2, z), rgb(222, 166, 96), nil, false, CYL)
	end
	mk("Part", m, v3(6.2, 1.2, 1.2), cf * CFrame.new(0, 1.9, 0), rgb(196, 70, 50), nil, false, CYL)
	block(m, v3(5, 0.2, 0.4), cf * CFrame.new(0, 2.55, 0), C.gold)
end
function PROPS.candyfloss(m, cf)
	rod(m, (cf * CFrame.new(0, 0, 0)).Position, (cf * CFrame.new(0, 3, 0)).Position, 0.3, C.white)
	ball(m, 3.2, (cf * CFrame.new(0, 4, 0)).Position, rgb(255, 160, 210))
	ball(m, 2.6, (cf * CFrame.new(1.1, 4.8, 0.3)).Position, rgb(255, 186, 222))
	ball(m, 2.4, (cf * CFrame.new(-1, 4.6, -0.4)).Position, rgb(255, 140, 200))
end
function PROPS.drink(m, cf)
	cyl(m, 2.6, 3.6, cf * CFrame.new(0, 1.8, 0), rgb(255, 230, 90))
	cyl(m, 2.9, 0.4, cf * CFrame.new(0, 3.8, 0), C.white)
	rod(m, (cf * CFrame.new(0.3, 3.8, 0)).Position, (cf * CFrame.new(1.2, 6.2, 0)).Position, 0.35, C.red)
	mk("Part", m, v3(0.3, 1.8, 1.8), cf * CFrame.new(-1.4, 3.6, 0) * ALONG_Z, rgb(255, 250, 120), nil, false, CYL)
end
function PROPS.prizes(m, cf)
	ball(m, 2.8, (cf * CFrame.new(0, 1.4, 0)).Position, rgb(190, 130, 80))
	ball(m, 2.2, (cf * CFrame.new(0, 3.6, 0)).Position, rgb(190, 130, 80))
	for _, x in { -0.8, 0.8 } do
		ball(m, 0.8, (cf * CFrame.new(x, 4.6, 0)).Position, rgb(170, 110, 66))
	end
	ball(m, 0.9, (cf * CFrame.new(0, 3.4, -0.9)).Position, rgb(240, 214, 180))
end
function PROPS.duck(m, cf)
	ball(m, 2.8, (cf * CFrame.new(0, 1.4, 0)).Position, rgb(255, 214, 40))
	ball(m, 1.9, (cf * CFrame.new(0, 3.1, -0.9)).Position, rgb(255, 214, 40))
	block(m, v3(0.9, 0.4, 1), cf * CFrame.new(0, 3, -2.1), rgb(255, 130, 30))
end
function PROPS.burger(m, cf)
	cyl(m, 3.4, 0.8, cf * CFrame.new(0, 0.4, 0), rgb(222, 160, 90))
	cyl(m, 3.7, 0.7, cf * CFrame.new(0, 1.1, 0), rgb(110, 60, 40))
	block(m, v3(3.3, 0.2, 3.3), cf * CFrame.new(0, 1.55, 0) * CFrame.Angles(0, math.rad(45), 0), C.gold)
	cyl(m, 3.9, 0.3, cf * CFrame.new(0, 1.7, 0), rgb(110, 200, 80))
	ball(m, 3.4, (cf * CFrame.new(0, 2.0, 0)).Position, rgb(222, 160, 90))
end

function Dress.stall(m, cf, pal, rng, text)
	local kind = STALLS[rng:NextInteger(1, #STALLS)]
	if type(text) == "string" and text ~= "" then
		kind = { string.upper(text), "popcorn" }
		for _, k in STALLS do
			if k[1] == kind[1] then
				kind = k
			end
		end
	end
	local main, accent = pal[1], pal[2]
	block(m, v3(12, 0.6, 9), cf * CFrame.new(0, 0.3, 0), C.darkWood, M.WoodPlanks, true)
	block(m, v3(12, 9, 0.6), cf * CFrame.new(0, 4.8, 4.2), C.cream, M.WoodPlanks, true)
	for _, x in { -5.7, 5.7 } do
		block(m, v3(0.6, 9, 9), cf * CFrame.new(x, 4.8, 0), main, nil, true)
	end
	block(m, v3(12, 3.6, 1.4), cf * CFrame.new(0, 2.4, -3.6), main, nil, true)
	block(m, v3(12.4, 0.4, 2.2), cf * CFrame.new(0, 4.4, -3.6), C.cream, M.WoodPlanks, true)
	for i = -2, 2 do
		block(m, v3(1, 3.2, 0.2), cf * CFrame.new(i * 2.4, 2.4, -4.35), accent)
	end
	block(m, v3(12.8, 0.6, 9.6), cf * CFrame.new(0, 9.6, 0), C.cream, nil, true)
	local w = 12.8 / 6
	for i = 0, 5 do
		local x = -6.4 + w * (i + 0.5)
		local col = if i % 2 == 0 then accent else C.white
		block(m, v3(w, 0.25, 4.2), cf * CFrame.new(x, 8.6, -6.4) * CFrame.Angles(math.rad(-25), 0, 0), col, M.SmoothPlastic)
		ball(m, w * 0.95, (cf * CFrame.new(x, 7.6, -8.2)).Position, col, M.SmoothPlastic)
	end
	signBoard(m, cf * CFrame.new(0, 11.7, -2), 10, 2.8, kind[1], C.white, main, accent)
	PROPS[kind[2]](m, cf * CFrame.new(0, 9.9, 2.2))
	for i = 1, 4 do
		ball(m, 0.9, (cf * CFrame.new(-4 + i * 1.6, 5.05, -3.4)).Position, BRIGHT[(i + rng:NextInteger(0, 6)) % #BRIGHT + 1])
	end
end

function Dress.lamp(m, cf, pal)
	cyl(m, 1.8, 1, cf * CFrame.new(0, 0.5, 0), C.iron, M.Metal, true)
	cyl(m, 0.55, 12, cf * CFrame.new(0, 6.5, 0), C.iron, M.Metal, true)
	block(m, v3(1.6, 0.5, 1.6), cf * CFrame.new(0, 12.6, 0), C.iron, M.Metal)
	local lantern = block(m, v3(1.2, 1.6, 1.2), cf * CFrame.new(0, 13.6, 0), C.warm, M.Neon)
	block(m, v3(1.9, 0.4, 1.9), cf * CFrame.new(0, 14.6, 0), pal[1])
	ball(m, 0.7, (cf * CFrame.new(0, 15.1, 0)).Position, C.gold)
	return lantern
end

function Dress.bench(m, cf, pal)
	for _, x in { -2.6, 2.6 } do
		block(m, v3(0.4, 1.8, 2.2), cf * CFrame.new(x, 0.9, 0.1), C.iron, M.Metal, true)
	end
	block(m, v3(6.2, 0.3, 1), cf * CFrame.new(0, 1.85, -0.45), C.wood, M.Wood, true)
	block(m, v3(6.2, 0.3, 1), cf * CFrame.new(0, 1.85, 0.6), C.wood, M.Wood, true)
	block(m, v3(6.2, 0.8, 0.25), cf * CFrame.new(0, 2.9, 1.15) * CFrame.Angles(math.rad(12), 0, 0), C.wood, M.Wood, true)
	block(m, v3(6.2, 0.5, 0.25), cf * CFrame.new(0, 3.75, 1.3) * CFrame.Angles(math.rad(12), 0, 0), pal[1], nil, true)
end

function Dress.tree(m, cf, pal, rng)
	local h = rng:NextNumber(5, 8)
	cyl(m, 1.6, h, cf * CFrame.new(0, h / 2, 0), C.trunk, M.Wood, true)
	local g = GREENS[rng:NextInteger(1, #GREENS)]
	local g2 = GREENS[rng:NextInteger(1, #GREENS)]
	ball(m, rng:NextNumber(9.5, 11.5), (cf * CFrame.new(0, h + 3.5, 0)).Position, g, M.Grass, true)
	ball(m, rng:NextNumber(6.5, 8), (cf * CFrame.new(rng:NextNumber(-3, 3), h + 1.8, rng:NextNumber(-3, 3))).Position, g2, M.Grass)
	ball(m, rng:NextNumber(5.5, 7), (cf * CFrame.new(rng:NextNumber(-2, 2), h + 6.5, rng:NextNumber(-2, 2))).Position, g, M.Grass)
end

function Dress.cypress(m, cf, pal, rng)
	local h = rng:NextNumber(12, 16)
	cyl(m, 1.2, 3, cf * CFrame.new(0, 1.5, 0), C.trunk, M.Wood, true)
	blob(m, v3(4.6, h, 4.6), cf * CFrame.new(0, 2 + h / 2, 0), GREENS[rng:NextInteger(1, #GREENS)], M.Grass)
end

function Dress.balloon_cluster(m, cf, pal, rng)
	local weight = block(m, v3(1.4, 1.2, 1.4), cf * CFrame.new(0, 0.6, 0), pal[1], nil, true)
	local knot = weight.Position + v3(0, 0.6, 0)
	for i = 1, 7 do
		local a = i / 7 * TAU + rng:NextNumber(-0.3, 0.3)
		local r = if i == 7 then 0 else rng:NextNumber(1.6, 2.6)
		local y = rng:NextNumber(10, 13) + (if i == 7 then 1.8 else 0)
		local p = (cf * CFrame.new(math.cos(a) * r, y, math.sin(a) * r)).Position
		local d = rng:NextNumber(2.6, 3.2)
		local b = ball(m, d, p, BRIGHT[(i + rng:NextInteger(0, 6)) % #BRIGHT + 1])
		b.Reflectance = 0.12
		wire(weight, knot, b, p - v3(0, d / 2, 0), 0, rgb(245, 245, 245), 0.06)
	end
end

function Dress.string_lights(m, cf, pal)
	local a = Dress.lamp(m, cf * CFrame.new(0, 0, 12), pal)
	local b = Dress.lamp(m, cf * CFrame.new(0, 0, -12), pal)
	lights(m, a, a.Position + v3(0, 0.6, 0), b, b.Position + v3(0, 0.6, 0), 2.2, 9)
end

function Dress.sign(m, cf, pal, rng, text)
	for _, x in { -3.4, 3.4 } do
		cyl(m, 0.5, 7.4, cf * CFrame.new(x, 3.7, 0), C.darkWood, M.Wood, true)
	end
	signBoard(m, cf * CFrame.new(0, 6.2, 0), 8, 3, if type(text) == "string" and text ~= "" then string.upper(text) else "FUN THIS WAY!",
		pal[1], C.white, C.gold, true)
	ball(m, 1, (cf * CFrame.new(0, 8.3, 0)).Position, C.gold)
end

function Dress.fence(m, cf, pal)
	for _, x in { -8, 8 } do
		block(m, v3(0.8, 4.2, 0.8), cf * CFrame.new(x, 2.1, 0), C.white, nil, true)
		ball(m, 1.1, (cf * CFrame.new(x, 4.5, 0)).Position, pal[1])
	end
	block(m, v3(16, 0.5, 0.35), cf * CFrame.new(0, 3.3, 0), C.white, nil, true)
	block(m, v3(16, 0.5, 0.35), cf * CFrame.new(0, 1.6, 0), C.white, nil, true)
end

function Dress.popcorn_cart(m, cf, pal)
	block(m, v3(4.6, 2.6, 2.8), cf * CFrame.new(0, 2.9, 0), pal[1], nil, true)
	for i = -1, 1 do
		block(m, v3(0.5, 2.4, 0.15), cf * CFrame.new(i * 1.4, 2.9, -1.45), C.white)
	end
	for _, x in { -1.8, 1.8 } do
		mk("Part", m, v3(0.4, 2.4, 2.4), cf * CFrame.new(x, 1.2, -1.6) * ALONG_Z, C.ink, nil, true, CYL)
		mk("Part", m, v3(0.5, 0.8, 0.8), cf * CFrame.new(x, 1.2, -1.65) * ALONG_Z, C.gold, nil, false, CYL)
	end
	local glass = block(m, v3(3.8, 2.6, 2.4), cf * CFrame.new(0, 5.5, 0), rgb(220, 240, 255), M.Glass)
	glass.Transparency = 0.55
	for i = 0, 5 do
		ball(m, 0.9, (cf * CFrame.new(-1.2 + (i % 3) * 1.2, 4.6 + math.floor(i / 3) * 0.8, 0)).Position, rgb(255, 238, 170))
	end
	block(m, v3(4.4, 0.4, 3), cf * CFrame.new(0, 7, 0), pal[2])
	rod(m, (cf * CFrame.new(0, 7, 0)).Position, (cf * CFrame.new(0, 11, 0)).Position, 0.25, C.white)
	local apex = cone(m, cf * CFrame.new(0, 10.2, 0), 4.6, 1.8, 8, { pal[1], C.white }, M.SmoothPlastic)
	ball(m, 0.6, apex + v3(0, 0.3, 0), C.gold)
	bar(m, (cf * CFrame.new(-2.4, 4, 2)).Position, (cf * CFrame.new(-2.4, 4, 3.4)).Position, 0.3, 0.3, C.iron)
end

function Dress.flower_bed(m, cf, pal, rng)
	local w, l = rng:NextNumber(6, 10), rng:NextNumber(4, 7)
	block(m, v3(w + 1, 0.9, l + 1), cf * CFrame.new(0, 0.45, 0), C.stone, M.Cobblestone, true)
	block(m, v3(w, 0.4, l), cf * CFrame.new(0, 0.95, 0), C.soil, M.Ground)
	for _ = 1, 3 do
		ball(m, rng:NextNumber(1.8, 2.6), (cf * CFrame.new(rng:NextNumber(-w / 3, w / 3), 1.6, rng:NextNumber(-l / 4, l / 4))).Position,
			GREENS[rng:NextInteger(1, #GREENS)], M.Grass)
	end
	local fl = { rgb(255, 92, 140), rgb(255, 214, 60), rgb(255, 255, 255), rgb(190, 110, 255), rgb(255, 140, 60) }
	for _ = 1, 7 do
		ball(m, rng:NextNumber(0.9, 1.3), (cf * CFrame.new(rng:NextNumber(-w / 2 + 0.6, w / 2 - 0.6), 1.5,
			rng:NextNumber(-l / 2 + 0.6, l / 2 - 0.6))).Position, fl[rng:NextInteger(1, #fl)])
	end
end

local FLOWERS = { rgb(255, 72, 120), rgb(255, 210, 50), rgb(255, 255, 255), rgb(176, 96, 255), rgb(255, 140, 50),
	rgb(70, 190, 255) }

-- one 3D flower: a stem, two leaves and a bloom with a contrasting heart
local function flower(m, at: Vector3, h: number, color: Color3, d: number)
	rod(m, at, at + v3(0, h, 0), 0.22, rgb(64, 150, 60))
	ball(m, d, at + v3(0, h + d * 0.2, 0), color)
	ball(m, d * 0.42, at + v3(0, h + d * 0.62, 0), if color == C.white or color == FLOWERS[2] then rgb(255, 140, 40) else C.gold)
end

local function hedge(m, a: Vector3, b: Vector3, h: number, w: number)
	return bar(m, a + v3(0, h / 2, 0), b + v3(0, h / 2, 0), w, h, rgb(58, 134, 62), M.LeafyGrass, true)
end

-- a garden you can read from a course above it: raised beds of real flowers inside clipped hedges, never taller
-- than 4 studs; three layouts in many sizes, so no two lawns look alike
function Dress.flower_garden(m, cf, pal, rng)
	local layout = rng:NextInteger(1, 3)
	local k = rng:NextInteger(0, #FLOWERS - 1)
	local cols = { FLOWERS[k + 1], FLOWERS[(k + 2) % #FLOWERS + 1], FLOWERS[(k + 4) % #FLOWERS + 1] }
	if layout == 1 then -- a round bed: stone rim, rings of flowers, a topiary in the middle
		local r = rng:NextNumber(5.5, 9)
		cyl(m, r * 2 + 1.4, 0.9, cf * CFrame.new(0, 0.45, 0), C.stone, M.Cobblestone, true)
		cyl(m, r * 2, 0.3, cf * CFrame.new(0, 0.95, 0), C.soil, M.Ground)
		for ring = 1, 2 do
			local rr = r * (if ring == 1 then 0.78 else 0.45)
			local n = math.floor(rr * 1.3)
			for i = 0, n - 1 do
				local a = i / n * TAU + ring
				flower(m, (cf * CFrame.new(math.cos(a) * rr, 1.1, math.sin(a) * rr)).Position, rng:NextNumber(1.1, 1.8),
					cols[ring], rng:NextNumber(1.0, 1.3))
			end
		end
		rod(m, (cf * CFrame.new(0, 1, 0)).Position, (cf * CFrame.new(0, 2.2, 0)).Position, 0.5, C.trunk)
		ball(m, 2.6, (cf * CFrame.new(0, 3.2, 0)).Position, GREENS[rng:NextInteger(1, #GREENS)], M.LeafyGrass)
	elseif layout == 2 then -- a long bed in a box hedge, rows of tulips, topiary balls on the corners
		local w, l = rng:NextNumber(12, 22), rng:NextNumber(6, 9)
		block(m, v3(w, 0.3, l), cf * CFrame.new(0, 0.15, 0), C.soil, M.Ground)
		for _, sz in { -1, 1 } do
			hedge(m, (cf * v3(-w / 2, 0, sz * l / 2)), (cf * v3(w / 2, 0, sz * l / 2)), 1.6, 1.2)
			hedge(m, (cf * v3(sz * w / 2, 0, -l / 2)), (cf * v3(sz * w / 2, 0, l / 2)), 1.6, 1.2)
			for _, sx in { -1, 1 } do
				ball(m, 2.2, (cf * v3(sx * w / 2, 2.3, sz * l / 2)), rgb(70, 150, 70), M.LeafyGrass)
			end
		end
		local rows = math.floor(l / 2.2)
		for row = 1, rows do
			local z = -l / 2 + row * l / (rows + 1)
			for x = -w / 2 + 2, w / 2 - 1.5, 2.1 do
				flower(m, (cf * v3(x + rng:NextNumber(-0.3, 0.3), 0.3, z)), rng:NextNumber(0.9, 1.5), cols[row % 2 + 1], 1.0)
			end
		end
	else -- a knot garden: a hedge cross, a flower bed in each quarter and a sundial in the middle
		local h = rng:NextNumber(8, 11)
		block(m, v3(h * 2 + 2, 0.4, h * 2 + 2), cf * CFrame.new(0, 0.2, 0), rgb(228, 206, 168), M.Limestone, true)
		hedge(m, (cf * v3(-h, 0, 0)), (cf * v3(-2, 0, 0)), 1.4, 1)
		hedge(m, (cf * v3(2, 0, 0)), (cf * v3(h, 0, 0)), 1.4, 1)
		hedge(m, (cf * v3(0, 0, -h)), (cf * v3(0, 0, -2)), 1.4, 1)
		hedge(m, (cf * v3(0, 0, 2)), (cf * v3(0, 0, h)), 1.4, 1)
		for q = 0, 3 do
			local a = q * math.pi / 2 + math.pi / 4
			local c = cf * CFrame.new(math.cos(a) * h * 0.6, 0.4, math.sin(a) * h * 0.6)
			cyl(m, h * 0.7, 0.3, c * CFrame.new(0, 0.15, 0), C.soil, M.Ground)
			for i = 0, 4 do
				local b = i / 5 * TAU
				flower(m, (c * v3(math.cos(b) * h * 0.2, 0.3, math.sin(b) * h * 0.2)), 1.2, cols[q % 3 + 1], 1.1)
			end
		end
		cyl(m, 1.4, 2.4, cf * CFrame.new(0, 1.6, 0), C.stone, M.Marble, true)
		cyl(m, 2.4, 0.3, cf * CFrame.new(0, 2.95, 0), C.gold, M.Metal)
	end
end

-- a café table under a striped umbrella, with stools (the umbrella's top 5.6 studs up)
function Dress.picnic(m, cf, pal, rng)
	local c = BRIGHT[rng:NextInteger(1, #BRIGHT)]
	cyl(m, 1.6, 0.3, cf * CFrame.new(0, 0.15, 0), C.iron, M.Metal, true)
	rod(m, (cf * v3(0, 0.2, 0)), (cf * v3(0, 2.4, 0)), 0.4, C.iron)
	cyl(m, 4.2, 0.3, cf * CFrame.new(0, 2.5, 0), C.white, nil, true)
	rod(m, (cf * v3(0, 2.6, 0)), (cf * v3(0, 4.9, 0)), 0.25, C.white)
	local apex = cone(m, cf * CFrame.new(0, 4.2, 0), 4.2, 1.2, 8, { c, C.white }, M.SmoothPlastic, rng:NextNumber(0, 1))
	ball(m, 0.5, apex + v3(0, 0.15, 0), C.gold)
	for i = 0, rng:NextInteger(2, 3) do
		local a = i / 4 * TAU + rng:NextNumber(-0.2, 0.2)
		local p = cf * CFrame.new(math.cos(a) * 3.4, 0, math.sin(a) * 3.4)
		cyl(m, 1.8, 0.4, p * CFrame.new(0, 1.7, 0), c, nil, true)
		rod(m, p.Position, (p * v3(0, 1.5, 0)), 0.3, C.iron)
	end
end

-- a mini-golf hole: a green with rails, a hole and flag, and a little windmill to putt through (5.6 studs)
function Dress.mini_golf(m, cf, pal, rng)
	local w, l = 6, rng:NextNumber(14, 20)
	block(m, v3(w + 1.2, 0.4, l + 1.2), cf * CFrame.new(0, 0.2, 0), pal[1], nil, true)
	block(m, v3(w, 0.3, l), cf * CFrame.new(0, 0.45, 0), rgb(56, 168, 82), M.Fabric, true)
	for _, sx in { -1, 1 } do
		block(m, v3(0.5, 0.7, l + 1.2), cf * CFrame.new(sx * (w / 2 + 0.35), 0.75, 0), C.white, nil, true)
	end
	cyl(m, 0.9, 0.05, cf * CFrame.new(0, 0.62, -l / 2 + 2), C.ink)
	rod(m, (cf * v3(0.3, 0.6, -l / 2 + 2)), (cf * v3(0.3, 4.2, -l / 2 + 2)), 0.15, C.white)
	pennant(m, (cf * v3(0.3, 4.2, -l / 2 + 2)), cf.RightVector, 1.6, C.red)
	ball(m, 0.5, (cf * v3(-1, 0.85, l / 2 - 2)), C.white)
	local mill = cf * CFrame.new(0, 0.6, 1)
	block(m, v3(4.4, 2.6, 2.6), mill * CFrame.new(0, 1.3, 0), C.cream, M.WoodPlanks, true)
	block(m, v3(1.8, 1.6, 2.8), mill * CFrame.new(0, 0.8, 0), C.ink)
	local apex = cone(m, mill * CFrame.new(0, 2.6, 0), 2.6, 1.6, 6, { pal[2] or C.red, C.white }, M.SmoothPlastic)
	local hub = (mill * CFrame.new(0, 3.4, -1.5)).Position
	ball(m, 0.6, hub, C.gold)
	for i = 0, 3 do
		local a = i / 4 * TAU + rng:NextNumber(0, 1)
		bar(m, hub, hub + (cf.RightVector * math.cos(a) + cf.UpVector * math.sin(a)) * 1.5, 0.15, 0.7, C.white, nil, false,
			cf.LookVector)
	end
	ball(m, 0.4, apex + v3(0, 0.2, 0), C.gold)
end

-- a queue maze of low rails in two colours (3 studs)
function Dress.queue_fence(m, cf, pal, rng)
	local lanes, len = rng:NextInteger(3, 4), rng:NextNumber(10, 14)
	for lane = 0, lanes do
		local z = (lane - lanes / 2) * 3.2
		local from, to = -len / 2 + (if lane % 2 == 0 then 0 else 2.4), len / 2 - (if lane % 2 == 0 then 2.4 else 0)
		if lane == 0 or lane == lanes then
			from, to = -len / 2, len / 2
		end
		local a, b = cf * v3(from, 0, z), cf * v3(to, 0, z)
		for _, p in { a, b } do
			cyl(m, 0.5, 3, CFrame.new(p + v3(0, 1.5, 0)) * cf.Rotation, C.gold, M.Metal, true)
			ball(m, 0.7, p + v3(0, 3.1, 0), C.gold, M.Metal)
		end
		bar(m, a + v3(0, 2.6, 0), b + v3(0, 2.6, 0), 0.3, 0.5, if lane % 2 == 0 then pal[1] else C.red, nil, true)
		bar(m, a + v3(0, 1.3, 0), b + v3(0, 1.3, 0), 0.3, 0.3, C.white, nil, true)
	end
end

-- kiddie corner: spring-rider animals on a soft mat (4 studs)
function Dress.kiddie_ride(m, cf, pal, rng)
	cyl(m, 15, 0.3, cf * CFrame.new(0, 0.15, 0), rgb(90, 200, 220), nil, true)
	cyl(m, 16, 0.2, cf * CFrame.new(0, 0.1, 0), C.white, nil, true)
	for i = 0, 2 do
		local a = i / 3 * TAU + rng:NextNumber(0, 0.6)
		local base = cf * CFrame.new(math.cos(a) * 4.2, 0.3, math.sin(a) * 4.2) * CFrame.Angles(0, -a, 0)
		local col = BRIGHT[(i * 2 + rng:NextInteger(0, 6)) % #BRIGHT + 1]
		rod(m, base.Position, (base * v3(0, 1.4, 0)), 0.5, C.metal, M.Metal)
		if i == 0 then -- a duck
			ball(m, 2.2, (base * v3(0, 2.2, 0)), rgb(255, 214, 40))
			ball(m, 1.4, (base * v3(0, 3.4, -0.8)), rgb(255, 214, 40))
			block(m, v3(0.6, 0.3, 0.7), base * CFrame.new(0, 3.3, -1.6), rgb(255, 130, 30))
		elseif i == 1 then -- a little car
			block(m, v3(1.8, 1.0, 3), base * CFrame.new(0, 2.0, 0), col)
			block(m, v3(1.6, 0.8, 1.2), base * CFrame.new(0, 2.8, 0.4), C.white)
			for _, x in { -0.95, 0.95 } do
				for _, z in { -1, 1 } do
					mk("Part", m, v3(0.3, 0.8, 0.8), base * CFrame.new(x, 1.6, z), C.ink, nil, false, CYL)
				end
			end
		else -- a pony
			block(m, v3(1.2, 1.2, 2.6), base * CFrame.new(0, 2.1, 0), col)
			block(m, v3(0.9, 1.6, 0.9), base * CFrame.new(0, 3.0, -1.2) * CFrame.Angles(math.rad(-20), 0, 0), col)
			block(m, v3(0.3, 1.2, 0.6), base * CFrame.new(0, 3.1, -0.8) * CFrame.Angles(math.rad(-20), 0, 0), C.cream)
		end
	end
	Dress.bench(m, cf * CFrame.new(0, 0.3, 7) * CFrame.Angles(0, math.pi, 0), pal)
end

-- a balloon arch over a side walk: 17 balloons on a 12-stud arch between two weights
function Dress.balloon_arch(m, cf, pal, rng)
	for _, x in { -6.5, 6.5 } do
		block(m, v3(1.6, 1.2, 1.6), cf * CFrame.new(x, 0.6, 0), pal[1] or C.red, nil, true)
	end
	local k0 = rng:NextInteger(0, #BRIGHT - 1)
	for i = 0, 16 do
		local a = math.pi * i / 16
		for _, z in { -0.9, 0.9 } do
			ball(m, 2.5, (cf * v3(-math.cos(a) * 6.5, 1.2 + math.sin(a) * 10.5, z)), BRIGHT[(k0 + i + (if z > 0 then 2 else 0)) % #BRIGHT + 1])
		end
	end
end

-- Water in the two voxel layers under the grass inside a circle. Terrain fills with Water do not replace
-- solid voxels and round partial ones unpredictably, so the voxels are written directly (4-stud grid;
-- a full layer whose top is at y renders its surface at y + 2).
local function waterDisc(center: Vector3, r: number)
	local T = workspace.Terrain
	local top = 4 * math.floor((center.Y - 2) / 4 + 0.5)
	local lo = v3(4 * math.floor((center.X - r - 2) / 4), top - 8, 4 * math.floor((center.Z - r - 2) / 4))
	local hi = v3(4 * math.ceil((center.X + r + 2) / 4), top, 4 * math.ceil((center.Z + r + 2) / 4))
	local region = Region3.new(lo, hi)
	local mats, occ = T:ReadVoxels(region, 4)
	for x = 1, #mats do
		for y = 1, #mats[x] do
			for z = 1, #mats[x][y] do
				local px, pz = lo.X + (x - 0.5) * 4, lo.Z + (z - 0.5) * 4
				if (px - center.X) ^ 2 + (pz - center.Z) ^ 2 <= r * r then
					mats[x][y][z] = M.Water
					occ[x][y][z] = 1
				end
			end
		end
	end
	T:WriteVoxels(region, 4, mats, occ)
end

function Dress.pond(m, cf, pal, rng)
	local r = rng:NextNumber(14, 22)
	waterDisc(cf.Position, r)
	ring(m, cf * CFrame.new(0, 0.3, 0), r + 1, 20, 2.6, 0.9, C.stone, M.Cobblestone, true)
	for _ = 1, 5 do
		local a, d = rng:NextNumber(0, TAU), rng:NextNumber(3, r - 3)
		cyl(m, rng:NextNumber(2, 3.2), 0.15, cf * CFrame.new(math.cos(a) * d, -0.7, math.sin(a) * d), rgb(70, 160, 70))
	end
	local jet = rod(m, (cf * CFrame.new(0, -0.8, 0)).Position, (cf * CFrame.new(0, 4.2, 0)).Position, 0.8, rgb(200, 240, 255), M.Glass)
	jet.Transparency = 0.35
	ball(m, 1.8, (cf * CFrame.new(0, 4.3, 0)).Position, rgb(220, 248, 255), M.Glass).Transparency = 0.3
end

-- ============================================================== small attractions (the lawns inside the ring)

local Small = {}

function Small.swings(m, cf, pal, s)
	local at, pt, S = space(cf, s)
	local main, accent = pal[1], pal[2]
	cyl(m, 32 * s, 1 * s, at(0, 0.5, 0), C.cream, nil, true)
	cyl(m, 33.4 * s, 0.6 * s, at(0, 0.3, 0), accent, nil, true)
	for i = 0, 2 do
		cyl(m, 3.2 * s, 6 * s, at(0, 4 + i * 6, 0), if i % 2 == 0 then main else C.cream, nil, true)
	end
	local top = Instance.new("Model")
	top.Name = "Swings"
	local hub = cyl(top, 5 * s, 2 * s, at(0, 20, 0), accent)
	local apex = cone(top, at(0, 21, 0), 12.5 * s, 4.5 * s, 12, { main, C.cream })
	ball(top, 1.6 * s, apex + v3(0, 0.6 * s, 0), C.gold)
	ring(top, at(0, 20.4, 0), 12.6 * s, 12, 0.5 * s, 1.4 * s, C.gold)
	bulbRing(top, at(0, 20.4, 0), 13.1 * s, 12, 0.7 * s, BULBS)
	for i = 0, 11 do
		local a = (i + 0.5) / 12 * TAU
		local hang = pt(math.cos(a) * 11.5, 19.8, math.sin(a) * 11.5)
		local seat = pt(math.cos(a) * 15, 10, math.sin(a) * 15)
		rod(top, hang, seat + v3(0, 1.2 * s, 0), 0.15 * s, C.metal)
		local f = CFrame.lookAt(seat, seat + cf:VectorToWorldSpace(v3(-math.sin(a), 0, math.cos(a))))
		block(top, S(1.6, 0.4, 1.6), f, BRIGHT[i % #BRIGHT + 1])
		block(top, S(1.6, 1.4, 0.3), f * CFrame.new(0, 0.7 * s, 0.75 * s), BRIGHT[i % #BRIGHT + 1])
	end
	rig(top, hub)
	top.Parent = m
	motion(hub, "spin", { Pivot = cf, Speed = -0.8, Axis = "Y" })
	signBoard(m, at(0, 2.8, -18.5), 12 * s, 2.6 * s, "SKY SWINGS", C.cream, main, accent)
	for _, x in { -6.4, 6.4 } do
		cyl(m, 0.5 * s, 4.1 * s, at(x, 2.05, -18.5), C.gold, nil, true)
	end
end

function Small.bandstand(m, cf, pal, s)
	local at, pt = space(cf, s)
	local main, accent = pal[1], pal[2]
	cyl(m, 24 * s, 1.6 * s, at(0, 0.8, 0), C.cream, nil, true)
	cyl(m, 26 * s, 0.6 * s, at(0, 0.3, 0), C.stone, M.Cobblestone, true)
	for i = 0, 7 do
		local a, b = i / 8 * TAU + math.pi / 8, (i + 1) / 8 * TAU + math.pi / 8
		local p, q = pt(math.cos(a) * 10.5, 1.6, math.sin(a) * 10.5), pt(math.cos(b) * 10.5, 1.6, math.sin(b) * 10.5)
		cyl(m, 0.8 * s, 9 * s, CFrame.new(p + v3(0, 4.5 * s, 0)), C.white, nil, true)
		if i ~= 5 then -- the open side faces the front
			bar(m, p + v3(0, 3 * s, 0), q + v3(0, 3 * s, 0), 0.3 * s, 0.4 * s, main, nil, true)
		end
	end
	cyl(m, 25 * s, 0.6 * s, at(0, 10.3, 0), accent)
	local apex = cone(m, at(0, 10.6, 0), 13 * s, 6 * s, 8, { main, C.cream }, nil, math.pi / 8)
	ball(m, 1.6 * s, apex + v3(0, 0.6 * s, 0), C.gold)
	bulbRing(m, at(0, 10, 0), 12.6 * s, 16, 0.7 * s, BULBS)
	for i = 0, 2 do
		local x = -3 + i * 3
		cyl(m, 1.6 * s, 1.2 * s, at(x, 2.2, 2), BRIGHT[i + 1])
		rod(m, pt(x, 1.6, 4), pt(x, 4, 4), 0.2 * s, C.iron)
	end
end

function Small.booths(m, cf, pal, s, rng)
	cyl(m, 46 * s, 0.6 * s, cf * CFrame.new(0, 0.3 * s, 0), C.paving, M.Limestone, true)
	local names = { "RING TOSS", "HOOK A DUCK", "PRIZES" }
	for i = 0, 2 do
		local a = math.pi / 2 + (i - 1) * 0.95
		local p = (cf * CFrame.new(math.cos(a) * 16 * s, 0.6 * s, math.sin(a) * 16 * s)).Position
		Dress.stall(m, CFrame.lookAt(p, cf.Position + v3(0, p.Y - cf.Position.Y, 0)), pal, rng, names[i + 1])
	end
	Dress.balloon_cluster(m, cf * CFrame.new(0, 0.6 * s, -4 * s), pal, rng)
end

local TRAIN_A, TRAIN_B, TRAIN_N = 20, 11, 32

-- the kiddie train's oval, sampled at TRAIN_N points
local function trainOval()
	local A, B, n = TRAIN_A, TRAIN_B, TRAIN_N
	local L = 4 * A + TAU * B
	local P = {}
	for i = 0, n - 1 do
		local d = i / n * L
		local x, z
		if d < 2 * A then
			x, z = -A + d, -B
		elseif d < 2 * A + math.pi * B then
			local a = (d - 2 * A) / B
			x, z = A + math.sin(a) * B, -math.cos(a) * B
		elseif d < 4 * A + math.pi * B then
			x, z = A - (d - 2 * A - math.pi * B), B
		else
			local a = (d - 4 * A - math.pi * B) / B
			x, z = -A - math.sin(a) * B, math.cos(a) * B
		end
		P[i + 1] = v3(x, 0.9, z)
	end
	return P
end

function PATHS.train(cf: CFrame, s: number)
	local P = trainOval()
	local U = table.create(#P, Vector3.yAxis)
	local times = timetable(P, s, function()
		return 7
	end)
	local frameAt, total = pathFrames(cf, s, P, U, times)
	return frameAt, total, P
end

-- a kiddie train on an oval of track; everything stays under 6 studs, so it may sit below a course
function Small.minitrain(m, cf, pal, s, rng)
	local B, n = TRAIN_B, TRAIN_N
	local frameAt, _, P = pathOf("train", cf, s)
	for i = 1, n do
		local a, b = P[i], P[i % n + 1]
		local sd = (b - a).Unit:Cross(Vector3.yAxis).Unit
		for _, o in { -0.9, 0.9 } do
			rod(m, cf * ((a + sd * o) * s), cf * ((b + sd * o) * s), 0.25 * s, C.iron, M.Metal)
		end
		if i % 2 == 0 then
			bar(m, cf * ((a - sd * 1.4 - v3(0, 0.4, 0)) * s), cf * ((a + sd * 1.4 - v3(0, 0.4, 0)) * s), 0.6 * s, 0.25 * s,
				C.darkWood, M.Wood)
		end
	end
	local at, _, S = space(cf, s)
	block(m, S(14, 0.8, 4), at(0, 0.4, -B - 3.4), C.cream, M.WoodPlanks, true)
	for _, x in { -6, 6 } do
		cyl(m, 0.5 * s, 4.6 * s, at(x, 2.3, -B - 4.6), C.white, nil, true)
	end
	for i = 0, 3 do
		block(m, S(3.6, 0.3, 4.6), at(-5.4 + i * 3.6, 4.8, -B - 3.6) * CFrame.Angles(math.rad(-8), 0, 0),
			if i % 2 == 0 then pal[1] else C.white)
	end
	for k = 0, 3 do
		local offset = (3 - k) * 4.6 * s / 7
		local F = frameAt(offset, 1)
		local fat, _, FS = space(F, s)
		local car = Instance.new("Model")
		car.Name = if k == 0 then "Engine" else "Wagon"
		local body
		if k == 0 then
			body = block(car, FS(2.2, 1.2, 4), fat(0, 0.9, 0), pal[1])
			mk("Part", car, FS(2.6, 1.8, 1.8), fat(0, 2.2, -0.5) * ALONG_Z, C.iron, M.Metal, false, CYL)
			block(car, FS(2.2, 2.4, 1.6), fat(0, 2.5, 1.2), pal[2])
			block(car, FS(2.6, 0.3, 2), fat(0, 3.8, 1.2), C.iron)
			cyl(car, 0.8 * s, 1.4 * s, fat(0, 3.6, -1.4), C.iron)
		else
			body = block(car, FS(2.2, 1.2, 3.2), fat(0, 0.9, 0), BRIGHT[(k * 2) % #BRIGHT + 1])
			block(car, FS(2.4, 0.6, 3.4), fat(0, 1.7, 0), C.white)
		end
		for _, x in { -1.1, 1.1 } do
			for _, z in { -1, 1 } do
				mk("Part", car, FS(0.3, 0.9, 0.9), fat(x, 0.45, z), C.ink, nil, false, CYL)
			end
		end
		car.Parent = m
		rig(car, body)
		motion(body, "ride", { Path = "train", Pivot = cf, Scale = s, Offset = offset })
	end
end

function Small.grove(m, cf, pal, s, rng)
	for i = 0, 5 do
		local a = i / 6 * TAU + rng:NextNumber(-0.3, 0.3)
		local r = if i == 0 then 0 else rng:NextNumber(9, 14)
		Dress.tree(m, cf * CFrame.new(math.cos(a) * r * s, 0, math.sin(a) * r * s), pal, rng)
	end
	Dress.bench(m, cf * CFrame.new(0, 0, -14 * s), pal)
end

-- ============================================================== themes, palettes, zones

local function hexColor(h)
	if typeof(h) == "Color3" then
		return h
	end
	local ok, c = pcall(Color3.fromHex, tostring(h))
	return if ok then c else nil
end

local function kindOf(theme, i: number): string
	local t = string.lower(tostring(theme or ""))
	if THEME_KIND[t] then
		return THEME_KIND[t]
	end
	for _, pair in KEYWORDS do
		for _, w in pair[2] do
			if string.find(t, w, 1, true) then
				return pair[1]
			end
		end
	end
	return FALLBACK_KINDS[(i - 1) % #FALLBACK_KINDS + 1]
end

local function paletteOf(raw, kind: string)
	local out = {}
	if type(raw) == "table" then
		for _, h in raw do
			local c = hexColor(h)
			if c then
				table.insert(out, c)
			end
		end
	end
	for _, h in KINDS[kind].palette do
		if #out >= 3 then
			break
		end
		table.insert(out, Color3.fromHex(h))
	end
	return out
end

local function normalizeZones(raw)
	local list = if type(raw) == "table" and #raw > 0 then raw else {}
	if #list == 0 then
		for _, t in WorldKit.Themes do
			table.insert(list, { theme = t })
		end
	end
	local zones = {}
	for i, z in list do
		z = if type(z) == "table" then z else { theme = z }
		local kind = kindOf(z.theme or z.name, i)
		local name = if type(z.name) == "string" and z.name ~= "" then z.name else KINDS[kind].name
		local length = tonumber(z.length)
		table.insert(zones, { index = i, name = name, theme = tostring(z.theme or kind), kind = kind,
			pal = paletteOf(z.palette, kind), length = if length and length > 0 then length else nil })
	end
	return zones
end

-- ============================================================== public: one landmark, one piece of dressing

local function newModel(name: string, parent: Instance?): Model
	local m = Instance.new("Model")
	m.Name = name
	if parent then
		m.Parent = parent
	end
	return m
end

local function landmarkInto(parent: Instance?, theme, cf: CFrame, palette, s: number?, seed: number?, gated: boolean?): Model
	local kind = kindOf(theme, 1)
	local m = newModel(KINDS[kind].name:gsub("%s", ""), nil)
	m:SetAttribute("Landmark", kind)
	pcall(function()
		m.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	end)
	frontSigns = not gated
	local ok, err = pcall(LM[kind], m, cf, paletteOf(palette, kind), s or 1, Random.new(seed or 3))
	frontSigns = true
	if not ok then
		error(err, 0)
	end
	CollectionService:AddTag(m, "Landmark")
	m.Parent = parent or workspace
	return m
end

-- WorldKit.landmark(theme, cframe, palette) -> Model. cframe = the ground centre, LookVector = the ride's front.
function WorldKit.landmark(theme, cframe: CFrame?, palette): Model
	return landmarkInto(workspace, theme, cframe or CFrame.new(), palette)
end

local DRESS_KINDS = { "stall", "balloon_cluster", "string_lights", "bench", "tree", "lamp", "sign", "fence",
	"popcorn_cart", "flower_bed", "cypress", "flower_garden", "picnic", "mini_golf", "queue_fence", "kiddie_ride",
	"balloon_arch" }
WorldKit.DressingKinds = DRESS_KINDS

-- WorldKit.dressing(kind, cframe, palette, text?, seed?) -> Model. cframe = the ground point, LookVector = its front.
-- What varies (a stall's goods, a tree's size and greens, the balloons) comes from `seed`, by default from where
-- the piece stands, so pieces scattered by other code are not clones of each other.
function WorldKit.dressing(kind: string, cframe: CFrame?, palette, text: string?, seed: number?): Model
	local fn = Dress[kind]
	assert(fn, "WorldKit.dressing: unknown kind " .. tostring(kind) .. " (" .. table.concat(DRESS_KINDS, ", ") .. ")")
	local cf = cframe or CFrame.new()
	local m = newModel(kind, nil)
	fn(m, cf, paletteOf(palette, "circus"), Random.new(math.floor(tonumber(seed) or (cf.X * 31 + cf.Z * 17 + cf.Y * 7))), text)
	CollectionService:AddTag(m, "Dressing")
	m.Parent = workspace
	return m
end

-- ============================================================== the park: sky and terrain

local function ensure(parent: Instance, class: string): Instance
	local e = parent:FindFirstChildOfClass(class)
	if not e then
		e = Instance.new(class)
		e.Parent = parent
	end
	return e
end

local function applySky()
	Lighting.ClockTime = 15.4
	Lighting.GeographicLatitude = 32
	Lighting.Brightness = 2.6
	Lighting.Ambient = rgb(118, 104, 112)
	Lighting.OutdoorAmbient = rgb(168, 150, 142)
	Lighting.ColorShift_Top = rgb(255, 232, 200)
	Lighting.EnvironmentDiffuseScale = 0.55
	Lighting.EnvironmentSpecularScale = 0.45
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = 0.25
	pcall(function()
		Lighting.ExposureCompensation = 0.1
	end)
	local sky = ensure(Lighting, "Sky") :: Sky
	sky.SunAngularSize, sky.MoonAngularSize, sky.StarCount, sky.CelestialBodiesShown = 14, 9, 800, true
	local atm = ensure(Lighting, "Atmosphere") :: Atmosphere
	atm.Density, atm.Offset, atm.Glare, atm.Haze = 0.24, 0.22, 0.25, 0.7
	atm.Color, atm.Decay = rgb(255, 242, 226), rgb(120, 150, 196)
	local bloom = ensure(Lighting, "BloomEffect") :: BloomEffect
	bloom.Intensity, bloom.Size, bloom.Threshold = 0.5, 28, 1.25
	local rays = ensure(Lighting, "SunRaysEffect") :: SunRaysEffect
	rays.Intensity, rays.Spread = 0.06, 0.7
	local cc = ensure(Lighting, "ColorCorrectionEffect") :: ColorCorrectionEffect
	cc.Saturation, cc.Contrast, cc.Brightness, cc.TintColor = 0.18, 0.07, 0.02, rgb(255, 249, 240)
	local clouds = ensure(workspace.Terrain, "Clouds") :: Clouds
	clouds.Cover, clouds.Density, clouds.Color = 0.55, 0.62, rgb(255, 247, 238)
end

local function terrainLook()
	local T = workspace.Terrain
	T:SetMaterialColor(M.Grass, rgb(104, 186, 74))
	T:SetMaterialColor(M.LeafyGrass, rgb(84, 158, 62))
	T:SetMaterialColor(M.Sand, rgb(236, 212, 160))
	T:SetMaterialColor(M.Rock, rgb(132, 124, 112))
	T:SetMaterialColor(M.Ground, rgb(130, 104, 80))
	T.WaterColor = rgb(56, 170, 214)
	T.WaterTransparency = 0.35
	T.WaterReflectance = 0.6
	T.WaterWaveSize = 0.12
	T.WaterWaveSpeed = 8
end

-- Voxels are 4 studs on a grid at multiples of 4, and full voxels up to height `top` render (and collide) with
-- their surface at top + 2. A raycast right after the fill misses on a live server, so the park is placed on
-- that surface by rule: this is the origin moved onto it.
local function groundFrame(O: CFrame): CFrame
	local top = 4 * math.floor(O.Position.Y / 4 + 0.5)
	return O + v3(0, top + 2 - O.Position.Y, 0)
end

-- Flat grass parts 11 studs under the surface, below every pond and lake, as far as the ground reaches. A joining
-- client gets the Terrain chunk by chunk, which takes minutes for a park this size; until a chunk arrives these show
-- (and catch) a player instead of a void, and once it does they are buried in it.
local function groundUnderlay(O: CFrame, half: number, parent: Instance)
	local n = math.ceil(half * 2 / 2000)
	local w = half * 2 / n
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local cf = CFrame.new(O.Position.X - half + (i + 0.5) * w, O.Position.Y - 12, O.Position.Z - half + (j + 0.5) * w)
			mk("Part", parent, v3(w, 2, w), cf, rgb(98, 178, 70), M.Grass, true).Name = "GroundUnderlay"
		end
	end
end

-- grass from the hub out to `half` studs every way, in tiles of at most 2000 studs a side
local function fillGround(O: CFrame, half: number)
	local T = workspace.Terrain
	local top = O.Position.Y - 2
	local n = math.ceil(half * 2 / 2000)
	local w = half * 2 / n
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			local x, z = O.Position.X - half + (i + 0.5) * w, O.Position.Z - half + (j + 0.5) * w
			T:FillBlock(CFrame.new(x, top - 6, z), v3(w, 12, w), M.Grass)
		end
	end
end

-- ============================================================== the courses the park is built around

local COURSE_CLEAR = 40 -- nothing taller than 6 studs within this many studs of a course
local COURSE_BACK = 24 -- ... from this far behind its start
local COURSE_AHEAD = 40 -- ... to this far past its end, where the ride gate stands
local CORRIDOR = 118 -- the park reaches this far to either side of every course, and its fence stands there
local DEFAULT_COURSE = 460 -- a zone's course when nothing says how long it is (forge/obby.py's zone plot)

local function kitSibling(name: string): ModuleScript?
	local here = if typeof(script) == "Instance" then script.Parent else nil
	for _, folder in { here, ReplicatedStorage:FindFirstChild("Kit") } do
		local m = folder and folder:FindFirstChild(name)
		if m and m:IsA("ModuleScript") then
			return m
		end
	end
	return nil
end

-- ObbyKit's own stage layout (LevelBuilder.layout), and whether this ObbyKit turns stages (version 2 on)
local function obbyLayout()
	local mod = kitSibling("ObbyKit")
	if not mod then
		return nil, false
	end
	local ok, kit = pcall(require, mod)
	if ok and type(kit) == "table" and type(kit.LevelBuilder) == "table" and type(kit.LevelBuilder.layout) == "function" then
		return kit.LevelBuilder.layout, (tonumber(kit.VERSION) or 1) >= 2
	end
	return nil, false
end

-- {[zone number] = zone data} from ReplicatedStorage.Levels: the data ObbyKit builds its courses from
local function levelData()
	local out = {}
	local folder = ReplicatedStorage:FindFirstChild("Levels")
	for _, mod in (if folder then folder:GetChildren() else {}) do
		if mod:IsA("ModuleScript") then
			local ok, z = pcall(require, mod)
			if ok and type(z) == "table" and type(z.stages) == "table" then
				local n = tonumber(z.zone) or tonumber(string.match(mod.Name, "%d+") or "")
				if n then
					out[n] = z
				end
			end
		end
	end
	return out
end

-- One zone's course in its own frame (x right of the start line, y up, z forward from the start pad's centre):
-- the start, then every stage's checkpoint, each stage turned by its `turn` (degrees, right +) on its start pad
-- the way ObbyKit lays them out.
local function measureCourse(zd, layout, turns: boolean)
	local pts = { Vector3.zero }
	local x, y, z, h = 0, 0, 0, 0
	for _, st in zd.stages do
		if type(st) ~= "table" then
			continue
		end
		if turns then
			h += math.rad(tonumber(st.turn) or 0)
		end
		-- the next stage starts on this one's checkpoint (a stage without one leaves the cursor where it was)
		local ok, surfaces = pcall(layout, st)
		local e
		for _, s in (if ok and type(surfaces) == "table" then surfaces else {}) do
			if type(s) == "table" and s.kind == "checkpoint" then
				e = s
			end
		end
		if e and tonumber(e.z) then
			local c, sn = math.cos(h), math.sin(h)
			local ex = tonumber(e.x) or 0
			x, y, z = x + ex * c + e.z * sn, y + (tonumber(e.top) or 0), z - ex * sn + e.z * c
			table.insert(pts, v3(x, y, z))
		end
	end
	return pts
end

-- every zone's course: measured from its level data when the game has them, else a straight zones[i].length
local function measureCourses(zones)
	local layout, turns = obbyLayout()
	local levels = if layout then levelData() else {}
	for i, z in zones do
		local zd = levels[i]
		local pts = if zd then measureCourse(zd, layout, turns) else nil
		z.measured = pts ~= nil and #pts > 1
		if not z.measured then
			pts = { Vector3.zero, v3(0, 0, z.length or DEFAULT_COURSE) }
		end
		z.course = simplify(pts, 3)
	end
end

-- ============================================================== the park: plan (pure geometry)

local function polar(r: number, phi: number): (number, number)
	return -r * math.sin(phi), r * math.cos(phi)
end

local function flatten(cf: CFrame): CFrame
	local look = v3(cf.LookVector.X, 0, cf.LookVector.Z)
	if look.Magnitude < 1e-3 then
		look = v3(0, 0, -1)
	end
	return CFrame.lookAt(cf.Position, cf.Position + look.Unit)
end

local CELL = 48 -- the grid that keeps `free` quick

local Plan = {}
Plan.__index = Plan

function Plan.new(O: CFrame, R: number, zones)
	local self = setmetatable({ O = O, R = R, zones = zones, grid = {}, stamp = 0, spaced = {} }, Plan)
	self.rF, self.rC, self.rHub = 0.92 * R, 0.64 * R, math.max(70, 0.11 * R)
	self.lobbyZ0 = 0.68 * R
	-- zones 2..n sit between 44 degrees and the last angle whose course line leaves the park before it reaches the
	-- lobby (200 studs wide) plus the 40-stud clear band
	self.span = 360 - math.deg(math.asin(math.min(1, 150 / self.rF))) - math.deg(math.acos(self.rC / self.rF)) - 44
	local n = #zones
	self.s = math.clamp(R / 800, 0.5, 1)
	if n > 2 then
		self.s = math.min(self.s, math.clamp(math.rad(self.span / (n - 2)) * 0.6 * R / 230, 0.5, 1))
	end
	-- the forecourt outside the gate, where players arrive
	self.court = { x = 74, z0 = self.rF - 4, z1 = self.rF + 96 }
	for i, z in zones do
		self:placeZone(i, z, n)
	end
	self:layCourses()
	return self
end

function Plan:L(x: number, y: number, z: number): CFrame
	return self.O * CFrame.new(x, y, z)
end

function Plan:look(x: number, y: number, z: number, dx: number, dz: number): CFrame
	return self.O * CFrame.lookAt(v3(x, y, z), v3(x + dx, y, z + dz))
end

function Plan:placeZone(i: number, z, n: number)
	local k, s = KINDS[z.kind], self.s
	local hx, front, back = k.hx * s, k.front * s, k.back * s
	-- every ride fits inside r = rC - 44, so it stays 44 studs to the side of every course that starts on the ring
	-- and runs out along its tangent
	local lim = self.rC - 44
	z.rL = math.max(math.sqrt(math.max(lim * lim - hx * hx, 1)) - back, self.rHub + front + 70)
	z.front = front
	if i == 1 then
		z.phi = math.rad(8)
		z.phiL = math.max(math.rad(16), math.asin(math.clamp((hx + 24) / z.rL, 0, 1)))
		z.height = KINDS.circus.height
	else
		z.phi = if n == 2 then math.rad(150) else math.rad(44 + (i - 2) * self.span / (n - 2))
		-- the ride sits a little further clockwise than its course start: about 50 degrees ahead-right of a
		-- player standing on the start pad, so the first view along the course has the ride in it
		z.phiL = z.phi
		for d = 0.5, 20, 0.5 do
			local a = math.rad(d)
			z.phiL = z.phi + a
			if (self.rC - z.rL * math.cos(a)) / (z.rL * math.sin(a)) <= 1.2 then
				break
			end
		end
		z.height = k.height
	end
	local lx, lz = polar(z.rL, z.phiL)
	local ix, iz = math.sin(z.phiL), -math.cos(z.phiL)
	z.lx, z.lz = lx, lz
	z.landmarkCF = self:look(lx, 0, lz, ix, iz)
	local ax, az = polar(self.rC, z.phi)
	local tx, tz = -math.cos(z.phi), -math.sin(z.phi)
	z.ax, z.az, z.tx, z.tz = ax, az, tx, tz
	z.anchor = self:look(ax, z.height, az, tx, tz)
	-- the gate: on the paving in front of the ride, facing it
	local rg = z.rL - front - 14
	z.gx, z.gz = polar(rg, z.phiL)
	z.archCF = self:look(z.gx - ix * 7, 0, z.gz - iz * 7, -ix, -iz)
	z.gate = self:look(z.gx, 0.4, z.gz, -ix, -iz)
	local rx, rz = math.cos(z.phiL), math.sin(z.phiL)
	self:keepRect(lx, lz, rx, rz, hx + 4, front + 2, back + 4)
	if i ~= 1 then
		self:keepCircle(ax, az, 9)
	end
end

-- Every course in park coordinates (z.path: {x, z, y = height over the ground}) and its clearance stretch
-- (z.ext: COURSE_BACK behind the start to COURSE_AHEAD past the end), as segments for distance queries.
function Plan:layCourses()
	self.courses = {}
	self.reach = self.rF
	for _, z in self.zones do
		local tx, tz, rx, rz = z.tx, z.tz, -z.tz, z.tx
		local path = {}
		for _, p in z.course do
			table.insert(path, { x = z.ax + rx * p.X + tx * p.Z, z = z.az + rz * p.X + tz * p.Z, y = z.height + p.Y })
		end
		z.path = path
		local function dirAt(a, b, fx, fz)
			local dx, dz = b.x - a.x, b.z - a.z
			local len = math.sqrt(dx * dx + dz * dz)
			if len < 1e-3 then
				return fx, fz
			end
			return dx / len, dz / len
		end
		local d0x, d0z = dirAt(path[1], path[2], tx, tz)
		local d1x, d1z = dirAt(path[#path - 1], path[#path], d0x, d0z)
		z.endDir = { d1x, d1z }
		local ext = { { x = path[1].x - d0x * COURSE_BACK, z = path[1].z - d0z * COURSE_BACK } }
		for _, p in path do
			table.insert(ext, p)
		end
		local last = path[#path]
		table.insert(ext, { x = last.x + d1x * COURSE_AHEAD, z = last.z + d1z * COURSE_AHEAD })
		z.ext = ext
		local segs, box = {}, { math.huge, math.huge, -math.huge, -math.huge }
		for k = 1, #ext do
			local p = ext[k]
			box[1], box[2] = math.min(box[1], p.x), math.min(box[2], p.z)
			box[3], box[4] = math.max(box[3], p.x), math.max(box[4], p.z)
			self.reach = math.max(self.reach, math.sqrt(p.x * p.x + p.z * p.z) + CORRIDOR)
			local q = ext[k + 1]
			if q and (q.x - p.x) ^ 2 + (q.z - p.z) ^ 2 > 1e-4 then
				table.insert(segs, { p.x, p.z, q.x, q.z })
			end
		end
		table.insert(self.courses, { segs = segs, box = box })
	end
end

-- distance from (x, z) to the nearest course's clearance stretch; it may stop early once it is under `stop`
function Plan:courseDist(x: number, z: number, stop: number?): number
	local best = math.huge
	local lim = stop or 0
	for _, c in self.courses do
		local b = c.box
		if x > b[1] - best and x < b[3] + best and z > b[2] - best and z < b[4] + best then
			for _, sg in c.segs do
				local d = segDist(x, z, sg[1], sg[2], sg[3], sg[4])
				if d < best then
					best = d
					if best < lim then
						return best
					end
				end
			end
		end
	end
	return best
end

-- is anything taller than 6 studs allowed here? (not within COURSE_CLEAR of any course's clearance stretch). A
-- piece faces a random way and `r` is its round size, so a long piece's corner can reach past r: keep OPEN_MARGIN more.
local OPEN_MARGIN = 3
function Plan:open(x: number, z: number, r: number): boolean
	local need = COURSE_CLEAR + r + OPEN_MARGIN
	return self:courseDist(x, z, need) >= need
end

-- is (x, z) inside the park, `margin` studs grown: the fenced circle or a course's corridor
function Plan:inPark(x: number, z: number, margin: number): boolean
	return x * x + z * z < (self.rF + margin) ^ 2 or self:courseDist(x, z, CORRIDOR + margin) < CORRIDOR + margin
end

function Plan:inCourt(x: number, z: number, margin: number): boolean
	local c = self.court
	return math.abs(x) < c.x + margin and z > c.z0 - margin and z < c.z1 + margin
end

function Plan:addKeep(k, x0: number, z0: number, x1: number, z1: number)
	for cx = math.floor(x0 / CELL), math.floor(x1 / CELL) do
		for cz = math.floor(z0 / CELL), math.floor(z1 / CELL) do
			local key = (cx + 2048) * 4096 + cz + 2048
			local list = self.grid[key]
			if not list then
				list = {}
				self.grid[key] = list
			end
			table.insert(list, k)
		end
	end
end

function Plan:keepCircle(x, z, r)
	self:addKeep({ 1, x, z, r }, x - r, z - r, x + r, z + r)
end
function Plan:keepSeg(ax, az, bx, bz, hw)
	self:addKeep({ 2, ax, az, bx, bz, hw }, math.min(ax, bx) - hw, math.min(az, bz) - hw, math.max(ax, bx) + hw,
		math.max(az, bz) + hw)
end
function Plan:keepRect(x, z, rx, rz, hx, front, back)
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, u in { -hx, hx } do
		for _, w in { -front, back } do
			local px, pz = x + rx * u - rz * w, z + rz * u + rx * w
			x0, z0, x1, z1 = math.min(x0, px), math.min(z0, pz), math.max(x1, px), math.max(z1, pz)
		end
	end
	self:addKeep({ 3, x, z, rx, rz, hx, front, back }, x0, z0, x1, z1)
end

-- is a spot of radius r at (x, z) clear of rides, paths, plazas and everything placed so far?
function Plan:free(x: number, z: number, r: number): boolean
	self.stamp += 1
	local stamp = self.stamp
	for cx = math.floor((x - r) / CELL), math.floor((x + r) / CELL) do
		for cz = math.floor((z - r) / CELL), math.floor((z + r) / CELL) do
			for _, k in self.grid[(cx + 2048) * 4096 + cz + 2048] or {} do
				if k.seen == stamp then
					continue
				end
				k.seen = stamp
				if k[1] == 1 then
					if (x - k[2]) ^ 2 + (z - k[3]) ^ 2 < (k[4] + r) ^ 2 then
						return false
					end
				elseif k[1] == 2 then
					if segDist(x, z, k[2], k[3], k[4], k[5]) < k[6] + r then
						return false
					end
				else
					local dx, dz = x - k[2], z - k[3]
					local lx = dx * k[4] + dz * k[5]
					local lz = dx * -k[5] + dz * k[4]
					if math.abs(lx) < k[6] + r and lz > -k[7] - r and lz < k[8] + r then
						return false
					end
				end
			end
		end
	end
	return true
end

-- spacing between pieces of one kind (lamps along stacked courses): false if one stands within d, else claims it
function Plan:space(kind: string, x: number, z: number, d: number): boolean
	local pts = self.spaced[kind]
	if not pts then
		pts = {}
		self.spaced[kind] = pts
	end
	local cx, cz = math.floor(x / d), math.floor(z / d)
	for i = cx - 1, cx + 1 do
		for j = cz - 1, cz + 1 do
			for _, p in pts[i * 8192 + j] or {} do
				if (p[1] - x) ^ 2 + (p[2] - z) ^ 2 < d * d then
					return false
				end
			end
		end
	end
	local key = cx * 8192 + cz
	pts[key] = pts[key] or {}
	table.insert(pts[key], { x, z })
	return true
end

-- ============================================================== the park: paths

local function strip(plan, parent, ax, az, bx, bz, w: number, top: number, color: Color3, mat, border: Color3?)
	local dx, dz = bx - ax, bz - az
	local len = math.sqrt(dx * dx + dz * dz)
	if len < 0.5 then
		return
	end
	local cf = plan:look((ax + bx) / 2, top - 0.5, (az + bz) / 2, dx, dz)
	block(parent, v3(w, 1, len), cf, color, mat or M.Limestone, true)
	if border then
		for _, sx in { -1, 1 } do
			block(parent, v3(1.6, 1, len), cf * CFrame.new(sx * (w / 2 + 0.8), -0.08, 0), border, M.Brick, true)
		end
	end
	plan:keepSeg(ax, az, bx, bz, w / 2 + (if border then 1.6 else 0))
end

local function disc(plan, parent, x, z, d: number, top: number, color: Color3, mat)
	return cyl(parent, d, 1, plan:L(x, top - 0.5, z), color, mat or M.Limestone, true)
end

local function buildPaths(plan, F)
	local hub = plan.rHub
	disc(plan, F.paths, 0, 0, hub * 2, 0.5, C.brick, M.Brick)
	disc(plan, F.paths, 0, 0, hub * 2 - 8, 0.6, C.paving)
	disc(plan, F.paths, 0, 0, hub * 2 - 40, 0.7, rgb(240, 216, 176))
	plan:keepCircle(0, 0, hub + 2)
	strip(plan, F.paths, 0, hub - 6, 0, plan.lobbyZ0 + 4, 28, 0.26, C.paving, nil, C.brick)
	-- the ring through every ride's gate, crossing the avenue at the front
	local pts = {}
	for _, z in plan.zones do
		table.insert(pts, { phi = z.phiL, x = z.gx, z = z.gz })
	end
	table.sort(pts, function(a, b)
		return a.phi < b.phi
	end)
	local r0 = (math.sqrt(pts[1].x ^ 2 + pts[1].z ^ 2) + math.sqrt(pts[#pts].x ^ 2 + pts[#pts].z ^ 2)) / 2
	table.insert(pts, 1, { phi = 0, x = 0, z = r0 })
	for i, p in pts do
		local q = pts[i % #pts + 1]
		strip(plan, F.paths, p.x, p.z, q.x, q.z, 16, 0.32, C.paving, nil, C.brick)
		disc(plan, F.paths, p.x, p.z, 24, 0.44, C.paving)
		if i > 1 then
			local hx, hz = polar(hub - 6, p.phi)
			strip(plan, F.paths, hx, hz, p.x, p.z, 18, 0.2, C.paving, nil, C.brick)
		end
	end
	plan.ring = pts
	-- queue plazas from each gate to its ride
	for _, z in plan.zones do
		local ix, iz = math.sin(z.phiL), -math.cos(z.phiL)
		local fx, fz = z.lx + ix * (z.front - 4), z.lz + iz * (z.front - 4)
		strip(plan, F.paths, z.gx + ix * 4, z.gz + iz * 4, fx, fz, 26, 0.38, rgb(234, 208, 168))
	end
	-- the promenade just inside the fence
	local rp, n = plan.rF - 24, 48
	for i = 0, n - 1 do
		local ax, az = polar(rp, i / n * TAU)
		local bx, bz = polar(rp, (i + 1) / n * TAU)
		strip(plan, F.paths, ax, az, bx, bz, 12, 0.24, C.paving)
		disc(plan, F.paths, ax, az, 13, 0.3, C.paving)
	end
end

-- the parts of the segment a-b that lie outside the circle of radius r round the hub, as {t0, t1} spans of t in [0, 1]
local function outsideCircle(ax, az, bx, bz, r: number)
	local dx, dz = bx - ax, bz - az
	local A = dx * dx + dz * dz
	if A < 1e-6 then
		return {}
	end
	local B = 2 * (ax * dx + az * dz)
	local K = ax * ax + az * az - r * r
	local disc = B * B - 4 * A * K
	if disc <= 0 then
		return if K >= 0 then { { 0, 1 } } else {}
	end
	local sq = math.sqrt(disc)
	local t1, t2 = (-B - sq) / (2 * A), (-B + sq) / (2 * A)
	local out = {}
	if t1 > 0 then
		table.insert(out, { 0, math.min(1, t1) })
	end
	if t2 < 1 then
		table.insert(out, { math.max(0, t2), 1 })
	end
	return out
end

-- a midway under every course where it runs beyond the fenced circle: paving 18 studs wide with brick edges from
-- the promenade inside the fence to a little plaza under the course's end
local function courseAvenues(plan, F)
	for _, z in plan.zones do
		local pts = z.path
		local last = pts[#pts]
		local ex, ez = last.x + z.endDir[1] * 18, last.z + z.endDir[2] * 18
		for k = 1, #pts - 1 do
			local a, b = pts[k], if k == #pts - 1 then { x = ex, z = ez } else pts[k + 1]
			for _, span in outsideCircle(a.x, a.z, b.x, b.z, plan.rF - 24) do
				if span[2] - span[1] > 1e-3 then
					local ax, az = a.x + (b.x - a.x) * span[1], a.z + (b.z - a.z) * span[1]
					local bx, bz = a.x + (b.x - a.x) * span[2], a.z + (b.z - a.z) * span[2]
					local n = math.ceil(math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2) / 900)
					for j = 0, n - 1 do
						strip(plan, F.paths, ax + (bx - ax) * j / n, az + (bz - az) * j / n, ax + (bx - ax) * (j + 1) / n,
							az + (bz - az) * (j + 1) / n, 18, 0.3, C.paving, nil, C.brick)
					end
				end
			end
		end
		if ex * ex + ez * ez > (plan.rF - 10) ^ 2 then
			disc(plan, F.paths, ex, ez, 38, 0.34, C.brick, M.Brick)
			disc(plan, F.paths, ex, ez, 34, 0.4, C.paving)
			plan:keepCircle(ex, ez, 19)
		end
	end
end

-- ============================================================== the park: lobby and entrance

local function startStairs(plan, F, z)
	local A = z.anchor
	local h = z.height
	local pal = z.pal
	local landing = A * CFrame.new(0, -0.6, 12)
	block(F.lobby, v3(14, 1.2, 14), landing, C.cream, M.WoodPlanks, true)
	for _, dx in { -6, 6 } do
		for _, dz in { -6, 6 } do
			local top = (landing * CFrame.new(dx, -0.6, dz)).Position
			rod(F.lobby, top - v3(0, h - 1.2, 0), top, 1.6, pal[1], nil, true)
		end
	end
	local steps = math.ceil(h / 1.05)
	local rise, run = h / steps, 1.6
	local L = steps * run
	for k = 1, steps - 1 do
		block(F.lobby, v3(run + 0.1, rise + 0.4, 10), A * CFrame.new(-7 - (k - 0.5) * run, -k * rise - (rise + 0.4) / 2, 12),
			if k % 2 == 0 then C.cream else pal[2], M.WoodPlanks, true)
	end
	wedge(F.lobby, v3(10, h - rise, L), A * CFrame.new(-7 - L / 2, -(h + rise) / 2, 12) * CFrame.Angles(0, math.pi / 2, 0),
		pal[1], nil, true)
	for _, dz in { -5.4, 5.4 } do
		bar(F.lobby, (A * CFrame.new(-7, 3, 12 + dz)).Position, (A * CFrame.new(-7 - L, 3 - h, 12 + dz)).Position, 0.4, 0.4,
			C.gold, nil, true)
	end
	-- the START arch over the top step, facing the players coming up (posts clear of the 12-stud board)
	for _, dz in { -7.2, 7.2 } do
		cyl(F.lobby, 1, 11, A * CFrame.new(-7.6, 5.5, 12 + dz), C.gold, nil, true)
		ball(F.lobby, 1.8, (A * CFrame.new(-7.6, 11.4, 12 + dz)).Position, pal[2])
	end
	local sign = signBoard(F.lobby, A * CFrame.new(-7.6, 10.4, 12) * CFrame.Angles(0, math.pi / 2, 0), 12, 3.2, "START",
		C.white, pal[1], C.gold, true)
	sign.CanCollide = false
	local foot = A * CFrame.new(-7 - L - 6, -h + 0.7, 12)
	plan.startFoot = foot
	z.gate = CFrame.lookAt(foot.Position, foot.Position + A.RightVector)
	local fx = plan.O:PointToObjectSpace(foot.Position)
	local tx = plan.O:PointToObjectSpace((A * CFrame.new(0, 0, 12)).Position)
	plan:keepSeg(fx.X, fx.Z, tx.X, tx.Z, 9)
end

local function entranceGate(plan, F, title: string)
	local zf = plan.rF
	local pal = { C.red, C.gold, rgb(58, 134, 255) }
	for _, sx in { -1, 1 } do
		local x = sx * 46
		block(F.lobby, v3(12, 28, 12), plan:L(x, 14, zf), C.red, nil, true)
		for _, y in { 8, 18 } do
			block(F.lobby, v3(12.6, 1.8, 12.6), plan:L(x, y, zf), C.cream)
		end
		block(F.lobby, v3(14, 1.4, 14), plan:L(x, 28.7, zf), C.gold, nil, true)
		local apex = cone(F.lobby, plan:L(x, 29.4, zf), 8.6, 15, 8, { C.red, C.cream }, M.SmoothPlastic)
		ball(F.lobby, 2.2, apex + v3(0, 0.8, 0), C.gold)
		rod(F.lobby, apex, apex + v3(0, 9, 0), 0.4, C.white)
		pennant(F.lobby, apex + v3(0, 9, 0), plan.O.RightVector * sx, 5, C.gold)
	end
	local prev
	for i = 0, 10 do
		local a = math.pi * i / 10
		local p = (plan:L(-math.cos(a) * 40, 22 + math.sin(a) * 14, zf)).Position
		if prev then
			bar(F.lobby, prev, p, 3, 2.6, C.gold, nil, true)
		end
		ball(F.lobby, 1.2, p + v3(0, 1.8, 0), BULBS[i % #BULBS + 1], M.Neon)
		prev = p
	end
	signBoard(F.lobby, plan:L(0, 28.5, zf), 52, 7.5, title, C.cream, C.red, C.gold, true)
	for _, sx in { -1, 1 } do
		local base = plan:L(sx * 70, 0, zf - 14)
		block(F.lobby, v3(10, 9, 8), base * CFrame.new(0, 4.5, 0), C.cream, M.WoodPlanks, true)
		block(F.lobby, v3(7, 3, 0.3), base * CFrame.new(0, 5, -4), rgb(170, 220, 255), M.Glass)
		local apex = cone(F.lobby, base * CFrame.new(0, 9, 0), 7.6, 6, 8, { pal[sx > 0 and 3 or 1], C.cream }, M.SmoothPlastic)
		ball(F.lobby, 1.2, apex + v3(0, 0.4, 0), C.gold)
		signBoard(F.lobby, base * CFrame.new(0, 7.8, -4.4) * CFrame.Angles(0, math.pi, 0), 7, 1.6, "TICKETS", C.white, C.red, C.gold)
		plan:keepCircle(sx * 70, zf - 14, 9)
	end
end

-- the lobby's centrepiece: a three-tier fountain on a rosette of red and gold paving
local function fountain(plan, F, x: number, z: number)
	local base = plan:L(x, 0, z)
	disc(plan, F.lobby, x, z, 80, 0.64, C.brick, M.Brick)
	disc(plan, F.lobby, x, z, 76, 0.68, C.cream)
	for i = 0, 15 do
		local a, b = i / 16 * TAU, (i + 1) / 16 * TAU
		tri(F.lobby, base * v3(math.cos(a) * 35, 0.72, math.sin(a) * 35), base * v3(math.cos(b) * 35, 0.72, math.sin(b) * 35),
			base * v3(0, 0.72, 0), if i % 2 == 0 then rgb(255, 196, 61) else rgb(232, 72, 84), M.SmoothPlastic, 0.1)
	end
	ring(F.lobby, base * CFrame.new(0, 1.6, 0), 20.5, 28, 2.6, 2.2, C.stone, M.Cobblestone, true)
	cyl(F.lobby, 40, 0.4, base * CFrame.new(0, 1.7, 0), rgb(84, 198, 240), M.Glass).Transparency = 0.15
	cyl(F.lobby, 4.4, 6, base * CFrame.new(0, 4, 0), C.cream, M.Marble, true)
	cyl(F.lobby, 19, 1.2, base * CFrame.new(0, 7.4, 0), C.stone, M.Marble, true)
	cyl(F.lobby, 17, 0.3, base * CFrame.new(0, 8.05, 0), rgb(84, 198, 240), M.Glass).Transparency = 0.15
	cyl(F.lobby, 2.6, 4, base * CFrame.new(0, 10, 0), C.cream, M.Marble, true)
	cyl(F.lobby, 9.5, 1, base * CFrame.new(0, 12.4, 0), C.stone, M.Marble, true)
	bulbRing(F.lobby, base * CFrame.new(0, 7.6, 0), 9.8, 14, 0.8, BULBS)
	ball(F.lobby, 3, (base * v3(0, 14.6, 0)), C.gold, M.Metal)
	rod(F.lobby, (base * v3(0, 16, 0)), (base * v3(0, 19.5, 0)), 0.35, C.gold, M.Metal)
	pennant(F.lobby, (base * v3(0, 19.5, 0)), plan.O.RightVector, 3.4, C.red)
	spray(anchorPart(F.lobby, (base * v3(0, 13.4, 0))), 34, 2.2, 15)
	for i = 0, 5 do
		local a = i / 6 * TAU
		local at = base * v3(math.cos(a) * 18.5, 2.2, math.sin(a) * 18.5)
		local up = (base:VectorToWorldSpace(v3(-math.cos(a), 0, -math.sin(a))) * 0.55 + Vector3.yAxis).Unit
		local right = up:Cross(Vector3.zAxis).Unit
		local holder = anchorPart(F.lobby, at)
		holder.CFrame = CFrame.fromMatrix(at, right, up)
		spray(holder, 18, 1.4, 22)
	end
	plan:keepCircle(x, z, 40)
end

-- a park map on two posts: the title and every zone with its number and colour
local function parkMap(plan, F, x: number, z: number, title: string)
	local cf = plan:look(x, 0, z, 0, 1)
	for _, dx in { -10.4, 10.4 } do
		cyl(F.lobby, 1, 13.4, cf * CFrame.new(dx, 6.7, 0), C.iron, M.Metal, true)
		ball(F.lobby, 1.6, (cf * v3(dx, 13.8, 0)), C.gold)
	end
	block(F.lobby, v3(20, 12, 0.5), cf * CFrame.new(0, 7.8, 0.35), C.gold)
	local board = block(F.lobby, v3(19, 11, 0.8), cf * CFrame.new(0, 7.8, 0), C.cream, nil, true)
	local g = Instance.new("SurfaceGui")
	g.Face = FRONT
	g.LightInfluence = 0
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 20
	local head = Instance.new("TextLabel")
	head.BackgroundTransparency = 1
	head.Size = UDim2.fromScale(0.92, 0.17)
	head.Position = UDim2.fromScale(0.04, 0.03)
	head.Font = Enum.Font.LuckiestGuy
	head.TextScaled = true
	head.Text = title .. "  -  PARK MAP"
	head.TextColor3 = C.red
	head.Parent = g
	local n = #plan.zones
	local perCol = math.ceil(n / 2)
	for i, zone in plan.zones do
		local col, row = (i - 1) // perCol, (i - 1) % perCol
		local cell = Instance.new("Frame")
		cell.BackgroundTransparency = 1
		cell.Size = UDim2.fromScale(0.46, 0.76 / perCol)
		cell.Position = UDim2.fromScale(0.04 + col * 0.48, 0.22 + row * 0.76 / perCol)
		cell.Parent = g
		local dot = Instance.new("TextLabel")
		dot.Size = UDim2.fromScale(0.13, 0.86)
		dot.Position = UDim2.fromScale(0, 0.07)
		dot.BackgroundColor3 = zone.pal[1]
		dot.Font = Enum.Font.LuckiestGuy
		dot.TextScaled = true
		dot.Text = tostring(i)
		dot.TextColor3 = C.white
		dot.Parent = cell
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = dot
		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Size = UDim2.fromScale(0.84, 0.8)
		name.Position = UDim2.fromScale(0.16, 0.1)
		name.Font = Enum.Font.FredokaOne
		name.TextScaled = true
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Text = string.upper(zone.name)
		name.TextColor3 = C.ink
		name.Parent = cell
	end
	g.Parent = board
	plan:keepCircle(x, z, 12)
end

-- lots: reserved clear spots a game builds on (changingRoom = true -> lots.changingRoom, the left stall's place
-- in the plaza, facing in)
local function buildLobby(plan, F, title: string, lots: { [string]: any }?)
	local z0, z1 = plan.lobbyZ0, plan.rF - 10
	local zc = (z0 + z1) / 2
	block(F.lobby, v3(200, 1, z1 - z0), plan:L(0, 0, zc), C.brick, M.Brick, true)
	block(F.lobby, v3(184, 1, z1 - z0 - 16), plan:L(0, 0.1, zc), C.paving, M.Limestone, true)
	plan:keepRect(0, zc, 1, 0, 100, (z1 - z0) / 2, (z1 - z0) / 2 + 12)
	plan.lobby = plan:L(0, 0.6, zc)
	fountain(plan, F, 0, plan.rF - 64)
	parkMap(plan, F, -58, plan.rF - 40, title)
	Dress.kiddie_ride(F.dress, plan:look(58, 0.6, plan.rF - 44, 0, 1), { C.red, C.gold, rgb(58, 134, 255) }, Random.new(31))
	entranceGate(plan, F, title)
	-- the balloon arch over the avenue
	for i = 0, 16 do
		local a = math.pi * i / 16
		for _, j in { -1.1, 1.1 } do
			ball(F.lobby, 3.3, (plan:L(-math.cos(a) * 20, 1.5 + math.sin(a) * 20, z0 + 2 + j)).Position,
				BRIGHT[(i + (if j > 0 then 3 else 0)) % #BRIGHT + 1])
		end
	end
	local lamps = {}
	for _, sx in { -1, 1 } do
		for k = 0, 3 do
			local x, z = sx * 92, z0 + 22 + k * ((z1 - z0 - 44) / 3)
			table.insert(lamps, { sx, Dress.lamp(F.lobby, plan:L(x, 0.6, z), { C.red }) })
		end
	end
	for k = 1, 4 do
		local a, b = lamps[k][2], lamps[k + 4][2]
		lights(F.dress, a, a.Position + v3(0, 0.6, 0), b, b.Position + v3(0, 0.6, 0), 4, 22)
	end
	plan.lots = {}
	if lots and lots.changingRoom then
		plan.lots.changingRoom = plan:look(-72, 0.6, zc + 4, 1, 0)
	end
	for _, sx in { -1, 1 } do
		if not (sx < 0 and plan.lots.changingRoom) then
			Dress.stall(F.dress, plan:look(sx * 78, 0.6, zc - 18, -sx, 0), { C.red, C.gold }, Random.new(sx + 4), nil)
		end
		Dress.popcorn_cart(F.dress, plan:look(sx * 30, 0.6, z0 + 26, -sx, 0), { C.red, C.gold })
		Dress.balloon_cluster(F.dress, plan:L(sx * 26, 0.6, z0 + 6), { C.red }, Random.new(sx + 9))
		Dress.balloon_cluster(F.dress, plan:L(sx * 34, 0.6, z1 - 8), { C.gold }, Random.new(sx + 19))
		for k = 0, 1 do
			Dress.bench(F.dress, plan:look(sx * 52, 0.6, zc - 30 + k * 30, -sx, 0), { C.red })
		end
		local top = anchorPart(F.lobby, (plan:L(sx * 46, 28, plan.rF - 6)).Position)
		local booth = anchorPart(F.lobby, (plan:L(sx * 70, 9.5, plan.rF - 14)).Position)
		bunting(F.dress, top, top.Position, booth, booth.Position, 3, 9, BRIGHT)
	end
end

-- outside the gate: the paved forecourt players arrive on, the spawn pad 44 studs out facing the gate, flags,
-- lamps strung to the gate towers, gardens and a balloon seller
local function buildForecourt(plan, F)
	local c, zf = plan.court, plan.rF
	local zs = zf - 10 -- under the gate, where the lobby's paving stops
	local zm = (zs + c.z1) / 2
	block(F.lobby, v3(c.x * 2 + 8, 1, c.z1 - zs), plan:L(0, 0, zm), C.brick, M.Brick, true)
	block(F.lobby, v3(c.x * 2, 1, c.z1 - zs - 8), plan:L(0, 0.1, zm - 4), C.paving, M.Limestone, true)
	plan:keepRect(0, zm, 1, 0, c.x + 4, (c.z1 - zs) / 2, (c.z1 - zs) / 2)
	local base = plan:look(0, 0.6, zf + 44, 0, -1)
	cyl(F.lobby, 25, 0.9, base * CFrame.new(0, -0.05, 0), C.gold, nil, true)
	for i = 0, 11 do
		local a, b = i / 12 * TAU, (i + 1) / 12 * TAU
		tri(F.lobby, base * v3(math.cos(a) * 11, 0.42, math.sin(a) * 11), base * v3(math.cos(b) * 11, 0.42, math.sin(b) * 11),
			base * v3(0, 0.42, 0), if i % 2 == 0 then C.red else C.cream, M.SmoothPlastic, 0.06)
	end
	cyl(F.lobby, 5.4, 0.14, base * CFrame.new(0, 0.46, 0), C.white)
	bulbRing(F.lobby, base * CFrame.new(0, 0.6, 0), 11.9, 22, 0.9, BULBS)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "ParkSpawn"
	spawn.Anchored = true
	spawn.Size = v3(12, 1, 12)
	spawn.CFrame = base * CFrame.new(0, -0.1, 0)
	spawn.Transparency = 1
	spawn.Neutral = true
	spawn.Duration = 0
	spawn.CanTouch = true
	spawn.Parent = F.lobby
	made += 1
	plan.spawn = base * CFrame.new(0, 0.4, 0)
	-- the tall pieces only where no course passes close by (a long last course can run out past the front)
	for _, sx in { -1, 1 } do
		for k, dz in { 14, 58 } do
			local px, pz = sx * (c.x - 8), zf + dz
			if plan:open(px, pz, 9) then
				local pole = plan:L(px, 0.6, pz)
				cyl(F.lobby, 2.2, 1, pole * CFrame.new(0, 0.5, 0), C.stone, nil, true)
				rod(F.lobby, pole.Position, (pole * v3(0, 26, 0)), 0.5, C.white, M.Metal, true)
				ball(F.lobby, 1, (pole * v3(0, 26.4, 0)), C.gold)
				local flag = BRIGHT[(k + (if sx > 0 then 2 else 0)) % #BRIGHT + 1]
				tri(F.lobby, (pole * v3(0, 25.6, 0)), (pole * v3(0, 20.6, 0)), (pole * v3(-sx * 8, 23.1, 0)), flag, M.SmoothPlastic, 0.12)
			end
		end
		local lx = sx * (c.x - 22)
		local lamp = if plan:open(lx, zf + 36, 2) then Dress.lamp(F.lobby, plan:L(lx, 0.6, zf + 36), { C.red }) else nil
		if lamp then
			local tower = anchorPart(F.lobby, (plan:L(sx * 46, 26, zf + 6)).Position)
			lights(F.dress, tower, tower.Position, lamp, lamp.Position + v3(0, 0.6, 0), 3, 12)
			if plan:open(lx, zf + 80, 2) then
				local far = Dress.lamp(F.lobby, plan:L(lx, 0.6, zf + 80), { C.red })
				lights(F.dress, lamp, lamp.Position + v3(0, 0.6, 0), far, far.Position + v3(0, 0.6, 0), 3, 14)
			end
		end
		Dress.flower_garden(F.nature, plan:look(sx * 40, 0.6, zf + 62, 0, -1), nil, Random.new(sx + 61))
		if plan:open(sx * 17, zf + 18, 5) then
			Dress.balloon_cluster(F.dress, plan:L(sx * 17, 0.6, zf + 18), { C.red }, Random.new(sx + 71))
		end
		Dress.bench(F.dress, plan:look(sx * 24, 0.6, zf + 86, 0, -1), { C.red })
	end
	if plan:open(30, zf + 38, 5) then
		Dress.popcorn_cart(F.dress, plan:look(30, 0.6, zf + 38, -1, 0), { C.red, C.gold })
	end
end

-- ============================================================== the park: rides, arches and course towers

-- the zone's arch: the name board (19 studs with its frame) hangs between pillars whose faces stand clear of it
local function rideArch(parent, cf: CFrame, pal, text: string)
	for _, x in { -10.8, 10.8 } do
		cyl(parent, 2.4, 14, cf * CFrame.new(x, 7, 0), pal[1], nil, true)
		cyl(parent, 3.4, 1.2, cf * CFrame.new(x, 0.6, 0), C.cream, nil, true)
		for _, y in { 3.5, 8, 12.5 } do
			cyl(parent, 2.7, 0.8, cf * CFrame.new(x, y, 0), pal[2])
		end
		ball(parent, 2.8, (cf * CFrame.new(x, 15.2, 0)).Position, C.gold)
	end
	local board = signBoard(parent, cf * CFrame.new(0, 13, 0), 18, 3.6, string.upper(text), C.cream, pal[1], pal[2], true)
	board.CanCollide = false
	bar(parent, (cf * CFrame.new(-10.8, 15.2, 0)).Position, (cf * CFrame.new(10.8, 15.2, 0)).Position, 0.7, 0.7, pal[2])
	for i = 0, 10 do
		ball(parent, 0.8, (cf * CFrame.new(-9 + i * 1.8, 15.9, 0)).Position, BULBS[i % #BULBS + 1], M.Neon)
	end
end

local function courseTower(parent, plan, z)
	local base = plan:L(z.ax, 0, z.az)
	local top = z.height - 1.05
	local pal = z.pal
	cyl(parent, 9, 2, base * CFrame.new(0, 1, 0), C.stone, M.Cobblestone, true)
	cyl(parent, 5, top - 2, base * CFrame.new(0, 2 + (top - 2) / 2, 0), pal[1], nil, true)
	for y = 8, top - 6, 8 do
		cyl(parent, 5.8, 1, base * CFrame.new(0, y, 0), C.cream)
	end
	cyl(parent, 12, 1, base * CFrame.new(0, top - 0.5, 0), pal[2], nil, true)
	for i = 0, 3 do
		local a = i / 4 * TAU + math.pi / 4
		rod(parent, (base * v3(math.cos(a) * 4.4, 1.6, math.sin(a) * 4.4)), (base * v3(math.cos(a) * 2, top * 0.3, math.sin(a) * 2)),
			0.8, C.cream)
	end
	bulbRing(parent, base * CFrame.new(0, top - 0.6, 0), 6.1, 10, 0.8, BULBS)
end

local function buildRides(plan, F)
	for i, z in plan.zones do
		local m = landmarkInto(F.rides, z.kind, z.landmarkCF, z.pal, plan.s, i * 17, true)
		m.Name = string.format("Zone%02d_%s", i, m.Name)
		m:SetAttribute("Zone", i)
		rideArch(F.rides, z.archCF, z.pal, z.name)
		if i == 1 then
			startStairs(plan, F, z)
		else
			courseTower(F.rides, plan, z)
		end
		if i % 3 == 0 then
			task.wait()
		end
	end
end

-- ============================================================== the park: dressing along the paths

-- path-side pieces taller than 6 studs go up only where no course passes (plan:open; a stall's awning reaches 11.5
-- studs from its centre)
local function stallAt(plan, F, x, z, dx, dz, pal, rng)
	if not (plan:free(x, z, 8) and plan:open(x, z, 11.5)) then
		return false
	end
	Dress.stall(F.dress, plan:look(x, 0.1, z, dx, dz), pal, rng, nil)
	plan:keepCircle(x, z, 8)
	return true
end

local function lampAt(plan, F, x: number, y: number, z: number): BasePart?
	if not plan:open(x, z, 2) then
		return nil
	end
	return Dress.lamp(F.dress, plan:L(x, y, z), { C.red })
end

local function lightsIf(F, a: BasePart?, b: BasePart?, sag: number, n: number)
	if a and b then
		lights(F.dress, a, a.Position + v3(0, 0.6, 0), b, b.Position + v3(0, 0.6, 0), sag, n)
	end
end

local function cypressAt(plan, F, x: number, z: number, rng)
	if plan:free(x, z, 3) and plan:open(x, z, 3) then
		Dress.cypress(F.nature, plan:L(x, 0, z), nil, rng)
	end
end

local function dressAvenue(plan, F, rng)
	local hub, z0 = plan.rHub, plan.lobbyZ0
	local left, right = {}, {}
	local count = math.max(2, math.floor((z0 - hub - 30) / 38))
	for k = 0, count do
		local z = hub + 18 + k * (z0 - hub - 30) / count
		left[k + 1] = lampAt(plan, F, -18.5, 0, z)
		right[k + 1] = lampAt(plan, F, 18.5, 0, z)
	end
	for k = 1, count do
		lightsIf(F, if k % 2 == 1 then left[k] else right[k], if k % 2 == 1 then right[k + 1] else left[k + 1], 3.2, 14)
	end
	for _, sx in { -1, 1 } do
		for k = 0, 4 do
			local z = hub + 50 + k * (z0 - hub - 90) / 4
			local pal = plan.zones[(k + (if sx > 0 then 2 else 0)) % #plan.zones + 1].pal
			stallAt(plan, F, sx * 31, z, -sx, 0, pal, rng)
		end
		for k = 0, 9 do
			cypressAt(plan, F, sx * 44, hub + 30 + k * (z0 - hub - 50) / 9, rng)
		end
	end
end

local function dressHub(plan, F, rng)
	local hub = plan.rHub
	local m = landmarkInto(F.rides, "droptower", plan:look(0, 0.7, 0, 0, 1), nil, plan.s, 99)
	m.Name = "HubDropTower"
	local basin = plan:L(0, 0, 0)
	ring(F.paths, basin * CFrame.new(0, 2, 0), 29, 28, 2.6, 2.6, C.stone, M.Cobblestone, true)
	local water = cyl(F.paths, 57, 0.4, basin * CFrame.new(0, 1.6, 0), C.water, M.Glass)
	water.Transparency = 0.2
	for i = 0, 7 do
		local a = i / 8 * TAU
		local p = basin * v3(math.cos(a) * 22, 1.8, math.sin(a) * 22)
		local jet = rod(F.paths, p, p + v3(0, 7, 0), 0.7, rgb(200, 240, 255), M.Glass)
		jet.Transparency = 0.35
		ball(F.paths, 1.6, p + v3(0, 7.3, 0), rgb(220, 248, 255), M.Glass).Transparency = 0.3
	end
	-- lamps round the hub with festoons between them, stalls and carts between the paths
	local spokes = {}
	for _, p in plan.ring do
		table.insert(spokes, p.phi)
	end
	local lamps = {}
	for i, phi in spokes do
		local nextPhi = spokes[i % #spokes + 1] + (if i == #spokes then TAU else 0)
		local mid = (phi + nextPhi) / 2
		local x, z = polar(hub - 6, mid)
		table.insert(lamps, Dress.lamp(F.dress, plan:L(x, 0.6, z), { C.red }))
		local sx, sz = polar(hub + 15, mid)
		local ix, iz = math.sin(mid), -math.cos(mid)
		if i % 2 == 0 then
			stallAt(plan, F, sx, sz, ix, iz, plan.zones[i % #plan.zones + 1].pal, rng)
		else
			local cx, cz = polar(hub - 16, mid)
			Dress.popcorn_cart(F.dress, plan:look(cx, 0.7, cz, ix, iz), plan.zones[i % #plan.zones + 1].pal)
		end
		local bx, bz = polar(36, mid)
		Dress.bench(F.dress, plan:look(bx, 0.7, bz, ix, iz), { C.red })
	end
	for i, a in lamps do
		local b = lamps[i % #lamps + 1]
		lights(F.dress, a, a.Position + v3(0, 0.6, 0), b, b.Position + v3(0, 0.6, 0), 3.5, 12)
	end
	for i = 0, 3 do
		local x, z = polar(30, i / 4 * TAU + math.pi / 4)
		Dress.balloon_cluster(F.dress, plan:L(x, 0.7, z), { BRIGHT[i + 1] }, Random.new(i + 40))
	end
end

local function dressSpokes(plan, F, rng)
	for i, p in plan.ring do
		if i == 1 then
			continue
		end
		local hx, hz = polar(plan.rHub + 10, p.phi)
		local dx, dz = p.x - hx, p.z - hz
		local len = math.sqrt(dx * dx + dz * dz)
		local ux, uz = dx / len, dz / len
		local nx, nz = -uz, ux
		local count = math.floor(len / 52)
		for k = 1, count do
			local cx, cz = hx + ux * k * len / (count + 1), hz + uz * k * len / (count + 1)
			local a = lampAt(plan, F, cx + nx * 13, 0, cz + nz * 13)
			local b = lampAt(plan, F, cx - nx * 13, 0, cz - nz * 13)
			lightsIf(F, a, b, 2.4, 7)
			local side = if k % 2 == 0 then 1 else -1
			local bx, bz = cx + ux * 14 + nx * side * 13.5, cz + uz * 14 + nz * side * 13.5
			if plan:free(bx, bz, 1) then
				Dress.bench(F.dress, plan:look(bx, 0, bz, -nx * side, -nz * side), { C.red })
			end
			for _, sd in { -1, 1 } do
				cypressAt(plan, F, cx - ux * 14 + nx * sd * 17, cz - uz * 14 + nz * sd * 17, rng)
			end
		end
	end
end

local function dressRing(plan, F, rng)
	local pts = plan.ring
	for i, p in pts do
		local q = pts[i % #pts + 1]
		local dx, dz = q.x - p.x, q.z - p.z
		local len = math.sqrt(dx * dx + dz * dz)
		local ux, uz = dx / len, dz / len
		local mx, mz = (p.x + q.x) / 2, (p.z + q.z) / 2
		local inx, inz = -mx, -mz
		local il = math.sqrt(inx * inx + inz * inz)
		inx, inz = inx / il, inz / il
		local a = lampAt(plan, F, p.x + dx * 0.3 + inx * 11.5, 0, p.z + dz * 0.3 + inz * 11.5)
		local b = lampAt(plan, F, p.x + dx * 0.7 + inx * 11.5, 0, p.z + dz * 0.7 + inz * 11.5)
		lightsIf(F, a, b, 3.6, 12)
		stallAt(plan, F, mx + inx * 20, mz + inz * 20, -inx, -inz, plan.zones[i % #plan.zones + 1].pal, rng)
		local ox, oz = mx - inx * 16, mz - inz * 16
		if plan:free(ox, oz, 4) then
			Dress.flower_bed(F.nature, plan:look(ox, 0, oz, ux, uz), nil, rng)
			plan:keepCircle(ox, oz, 6)
		end
	end
	for _, z in plan.zones do
		local ix, iz = math.sin(z.phiL), -math.cos(z.phiL)
		local rx, rz = math.cos(z.phiL), math.sin(z.phiL)
		for _, sd in { -1, 1 } do
			local bx, bz = z.gx - ix * 6 + rx * sd * 16, z.gz - iz * 6 + rz * sd * 16
			if plan:open(bx, bz, 5) then
				Dress.balloon_cluster(F.dress, plan:L(bx, 0.4, bz), z.pal, rng)
				plan:keepCircle(bx, bz, 3)
			end
		end
	end
end

-- one small attraction in each lawn between two spokes, halfway between the hub and the ring
local function dressSectors(plan, F, rng)
	local pts = plan.ring
	local kinds = { "swings", "booths", "bandstand", "grove" }
	local RADIUS = { swings = 19, booths = 24, bandstand = 14, grove = 23 }
	for i, p in pts do
		local q = pts[i % #pts + 1]
		local mid = (p.phi + q.phi + (if i == #pts then TAU else 0)) / 2
		local rRing = math.min(math.sqrt(p.x ^ 2 + p.z ^ 2), math.sqrt(q.x ^ 2 + q.z ^ 2))
		local x, z = polar((plan.rHub + rRing) / 2 + 8, mid)
		local kind = kinds[(i - 1) % #kinds + 1]
		local rad = RADIUS[kind]
		if plan:free(x, z, rad) then
			local m = newModel(kind, F.rides)
			Small[kind](m, plan:look(x, 0, z, math.sin(mid), -math.cos(mid)), plan.zones[i % #plan.zones + 1].pal, 1, rng)
			plan:keepCircle(x, z, rad)
		end
	end
end

-- kind -> radius it needs, is it taller than 6 studs (then never near a course), and how to build it
local PLACERS = {
	tree = { 9, true, function(F, cf, pal, rng)
		Dress.tree(F.nature, cf, pal, rng)
	end },
	cypress = { 3.5, true, function(F, cf, pal, rng)
		Dress.cypress(F.nature, cf, pal, rng)
	end },
	flower_bed = { 6, false, function(F, cf, pal, rng)
		Dress.flower_bed(F.nature, cf, pal, rng)
	end },
	flower_garden = { 17, false, function(F, cf, pal, rng)
		Dress.flower_garden(F.nature, cf, pal, rng)
	end },
	pond = { 25, false, function(F, cf, pal, rng)
		Dress.pond(F.nature, cf, pal, rng)
	end },
	picnic = { 6, false, function(F, cf, pal, rng)
		Dress.picnic(F.dress, cf, pal, rng)
	end },
	mini_golf = { 11, false, function(F, cf, pal, rng)
		Dress.mini_golf(F.dress, cf, pal, rng)
	end },
	queue_fence = { 9, false, function(F, cf, pal, rng)
		Dress.queue_fence(F.dress, cf, pal, rng)
	end },
	kiddie_ride = { 9, false, function(F, cf, pal, rng)
		Dress.kiddie_ride(F.dress, cf, pal, rng)
	end },
	balloon_cluster = { 5, true, function(F, cf, pal, rng)
		Dress.balloon_cluster(F.dress, cf, pal, rng)
	end },
	balloon_arch = { 8, true, function(F, cf, pal, rng)
		Dress.balloon_arch(F.dress, cf, pal, rng)
	end },
	bench = { 4, false, function(F, cf, pal)
		Dress.bench(F.dress, cf, pal)
	end },
	popcorn_cart = { 5, true, function(F, cf, pal)
		Dress.popcorn_cart(F.dress, cf, pal)
	end },
	grove = { 23, true, function(F, cf, pal, rng)
		Small.grove(newModel("grove", F.nature), cf, pal, 1, rng)
	end },
	swings = { 20, true, function(F, cf, pal, rng)
		Small.swings(newModel("swings", F.rides), cf, pal, 1, rng)
	end },
	booths = { 25, true, function(F, cf, pal, rng)
		Small.booths(newModel("booths", F.rides), cf, pal, 1, rng)
	end },
	bandstand = { 14, true, function(F, cf, pal, rng)
		Small.bandstand(newModel("bandstand", F.rides), cf, pal, 1, rng)
	end },
	minitrain = { 36, false, function(F, cf, pal, rng)
		Small.minitrain(newModel("minitrain", F.rides), cf, pal, 1, rng)
	end },
}

-- one piece of `kind` at (x, z) facing (fx, fz), if its spot is free (and, for a tall piece, clear of every course)
local function place(plan, F, kind: string, x: number, z: number, fx: number, fz: number, pal, rng): boolean
	local spec = PLACERS[kind]
	if not plan:free(x, z, spec[1]) or (spec[2] and not plan:open(x, z, spec[1])) then
		return false
	end
	spec[3](F, plan:look(x, 0, z, fx, fz), pal, rng)
	plan:keepCircle(x, z, spec[1])
	return true
end

local function pathLength(pts): number
	local len = 0
	for k = 1, #pts - 1 do
		len += math.sqrt((pts[k + 1].x - pts[k].x) ^ 2 + (pts[k + 1].z - pts[k].z) ^ 2)
	end
	return len
end

-- points every `step` studs along a polyline of {x, z} from `from` studs in: {x, z, dx, dz}
local function stations(pts, step: number, from: number)
	local out = {}
	local s0, want = 0, from
	for k = 1, #pts - 1 do
		local a, b = pts[k], pts[k + 1]
		local dx, dz = b.x - a.x, b.z - a.z
		local len = math.sqrt(dx * dx + dz * dz)
		if len > 1e-3 then
			dx, dz = dx / len, dz / len
			while want <= s0 + len do
				local t = want - s0
				table.insert(out, { x = a.x + dx * t, z = a.z + dz * t, dx = dx, dz = dz })
				want += step
			end
			s0 += len
		end
	end
	return out
end

local LOW = { "flower_garden", "picnic", "mini_golf", "flower_garden", "queue_fence", "kiddie_ride", "picnic", "flower_bed" }
local SIDE_RIDES = { "swings", "booths", "balloon_arch", "bandstand", "booths", "grove", "swings", "balloon_arch" }

-- The fair along every course, start to end, so a player on it always has the park beside and under them: lamps
-- strung with lights 46 studs out on both sides every 80 studs, stalls 64 out, a ride, a booth corner or a
-- balloon arch further out, trees behind them, and low gardens, café tables, mini golf, queue mazes and kiddie
-- rides under the course (nothing within 40 studs of it is taller than 6). The longer the courses, the further
-- apart the bigger pieces stand, so the park stays near 40k parts.
local function dressCourses(plan, F, rng)
	local total = 0
	for _, z in plan.zones do
		total += pathLength(z.path)
	end
	local thin = math.clamp(total / 11000, 1, 2.2)
	local lampEvery = if thin > 1.5 then 3 else 2
	local stallEvery = math.round(3 * thin)
	for i, z in plan.zones do
		local pal = z.pal
		local last = {}
		local outside = function(x, zz)
			return x * x + zz * zz > (plan.rF - 20) ^ 2
		end
		for k, p in stations(z.path, 40, 20) do
			local nx, nz = -p.dz, p.dx -- the course's right
			if k % lampEvery == 1 then
				for _, side in { -1, 1 } do
					local lx, lz = p.x + nx * side * 46, p.z + nz * side * 46
					local lamp
					if plan:courseDist(lx, lz, 44) >= 44 and plan:free(lx, lz, 1.5) and plan:space("lamp", lx, lz, 34) then
						lamp = Dress.lamp(F.dress, plan:L(lx, 0, lz), pal)
						plan:keepCircle(lx, lz, 1.5)
					end
					local prev = last[side]
					if lamp and prev and (prev.Position - lamp.Position).Magnitude < 40 * lampEvery + 16 then
						lights(F.dress, prev, prev.Position + v3(0, 0.6, 0), lamp, lamp.Position + v3(0, 0.6, 0), 3.2, 4 + 2 * lampEvery)
					end
					last[side] = lamp
				end
			end
			local side = if k % 2 == 0 then 1 else -1
			-- a stall on each side every stallEvery stations, the two sides staggered
			local ss = if k % stallEvery == 0 then 1 elseif k % stallEvery == stallEvery // 2 then -1 else nil
			if ss then
				local sx, sz = p.x + nx * ss * 64, p.z + nz * ss * 64
				if plan:courseDist(sx, sz, 56) >= 56 and plan:free(sx, sz, 8) and plan:open(sx, sz, 8) then
					Dress.stall(F.dress, plan:look(sx, 0.1, sz, -nx * ss, -nz * ss), pal, rng, nil)
					plan:keepCircle(sx, sz, 8)
				end
			end
			if k % math.round(10 * thin) == 5 then
				local kind = SIDE_RIDES[(k // 10 + i) % #SIDE_RIDES + 1]
				local rad = PLACERS[kind][1]
				local d = math.min(58 + rad, CORRIDOR - 8 - rad)
				place(plan, F, kind, p.x - nx * side * d, p.z - nz * side * d, nx * side, nz * side, pal, rng)
			end
			if k % 2 == 0 then
				local d = rng:NextNumber(96, 104)
				place(plan, F, if rng:NextNumber() < 0.35 then "cypress" else "tree", p.x + nx * side * d, p.z + nz * side * d,
					p.dx, p.dz, pal, rng)
			end
			if k % math.round(2 * thin) == 1 then
				local kind = LOW[(k + i * 3) % #LOW + 1]
				local rad = PLACERS[kind][1]
				local lat = rad + rng:NextNumber(2, 9) + (if outside(p.x, p.z) then 10 else 0)
				local face = rng:NextNumber(0, TAU)
				place(plan, F, kind, p.x - nx * side * lat, p.z - nz * side * lat, math.cos(face), math.sin(face), pal, rng)
			end
		end
	end
	return total
end

-- trees, gardens, ponds and small rides in the free spots of a band of the park (caps: kind -> max count)
local function scatter(plan, F, rng, rMin: number, rMax: number, count: number, kinds, caps)
	local placed, tries, used = 0, 0, {}
	while placed < count and tries < count * 30 do
		tries += 1
		local x, z = polar(math.sqrt(rng:NextNumber(rMin * rMin, rMax * rMax)), rng:NextNumber(0, TAU))
		local kind = kinds[rng:NextInteger(1, #kinds)]
		local spec = PLACERS[kind]
		local rad, tall = spec[1], spec[2]
		if caps and caps[kind] and (used[kind] or 0) >= caps[kind] then
			continue
		end
		if plan:free(x, z, rad) and (not tall or plan:open(x, z, rad)) then
			local face = rng:NextNumber(0, TAU)
			local pal = plan.zones[rng:NextInteger(1, #plan.zones)].pal
			spec[3](F, plan:look(x, 0, z, math.cos(face), math.sin(face)), pal, rng)
			plan:keepCircle(x, z, rad)
			used[kind] = (used[kind] or 0) + 1
			placed += 1
		end
	end
end

-- ============================================================== the park: perimeter and the land beyond

local function wrap(a: number): number
	return math.atan2(math.sin(a), math.cos(a))
end

-- Points about every `step` studs on the outline `off` studs out from a course's clearance stretch (z.ext): up
-- its right side (round the outside of every bend), round its far end, back down its left side and round its
-- start. Points on a bend's inside or inside another course's corridor are dropped by the caller.
local function outline(ext, off: number, step: number)
	local out = {}
	local prev, uturn = nil, false
	local function arc(cx: number, cz: number, from: number, delta: number)
		local n = math.max(1, math.ceil(math.abs(delta) * off / step))
		for j = 1, n - 1 do
			local q = from + delta * j / n
			table.insert(out, { x = cx + math.cos(q) * off, z = cz + math.sin(q) * off })
		end
	end
	local function walk(pts)
		for k = 1, #pts - 1 do
			local a, b = pts[k], pts[k + 1]
			local dx, dz = b.x - a.x, b.z - a.z
			local len = math.sqrt(dx * dx + dz * dz)
			if len < 1e-3 then
				continue
			end
			local ang = math.atan2(dz, dx)
			if prev then
				arc(a.x, a.z, prev + math.pi / 2, if uturn then -math.pi else wrap(ang - prev))
			end
			prev, uturn = ang, false
			local nx, nz = -dz / len, dx / len
			local n = math.max(1, math.ceil(len / step))
			for j = 0, n do
				local t = j / n
				table.insert(out, { x = a.x + dx * t + nx * off, z = a.z + dz * t + nz * off })
			end
		end
	end
	walk(ext)
	local back = {}
	for k = #ext, 1, -1 do
		table.insert(back, ext[k])
	end
	uturn = true
	walk(back)
	if prev then
		arc(ext[1].x, ext[1].z, prev + math.pi / 2, -math.pi)
	end
	return out
end

local function fencePost(F, plan, x: number, z: number, i: number, cap: boolean?): Vector3
	local a = plan.O * v3(x, 0, z)
	block(F.nature, v3(0.9, 4.4, 0.9), CFrame.new(a + v3(0, 2.2, 0)) * plan.O.Rotation, C.white, nil, true)
	if cap ~= false then
		ball(F.nature, 1.2, a + v3(0, 4.7, 0), if i % 2 == 0 then C.red else C.gold)
	end
	return a
end

local function fenceRails(F, a: Vector3, b: Vector3)
	bar(F.nature, a + v3(0, 3.4, 0), b + v3(0, 3.4, 0), 0.35, 0.5, C.white, nil, true)
	bar(F.nature, a + v3(0, 1.6, 0), b + v3(0, 1.6, 0), 0.35, 0.5, C.white, nil, true)
end

-- the white picket fence round the circle, open at the gate and wherever a course's corridor leaves it, and
-- along both sides and round the far end of every corridor that runs out beyond the circle
local function buildFence(plan, F)
	local rF = plan.rF
	local n = math.floor(TAU * rF / 16)
	local prev
	for i = 0, n do
		local x, z = polar(rF, i / n * TAU)
		local keep = not (math.abs(x) < 54 and z > 0) and plan:courseDist(x, z, CORRIDOR + 1) >= CORRIDOR + 1
		local a = plan.O * v3(x, 0, z)
		if keep and i < n then
			fencePost(F, plan, x, z, i)
		end
		if keep and prev then
			fenceRails(F, prev, a)
		end
		prev = if keep then a else nil
	end
	for _, z in plan.zones do
		local last
		for i, p in outline(z.ext, CORRIDOR, 30) do
			local d = plan:courseDist(p.x, p.z)
			local keep = p.x * p.x + p.z * p.z > (rF + 3) ^ 2 and math.abs(d - CORRIDOR) < 2 and not plan:inCourt(p.x, p.z, 6)
			if keep then
				local a = fencePost(F, plan, p.x, p.z, i, i % 2 == 0)
				if last and (last - a).Magnitude < 44 then
					fenceRails(F, last, a)
				end
				last = a
			else
				last = nil
			end
		end
	end
end

local function treeAt(F, plan, x: number, z: number, rng)
	if rng:NextNumber() < 0.3 then
		Dress.cypress(F.nature, plan:L(x, 0, z), nil, rng)
	else
		Dress.tree(F.nature, plan:L(x, 0, z), nil, rng)
	end
end

-- three rows of trees just outside the circle's fence, two along every corridor's, none in front of the gate
local function buildTreeLine(plan, F, rng)
	for row, r in { plan.rF + 20, plan.rF + 40, plan.rF + 62 } do
		local n = math.floor(TAU * r / 24)
		for i = 0, n - 1 do
			local a = (i + (row % 2) * 0.5) / n * TAU + rng:NextNumber(-0.01, 0.01)
			local x, z = polar(r + rng:NextNumber(-5, 5), a)
			if plan:courseDist(x, z, CORRIDOR + 14) >= CORRIDOR + 14 and not plan:inCourt(x, z, 14) then
				treeAt(F, plan, x, z, rng)
			end
		end
	end
	for _, z in plan.zones do
		for _, row in { { CORRIDOR + 24, 34, 0.8 }, { CORRIDOR + 50, 60, 0.5 } } do
			for _, p in outline(z.ext, row[1], row[2]) do
				local x, zz = p.x + rng:NextNumber(-5, 5), p.z + rng:NextNumber(-5, 5)
				if rng:NextNumber() < row[3] and x * x + zz * zz > (plan.rF + 70) ^ 2
					and plan:courseDist(x, zz, CORRIDOR + 12) >= CORRIDOR + 12 and not plan:inCourt(x, zz, 14) then
					treeAt(F, plan, x, zz, rng)
				end
			end
		end
	end
end

-- the height of the land at (x, z) in park-local studs: the highest hill there (terrain written this frame is
-- not raycastable yet on a live server, so the hills are tracked instead)
local function groundAt(mounds, x: number, z: number): number
	local y = 0
	for _, h in mounds do
		local d2 = (x - h[1]) ^ 2 + (z - h[2]) ^ 2
		if d2 < h[4] * h[4] then
			y = math.max(y, h[3] + math.sqrt(h[4] * h[4] - d2))
		end
	end
	return y
end

-- is (x, z) wild land, r studs round it clear of the park and its corridors and of the approach to the gate?
local function wild(plan, x: number, z: number, r: number): boolean
	return not plan:inPark(x, z, 60 + r) and not (math.abs(x) < 150 + r and z > 0 and z < plan.rF + 240 + r)
end

-- Beyond the fence: lakes, meadows, rolling hills, woods and a ring of mountains, kept off the park and every
-- course's corridor. Past the end of every course a hill and a mountain stand in its way, tall enough to fill
-- the view from the course's last stage, and the land runs on far past them.
local function buildLand(plan, F, rng)
	local T = workspace.Terrain
	local R, O = plan.R, plan.O
	local far = math.max(plan.reach, plan.rF + 100)
	local grow = math.clamp(far / (plan.rF + 100), 1, 2.5)
	local lakes, mounds = {}, {}
	local function hill(x, z, size)
		T:FillBall(O * v3(x, -0.55 * size, z), size, M.Grass)
		table.insert(mounds, { x, z, -0.55 * size, size })
	end
	local function mountain(x, z, size)
		T:FillBall(O * v3(x, -0.5 * size, z), size, M.Grass)
		T:FillBall(O * v3(x, 0.15 * size, z), 0.42 * size, M.Rock)
		table.insert(mounds, { x, z, -0.5 * size, size })
	end
	for _ = 1, math.round(30 * grow) do
		if #lakes >= math.round(2 * grow) then
			break
		end
		local x, z = polar(rng:NextNumber(plan.rF + 170, math.max(1.7 * R, far + 300)), rng:NextNumber(0, TAU))
		local r = rng:NextNumber(60, 100)
		if wild(plan, x, z, r + 10) then
			T:FillCylinder(O * CFrame.new(x, -1.5, z), 3, r + 10, M.Sand)
			T:FillCylinder(O * CFrame.new(x, -3, z), 6, r, M.Air)
			T:FillCylinder(O * CFrame.new(x, -3.6, z), 4.8, r, M.Water)
			table.insert(lakes, { x, z, r + 12 })
		end
	end
	local function nearLake(x, z, r)
		for _, l in lakes do
			if (x - l[1]) ^ 2 + (z - l[2]) ^ 2 < (l[3] + r) ^ 2 then
				return true
			end
		end
		return false
	end
	for _ = 1, math.round(26 * grow) do
		local x, z = polar(rng:NextNumber(plan.rF + 90, math.max(2.6 * R, far + 900)), rng:NextNumber(0, TAU))
		local r = rng:NextNumber(40, 110)
		if not nearLake(x, z, r) and wild(plan, x, z, 0) then
			T:FillCylinder(O * CFrame.new(x, -1.5, z), 3, r, M.LeafyGrass)
		end
	end
	-- past every course's end: a hill, then a mountain that rises over the course's last checkpoint
	for _, z in plan.zones do
		local e = z.path[#z.path]
		local dx, dz = z.endDir[1], z.endDir[2]
		local s = COURSE_AHEAD
		while s < 4000 and plan:inPark(e.x + dx * s, e.z + dz * s, 60) do
			s += 20
		end
		local peak = math.clamp((e.y + 50) / 0.57, 300, 460)
		for _, try in { 0, 0.25, -0.25, 0.5, -0.5 } do
			local c, sn = math.cos(try), math.sin(try)
			local ux, uz = dx * c - dz * sn, dx * sn + dz * c
			local hx, hz = e.x + ux * (s + 170), e.z + uz * (s + 170)
			local mx, mz = e.x + ux * (s + 300 + 0.85 * peak), e.z + uz * (s + 300 + 0.85 * peak)
			if wild(plan, mx, mz, 0.85 * peak) then
				if wild(plan, hx, hz, 110) and not nearLake(hx, hz, 110) then
					hill(hx, hz, 130)
				end
				mountain(mx, mz, peak)
				break
			end
		end
	end
	-- hills along both sides of every course that runs beyond the circle: it crosses a valley, not a plain
	for _, z in plan.zones do
		for _, p in stations(z.path, 300, 150) do
			if p.x * p.x + p.z * p.z > (plan.rF + 150) ^ 2 then
				for _, side in { -1, 1 } do
					local size = rng:NextNumber(110, 180)
					local d = CORRIDOR + 90 + 0.84 * size + rng:NextNumber(0, 70)
					local along = rng:NextNumber(-70, 70)
					local hx, hz = p.x - p.dz * side * d + p.dx * along, p.z + p.dx * side * d + p.dz * along
					if wild(plan, hx, hz, 0.84 * size) and not nearLake(hx, hz, 0.84 * size) then
						hill(hx, hz, size)
					end
				end
			end
		end
	end
	for _ = 1, math.round(40 * grow) do
		local size = rng:NextNumber(70, 170)
		local x, z = polar(rng:NextNumber(plan.rF + 90 + 0.84 * size, math.max(1.6 * R, far + 400) + 0.5 * size), rng:NextNumber(0, TAU))
		if wild(plan, x, z, 0.84 * size) and not nearLake(x, z, 0.84 * size) then
			hill(x, z, size)
		end
	end
	for _ = 1, math.round(18 * math.min(grow, 1.4)) do
		local size = rng:NextNumber(260, 420)
		local x, z = polar(rng:NextNumber(math.max(2.4 * R, far + 250), math.max(3.0 * R, far + 1000)), rng:NextNumber(0, TAU))
		if wild(plan, x, z, 0.87 * size) then
			mountain(x, z, size)
		end
	end
	for _ = 1, math.round(40 * math.min(grow, 1.6)) do
		local cx, cz = polar(rng:NextNumber(plan.rF + 120, math.max(2.4 * R, far + 600)), rng:NextNumber(0, TAU))
		for _ = 1, rng:NextInteger(4, 8) do
			local x, z = cx + rng:NextNumber(-34, 34), cz + rng:NextNumber(-34, 34)
			if wild(plan, x, z, 9) and not nearLake(x, z, 4) then
				local y = groundAt(mounds, x, z)
				Dress.tree(F.nature, plan:L(x, if y > 0 then y - 2 else 0, z), nil, rng) -- sunk a little on slopes
			end
		end
	end
end

-- ============================================================== public: the whole park

local function folders(park: Folder)
	local F = {}
	for key, name in { lobby = "Lobby", paths = "Paths", rides = "Rides", dress = "Dressing", nature = "Nature", ground = "Ground" } do
		local f = Instance.new("Folder")
		f.Name = name
		f.Parent = park
		F[key] = f
	end
	return F
end

-- WorldKit.buildPark(opts) -> { anchors = {[i] = CFrame}, gates = {[i] = CFrame}, spawn = CFrame, lobby = CFrame,
-- lots = {[name] = CFrame}, parts = number, courses }. opts: zones = {{name, theme, palette = {hex, ...}, length?}, ...}
-- (default: the 10 park themes), origin = CFrame (the hub on the ground, LookVector into the park; default
-- CFrame.new()), size = studs (1600), seed = number, title = entrance sign text, lots = {changingRoom = true} (a clear
-- spot in the plaza for Cosmetics.buildChangingRoom, in place of the left stall). Each zone's course is measured from ReplicatedStorage.Levels with the
-- game's ObbyKit (zone i = level zone i); without level data a zone's course is `length` studs straight ahead
-- (default 460). Replaces an existing workspace.Park and the template Baseplate.
function WorldKit.buildPark(opts)
	opts = if type(opts) == "table" then opts else {}
	assert(RunService:IsServer(), "WorldKit.buildPark runs on the server")
	made = 0
	local size = math.clamp(tonumber(opts.size) or 1600, 800, 4000)
	local rng = Random.new(math.floor(tonumber(opts.seed) or 1))
	local zones = normalizeZones(opts.zones)
	measureCourses(zones)
	applySky()
	terrainLook()
	local O = groundFrame(flatten(if typeof(opts.origin) == "CFrame" then opts.origin else CFrame.new()))
	local plan = Plan.new(O, size / 2, zones)
	local half = math.min(math.max(3.3 * plan.R, plan.reach + 1600), 9000)
	fillGround(O, half)
	local old = workspace:FindFirstChild("Park")
	if old then
		old:Destroy()
	end
	local base = workspace:FindFirstChild("Baseplate")
	if base and base:IsA("BasePart") then
		base:Destroy()
	end
	local park = Instance.new("Folder")
	park.Name = "Park"
	local F = folders(park)
	local title = if type(opts.title) == "string" and opts.title ~= "" then string.upper(opts.title) else "FUN PARK"
	groundUnderlay(O, half, F.ground)
	buildPaths(plan, F)
	courseAvenues(plan, F)
	buildLobby(plan, F, title, if type(opts.lots) == "table" then opts.lots else nil)
	buildForecourt(plan, F)
	task.wait()
	buildRides(plan, F)
	dressHub(plan, F, rng)
	dressAvenue(plan, F, rng)
	dressSpokes(plan, F, rng)
	dressRing(plan, F, rng)
	dressSectors(plan, F, rng)
	task.wait()
	local dressed = dressCourses(plan, F, rng)
	task.wait()
	-- long courses carry a lot of the fair out of the circle: fewer extra pieces inside it keep the park near 40k parts
	local fill = if dressed > 15000 then 0.7 else 1
	scatter(plan, F, rng, plan.rHub + 20, plan.rC - 20, math.round(150 * fill), { "tree", "tree", "flower_garden", "flower_bed",
		"cypress", "balloon_cluster", "grove", "picnic", "kiddie_ride" }, { kiddie_ride = 3 })
	scatter(plan, F, rng, plan.rC - 30, plan.rF - 14, math.round(190 * fill), { "flower_garden", "flower_garden", "tree", "tree", "grove",
		"grove", "bench", "pond", "minitrain", "swings", "booths", "popcorn_cart", "mini_golf", "picnic" },
		{ pond = 4, minitrain = 2, swings = 2, booths = 2, popcorn_cart = 6, mini_golf = 4 })
	buildFence(plan, F)
	buildTreeLine(plan, F, rng)
	task.wait()
	buildLand(plan, F, rng)
	park:SetAttribute("Parts", made)
	park:SetAttribute("Zones", #zones)
	park:SetAttribute("Reach", plan.reach)
	park:SetAttribute("Ground", half)
	park.Parent = workspace
	local anchors, gates, courses = {}, {}, {}
	for i, z in zones do
		anchors[i] = z.anchor
		gates[i] = z.gate
		courses[i] = {}
		for _, p in z.path do
			table.insert(courses[i], O * v3(p.x, p.y, p.z))
		end
		park:SetAttribute(string.format("Course%02d", i), string.format("%s, %.0f studs", if z.measured then "level data" else "length",
			pathLength(z.path)))
	end
	return { anchors = anchors, gates = gates, spawn = plan.spawn, lobby = plan.lobby, lots = plan.lots, parts = made,
		courses = courses }
end

-- ============================================================== public: motion on the client

local clientOn = false

-- WorldKit.client(): call once from a LocalScript. Runs every ride near the camera on this client, once per rendered
-- frame (smooth, nothing replicated), and tells the server to stop moving them.
function WorldKit.client()
	assert(RunService:IsClient(), "WorldKit.client runs in a LocalScript")
	if clientOn then
		return
	end
	clientOn = true
	local list = {}
	local function add(root: Instance)
		if list[root] or not root:IsA("BasePart") then
			return
		end
		local make = STEPS[root:GetAttribute("WKMotion")]
		if not make then
			return
		end
		local ok, step = pcall(make, root, true)
		if ok and step then
			local pivot = root:GetAttribute("WKPivot")
			list[root] = { step = step, at = if typeof(pivot) == "CFrame" then pivot.Position else root.Position }
		end
	end
	for _, root in CollectionService:GetTagged(MOVER_TAG) do
		add(root)
	end
	CollectionService:GetInstanceAddedSignal(MOVER_TAG):Connect(add)
	CollectionService:GetInstanceRemovedSignal(MOVER_TAG):Connect(function(root)
		list[root] = nil
	end)
	local active, nextScan = {}, 0
	RunService.RenderStepped:Connect(function()
		if os.clock() >= nextScan then
			nextScan = os.clock() + 0.5
			local cam = workspace.CurrentCamera
			local at = if cam then cam.CFrame.Position else Vector3.zero
			table.clear(active)
			for root, m in list do
				if root.Parent and (m.at - at).Magnitude < CLIENT_RANGE then
					table.insert(active, m)
				end
			end
		end
		local t = now()
		for _, m in active do
			if not pcall(m.step, t) then
				m.step = function() end
			end
		end
	end)
	task.spawn(function()
		local remote = ReplicatedStorage:WaitForChild(REMOTE, 30)
		if remote then
			remote:FireServer()
		end
	end)
end

return WorldKit
