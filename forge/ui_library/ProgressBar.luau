-- ProgressBar: XP / level / health / timer / capacity bar with gradient fill, smooth tween and a shine sweep.
local function progressBar(parent: Instance, size: UDim2, pos: UDim2, color: Color3): (Frame, (number, string?) -> ())
	local back = Instance.new("Frame")
	back.Size, back.Position, back.BackgroundColor3 = size, pos, Theme.Ink
	Theme.corner(back, 10)
	Theme.stroke(back, 3, nil, true)
	back.ClipsDescendants = true
	back.Parent = parent
	local fill = Instance.new("Frame")
	fill.Size, fill.BackgroundColor3, fill.ZIndex = UDim2.fromScale(0, 1), color, 2
	Theme.corner(fill, 10)
	Theme.gradient(fill, color)
	fill.Parent = back
	-- White streak that sweeps across when progress grows. Not rotated: ClipsDescendants skips rotated children.
	local shine = Instance.new("Frame")
	shine.Size, shine.Position = UDim2.fromScale(0.15, 1), UDim2.fromScale(-0.2, 0)
	shine.BackgroundColor3, shine.ZIndex = Color3.new(1, 1, 1), 3
	local soft = Instance.new("UIGradient")
	soft.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0.4), NumberSequenceKeypoint.new(1, 1) })
	soft.Parent = shine
	shine.Parent = back
	local label = Instance.new("TextLabel")
	label.Size, label.BackgroundTransparency, label.ZIndex = UDim2.fromScale(1, 1), 1, 4
	label.Font, label.TextScaled, label.TextColor3, label.Text = Theme.Header, true, Theme.Cream, ""
	Theme.stroke(label, 2.5)
	label.Parent = back
	local last = 0
	local function set(fraction: number, text: string?)
		local f = math.clamp(fraction, 0, 1)
		Theme.tween(fill, 0.35, { Size = UDim2.fromScale(f, 1) }, Enum.EasingStyle.Quart)
		if text then label.Text = text end
		if f > last then
			shine.Position = UDim2.fromScale(-0.2, 0)
			Theme.tween(shine, 0.6, { Position = UDim2.fromScale(1.1, 0) }, Enum.EasingStyle.Sine)
		end
		last = f
	end
	return back, set -- set(0.4, "40 / 100")
end
