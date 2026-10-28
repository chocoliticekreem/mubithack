--!strict
-- OnboardingController [owner: Onboarding]. The first minute: title card, a 3-step station tutorial
-- with world arrows + highlights, contextual dispatch hints, a Help (H) panel, and a calmer lobby HUD.
-- Copy + tuning: Config/OnboardingConfig. Step logic: Lib/Onboarding/OnboardingFlow (spec-tested).
--   * Title card ("FLAME AND BLAME / Station 67") on the first spawn of the session; short for returning
--     players (Player attr Onboarded = true, written by OnboardingService from the DataService profile).
--   * Tutorial (first join only, or replayed from Help): GRAB YOUR GEAR (the big red StationLocker, done
--     on its prompt or once InvHand is set) -> CHECK THE MISSION BOARD (prompt / picker / look at it up close)
--     -> STEP ON A GLOWING PAD (SquadId ~= "") -> ROLLING OUT (countdown). Launch = done
--     (Onboarding/Done -> settings.onboarded). Each step: a card at the top centre, a bouncing arrow
--     and a Highlight on the target, and an edge arrow when it's off screen.
--   * Dispatch hints (everyone, every mission): the squad starts IN its truck (LobbyService boards it), so
--     HIT THE SIREN! FOLLOW THE GPS (driver) / YOU'RE IN THE TRUCK! (riders), a few seconds each; got out on
--     the way: HOP BACK IN with the arrow on the truck you were riding.
--   * Lobby declutter: the graphics button and emote hint only show with Help open (H).
--   * Help (H): a scrollable cheat sheet (attr Menu, so the mouse frees in first person): the 3 slots
--     drawn like the hotbar, grab / swap / drop / throw, carry + rescue, water, ladders, truck. Keys
--     come from InventoryConfig / GearConfig / VehicleConfig / MissionGuides.
--   * First fire, Onboarding v3 (brand-new players, Services/FirstFireService + Config/FirstFireConfig): the
--     cold open (Controllers/ColdOpenController) plays first and nothing of ours shows over it (no STATION 67
--     title for a newbie: the cutscene is the title). Then one mechanic at a time: FirstFire "burning" =
--     SPRAY THE FIRE! + arrow on the panda house (the camera turns to face it once the cutscene is over);
--     "panda" = NOW SAVE THE PANDA! (arrow + highlight on the panda), then CARRY IT OUTSIDE! (arrow on the
--     lawn) while you hold it; "done" = PANDA SAVED! +XP until the auto-queued first call lands.
--     On the pad for the auto-queued first call: YOUR FIRST CALL card with GO NOW (Lobby/Launch) and
--     NOT YET (Onboarding/SkipCall: off the pad, the board -> pad tutorial at your own pace).
--   * After the first call, still out at the scene (dispatch doesn't teleport you home): GREAT JOB card
--     with BACK TO STATION (Lobby/BackToStation) and an arrow home, for this session's newbies.
--   * SKIP TUTORIAL under every tutorial card (Onboarding/Skip -> settings.onboarded).
--   * Handshake: Onboarding/Ready once every controller has started (their OnClientEvent handlers are
--     connected); the server holds the training fire until then. Onboarding/Seen("firecard") when the
--     PUT OUT THE FIRE card is actually on screen (the "Saw Fire Card" funnel step).
-- Public: OnboardingController:Replay(), :IsActive(): boolean
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigDir = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigDir:WaitForChild("OnboardingConfig") :: ModuleScript) :: any
local VehicleConfig = require(ConfigDir:WaitForChild("VehicleConfig") :: ModuleScript) :: any
local InventoryConfig = require(ConfigDir:WaitForChild("InventoryConfig") :: ModuleScript) :: any
local GearConfig = require(ConfigDir:WaitForChild("GearConfig") :: ModuleScript) :: any
local MissionGuideKey: string = (require(ConfigDir:WaitForChild("MissionGuides") :: ModuleScript) :: any).SkipKey or "J"
local Flow = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("OnboardingFlow") :: ModuleScript)
local FirstFire = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("FirstFire") :: ModuleScript)
local FireCfg = require(ConfigDir:WaitForChild("FirstFireConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local Calm = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("Calm") :: ModuleScript)
local HudGate = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudGate") :: ModuleScript)
local Funnel = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Onboarding"):WaitForChild("Funnel") :: ModuleScript)
local GuiService = game:GetService("GuiService")

local OnboardingController = {}
OnboardingController.Priority = 120

local player = Players.LocalPlayer
local Tag = Names.Tag :: any
local Attr = Names.Attr :: any
local LOCKER_TAG: string = GearConfig.LockerTag or "StationLocker"
local PAD_TAG: string = Tag.SquadPad or "SquadPad"
local BOARD_TAG: string = Tag.MissionBoard or "MissionBoard"
local TRUCK_TAG: string = Tag.Truck or "Truck"
local HELP_OPEN_ATTR = "HelpOpen" -- local-only Player attr other controllers may read (SquadController emote hint)

local INK = Palette.UiInk
local CREAM = Palette.UiCream
local WARN = Palette.UiWarn
local RED = Palette.UiRed

type Guide = { kind: string, part: BasePart?, model: Instance?, head: string, sub: string, chip: string, subTouch: string?, subPad: string? }

-- cards that belong to the tutorial (SKIP TUTORIAL shows under them)
local SKIPPABLE = { firstfire = true, firstpanda = true, firstcarry = true, firstfiredone = true, gear = true, board = true, pad = true, wait = true }

local controllers: { [string]: any } = {}

-- the cold open is on screen (Controllers/ColdOpenController): nothing of ours over it
local function coldOpenPlaying(): boolean
	local co = controllers.ColdOpenController
	if co and type(co.IsPlaying) == "function" then
		local ok, on = pcall(co.IsPlaying, co)
		return ok and on == true
	end
	return false
end

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
	rideTruck = nil :: Model?, -- the truck you last sat in this call (HOP BACK IN points at it)
	helpOpen = false,
	callTitle = "", -- Lobby/Countdown title of the pad you're on
	callEndsAt = 0, -- os.clock() when that countdown hits 0 (0 = no countdown)
	seenFireCard = false,
	wasOnCall = false, -- had an InstanceId this session
	missionEnded = false, -- ...and it's over (InstanceId back to "")
	staleKey = "", -- the lobby tutorial step on the card, and since when (os.clock): a stale step hides
	staleSince = 0,
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

-- the one big shared LOCKER in the station (GearService / GearController's menu)
local function theLocker(): BasePart?
	for _, r in CollectionService:GetTagged(LOCKER_TAG) do
		if r:IsA("BasePart") and r:IsDescendantOf(workspace) then
			return r
		end
	end
	return nil
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

------------------------------------------------------------------------------------------ help panel

local function keyName(k: any, fallback: string): string
	if typeof(k) == "EnumItem" then
		return k.Name
	end
	return if type(k) == "string" and k ~= "" then k else fallback
end

-- one keycap chip ("E", "hold Q", "CLICK")
local function keycap(parent: Instance, label: string, order: number)
	local cap = Instance.new("Frame")
	cap.Name = "Key"
	cap.LayoutOrder = order
	cap.AutomaticSize = Enum.AutomaticSize.X
	cap.Size = UDim2.fromOffset(30, 28)
	cap.BackgroundColor3 = CREAM
	cap.ZIndex = 7
	cap.Parent = parent
	corner(cap, 6)
	stroke(cap, 2)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 7)
	pad.PaddingRight = UDim.new(0, 7)
	pad.Parent = cap
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.AutomaticSize = Enum.AutomaticSize.X
	t.Size = UDim2.fromOffset(0, 28)
	t.Font = Enum.Font.LuckiestGuy
	t.TextSize = 17
	t.TextColor3 = INK
	t.Text = label
	t.ZIndex = 8
	t.Parent = cap
	return cap, t
end

local function helpRow(list: Instance, order: number, keys: { string }, body: string, ctx: any?, touchBody: string?)
	local row = Instance.new("Frame")
	row.Name = `Row{order}`
	row.LayoutOrder = order
	row.BackgroundTransparency = 1
	row.AutomaticSize = Enum.AutomaticSize.Y
	row.Size = UDim2.new(1, 0, 0, 30)
	row.ZIndex = 6
	row.Parent = list
	local caps = Instance.new("Frame")
	caps.Name = "Keys"
	caps.BackgroundTransparency = 1
	caps.Size = UDim2.fromOffset(150, 30)
	caps.ZIndex = 6
	caps.Parent = row
	local cl = Instance.new("UIListLayout")
	cl.FillDirection = Enum.FillDirection.Horizontal
	cl.HorizontalAlignment = Enum.HorizontalAlignment.Right
	cl.Padding = UDim.new(0, 4)
	cl.SortOrder = Enum.SortOrder.LayoutOrder
	cl.Parent = caps
	local made = {}
	for i, k in keys do
		local cap, label = keycap(caps, k, i)
		table.insert(made, { cap = cap, label = label, key = k })
	end
	local t = Instance.new("TextLabel")
	t.Name = "Text"
	t.BackgroundTransparency = 1
	t.Position = UDim2.fromOffset(162, 3)
	t.Size = UDim2.new(1, -166, 0, 24)
	t.AutomaticSize = Enum.AutomaticSize.Y
	t.Font = Enum.Font.FredokaOne
	t.TextSize = 18
	t.TextColor3 = CREAM
	t.TextWrapped = true
	t.TextXAlignment = Enum.TextXAlignment.Left
	t.TextYAlignment = Enum.TextYAlignment.Top
	if touchBody then
		InputHints.setPick(t, body, touchBody)
	else
		InputHints.set(t, body, ctx)
	end
	t.ZIndex = 7
	t.Parent = row
	-- keycaps per input: "E" -> TAP on a phone; rows with no way to do it on this input hide
	InputHints.watch(row, function()
		local any, last = false, nil
		for _, m in made do
			local l = InputHints.key(m.key, ctx)
			local show = l ~= nil and l ~= last
			m.cap.Visible = show
			m.label.Text = l or m.key
			any = any or show
			last = l or last
		end
		row.Visible = any or #made == 0
	end)
end

local function helpHeader(list: Instance, order: number, title: string)
	local h = Instance.new("TextLabel")
	h.Name = `H{order}`
	h.LayoutOrder = order
	h.BackgroundTransparency = 1
	h.Size = UDim2.new(1, 0, 0, 34)
	h.Font = Enum.Font.LuckiestGuy
	h.TextSize = 24
	h.TextColor3 = WARN
	h.TextXAlignment = Enum.TextXAlignment.Left
	h.TextYAlignment = Enum.TextYAlignment.Bottom
	h.Text = title
	h.ZIndex = 7
	h.Parent = list
	stroke(h, 2)
end

-- the hotbar, drawn small: three tiles (same labels as InventoryController) with what each is for
local function slotPicture(list: Instance, order: number)
	local holder = Instance.new("Frame")
	holder.Name = "Slots"
	holder.LayoutOrder = order
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.new(1, 0, 0, 150)
	holder.ZIndex = 6
	holder.Parent = list
	local hl = Instance.new("UIListLayout")
	hl.FillDirection = Enum.FillDirection.Horizontal
	hl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	hl.Padding = UDim.new(0, 12)
	hl.SortOrder = Enum.SortOrder.LayoutOrder
	hl.Parent = holder
	local tiles = {
		{ "HAND", "AXE", "What you hold. CLICK to use it: spray, chop, stand a ladder." },
		{ "1/2 SWAP", "TANK", "Your back. Press 1 or 2 to swap it with your hand." },
		{ "CARRY", "CAT", "Both arms: a person, a pet or a prop. Press G to put it down." },
	}
	for i, d in tiles do
		local col = Instance.new("Frame")
		col.Name = d[1]
		col.LayoutOrder = i
		col.BackgroundTransparency = 1
		col.Size = UDim2.fromOffset(170, 150)
		col.ZIndex = 6
		col.Parent = holder
		local tag = Instance.new("TextLabel")
		tag.BackgroundColor3 = WARN
		tag.Position = UDim2.fromOffset(45, 0)
		tag.Size = UDim2.fromOffset(80, 20)
		tag.Font = Enum.Font.LuckiestGuy
		tag.TextSize = 14
		tag.TextColor3 = INK
		InputHints.setPick(tag, d[1], (string.gsub(d[1], "^1/2 ", "")))
		tag.ZIndex = 8
		tag.Parent = col
		corner(tag, 6)
		local tile = Instance.new("Frame")
		tile.Position = UDim2.fromOffset(53, 12)
		tile.Size = UDim2.fromOffset(64, 56)
		tile.BackgroundColor3 = Color3.fromHex("#5A3B2E")
		tile.ZIndex = 7
		tile.Parent = col
		corner(tile, 10)
		stroke(tile, 3)
		local glyph = Instance.new("TextLabel")
		glyph.BackgroundTransparency = 1
		glyph.Size = UDim2.fromScale(1, 1)
		glyph.Font = Enum.Font.LuckiestGuy
		glyph.TextSize = 18
		glyph.TextColor3 = CREAM
		glyph.Text = d[2]
		glyph.ZIndex = 8
		glyph.Parent = tile
		local cap = Instance.new("TextLabel")
		cap.BackgroundTransparency = 1
		cap.Position = UDim2.fromOffset(0, 74)
		cap.Size = UDim2.new(1, 0, 0, 72)
		cap.Font = Enum.Font.FredokaOne
		cap.TextSize = 16
		cap.TextWrapped = true
		cap.TextYAlignment = Enum.TextYAlignment.Top
		cap.TextColor3 = CREAM
		InputHints.set(cap, d[3])
		cap.ZIndex = 7
		cap.Parent = col
	end
end

local function buildHelp(gui: ScreenGui): Frame
	local panel = Instance.new("Frame")
	panel.Name = "Help"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.52)
	panel.Size = UDim2.fromOffset(660, 520)
	panel.BackgroundColor3 = Palette.UiPanelDark
	panel.Visible = false
	panel.ZIndex = 5
	panel:SetAttribute("Menu", true) -- MenuMouseController frees the mouse in first person
	panel.Parent = gui
	corner(panel, 16)
	stroke(panel, 4, WARN)
	local ph = text(panel, "Head", "HOW TO FIREFIGHT (BADLY)", Enum.Font.LuckiestGuy, WARN, UDim2.new(1, -32, 0, 40), UDim2.fromOffset(16, 10))
	ph.ZIndex = 6
	stroke(ph, 2)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.Position = UDim2.fromOffset(14, 56)
	scroll.Size = UDim2.new(1, -28, 1, -136)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 8
	scroll.ScrollBarImageColor3 = WARN
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ZIndex = 6
	scroll.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 14)
	pad.Parent = scroll
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 6)
	layout.Parent = scroll
	local list = scroll

	local hoseKey = keyName(InventoryConfig.TruckHoseKey, "T")
	local kick = keyName(GearConfig.KickKey, "F")
	local enter = keyName(VehicleConfig.KeyEnter, "F")
	local n = 0
	local function nx(): number
		n += 1
		return n
	end
	helpHeader(list, nx(), "YOUR 3 SLOTS (bottom of the screen)")
	slotPicture(list, nx())
	helpHeader(list, nx(), "GRAB STUFF")
	helpRow(list, nx(), { "E" }, "At the big red LOCKER in the station: tap a picture to hold it. Also grabs truck lockers and anything on the ground.")
	helpRow(list, nx(), { "1", "2" }, "Swap your hand and your back (the oxygen tank lives there).")
	helpRow(list, nx(), { "G" }, "Drop what you're holding (carry first, then your hand).")
	helpRow(list, nx(), { "hold Q" }, "Wind up and THROW it. Release to let go. It bonks people.")
	helpHeader(list, nx(), "CARRY & RESCUE")
	helpRow(list, nx(), { "E" }, '"Pick up" a person, a pet or a prop. They ride in your CARRY slot.')
	helpRow(list, nx(), { "WALK" }, "Walk them into the glowing drop zone at the truck: that's a rescue!")
	helpRow(list, nx(), { "G" }, "Put them down. Gently. They remember.")
	helpRow(list, nx(), { "hold Q" }, "YEET them. Landing in the drop zone still counts. Probably.", { Q = { touch = "YEET", pad = "L1" } })
	helpRow(list, nx(), { "E", "E" }, "The panda needs TWO: both of you press E on it, then waddle.")
	helpHeader(list, nx(), "WATER")
	helpRow(list, nx(), { hoseKey }, "Next to ANY side of a truck: grab the hose (again to stow it). It never runs out of water.")
	helpRow(list, nx(), { "CLICK" }, "Spray. Aim at the BASE of the flames, not the top.")
	helpHeader(list, nx(), "LADDERS & WAYS IN")
	helpRow(list, nx(), { "CLICK" }, "Holding the Ladder: face a wall and click to stand it up. Walk into it to climb.")
	helpRow(list, nx(), { "E" }, '"Take Ladder" to pick it back up.')
	helpRow(list, nx(), { kick }, "Kick a locked door (or chop it with the axe). Broken windows: climb through.")
	helpHeader(list, nx(), "TRUCK")
	helpRow(list, nx(), { keyName(VehicleConfig.KeyDoor, "E") }, "Open the door.")
	helpRow(list, nx(), { enter }, "Get in. Driver: W/S drive, A/D steer, SPACE hops out.", nil,
		"Get in. Driver: the stick drives and steers, OUT gets you out.")
	local truckKeys = { G = { touch = "SIREN", pad = "X" }, H = { touch = "HONK", pad = "Y" }, R = { touch = "RESPAWN", pad = "D-PAD RIGHT" }, V = { pad = "R3" } }
	helpRow(list, nx(), { keyName(VehicleConfig.KeySiren, "G"), keyName(VehicleConfig.KeyHorn, "H") }, "Siren and horn.", truckKeys)
	helpRow(list, nx(), { keyName(VehicleConfig.KeyRespawn, "R"), keyName(VehicleConfig.KeyCam, "V") }, "Unflip the truck, switch camera.", truckKeys,
		"Stuck or flipped? RESPAWN TRUCK puts it back on the road.")
	helpHeader(list, nx(), "EVERYWHERE ELSE")
	helpRow(list, nx(), { "M" }, "Big map.", nil, "Big map (the M button on the minimap).")
	helpRow(list, nx(), { "Z", "X", "C" }, "Emotes at the station: wave, facepalm, BLAME!")
	helpRow(list, nx(), { MissionGuideKey }, "Skip a mission guide.")
	-- HIDE UI (Controllers/HideUiController, Config/HudConfig.HideKeys)
	helpRow(list, nx(), { "F1" }, "Hide / show the game's buttons (or the 👁 eye, top left).", { F1 = { touch = "👁", pad = "D-PAD ◄" } },
		"Tap the 👁 eye (top left) to hide / show the game's buttons.")
	helpRow(list, nx(), { "MENU" }, "PASS, NEWS, INVITE, TROPHIES and more live in the MENU button on the left.", { MENU = { touch = "MENU", pad = "D-PAD ◄" } })
	helpRow(list, nx(), { "H" }, "This panel. Graphics + pop-up settings are top left while it's open.")

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
	ui.close:SetAttribute("GamepadDefault", true) -- gamepad: the cursor opens on GOT IT, never on REPLAY
	return panel
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

	-- buttons hanging under the card: GO NOW / NOT YET (first call), SKIP TUTORIAL (any tutorial card).
	-- Big, thumb-sized and away from the screen edges (the touch stick / jump button live there).
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
	local function actionButton(name: string, label: string, color: Color3, order: number, w: number, h: number): TextButton
		local b = Instance.new("TextButton")
		b.Name = name
		b.LayoutOrder = order
		b.Size = UDim2.fromOffset(w, h)
		b.BackgroundColor3 = color
		b.Font = Enum.Font.LuckiestGuy
		b.TextColor3 = CREAM
		b.TextScaled = true
		b.Text = label
		b.AutoButtonColor = true
		b.Visible = false
		b.Parent = actions
		corner(b, 10)
		stroke(b, 3)
		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.PaddingLeft = UDim.new(0, 10)
		pad.PaddingRight = UDim.new(0, 10)
		pad.Parent = b
		return b
	end
	ui.go = actionButton("GoNow", FireCfg.CallGo or "GO NOW!", Color3.fromHex("#3B6E4A"), 1, 170, 44)
	ui.wait = actionButton("NotYet", FireCfg.CallWait or "NOT YET", Palette.UiPanelDark, 2, 150, 44)
	ui.skip = actionButton("Skip", FireCfg.SkipLabel or "SKIP TUTORIAL", Palette.UiPanelDark, 3, 150, 30)
	ui.home = actionButton("Home", FireCfg.AwayButton or "BACK TO STATION", RED, 4, 220, 44)
	ui.skip.BackgroundTransparency = 0.25
	ui.actions = actions
	-- top-centre stack (ClientLib/HudLayout): under the mission timer when there is one
	-- its height includes the button row hanging under it, so toasts / banners stack below the buttons
	HudLayout.add("TopCentre", card, 20, function(): number
		local a = ui.actions
		local any = a and (ui.go.Visible or ui.wait.Visible or ui.skip.Visible or ui.home.Visible)
		return card.Size.Y.Offset + (if any then a.Size.Y.Offset + 8 else 0)
	end)
	HudLayout.reserve(card)

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

	-- help chip: the left chip column (HudLayout stack "Chips": PASS, NEWS, INVITE, HELP, ADMIN), which
	-- keeps clear of a phone's thumbstick and the gamepad D-pad legend in the bottom-left corner
	local help = Instance.new("TextButton")
	help.Name = "HelpChip"
	help.Position = UDim2.new(0, 13, 0.6, 0)
	help.Size = UDim2.fromOffset(118, 40)
	help.BackgroundColor3 = Palette.UiPanelDark
	help.BackgroundTransparency = 0.15
	help.Font = Enum.Font.LuckiestGuy
	help.TextColor3 = CREAM
	help.TextSize = 20
	InputHints.setChip(help, Cfg.HelpKey, "HELP")
	help.AutoButtonColor = true
	help.Parent = gui
	corner(help, 10)
	stroke(help, 2)
	ui.helpChip = help
	HudLayout.reserve(help)
	HudLayout.add("Chips", help, 4)

	-- help panel: a scrollable, skimmable cheat sheet (keys come from the configs, never hard-coded)
	ui.help = buildHelp(gui)

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

------------------------------------------------------------------------------------------ first fire

local function trainingFire(): Model?
	local spot = player:GetAttribute(FireCfg.SpotAttr)
	local folder = workspace:FindFirstChild("TrainingFires")
	local m = folder and type(spot) == "number" and folder:FindFirstChild(`Spot{spot}`)
	return if m and m:IsA("Model") then m else nil
end

local function burningPart(m: Model): BasePart?
	local best: BasePart? = nil
	for _, d in m:GetDescendants() do -- each fuel item sits in its own sub-model (FirstFireService)
		if d:IsA("BasePart") and d:HasTag(Names.Tag.Burning) then
			if not best or d.Position.Y > best.Position.Y then
				best = d
			end
		end
	end
	return best or m.PrimaryPart
end

local function firstFireGuide(): Guide?
	local phase = player:GetAttribute(FireCfg.PhaseAttr)
	if type(phase) ~= "string" then
		return nil
	end
	local doneAt = player:GetAttribute(FireCfg.DoneAtAttr)
	local since = if type(doneAt) == "number" then workspace:GetServerTimeNow() - doneAt else 0
	local card = FirstFire.card(phase, since, FireCfg.CelebrateSeconds or 3)
	if card == "fire" then
		local m = trainingFire()
		local click = "LEFT CLICK" -- InputHints shows "the screen" on a phone, R2 on a gamepad
		return {
			kind = "firstfire",
			part = m and burningPart(m),
			model = m,
			head = FireCfg.FireCard.head,
			sub = fill(FireCfg.FireCard.sub, { click = click }),
			subTouch = FireCfg.FireCard.subTouch,
			subPad = FireCfg.FireCard.subPad,
			chip = "FIRE!",
		}
	elseif card == "panda" then
		local m = trainingFire()
		local id = player:GetAttribute(FireCfg.PandaAttr)
		local r = workspace:FindFirstChild("Rescuables")
		local panda = r and type(id) == "string" and r:FindFirstChild(id)
		local carrying = type(id) == "string" and id ~= "" and player:GetAttribute(Attr.Carrying) == id
		if carrying then
			local safe = m and m:FindFirstChild("SafeSpot")
			return {
				kind = "firstcarry",
				part = if safe and safe:IsA("BasePart") then safe else nil,
				model = nil,
				head = FireCfg.CarryCard.head,
				sub = FireCfg.CarryCard.sub,
				chip = "GO!",
			}
		end
		local pp = panda and (panda :: Instance):IsA("Model") and ((panda :: Model).PrimaryPart or panda:FindFirstChildWhichIsA("BasePart", true))
		return {
			kind = "firstpanda",
			part = if pp and pp:IsA("BasePart") then pp else nil,
			model = panda or nil,
			head = FireCfg.PandaCard.head,
			sub = FireCfg.PandaCard.sub,
			subTouch = FireCfg.PandaCard.subTouch,
			subPad = FireCfg.PandaCard.subPad,
			chip = "PANDA!",
		}
	elseif card == "call" then
		local secs = if state.callEndsAt > 0 then math.max(0, math.ceil(state.callEndsAt - os.clock())) else 0
		local title = if state.callTitle ~= "" then string.upper(state.callTitle) else "A REAL FIRE"
		-- LOCKED IN (LobbyService, last 5 s): no GO NOW / NOT YET any more, just the count
		if player:GetAttribute("PadLocked") == true and FireCfg.LockedCard then
			return {
				kind = "firstcalllocked",
				part = nil,
				model = nil,
				head = fill(FireCfg.LockedCard.head, { secs = if secs > 0 then `{secs}` else "" }),
				sub = FireCfg.LockedCard.sub,
				chip = if secs > 0 then `{secs}` else "GO!",
			}
		end
		return {
			kind = "firstcall",
			part = nil,
			model = nil,
			head = fill(FireCfg.CallCard.head, { title = title }),
			sub = fill(FireCfg.CallCard.sub, { secs = if secs > 0 then `{secs}` else "a moment" }),
			chip = if secs > 0 then `{secs}` else "GO!",
		}
	elseif card == "done" then
		return {
			kind = "firstfiredone",
			part = nil,
			model = nil,
			head = fill(FireCfg.DoneCard.head, { xp = FireCfg.XpReward or 0 }),
			sub = FireCfg.DoneCard.sub,
			chip = "NICE!",
		}
	end
	return nil
end

local shoulderOn = false
local function setShoulder(on: boolean)
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if on then
		shoulderOn = true
		hum.CameraOffset = FireCfg.ShoulderOffset or Vector3.new(2, 2.8, 0)
	elseif shoulderOn then
		shoulderOn = false
		hum.CameraOffset = Vector3.zero
	end
end

-- Turn the camera to the training fire once, as soon as FirstFireService has put you at the door.
local function faceFirstFire()
	-- the cold open owns the camera first; turn to the fire once it hands back
	local w0 = os.clock()
	while coldOpenPlaying() and os.clock() - w0 < 20 do
		task.wait(0.1)
	end
	setShoulder(true)
	local t0 = os.clock()
	while os.clock() - t0 < 6 do
		if player:GetAttribute(FireCfg.PhaseAttr) ~= "burning" then
			return
		end
		local m = trainingFire()
		local r = root()
		local cam = workspace.CurrentCamera
		if m and r and cam and m.PrimaryPart and (m.PrimaryPart.Position - r.Position).Magnitude < 30 then
			local target = m.PrimaryPart.Position + Vector3.new(0, 2, 0)
			local flat = (target - r.Position) * Vector3.new(1, 0, 1)
			if flat.Magnitude > 0.1 then
				local zoom = FireCfg.CameraZoom or 12
				-- straight behind you (the extinguisher sprays along the camera's look), but over your
				-- shoulder: Humanoid.CameraOffset slides the camera sideways so your own body doesn't hide
				-- the fire you're aiming at. Put back once the fire is out (setShoulder(false)).
				local eye = r.Position - flat.Unit * zoom + Vector3.new(0, zoom * 0.5, 0)
				cam.CFrame = CFrame.lookAt(eye, target)
				-- the classic camera keeps its own zoom: force it out for a moment (same trick as
				-- FirstPersonController's lobby step-out), then hand the wheel back
				player.CameraMinZoomDistance = zoom
				task.delay(0.15, function()
					player.CameraMinZoomDistance = 0.5
				end)
			end
			return
		end
		task.wait(0.1)
	end
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
		-- past the "get in your truck" steps: riding in ANY seat (crew seat, a friend's truck), or already
		-- at the scene (within ArrivedStuds of the GPS waypoint), so the card doesn't hang around
		local r = root()
		local wp = player:GetAttribute("WaypointPos")
		local arrived = r ~= nil and typeof(wp) == "Vector3" and (wp - r.Position).Magnitude <= (Cfg.ArrivedStuds or 150)
		if seat ~= nil and not seated then
			seated = true
		end
		-- the truck you're riding (LobbyService boards the whole squad into the leader's): if you hop out
		-- on the way, HOP BACK IN points at THAT truck, not your own parked at the station
		local rideModel = seat and seat:FindFirstAncestorWhichIsA("Model")
		if rideModel and rideModel:HasTag(TRUCK_TAG) then
			state.rideTruck = rideModel
		end
		local hint = Flow.missionHint({
			state = st,
			hasTruck = truck ~= nil,
			seated = seated,
			driving = driving,
			doorOpen = doorOpen,
			arrived = arrived,
		})
		if hint == "drive" or hint == "ride" then
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
		local target: Model = truck
		if hint == "seat" then
			local rt = state.rideTruck
			if rt and rt:IsDescendantOf(workspace) and rt.PrimaryPart then
				target = rt
			end
			part = if target == truck then driverSeat(target) else target.PrimaryPart
		end
		return {
			kind = hint,
			part = part,
			model = if hint == "seat" then target else nil,
			head = fill(h.head, vars),
			sub = fill(h.sub, vars),
			subTouch = h.subTouch and fill(h.subTouch, vars),
			subPad = h.subPad and fill(h.subPad, vars),
			chip = if hint == "seat" then "CALL!" else "GO!",
		}
	end
	-- the first call is over but you're still out at the scene (dispatch calls don't teleport you
	-- home): say what's next and offer the shortcut, instead of a silent truck in a parking lot
	if state.missionEnded and player:GetAttribute(FireCfg.PhaseAttr) ~= nil then
		local b = board()
		local r = root()
		if b and r and (b.Position - r.Position).Magnitude > (FireCfg.AwayStuds or 220) then
			return {
				kind = "away",
				part = b,
				model = nil,
				head = FireCfg.AwayCard.head,
				sub = FireCfg.AwayCard.sub,
				chip = "NEXT",
			}
		end
	end
	local ff = firstFireGuide()
	if ff then
		return ff
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
	local vars: { [string]: string } = {}
	local part: BasePart?, model: Instance? = nil, nil
	if step == "gear" then
		part = theLocker()
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
		subTouch = s.subTouch and fill(s.subTouch, vars),
		chip = if idx > 0 then `{idx}/{#Flow.Steps}` else "GO!",
	}
end

local function remote(name: string): RemoteEvent?
	local ok, r = pcall(Net.event, "Onboarding", name)
	return if ok then r else nil
end

local actionsKey = ""
local function setActions(g: Guide?)
	local kind = g and g.kind or ""
	local call = kind == "firstcall"
	local skip = SKIPPABLE[kind] == true and not inMission()
	local home = kind == "away"
	local key = `{call}{skip}{home}`
	if key == actionsKey then
		return
	end
	actionsKey = key
	ui.go.Visible = false -- the ONE big GO NOW! is LobbyController's (above the squad strip, E / X / tap)
	ui.wait.Visible = call
	ui.skip.Visible = skip
	ui.home.Visible = home
	HudLayout.flush() -- the card's stack height changed (button row on / off)
end

-- the top-centre card must not run into the left column (mission guide card, 14 + 350 design units)
-- on narrow screens (4:3 tablets, a portrait-ish window): shrink it to the room between the columns
-- Phones: UiKit's scale bottoms out at 0.55, so the 24-unit sub line printed at ~9 px. There the card
-- grows instead: the sub line is set at CARD_SUB_PX real pixels (wrapped, as many lines as it needs, up
-- to 3) and SKIP TUTORIAL is at least SKIP_PX real pixels tall.
local CARD_SUB_PX = 15
local SKIP_PX = 46
local lastFit = ""
local function fitCard()
	local gui = ui.gui :: ScreenGui
	local s = math.max(0.01, HudLayout.scaleOf(gui))
	local w = gui.AbsoluteSize.X / s
	local small = Calm.small() or s < 0.75
	local room = if inMission() then w - 2 * (14 + 350 + 10) else w - 40
	local width = math.clamp(math.floor(room), 330, if small then 600 else 520)
	local sub: TextLabel = ui.sub
	local key = `{width}|{s}|{small}|{sub.Text}`
	if key == lastFit then
		return
	end
	lastFit = key
	local height = 78
	if small then
		local size = math.ceil(CARD_SUB_PX / s) -- design units: UIScale brings it back to CARD_SUB_PX
		local textW = width - 132
		local ok, b = pcall(function()
			return TextService:GetTextSize(sub.Text, size, sub.Font, Vector2.new(textW, 10000))
		end)
		local lines = if ok then math.clamp(math.ceil(b.Y / size - 0.2), 1, 3) else 2
		local subH = lines * math.ceil(size * 1.15)
		sub.TextScaled = false
		sub.TextWrapped = true
		sub.TextSize = size
		sub.TextYAlignment = Enum.TextYAlignment.Top
		sub.Size = UDim2.new(1, -132, 0, subH)
		height = math.max(78, 46 + subH + 8)
		local skipH = math.max(30, math.ceil(SKIP_PX / s))
		ui.skip.Size = UDim2.fromOffset(math.max(150, math.ceil(skipH * 2.6)), skipH)
	else
		sub.TextScaled = true
		sub.TextWrapped = false
		sub.TextYAlignment = Enum.TextYAlignment.Center
		sub.Size = UDim2.new(1, -132, 0, 24)
		ui.skip.Size = UDim2.fromOffset(150, 30)
	end
	ui.card.Size = UDim2.fromOffset(width, height)
	local rowH = 44
	for _, b in { ui.go, ui.wait, ui.skip, ui.home } do
		rowH = math.max(rowH, (b :: TextButton).Size.Y.Offset)
	end
	ui.actions.Size = UDim2.new(1, 0, 0, rowH)
	HudLayout.flush()
end

-- Lobby tutorial steps that no longer apply: sitting in a truck (GRAB YOUR GEAR from the driver's seat),
-- the step's target gone, or the same step up for StaleCardSeconds with no progress (the world arrow
-- keeps pointing; the card comes back when the step changes). Calls / missions / the training fire are
-- never hidden here.
local LOBBY_STEPS = { gear = true, board = true, pad = true }
-- -> (show the card, show the world arrow)
local function cardApplies(g: Guide?): (boolean, boolean)
	if not g or inMission() then
		return true, true
	end
	local kind = g.kind
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if SKIPPABLE[kind] and hum and hum.SeatPart then
		return false, false
	end
	if not LOBBY_STEPS[kind] then
		state.staleKey = ""
		return true, true
	end
	if not g.part or not g.part:IsDescendantOf(workspace) then
		return false, false
	end
	if state.staleKey ~= kind then
		state.staleKey, state.staleSince = kind, os.clock()
	end
	return os.clock() - state.staleSince < (Cfg.StaleCardSeconds or 120), true
end

local function showCard(g: Guide?)
	local card: Frame = ui.card
	setActions(g)
	if not g then
		if card.Visible then
			card.Visible = false
		end
		state.guideKey = "" -- the same step coming back (out of the truck, Help closed) shows again
		return
	end
	fitCard()
	if g.kind == "firstfire" and not state.seenFireCard then
		state.seenFireCard = true
		local r = remote("Seen")
		if r then
			r:FireServer("firecard")
		end
	end
	-- the first-call card ticks every second: update its text in place, don't re-pop it
	local key = g.kind .. "|" .. g.head .. (if g.kind == "firstcall" then "" else "|" .. g.sub)
	if g.kind == "firstcall" and key == state.guideKey then
		if ui.sub.Text ~= g.sub then
			InputHints.setPick(ui.sub, g.sub)
		end
		ui.chipText.Text = g.chip
	end
	if key ~= state.guideKey then
		state.guideKey = key
		ui.head.Text = g.head
		InputHints.setPick(ui.sub, g.sub, g.subTouch, g.subPad)
		ui.chipText.Text = g.chip
		card.Visible = true -- HudLayout's top-centre stack places it (under the timer on a mission)
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
	-- phones: the card up top already says it; the world arrow alone points (no second giant headline)
	ui.arrowLabel.Text = if g and not Calm.small() then g.head else ""
	bb.Enabled = true
	local model = g and g.model
	if model and model:IsDescendantOf(workspace) then
		if hl.Adornee ~= model then
			hl.Adornee = model
		end
		if hl.Parent ~= workspace.CurrentCamera then
			hl.Parent = workspace.CurrentCamera
		end
		-- the training fire: outline only (an always-on-top fill painted over the flames, so the
		-- "fire" read as a yellow box)
		hl.FillTransparency = if g and g.kind == "firstfire" then 1 else 0.7 + 0.15 * math.sin(t * 4)
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
	-- off the HUD chips / gauges on that edge, and off the other edge arrows
	local ex, ey = HudLayout.clear(x, vp.Y * 0.6, 32, "OnboardingEdge", HudLayout.Prio.Onboarding)
	ui.edge.Position = UDim2.fromOffset(ex, ey)
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
	if not ui.helpModal then
		-- a modal: dims the HUD under it (click outside closes); the lobby settings buttons stay above
		ui.helpModal = true
		HudLayout.modal(ui.help, {
			onDismiss = function()
				setHelp(false)
			end,
			companions = Cfg.LobbyHiddenGuis,
		})
	end
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
	local coldOpen = not returning and ((FireCfg.ColdOpen or {}).Enabled ~= false) and FireCfg.Enabled ~= false
	if not coldOpen then
		showTitle(returning) -- a newbie's title is the cold open's SAVE THE PANDA!
	end
	if not returning then
		task.delay((Cfg.TitleSeconds or 3) + 0.4, function()
			if not inMission() and not state.flow.done then
				startTutorial()
			end
		end)
	end
end

function OnboardingController:Init(all: { [string]: any })
	controllers = all
end

function OnboardingController:Start()
	if Cfg.Enabled == false then
		return
	end
	buildTitle()
	buildHud()
	player:SetAttribute(HELP_OPEN_ATTR, false)

	-- small chips: UiKit.onTap adds a 44 px touch pad around them on phones
	UiKit.onTap(ui.helpChip, function()
		setHelp(not state.helpOpen)
	end)
	UiKit.onTap(ui.close, function()
		setHelp(false)
	end)
	ui.replay.Activated:Connect(function()
		OnboardingController:Replay()
	end)
	ui.go.Activated:Connect(function()
		pcall(function()
			Net.event("Lobby", "Launch"):FireServer()
		end)
		UiKit.pop(ui.go, 0.2)
	end)
	ui.wait.Activated:Connect(function()
		local r = remote("SkipCall")
		if r then
			r:FireServer()
		end
		state.callEndsAt = 0
		state.guideKey = ""
	end)
	ui.home.Activated:Connect(function()
		pcall(function()
			Net.event("Lobby", "BackToStation"):FireServer()
		end)
		UiKit.pop(ui.home, 0.2)
	end)
	UiKit.onTap(ui.skip, function()
		local r = remote("Skip")
		if r then
			r:FireServer()
		end
		state.tutorial = false
		state.flow.done = true
		state.guideKey = ""
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
		elseif prompt:GetAttribute("GearLocker") == true then
			state.gearGrabbed = true
		end
	end)
	-- countdown hit 0 (squad launched) = the tutorial worked
	pcall(function()
		Net.event("Lobby", "Countdown").OnClientEvent:Connect(function(_pad: any, seconds: any, title: any)
			if type(seconds) == "number" and seconds > 0 then
				state.callEndsAt = os.clock() + seconds
				state.callTitle = if type(title) == "string" then title else state.callTitle
			elseif seconds == -1 then
				state.callEndsAt = 0
			end
			if seconds == 0 then
				state.callEndsAt = 0
				finishTutorial()
			end
		end)
	end)
	player:GetAttributeChangedSignal(Attr.InstanceId):Connect(function()
		state.driveHintUntil = 0
		state.rideTruck = nil
		state.guideKey = ""
		state.missionSince = os.clock()
		if inMission() then
			state.wasOnCall = true
		elseif state.wasOnCall then
			state.missionEnded = true
		end
		if inMission() then
			finishTutorial()
			if state.helpOpen then
				setHelp(false)
			end
		end
		-- ShaderController re-enables its button on this change: re-apply after it
		task.defer(setLobbyClutter)
	end)
	player:GetAttributeChangedSignal(FireCfg.PhaseAttr):Connect(function()
		state.guideKey = ""
		if player:GetAttribute(FireCfg.PhaseAttr) == "burning" then
			task.spawn(faceFirstFire)
		else
			setShoulder(false)
		end
	end)
	if player:GetAttribute(FireCfg.PhaseAttr) == "burning" then
		task.spawn(faceFirstFire)
	end
	-- respawned while it still burns: FirstFireService puts you back at the door; face it again
	player.CharacterAdded:Connect(function()
		shoulderOn = false
		if player:GetAttribute(FireCfg.PhaseAttr) == "burning" then
			task.delay((FireCfg.StandDelay or 0.6) + 0.3, faceFirstFire)
		end
	end)
	local pg = player:WaitForChild("PlayerGui")
	pg.ChildAdded:Connect(watchClutter)
	for _, c in pg:GetChildren() do
		watchClutter(c)
	end
	setLobbyClutter()

	-- handshake: Main.client started every controller in this same frame (each Start runs until its
	-- first yield), so after one more frame their OnClientEvent handlers are connected
	task.spawn(function()
		task.wait()
		-- and only once the server has finished booting (every service declared its remotes)
		while workspace:GetAttribute("ServerBooted") ~= true do
			task.wait(0.2)
		end
		local r = remote("Ready")
		if r then
			local cam = workspace.CurrentCamera
			local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
			local tenFoot = false
			pcall(function()
				tenFoot = GuiService:IsTenFootInterface()
			end)
			-- Phone / Tablet / PC / Console for the funnel's device split (Lib/Onboarding/Funnel.device)
			r:FireServer(Funnel.device({
				touch = UserInputService.TouchEnabled,
				keyboard = UserInputService.KeyboardEnabled,
				mouse = UserInputService.MouseEnabled,
				gamepad = UserInputService.GamepadEnabled,
				tenFoot = tenFoot,
				viewportX = vp.X,
				viewportY = vp.Y,
			}))
		end
	end)

	if player.Character then
		task.spawn(onLobbyReady)
	else
		player.CharacterAdded:Once(function()
			task.wait(0.2)
			onLobbyReady()
		end)
	end

	-- touch, seated in a truck: no tutorial card / arrow over the drive (the stick, GPS and ARRIVING bar need
	-- the small screen; "1/3 GRAB YOUR GEAR" stayed up the whole drive). It comes back when you get out.
	local function truckOnTouch(): boolean
		if not InputHints.isTouch() then
			return false
		end
		local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
		local node: Instance? = hum and hum.SeatPart
		while node and node ~= workspace do
			if node:HasTag(Names.Tag.Truck) then
				return true
			end
			node = node.Parent
		end
		return false
	end

	local t = 0
	RunService.RenderStepped:Connect(function(dt: number)
		t += dt
		updateBoardLook(dt)
		-- nothing over the title card, the Help panel or the mission picker
		local busy = (ui.title and ui.title.gui.Enabled) or state.helpOpen or pickerOpen() or coldOpenPlaying() or truckOnTouch()
		local g = if busy then nil else currentGuide()
		local cardOk, arrowOk = cardApplies(g)
		showCard(if cardOk then g else nil)
		placeArrow(if arrowOk then g else nil, t)
		-- HELP waits for the panda (Onboarding v3 HUD reveal, ClientLib/HudGate)
		ui.helpChip.Visible = not inMission() and not state.helpOpen and HudGate.allows("help")
	end)
end

return OnboardingController
