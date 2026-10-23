--!strict
-- PhysicsHands [owner: Hands agent]. The trailer's big gloved first-person hands, as physics:
--   * Each glove is a local, unanchored assembly in workspace (never replicated) pulled toward a
--     sprung target pose by AlignPosition + AlignOrientation. The target itself runs through an
--     underdamped spring (HandsMath), so hands lag, overshoot and wobble; the palm collides with the
--     world, so it bumps walls, presses on doors and shoves props. Stretchy turnout sleeves run from
--     the shoulder to each wrist.
--   * Input (desktop): no tool -> LMB = left hand, RMB = right hand: hold to reach toward the
--     crosshair and grab what's there, release to let go (throws keep momentum). Both hands on one
--     heavy thing lifts it. Holding a tool -> LMB uses it (ToolController sprays; the axe winds up
--     while held and swings on release) and RMB is the free left hand. Swing a hand into a teammate
--     to slap them (HandsService knocks them back; a downed teammate is slapped awake).
--   * Held tools: the equipped Tool's parts are cloned into a local physics item welded to the
--     right glove (the real Tool is hidden locally by FirstPersonController). The axe head hangs on
--     a BallSocketConstraint so it flops; its measured head speed when it hits a Door is the damage
--     (Hands/AxeHit -> HandsMath.axeHits). The hose nozzle bucks with recoil while spraying; the
--     extinguisher sputters.
--   * Replication: the local hand positions (HumanoidRootPart space) go to HandsService at
--     HandsConfig.PoseHz; PhysicsHands.startRemote() aims every other player's shoulders at their
--     replicated hands so everyone sees reaching, slapping and wind-ups.
--
--   local hands = PhysicsHands.new()     -- from a controller's Start, never at require time
--   hands:BindInput()
--   hands:Update(dt, camCFrame, frame)   -- every RenderStepped after the camera (frame below)
--   hands:SetActive(false)               -- park: hide, drop grips, release the held item
--   hands:SetSoot(alpha)  hands:GetNozzle(): Attachment?  hands:Destroy()
--   PhysicsHands.startRemote(onFx)       -- once per client: remote arms + Hands/Fx pops
-- Remotes used (declared by HandsService): Hands/Pose, Poses, Grab, Release, Slap, Push, AxeHit, Fx.

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Names = require(Shared:WaitForChild("Names") :: ModuleScript) :: any
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local HandsMath = require(ReplicatedStorage:WaitForChild("HandsMath") :: ModuleScript)
local HandsConfig =
	require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HandsConfig") :: ModuleScript) :: any
local Viewmodel = require(script.Parent:WaitForChild("Viewmodel") :: ModuleScript)

local LocalPlayer = Players.LocalPlayer

export type Frame = {
	pose: string, -- "empty" | "hose" | "axe" | "carry" | "item" (FirstPersonController.poseFor)
	tool: Tool?,
	bob: Vector2?,
	sway: Vector2?,
	dip: number?,
	spraying: boolean?,
	pressure: number?, -- 0..1 hose/foam pressure for the kick
}

type Vec = HandsMath.Vec

type Grip = {
	part: BasePart,
	att: Attachment,
	joint: Constraint,
	nocollide: { Instance },
	verdict: string,
}

type Hand = {
	side: string,
	sign: number,
	palm: BasePart, -- invisible physics collider; the glove you see is `rig`
	rig: Viewmodel.Rig,
	curl: number,
	wrist: Attachment,
	gripAtt: Attachment,
	ap: AlignPosition,
	ao: AlignOrientation,
	sp: Vec,
	sv: Vec,
	pressed: boolean,
	reachT: number,
	aimPart: BasePart?,
	aimPos: Vector3?,
	target: CFrame,
	stuck: number,
	grip: Grip?,
	pending: boolean,
	denyUntil: number,
	probeAt: number,
	cooldown: { [Instance]: number },
	hitStop: number,
}

type Item = {
	model: Model,
	kind: string,
	tool: Tool,
	head: BasePart?, -- axe head (ball socket)
	nozzle: Attachment?,
	lastHeadPos: Vector3?,
	prevManual: boolean?,
}

local PhysicsHands = {}
PhysicsHands.__index = PhysicsHands

export type PhysicsHands = typeof(setmetatable(
	{} :: {
		folder: Folder,
		visual: Model,
		hands: { [string]: Hand },
		active: boolean,
		item: Item?,
		toolFor: Tool?,
		charNoCollide: { Instance },
		noCollideFor: Model?,
		t: number,
		windStart: number?,
		windCharge: number,
		strikeT: number,
		strikeFrom: number,
		strikeShook: boolean,
		axeCooldown: number,
		sendAt: number,
		kickAt: number,
		soot: number,
		conns: { RBXScriptConnection },
		remotes: { [string]: any },
	},
	PhysicsHands
))

-- helpers ----------------------------------------------------------------------------------------
local function scale(): number
	return math.clamp(tonumber(HandsConfig.GloveScale) or 0.5, 0.2, 1.5)
end

local function remote(name: string): any
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Hands")
	return ns and ns:FindFirstChild(name)
end

local function poseCFrame(p: HandsMath.Pose): CFrame
	return CFrame.Angles(math.rad(p.rx), math.rad(p.ry), math.rad(p.rz))
end

local function toVec(v: Vector3): Vec
	return { x = v.X, y = v.Y, z = v.Z }
end

local function charOf(): Model?
	return LocalPlayer.Character
end

local function rootOf(char: Model?): BasePart?
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function toolKind(tool: Tool?): string?
	if not tool then
		return nil
	end
	local n = string.lower(tool.Name)
	if string.find(n, "axe") then
		return "axe"
	elseif string.find(n, "hose") or string.find(n, "nozzle") then
		return "hose"
	elseif string.find(n, "extinguish") then
		return "extinguisher"
	end
	return "item"
end

local function humanoidModel(part: BasePart): Model?
	local m = part:FindFirstAncestorWhichIsA("Model")
	while m do
		if m:FindFirstChildOfClass("Humanoid") then
			return m
		end
		m = m:FindFirstAncestorWhichIsA("Model")
	end
	return nil
end

-- Mirrors HandsService's denylist so we don't reach for things the server will refuse.
local function grabbable(part: BasePart, char: Model?): boolean
	if part.Anchored or part:GetAttribute("NoGrab") == true or CollectionService:HasTag(part, Names.Tag.Door) then
		return false
	end
	local root = part.AssemblyRootPart
	if root and root.Anchored then
		return false
	end
	if char and part:IsDescendantOf(char) then
		return false
	end
	local node: Instance? = part.Parent
	while node and node ~= workspace do
		if node:IsA("Model") then
			if
				node:FindFirstChildOfClass("Humanoid")
				or node:GetAttribute("OwnerUserId") ~= nil
				or node:GetAttribute("NoGrab") == true
				or CollectionService:HasTag(node, Names.Tag.Truck)
				or CollectionService:HasTag(node, Names.Tag.Rescuable)
			then
				return false
			end
		end
		node = node.Parent
	end
	local heldBy = (root or part):GetAttribute("HeldBy")
	return heldBy == nil or heldBy == LocalPlayer.UserId
end

local function noCollide(a: BasePart, b: BasePart, parent: Instance): NoCollisionConstraint
	local n = Instance.new("NoCollisionConstraint")
	n.Part0 = a
	n.Part1 = b
	n.Parent = parent
	return n
end

local function limbs(char: Model): { BasePart }
	local out = {}
	for _, c in char:GetChildren() do
		if c:IsA("BasePart") then
			table.insert(out, c)
		end
	end
	return out
end

-- pops ("SLAP!", "THUNK") --------------------------------------------------------------------------
local POP_TEXT: { [string]: { any } } = {
	slap = { "SLAP!", Color3.fromHex("#FF6B5A") },
	bonk = { "BONK!", Color3.fromHex("#FFD24A") },
	thunk = { "THUNK!", Color3.fromHex("#FFFFFF") },
	tonk = { "tonk", Color3.fromHex("#C9CCD0") },
	heavy = { "TOO HEAVY!", Color3.fromHex("#FFB12B") },
	both = { "USE BOTH HANDS!", Color3.fromHex("#FFB12B") },
}

local function pop(kind: string, position: Vector3)
	local spec = POP_TEXT[kind]
	if not spec then
		return
	end
	local att = Instance.new("Attachment")
	att.Name = "HandsPop"
	att.WorldPosition = position
	att.Parent = workspace.Terrain
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 70)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 120
	gui.Parent = att
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.FredokaOne
	label.TextScaled = true
	label.Text = spec[1]
	label.TextColor3 = spec[2]
	label.TextStrokeTransparency = 0
	label.TextStrokeColor3 = Palette.NumberInk or Color3.new(0, 0, 0)
	label.Rotation = math.random(-12, 12)
	label.Parent = gui
	local info = TweenInfo.new(0.7, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	TweenService:Create(gui, info, { StudsOffsetWorldSpace = Vector3.new(0, 2.5, 0) }):Play()
	TweenService:Create(label, info, { TextTransparency = 1, TextStrokeTransparency = 1 }):Play()
	Debris:AddItem(att, 0.8)
end
PhysicsHands.pop = pop

local function playSound(id: string, parent: Instance, volume: number)
	if id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.PlaybackSpeed = Random.new():NextNumber(0.9, 1.12)
	s.Parent = parent
	s:Play()
	Debris:AddItem(s, 3)
end

-- construction -----------------------------------------------------------------------------------
local function buildHand(folder: Folder, visual: Model, side: string): Hand
	local sign = if side == "R" then 1 else -1
	local s = scale()
	local model = Instance.new("Model")
	model.Name = side .. "Hand"
	model.Parent = folder
	-- the collider: a palm-sized box at the palm centre (wrist-relative), never drawn
	local palmOffset = CFrame.new(0, 0, -0.5 * s)
	local palm = Instance.new("Part")
	palm.Name = side .. "Palm"
	palm.Size = Vector3.new(1.0, 0.48, 0.86) * s
	palm.Transparency = 1
	palm.CastShadow = false
	palm.Anchored = true
	palm.CanCollide = false -- turned on by SetActive(true)
	palm.Massless = false
	palm.CustomPhysicalProperties = PhysicalProperties.new(HandsConfig.HandDensity, 0.8, 0.25, 1, 1)
	palm.Parent = model
	model.PrimaryPart = palm
	local palmInv = palmOffset:Inverse()
	-- Wrist attachment: its world frame IS the wrist frame the poses describe.
	local wrist = Instance.new("Attachment")
	wrist.Name = "Wrist"
	wrist.CFrame = palmInv
	wrist.Parent = palm
	local gripAtt = Instance.new("Attachment")
	gripAtt.Name = "Grip"
	gripAtt.CFrame = palmInv * CFrame.new(0, -0.34 * s, -0.82 * s)
	gripAtt.Parent = palm
	local rig = Viewmodel.newRig(visual, sign, if side == "R" then "Right" else "Left", s)

	local ap = Instance.new("AlignPosition")
	ap.Mode = Enum.PositionAlignmentMode.OneAttachment
	ap.Attachment0 = wrist
	ap.Responsiveness = HandsConfig.HandResponsiveness
	ap.MaxForce = HandsConfig.HandMaxForce
	ap.MaxVelocity = HandsConfig.HandMaxVelocity
	ap.Parent = palm
	local ao = Instance.new("AlignOrientation")
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.Attachment0 = wrist
	ao.Responsiveness = HandsConfig.HandRotResponsiveness
	ao.MaxTorque = HandsConfig.HandMaxTorque
	ao.Parent = palm

	palm.CanQuery = false
	palm.CanTouch = false

	local p = HandsMath.pose("idle", side)
	return {
		side = side,
		sign = sign,
		palm = palm,
		rig = rig,
		curl = 0.3,
		wrist = wrist,
		gripAtt = gripAtt,
		ap = ap,
		ao = ao,
		sp = { x = p.x, y = p.y, z = p.z },
		sv = { x = 0, y = 0, z = 0 },
		pressed = false,
		reachT = 0,
		aimPart = nil,
		aimPos = nil,
		target = CFrame.identity,
		stuck = 0,
		grip = nil,
		pending = false,
		denyUntil = 0,
		probeAt = 0,
		cooldown = setmetatable({}, { __mode = "k" }) :: any,
		hitStop = 0,
	}
end

function PhysicsHands.new(): PhysicsHands
	local folder = Instance.new("Folder")
	folder.Name = "PhysicsHands_" .. LocalPlayer.Name
	folder.Parent = workspace
	-- what you see: the glove rigs, drawn in the Camera (local, unsimulated, no shadows cast)
	local visual = Instance.new("Model")
	visual.Name = "FirstPersonHands"
	local self = setmetatable({
		folder = folder,
		visual = visual,
		hands = { L = buildHand(folder, visual, "L"), R = buildHand(folder, visual, "R") },
		active = false,
		item = nil,
		toolFor = nil,
		charNoCollide = {},
		noCollideFor = nil,
		t = 0,
		windStart = nil,
		windCharge = 0,
		strikeT = -1,
		strikeFrom = 0,
		strikeShook = true,
		axeCooldown = 0,
		sendAt = 0,
		kickAt = 0,
		soot = 0,
		conns = {},
		remotes = {},
	} :: any, PhysicsHands)
	return self
end

-- character collisions ---------------------------------------------------------------------------
-- Own body never collides with the gloves, the held item or grabbed props.
function PhysicsHands._refreshNoCollide(self: PhysicsHands, char: Model?)
	if self.noCollideFor == char then
		return
	end
	for _, n in self.charNoCollide do
		n:Destroy()
	end
	table.clear(self.charNoCollide)
	self.noCollideFor = char
	if not char then
		return
	end
	local body = limbs(char)
	for _, hand in self.hands do
		for _, b in body do
			table.insert(self.charNoCollide, noCollide(hand.palm, b, self.folder))
		end
	end
	local item = self.item
	if item and item.head then
		for _, b in body do
			table.insert(self.charNoCollide, noCollide(item.head, b, self.folder))
		end
	end
end

-- grips ------------------------------------------------------------------------------------------
local function gripsOn(self: PhysicsHands, root: BasePart): number
	local n = 0
	for _, h in self.hands do
		local g = h.grip
		if g and (g.part.AssemblyRootPart or g.part) == root then
			n += 1
		end
	end
	return n
end

function PhysicsHands._release(self: PhysicsHands, hand: Hand, throw: boolean)
	local g = hand.grip
	if not g then
		return
	end
	hand.grip = nil
	g.joint:Destroy()
	g.att:Destroy()
	local part = g.part
	-- keep our body out of its way for a moment so a throw doesn't bounce off our own face
	local nc = g.nocollide
	task.delay(0.4, function()
		for _, n in nc do
			n:Destroy()
		end
	end)
	if throw and part.Parent and gripsOn(self, part.AssemblyRootPart or part) == 0 then
		pcall(function()
			part.AssemblyLinearVelocity *= HandsConfig.ThrowBoost
		end)
	end
	local r = remote("Release")
	if r then
		r:FireServer(part, hand.side)
	end
end

function PhysicsHands._attach(self: PhysicsHands, hand: Hand, part: BasePart, at: Vector3, verdict: string)
	local att = Instance.new("Attachment")
	att.Name = "HandGrip_" .. hand.side
	att.Parent = part
	att.WorldPosition = at
	local joint = Instance.new("BallSocketConstraint")
	joint.Name = "HandGrip_" .. hand.side
	joint.Attachment0 = hand.gripAtt
	joint.Attachment1 = att
	joint.Parent = self.folder
	local nc = { noCollide(hand.palm, part, self.folder) }
	local char = charOf()
	if char then
		for _, b in limbs(char) do
			table.insert(nc, noCollide(part, b, self.folder))
		end
	end
	hand.grip = { part = part, att = att, joint = joint, nocollide = nc, verdict = verdict }
	playSound(HandsConfig.SoundGrab, hand.palm, 0.6)
	if verdict == "heavy" then
		pop("both", at)
	end
end

function PhysicsHands._tryGrab(self: PhysicsHands, hand: Hand)
	local part, at = hand.aimPart, hand.aimPos
	if not (part and at) or hand.pending or os.clock() < hand.denyUntil then
		return
	end
	local fn = remote("Grab")
	if not fn then
		return
	end
	hand.pending = true
	task.spawn(function()
		local ok, verdict = pcall(function()
			return fn:InvokeServer(part, hand.side)
		end)
		hand.pending = false
		local granted = ok and (verdict == "ok" or verdict == "heavy")
		if not granted then
			hand.denyUntil = os.clock() + 0.6
			return
		end
		if not hand.pressed or hand.grip or not part.Parent or not self.active then
			local r = remote("Release")
			if r then
				r:FireServer(part, hand.side)
			end
			return
		end
		self:_attach(hand, part, at, verdict :: string)
	end)
end

-- held tool item ---------------------------------------------------------------------------------
local STRIP = { "JointInstance", "WeldConstraint", "Constraint", "BaseScript", "Sound", "ProximityPrompt", "TouchTransmitter" }

local function strip(inst: Instance)
	for _, d in inst:GetDescendants() do
		for _, cls in STRIP do
			if d:IsA(cls) then
				d:Destroy()
				break
			end
		end
	end
end

function PhysicsHands._dropItem(self: PhysicsHands)
	local item = self.item
	self.item = nil
	self.toolFor = nil
	if not item then
		return
	end
	if item.prevManual ~= nil and item.tool.Parent then
		item.tool.ManualActivationOnly = item.prevManual
	end
	item.model:Destroy()
	self.noCollideFor = nil -- rebuild without the old axe head
	self.windStart = nil
	self.strikeT = -1
end

function PhysicsHands._equip(self: PhysicsHands, tool: Tool?)
	if self.toolFor == tool then
		return
	end
	self:_dropItem()
	self.toolFor = tool
	if not tool then
		return
	end
	local handle = tool:FindFirstChild("Handle")
	if not (handle and handle:IsA("BasePart")) then
		return
	end
	local kind = toolKind(tool) :: string
	local hand = self.hands.R
	local model = Instance.new("Model")
	model.Name = "HeldItem"
	model.Parent = self.folder -- in the world before welding, so WeldConstraints record real offsets
	local handleCF = hand.gripAtt.WorldCFrame * tool.Grip:Inverse()
	local srcHandle = handle :: BasePart
	local clones: { [BasePart]: BasePart } = {}
	for _, d in tool:GetDescendants() do
		if d:IsA("BasePart") then
			local c = d:Clone()
			strip(c)
			for _, child in c:GetChildren() do
				if child:IsA("BasePart") then
					child:Destroy() -- nested parts get their own clone
				end
			end
			c.Anchored = false
			c.CanCollide = false
			c.CanQuery = false
			c.CanTouch = false
			c.Massless = true
			c.LocalTransparencyModifier = 0
			c.CFrame = handleCF * srcHandle.CFrame:ToObjectSpace(d.CFrame)
			c.Parent = model
			clones[d] = c
		end
	end
	local cHandle = clones[srcHandle]
	local item: Item = { model = model, kind = kind, tool = tool, head = nil, nozzle = nil }
	-- The axe: everything that isn't the handle is the head, hung on a ball socket at the handle top.
	local headParts: { BasePart } = {}
	for src, c in clones do
		if src ~= srcHandle and kind == "axe" then
			table.insert(headParts, c)
		elseif src ~= srcHandle then
			local w = Instance.new("WeldConstraint")
			w.Part0 = cHandle
			w.Part1 = c
			w.Parent = c
		end
	end
	local w = Instance.new("WeldConstraint")
	w.Part0 = hand.palm
	w.Part1 = cHandle
	w.Parent = cHandle
	if kind == "axe" and #headParts > 0 then
		local head = headParts[1]
		for _, p in headParts do
			if p.Name == "Head" then
				head = p
			end
		end
		for _, p in headParts do
			if p ~= head then
				local hw = Instance.new("WeldConstraint")
				hw.Part0 = head
				hw.Part1 = p
				hw.Parent = p
			end
			p.CanCollide = true
		end
		head.Massless = false
		head.CustomPhysicalProperties = PhysicalProperties.new(HandsConfig.AxeHeadDensity, 0.5, 0.35, 1, 1)
		-- socket at the top of the handle; the attachments' primary (X) axis runs up the handle
		local topCF = cHandle.CFrame * CFrame.new(0, cHandle.Size.Y / 2 - 0.15, 0) * CFrame.Angles(0, 0, math.rad(90))
		local a0 = Instance.new("Attachment")
		a0.Name = "AxeSocket"
		a0.Parent = cHandle
		a0.WorldCFrame = topCF
		local a1 = Instance.new("Attachment")
		a1.Name = "AxeSocket"
		a1.Parent = head
		a1.WorldCFrame = topCF
		local sock = Instance.new("BallSocketConstraint")
		sock.Attachment0 = a0
		sock.Attachment1 = a1
		sock.LimitsEnabled = true
		sock.UpperAngle = HandsConfig.AxeHeadFlopDeg
		sock.TwistLimitsEnabled = true
		sock.TwistLowerAngle = -25
		sock.TwistUpperAngle = 25
		sock.Restitution = 0.35
		sock.Parent = head
		noCollide(head, cHandle, model)
		noCollide(head, hand.palm, model)
		noCollide(head, self.hands.L.palm, model)
		item.head = head
		-- clicks belong to the physical swing now, not ToolService's proximity swing
		item.prevManual = tool.ManualActivationOnly
		tool.ManualActivationOnly = true
	end
	local nozzle = cHandle:FindFirstChild("Nozzle")
	if nozzle and nozzle:IsA("Attachment") then
		item.nozzle = nozzle
	end
	self.item = item
	self.noCollideFor = nil -- include the axe head in the body no-collide set
end

-- input ------------------------------------------------------------------------------------------
function PhysicsHands._button(self: PhysicsHands, which: number, down: boolean)
	if not self.active then
		return
	end
	local carrying = LocalPlayer:GetAttribute(Names.Attr.Carrying)
	if down and type(carrying) == "string" and carrying ~= "" then
		return -- arms are full (RescueService carry)
	end
	local item = self.item
	local hand: Hand
	if item then
		if which == 1 then
			if item.kind == "axe" then
				if down then
					if self.strikeT < 0 then
						self.windStart = self.t
					end
				elseif self.windStart then
					self.strikeFrom = self.windCharge
					self.windStart = nil
					self.strikeT = 0
					self.strikeShook = false
				end
			end
			return -- hose/extinguisher/other: ToolController owns LMB through Tool.Activated
		end
		hand = self.hands.L
	else
		hand = if which == 1 then self.hands.L else self.hands.R
	end
	hand.pressed = down
	if not down then
		self:_release(hand, true)
	end
end

function PhysicsHands.BindInput(self: PhysicsHands)
	table.insert(
		self.conns,
		UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
			-- with the mouse locked to the crosshair a "processed" click is a Tool click, not a GUI one
			if processed and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
				return
			end
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				self:_button(1, true)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:_button(2, true)
			elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
				self:_button(2, true)
			end
		end)
	)
	table.insert(
		self.conns,
		UserInputService.InputEnded:Connect(function(input: InputObject)
			if input.UserInputType == Enum.UserInputType.MouseButton1 then
				self:_button(1, false)
			elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
				self:_button(2, false)
			elseif input.KeyCode == Enum.KeyCode.ButtonL2 then
				self:_button(2, false)
			end
		end)
	)
end

-- activation -------------------------------------------------------------------------------------
function PhysicsHands.SetActive(self: PhysicsHands, on: boolean)
	if self.active == on then
		return
	end
	self.active = on
	for _, hand in self.hands do
		if not on then
			hand.pressed = false
			self:_release(hand, false)
		end
		hand.palm.Anchored = not on
		hand.palm.CanCollide = on
		hand.stuck = if on then math.huge else 0 -- snap straight to the pose on wake
	end
	self.visual.Parent = if on then workspace.CurrentCamera else nil
	if not on then
		self:_dropItem()
	end
end

function PhysicsHands.SetSoot(self: PhysicsHands, alpha: number)
	alpha = math.clamp(alpha, 0, 1)
	if math.abs(alpha - self.soot) < 0.02 then
		return
	end
	self.soot = alpha
	for _, hand in self.hands do
		Viewmodel.setRigSoot(hand.rig, alpha)
	end
end

function PhysicsHands.GetNozzle(self: PhysicsHands): Attachment?
	local item = self.item
	return if self.active and item then item.nozzle else nil
end

function PhysicsHands.GetModel(self: PhysicsHands): Instance
	return self.folder
end

-- per-frame --------------------------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude

-- Where a pressed hand reaches: the crosshair ray, stopped just short of whatever it hits.
local function aim(hand: Hand, cam: CFrame): (Vec, BasePart?, Vector3?)
	local look = cam.LookVector
	local hit = workspace:Raycast(cam.Position, look * HandsConfig.Reach, rayParams)
	local dist = HandsMath.reachDistance(if hit then hit.Distance else nil, HandsConfig.Reach, 0.35)
	local world = cam.Position + look * dist
	local localPt = cam:PointToObjectSpace(world)
	-- keep the two hands apart, a touch below the crosshair
	local pt = { x = localPt.X + 0.3 * hand.sign, y = localPt.Y - 0.25, z = localPt.Z }
	if hit and hit.Instance:IsA("BasePart") then
		return pt, hit.Instance :: BasePart, hit.Position
	end
	return pt, nil, nil
end

-- Framing tweaks on top of the shared HandsMath poses (HandsConfig.PoseTweak[name], given for the
-- right hand and mirrored for the left). In Studio, Camera attributes HandsTweak_<name> (Vector3
-- studs) and HandsTweakRot_<name> (Vector3 degrees) override them live for tuning.
local IS_STUDIO = RunService:IsStudio()

local function tweak(p: HandsMath.Pose, name: string, side: string): HandsMath.Pose
	local t = (HandsConfig.PoseTweak or {})[name]
	local dx, dy, dz, drx, dry, drz = 0, 0, 0, 0, 0, 0
	if t then
		dx, dy, dz = t.x or 0, t.y or 0, t.z or 0
		drx, dry, drz = t.rx or 0, t.ry or 0, t.rz or 0
	end
	if IS_STUDIO then
		local cam = workspace.CurrentCamera
		local pos = cam and cam:GetAttribute("HandsTweak_" .. name)
		local rot = cam and cam:GetAttribute("HandsTweakRot_" .. name)
		if typeof(pos) == "Vector3" then
			dx, dy, dz = pos.X, pos.Y, pos.Z
		end
		if typeof(rot) == "Vector3" then
			drx, dry, drz = rot.X, rot.Y, rot.Z
		end
	end
	if dx == 0 and dy == 0 and dz == 0 and drx == 0 and dry == 0 and drz == 0 then
		return p
	end
	local m = if side == "L" then -1 else 1
	return { x = p.x + dx * m, y = p.y + dy, z = p.z + dz, rx = p.rx + drx, ry = p.ry + dry * m, rz = p.rz + drz * m }
end

function PhysicsHands._basePose(self: PhysicsHands, hand: Hand, cam: CFrame, f: Frame, char: Model?): HandsMath.Pose
	local side = hand.side
	local item = self.item
	local carrying = LocalPlayer:GetAttribute(Names.Attr.Carrying)
	if type(carrying) == "string" and carrying ~= "" then
		return tweak(HandsMath.pose("carry", side), "carry", side)
	end
	local rest: HandsMath.Pose
	if side == "R" and item then
		if item.kind == "axe" then
			local charge = 0
			if self.windStart then
				charge = HandsMath.windupCharge(self.t - self.windStart, HandsConfig.AxeWindupSeconds)
				self.windCharge = charge
			end
			return HandsMath.axePose(charge, if self.strikeT >= 0 then self.strikeT else nil, HandsConfig.AxeStrikeSeconds, self.strikeFrom)
		elseif item.kind == "hose" then
			return tweak(HandsMath.Poses.hose, "hose", side)
		elseif item.kind == "extinguisher" then
			return tweak(HandsMath.Poses.extinguisher, "extinguisher", side)
		end
		return tweak(HandsMath.Poses.item, "item", side)
	end
	if side == "L" and item then
		rest = if item.kind == "hose"
			then tweak(HandsMath.Poses.hoseSupport, "hoseSupport", "R")
			else tweak(HandsMath.pose("lowered", "L"), "lowered", "L")
	else
		rest = tweak(HandsMath.pose("idle", side), "idle", side)
	end
	local g = hand.grip
	if g then
		-- hold grabbed things up in front; two hands on one thing bring it to the middle
		local twoHanded = gripsOn(self, g.part.AssemblyRootPart or g.part) >= 2
		local hold = if twoHanded
			then { x = 0.75 * hand.sign, y = -0.7, z = -3.0 }
			else { x = 1.0 * hand.sign, y = -0.85, z = -2.9 }
		return HandsMath.reachPose(rest, hold, 1)
	end
	if hand.pressed or hand.reachT > 0 then
		local pt, part, pos = aim(hand, cam)
		hand.aimPart = if part and grabbable(part, char) then part else nil
		hand.aimPos = if hand.aimPart then pos else nil
		if hand.aimPos then
			local lp = cam:PointToObjectSpace(hand.aimPos :: Vector3)
			pt = { x = lp.X, y = lp.Y, z = lp.Z + 0.2 }
		end
		return HandsMath.reachPose(rest, pt, hand.reachT)
	end
	hand.aimPart, hand.aimPos = nil, nil
	return rest
end

function PhysicsHands._probe(self: PhysicsHands, hand: Hand, char: Model, relVel: Vector3, kind: string)
	local speed = relVel.Magnitude
	if speed < math.min(HandsConfig.PushMinSpeed, HandsConfig.SlapMinSpeed) or self.t < hand.probeAt then
		return
	end
	hand.probeAt = self.t + 1 / 30
	local probePart = if kind == "axe" and self.item and self.item.head then self.item.head :: BasePart else hand.palm
	local hits = workspace:GetPartBoundsInRadius(probePart.Position, HandsConfig.GrabRadius, overlap)
	local now = self.t
	for _, part in hits do
		local m = humanoidModel(part)
		local key: Instance = m or part
		if (hand.cooldown[key] or 0) > now then
			continue
		end
		if m and m ~= char then
			if speed >= HandsConfig.SlapMinSpeed or kind == "axe" then
				hand.cooldown[key] = now + HandsConfig.SlapCooldown
				local r = remote("Slap")
				if r then
					r:FireServer(m, relVel, kind)
				end
				hand.hitStop = HandsConfig.HitStopSeconds
				playSound(HandsConfig.SoundSlap, hand.palm, 0.9)
				return
			end
		elseif not m then
			-- hands shove loose props and open doors; the axe head only bats props (doors are AxeHit)
			local isDoor = kind == "hand" and CollectionService:HasTag(part, Names.Tag.Door)
			local loose = not part.Anchored
				and (part.AssemblyRootPart or part):GetAttribute("HeldBy") ~= LocalPlayer.UserId
			if isDoor or loose then
				hand.cooldown[key] = now + HandsConfig.PushCooldown
				local r = remote("Push")
				if r then
					r:FireServer(part, relVel)
				end
				return
			end
		end
	end
end

-- Axe head vs doors: sweep the head between frames so a fast swing can't tunnel through.
function PhysicsHands._axeCheck(self: PhysicsHands, item: Item, onShake: ((number, number) -> ())?)
	local head = item.head
	if not head then
		return
	end
	local pos = head.Position
	local last = item.lastHeadPos
	item.lastHeadPos = pos
	if not last or self.t < self.axeCooldown then
		return
	end
	local delta = pos - last
	local root = rootOf(charOf())
	local rel = head.AssemblyLinearVelocity - (if root then root.AssemblyLinearVelocity else Vector3.zero)
	local speed = rel.Magnitude
	if speed < HandsConfig.AxeMinSpeed * 0.5 then
		return
	end
	local dir = if delta.Magnitude > 1e-3 then delta else rel.Unit * 0.2
	local hit = workspace:Spherecast(last, math.max(head.Size.Y, head.Size.Z) * 0.45, dir, rayParams)
	if not hit then
		return
	end
	local part = hit.Instance
	if CollectionService:HasTag(part, Names.Tag.Door) and part:GetAttribute(Names.Attr.Broken) ~= true then
		self.axeCooldown = self.t + HandsConfig.AxeHitCooldown
		local r = remote("AxeHit")
		if r then
			r:FireServer(part, speed)
		end
		self.hands.R.hitStop = HandsConfig.HitStopSeconds
		if onShake then
			onShake(math.clamp(speed / HandsConfig.AxeCritSpeed, 0.15, 0.6), 0.2)
		end
	end
end

local rigParts: { BasePart } = {}
local rigCFrames: { CFrame } = {}

-- How closed each glove is: 0 open (reaching), ~0.3 relaxed with a slow idle flex, ~0.95 wrapped
-- around a held tool / grabbed prop.
function PhysicsHands._curlTarget(self: PhysicsHands, hand: Hand): number
	local carrying = LocalPlayer:GetAttribute(Names.Attr.Carrying)
	if hand.grip or (hand.side == "R" and self.item) then
		return 0.95
	elseif type(carrying) == "string" and carrying ~= "" then
		return 0.7
	elseif hand.side == "L" and self.item and self.item.kind == "hose" then
		return 0.85
	elseif hand.pressed or hand.reachT > 0.05 then
		return 0.02
	end
	local idle = tonumber(HandsConfig.IdleCurl) or 0.3
	return idle + 0.06 * math.sin(self.t * 1.7 + hand.sign * 1.3) + 0.03 * math.sin(self.t * 3.1 + hand.sign)
end

function PhysicsHands.Update(self: PhysicsHands, dt: number, cam: CFrame, f: Frame, onShake: ((number, number) -> ())?)
	if not self.active then
		return
	end
	self.t += dt
	local char = charOf()
	local root = rootOf(char)
	if not (char and root) then
		return
	end
	self:_equip(f.tool)
	self:_refreshNoCollide(char)
	local item = self.item

	rayParams.FilterDescendantsInstances = { self.folder, char }
	overlap.FilterDescendantsInstances = { self.folder, char }

	if self.strikeT >= 0 then
		self.strikeT += dt
		if self.strikeT > HandsConfig.AxeStrikeSeconds * 3 then
			self.strikeT = -1
		end
	end
	local striking = self.strikeT >= 0 and self.strikeT < HandsConfig.AxeStrikeSeconds * 1.5
	if striking and not self.strikeShook then
		self.strikeShook = true
		if onShake then
			onShake(0.12 + 0.12 * self.strikeFrom, 0.2) -- the whoosh
		end
	end

	local bob = f.bob or Vector2.zero
	local sway = f.sway or Vector2.zero
	local base = cam * CFrame.new(bob.X, bob.Y + (f.dip or 0), 0) * CFrame.Angles(sway.X, sway.Y, sway.Y * 0.6)
	local gravity = workspace.Gravity

	table.clear(rigParts)
	table.clear(rigCFrames)
	local camObj = workspace.CurrentCamera
	if camObj and self.visual.Parent ~= camObj then
		self.visual.Parent = camObj
	end
	for side, hand in self.hands do
		-- reach ramp
		local rate = dt / math.max(HandsConfig.ReachSeconds, 0.01)
		hand.reachT = math.clamp(hand.reachT + (if hand.pressed then rate else -rate), 0, 1)

		local p = self:_basePose(hand, cam, f, char)
		local hz, zeta = HandsConfig.TargetHz, HandsConfig.TargetDamping
		if side == "R" and striking then
			hz, zeta = HandsConfig.StrikeHz, HandsConfig.StrikeDamping
		end
		local k, c = HandsMath.springCoeffs(hz, zeta)
		if hand.hitStop > 0 then
			hand.hitStop -= dt
		else
			hand.sp, hand.sv = HandsMath.springStep3(hand.sp, hand.sv, { x = p.x, y = p.y, z = p.z }, k, c, dt)
		end

		local extra = CFrame.identity
		if side == "R" and item and f.spraying then
			if item.kind == "hose" then
				local x, y, z, pitch = HandsMath.hoseKick(self.t, f.pressure or 1, HandsConfig.HoseKick)
				extra = CFrame.new(x, y, z) * CFrame.Angles(math.rad(pitch), 0, 0)
			elseif item.kind == "extinguisher" then
				local burst = HandsMath.sputter(self.t, f.pressure or 1)
				extra = CFrame.new(0, 0.05 * burst, 0.12 * burst) * CFrame.Angles(math.rad(6 * burst), 0, 0)
			end
		end
		local target = base * CFrame.new(hand.sp.x, hand.sp.y, hand.sp.z) * extra * poseCFrame(p)
		hand.target = target
		hand.ap.Position = target.Position
		hand.ao.CFrame = target.Rotation

		-- lift for whatever this hand grips
		local g = hand.grip
		local force = HandsConfig.HandMaxForce
		if g then
			if not g.part.Parent or not g.part:IsDescendantOf(workspace) then
				self:_release(hand, false)
			else
				local rootPart = g.part.AssemblyRootPart or g.part
				force += HandsMath.liftForce(rootPart.AssemblyMass, gripsOn(self, rootPart), gravity, HandsConfig)
				if (g.att.WorldPosition - hand.gripAtt.WorldPosition).Magnitude > HandsConfig.GripBreakDistance then
					self:_release(hand, false)
				end
			end
		elseif hand.pressed and hand.aimPart and hand.aimPos and not (side == "R" and item) then
			if (hand.gripAtt.WorldPosition - (hand.aimPos :: Vector3)).Magnitude <= HandsConfig.GrabSnap then
				self:_tryGrab(hand)
			end
		end
		hand.ap.MaxForce = force

		-- stuck behind a wall or left behind by a teleport: snap back
		local dist = (hand.wrist.WorldPosition - target.Position).Magnitude
		hand.stuck = if dist > HandsConfig.SnapDistance then hand.stuck + dt else 0
		if HandsMath.shouldSnap(dist, hand.stuck, HandsConfig.SnapDistance, HandsConfig.SnapAfter) then
			if g then
				self:_release(hand, false)
			end
			hand.palm:PivotTo(target * hand.wrist.CFrame:Inverse())
			hand.palm.AssemblyLinearVelocity = root.AssemblyLinearVelocity
			hand.palm.AssemblyAngularVelocity = Vector3.zero
			hand.stuck = 0
			if side == "R" and item and item.head then
				item.lastHeadPos = nil
			end
		end

		-- slaps and shoves
		local rel = hand.palm.AssemblyLinearVelocity - root.AssemblyLinearVelocity
		self:_probe(hand, char, rel, "hand")

		-- the glove you see, drawn on the physics palm, sleeve stretched from the shoulder
		local shoulder = base
			* Vector3.new(HandsConfig.ShoulderX * hand.sign, HandsConfig.ShoulderY, HandsConfig.ShoulderZ)
		hand.curl += (self:_curlTarget(hand) - hand.curl) * math.min(1, dt * 14)
		Viewmodel.poseRig(hand.rig, hand.wrist.WorldCFrame, shoulder, cam.UpVector, hand.curl, rigParts, rigCFrames)
	end
	workspace:BulkMoveTo(rigParts, rigCFrames, Enum.BulkMoveMode.FireCFrameChanged)

	-- the floppy axe and the bucking nozzle
	if item then
		if item.kind == "axe" then
			self:_axeCheck(item, onShake)
			local head = item.head
			if head and striking then
				local rel = head.AssemblyLinearVelocity - root.AssemblyLinearVelocity
				self:_probe(self.hands.R, char, rel, "axe")
			end
		elseif f.spraying and self.t >= self.kickAt then
			self.kickAt = self.t + 1 / HandsConfig.HoseKickHz
			local rng = Random.new()
			local amount = if item.kind == "hose"
				then HandsConfig.HoseKickImpulse * (f.pressure or 1)
				elseif item.kind == "extinguisher" then HandsConfig.ExtSputterKick * HandsMath.sputter(self.t, f.pressure or 1)
				else 0
			if amount > 0 then
				local palm = self.hands.R.palm
				local kick = (-cam.LookVector * rng:NextNumber(0.6, 1.2) + cam.UpVector * rng:NextNumber(0.2, 0.9) + cam.RightVector * rng:NextNumber(-0.5, 0.5))
				palm:ApplyImpulse(kick * amount * palm.AssemblyMass * 10)
			end
		end
	end

	-- replicate the pose
	if self.t >= self.sendAt then
		self.sendAt = self.t + 1 / math.max(1, HandsConfig.PoseHz)
		local r = remote("Pose")
		if r then
			local l = root.CFrame:PointToObjectSpace(self.hands.L.wrist.WorldPosition)
			local rr = root.CFrame:PointToObjectSpace(self.hands.R.wrist.WorldPosition)
			local F = HandsMath.Flag
			local flags = (if self.hands.L.grip then F.LeftGrip else 0)
				+ (if self.hands.R.grip then F.RightGrip else 0)
				+ (if self.windStart then F.Windup else 0)
				+ (if self.hands.L.pressed or self.hands.R.pressed then F.Reach else 0)
			r:FireServer(HandsMath.encodePose(toVec(l), toVec(rr), flags, HandsConfig.PoseMaxOffset))
		end
	end
end

function PhysicsHands.Destroy(self: PhysicsHands)
	self:SetActive(false)
	for _, c in self.conns do
		c:Disconnect()
	end
	table.clear(self.conns)
	self.folder:Destroy()
	self.visual:Destroy()
end

-- remote players' arms ---------------------------------------------------------------------------
type RemoteSide = { pos: Vec, vel: Vec, target: Vec }
type RemoteEntry = { L: RemoteSide, R: RemoteSide, at: number, weight: number }

local remoteStarted = false

local function shoulderMotor(char: Model, side: string): (Motor6D?, Motor6D?)
	local full = if side == "R" then "Right" else "Left"
	local upper = char:FindFirstChild(full .. "UpperArm")
	if upper then
		local m = upper:FindFirstChild(full .. "Shoulder")
		local lower = char:FindFirstChild(full .. "LowerArm")
		local e = lower and lower:FindFirstChild(full .. "Elbow")
		return (if m and m:IsA("Motor6D") then m else nil), (if e and e:IsA("Motor6D") then e else nil)
	end
	local torso = char:FindFirstChild("Torso")
	local m = torso and torso:FindFirstChild(full .. " Shoulder")
	return (if m and m:IsA("Motor6D") then m else nil), nil
end

local DOWN = Vector3.new(0, -1, 0)

local function aimShoulder(motor: Motor6D, elbow: Motor6D?, target: Vector3, weight: number)
	local part0 = motor.Part0
	if not part0 or not motor.Enabled then
		return
	end
	local joint = part0.CFrame * motor.C0
	local dir = joint:VectorToObjectSpace(target - joint.Position)
	local rest = motor.C1:VectorToObjectSpace(DOWN)
	local axis, angle = HandsMath.rotationBetween(toVec(rest), toVec(dir))
	if angle < 1e-4 then
		return
	end
	local rot = CFrame.fromAxisAngle(Vector3.new(axis.x, axis.y, axis.z), angle)
	motor.Transform = motor.Transform:Lerp(rot, weight)
	if elbow and elbow.Enabled then
		elbow.Transform = elbow.Transform:Lerp(CFrame.identity, weight)
	end
end

-- Call once per client. Aims other players' shoulders at their replicated hands every frame (after
-- the Animator, before physics) and routes Hands/Fx to `onFx(kind, position, extra)`.
function PhysicsHands.startRemote(onFx: ((string, Vector3, number) -> ())?)
	if remoteStarted then
		return
	end
	remoteStarted = true
	local entries: { [number]: RemoteEntry } = {}
	task.spawn(function()
		local net = ReplicatedStorage:WaitForChild("Net")
		local ns = net:WaitForChild("Hands", 30)
		if not ns then
			warn("[PhysicsHands] Net.Hands never appeared (HandsService not running?)")
			return
		end
		local poses = ns:WaitForChild("Poses", 30) :: any
		if poses then
			poses.OnClientEvent:Connect(function(flat: any)
				if type(flat) ~= "table" then
					return
				end
				local stride = 1 + HandsMath.PacketSize
				local now = os.clock()
				for i = 1, #flat - stride + 1, stride do
					local userId = flat[i]
					if userId == LocalPlayer.UserId or type(userId) ~= "number" then
						continue
					end
					local l, r = HandsMath.decodePose(table.move(flat, i + 1, i + HandsMath.PacketSize, 1, {}), HandsConfig.PoseMaxOffset)
					if l and r then
						local e = entries[userId]
						if not e then
							e = {
								L = { pos = l, vel = { x = 0, y = 0, z = 0 }, target = l },
								R = { pos = r, vel = { x = 0, y = 0, z = 0 }, target = r },
								at = now,
								weight = 0,
							}
							entries[userId] = e
						end
						local entry = e :: RemoteEntry
						entry.L.target = l
						entry.R.target = r
						entry.at = now
					end
				end
			end)
		end
		local fxRemote = ns:WaitForChild("Fx", 30) :: RemoteEvent?
		if fxRemote then
			fxRemote.OnClientEvent:Connect(function(kind: any, position: any, extra: any)
				if type(kind) ~= "string" or typeof(position) ~= "Vector3" then
					return
				end
				pop(kind, position)
				if onFx then
					onFx(kind, position, tonumber(extra) or 0)
				end
			end)
		end
	end)

	local k, c = HandsMath.springCoeffs(12, 0.8)
	RunService.PreSimulation:Connect(function(dt: number)
		local now = os.clock()
		for userId, e in entries do
			local player = Players:GetPlayerByUserId(userId)
			local char = player and player.Character
			local root = rootOf(char)
			local fresh = now - e.at < HandsConfig.RemoteStaleSeconds
			e.weight = math.clamp(e.weight + (if fresh then dt * 6 else -dt * 3), 0, 1)
			if not player or (e.weight <= 0 and not fresh) then
				entries[userId] = nil
				continue
			end
			if not (char and root) or char:GetAttribute(Names.Attr.Ragdolled) == true then
				continue
			end
			local w = e.weight * math.clamp(tonumber(HandsConfig.RemoteArmBlend) or 0.85, 0, 1)
			for _, side in { "L", "R" } do
				local rs = (e :: any)[side] :: RemoteSide
				rs.pos, rs.vel = HandsMath.springStep3(rs.pos, rs.vel, rs.target, k, c, dt)
				local motor, elbow = shoulderMotor(char :: Model, side)
				if motor then
					local world = root.CFrame:PointToWorldSpace(Vector3.new(rs.pos.x, rs.pos.y, rs.pos.z))
					aimShoulder(motor, elbow, world, w)
				end
			end
		end
	end)
end

return PhysicsHands
