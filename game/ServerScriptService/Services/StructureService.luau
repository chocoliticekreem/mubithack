--!strict
-- StructureService [owner: Structure agent]. HOUSES BURN DOWN. Every building (a Model tagged IncidentSite,
-- else the outermost Model with a BuildingId attr) is a structure of chunks: Wall*/Partition* walls,
-- Roof*/Ceiling*/Gable*/Ridge* roof, Floor* floors and Window-tagged panes. Fire wears chunks down; when a
-- section's supports fail it creaks for WarnSeconds, then COLLAPSES for real (joints broken, unanchored,
-- dust cloud, trim and furniture ride down with it). Windows blow out (glass), roofs cave in, upper floors
-- give way into the room below, smoke pours from broken windows, and at TotalLossAt the house drops to a
-- smoking blackened shell (TOTAL LOSS). People under a collapse get hurt. Rubble is capped, settles, anchors.
-- The maths is Lib/Fire/Structure (pure, spec-tested); this file owns the Roblox side.
--
-- Public API:
--   StructureService:Index(model: Model): boolean                 -- eager (otherwise indexed on first fire)
--   StructureService:GetIntegrity(key: string | Instance): number? -- key = SiteId, BuildingId or a Model/part;
--                                                                   a container -> its worst building (nil: none)
--   StructureService:IsTotalLoss(key): boolean
--   StructureService:Saved(key): boolean                           -- mission star "save the building"
--   StructureService:ResetSite(key): boolean                        -- restore moved parts, forget the state
-- Signals: IntegrityChanged(model: Model, integrity: number), Collapsed(model: Model, kind: string, at: Vector3),
--          TotalLoss(model: Model, siteId: string?)
-- Remotes: Structure/Fx (S->C all: kind "creak"|"collapse"|"shatter"|"totalloss", pos: Vector3, data: table)
-- Writes: tag StructureConfig.Tag on building Models; attrs Integrity (0..100), TotalLoss, Smoking, Center
--   (Vector3), SmokeTop (Vector3) on them; Integrity/TotalLoss on Workspace.Runs.<runId> whose SiteId matches;
--   Window parts: attr Broken = true (AudioController plays the shatter), transparent, no collision.
-- Consumes (nil-guarded): FireService.Ignited/Spread/Extinguished/Charred (+ Burning tag as a fallback),
--   HazardService:Trigger(scope, "ceiling_collapse", { parts }) for roof-only sections (it owns the roof
--   creak, the shake and hurting players under it; we add NPC damage, trim, dust and rubble settling),
--   HeatService:AddHeat, RescueService:Hurt(rescueId, amount), MapService.SiteRebuilt/SiteReset (reset),
--   Shared/Ragdoll, Config/HazardConfig.CollapseWarnSeconds.
-- Counters: structures_indexed, structure_collapses, structure_roof_handoffs, windows_shattered,
--   structures_lost, structure_debris_crumbled, structure_hurt_players, structure_hurt_npcs,
--   structure_tick_over_budget
-- Test hooks (DevHook only): _char(model, kind?, n?), _state(model), _selftest()
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("StructureConfig") :: ModuleScript) :: any
local Structure = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Fire"):WaitForChild("Structure") :: ModuleScript)

local StructureService = {}
StructureService.Priority = 75
StructureService.IntegrityChanged = Signal.new() :: Signal.Signal<Model, number>
StructureService.Collapsed = Signal.new() :: Signal.Signal<Model, string, Vector3>
StructureService.TotalLoss = Signal.new() :: Signal.Signal<Model, string?>

local INCIDENT_SITE = "IncidentSite" -- v2 tag (docs/game/08); not in the frozen Names yet

type Saved = { cf: CFrame, anchored: boolean, collide: boolean, query: boolean, transparency: number }
type Rec = {
	model: Model,
	s: Structure.Struct,
	parts: { BasePart }, -- chunk id -> part
	attach: { [number]: { BasePart } }, -- chunk id -> trim / furniture that rides down with it
	saved: { [BasePart]: Saved },
	scope: string?, -- instanceId / locationId (HazardService scope, notify scope)
	siteId: string?,
	center: Vector3,
	lastBurnAt: number,
	lastNotify: number,
	integrity: number,
	pending: number, -- sections creaking right now
	active: boolean,
	conn: RBXScriptConnection?,
}

local services: { [string]: any } = {}
local recs: { [Model]: Rec } = {}
local partRec: { [BasePart]: Rec } = {}
local partId: { [BasePart]: number } = {}
local notStructure: { [Instance]: boolean } = {}
local debris: { { part: BasePart, at: number, rec: Rec } } = {}
local loose: { [BasePart]: boolean } = {}
local looseCount = 0
local fxRemote: RemoteEvent? = nil
local rng = Random.new()

local function count(name: string, n: number?)
	Telemetry.count(name, n or 1)
end

local function roll(): number
	return rng:NextNumber()
end

local function fx(kind: string, pos: Vector3, data: { [string]: any })
	if fxRemote then
		fxRemote:FireAllClients(kind, pos, data)
	end
end

---------------------------------------------------------------------------------------------- discovery

local function structureRootOf(inst: Instance): Model?
	local node = inst.Parent
	local best: Model? = nil
	while node and node ~= workspace and node ~= game do
		if node:IsA("Model") then
			if node:HasTag(INCIDENT_SITE) then
				return node
			end
			if node:GetAttribute(Names.Attr.BuildingId) ~= nil then
				best = node -- keep walking: the outermost building Model wins
			end
		end
		node = node.Parent
	end
	return best
end

local function scopeOf(model: Instance): string?
	local node: Instance? = model
	while node and node ~= workspace do
		local inst = node:GetAttribute(Names.Attr.InstanceId)
		if type(inst) == "string" and inst ~= "" then
			return inst
		end
		local loc = node:GetAttribute(Names.Attr.LocationId)
		if type(loc) == "string" and loc ~= "" then
			return loc
		end
		node = node.Parent
	end
	return nil
end

-- World-space AABB half extents of a rotated box.
local function halfExtents(cf: CFrame, size: Vector3): Vector3
	local h = size / 2
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	return Vector3.new(
		math.abs(r.X) * h.X + math.abs(u.X) * h.Y + math.abs(l.X) * h.Z,
		math.abs(r.Y) * h.X + math.abs(u.Y) * h.Y + math.abs(l.Y) * h.Z,
		math.abs(r.Z) * h.X + math.abs(u.Z) * h.Y + math.abs(l.Z) * h.Z
	)
end

local MARKER_TAGS = { Names.Tag.FireStart, Names.Tag.RescueSpawn, Names.Tag.TruckSpot, Names.Tag.RescueDropoff }

local function isMarker(p: BasePart): boolean
	if p.Transparency >= 1 then
		return true
	end
	for _, t in MARKER_TAGS do
		if p:HasTag(t) then
			return true
		end
	end
	return p.Name == "ArrivalZone"
end

local function drop(rec: Rec)
	if recs[rec.model] ~= rec then
		return
	end
	recs[rec.model] = nil
	for _, p in rec.parts do
		partRec[p] = nil
		partId[p] = nil
	end
	for _, list in rec.attach do
		for _, p in list do
			partRec[p] = nil
		end
	end
	if rec.conn then
		rec.conn:Disconnect()
	end
	for i = #debris, 1, -1 do
		if debris[i].rec == rec then
			loose[debris[i].part] = nil
			table.remove(debris, i)
			looseCount -= 1
		end
	end
end

local function track(rec: Rec, p: BasePart)
	if not loose[p] then
		loose[p] = true
		looseCount += 1
		table.insert(debris, { part = p, at = os.clock(), rec = rec })
	end
end

local function index(model: Model): Rec?
	if recs[model] then
		return recs[model]
	end
	if notStructure[model] then
		return nil
	end
	local boxes: { Structure.Box } = {}
	local parts: { BasePart } = {}
	local others: { BasePart } = {}
	local scanned = 0
	for _, d in model:GetDescendants() do
		if not d:IsA("BasePart") then
			continue
		end
		scanned += 1
		if scanned > Cfg.MaxPartsPerStructure then
			break
		end
		if not d.Anchored or isMarker(d) or partRec[d] then
			continue
		end
		local parent = d.Parent
		if parent and parent:FindFirstChildOfClass("Humanoid") then
			continue
		end
		local kind = Structure.classify(d.Name, d:HasTag(Names.Tag.Window))
		if kind then
			local h = halfExtents(d.CFrame, d.Size)
			local p = d.Position
			table.insert(boxes, { kind = kind, x = p.X, y = p.Y, z = p.Z, hx = h.X, hy = h.Y, hz = h.Z })
			table.insert(parts, d)
		else
			table.insert(others, d)
		end
	end
	local structural = 0
	for _, b in boxes do
		if b.kind ~= "window" then
			structural += 1
		end
	end
	if structural < Cfg.MinChunks then
		notStructure[model] = true
		model.Destroying:Once(function()
			notStructure[model] = nil
		end)
		return nil
	end
	local s = Structure.new(boxes, Cfg)
	local rec: Rec = {
		model = model,
		s = s,
		parts = parts,
		attach = {},
		saved = {},
		scope = scopeOf(model),
		siteId = (model:GetAttribute("SiteId") :: any) or nil,
		center = Vector3.zero,
		lastBurnAt = 0,
		lastNotify = 0,
		integrity = 100,
		pending = 0,
		active = false,
		conn = nil,
	}
	-- trim, shutters, doors-in-walls and furniture resting on upper floors ride down with their chunk
	local sum, top = Vector3.zero, -math.huge
	for _, c in s.chunks do
		sum += Vector3.new(c.x, c.y, c.z)
		top = math.max(top, c.y + c.hy)
	end
	rec.center = sum / #s.chunks
	for _, o in others do
		local p = o.Position
		local h = halfExtents(o.CFrame, o.Size)
		for _, c in s.chunks do
			if c.kind == "ground" or c.kind == "window" then
				continue
			end
			local inside = math.abs(p.X - c.x) <= c.hx + 1.2 and math.abs(p.Y - c.y) <= c.hy + 1.2 and math.abs(p.Z - c.z) <= c.hz + 1.2
			local resting = c.kind == "floor"
				and math.abs(p.X - c.x) <= c.hx
				and math.abs(p.Z - c.z) <= c.hz
				and math.abs((p.Y - h.Y) - (c.y + c.hy)) <= 1.5
			if inside or resting then
				local list = rec.attach[c.id]
				if not list then
					list = {}
					rec.attach[c.id] = list
				end
				if #list < Cfg.AttachMaxPerChunk then
					table.insert(list, o)
					partRec[o] = rec
				end
				break
			end
		end
	end
	for i, p in parts do
		partRec[p] = rec
		partId[p] = i
	end
	recs[model] = rec
	rec.conn = model.Destroying:Connect(function()
		drop(rec)
	end)
	CollectionService:AddTag(model, Cfg.Tag)
	model:SetAttribute("Integrity", 100)
	model:SetAttribute("Center", rec.center)
	model:SetAttribute("SmokeTop", Vector3.new(rec.center.X, top + 2, rec.center.Z))
	count("structures_indexed")
	return rec
end

local function ensure(part: BasePart): (Rec?, number?)
	local rec = partRec[part]
	if not rec then
		local root = structureRootOf(part)
		if root and not recs[root] and not notStructure[root] then
			index(root)
		end
		rec = partRec[part]
	end
	return rec, partId[part]
end

---------------------------------------------------------------------------------------------- people

local function playersNear(rec: Rec): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		local tag = p:GetAttribute(Names.Attr.InstanceId)
		local char = p.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if (rec.scope and tag == rec.scope) or (hrp and (hrp.Position - rec.center).Magnitude <= Cfg.NotifyRadius) then
			table.insert(out, p)
		end
	end
	return out
end

local function notify(rec: Rec, text: string, kind: string, force: boolean?)
	local now = os.clock()
	if not force and now - rec.lastNotify < 4 then
		return
	end
	rec.lastNotify = now
	for _, p in playersNear(rec) do
		Net.notify(p, text, kind)
	end
end

local function ragdollModule(): any
	local ok, R = pcall(require, Shared:WaitForChild("Ragdoll") :: ModuleScript)
	return if ok then R else nil
end

local function knock(character: Model, seconds: number, impulse: Vector3)
	local R = ragdollModule()
	if R then
		pcall(R.enable, character, seconds)
		pcall(R.knockback, character, impulse)
	end
end

local function hurtPeople(rec: Rec, centre: Vector3, size: Vector3, top: number, skipPlayers: boolean)
	local radius = math.max(size.X, size.Z) / 2 + Cfg.HurtRadius
	local function flat(a: Vector3): number
		return Vector3.new(a.X - centre.X, 0, a.Z - centre.Z).Magnitude
	end
	if not skipPlayers then
		for _, p in Players:GetPlayers() do
			local char = p.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not char or not hrp or hrp.Position.Y > top + 3 then
				continue
			end
			local d = flat(hrp.Position)
			local dmg = Structure.hurtAmount(d, radius, Cfg.PlayerHeat)
			if dmg > 0 then
				local Heat = services.HeatService
				if Heat and type(Heat.AddHeat) == "function" then
					pcall(Heat.AddHeat, Heat, p, dmg, "collapse")
				end
				local away = Vector3.new(hrp.Position.X - centre.X, 0, hrp.Position.Z - centre.Z)
				away = if away.Magnitude > 0.1 then away.Unit else Vector3.new(1, 0, 0)
				knock(char, Cfg.RagdollSeconds, away * 30 + Vector3.new(0, 18, 0))
				count("structure_hurt_players")
				Popup.show(p, "BONK! Building fell on you", "bad", p)
			end
		end
	end
	local trapped = 0
	local Rescue = services.RescueService
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if not m:IsA("Model") then
			continue
		end
		local st = m:GetAttribute(Names.Attr.RescueState)
		if st == "Rescued" or st == "Toasted" then
			continue
		end
		local root = m.PrimaryPart
		if not root or root.Position.Y > top + 3 then
			continue
		end
		local dmg = Structure.hurtAmount(flat(root.Position), radius, Cfg.NpcDamage)
		if dmg > 0 then
			local id = m:GetAttribute(Names.Attr.RescueId)
			if Rescue and type(Rescue.Hurt) == "function" and type(id) == "string" then
				pcall(Rescue.Hurt, Rescue, id, dmg, nil)
			end
			if st ~= "Carried" then
				knock(m, 1.5, Vector3.new(rng:NextNumber(-12, 12), 14, rng:NextNumber(-12, 12)))
			end
			trapped += 1
			count("structure_hurt_npcs")
		end
	end
	if trapped > 0 then
		notify(rec, "Someone's trapped under the rubble! GET THEM OUT!", "bad", true)
	end
end

---------------------------------------------------------------------------------------------- physics

local function save(rec: Rec, p: BasePart)
	if not rec.saved[p] then
		rec.saved[p] = { cf = p.CFrame, anchored = p.Anchored, collide = p.CanCollide, query = p.CanQuery, transparency = p.Transparency }
	end
end

local function fallPart(rec: Rec, p: BasePart)
	if not p.Parent or not p.Anchored then
		return
	end
	save(rec, p)
	for _, j in p:GetJoints() do
		if j:IsA("JointInstance") or j:IsA("WeldConstraint") then
			j:Destroy()
		end
	end
	if looseCount >= Cfg.MaxLooseDebris then
		-- over budget: crumble to dust instead of adding another physics body
		p.Transparency = 1
		p.CanCollide = false
		p.CanQuery = false
		count("structure_debris_crumbled")
		return
	end
	p.CanCollide = true
	p.Anchored = false
	local k = Cfg.FallKick
	p.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-k, k), rng:NextNumber(-k / 2, k / 2), rng:NextNumber(-k, k))
	pcall(function()
		p:SetNetworkOwner(nil) -- server simulates rubble: nobody can fling it at the squad
	end)
	track(rec, p)
end

local function bboxOf(parts: { BasePart }): (Vector3, Vector3, number)
	local lo = Vector3.new(math.huge, math.huge, math.huge)
	local hi = -lo
	for _, p in parts do
		local h = halfExtents(p.CFrame, p.Size)
		lo = lo:Min(p.Position - h)
		hi = hi:Max(p.Position + h)
	end
	return (lo + hi) / 2, hi - lo, hi.Y
end

local function dominantKind(rec: Rec, ids: { number }): string
	local tally: { [string]: number } = {}
	local best, bestN = "wall", 0
	for _, id in ids do
		local k = rec.s.chunks[id].kind
		tally[k] = (tally[k] or 0) + 1
		if tally[k] > bestN then
			best, bestN = k, tally[k]
		end
	end
	return best
end

local LINES = {
	roof = "*CREEEAK* THE ROOF IS COMING DOWN!",
	floor = "*CRACK* The floor is giving way!",
	wall = "*GROAN* A wall is about to go!",
	partition = "*CREAK* Inside wall collapsing!",
}

local function warnSeconds(roofHandoff: boolean): number
	if roofHandoff then
		local ok, H = pcall(require, ConfigFolder:WaitForChild("HazardConfig") :: ModuleScript)
		if ok and type(H) == "table" and type((H :: any).CollapseWarnSeconds) == "number" then
			return (H :: any).CollapseWarnSeconds
		end
		return 2.5
	end
	return Cfg.WarnSeconds
end

local function afterFall(rec: Rec, ids: { number }, parts: { BasePart }, kind: string, playersHandled: boolean)
	rec.pending = math.max(0, rec.pending - 1)
	if recs[rec.model] ~= rec then
		return -- reset while it creaked
	end
	local centre, size, top = bboxOf(parts)
	for _, p in parts do
		if p.Parent and p.Anchored then
			fallPart(rec, p)
		elseif p.Parent then
			track(rec, p) -- HazardService unanchored it: make sure it settles and anchors
		end
	end
	for _, id in ids do
		for _, a in rec.attach[id] or {} do
			fallPart(rec, a)
		end
	end
	fx("collapse", centre, { size = size, kind = kind })
	count("structure_collapses")
	hurtPeople(rec, centre, size, top, playersHandled)
	StructureService.Collapsed:Fire(rec.model, kind, centre)
end

-- One section: creak + shake for WarnSeconds, then it falls. Roof-only sections go to HazardService.
local function startCollapse(rec: Rec, ids: { number })
	local parts: { BasePart } = {}
	for _, id in ids do
		local p = rec.parts[id]
		if p and p.Parent and p.Anchored then
			table.insert(parts, p)
		end
	end
	if #parts == 0 then
		return
	end
	local kind = dominantKind(rec, ids)
	local roofOnly = true
	for _, id in ids do
		if rec.s.chunks[id].kind ~= "roof" then
			roofOnly = false
			break
		end
	end
	rec.pending += 1
	local Hazard = services.HazardService
	if roofOnly and rec.scope and Hazard and type(Hazard.Trigger) == "function" then
		for _, p in parts do
			save(rec, p) -- so ResetSite can put HazardService's fallen roof back
		end
		local ok, handled = pcall(Hazard.Trigger, Hazard, rec.scope, "ceiling_collapse", { parts = parts })
		if ok and handled then
			count("structure_roof_handoffs")
			task.delay(warnSeconds(true) + 0.05, afterFall, rec, ids, parts, kind, true)
			return
		end
	end
	local centre, size = bboxOf(parts)
	local warn = warnSeconds(false)
	fx("creak", centre, { size = size, warn = warn, kind = kind })
	if os.clock() - rec.lastNotify >= 4 then -- collapse warnings: small text over the creaking piece
		rec.lastNotify = os.clock()
		Popup.show(centre, LINES[kind] or LINES.wall, "bad")
	end
	task.spawn(function()
		local base: { [BasePart]: CFrame } = {}
		for i, p in parts do
			if i > 24 then
				break -- shake budget
			end
			base[p] = p.CFrame
		end
		local t0 = os.clock()
		while os.clock() - t0 < warn do
			for p, cf in base do
				if p.Parent and p.Anchored then
					p.CFrame = cf * CFrame.new(rng:NextNumber(-0.12, 0.12), 0, rng:NextNumber(-0.12, 0.12))
				end
			end
			task.wait(0.06)
		end
		for p, cf in base do
			if p.Parent and p.Anchored then
				p.CFrame = cf
			end
		end
		afterFall(rec, ids, parts, kind, false)
	end)
end

local function shatterWindow(rec: Rec, id: number)
	Structure.shatter(rec.s, id)
	local p = rec.parts[id]
	if not p or not p.Parent then
		return
	end
	if p:GetAttribute(Names.Attr.Broken) ~= true then
		save(rec, p)
		p:SetAttribute(Names.Attr.Broken, true)
		p.Transparency = 1
		p.CanCollide = false
		p.CanQuery = false
		fx("shatter", p.Position, { cf = p.CFrame, size = p.Size })
		count("windows_shattered")
	end
end

---------------------------------------------------------------------------------------------- run state

local function writeRuns(rec: Rec, integrity: number, lost: boolean)
	if not rec.siteId then
		return
	end
	local runs = workspace:FindFirstChild("Runs")
	if not runs then
		return
	end
	for _, r in runs:GetChildren() do
		if r:GetAttribute("SiteId") == rec.siteId then
			r:SetAttribute("Integrity", integrity)
			r:SetAttribute("TotalLoss", lost)
		end
	end
end

local function setIntegrity(rec: Rec, v: number)
	if v == rec.integrity then
		return
	end
	rec.integrity = v
	rec.model:SetAttribute("Integrity", v)
	writeRuns(rec, v, rec.s.lost)
	StructureService.IntegrityChanged:Fire(rec.model, v)
end

local function totalLoss(rec: Rec)
	local s = rec.s
	s.lost = true
	local plan = Structure.shellPlan(s)
	for _, id in plan do
		Structure.collapse(s, id)
	end
	for _, g in Structure.cluster(s, plan, Cfg.ClusterRadius * 1.5) do
		startCollapse(rec, g)
	end
	rec.model:SetAttribute("TotalLoss", true)
	rec.model:SetAttribute("Smoking", true)
	setIntegrity(rec, 0)
	writeRuns(rec, 0, true)
	count("structures_lost")
	local nick = rec.model:GetAttribute("Nickname") or rec.model:GetAttribute("Address")
	local label = if type(nick) == "string" then nick else "The building"
	notify(rec, `TOTAL LOSS! {label} burned to the ground.`, "bad", true)
	for _, p in playersNear(rec) do
		if fxRemote then
			fxRemote:FireClient(p, "totalloss", rec.center, { model = rec.model })
		end
	end
	StructureService.TotalLoss:Fire(rec.model, rec.siteId)
end

---------------------------------------------------------------------------------------------- tick

-- Parts moved/destroyed by someone else (HazardService's own watcher, explosions) count as collapsed.
local function sync(rec: Rec)
	local s = rec.s
	for id, p in rec.parts do
		local c = s.chunks[id]
		if c.collapsed then
			continue
		end
		if c.kind == "window" then
			if not c.shattered and (not p.Parent or p:GetAttribute(Names.Attr.Broken) == true) then
				Structure.shatter(s, id)
			end
		elseif not p.Parent or not p.Anchored then
			Structure.collapse(s, id)
		elseif c.burning > 0 then
			Structure.setBurning(s, id, tonumber(p:GetAttribute(Names.Attr.FireLevel)) or 0)
		end
	end
end

local function stepRec(rec: Rec, dt: number, now: number)
	local s = rec.s
	sync(rec)
	Structure.tick(s, dt, Cfg)
	if Structure.burningCount(s) > 0 then
		rec.lastBurnAt = now
	end
	for _, id in Structure.windowsToShatter(s, Cfg) do
		shatterWindow(rec, id)
	end
	local fails = Structure.failures(s, Cfg, roll, dt)
	if #fails > 0 then
		local groups = Structure.cluster(s, fails, Cfg.ClusterRadius)
		for i, g in groups do
			if i > Cfg.MaxCollapsesPerTick then
				break -- the rest fail again next tick
			end
			for _, id in g do
				Structure.collapse(s, id)
			end
			startCollapse(rec, g)
		end
	end
	local v = Structure.integrity(s)
	if not s.lost and Structure.isTotalLoss(v, Cfg) then
		totalLoss(rec)
	else
		setIntegrity(rec, v)
	end
	local smoking = s.lost or now - rec.lastBurnAt < Cfg.SmokeLingerSeconds
	if rec.model:GetAttribute("Smoking") ~= smoking then
		rec.model:SetAttribute("Smoking", smoking)
	end
	if not smoking and rec.pending == 0 then
		rec.active = false
	end
end

local function settleDebris(now: number)
	for i = #debris, 1, -1 do
		local d = debris[i]
		local p = d.part
		local age = now - d.at
		local done = not p.Parent
		if not done and p.Position.Y < workspace.FallenPartsDestroyHeight + 50 then
			p.Anchored = true
			p.Transparency = 1
			p.CanCollide = false
			done = true
		elseif not done and (age >= Cfg.SettleMaxSeconds or (age >= Cfg.SettleMinSeconds and p.AssemblyLinearVelocity.Magnitude < Cfg.SettleSpeed)) then
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
			p.Anchored = true
			done = true
		end
		if done then
			loose[p] = nil
			table.remove(debris, i)
			looseCount -= 1
		end
	end
end

local function step(dt: number)
	local t0 = os.clock()
	local now = t0
	for _, rec in recs do
		if rec.active then
			stepRec(rec, dt, now)
		end
	end
	settleDebris(now)
	if (os.clock() - t0) * 1000 > 3 then
		count("structure_tick_over_budget")
	end
end

---------------------------------------------------------------------------------------------- fire hooks

local function onBurning(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local rec, id = ensure(part)
	if not rec then
		return
	end
	rec.active = true
	rec.lastBurnAt = os.clock()
	if id then
		Structure.setBurning(rec.s, id, math.max(1, tonumber(part:GetAttribute(Names.Attr.FireLevel)) or 1))
	end
end

local function onOut(part: Instance, charred: boolean)
	if not part:IsA("BasePart") then
		return
	end
	local rec, id = ensure(part)
	if not rec or not id then
		return
	end
	if charred then
		Structure.setCharred(rec.s, id, Cfg)
		rec.active = true
	else
		Structure.setBurning(rec.s, id, 0)
	end
end

---------------------------------------------------------------------------------------------- reset

local function reset(rec: Rec)
	for p, sv in rec.saved do
		if p.Parent then
			p.Anchored = true
			p.AssemblyLinearVelocity = Vector3.zero
			p.AssemblyAngularVelocity = Vector3.zero
			p.CFrame = sv.cf
			p.Anchored = sv.anchored
			p.CanCollide = sv.collide
			p.CanQuery = sv.query
			p.Transparency = sv.transparency
			if p:HasTag(Names.Tag.Window) then
				p:SetAttribute(Names.Attr.Broken, nil)
			end
		end
	end
	local m = rec.model
	drop(rec)
	if m.Parent then
		CollectionService:RemoveTag(m, Cfg.Tag)
		for _, a in { "Integrity", "TotalLoss", "Smoking", "Center", "SmokeTop" } do
			m:SetAttribute(a, nil)
		end
	end
	writeRuns(rec, 100, false)
end

local function find(key: any): Rec?
	if typeof(key) == "Instance" then
		if key:IsA("Model") and recs[key :: Model] then
			return recs[key :: Model]
		end
		if key:IsA("BasePart") and partRec[key :: BasePart] then
			return partRec[key :: BasePart]
		end
		local root = if key:IsA("Model") and (key:HasTag(INCIDENT_SITE) or key:GetAttribute(Names.Attr.BuildingId) ~= nil)
			then key :: Model
			else structureRootOf(key)
		return root and recs[root] or nil
	elseif type(key) == "string" then
		for m, rec in recs do
			if rec.siteId == key or m:GetAttribute(Names.Attr.BuildingId) == key or m:GetAttribute("SiteId") == key then
				return rec
			end
		end
	end
	return nil
end

---------------------------------------------------------------------------------------------- lifecycle

function StructureService:Init(all: { [string]: any })
	services = all
end

function StructureService:Start()
	fxRemote = Net.event("Structure", "Fx")
	local Fire = services.FireService
	if Fire then
		if Fire.Ignited then
			Fire.Ignited:Connect(function(part: BasePart)
				onBurning(part)
			end)
		end
		if Fire.Spread then
			Fire.Spread:Connect(function(_from: BasePart, to: BasePart)
				onBurning(to)
			end)
		end
		if Fire.Extinguished then
			Fire.Extinguished:Connect(function(part: BasePart)
				onOut(part, false)
			end)
		end
		if Fire.Charred then
			Fire.Charred:Connect(function(part: BasePart)
				onOut(part, true)
			end)
		end
	end
	-- fallback for fires lit outside FireService's signals; every handler above is idempotent
	CollectionService:GetInstanceAddedSignal(Names.Tag.Burning):Connect(onBurning)
	CollectionService:GetInstanceRemovedSignal(Names.Tag.Burning):Connect(function(part: Instance)
		onOut(part, part:GetAttribute(Names.Attr.Charred) == true)
	end)
	local Map = services.MapService
	if Map then
		for _, sigName in { "SiteRebuilt", "SiteReset" } do
			local sig = Map[sigName]
			if sig and type(sig.Connect) == "function" then
				sig:Connect(function(a: any, b: any)
					local rec = find(a) or find(b)
					if rec then
						reset(rec)
					end
				end)
			end
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		local period = 1 / Cfg.TickHz
		if acc >= period then
			acc = if acc > period * 2 then 0 else acc - period
			step(period)
		end
	end)
end

function StructureService:Index(model: Model): boolean
	return typeof(model) == "Instance" and model:IsA("Model") and index(model) ~= nil
end

function StructureService:GetIntegrity(key: string | Instance): number?
	local rec = find(key)
	if rec then
		return rec.integrity
	end
	-- a container (v1.5 mission instance, a location): its worst damaged building, nil if none indexed
	if typeof(key) == "Instance" then
		local worst: number? = nil
		for m, r in recs do
			if m:IsDescendantOf(key) then
				worst = math.min(worst or 100, r.integrity)
			end
		end
		return worst
	end
	return nil
end

function StructureService:IsTotalLoss(key: string | Instance): boolean
	local rec = find(key)
	return rec ~= nil and rec.s.lost
end

function StructureService:Saved(key: string | Instance): boolean
	local rec = find(key)
	return rec == nil or Structure.saved(rec.integrity, Cfg) -- never indexed = never burned = saved
end

function StructureService:ResetSite(key: string | Instance): boolean
	local rec = find(key)
	if not rec then
		return false
	end
	reset(rec)
	return true
end

---------------------------------------------------------------------------------------------- test hooks

-- Char `n` chunks of `kind` (default roof) in a building, as if the fire burnt them out.
function StructureService:_char(model: Model, kind: string?, n: number?): number
	local rec = recs[model] or index(model)
	if not rec then
		return 0
	end
	local done = 0
	for id, c in rec.s.chunks do
		if c.kind == (kind or "roof") and not c.charred and done < (n or math.huge) then
			onOut(rec.parts[id], true)
			done += 1
		end
	end
	return done
end

function StructureService:_state(model: Model): { [string]: any }?
	local rec = recs[model]
	if not rec then
		return nil
	end
	local kinds: { [string]: number } = {}
	local collapsed = 0
	for _, c in rec.s.chunks do
		kinds[c.kind] = (kinds[c.kind] or 0) + 1
		if c.collapsed then
			collapsed += 1
		end
	end
	return { integrity = rec.integrity, lost = rec.s.lost, kinds = kinds, collapsed = collapsed, loose = looseCount, active = rec.active }
end

function StructureService:_selftest(): (boolean, string)
	if not fxRemote then
		return false, "remote not declared"
	end
	-- a tiny two-wall shed far above the map: index it, char its walls, check integrity drops, reset
	local m = Instance.new("Model")
	m.Name = "StructureSelftest"
	m:SetAttribute(Names.Attr.BuildingId, "_selftest")
	local function mk(name: string, pos: Vector3, size: Vector3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Anchored = true
		p.Size = size
		p.Position = pos
		p.Parent = m
		return p
	end
	local y = 1500
	mk("Floor", Vector3.new(0, y, 0), Vector3.new(16, 1, 16))
	for i = 0, 3 do
		mk(`Wall_{i}`, Vector3.new(-8, y + 6.5, -6 + i * 4), Vector3.new(1, 12, 4))
		mk(`Wall_{i + 4}`, Vector3.new(8, y + 6.5, -6 + i * 4), Vector3.new(1, 12, 4))
	end
	mk("Roof", Vector3.new(0, y + 13, 0), Vector3.new(18, 1, 16))
	m.Parent = workspace
	local result, message = true, "ok"
	local ok, err = pcall(function()
		local rec = index(m)
		if not rec then
			result, message = false, "not indexed"
			return
		end
		if m:GetAttribute("Integrity") ~= 100 then
			result, message = false, "Integrity attr not 100"
			return
		end
		for id, c in rec.s.chunks do
			if c.kind == "wall" then
				Structure.setCharred(rec.s, id, Cfg)
			end
		end
		local v = Structure.integrity(rec.s)
		if v >= 100 then
			result, message = false, "charring did not lower integrity"
			return
		end
		local f = Structure.failures(rec.s, Cfg, function()
			return 1
		end, 0.25)
		local roofFalls = false
		for _, id in f do
			if rec.s.chunks[id].kind == "roof" then
				roofFalls = true
			end
		end
		if not roofFalls then
			result, message = false, "roof did not lose its supports"
		end
	end)
	local rec = recs[m]
	if rec then
		reset(rec)
	end
	m:Destroy()
	if not ok then
		return false, tostring(err)
	end
	return result, message
end

return StructureService
