--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local okCfg, cfg = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Config", 10):WaitForChild("BattlePassConfig", 10))
end)
if not okCfg or type(cfg) ~= "table" then
	return
end
local okPal, Palette = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Shared", 10):WaitForChild("Palette", 10))
end)
if not okPal then
	return
end

local rn = cfg.Remotes or cfg.RemoteNames or {}
local STATE_NAME = rn.State or rn.PassState or "BattlePassState"
local CLAIM_NAME = rn.Claim or rn.PassClaim or "BattlePassClaim"
local BUY_NAME = rn.Prompt or rn.Buy or rn.PassBuy or "BattlePassPrompt"
local RESULT_NAME = rn.Result or rn.PassResult or "BattlePassResult"

-- Looks for the remote; checks at least once, then retries until timeout. Returns nil (no-op) if missing.
local function findRemote(name: string, timeout: number): RemoteEvent?
	local deadline = os.clock() + timeout
	repeat
		local direct = ReplicatedStorage:FindFirstChild(name)
		if direct and direct:IsA("RemoteEvent") then
			return direct
		end
		for _, d in ipairs(ReplicatedStorage:GetDescendants()) do
			if d:IsA("RemoteEvent") and d.Name == name then
				return d
			end
		end
		if os.clock() < deadline then
			task.wait(0.5)
		end
	until os.clock() >= deadline
	return nil
end

local XP_PER_TIER = tonumber(cfg.XpPerTier) or 100
local MAX_TIER = tonumber(cfg.MaxTier) or 20
local toggleKey = cfg.UiToggleKey or Enum.KeyCode.P

local state = { xp = 0, tier = 0, premium = false, claimed = {} }

-- UI build
local gui = Instance.new("ScreenGui")
gui.Name = "BattlePassGui"
gui.ResetOnSpawn = false
gui.DisplayOrder = 5

local function styled(inst: GuiObject, radius: number, stroke: boolean?)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius)
	c.Parent = inst
	if stroke then
		local s = Instance.new("UIStroke")
		s.Color = Palette.UiInk
		s.Thickness = 2
		s.Parent = inst
	end
end

local function label(parent: Instance, text: string, size: UDim2, pos: UDim2, color: Color3?): TextLabel
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Text = text
	l.TextScaled = true
	l.Font = Enum.Font.FredokaOne
	l.TextColor3 = color or Palette.UiCream
	l.Parent = parent
	return l
end

local passBtn = Instance.new("TextButton")
passBtn.Name = "PassButton"
passBtn.Size = UDim2.fromScale(0.08, 0.06)
passBtn.Position = UDim2.fromScale(0.01, 0.45)
passBtn.BackgroundColor3 = Palette.UiFlameMid
passBtn.Text = "Pass"
passBtn.TextScaled = true
passBtn.Font = Enum.Font.FredokaOne
passBtn.TextColor3 = Palette.UiInk
passBtn.Parent = gui
styled(passBtn, 10, true)

local panel = Instance.new("Frame")
panel.Name = "Panel"
panel.Size = UDim2.fromScale(0.7, 0.55)
panel.Position = UDim2.fromScale(0.15, 0.2)
panel.BackgroundColor3 = Palette.UiPanelDark
panel.Visible = false
panel.Parent = gui
styled(panel, 14, true)

label(panel, "Battle Pass", UDim2.fromScale(0.3, 0.12), UDim2.fromScale(0.02, 0.02), Palette.UiFlameTop)
local tierLabel = label(panel, "Tier 0", UDim2.fromScale(0.18, 0.12), UDim2.fromScale(0.34, 0.02), Palette.UiCream)

local barBack = Instance.new("Frame")
barBack.Size = UDim2.fromScale(0.5, 0.06)
barBack.Position = UDim2.fromScale(0.02, 0.15)
barBack.BackgroundColor3 = Palette.UiInk
barBack.Parent = panel
styled(barBack, 8)
local barFill = Instance.new("Frame")
barFill.Size = UDim2.fromScale(0, 1)
barFill.BackgroundColor3 = Palette.UiWater
barFill.Parent = barBack
styled(barFill, 8)
local xpLabel = label(panel, "0 / " .. XP_PER_TIER, UDim2.fromScale(0.2, 0.06), UDim2.fromScale(0.54, 0.15), Palette.UiCream)
xpLabel.TextXAlignment = Enum.TextXAlignment.Left

local buyBtn = Instance.new("TextButton")
buyBtn.Size = UDim2.fromScale(0.25, 0.1)
buyBtn.Position = UDim2.fromScale(0.72, 0.03)
buyBtn.BackgroundColor3 = Palette.UiWarn
buyBtn.Text = "Get Premium Pass"
buyBtn.TextScaled = true
buyBtn.Font = Enum.Font.FredokaOne
buyBtn.TextColor3 = Palette.UiInk
buyBtn.Parent = panel
styled(buyBtn, 10, true)

local closeBtn = Instance.new("TextButton")
closeBtn.Size = UDim2.fromScale(0.05, 0.08)
closeBtn.Position = UDim2.fromScale(0.94, 0.13)
closeBtn.BackgroundColor3 = Palette.UiRed
closeBtn.Text = "X"
closeBtn.TextScaled = true
closeBtn.Font = Enum.Font.FredokaOne
closeBtn.TextColor3 = Palette.UiCream
closeBtn.Parent = panel
styled(closeBtn, 8, true)

local toast = Instance.new("TextLabel")
toast.Name = "Toast"
toast.Size = UDim2.fromScale(0.4, 0.06)
toast.Position = UDim2.fromScale(0.3, 0.13)
toast.BackgroundColor3 = Palette.UiInk
toast.BackgroundTransparency = 0.15
toast.TextScaled = true
toast.Font = Enum.Font.FredokaOne
toast.TextColor3 = Palette.UiCream
toast.Text = ""
toast.Visible = false
toast.ZIndex = 10
toast.Parent = gui
styled(toast, 8, true)

local scroll = Instance.new("ScrollingFrame")
scroll.Size = UDim2.fromScale(0.96, 0.68)
scroll.Position = UDim2.fromScale(0.02, 0.29)
scroll.BackgroundTransparency = 1
scroll.ScrollBarThickness = 8
scroll.ScrollingDirection = Enum.ScrollingDirection.X
scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
scroll.AutomaticCanvasSize = Enum.AutomaticSize.X
scroll.Parent = panel
local layout = Instance.new("UIListLayout")
layout.FillDirection = Enum.FillDirection.Horizontal
layout.Padding = UDim.new(0, 8)
layout.Parent = scroll

local claimRemote: RemoteEvent? = nil
local buyRemote: RemoteEvent? = nil
local lastFire = 0
local lastBuy = 0
local toastGen = 0

local function showToast(text: string, good: boolean)
	toastGen += 1
	local gen = toastGen
	toast.Text = text
	toast.TextColor3 = good and Palette.UiGood or Palette.UiWarn
	toast.Visible = true
	task.delay(2.5, function()
		if toastGen == gen then
			toast.Visible = false
		end
	end)
end

local function isClaimed(track: string, tier: number): boolean
	local c = state.claimed
	if type(c) ~= "table" then
		return false
	end
	local t = c[track] or c[string.lower(track)]
	if type(t) == "table" and (t[tier] or t[tostring(tier)]) then
		return true
	end
	local e = c[tier] or c[tostring(tier)]
	if type(e) == "table" and e[track] then
		return true
	end
	return c[tostring(tier) .. ":" .. track] == true or c[track .. tostring(tier)] == true
end

local function rewardText(r: any): string
	if type(r) ~= "table" then
		return "-"
	end
	if r.Kind == "XpBoost" then
		return "+" .. tostring(r.Pct or 0) .. "% XP"
	elseif r.Kind == "HelmetTint" then
		return "Helmet " .. tostring(r.Id or "")
	end
	return tostring(r.Id or r.Kind or "?")
end

local function sendClaim(tier: number, track: string)
	if not claimRemote then
		claimRemote = findRemote(CLAIM_NAME, 0)
	end
	if claimRemote and os.clock() - lastFire > 0.3 then
		lastFire = os.clock()
		claimRemote:FireServer(tier, track)
	end
end

local function slot(card: Frame, track: string, tier: number, reward: any, yPos: number, reached: boolean)
	local f = Instance.new("Frame")
	f.Size = UDim2.fromScale(0.92, 0.36)
	f.Position = UDim2.fromScale(0.04, yPos)
	f.BackgroundColor3 = track == "Premium" and Palette.CoatShadow or Palette.RoomTeal
	f.Parent = card
	styled(f, 8)
	if type(reward) == "table" and reward.Kind == "HelmetTint" and typeof(reward.Color) == "Color3" then
		f.BackgroundColor3 = reward.Color
	end
	local locked = track == "Premium" and not state.premium
	local claimed = isClaimed(track, tier)
	label(f, rewardText(reward), UDim2.fromScale(0.94, 0.45), UDim2.fromScale(0.03, 0.04), Palette.UiCream)
	local b = Instance.new("TextButton")
	b.Size = UDim2.fromScale(0.86, 0.38)
	b.Position = UDim2.fromScale(0.07, 0.56)
	b.TextScaled = true
	b.Font = Enum.Font.FredokaOne
	b.Parent = f
	styled(b, 6)
	if claimed then
		b.Text = "Claimed"
		b.BackgroundColor3 = Palette.UiGood
		b.TextColor3 = Palette.UiInk
		b.AutoButtonColor = false
	elseif locked then
		b.Text = "Locked"
		b.BackgroundColor3 = Palette.LockerGrey
		b.TextColor3 = Palette.UiCream
		b.AutoButtonColor = false
	elseif reached then
		b.Text = "Claim"
		b.BackgroundColor3 = Palette.UiWarn
		b.TextColor3 = Palette.UiInk
		b.Activated:Connect(function()
			sendClaim(tier, track)
		end)
	else
		b.Text = "..."
		b.BackgroundColor3 = Palette.UiPanelDark
		b.TextColor3 = Palette.UiCream
		b.AutoButtonColor = false
	end
end

local function render()
	local xp = state.xp
	local tier = math.clamp(state.tier, 0, MAX_TIER)
	tierLabel.Text = "Tier " .. tier
	local frac = tier >= MAX_TIER and 1 or (xp % XP_PER_TIER) / XP_PER_TIER
	TweenService:Create(barFill, TweenInfo.new(0.25), { Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1) }):Play()
	xpLabel.Text = tier >= MAX_TIER and "MAX" or (math.floor(xp % XP_PER_TIER) .. " / " .. XP_PER_TIER)
	buyBtn.Visible = not state.premium

	for _, ch in ipairs(scroll:GetChildren()) do
		if ch:IsA("Frame") then
			ch:Destroy()
		end
	end
	local tiers = type(cfg.Tiers) == "table" and cfg.Tiers or {}
	for i, def in ipairs(tiers) do
		local n = tonumber(def.Tier) or i
		local reached = n <= tier
		local card = Instance.new("Frame")
		card.Name = "Tier" .. n
		card.LayoutOrder = n
		card.Size = UDim2.new(0, 120, 1, -12)
		card.BackgroundColor3 = reached and Palette.UiFlameLow or Palette.UiInk
		card.Parent = scroll
		styled(card, 10, true)
		label(card, "Tier " .. n, UDim2.fromScale(0.9, 0.14), UDim2.fromScale(0.05, 0.01), Palette.UiCream)
		slot(card, "Free", n, def.Free, 0.16, reached)
		slot(card, "Premium", n, def.Premium, 0.55, reached)
	end
end

local function setOpen(open: boolean)
	panel.Visible = open
end

passBtn.Activated:Connect(function()
	setOpen(not panel.Visible)
end)
closeBtn.Activated:Connect(function()
	setOpen(false)
end)
buyBtn.Activated:Connect(function()
	if not buyRemote then
		buyRemote = findRemote(BUY_NAME, 0)
	end
	if not buyRemote then
		showToast("Premium pass unavailable", false)
		return
	end
	if os.clock() - lastBuy > 0.5 then
		lastBuy = os.clock()
		buyRemote:FireServer()
	end
end)
UserInputService.InputBegan:Connect(function(input, processed)
	if processed or UserInputService:GetFocusedTextBox() then
		return
	end
	if input.KeyCode == toggleKey then
		setOpen(not panel.Visible)
	end
end)

local function applyState(s: any)
	if type(s) ~= "table" then
		return
	end
	local xp = tonumber(s.Xp or s.xp or s.XP)
	if xp then
		state.xp = xp
	end
	local t = tonumber(s.Tier or s.tier)
	state.tier = t or math.min(MAX_TIER, math.floor(state.xp / XP_PER_TIER))
	local prem = s.Premium
	if prem == nil then
		prem = s.premium
	end
	if prem == nil then
		prem = s.Owned
	end
	state.premium = prem == true
	state.claimed = s.Claimed or s.claimed or {}
	render()
end

local function applyResult(a: any, b: any)
	local ok = nil
	local msg = nil
	if type(a) == "table" then
		ok = a.Ok
		if ok == nil then
			ok = a.Success
		end
		if ok == nil then
			ok = a.ok
		end
		msg = a.Message or a.Reason or a.Error
	elseif type(a) == "boolean" then
		ok = a
		if type(b) == "string" then
			msg = b
		end
	elseif type(a) == "string" then
		msg = a
	end
	if type(msg) ~= "string" or msg == "" then
		msg = ok and "Reward claimed!" or "Claim failed"
	end
	showToast(msg, ok == true)
end

gui.Parent = player:WaitForChild("PlayerGui", 10) or player:FindFirstChildOfClass("PlayerGui")
render()

task.spawn(function()
	local stateRemote = findRemote(STATE_NAME, 10)
	if stateRemote then
		stateRemote.OnClientEvent:Connect(applyState)
	end
	claimRemote = findRemote(CLAIM_NAME, 5)
	buyRemote = findRemote(BUY_NAME, 5)
	local resultRemote = findRemote(RESULT_NAME, 5)
	if resultRemote then
		resultRemote.OnClientEvent:Connect(applyResult)
	end
end)
