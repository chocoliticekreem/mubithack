--!nonstrict
-- CosmeticsClient (Forge kit, client): the costume panel for Cosmetics (server). Opens from changing-room
-- prompts, a HUD button or CosmeticsClient.open(id); buy / wear / take off go through the server's
-- remote, which checks everything. House UI style. Do not rewrite; require it.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local CosmeticsClient = {}

local T = {
	Ink = Color3.fromRGB(28, 22, 38), Cream = Color3.fromRGB(255, 248, 232), Primary = Color3.fromRGB(255, 196, 41),
	Good = Color3.fromRGB(88, 214, 92), Bad = Color3.fromRGB(240, 68, 64), Info = Color3.fromRGB(64, 170, 255),
	Gem = Color3.fromRGB(190, 92, 255), White = Color3.fromRGB(255, 255, 255),
	Header = Enum.Font.LuckiestGuy, Body = Enum.Font.FredokaOne,
}
local SLOT_LABEL = { head = "HAT", back = "CAPE", trail = "TRAIL", body = "COLOUR" }
local WIN, CELL, GAP = Vector2.new(820, 520), Vector2.new(176, 196), 14
local COLS = math.max(1, math.floor((WIN.X - 36 + GAP) / (CELL.X + GAP)))

local player = Players.LocalPlayer
local started, busy, isOpen = false, false, false
local state = nil
local cards, byId = {}, {}
local request: RemoteFunction? = nil
local gui, dim, win, grid, balanceLabel, toastLabel

-- ------------------------------------------------------------------ style helpers (forge/ui_library Theme)

local function corner(g: GuiObject, r: number?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 12)
	c.Parent = g
end

local function stroke(g: GuiObject, px: number, color: Color3?, border: boolean?): UIStroke
	local s = Instance.new("UIStroke")
	s.Thickness, s.Color = px, color or T.Ink
	s.ApplyStrokeMode = if border then Enum.ApplyStrokeMode.Border else Enum.ApplyStrokeMode.Contextual
	s.Parent = g
	return s
end

local function gradient(g: GuiObject, base: Color3)
	local gr = g:FindFirstChildOfClass("UIGradient") or Instance.new("UIGradient")
	gr.Rotation = 90
	gr.Color = ColorSequence.new(base:Lerp(Color3.new(1, 1, 1), 0.35), base:Lerp(Color3.new(), 0.12))
	gr.Parent = g
end

local function tween(inst: Instance, t: number, props: { [string]: any }, style: Enum.EasingStyle?): Tween
	local tw = TweenService:Create(inst, TweenInfo.new(t, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	tw:Play()
	return tw
end

local function juice(g: GuiObject): UIScale
	local s = g:FindFirstChild("Juice") or Instance.new("UIScale")
	s.Name, s.Parent = "Juice", g
	return s :: UIScale
end

local function pop(g: GuiObject, t: number?)
	local s = juice(g)
	s.Scale = 0
	tween(s, t or 0.3, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function punch(g: GuiObject, amount: number?)
	local s = juice(g)
	s.Scale = 1 + (amount or 0.15)
	tween(s, 0.25, { Scale = 1 }, Enum.EasingStyle.Back)
end

local function text(parent: Instance, str: string, font: Enum.Font, color: Color3, size: UDim2, pos: UDim2): TextLabel
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency, t.Text, t.Font, t.TextColor3, t.TextScaled = 1, str, font, color, true
	t.Size, t.Position, t.AnchorPoint, t.ZIndex = size, pos, Vector2.new(0.5, 0.5), 13
	stroke(t, 2.5)
	t.Parent = parent
	return t
end

local function button(parent: Instance, str: string, size: UDim2, pos: UDim2, color: Color3, onClick: () -> (),
	radius: number?): TextButton
	local sh = Instance.new("Frame") -- hard drop shadow
	sh.AnchorPoint, sh.Size, sh.Position = Vector2.new(0.5, 0.5), size, pos + UDim2.fromOffset(0, 5)
	sh.BackgroundColor3, sh.BackgroundTransparency, sh.BorderSizePixel, sh.ZIndex = T.Ink, 0.4, 0, 13
	corner(sh, radius or 12)
	sh.Parent = parent
	local b = Instance.new("TextButton")
	b.Text, b.Size, b.Position, b.AnchorPoint = str, size, pos, Vector2.new(0.5, 0.5)
	b.BackgroundColor3, b.AutoButtonColor, b.BorderSizePixel = color, false, 0
	b.Font, b.TextScaled, b.TextColor3, b.ZIndex = T.Header, true, T.Cream, 14
	corner(b, radius or 12)
	gradient(b, color)
	stroke(b, 3, nil, true)
	stroke(b, 2.5)
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0.18, 0), UDim.new(0.18, 0)
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.Parent = b
	local s = Instance.new("UIScale")
	s.Parent = b
	b.MouseEnter:Connect(function() tween(s, 0.1, { Scale = 1.06 }) end)
	b.MouseLeave:Connect(function() tween(s, 0.1, { Scale = 1 }) end)
	b.MouseButton1Down:Connect(function() tween(s, 0.06, { Scale = 0.9 }) end)
	b.MouseButton1Up:Connect(function() tween(s, 0.2, { Scale = 1 }, Enum.EasingStyle.Back) end)
	b.Activated:Connect(onClick)
	b.Parent = parent
	return b
end

local function setColor(b: GuiObject, color: Color3)
	b.BackgroundColor3 = color
	gradient(b, color)
end

local function sound(name: string)
	local ga = ReplicatedStorage:FindFirstChild("GameAssets")
	if ga and ga:IsA("ModuleScript") then
		pcall(function()
			require(ga).play(name)
		end)
	end
end

local function toast(str: string, color: Color3?)
	if not toastLabel then
		return
	end
	toastLabel.Text = str
	toastLabel.BackgroundColor3 = color or T.Good
	gradient(toastLabel, color or T.Good)
	toastLabel.Visible = true
	pop(toastLabel, 0.25)
	local mine = os.clock()
	toastLabel:SetAttribute("At", mine)
	task.delay(1.8, function()
		if toastLabel:GetAttribute("At") == mine then
			toastLabel.Visible = false
		end
	end)
end

-- ------------------------------------------------------------------ state -> cards

local function owned(id: string): boolean
	return state ~= nil and table.find(state.owned, id) ~= nil
end

local function wearing(def): boolean
	return state ~= nil and state.equipped[def.slot] == def.id
end

local function refresh()
	if not state then
		return
	end
	balanceLabel.Text = "💰 " .. tostring(state.balance) .. " " .. tostring(state.currency)
	for id, c in cards do
		local def = byId[id]
		local on, have = wearing(def), owned(id)
		c.badge.Visible = on
		c.ring.Color = if on then T.Good else T.Ink
		c.ring.Thickness = if on then 5 else 3
		if on then
			c.button.Text = "TAKE OFF"
			setColor(c.button, T.Info)
		elseif have then
			c.button.Text = "WEAR"
			setColor(c.button, T.Primary)
		elseif def.reward then
			c.button.Text = "🏆 REWARD"
			setColor(c.button, T.Gem)
		elseif (state.balance or 0) >= def.price then
			c.button.Text = "BUY " .. def.price
			setColor(c.button, T.Good)
		else
			c.button.Text = "NEED " .. def.price
			setColor(c.button, T.Bad)
		end
	end
end

local function act(action: string, id: string)
	if busy or not request then
		return nil
	end
	busy = true
	local ok, res = pcall(request.InvokeServer, request, action, id)
	busy = false
	if not ok or type(res) ~= "table" then
		toast("Try again", T.Bad)
		return nil
	end
	if res.state then
		CosmeticsClient._apply(res.state)
	end
	local def = byId[id]
	local name = if def then def.name else tostring(id)
	if res.ok then
		toast(if action == "unequip" then "Took off " .. name elseif action == "buy" then "Bought " .. name .. "!"
			else "Wearing " .. name .. "!")
		sound(if action == "buy" then "Buy" else "Pop")
		if cards[id] then
			punch(cards[id].frame, 0.12)
		end
	else
		toast(res.err or "Can't do that", T.Bad)
		sound("Error")
	end
	return res
end

local function onCard(id: string)
	local def = byId[id]
	if wearing(def) then
		act("unequip", id)
	elseif owned(id) then
		act("equip", id)
	elseif def.reward then
		toast("Earn it to unlock", T.Gem)
	else
		act("buy", id)
	end
end

local function buildCards()
	for _, c in cards do
		c.frame:Destroy()
	end
	cards, byId = {}, {}
	for i, def in state.costumes do
		byId[def.id] = def
		local f = Instance.new("Frame")
		f.Name, f.LayoutOrder, f.BackgroundColor3, f.ZIndex = def.id, i, T.White, 12
		corner(f, 14)
		local ring = stroke(f, 3, nil, true)
		f:SetAttribute("Costume", def.id)
		local disc = Instance.new("Frame")
		disc.Size, disc.Position, disc.AnchorPoint = UDim2.fromOffset(84, 84), UDim2.new(0.5, 0, 0, 52), Vector2.new(0.5, 0.5)
		disc.BackgroundColor3, disc.ZIndex = def.color or T.Info, 12
		corner(disc, 42)
		gradient(disc, def.color or T.Info)
		stroke(disc, 3, nil, true)
		disc.Parent = f
		local icon = text(disc, def.icon or "?", T.Body, T.White, UDim2.fromScale(0.8, 0.8), UDim2.fromScale(0.5, 0.5))
		icon:FindFirstChildOfClass("UIStroke").Enabled = false
		local tag = text(f, SLOT_LABEL[def.slot] or def.slot, T.Body, T.Cream, UDim2.fromOffset(60, 20), UDim2.fromOffset(36, 16))
		tag.BackgroundTransparency, tag.BackgroundColor3 = 0, T.Ink
		corner(tag, 8)
		text(f, def.name, T.Body, T.White, UDim2.new(1, -12, 0, 26), UDim2.new(0.5, 0, 0, 112))
		local badge = text(f, "✓", T.Header, T.White, UDim2.fromOffset(30, 30), UDim2.new(1, -14, 0, 14))
		badge.BackgroundTransparency, badge.BackgroundColor3 = 0, T.Good
		corner(badge, 15)
		local b = button(f, "", UDim2.new(1, -20, 0, 42), UDim2.new(0.5, 0, 1, -30), T.Primary, function()
			onCard(def.id)
		end)
		b.Name = "Action"
		f.Parent = grid
		cards[def.id] = { frame = f, button = b, badge = badge, ring = ring }
	end
end

function CosmeticsClient._apply(s)
	if type(s) ~= "table" or s.loading then
		return
	end
	local rebuild = state == nil or #state.costumes ~= #s.costumes
	state = s
	if rebuild then
		buildCards()
	end
	refresh()
end

-- ------------------------------------------------------------------ panel

local function setOpen(want: boolean)
	if want == isOpen or not dim then
		return
	end
	isOpen = want
	if want then
		dim.Visible = true
		tween(dim, 0.2, { BackgroundTransparency = 0.45 })
		pop(win, 0.35)
		sound("Whoosh")
	else
		tween(dim, 0.15, { BackgroundTransparency = 1 })
		tween(juice(win), 0.15, { Scale = 0 }).Completed:Wait()
		if not isOpen then
			dim.Visible = false
		end
	end
end

local function build(opts)
	gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.DisplayOrder = "Cosmetics", false, 20
	gui.ZIndexBehavior, gui.ScreenInsets = Enum.ZIndexBehavior.Sibling, Enum.ScreenInsets.CoreUISafeInsets
	local scale = Instance.new("UIScale")
	local cam = workspace.CurrentCamera
	local function fit()
		local v = cam.ViewportSize
		scale.Scale = math.clamp(math.min(v.X / 1280, v.Y / 720), 0.6, 1.4)
	end
	fit()
	cam:GetPropertyChangedSignal("ViewportSize"):Connect(fit)
	scale.Parent = gui

	dim = Instance.new("Frame")
	dim.Name, dim.Size, dim.BackgroundColor3, dim.BackgroundTransparency = "Dim", UDim2.fromScale(1, 1), T.Ink, 1
	dim.Visible, dim.ZIndex = false, 10
	dim.Parent = gui
	win = Instance.new("Frame")
	win.Name, win.Size, win.AnchorPoint, win.Position = "Window", UDim2.fromOffset(WIN.X, WIN.Y), Vector2.new(0.5, 0.5),
		UDim2.fromScale(0.5, 0.52)
	win.BackgroundColor3, win.ZIndex = T.Cream, 11
	corner(win, 18)
	stroke(win, 4, nil, true)
	win.Parent = dim
	local tab = text(win, opts.title or "COSTUMES", T.Header, T.Cream, UDim2.new(0.5, 0, 0, 54), UDim2.fromScale(0.5, 0))
	tab.BackgroundTransparency, tab.BackgroundColor3 = 0, T.Info
	corner(tab, 14)
	gradient(tab, T.Info)
	stroke(tab, 3, nil, true)
	balanceLabel = text(win, "💰 ...", T.Header, T.Primary, UDim2.fromOffset(240, 34), UDim2.fromOffset(150, 52))
	balanceLabel.TextXAlignment = Enum.TextXAlignment.Left
	button(win, "X", UDim2.fromOffset(50, 50), UDim2.new(1, -8, 0, 8), T.Bad, function()
		setOpen(false)
	end, 25)
	grid = Instance.new("ScrollingFrame")
	grid.Name, grid.Size, grid.Position = "Grid", UDim2.new(1, -36, 1, -96), UDim2.fromOffset(18, 80)
	grid.BackgroundTransparency, grid.BorderSizePixel, grid.ZIndex = 1, 0, 12
	grid.ScrollBarThickness, grid.ScrollBarImageColor3 = 8, T.Ink
	grid.AutomaticCanvasSize, grid.CanvasSize = Enum.AutomaticSize.Y, UDim2.new()
	local layout = Instance.new("UIGridLayout")
	layout.CellSize, layout.CellPadding = UDim2.fromOffset(CELL.X, CELL.Y), UDim2.fromOffset(GAP, GAP)
	layout.SortOrder, layout.HorizontalAlignment = Enum.SortOrder.LayoutOrder, Enum.HorizontalAlignment.Center
	layout.Parent = grid
	local pad = Instance.new("UIPadding")
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 8), UDim.new(0, 8)
	pad.Parent = grid
	grid.Parent = win

	toastLabel = text(gui, "", T.Header, T.Cream, UDim2.fromOffset(420, 52), UDim2.new(0.5, 0, 1, -130))
	toastLabel.BackgroundTransparency, toastLabel.Visible, toastLabel.ZIndex = 0, false, 30
	corner(toastLabel, 14)
	stroke(toastLabel, 3, nil, true)

	if opts.button ~= false then
		local hud = button(gui, "👕 COSTUMES", UDim2.fromOffset(170, 54), UDim2.new(0, 100, 0.5, 40), T.Info, function()
			CosmeticsClient.toggle()
		end)
		hud.Name = "CostumesButton"
	end
	gui.Parent = player:WaitForChild("PlayerGui")
end

-- opts: button (HUD "COSTUMES" button, true), title ("COSTUMES").
function CosmeticsClient.start(opts: { [string]: any }?)
	assert(RunService:IsClient(), "CosmeticsClient.start runs on the client (a LocalScript)")
	if started then
		return CosmeticsClient
	end
	started = true
	build(opts or {})
	task.spawn(function()
		local folder = ReplicatedStorage:WaitForChild("CosmeticsRemotes", 30)
		if not folder then
			warn("[CosmeticsClient] no ReplicatedStorage.CosmeticsRemotes: call Cosmetics.start() on the server")
			return
		end
		request = folder:WaitForChild("Request") :: RemoteFunction
		folder:WaitForChild("State").OnClientEvent:Connect(CosmeticsClient._apply)
		folder:WaitForChild("Open").OnClientEvent:Connect(function(id)
			CosmeticsClient.open(id)
		end)
		for _ = 1, 15 do
			local ok, res = pcall(request.InvokeServer, request, "state")
			if ok and type(res) == "table" and res.state and not res.state.loading then
				CosmeticsClient._apply(res.state)
				break
			end
			task.wait(1)
		end
		local ls = player:WaitForChild("leaderstats", 10)
		local stat = state and ls and ls:FindFirstChild(state.currency)
		if stat and stat:IsA("ValueBase") then
			stat.Changed:Connect(function(v)
				if state and type(v) == "number" then
					state.balance = v
					refresh()
				end
			end)
		end
	end)
	return CosmeticsClient
end

-- Open the panel; with an id, scroll to that costume's card and bounce it.
function CosmeticsClient.open(id: string?)
	setOpen(true)
	local c = id and cards[id]
	if c then -- the grid's rows are fixed size, so the card's row gives its scroll offset
		local row = math.floor((c.frame.LayoutOrder - 1) / COLS)
		grid.CanvasPosition = Vector2.new(0, row * (CELL.Y + GAP))
		punch(c.frame, 0.2)
	end
end

function CosmeticsClient.close()
	setOpen(false)
end

function CosmeticsClient.toggle()
	if isOpen then
		setOpen(false)
	else
		setOpen(true)
	end
end

function CosmeticsClient.isOpen(): boolean
	return isOpen
end

-- action: "buy" | "equip" | "unequip"; returns the server's {ok, err, state}.
function CosmeticsClient.request(action: string, id: string)
	return act(action, id)
end

function CosmeticsClient.state()
	return state
end

return CosmeticsClient
