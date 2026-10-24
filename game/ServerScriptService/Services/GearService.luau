--!strict
-- GearService [owner: Gear]. Gear progression and the "different ways in":
--   * PROGRESSION: levels unlock gear (Lib/Items/Progression: Lv1 Rusty Axe + Hose + Ladder, Lv2 Gas Mask, Lv3
--     Halligan, Lv4 Fire Axe, Lv6 Thermal Cam, Lv8 Sledgehammer, Lv10 Golden Axe, Lv12 Rescue
--     Saw). Unlocks + the locker loadout persist in the profile (ProfileSchema v3 `gear`). A level-up
--     tells the client what it unlocked (Gear/Unlocked). Your station GearRack (rack Helmet = your
--     Helmet) hangs your loadout on three pegs that restock, and has a LOCKER prompt (R) that opens
--     GearController's loadout picker.
--   * TOOLS (plain Tools from ItemProps; their Activated is hooked here): Halligan / Crowbar pry a
--     locked door open quietly (ToolService:PryDoor), Sledgehammer smashes Window panes and weak wall
--     chunks into new doorways, Rescue Saw cuts doors/walls fast, Ladder stands a climbable truss
--     against the wall in front of you, Thermal Cam counts people inside (the glow is client-side),
--     Flashlight toggles its beam. Any axe tier also smashes a window it is pointed at.
--   * WAYS IN without tools: KICK a locked door (F prompt; Progression.kickChance; a miss ragdolls you
--     backwards), CLIMB THROUGH a broken window (prompt appears on every broken Window pane), and a
--     ROOF HATCH on every IncidentSite roof (open + drop into the top floor; quicker with a pry bar).
--
-- Public API:
--   GearService:GetLoadout(player): { string }
--   GearService:SetLoadout(player, ids): boolean        -- validated by Progression.sanitizeLoadout
--   GearService:LevelOf(player): number
-- Remotes: Gear/SetLoadout (C->S: { id }, 2/s), Gear/Unlocked (S->C owner: level, { id }),
--          Gear/Fx (S->C all: kind "pry"|"smash"|"breach"|"kick"|"kickfail"|"saw"|"ladder"|"climb"|"hatch", pos)
-- Writes: Player attrs GearLoadout ("Axe,OxygenTank,..."), GearBusy ("" | "Prying" | "Cutting");
--   rack peg parts (folder "LoadoutPegs" in each GearRack folder) with attrs Item, Owner; "GearLocker"
--   prompts; "KickPoint" Attachments + prompts on Door parts; "ClimbPoint" prompts on broken Windows;
--   "RoofHatch" parts on IncidentSite roofs; workspace.PlacedLadders (TrussParts, attr OwnerUserId).
-- Reads (nil-guarded): DataService (GetProfile/Update/ProfileLoaded/LevelUp), InventoryService
--   (Give/TakeHand), ToolService (PryDoor/HitDoor/PushDoor), StructureService (BreakWindow/Breach).
-- Counters: gear_pries, gear_kicks, gear_kick_fails, gear_windows_smashed, gear_breaches, gear_saw_cuts,
--   gear_ladders, gear_climbs, gear_hatch_drops, gear_unlocks, gear_loadouts_saved, gear_peg_grabs
-- Test hooks (DevHook only): _selftest(), _use(player, id?), _kick(player, door?, force?),
--   _setLevel(player, level), _state(player), _climb(player, window), _hatch(player, hatch?)

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Popup = require(Shared:WaitForChild("Popup") :: ModuleScript)
local Ragdoll = require(Shared:WaitForChild("Ragdoll") :: ModuleScript)
local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
local ConfigFolder = ReplicatedStorage:WaitForChild("Config")
local Cfg = require(ConfigFolder:WaitForChild("GearConfig") :: ModuleScript) :: any
local ToolConfig = require(ConfigFolder:WaitForChild("ToolConfig") :: ModuleScript) :: any
local InvCfg = require(ConfigFolder:WaitForChild("InventoryConfig") :: ModuleScript) :: any
local DataConfig = require(ConfigFolder:WaitForChild("DataConfig") :: ModuleScript) :: any
local Items = ReplicatedStorage:WaitForChild("Lib"):WaitForChild("Items")
local ItemDefs = require(Items:WaitForChild("ItemDefs") :: ModuleScript) :: any
local Progression = require(Items:WaitForChild("Progression") :: ModuleScript) :: any
local Lib = ServerScriptService:WaitForChild("Lib")
local ItemProps = require(Lib:WaitForChild("Items"):WaitForChild("ItemProps") :: ModuleScript) :: any
local Schema = require(Lib:WaitForChild("Data"):WaitForChild("ProfileSchema") :: ModuleScript) :: any

local GearService = {}
GearService.Priority = 60

local SITE_TAG = "IncidentSite"
local TAG_RACK = "GearRack"
local AXES = { Axe = true, FireAxe = true, GoldenAxe = true }
local ROOFY = { "^Roof", "^Ceiling", "^Gable", "^Ridge", "^Parapet" }

type PState = {
	level: number,
	loadout: { string },
	busy: boolean,
	lastUse: number,
	lastKick: number,
	lastSay: number,
}
type Peg = { part: BasePart, prompt: ProximityPrompt, display: Model?, id: string?, stocked: boolean }
type Rack = { board: BasePart, pegs: { Peg }, sig: string }

local services: { [string]: any } = {}
local states: { [Player]: PState } = {}
local racks: { [BasePart]: Rack } = {}
local kickTries: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local wallHits: { [BasePart]: number } = setmetatable({}, { __mode = "k" }) :: any
local hookedTools: { [Tool]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local hookedDoors: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local hookedWindows: { [BasePart]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local hookedSites: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local ladders: { BasePart } = {}
local FxRemote: RemoteEvent? = nil
local UnlockedRemote: RemoteEvent? = nil

-- helpers ------------------------------------------------------------------------------------------
local function call(serviceName: string, method: string, ...: any): any
	local svc = services[serviceName]
	local f = svc and svc[method]
	if type(f) ~= "function" then
		return nil
	end
	local ok, res = pcall(f, svc, ...)
	if not ok then
		warn(`[GearService] {serviceName}:{method} failed: {res}`)
		return nil
	end
	return res
end

local function fx(kind: string, pos: Vector3)
	if FxRemote then
		FxRemote:FireAllClients(kind, pos)
	end
end

local function stateOf(player: Player): PState
	local s = states[player]
	if not s then
		s = { level = 1, loadout = Progression.defaultLoadout(1), busy = false, lastUse = 0, lastKick = 0, lastSay = 0 }
		states[player] = s
	end
	return s :: PState
end

local function say(player: Player, text: string, kind: string?)
	local s = stateOf(player)
	local now = os.clock()
	if now - s.lastSay < 0.7 then
		return
	end
	s.lastSay = now
	Popup.show(player, text, kind or "info", player)
end

local function charOf(player: Player): (Model?, BasePart?)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return char, root
end

local function downed(player: Player): boolean
	return player:GetAttribute(Names.Attr.Downed) == true
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

local function siteOf(inst: Instance): Model?
	local node = inst.Parent
	while node and node ~= workspace do
		if node:IsA("Model") and node:HasTag(SITE_TAG) then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function isRoofy(name: string): boolean
	for _, pat in ROOFY do
		if string.match(name, pat) then
			return true
		end
	end
	return false
end

-- Nearest part from `list` within Reach that is roughly in front of the player (distance to its
-- surface, so a wide wall counts when you stand at its edge).
local function nearestInFront(root: BasePart, list: { BasePart }, reach: number?): BasePart?
	local r = reach or Cfg.Reach
	local look = flat(root.CFrame.LookVector)
	local best: BasePart?, bestD = nil, math.huge
	for _, p in list do
		local to = p.Position - root.Position
		local d = math.max(0, to.Magnitude - math.min(p.Size.X, p.Size.Z) * 0.5)
		if d <= r and d < bestD then
			local f = Vector3.new(to.X, 0, to.Z)
			if f.Magnitude < 1.5 or look:Dot(f.Unit) >= Cfg.FacingDot then
				best, bestD = p, d
			end
		end
	end
	return best
end

local function taggedNear(tag: string, root: BasePart, pred: ((BasePart) -> boolean)?): { BasePart }
	local out: { BasePart } = {}
	local r = Cfg.Reach + 8
	for _, inst in CollectionService:GetTagged(tag) do
		if inst:IsA("BasePart") and (inst.Position - root.Position).Magnitude <= r and inst:IsDescendantOf(workspace) then
			if not pred or pred(inst) then
				table.insert(out, inst)
			end
		end
	end
	return out
end

local function closedDoor(p: BasePart): boolean
	return p:GetAttribute(Names.Attr.Broken) ~= true and p.CanCollide
end

local function intactWindow(p: BasePart): boolean
	return p:GetAttribute(Names.Attr.Broken) ~= true and p.Transparency < 1
end

-- Weak wall chunks: an IncidentSite's chunked "Wall"/"Partition" parts no wider than WeakWallMaxSize.
local function weakWalls(root: BasePart): { BasePart }
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local char = root.Parent
	params.FilterDescendantsInstances = if char then { char } else {}
	local out: { BasePart } = {}
	for _, p in workspace:GetPartBoundsInRadius(root.Position, Cfg.Reach + 2, params) do
		if (p.Name == "Wall" or p.Name == "Partition") and p.Anchored and p.CanCollide and p:GetAttribute("Breached") ~= true then
			local wide = math.max(p.Size.X, p.Size.Z)
			if wide <= Cfg.WeakWallMaxSize and siteOf(p) then
				table.insert(out, p)
			end
		end
	end
	return out
end

local function debris(at: CFrame, size: Vector3, color: Color3, material: Enum.Material, dir: Vector3, n: number)
	local rng = Random.new()
	for _ = 1, n do
		local c = Instance.new("Part")
		c.Name = "GearDebris"
		c.Size = Vector3.new(rng:NextNumber(0.4, 1.2), rng:NextNumber(0.4, 1.2), rng:NextNumber(0.3, 0.8))
		c.Color = color
		c.Material = material
		c.CanQuery = false
		c.CanTouch = false
		c.CFrame = at * CFrame.new(rng:NextNumber(-size.X / 2, size.X / 2), rng:NextNumber(-size.Y / 2, size.Y / 2), 0)
		c.Parent = workspace
		c.AssemblyLinearVelocity = dir * rng:NextNumber(10, 26) + Vector3.new(rng:NextNumber(-6, 6), rng:NextNumber(6, 14), rng:NextNumber(-6, 6))
		c.AssemblyAngularVelocity = Vector3.new(rng:NextNumber(-15, 15), rng:NextNumber(-15, 15), rng:NextNumber(-15, 15))
		Debris:AddItem(c, 4)
	end
end

-- windows and walls --------------------------------------------------------------------------------
local function breakWindow(player: Player?, pane: BasePart): boolean
	if not intactWindow(pane) then
		return false
	end
	local root: BasePart? = nil
	if player then
		local _, r = charOf(player)
		root = r
	end
	local dir = if root then flat(pane.Position - root.Position) else pane.CFrame.LookVector
	if not call("StructureService", "BreakWindow", pane) then
		-- not part of an indexed structure: break it ourselves and heal it later
		local t, c, q = pane.Transparency, pane.CanCollide, pane.CanQuery
		pane:SetAttribute(Names.Attr.Broken, true)
		pane.Transparency = 1
		pane.CanCollide = false
		pane.CanQuery = false
		task.delay(Cfg.BreachHealSeconds, function()
			if pane.Parent and pane:GetAttribute(Names.Attr.Broken) == true then
				pane.Transparency, pane.CanCollide, pane.CanQuery = t, c, q
				pane:SetAttribute(Names.Attr.Broken, nil)
			end
		end)
	end
	debris(pane.CFrame, pane.Size, pane.Color, Enum.Material.Glass, dir, 7)
	Telemetry.count("gear_windows_smashed")
	fx("smash", pane.Position)
	return true
end

local function breachWall(player: Player, wall: BasePart)
	local _, root = charOf(player)
	local dir = if root then flat(wall.Position - root.Position) else wall.CFrame.LookVector
	if not call("StructureService", "Breach", wall) then
		local t, c, q = wall.Transparency, wall.CanCollide, wall.CanQuery
		wall.Transparency = 1
		wall.CanCollide = false
		wall.CanQuery = false
		wall:SetAttribute("Breached", true)
		task.delay(Cfg.BreachHealSeconds, function()
			if wall.Parent and wall:GetAttribute("Breached") == true then
				wall.Transparency, wall.CanCollide, wall.CanQuery = t, c, q
				wall:SetAttribute("Breached", nil)
			end
		end)
	end
	wallHits[wall] = nil
	debris(wall.CFrame, wall.Size * Vector3.new(1, 0.8, 0.8), wall.Color, wall.Material, dir, 12)
	Telemetry.count("gear_breaches")
	fx("breach", wall.Position)
	Popup.show(wall, "NEW DOOR!", "good", player)
end

-- channelled verbs (pry / cut): the player must stay near and keep holding the tool ------------------
local function channel(player: Player, id: string, seconds: number, at: Vector3, label: string): boolean
	local s = stateOf(player)
	if s.busy then
		return false
	end
	s.busy = true
	player:SetAttribute("GearBusy", label)
	player:SetAttribute("GearBusyUntil", workspace:GetServerTimeNow() + seconds)
	local t0 = os.clock()
	local ok = true
	while os.clock() - t0 < seconds do
		task.wait(0.1)
		local char = player.Character
		local tool = char and char:FindFirstChildOfClass("Tool")
		if not player.Parent or downed(player) or not tool or tool:GetAttribute("InvItem") ~= id or not Net.near(player, at, Cfg.PryStayStuds) then
			ok = false
			break
		end
	end
	s.busy = false
	if player.Parent then
		player:SetAttribute("GearBusy", "")
		player:SetAttribute("GearBusyUntil", nil)
	end
	return ok
end

-- hatches ---------------------------------------------------------------------------------------------
local openHatch: (player: Player, hatch: BasePart) -> ()

local function nearestHatch(root: BasePart): BasePart?
	return nearestInFront(root, taggedNear("RoofHatch", root), Cfg.Reach)
end

-- tool verbs -----------------------------------------------------------------------------------------
local function usePry(player: Player, id: string, root: BasePart)
	local def = ItemDefs.get(id)
	local seconds = (def and def.pry) or 2
	local door = nearestInFront(root, taggedNear(Names.Tag.Door, root, closedDoor))
	if door then
		if door:GetAttribute(Names.Attr.Locked) ~= true then
			call("ToolService", "PushDoor", door)
			return
		end
		Popup.show(door, `Prying... ({def and def.name or id})`, "info", player)
		fx("pry", door.Position)
		if not channel(player, id, seconds, door.Position, "Prying") then
			say(player, "Lost your grip!")
			return
		end
		if call("ToolService", "PryDoor", door) then
			Telemetry.count("gear_pries")
			fx("pry", door.Position)
			Popup.show(door, "POP! Pried it open", "good", player)
		end
		return
	end
	local hatch = nearestHatch(root)
	if hatch then
		openHatch(player, hatch)
		return
	end
	local pane = nearestInFront(root, taggedNear(Names.Tag.Window, root, intactWindow), 6)
	if pane and pane:GetAttribute("Pried") ~= true then
		-- a pry bar levers a window out of its frame (slower than smashing it)
		if channel(player, id, seconds, pane.Position, "Prying") then
			pane:SetAttribute("Pried", true)
			breakWindow(player, pane)
		end
		return
	end
	say(player, "Nothing to pry here. Find a locked door!")
end

local function useSledge(player: Player, root: BasePart)
	local s = stateOf(player)
	local now = os.clock()
	if now - s.lastUse < Cfg.SledgeCooldown then
		return
	end
	s.lastUse = now
	local pane = nearestInFront(root, taggedNear(Names.Tag.Window, root, intactWindow))
	if pane then
		breakWindow(player, pane)
		Popup.show(pane, "SMASH!", "good", player)
		return
	end
	local door = nearestInFront(root, taggedNear(Names.Tag.Door, root, closedDoor))
	local wall = nearestInFront(root, weakWalls(root))
	if door and (not wall or (door.Position - root.Position).Magnitude <= (wall.Position - root.Position).Magnitude + 1) then
		call("ToolService", "HitDoor", player, door, 2)
		fx("smash", door.Position)
		return
	end
	if wall then
		local hits = (wallHits[wall] or 0) + 1
		wallHits[wall] = hits
		debris(wall.CFrame, Vector3.new(2, 2, 0), wall.Color, wall.Material, flat(wall.Position - root.Position), 4)
		fx("smash", wall.Position)
		if hits >= Cfg.SledgeWallHits then
			breachWall(player, wall)
		else
			Popup.show(wall, `CRACK! ({hits}/{Cfg.SledgeWallHits})`, "info", player)
		end
		return
	end
	fx("smash", root.Position + root.CFrame.LookVector * 3)
	say(player, "WHOOSH. Hit a window or a wall!")
end

local function useSaw(player: Player, id: string, root: BasePart, tool: Tool)
	local def = ItemDefs.get(id)
	local seconds = (def and def.cut) or 0.8
	local door = nearestInFront(root, taggedNear(Names.Tag.Door, root, closedDoor))
	local wall = if door then nil else nearestInFront(root, weakWalls(root))
	local pane = if door or wall then nil else nearestInFront(root, taggedNear(Names.Tag.Window, root, intactWindow))
	local target = door or wall or pane
	if not target then
		say(player, "BRRRRR! Point the saw at a door or a wall")
		fx("saw", root.Position + root.CFrame.LookVector * 3)
		return
	end
	local sparks = tool:FindFirstChild("Handle") and (tool :: any).Handle:FindFirstChild("SawSparks") :: ParticleEmitter?
	if sparks then
		sparks.Enabled = true
	end
	fx("saw", target.Position)
	local ok = channel(player, id, seconds, target.Position, "Cutting")
	if sparks and sparks.Parent then
		sparks.Enabled = false
	end
	if not ok then
		return
	end
	Telemetry.count("gear_saw_cuts")
	if door then
		call("ToolService", "HitDoor", player, door, ToolConfig.DoorHits)
	elseif wall then
		breachWall(player, wall)
	elseif pane then
		breakWindow(player, pane)
	end
end

local function useAxe(player: Player, root: BasePart)
	-- ToolService swings at doors; we only add: the axe smashes a window it's pointed at
	local door = nearestInFront(root, taggedNear(Names.Tag.Door, root, closedDoor), ToolConfig.AxeReach)
	if door then
		return
	end
	local pane = nearestInFront(root, taggedNear(Names.Tag.Window, root, intactWindow), 7)
	if pane then
		breakWindow(player, pane)
	end
end

local function placeLadder(player: Player, root: BasePart)
	local char = player.Character :: Model
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = { char, workspace:FindFirstChild("PlacedLadders") or char }
	local look = flat(root.CFrame.LookVector)
	local hit = workspace:Raycast(root.Position, look * 7, rp)
	if not hit or math.abs(hit.Normal.Y) > 0.35 then
		say(player, "Walk up to a wall to stand the ladder against it")
		return
	end
	local n = flat(hit.Normal)
	-- ground under the foot of the ladder
	local footXZ = hit.Position + n * 1.1
	local down = workspace:Raycast(footXZ + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), rp)
	local groundY = if down then down.Position.Y else root.Position.Y - 3
	-- climb the wall face until it ends (the eave / roof edge)
	local height = Cfg.LadderMinHeight
	for h = 4, Cfg.LadderMaxHeight, 2 do
		local probe = Vector3.new(footXZ.X, groundY + h, footXZ.Z)
		local face = workspace:Raycast(probe, -n * 2.5, rp)
		if not face then
			height = h + 2
			break
		end
		height = h + 2
	end
	height = math.clamp(math.ceil(height / 2) * 2, Cfg.LadderMinHeight, Cfg.LadderMaxHeight)
	if not call("InventoryService", "TakeHand", player, "Ladder") then
		return
	end
	local folder = workspace:FindFirstChild("PlacedLadders")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "PlacedLadders"
		folder.Parent = workspace
	end
	local truss = Instance.new("TrussPart")
	truss.Name = "PlacedLadder"
	truss.Size = Vector3.new(2, height, 2)
	truss.Style = Enum.Style.NoSupports
	truss.Color = Color3.fromHex("#C9CCD0")
	truss.Material = Enum.Material.Metal
	truss.Anchored = true
	local base = Vector3.new(footXZ.X, groundY, footXZ.Z)
	truss.CFrame = CFrame.lookAt(base + Vector3.new(0, height / 2, 0), base + Vector3.new(0, height / 2, 0) - n)
	truss:SetAttribute("OwnerUserId", player.UserId)
	-- the truss is the invisible climb surface; the ladder you see is two rails and rungs
	truss.Transparency = 1
	local function deco(name: string, size: Vector3, offset: CFrame)
		local d = Instance.new("Part")
		d.Name = name
		d.Size = size
		d.CFrame = truss.CFrame * offset
		d.Color = Color3.fromHex("#C9CCD0")
		d.Material = Enum.Material.Metal
		d.Anchored = true
		d.CanCollide = false
		d.CanQuery = false
		d.CanTouch = false
		d.Parent = truss
	end
	for _, side in { -1, 1 } do
		deco("Rail", Vector3.new(0.3, height, 0.4), CFrame.new(side * 1.1, 0, 0))
	end
	for y = -height / 2 + 1, height / 2 - 0.5, 1.5 do
		deco("Rung", Vector3.new(2.2, 0.22, 0.22), CFrame.new(0, y, 0))
	end
	deco("FootL", Vector3.new(0.5, 0.3, 0.7), CFrame.new(-1.1, -height / 2 + 0.15, 0))
	deco("FootR", Vector3.new(0.5, 0.3, 0.7), CFrame.new(1.1, -height / 2 + 0.15, 0))
	truss.Parent = folder
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Take Ladder"
	prompt.ObjectText = "Ladder"
	prompt.HoldDuration = 0.4
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.UIOffset = Vector2.new(0, 0)
	local att = Instance.new("Attachment")
	att.Name = "TakePoint"
	att.Position = Vector3.new(0, -height / 2 + 3, 0)
	att.Parent = truss
	prompt.Parent = att
	prompt.Triggered:Connect(function(who: Player)
		if not truss.Parent then
			return
		end
		if call("InventoryService", "Give", who, "Ladder") then
			local i = table.find(ladders, truss)
			if i then
				table.remove(ladders, i)
			end
			truss:Destroy()
		end
	end)
	table.insert(ladders, truss)
	while #ladders > Cfg.MaxLadders do
		local old = table.remove(ladders, 1)
		if old then
			old:Destroy()
		end
	end
	Telemetry.count("gear_ladders")
	fx("ladder", base)
	Popup.show(player, `Ladder up! ({height} studs)`, "good", player)
end

local function useThermal(player: Player, root: BasePart)
	local n = 0
	for _, m in CollectionService:GetTagged(Names.Tag.Rescuable) do
		if m:IsA("Model") and m:IsDescendantOf(workspace) then
			local state = m:GetAttribute(Names.Attr.RescueState)
			local pivot = m:GetPivot().Position
			if state ~= "Rescued" and state ~= "Toasted" and (pivot - root.Position).Magnitude <= Cfg.ThermalRange then
				n += 1
			end
		end
	end
	say(player, if n == 0 then "Thermal: no heat signatures nearby" else `Thermal: {n} heat signature{if n == 1 then "" else "s"}!`, if n > 0 then "good" else "info")
end

local function onUse(player: Player, tool: Tool)
	local id = tool:GetAttribute("InvItem")
	if type(id) ~= "string" or downed(player) then
		return
	end
	local char, root = charOf(player)
	if not char or not root or tool.Parent ~= char then
		return
	end
	local def = ItemDefs.get(id)
	if AXES[id] then
		useAxe(player, root)
	elseif def and def.pry then
		usePry(player, id, root)
	elseif id == "Sledgehammer" then
		useSledge(player, root)
	elseif id == "RescueSaw" then
		useSaw(player, id, root, tool)
	elseif id == "Ladder" then
		placeLadder(player, root)
	elseif id == "ThermalCam" then
		useThermal(player, root)
	elseif id == "Flashlight" then
		local handle = tool:FindFirstChild("Handle")
		local light = handle and handle:FindFirstChild("FlashBeam", true) :: SpotLight?
		if light then
			light.Enabled = not light.Enabled
			tool:SetAttribute("LightOn", light.Enabled)
		end
	end
end

-- Extra bits on a fresh plain tool: the flashlight's beam, the saw's sparks.
local function dressTool(tool: Tool, id: string)
	local handle = tool:FindFirstChild("Handle") :: BasePart?
	if not handle then
		return
	end
	if id == "Flashlight" then
		local att = handle:FindFirstChild("Beam") :: Attachment?
		local light = Instance.new("SpotLight")
		light.Name = "FlashBeam"
		light.Face = Enum.NormalId.Front
		light.Range = Cfg.FlashRange
		light.Angle = Cfg.FlashAngle
		light.Brightness = Cfg.FlashBrightness
		light.Color = Cfg.FlashColor
		light.Shadows = true
		light.Parent = att or handle
		tool:SetAttribute("LightOn", true)
	elseif id == "RescueSaw" then
		local pe = Instance.new("ParticleEmitter")
		pe.Name = "SawSparks"
		pe.Enabled = false
		pe.Rate = 120
		pe.Lifetime = NumberRange.new(0.15, 0.35)
		pe.Speed = NumberRange.new(14, 26)
		pe.SpreadAngle = Vector2.new(35, 35)
		pe.LightEmission = 1
		pe.Color = ColorSequence.new(Color3.fromHex("#FFE45C"), Color3.fromHex("#FF8A1F"))
		pe.Size = NumberSequence.new(0.18, 0)
		pe.Parent = handle
	end
	tool.ToolTip = (function()
		local def = ItemDefs.get(id)
		return if def and def.blurb then `{def.name}: {def.blurb}` else tool.ToolTip
	end)()
end

local function hookTool(player: Player, tool: Instance)
	if not tool:IsA("Tool") or hookedTools[tool] then
		return
	end
	local id = tool:GetAttribute("InvItem")
	if type(id) ~= "string" then
		return
	end
	hookedTools[tool] = true
	if not AXES[id] then
		dressTool(tool, id)
	end
	tool.Activated:Connect(function()
		if player.Character == tool.Parent then
			task.spawn(onUse, player, tool)
		end
	end)
end

-- kicks --------------------------------------------------------------------------------------------
local function kick(player: Player, door: BasePart, force: boolean?): boolean
	local s = stateOf(player)
	local char, root = charOf(player)
	if not char or not root or downed(player) or door:GetAttribute(Names.Attr.Broken) == true then
		return false
	end
	if not Net.near(player, door.Position, Cfg.Reach + 3) then
		return false
	end
	local now = os.clock()
	if now - s.lastKick < Cfg.KickCooldown then
		return false
	end
	s.lastKick = now
	Telemetry.count("gear_kicks")
	if door:GetAttribute(Names.Attr.Locked) ~= true then
		call("ToolService", "HitDoor", player, door, ToolConfig.DoorHits) -- an unlocked door just bursts open
		fx("kick", door.Position)
		Popup.show(door, "HI-YAH!", "good", player)
		return true
	end
	local tries = kickTries[door] or 0
	local chance = Progression.kickChance(s.level, tries)
	local win = if force ~= nil then force else math.random() < chance
	if win then
		kickTries[door] = nil
		call("ToolService", "HitDoor", player, door, ToolConfig.DoorHits)
		fx("kick", door.Position)
		Popup.show(door, "KICKED IT IN!", "good", player)
		return true
	end
	kickTries[door] = tries + 1
	Telemetry.count("gear_kick_fails")
	fx("kickfail", door.Position)
	local back = flat(root.Position - door.Position)
	pcall(Ragdoll.enable, char, Cfg.KickFailRagdoll)
	pcall(Ragdoll.knockback, char, back * Cfg.KickFailPush + Vector3.new(0, Cfg.KickFailLift, 0))
	local quips = { "OW! The door won.", "BOING! Not even a dent.", "Ouch, my everything.", "The door is unimpressed." }
	Popup.show(player, quips[math.random(1, #quips)], "blame", player)
	return false
end

local function refreshKickPrompt(door: BasePart, prompt: ProximityPrompt)
	prompt.Enabled = door:GetAttribute(Names.Attr.Locked) == true and door:GetAttribute(Names.Attr.Broken) ~= true
end

local function hookDoor(inst: Instance)
	if not inst:IsA("BasePart") or hookedDoors[inst] or not inst:IsDescendantOf(workspace) then
		return
	end
	local door = inst :: BasePart
	hookedDoors[door] = true
	local att = Instance.new("Attachment")
	att.Name = "KickPoint"
	att.Parent = door
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "KickPrompt"
	prompt.ActionText = "Kick door"
	prompt.ObjectText = "Locked"
	prompt.KeyboardKeyCode = Cfg.KickKey
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 7
	prompt.RequiresLineOfSight = false
	prompt.UIOffset = Vector2.new(0, -60)
	prompt.Parent = att
	refreshKickPrompt(door, prompt)
	for _, a in { Names.Attr.Locked, Names.Attr.Broken } do
		door:GetAttributeChangedSignal(a):Connect(function()
			refreshKickPrompt(door, prompt)
		end)
	end
	prompt.Triggered:Connect(function(player: Player)
		kick(player, door, nil)
	end)
end

-- climbing through broken windows ------------------------------------------------------------------
local function floorBelow(pos: Vector3, exclude: { Instance }): number?
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Exclude
	rp.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(pos + Vector3.new(0, 1, 0), Vector3.new(0, -16, 0), rp)
	return hit and hit.Position.Y or nil
end

local function climbThrough(player: Player, pane: BasePart): boolean
	local char, root = charOf(player)
	if not char or not root or downed(player) or pane:GetAttribute(Names.Attr.Broken) ~= true then
		return false
	end
	if not Net.near(player, pane.Position, Cfg.ClimbPromptDistance + 4) then
		return false
	end
	local normal = flat(pane.CFrame.LookVector)
	local side = if (root.Position - pane.Position):Dot(normal) >= 0 then 1 else -1
	local into = -normal * side
	local target = pane.Position + into * Cfg.ClimbThrough
	local floorY = floorBelow(target, { char, pane })
	local y = if floorY then floorY + 3 else pane.Position.Y - pane.Size.Y / 2 + 3
	local at = Vector3.new(target.X, y, target.Z)
	char:PivotTo(CFrame.lookAt(at, at + into))
	root.AssemblyLinearVelocity = into * 6
	Telemetry.count("gear_climbs")
	fx("climb", at)
	Popup.show(player, "Climbed through!", "good", player)
	return true
end

local function refreshClimb(pane: BasePart)
	local att = pane:FindFirstChild("ClimbPoint")
	local prompt = att and att:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.Enabled = pane:GetAttribute(Names.Attr.Broken) == true
	end
end

local function hookWindow(inst: Instance)
	if not inst:IsA("BasePart") or hookedWindows[inst] or not inst:IsDescendantOf(workspace) then
		return
	end
	local pane = inst :: BasePart
	-- only real building windows (an IncidentSite or a building Model), not shop props
	if not siteOf(pane) and not pane:FindFirstAncestorWhichIsA("Model") then
		return
	end
	hookedWindows[pane] = true
	local function ensurePrompt()
		if pane:GetAttribute(Names.Attr.Broken) ~= true or pane:FindFirstChild("ClimbPoint") then
			refreshClimb(pane)
			return
		end
		local att = Instance.new("Attachment")
		att.Name = "ClimbPoint"
		att.Parent = pane
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ClimbPrompt"
		prompt.ActionText = "Climb through"
		prompt.ObjectText = "Broken window"
		prompt.HoldDuration = 0.35
		prompt.MaxActivationDistance = Cfg.ClimbPromptDistance
		prompt.RequiresLineOfSight = false
		prompt.Parent = att
		prompt.Triggered:Connect(function(player: Player)
			climbThrough(player, pane)
		end)
		refreshClimb(pane)
	end
	pane:GetAttributeChangedSignal(Names.Attr.Broken):Connect(ensurePrompt)
	ensurePrompt()
end

-- roof hatches -------------------------------------------------------------------------------------
local function siteParts(site: Model, roofOnly: boolean): { BasePart }
	local out: { BasePart } = {}
	for _, d in site:GetDescendants() do
		if d:IsA("BasePart") and d.CanCollide and d.Transparency < 1 and (isRoofy(d.Name) == roofOnly) then
			table.insert(out, d)
		end
	end
	return out
end

local function dropInto(player: Player, hatch: BasePart): boolean
	local char, root = charOf(player)
	local site = siteOf(hatch)
	if not char or not root or not site then
		return false
	end
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = siteParts(site, false)
	local from = hatch.Position - Vector3.new(0, 1.5, 0)
	local hit = workspace:Raycast(from, Vector3.new(0, -60, 0), rp)
	if not hit or hit.Instance == hatch then
		say(player, "It's a long way down... nothing to land on")
		return false
	end
	local at = hit.Position + Vector3.new(0, 3, 0)
	char:PivotTo(CFrame.new(at) * root.CFrame.Rotation)
	root.AssemblyLinearVelocity = Vector3.new(0, -8, 0)
	Telemetry.count("gear_hatch_drops")
	fx("hatch", at)
	Popup.show(player, "Dropped in through the roof!", "good", player)
	return true
end

openHatch = function(player: Player, hatch: BasePart)
	if hatch:GetAttribute("Open") ~= true then
		hatch:SetAttribute("Open", true)
		local lid = hatch:FindFirstChild("Lid")
		if lid and lid:IsA("BasePart") then
			lid.CFrame = hatch.CFrame * CFrame.new(0, hatch.Size.Y / 2 + 1.6, hatch.Size.Z / 2) * CFrame.Angles(math.rad(80), 0, 0)
		end
		hatch.Color = Color3.fromHex("#151515")
		fx("hatch", hatch.Position)
	end
	dropInto(player, hatch)
end

local buildHatch: (site: Model) -> ()

local function hookSite(inst: Instance)
	if not inst:IsA("Model") or hookedSites[inst] or not inst:IsDescendantOf(workspace) then
		return
	end
	local site = inst :: Model
	hookedSites[site] = true
	task.delay(1, function() -- builders finish the model after tagging
		if site.Parent then
			buildHatch(site)
		end
	end)
end

buildHatch = function(site: Model)
	if site:FindFirstChild("RoofHatch", true) then
		return
	end
	local roofs: { BasePart } = {}
	for _, d in site:GetDescendants() do
		if d:IsA("BasePart") and string.match(d.Name, "^Roof") and d.CanCollide and d.Size.X >= 6 and d.Size.Z >= 6 then
			table.insert(roofs, d)
		end
	end
	if #roofs == 0 then
		return
	end
	table.sort(roofs, function(a: BasePart, b: BasePart): boolean
		return a.Position.Y + a.Size.Y / 2 > b.Position.Y + b.Size.Y / 2
	end)
	local roof = roofs[1]
	local rp = RaycastParams.new()
	rp.FilterType = Enum.RaycastFilterType.Include
	rp.FilterDescendantsInstances = roofs
	-- a quarter of the way along the roof so it isn't on the ridge
	local probe = (roof.CFrame * CFrame.new(roof.Size.X * 0.2, 0, roof.Size.Z * 0.15)).Position
	local hit = workspace:Raycast(probe + Vector3.new(0, 30, 0), Vector3.new(0, -60, 0), rp)
	if not hit then
		return
	end
	local up = hit.Normal
	local fwd = flat(roof.CFrame.LookVector)
	local right = fwd:Cross(up)
	if right.Magnitude < 1e-3 then
		right = Vector3.new(1, 0, 0)
	end
	right = right.Unit
	local look = up:Cross(right).Unit
	local cf = CFrame.fromMatrix(hit.Position + up * (Cfg.HatchSize.Y / 2), right, up, -look)
	local hatch = Instance.new("Part")
	hatch.Name = "RoofHatch"
	hatch.Size = Cfg.HatchSize
	hatch.CFrame = cf
	hatch.Color = Color3.fromHex("#55595E")
	hatch.Material = Enum.Material.DiamondPlate
	hatch.Anchored = true
	hatch.CanCollide = false
	hatch.CanQuery = false
	hatch.CanTouch = false
	hatch.CastShadow = false
	hatch:AddTag("RoofHatch")
	hatch.Parent = site
	local lid = Instance.new("Part")
	lid.Name = "Lid"
	lid.Size = Cfg.HatchSize * Vector3.new(0.85, 0.6, 0.85)
	lid.CFrame = cf * CFrame.new(0, Cfg.HatchSize.Y * 0.6, 0)
	lid.Color = Color3.fromHex("#C8232B")
	lid.Material = Enum.Material.Metal
	lid.Anchored = true
	lid.CanCollide = false
	lid.CanQuery = false
	lid.Parent = hatch
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "HatchPrompt"
	prompt.ActionText = "Drop in"
	prompt.ObjectText = "Roof hatch"
	prompt.HoldDuration = Cfg.HatchOpenSeconds
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("GearHatch", true) -- GearController shortens the hold for pry-bar holders
	prompt.Parent = hatch
	prompt.Triggered:Connect(function(player: Player)
		openHatch(player, hatch)
	end)
end

-- racks: loadout pegs and the locker --------------------------------------------------------------
local function rackOwner(board: BasePart): Player?
	local helmet = board:GetAttribute(Names.Attr.Helmet) or board:GetAttribute(Names.Attr.Slot)
	if helmet == nil then
		return nil
	end
	for _, p in Players:GetPlayers() do
		if p:GetAttribute(Names.Attr.Helmet) == helmet then
			return p
		end
	end
	return nil
end

local function setPeg(peg: Peg, id: string?)
	if peg.display then
		peg.display:Destroy()
		peg.display = nil
	end
	peg.id = id
	peg.stocked = id ~= nil
	peg.part:SetAttribute("Item", id or "")
	peg.prompt.Enabled = id ~= nil
	if not id then
		return
	end
	local def = ItemDefs.get(id)
	peg.prompt.ActionText = `Grab {if def then def.name else id}`
	local m = ItemProps.build(id, "display", 0.62)
	m.Name = "InvDisplay" -- InventoryController highlights it when the prompt shows
	m:PivotTo(peg.part.CFrame)
	local w = Instance.new("WeldConstraint")
	w.Part0 = peg.part
	w.Part1 = m.PrimaryPart
	w.Parent = m
	m.Parent = peg.part
	peg.display = m
end

local function onPeg(player: Player, rack: Rack, peg: Peg)
	if not peg.stocked or not peg.id then
		return
	end
	local owner = rackOwner(rack.board)
	if owner and owner ~= player then
		say(player, `That's {owner.DisplayName}'s locker! Use your own`)
		return
	end
	if not Net.near(player, peg.part.Position, Cfg.LockerDistance + 4) then
		return
	end
	local id = peg.id
	if not Progression.isUnlocked(id, stateOf(player).level) then
		say(player, `Unlocks at Lv {Progression.unlockLevel(id)}`)
		return
	end
	if not call("InventoryService", "Give", player, id) then
		return
	end
	Telemetry.count("gear_peg_grabs")
	peg.stocked = false
	peg.prompt.Enabled = false
	if peg.display then
		for _, p in peg.display:GetDescendants() do
			if p:IsA("BasePart") then
				p.LocalTransparencyModifier = 0
				p:SetAttribute("PegT", p.Transparency)
				p.Transparency = 1
			end
		end
	end
	task.delay(Cfg.PegRestockSeconds, function()
		if peg.id ~= id or not peg.part.Parent then
			return
		end
		peg.stocked = true
		peg.prompt.Enabled = true
		if peg.display then
			for _, p in peg.display:GetDescendants() do
				if p:IsA("BasePart") then
					p.Transparency = tonumber(p:GetAttribute("PegT")) or 0
				end
			end
		end
	end)
end

local function loadoutFor(board: BasePart): ({ string }, Player?)
	local owner = rackOwner(board)
	if owner then
		return stateOf(owner).loadout, owner
	end
	return Progression.defaultLoadout(1), nil
end

local function refreshRack(rack: Rack)
	local list, owner = loadoutFor(rack.board)
	local sig = `{if owner then owner.UserId else 0}:{table.concat(list, ",")}`
	if sig == rack.sig then
		return
	end
	rack.sig = sig
	for i, peg in rack.pegs do
		peg.part:SetAttribute("Owner", if owner then owner.UserId else 0)
		setPeg(peg, list[i])
	end
end

local function hookRack(inst: Instance)
	if not inst:IsA("BasePart") or racks[inst] or not inst:IsDescendantOf(workspace) then
		return
	end
	local board = inst :: BasePart
	-- only the station's numbered racks (they carry a Slot/Helmet); truck compartments use another tag
	if board:GetAttribute(Names.Attr.Slot) == nil and board:GetAttribute(Names.Attr.Helmet) == nil then
		return
	end
	local rack: Rack = { board = board, pegs = {}, sig = "" }
	racks[board] = rack
	local holder = Instance.new("Folder")
	holder.Name = "LoadoutPegs"
	holder.Parent = board.Parent or board
	for i = 1, Progression.LoadoutSize do
		local x = (i - (Progression.LoadoutSize + 1) / 2) * 2.1
		local part = Instance.new("Part")
		part.Name = `Peg{i}`
		part.Size = Vector3.new(1.4, 1.4, 1.4)
		part.Transparency = 1
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CFrame = board.CFrame * CFrame.new(x, -0.9, -(board.Size.Z / 2 + 1.9))
		part:SetAttribute("LoadoutPeg", i)
		part.Parent = holder
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "InvPrompt"
		prompt.ActionText = "Grab"
		prompt.ObjectText = "Your locker"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = InvCfg.GrabDistance
		prompt.RequiresLineOfSight = false
		prompt.Style = Enum.ProximityPromptStyle.Custom
		prompt:SetAttribute("InvPrompt", true) -- InventoryController draws the chunky sticker
		prompt.Parent = part
		local peg: Peg = { part = part, prompt = prompt, display = nil, id = nil, stocked = false }
		table.insert(rack.pegs, peg)
		prompt.Triggered:Connect(function(player: Player)
			onPeg(player, rack, peg)
		end)
	end
	-- the locker: R opens GearController's loadout picker (client-side; it sends Gear/SetLoadout)
	local att = Instance.new("Attachment")
	att.Name = "LockerPoint"
	att.Position = Vector3.new(0, 2.2, -(board.Size.Z / 2 + 0.4))
	att.Parent = board
	local locker = Instance.new("ProximityPrompt")
	locker.Name = "LockerPrompt"
	locker.ActionText = "Open Locker"
	locker.ObjectText = "Pick your loadout"
	locker.KeyboardKeyCode = Enum.KeyCode.R
	locker.GamepadKeyCode = Enum.KeyCode.ButtonY
	locker.HoldDuration = 0
	locker.MaxActivationDistance = Cfg.LockerDistance
	locker.RequiresLineOfSight = false
	locker:SetAttribute("GearLocker", true)
	locker.Parent = att
	-- a little "LOCKER" sign over the rack
	local sign = Instance.new("SurfaceGui")
	sign.Name = "LockerSign"
	sign.Face = Enum.NormalId.Front
	sign.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	sign.PixelsPerStud = 40
	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0.12, 0)
	label.Position = UDim2.new(0, 0, 0.02, 0)
	label.Font = Enum.Font.LuckiestGuy
	label.TextScaled = true
	label.TextColor3 = Color3.fromHex("#FFF1D6")
	label.Text = "LOCKER [R]"
	-- each client shows it for its own input (ClientLib/InputHints): phones tap the prompt, no [R]
	label:SetAttribute("HintText", "LOCKER [R]")
	label:SetAttribute("HintTouch", "LOCKER")
	label:SetAttribute("HintGamepad", "LOCKER")
	label:AddTag("InputHint")
	label.Parent = sign
	sign.Parent = board
	refreshRack(rack)
end

-- progression ------------------------------------------------------------------------------------
local function levelFromAttr(player: Player): number
	local l = player:GetAttribute(DataConfig.Attr.Level)
	return if type(l) == "number" then math.max(1, math.floor(l)) else 1
end

local function publish(player: Player)
	local s = stateOf(player)
	player:SetAttribute("GearLoadout", table.concat(s.loadout, ","))
	player:SetAttribute("GearLevel", s.level)
end

local function onProfile(player: Player)
	local s = stateOf(player)
	local profile = call("DataService", "GetProfile", player)
	s.level = if type(profile) == "table" and type(profile.level) == "number" then profile.level else levelFromAttr(player)
	local saved = if type(profile) == "table" and type(profile.gear) == "table" then profile.gear.loadout else nil
	local loadout = Progression.sanitizeLoadout(saved, s.level)
	if #loadout == 0 then
		loadout = Progression.defaultLoadout(s.level)
	end
	s.loadout = loadout
	call("DataService", "Update", player, function(p: any)
		if type(p.gear) == "table" then
			Schema.unlockGear(p, Progression.unlockedAt(p.level))
			Schema.setLoadout(p, loadout)
		end
	end)
	publish(player)
end

local function onLevelUp(player: Player, level: number)
	local s = stateOf(player)
	local before = s.level
	if type(level) ~= "number" or level <= before then
		s.level = math.max(before, tonumber(level) or before)
		return
	end
	s.level = level
	local new = Progression.newUnlocks(before, level)
	if #new > 0 then
		call("DataService", "Update", player, function(p: any)
			if type(p.gear) == "table" then
				Schema.unlockGear(p, new)
			end
		end)
		Telemetry.count("gear_unlocks", #new)
		-- a fresh unlock goes straight onto an empty peg of your rack
		if #s.loadout < Progression.LoadoutSize then
			local list = table.clone(s.loadout)
			for _, id in new do
				table.insert(list, id)
			end
			s.loadout = Progression.sanitizeLoadout(list, level)
		end
	end
	if UnlockedRemote then
		UnlockedRemote:FireClient(player, level, new)
	end
	publish(player)
end

-- service ------------------------------------------------------------------------------------------
function GearService:Init(all: { [string]: any })
	services = all
end

local function watchTag(tag: string, fn: (Instance) -> ())
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst: Instance)
		task.defer(fn, inst)
	end)
	task.spawn(function()
		for i, inst in CollectionService:GetTagged(tag) do
			fn(inst)
			if i % 50 == 0 then
				task.wait()
			end
		end
	end)
end

local function hookPlayer(player: Player)
	stateOf(player)
	local function onChar(char: Model)
		char.ChildAdded:Connect(function(child: Instance)
			hookTool(player, child)
		end)
		for _, c in char:GetChildren() do
			hookTool(player, c)
		end
	end
	player.CharacterAdded:Connect(onChar)
	if player.Character then
		task.spawn(onChar, player.Character)
	end
	player:GetAttributeChangedSignal(Names.Attr.Helmet):Connect(function()
		for _, rack in racks do
			refreshRack(rack)
		end
	end)
	-- no DataService (or it already loaded): fall back to the Level attr
	task.delay(2, function()
		if player.Parent and player:GetAttribute("GearLoadout") == nil then
			onProfile(player)
		end
	end)
end

function GearService:Start()
	FxRemote = Net.event("Gear", "Fx")
	UnlockedRemote = Net.event("Gear", "Unlocked")
	local SetR = Net.event("Gear", "SetLoadout")
	Net.onServer(SetR, { rate = 2, burst = 2 }, function(player: Player, ids: any)
		if type(ids) == "table" and #ids <= 12 then
			GearService:SetLoadout(player, ids)
		end
	end)

	local Data = services.DataService
	if Data then
		if Data.ProfileLoaded then
			Data.ProfileLoaded:Connect(onProfile)
		end
		if Data.LevelUp then
			Data.LevelUp:Connect(onLevelUp)
		end
	end

	Players.PlayerAdded:Connect(hookPlayer)
	for _, p in Players:GetPlayers() do
		task.spawn(hookPlayer, p)
	end
	Players.PlayerRemoving:Connect(function(player: Player)
		states[player] = nil
		for _, rack in racks do
			refreshRack(rack)
		end
	end)

	watchTag(TAG_RACK, hookRack)
	watchTag(Names.Tag.Door, hookDoor)
	watchTag(Names.Tag.Window, hookWindow)
	watchTag(SITE_TAG, hookSite)

	-- racks follow owners (Helmet attrs) and loadouts; cheap: 4 racks
	task.spawn(function()
		while true do
			task.wait(2)
			for board, rack in racks do
				if board.Parent then
					refreshRack(rack)
				else
					racks[board] = nil
				end
			end
		end
	end)
end

function GearService:LevelOf(player: Player): number
	return stateOf(player).level
end

function GearService:GetLoadout(player: Player): { string }
	return table.clone(stateOf(player).loadout)
end

function GearService:SetLoadout(player: Player, ids: { any }): boolean
	local s = stateOf(player)
	local list = Progression.sanitizeLoadout(ids, s.level)
	s.loadout = list
	call("DataService", "Update", player, function(p: any)
		if type(p.gear) == "table" then
			Schema.setLoadout(p, list)
		end
	end)
	publish(player)
	for _, rack in racks do
		refreshRack(rack)
	end
	Telemetry.count("gear_loadouts_saved")
	Popup.show(player, "Loadout saved! Your rack is restocked", "good", player)
	return true
end

-- test hooks ---------------------------------------------------------------------------------------
function GearService:_state(player: Player): { [string]: any }
	local s = stateOf(player)
	return { level = s.level, loadout = s.loadout, busy = s.busy, racks = (function()
		local n = 0
		for _ in racks do
			n += 1
		end
		return n
	end)(), ladders = #ladders }
end

function GearService:_setLevel(player: Player, level: number)
	local before = stateOf(player).level
	onLevelUp(player, level)
	if level < before then
		stateOf(player).level = level
		publish(player)
	end
end

function GearService:_use(player: Player, id: string?): boolean
	local char = player.Character
	local tool = char and char:FindFirstChildOfClass("Tool")
	if not tool or (id and tool:GetAttribute("InvItem") ~= id) then
		return false
	end
	hookTool(player, tool)
	onUse(player, tool)
	return true
end

function GearService:_kick(player: Player, door: BasePart?, force: boolean?): boolean
	local _, root = charOf(player)
	local d = door or (root and nearestInFront(root, taggedNear(Names.Tag.Door, root, closedDoor)))
	if not d then
		return false
	end
	stateOf(player).lastKick = 0
	return kick(player, d, force)
end

function GearService:_climb(player: Player, window: BasePart): boolean
	return climbThrough(player, window)
end

function GearService:_hatch(player: Player, hatch: BasePart?): boolean
	local h = hatch
	if not h then
		local _, root = charOf(player)
		local best, bestD = nil :: BasePart?, math.huge
		for _, inst in CollectionService:GetTagged("RoofHatch") do
			if inst:IsA("BasePart") and root then
				local d = (inst.Position - root.Position).Magnitude
				if d < bestD then
					best, bestD = inst, d
				end
			end
		end
		h = best
	end
	if not h then
		return false
	end
	openHatch(player, h)
	return true
end

function GearService:_selftest(): (boolean, string)
	for _, r in { "Fx", "Unlocked", "SetLoadout" } do
		local net = ReplicatedStorage:FindFirstChild("Net")
		local ns = net and net:FindFirstChild("Gear")
		if not (ns and ns:FindFirstChild(r)) then
			return false, `Gear/{r} remote missing`
		end
	end
	for _, id in ItemDefs.GearOrder do
		local m = ItemProps.build(id, "world")
		local ok = m.PrimaryPart ~= nil
		m:Destroy()
		if not ok then
			return false, `ItemProps {id} has no Handle`
		end
	end
	return true, "ok"
end

return GearService
