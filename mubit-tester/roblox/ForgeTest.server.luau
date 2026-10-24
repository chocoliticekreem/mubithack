-- ForgeTest: in-game test harness for the mubit-tester MCP server (Studio only). docs/TESTER.md.
--
-- ServerStorage.ForgeTest (BindableFunction)
--   :Invoke(cmd: string, argsJson: string?) -> JSON string {"ok": bool, "result": any, "error": string?}
--   cmds: ping, caps, players, observe, act, query, inspect, set_attr, ignite, extinguish, teleport,
--         config, counters, events, reset, round, blame, hook,
--         teleport_stage, obby_try   (obbies: parts tagged Checkpoint with a Stage attribute, KillPart hazards)
--         ui, ui_target, ui_effect   (the player's GUI buttons; `press` = these + a real click, Python)
--         squads, instances, queue, launch, mission_start, mission_end   (multiplayer / co-op / squads)
--         bot_spawn, bots, bot_clear   (swarm: server-driven NPC testers, addressed like players)
--         multi   ({calls: [{cmd, args}]}: run several commands concurrently in one call)
--   Players are addressed by `userId` (also `player`): a UserId, a helmet number (1-4), or a name.
--   players/observe/query/events take an optional `instanceId` (players/events also `squadId`) so
--   one mission instance can be looked at in isolation while several run at once.
--   Every game service is optional and nil-guarded: a missing or K0-stub service (its _selftest
--   says "stub") makes the command fail with an "unsupported: ..." error, which scenarios turn
--   into a SKIP instead of a FAIL.
--
-- ReplicatedStorage.ForgeTestRemote (RemoteFunction)
--   server -> client: InvokeClient(player, "ForgeTest", cmd, args) runs an action on that player's
--   client (StarterPlayerScripts/ForgeTestAgent). Always called with a timeout, because InvokeClient
--   can hang forever. client -> server: InvokeServer("ForgeTest", "hello") marks the agent ready.
--
-- Event log: ring buffer (500) of {t, kind, data}; t is seconds since this script started (the
-- same clock as `events.now` and `ping.clock`). Player events are stamped with the player's
-- instanceId/squadId at log time. Lobby events (joined_pad, left_pad, countdown, launched) and
-- mission events (mission_state, entered_instance, delivered, overheated, downed, revived,
-- ragdolled, hose_hit, kinked, ...) come from attributes and from every Signal on the services.
--
-- Team Test with real friends: Studio MCP can't reach the cloud server, so the Python side relays
-- commands through a client: ForgeTestRemote:InvokeServer("ForgeTest", "call", cmd, argsJson).
-- Outside Studio the harness only runs if ServerStorage has a BoolValue `ForgeTestEnabled` = true
-- (remove it before publishing); relayed calls are then accepted only from the place creator or
-- the UserIds in its `AllowUserIds` attribute ("123,456").

local RunService = game:GetService("RunService")
local IS_STUDIO = RunService:IsStudio()
local enableFlag = game:GetService("ServerStorage"):FindFirstChild("ForgeTestEnabled")
if not IS_STUDIO and not (enableFlag and enableFlag:IsA("BoolValue") and enableFlag.Value) then
	return
end

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")
local StarterPlayer = game:GetService("StarterPlayer")

local VERSION = "2"
local MAX_EVENTS = 500
local HUD_TIMEOUT = 3
local DEFAULT_ACT_TIMEOUT = 10
local WALK_TIMEOUT = 20

local TAGS = {
	"Burning", "Flammable", "Door", "Hydrant", "TruckRefill", "RescueDropoff", "Rescuable", "Truck", "StationSpawn",
	"SquadPad", "MissionBoard", "Hazard",
}
local THING_ATTRS = { "Locked", "Broken", "FireLevel", "RescueState", "Kind", "PadId", "CarriedBy", "HazardId", "InstanceId" }
local ME_ATTRS = { "Water", "TankSize", "Carrying", "Helmet", "Downed", "Heat", "SquadId", "InstanceId" }
-- Services / modules the harness knows about (all optional). Their Signals are logged as events.
local KNOWN_SERVICES = {
	"LobbyService", "MissionService", "SquadService", "ToolService", "RescueService", "BlameService",
	"HeatService", "FireService", "MapService", "VehicleService", "HazardService", "Ragdoll", "HoseLine",
}
-- Signal name -> event kind (any other signal: snake_case of its name).
local SIGNAL_KINDS = {
	HoseHit = "hose_hit", Downed = "downed", Revived = "revived", Rescued = "delivered", Delivered = "delivered",
	Overheated = "overheated", Kinked = "kinked", Yanked = "hose_yanked", Tethered = "hose_yanked",
	Ragdolled = "ragdolled", PadJoined = "joined_pad", JoinedPad = "joined_pad", Joined = "joined_pad",
	PadLeft = "left_pad", LeftPad = "left_pad", Left = "left_pad", CountdownStarted = "countdown",
	Countdown = "countdown", CountdownTick = "countdown", CountdownCancelled = "countdown_cancelled",
	Launched = "launched", SquadLaunched = "launched", SquadFormed = "squad_formed", SquadDisbanded = "squad_disbanded",
	MissionStarted = "mission_started", InstanceStarted = "mission_started", MissionEnded = "mission_ended",
	InstanceEnded = "mission_ended", StateChanged = "mission_state", InstanceStateChanged = "mission_state",
	RoundStarted = "round_started", RoundEnded = "round_ended",
}
local WORLD_ATTRS = { "RoundState", "RoundEndsAt", "MissionId" }
-- RoundState values between rounds; any other value but Active (Results, Ended, ...) is a round still finishing
local ROUND_IDLE = { Lobby = true, Waiting = true, Intermission = true, Idle = true, [""] = true }
local ROUND_COOLDOWN = 30
local ACTIONS = {
	walk_to = true, jump = true, interact = true, equip = true, unequip = true,
	use = true, look_at = true, say = true, wait = true,
	go_touch = true, go_use = true, chase = true, ["repeat"] = true,
}
-- Macros: one tester decision runs a whole interaction and returns an `effect` diff.
local MACROS = { go_touch = true, go_use = true, chase = true, ["repeat"] = true }
local REPEAT_MAX = 5
local AMBIENT_WINDOW = 15 -- seconds: a counter that ticked this recently before a macro is background noise

local started = os.clock()
local function now(): number
	return math.floor((os.clock() - started) * 1000 + 0.5) / 1000
end

------------------------------------------------------------------------------- JSON

-- HttpService:JSONEncode turns {} into [], so objects that may be empty are marked with obj().
local objMarks = setmetatable({}, { __mode = "k" })
local function obj(t)
	objMarks[t] = true
	return t
end

local function r(n: number, places: number?): number
	local m = 10 ^ (places or 1)
	return math.floor(n * m + 0.5) / m
end

local function v3(v: Vector3)
	return { r(v.X), r(v.Y), r(v.Z) }
end

local function escape(s: string): string
	s = string.gsub(s, '[%c"\\]', function(c)
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. s .. '"'
end

local encode
local function encodeNumber(n: number): string
	if n ~= n or n == math.huge or n == -math.huge then
		return "null"
	end
	if n == math.floor(n) and math.abs(n) < 1e15 then
		return string.format("%d", n)
	end
	local s = string.format("%.4f", n)
	s = string.gsub(s, "0+$", "")
	s = string.gsub(s, "%.$", "")
	return s
end

function encode(v: any, depth: number?): string
	local d = depth or 0
	if d > 20 then
		return '"<depth>"'
	end
	local t = typeof(v)
	if v == nil then
		return "null"
	elseif t == "boolean" then
		return if v then "true" else "false"
	elseif t == "number" then
		return encodeNumber(v)
	elseif t == "string" then
		return escape(v)
	elseif t == "Vector3" then
		return encode(v3(v), d + 1)
	elseif t == "Vector2" then
		return encode({ r(v.X), r(v.Y) }, d + 1)
	elseif t == "CFrame" then
		return encode(v3(v.Position), d + 1)
	elseif t == "Color3" then
		return escape("#" .. v:ToHex())
	elseif t == "EnumItem" then
		return escape(v.Name)
	elseif t == "Instance" then
		return escape(v:GetFullName())
	elseif t == "table" then
		local n = #v
		local count = 0
		for _ in v do
			count += 1
		end
		if count == 0 then
			return if objMarks[v] then "{}" else "[]"
		end
		local parts = {}
		if count == n and not objMarks[v] then
			for i = 1, n do
				parts[i] = encode(v[i], d + 1)
			end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, val in v do
			table.insert(parts, escape(tostring(k)) .. ":" .. encode(val, d + 1))
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return escape(tostring(v))
end

-- Attribute / config values as plain JSON-able values.
local function val(v: any): any
	local t = typeof(v)
	if v == nil then
		return nil
	elseif t == "number" then
		return r(v, 2)
	elseif t == "boolean" or t == "string" then
		return v
	elseif t == "Vector3" then
		return v3(v)
	end
	return tostring(v)
end

local function attrsOf(inst: Instance, keys: { string }?)
	local out = obj({})
	if keys then
		for _, k in keys do
			local v = inst:GetAttribute(k)
			if v ~= nil then
				out[k] = val(v)
			end
		end
	else
		for k, v in inst:GetAttributes() do
			out[k] = val(v)
		end
	end
	return out
end

------------------------------------------------------------------------------- helpers

local function posOf(inst: Instance?): Vector3?
	if not inst then
		return nil
	end
	if type(inst) == "table" and (inst :: any).IsBot then -- a swarm bot (see botSpawn)
		local char = (inst :: any).Character
		local root = char and char.Parent and char:FindFirstChild("HumanoidRootPart")
		return root and root.Position or nil
	end
	if inst:IsA("BasePart") then
		return inst.Position
	end
	if inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	if inst:IsA("Model") then
		local ok, cf = pcall(inst.GetPivot, inst)
		if ok then
			return cf.Position
		end
	end
	if inst:IsA("Player") then
		local root = inst.Character and inst.Character:FindFirstChild("HumanoidRootPart")
		return root and root.Position or nil
	end
	local part = inst:FindFirstAncestorWhichIsA("BasePart")
	return part and part.Position or nil
end

-- "Workspace.Map.Station.Door" (GetFullName form, optional "game." prefix). Names may contain dots,
-- so every split is tried.
local function resolvePath(path: any): Instance?
	if typeof(path) == "Instance" then
		return path
	end
	if type(path) ~= "string" or path == "" then
		return nil
	end
	local segs = string.split(path, ".")
	local first = 1
	if segs[1] == "game" then
		first = 2
	end
	local function walk(node: Instance, i: number): Instance?
		if i > #segs then
			return node
		end
		local name = segs[i]
		for j = i, #segs do
			if j > i then
				name = name .. "." .. segs[j]
			end
			local child = node:FindFirstChild(name)
			if not child and node == game then
				local ok, svc = pcall(game.GetService, game, name)
				if ok then
					child = svc
				end
			end
			if child then
				local found = walk(child, j + 1)
				if found then
					return found
				end
			end
		end
		return nil
	end
	return walk(game, first)
end

local function mustPath(path: any): Instance
	local inst = resolvePath(path)
	if not inst then
		error("no instance at path " .. tostring(path))
	end
	return inst
end

local function toVec(v: any): Vector3?
	if typeof(v) == "Vector3" then
		return v
	end
	if type(v) == "table" and tonumber(v[1]) and tonumber(v[2]) and tonumber(v[3]) then
		return Vector3.new(tonumber(v[1]), tonumber(v[2]), tonumber(v[3]))
	end
	if type(v) == "table" and tonumber(v.x or v.X) then
		return Vector3.new(tonumber(v.x or v.X), tonumber(v.y or v.Y) or 0, tonumber(v.z or v.Z) or 0)
	end
	return nil
end

local joinOrder: { Player } = {}

-- Swarm bots: server-driven NPC testers (bot_spawn). Each is a proxy table that quacks like a
-- Player for the harness (UserId -1001, -1002, ..., Name, Character, GetAttribute), so observe /
-- act / teleport / players address them by name or UserId. The game only sees their bodies (touch,
-- physics, collisions), not a Player, so Player-keyed features (leaderstats, GUIs, prompts) ignore them.
local bots: { any } = {}
local BotProxy = {}
BotProxy.__index = BotProxy
function BotProxy:GetAttribute(k: string): any
	local m = self.Character
	return if m and m.Parent then m:GetAttribute(k) else nil
end
function BotProxy:SetAttribute(k: string, v: any)
	if self.Character then
		self.Character:SetAttribute(k, v)
	end
end
function BotProxy:GetAttributes()
	return if self.Character then self.Character:GetAttributes() else {}
end
function BotProxy:FindFirstChildOfClass(_c: string): Instance?
	return nil
end
function BotProxy:FindFirstChild(_n: string): Instance?
	return nil
end
function BotProxy:IsA(_c: string): boolean
	return false
end

-- (a real Player errors on unknown members, so never index .IsBot on one)
local function isBot(p: any): boolean
	return type(p) == "table" and p.IsBot == true
end

local function findBot(id: any): any?
	if id == nil then
		return nil
	end
	local n, s = tonumber(id), string.lower(tostring(id))
	for _, b in bots do
		if (n and b.UserId == n) or string.lower(b.Name) == s then
			return b
		end
	end
	return nil
end

local function playerList(): { Player }
	local out = {}
	for _, p in joinOrder do
		if p.Parent == Players then
			table.insert(out, p)
		end
	end
	for _, p in Players:GetPlayers() do
		if not table.find(out, p) then
			table.insert(out, p)
		end
	end
	return out
end

-- UserId, helmet number (1-4), join index, or name / display name (case-insensitive, then prefix).
-- With no id and exactly one player, that player.
local function resolvePlayer(id: any): Player
	local list = playerList()
	if id == nil or id == "" then
		if #list == 1 then
			return list[1]
		end
		error(if #list == 0 then "no players in game" else "userId required (" .. #list .. " players)")
	end
	if typeof(id) == "Instance" and id:IsA("Player") then
		return id
	end
	if type(id) == "table" and id.IsBot then
		return id
	end
	local bot = findBot(id)
	if bot then
		return bot
	end
	local n = tonumber(id)
	if n then
		for _, p in list do
			if p.UserId == n then
				return p
			end
		end
		for _, p in list do
			if p:GetAttribute("Helmet") == n then
				return p
			end
		end
		if n >= 1 and n == math.floor(n) and list[n] then
			return list[n]
		end
		error("no player with userId/helmet " .. tostring(id))
	end
	local s = string.lower(tostring(id))
	for _, p in list do
		if string.lower(p.Name) == s or string.lower(p.DisplayName) == s then
			return p
		end
	end
	for _, p in list do
		if string.sub(string.lower(p.Name), 1, #s) == s or string.sub(string.lower(p.DisplayName), 1, #s) == s then
			return p
		end
	end
	error("no player named " .. tostring(id))
end

local function playerArg(args): Player
	local id = args.userId
	if id == nil then
		id = args.player
	end
	return resolvePlayer(id)
end

local moduleCache: { [string]: ModuleScript } = {}
local function findModule(name: string): ModuleScript?
	local cached = moduleCache[name]
	if cached and cached.Parent and cached.Name == name then
		return cached
	end
	for _, container in { ServerScriptService, ServerStorage, ReplicatedStorage } do
		for _, d in container:GetDescendants() do
			if d.Name == name and d:IsA("ModuleScript") then
				moduleCache[name] = d
				return d
			end
		end
	end
	return nil
end

-- The live module table (same VM as Main.server, so the same require cache), or nil.
local function liveModule(name: string): any
	local ms = findModule(name)
	if not ms then
		return nil
	end
	local ok, mod = pcall(require, ms)
	if ok and type(mod) == "table" then
		return mod
	end
	return nil
end

------------------------------------------------------------------------------- event log

local events: { { t: number, kind: string, data: any } } = {}

local function nonEmpty(v: any): string?
	if type(v) == "string" and v ~= "" then
		return v
	end
	if type(v) == "number" then
		return tostring(v)
	end
	return nil
end

local function log(kind: string, data: any, coalesceKey: string?)
	data = obj(data or {})
	-- Stamp the player's current mission instance / squad so events can be scoped by instanceId.
	if data.userId ~= nil and (data.instanceId == nil or data.squadId == nil) then
		local ok, p = pcall(Players.GetPlayerByUserId, Players, tonumber(data.userId) or 0)
		if ok and p then
			if data.instanceId == nil then
				data.instanceId = nonEmpty(p:GetAttribute("InstanceId"))
			end
			if data.squadId == nil then
				data.squadId = nonEmpty(p:GetAttribute("SquadId"))
			end
		end
	end
	local t = now()
	local last = events[#events]
	-- Coalesce bursts (Water draining while spraying, counters ticking) into the latest entry.
	if coalesceKey and last and last.kind == kind and last.ckey == coalesceKey and t - last.t < 1 then
		if data.delta and last.data.delta then
			data.delta += last.data.delta
		end
		if last.data.old ~= nil and data.old ~= nil then
			data.old = last.data.old
		end
		last.data = data
		last.t = t
		return
	end
	table.insert(events, { t = t, kind = kind, data = data, ckey = coalesceKey })
	if #events > MAX_EVENTS then
		table.remove(events, 1)
	end
end

local function who(p: Player)
	return { userId = p.UserId, name = p.Name, helmet = p:GetAttribute("Helmet") }
end

local function with(base, extra)
	for k, v in extra do
		base[k] = v
	end
	return base
end

local hookedTools = setmetatable({}, { __mode = "k" })
local PLAYER_ATTRS = {
	Water = true, Carrying = true, Downed = true, Helmet = true, SquadId = true, InstanceId = true, Heat = true,
	Ragdolled = true, HoseKinkedBy = true,
}

local function hookTool(tool: Tool, player: Player)
	if hookedTools[tool] then
		return
	end
	hookedTools[tool] = true
	tool.Activated:Connect(function()
		log("tool_activated", with(who(player), { tool = tool.Name }))
	end)
	tool.Deactivated:Connect(function()
		log("tool_deactivated", with(who(player), { tool = tool.Name }))
	end)
end

local agents: { [Player]: number } = {}

local function hookCharacter(player: Player, char: Model)
	log("character_added", who(player))
	local hum = char:WaitForChild("Humanoid", 10) :: Humanoid?
	if hum then
		hum.Died:Connect(function()
			log("player_died", with(who(player), { pos = posOf(player) }))
		end)
	end
	char.ChildAdded:Connect(function(c)
		if c:IsA("Tool") then
			hookTool(c, player)
			log("tool_equipped", with(who(player), { tool = c.Name }))
		end
	end)
	char.ChildRemoved:Connect(function(c)
		if c:IsA("Tool") then
			log("tool_unequipped", with(who(player), { tool = c.Name }))
		end
	end)
	for _, c in char:GetChildren() do
		if c:IsA("Tool") then
			hookTool(c, player)
		end
	end
	char.AttributeChanged:Connect(function(key)
		if PLAYER_ATTRS[key] then
			local v = char:GetAttribute(key)
			log("attr", with(who(player), { on = "character", key = key, value = val(v) }), "char:" .. player.UserId .. ":" .. key)
			if key == "Ragdolled" then
				log(if v == true then "ragdolled" else "unragdolled", with(who(player), { via = "attr" }))
			elseif key == "Downed" then
				log(if v == true then "downed" else "revived", with(who(player), { via = "attr" }))
			end
		end
	end)
end

-- Lobby / mission transitions derived from player attributes (work whatever the signals are named).
local function playerTransition(player: Player, key: string, v: any, old: any)
	local base = who(player)
	if key == "SquadId" then
		local sid, oldSid = nonEmpty(v), nonEmpty(old)
		if sid then
			log("joined_pad", with(base, { squadId = sid, via = "attr" }))
		elseif oldSid then
			log("left_pad", with(base, { squadId = oldSid, via = "attr" }))
		end
	elseif key == "InstanceId" then
		local iid, oldIid = nonEmpty(v), nonEmpty(old)
		if iid then
			log("entered_instance", with(base, { instanceId = iid, via = "attr" }))
		elseif oldIid then
			log("left_instance", with(base, { instanceId = oldIid, via = "attr" }))
		end
	elseif key == "Heat" then
		if (tonumber(v) or 0) >= 100 and (tonumber(old) or 0) < 100 then
			log("overheated", with(base, { heat = val(v), via = "attr" }))
		end
	elseif key == "Downed" then
		if v == true and old ~= true then
			log("downed", with(base, { via = "attr" }))
		elseif v ~= true and old == true then
			log("revived", with(base, { via = "attr" }))
		end
	elseif key == "Ragdolled" then
		log(if v == true then "ragdolled" else "unragdolled", with(base, { via = "attr" }))
	elseif key == "HoseKinkedBy" then
		if v ~= nil and old == nil then
			log("kinked", with(base, { by = val(v), via = "attr" }))
		end
	end
end

local function hookPlayer(player: Player)
	if not table.find(joinOrder, player) then
		table.insert(joinOrder, player)
	end
	log("player_added", who(player))
	local last: { [string]: any } = {}
	for k in PLAYER_ATTRS do
		last[k] = player:GetAttribute(k)
	end
	player.AttributeChanged:Connect(function(key)
		if PLAYER_ATTRS[key] then
			local v = player:GetAttribute(key)
			local old = last[key]
			local data = with(who(player), { on = "player", key = key, value = val(v), old = val(old) })
			last[key] = v
			-- an instance/squad change is stamped with the new id by log(); keep the old one visible
			log("attr", data, "player:" .. player.UserId .. ":" .. key)
			playerTransition(player, key, v, old)
		end
	end)
	player.CharacterAdded:Connect(function(char)
		hookCharacter(player, char)
	end)
	if player.Character then
		task.spawn(hookCharacter, player, player.Character)
	end
end

Players.PlayerAdded:Connect(hookPlayer)
for _, p in Players:GetPlayers() do
	task.spawn(hookPlayer, p)
end
Players.PlayerRemoving:Connect(function(p)
	log("player_removed", who(p))
	agents[p] = nil
	local i = table.find(joinOrder, p)
	if i then
		table.remove(joinOrder, i)
	end
end)

ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
	log("prompt_triggered", with(who(player), {
		prompt = prompt:GetFullName(),
		action = prompt.ActionText,
		object = prompt.ObjectText,
	}))
end)

local rescueConns: { [Instance]: RBXScriptConnection } = {}
local instanceIdOfInst -- forward: (Instance) -> string?, defined with the mission instance helpers
local function hookRescuable(inst: Instance)
	if rescueConns[inst] then
		return
	end
	rescueConns[inst] = inst:GetAttributeChangedSignal("RescueState"):Connect(function()
		local state = inst:GetAttribute("RescueState")
		local iid = instanceIdOfInst and instanceIdOfInst(inst) or nil
		log("attr", { on = inst:GetFullName(), key = "RescueState", value = val(state), instanceId = iid })
		if state == "Rescued" then
			local carrier = tonumber(inst:GetAttribute("CarriedBy"))
			log("delivered", {
				path = inst:GetFullName(), kind = val(inst:GetAttribute("Kind")), rescueId = val(inst:GetAttribute("RescueId")),
				instanceId = iid, by = carrier, via = "attr",
			})
		end
	end)
end
local function watchTag(tag: string)
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
		local iid = instanceIdOfInst and instanceIdOfInst(inst) or nil
		log("tag_added", { tag = tag, path = inst:GetFullName(), pos = posOf(inst), instanceId = iid })
		if tag == "Rescuable" then
			hookRescuable(inst)
		end
	end)
	CollectionService:GetInstanceRemovedSignal(tag):Connect(function(inst)
		log("tag_removed", { tag = tag, path = inst:GetFullName() })
		if tag == "Rescuable" and rescueConns[inst] then
			rescueConns[inst]:Disconnect()
			rescueConns[inst] = nil
		end
	end)
end
watchTag("Burning")
watchTag("Rescuable")
for _, inst in CollectionService:GetTagged("Rescuable") do
	hookRescuable(inst)
end

workspace.AttributeChanged:Connect(function(key)
	if key == "RoundState" or key == "MissionId" then
		log("attr", { on = "Workspace", key = key, value = val(workspace:GetAttribute(key)) })
	end
end)

-- ForgeTelemetry.count writes number attributes on ServerStorage.ForgeCounters; watching the folder
-- sees every count from every script (no need to wrap the module function).
local counterCache: { [string]: number } = {}
local hookedCounters: Instance? = nil
local function hookCounters(f: Instance)
	if hookedCounters == f then
		return
	end
	hookedCounters = f
	for k, v in f:GetAttributes() do
		if type(v) == "number" then
			counterCache[k] = v
		end
	end
	f.AttributeChanged:Connect(function(key)
		local v = f:GetAttribute(key)
		if type(v) ~= "number" then
			return
		end
		local old = counterCache[key] or 0
		counterCache[key] = v
		log("count", { name = key, delta = r(v - old, 2), value = r(v, 2) }, "count:" .. key)
	end)
end
ServerStorage.ChildAdded:Connect(function(c)
	if c.Name == "ForgeCounters" then
		hookCounters(c)
	end
end)
if ServerStorage:FindFirstChild("ForgeCounters") then
	hookCounters(ServerStorage.ForgeCounters)
end

local function counters()
	local out = obj({})
	local f = ServerStorage:FindFirstChild("ForgeCounters")
	if f then
		for k, v in f:GetAttributes() do
			if type(v) == "number" then
				out[k] = r(v, 2)
			end
		end
	end
	return out
end

------------------------------------------------------------------------------- client remote

local function getOrCreate(parent: Instance, name: string, className: string): Instance
	local existing = parent:FindFirstChild(name)
	if existing then
		existing:Destroy()
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local dispatchCommand: (cmd: any, argsJson: any) -> string -- forward, defined at the bottom
-- Latest lobby countdown per pad, as forwarded by the client agents: {seconds (-1 = cancelled), at}.
local padCountdown: { [number]: { seconds: number, at: number } } = {}

-- Who may run harness commands through the client relay (Team Test: the server isn't on MCP).
local function relayAllowed(player: Player): boolean
	if IS_STUDIO and not (enableFlag and enableFlag:IsA("BoolValue")) then
		return true -- local Studio test (Play / Clients and Servers)
	end
	if game.CreatorType == Enum.CreatorType.User and player.UserId == game.CreatorId then
		return true
	end
	local allow = enableFlag and tostring(enableFlag:GetAttribute("AllowUserIds") or "") or ""
	for id in string.gmatch(allow, "%-?%d+") do
		if tonumber(id) == player.UserId then
			return true
		end
	end
	return IS_STUDIO
end

local remote = getOrCreate(ReplicatedStorage, "ForgeTestRemote", "RemoteFunction") :: RemoteFunction
-- Replicates to every client of THIS test, so Python can tell which Studio window drives which
-- player of this session (and never click into an unrelated playtest).
remote:SetAttribute("Session", HttpService:GenerateGUID(false))
remote.OnServerInvoke = function(player: Player, tag: any, cmd: any, hcmd: any, argsJson: any)
	if tag ~= "ForgeTest" then
		return false
	end
	if cmd == "hello" then
		agents[player] = now()
		log("agent_ready", who(player))
		return true
	end
	if cmd == "event" and hcmd == "ui_press" and type(argsJson) == "table" then
		-- a real click on a GUI button, reported by ForgeTestAgent after Harness.press
		local d = argsJson
		log("ui_press", with(who(player), {
			path = tostring(d.path or ""), text = tostring(d.text or ""), gui = d.gui, fired = d.fired == true,
			changed = d.changed == true, effect = if type(d.effect) == "table" then d.effect else nil,
		}))
		return true
	end
	if cmd == "event" and hcmd == "countdown" and type(argsJson) == "table" then
		-- forwarded by ForgeTestAgent from Net.Lobby.Countdown (client-only remote)
		local padId, seconds = tonumber(argsJson.padId), tonumber(argsJson.seconds)
		if padId and seconds then
			padCountdown[padId] = { seconds = seconds, at = os.clock() }
			log("countdown", with(who(player), { padId = padId, seconds = seconds, via = "client" }), "countdown:" .. padId)
		end
		return true
	end
	if cmd == "call" then
		if not relayAllowed(player) then
			return '{"ok":false,"error":"relay not allowed for this player (see ForgeTestEnabled.AllowUserIds)"}'
		end
		return dispatchCommand(hcmd, argsJson)
	end
	return false
end

-- InvokeClient can hang forever (client gone, script not loaded), so it runs in its own thread
-- and we give up after `timeout` seconds. A late reply is dropped.
local function invokeClient(player: Player, cmd: string, args: any, timeout: number): (boolean, any)
	local done, ok, res = false, false, nil
	task.spawn(function()
		local okCall, reply = pcall(remote.InvokeClient, remote, player, "ForgeTest", cmd, args)
		if done then
			return
		end
		done = true
		if not okCall then
			ok, res = false, "InvokeClient failed: " .. tostring(reply)
		elseif type(reply) ~= "table" then
			ok, res = false, "bad reply from client agent: " .. tostring(reply)
		elseif reply.ok == false then
			ok, res = false, tostring(reply.error or "client error")
		else
			ok, res = true, reply.result
		end
	end)
	local t0 = os.clock()
	while not done and os.clock() - t0 < timeout do
		task.wait(0.05)
	end
	if not done then
		done = true
		local hint = if agents[player] then "" else " (agent never said hello: is ForgeTestAgent running?)"
		return false, string.format("client %s did not answer %s within %ds%s", player.Name, cmd, timeout, hint)
	end
	return ok, res
end

------------------------------------------------------------------------------- commands

local function playerInfo(p: Player)
	local char = p.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local tool = char and char:FindFirstChildOfClass("Tool")
	local bp = {}
	local backpack = p:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, t in backpack:GetChildren() do
			if t:IsA("Tool") then
				table.insert(bp, t.Name)
			end
		end
	end
	local attrs = attrsOf(p)
	if char then
		for k, v in char:GetAttributes() do
			if attrs[k] == nil then
				attrs[k] = val(v)
			end
		end
	end
	local function attr(k)
		local v = p:GetAttribute(k)
		if v == nil and char then
			v = char:GetAttribute(k)
		end
		return v
	end
	local carrying = attr("Carrying")
	return obj({
		userId = p.UserId,
		name = p.Name,
		displayName = p.DisplayName,
		helmet = attr("Helmet"),
		pos = root and v3(root.Position) or nil,
		health = hum and r(hum.Health) or nil,
		maxHealth = hum and r(hum.MaxHealth) or nil,
		attrs = attrs,
		tool = tool and tool.Name or nil,
		backpack = bp,
		carrying = if carrying == "" then nil else carrying,
		downed = attr("Downed") == true,
		heat = val(attr("Heat")),
		ragdolled = attr("Ragdolled") == true,
		squadId = nonEmpty(attr("SquadId")),
		instanceId = nonEmpty(attr("InstanceId")),
		character = char and char:GetFullName() or nil,
		agent = agents[p] ~= nil,
		hasCharacter = char ~= nil,
		bot = if isBot(p) then true else nil,
		deaths = if isBot(p) then p.deaths else nil,
	})
end

------------------------------------------------------------------------------- services, instances, lobby

-- An error whose message starts with "unsupported:" means "the game can't do this yet" (missing or
-- stub service); scenario runners report it as SKIP, not FAIL.
local function unsupported(msg: string)
	error("unsupported: " .. msg, 0)
end

-- Any Lua value as JSON-able data (Players as {userId, name, helmet}, Instances as paths).
local function plain(v: any, depth: number?): any
	local d = depth or 0
	local t = typeof(v)
	if t == "Instance" then
		if v:IsA("Player") then
			return who(v)
		end
		return v:GetFullName()
	elseif t == "table" then
		if d > 3 then
			return "<table>"
		end
		local out = {}
		local isArr = #v > 0
		for k, x in v do
			if type(x) ~= "function" and not (type(x) == "table" and type(x.Connect) == "function") then
				if isArr and type(k) == "number" then
					out[k] = plain(x, d + 1)
				else
					out[tostring(k)] = plain(x, d + 1)
				end
			end
		end
		return if isArr then out else obj(out)
	elseif t == "function" then
		return nil
	end
	return val(v)
end

local function findMethod(mod: any, names: { string }): (string?, any)
	if type(mod) ~= "table" then
		return nil, nil
	end
	for _, n in names do
		if type(mod[n]) == "function" then
			return n, mod[n]
		end
	end
	return nil, nil
end

-- "missing" | "stub" | "live". K0 stubs answer _selftest() with (true, "stub"). Cached per session.
local statusCache: { [string]: string } = {}
local function serviceStatus(name: string): (string, any)
	local mod = liveModule(name)
	if not mod then
		return "missing", nil
	end
	local cached = statusCache[name]
	if cached then
		return cached, mod
	end
	local status = "live"
	if type(mod._selftest) == "function" then
		local done, msg = false, ""
		task.spawn(function()
			local ok, a, b = pcall(mod._selftest, mod)
			if ok then
				msg = if type(b) == "string" then b elseif type(a) == "string" then a else ""
			end
			done = true
		end)
		local t0 = os.clock()
		while not done and os.clock() - t0 < 2 do
			task.wait(0.05)
		end
		if string.lower(msg) == "stub" then
			status = "stub"
		end
	end
	statusCache[name] = status
	return status, mod
end

-- Mission instance Models / Folders (attribute InstanceId) near the top of Workspace.
local instModels: { [string]: Instance } = {}
local instModelsAt = -100
local hookedModels = setmetatable({}, { __mode = "k" })

local function hookInstanceModel(m: Instance, id: string)
	if hookedModels[m] then
		return
	end
	hookedModels[m] = true
	m.AttributeChanged:Connect(function(key)
		local v = m:GetAttribute(key)
		if key == "RoundState" or key == "State" or key == "MissionState" then
			log("mission_state", { instanceId = id, value = val(v), via = "attr" })
		elseif key ~= "InstanceId" then
			log("instance_attr", { instanceId = id, key = key, value = val(v) }, "inst:" .. id .. ":" .. key)
		end
	end)
end

local function scanInstanceModels(force: boolean?): { [string]: Instance }
	if not force and os.clock() - instModelsAt < 1 then
		return instModels
	end
	instModelsAt = os.clock()
	local out = {}
	local function walk(node: Instance, depth: number)
		for _, c in node:GetChildren() do
			if c:IsA("Model") or c:IsA("Folder") then
				local id = nonEmpty(c:GetAttribute("InstanceId"))
				if id and not (c:IsA("Model") and Players:GetPlayerFromCharacter(c)) then
					if not out[id] then
						out[id] = c
						hookInstanceModel(c, id)
					end
				elseif depth < 4 then
					walk(c, depth + 1)
				end
			end
		end
	end
	walk(workspace, 1)
	instModels = out
	return out
end

instanceIdOfInst = function(inst: Instance): string?
	for id, m in scanInstanceModels() do
		if inst == m or inst:IsDescendantOf(m) then
			return id
		end
	end
	return nil
end

-- Visible from instance `scopeId`: inside it, or in the shared world (not inside another instance).
local function visibleIn(inst: Instance, scopeId: string?): boolean
	if not scopeId then
		return true
	end
	local owner = instanceIdOfInst(inst)
	return owner == nil or owner == scopeId
end

-- MissionService:GetMissions() is the §10 v1.5 contract; the rest are tolerated aliases.
local RUN_METHODS = { "GetMissions", "GetInstances", "GetRuns", "ListInstances" }

-- MissionRun-like tables from MissionService (any of RUN_METHODS, or an Instances/Runs field).
local function rawRuns(): ({ any }, string)
	local mission = liveModule("MissionService")
	local list = {}
	local via = "attrs"
	if mission then
		local got
		local name, fn = findMethod(mission, RUN_METHODS)
		if fn then
			local ok, res = pcall(fn, mission)
			if ok then
				got, via = res, "MissionService:" .. tostring(name)
			end
		else
			for _, f in { "Instances", "instances", "Runs", "runs" } do
				if type(mission[f]) == "table" then
					got, via = mission[f], "MissionService." .. f
					break
				end
			end
		end
		if type(got) == "table" then
			for k, run in got do
				if type(run) == "table" then
					if run.instanceId == nil and run.id == nil and type(k) == "string" then
						run = table.clone(run)
						run.instanceId = k
					end
					table.insert(list, run)
				end
			end
		end
	end
	return list, via
end

local function scopeFor(id: string): Instance
	local m = scanInstanceModels()[id] or scanInstanceModels(true)[id]
	if m then
		return m
	end
	for _, run in rawRuns() do
		if nonEmpty(run.instanceId or run.id) == id then
			if typeof(run.model) == "Instance" then
				return run.model
			end
			local map = liveModule("MapService")
			if map and run.locationId and type(map.GetLocation) == "function" then
				local ok, loc = pcall(map.GetLocation, map, run.locationId)
				if ok and typeof(loc) == "Instance" then
					return loc
				end
			end
		end
	end
	error("no mission instance " .. id .. " (no Model with InstanceId=" .. id .. " and no MissionService run)", 0)
end

local function countBurning(scope: Instance?): number
	local n = 0
	for _, inst in CollectionService:GetTagged("Burning") do
		if inst:IsDescendantOf(workspace) and (not scope or inst:IsDescendantOf(scope)) then
			n += 1
		end
	end
	return n
end

local function countRescues(scope: Instance?)
	local c = obj({ total = 0 })
	for _, inst in CollectionService:GetTagged("Rescuable") do
		if inst:IsDescendantOf(workspace) and (not scope or inst:IsDescendantOf(scope)) then
			c.total += 1
			local st = tostring(inst:GetAttribute("RescueState") or "Unknown")
			c[st] = (c[st] or 0) + 1
		end
	end
	return c
end

local function playerIdOf(u: any): number?
	if typeof(u) == "Instance" and u:IsA("Player") then
		return u.UserId
	end
	if type(u) == "table" then
		return tonumber(u.userId or u.UserId)
	end
	return tonumber(u)
end

local function whoById(uid: number)
	local ok, p = pcall(Players.GetPlayerByUserId, Players, uid)
	if ok and p then
		return who(p)
	end
	return obj({ userId = uid, gone = true })
end

-- Every running mission instance: MissionService runs + instance Models + players' InstanceId.
local function instancesList(args): { any }
	local runs, via = rawRuns()
	local models = scanInstanceModels(true)
	local byId, order = {}, {}
	local function entry(id: string, source: string)
		if not byId[id] then
			byId[id] = obj({ instanceId = id, players = {}, source = source })
			table.insert(order, id)
		end
		return byId[id]
	end
	local function addPlayer(e, uid: number?)
		if not uid then
			return
		end
		for _, x in e.players do
			if x.userId == uid then
				return
			end
		end
		table.insert(e.players, whoById(uid))
	end
	for _, run in runs do
		local id = nonEmpty(run.instanceId or run.id)
		if id then
			local e = entry(id, via)
			e.missionId = val(run.missionId)
			e.locationId = val(run.locationId)
			e.squadId = val(run.squadId)
			e.state = val(run.state)
			e.endsAt = val(run.endsAt)
			if type(run.players) == "table" then
				for _, u in run.players do
					addPlayer(e, playerIdOf(u))
				end
			end
		end
	end
	for id in models do
		entry(id, "model")
	end
	for _, p in playerList() do
		local id = nonEmpty(p:GetAttribute("InstanceId"))
		if id then
			addPlayer(entry(id, "player attrs"), p.UserId)
		end
	end
	local want = nonEmpty(args and args.instanceId)
	local out = {}
	for _, id in order do
		if not want or want == id then
			local e = byId[id]
			local m = models[id]
			if not m then
				local ok, scope = pcall(scopeFor, id)
				m = if ok then scope else nil
			end
			if m then
				e.model = m:GetFullName()
				e.state = e.state or val(m:GetAttribute("RoundState") or m:GetAttribute("State"))
				e.missionId = e.missionId or val(m:GetAttribute("MissionId"))
				e.locationId = e.locationId or val(m:GetAttribute("LocationId"))
				e.fires = countBurning(m)
				e.rescues = countRescues(m)
			end
			if type(e.endsAt) == "number" then
				e.secondsLeft = r(e.endsAt - workspace:GetServerTimeNow())
			end
			table.insert(out, e)
		end
	end
	return out
end

-- Lobby: SquadPads, squads (LobbyService or players' SquadId attrs), the mission catalog.
local SQUAD_METHODS = { "GetSquads", "ListSquads", "GetAllSquads" }

local function catalogIds(): { string }
	local out = {}
	local ms = findModule("MissionCatalog")
	if ms then
		local ok, cat = pcall(require, ms)
		if ok and type(cat) == "table" then
			local list = cat.missions or cat.Missions or cat
			for k, def in list do
				if type(def) == "table" and def.enabled == true then
					local id = def.id or (if type(k) == "string" then k else nil)
					if id ~= nil and not table.find(out, tostring(id)) then
						table.insert(out, tostring(id))
					end
				end
			end
		end
	end
	table.sort(out)
	return out
end

local function padsList()
	local pads = {}
	for _, pad in CollectionService:GetTagged("SquadPad") do
		if pad:IsDescendantOf(workspace) then
			local pos = posOf(pad)
			local e = obj({ padId = val(pad:GetAttribute("PadId")), path = pad:GetFullName(), pos = pos and v3(pos) or nil, attrs = attrsOf(pad), standing = {} })
			if pad:IsA("BasePart") then
				for _, p in playerList() do
					local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root then
						local rel = pad.CFrame:PointToObjectSpace(root.Position)
						if math.abs(rel.X) <= pad.Size.X / 2 + 1 and math.abs(rel.Z) <= pad.Size.Z / 2 + 1 and rel.Y > -2 and rel.Y < 12 then
							table.insert(e.standing, who(p))
						end
					end
				end
			end
			table.insert(pads, e)
		end
	end
	table.sort(pads, function(a, b)
		return (tonumber(a.padId) or 0) < (tonumber(b.padId) or 0)
	end)
	return pads
end

local function findPad(pad: any): Instance
	if type(pad) == "string" and string.find(pad, "%.") then
		return mustPath(pad)
	end
	local tagged = CollectionService:GetTagged("SquadPad")
	if #tagged == 0 then
		unsupported("no SquadPad in the world (station lobby not built yet)")
	end
	local n = tonumber(pad) or 1
	for _, p in tagged do
		if p:IsDescendantOf(workspace) and tonumber(p:GetAttribute("PadId")) == n then
			return p
		end
	end
	error("no SquadPad with PadId " .. tostring(pad), 0)
end

local function normSquad(sq: any, lobby: any)
	local e = plain(sq)
	if type(e) ~= "table" then
		e = obj({})
	end
	e = obj(e)
	e.id = val(sq.id or sq.squadId or sq.Id)
	e.padId = val(sq.padId or sq.PadId)
	e.leader = playerIdOf(sq.leader)
	local members = {}
	if type(sq.members) == "table" then
		for _, u in sq.members do
			local uid = playerIdOf(u)
			if uid then
				table.insert(members, whoById(uid))
			end
		end
	end
	e.members = members
	e.missionId = val(sq.missionId)
	e.instanceId = val(sq.instanceId)
	e.state = val(sq.state)
	local cd = sq.countdown or sq.secondsLeft or sq.Countdown
	if cd == nil then
		local endsAt = sq.launchAt or sq.countdownEndsAt or sq.endsAt
		if type(endsAt) == "number" then
			cd = math.max(0, endsAt - workspace:GetServerTimeNow())
		end
	end
	if cd == nil and e.id ~= nil and type(lobby) == "table" and type(lobby.GetCountdown) == "function" then
		local ok, res = pcall(lobby.GetCountdown, lobby, sq.id)
		if ok and type(res) == "number" then
			cd = res
		end
	end
	e.countdown = if type(cd) == "number" then r(cd) else nil
	e.source = "LobbyService"
	return e
end

local function squadsCmd(args)
	local status, lobby = serviceStatus("LobbyService")
	local squads = {}
	local via = "attrs"
	if lobby then
		local got
		local name, fn = findMethod(lobby, SQUAD_METHODS)
		if fn then
			local ok, res = pcall(fn, lobby)
			if ok then
				got, via = res, "LobbyService:" .. tostring(name)
			end
		else
			for _, f in { "Squads", "squads" } do
				if type(lobby[f]) == "table" then
					got, via = lobby[f], "LobbyService." .. f
					break
				end
			end
		end
		if type(got) == "table" then
			for k, sq in got do
				if type(sq) == "table" then
					local e = normSquad(sq, lobby)
					if e.id == nil and type(k) == "string" then
						e.id = k
					end
					table.insert(squads, e)
				end
			end
		end
	end
	local known = {}
	for _, s in squads do
		if s.id ~= nil then
			known[tostring(s.id)] = s
		end
	end
	for _, p in playerList() do
		local sid = nonEmpty(p:GetAttribute("SquadId"))
		if sid then
			if not known[sid] then
				known[sid] = obj({ id = sid, members = {}, source = "player attrs" })
				table.insert(squads, known[sid])
			end
			local s = known[sid]
			local listed = false
			for _, m in s.members do
				if m.userId == p.UserId then
					listed = true
				end
			end
			if not listed then
				table.insert(s.members, who(p))
			end
			s.instanceId = s.instanceId or nonEmpty(p:GetAttribute("InstanceId"))
		end
	end
	local pads = padsList()
	for _, pd in pads do
		local cd = padCountdown[tonumber(pd.padId) or -1]
		if cd and cd.seconds >= 0 then
			local left = cd.seconds - (os.clock() - cd.at)
			if left > -2 then
				pd.countdown = r(math.max(0, left))
			end
		end
	end
	for _, s in squads do
		if s.countdown == nil and s.padId ~= nil and s.instanceId == nil then
			local cd = padCountdown[tonumber(s.padId) or -1]
			if cd and cd.seconds >= 0 and cd.seconds - (os.clock() - cd.at) > -2 then
				s.countdown = r(math.max(0, cd.seconds - (os.clock() - cd.at)))
			end
		end
	end
	for _, s in squads do
		for _, pd in pads do
			if s.padId ~= nil and pd.padId == s.padId then
				pd.squadId = s.id
				if s.countdown == nil then
					for k, v in pd.attrs do
						if string.find(string.lower(k), "count") and type(v) == "number" then
							s.countdown = v
						end
					end
				end
			end
		end
	end
	local wantSquad = nonEmpty(args.squadId)
	local wantPad = tonumber(args.pad)
	if wantSquad or wantPad then
		local filtered = {}
		for _, s in squads do
			if (wantSquad and tostring(s.id) == wantSquad) or (wantPad and tonumber(s.padId) == wantPad) then
				table.insert(filtered, s)
			end
		end
		squads = filtered
	end
	local lobbyPlayers = {}
	for _, p in playerList() do
		if not nonEmpty(p:GetAttribute("InstanceId")) then
			table.insert(lobbyPlayers, who(p))
		end
	end
	return obj({ service = status, via = via, squads = squads, pads = pads, lobby = lobbyPlayers, catalog = catalogIds() })
end

-- Log every Signal on the game services as an event (kind from SIGNAL_KINDS, else snake_case).
local hookedSignals = setmetatable({}, { __mode = "k" })
local function snake(s: string): string
	return string.lower((string.gsub(s, "(%l)(%u)", "%1_%2")))
end

local function hookSignals(name: string, mod: any)
	for key, sig in mod do
		if type(key) == "string" and type(sig) == "table" and type(sig.Connect) == "function" and not hookedSignals[sig] then
			hookedSignals[sig] = true
			local kind = SIGNAL_KINDS[key] or snake(key)
			pcall(function()
				sig:Connect(function(...)
					local packed = table.pack(...)
					local data = obj({ signal = name .. "." .. key, via = "signal" })
					local list = {}
					local first: Player? = nil
					for i = 1, packed.n do
						local a = packed[i]
						local pv = plain(a)
						list[i] = if pv == nil then "nil" else pv
						if typeof(a) == "Instance" and a:IsA("Player") then
							if not first then
								first = a
							elseif data.other == nil then
								data.other = who(a)
							end
						end
						if data.instanceId == nil then
							if type(a) == "table" then
								data.instanceId = nonEmpty(a.instanceId)
							elseif type(a) == "string" and instModels[a] then
								data.instanceId = a
							end
						end
					end
					data.args = list
					if first then
						data.userId, data.name, data.helmet = first.UserId, first.Name, first:GetAttribute("Helmet")
					end
					log(kind, data)
				end)
			end)
		end
	end
end

local hookedPads = setmetatable({}, { __mode = "k" })
local function hookPad(pad: Instance)
	if hookedPads[pad] then
		return
	end
	hookedPads[pad] = true
	pad.AttributeChanged:Connect(function(key)
		local v = pad:GetAttribute(key)
		local padId = val(pad:GetAttribute("PadId"))
		if string.find(string.lower(key), "count") then
			log("countdown", { padId = padId, key = key, value = val(v), via = "attr" })
		else
			log("pad_attr", { padId = padId, key = key, value = val(v) }, "pad:" .. tostring(padId) .. ":" .. key)
		end
	end)
end
CollectionService:GetInstanceAddedSignal("SquadPad"):Connect(hookPad)
for _, pad in CollectionService:GetTagged("SquadPad") do
	hookPad(pad)
end

task.spawn(function()
	local t0 = os.clock()
	while workspace:GetAttribute("ServerBooted") ~= true and os.clock() - t0 < 60 do
		task.wait(0.5)
	end
	while true do
		for _, name in KNOWN_SERVICES do
			local mod = liveModule(name)
			if mod then
				pcall(hookSignals, name, mod)
			end
		end
		local folder = ServerScriptService:FindFirstChild("Services")
		if folder then
			for _, ms in folder:GetChildren() do
				if ms:IsA("ModuleScript") and not table.find(KNOWN_SERVICES, ms.Name) then
					local ok, mod = pcall(require, ms)
					if ok and type(mod) == "table" then
						pcall(hookSignals, ms.Name, mod)
					end
				end
			end
		end
		pcall(scanInstanceModels, true)
		task.wait(5)
	end
end)

local function burningish(inst: Instance): boolean
	return CollectionService:HasTag(inst, "Burning") or (tonumber(inst:GetAttribute("FireLevel")) or 0) > 0
end

------------------------------------------------------------------------------- obby
-- ObbyKit contract: a checkpoint is a part (or a model) tagged "Checkpoint" with a number attribute Stage
-- (1..N); a hazard is tagged "KillPart". A player's stage is their Stage attribute, else leaderstats.Stage.

local OBBY_CHECKPOINT, OBBY_HAZARD = "Checkpoint", "KillPart"

local function checkpointPart(inst: Instance): BasePart?
	if inst:IsA("BasePart") then
		return inst
	elseif inst:IsA("Model") then
		return inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart", true)
	end
	return nil
end

-- stage number -> its checkpoint part (the first one tagged with that Stage), and how many stages there are
local function checkpoints(): ({ [number]: BasePart }, number)
	local out, n = {}, 0
	for _, inst in CollectionService:GetTagged(OBBY_CHECKPOINT) do
		local stage = tonumber(inst:GetAttribute("Stage"))
		local part = if stage and inst:IsDescendantOf(workspace) then checkpointPart(inst) else nil
		if stage and part and out[stage] == nil then
			out[stage] = part
			n += 1
		end
	end
	return out, n
end

-- Stage 0 is the course start, which is often not a checkpoint: ObbyKit tags its start pad ObbyStart, other
-- obbies start on a SpawnLocation. teleport_stage / obby_try take it, so a run can begin where a new player does.
local function startPart(): BasePart?
	for _, inst in CollectionService:GetTagged("ObbyStart") do
		local part = if inst:IsDescendantOf(workspace) then checkpointPart(inst) else nil
		if part then
			return part
		end
	end
	return workspace:FindFirstChildWhichIsA("SpawnLocation", true)
end

local function stagePart(cps: { [number]: BasePart }, stage: number): BasePart?
	return cps[stage] or (if stage == 0 then startPart() else nil)
end

local function stageOf(p: any): number?
	local v = tonumber(p:GetAttribute("Stage"))
	if v then
		return v
	end
	local ls = p:FindFirstChild("leaderstats")
	local s = ls and ls:FindFirstChild("Stage")
	return if s and s:IsA("ValueBase") then tonumber((s :: any).Value) else nil
end

local function nextStage(cps: { [number]: BasePart }, after: number): number?
	local best: number? = nil
	for n in cps do
		if n > after and (best == nil or n < (best :: number)) then
			best = n
		end
	end
	return best
end

local function topOf(part: BasePart): Vector3
	return part.Position + Vector3.new(0, part.Size.Y / 2, 0)
end

-- observe's `obby` block (games with checkpoints only): stage, the next checkpoint, hazards nearby
local function obbyView(p: any, origin: Vector3?, radius: number)
	local cps, count = checkpoints()
	if count == 0 then
		return nil
	end
	local maxStage, nearest, nearD = 0, nil, math.huge
	for n, part in cps do
		maxStage = math.max(maxStage, n)
		local d = if origin then (part.Position - origin).Magnitude else math.huge
		if d < nearD then
			nearest, nearD = n, d
		end
	end
	local stage = stageOf(p)
	local view = obj({ stage = stage, stages = count, max_stage = maxStage })
	if nearest and origin then
		view.nearest = { stage = nearest, dist = math.floor(nearD + 0.5) }
	end
	local nx = nextStage(cps, stage or nearest or 0)
	if nx then
		local part = cps[nx]
		view.next = { stage = nx, path = part:GetFullName(), pos = v3(topOf(part)),
			dist = if origin then math.floor((part.Position - origin).Magnitude + 0.5) else nil }
	end
	local hazards = {}
	for _, h in CollectionService:GetTagged(OBBY_HAZARD) do
		local pos = if origin and h:IsDescendantOf(workspace) then posOf(h) else nil
		if pos and origin and (pos - origin).Magnitude <= radius then
			table.insert(hazards, { name = h.Name, path = h:GetFullName(), dist = math.floor((pos - origin).Magnitude + 0.5),
				pos = v3(pos) })
		end
	end
	table.sort(hazards, function(a, b)
		return a.dist < b.dist
	end)
	view.hazards = {}
	for i = 1, math.min(6, #hazards) do
		table.insert(view.hazards, hazards[i])
	end
	return view
end

local function observe(args)
	local p = playerArg(args)
	local radius = tonumber(args.radius) or 120
	local max = tonumber(args.max) or 12
	local char = p.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local origin = root and root.Position
	local out = obj({ me = obj({}), world = obj({}), things = {}, prompts = {}, hud = {} })
	-- Scope: an explicit instanceId, else the player's own instance; things inside OTHER mission
	-- instances are hidden (shared world such as the station stays visible). allInstances = no scope.
	local scopeId = nonEmpty(args.instanceId)
	if scopeId then
		scopeFor(scopeId) -- errors on an unknown instance
	elseif args.allInstances ~= true then
		scopeId = nonEmpty(p:GetAttribute("InstanceId"))
	end
	local me = out.me
	me.userId, me.name, me.helmet = p.UserId, p.Name, p:GetAttribute("Helmet")
	if origin then
		me.pos = v3(origin)
	end
	if hum then
		me.health = math.floor(hum.Health + 0.5)
		me.max_health = math.floor(hum.MaxHealth + 0.5)
	end
	if not char then
		me.no_character = true
	end
	local attrs = obj({})
	for _, k in ME_ATTRS do
		local v = p:GetAttribute(k)
		if v == nil and char then
			v = char:GetAttribute(k)
		end
		if v ~= nil then
			attrs[k] = val(v)
		end
	end
	me.attrs = attrs
	local tool = char and char:FindFirstChildOfClass("Tool")
	me.tool = tool and tool.Name or nil
	local bp = {}
	local backpack = p:FindFirstChildOfClass("Backpack")
	if backpack then
		for _, t in backpack:GetChildren() do
			if t:IsA("Tool") then
				table.insert(bp, t.Name)
			end
		end
	end
	me.backpack = bp
	for _, k in WORLD_ATTRS do
		local v = workspace:GetAttribute(k)
		if v ~= nil then
			out.world[k] = val(v)
		end
	end
	out.world.now = math.floor(workspace:GetServerTimeNow())
	local sid = nonEmpty(p:GetAttribute("SquadId"))
	if sid then
		out.world.SquadId = sid
	end
	if scopeId then
		out.world.InstanceId = scopeId
		local ok, list = pcall(instancesList, { instanceId = scopeId })
		local run = ok and list[1] or nil
		if run then
			out.world.instance = obj({
				missionId = run.missionId, state = run.state, secondsLeft = run.secondsLeft, fires = run.fires,
				rescues = run.rescues, players = #run.players,
			})
		end
	elseif #CollectionService:GetTagged("SquadPad") > 0 then
		out.world.lobby = true
	end

	local seen, things = {}, {}
	for _, tag in TAGS do
		for _, inst in CollectionService:GetTagged(tag) do
			if not seen[inst] and inst:IsDescendantOf(workspace) and (tag ~= "Flammable" or burningish(inst)) and visibleIn(inst, scopeId) then
				local pos = posOf(inst)
				if pos then
					local d = origin and (pos - origin).Magnitude or 0
					if d <= radius then
						seen[inst] = true
						local e = { name = inst.Name, path = inst:GetFullName(), tag = tag, dist = math.floor(d + 0.5), pos = v3(pos) }
						for _, a in THING_ATTRS do
							local v = inst:GetAttribute(a)
							if v ~= nil then
								e[a] = val(v)
							end
						end
						table.insert(things, e)
					end
				end
			end
		end
	end
	table.sort(things, function(a, b)
		return a.dist < b.dist
	end)
	for i = 1, math.min(max, #things) do
		table.insert(out.things, things[i])
	end

	local prompts = {}
	local promptRadius = math.min(60, radius)
	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") and d.Enabled then
			local pos = posOf(d.Parent)
			if pos then
				local dist = origin and (pos - origin).Magnitude or 0
				if dist <= promptRadius and visibleIn(d, scopeId) then
					table.insert(prompts, {
						action = d.ActionText, object = d.ObjectText, dist = math.floor(dist + 0.5),
						range = d.MaxActivationDistance, in_range = dist <= d.MaxActivationDistance,
						hold = r(d.HoldDuration), key = d.KeyboardKeyCode.Name, path = d.Parent:GetFullName(),
					})
				end
			end
		end
	end
	table.sort(prompts, function(a, b)
		return a.dist < b.dist
	end)
	for i = 1, math.min(6, #prompts) do
		table.insert(out.prompts, prompts[i])
	end

	-- Any game's touch triggers (buy pads, buttons, enemies, checkpoints) and labelled parts, so testers
	-- of games without the tags above can find them and walk onto them by path.
	local touchables = {}
	for _, d in workspace:GetDescendants() do
		if d:IsA("BasePart") and not seen[d] and visibleIn(d, scopeId) then
			local touch = d:FindFirstChildOfClass("TouchTransmitter") ~= nil
			local label
			for _, g in d:GetDescendants() do
				if (g:IsA("TextLabel") or g:IsA("TextButton")) and g.Text ~= "" then
					label = (label and label .. " | " or "") .. g.Text
				end
			end
			local owner = d:FindFirstAncestorOfClass("Model")
			local isCharacter = owner ~= nil
				and (Players:GetPlayerFromCharacter(owner) ~= nil or owner:GetAttribute("ForgeBot") ~= nil)
			if (touch or label) and not isCharacter then
				local dist = origin and (d.Position - origin).Magnitude or 0
				if dist <= promptRadius then
					table.insert(touchables, {
						name = d.Name, path = d:GetFullName(), dist = math.floor(dist + 0.5), pos = v3(d.Position),
						touch = touch, label = label and string.sub(label, 1, 80) or nil,
					})
				end
			end
		end
	end
	table.sort(touchables, function(a, b)
		return a.dist < b.dist
	end)
	out.touchables = {}
	for i = 1, math.min(8, #touchables) do
		table.insert(out.touchables, touchables[i])
	end
	local obby = obbyView(p, origin, math.min(radius, 60))
	if obby then
		out.obby = obby
	end

	if isBot(p) then
		-- no client, so no screen: a bot only sees the world
		me.bot = true
		out.hud_error = "bot tester: no screen (HUD and GUI belong to real players)"
		return out
	end
	local ok, hud = invokeClient(p, "hud", {}, HUD_TIMEOUT)
	if ok and type(hud) == "table" then
		out.hud = hud
	else
		out.hud_error = tostring(hud)
	end
	local uiOk, ui = invokeClient(p, "ui", {}, HUD_TIMEOUT)
	if uiOk and type(ui) == "table" then
		out.ui = ui.buttons or {}
		out.panels = ui.panels or {}
		if ui.not_rendering then
			out.ui_error = ui.not_rendering -- a minimized Studio window: no button has a size
		end
	else
		out.ui_error = tostring(ui)
	end
	return out
end

-- GUI commands run on the player's own client (ForgeTestAgent). The click between ui_target and
-- ui_effect is a real mouse click sent by the Python side (Harness.press) through Studio MCP.
local function agentCmd(name: string)
	return function(args)
		local p = playerArg(args)
		if isBot(p) then
			error(p.Name .. " is a bot tester: it has no screen, so no GUI (" .. name .. ")")
		end
		local a = table.clone(args)
		a.userId, a.player = nil, nil
		local ok, res = invokeClient(p, name, a, HUD_TIMEOUT)
		if not ok then
			error(res)
		end
		return res
	end
end

-------------------------------------------------------------------- effect diff (macros)

local function statsOf(p: Player): { [string]: any }
	local out = {}
	local ls = p:FindFirstChild("leaderstats")
	if ls then
		for _, v in ls:GetChildren() do
			if v:IsA("ValueBase") then
				out[v.Name] = val((v :: any).Value)
			end
		end
	end
	return out
end

local function playerAttrs(p: Player): { [string]: any }
	local out = {}
	for k, v in p:GetAttributes() do
		out[k] = val(v)
	end
	local char = p.Character
	if char then
		for k, v in char:GetAttributes() do
			if out[k] == nil then
				out[k] = val(v)
			end
		end
	end
	return out
end

-- {key: [old, new]} for keys whose value changed (missing = "nil"), at most `max`
local function changes(a: { [string]: any }, b: { [string]: any }, max: number)
	local out, n = obj({}), 0
	local keys = {}
	for k in a do
		keys[k] = true
	end
	for k in b do
		keys[k] = true
	end
	local sorted = {}
	for k in keys do
		table.insert(sorted, k)
	end
	table.sort(sorted)
	for _, k in sorted do
		local old, new = a[k], b[k]
		if old ~= new and type(old) ~= "table" and n < max then
			out[k] = { if old == nil then "nil" else old, if new == nil then "nil" else new }
			n += 1
		end
	end
	return out, n
end

local function newEvents(p: Player, t0: number, max: number): { any }
	local out = {}
	for _, e in events do
		if e.t >= t0 and e.kind ~= "count" and (e.data.userId == nil or e.data.userId == p.UserId) then
			local brief = obj({ kind = e.kind })
			for k, v in e.data do
				if k ~= "userId" and k ~= "name" and k ~= "helmet" and k ~= "instanceId" and k ~= "squadId"
					and (type(v) ~= "table" or k == "args") then
					brief[k] = v
				end
			end
			table.insert(out, brief)
		end
	end
	while #out > max do
		table.remove(out, 1)
	end
	return out
end

-- Run fn and attach `effect`: what the action changed for this player and the game (leaderstats,
-- player/character attributes, ForgeTelemetry counters, HUD text from the agent, new events).
local function withEffect(p: Player, fn: () -> any)
	local s0, a0, c0, t0 = statsOf(p), playerAttrs(p), counters(), now()
	local res = fn()
	task.wait(0.2)
	local eff = obj({})
	local d, n = changes(s0, statsOf(p), 8)
	if n > 0 then
		eff.leaderstats = d
	end
	d, n = changes(a0, playerAttrs(p), 10)
	if n > 0 then
		eff.attrs = d
	end
	-- counters that were already ticking before the action (traffic, ambient props) are not its effect
	local ambient = {}
	for _, e in events do
		if e.kind == "count" and e.t >= t0 - AMBIENT_WINDOW and e.t < t0 then
			ambient[tostring(e.data.name)] = true
		end
	end
	local c1 = counters()
	for k in ambient do
		c0[k], c1[k] = nil, nil
	end
	d, n = changes(c0, c1, 10)
	if n > 0 then
		eff.counters = d
	end
	if type(res) == "table" then
		if type(res.hud_new) == "table" and #res.hud_new > 0 then
			eff.hud_new = res.hud_new
		end
		if type(res.hud_gone) == "table" and #res.hud_gone > 0 then
			eff.hud_gone = res.hud_gone
		end
		res.hud_new, res.hud_gone = nil, nil
	end
	local ev = newEvents(p, t0, 8)
	if #ev > 0 then
		eff.events = ev
	end
	if type(res) ~= "table" then
		res = { done = true, detail = tostring(res) }
	end
	res.effect = eff
	return res
end

local actRaw: (args: any) -> any

------------------------------------------------------------------------------- swarm bots

local PathfindingService = game:GetService("PathfindingService")
local BOT_ID_BASE = 1000
local BOT_RESPAWN = 3
local BOT_ARRIVE = 1 -- walk_to: horizontal studs from the target point that count as arrived (arrive_radius)
local botFolder: Folder? = nil
local nextBotId = 1

local function botParent(): Folder
	if not botFolder or not botFolder.Parent then
		local f = workspace:FindFirstChild("ForgeTestBots")
		if not f then
			f = Instance.new("Folder")
			f.Name = "ForgeTestBots"
			f.Parent = workspace
		end
		botFolder = f :: Folder
	end
	return botFolder :: Folder
end

local function botColor(c: any, i: number): Color3
	if type(c) == "table" and tonumber(c[1]) then
		return Color3.fromRGB(tonumber(c[1]) or 0, tonumber(c[2]) or 0, tonumber(c[3]) or 0)
	end
	return Color3.fromHSV((i * 0.137) % 1, 0.65, 0.95)
end

-- An R15 rig from a blank HumanoidDescription; if that fails, a one-part rig (a Humanoid with a
-- HipHeight walks with just a root part).
local function buildBotModel(name: string, color: Color3): Model
	local ok, m = pcall(Players.CreateHumanoidModelFromDescription, Players, Instance.new("HumanoidDescription"),
		Enum.HumanoidRigType.R15)
	if not ok or not m then
		m = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Size = Vector3.new(2, 2, 1)
		root.Parent = m
		local head = Instance.new("Part")
		head.Name = "Head"
		head.Size = Vector3.new(2, 1, 1)
		head.CFrame = root.CFrame * CFrame.new(0, 1.5, 0)
		head.Parent = m
		local weld = Instance.new("WeldConstraint")
		weld.Part0, weld.Part1 = root, head
		weld.Parent = root
		local hum = Instance.new("Humanoid")
		hum.RigType = Enum.HumanoidRigType.R15
		hum.HipHeight = 2
		hum.Parent = m
		m.PrimaryPart = root
	end
	m.Name = name
	for _, d in m:GetDescendants() do
		if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" then
			d.Color = color
		end
	end
	local hum = m:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.DisplayName = name
		hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
		hum.NameDisplayDistance = 150
		-- jump and run like this game's players (an obby sets its own jump height on StarterPlayer), so a bot's
		-- obby_try says what a player can reach
		hum.UseJumpPower = StarterPlayer.CharacterUseJumpPower
		hum.JumpPower = StarterPlayer.CharacterJumpPower
		hum.JumpHeight = StarterPlayer.CharacterJumpHeight
		hum.WalkSpeed = StarterPlayer.CharacterWalkSpeed
	end
	m:SetAttribute("ForgeBot", name)
	return m
end

local attachBot: (b: any) -> ()
attachBot = function(b)
	local m = buildBotModel(b.Name, b.color)
	b.life += 1
	local life = b.life
	m:PivotTo(b.spawnCF)
	m.Parent = botParent()
	b.Character = m
	local root = m:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root then
		pcall(root.SetNetworkOwner, root, nil) -- server physics, so MoveTo isn't fought by a client
	end
	local function lost(cause: string)
		if b.life ~= life or b.removed then
			return
		end
		b.life += 1 -- only one respawn per life
		b.deaths += 1
		log("player_died", with(who(b), { bot = true, cause = cause, pos = root and v3(root.Position) or nil }))
		task.delay(BOT_RESPAWN, function()
			if not b.removed then
				if m.Parent then
					m:Destroy()
				end
				attachBot(b)
				log("bot_respawned", who(b))
			end
		end)
	end
	local hum = m:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.Died:Connect(function()
			lost("died")
		end)
	end
	m.AncestryChanged:Connect(function(_, parent)
		if parent == nil then
			lost("removed")
		end
	end)
	task.spawn(function() -- the void destroys parts, not always the Humanoid
		while b.life == life and not b.removed do
			task.wait(0.5)
			if b.life ~= life then
				break
			end
			if not root or root.Parent == nil or root.Position.Y < workspace.FallenPartsDestroyHeight + 5 then
				lost("fell out of the world")
				break
			end
		end
	end)
end

local function botOrigin(args): Vector3
	local near = args.near
	if near ~= nil then
		local v = toVec(near)
		if v then
			return v
		end
		local ok, p = pcall(resolvePlayer, near)
		local pos = ok and posOf(p) or nil
		if pos then
			return pos
		end
	end
	for _, p in playerList() do
		local pos = posOf(p)
		if pos then
			return pos
		end
	end
	local spawn = workspace:FindFirstChildWhichIsA("SpawnLocation", true)
	return if spawn then spawn.Position + Vector3.new(0, 3, 0) else Vector3.new(0, 5, 0)
end

-- bot_spawn {names: [string] | n, colors?: [[r,g,b]], near?: pos | player, radius?}: spawn NPC
-- testers in a ring around `near` (default: the first real player). Returns their players-info.
local function botSpawn(args)
	local names = args.names
	if type(names) ~= "table" then
		names = {}
		for i = 1, math.clamp(tonumber(args.n) or 1, 1, 24) do
			table.insert(names, "Bot" .. (nextBotId + i - 1))
		end
	end
	local origin = botOrigin(args)
	local radius = tonumber(args.radius) or 10
	local out = {}
	for i, name in names do
		name = tostring(name)
		if findBot(name) then
			error("a bot named " .. name .. " already exists (bot_clear first)")
		end
		local a = (i - 1) / #names * math.pi * 2
		local pos = origin + Vector3.new(math.cos(a) * radius, 3, math.sin(a) * radius)
		local b = setmetatable({
			IsBot = true, UserId = -(BOT_ID_BASE + nextBotId), Name = name, DisplayName = name,
			color = botColor(type(args.colors) == "table" and args.colors[i] or nil, nextBotId),
			spawnCF = CFrame.lookAt(pos, Vector3.new(origin.X, pos.Y, origin.Z)), deaths = 0, life = 0,
		}, BotProxy)
		nextBotId += 1
		table.insert(bots, b)
		attachBot(b)
		log("bot_spawned", with(who(b), { pos = v3(pos) }))
		table.insert(out, playerInfo(b))
	end
	return out
end

local function botClear()
	local n = #bots
	for _, b in bots do
		b.removed = true
		if b.Character and b.Character.Parent then
			b.Character:Destroy()
		end
	end
	table.clear(bots)
	if botFolder and botFolder.Parent then
		botFolder:Destroy()
	end
	botFolder = nil
	return { removed = n }
end

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function footprint(inst: Instance?): number?
	if inst and inst:IsA("BasePart") then
		return math.max(inst.Size.X, inst.Size.Z) / 2
	elseif inst and inst:IsA("Model") then
		local ok, _, size = pcall(inst.GetBoundingBox, inst)
		return if ok then math.min(math.max(size.X, size.Z) / 2, 20) else nil
	end
	return nil
end

-- Same arrival rule as the client agent: within `arrive` studs of the target point (so a walk to a
-- pad ends on it); a solid target that blocks the last stretch counts when the bot is beside it.
local function botWalk(b, char: Model, hum: Humanoid, root: BasePart, target: Vector3, timeout: number,
	arrive: number?, inst: Instance?)
	arrive = math.clamp(arrive or BOT_ARRIVE, 0.5, 50)
	local t0 = os.clock()
	local start = root.Position
	local path = PathfindingService:CreatePath({ AgentRadius = 2, AgentHeight = 5, AgentCanJump = true })
	local okPath = pcall(path.ComputeAsync, path, start, target)
	local waypoints: { any } = { { Position = target, Action = Enum.PathWaypointAction.Walk } }
	local via = "direct"
	if okPath and path.Status == Enum.PathStatus.Success then
		waypoints = path:GetWaypoints()
		via = "path"
	end
	for _, wp in waypoints do
		if os.clock() - t0 > timeout or hum.Health <= 0 or char.Parent == nil then
			break
		end
		if wp.Action == Enum.PathWaypointAction.Jump then
			hum.Jump = true
		end
		hum:MoveTo(wp.Position)
		local reached = false
		local conn = hum.MoveToFinished:Connect(function()
			reached = true
		end)
		local w0 = os.clock()
		while not reached and os.clock() - w0 < 4 and os.clock() - t0 < timeout do
			task.wait(0.05)
		end
		conn:Disconnect()
	end
	-- last stretch straight at the point (paths end at the nearest walkable spot); stop when blocked
	local stalls = 0
	while char.Parent and hum.Health > 0 and os.clock() - t0 < timeout and stalls < 2
		and (flat(root.Position) - flat(target)).Magnitude > arrive do
		local before = (flat(root.Position) - flat(target)).Magnitude
		hum:MoveTo(target)
		local p0 = os.clock()
		while os.clock() - p0 < 2 and os.clock() - t0 < timeout and (flat(root.Position) - flat(target)).Magnitude > arrive do
			task.wait(0.05)
		end
		stalls = if before - (flat(root.Position) - flat(target)).Magnitude < 0.3 then stalls + 1 else 0
	end
	if char.Parent == nil or hum.Health <= 0 then
		return { done = false, detail = b.Name .. " died or fell out of the world while walking", dead = true }
	end
	hum:MoveTo(root.Position) -- stop
	local dist = (flat(root.Position) - flat(target)).Magnitude
	local moved = (root.Position - start).Magnitude
	local secs = os.clock() - t0
	local side = footprint(inst)
	if dist <= arrive or (side and dist <= side + 1.5) then
		return { done = true, dist = r(dist), pos = v3(root.Position), detail = string.format(
			"%s walk: arrived %.1f studs from target in %.1fs%s", via, dist, secs,
			if dist <= arrive then "" else " (beside it: the target is solid)") }
	end
	return { done = false, dist = r(dist), pos = v3(root.Position), detail = string.format(
		"%s walk: stopped %.1f studs short after %.1fs, moved %.1f (blocked or unreachable)", via, dist, secs, moved) }
end

-- The server side of `act` for a bot: walk_to / jump / look_at / say. Tools and ProximityPrompts
-- are client input, so bots report them as not possible instead of faking them.
local function botAct(b, action: string, a)
	local char = b.Character
	local hum = char and char.Parent and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hum or not root or hum.Health <= 0 then
		return { done = false, detail = b.Name .. " is dead or respawning" }
	end
	local goalInst: Instance? = nil
	local function target(): Vector3
		local v = toVec(a.pos)
		if not v and a.path then
			goalInst = mustPath(a.path)
			v = posOf(goalInst)
		end
		if not v then
			error("pos or path required")
		end
		return v :: Vector3
	end
	local function walk()
		local goal = target()
		return botWalk(b, char, hum, root, goal, math.clamp(tonumber(a.timeout) or WALK_TIMEOUT, 1, 60),
			tonumber(a.arrive_radius), goalInst)
	end
	if action == "walk_to" or action == "go_touch" or action == "chase" then
		local res = walk()
		if action ~= "walk_to" and res.done then
			task.wait(0.5) -- stand on it so Touched handlers run
			res.detail = action .. ": touched it (" .. res.detail .. ")"
		end
		return res
	elseif action == "go_use" then
		local res = walk()
		res.done = false
		res.detail = res.detail .. "; bot testers can't hold ProximityPrompts (client input), a real player has to"
		return res
	elseif action == "jump" then
		local y0, peak = root.Position.Y, root.Position.Y
		hum.Jump = true
		for _ = 1, 14 do
			task.wait(0.05)
			peak = math.max(peak, root.Position.Y)
		end
		return { done = true, detail = string.format("jumped %.1f studs", peak - y0), pos = v3(root.Position) }
	elseif action == "look_at" then
		local t = target()
		root.CFrame = CFrame.lookAt(root.Position, Vector3.new(t.X, root.Position.Y, t.Z))
		return { done = true, detail = "facing " .. tostring(v3(t)) }
	elseif action == "say" then
		local text = string.sub(tostring(a.text or ""), 1, 120)
		local head = char:FindFirstChild("Head")
		if head then
			pcall(function()
				game:GetService("Chat"):Chat(head, text, Enum.ChatColor.White)
			end)
		end
		log("say", with(who(b), { text = text, bot = true }))
		return { done = true, detail = "said: " .. text }
	elseif action == "interact" then
		return { done = false, detail = "bot testers can't hold ProximityPrompts (client input); a real player has to" }
	end
	return { done = false, detail = "bot testers have no backpack or tools (" .. action .. " needs a real player)" }
end

local function act(args)
	local p = playerArg(args)
	if MACROS[tostring(args.action or "")] then
		return withEffect(p, function()
			return actRaw(args)
		end)
	end
	return actRaw(args)
end

actRaw = function(args)
	local p = playerArg(args)
	local action = tostring(args.action or "")
	local a = args.args
	if type(a) ~= "table" then
		a = {}
	end
	if not ACTIONS[action] then
		local names = {}
		for k in ACTIONS do
			table.insert(names, k)
		end
		table.sort(names)
		error("unknown action '" .. action .. "' (one of: " .. table.concat(names, ", ") .. ")")
	end
	-- Aim / walk / interact at another player by name, UserId or helmet ("target_player": "2").
	local tp = a.target_player or a.at_player
	if tp ~= nil then
		local target = resolvePlayer(tp)
		local tchar = target.Character
		if not tchar then
			error(target.Name .. " has no character")
		end
		a = table.clone(a)
		a.target_player, a.at_player = nil, nil
		if action == "use" then
			a.aim = tchar:GetFullName()
		else
			a.path = tchar:GetFullName()
		end
	end
	if action == "wait" then
		local s = math.clamp(tonumber(a.seconds) or 1, 0, 60)
		task.wait(s)
		return { done = true, detail = string.format("waited %.1fs", s) }
	end
	if action == "repeat" then
		-- edge cases: double buys, spammed claims; one effect diff covers all the tries
		local inner = tostring(a.action or "")
		if inner == "repeat" or not ACTIONS[inner] then
			error("repeat: args.action must be another action (e.g. go_use, interact), got '" .. inner .. "'")
		end
		local times = math.clamp(math.floor(tonumber(a.times) or 2), 1, REPEAT_MAX)
		local innerArgs = if type(a.args) == "table" then a.args else {}
		local notes, ok = {}, 0
		for i = 1, times do
			local good, res = pcall(actRaw, { userId = args.userId, player = args.player, action = inner, args = innerArgs })
			if good and type(res) == "table" and res.done ~= false then
				ok += 1
			end
			local note = if good and type(res) == "table" then tostring(res.detail or "") else "error: " .. tostring(res)
			table.insert(notes, string.format("%d: %s", i, string.sub(note, 1, 160)))
		end
		return obj({
			done = ok == times, times = times, succeeded = ok,
			detail = string.format("%s x%d, %d done | %s", inner, times, ok, table.concat(notes, " | ")),
		})
	end
	if isBot(p) then
		return botAct(p, action, a)
	end
	-- Paths are resolved on the client, but an Instance can't be passed from JSON, so send strings.
	local timeout = DEFAULT_ACT_TIMEOUT
	if MACROS[action] then
		timeout = math.clamp(tonumber(a.timeout) or 20, 2, 60) + 10
	elseif action == "walk_to" then
		timeout = (tonumber(a.timeout) or WALK_TIMEOUT) + 5
	elseif action == "use" then
		timeout = math.clamp(tonumber(a.seconds) or 1, 0, 30) + 5
	elseif action == "interact" then
		timeout = 20
	end
	local ok, res = invokeClient(p, "act", { action = action, args = a }, timeout)
	if not ok then
		error(res)
	end
	if type(res) == "table" then
		return obj(res)
	end
	return { done = true, detail = tostring(res) }
end

local function nearPos(near: any): Vector3?
	if near == nil then
		return nil
	end
	local v = toVec(near)
	if v then
		return v
	end
	if type(near) == "string" and resolvePath(near) and string.find(near, "%.") then
		return posOf(resolvePath(near))
	end
	local p = resolvePlayer(near)
	local pos = posOf(p)
	if not pos then
		error("player " .. p.Name .. " has no character")
	end
	return pos
end

local function query(args)
	local origin = nearPos(args.near)
	local radius = tonumber(args.radius)
	local limit = tonumber(args.limit) or 25
	local keys = if type(args.attrs) == "table" then args.attrs else nil
	local tags = if args.tag then { tostring(args.tag) } else TAGS
	-- instanceId: only things inside that mission instance. where: {attr = value} equality filter.
	local scope = if nonEmpty(args.instanceId) then scopeFor(tostring(args.instanceId)) else nil
	local where = if type(args.where) == "table" then args.where else nil
	local function matches(inst: Instance): boolean
		if scope and not (inst == scope or inst:IsDescendantOf(scope)) then
			return false
		end
		if where then
			for k, want in where do
				local got = inst:GetAttribute(tostring(k))
				if got ~= want and not (tonumber(got) and tonumber(want) and tonumber(got) == tonumber(want)) then
					return false
				end
			end
		end
		return true
	end
	local seen, rows = {}, {}
	for _, tag in tags do
		for _, inst in CollectionService:GetTagged(tag) do
			if not seen[inst] and inst:IsDescendantOf(workspace) and matches(inst) then
				seen[inst] = true
				local pos = posOf(inst)
				local d = if origin and pos then (pos - origin).Magnitude else nil
				if not radius or (d and d <= radius) then
					table.insert(rows, {
						path = inst:GetFullName(),
						name = inst.Name,
						tags = CollectionService:GetTags(inst),
						pos = pos and v3(pos) or nil,
						dist = d and r(d) or nil,
						attrs = attrsOf(inst, keys),
						instanceId = instanceIdOfInst(inst),
					})
				end
			end
		end
	end
	if origin then
		table.sort(rows, function(a, b)
			return (a.dist or math.huge) < (b.dist or math.huge)
		end)
	else
		table.sort(rows, function(a, b)
			return a.path < b.path
		end)
	end
	local out = {}
	for i = 1, math.min(limit, #rows) do
		out[i] = rows[i]
	end
	return out
end

local function inspect(args)
	local inst = mustPath(args.path)
	local out = obj({
		class = inst.ClassName,
		name = inst.Name,
		path = inst:GetFullName(),
		attrs = attrsOf(inst),
		tags = CollectionService:GetTags(inst),
	})
	local pos = posOf(inst)
	out.pos = pos and v3(pos) or nil
	if inst:IsA("BasePart") then
		out.size = v3(inst.Size)
		out.anchored = inst.Anchored
		out.canCollide = inst.CanCollide
		out.transparency = r(inst.Transparency, 2)
	elseif inst:IsA("Model") then
		local ok, _, size = pcall(inst.GetBoundingBox, inst)
		if ok then
			out.size = v3(size)
		end
	elseif inst:IsA("ProximityPrompt") then
		out.prompt = obj({ action = inst.ActionText, object = inst.ObjectText, enabled = inst.Enabled, hold = inst.HoldDuration, range = inst.MaxActivationDistance })
	elseif inst:IsA("Player") then
		out.player = playerInfo(inst)
	end
	local children = {}
	for i, c in inst:GetChildren() do
		if i > 100 then
			table.insert(children, "...(" .. (#inst:GetChildren() - 100) .. " more)")
			break
		end
		table.insert(children, c.Name)
	end
	out.children = children
	return out
end

local function toAttrValue(v: any): any
	if type(v) == "table" then
		local vec = toVec(v)
		if vec then
			return vec
		end
		error("unsupported attribute value (use number, string, bool, null or [x,y,z])")
	end
	return v
end

local function setAttr(args)
	local inst: Instance
	if args.path then
		inst = mustPath(args.path)
	else
		inst = playerArg(args)
	end
	local key = tostring(args.key or "")
	if key == "" then
		error("key required")
	end
	inst:SetAttribute(key, toAttrValue(args.value))
	return true
end

local function nearestFlammable(origin: Vector3, radius: number, wantBurning: boolean, scope: Instance?): Instance?
	local best, bestD = nil, radius
	local list = if wantBurning then CollectionService:GetTagged("Burning") else CollectionService:GetTagged("Flammable")
	for _, inst in list do
		if inst:IsDescendantOf(workspace) and burningish(inst) == wantBurning and (not scope or inst:IsDescendantOf(scope)) then
			local pos = posOf(inst)
			if pos then
				local d = (pos - origin).Magnitude
				if d <= bestD then
					best, bestD = inst, d
				end
			end
		end
	end
	return best
end

local function targetFor(args, wantBurning: boolean): Instance
	if args.path then
		return mustPath(args.path)
	end
	local origin = nearPos(args.near)
	if not origin then
		error("path or near required")
	end
	local scope = if nonEmpty(args.instanceId) then scopeFor(tostring(args.instanceId)) else nil
	local inst = nearestFlammable(origin, tonumber(args.radius) or 60, wantBurning, scope)
	if not inst then
		error(string.format("no %s part within %s studs", if wantBurning then "burning" else "unburnt Flammable", tostring(args.radius or 60)))
	end
	return inst
end

local function ignite(args)
	local inst = targetFor(args, false)
	local fire = liveModule("FireService")
	local via = "tags"
	if fire and type(fire.Ignite) == "function" and inst:IsA("BasePart") then
		local ok, res = pcall(fire.Ignite, fire, inst, nil)
		if ok then
			via = "FireService:Ignite -> " .. tostring(res)
		else
			via = "tags (FireService:Ignite failed: " .. tostring(res) .. ")"
		end
	end
	if not burningish(inst) then
		inst:SetAttribute("FireLevel", 1)
		CollectionService:AddTag(inst, "Burning")
		if via ~= "tags" then
			via ..= "; tags fallback"
		end
	end
	return { path = inst:GetFullName(), burning = burningish(inst), via = via }
end

local function extinguish(args)
	local fire = liveModule("FireService")
	if args.all then
		if fire and type(fire.ExtinguishAll) == "function" then
			pcall(fire.ExtinguishAll, fire)
		end
		local n = 0
		for _, inst in CollectionService:GetTagged("Burning") do
			CollectionService:RemoveTag(inst, "Burning")
			inst:SetAttribute("FireLevel", nil)
			n += 1
		end
		return { all = true, cleared = n }
	end
	local inst = targetFor(args, true)
	local via = "tags"
	if fire and type(fire.Extinguish) == "function" then
		local ok, res = pcall(fire.Extinguish, fire, inst, nil)
		via = if ok then "FireService:Extinguish -> " .. tostring(res) else "tags (FireService:Extinguish failed: " .. tostring(res) .. ")"
	end
	if burningish(inst) then
		CollectionService:RemoveTag(inst, "Burning")
		inst:SetAttribute("FireLevel", nil)
	end
	return { path = inst:GetFullName(), burning = burningish(inst), via = via }
end

local function teleport(args)
	local p = playerArg(args)
	local char = p.Character
	if not char then
		error(p.Name .. " has no character")
	end
	local pos = toVec(args.pos)
	if not pos and args.path then
		local inst = mustPath(args.path)
		pos = posOf(inst)
		if pos then
			local h = 0
			if inst:IsA("BasePart") then
				h = inst.Size.Y / 2
			elseif inst:IsA("Model") then
				local ok, _, size = pcall(inst.GetBoundingBox, inst)
				h = if ok then size.Y / 2 else 0
			end
			pos += Vector3.new(0, h, 0)
		end
	end
	if not pos and args.to ~= nil then -- next to another player (name / UserId / helmet)
		local other = resolvePlayer(args.to)
		pos = posOf(other)
		if not pos then
			error(other.Name .. " has no character")
		end
		pos -= Vector3.new(0, 3, 0)
	end
	local offset = toVec(args.offset)
	if pos and offset then
		pos += offset
	end
	if not pos then
		error("pos, path or to required")
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum and hum.Sit then
		hum.Sit = false
		task.wait()
	end
	local rot = char:GetPivot().Rotation
	char:PivotTo(CFrame.new(pos + Vector3.new(0, 3, 0)) * rot)
	log("teleport", with(who(p), { pos = v3(pos) }))
	return true
end

------------------------------------------------------------------------------- obby commands

local OBBY_TIMEOUT = 20 -- seconds per obby_try attempt (one checkpoint to the next)
local OBBY_ATTEMPTS = 5
local OBBY_FALL = 12 -- studs below the lower of the two checkpoints' tops: the runner fell off the course
local OBBY_BUDGET = 100 -- seconds for all of one obby_try's attempts (Python waits at most 115)
local OBBY_OVERHEAD = 15 -- per attempt besides the run: a respawn (up to 10 s), settling, the teleport, the path

local function waitAlive(p: any, timeout: number): (Model?, Humanoid?, BasePart?)
	local t0 = os.clock()
	repeat
		local char = p.Character
		local hum = char and char.Parent and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if hum and root and hum.Health > 0 then
			return char, hum, root
		end
		task.wait(0.2)
	until os.clock() - t0 > timeout
	return nil, nil, nil
end

-- teleport_stage {userId, stage}: stand the player on top of the checkpoint tagged Stage = stage, so a tester
-- can start anywhere on a long course instead of walking it from stage 1.
local function teleportStage(args)
	local p = playerArg(args)
	local stage = tonumber(args.stage)
	if not stage then
		error("stage required (a checkpoint's Stage number)", 0)
	end
	local cps, count = checkpoints()
	local part = stagePart(cps, stage)
	if not part then
		local have = {}
		for n in cps do
			table.insert(have, n)
		end
		table.sort(have)
		error(string.format("no checkpoint with Stage %s (%d parts tagged %s%s)", tostring(args.stage), count,
			OBBY_CHECKPOINT, if #have > 0 then string.format(", stages %s..%s", tostring(have[1]), tostring(have[#have])) else ""), 0)
	end
	local old = p.Character
	local oldHum = old and old:FindFirstChildOfClass("Humanoid")
	local char, hum, root = waitAlive(p, 10)
	if not char or not hum or not root then
		error(p.Name .. " has no living character", 0)
	end
	if char ~= old or not oldHum or oldHum.Health <= 0 then
		task.wait(1) -- a fresh respawn: the game's own spawn code moves the body first
	end
	if hum.Sit then
		hum.Sit = false
		task.wait()
	end
	local top = topOf(part)
	local spot = top + Vector3.new(0, 3, 0)
	for _ = 1, 2 do
		char:PivotTo(CFrame.new(spot) * char:GetPivot().Rotation)
		root.AssemblyLinearVelocity = Vector3.zero
		task.wait(0.4) -- land on it, so the checkpoint's own Touched handler runs
		if (root.Position - spot).Magnitude < 6 then
			break -- else the game moved it (a spawn or checkpoint handler): once more
		end
	end
	log("teleport_stage", with(who(p), { stage = stage }))
	return obj({ stage = stage, path = part:GetFullName(), pos = v3(top), player_stage = stageOf(p), stages = count,
		next = nextStage(cps, stage) })
end

-- standing on the part: over its top face, a body height above it (a character's root is ~3 studs up), grounded
local function onTop(root: BasePart, hum: Humanoid, part: BasePart): boolean
	local rel = part.CFrame:PointToObjectSpace(root.Position)
	return hum.FloorMaterial ~= Enum.Material.Air and math.abs(rel.X) <= part.Size.X / 2 + 0.5
		and math.abs(rel.Z) <= part.Size.Z / 2 + 0.5 and rel.Y >= part.Size.Y / 2 and rel.Y <= part.Size.Y / 2 + 5
end

-- One deterministic run from `fromPart` toward `toPart`: PathfindingService waypoints (AgentCanJump) with
-- Humanoid:MoveTo + Jump, then a straight run at the goal that jumps at a platform edge, when blocked, and when
-- the goal is a step up. The server drives the body (for a real player it holds physics ownership for the run).
local function obbyRun(p: any, toStage: number, fromPart: BasePart, toPart: BasePart, timeout: number)
	local char = p.Character
	local hum = char and char.Parent and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not char or not hum or not root or hum.Health <= 0 then
		return { result = "not_started", detail = p.Name .. " died or respawned right after the teleport" }
	end
	if flat(root.Position - fromPart.Position).Magnitude > math.max(fromPart.Size.X, fromPart.Size.Z) / 2 + 3 then
		return { result = "not_started", detail = "the game moved the body off the start checkpoint (to "
			.. table.concat(v3(root.Position), ", ") .. ")" }
	end
	local real = not isBot(p)
	if real then
		pcall(root.SetNetworkOwner, root, nil)
	end
	local goal = topOf(toPart)
	local floorY = math.min(topOf(fromPart).Y, goal.Y) - OBBY_FALL
	local stage0 = stageOf(p) -- an obby only counts up, so a stage reached earlier says nothing about this run
	local hazard: Instance? = nil
	local conns = {}
	for _, h in CollectionService:GetTagged(OBBY_HAZARD) do
		if h:IsA("BasePart") and ((h.Position - goal).Magnitude < 200 or (h.Position - root.Position).Magnitude < 200) then
			table.insert(conns, h.Touched:Connect(function(hit)
				if hazard == nil and hit:IsDescendantOf(char) then
					hazard = h
				end
			end))
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local t0 = os.clock()
	local lastFloor: string? = nil
	local jumps = 0
	local function outcome(): string?
		if char.Parent == nil or hum.Health <= 0 or hazard ~= nil or root.Position.Y < floorY then
			return "fell"
		end
		local st = stageOf(p)
		if onTop(root, hum, toPart) or (st ~= nil and st >= toStage and (stage0 == nil or st > stage0)) then
			return "reached"
		end
		return nil
	end
	local function sample()
		if hum.FloorMaterial ~= Enum.Material.Air then
			local hit = workspace:Raycast(root.Position, Vector3.new(0, -8, 0), params)
			if hit then
				lastFloor = hit.Instance:GetFullName()
			end
		end
	end
	local function jump()
		if hum.FloorMaterial ~= Enum.Material.Air then
			hum.Jump = true
			jumps += 1
		end
	end
	-- a solid hazard (a lava strip) is floor to pathfinding and to a raycast, but a player jumps it
	local function solidFloor(hit: RaycastResult?): boolean
		return hit ~= nil and not CollectionService:HasTag(hit.Instance, OBBY_HAZARD)
	end
	local result: string? = nil
	local via = "path"
	-- the route: PathfindingService waypoints (AgentCanJump) minus the ones on a hazard, else straight at the goal
	local targets: { { pos: Vector3, jump: boolean } } = {}
	local path = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 3 })
	local okPath = pcall(path.ComputeAsync, path, root.Position, goal)
	if okPath and path.Status == Enum.PathStatus.Success then
		for i, wp in path:GetWaypoints() do
			local under = workspace:Raycast(wp.Position + Vector3.new(0, 2, 0), Vector3.new(0, -6, 0), params)
			if i > 1 and (under == nil or solidFloor(under)) then
				table.insert(targets, { pos = wp.Position, jump = wp.Action == Enum.PathWaypointAction.Jump })
			end
		end
	else
		via = "straight (no path: " .. (if okPath then path.Status.Name else "ComputeAsync failed") .. ")"
	end
	table.insert(targets, { pos = goal, jump = false })
	local idx, jumpAt = 1, nil
	local best, lastGain = flat(goal - root.Position).Magnitude, os.clock()
	while os.clock() - t0 < timeout and os.clock() - lastGain < 4 do
		local tgt = targets[idx]
		if idx < #targets and flat(tgt.pos - root.Position).Magnitude < 1.5 then
			if tgt.jump then
				jumpAt = os.clock() -- a Jump waypoint is the take-off point: jump from here
			end
			idx += 1
			tgt = targets[idx]
		end
		hum:MoveTo(tgt.pos)
		if hum.FloorMaterial ~= Enum.Material.Air then
			local dir = flat(tgt.pos - root.Position)
			if jumpAt and os.clock() - jumpAt < 0.6 then
				jump()
				jumpAt = nil
			elseif dir.Magnitude > 0.5 and not solidFloor(workspace:Raycast(root.Position + dir.Unit * 1.5, Vector3.new(0, -6, 0), params)) then
				jump() -- the platform ends just ahead (or a hazard is the floor there): jump it
			elseif tgt.pos.Y > root.Position.Y - 1 and dir.Magnitude < 6 then
				jump() -- a step up (the root rides ~3 studs above the floor)
			end
		end
		task.wait(0.05)
		sample()
		result = outcome()
		if result then
			break
		end
		local d = flat(goal - root.Position).Magnitude
		if d < best - 0.5 then
			best, lastGain = d, os.clock()
		elseif os.clock() - lastGain > 1.2 then
			jump() -- held up by a lip or a wall: hop
		end
	end
	for _, c in conns do
		c:Disconnect()
	end
	if hum.Parent and hum.Health > 0 then
		hum:MoveTo(root.Position)
	end
	if real and root.Parent then
		pcall(root.SetNetworkOwner, root, p)
	end
	result = result or "stuck"
	local at, secs, dist = v3(root.Position), os.clock() - t0, flat(goal - root.Position).Magnitude
	local where = table.concat(at, ", ")
	local detail
	if result == "reached" then
		detail = string.format("reached stage %d in %.1fs (%d jumps, %s)", toStage, secs, jumps, via)
	elseif result == "fell" then
		local how = if hazard then "on hazard " .. hazard:GetFullName()
			elseif hum.Health <= 0 or char.Parent == nil then "and died"
			else "off the course"
		detail = string.format("fell %s at [%s] after %.1fs, %.0f studs short of stage %d%s (%d jumps, %s)", how, where,
			secs, dist, toStage, if lastFloor then "; last ground " .. lastFloor else "", jumps, via)
	else
		detail = string.format("stuck at [%s] after %.1fs, %.0f studs short of stage %d%s (%d jumps, %s)", where, secs,
			dist, toStage, if lastFloor then " on " .. lastFloor else "", jumps, via)
	end
	return { result = result, at = at, dist = r(dist), secs = r(secs), jumps = jumps, via = via,
		hazard = if hazard then hazard:GetFullName() else nil, last_floor = lastFloor, detail = detail }
end

-- obby_try {userId, from_stage?, to_stage?, attempts?=1, timeout?=20}: stand the player on checkpoint from_stage
-- (default: their stage) and let a deterministic runner (obbyRun, no LLM) go for the next checkpoint, up to
-- `attempts` times. -> {done = reached, from_stage, to_stage, attempts: [{result = reached | fell | stuck, at,
-- dist, secs, jumps, hazard?, last_floor?, detail}], detail}
local function obbyTry(args)
	local p = playerArg(args)
	local cps = checkpoints()
	local from = tonumber(args.from_stage or args.stage) or stageOf(p)
	if not from then
		error("from_stage required (the player has no Stage yet)", 0)
	end
	local to = tonumber(args.to_stage) or nextStage(cps, from)
	local fromPart = stagePart(cps, from)
	if fromPart and not (to and cps[to]) then
		error(string.format("no checkpoint after stage %s", tostring(from)), 0)
	end
	local attempts = math.clamp(math.floor(tonumber(args.attempts) or 1), 1, OBBY_ATTEMPTS)
	local per = math.clamp(tonumber(args.timeout) or OBBY_TIMEOUT, 3, 60)
	local tries, reached, started = {}, false, os.clock()
	for i = 1, attempts do
		if i > 1 and os.clock() - started + per + OBBY_OVERHEAD > OBBY_BUDGET then
			break -- the whole call has to answer inside one Studio MCP call
		end
		local res
		for _ = 1, 2 do -- the game can kill or move the body right after the teleport: once more
			teleportStage({ userId = p, stage = from }) -- errors with the stage listing when from_stage is unknown
			res = obbyRun(p, to :: number, fromPart :: BasePart, cps[to :: number], per)
			if res.result ~= "not_started" then
				break
			end
		end
		if res.result == "not_started" then
			res.result, res.detail = "stuck", "could not start: " .. res.detail
		end
		res.attempt = i
		table.insert(tries, res)
		if res.result == "reached" then
			reached = true
			break
		end
	end
	local last = tries[#tries]
	log("obby_try", with(who(p), { from = from, to = to, reached = reached, attempts = #tries, result = last.result }))
	return obj({ done = reached, from_stage = from, to_stage = to, reached = reached, attempts = tries,
		detail = string.format("stage %s -> %s: %s after %d attempt(s); last: %s", tostring(from), tostring(to),
			if reached then "reached" else "NOT reached", #tries, tostring(last.detail)) })
end

local function config(args)
	local name = tostring(args.module or "")
	local ms = findModule(name)
	if not ms then
		error("no ModuleScript named " .. name)
	end
	local mod = require(ms) :: any
	if type(mod) ~= "table" then
		error(name .. " is not a table module")
	end
	local key = args.key
	if key == nil then
		local out = obj({})
		for k, v in mod do
			if type(v) ~= "function" then
				out[tostring(k)] = val(v)
			end
		end
		return out
	end
	if args.value == nil then
		return { module = name, key = key, value = val(mod[key]) }
	end
	local old = mod[key]
	local value = args.value
	if typeof(old) == "Vector3" then
		value = toVec(value) or error("value must be [x,y,z]")
	end
	if type(mod.Set) == "function" then
		mod.Set(key, value)
	else
		if old == nil then
			error("unknown key " .. tostring(key))
		end
		mod[key] = value
	end
	log("config", { module = name, key = key, value = val(mod[key]), old = val(old) })
	return { module = name, key = key, value = val(mod[key]), old = val(old) }
end

local function kindSet(kinds: any): { [string]: boolean }?
	if kinds == nil or kinds == "" then
		return nil
	end
	local set = {}
	if type(kinds) == "string" then
		for k in string.gmatch(kinds, "[^,%s]+") do
			set[k] = true
		end
	elseif type(kinds) == "table" then
		for _, k in kinds do
			set[tostring(k)] = true
		end
	end
	return set
end

-- events {since?, instanceId?, squadId?, kinds?}: scoped event log. With instanceId, events that
-- carry another instance's id are dropped; unstamped world events are kept unless strict=true.
local function eventsCmd(args)
	local since = tonumber(args.since) or -1
	local iid = nonEmpty(args.instanceId)
	local sid = nonEmpty(args.squadId)
	local kinds = kindSet(args.kinds)
	local strict = args.strict == true
	local out = {}
	for _, e in events do
		if e.t > since and (not kinds or kinds[e.kind]) then
			local d = e.data or {}
			local keep = true
			if iid then
				local eid = nonEmpty(d.instanceId)
				keep = (eid == iid) or (eid == nil and not strict and d.squadId == nil)
			end
			if keep and sid then
				keep = nonEmpty(d.squadId) == sid
			end
			if keep then
				table.insert(out, { t = e.t, kind = e.kind, data = e.data })
			end
		end
	end
	return { now = now(), events = out }
end

local function reset(args)
	local map = liveModule("MapService")
	local rebuilt = {}
	if map then
		if args.location then
			if type(map.RebuildLocation) ~= "function" then
				error("MapService has no RebuildLocation")
			end
			local m = map:RebuildLocation(tostring(args.location))
			if not m then
				error("unknown location " .. tostring(args.location))
			end
			table.insert(rebuilt, tostring(args.location))
		else
			local ids = {}
			for id in (if type(map.GetLocations) == "function" then map:GetLocations() else {}) do
				table.insert(ids, id)
			end
			table.sort(ids)
			for _, id in ids do
				map:RebuildLocation(id)
				table.insert(rebuilt, id)
				task.wait()
			end
		end
	end
	table.clear(events)
	log("reset", { rebuilt = rebuilt })
	return { rebuilt = rebuilt, map = map ~= nil }
end

local function round(args)
	local function state()
		local out = obj({})
		for _, k in WORLD_ATTRS do
			local v = workspace:GetAttribute(k)
			if v ~= nil then
				out[k] = val(v)
			end
		end
		return out
	end
	if args.state == nil then
		return state()
	end
	local want = tostring(args.state)
	local function idle(): boolean
		local s = workspace:GetAttribute("RoundState")
		return s == nil or ROUND_IDLE[tostring(s)] == true
	end
	local mission = liveModule("MissionService")
	local waited = 0
	if want == "Active" and mission and workspace:GetAttribute("RoundState") ~= "Active" and not idle() then
		-- the last round is still in its Results / cooldown phase: the game frees its players only back in
		-- the lobby, so a start now would do nothing (`wait`: how long to wait for that, default 30 s).
		-- Without MissionService this command sets RoundState itself, so there is nothing to wait for.
		local t0, limit = os.clock(), math.clamp(tonumber(args.wait) or ROUND_COOLDOWN, 0, 60)
		while os.clock() - t0 < limit and not idle() and workspace:GetAttribute("RoundState") ~= "Active" do
			task.wait(0.2)
		end
		waited = os.clock() - t0
		if workspace:GetAttribute("RoundState") == "Active" then
			local out = state()
			out.via, out.waited = "became Active by itself", r(waited)
			return out
		end
		task.wait(1) -- settle: the game finishes handing its players back
	end
	local via = "attribute"
	if mission then
		local ok, err = true, nil
		if want == "Active" and type(mission.StartRound) == "function" then
			ok, err = pcall(mission.StartRound, mission, args.location, tonumber(args.seconds))
			via = "MissionService:StartRound"
		elseif want == "Results" and type(mission.EndRound) == "function" then
			ok, err = pcall(mission.EndRound, mission, "forced")
			via = "MissionService:EndRound"
		end
		if not ok then
			via ..= " failed: " .. tostring(err) .. "; attribute"
			workspace:SetAttribute("RoundState", want)
		end
	end
	if via == "attribute" then
		workspace:SetAttribute("RoundState", want)
	end
	local out = state()
	out.via = via
	if waited > 0 then
		out.waited = r(waited)
	end
	return out
end

------------------------------------------------------------------------------- multiplayer / squads

-- §10 v1.5: LobbyService:Join(player, padId) -> squadId, :Launch(squadId, missionId) -> instanceId,
-- MissionService:StartMission(squad: {Player}, missionId, seconds?) -> instanceId, :EndMission(id, reason).
local JOIN_METHODS = { "Join", "_join" }
local LAUNCH_METHODS = { "Launch", "_launch" }
local END_METHODS = { "EndMission", "_endMission" }

local function waitFor(seconds: number, pred: () -> boolean): boolean
	local t0 = os.clock()
	while not pred() do
		if os.clock() - t0 >= seconds then
			return false
		end
		task.wait(0.1)
	end
	return true
end

local function filterPlayers(args): { Player }
	local iid, sid = nonEmpty(args.instanceId), nonEmpty(args.squadId)
	local only: { Player }? = nil
	if type(args.userIds) == "table" then
		only = {}
		for _, id in args.userIds do
			table.insert(only :: { Player }, resolvePlayer(id))
		end
	end
	local list = only or playerList()
	if not only and args.includeBots == true then
		list = table.clone(list)
		for _, b in bots do
			table.insert(list, b)
		end
	end
	local out = {}
	for _, p in list do
		if (not iid or nonEmpty(p:GetAttribute("InstanceId")) == iid) and (not sid or nonEmpty(p:GetAttribute("SquadId")) == sid) then
			table.insert(out, p)
		end
	end
	return out
end

-- queue {userId, pad, walk?, join?, wait?}: put a player on a SquadPad (teleport, or walk with
-- walk=true) and wait for their SquadId. If the pad itself didn't sign them up within `wait`,
-- LobbyService:Join(player, padId) is called (join=false skips that; join=true calls it at once).
local function queueCmd(args)
	local p = playerArg(args)
	local pad = findPad(if args.pad == nil then 1 else args.pad)
	local padId = val(pad:GetAttribute("PadId"))
	local via
	if args.walk then
		local res = act({ userId = p.UserId, action = "walk_to", args = { path = pad:GetFullName(), timeout = tonumber(args.timeout) or 20 } })
		via = "walk: " .. tostring(res.detail)
	else
		teleport({ userId = p.UserId, path = pad:GetFullName() })
		via = "teleport"
	end
	local function joined(): boolean
		return nonEmpty(p:GetAttribute("SquadId")) ~= nil
	end
	local wait = math.clamp(tonumber(args.wait) or 3, 0, 30)
	if args.join ~= true then
		waitFor(wait, joined)
	end
	if not joined() and args.join ~= false then
		local status, lobby = serviceStatus("LobbyService")
		local name, fn = findMethod(lobby, JOIN_METHODS)
		if not fn then
			unsupported("LobbyService (" .. status .. ") has no Join and the pad did not sign the player up")
		end
		local ok, res = pcall(fn, lobby, p, tonumber(padId) or padId)
		via ..= string.format("; LobbyService:%s -> %s", tostring(name), if ok then tostring(res) else "error " .. tostring(res))
		waitFor(wait, joined)
		if not joined() and status == "stub" then
			unsupported("LobbyService is a K0 stub (Join did nothing)")
		end
	end
	local sid = nonEmpty(p:GetAttribute("SquadId"))
	return obj({ player = who(p), pad = padId, padPath = pad:GetFullName(), squadId = sid, joined = sid ~= nil, via = via })
end

local function findSquad(args)
	local data = squadsCmd({})
	local sid = nonEmpty(args.squadId)
	if not sid and args.player ~= nil then
		sid = nonEmpty(resolvePlayer(args.player):GetAttribute("SquadId"))
	end
	local padN = tonumber(args.pad)
	for _, s in data.squads do
		if (sid and tostring(s.id) == sid) or (not sid and padN and tonumber(s.padId) == padN) then
			return s, data
		end
	end
	return nil, data
end

local function membersOf(squad): { Player }
	local out = {}
	for _, m in squad.members or {} do
		local ok, p = pcall(Players.GetPlayerByUserId, Players, tonumber(m.userId) or 0)
		if ok and p then
			table.insert(out, p)
		end
	end
	return out
end

-- launch {pad | squadId | player, missionId?, wait?}: launch now via LobbyService:Launch(squadId,
-- missionId) (skips the leader's board + countdown). missionId defaults to the squad's choice, then
-- the first enabled MissionCatalog entry.
local function launchCmd(args)
	local status, lobby = serviceStatus("LobbyService")
	if not lobby then
		unsupported("no LobbyService")
	end
	local squad, data = findSquad(args)
	if not squad then
		if #data.squads == 0 and status == "stub" then
			unsupported("LobbyService is a K0 stub (no squads)")
		end
		error("no squad for " .. (if args.squadId then "squadId " .. tostring(args.squadId) else "pad " .. tostring(args.pad)), 0)
	end
	local sid = squad.id
	local notes = {}
	local missionId = nonEmpty(args.missionId) or nonEmpty(squad.missionId) or catalogIds()[1]
	if not missionId then
		error("missionId required (squad chose none and MissionCatalog has no enabled mission)", 0)
	end
	local name, fn = findMethod(lobby, LAUNCH_METHODS)
	if not fn then
		unsupported("LobbyService (" .. status .. ") has no Launch")
	end
	local ok, res = pcall(fn, lobby, sid, missionId)
	if not ok then
		error("LobbyService:" .. tostring(name) .. " failed: " .. tostring(res), 0)
	end
	table.insert(notes, string.format("LobbyService:%s(%s, %s) -> %s", tostring(name), tostring(sid), missionId, tostring(res)))
	local members = membersOf(squad)
	waitFor(math.clamp(tonumber(args.wait) or 8, 0, 60), function()
		for _, p in members do
			if not nonEmpty(p:GetAttribute("InstanceId")) then
				return false
			end
		end
		return #members > 0
	end)
	local iid = if type(res) == "string" then nonEmpty(res) elseif type(res) == "table" then nonEmpty(res.instanceId) else nil
	for _, p in members do
		iid = iid or nonEmpty(p:GetAttribute("InstanceId"))
	end
	if not iid and status == "stub" then
		unsupported("LobbyService is a K0 stub (launch did nothing)")
	end
	local whos = {}
	for _, p in members do
		table.insert(whos, with(who(p), { instanceId = nonEmpty(p:GetAttribute("InstanceId")) }))
	end
	return obj({ squadId = sid, pad = squad.padId, missionId = missionId, instanceId = iid, members = whos, via = table.concat(notes, "; "), result = plain(res) })
end

-- mission_start {missionId?, players?: [..] | "all", seconds?, wait?}:
-- MissionService:StartMission(players, missionId, seconds?) -> instanceId.
local function missionStartCmd(args)
	local status, mission = serviceStatus("MissionService")
	if not mission or type(mission.StartMission) ~= "function" then
		unsupported("MissionService:StartMission not available (" .. status .. ")")
	end
	local list = {}
	local ids = args.players
	if ids == nil or ids == "all" then
		list = playerList()
	else
		if type(ids) ~= "table" then
			ids = { ids }
		end
		for _, id in ids do
			table.insert(list, resolvePlayer(id))
		end
	end
	if #list == 0 then
		error("no players to start a mission with", 0)
	end
	local missionId = tostring(args.missionId or "")
	if missionId == "" then
		missionId = catalogIds()[1] or error("missionId required (MissionCatalog has no enabled mission)", 0)
	end
	local ok, res = pcall(mission.StartMission, mission, list, missionId, tonumber(args.seconds))
	if not ok then
		error("MissionService:StartMission failed: " .. tostring(res), 0)
	end
	waitFor(math.clamp(tonumber(args.wait) or 8, 0, 60), function()
		for _, p in list do
			if not nonEmpty(p:GetAttribute("InstanceId")) then
				return false
			end
		end
		return true
	end)
	local iid = if type(res) == "string" then nonEmpty(res) elseif type(res) == "table" then nonEmpty(res.instanceId) else nil
	for _, p in list do
		iid = iid or nonEmpty(p:GetAttribute("InstanceId"))
	end
	if not iid then
		if status == "stub" then
			unsupported("MissionService is a K0 stub (StartMission did nothing)")
		end
		error("StartMission returned no instanceId and no player got an InstanceId", 0)
	end
	local whos = {}
	for _, p in list do
		table.insert(whos, with(who(p), { instanceId = nonEmpty(p:GetAttribute("InstanceId")) }))
	end
	return obj({ instanceId = iid, missionId = missionId, players = whos, result = plain(res) })
end

-- mission_end {instanceId | player, reason?="forced", wait?}
local function missionEndCmd(args)
	local status, mission = serviceStatus("MissionService")
	local id = nonEmpty(args.instanceId)
	if not id and args.player ~= nil then
		id = nonEmpty(resolvePlayer(args.player):GetAttribute("InstanceId"))
	end
	if not id then
		error("instanceId required", 0)
	end
	local name, fn = findMethod(mission, END_METHODS)
	if not fn then
		unsupported("MissionService (" .. status .. ") has no EndMission/EndInstance")
	end
	local ok, res = pcall(fn, mission, id, tostring(args.reason or "forced"))
	if not ok then
		error("MissionService:" .. tostring(name) .. " failed: " .. tostring(res), 0)
	end
	local function remaining(): number
		local n = 0
		for _, p in playerList() do
			if nonEmpty(p:GetAttribute("InstanceId")) == id then
				n += 1
			end
		end
		return n
	end
	local function state(): any
		if type(mission.GetMission) == "function" then
			local okRun, run = pcall(mission.GetMission, mission, id)
			if okRun and type(run) == "table" then
				return run.state
			end
			return if okRun then "gone" else nil
		end
		return nil
	end
	-- ended = state Results/gone, or everyone back in the lobby (players return after ReturnSeconds)
	waitFor(math.clamp(tonumber(args.wait) or 5, 0, 60), function()
		local s = state()
		return remaining() == 0 or s == "Results" or s == "gone"
	end)
	return obj({ instanceId = id, via = "MissionService:" .. tostring(name), result = plain(res), state = state(), playersStillIn = remaining() })
end

-- blame {instanceId?, squadId?, awards?}: BlameService stats per player (and awards).
local function blameCmd(args)
	local status, blame = serviceStatus("BlameService")
	if not blame or type(blame.GetStats) ~= "function" then
		unsupported("BlameService:GetStats not available (" .. status .. ")")
	end
	local stats = {}
	for _, p in filterPlayers(args) do
		local ok, s = pcall(blame.GetStats, blame, p)
		table.insert(stats, if ok then plain(s) else with(who(p), { error = tostring(s) }))
	end
	local out = obj({ service = status, stats = stats })
	if args.awards and type(blame.BuildAwards) == "function" then
		local ok, a = pcall(blame.BuildAwards, blame)
		out.awards = if ok then plain(a) else tostring(a)
	end
	return out
end

-- hook {module, fn, args?}: call a function on a live module (same require cache as the game), like
-- ServerStorage.DevHook. fn "Name" = method call (mod:Name(...)), ".name" = dot call. Arg objects
-- {"player": id} become that Player, {"character": id} their character, {"path": p} the instance,
-- {"vec": [x,y,z]} a Vector3.
local function hookCmd(args)
	local name = tostring(args.module or "")
	local status, mod = serviceStatus(name)
	if not mod then
		unsupported("no module " .. name)
	end
	local fname = tostring(args.fn or "")
	local dot = string.sub(fname, 1, 1) == "."
	if dot then
		fname = string.sub(fname, 2)
	end
	local fn = mod[fname]
	if type(fn) ~= "function" then
		unsupported(name .. " (" .. status .. ") has no function " .. fname)
	end
	local callArgs = {}
	local n = 0
	for i, a in (if type(args.args) == "table" then args.args else {}) do
		n = math.max(n, i)
		if type(a) == "table" and a.player ~= nil then
			callArgs[i] = resolvePlayer(a.player)
		elseif type(a) == "table" and a.character ~= nil then
			callArgs[i] = resolvePlayer(a.character).Character
		elseif type(a) == "table" and a.path ~= nil then
			callArgs[i] = mustPath(a.path)
		elseif type(a) == "table" and a.vec ~= nil then
			callArgs[i] = toVec(a.vec)
		else
			callArgs[i] = a
		end
	end
	local packed
	if dot then
		packed = table.pack(pcall(fn, table.unpack(callArgs, 1, n)))
	else
		packed = table.pack(pcall(fn, mod, table.unpack(callArgs, 1, n)))
	end
	if not packed[1] then
		error(name .. "." .. fname .. " failed: " .. tostring(packed[2]), 0)
	end
	local results = {}
	for i = 2, packed.n do
		local v = plain(packed[i])
		results[i - 1] = if v == nil then "nil" else v
	end
	return obj({ module = name, fn = fname, status = status, result = results[1], results = results })
end

-- caps {}: which services exist / are stubs, their methods and signals, tag counts, catalog.
local function capsCmd()
	local services = obj({})
	for _, name in KNOWN_SERVICES do
		local status, mod = serviceStatus(name)
		local e = obj({ status = status })
		if mod then
			local methods, signals = {}, {}
			for k, v in mod do
				if type(k) == "string" then
					if type(v) == "function" then
						table.insert(methods, k)
					elseif type(v) == "table" and type(v.Connect) == "function" then
						table.insert(signals, k)
					end
				end
			end
			table.sort(methods)
			table.sort(signals)
			e.methods, e.signals = methods, signals
		end
		services[name] = e
	end
	local tags = obj({})
	for _, t in TAGS do
		tags[t] = #CollectionService:GetTagged(t)
	end
	local instances = {}
	for id in scanInstanceModels(true) do
		table.insert(instances, id)
	end
	return obj({
		version = VERSION, studio = IS_STUDIO, players = #Players:GetPlayers(), services = services, tags = tags,
		catalog = catalogIds(), instanceModels = instances,
	})
end

local commands: { [string]: (any) -> any } = {
	ping = function()
		return {
			version = VERSION,
			players = #Players:GetPlayers(),
			agents = (function()
				local n = 0
				for p in agents do
					if p.Parent == Players then
						n += 1
					end
				end
				return n
			end)(),
			studio = true,
			time = workspace:GetServerTimeNow(),
			clock = now(),
			mapReady = workspace:GetAttribute("MapReady") == true,
			session = remote:GetAttribute("Session"),
			bots = #bots,
		}
	end,
	caps = capsCmd,
	players = function(args)
		local out = {}
		for _, p in filterPlayers(args) do
			table.insert(out, playerInfo(p))
		end
		return out
	end,
	squads = squadsCmd,
	instances = instancesList,
	queue = queueCmd,
	launch = launchCmd,
	mission_start = missionStartCmd,
	mission_end = missionEndCmd,
	blame = blameCmd,
	hook = hookCmd,
	observe = observe,
	act = act,
	ui = agentCmd("ui"),
	ui_target = agentCmd("ui_target"),
	ui_effect = agentCmd("ui_effect"),
	query = query,
	inspect = inspect,
	set_attr = setAttr,
	ignite = ignite,
	extinguish = extinguish,
	teleport = teleport,
	teleport_stage = teleportStage,
	obby_try = obbyTry,
	config = config,
	counters = counters,
	events = eventsCmd,
	reset = reset,
	round = round,
}

local runCommand: (cmd: any, argsJson: any) -> any -- forward, below

-- multi {calls: [{cmd, args}], timeout?}: run several commands concurrently (one thread each) and
-- return their replies in order: [{ok, result?, error?}]. One MCP round trip for a whole swarm tick.
local MULTI_TIMEOUT = 90
commands.multi = function(args)
	local calls = args.calls
	if type(calls) ~= "table" then
		error("multi needs calls: [{cmd, args}]")
	end
	local n = #calls
	local results = table.create(n)
	local pending = n
	for i, c in calls do
		local cmd = type(c) == "table" and c.cmd or nil
		if cmd == "multi" then
			results[i] = { ok = false, error = "multi can't be nested" }
			pending -= 1
		else
			task.spawn(function()
				local reply = runCommand(cmd, if type(c) == "table" then c.args else nil)
				if results[i] == nil then
					results[i] = reply
					pending -= 1
				end
			end)
		end
	end
	local limit = math.clamp(tonumber(args.timeout) or MULTI_TIMEOUT, 1, 300)
	local t0 = os.clock()
	while pending > 0 and os.clock() - t0 < limit do
		task.wait(0.03)
	end
	for i = 1, n do
		if results[i] == nil then
			results[i] = { ok = false, error = string.format("timed out after %ds in multi", limit) }
		end
	end
	return results
end
commands.bot_spawn = botSpawn
commands.bot_clear = botClear
commands.bots = function()
	local out = {}
	for _, b in bots do
		table.insert(out, playerInfo(b))
	end
	return out
end

local function decodeArgs(argsJson: any)
	if type(argsJson) == "table" then
		return argsJson
	end
	if argsJson == nil or argsJson == "" then
		return {}
	end
	local ok, res = pcall(HttpService.JSONDecode, HttpService, tostring(argsJson))
	if not ok then
		error("args are not valid JSON: " .. tostring(res))
	end
	if type(res) ~= "table" then
		error("args must be a JSON object")
	end
	return res
end

local bf = getOrCreate(ServerStorage, "ForgeTest", "BindableFunction") :: BindableFunction
runCommand = function(cmd: any, argsJson: any): any
	local ok, res = pcall(function()
		local fn = commands[tostring(cmd)]
		if not fn then
			local names = {}
			for k in commands do
				table.insert(names, k)
			end
			table.sort(names)
			error("unknown command '" .. tostring(cmd) .. "' (one of: " .. table.concat(names, ", ") .. ")")
		end
		return fn(decodeArgs(argsJson))
	end)
	if ok then
		return { ok = true, result = res }
	end
	local msg = tostring(res)
	-- strip "ServerScriptService.ForgeTest:123: " so errors read cleanly
	msg = string.gsub(msg, "^[%w%.]+:%d+: ", "")
	return { ok = false, error = msg }
end
dispatchCommand = function(cmd: any, argsJson: any): string
	local reply = runCommand(cmd, argsJson)
	local encOk, json = pcall(encode, reply)
	if encOk then
		return json
	end
	return '{"ok":false,"error":' .. escape("encode failed: " .. tostring(json)) .. "}"
end
bf.OnInvoke = dispatchCommand

print("[ForgeTest] ready: ServerStorage.ForgeTest, ReplicatedStorage.ForgeTestRemote")
