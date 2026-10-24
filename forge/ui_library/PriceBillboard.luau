-- PriceBillboard: world price tag over a buy pad / shop item; green when affordable, red when not. Server or client.
-- Standalone (no Theme needed) so a server Script can paste it too.
local function priceBillboard(part: BasePart, title: string, price: number): (BillboardGui, (boolean) -> ())
	local bb = Instance.new("BillboardGui")
	bb.Size, bb.StudsOffset = UDim2.fromScale(6, 2.2), Vector3.new(0, part.Size.Y / 2 + 2, 0)
	bb.AlwaysOnTop, bb.MaxDistance, bb.LightInfluence = false, 80, 0
	bb.Adornee = part
	local function text(t: string, y: number, h: number, color: Color3): TextLabel
		local l = Instance.new("TextLabel")
		l.Size, l.Position, l.BackgroundTransparency = UDim2.fromScale(1, h), UDim2.fromScale(0, y), 1
		l.Text, l.Font, l.TextScaled, l.TextColor3 = t, Enum.Font.LuckiestGuy, true, color
		local s = Instance.new("UIStroke")
		s.Thickness, s.Color = 3, Color3.fromRGB(28, 22, 38)
		s.Parent = l
		l.Parent = bb
		return l
	end
	text(title, 0, 0.45, Color3.fromRGB(255, 248, 232))
	local cost = text("$" .. tostring(price), 0.45, 0.55, Color3.fromRGB(240, 68, 64))
	bb.Parent = part
	local function setAffordable(ok: boolean)
		cost.TextColor3 = if ok then Color3.fromRGB(88, 214, 92) else Color3.fromRGB(240, 68, 64)
	end
	return bb, setAffordable -- client: call setAffordable(cash.Value >= price) on cash.Changed
end
