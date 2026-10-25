--!strict
-- ThumbLayout [owner: G3]. The touch action buttons, drawn by US as ONE cluster around Roblox's jump
-- button (sized from the real jump button), so nothing overlaps it, the squad strip, the hotbar or each
-- other on phones and iPads:
--
--              [above]          slot "above"   : SWAP / OUT          (small, over the jump button)
--      [upleft]                 slot "upleft"  : DROP / HONK         (small, over the primary)
--  [left] (  PRIMARY  ) (JUMP)  slot "primary" : SPRAY / CHOP / DRIFT (big, left of jump)
--                               slot "left"    : THROW / SIREN       (small, left of the primary)
--                               "upfar" / "leftfar": overflow
--                               slot "jump"    : the jump button's own spot and size, for screens
--                                                that hide Roblox's jump (driving: OUT sits there)
--
--   ThumbLayout.place(action, slot, handler)   after ContextActionService:BindAction(action, handler, ...)
--   ThumbLayout.forget(action)                 before UnbindAction
-- The handler is called as handler(action, Begin / End, nil), exactly like ContextActionService does.
-- Roblox's own ContextActionService touch buttons are hidden: they live in a small frame by the jump
-- button that clipped / mis-placed buttons on some phones (SPRAY simply did not show), so we never rely
-- on them. Shown whenever the input mode is touch (InputHints.isTouch: real touch, or the dev attrs
-- InputHintsMode = "touch" / ForceTouchUI in Studio).
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")

local ThumbLayout = {}

export type Slot = "primary" | "above" | "upleft" | "left" | "upfar" | "leftfar" | "jump"
type Handler = (string, Enum.UserInputState, any) -> any

local ORDER: { Slot } = { "primary", "above", "upleft", "left", "upfar", "leftfar" }

type Entry = { slot: Slot, handler: Handler?, button: TextButton? }
local entries: { [string]: Entry } = {}
local gui: ScreenGui? = nil
local hooked = false

local function isTouch(): boolean
	local ok, InputHints = pcall(function()
		return require(script.Parent:WaitForChild("InputHints") :: ModuleScript) :: any
	end)
	if ok and InputHints and type(InputHints.isTouch) == "function" then
		local ok2, v = pcall(InputHints.isTouch)
		if ok2 and v then
			return true
		end
	end
	local p = Players.LocalPlayer
	return p:GetAttribute("ForceTouchUI") == true or game:GetService("UserInputService").TouchEnabled
end

local function jumpRect(): (Vector2, number)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local touch = pg and pg:FindFirstChild("TouchGui")
	local jump = touch and touch:FindFirstChild("JumpButton", true)
	if jump and jump:IsA("GuiObject") and jump.AbsoluteSize.X > 10 and jump.Visible then
		local inset = 0
		local sg = jump:FindFirstAncestorOfClass("ScreenGui")
		if sg and not sg.IgnoreGuiInset then
			inset = game:GetService("GuiService"):GetGuiInset().Y
		end
		return jump.AbsolutePosition + jump.AbsoluteSize / 2 + Vector2.new(0, inset), jump.AbsoluteSize.X
	end
	-- Roblox's own rule (TouchJump): small screens get a 70 px button, big ones 120 px
	local small = math.min(vp.X, vp.Y) <= 500
	local j = if small then 70 else 120
	local c = if small then Vector2.new(vp.X - 60, vp.Y - 55) else Vector2.new(vp.X - 110, vp.Y - 150)
	return c, j
end

-- centre + size of a slot, in screen pixels (top-bar inset included: our gui ignores the inset)
local function slotRect(slot: Slot): (Vector2, number)
	local jc, j = jumpRect()
	local big = math.floor(j * 1.2)
	local small = math.floor(j * 0.75)
	local gap = math.max(8, math.floor(j * 0.15))
	local primary = Vector2.new(jc.X - (j / 2 + gap + big / 2), jc.Y + j * 0.05)
	if slot == "jump" then
		return jc, j
	elseif slot == "primary" then
		return primary, big
	elseif slot == "above" then
		return Vector2.new(jc.X, jc.Y - (j / 2 + gap + small / 2)), small
	elseif slot == "upleft" then
		return Vector2.new(primary.X + big * 0.05, primary.Y - (big / 2 + gap + small / 2)), small
	elseif slot == "left" then
		return Vector2.new(primary.X - (big / 2 + gap + small / 2), primary.Y + big * 0.15), small
	elseif slot == "upfar" then
		return Vector2.new(primary.X - (big / 2 + gap + small / 2), primary.Y - (big / 2 + gap + small / 2)), small
	else
		return Vector2.new(primary.X - (big / 2 + gap + small * 1.5 + gap), primary.Y + big * 0.15), small
	end
end

local function screen(): ScreenGui
	if gui and gui.Parent then
		return gui :: ScreenGui
	end
	local g = Instance.new("ScreenGui")
	g.Name = "ThumbButtons"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true
	g.ScreenInsets = Enum.ScreenInsets.None
	g.DisplayOrder = 20
	g.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = g
	return g
end

local function title(action: string): string
	local ok, info = pcall(function()
		return ContextActionService:GetBoundActionInfo(action)
	end)
	local t = if ok and type(info) == "table" then info.title else nil
	return if type(t) == "string" and t ~= "" then t else action
end

local function hideRoblox(action: string)
	local b = ContextActionService:GetButton(action)
	if b then
		b.Visible = false
	end
end

local function makeButton(action: string): TextButton
	local b = Instance.new("TextButton")
	b.Name = action
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.AutoButtonColor = false
	b.BackgroundColor3 = Color3.fromRGB(30, 26, 28)
	b.BackgroundTransparency = 0.25
	b.Text = ""
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0.5, 0)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.fromRGB(255, 244, 196)
	s.Transparency = 0.15
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = b
	local l = Instance.new("TextLabel")
	l.Name = "Label"
	l.BackgroundTransparency = 1
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.5)
	l.Size = UDim2.fromScale(0.82, 0.46)
	l.Font = Enum.Font.FredokaOne
	l.TextScaled = true
	l.TextColor3 = Color3.fromRGB(255, 244, 196)
	l.Parent = b
	local lim = Instance.new("UITextSizeConstraint")
	lim.MinTextSize = 8
	lim.Parent = l
	-- press / release drive the bound handler like ContextActionService would
	local down = false
	local function fire(state: Enum.UserInputState)
		local e = entries[action]
		if e and e.handler then
			task.spawn(e.handler, action, state, nil)
		end
	end
	b.InputBegan:Connect(function(input: InputObject)
		local t = input.UserInputType
		if t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1 then
			if not down then
				down = true
				b.BackgroundTransparency = 0.05
				fire(Enum.UserInputState.Begin)
			end
		end
	end)
	b.InputEnded:Connect(function(input: InputObject)
		local t = input.UserInputType
		if (t == Enum.UserInputType.Touch or t == Enum.UserInputType.MouseButton1) and down then
			down = false
			b.BackgroundTransparency = 0.25
			fire(Enum.UserInputState.End)
		end
	end)
	b.Parent = screen()
	return b
end

local function apply(action: string)
	local e = entries[action]
	if not e then
		return
	end
	hideRoblox(action)
	if not isTouch() or not e.handler then
		if e.button then
			e.button.Visible = false
		end
		return
	end
	local b = e.button or makeButton(action)
	e.button = b
	local c, size = slotRect(e.slot)
	b.Size = UDim2.fromOffset(size, size)
	b.Position = UDim2.fromOffset(c.X, c.Y)
	b.Visible = true
	local l = b:FindFirstChild("Label") :: TextLabel?
	if l then
		l.Text = title(action)
		local lim = l:FindFirstChildOfClass("UITextSizeConstraint")
		if lim then
			lim.MaxTextSize = if e.slot == "primary" then 30 else 18
		end
	end
end

local function reapply()
	for action in entries do
		apply(action)
	end
end

function ThumbLayout.place(action: string, want: Slot, handler: Handler?)
	local taken: { [Slot]: boolean } = {}
	for other, e in entries do
		if other ~= action then
			taken[e.slot] = true
		end
	end
	local slot = want
	if taken[slot] then
		for _, s in ORDER do
			if not taken[s] then
				slot = s
				break
			end
		end
	end
	local e = entries[action]
	if e then
		e.slot = slot
		e.handler = handler or e.handler
	else
		entries[action] = { slot = slot, handler = handler, button = nil }
	end
	apply(action)
	-- Roblox builds its own touch button a frame later: hide it again once it exists; titles too
	task.defer(apply, action)
	task.delay(0.3, apply, action)
	if not hooked then
		hooked = true
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				task.defer(reapply)
			end)
		end
		local p = Players.LocalPlayer
		p:GetAttributeChangedSignal("InputHintsMode"):Connect(reapply)
		p:GetAttributeChangedSignal("ForceTouchUI"):Connect(reapply)
		game:GetService("UserInputService").LastInputTypeChanged:Connect(function()
			task.defer(reapply)
		end)
	end
end

-- relabel a placed button (e.g. OUT -> OFF)
function ThumbLayout.refresh(action: string)
	apply(action)
end

function ThumbLayout.forget(action: string)
	local e = entries[action]
	entries[action] = nil
	if e and e.button then
		e.button:Destroy()
	end
end

return ThumbLayout
