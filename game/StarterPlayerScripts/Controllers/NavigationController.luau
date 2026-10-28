--!strict
-- NavigationController [owner: Navigation]. The client half of the GPS (docs/game/08 "Navigation").
-- Renders only replicated state, all locally (each player sees their own squad's route, so parallel
-- squads at different sites never interfere):
--   LocalPlayer attrs WaypointPos / WaypointLabel (NavigationService) -> waypoint pin, 3D beacon
--     (tall light beam + floating label with distance), off-screen edge arrow, GPS route
--   Workspace.Map.City.RoadGraphJson (or the RoadGraph folder)        -> roads on the maps, A* routes
--   tag IncidentSite with Busy = true                                  -> pulsing flames on the maps
--   other Players (same SquadId = teammates with helmet numbers)       -> dots
--   tag Truck (OwnerUserId / Driver = me -> "my truck")                -> truck icons
-- GPS: every NavigationConfig.RouteRefresh s (or as soon as you're OffRouteDistance off the line) the
-- shortest road path from you (or the truck you're driving) to the target is recomputed
-- (ClientLib/Pathfind A*), drawn as glowing chevrons on the road (pooled neon parts) and on the
-- maps, with turn hints ("TURN LEFT in 80 studs").
-- M (or the minimap's M button) opens the big map; clicking it drops a personal pin that the GPS
-- follows until the server sets a new waypoint (click near the pin again to clear it).
-- Public (for other controllers): NavigationController:GetTarget(): (Vector3?, string?),
--   NavigationController:GetRoadDir(x, z, range?): (dx?, dz?)  -- nearest road's direction
--   NavigationController:GetRouteInfo(): RouteInfo?  -- the live GPS route (DriveController's ARRIVING bar,
--     big TURN arrow and WRONG WAY card): { total, left (studs of road), turn ("left"|"right"|"uturn"|nil),
--     turnDist, dx, dz (route direction where you are), arrived, off (studs from the route line), ax, az (a point
--     DriveConfig.AssistLookAhead studs further along: VehicleController's touch route assist) }; nil = no target
local CollectionService = game:GetService("CollectionService")
local ContextActionService = game:GetService("ContextActionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local NavigationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("NavigationConfig") :: ModuleScript) :: any
local DriveConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DriveConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript)
local Pathfind = require(ClientLib:WaitForChild("Pathfind") :: ModuleScript)
local Minimap = require(ClientLib:WaitForChild("Minimap") :: ModuleScript)
local Loc = require(game:GetService("ReplicatedStorage"):WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local NavigationController = {}
NavigationController.Priority = 70

local player = Players.LocalPlayer
local Tag = Names.Tag :: any
local Attr = Names.Attr :: any
local TRUCK_TAG: string = Tag.Truck or "Truck"
local INCIDENT_TAG = "IncidentSite"

local mm: any = nil
local graph: Pathfind.Graph? = nil
local graphSource: Instance? = nil
local route: { Pathfind.P }? = nil
local routeTarget: Vector3? = nil
local lastRouteAt = 0
local pin: Vector3? = nil -- personal pin from the big map
local fx: Folder? = nil

-- helpers --------------------------------------------------------------------------------------

local function unit(d: number): string
	local per = tonumber(NavigationConfig.StudsPerUnit) or 1
	local n = d / per
	n = if n >= 100 then math.floor(n / 10 + 0.5) * 10 else math.floor(n + 0.5)
	return Loc.t("{1} " .. (NavigationConfig.UnitName or "studs"), { n })
end

local function partPos(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		local ok, cf = pcall(function()
			return (inst :: Model):GetPivot()
		end)
		return if ok then cf.Position else nil
	end
	return nil
end

-- Where I am: the root part, which rides along inside a truck seat.
local function myRoot(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function mySeat(): BasePart?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum and hum.SeatPart or nil
end

local function target(): (Vector3?, string?)
	if pin then
		return pin, "MY PIN"
	end
	local pos = player:GetAttribute("WaypointPos")
	if typeof(pos) == "Vector3" then
		local label = player:GetAttribute("WaypointLabel")
		return pos, if type(label) == "string" then label else "DESTINATION"
	end
	return nil, nil
end

function NavigationController:GetTarget(): (Vector3?, string?)
	return target()
end

-- Direction (unit dx, dz) of the road nearest to (x, z), if its centre line is within `range` studs
-- (VehicleController's touch steering assist lines a released truck up with it). Cached briefly.
local roadDirCache: { x: number, z: number, at: number, dx: number?, dz: number? }? = nil
function NavigationController:GetRoadDir(x: number, z: number, range: number?): (number?, number?)
	local g = graph
	if not g then
		return nil, nil
	end
	local c = roadDirCache
	local now = os.clock()
	if c and now - c.at < 0.15 and math.abs(c.x - x) + math.abs(c.z - z) < 4 then
		return c.dx, c.dz
	end
	local snap = Pathfind.nearestOnEdge(g, x, z)
	local dx, dz = nil, nil
	if snap and snap.dist <= (range or 20) and snap.a ~= snap.b then
		local a, b = g.pos[snap.a], g.pos[snap.b]
		local lx, lz = b.x - a.x, b.z - a.z
		local len = math.sqrt(lx * lx + lz * lz)
		if len > 1e-3 then
			dx, dz = lx / len, lz / len
		end
	end
	roadDirCache = { x = x, z = z, at = now, dx = dx, dz = dz }
	return dx, dz
end

-- road graph -----------------------------------------------------------------------------------

local function nodeId(v: Instance?): string?
	if not v then
		return nil
	end
	local id = v:GetAttribute("NodeId")
	if id ~= nil then
		return tostring(id)
	end
	return v.Name
end

-- RoadGraph folder: RoadNode parts (attr NodeId) + RoadEdge ObjectValues. An edge names its ends
-- with attrs A / B (NodeIds), child ObjectValues A / B, or Value (= A) + attr B.
local function graphFromFolder(folder: Instance): Pathfind.Graph?
	local nodes: { [string]: { number } } = {}
	local edges: { { string } } = {}
	for _, d in folder:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "RoadNode" or d:GetAttribute("NodeId") ~= nil) then
			local id = nodeId(d)
			if id then
				nodes[id] = { d.Position.X, d.Position.Y, d.Position.Z }
			end
		end
	end
	for _, d in folder:GetDescendants() do
		if d.Name ~= "RoadEdge" then
			continue
		end
		local a: any = d:GetAttribute("A")
		local b: any = d:GetAttribute("B")
		local ca, cb = d:FindFirstChild("A"), d:FindFirstChild("B")
		if a == nil and ca and ca:IsA("ObjectValue") then
			a = nodeId(ca.Value)
		end
		if b == nil and cb and cb:IsA("ObjectValue") then
			b = nodeId(cb.Value)
		end
		if a == nil and d:IsA("ObjectValue") then
			a = nodeId(d.Value)
		end
		if a ~= nil and b ~= nil then
			table.insert(edges, { tostring(a), tostring(b) })
		end
	end
	return Pathfind.decode({ nodes = nodes, edges = edges })
end

local lastSignature = ""

-- Cheap "did it change" key for the graph source, so we only re-decode when it does.
local function signature(src: Instance): string
	if src:IsA("StringValue") then
		return `json:{#src.Value}:{string.sub(src.Value, 1, 64)}:{string.sub(src.Value, -64)}`
	end
	return `folder:{#src:GetDescendants()}`
end

local function findSource(): Instance?
	local map = workspace:FindFirstChild("Map")
	local city = map and map:FindFirstChild("City")
	if not city then
		return nil
	end
	local json = city:FindFirstChild("RoadGraphJson")
	if json and json:IsA("StringValue") and json.Value ~= "" then
		return json
	end
	return city:FindFirstChild("RoadGraph")
end

local function loadGraph(): (Pathfind.Graph?, Instance?)
	local map = workspace:FindFirstChild("Map")
	local city = map and map:FindFirstChild("City")
	if not city then
		return nil, nil
	end
	local json = city:FindFirstChild("RoadGraphJson")
	if json and json:IsA("StringValue") and json.Value ~= "" then
		local ok, data = pcall(HttpService.JSONDecode, HttpService, json.Value)
		if ok then
			local g = Pathfind.decode(data)
			if g then
				return g, json
			end
		else
			warn(`[Navigation] RoadGraphJson is not valid JSON: {data}`)
		end
	end
	local folder = city:FindFirstChild("RoadGraph")
	if folder then
		local g = graphFromFolder(folder)
		if g then
			return g, folder
		end
	end
	return nil, nil
end

local function watchGraph()
	while true do
		local src = findSource()
		local sig = if src then signature(src) else ""
		if src and (src ~= graphSource or sig ~= lastSignature) then
			local g, from = loadGraph()
			lastSignature = sig
			if g then
				graph, graphSource = g, from
				route, routeTarget = nil, nil
				if mm then
					mm:setGraph(g)
				end
				print(`[Navigation] road graph: {#g.ids} nodes, {#g.edges} edges`)
			else
				graphSource = src -- unusable: wait until it changes instead of re-decoding every poll
			end
		elseif not src and graph then
			graph, graphSource, route, routeTarget, lastSignature = nil, nil, nil, nil, ""
			if mm then
				mm:setGraph(nil)
			end
		end
		task.wait(tonumber(NavigationConfig.GraphPollSeconds) or 2)
	end
end

-- 3D: beacon, route chevrons ----------------------------------------------------------------------

local function fxFolder(): Folder
	if fx and fx.Parent then
		return fx
	end
	local f = Instance.new("Folder")
	f.Name = "NavFx_Local"
	f.Parent = workspace
	fx = f
	return f
end

local function fxPart(name: string, size: Vector3, color: Color3, transparency: number, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = color
	p.Transparency = transparency
	p.Size = size
	if shape then
		p.Shape = shape
	end
	p.Parent = fxFolder()
	return p
end

type Beacon = { core: Part, glow: Part, ring: Part, head: Part, label: TextLabel, dist: TextLabel, gui: BillboardGui }
local beacon: Beacon? = nil

local function makeBeacon(): Beacon
	local h = tonumber(NavigationConfig.BeaconHeight) or 260
	local color: Color3 = NavigationConfig.BeaconColor or Palette.UiWarn
	local core = fxPart("BeaconCore", Vector3.new(h, 2.5, 2.5), color, 0.35, Enum.PartType.Cylinder)
	local glow = fxPart("BeaconGlow", Vector3.new(h, 9, 9), color, 0.85, Enum.PartType.Cylinder)
	local ring = fxPart("BeaconRing", Vector3.new(0.4, 26, 26), color, 0.5, Enum.PartType.Cylinder)
	local head = fxPart("BeaconHead", Vector3.new(1, 1, 1), color, 1)
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = 40
	light.Brightness = 3
	light.Parent = ring
	local gui = Instance.new("BillboardGui")
	gui.Name = "BeaconLabel"
	gui.Size = UDim2.fromOffset(260, 74)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 6, 0)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 100000
	gui.Adornee = head
	gui.Parent = head
	local pill = Instance.new("Frame")
	pill.Name = "Pill"
	pill.AnchorPoint = Vector2.new(0.5, 0.5)
	pill.Position = UDim2.fromScale(0.5, 0.5)
	pill.Size = UDim2.new(1, -10, 1, -10)
	pill.BackgroundColor3 = Palette.UiPanelDark
	pill.BackgroundTransparency = 0.15
	pill.Parent = gui
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 14)
	pc.Parent = pill
	UiKit.stroke(pill, 3, color)
	local label = UiKit.label(pill, "Label", "", UDim2.new(1, -12, 0, 30), UDim2.fromOffset(6, 4), {
		font = UiKit.Header,
		textSize = 24,
		color = Palette.UiCream,
		stroke = true,
		scaled = true,
	})
	local dist = UiKit.label(pill, "Dist", "", UDim2.new(1, -12, 0, 24), UDim2.fromOffset(6, 36), {
		font = UiKit.Header,
		textSize = 22,
		color = color,
		stroke = true,
	})
	return { core = core, glow = glow, ring = ring, head = head, label = label, dist = dist, gui = gui }
end

local function hideBeacon()
	if beacon then
		for _, p in { beacon.core, beacon.glow, beacon.ring } do
			p.Transparency = 1
		end
		beacon.gui.Enabled = false
	end
end

local function updateBeacon(pos: Vector3, label: string, distance: number, t: number)
	if not beacon or not beacon.core.Parent then
		beacon = makeBeacon()
	end
	local b = beacon :: Beacon
	local h = tonumber(NavigationConfig.BeaconHeight) or 260
	local up = CFrame.Angles(0, 0, math.pi / 2) -- cylinders run along X: stand them up
	b.core.CFrame = CFrame.new(pos + Vector3.new(0, h / 2, 0)) * up
	b.glow.CFrame = b.core.CFrame
	local k = (t * 0.8) % 1
	local ringSize = 10 + 30 * k
	b.ring.Size = Vector3.new(0.4, ringSize, ringSize)
	b.ring.CFrame = CFrame.new(pos + Vector3.new(0, 0.6, 0)) * up
	b.head.CFrame = CFrame.new(pos + Vector3.new(0, 14 + math.sin(t * 2) * 1.5, 0))
	-- fade the beam when you're standing in it
	local near = tonumber(NavigationConfig.BeaconFadeNear) or 30
	local fade = math.clamp((distance - near) / (near * 2), 0, 1)
	b.core.Transparency = 1 - (1 - 0.35) * fade - 0.08 * math.sin(t * 3) * fade
	b.glow.Transparency = 1 - (1 - 0.85) * fade
	b.ring.Transparency = 0.3 + 0.7 * k
	-- once you're there it's just clutter: hide the beam, ring and label
	local hideNear = tonumber(NavigationConfig.HideNear) or 70
	if distance < hideNear then
		b.core.Transparency = 1
		b.glow.Transparency = 1
		b.ring.Transparency = 1
		b.gui.Enabled = false
		return
	end
	b.gui.Enabled = true
	b.label.Text = string.upper(label)
	b.dist.Text = unit(distance)
end

type Chevron = { l: Part, r: Part, line: Part? }
local chevrons: { Chevron } = {}
local chevronAlong: { number } = {}
local heightCache: { [number]: number } = {}

local function chevron(i: number): Chevron
	local c = chevrons[i]
	if c then
		return c
	end
	local color: Color3 = NavigationConfig.ArrowColor or Palette.UiShock
	local arm = tonumber(NavigationConfig.ArrowArm) or 5
	local w = tonumber(NavigationConfig.ArrowWidth) or 0.9
	local ribbon = tonumber(NavigationConfig.RibbonWidth) or 0
	local made: Chevron = {
		l = fxPart("RouteArrowL", Vector3.new(w, 0.2, arm), color, 1),
		r = fxPart("RouteArrowR", Vector3.new(w, 0.2, arm), color, 1),
		line = if ribbon > 0
			then fxPart("RouteRibbon", Vector3.new(ribbon, 0.1, tonumber(NavigationConfig.ArrowSpacing) or 14), color, 1)
			else nil,
	}
	chevrons[i] = made
	return made
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function roadHeight(x: number, y: number, z: number, key: number): number
	local cached = heightCache[key]
	if cached then
		return cached
	end
	local hit = workspace:Raycast(Vector3.new(x, y + 25, z), Vector3.new(0, -70, 0), rayParams)
	local h = if hit then hit.Position.Y else y
	heightCache[key] = h
	return h
end

local function hideChevrons(from: number)
	for i = from, #chevrons do
		local c = chevrons[i]
		if c.l.Transparency < 1 then
			c.l.Transparency = 1
			c.r.Transparency = 1
		end
		if c.line and c.line.Transparency < 1 then
			c.line.Transparency = 1
		end
		chevronAlong[i] = nil
	end
end

local function placeChevrons(fromAlong: number)
	local poly = route
	if not poly then
		hideChevrons(1)
		return
	end
	local filter: { Instance } = { fxFolder() }
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(filter, p.Character)
		end
	end
	for _, t in CollectionService:GetTagged(TRUCK_TAG) do
		table.insert(filter, t)
	end
	rayParams.FilterDescendantsInstances = filter
	local spacing = tonumber(NavigationConfig.ArrowSpacing) or 14
	local hover = tonumber(NavigationConfig.ArrowHover) or 0.35
	local samples = Pathfind.samples(poly, fromAlong + 4, spacing, tonumber(NavigationConfig.MaxArrows) or 48)
	local ARM = tonumber(NavigationConfig.ArrowArm) or 5
	for i, s in samples do
		local c = chevron(i)
		local key = math.floor(s.along * 10 + 0.5)
		local y = roadHeight(s.x, s.y, s.z, key) + hover
		local base = CFrame.lookAt(Vector3.new(s.x, y, s.z), Vector3.new(s.x + s.dx, y, s.z + s.dz))
		local tip = base * Vector3.new(0, 0, -ARM * 0.45)
		for side, part in { [-1] = c.l, [1] = c.r } do
			local dir = base:VectorToWorldSpace(Vector3.new(side * 0.7071, 0, 0.7071))
			local centre = tip + dir * (ARM / 2)
			part.CFrame = CFrame.lookAt(centre, centre + dir)
		end
		if c.line then
			-- the glowing line: one spacing-long strip per arrow, just under it (reads as one ribbon)
			c.line.CFrame = base * CFrame.new(0, -0.12, spacing / 2)
		end
		chevronAlong[i] = s.along
	end
	hideChevrons(#samples + 1)
end

local function animateChevrons(t: number)
	local spacing = tonumber(NavigationConfig.ArrowSpacing) or 14
	local speed = tonumber(NavigationConfig.ArrowFlowSpeed) or 3.5
	for i, c in chevrons do
		local along = chevronAlong[i]
		if not along then
			continue
		end
		local k = ((along / spacing) - t * speed) % 6 / 6 -- 0..1 sawtooth running forward
		local fadeIn = math.clamp(i / 3, 0.35, 1) -- the first ones near your feet are fainter
		local tr = 1 - (0.25 + 0.6 * (1 - k)) * fadeIn
		c.l.Transparency = tr
		c.r.Transparency = tr
		if c.line then
			local base = tonumber(NavigationConfig.RibbonTransparency) or 0.5
			c.line.Transparency = 1 - (1 - base) * fadeIn * (0.8 + 0.2 * (1 - k))
		end
	end
end

-- 2D: edge arrow ---------------------------------------------------------------------------------

type Edge = { gui: ScreenGui, root: Frame, tip: Frame, dist: TextLabel }
local edge: Edge? = nil

local function makeEdge(): Edge
	local playerGui = player:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild("NavEdge")
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "NavEdge"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- WorldToViewportPoint space
	gui.DisplayOrder = 4
	gui.Parent = playerGui
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(52, 52)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = gui
	local pivot = Instance.new("Frame")
	pivot.Name = "Pivot"
	pivot.AnchorPoint = Vector2.new(0.5, 0.5)
	pivot.Position = UDim2.fromScale(0.5, 0.5)
	pivot.Size = UDim2.fromScale(1, 1)
	pivot.BackgroundTransparency = 1
	pivot.Parent = root
	local tip = Instance.new("Frame")
	tip.Name = "Tip"
	tip.AnchorPoint = Vector2.new(0.5, 0.5)
	tip.Position = UDim2.new(1, 4, 0.5, 0)
	tip.Size = UDim2.fromOffset(22, 22)
	tip.Rotation = 45
	tip.BackgroundColor3 = Palette.UiWarn
	tip.BorderSizePixel = 0
	UiKit.stroke(tip, 3)
	tip.Parent = pivot
	local circle = Instance.new("Frame")
	circle.Name = "Circle"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromOffset(46, 46)
	circle.BackgroundColor3 = Palette.UiWarn
	circle.BorderSizePixel = 0
	circle.ZIndex = 2
	UiKit.corner(circle, 46)
	UiKit.stroke(circle, 3)
	circle.Parent = root
	local bang = UiKit.label(circle, "Bang", "!", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 30,
		color = Palette.UiInk,
	})
	bang.ZIndex = 3
	local dist = UiKit.label(root, "Dist", "", UDim2.fromOffset(120, 24), UDim2.new(0.5, -60, 1, 2), {
		font = UiKit.Header,
		textSize = 20,
		color = Palette.UiCream,
		stroke = true,
	})
	dist.ZIndex = 3
	return { gui = gui, root = root, tip = tip, dist = dist }
end

local function updateEdge(pos: Vector3?, distance: number)
	if not edge or not edge.gui.Parent then
		edge = makeEdge()
	end
	local e = edge :: Edge
	local cam = workspace.CurrentCamera
	if not pos or not cam or (mm and mm:isBigOpen()) or distance < (tonumber(NavigationConfig.HideNear) or 70) then
		e.root.Visible = false
		return
	end
	-- one "!" arrow at a time: while the tutorial points at something (OnboardingEdge, e.g. "run to your
	-- truck"), the GPS arrow waits; the minimap route still shows the way
	local pgui = player:FindFirstChildOfClass("PlayerGui")
	local ob = pgui and pgui:FindFirstChild("OnboardingEdge")
	local obArrow = ob and ob:FindFirstChild("EdgeArrow", true)
	if ob and (ob :: ScreenGui).Enabled and obArrow and obArrow:IsA("GuiObject") and obArrow.Visible then
		e.root.Visible = false
		return
	end
	local vp = cam.ViewportSize
	local v, onScreen = cam:WorldToViewportPoint(pos + Vector3.new(0, 14, 0))
	local margin = tonumber(NavigationConfig.EdgeArrowMargin) or 70
	if onScreen and v.Z > 0 and v.X > margin and v.X < vp.X - margin and v.Y > margin and v.Y < vp.Y - margin then
		e.root.Visible = false -- the beacon label is on screen
		return
	end
	local cx, cy = vp.X / 2, vp.Y / 2
	local dx, dy = v.X - cx, v.Y - cy
	if v.Z < 0 then
		dx, dy = -dx, -dy
	end
	if math.abs(dx) < 1e-3 and math.abs(dy) < 1e-3 then
		dy = 1
	end
	local rx, ry = cx - margin, cy - margin
	local k = 1 / math.sqrt((dx / rx) ^ 2 + (dy / ry) ^ 2)
	e.root.Visible = true
	-- off the HUD panels on that edge (guide card, gauges, chips): slide in toward the centre
	-- 48: the circle plus the distance label hanging under it
	local ex, ey = HudLayout.clear(cx + dx * k, cy + dy * k, 48, "NavEdge", HudLayout.Prio.Nav)
	e.root.Position = UDim2.fromOffset(ex, ey)
	local pivot = e.root:FindFirstChild("Pivot") :: Frame?
	if pivot then
		pivot.Rotation = math.deg(math.atan2(dy, dx))
	end
	e.dist.Text = unit(distance)
end

-- route --------------------------------------------------------------------------------------------

local function recompute(from: Vector3, to: Vector3)
	lastRouteAt = os.clock()
	routeTarget = to
	heightCache = {}
	if not graph then
		route = nil
		if mm then
			mm:setRoute(nil)
		end
		return
	end
	local poly = Pathfind.route(graph :: Pathfind.Graph, { x = from.X, y = from.Y, z = from.Z }, { x = to.X, y = to.Y, z = to.Z })
	route = poly
	if mm then
		mm:setRoute(poly)
	end
end

local ICON = { left = "⬅", right = "➡", uturn = "↩", straight = "⬆", arrive = "★" }

local function updateHint(from: Vector3, to: Vector3, label: string, along: number)
	if not mm then
		return
	end
	local direct = Vector3.new(to.X - from.X, 0, to.Z - from.Z).Magnitude
	local arrive = tonumber(NavigationConfig.ArriveRadius) or 45
	if direct <= arrive then
		mm:setHint("YOU'RE HERE!", string.upper(label), ICON.arrive)
		return
	end
	local poly = route
	if not poly then
		mm:setHint(Loc.t("HEAD {1}", { Pathfind.compass(to.X - from.X, to.Z - from.Z) }), Loc.t("{1} · {2}", { unit(direct), string.upper(label) }), ICON.straight)
		return
	end
	local total = math.max(0, Pathfind.length(poly) - along)
	local kind, dist = Pathfind.nextTurn(poly, along, tonumber(NavigationConfig.TurnAngle) or 35)
	local sub = Loc.t("{1} · {2}", { unit(total), string.upper(label) })
	if kind and dist <= (tonumber(NavigationConfig.TurnHintRange) or 220) then
		local word = if kind == "uturn" then "U-TURN" else Loc.t("TURN {1}", { string.upper(kind) })
		mm:setHint(Loc.t("{1} in {2}", { word, unit(dist) }), sub, ICON[kind])
	elseif kind then
		mm:setHint(Loc.t("FOLLOW THE ROAD {1}", { unit(dist) }), sub, ICON.straight)
	else
		mm:setHint(Loc.t("STRAIGHT ON {1}", { unit(dist) }), sub, ICON.straight)
	end
end

export type RouteInfo = {
	total: number,
	left: number,
	turn: string?,
	turnDist: number,
	dx: number,
	dz: number,
	arrived: boolean,
	off: number?,
	ax: number?,
	az: number?,
}
local routeInfo: RouteInfo? = nil
local routeTotal = 0 -- longest route length seen for this target (the ARRIVING bar's 0%)

function NavigationController:GetRouteInfo(): RouteInfo?
	return routeInfo
end

local function updateRouteInfo(from: Vector3, to: Vector3, along: number, arrived: boolean)
	local poly = route
	if arrived then
		routeInfo = { total = math.max(routeTotal, 1), left = 0, turn = nil, turnDist = 0, dx = 0, dz = 0, arrived = true }
		return
	end
	if not poly then
		local direct = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
		local d = direct.Magnitude
		routeTotal = math.max(routeTotal, d)
		local u = if d > 1e-3 then direct.Unit else Vector3.zero
		routeInfo = { total = routeTotal, left = d, turn = nil, turnDist = 0, dx = u.X, dz = u.Z, arrived = false }
		return
	end
	local len = Pathfind.length(poly)
	local left = math.max(0, len - along)
	routeTotal = math.max(routeTotal, left)
	local kind, dist = Pathfind.nextTurn(poly, along, tonumber(NavigationConfig.TurnAngle) or 35)
	local s = Pathfind.samples(poly, along + 2, 1, 1)[1]
	local ahead = Pathfind.samples(poly, along + (tonumber(DriveConfig.AssistLookAhead) or 26), 1, 1)[1]
	local _, off = Pathfind.project(poly, from.X, from.Z)
	routeInfo = {
		total = routeTotal,
		left = left,
		turn = kind,
		turnDist = if kind then dist else 0,
		dx = if s then s.dx else 0,
		dz = if s then s.dz else 0,
		arrived = false,
		off = off,
		ax = if ahead then ahead.x else nil,
		az = if ahead then ahead.z else nil,
	}
end

-- markers ------------------------------------------------------------------------------------------

local incidentPos: { [Instance]: Vector3 } = {}

local function siteCentre(site: Instance): Vector3?
	local cached = incidentPos[site]
	if cached then
		return cached
	end
	local zone = site:FindFirstChild("ArrivalZone", true) or site:FindFirstChild("TruckSpot", true)
	local p = if zone then partPos(zone) else partPos(site)
	if p then
		incidentPos[site] = p
	end
	return p
end

-- the station (home) and, in the lobby, the glowing queue pads (OnboardingController's tutorial points at them)
local stationPos: Vector3? = nil
local function homePos(): Vector3?
	if stationPos then
		return stationPos
	end
	local sum, n = Vector3.zero, 0
	for _, tag in { Tag.StationSpawn or "StationSpawn", Tag.TruckBay or "TruckBay" } do
		for _, b in CollectionService:GetTagged(tag) do
			if b:IsA("BasePart") and b:IsDescendantOf(workspace) then
				sum += b.Position
				n += 1
			end
		end
	end
	if n > 0 then
		stationPos = sum / n
	end
	return stationPos
end

local function collectMarkers(): { any }
	local out = {}
	local home = homePos()
	if home then
		table.insert(out, { id = "station", kind = "station", x = home.X, z = home.Z, text = "67" })
	end
	local iid = player:GetAttribute(Attr.InstanceId or "InstanceId")
	if iid == nil or iid == "" then
		for _, pad in CollectionService:GetTagged(Tag.SquadPad or "SquadPad") do
			if pad:IsA("BasePart") and pad:IsDescendantOf(workspace) then
				table.insert(out, { id = "pad_" .. tostring(pad:GetAttribute("PadId") or pad.Name), kind = "pad", x = pad.Position.X, z = pad.Position.Z })
			end
		end
	end
	local tPos, tLabel = target()
	if tPos then
		table.insert(out, { id = "wp", kind = if pin then "pin" else "waypoint", x = tPos.X, z = tPos.Z, text = tLabel })
	end
	if pin then
		local sPos = player:GetAttribute("WaypointPos")
		if typeof(sPos) == "Vector3" then
			table.insert(out, { id = "wp_server", kind = "waypoint", x = sPos.X, z = sPos.Z })
		end
	end
	for _, site in CollectionService:GetTagged(INCIDENT_TAG) do
		if site:GetAttribute("Busy") == true and site:IsDescendantOf(workspace) then
			local p = siteCentre(site)
			if p then
				table.insert(out, { id = "inc_" .. tostring(site:GetAttribute("SiteId") or site:GetFullName()), kind = "incident", x = p.X, z = p.Z })
			end
		end
	end
	local mySquad = player:GetAttribute(Attr.SquadId or "SquadId")
	for _, p in Players:GetPlayers() do
		if p == player then
			continue
		end
		local char = p.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			continue
		end
		local squad = p:GetAttribute(Attr.SquadId or "SquadId")
		local mate = type(mySquad) == "string" and mySquad ~= "" and squad == mySquad
		local helmet = tonumber(p:GetAttribute(Attr.Helmet or "Helmet"))
		table.insert(out, {
			id = "p" .. p.UserId,
			kind = if mate then "mate" else "other",
			x = root.Position.X,
			z = root.Position.Z,
			text = if helmet then tostring(helmet) else "?",
		})
	end
	for _, truck in CollectionService:GetTagged(TRUCK_TAG) do
		if not truck:IsDescendantOf(workspace) or not truck:IsA("Model") then
			continue
		end
		local ok, cf = pcall(function()
			return (truck :: Model):GetPivot()
		end)
		if not ok then
			continue
		end
		local owner = truck:GetAttribute("OwnerUserId")
		local driver = truck:GetAttribute("Driver")
		local mine = owner == player.UserId or driver == player.UserId
		local look = cf.LookVector
		local helmet = tonumber(player:GetAttribute(Attr.Helmet or "Helmet"))
		table.insert(out, {
			id = "t_" .. truck:GetFullName(),
			kind = if mine then "mytruck" else "truck",
			x = cf.Position.X,
			z = cf.Position.Z,
			yaw = Pathfind.heading(look.X, look.Z),
			text = if mine and helmet then UiKit.helmetTag(helmet) else nil,
		})
	end
	return out
end

-- main loop ------------------------------------------------------------------------------------------

local lastPlace = 0
local lastOffCheck = 0
local lastAnim = 0
local currentScale = 0.42

local function step(dt: number)
	local root = myRoot()
	local cam = workspace.CurrentCamera
	if not root or not cam or not mm then
		return
	end
	local t = os.clock()
	local seat = mySeat()
	local here = if seat then seat.Position else root.Position
	local look = cam.CFrame.LookVector
	local heading = Pathfind.heading(look.X, look.Z)
	local face = (if seat then seat.CFrame.LookVector else root.CFrame.LookVector)
	local facing = Pathfind.heading(face.X, face.Z)

	-- zoom out with speed (driving)
	local speed = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z).Magnitude
	local k = math.clamp(speed / (tonumber(NavigationConfig.TruckSpeedForZoom) or 60), 0, 1)
	local want = (tonumber(NavigationConfig.MinimapScale) or 0.42) * (1 - k) + (tonumber(NavigationConfig.MinimapScaleFast) or 0.22) * k
	currentScale += (want - currentScale) * math.clamp(dt * 2, 0, 1)

	local tPos, tLabel = target()
	if tPos then
		local label = tLabel or "DESTINATION"
		local distance = (tPos - here).Magnitude
		local arrive = tonumber(NavigationConfig.ArriveRadius) or 45
		local arrived = Vector3.new(tPos.X - here.X, 0, tPos.Z - here.Z).Magnitude <= arrive
		-- route upkeep: on a timer, when the target moves, or as soon as we're off the line
		local refresh = tonumber(NavigationConfig.RouteRefresh) or 1
		local moved = not routeTarget or ((routeTarget :: Vector3) - tPos).Magnitude > 4
		local along = 0
		if route then
			local a, off = Pathfind.project(route :: { Pathfind.P }, here.X, here.Z)
			along = a
			if t - lastOffCheck > 0.25 then
				lastOffCheck = t
				if off > (tonumber(NavigationConfig.OffRouteDistance) or 30) then
					moved = true
				end
			end
		end
		if arrived then
			if route then
				route = nil
				mm:setRoute(nil)
				hideChevrons(1)
			end
			routeTarget = tPos
		elseif moved or t - lastRouteAt > refresh then
			recompute(here, tPos)
			if route then
				along = Pathfind.project(route :: { Pathfind.P }, here.X, here.Z)
			end
			lastPlace = 0
		end
		if not arrived and route and t - lastPlace > 0.2 then
			lastPlace = t
			placeChevrons(along)
		end
		if t - lastAnim > 0.05 then
			lastAnim = t
			animateChevrons(t)
		end
		updateBeacon(tPos, label, distance, t)
		updateEdge(tPos, distance)
		updateHint(here, tPos, label, along)
		updateRouteInfo(here, tPos, along, arrived)
	else
		if route or routeTarget then
			route, routeTarget = nil, nil
			mm:setRoute(nil)
		end
		hideChevrons(1)
		hideBeacon()
		updateEdge(nil, 0)
		mm:setHint(nil)
		routeInfo = nil
		routeTotal = 0
	end

	mm:update({
		x = here.X,
		z = here.Z,
		heading = heading,
		facing = facing,
		scale = currentScale,
		markers = collectMarkers(),
	})
end

function NavigationController:Init(_controllers: { [string]: any }) end

function NavigationController:Start()
	currentScale = tonumber(NavigationConfig.MinimapScale) or 0.42
	mm = Minimap.new()
	mm.onPin = function(x: number?, z: number?)
		if not x or not z then
			pin = nil
			return
		end
		-- clicking near the current pin clears it
		if pin and Vector3.new((pin :: Vector3).X - x, 0, (pin :: Vector3).Z - z).Magnitude < 40 then
			pin = nil
		else
			local y = 0
			local root = myRoot()
			if root then
				y = root.Position.Y
			end
			pin = Vector3.new(x, y, z)
		end
		routeTarget = nil -- re-route now
	end
	-- a new server waypoint (dispatch) wins over a personal pin
	player:GetAttributeChangedSignal("WaypointPos"):Connect(function()
		pin = nil
		routeTarget = nil
		routeTotal = 0
	end)
	task.spawn(watchGraph)
	ContextActionService:BindAction("NavBigMap", function(_name: string, state: Enum.UserInputState): Enum.ContextActionResult
		if state == Enum.UserInputState.Begin then
			mm:toggleBig()
		end
		return Enum.ContextActionResult.Pass
	end, false, NavigationConfig.BigMapKey or Enum.KeyCode.M, Enum.KeyCode.DPadDown) -- gamepad: D-pad down
	-- forget cached incident centres when sites are rebuilt
	CollectionService:GetInstanceRemovedSignal(INCIDENT_TAG):Connect(function(inst: Instance)
		incidentPos[inst] = nil
	end)
	local quietUntil = 0
	RunService.RenderStepped:Connect(function(dt: number)
		local ok, err = pcall(step, dt)
		if not ok and os.clock() > quietUntil then
			quietUntil = os.clock() + 5 -- warn at most every 5 s
			warn(`[Navigation] {err}`)
		end
	end)
end

return NavigationController
