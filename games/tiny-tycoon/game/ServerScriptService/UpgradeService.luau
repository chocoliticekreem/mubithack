--!nonstrict
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local Upgrades = require(ReplicatedStorage:WaitForChild("Upgrades"))
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))
local PlotThemes = require(ReplicatedStorage:WaitForChild("PlotThemes"))
local Tycoon = require(ServerScriptService:WaitForChild("Tycoon"))
local CashInService = require(ServerScriptService:WaitForChild("CashInService"))
local JuiceService = require(ServerScriptService:WaitForChild("JuiceService"))
local PadFeedbackService = require(ServerScriptService:WaitForChild("PadFeedbackService"))

local UpgradeService = {}

local NEUTRAL = Color3.fromRGB(120, 120, 135)
local DEBOUNCE = 0.35
local COLS = 6
local SPACING = 8.5
local MAX_VISIBLE = 3

local list: { any } = Upgrades.list or Upgrades
local byId: { [string]: any } = {}
for _, u in ipairs(list) do
	byId[u.id] = u
end

local states: { [Player]: any } = {}
local plots: { [Player]: any } = {}
local boughtRemote: RemoteEvent? = nil

local function ensureRemote(name: string): RemoteEvent
	local existing = ReplicatedStorage:FindFirstChild(name)
	if existing and existing:IsA("RemoteEvent") then
		return existing
	end
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = ReplicatedStorage
	return r
end
local buyRemote: RemoteEvent = ensureRemote("BuyUpgrade")
local shopSync: RemoteEvent = ensureRemote("ShopSync")
local shopCooldown: { [Player]: number } = {}
local SHOP_COOLDOWN = 0.3
local START_GRANT = 5
local startGranted: { [Player]: boolean } = {}

local PlotGrowth: any = nil
do
	local growthModule = ServerScriptService:FindFirstChild("PlotGrowth")
	if growthModule then
		local okReq, res = pcall(require, growthModule)
		if okReq then
			PlotGrowth = res
		end
	end
end

local function growPlot(player: Player, plot: any, owned: { [string]: boolean })
	if PlotGrowth == nil or type(PlotGrowth.apply) ~= "function" or plot == nil then
		return
	end
	local ownedIds: { [string]: boolean } = {}
	for id, v in pairs(owned) do
		if v then
			ownedIds[id] = true
		end
	end
	local target: any = plot
	if typeof(plot) ~= "Instance" then
		target = type(plot) == "table" and plot.model or nil
	end
	if target == nil then
		return
	end
	local ok, err = pcall(PlotGrowth.apply, player, target, ownedIds)
	if not ok then
		warn("[UpgradeService] PlotGrowth.apply failed: " .. tostring(err))
	end
end

local function pickColor(t: any, keys: { string }, default: Color3): Color3
	if type(t) ~= "table" then
		return default
	end
	for _, k in ipairs(keys) do
		if typeof(t[k]) == "Color3" then
			return t[k]
		end
	end
	return default
end

local function num(t: any, keys: { string }, default: number): number
	if type(t) ~= "table" then
		return default
	end
	for _, k in ipairs(keys) do
		if type(t[k]) == "number" then
			return t[k]
		end
	end
	return default
end

local function kindOf(u: any): string
	local e = u.effect
	if type(e) == "table" and type(e.kind) == "string" then
		return string.lower(e.kind)
	end
	return ""
end

local function computeMods(owned: { [string]: boolean })
	local slots, ore, speed, cash = 1, 1, 1, 1
	for id in pairs(owned) do
		local u = byId[id]
		if u then
			local k = kindOf(u)
			local e = u.effect
			if k == "slot" or k == "dropper" then
				slots += 1
			elseif k == "tier" then
				ore = math.max(ore, num(e, { "tier", "ore", "value" }, 1))
			elseif k == "speed" or k == "conveyor" then
				speed *= num(e, { "mult", "value", "speed" }, 1)
			elseif k == "cashmult" or k == "cash" or k == "multiplier" then
				cash = math.max(cash, num(e, { "mult", "value", "cashMult" }, 1))
			end
		end
	end
	return { slots = slots, ore = ore, speedMult = speed, cashMult = cash }
end

local ORE_FALLBACK_NAMES = { "Bronze", "Silver", "Gold", "Platinum", "Diamond" }

-- publishes the player's current modifiers as attributes so the client HUD can read state
local function publishMods(player: Player, owned: { [string]: boolean }, mods: any)
	local oreTier = mods.ore
	local oreName: string? = nil
	for id in pairs(owned) do
		local u = byId[id]
		if u and kindOf(u) == "tier" and type(u.effect) == "table" then
			local e = u.effect
			if num(e, { "tier", "ore", "value" }, 1) == oreTier then
				if type(e.oreName) == "string" then
					oreName = e.oreName
				elseif type(e.name) == "string" then
					oreName = e.name
				end
			end
		end
	end
	if oreName == nil then
		oreName = ORE_FALLBACK_NAMES[oreTier] or ("Tier " .. tostring(oreTier))
	end
	player:SetAttribute("OreName", oreName)
	player:SetAttribute("DropperSlots", mods.slots)
	player:SetAttribute("CashMult", mods.cashMult)
end

local function getCash(player: Player): IntValue?
	local ls = player:FindFirstChild("leaderstats")
	local c = ls and ls:FindFirstChild("Cash")
	if c and (c:IsA("IntValue") or c:IsA("NumberValue")) then
		return c :: any
	end
	return nil
end

local function padVisible(state: any, u: any): boolean
	if state.owned[u.id] then
		return false
	end
	return u.requires == nil or state.owned[u.requires] == true
end

local function refresh(state: any)
	local cash = getCash(state.player)
	local value = cash and cash.Value or 0
	local shown: { [string]: boolean } = {}
	local shownCount = 0
	for _, lu in ipairs(list) do
		if shownCount < MAX_VISIBLE and padVisible(state, lu) then
			shown[lu.id] = true
			shownCount += 1
		end
	end
	for id, pad in pairs(state.pads) do
		local u = byId[id]
		if pad.part.Parent and u then
			local visible = shown[id] == true
			pad.part.Transparency = visible and 0 or 1
			pad.part.CanTouch = visible
			pad.gui.Enabled = visible
			if visible and not pad.fbReg then
				pad.fbReg = true
				PadFeedbackService.Register(pad.part, state.player, u.cost)
			elseif not visible and pad.fbReg then
				pad.fbReg = false
				PadFeedbackService.Unregister(pad.part)
			end
			if pad.cost then
				pad.cost.TextColor3 = (value >= u.cost) and Color3.fromRGB(88, 214, 92) or Color3.fromRGB(240, 68, 64)
			end
			if visible then
				pad.part.Color = (value >= u.cost) and state.accent or NEUTRAL
				if pad.label then
					pad.label.TextColor3 = (value >= u.cost) and Color3.fromRGB(88, 214, 92) or Color3.fromRGB(240, 68, 64)
				end
			end
		end
	end
end

local function sendOwned(player: Player)
	local state = states[player]
	local ids = {}
	if state then
		for id, v in pairs(state.owned) do
			if v then
				table.insert(ids, id)
			end
		end
	end
	shopSync:FireClient(player, ids)
end

-- tells the client HUD which unbought upgrade is the cheapest goal
local function pushNextGoal(state: any)
	local best: any = nil
	for _, u in ipairs(list) do
		if not state.owned[u.id] and (best == nil or u.cost < best.cost) then
			best = u
		end
	end
	if best then
		state.player:SetAttribute("NextGoalName", tostring(best.name))
		state.player:SetAttribute("NextGoalCost", best.cost)
		JuiceService.pushGoal(state.player, tostring(best.name), best.cost)
	else
		state.player:SetAttribute("NextGoalName", "")
		state.player:SetAttribute("NextGoalCost", 0)
		JuiceService.pushGoal(state.player, nil, nil)
	end
end

local function purchase(player: Player, id: string): boolean
	local state = states[player]
	if not state or not plots[player] then
		return false
	end
	local u = byId[id]
	local cash = getCash(state.player)
	if not u or not cash then
		return false
	end
	if state.owned[id] or (u.requires ~= nil and not state.owned[u.requires]) then
		return false
	end
	state.lastBuy = state.lastBuy or {}
	local nowT = os.clock()
	if state.lastBuy[id] and nowT - state.lastBuy[id] < DEBOUNCE then
		return false
	end
	if cash.Value < u.cost then
		JuiceService.onInsufficient(player, u, u.cost - cash.Value)
		local deniedPad = state.pads[id]
		if deniedPad and deniedPad.part then
			PadFeedbackService.Denied(player, deniedPad.part, u.cost)
		end
		return false
	end
	state.lastBuy[id] = nowT
	-- atomic: no yields between check and deduct
	cash.Value -= u.cost
	state.owned[id] = true
	local pad = state.pads[id]
	if pad then
		if pad.fbReg then
			pad.fbReg = false
			PadFeedbackService.Unregister(pad.part)
		end
		pad.part.Transparency = 1
		pad.part.CanTouch = false
		pad.gui.Enabled = false
	end
	local mods = computeMods(state.owned)
	if type(Tycoon.setModifiers) == "function" then
		Tycoon.setModifiers(state.player, mods)
	end
	if pad and pad.part then
		CashInService.purchase(state.player, pad.part.Position)
	end
	Telemetry.count("upgrades_bought", 1)
	if kindOf(u) == "tier" then
		Telemetry.count("tier_upgrades", 1)
	end
	local boughtKind = kindOf(u)
	local lowerId = string.lower(tostring(id))
	if boughtKind == "slot" or boughtKind == "dropper" or string.find(lowerId, "dropper", 1, true) then
		Telemetry.count("dropper_bought", 1)
	elseif boughtKind == "speed" or boughtKind == "conveyor" or string.find(lowerId, "conveyor", 1, true) then
		Telemetry.count("conveyor_bought", 1)
	end
	publishMods(state.player, state.owned, mods)
	if boughtRemote then
		boughtRemote:FireClient(state.player, id, mods)
	end
	refresh(state)
	sendOwned(player)
	JuiceService.onPurchase(player, u, pad and pad.part or nil, nil)
	pushNextGoal(state)
	growPlot(player, plots[player], state.owned)
	return true
end

local function makePad(state: any, u: any, index: number, origin: CFrame, folder: Folder)
	local lx = index <= 5 and 19 or 26
	local lz = (((index - 1) % 5) - 2) * 10
	local part = Instance.new("Part")
	part.Name = "UpgradePad_" .. tostring(u.id)
	part.Size = Vector3.new(4, 0.6, 4)
	part.CFrame = origin * CFrame.new(lx, 1, lz)
	part.Anchored = true
	part.CanCollide = false
	part.Material = Enum.Material.Neon
	part.Color = NEUTRAL
	part.Transparency = 1
	part.CanTouch = false

	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromScale(5, 1.6)
	gui.StudsOffset = Vector3.new(0, 2.5, 0)
	gui.MaxDistance = 35
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Adornee = part
	gui.Enabled = false
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 0.5)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.LuckiestGuy
	label.TextColor3 = Color3.fromRGB(255, 248, 232)
	label.Text = tostring(u.name)
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 3
	stroke.Color = Color3.fromRGB(28, 22, 38)
	stroke.Parent = label
	label.Parent = gui
	local cost = Instance.new("TextLabel")
	cost.Size = UDim2.fromScale(1, 0.5)
	cost.Position = UDim2.fromScale(0, 0.5)
	cost.BackgroundTransparency = 1
	cost.TextScaled = true
	cost.Font = Enum.Font.LuckiestGuy
	cost.TextColor3 = Color3.fromRGB(240, 68, 64)
	cost.Text = string.format("$%d", u.cost)
	local costStroke = Instance.new("UIStroke")
	costStroke.Thickness = 3
	costStroke.Color = Color3.fromRGB(28, 22, 38)
	costStroke.Parent = cost
	cost.Parent = gui
	gui.Parent = part
	part.Parent = folder

	state.pads[u.id] = { part = part, gui = gui, label = label, cost = cost }
	part.Touched:Connect(function(hit)
		local p = Players:GetPlayerFromCharacter(hit.Parent)
		if not p or p ~= state.player or states[p] ~= state then
			return
		end
		local now = os.clock()
		if now - state.lastTouch < DEBOUNCE then
			return
		end
		state.lastTouch = now
		purchase(state.player, u.id)
	end)
end

shopSync.OnServerEvent:Connect(function(player, opened)
	if opened == true then
		Telemetry.count("shop_opened", 1)
	end
	sendOwned(player)
end)

local purchaseOk: BindableEvent
do
	local existingOk = ReplicatedStorage:FindFirstChild("ShopPurchaseOk")
	if existingOk and existingOk:IsA("BindableEvent") then
		purchaseOk = existingOk
	else
		purchaseOk = Instance.new("BindableEvent")
		purchaseOk.Name = "ShopPurchaseOk"
		purchaseOk.Parent = ReplicatedStorage
	end
end

buyRemote.OnServerEvent:Connect(function(player, upgradeId)
	if type(upgradeId) == "string" then
		local now = os.clock()
		local last = shopCooldown[player] or 0
		if now - last >= SHOP_COOLDOWN then
			shopCooldown[player] = now
			if purchase(player, upgradeId) then
				Telemetry.count("shop_purchases", 1)
				purchaseOk:Fire(player, upgradeId)
			end
		end
	end
	sendOwned(player)
end)

local pendingOwned: { [Player]: { string } } = {}

Players.PlayerRemoving:Connect(function(player)
	shopCooldown[player] = nil
	startGranted[player] = nil
	pendingOwned[player] = nil
end)

-- keeps only known ids whose 'requires' prerequisite is also in the valid set
local function validateIds(ids: any): { string }
	local want: { [string]: boolean } = {}
	if type(ids) == "table" then
		for _, id in ipairs(ids) do
			if type(id) == "string" and byId[id] then
				want[id] = true
			end
		end
	end
	local ok: { [string]: boolean } = {}
	local changed = true
	while changed do
		changed = false
		for id in pairs(want) do
			if not ok[id] then
				local req = byId[id].requires
				if req == nil or ok[req] then
					ok[id] = true
					changed = true
				end
			end
		end
	end
	local out = {}
	for id in pairs(ok) do
		table.insert(out, id)
	end
	return out
end

local function applyOwned(state: any, ids: { string })
	for _, id in ipairs(ids) do
		state.owned[id] = true
	end
	local mods = computeMods(state.owned)
	if type(Tycoon.setModifiers) == "function" then
		Tycoon.setModifiers(state.player, mods)
	end
	publishMods(state.player, state.owned, mods)
	refresh(state)
	sendOwned(state.player)
	pushNextGoal(state)
end

-- array of upgrade ids the player currently owns
function UpgradeService.getOwnedIds(player: Player): { string }
	local ids = {}
	local state = states[player]
	if state then
		for id, v in pairs(state.owned) do
			if v then
				table.insert(ids, id)
			end
		end
	else
		local pending = pendingOwned[player]
		if pending then
			for _, id in ipairs(pending) do
				table.insert(ids, id)
			end
		end
	end
	return ids
end

-- marks saved upgrades as owned (no charge, no telemetry); applies now or when the plot is claimed
function UpgradeService.restoreOwned(player: Player, ids: any)
	local valid = validateIds(ids)
	local state = states[player]
	if state and plots[player] then
		pendingOwned[player] = nil
		applyOwned(state, valid)
		growPlot(player, plots[player], state.owned)
	else
		pendingOwned[player] = valid
	end
end

function UpgradeService.init()
	local existing = ReplicatedStorage:FindFirstChild("UpgradeBought")
	if existing and existing:IsA("RemoteEvent") then
		boughtRemote = existing
		return
	end
	local r = Instance.new("RemoteEvent")
	r.Name = "UpgradeBought"
	r.Parent = ReplicatedStorage
	boughtRemote = r
end

function UpgradeService.onPlotClaimed(player: Player, plot: any)
	if states[player] then
		UpgradeService.onPlayerRemoving(player)
	end
	plots[player] = plot
	local theme = plot.theme
	if theme == nil and plot.index ~= nil then
		theme = PlotThemes.getTheme(plot.index)
	end
	local folder = Instance.new("Folder")
	folder.Name = "UpgradePads_" .. player.Name
	local state = {
		player = player,
		owned = {},
		pads = {},
		conns = {},
		folder = folder,
		lastTouch = 0,
		accent = pickColor(theme, { "accent", "Accent", "accentColor" }, Color3.fromRGB(88, 214, 92)),
	}
	states[player] = state
	publishMods(player, state.owned, computeMods(state.owned))
	for i, u in ipairs(list) do
		makePad(state, u, i, plot.origin, folder)
	end
	folder.Parent = workspace
	local pending = pendingOwned[player]
	if pending then
		pendingOwned[player] = nil
		applyOwned(state, pending)
	end
	if not startGranted[player] then
		local startCash = getCash(player)
		if startCash then
			startGranted[player] = true
			if next(state.owned) == nil and startCash.Value < START_GRANT then
				startCash.Value = START_GRANT
			end
		end
	end
	refresh(state)
	sendOwned(player)
	pushNextGoal(state)
	growPlot(player, plot, state.owned)

	local function hookCash(cash: Instance)
		table.insert(state.conns, (cash :: any).Changed:Connect(function()
			refresh(state)
		end))
		refresh(state)
	end
	local cash = getCash(player)
	if cash then
		hookCash(cash)
	else
		task.spawn(function()
			local ls = player:WaitForChild("leaderstats", 10)
			local c = ls and ls:WaitForChild("Cash", 10)
			if c and states[player] == state then
				hookCash(c)
			end
		end)
	end

end

function UpgradeService.onPlayerRemoving(player: Player)
	plots[player] = nil
	local state = states[player]
	if not state then
		return
	end
	states[player] = nil
	for _, c in ipairs(state.conns) do
		c:Disconnect()
	end
	if state.folder then
		state.folder:Destroy()
	end
	for _, p in pairs(state.pads) do
		if p.fbReg then
			p.fbReg = false
			PadFeedbackService.Unregister(p.part)
		end
	end
	state.pads = {}
	state.owned = {}
end

-- true when the player has bought every upgrade id in the tree
function UpgradeService.hasAll(player: Player): boolean
	local state = states[player]
	if not state then
		return false
	end
	for _, u in ipairs(list) do
		if not state.owned[u.id] then
			return false
		end
	end
	return true
end

-- clears bought upgrades and rebuilds the player's buy pads like a fresh claim
function UpgradeService.resetPlayer(player: Player): boolean
	local plot = plots[player]
	if not plot then
		return false
	end
	-- tears down the old state (pads, connections, owned record) and rebuilds fresh pads
	UpgradeService.onPlotClaimed(player, plot)
	publishMods(player, {}, computeMods({}))
	if type(Tycoon.setModifiers) == "function" then
		Tycoon.setModifiers(player, computeMods({}))
	end
	return true
end

return UpgradeService
