--!strict
-- UiTheme: pure shared UI kit for the house Theme (no side effects, no server code).
-- Palette matches the HUD / cash look: yellow Primary, green Good, red Bad, blue Info, dark Ink outlines.
-- Telemetry (shop_opened, shop_purchases) is counted by the server-side owner of those events, not here.

local TweenService = game:GetService("TweenService")

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
	if corner then
		corner.CornerRadius = UDim.new(0, radius or UiTheme.cornerRadius)
	end
end

-- Active punch tweens per GuiObject (weak keys so destroyed gui objects are collected).
local activePunch: { [Instance]: Tween } = setmetatable({}, { __mode = "k" }) :: any

-- Punch: pops a GuiObject to 1.15x and back with Back easing in 0.18s total.
-- Uses a UIScale child so layouts and text sizes are untouched. Call on every cash change.
function UiTheme.punch(guiObject: GuiObject, peak: number?)
	if not guiObject or not guiObject.Parent then
		return
	end
	local uiScale = guiObject:FindFirstChild("PunchScale")
	if not uiScale or not uiScale:IsA("UIScale") then
		local created = Instance.new("UIScale")
		created.Name = "PunchScale"
		created.Scale = 1
		created.Parent = guiObject
		uiScale = created
	end
	local scaleObj = uiScale :: UIScale

	local running = activePunch[guiObject]
	if running then
		running:Cancel()
		activePunch[guiObject] = nil
	end
	scaleObj.Scale = 1

	local info = TweenInfo.new(0.09, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	local up = TweenService:Create(scaleObj, info, { Scale = peak or 1.15 })
	local down = TweenService:Create(scaleObj, info, { Scale = 1 })
	activePunch[guiObject] = up
	up.Completed:Once(function(state: Enum.PlaybackState)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		if scaleObj.Parent then
			activePunch[guiObject] = down
			down:Play()
		end
	end)
	up:Play()
end

export type GoalBar = {
	frame: Frame,
	fill: Frame,
	label: TextLabel,
	update: (current: number, cost: number, text: string?) -> (),
	destroy: () -> (),
}

-- Goal bar: a progress bar (e.g. "Next: Dropper 2 $10") that fills green as cash nears the cost
-- and flashes when affordable.
-- props: size, position, anchorPoint, parent, name, zIndex, text
function UiTheme.makeGoalBar(props: { [string]: any }): GoalBar
	local frame = Instance.new("Frame")
	frame.Name = props.name or "GoalBar"
	frame.Size = props.size or UDim2.fromOffset(220, 26)
	frame.Position = props.position or UDim2.fromOffset(0, 0)
	frame.AnchorPoint = props.anchorPoint or Vector2.new(0, 0)
	frame.BackgroundColor3 = UiTheme.ink
	frame.BackgroundTransparency = 0.25
	frame.BorderSizePixel = 0
	frame.ZIndex = props.zIndex or 1
	frame.ClipsDescendants = true
	UiTheme.roundify(frame, 10)

	local border = Instance.new("UIStroke")
	border.Thickness = UiTheme.stroke
	border.Color = UiTheme.ink
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Parent = frame

	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = UiTheme.good
	fill.BorderSizePixel = 0
	fill.ZIndex = frame.ZIndex + 1
	UiTheme.roundify(fill, 10)
	fill.Parent = frame

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = props.text or "Next goal"
	label.Font = UiTheme.headerFont
	label.TextScaled = true
	label.TextColor3 = UiTheme.cream
	label.ZIndex = frame.ZIndex + 2
	local labelStroke = Instance.new("UIStroke")
	labelStroke.Thickness = 2.5
	labelStroke.Color = UiTheme.ink
	labelStroke.Parent = label
	local labelPad = Instance.new("UIPadding")
	labelPad.PaddingTop = UDim.new(0.12, 0)
	labelPad.PaddingBottom = UDim.new(0.12, 0)
	labelPad.Parent = label
	label.Parent = frame

	local flashTween: Tween? = nil
	local fillTween: Tween? = nil
	local flashing = false

	local function setFlashing(on: boolean)
		if on == flashing then
			return
		end
		flashing = on
		if flashTween then
			flashTween:Cancel()
			flashTween = nil
		end
		if on then
			local t = TweenService:Create(
				fill,
				TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
				{ BackgroundColor3 = UiTheme.accent }
			)
			flashTween = t
			t:Play()
			UiTheme.punch(frame, 1.1)
		else
			fill.BackgroundColor3 = UiTheme.good
		end
	end

	local function update(current: number, cost: number, text: string?)
		if text then
			label.Text = text
		end
		local ratio = 1
		if cost > 0 then
			ratio = math.clamp(current / cost, 0, 1)
		end
		if fillTween then
			fillTween:Cancel()
		end
		local t = TweenService:Create(
			fill,
			TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ Size = UDim2.fromScale(ratio, 1) }
		)
		fillTween = t
		t:Play()
		setFlashing(current >= cost and cost > 0)
	end

	local function destroy()
		if flashTween then
			flashTween:Cancel()
			flashTween = nil
		end
		if fillTween then
			fillTween:Cancel()
			fillTween = nil
		end
		frame:Destroy()
	end

	if props.parent then
		frame.Parent = props.parent
	end

	return {
		frame = frame,
		fill = fill,
		label = label,
		update = update,
		destroy = destroy,
	}
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
