--!strict
-- Hud.client.luau: UI only. Shows Cash, a hint line, and toast messages from the server.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Config = require(ReplicatedStorage:WaitForChild("Config", 10) :: ModuleScript) :: any

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui", 10)
if not playerGui then
	return
end

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
cashFrame.BackgroundColor3 = Color3.fromRGB(40, 190, 90)
cashFrame.BorderSizePixel = 0
cashFrame.Parent = gui

local cashCorner = Instance.new("UICorner")
cashCorner.CornerRadius = UDim.new(0.25, 0)
cashCorner.Parent = cashFrame

local cashStroke = Instance.new("UIStroke")
cashStroke.Color = Color3.fromRGB(255, 255, 255)
cashStroke.Thickness = 3
cashStroke.Parent = cashFrame

local cashLabel = Instance.new("TextLabel")
cashLabel.Name = "CashLabel"
cashLabel.Size = UDim2.fromScale(1, 1)
cashLabel.BackgroundTransparency = 1
cashLabel.Font = Enum.Font.GothamBlack
cashLabel.TextScaled = true
cashLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
cashLabel.Text = "Cash: 0"
cashLabel.Parent = cashFrame

local cashPad = Instance.new("UIPadding")
cashPad.PaddingTop = UDim.new(0.12, 0)
cashPad.PaddingBottom = UDim.new(0.12, 0)
cashPad.Parent = cashLabel

local hint = Instance.new("TextLabel")
hint.Name = "Hint"
hint.AnchorPoint = Vector2.new(0.5, 0)
hint.Position = UDim2.fromScale(0.5, 0.115)
hint.Size = UDim2.fromScale(0.4, 0.04)
hint.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
hint.BackgroundTransparency = 0.45
hint.Font = Enum.Font.GothamBold
hint.TextScaled = true
hint.TextColor3 = Color3.fromRGB(255, 255, 255)
hint.Text = "Touch the green pads to buy: Dropper 25 / Fast Belt 50"
hint.Parent = gui

local hintCorner = Instance.new("UICorner")
hintCorner.CornerRadius = UDim.new(0.3, 0)
hintCorner.Parent = hint

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

-- Cash binding
local function formatCash(n: number): string
	return "Cash: " .. tostring(math.floor(n))
end

local lastCash = 0
local function bindCash(cash: ValueBase)
	local cashAny = cash :: any
	local function refresh()
		local v = cashAny.Value
		if type(v) == "number" then
			cashLabel.Text = formatCash(v)
			if v > lastCash then
				cashFrame.Size = UDim2.fromScale(0.3, 0.1)
				TweenService:Create(cashFrame, TweenInfo.new(0.15, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
					Size = UDim2.fromScale(0.28, 0.09),
				}):Play()
			end
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
