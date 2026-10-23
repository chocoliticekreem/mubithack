--!strict
-- Greenbelt [owner: CityBuilder]. Dresses the open ground between the neighbourhoods (cheap, few
-- parts): Mill Pond (the lake the creek widens into, plan.lake) with a dock, ducks, reeds and a
-- bankside path; pocket parks in the corners where the avenue corridors meet (a fountain plaza on
-- the hub side, groves elsewhere); hedgerows + tree clumps along Highway 67's inner verge; striped
-- crop fields on the outskirts beyond the highway.
--
--   Greenbelt.build(ctx, parent)   ctx: { cfg, plan, rng: Random, clear: (Vector3, number) -> boolean }
local SK = require(script.Parent:WaitForChild("SiteKit") :: ModuleScript) :: any
local BlockFiller = require(script.Parent:WaitForChild("BlockFiller") :: ModuleScript) :: any

local Greenbelt = {}

local C = SK.C
local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local GY = 0.72

local PATH = Color3.fromHex("#D9C9A8")

local function slab(parent: Instance, name: string, x0: number, z0: number, x1: number, z1: number, top: number, color: Color3, mat: Enum.Material?)
	if x1 - x0 < 0.5 or z1 - z0 < 0.5 then
		return
	end
	SK.part(parent, name, CF((x0 + x1) / 2, (top - 0.1) / 2, (z0 + z1) / 2), V(x1 - x0, top + 0.1, z1 - z0), color, { material = mat })
end

local function duck(parent: Instance, cf: CFrame)
	local m = Instance.new("Model")
	m.Name = "Duck" -- PhysicsFxService knockable name
	SK.ball(m, "Body", cf, 1.8, Color3.fromHex("#F2D13C"))
	SK.ball(m, "Head", cf * CF(0, 1, -0.7), 1.1, Color3.fromHex("#F2D13C"))
	SK.part(m, "Beak", cf * CF(0, 0.95, -1.35), V(0.45, 0.22, 0.6), Color3.fromHex("#E76F51"))
	m:AddTag("Knockable")
	m.Parent = parent
end

-- Mill Pond: bank path round it, a dock on the west bank, ducks, reeds, benches, willows.
local function pond(ctx: any, parent: Instance)
	local lk = ctx.plan.lake
	if not lk then
		return
	end
	local rng: Random = ctx.rng
	local m = Instance.new("Model")
	m.Name = "MillPond"
	m:SetAttribute("DisplayName", "Mill Pond")
	local cfg = ctx.cfg
	local waterY = cfg.GroundY - 2
	-- sandy bank path (west + east banks; north/south ends meet the creek)
	slab(m, "BankPath", lk.x0 - 6, lk.z0 - 4, lk.x0, lk.z1 + 4, GY - 0.6, PATH)
	slab(m, "BankPath", lk.x1, lk.z0 - 4, lk.x1 + 6, lk.z1 + 4, GY - 0.6, PATH)
	-- the dock: planks out over the water from the west bank, with a goofy life ring
	local dz = (lk.z0 + lk.z1) / 2
	SK.part(m, "Dock", CF(lk.x0 + 10, cfg.GroundY + 0.2, dz), V(22, 0.6, 7), C.Wood)
	for _, s in { -1, 1 } do
		SK.part(m, "DockPost", CF(lk.x0 + 20, cfg.GroundY - 1.5, dz + s * 3), V(0.8, 4.5, 0.8), C.Trunk)
	end
	SK.part(m, "LifeRingPost", CF(lk.x0 + 20, cfg.GroundY + 2.5, dz - 3.2), V(0.5, 4, 0.5), C.Trim)
	local ring = SK.cyl(m, "LifeRing", CF(lk.x0 + 20, cfg.GroundY + 3.6, dz - 3.5) * ANG(math.rad(90), 0, 0), 0.6, 3, C.Red, { collide = false })
	local _ = ring
	-- a rowboat tied to the dock
	SK.part(m, "Rowboat", CF(lk.x0 + 18, waterY + 0.6, dz + 7), V(4, 1.4, 10), Color3.fromHex("#3D5A80"))
	-- ducks paddling about (knockable)
	for _ = 1, 6 do
		duck(m, CF(rng:NextNumber(lk.x0 + 26, lk.x1 - 8), waterY + 0.9, rng:NextNumber(lk.z0 + 8, lk.z1 - 8)) * ANG(0, rng:NextNumber(0, 6.28), 0))
	end
	-- reeds along the banks (one cluster part each)
	for k = 1, 6 do
		local east = k % 2 == 0
		local x = if east then lk.x1 - 2 else lk.x0 + 2
		local z = lk.z0 + (k - 0.5) * (lk.z1 - lk.z0) / 6
		if math.abs(z - dz) > 12 then
			SK.part(m, "Reeds", CF(x, waterY + 2, z), V(3, 5, 8), Color3.fromHex("#6E8B3D"), { collide = false, cast = false })
		end
	end
	-- benches + willows on the east bank (the side away from the avenue)
	for k = 1, 3 do
		local z = lk.z0 + k * (lk.z1 - lk.z0) / 4
		BlockFiller.parkBench(m, CFrame.lookAt(V(lk.x1 + 3, GY - 0.6, z), V(lk.x1 - 5, GY - 0.6, z)))
		BlockFiller.tree(m, CF(lk.x1 + 6, GY - 0.6, z + 14), rng, 1.3)
	end
	local sign = SK.part(m, "PondSign", CF(lk.x0 - 3, cfg.GroundY + 6, lk.z0 + 10) * ANG(0, math.rad(90), 0), V(12, 3.5, 0.4), C.Wood)
	SK.sign(sign, "MILL POND (NO SWIMMING TRUCKS)", Enum.NormalId.Front, C.Trim)
	SK.sign(sign, "MILL POND (NO SWIMMING TRUCKS)", Enum.NormalId.Back, C.Trim)
	m.Parent = parent
end

-- in the creek / pond, or on ground something else covers (ctx.blocked: the tunnel hill)
local function wet(ctx: any, x0: number, z0: number, x1: number, z1: number): boolean
	for _, rv in ctx.plan.river do
		if x1 > rv.x0 - 4 and x0 < rv.x1 + 4 and z1 > rv.z0 - 4 and z0 < rv.z1 + 4 then
			return true
		end
	end
	for _, rv in ctx.blocked or {} do
		if x1 > rv.x0 and x0 < rv.x1 and z1 > rv.z0 and z0 < rv.z1 then
			return true
		end
	end
	return false
end

-- Pocket parks in the open corners where two avenue corridors meet.
local function corners(ctx: any, parent: Instance)
	local cfg = ctx.cfg
	local rng: Random = ctx.rng
	local lines = ctx.plan.lines
	local m = Instance.new("Model")
	m.Name = "PocketParks"
	local roadHalf = cfg.AvenueWidth / 2
	local inset = roadHalf + 10 -- clear of the traffic-light poles and signposts at the crossing
	for i = 2, #lines - 1 do
		for j = 2, #lines - 1 do
			local gx, gz = lines[i], lines[j]
			for _, sx in { -1, 1 } do
				for _, sz in { -1, 1 } do
					-- the square between the crossing and the neighbourhood corner diagonally off it
					local function edge(g: number, sgn: number): number
						local c = g + sgn * cfg.CellSize / 2 -- that cell's centre on this axis
						return c - sgn * cfg.DistrictHalf - sgn * 6
					end
					local ax, bx = gx + sx * inset, edge(gx, sx)
					local az, bz = gz + sz * inset, edge(gz, sz)
					local x0, x1 = math.min(ax, bx), math.max(ax, bx)
					local z0, z1 = math.min(az, bz), math.max(az, bz)
					if x1 - x0 >= 40 and z1 - z0 >= 40 and not wet(ctx, x0, z0, x1, z1) then
						local cx, cz = (x0 + x1) / 2, (z0 + z1) / 2
						local hub = math.abs(cx) < cfg.CellSize / 2 and math.abs(cz) < cfg.CellSize / 2
						slab(m, "ParkLawn", x0, z0, x1, z1, GY - 0.02, Color3.fromHex("#76AE4A"), Enum.Material.Grass)
						-- a diagonal-ish path: two crossing strips
						slab(m, "ParkPath", cx - 3, z0, cx + 3, z1, GY + 0.02, PATH)
						slab(m, "ParkPath", x0, cz - 3, x1, cz + 3, GY + 0.02, PATH)
						if hub then
							-- fountain plaza by downtown
							SK.cyl(m, "FountainRim", CF(cx, GY + 1, cz), 2, 18, C.Concrete)
							SK.cyl(m, "FountainWater", CF(cx, GY + 1.6, cz), 1.4, 16, C.Water, { material = Enum.Material.Glass, transparency = 0.25 })
							SK.cyl(m, "FountainSpout", CF(cx, GY + 4, cz), 5, 2.2, C.Concrete)
							for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
								local p = V(cx + d[1] * 14, GY, cz + d[2] * 14)
								BlockFiller.parkBench(m, CFrame.lookAt(p, V(cx, GY, cz)))
							end
						end
						for _, q in { { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 } } do
							local p = V(cx + q[1] * (x1 - x0) * 0.28, GY, cz + q[2] * (z1 - z0) * 0.28)
							if ctx.clear(p, 10) then
								BlockFiller.tree(m, CF(p), rng, 1.25)
							end
						end
						if not hub then
							BlockFiller.trashCan(m, CF(cx + 5, GY, cz + 5))
						end
					end
				end
			end
		end
	end
	m.Parent = parent
end

-- Highway 67's inner verge: one long hedgerow per stretch between the gate streets + tree clumps;
-- beyond the highway, striped crop fields out to the world edge.
local function outskirts(ctx: any, parent: Instance)
	local cfg = ctx.cfg
	local rng: Random = ctx.rng
	local b = cfg.Bounds
	local lines = ctx.plan.lines
	local hw = cfg.HighwayWidth / 2
	local cell = cfg.CellSize
	local m = Instance.new("Model")
	m.Name = "Outskirts"
	local crops = { Color3.fromHex("#E2C35A"), Color3.fromHex("#8DBE52"), Color3.fromHex("#D98B3A"), Color3.fromHex("#B5C95A"), Color3.fromHex("#9C7B4A") }
	for _, hl in { 1, #lines } do
		local line = lines[hl]
		local out = if hl == 1 then -1 else 1 -- outward sign
		for _, axis in { "x", "z" } do
			-- stretches between everything that joins the highway: gate streets (cell centres), the
			-- avenues, and the corners
			local stops = { lines[1] + hw + 30 }
			local joins = {}
			for k = 1, 3 do
				table.insert(joins, { -cell + (k - 1) * cell, 40 })
			end
			for k = 2, #lines - 1 do
				table.insert(joins, { lines[k], hw + 30 })
			end
			table.sort(joins, function(a, b)
				return a[1] < b[1]
			end)
			for _, j in joins do
				table.insert(stops, j[1] - j[2])
				table.insert(stops, j[1] + j[2])
			end
			table.insert(stops, lines[#lines] - hw - 30)
			for k = 1, #stops - 1, 2 do
				local a0, a1 = stops[k], stops[k + 1]
				-- inner verge hedgerow (2 studs in from the verge trees)
				local across = line - out * (hw + 12)
				local hx0, hx1, hz0, hz1
				if axis == "x" then
					hx0, hx1, hz0, hz1 = across - 1.5, across + 1.5, a0, a1
				else
					hx0, hx1, hz0, hz1 = a0, a1, across - 1.5, across + 1.5
				end
				if not wet(ctx, hx0, hz0, hx1, hz1) then
					SK.part(m, "Hedgerow", CF((hx0 + hx1) / 2, GY + 1.6, (hz0 + hz1) / 2), V(hx1 - hx0, 3.6, hz1 - hz0), Color3.fromHex("#4F7A3A"), {
						material = Enum.Material.Grass,
					})
				end
				-- outskirts fields beyond the highway: stripes across the stretch
				local f0 = line + out * (hw + 10)
				local f1 = (if out > 0 then (if axis == "x" then b.maxX else b.maxZ) else (if axis == "x" then b.minX else b.minZ)) - out * 8
				local n = math.max(1, math.floor((a1 - a0) / 70))
				for s = 1, n do
					local s0 = a0 + (s - 1) * (a1 - a0) / n + 2
					local s1 = a0 + s * (a1 - a0) / n - 2
					local c0, c1 = math.min(f0, f1), math.max(f0, f1)
					local x0, x1, z0, z1
					if axis == "x" then
						x0, x1, z0, z1 = c0, c1, s0, s1
					else
						x0, x1, z0, z1 = s0, s1, c0, c1
					end
					if not wet(ctx, x0, z0, x1, z1) then
						SK.part(m, "OutField", CF((x0 + x1) / 2, GY - 0.3, (z0 + z1) / 2), V(x1 - x0, 1.2, z1 - z0), crops[rng:NextInteger(1, #crops)], {
							material = Enum.Material.Grass,
							cast = false,
						})
					end
				end
				-- a clump of pines on the verge mid-stretch
				local mid = (a0 + a1) / 2
				for t = -1, 1 do
					local c = line - out * (hw + 24 + rng:NextNumber(0, 30))
					local p = if axis == "x" then V(c, GY, mid + t * 14) else V(mid + t * 14, GY, c)
					if ctx.clear(p, 12) then
						BlockFiller.pine(m, CF(p), rng, 1.3)
					end
				end
			end
		end
	end
	m.Parent = parent
end

function Greenbelt.build(ctx: any, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = "Greenbelt"
	for _, step in { pond, corners, outskirts } do
		local ok, err = pcall(step, ctx, m)
		if not ok then
			warn(`[Greenbelt] {err}`)
		end
	end
	m.Parent = parent
	return m
end

return Greenbelt
