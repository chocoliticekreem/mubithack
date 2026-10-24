-- Toast: short stacked notifications that pop in at the top and shrink away ("+50 coins", "Not enough cash!").
local toastList: Frame? = nil
local function toast(gui: ScreenGui, text: string, color: Color3?, seconds: number?)
	if not toastList then
		local list = Instance.new("Frame")
		list.Size, list.AnchorPoint = UDim2.fromOffset(420, 200), Vector2.new(0.5, 0)
		list.Position, list.BackgroundTransparency = UDim2.new(0.5, 0, 0, 70), 1
		local layout = Instance.new("UIListLayout")
		layout.Padding, layout.HorizontalAlignment = UDim.new(0, 8), Enum.HorizontalAlignment.Center
		layout.Parent = list
		list.Parent = gui
		toastList = list
	end
	local list = toastList :: Frame
	if #list:GetChildren() > 3 then return end -- 3 visible max: drop spam instead of stacking forever
	local f = Instance.new("TextLabel")
	f.Size, f.BackgroundColor3, f.ZIndex, f.Text = UDim2.fromOffset(380, 48), color or Theme.Ink, 20, text
	f.Font, f.TextScaled, f.TextColor3 = Theme.Body, true, Theme.Cream
	Theme.corner(f, 24)
	Theme.stroke(f, 3, Theme.Ink, true)
	Theme.stroke(f, 2.5)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = f
	f.Parent = list
	Theme.pop(f, 0.25)
	task.delay(seconds or 2.2, function()
		local s = f:FindFirstChild("Juice") :: UIScale?
		if s then Theme.tween(s, 0.2, { Scale = 0 }).Completed:Wait() end
		f:Destroy()
	end)
end
