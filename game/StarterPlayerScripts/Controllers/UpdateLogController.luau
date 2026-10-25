--!strict
-- UpdateLogController [owner: UpdateLog]. The WHAT'S NEW panel + the NEWS chip (list: Config/UpdateLog;
-- the server half, which remembers what you've seen in your profile: Services/UpdateLogService).
--   * Pops up by itself ONCE per new update (Player attr LastSeenUpdate ~= the newest version), but only
--     when nothing else is on screen: never during the first-fire tutorial (FirstFire burning / done /
--     queued, the tutorial cards, the title card), never on a call or a pad, never over a modal
--     (HudLayout.modal) or a busy screen (results, HudLayout.isBusy), and only after the screen has been
--     clear for ClearSeconds. Closing it (OK / X / tap outside) sends UpdateLog/Seen.
--   * Big header, the newest entry as a scrollable list, older entries folded under OLDER UPDATES, and a
--     big OK. A HudLayout.modal: dims the HUD, sits above it, shrinks to fit phones.
--   * 🔔 GET NOTIFIED OF UPDATES: ExperienceNotificationService:PromptOptIn() (hidden unless
--     CanPromptOptInAsync says yes). Closing the auto-shown panel with OK asks once by itself if you didn't
--     tap it, at most once per update (Player attr NotifyPromptedFor, saved in the profile).
--   * ⭐ FAVORITE THE GAME: AvatarEditorService:PromptSetFavorite(PlaceId, AvatarItemType.Asset, true), the
--     API for favoriting an experience (hidden when it's already a favorite or there's no PlaceId).
--   * NEWS chip in the left chip column (above ADMIN, under the touch HELP chip) re-opens it any time; a red
--     dot while the newest update is unseen. UiKit.onTap gives it a 44 px touch pad.
--   * Funnel events (UpdateLog/Event -> FunnelService): UpdateLogShown, NotifyPrompted, FavoritePrompted,
--     FavoriteAccepted. Roblox doesn't tell the game whether the opt-in was accepted, so no NotifyAccepted.
-- Public: UpdateLogController:Open(how: number?), :Close(), :IsOpen(): boolean
local AvatarEditorService = game:GetService("AvatarEditorService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local UpdateLog = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("UpdateLog") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript)
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript)

local UpdateLogController = {}
UpdateLogController.Priority = 125

local player = Players.LocalPlayer

local CLEAR_SECONDS = 3 -- the screen must be free this long before the panel pops up by itself
local MIN_SECONDS = 6 -- ...and never sooner than this after the character spawned (the title card)
local BUSY_PHASES = { burning = true, done = true, queued = true } -- FirstFire tutorial cards up
local STUDIO_PREVIEW = RunService:IsStudio() -- show both prompt buttons in Studio (they explain they're live-only)

local controllers: { [string]: any } = {}
local ui: { [string]: any } = {}
local open = false
local openedHow = 0 -- 1 = popped up by itself, 2 = NEWS chip
local autoShown = false -- popped up by itself this session
local tappedNotify = false
local canNotify = false
local canFavorite = false
local favPending = false -- our own favorite prompt is open (SocialAskController logs the like card's)
local eventRemote: RemoteEvent? = nil
local seenRemote: RemoteEvent? = nil

local function newest(): string
	local e = UpdateLog.latest()
	return if e then e.version else ""
end

local function unseen(): boolean
	return player:GetAttribute("UpdateLogReady") == true and UpdateLog.unseen(player:GetAttribute("LastSeenUpdate"))
end

local function logEvent(name: string, how: number?)
	if eventRemote then
		pcall(function()
			(eventRemote :: RemoteEvent):FireServer(name, how)
		end)
	end
end

------------------------------------------------------------------------------------------ prompts

local function notifyService(): any
	local ok, s = pcall(game.GetService, game, "ExperienceNotificationService")
	return if ok then s else nil
end

local function checkNotify(): boolean
	local s = notifyService()
	if not s then
		return false
	end
	local ok, can = pcall(function()
		return s:CanPromptOptInAsync()
	end)
	return ok and can == true
end

local function checkFavorite(): boolean
	if game.PlaceId == 0 then
		return false
	end
	local ok, fav = pcall(function()
		return AvatarEditorService:GetFavorite(game.PlaceId, Enum.AvatarItemType.Asset)
	end)
	-- GetFavorite failing doesn't mean the prompt can't open; only hide it when it says "already a favorite"
	return not (ok and fav == true)
end

local function flash(button: TextButton, text: string)
	local was = button.Text
	button.Text = text
	task.delay(2.5, function()
		if button.Parent and button.Text == text then
			button.Text = was
		end
	end)
end

local function layoutButtons()
	if not ui.notify then
		return
	end
	ui.notify.Visible = canNotify or STUDIO_PREVIEW
	ui.favorite.Visible = canFavorite or STUDIO_PREVIEW
end

local function promptNotify(auto: boolean): boolean
	if not canNotify then
		if not auto and ui.notify then
			flash(ui.notify, "WORKS IN THE LIVE GAME")
		end
		return false
	end
	local s = notifyService()
	local ok = s ~= nil and pcall(function()
		s:PromptOptIn()
	end)
	if ok then
		tappedNotify = true
		player:SetAttribute("NotifyPromptedFor", newest()) -- the server saves it too (NotifyPrompted)
		logEvent("NotifyPrompted", if auto then 1 else 2)
	end
	return ok
end

local function promptFavorite()
	if not canFavorite or game.PlaceId == 0 then
		if ui.favorite then
			flash(ui.favorite, "WORKS IN THE LIVE GAME")
		end
		return
	end
	local ok = pcall(function()
		AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
	end)
	if ok then
		favPending = true
		logEvent("FavoritePrompted")
	end
end

------------------------------------------------------------------------------------------ panel

local function entryBlock(parent: Instance, entry: UpdateLog.Entry, order: number, big: boolean): Frame
	local block = Instance.new("Frame")
	block.Name = "Entry_" .. entry.version
	block.BackgroundTransparency = 1
	block.Size = UDim2.new(1, 0, 0, 0)
	block.AutomaticSize = Enum.AutomaticSize.Y
	block.LayoutOrder = order
	block.Parent = parent
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, if big then 8 else 4)
	list.Parent = block

	local head = UiKit.label(block, "Title", `{entry.title}  <font color="#8C6F55" size="{if big then 24 else 20}">{entry.date}</font>`,
		UDim2.new(1, 0, 0, if big then 44 else 34), UDim2.new(), {
			font = UiKit.Header,
			textSize = if big then 36 else 28,
			color = Palette.UiRed,
			align = Enum.TextXAlignment.Left,
		})
	head.RichText = true
	head.LayoutOrder = 0
	for i, line in entry.items do
		local row = Instance.new("Frame")
		row.Name = "Item" .. i
		row.BackgroundColor3 = Color3.new(1, 1, 1)
		row.BackgroundTransparency = if i % 2 == 1 then 0.55 else 1
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, 0)
		row.AutomaticSize = Enum.AutomaticSize.Y
		row.LayoutOrder = i
		row.Parent = block
		UiKit.corner(row, 10)
		local pad = Instance.new("UIPadding")
		pad.PaddingLeft = UDim.new(0, 12)
		pad.PaddingRight = UDim.new(0, 12)
		pad.PaddingTop = UDim.new(0, 6)
		pad.PaddingBottom = UDim.new(0, 6)
		pad.Parent = row
		local l = UiKit.label(row, "Text", line, UDim2.new(1, 0, 0, 0), UDim2.new(), {
			textSize = if big then 28 else 22,
			align = Enum.TextXAlignment.Left,
		})
		l.AutomaticSize = Enum.AutomaticSize.Y
	end
	return block
end

local function build()
	local g = UiKit.screen("UpdateLog", 30)
	ui.gui = g

	local p = UiKit.panel(g, "UpdateLogPanel", UDim2.fromOffset(860, 580), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	p.Visible = false
	p.ZIndex = 5
	p:SetAttribute("Menu", true) -- MenuMouseController frees the mouse in first person
	ui.panel = p
	HudLayout.modal(p, {
		onDismiss = function()
			UpdateLogController:Close()
		end,
	})

	-- header: a red band with the big title and an X
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 84)
	head.BackgroundColor3 = Palette.UiRed
	head.BorderSizePixel = 0
	head.Parent = p
	UiKit.corner(head, 12)
	local flat = Instance.new("Frame") -- squares off the header's bottom corners
	flat.Size = UDim2.new(1, 0, 0, 14)
	flat.Position = UDim2.new(0, 0, 1, -14)
	flat.BackgroundColor3 = Palette.UiRed
	flat.BorderSizePixel = 0
	flat.Parent = head
	UiKit.label(head, "Title", "📰 WHAT'S NEW!", UDim2.new(1, -120, 1, 0), UDim2.fromOffset(22, 2), {
		font = UiKit.Header,
		textSize = 50,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
		align = Enum.TextXAlignment.Left,
	})
	local close = UiKit.button(head, "Close", "X", UDim2.fromOffset(56, 56), UDim2.new(1, -40, 0.5, 0), Palette.UiPanelDark)
	close.TextSize = 30
	UiKit.onTap(close, function()
		UpdateLogController:Close()
	end)

	-- the list: newest entry open, older ones folded
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Body"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(20, 96)
	scroll.Size = UDim2.new(1, -40, 1, -96 - 112)
	scroll.CanvasSize = UDim2.new()
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.ScrollingDirection = Enum.ScrollingDirection.Y
	scroll.ScrollBarThickness = 12
	scroll.ScrollBarImageColor3 = Palette.UiInk
	scroll.ZIndex = 6
	scroll.Parent = p
	ui.scroll = scroll
	local pad = Instance.new("UIPadding")
	pad.PaddingRight = UDim.new(0, 18)
	pad.PaddingBottom = UDim.new(0, 8)
	pad.Parent = scroll
	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 12)
	list.Parent = scroll

	local entries = UpdateLog.Entries
	if entries[1] then
		entryBlock(scroll, entries[1], 1, true)
	end
	if #entries > 1 then
		local toggle = UiKit.button(scroll, "OlderToggle", "▶ OLDER UPDATES", UDim2.fromOffset(320, 56), UDim2.new(), Palette.UiPanelDark)
		toggle.AnchorPoint = Vector2.zero
		toggle.TextSize = 26
		toggle.LayoutOrder = 2
		local older = Instance.new("Frame")
		older.Name = "Older"
		older.BackgroundTransparency = 1
		older.Size = UDim2.new(1, 0, 0, 0)
		older.AutomaticSize = Enum.AutomaticSize.Y
		older.LayoutOrder = 3
		older.Visible = false
		older.Parent = scroll
		local ol = Instance.new("UIListLayout")
		ol.SortOrder = Enum.SortOrder.LayoutOrder
		ol.Padding = UDim.new(0, 14)
		ol.Parent = older
		for i = 2, #entries do
			entryBlock(older, entries[i], i, false)
		end
		UiKit.onTap(toggle, function()
			older.Visible = not older.Visible
			toggle.Text = if older.Visible then "▼ OLDER UPDATES" else "▶ OLDER UPDATES"
		end)
	end

	-- bottom row: GET NOTIFIED, FAVORITE, OK (hidden ones close up)
	local row = Instance.new("Frame")
	row.Name = "Buttons"
	row.BackgroundTransparency = 1
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -14)
	row.Size = UDim2.new(1, -28, 0, 86)
	row.Parent = p
	local rl = Instance.new("UIListLayout")
	rl.FillDirection = Enum.FillDirection.Horizontal
	rl.HorizontalAlignment = Enum.HorizontalAlignment.Center
	rl.VerticalAlignment = Enum.VerticalAlignment.Center
	rl.SortOrder = Enum.SortOrder.LayoutOrder
	rl.Padding = UDim.new(0, 14)
	rl.Parent = row

	local notify = UiKit.button(row, "Notify", "🔔 GET NOTIFIED OF UPDATES", UDim2.fromOffset(340, 80), UDim2.new(), Palette.UiWater)
	notify.LayoutOrder = 1
	notify.TextSize = 25
	notify.TextWrapped = true
	UiKit.onTap(notify, function()
		promptNotify(false)
	end)
	ui.notify = notify
	local favorite = UiKit.button(row, "Favorite", "⭐ FAVORITE THE GAME", UDim2.fromOffset(270, 80), UDim2.new(), Palette.UiWarn)
	favorite.LayoutOrder = 2
	favorite.TextSize = 25
	favorite.TextWrapped = true
	UiKit.onTap(favorite, promptFavorite)
	ui.favorite = favorite
	local ok = UiKit.button(row, "Ok", "OK!", UDim2.fromOffset(190, 86), UDim2.new(), Palette.UiGood)
	ok.LayoutOrder = 3
	ok.TextSize = 46
	UiKit.onTap(ok, function()
		UpdateLogController:Close(true)
	end)
	ui.ok = ok
	layoutButtons()
end

local function buildChip()
	-- left chip column, in the free slot above ADMIN (AdminController: 0.53 + 48) and below the touch HELP
	-- chip (OnboardingController: 0.4): the top-bar box already reaches the minimap on small screens
	local b = Instance.new("TextButton")
	b.Name = "NewsChip"
	b.Position = UDim2.new(0, 13, 0.53, -14) -- 22 above ADMIN: room for both 44 px touch pads on phones
	b.Size = UDim2.fromOffset(118, 40)
	b.BackgroundColor3 = Palette.UiFlameMid
	b.Font = UiKit.Header
	b.TextSize = 20
	b.TextColor3 = Palette.UiCream
	b.Text = "📰 NEWS"
	b.AutoButtonColor = true
	b.Parent = ui.gui
	UiKit.corner(b, 10)
	UiKit.stroke(b, 3, Palette.UiInk)
	local ts = Instance.new("UIStroke")
	ts.Thickness = 2
	ts.Color = Palette.UiInk
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = b
	HudLayout.reserve(b) -- edge arrows / world markers keep off it
	local dot = Instance.new("Frame")
	dot.Name = "Dot"
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.new(1, -4, 0, 4)
	dot.Size = UDim2.fromOffset(16, 16)
	dot.BackgroundColor3 = Palette.UiRed
	dot.BorderSizePixel = 0
	dot.ZIndex = 3
	dot.Visible = false
	dot.Parent = b
	UiKit.corner(dot, 8)
	UiKit.stroke(dot, 1.5, Palette.UiCream)
	ui.chip = b
	ui.dot = dot
	UiKit.onTap(b, function()
		if open then
			UpdateLogController:Close()
		else
			UpdateLogController:Open(2)
		end
	end)
end

local function syncDot()
	if ui.dot then
		ui.dot.Visible = unseen() and not open
	end
end

------------------------------------------------------------------------------------------ public

function UpdateLogController:IsOpen(): boolean
	return open
end

function UpdateLogController:Open(how: number?)
	if open or not ui.panel then
		return
	end
	open = true
	openedHow = how or 2
	tappedNotify = false
	ui.scroll.CanvasPosition = Vector2.zero
	layoutButtons()
	ui.panel.Visible = true
	UiKit.pop(ui.panel, 0.25)
	syncDot()
	logEvent("UpdateLogShown", openedHow)
	-- refresh the prompt buttons (both checks yield)
	task.spawn(function()
		canNotify = checkNotify()
		canFavorite = checkFavorite()
		layoutButtons()
	end)
end

-- viaOk: closed with the big OK (the only close that may follow up with the opt-in prompt)
function UpdateLogController:Close(viaOk: boolean?)
	if not open then
		return
	end
	open = false
	ui.panel.Visible = false
	local version = newest()
	if version ~= "" and player:GetAttribute("LastSeenUpdate") ~= version then
		player:SetAttribute("LastSeenUpdate", version) -- the server confirms (and saves) it
		if seenRemote then
			pcall(function()
				(seenRemote :: RemoteEvent):FireServer(version)
			end)
		end
	end
	syncDot()
	-- the one automatic ask: after the auto-shown panel, once per update, only if they didn't tap it
	if viaOk and openedHow == 1 and not tappedNotify and canNotify
		and player:GetAttribute("NotifyPromptedFor") ~= version then
		task.delay(0.4, function()
			promptNotify(true)
		end)
	end
end

------------------------------------------------------------------------------------------ auto show

local function guiShown(name: string, child: string?): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local g = pg and pg:FindFirstChild(name)
	if not g or not g:IsA("ScreenGui") or not g.Enabled then
		return false
	end
	if not child then
		return true
	end
	local c = g:FindFirstChild(child)
	return c ~= nil and c:IsA("GuiObject") and c.Visible
end

-- true while anything the panel must not cover is up
local function blocked(): boolean
	if player:GetAttribute("Onboarded") == nil then
		return true -- don't know yet if you're new
	end
	local iid = player:GetAttribute("InstanceId")
	if type(iid) == "string" and iid ~= "" then
		return true -- on a call
	end
	local squad = player:GetAttribute("SquadId")
	if type(squad) == "string" and squad ~= "" then
		return true -- on a pad (the first-call card lives here)
	end
	local phase = player:GetAttribute("FirstFire")
	if type(phase) == "string" and BUSY_PHASES[phase] then
		return true
	end
	local onb = controllers.OnboardingController
	if onb and type(onb.IsActive) == "function" then
		local ok, active = pcall(onb.IsActive, onb)
		if ok and active then
			return true
		end
	end
	if guiShown("Onboarding", "Card") or guiShown("OnboardingTitle") then
		return true
	end
	if HudLayout.modalOpen() or HudLayout.isBusy() then
		return true
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	return hum == nil or hum.Health <= 0
end

local function autoLoop()
	local clearSince: number? = nil
	local spawnedAt = os.clock()
	player.CharacterAdded:Connect(function()
		spawnedAt = os.clock()
	end)
	while not autoShown do
		task.wait(0.5)
		syncDot()
		if not unseen() or open then
			clearSince = nil
			continue
		end
		if blocked() then
			clearSince = nil
			continue
		end
		local now = os.clock()
		clearSince = clearSince or now
		if now - (clearSince :: number) >= CLEAR_SECONDS and now - spawnedAt >= MIN_SECONDS then
			autoShown = true
			UpdateLogController:Open(1)
		end
	end
end

------------------------------------------------------------------------------------------ lifecycle

function UpdateLogController:Init(all: { [string]: any })
	controllers = all
end

function UpdateLogController:Start()
	build()
	buildChip()
	task.spawn(function()
		eventRemote = Net.event("UpdateLog", "Event") :: RemoteEvent
		seenRemote = Net.event("UpdateLog", "Seen") :: RemoteEvent
	end)
	for _, attr in { "LastSeenUpdate", "UpdateLogReady" } do
		player:GetAttributeChangedSignal(attr):Connect(syncDot)
	end
	pcall(function()
		AvatarEditorService.PromptSetFavoriteCompleted:Connect(function(result: Enum.AvatarPromptResult)
			local mine = favPending
			favPending = false
			if result == Enum.AvatarPromptResult.Success then
				if mine then
					logEvent("FavoriteAccepted")
				end
				canFavorite = false
				layoutButtons()
			end
		end)
	end)
	pcall(function()
		local s = notifyService()
		if s then
			s.OptInPromptClosed:Connect(function()
				canNotify = checkNotify() -- opted in (or said no): the button goes away
				layoutButtons()
			end)
		end
	end)
	task.spawn(function()
		canNotify = checkNotify()
		canFavorite = checkFavorite()
		layoutButtons()
	end)
	syncDot()
	autoLoop()
end

return UpdateLogController
