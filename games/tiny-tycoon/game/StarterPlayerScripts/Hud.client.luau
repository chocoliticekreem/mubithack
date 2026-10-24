--!strict
-- Hud.client.luau: UI only. Shows Cash and toast messages from the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config", 10) :: ModuleScript) :: any

local NumberFormat: any = nil
do
	local nfModule = ReplicatedStorage:WaitForChild("NumberFormat", 10)
	if nfModule and nfModule:IsA("ModuleScript") then
		local ok, result = pcall(require, nfModule)
		if ok then
			NumberFormat = result
		end
	end
end

-- All big numbers written to the HUD go through the shared formatter.
local function short(n: number): string
	if NumberFormat and type(NumberFormat.short) == "function" then
		local ok, text = pcall(NumberFormat.short, n)
		if ok and type(text) == "string" then
			return text
		end
	end
	return tostring(math.floor(n))
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui", 10)
if not playerGui then
	return
end

local CASH_COLOR = Color3.fromRGB(40, 190, 90)
local CASH_FLASH_COLOR = Color3.fromRGB(150, 255, 120)

-- Build UI
local gui = Instance.new("ScreenGui")
gui.Name = "TycoonHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false
gui.DisplayOrder = 5

local cashFrame = Instance.new("Frame")
cashFrame.Name = "CashFrame"
cashFrame.AnchorPoint = Vector2.new(0.5, 0)
cashFrame.Position = UDim2.fromScale(0.5, 0.02)
cashFrame.Size = UDim2.fromScale(0.28, 0.09)
cashFrame.BackgroundColor3 = CASH_COLOR
cashFrame.BorderSizePixel = 0
cashFrame.Parent = gui

local cashCorner = Instance.new("UICorner")
cashCorner.CornerRadius = UDim.new(0.25, 0)
cashCorner.Parent = cashFrame

local cashStroke = Instance.new("UIStroke")
cashStroke.Color = Color3.fromRGB(255, 255, 255)
cashStroke.Thickness = 3
cashStroke.Parent = cashFrame

local cashScale = Instance.new("UIScale")
cashScale.Scale = 1
cashScale.Parent = cashFrame

local cashLabel = Instance.new("TextLabel")
cashLabel.Name = "CashLabel"
cashLabel.Size = UDim2.fromScale(1, 1)
cashLabel.BackgroundTransparency = 1
cashLabel.Font = Enum.Font.GothamBlack
cashLabel.TextScaled = true
cashLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
cashLabel.Text = "Cash: 0"
cashLabel.Parent = cashFrame

local cashTextStroke = Instance.new("UIStroke")
cashTextStroke.Color = Color3.fromRGB(28, 22, 38)
cashTextStroke.Thickness = 2.5
cashTextStroke.Parent = cashLabel

local cashPad = Instance.new("UIPadding")
cashPad.PaddingTop = UDim.new(0.12, 0)
cashPad.PaddingBottom = UDim.new(0.12, 0)
cashPad.Parent = cashLabel

local toast = Instance.new("TextLabel")
toast.Name = "Toast"
toast.AnchorPoint = Vector2.new(0.5, 0.5)
toast.Position = UDim2.fromScale(0.5, 0.75)
toast.Size = UDim2.fromScale(0.35, 0.07)
toast.BackgroundColor3 = Color3.fromRGB(255, 210, 40)
toast.BackgroundTransparency = 1
toast.TextTransparency = 1
toast.Font = Enum.Font.GothamBlack
toast.TextScaled = true
toast.TextColor3 = Color3.fromRGB(40, 40, 40)
toast.Text = ""
toast.Parent = gui

local toastCorner = Instance.new("UICorner")
toastCorner.CornerRadius = UDim.new(0.3, 0)
toastCorner.Parent = toast

gui.Parent = playerGui

-- Juice helpers
local function formatCash(n: number): string
	return "Cash: " .. short(n)
end

local popupCounter = 0
local function floatPopup(amount: number)
	popupCounter += 1
	local label = Instance.new("TextLabel")
	label.Name = "Popup" .. popupCounter
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	local xOffset = (math.random() - 0.5) * 0.1
	label.Position = UDim2.fromScale(0.5 + xOffset, 0.21)
	label.Size = UDim2.fromScale(0.1, 0.05)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(120, 255, 120)
	label.Text = "+" .. short(amount)
	label.ZIndex = 5

	local stroke = Instance.new("UIStroke")
	stroke.Color = Color3.fromRGB(28, 22, 38)
	stroke.Thickness = 2.5
	stroke.Parent = label

	label.Parent = gui

	local info = TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(label, info, {
		Position = UDim2.fromScale(0.5 + xOffset, 0.15),
		TextTransparency = 1,
	}):Play()
	TweenService:Create(stroke, info, { Transparency = 1 }):Play()
	task.delay(0.9, function()
		label:Destroy()
	end)
end

local function pulseCash()
	cashScale.Scale = 1.18
	TweenService:Create(cashScale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Scale = 1,
	}):Play()
	cashFrame.BackgroundColor3 = CASH_FLASH_COLOR
	TweenService:Create(cashFrame, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		BackgroundColor3 = CASH_COLOR,
	}):Play()
end

-- Cash binding
local lastCash = 0
local firstRefresh = true
local function bindCash(cash: ValueBase)
	local cashAny = cash :: any
	local function refresh()
		local v = cashAny.Value
		if type(v) == "number" then
			cashLabel.Text = formatCash(v)
			if v > lastCash and not firstRefresh then
				pulseCash()
				floatPopup(v - lastCash)
			end
			firstRefresh = false
			lastCash = v
		end
	end
	refresh()
	cashAny:GetPropertyChangedSignal("Value"):Connect(refresh)
end

task.spawn(function()
	local stats = player:WaitForChild("leaderstats", 30)
	if not stats then
		return
	end
	local cash = stats:WaitForChild("Cash", 30)
	if cash and (cash:IsA("IntValue") or cash:IsA("NumberValue")) then
		bindCash(cash :: ValueBase)
	end
end)

-- Toast
local toastToken = 0
local function showToast(msg: string)
	toastToken += 1
	local myToken = toastToken
	toast.Text = msg
	toast.BackgroundTransparency = 0
	toast.TextTransparency = 0
	toast.Position = UDim2.fromScale(0.5, 0.78)
	TweenService:Create(toast, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Position = UDim2.fromScale(0.5, 0.75),
	}):Play()
	task.delay(2.5, function()
		if myToken ~= toastToken then
			return
		end
		TweenService:Create(toast, TweenInfo.new(0.4), {
			BackgroundTransparency = 1,
			TextTransparency = 1,
		}):Play()
	end)
end

task.spawn(function()
	local remotes = ReplicatedStorage:WaitForChild(Config.REMOTES_FOLDER, 10)
	if not remotes then
		return
	end
	local notify = remotes:WaitForChild(Config.REMOTE_NOTIFY, 10)
	if notify and notify:IsA("RemoteEvent") then
		notify.OnClientEvent:Connect(function(msg: any)
			if type(msg) == "string" then
				showToast(string.sub(msg, 1, 80))
			end
		end)
	end
end)
