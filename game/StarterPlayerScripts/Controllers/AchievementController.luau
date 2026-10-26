--!strict
-- AchievementController [owner: Achievements]. Client half of Services/AchievementService.
--   * 🏆 TROPHIES chip in the left chip column (lobby only, same look as NEWS / INVITE), in the first free
--     slot under ADMIN / INVITE; a red dot with the number of unlocks you haven't looked at yet.
--   * ACHIEVEMENTS panel: a HudLayout.modal (dims the HUD, shrinks to fit phones; gamepad: the cursor
--     lands on ALL, the D-pad moves between ALL / TO DO / DONE! and X, the right stick scrolls, B closes).
--     One card per achievement: tier-coloured icon, name, one line, a progress bar (7 / 10) and the XP
--     reward; unlocked cards turn gold-edged with DONE!, ones unlocked this session say NEW!. Pass-tier
--     ones past this season's MaxTier and `off` ones are hidden (AchievementRules.visible).
--   * Unlock: the toast itself comes from the server through the one HUD toast queue (Shared/Notify,
--     "🏆 ACHIEVEMENT! FIRST RESCUE +50 XP"); Achievements/Unlocked (sent the moment it shows) adds a
--     chime and punches the chip.
-- Text is English keys (Config/Translations); LocalizationController translates labels as they change.
-- Public: AchievementController:Open(), :Close(), :IsOpen(): boolean
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Config = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(Config:WaitForChild("AchievementConfig") :: ModuleScript) :: any
local Rules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Achievements"):WaitForChild("AchievementRules") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local HudGate = require(ClientLib:WaitForChild("HudGate") :: ModuleScript) :: any

local AchievementController = {}
AchievementController.Priority = 126

local player = Players.LocalPlayer

local TIER_COLOR: { [string]: Color3 } = {
	bronze = Color3.fromHex("#D98A4E"),
	silver = Color3.fromHex("#B9C6D3"),
	gold = Color3.fromHex("#FFC531"),
}
local LOCKED_FILL = Color3.fromHex("#E6D9C2")
local CHIP_SLOTS = { "AdminChip", "InviteChip" } -- chips above ours in the column (when visible)

local ui: { [string]: any } = {}
local open = false
local filter = "all" -- "all" | "todo" | "done"
local data: Rules.Data = Rules.empty()
local haveState = false
local fresh: { [string]: boolean } = {} -- unlocked this session: NEW! on the card
local unseen = 0 -- unlocks since the panel was last opened (chip dot)
local cards: { [string]: any } = {}

local function maxPassTier(): number?
	local ok, bp = pcall(function()
		return require(Config:WaitForChild("BattlePassConfig") :: ModuleScript) :: any
	end)
	return if ok and type(bp) == "table" then tonumber(bp.MaxTier) else nil
end

local function inLobby(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) ~= "string" or iid == ""
end

------------------------------------------------------------------------------------------ cards

local function frame(parent: Instance, name: string, size: UDim2, pos: UDim2, color: Color3, radius: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = pos
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	f.Parent = parent
	if radius then
		UiKit.corner(f, radius)
	end
	return f
end

local function buildCard(parent: Instance, def: any): any
	local card = frame(parent, "Card_" .. def.id, UDim2.fromOffset(100, 100), UDim2.new(), LOCKED_FILL, 14)
	local stroke = UiKit.stroke(card, 3, Palette.UiInk)
	local disc = frame(card, "Icon", UDim2.fromOffset(78, 78), UDim2.new(0, 12, 0.5, -39), TIER_COLOR[def.tier] or TIER_COLOR.bronze, 39)
	UiKit.stroke(disc, 3, Palette.UiInk)
	local icon = UiKit.label(disc, "Emoji", def.icon, UDim2.fromScale(1, 1), UDim2.new(), { textSize = 44 })
	icon.ZIndex = 3
	local lock = UiKit.label(disc, "Lock", "🔒", UDim2.fromOffset(38, 38), UDim2.new(1, -26, 1, -30), { textSize = 30 })
	lock.ZIndex = 4
	local name = UiKit.label(card, "Name", def.name, UDim2.new(1, -112, 0, 30), UDim2.fromOffset(102, 6), {
		font = UiKit.Header,
		textSize = 25,
		align = Enum.TextXAlignment.Left,
	})
	name.TextWrapped = false
	name.TextTruncate = Enum.TextTruncate.AtEnd
	local desc = UiKit.label(card, "Desc", def.desc, UDim2.new(1, -112, 0, 40), UDim2.fromOffset(102, 34), {
		textSize = 19,
		align = Enum.TextXAlignment.Left,
	})
	desc.TextYAlignment = Enum.TextYAlignment.Top
	local bar = frame(card, "Bar", UDim2.new(1, -196, 0, 20), UDim2.new(0, 102, 1, -30), Palette.UiPanelDark, 10)
	local fill = frame(bar, "Fill", UDim2.fromScale(0, 1), UDim2.new(), Palette.UiGood, 10)
	local count = UiKit.label(bar, "Count", "0 / 1", UDim2.fromScale(1, 1), UDim2.new(), {
		font = UiKit.Header,
		textSize = 16,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 1.5,
	})
	count.ZIndex = 4
	fill.ZIndex = 3
	local reward = UiKit.label(card, "Xp", `+{def.xp} XP`, UDim2.fromOffset(84, 24), UDim2.new(1, -90, 1, -32), {
		font = UiKit.Header,
		textSize = 19,
		color = Palette.UiFlameMid,
	})
	local newTag = UiKit.label(card, "New", "NEW!", UDim2.fromOffset(64, 26), UDim2.new(1, -70, 0, 6), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiCream,
	})
	newTag.BackgroundTransparency = 0
	newTag.BackgroundColor3 = Palette.UiRed
	newTag.ZIndex = 4
	UiKit.corner(newTag, 8)
	return { card = card, stroke = stroke, icon = icon, lock = lock, disc = disc, name = name, fill = fill, count = count, reward = reward, newTag = newTag, def = def }
end

local function paintCard(c: any)
	local cur, goal, done = Rules.progress(c.def, data)
	c.card.BackgroundColor3 = if done then Palette.UiCream else LOCKED_FILL
	c.stroke.Color = if done then (TIER_COLOR[c.def.tier] or Palette.UiInk) else Palette.UiInk
	c.stroke.Thickness = if done then 5 else 3
	c.icon.TextTransparency = if done then 0 else 0.45
	c.disc.BackgroundTransparency = if done then 0 else 0.35
	c.lock.Visible = not done
	c.fill.Size = UDim2.fromScale(if done then 1 else cur / goal, 1)
	c.fill.BackgroundColor3 = if done then Palette.UiGood else Palette.UiWater
	c.count.Text = if done then "DONE!" else `{cur} / {goal}`
	c.newTag.Visible = fresh[c.def.id] == true
	c.reward.TextTransparency = if done then 0.4 else 0
end

local function sortKey(def: any): (number, number)
	local cur, goal, done = Rules.progress(def, data)
	if filter == "done" then
		return -(data.unlocked[def.id] or 0), 0
	end
	return if done then 1 else 0, -cur / goal
end

local function refresh()
	if not ui.panel then
		return
	end
	local maxTier = maxPassTier()
	local order: { any } = {}
	for i, def in Cfg.Defs do
		local done = data.unlocked[def.id] ~= nil
		local show = (done or Rules.visible(def, maxTier))
			and (filter == "all" or (filter == "done" and done) or (filter == "todo" and not done))
		local c = cards[def.id]
		if c then
			c.card.Visible = show
			if show then
				paintCard(c)
				table.insert(order, { def = def, i = i })
			end
		end
	end
	if filter ~= "all" then
		table.sort(order, function(a, b)
			local a1, a2 = sortKey(a.def)
			local b1, b2 = sortKey(b.def)
			if a1 ~= b1 then
				return a1 < b1
			end
			if a2 ~= b2 then
				return a2 < b2
			end
			return a.i < b.i
		end)
	end
	for n, o in order do
		cards[o.def.id].card.LayoutOrder = n
	end
	local got, total = Rules.count(Cfg.Defs, data, maxTier)
	ui.total.Text = `{got} / {total}`
	ui.empty.Visible = #order == 0
	for key, b in ui.tabs do
		b.BackgroundColor3 = if key == filter then Palette.UiFlameMid else Palette.UiPanelDark
	end
end

------------------------------------------------------------------------------------------ chip

local function syncChip()
	local chip = ui.chip
	if not chip then
		return
	end
	chip.Visible = inLobby() and HudGate.allows("news") and not open
	ui.dot.Visible = unseen > 0
	ui.dotText.Text = tostring(math.min(unseen, 9))
	-- first free slot under the chips above us (ADMIN for admins, INVITE when invites work)
	local pg = player:FindFirstChild("PlayerGui")
	local n = 0
	for _, name in CHIP_SLOTS do
		local c = pg and pg:FindFirstChild(name, true)
		if c and c:IsA("GuiObject") and c.Visible then
			local g = c:FindFirstAncestorOfClass("ScreenGui")
			if g and g.Enabled then
				n += 1
			end
		end
	end
	local want = UDim2.new(0, 13, 0.53, 48 + 52 * n)
	if chip.Position ~= want then
		chip.Position = want
	end
end

local function buildChip()
	local b = Instance.new("TextButton")
	b.Name = "AchievementChip"
	b.Position = UDim2.new(0, 13, 0.53, 48)
	b.Size = UDim2.fromOffset(118, 40)
	b.BackgroundColor3 = Palette.UiFlameMid
	b.Font = UiKit.Header
	b.TextSize = 17
	b.TextColor3 = Palette.UiCream
	b.Text = "🏆 TROPHIES"
	b.AutoButtonColor = true
	b.Visible = false
	b.Parent = ui.gui
	UiKit.corner(b, 10)
	UiKit.stroke(b, 3, Palette.UiInk)
	local ts = Instance.new("UIStroke")
	ts.Thickness = 2
	ts.Color = Palette.UiInk
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = b
	local scale = Instance.new("UIScale")
	scale.Parent = b
	HudLayout.reserve(b)
	local dot = frame(b, "Dot", UDim2.fromOffset(22, 22), UDim2.new(1, -6, 0, -4), Palette.UiRed, 11)
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.ZIndex = 3
	dot.Visible = false
	UiKit.stroke(dot, 1.5, Palette.UiCream)
	local dt = UiKit.label(dot, "N", "1", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), {
		font = UiKit.Header,
		textSize = 15,
		color = Palette.UiCream,
	})
	dt.ZIndex = 4
	ui.chip = b
	ui.chipScale = scale
	ui.dot = dot
	ui.dotText = dt
	UiKit.onTap(b, function()
		if open then
			AchievementController:Close()
		else
			AchievementController:Open()
		end
	end)
end

------------------------------------------------------------------------------------------ panel

local function build()
	local g = UiKit.screen("Achievements", 30)
	ui.gui = g

	local p = UiKit.panel(g, "AchievementPanel", UDim2.fromOffset(880, 580), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	p.Visible = false
	p.ZIndex = 5
	p:SetAttribute("Menu", true) -- MenuMouseController frees the mouse in first person
	ui.panel = p
	HudLayout.modal(p, {
		onDismiss = function()
			AchievementController:Close()
		end,
	})

	-- header: red band, big title, the count, X
	local head = frame(p, "Header", UDim2.new(1, 0, 0, 80), UDim2.new(), Palette.UiRed, 12)
	frame(head, "Flat", UDim2.new(1, 0, 0, 14), UDim2.new(0, 0, 1, -14), Palette.UiRed)
	UiKit.label(head, "Title", "🏆 ACHIEVEMENTS", UDim2.new(1, -300, 1, 0), UDim2.fromOffset(22, 2), {
		font = UiKit.Header,
		textSize = 46,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
		align = Enum.TextXAlignment.Left,
	}).TextWrapped = false
	ui.total = UiKit.label(head, "Total", "0 / 0", UDim2.fromOffset(150, 50), UDim2.new(1, -230, 0.5, -25), {
		font = UiKit.Header,
		textSize = 38,
		color = Palette.UiFlameTop,
		stroke = true,
		strokeThickness = 3,
	})
	local close = UiKit.button(head, "Close", "X", UDim2.fromOffset(56, 56), UDim2.new(1, -40, 0.5, 0), Palette.UiPanelDark)
	close.TextSize = 30
	UiKit.onTap(close, function()
		AchievementController:Close()
	end)

	-- tabs
	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromOffset(20, 90)
	tabs.Size = UDim2.new(1, -40, 0, 54)
	tabs.Parent = p
	local tl = Instance.new("UIListLayout")
	tl.FillDirection = Enum.FillDirection.Horizontal
	tl.SortOrder = Enum.SortOrder.LayoutOrder
	tl.Padding = UDim.new(0, 12)
	tl.VerticalAlignment = Enum.VerticalAlignment.Center
	tl.Parent = tabs
	ui.tabs = {}
	for i, t in { { "all", "ALL" }, { "todo", "TO DO" }, { "done", "DONE!" } } do
		local b = UiKit.button(tabs, "Tab_" .. t[1], t[2], UDim2.fromOffset(170, 50), UDim2.new(), Palette.UiPanelDark)
		b.AnchorPoint = Vector2.zero
		b.TextSize = 26
		b.LayoutOrder = i
		if t[1] == "all" then
			b:SetAttribute("GamepadDefault", true)
		end
		UiKit.onTap(b, function()
			filter = t[1]
			ui.scroll.CanvasPosition = Vector2.zero
			refresh()
		end)
		ui.tabs[t[1]] = b
	end

	-- the card grid
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(20, 154)
	scroll.Size = UDim2.new(1, -30, 1, -166)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 12
	scroll.ScrollBarImageColor3 = Palette.UiInk
	scroll.Selectable = false
	scroll.ZIndex = 6
	scroll.Parent = p
	ui.scroll = scroll
	local pad = Instance.new("UIPadding")
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingLeft = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = scroll
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromOffset(404, 116)
	grid.CellPadding = UDim2.fromOffset(12, 12)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = scroll
	for i, def in Cfg.Defs do
		local c = buildCard(scroll, def)
		c.card.LayoutOrder = i
		cards[def.id] = c
	end
	ui.empty = UiKit.label(p, "Empty", "Keep playing to unlock more!", UDim2.new(1, -40, 0, 60), UDim2.new(0, 20, 0.5, 20), {
		font = UiKit.Header,
		textSize = 30,
		color = Palette.UiPanelDark,
	})
	ui.empty.Visible = false
	ui.empty.ZIndex = 7
end

------------------------------------------------------------------------------------------ public

function AchievementController:IsOpen(): boolean
	return open
end

function AchievementController:Open()
	if open or not ui.panel then
		return
	end
	open = true
	unseen = 0
	filter = "all"
	ui.scroll.CanvasPosition = Vector2.zero
	refresh()
	ui.panel.Visible = true
	UiKit.pop(ui.panel, 0.25)
	syncChip()
	if not haveState and ui.request then
		pcall(function()
			ui.request:FireServer("state")
		end)
	end
end

function AchievementController:Close()
	if not open then
		return
	end
	open = false
	ui.panel.Visible = false
	fresh = {}
	syncChip()
end

------------------------------------------------------------------------------------------ lifecycle

local function onState(snap: any)
	if type(snap) ~= "table" then
		return
	end
	local unlocked: { [string]: number } = {}
	if type(snap.unlocked) == "table" then
		for id, t in snap.unlocked do
			if type(id) == "string" and type(t) == "number" then
				unlocked[id] = t
			end
		end
	end
	local stats: { [string]: number } = {}
	if type(snap.stats) == "table" then
		for k, v in snap.stats do
			if type(k) == "string" and type(v) == "number" then
				stats[k] = v
			end
		end
	end
	data = { stats = stats, unlocked = unlocked, sites = {} }
	haveState = true
	if open then
		refresh()
	end
end

local function chime()
	local ok, audio = pcall(function()
		return require(Config:WaitForChild("AudioConfig") :: ModuleScript) :: any
	end)
	local s = ok and type(audio) == "table" and audio.Sounds and audio.Sounds.LevelUp
	if s and type(s.id) == "string" then
		UiKit.sound(s.id, 0.45, 1.25)
	end
end

local function onUnlocked(id: any, _xp: any)
	if type(id) ~= "string" then
		return
	end
	fresh[id] = true
	if not open then
		unseen += 1
	end
	chime()
	syncChip()
	if ui.chip and ui.chip.Visible then
		UiKit.punch(ui.chip, 0.25)
	end
	if open then
		refresh()
	end
end

function AchievementController:Init(_all: { [string]: any }) end

function AchievementController:Start()
	build()
	buildChip()
	task.spawn(function()
		local state = Net.event("Achievements", "State")
		state.OnClientEvent:Connect(onState)
		Net.event("Achievements", "Unlocked").OnClientEvent:Connect(onUnlocked)
		ui.request = Net.event("Achievements", "Request")
		pcall(function()
			ui.request:FireServer("state")
		end)
	end)
	player:GetAttributeChangedSignal("InstanceId"):Connect(function()
		if not inLobby() and open then
			AchievementController:Close() -- a call started: get the panel out of the way
		end
		syncChip()
	end)
	HudGate.onChanged(syncChip)
	-- the chips above ours come and go (admin, invite): re-check our slot now and then (cheap)
	while true do
		syncChip()
		task.wait(1)
	end
end

return AchievementController
