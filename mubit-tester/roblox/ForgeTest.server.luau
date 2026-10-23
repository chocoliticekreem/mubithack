-- ForgeTest: in-game test harness for the mubit-tester MCP server (Studio only). docs/TESTER.md.
--
-- ServerStorage.ForgeTest (BindableFunction)
--   :Invoke(cmd: string, argsJson: string?) -> JSON string {"ok": bool, "result": any, "error": string?}
--   cmds: ping, players, observe, act, query, inspect, set_attr, ignite, extinguish, teleport,
--         config, counters, events, reset, round
--   Players are addressed by `userId` (also `player`): a UserId, a helmet number (1-4), or a name.
--
-- ReplicatedStorage.ForgeTestRemote (RemoteFunction)
--   server -> client: InvokeClient(player, "ForgeTest", cmd, args) runs an action on that player's
--   client (StarterPlayerScripts/ForgeTestAgent). Always called with a timeout, because InvokeClient
--   can hang forever. client -> server: InvokeServer("ForgeTest", "hello") marks the agent ready.
--
-- Event log: ring buffer (500) of {t, kind, data}; t is seconds since this script started (the
-- same clock as `events.now` and `ping.clock`).

local RunService = game:GetService("RunService")
if not RunService:IsStudio() then
	return
end

local CollectionService = game:GetService("CollectionService")
local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local ServerStorage = game:GetService("ServerStorage")

local VERSION = "1"
local MAX_EVENTS = 500
local HUD_TIMEOUT = 3
local DEFAULT_ACT_TIMEOUT = 10
local WALK_TIMEOUT = 20

local TAGS = { "Burning", "Flammable", "Door", "Hydrant", "TruckRefill", "RescueDropoff", "Rescuable", "Truck", "StationSpawn" }
local THING_ATTRS = { "Locked", "Broken", "FireLevel", "RescueState", "Kind" }
local ME_ATTRS = { "Water", "TankSize", "Carrying", "Helmet", "Downed" }
local WORLD_ATTRS = { "RoundState", "RoundEndsAt", "MissionId" }
local ACTIONS = {
	walk_to = true, jump = true, interact = true, equip = true, unequip = true,
	use = true, look_at = true, say = true, wait = true,
}

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

local function findModule(name: string): ModuleScript?
	for _, container in { ServerScriptService, ServerStorage, ReplicatedStorage } do
		for _, d in container:GetDescendants() do
			if d.Name == name and d:IsA("ModuleScript") then
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

local function log(kind: string, data: any, coalesceKey: string?)
	data = obj(data or {})
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
local PLAYER_ATTRS = { Water = true, Carrying = true, Downed = true, Helmet = true }

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
			log("attr", with(who(player), { on = "character", key = key, value = val(char:GetAttribute(key)) }), "char:" .. player.UserId .. ":" .. key)
		end
	end)
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
			local data = with(who(player), { on = "player", key = key, value = val(v), old = val(last[key]) })
			last[key] = v
			log("attr", data, "player:" .. player.UserId .. ":" .. key)
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
local function watchTag(tag: string)
	CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
		log("tag_added", { tag = tag, path = inst:GetFullName(), pos = posOf(inst) })
		if tag == "Rescuable" and not rescueConns[inst] then
			rescueConns[inst] = inst:GetAttributeChangedSignal("RescueState"):Connect(function()
				log("attr", { on = inst:GetFullName(), key = "RescueState", value = val(inst:GetAttribute("RescueState")) })
			end)
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
	rescueConns[inst] = inst:GetAttributeChangedSignal("RescueState"):Connect(function()
		log("attr", { on = inst:GetFullName(), key = "RescueState", value = val(inst:GetAttribute("RescueState")) })
	end)
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

local remote = getOrCreate(ReplicatedStorage, "ForgeTestRemote", "RemoteFunction") :: RemoteFunction
remote.OnServerInvoke = function(player: Player, tag: any, cmd: any)
	if tag ~= "ForgeTest" then
		return false
	end
	if cmd == "hello" then
		agents[player] = now()
		log("agent_ready", who(player))
		return true
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
		agent = agents[p] ~= nil,
		hasCharacter = char ~= nil,
	})
end

local function burningish(inst: Instance): boolean
	return CollectionService:HasTag(inst, "Burning") or (tonumber(inst:GetAttribute("FireLevel")) or 0) > 0
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

	local seen, things = {}, {}
	for _, tag in TAGS do
		for _, inst in CollectionService:GetTagged(tag) do
			if not seen[inst] and inst:IsDescendantOf(workspace) and (tag ~= "Flammable" or burningish(inst)) then
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
				if dist <= promptRadius then
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

	local ok, hud = invokeClient(p, "hud", {}, HUD_TIMEOUT)
	if ok and type(hud) == "table" then
		out.hud = hud
	else
		out.hud_error = tostring(hud)
	end
	return out
end

local function act(args)
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
	if action == "wait" then
		local s = math.clamp(tonumber(a.seconds) or 1, 0, 60)
		task.wait(s)
		return { done = true, detail = string.format("waited %.1fs", s) }
	end
	-- Paths are resolved on the client, but an Instance can't be passed from JSON, so send strings.
	local timeout = DEFAULT_ACT_TIMEOUT
	if action == "walk_to" then
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
	local seen, rows = {}, {}
	for _, tag in tags do
		for _, inst in CollectionService:GetTagged(tag) do
			if not seen[inst] and inst:IsDescendantOf(workspace) then
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

local function nearestFlammable(origin: Vector3, radius: number, wantBurning: boolean): Instance?
	local best, bestD = nil, radius
	local list = if wantBurning then CollectionService:GetTagged("Burning") else CollectionService:GetTagged("Flammable")
	for _, inst in list do
		if inst:IsDescendantOf(workspace) and burningish(inst) == wantBurning then
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
	local inst = nearestFlammable(origin, tonumber(args.radius) or 60, wantBurning)
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
	if not pos then
		error("pos or path required")
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

local function eventsCmd(args)
	local since = tonumber(args.since) or -1
	local out = {}
	for _, e in events do
		if e.t > since then
			table.insert(out, { t = e.t, kind = e.kind, data = e.data })
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
	local mission = liveModule("MissionService")
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
	return out
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
		}
	end,
	players = function()
		local out = {}
		for _, p in playerList() do
			table.insert(out, playerInfo(p))
		end
		return out
	end,
	observe = observe,
	act = act,
	query = query,
	inspect = inspect,
	set_attr = setAttr,
	ignite = ignite,
	extinguish = extinguish,
	teleport = teleport,
	config = config,
	counters = counters,
	events = eventsCmd,
	reset = reset,
	round = round,
}

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
bf.OnInvoke = function(cmd: any, argsJson: any): string
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
	local reply
	if ok then
		reply = { ok = true, result = res }
	else
		local msg = tostring(res)
		-- strip "ServerScriptService.ForgeTest:123: " so errors read cleanly
		msg = string.gsub(msg, "^[%w%.]+:%d+: ", "")
		reply = { ok = false, error = msg }
	end
	local encOk, json = pcall(encode, reply)
	if encOk then
		return json
	end
	return '{"ok":false,"error":' .. escape("encode failed: " .. tostring(json)) .. "}"
end

print("[ForgeTest] ready: ServerStorage.ForgeTest, ReplicatedStorage.ForgeTestRemote")
