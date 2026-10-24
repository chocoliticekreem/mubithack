--!strict
-- UiKit [owner: G3]. Shared client UI builders in the chunky sticker style of docs/game/02-art-feel-ui.md §9:
-- UiCream panels with a UiInk stroke, LuckiestGuy numbers/headers, FredokaOne body text, UIScale for phones.
-- Lives in StarterPlayerScripts/ClientLib (not booted by Main.client; controllers require it):
--   local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit"))
--
--   UiKit.screen(name, displayOrder?, fullBleed?) -> ScreenGui   (fullBleed: ignore the top-bar inset)
--   UiKit.panel(parent, name, size, position, anchor?) -> Frame
--   UiKit.label(parent, name, text, size, position, opts?) -> TextLabel
--   UiKit.button(parent, name, text, size, position, color?) -> TextButton
--   UiKit.badge(parent, name, helmet, size, position) -> Frame      (red helmet circle with "02")
--   UiKit.pop(gui, duration?), UiKit.punch(gui, amount?), UiKit.shake(gui, seconds?, px?)
--   UiKit.tween(inst, seconds, props, style?, dir?) -> Tween
--   UiKit.clock(seconds) -> "2:05", UiKit.helmetTag(n) -> "02", UiKit.kindColor(kind) -> Color3
--   UiKit.corner(parent, r?), UiKit.stroke(parent, thickness?, color?), UiKit.Header, UiKit.Body
--   UiKit.sound(id, volume?, pitch?)   -- 2D one-shot; no-op for "" (ids are configurable, default "")
--   UiKit.onTap(button, fn) -> RBXScriptConnection   button.Activated:Connect(fn), and on touch a button
--                                       smaller than UiKit.MinTouch px on screen gets an invisible "TouchPad"
--                                       around it (centred, MinTouch x MinTouch) that taps it too
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local SoundService = game:GetService("SoundService")
local TweenService = game:GetService("TweenService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)

local UiKit = {}

UiKit.Header = Enum.Font.LuckiestGuy
UiKit.Body = Enum.Font.FredokaOne

-- A ScreenGui under PlayerGui with a UIScale that tracks the viewport (1280x720 = 1, clamped for phones).
-- By default it respects the Roblox top bar and device notches (CoreUISafeInsets) so nothing hides under them.
function UiKit.screen(name: string, displayOrder: number?, fullBleed: boolean?): ScreenGui
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = playerGui:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = fullBleed == true
	gui.ScreenInsets = if fullBleed then Enum.ScreenInsets.None else Enum.ScreenInsets.CoreUISafeInsets
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = displayOrder or 0
	local scale = Instance.new("UIScale")
	scale.Name = "ViewportScale"
	local function rescale()
		local cam = workspace.CurrentCamera
		if cam then
			local v = cam.ViewportSize
			scale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.55, 1.4)
		end
	end
	rescale()
	if workspace.CurrentCamera then
		workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	scale.Parent = gui
	gui.Parent = playerGui
	return gui
end

-- touch targets -------------------------------------------------------------------------------------
UiKit.MinTouch = 44 -- px on screen: the smallest thing a thumb should have to hit

local function totalScale(obj: Instance): number
	local k = 1
	local cur: Instance? = obj
	while cur do
		for _, c in cur:GetChildren() do
			if c:IsA("UIScale") then
				k *= c.Scale
			end
		end
		if cur:IsA("LayerCollector") then
			break
		end
		cur = cur.Parent
	end
	return k
end

local hintsMod: any = nil
local function isTouch(): boolean
	if hintsMod == nil then
		local ok, m = pcall(function()
			return require(script.Parent:WaitForChild("InputHints") :: ModuleScript)
		end)
		hintsMod = if ok then m else false
	end
	return hintsMod ~= false and hintsMod.isTouch()
end

function UiKit.onTap(button: GuiButton, fn: () -> ()): RBXScriptConnection
	local conn = button.Activated:Connect(fn)
	local pad = Instance.new("TextButton")
	pad.Name = "TouchPad"
	pad.Text = ""
	pad.BackgroundTransparency = 1
	pad.AutoButtonColor = false
	pad.Selectable = false
	pad.AnchorPoint = Vector2.new(0.5, 0.5)
	pad.Position = UDim2.fromScale(0.5, 0.5)
	pad.ZIndex = button.ZIndex + 1
	pad.Visible = false
	pad:SetAttribute("UiAuditIgnore", true)
	pad.Parent = button
	pad.Activated:Connect(fn)
	local function fit()
		local abs = button.AbsoluteSize
		local want = UiKit.MinTouch
		if not isTouch() or (abs.X >= want and abs.Y >= want) or abs.X <= 0 then
			pad.Visible = false
			return
		end
		-- px per local unit, measured (UIScales, pops and tweens included): a 100-unit probe
		pad.Size = UDim2.new(1, 100, 1, 100)
		local k = (pad.AbsoluteSize.X - abs.X) / 100
		if k <= 0.01 then
			k = math.max(totalScale(button), 0.05)
		end
		-- grow only the short sides, in the button's own (unscaled) units
		local ex = math.max(0, want - abs.X) / k
		local ey = math.max(0, want - abs.Y) / k
		pad.Size = UDim2.new(1, math.ceil(ex), 1, math.ceil(ey))
		pad.Visible = true
	end
	button:GetPropertyChangedSignal("AbsoluteSize"):Connect(fit)
	task.defer(fit)
	task.spawn(function()
		isTouch() -- loads InputHints
		if hintsMod then
			hintsMod.onChanged(function()
				fit()
			end)
		end
	end)
	return conn
end

function UiKit.corner(parent: Instance, radius: number?)
	local c = parent:FindFirstChildOfClass("UICorner") or Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or 12)
	c.Parent = parent
end

function UiKit.stroke(parent: Instance, thickness: number?, color: Color3?): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness = thickness or 3
	s.Color = color or Palette.UiInk
	s.ApplyStrokeMode = if parent:IsA("TextLabel") or parent:IsA("TextButton")
		then Enum.ApplyStrokeMode.Contextual
		else Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

-- A sticker panel: UiCream fill, rounded, 3px ink border.
function UiKit.panel(parent: Instance, name: string, size: UDim2, position: UDim2, anchor: Vector2?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = position
	f.AnchorPoint = anchor or Vector2.zero
	f.BackgroundColor3 = Palette.UiCream
	f.BorderSizePixel = 0
	UiKit.corner(f, 12)
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	f.Parent = parent
	return f
end

export type LabelOpts = {
	font: Enum.Font?,
	textSize: number?,
	color: Color3?,
	stroke: boolean?,
	strokeThickness: number?,
	align: Enum.TextXAlignment?,
	scaled: boolean?,
}

function UiKit.label(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, opts: LabelOpts?): TextLabel
	local o = opts or {} :: LabelOpts
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Text = text
	l.Size = size
	l.Position = position
	l.BackgroundTransparency = 1
	l.Font = o.font or UiKit.Body
	l.TextSize = o.textSize or 22
	l.TextScaled = o.scaled == true
	l.TextColor3 = o.color or Palette.UiInk
	l.TextXAlignment = o.align or Enum.TextXAlignment.Center
	l.TextWrapped = true
	l.ZIndex = 2
	if o.stroke then
		local s = Instance.new("UIStroke")
		s.Thickness = o.strokeThickness or 2.5
		s.Color = Palette.UiInk
		s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
		s.Parent = l
	end
	l.Parent = parent
	return l
end

-- Big chunky button with a press squish. Works with touch, mouse and gamepad (Activated).
function UiKit.button(parent: Instance, name: string, text: string, size: UDim2, position: UDim2, color: Color3?): TextButton
	local b = Instance.new("TextButton")
	b.Name = name
	b.Text = text
	b.Size = size
	b.Position = position
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.AutoButtonColor = true
	b.BackgroundColor3 = color or Palette.UiWarn
	b.Font = UiKit.Header
	b.TextSize = 30
	b.TextColor3 = Palette.UiCream
	b.ZIndex = 3
	UiKit.corner(b, 16)
	local border = Instance.new("UIStroke")
	border.Thickness = 4
	border.Color = Palette.UiInk
	border.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	border.Parent = b
	local textStroke = Instance.new("UIStroke")
	textStroke.Thickness = 2.5
	textStroke.Color = Palette.UiInk
	textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	textStroke.Parent = b
	local scale = Instance.new("UIScale")
	scale.Parent = b
	b.MouseButton1Down:Connect(function()
		UiKit.tween(scale, 0.06, { Scale = 0.92 })
	end)
	b.MouseButton1Up:Connect(function()
		UiKit.tween(scale, 0.12, { Scale = 1 }, Enum.EasingStyle.Back)
	end)
	b.MouseLeave:Connect(function()
		UiKit.tween(scale, 0.12, { Scale = 1 })
	end)
	b.Parent = parent
	return b
end

function UiKit.helmetTag(n: number?): string
	return string.format("%02d", n or 0)
end

-- Red helmet circle with the white number, like the decal on the helmets.
function UiKit.badge(parent: Instance, name: string, helmet: number, size: number, position: UDim2): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = UDim2.fromOffset(size, size)
	f.Position = position
	f.BackgroundColor3 = Palette.HelmetRed
	f.BorderSizePixel = 0
	f.ZIndex = 2
	UiKit.corner(f, size)
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	local l = UiKit.label(f, "Num", UiKit.helmetTag(helmet), UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = math.floor(size * 0.5),
		color = Palette.UiCream,
		stroke = true,
	})
	l.ZIndex = 3
	f.Parent = parent
	return f
end

local function scaleOf(gui: GuiObject): UIScale
	local s = gui:FindFirstChild("PopScale") :: UIScale?
	if not s then
		local n = Instance.new("UIScale")
		n.Name = "PopScale"
		n.Parent = gui
		return n
	end
	return s
end

function UiKit.tween(inst: Instance, seconds: number, props: { [string]: any }, style: Enum.EasingStyle?, dir: Enum.EasingDirection?): Tween
	local t = TweenService:Create(inst, TweenInfo.new(seconds, style or Enum.EasingStyle.Quad, dir or Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

-- Scale pop 0 -> 1.15 -> 1.
function UiKit.pop(gui: GuiObject, duration: number?)
	local scale = scaleOf(gui)
	scale.Scale = 0
	local d = duration or 0.25
	local up = UiKit.tween(scale, d * 0.6, { Scale = 1.15 }, Enum.EasingStyle.Back)
	up.Completed:Connect(function()
		UiKit.tween(scale, d * 0.4, { Scale = 1 })
	end)
end

-- Bump an existing element: 1 -> 1+amount -> 1.
function UiKit.punch(gui: GuiObject, amount: number?)
	local scale = scaleOf(gui)
	scale.Scale = 1 + (amount or 0.2)
	UiKit.tween(scale, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

-- Rattle a GuiObject around its current Position (restores it afterwards). Not for UIListLayout children
-- (the layout owns their Position): shake a child of theirs instead.
local shaking: { [GuiObject]: boolean } = {}
function UiKit.shake(gui: GuiObject, seconds: number?, px: number?)
	if shaking[gui] then
		return
	end
	shaking[gui] = true
	local home = gui.Position
	local amp = px or 6
	task.spawn(function()
		local t0 = os.clock()
		local dur = seconds or 0.3
		while os.clock() - t0 < dur and gui.Parent do
			local k = 1 - (os.clock() - t0) / dur
			gui.Position = home + UDim2.fromOffset(math.random(-amp, amp) * k, math.random(-amp, amp) * k)
			task.wait(1 / 30)
		end
		gui.Position = home
		shaking[gui] = nil
	end)
end

-- 125 -> "2:05"
function UiKit.clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

-- Colour for a Shared/Notify kind ("info" | "good" | "bad" | "blame").
function UiKit.kindColor(kind: string): Color3
	if kind == "good" then
		return Palette.UiGood
	elseif kind == "bad" then
		return Palette.UiRed
	elseif kind == "blame" then
		return Palette.UiWarn
	end
	return Palette.UiCream
end

-- 2D one-shot. Empty / nil ids are a no-op so unverified sounds never error.
function UiKit.sound(id: string?, volume: number?, pitch: number?)
	if not id or id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume or 0.6
	s.PlaybackSpeed = (pitch or 1) * (1 + (math.random() - 0.5) * 0.08)
	s.Parent = SoundService
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
	task.delay(8, function()
		if s.Parent then
			s:Destroy()
		end
	end)
end

return UiKit
