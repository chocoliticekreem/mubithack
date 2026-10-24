--!strict
-- AdminController [owner: Admin]. Client side of AdminService (our own Kohl's-style admin):
--   * staff console: the ";" key (AdminConfig.ConsoleKey) or the ADMIN chip opens a centre-top modal with a
--     command box, autocomplete (Tab / click a suggestion) and the server's replies. :cmds lists the
--     commands for your rank. Attribute Menu = true, so MenuMouseController frees the mouse.
--   * ADMIN chip in the left chip column under STORE (touch friendly), staff only.
--   * :m banner and :h hint for everyone (Admin/Announce, text already filtered by the server).
--   * fly / noclip for the local character while Player attrs AdminFly / AdminNoclip are true.
-- Staff = Player attr AdminRank >= 1, written by the server. It only decides what UI shows: the server
-- re-checks the rank of every command, so a client faking the attribute gets "You can't use admin commands."
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("AdminConfig") :: ModuleScript) :: any
local MonetizationConfig = require(ConfigFolder:WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local MissionCatalog = require(ConfigFolder:WaitForChild("MissionCatalog") :: ModuleScript) :: any
local EventConfig = require(ConfigFolder:WaitForChild("EventConfig") :: ModuleScript) :: any
local AtmosphereConfig = require(ConfigFolder:WaitForChild("AtmosphereConfig") :: ModuleScript) :: any
local Lib = ReplicatedStorage:WaitForChild("Lib")
local Rules = require(Lib:WaitForChild("Admin"):WaitForChild("AdminRules") :: ModuleScript)
local Commands = require(Lib:WaitForChild("Admin"):WaitForChild("AdminCommands") :: ModuleScript)
local ItemDefs = require(Lib:WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)

local AdminController = {}
AdminController.Priority = 130

local player = Players.LocalPlayer
local A = Cfg.Attr

local MAX_LINES = 60
local MAX_SUGGEST = 6
local CONSOLE_W = 660

type Ui = {
	gui: ScreenGui,
	chip: TextButton,
	panel: Frame,
	box: TextBox,
	suggest: Frame,
	output: ScrollingFrame,
	banner: Frame,
	bannerFrom: TextLabel,
	bannerText: TextLabel,
	hint: Frame,
	hintText: TextLabel,
}

local ui: Ui? = nil
local runRemote: RemoteEvent? = nil
local suggestions: { string } = {}
local lineCount = 0
local bannerSeq = 0
local hintSeq = 0

------------------------------------------------------------------------------------------- lists

local function sortedKeys(t: any): { string }
	local out: { string } = {}
	if type(t) == "table" then
		for k in t do
			if type(k) == "string" and k ~= "Set" then
				table.insert(out, k)
			end
		end
	end
	table.sort(out)
	return out
end

local listCache: { [string]: { string } }? = nil
local function lists(): { [string]: { string } }
	if listCache then
		return listCache
	end
	local missions: { string } = {}
	for _, m in MissionCatalog do
		if type(m) == "table" and type(m.id) == "string" and m.enabled == true then
			table.insert(missions, m.id)
		end
	end
	table.sort(missions)
	listCache = {
		pass = sortedKeys(MonetizationConfig.GamePasses),
		item = sortedKeys(ItemDefs.Items),
		mission = missions,
		event = sortedKeys(EventConfig.Weights),
		preset = sortedKeys(AtmosphereConfig.Presets),
		rank = Commands.Lists.rank,
	}
	return listCache :: any
end

local function rank(): number
	return tonumber(player:GetAttribute(A.Rank)) or 0
end

local function playerNames(): { string }
	local out: { string } = {}
	for _, p in Players:GetPlayers() do
		table.insert(out, p.Name)
	end
	table.sort(out)
	return out
end

------------------------------------------------------------------------------------------ output

local function addLine(text: string, color: Color3?)
	local u = ui
	if not u then
		return
	end
	lineCount += 1
	local l = UiKit.label(u.output, `L{string.format("%05d", lineCount)}`, text, UDim2.new(1, -12, 0, 0), UDim2.new(), {
		font = UiKit.Body,
		textSize = 16,
		color = color or Palette.UiCream,
		align = Enum.TextXAlignment.Left,
	})
	l.AutomaticSize = Enum.AutomaticSize.Y
	l.LayoutOrder = lineCount
	l.RichText = false
	local kids = {}
	for _, c in u.output:GetChildren() do
		if c:IsA("TextLabel") then
			table.insert(kids, c)
		end
	end
	if #kids > MAX_LINES then
		table.sort(kids, function(a, b)
			return (a :: TextLabel).LayoutOrder < (b :: TextLabel).LayoutOrder
		end)
		for i = 1, #kids - MAX_LINES do
			kids[i]:Destroy()
		end
	end
	task.defer(function()
		u.output.CanvasPosition = Vector2.new(0, math.max(0, u.output.AbsoluteCanvasSize.Y - u.output.AbsoluteSize.Y))
	end)
end

local function showHelp()
	addLine(`You are {Rules.rankName(rank())}. Targets: me, all, others, random, @lobby, @squad, partial names, a,b`, Palette.UiWarn)
	for _, line in Rules.helpLines(Commands.Commands :: any, rank()) do
		addLine(line, if string.sub(line, 1, 2) == "==" then Palette.UiShock else Palette.UiCream)
	end
	addLine("Gifted passes are an in-game entitlement only: they don't grant the real Roblox game pass.", Palette.UiWarn)
end

---------------------------------------------------------------------------------------- suggests

local function renderSuggest()
	local u = ui
	if not u then
		return
	end
	for _, c in u.suggest:GetChildren() do
		if c:IsA("TextButton") then
			c:Destroy()
		end
	end
	u.suggest.Visible = #suggestions > 0
	for i, s in suggestions do
		if i > MAX_SUGGEST then
			break
		end
		local b = Instance.new("TextButton")
		b.Name = `S{i}`
		b.LayoutOrder = i
		b.Size = UDim2.new(1, 0, 0, 26)
		b.BackgroundColor3 = if i == 1 then Palette.UiWarn else Palette.UiCream
		b.AutoButtonColor = true
		b.Font = UiKit.Body
		b.TextSize = 17
		b.TextColor3 = Palette.UiInk
		b.TextXAlignment = Enum.TextXAlignment.Left
		b.Text = "  " .. s .. (if i == 1 then "   [Tab]" else "")
		b.Parent = u.suggest
		UiKit.corner(b, 6)
		b.Activated:Connect(function()
			u.box.Text = s
			u.box:CaptureFocus()
			u.box.CursorPosition = #s + 1
		end)
	end
end

local function updateSuggest()
	local u = ui
	if not u then
		return
	end
	local t = u.box.Text
	suggestions = if t == "" then {} else Rules.complete(t, Commands.Commands :: any, rank(), playerNames(), lists())
	-- don't suggest exactly what's typed
	if #suggestions == 1 and suggestions[1] == t then
		suggestions = {}
	end
	renderSuggest()
end

------------------------------------------------------------------------------------------ console

local function setOpen(open: boolean)
	local u = ui
	if not u then
		return
	end
	if open and rank() < 1 then
		return
	end
	if open == u.panel.Visible then
		if open then
			u.box:CaptureFocus()
		end
		return
	end
	u.panel.Visible = open
	if open then
		UiKit.pop(u.panel, 0.2)
		task.defer(function()
			u.box:CaptureFocus()
			u.box.Text = ""
		end)
	else
		u.box:ReleaseFocus()
		suggestions = {}
		renderSuggest()
	end
end

local function submit(text: string)
	local t = string.match(text, "^%s*(.-)%s*$") or ""
	if t == "" then
		return
	end
	addLine("> " .. t, Palette.UiWater)
	local r = runRemote
	if r then
		r:FireServer(t)
	end
end

------------------------------------------------------------------------------------------- build

local function chipButton(g: ScreenGui): TextButton
	local b = Instance.new("TextButton")
	b.Name = "AdminChip"
	b.Position = UDim2.new(0, 13, 0.53, 48) -- left chip column, under STORE (StoreController: 0.53, 40 tall)
	b.Size = UDim2.fromOffset(118, 40)
	b.BackgroundColor3 = Palette.UiPanelDark
	b.Font = UiKit.Header
	b.TextSize = 20
	b.TextColor3 = Palette.UiWarn
	b.Text = if UserInputService.KeyboardEnabled then "[;] ADMIN" else "ADMIN"
	b.AutoButtonColor = true
	b.Visible = false
	b.Parent = g
	UiKit.corner(b, 10)
	UiKit.stroke(b, 3, Palette.UiInk)
	local ts = Instance.new("UIStroke")
	ts.Thickness = 2
	ts.Color = Palette.UiInk
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = b
	return b
end

local function build()
	local g = UiKit.screen("AdminGui", 45)

	local chip = chipButton(g)

	-- console: centre-top modal
	local panel = UiKit.panel(g, "AdminConsole", UDim2.fromOffset(CONSOLE_W, 380), UDim2.new(0.5, 0, 0, 8), Vector2.new(0.5, 0))
	panel.BackgroundColor3 = Palette.UiPanelDark
	panel.Visible = false
	panel.ZIndex = 5
	panel:SetAttribute("Menu", true)

	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 44)
	head.BackgroundColor3 = Palette.UiRed
	head.BorderSizePixel = 0
	head.Parent = panel
	UiKit.corner(head, 12)
	local flat = Instance.new("Frame")
	flat.Size = UDim2.new(1, 0, 0, 12)
	flat.Position = UDim2.new(0, 0, 1, -12)
	flat.BackgroundColor3 = Palette.UiRed
	flat.BorderSizePixel = 0
	flat.Parent = head
	local title = UiKit.label(head, "Title", "STATION 67 ADMIN", UDim2.new(1, -170, 1, 0), UDim2.fromOffset(16, 0), {
		font = UiKit.Header,
		textSize = 26,
		color = Palette.UiCream,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	title.Name = "Title"
	local rankTag = UiKit.label(head, "Rank", "", UDim2.fromOffset(100, 44), UDim2.new(1, -160, 0, 0), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiWarn,
		stroke = true,
		align = Enum.TextXAlignment.Right,
	})
	local function paintRank()
		rankTag.Text = string.upper(Rules.rankName(rank()))
	end
	paintRank()
	player:GetAttributeChangedSignal(A.Rank):Connect(paintRank)
	local close = UiKit.button(head, "Close", "X", UDim2.fromOffset(36, 36), UDim2.new(1, -26, 0.5, 0), Palette.UiPanelDark)
	close.TextSize = 22

	local box = Instance.new("TextBox")
	box.Name = "Input"
	box.Size = UDim2.new(1, -110, 0, 40)
	box.Position = UDim2.fromOffset(12, 54)
	box.BackgroundColor3 = Palette.UiCream
	box.Font = UiKit.Body
	box.TextSize = 20
	box.TextColor3 = Palette.UiInk
	box.PlaceholderText = ":cmds   (Tab completes, Enter runs)"
	box.PlaceholderColor3 = Color3.fromHex("#8C8A88")
	box.Text = ""
	box.ClearTextOnFocus = false
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.Parent = panel
	UiKit.corner(box, 8)
	UiKit.stroke(box, 2, Palette.UiInk)
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.Parent = box

	local run = UiKit.button(panel, "Run", "RUN", UDim2.fromOffset(84, 40), UDim2.new(1, -54, 0, 74), Palette.UiGood)
	run.TextSize = 22

	local out = Instance.new("ScrollingFrame")
	out.Name = "Output"
	out.Size = UDim2.new(1, -24, 1, -112)
	out.Position = UDim2.fromOffset(12, 102)
	out.BackgroundColor3 = Color3.fromHex("#141018")
	out.BorderSizePixel = 0
	out.ScrollBarThickness = 6
	out.AutomaticCanvasSize = Enum.AutomaticSize.Y
	out.CanvasSize = UDim2.new()
	out.Parent = panel
	UiKit.corner(out, 8)
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 2)
	list.Parent = out
	local opad = Instance.new("UIPadding")
	opad.PaddingLeft = UDim.new(0, 8)
	opad.PaddingTop = UDim.new(0, 6)
	opad.Parent = out

	-- autocomplete drops over the output, under the box
	local suggest = Instance.new("Frame")
	suggest.Name = "Suggest"
	suggest.Size = UDim2.new(1, -110, 0, 0)
	suggest.AutomaticSize = Enum.AutomaticSize.Y
	suggest.Position = UDim2.fromOffset(12, 96)
	suggest.BackgroundColor3 = Palette.UiInk
	suggest.BorderSizePixel = 0
	suggest.Visible = false
	suggest.ZIndex = 8
	suggest.Parent = panel
	UiKit.corner(suggest, 8)
	local sl = Instance.new("UIListLayout")
	sl.SortOrder = Enum.SortOrder.LayoutOrder
	sl.Padding = UDim.new(0, 2)
	sl.Parent = suggest
	local sp = Instance.new("UIPadding")
	sp.PaddingTop = UDim.new(0, 3)
	sp.PaddingBottom = UDim.new(0, 3)
	sp.PaddingLeft = UDim.new(0, 3)
	sp.PaddingRight = UDim.new(0, 3)
	sp.Parent = suggest

	-- :m banner (everyone)
	local banner = UiKit.panel(g, "AdminMessage", UDim2.fromOffset(560, 0), UDim2.fromScale(0.5, 0.56), Vector2.new(0.5, 0.5)) -- under the console
	banner.AutomaticSize = Enum.AutomaticSize.Y
	banner.Visible = false
	banner.ZIndex = 4
	local bl = Instance.new("UIListLayout")
	bl.SortOrder = Enum.SortOrder.LayoutOrder
	bl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	bl.Padding = UDim.new(0, 4)
	bl.Parent = banner
	local bp = Instance.new("UIPadding")
	bp.PaddingTop = UDim.new(0, 10)
	bp.PaddingBottom = UDim.new(0, 14)
	bp.PaddingLeft = UDim.new(0, 16)
	bp.PaddingRight = UDim.new(0, 16)
	bp.Parent = banner
	local from = UiKit.label(banner, "From", "", UDim2.new(1, 0, 0, 30), UDim2.new(), {
		font = UiKit.Header,
		textSize = 26,
		color = Palette.UiRed,
	})
	from.LayoutOrder = 1
	local msg = UiKit.label(banner, "Text", "", UDim2.new(1, 0, 0, 0), UDim2.new(), {
		font = UiKit.Body,
		textSize = 24,
		color = Palette.UiInk,
	})
	msg.AutomaticSize = Enum.AutomaticSize.Y
	msg.LayoutOrder = 2

	-- :h hint (everyone)
	local hint = Instance.new("Frame")
	hint.Name = "AdminHint"
	hint.Size = UDim2.fromOffset(620, 38)
	hint.Position = UDim2.fromScale(0.5, 0.2)
	hint.AnchorPoint = Vector2.new(0.5, 0.5)
	hint.BackgroundColor3 = Palette.UiPanelDark
	hint.BackgroundTransparency = 0.15
	hint.Visible = false
	hint.Parent = g
	UiKit.corner(hint, 10)
	UiKit.stroke(hint, 2, Palette.UiInk)
	local hintText = UiKit.label(hint, "Text", "", UDim2.new(1, -20, 1, 0), UDim2.fromOffset(10, 0), {
		font = UiKit.Body,
		textSize = 20,
		color = Palette.UiWarn,
		stroke = true,
		strokeThickness = 1.5,
	})
	hintText.TextScaled = true

	ui = {
		gui = g,
		chip = chip,
		panel = panel,
		box = box,
		suggest = suggest,
		output = out,
		banner = banner,
		bannerFrom = from,
		bannerText = msg,
		hint = hint,
		hintText = hintText,
	}

	chip.Activated:Connect(function()
		setOpen(not panel.Visible)
	end)
	close.Activated:Connect(function()
		setOpen(false)
	end)
	run.Activated:Connect(function()
		submit(box.Text)
		box.Text = ""
		box:CaptureFocus()
	end)
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if string.find(box.Text, "\t", 1, true) then
			-- Tab: take the top suggestion
			local top = suggestions[1]
			box.Text = top or (string.gsub(box.Text, "\t", ""))
			box.CursorPosition = #box.Text + 1
			return
		end
		updateSuggest()
	end)
	box.FocusLost:Connect(function(enter: boolean)
		if enter then
			submit(box.Text)
			box.Text = ""
			task.defer(function()
				if panel.Visible then
					box:CaptureFocus()
				end
			end)
		end
	end)

	addLine("Type a command (prefix optional) or :cmds. Esc / X closes.", Palette.UiWarn)
end

------------------------------------------------------------------------------------------ announce

local function showBanner(from: string, text: string)
	local u = ui
	if not u then
		return
	end
	bannerSeq += 1
	local seq = bannerSeq
	u.bannerFrom.Text = `MESSAGE FROM {string.upper(from)}`
	u.bannerText.Text = text
	u.banner.Visible = true
	UiKit.pop(u.banner, 0.3)
	task.delay(Cfg.MessageSeconds, function()
		if bannerSeq == seq then
			u.banner.Visible = false
		end
	end)
end

local function showHint(from: string, text: string)
	local u = ui
	if not u then
		return
	end
	hintSeq += 1
	local seq = hintSeq
	u.hintText.Text = `{from}: {text}`
	u.hint.Visible = true
	UiKit.punch(u.hint, 0.08)
	task.delay(Cfg.HintSeconds, function()
		if hintSeq == seq then
			u.hint.Visible = false
		end
	end)
end

--------------------------------------------------------------------------------------- fly/noclip

local flyConn: RBXScriptConnection? = nil
local flyBits: { Instance } = {}

local function stopFly()
	if flyConn then
		flyConn:Disconnect()
		flyConn = nil
	end
	for _, b in flyBits do
		b:Destroy()
	end
	flyBits = {}
	local c = player.Character
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
end

local function startFly()
	stopFly()
	local c = player.Character
	local root = c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = c and c:FindFirstChildOfClass("Humanoid")
	if not root or not hum then
		return
	end
	local att = Instance.new("Attachment")
	att.Name = "AdminFlyAtt"
	att.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Name = "AdminFly"
	lv.Attachment0 = att
	lv.MaxForce = 1e6
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VectorVelocity = Vector3.zero
	lv.Parent = root
	local ao = Instance.new("AlignOrientation")
	ao.Name = "AdminFlyGyro"
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = att
	ao.MaxTorque = 1e6
	ao.Responsiveness = 30
	ao.Parent = root
	flyBits = { att, lv, ao }
	hum.PlatformStand = true
	flyConn = RunService.RenderStepped:Connect(function()
		local cam = workspace.CurrentCamera
		if not cam or not root.Parent then
			return
		end
		local move = hum.MoveDirection
		local up = 0
		if not UserInputService:GetFocusedTextBox() then
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				up += 1
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.C) then
				up -= 1
			end
		end
		local look = cam.CFrame.LookVector
		local v = move
		if move.Magnitude > 0.05 then
			-- pitch with the camera when moving forward/back
			local forward = Vector3.new(look.X, 0, look.Z)
			local along = if forward.Magnitude > 0 then move:Dot(forward.Unit) else 0
			v += Vector3.new(0, look.Y * along, 0)
		end
		v += Vector3.new(0, up, 0)
		lv.VectorVelocity = if v.Magnitude > 0 then v.Unit * Cfg.FlySpeed else Vector3.zero
		ao.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(look.X, 0, look.Z) + Vector3.new(0, 0, 1e-4))
	end)
end

local noclipConn: RBXScriptConnection? = nil
local collide: { [BasePart]: boolean } = {}

local function setNoclip(on: boolean)
	if noclipConn then
		noclipConn:Disconnect()
		noclipConn = nil
	end
	if not on then
		for part, was in collide do
			if part.Parent then
				part.CanCollide = was
			end
		end
		collide = {}
		return
	end
	noclipConn = RunService.Stepped:Connect(function()
		local c = player.Character
		if not c then
			return
		end
		for _, d in c:GetDescendants() do
			if d:IsA("BasePart") and d.CanCollide then
				if collide[d] == nil then
					collide[d] = true
				end
				d.CanCollide = false
			end
		end
	end)
end

local function syncBody()
	if player:GetAttribute(A.Fly) == true then
		startFly()
	else
		stopFly()
	end
	setNoclip(player:GetAttribute(A.Noclip) == true)
end

--------------------------------------------------------------------------------------------- boot

local function syncStaff()
	local u = ui
	if not u then
		return
	end
	local staff = rank() >= 1
	u.chip.Visible = staff
	if not staff then
		setOpen(false)
	end
end

function AdminController:Init(_all) end

function AdminController:Start()
	build()
	-- UI and body flags first: they only read attributes, so they work even while remotes are still coming
	player:GetAttributeChangedSignal(A.Rank):Connect(syncStaff)
	syncStaff()
	player:GetAttributeChangedSignal(A.Fly):Connect(syncBody)
	player:GetAttributeChangedSignal(A.Noclip):Connect(syncBody)
	player.CharacterAdded:Connect(function()
		stopFly()
		collide = {}
		task.wait(0.5)
		syncBody()
	end)
	syncBody()

	local Admin = ReplicatedStorage:WaitForChild("Net"):WaitForChild("Admin") -- the server may still be building the map
	runRemote = Admin:WaitForChild("Run") :: RemoteEvent
	local result = Admin:WaitForChild("Result") :: RemoteEvent
	local announce = Admin:WaitForChild("Announce") :: RemoteEvent

	result.OnClientEvent:Connect(function(ok: any, lines: any, open: any)
		if open == "cmds" then
			setOpen(true)
			showHelp()
			return
		end
		if type(lines) ~= "table" then
			return
		end
		for i, line in lines do
			if type(line) == "string" then
				addLine(line, if i == 1 then (if ok then Palette.UiGood else Palette.UiRed) else Palette.UiCream)
			end
		end
	end)
	announce.OnClientEvent:Connect(function(kind: any, from: any, text: any)
		if type(from) ~= "string" or type(text) ~= "string" then
			return
		end
		if kind == "m" then
			showBanner(from, text)
		elseif kind == "h" then
			showHint(from, text)
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local u = ui
		if not u then
			return
		end
		if input.KeyCode == Enum.KeyCode.Tab and u.panel.Visible and u.box:IsFocused() then
			local top = suggestions[1]
			if top then
				task.defer(function()
					u.box.Text = top
					u.box.CursorPosition = #top + 1
				end)
			end
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape and u.panel.Visible then
			setOpen(false)
			return
		end
		if processed or input.KeyCode ~= Cfg.ConsoleKey then
			return
		end
		if rank() >= 1 then
			setOpen(not u.panel.Visible)
		end
	end)
end

-- test hooks (execute_luau on the Client)
function AdminController:_open()
	setOpen(true)
end

function AdminController:_close()
	setOpen(false)
end

function AdminController:_submit(text: string)
	submit(text)
end

return AdminController
