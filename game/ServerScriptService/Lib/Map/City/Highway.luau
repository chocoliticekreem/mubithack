--!strict
-- Highway [owner: CityBuilder]. Highway 67 set dressing (the road itself is drawn by CityBuilder from
-- the road graph): the Ridge Tunnel (a grassy hill the west highway runs through; walls, roof, lit
-- ceiling strips, portals with name boards) and overhead exit gantries before every junction where an
-- avenue leaves the highway. All of it clears a fire truck (9.6 tall + light bar): tunnel roof and
-- gantry boards start TruckClearance above the road.
--
--   Highway.blocked(cfg): { Rect }   -- ground the tunnel hill covers (no lamps/trees/fields there)
--   Highway.build(ctx, parent)       ctx: { cfg, plan, rng: Random }
local SK = require(script.Parent:WaitForChild("SiteKit") :: ModuleScript) :: any

local Highway = {}

local C = SK.C
local V = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles

local CLEAR = 22 -- tunnel roof underside / gantry board bottom above the road
local WALL = 4
local HILL = 44 -- hill flank width either side of the tunnel walls

local function tunnelRect(cfg: any): any?
	local t = cfg.Tunnel
	if not t then
		return nil
	end
	local hw = cfg.HighwayWidth / 2
	local reach = hw + 3 + WALL + HILL
	return { x0 = t.x - reach, z0 = t.z0, x1 = t.x + reach, z1 = t.z1 }
end

function Highway.blocked(cfg: any): { any }
	local r = tunnelRect(cfg)
	return if r then { r } else {}
end

local function tunnel(ctx: any, parent: Instance)
	local cfg = ctx.cfg
	local t = cfg.Tunnel
	if not t then
		return
	end
	local m = Instance.new("Model")
	m.Name = "RidgeTunnel"
	m:SetAttribute("DisplayName", t.name or "Ridge Tunnel")
	local hw = cfg.HighwayWidth / 2 + 3 -- inner face of the walls
	local len = t.z1 - t.z0
	local cz = (t.z0 + t.z1) / 2
	local y0 = cfg.RoadY
	local rock = Color3.fromHex("#9A958C")
	local grass = Color3.fromHex("#6E9E45")
	for _, s in { -1, 1 } do
		-- side wall
		SK.part(m, "TunnelWall", CF(t.x + s * (hw + WALL / 2), (cfg.GroundY + y0 + CLEAR) / 2, cz), V(WALL, y0 + CLEAR - cfg.GroundY, len), rock, { material = Enum.Material.Concrete })
		-- hill flank sloping down to the ground (wedge: tall side toward the tunnel)
		SK.wedge(m, "HillFlank", CF(t.x + s * (hw + WALL + HILL / 2), cfg.GroundY + (CLEAR + 4) / 2, cz) * ANG(0, math.rad(if s > 0 then -90 else 90), 0), V(len, CLEAR + 4, HILL), grass, {
			material = Enum.Material.Grass,
		})
	end
	-- roof slab + grassy hill top
	SK.part(m, "TunnelRoof", CF(t.x, y0 + CLEAR + 1, cz), V(2 * (hw + WALL), 2, len), rock, { material = Enum.Material.Concrete })
	SK.part(m, "HillTop", CF(t.x, y0 + CLEAR + 3, cz), V(2 * (hw + WALL), 2, len - 8), grass, { material = Enum.Material.Grass })
	-- ceiling light strips (neon) + a couple of real lights
	for _, s in { -1, 1 } do
		SK.part(m, "CeilingStrip", CF(t.x + s * 8, y0 + CLEAR - 0.2, cz), V(1, 0.3, len - 6), Color3.fromHex("#FFE2A8"), {
			neon = true,
			collide = false,
			cast = false,
			query = false,
		})
	end
	for _, f in { 0.25, 0.75 } do
		local holder = SK.part(m, "TunnelLight", CF(t.x, y0 + CLEAR - 0.6, t.z0 + f * len), V(2, 0.4, 2), C.MetalDark, { collide = false, query = false })
		local light = Instance.new("PointLight")
		light.Color = Color3.fromHex("#FFD9A0")
		light.Range = 60
		light.Brightness = 1.2
		light.Shadows = false
		light.Parent = holder
	end
	-- portals: a concrete frame band + name board over each mouth (above the clearance)
	for _, e in { { t.z0, -1 }, { t.z1, 1 } } do
		local z = e[1]
		SK.part(m, "Portal", CF(t.x, y0 + CLEAR + 2.5, z + e[2] * 0.6), V(2 * (hw + WALL) + 4, 5, 1.2), Color3.fromHex("#B7B1A8"), {
			material = Enum.Material.Concrete,
		})
		local board = SK.part(m, "PortalSign", CF(t.x, y0 + CLEAR + 2.5, z + e[2] * 1.3), V(30, 3.6, 0.3), Color3.fromHex("#2E7D4F"))
		local face = if e[2] < 0 then Enum.NormalId.Front else Enum.NormalId.Back
		SK.sign(board, string.upper(t.name or "Ridge Tunnel"), face, C.Trim)
		-- hazard stripes on the wall ends
		for _, s in { -1, 1 } do
			SK.part(m, "WallStripe", CF(t.x + s * (hw - 0.2), y0 + 4, z - e[2] * 1.5), V(0.4, 8, 3), Color3.fromHex("#E9C46A"), { collide = false })
		end
	end
	m.Parent = parent
end

-- Overhead exit gantries on Highway 67 before every junction with an avenue.
local function gantries(ctx: any, parent: Instance)
	local cfg = ctx.cfg
	local lines = ctx.plan.lines
	local names = ctx.streetNames
	local hw = cfg.HighwayWidth / 2
	local y0 = cfg.RoadY
	local m = Instance.new("Model")
	m.Name = "ExitGantries"
	local blocked = Highway.blocked(cfg)
	local function inBlocked(x: number, z: number): boolean
		for _, r in blocked do
			if x > r.x0 and x < r.x1 and z > r.z0 - 40 and z < r.z1 + 40 then
				return true
			end
		end
		return false
	end
	local n = 0
	for _, hi in { 1, #lines } do
		for ai = 2, #lines - 1 do
			for _, axis in { "x", "z" } do
				-- highway along `axis`-line hi; the avenue crossing it is the other axis' line ai
				local hl, al = lines[hi], lines[ai]
				local avenueName = if axis == "x" then names.lineZ[ai] else names.lineX[ai]
				for _, dirSign in { -1, 1 } do
					-- traffic approaching the junction from dirSign side; the gantry stands 70 studs out
					local along = al + dirSign * 70
					local x, z = if axis == "x" then hl else along, if axis == "x" then along else hl
					if not inBlocked(x, z) then
						n += 1
						local acrossDir = if axis == "x" then V(1, 0, 0) else V(0, 0, 1)
						local p = V(x, 0, z)
						for _, s in { -1, 1 } do
							local q = p + acrossDir * s * (hw + 5)
							SK.part(m, "GantryPost", CF(q.X, y0 + (CLEAR + 7) / 2, q.Z), V(1.2, CLEAR + 7, 1.2), C.MetalDark)
						end
						local faceDir = if axis == "x" then V(0, 0, dirSign) else V(dirSign, 0, 0)
						local beamCf = CFrame.lookAt(V(x, y0 + CLEAR + 6, z), V(x, y0 + CLEAR + 6, z) + faceDir)
						SK.part(m, "GantryBeam", beamCf, V(2 * hw + 12, 1, 1), C.MetalDark)
						local board = SK.part(m, "ExitSign", beamCf * CF(0, -2.6, -0.8), V(26, 5, 0.4), Color3.fromHex("#2E7D4F"))
						-- the board's Front faces the traffic coming toward the junction
						SK.sign(board, `EXIT  {string.upper(avenueName)}`, Enum.NormalId.Front, C.Trim)
					end
				end
			end
		end
	end
	m:SetAttribute("Count", n)
	m.Parent = parent
end

function Highway.build(ctx: any, parent: Instance): Model
	local m = Instance.new("Model")
	m.Name = "Highway67"
	for _, step in { tunnel, gantries } do
		local ok, err = pcall(step, ctx, m)
		if not ok then
			warn(`[Highway] {err}`)
		end
	end
	m.Parent = parent
	return m
end

return Highway
