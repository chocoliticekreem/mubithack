--!strict
-- GamepadNav [owner: G3]. Menus a gamepad can drive (docs/game/17-console-support.md). Rules: Lib/PadNav.
--   * Every menu registers once: HudLayout.modal() does it for its panels (back = its onDismiss); other
--     menus call GamepadNav.menu(panel, opts) themselves (results screen, big map).
--   * When a menu opens on a gamepad, GuiService.SelectedObject lands on its default button (opts.default,
--     a button with attr GamepadDefault = true, else the first non-CLOSE button top-left first). The panel
--     is a SelectionGroup, so the D-pad / left stick stay inside it. When it closes the cursor goes back
--     to where it was (usually nowhere, so A jumps again).
--   * B = back: the top menu's opts.back (close). Outside menus B only clears a HUD cursor.
--   * D-pad left (nothing selected, no menu) = focusHud(): the cursor jumps onto the HUD buttons (DISPATCH /
--     STORE / PASS / NEWS / HELP / GO NOW / ACCEPT ...); A presses, B leaves.
-- Keyboard, mouse and touch never see any of this: nothing here runs unless the last input is a gamepad.
-- The live loop (step / B / D-pad / right-stick scroll) is GamepadController's.
--
--   GamepadNav.isGamepad() -> boolean
--   GamepadNav.menu(panel, opts?)  opts = { back = fn?, default = fn() -> GuiObject?, companions = {gui names}? }
--   GamepadNav.top() -> panel?, GamepadNav.active() -> boolean (a menu is up or the cursor is on something)
--   GamepadNav.back() -> boolean, GamepadNav.focusHud() -> boolean, GamepadNav.step()
--   GamepadNav.scroll(y, dt)       right stick: scroll the top menu's list
--   GamepadNav.selectionImage() -> Frame   the chunky yellow cursor (PlayerGui.SelectionImageObject)
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")

local InputHints = require(script.Parent:WaitForChild("InputHints") :: ModuleScript) :: any
local PadNav = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("PadNav") :: ModuleScript) :: any

local GamepadNav = {}

-- HUD buttons D-pad left lands on first (by Name), else the top-left one
GamepadNav.HudPriority = { "Accept", "GoNow", "Go", "NextCallButton", "DispatchChip", "StoreChip" }
GamepadNav.ScrollSpeed = 900 -- px per second at full right-stick tilt

export type Opts = { back: (() -> ())?, default: (() -> GuiObject?)?, companions: { string }? }
type Menu = { panel: GuiObject, opts: Opts, visible: boolean, opened: number, prev: GuiObject? }

local menus: { [GuiObject]: Menu } = {}
local player = Players.LocalPlayer

function GamepadNav.isGamepad(): boolean
	return InputHints.mode() == "gamepad"
end

local function playerGui(): Instance?
	return player and player:FindFirstChild("PlayerGui")
end

-- on screen: every ancestor visible, inside an enabled ScreenGui under PlayerGui
local function shown(g: Instance): boolean
	if g:IsA("GuiObject") and not g.Visible then
		return false
	end
	local p = g.Parent
	while p do
		if p:IsA("GuiObject") then
			if not p.Visible then
				return false
			end
		elseif p:IsA("LayerCollector") then
			return p:IsA("ScreenGui") and p.Enabled and p.Parent ~= nil and p.Parent:IsA("PlayerGui")
		end
		p = p.Parent
	end
	return false
end
GamepadNav.shown = shown

local function screenOf(g: Instance): ScreenGui?
	local lc = g:FindFirstAncestorWhichIsA("ScreenGui")
	return if lc and lc:IsA("ScreenGui") then lc else nil
end

local function selectable(b: Instance?): boolean
	if not b or not b:IsA("GuiButton") then
		return false
	end
	local g = b :: GuiButton
	if not g.Selectable or g:GetAttribute("GamepadSkip") == true then
		return false
	end
	local s = g.AbsoluteSize
	return s.X > 4 and s.Y > 4 and shown(g)
end

local function inside(m: Menu, obj: Instance): boolean
	if obj:IsDescendantOf(m.panel) then
		return true
	end
	local pg = playerGui()
	for _, name in m.opts.companions or {} do
		local g = pg and pg:FindFirstChild(name)
		if g and obj:IsDescendantOf(g) then
			return true
		end
	end
	return false
end

local function buttonsIn(root: Instance): ({ GuiObject }, { any })
	local list, cands = {}, {}
	for _, d in root:GetDescendants() do
		if selectable(d) then
			local b = d :: GuiButton
			table.insert(list, b)
			local text = if b:IsA("TextButton") then (b :: TextButton).Text else nil
			table.insert(cands, {
				name = b.Name,
				text = text,
				x = b.AbsolutePosition.X,
				y = b.AbsolutePosition.Y,
				default = b:GetAttribute("GamepadDefault") == true,
			})
		end
	end
	return list, cands
end

local function defaultOf(m: Menu): GuiObject?
	local fn = m.opts.default
	if fn then
		local ok, d = pcall(fn)
		if ok and d and selectable(d) then
			return d
		end
	end
	local list, cands = buttonsIn(m.panel)
	local i = PadNav.pickDefault(cands)
	return if i then list[i] else nil
end

local function setSelected(obj: GuiObject?)
	if GuiService.SelectedObject ~= obj then
		pcall(function()
			GuiService.SelectedObject = obj
		end)
	end
end

-- a menu went away: the cursor goes back to where it was (a HUD chip), or nowhere so A jumps again.
-- Roblox itself moves a cursor whose button just hid to the nearest other button (the NEWS chip), so
-- anything but another open menu's button is overruled.
local function closed(panel: GuiObject, prev: GuiObject?)
	local sel = GuiService.SelectedObject
	for p2, m2 in menus do
		if p2 ~= panel and m2.visible and sel and inside(m2, sel) then
			return
		end
	end
	if sel ~= prev then
		setSelected(if prev and selectable(prev) then prev else nil)
	end
end

function GamepadNav.menu(panel: GuiObject, opts: Opts?)
	local o = opts or {} :: Opts
	local m = menus[panel]
	if m then
		for k, v in o :: any do
			(m.opts :: any)[k] = v
		end
		return
	end
	menus[panel] = { panel = panel, opts = o, visible = false, opened = 0 }
	-- the D-pad / left stick stay inside the menu (companion guis, like the lobby settings buttons beside
	-- HELP, have to be reachable, so those menus only group, they don't stop at the edge)
	panel.SelectionGroup = true
	if not o.companions then
		panel.SelectionBehaviorUp = Enum.SelectionBehavior.Stop
		panel.SelectionBehaviorDown = Enum.SelectionBehavior.Stop
		panel.SelectionBehaviorLeft = Enum.SelectionBehavior.Stop
		panel.SelectionBehaviorRight = Enum.SelectionBehavior.Stop
	end
	panel.Destroying:Connect(function()
		local mm = menus[panel]
		menus[panel] = nil
		if mm and mm.visible then
			closed(panel, mm.prev)
		end
	end)
end

local function topMenu(): Menu?
	local open: { Menu } = {}
	local states = {}
	for _, m in menus do
		if m.visible then
			table.insert(open, m)
			local sg = screenOf(m.panel)
			table.insert(states, { order = if sg then sg.DisplayOrder else 0, opened = m.opened })
		end
	end
	local i = PadNav.topMenu(states)
	return if i then open[i] else nil
end

function GamepadNav.top(): GuiObject?
	local m = topMenu()
	return if m then m.panel else nil
end

function GamepadNav.active(): boolean
	return GamepadNav.isGamepad() and (topMenu() ~= nil or GuiService.SelectedObject ~= nil)
end

-- once per frame (GamepadController): open / close bookkeeping, keep the cursor in the top menu
function GamepadNav.step()
	local pad = GamepadNav.isGamepad()
	local sel = GuiService.SelectedObject
	for panel, m in menus do
		local vis = panel.Parent ~= nil and shown(panel)
		if vis and not m.visible then
			m.visible = true
			m.opened = os.clock()
			m.prev = if sel and not inside(m, sel) then sel else nil
		elseif not vis and m.visible then
			m.visible = false
			local prev = m.prev
			m.prev = nil
			closed(panel, prev)
			sel = GuiService.SelectedObject
		end
	end
	if not pad then
		return
	end
	local top = topMenu()
	if top then
		if not (sel and inside(top, sel) and selectable(sel)) then
			local d = defaultOf(top)
			if d then
				setSelected(d)
			end
		end
	elseif sel and not shown(sel) then
		setSelected(nil) -- a cursor left on something that went away
	end
end

function GamepadNav.back(): boolean
	local top = topMenu()
	if top then
		local fn = top.opts.back
		if fn then
			task.spawn(fn)
			return true
		end
		return false
	end
	if GuiService.SelectedObject ~= nil then
		setSelected(nil)
		return true
	end
	return false
end

-- D-pad left: put the cursor on the HUD buttons (none selected and no menu up)
function GamepadNav.focusHud(): boolean
	local pg = playerGui()
	if not pg or topMenu() then
		return false
	end
	local cam = workspace.CurrentCamera
	local view = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local list, cands = {}, {}
	for _, sg in pg:GetChildren() do
		if not sg:IsA("ScreenGui") or not sg.Enabled then
			continue
		end
		local bl, bc = buttonsIn(sg)
		for i, b in bl do
			local s = b.AbsoluteSize
			-- skip invisible hit boxes and anything screen-sized (backdrops, the minimap's own hit area:
			-- its round M button is the way in)
			local bare = b.BackgroundTransparency >= 0.99 and (not b:IsA("TextButton") or (b :: TextButton).Text == "")
			if s.X > view.X * 0.6 or s.Y > view.Y * 0.6 or (bare and s.X * s.Y > 160 * 60) then
				continue
			end
			table.insert(list, b)
			table.insert(cands, bc[i])
		end
	end
	local i = PadNav.pickHud(cands, GamepadNav.HudPriority)
	if not i then
		return false
	end
	setSelected(list[i])
	return true
end

-- right stick in a menu: scroll its list (the one holding the cursor, else the biggest)
function GamepadNav.scroll(y: number, dt: number)
	local top = topMenu()
	if not top or math.abs(y) < 0.2 then
		return
	end
	local sel = GuiService.SelectedObject
	local pick: ScrollingFrame? = nil
	local area = 0
	for _, d in top.panel:GetDescendants() do
		if d:IsA("ScrollingFrame") and shown(d) then
			local sf = d :: ScrollingFrame
			if sf.AbsoluteCanvasSize.Y > sf.AbsoluteWindowSize.Y + 1 then
				if sel and sel:IsDescendantOf(sf) then
					pick = sf
					break
				end
				local a = sf.AbsoluteSize.X * sf.AbsoluteSize.Y
				if a > area then
					pick, area = sf, a
				end
			end
		end
	end
	if pick then
		local sf = pick :: ScrollingFrame
		local maxY = math.max(0, sf.AbsoluteCanvasSize.Y - sf.AbsoluteWindowSize.Y)
		local ny = math.clamp(sf.CanvasPosition.Y - y * GamepadNav.ScrollSpeed * dt, 0, maxY)
		sf.CanvasPosition = Vector2.new(sf.CanvasPosition.X, ny)
	end
end

function GamepadNav.selectionImage(): Frame
	local f = Instance.new("Frame")
	f.Name = "PadCursor"
	f.BackgroundTransparency = 1
	f.Size = UDim2.new(1, 12, 1, 12)
	f.Position = UDim2.fromOffset(-6, -6)
	local s = Instance.new("UIStroke")
	s.Thickness = 5
	s.Color = Color3.fromHex("#FFE15A") -- PromptConfig.HighlightColor: "this is what you'd use"
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = f
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 14)
	c.Parent = f
	return f
end

-- test hook: the registered menus and which is on top
function GamepadNav.debug(): { [string]: any }
	local open = {}
	for p, m in menus do
		if m.visible then
			table.insert(open, p:GetFullName())
		end
	end
	local top = topMenu()
	local sel = GuiService.SelectedObject
	return {
		mode = InputHints.mode(),
		open = open,
		top = if top then top.panel:GetFullName() else nil,
		selected = if sel then sel:GetFullName() else nil,
	}
end

return GamepadNav
