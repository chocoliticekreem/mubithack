--!strict
-- OnboardingController [owner: Onboarding]. The first minute: title card, a 3-step station tutorial
-- with world arrows + highlights, contextual dispatch hints, a Help (H) panel, and a calmer lobby HUD.
-- Copy + tuning: Config/OnboardingConfig. Step logic: Lib/Onboarding/OnboardingFlow (spec-tested).
--   * Title card ("FLAME AND BLAME / Station 67") on the first spawn of the session; short for returning
--     players (Player attr Onboarded = true, written by OnboardingService from the DataService profile).
--   * Tutorial (first join only, or replayed from Help): GRAB YOUR GEAR (your numbered GearRack, done
--     on its prompt or once InvHand is set) -> CHECK THE MISSION BOARD (prompt / picker / look at it up close)
--     -> STEP ON A GLOWING PAD (SquadId ~= "") -> ROLLING OUT (countdown). Launch = done
--     (Onboarding/Done -> settings.onboarded). Each step: a card at the top centre, a bouncing arrow
--     and a Highlight on the target, and an edge arrow when it's off screen.
--   * Dispatch hints (everyone, every mission): RUN TO BAY n / open YOUR truck's door -> HOP IN ->
--     FOLLOW THE GPS (shown a few seconds), arrow on the door handle / driver seat of your truck.
--   * Lobby declutter: the graphics button and emote hint only show with Help open (H).
-- Public: OnboardingController:Replay(), :IsActive(): boolean
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigDir:WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local VehicleConfig = require(ConfigDir:WaitForChild("VehicleConfig") :: ModuleScript) :: any
local Flow = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("OnboardingFlow") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local OnboardingController = {}
OnboardingController.Priority = 120

local player = Players.LocalPlayer
local Tag = Names.Tag :: any
local Attr = Names.Attr :: any
local GEAR_RACK_TAG: string = Tag.GearRack or "GearRack"
local PAD_TAG: string = Tag.SquadPad or "SquadPad"
local BOARD_TAG: string = Tag.MissionBoard or "MissionBoard"
local TRUCK_TAG: string = Tag.Truck or "Truck"
local HELP_OPEN_ATTR = "HelpOpen" -- local-only Player attr other controllers may read (SquadController emote hint)

local INK = Palette.UiInk
local CREAM = Palette.UiCream
local WARN = Palette.UiWarn
local RED = Palette.UiRed

type Guide = { kind: string, part: BasePart?, model: Instance?, head: string, sub: string, chip: string }

local state = {
	flow = Flow.new(),
	tutorial = false, -- tutorial running
	boardSeen = false,
	gearGrabbed = false,
	baseBack = "" :: any, -- InvBack when the tutorial started (a default tank doesn't count as "grabbed")
	lookTime = 0,
	titleShown = false,
	guideKey = "", -- what the card/arrow currently show
	driveHintUntil = 0,
	missionSince = 0, -- os.clock() when InstanceId was set (the HUD's ALARM banner owns the screen first)
	helpOpen = false,
}

local ui: { [string]: any } = {}

------------------------------------------------------------------------------------------ helpers

local function inMission(): boolean
	local id = player:GetAttribute(Attr.InstanceId)
	return type(id) == "string" and id ~= ""
end

local function helmet(): number
	return tonumber(player:GetAttribute(Attr.Helmet)) or 1
end

local function root(): BasePart?
	local c = player.Character
	local r = c and c:FindFirstChild("HumanoidRootPart")
	return if r and r:IsA("BasePart") then r else nil
end

local function fill(text: string, vars: { [string]: any }): string
	return (string.gsub(text, "{(%w+)}", function(k: string)
		local v = vars[k]
		return if v ~= nil then tostring(v) else "{" .. k .. "}"
	end))
end

local function firstPart(inst: Instance?): BasePart?
	if not inst then
		return nil
	end
	if inst:IsA("BasePart") then
		return inst
	end
	if inst:IsA("Model") and inst.PrimaryPart then
		return inst.PrimaryPart
	end
	return inst:FindFirstChildWhichIsA("BasePart", true)
end

local function myRack(): BasePart?
	local want = helmet()
	local any: BasePart? = nil
	for _, r in CollectionService:GetTagged(GEAR_RACK_TAG) do
		if r:IsA("BasePart") and r:IsDescendantOf(workspace) then
			local slot = r:GetAttribute(Attr.Slot or "Slot") or r:GetAttribute(Attr.Helmet)
			if slot == want then
				return r
			end
			any = any or r
		end
	end
	return any
end

local function board(): BasePart?
	for _, b in CollectionService:GetTagged(BOARD_TAG) do
		if b:IsDescendantOf(workspace) then
			local p = firstPart(b)
			if p then
				return p
			end
		end
	end
	return nil
end

local function nearestPad(): BasePart?
	local r = root()
	local best, bestD = nil :: BasePart?, math.huge
	for _, p in CollectionService:GetTagged(PAD_TAG) do
		local part = firstPart(p)
		if part and part:IsDescendantOf(workspace) then
			local d = if r then (part.Position - r.Position).Magnitude else 0
			if d < bestD then
				best, bestD = part, d
			end
		end
	end
	return best
end

local function myTruck(): Model?
	for _, t in CollectionService:GetTagged(TRUCK_TAG) do
		if t:IsA("Model") and t:GetAttribute("OwnerUserId") == player.UserId and t:IsDescendantOf(workspace) then
			return t
		end
	end
	return nil
end

local function driverSeat(truck: Model): BasePart?
	local seat = truck:FindFirstChildWhichIsA("VehicleSeat", true)
	return seat
end

local function runState(): string?
	local id = player:GetAttribute(Attr.InstanceId)
	if type(id) ~= "string" or id == "" then
		return nil
	end
	local runs = workspace:FindFirstChild("Runs")
	local run = runs and runs:FindFirstChild(id)
	if not run then
		return nil -- v1.5 instance: no truck run, no dispatch hints
	end
	local st = run:GetAttribute("RoundState")
	return if type(st) == "string" then st else nil
end

local function stroke(parent: Instance, thickness: number, color: Color3?)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = color or INK
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
	return s
end

local function corner(parent: Instance, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
end

local function text(parent: Instance, name: string, str: string, font: Enum.Font, color: Color3, size: UDim2, pos: UDim2): TextLabel
	local t = Instance.new("TextLabel")
	t.Name = name
	t.BackgroundTransparency = 1
	t.Text = str
	t.Font = font
	t.TextColor3 = color
	t.TextScaled = true
	t.Size = size
	t.Position = pos
	t.Parent = parent
	return t
end

------------------------------------------------------------------------------------------ build

local function buildTitle()
	local gui = UiKit.screen("OnboardingTitle", 60, true)
	gui.Enabled = false
	local bg = Instance.new("Frame")
	bg.Name = "Bg"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromHex("#140C0A")
	bg.BorderSizePixel = 0
	bg.Parent = gui
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Color3.fromHex("#3A1410"), Color3.fromHex("#0E0806"))
	grad.Parent = bg
	local holder = Instance.new("Frame")
	holder.Name = "Holder"
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.fromScale(0.5, 0.46)
	holder.Size = UDim2.fromOffset(820, 300)
	holder.BackgroundTransparency = 1
	holder.Parent = gui
	local scale = Instance.new("UIScale")
	scale.Parent = holder
	local title = text(holder, "Title", Cfg.Title, Enum.Font.LuckiestGuy, Palette.UiFlameTop, UDim2.new(1, 0, 0, 130), UDim2.fromOffset(0, 0))
	local tg = Instance.new("UIGradient")
	tg.Rotation = 90
	tg.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.UiFlameTop),
		ColorSequenceKeypoint.new(0.55, Palette.UiFlameMid),
		ColorSequenceKeypoint.new(1, Palette.UiFlameLow),
	})
	tg.Parent = title
	title.TextColor3 = Color3.new(1, 1, 1)
	stroke(title, 6)
	title.Rotation = -2
	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0.5, 0)
	badge.Position = UDim2.new(0.5, 0, 0, 140)
	badge.Size = UDim2.fromOffset(330, 56)
	badge.BackgroundColor3 = RED
	badge.Parent = holder
	corner(badge, 12)
	stroke(badge, 4)
	local sub = text(badge, "Sub", string.upper(Cfg.Subtitle), Enum.Font.LuckiestGuy, CREAM, UDim2.new(1, -24, 1, -12), UDim2.fromOffset(12, 6))
	stroke(sub, 2)
	local tag = text(holder, "Tag", Cfg.Tagline, Enum.Font.FredokaOne, CREAM, UDim2.new(1, 0, 0, 34), UDim2.fromOffset(0, 214))
	stroke(tag, 2)
	ui.title = { gui = gui, bg = bg, holder = holder, scale = scale, labels = { title, sub, tag }, badge = badge }
end

local function buildHud()
	local gui = UiKit.screen("Onboarding", 25)
	ui.gui = gui

	-- objective card (top centre)
	local card = Instance.new("Frame")
	card.Name = "Card"
	card.AnchorPoint = Vector2.new(0.5, 0)
	card.Position = UDim2.new(0.5, 0, 0, 10)
	card.Size = UDim2.fromOffset(520, 78)
	card.BackgroundColor3 = Palette.UiPanelDark
	card.BackgroundTransparency = 0.08
	card.Visible = false
	card.Parent = gui
	corner(card, 14)
	stroke(card, 3, WARN)
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.Position = UDim2.fromOffset(10, 10)
	chip.Size = UDim2.fromOffset(96, 58)
	chip.BackgroundColor3 = WARN
	chip.Parent = card
	corner(chip, 10)
	local chipText = text(chip, "T", "1/3", Enum.Font.LuckiestGuy, INK, UDim2.new(1, -12, 1, -14), UDim2.fromOffset(6, 7))
	local head = text(card, "Head", "", Enum.Font.LuckiestGuy, CREAM, UDim2.new(1, -132, 0, 34), UDim2.fromOffset(118, 8))
	head.TextXAlignment = Enum.TextXAlignment.Left
	stroke(head, 2)
	local sub = text(card, "Sub", "", Enum.Font.FredokaOne, CREAM, UDim2.new(1, -132, 0, 24), UDim2.fromOffset(118, 44))
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.TextTransparency = 0.1
	local scale = Instance.new("UIScale")
	scale.Parent = card
	ui.card, ui.chip, ui.chipText, ui.head, ui.sub, ui.cardScale = card, chip, chipText, head, sub, scale

	-- edge arrow (target off screen): its own full-bleed, unscaled gui so positions are viewport pixels.
	-- A yellow "!" badge with a pointer that orbits it toward the target.
	local edgeGui = Instance.new("ScreenGui")
	edgeGui.Name = "OnboardingEdge"
	edgeGui.IgnoreGuiInset = true
	edgeGui.ResetOnSpawn = false
	edgeGui.DisplayOrder = 26
	edgeGui.Parent = player:WaitForChild("PlayerGui")
	local edge = Instance.new("Frame")
	edge.Name = "EdgeArrow"
	edge.AnchorPoint = Vector2.new(0.5, 0.5)
	edge.Size = UDim2.fromOffset(52, 52)
	edge.BackgroundColor3 = WARN
	edge.Visible = false
	edge.Parent = edgeGui
	corner(edge, 26)
	stroke(edge, 3)
	local pointer = Instance.new("Frame")
	pointer.Name = "Pointer"
	pointer.AnchorPoint = Vector2.new(0.5, 0.5)
	pointer.Size = UDim2.fromOffset(22, 22)
	pointer.Rotation = 45
	pointer.BackgroundColor3 = WARN
	pointer.BorderSizePixel = 0
	pointer.ZIndex = 0
	pointer.Parent = edge
	stroke(pointer, 3)
	local bang = text(edge, "Bang", "!", Enum.Font.LuckiestGuy, INK, UDim2.new(1, -14, 1, -14), UDim2.fromOffset(7, 9))
	bang.ZIndex = 2
	ui.pointer = pointer
	ui.edge = edge

	-- help chip (bottom left)
	local help = Instance.new("TextButton")
	help.Name = "HelpChip"
	help.AnchorPoint = Vector2.new(0, 1)
	help.Position = UDim2.new(0, 16, 1, -16)
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		-- phones: the bottom-left corner is the touch thumbstick; sit on the left edge above it instead
		help.AnchorPoint = Vector2.new(0, 0.5)
		help.Position = UDim2.new(0, 16, 0.4, 0)
		help.Text = "HELP"
	end
	help.Size = UDim2.fromOffset(118, 36)
	help.BackgroundColor3 = Palette.UiPanelDark
	help.BackgroundTransparency = 0.15
	help.Font = Enum.Font.LuckiestGuy
	help.TextColor3 = CREAM
	help.TextSize = 20
	help.Text = `[{Cfg.HelpKey}]  HELP`
	help.AutoButtonColor = true
	help.Parent = gui
	corner(help, 10)
	stroke(help, 2)
	ui.helpChip = help

	-- help panel
	local panel = Instance.new("Frame")
	panel.Name = "Help"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.52)
	panel.Size = UDim2.fromOffset(560, 430)
	panel.BackgroundColor3 = Palette.UiPanelDark
	panel.Visible = false
	panel.ZIndex = 5
	panel.Parent = gui
	corner(panel, 16)
	stroke(panel, 4, WARN)
	local ph = text(panel, "Head", "HOW TO FIREFIGHT (BADLY)", Enum.Font.LuckiestGuy, WARN, UDim2.new(1, -32, 0, 40), UDim2.fromOffset(16, 12))
	ph.ZIndex = 6
	stroke(ph, 2)
	local lines = {
		"STATION: grab gear at your rack (E), pick a call at the Mission Board, hop on a glowing pad.",
		"ON FOOT:  WASD move  -  E grab / use  -  G drop  -  hold Q throw  -  M map  -  V camera",
		`TRUCK:  E door  -  {VehicleConfig.KeyEnter or "F"} get in / out  -  {VehicleConfig.KeySiren or "G"} siren  -  {VehicleConfig.KeyHorn or "H"} horn  -  SPACE drift  -  {VehicleConfig.KeyRespawn or "R"} unflip`,
		"FIRE: spray the base of the flames, carry people + pets to the truck, then blame someone.",
		"EMOTES (station):  Z wave  -  X facepalm  -  C blame!   -   1 / 2 swap hand + back",
		"SETTINGS: graphics + pop-ups buttons are top left while this panel is open.",
	}
	for i, l in lines do
		local t = text(panel, `L{i}`, l, Enum.Font.FredokaOne, CREAM, UDim2.new(1, -40, 0, 44), UDim2.fromOffset(20, 60 + (i - 1) * 50))
		t.TextXAlignment = Enum.TextXAlignment.Left
		t.TextWrapped = true
		t.ZIndex = 6
	end
	local function btn(name: string, label: string, x: number, color: Color3): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.AnchorPoint = Vector2.new(0.5, 1)
		b.Position = UDim2.new(0.5, x, 1, -16)
		b.Size = UDim2.fromOffset(220, 50)
		b.BackgroundColor3 = color
		b.Font = Enum.Font.LuckiestGuy
		b.TextColor3 = CREAM
		b.TextSize = 24
		b.Text = label
		b.ZIndex = 6
		b.Parent = panel
		corner(b, 10)
		stroke(b, 3)
		return b
	end
	ui.replay = btn("Replay", "REPLAY TUTORIAL", -120, RED)
	ui.close = btn("Close", "GOT IT", 120, Color3.fromHex("#3B6E4A"))
	ui.help = panel

	-- world guide: bouncing arrow over the target (+ a Highlight on it)
	local bb = Instance.new("BillboardGui")
	bb.Name = "OnboardingArrow"
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.Size = UDim2.fromOffset(200, 120)
	bb.StudsOffsetWorldSpace = Vector3.new(0, Cfg.ArrowHeight, 0)
	bb.Enabled = false
	bb.ResetOnSpawn = false
	bb.Parent = player:WaitForChild("PlayerGui")
	local inner = Instance.new("Frame")
	inner.Name = "Inner"
	inner.BackgroundTransparency = 1
	inner.Size = UDim2.fromScale(1, 1)
	inner.Parent = bb
	local lbl = text(inner, "Label", "", Enum.Font.LuckiestGuy, WARN, UDim2.new(1, 0, 0, 34), UDim2.fromOffset(0, 0))
	stroke(lbl, 3)
	local shaft = Instance.new("Frame")
	shaft.AnchorPoint = Vector2.new(0.5, 0)
	shaft.Position = UDim2.new(0.5, 0, 0, 40)
	shaft.Size = UDim2.fromOffset(18, 34)
	shaft.BackgroundColor3 = WARN
	shaft.BorderSizePixel = 0
	shaft.Parent = inner
	stroke(shaft, 3)
	local head2 = Instance.new("Frame")
	head2.AnchorPoint = Vector2.new(0.5, 0.5)
	head2.Position = UDim2.new(0.5, 0, 0, 80)
	head2.Size = UDim2.fromOffset(34, 34)
	head2.Rotation = 45
	head2.BackgroundColor3 = WARN
	head2.BorderSizePixel = 0
	head2.Parent = inner
	stroke(head2, 3)
	local hl = Instance.new("Highlight")
	hl.Name = "OnboardingHighlight"
	hl.FillColor = Cfg.HighlightColor
	hl.OutlineColor = Cfg.HighlightColor
	hl.FillTransparency = 0.75
	hl.OutlineTransparency = 0
	hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	hl.Enabled = false
	ui.arrow, ui.arrowInner, ui.arrowLabel, ui.highlight = bb, inner, lbl, hl
end

------------------------------------------------------------------------------------------ title card

local function setLobbyClutter()
	-- the graphics button and the emote hint only with Help open (or on a mission, where their
	-- owners hide them anyway)
	local pg = player:FindFirstChild("PlayerGui")
	if not pg then
		return
	end
	for _, name in Cfg.LobbyHiddenGuis do
		local g = pg:FindFirstChild(name)
		if g and g:IsA("ScreenGui") then
			local want = state.helpOpen and not inMission()
			if g.Enabled ~= want then
				g.Enabled = want
			end
		end
	end
end

-- their owners re-enable them (on InstanceId changes, setting changes): put them back right after
local watched = setmetatable({}, { __mode = "k" }) :: { [Instance]: boolean }
local function watchClutter(g: Instance)
	if watched[g] or not g:IsA("ScreenGui") or not table.find(Cfg.LobbyHiddenGuis, g.Name) then
		return
	end
	watched[g] = true
	g:GetPropertyChangedSignal("Enabled"):Connect(function()
		task.defer(setLobbyClutter)
	end)
	task.defer(setLobbyClutter)
end

local function showTitle(returning: boolean)
	local t = ui.title
	if not t then
		return
	end
	local hold = if returning then Cfg.ReturningTitleSeconds else Cfg.TitleSeconds
	t.gui.Enabled = true
	t.bg.BackgroundTransparency = 0
	t.scale.Scale = 0.3
	for _, l in t.labels do
		l.TextTransparency = 0
		local s = l:FindFirstChildOfClass("UIStroke")
		if s then
			s.Transparency = 0
		end
	end
	t.badge.BackgroundTransparency = 0
	TweenService:Create(t.scale, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(hold * 0.35, function()
		TweenService:Create(t.bg, TweenInfo.new(hold * 0.5), { BackgroundTransparency = 0.35 }):Play()
	end)
	task.delay(hold, function()
		local info = TweenInfo.new(Cfg.FadeInSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(t.bg, info, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(t.badge, info, { BackgroundTransparency = 1 }):Play()
		TweenService:Create(t.scale, info, { Scale = 1.15 }):Play()
		for _, l in t.labels do
			TweenService:Create(l, info, { TextTransparency = 1 }):Play()
			local s = l:FindFirstChildOfClass("UIStroke")
			if s then
				TweenService:Create(s, info, { Transparency = 1 }):Play()
			end
		end
		task.delay(Cfg.FadeInSeconds + 0.05, function()
			t.gui.Enabled = false
		end)
	end)
end

------------------------------------------------------------------------------------------ guide

local function currentGuide(): Guide?
	-- mission hints first (everyone, every mission)
	if inMission() then
		if os.clock() - state.missionSince < (Cfg.DispatchHintDelay or 0) then
			return nil
		end
		local st = runState()
		local truck = myTruck()
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local seat = hum and hum.SeatPart
		local seated = seat ~= nil and truck ~= nil and seat:IsDescendantOf(truck)
		local driving = truck ~= nil and truck:GetAttribute("Driver") == player.UserId
		local doorOpen = truck ~= nil and truck:GetAttribute("DoorOpen_L") == true or (truck ~= nil and truck:GetAttribute("DoorGone_L") == true)
		local hint = Flow.missionHint({
			state = st,
			hasTruck = truck ~= nil,
			seated = seated,
			driving = driving,
			doorOpen = doorOpen,
			arrived = false,
		})
		if hint == "drive" then
			if state.driveHintUntil == 0 then
				state.driveHintUntil = os.clock() + Cfg.DriveHintSeconds
			end
			if os.clock() > state.driveHintUntil then
				return nil
			end
		end
		if not hint or not truck then
			return nil
		end
		local h = Cfg.Hints[hint]
		local vars = {
			bay = truck:GetAttribute("Bay") or helmet(),
			siren = VehicleConfig.KeySiren or "G",
			horn = VehicleConfig.KeyHorn or "H",
			enter = VehicleConfig.KeyEnter or "F",
		}
		local part: BasePart? = nil
		if hint == "door" then
			part = firstPart(truck:FindFirstChild("DoorHandle_L", true)) or firstPart(truck:FindFirstChild("Door_L", true))
		elseif hint == "seat" then
			part = driverSeat(truck)
		end
		return {
			kind = hint,
			part = part,
			model = if hint == "drive" then nil else truck,
			head = fill(h.head, vars),
			sub = fill(h.sub, vars),
			chip = if hint == "drive" then "GO!" else "CALL!",
		}
	end
	if not state.tutorial then
		return nil
	end
	local step = Flow.advance(state.flow, {
		gear = state.gearGrabbed
			or (player:GetAttribute("InvHand") or "") ~= ""
			or ((player:GetAttribute("InvBack") or "") ~= "" and player:GetAttribute("InvBack") ~= state.baseBack),
		board = state.boardSeen,
		pad = (player:GetAttribute(Attr.SquadId) or "") ~= "",
		launched = false,
	})
	if not step then
		return nil
	end
	local s = Cfg.Steps[step]
	local vars = { rack = string.format("%02d", helmet()) }
	local part: BasePart?, model: Instance? = nil, nil
	if step == "gear" then
		part = myRack()
		model = part
	elseif step == "board" then
		part = board()
		model = part
	elseif step == "pad" then
		part = nearestPad()
		model = part
	end
	local idx = Flow.indexOf(step)
	return {
		kind = step,
		part = part,
		model = model,
		head = s.head,
		sub = fill(s.sub, vars),
		chip = if idx > 0 then `{idx}/{#Flow.Steps}` else "GO!",
	}
end

local function showCard(g: Guide?)
	local card: Frame = ui.card
	if not g then
		if card.Visible then
			card.Visible = false
		end
		return
	end
	local key = g.kind .. "|" .. g.head .. "|" .. g.sub
	if key ~= state.guideKey then
		state.guideKey = key
		ui.head.Text = g.head
		ui.sub.Text = g.sub
		ui.chipText.Text = g.chip
		card.Visible = true
		card.Position = UDim2.new(0.5, 0, 0, if inMission() then 76 else 10)
		ui.cardScale.Scale = 0.6
		TweenService:Create(ui.cardScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
		UiKit.pop(ui.chip, 0.3)
	end
end

local function placeArrow(g: Guide?, t: number)
	local bb: BillboardGui = ui.arrow
	local hl: Highlight = ui.highlight
	local part = g and g.part
	if not part or not part:IsDescendantOf(workspace) then
		bb.Enabled = false
		hl.Enabled = false
		ui.edge.Visible = false
		return
	end
	local p = part :: BasePart
	if bb.Adornee ~= p then
		bb.Adornee = p
	end
	bb.StudsOffsetWorldSpace = Vector3.new(0, p.Size.Y / 2 + Cfg.ArrowHeight + math.sin(t * 5) * Cfg.ArrowBob, 0)
	ui.arrowLabel.Text = if g then g.head else ""
	bb.Enabled = true
	local model = g and g.model
	if model and model:IsDescendantOf(workspace) then
		if hl.Adornee ~= model then
			hl.Adornee = model
		end
		if hl.Parent ~= workspace.CurrentCamera then
			hl.Parent = workspace.CurrentCamera
		end
		hl.FillTransparency = 0.7 + 0.15 * math.sin(t * 4)
		hl.Enabled = true
	else
		hl.Enabled = false
	end
	-- edge arrow when the target is behind you / off screen
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	local sp, onScreen = cam:WorldToViewportPoint(p.Position)
	if onScreen and sp.Z > 0 then
		ui.edge.Visible = false
		return
	end
	-- off screen: a badge on the left or right edge (lower half, clear of the XP panel and the minimap)
	-- pointing the way to turn
	local rel = cam.CFrame:PointToObjectSpace(p.Position)
	local side = if rel.X >= 0 then 1 else -1
	local x = if side > 0 then vp.X - 60 else 60
	ui.edge.Position = UDim2.fromOffset(x, vp.Y * 0.6)
	ui.pointer.Position = UDim2.fromOffset(26 + side * 30, 26)
	ui.edge.Visible = true
end

------------------------------------------------------------------------------------------ board look

local function pickerOpen(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local lobby = pg and pg:FindFirstChild("LobbyUI")
	local picker = lobby and lobby:FindFirstChild("Picker")
	return picker ~= nil and picker:IsA("GuiObject") and picker.Visible and (lobby :: ScreenGui).Enabled
end

local function updateBoardLook(dt: number)
	if state.boardSeen or not state.tutorial then
		return
	end
	if pickerOpen() then
		state.boardSeen = true
		return
	end
	local b = board()
	local cam = workspace.CurrentCamera
	local r = root()
	if not (b and cam and r) then
		return
	end
	if (b.Position - r.Position).Magnitude > Cfg.BoardLookDistance then
		state.lookTime = 0
		return
	end
	local to = b.Position - cam.CFrame.Position
	if to.Magnitude > 0.1 and cam.CFrame.LookVector:Dot(to.Unit) > Cfg.BoardLookDot then
		state.lookTime += dt
		if state.lookTime >= Cfg.BoardLookSeconds then
			state.boardSeen = true
		end
	else
		state.lookTime = 0
	end
end

------------------------------------------------------------------------------------------ help

local function setHelp(open: boolean)
	state.helpOpen = open
	ui.help.Visible = open
	player:SetAttribute(HELP_OPEN_ATTR, open)
	setLobbyClutter()
	if open then
		UiKit.pop(ui.help, 0.25)
	end
end

local function startTutorial()
	state.flow = Flow.new()
	state.boardSeen = false
	state.gearGrabbed = false
	state.baseBack = player:GetAttribute("InvBack") or ""
	state.lookTime = 0
	state.guideKey = ""
	state.tutorial = true
end

local function finishTutorial()
	if not state.tutorial then
		return
	end
	state.tutorial = false
	state.flow.done = true
	pcall(function()
		Net.event("Onboarding", "Done"):FireServer()
	end)
end

function OnboardingController:Replay()
	setHelp(false)
	if inMission() then
		return
	end
	startTutorial()
end

function OnboardingController:IsActive(): boolean
	return state.tutorial
end

------------------------------------------------------------------------------------------ lifecycle

local function onLobbyReady()
	if state.titleShown or inMission() then
		return
	end
	state.titleShown = true
	-- wait (briefly) for the server to tell us if we're new
	local t0 = os.clock()
	while player:GetAttribute(Cfg.DoneAttr) == nil and os.clock() - t0 < 6 do
		task.wait(0.1)
	end
	local returning = player:GetAttribute(Cfg.DoneAttr) == true
	showTitle(returning)
	if not returning then
		task.delay((Cfg.TitleSeconds or 3) + 0.4, function()
			if not inMission() and not state.flow.done then
				startTutorial()
			end
		end)
	end
end

function OnboardingController:Init(_all: { [string]: any }) end

function OnboardingController:Start()
	if Cfg.Enabled == false then
		return
	end
	buildTitle()
	buildHud()
	player:SetAttribute(HELP_OPEN_ATTR, false)

	ui.helpChip.Activated:Connect(function()
		setHelp(not state.helpOpen)
	end)
	ui.close.Activated:Connect(function()
		setHelp(false)
	end)
	ui.replay.Activated:Connect(function()
		OnboardingController:Replay()
	end)
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode.Name ~= Cfg.HelpKey then
			return
		end
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		if hum and hum.SeatPart then
			return -- H is the horn in a truck
		end
		setHelp(not state.helpOpen)
	end)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, who: Player)
		if who ~= player or not prompt.Parent then
			return
		end
		local p = prompt.Parent :: Instance
		if p:HasTag(BOARD_TAG) or (p.Parent and p.Parent:HasTag(BOARD_TAG)) then
			state.boardSeen = true
		elseif p:HasTag(GEAR_RACK_TAG) or (p.Parent and p.Parent:HasTag(GEAR_RACK_TAG)) then
			state.gearGrabbed = true
		end
	end)
	-- countdown hit 0 (squad launched) = the tutorial worked
	pcall(function()
		Net.event("Lobby", "Countdown").OnClientEvent:Connect(function(_pad: any, seconds: any)
			if seconds == 0 then
				finishTutorial()
			end
		end)
	end)
	player:GetAttributeChangedSignal(Attr.InstanceId):Connect(function()
		state.driveHintUntil = 0
		state.guideKey = ""
		state.missionSince = os.clock()
		if inMission() then
			finishTutorial()
			if state.helpOpen then
				setHelp(false)
			end
		end
		-- ShaderController re-enables its button on this change: re-apply after it
		task.defer(setLobbyClutter)
	end)
	local pg = player:WaitForChild("PlayerGui")
	pg.ChildAdded:Connect(watchClutter)
	for _, c in pg:GetChildren() do
		watchClutter(c)
	end
	setLobbyClutter()

	if player.Character then
		task.spawn(onLobbyReady)
	else
		player.CharacterAdded:Once(function()
			task.wait(0.2)
			onLobbyReady()
		end)
	end

	local t = 0
	RunService.RenderStepped:Connect(function(dt: number)
		t += dt
		updateBoardLook(dt)
		-- nothing over the title card, the Help panel or the mission picker
		local busy = (ui.title and ui.title.gui.Enabled) or state.helpOpen or pickerOpen()
		local g = if busy then nil else currentGuide()
		showCard(g)
		placeArrow(g, t)
		ui.helpChip.Visible = not inMission() and not state.helpOpen
	end)
end

return OnboardingController
