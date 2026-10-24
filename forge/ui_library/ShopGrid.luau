-- ShopGrid: scrolling grid of item cards (emoji icon, name, price, level/owned) with buy buttons; for shops and upgrade trees.
-- items: { {id, name, icon, price, level?, maxLevel?} }; onBuy(id) asks the server; call setItem(id, price, level) after.
local function shopGrid(parent: GuiObject, items: { any }, onBuy: (string) -> ()): (ScrollingFrame, (string, number, number?) -> ())
	local grid = Instance.new("ScrollingFrame")
	grid.Size, grid.Position, grid.BackgroundTransparency = UDim2.new(1, -24, 1, -80), UDim2.fromOffset(12, 68), 1
	grid.ScrollBarThickness, grid.AutomaticCanvasSize, grid.CanvasSize = 8, Enum.AutomaticSize.Y, UDim2.new()
	local layout = Instance.new("UIGridLayout")
	layout.CellSize, layout.CellPadding = UDim2.fromOffset(150, 190), UDim2.fromOffset(12, 12)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = grid
	local cards = {}
	for i, it in items do
		local card = Instance.new("Frame")
		card.LayoutOrder, card.BackgroundColor3 = i, Theme.Cream
		Theme.corner(card, 14)
		Theme.stroke(card, 3, nil, true)
		local icon = Instance.new("TextLabel")
		icon.Size, icon.BackgroundTransparency, icon.Text = UDim2.new(1, 0, 0, 64), 1, it.icon or "?"
		icon.TextScaled, icon.Font = true, Theme.Header
		icon.Parent = card
		local name = Instance.new("TextLabel")
		name.Size, name.Position, name.BackgroundTransparency = UDim2.new(1, -12, 0, 30), UDim2.fromOffset(6, 66), 1
		name.Text, name.Font, name.TextScaled, name.TextColor3 = it.name, Theme.Header, true, Theme.Ink
		name.Parent = card
		local lvl = Instance.new("TextLabel")
		lvl.Size, lvl.Position, lvl.BackgroundTransparency = UDim2.new(1, -12, 0, 22), UDim2.fromOffset(6, 96), 1
		lvl.Font, lvl.TextScaled, lvl.TextColor3 = Theme.Body, true, Theme.Info
		lvl.Parent = card
		local buy = Instance.new("TextButton")
		buy.Size, buy.Position, buy.AutoButtonColor = UDim2.new(1, -16, 0, 48), UDim2.new(0, 8, 1, -56), false
		buy.Font, buy.TextScaled, buy.TextColor3, buy.BackgroundColor3 = Theme.Header, true, Theme.Cream, Theme.Good
		Theme.corner(buy, 12)
		Theme.gradient(buy, Theme.Good)
		Theme.stroke(buy, 3, nil, true)
		Theme.stroke(buy, 2.5)
		buy.Parent = card
		buy.Activated:Connect(function()
			Theme.punch(card, 0.08)
			onBuy(it.id)
		end)
		card.Parent = grid
		cards[it.id] = { card = card, buy = buy, lvl = lvl, max = it.maxLevel }
	end
	local function setItem(id: string, price: number, level: number?)
		local c = cards[id]
		if not c then return end
		local maxed = c.max ~= nil and level ~= nil and level >= c.max
		c.lvl.Text = if level then (if c.max then string.format("Lv %d/%d", level, c.max) else "Lv " .. level) else ""
		c.buy.Text = if maxed then "MAX" else "$" .. tostring(price)
		c.buy.BackgroundColor3 = if maxed then Theme.Info else Theme.Good
		c.buy.Active = not maxed
	end
	for _, it in items do
		setItem(it.id, it.price, it.level)
	end
	grid.Parent = parent
	return grid, setItem
end
