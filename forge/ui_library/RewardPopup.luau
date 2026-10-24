-- RewardPopup: big centre celebration (level up, chest, unlock, win) with spinning burst rays, overshoot pop, auto close.
local function rewardPopup(gui: ScreenGui, title: string, amount: string, color: Color3?)
	local c = color or Theme.Primary
	local root = Instance.new("Frame")
	root.Size, root.AnchorPoint, root.Position = UDim2.fromOffset(420, 420), Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.45)
	root.BackgroundTransparency, root.ZIndex = 1, 30
	root.Parent = gui
	local rays = Instance.new("Frame") -- 6 thin bars crossing at the centre = 12 rays, spun slowly
	rays.Size, rays.AnchorPoint, rays.Position = UDim2.fromScale(1, 1), Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
	rays.BackgroundTransparency, rays.ZIndex = 1, 30
	rays.Parent = root
	for i = 0, 5 do
		local r = Instance.new("Frame")
		r.Size, r.AnchorPoint, r.Position = UDim2.new(0, 34, 1, 0), Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
		r.Rotation, r.BackgroundColor3, r.BackgroundTransparency, r.ZIndex = i * 30, c, 0.55, 30
		local g = Instance.new("UIGradient") -- fade both ends so the rays read as light, not sticks
		g.Rotation = 90
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = r
		r.Parent = rays
	end
	local card = Instance.new("Frame")
	card.Size, card.AnchorPoint, card.Position = UDim2.fromOffset(300, 170), Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5)
	card.BackgroundColor3, card.ZIndex = c, 31
	Theme.corner(card, 22)
	Theme.gradient(card, c)
	Theme.stroke(card, 5, nil, true)
	card.Parent = root
	for i, t in { title, amount } do
		local l = Instance.new("TextLabel")
		l.Size, l.Position = UDim2.new(1, -24, 0.42, 0), UDim2.new(0, 12, if i == 1 then 0.08 else 0.5, 0)
		l.BackgroundTransparency, l.Text, l.ZIndex = 1, t, 32
		l.Font, l.TextScaled, l.TextColor3 = Theme.Header, true, Theme.Cream
		Theme.stroke(l, if i == 1 then 3 else 4)
		l.Parent = card
	end
	Theme.pop(root, 0.45)
	local spin = true
	task.spawn(function()
		while spin and rays.Parent do
			rays.Rotation += 1.2
			task.wait()
		end
	end)
	task.delay(2.5, function()
		local s = root:FindFirstChild("Juice") :: UIScale?
		if s then Theme.tween(s, 0.2, { Scale = 0 }).Completed:Wait() end
		spin = false
		root:Destroy()
	end)
end
