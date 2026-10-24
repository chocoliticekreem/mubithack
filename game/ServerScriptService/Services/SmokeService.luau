--!strict
-- SmokeService [owner: Smoke agent]. FIRE IS A ROOM HAZARD. Every building of an ACTIVE mission site
-- (Workspace.Runs.<runId> with RoundState Alarm / Dispatched / Active) is split into rooms (Lib/Fire/Rooms:
-- walls, doors and windows rasterized per storey, flood fill). Each room fills with smoke and heat from
-- the fires burning in it (Lib/Fire/SmokeSim), which flow through open doors, rise up stairwells and
-- seep under closed doors. Players' Heat rises faster in smoke (the GasMask protects), rescue NPCs
-- choke slowly. Opening / breaking a window or door VENTS the room. A sealed room with heavy fire and
-- smoke builds PRESSURE: doors rattle, smoke puffs from the gaps, creaks, "Something's building up in
-- there..."; opening a door onto it then = BACKDRAFT (fireball out of the doorway, ragdoll knockback,
-- blame). Venting a window first relieves it safely. Fire creeps under doors into the next room, the
-- door gets hot, and grabbing a hot handle burns ("Feel the door first!"; T = feel a door).
--
-- Public API:
--   SmokeService:GetRoomAt(pos: Vector3): { smoke: number, heat: number, pressure: number, stage: number }?
--   SmokeService:ActiveSites(): { string }
-- Signals: Backdraft(opener: Player?, door: BasePart), Vented(part: BasePart, relief: boolean)
-- Remotes: Smoke/Fx (S->C all: kind "backdraft"|"relief"|"vent"|"puff"|"creak"|"jolt", pos: Vector3, data: table)
-- Writes: Workspace.SmokeRooms.<siteId>.Room<n> Models (attrs Smoke 0..1, Heat 0..100, Pressure 0..1,
--   Stage 0|1|2, FloorY, Height) holding invisible "Area" parts (the room's floor plan boxes, full
--   height); tag SmokeLink + attrs Seep (0..1), SeepDir (Vector3), DoorHeat (0..1), Rattle (0|1|2), Vent
--   (0..1), VentDir (Vector3) on the site's tracked Door / Window parts; a "FeelPoint" Attachment +
--   ProximityPrompt on tracked doors; Player attr InSmoke (0..1).
-- Reads (never writes): Door CanCollide / attr Broken (ToolService toggles / breaks), Window attr Broken /
--   Transparency (GearService / StructureService smash), Burning tag + FireLevel, Player attrs GasMask,
--   OxygenAir, Rescuable attrs RescueId / RescueState.
-- Consumes (nil-guarded): FireService:Ignite / IsBurning, HeatService:AddHeat, RescueService:Hurt,
--   Shared/Ragdoll, Shared/Popup.
-- Counters: smoke_sites, smoke_rooms, smoke_backdrafts, smoke_reliefs, smoke_vents, smoke_spreads,
--   smoke_warns, smoke_jolts, smoke_feels, smoke_tick_over_budget
-- Test hooks (DevHook only): _activate(siteId), _deactivate(siteId), _state(siteId?), _set(siteId, room,
--   field, value), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("SmokeConfig") :: ModuleScript) :: any
local FireLib = ServerScriptService:WaitForChild("Lib"):WaitForChild("Fire")
local Rooms = require(FireLib:WaitForChild("Rooms") :: ModuleScript)
local SmokeSim = require(FireLib:WaitForChild("SmokeSim") :: ModuleScript)

local SmokeService = {}
SmokeService.Priority = 85
SmokeService.Backdraft = Signal.new() :: Signal.Signal<Player?, BasePart>
SmokeService.Vented = Signal.new() :: Signal.Signal<BasePart, boolean>

local SITE_TAG = "IncidentSite"
local LINK_TAG = "SmokeLink"
local LIVE_STATES = { Alarm = true, Dispatched = true, Active = true }

type Building = {
	frame: CFrame, -- yaw-only, y = 0: local Y = world Y
	grid: Rooms.Grid,
	levels: { Rooms.Level },
	labels: { { [number]: number } }, -- per storey
	roomMap: { { [number]: number } }, -- per storey: label -> site room index
	minX: number,
	minZ: number,
	maxX: number,
	maxZ: number,
}
type RoomRec = {
	sim: SmokeSim.Room,
	building: Building,
	storey: number,
	floorY: number,
	height: number,
	centre: Vector3,
	model: Model,
	links: { number },
	parts: { BasePart }, -- flammables in the room
	written: { [string]: number },
	nextPuff: number,
}
type LinkRec = {
	sim: SmokeSim.Link,
	part: BasePart,
	dirAB: Vector3, -- world, flat: from room a's side toward b's side
	conns: { RBXScriptConnection },
	feel: Attachment?,
	written: { [string]: any },
}
type Site = {
	id: string,
	model: Instance,
	folder: Folder,
	buildings: { Building },
	rooms: { RoomRec },
	simRooms: { SmokeSim.Room },
	links: { LinkRec },
	simLinks: { SmokeSim.Link },
	tickMs: number,
}

local services: { [string]: any } = {}
local sites: { [string]: Site } = {}
local pending: { [string]: boolean } = {}
local forced: { [string]: Instance } = {}
local burnIndex: { [BasePart]: { site: Site, room: number } } = {}
local lastCough: { [Instance]: number } = {}
local FxRemote: RemoteEvent? = nil

---------------------------------------------------------------------------------------------- helpers

local function call(service: string, method: string, ...: any): any
	local s = services[service]
	local fn = s and s[method]
	if type(fn) ~= "function" then
		return nil
	end
	local ok, res = pcall(fn, s, ...)
	if not ok then
		warn(`[SmokeService] {service}:{method}: {res}`)
		return nil
	end
	return res
end

local function fx(kind: string, pos: Vector3, data: { [string]: any }?)
	if FxRemote then
		FxRemote:FireAllClients(kind, pos, data or {})
	end
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-4 then f.Unit else Vector3.new(0, 0, -1)
end

local function yExtent(p: BasePart): (number, number)
	local cf, s = p.CFrame, p.Size
	local hy = math.abs(cf.RightVector.Y) * s.X / 2 + math.abs(cf.UpVector.Y) * s.Y / 2 + math.abs(cf.LookVector.Y) * s.Z / 2
	return p.Position.Y - hy, p.Position.Y + hy
end

local function rectOf(frame: CFrame, p: BasePart): Rooms.Rect?
	local cf = frame:ToObjectSpace(p.CFrame)
	if math.abs(cf.UpVector.Y) < 0.9 then
		return nil -- tilted (roof slopes, stair wedges on their side): not a wall
	end
	local rx = cf.RightVector
	local m = math.sqrt(rx.X * rx.X + rx.Z * rx.Z)
	if m < 1e-4 then
		return nil
	end
	return { cx = cf.X, cz = cf.Z, ax = rx.X / m, az = rx.Z / m, hx = p.Size.X / 2, hz = p.Size.Z / 2 }
end

local function isWallName(n: string): boolean
	return string.sub(n, 1, 4) == "Wall" or string.sub(n, 1, 9) == "Partition"
end

local function isOpenPart(p: BasePart, kind: string): boolean
	if not p:IsDescendantOf(workspace) then
		return true
	end
	if p:GetAttribute(Names.Attr.Broken) == true then
		return true
	end
	if kind == "door" then
		return not p.CanCollide
	end
	return p.Transparency >= 0.99
end

local function rootOf(player: Player): BasePart?
	local char = player.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function setAttr(inst: Instance, cache: { [string]: any }, key: string, value: any)
	if cache[key] ~= value then
		cache[key] = value
		inst:SetAttribute(key, value)
	end
end

local function q(v: number, step: number): number
	return math.floor(v / step + 0.5) * step
end

local function rootFolder(): Folder
	local f = workspace:FindFirstChild("SmokeRooms")
	if not f then
		f = Instance.new("Folder")
		f.Name = "SmokeRooms"
		f.Parent = workspace
	end
	return f :: Folder
end

---------------------------------------------------------------------------------------------- rooms

-- Room index (in site.rooms) at a world point, or nil.
local function roomAt(site: Site, pos: Vector3, reach: number): number?
	for _, b in site.buildings do
		local lp = b.frame:PointToObjectSpace(pos)
		if lp.X < b.minX - 1 or lp.X > b.maxX + 1 or lp.Z < b.minZ - 1 or lp.Z > b.maxZ + 1 then
			continue
		end
		local s = Rooms.storeyOf(b.levels, pos.Y)
		if s then
			local l = Rooms.labelAt(b.grid, b.labels[s], lp.X, lp.Z, reach)
			if l and l > 0 then
				return b.roomMap[s][l]
			end
		end
	end
	return nil
end

-- 0 = outside, >0 = room index, nil = unknown (walls only) for a point on storey s of building b.
local function sideAt(b: Building, s: number, lx: number, lz: number): number?
	local l = Rooms.labelAt(b.grid, b.labels[s], lx, lz, 1)
	if l == nil then
		return nil
	elseif l == 0 then
		return 0
	end
	return b.roomMap[s][l]
end

type Group = { walls: { BasePart }, tall: number }

local function groupWalls(parts: { BasePart }): { Group }
	local groups: { [string]: Group } = {}
	for _, p in parts do
		if not isWallName(p.Name) then
			continue
		end
		local bid = p:GetAttribute(Names.Attr.BuildingId)
		local key = if type(bid) == "string" then bid else (p:FindFirstAncestorWhichIsA("Model") or p).Name
		local g = groups[key]
		if not g then
			g = { walls = {}, tall = 0 }
			groups[key] = g
		end
		table.insert(g.walls, p)
		local y0, y1 = yExtent(p)
		if y1 - y0 >= Cfg.MinWallHeight then
			g.tall += 1
		end
	end
	local out: { Group } = {}
	for _, g in groups do
		if g.tall >= 4 then
			table.insert(out, g)
		end
	end
	return out
end

local function frameFor(walls: { BasePart }): CFrame
	local best, bestLen = walls[1], 0
	local sx, sz = 0, 0
	for _, w in walls do
		local len = math.max(w.Size.X, w.Size.Z)
		if len > bestLen then
			best, bestLen = w, len
		end
		sx += w.Position.X
		sz += w.Position.Z
	end
	local axis = if best.Size.X >= best.Size.Z then best.CFrame.RightVector else best.CFrame.LookVector
	local dir = flat(axis)
	return CFrame.new(sx / #walls, 0, sz / #walls) * CFrame.lookAt(Vector3.zero, dir)
end

local function newBuilding(walls: { BasePart }): Building?
	local frame = frameFor(walls)
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	local spans: { Rooms.Wall } = {}
	for _, w in walls do
		local r = rectOf(frame, w)
		if not r then
			continue
		end
		local ex = math.abs(r.ax) * r.hx + math.abs(r.az) * r.hz
		local ez = math.abs(r.az) * r.hx + math.abs(r.ax) * r.hz
		minX, maxX = math.min(minX, r.cx - ex), math.max(maxX, r.cx + ex)
		minZ, maxZ = math.min(minZ, r.cz - ez), math.max(maxZ, r.cz + ez)
		local y0, y1 = yExtent(w)
		if y1 - y0 >= Cfg.MinWallHeight then
			table.insert(spans, { bottom = y0, top = y1 })
		end
	end
	local levels = Rooms.levels(spans, 0.6, 3)
	if #levels == 0 or maxX - minX < 4 or maxZ - minZ < 4 or (maxX - minX) * (maxZ - minZ) > 40000 then
		return nil
	end
	return {
		frame = frame,
		grid = Rooms.grid(minX, minZ, maxX, maxZ, Cfg.Cell, Cfg.Cell * 2),
		levels = levels,
		labels = {},
		roomMap = {},
		minX = minX,
		minZ = minZ,
		maxX = maxX,
		maxZ = maxZ,
	}
end

local function inside(b: Building, pos: Vector3, pad: number): boolean
	local lp = b.frame:PointToObjectSpace(pos)
	return lp.X >= b.minX - pad and lp.X <= b.maxX + pad and lp.Z >= b.minZ - pad and lp.Z <= b.maxZ + pad
end

local function makeArea(parent: Instance, cf: CFrame, size: Vector3)
	local p = Instance.new("Part")
	p.Name = "Area"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Transparency = 1
	p.Size = size
	p.CFrame = cf
	p.Parent = parent
end

local function addLink(site: Site, a: number, b: number, kind: string, part: BasePart?, dirAB: Vector3)
	for _, l in site.links do
		if (part and l.part == part) or (not part and l.sim.kind == kind and l.sim.a == a and l.sim.b == b) then
			return
		end
	end
	local open = if part then isOpenPart(part, kind) else true
	local rec: LinkRec = {
		sim = SmokeSim.newLink(a, b, kind, open),
		part = part :: any,
		dirAB = dirAB,
		conns = {},
		written = {},
	}
	table.insert(site.links, rec)
	table.insert(site.simLinks, rec.sim)
	local li = #site.links
	table.insert(site.rooms[a].links, li)
	if b > 0 then
		table.insert(site.rooms[b].links, li)
	end
end

-- Builds every room + link of a site (yields between buildings). Returns nil if nothing usable.
local function derive(siteId: string, model: Instance): Site?
	local parts: { BasePart } = {}
	local doors: { BasePart } = {}
	local windows: { BasePart } = {}
	local stairs: { BasePart } = {}
	local flammables: { BasePart } = {}
	local fireStarts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			table.insert(parts, d)
			if d:HasTag(Names.Tag.Door) then
				table.insert(doors, d)
			elseif d:HasTag(Names.Tag.Window) then
				table.insert(windows, d)
			elseif string.sub(d.Name, 1, 5) == "Stair" then
				table.insert(stairs, d)
			end
			if d:HasTag(Names.Tag.Flammable) then
				table.insert(flammables, d)
			end
			if d:HasTag(Names.Tag.FireStart) then
				table.insert(fireStarts, d)
			end
		end
	end
	-- buildings: wall groups, the ones with fire starts first
	local cands: { { b: Building, walls: { BasePart }, score: number } } = {}
	for _, g in groupWalls(parts) do
		local b = newBuilding(g.walls)
		if b then
			local score = 0
			for _, f in fireStarts do
				if inside(b, f.Position, 1) then
					score += 100
				end
			end
			table.insert(cands, { b = b, walls = g.walls, score = score + #g.walls / 1000 })
		end
	end
	table.sort(cands, function(x, y)
		return x.score > y.score
	end)
	local folder = Instance.new("Folder")
	folder.Name = siteId
	folder:SetAttribute("SiteId", siteId)
	local site: Site = {
		id = siteId,
		model = model,
		folder = folder,
		buildings = {},
		rooms = {},
		simRooms = {},
		links = {},
		simLinks = {},
		tickMs = 0,
	}
	for ci, c in cands do
		if ci > Cfg.MaxBuildingsPerSite or #site.rooms >= Cfg.MaxRoomsPerSite then
			break
		end
		local b = c.b
		-- blockers: this building's walls + every door / window inside its footprint
		local blockers: { BasePart } = table.clone(c.walls)
		for _, list in { doors, windows } do
			for _, p in list do
				if inside(b, p.Position, 1.5) then
					table.insert(blockers, p)
				end
			end
		end
		for s, lvl in b.levels do
			local sliceY = lvl.y + Cfg.SliceHeight
			local rects: { Rooms.Rect } = {}
			for _, p in blockers do
				local y0, y1 = yExtent(p)
				if y0 <= sliceY and y1 >= sliceY then
					local r = rectOf(b.frame, p)
					if r then
						table.insert(rects, r)
					end
				end
			end
			local blocked = Rooms.rasterize(b.grid, rects, Cfg.WallPad)
			local labels, found = Rooms.flood(b.grid, blocked, Cfg.MinRoomCells)
			b.labels[s] = labels
			b.roomMap[s] = {}
			for _, fr in found do
				if #site.rooms >= Cfg.MaxRoomsPerSite then
					break
				end
				local area = fr.cells * Cfg.Cell * Cfg.Cell
				local n = #site.rooms + 1
				local m = Instance.new("Model")
				m.Name = `Room{n}`
				m:SetAttribute("Storey", s)
				m:SetAttribute("FloorY", lvl.y)
				m:SetAttribute("Height", lvl.h)
				m:SetAttribute("Smoke", 0)
				m:SetAttribute("Heat", 0)
				m:SetAttribute("Pressure", 0)
				m:SetAttribute("Stage", 0)
				for _, cr in Rooms.rects(b.grid, labels, fr.id, Cfg.MaxRectsPerRoom) do
					local x0, z0 = Rooms.centre(b.grid, cr.i0, cr.k0)
					local x1, z1 = Rooms.centre(b.grid, cr.i1, cr.k1)
					local size = Vector3.new(x1 - x0 + Cfg.Cell, lvl.h, z1 - z0 + Cfg.Cell)
					local cf = b.frame * CFrame.new((x0 + x1) / 2, lvl.y + lvl.h / 2, (z0 + z1) / 2)
					makeArea(m, cf, size)
				end
				m.Parent = folder
				local centre = b.frame:PointToWorldSpace(Vector3.new(fr.cx, lvl.y + lvl.h / 2, fr.cz))
				local rec: RoomRec = {
					sim = SmokeSim.newRoom(area),
					building = b,
					storey = s,
					floorY = lvl.y,
					height = lvl.h,
					centre = centre,
					model = m,
					links = {},
					parts = {},
					written = {},
					nextPuff = 0,
				}
				table.insert(site.rooms, rec)
				table.insert(site.simRooms, rec.sim)
				b.roomMap[s][fr.id] = n
			end
		end
		table.insert(site.buildings, b)
		task.wait()
	end
	if #site.rooms == 0 then
		folder:Destroy()
		return nil
	end
	-- doors + windows -> links (a = a room, b = the other room or 0 = outside)
	for _, b in site.buildings do
		for _, list in { doors, windows } do
			for _, p in list do
				if not inside(b, p.Position, 1.5) then
					continue
				end
				local s = Rooms.storeyOf(b.levels, p.Position.Y)
				if not s then
					continue
				end
				local kind = if p:HasTag(Names.Tag.Door) then "door" else "window"
				local lc = b.frame:PointToObjectSpace(p.Position)
				local nl = b.frame:VectorToObjectSpace(p.CFrame.LookVector)
				local n2 = Vector3.new(nl.X, 0, nl.Z)
				if n2.Magnitude < 1e-3 then
					continue
				end
				n2 = n2.Unit
				local d = p.Size.Z / 2 + Cfg.WallPad + Cfg.Cell * 1.2
				local sa = sideAt(b, s, lc.X + n2.X * d, lc.Z + n2.Z * d)
				local sb = sideAt(b, s, lc.X - n2.X * d, lc.Z - n2.Z * d)
				if sa == nil or sb == nil or sa == sb then
					continue
				end
				local worldN = flat(p.CFrame.LookVector)
				if sa == 0 then
					sa, sb = sb, sa
					worldN = -worldN
				end
				-- room a sits on the +worldN side, so a -> b points along -worldN
				addLink(site, sa :: number, sb :: number, kind, p, -worldN)
			end
		end
		-- stairwells between storeys
		for _, p in stairs do
			if not inside(b, p.Position, 0.5) then
				continue
			end
			local y0, y1 = yExtent(p)
			local s0, s1 = Rooms.storeyOf(b.levels, y0 + 1), Rooms.storeyOf(b.levels, y1 + 1)
			if not s0 or not s1 or s0 == s1 then
				continue
			end
			local lc = b.frame:PointToObjectSpace(p.Position)
			local l0 = Rooms.labelAt(b.grid, b.labels[s0], lc.X, lc.Z, 3)
			local l1 = Rooms.labelAt(b.grid, b.labels[s1], lc.X, lc.Z, 3)
			local r0 = l0 and l0 > 0 and b.roomMap[s0][l0]
			local r1 = l1 and l1 > 0 and b.roomMap[s1][l1]
			if r0 and r1 and r0 ~= r1 then
				addLink(site, r0, r1, "stair", nil, Vector3.yAxis)
			end
		end
		-- every storey above the ground smokes into from below somehow: biggest room to biggest room
		for s = 1, #b.levels - 1 do
			local linked = false
			local big0, big1, a0, a1 = nil :: number?, nil :: number?, 0, 0
			for ri, r in site.rooms do
				if r.building == b and r.storey == s and r.sim.area > a0 then
					big0, a0 = ri, r.sim.area
				elseif r.building == b and r.storey == s + 1 and r.sim.area > a1 then
					big1, a1 = ri, r.sim.area
				end
			end
			for _, l in site.links do
				if l.sim.kind == "stair" and site.rooms[l.sim.a].storey == s and l.sim.b > 0 and site.rooms[l.sim.b].storey == s + 1 and site.rooms[l.sim.a].building == b then
					linked = true
				end
			end
			if not linked and big0 and big1 then
				addLink(site, big0, big1, "stair", nil, Vector3.yAxis)
			end
		end
	end
	-- flammable parts -> rooms
	for _, p in flammables do
		local ri = roomAt(site, p.Position, 2)
		if ri then
			table.insert(site.rooms[ri].parts, p)
		end
	end
	return site
end

---------------------------------------------------------------------------------------------- events

local function nearestPlayer(pos: Vector3, within: number): Player?
	local best, bestD = nil :: Player?, within
	for _, p in Players:GetPlayers() do
		local r = rootOf(p)
		if r then
			local d = (r.Position - pos).Magnitude
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	return best
end

-- Sets up to n idle flammable parts of a room alight, nearest to `near` first.
local function igniteIn(site: Site, ri: number, near: Vector3, n: number, cause: Player?): number
	local room = site.rooms[ri]
	if not room or n <= 0 then
		return 0
	end
	local list = table.clone(room.parts)
	table.sort(list, function(a, b)
		return (a.Position - near).Magnitude < (b.Position - near).Magnitude
	end)
	local lit = 0
	for _, p in list do
		if lit >= n then
			break
		end
		if p.Parent and not call("FireService", "IsBurning", p) and call("FireService", "Ignite", p, cause) then
			lit += 1
		end
	end
	return lit
end

local function closedLinkOf(site: Site, ri: number): LinkRec?
	for _, li in site.rooms[ri].links do
		local l = site.links[li]
		if l.part and not l.sim.open and l.sim.kind == "door" then
			return l
		end
	end
	for _, li in site.rooms[ri].links do
		local l = site.links[li]
		if l.part and not l.sim.open then
			return l
		end
	end
	return nil
end

local function doBackdraft(site: Site, li: number, ri: number)
	local l = site.links[li]
	local door = l.part
	local dir = if l.sim.a == ri then l.dirAB else -l.dirAB
	local origin = door.Position
	local opener = nearestPlayer(origin, 14)
	Telemetry.count("smoke_backdrafts")
	fx("backdraft", origin, { dir = dir, size = door.Size })
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = rootOf(p)
		if not char or not root then
			continue
		end
		local off = root.Position - origin
		local dist = off.Magnitude
		if dist > Cfg.BackdraftRadius or off:Dot(dir) < -6 then
			continue
		end
		local k = 1 - dist / Cfg.BackdraftRadius
		local push = dir * Cfg.BackdraftPush * (0.4 + 0.6 * k) + Vector3.new(0, Cfg.BackdraftLift * (0.5 + 0.5 * k), 0) + flat(off) * 10
		pcall(Ragdoll.knockback, char, push)
		pcall(Ragdoll.enable, char, Cfg.BackdraftRagdoll)
		call("HeatService", "AddHeat", p, Cfg.BackdraftPlayerHeat * (0.5 + 0.5 * k), "backdraft")
	end
	Popup.show(origin + Vector3.new(0, 4, 0), "FWOOOSH! BACKDRAFT!", "bad")
	if opener then
		local lines = {
			"%s opened the wrong door.",
			"%s: 'I'll just check in here...'",
			"%s forgot to feel the door.",
			"%s got a face full of fireball.",
		}
		Popup.show(opener, string.format(lines[math.random(1, #lines)], opener.DisplayName), "blame", opener)
	end
	igniteIn(site, ri, origin, Cfg.BackdraftIgnite, nil)
	local other = if l.sim.a == ri then l.sim.b else l.sim.a
	if other > 0 then
		igniteIn(site, other, origin, 2, nil)
	end
	SmokeService.Backdraft:Fire(opener, door)
end

-- A link changed state; on opening decide backdraft / relief / vent.
local function refreshLink(site: Site, li: number)
	local l = site.links[li]
	if not l or not l.part then
		return
	end
	local open = isOpenPart(l.part, l.sim.kind)
	if open == l.sim.open then
		return
	end
	l.sim.open = open
	if l.feel then
		local prompt = l.feel:FindFirstChildOfClass("ProximityPrompt")
		if prompt then
			prompt.Enabled = not open
		end
	end
	if not open then
		return
	end
	local outcome, ri = SmokeSim.onOpened(site.simRooms, site.simLinks, li, Cfg)
	if outcome == "backdraft" and ri then
		doBackdraft(site, li, ri)
	elseif outcome == "relief" then
		Telemetry.count("smoke_reliefs")
		local dir = if site.rooms[l.sim.a] then l.dirAB else -l.dirAB
		fx("relief", l.part.Position, { dir = dir })
		Popup.show(l.part.Position + Vector3.new(0, 3, 0), "Phew! Pressure vented.", "good")
		SmokeService.Vented:Fire(l.part, true)
	elseif outcome == "vent" then
		Telemetry.count("smoke_vents")
		fx("vent", l.part.Position, { dir = l.dirAB })
		SmokeService.Vented:Fire(l.part, false)
	end
end

local function feelDoor(site: Site, li: number, player: Player)
	local l = site.links[li]
	local root = rootOf(player)
	if not l or not root or l.sim.open then
		return
	end
	Telemetry.count("smoke_feels")
	local onB = (root.Position - l.part.Position):Dot(l.dirAB) > 0
	local other = if onB then l.sim.a else l.sim.b
	local text, kind = "Cool. Probably safe.", "good"
	if other <= 0 then
		text = "Cool breeze. That's the outside."
	else
		local r = site.simRooms[other]
		if r.stage >= 2 then
			text, kind = "It's RATTLING and scorching! Vent a window first!", "bad"
		elseif r.stage >= 1 then
			text, kind = "Hot... and something's rumbling in there.", "bad"
		elseif r.heat >= Cfg.HotDoorAt * 100 then
			text, kind = "HOT! Fire on the other side.", "bad"
		elseif r.smoke >= 0.3 then
			text, kind = "Warm. Smoky in there. Mask up.", "info"
		end
	end
	Popup.show(player, text, kind, player)
end

local function onDoorGrab(site: Site, li: number, player: Player)
	local l = site.links[li]
	if not l or l.sim.open then
		return
	end
	local heat = tonumber(l.part:GetAttribute("DoorHeat")) or 0
	if heat < Cfg.HotDoorAt then
		return
	end
	Telemetry.count("smoke_jolts")
	call("HeatService", "AddHeat", player, Cfg.JoltHeat * heat, "door")
	local char = player.Character
	local root = rootOf(player)
	if char and root then
		pcall(Ragdoll.knockback, char, flat(root.Position - l.part.Position) * Cfg.JoltPush + Vector3.new(0, 8, 0))
	end
	fx("jolt", l.part.Position, {})
	Popup.show(player, `YOWCH! Hot handle. Feel the door first! ({Cfg.FeelKey.Name})`, "bad", player)
end

local function hookLink(site: Site, li: number)
	local l = site.links[li]
	local p = l.part
	if not p then
		return
	end
	p:AddTag(LINK_TAG)
	local function changed()
		refreshLink(site, li)
	end
	table.insert(l.conns, p:GetPropertyChangedSignal("CanCollide"):Connect(changed))
	table.insert(l.conns, p:GetPropertyChangedSignal("Transparency"):Connect(changed))
	table.insert(l.conns, p:GetAttributeChangedSignal(Names.Attr.Broken):Connect(changed))
	if l.sim.kind ~= "door" then
		return
	end
	local main = p:FindFirstChildOfClass("ProximityPrompt")
	if main then
		table.insert(l.conns, main.Triggered:Connect(function(player: Player)
			onDoorGrab(site, li, player)
		end))
	end
	local att = Instance.new("Attachment")
	att.Name = "FeelPoint"
	att.Position = Vector3.new(0, -1, 0)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "FeelPrompt"
	prompt.ActionText = "Feel door"
	prompt.ObjectText = "Hot?"
	prompt.KeyboardKeyCode = Cfg.FeelKey
	prompt.GamepadKeyCode = Enum.KeyCode.DPadUp
	prompt.HoldDuration = 0.35
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.UIOffset = Vector2.new(0, 70)
	prompt.Enabled = not l.sim.open
	prompt.Parent = att
	att.Parent = p
	l.feel = att
	table.insert(l.conns, prompt.Triggered:Connect(function(player: Player)
		feelDoor(site, li, player)
	end))
end

---------------------------------------------------------------------------------------------- lifecycle

local function deactivate(siteId: string)
	local site = sites[siteId]
	if not site then
		return
	end
	sites[siteId] = nil
	for part, e in burnIndex do
		if e.site == site then
			burnIndex[part] = nil
		end
	end
	for _, l in site.links do
		for _, c in l.conns do
			c:Disconnect()
		end
		if l.feel then
			l.feel:Destroy()
		end
		local p = l.part
		if p and p.Parent then
			p:RemoveTag(LINK_TAG)
			for _, k in { "Seep", "SeepDir", "DoorHeat", "Rattle", "Vent", "VentDir" } do
				p:SetAttribute(k, nil)
			end
		end
	end
	site.folder:Destroy()
end

local function activate(siteId: string, model: Instance)
	if sites[siteId] or pending[siteId] then
		return
	end
	pending[siteId] = true
	task.spawn(function()
		local t0 = os.clock()
		local ok, site = pcall(derive, siteId, model)
		pending[siteId] = nil
		if not ok then
			warn(`[SmokeService] rooms for {siteId}: {site}`)
			return
		end
		if not site or not model.Parent then
			return
		end
		sites[siteId] = site
		for ri, r in site.rooms do
			for _, p in r.parts do
				burnIndex[p] = { site = site, room = ri }
			end
		end
		for li in site.links do
			hookLink(site, li)
		end
		site.folder:SetAttribute("Rooms", #site.rooms)
		site.folder:SetAttribute("Links", #site.links)
		site.folder:SetAttribute("DeriveMs", math.floor((os.clock() - t0) * 1000))
		site.folder.Parent = rootFolder()
		Telemetry.count("smoke_sites")
		Telemetry.count("smoke_rooms", #site.rooms)
	end)
end

local function siteModel(siteId: string): Instance?
	for _, m in CollectionService:GetTagged(SITE_TAG) do
		if m:GetAttribute("SiteId") == siteId and m:IsDescendantOf(workspace) then
			return m
		end
	end
	return nil
end

local function syncSites()
	local want: { [string]: Instance } = {}
	local runs = workspace:FindFirstChild("Runs")
	if runs then
		for _, run in runs:GetChildren() do
			local state = run:GetAttribute(Names.Attr.RoundState)
			local siteId = run:GetAttribute("SiteId")
			if type(siteId) == "string" and siteId ~= "" and LIVE_STATES[state :: any] then
				local ov = run:FindFirstChild("Site")
				local m = if ov and ov:IsA("ObjectValue") and ov.Value then ov.Value else siteModel(siteId)
				if m and m:IsDescendantOf(workspace) then
					want[siteId] = m
				end
			end
		end
	end
	for id, m in forced do
		if m.Parent then
			want[id] = m
		else
			forced[id] = nil
		end
	end
	for id, site in sites do
		if want[id] ~= site.model or not site.model:IsDescendantOf(workspace) then
			deactivate(id)
		end
	end
	if Cfg.Enabled then
		for id, m in want do
			activate(id, m)
		end
	end
end

---------------------------------------------------------------------------------------------- tick

local function writeRoom(r: RoomRec)
	local s = r.sim
	local w = r.written
	local function put(key: string, value: number, step: number)
		local v = q(value, step)
		if w[key] ~= v then
			w[key] = v
			r.model:SetAttribute(key, v)
		end
	end
	put("Smoke", s.smoke, 0.02)
	put("Heat", s.heat, 1)
	put("Pressure", s.pressure, 0.02)
	put("Stage", s.stage, 1)
	put("Fire", s.fire, 1)
end

local function writeLink(site: Site, l: LinkRec)
	local p = l.part
	if not p or not p.Parent then
		return
	end
	local ra = site.simRooms[l.sim.a]
	local rb = if l.sim.b > 0 then site.simRooms[l.sim.b] else nil
	local sa, ha = ra.smoke, ra.heat
	local sb, hb = if rb then rb.smoke else 0, if rb then rb.heat else 0
	if l.sim.open then
		local v = math.clamp(math.abs(l.sim.flow) * 4, 0, 1)
		setAttr(p, l.written, "Vent", q(v, 0.05))
		setAttr(p, l.written, "VentDir", if l.sim.flow >= 0 then l.dirAB else -l.dirAB)
		setAttr(p, l.written, "Seep", 0)
		setAttr(p, l.written, "Rattle", 0)
		setAttr(p, l.written, "DoorHeat", 0)
		return
	end
	setAttr(p, l.written, "Vent", 0)
	local rattle = math.max(ra.stage, if rb then rb.stage else 0)
	setAttr(p, l.written, "Rattle", rattle)
	if l.sim.kind ~= "door" then
		return
	end
	local seep, sign, heat = SmokeSim.doorState(sa, sb, ha, hb)
	setAttr(p, l.written, "Seep", if seep >= 0.08 then q(seep, 0.05) else 0)
	setAttr(p, l.written, "SeepDir", if sign > 0 then l.dirAB else -l.dirAB)
	setAttr(p, l.written, "DoorHeat", q(heat, 0.05))
end

local function handleEvents(site: Site, events: { SmokeSim.Event })
	for _, e in events do
		if e.kind == "warn" or e.kind == "armed" then
			local ri = e.room :: number
			local l = closedLinkOf(site, ri)
			local at = if l then l.part.Position + Vector3.new(0, 3, 0) else site.rooms[ri].centre
			if e.kind == "warn" then
				Telemetry.count("smoke_warns")
				Popup.show(at, "Something's building up in there...", "bad")
			else
				Popup.show(at, "It's gonna BLOW! Vent a window first!", "bad")
			end
			fx("creak", at, { stage = if e.kind == "armed" then 2 else 1 })
			site.rooms[ri].nextPuff = os.clock() + 1
		elseif e.kind == "spread" then
			local l = site.links[e.link :: number]
			local near = if l.part then l.part.Position else site.rooms[e.to :: number].centre
			if igniteIn(site, e.to :: number, near, 1, nil) > 0 then
				Telemetry.count("smoke_spreads")
				if l.part and not l.sim.open then
					Popup.show(near + Vector3.new(0, 2, 0), "Fire crept under the door!", "bad")
				end
			end
		end
	end
end

local function puffs(site: Site, now: number)
	for ri, r in site.rooms do
		if r.sim.stage < 1 or now < r.nextPuff then
			continue
		end
		r.nextPuff = now + Cfg.WarnPuffEvery / r.sim.stage
		local points: { Vector3 } = {}
		local dirs: { Vector3 } = {}
		for _, li in r.links do
			local l = site.links[li]
			if l.part and not l.sim.open and #points < 6 then
				local p = l.part
				local bottom = p.Position - Vector3.new(0, p.Size.Y / 2 - 0.3, 0)
				table.insert(points, if l.sim.kind == "door" then bottom else p.Position + Vector3.new(0, p.Size.Y / 2, 0))
				table.insert(dirs, if l.sim.a == ri then l.dirAB else -l.dirAB)
			end
		end
		if #points > 0 then
			fx("puff", points[1], { points = points, dirs = dirs, stage = r.sim.stage })
			fx("creak", points[1], { stage = r.sim.stage })
		end
	end
end

local function exposure(dt: number)
	-- players
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local root = rootOf(p)
		local smoke = 0
		if char and root then
			local head = char:FindFirstChild("Head") :: BasePart?
			local headY = if head then head.Position.Y else root.Position.Y + 1.5
			for _, site in sites do
				local ri = roomAt(site, root.Position, 1)
				if ri then
					local r = site.rooms[ri]
					local depth = SmokeSim.layer(r.sim.smoke, r.height, Cfg)
					local inLayer = headY >= r.floorY + r.height - depth
					smoke = if inLayer then r.sim.smoke else r.sim.smoke * 0.25
					local air = tonumber(p:GetAttribute("OxygenAir")) or 0
					local rate = SmokeSim.playerHeatRate(smoke, r.sim.heat, p:GetAttribute("GasMask") == true, air > 0, Cfg)
					if rate > 0 and p:GetAttribute(Names.Attr.Downed) ~= true then
						call("HeatService", "AddHeat", p, rate * dt, "smoke")
					end
					break
				end
			end
		end
		local v = q(smoke, 0.05)
		if p:GetAttribute("InSmoke") ~= v then
			p:SetAttribute("InSmoke", if v > 0 then v else nil)
		end
	end
	-- rescue NPCs choke slowly
	local now = os.clock()
	for _, npc in CollectionService:GetTagged(Names.Tag.Rescuable) do
		local state = npc:GetAttribute(Names.Attr.RescueState)
		local id = npc:GetAttribute(Names.Attr.RescueId)
		if (state ~= "Trapped" and state ~= "Downed") or type(id) ~= "string" or not npc:IsA("Model") then
			continue
		end
		local pos = (npc :: Model):GetPivot().Position
		for _, site in sites do
			local ri = roomAt(site, pos, 1)
			if ri then
				local dps = SmokeSim.chokeDps(site.simRooms[ri].smoke, Cfg)
				if dps > 0 then
					call("RescueService", "Hurt", id, dps * dt, nil)
					if now - (lastCough[npc] or 0) >= Cfg.CoughEvery then
						lastCough[npc] = now
						local lines = { "*cough cough*", "*hack* can't breathe!", "*wheeze*", "Smoky! *cough*" }
						Popup.show(npc, lines[math.random(1, #lines)], "bad")
					end
				end
				break
			end
		end
	end
end

local function tick(dt: number)
	if next(sites) == nil then
		return
	end
	local t0 = os.clock()
	for _, site in sites do
		for _, r in site.simRooms do
			r.fire = 0
		end
	end
	for _, inst in CollectionService:GetTagged(Names.Tag.Burning) do
		local e = burnIndex[inst :: BasePart]
		if e then
			local r = e.site.simRooms[e.room]
			r.fire += tonumber(inst:GetAttribute(Names.Attr.FireLevel)) or 1
		end
	end
	local now = os.clock()
	for _, site in sites do
		local s0 = os.clock()
		for li in site.links do
			refreshLink(site, li)
		end
		handleEvents(site, SmokeSim.step(site.simRooms, site.simLinks, dt, Cfg))
		for _, r in site.rooms do
			writeRoom(r)
		end
		for _, l in site.links do
			writeLink(site, l)
		end
		puffs(site, now)
		site.tickMs = site.tickMs * 0.9 + (os.clock() - s0) * 1000 * 0.1
		site.folder:SetAttribute("TickMs", q(site.tickMs, 0.01))
	end
	exposure(dt)
	if (os.clock() - t0) * 1000 > Cfg.TickBudgetMs then
		Telemetry.count("smoke_tick_over_budget")
	end
end

---------------------------------------------------------------------------------------------- boot

function SmokeService:Init(all: { [string]: any })
	services = all
end

function SmokeService:Start()
	FxRemote = Net.event("Smoke", "Fx")
	local acc, syncAcc = 0, 1
	RunService.Heartbeat:Connect(function(dt: number)
		syncAcc += dt
		if syncAcc >= 1 then
			syncAcc = 0
			local ok, err = pcall(syncSites)
			if not ok then
				warn(`[SmokeService] sync: {err}`)
			end
		end
		acc += dt
		local period = 1 / Cfg.TickHz
		if acc >= period then
			acc = math.min(acc - period, period)
			local ok, err = pcall(tick, period)
			if not ok then
				warn(`[SmokeService] tick: {err}`)
			end
		end
	end)
end

function SmokeService:GetRoomAt(pos: Vector3): { smoke: number, heat: number, pressure: number, stage: number }?
	for _, site in sites do
		local ri = roomAt(site, pos, 1)
		if ri then
			local r = site.simRooms[ri]
			return { smoke = r.smoke, heat = r.heat, pressure = r.pressure, stage = r.stage }
		end
	end
	return nil
end

function SmokeService:ActiveSites(): { string }
	local out = {}
	for id in sites do
		table.insert(out, id)
	end
	table.sort(out)
	return out
end

---------------------------------------------------------------------------------------------- test hooks

function SmokeService:_activate(siteId: string): boolean
	local m = siteModel(siteId)
	if not m then
		return false
	end
	forced[siteId] = m
	syncSites()
	return true
end

function SmokeService:_deactivate(siteId: string)
	forced[siteId] = nil
	deactivate(siteId)
end

function SmokeService:_state(siteId: string?): any
	local out = {}
	for id, site in sites do
		if siteId and id ~= siteId then
			continue
		end
		local rooms = {}
		for i, r in site.rooms do
			local s = r.sim
			table.insert(rooms, {
				i = i,
				storey = r.storey,
				area = math.floor(s.area),
				parts = #r.parts,
				smoke = q(s.smoke, 0.01),
				heat = q(s.heat, 0.1),
				pressure = q(s.pressure, 0.01),
				stage = s.stage,
				fire = s.fire,
				vented = s.vented,
				centre = r.centre,
			})
		end
		local links = {}
		for i, l in site.links do
			table.insert(links, {
				i = i,
				kind = l.sim.kind,
				a = l.sim.a,
				b = l.sim.b,
				open = l.sim.open,
				part = if l.part then l.part:GetFullName() else nil,
				pos = if l.part then l.part.Position else nil,
			})
		end
		out[id] = { rooms = rooms, links = links, tickMs = site.tickMs, buildings = #site.buildings }
	end
	return out
end

function SmokeService:_set(siteId: string, room: number, field: string, value: number): boolean
	local site = sites[siteId]
	local r = site and site.simRooms[room]
	if not r or (r :: any)[field] == nil then
		return false
	end
	(r :: any)[field] = value
	return true
end

function SmokeService:_selftest(): (boolean, string)
	-- A 2-room test house far above the map: front door to outside, inner door between the rooms,
	-- a window on room 2. Checks the derived rooms + links, then cleans up.
	local m = Instance.new("Model")
	m.Name = "SmokeSelftest"
	local function part(name: string, cf: CFrame, size: Vector3, tag: string?): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.CFrame = cf
		if tag then
			p:AddTag(tag)
		end
		p.Parent = m
		return p
	end
	local base = CFrame.new(0, 800, 0)
	-- 20 x 12 footprint, walls 10 tall
	part("Wall", base * CFrame.new(-6, 5, 0), Vector3.new(8, 10, 1))
	part("Wall", base * CFrame.new(6, 5, 0), Vector3.new(8, 10, 1))
	part("Door", base * CFrame.new(0, 3.5, 0), Vector3.new(4, 7, 0.6), Names.Tag.Door)
	part("Lintel", base * CFrame.new(0, 8.5, 0), Vector3.new(4, 3, 1))
	part("Wall", base * CFrame.new(0, 5, 12), Vector3.new(20, 10, 1))
	part("Wall", base * CFrame.new(-10, 5, 6), Vector3.new(1, 10, 12))
	part("Wall", base * CFrame.new(10, 5, 3), Vector3.new(1, 10, 6))
	part("Wall", base * CFrame.new(10, 5, 10.5), Vector3.new(1, 10, 3))
	part("Window", base * CFrame.new(10, 5, 7.5) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(3, 4, 0.3), Names.Tag.Window)
	part("Partition", base * CFrame.new(2, 5, 2.5), Vector3.new(1, 10, 5))
	part("Partition", base * CFrame.new(2, 5, 10.5), Vector3.new(1, 10, 3))
	part("Door", base * CFrame.new(2, 3.5, 7) * CFrame.Angles(0, math.pi / 2, 0), Vector3.new(4, 7, 0.6), Names.Tag.Door)
	m.Parent = workspace
	local ok, res = pcall(derive, "_selftest", m)
	m:Destroy()
	if not ok then
		return false, tostring(res)
	end
	local site = res :: Site?
	if not site then
		return false, "no rooms derived"
	end
	site.folder:Destroy()
	local kinds = {}
	for _, l in site.links do
		table.insert(kinds, `{l.sim.kind}:{l.sim.a}-{l.sim.b}`)
	end
	local summary = `{#site.rooms} rooms, links {table.concat(kinds, " ")}`
	if #site.rooms ~= 2 then
		return false, summary
	end
	local outsideDoors, innerDoors, windows = 0, 0, 0
	for _, l in site.links do
		if l.sim.kind == "door" and l.sim.b == 0 then
			outsideDoors += 1
		elseif l.sim.kind == "door" then
			innerDoors += 1
		elseif l.sim.kind == "window" and l.sim.b == 0 then
			windows += 1
		end
	end
	if outsideDoors ~= 1 or innerDoors ~= 1 or windows ~= 1 then
		return false, summary
	end
	return true, "ok: " .. summary
end

return SmokeService
