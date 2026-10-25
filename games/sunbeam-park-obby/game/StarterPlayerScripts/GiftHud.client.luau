--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local player = Players.LocalPlayer
local Config = require(ReplicatedStorage:WaitForChild("Config"))
local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets"))

-- Remote names come from Config.Remotes when present; fall back to the defaults.
local names = (type(Config.Remotes) == "table" and Config.Remotes) or {}
local stateName = names.GiftState or "GiftState"
local claimName = names.ClaimGift or "ClaimGift"

local GREEN = Color3.fromRGB(70, 210, 90)
local WAIT_COLOR = Color3.fromRGB(255, 160, 60)
local GOLD = Color3.fromRGB(255, 215, 70)
local STROKE_DARK = Color3.fromRGB(60, 40, 20)

local stateRemote = nil
local claimRemote = nil
local stateConnected = false
local stateKnown = false
local arrowShown = false
local fallbackActive = false

-- UI ---------------------------------------------------------------------
local gui = Instance.new("ScreenGui")
gui.Name = "GiftHud"
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = false

local holder = Instance.new("Frame")
holder.Name = "Holder"
holder.BackgroundTransparency = 1
holder.AnchorPoint = Vector2.new(0, 0.5)
holder.Position = UDim2.fromScale(0.015, 0.35)
holder.Size = UDim2.fromScale(0.15, 0.13)
holder.Parent = gui

local button = Instance.new("TextButton")
button.Name = "GiftButton"
button.AutoButtonColor = false
button.AnchorPoint = Vector2.new(0.5, 0)
button.Position = UDim2.fromScale(0.5, 0)
button.Size = UDim2.fromScale(1, 0.72)
button.BackgroundColor3 = WAIT_COLOR
button.Font = Enum.Font.FredokaOne
button.TextColor3 = Color3.new(1, 1, 1)
button.TextScaled = true
button.Text = "🎁 Free Gift"
button.Parent = holder

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0.25, 0)
corner.Parent = button
local stroke = Instance.new("UIStroke")
stroke.Thickness = 3
stroke.Color = STROKE_DARK
stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
stroke.Parent = button
local textStroke = Instance.new("UIStroke")
textStroke.Thickness = 2
textStroke.Color = Color3.fromRGB(40, 30, 20)
textStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
textStroke.Parent = button
local pad = Instance.new("UIPadding")
pad.PaddingLeft = UDim.new(0.06, 0)
pad.PaddingRight = UDim.new(0.06, 0)
pad.PaddingTop = UDim.new(0.1, 0)
pad.PaddingBottom = UDim.new(0.1, 0)
pad.Parent = button
local scale = Instance.new("UIScale")
scale.Parent = button

-- rotating shine gradient (only enabled while ready)
local shine = Instance.new("UIGradient")
shine.Color = ColorSequence.new({
	ColorSequenceKeypoint.new(0, Color3.fromRGB(190, 190, 190)),
	ColorSequenceKeypoint.new(0.5, Color3.new(1, 1, 1)),
	ColorSequenceKeypoint.new(1, Color3.fromRGB(190, 190, 190)),
})
shine.Enabled = false
shine.Parent = button
local shineTween = TweenService:Create(shine, TweenInfo.new(2, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false), {
	Rotation = 360,
})
shineTween:Play()

local streakLabel = Instance.new("TextLabel")
streakLabel.Name = "Streak"
streakLabel.AnchorPoint = Vector2.new(0.5, 1)
streakLabel.Position = UDim2.fromScale(0.5, 1)
streakLabel.Size = UDim2.fromScale(0.7, 0.24)
streakLabel.BackgroundColor3 = Color3.fromRGB(40, 40, 70)
streakLabel.TextColor3 = GOLD
streakLabel.Font = Enum.Font.FredokaOne
streakLabel.TextScaled = true
streakLabel.Text = "Streak: 0"
streakLabel.Parent = holder
local sc = Instance.new("UICorner")
sc.CornerRadius = UDim.new(0.4, 0)
sc.Parent = streakLabel

-- one-time tutorial arrow (shown on first ready)
local arrow = Instance.new("TextLabel")
arrow.Name = "GiftArrow"
arrow.AnchorPoint = Vector2.new(0.5, 1)
arrow.Position = UDim2.fromScale(0.5, -0.02)
arrow.Size = UDim2.fromScale(1.3, 0.4)
arrow.BackgroundTransparency = 1
arrow.Font = Enum.Font.FredokaOne
arrow.TextColor3 = GOLD
arrow.TextScaled = true
arrow.Text = "Claim your free gift! ▼"
arrow.Visible = false
arrow.ZIndex = 25
local arrowStroke = Instance.new("UIStroke")
arrowStroke.Thickness = 2
arrowStroke.Color = STROKE_DARK
arrowStroke.Parent = arrow
arrow.Parent = holder

-- short notice under the gift button (e.g. "Gift unavailable")
local notice = Instance.new("TextLabel")
notice.Name = "Notice"
notice.AnchorPoint = Vector2.new(0.5, 0)
notice.Position = UDim2.fromScale(0.5, 1.04)
notice.Size = UDim2.fromScale(1.2, 0.26)
notice.BackgroundTransparency = 1
notice.Font = Enum.Font.FredokaOne
notice.TextColor3 = Color3.fromRGB(255, 94, 126)
notice.TextScaled = true
notice.Text = ""
notice.TextTransparency = 1
notice.ZIndex = 26
local noticeStroke = Instance.new("UIStroke")
noticeStroke.Thickness = 2
noticeStroke.Color = STROKE_DARK
noticeStroke.Transparency = 1
noticeStroke.Parent = notice
notice.Parent = holder

-- persistent goal pill (top centre)
local goalLabel = Instance.new("TextLabel")
goalLabel.Name = "GoalLabel"
goalLabel.AnchorPoint = Vector2.new(0.5, 0)
goalLabel.Position = UDim2.fromScale(0.5, 0.012)
goalLabel.Size = UDim2.fromScale(0.34, 0.065)
goalLabel.BackgroundColor3 = Color3.fromRGB(40, 40, 70)
goalLabel.BackgroundTransparency = 0.15
goalLabel.Font = Enum.Font.FredokaOne
goalLabel.TextColor3 = Color3.fromRGB(255, 244, 224)
goalLabel.TextScaled = true
goalLabel.Text = "Grab the coins!"
goalLabel.ZIndex = 10
goalLabel.Parent = gui
local goalCorner = Instance.new("UICorner")
goalCorner.CornerRadius = UDim.new(0.5, 0)
goalCorner.Parent = goalLabel
local goalBorder = Instance.new("UIStroke")
goalBorder.Thickness = 3
goalBorder.Color = GOLD
goalBorder.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
goalBorder.Parent = goalLabel
local goalTextStroke = Instance.new("UIStroke")
goalTextStroke.Thickness = 2
goalTextStroke.Color = Color3.fromRGB(40, 30, 20)
goalTextStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
goalTextStroke.Parent = goalLabel
local goalPad = Instance.new("UIPadding")
goalPad.PaddingLeft = UDim.new(0.05, 0)
goalPad.PaddingRight = UDim.new(0.05, 0)
goalPad.PaddingTop = UDim.new(0.12, 0)
goalPad.PaddingBottom = UDim.new(0.12, 0)
goalPad.Parent = goalLabel
local goalScale = Instance.new("UIScale")
goalScale.Parent = goalLabel

gui.Parent = player:WaitForChild("PlayerGui")

-- Bobbing
local bob = TweenService:Create(button, TweenInfo.new(1, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
	Position = UDim2.fromScale(0.5, 0.06),
})
bob:Play()

-- Goal text ----------------------------------------------------------------
local GOAL_TEXTS = {
	"Grab the coins!",
	"Buy the Party Hat!",
	"Climb the START stairs!",
}
local goalStep = 1
local coinsCollected = 0

local function setGoal(step)
	if step == goalStep or not GOAL_TEXTS[step] then
		return
	end
	goalStep = step
	goalLabel.Text = GOAL_TEXTS[step]
	goalScale.Scale = 1.25
	TweenService:Create(goalScale, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function getCoins()
	local attr = player:GetAttribute("Coins")
	if type(attr) ~= "number" then
		attr = player:GetAttribute("coins")
	end
	if type(attr) == "number" then
		return attr
	end
	local ls = player:FindFirstChild("leaderstats")
	if ls then
		for _, v in ipairs(ls:GetChildren()) do
			if (v:IsA("IntValue") or v:IsA("NumberValue")) and string.lower(v.Name) == "coins" then
				return v.Value
			end
		end
	end
	return nil
end

task.spawn(function()
	local last = nil
	while gui.Parent do
		local c = getCoins()
		if c then
			if last ~= nil then
				local delta = c - last
				if delta > 0 and delta <= 15 then
					-- a coin is worth 5; bigger jumps (gift, zone bonus) are not coin pickups
					coinsCollected += math.max(1, math.floor(delta / 5 + 0.5))
					if goalStep == 1 and coinsCollected >= 3 then
						setGoal(2)
					end
				elseif delta < 0 and goalStep == 2 then
					setGoal(3)
				end
			end
			last = c
		end
		task.wait(0.25)
	end
end)

-- State --------------------------------------------------------------------
local ready = false
local endTime = nil
local pending = false
local pulse = nil
local streakValue = 1
local lastShownReady = false
local rewardAmount = (type(Config.GiftReward) == "number" and Config.GiftReward)
	or (type(Config.GiftCoins) == "number" and Config.GiftCoins)
	or 30

local function setPulse(on)
	if on and not pulse then
		pulse = TweenService:Create(scale, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, -1, true), { Scale = 1.12 })
		pulse:Play()
	elseif not on and pulse then
		pulse:Cancel()
		pulse = nil
		scale.Scale = 1
	end
end

local function fmt(sec)
	sec = math.max(0, math.ceil(sec))
	return string.format("%d:%02d", sec // 60, sec % 60)
end

local noticeToken = 0
local function showNotice(text)
	noticeToken += 1
	local token = noticeToken
	notice.Text = text
	notice.TextTransparency = 0
	noticeStroke.Transparency = 0
	task.delay(1.6, function()
		if token ~= noticeToken then
			return
		end
		local info = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		TweenService:Create(notice, info, { TextTransparency = 1 }):Play()
		TweenService:Create(noticeStroke, info, { Transparency = 1 }):Play()
	end)
end

local function wiggle()
	button.Rotation = -8
	TweenService:Create(button, TweenInfo.new(0.08, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, 5, true), {
		Rotation = 8,
	}):Play()
	task.delay(1.0, function()
		button.Rotation = 0
	end)
end

local function showArrow()
	if arrowShown then
		return
	end
	arrowShown = true
	arrow.Visible = true
	local arrowBob = TweenService:Create(arrow, TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		Position = UDim2.fromScale(0.5, -0.08),
	})
	arrowBob:Play()
	task.delay(6, function()
		arrowBob:Cancel()
		arrow.Visible = false
	end)
end

local function render()
	local isReady = ready or (endTime ~= nil and os.clock() >= endTime)
	if isReady then
		button.Text = "🎁 FREE GIFT! Claim"
		button.BackgroundColor3 = GREEN
		shine.Enabled = true
		setPulse(true)
		if not lastShownReady then
			lastShownReady = true
			if stateKnown then
				pcall(GameAssets.play, "Gem")
				wiggle()
				showArrow()
			end
		end
	else
		lastShownReady = false
		shine.Enabled = false
		if endTime then
			button.Text = "🎁 Free Gift " .. fmt(endTime - os.clock())
		else
			button.Text = "🎁 Free Gift"
		end
		button.BackgroundColor3 = WAIT_COLOR
		setPulse(false)
	end
end

-- 12 small gold sparkles that tween upward from the button and fade out
local function sparkle()
	local abs, size = button.AbsolutePosition, button.AbsoluteSize
	local cx, cy = abs.X + size.X / 2, abs.Y + size.Y / 2
	for i = 1, 12 do
		local f = Instance.new("Frame")
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.BackgroundColor3 = GOLD
		f.BorderSizePixel = 0
		f.Size = UDim2.fromOffset(10, 10)
		f.Rotation = math.random(0, 90)
		local startX = cx + (math.random() - 0.5) * size.X * 0.8
		local startY = cy + 36
		f.Position = UDim2.fromOffset(startX, startY)
		f.ZIndex = 20
		local c = Instance.new("UICorner")
		c.CornerRadius = UDim.new(0.3, 0)
		c.Parent = f
		f.Parent = gui
		local driftX = (math.random() - 0.5) * 120
		local rise = math.random(80, 160)
		local tw = TweenService:Create(f, TweenInfo.new(0.7 + math.random() * 0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Position = UDim2.fromOffset(startX + driftX, startY - rise),
			BackgroundTransparency = 1,
			Size = UDim2.fromOffset(4, 4),
			Rotation = f.Rotation + 180,
		})
		tw:Play()
		tw.Completed:Once(function()
			f:Destroy()
		end)
	end
end

local function goldFlash()
	stroke.Color = GOLD
	stroke.Thickness = 9
	TweenService:Create(stroke, TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Color = STROKE_DARK,
		Thickness = 3,
	}):Play()
end

local function rewardPopup()
	local abs, size = button.AbsolutePosition, button.AbsoluteSize
	local cx = abs.X + size.X / 2
	local cy = abs.Y + size.Y / 2
	local label = Instance.new("TextLabel")
	label.Name = "RewardPopup"
	label.AnchorPoint = Vector2.new(0, 0.5)
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromOffset(340, 50)
	label.Position = UDim2.fromOffset(cx + size.X / 2 + 10, cy)
	label.Font = Enum.Font.FredokaOne
	label.TextColor3 = GOLD
	label.TextScaled = true
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.Text = "+" .. tostring(rewardAmount) .. " coins, streak x" .. tostring(streakValue)
	label.ZIndex = 30
	local st = Instance.new("UIStroke")
	st.Thickness = 3
	st.Color = STROKE_DARK
	st.Parent = label
	label.Parent = gui

	local info = TweenInfo.new(1.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
	TweenService:Create(label, info, {
		Position = UDim2.fromOffset(cx + size.X / 2 + 10, cy - 80),
	}):Play()
	local fade = TweenInfo.new(1.5, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
	TweenService:Create(label, fade, { TextTransparency = 1 }):Play()
	local fadeStroke = TweenService:Create(st, fade, { Transparency = 1 })
	fadeStroke:Play()
	fadeStroke.Completed:Once(function()
		label:Destroy()
	end)
end

local function celebrate()
	pcall(GameAssets.play, "Gem")
	goldFlash()
	sparkle()
	rewardPopup()
	arrow.Visible = false
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if root and GameAssets.burst then
		pcall(GameAssets.burst, root)
	end
	if GameAssets.shake then
		pcall(GameAssets.shake)
	end
	scale.Scale = 1.3
	TweenService:Create(scale, TweenInfo.new(0.4, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Scale = 1 }):Play()
end

local function num(v)
	return type(v) == "number" and v or nil
end

local function onState(a, b, c)
	stateKnown = true
	fallbackActive = false
	local rem, streak
	local isReady = nil
	if type(a) == "table" then
		isReady = a.ready
		if isReady == nil then
			isReady = a.Ready
		end
		rem = num(a.remaining) or num(a.seconds) or num(a.timeLeft) or num(a.secondsLeft) or num(a.cooldown)
		if num(a.nextAt) then
			rem = a.nextAt - os.time()
		end
		streak = num(a.streak) or num(a.Streak)
		local amt = num(a.reward) or num(a.amount) or num(a.coins) or num(a.lastReward)
		if amt then
			rewardAmount = math.floor(amt)
		end
	elseif type(a) == "boolean" then
		isReady = a
		rem = num(b)
		streak = num(c)
	elseif type(a) == "number" then
		rem = a
		streak = num(b)
	end
	if rem then
		endTime = os.clock() + rem
	end
	if isReady == nil then
		isReady = rem ~= nil and rem <= 0
	end
	ready = isReady and true or false
	if ready then
		endTime = os.clock()
	end
	if streak then
		streakValue = math.floor(streak)
		streakLabel.Text = "Streak: " .. tostring(streakValue)
	end
	if pending and not ready then
		pending = false
		celebrate()
	end
	render()
end

local function fireClaim()
	if not claimRemote then
		return
	end
	if claimRemote:IsA("RemoteFunction") then
		task.spawn(function()
			local ok = pcall(function()
				return claimRemote:InvokeServer()
			end)
			if ok and pending then
				-- state event (if any) will celebrate; otherwise celebrate after short wait
				task.wait(0.5)
				if pending then
					pending = false
					celebrate()
				end
			end
		end)
	else
		pcall(function()
			claimRemote:FireServer()
		end)
	end
end

-- Ask the server for the current state (it may have sent it before we connected).
local function requestSync()
	if stateRemote and stateRemote:IsA("RemoteEvent") then
		pcall(function()
			stateRemote:FireServer("sync")
		end)
	end
	if claimRemote then
		if claimRemote:IsA("RemoteFunction") then
			task.spawn(function()
				local ok, res = pcall(function()
					return claimRemote:InvokeServer("sync")
				end)
				if ok and res ~= nil and not stateKnown then
					onState(res)
				end
			end)
		else
			pcall(function()
				claimRemote:FireServer("sync")
			end)
		end
	end
end

button.Activated:Connect(function()
	if pending then
		return
	end
	if not claimRemote then
		TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true), { Scale = 0.9 }):Play()
		pcall(GameAssets.play, "Error")
		showNotice(fallbackActive and "Gift unavailable" or "Gift loading...")
		return
	end
	local isReady = ready or (endTime ~= nil and os.clock() >= endTime)
	-- If the server never told us the state, still let the server decide.
	local canTry = isReady or not stateKnown
	if not canTry then
		TweenService:Create(scale, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out, 0, true), { Scale = 0.9 }):Play()
		pcall(GameAssets.play, "Click")
		return
	end
	pending = true
	fireClaim()
	task.delay(3, function()
		pending = false
	end)
end)

task.spawn(function()
	while gui.Parent do
		render()
		task.wait(0.25)
	end
end)
render()

-- Remote discovery ---------------------------------------------------------
local function isEventLike(inst)
	return inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent")
end

-- Connect OnClientEvent as soon as the state remote is known.
local function connectState()
	if stateRemote and not stateConnected then
		stateConnected = true
		stateRemote.OnClientEvent:Connect(onState)
		-- ask right away; the server may already have sent its state
		task.defer(function()
			if not stateKnown then
				requestSync()
			end
		end)
	end
end

local function consider(inst)
	if not (isEventLike(inst) or inst:IsA("RemoteFunction")) then
		return
	end
	local n = string.lower(inst.Name)
	local stateLower = string.lower(stateName)
	local claimLower = string.lower(claimName)

	if not stateRemote and isEventLike(inst) then
		if n == stateLower or n == "giftstate" or (string.find(n, "gift", 1, true) and string.find(n, "state", 1, true)) then
			stateRemote = inst
		end
	end
	if not claimRemote then
		if n == claimLower or n == "claimgift" or (string.find(n, "claim", 1, true) and string.find(n, "gift", 1, true)) then
			claimRemote = inst
		end
	end
	connectState()
end

local function scanAll()
	for _, inst in ipairs(ReplicatedStorage:GetDescendants()) do
		consider(inst)
		if stateRemote and claimRemote then
			break
		end
	end
end

-- recursive lookup anywhere under ReplicatedStorage
local function tryExact()
	if not stateRemote then
		local s = ReplicatedStorage:FindFirstChild(stateName, true)
		if s and isEventLike(s) then
			stateRemote = s
		end
	end
	if not claimRemote then
		local c = ReplicatedStorage:FindFirstChild(claimName, true)
		if c and (isEventLike(c) or c:IsA("RemoteFunction")) then
			claimRemote = c
		end
	end
	connectState()
end

ReplicatedStorage.DescendantAdded:Connect(function(inst)
	consider(inst)
	-- Name may be set right after parenting; re-check shortly.
	if (inst:IsA("RemoteEvent") or inst:IsA("UnreliableRemoteEvent") or inst:IsA("RemoteFunction"))
		and not (stateRemote and claimRemote) then
		task.defer(consider, inst)
	end
end)

-- Local countdown so the button still shows a timer when remotes never show up.
local function startFallback()
	if stateKnown or claimRemote then
		return
	end
	fallbackActive = true
	if endTime == nil then
		local interval = (type(Config.GiftInterval) == "number" and Config.GiftInterval)
			or (type(Config.GiftCooldown) == "number" and Config.GiftCooldown)
			or 180
		endTime = os.clock() + interval
	end
	render()
end

task.spawn(function()
	local startT = os.clock()
	local warned = false
	while not (stateRemote and claimRemote) and gui.Parent do
		tryExact()
		scanAll()
		if stateRemote and claimRemote then
			break
		end
		if not warned and os.clock() - startT > 10 then
			warned = true
			warn(string.format(
				"[GiftHud] gift remotes missing after 10s (looked for '%s' and '%s' anywhere under ReplicatedStorage); using a local countdown and still watching for them",
				stateName, claimName
			))
			startFallback()
		end
		task.wait(warned and 2 or 0.5)
	end

	-- Found: ask the server for the current state until we hear back.
	local tries = 0
	while not stateKnown and tries < 15 and gui.Parent do
		requestSync()
		tries += 1
		task.wait(2)
	end
end)

tryExact()
scanAll()
