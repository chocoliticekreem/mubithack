--!strict
-- HudController [owner: G3]. The in-round HUD (docs/game/02-art-feel-ui.md §9), chunky sticker style, phone-safe
-- (UiKit.screen: UIScale + CoreUISafeInsets). Renders only replicated state:
--   Workspace RoundState / RoundEndsAt / MissionId      -> timer pill (red + pulse + tick under 30 s)
--   tag Burning (under workspace.Map[MissionId])        -> objectives: "FIRES LEFT n"
--   tag Rescuable + attr RescueState                    -> objectives: "RESCUED a / b"
--   LocalPlayer attr Heat 0..100 (HeatService)          -> HEAT thermometer (fills red, shakes >= 85, flashes at 100)
--   LocalPlayer attr Carrying (RescueService)           -> carry slot "CARRYING: DOG -> bring to TRUCK"
--   LocalPlayer attr Downed (SquadService)              -> DOWNED overlay
--   every Player's Helmet / Downed / Carrying / Heat    -> squad strip (top right)
--   nearest Burning / trapped Rescuable / Truck         -> on-screen markers + off-screen edge arrows (HudMarkers gui)
--   Mission/Alarm (missionId, locationName)             -> alarm banner
--   Shared/Notify (text, kind)                          -> compact toast stack, top-centre under the timer: max 2
--                                                          visible, 2.5 s, repeats within 2 s dropped (FeedbackConfig,
--                                                          Lib/PopupLogic). Important events only; minor juice is
--                                                          world text above heads (ClientLib/WorldPopup, started here).
local CollectionService = game:GetService("CollectionService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local BlameConfig = require(ConfigFolder:WaitForChild("BlameConfig") :: ModuleScript) :: any
local LobbyConfig = require(ConfigFolder:WaitForChild("LobbyConfig") :: ModuleScript) :: any
local FeedbackConfig = require(ConfigFolder:WaitForChild("FeedbackConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)
local TOUCH = UserInputService.TouchEnabled and not UserInputService.MouseEnabled -- phones + iPads (even with a keyboard)
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)
local PopupLogic = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("PopupLogic") :: ModuleScript)
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local Calm = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("Calm") :: ModuleScript)

local HudController = {}
HudController.Priority = 50

local player = Players.LocalPlayer
local Attr = Names.Attr :: any
local Tag = Names.Tag :: any
local HEAT_ATTR: string = Attr.Heat or "Heat"

local function sfx(name: string, volume: number?, pitch: number?)
	local sounds = BlameConfig.Sounds
	UiKit.sound(if type(sounds) == "table" then sounds[name] else nil, volume, pitch)
end

type Marker = { root: Frame, tip: Frame, icon: TextLabel, dist: TextLabel }

type Ui = {
	gui: ScreenGui,
	markers: ScreenGui,
	timerPill: Frame,
	timer: TextLabel,
	objectives: Frame,
	fires: TextLabel,
	rescued: TextLabel,
	heat: Frame,
	heatTube: Frame,
	heatFill: Frame,
	heatBulb: Frame,
	heatPct: TextLabel,
	heatVignette: { Frame },
	heatWarn: TextLabel,
	carry: Frame,
	carryText: TextLabel,
	squad: Frame,
	banner: Frame,
	bannerText: TextLabel,
	toasts: Frame,
	downed: Frame,
	marks: { [string]: Marker },
}

local ui: Ui? = nil

-- builders ---------------------------------------------------------------------------------

local function vignette(parent: Instance, color: Color3): { Frame }
	local out = {}
	local sides = {
		{ UDim2.new(1, 0, 0.22, 0), UDim2.fromScale(0, 0), 90 },
		{ UDim2.new(1, 0, 0.22, 0), UDim2.fromScale(0, 0.78), -90 },
		{ UDim2.new(0.16, 0, 1, 0), UDim2.fromScale(0, 0), 0 },
		{ UDim2.new(0.16, 0, 1, 0), UDim2.fromScale(0.84, 0), 180 },
	}
	for i, s in sides do
		local f = Instance.new("Frame")
		f.Name = `Vignette{i}`
		f.Size = s[1] :: UDim2
		f.Position = s[2] :: UDim2
		f.BackgroundColor3 = color
		f.BackgroundTransparency = 1
		f.BorderSizePixel = 0
		f.ZIndex = 0
		local g = Instance.new("UIGradient")
		g.Rotation = s[3] :: number
		g.Transparency = NumberSequence.new(0, 1)
		g.Parent = f
		f.Parent = parent
		table.insert(out, f)
	end
	return out
end

local function marker(parent: Instance, name: string, letter: string, color: Color3): Marker
	local root = Instance.new("Frame")
	root.Name = name
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Size = UDim2.fromOffset(46, 46)
	root.BackgroundTransparency = 1
	root.Visible = false
	root.Parent = parent
	-- pointer: rotated square sticking out of the circle, rotated toward the target when off-screen
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
	tip.Position = UDim2.new(1, 2, 0.5, 0)
	tip.Size = UDim2.fromOffset(20, 20)
	tip.Rotation = 45
	tip.BackgroundColor3 = color
	tip.BorderSizePixel = 0
	UiKit.stroke(tip, 3)
	tip.Parent = pivot
	local circle = Instance.new("Frame")
	circle.Name = "Circle"
	circle.AnchorPoint = Vector2.new(0.5, 0.5)
	circle.Position = UDim2.fromScale(0.5, 0.5)
	circle.Size = UDim2.fromOffset(40, 40)
	circle.BackgroundColor3 = color
	circle.BorderSizePixel = 0
	circle.ZIndex = 2
	UiKit.corner(circle, 40)
	UiKit.stroke(circle, 3)
	circle.Parent = root
	local icon = UiKit.label(circle, "Icon", letter, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 22,
		color = Palette.UiCream,
		stroke = true,
	})
	icon.ZIndex = 3
	local dist = UiKit.label(root, "Dist", "0m", UDim2.fromOffset(90, 22), UDim2.new(0.5, -45, 1, 2), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiCream,
		stroke = true,
	})
	return { root = root, tip = pivot, icon = icon, dist = dist }
end

local function build(): Ui
	local gui = UiKit.screen("Hud", 1)

	-- markers live in their own unscaled, full-bleed gui so viewport pixels map 1:1
	local markers = UiKit.screen("HudMarkers", 0, true)
	local markerScale = markers:FindFirstChild("ViewportScale")
	if markerScale then
		markerScale:Destroy()
	end
	local heatVignette = vignette(markers, Palette.FireEdge)

	-- timer pill (top centre)
	local timerPill = UiKit.panel(gui, "TimerPill", UDim2.fromOffset(180, 56), UDim2.new(0.5, 0, 0, 10), Vector2.new(0.5, 0))
	local pillScale = Instance.new("UIScale")
	pillScale.Name = "Pulse"
	pillScale.Parent = timerPill
	local timer = UiKit.label(timerPill, "Time", "3:00", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 40,
	})

	-- objectives card (top left)
	local objectives = UiKit.panel(gui, "Objectives", UDim2.fromOffset(260, 96), UDim2.fromOffset(14, 10))
	local fires = UiKit.label(objectives, "Fires", "FIRES LEFT  0", UDim2.new(1, -24, 0, 38), UDim2.fromOffset(12, 8), {
		font = UiKit.Header,
		textSize = 27,
		color = Palette.FireEdge,
		align = Enum.TextXAlignment.Left,
		stroke = true,
		strokeThickness = 1.5,
	})
	local rescued = UiKit.label(objectives, "Rescued", "RESCUED  0 / 0", UDim2.new(1, -24, 0, 38), UDim2.fromOffset(12, 50), {
		font = UiKit.Header,
		textSize = 27,
		color = Palette.UiGood,
		align = Enum.TextXAlignment.Left,
		stroke = true,
		strokeThickness = 1.5,
	})

	-- squad strip (top right)
	local squad = Instance.new("Frame")
	squad.Name = "Squad"
	squad.AnchorPoint = Vector2.new(1, 0)
	squad.Position = UDim2.new(1, -14, 0, 150) -- HudLayout.pin below: under the minimap and its turn-hint slot
	squad.Size = UDim2.fromOffset(220, 4 * 46)
	squad.BackgroundTransparency = 1
	local squadLayout = Instance.new("UIListLayout")
	squadLayout.SortOrder = Enum.SortOrder.LayoutOrder
	squadLayout.Padding = UDim.new(0, 6)
	squadLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	squadLayout.Parent = squad
	squad.Parent = gui

	-- heat thermometer (bottom right; no water gauge: trucks have endless water)
	local heat = Instance.new("Frame")
	heat.Name = "Heat"
	heat.AnchorPoint = Vector2.new(1, 1)
	heat.Position = UDim2.new(1, -14, 1, -14)
	heat.Size = UDim2.fromOffset(56, 184)
	heat.BackgroundTransparency = 1
	heat.Parent = gui
	-- big centre warning so you KNOW you're about to drop (the thermometer alone is easy to miss)
	-- bottom-anchored: always 16 px above the carry slot (RescueController, 1,-122 + 74 tall) whatever the
	-- screen's aspect; at 0.62 of the height it sat on the carry slot on phones
	local heatWarn = UiKit.label(gui, "HeatWarn", "", UDim2.fromOffset(640, 56), UDim2.new(0.5, -320, 1, -268), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.UiFlameTop,
		stroke = true,
	})
	heatWarn.Visible = false
	local heatTube = Instance.new("Frame")
	heatTube.Name = "Tube"
	heatTube.AnchorPoint = Vector2.new(0.5, 0)
	heatTube.Position = UDim2.new(0.5, 0, 0, 22)
	heatTube.Size = UDim2.fromOffset(26, 124)
	heatTube.BackgroundColor3 = Palette.UiCream
	heatTube.BorderSizePixel = 0
	heatTube.ClipsDescendants = true
	UiKit.corner(heatTube, 13)
	UiKit.stroke(heatTube, 3)
	heatTube.Parent = heat
	local heatFill = Instance.new("Frame")
	heatFill.Name = "Fill"
	heatFill.AnchorPoint = Vector2.new(0, 1)
	heatFill.Position = UDim2.fromScale(0, 1)
	heatFill.Size = UDim2.fromScale(1, 0)
	heatFill.BackgroundColor3 = Color3.new(1, 1, 1)
	heatFill.BorderSizePixel = 0
	local heatGrad = Instance.new("UIGradient")
	heatGrad.Rotation = -90
	heatGrad.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.UiFlameLow),
		ColorSequenceKeypoint.new(0.6, Palette.UiFlameMid),
		ColorSequenceKeypoint.new(1, Palette.UiFlameTop),
	})
	heatGrad.Parent = heatFill
	heatFill.Parent = heatTube
	local heatBulb = Instance.new("Frame")
	heatBulb.Name = "Bulb"
	heatBulb.AnchorPoint = Vector2.new(0.5, 1)
	heatBulb.Position = UDim2.new(0.5, 0, 1, 0)
	heatBulb.Size = UDim2.fromOffset(44, 44)
	heatBulb.BackgroundColor3 = Palette.UiFlameLow
	heatBulb.BorderSizePixel = 0
	heatBulb.ZIndex = 2
	UiKit.corner(heatBulb, 44)
	UiKit.stroke(heatBulb, 3)
	heatBulb.Parent = heat
	local heatPct = UiKit.label(heatBulb, "Pct", "0", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiCream,
		stroke = true,
	})
	heatPct.ZIndex = 3
	UiKit.label(heat, "Caption", "HEAT", UDim2.new(1, 10, 0, 20), UDim2.fromOffset(-5, 0), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiCream,
		stroke = true,
	})

	-- phones / iPads: the bottom-right corner is the thumb cluster (jump + SPRAY etc.) and the left edge
	-- holds the HELP / STORE / ADMIN chips, so the thermometer sits right of the chip column
	if TOUCH then
		heat.AnchorPoint = Vector2.new(0, 0.5)
		heat.Position = UDim2.new(0, 146, 0.5, -10)
	end

	-- carry slot (bottom left)
	local carry = UiKit.panel(gui, "Carry", UDim2.fromOffset(300, 70), UDim2.new(0, 14, 1, -14), Vector2.new(0, 1))
	carry.BackgroundColor3 = Palette.UiGood
	local carryText = UiKit.label(carry, "Text", "CARRYING", UDim2.new(1, -16, 1, -8), UDim2.fromOffset(8, 4), {
		font = UiKit.Header,
		textSize = 22,
		color = Palette.UiCream,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	carry.Visible = false

	-- alarm banner (top-centre stack under the CALL! card: it pops in place, HudLayout owns its Position)
	local banner = Instance.new("Frame")
	banner.Name = "AlarmBanner"
	banner.AnchorPoint = Vector2.new(0.5, 0)
	banner.Position = UDim2.new(0.5, 0, 0, 0)
	banner.Size = UDim2.fromOffset(520, 72) -- card width: a full-width strip ran over the side columns
	banner.Visible = false
	banner.Rotation = -2
	banner.BackgroundColor3 = Palette.UiRed
	banner.BorderSizePixel = 0
	UiKit.stroke(banner, 4)
	banner.Parent = gui
	local bannerText = UiKit.label(banner, "Text", "ALARM!", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 48,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	-- long addresses shrink to fit the card-width banner instead of spilling out of it
	bannerText.Size = UDim2.new(1, -20, 1, -10)
	bannerText.Position = UDim2.fromOffset(10, 5)
	bannerText.TextScaled = true
	local bannerMax = Instance.new("UITextSizeConstraint")
	bannerMax.MaxTextSize = 44
	bannerMax.Parent = bannerText
	UiKit.corner(banner, 12)

	-- toast stack (top centre, just under the timer pill; compact, max 2)
	local toasts = Instance.new("Frame")
	toasts.Name = "Toasts"
	toasts.BackgroundTransparency = 1
	toasts.AnchorPoint = Vector2.new(0.5, 0)
	toasts.Position = UDim2.new(0.5, 0, 0, tonumber(FeedbackConfig.ToastTop) or 74)
	toasts.Size = UDim2.fromOffset(420, 70)
	local layout = Instance.new("UIListLayout")
	layout.VerticalAlignment = Enum.VerticalAlignment.Top
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 4)
	layout.Parent = toasts
	toasts.Parent = gui

	-- downed overlay
	local downed = Instance.new("Frame")
	downed.Name = "Downed"
	downed.Size = UDim2.fromScale(1, 1)
	downed.BackgroundColor3 = Palette.UiRed
	downed.BackgroundTransparency = 0.75
	downed.BorderSizePixel = 0
	downed.Visible = false
	downed.Parent = gui
	local downedText = UiKit.label(downed, "Text", "DOWNED!\nHold on, a teammate can revive you", UDim2.fromOffset(760, 120),
		UDim2.fromScale(0.5, 0.4), {
			font = UiKit.Header,
			textSize = 40,
			color = Palette.UiCream,
			stroke = true,
			strokeThickness = 3,
		})
	downedText.AnchorPoint = Vector2.new(0.5, 0.5)

	-- shared layout (ClientLib/HudLayout): top-centre stack timer -> CALL! card -> banner -> toasts,
	-- the left column, and the squad strip under the minimap's turn-hint slot
	HudLayout.add("TopCentre", timerPill, 10)
	HudLayout.add("TopCentre", banner, 30)
	HudLayout.add("TopCentre", toasts, 40) -- its fixed 70 px holds the 2 toasts it may show at once
	HudLayout.add("Left", objectives, 10)
	HudLayout.pin(squad, function(s, _inset)
		return HudLayout.RightColumnBelow * s
	end)
	for _, w in { timerPill, objectives, squad, heat, carry } do
		HudLayout.reserve(w)
	end

	local marks = {
		fire = marker(markers, "FireMarker", "F", Palette.FireEdge),
		rescue = marker(markers, "RescueMarker", "R", Palette.UiGood),
		truck = marker(markers, "TruckMarker", "T", Palette.UiWater),
	}

	return {
		gui = gui,
		markers = markers,
		timerPill = timerPill,
		timer = timer,
		objectives = objectives,
		fires = fires,
		rescued = rescued,
		heat = heat,
		heatTube = heatTube,
		heatFill = heatFill,
		heatBulb = heatBulb,
		heatPct = heatPct,
		heatVignette = heatVignette,
		heatWarn = heatWarn,
		carry = carry,
		carryText = carryText,
		squad = squad,
		banner = banner,
		bannerText = bannerText,
		toasts = toasts,
		downed = downed,
		marks = marks,
	}
end

-- toasts -----------------------------------------------------------------------------------

local toastOrder = 0
local toastStates: { [boolean]: PopupLogic.State } = {} -- [calm]: phones show one toast at a time
local toastFrames: { [number]: Frame } = {}

local function dropToast(id: number)
	local f = toastFrames[id]
	toastFrames[id] = nil
	if f then
		f:Destroy()
	end
end

local function toast(text: string, kind: string)
	local u = ui
	if not u then
		return
	end
	WorldPopup.screenShown(text) -- the same line as a world popup too would say it twice
	text = InputHints.format(text) -- server text names keys; touch / gamepad see their own buttons
	local calm = Calm.on()
	local secs = tonumber(if calm then FeedbackConfig.CalmToastSeconds else FeedbackConfig.ToastSeconds) or 2.5
	local toastState = toastStates[calm]
	if not toastState then
		local n = tonumber(if calm then FeedbackConfig.CalmToastMax else FeedbackConfig.ToastMax) or 2
		toastState = PopupLogic.new({
			cap = n,
			perSubject = n,
			dedupeSeconds = tonumber(FeedbackConfig.ToastDedupeSeconds) or 2,
			lifeSeconds = secs,
		})
		toastStates[calm] = toastState
	end
	local d = PopupLogic.admit(toastState, os.clock(), "screen", text)
	if not d.show then
		return
	end
	for _, id in d.evict do
		dropToast(id)
	end
	toastOrder += 1
	local size = (tonumber(FeedbackConfig.ToastTextSize) or 17) - (if calm then 1 else 0)
	local frame = Instance.new("Frame")
	frame.Name = `Toast{toastOrder}`
	frame.LayoutOrder = toastOrder
	frame.AutomaticSize = Enum.AutomaticSize.X
	frame.Size = UDim2.fromOffset(0, size + 12)
	frame.BackgroundColor3 = Palette.UiInk
	frame.BackgroundTransparency = 0.35
	frame.BorderSizePixel = 0
	UiKit.corner(frame, 10)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 12)
	pad.PaddingRight = UDim.new(0, 12)
	pad.Parent = frame
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.AutomaticSize = Enum.AutomaticSize.X
	label.Size = UDim2.fromScale(0, 1)
	label.BackgroundTransparency = 1
	label.Font = UiKit.Header
	label.TextSize = size
	label.Text = text
	label.TextColor3 = if kind == "info" then Palette.UiCream else UiKit.kindColor(kind)
	label.Parent = frame
	frame.Parent = u.toasts
	toastFrames[d.id] = frame
	UiKit.pop(frame, 0.15)
	sfx("Toast", if calm then 0.18 else 0.3)
	local id = d.id
	task.delay(secs, function()
		if toastFrames[id] == frame then
			UiKit.tween(frame, 0.2, { BackgroundTransparency = 1 })
			UiKit.tween(label, 0.2, { TextTransparency = 1 })
			task.wait(0.2)
			dropToast(id)
			PopupLogic.release(toastState, id)
		end
	end)
end

local bannerShows = 0
local function showBanner(locationName: string)
	local u = ui
	if not u then
		return
	end
	u.bannerText.Text = `ALARM! FIRE AT {string.upper(locationName)}!`
	bannerShows += 1
	local mine = bannerShows
	u.banner.Visible = true
	-- HudLayout's top-centre stack puts it under the CALL! card; pop it in place
	UiKit.pop(u.banner, 0.35)
	task.spawn(function()
		for i = 1, 6 do
			u.banner.BackgroundColor3 = if i % 2 == 0 then Palette.UiRed else Palette.AlarmRed
			task.wait(0.25)
		end
	end)
	task.delay(3, function()
		if bannerShows == mine then
			u.banner.Visible = false
		end
	end)
end

-- world queries ----------------------------------------------------------------------------
-- v1: one round, state on Workspace. v1.5: each squad plays in Workspace.Instances.<InstanceId>, whose
-- Model carries RoundState / RoundEndsAt / MissionId; Player.InstanceId == "" means "in the lobby".

local function instanceIdOf(p: Player): string
	local id = p:GetAttribute(Attr.InstanceId or "InstanceId")
	return if type(id) == "string" then id else ""
end

local function myInstance(): Instance?
	local id = instanceIdOf(player)
	if id == "" then
		return nil
	end
	local folder = workspace:FindFirstChild("Instances")
	return folder and folder:FindFirstChild(id)
end

local function roundAttr(name: string): any
	local inst = myInstance()
	if inst then
		local v = inst:GetAttribute(name)
		if v ~= nil then
			return v
		end
	end
	return workspace:GetAttribute(name)
end

local function missionRoot(): Instance?
	local inst = myInstance()
	if inst then
		-- v2 dispatch: the run folder points at its IncidentSite in the city (MissionService)
		local site = inst:FindFirstChild("Site")
		if site and site:IsA("ObjectValue") and site.Value then
			return site.Value
		end
		return inst
	end
	local map = workspace:FindFirstChild("Map")
	local id = workspace:GetAttribute(Names.Attr.MissionId)
	return if map and type(id) == "string" then map:FindFirstChild(id) else nil
end

-- Rescuables of my mission: in an instance, those inside it or tagged with its InstanceId.
local function rescuables(): { Instance }
	local all = CollectionService:GetTagged(Names.Tag.Rescuable)
	local inst = myInstance()
	if not inst then
		return all
	end
	local id = instanceIdOf(player)
	local mine = {}
	for _, m in all do
		if m:IsDescendantOf(inst) or m:GetAttribute(Attr.InstanceId or "InstanceId") == id then
			table.insert(mine, m)
		end
	end
	return if #mine > 0 then mine else all
end

local function partPos(inst: Instance): Vector3?
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Model") then
		return inst:GetPivot().Position
	end
	return nil
end

local function myPos(): Vector3?
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return if root then root.Position else nil
end

-- (fires left, nearest burning position)
local function scanFires(from: Vector3?): (number, Vector3?)
	local loc = missionRoot()
	local n, best, bestD = 0, nil :: Vector3?, math.huge
	for _, part in CollectionService:GetTagged(Names.Tag.Burning) do
		if loc and not part:IsDescendantOf(loc) then
			continue
		end
		n += 1
		local p = partPos(part)
		if p and from then
			local d = (p - from).Magnitude
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	return n, best
end

-- (rescued, total, nearest trapped position)
local function scanRescues(from: Vector3?): (number, number, Vector3?)
	local rescued, total = 0, 0
	local best, bestD = nil :: Vector3?, math.huge
	for _, m in rescuables() do
		total += 1
		local st = m:GetAttribute(Names.Attr.RescueState)
		if st == "Rescued" then
			rescued += 1
		elseif st == "Trapped" or st == "Downed" then
			local p = partPos(m)
			if p and from then
				local d = (p - from).Magnitude
				if d < bestD then
					best, bestD = p, d
				end
			end
		end
	end
	return rescued, total, best
end

local function truckPos(from: Vector3?): Vector3?
	local best, bestD = nil :: Vector3?, math.huge
	for _, t in CollectionService:GetTagged(Names.Tag.Truck) do
		local p = if t:IsDescendantOf(workspace) then partPos(t) else nil
		if p then
			local d = if from then (p - from).Magnitude else 0
			if d < bestD then
				best, bestD = p, d
			end
		end
	end
	return best
end

local function carriedKind(id: any): string
	if id == nil or id == false or id == "" then
		return ""
	end
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:GetAttribute(Names.Attr.RescueId) == id or m:GetAttribute(Names.Attr.CarriedBy) == player.UserId then
			return string.upper(tostring(m:GetAttribute(Names.Attr.Kind) or "someone"))
		end
	end
	return if type(id) == "string" and #id < 12 then string.upper(id) else "SOMEONE"
end

-- markers ------------------------------------------------------------------------------------

-- HudLayout claim priority: two markers pointing the same way stack instead of overlapping
local function markerPrio(m: Marker): number
	local n = m.root.Name
	return if n == "FireMarker" then HudLayout.Prio.Fire
		elseif n == "RescueMarker" then HudLayout.Prio.Rescue
		else HudLayout.Prio.Truck
end

local function placeMarker(m: Marker, target: Vector3?, from: Vector3?)
	local cam = workspace.CurrentCamera
	if not target or not from or not cam then
		m.root.Visible = false
		return
	end
	local vp = cam.ViewportSize
	local v, onScreen = cam:WorldToViewportPoint(target + Vector3.new(0, 4, 0))
	-- metres (3.5 studs each); the marker hides once you're right there (it only clutters the view)
	local metres = math.floor((target - from).Magnitude / 3.5 + 0.5)
	m.dist.Text = `{metres}m`
	-- calm (phones): far away the GPS route + its marker already lead to the call; F / R join once you're
	-- close (three arrows to one spot is noise on a small screen)
	local far = Calm.on() and metres > 60 and m.root.Name ~= "TruckMarker" and player:GetAttribute("WaypointPos") ~= nil
	m.root.Visible = metres > 20 and not far
	if far then
		return
	end
	local margin = 40
	-- keep markers out from under the Roblox top bar (HudMarkers is full-bleed: y = 0 is the screen top)
	local topClear = GuiService:GetGuiInset().Y + 28
	if onScreen and v.X > margin and v.X < vp.X - margin and v.Y > topClear and v.Y < vp.Y - margin then
		-- never on top of a HUD panel (minimap, squad strip, cards): nudge it toward the centre
		local ox, oy = HudLayout.clear(v.X, v.Y, 36, m.root.Name, markerPrio(m))
		m.root.Position = UDim2.fromOffset(ox, oy)
		m.tip.Rotation = 90 -- point down at the target
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
	local rx, ry = vp.X * 0.44, math.min(vp.Y * 0.40, vp.Y / 2 - topClear)
	local k = 1 / math.sqrt((dx / rx) ^ 2 + (dy / ry) ^ 2)
	-- off the HUD panels (objectives, squad, gauges...): slide in toward the centre until clear
	local ex, ey = HudLayout.clear(cx + dx * k, cy + dy * k, 36, m.root.Name, markerPrio(m))
	m.root.Position = UDim2.fromOffset(ex, ey)
	m.tip.Rotation = math.deg(math.atan2(dy, dx))
end

-- squad strip ------------------------------------------------------------------------------

local function squadRow(parent: Instance, p: Player): Frame
	local row = UiKit.panel(parent, `Row{p.UserId}`, UDim2.fromOffset(210, 40), UDim2.fromScale(0, 0))
	UiKit.badge(row, "Badge", 0, 34, UDim2.fromOffset(4, 3))
	UiKit.label(row, "Name", if p == player then "YOU" else p.DisplayName, UDim2.new(1, -110, 1, 0), UDim2.fromOffset(44, 0), {
		font = UiKit.Header,
		textSize = 18,
		align = Enum.TextXAlignment.Left,
	})
	local status = UiKit.label(row, "Status", "OK", UDim2.fromOffset(66, 40), UDim2.new(1, -70, 0, 0), {
		font = UiKit.Header,
		textSize = 16,
		color = Palette.UiGood,
		align = Enum.TextXAlignment.Right,
	})
	status.Name = "Status"
	-- battle pass title (BattlePassService attr PassTitle) under the name; refreshSquad fills it
	local title = UiKit.label(row, "PassTitle", "", UDim2.new(1, -110, 0, 14), UDim2.fromOffset(45, 24), {
		font = UiKit.Body,
		textSize = 12,
		color = Palette.UiFlameMid,
		align = Enum.TextXAlignment.Left,
	})
	title.Visible = false
	return row
end

local function refreshSquad(u: Ui)
	local seen: { [Instance]: boolean } = {}
	local scope = instanceIdOf(player)
	for _, p in Players:GetPlayers() do
		if instanceIdOf(p) ~= scope then
			continue
		end
		local row = u.squad:FindFirstChild(`Row{p.UserId}`) :: Frame?
		if not row then
			row = squadRow(u.squad, p)
		end
		local r = row :: Frame
		seen[r] = true
		local helmet = (p:GetAttribute(Names.Attr.Helmet) :: number?) or 0
		r.LayoutOrder = helmet
		local num = r:FindFirstChild("Badge") and (r :: any).Badge:FindFirstChild("Num") :: TextLabel?
		if num then
			num.Text = UiKit.helmetTag(helmet)
		end
		local status = r:FindFirstChild("Status") :: TextLabel?
		local downedNow = p:GetAttribute(Names.Attr.Downed) == true
		local heatNow = (p:GetAttribute(HEAT_ATTR) :: number?) or 0
		local carrying = p:GetAttribute(Names.Attr.Carrying)
		if status then
			if downedNow then
				status.Text, status.TextColor3 = "DOWNED", Palette.UiRed
			elseif heatNow >= 85 then
				status.Text, status.TextColor3 = "HOT!", Palette.FireEdge
			elseif carrying ~= nil and carrying ~= false and carrying ~= "" then
				status.Text, status.TextColor3 = "CARRY", Palette.UiWater
			else
				status.Text, status.TextColor3 = "OK", Palette.UiGood
			end
		end
		r.BackgroundColor3 = if downedNow then Color3.fromHex("#F2B8B0") else Palette.UiCream
		local passTitle = p:GetAttribute("PassTitle")
		local tl = r:FindFirstChild("PassTitle") :: TextLabel?
		local nameLabel = r:FindFirstChild("Name") :: TextLabel?
		if tl and nameLabel then
			local has = type(passTitle) == "string" and passTitle ~= ""
			tl.Visible = has
			tl.Text = if has then string.upper(passTitle :: string) else ""
			local tc = p:GetAttribute("PassTitleColor")
			tl.TextColor3 = if typeof(tc) == "Color3" and tc ~= Color3.fromHex("#FFF1D6") then (tc :: Color3):Lerp(Palette.UiInk, 0.25) else Palette.UiFlameMid
			nameLabel.Size = if has then UDim2.new(1, -110, 0, 26) else UDim2.new(1, -110, 1, 0)
		end
	end
	for _, c in u.squad:GetChildren() do
		if c:IsA("Frame") and not seen[c] then
			c:Destroy()
		end
	end
end

-- per-frame refresh -------------------------------------------------------------------------

local lastTick = -1
local wasInRound = false
local heatAlarmAt = 0
local wasDowned = false

local function refresh(t: number)
	local u = ui
	if not u then
		return
	end
	local state = roundAttr(Names.Attr.RoundState)
	local active = state == "Active"
	local inRound = active or state == "Alarm"
	local from = myPos()

	u.timerPill.Visible = inRound
	if inRound ~= wasInRound then
		-- level-up / tier-up cards wait for the end of the call: mid-fire they landed on the heat warning
		wasInRound = inRound
		HudLayout.setBusy("OnCall", inRound)
	end
	local pulse = u.timerPill:FindFirstChild("Pulse") :: UIScale?
	if state == "Alarm" then
		u.timer.Text = "ALARM"
		u.timer.TextColor3 = Palette.UiRed
	elseif active then
		local endsAt = (roundAttr(Names.Attr.RoundEndsAt) :: number?) or 0
		local left = endsAt - workspace:GetServerTimeNow()
		u.timer.Text = UiKit.clock(left)
		local critical = left < 30
		u.timer.TextColor3 = if critical then Palette.UiRed else Palette.UiInk
		if pulse then
			pulse.Scale = if critical then 1 + 0.06 * (1 + math.sin(t * math.pi * 2)) else 1
		end
		local whole = math.ceil(left)
		if critical and whole ~= lastTick and whole >= 0 then
			lastTick = whole
			sfx("TimerTick", 0.4, 1 + (30 - whole) * 0.01)
		end
	end

	u.objectives.Visible = active
	local firesLeft, nearestFire = scanFires(from)
	local rescued, total, nearestRescue = scanRescues(from)
	u.fires.Text = `FIRES LEFT  {firesLeft}`
	u.rescued.Text = `RESCUED  {rescued} / {total}`

	-- heat
	local heatAttr = player:GetAttribute(HEAT_ATTR)
	local heat = if type(heatAttr) == "number" then math.clamp(heatAttr, 0, 100) else 0
	u.heat.Visible = inRound or heat > 0
	u.heatFill.Size = UDim2.fromScale(1, heat / 100)
	u.heatPct.Text = tostring(math.floor(heat))
	if heat >= 100 then
		local on = math.floor(t * 8) % 2 == 0
		u.heatBulb.BackgroundColor3 = if on then Color3.new(1, 1, 1) else Palette.UiRed
		u.heatTube.BackgroundColor3 = if on then Palette.UiFlameTop else Palette.UiCream
	else
		u.heatBulb.BackgroundColor3 = if heat > 0 then Palette.UiFlameLow:Lerp(Palette.UiRed, heat / 100) else Palette.UiPanelDark
		u.heatTube.BackgroundColor3 = Palette.UiCream
	end
	if heat >= 75 and heat < 100 then
		local critical = heat >= 90
		u.heatWarn.Visible = true
		u.heatWarn.Text = if critical then "OVERHEATING! GET OUT NOW!" else "TOO HOT! GET OUT OR GET HOSED"
		local pulse = 0.5 + 0.5 * math.sin(t * (if critical then 16 else 7))
		u.heatWarn.TextColor3 = Palette.UiFlameTop:Lerp(Palette.UiRed, pulse)
		u.heatWarn.TextTransparency = if critical then 0 else 0.25 * (1 - pulse)
	else
		u.heatWarn.Visible = false
	end
	if heat >= 85 then
		UiKit.shake(u.heat, 0.2, if heat >= 100 then 6 else 3)
		if os.clock() - heatAlarmAt > 1 then
			heatAlarmAt = os.clock()
			sfx("HeatAlarm", 0.5)
		end
	end
	local vig = math.clamp((heat - 40) / 60, 0, 1) * 0.55
	if heat >= 100 then
		vig = 0.45 + 0.2 * math.sin(t * 12)
	end
	for _, f in u.heatVignette do
		f.BackgroundTransparency = 1 - vig
	end

	-- carry
	local carryId = player:GetAttribute(Names.Attr.Carrying)
	local kind = carriedKind(carryId)
	local carrying = kind ~= ""
	if carrying and not u.carry.Visible then
		UiKit.pop(u.carry, 0.25)
	end
	u.carry.Visible = carrying
	if carrying then
		u.carryText.Text = `CARRYING: {kind}\nGet them OUTSIDE or to the TRUCK!` -- either counts (RescueService)
	end

	-- downed
	-- only while the call is live: after a squad wipe the round goes to Results with everyone still
	-- Downed, and "a teammate can revive you" sat on top of the results card
	local downedNow = player:GetAttribute(Names.Attr.Downed) == true and state ~= "Results" and state ~= "Done"
	u.downed.Visible = downedNow
	if downedNow and not wasDowned then
		UiKit.pop(u.downed:FindFirstChild("Text") :: GuiObject, 0.3)
	end
	wasDowned = downedNow
	u.downed.BackgroundTransparency = 0.72 + 0.08 * math.sin(t * 5)

	-- squad
	u.squad.Visible = inRound or #Players:GetPlayers() > 1
	refreshSquad(u)

	-- markers: the truck is forced on while carrying
	placeMarker(u.marks.fire, if active then nearestFire else nil, from)
	placeMarker(u.marks.rescue, if active and not carrying then nearestRescue else nil, from)
	placeMarker(u.marks.truck, if active and carrying then truckPos(from) else nil, from)
end

function HudController:Init(_controllers: { [string]: any }) end

function HudController:Start()
	ui = build()
	WorldPopup.start()
	-- remotes: never let a missing one kill the HUD loop
	task.spawn(function()
		local ok, err = pcall(function()
			Net.event("Shared", "Notify").OnClientEvent:Connect(function(text: string, kind: string?)
				toast(tostring(text), kind or "info")
			end)
		end)
		if not ok then
			warn(`[HudController] Shared/Notify: {err}`)
		end
	end)
	task.spawn(function()
		local ok, err = pcall(function()
			Net.event("Mission", "Alarm").OnClientEvent:Connect(function(_missionId: string, locationName: string)
				-- Mission/Alarm goes to everyone; with parallel squads only show it to players in a mission
				task.wait(0.3) -- let InstanceId replicate
				if not LobbyConfig.UseLobby or instanceIdOf(player) ~= "" then
					showBanner(tostring(locationName))
				end
			end)
		end)
		if not ok then
			warn(`[HudController] Mission/Alarm: {err}`)
		end
	end)
	local t0 = os.clock()
	RunService.RenderStepped:Connect(function()
		local ok, err = pcall(refresh, os.clock() - t0)
		if not ok then
			warn(`[HudController] refresh: {err}`)
			task.wait(1)
		end
	end)
end

-- Test hook: push a toast without a server.
function HudController:_toast(text: string, kind: string?)
	toast(text, kind or "info")
end

return HudController
