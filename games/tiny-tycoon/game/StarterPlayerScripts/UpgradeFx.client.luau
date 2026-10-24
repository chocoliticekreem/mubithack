--!strict
-- UpgradeFx: client-only toast + corner label for upgrades. Sends nothing to the server.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Upgrades = require(ReplicatedStorage:WaitForChild("Upgrades", 10) :: ModuleScript)

local remote = ReplicatedStorage:WaitForChild("UpgradeBought", 10)
if not remote or not remote:IsA("RemoteEvent") then
	return
end

-- Theme (trimmed from house kit)
local Theme = {
	Ink = Color3.fromRGB(28, 22, 38), Cream = Color3.fromRGB(255, 248, 232),
	Primary = Color3.fromRGB(255, 196, 41), Good = Color3.fromRGB(88, 214, 92),
	Info = Color3.fromRGB(64, 170, 255),
	Header = Enum.Font.LuckiestGuy, Body = Enum.Font.FredokaOne,
}

local function corner(gui: GuiObject, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 12)
	c.Parent = gui
end

local function stroke(gui: GuiObject, px: number?, border: boolean?)
	local s = Instance.new("UIStroke")
	s.Thickness = px or 3
	s.Color = Theme.Ink
	s.ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual
	s.Parent = gui
end

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function juiceScale(gui: GuiObject): UIScale
	local existing = gui:FindFirstChild("Juice")
	local s: UIScale
	if existing and existing:IsA("UIScale") then
		s = existing
	else
		s = Instance.new("UIScale")
		s.Name = "Juice"
		s.Parent = gui
	end
	return s
end

local function pop(gui: GuiObject, t: number?)
	local s = juiceScale(gui)
	s.Scale = 0
	tween(s, t or 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function punch(gui: GuiObject, amount: number?)
	local s = juiceScale(gui)
	s.Scale = 1 + (amount or 0.2)
	tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui", 10)
if not playerGui then
	return
end

local gui = Instance.new("ScreenGui")
gui.Name = "UpgradeFx"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

-- Toast list (top centre)
local toastList = Instance.new("Frame")
toastList.Name = "Toasts"
toastList.Size = UDim2.fromOffset(420, 200)
toastList.AnchorPoint = Vector2.new(0.5, 0)
toastList.Position = UDim2.new(0.5, 0, 0, 70)
toastList.BackgroundTransparency = 1
local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
layout.Parent = toastList
toastList.Parent = gui

local function toast(text: string, color: Color3?, seconds: number?)
	local count = 0
	for _, c in ipairs(toastList:GetChildren()) do
		if c:IsA("TextLabel") then
			count += 1
		end
	end
	if count >= 3 then
		return
	end
	local f = Instance.new("TextLabel")
	f.Size = UDim2.fromOffset(380, 48)
	f.BackgroundColor3 = color or Theme.Ink
	f.Text = text
	f.Font = Theme.Body
	f.TextScaled = true
	f.TextColor3 = Theme.Cream
	f.ZIndex = 20
	corner(f, 24)
	stroke(f, 3, true)
	stroke(f, 2.5)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 8)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = f
	f.Parent = toastList
	pop(f, 0.25)
	task.delay(seconds or 2.2, function()
		if not f.Parent then
			return
		end
		local s = f:FindFirstChild("Juice")
		if s and s:IsA("UIScale") then
			tween(s, 0.2, { Scale = 0 }).Completed:Wait()
		end
		f:Destroy()
	end)
end

-- Corner label (bottom right, clear of the top-left menu)
local info = Instance.new("TextLabel")
info.Name = "ModsLabel"
info.AnchorPoint = Vector2.new(1, 1)
info.Position = UDim2.new(1, -12, 1, -12)
info.Size = UDim2.fromOffset(340, 36)
info.BackgroundColor3 = Theme.Ink
info.BackgroundTransparency = 0.25
info.Font = Theme.Body
info.TextScaled = true
info.TextColor3 = Theme.Cream
info.Text = ""
corner(info, 14)
stroke(info, 3, true)
stroke(info, 2.5)
local ipad = Instance.new("UIPadding")
ipad.PaddingLeft = UDim.new(0, 10)
ipad.PaddingRight = UDim.new(0, 10)
ipad.PaddingTop = UDim.new(0, 5)
ipad.PaddingBottom = UDim.new(0, 5)
ipad.Parent = info
info.Parent = gui

local function fmt(n: number): string
	return string.format("%g", n)
end

local function updateLabel(mods: any)
	local tierIndex = 1
	local slots = 1
	local mult = 1
	if type(mods) == "table" then
		if type(mods.tier) == "number" then
			tierIndex = mods.tier
		end
		if type(mods.slots) == "number" then
			slots = mods.slots
		end
		if type(mods.cashMult) == "number" then
			mult = mods.cashMult
		end
	end
	local ore = Upgrades.ores[tierIndex] or Upgrades.ores[1]
	info.Text = "Ore: " .. ore.name .. "  Slots: " .. fmt(slots) .. "  Cash x" .. fmt(mult)
	info.TextColor3 = ore.color:Lerp(Theme.Cream, 0.5)
	punch(info, 0.12)
end

updateLabel(nil)

remote.OnClientEvent:Connect(function(upgradeId: any, mods: any)
	local name = "Upgrade"
	if type(upgradeId) == "string" then
		local up = Upgrades.byId[upgradeId]
		if up then
			name = up.name
		end
	end
	toast("Upgraded: " .. name, Theme.Good, 2.2)
	updateLabel(mods)
end)
