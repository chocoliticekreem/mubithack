--!strict
-- StoreController [owner: Monetization]. The Robux store: a lobby-only STORE button in the top-bar box
-- (ClientLib/TopBox, after level + pass; or [B]) that opens a sticker-style panel listing MonetizationConfig.Passes (icon, name, blurb, "R$ 149",
-- BUY / OWNED / GIFTED / COMING SOON) and a donate row (R$ 10 / 50 / 100 / 500).
-- Prices come from MarketplaceService:GetProductInfo (config price until it answers). Ownership is the
-- server's Player attr Pass_<Key>. Purchases go through Monetization/Buy (the server validates and
-- prompts). The Donation Board's prompt fires Monetization/Open ("donate") to open it here.
-- The panel has attribute Menu = true, so MenuMouseController frees the mouse while it is open.
-- Back at the station after a call, the STORE chip pulses once (a gentle grow + gold flash; only while
-- there is still a pass you don't own). No sound, no repeat.
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript)
local Loc = require(game:GetService("ReplicatedStorage"):WaitForChild("Lib"):WaitForChild("Loc") :: ModuleScript)

local StoreController = {}
StoreController.Priority = 120

local player = Players.LocalPlayer

type Card = { key: string, id: number, button: TextButton, price: TextLabel, icon: ImageLabel, glyph: TextLabel }

local gui: ScreenGui? = nil
local panel: Frame? = nil
local chip: GuiObject? = nil -- the Store section of the top-bar box
local chipButton: TextButton? = nil
local donateRow: Frame? = nil
local donatedLabel: TextLabel? = nil
local cards: { Card } = {}
local buyRemote: RemoteEvent? = nil

local GREY = Color3.fromHex("#8C8A88")

local function passId(key: string): number
	local v = Cfg.GamePasses[key]
	return if type(v) == "number" and v > 0 then v else 0
end

local function inLobby(): boolean
	local iid = player:GetAttribute("InstanceId")
	return type(iid) ~= "string" or iid == ""
end

local function paintCard(c: Card)
	local b = c.button
	if c.id == 0 then
		b.Text = "COMING SOON"
		b.BackgroundColor3 = GREY
		b.TextSize = 20
		b.AutoButtonColor = false
	elseif player:GetAttribute(Cfg.Attr.GiftedPrefix .. c.key) == true then
		b.Text = "GIFTED"
		b.BackgroundColor3 = Palette.UiWater
		b.TextSize = 26
		b.AutoButtonColor = false
	elseif player:GetAttribute(Cfg.Attr.PassPrefix .. c.key) == true then
		b.Text = "OWNED"
		b.BackgroundColor3 = Palette.UiGood
		b.TextSize = 26
		b.AutoButtonColor = false
	else
		b.Text = "BUY"
		b.BackgroundColor3 = Palette.UiWarn
		b.TextSize = 28
		b.AutoButtonColor = true
	end
end

local function paintAll()
	for _, c in cards do
		paintCard(c)
	end
	local d = donatedLabel
	if d then
		local total = tonumber(player:GetAttribute(Cfg.Attr.Donated)) or 0
		d.Text = if total > 0 then Loc.t("You've donated R$ {1}. You're a hero!", { total }) else "Every Robux keeps the trucks rolling."
	end
end

local function fetchInfo(c: Card)
	if c.id == 0 then
		return
	end
	local ok, info = pcall(function()
		return MarketplaceService:GetProductInfo(c.id, Enum.InfoType.GamePass)
	end)
	if not ok or type(info) ~= "table" then
		return
	end
	local price = (info :: any).PriceInRobux
	if type(price) == "number" then
		c.price.Text = `R$ {price}`
	end
	local icon = (info :: any).IconImageAssetId
	if type(icon) == "number" and icon > 0 then
		c.icon.Image = `rbxassetid://{icon}`
		c.icon.Visible = true
		c.glyph.Visible = false
	end
end

local function setOpen(open: boolean, section: string?)
	local p = panel
	if not p then
		return
	end
	if open then
		paintAll()
		p.Visible = true
		UiKit.pop(p, 0.25)
		if section == "donate" and donateRow then
			task.delay(0.3, function()
				if donateRow then
					UiKit.punch(donateRow, 0.08)
				end
			end)
		end
	else
		p.Visible = false
	end
end

-- one gentle pulse of the STORE chip (after a call): grow + gold, then back
local function pulseChip()
	local b = chipButton
	if not b or not b.Visible then
		return
	end
	local anyToBuy = false
	for _, def in Cfg.Passes do
		if passId(def.key) > 0 and player:GetAttribute(Cfg.Attr.PassPrefix .. def.key) ~= true then
			anyToBuy = true
		end
	end
	if not anyToBuy then
		return
	end
	local base = b.BackgroundColor3
	local scale = b:FindFirstChild("PulseScale") :: UIScale?
	if not scale then
		local s = Instance.new("UIScale")
		s.Name = "PulseScale"
		s.Parent = b
		scale = s
	end
	local sc = scale :: UIScale
	UiKit.tween(b, 0.25, { BackgroundColor3 = Palette.UiWarn })
	UiKit.tween(sc, 0.25, { Scale = 1.22 }, Enum.EasingStyle.Back)
	task.delay(0.45, function()
		UiKit.tween(sc, 0.3, { Scale = 1 })
		UiKit.tween(b, 0.6, { BackgroundColor3 = base })
	end)
end

local function toggle()
	local p = panel
	if p then
		setOpen(not p.Visible)
	end
end

local function buildCard(parent: Instance, def: any, index: number, count: number): Card
	local w = 330
	local gap = 20
	local totalW = count * w + (count - 1) * gap
	local x = -totalW / 2 + (index - 1) * (w + gap)
	local card = Instance.new("Frame")
	card.Name = def.key
	card.Size = UDim2.fromOffset(w, 220)
	card.Position = UDim2.new(0.5, x, 0, 78)
	card.BackgroundColor3 = Color3.fromHex("#FFE7BF")
	card.BorderSizePixel = 0
	card.Parent = parent
	UiKit.corner(card, 14)
	UiKit.stroke(card, 3, Palette.UiInk)

	local badge = Instance.new("Frame")
	badge.Name = "IconBg"
	badge.Size = UDim2.fromOffset(84, 84)
	badge.Position = UDim2.fromOffset(14, 14)
	badge.BackgroundColor3 = def.color or Palette.UiWater
	badge.Parent = card
	UiKit.corner(badge, 42)
	UiKit.stroke(badge, 3, Palette.UiInk)
	local glyph = UiKit.label(badge, "Glyph", def.icon or "?", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 52,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
	})
	local icon = Instance.new("ImageLabel")
	icon.Name = "Icon"
	icon.BackgroundTransparency = 1
	icon.Size = UDim2.fromScale(0.86, 0.86)
	icon.Position = UDim2.fromScale(0.07, 0.07)
	icon.Visible = false
	icon.ZIndex = 3
	icon.Parent = badge
	UiKit.corner(icon, 38)

	UiKit.label(card, "Name", def.name, UDim2.fromOffset(w - 120, 34), UDim2.fromOffset(110, 16), {
		font = UiKit.Header,
		textSize = 26,
		color = Palette.UiInk,
		align = Enum.TextXAlignment.Left,
	})
	local price = UiKit.label(card, "Price", `R$ {def.price}`, UDim2.fromOffset(w - 120, 32), UDim2.fromOffset(110, 54), {
		font = UiKit.Header,
		textSize = 28,
		color = Palette.UiFlameMid,
		stroke = true,
		strokeThickness = 2,
		align = Enum.TextXAlignment.Left,
	})
	local blurb = UiKit.label(card, "Blurb", def.blurb, UDim2.fromOffset(w - 28, 58), UDim2.fromOffset(14, 104), {
		font = UiKit.Body,
		textSize = 18,
		color = Palette.UiInk,
		align = Enum.TextXAlignment.Left,
	})
	blurb.TextYAlignment = Enum.TextYAlignment.Top

	local button = UiKit.button(card, "Buy", "BUY", UDim2.fromOffset(w - 40, 44), UDim2.new(0.5, 0, 1, -32), Palette.UiWarn)
	local c: Card = { key = def.key, id = passId(def.key), button = button, price = price, icon = icon, glyph = glyph }
	button.Activated:Connect(function()
		if c.id == 0 or player:GetAttribute(Cfg.Attr.PassPrefix .. c.key) == true then
			UiKit.shake(card, 0.25, 4)
			return
		end
		local r = buyRemote
		if r then
			r:FireServer("pass", c.key)
		end
	end)
	player:GetAttributeChangedSignal(Cfg.Attr.PassPrefix .. def.key):Connect(function()
		paintCard(c)
		if player:GetAttribute(Cfg.Attr.PassPrefix .. def.key) == true then
			UiKit.punch(card, 0.08)
		end
	end)
	player:GetAttributeChangedSignal(Cfg.Attr.GiftedPrefix .. def.key):Connect(function()
		paintCard(c)
	end)
	return c
end

local function build()
	local g = UiKit.screen("StoreGui", 7)
	gui = g

	-- lobby button: the last section of the top-bar box (ClientLib/TopBox), after level + pass
	local TopBox = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("TopBox") :: ModuleScript) :: any
	local hasKeys = InputHints.mode() == "keyboard"
	local slot = TopBox.section("Store", 3, if hasKeys then 92 else 64) :: Frame
	local b = Instance.new("TextButton")
	b.Name = "StoreChip"
	b.AnchorPoint = Vector2.new(0, 0.5)
	b.Position = UDim2.fromScale(0, 0.5)
	b.Size = UDim2.new(1, 0, 0, 28)
	b.BackgroundColor3 = Palette.UiGood
	b.Font = UiKit.Header
	b.TextSize = 16
	b.TextColor3 = Palette.UiCream
	InputHints.setChip(b, Cfg.StoreKey.Name, "STORE")
	b.AutoButtonColor = true
	b.Parent = slot
	UiKit.corner(b, 8)
	UiKit.stroke(b, 2, Palette.UiInk)
	local ts = Instance.new("UIStroke")
	ts.Thickness = 1.5
	ts.Color = Palette.UiInk
	ts.ApplyStrokeMode = Enum.ApplyStrokeMode.Contextual
	ts.Parent = b
	UiKit.onTap(b, toggle) -- a 44 px touch pad around the small chip on phones
	chipButton = b
	chip = slot -- syncChip shows / hides the whole section (lobby only)

	-- panel
	local p = UiKit.panel(g, "StorePanel", UDim2.fromOffset(720, 470), UDim2.fromScale(0.5, 0.5), Vector2.new(0.5, 0.5))
	p.Visible = false
	p:SetAttribute("Menu", true)
	p.ZIndex = 5
	panel = p
	-- a modal: dims the HUD under it and sits above every HUD gui while open; click outside closes
	HudLayout.modal(p, {
		onDismiss = function()
			setOpen(false)
		end,
	})

	local head = Instance.new("Frame")
	head.Name = "Header"
	head.Size = UDim2.new(1, 0, 0, 62)
	head.BackgroundColor3 = Palette.UiRed
	head.BorderSizePixel = 0
	head.Parent = p
	UiKit.corner(head, 12)
	local flat = Instance.new("Frame") -- squares off the header's bottom corners
	flat.Size = UDim2.new(1, 0, 0, 14)
	flat.Position = UDim2.new(0, 0, 1, -14)
	flat.BackgroundColor3 = Palette.UiRed
	flat.BorderSizePixel = 0
	flat.Parent = head
	UiKit.label(head, "Title", "STATION 67 STORE", UDim2.new(1, -120, 1, 0), UDim2.fromOffset(20, 0), {
		font = UiKit.Header,
		textSize = 36,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
		align = Enum.TextXAlignment.Left,
	})
	local close = UiKit.button(head, "Close", "X", UDim2.fromOffset(44, 44), UDim2.new(1, -34, 0.5, 0), Palette.UiPanelDark)
	close.TextSize = 26
	UiKit.onTap(close, function()
		setOpen(false)
	end)

	cards = {}
	for i, def in Cfg.Passes do
		table.insert(cards, buildCard(p, def, i, #Cfg.Passes))
	end

	-- donate row
	local row = Instance.new("Frame")
	row.Name = "Donate"
	row.Size = UDim2.new(1, -40, 0, 140)
	row.Position = UDim2.new(0, 20, 1, -156)
	row.BackgroundColor3 = Palette.UiPanelDark
	row.BorderSizePixel = 0
	row.Parent = p
	UiKit.corner(row, 14)
	UiKit.stroke(row, 3, Palette.UiInk)
	donateRow = row
	UiKit.label(row, "Title", "SUPPORT STATION 67", UDim2.new(1, -24, 0, 30), UDim2.fromOffset(12, 8), {
		font = UiKit.Header,
		textSize = 26,
		color = Palette.UiWarn,
		stroke = true,
		align = Enum.TextXAlignment.Left,
	})
	donatedLabel = UiKit.label(row, "Total", "", UDim2.new(1, -24, 0, 22), UDim2.fromOffset(12, 38), {
		font = UiKit.Body,
		textSize = 18,
		color = Palette.UiCream,
		align = Enum.TextXAlignment.Left,
	})
	local products = Cfg.DonationProducts
	local n = #products
	local bw, gap = 140, 14
	local totalW = n * bw + (n - 1) * gap
	for i, prod in products do
		local x = -totalW / 2 + bw / 2 + (i - 1) * (bw + gap)
		local configured = type(prod.id) == "number" and prod.id > 0
		local btn = UiKit.button(row, `R{prod.robux}`, `R$ {prod.robux}`, UDim2.fromOffset(bw, 50), UDim2.new(0.5, x, 1, -38),
			if configured then Palette.UiGood else GREY)
		btn.TextSize = 26
		btn.Activated:Connect(function()
			local r = buyRemote
			if r then
				r:FireServer("donate", prod.robux) -- the server says "coming soon" for unset ids
			end
		end)
	end
	paintAll()
end

function StoreController:Init(_all) end

function StoreController:Start()
	buyRemote = Net.event("Monetization", "Buy")
	local open = Net.event("Monetization", "Open")
	build()
	open.OnClientEvent:Connect(function(section: any)
		setOpen(true, if type(section) == "string" then section else nil)
	end)
	for _, c in cards do
		task.spawn(fetchInfo, c)
	end
	player:GetAttributeChangedSignal(Cfg.Attr.Donated):Connect(paintAll)

	local wasOut = not inLobby()
	local function syncChip()
		local c = chip
		if c then
			c.Visible = inLobby()
		end
		if inLobby() and wasOut then
			task.delay(2.5, pulseChip) -- back from a call: one pulse once the lobby HUD is up
		end
		wasOut = not inLobby()
		if not inLobby() and panel then
			setOpen(false)
		end
	end
	player:GetAttributeChangedSignal("InstanceId"):Connect(syncChip)
	syncChip()

	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.KeyCode ~= Cfg.StoreKey then
			return
		end
		if inLobby() or (panel and panel.Visible) then
			toggle()
		end
	end)
end

-- test hooks (execute_luau on the Client)
function StoreController:_open(section: string?)
	setOpen(true, section)
end

function StoreController:_close()
	setOpen(false)
end

function StoreController:_pulse()
	pulseChip()
end

return StoreController
