--!strict
-- Minimap [owner: Navigation]. The 2D maps for NavigationController (docs/game/08 "Navigation"):
--   * a round minimap (top right, under the HUD squad strip) that rotates with the camera heading:
--     roads from the road graph, the GPS route, the player arrow, teammates (helmet numbers), trucks,
--     active incidents (pulsing flames), the waypoint pin, a north tick and a turn-hint pill.
--   * a big north-up city map (M) with drag-to-pan, wheel / buttons to zoom, "centre on me", and
--     click-to-drop a personal pin.
-- Roads are drawn once into a square "World" frame in scale coordinates, so zooming is just
-- resizing that frame; markers are positioned per frame with Pathfind.toMap (cheap: a dozen).
-- Not booted by Main.client (lives in ClientLib):
--   local mm = Minimap.new()
--   mm:setGraph(graph?) ; mm:setRoute(poly?) ; mm:setHint(text?, sub?)
--   mm:update(view)  -- every RenderStepped, view = {x, z, heading, facing, scale, markers}
--   mm:toggleBig(open?) ; mm:isBigOpen() ; mm.onPin = function(x?, z?) end   (nil = clear pin)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local NavigationConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("NavigationConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent:WaitForChild("UiKit") :: ModuleScript)
local Pathfind = require(script.Parent:WaitForChild("Pathfind") :: ModuleScript)
local InputHints = require(script.Parent:WaitForChild("InputHints") :: ModuleScript) :: any

export type Marker = {
	id: string,
	kind: string, -- "waypoint" | "pin" | "incident" | "mate" | "other" | "truck" | "mytruck"
	x: number,
	z: number,
	text: string?,
	yaw: number?, -- heading (Pathfind.heading) for trucks
	color: Color3?,
}
export type View = {
	x: number,
	z: number,
	heading: number, -- camera heading: this direction points up on the minimap
	facing: number, -- character heading: the player arrow
	scale: number, -- px per stud
	markers: { Marker },
}
type Bounds = { minX: number, minZ: number, extent: number }

local GROUND = Color3.fromHex("#2E3B36")
local ROAD = Color3.fromHex("#CFC6B6")
local ROAD_EDGE = Color3.fromHex("#1E2724")
local BLOCK = Color3.fromHex("#3B4A43")

local Minimap = {}
Minimap.__index = Minimap

local function frame(parent: Instance, name: string, color: Color3?, transparency: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.BorderSizePixel = 0
	f.BackgroundColor3 = color or Color3.new(1, 1, 1)
	f.BackgroundTransparency = transparency or (if color then 0 else 1)
	f.Parent = parent
	return f
end

local function round(f: GuiObject)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = f
end

local function text(parent: Instance, name: string, t: string, size: number, color: Color3?, font: Enum.Font?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Text = t
	l.TextSize = size
	l.Font = font or UiKit.Header
	l.TextColor3 = color or Palette.UiCream
	l.Size = UDim2.fromScale(1, 1)
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = l
	l.Parent = parent
	return l
end

-- A line in a square world frame, in scale coordinates (so resizing the frame zooms it).
local function line(parent: Instance, b: Bounds, ax: number, az: number, bx: number, bz: number, width: number, color: Color3, z: number, f: Frame?): Frame
	local seg = f or frame(parent, "Seg", color)
	local dx, dz = bx - ax, bz - az
	local len = math.sqrt(dx * dx + dz * dz)
	seg.AnchorPoint = Vector2.new(0.5, 0.5)
	seg.Position = UDim2.fromScale(((ax + bx) / 2 - b.minX) / b.extent, ((az + bz) / 2 - b.minZ) / b.extent)
	seg.Size = UDim2.new((len + width) / b.extent, 0, width / b.extent, 2)
	seg.Rotation = math.deg(math.atan2(dz, dx))
	seg.BackgroundColor3 = color
	seg.ZIndex = z
	seg.Visible = true
	return seg
end

local function boundsOf(g: Pathfind.Graph?): Bounds
	if not g or #g.ids == 0 then
		return { minX = -800, minZ = -800, extent = 1600 }
	end
	local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
	for _, id in g.ids do
		local p = g.pos[id]
		minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
		minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
	end
	local pad = 160
	local extent = math.max(maxX - minX, maxZ - minZ) + pad * 2
	local cx, cz = (minX + maxX) / 2, (minZ + maxZ) / 2
	return { minX = cx - extent / 2, minZ = cz - extent / 2, extent = extent }
end

-- Draw roads (outline + fill + rounded joints) into a world frame.
local function drawRoads(world: Frame, g: Pathfind.Graph?, b: Bounds)
	local old = world:FindFirstChild("Roads")
	if old then
		old:Destroy()
	end
	local layer = frame(world, "Roads")
	layer.Size = UDim2.fromScale(1, 1)
	if not g then
		return
	end
	local w = tonumber(NavigationConfig.RoadWidth) or 24
	for _, e in g.edges do
		local a, c = g.pos[e.a], g.pos[e.b]
		line(layer, b, a.x, a.z, c.x, c.z, w + 6, ROAD_EDGE, 2)
		line(layer, b, a.x, a.z, c.x, c.z, w, ROAD, 3)
	end
	for _, id in g.ids do
		local p = g.pos[id]
		local dot = frame(layer, "Joint", ROAD)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale((p.x - b.minX) / b.extent, (p.z - b.minZ) / b.extent)
		dot.Size = UDim2.new(w / b.extent, 2, w / b.extent, 2)
		dot.ZIndex = 3
		round(dot)
	end
end

type Icon = { root: Frame, label: TextLabel?, ring: Frame?, seen: boolean }

-- One marker icon (same look on both maps).
local function makeIcon(parent: Instance, m: Marker): Icon
	local root = frame(parent, "M_" .. m.id)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.ZIndex = 10
	local icon: Icon = { root = root, seen = true }
	if m.kind == "waypoint" or m.kind == "pin" then
		root.Size = UDim2.fromOffset(24, 24)
		local ring = frame(root, "Ring", m.color or Palette.UiWarn, 0.4)
		ring.AnchorPoint = Vector2.new(0.5, 0.5)
		ring.Position = UDim2.fromScale(0.5, 0.5)
		ring.Size = UDim2.fromScale(1, 1)
		ring.ZIndex = 10
		round(ring)
		local dot = frame(root, "Dot", m.color or Palette.UiWarn)
		dot.AnchorPoint = Vector2.new(0.5, 0.5)
		dot.Position = UDim2.fromScale(0.5, 0.5)
		dot.Size = UDim2.fromScale(1, 1)
		dot.ZIndex = 11
		round(dot)
		UiKit.stroke(dot, 2.5)
		local l = text(dot, "T", if m.kind == "pin" then "P" else "!", 16, Palette.UiInk)
		l.ZIndex = 12
		l.TextColor3 = Palette.UiInk
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			st.Enabled = false
		end
		icon.ring = ring
	elseif m.kind == "incident" then
		root.Size = UDim2.fromOffset(26, 26)
		local glow = frame(root, "Glow", Palette.UiFlameMid, 0.35)
		glow.AnchorPoint = Vector2.new(0.5, 0.5)
		glow.Position = UDim2.fromScale(0.5, 0.5)
		glow.Size = UDim2.fromScale(1, 1)
		glow.ZIndex = 10
		round(glow)
		local l = text(root, "T", "🔥", 20)
		l.ZIndex = 11
		icon.ring = glow
	elseif m.kind == "mate" then
		root.Size = UDim2.fromOffset(22, 22)
		root.BackgroundColor3 = m.color or Palette.HelmetRed
		root.BackgroundTransparency = 0
		round(root)
		UiKit.stroke(root, 2)
		local l = text(root, "T", m.text or "", 13)
		l.ZIndex = 11
		icon.label = l
	elseif m.kind == "station" then -- home: a red "67" badge
		root.Size = UDim2.fromOffset(26, 20)
		root.BackgroundColor3 = Palette.UiRed
		root.BackgroundTransparency = 0
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 5)
		c.Parent = root
		UiKit.stroke(root, 2)
		local l = text(root, "T", m.text or "67", 13)
		l.ZIndex = 11
		icon.label = l
	elseif m.kind == "pad" then -- glowing queue pad
		root.Size = UDim2.fromOffset(12, 12)
		root.BackgroundColor3 = Palette.UiWater
		root.BackgroundTransparency = 0.1
		round(root)
		UiKit.stroke(root, 2, Palette.UiCream)
	elseif m.kind == "other" then
		root.Size = UDim2.fromOffset(9, 9)
		root.BackgroundColor3 = Palette.ReflectSilver
		root.BackgroundTransparency = 0
		round(root)
		UiKit.stroke(root, 1.5)
	else -- truck / mytruck: a little red bus shape with a white cab stripe
		local mine = m.kind == "mytruck"
		root.Size = UDim2.fromOffset(if mine then 13 else 10, if mine then 22 else 17)
		root.BackgroundColor3 = Palette.TruckRed
		root.BackgroundTransparency = 0
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0, 3)
		c.Parent = root
		UiKit.stroke(root, if mine then 2.5 else 1.5, if mine then Palette.UiWarn else Palette.UiInk)
		local cab = frame(root, "Cab", Palette.TruckChrome)
		cab.Size = UDim2.new(1, -4, 0, 4)
		cab.Position = UDim2.fromOffset(2, 2)
		cab.ZIndex = 11
		if mine and m.text then
			local tag = frame(root, "Tag")
			tag.Size = UDim2.fromOffset(30, 14)
			tag.AnchorPoint = Vector2.new(0.5, 1)
			tag.Position = UDim2.new(0.5, 0, 0, -2)
			local l = text(tag, "T", m.text, 11)
			l.ZIndex = 12
			icon.label = l
		end
	end
	return icon
end

-- A pool of marker icons keyed by id, swept every update.
type IconSet = { parent: Instance, icons: { [string]: Icon }, kinds: { [string]: string } }

local function iconFor(set: IconSet, m: Marker): Icon
	local icon = set.icons[m.id]
	if icon and set.kinds[m.id] ~= m.kind then
		icon.root:Destroy()
		icon = nil
	end
	if not icon then
		local made = makeIcon(set.parent, m)
		set.icons[m.id] = made
		set.kinds[m.id] = m.kind
		return made
	end
	if icon.label and m.text and icon.label.Text ~= m.text then
		icon.label.Text = m.text
	end
	return icon
end

local function sweep(set: IconSet)
	for id, icon in set.icons do
		if not icon.seen then
			icon.root:Destroy()
			set.icons[id] = nil
			set.kinds[id] = nil
		else
			icon.seen = false
		end
	end
end

local function pulse(icon: Icon, kind: string, t: number)
	if icon.ring then
		local k = if kind == "incident" then (t * 2.2) % 1 else (t * 1.2) % 1
		icon.ring.Size = UDim2.fromScale(1 + k * 1.1, 1 + k * 1.1)
		icon.ring.BackgroundTransparency = 0.3 + 0.7 * k
	end
end

local CLAMPED: { [string]: boolean } = { waypoint = true, pin = true, incident = true, mate = true, mytruck = true }
local Z_ORDER: { [string]: number } = { other = 10, truck = 11, mytruck = 12, mate = 13, incident = 14, pin = 15, waypoint = 16 }

function Minimap.new()
	local self = setmetatable({}, Minimap) :: any
	self.graph = nil :: Pathfind.Graph?
	self.bounds = boundsOf(nil)
	self.route = nil :: { Pathfind.P }?
	self.onPin = nil :: ((number?, number?) -> ())?
	self.bigOpen = false
	self.bigZoom = 0.6
	self.bigCenter = { x = 0, z = 0 }
	self.lastView = nil :: View?

	-- minimap -----------------------------------------------------------------------------------
	local size = tonumber(NavigationConfig.MinimapSize) or 190
	local gui = UiKit.screen("NavMinimap", 5)
	gui.IgnoreGuiInset = true -- up level with the Roblox menu buttons (top-right of the screen is free)
	gui.ScreenInsets = Enum.ScreenInsets.None
	self.gui = gui
	local root = frame(gui, "Root")
	root.AnchorPoint = Vector2.new(1, 0)
	root.Position = UDim2.new(1, -(tonumber(NavigationConfig.MinimapRight) or 14), 0, tonumber(NavigationConfig.MinimapTop) or 204)
	root.Size = UDim2.fromOffset(size, size)
	self.root = root

	local shadow = frame(root, "Shadow", Color3.new(0, 0, 0), 0.6)
	shadow.Size = UDim2.fromScale(1, 1)
	shadow.Position = UDim2.fromOffset(0, 5)
	round(shadow)

	local clip = Instance.new("CanvasGroup")
	clip.Name = "Clip"
	clip.Size = UDim2.fromScale(1, 1)
	clip.BackgroundColor3 = GROUND
	clip.BorderSizePixel = 0
	clip.ZIndex = 2
	round(clip)
	clip.Parent = root

	local pivot = frame(clip, "Pivot")
	pivot.AnchorPoint = Vector2.new(0.5, 0.5)
	pivot.Position = UDim2.fromScale(0.5, 0.5)
	pivot.Size = UDim2.fromOffset(0, 0)
	self.pivot = pivot
	local world = frame(pivot, "World", BLOCK, 0.2)
	world.AnchorPoint = Vector2.new(0, 0)
	self.world = world

	local markers = frame(clip, "Markers")
	markers.Size = UDim2.fromScale(1, 1)
	markers.ZIndex = 10
	self.miniIcons = { parent = markers, icons = {}, kinds = {} } :: IconSet

	-- range rings and the player arrow
	local ringIn = frame(clip, "RangeRing")
	ringIn.AnchorPoint = Vector2.new(0.5, 0.5)
	ringIn.Position = UDim2.fromScale(0.5, 0.5)
	ringIn.Size = UDim2.fromScale(0.5, 0.5)
	round(ringIn)
	local rs = Instance.new("UIStroke")
	rs.Thickness = 1
	rs.Color = Palette.UiCream
	rs.Transparency = 0.8
	rs.Parent = ringIn

	local arrow = frame(clip, "Player")
	arrow.AnchorPoint = Vector2.new(0.5, 0.5)
	arrow.Position = UDim2.fromScale(0.5, 0.5)
	arrow.Size = UDim2.fromOffset(26, 26)
	arrow.ZIndex = 20
	local arrowText = text(arrow, "T", "▲", 24, Palette.UiCream, Enum.Font.GothamBlack)
	arrowText.ZIndex = 20
	local ast = arrowText:FindFirstChildOfClass("UIStroke")
	if ast then
		ast.Thickness = 3
	end
	self.arrow = arrow

	-- rim: ink ring, cream inner ring, north tick
	local rim = frame(root, "Rim")
	rim.Size = UDim2.fromScale(1, 1)
	rim.ZIndex = 30
	round(rim)
	local s1 = Instance.new("UIStroke")
	s1.Thickness = 5
	s1.Color = Palette.UiInk
	s1.Parent = rim
	local inner = frame(root, "Inner")
	inner.AnchorPoint = Vector2.new(0.5, 0.5)
	inner.Position = UDim2.fromScale(0.5, 0.5)
	inner.Size = UDim2.new(1, -6, 1, -6)
	inner.ZIndex = 30
	round(inner)
	local s2 = Instance.new("UIStroke")
	s2.Thickness = 2
	s2.Color = Palette.UiCream
	s2.Transparency = 0.3
	s2.Parent = inner

	local north = frame(root, "North", Palette.UiRed)
	north.AnchorPoint = Vector2.new(0.5, 0.5)
	north.Size = UDim2.fromOffset(22, 22)
	north.ZIndex = 31
	round(north)
	UiKit.stroke(north, 2.5)
	local nl = text(north, "T", "N", 14)
	nl.ZIndex = 32
	self.north = north

	-- hint pill under the map
	-- right-aligned with the map so it never runs off the screen edge; its slot is reserved in the right
	-- column (ClientLib/HudLayout.RightColumnBelow), so the squad strip sits under it, never behind it
	local hint = frame(root, "Hint", Palette.UiPanelDark, 0.08)
	hint.AnchorPoint = Vector2.new(1, 0)
	hint.Position = UDim2.new(1, 0, 1, 8)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		-- phones: under the map is the jump button + touch actions; put the turn hint beside the map
		hint.AnchorPoint = Vector2.new(1, 0)
		hint.Position = UDim2.new(0, -10, 0, 0)
	end
	hint.Size = UDim2.fromOffset(size + 40, 52)
	hint.ZIndex = 30
	hint.Visible = false
	local hc = Instance.new("UICorner")
	hc.CornerRadius = UDim.new(0, 14)
	hc.Parent = hint
	UiKit.stroke(hint, 3)
	local hintIcon = text(hint, "Icon", "⬆", 30, Palette.UiShock, Enum.Font.GothamBlack)
	hintIcon.AnchorPoint = Vector2.new(0, 0.5)
	hintIcon.Position = UDim2.new(0, 6, 0.5, 0)
	hintIcon.Size = UDim2.fromOffset(40, 40)
	hintIcon.ZIndex = 31
	local hintText = text(hint, "Main", "", 18)
	hintText.AnchorPoint = Vector2.new(0, 0)
	hintText.Position = UDim2.fromOffset(48, 5)
	hintText.Size = UDim2.new(1, -54, 0, 22)
	hintText.TextXAlignment = Enum.TextXAlignment.Left
	hintText.TextScaled = true
	hintText.ZIndex = 31
	local hintSub = text(hint, "Sub", "", 14, Palette.UiWarn, UiKit.Body)
	hintSub.AnchorPoint = Vector2.new(0, 0)
	hintSub.Position = UDim2.fromOffset(48, 28)
	hintSub.Size = UDim2.new(1, -54, 0, 18)
	hintSub.TextXAlignment = Enum.TextXAlignment.Left
	hintSub.TextTruncate = Enum.TextTruncate.AtEnd
	hintSub.ZIndex = 31
	self.hint, self.hintIcon, self.hintText, self.hintSub = hint, hintIcon, hintText, hintSub
	local HudLayout = require(script.Parent:WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.reserve(root)
	HudLayout.reserve(hint)

	-- "M" map button (also the touch way in)
	local mapBtn = Instance.new("TextButton")
	mapBtn.Name = "MapButton"
	mapBtn.AnchorPoint = Vector2.new(0.5, 0.5)
	mapBtn.Position = UDim2.new(0, 10, 1, -10)
	mapBtn.Size = UDim2.fromOffset(40, 40)
	mapBtn.BackgroundColor3 = Palette.UiWarn
	mapBtn.Text = "M"
	mapBtn.Font = UiKit.Header
	mapBtn.TextSize = 22
	mapBtn.TextColor3 = Palette.UiInk
	mapBtn.ZIndex = 32
	round(mapBtn)
	UiKit.stroke(mapBtn, 3)
	mapBtn.Parent = root
	UiKit.onTap(mapBtn, function()
		self:toggleBig()
	end)
	-- the whole minimap is a button too: click / tap anywhere on it to open the big map
	local mapHit = Instance.new("TextButton")
	mapHit.Name = "OpenBigMap"
	mapHit.Size = UDim2.fromScale(1, 1)
	mapHit.BackgroundTransparency = 1
	mapHit.Text = ""
	mapHit.AutoButtonColor = false
	mapHit.ZIndex = 31
	mapHit.Parent = root
	mapHit.Activated:Connect(function()
		self:toggleBig(true)
	end)
	mapHit.MouseEnter:Connect(function()
		s1.Color = Palette.UiWarn
	end)
	mapHit.MouseLeave:Connect(function()
		s1.Color = Palette.UiInk
	end)

	-- big map ----------------------------------------------------------------------------------
	local big = UiKit.screen("NavBigMap", 40)
	big.Enabled = false
	self.bigGui = big
	local dim = frame(big, "Dim", Color3.new(0, 0, 0), 0.45)
	-- oversized: the gui respects the top-bar inset, and the dim must cover the top-bar row too
	dim.Size = UDim2.fromScale(3, 3)
	dim.Position = UDim2.fromScale(-1, -1)
	local panel = UiKit.panel(big, "Panel", UDim2.new(0.86, 0, 0.84, 0), UDim2.fromScale(0.5, 0.52), Vector2.new(0.5, 0.5))
	panel.BackgroundColor3 = Palette.UiPanelDark
	local pc = Instance.new("UICorner")
	pc.CornerRadius = UDim.new(0, 18)
	pc.Parent = panel
	local title = UiKit.label(panel, "Title", "CITY MAP", UDim2.new(1, -20, 0, 40), UDim2.fromOffset(10, 4), {
		font = UiKit.Header,
		textSize = 32,
		color = Palette.UiCream,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	title.ZIndex = 5
	local help = UiKit.label(panel, "Help", "drag to pan  ·  wheel to zoom  ·  click to drop a pin", UDim2.new(1, -20, 0, 24), UDim2.new(0, 10, 1, -28), {
		font = UiKit.Body,
		textSize = 16,
		color = Palette.UiCream,
		align = Enum.TextXAlignment.Left,
	})
	help.ZIndex = 5
	InputHints.setPick(help, help.Text, "drag to pan  ·  pinch to zoom  ·  tap to drop a pin")
	local view = frame(panel, "View", GROUND)
	view.Position = UDim2.fromOffset(12, 48)
	view.Size = UDim2.new(1, -24, 1, -82)
	view.ClipsDescendants = true
	view.Active = true
	view.ZIndex = 2
	local vc = Instance.new("UICorner")
	vc.CornerRadius = UDim.new(0, 12)
	vc.Parent = view
	self.bigView = view
	local bigWorld = frame(view, "World", BLOCK, 0.2)
	bigWorld.ZIndex = 2
	self.bigWorld = bigWorld
	local bigMarkers = frame(bigWorld, "Markers")
	bigMarkers.Size = UDim2.fromScale(1, 1)
	bigMarkers.ZIndex = 10
	self.bigIcons = { parent = bigMarkers, icons = {}, kinds = {} } :: IconSet
	local me = frame(bigWorld, "Me")
	me.AnchorPoint = Vector2.new(0.5, 0.5)
	me.Size = UDim2.fromOffset(30, 30)
	me.ZIndex = 20
	local meText = text(me, "T", "▲", 28, Palette.UiCream, Enum.Font.GothamBlack)
	meText.ZIndex = 20
	self.bigMe = me

	local function smallButton(name: string, label: string, pos: UDim2, fn: () -> ())
		local b = UiKit.button(panel, name, label, UDim2.fromOffset(46, 46), pos, Palette.UiWarn)
		b.TextColor3 = Palette.UiInk
		b.TextSize = 26
		b.ZIndex = 6
		UiKit.onTap(b, fn) -- 44 px touch pad on phones (these come out ~26 px at UIScale 0.55)
	end
	smallButton("Close", "X", UDim2.new(1, -30, 0, 26), function()
		self:toggleBig(false)
	end)
	smallButton("ZoomIn", "+", UDim2.new(1, -86, 0, 26), function()
		self:zoomBig(1.4)
	end)
	smallButton("ZoomOut", "-", UDim2.new(1, -142, 0, 26), function()
		self:zoomBig(1 / 1.4)
	end)
	smallButton("Center", "◎", UDim2.new(1, -198, 0, 26), function()
		local v = self.lastView
		if v then
			self.bigCenter = { x = v.x, z = v.z }
			self:layoutBig()
		end
	end)

	-- pan / zoom / pin input on the big map
	local dragging: InputObject? = nil
	local dragStart = Vector2.zero
	local dragMoved = 0
	view.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or t == Enum.UserInputType.Touch then
			dragging = input
			dragStart = Vector2.new(input.Position.X, input.Position.Y)
			dragMoved = 0
		elseif t == Enum.UserInputType.MouseWheel then
			self:zoomBig(if input.Position.Z > 0 then 1.15 else 1 / 1.15)
		end
	end)
	UserInputService.InputChanged:Connect(function(input: InputObject)
		if not self.bigOpen or not dragging then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseMovement or (t == Enum.UserInputType.Touch and input == dragging) then
			local pos = Vector2.new(input.Position.X, input.Position.Y)
			local delta = pos - dragStart
			dragStart = pos
			dragMoved += delta.Magnitude
			local s = self:bigScale()
			self.bigCenter = { x = self.bigCenter.x - delta.X / s, z = self.bigCenter.z - delta.Y / s }
			self:layoutBig()
		end
	end)
	UserInputService.InputEnded:Connect(function(input: InputObject)
		if not dragging then
			return
		end
		local t = input.UserInputType
		if t == Enum.UserInputType.MouseButton1 or (t == Enum.UserInputType.Touch and input == dragging) then
			dragging = nil
			if dragMoved < 6 and self.bigOpen then
				-- a click: drop (or clear) a personal pin there
				local abs = view.AbsolutePosition
				local sz = view.AbsoluteSize
				local s = self:bigScale()
				local px, py = input.Position.X - abs.X - sz.X / 2, input.Position.Y - abs.Y - sz.Y / 2
				local wx, wz = self.bigCenter.x + px / s, self.bigCenter.z + py / s
				if self.onPin then
					self.onPin(wx, wz)
				end
			end
		end
	end)
	local lastPinch = 1
	UserInputService.TouchPinch:Connect(function(_pos: { Vector2 }, scale: number, _vel: number, state: Enum.UserInputState)
		if not self.bigOpen or scale <= 0 then
			return
		end
		if state == Enum.UserInputState.Begin then
			lastPinch = scale
		elseif state == Enum.UserInputState.Change then
			dragging = nil -- a pinch is not a drag or a click
			self:zoomBig(scale / lastPinch)
			lastPinch = scale
		end
	end)

	self:setGraph(nil)
	return self
end

-- Real screen px per declared offset px on the big map (UiKit's ViewportScale), measured, not assumed.
function Minimap:uiK(): number
	local w = self.bigWorld :: Frame
	local declared = w.Size.X.Offset
	if declared > 0 and w.AbsoluteSize.X > 0 then
		return w.AbsoluteSize.X / declared
	end
	return 1
end

-- Screen pixels per stud on the big map.
function Minimap:bigScale(): number
	return self.bigZoom * self:uiK()
end

function Minimap:zoomBig(factor: number)
	self.bigZoom = math.clamp(self.bigZoom * factor, tonumber(NavigationConfig.BigMapMinZoom) or 0.25, tonumber(NavigationConfig.BigMapMaxZoom) or 3)
	self:layoutBig()
end

function Minimap:layoutBig()
	local b: Bounds = self.bounds
	local s = self.bigZoom
	local w = self.bigWorld :: Frame
	w.Size = UDim2.fromOffset(b.extent * s, b.extent * s)
	w.Position = UDim2.new(0.5, -(self.bigCenter.x - b.minX) * s, 0.5, -(self.bigCenter.z - b.minZ) * s)
end

function Minimap:toggleBig(open: boolean?)
	local want = if open == nil then not self.bigOpen else open
	self.bigOpen = want
	self.bigGui.Enabled = want
	if want then
		local v = self.lastView
		if v then
			self.bigCenter = { x = v.x, z = v.z }
		end
		-- zoom so a good chunk of the city fits the view
		self:layoutBig()
		local vsz = self.bigView.AbsoluteSize
		local fit = math.min(vsz.X, vsz.Y) / self:uiK() / math.max(1, self.bounds.extent)
		if fit > 0 then
			self.bigZoom = math.clamp(fit * 1.6, tonumber(NavigationConfig.BigMapMinZoom) or 0.25, tonumber(NavigationConfig.BigMapMaxZoom) or 3)
		end
		self:layoutBig()
		UiKit.pop(self.bigView, 0.25)
	end
end

function Minimap:isBigOpen(): boolean
	return self.bigOpen
end

function Minimap:setGraph(g: Pathfind.Graph?)
	self.graph = g
	self.bounds = boundsOf(g)
	drawRoads(self.world, g, self.bounds)
	drawRoads(self.bigWorld, g, self.bounds)
	self:setRoute(self.route)
	self:layoutBig()
end

local function drawRoute(world: Frame, b: Bounds, poly: { Pathfind.P }?, width: number)
	local layer = world:FindFirstChild("Route") :: Frame?
	if not layer then
		local made = frame(world, "Route")
		made.Size = UDim2.fromScale(1, 1)
		made.ZIndex = 5
		layer = made
	end
	local l = layer :: Frame
	local segs = l:GetChildren()
	local used = 0
	if poly then
		for i = 2, #poly do
			used += 1
			local f = segs[used] :: Frame?
			line(l, b, poly[i - 1].x, poly[i - 1].z, poly[i].x, poly[i].z, width, NavigationConfig.ArrowColor, 6, f)
		end
	end
	for i = used + 1, #segs do
		(segs[i] :: Frame).Visible = false
	end
end

function Minimap:setRoute(poly: { Pathfind.P }?)
	self.route = poly
	local w = (tonumber(NavigationConfig.RoadWidth) or 24) * 0.45
	drawRoute(self.world, self.bounds, poly, w)
	drawRoute(self.bigWorld, self.bounds, poly, w)
end

function Minimap:setHint(main: string?, sub: string?, icon: string?)
	if not main then
		self.hint.Visible = false
		return
	end
	self.hint.Visible = true
	self.hintText.Text = main
	self.hintSub.Text = sub or ""
	self.hintIcon.Text = icon or "⬆"
end

function Minimap:update(v: View)
	self.lastView = v
	local t = os.clock()
	local b: Bounds = self.bounds
	local size = tonumber(NavigationConfig.MinimapSize) or 190 -- declared px (any UIScale applies on top)
	local r = size / 2
	local scale = v.scale

	-- world: put the player at the pivot, rotate so the camera heading points up
	local w = self.world :: Frame
	w.Size = UDim2.fromOffset(b.extent * scale, b.extent * scale)
	w.Position = UDim2.fromOffset(-(v.x - b.minX) * scale, -(v.z - b.minZ) * scale)
	self.pivot.Rotation = -math.deg(v.heading)
	self.arrow.Rotation = math.deg(v.facing - v.heading)

	-- north tick on the rim
	local nx, ny = Pathfind.toMap(0, -1, v.heading, 1)
	self.north.Position = UDim2.new(0.5, nx * (r - 2), 0.5, ny * (r - 2))

	-- markers
	local set: IconSet = self.miniIcons
	table.sort(v.markers, function(a: Marker, c: Marker): boolean
		return (Z_ORDER[a.kind] or 0) < (Z_ORDER[c.kind] or 0)
	end)
	for i, m in v.markers do
		local icon = iconFor(set, m)
		icon.seen = true
		local px, py = Pathfind.toMap(m.x - v.x, m.z - v.z, v.heading, scale)
		local edge = r - 12
		local cx, cy, clamped = Pathfind.clampRadius(px, py, edge)
		if clamped and not CLAMPED[m.kind] then
			icon.root.Visible = false
			continue
		end
		icon.root.Visible = true
		icon.root.Position = UDim2.new(0.5, cx, 0.5, cy)
		icon.root.ZIndex = 10 + i
		icon.root.Rotation = if m.yaw then math.deg(m.yaw - v.heading) else 0
		pulse(icon, m.kind, t)
	end
	sweep(set)

	if self.bigOpen then
		self:updateBig(v, t)
	end
end

function Minimap:updateBig(v: View, t: number)
	local b: Bounds = self.bounds
	local function at(x: number, z: number): UDim2
		return UDim2.fromScale((x - b.minX) / b.extent, (z - b.minZ) / b.extent)
	end
	self.bigMe.Position = at(v.x, v.z)
	self.bigMe.Rotation = math.deg(v.facing)
	local set: IconSet = self.bigIcons
	for i, m in v.markers do
		local icon = iconFor(set, m)
		icon.seen = true
		icon.root.Visible = true
		icon.root.Position = at(m.x, m.z)
		icon.root.ZIndex = 10 + i
		icon.root.Rotation = if m.yaw then math.deg(m.yaw) else 0
		pulse(icon, m.kind, t)
	end
	sweep(set)
end

function Minimap:setVisible(on: boolean)
	self.gui.Enabled = on
	if not on then
		self:toggleBig(false)
	end
end

return Minimap
