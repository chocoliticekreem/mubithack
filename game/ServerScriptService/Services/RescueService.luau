--!strict
-- RescueService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   RescueService:Spawn(locationId: string, count: number)
--   RescueService:Clear()
--   RescueService:Deliver(player: Player): boolean       -- carrier reached a RescueDropoff volume
-- Signals: Rescued(player, rescueId: string, kind: string), Dropped(player, rescueId: string)
-- Remotes: Rescue/Drop (C->S, no args, 2/s)
-- Writes: Rescuable NPC Models (attrs RescueId, Kind, RescueState, CarriedBy); Player attr Carrying
-- Test hooks (DevHook only): _carry(player, rescueId), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)

local RescueService = {}
RescueService.Priority = 50
RescueService.Rescued = Signal.new() :: Signal.Signal<Player, string, string>
RescueService.Dropped = Signal.new() :: Signal.Signal<Player, string>

local services: { [string]: any } = {}

function RescueService:Init(all: { [string]: any })
	services = all
end

function RescueService:Start()
	Net.event("Rescue", "Drop")
end

function RescueService:Spawn(_locationId: string, _count: number) end

function RescueService:Clear() end

function RescueService:Deliver(_player: Player): boolean
	return false
end

function RescueService:_carry(_player: Player, _rescueId: string): boolean
	return false
end

function RescueService:_selftest(): (boolean, string)
	return true, "stub"
end

return RescueService
