--!strict
-- ProfileController [owner: Data]. Level badge + XP bar (the first section of the top-bar box,
-- ClientLib/TopBox) and
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
local Calm = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("Calm") :: ModuleScript)

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

local function update()
	if not panel then
		return
	end
	local A = DataConfig.Attr
	local ready = player:GetAttribute(A.ProfileReady) == true
	-- the top-bar box shows level + XP in the lobby and on a call alike (it lives in the top-bar row,
	-- clear of the mission HUD); the store button next to it is the lobby-only part
	;(panel :: Frame).Visible = ready
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

	-- the popups layer scales with the viewport; the level readout lives in the shared top-bar box
	local scale = Instance.new("UIScale")
	scale.Parent = g
	local function rescale()
		local cam = Workspace.CurrentCamera
		if cam then
			scale.Scale = math.max(0.6, math.min(cam.ViewportSize.X / 1280, cam.ViewportSize.Y / 720))
		end
	end
	if Workspace.CurrentCamera then
		(Workspace.CurrentCamera :: Camera):GetPropertyChangedSignal("ViewportSize"):Connect(rescale)
	end
	rescale()

	-- level + XP: the first section of ClientLib/TopBox (one compact box in the top-bar row)
	local TopBox = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("TopBox") :: ModuleScript) :: any
	local p = TopBox.section("Level", 1, 150) :: Frame
	p.Visible = false

	local badge = Instance.new("Frame")
	badge.Name = "Badge"
	badge.AnchorPoint = Vector2.new(0, 0.5)
	badge.Size = UDim2.fromOffset(32, 32)
	badge.Position = UDim2.fromScale(0, 0.5)
	badge.BackgroundColor3 = Palette.HelmetRed
	badge.Parent = p
	corner(badge, 16)
	stroke(badge, 2)
	local lv = label(badge, "Level", Enum.Font.LuckiestGuy, Palette.UiCream)
	lv.Size = UDim2.fromScale(0.8, 0.62)
	lv.Position = UDim2.fromScale(0.1, 0.22)

	local xl = label(p, "Xp", Enum.Font.FredokaOne, Palette.UiInk)
	xl.Position = UDim2.new(0, 38, 0.5, -15)
	xl.Size = UDim2.new(1, -38, 0, 15)
	xl.TextScaled = false
	xl.TextSize = 13
	xl.TextXAlignment = Enum.TextXAlignment.Left
	local xs = xl:FindFirstChildOfClass("UIStroke")
	if xs then
		xs:Destroy() -- ink text on cream needs no outline
	end

	local bar = Instance.new("Frame")
	bar.Name = "Bar"
	bar.Position = UDim2.new(0, 38, 0.5, 3)
	bar.Size = UDim2.new(1, -38, 0, 9)
	bar.BackgroundColor3 = Palette.UiPanelDark
	bar.Parent = p
	corner(bar, 5)
	local f = Instance.new("Frame")
	f.Name = "Fill"
	f.Size = UDim2.fromScale(0, 1)
	f.BackgroundColor3 = Palette.HelmetShield
	f.Parent = bar
	corner(f, 5)

	local layer = Instance.new("Frame")
	layer.Name = "Popups"
	layer.BackgroundTransparency = 1
	layer.Size = UDim2.fromScale(1, 1)
	layer.Parent = g

	g.Parent = player:WaitForChild("PlayerGui")
	gui, panel, levelLabel, fill, xpLabel, popupLayer = g, p, lv, f, xl, layer
end

local popupCount = 0

local function popup(text: string, sub: string?, color: Color3, size: number, seconds: number, y: number?): Frame?
	if not popupLayer then
		return nil
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
	return holder
end

-- Calm (phones / EFFECTS: CALM): a small "+50 XP" tick right under the level bar in the top box instead of
-- a big number in the middle of the screen (where you aim the hose)
local function tick(text: string)
	local layer, p = popupLayer, panel
	if not layer or not p or not p.Visible then
		return
	end
	local sc = (gui :: ScreenGui):FindFirstChildOfClass("UIScale")
	local s = if sc then sc.Scale else 1
	local rel = p.AbsolutePosition - layer.AbsolutePosition
	local holder = Instance.new("Frame")
	holder.Name = "XpTick"
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(120, 22)
	holder.Position = UDim2.fromOffset((rel.X + 38 * s) / s, (rel.Y + p.AbsoluteSize.Y + 4) / s)
	holder.Parent = layer
	local l = label(holder, "Main", Enum.Font.FredokaOne, Palette.HelmetShield)
	l.Size = UDim2.fromScale(1, 1)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.Text = text
	local info = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	task.delay(0.9, function()
		TweenService:Create(l, info, { TextTransparency = 1 }):Play()
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			TweenService:Create(st, info, { Transparency = 1 }):Play()
		end
	end)
	task.delay(1.6, function()
		holder:Destroy()
	end)
end

-- XP lands in bursts (five fires out at once): one popup with the sum
local xpPending, xpReason, xpToken = 0, "", 0
local function xpGain(amount: number, reason: string?)
	xpPending += amount
	xpReason = reason or xpReason
	xpToken += 1
	local token = xpToken
	task.delay(if Calm.on() then 1.0 else 0.6, function()
		if token ~= xpToken or xpPending <= 0 then
			return
		end
		local n = math.floor(xpPending)
		xpPending = 0
		if Calm.on() then
			tick(`+{n} XP`)
		else
			popup(`+{n} XP`, if xpReason ~= "" then xpReason else nil, Palette.HelmetShield, 54, DataConfig.Ui.PopupSeconds)
		end
		xpReason = ""
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
	glow.BackgroundTransparency = Calm.alpha(0.55) -- calm: a faint glow, not a gold flash
	glow.BorderSizePixel = 0
	glow.Size = UDim2.fromScale(1, 1)
	glow.ZIndex = 0
	glow.Parent = layer
	TweenService:Create(glow, TweenInfo.new(0.6, Enum.EasingStyle.Quad), { BackgroundTransparency = 1 }):Play()
	task.delay(0.7, function()
		glow:Destroy()
	end)
	local rng = Random.new()
	for i = 1, if Calm.on() then 10 else 28 do
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
		xpGain(amount, if type(reason) == "string" then reason else nil)
		if type(levelsGained) == "number" and levelsGained > 0 then
			task.delay(0.5, function()
				-- centre celebrations take turns (ClientLib/HudLayout): this, then NEW GEAR, then TIER UP,
				-- and only once the results screen has closed
				local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
				HudLayout.celebrate(function()
					local secs = Calm.seconds(tonumber(DataConfig.Ui.LevelUpSeconds) or 2, 1.8)
					local card = popup(`LEVEL {level}!`, nil, Palette.UiCream, 80, secs, 0.62)
					celebrate()
					-- a tap anywhere hides it early (HudLayout.celebrate)
					return secs + 0.2, function()
						if card then
							card:Destroy()
						end
					end
				end)
			end)
		end
	end)
end

return ProfileController
