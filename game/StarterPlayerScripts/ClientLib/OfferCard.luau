--!strict
-- OfferCard [owner: Monetization]. One small, honest game pass card (OfferService's Monetization/Offer
-- payload): a headline about what just happened ("OUT OF FOAM?"), the pass icon + name + one line of
-- what you get, a big "BUY  R$ 149" (the real price) and a small "No thanks". No timers, no "limited".
-- Used by ResultsController (beside NEXT CALL, which stays the biggest button) and OfferController
-- (the lobby card after a level up). The card reports shown / buy / no to Monetization/OfferAct; the
-- server prompts the purchase (MonetizationService, the store's own path).
--   OfferCard.build(parent, offer, opts?) -> Frame   -- 262 x 124 design units, anchored per opts
--     opts.position: UDim2, opts.anchor: Vector2, opts.onClose: () -> () (after BUY or No thanks)
--   OfferCard.price(key, fallback) -> number          -- cached GetProductInfo price
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent:WaitForChild("UiKit") :: ModuleScript) :: any
local Loc = require(game:GetService("ReplicatedStorage"):WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local OfferCard = {}
OfferCard.Width = 262
OfferCard.Height = 124

type Info = { price: number?, icon: number? }
local infoCache: { [string]: Info } = {}

local function defOf(key: string): any
	for _, d in Cfg.Passes do
		if d.key == key then
			return d
		end
	end
	return nil
end

local function info(key: string): Info
	local cached = infoCache[key]
	if cached then
		return cached
	end
	local out: Info = {}
	local id = Cfg.GamePasses[key]
	if type(id) == "number" and id > 0 then
		local ok, res = pcall(function()
			return MarketplaceService:GetProductInfo(id, Enum.InfoType.GamePass)
		end)
		if ok and type(res) == "table" then
			local r = res :: any
			out.price = if type(r.PriceInRobux) == "number" then r.PriceInRobux else nil
			out.icon = if type(r.IconImageAssetId) == "number" and r.IconImageAssetId > 0 then r.IconImageAssetId else nil
			infoCache[key] = out
		end
	end
	return out
end

function OfferCard.price(key: string, fallback: number): number
	local i = infoCache[key]
	return if i and i.price then i.price else fallback
end

local function act(action: string, id: number)
	local ok, remote = pcall(Net.event, "Monetization", "OfferAct")
	if ok and remote then
		remote:FireServer(action, id)
	end
end

function OfferCard.build(parent: Instance, offer: { [string]: any }, opts: { [string]: any }?): Frame
	local o = opts or {}
	local key = tostring(offer.key)
	local def = defOf(key) or {}
	local id = tonumber(offer.id) or 0
	local W, H = OfferCard.Width, OfferCard.Height

	local card = Instance.new("Frame")
	card.Name = "OfferCard"
	card.Size = UDim2.fromOffset(W, H)
	card.Position = o.position or UDim2.fromOffset(0, 0)
	card.AnchorPoint = o.anchor or Vector2.new(0, 0)
	card.BackgroundColor3 = Color3.fromHex("#FFE7BF")
	card.BorderSizePixel = 0
	card.ZIndex = 4
	card:SetAttribute("OfferKey", key)
	card:SetAttribute("Menu", true) -- frees the first-person mouse while it is up
	UiKit.corner(card, 14)
	UiKit.stroke(card, 3, Palette.UiInk)

	local head = UiKit.label(card, "Headline", tostring(offer.headline or def.name or key), UDim2.new(1, -16, 0, 24), UDim2.fromOffset(8, 5), {
		font = UiKit.Header,
		textSize = 22,
		color = def.color or Palette.UiFlameMid,
		stroke = true,
		strokeThickness = 2,
		align = Enum.TextXAlignment.Left,
	})
	head.ZIndex = 5

	local badge = Instance.new("Frame")
	badge.Name = "IconBg"
	badge.Size = UDim2.fromOffset(46, 46)
	badge.Position = UDim2.fromOffset(8, 32)
	badge.BackgroundColor3 = def.color or Palette.UiWater
	badge.ZIndex = 5
	badge.Parent = card
	UiKit.corner(badge, 23)
	UiKit.stroke(badge, 2, Palette.UiInk)
	local glyph = Instance.new("TextLabel")
	glyph.Name = "Glyph"
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.fromScale(1, 1)
	glyph.Font = Enum.Font.GothamBlack
	glyph.TextScaled = true
	glyph.Text = def.icon or "?"
	glyph.TextColor3 = Palette.UiCream
	glyph.ZIndex = 6
	glyph.Parent = badge
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(0.9, 0.9)
	icon.Position = UDim2.fromScale(0.05, 0.05)
	icon.Visible = false
	icon.ZIndex = 7
	icon.Parent = badge
	UiKit.corner(icon, 20)

	local name = UiKit.label(card, "Name", tostring(def.name or key), UDim2.new(1, -72, 0, 24), UDim2.fromOffset(62, 32), {
		font = UiKit.Header,
		textSize = 21,
		color = Palette.UiInk,
		align = Enum.TextXAlignment.Left,
	})
	name.ZIndex = 5
	local short = UiKit.label(card, "Short", tostring(offer.short or ""), UDim2.new(1, -72, 0, 22), UDim2.fromOffset(62, 56), {
		font = UiKit.Body,
		textSize = 15,
		color = Palette.UiInk,
		align = Enum.TextXAlignment.Left,
	})
	short.TextWrapped = true
	short.ZIndex = 5

	local price = tonumber(offer.price) or tonumber(def.price) or 0
	local buy = UiKit.button(card, "Buy", Loc.t("BUY  R$ {1}", { price }), UDim2.fromOffset(160, 38), UDim2.fromOffset(8 + 80, 82 + 19), Palette.UiWarn)
	buy.TextSize = 22
	buy.ZIndex = 6
	local no = Instance.new("TextButton")
	no.Name = "NoThanks"
	no.AnchorPoint = Vector2.new(0.5, 0.5)
	no.Position = UDim2.fromOffset(176 + 39, 82 + 19)
	no.Size = UDim2.fromOffset(78, 38)
	no.BackgroundTransparency = 1
	no.Font = UiKit.Body
	no.TextSize = 16
	no.TextColor3 = Palette.CoatShadow or Palette.UiInk
	no.Text = "No thanks"
	no.ZIndex = 6
	no.Parent = card

	local closed = false
	local function close()
		if closed then
			return
		end
		closed = true
		UiKit.tween(card, 0.2, { BackgroundTransparency = 1 })
		task.delay(0.2, function()
			card:Destroy()
		end)
		if type(o.onClose) == "function" then
			o.onClose()
		end
	end
	UiKit.onTap(buy, function()
		if closed then
			return
		end
		act("buy", id) -- the server opens the Roblox purchase prompt
		close()
	end)
	UiKit.onTap(no, function()
		if closed then
			return
		end
		act("no", id)
		close()
	end)
	-- the card is on screen: report it once it is parented and visible
	card.Parent = parent
	act("shown", id)

	task.spawn(function()
		local i = info(key)
		if closed then
			return
		end
		if i.price and i.price ~= price then
			buy.Text = Loc.t("BUY  R$ {1}", { i.price })
		end
		if i.icon then
			icon.Image = `rbxassetid://{i.icon}`
			icon.Visible = true
			glyph.Visible = false
		end
	end)
	return card
end

return OfferCard
