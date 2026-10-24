-- Panel: a window (shop, inventory, upgrades, settings) with title tab, close X, dim backdrop, pop open/close.
local function panel(gui: ScreenGui, title: string, size: UDim2): (Frame, (boolean) -> ())
	local dim = Instance.new("Frame")
	dim.Size, dim.BackgroundColor3, dim.BackgroundTransparency = UDim2.fromScale(1, 1), Theme.Ink, 1
	dim.Visible, dim.ZIndex = false, 10
	dim.Parent = gui
	local f = Instance.new("Frame")
	f.Size, f.AnchorPoint, f.Position = size, Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
	f.BackgroundColor3, f.ZIndex = Theme.Cream, 11
	Theme.corner(f, 18)
	Theme.stroke(f, 4, nil, true)
	f.Parent = dim
	local tab = Instance.new("TextLabel")
	tab.Size, tab.AnchorPoint, tab.Position = UDim2.new(0.6, 0, 0, 52), Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0)
	tab.BackgroundColor3, tab.ZIndex, tab.Text = Theme.Info, 12, title
	tab.Font, tab.TextScaled, tab.TextColor3 = Theme.Header, true, Theme.Cream
	Theme.corner(tab, 14)
	Theme.gradient(tab, Theme.Info)
	Theme.stroke(tab, 3, nil, true)
	Theme.stroke(tab, 3)
	tab.Parent = f
	local open = false
	local function setOpen(want: boolean)
		if want == open then return end
		open = want
		if want then
			dim.Visible = true
			Theme.tween(dim, 0.2, { BackgroundTransparency = 0.45 })
			Theme.pop(f, 0.35)
		else
			Theme.tween(dim, 0.15, { BackgroundTransparency = 1 })
			local s = f:FindFirstChild("Juice") :: UIScale?
			if s then Theme.tween(s, 0.15, { Scale = 0 }).Completed:Wait() end
			if not open then dim.Visible = false end
		end
	end
	local x = Instance.new("TextButton")
	x.Size, x.AnchorPoint, x.Position = UDim2.fromOffset(48, 48), Vector2.new(0.5, 0.5), UDim2.new(1, -6, 0, 6)
	x.Text, x.Font, x.TextScaled, x.TextColor3, x.ZIndex = "X", Theme.Header, true, Theme.Cream, 14
	x.BackgroundColor3 = Theme.Bad
	Theme.corner(x, 24)
	Theme.stroke(x, 3, nil, true)
	x.Parent = f
	x.Activated:Connect(function() setOpen(false) end)
	return f, setOpen -- put content in f below the tab (y >= 40), ZIndex >= 12; open with setOpen(true)
end
