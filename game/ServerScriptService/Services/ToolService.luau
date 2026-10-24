--!strict
-- ToolService [owner: G1]. Loadout (Hose, Axe, Extinguisher), backpack water tank, hose spray with
-- recoil, friendly fire, puddles (WetFloor), refills, doors that fly off their hinges, axe bonks.
--
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   ToolService:GiveLoadout(player: Player)              -- Hose + Axe + Extinguisher, full tank/foam
--   ToolService:Refill(player: Player, litres: number?)  -- nil = full (tank; foam too at a truck)
--   ToolService:ResetDoors(locationId: string)           -- un-break every door of a location/instance
--   ToolService:CreateTool(itemId: string, player: Player): Tool?  -- v2: a fresh "Hose" | "Axe" | "Extinguisher"
--     Tool for InventoryService to put in a hand (nil for other ids)
-- v2 (docs/game/08 "Inventory"): when InventoryService is running it owns where tools come from, so
--   GiveLoadout only resets the tank/foam attrs (no Backpack tools), and the Hydrant / TruckRefill
--   prompts are InventoryService's (nozzle off the reel, supply lines), not hooked here.
--   ToolService:HitDoor(player, door, hits?)             -- v2: HandsService axe-head impact (1..DoorHits)
--   ToolService:PushDoor(door): boolean                  -- v2: hand shove opens an unlocked closed door
--   ToolService:PryDoor(door): boolean                   -- gear: Halligan/Crowbar pop a locked door open
--     quietly (unlocked + opened, no planks; ResetDoors re-locks it)
-- Axe tiers (gear progression): CreateTool("Axe" | "FireAxe" | "GoldenAxe") always makes a Tool named
--   "Axe" (attr AxeTier = the item id) painted by ItemProps.paintAxe. Door damage (HitDoor, the door
--   prompt) is multiplied and the swing cooldown divided by the tier (Lib/Items/Progression).
-- Signals: DoorBroken(player, door: BasePart), WaterUsed(player, litres: number),
--          HoseHit(sprayer: Player, victim: Player)       -- once per pair per HoseHitCooldown
--          HoseRecoil(sprayer: Player, impulse: Vector3)  -- every hose spray event (-aim * HoseRecoil * pressure).
--            The sprayer's own client applies the recoil smoothly (ToolController); listeners must
--            NOT also call Ragdoll.knockback with it, or the recoil doubles.
-- Remotes: Tool/Spray  (C->S, aim: Vector3 unit, 12/s burst 4) -- hose or extinguisher, whichever is equipped
--          Tool/Pushed (S->C victim, velocity: Vector3, fromUserId: number, kind: "hose"|"foam"|"axe")
--            juice only (splash overlay, shake); the shove itself goes through Ragdoll.knockback
--          Tool/Fx     (S->C all, kind: string, position: Vector3, extra: number?) -- "crack", "chop",
--            "bonk", "sploosh", "whoosh" world pops + nearby camera shake
-- Writes: Player attrs Water, TankSize, Spraying, Foam, FoamSize, HoseRocket;
--         Door attrs Locked, Broken; puddle parts tagged WetFloor under workspace.Puddles
-- Reads: Player attrs Carrying (RescueService), Downed (SquadService), HosePressure (HoseLine);
--        character attr Ragdolled;
--        prompts under parts tagged Hydrant / TruckRefill / Door (one ProximityPrompt each, builders)
-- Calls (nil-guarded): FireService:ApplyWater, HeatService:Cool, MapService:GetLocation/GetInstance,
--        Lib/Tools/HoseLine (attach/detach/getPressure; optional, owned by another lane)
-- Counters: water_used, refills, doors_broken, hose_teammate_hits, hose_knockdowns, axe_swings,
--           axe_teammate_hits, puddles, foam_used, hose_rockets
-- Foam: at most one puff per 0.85 / SprayHz s per player (server-side, on top of the remote's rate limit).
-- Test hooks (DevHook only): _spray(player, aim), _swing(player), _doorPrompt(player, door), _selftest(),
--   _resetFoamLimit(player)

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Palette = require(Shared:WaitForChild("Palette") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local ToolConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("ToolConfig") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript)
local ToolMath = require(ReplicatedStorage:WaitForChild("ToolMath") :: ModuleScript)
local Progression = require(ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("Progression") :: ModuleScript) :: any
local AXE_TIERS = { Axe = true, FireAxe = true, GoldenAxe = true }
local AxeBuilder = require(script.Parent.Parent:WaitForChild("Lib"):WaitForChild("Tools"):WaitForChild("AxeBuilder") :: ModuleScript)

local ToolService = {}
ToolService.Priority = 50
ToolService.DoorBroken = Signal.new() :: Signal.Signal<Player, BasePart>
ToolService.WaterUsed = Signal.new() :: Signal.Signal<Player, number>
ToolService.HoseHit = Signal.new() :: Signal.Signal<Player, Player>
ToolService.HoseRecoil = Signal.new() :: Signal.Signal<Player, Vector3>

local ATTR_FOAM = "Foam"
local ATTR_FOAM_SIZE = "FoamSize"
local TOOL_NAMES = { "Hose", "Axe", "Extinguisher" }

type DoorState = {
	locked: boolean,
	transparency: number,
	canCollide: boolean,
	canQuery: boolean,
	actionText: string,
}

local services: { [string]: any } = {}
local lastSpray: { [Player]: number } = {}
local lastFoam: { [Player]: number } = {} -- foam is rate-limited per player, whatever the client sends
local lastSwing: { [Player]: number } = {}
local sprayCount: { [Player]: number } = {}
local rocketSince: { [Player]: number } = {}
local lastHit: { [string]: number } = {} -- "<sprayer>:<victim>" -> os.clock() of the last HoseHit
local lastPush: { [string]: number } = {} -- "<sprayer>:<victim>" -> os.clock() of the last shove
local soakSince: { [Player]: number } = {} -- victim -> when continuous soaking started
local soakLast: { [Player]: number } = {}
local doorHits: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local doorOriginal: { [BasePart]: DoorState } = setmetatable({}, { __mode = "k" }) :: any
local hooked: { [ProximityPrompt]: true } = {}
local Pushed: RemoteEvent? = nil
local Fx: RemoteEvent? = nil
local puddleFolder: Folder? = nil

local swing: (player: Player) -> () -- defined in the axe section (proximity swing; test hook _swing)

-- optional HoseLine (another lane) ------------------------------------------------------------
local hoseLineCache: any = nil
local function hoseLine(): any
	if hoseLineCache then
		return hoseLineCache
	end
	local lib = ServerScriptService:FindFirstChild("Lib")
	local tools = lib and lib:FindFirstChild("Tools")
	local mod = tools and tools:FindFirstChild("HoseLine")
	if mod and mod:IsA("ModuleScript") then
		local ok, res = pcall(require, mod)
		if ok and type(res) == "table" then
			hoseLineCache = res
		end
	end
	return hoseLineCache
end

local function hoseLineCall(fn: string, ...: any): any
	local hl = hoseLine()
	local f = hl and hl[fn]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, ...)
	return if ok then res else nil
end

local function call(serviceName: string, method: string, ...: any): any
	local svc = services[serviceName]
	local f = svc and svc[method]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, svc, ...)
	if not ok then
		warn(`[ToolService] {serviceName}:{method} failed: {res}`)
		return nil
	end
	return res
end

local function fx(kind: string, position: Vector3, extra: number?)
	if Fx then
		Fx:FireAllClients(kind, position, extra or 0)
	end
end

-- tools ------------------------------------------------------------------------------------
local function toolPart(name: string, size: Vector3, color: Color3, material: Enum.Material?): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CastShadow = false
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = a
end

local function makeHose(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Hose"
	tool.ToolTip = "Hold to spray (look down for a hose rocket)"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	-- handle runs along Z; the nozzle points down -Z (forward from the hand)
	local handle = toolPart("Handle", Vector3.new(0.6, 0.6, 2.4), Palette.HoseYellow)
	handle.Parent = tool
	local tip = toolPart("Tip", Vector3.new(0.75, 0.75, 0.6), Palette.BrassCoupling, Enum.Material.Metal)
	tip.CFrame = handle.CFrame * CFrame.new(0, 0, -1.5)
	tip.Parent = tool
	weld(handle, tip)
	local grip = toolPart("Grip", Vector3.new(0.35, 0.9, 0.35), Palette.TruckChrome, Enum.Material.Metal)
	grip.CFrame = handle.CFrame * CFrame.new(0, -0.6, 0.2)
	grip.Parent = tool
	weld(handle, grip)
	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, 0, -1.9)
	nozzle.Parent = handle
	tool.Grip = CFrame.new(0, -0.6, 0.2) -- fist on the pistol grip, nozzle forward above it
	return tool
end

local function makeExtinguisher(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Extinguisher"
	tool.ToolTip = "Hold to foam (refill at the truck)"
	tool.CanBeDropped = false
	tool.RequiresHandle = true
	local handle = toolPart("Handle", Vector3.new(0.9, 2, 0.9), Palette.TruckRed)
	handle.Shape = Enum.PartType.Block
	handle.Parent = tool
	local cap = toolPart("Cap", Vector3.new(0.6, 0.4, 0.6), Palette.TruckChrome, Enum.Material.Metal)
	cap.CFrame = handle.CFrame * CFrame.new(0, 1.2, 0)
	cap.Parent = tool
	weld(handle, cap)
	local horn = toolPart("Horn", Vector3.new(0.35, 0.35, 1.2), Color3.fromRGB(30, 30, 30))
	horn.CFrame = handle.CFrame * CFrame.new(0, 1.2, -0.8)
	horn.Parent = tool
	weld(handle, horn)
	local nozzle = Instance.new("Attachment")
	nozzle.Name = "Nozzle"
	nozzle.Position = Vector3.new(0, 1.2, -1.45)
	nozzle.Parent = handle
	tool.Grip = CFrame.new(0, 1.35, 0) -- carried by the top lever, the tank hangs below the fist
	return tool
end

-- The ONE physical axe (Lib/Tools/AxeBuilder): floppy metal head on a ball socket, swung by
-- ClientLib/AxeArm; door damage comes from the head's speed (HandsService Hands/AxeHit -> HitDoor).
local function makeAxe(_player: Player): Tool
	return AxeBuilder.make()
end

local function removeTools(player: Player)
	for _, holder in { player:FindFirstChildOfClass("Backpack"), player.Character } do
		if holder then
			for _, name in TOOL_NAMES do
				local t = holder:FindFirstChild(name)
				if t and t:IsA("Tool") then
					t:Destroy()
				end
			end
		end
	end
end

-- state helpers ----------------------------------------------------------------------------
local function blocked(player: Player): boolean
	local carrying = (player:GetAttribute(Names.Attr.Carrying) :: string?) or ""
	if carrying ~= "" or player:GetAttribute(Names.Attr.Downed) == true then
		return true
	end
	local char = player.Character
	return char ~= nil and Ragdoll.isRagdolled(char)
end

local function markSpraying(player: Player)
	local now = os.clock()
	lastSpray[player] = now
	player:SetAttribute(Names.Attr.Spraying, true)
	task.delay(ToolConfig.SprayingClearSeconds + 0.05, function()
		if lastSpray[player] == now and player.Parent then
			player:SetAttribute(Names.Attr.Spraying, false)
			rocketSince[player] = nil
		end
	end)
end

local function pressureOf(player: Player): number
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	-- HoseLine.getPressure is 1 with no line attached, lower while kinked; it scales the tank pressure.
	local line = hoseLineCall("getPressure", player)
	return ToolMath.pressure(water, size, if type(line) == "number" then line else nil)
end

local function charParts(): { Instance }
	local list: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(list, p.Character)
		end
	end
	return list
end

local function rayParams(exclude: { Instance }): RaycastParams
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	local list = table.clone(exclude)
	if puddleFolder then
		table.insert(list, puddleFolder)
	end
	rp.FilterDescendantsInstances = list
	rp.IgnoreWater = true
	return rp
end

-- Samples the stream's gravity arc and returns the first hit.
local function streamImpact(origin: Vector3, aim: Vector3, speed: number, exclude: { Instance }): RaycastResult?
	local rp = rayParams(exclude)
	local steps = 5
	local T = ToolConfig.StreamMaxTime
	local g = ToolConfig.StreamGravity
	local prev = origin
	for i = 1, steps do
		local t = T * i / steps
		local x, y, z = ToolMath.arcPoint(origin.X, origin.Y, origin.Z, aim.X * speed, aim.Y * speed, aim.Z * speed, g, t)
		local nextP = Vector3.new(x, y, z)
		local hit = workspace:Raycast(prev, nextP - prev, rp)
		if hit then
			return hit
		end
		prev = nextP
	end
	return nil
end

-- puddles (WetFloor) -----------------------------------------------------------------------
local function puddles(): Folder
	local f = puddleFolder
	if f and f.Parent then
		return f
	end
	local nf = Instance.new("Folder")
	nf.Name = "Puddles"
	nf.Parent = workspace
	puddleFolder = nf
	return nf
end

local function splashPuddle(pos: Vector3, litres: number)
	local folder = puddles()
	local best: BasePart? = nil
	local bestD = ToolConfig.PuddleMergeStuds
	for _, p in folder:GetChildren() do
		if p:IsA("BasePart") then
			local d = (Vector3.new(p.Position.X, pos.Y, p.Position.Z) - pos).Magnitude
			if d <= bestD + p.Size.Y / 2 and math.abs(p.Position.Y - pos.Y) < 2 then
				best, bestD = p, d
			end
		end
	end
	local now = os.clock()
	if best then
		local l = ((best:GetAttribute("Litres") :: number?) or 0) + litres
		best:SetAttribute("Litres", l)
		best:SetAttribute("Until", now + ToolConfig.PuddleSeconds)
		best.Transparency = 0.45 -- a fading puddle gets topped up
		local r = ToolMath.puddleRadius(l, ToolConfig.PuddleMinRadius, ToolConfig.PuddleMaxRadius)
		best.Size = Vector3.new(0.06, r * 2, r * 2)
		return
	end
	local kids = folder:GetChildren()
	if #kids >= ToolConfig.PuddleMax then
		-- recycle the oldest
		local oldest: Instance? = nil
		local oldestT = math.huge
		for _, k in kids do
			local u = (k:GetAttribute("Until") :: number?) or 0
			if u < oldestT then
				oldest, oldestT = k, u
			end
		end
		if oldest then
			oldest:Destroy()
		end
	end
	local p = Instance.new("Part")
	p.Name = "Puddle"
	p.Shape = Enum.PartType.Cylinder
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = true
	p.CastShadow = false
	p.Material = Enum.Material.Glass
	p.Color = Color3.fromHex("#7FC8D8")
	p.Transparency = 0.45
	p.Reflectance = 0.15
	local r = ToolMath.puddleRadius(litres, ToolConfig.PuddleMinRadius, ToolConfig.PuddleMaxRadius)
	p.Size = Vector3.new(0.06, r * 2, r * 2)
	p.CFrame = CFrame.new(pos + Vector3.new(0, 0.04, 0)) * CFrame.Angles(0, 0, math.rad(90))
	p:SetAttribute("Litres", litres)
	p:SetAttribute("Until", now + ToolConfig.PuddleSeconds)
	CollectionService:AddTag(p, Names.Tag.WetFloor)
	p.Parent = folder
	Telemetry.count("puddles")
end

local function puddleLoop()
	while true do
		task.wait(1)
		local f = puddleFolder
		if f then
			local now = os.clock()
			for _, p in f:GetChildren() do
				local u = (p:GetAttribute("Until") :: number?) or 0
				if now > u and p:IsA("BasePart") then
					p.Transparency = math.min(1, p.Transparency + 0.12)
					if p.Transparency >= 0.98 then
						p:Destroy()
					end
				end
			end
		end
	end
end

-- friendly fire ----------------------------------------------------------------------------
local function lineOfSight(from: Vector3, victimChar: Model, sprayerChar: Model): boolean
	local root = victimChar:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return false
	end
	local hit = workspace:Raycast(from, root.Position - from, rayParams({ sprayerChar }))
	return hit == nil or hit.Instance:IsDescendantOf(victimChar)
end

local function soak(sprayer: Player, origin: Vector3, aim: Vector3, kind: string, pressure: number)
	local sprayerChar = sprayer.Character
	if not sprayerChar then
		return
	end
	local now = os.clock()
	local range = if kind == "foam" then ToolConfig.FoamRange else ToolConfig.HoseHitRange
	for _, victim in Players:GetPlayers() do
		if victim == sprayer then
			continue
		end
		local vchar = victim.Character
		local root = vchar and vchar:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (vchar and root) then
			continue
		end
		local d = root.Position - origin
		if not ToolMath.inCone(d.X, d.Y, d.Z, aim.X, aim.Y, aim.Z, range, ToolConfig.HoseHitCos) then
			continue
		end
		if not lineOfSight(origin, vchar, sprayerChar) then
			continue
		end
		local key = `{sprayer.UserId}:{victim.UserId}`
		-- the shove (rate-limited per pair)
		if now - (lastPush[key] or 0) >= ToolConfig.HosePushInterval then
			lastPush[key] = now
			local speed = if kind == "foam" then ToolConfig.FoamPush else ToolConfig.HosePush * pressure
			local x, y, z = ToolMath.push(aim.X, aim.Z, speed, ToolConfig.HosePushLift * (if kind == "foam" then 0.3 else pressure))
			local v = Vector3.new(x, y, z)
			Ragdoll.knockback(vchar, v)
			if Pushed then
				Pushed:FireClient(victim, v, sprayer.UserId, kind)
			end
			call("HeatService", "Cool", victim, if kind == "foam" then ToolConfig.FoamCool else ToolConfig.HoseCool, sprayer)
		end
		-- sustained soaking knocks them over (hose only)
		if kind == "hose" then
			if now - (soakLast[victim] or 0) > 0.35 then
				soakSince[victim] = now
			end
			soakLast[victim] = now
			if now - (soakSince[victim] or now) >= ToolConfig.HoseKnockdownSeconds and not Ragdoll.isRagdolled(vchar) then
				if Ragdoll.enable(vchar, ToolConfig.HoseRagdollSeconds) then
					Telemetry.count("hose_knockdowns")
					fx("sploosh", root.Position, 1)
					Popup.show(victim, `Hosed by {sprayer.DisplayName}!`, "blame", sprayer)
				end
				soakSince[victim] = now
			end
		end
		-- the blame (once per pair per cooldown)
		if now - (lastHit[key] or 0) >= ToolConfig.HoseHitCooldown then
			lastHit[key] = now
			Telemetry.count("hose_teammate_hits")
			ToolService.HoseHit:Fire(sprayer, victim)
		end
	end
end

-- spray ------------------------------------------------------------------------------------
local function equipped(player: Player): string?
	local char = player.Character
	if not char then
		return nil
	end
	if char:FindFirstChild("Hose") then
		return "hose"
	elseif char:FindFirstChild("Extinguisher") then
		return "foam"
	end
	return nil
end

local function sprayHose(player: Player, char: Model, head: BasePart, aim: Vector3)
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local litres = math.min(water, ToolConfig.LitresPerSpray)
	if litres <= 0 then
		return
	end
	local pressure = pressureOf(player)
	player:SetAttribute(Names.Attr.Water, water - litres)
	Telemetry.count("water_used", litres)
	ToolService.WaterUsed:Fire(player, litres)
	markSpraying(player)
	call("FireService", "ApplyWater", player, head.Position, aim, litres * math.max(pressure, 0.3))
	ToolService.HoseRecoil:Fire(player, -aim * ToolConfig.HoseRecoil * pressure)
	soak(player, head.Position, aim, "hose", pressure)
	-- hose rocket gag: aim straight down long enough and the client lifts off; count it once
	local now = os.clock()
	if -aim.Y >= ToolConfig.HoseRocketCos then
		rocketSince[player] = rocketSince[player] or now
		if now - (rocketSince[player] :: number) >= ToolConfig.HoseRocketSeconds and not player:GetAttribute("HoseRocket") then
			player:SetAttribute("HoseRocket", true)
			Telemetry.count("hose_rockets")
		end
	else
		rocketSince[player] = nil
		player:SetAttribute("HoseRocket", nil)
	end
	-- puddles where the stream lands on a floor
	local n = (sprayCount[player] or 0) + 1
	sprayCount[player] = n
	if n % ToolConfig.PuddleEvery == 0 then
		local hit = streamImpact(head.Position, aim, ToolConfig.StreamSpeed * (0.6 + 0.4 * pressure), charParts())
		if hit and hit.Normal.Y > 0.6 then
			splashPuddle(hit.Position, litres * ToolConfig.PuddleEvery)
		end
	end
end

local function sprayFoam(player: Player, head: BasePart, aim: Vector3)
	-- one can at a time and at most SprayHz puffs a second: swapping between two extinguishers (or
	-- two clients' worth of input) can't stack sprays
	local now = os.clock()
	if now - (lastFoam[player] or 0) < 0.85 / math.max(1, ToolConfig.SprayHz) then
		return
	end
	local size = (player:GetAttribute(ATTR_FOAM_SIZE) :: number?) or ToolConfig.FoamSize
	local foam = math.clamp((player:GetAttribute(ATTR_FOAM) :: number?) or 0, 0, size)
	local charges = math.min(foam, ToolConfig.FoamPerSpray)
	if charges <= 0 then
		return
	end
	lastFoam[player] = now
	player:SetAttribute(ATTR_FOAM, foam - charges)
	Telemetry.count("foam_used", charges)
	markSpraying(player)
	call("FireService", "ApplyWater", player, head.Position, aim, charges * ToolConfig.FoamEfficiency)
	soak(player, head.Position, aim, "foam", 1)
end

local function sprayOnce(player: Player, aim: Vector3)
	local kind = equipped(player)
	local char = player.Character
	if not kind or not char or blocked(player) then
		return
	end
	local head = char:FindFirstChild("Head") :: BasePart?
	if not head then
		return
	end
	if kind == "hose" then
		sprayHose(player, char, head, aim)
	else
		sprayFoam(player, head, aim)
	end
end

-- prompts ----------------------------------------------------------------------------------
-- Every Hydrant / TruckRefill / Door part has exactly one ProximityPrompt made by its builder.
local function hookPrompt(part: Instance, onTrigger: (Player, BasePart) -> ())
	if not part:IsA("BasePart") then
		return
	end
	local prompt = part:FindFirstChildOfClass("ProximityPrompt")
	if not prompt or hooked[prompt] then
		return
	end
	hooked[prompt] = true
	prompt.Triggered:Connect(function(player: Player)
		onTrigger(player, part :: BasePart)
	end)
	prompt.Destroying:Connect(function()
		hooked[prompt] = nil
	end)
end

local function watchTag(tag: string, onTrigger: (Player, BasePart) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		task.defer(hookPrompt, inst, onTrigger) -- builders add the prompt right after the tag
	end)
	for _, inst in CollectionService:GetTagged(tag) do
		hookPrompt(inst, onTrigger)
	end
end

-- doors ------------------------------------------------------------------------------------
local function doorPrompt(door: BasePart): ProximityPrompt?
	return door:FindFirstChildOfClass("ProximityPrompt")
end

local function remember(door: BasePart)
	if doorOriginal[door] then
		return
	end
	local p = doorPrompt(door)
	doorOriginal[door] = {
		locked = door:GetAttribute(Names.Attr.Locked) == true,
		transparency = door.Transparency,
		canCollide = door.CanCollide,
		canQuery = door.CanQuery,
		actionText = if p then p.ActionText else "Open",
	}
end

local function toggleDoor(door: BasePart)
	remember(door)
	local o = doorOriginal[door] :: DoorState
	local opening = door.CanCollide
	door.CanCollide = not opening
	door.Transparency = if opening then 0.8 else o.transparency
	local p = doorPrompt(door)
	if p then
		p.ActionText = if opening then "Close" else "Open"
	end
end

local function chips(door: BasePart, dir: Vector3)
	local rng = Random.new()
	for _ = 1, 6 do
		local c = Instance.new("Part")
		c.Name = "Chip"
		c.Size = Vector3.new(0.4, 0.4, 0.8) * rng:NextNumber(0.7, 1.3)
		c.Color = door.Color
		c.Material = Enum.Material.Wood
		c.CanQuery = false
		c.CanTouch = false
		c.CFrame = door.CFrame * CFrame.new(rng:NextNumber(-1.5, 1.5), rng:NextNumber(-2, 2), 0)
		c.AssemblyLinearVelocity = dir * rng:NextNumber(6, 16) + Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(8, 16), rng:NextNumber(-6, 6))
		c.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-20, 20), rng:NextNumber(-20, 20), rng:NextNumber(-20, 20))
		c.Parent = workspace
		Debris:AddItem(c, 3)
	end
end

-- The real door hides (so ResetDoors can bring it back); three physics planks take its place and
-- get launched along the swing with a wild spin.
local function launchPlanks(door: BasePart, dir: Vector3)
	local rng = Random.new()
	local n = 3
	local w = door.Size.X / n
	for i = 1, n do
		local plank = Instance.new("Part")
		plank.Name = "DoorPlank"
		plank.Size = Vector3.new(w * 0.96, door.Size.Y * rng:NextNumber(0.85, 1), door.Size.Z)
		plank.Color = door.Color
		plank.Material = Enum.Material.WoodPlanks
		plank.CFrame = door.CFrame * CFrame.new(-door.Size.X / 2 + w * (i - 0.5), 0, 0)
		plank.CanQuery = false
		plank.CanTouch = false
		plank.Anchored = false
		plank.CustomPhysicalProperties = PhysicalProperties.new(0.4, 0.4, 0.6) -- light and bouncy
		plank.Parent = workspace
		plank.AssemblyLinearVelocity = dir * ToolConfig.DoorFlySpeed * rng:NextNumber(0.75, 1.2)
			+ Vector3.new(0, ToolConfig.DoorFlyLift * rng:NextNumber(0.7, 1.3), 0)
		plank.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-14, 14), rng:NextNumber(-10, 10), rng:NextNumber(-14, 14))
		Debris:AddItem(plank, ToolConfig.DoorDebrisSeconds)
	end
end

local function breakDoor(door: BasePart, dir: Vector3)
	door:SetAttribute(Names.Attr.Broken, true)
	door:SetAttribute(Names.Attr.Locked, false)
	door.CanCollide = false
	door.CanQuery = false
	door.Transparency = 1
	local p = doorPrompt(door)
	if p then
		p.Enabled = false
	end
	launchPlanks(door, dir)
end

local function resetDoor(door: BasePart)
	local o = doorOriginal[door]
	doorHits[door] = nil
	if not o then
		return
	end
	door:SetAttribute(Names.Attr.Broken, false)
	door:SetAttribute(Names.Attr.Locked, o.locked)
	door.CanCollide = o.canCollide
	door.CanQuery = o.canQuery
	door.Transparency = o.transparency
	local p = doorPrompt(door)
	if p then
		p.Enabled = true
		p.ActionText = o.actionText
	end
end

-- Direction the planks fly: from the swinger through the door, flattened.
local function swingDir(player: Player, door: BasePart): Vector3
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local d = if root then door.Position - root.Position else door.CFrame.LookVector
	d = Vector3.new(d.X, 0, d.Z)
	return if d.Magnitude > 1e-3 then d.Unit else Vector3.new(0, 0, -1)
end

local function hitDoor(player: Player, door: BasePart)
	remember(door)
	if door:GetAttribute(Names.Attr.Broken) == true then
		return
	end
	local dir = swingDir(player, door)
	chips(door, dir)
	local hits, broke = ToolMath.doorHit(doorHits[door] or 0, ToolConfig.DoorHits)
	doorHits[door] = hits
	if not broke then
		fx("chop", door.Position, hits)
		return
	end
	breakDoor(door, dir)
	fx("crack", door.Position, 1)
	Telemetry.count("doors_broken")
	ToolService.DoorBroken:Fire(player, door)
	-- (the Tool/Fx "CRACK!" pop over the door already says it; no screen toast)
end

local function nearestDoor(root: BasePart, reach: number, lockedOnly: boolean): BasePart?
	local best, bestD = nil :: BasePart?, math.huge
	for _, inst in CollectionService:GetTagged(Names.Tag.Door) do
		if
			inst:IsA("BasePart")
			and inst:GetAttribute(Names.Attr.Broken) ~= true
			and (not lockedOnly or inst:GetAttribute(Names.Attr.Locked) == true)
			and inst.CanCollide
			and inst:IsDescendantOf(workspace)
		then
			local to = inst.Position - root.Position
			local d = to.Magnitude
			local facing = d < 1e-3 or root.CFrame.LookVector:Dot(to.Unit) > 0.3
			if d <= reach and facing and d < bestD then
				best, bestD = inst, d
			end
		end
	end
	return best
end

-- axe --------------------------------------------------------------------------------------
-- The held axe's tier id ("Axe" = rusty), nil-guarded: a plain "Axe" Tool with no attr is the rusty one.
local function axeTier(player: Player): string?
	local char = player.Character
	local t = char and char:FindFirstChild("Axe")
	if not t then
		return nil
	end
	local tier = t:GetAttribute("AxeTier") or t:GetAttribute("InvItem")
	return if type(tier) == "string" then tier else "Axe"
end

local function bonk(player: Player, root: BasePart): boolean
	local any = false
	local look = root.CFrame.LookVector
	for _, victim in Players:GetPlayers() do
		if victim == player then
			continue
		end
		local vchar = victim.Character
		local vroot = vchar and vchar:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not (vchar and vroot) then
			continue
		end
		local d = vroot.Position - root.Position
		if ToolMath.inCone(d.X, d.Y, d.Z, look.X, look.Y, look.Z, ToolConfig.AxeBonkReach, ToolConfig.AxeBonkCos) then
			local x, y, z = ToolMath.push(d.X, d.Z, ToolConfig.AxeBonkPush, ToolConfig.AxeBonkLift)
			local v = Vector3.new(x, y, z)
			Ragdoll.knockback(vchar, v)
			if Pushed then
				Pushed:FireClient(victim, v, player.UserId, "axe")
			end
			fx("bonk", vroot.Position + Vector3.new(0, 2, 0), 1)
			Telemetry.count("axe_teammate_hits")
			Popup.show(victim, `{player.DisplayName}'s axe!`, "blame", player)
			any = true
		end
	end
	return any
end

swing = function(player: Player)
	local char = player.Character
	if not char or not char:FindFirstChild("Axe") or blocked(player) then
		return
	end
	local now = os.clock()
	if now - (lastSwing[player] or 0) < Progression.swingCooldown(ToolConfig.AxeCooldown, axeTier(player)) then
		return
	end
	lastSwing[player] = now
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	Telemetry.count("axe_swings")
	fx("whoosh", root.Position, player.UserId)
	local door = nearestDoor(root, ToolConfig.AxeReach, false)
	if door then
		for _ = 1, Progression.doorHits(1, axeTier(player), ToolConfig.DoorHits) do
			if door:GetAttribute(Names.Attr.Broken) == true then
				break
			end
			hitDoor(player, door)
		end
	end
	bonk(player, root)
end

local function onDoorPrompt(player: Player, door: BasePart)
	if door:GetAttribute(Names.Attr.Broken) == true then
		return
	end
	if door:GetAttribute(Names.Attr.Locked) ~= true then
		toggleDoor(door)
		return
	end
	local char = player.Character
	if char and char:FindFirstChild("Axe") and not blocked(player) then
		local now = os.clock()
		if now - (lastSwing[player] or 0) < Progression.swingCooldown(ToolConfig.AxeCooldown, axeTier(player)) then
			return
		end
		lastSwing[player] = now
		for _ = 1, Progression.doorHits(1, axeTier(player), ToolConfig.DoorHits) do
			if door:GetAttribute(Names.Attr.Broken) == true then
				break
			end
			hitDoor(player, door)
		end
	else
		Popup.show(door, "Locked! Use the axe", "info", player)
	end
end

-- refills and hose lines -------------------------------------------------------------------
local function onRefill(player: Player, part: BasePart, isTruck: boolean)
	if blocked(player) then
		return
	end
	ToolService:Refill(player, nil)
	if isTruck then
		player:SetAttribute(ATTR_FOAM_SIZE, ToolConfig.FoamSize)
		player:SetAttribute(ATTR_FOAM, ToolConfig.FoamSize)
	end
	hoseLineCall("attach", player, part)
	fx("refill", part.Position, player.UserId)
end

local function hookCharacter(player: Player, char: Model)
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		hum.Died:Connect(function()
			hoseLineCall("detach", player)
			player:SetAttribute(Names.Attr.Spraying, false)
		end)
	end
	char.ChildRemoved:Connect(function(child: Instance)
		if child:IsA("Tool") and child.Name == "Hose" then
			hoseLineCall("detach", player) -- unequipped the hose
			player:SetAttribute(Names.Attr.Spraying, false)
		end
	end)
end

local function hookPlayer(player: Player)
	player.CharacterAdded:Connect(function(char: Model)
		hookCharacter(player, char)
	end)
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end
end

-- service ----------------------------------------------------------------------------------
function ToolService:Init(all: { [string]: any })
	services = all
end

function ToolService:Start()
	Pushed = Net.event("Tool", "Pushed")
	Fx = Net.event("Tool", "Fx")
	local Spray = Net.event("Tool", "Spray")
	Net.onServer(Spray, { rate = 12, burst = 4 }, function(player: Player, rawAim: any)
		local aim = Net.unit(rawAim)
		if aim then
			sprayOnce(player, aim)
		end
	end)
	puddles()
	if not services.InventoryService then -- v2: InventoryService owns the reel and hydrant prompts
		watchTag(Names.Tag.Hydrant, function(player: Player, part: BasePart)
			onRefill(player, part, false)
		end)
		watchTag(Names.Tag.TruckRefill, function(player: Player, part: BasePart)
			onRefill(player, part, true)
		end)
	end
	watchTag(Names.Tag.Door, onDoorPrompt)
	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		hookPlayer(p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		hoseLineCall("detach", player)
		lastSpray[player] = nil
		lastFoam[player] = nil
		lastSwing[player] = nil
		sprayCount[player] = nil
		rocketSince[player] = nil
		soakSince[player] = nil
		soakLast[player] = nil
		local id = tostring(player.UserId)
		for _, map in { lastHit, lastPush } do
			for key in map do
				local a, b = string.match(key, "^(%d+):(%d+)$")
				if a == id or b == id then
					map[key] = nil
				end
			end
		end
	end)
	task.spawn(puddleLoop)
end

function ToolService:GiveLoadout(player: Player)
	local backpack = if services.InventoryService then nil else player:FindFirstChildOfClass("Backpack")
	if backpack then
		removeTools(player)
		makeHose().Parent = backpack
		makeAxe(player).Parent = backpack
		makeExtinguisher().Parent = backpack
	end
	player:SetAttribute(Names.Attr.TankSize, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Water, ToolConfig.TankSize)
	player:SetAttribute(Names.Attr.Spraying, false)
	player:SetAttribute(ATTR_FOAM_SIZE, ToolConfig.FoamSize)
	player:SetAttribute(ATTR_FOAM, ToolConfig.FoamSize)
end

function ToolService:CreateTool(itemId: string, player: Player): Tool?
	if itemId == "Hose" then
		return makeHose()
	elseif AXE_TIERS[itemId] then
		local axe = makeAxe(player)
		axe:SetAttribute("AxeTier", itemId)
		local ok, ItemProps = pcall(function()
			return require(ServerScriptService:WaitForChild("Lib"):WaitForChild("Items"):WaitForChild("ItemProps") :: ModuleScript) :: any
		end)
		if ok and ItemProps and ItemProps.paintAxe then
			pcall(ItemProps.paintAxe, axe, itemId)
		end
		if itemId ~= "Axe" then
			axe.ToolTip = `{if itemId == "GoldenAxe" then "Golden Axe" else "Fire Axe"}: click to break doors (hits harder, swings faster)`
		end
		return axe
	elseif itemId == "Extinguisher" then
		return makeExtinguisher()
	end
	return nil
end

function ToolService:Refill(player: Player, litres: number?)
	local size = (player:GetAttribute(Names.Attr.TankSize) :: number?) or ToolConfig.TankSize
	local water = (player:GetAttribute(Names.Attr.Water) :: number?) or 0
	local new = math.min(size, water + (litres or size))
	player:SetAttribute(Names.Attr.TankSize, size)
	player:SetAttribute(Names.Attr.Water, new)
	Telemetry.count("refills")
	if new >= size then
		Popup.show(player, "Tank full!", "good", player)
	end
end

-- Accepts a locationId (v1) or an instanceId (v1.5 parallel missions).
function ToolService:ResetDoors(locationId: string)
	local model = call("MapService", "GetLocation", locationId) or call("MapService", "GetInstance", locationId)
	if typeof(model) ~= "Instance" then
		return
	end
	for _, d in (model :: Instance):GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, Names.Tag.Door) then
			resetDoor(d)
		end
	end
end

-- v2 physics hands (HandsService validates first): an axe-head impact worth `hits` door hits, and a
-- hand shove that swings an unlocked closed door open. PushDoor returns true when it opened.
function ToolService:HitDoor(player: Player, door: BasePart, hits: number?)
	local base = math.clamp(math.floor(tonumber(hits) or 1), 1, math.max(1, ToolConfig.DoorHits))
	-- axe tiers hit harder (a kick or a saw passes the full DoorHits, so the tier can't add to it)
	for _ = 1, Progression.doorHits(base, axeTier(player), ToolConfig.DoorHits) do
		if door:GetAttribute(Names.Attr.Broken) == true then
			break
		end
		hitDoor(player, door)
	end
end

function ToolService:PryDoor(door: BasePart): boolean
	if door:GetAttribute(Names.Attr.Broken) == true or not door:HasTag(Names.Tag.Door) then
		return false
	end
	remember(door) -- the original Locked state, so ResetDoors re-locks it
	door:SetAttribute(Names.Attr.Locked, false)
	doorHits[door] = nil
	if door.CanCollide then
		toggleDoor(door)
	end
	return true
end

function ToolService:PushDoor(door: BasePart): boolean
	if door:GetAttribute(Names.Attr.Broken) == true or door:GetAttribute(Names.Attr.Locked) == true or not door.CanCollide then
		return false
	end
	toggleDoor(door)
	return true
end

-- test hooks -------------------------------------------------------------------------------
function ToolService:_spray(player: Player, aim: Vector3)
	sprayOnce(player, aim.Unit)
end

-- Foam rate-limit check for tests: clears the limiter so the next _spray goes through.
function ToolService:_resetFoamLimit(player: Player)
	lastFoam[player] = nil
end

function ToolService:_swing(player: Player)
	lastSwing[player] = nil -- tests may swing faster than AxeCooldown
	swing(player)
end

function ToolService:_doorPrompt(player: Player, door: BasePart)
	lastSwing[player] = nil
	onDoorPrompt(player, door)
end

function ToolService:_selftest(): (boolean, string)
	local net = ReplicatedStorage:FindFirstChild("Net")
	local ns = net and net:FindFirstChild("Tool")
	for _, r in { "Spray", "Pushed", "Fx" } do
		if not (ns and ns:FindFirstChild(r)) then
			return false, `Tool/{r} remote missing`
		end
	end
	for _, make in { makeHose, makeExtinguisher } do
		local t = make()
		local ok = t:FindFirstChild("Handle") ~= nil and (t :: any).Handle:FindFirstChild("Nozzle") ~= nil
		t:Destroy()
		if not ok then
			return false, "tool has no Handle.Nozzle"
		end
	end
	local rok, rmsg = Ragdoll._selftest()
	if not rok then
		return false, `Ragdoll: {rmsg}`
	end
	return true, "ok"
end

return ToolService
