-- CurrencyCounter: HUD pill (coins, gems, cash) whose number ticks up, pops and flashes on change. Bind to a leaderstat.
local function short(n: number): string -- 999 -> "999", 12500 -> "12.5K", 3400000 -> "3.4M"
	for _, u in { { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e4, "K" } } do
		if math.abs(n) >= u[1] then
			return (string.format("%.1f", n / u[1]):gsub("%.0$", "")) .. u[2]
		end
	end
	return tostring(math.floor(n))
end

local function currencyCounter(parent: Instance, icon: string, color: Color3, pos: UDim2, value: IntValue | NumberValue)
	local pill = Instance.new("Frame")
	pill.Size, pill.Position, pill.BackgroundColor3 = UDim2.fromOffset(220, 56), pos, color
	Theme.corner(pill, 28)
	Theme.gradient(pill, color)
	Theme.stroke(pill, 3, nil, true)
	pill.Parent = parent
	local ico = Instance.new("TextLabel") -- emoji or letter icon; no asset ids needed
	ico.Size, ico.Position, ico.BackgroundTransparency = UDim2.fromOffset(64, 64), UDim2.fromOffset(-14, -4), 1
	ico.Text, ico.TextScaled, ico.Font, ico.ZIndex = icon, true, Theme.Header, 3
	Theme.stroke(ico, 3)
	ico.Parent = pill
	local num = Instance.new("TextLabel")
	num.Size, num.Position, num.BackgroundTransparency = UDim2.new(1, -60, 1, -8), UDim2.fromOffset(52, 4), 1
	num.Font, num.TextScaled, num.TextColor3, num.ZIndex = Theme.Header, true, Theme.Cream, 3
	num.TextXAlignment = Enum.TextXAlignment.Left
	Theme.stroke(num, 3)
	num.Parent = pill
	local shown: number = value.Value
	num.Text = short(shown)
	local token = 0
	value.Changed:Connect(function(new: any)
		local from, to = shown, new :: number
		token += 1
		local my = token
		Theme.punch(pill, if to > from then 0.15 else 0.08)
		num.TextColor3 = if to >= from then Theme.Good else Theme.Bad
		task.spawn(function() -- tick the number up over ~0.4 s instead of jumping
			for i = 1, 12 do
				if my ~= token then return end
				shown = from + (to - from) * (i / 12)
				num.Text = short(shown)
				task.wait(0.033)
			end
			num.TextColor3 = Theme.Cream
		end)
	end)
	return pill
end
