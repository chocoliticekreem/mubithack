--!strict
-- DispatchController [owner: Dispatch]. The free-roam DISPATCH radio on screen (server: DispatchService).
--   * [L] DISPATCH: the last section of the top-bar box (ClientLib/TopBox, after level / pass / store), shown
--     while you're free (no call). A red dot = a call is waiting. Opens the DISPATCH list: the calls open
--     right now ("House fire / 27 Maple St · 450 m / ACCEPT", "BUSY" when every crew's out) and BACK TO
--     STATION. A modal (ClientLib/HudLayout.modal), so it dims the HUD and works in first person.
--   * INCOMING CALL card: pops into the top-centre stack (HudLayout "TopCentre") with ACCEPT [Y] /
--     DECLINE [N] under it and a shrinking timer bar; Menu = true frees the mouse in first person.
-- Renders what the server sends (Dispatch/Offer, Dispatch/Calls); every decision is the server's.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigDir:WaitForChild("DispatchConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any
local TopBox = require(ClientLib:WaitForChild("TopBox") :: ModuleScript) :: any

local DispatchController = {}
DispatchController.Priority = 110

local player = Players.LocalPlayer
local CREAM, INK = Palette.UiCream, Palette.UiInk
local GREEN = Color3.fromHex("#3B6E4A")

type Payload = { id: string, kind: string, call: string, address: string, distText: string, busy: boolean, seconds: number }

local ui: { [string]: any } = {}
local offer: Payload? = nil
local offerUntil = 0
local remotes: { [string]: RemoteEvent } = {}

local function dingId(): string
	local ok, A = pcall(function()
		return require(ConfigDir:WaitForChild("AudioConfig") :: ModuleScript) :: any
	end)
	local e = ok and type(A) == "table" and type(A.Sounds) == "table" and A.Sounds.Ding
	return if type(e) == "table" and type(e.id) == "string" then e.id else ""
end

local function stroke(parent: Instance, t: number, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Color = color or INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
end

local function textStroke(parent: Instance, t: number)
	local s = Instance.new("UIStroke")
	s.Thickness = t
	s.Color = INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
end

local function text(parent: Instance, name: string, s: string, font: Enum.Font, color: Color3, size: UDim2, pos: UDim2): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font
	l.Text = s
	l.TextColor3 = color
	l.TextScaled = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Size = size
	l.Position = pos
	l.Parent = parent
	return l
end

local function button(parent: Instance, name: string, color: Color3, size: UDim2): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Size = size
	b.BackgroundColor3 = color
	b.Font = UiKit.Header
	b.TextColor3 = CREAM
	b.TextScaled = true
	b.AutoButtonColor = true
	b.Parent = parent
	UiKit.corner(b, 10)
	stroke(b, 3)
	textStroke(b, 1.5)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.Parent = b
	return b
end

local function free(): boolean
	local id = player:GetAttribute(Names.Attr.InstanceId)
	local ff = player:GetAttribute("FirstFire")
	return (id == nil or id == "") and ff ~= "burning" and ff ~= "queued"
end

---------------------------------------------------------------------------- incoming card

local function showCard(p: Payload?)
	offer = p
	local card = ui.card :: Frame
	if not p then
		card.Visible = false
		ui.dot.Visible = false
		return
	end
	offerUntil = os.clock() + math.max(1, p.seconds)
	ui.cardHead.Text = if p.kind == "mini" then "SMALL JOB" else "INCOMING CALL"
	ui.cardCall.Text = p.call
	ui.cardSub.Text = `{p.address}  ·  {p.distText}`
	ui.bar.Size = UDim2.fromScale(1, 1)
	card.Visible = true
	ui.dot.Visible = true
	UiKit.pop(card, 0.25)
	UiKit.sound(dingId(), 0.6, 1.25)
end

local function acceptOffer()
	local p = offer
	if p and remotes.Accept then
		remotes.Accept:FireServer(p.id)
		showCard(nil)
	end
end

local function declineOffer()
	local p = offer
	if p and remotes.Decline then
		remotes.Decline:FireServer(p.id)
		showCard(nil)
	end
end

---------------------------------------------------------------------------- list panel

local function setOpen(open: boolean)
	local panel = ui.panel :: Frame
	if open == panel.Visible then
		return
	end
	panel.Visible = open
	if open then
		ui.status.Text = "Calling dispatch..."
		ui.status.Visible = true
		for _, c in (ui.rows :: ScrollingFrame):GetChildren() do
			if c:IsA("Frame") then
				c:Destroy()
			end
		end
		if remotes.Open then
			remotes.Open:FireServer()
		end
		UiKit.pop(panel, 0.2)
	end
end

local function row(i: number, p: Payload)
	local r = Instance.new("Frame")
	r.Name = `Call{i}`
	r.LayoutOrder = i
	r.Size = UDim2.new(1, -8, 0, 62)
	r.BackgroundColor3 = if p.busy then Color3.fromHex("#3A3440") else Palette.UiPanelDark
	r.Parent = ui.rows
	UiKit.corner(r, 10)
	stroke(r, 2, if p.kind == "mini" then Palette.UiWarn else INK)
	local title = text(r, "Call", p.call, UiKit.Header, if p.busy then Color3.fromHex("#9A8F86") else CREAM, UDim2.new(1, -150, 0, 28), UDim2.fromOffset(12, 6))
	textStroke(title, 1.5)
	local sub = if p.busy then "Every crew's out on one. Try again soon." else `{p.address}  ·  {p.distText}`
	text(r, "Where", sub, UiKit.Body, if p.busy then Color3.fromHex("#9A8F86") else Palette.UiWarn, UDim2.new(1, -150, 0, 20), UDim2.fromOffset(12, 36))
	if p.busy then
		local tag = text(r, "Busy", "BUSY", UiKit.Header, Color3.fromHex("#9A8F86"), UDim2.fromOffset(120, 30), UDim2.new(1, -128, 0.5, -15))
		tag.TextXAlignment = Enum.TextXAlignment.Center
	else
		local b = button(r, "Accept", GREEN, UDim2.fromOffset(120, 42))
		b.AnchorPoint = Vector2.new(1, 0.5)
		b.Position = UDim2.new(1, -10, 0.5, 0)
		b.Text = "ACCEPT"
		UiKit.onTap(b, function()
			if remotes.Accept then
				remotes.Accept:FireServer(p.id)
			end
			setOpen(false)
		end)
	end
end

local function onCalls(list: any)
	if type(list) ~= "table" or not ui.panel.Visible then
		return
	end
	for _, c in (ui.rows :: ScrollingFrame):GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local n = 0
	for i, p in list do
		if type(p) == "table" and type(p.id) == "string" then
			n += 1
			row(i, p :: Payload)
		end
	end
	ui.status.Visible = n == 0
	ui.status.Text = "Quiet night. No calls right now."
end

---------------------------------------------------------------------------- build

local function build()
	local gui = UiKit.screen("DispatchGui", 27)
	ui.gui = gui

	-- top-bar pill (ClientLib/TopBox): after level / pass / store
	local hasKeys = InputHints.mode() == "keyboard"
	local slot = TopBox.section("Dispatch", 4, if hasKeys then 122 else 92) :: Frame
	local pill = Instance.new("TextButton")
	pill.Name = "DispatchChip"
	pill.AnchorPoint = Vector2.new(0, 0.5)
	pill.Position = UDim2.fromScale(0, 0.5)
	pill.Size = UDim2.new(1, 0, 0, 28)
	pill.BackgroundColor3 = Palette.UiRed
	pill.Font = UiKit.Header
	pill.TextSize = 16
	pill.TextColor3 = CREAM
	pill.AutoButtonColor = true
	pill.Parent = slot
	InputHints.setChip(pill, Cfg.Keys.Toggle, "DISPATCH")
	UiKit.corner(pill, 8)
	UiKit.stroke(pill, 2, INK)
	textStroke(pill, 1.5)
	UiKit.onTap(pill, function()
		setOpen(not ui.panel.Visible)
	end)
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.new(1, -3, 0, 3)
	dot.Size = UDim2.fromOffset(12, 12)
	dot.BackgroundColor3 = Palette.UiWarn
	dot.Visible = false
	dot.ZIndex = 3
	dot.Parent = pill
	UiKit.corner(dot, 6)
	stroke(dot, 2)
	ui.slot, ui.pill, ui.dot = slot, pill, dot
	-- Narrow screens: if the top-bar box would run under the minimap, the pill shrinks to "911"
	local wide = if hasKeys then 122 else 92
	local function fit()
		local box = slot.Parent
		local pg = player:FindFirstChild("PlayerGui")
		local nav = pg and pg:FindFirstChild("NavMinimap")
		local mm = nav and nav:FindFirstChild("Root")
		if not (box and box:IsA("GuiObject") and mm and mm:IsA("GuiObject")) then
			return
		end
		local compact = slot.Size.X.Offset < wide
		local spare = mm.AbsolutePosition.X - 8 - (box.AbsolutePosition.X + box.AbsoluteSize.X)
		if not compact and spare < 0 then
			slot.Size = UDim2.new(0, if hasKeys then 74 else 50, 1, 0)
			InputHints.setChip(pill, Cfg.Keys.Toggle, "911")
		elseif compact and spare > wide - slot.Size.X.Offset + 16 then
			slot.Size = UDim2.new(0, wide, 1, 0)
			InputHints.setChip(pill, Cfg.Keys.Toggle, "DISPATCH")
		end
	end
	slot:GetPropertyChangedSignal("AbsolutePosition"):Connect(fit)
	local boxF = slot.Parent
	if boxF and boxF:IsA("GuiObject") then
		boxF:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	end
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.defer(fit)
		end)
	end
	task.delay(2, fit)

	-- INCOMING CALL card (top-centre stack)
	local card = Instance.new("Frame")
	card.Name = "IncomingCall"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 10)
	card.Size = UDim2.fromOffset(440, 84)
	card.BackgroundColor3 = Palette.UiPanelDark
	card.BackgroundTransparency = 0.04
	card.Visible = false
	card:SetAttribute("Menu", true) -- MenuMouseController frees the mouse in first person
	card.Parent = gui
	UiKit.corner(card, 14)
	stroke(card, 3, Palette.UiRed)
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.Position = UDim2.fromOffset(10, 10)
	chip.Size = UDim2.fromOffset(64, 64)
	chip.BackgroundColor3 = Palette.UiRed
	chip.Parent = card
	UiKit.corner(chip, 10)
	stroke(chip, 2)
	local ct = text(chip, "T", "911", UiKit.Header, CREAM, UDim2.new(1, -10, 1, -18), UDim2.fromOffset(5, 9))
	ct.TextXAlignment = Enum.TextXAlignment.Center
	textStroke(ct, 1.5)
	ui.cardHead = text(card, "Head", "INCOMING CALL", UiKit.Header, Palette.UiWarn, UDim2.new(1, -96, 0, 18), UDim2.fromOffset(86, 8))
	ui.cardCall = text(card, "Call", "", UiKit.Header, CREAM, UDim2.new(1, -96, 0, 30), UDim2.fromOffset(86, 26))
	textStroke(ui.cardCall, 2)
	ui.cardSub = text(card, "Where", "", UiKit.Body, CREAM, UDim2.new(1, -96, 0, 20), UDim2.fromOffset(86, 56))
	local track = Instance.new("Frame")
	track.Name = "Timer"
	track.AnchorPoint = Vector2.new(0, 1)
	track.Position = UDim2.new(0, 14, 1, -3)
	track.Size = UDim2.new(1, -28, 0, 4)
	track.BackgroundTransparency = 1
	track.Parent = card
	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Size = UDim2.fromScale(1, 1)
	bar.BackgroundColor3 = Palette.UiWarn
	bar.BorderSizePixel = 0
	bar.Parent = track
	UiKit.corner(bar, 2)
	ui.bar = bar
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.AnchorPoint = Vector2.new(0.5, 0)
	actions.Position = UDim2.new(0.5, 0, 1, 8)
	actions.Size = UDim2.new(1, 0, 0, 44)
	actions.BackgroundTransparency = 1
	actions.Parent = card
	local al = Instance.new("UIListLayout")
	al.FillDirection = Enum.FillDirection.Horizontal
	al.HorizontalAlignment = Enum.HorizontalAlignment.Center
	al.Padding = UDim.new(0, 12)
	al.SortOrder = Enum.SortOrder.LayoutOrder
	al.Parent = actions
	local acc = button(actions, "Accept", GREEN, UDim2.fromOffset(170, 44))
	acc.LayoutOrder = 1
	InputHints.setChip(acc, Cfg.Keys.Accept, "ACCEPT")
	UiKit.onTap(acc, acceptOffer)
	local dec = button(actions, "Decline", Palette.UiPanelDark, UDim2.fromOffset(150, 44))
	dec.LayoutOrder = 2
	InputHints.setChip(dec, Cfg.Keys.Decline, "DECLINE")
	UiKit.onTap(dec, declineOffer)
	ui.card = card
	-- its height includes the button row, so toasts / banners stack below the buttons
	HudLayout.add("TopCentre", card, 25, function(): number
		return card.Size.Y.Offset + 52
	end)
	HudLayout.reserve(card)

	-- DISPATCH list (modal)
	local panel = UiKit.panel(gui, "DispatchPanel", UDim2.fromOffset(540, 430), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	panel.Visible = false
	panel:SetAttribute("Menu", true)
	panel.ZIndex = 5
	ui.panel = panel
	HudLayout.modal(panel, {
		onDismiss = function()
			setOpen(false)
		end,
	})
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 56)
	head.BackgroundColor3 = Palette.UiRed
	head.BorderSizePixel = 0
	head.Parent = panel
	UiKit.corner(head, 12)
	local flat = Instance.new("Frame")
	flat.Size = UDim2.new(1, 0, 0, 14)
	flat.Position = UDim2.new(0, 0, 1, -14)
	flat.BackgroundColor3 = Palette.UiRed
	flat.BorderSizePixel = 0
	flat.Parent = head
	local ht = text(head, "Title", "DISPATCH", UiKit.Header, CREAM, UDim2.new(1, -90, 0, 36), UDim2.fromOffset(18, 10))
	textStroke(ht, 2)
	local close = button(head, "Close", Palette.UiPanelDark, UDim2.fromOffset(44, 40))
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -10, 0.5, 0)
	close.Text = "X"
	UiKit.onTap(close, function()
		setOpen(false)
	end)
	local rows = Instance.new("ScrollingFrame")
	rows.Name = "Rows"
	rows.Position = UDim2.fromOffset(14, 66)
	rows.Size = UDim2.new(1, -28, 1, -136)
	rows.BackgroundTransparency = 1
	rows.BorderSizePixel = 0
	rows.ScrollBarThickness = 6
	rows.AutomaticCanvasSize = Enum.AutomaticSize.Y
	rows.CanvasSize = UDim2.new()
	rows.Parent = panel
	local rl = Instance.new("UIListLayout")
	rl.Padding = UDim.new(0, 8)
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Parent = rows
	ui.rows = rows
	local status = text(panel, "Status", "", UiKit.Body, INK, UDim2.new(1, -28, 0, 24), UDim2.fromOffset(14, 74))
	status.TextXAlignment = Enum.TextXAlignment.Center
	ui.status = status
	local home = button(panel, "Home", Palette.UiRed, UDim2.fromOffset(240, 46))
	home.AnchorPoint = Vector2.new(0.5, 1)
	home.Position = UDim2.new(0.5, 0, 1, -12)
	home.Text = "BACK TO STATION"
	UiKit.onTap(home, function()
		if remotes.Home then
			remotes.Home:FireServer()
		end
		setOpen(false)
	end)
end

local function refreshVisible()
	local f = free()
	ui.slot.Visible = f
	if not f then
		if ui.panel.Visible then
			setOpen(false)
		end
		if offer then
			showCard(nil)
		end
	end
end

function DispatchController:Start()
	if Cfg.Enabled ~= true then
		return
	end
	build()
	remotes.Accept = Net.event("Dispatch", "Accept")
	remotes.Decline = Net.event("Dispatch", "Decline")
	remotes.Open = Net.event("Dispatch", "Open")
	remotes.Home = Net.event("Dispatch", "Home")
	Net.event("Dispatch", "Offer").OnClientEvent:Connect(function(p: any)
		if type(p) == "table" and type(p.id) == "string" then
			showCard(p :: Payload)
		else
			showCard(nil)
		end
	end)
	Net.event("Dispatch", "Calls").OnClientEvent:Connect(onCalls)
	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(refreshVisible)
	player:GetAttributeChangedSignal("FirstFire"):Connect(refreshVisible)
	refreshVisible()

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		local k = input.KeyCode.Name
		if k == Cfg.Keys.Toggle and free() then
			setOpen(not ui.panel.Visible)
		elseif offer and k == Cfg.Keys.Accept then
			acceptOffer()
		elseif offer and k == Cfg.Keys.Decline then
			declineOffer()
		end
	end)

	-- timer bar
	task.spawn(function()
		while true do
			task.wait(0.1)
			if offer and ui.card.Visible then
				local left = offerUntil - os.clock()
				local total = math.max(1, Cfg.OfferSeconds)
				ui.bar.Size = UDim2.fromScale(math.clamp(left / total, 0, 1), 1)
			end
		end
	end)
end

return DispatchController
