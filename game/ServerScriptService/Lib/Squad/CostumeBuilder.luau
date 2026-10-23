--!strict
-- CostumeBuilder [owner: G3]. Dresses a player's R15 (or R6) character as a trailer firefighter
-- (docs/game/02 §3): yellow turnout coat with lime/silver reflective bands, olive gloves, a big bean
-- head with googly eyes, a red numbered helmet with a gold badge, and an air tank on the back.
-- The look is BORROWED from Lib/Rescue/NpcBuilder (required read-only, never edited): we build its
-- "Firefighter" display model once, then copy its head/helmet/eyes and body/coat/tank parts onto the
-- character, welded to Head and UpperTorso at the same relative offsets. Limbs keep the character's
-- own animated parts, recoloured. Everything is Massless, non-colliding and kept in Folder "Costume".
--   CostumeBuilder.dress(character: Model, helmet: number, player: Player?)
--   CostumeBuilder.setNumber(character: Model, helmet: number)
-- Pupils are attached with Welds (not WeldConstraints) carrying a CFrame attribute "BaseC0", so
-- SquadController can spin them locally for the spiral-eyes Downed look.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript)
local SquadConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("SquadConfig") :: ModuleScript)
local SquadRules = require(script.Parent:WaitForChild("SquadRules") :: ModuleScript)

local CostumeBuilder = {}

local BOOT = Color3.fromHex("#2B2522")

-- NpcBuilder part names -> which character part they ride on.
local HEAD_SET = {
	Head = true,
	Mouth = true,
	Soot = true,
	Brim = true,
	HelmetDome = true,
	HelmetComb = true,
	ShieldHolder = true,
	Shield = true,
	Eye1 = true,
	Eye2 = true,
	Pupil1 = true,
	Pupil2 = true,
}
local BODY_SET = {
	Body = true,
	CoatHem = true,
	Collar = true,
	CollarLine = true,
	Tank = true,
	TankTop = true,
	TankBottom = true,
	TankBand = true,
	TankValve = true,
	Harness = true,
}
local BODY_PREFIX = { "ChestBand", "Toggle", "Strap" }

local function isBody(name: string): boolean
	if BODY_SET[name] then
		return true
	end
	for _, p in BODY_PREFIX do
		if string.sub(name, 1, #p) == p then
			return true
		end
	end
	return false
end

local NpcBuilder: any = nil
local function npcBuilder(): any
	if NpcBuilder == nil then
		local lib = ServerScriptService:FindFirstChild("Lib")
		local rescue = lib and lib:FindFirstChild("Rescue")
		local ms = rescue and rescue:FindFirstChild("NpcBuilder")
		if ms and ms:IsA("ModuleScript") then
			local ok, mod = pcall(require, ms)
			NpcBuilder = if ok then mod else false
		else
			NpcBuilder = false
		end
	end
	return NpcBuilder
end

local function prep(p: BasePart)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

local function recolor(character: Model, names: { string }, color: Color3)
	for _, n in names do
		local part = character:FindFirstChild(n)
		if part and part:IsA("BasePart") then
			part.Color = color
			part.Material = Enum.Material.SmoothPlastic
		end
	end
end

local function band(folder: Instance, limb: BasePart, name: string, y: number)
	-- lime / silver / lime ring, slightly bigger than the limb so it wraps
	local s = limb.Size
	local colors = { Palette.ReflectLime, Palette.ReflectSilver, Palette.ReflectLime }
	for i, c in colors do
		local p = Instance.new("Part")
		p.Name = `{name}{i}`
		p.Size = Vector3.new(s.X + 0.08, 0.12, s.Z + 0.08)
		p.CFrame = limb.CFrame * CFrame.new(0, y + (i - 2) * 0.12, 0)
		p.Color = c
		p.Material = Enum.Material.SmoothPlastic
		prep(p)
		weld(limb, p)
		p.Parent = folder
	end
end

-- Fallback when NpcBuilder is missing: a plain helmet so the number still shows.
local function simpleHelmet(folder: Instance, head: BasePart, helmet: number)
	local dome = Instance.new("Part")
	dome.Name = "HelmetDome"
	dome.Shape = Enum.PartType.Ball
	dome.Size = Vector3.one * 2
	dome.CFrame = head.CFrame * CFrame.new(0, 0.6, 0)
	dome.Color = Palette.HelmetRed
	prep(dome)
	weld(head, dome)
	dome.Parent = folder
	local shield = Instance.new("Part")
	shield.Name = "Shield"
	shield.Size = Vector3.new(1, 0.9, 0.14)
	shield.CFrame = head.CFrame * CFrame.new(0, 0.9, -1) * CFrame.Angles(math.rad(15), 0, 0)
	shield.Color = Palette.HelmetShield
	prep(shield)
	weld(head, shield)
	local gui = Instance.new("SurfaceGui")
	gui.Name = "Number"
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 100
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = Palette.NumberInk
	label.Text = SquadRules.badge(helmet)
	label.Parent = gui
	gui.Parent = shield
	shield.Parent = folder
end

local function nameTag(folder: Instance, head: BasePart, helmet: number, player: Player?)
	local gui = Instance.new("BillboardGui")
	gui.Name = "BadgeTag"
	gui.Size = UDim2.fromOffset(44, 28)
	gui.StudsOffsetWorldSpace = Vector3.new(0, 3.4, 0)
	gui.AlwaysOnTop = true
	gui.MaxDistance = 250
	gui.LightInfluence = 0
	if player then
		gui.PlayerToHideFrom = player
	end
	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundColor3 = Palette.HelmetRed
	label.BackgroundTransparency = 0.15
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = Palette.UiCream
	label.Text = SquadRules.badge(helmet)
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.3, 0)
	corner.Parent = label
	local stroke = Instance.new("UIStroke")
	stroke.Color = Palette.NumberInk
	stroke.Thickness = 2
	stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	stroke.Parent = label
	label.Parent = gui
	gui.Adornee = head
	gui.Parent = folder
end

function CostumeBuilder.dress(character: Model, helmet: number, player: Player?)
	local head = character:FindFirstChild("Head") :: BasePart?
	local torso = (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
	if not head or not torso then
		return
	end
	local old = character:FindFirstChild("Costume")
	if old then
		old:Destroy()
	end
	-- Avatar clothing and hats clash with the uniform.
	for _, d in character:GetChildren() do
		if d:IsA("Accessory") or d:IsA("Shirt") or d:IsA("Pants") or d:IsA("ShirtGraphic") or d:IsA("BodyColors") then
			d:Destroy()
		end
	end
	for _, d in head:GetChildren() do
		if d:IsA("Decal") then
			d.Transparency = 1
		end
	end

	recolor(character, { "UpperTorso", "LowerTorso", "Torso", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm", "Left Arm", "Right Arm" }, Palette.CoatYellow)
	recolor(character, { "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "Left Leg", "Right Leg" }, Palette.CoatShadow)
	recolor(character, { "LeftHand", "RightHand" }, Palette.GloveOlive)
	recolor(character, { "LeftFoot", "RightFoot" }, BOOT)

	local folder = Instance.new("Folder")
	folder.Name = "Costume"

	local builder = npcBuilder()
	local template: Model? = nil
	if builder then
		local ok, m = pcall(builder.Build, "Firefighter", CFrame.identity, { helmet = helmet })
		if ok then
			template = m
		else
			warn(`[CostumeBuilder] NpcBuilder.Build failed: {m}`)
		end
	end

	if template then
		local npcHead = template:FindFirstChild("Head") :: BasePart?
		local npcBody = template:FindFirstChild("Body") :: BasePart?
		local headAnchor = head.CFrame * CFrame.new(SquadConfig.HeadOffset)
		local bodyAnchor = torso.CFrame * CFrame.new(SquadConfig.BodyOffset)
		local eyes: { [string]: BasePart } = {}
		local pupils: { BasePart } = {}
		for _, d in template:GetDescendants() do
			if not d:IsA("BasePart") then
				continue
			end
			local onHead = HEAD_SET[d.Name] == true
			local onBody = not onHead and isBody(d.Name)
			if not (onHead or onBody) then
				continue
			end
			local ref = if onHead then npcHead else npcBody
			if not ref then
				continue
			end
			local rel = ref.CFrame:ToObjectSpace(d.CFrame)
			local anchorCf = if onHead then headAnchor else bodyAnchor
			local p = d:Clone()
			for _, c in p:GetChildren() do
				if c:IsA("JointInstance") or c:IsA("WeldConstraint") then
					c:Destroy()
				end
			end
			p.Name = if d.Name == "Head" then "HeadBlob" elseif d.Name == "Body" then "BodyBlob" else d.Name
			p.CFrame = anchorCf * rel
			prep(p)
			if string.sub(d.Name, 1, 5) == "Pupil" then
				table.insert(pupils, p)
			else
				weld(if onHead then head else torso, p)
				if string.sub(d.Name, 1, 3) == "Eye" then
					eyes[d.Name] = p
				end
			end
			p.Parent = folder
		end
		-- Pupils ride on their eye with a Weld the client can spin (spiral eyes when Downed).
		for _, pupil in pupils do
			local eye = eyes["Eye" .. string.sub(pupil.Name, 6)] or eyes.Eye1
			local w = Instance.new("Weld")
			w.Name = "PupilWeld"
			if eye then
				w.Part0 = eye
				w.C0 = eye.CFrame:ToObjectSpace(pupil.CFrame)
			else
				w.Part0 = head
				w.C0 = head.CFrame:ToObjectSpace(pupil.CFrame)
			end
			w.Part1 = pupil
			w:SetAttribute("BaseC0", w.C0)
			w.Parent = pupil
		end
		template:Destroy()
		head.Transparency = 1 -- the bean head blob replaces it
	else
		simpleHelmet(folder, head, helmet)
	end

	-- Reflective bands on forearms and shins, gloves stay the hand parts.
	for _, n in { "LeftLowerArm", "RightLowerArm" } do
		local limb = character:FindFirstChild(n)
		if limb and limb:IsA("BasePart") then
			band(folder, limb, n .. "Band", -limb.Size.Y / 2 + 0.25)
		end
	end
	for _, n in { "LeftLowerLeg", "RightLowerLeg" } do
		local limb = character:FindFirstChild(n)
		if limb and limb:IsA("BasePart") then
			band(folder, limb, n .. "Band", 0)
		end
	end

	nameTag(folder, head, helmet, player)
	folder:SetAttribute("Helmet", helmet)
	folder.Parent = character
end

function CostumeBuilder.setNumber(character: Model, helmet: number)
	local costume = character:FindFirstChild("Costume")
	if not costume then
		return
	end
	costume:SetAttribute("Helmet", helmet)
	for _, d in costume:GetDescendants() do
		if d:IsA("TextLabel") and (d.Parent and (d.Parent.Name == "Number" or d.Parent.Name == "BadgeTag")) then
			d.Text = SquadRules.badge(helmet)
		end
	end
end

return CostumeBuilder
