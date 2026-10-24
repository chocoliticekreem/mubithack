-- Leaderboard: live top-N players panel sorted by a leaderstat (Cash, Stage, Rebirths); the local player is highlighted.
local function leaderboard(gui: ScreenGui, statName: string, top: number?): Frame
	local Players = game:GetService("Players")
	local n = top or 5
	local box = Instance.new("Frame")
	box.AnchorPoint, box.Position, box.Size = Vector2.new(1, 0), UDim2.new(1, -16, 0, 90), UDim2.fromOffset(240, 46 + n * 34)
	box.BackgroundColor3, box.BackgroundTransparency = Theme.Ink, 0.2
	Theme.corner(box, 14)
	Theme.stroke(box, 3, nil, true)
	local title = Instance.new("TextLabel")
	title.Size, title.Position, title.BackgroundTransparency = UDim2.new(1, -16, 0, 34), UDim2.fromOffset(8, 6), 1
	title.Text, title.Font, title.TextScaled, title.TextColor3 = "TOP " .. statName:upper(), Theme.Header, true, Theme.Primary
	Theme.stroke(title, 2.5)
	title.Parent = box
	local rows = {}
	for i = 1, n do
		local r = Instance.new("TextLabel")
		r.Size, r.Position = UDim2.new(1, -16, 0, 30), UDim2.fromOffset(8, 40 + (i - 1) * 34)
		r.BackgroundColor3, r.BackgroundTransparency = Theme.Cream, 0.88
		r.Font, r.TextScaled, r.TextColor3, r.TextXAlignment = Theme.Body, true, Theme.Cream, Enum.TextXAlignment.Left
		r.Text = ""
		Theme.corner(r, 8)
		Theme.stroke(r, 2)
		r.Parent = box
		rows[i] = r
	end
	box.Parent = gui
	Theme.pop(box)
	local function short(v: number): string
		if v >= 1e6 then return string.format("%.1fM", v / 1e6) end
		if v >= 1e3 then return string.format("%.1fK", v / 1e3) end
		return tostring(math.floor(v))
	end
	local last = ""
	local function refresh()
		local list = {}
		for _, p in Players:GetPlayers() do
			local ls = p:FindFirstChild("leaderstats")
			local v = ls and ls:FindFirstChild(statName)
			table.insert(list, { p = p, v = (v and tonumber(v.Value)) or 0 })
		end
		table.sort(list, function(a, b) return a.v > b.v end)
		local key = ""
		for i = 1, n do
			local e = list[i]
			rows[i].Visible = e ~= nil
			if e then
				rows[i].Text = string.format("  %d. %s  %s", i, e.p.DisplayName, short(e.v))
				rows[i].TextColor3 = if e.p == Players.LocalPlayer then Theme.Primary else Theme.Cream
				key ..= e.p.Name .. ":" .. e.v .. ";"
			end
		end
		if key ~= last and last ~= "" then Theme.punch(box, 0.05) end
		last = key
	end
	task.spawn(function()
		while box.Parent do
			refresh()
			task.wait(1)
		end
	end)
	return box
end
