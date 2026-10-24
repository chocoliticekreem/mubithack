--!strict
-- PadFeedbackService: affordability glow + denied feedback for buy pads. Never touches Cash or purchase rules.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local TweenService = game:GetService("TweenService")

local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry"))

local GREEN = Color3.fromRGB(70, 255, 120)
local RED = Color3.fromRGB(255, 60, 60)
local DENY_DEBOUNCE = 1
local CHECK_INTERVAL = 0.5

type Entry = {
	owner: Player,
	cost: number,
	highlight: Highlight?,
	tween: Tween?,
	active: boolean,
	ancestryConn: RBXScriptConnection?,
	tagOrig: { [TextLabel]: Color3 },
	flashing: boolean,
}

local PadFeedback = {}

local entries: { [BasePart]: Entry } = {}
local cashConns: { [Player]: RBXScriptConnection } = {}
local deniedAt: { [Player]: { [BasePart]: number } } = {}
local remote: RemoteEvent
local affordableEvent: BindableEvent

local function getCash(player: Player): number?
	local ls = player:FindFirstChild("leaderstats")
	if not ls then
		return nil
	end
	local cash = ls:FindFirstChild("Cash")
	if cash and (cash:IsA("IntValue") or cash:IsA("NumberValue")) then
		return cash.Value
	end
	return nil
end

local function tagLabels(pad: BasePart): { TextLabel }
	local out = {}
	local roots: { Instance } = { pad }
	if pad.Parent and pad.Parent:IsA("Model") then
		table.insert(roots, pad.Parent)
	end
	for _, root in roots do
		for _, d in root:GetDescendants() do
			if d:IsA("TextLabel") and d:FindFirstAncestorWhichIsA("BillboardGui") then
				table.insert(out, d)
			end
		end
		if #out > 0 then
			break
		end
	end
	return out
end

local function deactivate(pad: BasePart, e: Entry)
	if e.tween then
		e.tween:Cancel()
		e.tween = nil
	end
	if e.highlight then
		e.highlight:Destroy()
		e.highlight = nil
	end
	for label, col in e.tagOrig do
		if label.Parent then
			label.TextColor3 = col
		end
	end
	e.tagOrig = {}
	e.active = false
	if pad.Parent then
		pad:SetAttribute("Affordable", false)
	end
end

local function activate(pad: BasePart, e: Entry)
	e.active = true
	pad:SetAttribute("Affordable", true)
	local h = Instance.new("Highlight")
	h.Name = "AffordHighlight"
	h.FillColor = GREEN
	h.FillTransparency = 0.6
	h.OutlineColor = Color3.new(1, 1, 1)
	h.OutlineTransparency = 0
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Adornee = pad
	h.Enabled = true
	h.Parent = pad
	e.highlight = h
	local tw = TweenService:Create(h, TweenInfo.new(0.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
		FillTransparency = 0.85,
	})
	tw:Play()
	e.tween = tw
	for _, label in tagLabels(pad) do
		e.tagOrig[label] = label.TextColor3
		label.TextColor3 = GREEN
	end
	Telemetry.count("highlights", 1)
	-- hook for tests / auto-buy paths: server-only, never changes cash itself
	if affordableEvent then
		affordableEvent:Fire(pad, e.owner, e.cost)
	end
end

local function refresh(pad: BasePart)
	local e = entries[pad]
	if not e then
		return
	end
	local cash = getCash(e.owner)
	local affordable = cash ~= nil and cash >= e.cost
	if affordable and not e.active then
		activate(pad, e)
	elseif not affordable and e.active then
		deactivate(pad, e)
	end
end

local function watchCash(player: Player)
	if cashConns[player] then
		return
	end
	local ls = player:FindFirstChild("leaderstats")
	local cash = ls and ls:FindFirstChild("Cash")
	if cash and cash:IsA("ValueBase") then
		cashConns[player] = (cash :: any).Changed:Connect(function()
			for pad, e in entries do
				if e.owner == player then
					refresh(pad)
				end
			end
		end)
	end
end

function PadFeedback.GetAffordablePads(player: Player): { BasePart }
	local out: { BasePart } = {}
	for pad, e in entries do
		if e.owner == player and e.active and pad.Parent then
			table.insert(out, pad)
		end
	end
	return out
end

function PadFeedback.Unregister(pad: BasePart)
	local e = entries[pad]
	if not e then
		return
	end
	entries[pad] = nil
	if e.ancestryConn then
		e.ancestryConn:Disconnect()
	end
	deactivate(pad, e)
end

function PadFeedback.Register(pad: BasePart, owner: Player, cost: number)
	if typeof(pad) ~= "Instance" or not pad:IsA("BasePart") then
		return
	end
	if typeof(owner) ~= "Instance" or not owner:IsA("Player") or type(cost) ~= "number" then
		return
	end
	local e = entries[pad]
	if e then
		e.owner = owner
		e.cost = cost
	else
		local newEntry: Entry = {
			owner = owner,
			cost = cost,
			highlight = nil,
			tween = nil,
			active = false,
			ancestryConn = nil,
			tagOrig = {},
			flashing = false,
		}
		newEntry.ancestryConn = pad.AncestryChanged:Connect(function(_, parent)
			if parent == nil then
				PadFeedback.Unregister(pad)
			end
		end)
		entries[pad] = newEntry
		pad:SetAttribute("Affordable", false)
	end
	watchCash(owner)
	refresh(pad)
end

function PadFeedback.Denied(player: Player, pad: BasePart, cost: number)
	if typeof(player) ~= "Instance" or not player:IsA("Player") then
		return
	end
	if typeof(pad) ~= "Instance" or not pad:IsA("BasePart") then
		return
	end
	local c = if type(cost) == "number" then cost else 0
	local perPlayer = deniedAt[player]
	if not perPlayer then
		perPlayer = {}
		deniedAt[player] = perPlayer
	end
	local now = os.clock()
	local last = perPlayer[pad]
	if last and now - last < DENY_DEBOUNCE then
		return
	end
	perPlayer[pad] = now
	Telemetry.count("pad_denied", 1)
	remote:FireClient(player, "denied", pad, c)

	-- server-side red flash so feedback exists even without client help
	local e = entries[pad]
	if not (e and e.flashing) then
		if e then
			e.flashing = true
		end
		local original = pad.Color
		pad.Color = RED
		task.delay(0.35, function()
			if pad.Parent then
				pad.Color = original
			end
			if e then
				e.flashing = false
			end
		end)
	end
end

local function onPlayerRemoving(player: Player)
	for pad, e in entries do
		if e.owner == player then
			PadFeedback.Unregister(pad)
		end
	end
	local conn = cashConns[player]
	if conn then
		conn:Disconnect()
		cashConns[player] = nil
	end
	deniedAt[player] = nil
end

local function init()
	local existing = ReplicatedStorage:FindFirstChild("PadFeedback")
	if existing and existing:IsA("RemoteEvent") then
		remote = existing
	else
		remote = Instance.new("RemoteEvent")
		remote.Name = "PadFeedback"
		remote.Parent = ReplicatedStorage
	end
	local existingBind = ServerStorage:FindFirstChild("PadAffordable")
	if existingBind and existingBind:IsA("BindableEvent") then
		affordableEvent = existingBind
	else
		affordableEvent = Instance.new("BindableEvent")
		affordableEvent.Name = "PadAffordable"
		affordableEvent.Parent = ServerStorage
	end
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			for pad, e in entries do
				watchCash(e.owner)
				refresh(pad)
			end
		end
	end)
end

init()

return PadFeedback
