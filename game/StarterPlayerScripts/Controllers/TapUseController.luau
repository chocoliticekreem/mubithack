--!strict
-- TapUseController [owner: G3]. Touch (phones / iPads): tap things in the world to use them, and one
-- small round bubble instead of Roblox's big ProximityPrompt cards.
--   * While InputHints says "touch", every ProximityPrompt is switched to Style Custom + Exclusivity
--     AlwaysShow locally (Roblox draws nothing, and any prompt in reach can be tapped, not just the one
--     OnePerButton picked) and the originals come back on keyboard / gamepad. InventoryController's
--     "[E] Grab Axe" stickers stand down on touch too.
--   * ONE bubble at a time over the most relevant thing in reach (rescue > truck > pick-ups > the rest,
--     then nearest): a 50 px circle with a one-word verb (IN, GRAB, FILL, OPEN...) that follows the thing
--     on screen (ScreenGui "TapBubble"). Tap it to use it.
--   * Tap the thing itself: a ray from the tap (your own character ignored) and a snap radius, so a
--     fat-finger tap next to an axe still grabs it. In range: it happens (a hold prompt holds for its
--     HoldDuration, with a ring filling). Out of range: a small "walk closer" pop over it.
--   * Fire trucks: tap the body, a door or a seat from up to VehicleConfig.TapEnterRange studs and you sit
--     straight in (Vehicle/Enter on the server: driver seat if it's yours and free, else the nearest free
--     seat). No door to open first, so the door never swings into you. Truck door / seat prompts are
--     never bubbled (the truck's IN bubble covers them); its lockers, reel and supply intakes are.
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
local WorldPopup = require(ClientLib:WaitForChild("WorldPopup") :: ModuleScript) :: any

local TapUseController = {}
TapUseController.Priority = 140

local player = Players.LocalPlayer
local SNAP = 6 -- studs: a tap this close to a prompt's part counts as a tap on it
local REACH_SLACK = 2 -- studs past a prompt's MaxActivationDistance that still count (the server re-checks)
local BUBBLE_PX = 50
local TRUCK_HIDDEN = { DoorPrompt = true, SeatPrompt = true }

type Target = {
	kind: string, -- "prompt" | "truck"
	prompt: ProximityPrompt?,
	truck: Model?,
	part: BasePart,
	verb: string,
	rank: number,
}

local shown: { [ProximityPrompt]: boolean } = {}
local origStyle: { [ProximityPrompt]: { style: Enum.ProximityPromptStyle, excl: Enum.ProximityPromptExclusivity } } = {}
local bubble: ScreenGui? = nil
local bubbleTarget: Target? = nil
local busyUntil = 0

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

-- one short verb for the bubble
local VERBS: { { string } } = {
	{ "^Grab", "GRAB" },
	{ "^Pick up", "GRAB" }, -- a rescue's Carry prompt says "Pick up" too: verbOf maps it to CARRY first
	{ "^Take", "GRAB" },
	{ "^Carry", "CARRY" },
	{ "^Refill", "FILL" },
	{ "^Hook", "HOOK" },
	{ "^Unhook", "UNHOOK" },
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
	local part = partOf(prompt)
	if not part or not usable(prompt) then
		return nil
	end
	return { kind = "prompt", prompt = prompt, part = part, verb = verbOf(prompt), rank = rankOf(prompt) }
end

local function truckTarget(truck: Model): Target?
	local seat = truck:FindFirstChild("DriveSeat")
	local part = if seat and seat:IsA("BasePart") then seat else truck.PrimaryPart
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
		return true
	end
	local prompt = t.prompt :: ProximityPrompt
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
local function makeBubble(): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "TapBubble"
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
	b.BackgroundColor3 = Palette.UiCream
	b.Font = Enum.Font.FredokaOne
	b.TextColor3 = Palette.UiInk
	b.TextSize = 15
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
	b.Activated:Connect(function()
		local t = bubbleTarget
		if t then
			use(t)
		end
	end)
	gui.Parent = player:WaitForChild("PlayerGui")
	return gui
end

local function nearestTruck(): Model?
	local r = root()
	if not r or seated() then
		return nil
	end
	local best, bestD = nil :: Model?, (tonumber(VehicleConfig.TapEnterRange) or 22) - 1
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
	for prompt in shown do
		consider(promptTarget(prompt))
	end
	local truck = nearestTruck()
	if truck then
		consider(truckTarget(truck))
	end
	return best
end

local function refreshBubble()
	local t = if touch() then pickBubble() else nil
	bubbleTarget = t
	local gui = bubble
	if not t then
		if gui then
			(gui :: any).Button.Visible = false
		end
		return
	end
	if not gui then
		gui = makeBubble()
		bubble = gui
	end
	local b = (gui :: ScreenGui):FindFirstChild("Button") :: TextButton
	if b.Text ~= t.verb then
		b.Text = t.verb
	end
end

-- every frame: keep the bubble over its target (above the part's top), hidden when it's behind you
local function placeBubble()
	local gui, t = bubble, bubbleTarget
	local cam = workspace.CurrentCamera
	if not gui or not t or not cam or not t.part.Parent then
		return
	end
	local b = (gui :: any).Button :: TextButton
	local up = if t.kind == "truck" then 4 else math.clamp(t.part.Size.Y / 2 + 1.2, 1.2, 4)
	local v, on = cam:WorldToViewportPoint(t.part.Position + Vector3.new(0, up, 0))
	b.Visible = on and v.Z > 0
	if b.Visible then
		b.Position = UDim2.fromOffset(math.floor(v.X + 0.5), math.floor(v.Y + 0.5))
	end
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
		local pp = promptPos(p)
		if t and pp then
			local d = (pp - pos).Magnitude
			if d < bestD then
				best, bestD = t, d
			end
		end
	end
	-- on a truck, getting in wins unless the tap landed ON a locker / reel / intake that you can reach
	local truck = truckOf(hit)
	if truck then
		local onIt = best ~= nil and (hit == best.part or hit:IsDescendantOf(best.part) or best.part:IsDescendantOf(hit))
		if not (onIt and best and inReach(best)) then
			best = truckTarget(truck)
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
		local o = origStyle[prompt]
		prompt.Style = o.style
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
