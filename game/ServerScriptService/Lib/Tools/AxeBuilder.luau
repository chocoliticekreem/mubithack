--!strict
-- AxeBuilder [owner: Hands agent / axe]. Builds the ONE physical fire axe Tool (ToolService.makeAxe):
--   * Handle (3.2 studs, wood, massless, no collision) - the Tool grip welds it to the RightHand.
--   * Head (red metal block + silver Edge + red Pick, welded together, ~1.3 studs long) hung on a
--     BallSocketConstraint at the top of the handle (cone HandsConfig.AxeHeadDeg, small twist,
--     a little restitution) plus a weak AlignOrientation back to rest, so the metal head FLOPS and
--     wobbles when the arm swings or runs. The head collides with the world but not with players
--     (collision group "AxeHead" vs "Players").
--   * On equip (server): head snapped back onto the handle, network owner = the holder, so the
--     holder simulates the flop smoothly and everyone else sees the same replicated head.
-- The arm that swings it is ClientLib/AxeArm; door damage is HandsService (Hands/AxeHit).
--   AxeBuilder.make(): Tool
--   AxeBuilder.resetHead(tool)   -- put the head back at rest on the handle
--   AxeBuilder.HEAD_GROUP = "AxeHead"

local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Palette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Palette") :: ModuleScript) :: any
local HandsConfig =
	require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HandsConfig") :: ModuleScript) :: any

local AxeBuilder = {}
AxeBuilder.HEAD_GROUP = "AxeHead"
local PLAYER_GROUP = "Players" -- shared with Lib/Tools/HoseLine (characters' parts)

local HANDLE_LEN = 3.2
local GRIP_Y = -1.15 -- the fist sits near the bottom of the handle
local SOCKET_Y = 1.25 -- the head's pivot, just under the head

local groupsReady = false
local function ensureGroups()
	if groupsReady then
		return
	end
	groupsReady = true
	pcall(function()
		for _, g in { AxeBuilder.HEAD_GROUP, PLAYER_GROUP } do
			if not PhysicsService:IsCollisionGroupRegistered(g) then
				PhysicsService:RegisterCollisionGroup(g)
			end
		end
		PhysicsService:CollisionGroupSetCollidable(AxeBuilder.HEAD_GROUP, PLAYER_GROUP, false)
		PhysicsService:CollisionGroupSetCollidable(AxeBuilder.HEAD_GROUP, AxeBuilder.HEAD_GROUP, false)
	end)
end

local function part(name: string, size: Vector3, color: Color3, material: Enum.Material, cf: CFrame): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = true
	p.CFrame = cf
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

-- Head frame relative to the handle at rest.
local HEAD_REST = CFrame.new(0, 1.43, -0.12)

function AxeBuilder.make(): Tool
	ensureGroups()
	local tool = Instance.new("Tool")
	tool.Name = "Axe"
	tool.ToolTip = "Hold to wind up, release to chop (doors, and friends)"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	tool.ManualActivationOnly = false -- Activated/Deactivated = wind-up / chop (ClientLib/AxeArm)
	tool.Grip = CFrame.new(0, GRIP_Y, 0)

	local wood = Palette.BookshelfWood or Color3.fromHex("#8A4A28")
	local red = Palette.HelmetRed or Color3.fromHex("#C0301E")
	local steel = Palette.TruckChrome or Color3.fromHex("#D6D8DC")

	local handle = part("Handle", Vector3.new(0.26, HANDLE_LEN, 0.26), wood, Enum.Material.Wood, CFrame.new())
	handle.Parent = tool
	local wrap = part("GripWrap", Vector3.new(0.32, 0.8, 0.32), Color3.fromHex("#1A1210"), Enum.Material.SmoothPlastic, CFrame.new(0, -1.15, 0))
	wrap.Parent = tool
	weld(handle, wrap)
	local knob = part("Knob", Vector3.new(0.36, 0.16, 0.36), Color3.fromHex("#1A1210"), Enum.Material.SmoothPlastic, CFrame.new(0, -HANDLE_LEN / 2 - 0.02, 0))
	knob.Parent = tool
	weld(handle, knob)

	-- the floppy metal head: one collider (Head) with the edge and pick welded on
	local headCF = HEAD_REST
	local head = part("Head", Vector3.new(0.3, 0.56, 0.62), red, Enum.Material.Metal, headCF)
	head.Massless = false
	head.CanCollide = true
	head.CanQuery = false
	head.CanTouch = true
	head.CollisionGroup = AxeBuilder.HEAD_GROUP
	head.CustomPhysicalProperties = PhysicalProperties.new(tonumber(HandsConfig.AxeHeadDensityV2) or 2, 0.4, 0.3, 1, 1)
	head.Parent = tool
	local edge = part("Edge", Vector3.new(0.16, 0.86, 0.26), steel, Enum.Material.Metal, headCF * CFrame.new(0, 0, -0.43))
	edge.Parent = tool
	weld(head, edge)
	local edgeTip = part("EdgeTip", Vector3.new(0.1, 0.92, 0.08), Color3.fromHex("#F4F6F8"), Enum.Material.Metal, headCF * CFrame.new(0, 0, -0.58))
	edgeTip.Parent = tool
	weld(head, edgeTip)
	local pick = Instance.new("WedgePart")
	pick.Name = "Pick"
	pick.Size = Vector3.new(0.18, 0.26, 0.5)
	pick.Color = red
	pick.Material = Enum.Material.Metal
	pick.CanCollide = false
	pick.CanQuery = false
	pick.CanTouch = false
	pick.Massless = true
	-- the wedge's slope points the pick backwards (+Z) and slightly down
	pick.CFrame = headCF * CFrame.new(0, 0.05, 0.55) * CFrame.Angles(0, math.rad(180), 0)
	pick.Parent = tool
	weld(head, pick)

	-- socket at the top of the handle; the attachments' primary (X) axis runs up the handle
	local socketCF = CFrame.new(0, SOCKET_Y, 0) * CFrame.Angles(0, 0, math.rad(90))
	local a0 = Instance.new("Attachment")
	a0.Name = "AxeSocket"
	a0.CFrame = socketCF
	a0.Parent = handle
	local a1 = Instance.new("Attachment")
	a1.Name = "AxeSocket"
	a1.CFrame = headCF:Inverse() * socketCF
	a1.Parent = head
	local sock = Instance.new("BallSocketConstraint")
	sock.Name = "AxeHeadSocket"
	sock.Attachment0 = a0
	sock.Attachment1 = a1
	sock.LimitsEnabled = true
	sock.UpperAngle = tonumber(HandsConfig.AxeHeadDeg) or 40
	sock.TwistLimitsEnabled = true
	local twist = tonumber(HandsConfig.AxeHeadTwistDeg) or 12
	sock.TwistLowerAngle = -twist
	sock.TwistUpperAngle = twist
	sock.Restitution = tonumber(HandsConfig.AxeHeadRestitution) or 0.25
	sock.Parent = head
	-- weak pull back to rest: damps the wobble without making it rigid
	local spring = Instance.new("AlignOrientation")
	spring.Name = "AxeHeadSpring"
	spring.Mode = Enum.OrientationAlignmentMode.TwoAttachment
	spring.Attachment0 = a1
	spring.Attachment1 = a0
	spring.Responsiveness = tonumber(HandsConfig.AxeHeadSpring) or 12
	spring.MaxTorque = tonumber(HandsConfig.AxeHeadSpringTorque) or 40
	spring.ReactionTorqueEnabled = true
	spring.Parent = head
	local nc = Instance.new("NoCollisionConstraint")
	nc.Part0 = head
	nc.Part1 = handle
	nc.Parent = head

	-- swing trail on the blade: only shows while the head moves fast
	local t0 = Instance.new("Attachment")
	t0.Name = "Trail0"
	t0.Position = Vector3.new(0, 0.42, -0.6)
	t0.Parent = head
	local t1 = Instance.new("Attachment")
	t1.Name = "Trail1"
	t1.Position = Vector3.new(0, -0.42, -0.6)
	t1.Parent = head
	local trail = Instance.new("Trail")
	trail.Attachment0 = t0
	trail.Attachment1 = t1
	trail.Lifetime = 0.16
	trail.MinLength = 0.1
	trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
	trail.Transparency = NumberSequence.new(0.35, 1)
	trail.LightEmission = 0.4
	trail.FaceCamera = true
	trail.Parent = head

	tool:SetAttribute("AxeHeadRest", HEAD_REST)
	tool.Equipped:Connect(function()
		AxeBuilder.onEquipped(tool)
	end)
	return tool
end

function AxeBuilder.resetHead(tool: Tool)
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	local head = tool:FindFirstChild("Head") :: BasePart?
	if not (handle and head) then
		return
	end
	head.CFrame = handle.CFrame * HEAD_REST
	head.AssemblyLinearVelocity = handle.AssemblyLinearVelocity
	head.AssemblyAngularVelocity = Vector3.zero
end

-- Server, on equip: claim the holder's body for the "Players" group (so the head never hits its own
-- holder), put the head back on the handle and give the holder its physics.
function AxeBuilder.onEquipped(tool: Tool)
	local char = tool.Parent
	local player = if char and char:IsA("Model") then Players:GetPlayerFromCharacter(char) else nil
	if not (player and char) then
		return
	end
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") and d.CollisionGroup == "Default" and not d:IsDescendantOf(tool) then
			d.CollisionGroup = PLAYER_GROUP
		end
	end
	AxeBuilder.resetHead(tool)
	task.defer(function()
		local head = tool:FindFirstChild("Head") :: BasePart?
		if head and tool.Parent == char and head:IsDescendantOf(workspace) then
			AxeBuilder.resetHead(tool)
			pcall(function()
				if head:CanSetNetworkOwnership() then
					head:SetNetworkOwner(player)
				end
			end)
		end
	end)
end

return AxeBuilder
