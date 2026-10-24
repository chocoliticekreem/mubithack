--!strict
-- Interiors/Furnish [owner: interiors]. Builds a mission site's interior when a run takes the site:
-- MapService:BindSite calls Furnish.site(site) BEFORE it fires InstanceBuilt, so FireService indexes the
-- new Flammable furniture with the run. The pristine snapshot MapService keeps is taken before this, so
-- RebuildSite swaps in a bare building again and the idle city pays nothing (part budget).
--
--   Furnish.site(site: Model) -> (parts: number, ms: number)   no-op (0) on a site already furnished
--   Furnish.Layouts[kind] = fn(ctx)                           kind = site attr "Interior"
-- Sites opt in with attrs (BlockFiller sets them): Interior = "school" | ..., InteriorFrame (CFrame:
-- the building's front-centre on the ground, -Z = street), InteriorW, InteriorD, InteriorH (storey
-- height), InteriorStoreys, InteriorFloorY (first floor surface, local y). A location-builder district
-- (attr LocationId = <id>) is furnished by Lib/Map/Locations/<id>Builder.Furnish(model) when it has one.
-- Writes: Model "Interior" under the site (everything built here), site attrs Furnished = true,
-- InteriorParts; counter interior_parts. Furniture never covers a door, the stairs, a RescueSpawn or a
-- jump window (keep-outs read from the site, Interiors/Plan placer).
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Names = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Names") :: ModuleScript)
local Plan = require(script.Parent:WaitForChild("Plan") :: ModuleScript)
local Kit = require(script.Parent:WaitForChild("Kit") :: ModuleScript)
local Districts = require(script.Parent:WaitForChild("Districts") :: ModuleScript) :: any

local Furnish = {}
Furnish.Layouts = {} :: { [string]: (any) -> () }
Furnish.Debug = false -- true: Furnish.Misses lists every floor item a keep-out refused (Studio checks)
Furnish.Misses = {} :: { string }

local C = Kit.C
local CF = CFrame.new
local ANG = CFrame.Angles
local V = Vector3.new
local R90 = math.rad(90)

-- yaw so that an item's -Z faces: +X (east), -X (west), +Z (back), -Z (street)
local FACE = { E = -R90, W = R90, S = math.pi, N = 0 }
Furnish.FACE = FACE

local function hash(s: string): number
	local h = 0
	for i = 1, #s do
		h = (h * 31 + string.byte(s, i)) % 1000003
	end
	return h
end

local function count(name: string, n: number)
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count(name, n)
	end)
end

---------------------------------------------------------------------------------------------------
-- context
---------------------------------------------------------------------------------------------------
export type Ctx = {
	site: Model,
	root: Model,
	F: CFrame,
	w: number,
	d: number,
	H: number,
	storeys: number,
	floors: { number }, -- floor surface y (local) per storey
	rng: Random,
	bid: string,
	placers: { any }, -- Plan placer per storey
	at: (self: Ctx, x: number, y: number, z: number, yaw: number?) -> CFrame,
	ceiling: (self: Ctx, s: number) -> number,
	put: (self: Ctx, s: number, fn: any, x: number, z: number, yaw: number, fw: number, fd: number, opts: { [string]: any }?) -> Model?,
	add: (self: Ctx, fn: any, cf: CFrame, opts: { [string]: any }?) -> Model,
}

-- Footprint of an fw x fd item turned by yaw (only quarter turns are used).
local function footprint(x: number, z: number, yaw: number, fw: number, fd: number): Plan.Rect
	local q = math.abs(math.floor(yaw / R90 + 0.5)) % 2
	if q == 1 then
		return Plan.rect(x, z, fd, fw)
	end
	return Plan.rect(x, z, fw, fd)
end
Furnish.footprint = footprint

local function newCtx(site: Model, F: CFrame, w: number, d: number, H: number, storeys: number, fy: number): Ctx
	local ctx = {} :: any
	ctx.site = site
	ctx.F = F
	ctx.w, ctx.d, ctx.H, ctx.storeys = w, d, H, storeys
	ctx.floors = {}
	for s = 1, storeys do
		ctx.floors[s] = fy + (s - 1) * H
	end
	ctx.rng = Random.new(hash(site.Name) + 67)
	ctx.bid = site.Name
	ctx.root = Instance.new("Model")
	ctx.root.Name = "Interior"
	ctx.placers = {}
	for s = 1, storeys do
		ctx.placers[s] = Plan.placer({})
	end
	function ctx.at(self: Ctx, x: number, y: number, z: number, yaw: number?): CFrame
		return self.F * CF(x, y, z) * ANG(0, yaw or 0, 0)
	end
	-- underside of the slab above storey s (the roof for the top storey)
	function ctx.ceiling(self: Ctx, s: number): number
		local top = self.floors[s] + self.H
		return if s < self.storeys then top - 0.6 else top
	end
	-- a floor item, only if its footprint is clear (keep-outs + everything placed so far)
	function ctx.put(self: Ctx, s: number, fn: any, x: number, z: number, yaw: number, fw: number, fd: number, opts: { [string]: any }?): Model?
		local r = footprint(x, z, yaw, fw, fd)
		if not self.placers[s]:take(r) then
			if Furnish.Debug then
				local by = "?"
				for _, k in self.placers[s].keeps do
					if Plan.overlap(r, k) then
						by = string.format("keep %.1f,%.1f..%.1f,%.1f", k.x0, k.z0, k.x1, k.z1)
						break
					end
				end
				table.insert(Furnish.Misses, string.format("s%d (%.1f,%.1f) %s", s, x, z, by))
			end
			return nil
		end
		return self:add(fn, self:at(x, self.floors[s], z, yaw), opts)
	end
	-- an item that needs no footprint (wall, ceiling or table-top items)
	function ctx.add(self: Ctx, fn: any, cf: CFrame, opts: { [string]: any }?): Model
		local o = opts or {}
		if o.rng == nil then
			o.rng = self.rng
		end
		return fn(self.root, cf, o)
	end
	return ctx :: Ctx
end

-- Builder placeholder boxes that the home layouts swap for real furniture (not keep-outs: the swap
-- itself decides where the real piece goes).
Furnish.Swappable = {
	Sofa = true, Table = true, Counter = true, Fridge = true, Bookshelf = true, Bed = true, Dresser = true,
	BunkBed = true, Desk = true, Shelf = true, Crates = true, Booth = true,
}

-- Keep-outs from what the site already has: doors (both sides), stairs (+ walk-in / landing strips),
-- rescue spots, jump windows and any solid furniture the builder left (lockers, the gas tank).
local function collectKeepouts(ctx: Ctx, opts: { [string]: any })
	local inv = ctx.F:Inverse()
	local function storeyOf(y: number): number?
		for s = ctx.storeys, 1, -1 do
			if y >= ctx.floors[s] - 0.75 then
				return if y < ctx.floors[s] + ctx.H then s else nil
			end
		end
		return nil
	end
	for _, p in ctx.site:GetDescendants() do
		if not p:IsA("BasePart") or p:IsDescendantOf(ctx.root) then
			continue
		end
		local lcf = inv * p.CFrame
		local lp = lcf.Position
		local s = storeyOf(lp.Y - p.Size.Y / 2 + 0.1)
		local base = p.Name
		if p:HasTag(Names.Tag.Door) then
			local along = lcf.RightVector
			local alongX = math.abs(along.X) > math.abs(along.Z)
			local r = if alongX then Plan.rect(lp.X, lp.Z, 5.5, 11) else Plan.rect(lp.X, lp.Z, 11, 5.5)
			if s then
				ctx.placers[s]:keep(r)
			end
		elseif p:HasTag(Names.Tag.RescueSpawn) then
			s = storeyOf(lp.Y - 1)
			if s then
				ctx.placers[s]:keep(Plan.rect(lp.X, lp.Z, 4.4, 4.4))
			end
		elseif p:HasTag(Names.Tag.FireStart) then
			if opts.keepFireStarts and s then
				ctx.placers[s]:keep(Plan.rect(lp.X, lp.Z, 2.4, 2.4))
			end
		elseif string.sub(base, 1, 5) == "Stair" then
			-- the flight + the walk-in strip in front + the landing behind, on the storey it leaves and
			-- the one it arrives at
			local hx = math.abs(lcf.RightVector.X) * p.Size.X / 2 + math.abs(lcf.LookVector.X) * p.Size.Z / 2
			local hz = math.abs(lcf.RightVector.Z) * p.Size.X / 2 + math.abs(lcf.LookVector.Z) * p.Size.Z / 2
			local r = Plan.span(lp.X - hx - 0.5, lp.Z - hz - 4, lp.X + hx + 0.5, lp.Z + hz + 3)
			-- room to walk up to the foot and off the landing from the open side (+X for stairs on
			-- the left wall, -X on the right), not just the flight's own width
			local side = if lp.X < 0 then 1 else -1
			local ox0, ox1 = lp.X - hx - 0.5, lp.X + hx + 0.5
			local wideX0, wideX1 = if side > 0 then ox0 else ox0 - 5.5, if side > 0 then ox1 + 5.5 else ox1
			local foot = Plan.span(wideX0, lp.Z - hz - 4, wideX1, lp.Z - hz + 1.5)
			local land = Plan.span(wideX0, lp.Z + hz - 1.5, wideX1, lp.Z + hz + 4)
			for k = 1, ctx.storeys do
				local y0 = ctx.floors[k]
				if lp.Y + p.Size.Y / 2 >= y0 - 1 and lp.Y - p.Size.Y / 2 <= y0 + ctx.H then
					ctx.placers[k]:keep(r)
					-- the foot is on the storey the flight leaves, the landing on the one it reaches
					ctx.placers[k]:keep(if lp.Y - p.Size.Y / 2 >= y0 - 1 then foot else land)
				end
			end
		elseif p:HasTag(Names.Tag.Window) and p:GetAttribute("Jump") == true then
			if s then
				ctx.placers[s]:keep(Plan.rect(lp.X, lp.Z, 6, 6))
			end
		elseif p.CanCollide and p.Transparency < 0.9 and s and not (opts.swaps and Furnish.Swappable[base]) and base ~= "Floor" and base ~= "Foundation" and base ~= "Ceiling"
			and string.sub(base, 1, 4) ~= "Wall" and base ~= "Lintel" and base ~= "Sill" and string.sub(base, 1, 4) ~= "Roof"
			and base ~= "Parapet" and not p:HasTag(Names.Tag.Window)
		then
			-- a builder's own furniture (lockers, desks, the gas tank): don't build through it
			local hx = math.abs(lcf.RightVector.X) * p.Size.X / 2 + math.abs(lcf.UpVector.X) * p.Size.Y / 2 + math.abs(lcf.LookVector.X) * p.Size.Z / 2
			local hz = math.abs(lcf.RightVector.Z) * p.Size.X / 2 + math.abs(lcf.UpVector.Z) * p.Size.Y / 2 + math.abs(lcf.LookVector.Z) * p.Size.Z / 2
			if lp.X > -ctx.w / 2 and lp.X < ctx.w / 2 and lp.Z > 0 and lp.Z < ctx.d then
				ctx.placers[s]:keep(Plan.span(lp.X - hx, lp.Z - hz, lp.X + hx, lp.Z + hz))
			end
		end
	end
end

---------------------------------------------------------------------------------------------------
-- partitions: flammable two-tone interior walls (named Partition so SmokeService splits rooms)
---------------------------------------------------------------------------------------------------
type Hole = { c: number, w: number, top: number? }

-- Wall from (ax, az) to (bx, bz) on storey s, 1 thick, full storey height, two-tone (lower 4 studs
-- `low`, upper `high`). holes: { c = centre along the wall (x or z), w, top = 7.5 }.
function Furnish.partition(ctx: Ctx, s: number, ax: number, az: number, bx: number, bz: number, holes: { Hole }?, low: Color3?, high: Color3?)
	local alongX = math.abs(bx - ax) > math.abs(bz - az)
	local a0 = if alongX then math.min(ax, bx) else math.min(az, bz)
	local a1 = if alongX then math.max(ax, bx) else math.max(az, bz)
	local fixed = if alongX then az else ax
	local y0 = ctx.floors[s]
	local h = ctx:ceiling(s) - y0
	local bands = { { 0, math.min(4, h), low or C.SchoolWall }, { math.min(4, h), h, high or C.SchoolWallUp } }
	-- only the holes on this run, clipped to it
	local list = {}
	for _, hole in holes or {} do
		local l, r = math.max(a0, hole.c - hole.w / 2), math.min(a1, hole.c + hole.w / 2)
		if r - l > 0.05 then
			table.insert(list, { c = (l + r) / 2, w = r - l, top = hole.top })
		end
	end
	table.sort(list, function(p, q)
		return p.c < q.c
	end)
	local function seg(s0: number, s1: number, yb: number, yt: number, color: Color3)
		local L = s1 - s0
		if L < 0.05 or yt - yb < 0.05 then
			return
		end
		local n = math.max(1, math.ceil(L / 8 - 1e-6))
		for i = 1, n do
			local m = s0 + (i - 0.5) * L / n
			local size = if alongX then V(L / n, yt - yb, 1) else V(1, yt - yb, L / n)
			local cx, cz = if alongX then m else fixed, if alongX then fixed else m
			local p = Kit.part(ctx.root, "Partition", ctx:at(cx, y0 + (yb + yt) / 2, cz), size, color, { solid = true, fuel = 25 })
			p.CanQuery = true
			p:SetAttribute(Names.Attr.BuildingId, ctx.bid)
		end
	end
	for _, band in bands do
		local yb, yt, color = band[1], band[2], band[3]
		local cursor = a0
		for _, hole in list do
			local l, r = hole.c - hole.w / 2, hole.c + hole.w / 2
			local top = hole.top or 7.5
			seg(cursor, l, yb, yt, color)
			-- above the doorway (lintel) inside this band
			seg(l, r, math.max(yb, top), yt, color)
			cursor = r
		end
		seg(cursor, a1, yb, yt, color)
	end
end

---------------------------------------------------------------------------------------------------
-- dispatch
---------------------------------------------------------------------------------------------------
local function stampBuilding(root: Instance, bid: string): number
	local n = 0
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
			if d:HasTag(Names.Tag.Flammable) and d:GetAttribute(Names.Attr.BuildingId) == nil then
				d:SetAttribute(Names.Attr.BuildingId, bid)
			end
		end
	end
	return n
end

local function locationBuilder(id: string): any?
	local locs = script.Parent.Parent:FindFirstChild("Locations")
	local mod = locs and locs:FindFirstChild(`{id}Builder`)
	if not (mod and mod:IsA("ModuleScript")) then
		return nil
	end
	local ok, b = pcall(require, mod)
	return if ok and type(b) == "table" then b else nil
end

function Furnish.site(site: Model): (number, number)
	if site:GetAttribute("Furnished") == true then
		return 0, 0
	end
	local t0 = os.clock()
	local parts = 0
	local kind = site:GetAttribute("Interior")
	local layout = if type(kind) == "string" then Furnish.Layouts[kind] else nil
	if layout then
		local F = site:GetAttribute("InteriorFrame")
		local w, d = site:GetAttribute("InteriorW"), site:GetAttribute("InteriorD")
		local H, storeys = site:GetAttribute("InteriorH"), site:GetAttribute("InteriorStoreys")
		local fy = site:GetAttribute("InteriorFloorY")
		if typeof(F) ~= "CFrame" or type(w) ~= "number" or type(d) ~= "number" or type(H) ~= "number" or type(storeys) ~= "number" then
			warn(`[Furnish] {site.Name}: Interior = {kind} but the Interior* attrs are incomplete`)
			return 0, 0
		end
		local ctx = newCtx(site, F, w, d, H, storeys, if type(fy) == "number" then fy else 1.72)
		local ok, err = pcall(function()
			collectKeepouts(ctx, { keepFireStarts = false, swaps = kind ~= "school" })
			layout(ctx)
		end)
		if not ok then
			warn(`[Furnish] {site.Name} ({kind}) failed: {err}`)
		end
		parts = stampBuilding(ctx.root, ctx.bid)
		ctx.root.Parent = site
	else
		local loc = site:GetAttribute(Names.Attr.LocationId)
		local b = if type(loc) == "string" and loc ~= "City" then locationBuilder(loc) else nil
		local origin = site:GetAttribute("InteriorOrigin")
		if b and type(b.Furnish) == "function" then
			local ok, res = pcall(b.Furnish, site)
			if not ok then
				warn(`[Furnish] {loc}Builder.Furnish failed: {res}`)
			end
		elseif type(loc) == "string" and type(Districts[loc]) == "function" and typeof(origin) == "CFrame" then
			-- Interiors/Districts: dressing for a builder without a Furnish of its own
			local root = Instance.new("Model")
			root.Name = "Interior"
			local ok, res = pcall(Districts[loc], site, origin, root, Random.new(hash(site.Name) + 67))
			if not ok then
				warn(`[Furnish] Districts.{loc} failed: {res}`)
			end
			root.Parent = site
		end
		local root = site:FindFirstChild("Interior")
		if root then
			parts = stampBuilding(root, site.Name)
		end
	end
	site:SetAttribute("Furnished", true)
	site:SetAttribute("InteriorParts", parts)
	local ms = math.floor((os.clock() - t0) * 1000)
	site:SetAttribute("InteriorMs", ms)
	if parts > 0 then
		count("interior_parts", parts)
		count("interiors_built", 1)
	end
	return parts, ms
end

-- Layout modules register themselves here (Interiors/School, ...).
for _, name in { "School", "Home" } do
	local mod = script.Parent:FindFirstChild(name)
	if mod and mod:IsA("ModuleScript") then
		local ok, layout = pcall(require, mod)
		if ok and type(layout) == "table" and type(layout.register) == "function" then
			layout.register(Furnish)
		elseif not ok then
			warn(`[Furnish] {name} unavailable: {layout}`)
		end
	end
end

return Furnish
