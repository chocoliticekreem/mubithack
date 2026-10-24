--!strict
-- ProfileController [owner: Data]. Lobby level badge + XP bar (top left, hidden during a mission) and
-- "+XP" popups / LEVEL UP banner from Data/XpGained. Reads the Player attrs DataService writes
-- (DataConfig.Attr). Renders only; never decides anything. docs/game/06-data.md.
local GuiService = game:GetService("GuiService")
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
	-- the level panel sits UP in the Roblox top-bar row, right against the menu buttons (GuiService.TopbarInset)
	g.IgnoreGuiInset = true
	g.ScreenInsets = Enum.ScreenInsets.None
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
				-- right after Roblox's menu/chat buttons, vertically centred in the top bar
				local bar = GuiService.TopbarInset
				local x = (bar.Min.X + 8) / s
				local h = 64 * s
				local y = math.max(2, (bar.Height - h) / 2 + 4) / s
				levelPanel.Position = UDim2.fromOffset(x, y)
			end
		end
	end
	if Workspace.CurrentCamera then
		(Workspace.CurrentCamera :: Camera):GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(rescale)

	local p = Instance.new("Frame")
	p.Name = "LevelPanel"
	p.Position = UDim2.fromOffset(172, 4) -- rescale() puts it right after the Roblox menu buttons
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

local function popup(text: string, sub: string?, color: Color3, size: number, seconds: number, y: number?)
	if not popupLayer then
		return
	end
	popupCount += 1
	local slot = popupCount % 4
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0.5)
	holder.Position = UDim2.new(0.5, 0, y or 0.38, slot * 18)
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

-- LEVEL UP celebration: confetti burst from behind the banner, a gold screen-edge flash, the level badge
-- bounces, and the LevelUp stinger (AudioController ducks the music). Cheap: ~28 frames for ~1.6 s.
local CONFETTI = { Palette.HelmetRed, Palette.HelmetShield, Palette.UiCream, Palette.WaterSpray, Color3.fromRGB(255, 211, 90) }
local controllers: { [string]: any } = {}

local function celebrate()
	local audio = controllers.AudioController
	if audio and type(audio.Stinger) == "function" then
		pcall(audio.Stinger, audio, "LevelUp")
	end
	if not popupLayer then
		return
	end
	local layer = popupLayer :: Frame
	local glow = Instance.new("Frame")
	glow.BackgroundColor3 = Color3.fromRGB(255, 211, 90)
	glow.BackgroundTransparency = 0.55
	glow.BorderSizePixel = 0
	glow.Size = UDim2.fromScale(1, 1)
	glow.ZIndex = 0
	glow.Parent = layer
	TweenService:Create(glow, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
	task.delay(0.7, function()
		glow:Destroy()
	end)
	local rng = Random.new()
	for i = 1, 28 do
		local c = Instance.new("Frame")
		c.BorderSizePixel = 0
		c.AnchorPoint = Vector2.new(0.5, 0.5)
		c.BackgroundColor3 = CONFETTI[(i - 1) % #CONFETTI + 1]
		c.Size = UDim2.fromOffset(rng:NextInteger(8, 14), rng:NextInteger(5, 9))
		c.Position = UDim2.fromScale(0.5, 0.62)
		c.Rotation = rng:NextNumber(0, 360)
		c.Parent = layer
		local angle = rng:NextNumber(0, math.pi * 2)
		local dist = rng:NextNumber(0.12, 0.32)
		local up = TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		TweenService:Create(c, up, {
			Position = UDim2.fromScale(0.5 + math.cos(angle) * dist, 0.62 + math.sin(angle) * dist * 0.7 - 0.08),
			Rotation = c.Rotation + rng:NextNumber(-220, 220),
		}):Play()
		task.delay(0.45, function()
			local fall = TweenInfo.new(1.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			TweenService:Create(c, fall, {
				Position = c.Position + UDim2.fromScale(rng:NextNumber(-0.04, 0.04), 0.35),
				BackgroundTransparency = 1,
				Rotation = c.Rotation + rng:NextNumber(-180, 180),
			}):Play()
			task.delay(1.15, function()
				c:Destroy()
			end)
		end)
	end
	if panel and levelLabel then
		local s = (levelLabel :: TextLabel).Parent and (levelLabel :: TextLabel).Parent:FindFirstChildOfClass("UIScale")
		if not s then
			s = Instance.new("UIScale")
			s.Parent = (levelLabel :: TextLabel).Parent
		end
		local us = s :: UIScale
		us.Scale = 1.5
		TweenService:Create(us, TweenInfo.new(0.5, Enum.EasingStyle.Elastic, Enum.EasingDirection.Out), { Scale = 1 }):Play()
	end
end

function ProfileController:Init(all: { [string]: any })
	controllers = all
end

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
				-- centre celebrations take turns (ClientLib/HudLayout): this, then NEW GEAR, then TIER UP,
				-- and only once the results screen has closed
				local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
				HudLayout.celebrate(function()
					popup(`LEVEL {level}!`, nil, Palette.UiCream, 80, DataConfig.Ui.LevelUpSeconds, 0.62)
					celebrate()
					return (tonumber(DataConfig.Ui.LevelUpSeconds) or 2) + 0.2
				end)
			end)
		end
	end)
end

return ProfileController
