--!strict
-- TopBox [owner: G3]. ONE compact box up in the Roblox top-bar row, right after the menu buttons:
--   [ level badge | XP bar ]  [ pass tier | pass bar ]  [ STORE ]
-- ProfileController fills "Level", BattlePassController "Pass" (click: open the pass), StoreController
-- "Store" (a small button, lobby only). It is pixel-sized like Roblox's own top-bar buttons (no viewport
-- UIScale), so it stays inside the top-bar row on a phone and on a monitor, and never reaches the
-- top-centre stack under the bar (ClientLib/HudLayout).
--
--   TopBox.section(name, order, width) -> Frame   a slot (full box height) the caller fills; hide it with
--                                                 .Visible and the box closes up around it
--   TopBox.Height                                 the box's inner height in px
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any

local TopBox = {}
TopBox.Height = 40

local box: Frame? = nil
local sections: { [string]: Frame } = {}

local function place(b: Frame)
	local bar = GuiService.TopbarInset
	-- the free part of the top bar starts after Roblox's menu / chat buttons (Min.X); 0 before it loads
	local left = if bar.Min.X > 0 then bar.Min.X else 164
	local barH = if bar.Height > 0 then bar.Height else 58
	local h = math.clamp(barH - 12, 32, 40)
	TopBox.Height = h
	b.Size = UDim2.fromOffset(0, h)
	b.Position = UDim2.fromOffset(left + 8, bar.Min.Y + math.floor((barH - h) / 2))
end

local function refreshVisible(b: Frame)
	local any = false
	for _, s in sections do
		if s.Visible then
			any = true
		end
	end
	b.Visible = any
end

local function get(): Frame
	if box and box.Parent then
		return box :: Frame
	end
	local pg = Players.LocalPlayer:WaitForChild("PlayerGui")
	local old = pg:FindFirstChild("TopBox")
	if old then
		old:Destroy()
	end
	local g = Instance.new("ScreenGui")
	g.Name = "TopBox"
	g.ResetOnSpawn = false
	g.IgnoreGuiInset = true -- up in the top-bar row
	g.ScreenInsets = Enum.ScreenInsets.None
	g.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	g.DisplayOrder = 6
	local b = Instance.new("Frame")
	b.Name = "Box"
	b.AutomaticSize = Enum.AutomaticSize.X
	b.BackgroundColor3 = Palette.UiCream
	b.BorderSizePixel = 0
	b.Visible = false
	b.Parent = g
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 10)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Thickness = 2.5
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = b
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingRight = UDim.new(0, 6)
	pad.Parent = b
	local list = Instance.new("UIListLayout")
	list.FillDirection = Enum.FillDirection.Horizontal
	list.VerticalAlignment = Enum.VerticalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 8)
	list.Parent = b
	place(b)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(function()
		place(b)
	end)
	g.Parent = pg
	box = b
	-- world markers / edge arrows keep off it (ClientLib/HudLayout)
	task.spawn(function()
		local ok, HudLayout = pcall(require, script.Parent:WaitForChild("HudLayout") :: ModuleScript)
		if ok then
			(HudLayout :: any).reserve(b)
		end
	end)
	return b
end

function TopBox.section(name: string, order: number, width: number): Frame
	local b = get()
	local existing = sections[name]
	if existing and existing.Parent then
		return existing
	end
	local f = Instance.new("Frame")
	f.Name = name
	f.LayoutOrder = order * 10
	f.Size = UDim2.new(0, width, 1, 0)
	f.BackgroundTransparency = 1
	f.Parent = b
	sections[name] = f
	if order > 1 then
		-- a thin divider before every section but the first, hidden with it
		local d = Instance.new("Frame")
		d.Name = name .. "Divider"
		d.LayoutOrder = order * 10 - 5
		d.Size = UDim2.new(0, 2, 1, -14)
		d.BackgroundColor3 = Palette.UiInk
		d.BackgroundTransparency = 0.8
		d.BorderSizePixel = 0
		d.Parent = b
		d.Visible = f.Visible
		f:GetPropertyChangedSignal("Visible"):Connect(function()
			d.Visible = f.Visible
		end)
	end
	f:GetPropertyChangedSignal("Visible"):Connect(function()
		refreshVisible(b)
	end)
	refreshVisible(b)
	return f
end

return TopBox
