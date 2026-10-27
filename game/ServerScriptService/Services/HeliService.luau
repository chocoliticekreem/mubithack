--!strict
-- HeliService [owner: Heli]. The FIRE HELICOPTER game pass (MonetizationConfig key "Helicopter";
-- numbers in Config/HeliConfig, maths in ReplicatedStorage/Lib/Heli/HeliRules, model from HeliBuilder).
--   * Ownership = Player attr Pass_Helicopter (MonetizationService: real pass, gift, or Studio
--     PassDebug_Helicopter). While the pass id is 0 nobody owns it outside Studio, so all of this no-ops.
--   * One heli per owner (MaxPerOwner). Owners call it from the station HELIPAD (on the lawn behind the east parking lot: pad,
--     kiosk prompt, HeliWater refill tank) or anywhere with SUMMON HELI (Heli/Summon, cooldown): it lands
--     on a clear spot next to you and you're in the pilot seat. Non-owners at the kiosk get the store
--     (Monetization/Open "heli") instead: "GET THE HELICOPTER".
--   * "Hop in" prompt (F) on every heli: the owner flies (pilot seat), anyone else rides (3 seats).
--   * Flight: the pilot's client owns the physics (SetNetworkOwner) and drives the LinearVelocity /
--     AlignOrientation movers (HeliController). Empty or pilot gone / EXIT in the air -> the server takes the
--     physics back and auto-lands it straight down (LandSpeed), then parks it (anchored).
--   * Bucket (server-authoritative): low over water (Hydrant-tagged ponds / pools / hydrants, HeliWater,
--     terrain water) it fills over FillSeconds (model attr Fill 0..1). Heli/Drop: full + DropCooldown +
--     not higher than DropMaxHeight -> every burning part within DropRadius of the splash (and under it,
--     DropDepth, inside a building under the roof), nearest first, at most DropMaxParts, gets
--     FireService:ApplyWater(pilot, just above it, down, DropLitres): the hose's own API, so it counts
--     exactly like a hose (Extinguished(part, pilot) -> fires out / XP / battle pass / COMBO).
--     Teammates in the splash are cooled (HeatService:Cool). Heli/Fx tells every client to draw it.
-- Remotes: Heli/Summon (C->S, no args, 1/s), Heli/Drop (C->S, no args, 2/s), Heli/Exit (C->S, no args, 2/s),
--          Heli/Fx (S->C all: kind "drop" | "fill", heli: Model, pos: Vector3, hits: number?)
-- Writes: Folder Workspace.Helis, Models tagged "Heli" (attrs Owner, OwnerName, Fill, State "parked" |
--   "flying" | "landing", Pilot (UserId, 0 = none), BoundsMin / BoundsMax (Vector3), NextDrop (server
--   time)), helipad Model "Helipad" in the Station location; tag "HeliWater" on the refill tank.
-- Consumes (nil-guarded): MapService (.LocationBuilt, :GetLocation), FireService:ApplyWater,
--   HeatService:Cool, WorldBoundsService:GetBounds
-- Counters: heli_spawned, heli_summons, heli_fills, heli_drops, heli_drop_hits, heli_store_prompts
-- Test hooks (DevHook only): _spawn(player, cframe?) -> string, _fill(player) -> string,
--   _drop(player) -> string, _state(player) -> JSON, _land(player)
local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local PhysicsService = game:GetService("PhysicsService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("HeliConfig") :: ModuleScript) :: any
local MonCfg = require(ConfigFolder:WaitForChild("MonetizationConfig") :: ModuleScript) :: any
local MapConfig = require(ConfigFolder:WaitForChild("MapConfig") :: ModuleScript) :: any
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local HeliLib = ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Heli")
local Rules = require(HeliLib:WaitForChild("HeliRules") :: ModuleScript)
local Builder = require(HeliLib:WaitForChild("HeliBuilder") :: ModuleScript)

local HeliService = {}
HeliService.Priority = 97 -- after MonetizationService (60), MapService, FireService

local TAG = "Heli"
local WATER_TAG = "HeliWater"
local SEATS = { "PilotSeat", "RideSeat1", "RideSeat2", "RideSeat3" }
-- the heli's solid parts never collide with the people sitting in it (the cabin hull wraps the seats, and
-- the physics rig's torso / head are their own assemblies: they would wedge the heli on the ground)
local BODY_GROUP = "HeliBody"
local RIDER_GROUP = "HeliRider"

type Heli = {
	model: Model,
	root: BasePart,
	owner: Player,
	move: LinearVelocity,
	level: AlignOrientation,
	state: string,
	fill: number,
	lastDrop: number,
	exitPilot: boolean, -- landing because the pilot pressed EXIT: hop them out once down
	idleSince: number,
	filling: boolean,
	fullTold: boolean,
}

local services: { [string]: any } = {}
local helis: { [Player]: Heli } = {}
local lastSummon: { [Player]: number } = {}
local folder: Folder? = nil
local fxRemote: RemoteEvent? = nil
local openStore: RemoteEvent? = nil
local pad: { model: Model?, center: CFrame? } = { model = nil, center = nil }
local waters: { [BasePart]: true } = {}
local riderGroups: { [BasePart]: string } = {} -- a seated rider's part -> its collision group before

local function count(name: string, n: number?)
	pcall(Telemetry.count, name, n or 1)
end

local function owns(player: Player): boolean
	return player:GetAttribute(MonCfg.Attr.PassPrefix .. Cfg.PassKey) == true
end

local function hint(player: Player, text: string)
	pcall(Popup.show, player, text, "hint", player)
end

local function heliOf(model: Instance?): Heli?
	for _, h in helis do
		if h.model == model then
			return h
		end
	end
	return nil
end

local function humOf(player: Player): (Humanoid?, BasePart?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hum and hum.Health > 0 then
		return hum, root
	end
	return nil, nil
end

-- the heli (if any) this player is sitting in, and which seat
local function seatedIn(player: Player): (Heli?, Seat?)
	local hum = humOf(player)
	local seat = hum and hum.SeatPart
	if not seat or not seat:IsA("Seat") then
		return nil, nil
	end
	local h = heliOf(seat.Parent)
	return h, if h then seat :: Seat else nil
end

local function rayParams(h: Heli?): RaycastParams
	local ignore: { Instance } = {}
	local f = folder
	if f then
		table.insert(ignore, f)
	end
	if h then
		table.insert(ignore, h.model)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	rp.RespectCanCollide = true
	rp.IgnoreWater = true
	return rp
end

-- studs from the skids down to solid ground (math.huge = nothing within 400)
local function clearance(h: Heli): (number, Vector3?)
	local from = h.root.Position
	local hit = Workspace:Raycast(from, Vector3.new(0, -400, 0), rayParams(h))
	if not hit then
		return math.huge, nil
	end
	return (from.Y - hit.Position.Y) - Builder.SkidDepth, hit.Position
end

local function bucketPos(h: Heli, clear: number): Vector3
	-- bucket bottom (the rope hangs RopeLength, less when the ground is closer)
	local drop = Rules.ropeDrop(clear + Builder.SkidDepth + Builder.BellyY, Cfg)
	return h.root.Position + Vector3.new(0, Builder.BellyY - drop - 3.2, 0)
end

------------------------------------------------------------------------------------------- water

local function waterRect(p: BasePart): { [string]: number }
	local half = p.Size / 2
	local cf = p.CFrame
	-- axis-aligned footprint of a (possibly rotated) part
	local ex = math.abs(cf.RightVector.X) * half.X + math.abs(cf.UpVector.X) * half.Y + math.abs(cf.LookVector.X) * half.Z
	local ez = math.abs(cf.RightVector.Z) * half.X + math.abs(cf.UpVector.Z) * half.Y + math.abs(cf.LookVector.Z) * half.Z
	local ey = math.abs(cf.RightVector.Y) * half.X + math.abs(cf.UpVector.Y) * half.Y + math.abs(cf.LookVector.Y) * half.Z
	return { minX = cf.X - ex, maxX = cf.X + ex, minZ = cf.Z - ez, maxZ = cf.Z + ez, top = cf.Y + ey }
end

local function addWater(inst: Instance)
	if inst:IsA("BasePart") then
		waters[inst] = true
	elseif inst:IsA("Model") then
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				waters[d] = true
			end
		end
	end
end

local function removeWater(inst: Instance)
	if inst:IsA("BasePart") then
		waters[inst] = nil
	else
		for _, d in inst:GetDescendants() do
			if d:IsA("BasePart") then
				waters[d] = nil
			end
		end
	end
end

local function overWater(h: Heli, b: Vector3): boolean
	for p in waters do
		if p.Parent and Rules.inWater(b.X, b.Y, b.Z, waterRect(p), Cfg) then
			return true
		end
	end
	-- terrain water right under the bucket
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = { Workspace.Terrain }
	rp.IgnoreWater = false
	local hit = Workspace:Raycast(b + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), rp)
	if hit and hit.Material == Enum.Material.Water then
		return b.Y <= hit.Position.Y + (tonumber(Cfg.FillReach) or 7)
	end
	return false
end

------------------------------------------------------------------------------------------- helis

local function setState(h: Heli, s: string)
	h.state = s
	h.model:SetAttribute("State", s)
end

local function setFill(h: Heli, f: number)
	h.fill = f
	-- replicate in 5% steps (the meter is smooth enough; fewer attribute writes)
	local q = math.floor(f * 20 + 0.5) / 20
	if h.model:GetAttribute("Fill") ~= q then
		h.model:SetAttribute("Fill", q)
	end
end

local function pilotOf(h: Heli): Player?
	local seat = h.model:FindFirstChild("PilotSeat") :: Seat?
	local occ = seat and seat.Occupant
	return if occ then Players:GetPlayerFromCharacter(occ.Parent) else nil
end

local function park(h: Heli)
	h.move.Enabled = false
	h.level.Enabled = false
	h.root.AssemblyLinearVelocity = Vector3.zero
	h.root.AssemblyAngularVelocity = Vector3.zero
	h.root.Anchored = true
	setState(h, "parked")
	h.model:SetAttribute("Pilot", 0)
	h.idleSince = os.clock()
end

local function yawOnly(cf: CFrame): CFrame
	local look = cf.LookVector
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	return CFrame.lookAt(Vector3.zero, flat.Unit)
end

local function unseat(player: Player, beside: CFrame?)
	local hum, root = humOf(player)
	if not hum or not hum.SeatPart then
		return
	end
	local w = hum.SeatPart:FindFirstChild("SeatWeld")
	if w then
		w:Destroy()
	end
	hum.Sit = false
	if beside and player.Character then
		task.defer(function()
			if player.Character and player.Character.Parent then
				player.Character:PivotTo(beside)
				if root then
					root.AssemblyLinearVelocity = Vector3.zero
				end
			end
		end)
	end
end

-- a free standing spot on the ground next to the heli (left door first)
local function besideSpot(h: Heli): CFrame
	local cf = h.root.CFrame
	local rp = rayParams(h)
	for _, side in { -1, 1 } do
		for _, back in { -1, 2, 5 } do
			local p = (cf * CFrame.new(side * 7, 0, back)).Position
			local hit = Workspace:Raycast(p + Vector3.new(0, 20, 0), Vector3.new(0, -200, 0), rp)
			if hit then
				local stand = hit.Position + Vector3.new(0, 3.2, 0)
				return CFrame.lookAt(stand, stand + cf.LookVector * Vector3.new(1, 0, 1) + Vector3.new(0, 0, 0.001))
			end
		end
	end
	return cf * CFrame.new(-7, 0, 0)
end

local function startLanding(h: Heli, exitPilot: boolean)
	if h.state == "parked" then
		return
	end
	h.exitPilot = exitPilot
	setState(h, "landing")
	h.root.Anchored = false
	pcall(function()
		h.root:SetNetworkOwner(nil)
	end)
	h.move.Enabled = true
	h.level.Enabled = true
	h.level.CFrame = yawOnly(h.root.CFrame)
end

local function startFlying(h: Heli, pilot: Player)
	h.exitPilot = false
	setState(h, "flying")
	h.model:SetAttribute("Pilot", pilot.UserId)
	h.move.VectorVelocity = Vector3.zero
	h.level.CFrame = yawOnly(h.root.CFrame)
	h.move.Enabled = true
	h.level.Enabled = true
	h.root.Anchored = false
	task.defer(function()
		if h.state == "flying" and h.root.Parent and not h.root.Anchored then
			pcall(function()
				h.root:SetNetworkOwner(pilot)
			end)
		end
	end)
end

local function onPilotChanged(h: Heli)
	local pilot = pilotOf(h)
	if pilot then
		if pilot == h.owner and (h.state == "parked" or h.state == "landing") then
			startFlying(h, pilot)
		end
	elseif h.state == "flying" then
		startLanding(h, false)
	end
end

local function setRider(char: Model?, on: boolean)
	if not char then
		return
	end
	for _, d in char:GetDescendants() do
		if d:IsA("BasePart") then
			if on then
				if riderGroups[d] == nil then
					riderGroups[d] = d.CollisionGroup
				end
				d.CollisionGroup = RIDER_GROUP
			elseif riderGroups[d] ~= nil then
				d.CollisionGroup = riderGroups[d]
				riderGroups[d] = nil
			end
		end
	end
end

local function watchSeat(seat: Seat)
	local was: Model? = nil
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occ = seat.Occupant
		local char = if occ then occ.Parent :: Model? else nil
		if was and was ~= char then
			setRider(was, false)
		end
		if char then
			setRider(char, true)
		end
		was = char
	end)
end

local function destroyHeli(h: Heli)
	for _, p in Players:GetPlayers() do
		local inH = seatedIn(p)
		if inH == h then
			unseat(p, besideSpot(h))
			setRider(p.Character, false)
		end
	end
	if helis[h.owner] == h then
		helis[h.owner] = nil
	end
	h.model:Destroy()
end

local function sitIn(player: Player, seat: Seat): boolean
	local hum = humOf(player)
	if not hum or seat.Occupant then
		return false
	end
	if hum.SeatPart then
		local w = hum.SeatPart:FindFirstChild("SeatWeld")
		if w then
			w:Destroy()
		end
		hum.Sit = false
	end
	local char = player.Character :: Model
	char:PivotTo(seat.CFrame * CFrame.new(0, 2.5, 0))
	seat:Sit(hum)
	return true
end

-- the "Hop in" prompt: owner -> pilot seat (if free), everyone -> the first free ride seat
local function hopIn(h: Heli, player: Player)
	if seatedIn(player) == h then
		return
	end
	if player == h.owner then
		local ps = h.model:FindFirstChild("PilotSeat") :: Seat?
		if ps and not ps.Occupant then
			sitIn(player, ps)
			return
		end
	end
	for i = 2, #SEATS do
		local s = h.model:FindFirstChild(SEATS[i]) :: Seat?
		if s and not s.Occupant then
			sitIn(player, s)
			count("heli_rides")
			return
		end
	end
	hint(player, "It's full! Wait for the next flight")
end

local function addPrompt(h: Heli)
	local att = Instance.new("Attachment")
	att.Name = "HopInAtt"
	att.Position = Vector3.new(0, -1, 0.6)
	att.Parent = h.root
	local pr = Instance.new("ProximityPrompt")
	pr.Name = "HeliBoard"
	pr.ActionText = "Hop in"
	pr.ObjectText = `{h.owner.DisplayName}'s heli`
	pr.KeyboardKeyCode = Enum.KeyCode.F
	pr.HoldDuration = 0
	pr.MaxActivationDistance = 14 -- a big thing: may reach further than 10 (doc 16)
	pr.RequiresLineOfSight = false
	pr.Style = Enum.ProximityPromptStyle.Custom
	pr:SetAttribute("HeliOwner", h.owner.UserId)
	pr.Parent = att
	pr.Triggered:Connect(function(player: Player)
		local hh = heliOf(h.model)
		if hh then
			hopIn(hh, player)
		end
	end)
end

local function bounds(): (Vector3, Vector3)
	local WB = services.WorldBoundsService
	local b: any = nil
	if WB and type(WB.GetBounds) == "function" then
		local ok, res = pcall(WB.GetBounds, WB)
		if ok then
			b = res
		end
	end
	if type(b) ~= "table" then
		b = { minX = -450, maxX = 450, minZ = -450, maxZ = 450 }
	end
	return Vector3.new(b.minX, 0, b.minZ), Vector3.new(b.maxX, 0, b.maxZ)
end

local function build(owner: Player, at: CFrame): Heli
	local m = Builder.build(Cfg)
	m.Name = `Heli_{owner.Name}`
	local root = m.PrimaryPart :: BasePart
	root.Anchored = true
	m:PivotTo(at)
	local att = Instance.new("Attachment")
	att.Name = "RootAtt"
	att.Parent = root
	local mv = Instance.new("LinearVelocity")
	mv.Name = "Move"
	mv.Attachment0 = att
	mv.RelativeTo = Enum.ActuatorRelativeTo.World
	mv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	mv.ForceLimitMode = Enum.ForceLimitMode.Magnitude
	mv.MaxForce = 6e5
	mv.VectorVelocity = Vector3.zero
	mv.Enabled = false
	mv.Parent = root
	local ao = Instance.new("AlignOrientation")
	ao.Name = "Level"
	ao.Attachment0 = att
	ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
	ao.RigidityEnabled = false
	ao.MaxTorque = 5e7
	ao.Responsiveness = 18
	ao.MaxAngularVelocity = 8
	ao.CFrame = yawOnly(at)
	ao.Enabled = false
	ao.Parent = root
	local bmin, bmax = bounds()
	m:SetAttribute("Owner", owner.UserId)
	m:SetAttribute("OwnerName", owner.DisplayName)
	m:SetAttribute("Fill", 0)
	m:SetAttribute("State", "parked")
	m:SetAttribute("Pilot", 0)
	m:SetAttribute("BoundsMin", bmin)
	m:SetAttribute("BoundsMax", bmax)
	m:SetAttribute("NextDrop", 0)
	CollectionService:AddTag(m, TAG)
	local h: Heli = {
		model = m,
		root = root,
		owner = owner,
		move = mv,
		level = ao,
		state = "parked",
		fill = 0,
		lastDrop = -math.huge,
		exitPilot = false,
		idleSince = os.clock(),
		filling = false,
		fullTold = false,
	}
	addPrompt(h)
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") then
			d.CollisionGroup = BODY_GROUP
		end
	end
	for _, n in SEATS do
		local seat = m:FindFirstChild(n)
		if seat and seat:IsA("Seat") then
			watchSeat(seat)
		end
	end
	local ps = m:FindFirstChild("PilotSeat") :: Seat
	ps:GetPropertyChangedSignal("Occupant"):Connect(function()
		onPilotChanged(h)
	end)
	m.Parent = folder
	count("heli_spawned")
	return h
end

-- a landed CFrame at `pos` (ground under it), facing `look`
local function landedAt(pos: Vector3, look: Vector3, h: Heli?): CFrame?
	local hit = Workspace:Raycast(pos + Vector3.new(0, 60, 0), Vector3.new(0, -240, 0), rayParams(h))
	if not hit then
		return nil
	end
	local flat = Vector3.new(look.X, 0, look.Z)
	if flat.Magnitude < 1e-3 then
		flat = Vector3.new(0, 0, -1)
	end
	local p = hit.Position + Vector3.new(0, Builder.SkidDepth + 0.05, 0)
	return CFrame.lookAt(p, p + flat.Unit)
end

local function spotClear(cf: CFrame, h: Heli?): boolean
	local op = OverlapParams.new()
	op.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if h then
		table.insert(ignore, h.model)
	end
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(ignore, p.Character)
		end
	end
	op.FilterDescendantsInstances = ignore
	op.RespectCanCollide = true
	-- hull + rotor disc, lifted off the ground so the floor itself doesn't count
	local box = cf * CFrame.new(0, 3.5, 3)
	local parts = Workspace:GetPartBoundsInBox(box, Vector3.new(18, 9, 26), op)
	return #parts == 0
end

-- where a summoned heli lands near the player: the first clear ring spot, else straight overhead
local function summonSpot(player: Player, h: Heli?): CFrame?
	local _, root = humOf(player)
	if not root then
		return nil
	end
	local look = root.CFrame.LookVector
	local r = tonumber(Cfg.SummonRange) or 26
	for _, dist in { r, r * 0.75, r * 1.4 } do
		for i = 0, 11 do
			local a = i * math.pi / 6
			local off = Vector3.new(math.sin(a), 0, math.cos(a)) * dist
			local cf = landedAt(root.Position + off, look, h)
			if cf and math.abs(cf.Y - root.Position.Y) < 30 and spotClear(cf, h) then
				return cf
			end
		end
	end
	return nil
end

local function padSpots(): { CFrame }
	local c = pad.center
	if not c then
		return {}
	end
	-- the H first, then beside it (HeliConfig Pad.SpareOffsets, in the station's frame; pad.center faces
	-- the lot, so a station-frame offset is the inverse of its rotation)
	local out = { c }
	local spare = (Cfg.Pad :: any).SpareOffsets
	for _, off in (if type(spare) == "table" then spare else {}) :: { Vector3 } do
		table.insert(out, c * CFrame.new(-off.X, off.Y, -off.Z))
	end
	return out
end

local function bringTo(player: Player, cf: CFrame)
	local h = helis[player]
	if h then
		-- riders come along (they're welded to its seats); a flying heli parks first
		park(h)
		h.model:PivotTo(cf)
	else
		h = build(player, cf)
		helis[player] = h
	end
	local hh = h :: Heli
	local ps = hh.model:FindFirstChild("PilotSeat") :: Seat?
	if ps then
		if ps.Occupant and ps.Occupant.Parent ~= player.Character then
			local other = Players:GetPlayerFromCharacter(ps.Occupant.Parent)
			if other then
				unseat(other, besideSpot(hh))
			end
		end
		task.defer(function()
			if ps.Parent then
				sitIn(player, ps)
			end
		end)
	end
end

local function canCall(player: Player): boolean
	if not owns(player) then
		return false
	end
	local now = os.clock()
	if now - (lastSummon[player] or -math.huge) < (tonumber(Cfg.SummonCooldown) or 12) then
		hint(player, "Your heli is on its way! Wait a moment")
		return false
	end
	local h = seatedIn(player)
	if h and h.owner == player then
		return false -- already flying it
	end
	lastSummon[player] = now
	return true
end

local function summon(player: Player): string
	local hum = humOf(player)
	if not hum or not canCall(player) then
		return "not allowed"
	end
	local h = helis[player]
	local cf = summonSpot(player, h)
	if not cf then
		lastSummon[player] = nil
		hint(player, "No room here! Go outside to call your heli")
		return "no room"
	end
	count("heli_summons")
	bringTo(player, cf)
	Popup.show(player, "HELI ON THE WAY!", "good", player)
	return "ok"
end

local function fromPad(player: Player): string
	if not owns(player) then
		count("heli_store_prompts")
		local o = openStore
		if o then
			o:FireClient(player, "heli")
		end
		return "store"
	end
	if not canCall(player) then
		return "not allowed"
	end
	local own = helis[player]
	for _, cf in padSpots() do
		local landed = landedAt(cf.Position, cf.LookVector, own)
		if landed and spotClear(landed, own) then
			count("heli_summons")
			bringTo(player, landed)
			return "ok"
		end
	end
	-- the whole pad is busy: lift off from right above it
	local c = pad.center
	if c then
		bringTo(player, c * CFrame.new(0, 30, 0))
		return "ok (air)"
	end
	return "no pad"
end

------------------------------------------------------------------------------------------- bucket

local function drop(player: Player): string
	local h, seat = seatedIn(player)
	if not h or not seat or seat.Name ~= "PilotSeat" then
		return "not pilot"
	end
	local clear, _ = clearance(h)
	local b = bucketPos(h, clear)
	local hit = Workspace:Raycast(b + Vector3.new(0, 2, 0), Vector3.new(0, -400, 0), rayParams(h))
	local ground = if hit then hit.Position else b - Vector3.new(0, 10, 0)
	local height = b.Y - ground.Y
	local now = os.clock()
	local ok, why = Rules.canDrop({ pilot = h.state == "flying" and player == h.owner, fill = h.fill, now = now, last = h.lastDrop, height = height }, Cfg)
	if not ok then
		if why == "empty" then
			hint(player, "Empty! Fly low over water to fill the bucket")
		elseif why == "too high" then
			hint(player, "Too high! Fly lower")
		elseif why == "cooldown" then
			hint(player, "Refilling...")
		end
		return why or "no"
	end
	h.lastDrop = now
	h.fullTold = false
	setFill(h, 0)
	h.model:SetAttribute("NextDrop", Workspace:GetServerTimeNow() + (tonumber(Cfg.DropCooldown) or 8))
	local radius = tonumber(Cfg.DropRadius) or 18
	-- the burning parts the splash reaches (HeliRules.dropTargets: radius, under the roof, capped), each
	-- hosed point-blank from just above through the hose's own FireService:ApplyWater, so they count like
	-- a hose: Extinguished(part, pilot) -> fires out / XP / battle pass, Doused -> COMBO
	local burning: { BasePart } = {}
	local pts = {}
	for _, b in CollectionService:GetTagged(Names.Tag.Burning) do
		if b:IsA("BasePart") and b:IsDescendantOf(Workspace) then
			table.insert(burning, b)
			table.insert(pts, { x = b.Position.X, y = b.Position.Y, z = b.Position.Z })
		end
	end
	local hits = 0
	local Fire = services.FireService
	local litres = tonumber(Cfg.DropLitres) or 40
	if Fire and type(Fire.ApplyWater) == "function" then
		for _, i in Rules.dropTargets(pts, { x = ground.X, y = ground.Y, z = ground.Z }, Cfg) do
			local b = burning[i]
			if b:HasTag(Names.Tag.Burning) then
				local top = b.Position + Vector3.new(0, b.Size.Y / 2 + 1.5, 0)
				local okW, res = pcall(Fire.ApplyWater, Fire, player, top, Vector3.new(0, -1, 0), litres)
				if okW and type(res) == "number" and res > 0 then
					hits += 1
				end
			end
		end
	end
	-- soak (cool) everyone in the splash
	local Heat = services.HeatService
	for _, p in Players:GetPlayers() do
		local _, r = humOf(p)
		if r and (Vector3.new(r.Position.X, 0, r.Position.Z) - Vector3.new(ground.X, 0, ground.Z)).Magnitude <= radius and math.abs(r.Position.Y - ground.Y) < 25 then
			if Heat and type(Heat.Cool) == "function" then
				pcall(Heat.Cool, Heat, p, 40, player)
			end
		end
	end
	count("heli_drops")
	count("heli_drop_hits", hits)
	local fx = fxRemote
	if fx then
		fx:FireAllClients("drop", h.model, ground, hits)
	end
	pcall(Popup.show, ground + Vector3.new(0, 4, 0), if hits > 0 then `SPLASH! x{hits}` else "SPLASH!", "good", player)
	return `dropped hits={hits} height={math.floor(height)}`
end

local function stepBucket(h: Heli, dt: number)
	if h.state ~= "flying" or h.fill >= 1 then
		h.filling = false
		return
	end
	local clear = clearance(h)
	local b = bucketPos(h, clear)
	local wet = overWater(h, b)
	if wet and not h.filling then
		local fx = fxRemote
		if fx then
			fx:FireAllClients("fill", h.model, b, nil)
		end
	end
	h.filling = wet
	if wet then
		local before = h.fill
		setFill(h, Rules.fill(h.fill, dt, true, Cfg))
		if before < 1 and h.fill >= 1 then
			count("heli_fills")
			if not h.fullTold then
				h.fullTold = true
				local pilot = pilotOf(h)
				if pilot then
					Popup.show(pilot, "BUCKET FULL! Fly to a fire and DROP", "good", pilot)
				end
			end
		end
	end
end

local function stepLanding(h: Heli)
	local clear = clearance(h)
	if clear <= 0.35 or clear == math.huge then
		local riders: { Player } = {}
		local pilot = pilotOf(h)
		park(h)
		if h.exitPilot and pilot then
			unseat(pilot, besideSpot(h))
		end
		h.exitPilot = false
		local _ = riders
		return
	end
	local v = math.min(tonumber(Cfg.LandSpeed) or 22, math.max(3, clear * 2.2))
	h.move.VectorVelocity = Vector3.new(0, -v, 0)
end

local function onExit(player: Player)
	local h, seat = seatedIn(player)
	if not h or not seat then
		return
	end
	if seat.Name == "PilotSeat" then
		local clear = clearance(h)
		if clear > 4 and h.state == "flying" then
			startLanding(h, true) -- safe auto-land with you inside, then out you hop
			Popup.show(player, "LANDING...", "info", player)
			return
		end
		unseat(player, besideSpot(h))
		return
	end
	-- a rider: straight down onto the ground beside it (never a long fall)
	unseat(player, besideSpot(h))
end

------------------------------------------------------------------------------------------- helipad

local function padPart(model: Model, name: string, cf: CFrame, size: Vector3, color: Color3, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local p = Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = o.material or Enum.Material.SmoothPlastic
	p.Shape = o.shape or Enum.PartType.Block
	p.CanCollide = o.collide ~= false
	p.Transparency = o.transparency or 0
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function signText(p: BasePart, face: Enum.NormalId, str: string, color: Color3, pps: number?)
	local g = Instance.new("SurfaceGui")
	g.Face = face
	g.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	g.PixelsPerStud = pps or 40
	g.LightInfluence = 0.3
	g.Parent = p
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Size = UDim2.fromScale(0.94, 0.86)
	l.Position = UDim2.fromScale(0.03, 0.07)
	l.Font = Enum.Font.LuckiestGuy
	l.TextScaled = true
	l.Text = str
	l.TextColor3 = color
	l.Parent = g
	local s = Instance.new("UIStroke")
	s.Thickness = 3
	s.Color = Color3.fromHex("#2A1410")
	s.Parent = l
end

local function buildPad(station: Model)
	local P = Cfg.Pad
	local old = station:FindFirstChild("Helipad")
	if old then
		old:Destroy()
	end
	local origin = station:GetAttribute("StationOrigin")
	local O: CFrame = if typeof(origin) == "CFrame" then origin else MapConfig.SlotOrigin(0)
	local m = Instance.new("Model")
	m.Name = "Helipad"
	local c: Vector3 = P.Center
	local R: number = P.Radius
	local base = O * CFrame.new(c)
	local Z90 = CFrame.Angles(0, 0, math.rad(90))
	-- the pad sits on the lawn behind the parking lot: a flat paved apron under it and a path from the
	-- lot's back edge (station-local Z -50) to the kiosk, so you can see and walk straight to it
	local apronW = R * 2 + 12
	padPart(m, "PadApron", base * CFrame.new(0, -0.1, -4), Vector3.new(apronW, 0.2, apronW + 8), Color3.fromHex("#8E8A86"), { collide = false })
	local pathZ0 = c.Z - 4 + (apronW + 8) / 2 -- apron front edge (local, toward the lot)
	local pathLen = math.max(0, -50 - pathZ0)
	if pathLen > 0 then
		padPart(m, "PadPath", O * CFrame.new(c.X, c.Y - 0.1, pathZ0 + pathLen / 2), Vector3.new(8, 0.2, pathLen), Color3.fromHex("#B9A38E"), { collide = false })
	end
	-- the pad: dark disc, yellow ring, big white H (paint on top)
	padPart(m, "Pad", base * CFrame.new(0, 0.12, 0) * Z90, Vector3.new(0.3, R * 2, R * 2), Color3.fromHex("#3A3A44"), { shape = Enum.PartType.Cylinder })
	padPart(m, "Ring", base * CFrame.new(0, 0.2, 0) * Z90, Vector3.new(0.18, R * 2 - 1.2, R * 2 - 1.2), Color3.fromHex("#FFC531"), {
		shape = Enum.PartType.Cylinder,
		collide = false,
	})
	padPart(m, "RingInner", base * CFrame.new(0, 0.24, 0) * Z90, Vector3.new(0.18, R * 2 - 3, R * 2 - 3), Color3.fromHex("#3A3A44"), {
		shape = Enum.PartType.Cylinder,
		collide = false,
	})
	local W = Color3.fromHex("#FFF6EA")
	padPart(m, "H1", base * CFrame.new(-3.2, 0.3, 0), Vector3.new(1.8, 0.1, 11), W, { collide = false })
	padPart(m, "H2", base * CFrame.new(3.2, 0.3, 0), Vector3.new(1.8, 0.1, 11), W, { collide = false })
	padPart(m, "H3", base * CFrame.new(0, 0.3, 0), Vector3.new(6.4, 0.1, 1.8), W, { collide = false })
	-- corner lights
	for i = 0, 7 do
		local a = i * math.pi / 4
		padPart(m, "PadLight", base * CFrame.new(math.cos(a) * (R + 0.6), 0.4, math.sin(a) * (R + 0.6)), Vector3.new(0.8, 0.8, 0.8), Color3.fromHex("#6BCB5A"), {
			shape = Enum.PartType.Ball,
			material = Enum.Material.Neon,
			collide = false,
		})
	end
	-- the refill tank: a round pool of water (tag HeliWater)
	local wc = base * CFrame.new(P.WaterOffset)
	local wr: number = P.WaterRadius
	padPart(m, "TankWall", wc * CFrame.new(0, 1.1, 0) * Z90, Vector3.new(2.2, wr * 2 + 1.6, wr * 2 + 1.6), Color3.fromHex("#C8232B"), { shape = Enum.PartType.Cylinder })
	local water = padPart(m, "TankWater", wc * CFrame.new(0, 1.35, 0) * Z90, Vector3.new(2.2, wr * 2, wr * 2), Color3.fromHex("#4FB3D9"), {
		shape = Enum.PartType.Cylinder,
		material = Enum.Material.Glass,
		transparency = 0.15,
	})
	CollectionService:AddTag(water, WATER_TAG)
	local tankSign = padPart(m, "TankSign", wc * CFrame.new(0, 3.2, wr + 0.9), Vector3.new(9, 1.6, 0.3), Color3.fromHex("#2E5E9A"), { collide = false })
	signText(tankSign, Enum.NormalId.Back, "BUCKET REFILL", W)
	signText(tankSign, Enum.NormalId.Front, "BUCKET REFILL", W)
	-- the kiosk: a sign on a post at the pad's front (+Z) edge, where the path from the lot arrives, a
	-- little off the path's centre line so it never stands in the way
	local kc = base * CFrame.new(-9, 0, R + 3)
	padPart(m, "KioskPost", kc * CFrame.new(0, 3, 0), Vector3.new(0.6, 6, 0.6), Color3.fromHex("#4A4650"))
	local sign = padPart(m, "KioskSign", kc * CFrame.new(0, 6.6, 0), Vector3.new(9, 3.2, 0.4), Color3.fromHex("#D9372A"))
	signText(sign, Enum.NormalId.Front, "🚁 HELIPAD", W)
	signText(sign, Enum.NormalId.Back, "🚁 HELIPAD", W)
	local pr = Instance.new("ProximityPrompt")
	pr.Name = "HeliPadPrompt"
	pr.ActionText = "Fly the helicopter"
	pr.ObjectText = "Helipad"
	pr.KeyboardKeyCode = Enum.KeyCode.E
	pr.HoldDuration = 0
	pr.MaxActivationDistance = 14
	pr.RequiresLineOfSight = false
	pr.Style = Enum.ProximityPromptStyle.Custom
	pr.Parent = sign
	pr.Triggered:Connect(function(player: Player)
		fromPad(player)
	end)
	m.Parent = station
	pad.model = m
	pad.center = base * CFrame.Angles(0, math.pi, 0) -- nose toward the lot and the street (+Z)
end

------------------------------------------------------------------------------------------- loop

local function tick(dt: number)
	for owner, h in helis do
		if not h.model.Parent or not h.root.Parent then
			helis[owner] = nil
			continue
		end
		if h.root.Position.Y < -60 or h.root.Position.Y ~= h.root.Position.Y then
			destroyHeli(h)
			continue
		end
		if h.state == "flying" then
			local pilot = pilotOf(h)
			if pilot ~= h.owner then
				startLanding(h, false)
			end
			stepBucket(h, dt)
		elseif h.state == "landing" then
			stepLanding(h)
		elseif h.state == "parked" then
			local _, r = humOf(owner)
			if r and (r.Position - h.root.Position).Magnitude < 300 then
				h.idleSince = os.clock()
			elseif os.clock() - h.idleSince > (tonumber(Cfg.IdleDespawnSeconds) or 600) then
				destroyHeli(h)
			end
		end
	end
end

function HeliService:Init(all: { [string]: any })
	services = all
end

function HeliService:Start()
	local f = Workspace:FindFirstChild("Helis")
	if not f then
		local nf = Instance.new("Folder")
		nf.Name = "Helis"
		nf.Parent = Workspace
		f = nf
	end
	folder = f :: Folder
	pcall(function()
		for _, g in { BODY_GROUP, RIDER_GROUP } do
			if not PhysicsService:IsCollisionGroupRegistered(g) then
				PhysicsService:RegisterCollisionGroup(g)
			end
		end
		PhysicsService:CollisionGroupSetCollidable(BODY_GROUP, RIDER_GROUP, false)
	end)
	fxRemote = Net.event("Heli", "Fx")
	openStore = Net.event("Monetization", "Open")
	Net.onServer(Net.event("Heli", "Summon"), { rate = 1, burst = 1 }, function(player: Player)
		summon(player)
	end)
	Net.onServer(Net.event("Heli", "Drop"), { rate = 2, burst = 1 }, function(player: Player)
		drop(player)
	end)
	Net.onServer(Net.event("Heli", "Exit"), { rate = 2, burst = 2 }, onExit)

	for _, t in { Names.Tag.Hydrant, WATER_TAG } do
		for _, inst in CollectionService:GetTagged(t) do
			addWater(inst)
		end
		CollectionService:GetInstanceAddedSignal(t):Connect(addWater)
		CollectionService:GetInstanceRemovedSignal(t):Connect(removeWater)
	end

	local function onPlayer(player: Player)
		player:GetAttributeChangedSignal(MonCfg.Attr.PassPrefix .. Cfg.PassKey):Connect(function()
			if not owns(player) then
				local h = helis[player]
				if h then
					destroyHeli(h)
				end
			end
		end)
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, p in Players:GetPlayers() do
		onPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		local h = helis[player]
		if h then
			destroyHeli(h)
		end
		lastSummon[player] = nil
	end)

	local Map = services.MapService
	if Map then
		if Map.LocationBuilt then
			Map.LocationBuilt:Connect(function(model: Model, id: string)
				if id == Cfg.Pad.LocationId then
					local ok, err = pcall(buildPad, model)
					if not ok then
						warn(`[HeliService] helipad: {err}`)
					end
				end
			end)
		end
		local existing = type(Map.GetLocation) == "function" and Map:GetLocation(Cfg.Pad.LocationId)
		if existing then
			local ok, err = pcall(buildPad, existing)
			if not ok then
				warn(`[HeliService] helipad: {err}`)
			end
		end
	end

	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		-- landing descends every frame (smooth); the bucket / housekeeping runs at 10 Hz
		for _, h in helis do
			if h.state == "landing" and h.root.Parent then
				stepLanding(h)
			end
		end
		acc += dt
		if acc >= 0.1 then
			local step = acc
			acc = 0
			local ok, err = pcall(tick, step)
			if not ok then
				warn(`[HeliService] tick: {err}`)
			end
		end
	end)
end

------------------------------------------------------------------------------------------ public API

function HeliService:GetHeli(player: Player): Model?
	local h = helis[player]
	return h and h.model
end

------------------------------------------------------------------------------------------ test hooks

function HeliService:_spawn(player: Player, cf: CFrame?): string
	if not owns(player) then
		return "not an owner (set PassDebug_Helicopter)"
	end
	lastSummon[player] = nil
	if cf then
		bringTo(player, cf)
		return "ok"
	end
	return summon(player)
end

function HeliService:_pad(player: Player): string
	lastSummon[player] = nil
	return fromPad(player)
end

function HeliService:_fill(player: Player): string
	local h = helis[player]
	if not h then
		return "no heli"
	end
	setFill(h, 1)
	return "full"
end

function HeliService:_drop(player: Player): string
	return drop(player)
end

function HeliService:_exit(player: Player)
	onExit(player)
end

function HeliService:_state(player: Player): string
	local h = helis[player]
	if not h then
		return "{}"
	end
	local clear = clearance(h)
	local b = bucketPos(h, clear)
	return HttpService:JSONEncode({
		state = h.state,
		fill = h.fill,
		pilot = (pilotOf(h) or {} :: any).Name,
		pos = { math.floor(h.root.Position.X), math.floor(h.root.Position.Y), math.floor(h.root.Position.Z) },
		clearance = if clear == math.huge then -1 else math.floor(clear * 10) / 10,
		overWater = overWater(h, b),
		anchored = h.root.Anchored,
		waters = (function()
			local n = 0
			for _ in waters do
				n += 1
			end
			return n
		end)(),
	})
end

return HeliService
