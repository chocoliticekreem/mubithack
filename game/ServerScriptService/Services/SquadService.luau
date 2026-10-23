--!strict
-- SquadService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   SquadService:GetHelmet(player: Player): number       -- 1..4
--   SquadService:Down(player: Player, cause: string, culprit: Player?)
--   SquadService:Revive(player: Player, by: Player)
--   SquadService:RespawnAll()                            -- everyone back to a StationSpawn pad
-- Signals: Downed(victim: Player, cause: string, culprit: Player?)
-- Writes: Player attrs Helmet, Downed
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)

local SquadService = {}
SquadService.Priority = 10
SquadService.Downed = Signal.new() :: Signal.Signal<Player, string, Player?>

local services: { [string]: any } = {}

function SquadService:Init(all: { [string]: any })
	services = all
end

function SquadService:Start() end

function SquadService:GetHelmet(player: Player): number
	return (player:GetAttribute(Names.Attr.Helmet) :: number?) or 1
end

function SquadService:Down(_player: Player, _cause: string, _culprit: Player?) end

function SquadService:Revive(_player: Player, _by: Player) end

function SquadService:RespawnAll() end

function SquadService:_selftest(): (boolean, string)
	return true, "stub"
end

return SquadService
