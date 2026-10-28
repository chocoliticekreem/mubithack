--!strict
-- ChipMenu [owner: G3]. The left chip column, folded into ONE ☰ MENU chip (docs/game/22-declutter.md).
-- Every lobby chip (PASS, NEWS, INVITE, TROPHIES, HELP, ADMIN, HELI) still lives in its owner's ScreenGui and
-- its owner still decides when it's available (chip.Visible, its gui's Enabled / HudGate). They register with
-- HudLayout.add("Chips", chip, order), which lands here:
--   * none available: nothing. One: that chip alone, where ☰ sits (a new player's HELP).
--   * two or more: the ☰ MENU chip (left edge, middle, clear of a phone's thumbstick) with a red dot when any
--     chip inside has its own badge / dot up (rewards to claim, news, trophies). Tap it: a compact grid panel
--     opens beside it with the chips in it (2 columns, 3 from 5 chips). Tap a chip, outside, ☰ again, B or a
--     menu opening (keybinds [P] [H] [;] still work on their own) closes it.
-- How: while a chip is not on screen here its Visible is held false; whatever its owner sets meanwhile is
-- remembered (HudRevealController's trick) and put back when it shows. Positions: every chip gui is a
-- UiKit.screen like ours, so design units line up; the grid enlarges chips to CellW x CellH.
-- Gamepad: ☰ is a HUD button (D-pad left reaches it, GamepadNav.HudPriority "MenuChip"); the panel is a
-- GamepadNav menu whose companions are the chips' guis, so the cursor lands on the first chip and B closes.
--   ChipMenu.adopt(chip, order)   (HudLayout.add("Chips", ...))
--   ChipMenu.setOpen(open), ChipMenu.isOpen() -> boolean, ChipMenu.debug() -> table (tests)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local HudRules = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("HudRules") :: ModuleScript)

local ChipMenu = {}
ChipMenu.CellW = 150
ChipMenu.CellH = 52
ChipMenu.Gap = 8
ChipMenu.ButtonW = 118
ChipMenu.ButtonH = 44
ChipMenu.Left = 13

type Entry = { chip: GuiObject, order: number, wanted: boolean, setting: boolean, placed: boolean, size: UDim2 }

local entries: { Entry } = {}
local gui: ScreenGui? = nil
local button: TextButton? = nil
local dot: Frame? = nil
local panel: Frame? = nil
local backdrop: TextButton? = nil
local open = false
local mode = "none"
local queued = false
local layout: () -> ()

local function uiKit(): any
	return require(script.Parent:WaitForChild("UiKit") :: ModuleScript)
end

local function guiOf(o: Instance): ScreenGui?
	return o:FindFirstAncestorOfClass("ScreenGui")
end

local function available(e: Entry): boolean
	if not e.wanted or not e.chip.Parent then
		return false
	end
	local g = guiOf(e.chip)
	return g ~= nil and g.Enabled
end

local function setVisible(e: Entry, v: boolean)
	if e.chip.Visible ~= v then
		e.setting = true
		e.chip.Visible = v
		e.setting = false
	end
end

local function setProp(o: Instance, prop: string, v: any)
	if (o :: any)[prop] ~= v then
		(o :: any)[prop] = v
	end
end

local function schedule()
	if queued then
		return
	end
	queued = true
	task.defer(function()
		queued = false
		local ok, err = pcall(layout)
		if not ok then
			warn(`[ChipMenu] {err}`)
		end
	end)
end

local function badgeUp(chip: GuiObject): boolean
	for _, d in chip:GetDescendants() do
		if (d.Name == "Dot" or d.Name == "Badge") and d:IsA("GuiObject") and d.Visible then
			return true
		end
	end
	return false
end

local function build()
	if gui and gui.Parent then
		return
	end
	local UiKit = uiKit()
	local g = UiKit.screen("ChipMenuGui", 7) :: ScreenGui -- under every chip gui (HeliHud 8, the rest 25-45): they draw on the panel
	gui = g
	local bd = Instance.new("TextButton")
	bd.Name = "Backdrop"
	bd.Text = ""
	bd.AutoButtonColor = false
	bd.BackgroundColor3 = Color3.new(0, 0, 0)
	bd.BackgroundTransparency = 0.75
	bd.BorderSizePixel = 0
	bd.Size = UDim2.fromScale(3, 3)
	bd.Position = UDim2.fromScale(-1, -1)
	bd.Selectable = false
	bd.Visible = false
	bd.ZIndex = 1
	bd.Parent = g
	bd.Activated:Connect(function()
		ChipMenu.setOpen(false)
	end)
	backdrop = bd

	local b = Instance.new("TextButton")
	b.Name = "MenuChip"
	b.Size = UDim2.fromOffset(ChipMenu.ButtonW, ChipMenu.ButtonH)
	b.Position = UDim2.fromOffset(ChipMenu.Left, 300)
	b.BackgroundColor3 = Palette.UiPanelDark
	b.Text = ""
	b.AutoButtonColor = true
	b.Visible = false
	b.ZIndex = 3
	b.Parent = g
	UiKit.corner(b, 10)
	UiKit.stroke(b, 3, Palette.UiInk)
	-- ☰ drawn with frames (the fonts have no ☰ glyph)
	for i = 0, 2 do
		local bar = Instance.new("Frame")
		bar.Name = `Bar{i}`
		bar.Size = UDim2.fromOffset(22, 4)
		bar.Position = UDim2.fromOffset(14, 13 + i * 8)
		bar.BackgroundColor3 = Palette.UiCream
		bar.BorderSizePixel = 0
		bar.ZIndex = 4
		bar.Parent = b
		UiKit.corner(bar, 2)
	end
	local t = UiKit.label(b, "Label", "MENU", UDim2.new(1, -46, 1, 0), UDim2.fromOffset(42, 1), {
		font = UiKit.Header,
		textSize = 22,
		color = Palette.UiCream,
	})
	t.ZIndex = 4
	local d = Instance.new("Frame")
	d.Name = "Dot"
	d.AnchorPoint = Vector2.new(0.5, 0.5)
	d.Position = UDim2.new(1, -4, 0, 4)
	d.Size = UDim2.fromOffset(16, 16)
	d.BackgroundColor3 = Palette.UiRed
	d.BorderSizePixel = 0
	d.Visible = false
	d.ZIndex = 5
	d.Parent = b
	UiKit.corner(d, 8)
	UiKit.stroke(d, 2, Palette.UiCream)
	dot = d
	UiKit.onTap(b, function()
		ChipMenu.setOpen(not open)
	end)
	button = b

	local p = Instance.new("Frame")
	p.Name = "MenuPanel"
	p.BackgroundColor3 = Palette.UiPanelDark
	p.BackgroundTransparency = 0.1
	p.Visible = false
	p.ZIndex = 2
	p.Parent = g
	p:SetAttribute("Menu", true) -- MenuMouseController frees the mouse in first person
	UiKit.corner(p, 14)
	UiKit.stroke(p, 3, Palette.UiInk)
	panel = p

	-- reflow on anything that moves the screen
	local sc = g:FindFirstChild("ViewportScale")
	if sc and sc:IsA("UIScale") then
		sc:GetPropertyChangedSignal("Scale"):Connect(schedule)
	end
	g:GetPropertyChangedSignal("AbsoluteSize"):Connect(schedule)
	g:GetPropertyChangedSignal("Enabled"):Connect(schedule)

	pcall(function()
		local GamepadNav = require(script.Parent:WaitForChild("GamepadNav") :: ModuleScript) :: any
		GamepadNav.menu(p, {
			back = function()
				ChipMenu.setOpen(false)
			end,
			default = function(): GuiObject?
				for _, e in entries do
					if e.placed then
						return e.chip
					end
				end
				return nil
			end,
			companions = {},
		})
	end)
	-- a real menu opening (PASS by its key, STORE ...) closes this one
	task.spawn(function()
		local HudLayout = require(script.Parent:WaitForChild("HudLayout") :: ModuleScript) :: any
		HudLayout.reserve(b) -- edge arrows / world markers keep off ☰ and the panel
		HudLayout.reserve(p)
		HudLayout.ModalChanged.Event:Connect(function(isOpen: boolean)
			if isOpen and open then
				ChipMenu.setOpen(false)
			end
		end)
	end)
	-- badges come and go inside the chips; cheap poll (also a safety net for missed signals)
	task.spawn(function()
		while g.Parent do
			task.wait(0.5)
			schedule()
		end
	end)
end

layout = function()
	local g, b, p, d = gui, button, panel, dot
	if not (g and b and p and d) then
		return
	end
	table.sort(entries, function(x: Entry, y: Entry)
		return x.order < y.order
	end)
	local avail: { Entry } = {}
	for _, e in entries do
		if available(e) then
			table.insert(avail, e)
		end
	end
	mode = HudRules.menuMode(#avail)
	if mode ~= "menu" then
		open = false
	end
	local sc = g:FindFirstChild("ViewportScale")
	local s = if sc and sc:IsA("UIScale") and sc.Scale > 0 then sc.Scale else 1
	local area = g.AbsoluteSize
	local H = (if area.Y > 0 then area.Y else 720) / s
	-- ☰ (or the lone chip): left edge, middle, never down where a thumbstick / the D-pad legend sits
	local bh = ChipMenu.ButtonH
	local by = math.floor(math.max(60, math.min(H * 0.5 - bh * 0.5, H - 130 / s - bh)))
	setProp(b, "Position", UDim2.fromOffset(ChipMenu.Left, by))
	setProp(b, "Visible", mode == "menu")
	local anyBadge = false
	for _, e in avail do
		if badgeUp(e.chip) then
			anyBadge = true
		end
	end
	setProp(d, "Visible", anyBadge and not open)

	local grid = HudRules.grid(#avail, ChipMenu.CellW, ChipMenu.CellH, ChipMenu.Gap)
	local px = ChipMenu.Left + ChipMenu.ButtonW + 10
	local py = math.floor(math.clamp(by + bh * 0.5 - grid.h * 0.5, 8, math.max(8, H - grid.h - 8)))
	setProp(p, "Size", UDim2.fromOffset(grid.w, grid.h))
	setProp(p, "Position", UDim2.fromOffset(px, py))
	setProp(p, "Visible", open)
	if backdrop then
		setProp(backdrop, "Visible", open)
	end
	local names: { string } = {}
	for _, e in entries do
		e.placed = false
	end
	if mode == "single" then
		local e = avail[1]
		e.placed = true
		setProp(e.chip, "Size", e.size)
		setProp(e.chip, "Position", UDim2.fromOffset(ChipMenu.Left, by))
	elseif mode == "menu" and open then
		for i, e in avail do
			local c = grid.cells[i]
			e.placed = true
			setProp(e.chip, "Size", UDim2.fromOffset(ChipMenu.CellW, ChipMenu.CellH))
			setProp(e.chip, "Position", UDim2.fromOffset(px + c.x, py + c.y))
			local cg = guiOf(e.chip)
			if cg and not table.find(names, cg.Name) then
				table.insert(names, cg.Name)
			end
		end
	end
	for _, e in entries do
		setVisible(e, e.placed and e.wanted)
	end
	pcall(function()
		local GamepadNav = require(script.Parent:WaitForChild("GamepadNav") :: ModuleScript) :: any
		GamepadNav.menu(p, { companions = names })
	end)
end

function ChipMenu.adopt(chip: GuiObject, order: number)
	for _, e in entries do
		if e.chip == chip then
			return
		end
	end
	build()
	local e: Entry = { chip = chip, order = order, wanted = chip.Visible, setting = false, placed = false, size = chip.Size }
	table.insert(entries, e)
	chip:GetPropertyChangedSignal("Visible"):Connect(function()
		if e.setting then
			return
		end
		e.wanted = chip.Visible
		if e.wanted and not e.placed then
			setVisible(e, false) -- remembered; shown when the menu opens
		end
		schedule()
	end)
	local function hookGui()
		local g = guiOf(chip)
		if g then
			g:GetPropertyChangedSignal("Enabled"):Connect(schedule)
		end
	end
	hookGui()
	chip.AncestryChanged:Connect(schedule)
	if chip:IsA("GuiButton") then
		(chip :: GuiButton).Activated:Connect(function()
			if open then
				task.defer(ChipMenu.setOpen, false)
			end
		end)
	end
	chip.Destroying:Connect(function()
		local i = table.find(entries, e)
		if i then
			table.remove(entries, i)
		end
		schedule()
	end)
	if not e.placed then
		setVisible(e, false)
	end
	schedule()
end

function ChipMenu.setOpen(want: boolean)
	local v = want and mode == "menu"
	if v == open then
		return
	end
	open = v
	local ok, err = pcall(layout)
	if not ok then
		warn(`[ChipMenu] {err}`)
	end
	if open and panel then
		pcall(function()
			uiKit().pop(panel, 0.18)
		end)
	end
end

function ChipMenu.isOpen(): boolean
	return open
end

function ChipMenu.debug(): { [string]: any }
	local list = {}
	for _, e in entries do
		table.insert(list, { name = e.chip.Name, wanted = e.wanted, placed = e.placed, available = available(e) })
	end
	return { mode = mode, open = open, chips = list, button = button ~= nil and button.Visible }
end

-- test hook (Studio MCP runs code in its own VM): Players.LocalPlayer.ChipMenuTest:Invoke("open" | "close" | "state")
task.defer(function()
	local lp = Players.LocalPlayer
	if not lp or lp:FindFirstChild("ChipMenuTest") then
		return
	end
	local f = Instance.new("BindableFunction")
	f.Name = "ChipMenuTest"
	f.OnInvoke = function(what: string): string
		if what == "open" then
			ChipMenu.setOpen(true)
		elseif what == "close" then
			ChipMenu.setOpen(false)
		end
		return game:GetService("HttpService"):JSONEncode(ChipMenu.debug())
	end
	f.Parent = lp
end)

return ChipMenu
