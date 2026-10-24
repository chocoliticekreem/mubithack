-- FloatingText: "+1" / "+$50" / "-10" text that rises and fades over a world point. Pickup, hit and payout feedback.
local function floatingText(at: Vector3, text: string, color: Color3?)
	local anchor = Instance.new("Part")
	anchor.Anchored, anchor.CanCollide, anchor.CanQuery, anchor.CanTouch = true, false, false, false
	anchor.Transparency, anchor.Size, anchor.Position = 1, Vector3.one * 0.2, at
	anchor.Parent = workspace
	local bb = Instance.new("BillboardGui")
	bb.Size, bb.StudsOffset, bb.AlwaysOnTop = UDim2.fromOffset(160, 60), Vector3.new(0, 1, 0), true
	bb.Adornee = anchor
	local l = Instance.new("TextLabel")
	l.Size, l.BackgroundTransparency, l.Text = UDim2.fromScale(1, 1), 1, text
	l.Font, l.TextScaled, l.TextColor3 = Theme.Header, true, color or Theme.Primary
	local s = Theme.stroke(l, 3)
	l.Parent = bb
	bb.Parent = anchor
	Theme.tween(bb, 0.9, { StudsOffset = Vector3.new(math.random(-10, 10) / 10, 4, 0) }, Enum.EasingStyle.Quart)
	task.delay(0.45, function()
		Theme.tween(l, 0.45, { TextTransparency = 1 })
		Theme.tween(s, 0.45, { Transparency = 1 })
	end)
	task.delay(1, function() anchor:Destroy() end)
end
