--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets", 10))
local NumberFormat = require(ReplicatedStorage:WaitForChild("NumberFormat", 10))
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme", 10))

local function safe(fn, ...)
	if type(fn) ~= "function" then
		return
	end
	local ok, err = pcall(fn, ...)
	if not ok then
		warn("JuiceFx: " .. tostring(err))
	end
end

local function findRemote(name: string): Instance?
	local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
	if remotes then
		local r = remotes:WaitForChild(name, 10)
		if r then
			return r
		end
	end
	return ReplicatedStorage:WaitForChild(name, 3)
end

local fxRemote = findRemote("JuiceFx")
local ackRemote = findRemote("JuiceAck")
if not fxRemote then
	warn("JuiceFx remote missing; JuiceFx disabled")
	return
end

local playerGui = player:WaitForChild("PlayerGui")

-- ===== UI =====
local function stroke(gui: GuiObject, px: number, border: boolean?)
	local s = Instance.new("UIStroke")
	s.Thickness = px
	s.Color = UiTheme.ink
	s.ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual
	s.Parent = gui
end

local function corner(gui: GuiObject, r: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r)
	c.Parent = gui
end

local function tween(inst: Instance, t: number, props, style: Enum.EasingStyle?)
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function pop(gui: GuiObject, t: number)
	local s = Instance.new("UIScale")
	s.Name = "Juice"
	s.Scale = 0
	s.Parent = gui
	tween(s, t, { Scale = 1 }, Enum.EasingStyle.Back)
	return s
end

local screen = Instance.new("ScreenGui")
screen.Name = "JuiceFx"
screen.ResetOnSpawn = false
screen.IgnoreGuiInset = true
screen.DisplayOrder = 8
screen.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
screen.Parent = playerGui

-- income label + goal bar (top right, under the cash counter)
local hudFrame = Instance.new("Frame")
hudFrame.Name = "IncomeGoal"
hudFrame.AnchorPoint = Vector2.new(1, 0)
hudFrame.Position = UDim2.new(1, -16, 0, 96)
hudFrame.Size = UDim2.fromOffset(240, 92)
hudFrame.BackgroundTransparency = 1
hudFrame.Parent = screen

local incomeLabel = Instance.new("TextLabel")
incomeLabel.Size = UDim2.new(1, 0, 0, 34)
incomeLabel.BackgroundTransparency = 1
incomeLabel.Font = UiTheme.headerFont
incomeLabel.TextScaled = true
incomeLabel.TextColor3 = UiTheme.good
incomeLabel.TextXAlignment = Enum.TextXAlignment.Right
incomeLabel.Text = "+$0/s"
incomeLabel.Visible = false
stroke(incomeLabel, 3)
incomeLabel.Parent = hudFrame

local goalLabel = Instance.new("TextLabel")
goalLabel.Position = UDim2.fromOffset(0, 38)
goalLabel.Size = UDim2.new(1, 0, 0, 24)
goalLabel.BackgroundTransparency = 1
goalLabel.Font = UiTheme.font
goalLabel.TextScaled = true
goalLabel.TextColor3 = UiTheme.cream
goalLabel.TextXAlignment = Enum.TextXAlignment.Right
goalLabel.Text = "Next goal"
stroke(goalLabel, 2.5)
goalLabel.Parent = hudFrame

local barBack = Instance.new("Frame")
barBack.Position = UDim2.fromOffset(0, 66)
barBack.Size = UDim2.new(1, 0, 0, 20)
barBack.BackgroundColor3 = UiTheme.ink
barBack.BackgroundTransparency = 0.25
corner(barBack, 10)
stroke(barBack, 3, true)
barBack.Parent = hudFrame

local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = UiTheme.accent
corner(barFill, 10)
barFill.Parent = barBack

-- toasts
local toastList = Instance.new("Frame")
toastList.AnchorPoint = Vector2.new(0.5, 0)
toastList.Position = UDim2.new(0.5, 0, 0, 120)
toastList.Size = UDim2.fromOffset(420, 200)
toastList.BackgroundTransparency = 1
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = toastList
toastList.Parent = screen

local function toast(text: string, color: Color3?)
	if type(GameAssets.toast) == "function" then
		local ok = pcall(GameAssets.toast, text, color)
		if ok then
			return
		end
	end
	if #toastList:GetChildren() > 3 then
		return
	end
	local f = Instance.new("TextLabel")
	f.Size = UDim2.fromOffset(380, 48)
	f.BackgroundColor3 = color or UiTheme.ink
	f.Text = text
	f.Font = UiTheme.font
	f.TextScaled = true
	f.TextColor3 = UiTheme.cream
	corner(f, 24)
	stroke(f, 3, true)
	stroke(f, 2.5)
	f.Parent = toastList
	local s = pop(f, 0.25)
	task.delay(2.2, function()
		tween(s, 0.2, { Scale = 0 }).Completed:Wait()
		f:Destroy()
	end)
end

local function rewardPopup(title: string, amount: string, color: Color3)
	local root = Instance.new("Frame")
	root.Size = UDim2.fromOffset(420, 420)
	root.AnchorPoint = Vector2.new(0.5, 0.5)
	root.Position = UDim2.fromScale(0.5, 0.42)
	root.BackgroundTransparency = 1
	root.ZIndex = 30
	root.Parent = screen
	local rays = Instance.new("Frame")
	rays.Size = UDim2.fromScale(1, 1)
	rays.AnchorPoint = Vector2.new(0.5, 0.5)
	rays.Position = UDim2.fromScale(0.5, 0.5)
	rays.BackgroundTransparency = 1
	rays.ZIndex = 30
	rays.Parent = root
	for i = 0, 5 do
		local r = Instance.new("Frame")
		r.Size = UDim2.new(0, 34, 1, 0)
		r.AnchorPoint = Vector2.new(0.5, 0.5)
		r.Position = UDim2.fromScale(0.5, 0.5)
		r.Rotation = i * 30
		r.BackgroundColor3 = color
		r.BackgroundTransparency = 0.55
		r.BorderSizePixel = 0
		r.ZIndex = 30
		local g = Instance.new("UIGradient")
		g.Rotation = 90
		g.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 1),
			NumberSequenceKeypoint.new(0.5, 0),
			NumberSequenceKeypoint.new(1, 1),
		})
		g.Parent = r
		r.Parent = rays
	end
	local card = Instance.new("Frame")
	card.Size = UDim2.fromOffset(340, 170)
	card.AnchorPoint = Vector2.new(0.5, 0.5)
	card.Position = UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3 = color
	card.ZIndex = 31
	corner(card, 22)
	stroke(card, 5, true)
	card.Parent = root
	for i, t in { title, amount } do
		local l = Instance.new("TextLabel")
		l.Size = UDim2.new(1, -24, 0.42, 0)
		l.Position = UDim2.new(0, 12, 0, 0)
		l.Position = UDim2.new(0, 12, if i == 1 then 0.08 else 0.5, 0)
		l.BackgroundTransparency = 1
		l.Text = t
		l.ZIndex = 32
		l.Font = UiTheme.headerFont
		l.TextScaled = true
		l.TextColor3 = UiTheme.cream
		stroke(l, if i == 1 then 3 else 4)
		l.Parent = card
	end
	local s = pop(root, 0.45)
	task.spawn(function()
		while rays.Parent do
			rays.Rotation += 1.2
			task.wait()
		end
	end)
	task.delay(2.5, function()
		tween(s, 0.2, { Scale = 0 }).Completed:Wait()
		root:Destroy()
	end)
end

local flash = Instance.new("Frame")
flash.Size = UDim2.fromScale(1, 1)
flash.BackgroundColor3 = Color3.new(1, 1, 1)
flash.BackgroundTransparency = 1
flash.BorderSizePixel = 0
flash.ZIndex = 50
flash.Parent = screen

local function whiteFlash()
	flash.BackgroundTransparency = 0
	tween(flash, 1.2, { BackgroundTransparency = 1 })
end

-- ===== income tracking =====
local samples = {}
local lastCash: number? = nil
local incomeShown = false
local lastAck = 0

local function ack()
	if ackRemote and ackRemote:IsA("RemoteEvent") then
		ackRemote:FireServer("income")
	end
end

local function refreshIncome()
	local now = os.clock()
	local total = 0
	local kept = {}
	for _, smp in samples do
		if now - smp[1] <= 5 then
			total += smp[2]
			table.insert(kept, smp)
		end
	end
	samples = kept
	local perSec = total / 5
	incomeLabel.Text = "+$" .. NumberFormat.short(math.floor(perSec + 0.5)) .. "/s"
	if perSec > 0 and not incomeLabel.Visible then
		incomeLabel.Visible = true
	end
	if incomeLabel.Visible and (not incomeShown or now - lastAck >= 5) then
		incomeShown = true
		lastAck = now
		ack()
	end
end

-- goal bar
local goalName = ""
local goalCost = 0
local cashValue: number = 0

local function refreshGoal()
	if goalCost > 0 then
		goalLabel.Text = string.format("Next: %s ($%s)", goalName, NumberFormat.short(goalCost))
		local frac = math.clamp(cashValue / goalCost, 0, 1)
		tween(barFill, 0.2, { Size = UDim2.fromScale(frac, 1) })
		barFill.BackgroundColor3 = if frac >= 1 then UiTheme.good else UiTheme.accent
	else
		goalLabel.Text = "Next goal"
		barFill.Size = UDim2.fromScale(0, 1)
	end
end

local function applyGoalAttributes()
	local name = player:GetAttribute("NextGoalName")
	local cost = player:GetAttribute("NextGoalCost")
	if name == nil and cost == nil then
		return
	end
	if name ~= nil then
		goalName = tostring(name)
	end
	goalCost = if type(cost) == "number" then cost else 0
	refreshGoal()
end

player:GetAttributeChangedSignal("NextGoalName"):Connect(applyGoalAttributes)
player:GetAttributeChangedSignal("NextGoalCost"):Connect(applyGoalAttributes)
applyGoalAttributes()

task.spawn(function()
	local stats = player:WaitForChild("leaderstats", 30)
	local cash = stats and stats:WaitForChild("Cash", 30)
	if not cash then
		warn("JuiceFx: Cash leaderstat not found")
		return
	end
	lastCash = cash.Value
	cashValue = cash.Value
	cash.Changed:Connect(function(v)
		if type(v) ~= "number" then
			return
		end
		if lastCash and v > lastCash then
			table.insert(samples, { os.clock(), v - lastCash })
		end
		lastCash = v
		cashValue = v
		refreshGoal()
		refreshIncome()
	end)
	refreshGoal()
	while screen.Parent do
		refreshIncome()
		task.wait(1)
	end
end)

-- ===== remote events =====
local function field(data, key: string)
	if type(data) == "table" then
		return data[key]
	end
	return nil
end

local function toPosition(data): Vector3?
	local p = field(data, "position")
	if typeof(p) == "Vector3" then
		return p
	end
	local pad = field(data, "pad")
	if typeof(pad) == "Instance" and pad:IsA("BasePart") then
		return pad.Position
	end
	return nil
end

local function onFx(kind, data)
	if type(kind) ~= "string" then
		return
	end
	if kind == "buy" then
		local name = field(data, "name")
		if name == nil and type(data) == "string" then
			name = data
		end
		safe(GameAssets.play, "Buy")
		local pos = toPosition(data)
		if pos then
			safe(GameAssets.burst, pos, UiTheme.accent, 24)
		end
		safe(GameAssets.shake, 0.3, 0.2)
		toast("Unlocked: " .. tostring(name or "Upgrade") .. "!", UiTheme.good)
	elseif kind == "poor" then
		local need = field(data, "need")
		if type(data) == "number" then
			need = data
		end
		if type(need) ~= "number" then
			local cost = field(data, "cost")
			need = if type(cost) == "number" then math.max(0, cost - cashValue) else 0
		end
		safe(GameAssets.play, "Error")
		toast("Need $" .. NumberFormat.short(need) .. " more", UiTheme.bad)
	elseif kind == "ore" then
		local value = field(data, "value")
		if type(data) == "number" then
			value = data
		end
		safe(GameAssets.play, "Win")
		rewardPopup("GOLD ORE!", "$" .. NumberFormat.short(value or 0) .. " per cube", UiTheme.accent)
		safe(GameAssets.shake, 0.5, 0.3)
	elseif kind == "rebirth" then
		safe(GameAssets.play, "Boom")
		task.delay(0.4, function()
			safe(GameAssets.play, "Win")
		end)
		safe(GameAssets.shake, 1, 0.6)
		whiteFlash()
	elseif kind == "goal" then
		local name = field(data, "name")
		local cost = field(data, "cost")
		goalName = tostring(name or "Upgrade")
		goalCost = if type(cost) == "number" then cost else 0
		refreshGoal()
	end
end

if fxRemote:IsA("RemoteEvent") then
	fxRemote.OnClientEvent:Connect(onFx)
else
	warn("JuiceFx: remote is not a RemoteEvent")
end
