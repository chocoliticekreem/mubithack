--!strict
-- PenguinBuilder [owner: Squad/costume]. Turns a dressed player firefighter into a goofy cartoon
-- penguin firefighter. Called by CostumeBuilder.dress (when PenguinConfig.Enabled) on the Costume
-- folder BEFORE it is parented, so every weld captures its offset when the folder goes live.
--   PenguinBuilder.apply(character: Model, costume: Folder)
-- Keeps the R15 rig, Humanoid, HipHeight and every collider as-is (physics hands, axe IK, ragdoll,
-- seats, tools all depend on them). It only:
--   * strips the coat bits (PenguinRules.strip), keeps helmet + number shield, googly eyes, collar,
--     air tank and harness;
--   * recolours HeadBlob / BodyBlob / limbs black, feet orange;
--   * adds a white belly + face patch, an orange (slightly open) beak, flipper paddles on the arms
--     and flat orange feet with toes.
-- Everything added is Massless, CanCollide/CanQuery/CanTouch false, inside the Costume folder, so
-- the default first-person transparency hides it like the rest of the costume.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PenguinConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("PenguinConfig") :: ModuleScript) :: any
local PenguinRules = require(script.Parent:WaitForChild("PenguinRules") :: ModuleScript)

local PenguinBuilder = {}

local function color(key: string): Color3
	return Color3.fromHex(PenguinConfig[key])
end

local function prep(p: BasePart)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	p.Material = Enum.Material.SmoothPlastic
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

-- Ellipsoid (block + sphere mesh) welded to `to`.
local function blob(folder: Instance, to: BasePart, name: string, cf: CFrame, size: Vector3, c: Color3): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = c
	prep(p)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = p
	weld(to, p)
	p.Parent = folder
	return p
end

local function v3(t: any): Vector3
	return Vector3.new(t.x, t.y, t.z)
end

-- White inner ellipsoid on the front of an outer blob (belly on the body, face patch on the head).
local function patch(folder: Instance, outer: BasePart, to: BasePart, name: string, scale: any, drop: number)
	local s = outer.Size
	local sx, sy, sz, dy, dz = PenguinRules.patch({ x = s.X, y = s.Y, z = s.Z }, scale, drop)
	blob(folder, to, name, outer.CFrame * CFrame.new(0, dy, dz), Vector3.new(sx, sy, sz), color("White"))
end

local function head(character: Model, costume: Instance, mouthCf: CFrame?)
	local rigHead = character:FindFirstChild("Head") :: BasePart?
	local headBlob = costume:FindFirstChild("HeadBlob") :: BasePart?
	if not rigHead then
		return
	end
	local face = headBlob or rigHead
	if headBlob then
		headBlob.Color = color("Black")
		headBlob.Material = Enum.Material.SmoothPlastic
		patch(costume, headBlob, rigHead, "PenguinFace", PenguinConfig.FaceScale, PenguinConfig.FaceDrop)
	else
		rigHead.Color = color("Black")
	end
	-- beak where the mouth was (or low on the front of the head)
	local at = mouthCf or face.CFrame * CFrame.new(0, -face.Size.Y * 0.18, -face.Size.Z / 2)
	local bs = v3(PenguinConfig.BeakSize)
	blob(costume, rigHead, "BeakUpper", at * CFrame.new(0, 0.12, -bs.Z * 0.42) * CFrame.Angles(math.rad(6), 0, 0), bs, color("Beak"))
	-- lower beak hangs a little open: maximum goof
	local ls = Vector3.new(bs.X * 0.8, bs.Y * 0.75, bs.Z * 0.75)
	blob(costume, rigHead, "BeakLower", at * CFrame.new(0, -0.1, -ls.Z * 0.4) * CFrame.Angles(math.rad(-16), 0, 0), ls, color("BeakLower"))
end

local function body(character: Model, costume: Instance)
	local torso = (character:FindFirstChild("UpperTorso") or character:FindFirstChild("Torso")) :: BasePart?
	local bodyBlob = costume:FindFirstChild("BodyBlob") :: BasePart?
	if not torso or not bodyBlob then
		return
	end
	bodyBlob.Color = color("Black")
	bodyBlob.Material = Enum.Material.SmoothPlastic
	patch(costume, bodyBlob, torso, "PenguinBelly", PenguinConfig.BellyScale, PenguinConfig.BellyDrop)
	-- harness straps ride on top of the belly (welds are not live yet, so moving them is safe)
	local push = bodyBlob.Size.Z * 0.07
	for _, d in costume:GetChildren() do
		if d:IsA("BasePart") and string.sub(d.Name, 1, 5) == "Strap" then
			d.CFrame = d.CFrame * CFrame.new(0, 0, -push)
		end
	end
end

local function flippers(character: Model, costume: Instance)
	local thick = PenguinConfig.FlipperThick :: number
	local wide = PenguinConfig.FlipperWide :: number
	for _, side in { "Left", "Right" } do
		local upper = character:FindFirstChild(side .. "UpperArm") :: BasePart?
		local lower = character:FindFirstChild(side .. "LowerArm") :: BasePart?
		if upper then
			blob(costume, upper, side .. "FlipperUpper", upper.CFrame * CFrame.new(0, 0.05, 0), Vector3.new(thick, upper.Size.Y + 0.35, wide), color("Black"))
		end
		if lower then
			blob(costume, lower, side .. "FlipperLower", lower.CFrame * CFrame.new(0, -0.15, 0), Vector3.new(thick * 0.9, lower.Size.Y + 0.55, wide * 0.85), color("Black"))
		end
		-- R6 fallback: one paddle on the whole arm
		local arm = character:FindFirstChild(side .. " Arm") :: BasePart?
		if arm then
			blob(costume, arm, side .. "Flipper", arm.CFrame, Vector3.new(thick, arm.Size.Y + 0.3, wide), color("Black"))
		end
	end
end

local function feet(character: Model, costume: Instance)
	local fs = v3(PenguinConfig.FootSize)
	for _, side in { "Left", "Right" } do
		local foot = (character:FindFirstChild(side .. "Foot") or character:FindFirstChild(side .. " Leg")) :: BasePart?
		if not foot then
			continue
		end
		local base = foot.CFrame * CFrame.new(0, -foot.Size.Y / 2 + fs.Y / 2, -0.3)
		blob(costume, foot, side .. "PenguinFoot", base, fs, color("Feet"))
		for i, x in { -0.38, 0, 0.38 } do
			local toe = Vector3.new(0.42, fs.Y * 0.9, 0.5)
			blob(costume, foot, `{side}Toe{i}`, base * CFrame.new(x * fs.X, 0, -fs.Z / 2 + 0.05), toe, color("Feet"))
		end
	end
end

function PenguinBuilder.apply(character: Model, costume: Instance)
	local mouth = costume:FindFirstChild("Mouth") :: BasePart?
	local mouthCf = if mouth then mouth.CFrame else nil
	for _, d in costume:GetChildren() do
		if d:IsA("BasePart") and PenguinRules.strip(d.Name) then
			d:Destroy()
		end
	end
	for _, d in character:GetChildren() do
		if d:IsA("BasePart") then
			local key = PenguinRules.limbColor(d.Name)
			if key then
				d.Color = color(key)
				d.Material = Enum.Material.SmoothPlastic
			end
		end
	end
	head(character, costume, mouthCf)
	body(character, costume)
	flippers(character, costume)
	feet(character, costume)
	costume:SetAttribute("Penguin", true)
end

return PenguinBuilder
