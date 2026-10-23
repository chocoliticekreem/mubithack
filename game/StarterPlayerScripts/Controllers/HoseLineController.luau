--!strict
-- HoseLineController [owner: G1 / hose lines]. Client side of Lib/Tools/HoseLine:
--   * renders every hose in workspace.HoseLines as a smooth tube: one curved Beam per segment
--     (Catmull-Rom tangents through the physical joints), three layers (shadow, body, red stripe),
--     brass couplings at both ends, and hides the server's physics cylinders locally. A kinked
--     segment (attr Kinked) pinches and flushes red.
--   * applies HoseLine/Yank (the end-of-the-line tug) and HoseLine/Trip (the stumble fallback) to
--     the local character, which this client owns.
-- Reads: Model attrs Owner, SegLen, Segments; segment attrs Index, Kinked; HoseLineConfig.
-- Never trusts itself: it only draws what the server replicated.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HoseLineConfig") :: ModuleScript) :: any

local LocalPlayer = Players.LocalPlayer
local ROT = CFrame.Angles(0, math.pi / 2, 0) -- lookAt's -Z becomes +X (the attachment/beam axis)
local KINK_RED = Color3.fromRGB(220, 40, 30)
local STRIPE = Palette.HelmetRed or Color3.fromRGB(192, 48, 30)
local BODY = Palette.HoseYellow or Color3.fromRGB(232, 184, 58)
local SHADOW = Palette.CoatShadow or Color3.fromRGB(154, 106, 48)
local BRASS = Palette.BrassCoupling or Color3.fromRGB(200, 154, 60)

local HoseLineController = {}
HoseLineController.Priority = 100

type Layer = { beam: Beam, width: number, color: Color3 }
type Renderer = {
	model: Model,
	segs: { BasePart },
	atts: { Attachment }, -- joints 0..n, then the hand (n + 2 entries)
	layers: { { Layer } }, -- layers[k] = beams drawing joint k -> k + 1
	couplings: { BasePart },
	conns: { RBXScriptConnection },
	dirty: boolean,
}

local controllers: { [string]: any } = {}
local renderers: { [Model]: Renderer } = {}
local fxFolder: Folder? = nil

local function fx(): Folder
	if not fxFolder or not fxFolder.Parent then
		local f = Instance.new("Folder")
		f.Name = "HoseLineFx"
		f.Parent = workspace
		fxFolder = f
	end
	return fxFolder :: Folder
end

local function newBeam(a0: Attachment, a1: Attachment, width: number, color: Color3, z: number): Layer
	local b = Instance.new("Beam")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.Width0 = width
	b.Width1 = width
	b.Color = ColorSequence.new(color)
	b.FaceCamera = true
	b.Segments = Cfg.BeamSegments
	b.LightInfluence = 1
	b.LightEmission = 0
	b.Transparency = NumberSequence.new(0)
	b.ZOffset = z
	b.Parent = a0
	return { beam = b, width = width, color = color }
end

local function coupling(): BasePart
	local p = Instance.new("Part")
	p.Name = "Coupling"
	p.Shape = Enum.PartType.Cylinder
	p.Size = Vector3.new(0.5, Cfg.Thickness * 1.5, Cfg.Thickness * 1.5)
	p.Color = BRASS
	p.Material = Enum.Material.Metal
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = fx()
	return p
end

local function untrack(model: Model)
	local r = renderers[model]
	if not r then
		return
	end
	renderers[model] = nil
	for _, c in r.conns do
		c:Disconnect()
	end
	for _, a in r.atts do
		a:Destroy() -- beams are parented to their Attachment0
	end
	for _, p in r.couplings do
		p:Destroy()
	end
end

-- (Re)collect the physics segments in Index order and hide them locally.
local function collect(r: Renderer): boolean
	local n = tonumber(r.model:GetAttribute("Segments")) or 0
	local segs: { BasePart } = {}
	for _, c in r.model:GetChildren() do
		local i = c:GetAttribute("Index")
		if c:IsA("BasePart") and type(i) == "number" then
			segs[i] = c
			c.LocalTransparencyModifier = 1
		end
	end
	if n < 1 then
		return false
	end
	for i = 1, n do
		if not segs[i] then
			return false -- still streaming in
		end
	end
	r.segs = segs
	if #r.atts == 0 then
		local terrain = workspace.Terrain
		for k = 0, n + 1 do
			local a = Instance.new("Attachment")
			a.Name = `HoseJoint{k}`
			a.Parent = terrain
			r.atts[k + 1] = a
		end
		local w = Cfg.Thickness * 1.15
		for k = 1, n + 1 do
			local a0, a1 = r.atts[k], r.atts[k + 1]
			r.layers[k] = {
				newBeam(a0, a1, w * 1.12, SHADOW, 0),
				newBeam(a0, a1, w * 0.8, BODY, 0.02),
				newBeam(a0, a1, w * 0.16, STRIPE, 0.04),
			}
		end
		r.couplings = { coupling(), coupling() }
	end
	return true
end

local function track(inst: Instance)
	if not inst:IsA("Model") or renderers[inst :: Model] then
		return
	end
	local model = inst :: Model
	local r: Renderer = {
		model = model,
		segs = {},
		atts = {},
		layers = {},
		couplings = {},
		conns = {},
		dirty = true,
	}
	renderers[model] = r
	table.insert(
		r.conns,
		model.ChildAdded:Connect(function()
			r.dirty = true
		end)
	)
	table.insert(
		r.conns,
		model.ChildRemoved:Connect(function()
			r.dirty = true
		end)
	)
	table.insert(
		r.conns,
		model.AncestryChanged:Connect(function()
			if not model:IsDescendantOf(workspace) then
				untrack(model)
			end
		end)
	)
end

local function handPoint(model: Model): Vector3?
	local owner = Players:GetPlayerByUserId(tonumber(model:GetAttribute("Owner")) or 0)
	local char = owner and owner.Character
	if not char then
		return nil
	end
	local tool = char:FindFirstChild("Hose")
	local handle = tool and tool:FindFirstChild("Handle")
	local att = handle and handle:FindFirstChild("HoseLineEnd")
	if not att then
		local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
		att = hand and hand:FindFirstChild("RightGripAttachment")
	end
	return if att and att:IsA("Attachment") then att.WorldPosition else nil
end

local function setVisible(r: Renderer, on: boolean)
	for _, layer in r.layers do
		for _, l in layer do
			l.beam.Enabled = on
		end
	end
	for _, c in r.couplings do
		c.Transparency = if on then 0 else 1
	end
end

local function orient(a: Attachment, p: Vector3, t: Vector3)
	local dir = if t.Magnitude > 1e-4 then t.Unit else Vector3.xAxis
	local up = if math.abs(dir.Y) > 0.98 then Vector3.xAxis else Vector3.yAxis
	a.WorldCFrame = CFrame.lookAt(p, p + dir, up) * ROT
end

local function render()
	local cam = workspace.CurrentCamera
	local camPos = if cam then cam.CFrame.Position else Vector3.zero
	for model, r in renderers do
		if r.dirty then
			r.dirty = not collect(r)
		end
		if r.dirty or #r.atts == 0 then
			continue
		end
		local n = #r.segs
		local segLen = tonumber(model:GetAttribute("SegLen")) or r.segs[1].Size.X
		local half = Vector3.new(segLen / 2, 0, 0)

		-- joints: start of seg 1, then the end of every segment, then the holder's hand
		local pts: { Vector3 } = { (r.segs[1].CFrame * CFrame.new(-half)).Position }
		for i = 1, n do
			pts[i + 1] = (r.segs[i].CFrame * CFrame.new(half)).Position
		end
		local hand = handPoint(model)
		pts[n + 2] = hand or pts[n + 1]

		if (pts[1] - camPos).Magnitude > Cfg.RenderDistance and (pts[n + 1] - camPos).Magnitude > Cfg.RenderDistance then
			setVisible(r, false)
			continue
		end
		setVisible(r, true)

		local m = #pts
		local tangents: { Vector3 } = {}
		for k = 1, m do
			local prev = pts[math.max(1, k - 1)]
			local nxt = pts[math.min(m, k + 1)]
			tangents[k] = (nxt - prev) / (if k == 1 or k == m then 1 else 2)
		end
		for k = 1, m do
			orient(r.atts[k], pts[k], tangents[k])
		end
		for k = 1, m - 1 do
			local seg = r.segs[k]
			local kinked = seg ~= nil and seg:GetAttribute("Kinked") == true
			local c0 = tangents[k].Magnitude / 3
			local c1 = tangents[k + 1].Magnitude / 3
			for li, l in r.layers[k] do
				l.beam.CurveSize0 = c0
				l.beam.CurveSize1 = c1 -- control point 2 = P1 - axis1 * CurveSize1
				local w = if kinked then l.width * Cfg.KinkWidthScale else l.width
				if l.beam.Width0 ~= w then
					l.beam.Width0 = w
					l.beam.Width1 = w
					local col = if kinked and li == 2 then KINK_RED else l.color
					l.beam.Color = ColorSequence.new(col)
				end
			end
		end

		-- brass couplings at the source and at the nozzle
		local c1, c2 = r.couplings[1], r.couplings[2]
		c1.CFrame = CFrame.lookAt(pts[1], pts[1] + (if tangents[1].Magnitude > 1e-4 then tangents[1] else Vector3.xAxis)) * ROT
		local tail = pts[m]
		local tailT = if tangents[m].Magnitude > 1e-4 then tangents[m] else Vector3.xAxis
		c2.CFrame = CFrame.lookAt(tail, tail + tailT) * ROT
	end
end

-- ---------------------------------------------------------------- local character reactions

local function playSound(id: string, parent: Instance)
	if id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.PlaybackSpeed = 0.9 + math.random() * 0.2
	s.Parent = parent
	s:Play()
	s.Ended:Once(function()
		s:Destroy()
	end)
end

local function flop(velocity: Vector3, seconds: number, shake: number, sound: string)
	local char = LocalPlayer.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 or typeof(velocity) ~= "Vector3" then
		return
	end
	if velocity.Magnitude > 120 then
		velocity = velocity.Unit * 120
	end
	local v = root.AssemblyLinearVelocity
	hum:ChangeState(Enum.HumanoidStateType.Physics) -- the humanoid stops fighting the push
	root.AssemblyLinearVelocity = Vector3.new(velocity.X, math.max(v.Y, velocity.Y), velocity.Z)
	root.AssemblyAngularVelocity = Vector3.new(math.random(-4, 4), 0, math.random(-4, 4))
	playSound(sound, root)
	local fp = controllers.FirstPersonController
	if fp and type(fp.Shake) == "function" then
		pcall(fp.Shake, fp, shake, 0.3)
	end
	task.delay(seconds, function()
		if hum.Parent and hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end)
end

-- Remotes are declared lazily by the server on the first attach: wait for them without a timeout
-- (and without WaitForChild's infinite-yield warning).
local function onChild(parent: Instance, name: string, fn: (Instance) -> ())
	local existing = parent:FindFirstChild(name)
	if existing then
		fn(existing)
		return
	end
	local conn: RBXScriptConnection
	conn = parent.ChildAdded:Connect(function(c)
		if c.Name == name then
			conn:Disconnect()
			fn(c)
		end
	end)
end

function HoseLineController:Init(all: { [string]: any })
	controllers = all
end

function HoseLineController:Start()
	onChild(workspace, "HoseLines", function(folder)
		folder.ChildAdded:Connect(track)
		folder.ChildRemoved:Connect(function(c)
			if c:IsA("Model") then
				untrack(c)
			end
		end)
		for _, c in folder:GetChildren() do
			track(c)
		end
	end)
	onChild(ReplicatedStorage, "Net", function(net)
		onChild(net, "HoseLine", function(ns)
			onChild(ns, "Yank", function(r)
				(r :: RemoteEvent).OnClientEvent:Connect(function(v: Vector3)
					flop(v, 0.35, 0.6, Cfg.SoundYank)
				end)
			end)
			onChild(ns, "Trip", function(r)
				(r :: RemoteEvent).OnClientEvent:Connect(function(v: Vector3)
					flop(v, Cfg.TripSeconds, 1, Cfg.SoundTrip)
				end)
			end)
		end)
	end)
	LocalPlayer:GetAttributeChangedSignal("HoseKinkedBy"):Connect(function()
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and LocalPlayer:GetAttribute("HoseKinkedBy") ~= nil then
			playSound(Cfg.SoundKink, root)
		end
	end)
	RunService.RenderStepped:Connect(function()
		local ok, err = pcall(render)
		if not ok then
			warn(`[HoseLineController] render: {err}`)
		end
	end)
end

return HoseLineController
