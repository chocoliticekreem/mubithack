--!strict
-- HydrantController [owner: Inventory]. The client side of the street hydrants' hose prompt
-- (InventoryService hookHydrant: "HydrantHosePrompt" on a hydrant Body, attr InvHydrant, [T] / ButtonY /
-- tap). Everything here is local and cosmetic; the server checks every grab.
--   * Relabels each nearby hydrant prompt: "Stow Hose" when the hose in your hand comes off THAT hydrant
--     (HoseLine's "HoseLineSource_<UserId>" attachment sits on its Body), else "Grab Hose" (the server
--     swaps an extinguisher or another source's hose for this one). InventoryController's open sticker
--     flips with it (PromptController); TapUseController's bubble reads ActionText (HOSE / STOW).
--   * Hides hydrant prompts while you sit in a seat (no [T] stickers flashing by as you drive the city).
--   * A small "HOSE" beacon over the nearest hydrant when a fire burns near it and you are not already
--     holding a hose, so kids notice they can hose from there. It goes away once you are in the
--     prompt's reach (the sticker / tap bubble takes over).
-- Reads: tags Hydrant, Burning; Player attrs InvHand, HoseKind.
local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any

local HydrantController = {}
HydrantController.Priority = 145

local LocalPlayer = Players.LocalPlayer
local NEAR = 90 -- studs from you: hydrants we look after this tick
local FIRE_NEAR = 80 -- studs from a hydrant to a burning part for its beacon
local TICK = 0.4

local beacon: BillboardGui? = nil
local beaconOn: BasePart? = nil

local function promptOf(body: Instance): ProximityPrompt?
	local p = body:FindFirstChild("HydrantHosePrompt")
	return if p and p:IsA("ProximityPrompt") then p else nil
end

local function holdingHose(): boolean
	-- in your hand or slung on your back (InventoryService keeps its line hooked either way)
	return LocalPlayer:GetAttribute("InvHand") == "Hose" or LocalPlayer:GetAttribute("InvBack") == "Hose"
end

local function textFor(body: BasePart): string
	if holdingHose() and body:FindFirstChild(`HoseLineSource_{LocalPlayer.UserId}`) then
		return "Stow Hose"
	end
	return "Grab Hose"
end

-- the open "[T] Grab Hose" sticker (PromptController) follows ActionText by itself
local function setText(prompt: ProximityPrompt, _body: BasePart, text: string)
	if prompt.ActionText ~= text then
		prompt.ActionText = text
	end
end

local function makeBeacon(): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "HydrantHoseBeacon"
	gui.AlwaysOnTop = true
	gui.Size = UDim2.fromOffset(70, 30)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 4.2, 0)
	gui.MaxDistance = NEAR + 10
	gui.ResetOnSpawn = false
	gui.Enabled = false
	gui:SetAttribute("UiAuditIgnore", true) -- a world marker, not a HUD widget
	local pill = Instance.new("TextLabel")
	pill.Name = "Pill"
	pill.Size = UDim2.fromScale(1, 1)
	pill.BackgroundColor3 = Palette.UiCream
	pill.TextColor3 = Palette.UiInk
	pill.Font = UiKit.Header
	pill.TextSize = 17
	pill.Text = "HOSE"
	pill.Parent = gui
	UiKit.corner(pill, 15)
	UiKit.stroke(pill, 2, Palette.UiInk)
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	return gui
end

local function setBeacon(body: BasePart?)
	if body == beaconOn then
		return
	end
	beaconOn = body
	if not body then
		if beacon then
			beacon.Enabled = false
			beacon.Adornee = nil
		end
		return
	end
	local gui = beacon or makeBeacon()
	beacon = gui
	local pill = gui:FindFirstChild("Pill") :: TextLabel?
	if pill then
		pill.Text = if InputHints.isTouch() then "HOSE" else "[T] HOSE"
	end
	gui.Adornee = body
	gui.Enabled = true
	if pill then
		UiKit.pop(pill, 0.2)
	end
end

local function tick()
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root then
		setBeacon(nil)
		return
	end
	local here = root.Position
	local seated = hum ~= nil and hum.SeatPart ~= nil
	local near: { { body: BasePart, prompt: ProximityPrompt, d: number } } = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.Hydrant) do
		if not inst:IsA("BasePart") then
			continue
		end
		local prompt = promptOf(inst)
		if not prompt then
			continue -- ponds, pools, creeks, station props: no hose prompt
		end
		local d = (inst.Position - here).Magnitude
		if d > NEAR then
			continue
		end
		if prompt.Enabled == seated then
			prompt.Enabled = not seated
		end
		setText(prompt, inst, textFor(inst))
		table.insert(near, { body = inst, prompt = prompt, d = d })
	end
	if seated or holdingHose() or #near == 0 then
		setBeacon(nil)
		return
	end
	table.sort(near, function(a, b)
		return a.d < b.d
	end)
	local burning = CollectionService:GetTagged(Names.Tag.Burning)
	local pick: BasePart? = nil
	for _, h in near do
		if h.d <= h.prompt.MaxActivationDistance + 1 then
			break -- in reach of the closest one: its sticker / tap bubble says it already
		end
		local hp = h.body.Position
		for _, b in burning do
			if b:IsA("BasePart") and (b.Position - hp).Magnitude <= FIRE_NEAR then
				pick = h.body
				break
			end
		end
		if pick then
			break
		end
	end
	setBeacon(pick)
end

function HydrantController:Start()
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < TICK then
			return
		end
		acc = 0
		local ok, err = pcall(tick)
		if not ok then
			warn(`[Hydrant] {err}`)
		end
	end)
	-- the label flips the moment the hose comes out / goes back, not on the next tick
	for _, name in { "InvHand", "InvBack", "HoseKind" } do
		LocalPlayer:GetAttributeChangedSignal(name):Connect(function()
			task.defer(function()
				pcall(tick)
			end)
		end)
	end
end

return HydrantController
