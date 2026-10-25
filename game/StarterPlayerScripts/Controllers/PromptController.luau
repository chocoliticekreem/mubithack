--!strict
-- PromptController [owner: G3]. One look for EVERY ProximityPrompt on keyboard / gamepad, so a kid learns
-- it once (rules: Config/PromptConfig, audit: docs/game/16-predictability-audit.md):
--   * every prompt is switched to Style Custom locally (Roblox's grey card never draws), and while it is
--     shown it gets the same cream "[E] Verb" sticker over the thing plus a yellow outline on the thing.
--     Before, item / hose prompts had this sticker and doors, ladders, lockers, people, alarms and hazards
--     had Roblox's dark card: two looks for the same "press a key here".
--   * hold prompts fill the sticker left to right while you hold (and the bar empties if you let go)
--   * the sticker follows ActionText (Grab Hose <-> Stow Hose) and bumps when used
--   * two prompts on one thing (Open + Kick on a locked door) stack instead of overlapping
--   * a mouse click on the sticker uses it, like pressing the key (only while the mouse is free)
-- Touch is TapUseController's: one round verb bubble, nothing drawn here.
-- Escape hatch: a prompt with attr PromptDefaultStyle = true keeps Roblox's own card.
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PromptConfig") :: ModuleScript) :: any
local ClientLib = script.Parent.Parent:WaitForChild("ClientLib")
local UiKit = require(ClientLib:WaitForChild("UiKit") :: ModuleScript) :: any
local InputHints = require(ClientLib:WaitForChild("InputHints") :: ModuleScript) :: any

local PromptController = {}
PromptController.Priority = 60 -- before InventoryController / HydrantController relabel prompts

local LocalPlayer = Players.LocalPlayer
local HIGHLIGHT_MAX = 60 -- studs: things bigger than this (a whole building) get the sticker but no outline

type Shown = {
	gui: BillboardGui,
	hl: Highlight?,
	adornee: BasePart,
	target: Instance?,
	conns: { RBXScriptConnection },
}

local shown: { [ProximityPrompt]: Shown } = {}
local live: { [ProximityPrompt]: Enum.ProximityPromptInputType } = {} -- what Roblox shows right now

local function keepsDefault(prompt: ProximityPrompt): boolean
	return prompt:GetAttribute("PromptDefaultStyle") == true
end

-- every prompt, every input: Custom (TapUseController adds AlwaysShow on touch)
local function restyle(prompt: ProximityPrompt)
	if keepsDefault(prompt) then
		return
	end
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		prompt.Style = Enum.ProximityPromptStyle.Custom
	end
end

local function adorneeOf(prompt: ProximityPrompt): BasePart?
	local p = prompt.Parent
	if p and p:IsA("Attachment") then
		p = p.Parent
	end
	if p and p:IsA("BasePart") then
		return p
	end
	if p and p:IsA("Model") then
		return p.PrimaryPart or p:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- what gets the yellow outline: the item's display model, the item / prop model, or the part itself
local function outlineOf(prompt: ProximityPrompt, part: BasePart): Instance?
	local display = part:FindFirstChild("InvDisplay")
	if display then
		return display
	end
	local model = part.Parent
	if model and model:IsA("Model") and (model:HasTag("InventoryItem") or model.PrimaryPart == part or model:FindFirstChildOfClass("Humanoid")) then
		local _, size = model:GetBoundingBox()
		if math.max(size.X, size.Y, size.Z) <= HIGHLIGHT_MAX then
			return model
		end
	end
	if math.max(part.Size.X, part.Size.Y, part.Size.Z) <= HIGHLIGHT_MAX then
		return part
	end
	return nil
end

local function keyText(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType): string
	if inputType == Enum.ProximityPromptInputType.Gamepad then
		return (string.gsub(prompt.GamepadKeyCode.Name, "Button", ""))
	end
	return prompt.KeyboardKeyCode.Name
end

-- stickers already on this part (Open + Kick on one door): the new one sits above the others
local function slotOn(part: BasePart): number
	local n = 0
	for _, s in shown do
		if s.adornee == part then
			n += 1
		end
	end
	return n
end

local function outlined(target: Instance): boolean
	for _, s in shown do
		if s.target == target and s.hl then
			return true
		end
	end
	return false
end

local function hide(prompt: ProximityPrompt)
	local s = shown[prompt]
	if not s then
		return
	end
	shown[prompt] = nil
	for _, c in s.conns do
		c:Disconnect()
	end
	s.gui:Destroy()
end

local function use(prompt: ProximityPrompt)
	local hold = math.max(0, prompt.HoldDuration)
	prompt:InputHoldBegin()
	task.delay(if hold > 0 then hold + 0.2 else 0.05, function()
		prompt:InputHoldEnd()
	end)
end

local function show(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
	if shown[prompt] or keepsDefault(prompt) or InputHints.isTouch() then
		return -- touch: TapUseController's bubble
	end
	if prompt.Style ~= Enum.ProximityPromptStyle.Custom then
		restyle(prompt)
	end
	local part = adorneeOf(prompt)
	if not part then
		return
	end
	local slot = slotOn(part)
	local gui = Instance.new("BillboardGui")
	gui.Name = "PromptSticker"
	gui.Adornee = part
	gui.AlwaysOnTop = true
	gui.Active = true
	gui.Size = UDim2.fromOffset(196, 42)
	gui.StudsOffsetWorldSpace = Vector3.new(0, math.clamp(part.Size.Y / 2, 0.8, 4) + 1.6, 0)
	gui.SizeOffset = Vector2.new(0, slot * 1.2)
	gui.MaxDistance = Cfg.StickerMaxDistance
	gui.ResetOnSpawn = false
	gui:SetAttribute("UiAuditIgnore", true) -- a world marker, not a HUD widget
	local panel = UiKit.panel(gui, "Panel", UDim2.fromScale(1, 1), UDim2.fromScale(0, 0))
	panel.BackgroundColor3 = Palette.UiCream
	panel.ClipsDescendants = true
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.BorderSizePixel = 0
	fill.BackgroundColor3 = Palette.UiGood or Color3.fromRGB(107, 214, 107)
	fill.BackgroundTransparency = 0.25
	fill.Size = UDim2.fromScale(0, 1)
	fill.ZIndex = 1
	fill.Parent = panel
	local key = UiKit.label(panel, "Key", keyText(prompt, inputType), UDim2.fromOffset(32, 30), UDim2.fromOffset(6, 6), {
		font = UiKit.Header,
		textSize = 18,
		color = Palette.UiCream,
	})
	key.BackgroundTransparency = 0
	key.BackgroundColor3 = Palette.UiInk
	key.ZIndex = 3
	UiKit.corner(key, 8)
	local action = UiKit.label(panel, "Action", prompt.ActionText, UDim2.new(1, -50, 1, 0), UDim2.fromOffset(44, 0), {
		font = UiKit.Header,
		textSize = 17,
		align = Enum.TextXAlignment.Left,
	})
	action.ZIndex = 3
	action.TextScaled = true
	local cap = Instance.new("UITextSizeConstraint")
	cap.MaxTextSize = 17
	cap.MinTextSize = 11
	cap.Parent = action
	local click = Instance.new("TextButton")
	click.Name = "Click"
	click.BackgroundTransparency = 1
	click.Text = ""
	click.Size = UDim2.fromScale(1, 1)
	click.ZIndex = 5
	click.Parent = panel
	gui.Parent = LocalPlayer:WaitForChild("PlayerGui")
	UiKit.pop(panel, 0.2)

	local hl: Highlight? = nil
	local target = outlineOf(prompt, part)
	if target and not outlined(target) then
		local h = Instance.new("Highlight")
		h.Name = "PromptHighlight"
		h.Adornee = target
		h.FillColor = Cfg.HighlightColor
		h.FillTransparency = 0.75
		h.OutlineColor = Cfg.HighlightColor
		h.OutlineTransparency = 0
		h.DepthMode = Enum.HighlightDepthMode.Occluded
		h.Parent = gui
		hl = h
	end

	local conns: { RBXScriptConnection } = {}
	table.insert(conns, click.Activated:Connect(function()
		-- a free mouse only: with the mouse locked (first person / shift lock) a click is the tool's
		if UserInputService.MouseBehavior == Enum.MouseBehavior.Default then
			use(prompt)
		end
	end))
	table.insert(conns, prompt:GetPropertyChangedSignal("ActionText"):Connect(function()
		action.Text = prompt.ActionText
	end))
	table.insert(conns, prompt.PromptButtonHoldBegan:Connect(function()
		local hold = prompt.HoldDuration
		if hold > 0 then
			fill.Size = UDim2.fromScale(0, 1)
			UiKit.tween(fill, hold, { Size = UDim2.fromScale(1, 1) }, Enum.EasingStyle.Linear)
		end
	end))
	table.insert(conns, prompt.PromptButtonHoldEnded:Connect(function()
		UiKit.tween(fill, 0.15, { Size = UDim2.fromScale(0, 1) })
	end))
	table.insert(conns, prompt.Triggered:Connect(function()
		UiKit.punch(panel, 0.3)
	end))
	table.insert(conns, prompt.Destroying:Connect(function()
		hide(prompt)
	end))
	shown[prompt] = { gui = gui, hl = hl, adornee = part, target = target, conns = conns }
end

function PromptController:Start()
	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			restyle(d)
		end
	end
	workspace.DescendantAdded:Connect(function(d: Instance)
		if d:IsA("ProximityPrompt") then
			restyle(d)
			task.defer(restyle, d) -- after the builder set its properties
		end
	end)
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt, inputType: Enum.ProximityPromptInputType)
		live[prompt] = inputType
		show(prompt, inputType)
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		live[prompt] = nil
		hide(prompt)
	end)
	-- an iPad's keyboard comes off: stickers go, TapUseController's bubble takes over (and back)
	InputHints.onChanged(function()
		for prompt in shown do
			hide(prompt)
		end
		task.defer(function()
			for prompt, inputType in live do
				if prompt.Parent then
					show(prompt, inputType)
				else
					live[prompt] = nil
				end
			end
		end)
	end)
end

-- test hook (ForgeTest / Studio MCP): how many stickers are up, and their texts
function PromptController.debugShown(): { string }
	local out = {}
	for prompt, s in shown do
		table.insert(out, `{(s.gui:FindFirstChild("Key", true) :: TextLabel).Text} {prompt.ActionText}`)
	end
	return out
end

return PromptController
