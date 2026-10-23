--!strict
-- AudioService [owner: AV lane]. Server side of audio: it never plays a Sound itself, it tells the right
-- clients *which* AudioConfig sound to play and where. AudioController (client) does the playing,
-- budgeting and mixing. Most audio needs no server help at all (the client derives crackle, ignite,
-- steam, doors, hose, ragdoll whistles, alarm, siren and music from tags, attributes and the Mission
-- remotes); this service covers the events only the server sees (friendly fire, rescues, zaps).
--
-- Public API:
--   AudioService:Play(target: Target, name: string, at: (Instance | Vector3)?, opts: { [string]: any }?): number
--   AudioService:Stinger(target: Target, kind: string): number      -- AudioConfig.Stingers[kind]
--   AudioService:PlayersIn(instanceId: string): { Player }          -- "" = everyone in the lobby
--   AudioService:GroupOf(player: Player): { Player }                 -- everyone in that player's instance
--     Target = Player | { Player } | "all" | instanceId (string). Returns how many clients were told.
-- Remotes (declared here): Audio/Play (S->C: name, at, opts), Audio/Stinger (S->C: kind)
-- Consumes (nil-guarded): RescueService.Rescued, SquadService.Downed, ToolService.HoseHit,
--   HazardService.Zapped. Counter: audio_cues.
-- Test hooks (DevHook only): _selftest()
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local AudioConfig = require(ReplicatedStorage:WaitForChild("Config"):WaitForChild("AudioConfig") :: ModuleScript) :: any

export type Target = Player | { Player } | string

local AudioService = {}
AudioService.Priority = 80

local services: { [string]: any } = {}
local playRemote: RemoteEvent? = nil
local stingerRemote: RemoteEvent? = nil
local lastSplash: { [Player]: number } = {}

local function count(name: string, n: number?)
	pcall(function()
		require(ReplicatedStorage:WaitForChild("ForgeTelemetry") :: ModuleScript).count(name, n or 1)
	end)
end

local function instanceOf(p: Player): string
	local v = p:GetAttribute(Names.Attr.InstanceId)
	return if type(v) == "string" then v else ""
end

function AudioService:PlayersIn(instanceId: string): { Player }
	local out = {}
	for _, p in Players:GetPlayers() do
		if instanceOf(p) == instanceId then
			table.insert(out, p)
		end
	end
	return out
end

function AudioService:GroupOf(player: Player): { Player }
	return AudioService:PlayersIn(instanceOf(player))
end

local function resolve(target: Target): { Player }
	if typeof(target) == "Instance" then
		return if (target :: Instance):IsA("Player") then { target :: Player } else {}
	elseif type(target) == "table" then
		return target :: { Player }
	elseif target == "all" then
		return Players:GetPlayers()
	elseif type(target) == "string" then
		return AudioService:PlayersIn(target)
	end
	return {}
end

function AudioService:Play(target: Target, name: string, at: (Instance | Vector3)?, opts: { [string]: any }?): number
	if not playRemote or AudioConfig.Sounds[name] == nil then
		return 0
	end
	local list = resolve(target)
	for _, p in list do
		(playRemote :: RemoteEvent):FireClient(p, name, at, opts)
	end
	if #list > 0 then
		count("audio_cues")
	end
	return #list
end

function AudioService:Stinger(target: Target, kind: string): number
	if not stingerRemote or AudioConfig.Stingers[kind] == nil then
		return 0
	end
	local list = resolve(target)
	for _, p in list do
		(stingerRemote :: RemoteEvent):FireClient(p, kind)
	end
	if #list > 0 then
		count("audio_cues")
	end
	return #list
end

local function rootOf(p: Player): BasePart?
	local c = p.Character
	return c and c:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function hook(serviceName: string, signalName: string, fn: (...any) -> ())
	local svc = services[serviceName]
	local sig = svc and svc[signalName]
	if type(sig) == "table" and type(sig.Connect) == "function" then
		sig:Connect(function(...)
			local ok, err = pcall(fn, ...)
			if not ok then
				warn(`[AudioService] {serviceName}.{signalName}: {err}`)
			end
		end)
	end
end

function AudioService:Init(all: { [string]: any })
	services = all
end

function AudioService:Start()
	playRemote = Net.event("Audio", "Play")
	stingerRemote = Net.event("Audio", "Stinger")

	hook("RescueService", "Rescued", function(player: Player, _id: string, _kind: string)
		AudioService:Stinger(player, "Rescue")
	end)
	hook("SquadService", "Downed", function(victim: Player, _cause: string, culprit: Player?)
		if culprit and culprit ~= victim then
			AudioService:Stinger(AudioService:GroupOf(victim), "FriendlyFire")
		end
	end)
	hook("ToolService", "HoseHit", function(_sprayer: Player, victim: Player)
		local now = os.clock()
		if now - (lastSplash[victim] or 0) < 0.75 then
			return
		end
		lastSplash[victim] = now
		local root = rootOf(victim)
		if root then
			AudioService:Play(AudioService:GroupOf(victim), "CartoonSplash", root)
		end
	end)
	hook("HazardService", "Zapped", function(victim: Player, culprit: Player?)
		AudioService:Stinger(AudioService:GroupOf(victim), if culprit then "Blame" else "Ragdoll")
	end)

	Players.PlayerRemoving:Connect(function(p)
		lastSplash[p] = nil
	end)
end

function AudioService:_selftest(): (boolean, string)
	if not playRemote or not stingerRemote then
		return false, "remotes not declared"
	end
	for kind, name in AudioConfig.Stingers do
		if AudioConfig.Sounds[name] == nil then
			return false, `stinger {kind} -> unknown sound {name}`
		end
	end
	for loc, name in AudioConfig.LocationAmbience do
		if AudioConfig.Sounds[name] == nil then
			return false, `ambience {loc} -> unknown sound {name}`
		end
	end
	local n = 0
	for _ in AudioConfig.Sounds do
		n += 1
	end
	return true, `{n} sounds`
end

return AudioService
