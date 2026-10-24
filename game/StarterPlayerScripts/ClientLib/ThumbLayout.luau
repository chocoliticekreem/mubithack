--!strict
-- ThumbLayout [owner: G3]. Lays the touch action buttons (ContextActionService touch buttons) out as ONE
-- cluster around Roblox's jump button, sized from the real jump button, so nothing overlaps it, the
-- squad strip, the hotbar or each other on phones and iPads:
--
--              [above]          slot "above"   : SWAP          (small, over the jump button)
--      [upleft]                 slot "upleft"  : DROP          (small, over the primary)
--  [left] (  PRIMARY  ) (JUMP)  slot "primary" : SPRAY / CHOP  (big, left of jump)
--                               slot "left"    : THROW / YEET  (small, left of the primary)
--
--   ThumbLayout.place(actionName, slot)   call right after BindAction/SetTitle; re-applied on resize
-- Positions are computed in screen pixels from the live JumpButton (TouchGui) and converted into the
-- ContextButtonFrame's space, so they don't depend on how Roblox sizes that frame.
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")

local ThumbLayout = {}

export type Slot = "primary" | "above" | "upleft" | "left"

local placed: { [string]: Slot } = {}
local hooked = false

local function jumpRect(): (Vector2, number)
	local cam = workspace.CurrentCamera
	local vp = if cam then cam.ViewportSize else Vector2.new(1280, 720)
	local pg = Players.LocalPlayer:FindFirstChild("PlayerGui")
	local touch = pg and pg:FindFirstChild("TouchGui")
	local jump = touch and touch:FindFirstChild("JumpButton", true)
	if jump and jump:IsA("GuiObject") and jump.AbsoluteSize.X > 10 then
		local inset = 0
		local sg = jump:FindFirstAncestorOfClass("ScreenGui")
		if sg and not sg.IgnoreGuiInset then
			inset = game:GetService("GuiService"):GetGuiInset().Y
		end
		local c = jump.AbsolutePosition + jump.AbsoluteSize / 2 + Vector2.new(0, inset)
		return c, jump.AbsoluteSize.X
	end
	-- Roblox's own rule (TouchJump): small screens get a 70 px button, big ones 120 px
	local small = math.min(vp.X, vp.Y) <= 500
	local j = if small then 70 else 120
	local c = if small then Vector2.new(vp.X - 60, vp.Y - 55) else Vector2.new(vp.X - 110, vp.Y - 150)
	return c, j
end

-- centre + size of a slot, in screen pixels (inset-free)
local function slotRect(slot: Slot): (Vector2, number)
	local jc, j = jumpRect()
	local big = math.floor(j * 1.2)
	local small = math.floor(j * 0.75)
	local gap = math.max(8, math.floor(j * 0.15))
	local primary = Vector2.new(jc.X - (j / 2 + gap + big / 2), jc.Y + j * 0.05)
	if slot == "primary" then
		return primary, big
	elseif slot == "above" then
		return Vector2.new(jc.X, jc.Y - (j / 2 + gap + small / 2)), small
	elseif slot == "upleft" then
		return Vector2.new(primary.X + big * 0.05, primary.Y - (big / 2 + gap + small / 2)), small
	else
		return Vector2.new(primary.X - (big / 2 + gap + small / 2), primary.Y + big * 0.15), small
	end
end

local function apply(action: string, slot: Slot)
	local b = ContextActionService:GetButton(action)
	if not b then
		return
	end
	local frame = b.Parent
	if not frame or not frame:IsA("GuiObject") then
		return
	end
	local c, size = slotRect(slot)
	-- the frame lives in a ScreenGui that may or may not ignore the top-bar inset
	local inset = 0
	local sg = frame:FindFirstAncestorOfClass("ScreenGui")
	if sg and not sg.IgnoreGuiInset then
		inset = game:GetService("GuiService"):GetGuiInset().Y
	end
	local origin = frame.AbsolutePosition + Vector2.new(0, inset)
	b.AnchorPoint = Vector2.new(0.5, 0.5)
	b.Size = UDim2.fromOffset(size, size)
	b.Position = UDim2.fromOffset(c.X - origin.X, c.Y - origin.Y)
	local title = b:FindFirstChild("ActionTitle")
	if title and title:IsA("TextLabel") then
		title.TextScaled = true
		title.TextWrapped = false
		title.Font = Enum.Font.FredokaOne
		local lim = title:FindFirstChildOfClass("UITextSizeConstraint") or Instance.new("UITextSizeConstraint")
		lim.MaxTextSize = if slot == "primary" then 30 else 18
		lim.MinTextSize = 8
		lim.Parent = title
		title.Size = UDim2.fromScale(0.82, 0.5)
		title.AnchorPoint = Vector2.new(0.5, 0.5)
		title.Position = UDim2.fromScale(0.5, 0.5)
	end
end

local function reapply()
	for action, slot in placed do
		apply(action, slot)
	end
end

function ThumbLayout.place(action: string, slot: Slot)
	placed[action] = slot
	apply(action, slot)
	-- Roblox can build / move the frame a frame later: apply again once it has settled
	task.defer(apply, action, slot)
	task.delay(0.3, function()
		if placed[action] == slot then
			apply(action, slot)
		end
	end)
	if not hooked then
		hooked = true
		local cam = workspace.CurrentCamera
		if cam then
			cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				task.defer(reapply)
			end)
		end
	end
end

function ThumbLayout.forget(action: string)
	placed[action] = nil
end

return ThumbLayout
