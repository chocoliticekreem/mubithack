--!strict
-- PadFeedbackFx: client-only presentation for buy pad affordability and denied-buy feedback.
-- Sends nothing to the server. ForgeTelemetry is a no-op on the client, so the
-- 'highlights' and 'pad_denied' counters are bumped by the server-side owner of these events.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local SoundService = game:GetService("SoundService")

local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets", 10) :: ModuleScript) :: any
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme", 10) :: ModuleScript)

local player = Players.LocalPlayer
local GOOD = UiTheme.good
local BAD = UiTheme.bad

type State = {
	inst: Instance,
	part: BasePart,
	origColor: Color3,
	origMaterial: Enum.Material,
	highlight: Highlight?,
	label: TextLabel?,
	origTextColor: Color3?,
	origLabelSize: UDim2?,
	active: boolean,
	tweens: { Tween },
	flashToken: number,
}

local states: { [Instance]: State } = {}

local function resolvePart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function findLabel(inst: Instance, part: BasePart): TextLabel?
	local roots: { Instance } = { inst, part }
	if inst.Parent and inst.Parent ~= workspace then
		table.insert(roots, inst.Parent)
	end
	for _, root in ipairs(roots) do
		for _, d in ipairs(root:GetDescendants()) do
			if d:IsA("TextLabel") and d:FindFirstAncestorOfClass("BillboardGui") then
				return d
			end
		end
	end
	return nil
end

local function getState(inst: Instance): State?
	local existing = states[inst]
	if existing then
		return existing
	end
	local part = resolvePart(inst)
	if not part then
		return nil
	end
	local hl = part:FindFirstChild("AffordHighlight")
	if not (hl and hl:IsA("Highlight")) then
		local h = Instance.new("Highlight")
		h.Name = "AffordHighlight"
		h.FillColor = GOOD
		h.OutlineColor = GOOD
		h.FillTransparency = 1
		h.OutlineTransparency = 1
		h.Adornee = part
		h.Parent = part
		hl = h
	end
	local label = findLabel(inst, part)
	local st: State = {
		inst = inst,
		part = part,
		origColor = part.Color,
		origMaterial = part.Material,
		highlight = hl :: Highlight,
		label = label,
		origTextColor = if label then label.TextColor3 else nil,
		origLabelSize = if label then label.Size else nil,
		active = false,
		tweens = {},
		flashToken = 0,
	}
	states[inst] = st
	return st
end

local function cancelTweens(st: State)
	for _, t in ipairs(st.tweens) do
		t:Cancel()
	end
	table.clear(st.tweens)
end

local function play(st: State, obj: Instance, info: TweenInfo, goal: { [string]: any })
	local t = TweenService:Create(obj, info, goal)
	table.insert(st.tweens, t)
	t:Play()
end

local function restore(st: State)
	cancelTweens(st)
	if st.part.Parent then
		st.part.Color = st.origColor
		st.part.Material = st.origMaterial
	end
	if st.highlight then
		st.highlight.FillTransparency = 1
		st.highlight.OutlineTransparency = 1
	end
	if st.label then
		if st.origTextColor then
			st.label.TextColor3 = st.origTextColor
		end
		if st.origLabelSize then
			st.label.Size = st.origLabelSize
		end
	end
end

local function stopPulse(st: State)
	if not st.active then
		return
	end
	st.active = false
	restore(st)
end

local function startPulse(st: State)
	if st.active then
		return
	end
	st.active = true
	st.part.Material = Enum.Material.Neon
	if st.label then
		st.label.TextColor3 = GOOD
	end
	if st.highlight then
		st.highlight.FillColor = GOOD
		st.highlight.OutlineColor = GOOD
		st.highlight.OutlineTransparency = 0.2
	end
	task.spawn(function()
		local info = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
		local bright = st.origColor:Lerp(GOOD, 0.8)
		local dim = st.origColor:Lerp(GOOD, 0.25)
		local big = st.origLabelSize
		local grown = if big then UDim2.new(big.X.Scale * 1.1, big.X.Offset, big.Y.Scale * 1.1, big.Y.Offset) else nil
		while st.active and st.part.Parent do
			cancelTweens(st)
			play(st, st.part, info, { Color = bright })
			if st.highlight then
				play(st, st.highlight, info, { FillTransparency = 0.3 })
			end
			if st.label and grown then
				play(st, st.label, info, { Size = grown })
			end
			task.wait(0.5)
			if not st.active then
				break
			end
			cancelTweens(st)
			play(st, st.part, info, { Color = dim })
			if st.highlight then
				play(st, st.highlight, info, { FillTransparency = 0.7 })
			end
			if st.label and big then
				play(st, st.label, info, { Size = big })
			end
			task.wait(0.5)
		end
	end)
end

local function applyAffordable(inst: Instance)
	local st = getState(inst)
	if not st then
		return
	end
	if inst:GetAttribute("Affordable") == true then
		startPulse(st)
	else
		stopPulse(st)
	end
end

local watched: { [Instance]: boolean } = {}

local function watch(inst: Instance)
	if watched[inst] then
		return
	end
	if not (inst:IsA("BasePart") or inst:IsA("Model")) then
		return
	end
	if inst:GetAttribute("Affordable") == nil then
		return
	end
	watched[inst] = true
	inst:GetAttributeChangedSignal("Affordable"):Connect(function()
		applyAffordable(inst)
	end)
	inst.Destroying:Connect(function()
		watched[inst] = nil
		local st = states[inst]
		if st then
			st.active = false
			cancelTweens(st)
			states[inst] = nil
		end
	end)
	applyAffordable(inst)
end

-- Toast
local toastLabel: TextLabel? = nil
local toastToken = 0

local function ensureToast(): TextLabel?
	if toastLabel and toastLabel.Parent then
		return toastLabel
	end
	local pg = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
	if not pg then
		return nil
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "PadFeedbackToast"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	local l = Instance.new("TextLabel")
	l.AnchorPoint = Vector2.new(0.5, 0.5)
	l.Position = UDim2.fromScale(0.5, 0.22)
	l.Size = UDim2.fromScale(0.28, 0.08)
	l.BackgroundColor3 = UiTheme.cream
	l.TextColor3 = BAD
	l.Font = UiTheme.headerFont
	l.TextScaled = true
	l.Text = ""
	l.Visible = false
	UiTheme.roundify(l, UiTheme.cornerRadius)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = UiTheme.stroke
	stroke.Color = UiTheme.ink
	stroke.Parent = l
	l.Parent = gui
	gui.Parent = pg
	toastLabel = l
	return l
end

local function showToast(text: string)
	local l = ensureToast()
	if not l then
		return
	end
	toastToken += 1
	local my = toastToken
	l.Text = text
	l.Visible = true
	l.Size = UDim2.fromScale(0.2, 0.05)
	TweenService:Create(l, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
		Size = UDim2.fromScale(0.28, 0.08),
	}):Play()
	task.delay(1.4, function()
		if toastToken == my and l.Parent then
			l.Visible = false
		end
	end)
end

local function playBuzz()
	local candidates = { "error", "deny", "denied", "buzz", "fail", "wrong", "nope" }
	local sounds = GameAssets.Sounds
	if typeof(sounds) ~= "table" then
		return
	end
	for _, name in ipairs(candidates) do
		if (sounds :: any)[name] ~= nil then
			pcall(function()
				GameAssets.play(name, SoundService)
			end)
			return
		end
	end
end

local function flashRed(st: State)
	st.flashToken += 1
	local my = st.flashToken
	local wasActive = st.active
	if wasActive then
		stopPulse(st)
	end
	st.part.Material = Enum.Material.Neon
	st.part.Color = BAD
	task.delay(0.4, function()
		if st.flashToken == my and st.part.Parent and not st.active then
			st.part.Color = st.origColor
			st.part.Material = st.origMaterial
		end
	end)
end

local function findStateFor(obj: Instance?): State?
	local cur = obj
	while cur and cur ~= workspace do
		local st = states[cur]
		if st then
			return st
		end
		cur = cur.Parent
	end
	if obj then
		return getState(obj)
	end
	return nil
end

local function onDenied(pad: any, need: any)
	if typeof(pad) == "Instance" then
		local st = findStateFor(pad)
		if st then
			flashRed(st)
		end
		if typeof(need) ~= "number" then
			local c = pad:GetAttribute("Cost")
			if typeof(c) == "number" then
				need = c
			end
		end
	end
	playBuzz()
	if typeof(need) == "number" then
		showToast("Need $" .. tostring(math.floor(need)))
	else
		showToast("Not enough cash!")
	end
end

-- Hook up
for _, d in ipairs(workspace:GetDescendants()) do
	watch(d)
end
workspace.DescendantAdded:Connect(function(d)
	-- attributes are usually set before parenting; defer so late setters are caught too
	task.defer(watch, d)
end)

task.spawn(function()
	local remote = ReplicatedStorage:WaitForChild("PadFeedback", 10)
	if not remote or not remote:IsA("RemoteEvent") then
		return
	end
	remote.OnClientEvent:Connect(function(kind: any, pad: any, need: any)
		if kind == "denied" then
			onDenied(pad, need)
		end
	end)
end)
