--!strict
-- ProfileController [owner: Data]. Lobby level badge + XP bar (top left, hidden during a mission) and
-- "+XP" popups / LEVEL UP banner from Data/XpGained. Reads the Player attrs DataService writes
-- (DataConfig.Attr). Renders only; never decides anything. docs/game/06-data.md.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local DataConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("DataConfig") :: ModuleScript) :: any

local ProfileController = {}
ProfileController.Priority = 100

local player = Players.LocalPlayer
local gui: ScreenGui? = nil
local panel: Frame? = nil
local levelLabel: TextLabel? = nil
local fill: Frame? = nil
local xpLabel: TextLabel? = nil
local popupLayer: Frame? = nil

local function stroke(parent: Instance, thickness: number)
	local s = Instance.new("UIStroke")
	s.Thickness = thickness
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	s.Parent = parent
end

local function corner(parent: Instance, px: number)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, px)
	c.Parent = parent
end

local function label(parent: Instance, name: string, font: Enum.Font, color: Color3): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Font = font
	l.TextScaled = true
	l.TextColor3 = color
	l.Text = ""
	l.Parent = parent
	stroke(l, 2)
	return l
end

local function inLobby(): boolean
	local inst = player:GetAttribute(Names.Attr.InstanceId)
	if type(inst) == "string" and inst ~= "" then
		return false
	end
	local state = Workspace:GetAttribute(Names.Attr.RoundState)
	return state ~= "Active" and state ~= "Alarm"
end

local function update()
	if not panel then
		return
	end
	local A = DataConfig.Attr
	local ready = player:GetAttribute(A.ProfileReady) == true
	;(panel :: Frame).Visible = ready and inLobby()
	local level = (player:GetAttribute(A.Level) :: number?) or 1
	local into = (player:GetAttribute(A.Xp) :: number?) or 0
	local need = (player:GetAttribute(A.XpNext) :: number?) or 0
	;(levelLabel :: TextLabel).Text = tostring(level)
	local frac = if need > 0 then math.clamp(into / need, 0, 1) else 1
	TweenService:Create(fill :: Frame, TweenInfo.new(0.35, Enum.EasingStyle.Quad), { Size = UDim2.fromScale(frac, 1) }):Play()
	;(xpLabel :: TextLabel).Text = if need > 0 then `{into} / {need} XP` else "MAX LEVEL"
end

local function build()
	local g = Instance.new("ScreenGui")
	g.Name = "ProfileHud"
	g.ResetOnSpawn = false
	-- respect the Roblox top bar / core UI (y = 0 is just under it)
	g.IgnoreGuiInset = false
	g.ScreenInsets = Enum.ScreenInsets.CoreUISafeInsets
	g.DisplayOrder = 5

	local scale = Instance.new("UIScale")
	scale.Parent = g
	local levelPanel: Frame? = nil
	local function rescale()
		local cam = Workspace.CurrentCamera
		if cam then
			local s = math.max(0.6, math.min(cam.ViewportSize.X / 1280, cam.ViewportSize.Y / 720))
			scale.Scale = s
			-- narrow windows (the 0.6 floor kicks in): the centred objective card (520 px, top) would run
			-- into this panel, so drop it below the card instead
			if levelPanel then
				local narrow = cam.ViewportSize.X < (1128 * s + 16)
				levelPanel.Position = if narrow then UDim2.fromOffset(16, 100) else UDim2.fromOffset(16, 42)
			end
		end
	end
	if Workspace.CurrentCamera then
		(Workspace.CurrentCamera :: Camera):GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end

	local p = Instance.new("Frame")
	p.Name = "LevelPanel"
	p.Position = UDim2.fromOffset(16, 42) -- under the Roblox top bar (safe-inset gui) + clear of the HUD band
	p.Size = UDim2.fromOffset(280, 64)
	p.BackgroundColor3 = Palette.UiCream
	p.Visible = false
	p.Parent = g
	corner(p, 12)
	stroke(p, 3)
	levelPanel = p
	rescale()

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.Size = UDim2.fromOffset(72, 72)
	badge.Position = UDim2.fromOffset(-12, -4)
	badge.BackgroundColor3 = Palette.HelmetRed
	badge.Parent = p
	corner(badge, 36)
	stroke(badge, 3)
	local lv = label(badge, "Level", Enum.Font.LuckiestGuy, Palette.UiCream)
	lv.Size = UDim2.fromScale(0.7, 0.55)
	lv.Position = UDim2.fromScale(0.15, 0.25)
	local cap = label(badge, "Caption", Enum.Font.LuckiestGuy, Palette.HelmetShield)
	cap.Text = "LVL"
	cap.Size = UDim2.fromScale(0.6, 0.22)
	cap.Position = UDim2.fromScale(0.2, 0.06)

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Position = UDim2.fromOffset(72, 34)
	bar.Size = UDim2.fromOffset(196, 18)
	bar.BackgroundColor3 = Palette.UiPanelDark
	bar.Parent = p
	corner(bar, 9)
	stroke(bar, 2)
	local f = Instance.new("Frame")
	f.Name = "Fill"
	f.Size = UDim2.fromScale(0, 1)
	f.BackgroundColor3 = Palette.HelmetShield
	f.Parent = bar
	corner(f, 9)

	local xl = label(p, "Xp", Enum.Font.FredokaOne, Palette.UiInk)
	xl.Position = UDim2.fromOffset(72, 6)
	xl.Size = UDim2.fromOffset(196, 24)
	xl.TextXAlignment = Enum.TextXAlignment.Left
	local xs = xl:FindFirstChildOfClass("UIStroke")
	if xs then
		xs:Destroy() -- ink text on cream needs no outline
	end

	local layer = Instance.new("Frame")
	layer.Name = "Popups"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Parent = g

	g.Parent = player:WaitForChild("PlayerGui")
	gui, panel, levelLabel, fill, xpLabel, popupLayer = g, p, lv, f, xl, layer
end

local popupCount = 0

local function popup(text: string, sub: string?, color: Color3, size: number, seconds: number)
	if not popupLayer then
		return
	end
	popupCount += 1
	local slot = popupCount % 4
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, 0.38, slot * 18)
	holder.Size = UDim2.fromOffset(420, size + 26)
	holder.Parent = popupLayer
	local scale = Instance.new("UIScale")
	scale.Scale = 0.4
	scale.Parent = holder
	local main = label(holder, "Main", Enum.Font.LuckiestGuy, color)
	main.Size = UDim2.new(1, 0, 0, size)
	main.Text = text
	local labels = { main }
	if sub then
		local s = label(holder, "Sub", Enum.Font.FredokaOne, Palette.UiCream)
		s.Size = UDim2.new(1, 0, 0, 24)
		s.Position = UDim2.fromOffset(0, size)
		s.Text = sub
		table.insert(labels, s)
	end
	TweenService:Create(scale, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	task.delay(seconds * 0.45, function()
		local info = TweenInfo.new(seconds * 0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(holder, info, { Position = holder.Position - UDim2.fromOffset(0, 80) }):Play()
		for _, l in labels do
			TweenService:Create(l, info, { TextTransparency = 1 }):Play()
			local st = l:FindFirstChildOfClass("UIStroke")
			if st then
				TweenService:Create(st, info, { Transparency = 1 }):Play()
			end
		end
	end)
	task.delay(seconds + 0.1, function()
		holder:Destroy()
	end)
end

function ProfileController:Init(_controllers: { [string]: any }) end

function ProfileController:Start()
	build()
	local A = DataConfig.Attr
	for _, name in { A.Level, A.Xp, A.XpNext, A.ProfileReady, Names.Attr.InstanceId } do
		player:GetAttributeChangedSignal(name):Connect(update)
	end
	Workspace:GetAttributeChangedSignal(Names.Attr.RoundState):Connect(update)
	update()

	local xpGained = Net.event("Data", "XpGained")
	xpGained.OnClientEvent:Connect(function(amount: number, reason: string, level: number, levelsGained: number)
		if type(amount) ~= "number" or amount <= 0 then
			return
		end
		popup(`+{math.floor(amount)} XP`, if type(reason) == "string" then reason else nil, Palette.HelmetShield, 54, DataConfig.Ui.PopupSeconds)
		if type(levelsGained) == "number" and levelsGained > 0 then
			task.delay(0.5, function()
				popup(`LEVEL {level}!`, nil, Palette.UiCream, 80, DataConfig.Ui.LevelUpSeconds)
			end)
		end
	end)
end

return ProfileController
