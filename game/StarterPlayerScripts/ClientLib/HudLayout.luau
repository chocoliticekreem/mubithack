--!strict
-- HudLayout [owner: G3]. The one place that decides where shared HUD widgets sit, so systems built in
-- different files stop printing over each other (game/tools/ui_audit.luau checks the result).
--
-- Screen zones (design units at 1280x720; every ScreenGui scales them with its UiKit ViewportScale):
--   top bar row  Roblox menu buttons | ProfileHud level panel + battle pass pip | (free) | minimap
--   top-centre   stack "TopCentre": mission timer -> objective / CALL! card -> alarm banner -> toasts.
--                Each one sits under the previous VISIBLE one.
--   top-left     stack "Left": objectives -> building integrity -> mission guide card
--   top-right    minimap (NavMinimap, in the top-bar row) -> its turn-hint slot -> squad strip
--   left edge    stack "Chips" (lobby buttons, one column, in order): [P] PASS, NEWS, INVITE, TROPHIES,
--                [H] HELP, ADMIN. Centred on the left edge, its bottom kept clear of a phone's thumbstick and the
--                gamepad's bottom-left D-pad legend; bottom-left: carry card
--   bottom       hotbar (centre), carry slot above it, truck hints, heat gauge (right)
--   centre       transient banners (heat warning, level-up / tier-up cards)
--   modal        PASS / STORE / HELP / LOCKER / mission picker / big map: HudLayout.modal() dims
--                everything under them and lifts their ScreenGui above the HUD while open.
--
-- API
--   HudLayout.stack(name, top, gap?)          top(scale, insetY) -> screen px of the stack's first slot
--   HudLayout.add(name, obj, order, height?)  the stack owns obj.Position.Y from now on (X is kept).
--                                             height?: () -> design units (default obj.Size.Y.Offset)
--   HudLayout.pin(obj, y)                     obj.Position.Y = screen px y(scale, insetY), converted to
--                                             obj's ScreenGui (inset or full-bleed) on every resize
--   HudLayout.modal(panel, opts?)             opts.onDismiss (backdrop click), opts.companions = {gui names}.
--                                             While open, a panel sized in offsets that doesn't fit the
--                                             screen (phones: UiKit's scale stops at 0.55) shrinks its
--                                             gui's ViewportScale until it does; back on close
--   HudLayout.modalOpen() -> boolean, HudLayout.ModalChanged (BindableEvent, fires (open: boolean))
--   HudLayout.celebrate(fn, kind?)            queue a centre card (level up / new gear / tier up); fn shows
--                                             it and returns its seconds (+ optional hide()). One at a
--                                             time, never over a modal or a HudLayout.setBusy(name, true)
--                                             screen (results). A tap / click anywhere calls hide() and
--                                             moves on; calm screens (ClientLib/Calm) cap it at 2.5 s.
--                                             ClientLib/PopupGate: dropped (not queued) until the first
--                                             call is done; each card's end restarts the modal gap
--   HudLayout.isBusy() -> boolean            any setBusy screen up (results / on a call): pop-ups wait
--   HudLayout.reserve(obj)                    a HUD widget that edge arrows must stay off
--   HudLayout.clear(x, y, radius, key?, prio?) -> (x, y)
--                                             pull a full-bleed screen point toward the centre until a
--                                             circle of `radius` px there misses every reserved widget
--                                             and every higher-priority marker's claim (HudLayout.Prio)
--   HudLayout.flush()                         place everything now (before UiKit.shake on a stacked widget)
--   HudLayout.scaleOf(gui), HudLayout.inset() helpers
-- Nothing here writes a property every frame: stacks and pins recompute only when something they
-- watch changes (Visible, Size, Enabled, viewport, top bar), so two systems never fight per frame.
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local HudLayout = {}

HudLayout.Gap = 8
HudLayout.ModalOrder = 50 -- DisplayOrder a modal's ScreenGui gets while open (above every HUD gui)
HudLayout.ModalChanged = Instance.new("BindableEvent")

-- the right column under the minimap (full-bleed design units): map top + size + hint slot
local function navCfg(): any
	local ok, cfg = pcall(function()
		local rs = game:GetService("ReplicatedStorage")
		return require(rs:WaitForChild("Config"):WaitForChild("NavigationConfig") :: ModuleScript)
	end)
	return if ok then cfg else {}
end
local NAV = navCfg()
HudLayout.MinimapTop = tonumber(NAV.MinimapTop) or 8
HudLayout.MinimapSize = tonumber(NAV.MinimapSize) or 190
HudLayout.HintHeight = 52
-- full-bleed design units: where the squad strip starts (under the minimap and its reserved hint slot)
HudLayout.RightColumnBelow = HudLayout.MinimapTop + HudLayout.MinimapSize + 8 + HudLayout.HintHeight + 8

function HudLayout.inset(): number
	return GuiService:GetGuiInset().Y
end

function HudLayout.scaleOf(gui: Instance?): number
	local s = gui and gui:FindFirstChild("ViewportScale")
	return if s and s:IsA("UIScale") then s.Scale else 1
end

local function guiOf(obj: Instance): ScreenGui?
	local g = obj:FindFirstAncestorOfClass("ScreenGui")
	return g
end

local function originY(gui: ScreenGui): number
	return if gui.IgnoreGuiInset then 0 else HudLayout.inset()
end

local function shown(obj: GuiObject): boolean
	local cur: Instance? = obj
	while cur do
		if cur:IsA("GuiObject") and not cur.Visible then
			return false
		end
		if cur:IsA("ScreenGui") then
			return cur.Enabled
		end
		cur = cur.Parent
	end
	return false
end

-- set obj.Position.Y so its top edge lands on screen px `screenY`
local function setTop(obj: GuiObject, screenY: number)
	local gui = guiOf(obj)
	if not gui then
		return
	end
	local s = HudLayout.scaleOf(gui)
	local y = math.floor((screenY - originY(gui)) / s + 0.5)
	local p = obj.Position
	local want = UDim2.new(p.X.Scale, p.X.Offset, 0, y)
	if p ~= want then
		obj.Position = want
	end
end

-- dirty-flag scheduler: one recompute per frame at most, only after a watched change
local dirty = false
local stacks: { [string]: any } = {}
local pins: { { obj: GuiObject, y: (number, number) -> number } } = {}

local function markDirty()
	dirty = true
end

local function recompute()
	local inset = HudLayout.inset()
	for _, st in stacks do
		local items = st.items
		table.sort(items, function(a, b)
			return a.order < b.order
		end)
		local s = 1
		local first = items[1]
		if first then
			s = HudLayout.scaleOf(guiOf(first.obj))
		end
		local cursor = st.top(s, inset)
		for _, it in items do
			local obj = it.obj
			if obj.Parent and shown(obj) then
				local gs = HudLayout.scaleOf(guiOf(obj))
				setTop(obj, cursor)
				local h = if it.height then it.height() else obj.Size.Y.Offset
				cursor += (h + st.gap) * gs
			end
		end
	end
	for i = #pins, 1, -1 do
		local p = pins[i]
		if not p.obj.Parent then
			table.remove(pins, i)
		else
			local gui = guiOf(p.obj)
			setTop(p.obj, p.y(HudLayout.scaleOf(gui), inset))
		end
	end
end

local started = false
local function start()
	if started then
		return
	end
	started = true
	local function hookCamera()
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				-- UiKit's ViewportScale updates on the same signal; recompute next frame
				markDirty()
			end)
		end
	end
	hookCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(hookCamera)
	GuiService:GetPropertyChangedSignal("TopbarInset"):Connect(markDirty)
	RunService.Heartbeat:Connect(function()
		if dirty then
			dirty = false
			local ok, err = pcall(recompute)
			if not ok then
				warn(`[HudLayout] {err}`)
			end
		end
	end)
end

local function watch(obj: GuiObject)
	obj:GetPropertyChangedSignal("Visible"):Connect(markDirty)
	obj:GetPropertyChangedSignal("Size"):Connect(markDirty)
	obj.AncestryChanged:Connect(markDirty)
	local gui = guiOf(obj)
	if gui then
		gui:GetPropertyChangedSignal("Enabled"):Connect(markDirty)
		local sc = gui:FindFirstChild("ViewportScale")
		if sc and sc:IsA("UIScale") then
			sc:GetPropertyChangedSignal("Scale"):Connect(markDirty)
		end
	end
end

function HudLayout.stack(name: string, top: (number, number) -> number, gap: number?)
	start()
	if not stacks[name] then
		stacks[name] = { top = top, gap = gap or HudLayout.Gap, items = {} }
	else
		stacks[name].top = top
	end
	markDirty()
end

function HudLayout.add(name: string, obj: GuiObject, order: number, height: (() -> number)?)
	start()
	local st = stacks[name]
	if not st then
		HudLayout.stack(name, function(s, inset)
			return inset + 10 * s
		end)
		st = stacks[name]
	end
	for _, it in st.items do
		if it.obj == obj then
			return
		end
	end
	table.insert(st.items, { obj = obj, order = order, height = height })
	watch(obj)
	obj.Destroying:Connect(function()
		for i, it in st.items do
			if it.obj == obj then
				table.remove(st.items, i)
				break
			end
		end
		markDirty()
	end)
	markDirty()
end

-- Place everything now (e.g. before UiKit.shake captures a widget's home position).
function HudLayout.flush()
	dirty = false
	local ok, err = pcall(recompute)
	if not ok then
		warn(`[HudLayout] {err}`)
	end
end

function HudLayout.pin(obj: GuiObject, y: (number, number) -> number)
	start()
	table.insert(pins, { obj = obj, y = y })
	watch(obj)
	markDirty()
end

-- built-in stacks (the controllers add their widgets by name)
HudLayout.stack("TopCentre", function(s, inset)
	return inset + 10 * s
end)
HudLayout.stack("Left", function(s, inset)
	return inset + 10 * s
end)
-- the left chip column: 6 chips x 40 + 5 gaps x 10 = 290 design units, centred on the screen's left edge
-- but never lower than 120 px above the bottom (touch thumbstick, D-pad legend) nor under the top bar
HudLayout.ChipColumn = 290
HudLayout.stack("Chips", function(s, inset)
	local cam = workspace.CurrentCamera
	local h = if cam then cam.ViewportSize.Y else 720
	local col = HudLayout.ChipColumn * s
	return math.max(inset + 60 * s, math.min(h * 0.5 - col * 0.5, h - 120 - col))
end, 10)

-- modals ---------------------------------------------------------------------------------------
local openModals: { [GuiObject]: boolean } = {}

function HudLayout.modalOpen(): boolean
	return next(openModals) ~= nil
end

export type ModalOpts = { onDismiss: (() -> ())?, companions: { string }?, dim: number? }

function HudLayout.modal(panel: GuiObject, opts: ModalOpts?)
	local o = opts or {} :: ModalOpts
	local gui = guiOf(panel)
	if not gui then
		return
	end
	local g = gui :: ScreenGui
	local baseOrder = g.DisplayOrder
	local companionBase: { [string]: number } = {}
	if panel.ZIndex < 20 then
		panel.ZIndex = 20
	end
	local dim = Instance.new("TextButton")
	dim.Name = "ModalDim"
	dim.Text = ""
	dim.AutoButtonColor = false
	dim.BorderSizePixel = 0
	dim.BackgroundColor3 = Color3.new(0, 0, 0)
	dim.BackgroundTransparency = o.dim or 0.45
	-- oversized so it also covers the top-bar row and any safe-area inset, whatever the gui's mode
	dim.Size = UDim2.fromScale(3, 3)
	dim.Position = UDim2.fromScale(-1, -1)
	dim.ZIndex = panel.ZIndex - 1
	dim.Visible = false
	dim.Selectable = false
	dim.Parent = panel.Parent
	dim.Activated:Connect(function()
		if o.onDismiss then
			o.onDismiss()
		end
	end)

	local function pg(): Instance?
		return Players.LocalPlayer:FindFirstChild("PlayerGui")
	end

	-- fit on small screens: the gui's ViewportScale (UiKit) shrinks while this is open so the whole panel
	-- (and its close button) is on screen; UiKit's own formula comes back on close
	local function baseScale(): number
		local cam = workspace.CurrentCamera
		local v = if cam then cam.ViewportSize else Vector2.new(1280, 720)
		local okK, kit = pcall(function()
			return require(script.Parent:WaitForChild("UiKit") :: ModuleScript) :: any
		end)
		local maxS = if okK and type(kit) == "table" and type(kit.MaxScale) == "number" then kit.MaxScale else 1.4
		return math.clamp(math.min(v.X / 1280, v.Y / 720), 0.55, maxS)
	end
	local fitted = false
	local function fit(open: boolean)
		local vs = g:FindFirstChild("ViewportScale")
		if not vs or not vs:IsA("UIScale") then
			return
		end
		local sz = panel.Size
		if open and sz.X.Scale == 0 and sz.Y.Scale == 0 and sz.X.Offset > 0 and sz.Y.Offset > 0 then
			local area = g.AbsoluteSize
			local want = math.min(vs.Scale, (area.X - 12) / sz.X.Offset, (area.Y - 12) / sz.Y.Offset)
			if want < vs.Scale - 1e-3 then
				fitted = true
				vs.Scale = want
			end
		elseif not open and fitted then
			fitted = false
			vs.Scale = baseScale()
		end
	end

	local function apply()
		local open = panel.Visible and panel.Parent ~= nil
		local was = openModals[panel] == true
		dim.Visible = open
		pcall(fit, open)
		if open then
			openModals[panel] = true
			if g.DisplayOrder < HudLayout.ModalOrder then
				baseOrder = g.DisplayOrder
				g.DisplayOrder = HudLayout.ModalOrder
			end
			local p = pg()
			for _, name in o.companions or {} do
				local c = p and p:FindFirstChild(name)
				if c and c:IsA("ScreenGui") then
					if companionBase[name] == nil then
						companionBase[name] = c.DisplayOrder
					end
					c.DisplayOrder = HudLayout.ModalOrder + 1
				end
			end
		else
			openModals[panel] = nil
			if g.DisplayOrder == HudLayout.ModalOrder then
				g.DisplayOrder = baseOrder
			end
			local p = pg()
			for name, order in companionBase do
				local c = p and p:FindFirstChild(name)
				if c and c:IsA("ScreenGui") then
					c.DisplayOrder = order
				end
			end
			table.clear(companionBase)
		end
		if was ~= open then
			HudLayout.ModalChanged:Fire(HudLayout.modalOpen())
		end
	end
	-- gamepad: the cursor lands in the panel when it opens and B is the backdrop click (ClientLib/GamepadNav)
	pcall(function()
		local GamepadNav = require(script.Parent:WaitForChild("GamepadNav") :: ModuleScript) :: any
		GamepadNav.menu(panel, { back = o.onDismiss, companions = o.companions })
	end)
	panel:GetPropertyChangedSignal("Visible"):Connect(apply)
	panel.Destroying:Connect(function()
		openModals[panel] = nil
		HudLayout.ModalChanged:Fire(HudLayout.modalOpen())
	end)
	apply()
end

-- centre celebrations --------------------------------------------------------------------------
-- LEVEL UP, NEW GEAR and TIER UP cards all land at the end of a call. They take turns in the centre
-- of the screen, and wait while a modal or the results screen (HudLayout.setBusy) is up.
local busy: { [string]: boolean } = {}
local queue: { { fn: () -> (number?, (() -> ())?), at: number } } = {}
local celebrating = false
-- XP / level-up events land a moment before the results screen; give it this long to claim the screen
local GRACE = 1.2

local function pump()
	if celebrating or #queue == 0 or HudLayout.modalOpen() or next(busy) ~= nil then
		return
	end
	local wait = queue[1].at + GRACE - os.clock()
	if wait > 0 then
		task.delay(wait, pump)
		return
	end
	celebrating = true
	local fn = (table.remove(queue, 1) :: any).fn :: () -> (number?, (() -> ())?)
	task.spawn(function()
		local ok, secs, hide = pcall(fn)
		if not ok then
			warn(`[HudLayout] celebration: {secs}`)
		end
		local t = if ok and type(secs) == "number" then secs else 3
		local calm = false
		pcall(function()
			calm = (require(script.Parent:WaitForChild("Calm") :: ModuleScript) :: any).on()
		end)
		if calm then
			t = math.min(t, 2.5)
		end
		-- a tap / click anywhere (after a short beat, so the tap that earned it doesn't eat it) dismisses it
		local done = false
		local shownAt = os.clock()
		local conn = UserInputService.InputBegan:Connect(function(input: InputObject)
			local ty = input.UserInputType
			if not done and os.clock() - shownAt > 0.4
				and (ty == Enum.UserInputType.Touch or ty == Enum.UserInputType.MouseButton1) then
				done = true
			end
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < t do
			task.wait(0.05)
		end
		conn:Disconnect()
		-- tapped away, or cut short on a calm screen: take the card down now (it may run its own longer timer)
		if (done or calm) and type(hide) == "function" then
			pcall(hide)
			task.wait(0.15)
		end
		celebrating = false
		local g = popupGate()
		if g then
			g.noteEnd()
		end
		pump()
	end)
end

-- fn shows the card and returns how many seconds it stays up (the next one waits that long) and, optionally,
-- a hide() that takes it down early (tap to dismiss)
local gate: any = nil
local function popupGate(): any
	if gate == nil then
		local ok, m = pcall(function()
			return require(script.Parent:WaitForChild("PopupGate") :: ModuleScript)
		end)
		gate = if ok then m else false
	end
	return gate
end

function HudLayout.celebrate(fn: () -> (number?, (() -> ())?), kind: string?)
	-- the first call comes first: LEVEL 2! / NEW GEAR! landed on the first-call card in the same second
	local g = popupGate()
	if g and g.decide(kind or "celebrate") == "drop" then
		return
	end
	table.insert(queue, { fn = fn, at = os.clock() })
	pump()
end

function HudLayout.setBusy(name: string, on: boolean)
	busy[name] = if on then true else nil
	pump()
end

-- true while a HudLayout.setBusy screen is up (results, on a call): a panel that pops up by itself waits
function HudLayout.isBusy(): boolean
	return next(busy) ~= nil
end

HudLayout.ModalChanged.Event:Connect(function()
	pump()
end)

-- edge arrows ----------------------------------------------------------------------------------
local reserved: { GuiObject } = {}

function HudLayout.reserve(obj: GuiObject)
	if not table.find(reserved, obj) then
		table.insert(reserved, obj)
		obj.Destroying:Connect(function()
			local i = table.find(reserved, obj)
			if i then
				table.remove(reserved, i)
			end
		end)
	end
end

local function hits(x: number, y: number, r: number, inset: number): boolean
	for _, obj in reserved do
		if obj.Parent and shown(obj) then
			local p, sz = obj.AbsolutePosition, obj.AbsoluteSize
			-- AbsolutePosition is measured from below the top bar for every ScreenGui
			local x0, y0 = p.X - r, p.Y + inset - r
			local x1, y1 = p.X + sz.X + r, p.Y + inset + sz.Y + r
			if x > x0 and x < x1 and y > y0 and y < y1 then
				return true
			end
		end
	end
	return false
end

-- Floating markers (edge arrows, world markers) also claim their spot for a frame, so two arrows that
-- point the same way don't sit on each other: a claim blocks only callers with a LOWER priority (a
-- bigger `prio` number), so the more important one never moves for the other and nothing oscillates.
-- Claims expire after a few frames (a hidden marker stops claiming).
HudLayout.Prio = { Nav = 1, Fire = 2, Rescue = 3, Truck = 4, Guide = 5, Onboarding = 6 }
local frameNo = 0
local claims: { [string]: { x: number, y: number, r: number, prio: number, frame: number } } = {}
RunService:BindToRenderStep("HudLayoutFrame", Enum.RenderPriority.First.Value, function()
	frameNo += 1
end)

local function blocked(x: number, y: number, r: number, inset: number, key: string?, prio: number): boolean
	if hits(x, y, r, inset) then
		return true
	end
	for k, c in claims do
		if k ~= key and c.prio < prio and frameNo - c.frame <= 2 then
			local d = math.max(math.abs(x - c.x), math.abs(y - c.y))
			if d < r + c.r then
				return true
			end
		end
	end
	return false
end

-- x, y: full-bleed screen px (what IgnoreGuiInset guis use). Slides toward the screen centre until the
-- circle misses every reserved HUD widget (and every higher-priority marker when `key` is given).
function HudLayout.clear(x: number, y: number, radius: number, key: string?, prio: number?): (number, number)
	local cam = workspace.CurrentCamera
	if not cam then
		return x, y
	end
	local inset = HudLayout.inset()
	local p = prio or 99
	local rx, ry = x, y
	if blocked(x, y, radius, inset, key, p) then
		local vp = cam.ViewportSize
		local cx, cy = vp.X / 2, vp.Y / 2
		local dx, dy = cx - x, cy - y
		local len = math.sqrt(dx * dx + dy * dy)
		local found = false
		if len >= 1 then
			local step = 8 / len
			local t = 0
			while t < 1 do
				t += step
				local nx, ny = x + dx * t, y + dy * t
				if not blocked(nx, ny, radius, inset, key, p) then
					rx, ry = nx, ny
					found = true
					break
				end
			end
		end
		if not found then
			-- the way in is blocked too (a card in the middle): the nearest free spot in rings around it
			local m = radius + 4
			for ring = 1, 24 do
				local d = ring * 10
				for i = 0, 15 do
					local a = i * math.pi / 8
					local nx, ny = x + math.cos(a) * d, y + math.sin(a) * d
					if nx > m and nx < vp.X - m and ny > inset + m and ny < vp.Y - m
						and not blocked(nx, ny, radius, inset, key, p) then
						rx, ry = nx, ny
						found = true
						break
					end
				end
				if found then
					break
				end
			end
		end
	end
	if key then
		claims[key] = { x = rx, y = ry, r = radius, prio = p, frame = frameNo }
	end
	return rx, ry
end

return HudLayout
