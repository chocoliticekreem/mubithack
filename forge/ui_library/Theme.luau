-- Theme: palette, fonts and style helpers every other UI kit snippet uses. Paste it first, once per LocalScript.
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Theme = {
	Ink = Color3.fromRGB(28, 22, 38), Cream = Color3.fromRGB(255, 248, 232),
	Primary = Color3.fromRGB(255, 196, 41), Good = Color3.fromRGB(88, 214, 92),
	Bad = Color3.fromRGB(240, 68, 64), Info = Color3.fromRGB(64, 170, 255), Gem = Color3.fromRGB(190, 92, 255),
	Header = Enum.Font.LuckiestGuy, Body = Enum.Font.FredokaOne, Stroke = 3, Radius = 12,
}

function Theme.corner(gui: GuiObject, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or Theme.Radius)
	c.Parent = gui
end

-- border=true outlines the box; default outlines the text glyphs (the chunky game look).
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

-- Hard drop shadow behind gui (same parent, ZIndex - 1). Call after gui is parented.
function Theme.shadow(gui: GuiObject, px: number?): Frame
	local sh = Instance.new("Frame")
	sh.AnchorPoint, sh.Size = gui.AnchorPoint, gui.Size
	sh.Position = gui.Position + UDim2.fromOffset(0, px or 5)
	sh.BackgroundColor3, sh.BackgroundTransparency, sh.BorderSizePixel = Theme.Ink, 0.4, 0
	sh.ZIndex = gui.ZIndex - 1
	Theme.corner(sh)
	sh.Parent = gui.Parent
	return sh
end

function Theme.tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function juiceScale(gui: GuiObject): UIScale
	local s = gui:FindFirstChild("Juice") or Instance.new("UIScale")
	s.Name, s.Parent = "Juice", gui
	return s :: UIScale
end

function Theme.pop(gui: GuiObject, t: number?) -- appear: scale 0 -> 1 with Back overshoot
	local s = juiceScale(gui)
	s.Scale = 0
	Theme.tween(s, t or 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
end

function Theme.punch(gui: GuiObject, amount: number?) -- react: 1.2 -> 1
	local s = juiceScale(gui)
	s.Scale = 1 + (amount or 0.2)
	Theme.tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Design in 1280x720 offsets; the UIScale fits it to any screen, safe insets keep it off notches.
function Theme.screen(name: string, order: number?): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = name, false, order or 0
	gui.ZIndexBehavior, gui.ScreenInsets = Enum.ZIndexBehavior.Sibling, Enum.ScreenInsets.CoreUISafeInsets
	local scale = Instance.new("UIScale")
	local cam = workspace.CurrentCamera or workspace:WaitForChild("Camera")
	local function fit()
		local v = cam.ViewportSize
		scale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.6, 1.4)
	end
	fit()
	cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	scale.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return gui
end
