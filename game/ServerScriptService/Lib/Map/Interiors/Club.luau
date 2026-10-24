--!strict
-- Interiors/Club [owner: interiors]. Club Inferno (BlockFiller nightclub) fitted out when a run binds it
-- (Interiors/Furnish). Building frame: x across the front (-w/2..w/2), z from the front wall (0) to the
-- back (d); wide open entrance at x 0, fire exit in the back wall at x -0.3 w, side windows at z d/2.
-- The builder already lays the glowing dance floor (4 x 4 neon tiles round (0, 0.42 d)), the disco ball,
-- the fog machine + its gas bottle (explosion hazard) and the VIP curtain; those stay. Its placeholder
-- boxes are swapped for the real thing on the same spots (their FireStarts still find them):
--   DJBooth  -> DJ desk with two turntables, a mixer, a laptop, headphones and a neon DJ sign
--   Speaker  -> stacked speaker cabinets with drawn woofers
--   Bar + BarShelf -> bar counter with taps, bottles and glasses, a neon-lit back bar, stools, BAR sign
--   VIPCouch -> two VIP sofas, a coffee table, a floor lamp, rope stanchions, VIP sign
-- and around them: restrooms (two rooms behind flammable partitions, front-left), a coat check
-- (front-right), a diner-style booth by the front wall and one by the bar, cocktail tables, a lighting
-- truss with coloured spot cans over the dance floor, neon signs, the EXIT sign + a glowing floor strip
-- to the fire exit, and a dark floor. The entrance lane, the fire-exit lane and every rescue spot stay clear.
local Plan = require(script.Parent:WaitForChild("Plan") :: ModuleScript)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Club = {}
local Furnish_partition: any = nil

local C = Kit.C
local P = Kit.part
local CF = CFrame.new
local V = Vector3.new
local ANG = CFrame.Angles
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0
local hex = Color3.fromHex

local PINK = hex("#FF3DAE")
local CYAN = hex("#2FE6FF")
local LIME = hex("#B6FF3B")
local GOLD = hex("#FFC53D")
local NIGHT = hex("#120C1A")
local NEONS = { PINK, CYAN, LIME, GOLD }
local BOTTLES = { hex("#3FA34D"), hex("#C8232B"), hex("#E9C46A"), hex("#7FD1E0"), hex("#8E5572"), hex("#F4A261") }

type Ctx = any

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function model(name: string): Model
	local m = Instance.new("Model")
	m.Name = name
	return m
end

local function done(m: Model, parent: Instance, primary: BasePart): Model
	m.PrimaryPart = primary
	m.Parent = parent
	return m
end

-- The builder's placeholder boxes named `name`: local (x, z, size); each one is destroyed.
local function takeAll(ctx: Ctx, name: string): { { x: number, z: number, size: Vector3 } }
	local out = {}
	local inv = ctx.F:Inverse()
	for _, p in ctx.site:GetChildren() do
		if p:IsA("BasePart") and p.Name == name then
			local l = inv * p.CFrame
			table.insert(out, { x = l.Position.X, z = l.Position.Z, size = p.Size })
			p:Destroy()
		end
	end
	table.sort(out, function(a, b)
		return a.x < b.x
	end)
	return out
end

local function glowLight(p: BasePart, color: Color3, range: number, bright: number)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = range
	l.Brightness = bright
	l.Shadows = false
	l.Parent = p
end

---------------------------------------------------------------------------------------------------
-- club props
---------------------------------------------------------------------------------------------------
-- Neon text panel on a wall (cf = wall face, -Z into the room). o.w, o.h, o.y, o.text, o.color.
local function neonSign(parent: Instance, cf: CFrame, o: any): Model
	local m = model("NeonSign")
	local w, h = o.w or 6, o.h or 2
	local col = o.color or PINK
	local back = P(m, "NeonBacking", cf * CF(0, o.y or 10, -0.12), V(w, h, 0.12), NIGHT)
	local g = Kit.gui(back, Enum.NormalId.Front, 30, true)
	local t = Kit.text(g, 0.04, 0.06, 0.92, 0.88, o.text or "", col, Enum.Font.LuckiestGuy)
	local stroke = Instance.new("UIStroke")
	stroke.Color = C.White
	stroke.Thickness = 2
	stroke.Transparency = 0.4
	stroke.Parent = t
	local tube = P(m, "NeonTube", cf * CF(0, (o.y or 10) - h / 2 - 0.15, -0.25), V(w - 0.4, 0.15, 0.15), col, { neon = true })
	tube.CastShadow = false
	glowLight(tube, col, 12, 1.1)
	return done(m, parent, back)
end

-- DJ desk on the builder's DJBooth spot (12 x 3 footprint, faces -Z = the dance floor).
local function djBooth(parent: Instance, cf: CFrame, _o: any): Model
	local m = model("DJBooth")
	local fronts = Kit.chunked(m, "DJDesk", cf * CF(0, 1.85, 0.1), V(12, 3.7, 2.8), NIGHT, { solid = true, fuel = 25 })
	for i, f in fronts do
		local g = Kit.gui(f, Enum.NormalId.Front, 20, true)
		for k = 0, 2 do
			Kit.rect(g, 0, 0.62 + k * 0.12, 1, 0.05, NEONS[(k + i) % 4 + 1])
		end
		Kit.text(g, 0.1, 0.08, 0.8, 0.45, if i == 1 then "FROST" else "DJ", C.White, Enum.Font.LuckiestGuy)
	end
	P(m, "DeckTop", cf * CF(0, 3.82, 0.1), V(12.4, 0.25, 3.2), C.Iron, { solid = true })
	local top = cf * CF(0, 3.95, 0.3)
	for _, x in { -3.4, 3.4 } do
		P(m, "Turntable", top * CF(x, 0.15, 0), V(2.6, 0.3, 2.2), C.Steel)
		Kit.cylY(m, "Record", top * CF(x - 0.2, 0.34, 0), 0.08, 1.9, C.Black)
		Kit.cylY(m, "RecordLabel", top * CF(x - 0.2, 0.39, 0), 0.04, 0.6, if x < 0 then PINK else CYAN)
		P(m, "ToneArm", top * CF(x + 0.9, 0.42, 0.3) * ANG(0, 0.5, 0), V(0.12, 0.12, 1.4), C.Chrome)
	end
	local mixer = P(m, "Mixer", top * CF(0, 0.2, 0), V(2.4, 0.4, 2), C.Ink)
	local mg = Kit.gui(mixer, Enum.NormalId.Top, 30, true)
	for k = 0, 3 do
		Kit.rect(mg, 0.1 + k * 0.22, 0.15, 0.12, 0.12, NEONS[k + 1], 1)
		Kit.rect(mg, 0.13 + k * 0.22, 0.45, 0.06, 0.4, C.Steel)
	end
	P(m, "Laptop", top * CF(1.6, 0.06, -0.9), V(1.4, 0.1, 1), C.Chrome)
	local scr = P(m, "LaptopScreen", top * CF(1.6, 0.55, -0.42) * ANG(math.rad(15), 0, 0), V(1.4, 0.9, 0.06), CYAN, { neon = true })
	scr.CastShadow = false
	for _, x in { -0.35, 0.35 } do
		P(m, "Headphones", top * CF(-1.8 + x, 0.2, -1) , V(0.3, 0.4, 0.4), C.Red)
	end
	P(m, "HeadBand", top * CF(-1.8, 0.45, -1), V(0.9, 0.12, 0.15), C.Red)
	for _, x in { -5.5, 5.5 } do
		local spk = P(m, "MonitorSpeaker", top * CF(x, 0.6, 0), V(1, 1.2, 1), C.Ink)
		local g = Kit.gui(spk, Enum.NormalId.Front, 30)
		Kit.rect(g, 0.2, 0.3, 0.6, 0.5, C.Steel, 1)
	end
	return done(m, parent, fronts[1])
end

-- Speaker stack on the builder's Speaker spot (4 x 3.5 footprint, 9 tall), woofers drawn.
local function speakerStack(parent: Instance, cf: CFrame, o: any): Model
	local m = model("SpeakerStack")
	local h = o.h or 9
	local first: BasePart? = nil
	for k, seg in { { 0, h * 0.55 }, { h * 0.55, h } } do
		local hh = seg[2] - seg[1]
		local cab = P(m, "SpeakerCabinet", cf * CF(0, seg[1] + hh / 2, 0), if k == 1 then V(4, hh, 3.4) else V(3.7, hh, 3.2), hex("#1B1B1F"), { solid = true, fuel = 20 })
		local g = Kit.gui(cab, Enum.NormalId.Front, 20)
		local n = if k == 1 then 2 else 1
		for i = 0, n - 1 do
			local s = if n == 2 then 0.42 else 0.6
			local y = if n == 2 then 0.06 + i * 0.48 else 0.2
			local ring = Kit.rect(g, 0.5 - s / 2, y, s, s * 4 / hh, hex("#3A3A40"), 1)
			Kit.rect(ring, 0.2, 0.2, 0.6, 0.6, hex("#24242A"), 1)
		end
		first = first or cab
	end
	local glow = P(m, "SpeakerGlow", cf * CF(0, h * 0.55, -1.75), V(4, 0.15, 0.12), pick(o.rng, NEONS), { neon = true })
	glow.CastShadow = false
	return done(m, parent, first :: BasePart)
end

-- Bar counter along local X (customers on -Z), taps, bottles, glasses. o.len.
local function barCounter(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local len = o.len or 14
	local m = model("BarCounter")
	local body = Kit.chunked(m, "BarCounter", cf * CF(0, 1.9, 0), V(len, 3.8, 2.4), hex("#5A2A3A"), { solid = true, fuel = 28 })
	for _, b in body do
		local g = Kit.gui(b, Enum.NormalId.Front, 16, true)
		Kit.rect(g, 0, 0.08, 1, 0.04, PINK)
		for k = 0, 3 do
			Kit.rect(g, 0.05 + k * 0.25, 0.25, 0.15, 0.65, hex("#6E3448"), 0.2)
		end
	end
	P(m, "BarTop", cf * CF(0, 3.92, -0.15), V(len + 0.3, 0.25, 2.9), hex("#2A1A12"), { solid = true })
	P(m, "FootRail", cf * CF(0, 0.6, -1.45), V(len - 0.4, 0.25, 0.25), C.Gold)
	local top = cf * CF(0, 4.05, 0)
	for _, x in { -len / 2 + 2.5, len / 2 - 2.5 } do
		P(m, "BeerTower", top * CF(x, 0.9, 0.5), V(0.5, 1.8, 0.5), C.Chrome)
		for _, dx in { -0.45, 0.45 } do
			P(m, "TapHandle", top * CF(x + dx, 1.6, 0.1), V(0.2, 0.9, 0.2), pick(rng, NEONS))
		end
	end
	for k = 1, 6 do
		local x = -len / 2 + 1 + (k - 0.5) * (len - 2) / 6 + rng:NextNumber(-0.4, 0.4)
		if k % 2 == 0 then
			Kit.cylY(m, "Bottle", top * CF(x, 0.6, rng:NextNumber(-0.4, 0.6)), 1.2, 0.45, pick(rng, BOTTLES), { tr = 0.15 })
		else
			Kit.cylY(m, "Glass", top * CF(x, 0.35, rng:NextNumber(-0.8, 0)), 0.7, 0.55, C.Glass, { mat = Enum.Material.Glass, tr = 0.4 })
		end
	end
	return done(m, parent, body[1])
end

-- Back bar on a wall (cf = wall face, -Z into the room): a glowing panel with bottles drawn on it and two
-- shelves of real bottles. o.len.
local function backBar(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local len = o.len or 12
	local m = model("BackBar")
	local panel = P(m, "BackBarPanel", cf * CF(0, 6.5, -0.12), V(len, 6, 0.15), hex("#3B1F4A"))
	local g = Kit.gui(panel, Enum.NormalId.Front, 16, true)
	Kit.rect(g, 0, 0, 1, 1, PINK).BackgroundTransparency = 0.8
	for r = 0, 2 do
		local x = 0.02
		while x < 0.96 do
			local bw = rng:NextNumber(0.012, 0.022)
			local bh = rng:NextNumber(0.12, 0.2)
			Kit.rect(g, x, 0.31 + r * 0.33 - bh, bw, bh, pick(rng, BOTTLES), 0.3)
			x += bw + rng:NextNumber(0.006, 0.02)
		end
	end
	for _, y in { 4.6, 7.0 } do
		P(m, "BackBarShelf", cf * CF(0, y, -0.7), V(len, 0.2, 1.1), C.Wood, { fuel = 6 })
		for k = 1, 5 do
			local x = -len / 2 + (k - 0.5) * len / 5 + rng:NextNumber(-0.6, 0.6)
			Kit.cylY(m, "Bottle", cf * CF(x, y + 0.75, -0.7), 1.3, 0.45, pick(rng, BOTTLES), { tr = 0.1 })
		end
	end
	glowLight(panel, PINK, 10, 0.8)
	return done(m, parent, panel)
end

-- Coat check: a counter facing -Z with a bell, a coat rail behind it with coats hanging. o.len.
local function coatCheck(parent: Instance, cf: CFrame, o: any): Model
	local rng: Random = o.rng
	local len = o.len or 7
	local m = model("CoatCheck")
	local body = Kit.chunked(m, "CoatCounter", cf * CF(0, 1.9, 0), V(len, 3.8, 2.2), hex("#3B2A4A"), { solid = true, fuel = 20 })
	P(m, "CoatCounterTop", cf * CF(0, 3.92, 0), V(len + 0.2, 0.25, 2.5), C.Gold, { solid = true })
	P(m, "ServiceBell", cf * CF(-len / 2 + 1, 4.25, -0.4), V(0.6, 0.4, 0.6), C.Gold)
	P(m, "TicketStack", cf * CF(len / 2 - 1.2, 4.1, -0.3), V(0.9, 0.15, 0.6), C.Red, { fuel = 2 })
	-- rail 3.5 behind the counter, coats hanging off it
	local rz = 3.6
	for _, x in { -len / 2 + 0.4, len / 2 - 0.4 } do
		P(m, "RailPost", cf * CF(x, 3.3, rz), V(0.3, 6.6, 0.3), C.Chrome)
	end
	P(m, "CoatRail", cf * CF(0, 6.4, rz), V(len - 0.4, 0.2, 0.2), C.Chrome)
	for k = 1, math.floor(len / 1.1) do
		local x = -len / 2 + 0.6 + (k - 0.5) * (len - 1.2) / math.floor(len / 1.1)
		P(m, "Coat", cf * CF(x, 4.8, rz) * ANG(0, R90 + rng:NextNumber(-0.25, 0.25), 0), V(0.4, 3, 1.6), pick(rng, { C.Navy, C.Red, C.Teal, C.Mustard, C.Ink, C.Pink }), { fuel = 6 })
	end
	P(m, "HatShelf", cf * CF(0, 7.4, rz + 0.6), V(len, 0.2, 1.2), C.Wood)
	for k = 0, 2 do
		Kit.cylY(m, "Hat", cf * CF(-len / 2 + 1.5 + k * 2.2, 7.85, rz + 0.6), 0.7, 1, pick(rng, { C.Ink, C.Red, C.Mustard }))
	end
	return done(m, parent, body[1])
end

-- Sign hanging from the ceiling (cf = the ceiling point), readable from both sides.
local function hang(parent: Instance, cf: CFrame, o: any): Model
	local m = model("HangingSign")
	local w = o.w or 5
	local s = P(m, "HangingSign", cf * CF(0, -1.6, 0), V(w, 1.3, 0.2), o.bg or NIGHT)
	for _, face in { Enum.NormalId.Front, Enum.NormalId.Back } do
		Kit.text(Kit.gui(s, face, 30, true), 0.04, 0.08, 0.92, 0.84, o.text or "", o.fg or GOLD)
	end
	for _, x in { -w / 2 + 0.5, w / 2 - 0.5 } do
		P(m, "SignWire", cf * CF(x, -0.45, 0), V(0.08, 0.9, 0.08), C.Iron)
	end
	return done(m, parent, s)
end

-- Rope stanchions along local X (posts + sagging velvet rope, walk-through). o.len.
local function rope(parent: Instance, cf: CFrame, o: any): Model
	local len = o.len or 8
	local m = model("VelvetRope")
	local n = math.max(2, math.floor(len / 4) + 1)
	local first: BasePart? = nil
	for k = 0, n - 1 do
		local x = -len / 2 + k * len / (n - 1)
		local post = P(m, "RopePost", cf * CF(x, 1.6, 0), V(0.35, 3.2, 0.35), C.Gold)
		Kit.cylY(m, "RopeBase", cf * CF(x, 0.1, 0), 0.2, 1.1, C.Gold)
		first = first or post
		if k > 0 then
			P(m, "VelvetRope", cf * CF(x - len / (n - 1) / 2, 2.7, 0), V(len / (n - 1) - 0.4, 0.25, 0.25), hex("#B0123C"))
		end
	end
	return done(m, parent, first :: BasePart)
end

-- Lighting truss (square ring round the dance floor) with spot cans; a few cast coloured SpotLights.
local function truss(parent: Instance, cf: CFrame, o: any): Model
	local m = model("LightingTruss")
	local r = o.r or 11
	local first = P(m, "TrussBar", cf * CF(0, 0, -r), V(2 * r + 0.6, 0.6, 0.6), C.Iron)
	P(m, "TrussBar", cf * CF(0, 0, r), V(2 * r + 0.6, 0.6, 0.6), C.Iron)
	P(m, "TrussBar", cf * CF(-r, 0, 0), V(0.6, 0.6, 2 * r - 0.6), C.Iron)
	P(m, "TrussBar", cf * CF(r, 0, 0), V(0.6, 0.6, 2 * r - 0.6), C.Iron)
	for i, sp in { { -r * 0.5, -r }, { r * 0.5, -r }, { -r, 0 }, { r, 0 }, { -r * 0.5, r }, { r * 0.5, r } } do
		local col = NEONS[(i - 1) % 4 + 1]
		local can = cf * CF(sp[1], -0.9, sp[2]) * ANG(math.rad(if sp[2] < 0 then 25 elseif sp[2] > 0 then -25 else 0), 0, math.rad(if sp[1] < -r * 0.9 then -25 elseif sp[1] > r * 0.9 then 25 else 0))
		P(m, "SpotCan", can, V(0.9, 1.2, 0.9), C.Ink)
		local lens = P(m, "SpotLens", can * CF(0, -0.62, 0), V(0.7, 0.06, 0.7), col, { neon = true })
		lens.CastShadow = false
		if i % 2 == 1 or i == 4 then
			local l = Instance.new("SpotLight")
			l.Face = Enum.NormalId.Bottom
			l.Color = col
			l.Range = 26
			l.Angle = 50
			l.Brightness = 3
			l.Shadows = false
			l.Parent = lens
		end
	end
	return done(m, parent, first)
end

---------------------------------------------------------------------------------------------------
-- layout
---------------------------------------------------------------------------------------------------
local function nightclub(ctx: Ctx)
	local rng = ctx.rng
	local w, d, H = ctx.w, ctx.d, ctx.H
	local y = ctx.floors[1]
	local top = y + H
	local fz = d * 0.42 -- dance floor centre (builder)
	local exitX = -0.3 * w -- fire exit in the back wall (builder)
	local placer = ctx.placers[1]
	local xr = -w / 2 + 14 -- restroom block east wall
	-- lanes that stay clear: entrance -> dance floor, fire exit, restroom doors
	placer:keep(Plan.span(-4.5, 0, 4.5, fz - 10))
	placer:keep(Plan.span(exitX - 3, d - 13, exitX + 3, d))
	placer:keep(Plan.span(xr + 0.5, 0.5, -4.5, 11))

	-- floors: dark club floor, white tiles in the restrooms
	ctx:add(Kit.floorFinish, ctx:at((xr + 0.5 + w / 2 - 0.5) / 2, y, d / 2), { w = w / 2 - 0.5 - xr - 0.5, d = d - 1, color = hex("#2A1F3D") })
	ctx:add(Kit.floorFinish, ctx:at((-w / 2 + 0.5 + xr + 0.5) / 2, y, (10 + d - 0.5) / 2), { w = xr + 0.5 + w / 2 - 0.5, d = d - 10.5, color = hex("#2A1F3D") })
	ctx:add(Kit.floorFinish, ctx:at((-w / 2 + 0.5 + xr - 0.5) / 2, y, 5.25), { w = xr - 0.5 + w / 2 - 0.5, d = 9.5, color = C.Tile, grid = 2, lines = C.TileB })

	-- restrooms: two rooms (GUYS front, GALS behind) with doorways onto the entrance hall
	if Furnish_partition then
		Furnish_partition(ctx, 1, xr, 0.5, xr, 10, { { c = 2.75, w = 2.8 }, { c = 7.25, w = 2.8 } }, hex("#3B2A4A"), hex("#4A3A5C"))
		Furnish_partition(ctx, 1, -w / 2 + 0.5, 9.5, xr - 0.5, 9.5, {}, hex("#3B2A4A"), hex("#4A3A5C"))
		Furnish_partition(ctx, 1, -w / 2 + 0.5, 5, xr - 0.5, 5, {}, C.TileB, C.White)
	end
	for i, rz in { 2.75, 7.25 } do
		local wallZ = if i == 1 then 0.5 else 9
		ctx:add(Kit.toilet, ctx:at(-w / 2 + 1.75, y, rz, E), {})
		ctx:add(Kit.vanity, ctx:at(xr - 5, y, wallZ, if i == 1 then S else N), { color = C.White })
		ctx:add(Kit.handDryer, ctx:at(xr - 2, y, wallZ, if i == 1 then S else N))
		ctx:add(Kit.pendant, ctx:at(-w / 2 + 6, top, rz), { color = if i == 1 then CYAN else PINK, range = 10 })
		ctx:add(Kit.sign, ctx:at(xr + 0.5, y, rz, E), { text = if i == 1 then "GUYS" else "GALS", y = 8.3, w = 3, bg = if i == 1 then CYAN else PINK, fg = NIGHT })
	end
	placer:take(Plan.span(-w / 2, 0, xr + 0.5, 10))

	-- DJ booth + speakers (builder spots)
	for _, sp in takeAll(ctx, "DJBooth") do
		ctx:add(djBooth, ctx:at(sp.x, y, sp.z), {})
		ctx:add(neonSign, ctx:at(sp.x, y, d - 0.5), { text = "DJ FROSTBITE", w = 12, h = 2.6, y = 11, color = CYAN })
	end
	for _, sp in takeAll(ctx, "Speaker") do
		ctx:add(speakerStack, ctx:at(sp.x, y, sp.z), { h = sp.size.Y, rng = rng })
	end

	-- bar on the left wall: counter (customers on +x), back bar, stools, sign, pendants
	local barZ = d * 0.45
	local barLen = 14
	takeAll(ctx, "BarShelf")
	for _, sp in takeAll(ctx, "Bar") do
		barZ = sp.z
		ctx:add(barCounter, ctx:at(sp.x, y, sp.z, E), { len = barLen })
		-- the back bar stops short of the side window (z d/2 +- 2)
		local bz0, bz1 = sp.z - barLen / 2, math.min(sp.z + barLen / 2, d / 2 - 2.6)
		if bz1 - bz0 > 3 then
			ctx:add(backBar, ctx:at(-w / 2 + 0.5, y, (bz0 + bz1) / 2, E), { len = bz1 - bz0 })
		end
		placer:take(Plan.span(-w / 2, sp.z - barLen / 2 - 0.2, sp.x + 1.8, sp.z + barLen / 2 + 0.2))
		ctx:add(neonSign, ctx:at(-w / 2 + 0.5, y, sp.z, E), { text = "BAR", w = 6, h = 2.2, y = 12, color = PINK })
		for k = 0, 5 do
			ctx:put(1, Kit.stool, sp.x + 3.3, sp.z - barLen / 2 + 1.2 + k * 2.3, N, 1.7, 1.7, { color = pick(rng, NEONS) })
		end
		for _, dz in { -4, 4 } do
			ctx:add(Kit.pendant, ctx:at(sp.x + 1.5, top, sp.z + dz), { color = PINK, range = 14 })
		end
	end

	-- VIP lounge on the right wall
	for _, sp in takeAll(ctx, "VIPCouch") do
		local sx = w / 2 - 2.3
		-- on the couch's own spot (the builder's keep-out there is the couch we just removed)
		for _, dz in { -3.2, 3.2 } do
			ctx:add(Kit.sofa, ctx:at(sx, y, sp.z + dz, W), { w = 6, color = hex("#8E1A5A"), accent = GOLD })
		end
		placer:take(Plan.span(sx - 1.8, sp.z - 6.4, w / 2, sp.z + 6.4))
		ctx:put(1, Kit.coffeeTable, sx - 4.2, sp.z, W, 4.2, 2.6, { color = NIGHT })
		ctx:put(1, Kit.floorLamp, w / 2 - 1.3, sp.z - 7.6, N, 1.4, 1.4, { color = PINK })
		ctx:add(rope, ctx:at(sx - 7.6, y, sp.z + 1.5, W), { len = 9 })
		ctx:add(neonSign, ctx:at(w / 2 - 0.5, y, sp.z, W), { text = "VIP", w = 5, h = 2.2, y = 11, color = GOLD })
		ctx:add(Kit.pendant, ctx:at(sx - 3, top, sp.z), { color = GOLD, range = 14 })
	end

	-- coat check just inside the entrance (right), a booth in the front-right corner
	local cx = 6.8
	ctx:put(1, coatCheck, cx, 5, W, 7, 2.4, { len = 7 })
	placer:take(Plan.span(cx + 1, 1, cx + 5, 9)) -- the rail behind it
	ctx:add(hang, ctx:at(cx + 1.6, top, 5, W), { text = "COAT CHECK", w = 5, bg = NIGHT, fg = GOLD })
	ctx:put(1, Kit.booth, w / 2 - 6, 4.6, N, 5.2, 6.8, { color = hex("#8E1A5A") })
	ctx:add(neonSign, ctx:at(w / 2 - 8, y, 0.5, S), { text = "STAY COOL", w = 7, h = 2, y = 10.5, color = LIME })

	-- booth by the bar's far end, cocktail tables round the dance floor
	ctx:put(1, Kit.booth, -w / 2 + 3.8, barZ + 12.6, W, 5.2, 6.6, { color = hex("#2F3A6A") })
	for _, c in { { w / 2 - 11, d * 0.785 }, { -9, d * 0.76 }, { w / 2 - 11, d * 0.6 } } do
		ctx:put(1, Kit.roundTable, c[1], c[2], N, 6.2, 6.2, { n = 2, color = NIGHT })
	end

	-- the lighting rig over the floor + a cord for the disco ball
	ctx:add(truss, ctx:at(0, top - 4.5, fz), { r = 11 })
	P(ctx.root, "DiscoCord", ctx:at(0, top - 0.75, fz), V(0.12, 1.5, 0.12), C.Iron)

	-- fire exit: EXIT sign over the door, a glowing strip on the floor leading to it
	ctx:add(Kit.exitSign, ctx:at(exitX, y, d - 0.5, N), { y = 8.4 })
	local strip = P(ctx.root, "ExitStrip", ctx:at(exitX, y + 0.13, d - 6.75), V(0.7, 0.06, 11.5), C.ExitGreen, { neon = true })
	strip.CastShadow = false
	local sg = Kit.gui(strip, Enum.NormalId.Top, 12, true)
	for k = 0, 4 do
		Kit.text(sg, 0, k * 0.2, 1, 0.12, "^", C.White)
	end
	ctx:add(neonSign, ctx:at(-w / 2 + 5, y, d - 0.5, N), { text = "NO FOG\nAFTER 2AM", w = 5, h = 2.6, y = 12.6, color = LIME })
	ctx:add(neonSign, ctx:at(-4, y, 0.5, S), { text = "CLUB INFERNO", w = 8, h = 2, y = 12.5, color = PINK })
end

function Club.register(Furnish: any)
	Furnish_partition = Furnish.partition
	Furnish.Layouts.nightclub = nightclub
end

return Club
