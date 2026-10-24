--!strict
-- InventoryController [owner: Inventory]. Client side of the physical inventory (InventoryService):
--   * hides the Roblox Backpack (StarterGui:SetCoreGuiEnabled(Backpack, false))
--   * chunky hotbar bottom-centre: HAND / BACK / CARRY slots from Player attrs InvHand, InvBack,
--     InvCarry, with water / foam / air gauges (Water+TankSize, Foam+FoamSize, OxygenAir)
--   * input (bound only while you have something, so Rescue/Vehicle keep G and Q otherwise):
--       G drop (Inventory/Drop), hold Q throw with a charge meter (Inventory/Throw(cameraLook, charge)),
--       1 / 2 swap hand <-> back (Inventory/Swap). Gamepad: B drop, L1 throw, DPadUp swap.
--     (lobby emotes live on Z / X / C in SquadController, so 1 / 2 are inventory-only)
--   * the hotbar hides while you're seated (the truck key-hint bar takes the bottom centre)
--   * draws every prompt with attr InvPrompt (Style Custom) as a chunky "[E] Grab Axe" sticker plus a
--     yellow Highlight on the item; relabels the truck reel prompt locally (Grab / Stow Hose, Refill Foam)
--   * Inventory/Fx world pops: GRAB!, BONK!, Butterfingers!, YEET!, POP!, CLUNK! (supply line on),
--     RIIIP! (a supply line torn off by a truck); "supplywarn" = the driver's big STILL HOOKED UP banner + beep
--   * truck supply intakes (prompt attr InvIntake): only enabled locally while you hold a supply coupling
--     ("Hook up supply line") or that truck has a line on ("Unhook supply line")
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
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
local AudioOk, Audio = pcall(function()
	return require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AudioConfig") :: ModuleScript) :: any
end)
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
local chargeFrame: Frame? = nil
local chargeFill: Frame? = nil
local chargeStart: number? = nil
local boundItem = false
local boundSwap = false
local shown: { [ProximityPrompt]: { gui: BillboardGui, hl: Highlight? } } = {}

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
	sizeLimit.MinTextSize = 12
	sizeLimit.Parent = glyph
	-- keycap: what this slot's key does (cream chip, ink text, sits on the tile's top edge)
	local keyChip = chip(tile, "Key", label, UDim2.fromOffset(math.max(30, #label * 8 + 12), 18), UDim2.fromOffset(-4, -9), Palette.UiCream, Palette.UiInk, 12)
	InputHints.setPick(keyChip, label, (string.gsub(label, "^1/2 ", ""))) -- phones: the SWAP button, no keys
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
	slots.hand = makeSlot(row, "Hand", "HAND", 1)
	slots.back = makeSlot(row, "Back", "1/2 SWAP", 2)
	slots.carry = makeSlot(row, "Carry", "CARRY", 3)
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
	if id == "Hose" then
		local w, size = num(Names.Attr.Water), num(Names.Attr.TankSize)
		return if w and size and size > 0 then w / size else nil, Palette.WaterSpray
	elseif id == "Extinguisher" then
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

local function refreshHud()
	paint("hand", attr("InvHand"), false)
	paint("back", attr("InvBack"), false)
	paint("carry", attr("InvCarry"), true)
end

-- input ----------------------------------------------------------------------------------------------
local DropR: RemoteEvent? = nil
local ThrowR: RemoteEvent? = nil
local SwapR: RemoteEvent? = nil

local function chargeOf(): number
	if not chargeStart then
		return 0
	end
	return math.clamp((os.clock() - chargeStart) / math.max(0.05, Cfg.ThrowChargeSeconds), 0, 1)
end

local function hasItem(): boolean
	return attr("InvHand") ~= "" or attr("InvCarry") ~= ""
end

local function onDrop(_n: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	if not hasItem() then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin and DropR then
		DropR:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function onThrow(_n: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	if not hasItem() then
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

local function onSwap(_n: string, state: Enum.UserInputState, _i: InputObject): Enum.ContextActionResult
	if attr("InvHand") == "" and attr("InvBack") == "" then
		return Enum.ContextActionResult.Pass
	end
	if state == Enum.UserInputState.Begin and SwapR then
		SwapR:FireServer()
	end
	return Enum.ContextActionResult.Sink
end

local function rebind()
	local wantItem = hasItem()
	if wantItem and not boundItem then
		ContextActionService:BindAction("InvDrop", onDrop, true, Enum.KeyCode.G, Enum.KeyCode.ButtonB)
		ContextActionService:BindAction("InvThrow", onThrow, true, Enum.KeyCode.Q, Enum.KeyCode.ButtonL1)
		ContextActionService:SetTitle("InvDrop", "DROP")
		ContextActionService:SetTitle("InvThrow", "THROW")
		-- touch: one thumb cluster around the jump button (ClientLib/ThumbLayout), clear of the squad strip
		ThumbLayout.place("InvDrop", "upleft")
		ThumbLayout.place("InvThrow", "left")
		boundItem = true
	elseif not wantItem and boundItem then
		ThumbLayout.forget("InvDrop")
		ThumbLayout.forget("InvThrow")
		ContextActionService:UnbindAction("InvDrop")
		ContextActionService:UnbindAction("InvThrow")
		boundItem = false
		chargeStart = nil
	end
	local wantSwap = attr("InvHand") ~= "" or attr("InvBack") ~= ""
	if wantSwap and not boundSwap then
		ContextActionService:BindAction("InvSwap", onSwap, true, Enum.KeyCode.Two, Enum.KeyCode.One, Enum.KeyCode.DPadUp)
		ContextActionService:SetTitle("InvSwap", "SWAP")
		ThumbLayout.place("InvSwap", "above")
		boundSwap = true
	elseif not wantSwap and boundSwap then
		ThumbLayout.forget("InvSwap")
		ContextActionService:UnbindAction("InvSwap")
		boundSwap = false
	end
end

-- prompts --------------------------------------------------------------------------------------------
local function promptTarget(prompt: ProximityPrompt): Instance?
	local parent = prompt.Parent
	if not parent then
		return nil
	end
	local display = parent:FindFirstChild("InvDisplay")
	if display then
		return display
	end
	local model = parent.Parent
	if model and model:IsA("Model") and model:HasTag("InventoryItem") then
		return model
	end
	if model and model:IsA("Model") and model.PrimaryPart == parent then
		return model
	end
	return parent
end

local function keyText(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		return string.gsub(prompt.GamepadKeyCode.Name, "Button", "")
	elseif inputType == Enum.ProximityPromptInputType.Touch then
		return "TAP"
	end
	return prompt.KeyboardKeyCode.Name
end

local function showPrompt(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if not prompt:GetAttribute("InvPrompt") or shown[prompt] then
		return
	end
	local adornee = prompt.Parent
	if not adornee or not adornee:IsA("BasePart") then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "InvPromptGui"
	gui.Adornee = adornee
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(260, 56)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	gui.MaxDistance = 40
	gui.ResetOnSpawn = false
	local panel = UiKit.panel(gui, "Panel", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	panel.BackgroundColor3 = Palette.UiCream
	local key = UiKit.label(panel, "Key", keyText(prompt, inputType), UDim2.fromOffset(44, 40), UDim2.fromOffset(8, 8), {
		font = UiKit.Header,
		textSize = 24,
		color = Palette.UiCream,
	})
	key.BackgroundTransparency = 0
	key.BackgroundColor3 = Palette.UiInk
	UiKit.corner(key, 8)
	UiKit.label(panel, "Action", prompt.ActionText, UDim2.new(1, -66, 1, 0), UDim2.fromOffset(60, 0), {
		font = UiKit.Header,
		textSize = 22,
		align = Enum.TextXAlignment.Left,
	})
	if inputType == Enum.ProximityPromptInputType.Touch then
		local tap = Instance.new("TextButton")
		tap.Name = "Tap"
		tap.BackgroundTransparency = 1
		tap.Text = ""
		tap.Size = UDim2.fromScale(1, 1)
		tap.ZIndex = 5
		tap.Parent = panel
		gui.Active = true
		tap.Activated:Connect(function()
			prompt:InputHoldBegin()
			task.defer(function()
				prompt:InputHoldEnd()
			end)
		end)
	end
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	UiKit.pop(panel, 0.2)
	local hl: Highlight? = nil
	local target = promptTarget(prompt)
	if target and (target:IsA("Model") or target:IsA("BasePart")) then
		local h = Instance.new("Highlight")
		h.Name = "InvHighlight"
		h.Adornee = target
		h.FillColor = Cfg.HighlightColor
		h.FillTransparency = 0.7
		h.OutlineColor = Cfg.HighlightColor
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Parent = gui
		hl = h
	end
	shown[prompt] = { gui = gui, hl = hl }
end

local function hidePrompt(prompt: ProximityPrompt)
	local s = shown[prompt]
	if s then
		shown[prompt] = nil
		s.gui:Destroy()
	end
end

-- Truck reels keep their builder's default prompt; only the text changes, locally, with what you hold.
local function relabelReels()
	local hand = attr("InvHand")
	local text = if hand == "Hose" then "Stow Hose" elseif hand == "Extinguisher" then "Refill Foam" else "Grab Hose"
	local function set(p: Instance?)
		if p and p:IsA("ProximityPrompt") and p:GetAttribute("InvReel") then
			p.ActionText = text
			local s = shown[p] -- already on screen: the sticker flips at once (Grab -> Stow Hose)
			local label = s and s.gui:FindFirstChild("Action", true)
			if label and label:IsA("TextLabel") then
				label.Text = text
			end
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

-- Truck supply intakes: the server leaves them on; locally they only show when [R] would do something.
local function truckOfPrompt(p: Instance): Instance?
	local cur = p.Parent
	while cur and cur ~= workspace do
		if cur:HasTag(Names.Tag.Truck) then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function refreshIntakes()
	local holding = attr("InvHand") == "SupplyHose"
	for _, truck in CollectionService:GetTagged(Names.Tag.Truck) do
		local base = truck:IsA("Model") and truck.PrimaryPart
		if not base then
			continue
		end
		local hooked = truck:GetAttribute("SupplyLine") == true
		for _, side in { "L", "R" } do
			local intake = base:FindFirstChild(`SupplyIntake_{side}`)
			local p = intake and intake:FindFirstChild("SupplyIntakePrompt")
			if p and p:IsA("ProximityPrompt") and truckOfPrompt(p) == truck then
				local on = holding or hooked
				if p.Enabled ~= on then
					p.Enabled = on
				end
				local text = if hooked then "Unhook supply line" else "Hook up supply line"
				if p.ActionText ~= text then
					p.ActionText = text
					local sh = shown[p]
					local label = sh and sh.gui:FindFirstChild("Action", true)
					if label and label:IsA("TextLabel") then
						label.Text = text
					end
				end
			end
		end
	end
end

-- The driver of a hooked-up truck: a big red banner across the top and a horn-ish double beep.
local warnGui: ScreenGui? = nil
local warnAt = 0
local function supplyWarn(text: string)
	local now = os.clock()
	if now - warnAt < 1 then
		return
	end
	warnAt = now
	local gui = warnGui
	if not gui or not gui.Parent then
		gui = UiKit.screen("SupplyWarn", 40)
		warnGui = gui
	end
	local g = gui :: ScreenGui
	local old = g:FindFirstChild("Banner")
	if old then
		old:Destroy()
	end
	local panel = UiKit.panel(g, "Banner", UDim2.fromOffset(760, 96), UDim2.new(0.5, 0, 0, 120), Vector2.new(0.5, 0))
	panel.BackgroundColor3 = Palette.UiRed
	-- top-centre stack (ClientLib/HudLayout): under the timer / CALL! card / toasts, never on them
	local HudLayout = require(script.Parent.Parent:WaitForChild("ClientLib"):WaitForChild("HudLayout") :: ModuleScript) :: any
	HudLayout.add("TopCentre", panel, 50)
	HudLayout.flush() -- placed before UiKit.shake records its home position
	UiKit.label(panel, "Text", text, UDim2.new(1, -24, 1, -12), UDim2.fromOffset(12, 6), {
		font = UiKit.Header,
		textSize = 40,
		color = Palette.UiCream,
		stroke = true,
		strokeThickness = 3,
		scaled = true,
	})
	UiKit.pop(panel, 0.25)
	UiKit.shake(panel, 0.5, 8)
	local horn = AudioOk and type(Audio) == "table" and Audio.Sounds and Audio.Sounds.Horn
	local id = if type(horn) == "table" and type(horn.id) == "string" then horn.id else ""
	UiKit.sound(id, 0.9, 1.5)
	task.delay(0.22, function()
		UiKit.sound(id, 0.9, 1.5)
	end)
	shake(0.5, 0.3)
	task.delay(2.2, function()
		if panel.Parent then
			UiKit.tween(panel, 0.25, { BackgroundTransparency = 1 })
			task.delay(0.26, function()
				panel:Destroy()
			end)
		end
	end)
end

local function audioId(name: string): string
	local entry = AudioOk and type(Audio) == "table" and Audio.Sounds and Audio.Sounds[name]
	return if type(entry) == "table" and type(entry.id) == "string" then entry.id else ""
end

-- world pops -----------------------------------------------------------------------------------------
local POP_TEXT: { [string]: string } = {
	grab = "GRAB!",
	drop = "plonk",
	throw = "YEET!",
	bonk = "BONK!",
	fumble = "Butterfingers!",
	supply = "CLUNK! HOOKED UP!",
	unhook = "unhooked",
	snap = "POP!",
	rip = "RIIIP! POP!",
	stow = "click",
}

local function worldPop(kind: string, pos: Vector3, _text: string)
	local cam = workspace.CurrentCamera
	if not cam or (cam.CFrame.Position - pos).Magnitude > 120 then
		return
	end
	local big = kind == "bonk" or kind == "fumble" or kind == "snap" or kind == "rip" or kind == "supply"
	-- subtle world text (ClientLib/WorldPopup: caps, dedupe, feedback setting); routine grab/drop/stow
	-- are sound-only now
	if kind ~= "grab" and kind ~= "drop" and kind ~= "stow" then
		WorldPopup.show(WorldPopup.subjectAt(pos, 4), POP_TEXT[kind] or kind, {
			color = if kind == "bonk" or kind == "snap" or kind == "rip" then Palette.FireBody else nil,
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
	if kind == "supply" then
		UiKit.sound(audioId("Click"), 1, 0.45) -- a low, chunky clunk
	elseif kind == "rip" then
		UiKit.sound(audioId("DoorBreak"), 0.8, 1.3)
		UiKit.sound(audioId("Splash"), 0.9, 0.8)
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
	for _, name in { "InvHand", "InvBack", "InvCarry" } do
		LocalPlayer:GetAttributeChangedSignal(name):Connect(function()
			refreshHud()
			rebind()
			relabelReels()
			refreshIntakes()
		end)
	end
	for _, name in { Names.Attr.Water, Names.Attr.TankSize, "Foam", "FoamBack", "FoamSize", "OxygenAir", "Pass_UnlimitedFoam" } do
		LocalPlayer:GetAttributeChangedSignal(name):Connect(refreshHud)
	end
	rebind()
	relabelReels()
	task.spawn(function()
		while true do
			refreshIntakes() -- trucks come and go, and their SupplyLine attr flips
			task.wait(0.4)
		end
	end)
	CollectionService:GetInstanceAddedSignal(Names.Tag.TruckRefill):Connect(function()
		task.delay(2.5, relabelReels) -- after InventoryService adds the chassis [T] prompt
	end)

	ProximityPromptService.PromptShown:Connect(showPrompt)
	ProximityPromptService.PromptHidden:Connect(hidePrompt)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt)
		local s = shown[prompt]
		local panel = s and s.gui:FindFirstChild("Panel")
		if panel and panel:IsA("Frame") then
			UiKit.punch(panel, 0.3)
		end
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
			fill.BackgroundColor3 = if c >= 1 then Palette.UiRed else Palette.FireBody
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
				if kind == "supplywarn" then
					supplyWarn(if type(text) == "string" and text ~= "" then text else "SUPPLY LINE STILL HOOKED UP!")
					return
				end
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
