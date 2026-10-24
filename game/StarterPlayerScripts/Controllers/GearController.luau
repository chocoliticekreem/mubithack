--!strict
-- GearController [owner: Gear]. Client side of GearService (renders only; the server decides):
--   * GAS MASK (Player attr GasMask): a first-person mask frame (rubber visor with two lenses, a filter
--     canister at the bottom), muffled world audio (EQ on SoundService.Forge_Audio.Master) and a slow
--     breathing loop; your own InvFace model is hidden while the camera is in your head.
--   * THERMAL CAMERA (InvHand == "ThermalCam"): trapped people glow orange through walls, cold tint +
--     a "THERMAL" readout.
--   * LOCKER: the rack's "Open Locker" prompt (attr GearLocker) opens a loadout picker: every gear card,
--     locked ones say "Unlocks at Lv N"; pick up to Progression.LoadoutSize, SAVE -> Gear/SetLoadout.
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
	local l = attr("Level")
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
	lbl.Text = string.upper(what) .. "..."
	local left = untilT - workspace:GetServerTimeNow()
	local total = math.max(0.1, frame:GetAttribute("Total") or left)
	if frame:GetAttribute("For") ~= untilT then
		frame:SetAttribute("For", untilT)
		frame:SetAttribute("Total", math.max(0.1, left))
		total = math.max(0.1, left)
	end
	fill.Size = UDim2.fromScale(math.clamp(1 - left / total, 0, 1), 1)
end

-- locker -------------------------------------------------------------------------------------------
local function closeLocker()
	if lockerGui then
		lockerGui:Destroy()
		lockerGui = nil
	end
end

local function currentLoadout(): { string }
	local raw = attr("GearLoadout")
	local out: { string } = {}
	if type(raw) == "string" then
		for id in string.gmatch(raw, "[^,]+") do
			table.insert(out, id)
		end
	end
	return out
end

local function openLocker()
	closeLocker()
	local lvl = level()
	local picks = currentLoadout()
	local gui = UiKit.screen("GearLocker", 30)
	lockerGui = gui
	local panel = UiKit.panel(gui, "Locker", UDim2.fromOffset(820, 560), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	-- a modal: dims the HUD under it, above every HUD gui; click outside closes
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.modal(panel, { onDismiss = closeLocker })
	UiKit.label(panel, "Title", "LOCKER", UDim2.new(1, 0, 0, 52), UDim2.fromOffset(0, 8), { font = UiKit.Header, textSize = 46, color = Palette.UiRed, stroke = true })
	local sub = UiKit.label(panel, "Sub", "", UDim2.new(1, -40, 0, 26), UDim2.fromOffset(20, 58), { textSize = 20 })
	local grid = Instance.new("Frame")
	grid.Name = "Grid"
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.fromOffset(20, 92)
	grid.Size = UDim2.new(1, -40, 1, -170)
	grid.Parent = panel
	local layout = Instance.new("UIGridLayout")
	layout.CellSize = UDim2.fromOffset(148, 104)
	layout.CellPadding = UDim2.fromOffset(9, 9)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	local cards: { [string]: TextButton } = {}

	local function refresh()
		sub.Text = `Lv {lvl}  -  pick {Progression.LoadoutSize} for your rack ({#picks}/{Progression.LoadoutSize})`
		for id, card in cards do
			local picked = table.find(picks, id) ~= nil
			local open = Progression.isUnlocked(id, lvl)
			local stroke = card:FindFirstChild("Edge") :: UIStroke?
			if stroke then
				stroke.Color = if picked then Palette.UiGood else Palette.UiInk
				stroke.Thickness = if picked then 5 else 3
			end
			card.BackgroundColor3 = if not open then Color3.fromHex("#B9B1A6") elseif picked then Color3.fromHex("#E7F7D9") else Palette.UiCream
			local tag = card:FindFirstChild("Tag") :: TextLabel?
			if tag then
				local def = ItemDefs.get(id)
				tag.Text = if not open
					then `Unlocks at Lv {Progression.unlockLevel(id)}`
					elseif not Progression.lockable(id) then "On your truck"
					elseif picked then "ON RACK"
					else InputHints.format(def and def.blurb or "")
				tag.TextColor3 = if not open then Palette.UiRed elseif picked then Color3.fromHex("#2E7D32") else Palette.UiInk
			end
		end
	end

	for i, id in ItemDefs.GearOrder do
		local def = ItemDefs.get(id)
		local card = Instance.new("TextButton")
		card.Name = id
		card.LayoutOrder = i
		card.Text = ""
		card.AutoButtonColor = true
		card.BackgroundColor3 = Palette.UiCream
		card.Parent = grid
		UiKit.corner(card, 12)
		local edge = UiKit.stroke(card, 3)
		edge.Name = "Edge"
		local swatch = Instance.new("Frame")
		swatch.Name = "Swatch"
		swatch.BackgroundColor3 = Color3.fromHex(def and def.color or "#888888")
		swatch.Position = UDim2.fromOffset(8, 8)
		swatch.Size = UDim2.fromOffset(40, 40)
		swatch.Parent = card
		UiKit.corner(swatch, 10)
		UiKit.label(swatch, "Short", def and def.short or id, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
			font = UiKit.Header,
			textSize = 13,
			color = Palette.UiCream,
			stroke = true,
		})
		UiKit.label(card, "Name", def and def.name or id, UDim2.new(1, -58, 0, 40), UDim2.fromOffset(54, 8), {
			font = UiKit.Header,
			textSize = 18,
			align = Enum.TextXAlignment.Left,
		})
		local tag = UiKit.label(card, "Tag", "", UDim2.new(1, -12, 0, 46), UDim2.fromOffset(6, 52), { textSize = 13 })
		tag.Name = "Tag"
		if not Progression.isUnlocked(id, lvl) then
			local lock = UiKit.label(card, "Lock", "LOCKED", UDim2.fromOffset(70, 18), UDim2.new(1, -76, 0, 4), {
				font = UiKit.Header,
				textSize = 13,
				color = Palette.UiRed,
			})
			lock.Rotation = 8
		end
		cards[id] = card
		card.Activated:Connect(function()
			if not Progression.isUnlocked(id, lvl) then
				UiKit.shake(card, 0.25, 6)
				return
			end
			if not Progression.lockable(id) then
				UiKit.shake(card, 0.2, 4)
				return
			end
			local at = table.find(picks, id)
			if at then
				table.remove(picks, at)
			elseif #picks < Progression.LoadoutSize then
				table.insert(picks, id)
			else
				table.remove(picks, 1)
				table.insert(picks, id)
			end
			UiKit.punch(card, 0.15)
			refresh()
		end)
	end
	local nextId, nextAt = Progression.nextUnlock(lvl)
	if nextId then
		local def = ItemDefs.get(nextId)
		UiKit.label(panel, "Next", `Next unlock: {def and def.name or nextId} at Lv {nextAt}`, UDim2.new(0.5, 0, 0, 30), UDim2.new(0, 20, 1, -62), {
			textSize = 18,
			align = Enum.TextXAlignment.Left,
		})
	end
	local save = UiKit.button(panel, "Save", "SAVE", UDim2.fromOffset(170, 54), UDim2.new(1, -110, 1, -44), Palette.UiGood)
	save.Modal = true -- frees the mouse even in first person
	save.Activated:Connect(function()
		local ok = pcall(function()
			Net.event("Gear", "SetLoadout"):FireServer(picks)
		end)
		if ok then
			closeLocker()
		end
	end)
	local close = UiKit.button(panel, "Close", "X", UDim2.fromOffset(48, 48), UDim2.new(1, -30, 0, 30), Palette.UiRed)
	close.Activated:Connect(closeLocker)
	refresh()
	UiKit.pop(panel, 0.25)
end

-- level-up banner --------------------------------------------------------------------------------------
local function unlockBanner(lvl: number, ids: { string })
	local gui = UiKit.screen("GearUnlocked", 25)
	local panel = UiKit.panel(gui, "Banner", UDim2.fromOffset(520, if #ids > 0 then 96 + 44 * #ids else 96), UDim2.new(0.5, 0, 0.3, 0), Vector2.new(0.5, 0))
	panel.BackgroundColor3 = Palette.UiInk
	UiKit.label(panel, "Head", if #ids > 0 then `LEVEL {lvl}: NEW GEAR!` else `LEVEL {lvl}!`, UDim2.new(1, 0, 0, 46), UDim2.fromOffset(0, 8), {
		font = UiKit.Header,
		textSize = 38,
		color = Palette.UiWarn,
		stroke = true,
	})
	for i, id in ids do
		local def = ItemDefs.get(id)
		UiKit.label(panel, `Item{i}`, `+ {def and def.name or id}`, UDim2.new(1, -40, 0, 38), UDim2.fromOffset(20, 50 + (i - 1) * 44), {
			font = UiKit.Header,
			textSize = 28,
			color = Palette.UiCream,
			stroke = true,
		})
	end
	local nextId, nextAt = Progression.nextUnlock(lvl)
	local foot = if #ids > 0 then InputHints.pick("Pick it at your rack: LOCKER [R]", "Pick it at your rack: tap Open Locker") elseif nextId then `Next unlock: {(ItemDefs.get(nextId) or {}).name or nextId} at Lv {nextAt}` else "You've unlocked everything!"
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
					-- centre cards take turns and wait for the results screen to close (ClientLib/HudLayout)
					local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
					HudLayout.celebrate(function()
						unlockBanner(lvl, ids)
						return if #ids > 0 then 6.5 else 4
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
			-- walked away from the rack: close the locker
			if lockerGui then
				local char = player.Character
				local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
				local near = false
				for _, board in CollectionService:GetTagged("GearRack") do
					if board:IsA("BasePart") and root and (board.Position - root.Position).Magnitude < Cfg.LockerDistance + 8 then
						near = true
						break
					end
				end
				if not near then
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

function GearController:_banner(lvl: number, ids: { string })
	unlockBanner(lvl, ids)
end

return GearController
