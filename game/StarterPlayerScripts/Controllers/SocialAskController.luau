--!strict
-- SocialAskController [owner: Social]. The friendly asks (server half: Services/SocialAskService; rules and
-- caps: ReplicatedStorage/Lib/Social/AskRules). Nothing here ever gives a reward: Roblox doesn't allow
-- rewards for likes, favorites or invites.
--   * "Having fun? 👍" card: a small centre modal (HudLayout.modal) shown when the server set attr
--     LikeAskReady (a happy moment: >= 2 stars or a level up), only back at the station, never on a call,
--     a pad, the tutorial, the results screen or over another modal, after AskRules.Cfg.LobbySettleSeconds
--     in the lobby and ClearSeconds of calm, and never within OfferQuietSeconds of a pass offer (so the
--     like card and a pass offer never share a screen). It queues behind the LEVEL UP / NEW GEAR cards
--     (HudLayout.celebrate). Roblox has no thumbs-up API, so it shows where the 👍 is on the game page and
--     offers: ⭐ FAVORITE (AvatarEditorService:PromptSetFavorite, hidden when already a favorite), 🔔 NOTIFY
--     ME (ExperienceNotificationService:PromptOptIn, only when CanPromptOptInAsync), 👥 INVITE FRIENDS
--     (SocialService:PromptGameInvite, only when CanSendGameInviteAsync) and a big OK! to close.
--     Gamepad: OK! is selected, B closes. Touch: every button is >= 64 design px (UiKit.onTap pads).
--   * 👥 INVITE chip in the left chip column (lobby only, when invites are possible).
--   * Results screen (ResultsController calls :ResultsReady after its buttons are up): after a call with
--     a squad, a "Bring your friends next time!" line + INVITE at the top-left, once per session, never
--     on a screen with a pass offer (ResultsController removes it if an offer card arrives).
--   * Funnel events (SocialAsk/Event -> FunnelService): LikeAskShown, LikeAskClosed, InviteAskShown,
--     InvitePrompted, InviteSent, FavoritePrompted / FavoriteAccepted / NotifyPrompted (field "like").
-- Studio: the prompt buttons always show (they say "LIVE GAME ONLY"), since the prompts don't run.
-- Public: :Open() (test), :Close(kind?), :IsOpen(), :PromptInvite(source), :ResultsReady(root, payload, alive)
local AvatarEditorService = game:GetService("AvatarEditorService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SocialService = game:GetService("SocialService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local AskRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Social"):WaitForChild("AskRules") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local PopupGate = require(ClientLib:WaitForChild("PopupGate") :: ModuleScript) :: any
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any

local SocialAskController = {}
SocialAskController.Priority = 126

local player = Players.LocalPlayer
local Cfg = AskRules.Cfg
local STUDIO = RunService:IsStudio()
local BUSY_PHASES = { burning = true, done = true, queued = true } -- FirstFire tutorial cards up
local SRC_LIKE, SRC_LOBBY, SRC_RESULTS = 1, 2, 3
local CLOSE_OK, CLOSE_DISMISS, CLOSE_BACK = 1, 2, 3
local BACK_ACTION = "SocialAskClose"

local controllers: { [string]: any } = {}
local ui: { [string]: any } = {}
local open = false
local openedAt = 0
local queued = false
local gateHeld = false -- this open card holds the PopupGate slot ("like")
local canInvite = false
local canNotify = false
local canFavorite = false
local favPending = false -- our own favorite prompt is open (UpdateLogController logs its own)
local inviteSource = SRC_LOBBY
local lastOfferAt = -math.huge
local lobbySince = os.clock()
local nudged = 0
local eventRemote: RemoteEvent? = nil

local function logEvent(name: string, source: number, value: number?, kind: number?)
	if eventRemote then
		pcall(function()
			(eventRemote :: RemoteEvent):FireServer(name, source, value, kind)
		end)
	end
end

local function inLobby(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) ~= "string" or iid == ""
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
	return not (ok and fav == true) -- only hide it when Roblox says it already is one
end

local function checkInvite(): boolean
	local ok, can = pcall(function()
		return SocialService:CanSendGameInviteAsync(player)
	end)
	return ok and can == true
end

local function flash(button: TextButton?, text: string)
	if not button then
		return
	end
	local b = button :: TextButton
	local was = b:GetAttribute("Label") or b.Text
	b:SetAttribute("Label", was)
	b.Text = text
	task.delay(2.5, function()
		if b.Parent and b.Text == text then
			b.Text = was
		end
	end)
end

local function layoutButtons()
	if ui.favorite then
		ui.favorite.Visible = canFavorite or STUDIO
		ui.notify.Visible = canNotify or STUDIO
		ui.invite.Visible = canInvite or STUDIO
		ui.actions.Visible = ui.favorite.Visible or ui.notify.Visible or ui.invite.Visible
	end
	if ui.chip then
		ui.chip.Visible = inLobby() and (canInvite or STUDIO)
	end
end

function SocialAskController:PromptInvite(source: number, button: TextButton?)
	if not canInvite then
		flash(button, "LIVE GAME ONLY")
		return
	end
	local ok = pcall(function()
		local opts = Instance.new("ExperienceInviteOptions")
		opts.PromptMessage = Cfg.InviteMessage
		SocialService:PromptGameInvite(player, opts)
	end)
	if not ok then
		ok = pcall(function()
			SocialService:PromptGameInvite(player)
		end)
	end
	if ok then
		inviteSource = source
		logEvent("InvitePrompted", source)
	end
end

local function promptFavorite()
	if not canFavorite or game.PlaceId == 0 then
		flash(ui.favorite, "LIVE GAME ONLY")
		return
	end
	local ok = pcall(function()
		AvatarEditorService:PromptSetFavorite(game.PlaceId, Enum.AvatarItemType.Asset, true)
	end)
	if ok then
		favPending = true
		logEvent("FavoritePrompted", SRC_LIKE)
	end
end

local function promptNotify()
	if not canNotify then
		flash(ui.notify, "LIVE GAME ONLY")
		return
	end
	local s = notifyService()
	local ok = s ~= nil and pcall(function()
		s:PromptOptIn()
	end)
	if ok then
		logEvent("NotifyPrompted", SRC_LIKE)
	end
end

local function refresh()
	canInvite = checkInvite()
	canNotify = checkNotify()
	canFavorite = checkFavorite()
	layoutButtons()
end

------------------------------------------------------------------------------------------ card

local function actionButton(parent: Instance, name: string, text: string, color: Color3, order: number, fn: () -> ()): TextButton
	local b = UiKit.button(parent, name, text, UDim2.fromOffset(196, 72), UDim2.new(), color) :: TextButton
	b.LayoutOrder = order
	b.TextSize = 22
	b.TextWrapped = true
	b:SetAttribute("Label", text)
	UiKit.onTap(b, fn)
	return b
end

local function build()
	local g = UiKit.screen("SocialAsk", 30) :: ScreenGui
	ui.gui = g

	local p = UiKit.panel(g, "LikeAskPanel", UDim2.fromOffset(660, 470), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	p.Visible = false
	p.ZIndex = 5
	p:SetAttribute("Menu", true) -- MenuMouseController frees the mouse in first person
	ui.panel = p
	HudLayout.modal(p, {
		onDismiss = function()
			SocialAskController:Close(CLOSE_DISMISS)
		end,
	})

	-- header band
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 78)
	head.BackgroundColor3 = Palette.UiFlameMid
	head.BorderSizePixel = 0
	head.Parent = p
	UiKit.corner(head, 12)
	local flat = Instance.new("Frame")
	flat.Size = UDim2.new(1, 0, 0, 14)
	flat.Position = UDim2.new(0, 0, 1, -14)
	flat.BackgroundColor3 = Palette.UiFlameMid
	flat.BorderSizePixel = 0
	flat.Parent = head
	UiKit.label(head, "Title", "HAVING FUN? 👍", UDim2.new(1, -110, 1, 0), UDim2.fromOffset(22, 2), {
		font = UiKit.Header,
		textSize = 46,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
		align = Enum.TextXAlignment.Left,
	})
	local close = UiKit.button(head, "Close", "X", UDim2.fromOffset(56, 56), UDim2.new(1, -40, 0.5, 0), Palette.UiPanelDark)
	close.TextSize = 30
	UiKit.onTap(close, function()
		SocialAskController:Close(CLOSE_DISMISS)
	end)

	-- the picture: a little "game page" vote bar with a bouncing arrow on the 👍
	local page = Instance.new("Frame")
	page.Name = "GamePage"
	page.AnchorPoint = Vector2.new(0.5, 0)
	page.Position = UDim2.new(0.5, 0, 0, 132)
	page.Size = UDim2.fromOffset(300, 64)
	page.BackgroundColor3 = Palette.UiPanelDark
	page.BorderSizePixel = 0
	page.Parent = p
	UiKit.corner(page, 32)
	local up = Instance.new("Frame")
	up.Name = "ThumbUp"
	up.Position = UDim2.fromOffset(8, 8)
	up.Size = UDim2.fromOffset(136, 48)
	up.BackgroundColor3 = Palette.UiGood
	up.BorderSizePixel = 0
	up.Parent = page
	UiKit.corner(up, 24)
	UiKit.stroke(up, 3, Palette.UiCream)
	UiKit.label(up, "Icon", "👍", UDim2.fromScale(1, 1), UDim2.new(), { textSize = 34 })
	UiKit.label(page, "Down", "👎", UDim2.fromOffset(136, 48), UDim2.fromOffset(156, 8), { textSize = 30 }).TextTransparency = 0.55
	local arrow = UiKit.label(p, "Arrow", "⬇", UDim2.fromOffset(60, 46), UDim2.new(0.5, -104, 0, 84), {
		font = UiKit.Header,
		textSize = 44,
		color = Palette.UiWarn,
		stroke = true,
		strokeThickness = 3,
	})
	ui.arrow = arrow
	UiKit.label(p, "Line", "Tap 👍 on the game page to help us grow!", UDim2.new(1, -40, 0, 40), UDim2.fromOffset(20, 204), {
		font = UiKit.Header,
		textSize = 28,
		color = Palette.UiInk,
	})

	-- the real prompts (hidden ones close up)
	local actions = Instance.new("Frame")
	actions.Name = "Actions"
	actions.BackgroundTransparency = 1
	actions.AnchorPoint = Vector2.new(0.5, 0)
	actions.Position = UDim2.new(0.5, 0, 0, 256)
	actions.Size = UDim2.new(1, -28, 0, 76)
	actions.Parent = p
	local al = Instance.new("UIListLayout")
	al.FillDirection = Enum.FillDirection.Horizontal
	al.HorizontalAlignment = Enum.HorizontalAlignment.Center
	al.VerticalAlignment = Enum.VerticalAlignment.Center
	al.SortOrder = Enum.SortOrder.LayoutOrder
	al.Padding = UDim.new(0, 12)
	al.Parent = actions
	ui.actions = actions
	ui.favorite = actionButton(actions, "Favorite", "⭐ FAVORITE", Palette.UiWarn, 1, promptFavorite)
	ui.notify = actionButton(actions, "Notify", "🔔 NOTIFY ME", Palette.UiWater, 2, promptNotify)
	ui.invite = actionButton(actions, "Invite", "👥 INVITE FRIENDS", Palette.UiWater, 3, function()
		SocialAskController:PromptInvite(SRC_LIKE, ui.invite)
	end)

	local ok = UiKit.button(p, "Ok", "OK!", UDim2.fromOffset(220, 86), UDim2.new(0.5, 0, 1, -58), Palette.UiGood)
	ok.TextSize = 46
	UiKit.onTap(ok, function()
		SocialAskController:Close(CLOSE_OK)
	end)
	ui.ok = ok
	layoutButtons()
end

local function bounce()
	task.spawn(function()
		local arrow = ui.arrow :: TextLabel
		local base = arrow.Position
		while open and arrow.Parent do
			local y = math.abs(math.sin(os.clock() * 5)) * 10
			arrow.Position = base - UDim2.fromOffset(0, y)
			task.wait(1 / 30)
		end
		arrow.Position = base
	end)
end

------------------------------------------------------------------------------------------ public

function SocialAskController:IsOpen(): boolean
	return open
end

function SocialAskController:Open()
	if open or not ui.panel then
		return
	end
	open = true
	openedAt = os.clock()
	layoutButtons()
	ui.panel.Visible = true
	UiKit.pop(ui.panel, 0.25)
	bounce()
	logEvent("LikeAskShown", SRC_LIKE)
	if InputHints.mode() == "gamepad" then
		GuiService.SelectedObject = ui.ok
	end
	ContextActionService:BindActionAtPriority(BACK_ACTION, function(_, state: Enum.UserInputState)
		if state == Enum.UserInputState.Begin then
			SocialAskController:Close(CLOSE_BACK)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value + 10, Enum.KeyCode.ButtonB)
end

-- kind: 1 = OK!, 2 = X / tap outside, 3 = gamepad B
function SocialAskController:Close(kind: number?)
	if not open then
		return
	end
	open = false
	ui.panel.Visible = false
	if gateHeld then
		gateHeld = false
		PopupGate.release("like")
	end
	ContextActionService:UnbindAction(BACK_ACTION)
	local sel = GuiService.SelectedObject
	if sel and sel:IsDescendantOf(ui.panel) then
		GuiService.SelectedObject = nil
	end
	logEvent("LikeAskClosed", SRC_LIKE, math.floor(os.clock() - openedAt + 0.5), kind or CLOSE_OK)
end

-- ResultsController: its buttons are up. root = the 1280x720 design frame, alive() = still this screen.
function SocialAskController:ResultsReady(root: Frame, payload: any, alive: () -> boolean)
	task.spawn(function()
		local mates = AskRules.squadmates(payload, player.UserId)
		if mates < 1 or nudged >= Cfg.NudgePerSession then
			return
		end
		task.wait(1.2) -- a beat after the buttons (and any pass offer card)
		local can = canInvite or checkInvite()
		canInvite = can
		if not alive() or not root.Parent then
			return
		end
		local offerUp = root:FindFirstChild("OfferCard", true) ~= nil
		if not AskRules.inviteNudge({ squadmates = mates, nudged = nudged, offerOnScreen = offerUp, canInvite = can or STUDIO }) then
			return
		end
		nudged += 1
		-- top-left of the design frame: clear of the title, the stars, NEXT CALL and the offer slot
		local card = UiKit.panel(root, "InviteNudge", UDim2.fromOffset(360, 80), UDim2.fromOffset(12, 12))
		UiKit.label(card, "Text", "Bring your friends next time!", UDim2.new(1, -172, 1, -8), UDim2.fromOffset(12, 4), {
			font = UiKit.Header,
			textSize = 20,
			align = Enum.TextXAlignment.Left,
		}).TextWrapped = true
		local b = UiKit.button(card, "Invite", "👥 INVITE", UDim2.fromOffset(136, 64), UDim2.new(1, -76, 0.5, 0), Palette.UiWater)
		b.TextSize = 22
		UiKit.onTap(b, function()
			SocialAskController:PromptInvite(SRC_RESULTS, b)
		end)
		UiKit.pop(card, 0.3)
		logEvent("InviteAskShown", SRC_RESULTS)
	end)
end

------------------------------------------------------------------------------------------ lobby chip

local function buildChip()
	local b = Instance.new("TextButton")
	b.Name = "InviteChip"
	b.Position = UDim2.new(0, 13, 0.53, 48)
	b.Size = UDim2.fromOffset(118, 40)
	b.BackgroundColor3 = Palette.UiWater
	b.Font = UiKit.Header
	b.TextSize = 20
	b.TextColor3 = Palette.UiCream
	b.Text = "👥 INVITE"
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
	HudLayout.reserve(b)
	HudLayout.add("Chips", b, 3) -- left chip column: PASS, NEWS, INVITE, HELP, ADMIN (the stack owns its Y)
	UiKit.onTap(b, function()
		SocialAskController:PromptInvite(SRC_LOBBY, b)
	end)
	ui.chip = b
end

-- the chip's place is HudLayout's "Chips" stack (after NEWS, before HELP and ADMIN); nothing to place
local function placeChip() end

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

local function offerUp(): boolean
	local pg = player:FindFirstChild("PlayerGui")
	local g = pg and pg:FindFirstChild("OfferGui")
	return g ~= nil and g:FindFirstChild("OfferCard", true) ~= nil
end

local function tutorial(): boolean
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
	return guiShown("Onboarding", "Card") or guiShown("OnboardingTitle")
end

local function calm(): boolean
	local squad = player:GetAttribute("SquadId")
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local now = os.clock()
	return AskRules.calm({
		inLobby = inLobby(),
		onPad = type(squad) == "string" and squad ~= "",
		onboarded = player:GetAttribute("Onboarded") ~= nil,
		tutorial = tutorial(),
		modal = HudLayout.modalOpen(),
		busy = HudLayout.isBusy(),
		alive = hum ~= nil and hum.Health > 0,
		sinceLobby = now - lobbySince,
		sinceOffer = now - lastOfferAt,
		offerUp = offerUp(),
	})
end

local function autoLoop()
	local clearSince: number? = nil
	while true do
		task.wait(0.5)
		layoutButtons()
		placeChip()
		if open or queued or player:GetAttribute("LikeAskReady") ~= true or not calm() or PopupGate.decide("like") ~= "show" then
			clearSince = nil -- PopupGate: one auto pop-up at a time, spaced, capped per session
			continue
		end
		local now = os.clock()
		clearSince = clearSince or now
		if now - (clearSince :: number) < Cfg.ClearSeconds then
			continue
		end
		clearSince = nil
		refresh() -- yields: which prompt buttons to show
		queued = true
		-- take a turn after any LEVEL UP / NEW GEAR card, then re-check the screen
		HudLayout.celebrate(function()
			queued = false
			if player:GetAttribute("LikeAskReady") == true and calm() and not open and PopupGate.claim("like") then
				gateHeld = true
				SocialAskController:Open()
			end
			return 0.05
		end, "turn")
	end
end

------------------------------------------------------------------------------------------ lifecycle

function SocialAskController:Init(all: { [string]: any })
	controllers = all
end

function SocialAskController:Start()
	build()
	buildChip()
	task.spawn(function()
		eventRemote = Net.event("SocialAsk", "Event") :: RemoteEvent
	end)
	-- any pass offer keeps the like card away for OfferQuietSeconds
	task.spawn(function()
		Net.event("Monetization", "Offer").OnClientEvent:Connect(function()
			lastOfferAt = os.clock()
		end)
	end)
	player:GetAttributeChangedSignal("InstanceId"):Connect(function()
		if inLobby() then
			lobbySince = os.clock()
		end
		if not inLobby() and open then
			SocialAskController:Close(CLOSE_DISMISS) -- never during a call
		end
		layoutButtons()
	end)
	pcall(function()
		AvatarEditorService.PromptSetFavoriteCompleted:Connect(function(result: Enum.AvatarPromptResult)
			if not favPending then
				return
			end
			favPending = false
			if result == Enum.AvatarPromptResult.Success then
				logEvent("FavoriteAccepted", SRC_LIKE)
				canFavorite = false
				layoutButtons()
			end
		end)
	end)
	pcall(function()
		SocialService.GameInvitePromptClosed:Connect(function(who: Player, recipients: { number })
			if who ~= player then
				return
			end
			local n = if type(recipients) == "table" then #recipients else 0
			if n > 0 then
				logEvent("InviteSent", inviteSource, n)
			end
		end)
	end)
	pcall(function()
		local s = notifyService()
		if s then
			s.OptInPromptClosed:Connect(function()
				canNotify = checkNotify()
				layoutButtons()
			end)
		end
	end)
	task.spawn(refresh)
	autoLoop()
end

return SocialAskController
