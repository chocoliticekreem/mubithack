--!strict
-- BattlePassController [owner: BattlePass]. Client side of BattlePassService, sticker style (UiKit):
--   * "[P] PASS" chip on the left edge (lobby only, everyone: free track for all; locked premium tiles
--     say UNLOCK and open the Premium Battle Pass purchase. Previously owners only; everyone else buys
--     the pass in the STORE) with a red badge counting rewards waiting for a Claim.
--   * The panel (attr Menu = true, so MenuMouseController frees the mouse): season name + countdown, a big
--     tier badge, XP bar, CLAIM ALL, and two tabs:
--       REWARDS  a horizontal tier track: big tier numbers on a progress rail, FREE and PREMIUM rows of
--                reward cards (preview icon, name, CLAIM / OWNED / LOCKED), scrolled to your tier.
--       LOCKER   every cosmetic by slot; owned ones equip / unequip on click (saved in your profile),
--                your XP boost and a DANCE button for the equipped emote.
--   * HUD pip under the level panel (missions: top left): tier circle + mini XP bar + claim badge; pass
--     XP popups float up from it ("+25 PASS XP  Rescue").
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
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)

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
local COL_W, CARD_W, CARD_H = 134, 122, 150
local TRACK_TOP = 192

local SLOT_LABEL = {
	helmet = "HELMET",
	title = "TITLE",
	hose = "HOSE",
	truck = "TRUCK GLOW",
	nozzle = "NOZZLE",
	emote = "EMOTE",
}

type Card = { frame: Frame, button: TextButton, status: TextLabel, shade: Frame, glow: UIStroke, id: string, tier: number, track: string }
type Tile = { frame: Frame, tag: TextLabel, stroke: UIStroke, id: string }

local state: { [string]: any }? = nil
local requestRemote: RemoteEvent? = nil
local ui: { [string]: any } = {}
local cards: { Card } = {}
local tiles: { Tile } = {}
local columns: { [number]: { circle: Frame, num: TextLabel } } = {}
local tab = "rewards"

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
		local body = frame(box, "Body", UDim2.fromOffset(66 * s, 30 * s), UDim2.fromOffset(7 * s, 22 * s), Palette.TruckRed, math.floor(6 * s))
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

local function celebrateTier(tier: number, ids: { string })
	local layer = ui.fx :: Frame?
	if not layer then
		return
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
	local big = text(card, "Tier", `TIER {tier}`, UDim2.new(1, 0, 0, 74), UDim2.fromOffset(0, 46), UiKit.Header, 72, GOLD, true)
	big.ZIndex = 32
	local names = {}
	for _, id in ids do
		local r = Cfg.Rewards[id]
		if r then
			table.insert(names, r.Name)
		end
	end
	local row = Cfg.Tiers[tier]
	local premiumHint = ""
	if row and owner() then
		local pr = Cfg.Rewards[row.Premium]
		if pr then
			premiumHint = `  |  Premium: {pr.Name}, claim it!`
		end
	end
	local sub = text(card, "Rewards", (if #names > 0 then "Unlocked: " .. table.concat(names, ", ") else "Keep going!") .. premiumHint,
		UDim2.new(1, -24, 0, 56), UDim2.fromOffset(12, 124), UiKit.Body, 19, Palette.UiCream, false)
	sub.ZIndex = 32
	UiKit.pop(card, 0.35)
	confetti(layer, UDim2.fromScale(0.5, 0.52), 44, 0.32)
	task.delay(3.2, function()
		UiKit.tween(card, 0.3, { Position = UDim2.fromScale(0.5, -0.3) }, Enum.EasingStyle.Back, Enum.EasingDirection.In)
		task.delay(0.35, function()
			card:Destroy()
		end)
	end)
end

---------------------------------------------------------------------------------- XP popups

local pending = 0
local pendingReason = ""
local flushToken = 0

local function xpPopup(amount: number, reason: string)
	local pip = ui.pip :: Frame?
	local layer = ui.fx :: Frame?
	if not pip or not layer or not pip.Visible then
		return
	end
	local scale = (ui.gui :: ScreenGui):FindFirstChildOfClass("UIScale")
	local k = if scale then scale.Scale else 1
	local abs = pip.AbsolutePosition - layer.AbsolutePosition
	local holder = Instance.new("Frame")
	holder.BackgroundTransparency = 1
	holder.Size = UDim2.fromOffset(260, 48)
	holder.Position = UDim2.fromOffset(abs.X / k + 4, abs.Y / k + pip.AbsoluteSize.Y / k + 4)
	holder.ZIndex = 20
	holder.Parent = layer
	local main = text(holder, "Main", `+{amount} PASS XP`, UDim2.new(1, 0, 0, 30), UDim2.fromOffset(0, 0), UiKit.Header, 28, Palette.UiShock, true)
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
	UiKit.punch(pip, 0.12)
end

-- many fires out in a burst = one popup with the sum
local function queuePopup(amount: number, reason: string)
	pending += amount
	pendingReason = reason
	flushToken += 1
	local token = flushToken
	task.delay(0.35, function()
		if token == flushToken and pending > 0 then
			xpPopup(pending, pendingReason)
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
		b.Text = `TIER {c.tier}`
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
		dance.Text = if UserInputService.KeyboardEnabled then `DANCE [{Cfg.EmoteKey.Name}]` else "DANCE"
	end
end

local function paintPip(s: { [string]: any }?)
	local pip = ui.pip :: Frame?
	if not pip then
		return
	end
	pip.Visible = s ~= nil -- everyone has the free track
	if not s then
		return
	end
	;(ui.pipTier :: TextLabel).Text = tostring(s.tier)
	local frac = if s.need > 0 then s.into / s.need else 1
	UiKit.tween(ui.pipFill :: Frame, 0.3, { Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1) })
	;(ui.pipText :: TextLabel).Text = if s.need > 0 then `{s.into}/{s.need}` else "MAX"
	local badge = ui.pipBadge :: Frame
	badge.Visible = s.claimable > 0
	;(badge:FindFirstChild("N") :: TextLabel).Text = tostring(s.claimable)
end

local function paint()
	local s = state
	paintPip(s)
	local chipBadge = ui.chipBadge :: Frame?
	if chipBadge and s then
		chipBadge.Visible = s.claimable > 0
		;(chipBadge:FindFirstChild("N") :: TextLabel).Text = tostring(s.claimable)
	end
	if not s or not ui.panel then
		return
	end
	local pass = asPass(s)
	;(ui.tierNum :: TextLabel).Text = tostring(s.tier)
	local frac = if s.need > 0 then s.into / s.need else 1
	UiKit.tween(ui.xpFill :: Frame, 0.35, { Size = UDim2.fromScale(math.clamp(frac, 0.02, 1), 1) })
	;(ui.xpText :: TextLabel).Text = if s.need > 0 then `{s.into} / {s.need} XP` else "MAX TIER!"
	local nextRow = Cfg.Tiers[s.tier + 1]
	local nextText = ui.nextText :: TextLabel
	if nextRow then
		local fr = Cfg.Rewards[nextRow.Free]
		local pr = Cfg.Rewards[nextRow.Premium]
		nextText.Text = `NEXT  TIER {s.tier + 1}:  {fr and fr.Name or "?"}  +  {pr and pr.Name or "?"}`
	else
		nextText.Text = "ALL 20 TIERS DONE. YOU ARE THE FIRE CHIEF!"
	end
	;(ui.boostSmall :: TextLabel).Text = `XP boost +{s.boost or 0}%` .. (if s.premium then `  |  Premium x{Cfg.PremiumXpMultiplier}` else "")
	local all = ui.claimAll :: TextButton
	if s.claimable > 0 then
		all.Text = `CLAIM ALL ({s.claimable})`
		all.BackgroundColor3 = Palette.UiGood
		all.AutoButtonColor = true
	else
		all.Text = "ALL CLAIMED"
		all.BackgroundColor3 = GREY
		all.AutoButtonColor = false
	end
	-- rail fill + tier circles
	local rail = ui.railFill :: Frame
	rail.Size = UDim2.new(0, math.max(0, (s.tier - 0.5 + frac) * COL_W), 1, 0)
	for t, col in columns do
		local reached = t <= s.tier
		col.circle.BackgroundColor3 = if t == s.tier + 1 then Palette.UiWarn elseif reached then Palette.UiFlameMid else DIM
		col.num.TextColor3 = if reached or t == s.tier + 1 then Palette.UiCream else GREY
	end
	for _, c in cards do
		paintCard(c, s, pass)
	end
	paintTiles(s, pass)
end

---------------------------------------------------------------------------------- building

local function buildCard(parent: Instance, tier: number, track: string, id: string, y: number): Card
	local r = Cfg.Rewards[id] or { Slot = "boost", Name = id }
	local f = frame(parent, `{track}{tier}`, UDim2.fromOffset(CARD_W, CARD_H), UDim2.fromOffset((COL_W - CARD_W) / 2, y), if track == "premium" then GOLD_CARD else FREE_CARD, 14)
	f.ZIndex = 2
	local glow = UiKit.stroke(f, 4, Palette.UiGood)
	glow.Enabled = false
	UiKit.stroke(f, 3, Palette.UiInk)
	local ic = icon(f, r, 76)
	ic.Position = UDim2.fromOffset((CARD_W - 76) / 2, 6)
	local name = text(f, "Name", tostring(r.Name), UDim2.new(1, -10, 0, 34), UDim2.fromOffset(5, 82), UiKit.Body, 15, Palette.UiInk, false)
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
	local c: Card = { frame = f, button = b, status = name, shade = shade, glow = glow, id = id, tier = tier, track = track }
	b.Activated:Connect(function()
		local s = state
		if not s then
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
		local ok = PassRules.canClaim(asPass(s), tier, track, s.premium, opts(s))
		if ok then
			sfx("Click")
			request("claim", tier, track)
		else
			UiKit.shake(f, 0.25, 4)
		end
	end)
	return c
end

local function buildTrack(area: Frame)
	local labels = frame(area, "RowLabels", UDim2.fromOffset(104, 404), UDim2.fromOffset(0, 0), Color3.new(), nil)
	labels.BackgroundTransparency = 1
	local freeTag = UiKit.panel(labels, "Free", UDim2.fromOffset(96, CARD_H), UDim2.fromOffset(4, 66))
	text(freeTag, "T", "FREE", UDim2.new(1, 0, 0, 40), UDim2.fromOffset(0, 40), UiKit.Header, 28, Palette.UiInk, false)
	text(freeTag, "S", "for everyone", UDim2.new(1, -6, 0, 40), UDim2.fromOffset(3, 80), UiKit.Body, 15, Palette.CoatShadow, false)
	local premTag = UiKit.panel(labels, "Premium", UDim2.fromOffset(96, CARD_H), UDim2.fromOffset(4, 66 + CARD_H + 12))
	premTag.BackgroundColor3 = GOLD
	text(premTag, "Star", "★", UDim2.new(1, 0, 0, 40), UDim2.fromOffset(0, 14), UiKit.Header, 36, Palette.UiCream, true)
	text(premTag, "T", "PREMIUM", UDim2.new(1, -4, 0, 30), UDim2.fromOffset(2, 60), UiKit.Header, 20, Palette.UiInk, false)
	text(premTag, "S", "pass owners", UDim2.new(1, -6, 0, 30), UDim2.fromOffset(3, 92), UiKit.Body, 15, Palette.UiInk, false)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "Track"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.fromOffset(110, 0)
	scroll.Size = UDim2.new(1, -110, 0, 404)
	scroll.ScrollingDirection = Enum.ScrollingDirection.X
	scroll.ScrollBarThickness = 10
	scroll.ScrollBarImageColor3 = Palette.UiInk
	scroll.CanvasSize = UDim2.fromOffset(COL_W * Cfg.MaxTier + 20, 0)
	scroll.ElasticBehavior = Enum.ElasticBehavior.Always
	scroll.Parent = area
	ui.track = scroll

	local rail = frame(scroll, "Rail", UDim2.fromOffset(COL_W * Cfg.MaxTier, 12), UDim2.fromOffset(0, 24), DIM, 6)
	UiKit.stroke(rail, 2, Palette.UiInk)
	local fill = frame(rail, "Fill", UDim2.new(0, 0, 1, 0), UDim2.fromOffset(0, 0), Palette.UiFlameMid, 6)
	local g = Instance.new("UIGradient")
	g.Color = ColorSequence.new(Palette.UiFlameLow, Palette.UiFlameTop)
	g.Parent = fill
	ui.railFill = fill

	cards = {}
	for t, row in Cfg.Tiers do
		local col = frame(scroll, `Tier{t}`, UDim2.fromOffset(COL_W, 400), UDim2.fromOffset((t - 1) * COL_W, 0), Color3.new(), nil)
		col.BackgroundTransparency = 1
		local circle = frame(col, "Circle", UDim2.fromOffset(54, 54), UDim2.fromOffset((COL_W - 54) / 2, 3), DIM, 27)
		circle.ZIndex = 3
		UiKit.stroke(circle, 3, Palette.UiInk)
		local num = text(circle, "Num", tostring(t), UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, 32, Palette.UiCream, true)
		num.ZIndex = 4
		columns[t] = { circle = circle, num = num }
		table.insert(cards, buildCard(col, t, "free", row.Free, 66))
		table.insert(cards, buildCard(col, t, "premium", row.Premium, 66 + CARD_H + 12))
	end
end

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
	list.Parent = area
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 8)
	layout.Parent = list

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
	tiles = {}
	for i, slot in PassRules.Slots do
		local items = bySlot[slot] or {}
		local row = frame(list, slot, UDim2.new(1, -16, 0, 128), UDim2.fromOffset(0, 0), Color3.new(), nil)
		row.BackgroundTransparency = 1
		row.LayoutOrder = i
		local tag = UiKit.panel(row, "Label", UDim2.fromOffset(100, 116), UDim2.fromOffset(2, 6))
		tag.BackgroundColor3 = Palette.UiFlameMid
		local tl = text(tag, "T", SLOT_LABEL[slot], UDim2.new(1, -8, 0, 60), UDim2.fromOffset(4, 10), UiKit.Header, 22, Palette.UiCream, true)
		tl.TextWrapped = true
		local off = UiKit.button(tag, "Off", "REMOVE", UDim2.fromOffset(86, 30), UDim2.new(0.5, 0, 1, -22), Palette.UiPanelDark)
		off.TextSize = 16
		off.Activated:Connect(function()
			sfx("Click")
			request("unequip", slot)
		end)
		for j, it in items do
			local r = Cfg.Rewards[it.id]
			-- 10 helmets fit across the panel without scrolling sideways: 110 + 10 x 93 px
			local f = frame(row, it.id, UDim2.fromOffset(88, 116), UDim2.fromOffset(110 + (j - 1) * 93, 6), FREE_CARD, 12)
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
			local lockText = text(shade, "Req", (if it.track == "premium" then "★ " else "") .. `TIER {it.tier}`, UDim2.new(1, 0, 0, 24), UDim2.fromOffset(0, 40), UiKit.Header, 17, Palette.UiCream, true)
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
	end
end

local function setTab(name: string)
	tab = name
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
	-- CanvasPosition is in screen pixels; COL_W is in design pixels (the gui's UIScale shrinks them)
	local scale = (ui.gui :: ScreenGui):FindFirstChildOfClass("UIScale")
	local x = math.max(0, (s.tier - 2) * COL_W) * (if scale then scale.Scale else 1)
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

	-- left-edge chip (above the STORE chip)
	local chip = Instance.new("TextButton")
	chip.Name = "PassButton"
	chip.Position = UDim2.new(0, 13, 0.45, 0)
	chip.Size = UDim2.fromOffset(118, 40)
	chip.BackgroundColor3 = Palette.UiFlameMid
	chip.Font = UiKit.Header
	chip.TextSize = 20
	chip.TextColor3 = Palette.UiCream
	chip.Text = if UserInputService.KeyboardEnabled then `[{Cfg.UiToggleKey.Name}] PASS` else "PASS"
	chip.Visible = false
	chip.Parent = g
	UiKit.corner(chip, 10)
	UiKit.stroke(chip, 3, Palette.UiInk)
	local cts = Instance.new("UIStroke")
	cts.Thickness = 2
	cts.Color = Palette.UiInk
	cts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	cts.Parent = chip
	chip.Activated:Connect(toggle)
	ui.chip = chip
	HudLayout.reserve(chip)
	local function badge(parent: Instance, size: number, pos: UDim2): Frame
		local b = frame(parent, "Badge", UDim2.fromOffset(size, size), pos, Palette.UiRed, size)
		b.ZIndex = 8
		UiKit.stroke(b, 2, Palette.UiInk)
		local n = text(b, "N", "0", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, math.floor(size * 0.6), Palette.UiCream, false)
		n.ZIndex = 9
		b.Visible = false
		return b
	end
	ui.chipBadge = badge(chip, 24, UDim2.new(1, -14, 0, -10))

	-- HUD pip
	local pip = UiKit.panel(g, "PassPip", UDim2.fromOffset(196, 36), UDim2.fromOffset(16, 116))
	pip.Visible = false
	local circle = frame(pip, "Tier", UDim2.fromOffset(42, 42), UDim2.fromOffset(-8, -3), GOLD, 21)
	circle.ZIndex = 3
	UiKit.stroke(circle, 3, Palette.UiInk)
	local pt = text(circle, "N", "0", UDim2.fromScale(1, 1), UDim2.fromOffset(0, 1), UiKit.Header, 22, Palette.UiInk, false)
	pt.ZIndex = 4
	ui.pipTier = pt
	local cap = text(pip, "Cap", "PASS", UDim2.fromOffset(60, 16), UDim2.fromOffset(40, 1), UiKit.Header, 14, Palette.UiFlameMid, false)
	cap.TextXAlignment = Enum.TextXAlignment.Left
	local pxt = text(pip, "Xp", "", UDim2.fromOffset(90, 16), UDim2.fromOffset(96, 1), UiKit.Body, 13, Palette.UiInk, false)
	pxt.TextXAlignment = Enum.TextXAlignment.Right
	ui.pipText = pxt
	local bar = frame(pip, "Bar", UDim2.fromOffset(146, 10), UDim2.fromOffset(40, 19), Palette.UiPanelDark, 5)
	UiKit.stroke(bar, 2, Palette.UiInk)
	local bf = frame(bar, "Fill", UDim2.fromScale(0, 1), UDim2.fromOffset(0, 0), Palette.UiShock, 5)
	ui.pipFill = bf
	ui.pipBadge = badge(pip, 20, UDim2.new(1, -10, 0, -10))
	local pipHit = Instance.new("TextButton")
	pipHit.Name = "Open"
	pipHit.BackgroundTransparency = 1
	pipHit.Text = ""
	pipHit.Size = UDim2.fromScale(1, 1)
	pipHit.ZIndex = 10
	pipHit.Parent = pip
	pipHit.Activated:Connect(function()
		if inLobby() then
			toggle()
		end
	end)
	ui.pip = pip
	HudLayout.reserve(pip)

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
	close.Activated:Connect(function()
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
	ui.tierNum = text(tierBadge, "Num", "0", UDim2.new(1, 0, 0, 56), UDim2.fromOffset(0, 32), UiKit.Header, 54, Palette.UiCream, true)
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

-- what the pip hangs under: the lobby level panel (ProfileHud), else the mission objectives card (Hud)
local function anchorPanel(): GuiObject?
	local pg = player:FindFirstChild("PlayerGui")
	for _, path in { { "ProfileHud", "LevelPanel" }, { "Hud", "Objectives" } } do
		local gui = pg and pg:FindFirstChild(path[1])
		local f = gui and gui:FindFirstChild(path[2])
		if f and f:IsA("GuiObject") and f.Visible and (not gui:IsA("ScreenGui") or (gui :: ScreenGui).Enabled) then
			return f
		end
	end
	return nil
end

-- the pip sits under the lobby level panel / the mission objectives card and follows it when it moves
-- (narrow screens); with neither on screen it takes the top-left corner itself
local function placePip()
	local pip = ui.pip :: Frame?
	local g = ui.gui :: ScreenGui?
	if not pip or not g then
		return
	end
	local scale = g:FindFirstChildOfClass("UIScale")
	local k = if scale then scale.Scale else 1
	local lp = anchorPanel()
	if lp then
		-- beside the level panel, up in the top-bar row (under it would cover the objective card)
		local rel = lp.AbsolutePosition - (pip.Parent :: GuiObject).AbsolutePosition
		local x = (rel.X + lp.AbsoluteSize.X) / k + 10
		-- the level panel: centred on it in the top-bar row. The objectives card: level with its top, so
		-- it stays above the top-centre CALL! card (which starts under the mission timer)
		local y = if lp.Name == "Objectives" then rel.Y / k + 4 else (rel.Y + (lp.AbsoluteSize.Y - pip.AbsoluteSize.Y) / 2) / k
		pip.Position = UDim2.fromOffset(x, y)
	else
		pip.Position = UDim2.fromOffset(24, 14)
	end
end

local function syncVisibility()

	local chip = ui.chip :: TextButton?
	if chip then
		chip.Visible = inLobby()
	end
	if not inLobby() then
		setOpen(false)
	end
	paintPip(state)
	placePip()
end

---------------------------------------------------------------------------------- emote fx

local function emoteFx(userId: number, style: string)
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
	pe.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Palette.HelmetRed),
		ColorSequenceKeypoint.new(0.33, GOLD),
		ColorSequenceKeypoint.new(0.66, Palette.UiWater),
		ColorSequenceKeypoint.new(1, Palette.UiGood),
	})
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
	local l = text(bb, "T", if style == "spin" then "VICTORY SPIN!" else "HERO FLEX!", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), UiKit.Header, 34, GOLD, true)
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
		local conn: RBXScriptConnection? = nil
		conn = RunService.RenderStepped:Connect(function(dt)
			if os.clock() - t0 > 0.9 or not root.Parent then
				hum.AutoRotate = true
				if conn then
					conn:Disconnect()
				end
				return
			end
			root.CFrame *= CFrame.Angles(0, dt * math.pi * 4.4, 0)
		end)
		hum.Jump = true
	else
		hum.Jump = true
		root.AssemblyLinearVelocity += Vector3.new(0, 38, 0)
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
				celebrateTier(tier, if type(ids) == "table" then ids else {})
				return 3.7
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
	Net.event("BattlePass", "Fx").OnClientEvent:Connect(function(kind: any, userId: any, style: any)
		if kind == "emote" and type(userId) == "number" then
			emoteFx(userId, if type(style) == "string" then style else "spin")
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
				season.Text = `{s.seasonName or Cfg.SeasonName}   |   ENDS IN {PassRules.countdown(left)}`
			end
		end
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Cfg.UiToggleKey and owner() and (inLobby() or (ui.panel and (ui.panel :: Frame).Visible)) then
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
