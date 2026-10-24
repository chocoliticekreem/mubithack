--!nonstrict
-- ShopUi.client: client-only shop panel (SHOP button + upgrade cards). Sends intent only.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme"))
local Upgrades = require(ReplicatedStorage:WaitForChild("Upgrades"))

local ShopFx = nil
do
	local fxModule = script.Parent:WaitForChild("ShopFx", 10)
	if fxModule then
		local okFx, mod = pcall(require, fxModule)
		if okFx then
			ShopFx = mod
		end
	end
	if not ShopFx then
		warn("[ShopUi] ShopFx missing; using no-op effects")
		ShopFx = {
			openPanel = function(p)
				p.Visible = true
				local sc = p:FindFirstChildOfClass("UIScale")
				if sc then
					sc.Scale = 0
					TweenService:Create(sc, TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
				end
			end,
			buySuccess = function() end,
			buyFail = function() end,
		}
	end
end
local pendingBuy = nil

local buyRemote = ReplicatedStorage:WaitForChild("BuyUpgrade", 10)
local syncRemote = ReplicatedStorage:WaitForChild("ShopSync", 10)
if not buyRemote or not syncRemote then
	warn("[ShopUi] shop remotes missing; shop disabled")
	return
end

local playerGui = player:WaitForChild("PlayerGui")

local ownedSet = {}
local cash = 0
local cards = {}
local lastBuy = 0

-- Effect text built from the exact effect fields in Upgrades
local function effectText(u)
	local e = u.effect
	if type(e) ~= "table" then
		return ""
	end
	if e.kind == "dropper" then
		return "Droppers: " .. tostring(e.slots)
	elseif e.kind == "tier" then
		local ore = Upgrades.ores[e.tier]
		if ore then
			return ore.name .. " ore, $" .. tostring(ore.value) .. " each"
		end
		return "Ore tier " .. tostring(e.tier)
	elseif e.kind == "speed" then
		return "Conveyor speed x" .. tostring(e.mult)
	elseif e.kind == "cashMult" then
		return "Cash payout x" .. tostring(e.mult)
	end
	return tostring(e.kind)
end

local function swatchColor(u)
	local e = u.effect
	if type(e) == "table" then
		if e.kind == "tier" and Upgrades.ores[e.tier] then
			return Upgrades.ores[e.tier].color
		elseif e.kind == "dropper" then
			return UiTheme.info
		elseif e.kind == "speed" then
			return UiTheme.good
		end
	end
	return UiTheme.accent
end

-- GUI
local gui = Instance.new("ScreenGui")
gui.Name = "ShopUi"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.AnchorPoint = Vector2.new(0.5, 0.5)
panel.Position = UDim2.fromScale(0.54, 0.5)
panel.Size = UDim2.fromScale(0.9, 0.82)
panel.BackgroundColor3 = UiTheme.panel
panel.BorderSizePixel = 0
panel.Visible = false
panel.ZIndex = 1
panel.Parent = gui
UiTheme.roundify(panel, 18)
local panelStroke = Instance.new("UIStroke")
panelStroke.Thickness = 4
panelStroke.Color = UiTheme.ink
panelStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
panelStroke.Parent = panel
local limit = Instance.new("UISizeConstraint")
limit.MaxSize = Vector2.new(560, 560)
limit.MinSize = Vector2.new(240, 260)
limit.Parent = panel
local panelScale = Instance.new("UIScale")
panelScale.Parent = panel

local title = Instance.new("TextLabel")
title.Name = "Title"
title.BackgroundTransparency = 1
title.Position = UDim2.fromScale(0.04, 0.02)
title.Size = UDim2.fromScale(0.6, 0.09)
title.Text = "SHOP"
title.Font = UiTheme.headerFont
title.TextScaled = true
title.TextXAlignment = Enum.TextXAlignment.Left
title.TextColor3 = UiTheme.accent
title.ZIndex = 2
title.Parent = panel
local titleStroke = Instance.new("UIStroke")
titleStroke.Thickness = 3
titleStroke.Color = UiTheme.ink
titleStroke.Parent = title

local scroll = Instance.new("ScrollingFrame")
scroll.Name = "List"
scroll.Position = UDim2.fromScale(0.03, 0.13)
scroll.Size = UDim2.fromScale(0.94, 0.85)
scroll.BackgroundTransparency = 1
scroll.BorderSizePixel = 0
scroll.ScrollBarThickness = 6
scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
scroll.CanvasSize = UDim2.new()
scroll.ZIndex = 2
scroll.Parent = panel
local layout = Instance.new("UIGridLayout")
layout.CellSize = UDim2.new(0.5, -6, 0, 86)
layout.CellPadding = UDim2.fromOffset(6, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = scroll
local listPad = Instance.new("UIPadding")
listPad.PaddingRight = UDim.new(0, 8)
listPad.PaddingBottom = UDim.new(0, 8)
listPad.Parent = scroll

local function makeLabel(parent, name, pos, size, color)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Position = pos
	l.Size = size
	l.Font = UiTheme.font
	l.TextScaled = true
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.TextColor3 = color
	l.ZIndex = 4
	l.Parent = parent
	local cap = Instance.new("UITextSizeConstraint")
	cap.MinTextSize = 10
	cap.MaxTextSize = 24
	cap.Parent = l
	return l
end

local function refresh()
	for _, c in ipairs(cards) do
		local u = c.upgrade
		local owned = ownedSet[u.id] == true
		local reqName = nil
		if u.requires and not ownedSet[u.requires] then
			local req = Upgrades.byId[u.requires]
			reqName = req and req.name or tostring(u.requires)
		end
		local dimmed = (not owned) and cash < u.cost
		c.frame.BackgroundTransparency = dimmed and 0.45 or 0
		c.name.TextColor3 = dimmed and UiTheme.locked or UiTheme.text
		c.effect.TextColor3 = dimmed and UiTheme.locked or UiTheme.text
		c.cost.TextColor3 = dimmed and UiTheme.locked or UiTheme.text
		c.swatch.BackgroundTransparency = dimmed and 0.5 or 0
		c.cost.Text = "$" .. tostring(u.cost)
		local b = c.button
		if owned then
			b.Text = "Owned"
			b.BackgroundColor3 = UiTheme.dim
			b.AutoButtonColor = false
			b.Active = false
		elseif reqName then
			b.Text = "Locked (needs " .. reqName .. ")"
			b.BackgroundColor3 = UiTheme.locked
			b.AutoButtonColor = false
			b.Active = true
		else
			b.Text = "Buy"
			b.BackgroundColor3 = dimmed and UiTheme.dim or UiTheme.good
			b.AutoButtonColor = true
			b.Active = true
		end
		b.TextWrapped = true
	end
end

local function tryBuy(card)
	local u = card.upgrade
	if ownedSet[u.id] then
		return
	end
	if os.clock() - lastBuy < 0.4 then
		return
	end
	if u.requires and not ownedSet[u.requires] then
		card.button.BackgroundColor3 = UiTheme.bad
		task.delay(0.25, refresh)
		ShopFx.buyFail(card.frame)
		return
	end
	if cash < u.cost then
		local b = card.button
		b.BackgroundColor3 = UiTheme.bad
		task.delay(0.25, refresh)
		ShopFx.buyFail(card.frame)
		return
	end
	lastBuy = os.clock()
	local token = { card = card }
	pendingBuy = token
	buyRemote:FireServer(u.id)
	task.delay(2, function()
		if pendingBuy == token then
			pendingBuy = nil
			ShopFx.buyFail(card.frame)
		end
	end)
end

for i, u in ipairs(Upgrades.list) do
	local frame = Instance.new("Frame")
	frame.Name = "Card_" .. u.id
	frame.Size = UDim2.new(0.5, -6, 0, 86)
	frame.BackgroundColor3 = UiTheme.card
	frame.BorderSizePixel = 0
	frame.LayoutOrder = i
	frame.ZIndex = 3
	frame.Parent = scroll
	UiTheme.roundify(frame, 12)
	local fs = Instance.new("UIStroke")
	fs.Thickness = 2
	fs.Color = UiTheme.ink
	fs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	fs.Parent = frame

	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.Position = UDim2.new(0, 6, 0.5, 0)
	swatch.AnchorPoint = Vector2.new(0, 0.5)
	swatch.Size = UDim2.fromOffset(30, 30)
	swatch.BackgroundColor3 = swatchColor(u)
	swatch.BorderSizePixel = 0
	swatch.ZIndex = 4
	swatch.Parent = frame
	UiTheme.roundify(swatch, 10)
	local ss = Instance.new("UIStroke")
	ss.Thickness = 2
	ss.Color = UiTheme.ink
	ss.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	ss.Parent = swatch

	local nameL = makeLabel(frame, "Name", UDim2.new(0, 42, 0, 4), UDim2.new(1, -124, 0, 24), UiTheme.text)
	nameL.Text = u.name
	nameL.Font = UiTheme.headerFont
	local effL = makeLabel(frame, "Effect", UDim2.new(0, 42, 0, 30), UDim2.new(1, -124, 0, 18), UiTheme.text)
	effL.Text = effectText(u)
	local costL = makeLabel(frame, "Cost", UDim2.new(0, 42, 0, 52), UDim2.new(1, -124, 0, 26), UiTheme.text)
	costL.Text = "$" .. tostring(u.cost)
	costL.Font = UiTheme.headerFont

	local card = { upgrade = u, frame = frame, swatch = swatch, name = nameL, effect = effL, cost = costL }
	local button = UiTheme.makeButton({
		name = "State",
		text = "Buy",
		size = UDim2.fromOffset(70, 56),
		position = UDim2.new(1, -6, 0.5, 0),
		anchorPoint = Vector2.new(1, 0.5),
		color = UiTheme.good,
		zIndex = 5,
		parent = frame,
		onClick = function()
			tryBuy(card)
		end,
	})
	card.button = button
	cards[#cards + 1] = card
end

-- Open/close
local isOpen = false
local function setOpen(open)
	if open == isOpen then
		return
	end
	isOpen = open
	if open then
		ShopFx.openPanel(panel)
		syncRemote:FireServer(true)
		refresh()
	else
		local tw = TweenService:Create(panelScale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0 })
		tw.Completed:Connect(function()
			if not isOpen then
				panel.Visible = false
			end
		end)
		tw:Play()
	end
end

UiTheme.makeButton({
	name = "Close",
	text = "X",
	size = UDim2.fromOffset(48, 48),
	position = UDim2.new(1, -8, 0, 6),
	anchorPoint = Vector2.new(1, 0),
	color = UiTheme.bad,
	zIndex = 6,
	parent = panel,
	onClick = function()
		setOpen(false)
	end,
})

UiTheme.makeButton({
	name = "ShopButton",
	text = "SHOP",
	size = UDim2.fromOffset(84, 52),
	position = UDim2.new(0, 8, 0.5, 0),
	anchorPoint = Vector2.new(0, 0.5),
	color = UiTheme.accent,
	textColor = UiTheme.cream,
	zIndex = 10,
	parent = gui,
	onClick = function()
		setOpen(not isOpen)
	end,
})

syncRemote.OnClientEvent:Connect(function(ownedIds)
	if type(ownedIds) ~= "table" then
		return
	end
	local set = {}
	for _, id in ipairs(ownedIds) do
		if type(id) == "string" then
			set[id] = true
		end
	end
	ownedSet = set
	refresh()
	local pending = pendingBuy
	if pending and ownedSet[pending.card.upgrade.id] then
		pendingBuy = nil
		local level = 0
		for _ in pairs(ownedSet) do
			level += 1
		end
		ShopFx.buySuccess(pending.card.frame, level, #Upgrades.list)
	end
end)

gui.Parent = playerGui
refresh()

-- Keep ownedSet in sync with pad purchases
task.spawn(function()
	local upgradeBought = ReplicatedStorage:WaitForChild("UpgradeBought", 10)
	if not upgradeBought or not upgradeBought:IsA("RemoteEvent") then
		return
	end
	upgradeBought.OnClientEvent:Connect(function(a)
		local id = nil
		if type(a) == "string" then
			id = a
		elseif type(a) == "table" then
			local v = a.id or a.Id or a.upgradeId
			if type(v) == "string" then
				id = v
			end
		end
		if id then
			ownedSet[id] = true
			refresh()
		end
		syncRemote:FireServer(false)
	end)
end)

-- Cash leaderstat tracking (non-blocking)
task.spawn(function()
	local stats = player:WaitForChild("leaderstats", 15)
	if not stats then
		return
	end
	local cashValue = stats:WaitForChild("Cash", 15)
	if not cashValue then
		return
	end
	cash = cashValue.Value
	refresh()
	local rebirths = stats:FindFirstChild("Rebirths")
	if rebirths then
		rebirths.Changed:Connect(function()
			syncRemote:FireServer(false)
		end)
	end
	cashValue.Changed:Connect(function(v)
		local old = cash
		cash = v
		if old > 0 and v < old * 0.5 then
			syncRemote:FireServer(false)
		end
		refresh()
	end)
end)
