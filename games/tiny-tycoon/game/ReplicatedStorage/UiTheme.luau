--!strict
-- UiTheme: pure shared UI kit for the house Theme (no side effects, no server code).
-- Palette matches the HUD / cash look: yellow Primary, green Good, red Bad, blue Info, dark Ink outlines.
-- Telemetry (shop_opened, shop_purchases) is counted by the server-side owner of those events, not here.

local UiTheme = {}

-- Colors
UiTheme.ink = Color3.fromRGB(28, 22, 38)
UiTheme.cream = Color3.fromRGB(255, 248, 232)
UiTheme.panel = Color3.fromRGB(255, 248, 232)
UiTheme.card = Color3.fromRGB(255, 255, 255)
UiTheme.text = Color3.fromRGB(28, 22, 38)
UiTheme.accent = Color3.fromRGB(255, 196, 41)
UiTheme.good = Color3.fromRGB(88, 214, 92)
UiTheme.bad = Color3.fromRGB(240, 68, 64)
UiTheme.info = Color3.fromRGB(64, 170, 255)
UiTheme.dim = Color3.fromRGB(190, 184, 176)
UiTheme.locked = Color3.fromRGB(120, 112, 134)

-- Fonts and metrics
UiTheme.font = Enum.Font.FredokaOne
UiTheme.headerFont = Enum.Font.LuckiestGuy
UiTheme.cornerRadius = 14
UiTheme.stroke = 3
UiTheme.minButtonHeight = 48 -- at least 44 px touch target
UiTheme.padding = 10

-- Adds a UICorner to a GuiObject (reuses an existing one).
function UiTheme.roundify(guiObject: GuiObject, radius: number?)
	local corner = guiObject:FindFirstChildOfClass("UICorner")
	if not corner then
		corner = Instance.new("UICorner")
		corner.Parent = guiObject
	end
	(corner :: UICorner).CornerRadius = UDim.new(0, radius or UiTheme.cornerRadius)
end

-- Returns a big readable TextButton.
-- props: text, size, position, anchorPoint, color, textColor, parent, name, zIndex, layoutOrder, onClick
function UiTheme.makeButton(props: { [string]: any }): TextButton
	local button = Instance.new("TextButton")
	button.Name = props.name or "Button"
	button.Text = props.text or ""
	local size: UDim2 = props.size or UDim2.fromOffset(160, UiTheme.minButtonHeight)
	if size.Y.Offset < UiTheme.minButtonHeight and size.Y.Scale == 0 then
		size = UDim2.new(size.X.Scale, size.X.Offset, 0, UiTheme.minButtonHeight)
	end
	button.Size = size
	button.Position = props.position or UDim2.fromOffset(0, 0)
	button.AnchorPoint = props.anchorPoint or Vector2.new(0, 0)
	button.BackgroundColor3 = props.color or UiTheme.accent
	button.TextColor3 = props.textColor or UiTheme.cream
	button.Font = UiTheme.headerFont
	button.TextScaled = true
	button.AutoButtonColor = true
	button.BorderSizePixel = 0
	button.ZIndex = props.zIndex or 1
	button.LayoutOrder = props.layoutOrder or 0

	UiTheme.roundify(button, UiTheme.cornerRadius)

	local border = Instance.new("UIStroke")
	border.Thickness = UiTheme.stroke
	border.Color = UiTheme.ink
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Parent = button

	local textStroke = Instance.new("UIStroke")
	textStroke.Thickness = UiTheme.stroke
	textStroke.Color = UiTheme.ink
	textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	textStroke.Parent = button

	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0.16, 0)
	pad.PaddingBottom = UDim.new(0.16, 0)
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = button

	local minSize = Instance.new("UISizeConstraint")
	minSize.MinSize = Vector2.new(44, UiTheme.minButtonHeight)
	minSize.Parent = button

	local onClick = props.onClick
	if typeof(onClick) == "function" then
		button.Activated:Connect(function()
			onClick()
		end)
	end

	if props.parent then
		button.Parent = props.parent
	end
	return button
end

return UiTheme
