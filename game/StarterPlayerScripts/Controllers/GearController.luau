--!strict
-- GearController [owner: Gear]. Client side of GearService (renders only; the server decides):
--   * GAS MASK (Player attr GasMask): a first-person mask frame (rubber visor with two lenses, a filter
--     canister at the bottom), muffled world audio (EQ on SoundService.Forge_Audio.Master) and a slow
--     breathing loop; your own InvFace model is hidden while the camera is in your head.
--   * THERMAL CAMERA (InvHand == "ThermalCam"): trapped people glow orange through walls, cold tint +
--     a "THERMAL" readout.
--   * LOCKER: the big shared locker's "Locker" prompt (attr GearLocker; E, or tap it; any locker / coat
--     rack in the locker room too, and from anywhere in that room every locker's prompt reaches) opens one
--     kid-sized menu: IN HAND / SWAP / ON BACK on the left, a picture card per item (a ViewportFrame of
--     ReplicatedStorage.LockerIcons) on the right, a big CLOSE. Tap a card = hold it, its BACK chip = put
--     it on your back, tap the worn mask = take it off, tap a slot = put it away. Locked cards show a
--     padlock and "Reach Level N!", the hose says it lives on the truck. Every tap only asks the server
--     (Gear/Locker); Gear/LockerResult comes back as a one-line toast. Walk away and it closes.
--   * LEVEL UP: Gear/Unlocked -> a "NEW GEAR!" banner listing what the level unlocked (or the next one).
--   * Busy bar for prying / cutting (attrs GearBusy, GearBusyUntil); roof hatch prompts hold shorter
--     while you hold a pry bar; Gear/Fx dust puffs.
local CollectionService = game:GetService("CollectionService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("GearConfig") :: ModuleScript) :: any
local Items = ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items")
local ItemDefs = require(Items:WaitForChild("ItemDefs") :: ModuleScript) :: any
local Progression = require(Items:WaitForChild("Progression") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript) :: any
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local Loc = require(game:GetService("ReplicatedStorage"):WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local GearController = {}
GearController.Priority = 110

local player = Players.LocalPlayer

local maskGui: ScreenGui? = nil
local maskOn = false
local breath: Sound? = nil
local muffle: EqualizerSoundEffect? = nil
local thermalOn = false
local thermalCC: ColorCorrectionEffect? = nil
local thermalHl: { [Model]: Highlight } = {}
local hudGui: ScreenGui? = nil
local busyFrame: Frame? = nil
local busyFill: Frame? = nil
local busyLabel: TextLabel? = nil
local lockerGui: ScreenGui? = nil

local function attr(name: string): any
	return player:GetAttribute(name)
end

local function level(): number
	local l = attr("GearLevel") -- GearService's level (what the server unlocks by), else DataService's
	if type(l) ~= "number" then
		l = attr("Level")
	end
	return if type(l) == "number" then l else 1
end

local function firstPerson(): boolean
	local cam = workspace.CurrentCamera
	local char = player.Character
	local head = char and char:FindFirstChild("Head") :: BasePart?
	if not cam or not head then
		return false
	end
	return (cam.CFrame.Position - head.Position).Magnitude < 2.2
end

-- gas mask ------------------------------------------------------------------------------------------
local function buildMask(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "GasMaskOverlay"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = -2 -- under the HUD, over the world
	gui.Enabled = false
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.Size = UDim2.fromScale(1, 1)
	root.Parent = gui
	-- the visor: a wide rounded window; its huge stroke paints everything outside it rubber-black
	local visor = Instance.new("Frame")
	visor.Name = "Visor"
	visor.AnchorPoint = Vector2.new(0.5, 0.5)
	visor.Position = UDim2.fromScale(0.5, 0.45)
	visor.Size = UDim2.fromScale(0.94, 0.8)
	visor.BackgroundColor3 = Color3.fromHex("#9EE6F0")
	visor.BackgroundTransparency = 0.94
	visor.Parent = root
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.48, 0)
	c.Parent = visor
	local edge = Instance.new("UIStroke")
	edge.Name = "Rubber"
	edge.Color = Color3.fromHex("#0E0F11")
	edge.Thickness = 900
	edge.Parent = visor
	local rim = Instance.new("Frame")
	rim.Name = "Rim"
	rim.AnchorPoint = Vector2.new(0.5, 0.5)
	rim.Position = UDim2.fromScale(0.5, 0.5)
	rim.Size = UDim2.fromScale(1, 1)
	rim.BackgroundTransparency = 1
	rim.Parent = visor
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(0.48, 0)
	rc.Parent = rim
	local rs = Instance.new("UIStroke")
	rs.Color = Color3.fromHex("#2B2E33")
	rs.Thickness = 14
	rs.Parent = rim
	-- nose bridge splitting the visor into two lenses
	local bridge = Instance.new("Frame")
	bridge.Name = "Bridge"
	bridge.AnchorPoint = Vector2.new(0.5, 1)
	bridge.Position = UDim2.fromScale(0.5, 1.02)
	bridge.Size = UDim2.fromScale(0.13, 0.42)
	bridge.BackgroundColor3 = Color3.fromHex("#0E0F11")
	bridge.Parent = root
	local bc = Instance.new("UICorner")
	bc.CornerRadius = UDim.new(0.45, 0)
	bc.Parent = bridge
	-- filter canister poking up from the bottom
	local can = Instance.new("Frame")
	can.Name = "Filter"
	can.AnchorPoint = Vector2.new(0.5, 0.5)
	can.Position = UDim2.fromScale(0.5, 1.02)
	can.Size = UDim2.fromScale(0.2, 0.2)
	can.BackgroundColor3 = Color3.fromHex("#4A5A30")
	can.Parent = root
	local cc = Instance.new("UICorner")
	cc.CornerRadius = UDim.new(0.5, 0)
	cc.Parent = can
	local cs = Instance.new("UIStroke")
	cs.Color = Color3.fromHex("#C8A23C")
	cs.Thickness = 6
	cs.Parent = can
	local ar = Instance.new("UIAspectRatioConstraint")
	ar.AspectRatio = 1
	ar.Parent = can
	-- lens glints
	for i, x in { 0.24, 0.66 } do
		local g = Instance.new("Frame")
		g.Name = `Glint{i}`
		g.BackgroundColor3 = Color3.new(1, 1, 1)
		g.BackgroundTransparency = 0.82
		g.Position = UDim2.fromScale(x, 0.16)
		g.Size = UDim2.fromScale(0.09, 0.025)
		g.Rotation = -18
		g.Parent = root
		local gc = Instance.new("UICorner")
		gc.CornerRadius = UDim.new(1, 0)
		gc.Parent = g
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

local function masterGroup(): SoundGroup?
	local folder = SoundService:FindFirstChild("Forge_Audio")
	local master = folder and folder:FindFirstChild("Master")
	return if master and master:IsA("SoundGroup") then master else nil
end

local function setMask(on: boolean)
	maskOn = on
	if not maskGui then
		maskGui = buildMask()
	end
	local group = masterGroup()
	if group and not muffle then
		local eq = Instance.new("EqualizerSoundEffect")
		eq.Name = "GasMaskMuffle"
		eq.LowGain = 2
		eq.MidGain = -4
		eq.HighGain = Cfg.MuffleHighGain
		eq.Enabled = false
		eq.Parent = group
		muffle = eq
	end
	if muffle then
		muffle.Enabled = on
	end
	if on and not breath and type(Cfg.BreathSound) == "string" and Cfg.BreathSound ~= "" then
		local s = Instance.new("Sound")
		s.Name = "GasMaskBreath"
		s.SoundId = Cfg.BreathSound
		s.Looped = true
		s.Volume = Cfg.BreathVolume
		s.Parent = SoundService
		breath = s
	end
	if breath then
		if on then
			breath:Play()
		else
			breath:Stop()
		end
	end
end

local function hideOwnMask(fp: boolean)
	local char = player.Character
	local face = char and char:FindFirstChild("InvFace")
	if not face then
		return
	end
	for _, p in face:GetDescendants() do
		if p:IsA("BasePart") then
			p.LocalTransparencyModifier = if fp then 1 else 0
		end
	end
end

-- thermal ---------------------------------------------------------------------------------------------
local function setThermal(on: boolean)
	thermalOn = on
	if on and not thermalCC then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "GearThermal"
		cc.TintColor = Color3.fromHex("#B7A8FF")
		cc.Saturation = -0.55
		cc.Contrast = 0.15
		cc.Enabled = false
		cc.Parent = Lighting
		thermalCC = cc
	end
	if thermalCC then
		thermalCC.Enabled = on
	end
	if not on then
		for m, h in thermalHl do
			h:Destroy()
			thermalHl[m] = nil
		end
	end
end

local function thermalTick()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local seen: { [Model]: boolean } = {}
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:IsA("Model") and m:IsDescendantOf(workspace) then
			local state = m:GetAttribute(Names.Attr.RescueState)
			if state ~= "Rescued" and state ~= "Toasted" and (m:GetPivot().Position - root.Position).Magnitude <= Cfg.ThermalRange then
				seen[m] = true
				if not thermalHl[m] then
					local h = Instance.new("Highlight")
					h.Name = "ThermalGlow"
					h.Adornee = m
					h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					h.FillColor = Cfg.ThermalHot
					h.FillTransparency = 0.25
					h.OutlineColor = Color3.fromHex("#FFF1D6")
					h.OutlineTransparency = 0.2
					h.Parent = m
					thermalHl[m] = h
				end
			end
		end
	end
	for m, h in thermalHl do
		if not seen[m] then
			h:Destroy()
			thermalHl[m] = nil
		end
	end
end

-- hud: busy bar + thermal label ------------------------------------------------------------------------
local thermalLabel: TextLabel? = nil

local function buildHud()
	local gui = UiKit.screen("GearHud", 5)
	hudGui = gui
	local frame = UiKit.panel(gui, "Busy", UDim2.fromOffset(260, 44), UDim2.new(0.5, 0, 0.62, 0), Vector2.new(0.5, 0.5))
	frame.Visible = false
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BackgroundColor3 = Palette.UiWarn
	fill.Size = UDim2.fromScale(0, 1)
	fill.BorderSizePixel = 0
	fill.Parent = frame
	UiKit.corner(fill, 12)
	local lbl = UiKit.label(frame, "Text", "PRYING...", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), { font = UiKit.Header, textSize = 24, color = Palette.UiInk })
	lbl.ZIndex = 3
	busyFrame, busyFill, busyLabel = frame, fill, lbl
	local t = UiKit.label(gui, "Thermal", "THERMAL", UDim2.fromOffset(240, 40), UDim2.new(0.5, -120, 0, 64), {
		font = UiKit.Header,
		textSize = 30,
		color = Cfg.ThermalHot,
		stroke = true,
	})
	t.Visible = false
	thermalLabel = t
end

local function busyTick()
	local frame, fill, lbl = busyFrame, busyFill, busyLabel
	if not frame or not fill or not lbl then
		return
	end
	local what = attr("GearBusy")
	local untilT = attr("GearBusyUntil")
	if type(what) ~= "string" or what == "" or type(untilT) ~= "number" then
		frame.Visible = false
		return
	end
	frame.Visible = true
	lbl.Text = Loc.t("{1}...", { string.upper(what) })
	local left = untilT - workspace:GetServerTimeNow()
	local total = math.max(0.1, frame:GetAttribute("Total") or left)
	if frame:GetAttribute("For") ~= untilT then
		frame:SetAttribute("For", untilT)
		frame:SetAttribute("Total", math.max(0.1, left))
		total = math.max(0.1, left)
	end
	fill.Size = UDim2.fromScale(math.clamp(1 - left / total, 0, 1), 1)
end

-- locker menu ----------------------------------------------------------------------------------------
-- One big friendly menu (design units, UiKit scales it; HudLayout.modal shrinks it to fit a phone):
-- YOU (hand / swap / back) on the left, picture cards on the right, a big CLOSE. Tapping only asks the
-- server (Gear/Locker); the slots and cards redraw from the Inv* attrs it writes back.
local PANEL_W, PANEL_H = 1180, 640
local LEFT_W = 250
local CARD = 160
local GREEN = Color3.fromHex("#2E9E44") -- a darker UiGood: readable as text on the cream locker panel

local lockerConns: { RBXScriptConnection } = {}
local lockerToast: TextLabel? = nil
local lockerToastAt = 0

local function closeLocker()
	for _, c in lockerConns do
		c:Disconnect()
	end
	table.clear(lockerConns)
	lockerToast = nil
	if lockerGui then
		lockerGui:Destroy()
		lockerGui = nil
	end
end

local function slotOf(name: string): string?
	local v = attr(name)
	return if type(v) == "string" and v ~= "" then v else nil
end

local function ask(action: string, id: string?, slot: string?)
	pcall(function()
		Net.event("Gear", "Locker"):FireServer(action, id, slot)
	end)
end

local function toast(text: string, good: boolean)
	local t = lockerToast
	if not t or text == "" then
		return
	end
	t.Text = text
	t.TextColor3 = if good then GREEN else Palette.UiRed
	t.Visible = true
	lockerToastAt = os.clock()
	local at = lockerToastAt
	UiKit.punch(t, 0.08)
	task.delay(2.2, function()
		if lockerToastAt == at and t.Parent then
			t.Visible = false
		end
	end)
end

-- A ViewportFrame with the item's little model (ReplicatedStorage.LockerIcons, published by GearService).
local function itemView(parent: GuiObject, id: string?, size: UDim2, pos: UDim2): ViewportFrame
	local vp = Instance.new("ViewportFrame")
	vp.Name = "Picture"
	vp.BackgroundTransparency = 1
	vp.Size = size
	vp.Position = pos
	vp.Ambient = Color3.fromRGB(190, 190, 190)
	vp.LightColor = Color3.fromRGB(255, 244, 220)
	vp.LightDirection = Vector3.new(-1, -1.4, -1)
	vp.ZIndex = parent.ZIndex + 1
	vp.Parent = parent
	local icons = ReplicatedStorage:FindFirstChild("LockerIcons")
	local src = id and icons and icons:FindFirstChild(id)
	if src and src:IsA("Model") then
		local m = src:Clone()
		m.Parent = vp
		local cf, ext = m:GetBoundingBox()
		local cam = Instance.new("Camera")
		cam.FieldOfView = 30
		local big = math.max(ext.X, ext.Y, ext.Z)
		local dist = big / (2 * math.tan(math.rad(15))) * 1.02
		local dir = Vector3.new(1, 0.35, 0.5).Unit -- from the side: axe heads and bars show their profile
		cam.CFrame = CFrame.lookAt(cf.Position + dir * dist, cf.Position)
		cam.Parent = vp
		vp.CurrentCamera = cam
	elseif id then
		-- no model yet: the hotbar's chunky colour swatch
		local def = ItemDefs.get(id)
		local sw = Instance.new("Frame")
		sw.BackgroundColor3 = Color3.fromHex(def and def.color or "#888888")
		sw.AnchorPoint = Vector2.new(0.5, 0.5)
		sw.Position = UDim2.fromScale(0.5, 0.5)
		sw.Size = UDim2.fromScale(0.6, 0.8)
		sw.ZIndex = vp.ZIndex
		sw.Parent = parent
		UiKit.corner(sw, 12)
		UiKit.label(sw, "Short", def and def.short or id, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
			font = UiKit.Header,
			textSize = 22,
			color = Palette.UiCream,
			stroke = true,
		}).ZIndex = vp.ZIndex + 1
	end
	return vp
end

local function nearestLocker(): BasePart?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return nil
	end
	local best: BasePart?, bestD = nil, math.huge
	for _, p in CollectionService:GetTagged(Cfg.LockerTag or "StationLocker") do
		if p:IsA("BasePart") and p:IsDescendantOf(workspace) then
			local d = (p.Position - root.Position).Magnitude
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	return best
end

-- in the station's locker room box (GearService checks the same box, with the same slack)
local function inLockerRoom(pos: Vector3): boolean
	for _, z in CollectionService:GetTagged(Cfg.LockerRoomTag or "StationLockerRoom") do
		if z:IsA("BasePart") and z:IsDescendantOf(workspace) then
			local l = z.CFrame:PointToObjectSpace(pos)
			local h = z.Size / 2 + Vector3.new(3, 3, 3)
			if math.abs(l.X) <= h.X and math.abs(l.Y) <= h.Y and math.abs(l.Z) <= h.Z then
				return true
			end
		end
	end
	return false
end

-- Anywhere in the locker room, every locker's prompt reaches you (locally): PC shows one "E Locker"
-- card, a phone one LOCKER bubble over the nearest locker, and tapping ANY locker opens the menu.
local function lockerReachTick()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local inRoom = root ~= nil and inLockerRoom(root.Position)
	local reach = if inRoom then Cfg.LockerRoomReach or 70 else Cfg.LockerDistance
	for _, tag in { Cfg.LockerTag or "StationLocker", Cfg.LockerSpotTag or "StationLockerSpot" } do
		for _, p in CollectionService:GetTagged(tag) do
			local att = p:FindFirstChild("LockerPoint")
			local prompt = att and att:FindFirstChild("LockerPrompt")
			if prompt and prompt:IsA("ProximityPrompt") and prompt.MaxActivationDistance ~= reach then
				prompt.MaxActivationDistance = reach
			end
		end
	end
end

local function openLocker()
	closeLocker()
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	local gui = UiKit.screen("GearLocker", 30)
	lockerGui = gui
	local panel = UiKit.panel(gui, "Locker", UDim2.fromOffset(PANEL_W, PANEL_H), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	panel:SetAttribute("Menu", true)
	local edge = panel:FindFirstChildOfClass("UIStroke")
	if edge then
		edge.Thickness = 5
	end
	-- a modal: dims the HUD under it, above every HUD gui; tapping the dim area closes it
	HudLayout.modal(panel, { onDismiss = closeLocker })

	UiKit.label(panel, "Title", "LOCKER", UDim2.fromOffset(330, 64), UDim2.fromOffset(24, 12), {
		font = UiKit.Header,
		textSize = 60,
		color = Palette.UiRed,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	UiKit.label(panel, "Sub", InputHints.pick("Click a picture to hold it!", "Tap a picture to hold it!", "Pick a picture to hold it!"), UDim2.fromOffset(460, 30), UDim2.fromOffset(300, 34), {
		textSize = 26,
		align = Enum.TextXAlignment.Left,
	})
	local t = UiKit.label(panel, "Toast", "", UDim2.fromOffset(520, 30), UDim2.new(0.5, -170, 0, 74), { font = UiKit.Header, textSize = 26 })
	t.Visible = false
	t.ZIndex = 30
	lockerToast = t

	local close = UiKit.button(panel, "Close", "CLOSE", UDim2.fromOffset(210, 72), UDim2.new(1, -130, 0, 50), Palette.UiPanelDark) -- red = danger only
	close.TextSize = 38
	close.Modal = true -- frees the mouse even in first person
	UiKit.onTap(close, closeLocker)

	-- YOU: hand, swap, back -------------------------------------------------------------------------
	local you = Instance.new("Frame")
	you.Name = "You"
	you.BackgroundTransparency = 1
	you.Position = UDim2.fromOffset(24, 110)
	you.Size = UDim2.fromOffset(LEFT_W, PANEL_H - 130)
	you.Parent = panel

	local function slotTile(name: string, title: string, y: number, h: number): (TextButton, Frame)
		local b = Instance.new("TextButton")
		b.Name = name
		b.Text = ""
		b.AutoButtonColor = true
		b.BackgroundColor3 = Color3.fromHex("#FFFDF6")
		b.Position = UDim2.fromOffset(0, y)
		b.Size = UDim2.fromOffset(LEFT_W, h)
		b.ZIndex = 21
		b.Parent = you
		UiKit.corner(b, 18)
		UiKit.stroke(b, 4)
		UiKit.label(b, "Title", title, UDim2.new(1, 0, 0, 34), UDim2.fromOffset(0, 4), {
			font = UiKit.Header,
			textSize = 30,
			color = Palette.UiInk,
		}).ZIndex = 23
		local holder = Instance.new("Frame")
		holder.Name = "Holder"
		holder.BackgroundTransparency = 1
		holder.Position = UDim2.fromOffset(10, 38)
		holder.Size = UDim2.new(1, -20, 1, -48)
		holder.ZIndex = 22
		holder.Parent = b
		return b, holder
	end
	local handBtn, handHolder = slotTile("Hand", "IN HAND", 0, 210)
	local swap = UiKit.button(you, "Swap", "SWAP", UDim2.fromOffset(LEFT_W, 60), UDim2.fromOffset(LEFT_W / 2, 210 + 12 + 30), Palette.UiWarn)
	swap.ZIndex = 24
	local backBtn, backHolder = slotTile("Back", "ON BACK", 210 + 12 + 60 + 12, 200)
	UiKit.onTap(handBtn, function()
		if slotOf("InvHand") then
			ask("off", nil, "hand")
		end
	end)
	UiKit.onTap(backBtn, function()
		if slotOf("InvBack") then
			ask("off", nil, "back")
		end
	end)
	UiKit.onTap(swap, function()
		ask("swap")
	end)

	-- cards --------------------------------------------------------------------------------------------
	local grid = Instance.new("ScrollingFrame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.BorderSizePixel = 0
	grid.Position = UDim2.fromOffset(24 + LEFT_W + 24, 110)
	grid.Size = UDim2.fromOffset(PANEL_W - LEFT_W - 72, PANEL_H - 126)
	grid.ScrollBarThickness = 10
	grid.ScrollingDirection = Enum.ScrollingDirection.Y
	grid.AutomaticCanvasSize = Enum.AutomaticSize.Y
	grid.CanvasSize = UDim2.new()
	grid.ZIndex = 21
	grid.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(CARD, CARD)
	layout.CellPadding = UDim2.fromOffset(10, 10)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid

	type Card = { btn: TextButton, name: TextLabel, ribbon: TextLabel, lock: Frame, lockText: TextLabel, back: TextButton? }
	local cards: { [string]: Card } = {}

	local function tapCard(id: string, slot: string)
		local st = Progression.lockerState(id, level())
		local card = cards[id]
		if st == "locked" then
			if card then
				UiKit.shake(card.btn, 0.25, 6)
			end
			local def = ItemDefs.get(id)
			toast(Loc.t("{1}: {2}", { def and def.name or id, Progression.lockReason(id) }), false)
			return
		elseif st == "truck" then
			if card then
				UiKit.shake(card.btn, 0.2, 4)
			end
			toast(InputHints.pick("The hose lives on your fire truck! (T at the truck)", "The hose lives on your fire truck!", "The hose lives on your fire truck! (R1 at the truck)"), false)
			return
		end
		if card then
			UiKit.punch(card.btn, 0.12)
		end
		local def = ItemDefs.get(id)
		if def and def.wear == "face" and slotOf("InvFace") == id then
			ask("off", nil, "face") -- tap the mask you're wearing: take it off
			return
		end
		ask("take", id, slot)
	end

	local padDefaultSet = false
	for i, id in Progression.lockerItems() do
		local def = ItemDefs.get(id)
		-- the cell holds two SIBLING buttons (the card, and its BACK chip on top), never one inside the
		-- other: a click on a nested button also reached the card under it
		local cell = Instance.new("Frame")
		cell.Name = id
		cell.LayoutOrder = i
		cell.BackgroundTransparency = 1
		cell.ZIndex = 22
		cell.Parent = grid
		local b = Instance.new("TextButton")
		b.Name = "Pick"
		b.Text = ""
		if not padDefaultSet and id ~= "Hose" then
			padDefaultSet = true
			b:SetAttribute("GamepadDefault", true) -- gamepad: the cursor opens on the first item you can take
		end
		b.AutoButtonColor = true
		b.BackgroundColor3 = Palette.UiCream
		b.Size = UDim2.fromScale(1, 1)
		b.ZIndex = 22
		b.Parent = cell
		UiKit.corner(b, 18)
		local stroke = UiKit.stroke(b, 4)
		stroke.Name = "Edge"
		itemView(b, id, UDim2.new(1, -12, 0, 104), UDim2.fromOffset(6, 6))
		local nameL = UiKit.label(b, "Name", def and def.name or id, UDim2.new(1, -10, 0, 40), UDim2.new(0, 5, 1, -44), {
			font = UiKit.Header,
			textSize = 24,
			scaled = true,
		})
		nameL.ZIndex = 24
		local cap = Instance.new("UITextSizeConstraint")
		cap.MaxTextSize = 24
		cap.Parent = nameL
		local ribbon = UiKit.label(b, "Ribbon", "", UDim2.fromOffset(84, 28), UDim2.fromOffset(6, 6), {
			font = UiKit.Header,
			textSize = 16,
			color = Palette.UiCream,
			stroke = true,
		})
		ribbon.BackgroundTransparency = 0
		ribbon.BackgroundColor3 = GREEN
		ribbon.ZIndex = 27
		ribbon.Visible = false
		UiKit.corner(ribbon, 10)
		-- locked: a dark cover, a padlock and what unlocks it
		local lock = Instance.new("Frame")
		lock.Name = "Lock"
		lock.BackgroundColor3 = Color3.fromHex("#1A1210")
		lock.BackgroundTransparency = 0.3
		lock.Size = UDim2.fromScale(1, 1)
		lock.ZIndex = 28
		lock.Visible = false
		lock.Parent = b
		UiKit.corner(lock, 18)
		UiKit.label(lock, "Padlock", "🔒", UDim2.new(1, 0, 0, 70), UDim2.fromOffset(0, 10), { textSize = 56 }).ZIndex = 29
		local lockText = UiKit.label(lock, "Why", "", UDim2.new(1, -10, 0, 60), UDim2.new(0, 5, 1, -64), {
			font = UiKit.Header,
			textSize = 21,
			color = Palette.UiWarn,
			stroke = true,
			scaled = true,
		})
		lockText.ZIndex = 29
		local lcap = Instance.new("UITextSizeConstraint")
		lcap.MaxTextSize = 21
		lcap.Parent = lockText
		local backB: TextButton? = nil
		if def and def.backable and not def.tethered and def.wear == nil then
			local bb = Instance.new("TextButton")
			bb.Name = "ToBack"
			bb.Text = "BACK"
			bb.Font = UiKit.Header
			bb.TextSize = 18
			bb.TextColor3 = Palette.UiCream
			bb.BackgroundColor3 = Color3.fromHex("#4F6B8A")
			bb.AnchorPoint = Vector2.new(1, 0)
			bb.Position = UDim2.new(1, -6, 0, 6)
			bb.Size = UDim2.fromOffset(62, 34)
			bb.ZIndex = 30
			bb.Parent = cell
			UiKit.corner(bb, 10)
			UiKit.stroke(bb, 3)
			UiKit.onTap(bb, function()
				tapCard(id, "back")
			end)
			backB = bb
		end
		cards[id] = { btn = b, name = nameL, ribbon = ribbon, lock = lock, lockText = lockText, back = backB }
		UiKit.onTap(b, function()
			tapCard(id, "hand")
		end)
	end

	local shown: { [Frame]: string } = {}
	local function showIn(holder: Frame, id: string?, emptyText: string)
		if shown[holder] == (id or "") then
			return
		end
		shown[holder] = id or ""
		holder:ClearAllChildren()
		if id then
			itemView(holder, id, UDim2.new(1, 0, 1, -30), UDim2.fromOffset(0, 0))
			local def = ItemDefs.get(id)
			UiKit.label(holder, "Name", def and def.name or id, UDim2.new(1, 0, 0, 30), UDim2.new(0, 0, 1, -30), {
				font = UiKit.Header,
				textSize = 24,
			}).ZIndex = 24
		else
			UiKit.label(holder, "Empty", emptyText, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
				textSize = 22,
				color = Color3.fromHex("#8A7F72"),
			}).ZIndex = 24
		end
	end

	local function refresh()
		if not gui.Parent then
			return
		end
		local lvl = level()
		local hand, back, face = slotOf("InvHand"), slotOf("InvBack"), slotOf("InvFace")
		showIn(handHolder, hand, "Empty hands")
		showIn(backHolder, back, "Nothing on your back")
		swap.Visible = hand ~= nil or back ~= nil
		for id, c in cards do
			local st = Progression.lockerState(id, lvl)
			local on = if id == hand then "IN HAND" elseif id == back then "ON BACK" elseif id == face then "ON FACE" else nil
			c.ribbon.Visible = on ~= nil
			c.ribbon.Text = on or ""
			local edge = c.btn:FindFirstChild("Edge") :: UIStroke?
			if edge then
				edge.Color = if on then GREEN else Palette.UiInk
				edge.Thickness = if on then 6 else 4
			end
			c.btn.BackgroundColor3 = if on then Color3.fromHex("#E3F6DA") else Palette.UiCream
			c.lock.Visible = st ~= "open"
			c.name.Visible = st == "open"
			local nm = (ItemDefs.get(id) or {}).name or id
			c.lockText.Text = `{nm}\n{if st == "truck" then "On your truck!" else Progression.lockReason(id)}`
			local padlock = c.lock:FindFirstChild("Padlock") :: TextLabel?
			if padlock then
				padlock.Text = if st == "truck" then "🚒" else "🔒"
			end
			if c.back then
				c.back.Visible = st == "open" and id ~= back
			end
		end
	end
	for _, a in { "InvHand", "InvBack", "InvFace", "GearLevel", "Level" } do
		table.insert(lockerConns, player:GetAttributeChangedSignal(a):Connect(refresh))
	end
	refresh()
	UiKit.pop(panel, 0.25)
end

-- level-up banner --------------------------------------------------------------------------------------
local function unlockBanner(lvl: number, ids: { string }): ScreenGui
	local gui = UiKit.screen("GearUnlocked", 25)
	local panel = UiKit.panel(gui, "Banner", UDim2.fromOffset(520, if #ids > 0 then 96 + 44 * #ids else 96), UDim2.new(0.5, 0, 0.3, 0), Vector2.new(0.5, 0))
	panel.BackgroundColor3 = Palette.UiInk
	UiKit.label(panel, "Head", if #ids > 0 then Loc.t("LEVEL {1}: NEW GEAR!", { lvl }) else Loc.t("LEVEL {1}!", { lvl }), UDim2.new(1, 0, 0, 46), UDim2.fromOffset(0, 8), {
		font = UiKit.Header,
		textSize = 38,
		color = Palette.UiWarn,
		stroke = true,
	})
	for i, id in ids do
		local def = ItemDefs.get(id)
		UiKit.label(panel, `Item{i}`, Loc.t("+ {1}", { def and def.name or id }), UDim2.new(1, -40, 0, 38), UDim2.fromOffset(20, 50 + (i - 1) * 44), {
			font = UiKit.Header,
			textSize = 28,
			color = Palette.UiCream,
			stroke = true,
		})
	end
	local nextId, nextAt = Progression.nextUnlock(lvl)
	local foot = if #ids > 0 then "Get it at the big red LOCKER!" elseif nextId then Loc.t("Next unlock: {1} at Lv {2}", { (ItemDefs.get(nextId) or {}).name or nextId, nextAt }) else "You've unlocked everything!"
	UiKit.label(panel, "Foot", foot, UDim2.new(1, -20, 0, 26), UDim2.new(0, 10, 1, -34), { textSize = 18, color = Palette.UiCream })
	UiKit.pop(panel, 0.3)
	task.delay(if #ids > 0 then 6 else 3.5, function()
		if gui.Parent then
			local t = TweenService:Create(panel, TweenInfo.new(0.4), { Position = UDim2.new(0.5, 0, -0.5, 0) })
			t:Play()
			t.Completed:Wait()
			gui:Destroy()
		end
	end)
	return gui
end

-- fx -------------------------------------------------------------------------------------------------
local function puff(kind: string, pos: Vector3)
	local cam = workspace.CurrentCamera
	if cam and (cam.CFrame.Position - pos).Magnitude > 140 then
		return
	end
	local p = Instance.new("Part")
	p.Name = "GearPuff"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = Vector3.one
	p.Position = pos
	p.Parent = workspace
	local pe = Instance.new("ParticleEmitter")
	pe.Rate = 0
	pe.Lifetime = NumberRange.new(0.5, 1.1)
	pe.Speed = NumberRange.new(6, 14)
	pe.SpreadAngle = Vector2.new(180, 180)
	pe.Size = NumberSequence.new(if kind == "breach" then 2.4 else 1.2, 0)
	pe.Transparency = NumberSequence.new(0.3, 1)
	pe.Color = ColorSequence.new(if kind == "saw" then Color3.fromHex("#FFC531") else Color3.fromHex("#CFC6B8"))
	pe.LightEmission = if kind == "saw" then 1 else 0
	pe.Parent = p
	pe:Emit(if kind == "breach" then 40 elseif kind == "smash" then 18 else 10)
	task.delay(1.5, function()
		p:Destroy()
	end)
end

-- service -------------------------------------------------------------------------------------------
function GearController:Init(_controllers: { [string]: any }) end

function GearController:Start()
	buildHud()
	player:GetAttributeChangedSignal("GasMask"):Connect(function()
		setMask(attr("GasMask") == true)
	end)
	setMask(attr("GasMask") == true)
	player:GetAttributeChangedSignal("InvHand"):Connect(function()
		setThermal(attr("InvHand") == "ThermalCam")
	end)

	task.spawn(function()
		local ok, unlocked = pcall(Net.event, "Gear", "Unlocked")
		if ok and unlocked then
			unlocked.OnClientEvent:Connect(function(lvl: any, ids: any)
				if type(lvl) == "number" and type(ids) == "table" then
					if #ids == 0 then
						return -- no new gear: ProfileController's LEVEL N! card already says it (one card per level-up)
					end
					-- centre cards take turns and wait for the results screen to close (ClientLib/HudLayout)
					local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
					HudLayout.celebrate(function()
						local g = unlockBanner(lvl, ids)
						-- tap anywhere / calm screens: HudLayout calls this to take it down early
						return if #ids > 0 then 6.5 else 4, function()
							g:Destroy()
						end
					end)
				end
			end)
		end
		local okFx, fxr = pcall(Net.event, "Gear", "Fx")
		if okFx and fxr then
			fxr.OnClientEvent:Connect(function(kind: any, pos: any)
				if type(kind) == "string" and typeof(pos) == "Vector3" then
					puff(kind, pos)
				end
			end)
		end
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		if prompt:GetAttribute("GearLocker") then
			openLocker()
		end
	end)
	task.spawn(function()
		local ok, res = pcall(Net.event, "Gear", "LockerResult")
		if ok and res then
			res.OnClientEvent:Connect(function(good: any, msg: any)
				if type(msg) == "string" then
					toast(msg, good == true)
				end
			end)
		end
	end)
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		if prompt:GetAttribute("GearHatch") then
			local hand = attr("InvHand")
			local def = ItemDefs.get(hand)
			prompt.HoldDuration = if def and def.pry then Cfg.HatchPrySeconds else Cfg.HatchOpenSeconds
		end
	end)

	local acc = 0
	RunService.RenderStepped:Connect(function(dt: number)
		local fp = firstPerson()
		if maskGui then
			maskGui.Enabled = maskOn and fp
		end
		if maskOn then
			hideOwnMask(fp)
		end
		if thermalLabel then
			thermalLabel.Visible = thermalOn
		end
		busyTick()
		acc += dt
		if acc >= 0.5 then
			acc = 0
			if thermalOn then
				thermalTick()
			end
			lockerReachTick()
			-- walked away from the locker (or got teleported off to a call): close the menu
			if lockerGui then
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				local lk = nearestLocker()
				local inRoom = root ~= nil and inLockerRoom(root.Position)
				if not root or (not inRoom and (not lk or (lk.Position - root.Position).Magnitude > Cfg.LockerCloseDistance)) then
					closeLocker()
				end
			end
		end
	end)
	player.CharacterAdded:Connect(function()
		setThermal(false)
	end)
end

-- test hooks (ForgeTestAgent / manual): open the locker, fake a level-up banner
function GearController:_openLocker()
	openLocker()
end

function GearController:_closeLocker()
	closeLocker()
end

function GearController:_banner(lvl: number, ids: { string })
	unlockBanner(lvl, ids)
end

return GearController
