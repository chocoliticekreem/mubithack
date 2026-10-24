-- RebirthPanel: rebirth card with requirement progress bar, current -> next multiplier and a big button that glows when ready.
-- update(current, required, mult, nextMult) on every cash change; onRebirth() asks the server (which validates and resets).
local function rebirthPanel(parent: GuiObject, onRebirth: () -> ()): (Frame, (number, number, number, number) -> ())
	local card = Instance.new("Frame")
	card.AnchorPoint, card.Position, card.Size = Vector2.new(0.5, 0.5), UDim2.fromScale(0.5, 0.5), UDim2.fromOffset(420, 260)
	card.BackgroundColor3 = Theme.Gem
	Theme.corner(card, 18)
	Theme.gradient(card, Theme.Gem)
	Theme.stroke(card, 4, nil, true)
	local title = Instance.new("TextLabel")
	title.Size, title.Position, title.BackgroundTransparency = UDim2.new(1, -24, 0, 50), UDim2.fromOffset(12, 10), 1
	title.Text, title.Font, title.TextScaled, title.TextColor3 = "REBIRTH", Theme.Header, true, Theme.Cream
	Theme.stroke(title, 3.5)
	title.Parent = card
	local mult = Instance.new("TextLabel")
	mult.Size, mult.Position, mult.BackgroundTransparency = UDim2.new(1, -24, 0, 40), UDim2.fromOffset(12, 64), 1
	mult.Font, mult.TextScaled, mult.TextColor3 = Theme.Header, true, Theme.Primary
	Theme.stroke(mult, 3)
	mult.Parent = card
	local track = Instance.new("Frame")
	track.Size, track.Position, track.BackgroundColor3 = UDim2.new(1, -40, 0, 28), UDim2.fromOffset(20, 116), Theme.Ink
	Theme.corner(track, 14)
	track.Parent = card
	local fill = Instance.new("Frame")
	fill.Size, fill.BackgroundColor3 = UDim2.fromScale(0, 1), Theme.Good
	Theme.corner(fill, 14)
	Theme.gradient(fill, Theme.Good)
	fill.Parent = track
	local need = Instance.new("TextLabel")
	need.Size, need.BackgroundTransparency, need.ZIndex = UDim2.fromScale(1, 1), 1, 3
	need.Font, need.TextScaled, need.TextColor3 = Theme.Body, true, Theme.Cream
	Theme.stroke(need, 2)
	need.Parent = track
	local btn = Instance.new("TextButton")
	btn.AnchorPoint, btn.Position, btn.Size = Vector2.new(0.5, 1), UDim2.new(0.5, 0, 1, -16), UDim2.fromOffset(260, 70)
	btn.Text, btn.Font, btn.TextScaled, btn.TextColor3, btn.AutoButtonColor = "REBIRTH!", Theme.Header, true, Theme.Cream, false
	Theme.corner(btn, 16)
	Theme.stroke(btn, 3, nil, true)
	Theme.stroke(btn, 3)
	btn.Parent = card
	local ready = false
	btn.Activated:Connect(function()
		if ready then
			Theme.punch(card, 0.15)
			onRebirth()
		else
			Theme.punch(btn, -0.1)
		end
	end)
	card.Parent = parent
	task.spawn(function() -- pulse the button while a rebirth is ready
		while card.Parent do
			if ready then Theme.punch(btn, 0.08) end
			task.wait(0.8)
		end
	end)
	Theme.pop(card)
	local function update(current: number, required: number, m: number, nextM: number)
		local pct = math.clamp(current / math.max(required, 1), 0, 1)
		Theme.tween(fill, 0.3, { Size = UDim2.fromScale(pct, 1) })
		need.Text = string.format("%d%%  (%s / %s)", math.floor(pct * 100), tostring(math.floor(current)), tostring(required))
		mult.Text = string.format("x%g  ->  x%g", m, nextM)
		ready = pct >= 1
		btn.BackgroundColor3 = if ready then Theme.Primary else Theme.Ink
	end
	return card, update
end
