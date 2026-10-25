--!nonstrict
-- ObbyThemes: prebuilt by Forge (forge/kit/modules/ObbyThemes.luau). Do not rewrite it; require it.
-- Dresses every ObbyKit piece as part of an amusement-park ride (ObbyThemes.dress) and lines each stage with lamps,
-- string lights, balloons and a sign with the stage's name (ObbyThemes.stageDecor). Every decoration keeps to this:
-- - it never collides, touches or answers queries and is massless. On a moving piece it sits in Dressing.Rides
--   (attribute Host) welded to the part that moves, directly or through other decoration; elsewhere it is anchored.
-- - The body space over every walkable top stays empty: the top's footprint grown by MARGIN, from FLUSH to CLEAR studs
--   above it, over the whole path of a moving piece too. Only flush paint lies on a top, trims hang under the edge,
--   props stand on brackets past the margin, and lamps and string lights keep out of it as well.
-- - Nothing that reads as floor (half a stud wide or more) lies within 0.7 studs under a top and reaches more than half
--   a stud past its edge.
-- - Kill parts are Neon in the theme's kill colour (KILL: a red-orange that no walkable top, jump pad or trampoline
--   uses), and lava wears a yellow-and-black hazard band.
-- - Legs reach the ground: a raycast straight down (and Terrain's voxels, which are right before a raycast sees new
--   Terrain) sizes them; a piece gets a short bracket instead when there is no ground within MAX_LEG studs or the
--   course is in the way.
-- A theme owns the look of walkable tops (colour, material), kill parts, the kit's checkpoint flag, turntable stripes,
-- conveyor chevrons and pendulum frame. dress() saves every kit property it changes in a ThemeOrig_<property> attribute
-- and puts them all back (and removes its ThemeFx emitters) before it dresses a piece again or when the theme is nil.
-- stageDecor finally sweeps the stage: any decoration that reaches into a walkable's body space (in this stage or a
-- stage already built next to it) is removed together with the prop it belongs to.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local ObbyThemes = {}
ObbyThemes.VERSION = 2
ObbyThemes.THEMES = { "entrance", "carousel", "bumper", "teacups", "ferris", "flume", "haunted", "pirate", "coaster", "finale" }
ObbyThemes.MAX_STAGE_PARTS = 60

local CLEAR, MARGIN, FLUSH = 7, 0.5, 0.12
local MAX_LEG = 90
local ORIG = "ThemeOrig_"

-- ============================================================== palette and materials

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local C = {
	white = rgb(255, 255, 255), snow = rgb(246, 247, 251), cream = rgb(255, 243, 214), porcelain = rgb(255, 253, 247),
	red = rgb(232, 52, 58), gold = rgb(247, 190, 58), warm = rgb(255, 228, 150), pink = rgb(255, 93, 143),
	blush = rgb(255, 179, 209), lilac = rgb(201, 167, 255), purple = rgb(142, 91, 255), violet = rgb(112, 64, 255),
	navy = rgb(32, 34, 72), sky = rgb(73, 182, 255), psky = rgb(160, 210, 255), mint = rgb(95, 227, 192),
	pmint = rgb(168, 230, 207), yellow = rgb(255, 210, 63), orange = rgb(255, 138, 61), dark = rgb(38, 39, 46),
	steel = rgb(176, 186, 198), iron = rgb(58, 61, 68), rubber = rgb(34, 35, 43), wood = rgb(156, 107, 60),
	plank = rgb(196, 148, 92), deck = rgb(128, 78, 42), darkwood = rgb(96, 62, 34), rope = rgb(217, 183, 126),
	foam = rgb(232, 250, 255), deep = rgb(22, 110, 160), lily = rgb(62, 150, 74), leaf = rgb(76, 175, 80),
	moss = rgb(80, 160, 80), slate = rgb(84, 86, 100), stone = rgb(120, 122, 134), crypt = rgb(66, 52, 96),
	bone = rgb(233, 226, 207), ghost = rgb(124, 255, 178), glow = rgb(178, 107, 255), sail = rgb(243, 233, 210),
	track = rgb(222, 44, 60), magenta = rgb(255, 43, 214), cyan = rgb(32, 227, 255), lime = rgb(140, 255, 79),
	pumpkin = rgb(255, 128, 20), hazard = rgb(255, 214, 10), soot = rgb(30, 30, 34),
}
local WARN = rgb(255, 236, 140) -- ObbyKit's COLORS.warn: a vanishing tile flashes it before it goes

-- Each theme's kill colour: lava, spinner bars, pendulum balls.
local KILL = {
	entrance = rgb(255, 98, 24), carousel = rgb(255, 72, 38), bumper = rgb(255, 46, 58), teacups = rgb(255, 112, 28),
	ferris = rgb(255, 78, 30), flume = rgb(255, 88, 20), haunted = rgb(240, 40, 52), pirate = rgb(255, 92, 22),
	coaster = rgb(255, 58, 34), finale = rgb(255, 66, 20),
}

local function material(name: string): Enum.Material
	local ok, m = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and m then m else Enum.Material.SmoothPlastic
end

local SMOOTH, NEON, METAL = Enum.Material.SmoothPlastic, Enum.Material.Neon, Enum.Material.Metal
local WOOD, PLANKS, SLATE, DIAMOND = Enum.Material.Wood, Enum.Material.WoodPlanks, Enum.Material.Slate, Enum.Material.DiamondPlate
local RUBBER = material("Rubber")

-- The walkable tops a theme owns: { colour, material } per kind. Pads that mean something (checkpoint, jump pad,
-- trampoline) keep the kit's colours.
local TOPS = {
	entrance = { platform = { C.cream }, moving = { C.gold }, tile = { C.purple }, bridge = { C.cream }, base = { C.gold },
		turntable = { C.cream }, belt = { C.purple }, chevron = C.gold, stripe = C.purple },
	carousel = { platform = { C.cream }, moving = { C.blush }, tile = { C.lilac }, bridge = { C.cream }, base = { C.blush },
		turntable = { C.cream }, belt = { C.blush }, chevron = C.white, stripe = C.pink },
	bumper = { platform = { C.steel, DIAMOND }, moving = { C.rubber, RUBBER }, tile = { C.violet, NEON },
		bridge = { C.steel, DIAMOND }, base = { C.rubber, RUBBER }, turntable = { C.rubber, RUBBER }, belt = { C.iron, DIAMOND },
		chevron = C.hazard, stripe = C.hazard },
	teacups = { platform = { C.porcelain }, moving = { C.porcelain }, tile = { C.pmint }, bridge = { C.porcelain },
		base = { C.lilac }, turntable = { C.porcelain }, belt = { C.lilac }, chevron = C.white, stripe = C.gold },
	ferris = { platform = { C.snow }, moving = { C.snow }, tile = { C.purple }, bridge = { C.snow }, base = { C.snow },
		turntable = { C.snow }, belt = { C.steel, METAL }, chevron = C.gold, stripe = C.purple },
	flume = { platform = { C.plank, PLANKS }, moving = { C.plank, PLANKS }, tile = { C.lily }, bridge = { C.plank, PLANKS },
		base = { C.plank, PLANKS }, turntable = { C.plank, PLANKS }, belt = { C.foam }, chevron = C.deep, stripe = C.darkwood },
	haunted = { platform = { C.crypt, SLATE }, moving = { C.darkwood, WOOD }, tile = { C.stone, SLATE },
		bridge = { C.darkwood, PLANKS }, base = { C.crypt, SLATE }, turntable = { C.stone, SLATE }, belt = { C.slate, SLATE },
		chevron = C.glow, stripe = C.glow },
	pirate = { platform = { C.deck, PLANKS }, moving = { C.plank, PLANKS }, tile = { C.wood, WOOD }, bridge = { C.darkwood, PLANKS },
		base = { C.deck, PLANKS }, turntable = { C.deck, PLANKS }, belt = { C.deck, PLANKS }, chevron = C.rope, stripe = C.gold },
	coaster = { platform = { C.navy, DIAMOND }, moving = { C.rubber, RUBBER }, tile = { C.snow }, bridge = { C.navy, DIAMOND },
		base = { C.steel, METAL }, turntable = { C.steel, METAL }, belt = { C.iron, DIAMOND }, chevron = C.hazard, stripe = C.hazard },
	finale = { platform = { C.navy }, moving = { C.navy }, tile = { C.violet, NEON }, bridge = { C.navy }, base = { C.navy },
		turntable = { C.navy }, belt = { C.navy }, chevron = C.gold, stripe = C.magenta },
}

local SPARKLE = "rbxasset://textures/particles/sparkles_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

-- ============================================================== theme names

local ALIASES = {
	entrance = { "entrance", "gate", "ticket", "tickets", "lobby", "welcome", "popcorn", "plaza", "front" },
	carousel = { "carousel", "merry", "horse", "horses", "pony", "ponies", "candy" },
	bumper = { "bumper", "dodgem", "dodgems", "arena", "sparks", "arcade", "midway" },
	teacups = { "teacups", "teacup", "tea", "saucer", "saucers", "cups" },
	ferris = { "ferris", "wheel", "gondola", "gondolas", "heights" },
	flume = { "flume", "log", "logs", "water", "splash", "rafts", "raft", "river", "lagoon" },
	haunted = { "haunted", "ghost", "ghosts", "spooky", "graveyard", "halloween", "horror", "ghoul", "pumpkins" },
	pirate = { "pirate", "pirates", "ship", "treasure", "anchor", "cove", "galleon" },
	coaster = { "coaster", "rollercoaster", "roller", "loop", "loops", "carts", "track" },
	finale = { "finale", "firework", "fireworks", "neon", "rocket", "rockets" },
}

-- A theme id for an id or free text (a zone name or description): the id itself, else the theme whose words it uses
-- most (ties go to the earlier theme in THEMES), else "entrance". nil or blank text has no theme (nil).
function ObbyThemes.resolve(text: any): string?
	if text == nil then
		return nil
	end
	local low = string.lower(tostring(text))
	if string.match(low, "^%s*$") then
		return nil
	end
	if ALIASES[low] then
		return low
	end
	local words = {}
	for w in string.gmatch(low, "[a-z]+") do
		words[w] = (words[w] or 0) + 1
	end
	local best, bestScore = "entrance", 0
	for _, id in ObbyThemes.THEMES do
		local score = 0
		for _, w in ALIASES[id] do
			score += words[w] or 0
		end
		if score > bestScore then
			best, bestScore = id, score
		end
	end
	return best
end

-- ============================================================== geometry: walkable tops and their body space

local CYL = CFrame.Angles(0, 0, math.rad(90)) -- a Cylinder's axis is its local X: this turns it to local Y
local FLAT = CFrame.Angles(math.rad(90), 0, 0) -- local Y to local Z (a disc facing forward)
local TURN = CFrame.Angles(0, math.pi, 0)

-- How a walkable part is built: "disc" (an upright Cylinder), "log" (a Cylinder lying across the course, ObbyKit v2
-- Shape "cylinder"), "ramp" (a WedgePart climbing along the course, Shape "wedge-ramp") or "block".
local function shapeOf(part: BasePart): string
	local tag = part:GetAttribute("Shape")
	if tag == "cylinder" then
		return "log"
	elseif tag == "wedge-ramp" or part:IsA("WedgePart") then
		return "ramp"
	elseif part:IsA("Part") and (part :: Part).Shape == Enum.PartType.Cylinder then
		return "disc"
	end
	return "block"
end

-- The top of a walkable part: its frame (Y up, -Z along the course; a log's at its crown, a ramp's level with its high
-- far end), width, length, shape and, for a ramp, how far its low near edge sits under that frame. rest: where a
-- mover starts its path.
local function topOf(part: BasePart, rest: boolean?): (CFrame, number, number, string, number)
	local cf = part.CFrame
	if rest then
		local r = part:GetAttribute("Rest")
		if typeof(r) == "CFrame" then
			cf = r
		end
	end
	local s = part.Size
	local shape = shapeOf(part)
	if shape == "disc" then
		return cf * CYL:Inverse() * CFrame.new(0, s.X / 2, 0), s.Y, s.Y, shape, 0
	elseif shape == "log" then
		return cf * CFrame.new(0, s.Y / 2, 0), s.X, s.Y, shape, 0
	elseif shape == "ramp" then
		return cf * TURN * CFrame.new(0, s.Y / 2, 0), s.X, s.Z, shape, s.Y
	end
	return cf * CFrame.new(0, s.Y / 2, 0), s.X, s.Z, shape, 0
end

-- How deep a walkable reaches under its top frame.
local function depthOf(part: BasePart): number
	local shape = shapeOf(part)
	return if shape == "disc" then part.Size.X else part.Size.Y
end

-- The body space over a walkable, as a box in a frame on its top at rest (a ramp's frame lies on its slope): lo..hi
-- spans the footprint plus MARGIN and FLUSH to CLEAR over the top, stretched along a mover's whole path; slo..shi is
-- the same box where the part is (for decorations that ride on it); r for a disc.
local function columnOf(part: BasePart, piece: Instance?)
	local top, w, l, shape, rise = topOf(part, true)
	local col: { [string]: any } = { part = part, piece = piece, cf = top }
	if shape == "ramp" then
		col.cf = top * CFrame.new(0, -rise / 2, 0) * CFrame.Angles(math.atan2(rise, l), 0, 0)
		l = math.sqrt(l * l + rise * rise)
	elseif shape == "disc" then
		col.r = w / 2 + MARGIN
	end
	col.slo = Vector3.new(-w / 2 - MARGIN, FLUSH, -l / 2 - MARGIN)
	col.shi = Vector3.new(w / 2 + MARGIN, CLEAR, l / 2 + MARGIN)
	col.lo, col.hi = col.slo, col.shi
	local mv = part:GetAttribute("Move")
	if typeof(mv) == "Vector3" then
		local d = Vector3.new(mv.X, mv.Y, -mv.Z)
		col.lo, col.hi = col.slo:Min(col.slo + d), col.shi:Max(col.shi + d)
	end
	return col
end

-- The corners of a box (cf, size) seen from frame f, as the min and max of an axis-aligned box around it.
local function extent(f: CFrame, cf: CFrame, size: Vector3): (Vector3, Vector3)
	local rel = f:ToObjectSpace(cf)
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local x, y, z = rel.XVector, rel.YVector, rel.ZVector
	local e = Vector3.new(
		math.abs(x.X) * hx + math.abs(y.X) * hy + math.abs(z.X) * hz,
		math.abs(x.Y) * hx + math.abs(y.Y) * hy + math.abs(z.Y) * hz,
		math.abs(x.Z) * hx + math.abs(y.Z) * hy + math.abs(z.Z) * hz
	)
	local p = rel.Position
	return p - e, p + e
end

-- Does the box lo..hi (in the column's frame) reach into it? here: judge it against where the part is, not its path.
local function inColumn(col, lo: Vector3, hi: Vector3, here: boolean?): boolean
	local clo, chi = if here then col.slo else col.lo, if here then col.shi else col.hi
	if hi.Y <= clo.Y or lo.Y >= chi.Y then
		return false
	end
	if col.r then
		local cx, cz = math.clamp(0, lo.X, hi.X), math.clamp(0, lo.Z, hi.Z)
		return cx * cx + cz * cz < col.r * col.r
	end
	return hi.X > clo.X and lo.X < chi.X and hi.Z > clo.Z and lo.Z < chi.Z
end

-- The frame to judge a box at `cf` against a column in: a disc's frame turned to face the box (a circle looks the same
-- from every side), so a box set round a disc is judged by where it is, not by the square around it.
local function frameFor(col, cf: CFrame): CFrame
	if not col.r then
		return col.cf
	end
	local p = col.cf:PointToObjectSpace(cf.Position)
	if p.X * p.X + p.Z * p.Z < 1e-6 then
		return col.cf
	end
	return col.cf * CFrame.Angles(0, math.atan2(-p.X, -p.Z), 0)
end

-- A part turning round the vertical axis through `at` sweeps a ring: does it pass through the column?
local function ringHits(col, at: Vector3, cf: CFrame, size: Vector3): boolean
	local lo, hi = extent(col.cf, cf, size)
	if hi.Y <= col.lo.Y or lo.Y >= col.hi.Y then
		return false
	end
	local alo, ahi = extent(CFrame.new(at), cf, size)
	local rmax = math.sqrt(math.max(alo.X * alo.X, ahi.X * ahi.X) + math.max(alo.Z * alo.Z, ahi.Z * ahi.Z))
	local nx, nz = math.clamp(0, alo.X, ahi.X), math.clamp(0, alo.Z, ahi.Z)
	local rmin = math.sqrt(nx * nx + nz * nz)
	local c = col.cf:PointToObjectSpace(at)
	local dmin, dmax
	if col.r then
		local m = math.sqrt(c.X * c.X + c.Z * c.Z)
		dmin, dmax = math.max(0, m - col.r), m + col.r
	else
		local clo, chi = col.lo, col.hi
		local qx, qz = math.clamp(c.X, clo.X, chi.X), math.clamp(c.Z, clo.Z, chi.Z)
		dmin = math.sqrt((c.X - qx) ^ 2 + (c.Z - qz) ^ 2)
		dmax = math.sqrt(math.max((c.X - clo.X) ^ 2, (c.X - chi.X) ^ 2) + math.max((c.Z - clo.Z) ^ 2, (c.Z - chi.Z) ^ 2))
	end
	return dmin < rmax and dmax > rmin
end

-- How the part decorations hang on moves: slide (a mover: `move` from its rest, `back` = how far it is from rest
-- now), spin (a turntable or spinner bar, round the vertical axis through `at`) or swing (a pendulum ball round `pivot`).
local function motionOf(host: BasePart?)
	if not host then
		return nil
	end
	local mv = host:GetAttribute("Move")
	if typeof(mv) == "Vector3" then
		local rest = host:GetAttribute("Rest")
		local base = if typeof(rest) == "CFrame" then rest else host.CFrame
		return { kind = "slide", host = host, move = base:VectorToWorldSpace(Vector3.new(mv.X, mv.Y, -mv.Z)),
			back = host.Position - base.Position }
	end
	if host.Name == "Turntable" or host.Name == "Bar" then
		return { kind = "spin", host = host, at = host.Position }
	end
	if host.Name == "Ball" then
		local model = host.Parent
		local beam = model and model:FindFirstChild("Beam")
		if beam and beam:IsA("BasePart") then
			return { kind = "swing", host = host, pivot = beam.CFrame * CFrame.new(0, -0.6, 0) }
		end
	end
	return nil
end

-- A long thin part as a row of short boxes along its length, so a slanted rod or branch is judged by where it is,
-- not by the box around it.
local function segments(cf: CFrame, size: Vector3): { { any } }
	local len = math.max(size.X, size.Y, size.Z)
	local axis = if len == size.X then Vector3.xAxis elseif len == size.Y then Vector3.yAxis else Vector3.zAxis
	local thick = math.max(size.X + size.Y + size.Z - len - math.min(size.X, size.Y, size.Z), 0)
	if len <= 2 or len < 2 * thick then
		return { { cf, size } }
	end
	local n = math.ceil(len / 1.2)
	local seg = len / n
	local part = size - axis * (len - seg)
	local out = {}
	for i = 1, n do
		table.insert(out, { cf * CFrame.new(axis * (-len / 2 + seg * (i - 0.5))), part })
	end
	return out
end

-- Does a box (decoration moving with `motion`) reach into the column? A box that rides the column's own part moves
-- with it: it is judged where it sits on that part (at the part's rest), against the part's footprint.
local function boxHits(col, cf: CFrame, size: Vector3, motion): boolean
	if motion and motion.host == col.part then
		local at = if motion.kind == "slide" then cf - motion.back else cf
		local lo, hi = extent(frameFor(col, at), at, size)
		return inColumn(col, lo, hi, true)
	end
	if motion and motion.kind == "slide" then
		local at = cf - motion.back
		local f = frameFor(col, at)
		local lo, hi = extent(f, at, size)
		local d = f:VectorToObjectSpace(motion.move)
		return inColumn(col, lo:Min(lo + d), hi:Max(hi + d))
	elseif motion and motion.kind == "spin" then
		return ringHits(col, motion.at, cf, size)
	elseif motion and motion.kind == "swing" then
		local alo, ahi = extent(motion.pivot, cf, size)
		local r = math.sqrt(math.max(alo.X * alo.X, ahi.X * ahi.X) + math.max(alo.Y * alo.Y, ahi.Y * ahi.Y))
		local box = motion.pivot * CFrame.new(0, 0, (alo.Z + ahi.Z) / 2)
		local lo, hi = extent(frameFor(col, box), box, Vector3.new(2 * r, 2 * r, ahi.Z - alo.Z))
		return inColumn(col, lo, hi)
	end
	local lo, hi = extent(frameFor(col, cf), cf, size)
	return inColumn(col, lo, hi)
end

-- Does decoration part p (moving with `motion`) reach into the column?
local function partHits(col, p: BasePart, motion): boolean
	for _, s in segments(p.CFrame, p.Size) do
		if boxHits(col, s[1], s[2], motion) then
			return true
		end
	end
	return false
end

local function standable(p: Instance): boolean
	return p:IsA("BasePart") and CollectionService:HasTag(p, "ObbyStandable")
end

-- The body spaces near a piece: its own walkables and those of the pieces beside it (same parent, built so far).
local function columnsNear(model: Instance, centre: Vector3)
	local cols = {}
	for _, p in model:GetChildren() do
		if standable(p) then
			table.insert(cols, columnOf(p :: BasePart, model))
		end
	end
	local parent = model.Parent
	if parent and parent ~= workspace then
		for _, sib in parent:GetChildren() do
			if sib ~= model and sib:IsA("Model") then
				for _, p in sib:GetChildren() do
					if standable(p) and ((p :: BasePart).Position - centre).Magnitude < 70 then
						table.insert(cols, columnOf(p :: BasePart, sib))
					end
				end
			end
		end
	end
	return cols
end

-- ============================================================== the part factory

local MOVING = { Mover = true, Bar = true, Turntable = true, Ball = true }

local function moves(part: BasePart?): boolean
	return part ~= nil and (MOVING[part.Name] == true or part:GetAttribute("Move") ~= nil)
end

-- ctx = { root, folder, rng, theme, parts, dropped, model, cols, host, weld, motion, hazard, still }.
local function container(ctx, name: string, host: BasePart?): Instance
	local c = ctx.root:FindFirstChild(name)
	if not c then
		c = Instance.new("Model")
		c.Name = name
		if host then
			c:SetAttribute("Host", host.Name)
		end
		c.Parent = ctx.root
	end
	return c
end

-- Shapes made next go on `host`: welded to it in Rides when it moves, anchored in ctx.still (Fixed, or a vanishing
-- tile's own model) otherwise.
local function on(ctx, host: BasePart?, weld: boolean?)
	ctx.host = host
	ctx.weld = host ~= nil and (if weld ~= nil then weld else moves(host))
	ctx.folder = if ctx.weld then container(ctx, "Rides", host) else container(ctx, ctx.still or "Fixed")
	ctx.motion = if ctx.weld then motionOf(host) else nil
	ctx.hazard = host ~= nil and CollectionService:HasTag(host, "KillPart")
end

local function put(ctx, class: string, shape: Enum.PartType?, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?): BasePart
	local p = Instance.new(class) :: BasePart
	if shape then
		(p :: Part).Shape = shape
	end
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = mat or SMOOTH
	p.Name = "Deco"
	p.TopSurface, p.BottomSurface = Enum.SurfaceType.Smooth, Enum.SurfaceType.Smooth
	p.CanCollide, p.CanTouch, p.CanQuery = false, false, false
	p.Massless = true
	p.CastShadow = size.X * size.Y * size.Z > 6
	if ctx.hazard then
		p:SetAttribute("Hazard", true)
	end
	if ctx.weld and ctx.host then
		p.Anchored = false
		local w = Instance.new("WeldConstraint")
		w.Part0, w.Part1 = ctx.host, p
		w.Parent = p
	else
		p.Anchored = true
	end
	p.Parent = ctx.folder
	ctx.parts += 1
	return p
end

local function box(ctx, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?): BasePart
	return put(ctx, "Part", nil, size, cf, color, mat)
end

local function ball(ctx, d: number, cf: CFrame, color: Color3, mat: Enum.Material?): BasePart
	return put(ctx, "Part", Enum.PartType.Ball, Vector3.new(d, d, d), cf, color, mat)
end

-- A cylinder of diameter d and length len whose axis is cf's UpVector.
local function cyl(ctx, d: number, len: number, cf: CFrame, color: Color3, mat: Enum.Material?): BasePart
	return put(ctx, "Part", Enum.PartType.Cylinder, Vector3.new(len, d, d), cf * CYL, color, mat)
end

-- WedgePart: full height at the back (+Z), sloping down to the front (-Z).
local function wedge(ctx, size: Vector3, cf: CFrame, color: Color3, mat: Enum.Material?): BasePart
	return put(ctx, "WedgePart", nil, size, cf, color, mat)
end

-- A round rod from a to b (strings, poles, spokes, braces).
local function rod(ctx, a: Vector3, b: Vector3, d: number, color: Color3, mat: Enum.Material?): BasePart?
	local v = b - a
	local len = v.Magnitude
	if len < 0.05 then
		return nil
	end
	local up = if math.abs(v.Unit.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	local cf = CFrame.lookAt((a + b) / 2, b, up) * CFrame.Angles(0, math.rad(90), 0)
	return put(ctx, "Part", Enum.PartType.Cylinder, Vector3.new(len, d, d), cf, color, mat)
end

local function bulb(ctx, cf: CFrame, color: Color3?, d: number?): BasePart
	return ball(ctx, d or 0.55, cf, color or C.warm, NEON)
end

local function light(part: BasePart, color: Color3, range: number, brightness: number?)
	local l = Instance.new("PointLight")
	l.Color, l.Range, l.Brightness, l.Shadows = color, range, brightness or 1.2, false
	l.Parent = part
	return l
end

-- Particles on any part; the ones on kit parts are found by name (ThemeFx) and removed before a piece is dressed again.
local function particles(part: BasePart, texture: string, color: Color3, rate: number, speed: number, life: number, size: number?)
	local e = Instance.new("ParticleEmitter")
	e.Name = "ThemeFx"
	e.Texture = texture
	e.Color = ColorSequence.new(color)
	e.LightEmission = 0.6
	e.Rate = rate
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.Lifetime = NumberRange.new(life * 0.6, life)
	e.SpreadAngle = Vector2.new(25, 25)
	e.EmissionDirection = Enum.NormalId.Top
	local s = size or 0.8
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, s), NumberSequenceKeypoint.new(1, 0) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	e.Parent = part
	return e
end

-- Text on one face of a part (default its front, -Z).
local function label(part: BasePart, text: string, color: Color3, stroke: Color3?, face: Enum.NormalId?)
	local g = Instance.new("SurfaceGui")
	g.Name = "ThemeText"
	g.Face = face or Enum.NormalId.Front
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = 40
	g.LightInfluence = 0
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.Size = UDim2.fromScale(1, 1)
	t.Font = Enum.Font.FredokaOne
	t.TextScaled = true
	t.Text = text
	t.TextColor3 = color
	t.TextStrokeColor3 = stroke or C.dark
	t.TextStrokeTransparency = 0.1
	t.Parent = g
	g.Parent = part
	return g
end

-- Does every part of `g` keep out of the body spaces in ctx.cols? A prop on a kill part may sweep its own piece.
local function fits(ctx, g: Instance): boolean
	for _, p in g:GetDescendants() do
		if p:IsA("BasePart") then
			local hazard = p:GetAttribute("Hazard") == true
			for _, col in ctx.cols do
				if not (hazard and col.piece == ctx.model) and partHits(col, p, ctx.motion) then
					return false
				end
			end
		end
	end
	return true
end

-- One prop (a leg, a lamp, a string of lights) as its own Model: dropped whole when any part of it would reach into a
-- walkable's body space. Returns the Model, or nil when it was dropped.
local function group(ctx, name: string, build: () -> ()): Model?
	local g = Instance.new("Model")
	g.Name = name
	g.Parent = ctx.folder
	local saved, before = ctx.folder, ctx.parts
	ctx.folder = g
	local ok, err = pcall(build)
	ctx.folder = saved
	if ok and fits(ctx, g) then
		return g
	end
	if not ok then
		warn(string.format("[ObbyThemes] %s %s: %s", tostring(ctx.theme), name, tostring(err)))
	end
	ctx.parts = before
	ctx.dropped += 1
	g:Destroy()
	return nil
end

local function pick(ctx, list: { any }): any
	return list[ctx.rng:NextInteger(1, #list)]
end

-- ============================================================== the kit's own parts: owned and put back

local hooks = setmetatable({}, { __mode = "k" })

local function hook(ctx, signal: RBXScriptSignal, fn: () -> ())
	local list = hooks[ctx.model]
	if not list then
		list = {}
		hooks[ctx.model] = list
	end
	table.insert(list, signal:Connect(fn))
end

-- Set a property of a kit part, saving the kit's value the first time (ThemeOrig_<property>).
local function own(inst: Instance?, prop: string, value: any)
	if inst == nil then
		return
	end
	local key = ORIG .. prop
	if inst:GetAttribute(key) == nil then
		local cur = (inst :: any)[prop]
		inst:SetAttribute(key, if typeof(cur) == "EnumItem" then cur.Name else cur)
	end
	(inst :: any)[prop] = value
end

-- Undo dress(): disconnect its hooks, put every saved kit property back and remove its emitters from kit parts.
local function restore(model: Instance)
	local list = hooks[model]
	if list then
		for _, c in list do
			c:Disconnect()
		end
		hooks[model] = nil
	end
	local fx = {}
	for _, d in model:GetDescendants() do
		if d:IsA("ParticleEmitter") and d.Name == "ThemeFx" then
			table.insert(fx, d)
		else
			for key, v in d:GetAttributes() do
				if string.sub(key, 1, #ORIG) == ORIG then
					local prop = string.sub(key, #ORIG + 1)
					pcall(function()
						(d :: any)[prop] = if prop == "Material" then (Enum.Material :: any)[v] else v
					end)
					d:SetAttribute(key, nil)
				end
			end
		end
	end
	for _, e in fx do
		e:Destroy()
	end
end

local function paint(part: BasePart?, spec: { any }?)
	if part and spec then
		own(part, "Color", spec[1])
		own(part, "Material", spec[2] or SMOOTH)
	end
end

-- A vanishing tile in its theme's colour: ObbyKit puts its own colour back each time the tile turns solid and flashes
-- WARN before it goes, so the theme's colour comes back on every solid and the warning flash stays.
local function paintTile(ctx, tile: BasePart, spec: { any })
	own(tile, "Material", spec[2] or SMOOTH)
	own(tile, "Color", tile.Color)
	local function apply()
		if tile.Color ~= WARN and tile.Color ~= spec[1] then
			tile.Color = spec[1]
		end
	end
	hook(ctx, tile:GetPropertyChangedSignal("Color"), apply)
	apply()
end

-- A vanishing tile's decorations fade, flicker and vanish with it (ObbyKit drives the tile's Transparency).
local function mirror(ctx, tile: BasePart, folder: Instance)
	local base = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") then
			base[d] = d.Transparency
		elseif d:IsA("TextLabel") then
			base[d] = d.TextTransparency
		elseif d:IsA("Light") or d:IsA("ParticleEmitter") then
			base[d] = -1
		end
	end
	local function sync()
		local t = tile.Transparency
		for inst, b in base do
			if b < 0 then
				(inst :: any).Enabled = t < 0.9
			elseif inst:IsA("TextLabel") then
				inst.TextTransparency = b + (1 - b) * t
				inst.TextStrokeTransparency = 0.1 + 0.9 * t
			else
				(inst :: BasePart).Transparency = b + (1 - b) * t
			end
		end
	end
	hook(ctx, tile:GetPropertyChangedSignal("Transparency"), sync)
	sync()
end

-- Hang `root` (and what is welded to it) off the moving `host` with a Weld whose offset bobs each time ObbyKit moves
-- the host, so it only animates while the ride runs near a player.
local function bob(ctx, root: BasePart, host: BasePart, amp: number, period: number, phase: number)
	root.Anchored = false
	local weld = Instance.new("Weld")
	weld.Part0, weld.Part1 = host, root
	weld.C0 = host.CFrame:ToObjectSpace(root.CFrame)
	weld.Parent = root
	local c0 = weld.C0
	hook(ctx, host:GetPropertyChangedSignal("CFrame"), function()
		-- the offset is in the host's frame (up = the ride's up), not the pole's: a Cylinder's own Y is sideways
		weld.C0 = CFrame.new(0, amp * math.sin(2 * math.pi * (os.clock() / period + phase)), 0) * c0
	end)
end

-- ============================================================== legs

local COURSE_TAGS = { "ObbyStandable", "KillPart", "Obstacle", "ObbyStage", "ObbyStart", "ObbyZoneStart", "Checkpoint" }

local function isCourse(inst: Instance?): boolean
	local cur = inst
	while cur and cur ~= workspace and cur ~= game do
		for _, tag in COURSE_TAGS do
			if CollectionService:HasTag(cur, tag) then
				return true
			end
		end
		cur = cur.Parent
	end
	return false
end

-- The surface of solid Terrain straight under `from`, within MAX_LEG, read from its voxels: a raycast only sees
-- Terrain a moment after it is filled (WorldKit fills it just before the course is built), its voxels at once.
local function terrainTop(from: Vector3): number?
	local x0, z0 = math.floor(from.X / 4) * 4, math.floor(from.Z / 4) * 4
	local y0, y1 = math.floor((from.Y - MAX_LEG) / 4) * 4, math.floor(from.Y / 4) * 4
	if y1 <= y0 then
		return nil
	end
	local ok, mats, occ = pcall(function()
		return workspace.Terrain:ReadVoxels(Region3.new(Vector3.new(x0, y0, z0), Vector3.new(x0 + 4, y1, z0 + 4)), 4)
	end)
	local column = ok and type(mats) == "table" and mats[1]
	if not column or type(occ) ~= "table" then
		return nil
	end
	for j = (y1 - y0) / 4, 1, -1 do
		local m = column[j] and column[j][1]
		if m and m ~= Enum.Material.Air then
			local o = occ[1] and occ[1][j] and occ[1][j][1] or 1
			return y0 + 4 * (j - 1) + 4 * math.clamp(o, 0, 1)
		end
	end
	return nil
end

-- How far down the ground is from `from` (Terrain, the park, a baseplate), or nil: nothing within MAX_LEG, or the
-- course is in the way. Players' characters are looked through.
local function groundBelow(ctx, from: Vector3): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip = { ctx.model }
	for _, pl in Players:GetPlayers() do
		if pl.Character then
			table.insert(skip, pl.Character)
		end
	end
	params.FilterDescendantsInstances = skip
	local ok, hit = pcall(function()
		return workspace:Raycast(from, Vector3.new(0, -MAX_LEG, 0), params)
	end)
	if ok and hit and isCourse(hit.Instance) then
		return nil
	end
	local y = if ok and hit then hit.Position.Y else nil
	local t = terrainTop(from)
	if t and (not y or t > y) then
		y = t
	end
	return if y then from.Y - y else nil
end

-- A support at (x, z) under a walkable whose underside is `under` studs below its top: style.leg(ctx, a, b) from a down
-- to the ground at b when there is ground, else style.bracket(ctx, a). Each is its own group, so one that would
-- reach into a walkable's body space (another piece below) is dropped.
local function support(ctx, top: CFrame, x: number, z: number, under: number, style)
	local a = (top * CFrame.new(x, -under, z)).Position
	local depth = groundBelow(ctx, a - Vector3.new(0, 0.05, 0))
	if depth and depth > 1.5 then
		group(ctx, "Leg", function()
			style.leg(ctx, a, a - Vector3.new(0, depth + 0.05, 0))
		end)
	elseif style.bracket then
		group(ctx, "Bracket", function()
			style.bracket(ctx, a)
		end)
	end
end

local function supports(ctx, th, top: CFrame, w: number, l: number, under: number, shape: string)
	local st = th.legs
	if not st then
		return
	end
	local spots
	if shape == "disc" then
		spots = { Vector2.new(0, 0) }
	elseif shape == "log" then
		spots = { Vector2.new(-w / 2 + 0.8, 0), Vector2.new(w / 2 - 0.8, 0) }
	else
		spots = st.spots(w, l)
	end
	local done = {}
	for _, s in spots do
		-- a ramp is thin at its low near end: hold it up under its high half
		local z = if shape == "ramp" then -math.max(math.abs(s.Y), l / 4) else s.Y
		local key = string.format("%.2f,%.2f", s.X, z)
		if not done[key] then
			done[key] = true
			support(ctx, top, s.X, z, under, st)
		end
	end
end

-- ============================================================== trims (all under a top, at most 0.45 past its edge)

-- A slab just under the walking surface and a little wider: a trim lip all round in a single part.
local function lip(ctx, top: CFrame, w: number, l: number, round: boolean, color: Color3, mat: Enum.Material?, out: number?,
	depth: number?, drop: number?): BasePart
	local o, dp, dr = out or 0.3, depth or 0.6, drop or 0.3
	if round then
		return cyl(ctx, w + 2 * o, dp, top * CFrame.new(0, -dr - dp / 2, 0), color, mat)
	end
	return box(ctx, Vector3.new(w + 2 * o, dp, l + 2 * o), top * CFrame.new(0, -dr - dp / 2, 0), color, mat)
end

-- The four sides of a w x l rectangle, `out` past its edge: { frame (X along the side, -Z outward), side length }.
local function faces(top: CFrame, w: number, l: number, out: number): { { any } }
	return {
		{ top * CFrame.new(0, 0, -(l / 2 + out)), w },
		{ top * CFrame.new(0, 0, l / 2 + out) * TURN, w },
		{ top * CFrame.new(w / 2 + out, 0, 0) * CFrame.Angles(0, -math.pi / 2, 0), l },
		{ top * CFrame.new(-(w / 2 + out), 0, 0) * CFrame.Angles(0, math.pi / 2, 0), l },
	}
end

-- `each(frame, i)` at points round the sides (`out` past the edge), about `spacing` apart, at most `per` a side; a
-- disc of diameter w gets them round its rim.
local function around(top: CFrame, w: number, l: number, round: boolean, out: number, spacing: number, per: number,
	each: (CFrame, number) -> ())
	local k = 0
	if round then
		local r = w / 2 + out
		local n = math.clamp(math.floor(2 * math.pi * r / spacing + 0.5), 6, per * 4)
		for i = 1, n do
			k += 1
			each(top * CFrame.Angles(0, 2 * math.pi * (i - 0.5) / n, 0) * CFrame.new(0, 0, -r), k)
		end
		return
	end
	for _, f in faces(top, w, l, out) do
		local n = math.clamp(math.floor(f[2] / spacing + 0.5), 1, per)
		for i = 1, n do
			k += 1
			each(f[1] * CFrame.new(-f[2] / 2 + f[2] * (i - 0.5) / n, 0, 0), k)
		end
	end
end

-- A tent awning: a band of `base` round the sides under the top with stripes of `stripe` over it.
local function awning(ctx, top: CFrame, w: number, l: number, round: boolean, base: Color3, stripe: Color3)
	lip(ctx, top, w, l, round, base, SMOOTH, 0.12, 1.3, 0.25)
	around(top, w, l, round, 0.18, 2.4, 4, function(cf)
		box(ctx, Vector3.new(0.9, 1.3, 0.1), cf * CFrame.new(0, -0.9, 0), stripe)
	end)
end

-- A carousel valance: a band under the edge and a row of scalloped discs hanging from it.
local function valance(ctx, top: CFrame, w: number, l: number, round: boolean, band: Color3, scallop: { Color3 }, size: number?)
	lip(ctx, top, w, l, round, band, SMOOTH, 0.22, 0.8, 0.2)
	local s = size or 2.2
	around(top, w, l, round, 0.3, s, 4, function(cf, i)
		cyl(ctx, s * 0.9, 0.14, cf * CFrame.new(0, -1.05, 0) * FLAT, scallop[(i - 1) % #scallop + 1])
	end)
end

local function corners(top: CFrame, w: number, l: number, out: number): { CFrame }
	return {
		top * CFrame.new(-(w / 2 + out), 0, -(l / 2 + out)), top * CFrame.new(w / 2 + out, 0, -(l / 2 + out)),
		top * CFrame.new(w / 2 + out, 0, l / 2 + out), top * CFrame.new(-(w / 2 + out), 0, l / 2 + out),
	}
end

local function cornerBulbs(ctx, top: CFrame, w: number, l: number, round: boolean, colors: { Color3 }, y: number?)
	if round then
		around(top, w, l, true, 0.3, w, 2, function(cf, i)
			bulb(ctx, cf * CFrame.new(0, y or -0.45, 0), colors[(i - 1) % #colors + 1])
		end)
		return
	end
	for i, cf in corners(top, w, l, 0.3) do
		bulb(ctx, cf * CFrame.new(0, y or -0.45, 0), colors[(i - 1) % #colors + 1])
	end
end

local function edgeBulbs(ctx, top: CFrame, w: number, l: number, round: boolean, spacing: number, colors: { Color3 }, y: number?)
	around(top, w, l, round, 0.38, spacing, 4, function(cf, i)
		bulb(ctx, cf * CFrame.new(0, y or -0.5, 0), colors[(i - 1) % #colors + 1])
	end)
end

-- Yellow and black hazard slashes round a kill slab's sides, under its glowing top.
local function hazardBand(ctx, top: CFrame, w: number, l: number)
	box(ctx, Vector3.new(w + 0.2, 0.7, l + 0.2), top * CFrame.new(0, -0.5, 0), C.soot)
	for _, f in faces(top, w, l, 0.13) do
		local n = math.max(1, math.floor(f[2] / 1.3))
		for i = 1, n do
			box(ctx, Vector3.new(0.85, 0.24, 0.06), f[1] * CFrame.new(-f[2] / 2 + f[2] * (i - 0.5) / n, -0.5, 0) * CFrame.Angles(0, 0, math.rad(45)),
				C.hazard)
		end
	end
end

-- A log lying across the course: end caps and bulbs along its sides at the axis (no lip ring).
local function logTrim(ctx, th, top: CFrame, len: number, d: number)
	local a = th.accent
	for _, s in { -1, 1 } do
		put(ctx, "Part", Enum.PartType.Cylinder, Vector3.new(0.3, d + 0.16, d + 0.16), top * CFrame.new(s * (len / 2 + 0.15), -d / 2, 0), a[1], a[2])
		put(ctx, "Part", Enum.PartType.Cylinder, Vector3.new(0.34, d * 0.55, d * 0.55), top * CFrame.new(s * (len / 2 + 0.17), -d / 2, 0), a[3])
	end
	local n = math.max(2, math.floor(len / 2.8))
	for i = 1, n do
		for _, s in { -1, 1 } do
			bulb(ctx, top * CFrame.new(-len / 2 + len * (i - 0.5) / n, -d / 2, s * (d / 2 + 0.05)), th.bulbs[(i - 1) % #th.bulbs + 1])
		end
	end
end

-- A ramp: bands and bulbs along the slope's sides under it, and two chevrons painted up the slope (no flat lip).
local function rampTrim(ctx, th, top: CFrame, w: number, l: number, h: number, stripe: Color3)
	local len = math.sqrt(l * l + h * h)
	local slope = top * CFrame.new(0, -h / 2, 0) * CFrame.Angles(math.atan2(h, l), 0, 0)
	local a = th.accent
	for _, s in { -1, 1 } do
		box(ctx, Vector3.new(0.2, 0.7, len), slope * CFrame.new(s * (w / 2 + 0.1), -0.45, 0), a[1], a[2])
		local n = math.max(2, math.floor(len / 2.8))
		for i = 1, n do
			bulb(ctx, slope * CFrame.new(s * (w / 2 + 0.32), -0.55, -len / 2 + len * (i - 0.5) / n), th.bulbs[(i - 1) % #th.bulbs + 1])
		end
	end
	local arm = math.clamp(w * 0.3, 0.8, 2)
	for _, z in { -len * 0.18, len * 0.18 } do
		for _, s in { -1, 1 } do
			box(ctx, Vector3.new(0.3, 0.05, arm), slope * CFrame.new(s * arm * 0.32, 0.03, z) * CFrame.Angles(0, math.rad(40 * s), 0), stripe)
		end
	end
	box(ctx, Vector3.new(w + 0.2, 0.5, 0.2), top * CFrame.new(0, -0.4, -l / 2 - 0.1), a[1], a[2])
end

-- ============================================================== props (on brackets, past the margin)

-- A bracket shelf `r` studs in radius just past one side of a walkable (side -1/+1, at z along it), under its top:
-- props stand on it clear of the body space. Returns the plate's top.
local function shelf(ctx, top: CFrame, w: number, side: number, z: number, r: number, color: Color3, mat: Enum.Material?): CFrame
	local base = top * CFrame.new(side * (w / 2 + MARGIN + 0.1 + r), -0.8, z)
	box(ctx, Vector3.new(2 * r + 0.2, 0.2, 2 * r + 0.2), base * CFrame.new(0, -0.1, 0), color, mat)
	rod(ctx, (top * CFrame.new(side * (w / 2 - 0.1), -0.95, z)).Position, (base * CFrame.new(-side * r, -0.12, 0)).Position, 0.22, color, mat)
	return base
end

-- A post of diameter d standing just past one side on an arm under the top, h studs above the top, far enough out for
-- a finial or lamp up to a stud wide on its tip. Returns its tip.
local function post(ctx, top: CFrame, w: number, side: number, z: number, h: number, d: number, color: Color3, mat: Enum.Material?): CFrame
	local x = side * (w / 2 + MARGIN + 0.1 + math.max(d, 1) / 2)
	rod(ctx, (top * CFrame.new(side * (w / 2 - 0.1), -0.75, z)).Position, (top * CFrame.new(x, -0.75, z)).Position, 0.22, color, mat)
	cyl(ctx, d, h + 1.3, top * CFrame.new(x, (h - 1.3) / 2, z), color, mat)
	return top * CFrame.new(x, h, z)
end

-- A bunch of balloons tied at `tie`, floating `rise` studs up on the `out` side, so their strings stay outside.
local function balloons(ctx, tie: Vector3, out: Vector3, n: number, rise: number, colors: { Color3 })
	local across = Vector3.new(-out.Z, 0, out.X)
	for i = 1, n do
		local k = i - (n + 1) / 2
		local at = tie + out * (1.25 + 0.25 * math.abs(k)) + across * (k * 1.15) + Vector3.new(0, rise + ctx.rng:NextNumber(-0.4, 0.4), 0)
		rod(ctx, tie, at - Vector3.new(0, 0.95, 0), 0.07, C.white)
		local b = ball(ctx, 2, CFrame.new(at), colors[(i - 1) % #colors + 1])
		b.Reflectance = 0.12
	end
end

local function lamp(ctx, base: CFrame, height: number, pole: Color3, globe: Color3, lit: boolean?): BasePart
	cyl(ctx, 0.45, height, base * CFrame.new(0, height / 2, 0), pole, METAL)
	local g = ball(ctx, 1.4, base * CFrame.new(0, height + 0.6, 0), globe, NEON)
	cyl(ctx, 1.1, 0.35, base * CFrame.new(0, height + 1.4, 0), pole, METAL)
	if lit then
		light(g, globe, 14, 1)
	end
	return g
end

-- A board with text on its front (-Z) face, in a frame.
local function sign(ctx, cf: CFrame, w: number, h: number, text: string, board: Color3, frame: Color3, ink: Color3, mat: Enum.Material?): BasePart
	box(ctx, Vector3.new(w + 0.6, h + 0.6, 0.3), cf * CFrame.new(0, 0, 0.12), frame, mat or SMOOTH)
	local b = box(ctx, Vector3.new(w, h, 0.3), cf, board, SMOOTH)
	label(b, text, ink)
	return b
end

-- A pennant flying from a pole at `at` (+X = the way it flies): two wedges make an isosceles triangle.
local function pennant(ctx, at: CFrame, len: number, h: number, color: Color3, trim: Color3?)
	local f = at * CFrame.Angles(0, -math.pi / 2, 0)
	wedge(ctx, Vector3.new(0.12, h / 2, len), f * CFrame.new(0, h / 4, len / 2), color)
	wedge(ctx, Vector3.new(0.12, h / 2, len), f * CFrame.new(0, -h / 4, len / 2) * CFrame.Angles(0, 0, math.pi), color)
	if trim then
		box(ctx, Vector3.new(0.16, h, 0.3), at * CFrame.new(0.15, 0, 0), trim)
	end
end

local function popcorn(ctx, base: CFrame, s: number)
	local h = 1.3 * s
	box(ctx, Vector3.new(0.9 * s, h, 0.9 * s), base * CFrame.new(0, h / 2, 0), C.red)
	box(ctx, Vector3.new(0.94 * s, h, 0.3 * s), base * CFrame.new(0, h / 2, 0), C.white)
	box(ctx, Vector3.new(0.3 * s, h, 0.94 * s), base * CFrame.new(0, h / 2, 0), C.white)
	for i = 1, 3 do
		local a = 2 * math.pi * i / 3
		ball(ctx, 0.6 * s, base * CFrame.new(math.cos(a) * 0.22 * s, h + 0.12 * s, math.sin(a) * 0.22 * s), C.cream)
	end
end

local function barrel(ctx, base: CFrame, s: number)
	cyl(ctx, 1.4 * s, 1.8 * s, base * CFrame.new(0, 0.9 * s, 0), C.wood, WOOD)
	for _, y in { 0.35, 1.45 } do
		cyl(ctx, 1.5 * s, 0.18 * s, base * CFrame.new(0, y * s, 0), C.iron, METAL)
	end
end

local function candle(ctx, base: CFrame, h: number, lit: boolean?)
	cyl(ctx, 0.5, h, base * CFrame.new(0, h / 2, 0), C.bone)
	local f = ball(ctx, 0.42, base * CFrame.new(0, h + 0.25, 0), C.orange, NEON)
	if lit then
		light(f, C.orange, 9, 1)
	end
end

local function pumpkin(ctx, base: CFrame, s: number)
	ball(ctx, 1.5 * s, base * CFrame.new(0, 0.7 * s, 0), C.pumpkin)
	cyl(ctx, 0.25 * s, 0.5 * s, base * CFrame.new(0, 1.5 * s, 0), C.leaf)
end

local function tombstone(ctx, base: CFrame, w: number, h: number, text: string?): BasePart
	local slab = box(ctx, Vector3.new(w, h - w / 2, 0.6), base * CFrame.new(0, (h - w / 2) / 2, 0), C.stone, SLATE)
	cyl(ctx, w, 0.6, base * CFrame.new(0, h - w / 2, 0) * FLAT, C.stone, SLATE)
	if text then
		label(slab, text, C.dark, C.stone)
	end
	return slab
end

local function teapot(ctx, base: CFrame, s: number, color: Color3)
	ball(ctx, 2.4 * s, base * CFrame.new(0, 1.2 * s, 0), color)
	cyl(ctx, 1.5 * s, 0.35 * s, base * CFrame.new(0, 2.35 * s, 0), C.gold, METAL)
	ball(ctx, 0.5 * s, base * CFrame.new(0, 2.65 * s, 0), C.gold, METAL)
	rod(ctx, (base * CFrame.new(0, 1.1 * s, -0.9 * s)).Position, (base * CFrame.new(0, 2.1 * s, -2 * s)).Position, 0.45 * s, color)
	rod(ctx, (base * CFrame.new(0, 1.9 * s, 0.9 * s)).Position, (base * CFrame.new(0, 1.7 * s, 1.75 * s)).Position, 0.3 * s, C.gold, METAL)
	rod(ctx, (base * CFrame.new(0, 1.7 * s, 1.75 * s)).Position, (base * CFrame.new(0, 0.9 * s, 1.1 * s)).Position, 0.3 * s, C.gold, METAL)
end

local function rocket(ctx, base: CFrame, s: number, color: Color3)
	cyl(ctx, 1 * s, 3 * s, base * CFrame.new(0, 1.9 * s, 0), color)
	ball(ctx, 1 * s, base * CFrame.new(0, 3.4 * s, 0), C.white)
	for _, a in { 0, 120, 240 } do
		wedge(ctx, Vector3.new(0.15 * s, 1 * s, 0.8 * s), base * CFrame.Angles(0, math.rad(a), 0) * CFrame.new(0, 0.9 * s, 0.75 * s), C.gold)
	end
end

local function cannon(ctx, base: CFrame, s: number)
	cyl(ctx, 1.1 * s, 3.2 * s, base * CFrame.new(0, 1.3 * s, 0) * CFrame.Angles(math.rad(-60), 0, 0), C.iron, METAL)
	for _, x in { -0.75, 0.75 } do
		cyl(ctx, 1.4 * s, 0.25 * s, base * CFrame.new(x * s, 0.7 * s, 0.3 * s) * CFrame.Angles(0, 0, math.rad(90)), C.darkwood, WOOD)
	end
end

local function sparkler(ctx, base: CFrame, color: Color3)
	cyl(ctx, 0.9, 1.2, base * CFrame.new(0, 0.6, 0), C.navy)
	local tip = ball(ctx, 0.6, base * CFrame.new(0, 1.3, 0), color, NEON)
	particles(tip, SPARKLE, color, 14, 9, 0.7, 0.7)
end

local function skullFlag(ctx, base: CFrame, height: number)
	cyl(ctx, 0.3, height, base * CFrame.new(0, height / 2, 0), C.darkwood, WOOD)
	local flag = base * CFrame.new(1.4, height - 1, 0)
	box(ctx, Vector3.new(2.6, 1.7, 0.1), flag, C.dark)
	ball(ctx, 0.6, flag * CFrame.new(0, 0.25, -0.08), C.white)
	box(ctx, Vector3.new(1.3, 0.15, 0.06), flag * CFrame.new(0, -0.35, -0.08) * CFrame.Angles(0, 0, math.rad(30)), C.white)
	box(ctx, Vector3.new(1.3, 0.15, 0.06), flag * CFrame.new(0, -0.35, -0.08) * CFrame.Angles(0, 0, math.rad(-30)), C.white)
end

-- A carousel horse centred at `cf` (facing -Z), s = scale. Returns its body.
local function horse(ctx, cf: CFrame, s: number, color: Color3, mane: Color3): BasePart
	local body = cyl(ctx, 1.3 * s, 2.6 * s, cf * FLAT, color)
	local function at(x, y, z): Vector3
		return (cf * CFrame.new(x * s, y * s, z * s)).Position
	end
	rod(ctx, at(0, 0.3, -1.1), at(0, 1.5, -1.8), 0.75 * s, color)
	box(ctx, Vector3.new(0.65, 0.75, 1.5) * s, cf * CFrame.new(0, 1.75 * s, -2.35 * s) * CFrame.Angles(math.rad(-25), 0, 0), color)
	rod(ctx, at(0, 0.75, -0.9), at(0, 1.95, -1.75), 0.32 * s, mane)
	for _, x in { -0.3, 0.3 } do
		rod(ctx, at(x, -0.3, -0.9), at(x, -0.6, -1.9), 0.3 * s, color)
		rod(ctx, at(x, -0.3, 0.95), at(x, -1.55, 1.35), 0.3 * s, color)
	end
	rod(ctx, at(0, 0.2, 1.25), at(0, -0.85, 1.95), 0.3 * s, mane)
	box(ctx, Vector3.new(1.2, 0.25, 1) * s, cf * CFrame.new(0, 0.62 * s, 0.05 * s), C.red)
	return body
end

-- A horse riding a brass pole at `cf` (the pole's foot under a top): the pole bobs it on `host`.
local function poleHorse(ctx, host: BasePart, cf: CFrame, color: Color3, phase: number)
	group(ctx, "Horse", function()
		local saved = ctx.host
		local weld = ctx.weld
		ctx.weld = false
		local pole = cyl(ctx, 0.35, 9.6, cf * CFrame.new(0, 4.8, 0), C.gold, METAL)
		ctx.host, ctx.weld = pole, true
		ball(ctx, 0.7, cf * CFrame.new(0, 9.7, 0), C.gold, METAL)
		horse(ctx, cf * CFrame.new(0, 3.6, 0), 0.85, color, C.gold)
		ctx.host, ctx.weld = saved, weld
		bob(ctx, pole, host, 0.6, 2.4, phase)
	end)
end

-- A ring canopy over horses: scalloped panels on a circle of radius r at height y over `top`.
local function crown(ctx, top: CFrame, r: number, y: number, colors: { Color3 })
	local n = math.clamp(math.floor(2 * math.pi * r / 2.2), 8, 16)
	for i = 1, n do
		local cf = top * CFrame.Angles(0, 2 * math.pi * (i - 0.5) / n, 0) * CFrame.new(0, y, -r)
		box(ctx, Vector3.new(2 * math.pi * r / n + 0.1, 0.9, 0.2), cf, colors[(i - 1) % #colors + 1])
		cyl(ctx, 1.1, 0.12, cf * CFrame.new(0, -0.5, -0.05) * FLAT, colors[i % #colors + 1])
	end
end

-- ============================================================== themes
-- Every theme: accent { colour, material, inner } and bulbs for generic trims; edge(ctx, top, w, l, round) round any still
-- walkable; arch(ctx, top, w) over the checkpoint; legs { spots(w, l), leg(ctx, a, b), bracket(ctx, a) } (optional);
-- per kind (optional): platform (side props), moving(ctx, host, top, w, l), spinBase(ctx, top, d), spinBar(ctx, bar),
-- turntable(ctx, disc, top, d), tile(ctx, top, w, l, i), jumppad / trampoline / conveyor (ctx, top, w, l, part),
-- pendulum(ctx, parts), lava(ctx, slab, top, w, l), pennant colours, decor (stageDecor colours).

local FUN = { C.red, C.yellow, C.sky, C.pink, C.mint }
local PASTEL = { C.blush, C.lilac, C.pmint, C.psky }
local LIGHTS = { C.warm, C.yellow, C.pink, C.sky, C.mint }
local NEONS = { C.magenta, C.gold, C.lime, C.purple }

-- Posts either side of a checkpoint pad (clear of its body space) and a beam across, above head height: returns the
-- beam's top centre.
local function arch(ctx, top: CFrame, w: number, height: number, post: Color3, postMat: Enum.Material, beam: Color3,
	beamMat: Enum.Material, d: number?): CFrame
	local r = (d or 0.8) / 2
	local x = w / 2 + MARGIN + 0.15 + r
	for _, s in { -1, 1 } do
		cyl(ctx, 2 * r, height + 1.5, top * CFrame.new(s * x, (height - 1.5) / 2, 0), post, postMat)
	end
	box(ctx, Vector3.new(2 * x + 2 * r + 0.4, 1.2, 1), top * CFrame.new(0, height, 0), beam, beamMat)
	return top * CFrame.new(0, height + 0.6, 0)
end

local function bulbRow(ctx, a: Vector3, b: Vector3, n: number, colors: { Color3 })
	for i = 0, n - 1 do
		bulb(ctx, CFrame.new(a:Lerp(b, if n == 1 then 0.5 else i / (n - 1))), colors[i % #colors + 1])
	end
end

local function sideOf(ctx): number
	return pick(ctx, { -1, 1 })
end

local T = {}

-- ---------------------------------------------------------------- entrance: striped tents, popcorn, balloons
T.entrance = {
	accent = { C.red, SMOOTH, C.cream }, bulbs = { C.warm, C.yellow }, pennant = { C.red, C.yellow },
	decor = { pole = C.gold, globe = C.warm, wire = C.dark, bulbs = { C.warm, C.red, C.yellow }, board = C.red, frame = C.gold,
		ink = C.white, balloons = FUN },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.gold, METAL, 0.3, 0.2, 0.1)
		awning(ctx, top, w, l, round, C.cream, C.red)
		cornerBulbs(ctx, top, w, l, round, { C.warm })
	end,
	platform = function(ctx, top, w, l)
		local r, side = ctx.rng:NextNumber(), sideOf(ctx)
		if r < 0.35 then
			group(ctx, "Popcorn", function()
				popcorn(ctx, shelf(ctx, top, w, side, 0, 0.65, C.gold, METAL), 1.1)
			end)
		elseif r < 0.7 then
			group(ctx, "Balloons", function()
				local tip = post(ctx, top, w, side, 0, 4.2, 0.3, C.white)
				balloons(ctx, tip.Position, top.RightVector * side, 3, 2.4, FUN)
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.25, 0.25, 0.1)
		box(ctx, Vector3.new(w - 0.2, 1.6, l - 0.2), top * CFrame.new(0, -1.25, 0), C.wood, WOOD)
		awning(ctx, top, w, l, false, C.cream, C.red)
		group(ctx, "Balloon", function()
			local knot = top * CFrame.new(0, 10, 0)
			for _, cf in corners(top, w, l, MARGIN + 0.2) do
				local up = (cf * CFrame.new(0, 7.4, 0)).Position
				rod(ctx, (cf * CFrame.new(0, -0.6, 0)).Position, up, 0.09, C.rope)
				rod(ctx, up, knot.Position, 0.09, C.rope)
			end
			for i = 1, 5 do
				local a = 2 * math.pi * i / 5
				ball(ctx, 2.4, knot * CFrame.new(math.cos(a) * 1.3, 1.6 + (i % 2) * 0.8, math.sin(a) * 1.3), FUN[i])
			end
			ball(ctx, 2.5, knot * CFrame.new(0, 3.2, 0), C.white)
		end)
	end,
	spinBase = function(ctx, top, d)
		T.entrance.edge(ctx, top, d, d, true)
	end,
	spinBar = function(ctx, bar)
		group(ctx, "Popcorn", function()
			popcorn(ctx, bar.CFrame * CFrame.new(0, 0.5, 0), 1.3)
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.gold, METAL, 0.3, 0.3, 0.1)
		awning(ctx, top, d, d, true, C.cream, C.red)
		edgeBulbs(ctx, top, d, d, true, 3.2, { C.warm })
	end,
	tile = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.2, 0.35, 0.12)
		local ticket = box(ctx, Vector3.new(w - 0.8, 0.05, math.min(l - 0.8, 2.2)), top * CFrame.new(0, 0.025, 0), C.cream)
		label(ticket, "ADMIT ONE", C.purple, C.cream, Enum.NormalId.Top)
		cornerBulbs(ctx, top, w, l, false, { C.warm }, -0.4)
	end,
	jumppad = function(ctx, top, w, l, part)
		T.entrance.edge(ctx, top, w, l, false)
		particles(part, SPARKLE, C.cream, 5, 12, 0.8, 0.7)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.35, 0.5, 0.2)
		awning(ctx, top, w, l, false, C.cream, C.red)
	end,
	conveyor = function(ctx, top, w, l)
		T.entrance.edge(ctx, top, w, l, false)
		for _, side in { -1, 1 } do
			group(ctx, "Queue", function()
				local tips = {}
				for _, z in { -l / 2 + 1, 0, l / 2 - 1 } do
					table.insert(tips, post(ctx, top, w, side, z, 2.4, 0.3, C.gold, METAL).Position)
					ball(ctx, 0.5, CFrame.new(tips[#tips] + Vector3.new(0, 0.1, 0)), C.gold, METAL)
				end
				for i = 1, #tips - 1 do
					local mid = (tips[i] + tips[i + 1]) / 2 - Vector3.new(0, 0.5, 0)
					rod(ctx, tips[i], mid, 0.2, C.navy)
					rod(ctx, mid, tips[i + 1], 0.2, C.navy)
				end
			end)
		end
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.gold)
		end
		own(parts.beam, "Color", C.red)
		on(ctx, parts.ball, true)
		group(ctx, "Rings", function()
			cyl(ctx, 4.25, 0.6, parts.ball.CFrame, C.gold, METAL)
			cyl(ctx, 4.1, 0.25, parts.ball.CFrame * CFrame.new(0, 0.9, 0), C.white)
			cyl(ctx, 4.1, 0.25, parts.ball.CFrame * CFrame.new(0, -0.9, 0), C.white)
		end)
	end,
	arch = function(ctx, top, w)
		local at = arch(ctx, top, w, 10, C.red, SMOOTH, C.red, SMOOTH, 1)
		local x = w / 2 + MARGIN + 0.65
		for _, s in { -1, 1 } do
			for _, y in { 1.5, 4, 6.5 } do
				cyl(ctx, 1.15, 0.6, top * CFrame.new(s * x, y, 0), C.cream)
			end
			group(ctx, "Balloons", function()
				balloons(ctx, (at * CFrame.new(s * (x + 0.5), 0, 0)).Position, top.RightVector * s, 3, 2.6, FUN)
			end)
		end
		bulbRow(ctx, (at * CFrame.new(-x, -0.6, -0.6)).Position, (at * CFrame.new(x, -0.6, -0.6)).Position, 6, { C.warm, C.yellow })
	end,
}

-- ---------------------------------------------------------------- carousel: brass poles, horses, scalloped valance
T.carousel = {
	accent = { C.gold, METAL, C.pink }, bulbs = { C.warm }, pennant = { C.pink, C.gold },
	decor = { pole = C.gold, globe = C.warm, wire = C.gold, bulbs = { C.warm, C.pink }, board = C.pink, frame = C.gold,
		ink = C.white, balloons = { C.pink, C.mint, C.white } },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.gold, METAL, 0.32, 0.2, 0.1)
		valance(ctx, top, w, l, round, C.pink, { C.cream, C.gold })
		cornerBulbs(ctx, top, w, l, round, { C.warm }, -0.55)
	end,
	platform = function(ctx, top, w, l)
		if ctx.rng:NextNumber() < 0.55 then
			local side = sideOf(ctx)
			group(ctx, "Pole", function()
				local tip = post(ctx, top, w, side, 0, 5.4, 0.4, C.gold, METAL)
				ball(ctx, 0.8, tip * CFrame.new(0, 0.3, 0), C.gold, METAL)
				pennant(ctx, tip * CFrame.new(0, -0.8, 0) * (if side > 0 then CFrame.new() else TURN), 2, 1.3, C.pink)
			end)
		end
	end,
	moving = function(ctx, host, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.32, 0.2, 0.1)
		valance(ctx, top, w, l, false, C.pink, { C.cream, C.gold })
		for k, side in { -1, 1 } do
			local x = side * (w / 2 + MARGIN + 0.85)
			poleHorse(ctx, host, top * CFrame.new(x, -1.3, 0), pick(ctx, { C.white, C.cream, C.psky, C.blush }), k * 0.5)
		end
	end,
	spinBase = function(ctx, top, d)
		T.carousel.edge(ctx, top, d, d, true)
	end,
	spinBar = function(ctx, bar)
		group(ctx, "Crown", function()
			cyl(ctx, 0.5, 2.6, bar.CFrame * CFrame.new(0, 1.3, 0), C.gold, METAL)
			cyl(ctx, 3, 0.4, bar.CFrame * CFrame.new(0, 2.7, 0), C.pink)
			cyl(ctx, 2, 0.4, bar.CFrame * CFrame.new(0, 3.1, 0), C.cream)
			ball(ctx, 0.7, bar.CFrame * CFrame.new(0, 3.6, 0), C.gold, METAL)
		end)
	end,
	turntable = function(ctx, disc, top, d)
		lip(ctx, top, d, d, true, C.gold, METAL, 0.3, 0.3, 0.1)
		valance(ctx, top, d, d, true, C.pink, { C.cream, C.gold })
		local r = d / 2 + MARGIN + 0.85
		for k, a in { 0, 90, 180, 270 } do
			local cf = top * CFrame.Angles(0, math.rad(a), 0) * CFrame.new(0, -1.3, -r) * CFrame.Angles(0, math.rad(90), 0)
			if k % 2 == 1 then
				poleHorse(ctx, disc, cf, if k == 1 then C.white else C.psky, k * 0.25)
			else
				group(ctx, "Pole", function()
					cyl(ctx, 0.35, 9.6, cf * CFrame.new(0, 4.8, 0), C.gold, METAL)
					ball(ctx, 0.7, cf * CFrame.new(0, 9.7, 0), C.gold, METAL)
				end)
			end
		end
		group(ctx, "Crown", function()
			crown(ctx, top, r, 8.6, { C.pink, C.cream })
		end)
	end,
	tile = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.25, 0.4, 0.15)
		box(ctx, Vector3.new(0.6, 0.05, 0.6), top * CFrame.new(0, 0.025, 0) * CFrame.Angles(0, math.rad(45), 0), C.pink)
		cornerBulbs(ctx, top, w, l, false, { C.warm }, -0.45)
	end,
	jumppad = function(ctx, top, w, l, part)
		T.carousel.edge(ctx, top, w, l, false)
		particles(part, SPARKLE, C.pink, 5, 12, 0.8, 0.7)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.35, 0.5, 0.2)
		valance(ctx, top, w, l, false, C.pink, { C.cream, C.gold })
	end,
	conveyor = function(ctx, top, w, l)
		T.carousel.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.gold)
		end
		own(parts.beam, "Color", C.pink)
		if parts.beam then
			local cf = parts.beam.CFrame
			group(ctx, "Valance", function()
				around(cf * CFrame.new(0, -0.4, 0), parts.beam.Size.X, 0.8, false, 0.12, 1.8, 6, function(f, i)
					cyl(ctx, 1.5, 0.12, f * CFrame.new(0, -0.5, 0) * FLAT, if i % 2 == 0 then C.pink else C.cream)
				end)
			end)
		end
		on(ctx, parts.ball, true)
		group(ctx, "Rings", function()
			cyl(ctx, 4.25, 0.5, parts.ball.CFrame, C.gold, METAL)
		end)
	end,
	arch = function(ctx, top, w)
		local x = w / 2 + MARGIN + 0.5
		for _, s in { -1, 1 } do
			cyl(ctx, 0.6, 11.5, top * CFrame.new(s * x, 4.75, 0), C.gold, METAL)
			ball(ctx, 1, top * CFrame.new(s * x, 10.7, 0), C.gold, METAL)
		end
		local roof = top * CFrame.new(0, 10.4, 0)
		box(ctx, Vector3.new(2 * x + 1.6, 0.6, 3), roof, C.pink)
		box(ctx, Vector3.new(2 * x + 0.4, 0.6, 2), roof * CFrame.new(0, 0.6, 0), C.cream)
		around(roof, 2 * x + 1.6, 3, false, 0.05, 1.8, 7, function(f, i)
			cyl(ctx, 1.4, 0.12, f * CFrame.new(0, -0.75, 0) * FLAT, if i % 2 == 0 then C.pink else C.cream)
		end)
		edgeBulbs(ctx, roof * CFrame.new(0, -0.3, 0), 2 * x + 1.6, 3, false, 2.2, { C.warm }, 0)
	end,
}

-- ---------------------------------------------------------------- bumper: rubber, diamond plate, hazard yellow, sparks
local CARS = { C.yellow, C.purple, C.sky, C.pink, C.mint, C.orange }

local function rubberEdge(ctx, top: CFrame, w: number, l: number, y: number, d: number, out: number)
	local hw, hl = w / 2 + out, l / 2 + out
	for _, e in { { -hw, -hl, hw, -hl }, { hw, -hl, hw, hl }, { hw, hl, -hw, hl }, { -hw, hl, -hw, -hl } } do
		rod(ctx, (top * CFrame.new(e[1], y, e[2])).Position, (top * CFrame.new(e[3], y, e[4])).Position, d, C.rubber, RUBBER)
	end
end

local function bollard(ctx, base: CFrame)
	cyl(ctx, 0.7, 2.6, base * CFrame.new(0, 1.3, 0), C.hazard)
	cyl(ctx, 0.74, 0.4, base * CFrame.new(0, 1.6, 0), C.soot)
	ball(ctx, 0.75, base * CFrame.new(0, 2.8, 0), C.cyan, NEON)
end

T.bumper = {
	accent = { C.hazard, SMOOTH, C.soot }, bulbs = { C.cyan, C.hazard }, pennant = { C.hazard, C.soot },
	decor = { pole = C.steel, globe = C.cyan, wire = C.dark, bulbs = { C.cyan, C.hazard }, board = C.navy, frame = C.hazard,
		ink = C.hazard },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.hazard, SMOOTH, 0.18, 0.35, 0.1)
		if round then
			lip(ctx, top, w, l, true, C.rubber, RUBBER, 0.45, 0.9, 0.8)
		else
			rubberEdge(ctx, top, w, l, -1.25, 0.9, 0.2)
		end
		edgeBulbs(ctx, top, w, l, round, 3, { C.cyan, C.hazard }, -0.6)
	end,
	platform = function(ctx, top, w, l)
		if ctx.rng:NextNumber() < 0.6 then
			local side = sideOf(ctx)
			group(ctx, "Bollard", function()
				bollard(ctx, shelf(ctx, top, w, side, l / 2 - 1, 0.4, C.soot, METAL))
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		local color = pick(ctx, CARS)
		local shell = box(ctx, Vector3.new(w + 0.1, 1.4, l + 0.1), top * CFrame.new(0, -0.82, 0), color)
		shell.Reflectance = 0.15
		box(ctx, Vector3.new(w + 0.16, 0.18, l + 0.16), top * CFrame.new(0, -0.2, 0), C.white)
		rubberEdge(ctx, top, w, l, -1.75, 0.85, 0.15)
		for _, x in { -w * 0.3, w * 0.3 } do
			bulb(ctx, top * CFrame.new(x, -0.8, -l / 2 - 0.12), C.warm, 0.6)
		end
		group(ctx, "Seat", function()
			local back = top * CFrame.new(0, 0, l / 2 + MARGIN + 0.4)
			box(ctx, Vector3.new(w * 0.7, 3, 0.6), back * CFrame.new(0, 0.5, 0), color)
			box(ctx, Vector3.new(w * 0.7, 0.6, 0.9), back * CFrame.new(0, -1.1, -0.2), color)
			rod(ctx, (back * CFrame.new(0, 2, 0.1)).Position, (back * CFrame.new(0, 9, 0.1)).Position, 0.22, C.steel, METAL)
			local spark = ball(ctx, 0.7, back * CFrame.new(0, 9.1, 0.1), C.cyan, NEON)
			particles(spark, SPARKLE, C.cyan, 6, 6, 0.4, 0.6)
		end)
	end,
	spinBase = function(ctx, top, d)
		T.bumper.edge(ctx, top, d, d, true)
		for k = 0, 3 do
			box(ctx, Vector3.new(0.9, 0.05, d * 0.3), top * CFrame.Angles(0, k * math.pi / 2 + math.pi / 4, 0) * CFrame.new(0, 0.025, -d * 0.32), C.hazard)
		end
	end,
	spinBar = function(ctx, bar)
		local half = bar.Size.X / 2
		group(ctx, "Tips", function()
			for _, s in { -1, 1 } do
				local tip = ball(ctx, 1.2, bar.CFrame * CFrame.new(s * (half - 0.4), 0, 0), C.hazard, NEON)
				particles(tip, SPARKLE, C.white, 8, 8, 0.4, 0.6)
			end
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.hazard, SMOOTH, 0.18, 0.35, 0.1)
		lip(ctx, top, d, d, true, C.rubber, RUBBER, 0.45, 0.9, 0.8)
		edgeBulbs(ctx, top, d, d, true, 3, { C.cyan, C.hazard }, -0.6)
	end,
	tile = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.soot, SMOOTH, 0.15, 0.3, 0.1)
		rubberEdge(ctx, top, w, l, -1.05, 0.6, 0.1)
	end,
	jumppad = function(ctx, top, w, l, part)
		T.bumper.edge(ctx, top, w, l, false)
		particles(part, SPARKLE, C.white, 6, 10, 0.5, 0.7)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.hazard, SMOOTH, 0.18, 0.35, 0.1)
		lip(ctx, top, w, l, false, C.rubber, RUBBER, 0.45, 1.2, 0.8)
	end,
	conveyor = function(ctx, top, w, l)
		T.bumper.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.hazard)
		end
		own(parts.beam, "Color", C.soot)
		on(ctx, parts.ball, true)
		group(ctx, "Bumper", function()
			cyl(ctx, 4.6, 1, parts.ball.CFrame * FLAT, C.rubber, RUBBER)
			particles(parts.ball, SPARKLE, C.white, 8, 6, 0.4, 0.6)
		end)
	end,
	arch = function(ctx, top, w)
		local at = arch(ctx, top, w, 9.5, C.hazard, SMOOTH, C.rubber, RUBBER, 1)
		local b = box(ctx, Vector3.new(w - 1, 1.5, 0.3), at * CFrame.new(0, 0.75, 0) * TURN, C.hazard)
		label(b, "BUMPER CARS", C.navy, C.hazard)
		bulbRow(ctx, (at * CFrame.new(-w / 2 + 0.4, 1.75, 0)).Position, (at * CFrame.new(w / 2 - 0.4, 1.75, 0)).Position, 6, { C.cyan, C.hazard })
	end,
}

-- ---------------------------------------------------------------- teacups: porcelain, pastel, gold rims, lace
-- A cup body under a w x l top: a round cup for a square top, a stadium-shaped one for a long top (never wider than
-- the top by more than 0.2 a side).
local function cupBody(ctx, top: CFrame, w: number, l: number, color: Color3, round: boolean?)
	local s, long = math.min(w, l), math.max(w, l)
	local along = if w >= l then top * CFrame.Angles(0, math.pi / 2, 0) else top
	cyl(ctx, s + 0.4, 1.9, top * CFrame.new(0, -1.2, 0), color)
	cyl(ctx, s * 0.75, 1.3, top * CFrame.new(0, -2.6, 0), color)
	if long - s > 0.5 then
		box(ctx, Vector3.new(s + 0.4, 1.9, long - s), along * CFrame.new(0, -1.2, 0), color)
		for _, e in { -1, 1 } do
			cyl(ctx, s + 0.4, 1.9, along * CFrame.new(0, -1.2, e * (long - s) / 2), color)
		end
	end
	if round then
		cyl(ctx, w + 0.3, 0.3, top * CFrame.new(0, -0.45, 0), C.gold, METAL)
	else
		box(ctx, Vector3.new(w + 0.3, 0.3, l + 0.3), top * CFrame.new(0, -0.45, 0), C.gold, METAL)
	end
	cyl(ctx, s + 2.4, 0.35, top * CFrame.new(0, -3.4, 0), C.porcelain)
	cyl(ctx, s + 2.6, 0.15, top * CFrame.new(0, -3.55, 0), C.gold, METAL)
end

T.teacups = {
	accent = { C.gold, METAL, C.porcelain }, bulbs = { C.blush, C.lilac }, pennant = { C.lilac, C.gold },
	decor = { pole = C.gold, globe = C.blush, wire = C.gold, bulbs = PASTEL, board = C.porcelain, frame = C.gold, ink = C.purple,
		balloons = PASTEL },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.gold, METAL, 0.3, 0.18, 0.08)
		valance(ctx, top, w, l, round, pick(ctx, PASTEL), { C.white }, 1.8)
	end,
	platform = function(ctx, top, w, l)
		local r, side = ctx.rng:NextNumber(), sideOf(ctx)
		if r < 0.4 then
			group(ctx, "Teapot", function()
				teapot(ctx, shelf(ctx, top, w, side, 0, 1.1, C.gold, METAL), 0.65, pick(ctx, PASTEL))
			end)
		elseif r < 0.7 then
			group(ctx, "Sugar", function()
				local base = shelf(ctx, top, w, side, 0, 0.75, C.gold, METAL)
				box(ctx, Vector3.new(1.1, 1.1, 1.1), base * CFrame.new(0, 0.55, 0) * CFrame.Angles(0, 0.3, 0), C.white)
				box(ctx, Vector3.new(0.9, 0.9, 0.9), base * CFrame.new(0.1, 1.55, 0) * CFrame.Angles(0, 0.9, 0), C.white)
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		local color = pick(ctx, PASTEL)
		cupBody(ctx, top, w, l, color)
		local h = top * CFrame.new(w / 2 + 0.2, -1.3, 0)
		rod(ctx, (h * CFrame.new(0, 0.55, 0)).Position, (h * CFrame.new(0.9, 0.55, 0)).Position, 0.38, color)
		rod(ctx, (h * CFrame.new(0.9, 0.55, 0)).Position, (h * CFrame.new(0.9, -0.55, 0)).Position, 0.38, color)
		rod(ctx, (h * CFrame.new(0.9, -0.55, 0)).Position, (h * CFrame.new(0, -0.55, 0)).Position, 0.38, color)
		if math.abs(w - l) < 0.5 then
			for k = 0, 3 do
				cyl(ctx, 0.8, 0.1, top * CFrame.Angles(0, k * math.pi / 2 + 0.4, 0) * CFrame.new(0, -1.3, -(w / 2 + 0.22)) * FLAT, C.white)
			end
		end
	end,
	spinBase = function(ctx, top, d)
		lip(ctx, top, d, d, true, C.gold, METAL, 0.3, 0.18, 0.08)
		cupBody(ctx, top, d, d, pick(ctx, PASTEL), true)
	end,
	spinBar = function(ctx, bar)
		local cf = bar.CFrame
		group(ctx, "Spoon", function()
			rod(ctx, (cf * CFrame.new(0, 0.3, 0)).Position, (cf * CFrame.new(1.2, 5.5, 0)).Position, 0.5, C.steel, METAL)
			cyl(ctx, 1.6, 0.35, cf * CFrame.new(1.45, 6.6, 0) * CFrame.Angles(0, 0, math.rad(-12)) * FLAT, C.steel, METAL)
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.gold, METAL, 0.3, 0.18, 0.08)
		cupBody(ctx, top, d, d, pick(ctx, PASTEL), true)
		cyl(ctx, d * 0.45, 0.05, top * CFrame.new(0, 0.025, 0), C.gold, METAL)
		cyl(ctx, d * 0.4, 0.06, top * CFrame.new(0, 0.03, 0), C.porcelain)
	end,
	tile = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.gold, METAL, 0.15, 0.2, 0.1)
		local c = pick(ctx, PASTEL)
		local d = math.min(w, l)
		cyl(ctx, d, 0.5, top * CFrame.new(0, -1.25, 0), c)
		cyl(ctx, d * 0.9, 0.3, top * CFrame.new(0, -1.65, 0), C.cream)
	end,
	jumppad = function(ctx, top, w, l, part)
		T.teacups.edge(ctx, top, w, l, false)
		particles(part, SMOKE, C.white, 5, 8, 1.4, 1.6)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, pick(ctx, PASTEL), SMOOTH, 0.35, 0.9, 0.2)
		for _, cf in corners(top, w, l, 0.2) do
			ball(ctx, 0.7, cf * CFrame.new(0, -1.4, 0), C.gold, METAL)
		end
	end,
	conveyor = function(ctx, top, w, l)
		T.teacups.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.gold)
		end
		own(parts.beam, "Color", C.lilac)
		local ballPart = parts.ball
		on(ctx, ballPart, true)
		group(ctx, "Teapot", function()
			local cf = ballPart.CFrame
			cyl(ctx, 2.6, 0.5, cf * CFrame.new(0, 2.05, 0), C.gold, METAL)
			ball(ctx, 0.9, cf * CFrame.new(0, 2.6, 0), C.gold, METAL)
			rod(ctx, (cf * CFrame.new(-1.6, -0.2, 0)).Position, (cf * CFrame.new(-3, 1.4, 0)).Position, 0.8, C.porcelain)
			rod(ctx, (cf * CFrame.new(1.7, 1, 0)).Position, (cf * CFrame.new(2.7, 0.4, 0)).Position, 0.45, C.gold, METAL)
			rod(ctx, (cf * CFrame.new(2.7, 0.4, 0)).Position, (cf * CFrame.new(1.8, -0.9, 0)).Position, 0.45, C.gold, METAL)
		end)
	end,
	arch = function(ctx, top, w)
		local at = arch(ctx, top, w, 9, C.blush, SMOOTH, C.lilac, SMOOTH, 1)
		box(ctx, Vector3.new(w + 3, 0.3, 1.1), at * CFrame.new(0, -0.15, 0), C.gold, METAL)
		teapot(ctx, at, 1.1, C.blush)
	end,
}

-- ---------------------------------------------------------------- ferris: white steel, gondolas, rainbow bulbs, spokes
local GONDOLAS = { C.purple, C.gold, C.blush, C.lilac }

local function spokes(ctx, top: CFrame, d: number, n: number, colors: { Color3 })
	for k = 0, n - 1 do
		box(ctx, Vector3.new(0.35, 0.05, d / 2 - 1.2), top * CFrame.Angles(0, k * 2 * math.pi / n, 0) * CFrame.new(0, 0.025, -(d / 4 + 0.6)),
			colors[k % #colors + 1])
	end
	cyl(ctx, 2.2, 0.06, top * CFrame.new(0, 0.03, 0), C.gold, METAL)
end

T.ferris = {
	accent = { C.white, SMOOTH, C.purple }, bulbs = LIGHTS, pennant = { C.purple, C.yellow },
	decor = { pole = C.white, globe = C.warm, wire = C.dark, bulbs = LIGHTS, board = C.purple, frame = C.white, ink = C.white },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.white, SMOOTH, 0.25, 0.45, 0.2)
		lip(ctx, top, w, l, round, pick(ctx, GONDOLAS), SMOOTH, 0.12, 0.9, 0.62)
		edgeBulbs(ctx, top, w, l, round, 2.6, LIGHTS, -0.45)
		if not round and l >= 4 then
			for _, sx in { -1, 1 } do
				box(ctx, Vector3.new(0.5, 0.5, l), top * CFrame.new(sx * (w / 2 - 0.6), -1.4, 0), C.steel, METAL)
			end
			rod(ctx, (top * CFrame.new(-w / 2 + 0.6, -1.4, -l / 2 + 0.3)).Position, (top * CFrame.new(w / 2 - 0.6, -1.4, l / 2 - 0.3)).Position, 0.3, C.steel, METAL)
			rod(ctx, (top * CFrame.new(w / 2 - 0.6, -1.4, -l / 2 + 0.3)).Position, (top * CFrame.new(-w / 2 + 0.6, -1.4, l / 2 - 0.3)).Position, 0.3, C.steel, METAL)
		end
	end,
	platform = function(ctx, top, w, l)
		if ctx.rng:NextNumber() < 0.4 then
			group(ctx, "Wheel", function()
				local tip = post(ctx, top, w, sideOf(ctx), 0, 4.2, 0.35, C.white, METAL)
				local f = CFrame.new(tip.Position) * top.Rotation * CFrame.Angles(0, math.pi / 2, 0)
				for i = 0, 5 do
					local a = 2 * math.pi * i / 6
					bulb(ctx, f * CFrame.new(math.cos(a) * 1.2, math.sin(a) * 1.2, 0), LIGHTS[i % #LIGHTS + 1], 0.5)
				end
				cyl(ctx, 0.6, 0.4, f * FLAT, C.gold, METAL)
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		local color = pick(ctx, GONDOLAS)
		box(ctx, Vector3.new(w - 0.1, 1.7, l - 0.1), top * CFrame.new(0, -1.15, 0), color)
		lip(ctx, top, w, l, false, C.white, SMOOTH, 0.22, 0.35, 0.2)
		group(ctx, "Hanger", function()
			local x = w / 2 + MARGIN + 0.25
			for _, s in { -1, 1 } do
				rod(ctx, (top * CFrame.new(s * (w / 2 - 0.1), -1.6, 0)).Position, (top * CFrame.new(s * x, -1.6, 0)).Position, 0.3, C.white, METAL)
				rod(ctx, (top * CFrame.new(s * x, -1.7, 0)).Position, (top * CFrame.new(s * x, 8.4, 0)).Position, 0.3, C.white, METAL)
				bulb(ctx, top * CFrame.new(s * x, 8.5, 0), C.warm, 0.6)
			end
			rod(ctx, (top * CFrame.new(-x, 8.4, 0)).Position, (top * CFrame.new(x, 8.4, 0)).Position, 0.35, C.white, METAL)
			cyl(ctx, 0.9, 1.6, top * CFrame.new(0, 8.4, 0) * FLAT, C.steel, METAL)
		end)
	end,
	spinBase = function(ctx, top, d)
		T.ferris.edge(ctx, top, d, d, true)
		spokes(ctx, top, d, 6, { C.purple })
	end,
	spinBar = function(ctx, bar)
		local half = bar.Size.X / 2
		group(ctx, "Lights", function()
			for i = -2, 2 do
				bulb(ctx, bar.CFrame * CFrame.new(i * (half - 0.8) / 2, 0.6, 0), LIGHTS[i + 3], 0.6)
			end
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		T.ferris.edge(ctx, top, d, d, true)
		spokes(ctx, top, d, 8, { C.purple, C.sky })
	end,
	tile = function(ctx, top, w, l, i)
		local color = ({ C.purple, C.gold, C.blush, C.lilac })[i % 4 + 1]
		box(ctx, Vector3.new(w - 0.2, 1.4, l - 0.2), top * CFrame.new(0, -1, 0), color)
		lip(ctx, top, w, l, false, C.white, SMOOTH, 0.2, 0.3, 0.12)
		cornerBulbs(ctx, top, w, l, false, LIGHTS, -0.5)
	end,
	jumppad = function(ctx, top, w, l, part)
		T.ferris.edge(ctx, top, w, l, false)
		particles(part, SPARKLE, C.warm, 5, 12, 0.8, 0.7)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.white, SMOOTH, 0.3, 0.5, 0.2)
		edgeBulbs(ctx, top, w, l, false, 2.6, LIGHTS, -0.5)
	end,
	conveyor = function(ctx, top, w, l)
		T.ferris.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.white)
		end
		own(parts.beam, "Color", C.white)
		if parts.beam then
			group(ctx, "Lights", function()
				around(parts.beam.CFrame * CFrame.new(0, 0.4, 0), parts.beam.Size.X, 0.8, false, 0.1, 1.8, 8, function(f, i)
					bulb(ctx, f, LIGHTS[(i - 1) % #LIGHTS + 1])
				end)
			end)
		end
		on(ctx, parts.ball, true)
		group(ctx, "Ring", function()
			cyl(ctx, 4.3, 0.5, parts.ball.CFrame * FLAT, C.white, METAL)
		end)
	end,
	arch = function(ctx, top, w)
		-- a spoked half wheel over the pad, above head height
		local r = w / 2 + MARGIN + 0.7
		local hub = top * CFrame.new(0, 8.4, 0)
		for _, s in { -1, 1 } do
			cyl(ctx, 0.8, 9.9, top * CFrame.new(s * r, 3.45, 0), C.white, METAL)
		end
		local prev
		for i = 0, 8 do
			local a = math.pi * i / 8
			local p = (hub * CFrame.new(-math.cos(a) * r, math.sin(a) * r * 0.75, 0)).Position
			if prev then
				rod(ctx, prev, p, 0.6, C.purple, METAL)
			end
			if i > 0 and i < 8 then
				rod(ctx, hub.Position, p, 0.22, C.white, METAL)
			end
			bulb(ctx, CFrame.new(p), LIGHTS[i % #LIGHTS + 1], 0.9)
			prev = p
		end
		cyl(ctx, 1.2, 0.6, hub * FLAT, C.gold, METAL)
	end,
}

-- ---------------------------------------------------------------- flume: planks, pilings, white water, lily pads
local function piling(ctx, a: Vector3, b: Vector3)
	rod(ctx, a, b, 0.85, C.wood, WOOD)
	cyl(ctx, 0.95, 0.3, CFrame.new(a:Lerp(b, 0.4)), C.rope)
	if (a - b).Magnitude > 6 then
		cyl(ctx, 1.1, 0.4, CFrame.new(b + Vector3.new(0, 0.2, 0)), C.darkwood, WOOD)
	end
end

local function flumeBracket(ctx, a: Vector3)
	rod(ctx, a, a - Vector3.new(0, 1.2, 0), 0.85, C.wood, WOOD)
	cyl(ctx, 0.95, 0.25, CFrame.new(a - Vector3.new(0, 1.2, 0)), C.darkwood, WOOD)
end

T.flume = {
	accent = { C.darkwood, PLANKS, C.plank }, bulbs = { C.warm }, pennant = { C.deep, C.foam },
	decor = { pole = C.darkwood, globe = C.warm, wire = C.rope, bulbs = { C.warm }, board = C.wood, frame = C.darkwood, ink = C.cream,
		mat = PLANKS },
	legs = { spots = function(w, l)
		return { Vector2.new(-w / 2 + 0.55, -l / 2 + 0.55), Vector2.new(w / 2 - 0.55, l / 2 - 0.55) }
	end, leg = piling, bracket = flumeBracket },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.darkwood, PLANKS, 0.3, 0.5, 0.15)
		cornerBulbs(ctx, top, w, l, round, { C.warm }, -0.6)
	end,
	platform = function(ctx, top, w, l)
		local r, side = ctx.rng:NextNumber(), sideOf(ctx)
		if r < 0.4 then
			group(ctx, "Barrel", function()
				barrel(ctx, shelf(ctx, top, w, side, 0, 0.7, C.darkwood, WOOD), 0.75)
			end)
		elseif r < 0.7 then
			group(ctx, "Torch", function()
				local tip = post(ctx, top, w, side, 0, 3.2, 0.35, C.darkwood, WOOD)
				local f = ball(ctx, 0.7, tip * CFrame.new(0, 0.35, 0), C.orange, NEON)
				light(f, C.orange, 12, 1)
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		local n = math.max(3, math.floor(w / 1.5 + 0.5))
		local d = w / n
		for i = 1, n do
			local x = -w / 2 + d * (i - 0.5)
			cyl(ctx, d * 1.02, l + 0.8, top * CFrame.new(x, -d / 2 - 0.15, 0) * FLAT, if i % 2 == 0 then C.wood else C.darkwood, WOOD)
		end
		for _, z in { -l / 3, l / 3 } do
			box(ctx, Vector3.new(w + 0.15, d + 0.1, 0.3), top * CFrame.new(0, -d / 2 - 0.15, z), C.rope)
		end
		local back = box(ctx, Vector3.new(w * 0.8, 0.3, 0.3), top * CFrame.new(0, -1.2, l / 2 + 0.3), C.foam)
		particles(back, SPARKLE, C.foam, 8, 4, 0.6, 0.8)
	end,
	spinBase = function(ctx, top, d)
		T.flume.edge(ctx, top, d, d, true)
	end,
	spinBar = function(ctx, bar)
		local half = bar.Size.X / 2
		group(ctx, "Paddles", function()
			for _, s in { -1, 1 } do
				box(ctx, Vector3.new(1.6, 1.8, 0.3), bar.CFrame * CFrame.new(s * (half - 1.1), 0.3, 0), C.wood, PLANKS)
			end
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.darkwood, PLANKS, 0.3, 0.5, 0.15)
		for k = 0, 2 do
			box(ctx, Vector3.new(0.5, 0.05, d * 0.36), top * CFrame.Angles(0, k * 2 * math.pi / 3, 0) * CFrame.new(d * 0.12, 0.025, -d * 0.2)
				* CFrame.Angles(0, math.rad(35), 0), C.foam)
		end
		edgeBulbs(ctx, top, d, d, true, 3.4, { C.warm }, -0.6)
	end,
	tile = function(ctx, top, w, l)
		local d = math.min(w, l) + 0.5
		cyl(ctx, d, 0.3, top * CFrame.new(0, -0.7, 0), C.lily)
		wedge(ctx, Vector3.new(0.4, 0.32, d * 0.4), top * CFrame.new(0, -0.69, -d * 0.32), C.moss)
		ball(ctx, 0.8, top * CFrame.new(w * 0.32, -0.5, l * 0.32), C.pink)
		ball(ctx, 0.45, top * CFrame.new(w * 0.32, -0.2, l * 0.32), C.yellow, NEON)
	end,
	jumppad = function(ctx, top, w, l, part)
		lip(ctx, top, w, l, false, C.stone, SLATE, 0.3, 0.8, 0.2)
		around(top, w, l, false, 0.45, 2.6, 4, function(cf, i)
			if i % 2 == 1 then
				local d = ctx.rng:NextNumber(0.9, 1.3)
				ball(ctx, d, cf * CFrame.new(0, -0.75 - d / 2, 0), C.stone, SLATE)
			end
		end)
		particles(part, SPARKLE, C.foam, 12, 18, 0.7, 1)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.white, SMOOTH, 0.4, 0.8, 0.15)
		for _, f in faces(top, w, l, 0.42) do
			box(ctx, Vector3.new(1.4, 0.82, 0.12), f[1] * CFrame.new(0, -0.56, 0), C.deep)
		end
	end,
	conveyor = function(ctx, top, w, l, belt)
		box(ctx, Vector3.new(w + 0.5, 2.2, l + 0.2), top * CFrame.new(0, -1.25, 0), C.wood, PLANKS)
		lip(ctx, top, w, l, false, C.darkwood, PLANKS, 0.4, 0.35, 0.12)
		local spray = box(ctx, Vector3.new(w * 0.8, 0.2, 0.2), top * CFrame.new(0, -0.3, -l / 2 - 0.15), C.foam)
		particles(spray, SPARKLE, C.foam, 10, 7, 0.7, 0.9)
		particles(belt, SPARKLE, C.foam, 4, 2, 0.6, 0.5)
	end,
	pendulum = function(ctx, parts)
		own(parts.rod, "Color", C.rope)
		for _, p in parts.posts do
			own(p, "Color", C.wood)
			own(p, "Material", WOOD)
		end
		own(parts.beam, "Color", C.darkwood)
		own(parts.beam, "Material", WOOD)
		on(ctx, parts.ball, true)
		group(ctx, "Log", function()
			local cf = parts.ball.CFrame
			cyl(ctx, 4.4, 5, cf * FLAT, C.wood, WOOD)
			for _, z in { -2.51, 2.51 } do
				cyl(ctx, 3.6, 0.05, cf * CFrame.new(0, 0, z) * FLAT, C.plank)
			end
		end)
	end,
	lava = function(ctx, slab)
		particles(slab, SMOKE, C.white, 3, 3, 1.6, 1.4)
	end,
	arch = function(ctx, top, w)
		-- the sign hangs from the beam on two ropes, its bottom above head height; both rope ends are placed in the
		-- pad's own frame, so each rope stays on its side
		arch(ctx, top, w, 11.5, C.wood, WOOD, C.darkwood, PLANKS, 1)
		sign(ctx, top * CFrame.new(0, 8.75, -0.2) * TURN, 6, 1.8, "SPLASH!", C.wood, C.darkwood, C.cream, PLANKS)
		for _, s in { -1, 1 } do
			rod(ctx, (top * CFrame.new(s * 2.6, 10.9, -0.2)).Position, (top * CFrame.new(s * 2.6, 9.95, -0.2)).Position, 0.15, C.rope)
		end
	end,
}

-- ---------------------------------------------------------------- haunted: crypt stone, ghost glow, tombstones
local function ghost(ctx, cf: CFrame, s: number)
	local body = cyl(ctx, 1.7 * s, 1.6 * s, cf * CFrame.new(0, 0.8 * s, 0), C.white)
	local head = ball(ctx, 1.7 * s, cf * CFrame.new(0, 1.65 * s, 0), C.white)
	body.Transparency, head.Transparency = 0.12, 0.12
	for _, x in { -0.32, 0.32 } do
		ball(ctx, 0.36 * s, cf * CFrame.new(x * s, 1.85 * s, 0.72 * s), C.dark)
	end
end

local function deadTree(ctx, base: CFrame, h: number)
	local at = function(x, y, z)
		return (base * CFrame.new(x, y, z)).Position
	end
	rod(ctx, at(0, -0.3, 0), at(0.2, h, 0), 0.55, C.darkwood, WOOD)
	rod(ctx, at(0.1, h * 0.55, 0), at(0.9, h * 0.85, 0.3), 0.3, C.darkwood, WOOD)
	rod(ctx, at(0.15, h * 0.7, 0), at(-0.7, h * 1.05, -0.3), 0.28, C.darkwood, WOOD)
end

-- Haunted pieces float (no legs) over a purple glow: a ghost ride in the air.
T.haunted = {
	accent = { C.slate, SLATE, C.glow }, bulbs = { C.orange, C.glow }, pennant = { C.glow, C.dark },
	decor = { pole = C.iron, globe = C.ghost, wire = C.iron, bulbs = { C.orange, C.glow }, board = C.slate, frame = C.darkwood,
		ink = C.ghost },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.slate, SLATE, 0.3, 0.6, 0.2)
		if round then
			cyl(ctx, w * 0.7, 0.2, top * CFrame.new(0, -1.3, 0), C.glow, NEON)
		else
			box(ctx, Vector3.new(w * 0.75, 0.2, l * 0.75), top * CFrame.new(0, -1.3, 0), C.glow, NEON)
			for _ = 1, 2 do
				wedge(ctx, Vector3.new(0.25, 1.4, 0.9), top * CFrame.new(sideOf(ctx) * (w / 2 + 0.33), -1.5, ctx.rng:NextNumber(-l / 3, l / 3))
					* CFrame.Angles(math.rad(180), 0, 0), C.moss)
			end
		end
	end,
	platform = function(ctx, top, w, l)
		local r, side = ctx.rng:NextNumber(), sideOf(ctx)
		if r < 0.25 then
			group(ctx, "Candles", function()
				local base = shelf(ctx, top, w, side, 0, 0.9, C.slate, SLATE)
				candle(ctx, base * CFrame.new(0, 0, -0.3), 1.6, true)
				candle(ctx, base * CFrame.new(0.3, 0, 0.4), 1)
				pumpkin(ctx, base * CFrame.new(-0.35, 0, 0.2), 0.6)
			end)
		elseif r < 0.5 then
			group(ctx, "Ghost", function()
				ghost(ctx, top * CFrame.new(side * (w / 2 + MARGIN + 1.8), 0.8, ctx.rng:NextNumber(-l / 4, l / 4)) * CFrame.Angles(0, -side * math.pi / 2, 0), 1.2)
			end)
		elseif r < 0.75 then
			group(ctx, "Tree", function()
				deadTree(ctx, shelf(ctx, top, w, side, 0, 1, C.slate, SLATE) * (if side > 0 then CFrame.new() else TURN), 4.5)
			end)
		else
			group(ctx, "Grave", function()
				local base = shelf(ctx, top, w, side, 0, 1.1, C.slate, SLATE)
				tombstone(ctx, base * CFrame.Angles(0, side * math.pi / 2, 0), 1.8, 2.8, "RIP")
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		box(ctx, Vector3.new(w - 0.3, 1.4, l - 0.3), top * CFrame.new(0, -1.1, 0), C.darkwood, WOOD)
		lip(ctx, top, w, l, false, C.crypt, WOOD, 0.25, 0.35, 0.15)
		for _, sx in { -1, 1 } do
			local face = top * CFrame.new(sx * (w / 2 - 0.1), -1.05, -l * 0.12)
			box(ctx, Vector3.new(0.12, 1.1, 0.28), face, C.gold, METAL)
			box(ctx, Vector3.new(0.12, 0.28, 0.9), face * CFrame.new(0, 0.18, 0), C.gold, METAL)
		end
		box(ctx, Vector3.new(0.5, 0.05, l * 0.5), top * CFrame.new(0, 0.025, -l * 0.12), C.gold, METAL)
		box(ctx, Vector3.new(w * 0.45, 0.05, 0.5), top * CFrame.new(0, 0.026, -l * 0.22), C.gold, METAL)
		local glow = box(ctx, Vector3.new(w * 0.8, 0.2, l * 0.8), top * CFrame.new(0, -1.9, 0), C.ghost, NEON)
		particles(glow, SMOKE, C.ghost, 3, 1, 1.6, 1.4)
	end,
	spinBase = function(ctx, top, d)
		T.haunted.edge(ctx, top, d, d, true)
	end,
	spinBar = function(ctx, bar)
		local half = bar.Size.X / 2
		group(ctx, "Scythe", function()
			wedge(ctx, Vector3.new(0.3, 2.2, 2.6), bar.CFrame * CFrame.new(half - 0.6, 1, -0.9), C.steel, METAL)
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.slate, SLATE, 0.3, 0.6, 0.2)
		cyl(ctx, d * 0.6, 0.2, top * CFrame.new(0, -1.3, 0), C.glow, NEON)
		for k = 0, 7 do
			box(ctx, Vector3.new(0.3, 0.05, d * 0.22), top * CFrame.Angles(0, k * math.pi / 4, 0) * CFrame.new(0, 0.025, -d * 0.33), C.glow, NEON)
		end
		for _, a in { 45, 225 } do
			group(ctx, "Grave", function()
				tombstone(ctx, top * CFrame.Angles(0, math.rad(a), 0) * CFrame.new(0, -0.5, -(d / 2 + MARGIN + 0.45)) * TURN, 1.6, 2.6, "RIP")
			end)
		end
	end,
	tile = function(ctx, top, w, l, i)
		lip(ctx, top, w, l, false, C.darkwood, WOOD, 0.2, 0.4, 0.15)
		box(ctx, Vector3.new(w * 0.7, 0.2, l * 0.7), top * CFrame.new(0, -1.2, 0), C.glow, NEON)
		local side = if i % 2 == 0 then 1 else -1
		group(ctx, "Grave", function()
			tombstone(ctx, top * CFrame.new(side * (w / 2 + MARGIN + 0.45), -0.6, 0) * CFrame.Angles(0, side * math.pi / 2, 0), 1.8, 3.2, "RIP")
		end)
		box(ctx, Vector3.new(0.12, 0.05, l * 0.6), top * CFrame.new(w * 0.1, 0.025, 0) * CFrame.Angles(0, math.rad(20), 0), C.dark)
	end,
	jumppad = function(ctx, top, w, l, part)
		lip(ctx, top, w, l, false, C.slate, SLATE, 0.3, 0.6, 0.2)
		box(ctx, Vector3.new(w * 0.8, 0.2, l * 0.8), top * CFrame.new(0, -1.25, 0), C.ghost, NEON)
		group(ctx, "Candles", function()
			local base = shelf(ctx, top, w, sideOf(ctx), l / 2 - 0.9, 0.6, C.slate, SLATE)
			candle(ctx, base, 1.4, true)
		end)
		particles(part, SMOKE, C.ghost, 5, 9, 1.2, 1.6)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.slate, SLATE, 0.35, 0.8, 0.2)
		for _, a in { 0, 45, 90, 135 } do
			box(ctx, Vector3.new(0.12, 0.05, math.min(w, l) - 0.4), top * CFrame.new(0, 0.03, 0) * CFrame.Angles(0, math.rad(a), 0), C.white)
		end
	end,
	conveyor = function(ctx, top, w, l, belt)
		T.haunted.edge(ctx, top, w, l, false)
		particles(belt, SMOKE, C.ghost, 3, 1, 2, 2)
	end,
	pendulum = function(ctx, parts)
		own(parts.rod, "Color", C.darkwood)
		for _, p in parts.posts do
			own(p, "Color", C.iron)
		end
		own(parts.beam, "Color", C.darkwood)
		if parts.beam then
			local cf = parts.beam.CFrame
			group(ctx, "Lantern", function()
				rod(ctx, (cf * CFrame.new(parts.beam.Size.X / 2 - 0.4, -0.4, 0)).Position, (cf * CFrame.new(parts.beam.Size.X / 2 - 0.4, -1.4, 0)).Position, 0.1, C.iron)
				local lantern = box(ctx, Vector3.new(0.8, 1.1, 0.8), cf * CFrame.new(parts.beam.Size.X / 2 - 0.4, -1.9, 0), C.orange, NEON)
				light(lantern, C.orange, 12, 1)
			end)
		end
		on(ctx, parts.ball, true)
		group(ctx, "Blade", function()
			cyl(ctx, 5.6, 0.35, parts.ball.CFrame * FLAT, C.steel, METAL)
			cyl(ctx, 4.6, 0.42, parts.ball.CFrame * FLAT, C.slate, METAL)
		end)
	end,
	lava = function(ctx, slab)
		particles(slab, SMOKE, C.glow, 3, 2, 1.6, 1.4)
	end,
	arch = function(ctx, top, w)
		local x = w / 2 + MARGIN + 0.85
		for _, s in { -1, 1 } do
			box(ctx, Vector3.new(1.4, 9, 1.4), top * CFrame.new(s * x, 3.5, 0), C.stone, SLATE)
			box(ctx, Vector3.new(1.8, 0.6, 1.8), top * CFrame.new(s * x, 8.3, 0), C.slate, SLATE)
			ball(ctx, 0.9, top * CFrame.new(s * x, 9, 0), C.stone, SLATE)
		end
		local prev
		for i = 0, 4 do
			local a = math.pi * i / 4
			local p = (top * CFrame.new(-math.cos(a) * x, 8.3 + math.sin(a) * 2.2, 0)).Position
			if prev then
				rod(ctx, prev, p, 0.25, C.iron, METAL)
			end
			prev = p
		end
		local hook0 = top * CFrame.new(0, 10.5, 0)
		rod(ctx, hook0.Position, (hook0 * CFrame.new(0, -1.3, 0)).Position, 0.1, C.iron)
		local lantern = box(ctx, Vector3.new(0.9, 1.2, 0.9), hook0 * CFrame.new(0, -1.9, 0), C.orange, NEON)
		light(lantern, C.orange, 16, 1.2)
	end,
}

-- ---------------------------------------------------------------- pirate: deck planks, docks, boats, skull flags
local function dockPile(ctx, a: Vector3, b: Vector3)
	rod(ctx, a, b, 0.9, C.darkwood, WOOD)
	cyl(ctx, 1, 0.35, CFrame.new(a:Lerp(b, 0.15)), C.rope)
end

local function hull(ctx, top: CFrame, w: number, l: number, h: number, color: Color3)
	local flip = CFrame.Angles(math.rad(180), 0, 0)
	wedge(ctx, Vector3.new(l, h, w / 2), top * CFrame.new(-w / 4, -0.4 - h / 2, 0) * CFrame.Angles(0, math.rad(-90), 0) * flip, color, WOOD)
	wedge(ctx, Vector3.new(l, h, w / 2), top * CFrame.new(w / 4, -0.4 - h / 2, 0) * CFrame.Angles(0, math.rad(90), 0) * flip, color, WOOD)
end

T.pirate = {
	accent = { C.darkwood, PLANKS, C.gold }, bulbs = { C.warm }, pennant = { C.dark, C.white },
	decor = { pole = C.darkwood, globe = C.warm, wire = C.rope, bulbs = { C.warm }, board = C.wood, frame = C.darkwood, ink = C.gold,
		mat = PLANKS },
	legs = { spots = function(w, l)
		return { Vector2.new(-w / 2 + 0.6, 0), Vector2.new(w / 2 - 0.6, 0) }
	end, leg = dockPile },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.darkwood, PLANKS, 0.3, 0.55, 0.2)
		cornerBulbs(ctx, top, w, l, round, { C.warm }, -0.65)
	end,
	platform = function(ctx, top, w, l)
		local r, side = ctx.rng:NextNumber(), sideOf(ctx)
		if r < 0.35 then
			group(ctx, "Barrel", function()
				barrel(ctx, shelf(ctx, top, w, side, 0, 0.75, C.darkwood, WOOD), 0.8)
			end)
		elseif r < 0.6 then
			group(ctx, "Cannon", function()
				local base = shelf(ctx, top, w, side, 0, 1.3, C.darkwood, WOOD)
				cannon(ctx, base * CFrame.Angles(0, if side > 0 then -math.pi / 2 else math.pi / 2, 0), 0.8)
			end)
		elseif r < 0.8 then
			group(ctx, "Chest", function()
				local base = shelf(ctx, top, w, side, 0, 0.9, C.darkwood, WOOD)
				box(ctx, Vector3.new(1.6, 1, 1.1), base * CFrame.new(0, 0.5, 0), C.darkwood, WOOD)
				cyl(ctx, 1.1, 1.6, base * CFrame.new(0, 1, 0) * CFrame.Angles(0, 0, math.rad(90)), C.wood, WOOD)
				box(ctx, Vector3.new(1.64, 0.22, 1.14), base * CFrame.new(0, 0.85, 0), C.gold, METAL)
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		lip(ctx, top, w, l, false, C.darkwood, PLANKS, 0.3, 0.5, 0.2)
		hull(ctx, top, w, l, math.min(3, w * 0.45), C.red)
		wedge(ctx, Vector3.new(w * 0.8, 1.2, 2.4), top * CFrame.new(0, -1.45, -(l / 2 + 1.1)) * TURN * CFrame.Angles(math.pi, 0, 0), C.red, WOOD)
		for _, s in { -1, 1 } do
			rod(ctx, (top * CFrame.new(s * (w / 2), -0.5, 0)).Position, (top * CFrame.new(s * (w / 2 + 2.2), -1.9, 0.6)).Position, 0.22, C.wood, WOOD)
		end
		group(ctx, "Prow", function()
			local p = top * CFrame.new(0, 0, -(l / 2 + MARGIN + 0.4))
			rod(ctx, (p * CFrame.new(0, -1.6, 0.3)).Position, (p * CFrame.new(0, 2.4, -0.4)).Position, 0.45, C.gold, WOOD)
			ball(ctx, 0.9, p * CFrame.new(0, 2.6, -0.45), C.gold, METAL)
		end)
		group(ctx, "Mast", function()
			skullFlag(ctx, top * CFrame.new(0, -0.8, l / 2 + MARGIN + 0.5), 8)
		end)
	end,
	spinBase = function(ctx, top, d)
		lip(ctx, top, d, d, true, C.darkwood, PLANKS, 0.3, 0.55, 0.2)
		for k = 0, 7 do
			local cf = top * CFrame.Angles(0, k * math.pi / 4, 0) * CFrame.new(0, -1.1, -(d / 2 + 0.9))
			cyl(ctx, 0.5, 1.8, cf * FLAT, C.wood, WOOD)
			ball(ctx, 0.75, cf * CFrame.new(0, 0, -0.9), C.darkwood, WOOD)
		end
	end,
	spinBar = function(ctx, bar)
		group(ctx, "Ropes", function()
			for _, x in { -0.3, 0.3 } do
				cyl(ctx, 1.25, 0.3, bar.CFrame * CFrame.new(x * bar.Size.X, 0, 0) * CFrame.Angles(0, 0, math.rad(90)), C.rope)
			end
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.darkwood, PLANKS, 0.3, 0.55, 0.2)
		for k = 0, 7 do
			box(ctx, Vector3.new(0.5, 0.05, d / 2 - 1), top * CFrame.Angles(0, k * math.pi / 4, 0) * CFrame.new(0, 0.025, -(d / 4 + 0.5)), C.gold, METAL)
			local cf = top * CFrame.Angles(0, k * math.pi / 4, 0) * CFrame.new(0, -1.1, -(d / 2 + 0.9))
			cyl(ctx, 0.5, 1.8, cf * FLAT, C.wood, WOOD)
			ball(ctx, 0.75, cf * CFrame.new(0, 0, -0.9), C.darkwood, WOOD)
		end
		cyl(ctx, 1.6, 0.07, top * CFrame.new(0, 0.035, 0), C.gold, METAL)
	end,
	tile = function(ctx, top, w, l)
		box(ctx, Vector3.new(w - 0.1, 1.6, l - 0.1), top * CFrame.new(0, -1.1, 0), C.wood, PLANKS)
		lip(ctx, top, w, l, false, C.iron, METAL, 0.12, 0.25, 0.08)
		for _, f in faces(top, w, l, 0.02) do
			box(ctx, Vector3.new(0.3, math.sqrt(f[2] ^ 2 + 2.56) - 0.4, 0.1), f[1] * CFrame.new(0, -1.1, 0) * CFrame.Angles(0, 0, math.atan2(f[2], 1.6)),
				C.darkwood, WOOD)
		end
	end,
	jumppad = function(ctx, top, w, l, part)
		lip(ctx, top, w, l, false, C.darkwood, PLANKS, 0.3, 0.55, 0.2)
		local side = sideOf(ctx)
		group(ctx, "Cannon", function()
			local base = shelf(ctx, top, w, side, 0, 1.4, C.darkwood, WOOD)
			cannon(ctx, base * CFrame.Angles(0, if side > 0 then -math.pi / 2 else math.pi / 2, 0), 0.9)
		end)
		particles(part, SMOKE, C.white, 4, 6, 1.2, 1.4)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.sail, SMOOTH, 0.35, 0.7, 0.15)
		box(ctx, Vector3.new(w + 0.72, 0.25, 1), top * CFrame.new(0, -0.55, 0), C.navy)
	end,
	conveyor = function(ctx, top, w, l)
		T.pirate.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		own(parts.rod, "Color", C.rope)
		for _, p in parts.posts do
			own(p, "Color", C.wood)
			own(p, "Material", WOOD)
		end
		own(parts.beam, "Color", C.wood)
		own(parts.beam, "Material", WOOD)
		if parts.beam then
			local b = parts.beam
			group(ctx, "Sail", function()
				cyl(ctx, 1.2, b.Size.X - 1, b.CFrame * CFrame.new(0, -0.9, 0) * CFrame.Angles(0, 0, math.rad(90)), C.sail)
				skullFlag(ctx, b.CFrame * CFrame.new(-b.Size.X / 2 + 0.4, 0.4, 0), 4)
			end)
		end
		on(ctx, parts.ball, true)
		group(ctx, "Anchor", function()
			local cf = parts.ball.CFrame
			local function at(x, y): Vector3
				return (cf * CFrame.new(x, y, 0)).Position
			end
			cyl(ctx, 0.8, 5.4, cf * CFrame.new(0, 2.9, 0), C.iron, METAL)
			cyl(ctx, 0.55, 3.6, cf * CFrame.new(0, 4.6, 0) * FLAT, C.iron, METAL)
			for _, s in { -1, 1 } do
				rod(ctx, at(0, -1.6), at(s * 1.9, -1.2), 0.75, C.iron, METAL)
				rod(ctx, at(s * 1.9, -1.2), at(s * 2.7, 0.6), 0.7, C.iron, METAL)
			end
		end)
	end,
	arch = function(ctx, top, w)
		local at = arch(ctx, top, w, 10, C.wood, WOOD, C.darkwood, WOOD, 1)
		cyl(ctx, 1.1, w + 1, at * CFrame.new(0, -1.6, 0) * CFrame.Angles(0, 0, math.rad(90)), C.sail)
		skullFlag(ctx, at * CFrame.new(-w / 2 - 1, -0.3, 0), 4)
	end,
}

-- ---------------------------------------------------------------- coaster: navy steel, red rails, white columns
local function column(ctx, a: Vector3, b: Vector3)
	rod(ctx, a, b, 0.9, C.white, METAL)
	box(ctx, Vector3.new(1.6, 0.3, 1.6), CFrame.new(b + Vector3.new(0, 0.15, 0)), C.steel, METAL)
	box(ctx, Vector3.new(1.4, 0.3, 1.4), CFrame.new(a - Vector3.new(0, 0.15, 0)), C.track, METAL)
end

local function truss(ctx, a: Vector3)
	box(ctx, Vector3.new(1.2, 0.5, 1.2), CFrame.new(a - Vector3.new(0, 0.25, 0)), C.track, METAL)
	rod(ctx, a - Vector3.new(0, 0.5, 0), a - Vector3.new(0, 1.6, 0), 0.6, C.white, METAL)
end

local function trackEdges(ctx, top: CFrame, w: number, l: number)
	for _, s in { -1, 1 } do
		box(ctx, Vector3.new(0.4, 0.4, l + 0.6), top * CFrame.new(s * (w / 2 + 0.2), -0.45, 0), C.track, METAL)
		box(ctx, Vector3.new(0.12, 0.05, l - 0.4), top * CFrame.new(s * (w / 2 - 0.35), 0.025, 0), C.hazard)
	end
	for _, z in { -l / 3, l / 3 } do
		box(ctx, Vector3.new(w + 0.9, 0.35, 0.6), top * CFrame.new(0, -0.95, z), C.dark)
	end
end

-- A roller-coaster cart under a mover's top, its nose along its travel (lowered: it never reads as floor).
local function coasterCart(ctx, top: CFrame, w: number, l: number, color: Color3)
	local mv = ctx.params and ctx.params.move
	local v = if type(mv) == "table" then Vector3.new(tonumber(mv[1]) or 0, 0, -(tonumber(mv[3]) or 0)) else Vector3.zero
	local axis = if v.Magnitude < 0.5 then Vector3.new(0, 0, -1) else v.Unit
	local cf = top * CFrame.lookAt(Vector3.zero, axis)
	local alongX = math.abs(axis.X) > math.abs(axis.Z)
	local along = if alongX then w else l
	local across = if alongX then l else w
	local body = box(ctx, Vector3.new(across, 1.5, along), cf * CFrame.new(0, -0.95, 0), color)
	body.Reflectance = 0.15
	box(ctx, Vector3.new(across + 0.1, 0.3, along + 0.02), cf * CFrame.new(0, -0.35, 0), C.yellow)
	wedge(ctx, Vector3.new(across, 1, 1.4), cf * CFrame.new(0, -1.3, -(along / 2 + 0.7)), color)
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			cyl(ctx, 0.95, 0.5, cf * CFrame.new(sx * (across / 2 - 0.15), -1.9, sz * (along / 2 - 0.9)) * CFrame.Angles(0, 0, math.rad(90)), C.dark, METAL)
		end
		bulb(ctx, cf * CFrame.new(sx * across * 0.3, -1.2, -(along / 2 + 0.9)), C.warm, 0.5)
	end
	group(ctx, "Seat", function()
		box(ctx, Vector3.new(across - 0.4, 2.6, 0.6), cf * CFrame.new(0, 0.3, along / 2 + MARGIN + 0.4), color)
	end)
end

-- Two steel rails and ties under a mover's whole path (anchored: the cart runs on them), on columns.
local function coasterTrack(ctx, mover: BasePart, w: number, l: number)
	local rest = mover:GetAttribute("Rest")
	local mv = mover:GetAttribute("Move")
	if typeof(rest) ~= "CFrame" or typeof(mv) ~= "Vector3" then
		return
	end
	local move = rest:VectorToWorldSpace(Vector3.new(mv.X, mv.Y, -mv.Z))
	local base = rest * CFrame.new(0, -mover.Size.Y / 2, 0)
	local a, b = base.Position, base.Position + move
	local horizontal = Vector3.new(move.X, 0, move.Z)
	if horizontal.Magnitude < 0.5 then
		group(ctx, "Lift", function()
			for _, sx in { -1, 1 } do
				local x = base.RightVector * sx * (w / 2 - 0.4) + base.LookVector * -(l / 2 + MARGIN + 0.35)
				rod(ctx, a + x - Vector3.new(0, 3, 0), b + x + Vector3.new(0, 3, 0), 0.4, C.track, METAL)
			end
		end)
		return
	end
	local dir = horizontal.Unit
	local side = dir:Cross(Vector3.yAxis).Unit
	local across = if math.abs(base.RightVector:Dot(dir)) > 0.7 then l else w
	local y = Vector3.new(0, mover.Size.Y - 2.55, 0)
	local ext = dir * ((if across == l then w else l) / 2 + 0.4)
	group(ctx, "Track", function()
		for _, s in { -1, 1 } do
			local off = side * s * (across / 2 - 0.15) + y
			rod(ctx, a - ext + off, b + ext + off, 0.35, C.track, METAL)
		end
		local len = (b - a).Magnitude + 2 * ext.Magnitude
		local n = math.max(2, math.floor(len / 3))
		for i = 0, n do
			local p = (a - ext):Lerp(b + ext, i / n) + y - Vector3.new(0, 0.3, 0)
			box(ctx, Vector3.new(across + 0.6, 0.3, 0.5), CFrame.lookAt(p, p + side) * CFrame.Angles(0, math.rad(90), 0), C.dark)
		end
	end)
	for _, p in { a - ext * 0.5, b + ext * 0.5 } do
		local foot = p + y - Vector3.new(0, 0.5, 0)
		local depth = groundBelow(ctx, foot)
		if depth and depth > 1.5 then
			group(ctx, "Leg", function()
				column(ctx, foot, foot - Vector3.new(0, depth, 0))
			end)
		end
	end
end

T.coaster = {
	accent = { C.track, METAL, C.steel }, bulbs = { C.warm, C.yellow }, pennant = { C.track, C.white },
	decor = { pole = C.steel, globe = C.warm, wire = C.dark, bulbs = { C.warm, C.yellow, C.white }, board = C.navy, frame = C.steel,
		ink = C.yellow },
	legs = { spots = function(w, l)
		if l >= 10 then
			return { Vector2.new(0, -l / 4), Vector2.new(0, l / 4) }
		end
		return { Vector2.new(0, 0) }
	end, leg = column, bracket = truss },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.steel, METAL, 0.25, 0.5, 0.2)
		if not round then
			trackEdges(ctx, top, w, l)
		end
	end,
	platform = function(ctx, top, w, l)
		if ctx.rng:NextNumber() < 0.45 then
			group(ctx, "Signal", function()
				local tip = post(ctx, top, w, sideOf(ctx), -l / 2 + 1, 3.6, 0.3, C.dark, METAL)
				box(ctx, Vector3.new(0.8, 1.7, 0.6), tip * CFrame.new(0, 0.5, 0), C.dark)
				bulb(ctx, tip * CFrame.new(0, 0.95, 0.32), C.ghost, 0.45)
				bulb(ctx, tip * CFrame.new(0, 0.1, 0.32), C.dark, 0.45)
			end)
		end
	end,
	moving = function(ctx, host, top, w, l)
		coasterCart(ctx, top, w, l, pick(ctx, { C.sky, C.yellow, C.purple, C.white }))
		on(ctx, nil, false)
		coasterTrack(ctx, host, w, l)
		on(ctx, host)
	end,
	spinBase = function(ctx, top, d)
		lip(ctx, top, d, d, true, C.steel, METAL, 0.25, 0.5, 0.2)
		lip(ctx, top, d, d, true, C.track, METAL, 0.3, 0.3, 0.8)
	end,
	spinBar = function(ctx, bar)
		local half = bar.Size.X / 2
		group(ctx, "Cart", function()
			local cf = bar.CFrame * CFrame.new(half - 1.6, 1.1, 0) * CFrame.Angles(0, math.rad(90), 0)
			local body = box(ctx, Vector3.new(1.6, 1.2, 2.4), cf, C.yellow)
			body.Reflectance = 0.15
			wedge(ctx, Vector3.new(1.6, 1.2, 1.1), cf * CFrame.new(0, 0, -1.75), C.yellow)
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.steel, METAL, 0.25, 0.5, 0.2)
		for _, s in { -1, 1 } do
			box(ctx, Vector3.new(0.35, 0.05, d - 1), top * CFrame.new(s * 1.6, 0.025, 0), C.track, METAL)
		end
		for _, z in { -d / 4, 0, d / 4 } do
			box(ctx, Vector3.new(4.4, 0.04, 0.5), top * CFrame.new(0, 0.02, z), C.dark)
		end
	end,
	tile = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.steel, METAL, 0.2, 0.4, 0.15)
		trackEdges(ctx, top, w, l)
	end,
	jumppad = function(ctx, top, w, l, part)
		lip(ctx, top, w, l, false, C.steel, METAL, 0.25, 0.5, 0.2)
		trackEdges(ctx, top, w, l)
		for _, s in { -1, 1 } do
			for i = 0, 2 do
				bulb(ctx, top * CFrame.new(s * (w / 2 + 0.25), -0.15, l / 2 - 0.8 - i * (l - 1.6) / 2), C.cyan, 0.5)
			end
		end
		particles(part, SPARKLE, C.cyan, 6, 14, 0.5, 0.7)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.steel, METAL, 0.25, 0.5, 0.2)
		for _, cf in corners(top, w, l, -0.9) do
			cyl(ctx, 0.8, 2.4, cf * CFrame.new(0, -2.2, 0), C.hazard, METAL)
		end
	end,
	conveyor = function(ctx, top, w, l)
		T.coaster.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.track)
		end
		own(parts.beam, "Color", C.track)
		on(ctx, parts.ball, true)
		group(ctx, "Ring", function()
			cyl(ctx, 4.3, 0.6, parts.ball.CFrame * FLAT, C.steel, METAL)
		end)
	end,
	arch = function(ctx, top, w)
		local at = arch(ctx, top, w, 9, C.steel, METAL, C.track, METAL, 0.9)
		box(ctx, Vector3.new(w + 3, 0.5, 4), at * CFrame.new(0, 0.1, 0), C.track, METAL)
		local b = box(ctx, Vector3.new(w - 1, 1.6, 0.3), at * CFrame.new(0, 1.2, 2.15), C.navy)
		label(b, "STATION", C.yellow, C.dark, Enum.NormalId.Back)
		bulbRow(ctx, (at * CFrame.new(-w / 2 - 1, -0.3, 2.05)).Position, (at * CFrame.new(w / 2 + 1, -0.3, 2.05)).Position, 7, { C.warm, C.yellow })
	end,
}

-- ---------------------------------------------------------------- finale: star-field navy, neon rims, rockets
local function stars(ctx, top: CFrame, w: number, l: number, n: number)
	for _ = 1, n do
		local x = ctx.rng:NextNumber(-w / 2 + 0.8, w / 2 - 0.8)
		local z = ctx.rng:NextNumber(-l / 2 + 0.8, l / 2 - 0.8)
		local s = ctx.rng:NextNumber(0.35, 0.6)
		box(ctx, Vector3.new(s, 0.04, s), top * CFrame.new(x, 0.02, z) * CFrame.Angles(0, math.rad(45), 0), pick(ctx, { C.gold, C.white, C.lilac }), NEON)
	end
end

T.finale = {
	accent = { C.navy, SMOOTH, C.gold }, bulbs = NEONS, pennant = { C.magenta, C.gold },
	decor = { pole = C.navy, globe = C.magenta, wire = C.navy, bulbs = NEONS, board = C.navy, frame = C.gold, ink = C.gold,
		balloons = NEONS },
	edge = function(ctx, top, w, l, round)
		lip(ctx, top, w, l, round, C.navy, SMOOTH, 0.3, 0.6, 0.2)
		lip(ctx, top, w, l, round, pick(ctx, NEONS), NEON, 0.38, 0.18, 0.12)
		lip(ctx, top, w, l, round, pick(ctx, NEONS), NEON, -0.6, 0.2, 1.1)
		if not round then
			stars(ctx, top, w, l, math.clamp(math.floor(w * l / 25), 1, 4))
		end
	end,
	platform = function(ctx, top, w, l)
		local r, side = ctx.rng:NextNumber(), sideOf(ctx)
		if r < 0.35 then
			group(ctx, "Rocket", function()
				rocket(ctx, shelf(ctx, top, w, side, 0, 1.2, C.navy, METAL), 1, pick(ctx, NEONS))
			end)
		elseif r < 0.65 then
			group(ctx, "Sparkler", function()
				sparkler(ctx, shelf(ctx, top, w, side, 0, 0.55, C.navy, METAL), pick(ctx, NEONS))
			end)
		end
	end,
	moving = function(ctx, _host, top, w, l)
		lip(ctx, top, w, l, false, C.navy, SMOOTH, 0.3, 0.6, 0.2)
		lip(ctx, top, w, l, false, C.magenta, NEON, 0.38, 0.18, 0.12)
		lip(ctx, top, w, l, false, C.gold, NEON, -0.6, 0.2, 1.1)
		for _, side in { -1, 1 } do
			group(ctx, "Sparkler", function()
				sparkler(ctx, shelf(ctx, top, w, side, l / 2 - 1, 0.55, C.navy, METAL), if side > 0 then C.gold else C.magenta)
			end)
		end
	end,
	spinBase = function(ctx, top, d)
		T.finale.edge(ctx, top, d, d, true)
		for k = 0, 5 do
			box(ctx, Vector3.new(0.5, 0.05, d / 2 - 1.6), top * CFrame.Angles(0, k * math.pi / 3, 0) * CFrame.new(0, 0.025, -(d / 4 + 0.6)), NEONS[k % #NEONS + 1], NEON)
		end
	end,
	spinBar = function(ctx, bar)
		group(ctx, "Fuse", function()
			local fuse = box(ctx, Vector3.new(bar.Size.X - 1, 0.3, 0.3), bar.CFrame * CFrame.new(0, 0.6, 0), C.gold, NEON)
			particles(fuse, SPARKLE, C.gold, 30, 6, 0.5, 0.6)
		end)
	end,
	turntable = function(ctx, _disc, top, d)
		lip(ctx, top, d, d, true, C.navy, SMOOTH, 0.3, 0.6, 0.2)
		for k = 0, 5 do
			box(ctx, Vector3.new(0.6, 0.05, d / 2 - 0.8), top * CFrame.Angles(0, k * math.pi / 3, 0) * CFrame.new(0, 0.025, -(d / 4 + 0.2))
				* CFrame.Angles(0, math.rad(18), 0), NEONS[k % #NEONS + 1], NEON)
		end
		local rim = cyl(ctx, d + 0.6, 0.2, top * CFrame.new(0, -0.35, 0), C.gold, NEON)
		particles(rim, SPARKLE, C.gold, 12, 5, 0.6, 0.6)
	end,
	tile = function(ctx, top, w, l, i)
		lip(ctx, top, w, l, false, C.navy, SMOOTH, 0.2, 0.5, 0.15)
		lip(ctx, top, w, l, false, NEONS[i % #NEONS + 1], NEON, 0.32, 0.16, 0.1)
	end,
	jumppad = function(ctx, top, w, l, part)
		T.finale.edge(ctx, top, w, l, false)
		group(ctx, "Rocket", function()
			rocket(ctx, shelf(ctx, top, w, 1, l / 2 - 1.2, 1.35, C.navy, METAL), 1.1, C.magenta)
		end)
		particles(part, SPARKLE, C.gold, 10, 16, 0.6, 0.8)
	end,
	trampoline = function(ctx, top, w, l)
		lip(ctx, top, w, l, false, C.navy, SMOOTH, 0.3, 0.6, 0.2)
		lip(ctx, top, w, l, false, C.lime, NEON, 0.38, 0.18, 0.12)
	end,
	conveyor = function(ctx, top, w, l)
		T.finale.edge(ctx, top, w, l, false)
	end,
	pendulum = function(ctx, parts)
		for _, p in parts.posts do
			own(p, "Color", C.navy)
			own(p, "Material", SMOOTH)
		end
		own(parts.beam, "Color", C.navy)
		on(ctx, parts.ball, true)
		group(ctx, "Ring", function()
			cyl(ctx, 4.3, 0.4, parts.ball.CFrame * FLAT, C.gold, NEON)
			particles(parts.ball, SPARKLE, C.gold, 12, 5, 0.6, 0.8)
		end)
	end,
	arch = function(ctx, top, w)
		local x = w / 2 + MARGIN + 0.6
		for _, s in { -1, 1 } do
			cyl(ctx, 0.9, 9, top * CFrame.new(s * x, 3.5, 0), C.navy)
			box(ctx, Vector3.new(0.3, 8, 0.95), top * CFrame.new(s * x, 3.7, 0), C.magenta, NEON)
		end
		local prev
		for i = 0, 6 do
			local a = math.pi * i / 6
			local p = (top * CFrame.new(-math.cos(a) * x, 8 + math.sin(a) * 2.6, 0)).Position
			if prev then
				rod(ctx, prev, p, 0.45, NEONS[i % #NEONS + 1], NEON)
			end
			prev = p
		end
		local star = top * CFrame.new(0, 11.4, 0)
		for _, a in { 0, 45, 90, 135 } do
			box(ctx, Vector3.new(0.35, 2.6, 0.35), star * CFrame.Angles(0, 0, math.rad(a)), C.gold, NEON)
		end
	end,
}

-- ============================================================== dress: one piece

local MAIN = {
	platform = "Platform", checkpoint = "Checkpoint", moving = "Mover", spinner = "Base", turntable = "Turntable",
	jumppad = "JumpPad", trampoline = "Trampoline", conveyor = "Conveyor", pendulum = "Bridge", lava = "Lava",
}

local function child(model: Instance, name: string): BasePart?
	local p = model:FindFirstChild(name)
	return if p and p:IsA("BasePart") then p else nil
end

local function mainPart(model: Instance, kind: string): BasePart?
	local p = child(model, MAIN[kind] or "") or (if kind == "checkpoint" then child(model, "StartPad") else nil)
	if p then
		return p
	end
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") and (CollectionService:HasTag(d, "ObbyStandable") or CollectionService:HasTag(d, "KillPart")) then
			return d
		end
	end
	return nil
end

-- Trims for a still walkable of any shape, and its legs.
local function still(ctx, th, part: BasePart, hook0: string?): (CFrame, number, number, string)
	on(ctx, part)
	local top, w, l, shape, rise = topOf(part)
	if shape == "log" then
		logTrim(ctx, th, top, w, l)
	elseif shape == "ramp" then
		rampTrim(ctx, th, top, w, l, rise, TOPS[ctx.theme].stripe)
	else
		local fn = hook0 and th[hook0]
		if fn then
			fn(ctx, top, w, l, part, ctx.model)
		else
			th.edge(ctx, top, w, l, shape == "disc")
		end
	end
	on(ctx, nil, false)
	supports(ctx, th, top, w, l, depthOf(part), shape)
	on(ctx, part)
	return top, w, l, shape
end

local DRESS = {}

function DRESS.platform(ctx, th, tops)
	local p = mainPart(ctx.model, "platform")
	if p then
		paint(p, tops.platform)
		local top, w, l, shape = still(ctx, th, p)
		if th.platform and shape == "block" then
			th.platform(ctx, top, w, l)
		end
	end
end

function DRESS.moving(ctx, th, tops)
	local p = mainPart(ctx.model, "moving")
	if not p then
		return
	end
	local mv = p:GetAttribute("Move")
	if type(ctx.params.move) ~= "table" and typeof(mv) == "Vector3" then
		ctx.params.move = { mv.X, mv.Y, mv.Z }
	end
	paint(p, tops.moving)
	on(ctx, p)
	local top, w, l = topOf(p)
	if th.moving then
		th.moving(ctx, p, top, w, l)
	else
		th.edge(ctx, top, w, l, false)
	end
end

function DRESS.spinner(ctx, th, tops)
	local base, bar = child(ctx.model, "Base"), child(ctx.model, "Bar")
	if base then
		paint(base, tops.base)
		own(child(ctx.model, "Hub"), "Color", th.accent[3])
		on(ctx, base)
		local top, d = topOf(base)
		if th.spinBase then
			th.spinBase(ctx, top, d)
		else
			th.edge(ctx, top, d, d, true)
		end
		on(ctx, nil, false)
		supports(ctx, th, top, d, d, depthOf(base), "disc")
	end
	if bar then
		own(bar, "Color", KILL[ctx.theme])
		on(ctx, bar)
		if th.spinBar then
			th.spinBar(ctx, bar)
		end
	end
end

function DRESS.turntable(ctx, th, tops)
	local disc = mainPart(ctx.model, "turntable")
	if not disc then
		return
	end
	paint(disc, tops.turntable)
	for _, s in ctx.model:GetChildren() do
		if s:IsA("BasePart") and s.Name == "Stripe" then
			own(s, "Color", tops.stripe)
		end
	end
	on(ctx, disc)
	local top, d = topOf(disc)
	if th.turntable then
		th.turntable(ctx, disc, top, d)
	else
		th.edge(ctx, top, d, d, true)
	end
	on(ctx, nil, false)
	supports(ctx, th, top, d, d, depthOf(disc), "disc")
end

function DRESS.disappearing(ctx, th, tops)
	for _, tile in ctx.model:GetChildren() do
		if tile:IsA("BasePart") and (tile.Name == "Tile" or CollectionService:HasTag(tile, "ObbyStandable")) then
			local i = tonumber(tile:GetAttribute("Tile")) or 0
			ctx.still = "Tile" .. i
			paintTile(ctx, tile, tops.tile)
			on(ctx, tile, false)
			local top, w, l = topOf(tile)
			if th.tile then
				th.tile(ctx, top, w, l, i)
			else
				th.edge(ctx, top, w, l, false)
			end
			mirror(ctx, tile, ctx.folder)
		end
	end
	ctx.still = nil
end

function DRESS.jumppad(ctx, th)
	local p = mainPart(ctx.model, "jumppad")
	if p then
		still(ctx, th, p, "jumppad")
	end
end

function DRESS.trampoline(ctx, th)
	local p = mainPart(ctx.model, "trampoline")
	if p then
		still(ctx, th, p, "trampoline")
	end
end

function DRESS.conveyor(ctx, th, tops)
	local p = mainPart(ctx.model, "conveyor")
	if p then
		paint(p, tops.belt)
		for _, c in ctx.model:GetChildren() do
			if c:IsA("BasePart") and c.Name == "Chevron" then
				own(c, "Color", tops.chevron)
			end
		end
		still(ctx, th, p, "conveyor")
	end
end

function DRESS.checkpoint(ctx, th)
	local pad = mainPart(ctx.model, "checkpoint")
	if not pad then
		return
	end
	on(ctx, pad, false)
	local top, w = topOf(pad)
	group(ctx, "Arch", function()
		th.arch(ctx, top, w)
	end)
	local flag, pole = child(ctx.model, "Flag"), child(ctx.model, "Pole")
	if flag and pole then
		own(flag, "Transparency", 1)
		local cf = flag.CFrame * CFrame.new(-flag.Size.X / 2, 0, 0)
		local colors = th.pennant
		group(ctx, "Pennant", function()
			pennant(ctx, cf * CFrame.new(0.2, 0.1, 0), 3, 1.9, colors[1], colors[2])
		end)
	end
	on(ctx, nil, false)
	supports(ctx, th, top, w, w, depthOf(pad), "block")
end

function DRESS.pendulum(ctx, th, tops)
	local model = ctx.model
	local bridge = child(model, "Bridge")
	if bridge then
		paint(bridge, tops.bridge)
		still(ctx, th, bridge)
	end
	local parts = { bridge = bridge, posts = {}, beam = child(model, "Beam"), rod = child(model, "Rod"), ball = child(model, "Ball") }
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") and d.Name == "Post" then
			table.insert(parts.posts, d)
		end
	end
	if parts.ball then
		own(parts.ball, "Color", KILL[ctx.theme])
		if th.pendulum then
			on(ctx, nil, false)
			th.pendulum(ctx, parts)
		end
	end
end

function DRESS.lava(ctx, th)
	local slab = mainPart(ctx.model, "lava")
	if not slab then
		return
	end
	own(slab, "Color", KILL[ctx.theme])
	own(slab, "Material", NEON)
	on(ctx, slab, false)
	local top, w, l = topOf(slab)
	hazardBand(ctx, top, w, l)
	if th.lava then
		th.lava(ctx, slab, top, w, l)
	end
end

local function rngFor(rng: any, model: Instance): Random
	if typeof(rng) == "Random" then
		return rng
	end
	if type(rng) == "number" then
		return Random.new(rng)
	end
	for _, d in model:GetChildren() do
		if d:IsA("BasePart") then
			local p = d.Position
			return Random.new(math.floor(p.X * 7.13 + p.Y * 3.71 + p.Z * 5.29))
		end
	end
	return Random.new(0)
end

local function centreOf(model: Instance): Vector3
	local kind = tostring(model:GetAttribute("Kind") or "")
	local p = mainPart(model, kind)
	if p then
		return p.Position
	end
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			return d.Position
		end
	end
	return Vector3.zero
end

-- Dress one piece built by ObbyKit.Obstacles.<kind> as part of `theme`'s ride. kind: the piece kind (default the
-- model's Kind attribute); params: the piece's level data (moving reads `move`); theme: an id from THEMES or free text
-- (resolved); rng: a Random or a seed (default: seeded from the piece's position). Puts back whatever an earlier dress
-- changed, then adds a Model "Dressing" under the piece and returns it. A nil or blank theme only undoes an earlier
-- dress and returns nil. Never throws: a failure warns and keeps what was built.
function ObbyThemes.dress(kind: string?, model: Instance, params: any?, theme: string?, rng: any?): Model?
	if typeof(model) ~= "Instance" then
		return nil
	end
	local k = string.lower(tostring(kind or model:GetAttribute("Kind") or ""))
	local fn = DRESS[k]
	if not fn then
		return nil
	end
	local old = model:FindFirstChild("Dressing")
	if old then
		old:Destroy()
	end
	restore(model)
	local id = ObbyThemes.resolve(theme)
	if not id then
		return nil
	end
	local folder = Instance.new("Model")
	folder.Name = "Dressing"
	folder:SetAttribute("Theme", id)
	folder.Parent = model
	local p = {}
	if type(params) == "table" then
		for key, v in params do
			p[key] = v
		end
	end
	local ctx = { root = folder, rng = rngFor(rng, model), theme = id, parts = 0, dropped = 0, params = p, model = model }
	local ok, err = pcall(function()
		ctx.cols = columnsNear(model, centreOf(model))
		on(ctx, nil, false)
		fn(ctx, T[id], TOPS[id])
	end)
	if not ok then
		warn(string.format("[ObbyThemes] dress %s %s: %s", id, k, tostring(err)))
	end
	folder:SetAttribute("Parts", ctx.parts)
	folder:SetAttribute("Dropped", ctx.dropped)
	return folder
end

-- ============================================================== stageDecor: one stage

local STILL = { platform = true, checkpoint = true, jumppad = true, trampoline = true, conveyor = true, pendulum = true,
	spinner = true }

-- Where a piece sits (its walkable top at rest, turned like the course), its footprint and whether a lamp may stand by
-- it: still pieces only (no movers, turntables, vanishing tiles or lava).
local function seat(model: Instance, origin: CFrame): (CFrame?, number, number, boolean)
	local kind = tostring(model:GetAttribute("Kind") or "")
	local p = mainPart(model, kind)
	if not p then
		return nil, 0, 0, false
	end
	local top, w, l = topOf(p, true)
	return CFrame.new(top.Position) * origin.Rotation, w, l, STILL[kind] == true
end

local function stageOf(inst: Instance): Instance?
	local cur = inst.Parent
	while cur and cur ~= workspace do
		if CollectionService:HasTag(cur, "ObbyStage") then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

-- The part a decoration of `root` (a Dressing or StageDecor) belongs to as a unit: its group, or itself.
local function unitOf(p: Instance, root: Instance): Instance
	local parent = p.Parent
	if parent and parent.Parent and parent.Parent ~= root and parent.Parent.Parent == root then
		return parent
	end
	return p
end

-- Remove every decoration under `root` (from piece `piece`) that reaches into one of `cols`, with its group.
local function sweep(root: Instance, piece: Instance?, cols): number
	local gone, motions = {}, {}
	for _, p in root:GetDescendants() do
		if not p:IsA("BasePart") then
			continue
		end
		local unit = unitOf(p, root)
		if gone[unit] then
			continue
		end
		local box0 = p
		while box0.Parent and box0.Parent ~= root do
			box0 = box0.Parent
		end
		local m = motions[box0]
		if m == nil then
			local hostName = box0:GetAttribute("Host")
			local host = hostName and piece and piece:FindFirstChild(hostName)
			m = (host and host:IsA("BasePart") and motionOf(host)) or false
			motions[box0] = m
		end
		local hazard = p:GetAttribute("Hazard") == true
		for _, col in cols do
			if not (hazard and col.piece == piece) and partHits(col, p, m or nil) then
				gone[unit] = true
				break
			end
		end
	end
	local n = 0
	for unit in gone do
		unit:Destroy()
		n += 1
	end
	return n
end

-- The decorations of a stage: its pieces' Dressings and its StageDecor, with the piece each belongs to.
local function dressingsOf(stage: Instance): { { any } }
	local out = {}
	for _, m in stage:GetChildren() do
		local d = m:FindFirstChild("Dressing")
		if d then
			table.insert(out, { d, m })
		end
	end
	local decor = stage:FindFirstChild("StageDecor")
	if decor then
		table.insert(out, { decor, nil })
	end
	return out
end

-- String lights from a to b, sagging `sag` studs in the middle.
local function festoon(ctx, a: Vector3, b: Vector3, sag: number, n: number, wire: Color3, colors: { Color3 })
	local function at(t: number): Vector3
		return a:Lerp(b, t) - Vector3.new(0, sag * 4 * t * (1 - t), 0)
	end
	local segs = math.clamp(n, 2, 4)
	local prev = a
	for i = 1, segs do
		local p = at(i / segs)
		rod(ctx, prev, p, 0.08, wire)
		prev = p
	end
	for i = 1, n do
		bulb(ctx, CFrame.new(at(i / (n + 1)) - Vector3.new(0, 0.32, 0)), colors[(i - 1) % #colors + 1], 0.55)
	end
end

-- Side decoration for one built stage: lamps on brackets beside its still pieces (sides alternate by stage), string
-- lights between them, balloons, and a sign with the stage's name at its start, at most MAX_STAGE_PARTS parts. It
-- first sweeps the decorations of this stage and of the stages built next to it out of every walkable's body space.
-- Returns the Model "StageDecor" added under the stage; a nil or blank theme adds nothing. Never throws.
function ObbyThemes.stageDecor(stageModel: Instance, theme: string?, rng: any?, stage: number?): Model?
	if typeof(stageModel) ~= "Instance" then
		return nil
	end
	local old = stageModel:FindFirstChild("StageDecor")
	if old then
		old:Destroy()
	end
	local id = ObbyThemes.resolve(theme)
	if not id then
		return nil
	end
	local st = T[id].decor
	local folder = Instance.new("Model")
	folder.Name = "StageDecor"
	folder:SetAttribute("Theme", id)
	folder.Parent = stageModel
	local n = math.floor(tonumber(stage) or tonumber(stageModel:GetAttribute("Stage")) or 0)
	local ctx = { root = folder, rng = rngFor(rng, stageModel), theme = id, parts = 0, dropped = 0, params = {}, model = stageModel, cols = {} }
	local ok, err = pcall(function()
		local origin = stageModel:GetAttribute("Origin")
		local pieces = {}
		for _, m in stageModel:GetChildren() do
			if m:IsA("Model") and m:GetAttribute("Kind") then
				table.insert(pieces, m)
			end
		end
		table.sort(pieces, function(a, b)
			return (tonumber(a:GetAttribute("Piece")) or 0) < (tonumber(b:GetAttribute("Piece")) or 0)
		end)
		if typeof(origin) ~= "CFrame" then
			local first = pieces[1] and mainPart(pieces[1], tostring(pieces[1]:GetAttribute("Kind")))
			origin = if first then CFrame.new(first.Position) else CFrame.new()
		end
		-- the body spaces: this stage's walkables, and those already in the world around it (other stages, start pads)
		local own, lo, hi = {}, nil, nil
		for _, m in pieces do
			for _, p in m:GetChildren() do
				if standable(p) then
					local col = columnOf(p :: BasePart, m)
					table.insert(own, col)
					local pos = (p :: BasePart).Position
					lo = if lo then lo:Min(pos) else pos
					hi = if hi then hi:Max(pos) else pos
				end
			end
		end
		local cols = table.clone(own)
		local others = {}
		if lo and hi then
			local params = OverlapParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = { stageModel }
			local found = workspace:GetPartBoundsInBox(CFrame.new((lo + hi) / 2), hi - lo + Vector3.new(30, 30, 30), params)
			for _, p in found do
				if standable(p) and not p:IsDescendantOf(stageModel) then
					table.insert(cols, columnOf(p :: BasePart, p.Parent))
					local s = stageOf(p)
					if s and s ~= stageModel then
						others[s] = true
					end
				end
			end
		end
		ctx.cols = cols
		local swept = 0
		for _, entry in dressingsOf(stageModel) do
			if entry[1] ~= folder then
				swept += sweep(entry[1], entry[2], cols)
			end
		end
		for s in others do
			for _, entry in dressingsOf(s) do
				swept += sweep(entry[1], entry[2], own)
			end
		end
		folder:SetAttribute("Swept", swept)

		local side = if n % 2 == 0 then 1 else -1
		local budget = ObbyThemes.MAX_STAGE_PARTS
		on(ctx, nil, false)
		local first = pieces[1]
		local name = tostring(stageModel:GetAttribute("StageName") or "")
		if first and name ~= "" then
			local f, w, l = seat(first, origin)
			if f then
				local bw = math.clamp(#name * 0.42, 3, 7)
				local x = -side * (w / 2 + MARGIN + 0.45 + bw / 2)
				group(ctx, "Sign", function()
					local base = f * CFrame.new(x, 0, l / 2 - 0.6)
					rod(ctx, (f * CFrame.new(-side * (w / 2 - 0.1), -0.8, l / 2 - 0.6)).Position, (base * CFrame.new(0, -0.8, 0)).Position, 0.25, st.frame, METAL)
					cyl(ctx, 0.4, 5.6, base * CFrame.new(0, 2, 0), st.frame, METAL)
					sign(ctx, base * CFrame.new(0, 4.6, 0) * TURN, bw, 1.4, string.upper(name), st.board, st.frame, st.ink, st.mat)
					if st.balloons then
						balloons(ctx, (base * CFrame.new(0, 5.6, 0)).Position, (f.RightVector * -side), 3, 2.6, st.balloons)
					end
				end)
			end
		end
		local lamps = {}
		for i, m in pieces do
			local pf, pw, pl, ok2 = seat(m, origin)
			if pf and ok2 and i < #pieces and ctx.parts + 5 <= budget then
				local kind = m:GetAttribute("Kind")
				local z = if kind == "pendulum" then pl / 2 - 1.2 else 0
				local x = side * (pw / 2 + MARGIN + 0.8)
				local g = group(ctx, "Lamp", function()
					rod(ctx, (pf * CFrame.new(side * (pw / 2 - 0.1), -0.9, z)).Position, (pf * CFrame.new(x, -0.9, z)).Position, 0.22, st.pole, METAL)
					lamp(ctx, pf * CFrame.new(x, -1.3, z), 6.4, st.pole, st.globe, #lamps % 3 == 0)
				end)
				if g then
					table.insert(lamps, (pf * CFrame.new(x, 5.4, z)).Position)
				end
			end
		end
		for i = 1, #lamps - 1 do
			local a, b = lamps[i], lamps[i + 1]
			local dist = (b - a).Magnitude
			local k = math.clamp(math.floor(dist / 5), 2, 8)
			if dist > 2 and dist < 72 and ctx.parts + k + math.clamp(k, 2, 4) <= budget then
				group(ctx, "Lights", function()
					festoon(ctx, a, b, math.min(1.6, dist / 9), k, st.wire, st.bulbs)
				end)
			end
		end
	end)
	if not ok then
		warn(string.format("[ObbyThemes] stageDecor %s stage %d: %s", id, n, tostring(err)))
	end
	folder:SetAttribute("Parts", ctx.parts)
	folder:SetAttribute("Dropped", ctx.dropped)
	return folder
end

return ObbyThemes
