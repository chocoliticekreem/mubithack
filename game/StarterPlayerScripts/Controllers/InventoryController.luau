--!strict
-- InventoryController [owner: Inventory]. Client side of the physical inventory (InventoryService):
--   * hides the Roblox Backpack (StarterGui:SetCoreGuiEnabled(Backpack, false))
--   * chunky hotbar bottom-centre: HAND / BACK / CARRY slots from Player attrs InvHand, InvBack,
--     InvCarry, with foam / air gauges (Foam+FoamSize, OxygenAir); the hose has no gauge (endless water)
--   * input (bound only while you have something, so Rescue/Vehicle keep G and Q otherwise):
--       G drop (Inventory/Drop), hold Q throw with a charge meter (Inventory/Throw(cameraLook, charge)),
--       1 / 2 swap hand <-> back (Inventory/Swap). Gamepad: B drop, L1 throw, DPadUp swap. Tapping the
--       HAND or BACK tile swaps too. The hose swaps like anything else: on your back its line stays out.
--     (lobby emotes live on Z / X / C in SquadController, so 1 / 2 are inventory-only)
--   * the hotbar hides while you're seated (the truck key-hint bar takes the bottom centre)
--   * phones / tablets (InputHints touch): the tiles grow to at least Cfg.TouchTilePx screen px (UiKit's
--     0.55 phone scale made them 40 px), the row slides left so it never sits under the thumb buttons
--     (ThumbLayout.clusterLeft), and the CARRY tile only shows while you carry something. Tap HAND / BACK
--     = swap, so tapping what's on your back puts it in your hand.
--   * relabels the truck reel prompt locally (Grab / Stow Hose); every prompt's "[E] Grab Axe" sticker
--     and yellow outline are PromptController's
--   * Inventory/Fx world pops: GRAB!, BONK!, Butterfingers!, YEET!
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("InventoryConfig") :: ModuleScript) :: any
local ItemDefs = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemDefs") :: ModuleScript)
local UiKit = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("UiKit") :: ModuleScript)
local WorldPopup = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("WorldPopup") :: ModuleScript)
local InputHints = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("InputHints") :: ModuleScript) :: any
local ThumbLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("ThumbLayout") :: ModuleScript)

local InventoryController = {}
InventoryController.Priority = 65

local LocalPlayer = Players.LocalPlayer
local controllers: { [string]: any } = {}

type Slot = { frame: Frame, tile: Frame, glyph: TextLabel, name: TextLabel, bar: Frame, fill: Frame, charge: TextLabel }

local slots: { [string]: Slot } = {}
local hotbarRow: Frame? = nil
local touchScale: UIScale? = nil
local chargeFrame: Frame? = nil
local chargeFill: Frame? = nil
local chargeStart: number? = nil
local boundItem = false
local boundSwap = false
local DropR: RemoteEvent? = nil
local ThrowR: RemoteEvent? = nil
local SwapR: RemoteEvent? = nil

local function attr(name: string): string
	local v = LocalPlayer:GetAttribute(name)
	return if type(v) == "string" then v else ""
end

local function num(name: string): number?
	local v = LocalPlayer:GetAttribute(name)
	return if type(v) == "number" then v else nil
end

local function shake(m: number, s: number)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, m, s)
	end
end

-- hotbar --------------------------------------------------------------------------------------------
-- Readable at every UIScale: no text strokes under ~18px (a contextual ink stroke on small text turns
-- it into a dark blob), light text on dark pills, keycaps as cream chips with a Border-mode outline.
local NAME_H = 22

local function chip(parent: Instance, name: string, text: string, size: UDim2, pos: UDim2, bg: Color3, fg: Color3, textSize: number): TextLabel
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Text = text
	l.Size = size
	l.Position = pos
	l.BackgroundColor3 = bg
	l.BackgroundTransparency = 0
	l.BorderSizePixel = 0
	l.Font = Enum.Font.GothamBold
	l.TextSize = textSize
	l.TextColor3 = fg
	l.TextTruncate = Enum.TextTruncate.AtEnd
	l.ZIndex = 4
	UiKit.corner(l, 6)
	local s = Instance.new("UIStroke")
	s.Thickness = 2
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = l
	l.Parent = parent
	return l
end

local function makeSlot(parent: Instance, key: string, label: string, order: number): Slot
	local size = Cfg.HotbarSlotSize
	local frame = Instance.new("Frame")
	frame.Name = key
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.fromOffset(size, size + NAME_H + 4)
	frame.LayoutOrder = order
	frame.Parent = parent
	local tile = UiKit.panel(frame, "Tile", UDim2.fromOffset(size, size), UDim2.fromOffset(0, 0))
	tile.BackgroundColor3 = Palette.UiPanelDark
	tile.BackgroundTransparency = 0.25
	local glyph = UiKit.label(tile, "Glyph", "", UDim2.new(1, -8, 0, 30), UDim2.fromOffset(4, 16), {
		font = UiKit.Header,
		textSize = 26,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 2,
	})
	glyph.TextWrapped = false
	glyph.TextScaled = true
	local sizeLimit = Instance.new("UITextSizeConstraint")
	sizeLimit.MaxTextSize = 26
	sizeLimit.MinTextSize = 8 -- phones (UIScale 0.55): long glyphs need ~9 px in a 44 px tile
	sizeLimit.Parent = glyph
	-- keycap: what this slot's key does (cream chip, ink text, sits on the tile's top edge)
	local keyChip = chip(tile, "Key", label, UDim2.fromOffset(math.max(30, #label * 8 + 12), 18), UDim2.fromOffset(-4, -9), Palette.UiCream, Palette.UiInk, 12)
	-- phones: the SWAP button, no keys; gamepad: D-pad up swaps
	InputHints.setPick(keyChip, label, (string.gsub(label, "^1/2 ", "")), (string.gsub(label, "^1/2 ", "▲ ")))
	local bar = Instance.new("Frame")
	bar.Name = "Gauge"
	-- a pill tucked inside the tile's rounded bottom edge (clear of the 12 px corners + 3 px border), so it
	-- follows the tile's curve instead of butting into it; the fill is clipped to the same pill shape
	bar.Size = UDim2.new(1, -20, 0, 14)
	bar.Position = UDim2.new(0, 10, 1, -21)
	bar.BackgroundColor3 = Palette.UiInk
	bar.BorderSizePixel = 0
	bar.Visible = false
	bar.ZIndex = 3
	bar.Parent = tile
	local pill = UDim.new(0.5, 0)
	local bc = Instance.new("UICorner")
	bc.CornerRadius = pill
	bc.Parent = bar
	local bs = Instance.new("UIStroke")
	bs.Thickness = 1.5
	bs.Color = Palette.UiCream
	bs.Transparency = 0.35
	bs.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	bs.Parent = bar
	local clip = Instance.new("CanvasGroup")
	clip.Name = "Clip"
	clip.Size = UDim2.fromScale(1, 1)
	clip.BackgroundTransparency = 1
	clip.ZIndex = 3
	clip.Parent = bar
	local cc = Instance.new("UICorner")
	cc.CornerRadius = pill
	cc.Parent = clip
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Palette.WaterSpray
	fill.BorderSizePixel = 0
	fill.ZIndex = 3
	fill.Parent = clip
	-- charge readout on the gauge ("72%"): cream on the dark track, a thin ink stroke so it reads over the fill
	local charge = Instance.new("TextLabel")
	charge.Name = "Charge"
	charge.BackgroundTransparency = 1
	charge.Size = UDim2.fromScale(1, 1)
	charge.Font = Enum.Font.GothamBlack
	charge.TextSize = 11
	charge.TextColor3 = Color3.new(1, 1, 1)
	charge.TextStrokeColor3 = Palette.UiInk
	charge.TextStrokeTransparency = 0.2
	charge.Text = ""
	charge.ZIndex = 4
	charge.Parent = bar
	-- item name under the tile: light text on a dark pill
	local name = chip(frame, "Name", "", UDim2.new(1, 16, 0, NAME_H), UDim2.new(0, -8, 0, size + 4), Palette.UiPanelDark, Palette.UiCream, 13)
	name.BackgroundTransparency = 0.1
	local nameStroke = name:FindFirstChildOfClass("UIStroke")
	if nameStroke then
		nameStroke.Thickness = 1
		nameStroke.Transparency = 0.4
	end
	return { frame = frame, tile = tile, glyph = glyph, name = name, bar = bar, fill = fill, charge = charge }
end

local function buildHotbar()
	local gui = UiKit.screen("InventoryHud", 6)
	local row = Instance.new("Frame")
	row.Name = "Hotbar"
	row.AnchorPoint = Vector2.new(0.5, 1)
	row.Position = UDim2.new(0.5, 0, 1, -4) -- below HudController's toast stack (bottom -100)
	row.Size = UDim2.fromOffset(Cfg.HotbarSlotSize * 3 + 40, Cfg.HotbarSlotSize + NAME_H + 4)
	row.BackgroundTransparency = 1
	row.Parent = gui
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 20)
	layout.Parent = row
	local ts = Instance.new("UIScale")
	ts.Name = "TouchScale"
	ts.Parent = row
	touchScale = ts
	slots.hand = makeSlot(row, "Hand", "HAND", 1)
	slots.back = makeSlot(row, "Back", "1/2 SWAP", 2)
	slots.carry = makeSlot(row, "Carry", "CARRY", 3)
	-- tap (or click) the HAND or BACK tile = swap, same as 1 / 2 / D-pad up / the SWAP button (phones:
	-- tap the hose tile to bring it back off your back)
	for _, key in { "hand", "back" } do
		local tap = Instance.new("TextButton")
		tap.Name = "Tap"
		tap.Text = ""
		tap.BackgroundTransparency = 1
		tap.Size = UDim2.fromScale(1, 1)
		tap.Selectable = false
		tap.ZIndex = 6
		tap.Parent = slots[key].tile
		tap.Activated:Connect(function()
			if SwapR and (attr("InvHand") ~= "" or attr("InvBack") ~= "") then
				SwapR:FireServer()
			end
		end)
	end
	hotbarRow = row
	-- world markers / edge arrows stay off it (ClientLib/HudLayout)
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.reserve(row)
	-- throw charge meter, above the hotbar
	local charge = Instance.new("Frame")
	charge.Name = "Charge"
	charge.AnchorPoint = Vector2.new(0.5, 1)
	charge.Position = UDim2.new(0.5, 0, 1, -(Cfg.HotbarSlotSize + NAME_H + 16))
	charge.Size = UDim2.fromOffset(240, 18)
	charge.BackgroundColor3 = Palette.UiInk
	charge.Visible = false
	charge.Parent = gui
	UiKit.corner(charge, 8)
	UiKit.stroke(charge, 3, Palette.UiCream)
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = Palette.FireBody
	fill.BorderSizePixel = 0
	fill.Parent = charge
	UiKit.corner(fill, 8)
	UiKit.label(charge, "Yeet", "YEET POWER", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0), {
		font = UiKit.Header,
		textSize = 14,
		color = Palette.UiCream,
		stroke = true,
	})
	chargeFrame, chargeFill = charge, fill
end

local lastShown: { [string]: string } = {}

local function gauge(id: string, slot: string?): (number?, Color3)
	if id == "Extinguisher" then
		-- each extinguisher has its own charge: the one on your back reads FoamBack
		local f, size = num(if slot == "back" then "FoamBack" else "Foam"), num("FoamSize")
		return if f and size and size > 0 then f / size else nil, Palette.SmokeWhite
	elseif id == "OxygenTank" then
		local a = num("OxygenAir")
		return if a then a / math.max(1, Cfg.OxygenAir) else nil, Color3.fromHex("#2A9D8F")
	end
	return nil, Palette.WaterSpray
end

local function paint(key: string, id: string, isProp: boolean)
	local s = slots[key]
	if not s then
		return
	end
	local def = ItemDefs.get(id)
	if id == "" then
		s.glyph.Text = ""
		s.name.Text = if key == "hand" then "empty" elseif key == "back" then "nothing" else "nothing"
		s.name.TextColor3 = Color3.fromRGB(170, 160, 150)
		s.tile.BackgroundColor3 = Palette.UiPanelDark
		s.tile.BackgroundTransparency = 0.45
		s.bar.Visible = false
		s.charge.Text = ""
	else
		s.glyph.Text = if def then def.short elseif isProp then "PROP" else string.upper(id)
		s.name.Text = if def then def.name else id
		s.name.TextColor3 = Palette.UiCream
		s.tile.BackgroundColor3 = if def then Color3.fromHex(def.color) else Palette.FloorLineYellow
		s.tile.BackgroundTransparency = 0
		local frac, color = gauge(id, key)
		s.bar.Visible = frac ~= nil
		if id == "Extinguisher" and LocalPlayer:GetAttribute("Pass_UnlimitedFoam") == true then
			-- Unlimited Foam pass (MonetizationService): a full bar and a small infinity sign
			s.bar.Visible = true
			s.fill.Size = UDim2.fromScale(1, 1)
			s.fill.BackgroundColor3 = color
			s.charge.Text = "∞"
			s.charge.TextSize = 20
		elseif frac then
			s.charge.TextSize = 11
			s.fill.Size = UDim2.fromScale(math.clamp(frac, 0, 1), 1)
			s.fill.BackgroundColor3 = if frac < 0.2 then Palette.UiRed else color
			s.charge.Text = `{math.floor(math.clamp(frac, 0, 1) * 100 + 0.5)}%`
		else
			s.charge.Text = ""
		end
	end
	if lastShown[key] ~= id then
		lastShown[key] = id
		if id ~= "" then
			UiKit.punch(s.tile, 0.25)
		end
	end
end

-- touch: thumb-sized tiles, clear of the thumb buttons; keyboard / gamepad: exactly as before
local function fitTouch()
	local row, ts = hotbarRow, touchScale
	if not row or not ts then
		return
	end
	local touch = InputHints.isTouch()
	local carry = slots.carry
	if carry then
		carry.frame.Visible = not touch or attr("InvCarry") ~= ""
	end
	local gui = row:FindFirstAncestorOfClass("ScreenGui")
	local vs = gui and gui:FindFirstChild("ViewportScale")
	local k = if vs and vs:IsA("UIScale") then vs.Scale else 1
	local want = tonumber(Cfg.TouchTilePx) or 60
	local s = if touch then math.max(1, want / math.max(1, Cfg.HotbarSlotSize * k)) else 1
	if math.abs(ts.Scale - s) > 0.001 then
		ts.Scale = s
	end
	local shift = 0
	if touch then
		local n = if carry and carry.frame.Visible then 3 else 2
		local width = (Cfg.HotbarSlotSize * n + 20 * (n - 1)) * s * k -- screen px
		local cam = workspace.CurrentCamera
		local vpX = if cam then cam.ViewportSize.X else 1280
		local right = vpX / 2 + width / 2
		local limit = ThumbLayout.clusterLeft() - 10
		if right > limit then
			shift = math.max(8 + width / 2 - vpX / 2, limit - right) -- never off the left edge
		end
	end
	local want2 = UDim2.new(0.5, math.floor(shift / k + 0.5), 1, -4)
	if row.Position ~= want2 then
		row.Position = want2
	end
	local cf = chargeFrame
	if cf then
		cf.Position = UDim2.new(0.5, math.floor(shift / k + 0.5), 1, -math.floor((Cfg.HotbarSlotSize + NAME_H + 4) * s + 12))
	end
end

local function refreshHud()
	paint("hand", attr("InvHand"), false)
	paint("back", attr("InvBack"), false)
	paint("carry", attr("InvCarry"), true)
	fitTouch()
end

-- input ----------------------------------------------------------------------------------------------

local function chargeOf(): number
	if not chargeStart then
		return 0
	end
	return math.clamp((os.clock() - chargeStart) / math.max(0.05, Cfg.ThrowChargeSeconds), 0, 1)
end

local function hasItem(): boolean
	return attr("InvHand") ~= "" or attr("InvCarry") ~= ""
end

-- Touch buttons: never unbind an action while its button is held. Pressing DROP drops the item, the
-- InvHand attr clears and rebind() used to unbind InvDrop mid-press; the button's End then hit an
-- unbound action ("ContextActionService::CallFunction does not have a function for InvDrop" /
-- "could not find the function passed in"). Held actions stay bound until released (then rebind).
local held: { [string]: boolean } = {}
local rebind: () -> ()

local function track(name: string, state: Enum.UserInputState)
	if state == Enum.UserInputState.Begin then
		held[name] = true
	elseif held[name] and (state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel) then
		held[name] = nil
		task.defer(rebind) -- after this callback returns, never from inside it
	end
end

-- the same key always does the same thing: with a person in your arms G / Q drop / throw THEM, whichever
-- controller bound last (both sink the key)
local function carryingPerson(): boolean
	local c = LocalPlayer:GetAttribute(Names.Attr.Carrying)
	return type(c) == "string" and c ~= ""
end

local function onDrop(n: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	track(n, state)
	if not hasItem() or carryingPerson() then
		return Enum.ContextActionResult.Pass -- carrying someone: G / Q are always RescueController's
	end
	if state == Enum.UserInputState.Begin and DropR then
		DropR:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function onThrow(n: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	track(n, state)
	if not hasItem() or carryingPerson() then
		chargeStart = nil
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin then
		chargeStart = os.clock()
	elseif state == Enum.UserInputState.End and chargeStart then
		local c = chargeOf()
		chargeStart = nil
		local cam = workspace.CurrentCamera
		local look = if cam then cam.CFrame.LookVector else Vector3.new(0, 0, -1)
		if ThrowR then
			ThrowR:FireServer(look, c)
		end
		shake(0.25 + 0.35 * c, 0.2)
	elseif state == Enum.UserInputState.Cancel then
		chargeStart = nil
	end
	return Enum.ContextActionResult.Sink
end

local function onSwap(n: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	track(n, state)
	if attr("InvHand") == "" and attr("InvBack") == "" then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin and SwapR then
		SwapR:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

-- Fewer buttons when they can't matter (phones: "too many buttons" on the first screens): no DROP /
-- THROW / SWAP while you sit in a truck (the truck's own OUT / SIREN / HONK are what you need) or during
-- the training fire (just SPRAY).
local function quietSlots(): boolean
	local char = LocalPlayer.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum and hum.SeatPart ~= nil then
		return true
	end
	return LocalPlayer:GetAttribute("FirstFire") == "burning"
end

-- Phones, until the first call is done: no DROP / THROW buttons either (they popped up the moment the
-- panda was saved, in the same second as the first-call card, LEVEL 2! and GO NOW). Touch only: the keys
-- G / Q stay bound on keyboard and gamepad.
local function newbieTouch(): boolean
	return InputHints.isTouch() and LocalPlayer:GetAttribute("FirstCallDone") == false
end

function rebind()
	local quiet = quietSlots()
	local wantItem = hasItem() and not quiet and not newbieTouch()
	if wantItem and not boundItem then
		ContextActionService:BindAction("InvDrop", onDrop, true, Enum.KeyCode.G, Enum.KeyCode.ButtonB)
		ContextActionService:BindAction("InvThrow", onThrow, true, Enum.KeyCode.Q, Enum.KeyCode.ButtonL1)
		ContextActionService:SetTitle("InvDrop", "DROP")
		ContextActionService:SetTitle("InvThrow", "THROW")
		-- touch: one thumb cluster around the jump button (ClientLib/ThumbLayout), clear of the squad strip
		ThumbLayout.place("InvDrop", "upleft", onDrop)
		ThumbLayout.place("InvThrow", "left", onThrow)
		boundItem = true
	elseif not wantItem and boundItem and not held.InvDrop and not held.InvThrow then
		ThumbLayout.forget("InvDrop")
		ThumbLayout.forget("InvThrow")
		ContextActionService:UnbindAction("InvDrop")
		ContextActionService:UnbindAction("InvThrow")
		boundItem = false
		chargeStart = nil
	end
	local wantSwap = (attr("InvHand") ~= "" or attr("InvBack") ~= "") and not quiet
	if wantSwap and not boundSwap then
		ContextActionService:BindAction("InvSwap", onSwap, true, Enum.KeyCode.Two, Enum.KeyCode.One, Enum.KeyCode.DPadUp)
		ContextActionService:SetTitle("InvSwap", "SWAP")
		ThumbLayout.place("InvSwap", "above", onSwap)
		boundSwap = true
	elseif not wantSwap and boundSwap and not held.InvSwap then
		ThumbLayout.forget("InvSwap")
		ContextActionService:UnbindAction("InvSwap")
		boundSwap = false
	end
end

-- Truck reels keep their builder's default prompt; only the text changes, locally, with what you hold.
local function relabelReels()
	local hose = attr("InvHand") == "Hose" or attr("InvBack") == "Hose" -- slung on your back counts
	local text = if hose then "Stow Hose" else "Grab Hose" -- holding the extinguisher: swaps it for the hose
	local function set(p: Instance?)
		if p and p:IsA("ProximityPrompt") and p:GetAttribute("InvReel") then
			p.ActionText = text -- an open sticker follows (PromptController)
		end
	end
	for _, reel in CollectionService:GetTagged(Names.Tag.TruckRefill) do
		set(reel:FindFirstChildOfClass("ProximityPrompt"))
	end
	-- the [T] any-side hose prompt on each truck's chassis (InventoryService hookTruckHose)
	for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
		local base = truck:IsA("Model") and truck.PrimaryPart
		set(base and base:FindFirstChild("TruckHosePrompt"))
	end
end

-- world pops -----------------------------------------------------------------------------------------
local POP_TEXT: { [string]: string } = {
	grab = "GRAB!",
	drop = "plonk",
	throw = "YEET!",
	bonk = "BONK!",
	fumble = "Butterfingers!",
	stow = "click",
}

local function worldPop(kind: string, pos: Vector3, _text: string)
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - pos).Magnitude > 120 then
		return
	end
	local big = kind == "bonk" or kind == "fumble"
	-- subtle world text (ClientLib/WorldPopup: caps, dedupe, feedback setting); routine grab/drop/stow
	-- are sound-only now
	if kind ~= "grab" and kind ~= "drop" and kind ~= "stow" then
		WorldPopup.show(WorldPopup.subjectAt(pos, 4), POP_TEXT[kind] or kind, {
			color = if kind == "bonk" then Palette.FireBody else nil,
			big = big,
		})
	end
	local sound = if kind == "grab" then Cfg.SoundGrab
		elseif kind == "drop" then Cfg.SoundDrop
		elseif kind == "throw" then Cfg.SoundThrow
		elseif kind == "bonk" then Cfg.SoundBonk
		else ""
	if sound ~= "" then
		UiKit.sound(sound, 0.7, 0.9 + math.random() * 0.2)
	end
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if big and root and (root.Position - pos).Magnitude < 8 then
		shake(0.6, 0.35)
	end
end

-- controller -----------------------------------------------------------------------------------------
local function hideBackpack()
	for _ = 1, 10 do
		local ok = pcall(function()
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
			-- the squad strip (HudController) replaces the Roblox player list, which overlaid the top right
			StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.PlayerList, false)
		end)
		if ok then
			return
		end
		task.wait(0.5)
	end
end

function InventoryController:Init(all: { [string]: any })
	controllers = all
end

function InventoryController:Start()
	task.spawn(hideBackpack)
	buildHotbar()
	refreshHud()
	InputHints.onChanged(function()
		task.defer(fitTouch)
	end)
	local cam = workspace.CurrentCamera
	if cam then
		cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
			task.defer(fitTouch)
		end)
	end
	task.delay(1, fitTouch) -- Roblox's jump button exists by now (ThumbLayout sizes the cluster from it)
	for _, name in { "InvHand", "InvBack", "InvCarry" } do
		LocalPlayer:GetAttributeChangedSignal(name):Connect(function()
			refreshHud()
			rebind()
			relabelReels()
		end)
	end
	for _, name in { "Foam", "FoamBack", "FoamSize", "OxygenAir", "Pass_UnlimitedFoam" } do
		LocalPlayer:GetAttributeChangedSignal(name):Connect(refreshHud)
	end
	LocalPlayer:GetAttributeChangedSignal("FirstFire"):Connect(rebind)
	LocalPlayer:GetAttributeChangedSignal("FirstCallDone"):Connect(rebind)
	InputHints.onChanged(function()
		task.defer(rebind)
	end)
	local function watchSeat(char: Model)
		local hum = char:WaitForChild("Humanoid", 10)
		if hum and hum:IsA("Humanoid") then
			hum:GetPropertyChangedSignal("SeatPart"):Connect(rebind)
			rebind()
		end
	end
	if LocalPlayer.Character then
		task.spawn(watchSeat, LocalPlayer.Character)
	end
	LocalPlayer.CharacterAdded:Connect(watchSeat)
	rebind()
	relabelReels()
	CollectionService:GetInstanceAddedSignal(Names.Tag.TruckRefill):Connect(function()
		task.delay(2.5, relabelReels) -- after InventoryService adds the chassis [T] prompt
	end)

	RunService.RenderStepped:Connect(function()
		-- seated (truck cab / tailboard): the hotbar would sit under VehicleController's key-hint bar
		local row = hotbarRow
		if row then
			local char = LocalPlayer.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local seated = hum ~= nil and hum.SeatPart ~= nil
			if row.Visible == seated then
				row.Visible = not seated
			end
		end
		local cf, fill = chargeFrame, chargeFill
		if not cf or not fill then
			return
		end
		if chargeStart then
			cf.Visible = true
			local c = chargeOf()
			fill.Size = UDim2.fromScale(c, 1)
			fill.BackgroundColor3 = if c >= 1 then Palette.UiGood else Palette.FireBody -- full = ready (green), not danger
		else
			cf.Visible = false
		end
	end)

	-- remotes are declared by InventoryService in its Start; wait off the main thread
	task.spawn(function()
		local ok, err = pcall(function()
			DropR = Net.event("Inventory", "Drop")
			ThrowR = Net.event("Inventory", "Throw")
			SwapR = Net.event("Inventory", "Swap")
			local Fx = Net.event("Inventory", "Fx")
			Fx.OnClientEvent:Connect(function(kind: any, pos: any, text: any)
				if type(kind) == "string" and typeof(pos) == "Vector3" then
					worldPop(kind, pos, if type(text) == "string" then text else "")
				end
			end)
		end)
		if not ok then
			warn(`[InventoryController] remotes: {err}`)
		end
	end)
end

return InventoryController
