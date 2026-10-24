--!strict
-- ShopTelemetry: self-booting server Script. Counts shop opens (rate-limited per player)
-- and shop purchases (signalled by UpgradeService via a BindableEvent). Holds no game state.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ForgeTelemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry", 10) :: ModuleScript) :: any

local OPEN_COOLDOWN = 0.5

-- RemoteEvent 'ShopOpened' (reuse if it already exists)
local openedRemote = ReplicatedStorage:FindFirstChild("ShopOpened")
if not openedRemote or not openedRemote:IsA("RemoteEvent") then
	if openedRemote then
		openedRemote:Destroy()
	end
	local re = Instance.new("RemoteEvent")
	re.Name = "ShopOpened"
	re.Parent = ReplicatedStorage
	openedRemote = re
end

-- BindableEvent 'ShopPurchaseOk' (reuse if it already exists)
local purchaseOk = ServerStorage:FindFirstChild("ShopPurchaseOk")
if not purchaseOk or not purchaseOk:IsA("BindableEvent") then
	if purchaseOk then
		purchaseOk:Destroy()
	end
	local be = Instance.new("BindableEvent")
	be.Name = "ShopPurchaseOk"
	be.Parent = ServerStorage
	purchaseOk = be
end

local openedEvent = openedRemote :: RemoteEvent
local purchaseEvent = purchaseOk :: BindableEvent

local lastOpen: { [Player]: number } = {}

openedEvent.OnServerEvent:Connect(function(player: Player)
	if not player or not player.Parent then
		return
	end
	local now = os.clock()
	local last = lastOpen[player]
	if last and now - last < OPEN_COOLDOWN then
		return
	end
	lastOpen[player] = now
	ForgeTelemetry.count("shop_opened", 1)
end)

purchaseEvent.Event:Connect(function()
	ForgeTelemetry.count("shop_purchases", 1)
end)

Players.PlayerRemoving:Connect(function(player: Player)
	lastOpen[player] = nil
end)
