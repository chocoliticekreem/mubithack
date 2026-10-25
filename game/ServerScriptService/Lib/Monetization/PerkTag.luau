--!strict
-- PerkTag [owner: Monetization]. Social proof for pass owners: a row of little round pass icons
-- (MonetizationConfig.Passes glyph + colour) right beside the helmet number tag over a player's head
-- (CostumeBuilder's "BadgeTag": 44x28 px at 3.4 studs). Everyone else sees it; like the number tag it
-- is hidden from its wearer. MonetizationService calls it on spawn and whenever ownership changes.
--   PerkTag.apply(character, player, passes)   passes = { { icon: string, color: Color3 } }; {} removes it
local PerkTag = {}

local INK = Color3.fromHex("#2A1410")
local CREAM = Color3.fromHex("#FFF1D6")
local BADGE_HALF = 22 -- half the BadgeTag's width, px

function PerkTag.apply(character: Model, player: Player?, passes: { { icon: string, color: Color3 } }, px: number?, gap: number?)
	local head = character:FindFirstChild("Head") :: BasePart?
	local old = head and head:FindFirstChild("PerkTag")
	if old then
		old:Destroy()
	end
	if not head or #passes == 0 then
		return
	end
	local size = px or 26
	local g = gap or 4
	local width = #passes * size + (#passes - 1) * g
	local gui = Instance.new("BillboardGui")
	gui.Name = "PerkTag"
	gui.Size = UDim2.fromOffset(width, size)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0) -- the number tag's height
	-- shift right of the number tag: centre at BADGE_HALF + gap + width/2 px (SizeOffset is in gui widths)
	gui.SizeOffset = Vector2.new((BADGE_HALF + g + width / 2) / width, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 250
	gui.LightInfluence = 0
	gui.Adornee = head
	if player then
		gui.PlayerToHideFrom = player
	end
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, g)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = gui
	for i, p in passes do
		local dot = Instance.new("TextLabel")
		dot.Name = `Perk{i}`
		dot.LayoutOrder = i
		dot.Size = UDim2.fromOffset(size, size)
		dot.BackgroundColor3 = p.color
		dot.Font = Enum.Font.GothamBlack -- has the ∞ and ★ glyphs
		dot.TextScaled = true
		dot.Text = p.icon
		dot.TextColor3 = CREAM
		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0.5, 0)
		corner.Parent = dot
		local ring = Instance.new("UIStroke")
		ring.Color = INK
		ring.Thickness = 2
		ring.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		ring.Parent = dot
		local ts = Instance.new("UIStroke")
		ts.Color = INK
		ts.Thickness = 1.5
		ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		ts.Parent = dot
		dot.Parent = gui
	end
	gui.Parent = head
end

return PerkTag
