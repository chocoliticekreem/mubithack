--!strict
-- RetentionController [owner: Retention]. Reasons to come back, in the lobby (docs/game/21-retention.md):
--   * the COME BACK card (ClientLib/ComeBack): "TOMORROW 🎁 +35 XP 🔥 1 / DAY 2 CHEST / ⭐ NEXT: NEW HELMET AT
--     LEVEL 3!", top-left beside the chip column, only at the station and only once the first call is done
--     (never during onboarding). Redrawn when the server's preview attrs (ResultsFlowService) or the level move.
--   * the "🔔 REMIND ME TOMORROW?" ask: after a finished call, back at the station, through ClientLib/PopupGate
--     ("notify": one auto pop-up at a time, spaced, allowed in a new player's first session). Only when Roblox
--     says it can prompt (ExperienceNotificationService:CanPromptOptInAsync: 13+, not opted in yet) and the
--     rules allow it (RetentionRules.shouldAsk: MaxAsks ever, once a session). YES -> Roblox's own
--     PromptOptIn; when it closes, "can't prompt any more" = opted in (Roblox doesn't tell the answer).
--     Every step goes to the server (Retention/Notify: shown | yes | no | closed, canPromptAfter) for the
--     profile and analytics; the server sends the next-day notification (RetentionService).
--   Studio: Roblox can't prompt there. Set Player attr RetentionPreview = true (client) to see the ask anyway;
--   its YES then only says "WORKS IN THE LIVE GAME" (nothing is recorded as an answer).
-- Test hooks: RetentionController:_ask() (open the ask now, past the rules), :_card() (redraw the card);
--   Players.LocalPlayer.RetentionTest:Invoke("ask" | "card" | "try")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("RetentionConfig") :: ModuleScript) :: any
local Rules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Retention"):WaitForChild("RetentionRules") :: ModuleScript)
local Loc = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local PopupGate = require(ClientLib:WaitForChild("PopupGate") :: ModuleScript) :: any
local ComeBack = require(ClientLib:WaitForChild("ComeBack") :: ModuleScript) :: any

local RetentionController = {}
RetentionController.Priority = 126

local player = Players.LocalPlayer
local IS_STUDIO = RunService:IsStudio()
local remote: RemoteEvent? = nil
local askedThisSession = false
local asking = false

local function inLobby(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) ~= "string" or iid == ""
end

local function report(action: string, can: boolean?)
	if remote then
		remote:FireServer(action, can)
	end
end

local function notifyService(): any
	local ok, s = pcall(game.GetService, game, "ExperienceNotificationService")
	return if ok then s else nil
end

local function canPrompt(): boolean
	local s = notifyService()
	if not s then
		return false
	end
	local ok, can = pcall(function()
		return s:CanPromptOptInAsync()
	end)
	return ok and can == true
end

local function preview(): boolean
	return IS_STUDIO and player:GetAttribute("RetentionPreview") == true
end

----------------------------------------------------------------------------------- COME BACK card

local cardGui: ScreenGui? = nil
local holder: Frame? = nil

local function redraw()
	local h = holder
	if not h then
		return
	end
	for _, c in h:GetChildren() do
		if c:IsA("GuiObject") then
			c:Destroy()
		end
	end
	local show = inLobby() and not PopupGate.onboarding() and player:GetAttribute("DailyNextDay") ~= nil
	if not show then
		h.Visible = false
		return
	end
	local ok, card = pcall(ComeBack.card, h, player, { width = 290, unlock = true })
	if ok and card then
		h.Size = UDim2.fromOffset(card.Size.X.Offset, card.Size.Y.Offset)
		h.Visible = true
	else
		h.Visible = false
	end
end

local pending = false
local function redrawSoon()
	if pending then
		return
	end
	pending = true
	task.delay(0.3, function()
		pending = false
		redraw()
	end)
end

local function buildCard()
	local g = UiKit.screen("ComeBackGui", 4)
	cardGui = g
	local h = Instance.new("Frame")
	h.Name = "ComeBack"
	h.BackgroundTransparency = 1
	h.Size = UDim2.fromOffset(290, 184)
	-- right of the left chip column (13 + 118 px wide, HudLayout "Chips"), like the lobby offer card
	h.Position = UDim2.fromOffset(143, 0)
	h.Visible = false
	h.Parent = g
	holder = h
	HudLayout.add("Left", h, 50) -- the stack owns its Y (under the top bar); empty in the lobby otherwise
	for _, attr in { "DailyNextDay", "DailyNextXp", "DailyNextWhen", "DailyNextCosmetic", "DailyStreakNow", "Level", "PassTier", "InstanceId", "FirstCallDone", "Onboarded", "FirstFire" } do
		player:GetAttributeChangedSignal(attr):Connect(redrawSoon)
	end
	redraw()
end

-------------------------------------------------------------------------------------- the ask

local function openAsk()
	local g = UiKit.screen("RemindAsk", 30)
	local p = UiKit.panel(g, "RemindPanel", UDim2.fromOffset(620, 340), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	p.ZIndex = 5
	p:SetAttribute("Menu", true) -- frees the first-person mouse
	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		PopupGate.release("notify")
		g:Destroy()
	end
	HudLayout.modal(p, {
		onDismiss = function()
			report("no")
			close()
		end,
	})
	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 76)
	head.BackgroundColor3 = Palette.UiWater
	head.BorderSizePixel = 0
	head.ZIndex = 6
	UiKit.corner(head, 12)
	head.Parent = p
	local title = UiKit.label(head, "Title", "🔔 REMIND ME TOMORROW?", UDim2.new(1, -24, 1, 0), UDim2.fromOffset(12, 0), {
		font = UiKit.Header,
		textSize = 38,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	title.ZIndex = 7
	local day = tonumber(player:GetAttribute("DailyNextDay")) or 2
	local xp = tonumber(player:GetAttribute("DailyNextXp")) or 0
	local body = UiKit.label(p, "Body", Loc.t("We'll ping you when your DAY {1} CHEST 🎁 (+{2} XP) is ready!", { day, xp }), UDim2.new(1, -40, 0, 110), UDim2.fromOffset(20, 90), {
		font = UiKit.Body,
		textSize = 30,
		color = Palette.UiInk,
	})
	body.ZIndex = 6
	local yes = UiKit.button(p, "Yes", "YES, REMIND ME!", UDim2.fromOffset(300, 84), UDim2.new(0.5, -110, 1, -64), Palette.UiGood)
	yes.TextSize = 30
	yes.ZIndex = 7
	local no = UiKit.button(p, "NotNow", "NOT NOW", UDim2.fromOffset(180, 72), UDim2.new(0.5, 175, 1, -64), Palette.UiRed)
	no.TextSize = 26
	no.ZIndex = 7
	UiKit.onTap(no, function()
		if closed then
			return
		end
		report("no")
		close()
	end)
	UiKit.onTap(yes, function()
		if closed then
			return
		end
		report("yes")
		local s = notifyService()
		if not canPrompt() or not s then
			yes.Text = "WORKS IN THE LIVE GAME"
			task.delay(1.5, close)
			return
		end
		close()
		local done = false
		local conn: RBXScriptConnection? = nil
		conn = s.OptInPromptClosed:Connect(function()
			if done then
				return
			end
			done = true
			if conn then
				conn:Disconnect()
			end
			report("closed", canPrompt()) -- can't prompt any more = opted in (Rules.optInAnswer)
		end)
		local ok, err = pcall(function()
			s:PromptOptIn()
		end)
		if not ok then
			warn(`[RetentionController] PromptOptIn: {err}`)
			done = true
			if conn then
				conn:Disconnect()
			end
		end
	end)
	UiKit.pop(p, 0.3)
	report("shown")
end

local function tryAsk()
	if asking or askedThisSession or not Cfg.Notify.Ask then
		return
	end
	asking = true
	task.wait(tonumber(Cfg.Notify.AskDelay) or 5)
	local ok, why = Rules.shouldAsk({
		enabled = Cfg.Notify.Ask == true,
		canPrompt = preview() or canPrompt(),
		firstCallDone = not PopupGate.onboarding(),
		inLobby = inLobby(),
		asks = tonumber(player:GetAttribute("NotifyAsks")) or 0,
		maxAsks = Cfg.Notify.MaxAsks,
		answer = player:GetAttribute("NotifyAnswer") or "",
		askedThisSession = askedThisSession,
	})
	if not ok then
		asking = false
		print(`[RetentionController] no remind-me ask: {why}`)
		return
	end
	-- a calm screen: no modal / results, and the PopupGate slot (it may say defer: then not this session)
	local t0 = os.clock()
	while HudLayout.modalOpen() or HudLayout.isBusy() or PopupGate.decide("notify") == "wait" do
		if os.clock() - t0 > 60 or not inLobby() then
			asking = false
			return
		end
		task.wait(0.5)
	end
	if not inLobby() or not PopupGate.claim("notify") then
		asking = false
		return
	end
	askedThisSession = true
	asking = false
	openAsk()
end

function RetentionController:Init(_all) end

function RetentionController:Start()
	remote = Net.event("Retention", "Notify")
	buildCard()
	local last = player:GetAttribute("InstanceId")
	player:GetAttributeChangedSignal("InstanceId"):Connect(function()
		local now = player:GetAttribute("InstanceId")
		local wasOnCall = type(last) == "string" and last ~= ""
		last = now
		if wasOnCall and inLobby() then
			task.spawn(tryAsk) -- back at the station after a call
		end
	end)
	-- a returning player who said NOT NOW last time: once, a while after joining (if a call is done already)
	task.delay(60, function()
		if player:GetAttribute("RetentionReady") == true and inLobby() then
			tryAsk()
		end
	end)
end

function RetentionController:_ask()
	PopupGate.claim("notify") -- may say no (tests open it anyway); release on close is harmless
	openAsk()
end

function RetentionController:_card()
	redraw()
end

-- Studio / tests: Players.LocalPlayer.RetentionTest:Invoke("ask" | "card" | "try") (execute_luau can't reach
-- this module's live copy)
task.defer(function()
	if player:FindFirstChild("RetentionTest") then
		return
	end
	local f = Instance.new("BindableFunction")
	f.Name = "RetentionTest"
	f.OnInvoke = function(what: string): string
		if what == "ask" then
			RetentionController:_ask()
		elseif what == "card" then
			redraw()
			return if holder then `visible={holder.Visible}` else "no holder"
		elseif what == "try" then
			askedThisSession = false
			task.spawn(tryAsk)
		end
		return "ok"
	end
	f.Parent = player
end)

return RetentionController
