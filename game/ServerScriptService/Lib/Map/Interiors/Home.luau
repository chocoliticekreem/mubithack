--!strict
-- Interiors/Home [owner: interiors]. Interiors for BlockFiller's family houses, apartment blocks, shops
-- (incl. the gas-station kiosk) and diners, built when a run binds the site (Interiors/Furnish).
-- BlockFiller's placeholder boxes (Sofa, Table, Counter, Fridge, Bookshelf, Bed, Dresser, BunkBed, Desk,
-- Shelf, Crates, Booth) carry the FireStart markers, so each one is SWAPPED for a real Kit piece on the
-- same spot (the fire still starts there), then every zone gets dressed around it: rugs, lamps, a TV,
-- pictures, plants, kitchens, bedrooms, a bathroom corner, toys... Colours and the optional extras come
-- from a per-site Random, so two houses never look the same.
--   house:     living room (sofa, TV, coffee table, armchair, floor lamp), dining table, kitchen
--              (stove + sink counter, wall cabinets, fridge), bookcase, one random extra (piano /
--              aquarium / cat tree / reading nook); upstairs: bed + nightstands + dresser + wardrobe,
--              kids' corner (bunk bed, desk, toy box), bathroom corner (tub, toilet, vanity)
--   apartment: every flat: living room, dining, kitchenette, a bedroom behind a partition; lobby on
--              the ground floor (mailboxes, bench, notice board) beside the laundry
--   shop:      checkout, goods gondolas themed by the shop's name, drinks cooler, boxes, OPEN sign
--   diner:     booths, counter + stools, jukebox, checker floor, menu board, pendant lights
local Plan = require(script.Parent:WaitForChild("Plan") :: ModuleScript)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)

local Home = {}
local Furnish_partition: any = nil -- Furnish.partition / Furnish.footprint (set by register)
local Furnish_footprint: any = nil

local C = Kit.C
local CF = CFrame.new
local R90 = math.rad(90)
local E, W, S, N = -R90, R90, math.pi, 0

type Ctx = any

local THEMES = {
	{ wall = C.RoomTeal, sofa = C.Terracotta, rug = C.Mustard, accent = C.Teal },
	{ wall = C.Lilac, sofa = C.Teal, rug = C.Pink, accent = C.Navy },
	{ wall = C.Peach, sofa = C.Navy, rug = C.Teal, accent = C.Orange },
	{ wall = Color3.fromHex("#CDE3B0"), sofa = C.Mustard, rug = C.Terracotta, accent = C.Green },
	{ wall = C.PaleBlue, sofa = C.Red, rug = C.Cream, accent = C.Blue },
	{ wall = C.Mustard, sofa = C.Lilac, rug = C.Sky, accent = C.Pink },
}

local function pick<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

-- The builder's placeholder boxes named `name` (direct children): (local x, local z, storey, size).
-- Each one is destroyed; the caller builds the real piece on the returned spot.
local function takeAll(ctx: Ctx, name: string): { { x: number, z: number, s: number, size: Vector3 } }
	local out = {}
	local inv = ctx.F:Inverse()
	for _, p in ctx.site:GetChildren() do
		if p:IsA("BasePart") and p.Name == name then
			local l = inv * p.CFrame
			local base = l.Position.Y - p.Size.Y / 2
			local s = 1
			for k = ctx.storeys, 1, -1 do
				if base >= ctx.floors[k] - 0.75 then
					s = k
					break
				end
			end
			table.insert(out, { x = l.Position.X, z = l.Position.Z, s = s, size = p.Size })
			p:Destroy()
		end
	end
	table.sort(out, function(a, b)
		return if a.s ~= b.s then a.s < b.s else a.x < b.x
	end)
	return out
end

-- Swap each placeholder for fn: on its own spot when that's clear of the keep-outs (aisles, stairs,
-- rescue spots), else the nearest clear spot within ~6 studs (its FireStart still finds it: fires
-- light the nearest Flammable within GameConfig.FireStartSearch), else its own spot regardless.
local NUDGES = { { 0, 0 } }
for r = 1, 10 do
	for _, dxz in { { r, 0 }, { -r, 0 }, { 0, r }, { 0, -r }, { r, r }, { -r, r }, { r, -r }, { -r, -r } } do
		table.insert(NUDGES, dxz)
	end
end
local function swap(ctx: Ctx, name: string, fn: any, yaw: number, fw: number, fd: number, opts: any?, dz: number?): { any }
	local spots = takeAll(ctx, name)
	local placed = {}
	for _, sp in spots do
		local x0, z0 = sp.x, sp.z + (dz or 0)
		local px, pz = nil, nil
		local placer = ctx.placers[sp.s]
		for _, n in NUDGES do
			local r = Furnish_footprint(x0 + n[1], z0 + n[2], yaw, fw, fd)
			if r.x0 > -ctx.w / 2 + 0.5 and r.x1 < ctx.w / 2 - 0.5 and r.z0 > 0.5 and r.z1 < ctx.d - 0.5 and placer:fits(r) then
				px, pz = x0 + n[1], z0 + n[2]
				break
			end
		end
		if px and pz then
			placer:take(Furnish_footprint(px, pz, yaw, fw, fd))
			ctx:add(fn, ctx:at(px, ctx.floors[sp.s], pz, yaw), if opts then table.clone(opts) else {})
			sp.x, sp.z = px, pz
			table.insert(placed, sp)
		end
		-- (nowhere clear: left out, so it never blocks a stair or a rescue; its FireStart burns the
		-- nearest Flammable instead)
	end
	return placed
end

-- Walkways every storey keeps: a spine from the front door to the back, a hall from the stair landing
-- to the spine, and a strip from every rescue spot to the spine (BlockFiller shell: stairs up the left
-- wall rising toward +Z, flight length min(1.35 H, d - 4)).
local function keepWalkways(ctx: Ctx, spineX: number?)
	local w, d, H = ctx.w, ctx.d, ctx.H
	local sx = spineX or 0
	local L = math.min(H * 1.35, d - 4)
	local z0 = math.clamp(d - 3 - L, 2, 3.5)
	local z1 = z0 + L
	for s = 1, ctx.storeys do
		local placer = ctx.placers[s]
		placer:keep(Plan.span(sx - 2.2, 0, sx + 2.2, d - 3.2))
		if s > 1 then
			placer:keep(Plan.span(-w / 2, math.max(0.5, z1 - 1.5), sx + 2.2, math.min(d - 0.5, z1 + 3)))
		end
	end
	local inv = ctx.F:Inverse()
	for _, p in ctx.site:GetDescendants() do
		if p:IsA("BasePart") and p:HasTag("RescueSpawn") then
			local l = inv * p.CFrame
			for s = ctx.storeys, 1, -1 do
				if l.Position.Y - 1 >= ctx.floors[s] - 0.75 then
					ctx.placers[s]:keep(Plan.span(math.min(l.Position.X, sx), l.Position.Z - 1.6, math.max(l.Position.X, sx), l.Position.Z + 1.6))
					break
				end
			end
		end
	end
end

-- Ceiling underside of storey s for a gabled house (its ceiling slab hangs 0.5 below the eaves).
local function ceilingY(ctx: Ctx, s: number): number
	if s < ctx.storeys then
		return ctx.floors[s] + ctx.H - 0.6
	end
	return ctx.floors[s] + ctx.H - (if ctx.site:FindFirstChild("Ceiling") then 0.5 else 0)
end

local function light(ctx: Ctx, s: number, x: number, z: number, color: Color3?, on: boolean?)
	ctx:add(Kit.pendant, ctx:at(x, ceilingY(ctx, s), z), { color = color, light = on ~= false })
end

---------------------------------------------------------------------------------------------------
-- house
---------------------------------------------------------------------------------------------------
local EXTRAS = { "piano", "aquarium", "catTree", "reading" }

local function houseExtra(ctx: Ctx, s: number, x: number, z: number, kind: string, theme: any): boolean
	if kind == "piano" then
		return ctx:put(s, Kit.piano, x, z + 0.4, S, 5.2, 4.4, {}) ~= nil
	elseif kind == "aquarium" then
		return ctx:put(s, function(parent: Instance, cf: CFrame, _o: any)
			local m = Instance.new("Model")
			m.Name = "Aquarium"
			local stand = Kit.part(m, "TankStand", cf * CF(0, 1.2, 0), Vector3.new(5, 2.4, 2), C.Wood, { solid = true, fuel = 15 })
			Kit.part(m, "TankWater", cf * CF(0, 3.9, 0), Vector3.new(4.6, 3, 1.8), C.PaleBlue, { neon = true, tr = 0.35 })
			for k = 1, 3 do
				Kit.part(m, "Fish", cf * CF(-1.5 + k, 3.6 + (k % 2) * 0.6, 0), Vector3.new(0.6, 0.35, 0.15), Kit.Bright[k + 2])
			end
			m.PrimaryPart = stand
			m.Parent = parent
			return m
		end, x, z, S, 5, 2.4, {}) ~= nil
	elseif kind == "catTree" then
		return ctx:put(s, function(parent: Instance, cf: CFrame, _o: any)
			local m = Instance.new("Model")
			m.Name = "CatTree"
			local base = Kit.part(m, "CatBase", cf * CF(0, 0.3, 0), Vector3.new(3, 0.6, 3), C.Cream, { solid = true, fuel = 8 })
			Kit.part(m, "CatPost", cf * CF(0, 2.6, 0), Vector3.new(0.8, 4.4, 0.8), Color3.fromHex("#C99A62"), { fuel = 6 })
			Kit.part(m, "CatPerch", cf * CF(0.4, 4.9, 0), Vector3.new(2.4, 0.4, 2.4), C.Cream, { fuel = 6 })
			Kit.part(m, "CatToy", cf * CF(1.2, 4.2, 0), Vector3.new(0.4, 0.4, 0.4), C.Pink)
			m.PrimaryPart = base
			m.Parent = parent
			return m
		end, x, z, S, 3, 3, {}) ~= nil
	end
	if ctx:put(s, Kit.armchair, x, z + 0.5, S, 3.2, 3, { color = theme.accent }) then
		ctx:add(Kit.floorLamp, ctx:at(x + 2.6, ctx.floors[s], z + 1), {})
		return true
	end
	return false
end

local function house(ctx: Ctx)
	local rng = ctx.rng
	local w, d = ctx.w, ctx.d
	local theme = pick(rng, THEMES)
	local bedTheme = pick(rng, THEMES)
	local y1 = ctx.floors[1]
	keepWalkways(ctx)
	-- ground floor: living room around the sofa (front-right), TV toward the front wall
	local sofas = swap(ctx, "Sofa", Kit.sofa, N, 7.2, 3.6, { w = 7, color = theme.sofa, accent = theme.rug })
	for _, sp in sofas do
		local s = sp.s
		local y = ctx.floors[s]
		ctx:add(Kit.rug, ctx:at(sp.x, y, sp.z - 3.4), { w = 8, d = 5, color = theme.rug })
		ctx:put(s, Kit.coffeeTable, sp.x, sp.z - 3.4, N, 4, 2.4, {})
		ctx:put(s, Kit.tv, sp.x, sp.z - 6.8, S, 6, 2, { color = C.Wood })
		ctx:put(s, Kit.armchair, sp.x + 5.6, sp.z - 2.8, W, 3.2, 3, { color = theme.accent })
		ctx:put(s, Kit.floorLamp, sp.x - 4.4, sp.z + 0.6, N, 1.4, 1.4, {})
		light(ctx, s, sp.x, sp.z - 3.4, theme.accent)
	end
	local tables = swap(ctx, "Table", Kit.diningSet, N, 5.2, 6, { w = 4, n = 2, seat = theme.accent })
	for _, sp in tables do
		light(ctx, sp.s, sp.x, sp.z, C.Cream)
	end
	-- kitchen along the back wall: counter (stove + sink), cabinets above, fridge; tiles underfoot
	for _, sp in swap(ctx, "Counter", Kit.counter, N, 9, 2.6, { len = 9, stove = true, stoveX = 2.2, sink = true, sinkX = -2.2, color = pick(rng, { C.Cream, C.Sky, C.Mustard, C.Lilac }) }) do
		local y = ctx.floors[sp.s]
		ctx:add(Kit.wallCabinets, ctx:at(sp.x, y, d - 0.5, N), { w = 9, y = 7.3 })
		ctx:add(Kit.floorFinish, ctx:at(sp.x + 2, y, d - 3.6), { w = 14, d = 6, color = C.Tile, grid = 2, lines = C.TileB })
		light(ctx, sp.s, sp.x, d - 4, C.White)
	end
	swap(ctx, "Fridge", Kit.fridge, N, 3.2, 2.8, {})
	swap(ctx, "Bookshelf", Kit.bookshelf, N, 5, 1.6, { w = 5, h = 7 })
	-- front-left: one random extra; a doormat; a plant by the front window
	local extra = pick(rng, EXTRAS)
	for _, spot in { { -w * 0.12, 3 }, { -w * 0.2, d * 0.62 }, { w * 0.38, d * 0.62 } } do
		if houseExtra(ctx, 1, spot[1], spot[2], extra, theme) then
			break
		end
	end
	ctx:add(Kit.rug, ctx:at(0, y1, 2), { w = 3.6, d = 2, color = C.Red, pattern = "stripes" })
	ctx:put(1, Kit.plant, w / 2 - 1.8, 1.8, N, 2.4, 2.4, { color = theme.rug })
	ctx:add(Kit.wainscot, ctx:at((3 + w / 2 - 0.5) / 2, y1, 0.5, S), { w = w / 2 - 3.5, h = 2.6, color = theme.wall })
	ctx:add(Kit.picture, ctx:at(w / 2 - 0.5, y1, d * 0.25, W), { y = 6, kind = "photo" })
	ctx:add(Kit.picture, ctx:at(w / 2 - 0.5, y1, d * 0.75, W), { y = 6 })
	ctx:add(Kit.clock, ctx:at(-w * 0.1, y1, d - 0.5, N), { y = 8.2, rim = theme.accent })
	-- upstairs: the bedroom around the bed, the kids' corner round the bunk bed and desk
	if ctx.storeys >= 2 then
		local y2 = ctx.floors[2]
		for _, sp in swap(ctx, "Bed", Kit.bed, N, 5.2, 8.4, { w = 5, l = 8, color = bedTheme.sofa }) do
			ctx:add(Kit.rug, ctx:at(sp.x, y2, sp.z - 1), { w = 8, d = 6, color = bedTheme.rug })
			ctx:put(2, Kit.nightstand, sp.x - 3.6, sp.z + 3, N, 1.8, 1.6, { shade = bedTheme.accent })
			ctx:put(2, Kit.nightstand, sp.x + 3.6, sp.z + 3, N, 1.8, 1.6, { shade = bedTheme.accent })
			ctx:add(Kit.picture, ctx:at(sp.x, y2, d - 0.5, N), { y = 7.2, w = 3, h = 2, kind = "sea" })
			light(ctx, 2, sp.x, sp.z, bedTheme.accent)
		end
		swap(ctx, "Dresser", Kit.wardrobe, N, 5, 2.2, { w = 5, h = 3.6, color = bedTheme.accent:Lerp(C.White, 0.4) })
		ctx:put(2, Kit.wardrobe, w / 2 - 1.5, d - 4.5, W, 4, 2.2, { w = 4, h = 7, color = C.WoodLight })
		for _, sp in swap(ctx, "BunkBed", Kit.bunkBed, N, 7.6, 3.8, {}) do
			ctx:add(Kit.rug, ctx:at(sp.x, y2, sp.z - 4), { w = 6, d = 3.5, pattern = "dots" })
			ctx:put(2, Kit.toyBox, sp.x + 5.6, sp.z - 0.4, N, 3, 1.8, {})
			ctx:add(Kit.poster, ctx:at(sp.x, y2, d - 0.5, N), { y = 7.6, kind = "planets", w = 4, h = 2.4 })
		end
		swap(ctx, "Desk", Kit.desk, N, 4.4, 4.6, { w = 4.4 })
		-- bathroom corner at the front-right: tub under the window (no curtain), toilet, vanity
		local bx = w / 2 - 3.4
		ctx:add(Kit.floorFinish, ctx:at(w / 2 - 4.25, y2, 4.6), { w = 7.5, d = 8, color = C.White, grid = 1.5, lines = C.TileB })
		ctx:put(2, function(parent: Instance, cf: CFrame, o: any)
			local m = Kit.bathtub(parent, cf, o)
			local cur = m:FindFirstChild("BathCurtain")
			if cur then
				cur:Destroy()
			end
			return m
		end, bx, 2, N, 5.6, 3, { color = C.White })
		ctx:put(2, Kit.toilet, w / 2 - 1.6, 6.2, W, 1.6, 2.2, {})
		ctx:put(2, Kit.vanity, w / 2 - 0.5 - 1, 8.8, W, 3, 2, {})
		ctx:add(Kit.rug, ctx:at(bx, y2, 4.6), { w = 3, d = 1.6, color = C.PaleBlue, pattern = "stripes" })
		ctx:add(Kit.picture, ctx:at(-w / 2 + 0.5, y2, d * 0.75, E), { y = 6.5, kind = "photo" })
		light(ctx, 2, -w * 0.15, d * 0.4, C.Cream)
	end
end

---------------------------------------------------------------------------------------------------
-- apartment
---------------------------------------------------------------------------------------------------
local function apartment(ctx: Ctx)
	local rng = ctx.rng
	local w, d = ctx.w, ctx.d
	local stairEdge = -w / 2 + 10
	local bedX = math.min(w / 2 - 15, 14) -- the bedroom partition (between the 3rd and 4th front windows)
	keepWalkways(ctx)
	local sofas = swap(ctx, "Sofa", Kit.sofa, N, 7.2, 3.6, {})
	local themes: { [number]: any } = {}
	for s = 1, ctx.storeys do
		themes[s] = pick(rng, THEMES)
	end
	-- recolour the swapped sofas per flat
	for _, sp in sofas do
		local th = themes[sp.s]
		local y = ctx.floors[sp.s]
		ctx:add(Kit.rug, ctx:at(sp.x, y, sp.z - 3.4), { w = 8, d = 5, color = th.rug })
		ctx:put(sp.s, Kit.coffeeTable, sp.x, sp.z - 3.4, N, 4, 2.4, {})
		ctx:put(sp.s, Kit.tv, sp.x, sp.z - 6.8, S, 6, 2, {})
		ctx:put(sp.s, Kit.floorLamp, sp.x + 4.6, sp.z + 0.4, N, 1.4, 1.4, {})
		light(ctx, sp.s, sp.x, sp.z - 3, th.accent)
	end
	for _, sp in swap(ctx, "Table", Kit.diningSet, N, 5.2, 6, { w = 4, n = 2 }) do
		light(ctx, sp.s, sp.x, sp.z, C.Cream)
	end
	for s = 1, ctx.storeys do
		local y = ctx.floors[s]
		local th = themes[s]
		if s == 1 then
			-- lobby by the front door: mailboxes, a bench, a notice board, plants
			ctx:add(function(parent: Instance, cf: CFrame, _o: any)
				local m = Instance.new("Model")
				m.Name = "Mailboxes"
				local p = Kit.part(m, "MailboxBank", cf * CF(0, 4.2, -0.4), Vector3.new(5, 3, 0.8), C.Chrome)
				local g = Kit.gui(p, Enum.NormalId.Front, 20)
				for k = 0, 9 do
					Kit.rect(g, (k % 5) * 0.2 + 0.02, (k // 5) * 0.5 + 0.06, 0.16, 0.38, C.Steel, 0.05)
				end
				m.PrimaryPart = p
				m.Parent = parent
				return m
			end, ctx:at(-6, y, d - 0.5, N), {})
			ctx:put(1, Kit.bench, 6, d - 1.6, N, 6, 2, {})
			ctx:add(Kit.noticeBoard, ctx:at(2, y, d - 0.5, N), { w = 3, h = 2.4, y = 5.6, flyers = { "QUIET\nAFTER 10", "LOST\nKEYS", "YARD\nSALE", "NO\nPETS?!" } })
			ctx:put(1, Kit.plant, -3, 1.8, N, 2.4, 2.4, { size = 1.2 })
			ctx:put(1, Kit.plant, 3, 1.8, N, 2.4, 2.4, { size = 1.2 })
			ctx:add(Kit.rug, ctx:at(0, y, 2.4), { w = 4, d = 2.4, color = C.Red, pattern = "border" })
		else
			-- kitchenette along the back wall (west of the bedroom), the bedroom behind a partition
			local kx = stairEdge + 6
			local kitchen = { len = 8, stove = true, stoveX = 2, sink = true, sinkX = -2, color = th.accent:Lerp(C.White, 0.5) }
			if ctx:put(s, Kit.counter, kx, d - 1.4, N, 8, 2.6, kitchen) then
				ctx:add(Kit.wallCabinets, ctx:at(kx, y, d - 0.5, N), { w = 8, y = 6.6 })
				ctx:put(s, Kit.fridge, kx + 5.8, d - 1.5, N, 3.2, 2.8, {})
			elseif ctx:put(s, Kit.counter, kx + 1, 1.4, S, 8, 2.6, kitchen) then
				-- shallow block: the back wall is the stairs' landing, so the kitchenette goes up front
				ctx:put(s, Kit.fridge, kx + 6.8, 1.5, S, 3.2, 2.8, {})
			end
			Furnish_partition(ctx, s, bedX, 0.5, bedX, d - 0.5, { { c = d * 0.75, w = 4.6, top = 7.5 } }, th.wall:Lerp(C.Black, 0.1), th.wall)
			ctx.placers[s]:keep(Plan.span(bedX - 3.5, d * 0.75 - 2.5, bedX + 3.5, d * 0.75 + 2.5))
			ctx.placers[s]:keep(Plan.span(bedX - 0.6, 0, bedX + 0.6, d))
			local bx = (bedX + w / 2) / 2 + 1
			if ctx:put(s, Kit.bed, bx, d - 5.4, N, 5.4, 8.4, { w = 5, l = 8, color = th.sofa }) then
				ctx:put(s, Kit.nightstand, bx - 3.6, d - 2.2, N, 1.8, 1.6, {})
				ctx:add(Kit.rug, ctx:at(bx, y, d - 7), { w = 7, d = 5, color = th.rug })
			end
			ctx:put(s, Kit.wardrobe, w / 2 - 1.6, d * 0.25, W, 4, 2.2, { w = 4, h = 7 })
			ctx:add(Kit.picture, ctx:at(bedX + 0.5, y, d * 0.4, E), { y = 5.6 })
			light(ctx, s, bx, d * 0.5, th.accent)
			ctx:add(Kit.picture, ctx:at(-w * 0.05, y, d - 0.5, N), { y = 5.6, kind = "photo" })
			ctx:put(s, Kit.plant, bedX - 1.8, 2, N, 2.4, 2.4, { color = th.rug })
		end
		ctx:add(Kit.wainscot, ctx:at((stairEdge + bedX) / 2, y, d - 0.5, N), { w = bedX - stairEdge, h = 2.6, color = th.wall })
	end
end

---------------------------------------------------------------------------------------------------
-- shop / diner
---------------------------------------------------------------------------------------------------
local GOODS: { [string]: { Color3 } } = {
	DONUT = { C.Pink, Color3.fromHex("#7A4A2A"), C.Mustard, C.White },
	BAGEL = { Color3.fromHex("#C99A62"), C.Mustard, C.Cream },
	PIZZA = { C.Red, C.Mustard, C.Orange },
	TACO = { C.Mustard, C.Green, C.Red },
	NOODLE = { C.Mustard, C.Red, C.White },
	TOY = Kit.Bright,
	BOOK = { C.Red, C.Teal, C.Navy, C.Mustard, C.Green },
	PET = { C.Green, Color3.fromHex("#7A4A2A"), C.Sky, C.Orange },
	SOCK = { C.Pink, C.Lilac, C.Sky, C.Mustard },
	TOOL = { C.Red, C.Steel, C.Mustard, C.Iron },
	CHEESE = { C.Mustard, C.Orange, C.Cream },
	FISH = { C.Sky, C.Blue, C.Orange },
	SPUD = { Color3.fromHex("#C99A62"), C.Mustard, C.Green },
}

local function shopName(ctx: Ctx): string
	for _, p in ctx.site:GetChildren() do
		if p.Name == "Sign" and p:IsA("BasePart") then
			local t = p:FindFirstChildWhichIsA("SurfaceGui")
			local l = t and t:FindFirstChildWhichIsA("TextLabel")
			if l then
				return l.Text
			end
		end
	end
	return "SHOP"
end

local function goodsFor(name: string): { Color3 }
	local up = string.upper(name)
	for key, cols in GOODS do
		if string.find(up, key, 1, true) then
			return cols
		end
	end
	return Kit.Bright
end

local function shop(ctx: Ctx)
	local rng = ctx.rng
	local w, d = ctx.w, ctx.d
	local y = ctx.floors[1]
	local name = shopName(ctx)
	local goods = goodsFor(name)
	local theme = pick(rng, THEMES)
	ctx:add(Kit.floorFinish, ctx:at(0, y, d / 2), { w = w - 1, d = d - 1, color = C.Cream, grid = 3, lines = C.TileB })
	swap(ctx, "Counter", Kit.checkout, N, 7, 3, { w = 7, color = theme.accent })
	for _, sp in takeAll(ctx, "Shelf") do
		local back = sp.z > d * 0.7
		ctx.placers[1]:take(Furnish_footprint(sp.x, sp.z, N, sp.size.X, 1.8))
		ctx:add(Kit.shopShelf, ctx:at(sp.x, y, sp.z, N), { w = sp.size.X, h = sp.size.Y, goods = goods, oneSided = back, color = theme.wall:Lerp(C.White, 0.45) })
	end
	swap(ctx, "Crates", Kit.boxes, N, 3.6, 2.6, {})
	-- aisles of gondolas over the shop floor (they skip the spine, the rescue spots and the counter),
	-- a cooler on the side wall, a plant and a doormat
	keepWalkways(ctx)
	for _, c in Plan.grid(-w / 2 + 2, w / 2 - 5, 5.5, d - 3.5, 7.2, 3.8) do
		ctx:put(1, Kit.shopShelf, c[1], c[2], N, 6.4, 1.8, { w = 6, h = 4.5, goods = goods, color = theme.wall:Lerp(C.White, 0.45) })
	end
	ctx:put(1, Kit.cooler, w / 2 - 1.6, d - 4.4, W, 4, 2.6, { w = 4 })
	ctx:put(1, Kit.plant, -w / 2 + 1.8, 1.8, N, 2.4, 2.4, { color = theme.rug })
	ctx:add(Kit.rug, ctx:at(0, y, 2), { w = 4, d = 2.2, color = theme.accent, pattern = "stripes" })
	ctx:add(Kit.banner, ctx:at(0, y, d - 0.5, N), { w = math.min(14, w * 0.5), y = 8.4, h = 1.6, text = name, bg = theme.accent, fg = C.White })
	ctx:add(Kit.poster, ctx:at(-w / 2 + 0.5, y, d * 0.6, E), { y = 6.4, text = "SALE!\n50% OFF", bg = C.Mustard, fg = C.Red })
	-- an OPEN sign glowing just inside the right shop window
	local open = Kit.part(ctx.root, "OpenSign", ctx:at(w * 0.28, y + 5.2, 0.9), Vector3.new(2.8, 1.1, 0.12), C.Pink, { neon = true })
	Kit.text(Kit.gui(open, Enum.NormalId.Front, 30, true), 0.05, 0.05, 0.9, 0.9, "OPEN", C.White)
	Kit.text(Kit.gui(open, Enum.NormalId.Back, 30, true), 0.05, 0.05, 0.9, 0.9, "OPEN", C.White)
	for _, lx in { -w / 4, w / 4 } do
		ctx:add(Kit.ceilingLight, ctx:at(lx, y + ctx.H, d / 2), { len = 6, range = 20 })
	end
end

local function diner(ctx: Ctx)
	local rng = ctx.rng
	local w, d = ctx.w, ctx.d
	local y = ctx.floors[1]
	-- checker floor, booths along the front glass, a counter + stools, a jukebox, the menu
	local f = ctx:add(Kit.floorFinish, ctx:at(0, y, d / 2), { w = w - 1, d = d - 1, color = C.White })
	local g = Kit.gui(f.PrimaryPart :: BasePart, Enum.NormalId.Top, 4)
	local nx, nz = math.floor((w - 1) / 2), math.floor((d - 1) / 2)
	for i = 0, nx - 1 do
		for k = 0, nz - 1 do
			if (i + k) % 2 == 0 then
				Kit.rect(g, i / nx, k / nz, 1 / nx, 1 / nz, C.Ink)
			end
		end
	end
	local boothCol = pick(rng, { C.Red, C.Teal, C.Pink })
	for _, sp in takeAll(ctx, "Booth") do
		if math.abs(sp.x) < 6 then
			-- the builder's middle booth sits in front of the door: move it in by the side wall
			ctx:put(1, Kit.booth, -w / 2 + 3.2, d * 0.5, W, 5.2, 6.6, { color = boothCol })
		else
			local z = math.max(sp.z, 3.6)
			ctx.placers[1]:take(Furnish_footprint(sp.x, z, N, 5.2, 6.6))
			ctx:add(Kit.booth, ctx:at(sp.x, y, z, N), { color = boothCol })
		end
	end
	for _, sp in swap(ctx, "Counter", Kit.counter, N, 8.4, 2.8, { len = 8, color = boothCol, top = C.Cream }) do
		for k = -1, 1 do
			ctx:put(1, Kit.stool, sp.x + k * 2.6, sp.z - 2.4, N, 1.6, 1.6, { color = boothCol })
		end
	end
	for _, sp in takeAll(ctx, "Shelf") do
		ctx.placers[1]:take(Furnish_footprint(sp.x, sp.z, N, sp.size.X, 2.6))
		ctx:add(Kit.counter, ctx:at(sp.x, y, sp.z, N), { len = sp.size.X, sink = true, color = C.Steel, top = C.Chrome })
	end
	swap(ctx, "Crates", Kit.boxes, N, 3.6, 2.6, {})
	ctx:put(1, Kit.jukebox, w / 2 - 1.6, d * 0.45, W, 3, 2.2, {})
	local menu = Kit.part(ctx.root, "MenuBoard", ctx:at(0, y + 8, d - 0.65), Vector3.new(8, 2.4, 0.2), C.Chalk)
	Kit.text(Kit.gui(menu, Enum.NormalId.Front, 30), 0.03, 0.05, 0.94, 0.9, "BURGER  $2   FRIES  $1\nSHAKE  $2   PIE  $1", C.White, Enum.Font.PermanentMarker)
	ctx:add(Kit.poster, ctx:at(-w / 2 + 0.5, y, d * 0.5, E), { y = 6.4, kind = "food" })
	for _, lx in { -w / 3, 0, w / 3 } do
		light(ctx, 1, lx, d * 0.45, boothCol)
	end
end

function Home.register(Furnish: any)
	Furnish_partition = Furnish.partition
	Furnish_footprint = Furnish.footprint
	Furnish.Layouts.house = house
	Furnish.Layouts.apartment = apartment
	Furnish.Layouts.shop = shop
	Furnish.Layouts.diner = diner
end

return Home
