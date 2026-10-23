--!strict
-- RescueNpcBuilder [owner: G3]. Turns main's display-only NpcBuilder models (left untouched) into
-- carryable rescue targets:
--   * one physics assembly: every part is jointed to the invisible "Root" (PrimaryPart); only Root is
--     ever anchored, so RescueService carries/throws the NPC by un-anchoring Root;
--   * limbs (legs, arms, tails) hang on Motor6D joints named "Flail" so RescueController can wave them
--     about locally (legs flailing while carried or flying, running legs while panicking);
--   * a "Shout" speech bubble and a "Grab" attachment on Root.
--
--   RescueNpcBuilder.build(kind: string, feet: CFrame, pose: string?): Model
--   RescueNpcBuilder.rebuild(model: Model, kind: string, feet: CFrame, pose: string?): BasePart  -- new Root
--   RescueNpcBuilder.toast(model: Model)                -- sooty "Toasted" variant (googly eyes stay white)
--   RescueNpcBuilder.shout(model: Model, text: string?) -- set or hide the speech bubble
--   RescueNpcBuilder.setFree(model: Model, free: boolean) -- free = physics (collides, falls); else anchored
--   feet = ground point under the NPC; the NPC faces -Z of feet. pose: "stand" | "sitting" | "lying".
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)
local NpcBuilder = require(script.Parent:WaitForChild("NpcBuilder") :: ModuleScript)

local RescueNpcBuilder = {}

-- Limb parts that get a Motor6D to Root ("Flail"); everything else is welded.
local function isLimb(model: Model, name: string): boolean
	local base, digits = string.match(name, "^(%a+)(%d*)$")
	if not base then
		return false
	end
	if base == "Leg" or base == "Sleeve" or base == "FrontLeg" or base == "Haunch" then
		return digits ~= ""
	end
	if base == "Arm" then
		return digits ~= "" and model:FindFirstChild(`Sleeve{digits}`) == nil
	end
	if base == "Tail" then
		return digits == "" or digits == "1"
	end
	return false
end

-- The limb an appendage rides on (shoe on leg, hand on sleeve...), or nil = weld to Root.
local function limbOf(model: Model, name: string): BasePart?
	local base, digits = string.match(name, "^(%a+)(%d*)$")
	if not base then
		return nil
	end
	local i = string.sub(digits or "", 1, 1)
	local candidates: { string } = {}
	if base == "Shoe" or base == "Sole" or base == "Bean" or base == "Boot" then
		candidates = { `Leg{i}` }
	elseif base == "Hand" then
		candidates = { `Sleeve{i}`, `Arm{i}` }
	elseif base == "Arm" then
		candidates = { `Sleeve{i}` }
	elseif base == "Paw" then
		candidates = { `FrontLeg{i}`, `Leg{i}` }
	elseif base == "Glove" or base == "Thumb" then
		candidates = { `Arm{i}` }
	elseif base == "TailTip" then
		candidates = { "Tail" }
	elseif base == "Tail" and digits ~= "" and digits ~= "1" then
		candidates = { "Tail1" }
	end
	for _, c in candidates do
		local p = model:FindFirstChild(c)
		if p and p:IsA("BasePart") and c ~= name then
			return p
		end
	end
	return nil
end

local function motor(root: BasePart, limb: BasePart)
	-- joint at the end of the limb nearest the body (hip / shoulder / tail base)
	local half = limb.Size.Y / 2
	local a = limb.CFrame * CFrame.new(0, half, 0)
	local b = limb.CFrame * CFrame.new(0, -half, 0)
	local joint = if (a.Position - root.Position).Magnitude <= (b.Position - root.Position).Magnitude then a else b
	local m = Instance.new("Motor6D")
	m.Name = "Flail"
	m.Part0 = root
	m.Part1 = limb
	m.C0 = root.CFrame:ToObjectSpace(joint)
	m.C1 = limb.CFrame:ToObjectSpace(joint)
	m.Parent = limb
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

local function bubble(root: BasePart, kind: string): BillboardGui
	local gui = Instance.new("BillboardGui")
	gui.Name = "Shout"
	gui.Size = UDim2.fromOffset(150, 44)
	gui.StudsOffsetWorldSpace = Vector3.new(0, root.Size.Y / 2 + (if kind == "Panda" then 2.2 else 1.6), 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 160
	gui.LightInfluence = 0
	local text = Instance.new("TextLabel")
	text.Name = "Text"
	text.Size = UDim2.fromScale(1, 1)
	text.BackgroundTransparency = 1
	text.Font = Enum.Font.LuckiestGuy
	text.TextScaled = true
	text.TextColor3 = Palette.UiCream
	text.Text = ""
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 2
	stroke.Color = Palette.UiInk
	stroke.Parent = text
	text.Parent = gui
	gui.Parent = root
	return gui
end

-- Joint every part of a freshly built NpcBuilder model to its Root and un-anchor all but Root.
local function rig(model: Model, kind: string): BasePart
	local root = model.PrimaryPart :: BasePart
	root.Anchored = true
	root.CanCollide = false
	root.CanTouch = false
	root.CanQuery = true
	root.Massless = false
	if kind == "Panda" then
		root.CustomPhysicalProperties = PhysicalProperties.new(3, 0.9, 0.05) -- heavy, grippy, no bounce
	else
		root.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.6, 0.35) -- light and a bit bouncy
	end
	local parts: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root then
			table.insert(parts, d)
		end
	end
	for _, p in parts do
		if isLimb(model, p.Name) then
			motor(root, p)
		end
	end
	for _, p in parts do
		if not isLimb(model, p.Name) then
			weld(limbOf(model, p.Name) or root, p)
		end
	end
	for _, p in parts do
		p.Anchored = false
		p.CanCollide = false
		p.CanTouch = false
		p.CanQuery = false
		p.Massless = true
	end
	local grab = Instance.new("Attachment")
	grab.Name = "Grab"
	grab.Parent = root
	bubble(root, kind)
	return root
end

function RescueNpcBuilder.build(kind: string, feet: CFrame, pose: string?): Model
	local model = NpcBuilder.Build(kind, feet, { pose = pose or "stand" })
	rig(model, kind)
	return model
end

-- Replace the model's body with a new pose at `feet`, keeping the Model, its attributes, tags and
-- any ProximityPrompt / Sound under Root. Returns the new Root.
function RescueNpcBuilder.rebuild(model: Model, kind: string, feet: CFrame, pose: string?): BasePart
	local fresh = RescueNpcBuilder.build(kind, feet, pose)
	local newRoot = fresh.PrimaryPart :: BasePart
	local oldRoot = model.PrimaryPart
	local text = ""
	if oldRoot then
		for _, c in oldRoot:GetChildren() do
			if c:IsA("ProximityPrompt") or c:IsA("Sound") then
				c.Parent = newRoot
			end
		end
		local old = oldRoot:FindFirstChild("Shout")
		local label = old and old:FindFirstChild("Text")
		if label and label:IsA("TextLabel") then
			text = label.Text
		end
	end
	for _, c in model:GetChildren() do
		c:Destroy()
	end
	for _, c in fresh:GetChildren() do
		c.Parent = model
	end
	model.PrimaryPart = newRoot
	model:SetAttribute("Pose", pose or "stand")
	fresh:Destroy()
	RescueNpcBuilder.shout(model, text)
	return newRoot
end

local function isEye(name: string): boolean
	return string.sub(name, 1, 3) == "Eye" or string.find(name, "Pupil") ~= nil or string.find(name, "Shine") ~= nil
end

function RescueNpcBuilder.toast(model: Model)
	local root = model.PrimaryPart
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and d ~= root and not isEye(d.Name) then
			d.Color = if (string.len(d.Name) % 2) == 0 then Palette.Charred else Palette.CharredWarm
			d.Material = Enum.Material.Slate
		end
	end
	if root and not root:FindFirstChild("Soot") then
		local smoke = Instance.new("Smoke")
		smoke.Name = "Soot"
		smoke.Color = Palette.SmokeBlack
		smoke.Opacity = 0.25
		smoke.RiseVelocity = 3
		smoke.Size = 1.5
		smoke.Parent = root
	end
	model:SetAttribute("Toasted", true)
end

function RescueNpcBuilder.shout(model: Model, text: string?)
	local root = model.PrimaryPart
	local gui = root and root:FindFirstChild("Shout")
	if not gui or not gui:IsA("BillboardGui") then
		return
	end
	local label = gui:FindFirstChild("Text")
	if label and label:IsA("TextLabel") then
		label.Text = text or ""
	end
	gui.Enabled = text ~= nil and text ~= ""
end

function RescueNpcBuilder.setFree(model: Model, free: boolean)
	local root = model.PrimaryPart
	if not root then
		return
	end
	root.CanCollide = free
	root.Anchored = not free
end

return RescueNpcBuilder
