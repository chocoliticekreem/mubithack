--!strict
-- MonetizationService [owner: Monetization]. Robux: game passes, donation developer products and the
-- lobby Donation Board. Every id comes from ReplicatedStorage/Config/MonetizationConfig (0 = not
-- configured: never prompts, never errors).
--
-- Passes: ownership is checked on join (UserOwnsGamePassAsync, pcall + retries, cached per session)
--   and mirrored into Player attrs Pass_<Key> = true (UnlimitedFoam -> ToolService never drains Foam;
--   PremiumPass -> the store shows OWNED; BattlePassService reads Pass_PremiumPass for the premium track).
--   PromptGamePassPurchaseFinished applies a purchase at once (no rejoin).
--   Studio only: Player attr PassDebug_<Key> = true (set on the server) fakes ownership.
-- Donations: MarketplaceService.ProcessReceipt (this is the ONLY script that sets it). Idempotent per
--   PurchaseId (Lib/Monetization/MonetizationRules): a global ledger DataStore (memory in Studio, like
--   DataService) + the PurchaseIds kept in the donor's profile (ProfileSchema v5 donations). Returns
--   PurchaseGranted only once the profile holds the donation and was saved.
-- Donation Board: a physical board in the station lobby (west of the Mission Board) with the
--   all-time top donors (OrderedDataStore, memory in Studio), four R$ buttons (ClickDetector) and a
--   "Donate" prompt that opens the store's donate row. A donation shows "THANK YOU <name>!" + confetti.
--
-- Remotes: Monetization/Buy (C->S: kind "pass" | "donate", key: string | robux: number; 1/s burst 3)
--          Monetization/Open (S->C owner: section "donate" | nil) -- the board prompt opens the store
-- Writes: Player attrs Pass_<Key>, RobuxDonated; Model "DonationBoard" in the Station location
-- Consumes (nil-guarded): DataService (:WaitForProfile/:GetProfile/:Update/:Save/:IsPersistent,
--   .ProfileLoaded), MapService (.LocationBuilt, :GetLocation)
-- Counters: monetization_prompts, monetization_passes_bought, monetization_donations,
--           monetization_robux_donated, monetization_receipt_retries
-- Test hooks (DevHook only): _fakeReceipt(player, robux, purchaseId?) -> "Granted:applied" etc.,
--   _owns(player) -> "UnlimitedFoam=true,...", _board() -> top donor rows as text, _selftest()

local DataStoreService = game:GetService("DataStoreService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local TweenService = game:GetService("TweenService")

local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local MapConfig = require(ConfigFolder:WaitForChild("MapConfig") :: ModuleScript) :: any
local ToolConfig = require(ConfigFolder:WaitForChild("ToolConfig") :: ModuleScript) :: any
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local Lib = ServerScriptService:WaitForChild("Lib")
local Rules = require(Lib:WaitForChild("Monetization"):WaitForChild("MonetizationRules") :: ModuleScript)
local Schema = require(Lib:WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript)

local MonetizationService = {}
MonetizationService.Priority = 60

local IS_STUDIO = RunService:IsStudio()
local BATTLE_PASS_DEBUG = "BattlePassPremiumDebug" -- BattlePassService's own debug attribute

type Row = { userId: number, name: string, robux: number }

local services: { [string]: any } = {}
local owned: { [Player]: { [string]: boolean } } = {}
local mirroredPremiumDebug: { [Player]: boolean } = {}
local persistent = false
local ledger: GlobalDataStore? = nil
local memoryLedger: { [string]: any } = {}
local donorStore: OrderedDataStore? = nil
local memoryDonors: { [string]: number } = {}
local names: { [number]: string } = {}
local topRows: { Row } = {}
local openRemote: RemoteEvent? = nil

-- Donation Board handles (rebuilt with the station).
local board: { model: Model?, rows: { TextLabel }, thanks: BillboardGui?, confetti: { ParticleEmitter } } =
	{ model = nil, rows = {}, thanks = nil, confetti = {} }

------------------------------------------------------------------------------------------ passes

local function passKeys(): { string }
	local keys = {}
	for key in Cfg.GamePasses do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function attrFor(key: string): string
	return Cfg.Attr.PassPrefix .. key
end

local function owns(player: Player, key: string): boolean
	local cache = owned[player]
	return Rules.owns(cache and cache[key], player:GetAttribute(Cfg.Attr.DebugPrefix .. key), IS_STUDIO)
end

local function topUpFoam(player: Player)
	local size = (player:GetAttribute("FoamSize") :: number?) or ToolConfig.FoamSize
	if player:GetAttribute("Foam") ~= nil then
		player:SetAttribute("Foam", size)
	end
end

local function applyAttrs(player: Player)
	if not player.Parent then
		return
	end
	for _, key in passKeys() do
		local has = owns(player, key)
		local name = attrFor(key)
		local before = player:GetAttribute(name) == true
		player:SetAttribute(name, if has then true else nil)
		if has and not before and key == "UnlimitedFoam" then
			topUpFoam(player)
		end
	end
	-- Studio: faking the premium pass also flips the battle pass's own debug switch, so the premium
	-- track can be tested end to end.
	if IS_STUDIO then
		local dbg = player:GetAttribute(Cfg.Attr.DebugPrefix .. "PremiumPass") == true
		if dbg then
			player:SetAttribute(BATTLE_PASS_DEBUG, true)
			mirroredPremiumDebug[player] = true
		elseif mirroredPremiumDebug[player] then
			player:SetAttribute(BATTLE_PASS_DEBUG, nil)
			mirroredPremiumDebug[player] = nil
		end
	end
end

local function checkOwnership(player: Player)
	local cache = owned[player]
	if not cache then
		return
	end
	for _, key in passKeys() do
		local id = Rules.passId(Cfg.GamePasses, key)
		if id == 0 or player.UserId <= 0 then
			continue -- not configured / Studio test client (negative UserId)
		end
		for attempt = 1, 3 do
			local ok, res = pcall(function()
				return MarketplaceService:UserOwnsGamePassAsync(player.UserId, id)
			end)
			if ok then
				if res == true then
					cache[key] = true
				end
				break
			end
			if attempt == 3 then
				warn(`[MonetizationService] UserOwnsGamePassAsync {key} for {player.Name}: {res}`)
			else
				task.wait(attempt)
			end
		end
		if not player.Parent then
			return
		end
	end
	applyAttrs(player)
end

local function prettyName(key: string): string
	for _, p in Cfg.Passes do
		if p.key == key then
			return p.name
		end
	end
	return key
end

local function onPassPurchaseFinished(player: Player, passId: number, purchased: boolean)
	local key = Rules.passKey(Cfg.GamePasses, passId)
	if not key or not purchased or not owned[player] then
		return
	end
	owned[player][key] = true
	Telemetry.count("monetization_passes_bought")
	applyAttrs(player)
	Net.notify(player, `{prettyName(key)} unlocked! Thank you!`, "good")
end

------------------------------------------------------------------------------------ purchases

local function handleBuy(player: Player, kind: any, arg: any)
	if kind == "pass" then
		if type(arg) ~= "string" or Cfg.GamePasses[arg] == nil then
			return
		end
		local id = Rules.passId(Cfg.GamePasses, arg)
		if id == 0 then
			Net.notify(player, "Coming soon!", "info")
			return
		end
		if owns(player, arg) then
			Net.notify(player, "You already own that!", "info")
			return
		end
		Telemetry.count("monetization_prompts")
		local ok, err = pcall(function()
			MarketplaceService:PromptGamePassPurchase(player, id)
		end)
		if not ok then
			warn(`[MonetizationService] PromptGamePassPurchase {arg}: {err}`)
		end
	elseif kind == "donate" then
		local product = Rules.donation(Cfg.DonationProducts, arg)
		if not product then
			return
		end
		if product.id == 0 then
			Net.notify(player, "Donations are coming soon!", "info")
			return
		end
		Telemetry.count("monetization_prompts")
		local ok, err = pcall(function()
			MarketplaceService:PromptProductPurchase(player, product.id)
		end)
		if not ok then
			warn(`[MonetizationService] PromptProductPurchase {product.robux}: {err}`)
		end
	end
end

----------------------------------------------------------------------------------- donor board

local function nameOf(userId: number): string
	local n = names[userId]
	if n then
		return n
	end
	local player = Players:GetPlayerByUserId(userId)
	if player then
		n = player.DisplayName
	elseif userId > 0 then
		local ok, res = pcall(function()
			return Players:GetNameFromUserIdAsync(userId)
		end)
		n = if ok then res else nil
	end
	n = n or `Firefighter {userId}`
	names[userId] = n
	return n :: string
end

local function writeDonor(userId: number, robux: number)
	memoryDonors[tostring(userId)] = robux
	local ods = donorStore
	if ods then
		local ok, err = pcall(function()
			ods:SetAsync(tostring(userId), robux)
		end)
		if not ok then
			warn(`[MonetizationService] donor board write: {err}`)
		end
	end
end

local function readDonors(): { Row }?
	local n = math.max(1, math.floor(Cfg.DonorTopN))
	local items: { { key: string, value: number } } = {}
	local ods = donorStore
	if ods then
		local ok, page = pcall(function()
			return ods:GetSortedAsync(false, n):GetCurrentPage()
		end)
		if not ok then
			warn(`[MonetizationService] donor board read: {page}`)
			return nil
		end
		items = page :: any
	else
		for k, v in memoryDonors do
			table.insert(items, { key = k, value = v })
		end
		table.sort(items, function(a, b)
			return a.value > b.value
		end)
	end
	local rows: { Row } = {}
	for _, item in items do
		local userId = tonumber(item.key)
		if userId and item.value > 0 and #rows < n then
			table.insert(rows, { userId = userId, name = nameOf(userId), robux = item.value })
		end
	end
	return rows
end

local function escape(s: string): string
	return (string.gsub(string.gsub(s, "&", "&amp;"), "<", "&lt;"))
end

local function renderBoard()
	for i, label in board.rows do
		local r = topRows[i]
		if r then
			label.Text = `{i}. {escape(r.name)}  <font color="#FFC531"><b>R$ {r.robux}</b></font>`
		else
			label.Text = if i == 1 then "Be the first hero to donate!" else ""
		end
	end
end

local function refreshBoard()
	local rows = readDonors()
	if rows then
		topRows = rows
	end
	renderBoard()
end

local function part(parent: Instance, name: string, cf: CFrame, size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CFrame = cf
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = parent
	return p
end

local function label(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, font: Enum.Font, color: Color3, align: Enum.TextXAlignment?): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.BackgroundTransparency = 1
	l.Size = size
	l.Position = pos
	l.Font = font
	l.TextScaled = true
	l.RichText = true
	l.TextColor3 = color
	l.Text = text
	l.TextXAlignment = align or Enum.TextXAlignment.Center
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = Palette.UiInk
	s.Parent = l
	l.Parent = parent
	return l
end

local function surface(p: BasePart, pps: number): SurfaceGui
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = pps
	gui.LightInfluence = 0
	gui.Brightness = 1.3
	gui.MaxDistance = 200
	gui.Parent = p
	return gui
end

local CONFETTI_COLORS = { Palette.HelmetRed, Palette.HelmetShield, Palette.UiWater, Palette.UiGood, Color3.fromHex("#FF7AB6") }

local function buildBoard(station: Model)
	local B = Cfg.Board
	local old = station:FindFirstChild("DonationBoard")
	if old then
		old:Destroy()
	end
	local origin = station:GetAttribute("StationOrigin")
	local O: CFrame = if typeof(origin) == "CFrame" then origin else MapConfig.SlotOrigin(0)
	local W, H = B.Width, B.Height
	local floorY = B.Center.Y
	local cy = floorY + B.Lift + H / 2
	local center = Vector3.new(B.Center.X, cy, B.Center.Z)
	local face = O * CFrame.lookAt(center, center + Vector3.new(0, 0, 1)) -- Front face looks +Z (the pads)

	local model = Instance.new("Model")
	model.Name = "DonationBoard"
	local frame = part(model, "Frame", face * CFrame.new(0, 0, 0.35), Vector3.new(W + 0.8, H + 0.8, 0.4), Palette.BookshelfWood or Color3.fromHex("#8A4A28"), Enum.Material.Wood)
	frame.CanCollide = false
	for _, dx in { -W / 2 + 0.5, W / 2 - 0.5 } do
		local postH = cy + H / 2 - floorY
		part(model, "Post", O * CFrame.new(B.Center.X + dx, floorY + postH / 2, B.Center.Z - 0.7), Vector3.new(0.5, postH, 0.5), Color3.fromHex("#4A4650"), Enum.Material.Metal)
	end
	local header = part(model, "Header", face * CFrame.new(0, H / 2 + 0.85, 0.2), Vector3.new(W * 0.85, 1.3, 0.4), Palette.UiWarn, Enum.Material.Neon)
	header.CanCollide = false
	label(surface(header, B.PixelsPerStud), "Title", "DONATION BOARD", UDim2.fromScale(0.96, 0.84), UDim2.fromScale(0.02, 0.08), Enum.Font.LuckiestGuy, Palette.UiCream)

	local face0 = part(model, "Board", face, Vector3.new(W, H, 0.3), Palette.UiPanelDark)
	local gui = surface(face0, B.PixelsPerStud)
	gui.Name = "DonorGui"
	label(gui, "Sub", "TOP DONORS - ALL TIME", UDim2.fromScale(0.92, 0.1), UDim2.fromScale(0.04, 0.03), Enum.Font.LuckiestGuy, Palette.UiWarn)
	board.rows = {}
	local n = math.max(1, math.floor(Cfg.DonorTopN))
	local rowH = 0.66 / n
	for i = 1, n do
		local l = label(gui, `Row{i}`, "", UDim2.fromScale(0.9, rowH * 0.86), UDim2.fromScale(0.05, 0.15 + (i - 1) * rowH), Enum.Font.FredokaOne, Palette.UiCream, Enum.TextXAlignment.Left)
		table.insert(board.rows, l)
	end
	label(gui, "Hint", "Click a button below or press E to donate. Thank you!", UDim2.fromScale(0.92, 0.08), UDim2.fromScale(0.04, 0.89), Enum.Font.FredokaOne, Palette.UiShock)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DonatePrompt"
	prompt.ActionText = "Donate"
	prompt.ObjectText = "Donation Board"
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 12
	prompt.RequiresLineOfSight = false
	prompt.Parent = face0
	prompt.Triggered:Connect(function(player: Player)
		local r = openRemote
		if r then
			r:FireClient(player, "donate")
		end
	end)

	-- four R$ buttons on a ledge under the board
	local products = Cfg.DonationProducts
	local count = #products
	local bw = (W - 0.4 * (count + 1)) / count
	part(model, "Ledge", face * CFrame.new(0, -H / 2 - 0.15, -0.35), Vector3.new(W + 0.4, 0.3, 1.1), Color3.fromHex("#4A4650"), Enum.Material.Metal)
	for i, prod in products do
		-- the board looks +Z, so its local +X is the viewer's left: count from the right edge to read R$ 10 -> 500
		local x = W / 2 - 0.4 - bw / 2 - (i - 1) * (bw + 0.4)
		local btn = part(model, `Donate{prod.robux}`, face * CFrame.new(x, -H / 2 - 0.8, -0.35), Vector3.new(bw, 1, 0.5), Palette.UiGood, Enum.Material.SmoothPlastic)
		btn:SetAttribute("Robux", prod.robux)
		label(surface(btn, B.PixelsPerStud), "Text", `R$ {prod.robux}`, UDim2.fromScale(0.9, 0.8), UDim2.fromScale(0.05, 0.1), Enum.Font.LuckiestGuy, Palette.UiCream)
		local click = Instance.new("ClickDetector")
		click.MaxActivationDistance = 24
		click.Parent = btn
		click.MouseClick:Connect(function(player: Player)
			handleBuy(player, "donate", prod.robux)
		end)
	end

	-- THANK YOU banner (hidden) + confetti emitters at the header
	local bb = Instance.new("BillboardGui")
	bb.Name = "ThankYou"
	bb.Size = UDim2.fromOffset(520, 110)
	bb.StudsOffsetWorldSpace = Vector3.new(0, 3.2, 0)
	bb.AlwaysOnTop = true
	bb.LightInfluence = 0
	bb.MaxDistance = 160
	bb.Enabled = false
	bb.Adornee = header
	bb.Parent = header
	local big = label(bb, "Text", "THANK YOU!", UDim2.fromScale(1, 0.68), UDim2.fromScale(0, 0), Enum.Font.LuckiestGuy, Palette.UiWarn)
	big.TextStrokeTransparency = 1
	label(bb, "Sub", "", UDim2.fromScale(1, 0.3), UDim2.fromScale(0, 0.7), Enum.Font.FredokaOne, Palette.UiCream)
	board.thanks = bb

	local at = Instance.new("Attachment")
	at.Name = "ConfettiAt"
	at.Position = Vector3.new(0, 0.6, 0)
	at.Parent = header
	board.confetti = {}
	for _, c in CONFETTI_COLORS do
		local e = Instance.new("ParticleEmitter")
		e.Name = "Confetti"
		e.Enabled = false
		e.Color = ColorSequence.new(c)
		e.LightEmission = 0.2
		e.Size = NumberSequence.new(0.35)
		e.Squash = NumberSequence.new(-0.6)
		e.Lifetime = NumberRange.new(2.2, 3.2)
		e.Speed = NumberRange.new(14, 24)
		e.SpreadAngle = Vector2.new(70, 70)
		e.Acceleration = Vector3.new(0, -22, 0)
		e.Drag = 1.2
		e.Rotation = NumberRange.new(0, 360)
		e.RotSpeed = NumberRange.new(-300, 300)
		e.EmissionDirection = Enum.NormalId.Top
		e.Texture = "rbxasset://textures/particles/sparkles_main.dds"
		e.Parent = at
		table.insert(board.confetti, e)
	end

	board.model = model
	model.Parent = station
	renderBoard()
end

local function celebrate(player: Player?, name: string, robux: number)
	Net.notify("all", `THANK YOU {name}! (R$ {robux} donated to Station 67)`, "good")
	if player then
		Popup.show(player, "THANK YOU!", "good", player)
	end
	local bb = board.thanks
	if bb and bb.Parent then
		local big = bb:FindFirstChild("Text") :: TextLabel
		big.Text = `THANK YOU {escape(string.upper(name))}!`;
		(bb:FindFirstChild("Sub") :: TextLabel).Text = `donated R$ {robux}`
		bb.Enabled = true
		local scale = big:FindFirstChildOfClass("UIScale") or Instance.new("UIScale")
		scale.Scale = 0.3
		scale.Parent = big
		TweenService:Create(scale, TweenInfo.new(0.4, Enum.EasingStyle.Back), { Scale = 1 }):Play()
		local shownAt = os.clock()
		bb:SetAttribute("Shown", shownAt)
		task.delay(Cfg.ThankYouSeconds, function()
			if bb.Parent and bb:GetAttribute("Shown") == shownAt then
				bb.Enabled = false
			end
		end)
	end
	for _, e in board.confetti do
		if e.Parent then
			e:Emit(24)
		end
	end
end

------------------------------------------------------------------------------------- receipts

local function ledgerHas(purchaseId: string): (boolean, boolean)
	local ds = ledger
	if not ds then
		return true, memoryLedger[purchaseId] ~= nil
	end
	local ok, res = pcall(function()
		return ds:GetAsync(purchaseId)
	end)
	if not ok then
		warn(`[MonetizationService] ledger read {purchaseId}: {res}`)
		return false, false
	end
	return true, res ~= nil
end

local function ledgerPut(purchaseId: string, record: { [string]: any }): boolean
	record.at = os.time()
	memoryLedger[purchaseId] = record
	local ds = ledger
	if not ds then
		return true
	end
	local ok, err = pcall(function()
		ds:SetAsync(purchaseId, record)
	end)
	if not ok then
		warn(`[MonetizationService] ledger write {purchaseId}: {err}`)
	end
	return ok
end

local function donatedOf(player: Player): number
	local Data = services.DataService
	local p = Data and Data:GetProfile(player)
	local d = p and (p :: any).donations
	return if type(d) == "table" and type(d.robux) == "number" then d.robux else 0
end

-- The idempotent receipt flow against a given product list (the real config, or a test list).
local function processReceipt(receipt: any, products: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(tonumber(receipt and receipt.PlayerId) or 0)
	local Data = services.DataService
	local decision, why = Rules.process(receipt, products, {
		ledgerHas = ledgerHas,
		ledgerPut = ledgerPut,
		grant = function(purchaseId: string, robux: number): Rules.GrantResult
			if not player or not Data or type(Data.WaitForProfile) ~= "function" then
				return "absent"
			end
			if not Data:WaitForProfile(player, 10) then
				return "absent"
			end
			local result: Rules.GrantResult = "absent"
			Data:Update(player, function(p: any)
				result = if Schema.addDonation(p, purchaseId, robux) then "applied" else "duplicate"
			end)
			return result
		end,
		save = function(): boolean
			if not player or not Data or type(Data.Save) ~= "function" then
				return false
			end
			return Data:Save(player)
		end,
	})
	if decision ~= "Granted" then
		Telemetry.count("monetization_receipt_retries")
		warn(`[MonetizationService] receipt {tostring(receipt and receipt.PurchaseId)} not processed yet: {why}`)
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	if why == "applied" and player then
		local product = Rules.product(products, receipt.ProductId)
		local robux = if product then product.robux else 0
		local total = donatedOf(player)
		player:SetAttribute(Cfg.Attr.Donated, total)
		Telemetry.count("monetization_donations")
		Telemetry.count("monetization_robux_donated", robux)
		names[player.UserId] = player.DisplayName
		writeDonor(player.UserId, total)
		celebrate(player, player.DisplayName, robux)
		task.spawn(refreshBoard)
	end
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

------------------------------------------------------------------------------------- players

local function onPlayerAdded(player: Player)
	if owned[player] then
		return
	end
	owned[player] = {}
	for _, key in passKeys() do
		player:GetAttributeChangedSignal(Cfg.Attr.DebugPrefix .. key):Connect(function()
			applyAttrs(player)
		end)
	end
	-- a respawn / new extinguisher re-seeds Foam; keep it full for Unlimited Foam owners
	player:GetAttributeChangedSignal("Foam"):Connect(function()
		if player:GetAttribute(attrFor("UnlimitedFoam")) == true then
			local size = (player:GetAttribute("FoamSize") :: number?) or ToolConfig.FoamSize
			local foam = player:GetAttribute("Foam")
			if type(foam) == "number" and foam < size then
				player:SetAttribute("Foam", size)
			end
		end
	end)
	applyAttrs(player)
	task.spawn(checkOwnership, player)
end

local function onProfileLoaded(player: Player)
	local total = donatedOf(player)
	if total > 0 then
		player:SetAttribute(Cfg.Attr.Donated, total)
		names[player.UserId] = player.DisplayName
		task.spawn(writeDonor, player.UserId, total) -- heals a missed board write
	end
end

---------------------------------------------------------------------------------------- boot

function MonetizationService:Init(all: { [string]: any })
	services = all
end

function MonetizationService:Start()
	local Data = services.DataService
	persistent = Data ~= nil and type(Data.IsPersistent) == "function" and Data:IsPersistent()
	if persistent then
		pcall(function()
			ledger = DataStoreService:GetDataStore(Cfg.LedgerStore)
			donorStore = DataStoreService:GetOrderedDataStore(Cfg.DonorStore)
		end)
	end

	local buy = Net.event("Monetization", "Buy")
	openRemote = Net.event("Monetization", "Open")
	Net.onServer(buy, { rate = 1, burst = 3 }, handleBuy)

	MarketplaceService.PromptGamePassPurchaseFinished:Connect(onPassPurchaseFinished)
	MarketplaceService.ProcessReceipt = function(receipt: any): Enum.ProductPurchaseDecision
		local ok, res = pcall(processReceipt, receipt, Cfg.DonationProducts)
		if not ok then
			warn(`[MonetizationService] ProcessReceipt: {res}`)
			return Enum.ProductPurchaseDecision.NotProcessedYet
		end
		return res
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, p in Players:GetPlayers() do
		onPlayerAdded(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		owned[player] = nil
		mirroredPremiumDebug[player] = nil
	end)
	if Data and Data.ProfileLoaded then
		Data.ProfileLoaded:Connect(onProfileLoaded)
		for _, p in Players:GetPlayers() do
			if Data:GetProfile(p) then
				onProfileLoaded(p)
			end
		end
	end

	local B = Cfg.Board
	local Map = services.MapService
	if Map then
		if Map.LocationBuilt then
			Map.LocationBuilt:Connect(function(model: Model, id: string)
				if id == B.LocationId then
					buildBoard(model)
				end
			end)
		end
		local existing = type(Map.GetLocation) == "function" and Map:GetLocation(B.LocationId)
		if existing then
			buildBoard(existing)
		end
	end

	task.wait(4)
	while true do
		local ok, err = pcall(refreshBoard)
		if not ok then
			warn(`[MonetizationService] board refresh: {err}`)
		end
		task.wait(math.max(15, Cfg.DonorRefreshSeconds))
	end
end

----------------------------------------------------------------------------------- test hooks

-- Calls the real receipt flow with a fake receipt for a fake product worth `robux` (never a real id).
function MonetizationService:_fakeReceipt(player: Player, robux: number, purchaseId: string?): string
	local fakeId = 990000000 + math.floor(robux)
	local products = { { id = fakeId, robux = math.floor(robux) } }
	local receipt = {
		PurchaseId = purchaseId or `test-{os.clock()}`,
		PlayerId = player.UserId,
		ProductId = fakeId,
		CurrencySpent = robux,
		PlaceIdWherePurchased = game.PlaceId,
	}
	local res = processReceipt(receipt, products)
	return `{res.Name}:donated={donatedOf(player)}`
end

function MonetizationService:_owns(player: Player): string
	local out = {}
	for _, key in passKeys() do
		table.insert(out, `{key}={owns(player, key)}`)
	end
	return table.concat(out, ",")
end

function MonetizationService:_board(): string
	refreshBoard()
	local out = {}
	for i, r in topRows do
		table.insert(out, `{i}.{r.name}:{r.robux}`)
	end
	return table.concat(out, " ")
end

function MonetizationService:_selftest(): (boolean, string)
	local hasBoard = board.model ~= nil and board.model.Parent ~= nil
	return hasBoard, `board={hasBoard} persistent={persistent} passes={#passKeys()}`
end

return MonetizationService
