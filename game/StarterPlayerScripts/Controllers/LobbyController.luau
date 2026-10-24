--!strict
-- LobbyController [owner: G3]. Client side of the station lobby:
--   * Mission picker: opens from the MissionBoard ProximityPrompt, a click on the board or a pad's
--     "Change call" prompt (PadPrompt); a scrolling list of ReplicatedStorage.Config.MissionCatalog
--     (disabled ones greyed "COMING SOON"); ROLL OUT sends Lobby/Choose(missionId) (leader / solo).
--   * Squad strip (bottom): your squad, its call, "2/4 READY", and the leader's GO NOW (Lobby/Launch).
--   * Countdown: Lobby/Countdown(padId, seconds, title). Above BigCountdownFrom a banner; from 5..1 a
--     huge centre number with a tick sound and a screen pulse (red + shake at 3..2..1); 0 = "GO GO GO!",
--     the alarm hook (AlarmController:Blare/Play/Trigger if present) and a quick fade.
--   * Lobby/Fx: "slide" (fire pole), "welcome" / "toast" (compact centre toast).
-- Everything hides while the local Player's InstanceId ~= "" (in a mission).
local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local LobbyConfig = require(ConfigDir:WaitForChild("LobbyConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigDir:WaitForChild("MissionCatalog") :: ModuleScript) :: { any }
local LobbyQueue = require(ReplicatedStorage:WaitForChild("Lobby"):WaitForChild("LobbyQueue") :: ModuleScript)
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)

local LobbyController = {}
LobbyController.Priority = 100

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

local hex = Color3.fromHex
local C = {
	Ink = hex("1A1210"),
	Cream = hex("FFF1D6"),
	Red = hex("C8232B"),
	Hot = hex("FF3B2A"),
	Yellow = hex("E3B23C"),
	Panel = hex("22303A"),
	Card = hex("2E4452"),
	CardOff = hex("1C2329"),
	Grey = hex("8C8A88"),
	Green = hex("6BCB5A"),
}

local ui: { [string]: any } = {}
local mySquad: any = nil
local byId: { [string]: any } = {}

local function inMission(): boolean
	local id = player:GetAttribute(Names.Attr.InstanceId)
	return id ~= nil and id ~= ""
end

local function label(parent: Instance, name: string, pos: UDim2, size: UDim2, text: string, color: Color3, font: Enum.Font, strokeT: number?): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Position = pos
	t.Size = size
	t.Text = text
	t.TextColor3 = color
	t.Font = font
	t.TextScaled = true
	t.TextWrapped = true
	t.Parent = parent
	if strokeT then
		local s = Instance.new("UIStroke")
		s.Thickness = strokeT
		s.Color = C.Ink
		s.Parent = t
	end
	return t
end

local function corner(parent: Instance, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = parent
end

local function playLocal(soundId: string)
	if soundId == nil or soundId == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Parent = SoundService
	SoundService:PlayLocalSound(s)
	task.delay(5, function()
		s:Destroy()
	end)
end

local function shake(mag: number, seconds: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, mag, seconds)
	end
end

local function alarmHook()
	local alarm = controllers.AlarmController
	if not alarm then
		return
	end
	for _, name in { "Blare", "Play", "Trigger", "Flash" } do
		if type(alarm[name]) == "function" then
			pcall(alarm[name], alarm)
			return
		end
	end
end

------------------------------------------------------------------ build UI

local function buildUi()
	local gui = Instance.new("ScreenGui")
	gui.Name = "LobbyUI"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 20
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = player:WaitForChild("PlayerGui")
	ui.gui = gui

	local pulse = Instance.new("Frame")
	pulse.Name = "Pulse"
	pulse.Size = UDim2.fromScale(1, 1)
	pulse.BackgroundColor3 = C.Hot
	pulse.BackgroundTransparency = 1
	pulse.BorderSizePixel = 0
	pulse.ZIndex = 1
	pulse.Parent = gui
	ui.pulse = pulse

	local fade = Instance.new("Frame")
	fade.Name = "Fade"
	fade.Size = UDim2.fromScale(1, 1)
	fade.BackgroundColor3 = Color3.new(0, 0, 0)
	fade.BackgroundTransparency = 1
	fade.BorderSizePixel = 0
	fade.ZIndex = 50
	fade.Parent = gui
	ui.fade = fade

	local big = label(gui, "Big", UDim2.fromScale(0.3, 0.28), UDim2.fromScale(0.4, 0.3), "", C.Cream, Enum.Font.LuckiestGuy, 6)
	big.ZIndex = 40
	big.Visible = false
	local scale = Instance.new("UIScale")
	scale.Parent = big
	ui.big, ui.bigScale = big, scale

	-- under the OnboardingController objective card (top centre), not on top of it
	local banner = label(gui, "Banner", UDim2.new(0.25, 0, 0, 170), UDim2.new(0.5, 0, 0, 40), "", C.Yellow, Enum.Font.LuckiestGuy, 3)
	banner.Visible = false
	ui.banner = banner

	local toast = label(gui, "Toast", UDim2.fromScale(0.3, 0.16), UDim2.fromScale(0.4, 0.045), "", C.Cream, Enum.Font.LuckiestGuy, 2) -- compact (FeedbackConfig)
	toast.Visible = false
	toast.ZIndex = 45
	ui.toast = toast
	-- Both join the top-centre stack (ClientLib/HudLayout): under the objective card and the HUD toasts,
	-- whatever is showing, so they never print over each other. HudLayout owns their Position.Y.
	HudLayout.add("TopCentre", banner, 35)
	HudLayout.add("TopCentre", toast, 45, function()
		return toast.AbsoluteSize.Y
	end)
	local function placeTopLines()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local v = cam.ViewportSize
		local s = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.55, 1.4)
		banner.Size = UDim2.new(0.5, 0, 0, math.floor(40 * math.max(s, 0.8)))
	end
	placeTopLines()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(placeTopLines)
	end

	-- Squad strip
	local strip = Instance.new("Frame")
	strip.Name = "Squad"
	strip.AnchorPoint = Vector2.new(0.5, 1)
	strip.Position = UDim2.new(0.5, 0, 1, -128) -- above the inventory hotbar
	strip.Size = UDim2.new(0, 520, 0, 64)
	strip.BackgroundColor3 = C.Panel
	strip.BackgroundTransparency = 0.15
	strip.Visible = false
	strip.Parent = gui
	corner(strip, 12)
	-- same viewport scale as UiKit HUDs: a fixed 520 px strip covered most of a phone screen
	local stripScale = Instance.new("UIScale")
	local function rescaleStrip()
		local cam = workspace.CurrentCamera
		if cam then
			local v = cam.ViewportSize
			stripScale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.55, 1.4)
		end
	end
	rescaleStrip()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescaleStrip)
	end
	stripScale.Parent = strip
	ui.strip = strip
	ui.stripText = label(strip, "Text", UDim2.new(0, 14, 0, 6), UDim2.new(1, -170, 1, -12), "", C.Cream, Enum.Font.FredokaOne)
	ui.stripText.TextXAlignment = Enum.TextXAlignment.Left
	local go = Instance.new("TextButton")
	go.Name = "Go"
	go.AnchorPoint = Vector2.new(1, 0.5)
	go.Position = UDim2.new(1, -10, 0.5, 0)
	go.Size = UDim2.new(0, 140, 0, 46)
	go.BackgroundColor3 = C.Red
	go.Text = "GO NOW!"
	go.TextScaled = true
	go.Font = Enum.Font.LuckiestGuy
	go.TextColor3 = C.Cream
	go.Parent = strip
	corner(go, 10)
	ui.go = go

	-- Mission picker
	local panel = Instance.new("Frame")
	panel.Name = "Picker"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.new(0.62, 0, 0.74, 0)
	panel.BackgroundColor3 = C.Panel
	panel.Visible = false
	panel.ZIndex = 30
	panel.Parent = gui
	corner(panel, 16)
	local sizeLimit = Instance.new("UISizeConstraint")
	sizeLimit.MaxSize = Vector2.new(900, 720)
	sizeLimit.MinSize = Vector2.new(320, 300)
	sizeLimit.Parent = panel
	ui.panel = panel
	-- a modal: dims the HUD under it, above every HUD gui; click outside closes
	HudLayout.modal(panel, {
		onDismiss = function()
			panel.Visible = false
		end,
	})
	local head = label(panel, "Title", UDim2.new(0, 16, 0, 10), UDim2.new(1, -90, 0, 44), "DISPATCH: PICK A CALL", C.Yellow, Enum.Font.LuckiestGuy, 3)
	head.TextXAlignment = Enum.TextXAlignment.Left
	head.ZIndex = 31
	ui.pickerSub = label(panel, "Sub", UDim2.new(0, 16, 0, 54), UDim2.new(1, -32, 0, 22), "", C.Cream, Enum.Font.Gotham)
	ui.pickerSub.TextXAlignment = Enum.TextXAlignment.Left
	ui.pickerSub.ZIndex = 31
	local close = Instance.new("TextButton")
	close.Name = "Close"
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.new(1, -12, 0, 12)
	close.Size = UDim2.new(0, 44, 0, 44)
	close.BackgroundColor3 = C.Red
	close.Text = "X"
	close.TextScaled = true
	close.Font = Enum.Font.LuckiestGuy
	close.TextColor3 = C.Cream
	close.ZIndex = 31
	close.Parent = panel
	corner(close, 10)
	close.Activated:Connect(function()
		panel.Visible = false
	end)
	-- 11+ calls: a scrolling list (mouse wheel, touch drag, gamepad). The canvas follows the layout's
	-- content height explicitly (AutomaticCanvasSize under-counts list padding on some devices, which
	-- cut the last card off), and the scroll bar is bright enough to see on the dark panel.
	panel:SetAttribute("Menu", true) -- MenuMouseController frees the first-person mouse while it's open
	local list = Instance.new("ScrollingFrame")
	list.Name = "List"
	list.Position = UDim2.new(0, 12, 0, 84)
	list.Size = UDim2.new(1, -24, 1, -96)
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollingEnabled = true
	list.ScrollBarThickness = 12
	list.ScrollBarImageColor3 = C.Yellow
	list.ScrollBarImageTransparency = 0.1
	list.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar
	list.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	list.AutomaticCanvasSize = Enum.AutomaticSize.None
	list.CanvasSize = UDim2.new()
	list.Selectable = true
	list.ZIndex = 31
	list.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 2)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 4)
	pad.Parent = list
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 8)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list
	local function fitCanvas()
		list.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y + 12)
	end
	layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(fitCanvas)
	fitCanvas()
	ui.list = list
	ui.listLayout = layout
end

local function renderPicker()
	local list = ui.list
	if not list then
		return
	end
	for _, c in list:GetChildren() do
		if c:IsA("Frame") then
			c:Destroy()
		end
	end
	local current = mySquad and mySquad.missionId
	local leader = mySquad == nil or mySquad.leader == player.UserId
	local open = 0
	for _, m in MissionCatalog do
		if m.enabled then
			open += 1
		end
	end
	ui.pickerSub.Text = (if mySquad == nil
		then "Pick a call, then step on a glowing pad outside."
		elseif leader then "You lead this squad: your pick is the squad's call."
		else "Only your squad leader can change the call.") .. `  ({open} calls, scroll for more)`
	for i, m in MissionCatalog do
		local card = Instance.new("Frame")
		card.Name = m.id
		card.LayoutOrder = i
		card.Size = UDim2.new(1, -10, 0, 86)
		card.BackgroundColor3 = if m.id == current then hex("8E1A1F") elseif m.enabled then C.Card else C.CardOff
		card.ZIndex = 32
		card.Parent = list
		corner(card, 10)
		local on = m.enabled == true
		local t = label(card, "Title", UDim2.new(0, 12, 0, 6), UDim2.new(0.5, 0, 0, 30), m.title, if on then C.Yellow else C.Grey, Enum.Font.FredokaOne)
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.ZIndex = 33
		local b = label(card, "Blurb", UDim2.new(0, 12, 0, 38), UDim2.new(0.7, 0, 0, 42), m.blurb, if on then C.Cream else C.Grey, Enum.Font.Gotham)
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.ZIndex = 33
		local d = LobbyQueue.difficulty(m)
		local meta = label(card, "Meta", UDim2.new(0.5, 12, 0, 8), UDim2.new(0.25, 0, 0, 24), `{LobbyQueue.playersText(m)}   HEAT {string.rep("*", d)}{string.rep("-", 5 - d)}`, if on then C.Cream else C.Grey, Enum.Font.GothamBold)
		meta.TextXAlignment = Enum.TextXAlignment.Left
		meta.ZIndex = 33
		local btn = Instance.new("TextButton")
		btn.AnchorPoint = Vector2.new(1, 0.5)
		btn.Position = UDim2.new(1, -10, 0.5, 0)
		btn.Size = UDim2.new(0.22, 0, 0, 52)
		btn.BackgroundColor3 = if not on then C.CardOff elseif m.id == current then C.Green else C.Red
		btn.AutoButtonColor = on and leader
		btn.Text = if not on then "COMING SOON" elseif m.id == current then "PICKED" else "ROLL OUT"
		btn.TextScaled = true
		btn.Font = Enum.Font.LuckiestGuy
		btn.TextColor3 = if on then C.Cream else C.Grey
		btn.ZIndex = 33
		btn.Parent = card
		corner(btn, 8)
		if on and leader then
			btn.Activated:Connect(function()
				Net.event("Lobby", "Choose"):FireServer(m.id)
				ui.panel.Visible = false
			end)
		end
	end
end

local function openPicker()
	if inMission() or not ui.panel then
		return
	end
	local wasOpen = ui.panel.Visible
	renderPicker()
	ui.panel.Visible = true
	if not wasOpen then
		-- start at the squad's current call (it may be far down the list)
		task.defer(function()
			local list: ScrollingFrame = ui.list
			local current = mySquad and mySquad.missionId
			local card = current and list:FindFirstChild(current)
			if card and card:IsA("GuiObject") then
				local y = card.AbsolutePosition.Y - list.AbsolutePosition.Y + list.CanvasPosition.Y
				list.CanvasPosition = Vector2.new(0, math.max(0, y - 8))
			else
				list.CanvasPosition = Vector2.zero
			end
		end)
	end
end

-- Sit just above InventoryController's hotbar, whatever its UIScale (it is ~100px at 720p, ~145px at
-- 1080p); a fixed offset overlapped it on big screens.
local function placeStrip()
	local strip = ui.strip
	if not strip then
		return
	end
	local inv = player:FindFirstChild("PlayerGui") and player.PlayerGui:FindFirstChild("InventoryHud")
	local bar = inv and inv:FindFirstChild("Hotbar")
	local h = if bar and bar:IsA("GuiObject") and bar.Visible then bar.AbsoluteSize.Y + 22 else 24
	local want = UDim2.new(0.5, 0, 1, -math.floor(h))
	if strip.Position ~= want then
		strip.Position = want
	end
end

-- Local only: hide the sign over the pad you're standing on (you'd be right under it, so it filled the
-- screen); the squad strip shows the same info. Other pads keep their signs.
local function hideOwnPadSign()
	local mine = if mySquad and not mySquad.instanceId then mySquad.padId else nil
	for _, pad in CollectionService:GetTagged(Names.Tag.SquadPad) do
		local bb = pad:FindFirstChild("PadBillboard")
		if bb and bb:IsA("BillboardGui") then
			bb.Enabled = pad:GetAttribute(Names.Attr.PadId) ~= mine
		end
	end
end

local function renderStrip()
	if not ui.strip then
		return
	end
	placeStrip()
	hideOwnPadSign()
	if inMission() or not mySquad or mySquad.instanceId then
		ui.strip.Visible = false
		return
	end
	local def = byId[mySquad.missionId or ""]
	local cap = math.min(LobbyConfig.MaxSquadSize, def and def.players and def.players.max or LobbyConfig.MaxSquadSize)
	local lead = mySquad.leader == player.UserId
	ui.stripText.Text = `PAD {mySquad.padId}  |  {def and def.title or "No call"}  |  {LobbyQueue.readyText(#mySquad.members, cap)}{if lead then "  |  you lead" else ""}`
	ui.go.Visible = lead
	ui.strip.Visible = true
end

------------------------------------------------------------------ effects

local function pop(text: string, color: Color3, from: number)
	local big: TextLabel = ui.big
	big.Text = text
	big.TextColor3 = color
	big.TextTransparency = 0
	big.Visible = true
	ui.bigScale.Scale = from
	TweenService:Create(ui.bigScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function pulse(color: Color3, alpha: number)
	local f: Frame = ui.pulse
	f.BackgroundColor3 = color
	f.BackgroundTransparency = 1 - alpha
	TweenService:Create(f, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { BackgroundTransparency = 1 }):Play()
end

local function showToast(text: string, seconds: number)
	local t: TextLabel = ui.toast
	t.Text = text
	t.TextTransparency = 0
	t.Visible = true
	local s = t:FindFirstChildOfClass("UIStroke")
	if s then
		s.Transparency = 0
	end
	t.Rotation = -3
	TweenService:Create(t, TweenInfo.new(0.3, Enum.EasingStyle.Back), { Rotation = 0 }):Play()
	task.delay(seconds, function()
		if t.Text ~= text then
			return
		end
		TweenService:Create(t, TweenInfo.new(0.5), { TextTransparency = 1 }):Play()
		if s then
			TweenService:Create(s, TweenInfo.new(0.5), { Transparency = 1 }):Play()
		end
	end)
end

local function onCountdown(padId: number, seconds: number, title: string)
	if seconds < 0 then
		ui.big.Visible = false
		ui.banner.Visible = false
		return
	end
	if seconds == 0 then
		ui.banner.Visible = false
		pop("GO GO GO!", C.Yellow, 2.4)
		pulse(C.Hot, 0.55)
		shake(0.8, 0.5)
		playLocal(LobbyConfig.GoSoundId)
		alarmHook()
		-- v2 dispatch: you stay in the station and run to your truck, so no fade-to-black blink here
		task.delay(1.1, function()
			if ui.big.Text == "GO GO GO!" then
				TweenService:Create(ui.big, TweenInfo.new(0.3), { TextTransparency = 1 }):Play()
				task.delay(0.35, function()
					ui.big.Visible = false
				end)
			end
		end)
		return
	end
	ui.banner.Text = `PAD {padId}: {title}  -  ROLLING OUT IN {seconds}`
	ui.banner.Visible = true
	if seconds <= LobbyConfig.BigCountdownFrom then
		local hot = seconds <= LobbyConfig.AlarmFromSeconds
		pop(tostring(seconds), if hot then C.Hot else C.Cream, 1.9)
		playLocal(LobbyConfig.TickSoundId)
		pulse(if hot then C.Hot else C.Cream, if hot then 0.35 else 0.12)
		if hot then
			shake(0.25 + (LobbyConfig.AlarmFromSeconds - seconds) * 0.12, 0.25)
		end
		task.delay(0.8, function()
			if ui.big.Text == tostring(seconds) then
				TweenService:Create(ui.big, TweenInfo.new(0.15), { TextTransparency = 1 }):Play()
			end
		end)
	else
		ui.big.Visible = false
	end
end

local sliding = false
local function slide(top: CFrame, bottom: CFrame, seconds: number)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if sliding or not root then
		return
	end
	sliding = true
	local r = root :: BasePart
	r.Anchored = true
	r.CFrame = top
	playLocal(LobbyConfig.WhooshSoundId)
	local t0 = os.clock()
	local conn: RBXScriptConnection
	conn = RunService.RenderStepped:Connect(function()
		local a = math.clamp((os.clock() - t0) / seconds, 0, 1)
		local eased = a * a -- gravity-ish: slow start, fast finish
		local spin = CFrame.Angles(0, eased * math.pi * 4, 0)
		r.CFrame = CFrame.new(top.Position:Lerp(bottom.Position, eased)) * top.Rotation * spin
		if a >= 1 then
			conn:Disconnect()
			r.Anchored = false
			r.AssemblyLinearVelocity = Vector3.zero
			sliding = false
			shake(0.5, 0.25)
			pulse(C.Cream, 0.15)
		end
	end)
end

------------------------------------------------------------------ wiring

local function hookBoard(board: Instance)
	local click = board:FindFirstChildOfClass("ClickDetector") or board:WaitForChild("BoardClick", 5)
	if click and click:IsA("ClickDetector") then
		click.MouseClick:Connect(function(who: Player)
			if who == player then
				openPicker()
			end
		end)
	end
end

function LobbyController:Init(all: { [string]: any })
	controllers = all
end

function LobbyController:Start()
	for _, m in MissionCatalog do
		byId[m.id] = m
	end
	buildUi()
	task.spawn(function()
		-- the hotbar's size follows the viewport (UIScale); re-place the strip when it changes
		local pg = player:WaitForChild("PlayerGui")
		local inv = pg:WaitForChild("InventoryHud", 30)
		local bar = inv and inv:WaitForChild("Hotbar", 10)
		if bar and bar:IsA("GuiObject") then
			bar:GetPropertyChangedSignal("AbsoluteSize"):Connect(placeStrip)
			bar:GetPropertyChangedSignal("Visible"):Connect(placeStrip)
		end
		placeStrip()
	end)

	local Board = Net.event("Lobby", "Board")
	local Launch = Net.event("Lobby", "Launch")
	local Countdown = Net.event("Lobby", "Countdown")
	local Fx = Net.event("Lobby", "Fx")

	Board.OnClientEvent:Connect(function(squads: any)
		mySquad = nil
		if type(squads) == "table" then
			for _, s in squads do
				if type(s) == "table" and type(s.members) == "table" and table.find(s.members, player.UserId) and not s.instanceId then
					mySquad = s
					break
				end
			end
		end
		renderStrip()
		if ui.panel.Visible then
			renderPicker()
		end
	end)
	Countdown.OnClientEvent:Connect(function(padId: any, seconds: any, title: any)
		if type(seconds) ~= "number" then
			return
		end
		onCountdown(tonumber(padId) or 0, seconds, tostring(title or ""))
	end)
	Fx.OnClientEvent:Connect(function(kind: any, a: any, b: any, c: any)
		if kind == "slide" and typeof(a) == "CFrame" and typeof(b) == "CFrame" then
			slide(a, b, tonumber(c) or LobbyConfig.PoleSlideSeconds)
		elseif kind == "welcome" then
			showToast(tostring(a or LobbyConfig.WelcomeText), 4)
			pulse(C.Yellow, 0.25)
			ui.fade.BackgroundTransparency = 0
			TweenService:Create(ui.fade, TweenInfo.new(0.8), { BackgroundTransparency = 1 }):Play()
		elseif kind == "toast" then
			showToast(tostring(a or ""), 3)
		end
	end)
	ui.go.Activated:Connect(function()
		Launch:FireServer()
	end)

	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		-- the board, or "Change call" on a queue pad, opens the mission picker
		if who == player and prompt.Parent and (prompt.Parent:HasTag(Names.Tag.MissionBoard) or prompt.Name == "PadPrompt") then
			openPicker()
		end
	end)
	for _, b in CollectionService:GetTagged(Names.Tag.MissionBoard) do
		task.spawn(hookBoard, b)
	end
	CollectionService:GetInstanceAddedSignal(Names.Tag.MissionBoard):Connect(function(b)
		task.spawn(hookBoard, b)
	end)

	player:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		if inMission() then
			ui.panel.Visible = false
			ui.banner.Visible = false
		end
		renderStrip()
	end)
end

return LobbyController
