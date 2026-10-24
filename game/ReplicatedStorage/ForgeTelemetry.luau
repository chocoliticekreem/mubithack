--!strict
-- ForgeTelemetry: tiny counter API for generated games. ForgeProbe reports these counters.
--
--   local ForgeTelemetry = require(game:GetService("ReplicatedStorage").ForgeTelemetry)
--   ForgeTelemetry.count("coins_collected")      -- +1
--   ForgeTelemetry.count("damage_dealt", 25)     -- +25
--   ForgeTelemetry.get()                          -- { coins_collected = 1, damage_dealt = 25 }
--
-- Counters live as number attributes on ServerStorage.ForgeCounters (a Folder), so every VM in the
-- server (game scripts, ForgeProbe, execute_luau) sees the same values. get() is server only: on the
-- client it returns {}.
--
-- count() also works in LocalScripts and client modules (Studio playtests, where ForgeProbe reads the
-- counters; elsewhere it is a no-op on the client). The client adds counts up and sends them at most
-- every FLUSH_SECONDS through one RemoteEvent, ReplicatedStorage.ForgeTelemetryRemote, which the server
-- copy of this module creates when it is first required in a running playtest (ForgeProbe requires it
-- at boot). The server never trusts the client: a name must match NAME_PATTERN and be at most
-- MAX_NAME_LEN chars, a player may use at most MAX_NAMES_PER_PLAYER distinct names, a message carries at
-- most MAX_BATCH names and at most MAX_ADD per name, and a player may send MAX_SENDS_PER_SECOND messages
-- a second. Anything else is dropped and counted as telemetry_client_dropped. A game never needs its own
-- remote or "Ack" script to count a client-side moment.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FOLDER_NAME = "ForgeCounters"
local REMOTE_NAME = "ForgeTelemetryRemote"
local NAME_PATTERN = "^[%w_]+$"
local MAX_NAME_LEN = 64
local MAX_NAMES_PER_PLAYER = 64
local MAX_BATCH = 32
local MAX_ADD = 1000
local MAX_SENDS_PER_SECOND = 8
local FLUSH_SECONDS = 0.25
local REMOTE_WAIT = 10
local DROPPED = "telemetry_client_dropped"

local ForgeTelemetry = {}

local function folder(): Instance?
	if not RunService:IsServer() then
		return nil
	end
	local ServerStorage = game:GetService("ServerStorage")
	local f = ServerStorage:FindFirstChild(FOLDER_NAME)
	if not f then
		f = Instance.new("Folder")
		f.Name = FOLDER_NAME
		f.Parent = ServerStorage
	end
	return f
end

-- Attribute names: letters, digits and underscores, max 100 chars, may not start with "RBX".
local function key(name: string): string
	local k = string.gsub(tostring(name), "[^%w_]", "_")
	if k == "" then
		k = "_"
	end
	if string.sub(k, 1, 3) == "RBX" then
		k = "_" .. k
	end
	return string.sub(k, 1, 100)
end

local function validName(name: any): boolean
	return type(name) == "string"
		and #name <= MAX_NAME_LEN
		and string.match(name, NAME_PATTERN) ~= nil
		and string.sub(name, 1, 3) ~= "RBX"
end

local function validAdd(n: any): boolean
	return type(n) == "number" and n == n and n > 0 and n ~= math.huge
end

local function countServer(name: string, n: number?)
	local f = folder()
	if not f then
		return
	end
	local ok = pcall(function()
		local k = key(name)
		local cur = f:GetAttribute(k)
		local add = tonumber(n) or 1
		f:SetAttribute(k, (if type(cur) == "number" then cur else 0) + add)
	end)
	if not ok then
		-- telemetry must never break the game
		return
	end
end

-- ------------------------------------------------------------------ server end of the client channel

type Window = { start: number, sends: number }
type State = { names: { [Player]: { [string]: boolean } }, used: { [Player]: number }, windows: { [Player]: Window } }

local function onClientCounts(state: State, player: Player, batch: any)
	local now = os.clock()
	local w = state.windows[player]
	if not w or now - w.start >= 1 then
		w = { start = now, sends = 0 }
		state.windows[player] = w
	end
	w.sends += 1
	if w.sends > MAX_SENDS_PER_SECOND or type(batch) ~= "table" then
		countServer(DROPPED, 1)
		return
	end
	local names = state.names[player]
	if not names then
		names = {}
		state.names[player] = names
		state.used[player] = 0
	end
	local seen, dropped = 0, 0
	for name, add in batch do
		seen += 1
		if seen > MAX_BATCH then
			dropped += 1
			break
		end
		if not validName(name) or not validAdd(add) then
			dropped += 1
			continue
		end
		if not names[name] then
			if state.used[player] >= MAX_NAMES_PER_PLAYER then
				dropped += 1
				continue
			end
			names[name] = true
			state.used[player] += 1
		end
		countServer(name, math.min(add, MAX_ADD))
	end
	if dropped > 0 then
		countServer(DROPPED, dropped)
	end
end

-- One listener per server: the first VM that requires this module in a running Studio playtest owns
-- the remote (execute_luau and game scripts share it, so a second VM must not count everything twice).
local function listen()
	if not (RunService:IsServer() and RunService:IsRunning() and RunService:IsStudio()) then
		return
	end
	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME)
	if remote and remote:IsA("RemoteEvent") and remote:GetAttribute("Listening") == true then
		return
	end
	if not (remote and remote:IsA("RemoteEvent")) then
		if remote then
			remote:Destroy()
		end
		local created = Instance.new("RemoteEvent")
		created.Name = REMOTE_NAME
		created.Parent = ReplicatedStorage
		remote = created
	end
	local event = remote :: RemoteEvent
	event:SetAttribute("Listening", true)
	local state: State = { names = {}, used = {}, windows = {} }
	event.OnServerEvent:Connect(function(player: Player, batch: any)
		pcall(onClientCounts, state, player, batch)
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		state.names[player] = nil
		state.used[player] = nil
		state.windows[player] = nil
	end)
end

pcall(listen)

-- ------------------------------------------------------------------ client end

local pending: { [string]: number } = {}
local pendingNames = 0
local flushing = false

-- Runs on its own thread: the wait for the remote never blocks the caller, and counts made meanwhile
-- join this message. Without a server channel (no playtest), they are dropped.
local function flush()
	local remote = ReplicatedStorage:FindFirstChild(REMOTE_NAME) or ReplicatedStorage:WaitForChild(REMOTE_NAME, REMOTE_WAIT)
	local batch = pending
	pending = {}
	pendingNames = 0
	if remote and remote:IsA("RemoteEvent") and next(batch) ~= nil then
		(remote :: RemoteEvent):FireServer(batch)
	end
end

local function countClient(name: string, n: number?)
	if not RunService:IsStudio() then
		return
	end
	local k = key(name)
	local add = if n == nil then 1 else tonumber(n)
	if not validName(k) or not validAdd(add) then
		return
	end
	if pending[k] == nil then
		if pendingNames >= MAX_BATCH then
			return
		end
		pendingNames += 1
	end
	pending[k] = (pending[k] or 0) + (add :: number)
	if not flushing then
		flushing = true
		task.delay(FLUSH_SECONDS, function()
			pcall(flush)
			flushing = false
		end)
	end
end

function ForgeTelemetry.count(name: string, n: number?)
	if RunService:IsServer() then
		countServer(name, n)
		return
	end
	pcall(countClient, name, n)
end

function ForgeTelemetry.get(): { [string]: number }
	local out: { [string]: number } = {}
	if not RunService:IsServer() then
		return out
	end
	local f = game:GetService("ServerStorage"):FindFirstChild(FOLDER_NAME)
	if not f then
		return out
	end
	for k, v in f:GetAttributes() do
		if type(v) == "number" then
			out[k] = v
		end
	end
	return out
end

return ForgeTelemetry
