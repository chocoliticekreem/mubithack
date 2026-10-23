--!strict
-- BlameService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   BlameService:GetStats(player: Player): Types.PlayerStats
--   BlameService:BuildAwards(): { Types.Award }
--   BlameService:Reset()
-- Consumes (in Start, nil-guarded): FireService.Extinguished/.Spread, ToolService.WaterUsed/.DoorBroken/
--   .HoseHit, RescueService.Rescued, SquadService.Downed
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Types = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Types") :: ModuleScript)

local BlameService = {}
BlameService.Priority = 70

local services: { [string]: any } = {}

function BlameService:Init(all: { [string]: any })
	services = all
end

function BlameService:Start() end

function BlameService:GetStats(player: Player): Types.PlayerStats
	return {
		userId = player.UserId,
		helmet = 1,
		name = player.Name,
		firesOut = 0,
		firesStarted = 0,
		water = 0,
		doors = 0,
		rescued = 0,
		pandas = 0,
		downedOthers = 0,
		timesDowned = 0,
		teammateSprayed = 0,
	}
end

function BlameService:BuildAwards(): { Types.Award }
	return {}
end

function BlameService:Reset() end

function BlameService:_selftest(): (boolean, string)
	return true, "stub"
end

return BlameService
