--!strict
-- FROZEN. Remotes are declared by the service that owns them, not in a shared Remotes file.
-- They live at ReplicatedStorage.Net.<Namespace>.<Name>. Call these from Init/Start only, never at
-- module top level (Edit-mode requires must not create Instances).
--
--   Server: local Spray = Net.event("Tool", "Spray")                       -- creates it
--           Net.onServer(Spray, { rate = 12, burst = 4 }, function(player, aim) ... end)
--   Client: local Spray = Net.event("Tool", "Spray")                       -- waits for it
--           Spray:FireServer(aim)
--   Either: Net.notify(player | "all", "Panda saved!", "good")             -- Shared/Notify toast

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local IS_SERVER = RunService:IsServer()
local WAIT_SECONDS = 15

local Net = {}

local function child(parent: Instance, name: string, className: string): Instance
	local found = parent:FindFirstChild(name)
	if found then
		return found
	end
	if not IS_SERVER then
		local waited = parent:WaitForChild(name, WAIT_SECONDS)
		if not waited then
			error(`[Net] {parent:GetFullName()}.{name} never appeared (server didn't declare it?)`)
		end
		return waited
	end
	local inst = Instance.new(className)
	inst.Name = name
	inst.Parent = parent
	return inst
end

local function namespace(ns: string): Instance
	return child(child(ReplicatedStorage, "Net", "Folder"), ns, "Folder")
end

function Net.event(ns: string, name: string): RemoteEvent
	return child(namespace(ns), name, "RemoteEvent") :: RemoteEvent
end

-- Client -> server request/response only. Never InvokeClient.
function Net.func(ns: string, name: string): RemoteFunction
	return child(namespace(ns), name, "RemoteFunction") :: RemoteFunction
end

-- Token bucket per player: `rate` events/second sustained, `burst` extra. Excess calls are dropped
-- and counted as ForgeTelemetry "net_dropped". Handler errors are caught and warned.
export type Limit = { rate: number, burst: number? }

function Net.onServer(remote: RemoteEvent, limit: Limit, handler: (Player, ...any) -> ())
	assert(IS_SERVER, "Net.onServer is server-only")
	local Telemetry = require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript) :: any
	local cap = limit.rate + (limit.burst or 0)
	local tokens: { [Player]: number } = {}
	local stamp: { [Player]: number } = {}
	remote.OnServerEvent:Connect(function(player: Player, ...: any)
		local t = os.clock()
		local have = math.min(cap, (tokens[player] or cap) + (t - (stamp[player] or t)) * limit.rate)
		stamp[player] = t
		if have < 1 then
			tokens[player] = have
			Telemetry.count("net_dropped")
			return
		end
		tokens[player] = have - 1
		local ok, err = pcall(handler, player, ...)
		if not ok then
			warn(`[Net] {remote:GetFullName()} handler: {err}`)
		end
	end)
	Players.PlayerRemoving:Connect(function(player: Player)
		tokens[player] = nil
		stamp[player] = nil
	end)
end

-- Validators: return the value if valid, else nil. Use on every client argument.
function Net.unit(v: any): Vector3?
	if typeof(v) ~= "Vector3" then
		return nil
	end
	local m = (v :: Vector3).Magnitude
	if m ~= m or m < 0.5 or m > 1.5 then -- NaN or not roughly unit length
		return nil
	end
	return (v :: Vector3).Unit
end

function Net.tagged(v: any, tag: string): BasePart?
	if typeof(v) ~= "Instance" or not (v :: Instance):IsA("BasePart") then
		return nil
	end
	if not (v :: Instance):HasTag(tag) or not (v :: Instance):IsDescendantOf(workspace) then
		return nil
	end
	return v :: BasePart
end

function Net.near(player: Player, pos: Vector3, maxStuds: number): boolean
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	return root ~= nil and (root.Position - pos).Magnitude <= maxStuds
end

-- Shared/Notify: server -> client toast; HudController renders it.
function Net.notify(target: Player | string, text: string, kind: string?)
	local remote = Net.event("Shared", "Notify")
	if target == "all" then
		remote:FireAllClients(text, kind or "info")
	elseif typeof(target) == "Instance" then
		remote:FireClient(target :: Player, text, kind or "info")
	end
end

return Net
