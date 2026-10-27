--!strict
-- OfferController [owner: Monetization]. The lobby pass offer: OfferService sends Monetization/Offer with
-- moment "lobby" (back at the station after a call that levelled you up, at most once a session). It shows
-- one small OfferCard (ClientLib/OfferCard) at the left edge, just above the NEWS / ADMIN chips (clear
-- of the top bar, the hotbar and the phone thumb buttons), waits until no modal / results screen is up, and hides itself
-- after MonetizationConfig.Offers.LobbyCardSeconds. Results offers are ResultsController's.
-- ClientLib/PopupGate decides when ("offer"): never before the first call is done or in a new player's
-- first session, one auto pop-up at a time, spaced; a deferred offer is simply not shown (the server
-- offers again another session).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local HudLayout = require(ClientLib:WaitForChild("HudLayout") :: ModuleScript) :: any
local OfferCard = require(ClientLib:WaitForChild("OfferCard") :: ModuleScript) :: any
local PopupGate = require(ClientLib:WaitForChild("PopupGate") :: ModuleScript) :: any

local OfferController = {}
OfferController.Priority = 125

local player = Players.LocalPlayer
local gui: ScreenGui? = nil
local current: Frame? = nil

local function inLobby(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) ~= "string" or iid == ""
end

local function show(offer: { [string]: any })
	-- wait (up to 20 s) for a calm screen: no modal, no results / busy screen
	local t0 = os.clock()
	while HudLayout.modalOpen() or HudLayout.isBusy() or PopupGate.decide("offer") == "wait" do
		if os.clock() - t0 > 30 or not inLobby() then
			return
		end
		task.wait(0.5)
	end
	if not inLobby() or not PopupGate.claim("offer") then
		return -- dropped / deferred (PopupGate)
	end
	local released = false
	local function release()
		if not released then
			released = true
			PopupGate.release("offer")
		end
	end
	if current then
		current:Destroy()
		current = nil
	end
	local g = gui
	if not g then
		g = UiKit.screen("OfferGui", 8)
		gui = g
	end
	local card = OfferCard.build(g, offer, {
		-- right of the left chip column (HudLayout stack "Chips", 13 + 118 px wide), level with its middle
		position = UDim2.new(0, 143, 0.5, 0),
		anchor = Vector2.new(0, 0.5),
		onClose = function()
			current = nil
			release()
		end,
	})
	current = card
	card.Destroying:Connect(release)
	UiKit.pop(card, 0.3)
	local secs = tonumber(Cfg.Offers.LobbyCardSeconds) or 12
	task.delay(secs, function()
		if current == card then
			current = nil
			UiKit.tween(card, 0.25, { BackgroundTransparency = 1 })
			task.delay(0.25, function()
				card:Destroy()
				release()
			end)
		end
	end)
end

function OfferController:Init(_all) end

function OfferController:Start()
	local remote = Net.event("Monetization", "Offer")
	remote.OnClientEvent:Connect(function(offer: any)
		if type(offer) == "table" and offer.moment == "lobby" then
			task.spawn(show, offer)
		end
	end)
	player:GetAttributeChangedSignal("InstanceId"):Connect(function()
		if not inLobby() and current then
			current:Destroy()
			current = nil
		end
	end)
end

-- Test hook: draw a lobby offer card.
function OfferController:_show(offer: { [string]: any })
	task.spawn(show, offer)
end

return OfferController
