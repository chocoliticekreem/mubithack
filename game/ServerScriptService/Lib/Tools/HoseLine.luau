--!strict
-- HoseLine [owner: G1 / hose lines]. A real, physical hose from a source (truck reel or hydrant) to
-- the holder's nozzle: a chain of light cylinder segments joined by BallSocketConstraints, colliding
-- with the world and with other hoses (so lines tangle and wrap round poles) but not with players.
--
-- Public API (ToolService calls these, nil-guarded; keep the names):
--   HoseLine.attach(player: Player, sourcePart: BasePart): boolean  -- replaces any previous hose
--   HoseLine.detach(player: Player)
--   HoseLine.getPressure(player: Player): number   -- 0..1; 1 when no hose is attached
--   HoseLine.Kinked: Signal<Player, Player>         -- (hose owner, culprit). Fires when someone has
--       stood on your hose for KinkDelay s, or when your line first tangles with another player's
--       (then it fires both ways). The culprit can be the owner (you stood on your own hose).
-- Remotes (declared lazily on the first attach): HoseLine/Yank (S->C holder, velocity: Vector3),
--   HoseLine/Trip (S->C tripper, velocity: Vector3). The client owns its character, so the tug and
--   the stumble are applied by HoseLineController. A trip prefers Shared/Ragdoll (enable +
--   knockback) and only falls back to HoseLine/Trip while Ragdoll is a stub (returns false).
-- Caps: HoseLineConfig.MaxHosesPerInstance (by Player attr InstanceId) and MaxHoses per server;
--   MaxSegments per hose.
-- Writes: workspace.HoseLines/Hose_<UserId> (Model attrs Owner, SegLen, Segments, Kind, Length;
--   parts Seg01.. with attr Index and Kinked); Player attrs HosePressure, HoseKind, HoseKinkedBy.
-- Collision groups: "HoseLine" (hoses) never collides with "Players" (character parts we move
--   from Default into "Players", or whatever group another system put them in).
-- Counters: hose_attached, hose_kinks, hose_tangles, hose_trips, hose_yanks, hose_snapped
-- Test hooks (DevHook, dot-call: DevHook:Invoke("HoseLine", "._attachTest", player, 6)):
--   _selftest(), _state(player), _attachTest(player, dist?)
--
-- The pure maths at the top uses no Roblox API, so game/tests/hoseline.spec.luau can run it in the
-- luau CLI; the module returns early there (no `game`).

local HoseLine = {}

-- ---------------------------------------------------------------- pure maths
-- Points are anything with numeric X, Y, Z (a Vector3, or { X =, Y =, Z = } in specs).

function HoseLine.segmentCount(length: number, target: number, minSeg: number, maxSeg: number): number
	return math.clamp(math.ceil(length / math.max(target, 0.1)), minSeg, maxSeg)
end

-- n segments of exactly segLen laid from forward 0 toward forward `dist`. If the hose is longer
-- than the gap it zigzags sideways (lateral 0, h, 0, h, ...) so no segment overlaps on spawn.
-- Returns n + 1 points { f = forward, l = lateral }.
function HoseLine.zigzag(n: number, segLen: number, dist: number): { { f: number, l: number } }
	local dx = math.min(math.max(dist, 0), n * segLen) / n
	local h = math.sqrt(math.max(0, segLen * segLen - dx * dx))
	local pts = {}
	for i = 0, n do
		pts[i + 1] = { f = i * dx, l = if i % 2 == 1 then h else 0 }
	end
	return pts
end

-- Distance from p to segment ab, and the 0..1 parameter of the nearest point.
function HoseLine.pointSegDist(p: any, a: any, b: any): (number, number)
	local abx, aby, abz = b.X - a.X, b.Y - a.Y, b.Z - a.Z
	local len2 = abx * abx + aby * aby + abz * abz
	local t = 0
	if len2 > 1e-9 then
		t = math.clamp(((p.X - a.X) * abx + (p.Y - a.Y) * aby + (p.Z - a.Z) * abz) / len2, 0, 1)
	end
	local dx, dy, dz = a.X + abx * t - p.X, a.Y + aby * t - p.Y, a.Z + abz * t - p.Z
	return math.sqrt(dx * dx + dy * dy + dz * dz), t
end

-- Nearest polyline segment (segment i joins pts[i] and pts[i + 1]) among segments first..last.
function HoseLine.nearestSegment(p: any, pts: { any }, first: number, last: number): (number, number)
	local best, bestI = math.huge, 0
	for i = math.max(1, first), math.min(last, #pts - 1) do
		local d = HoseLine.pointSegDist(p, pts[i], pts[i + 1])
		if d < best then
			best, bestI = d, i
		end
	end
	return best, bestI
end

-- Do segments ab and cd cross in the XZ plane? Also returns the height gap at the crossing.
function HoseLine.crossXZ(a: any, b: any, c: any, d: any): (boolean, number)
	local rx, rz = b.X - a.X, b.Z - a.Z
	local sx, sz = d.X - c.X, d.Z - c.Z
	local denom = rx * sz - rz * sx
	if math.abs(denom) < 1e-9 then
		return false, math.huge -- parallel or degenerate: never a tangle
	end
	local qx, qz = c.X - a.X, c.Z - a.Z
	local t = (qx * sz - qz * sx) / denom
	local u = (qx * rz - qz * rx) / denom
	if t < 0 or t > 1 or u < 0 or u > 1 then
		return false, math.huge
	end
	local ya = a.Y + (b.Y - a.Y) * t
	local yc = c.Y + (d.Y - c.Y) * u
	return true, math.abs(ya - yc)
end

-- Crossings between two hose polylines that are within maxDy of each other vertically.
function HoseLine.countCrossings(pa: { any }, pb: { any }, maxDy: number): number
	local n = 0
	for i = 1, #pa - 1 do
		for j = 1, #pb - 1 do
			local crossed, dy = HoseLine.crossXZ(pa[i], pa[i + 1], pb[j], pb[j + 1])
			if crossed and dy <= maxDy then
				n += 1
			end
		end
	end
	return n
end

function HoseLine.pressureFor(kinkers: number, crossings: number, cfg: any): number
	return math.clamp(1 - kinkers * cfg.KinkLoss - crossings * cfg.TangleLoss, cfg.MinPressure, 1)
end

-- Contact timer for someone near a hose: returns the new time and whether a kink just started.
function HoseLine.stepContact(t: number, touching: boolean, dt: number, delay: number): (number, boolean)
	if not touching then
		return 0, false
	end
	local nt = t + dt
	return nt, t < delay and nt >= delay
end

-- "none" | "yank" (hit the end, or the chain is taut round something) | "snap" (way past: detach)
function HoseLine.stretchState(dist: number, length: number, endGap: number, cfg: any): string
	if dist > length * cfg.SnapFactor then
		return "snap"
	elseif dist > length or endGap > cfg.YankGap then
		return "yank"
	end
	return "none"
end

function HoseLine.shouldTrip(speedH: number, feetDist: number, cfg: any): boolean
	return speedH >= cfg.TripSpeed and feetDist <= cfg.StandRadius
end

if (game :: any) == nil then
	return HoseLine -- luau CLI (specs): pure maths only
end

-- ---------------------------------------------------------------- runtime (server)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript) :: any
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local Cfg = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("HoseLineConfig") :: ModuleScript) :: any

local HOSE_GROUP = "HoseLine"
local PLAYER_GROUP = "Players"
local FOLDER = "HoseLines"

HoseLine.Kinked = Signal.new() :: Signal.Signal<Player, Player>

type Hose = {
	owner: Player,
	source: BasePart,
	sourceAtt: Attachment,
	kind: string,
	length: number,
	segLen: number,
	model: Model,
	segs: { BasePart },
	ends: { Attachment }, -- ends[i] = attachment "B" of segment i
	rope: RopeConstraint,
	follow: AlignPosition,
	born: number,
	lastYank: number,
	contact: { [Player]: number },
	lastBlame: { [Player]: number },
	tangled: { [Player]: boolean },
	crossings: number,
	kinkers: number,
	pressure: number,
	kinkedSeg: number,
	conns: { RBXScriptConnection },
}

local hoses: { [Player]: Hose } = {}
local hoseCount = 0
local booted = false
local lastTrip: { [Player]: number } = {}
local YankRemote: RemoteEvent? = nil
local TripRemote: RemoteEvent? = nil

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function ensureGroup(name: string)
	if not PhysicsService:IsCollisionGroupRegistered(name) then
		pcall(PhysicsService.RegisterCollisionGroup, PhysicsService, name)
	end
end

local function claimPart(part: Instance)
	if not part:IsA("BasePart") then
		return
	end
	local p = part :: BasePart
	if p.CollisionGroup == "Default" then
		p.CollisionGroup = PLAYER_GROUP
	elseif p.CollisionGroup ~= PLAYER_GROUP and p.CollisionGroup ~= HOSE_GROUP then
		-- another system's group (ragdoll, carried...): just make sure hoses ignore it too
		pcall(PhysicsService.CollisionGroupSetCollidable, PhysicsService, HOSE_GROUP, p.CollisionGroup, false)
	end
end

local function hookCharacter(player: Player, char: Model)
	for _, d in char:GetDescendants() do
		claimPart(d)
	end
	char.DescendantAdded:Connect(claimPart)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		hum.Died:Connect(function()
			HoseLine.detach(player)
		end)
	end
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(char)
		hookCharacter(player, char)
	end)
	player.CharacterRemoving:Connect(function()
		HoseLine.detach(player)
	end)
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end
end

local tick: (number) -> ()

local function boot()
	if booted then
		return
	end
	booted = true
	ensureGroup(HOSE_GROUP)
	ensureGroup(PLAYER_GROUP)
	PhysicsService:CollisionGroupSetCollidable(HOSE_GROUP, PLAYER_GROUP, false)
	YankRemote = Net.event("HoseLine", "Yank")
	TripRemote = Net.event("HoseLine", "Trip")
	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	Players.PlayerAdded:Connect(hookPlayer)
	Players.PlayerRemoving:Connect(function(p)
		HoseLine.detach(p)
		lastTrip[p] = nil
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		local step = 1 / math.max(1, Cfg.TickHz)
		if acc < step then
			return
		end
		local elapsed = math.min(acc, 0.5)
		acc = 0
		local ok, err = pcall(tick, elapsed)
		if not ok then
			warn(`[HoseLine] tick: {err}`)
		end
	end)
end

local function folder(): Instance
	local f = workspace:FindFirstChild(FOLDER)
	if not f then
		f = Instance.new("Folder")
		f.Name = FOLDER
		f.Parent = workspace
	end
	return f :: Instance
end

local function isHydrant(part: BasePart): boolean
	local node: Instance? = part
	while node and node ~= workspace do
		if node:HasTag(Names.Tag.Hydrant) then
			return true
		end
		node = node.Parent
	end
	return false
end

local function rootOf(player: Player): (BasePart?, Humanoid?)
	local char = player.Character
	if not char then
		return nil, nil
	end
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not root or not hum or hum.Health <= 0 then
		return nil, nil
	end
	return root, hum
end

-- Where the hose ends on the holder: the equipped Hose tool's handle, else the right hand, else root.
local function endAttachment(player: Player): Attachment?
	local char = player.Character
	if not char then
		return nil
	end
	local tool = char:FindFirstChild("Hose")
	local handle = tool and tool:IsA("Tool") and tool:FindFirstChild("Handle")
	if handle and handle:IsA("BasePart") then
		local att = handle:FindFirstChild("HoseLineEnd") :: Attachment?
		if not att then
			local a = Instance.new("Attachment")
			a.Name = "HoseLineEnd"
			a.Position = Vector3.new(0, 0, handle.Size.Z / 2)
			a.Parent = handle
			att = a
		end
		return att
	end
	local hand = char:FindFirstChild("RightHand") or char:FindFirstChild("Right Arm")
	local grip = hand and hand:FindFirstChild("RightGripAttachment")
	if grip and grip:IsA("Attachment") then
		return grip
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	local ra = root and root:FindFirstChild("RootAttachment")
	return if ra and ra:IsA("Attachment") then ra else nil
end

local function instanceOf(player: Player): string
	local id = player:GetAttribute("InstanceId")
	return if type(id) == "string" then id else ""
end

local function newAttachment(parent: Instance, name: string, pos: Vector3): Attachment
	local a = Instance.new("Attachment")
	a.Name = name
	a.Position = pos
	a.Parent = parent
	return a
end

local function ballSocket(parent: Instance, a0: Attachment, a1: Attachment)
	local b = Instance.new("BallSocketConstraint")
	b.Attachment0 = a0
	b.Attachment1 = a1
	b.LimitsEnabled = true
	b.UpperAngle = 80 -- a hose bends, it doesn't fold flat on itself
	b.Restitution = 0
	b.Parent = parent
end

local function noCollide(parent: Instance, p0: BasePart, p1: BasePart)
	local n = Instance.new("NoCollisionConstraint")
	n.Part0 = p0
	n.Part1 = p1
	n.Parent = parent
end

function HoseLine.attach(player: Player, sourcePart: BasePart): boolean
	if typeof(player) ~= "Instance" or not (player :: Instance):IsA("Player") then
		return false
	end
	if typeof(sourcePart) ~= "Instance" or not (sourcePart :: Instance):IsA("BasePart") then
		return false
	end
	if not sourcePart:IsDescendantOf(workspace) then
		return false
	end
	local root = rootOf(player)
	local endAtt = endAttachment(player)
	if not root or not endAtt then
		return false
	end
	boot()

	local existing = hoses[player]
	if existing and existing.source == sourcePart then
		return true -- already hooked up here
	end
	if existing then
		HoseLine.detach(player)
	end
	if hoseCount >= Cfg.MaxHoses then
		warn("[HoseLine] server hose cap reached")
		return false
	end
	local inst = instanceOf(player)
	local inInstance = 0
	for other in hoses do
		if instanceOf(other) == inst then
			inInstance += 1
		end
	end
	if inInstance >= Cfg.MaxHosesPerInstance then
		warn(`[HoseLine] hose cap reached for instance "{inst}"`)
		return false
	end

	local kind = if isHydrant(sourcePart) then "Hydrant" else "Truck"
	local length = tonumber(sourcePart:GetAttribute("HoseLength"))
		or (if kind == "Hydrant" then Cfg.LengthHydrant else Cfg.LengthTruck)
	local n = HoseLine.segmentCount(length, Cfg.SegmentTarget, Cfg.MinSegments, Cfg.MaxSegments)
	local segLen = length / n

	-- source attachment: the point on the source's box nearest the holder
	local localP = sourcePart.CFrame:PointToObjectSpace(root.Position)
	local half = sourcePart.Size / 2
	local srcLocal = Vector3.new(
		math.clamp(localP.X, -half.X, half.X),
		math.clamp(localP.Y, -half.Y, half.Y),
		math.clamp(localP.Z, -half.Z, half.Z)
	)
	local sourceAtt = newAttachment(sourcePart, `HoseLineSource_{player.UserId}`, srcLocal)

	-- lay the chain out from the source toward the holder's hand
	local srcPos = sourceAtt.WorldPosition
	local endPos = endAtt.WorldPosition
	local gap = endPos - srcPos
	local flat = Vector3.new(gap.X, 0, gap.Z)
	local fwd = if flat.Magnitude > 0.1 then flat.Unit else root.CFrame.LookVector
	local side = fwd:Cross(Vector3.yAxis)
	side = if side.Magnitude > 0.1 then side.Unit else Vector3.xAxis
	local layout = HoseLine.zigzag(n, segLen, flat.Magnitude)
	local pts: { Vector3 } = {}
	for i, q in layout do
		local alpha = (i - 1) / n
		pts[i] = srcPos + fwd * q.f + side * q.l + Vector3.yAxis * (gap.Y * alpha + 0.4)
	end

	local model = Instance.new("Model")
	model.Name = `Hose_{player.UserId}`
	model:SetAttribute("Owner", player.UserId)
	model:SetAttribute("SegLen", segLen)
	model:SetAttribute("Segments", n)
	model:SetAttribute("Kind", kind)
	model:SetAttribute("Length", length)

	local segs: { BasePart } = {}
	local ends: { Attachment } = {}
	local prevEnd: Attachment = sourceAtt
	local props = PhysicalProperties.new(Cfg.Density, Cfg.Friction, 0.05)
	for i = 1, n do
		local a, b = pts[i], pts[i + 1]
		local seg = Instance.new("Part")
		seg.Name = string.format("Seg%02d", i)
		seg.Shape = Enum.PartType.Cylinder
		seg.Size = Vector3.new(segLen, Cfg.Thickness, Cfg.Thickness)
		-- lookAt points -Z at b; a +90 deg turn about Y puts the cylinder's +X axis there instead
		seg.CFrame = CFrame.lookAt((a + b) / 2, b) * CFrame.Angles(0, math.pi / 2, 0)
		seg.Color = Palette.HoseYellow
		seg.Material = Enum.Material.SmoothPlastic
		seg.CustomPhysicalProperties = props
		seg.CanCollide = true
		seg.CanTouch = false
		seg.CanQuery = false -- spray and axe raycasts go through the hose
		seg.CollisionGroup = HOSE_GROUP
		seg:SetAttribute("Index", i)
		seg:SetAttribute("Kinked", false)
		local sa = newAttachment(seg, "A", Vector3.new(-segLen / 2, 0, 0))
		local sb = newAttachment(seg, "B", Vector3.new(segLen / 2, 0, 0))
		ballSocket(seg, prevEnd, sa)
		if i == 1 then
			noCollide(seg, seg, sourcePart)
		else
			noCollide(seg, seg, segs[i - 1])
		end
		seg.Parent = model
		segs[i] = seg
		ends[i] = sb
		prevEnd = sb
	end

	local rope = Instance.new("RopeConstraint")
	rope.Name = "HandRope"
	rope.Attachment0 = ends[n]
	rope.Attachment1 = endAtt
	-- only a last-resort leash: a hose snagged on a wall or truck must never hold the holder in place
	rope.Length = length
	rope.Visible = false
	rope.Parent = segs[n]

	-- the tip follows the hand with a capped force that acts on the hose only (OneAttachment), so a
	-- free hose trails behind you and a snagged one just stretches its drawn end to your hand
	local follow = Instance.new("AlignPosition")
	follow.Name = "HandFollow"
	follow.Mode = Enum.PositionAlignmentMode.OneAttachment
	follow.Attachment0 = ends[n]
	follow.MaxForce = Cfg.FollowForce
	follow.Responsiveness = Cfg.FollowResponsiveness
	follow.Position = endAtt.WorldPosition
	follow.Parent = segs[n]

	model.PrimaryPart = segs[1]
	model.Parent = folder()

	local split = math.floor(n * math.clamp(Cfg.OwnerSplit, 0, 1))
	for i, seg in segs do
		pcall(seg.SetNetworkOwner, seg, if i <= split then nil else player)
	end

	local h: Hose = {
		owner = player,
		source = sourcePart,
		sourceAtt = sourceAtt,
		kind = kind,
		length = length,
		segLen = segLen,
		model = model,
		segs = segs,
		ends = ends,
		rope = rope,
		follow = follow,
		born = os.clock(),
		lastYank = 0,
		contact = {},
		lastBlame = {},
		tangled = {},
		crossings = 0,
		kinkers = 0,
		pressure = 1,
		kinkedSeg = 0,
		conns = {},
	}
	table.insert(
		h.conns,
		sourcePart.AncestryChanged:Connect(function()
			if not sourcePart:IsDescendantOf(workspace) then
				HoseLine.detach(player)
			end
		end)
	)
	hoses[player] = h
	hoseCount += 1
	player:SetAttribute("HosePressure", 1)
	player:SetAttribute("HoseKind", kind)
	player:SetAttribute("HoseKinkedBy", nil)
	count("hose_attached")
	return true
end

function HoseLine.detach(player: Player)
	local h = hoses[player]
	if not h then
		return
	end
	hoses[player] = nil
	hoseCount -= 1
	for _, c in h.conns do
		c:Disconnect()
	end
	h.model:Destroy()
	h.sourceAtt:Destroy()
	for _, other in hoses do
		other.contact[player] = nil
		other.lastBlame[player] = nil
		other.tangled[player] = nil
	end
	if player.Parent then
		player:SetAttribute("HosePressure", nil)
		player:SetAttribute("HoseKind", nil)
		player:SetAttribute("HoseKinkedBy", nil)
	end
end

function HoseLine.getPressure(player: Player): number
	local h = hoses[player]
	return if h then h.pressure else 1
end

local function polyline(h: Hose): { Vector3 }
	local pts = { h.sourceAtt.WorldPosition }
	for i, e in h.ends do
		pts[i + 1] = e.WorldPosition
	end
	return pts
end

local function blame(h: Hose, culprit: Player, now: number, text: string)
	if now - (h.lastBlame[culprit] or -math.huge) < Cfg.KinkCooldown then
		return
	end
	h.lastBlame[culprit] = now
	HoseLine.Kinked:Fire(h.owner, culprit)
	Popup.show(culprit, text, "blame", h.owner) -- over whoever is on the hose
end

tick = function(dt: number)
	local now = os.clock()
	local lines: { [Player]: { Vector3 } } = {}

	-- 1. stretch: yank the holder back, or snap off after a teleport
	for owner, h in hoses do
		if not h.model.Parent or not h.source:IsDescendantOf(workspace) or not owner.Parent then
			HoseLine.detach(owner)
			continue
		end
		local root, hum = rootOf(owner)
		local endAtt = endAttachment(owner)
		if not root or not endAtt then
			HoseLine.detach(owner)
			continue
		end
		if hum and hum.SeatPart then
			-- got in a vehicle: the line goes back on the reel. A chain from the reel to a hand inside
			-- the cab dragged on (and shoved) the truck it was hooked to.
			HoseLine.detach(owner)
			continue
		end
		if h.rope.Attachment1 ~= endAtt then
			h.rope.Attachment1 = endAtt -- tool equipped/unequipped: re-hook to the new end
		end
		h.follow.Position = endAtt.WorldPosition
		local srcPos = h.sourceAtt.WorldPosition
		local tip = h.ends[#h.ends].WorldPosition
		local dist = (endAtt.WorldPosition - srcPos).Magnitude
		local endGap = (tip - endAtt.WorldPosition).Magnitude - Cfg.HandRopeLength
		local state = HoseLine.stretchState(dist, h.length, endGap, Cfg)
		if state == "snap" then
			count("hose_snapped")
			Popup.show(owner, "Hose popped off!", "bad", owner)
			HoseLine.detach(owner)
			continue
		elseif state == "yank" and now - h.born > 0.6 and now - h.lastYank > Cfg.YankCooldown then
			h.lastYank = now
			-- pull toward whatever is holding the line taut: the chain tip, or the source itself
			local target = if dist > h.length then srcPos else tip
			local pull = target - root.Position
			pull = Vector3.new(pull.X, 0, pull.Z)
			local dir = if pull.Magnitude > 0.05 then pull.Unit else -root.CFrame.LookVector
			if YankRemote then
				YankRemote:FireClient(owner, dir * Cfg.YankSpeed + Vector3.yAxis * Cfg.YankUp)
			end
			count("hose_yanks")
		end
		lines[owner] = polyline(h)
	end

	-- 2. feet on hoses: kinks (standing) and trips (running across)
	for _, p in Players:GetPlayers() do
		local root, hum = rootOf(p)
		if not root or not hum then
			continue
		end
		local feet = root.Position - Vector3.new(0, hum.HipHeight + root.Size.Y / 2, 0)
		local vel = root.AssemblyLinearVelocity
		local speedH = Vector3.new(vel.X, 0, vel.Z).Magnitude
		local tripped = false
		for owner, h in hoses do
			local pts = lines[owner]
			if not pts then
				continue
			end
			local last = #h.segs - (if p == owner then Cfg.OwnerIgnoreSegments else 0)
			local d, segI = HoseLine.nearestSegment(feet, pts, 1, last)
			local touching = d <= Cfg.StandRadius
			local t, started = HoseLine.stepContact(h.contact[p] or 0, touching, dt, Cfg.KinkDelay)
			h.contact[p] = if touching then t else nil
			if touching and t >= Cfg.KinkDelay then
				h.kinkedSeg = segI
			end
			if started then
				count("hose_kinks")
				local who = if p == owner then "You are" else `{p.DisplayName} is`
				blame(h, p, now, `{who} standing on your hose!`)
			end
			if not tripped and p ~= owner and HoseLine.shouldTrip(speedH, d, Cfg) and now - (lastTrip[p] or -math.huge) > Cfg.TripCooldown then
				tripped = true
				lastTrip[p] = now
				local fwd = Vector3.new(vel.X, 0, vel.Z).Unit
				local push = fwd * Cfg.TripPush + Vector3.yAxis * Cfg.TripUp
				-- prefer the shared ragdoll (a real flop); fall back to our own stumble remote
				local char = p.Character :: Model
				local okR, flopped = pcall(Ragdoll.enable, char, Cfg.TripSeconds)
				local okK, shoved = pcall(Ragdoll.knockback, char, push)
				if not (okR and flopped) and not (okK and shoved) and TripRemote then
					TripRemote:FireClient(p, push)
				end
				count("hose_trips")
				if p ~= owner then
					Popup.show(p, `Tripped on {owner.DisplayName}'s hose!`, "blame", owner)
				end
			end
		end
	end

	-- 3. tangles between lines
	local list: { Hose } = {}
	for _, h in hoses do
		h.crossings = 0
		table.insert(list, h)
	end
	for i = 1, #list do
		for j = i + 1, #list do
			local a, b = list[i], list[j]
			local pa, pb = lines[a.owner], lines[b.owner]
			if not pa or not pb or instanceOf(a.owner) ~= instanceOf(b.owner) then
				continue
			end
			local c = HoseLine.countCrossings(pa, pb, Cfg.TangleMaxDy)
			a.crossings += c
			b.crossings += c
			if c > 0 and not a.tangled[b.owner] then
				a.tangled[b.owner] = true
				b.tangled[a.owner] = true
				count("hose_tangles")
				blame(a, b.owner, now, `Your hose is tangled with {b.owner.DisplayName}'s!`)
				blame(b, a.owner, now, `Your hose is tangled with {a.owner.DisplayName}'s!`)
			elseif c == 0 then
				a.tangled[b.owner] = nil
				b.tangled[a.owner] = nil
			end
		end
	end

	-- 4. pressure (smoothed) + replicated state
	for owner, h in hoses do
		local kinkers = 0
		local culprit: Player? = nil
		for p, t in h.contact do
			if t >= Cfg.KinkDelay then
				kinkers += 1
				culprit = p
			end
		end
		if kinkers == 0 then
			h.kinkedSeg = 0
		end
		h.kinkers = kinkers
		local target = HoseLine.pressureFor(kinkers, h.crossings, Cfg)
		h.pressure += (target - h.pressure) * math.min(1, dt * 8)
		if math.abs(h.pressure - target) < 0.01 then
			h.pressure = target
		end
		local shown = math.floor(h.pressure * 100 + 0.5) / 100
		if owner:GetAttribute("HosePressure") ~= shown then
			owner:SetAttribute("HosePressure", shown)
		end
		local by = if culprit then culprit.DisplayName else nil
		if owner:GetAttribute("HoseKinkedBy") ~= by then
			owner:SetAttribute("HoseKinkedBy", by)
		end
		for i, seg in h.segs do
			local k = i == h.kinkedSeg
			if seg:GetAttribute("Kinked") ~= k then
				seg:SetAttribute("Kinked", k)
			end
		end
	end
end

-- ---------------------------------------------------------------- test hooks (DevHook only)

function HoseLine._state(player: Player): { [string]: any }?
	local h = hoses[player]
	if not h then
		return nil
	end
	return {
		kind = h.kind,
		length = h.length,
		segments = #h.segs,
		pressure = h.pressure,
		kinkers = h.kinkers,
		crossings = h.crossings,
		hoses = hoseCount,
	}
end

-- Hook the player to a temporary anchored "reel" `dist` studs behind them (live checks).
function HoseLine._attachTest(player: Player, dist: number?): boolean
	local root = rootOf(player)
	if not root then
		return false
	end
	local reel = Instance.new("Part")
	reel.Name = "HoseLineTestReel"
	reel.Anchored = true
	reel.Size = Vector3.new(2, 2, 2)
	reel.Color = Palette.TruckRed
	reel.CFrame = root.CFrame * CFrame.new(0, -1, dist or 6)
	reel.Parent = workspace
	local ok = HoseLine.attach(player, reel)
	if not ok then
		reel:Destroy()
	end
	return ok
end

function HoseLine._selftest(): (boolean, string)
	local cfg = Cfg
	local n = HoseLine.segmentCount(cfg.LengthTruck, cfg.SegmentTarget, cfg.MinSegments, cfg.MaxSegments)
	if n < cfg.MinSegments or n > cfg.MaxSegments then
		return false, `segment count {n} out of range`
	end
	if HoseLine.pressureFor(1, 0, cfg) >= 1 then
		return false, "a kink must lower pressure"
	end
	local crossed = HoseLine.crossXZ(Vector3.new(-1, 0, 0), Vector3.new(1, 0, 0), Vector3.new(0, 0, -1), Vector3.new(0, 0, 1))
	if not crossed then
		return false, "crossXZ broken"
	end
	if booted and not PhysicsService:IsCollisionGroupRegistered(HOSE_GROUP) then
		return false, "HoseLine collision group missing"
	end
	local live = 0
	for _ in hoses do
		live += 1
	end
	if live ~= hoseCount then
		return false, `hose count drift {live} vs {hoseCount}`
	end
	return true, `ok ({hoseCount} hoses, {n} segs per truck hose)`
end

return HoseLine
