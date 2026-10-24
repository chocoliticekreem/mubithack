-- BuyPad: glowing world pad a player steps on to buy/unlock something; bobbing price label, debounce, pop-away on success.
-- Server Script, no Theme needed. onBuy(player) returns true when the server took the cash and unlocked the item.
local function buyPad(parent: Instance, cf: CFrame, title: string, price: number, onBuy: (Player) -> boolean): BasePart
	local Players = game:GetService("Players")
	local TweenService = game:GetService("TweenService")
	local pad = Instance.new("Part")
	pad.Name, pad.Anchored, pad.CanCollide = "BuyPad_" .. title, true, false
	pad.Size, pad.CFrame, pad.Shape = Vector3.new(5, 0.6, 5), cf, Enum.PartType.Block
	pad.Material, pad.Color = Enum.Material.Neon, Color3.fromRGB(88, 214, 92)
	pad.TopSurface = Enum.SurfaceType.Smooth
	local bb = Instance.new("BillboardGui")
	bb.Size, bb.StudsOffset, bb.MaxDistance, bb.LightInfluence = UDim2.fromScale(6, 2.4), Vector3.new(0, 3, 0), 90, 0
	local label = Instance.new("TextLabel")
	label.Size, label.BackgroundTransparency, label.TextScaled = UDim2.fromScale(1, 1), 1, true
	label.Font, label.TextColor3 = Enum.Font.LuckiestGuy, Color3.fromRGB(255, 248, 232)
	label.Text = string.format("%s\n$%s", title, tostring(price))
	local stroke = Instance.new("UIStroke")
	stroke.Thickness, stroke.Color = 3, Color3.fromRGB(28, 22, 38)
	stroke.Parent = label
	label.Parent = bb
	bb.Parent = pad
	pad.Parent = parent
	-- bob the label so the pad reads as interactive
	TweenService:Create(bb, TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
		{ StudsOffset = Vector3.new(0, 3.6, 0) }):Play()
	local busy: { [Player]: boolean } = {}
	local bought = false
	pad.Touched:Connect(function(hit: BasePart)
		local player = Players:GetPlayerFromCharacter(hit.Parent)
		if bought or not player or busy[player] then return end
		busy[player] = true
		if onBuy(player) then
			bought = true
			TweenService:Create(pad, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.In),
				{ Size = Vector3.new(0.1, 0.1, 0.1), Transparency = 1 }):Play()
			task.delay(0.3, function() pad:Destroy() end)
		else
			pad.Color = Color3.fromRGB(240, 68, 64) -- can't afford: flash red
			task.delay(0.4, function() pad.Color = Color3.fromRGB(88, 214, 92) end)
		end
		task.delay(1, function() busy[player] = nil end)
	end)
	return pad
end
