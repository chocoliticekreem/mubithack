-- ShopFx: client-only presentation helpers for the shop panel and rows.
-- No gameplay rules here. Purchase requests and telemetry stay on the server side
-- (the server counts shop_opened from the ShopOpened remote and shop_purchases from buys).

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameAssets = require(ReplicatedStorage:WaitForChild("GameAssets", 10))
local UiTheme = require(ReplicatedStorage:WaitForChild("UiTheme", 10))

local ShopFx = {}

local OPEN_SCALE = 0.85
local panelTweens: { [Instance]: { Tween } } = setmetatable({}, { __mode = "k" }) :: any
local rowTweens: { [Instance]: { Tween } } = setmetatable({}, { __mode = "k" }) :: any
local shakeToken: { [Instance]: number } = setmetatable({}, { __mode = "k" }) :: any
local shakeOrigin: { [Instance]: { [GuiObject]: UDim2 } } = setmetatable({}, { __mode = "k" }) :: any

local openedRemote: RemoteEvent? = nil
local remoteLookupRunning = false

local currentToast: TextLabel? = nil
local lastToastAt = 0

local function cancelTweens(store: { [Instance]: { Tween } }, key: Instance)
	local list = store[key]
	if list then
		for _, tw in ipairs(list) do
			pcall(function()
				tw:Cancel()
			end)
		end
	end
	store[key] = {}
end

local function track(store: { [Instance]: { Tween } }, key: Instance, tw: Tween)
	local list = store[key]
	if not list then
		list = {}
		store[key] = list
	end
	table.insert(list, tw)
	tw:Play()
end

-- Tries each candidate sound name (case-insensitive) that exists in GameAssets.Sounds.
local function playAny(names: { string })
	pcall(function()
		local sounds = (GameAssets :: any).Sounds
		if type(sounds) ~= "table" then
			GameAssets.play(names[1])
			return
		end
		local lower: { [string]: string } = {}
		for key, _ in pairs(sounds) do
			if type(key) == "string" then
				lower[string.lower(key)] = key
			end
		end
		for _, name in ipairs(names) do
			local real = lower[string.lower(name)]
			if real then
				GameAssets.play(real)
				return
			end
		end
	end)
end

local function fireOpened()
	if openedRemote then
		pcall(function()
			(openedRemote :: RemoteEvent):FireServer()
		end)
		return
	end
	if remoteLookupRunning then
		return
	end
	remoteLookupRunning = true
	task.spawn(function()
		local ok = pcall(function()
			local remotes = ReplicatedStorage:WaitForChild("Remotes", 10)
			local r = remotes and remotes:WaitForChild("ShopOpened", 5)
			if r and r:IsA("RemoteEvent") then
				openedRemote = r
				r:FireServer()
			end
		end)
		remoteLookupRunning = false
		if not ok then
			openedRemote = nil
		end
	end)
end

local function getScale(panel: GuiObject): UIScale
	local s = panel:FindFirstChildOfClass("UIScale")
	if not s then
		s = Instance.new("UIScale")
		s.Parent = panel
	end
	return s :: UIScale
end

function ShopFx.openPanel(panel: GuiObject?, opts: any?)
	if not panel then
		return
	end
	pcall(function()
		cancelTweens(panelTweens, panel)
		local base = panel:GetAttribute("FxBgT")
		if type(base) ~= "number" then
			base = panel.BackgroundTransparency
			panel:SetAttribute("FxBgT", base)
		end
		local scale = getScale(panel)
		scale.Scale = OPEN_SCALE
		panel.BackgroundTransparency = math.min(1, (base :: number) + 0.5)
		panel.Visible = true
		panel.Active = true
		local info = TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
		track(panelTweens, panel, TweenService:Create(scale, info, { Scale = 1 }))
		track(panelTweens, panel, TweenService:Create(panel, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
			BackgroundTransparency = base :: number,
		}))
	end)
	playAny({ "whoosh", "open", "swoosh", "click" })
	fireOpened()
end

function ShopFx.closePanel(panel: GuiObject?, onDone: (() -> ())?)
	if not panel then
		return
	end
	local ok = pcall(function()
		cancelTweens(panelTweens, panel)
		local scale = getScale(panel)
		local tw = TweenService:Create(scale, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			Scale = OPEN_SCALE,
		})
		tw.Completed:Connect(function()
			if onDone then
				pcall(onDone)
			end
		end)
		track(panelTweens, panel, tw)
	end)
	if not ok and onDone then
		pcall(onDone)
	end
end

local function flashRow(row: GuiObject, color: Color3)
	cancelTweens(rowTweens, row)
	local base = row:GetAttribute("FxBaseColor")
	if typeof(base) ~= "Color3" then
		base = row.BackgroundColor3
		row:SetAttribute("FxBaseColor", base)
	end
	row.BackgroundColor3 = base :: Color3
	local up = TweenService:Create(row, TweenInfo.new(0.1, Enum.EasingStyle.Quad), { BackgroundColor3 = color })
	local down = TweenService:Create(row, TweenInfo.new(0.4, Enum.EasingStyle.Quad), {
		BackgroundColor3 = base :: Color3,
	})
	up.Completed:Connect(function(state)
		if state == Enum.PlaybackState.Completed then
			track(rowTweens, row, down)
		end
	end)
	track(rowTweens, row, up)
end

local function getBar(row: GuiObject): Frame
	local bar = row:FindFirstChild("LevelBar")
	if bar and bar:IsA("Frame") then
		return bar
	end
	local f = Instance.new("Frame")
	f.Name = "LevelBar"
	f.AnchorPoint = Vector2.new(0, 1)
	f.Position = UDim2.new(0, 0, 1, 0)
	f.Size = UDim2.new(0, 0, 0, 6)
	f.BackgroundColor3 = UiTheme.good
	f.BorderSizePixel = 0
	f.ZIndex = row.ZIndex + 2
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 3)
	c.Parent = f
	f.Parent = row
	return f
end

-- Shows a short red message at the top of the ScreenGui that contains `row`.
local function showToast(row: GuiObject, message: string)
	local now = os.clock()
	if now - lastToastAt < 1 and currentToast and currentToast.Parent then
		-- debounce: just update the text of the visible toast
		currentToast.Text = message
		return
	end
	lastToastAt = now
	local gui = row:FindFirstAncestorOfClass("ScreenGui")
	if not gui then
		return
	end
	if currentToast then
		pcall(function()
			(currentToast :: TextLabel):Destroy()
		end)
		currentToast = nil
	end
	local label = Instance.new("TextLabel")
	label.Name = "ShopToast"
	label.AnchorPoint = Vector2.new(0.5, 0)
	label.Position = UDim2.new(0.5, 0, 0, 70)
	label.Size = UDim2.new(0, 320, 0, 40)
	label.BackgroundColor3 = UiTheme.bad
	label.BackgroundTransparency = 0.1
	label.BorderSizePixel = 0
	label.Text = message
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.ZIndex = 100
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = label
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 8)
	pad.PaddingRight = UDim.new(0, 8)
	pad.PaddingTop = UDim.new(0, 6)
	pad.PaddingBottom = UDim.new(0, 6)
	pad.Parent = label
	label.Parent = gui
	currentToast = label
	task.delay(1.6, function()
		if label.Parent then
			pcall(function()
				TweenService:Create(label, TweenInfo.new(0.3), { BackgroundTransparency = 1, TextTransparency = 1 }):Play()
			end)
			task.wait(0.35)
			if label.Parent then
				label:Destroy()
			end
			if currentToast == label then
				currentToast = nil
			end
		end
	end)
end

function ShopFx.buySuccess(row: GuiObject?, level: number?, maxLevel: number?)
	if not row then
		return
	end
	playAny({ "buy", "purchase", "cash", "coin", "collect" })
	pcall(function()
		flashRow(row, UiTheme.good)
	end)
	pcall(function()
		local maxL = math.max(1, tonumber(maxLevel) or 1)
		local frac = math.clamp((tonumber(level) or 0) / maxL, 0, 1)
		local bar = getBar(row)
		TweenService:Create(bar, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = UDim2.new(frac, 0, 0, 6),
		}):Play()
	end)
end

function ShopFx.buyFail(row: GuiObject?, reason: string?)
	if not row then
		return
	end
	playAny({ "error", "deny", "denied", "buzz", "fail", "hurt", "click" })
	pcall(function()
		flashRow(row, UiTheme.bad)
	end)
	pcall(function()
		showToast(row, (type(reason) == "string" and reason ~= "") and reason or "Can't buy that yet")
	end)
	pcall(function()
		-- The row's own Position is controlled by a UIListLayout, so shake its children instead.
		local origins = shakeOrigin[row]
		if not origins then
			origins = {}
			shakeOrigin[row] = origins
		end
		-- restore anything mid-shake
		for obj, pos in pairs(origins) do
			if obj.Parent then
				obj.Position = pos
			end
		end
		for _, child in ipairs(row:GetChildren()) do
			if child:IsA("GuiObject") and origins[child] == nil then
				origins[child] = child.Position
			end
		end
		local token = (shakeToken[row] or 0) + 1
		shakeToken[row] = token
		task.spawn(function()
			local offsets = { 8, -8, 6, -6, 3, -3 }
			for _, dx in ipairs(offsets) do
				if shakeToken[row] ~= token then
					return
				end
				for obj, o in pairs(origins) do
					if obj.Parent then
						pcall(function()
							obj.Position = UDim2.new(o.X.Scale, o.X.Offset + dx, o.Y.Scale, o.Y.Offset)
						end)
					end
				end
				task.wait(0.04)
			end
			if shakeToken[row] == token then
				for obj, o in pairs(origins) do
					if obj.Parent then
						pcall(function()
							obj.Position = o
						end)
					end
				end
			end
		end)
	end)
end

return ShopFx
