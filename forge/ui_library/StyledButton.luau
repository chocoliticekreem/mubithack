-- StyledButton: glossy outlined button with drop shadow, hover grow and press squish. Use for every clickable.
local function styledButton(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3?, onClick: (() -> ())?): TextButton
	local base = color or Theme.Primary
	local b = Instance.new("TextButton")
	b.Text, b.Size, b.Position, b.AnchorPoint = text, size, pos, Vector2.new(0.5, 0.5)
	b.BackgroundColor3, b.AutoButtonColor, b.BorderSizePixel = base, false, 0
	b.Font, b.TextScaled, b.TextColor3, b.ZIndex = Theme.Header, true, Theme.Cream, 3
	Theme.corner(b, 14)
	Theme.gradient(b, base)
	Theme.stroke(b, 3, nil, true) -- border
	Theme.stroke(b, 3) -- text outline
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0.18, 0), UDim.new(0.18, 0)
	pad.Parent = b
	local min = Instance.new("UISizeConstraint") -- 44 px minimum touch target
	min.MinSize = Vector2.new(44, 44)
	min.Parent = b
	b.Parent = parent
	Theme.shadow(b, 5)
	local s = Instance.new("UIScale")
	s.Parent = b
	b.MouseEnter:Connect(function() Theme.tween(s, 0.1, { Scale = 1.06 }) end)
	b.MouseLeave:Connect(function() Theme.tween(s, 0.1, { Scale = 1 }) end)
	b.MouseButton1Down:Connect(function() Theme.tween(s, 0.06, { Scale = 0.9 }) end)
	b.MouseButton1Up:Connect(function() Theme.tween(s, 0.2, { Scale = 1 }, Enum.EasingStyle.Back) end)
	if onClick then
		b.Activated:Connect(onClick) -- Activated covers mouse, touch and gamepad
	end
	return b
end
