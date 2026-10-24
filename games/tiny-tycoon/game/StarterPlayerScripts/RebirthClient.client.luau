--!strict
-- RebirthClient: client-only UI for the Rebirth feature (button, golden flash, banner, toast).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local RebirthConfig = require(ReplicatedStorage:WaitForChild("RebirthConfig"))

local player = Players.LocalPlayer

-- Theme ---------------------------------------------------------------
local Theme = {
	Ink = Color3.fromRGB(28, 22, 38), Cream = Color3.fromRGB(255, 248, 232),
	Primary = Color3.fromRGB(255, 196, 41), Good = Color3.fromRGB(88, 214, 92),
	Bad = Color3.fromRGB(240, 68, 64),
	Header = Enum.Font.LuckiestGuy, Body = Enum.Font.FredokaOne, Stroke = 3, Radius = 12,
}

function Theme.corner(gui: GuiObject, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or Theme.Radius)
	c.Parent = gui
end

function Theme.stroke(gui: GuiObject, px: number?, color: Color3?, border: boolean?): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness = px or Theme.Stroke
	s.Color = color or Theme.Ink
	s.ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual
	s.Parent = gui
	return s
end

function Theme.gradient(gui: GuiObject, base: Color3)
	local g = Instance.new("UIGradient")
	g.Rotation = 90
	g.Color = ColorSequence.new(base:Lerp(Color3.new(1, 1, 1), 0.35), base:Lerp(Color3.new(), 0.12))
	g.Parent = gui
end

function Theme.tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function juiceScale(gui: GuiObject): UIScale
	local existing = gui:FindFirstChild("Juice")
	local s: UIScale = if existing then existing :: UIScale else Instance.new("UIScale")
	s.Name = "Juice"
	s.Parent = gui
	return s
end

function Theme.pop(gui: GuiObject, t: number?)
	local s = juiceScale(gui)
	s.Scale = 0
	Theme.tween(s, t or 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function makeScreen(name: string, order: number, scaled: boolean): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = name, false, order
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	if scaled then
		gui.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
		local scale = Instance.new("UIScale")
		local cam = workspace.CurrentCamera or workspace:WaitForChild("Camera", 10)
		if cam then
			local camera = cam :: Camera
			local function fit()
				local v = camera.ViewportSize
				scale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.6, 1.4)
			end
			fit()
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
		end
		scale.Parent = gui
	else
		gui.ScreenInsets = Enum.ScreenInsets.None
	end
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

-- Remotes -------------------------------------------------------------
local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
if not remotes then
	warn("RebirthClient: Remotes folder missing")
	return
end
local requestRemoteInst = remotes:WaitForChild("RebirthRequest", 10)
local resultRemoteInst = remotes:WaitForChild("RebirthResult", 10)
if not (requestRemoteInst and requestRemoteInst:IsA("RemoteEvent") and resultRemoteInst and resultRemoteInst:IsA("RemoteEvent")) then
	warn("RebirthClient: Rebirth remotes missing")
	return
end
local requestRemote: RemoteEvent = requestRemoteInst :: RemoteEvent
local resultRemote: RemoteEvent = resultRemoteInst :: RemoteEvent

-- UI ------------------------------------------------------------------
local gui = makeScreen("RebirthGui", 5, true)
local fxGui = makeScreen("RebirthFx", 50, false)

local button = Instance.new("TextButton")
button.Name = "RebirthButton"
button.AnchorPoint = Vector2.new(0.5, 0.5)
button.Size = UDim2.fromOffset(200, 60)
button.Position = UDim2.new(1, -120, 0.62, 0)
button.BackgroundColor3 = RebirthConfig.altarColor
button.AutoButtonColor = false
button.BorderSizePixel = 0
button.Font = Theme.Header
button.TextScaled = true
button.TextColor3 = Theme.Cream
button.Text = "REBIRTH"
button.Parent = gui
Theme.corner(button, 14)
Theme.gradient(button, RebirthConfig.altarColor)
Theme.stroke(button, 3, nil, true)
Theme.stroke(button, 3)
local pad = Instance.new("UIPadding")
pad.PaddingTop, pad.PaddingBottom = UDim.new(0.16, 0), UDim.new(0.16, 0)
pad.Parent = button
local btnScale = Instance.new("UIScale")
btnScale.Parent = button
button.MouseEnter:Connect(function() Theme.tween(btnScale, 0.1, { Scale = 1.06 }) end)
button.MouseLeave:Connect(function() Theme.tween(btnScale, 0.1, { Scale = 1 }) end)
button.MouseButton1Down:Connect(function() Theme.tween(btnScale, 0.06, { Scale = 0.9 }) end)
button.MouseButton1Up:Connect(function() Theme.tween(btnScale, 0.2, { Scale = 1 }, Enum.EasingStyle.Back) end)
Theme.pop(button, 0.4)

local toastList = Instance.new("Frame")
toastList.Size = UDim2.fromOffset(420, 200)
toastList.AnchorPoint = Vector2.new(0.5, 0)
toastList.Position = UDim2.new(0.5, 0, 0, 70)
toastList.BackgroundTransparency = 1
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = toastList
toastList.Parent = gui

local function toast(text: string, color: Color3?)
	if #toastList:GetChildren() > 3 then return end
	local f = Instance.new("TextLabel")
	f.Size = UDim2.fromOffset(380, 48)
	f.BackgroundColor3 = color or Theme.Ink
	f.ZIndex = 20
	f.Text = text
	f.Font = Theme.Body
	f.TextScaled = true
	f.TextColor3 = Theme.Cream
	Theme.corner(f, 24)
	Theme.stroke(f, 3, Theme.Ink, true)
	Theme.stroke(f, 2.5)
	local p = Instance.new("UIPadding")
	p.PaddingTop, p.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	p.Parent = f
	f.Parent = toastList
	Theme.pop(f, 0.25)
	task.delay(2.2, function()
		local s = f:FindFirstChild("Juice")
		if s then
			Theme.tween(s, 0.2, { Scale = 0 }).Completed:Wait()
		end
		f:Destroy()
	end)
end

-- State ---------------------------------------------------------------
local cashValue: ValueBase? = nil
local rebirthValue: ValueBase? = nil

local function currentRebirths(): number
	if rebirthValue then
		local v = (rebirthValue :: any).Value
		if type(v) == "number" then return v end
	end
	return 0
end

local function currentCash(): number
	if cashValue then
		local v = (cashValue :: any).Value
		if type(v) == "number" then return v end
	end
	return 0
end

local function formatNum(n: number): string
	if n >= 1e6 then return string.format("%.1fM", n / 1e6) end
	if n >= 1e4 then return string.format("%.1fK", n / 1e3) end
	return tostring(math.floor(n))
end

local function refresh()
	local cost = RebirthConfig.costFor(currentRebirths())
	local ready = currentCash() >= cost
	button.Text = "REBIRTH $" .. formatNum(cost)
	button.BackgroundTransparency = if ready then 0 else 0.45
end

task.spawn(function()
	local stats = player:WaitForChild("leaderstats", 10)
	if not stats then return end
	local cash = stats:WaitForChild("Cash", 10)
	local rebirths = stats:WaitForChild("Rebirths", 10)
	if cash and cash:IsA("ValueBase") then
		cashValue = cash
		cash:GetPropertyChangedSignal("Value"):Connect(refresh)
	end
	if rebirths and rebirths:IsA("ValueBase") then
		rebirthValue = rebirths
		rebirths:GetPropertyChangedSignal("Value"):Connect(refresh)
	end
	refresh()
end)
refresh()

-- Effects -------------------------------------------------------------
local function playSuccess()
	task.wait(0.15) -- let the Rebirths leaderstat replicate
	local flash = Instance.new("Frame")
	flash.Size = UDim2.fromScale(1, 1)
	flash.BackgroundColor3 = RebirthConfig.flashColor
	flash.BackgroundTransparency = 0.1
	flash.BorderSizePixel = 0
	flash.ZIndex = 1
	flash.Parent = fxGui
	Theme.tween(flash, RebirthConfig.flashDuration, { BackgroundTransparency = 1 }).Completed:Connect(function()
		flash:Destroy()
	end)

	local banner = Instance.new("TextLabel")
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.4)
	banner.Size = UDim2.fromScale(0.6, 0.18)
	banner.BackgroundTransparency = 1
	banner.Font = Theme.Header
	banner.TextScaled = true
	banner.TextColor3 = Color3.fromRGB(255, 232, 110)
	banner.Text = RebirthConfig.bannerText(currentRebirths())
	banner.ZIndex = 5
	local st = Theme.stroke(banner, 4)
	banner.Parent = fxGui
	Theme.pop(banner, 0.4)
	task.delay(RebirthConfig.bannerDuration, function()
		Theme.tween(banner, 0.5, { TextTransparency = 1 })
		Theme.tween(st, 0.5, { Transparency = 1 }).Completed:Connect(function()
			banner:Destroy()
		end)
	end)
end

resultRemote.OnClientEvent:Connect(function(ok: any)
	if ok == true then
		task.spawn(playSuccess)
		refresh()
	else
		toast("Not ready to rebirth", Theme.Bad)
	end
end)

local lastClick = 0
button.Activated:Connect(function()
	local now = os.clock()
	if now - lastClick < 0.5 then return end
	lastClick = now
	requestRemote:FireServer()
end)
