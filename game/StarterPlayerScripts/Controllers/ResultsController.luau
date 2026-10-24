--!strict
-- ResultsController [owner: G3]. The Blame screen (docs/game/02-art-feel-ui.md §10, docs/game/04-market-and-hooks.md §3:
-- "the single most important viral asset"). Renders Mission/Results (Types.ResultsPayload) and hides itself when
-- Workspace RoundState leaves "Results" (or the player presses "Back to station").
--   Sunset backdrop, "FLAME AND BLAME" title with a flame gradient, MISSION COMPLETE / TIME'S UP + stars popping in,
--   a team stats strip whose numbers count up, then one award card per award flipping in 0.6 s apart; blame cards
--   get a red "BLAME!" rubber stamp that slams down (scale 3 -> 1, card shake). The scapegoat card is last and bigger.
-- Sounds come from BlameConfig.Sounds (ids default "", so silent until someone verifies an asset).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local BlameConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BlameConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local ResultsController = {}
ResultsController.Priority = 60

local CARD_W, CARD_H = 190, 250
local gui: ScreenGui? = nil
local showToken = 0
local runXp = 0 -- profile XP (Data/XpGained) since this run started; the pass's own is attr PassRunXp

local function sfx(name: string, volume: number?, pitch: number?)
	local sounds = BlameConfig.Sounds
	UiKit.sound(if type(sounds) == "table" then sounds[name] else nil, volume, pitch)
end

local function setBusy(on: boolean)
	-- level-up / new-gear / tier-up cards wait until this screen is gone (ClientLib/HudLayout)
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.setBusy("Results", on)
end

local function hide()
	showToken += 1
	setBusy(false)
	if gui then
		local g = gui
		gui = nil
		local bg = g:FindFirstChild("Backdrop") :: Frame?
		if bg then
			UiKit.tween(bg, 0.25, { BackgroundTransparency = 1 })
		end
		task.delay(0.25, function()
			g:Destroy()
		end)
	end
end

local function countUp(label: TextLabel, target: number, suffix: string, delay: number)
	label.Text = `0{suffix}`
	task.delay(delay, function()
		local value = Instance.new("NumberValue")
		local last = -1
		value.Changed:Connect(function(v: number)
			local n = math.floor(v + 0.5)
			label.Text = `{n}{suffix}`
			if n ~= last then
				last = n
				sfx("Tick", 0.3, 1 + n * 0.02)
			end
		end)
		local tween = TweenService:Create(value, TweenInfo.new(0.7, Enum.EasingStyle.Quad), { Value = target })
		tween.Completed:Connect(function()
			label.Text = `{target}{suffix}`
			UiKit.punch(label, 0.25)
			value:Destroy()
		end)
		tween:Play()
	end)
end

local function statOf(payload: Types.ResultsPayload, userId: number): Types.PlayerStats?
	for _, s in payload.stats do
		if s.userId == userId then
			return s
		end
	end
	return nil
end

local function bandColor(award: Types.Award): Color3
	if award.id == "scapegoat" then
		return Palette.UiInk
	elseif award.id == "shocking" or award.id == "lightning_rod" then
		return Palette.UiShock
	elseif award.blame then
		return Palette.UiRed
	end
	return Palette.UiWarn
end

-- A card = fixed-size holder (keeps the row layout stable) + inner face whose width flips 0 -> 1.
local function card(parent: Instance, payload: Types.ResultsPayload, award: Types.Award, order: number): (Frame, Frame)
	local isGoat = award.id == "scapegoat"
	local w, h = if isGoat then CARD_W + 30 else CARD_W, CARD_H
	local holder = Instance.new("Frame")
	holder.Name = `Card{order}`
	holder.LayoutOrder = order
	holder.Size = UDim2.fromOffset(w, h + 10)
	holder.BackgroundTransparency = 1
	holder.Visible = false
	holder:SetAttribute("AwardId", award.id)
	holder.Parent = parent

	local face = UiKit.panel(holder, "Face", UDim2.new(0, w, 0, h), UDim2.new(0.5, 0, 0.5, 0), Vector2.new(0.5, 0.5))
	face.Rotation = if order % 2 == 0 then 2 else -2
	face.ClipsDescendants = false
	if isGoat then
		face.BackgroundColor3 = Color3.fromHex("#FFE2C2")
	end

	local band = Instance.new("Frame")
	band.Name = "Band"
	band.Size = UDim2.new(1, 0, 0, 52)
	band.BackgroundColor3 = bandColor(award)
	band.BorderSizePixel = 0
	band.ZIndex = 1
	UiKit.corner(band, 12)
	band.Parent = face
	-- square off the band's bottom corners
	local fill = Instance.new("Frame")
	fill.Size = UDim2.new(1, 0, 0, 14)
	fill.Position = UDim2.new(0, 0, 1, -14)
	fill.BackgroundColor3 = band.BackgroundColor3
	fill.BorderSizePixel = 0
	fill.Parent = band

	local s = statOf(payload, award.userId)
	local helmet = if s then s.helmet else 1
	UiKit.badge(face, "Helmet", helmet, 64, UDim2.new(0.5, -32, 0, 18))
	-- battle pass title (BattlePassService attr PassTitle) on a little ink ribbon under the helmet
	local who = Players:GetPlayerByUserId(award.userId)
	local passTitle = who and who:GetAttribute("PassTitle")
	if type(passTitle) == "string" and passTitle ~= "" then
		local rib = Instance.new("Frame")
		rib.Name = "PassTitle"
		rib.AnchorPoint = Vector2.new(0.5, 0)
		rib.Position = UDim2.new(0.5, 0, 0, 70)
		rib.Size = UDim2.fromOffset(math.min(w - 20, 40 + #passTitle * 9), 20)
		rib.BackgroundColor3 = Palette.UiInk
		rib.BorderSizePixel = 0
		rib.ZIndex = 4
		UiKit.corner(rib, 8)
		rib.Parent = face
		local tc = who and who:GetAttribute("PassTitleColor")
		local tl = UiKit.label(rib, "Text", string.upper(passTitle), UDim2.new(1, -8, 1, 0), UDim2.fromOffset(4, 0), {
			font = UiKit.Header,
			textSize = 14,
			color = if typeof(tc) == "Color3" then tc else Palette.UiWarn,
		})
		tl.ZIndex = 5
	end

	UiKit.label(face, "Title", string.upper(award.title), UDim2.new(1, -16, 0, 62), UDim2.fromOffset(8, 86), {
		font = UiKit.Header,
		textSize = if isGoat then 24 else 22,
		color = if award.blame then Palette.UiRed else Palette.UiInk,
	})
	UiKit.label(face, "Name", if s then s.name else "?", UDim2.new(1, -16, 0, 22), UDim2.fromOffset(8, 148), {
		textSize = 17,
		color = Palette.CoatShadow,
	})
	UiKit.label(face, "Blurb", award.blurb, UDim2.new(1, -20, 0, 72), UDim2.fromOffset(10, 172), {
		textSize = 16,
	})

	if award.blame then
		-- slammed across the card's bottom edge: mid-card it covered the blamed player's name
		local stamp = UiKit.label(face, "Stamp", "BLAME!", UDim2.fromOffset(150, 50), UDim2.new(0.5, 0, 0, h - 6), {
			font = UiKit.Header,
			textSize = 40,
			color = Palette.UiRed,
		})
		stamp.AnchorPoint = Vector2.new(0.5, 0.5)
		stamp.Rotation = -12
		stamp.ZIndex = 5
		stamp.TextTransparency = 0.05
		stamp.Visible = false
		local ring = Instance.new("UIStroke")
		ring.Thickness = 4
		ring.Color = Palette.UiRed
		ring.Transparency = 0.1
		ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		ring.Parent = stamp
		UiKit.corner(stamp, 8)
		holder:SetAttribute("HasStamp", true)
	end
	return holder, face
end

local function flipIn(holder: Frame, face: Frame)
	local fullW = face.Size.X.Offset
	holder.Visible = true
	face.Size = UDim2.new(0, 0, 0, face.Size.Y.Offset)
	sfx("CardFlip", 0.6)
	UiKit.tween(face, 0.28, { Size = UDim2.new(0, fullW, 0, face.Size.Y.Offset) }, Enum.EasingStyle.Back)
	if holder:GetAttribute("HasStamp") then
		task.delay(0.4, function()
			local stamp = face:FindFirstChild("Stamp") :: TextLabel?
			if not stamp or not holder.Parent then
				return
			end
			local scale = Instance.new("UIScale")
			scale.Scale = 3
			scale.Parent = stamp
			stamp.TextTransparency = 1
			stamp.Visible = true
			UiKit.tween(stamp, 0.12, { TextTransparency = 0.05 })
			local slam = UiKit.tween(scale, 0.14, { Scale = 1 }, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			slam.Completed:Connect(function()
				sfx("Stamp", 0.8)
				UiKit.shake(face, 0.25, 8)
			end)
		end)
	end
end

local function star(parent: Instance, i: number, lit: boolean): TextLabel
	local l = UiKit.label(parent, `Star{i}`, "★", UDim2.fromOffset(58, 58), UDim2.fromOffset((i - 1) * 64, 0), {
		font = Enum.Font.GothamBlack,
		textSize = 54,
		color = if lit then Palette.UiWarn else Palette.UiPanelDark,
		stroke = true,
		strokeThickness = 3,
	})
	l.TextTransparency = if lit then 0 else 0.55
	l.Rotation = (i - 2) * 10
	l.Visible = false
	return l
end

local function show(payload: Types.ResultsPayload)
	hide()
	local token = showToken
	local screen = UiKit.screen("Results", 10, true)
	gui = screen
	setBusy(true)
	screen.Destroying:Connect(function()
		if gui == nil or gui == screen then
			setBusy(false)
		end
	end)

	local bg = Instance.new("Frame")
	bg.Name = "Backdrop"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.new(1, 1, 1)
	bg.BackgroundTransparency = 1
	bg.BorderSizePixel = 0
	bg.ZIndex = 0
	local grad = Instance.new("UIGradient")
	grad.Rotation = 90
	grad.Color = ColorSequence.new(Palette.SkyTitleTop, Palette.HorizonOrange)
	grad.Parent = bg
	bg.Parent = screen
	UiKit.tween(bg, 0.4, { BackgroundTransparency = 0.08 })

	-- Everything sits in a 1280x720 design frame centred on screen; ViewportScale shrinks it on phones.
	local root = Instance.new("Frame")
	root.Name = "Root"
	root.BackgroundTransparency = 1
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.5)
	root.Size = UDim2.fromOffset(1280, 720)
	root.Parent = screen

	local title = UiKit.label(root, "Title", "STATION 67", UDim2.new(1, 0, 0, 90), UDim2.fromOffset(0, 10), {
		font = UiKit.Header,
		textSize = 82,
		color = Color3.new(1, 1, 1),
		stroke = true,
		strokeThickness = 5,
	})
	local flame = Instance.new("UIGradient")
	flame.Rotation = 90
	flame.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.UiFlameTop),
		ColorSequenceKeypoint.new(0.5, Palette.UiFlameMid),
		ColorSequenceKeypoint.new(1, Palette.UiFlameLow),
	})
	flame.Parent = title
	UiKit.pop(title, 0.45)
	task.spawn(function()
		while token == showToken and title.Parent do
			title.Rotation = math.sin(os.clock() * 2) * 1.5
			task.wait(1 / 30)
		end
	end)

	local good = payload.trapped == 0 and payload.burningAtEnd == 0
	local headlineText = if payload.reason == "allOut" and good
		then "ALL CLEAR!"
		elseif good then "MISSION COMPLETE"
		elseif payload.reason == "allOut" then "FIRES OUT!"
		else "TIME'S UP!"
	local headline = UiKit.label(root, "Headline", headlineText, UDim2.fromOffset(560, 54), UDim2.new(0.5, -110, 0, 98), {
		font = UiKit.Header,
		textSize = 46,
		color = if good then Palette.UiGood else Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	headline.AnchorPoint = Vector2.new(0.5, 0)
	headline.TextXAlignment = Enum.TextXAlignment.Right
	sfx(if good then "Fanfare" else "Trombone", 0.7)

	local starRow = Instance.new("Frame")
	starRow.Name = "Stars"
	starRow.BackgroundTransparency = 1
	starRow.Size = UDim2.fromOffset(190, 58)
	starRow.Position = UDim2.new(0.5, 190, 0, 96)
	starRow.Parent = root
	local stars = {}
	for i = 1, 3 do
		stars[i] = star(starRow, i, i <= payload.stars)
	end
	task.spawn(function()
		task.wait(0.3)
		for i, s in stars do
			if token ~= showToken then
				return
			end
			s.Visible = true
			UiKit.pop(s, 0.3)
			if i <= payload.stars then
				sfx("Star", 0.6, 1 + i * 0.1)
			end
			task.wait(0.22)
		end
	end)

	-- team stats strip: six sticker chips (the last one is the XP you earned)
	local team = Instance.new("Frame")
	team.Name = "Team"
	team.BackgroundTransparency = 1
	team.AnchorPoint = Vector2.new(0.5, 0)
	team.Position = UDim2.new(0.5, 0, 0, 166)
	team.Size = UDim2.fromOffset(6 * 170 + 5 * 14, 88)
	team.Parent = root
	local teamLayout = Instance.new("UIListLayout")
	teamLayout.FillDirection = Enum.FillDirection.Horizontal
	teamLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	teamLayout.Padding = UDim.new(0, 14)
	teamLayout.SortOrder = Enum.SortOrder.LayoutOrder
	teamLayout.Parent = team
	local total = payload.rescued + payload.trapped + (tonumber(payload.lost) or 0)
	local chips = {
		{ "FIRES OUT", payload.firesOut, "", Palette.FireEdge },
		{ "RESCUED", payload.rescued, ` / {total}`, Palette.UiGood },
		{ "STILL BURNING", payload.burningAtEnd, "", Palette.UiRed },
		{ "BURNED PARTS", payload.burnedParts, "", Palette.CharredWarm },
	}
	for i, row in chips do
		local chip = UiKit.panel(team, `Chip{i}`, UDim2.fromOffset(170, 84), UDim2.fromScale(0, 0))
		chip.LayoutOrder = i
		UiKit.label(chip, "Caption", row[1] :: string, UDim2.new(1, -10, 0, 22), UDim2.fromOffset(5, 6), {
			font = UiKit.Header,
			textSize = 17,
			color = Palette.UiInk,
		})
		local value = UiKit.label(chip, "Value", "", UDim2.new(1, -10, 0, 48), UDim2.fromOffset(5, 30), {
			font = UiKit.Header,
			textSize = 42,
			color = row[4] :: Color3,
			stroke = true,
		})
		countUp(value, row[2] :: number, row[3] :: string, 0.5 + i * 0.25)
	end
	local timeChip = UiKit.panel(team, "Chip5", UDim2.fromOffset(170, 84), UDim2.fromScale(0, 0))
	timeChip.LayoutOrder = 5
	UiKit.label(timeChip, "Caption", "TIME", UDim2.new(1, -10, 0, 22), UDim2.fromOffset(5, 6), {
		font = UiKit.Header,
		textSize = 17,
	})
	UiKit.label(timeChip, "Value", UiKit.clock(payload.seconds), UDim2.new(1, -10, 0, 48), UDim2.fromOffset(5, 30), {
		font = UiKit.Header,
		textSize = 42,
		color = Palette.UiWater,
		stroke = true,
	})

	-- XP earned this run: profile XP (+ battle pass XP for pass owners). Both arrive just after this screen
	-- opens (DataService / BattlePassService handle MissionEnded after the results go out), so it ticks up.
	local me = Players.LocalPlayer
	local xpChip = UiKit.panel(team, "Chip6", UDim2.fromOffset(170, 84), UDim2.fromScale(0, 0))
	xpChip.LayoutOrder = 6
	UiKit.label(xpChip, "Caption", "XP EARNED", UDim2.new(1, -10, 0, 22), UDim2.fromOffset(5, 6), {
		font = UiKit.Header,
		textSize = 17,
	})
	local xpValue = UiKit.label(xpChip, "Value", "+0", UDim2.new(1, -10, 0, 36), UDim2.fromOffset(5, 26), {
		font = UiKit.Header,
		textSize = 36,
		color = Palette.HelmetShield,
		stroke = true,
	})
	local passValue = UiKit.label(xpChip, "Pass", "", UDim2.new(1, -10, 0, 18), UDim2.fromOffset(5, 62), {
		font = UiKit.Header,
		textSize = 15,
		color = Palette.UiWater,
	})
	local function passXp(): number
		return tonumber(me:GetAttribute("PassRunXp")) or 0 -- everyone earns pass XP (free track)
	end
	task.spawn(function()
		local lastXp, lastPass = -1, -1
		while token == showToken and xpChip.Parent do
			local xp, pass = math.floor(runXp), math.floor(passXp())
			if xp ~= lastXp or pass ~= lastPass then
				xpValue.Text = `+{xp}`
				passValue.Text = if pass > 0 then `BATTLE PASS +{pass}` else ""
				if lastXp >= 0 then
					UiKit.punch(xpChip, 0.1)
				end
				lastXp, lastPass = xp, pass
			end
			task.wait(0.25)
		end
	end)

	local blameHeader = UiKit.label(root, "BlameHeader", "~ THE BLAME ~", UDim2.new(1, 0, 0, 46), UDim2.fromOffset(0, 266), {
		font = UiKit.Header,
		textSize = 42,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	blameHeader.Visible = false

	local strip = Instance.new("ScrollingFrame")
	strip.Name = "Cards"
	strip.BackgroundTransparency = 1
	strip.BorderSizePixel = 0
	strip.AnchorPoint = Vector2.new(0.5, 0)
	strip.Position = UDim2.new(0.5, 0, 0, 316)
	strip.Size = UDim2.new(1, -40, 0, CARD_H + 30)
	strip.ScrollingDirection = Enum.ScrollingDirection.X
	strip.AutomaticCanvasSize = Enum.AutomaticSize.X
	strip.CanvasSize = UDim2.fromScale(0, 0)
	strip.ScrollBarThickness = 6
	strip.ScrollBarImageColor3 = Palette.UiInk
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = strip
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 10)
	pad.PaddingRight = UDim.new(0, 10)
	pad.Parent = strip
	strip.Parent = root

	local cards: { { Frame } } = {}
	for i, award in payload.awards do
		local holder, face = card(strip, payload, award, i)
		table.insert(cards, { holder, face })
	end

	local back = UiKit.button(root, "BackButton", "BACK TO STATION", UDim2.fromOffset(340, 64), UDim2.new(0.5, 0, 0, 650), Palette.UiRed)
	back.Visible = false
	back.Activated:Connect(function()
		sfx("Click", 0.6)
		local lobby = ReplicatedStorage:FindFirstChild("Net")
		local remote = lobby and lobby:FindFirstChild("Lobby") and (lobby :: any).Lobby:FindFirstChild("BackToStation")
		if remote and remote:IsA("RemoteEvent") then
			remote:FireServer()
		end
		hide()
	end)

	task.spawn(function()
		task.wait(1.6)
		if token ~= showToken then
			return
		end
		blameHeader.Visible = true
		UiKit.pop(blameHeader, 0.3)
		task.wait(0.4)
		for _, pair in cards do
			if token ~= showToken then
				return
			end
			flipIn(pair[1], pair[2])
			task.wait(0.6)
		end
		if token ~= showToken then
			return
		end
		back.Visible = true
		UiKit.pop(back, 0.3)
	end)
end

local function isMine(payload: Types.ResultsPayload): boolean
	-- Mission/Results goes to everyone; with parallel squads each squad only sees its own Blame screen.
	local me = Players.LocalPlayer.UserId
	if type(payload.stats) == "table" and #payload.stats > 0 then
		for _, s in payload.stats do
			if s.userId == me then
				return true
			end
		end
		return false
	end
	local id = (payload :: any).instanceId
	return id == nil or Players.LocalPlayer:GetAttribute(Names.Attr.InstanceId) == id
end

local currentInstance: string? = nil

function ResultsController:Init(_controllers: { [string]: any }) end

function ResultsController:Start()
	Net.event("Mission", "Results").OnClientEvent:Connect(function(payload: Types.ResultsPayload)
		if type(payload) ~= "table" or not isMine(payload) then
			return
		end
		currentInstance = (payload :: any).instanceId
		local ok, err = pcall(show, payload)
		if not ok then
			warn(`[ResultsController] show failed: {err}`)
			return
		end
		-- instance missions: LobbyService teleports the squad back after ReturnSeconds; keep a safety timeout
		local token = showToken
		task.delay(30, function()
			if token == showToken then
				hide()
			end
		end)
	end)
	-- v1 single round: hide when Workspace RoundState leaves Results
	workspace:GetAttributeChangedSignal(Names.Attr.RoundState):Connect(function()
		if currentInstance == nil and workspace:GetAttribute(Names.Attr.RoundState) ~= "Results" then
			hide()
		end
	end)
	-- XP earned per run (the results screen's XP EARNED line)
	Net.event("Data", "XpGained").OnClientEvent:Connect(function(amount: any)
		if type(amount) == "number" and amount > 0 then
			runXp += amount
		end
	end)
	local lastInstance = Players.LocalPlayer:GetAttribute(Names.Attr.InstanceId)
	Players.LocalPlayer:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		local now = Players.LocalPlayer:GetAttribute(Names.Attr.InstanceId)
		if type(now) == "string" and now ~= "" and now ~= lastInstance then
			runXp = 0 -- a new run
		end
		lastInstance = now
	end)
	-- v1.5 instances: hide once we are back in the lobby (InstanceId "") or launched into a new mission
	Players.LocalPlayer:GetAttributeChangedSignal(Names.Attr.InstanceId):Connect(function()
		if currentInstance ~= nil and Players.LocalPlayer:GetAttribute(Names.Attr.InstanceId) ~= currentInstance then
			hide()
		end
	end)
end

-- Test hook: render a payload locally (Client execute_luau can't require this live module, but other
-- controllers / a DevHook client harness can).
function ResultsController:_show(payload: Types.ResultsPayload)
	show(payload)
end

return ResultsController
