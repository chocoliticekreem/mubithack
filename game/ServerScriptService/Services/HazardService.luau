--!strict
-- HazardService [owner: GF]. Scripted chaos per mission instance (docs/game/01 §8, the trailer gags).
-- Hazards are scoped to an instanceId (v1's single round uses the location Id, e.g. "Town").
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   HazardService:Trigger(instanceId: string, hazardId: Types.HazardId, params: { [string]: any }?): boolean
--   HazardService:Clear(instanceId: string)                         -- stop every live hazard (mission end)
--   HazardService:GetActive(instanceId: string): { Types.HazardId }
-- params per hazardId (all optional unless marked):
--   electrocution  { fuseBox: BasePart?, culprit: Player? }  -- FuseBox Power = true; everyone standing on a
--                     WetFloor part within ZapRadius is zapped now (blame the flipper) and while it stays live
--   fire_tornado   { position: Vector3?, seconds: number? }   -- wanders the field, ignites, sucks in loose
--                     parts/NPCs, flings players
--   explosion      { position: Vector3 (required), radius: number?, culprit: Player? }
--   tidal_wave     { direction: Vector3?, seconds: number?, culprit: Player? }  -- a water wall sweeps the
--                     instance's "WaveVolume" part (else its bounding box), extinguishes, ragdolls, floods
--   cigarette      { npc: Model? }                           -- farmer relights hay until carried/rescued
--   EXTRA ids (not in Types.HazardId yet; Trigger accepts them): "backdraft" { door: BasePart, culprit: Player? },
--                  "ceiling_collapse" { parts: { BasePart }?, position: Vector3?, radius: number?, culprit: Player? }
--   v3 MISSION TWISTS (catalog `hazards`, armed only, not Trigger ids; Lib/Hazard/Twists has the details):
--                  "grease_fire" (diner fryer: water = fireball, extinguisher/lid = out), "gas_leak" (pump
--                  valves vs a tanker countdown), "pileup" (pinned drivers, pry the doors), "cat_tree" (a
--                  cat up a tree, ladder it down)
-- MissionCatalog hook: on MissionService.MissionStarted(instanceId, missionId) the def's `hazards` are armed
--   (fuse box lever prompts, gas tanks that blow when fire reaches them, a scripted tornado after
--   TornadoDelay, a detonator prompt for the wave). Every armed instance also watches for backdrafts
--   (a Door breaking with fire behind it) and ceiling collapse (a building's Ceiling*/Roof* parts Charred).
--   MissionEnded -> Clear. (MissionService runs v1 rounds as instances too, so this covers them.)
-- Signals: Triggered(instanceId: string, hazardId: string), Zapped(victim: Player, culprit: Player?),
--          Flung(victim: Player, hazardId: string)
-- Remotes: Hazard/Zapped (S->C all: victim: number, culprit: number? UserIds),
--          Hazard/Fx (S->C all: hazardId: string, position: Vector3, params: { [string]: any })
-- Consumes (nil-guarded): MapService:GetInstance/GetLocation, FireService:Ignite/ApplyWater/ExtinguishAll,
--   HeatService:AddHeat/Cool (hazard "damage" is Heat), MissionService.MissionStarted/MissionEnded/GetMissions,
--   FinaleService:Detonate, ToolService.DoorBroken, Shared/Ragdoll, Config/MissionCatalog
-- Reads tags: FuseBox, WetFloor, Hazard (attr HazardId), Door, Flammable, Burning, Rescuable;
--   parts named "WaveVolume", "TornadoField", "Ceiling*"/"Roof*" (attr BuildingId groups a building)
-- Writes: FuseBox attr Power; counters hazards_triggered, electrocutions, electrocutions_teammate, power_cut,
--   explosions, tornadoes, tornado_flings, tidal_waves, backdrafts, collapses
-- Test hooks (DevHook only): _trigger(instanceId, hazardId), _arm(instanceId, missionId),
--   _twist(instanceId, kind) (arm one v3 twist on a live run), _twists(instanceId) (live twist targets),
--   _twistPrompt(instanceId, actionText, userId?) / _twistSpray(instanceId, "hose"|"foam", userId?), _selftest()
local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local HazardConfig = require(ConfigFolder:WaitForChild("HazardConfig") :: ModuleScript)
local SquadConfig = require(ConfigFolder:WaitForChild("SquadConfig") :: ModuleScript) :: any
local HazardMath = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Hazard"):WaitForChild("HazardMath") :: ModuleScript)
local Rubble = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Physics"):WaitForChild("Rubble") :: ModuleScript)
local Twists = require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Hazard"):WaitForChild("Twists") :: ModuleScript) :: any

local HazardService = {}
HazardService.Priority = 70
HazardService.Triggered = Signal.new() :: Signal.Signal<string, string>
HazardService.Zapped = Signal.new() :: Signal.Signal<Player, Player?>
HazardService.Flung = Signal.new() :: Signal.Signal<Player, string>
HazardService.Caused = Signal.new() :: Signal.Signal<Player?, string> -- (culprit, "backdraft"): BlameService

type Handle = { stop: () -> () }
type Armed = { conns: { RBXScriptConnection }, threads: { thread }, prompts: { Instance }, collapsed: { [string]: boolean } }

local services: { [string]: any } = {}
local active: { [string]: { [string]: Handle } } = {} -- instanceId -> hazardId -> live handle
local armed: { [string]: Armed } = {}
local zapRemote: RemoteEvent? = nil
local fxRemote: RemoteEvent? = nil
local zapCooldown: { [Player]: number } = {}
local lastShock: { [Player]: number } = {} -- first touch stuns, a second one within ZapKnockWindow knocks you flat
local lastFlipper: { [BasePart]: Player } = {}
local floodBlocks: { [string]: { CFrame | Vector3 } } = {}

local ORANGE = Color3.fromRGB(255, 122, 31)
local EMBER = Color3.fromRGB(255, 228, 92)
local SMOKE = Color3.fromRGB(94, 90, 85)
local WAVE_DEEP = Color3.fromRGB(28, 92, 160)
local WAVE_MID = Color3.fromRGB(58, 140, 205)
local FOAM = Color3.fromRGB(235, 248, 255)

---------------------------------------------------------------------------------------------- helpers

local function count(name: string, n: number?)
	Telemetry.count(name, n or 1)
end

local function rootOf(instanceId: string): Instance?
	local Map = services.MapService
	if not Map then
		return nil
	end
	local inst = if type(Map.GetInstance) == "function" then Map:GetInstance(instanceId) else nil
	return inst or Map:GetLocation(instanceId)
end

local function bounds(root: Instance): (CFrame, Vector3)
	if root:IsA("Model") then
		return root:GetBoundingBox()
	end
	return CFrame.new(), Vector3.new(400, 200, 400)
end

local function inRoot(root: Instance, pos: Vector3): boolean
	local cf, size = bounds(root)
	local p = cf:PointToObjectSpace(pos)
	return HazardMath.inBox(p.X, p.Y, p.Z, 0, 0, 0, size.X / 2 + 10, size.Y / 2 + 60, size.Z / 2 + 10)
end

-- Players in this mission instance (attr InstanceId), or physically inside a v1 location.
local function playersIn(instanceId: string, root: Instance): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		local char = p.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not hrp then
			continue
		end
		local tag = p:GetAttribute(Names.Attr.InstanceId)
		if tag == instanceId or ((tag == nil or tag == "") and inRoot(root, hrp.Position)) then
			table.insert(out, p)
		end
	end
	return out
end

local function rootPart(p: Player): BasePart?
	local char = p.Character
	return char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function ragdollModule(): any
	local ok, R = pcall(require, Shared:WaitForChild("Ragdoll") :: ModuleScript)
	return if ok then R else nil
end

-- Limp for `seconds` plus a velocity kick. Players: Shared/Ragdoll (owner client applies it). NPCs: here.
local function ragdoll(character: Model, seconds: number, impulse: Vector3?)
	local R = ragdollModule()
	local done = false
	if R then
		done = R.enable(character, seconds) == true
		if impulse then
			R.knockback(character, impulse)
		end
	end
	if done then
		return
	end
	-- fallback while Ragdoll is a stub / for server-owned NPCs
	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = true
		task.delay(seconds, function()
			if hum.Parent then
				hum.PlatformStand = false
			end
		end)
	end
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hrp and impulse and not Players:GetPlayerFromCharacter(character) then
		hrp.AssemblyLinearVelocity += impulse
	end
end

local function hurt(p: Player, amount: number, source: string)
	local Heat = services.HeatService
	if Heat and type(Heat.AddHeat) == "function" then
		pcall(Heat.AddHeat, Heat, p, amount, source)
	end
end

local function fx(hazardId: string, pos: Vector3, params: { [string]: any }?)
	if fxRemote then
		fxRemote:FireAllClients(hazardId, pos, params or {})
	end
end

local function sound(parent: Instance, id: string, volume: number, looped: boolean?): Sound?
	if id == "" then
		return nil
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Volume = volume
	s.Looped = looped == true
	s.RollOffMaxDistance = 400
	s.Parent = parent
	if not s.Looped then
		s.Ended:Connect(function()
			s:Destroy()
		end)
	end
	s:Play()
	return s
end

local function ignite(part: BasePart, cause: Player?)
	local Fire = services.FireService
	if Fire and type(Fire.Ignite) == "function" and part:HasTag(Names.Tag.Flammable) and not part:HasTag(Names.Tag.Burning) then
		pcall(Fire.Ignite, Fire, part, cause)
	end
end

local function douse(part: BasePart)
	local Fire = services.FireService
	if Fire and type(Fire.ApplyWater) == "function" then
		pcall(Fire.ApplyWater, Fire, nil, part.Position + Vector3.new(0, 3, 0), Vector3.new(0, -1, 0), 200)
	end
end

local function partsNear(pos: Vector3, radius: number, root: Instance?): { BasePart }
	local op = OverlapParams.new()
	if root then
		op.FilterType = Enum.RaycastFilterType.Include
		op.FilterDescendantsInstances = { root }
	end
	return workspace:GetPartBoundsInRadius(pos, radius, op)
end

local function groundY(pos: Vector3, ignore: { Instance }): number
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(pos + Vector3.new(0, 40, 0), Vector3.new(0, -200, 0), rp)
	return if hit then hit.Position.Y else pos.Y
end

local function tagged(tag: string, root: Instance): { BasePart }
	local out = {}
	for _, inst in CollectionService:GetTagged(tag) do
		local part: BasePart? = nil
		if inst:IsA("BasePart") then
			part = inst
		elseif inst:IsA("Model") then
			part = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
		end
		if part and (inst:IsDescendantOf(root) or inRoot(root, part.Position)) then
			table.insert(out, part)
		end
	end
	return out
end

-- Hazard-tagged sources with a given HazardId (attr on the part or its Model).
local function sources(root: Instance, hazardId: string): { BasePart }
	local out = {}
	for _, inst in CollectionService:GetTagged(Names.Tag.Hazard) do
		if inst:GetAttribute(Names.Attr.HazardId) ~= hazardId or not inst:IsDescendantOf(root) then
			continue
		end
		local part = if inst:IsA("BasePart") then inst elseif inst:IsA("Model") then (inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)) else nil
		if part then
			table.insert(out, part)
		end
	end
	return out
end

local function setActive(instanceId: string, hazardId: string, h: Handle?)
	local list = active[instanceId]
	if not list then
		list = {}
		active[instanceId] = list
	end
	local old = list[hazardId]
	if old and old ~= h then
		pcall(old.stop)
	end
	list[hazardId] = h
end

local function displayName(p: Player?): string
	return if p then p.DisplayName else "Someone"
end

---------------------------------------------------------------------------------------------- electrocution

local function powerOf(box: BasePart): boolean
	local holder: Instance = if box.Parent and box.Parent:IsA("Model") and box.Parent:HasTag(Names.Tag.FuseBox) then box.Parent else box
	local v = holder:GetAttribute(Names.Attr.Power)
	if v == nil then
		v = box:GetAttribute(Names.Attr.Power)
	end
	return v ~= false
end

local function setPower(box: BasePart, on: boolean)
	box:SetAttribute(Names.Attr.Power, on)
	local parent = box.Parent
	if parent and parent:IsA("Model") and parent:HasTag(Names.Tag.FuseBox) then
		parent:SetAttribute(Names.Attr.Power, on)
	end
end

-- Wet floor parts within ZapRadius of a powered fuse box.
local function livePuddles(root: Instance, boxes: { BasePart }): { BasePart }
	local out = {}
	local wet = tagged(Names.Tag.WetFloor, root)
	for _, w in wet do
		for _, box in boxes do
			if powerOf(box) and (w.Position - box.Position).Magnitude <= HazardConfig.ZapRadius then
				table.insert(out, w)
				break
			end
		end
	end
	return out
end

-- Puddles from ToolService are flat cylinders (axis = local X pointing up); builder wet floors are boxes.
local function onPuddle(hrp: BasePart, w: BasePart): boolean
	local rel = hrp.Position - w.Position
	local dy = rel.Y
	if dy < -1.5 or dy > HazardConfig.ZapStandHeight then
		return false
	end
	if w:IsA("Part") and w.Shape == Enum.PartType.Cylinder then
		local r = math.max(w.Size.Y, w.Size.Z) / 2 + 0.5
		return Vector3.new(rel.X, 0, rel.Z).Magnitude <= r
	end
	local p = w.CFrame:PointToObjectSpace(hrp.Position)
	local half = w.Size / 2
	return math.abs(p.X) <= half.X + 0.5 and math.abs(p.Z) <= half.Z + 0.5
end

local function standingOn(hrp: BasePart, puddles: { BasePart }): boolean
	for _, w in puddles do
		if onPuddle(hrp, w) then
			return true
		end
	end
	return false
end

local function zap(victim: Player, culprit: Player?, pos: Vector3)
	local char = victim.Character
	if not char then
		return
	end
	local now = os.clock()
	local again = now - (lastShock[victim] or -math.huge) < HazardConfig.ZapKnockWindow
	lastShock[victim] = now
	zapCooldown[victim] = now
	local hum = char:FindFirstChildOfClass("Humanoid")
	if again then
		-- touched it AGAIN: knocked flat
		hurt(victim, HazardConfig.ZapKnockHeat, "electrocution")
		ragdoll(char, HazardConfig.ZapRagdollSeconds, Vector3.new(math.random(-8, 8), 22, math.random(-8, 8)))
	else
		-- first touch: stuck buzzing (clients shake you + flash your skeleton), staggering slowly; walk off it
		hurt(victim, HazardConfig.ZapStunHeat, "electrocution")
		victim:SetAttribute("Shocked", true)
		if hum then
			hum.WalkSpeed = math.min(hum.WalkSpeed, HazardConfig.ZapStunWalkSpeed)
			hum.UseJumpPower = false
			hum.JumpHeight = 0
		end
		task.delay(HazardConfig.ZapStunSeconds, function()
			if victim:GetAttribute("Shocked") ~= true then
				return
			end
			victim:SetAttribute("Shocked", nil)
			local h = victim.Character and victim.Character:FindFirstChildOfClass("Humanoid")
			if h and victim:GetAttribute(Names.Attr.Downed) ~= true then
				local broken = victim:GetAttribute("BrokenLeg") == true
				h.WalkSpeed = if broken then 7 else SquadConfig.WalkSpeed
				h.JumpHeight = if broken then 0 else SquadConfig.JumpHeight
			end
		end)
	end
	count("electrocutions")
	if culprit and culprit ~= victim then
		count("electrocutions_teammate")
	end
	HazardService.Zapped:Fire(victim, culprit)
	if zapRemote then
		zapRemote:FireAllClients(victim.UserId, if culprit then culprit.UserId else nil)
	end
	fx("electrocution", pos, { victim = victim.UserId })
	if again then
		Popup.show(victim, "ZAPPED AGAIN! Knocked flat. Cut the power!", "bad", victim)
	elseif culprit and culprit ~= victim then
		Popup.show(victim, `Zapped by {culprit.DisplayName}! Get off the puddle!`, "blame", culprit)
	elseif culprit == victim then
		Popup.show(victim, "Self-zap! Get off the puddle!", "blame", victim)
	else
		Popup.show(victim, "BZZZT! Live puddle! Get off it!", "bad", victim)
	end
end

local function electrocution(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local boxes = tagged(Names.Tag.FuseBox, root)
	for _, s in sources(root, "electrocution") do
		table.insert(boxes, s)
	end
	local box = params.fuseBox
	if typeof(box) == "Instance" and (box :: Instance):IsA("BasePart") then
		table.insert(boxes, box :: BasePart)
		setPower(box :: BasePart, true)
		if params.culprit then
			lastFlipper[box :: BasePart] = params.culprit
		end
	elseif #boxes > 0 then
		for _, b in boxes do
			setPower(b, true)
		end
	end
	local culprit: Player? = params.culprit
	-- instant zap: everyone already standing in a live puddle (the trailer beat)
	local puddles = livePuddles(root, boxes)
	for _, p in playersIn(instanceId, root) do
		local hrp = rootPart(p)
		if hrp and standingOn(hrp, puddles) then
			zap(p, culprit, hrp.Position)
		end
	end
	-- live loop: new victims while the power stays on
	local running = true
	local h: Handle = {
		stop = function()
			running = false
		end,
	}
	setActive(instanceId, "electrocution", h)
	task.spawn(function()
		while running do
			task.wait(HazardConfig.ZapTickSeconds)
			if not running or not root.Parent then
				break
			end
			local live = livePuddles(root, boxes)
			if #live == 0 then
				local anyOn = false
				for _, b in boxes do
					anyOn = anyOn or (b.Parent ~= nil and powerOf(b))
				end
				if not anyOn and #boxes > 0 then
					break
				end
				continue
			end
			local now = os.clock()
			for _, p in playersIn(instanceId, root) do
				local hrp = rootPart(p)
				if hrp and now - (zapCooldown[p] or 0) > HazardConfig.ZapCooldown and standingOn(hrp, live) then
					local who: Player? = nil
					for _, b in boxes do
						who = who or lastFlipper[b]
					end
					zap(p, who, hrp.Position)
				end
			end
		end
		if active[instanceId] and active[instanceId].electrocution == h then
			active[instanceId].electrocution = nil
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------- explosion

local function debrisBurst(pos: Vector3, n: number, color: Color3?)
	for i = 1, n do
		local d = Instance.new("Part")
		d.Name = "BoomDebris"
		local s = 0.6 + math.random() * 1.4
		d.Size = Vector3.new(s, s * (0.5 + math.random()), s)
		d.Color = color or (if i % 3 == 0 then ORANGE elseif i % 3 == 1 then SMOKE else Color3.fromRGB(60, 50, 45))
		d.Material = if i % 3 == 0 then Enum.Material.Neon else Enum.Material.SmoothPlastic
		d.CFrame = CFrame.new(pos + Vector3.new(0, 2, 0)) * CFrame.Angles(math.random() * 6, math.random() * 6, math.random() * 6)
		d.CanCollide = true
		d.CanQuery = false
		d.CanTouch = false
		d.Parent = workspace
		d.AssemblyLinearVelocity = Vector3.new(math.random(-50, 50), math.random(40, 90), math.random(-50, 50))
		d.AssemblyAngularVelocity = Vector3.new(math.random(-20, 20), math.random(-20, 20), math.random(-20, 20))
		Debris:AddItem(d, 5 + math.random() * 2)
	end
end

local function explosion(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local pos = params.position
	if typeof(pos) ~= "Vector3" then
		return false
	end
	local center = pos :: Vector3
	local radius = tonumber(params.radius) or HazardConfig.ExplosionRadius
	local culprit: Player? = params.culprit
	local big = params.big == true -- the tanker: huge flash/shake for everyone nearby, louder, more debris
	local maxDamage = tonumber(params.damage) or HazardConfig.ExplosionDamage
	local igniteCap = tonumber(params.ignite) or HazardConfig.ExplosionIgnite
	-- visual-only engine explosion (we do our own knockback)
	local e = Instance.new("Explosion")
	e.Position = center
	e.BlastRadius = if big then math.min(radius, 40) else radius
	e.BlastPressure = 0
	e.DestroyJointRadiusPercent = 0
	e.ExplosionType = Enum.ExplosionType.NoCraters
	e.Parent = workspace
	local holder = Instance.new("Part")
	holder.Anchored = true
	holder.CanCollide = false
	holder.CanQuery = false
	holder.Transparency = 1
	holder.Size = Vector3.one
	holder.Position = center
	holder.Parent = workspace
	local boom = sound(holder, HazardConfig.ExplosionSoundId, if big then 3 else 1.5)
	if big and boom then
		boom.RollOffMaxDistance = 1200
		boom.RollOffMinDistance = 60
		-- a second, slower copy: the deep rumble under the bang
		local rumble = sound(holder, HazardConfig.ExplosionSoundId, 3)
		if rumble then
			rumble.PlaybackSpeed = 0.55
			rumble.RollOffMaxDistance = 1200
			rumble.RollOffMinDistance = 60
		end
	end
	Debris:AddItem(holder, 8)
	debrisBurst(center, if big then HazardConfig.ExplosionDebris * 2 else HazardConfig.ExplosionDebris)
	fx("explosion", center, { radius = radius, big = big })
	count("explosions")

	for _, p in playersIn(instanceId, root) do
		local hrp = rootPart(p)
		local char = p.Character
		if not hrp or not char then
			continue
		end
		local d = (hrp.Position - center).Magnitude
		if d >= radius * 1.4 then
			continue
		end
		local dmg = HazardMath.blastDamage(d, radius, maxDamage)
		if dmg > 0 then
			hurt(p, dmg, "explosion")
		end
		local speed = HazardMath.knockback(d, radius * 1.4, HazardConfig.ExplosionKnockback, HazardConfig.ExplosionKnockbackMin)
		local away = hrp.Position - center
		away = if away.Magnitude > 0.1 then away.Unit else Vector3.new(0, 1, 0)
		ragdoll(char, HazardConfig.ExplosionRagdollSeconds, (away + Vector3.new(0, 1.1, 0)).Unit * speed)
		-- Flung = Downed (SquadService): only in the blast's core. The outer ring just sends you flying, so a
		-- big blast (the tanker's 60-stud radius) doesn't wipe a squad that kept its distance.
		if d < radius * (HazardConfig.ExplosionDownShare or 0.45) then
			HazardService.Flung:Fire(p, "explosion")
		end
	end
	-- NPCs and loose props go flying too
	for _, npc in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if npc:IsA("Model") and npc:IsDescendantOf(root) then
			local hrp = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and (hrp.Position - center).Magnitude < radius then
				local away = (hrp.Position - center)
				away = if away.Magnitude > 0.1 then away.Unit else Vector3.yAxis
				ragdoll(npc, 2, (away + Vector3.new(0, 1, 0)).Unit * 60)
			end
		end
	end
	local lit = 0
	for _, part in partsNear(center, radius * 0.7, root) do
		if part:IsA("BasePart") and not part.Anchored and part.AssemblyMass < 50 and not part:IsGrounded() then
			local away = part.Position - center
			away = if away.Magnitude > 0.1 then away.Unit else Vector3.yAxis
			part.AssemblyLinearVelocity += (away + Vector3.new(0, 0.8, 0)).Unit * 70
		end
		if lit < igniteCap and part:HasTag(Names.Tag.Flammable) then
			ignite(part, culprit)
			lit += 1
		end
	end
	if culprit then
		Popup.show(center, `KABOOM! Courtesy of {culprit.DisplayName}`, "blame", culprit)
	end
	return true
end

---------------------------------------------------------------------------------------------- fire tornado

local function buildTornado(parent: Instance, pos: Vector3): (Model, BasePart)
	local m = Instance.new("Model")
	m.Name = "FireTornado"
	local H = HazardConfig.TornadoHeight
	local R = HazardConfig.TornadoRadius
	local core = Instance.new("Part")
	core.Name = "Core"
	core.Shape = Enum.PartType.Cylinder
	core.Size = Vector3.new(H, R * 0.9, R * 0.9)
	core.CFrame = CFrame.new(pos + Vector3.new(0, H / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	core.Color = Color3.fromRGB(128, 67, 42)
	core.Material = Enum.Material.SmoothPlastic
	core.Transparency = 0.55
	core.Anchored = true
	core.CanCollide = false
	core.CanQuery = false
	core.CanTouch = false
	core.Parent = m
	-- rings of flame that widen with height (the client spins the whole model's look via Hazard/Fx)
	for i = 0, 5 do
		local y = 4 + i * (H - 8) / 5
		local r = R * (0.35 + 0.65 * i / 5)
		local ring = Instance.new("Part")
		ring.Name = `Ring{i}`
		ring.Shape = Enum.PartType.Cylinder
		ring.Size = Vector3.new(1.2, r * 2, r * 2)
		ring.CFrame = CFrame.new(pos + Vector3.new(0, y, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		ring.Color = if i % 2 == 0 then ORANGE else EMBER
		ring.Material = Enum.Material.Neon
		ring.Transparency = 0.45
		ring.Anchored = true
		ring.CanCollide = false
		ring.CanQuery = false
		ring.CanTouch = false
		ring.Parent = m
		local f = Instance.new("Fire")
		f.Size = math.clamp(r, 5, 25)
		f.Heat = 25
		f.Color = ORANGE
		f.SecondaryColor = EMBER
		f.Parent = ring
	end
	local smoke = Instance.new("Smoke")
	smoke.Color = SMOKE
	smoke.Opacity = 0.25
	smoke.RiseVelocity = 20
	smoke.Size = 20
	smoke.Parent = core
	local light = Instance.new("PointLight")
	light.Color = ORANGE
	light.Range = 60
	light.Brightness = 3
	light.Parent = core
	m.PrimaryPart = core
	m.Parent = parent
	return m, core
end

local function fieldCentre(root: Instance): Vector3
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "TornadoField" then
			return d.Position
		end
	end
	local src = sources(root, "fire_tornado")[1]
	if src then
		return src.Position
	end
	local cf = bounds(root)
	return cf.Position
end

local function fireTornado(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local centre = if typeof(params.position) == "Vector3" then params.position :: Vector3 else fieldCentre(root)
	local seconds = tonumber(params.seconds) or HazardConfig.TornadoSeconds
	local x, z = centre.X, centre.Z
	local m, core = buildTornado(root, Vector3.new(x, groundY(centre, {}), z))
	local whoosh = sound(core, HazardConfig.TornadoSoundId, 1, true)
	local heading = math.random() * math.pi * 2
	local spin = 0
	local flungAt: { [Player]: number } = {}
	local running = true
	local t0 = os.clock()
	local lastIgnite = 0
	local rng = Random.new()
	count("tornadoes")
	fx("fire_tornado", centre, { model = m, seconds = seconds })
	Net.notify("all", "FIRE TORNADO!!", "bad")

	local h: Handle
	local conn: RBXScriptConnection
	local function stop()
		if not running then
			return
		end
		running = false
		conn:Disconnect()
		if whoosh then
			whoosh:Stop()
		end
		-- fizzle: shrink then vanish
		task.spawn(function()
			for i = 1, 10 do
				if not m.Parent then
					break
				end
				m:ScaleTo(math.max(0.05, 1 - i / 10))
				task.wait(0.05)
			end
			m:Destroy()
		end)
	end
	h = { stop = stop }
	setActive(instanceId, "fire_tornado", h)

	conn = RunService.Heartbeat:Connect(function(dt: number)
		if not m.Parent or not root.Parent then
			stop()
			return
		end
		local now = os.clock()
		if now - t0 > seconds then
			stop()
			return
		end
		local here = Vector3.new(x, 0, z)
		local players = playersIn(instanceId, root)
		local tx: number?, tz: number? = nil, nil
		local best = math.huge
		for _, p in players do
			local hrp = rootPart(p)
			if hrp then
				local d = (Vector3.new(hrp.Position.X, 0, hrp.Position.Z) - here).Magnitude
				if d < best and d < 150 then
					best = d
					tx, tz = hrp.Position.X, hrp.Position.Z
				end
			end
		end
		x, z, heading = HazardMath.tornadoStep(x, z, heading, tx, tz, HazardConfig.TornadoBias * dt * 3, HazardConfig.TornadoSpeed, dt, function()
			return rng:NextNumber()
		end, centre.X, centre.Z, HazardConfig.TornadoLeash)
		spin += dt * 3
		local gy = groundY(Vector3.new(x, centre.Y, z), { m })
		m:PivotTo(CFrame.new(x, gy + HazardConfig.TornadoHeight / 2, z) * CFrame.Angles(0, spin, 0) * CFrame.Angles(0, 0, math.pi / 2))
		local base = Vector3.new(x, gy, z)
		local R = HazardConfig.TornadoRadius

		-- players: caught inside = flung, set alight (heat), blamed on the weather
		for _, p in players do
			local hrp = rootPart(p)
			local char = p.Character
			if not hrp or not char then
				continue
			end
			local flat = Vector3.new(hrp.Position.X - x, 0, hrp.Position.Z - z)
			if flat.Magnitude < R and hrp.Position.Y - gy < HazardConfig.TornadoHeight and now - (flungAt[p] or 0) > 3 then
				flungAt[p] = now
				local out = if flat.Magnitude > 0.1 then flat.Unit else Vector3.xAxis
				local tangent = Vector3.new(-out.Z, 0, out.X)
				local v = (out * 0.6 + tangent * 0.8 + Vector3.new(0, 1.3, 0)).Unit * HazardConfig.TornadoFlingSpeed
				ragdoll(char, HazardConfig.TornadoRagdollSeconds, v)
				hurt(p, HazardConfig.TornadoHeat, "fire_tornado")
				count("tornado_flings")
				HazardService.Flung:Fire(p, "fire_tornado")
				Popup.show(p, "YEETED by the fire tornado!", "blame", p)
			end
		end
		-- loose parts + NPCs: sucked in and spun
		for _, part in partsNear(base + Vector3.new(0, 6, 0), HazardConfig.TornadoSuckRadius, nil) do
			if part.Anchored or part:IsGrounded() or part.AssemblyMass > 40 then
				continue
			end
			local char = part:FindFirstAncestorWhichIsA("Model")
			if char and Players:GetPlayerFromCharacter(char) then
				continue -- players are handled above (their client owns them)
			end
			local rel = Vector3.new(part.Position.X - x, 0, part.Position.Z - z)
			local d = rel.Magnitude
			if d < 0.5 then
				continue
			end
			local inward = -rel.Unit
			local tangent = Vector3.new(-inward.Z, 0, inward.X)
			local lift = if d < R then 30 else 8
			local want = inward * 18 + tangent * 26 + Vector3.new(0, lift, 0)
			part.AssemblyLinearVelocity = part.AssemblyLinearVelocity:Lerp(want, math.min(1, dt * 3))
		end
		-- ignite what it crosses
		if now - lastIgnite > HazardConfig.TornadoIgniteEvery then
			lastIgnite = now
			local lit = 0
			for _, part in partsNear(base + Vector3.new(0, 4, 0), R, root) do
				if lit >= 3 then
					break
				end
				if part:HasTag(Names.Tag.Flammable) and not part:HasTag(Names.Tag.Burning) then
					ignite(part, nil)
					lit += 1
				end
			end
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------- tidal wave

local function waveVolume(root: Instance): (CFrame, Vector3)
	for _, d in root:GetDescendants() do
		if d:IsA("BasePart") and d.Name == "WaveVolume" then
			return d.CFrame, d.Size
		end
	end
	return bounds(root)
end

local function buildWave(parent: Instance, width: number, height: number): Model
	local m = Instance.new("Model")
	m.Name = "TidalWave"
	local function part(name: string, size: Vector3, offset: CFrame, color: Color3, kind: string?): BasePart
		local p: BasePart
		if kind == "wedge" then
			p = Instance.new("WedgePart")
		else
			local q = Instance.new("Part")
			if kind == "ball" then
				q.Shape = Enum.PartType.Ball
			end
			p = q
		end
		p.Name = name
		p.Size = size
		p.CFrame = offset
		p.Color = color
		p.Material = if kind == "ball" then Enum.Material.SmoothPlastic else Enum.Material.Glass
		p.Transparency = if kind == "ball" then 0.1 else 0.25
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Parent = m
		return p
	end
	-- local space: wave travels toward -Z (its LookVector). Back slab + front ramp + foam crest.
	local base = part("Body", Vector3.new(width, height * 0.7, 26), CFrame.new(0, height * 0.35, 13), WAVE_DEEP)
	part("Front", Vector3.new(width, height, 16), CFrame.new(0, height / 2, -8) * CFrame.Angles(0, math.pi, 0), WAVE_MID, "wedge")
	part("Curl", Vector3.new(width, height * 0.3, 10), CFrame.new(0, height * 0.85, 2), WAVE_MID)
	for i = 0, math.floor(width / 10) do
		local fx0 = -width / 2 + i * 10
		part(`Foam{i}`, Vector3.new(9, 9, 9), CFrame.new(fx0, height + 1, 0), FOAM, "ball")
	end
	m.PrimaryPart = base
	local p = Instance.new("ParticleEmitter")
	p.Color = ColorSequence.new(FOAM)
	p.Size = NumberSequence.new(3, 8)
	p.Transparency = NumberSequence.new(0.2, 1)
	p.Speed = NumberRange.new(10, 20)
	p.Lifetime = NumberRange.new(0.6, 1.2)
	p.Rate = 120
	p.EmissionDirection = Enum.NormalId.Top
	p.SpreadAngle = Vector2.new(30, 30)
	p.Parent = base
	m.Parent = parent
	return m
end

local function tidalWave(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local vcf, vsize = waveVolume(root)
	local dir: Vector3
	if typeof(params.direction) == "Vector3" and (params.direction :: Vector3).Magnitude > 0.1 then
		local d = params.direction :: Vector3
		dir = Vector3.new(d.X, 0, d.Z).Unit
	else
		local lv = vcf.LookVector
		dir = Vector3.new(lv.X, 0, lv.Z)
		dir = if dir.Magnitude > 0.1 then dir.Unit else Vector3.new(0, 0, -1)
	end
	-- path length/width along dir in the volume's frame
	local localDir = vcf:VectorToObjectSpace(dir)
	local length = math.abs(localDir.X) * vsize.X + math.abs(localDir.Z) * vsize.Z
	local width = math.abs(localDir.Z) * vsize.X + math.abs(localDir.X) * vsize.Z
	length = math.max(length, 60)
	width = math.max(width, 60)
	local seconds = tonumber(params.seconds) or HazardConfig.WaveSeconds
	local height = HazardConfig.WaveHeight
	local floorY = vcf.Position.Y - vsize.Y / 2
	local start = Vector3.new(vcf.Position.X, floorY, vcf.Position.Z) - dir * (length / 2)
	local right = Vector3.new(-dir.Z, 0, dir.X)
	local wave = buildWave(root, width + 20, height)
	local function place(front: number)
		local p = start + dir * front
		-- pivot = the Body part, which sits height*0.35 up and 13 studs behind the leading face
		wave:PivotTo(CFrame.lookAt(p, p + dir) * CFrame.new(0, height * 0.35, 13))
	end
	place(0)
	local culprit: Player? = params.culprit
	-- dam blast first: boom at the start of the path (no player damage there, it is the dam face)
	fx("explosion", start + Vector3.new(0, height * 0.5, 0), { radius = 40, big = true })
	debrisBurst(start + Vector3.new(0, height * 0.5, 0), 16, Color3.fromRGB(150, 150, 150))
	fx("tidal_wave", start, { model = wave, seconds = seconds, direction = dir, length = length })
	local roar: Sound? = if wave.PrimaryPart then sound(wave.PrimaryPart, HazardConfig.WaveSoundId, 2, true) else nil
	count("tidal_waves")
	Net.notify("all", if culprit then `{culprit.DisplayName} blew the dam! WAVE INCOMING!` else "WAVE INCOMING!", "bad")

	local hit: { [Instance]: boolean } = {}
	local doused: { [BasePart]: boolean } = {}
	local running = true
	local t0 = os.clock()
	local conn: RBXScriptConnection
	local function finish()
		if not running then
			return
		end
		running = false
		conn:Disconnect()
		if roar then
			roar:Stop()
		end
		-- every fire left in the instance goes out (the wave is the finale's "put out the city")
		for _, part in CollectionService:GetTagged(Names.Tag.Burning) do
			if part:IsA("BasePart") and part:IsDescendantOf(root) and not doused[part] then
				douse(part)
			end
		end
		local Fire = services.FireService
		if Fire and type(Fire.ExtinguishAll) == "function" then
			local Mission = services.MissionService
			local runs = if Mission and type(Mission.GetMissions) == "function" then Mission:GetMissions() else {}
			if #runs <= 1 then
				pcall(Fire.ExtinguishAll, Fire) -- only safe when no other squad is mid-mission
			end
		end
		-- leave the town flooded (shallow terrain water) and let the wall sink away
		local depth = HazardConfig.WaveFloodDepth
		if depth > 0 then
			local cf = CFrame.new(vcf.Position.X, floorY + depth / 2, vcf.Position.Z) * (vcf - vcf.Position)
			local size = Vector3.new(vsize.X, depth, vsize.Z)
			pcall(function()
				workspace.Terrain:FillBlock(cf, size, Enum.Material.Water)
			end)
			floodBlocks[instanceId] = { cf, size }
		end
		task.spawn(function()
			for i = 1, 20 do
				if not wave.Parent then
					break
				end
				wave:PivotTo(wave:GetPivot() * CFrame.new(0, -height / 20, 0))
				task.wait(0.05)
			end
			wave:Destroy()
		end)
	end
	setActive(instanceId, "tidal_wave", { stop = finish })

	conn = RunService.Heartbeat:Connect(function()
		if not root.Parent then
			finish()
			return
		end
		local t = os.clock() - t0
		local front = HazardMath.waveFront(t, length / seconds, length)
		place(front)
		local thick = HazardConfig.WaveThickness
		-- players
		for _, p in playersIn(instanceId, root) do
			local hrp = rootPart(p)
			local char = p.Character
			if not hrp or not char or hit[p] then
				continue
			end
			local rel = hrp.Position - start
			local along = rel:Dot(dir)
			if math.abs(rel:Dot(right)) <= width / 2 + 10 and HazardMath.waveHit(along, front, thick) then
				hit[p] = true
				ragdoll(char, HazardConfig.WaveRagdollSeconds, dir * HazardConfig.WaveKnockback + Vector3.new(0, 35, 0))
				HazardService.Flung:Fire(p, "tidal_wave")
				local Heat = services.HeatService
				if Heat and type(Heat.Cool) == "function" then
					pcall(Heat.Cool, Heat, p, 30, nil) -- a cold shower
				end
			end
		end
		-- NPCs ride the wave too
		for _, npc in CollectionService:GetTagged(Names.Tag.Rescuable) do
			if hit[npc] or not npc:IsA("Model") or not npc:IsDescendantOf(root) then
				continue
			end
			local hrp = npc:FindFirstChild("HumanoidRootPart") :: BasePart?
			if hrp and HazardMath.waveHit((hrp.Position - start):Dot(dir), front, thick) then
				hit[npc] = true
				ragdoll(npc, 3, dir * 50 + Vector3.new(0, 25, 0))
			end
		end
		-- fires behind the front go out
		for _, part in CollectionService:GetTagged(Names.Tag.Burning) do
			if part:IsA("BasePart") and not doused[part] and part:IsDescendantOf(root) then
				local along = (part.Position - start):Dot(dir)
				if along <= front then
					doused[part] = true
					douse(part)
				end
			end
		end
		if front >= length then
			finish()
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------- backdraft

local function backdraft(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local door = params.door
	if typeof(door) ~= "Instance" or not (door :: Instance):IsA("BasePart") then
		return false
	end
	local d = door :: BasePart
	local culprit: Player? = params.culprit
	-- the fireball blows out of the room: away from the burning stuff behind the door
	local sum, n = Vector3.zero, 0
	for _, part in partsNear(d.Position, 16, root) do
		if part:HasTag(Names.Tag.Burning) then
			sum += part.Position
			n += 1
		end
	end
	local out: Vector3
	if n > 0 then
		local v = d.Position - sum / n
		out = Vector3.new(v.X, 0, v.Z)
	else
		out = d.CFrame.LookVector
	end
	out = if out.Magnitude > 0.1 then out.Unit else Vector3.new(0, 0, -1)
	local origin = d.Position
	local cosHalf = math.cos(math.rad(HazardConfig.BackdraftHalfAngle))
	-- fireball: neon balls racing out of the doorway
	for i = 1, 6 do
		local b = Instance.new("Part")
		b.Shape = Enum.PartType.Ball
		b.Size = Vector3.one * (4 + i)
		b.Color = if i % 2 == 0 then ORANGE else EMBER
		b.Material = Enum.Material.Neon
		b.Transparency = 0.2
		b.Anchored = true
		b.CanCollide = false
		b.CanQuery = false
		b.CanTouch = false
		b.CFrame = CFrame.new(origin)
		b.Parent = workspace
		local target = origin + out * (HazardConfig.BackdraftRange * (0.4 + i * 0.1)) + Vector3.new(0, i * 0.8, 0)
		local tween = game:GetService("TweenService"):Create(b, TweenInfo.new(0.35 + i * 0.05, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			CFrame = CFrame.new(target),
			Transparency = 1,
			Size = b.Size * 2.2,
		})
		tween:Play()
		Debris:AddItem(b, 1)
	end
	fx("backdraft", origin, { direction = out })
	count("backdrafts")
	for _, p in playersIn(instanceId, root) do
		local hrp = rootPart(p)
		local char = p.Character
		if hrp and char then
			local rel = hrp.Position - origin
			if HazardMath.inCone(rel.X, rel.Y, rel.Z, out.X, out.Y, out.Z, HazardConfig.BackdraftRange, cosHalf) then
				hurt(p, HazardConfig.BackdraftDamage, "backdraft")
				ragdoll(char, 1.5, out * 55 + Vector3.new(0, 30, 0))
				HazardService.Flung:Fire(p, "backdraft")
			end
		end
	end
	Popup.show(d, `BACKDRAFT! {displayName(culprit)} opened the wrong door`, "blame", culprit)
	HazardService.Caused:Fire(culprit, "backdraft")
	return true
end

---------------------------------------------------------------------------------------------- ceiling collapse

local function isCeiling(part: BasePart): boolean
	local n = string.lower(part.Name)
	return string.find(n, "ceiling", 1, true) ~= nil or string.find(n, "roof", 1, true) ~= nil
end

local function ceilingCollapse(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local parts: { BasePart } = {}
	if type(params.parts) == "table" then
		for _, p in params.parts do
			if typeof(p) == "Instance" and p:IsA("BasePart") then
				table.insert(parts, p)
			end
		end
	elseif typeof(params.position) == "Vector3" then
		for _, p in partsNear(params.position :: Vector3, tonumber(params.radius) or 14, root) do
			if p.Anchored and isCeiling(p) then
				table.insert(parts, p)
			end
		end
	end
	if #parts == 0 then
		return false
	end
	local sum = Vector3.zero
	for _, p in parts do
		sum += p.Position
	end
	local centre = sum / #parts
	fx("ceiling_collapse", centre, { warn = HazardConfig.CollapseWarnSeconds })
	local creak = Instance.new("Part")
	creak.Anchored = true
	creak.CanCollide = false
	creak.CanQuery = false
	creak.Transparency = 1
	creak.Position = centre
	creak.Parent = workspace
	sound(creak, HazardConfig.CreakSoundId, 1.2)
	Debris:AddItem(creak, 8)
	-- dust while it shakes
	local dust = Instance.new("ParticleEmitter")
	dust.Color = ColorSequence.new(Color3.fromRGB(200, 190, 175))
	dust.Size = NumberSequence.new(1, 4)
	dust.Transparency = NumberSequence.new(0.3, 1)
	dust.Rate = 60
	dust.Lifetime = NumberRange.new(1, 2)
	dust.Speed = NumberRange.new(2, 6)
	dust.EmissionDirection = Enum.NormalId.Bottom
	dust.Parent = creak
	Net.notify("all", "*CREAAAK* ...the ceiling!", "bad")
	task.spawn(function()
		local base: { [BasePart]: CFrame } = {}
		for _, p in parts do
			base[p] = p.CFrame
		end
		local t0 = os.clock()
		while os.clock() - t0 < HazardConfig.CollapseWarnSeconds do
			for p, cf in base do
				if p.Parent then
					p.CFrame = cf * CFrame.new(math.random() * 0.2 - 0.1, 0, math.random() * 0.2 - 0.1)
				end
			end
			task.wait(0.05)
		end
		dust.Enabled = false
		for p, cf in base do
			if p.Parent then
				p.CFrame = cf
				-- Lib/Physics/Rubble: zero velocity, no rubble-on-rubble overlap explosions, clamped and
				-- leashed so the ceiling falls DOWN instead of launching off the plot; anchors when settled
				Rubble.release(p)
			end
		end
		count("collapses")
		-- who's underneath?
		for _, pl in playersIn(instanceId, root) do
			local hrp = rootPart(pl)
			local char = pl.Character
			if hrp and char then
				for _, p in parts do
					local rel = hrp.Position - p.Position
					if rel.Y < 0 and math.abs(rel.X) < p.Size.X / 2 + 3 and math.abs(rel.Z) < p.Size.Z / 2 + 3 then
						hurt(pl, HazardConfig.CollapseDamage, "ceiling_collapse")
						ragdoll(char, 2, Vector3.new(math.random(-10, 10), -10, math.random(-10, 10)))
						HazardService.Flung:Fire(pl, "ceiling_collapse")
						break
					end
				end
			end
		end
	end)
	return true
end

---------------------------------------------------------------------------------------------- cigarette

local function cigarette(instanceId: string, root: Instance, params: { [string]: any }): boolean
	local npc: Model? = nil
	if typeof(params.npc) == "Instance" and (params.npc :: Instance):IsA("Model") then
		npc = params.npc :: Model
	else
		for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
			if m:IsA("Model") and m:IsDescendantOf(root) and m:GetAttribute(Names.Attr.Kind) == "Civilian" then
				npc = m
				if string.find(string.lower(m.Name), "farmer", 1, true) then
					break
				end
			end
		end
	end
	if not npc then
		return false
	end
	local who = npc :: Model
	local running = true
	setActive(instanceId, "cigarette", {
		stop = function()
			running = false
		end,
	})
	task.spawn(function()
		while running and who.Parent and root.Parent do
			task.wait(HazardConfig.CigaretteRelightSeconds)
			if not running or not who.Parent then
				break
			end
			local st = who:GetAttribute(Names.Attr.RescueState)
			if st == "Carried" or st == "Rescued" or who:GetAttribute("Slapped") == true then
				break
			end
			local pivot = who:GetPivot().Position
			for _, part in partsNear(pivot, HazardConfig.CigaretteRadius, root) do
				if part:HasTag(Names.Tag.Flammable) and not part:HasTag(Names.Tag.Burning) then
					ignite(part, nil)
					fx("cigarette", pivot, {})
					break
				end
			end
		end
		running = false
	end)
	return true
end

---------------------------------------------------------------------------------------------- arming (catalog hook)

local HANDLERS: { [string]: (string, Instance, { [string]: any }) -> boolean } = {
	electrocution = electrocution,
	explosion = explosion,
	fire_tornado = fireTornado,
	tidal_wave = tidalWave,
	cigarette = cigarette,
	backdraft = backdraft,
	ceiling_collapse = ceilingCollapse,
}

local function prompt(part: BasePart, action: string, hold: number, onTrigger: (Player) -> ()): ProximityPrompt
	local p = Instance.new("ProximityPrompt")
	p.Name = "HazardPrompt"
	p.ActionText = action
	p.ObjectText = ""
	p.HoldDuration = hold
	p.MaxActivationDistance = 10
	p.RequiresLineOfSight = false
	p.Triggered:Connect(onTrigger)
	p.Parent = part
	return p
end

local function getArmed(instanceId: string): Armed
	local a = armed[instanceId]
	if not a then
		a = { conns = {}, threads = {}, prompts = {}, collapsed = {} }
		armed[instanceId] = a
	end
	return a
end

local function armFuseBoxes(instanceId: string, root: Instance, a: Armed)
	local boxes = tagged(Names.Tag.FuseBox, root)
	for _, s in sources(root, "electrocution") do
		if not table.find(boxes, s) then
			table.insert(boxes, s)
		end
	end
	for _, box in boxes do
		if box:FindFirstChild("HazardPrompt") then
			continue
		end
		local p = prompt(box, if powerOf(box) then "Power OFF" else "Power ON", 0.3, function(player: Player)
			if powerOf(box) then
				setPower(box, false)
				count("power_cut")
				Net.notify(player, "Power off. The puddles are safe... for now.", "good")
			else
				lastFlipper[box] = player
				HazardService:Trigger(instanceId, "electrocution", { fuseBox = box, culprit = player })
			end
		end)
		p.ObjectText = "Fuse Box"
		table.insert(a.prompts, p)
		table.insert(
			a.conns,
			box:GetAttributeChangedSignal(Names.Attr.Power):Connect(function()
				p.ActionText = if powerOf(box) then "Power OFF" else "Power ON"
			end)
		)
		-- builders start fuse boxes powered: puddles near them are already live
		if powerOf(box) and not (active[instanceId] and active[instanceId].electrocution) then
			HazardService:Trigger(instanceId, "electrocution", { fuseBox = box })
		end
	end
end

local function armGasTanks(instanceId: string, root: Instance, a: Armed)
	local tanks = sources(root, "explosion")
	if #tanks == 0 then
		return
	end
	local heatAt: { [BasePart]: number } = {}
	table.insert(
		a.threads,
		task.spawn(function()
			while root.Parent do
				task.wait(0.5)
				for _, tank in tanks do
					if not tank.Parent or tank:GetAttribute("Exploded") then
						continue
					end
					local hot = tank:HasTag(Names.Tag.Burning)
					if not hot then
						for _, part in partsNear(tank.Position, 10, root) do
							if part:HasTag(Names.Tag.Burning) then
								hot = true
								break
							end
						end
					end
					heatAt[tank] = if hot then (heatAt[tank] or 0) + 0.5 else 0
					if heatAt[tank] >= HazardConfig.GasTankFuseSeconds then
						tank:SetAttribute("Exploded", true)
						local pos = tank.Position
						local holder = tank.Parent
						if holder and holder:IsA("Model") and holder ~= root then
							holder:Destroy()
						else
							tank:Destroy()
						end
						HazardService:Trigger(instanceId, "explosion", { position = pos })
					end
				end
			end
		end)
	)
end

local function armDetonator(instanceId: string, root: Instance, a: Armed)
	for _, det in sources(root, "tidal_wave") do
		if det:FindFirstChildWhichIsA("ProximityPrompt") then
			continue -- FinaleService owns this one
		end
		local p = prompt(det, "DETONATE", 1, function(player: Player)
			local Finale = services.FinaleService
			if Finale and type(Finale.Detonate) == "function" then
				local ok, fired = pcall(Finale.Detonate, Finale, instanceId, player)
				if ok and fired then
					return -- FinaleService triggers the wave
				end
			end
			if HazardConfig.DetonatorNeedsCharges then
				Net.notify(player, "Plant every charge first!", "bad")
				return
			end
			if not (active[instanceId] and active[instanceId].tidal_wave) then
				HazardService:Trigger(instanceId, "tidal_wave", { culprit = player })
			end
		end)
		p.ObjectText = "Dam Detonator"
		table.insert(a.prompts, p)
	end
end

local function armTornado(instanceId: string, root: Instance, a: Armed)
	table.insert(
		a.threads,
		task.delay(HazardConfig.TornadoDelay, function()
			if root.Parent and armed[instanceId] == a then
				HazardService:Trigger(instanceId, "fire_tornado", {})
			end
		end)
	)
end

-- Generic watchers on every armed instance: backdraft on door break, ceiling collapse when charred.
local function armGeneric(instanceId: string, root: Instance, a: Armed)
	local Tool = services.ToolService
	if Tool and Tool.DoorBroken then
		table.insert(
			a.conns,
			Tool.DoorBroken:Connect(function(player: Player, door: BasePart)
				if not door:IsDescendantOf(root) then
					return
				end
				local n = 0
				for _, part in partsNear(door.Position, 14, root) do
					if part:HasTag(Names.Tag.Burning) then
						n += 1
					end
				end
				if n >= HazardConfig.BackdraftMinBurning then
					HazardService:Trigger(instanceId, "backdraft" :: any, { door = door, culprit = player })
				end
			end)
		)
	end
	table.insert(
		a.threads,
		task.spawn(function()
			while root.Parent and armed[instanceId] == a do
				task.wait(2)
				local groups: { [string]: { BasePart } } = {}
				for _, d in root:GetDescendants() do
					if d:IsA("BasePart") and d.Anchored and isCeiling(d) then
						local b = d:GetAttribute(Names.Attr.BuildingId)
						if b ~= nil then
							local key = tostring(b)
							local g = groups[key]
							if not g then
								g = {}
								groups[key] = g
							end
							table.insert(g, d)
						end
					end
				end
				for key, g in groups do
					if a.collapsed[key] then
						continue
					end
					local charred = 0
					for _, p in g do
						if p:GetAttribute(Names.Attr.Charred) then
							charred += 1
						end
					end
					if HazardMath.collapseShouldFall(charred, #g, HazardConfig.CollapseThreshold) then
						a.collapsed[key] = true
						HazardService:Trigger(instanceId, "ceiling_collapse" :: any, { parts = g })
					end
				end
			end
		end)
	)
end

local function catalogDef(missionId: string): any
	local ok, catalog = pcall(require, ReplicatedStorage:WaitForChild("Config"):WaitForChild("MissionCatalog") :: ModuleScript)
	if not ok or type(catalog) ~= "table" then
		return nil
	end
	for _, def in catalog :: { any } do
		if type(def) == "table" and def.id == missionId then
			return def
		end
	end
	return nil
end

-- v3 twist context (Lib/Hazard/Twists): cleanup goes through the Armed record, so Clear undoes it.
local function twistCtx(instanceId: string, root: Instance, a: Armed): any
	return {
		instanceId = instanceId,
		root = root,
		services = services,
		conn = function(c: RBXScriptConnection)
			table.insert(a.conns, c)
		end,
		thread = function(t: thread)
			table.insert(a.threads, t)
		end,
		prompt = function(p: Instance)
			table.insert(a.prompts, p)
		end,
		alive = function(): boolean
			return armed[instanceId] == a and root.Parent ~= nil
		end,
		explode = function(pos: Vector3, radius: number?, culprit: Player?, extra: { [string]: any }?)
			local params: { [string]: any } = { position = pos, radius = radius, culprit = culprit }
			for k, v in extra or {} do
				params[k] = v
			end
			HazardService:Trigger(instanceId, "explosion", params)
		end,
		heat = function(p: Player, amount: number, source: string)
			hurt(p, amount, source)
		end,
		players = function(): { Player }
			return playersIn(instanceId, root)
		end,
	}
end

function HazardService:_arm(instanceId: string, missionId: string?): boolean
	-- the instance may still be building: give it a moment
	local root: Instance? = nil
	for _ = 1, 40 do
		root = rootOf(instanceId)
		if root then
			break
		end
		task.wait(0.25)
	end
	if not root then
		return false
	end
	HazardService:Clear(instanceId)
	local a = getArmed(instanceId)
	local def = if missionId then catalogDef(missionId) else nil
	local hazards: { string } = if def and type(def.hazards) == "table" then def.hazards else {}
	for _, h in hazards do
		if h == "electrocution" then
			armFuseBoxes(instanceId, root, a)
		elseif h == "explosion" then
			armGasTanks(instanceId, root, a)
		elseif h == "fire_tornado" then
			armTornado(instanceId, root, a)
		elseif h == "tidal_wave" then
			armDetonator(instanceId, root, a)
		elseif table.find(Twists.Kinds, h) then
			if Twists.arm(h, twistCtx(instanceId, root, a)) then
				count("twists_armed")
			end
		elseif h == "cigarette" then
			table.insert(
				a.threads,
				task.delay(5, function()
					if armed[instanceId] == a then
						HazardService:Trigger(instanceId, "cigarette", {})
					end
				end)
			)
		end
	end
	-- props a builder placed are live even if the catalog forgot them
	if not table.find(hazards, "electrocution") and #tagged(Names.Tag.FuseBox, root) > 0 then
		armFuseBoxes(instanceId, root, a)
	end
	if not table.find(hazards, "explosion") then
		armGasTanks(instanceId, root, a)
	end
	if not table.find(hazards, "tidal_wave") then
		armDetonator(instanceId, root, a)
	end
	armGeneric(instanceId, root, a)
	return true
end

---------------------------------------------------------------------------------------------- lifecycle

function HazardService:Init(all: { [string]: any })
	services = all
end

function HazardService:Start()
	zapRemote = Net.event("Hazard", "Zapped")
	fxRemote = Net.event("Hazard", "Fx")
	local Mission = services.MissionService
	if Mission then
		if Mission.MissionStarted then
			Mission.MissionStarted:Connect(function(instanceId: string, missionId: string)
				task.spawn(HazardService._arm, HazardService, instanceId, missionId)
			end)
		end
		if Mission.MissionEnded then
			Mission.MissionEnded:Connect(function(instanceId: string, _results: any)
				HazardService:Clear(instanceId)
			end)
		end
	end
	-- the Finale lane's detonator calls Trigger(tidal_wave) directly; nothing to wire here
	Twists.start() -- v3 twists: a second Tool/Spray listener (hose vs extinguisher on twist targets)
	Players.PlayerRemoving:Connect(function(p: Player)
		zapCooldown[p] = nil
	end)
end

function HazardService:Trigger(instanceId: string, hazardId: Types.HazardId, params: { [string]: any }?): boolean
	local handler = HANDLERS[hazardId :: string]
	local root = rootOf(instanceId)
	if not handler or not root then
		return false
	end
	local ok, result = pcall(handler, instanceId, root, params or {})
	if not ok then
		warn(`[HazardService] {hazardId} in {instanceId} failed: {result}`)
		return false
	end
	if result then
		count("hazards_triggered")
		HazardService.Triggered:Fire(instanceId, hazardId :: string)
	end
	return result == true
end

function HazardService:Clear(instanceId: string)
	local list = active[instanceId]
	active[instanceId] = nil
	if list then
		for _, h in list do
			pcall(h.stop)
		end
	end
	Twists.clear(instanceId)
	local a = armed[instanceId]
	armed[instanceId] = nil
	if a then
		for _, c in a.conns do
			c:Disconnect()
		end
		for _, th in a.threads do
			pcall(task.cancel, th)
		end
		for _, p in a.prompts do
			p:Destroy()
		end
	end
	local flood = floodBlocks[instanceId]
	floodBlocks[instanceId] = nil
	if flood then
		pcall(function()
			workspace.Terrain:FillBlock(flood[1] :: CFrame, flood[2] :: Vector3, Enum.Material.Air)
		end)
	end
end

function HazardService:GetActive(instanceId: string): { Types.HazardId }
	local out: { Types.HazardId } = {}
	for id in active[instanceId] or {} do
		table.insert(out, id :: any)
	end
	return out
end

function HazardService:_trigger(instanceId: string, hazardId: Types.HazardId): boolean
	local params: { [string]: any } = {}
	if hazardId == "explosion" then
		-- test hook: blow up next to the first player in the instance, else the instance centre
		local root = rootOf(instanceId)
		if root then
			local p = playersIn(instanceId, root)[1]
			local hrp = p and rootPart(p)
			params.position = if hrp then hrp.Position + Vector3.new(6, 0, 0) else bounds(root).Position
		end
	end
	return self:Trigger(instanceId, hazardId, params)
end

function HazardService:_twist(instanceId: string, kind: string): boolean
	local root = rootOf(instanceId)
	if not root then
		return false
	end
	return Twists.arm(kind, twistCtx(instanceId, root, getArmed(instanceId)))
end

function HazardService:_twistPrompt(instanceId: string, action: string, userId: number?): boolean
	local root = rootOf(instanceId)
	local player = if userId then Players:GetPlayerByUserId(userId) else Players:GetPlayers()[1]
	return root ~= nil and player ~= nil and Twists.testPrompt(root, action, player)
end

function HazardService:_twistSpray(instanceId: string, kind: string, userId: number?): number
	local player = if userId then Players:GetPlayerByUserId(userId) else Players:GetPlayers()[1]
	return if player then Twists.testSpray(instanceId, player, kind) else 0
end

function HazardService:_blowTanker(instanceId: string): boolean
	return Twists.blowTanker(instanceId)
end

function HazardService:_twists(instanceId: string): { any }
	local out = {}
	for _, t in Twists.targets(instanceId) do
		table.insert(out, { part = t.part:GetFullName(), fire = t.fire, hp = t.hp, out = t.out, water = t.water })
	end
	return out
end

function HazardService:_selftest(): (boolean, string)
	if not zapRemote or not fxRemote then
		return false, "remotes not declared"
	end
	for _, id in { "electrocution", "fire_tornado", "explosion", "tidal_wave", "cigarette", "backdraft", "ceiling_collapse" } do
		if not HANDLERS[id] then
			return false, `no handler for {id}`
		end
	end
	if HazardService:Trigger("__nowhere__", "explosion", { position = Vector3.zero }) then
		return false, "Trigger on a missing instance returned true"
	end
	if #Twists.Kinds ~= 4 then
		return false, "Lib/Hazard/Twists lost a twist"
	end
	return true, `7 hazards + {#Twists.Kinds} twists wired`
end

return HazardService
