--!strict
-- BattlePassController [owner: BattlePass]. Client side of BattlePassService, sticker style (UiKit):
--   * Opened from the [P] PASS chip in the left chip column (HudLayout stack "Chips", first: PASS, NEWS,
--     INVITE, HELP, ADMIN) or [P]. Lobby only, everyone: free track for all; locked premium tiles say
--     UNLOCK and open the Premium Battle Pass purchase. The chip shows your tier, the XP to the next one
--     and a red badge counting rewards waiting for a Claim.
--   * The panel (attr Menu = true, so MenuMouseController frees the mouse): season name + countdown, a big
--     tier badge, XP bar, CLAIM ALL, and two tabs:
--       REWARDS  100 tiers in pages of Cfg.PageSize (page chips 1-10 ... 91-100 with a claim badge and a
--                star on the milestone pages; ◄ ► or L1 / R1 on a gamepad). Each page is a horizontal
--                track: big tier numbers on a progress rail, FREE and PREMIUM rows of reward cards (preview
--                icon, name, CLAIM / OWNED / LOCKED); milestone tiers (25/50/75/100) are gold columns.
--                Only one page of cards exists (they are re-filled on a page change), so 100 tiers cost the
--                same as 10 on a phone. Opens on the page of your next tier, scrolled to it.
--       LOCKER   every cosmetic by slot, one sideways-scrolling row per slot (built the first time the tab
--                opens); owned ones equip / unequip on click (saved in your profile), your XP boost and a
--                DANCE button for the equipped emote.
--   * Pass XP popups ("+25 PASS XP  Rescue") float from the chip in the lobby and from the top-bar box
--     (ClientLib/TopBox, the level / XP box) on a call, where the chip is hidden.
--   * Tier-up celebration (popup, confetti, LevelUp stinger) and emote FX for everyone ([K] to dance).
-- Renders only what the server sends (BattlePass/State, Gain, Claimed, Fx); intents go through
-- BattlePass/Request. Rules for drawing come from ReplicatedStorage/Lib/BattlePass/PassRules.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("BattlePassConfig") :: ModuleScript) :: any
local PassRules = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("BattlePass"):WaitForChild("PassRules") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)
local Calm = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("Calm") :: ModuleScript)
local Loc = require(game:GetService("ReplicatedStorage"):WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local BattlePassController = {}
BattlePassController.Priority = 110

local player = Players.LocalPlayer
local controllers: { [string]: any } = {}

local GOLD = Color3.fromHex("#FFC21F")
local GOLD_CARD = Color3.fromHex("#FFE08A")
local FREE_CARD = Color3.fromHex("#FFF1D6")
local GREY = Color3.fromHex("#8C8A88")
local DIM = Color3.fromHex("#3A3440")
local PANEL_W, PANEL_H = 1080, 600
local COL_W, CARD_W, CARD_H = 134, 122, 140
local TRACK_TOP = 192
local PAGE_BAR_H = 44 -- the page chips above the track
local MILESTONE = Color3.fromHex("#FFD84A")

local SLOT_LABEL = {
	helmet = "HELMET",
	title = "TITLE",
	hose = "HOSE",
	truck = "TRUCK",
	nozzle = "NOZZLE",
	emote = "EMOTE",
}

type Card = { frame: Frame, button: TextButton, status: TextLabel, shade: Frame, glow: UIStroke, id: string, tier: number, track: string, icon: Frame? }
type Tile = { frame: Frame, tag: TextLabel, stroke: UIStroke, id: string }

local state: { [string]: any }? = nil
local requestRemote: RemoteEvent? = nil
local ui: { [string]: any } = {}
local cards: { Card } = {}
local tiles: { Tile } = {}
local columns: { { frame: Frame, circle: Frame, num: TextLabel, star: TextLabel } } = {}
local tab = "rewards"
local page = 1 -- REWARDS page (tiers (page-1)*PageSize+1 .. page*PageSize)
local chips: { TextButton } = {}
local lockerBuilt = false

---------------------------------------------------------------------------------- helpers

local function hex(v: any, fallback: Color3): Color3
	if type(v) == "string" then
		local ok, c = pcall(Color3.fromHex, v)
		if ok then
			return c
		end
	end
	return fallback
end

local function owner(): boolean
	return player:GetAttribute(Cfg.PremiumAttribute) == true or player:GetAttribute(Cfg.PremiumDebugAttribute) == true
end

local function inLobby(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) ~= "string" or iid == ""
end

local function opts(s: { [string]: any }?): PassRules.Opts
	return {
		perTier = if s then s.perTier else Cfg.XpPerTier,
		maxTier = if s then s.maxTier else Cfg.MaxTier,
		needs = Cfg.XpCurve,
		tiers = Cfg.Tiers,
		rewards = Cfg.Rewards,
		boostCap = Cfg.BoostCapPct,
	}
end

-- the State payload as a PassRules.Pass, so the client can ask the same questions the server does
local function asPass(s: { [string]: any }): PassRules.Pass
	return {
		season = s.season,
		xp = s.xp,
		free = s.free or {},
		premium = s.premiumClaimed or {},
		equipped = s.equipped or {},
		legacy = true,
	}
end

local function request(kind: string, a: any?, b: any?)
	local r = requestRemote
	if r then
		r:FireServer(kind, a, b)
	end
end

local function sfx(name: string)
	local audio = controllers.AudioController
	if audio and type(audio.Play) == "function" then
		pcall(audio.Play, audio, name)
	end
end

local function frame(parent: Instance, name: string, size: UDim2, pos: UDim2, color: Color3, radius: number?): Frame
	local f = Instance.new("Frame")
	f.Name = name
	f.Size = size
	f.Position = pos
	f.BackgroundColor3 = color
	f.BorderSizePixel = 0
	if radius then
		UiKit.corner(f, radius)
	end
	f.Parent = parent
	return f
end

local function text(parent: Instance, name: string, t: string, size: UDim2, pos: UDim2, font: Enum.Font, px: number, color: Color3, stroke: boolean?): TextLabel
	return UiKit.label(parent, name, t, size, pos, { font = font, textSize = px, color = color, stroke = stroke })
end

---------------------------------------------------------------------------------- reward icons

-- A little picture of a reward, drawn from frames so it needs no image assets.
local function icon(parent: Instance, r: { [string]: any }, size: number): Frame
	local box = frame(parent, "Icon", UDim2.fromOffset(size, size), UDim2.fromOffset(0, 0), Color3.new(), nil)
	box.BackgroundTransparency = 1
	local s = size / 80
	local c = hex(r.Color, Palette.HelmetRed)
	if r.Slot == "helmet" then
		local dome = frame(box, "Dome", UDim2.fromOffset(56 * s, 44 * s), UDim2.fromOffset(12 * s, 12 * s), c, math.floor(28 * s))
		UiKit.stroke(dome, 2.5, Palette.UiInk)
		local brim = frame(box, "Brim", UDim2.fromOffset(72 * s, 12 * s), UDim2.fromOffset(4 * s, 50 * s), hex(r.Trim, c:Lerp(Color3.new(), 0.35)), math.floor(6 * s))
		UiKit.stroke(brim, 2.5, Palette.UiInk)
		local shield = frame(box, "Shield", UDim2.fromOffset(18 * s, 18 * s), UDim2.fromOffset(31 * s, 22 * s), if r.Chief then GOLD else Palette.HelmetShield, math.floor(5 * s))
		UiKit.stroke(shield, 2, Palette.UiInk)
		if r.Chief or r.Sparkle then
			text(box, "Star", "★", UDim2.fromOffset(28 * s, 28 * s), UDim2.fromOffset(26 * s, -10 * s), UiKit.Header, math.floor(28 * s), GOLD, true)
		end
		if r.Neon then
			local g = Instance.new("UIGradient")
			g.Color = ColorSequence.new(c, Color3.fromHex("#FFE45C"))
			g.Rotation = 90
			g.Parent = dome
		end
	elseif r.Slot == "title" then
		local rib = frame(box, "Ribbon", UDim2.fromOffset(76 * s, 34 * s), UDim2.fromOffset(2 * s, 23 * s), Palette.UiInk, math.floor(8 * s))
		local l = text(rib, "Text", string.upper(tostring(r.Name)), UDim2.new(1, -6, 1, -4), UDim2.fromOffset(3, 2), UiKit.Header, 14, c, false)
		l.TextScaled = true
		if r.Shine then
			l.TextColor3 = Color3.new(1, 1, 1)
			local g = Instance.new("UIGradient")
			g.Color = ColorSequence.new(Color3.fromHex("#FFF1A8"), Color3.fromHex("#FF8A1F"))
			g.Rotation = 90
			g.Parent = l
		end
	elseif r.Slot == "hose" then
		local hose = frame(box, "Hose", UDim2.fromOffset(70 * s, 20 * s), UDim2.fromOffset(5 * s, 30 * s), c, math.floor(10 * s))
		hose.Rotation = -22
		UiKit.stroke(hose, 2.5, Palette.UiInk)
		frame(hose, "Stripe", UDim2.new(1, -10, 0, math.max(2, 4 * s)), UDim2.new(0, 5, 0.5, -2 * s), hex(r.Stripe, Palette.HelmetRed), 2)
		local tip = frame(hose, "Tip", UDim2.fromOffset(14 * s, 24 * s), UDim2.new(1, -4 * s, 0.5, -12 * s), Palette.BrassCoupling, math.floor(4 * s))
		UiKit.stroke(tip, 2, Palette.UiInk)
	elseif r.Slot == "truck" then
		local glow = frame(box, "Glow", UDim2.fromOffset(78 * s, 16 * s), UDim2.fromOffset(1 * s, 56 * s), c, math.floor(8 * s))
		local g = Instance.new("UIGradient")
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.7), NumberSequenceKeypoint.new(0.5, 0), NumberSequenceKeypoint.new(1, 0.7) })
		g.Parent = glow
		if r.Pulse then
			g.Color = ColorSequence.new(c, hex(r.Pulse, c))
		end
		local body = frame(box, "Body", UDim2.fromOffset(66 * s, 30 * s), UDim2.fromOffset(7 * s, 22 * s), hex(r.Paint, Palette.TruckRed), math.floor(6 * s))
		UiKit.stroke(body, 2.5, Palette.UiInk)
		frame(body, "Window", UDim2.fromOffset(16 * s, 12 * s), UDim2.fromOffset(44 * s, 4 * s), Color3.fromHex("#9EC1CC"), 3)
		for i, x in { 14, 52 } do
			local w = frame(box, `Wheel{i}`, UDim2.fromOffset(16 * s, 16 * s), UDim2.fromOffset(x * s, 46 * s), Palette.UiInk, math.floor(8 * s))
			w.ZIndex = 3
		end
	elseif r.Slot == "nozzle" then
		local body = frame(box, "Body", UDim2.fromOffset(52 * s, 22 * s), UDim2.fromOffset(8 * s, 30 * s), c, math.floor(6 * s))
		UiKit.stroke(body, 2.5, Palette.UiInk)
		local tipf = frame(box, "Tip", UDim2.fromOffset(16 * s, 30 * s), UDim2.fromOffset(58 * s, 26 * s), c:Lerp(Color3.new(), 0.25), math.floor(6 * s))
		UiKit.stroke(tipf, 2.5, Palette.UiInk)
		local grip = frame(box, "Grip", UDim2.fromOffset(12 * s, 22 * s), UDim2.fromOffset(18 * s, 48 * s), Palette.UiInk, 3)
		grip.ZIndex = 1
		text(box, "Spark", "✦", UDim2.fromOffset(26 * s, 26 * s), UDim2.fromOffset(52 * s, 2 * s), UiKit.Header, math.floor(24 * s), Color3.new(1, 1, 1), true)
	elseif r.Slot == "emote" then
		local bubble = frame(box, "Bubble", UDim2.fromOffset(66 * s, 50 * s), UDim2.fromOffset(7 * s, 12 * s), Palette.UiWater, math.floor(22 * s))
		UiKit.stroke(bubble, 2.5, Palette.UiInk)
		if type(r.Fx) == "table" and r.Fx[1] then
			bubble.BackgroundColor3 = hex(r.Fx[1], Palette.UiWater)
		end
		local l = text(bubble, "Text", if r.Style == "spin" then "SPIN!" else "FLEX!", UDim2.new(1, -6, 1, 0), UDim2.fromOffset(3, 0), UiKit.Header, 16, Palette.UiCream, true)
		l.TextScaled = true
		local tail = frame(box, "Tail", UDim2.fromOffset(14 * s, 14 * s), UDim2.fromOffset(18 * s, 56 * s), Palette.UiWater, 2)
		tail.Rotation = 45
		tail.ZIndex = 0
	else -- boost
		local coin = frame(box, "Coin", UDim2.fromOffset(64 * s, 64 * s), UDim2.fromOffset(8 * s, 8 * s), Palette.UiGood, math.floor(32 * s))
		UiKit.stroke(coin, 3, Palette.UiInk)
		local l = text(coin, "Pct", `+{tonumber(r.Pct) or 0}%`, UDim2.new(1, -8, 0.6, 0), UDim2.new(0, 4, 0.12, 0), UiKit.Header, 20, Palette.UiCream, true)
		l.TextScaled = true
		text(coin, "Xp", "XP", UDim2.new(1, 0, 0.3, 0), UDim2.new(0, 0, 0.62, 0), UiKit.Header, math.floor(14 * s), Palette.UiInk, false)
	end
	return box
end

---------------------------------------------------------------------------------- celebration

local CONFETTI = { Palette.HelmetRed, GOLD, Palette.UiCream, Palette.UiWater, Palette.UiGood, Color3.fromHex("#FF7FC8") }

local function confetti(layer: Instance, origin: UDim2, n: number, spread: number)
	local rng = Random.new()
	for i = 1, n do
		local c = Instance.new("Frame")
		c.BorderSizePixel = 0
		c.AnchorPoint = Vector2.new(0.5, 0.5)
		c.BackgroundColor3 = CONFETTI[(i - 1) % #CONFETTI + 1]
		c.Size = UDim2.fromOffset(rng:NextInteger(8, 15), rng:NextInteger(5, 9))
		c.Position = origin
		c.Rotation = rng:NextNumber(0, 360)
		c.ZIndex = 40
		c.Parent = layer
		local a = rng:NextNumber(0, math.pi * 2)
		local d = rng:NextNumber(0.3, 1) * spread
		UiKit.tween(c, 0.45, {
			Position = origin + UDim2.fromScale(math.cos(a) * d, math.sin(a) * d * 0.8 - 0.06),
			Rotation = c.Rotation + rng:NextNumber(-240, 240),
		})
		task.delay(0.45, function()
			UiKit.tween(c, 1.1, {
				Position = c.Position + UDim2.fromScale(rng:NextNumber(-0.04, 0.04), 0.35),
				BackgroundTransparency = 1,
				Rotation = c.Rotation + rng:NextNumber(-180, 180),
			}, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			task.delay(1.15, function()
				c:Destroy()
			end)
		end)
	end
end

local function celebrateTier(tier: number, ids: { string }): Frame?
	local layer = ui.fx :: Frame?
	if not layer then
		return nil
	end
	local audio = controllers.AudioController
	if audio and type(audio.Stinger) == "function" then
		pcall(audio.Stinger, audio, "LevelUp")
	end
	-- screen centre: up at 0.36 it ran into the top-centre stack (timer, CALL! card, toasts)
	local card = UiKit.panel(layer, "TierUp", UDim2.fromOffset(460, 190), UDim2.fromScale(0.5, 0.52), Vector2.new(0.5, 0.5))
	HudLayout.reserve(card) -- edge arrows / world markers keep off it while it shows
	card.BackgroundColor3 = Palette.UiPanelDark
	card.ZIndex = 30
	local ribbon = frame(card, "Ribbon", UDim2.new(1, 0, 0, 44), UDim2.fromOffset(0, 0), GOLD, 12)
	ribbon.ZIndex = 31
	local rl = text(ribbon, "Text", "BATTLE PASS TIER UP!", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 0), UiKit.Header, 26, Palette.UiInk, false)
	rl.ZIndex = 32
	local big = text(card, "Tier", Loc.t("TIER {1}", { tier }), UDim2.new(1, 0, 0, 74), UDim2.fromOffset(0, 46), UiKit.Header, 72, GOLD, true)
	big.ZIndex = 32
	local names = {}
	for _, id in ids do
		local r = Cfg.Rewards[id]
		if r then
			table.insert(names, Loc.t(r.Name))
		end
	end
	local row = Cfg.Tiers[tier]
	local premiumHint = ""
	if row and owner() then
		local pr = Cfg.Rewards[row.Premium]
		if pr then
			premiumHint = Loc.t("  |  Premium: {1}, claim it!", { pr.Name })
		end
	end
	local sub = text(card, "Rewards", Loc.mark((if #names > 0 then Loc.t("Unlocked: {1}", { table.concat(names, ", ") }) else Loc.t("Keep going!")) .. premiumHint),
		UDim2.new(1, -24, 0, 56), UDim2.fromOffset(12, 124), UiKit.Body, 19, Palette.UiCream, false)
	sub.ZIndex = 32
	UiKit.pop(card, 0.35)
	confetti(layer, UDim2.fromScale(0.5, 0.52), if Calm.on() then 12 else 44, 0.32)
	task.delay(3.2, function()
		UiKit.tween(card, 0.3, { Position = UDim2.fromScale(0.5, -0.3) }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		task.delay(0.35, function()
			card:Destroy()
		end)
	end)
	return card
end

---------------------------------------------------------------------------------- XP popups

local pending = 0
local pendingReason = ""
local flushToken = 0

-- where pass XP popups start: the PASS chip (lobby), else the top-bar level / XP box (on a call)
local function popupAnchor(): GuiObject?
	local chip = ui.chip :: GuiObject?
	if chip and chip.Visible and (ui.gui :: ScreenGui).Enabled then
		return chip
	end
	local pg = player:FindFirstChild("PlayerGui")
	local top = pg and pg:FindFirstChild("TopBox")
	if top and top:IsA("ScreenGui") and top.Enabled then
		local box = top:FindFirstChildWhichIsA("GuiObject")
		if box and box.Visible then
			return box
		end
	end
	return nil
end

local function xpPopup(amount: number, reason: string)
	local pip = popupAnchor()
	local layer = ui.fx :: Frame?
	if not pip or not layer then
		return
	end
	local scale = (ui.gui :: ScreenGui):FindFirstChildOfClass("UIScale")
	local k = if scale then scale.Scale else 1
	local abs = pip.AbsolutePosition - layer.AbsolutePosition
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(260, 48)
	local y = abs.Y / k + pip.AbsoluteSize.Y / k + 4
	-- the top-centre tutorial card (OnboardingController) sits right under the pip: drop below it and
	-- its buttons instead of printing over "PUT OUT THE FIRE!"
	local pg = player:FindFirstChild("PlayerGui")
	local ob = pg and pg:FindFirstChild("Onboarding")
	local obCard = ob and ob:FindFirstChild("Card")
	if obCard and obCard:IsA("GuiObject") and obCard.Visible and (ob :: ScreenGui).Enabled then
		local below = (obCard.AbsolutePosition.Y + obCard.AbsoluteSize.Y - layer.AbsolutePosition.Y) / k + 56
		y = math.max(y, below)
	end
	local x = abs.X / k + 4
	if pip == ui.chip then
		-- the chip is in the left column: pop out to its right, level with it
		x = (abs.X + pip.AbsoluteSize.X) / k + 12
		y = abs.Y / k - 4
	end
	holder.Position = UDim2.fromOffset(x, y)
	holder.ZIndex = 20
	holder.Parent = layer
	local main = text(holder, "Main", Loc.t("+{1} PASS XP", { amount }), UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 0), UiKit.Header, 28, Palette.UiShock, true)
	main.TextXAlignment = Enum.TextXAlignment.Left
	main.ZIndex = 21
	local sub = text(holder, "Sub", reason, UDim2.new(1, 0, 0, 18), UDim2.fromOffset(2, 28), UiKit.Body, 17, Palette.UiCream, true)
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.ZIndex = 21
	UiKit.pop(holder, 0.25)
	task.delay(0.9, function()
		UiKit.tween(holder, 0.9, { Position = holder.Position + UDim2.fromOffset(0, 46) })
		for _, l in { main, sub } do
			UiKit.tween(l, 0.9, { TextTransparency = 1 })
			local st = l:FindFirstChildOfClass("UIStroke")
			if st then
				UiKit.tween(st, 0.9, { Transparency = 1 })
			end
		end
	end)
	task.delay(1.9, function()
		holder:Destroy()
	end)
	if pip == ui.chip then
		UiKit.punch(pip, 0.12)
	end
end

-- Calm (phones / EFFECTS: CALM): a small "+40 PASS" tick under the pip, no reason line, no punch
local function xpTick(amount: number)
	local pip = popupAnchor()
	local layer = ui.fx :: Frame?
	if not pip or not layer then
		return
	end
	local scale = (ui.gui :: ScreenGui):FindFirstChildOfClass("UIScale")
	local k = if scale then scale.Scale else 1
	local abs = pip.AbsolutePosition - layer.AbsolutePosition
	local pos = if pip == ui.chip
		then UDim2.fromOffset((abs.X + pip.AbsoluteSize.X) / k + 12, abs.Y / k + 8)
		else UDim2.fromOffset(abs.X / k + 4, (abs.Y + pip.AbsoluteSize.Y) / k + 4)
	local l = text(layer, "PassTick", Loc.t("+{1} PASS", { amount }), UDim2.fromOffset(120, 22), pos, UiKit.Body, 18, Palette.UiShock, true)
	l.TextXAlignment = Enum.TextXAlignment.Left
	l.ZIndex = 21
	task.delay(0.9, function()
		UiKit.tween(l, 0.6, { TextTransparency = 1 })
		local st = l:FindFirstChildOfClass("UIStroke")
		if st then
			UiKit.tween(st, 0.6, { Transparency = 1 })
		end
	end)
	task.delay(1.6, function()
		l:Destroy()
	end)
end

-- many fires out in a burst = one popup with the sum (calm: a longer window, so a run of +5s is one tick)
local function queuePopup(amount: number, reason: string)
	pending += amount
	pendingReason = reason
	flushToken += 1
	local token = flushToken
	local calm = Calm.on()
	task.delay(if calm then 1.0 else 0.35, function()
		if token == flushToken and pending > 0 then
			if Calm.on() then
				xpTick(pending)
			else
				xpPopup(pending, pendingReason)
			end
			pending = 0
		end
	end)
end

---------------------------------------------------------------------------------- painting

local function paintCard(c: Card, s: { [string]: any }, pass: PassRules.Pass)
	local claimedList = if c.track == "free" then pass.free else pass.premium
	local claimed = table.find(claimedList, c.tier) ~= nil
	local reached = c.tier <= s.tier
	local lockedPremium = c.track == "premium" and not s.premium
	local b = c.button
	c.shade.Visible = not reached or lockedPremium
	c.glow.Enabled = false
	b.Visible = true
	b.AutoButtonColor = false
	if claimed then
		b.Text = if pass.equipped[(Cfg.Rewards[c.id] or {}).Slot or ""] == c.id then "EQUIPPED" else "OWNED"
		b.BackgroundColor3 = Palette.UiGood
		b.TextSize = 17
	elseif not reached then
		b.Text = Loc.t("TIER {1}", { c.tier })
		b.BackgroundColor3 = GREY
		b.TextSize = 18
	elseif lockedPremium then
		b.Text = "UNLOCK"
		b.BackgroundColor3 = Palette.UiGood
		b.TextSize = 17
	else
		b.Text = "CLAIM"
		b.BackgroundColor3 = Palette.UiWarn
		b.TextSize = 22
		b.AutoButtonColor = true
		c.glow.Enabled = true
	end
end

local function paintTiles(s: { [string]: any }, pass: PassRules.Pass)
	local owned = PassRules.owned(pass, s.premium, opts(s))
	for _, t in tiles do
		local r = Cfg.Rewards[t.id]
		local has = owned[t.id] == true
		local on = pass.equipped[r.Slot] == t.id
		t.stroke.Color = if on then Palette.UiGood else Palette.UiInk
		t.stroke.Thickness = if on then 5 else 3
		t.frame.BackgroundColor3 = if on then Color3.fromHex("#DFF7D2") elseif has then FREE_CARD else DIM
		t.tag.Text = if on then "EQUIPPED" elseif has then "EQUIP" else "LOCKED"
		t.tag.TextColor3 = if on then Palette.UiGood elseif has then Palette.UiInk else Palette.UiCream
		local shade = t.frame:FindFirstChild("Shade") :: Frame?
		if shade then
			shade.Visible = not has
		end
	end
	local boost = ui.boost :: TextLabel?
	if boost then
		boost.Text = `PASS XP BOOST  +{s.boost or 0}%` .. (if s.premium then `   |   PREMIUM x{Cfg.PremiumXpMultiplier}` else "")
	end
	local dance = ui.dance :: TextButton?
	if dance then
		local e = Cfg.Rewards[pass.equipped.emote or ""]
		dance.Visible = e ~= nil and owned[pass.equipped.emote] == true
		InputHints.setChip(dance, Cfg.EmoteKey.Name, "DANCE", true)
	end
end

local function paintPip(s: { [string]: any }?)
	local pip = ui.pip :: GuiObject?
	if not pip then
		return
	end
	-- everyone has the free track; the chip is a lobby button (missions: popups use the top-bar box)
	pip.Visible = s ~= nil and inLobby()
	if not s then
		return
	end
	;(ui.pipTier :: TextLabel).Text = tostring(s.tier)
	local frac = if s.need > 0 then s.into / s.need else 1
	UiKit.tween(ui.pipFill :: Frame, 0.3, { Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1) })
	local badge = ui.pipBadge :: Frame
	badge.Visible = s.claimable > 0
	;(badge:FindFirstChild("N") :: TextLabel).Text = tostring(s.claimable)
end

local function paint()
	local s = state
	paintPip(s)
	if not s or not ui.panel then
		return
	end
	local pass = asPass(s)
	;(ui.tierNum :: TextLabel).Text = tostring(s.tier)
	local frac = if s.need > 0 then s.into / s.need else 1
	UiKit.tween(ui.xpFill :: Frame, 0.35, { Size = UDim2.fromScale(math.clamp(frac, 0.02, 1), 1) })
	;(ui.xpText :: TextLabel).Text = if s.need > 0 then Loc.t("{1} / {2} XP", { s.into, s.need }) else "MAX TIER!"
	local nextRow = Cfg.Tiers[s.tier + 1]
	local nextText = ui.nextText :: TextLabel
	if nextRow then
		local fr = Cfg.Rewards[nextRow.Free]
		local pr = Cfg.Rewards[nextRow.Premium]
		nextText.Text = Loc.t("NEXT  TIER {1}:  {2}  +  {3}", { s.tier + 1, fr and fr.Name or "?", pr and pr.Name or "?" })
	else
		nextText.Text = Loc.t("ALL {1} TIERS DONE. YOU ARE A LEGEND!", { Cfg.MaxTier })
	end
	local ms = ui.milestone :: TextLabel?
	if ms then
		local nextMs = nil
		for _, m in Cfg.Milestones do
			if m > s.tier then
				nextMs = m
				break
			end
		end
		ms.Text = if nextMs then Loc.t("NEXT MILESTONE: TIER {1}", { nextMs }) else ""
	end
	;(ui.boostSmall :: TextLabel).Text = `XP boost +{s.boost or 0}%` .. (if s.premium then `  |  Premium x{Cfg.PremiumXpMultiplier}` else "")
	local all = ui.claimAll :: TextButton
	if s.claimable > 0 then
		all.Text = Loc.t("CLAIM ALL ({1})", { s.claimable })
		all.BackgroundColor3 = Palette.UiGood
		all.AutoButtonColor = true
	else
		all.Text = "ALL CLAIMED"
		all.BackgroundColor3 = GREY
		all.AutoButtonColor = false
	end
	-- rail fill (this page's part of it) + tier circles
	local first = (page - 1) * Cfg.PageSize
	local rail = ui.railFill :: Frame
	local railW = #columns * COL_W
	rail.Size = UDim2.new(0, math.clamp((s.tier - first - 0.5 + frac) * COL_W, 0, railW), 1, 0)
	for i, col in columns do
		local t = first + i
		col.frame.Visible = t <= Cfg.MaxTier
		local reached = t <= s.tier
		local big = table.find(Cfg.Milestones, t) ~= nil
		col.num.Text = tostring(t)
		col.num.TextSize = if t >= 100 then 24 else 32
		col.star.Visible = big
		col.frame.BackgroundTransparency = if big then 0.55 else 1
		col.circle.BackgroundColor3 = if t == s.tier + 1 then Palette.UiWarn elseif reached then Palette.UiFlameMid elseif big then MILESTONE:Lerp(DIM, 0.35) else DIM
		col.num.TextColor3 = if reached or t == s.tier + 1 or big then Palette.UiCream else GREY
	end
	for _, c in cards do
		if c.tier <= Cfg.MaxTier then
			paintCard(c, s, pass)
		end
	end
	-- page chips: current page lit, your page outlined, red badge = rewards waiting there
	local o = opts(s)
	for n, chip in chips do
		local waiting = 0
		for t = (n - 1) * Cfg.PageSize + 1, math.min(n * Cfg.PageSize, s.tier) do
			if PassRules.canClaim(pass, t, "free", s.premium, o) then
				waiting += 1
			end
			if PassRules.canClaim(pass, t, "premium", s.premium, o) then
				waiting += 1
			end
		end
		local lo = (n - 1) * Cfg.PageSize + 1
		local hi = n * Cfg.PageSize
		local mine = s.tier + 1 >= lo and s.tier + 1 <= hi or (s.tier >= Cfg.MaxTier and n == #chips)
		chip.BackgroundColor3 = if n == page then Palette.UiWarn elseif hi <= s.tier then Palette.UiFlameMid else Palette.UiPanelDark
		local st = chip:FindFirstChild("Mine") :: UIStroke?
		if st then
			st.Enabled = mine and n ~= page
		end
		local b = chip:FindFirstChild("Badge") :: Frame?
		if b then
			b.Visible = waiting > 0
			;(b:FindFirstChild("N") :: TextLabel).Text = tostring(waiting)
		end
	end
	paintTiles(s, pass)
end

---------------------------------------------------------------------------------- building

-- (re)fill a card for another tier (page change): new icon + name, same frame and button
local function setCard(c: Card, tier: number, id: string)
	c.tier = tier
	c.id = id
	local r = Cfg.Rewards[id] or { Slot = "boost", Name = id }
	if c.icon then
		c.icon:Destroy()
	end
	local ic = icon(c.frame, r, 70)
	ic.Position = UDim2.fromOffset((CARD_W - 70) / 2, 5)
	c.icon = ic
	c.status.Text = tostring(r.Name)
end

local function buildCard(parent: Instance, track: string, y: number): Card
	local f = frame(parent, track, UDim2.fromOffset(CARD_W, CARD_H), UDim2.fromOffset((COL_W - 4 - CARD_W) / 2, y), if track == "premium" then GOLD_CARD else FREE_CARD, 14)
	f.ZIndex = 2
	local glow = UiKit.stroke(f, 4, Palette.UiGood)
	glow.Enabled = false
	UiKit.stroke(f, 3, Palette.UiInk)
	local name = text(f, "Name", "", UDim2.new(1, -10, 0, 30), UDim2.fromOffset(5, 76), UiKit.Body, 15, Palette.UiInk, false)
	name.TextYAlignment = Enum.TextYAlignment.Center
	name.ZIndex = 4
	local shade = frame(f, "Shade", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Palette.UiPanelDark, 14)
	shade.BackgroundTransparency = 0.45
	shade.ZIndex = 5
	local b = UiKit.button(f, "Action", "CLAIM", UDim2.fromOffset(CARD_W - 16, 28), UDim2.new(0.5, 0, 1, -18), Palette.UiWarn)
	b.ZIndex = 6
	b.TextSize = 20
	local border = b:FindFirstChildOfClass("UIStroke")
	if border then
		border.Thickness = 3
	end
	local c: Card = { frame = f, button = b, status = name, shade = shade, glow = glow, id = "", tier = 0, track = track, icon = nil }
	b.Activated:Connect(function()
		local s = state
		if not s or c.tier < 1 or c.tier > Cfg.MaxTier then
			return
		end
		if track == "premium" and not s.premium then
			-- locked premium reward: open the Premium Battle Pass purchase (MonetizationService validates)
			sfx("Click")
			pcall(function()
				Net.event("Monetization", "Buy"):FireServer("pass", "PremiumPass")
			end)
			return
		end
		local ok = PassRules.canClaim(asPass(s), c.tier, track, s.premium, opts(s))
		if ok then
			sfx("Click")
			request("claim", c.tier, track)
		else
			UiKit.shake(f, 0.25, 4)
		end
	end)
	return c
end

local function pages(): number
	return math.ceil(Cfg.MaxTier / Cfg.PageSize)
end

-- show page n: re-fill the PageSize columns with that page's tiers (cards[2i-1] free, cards[2i] premium)
local function showPage(n: number)
	page = math.clamp(n, 1, pages())
	local first = (page - 1) * Cfg.PageSize
	for k, c in cards do
		local t = first + (k + 1) // 2
		local row = Cfg.Tiers[t]
		if row then
			setCard(c, t, if c.track == "free" then row.Free else row.Premium)
		else
			c.tier = t
		end
	end
	paint()
end

local function stepPage(d: number)
	if page + d < 1 or page + d > pages() then
		return
	end
	sfx("Click")
	showPage(page + d)
	local track = ui.track :: ScrollingFrame?
	if track then
		track.CanvasPosition = Vector2.new(0, 0)
	end
end

local function buildTrack(area: Frame)
	-- page bar: ◄ [1-10] [11-20] ... [91-100] ►   (L1 / R1 on a gamepad)
	local bar = frame(area, "Pages", UDim2.new(1, 0, 0, PAGE_BAR_H - 6), UDim2.fromOffset(0, 0), Color3.new(), nil)
	bar.BackgroundTransparency = 1
	local n = pages()
	local width = PANEL_W - 36
	local chipW = math.floor((width - 116 - (n - 1) * 6) / n)
	local prev = UiKit.button(bar, "Prev", "◄", UDim2.fromOffset(50, 36), UDim2.fromOffset(25, 19), Palette.UiPanelDark)
	prev.TextSize = 22
	prev.Activated:Connect(function()
		stepPage(-1)
	end)
	local nextB = UiKit.button(bar, "Next", "►", UDim2.fromOffset(50, 36), UDim2.new(1, -25, 0, 19), Palette.UiPanelDark)
	nextB.TextSize = 22
	nextB.Activated:Connect(function()
		stepPage(1)
	end)
	-- a pad pages with its bumpers: the arrows say so
	InputHints.watch(prev, function(mode)
		prev.Text = if mode == "gamepad" then "L1" else "◄"
		nextB.Text = if mode == "gamepad" then "R1" else "►"
	end)
	chips = {}
	for k = 1, n do
		local lo, hi = (k - 1) * Cfg.PageSize + 1, math.min(k * Cfg.PageSize, Cfg.MaxTier)
		local big = false
		for _, m in Cfg.Milestones do
			if m >= lo and m <= hi then
				big = true
			end
		end
		local chip = UiKit.button(bar, `Page{k}`, (if big then "★" else "") .. `{lo}-{hi}`, UDim2.fromOffset(chipW, 34),
			UDim2.fromOffset(58 + (k - 1) * (chipW + 6) + chipW / 2, 19), Palette.UiPanelDark)
		chip.TextSize = if chipW < 84 then 17 else 19
		chip.TextColor3 = if big then MILESTONE else Palette.UiCream
		local border = chip:FindFirstChildOfClass("UIStroke")
		if border then
			border.Thickness = 3
		end
		local mine = Instance.new("UIStroke")
		mine.Name = "Mine"
		mine.Thickness = 4
		mine.Color = Palette.UiShock
		mine.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
		mine.Enabled = false
		mine.Parent = chip
		local badge = frame(chip, "Badge", UDim2.fromOffset(22, 22), UDim2.new(1, -14, 0, -10), Palette.UiRed, 11)
		badge.ZIndex = 8
		UiKit.stroke(badge, 2, Palette.UiInk)
		local bn = text(badge, "N", "0", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, 14, Palette.UiCream, false)
		bn.ZIndex = 9
		badge.Visible = false
		chip.Activated:Connect(function()
			sfx("Click")
			showPage(k)
			local track = ui.track :: ScrollingFrame?
			if track then
				track.CanvasPosition = Vector2.new(0, 0)
			end
		end)
		chips[k] = chip
	end

	local labels = frame(area, "RowLabels", UDim2.fromOffset(104, 360), UDim2.fromOffset(0, PAGE_BAR_H), Color3.new(), nil)
	labels.BackgroundTransparency = 1
	local freeTag = UiKit.panel(labels, "Free", UDim2.fromOffset(96, CARD_H), UDim2.fromOffset(4, 62))
	text(freeTag, "T", "FREE", UDim2.new(1, 0, 0, 40), UDim2.fromOffset(0, 36), UiKit.Header, 28, Palette.UiInk, false)
	text(freeTag, "S", "for everyone", UDim2.new(1, -6, 0, 40), UDim2.fromOffset(3, 74), UiKit.Body, 15, Palette.CoatShadow, false)
	local premTag = UiKit.panel(labels, "Premium", UDim2.fromOffset(96, CARD_H), UDim2.fromOffset(4, 62 + CARD_H + 8))
	premTag.BackgroundColor3 = GOLD
	text(premTag, "Star", "★", UDim2.new(1, 0, 0, 40), UDim2.fromOffset(0, 10), UiKit.Header, 36, Palette.UiCream, true)
	text(premTag, "T", "PREMIUM", UDim2.new(1, -4, 0, 30), UDim2.fromOffset(2, 56), UiKit.Header, 20, Palette.UiInk, false)
	text(premTag, "S", "pass owners", UDim2.new(1, -6, 0, 30), UDim2.fromOffset(3, 88), UiKit.Body, 15, Palette.UiInk, false)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Track"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(110, PAGE_BAR_H)
	scroll.Size = UDim2.new(1, -110, 0, 360)
	scroll.ScrollingDirection = Enum.ScrollingDirection.X
	scroll.ScrollBarThickness = 10
	scroll.ScrollBarImageColor3 = Palette.UiInk
	scroll.CanvasSize = UDim2.fromOffset(COL_W * Cfg.PageSize + 20, 0)
	scroll.ElasticBehavior = Enum.ElasticBehavior.Always
	scroll.Selectable = false
	scroll.Parent = area
	ui.track = scroll

	local rail = frame(scroll, "Rail", UDim2.fromOffset(COL_W * Cfg.PageSize, 12), UDim2.fromOffset(0, 24), DIM, 6)
	UiKit.stroke(rail, 2, Palette.UiInk)
	local fill = frame(rail, "Fill", UDim2.new(0, 0, 1, 0), UDim2.fromOffset(0, 0), Palette.UiFlameMid, 6)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Palette.UiFlameLow, Palette.UiFlameTop)
	g.Parent = fill
	ui.railFill = fill

	cards = {}
	columns = {}
	for i = 1, Cfg.PageSize do
		-- the column frame turns into a gold backdrop on milestone tiers
		local col = frame(scroll, `Col{i}`, UDim2.fromOffset(COL_W - 4, 352), UDim2.fromOffset((i - 1) * COL_W + 2, 0), MILESTONE, 16)
		col.BackgroundTransparency = 1
		local circle = frame(col, "Circle", UDim2.fromOffset(54, 54), UDim2.fromOffset((COL_W - 4 - 54) / 2, 3), DIM, 27)
		circle.ZIndex = 3
		UiKit.stroke(circle, 3, Palette.UiInk)
		local num = text(circle, "Num", tostring(i), UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, 32, Palette.UiCream, true)
		num.ZIndex = 4
		local star = text(col, "Star", "★", UDim2.fromOffset(30, 30), UDim2.new(0.5, 16, 0, -6), UiKit.Header, 28, MILESTONE, true)
		star.ZIndex = 5
		star.Visible = false
		columns[i] = { frame = col, circle = circle, num = num, star = star }
		table.insert(cards, buildCard(col, "free", 62))
		table.insert(cards, buildCard(col, "premium", 62 + CARD_H + 8))
	end
	showPage(1)
end

-- the LOCKER: boost line + DANCE, then one row per slot (filled by fillLocker the first time it opens)
local function buildLocker(area: Frame)
	local top = frame(area, "Top", UDim2.new(1, 0, 0, 44), UDim2.fromOffset(0, 0), Palette.UiPanelDark, 12)
	UiKit.stroke(top, 3, Palette.UiInk)
	local boost = text(top, "Boost", "", UDim2.new(1, -240, 1, 0), UDim2.fromOffset(16, 0), UiKit.Header, 22, Palette.UiGood, true)
	boost.TextXAlignment = Enum.TextXAlignment.Left
	ui.boost = boost
	local dance = UiKit.button(top, "Dance", "DANCE", UDim2.fromOffset(200, 34), UDim2.new(1, -110, 0.5, 0), Palette.UiWater)
	dance.TextSize = 22
	dance.Activated:Connect(function()
		request("emote")
	end)
	ui.dance = dance

	local list = Instance.new("ScrollingFrame")
	list.Name = "Slots"
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Position = UDim2.fromOffset(0, 52)
	list.Size = UDim2.new(1, 0, 0, 352)
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ScrollBarThickness = 10
	list.ScrollBarImageColor3 = Palette.UiInk
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.CanvasSize = UDim2.fromScale(0, 0)
	list.Selectable = false
	list.Parent = area
	ui.lockerList = list
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list
	tiles = {}
end

local function fillLocker()
	if lockerBuilt then
		return
	end
	lockerBuilt = true
	local list = ui.lockerList :: ScrollingFrame
	-- every equippable reward by slot, in tier order
	local bySlot: { [string]: { { id: string, tier: number, track: string } } } = {}
	for t, row in Cfg.Tiers do
		for _, pair in { { row.Free, "free" }, { row.Premium, "premium" } } do
			local r = Cfg.Rewards[pair[1]]
			if r and SLOT_LABEL[r.Slot] then
				bySlot[r.Slot] = bySlot[r.Slot] or {}
				table.insert(bySlot[r.Slot], { id = pair[1], tier = t, track = pair[2] })
			end
		end
	end
	for i, slot in PassRules.Slots do
		local items = bySlot[slot] or {}
		local row = frame(list, slot, UDim2.new(1, -16, 0, 134), UDim2.fromOffset(0, 0), Color3.new(), nil)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		local tag = UiKit.panel(row, "Label", UDim2.fromOffset(100, 116), UDim2.fromOffset(2, 6))
		tag.BackgroundColor3 = Palette.UiFlameMid
		local tl = text(tag, "T", SLOT_LABEL[slot], UDim2.new(1, -8, 0, 44), UDim2.fromOffset(4, 8), UiKit.Header, 22, Palette.UiCream, true)
		tl.TextWrapped = true
		local off = UiKit.button(tag, "Off", "REMOVE", UDim2.fromOffset(86, 30), UDim2.new(0.5, 0, 1, -22), Palette.UiPanelDark)
		off.TextSize = 16
		off.Activated:Connect(function()
			sfx("Click")
			request("unequip", slot)
		end)
		-- a sideways strip per slot: 40 helmets don't fit across any screen
		local strip = Instance.new("ScrollingFrame")
		strip.Name = "Strip"
		strip.BackgroundTransparency = 1
		strip.BorderSizePixel = 0
		strip.Position = UDim2.fromOffset(108, 0)
		strip.Size = UDim2.new(1, -108, 1, 0)
		strip.ScrollingDirection = Enum.ScrollingDirection.X
		strip.ScrollBarThickness = 8
		strip.ScrollBarImageColor3 = Palette.UiInk
		strip.CanvasSize = UDim2.fromOffset(#items * 93 + 8, 0)
		strip.ElasticBehavior = Enum.ElasticBehavior.Always
		strip.Selectable = false
		strip.Parent = row
		for j, it in items do
			local r = Cfg.Rewards[it.id]
			local f = frame(strip, it.id, UDim2.fromOffset(88, 116), UDim2.fromOffset(2 + (j - 1) * 93, 6), FREE_CARD, 12)
			local st = UiKit.stroke(f, 3, Palette.UiInk)
			local ic = icon(f, r, 60)
			ic.Position = UDim2.fromOffset(14, 4)
			local nm = text(f, "Name", tostring(r.Name), UDim2.new(1, -6, 0, 30), UDim2.fromOffset(3, 64), UiKit.Body, 13, Palette.UiInk, false)
			nm.ZIndex = 3
			local tg = text(f, "Tag", "EQUIP", UDim2.new(1, 0, 0, 18), UDim2.fromOffset(0, 96), UiKit.Header, 15, Palette.UiInk, false)
			tg.ZIndex = 4
			local shade = frame(f, "Shade", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Palette.UiPanelDark, 12)
			shade.BackgroundTransparency = 0.5
			shade.ZIndex = 3
			local lockText = text(shade, "Req", (if it.track == "premium" then "★ " else "") .. Loc.t("TIER {1}", { it.tier }),
				UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, 40), UiKit.Header, 17, Palette.UiCream, true)
			lockText.ZIndex = 4
			local hit = Instance.new("TextButton")
			hit.Name = "Hit"
			hit.BackgroundTransparency = 1
			hit.Text = ""
			hit.Size = UDim2.fromScale(1, 1)
			hit.ZIndex = 6
			hit.Parent = f
			local tile: Tile = { frame = f, tag = tg, stroke = st, id = it.id }
			table.insert(tiles, tile)
			hit.Activated:Connect(function()
				local s = state
				if not s then
					return
				end
				local pass = asPass(s)
				if not PassRules.owns(pass, it.id, s.premium, opts(s)) then
					UiKit.shake(f, 0.25, 4)
					return
				end
				sfx("Click")
				if pass.equipped[r.Slot] == it.id then
					request("unequip", r.Slot)
				else
					request("equip", it.id)
				end
				UiKit.punch(f, 0.1)
			end)
		end
		task.wait() -- one slot per frame: a phone builds the locker without a hitch
	end
	paint()
end

local function setTab(name: string)
	tab = name
	if name == "locker" and not lockerBuilt then
		task.spawn(fillLocker)
	end
	;(ui.rewardsArea :: Frame).Visible = name == "rewards"
	;(ui.lockerArea :: Frame).Visible = name == "locker"
	for key, b in { rewards = ui.tabRewards, locker = ui.tabLocker } do
		local btn = b :: TextButton
		btn.BackgroundColor3 = if key == name then Palette.UiWarn else Palette.UiPanelDark
		btn.TextColor3 = Palette.UiCream
	end
end

local function scrollToTier()
	local s = state
	local track = ui.track :: ScrollingFrame?
	if not s or not track then
		return
	end
	-- the page of your next tier, then that column ~2nd from the left
	local target = math.min(s.tier + 1, Cfg.MaxTier)
	local pg = math.ceil(target / Cfg.PageSize)
	if pg ~= page then
		showPage(pg)
	end
	local idx = target - (pg - 1) * Cfg.PageSize
	-- CanvasPosition is in screen pixels; COL_W is in design pixels (the gui's UIScale shrinks them)
	local scale = (ui.gui :: ScreenGui):FindFirstChildOfClass("UIScale")
	local x = math.max(0, (idx - 2) * COL_W) * (if scale then scale.Scale else 1)
	UiKit.tween(track, 0.4, { CanvasPosition = Vector2.new(x, 0) })
end

local function setOpen(open: boolean)
	local p = ui.panel :: Frame?
	if not p then
		return
	end
	-- the pass is open to everyone: free track for all, premium track shows locked + a buy button
	if open then
		p.Visible = true
		UiKit.pop(p, 0.25)
		request("state")
		paint()
		task.delay(0.1, scrollToTier)
	else
		p.Visible = false
	end
end

local function toggle()
	local p = ui.panel :: Frame?
	if p then
		setOpen(not p.Visible)
	end
end

local function build()
	local g = UiKit.screen("BattlePassGui", 30) -- above the onboarding edge arrows (26) and mission guide (24)
	ui.gui = g

	-- PASS chip: the left chip column (HudLayout stack "Chips": PASS, NEWS, INVITE, HELP, ADMIN), lobby
	-- only, same style as NEWS. [P] keycap on PC; the gold circle is your tier, the strip under the text is
	-- the XP to the next one, the red badge counts rewards waiting for a Claim.
	local chip = Instance.new("TextButton")
	chip.Name = "PassButton"
	chip.Position = UDim2.new(0, 13, 0.45, 0)
	chip.Size = UDim2.fromOffset(118, 40)
	chip.BackgroundColor3 = Palette.UiFlameMid
	chip.Font = UiKit.Header
	chip.TextSize = 20
	chip.TextColor3 = Palette.UiCream
	InputHints.setChip(chip, Cfg.UiToggleKey.Name, "PASS")
	chip.Visible = false
	chip.AutoButtonColor = true
	chip.Parent = g
	UiKit.corner(chip, 10)
	UiKit.stroke(chip, 3, Palette.UiInk)
	local cts = Instance.new("UIStroke")
	cts.Thickness = 2
	cts.Color = Palette.UiInk
	cts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	cts.Parent = chip
	UiKit.onTap(chip, toggle)
	ui.chip = chip
	HudLayout.reserve(chip)
	HudLayout.add("Chips", chip, 1)
	local function badge(parent: Instance, size: number, pos: UDim2): Frame
		local b = frame(parent, "Badge", UDim2.fromOffset(size, size), pos, Palette.UiRed, size)
		b.ZIndex = 8
		UiKit.stroke(b, 2, Palette.UiInk)
		local n = text(b, "N", "0", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, math.floor(size * 0.6), Palette.UiCream, false)
		n.ZIndex = 9
		b.Visible = false
		return b
	end
	ui.chipBadge = badge(chip, 22, UDim2.new(1, -44, 0, -12))
	local circle = frame(chip, "Tier", UDim2.fromOffset(28, 28), UDim2.new(1, -14, 0.5, -14), GOLD, 14)
	circle.ZIndex = 5
	UiKit.stroke(circle, 2, Palette.UiInk)
	local pt = text(circle, "N", "0", UDim2.new(1, -4, 1, -6), UDim2.fromOffset(2, 4), UiKit.Header, 16, Palette.UiInk, false)
	pt.TextScaled = true
	local ptc = Instance.new("UITextSizeConstraint")
	ptc.MaxTextSize = 16
	ptc.Parent = pt
	pt.ZIndex = 6
	ui.pipTier = pt
	local bar = frame(chip, "Bar", UDim2.new(1, -30, 0, 5), UDim2.new(0, 8, 1, -8), Palette.UiPanelDark, 3)
	bar.ZIndex = 4
	local bf = frame(bar, "Fill", UDim2.fromScale(0, 1), UDim2.fromOffset(0, 0), Palette.UiShock, 3)
	bf.ZIndex = 4
	ui.pipFill = bf
	ui.pipBadge = ui.chipBadge
	ui.pip = chip

	-- panel
	local p = UiKit.panel(g, "Panel", UDim2.fromOffset(PANEL_W, PANEL_H), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	p.Visible = false
	p:SetAttribute("Menu", true)
	p.ZIndex = 5
	ui.panel = p
	-- a modal: dims the HUD (and our own chip / pip) under it, above every HUD gui; click outside closes
	HudLayout.modal(p, {
		onDismiss = function()
			setOpen(false)
		end,
	})

	local head = frame(p, "Header", UDim2.new(1, 0, 0, 72), UDim2.fromOffset(0, 0), Palette.UiRed, 12)
	frame(head, "Flat", UDim2.new(1, 0, 0, 14), UDim2.new(0, 0, 1, -14), Palette.UiRed, nil)
	local hg = Instance.new("UIGradient")
	hg.Color = ColorSequence.new(Palette.UiFlameLow, Palette.UiFlameMid)
	hg.Parent = head
	local title = text(head, "Title", "BATTLE PASS", UDim2.fromOffset(420, 44), UDim2.fromOffset(22, 2), UiKit.Header, 42, Palette.UiCream, true)
	title.TextXAlignment = Enum.TextXAlignment.Left
	local season = text(head, "Season", "", UDim2.fromOffset(560, 24), UDim2.fromOffset(24, 44), UiKit.Header, 19, Palette.UiFlameTop, true)
	season.TextXAlignment = Enum.TextXAlignment.Left
	ui.season = season
	local tr = UiKit.button(head, "TabRewards", "REWARDS", UDim2.fromOffset(150, 44), UDim2.new(1, -330, 0.5, 0), Palette.UiWarn)
	tr.TextSize = 22
	tr.Activated:Connect(function()
		sfx("Click")
		setTab("rewards")
		scrollToTier()
	end)
	ui.tabRewards = tr
	local tl = UiKit.button(head, "TabLocker", "LOCKER", UDim2.fromOffset(150, 44), UDim2.new(1, -170, 0.5, 0), Palette.UiPanelDark)
	tl.TextSize = 22
	tl.Activated:Connect(function()
		sfx("Click")
		setTab("locker")
	end)
	ui.tabLocker = tl
	local close = UiKit.button(head, "Close", "X", UDim2.fromOffset(46, 46), UDim2.new(1, -36, 0.5, 0), Palette.UiPanelDark)
	close.TextSize = 26
	UiKit.onTap(close, function()
		setOpen(false)
	end)

	-- progress row
	local tierBadge = frame(p, "TierBadge", UDim2.fromOffset(96, 96), UDim2.fromOffset(22, 84), Palette.UiFlameMid, 48)
	UiKit.stroke(tierBadge, 4, Palette.UiInk)
	local tbg = Instance.new("UIGradient")
	tbg.Color = ColorSequence.new(Palette.UiFlameTop, Palette.UiFlameLow)
	tbg.Rotation = 90
	tbg.Parent = tierBadge
	text(tierBadge, "Cap", "TIER", UDim2.new(1, 0, 0, 22), UDim2.fromOffset(0, 10), UiKit.Header, 18, Palette.UiInk, false)
	local tn = text(tierBadge, "Num", "0", UDim2.new(1, -10, 0, 52), UDim2.fromOffset(5, 32), UiKit.Header, 54, Palette.UiCream, true)
	tn.TextScaled = true
	local tnc = Instance.new("UITextSizeConstraint")
	tnc.MaxTextSize = 54
	tnc.Parent = tn
	ui.tierNum = tn
	local nextText = text(p, "Next", "", UDim2.fromOffset(640, 26), UDim2.fromOffset(134, 86), UiKit.Body, 19, Palette.UiInk, false)
	nextText.TextXAlignment = Enum.TextXAlignment.Left
	ui.nextText = nextText
	local xpBar = frame(p, "XpBar", UDim2.fromOffset(640, 36), UDim2.fromOffset(134, 116), Palette.UiPanelDark, 18)
	UiKit.stroke(xpBar, 3, Palette.UiInk)
	local xpFill = frame(xpBar, "Fill", UDim2.fromScale(0.02, 1), UDim2.fromOffset(0, 0), Palette.UiWater, 18)
	local xg = Instance.new("UIGradient")
	xg.Color = ColorSequence.new(Palette.UiShock, Palette.UiWater)
	xg.Parent = xpFill
	ui.xpFill = xpFill
	local xpText = text(xpBar, "Text", "", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, 24, Palette.UiCream, true)
	xpText.ZIndex = 4
	ui.xpText = xpText
	local boostSmall = text(p, "BoostSmall", "", UDim2.fromOffset(640, 22), UDim2.fromOffset(136, 156), UiKit.Body, 16, Palette.CoatShadow, false)
	boostSmall.TextXAlignment = Enum.TextXAlignment.Left
	ui.boostSmall = boostSmall
	local milestone = text(p, "Milestone", "", UDim2.fromOffset(330, 22), UDim2.fromOffset(444, 156), UiKit.Header, 17, Palette.UiFlameMid, false)
	milestone.TextXAlignment = Enum.TextXAlignment.Right
	ui.milestone = milestone
	local all = UiKit.button(p, "ClaimAll", "CLAIM ALL", UDim2.fromOffset(250, 66), UDim2.new(1, -150, 0, 132), Palette.UiGood)
	all.TextSize = 28
	all.Activated:Connect(function()
		local s = state
		if s and s.claimable > 0 then
			sfx("Click")
			request("claimAll")
		else
			UiKit.shake(all, 0.25, 4)
		end
	end)
	ui.claimAll = all

	-- tabs content
	local rewardsArea = frame(p, "Rewards", UDim2.new(1, -36, 0, 404), UDim2.fromOffset(18, TRACK_TOP), Color3.new(), nil)
	rewardsArea.BackgroundTransparency = 1
	ui.rewardsArea = rewardsArea
	buildTrack(rewardsArea)
	local lockerArea = frame(p, "Locker", UDim2.new(1, -36, 0, 404), UDim2.fromOffset(18, TRACK_TOP), Color3.new(), nil)
	lockerArea.BackgroundTransparency = 1
	ui.lockerArea = lockerArea
	buildLocker(lockerArea)
	setTab("rewards")

	-- fx layer (popups, tier-up, confetti) above everything
	local fx = frame(g, "Fx", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), Color3.new(), nil)
	fx.BackgroundTransparency = 1
	fx.ZIndex = 30 -- over the panel (20 while HudLayout.modal owns it)
	ui.fx = fx
end

---------------------------------------------------------------------------------- layout / visibility

-- the chip's place is HudLayout's "Chips" stack; nothing to place
local function placePip() end

local function syncVisibility()
	if not inLobby() then
		setOpen(false)
	end
	paintPip(state)
	placePip()
end

---------------------------------------------------------------------------------- emote fx

local function emoteFx(userId: number, style: string, id: string?)
	local def = if id then Cfg.Rewards[id] else nil
	if def and def.Slot ~= "emote" then
		def = nil
	end
	local who = Players:GetPlayerByUserId(userId)
	local char = who and who.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root or not char then
		return
	end
	local att = Instance.new("Attachment")
	att.Name = "PassEmoteFx"
	att.Parent = root
	local pe = Instance.new("ParticleEmitter")
	local fx = def and def.Fx
	if type(fx) == "table" and #fx >= 2 then
		local keys = {}
		for i, h in fx do
			table.insert(keys, ColorSequenceKeypoint.new((i - 1) / (#fx - 1), hex(h, GOLD)))
		end
		pe.Color = ColorSequence.new(keys)
	else
		pe.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, Palette.HelmetRed),
			ColorSequenceKeypoint.new(0.33, GOLD),
			ColorSequenceKeypoint.new(0.66, Palette.UiWater),
			ColorSequenceKeypoint.new(1, Palette.UiGood),
		})
	end
	pe.LightEmission = 0.6
	pe.Size = NumberSequence.new(0.35, 0.1)
	pe.Speed = NumberRange.new(10, 18)
	pe.SpreadAngle = Vector2.new(60, 60)
	pe.EmissionDirection = Enum.NormalId.Top
	pe.Acceleration = Vector3.new(0, -25, 0)
	pe.Lifetime = NumberRange.new(0.8, 1.3)
	pe.Rotation = NumberRange.new(0, 360)
	pe.RotSpeed = NumberRange.new(-300, 300)
	pe.Rate = 0
	pe.Parent = att
	pe:Emit(48)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(220, 50)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 6.2, 0)
	bb.AlwaysOnTop = true
	bb.Adornee = root
	bb.Parent = att
	local shout = if def and type(def.Shout) == "string" then def.Shout elseif style == "spin" then "VICTORY SPIN!" else "HERO FLEX!"
	local l = text(bb, "T", shout, UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), UiKit.Header, 34, GOLD, true)
	UiKit.pop(l, 0.3)
	task.delay(1.8, function()
		att:Destroy()
	end)
	if who ~= player then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	if style == "spin" then
		hum.AutoRotate = false
		local t0 = os.clock()
		-- Turns = full turns (the classic Victory Spin is 2 in 0.9 s); same speed, longer for more turns
		local turns = math.clamp(tonumber(def and def.Turns) or 2, 1, 5)
		local dur = 0.45 * turns
		local speed = math.pi * 2 / 0.45
		local conn: RBXScriptConnection? = nil
		conn = RunService.RenderStepped:Connect(function(dt)
			if os.clock() - t0 > dur or not root.Parent then
				hum.AutoRotate = true
				if conn then
					conn:Disconnect()
				end
				return
			end
			root.CFrame *= CFrame.Angles(0, dt * speed, 0)
		end)
		hum.Jump = true
	else
		hum.Jump = true
		root.AssemblyLinearVelocity += Vector3.new(0, math.clamp(tonumber(def and def.Hop) or 38, 10, 70), 0)
	end
end

---------------------------------------------------------------------------------- lifecycle

function BattlePassController:Init(all: { [string]: any })
	controllers = all
end

function BattlePassController:Start()
	build()
	requestRemote = Net.event("BattlePass", "Request")
	Net.event("BattlePass", "State").OnClientEvent:Connect(function(s: any)
		if type(s) ~= "table" then
			return
		end
		state = s
		paint()
	end)
	Net.event("BattlePass", "Gain").OnClientEvent:Connect(function(amount: any, reason: any, tier: any, tiersGained: any, ids: any)
		if type(amount) ~= "number" then
			return
		end
		if reason ~= "Active" then
			queuePopup(amount, if type(reason) == "string" then reason else "")
		end
		if type(tiersGained) == "number" and tiersGained > 0 and type(tier) == "number" then
			-- centre cards take turns and wait for the results screen to close (ClientLib/HudLayout)
			HudLayout.celebrate(function()
				local card = celebrateTier(tier, if type(ids) == "table" then ids else {})
				return 3.7, function()
					if card then
						card:Destroy()
					end
				end
			end)
		end
	end)
	Net.event("BattlePass", "Claimed").OnClientEvent:Connect(function(list: any)
		if type(list) ~= "table" then
			return
		end
		for _, c in list do
			for _, card in cards do
				if type(c) == "table" and card.tier == c.tier and card.track == c.track then
					UiKit.punch(card.frame, 0.18)
					local fx = ui.fx :: Frame
					local abs = card.frame.AbsolutePosition + card.frame.AbsoluteSize / 2 - fx.AbsolutePosition
					local vs = fx.AbsoluteSize
					if vs.X > 0 then
						confetti(fx, UDim2.fromScale(abs.X / vs.X, abs.Y / vs.Y), 16, 0.08)
					end
				end
			end
		end
		local audio = controllers.AudioController
		if audio and type(audio.Stinger) == "function" then
			pcall(audio.Stinger, audio, "Rescue")
		end
	end)
	Net.event("BattlePass", "Fx").OnClientEvent:Connect(function(kind: any, userId: any, style: any, id: any)
		if kind == "emote" and type(userId) == "number" then
			emoteFx(userId, if type(style) == "string" then style else "spin", if type(id) == "string" then id else nil)
		end
	end)

	for _, a in { Cfg.PremiumAttribute, Cfg.PremiumDebugAttribute, "InstanceId" } do
		player:GetAttributeChangedSignal(a):Connect(syncVisibility)
	end
	syncVisibility()
	task.spawn(function()
		while true do
			task.wait(0.5)
			placePip()
			local s = state
			local season = ui.season :: TextLabel?
			if s and season and ui.panel and (ui.panel :: Frame).Visible then
				local left = (tonumber(s.endsAt) or 0) - workspace:GetServerTimeNow()
				season.Text = Loc.t("{1}   |   ENDS IN {2}", { s.seasonName or Cfg.SeasonName, PassRules.countdown(left) })
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		local panel = ui.panel :: Frame?
		if panel and panel.Visible and tab == "rewards" and (input.KeyCode == Enum.KeyCode.ButtonL1 or input.KeyCode == Enum.KeyCode.ButtonR1) then
			stepPage(if input.KeyCode == Enum.KeyCode.ButtonL1 then -1 else 1)
			return
		end
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Cfg.UiToggleKey and (inLobby() or (ui.panel and (ui.panel :: Frame).Visible)) then
			toggle()
		elseif input.KeyCode == Cfg.EmoteKey and inLobby() then
			request("emote")
		end
	end)
	request("state")
end

-- test hooks (Client execute_luau can't require live modules; other controllers / a harness can)
function BattlePassController:_open()
	setOpen(true)
end

function BattlePassController:_close()
	setOpen(false)
end

function BattlePassController:_tab(name: string)
	setTab(name)
end

return BattlePassController
