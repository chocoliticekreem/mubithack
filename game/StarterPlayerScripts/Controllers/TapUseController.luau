--!strict
-- TapUseController [owner: G3]. Touch (phones / iPads): tap things in the world to use them, and round
-- verb bubbles instead of Roblox's big ProximityPrompt cards.
--   * While InputHints says "touch", every ProximityPrompt is switched to Style Custom + Exclusivity
--     AlwaysShow locally (Roblox draws nothing, and any prompt in reach can be tapped, not just the one
--     OnePerButton picked) and the originals come back on keyboard / gamepad. InventoryController's
--     "[E] Grab Axe" stickers stand down on touch too.
--   * ONE use bubble over the most relevant thing in reach (rescue > pick-ups > the rest, then nearest):
--     a 64 px cream circle with a one-word verb (GRAB, HOSE, FILL, OPEN...) that follows the thing on
--     screen (ScreenGui "TapBubble"). Tap it to use it.
--   * Fire trucks get a SECOND, green IN bubble (ScreenGui "TapBubbleIn") pinned to the door you would get
--     in by: the driver's door while the driver seat is free, else the nearest free crew seat. That bubble
--     is the ONLY way in on touch (Vehicle/Enter on the server). Tapping the truck (body, cab, doors,
--     seats) never seats you: a tap near its hose reel / lockers uses that thing, anywhere else a small
--     "Tap IN to get in" hint shows. The truck's hose prompt (TruckHosePrompt, which lives on the
--     chassis) is drawn and tapped at the reel, not the chassis centre.
--   * HOSE thumb button (ThumbLayout slot "upfar", the T key on touch) while a "Grab Hose" prompt (truck
--     or hydrant) is in reach. It stays up HOSE_LINGER s after the prompt drops out of reach (it used to
--     flicker on / off at the truck's back, where the reach edge is, and a tap landed on a dead button),
--     and a press re-picks the hose then. Truck gear (reel, lockers) is looked for out to GEAR_RANGE, the
--     truck hose prompt's own reach, not the shorter IN range (right behind the reel there was no HOSE).
--   * Truck lockers / gear racks (GRAB) and the hose go straight to the server (Inventory/Take,
--     Inventory/Reel): Roblox ignores InputHoldBegin on a prompt it isn't showing.
--   * Tap the thing itself: a ray from the tap (your own character ignored) and a snap radius, so a
--     fat-finger tap next to an axe still grabs it. In range: it happens (a hold prompt holds for its
--     HoldDuration, with a ring filling). Out of range: a small "walk closer" pop over it.
-- Dev: Player attr ForceTouchUI = true makes a left mouse click act as a tap (Studio has no touch), and
-- InputHintsMode = "touch" (ClientLib/InputHints) puts the whole UI in touch mode.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local VehicleConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("VehicleConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any
local ThumbLayout = require(ClientLib:WaitForChild("ThumbLayout") :: ModuleScript) :: any
local WorldPopup = require(ClientLib:WaitForChild("WorldPopup") :: ModuleScript) :: any

local TapUseController = {}
TapUseController.Priority = 140

local TRUCK_GEAR_TAP = 8 -- studs from the tap point to a truck reel / locker that counts as tapping it

local player = Players.LocalPlayer
local SNAP = 6 -- studs: a tap this close to a prompt's part counts as a tap on it
local REACH_SLACK = 2 -- studs past a prompt's MaxActivationDistance that still count (the server re-checks)
local BUBBLE_PX = 64 -- on screen, never scaled: a thumb-sized target on every phone (>= 64 px)
local HOSE_ACTION = "TapHose"
local HOSE_LINGER = 0.8 -- s the HOSE button stays after its prompt leaves reach (no flicker at the edge)
local GEAR_RANGE = 26 -- studs from a truck's chassis: its gear (hose reel prompt reach 24 + slack) counts
local TOP_BAND = 0.36 -- of the screen height: the top HUD (timer, call / guide cards) lives above this
local TRUCK_HIDDEN = { DoorPrompt = true, SeatPrompt = true }

type Target = {
	kind: string, -- "prompt" | "truck"
	prompt: ProximityPrompt?,
	truck: Model?,
	part: BasePart,
	verb: string,
	rank: number,
	item: string?, -- GRAB / CARRY: what you get ("RUSTY AXE")
}

local shown: { [ProximityPrompt]: boolean } = {}
local origStyle: { [ProximityPrompt]: { style: Enum.ProximityPromptStyle, excl: Enum.ProximityPromptExclusivity } } = {}
local bubble: ScreenGui? = nil
local bubbleTarget: Target? = nil
local inBubble: ScreenGui? = nil
local inTarget: Target? = nil
local hoseTarget: Target? = nil
local hoseLast: Target? = nil
local hoseSeenAt = 0
local hosePlaced = false
local busyUntil = 0

local function count(name: string)
	pcall(function()
		local T = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
		T.count(name, 1)
	end)
end

local function touch(): boolean
	return InputHints.isTouch()
end

local function root(): BasePart?
	local c = player.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function seated(): boolean
	local c = player.Character
	local h = c and c:FindFirstChildOfClass("Humanoid")
	return h ~= nil and h.SeatPart ~= nil
end

local function truckOf(inst: Instance): Model?
	local cur: Instance? = inst
	while cur and cur ~= workspace do
		if cur:IsA("Model") and cur:HasTag(Names.Tag.Truck) then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function partOf(prompt: ProximityPrompt): BasePart?
	local p = prompt.Parent
	if p and p:IsA("BasePart") then
		return p
	elseif p and p:IsA("Attachment") and p.Parent and p.Parent:IsA("BasePart") then
		return p.Parent :: BasePart
	elseif p and p:IsA("Model") then
		return p.PrimaryPart or p:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

local function promptPos(prompt: ProximityPrompt): Vector3?
	local p = prompt.Parent
	if p and p:IsA("Attachment") then
		return p.WorldPosition
	end
	local part = partOf(prompt)
	return part and part.Position
end

-- the truck's hose reel (tagged TruckRefill), where its chassis hose prompt is drawn and tapped
local function reelOf(truck: Model): BasePart?
	for _, r in CollectionService:GetTagged(Names.Tag.TruckRefill) do
		if r:IsA("BasePart") and r:IsDescendantOf(truck) then
			return r
		end
	end
	return nil
end

-- where a prompt is drawn and tapped: its own part, except the chassis-wide truck hose prompt, which
-- belongs to the reel (its centre is the middle of the truck, so taps on the reel used to miss it)
local function anchorOf(prompt: ProximityPrompt): BasePart?
	if prompt.Name == "TruckHosePrompt" then
		local truck = truckOf(prompt)
		local reel = truck and reelOf(truck)
		if reel then
			return reel
		end
	end
	return partOf(prompt)
end

-- one short verb for the bubble
local VERBS: { { string } } = {
	{ "^Grab Hose", "HOSE" }, -- the truck's reel and the street hydrants
	{ "^Grab", "GRAB" },
	{ "^Pick up", "GRAB" }, -- a rescue's Carry prompt says "Pick up" too: verbOf maps it to CARRY first
	{ "^Take", "GRAB" },
	{ "^Carry", "CARRY" },
	{ "^Refill", "FILL" },
	{ "^Open", "OPEN" },
	{ "^Close", "CLOSE" },
	{ "^Break", "BREAK" },
	{ "^Kick", "KICK" },
	{ "^Pick a call", "CALLS" },
	{ "^Change call", "CALLS" },
	{ "^Stow", "STOW" },
	{ "^Drive", "IN" },
	{ "^Ride", "IN" },
	{ "^Hop on", "IN" },
	{ "^Slide", "SLIDE" },
	{ "^Climb", "CLIMB" },
	{ "^Give", "HELP" },
	{ "^Splint", "HELP" },
	{ "^SLAP", "SLAP" },
}

local function verbOf(prompt: ProximityPrompt): string
	if prompt.Name == "Carry" then
		return "CARRY"
	end
	local t = prompt.ActionText
	for _, v in VERBS do
		if string.find(t, v[1]) then
			return v[2]
		end
	end
	local first = string.match(t, "^(%S+)") or "USE"
	first = string.upper(first)
	return if #first <= 6 then first else "USE"
end

-- what the bubble acts on, so kids can tell WHICH thing they grab ("Grab Rusty Axe" -> "RUSTY AXE")
local function itemOf(prompt: ProximityPrompt): string
	-- the action names the item ("Grab Rusty Axe"); ObjectText is only where it is ("Truck"), so it's the fallback
	local rest = string.match(prompt.ActionText, "^Grab%s+(.+)$")
		or string.match(prompt.ActionText, "^Pick up%s+(.+)$")
		or string.match(prompt.ActionText, "^Take%s+(.+)$")
	if rest then
		return string.upper(rest)
	end
	return string.upper(prompt.ObjectText)
end

local function rankOf(prompt: ProximityPrompt): number
	if prompt.Name == "Carry" or prompt:FindFirstAncestorWhichIsA("Model") and prompt:FindFirstAncestorWhichIsA("Model"):HasTag(Names.Tag.Rescuable) then
		return 1
	end
	local t = prompt.ActionText
	if string.find(t, "^Grab") or string.find(t, "^Pick up") or string.find(t, "^Take") or prompt:GetAttribute("InvPrompt") then
		return 3
	end
	return 4
end

local function usable(prompt: ProximityPrompt): boolean
	if not prompt.Enabled or not prompt.Parent or not prompt:IsDescendantOf(workspace) then
		return false
	end
	if TRUCK_HIDDEN[prompt.Name] and truckOf(prompt) then
		return false -- the truck's IN bubble / tap covers its doors and seats
	end
	return true
end

local function promptTarget(prompt: ProximityPrompt): Target?
	local part = anchorOf(prompt)
	if not part or not usable(prompt) then
		return nil
	end
	-- the truck's own reel / lockers rank with the pick-ups (getting IN has its own bubble)
	local rank = if truckOf(prompt) then math.min(rankOf(prompt), 2) else rankOf(prompt)
	local verb = verbOf(prompt)
	return { kind = "prompt", prompt = prompt, part = part, verb = verb, rank = rank, item = if verb == "GRAB" or verb == "CARRY" then itemOf(prompt) else nil }
end

local function freeSeat(s: Instance?): boolean
	return s ~= nil and (s:IsA("Seat") or s:IsA("VehicleSeat")) and (s :: any).Occupant == nil
end

-- The way in that Vehicle/Enter would use: the driver's door while the driver seat is free (anyone may
-- drive), else the nearest free crew seat. nil = the truck is full.
local function entryPart(truck: Model): BasePart?
	local drive = truck:FindFirstChild("DriveSeat")
	if freeSeat(drive) then
		local door = truck:FindFirstChild("Door_L")
		local handle = door and door:FindFirstChild("DoorHandle_L")
		if handle and handle:IsA("BasePart") then
			return handle
		end
		return drive :: BasePart
	end
	local r = root()
	local best: BasePart?, bestD = nil, math.huge
	for i = 1, 5 do
		local s = truck:FindFirstChild(`CrewSeat_{i}`)
		if freeSeat(s) then
			local d = if r then ((s :: BasePart).Position - r.Position).Magnitude else i
			if d < bestD then
				best, bestD = s :: BasePart, d
			end
		end
	end
	return best
end

local function truckTarget(truck: Model): Target?
	local part = entryPart(truck)
	if not part then
		return nil
	end
	return { kind = "truck", truck = truck, part = part, verb = "IN", rank = 2 }
end

local function inReach(t: Target): boolean
	local r = root()
	if not r then
		return false
	end
	if t.kind == "truck" then
		local c = (t.truck :: Model).PrimaryPart
		return c ~= nil and (c.Position - r.Position).Magnitude <= (tonumber(VehicleConfig.TapEnterRange) or 22) - 1
	end
	local pos = promptPos(t.prompt :: ProximityPrompt)
	return pos ~= nil and (pos - r.Position).Magnitude <= (t.prompt :: ProximityPrompt).MaxActivationDistance + REACH_SLACK
end

-- use ------------------------------------------------------------------------------------------------

local function ringOn(gui: ScreenGui?, seconds: number)
	local ring = gui and gui:FindFirstChild("Ring", true) :: Frame?
	if not ring then
		return
	end
	ring.Size = UDim2.fromScale(0, 0)
	ring.Visible = true
	TweenService:Create(ring, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Size = UDim2.fromScale(1, 1) }):Play()
	task.delay(seconds + 0.1, function()
		ring.Visible = false
	end)
end

local function use(t: Target): boolean
	if os.clock() < busyUntil then
		return false
	end
	if not inReach(t) then
		WorldPopup.show(t.part, "walk closer", { mine = true, seconds = 1 })
		return false
	end
	if t.kind == "truck" then
		busyUntil = os.clock() + 0.6
		Net.event("Vehicle", "Enter"):FireServer(t.truck)
		count("tap_truck_in")
		return true
	end
	local prompt = t.prompt :: ProximityPrompt
	if prompt:GetAttribute("InvReel") or prompt:GetAttribute("InvHydrant") then
		-- the hose goes through Inventory/Reel: Roblox ignores InputHoldBegin on a prompt whose spot is off
		-- screen, and the truck's hose prompt sits in the middle of the chassis (behind the camera from the
		-- far side), so the HOSE button / bubble did nothing there
		busyUntil = os.clock() + 0.5
		Net.event("Inventory", "Reel"):FireServer(prompt)
		count("tap_hose")
		return true
	end
	local holder = prompt.Parent
	if prompt.Name == "InvPrompt" and holder and holder:IsA("BasePart") and holder:GetAttribute("Stocked") ~= nil then
		-- a truck locker / gear rack: same reason as the hose (off-screen prompts ignore InputHoldBegin)
		busyUntil = os.clock() + 0.5
		Net.event("Inventory", "Take"):FireServer(prompt)
		count("tap_take")
		return true
	end
	local hold = math.max(0, prompt.HoldDuration)
	busyUntil = os.clock() + hold + 0.4
	prompt:InputHoldBegin()
	if hold > 0.15 then
		ringOn(if bubbleTarget and bubbleTarget.prompt == prompt then bubble else nil, hold)
	end
	-- release a beat after HoldDuration (frame jitter: releasing right on time sometimes cancels the hold)
	task.delay(if hold > 0 then hold + 0.2 else 0.05, function()
		prompt:InputHoldEnd()
	end)
	return true
end

-- the bubble -----------------------------------------------------------------------------------------

-- A ScreenGui button that follows the target on screen (a world BillboardGui set AlwaysOnTop didn't draw
-- reliably, and a screen button takes taps before the camera does).
local function makeBubble(name: string, getTarget: () -> Target?, fill: Color3?): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = name
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.ScreenInsets = Enum.ScreenInsets.None
	gui.DisplayOrder = 4
	gui:SetAttribute("UiAuditIgnore", true) -- a world marker, not a HUD widget
	local b = Instance.new("TextButton")
	b.Name = "Button"
	b.AnchorPoint = Vector2.new(0.5, 1)
	b.AutoButtonColor = true
	b.Size = UDim2.fromOffset(BUBBLE_PX, BUBBLE_PX)
	b.BackgroundColor3 = fill or Palette.UiCream
	b.Font = Enum.Font.FredokaOne
	b.TextColor3 = Palette.UiInk
	b.TextSize = 17
	b.Text = ""
	b.Visible = false
	b.Parent = gui
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(1, 0)
	c.Parent = b
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Palette.UiInk
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = b
	-- hold progress: a disc that fills from the centre
	local ring = Instance.new("Frame")
	ring.Name = "Ring"
	ring.AnchorPoint = Vector2.new(0.5, 0.5)
	ring.Position = UDim2.fromScale(0.5, 0.5)
	ring.BackgroundColor3 = Palette.UiGood or Color3.fromRGB(107, 214, 107)
	ring.BackgroundTransparency = 0.35
	ring.Visible = false
	ring.ZIndex = 0
	ring.Parent = b
	local rc = Instance.new("UICorner")
	rc.CornerRadius = UDim.new(1, 0)
	rc.Parent = ring
	-- the item's name in a pill under the circle (GRAB alone didn't say what you'd get)
	local item = Instance.new("TextLabel")
	item.Name = "Item"
	item.AnchorPoint = Vector2.new(0.5, 0)
	item.Position = UDim2.new(0.5, 0, 1, 4)
	item.AutomaticSize = Enum.AutomaticSize.X
	item.Size = UDim2.fromOffset(0, 22)
	item.BackgroundColor3 = Palette.UiInk
	item.TextColor3 = Palette.UiCream
	item.Font = Enum.Font.FredokaOne
	item.TextSize = 16
	item.Text = ""
	item.Visible = false
	item.Parent = b
	local ic = Instance.new("UICorner")
	ic.CornerRadius = UDim.new(0, 8)
	ic.Parent = item
	local ip = Instance.new("UIPadding")
	ip.PaddingLeft = UDim.new(0, 8)
	ip.PaddingRight = UDim.new(0, 8)
	ip.Parent = item
	b.Activated:Connect(function()
		local t = getTarget()
		if t then
			use(t)
		end
	end)
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

local function nearestTruck(range: number?): Model?
	local r = root()
	if not r or seated() then
		return nil
	end
	local best, bestD = nil :: Model?, range or ((tonumber(VehicleConfig.TapEnterRange) or 22) - 1)
	for _, m in CollectionService:GetTagged(Names.Tag.Truck) do
		if m:IsA("Model") and m.PrimaryPart and m:IsDescendantOf(workspace) then
			local d = (m.PrimaryPart.Position - r.Position).Magnitude
			if d < bestD then
				best, bestD = m, d
			end
		end
	end
	return best
end

-- Prompts that may get a bubble: the ones Roblox says are shown, plus the nearest truck's own gear
-- (reel / lockers) when in reach. Roblox doesn't re-send PromptShown for a prompt you were already beside
-- when you got out of the truck (VehicleController turns ProximityPromptService off while seated), so the
-- HOSE bubble used to stay away until you walked off and came back.
local function candidates(): { ProximityPrompt }
	local list: { ProximityPrompt } = {}
	local seen: { [ProximityPrompt]: boolean } = {}
	for prompt in shown do
		seen[prompt] = true
		table.insert(list, prompt)
	end
	local truck = nearestTruck(GEAR_RANGE)
	if truck then
		for _, d in truck:GetDescendants() do
			if d:IsA("ProximityPrompt") and not seen[d] and usable(d) then
				local t = promptTarget(d)
				if t and inReach(t) then
					table.insert(list, d)
				end
			end
		end
	end
	return list
end

local function pickBubble(): Target?
	local r = root()
	if not r or seated() then
		return nil
	end
	local best: Target? = nil
	local bestD = math.huge
	local function consider(t: Target?)
		if not t then
			return
		end
		local d = (t.part.Position - r.Position).Magnitude
		if not best or t.rank < best.rank or (t.rank == best.rank and d < bestD) then
			best, bestD = t, d
		end
	end
	-- on the first-call pad (FirstFire "queued") the card's GO NOW is the one thing to press: no CALLS
	-- bubble from the mission board next to it
	local firstCallPad = player:GetAttribute("FirstFire") == "queued"
	for _, prompt in candidates() do
		local t = promptTarget(prompt)
		if t and not (firstCallPad and t.verb == "CALLS") then
			consider(t)
		end
	end
	return best
end

-- a "Grab Hose" prompt (truck or hydrant) in reach: the HOSE thumb button uses it
local function pickHose(): Target?
	local r = root()
	if not r or seated() then
		return nil
	end
	local best: Target?, bestD = nil, math.huge
	for _, prompt in candidates() do
		if string.find(prompt.ActionText, "^Grab Hose") then
			local t = promptTarget(prompt)
			if t and inReach(t) then
				local d = (t.part.Position - r.Position).Magnitude
				if d < bestD then
					best, bestD = t, d
				end
			end
		end
	end
	return best
end

local function onHoseButton(_: string, state: Enum.UserInputState, _i: any): Enum.ContextActionResult
	if state == Enum.UserInputState.Begin then
		-- re-pick now (the button lingers a moment past the reach edge); the server re-checks distance
		-- (never the lingering one once the hose is in your hand: a second tap would stow it again)
		local t = pickHose() or (if player:GetAttribute("InvHand") == "Hose" then nil else hoseTarget or hoseLast)
		if t then
			use(t :: Target)
		end
	end
	return Enum.ContextActionResult.Sink
end

local function refreshHoseButton()
	local t = if touch() then pickHose() else nil
	hoseTarget = t
	if t then
		hoseLast, hoseSeenAt = t, os.clock()
	end
	local holding = player:GetAttribute("InvHand") == "Hose"
	local want = t ~= nil
		or (touch() and not seated() and not holding and hoseLast ~= nil and os.clock() - hoseSeenAt < HOSE_LINGER)
	if want and not hosePlaced then
		hosePlaced = true
		ThumbLayout.place(HOSE_ACTION, "upfar", onHoseButton, "HOSE")
	elseif not want and hosePlaced then
		hosePlaced = false
		hoseLast = nil
		ThumbLayout.forget(HOSE_ACTION)
	end
end

local function refreshBubble()
	local t = if touch() then pickBubble() else nil
	bubbleTarget = t
	local gui = bubble
	if t and not gui then
		gui = makeBubble("TapBubble", function()
			return bubbleTarget
		end)
		bubble = gui
	end
	if gui then
		local b = (gui :: any).Button :: TextButton
		if not t then
			b.Visible = false
		elseif b.Text ~= t.verb then
			b.Text = t.verb
		end
		local item = b:FindFirstChild("Item") :: TextLabel?
		if item then
			local name = if t then t.item else nil
			item.Visible = name ~= nil and name ~= ""
			item.Text = name or ""
		end
	end
	-- the truck's own IN bubble (green = go), at its door
	local truck = if touch() then nearestTruck() else nil
	local it = if truck then truckTarget(truck) else nil
	inTarget = it
	local ig = inBubble
	if it and not ig then
		ig = makeBubble("TapBubbleIn", function()
			return inTarget
		end, Palette.UiGood or Color3.fromRGB(107, 214, 107))
		inBubble = ig
	end
	if ig then
		local b = (ig :: any).Button :: TextButton
		if not it then
			b.Visible = false
		elseif b.Text ~= "IN" then
			b.Text = "IN"
		end
	end
	refreshHoseButton()
end

-- every frame: keep the bubbles over their targets (above the part's top), hidden when behind you
local function placeOne(gui: ScreenGui?, t: Target?, avoid: Vector2?): Vector2?
	local cam = workspace.CurrentCamera
	if not gui or not t or not cam or not t.part.Parent then
		return nil
	end
	local b = (gui :: any).Button :: TextButton
	local up = if t.kind == "truck" then 2 else math.clamp(t.part.Size.Y / 2 + 1.2, 1.2, 4)
	local v, on = cam:WorldToViewportPoint(t.part.Position + Vector3.new(0, up, 0))
	if t.kind == "truck" and not (on and v.Z > 0) and t.truck and t.truck.PrimaryPart then
		-- the door is out of view (you're at the back): put IN over the middle of the truck instead, so a
		-- kid beside the truck always sees the way in
		local c = (t.truck :: Model).PrimaryPart :: BasePart
		v, on = cam:WorldToViewportPoint(c.Position + Vector3.new(0, 5, 0))
	end
	b.Visible = on and v.Z > 0
	if not b.Visible then
		return nil
	end
	-- never up in the top HUD band (timer, objective / guide cards, minimap draw over it there) or off an edge
	local vp = cam.ViewportSize
	local at = Vector2.new(
		math.floor(math.clamp(v.X, BUBBLE_PX / 2 + 4, vp.X - BUBBLE_PX / 2 - 4) + 0.5),
		math.floor(math.clamp(v.Y, vp.Y * TOP_BAND + BUBBLE_PX, vp.Y - 8) + 0.5)
	)
	-- two bubbles never sit on each other (looking down the truck, the door and the reel line up)
	if avoid and (at - avoid).Magnitude < BUBBLE_PX + 8 then
		local side = if at.X >= avoid.X then 1 else -1
		if avoid.X + side * (BUBBLE_PX + 8) > vp.X - BUBBLE_PX / 2 or avoid.X + side * (BUBBLE_PX + 8) < BUBBLE_PX / 2 then
			side = -side
		end
		at = Vector2.new(avoid.X + side * (BUBBLE_PX + 8), avoid.Y)
	end
	b.Position = UDim2.fromOffset(at.X, at.Y)
	return at
end

local function placeBubble()
	local main = placeOne(bubble, bubbleTarget, nil)
	placeOne(inBubble, inTarget, main)
end

-- taps in the world ----------------------------------------------------------------------------------

local function promptsNear(pos: Vector3, hit: Instance?): { ProximityPrompt }
	local out: { ProximityPrompt } = {}
	local seen: { [ProximityPrompt]: boolean } = {}
	local function add(p: ProximityPrompt)
		if not seen[p] and usable(p) then
			seen[p] = true
			table.insert(out, p)
		end
	end
	-- prompts on the thing you tapped (its own model, if that model is small)
	if hit then
		local m = hit:FindFirstAncestorWhichIsA("Model")
		local scope: Instance = if m and #m:GetChildren() < 80 then m else hit
		for _, d in scope:GetDescendants() do
			if d:IsA("ProximityPrompt") then
				add(d)
			end
		end
	end
	-- and anything within SNAP studs of the tap point (spatial query, then their prompts)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance }
	params.MaxParts = 60
	for _, part in workspace:GetPartBoundsInRadius(pos, SNAP, params) do
		for _, c in part:GetChildren() do
			if c:IsA("ProximityPrompt") then
				add(c)
			elseif c:IsA("Attachment") then
				local pp = c:FindFirstChildOfClass("ProximityPrompt")
				if pp then
					add(pp)
				end
			end
		end
	end
	return out
end

-- screen: input position (below the top bar, what TouchTap / InputObject.Position give); viewport = true:
-- a full-viewport point (the test hook)
local function tapAt(screen: Vector2, viewport: boolean?): string
	local cam = workspace.CurrentCamera
	if not cam or seated() then
		return "seated / no camera"
	end
	local ray = if viewport then cam:ViewportPointToRay(screen.X, screen.Y) else cam:ScreenPointToRay(screen.X, screen.Y)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { player.Character :: Instance }
	local res = workspace:Raycast(ray.Origin, ray.Direction * 150, params)
	if not res then
		return "nothing hit"
	end
	local pos, hit = res.Position, res.Instance
	-- the closest prompt to the tap point wins
	local best: Target? = nil
	local bestD = math.huge
	for _, p in promptsNear(pos, hit) do
		local t = promptTarget(p)
		if t then
			local d = (t.part.Position - pos).Magnitude -- the truck hose: measured to the reel, not the chassis
			if d < bestD then
				best, bestD = t, d
			end
		end
	end
	-- On a truck, tapping it is never a way in (it put kids in the driver's seat when they reached for the
	-- hose; the open crew seats sit right by the reel). Only the green IN bubble gets you in. Near the
	-- reel / a locker uses that; the cab, its doors and anywhere else: a hint pointing at the IN bubble.
	local truck = truckOf(hit)
	if truck then
		local name = hit.Name
		local cab = string.find(name, "^Door") ~= nil or string.find(name, "^Cab") ~= nil
			or hit:FindFirstAncestor("Door_L") ~= nil or hit:FindFirstAncestor("Door_R") ~= nil
		if cab or best == nil or bestD > TRUCK_GEAR_TAP then
			WorldPopup.show(pos, "Tap IN to get in", { kind = "hint", mine = true, seconds = 1.2 })
			count("tap_truck_body")
			return "truck body: hint"
		end
	end
	if not best then
		return "no target near " .. hit:GetFullName()
	end
	local ok = use(best)
	return `{best.verb} {if best.prompt then best.prompt:GetFullName() else (best.truck :: Model).Name} used={ok}`
end

-- prompt styles ------------------------------------------------------------------------------------

-- touch: Custom style (Roblox draws nothing; the bubble does) and AlwaysShow, so every prompt in reach
-- can be triggered by a tap, not only the one OnePerButton picked for its key
local function styleFor(prompt: ProximityPrompt)
	if touch() then
		if not origStyle[prompt] then
			origStyle[prompt] = { style = prompt.Style, excl = prompt.Exclusivity }
		end
		if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
			prompt.Style = Enum.ProximityPromptStyle.Custom
		end
		if prompt.Exclusivity ~= Enum.ProximityPromptExclusivity.AlwaysShow then
			prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
		end
	elseif origStyle[prompt] then
		-- back on keyboard / gamepad: Exclusivity only. Style stays Custom, because PromptController draws
		-- the same sticker for every prompt on every input (Roblox's grey card never comes back)
		local o = origStyle[prompt]
		prompt.Exclusivity = o.excl
		origStyle[prompt] = nil
	end
end

local function restyleAll()
	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			styleFor(d)
		end
	end
end

function TapUseController:Start()
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		shown[prompt] = true
		styleFor(prompt)
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		shown[prompt] = nil
	end)
	workspace.DescendantAdded:Connect(function(d: Instance)
		if d:IsA("ProximityPrompt") and touch() then
			task.defer(styleFor, d)
		end
	end)
	InputHints.onChanged(function()
		task.spawn(restyleAll)
	end)
	task.spawn(restyleAll)

	UserInputService.TouchTap:Connect(function(positions: { Vector2 }, processed: boolean)
		if processed or not touch() or #positions == 0 then
			return
		end
		tapAt(positions[1])
	end)
	-- Studio has no touch: with ForceTouchUI a left click is a tap
	UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
			return
		end
		if player:GetAttribute("ForceTouchUI") == true and touch() then
			local p = input.Position
			tapAt(Vector2.new(p.X, p.Y))
		end
	end)

	RunService.RenderStepped:Connect(function()
		pcall(placeBubble)
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < 0.15 then
			return
		end
		acc = 0
		local ok, err = pcall(refreshBubble)
		if not ok then
			warn(`[TapUse] {err}`)
		end
	end)

	-- test hook (Studio MCP / ForgeTest): Players.LocalPlayer.TapUseTest:Invoke(x, y) taps a viewport point
	local hook = Instance.new("BindableFunction")
	hook.Name = "TapUseTest"
	hook.OnInvoke = function(x: number, y: number): string
		return tapAt(Vector2.new(x, y), true)
	end
	hook.Parent = player -- not PlayerGui: that one is emptied on respawn
end

return TapUseController
