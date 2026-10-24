local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TutorialConfig = require(ReplicatedStorage:WaitForChild("TutorialConfig", 10))
local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 10))

local TutorialFlow = {}

local STUCK_SECONDS = math.max(15, (TutorialConfig :: any).STUCK_RESHOW_SECONDS or 15)
local TUTORIAL_MAX_SECONDS = 60
local SHOP_FALLBACK = (TutorialConfig :: any).SHOP_STEP_FALLBACK_SECONDS or 20
local MAX_STEP = 6

local started = false
local states: { [Player]: any } = {}
local gateCache: { BasePart } = {}
local gateCacheTime = 0
local firstUpgradeId: string? = nil
local firstIdResolved = false

local EXTRA_TEXT = {
	[4] = "Tap the yellow SHOP button to open the shop!",
	[5] = "Buy a tier upgrade from the SHOP or a glowing pad!",
	[6] = "You're a tycoon now! Keep growing your factory!",
}

local function textFor(step: number): string
	if EXTRA_TEXT[step] then
		return EXTRA_TEXT[step]
	end
	local steps = (TutorialConfig :: any).STEPS
	local t = steps and steps[step]
	return if type(t) == "string" then t else ""
end

local function norm(s: any): string
	return string.lower((string.gsub(tostring(s), "[^%w]", "")))
end

local function resolveFirstId()
	if firstIdResolved then
		return
	end
	firstIdResolved = true
	pcall(function()
		local mod = ReplicatedStorage:FindFirstChild("Upgrades")
		if not mod then
			return
		end
		local U: any = require(mod)
		local arrays = { U.list, U.List, U.all, U.All, U }
		for _, arr in arrays do
			if type(arr) == "table" and type(arr[1]) == "table" then
				local e = arr[1]
				local id = e.id or e.Id or e.ID or e.name
				if id ~= nil then
					firstUpgradeId = tostring(id)
					return
				end
			end
		end
	end)
end

local function isDropper2(id: any): boolean
	resolveFirstId()
	if id == nil then
		return false
	end
	if firstUpgradeId and tostring(id) == firstUpgradeId then
		return true
	end
	local n = norm(id)
	return n == "dropper2" or n == "dropper02"
end

local function toPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local OWNER_KEYS = { "OwnerUserId", "OwnerId", "Owner", "OwnerName", "ClaimedBy" }

local function ownedBy(inst: Instance, player: Player): boolean
	for _, k in OWNER_KEYS do
		local v = inst:GetAttribute(k)
		if v ~= nil and (v == player.UserId or v == player.Name) then
			return true
		end
	end
	local ov = inst:FindFirstChild("Owner")
	if ov then
		if ov:IsA("ObjectValue") and ov.Value == player then
			return true
		elseif ov:IsA("StringValue") and ov.Value == player.Name then
			return true
		elseif (ov:IsA("IntValue") or ov:IsA("NumberValue")) and (ov :: any).Value == player.UserId then
			return true
		end
	end
	local pn = player:GetAttribute("PlotName")
	if pn ~= nil and pn == inst.Name then
		return true
	end
	return false
end

local function hasAnyOwner(inst: Instance): boolean
	local cur: Instance? = inst
	for _ = 1, 3 do
		if not cur or cur == workspace then
			break
		end
		for _, k in OWNER_KEYS do
			local v = cur:GetAttribute(k)
			if v ~= nil and v ~= "" and v ~= 0 and v ~= false then
				return true
			end
		end
		cur = cur.Parent
	end
	return false
end

local function findOwnedPlot(player: Player): Instance?
	for _, c in workspace:GetChildren() do
		if c:IsA("Model") or c:IsA("Folder") then
			if ownedBy(c, player) and not c:IsA("Terrain") then
				if c:IsA("Model") or c.Name:lower():find("plot") then
					return c
				end
			end
			if c:IsA("Folder") then
				for _, cc in c:GetChildren() do
					if (cc:IsA("Model") or cc:IsA("Folder")) and ownedBy(cc, player) then
						return cc
					end
				end
			end
		end
	end
	return nil
end

local function findInPlot(plot: Instance, pred: (Instance) -> boolean): BasePart?
	for _, d in plot:GetDescendants() do
		if (d:IsA("BasePart") or d:IsA("Model")) and pred(d) then
			local p = toPart(d)
			if p then
				return p
			end
		end
	end
	return nil
end

local function isCollector(d: Instance): boolean
	return string.find(string.lower(d.Name), "collector", 1, true) ~= nil
end

local function isPad(d: Instance): boolean
	if not d:IsA("BasePart") then
		return false
	end
	local lname = string.lower(d.Name)
	if string.find(lname, "collector", 1, true) then
		return false
	end
	return d:GetAttribute("UpgradeId") ~= nil or string.find(lname, "pad", 1, true) ~= nil
end

local function padIsDropper2(d: Instance): boolean
	local id = d:GetAttribute("UpgradeId")
	if id ~= nil and isDropper2(id) then
		return true
	end
	return norm(d.Name):find("dropper2", 1, true) ~= nil
end

local function visible(p: BasePart): boolean
	return p.Transparency < 0.95
end

local function nearestGate(player: Player): BasePart?
	if os.clock() - gateCacheTime > 3 or #gateCache == 0 then
		gateCache = {}
		gateCacheTime = os.clock()
		for _, d in workspace:GetDescendants() do
			if d:IsA("BasePart") then
				local ln = string.lower(d.Name)
				if d:GetAttribute("ClaimGate") ~= nil or string.find(ln, "gate", 1, true) then
					table.insert(gateCache, d)
				end
			end
		end
	end
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local origin = if root and root:IsA("BasePart") then root.Position else Vector3.zero
	local best, bestD, anyBest, anyD = nil, math.huge, nil, math.huge
	for _, g in gateCache do
		if g.Parent then
			local dist = (g.Position - origin).Magnitude
			if dist < anyD then
				anyBest, anyD = g, dist
			end
			if visible(g) and not hasAnyOwner(g) and dist < bestD then
				best, bestD = g, dist
			end
		end
	end
	return best or anyBest
end

local function computeTarget(player: Player, step: number): BasePart?
	if step == 1 then
		return nearestGate(player)
	end
	local plot = findOwnedPlot(player)
	if not plot then
		return nil
	end
	if step == 2 or step == 4 then
		return findInPlot(plot, isCollector)
	elseif step == 3 then
		local pad = findInPlot(plot, function(d)
			return isPad(d) and padIsDropper2(d)
		end)
		return pad or findInPlot(plot, isCollector)
	elseif step == 5 then
		local pad = findInPlot(plot, function(d)
			return isPad(d) and not padIsDropper2(d) and visible(d :: BasePart)
		end)
		return pad or findInPlot(plot, isCollector)
	end
	return nil
end

local function clearBeam(state)
	if state.beam then
		state.beam:Destroy()
		state.beam = nil
	end
	if state.att0 then
		state.att0:Destroy()
		state.att0 = nil
	end
	if state.att1 then
		state.att1:Destroy()
		state.att1 = nil
	end
	state.beamTarget = nil
end

local function updateBeam(player: Player, state, target: BasePart?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not target or not target:IsDescendantOf(workspace) or not root or not root:IsA("BasePart") then
		clearBeam(state)
		return
	end
	if state.beam and state.beam.Parent and state.beamTarget == target and state.att0 and state.att0.Parent == root then
		return
	end
	clearBeam(state)
	local a0 = Instance.new("Attachment")
	a0.Name = "TutorialBeamStart"
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Name = "TutorialBeamEnd_" .. player.UserId
	a1.Parent = target
	local beam = Instance.new("Beam")
	beam.Name = "TutorialBeam"
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new((TutorialConfig :: any).BEAM_COLOR or Color3.fromRGB(255, 240, 120))
	local w = (TutorialConfig :: any).BEAM_WIDTH or 1
	beam.Width0 = w
	beam.Width1 = w
	beam.LightEmission = 1
	beam.FaceCamera = true
	beam.Transparency = NumberSequence.new(0.1)
	beam.Parent = root
	state.beam, state.att0, state.att1, state.beamTarget = beam, a0, a1, target
end

local function publish(player: Player, state)
	player:SetAttribute("TutorialStep", state.step)
	player:SetAttribute("TutorialText", textFor(state.step))
	state.nonce += 1
	player:SetAttribute("TutorialNonce", state.nonce)
end

local function cashOf(player: Player): number
	local ls = player:FindFirstChild("leaderstats")
	local c = ls and ls:FindFirstChild("Cash")
	if c and (c:IsA("IntValue") or c:IsA("NumberValue")) then
		return (c :: any).Value
	end
	return 0
end

local function advance(player: Player, state)
	if state.step >= MAX_STEP then
		return
	end
	state.step += 1
	state.startTime = os.clock()
	state.lastReshow = state.startTime
	state.baseCash = cashOf(player)
	publish(player, state)
	ForgeTelemetry.count("tutorial_steps", 1)
	if state.step >= MAX_STEP then
		ForgeTelemetry.count("tutorial_done", 1)
		local tv = player:FindFirstChild("TutorialTarget")
		if tv and tv:IsA("ObjectValue") then
			tv.Value = nil
		end
		clearBeam(state)
	end
end

function TutorialFlow.getStep(player: Player): number
	local s = states[player]
	return if s then s.step else 0
end

function TutorialFlow.notify(player: Player, eventName: string, arg: any?)
	local state = states[player]
	if not state or type(eventName) ~= "string" then
		return
	end
	local step = state.step
	if eventName == "claimed" then
		if step == 1 then
			advance(player, state)
		end
	elseif eventName == "cashed_in" then
		if step == 2 then
			advance(player, state)
		end
	elseif eventName == "upgrade_bought" then
		local id = arg
		if type(id) == "table" then
			id = (id :: any).id or (id :: any).Id
		end
		resolveFirstId()
		if step == 3 then
			if isDropper2(id) or firstUpgradeId == nil then
				advance(player, state)
			end
		elseif step == 5 then
			if id ~= nil and not isDropper2(id) then
				advance(player, state)
			end
		end
	elseif eventName == "shop_opened" then
		if step == 4 then
			ForgeTelemetry.count("shop_opened", 1)
			advance(player, state)
		end
	end
end

local function setupPlayer(player: Player)
	if states[player] then
		return
	end
	local state = {
		step = 1,
		startTime = os.clock(),
		lastReshow = os.clock(),
		nonce = 0,
		begin = os.clock(),
		baseCash = 0,
	}
	states[player] = state
	local tv = player:FindFirstChild("TutorialTarget")
	if not tv then
		tv = Instance.new("ObjectValue")
		tv.Name = "TutorialTarget"
		tv.Parent = player
	end
	publish(player, state)
end

local function tick(player: Player, state)
	local step = state.step
	if state.done or step >= MAX_STEP then
		return
	end
	local now = os.clock()
	if now - state.begin >= TUTORIAL_MAX_SECONDS then
		state.done = true
		state.step = MAX_STEP
		publish(player, state)
		ForgeTelemetry.count("tutorial_done", 1)
		local ftv = player:FindFirstChild("TutorialTarget")
		if ftv and ftv:IsA("ObjectValue") then
			ftv.Value = nil
		end
		clearBeam(state)
		return
	end
	if step == 1 and findOwnedPlot(player) then
		advance(player, state)
	elseif step == 2 and cashOf(player) > state.baseCash then
		advance(player, state)
	elseif step == 4 and now - state.startTime >= SHOP_FALLBACK then
		advance(player, state)
	end
	step = state.step
	if step >= MAX_STEP then
		return
	end
	if now - math.max(state.startTime, state.lastReshow) >= STUCK_SECONDS then
		state.lastReshow = now
		publish(player, state)
		ForgeTelemetry.count("tutorial_reshown", 1)
	end
	local target = computeTarget(player, step)
	local tv = player:FindFirstChild("TutorialTarget")
	if tv and tv:IsA("ObjectValue") and tv.Value ~= target then
		tv.Value = target
	end
	updateBeam(player, state, target)
end

function TutorialFlow.start()
	if started then
		return
	end
	started = true

	local remote = ReplicatedStorage:FindFirstChild("ShopOpened")
	if not remote or not remote:IsA("RemoteEvent") then
		remote = Instance.new("RemoteEvent")
		remote.Name = "ShopOpened"
		remote.Parent = ReplicatedStorage
	end
	(remote :: RemoteEvent).OnServerEvent:Connect(function(player: Player)
		if states[player] and states[player].step == 4 then
			TutorialFlow.notify(player, "shop_opened")
		end
	end)

	Players.PlayerAdded:Connect(setupPlayer)
	for _, p in Players:GetPlayers() do
		setupPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		local s = states[player]
		if s then
			clearBeam(s)
		end
		states[player] = nil
	end)

	task.spawn(function()
		while started do
			task.wait(1)
			for player, state in states do
				if player.Parent then
					local ok = pcall(tick, player, state)
					if not ok then
						continue
					end
				end
			end
		end
	end)
end

pcall(TutorialFlow.start)

return TutorialFlow
