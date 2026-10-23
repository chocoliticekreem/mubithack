--!strict
-- MissionService [owner: G3]. STUB from K0: harmless defaults until G3 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   MissionService:StartRound(locationId: string?, seconds: number?)
--   MissionService:EndRound(reason: Types.EndReason)
--   MissionService:GetState(): Types.RoundState
-- Signals: RoundStarted(locationId: string), RoundEnded(payload: Types.ResultsPayload)
-- Remotes: Mission/Alarm (S->C all: missionId, locationName), Mission/Results (S->C all: ResultsPayload)
-- Writes: Workspace attrs RoundState, RoundEndsAt, MissionId; counter rounds_completed
-- Test hooks (DevHook only): _startRound(locationId, seconds), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)

local MissionService = {}
MissionService.Priority = 60
MissionService.RoundStarted = Signal.new() :: Signal.Signal<string>
MissionService.RoundEnded = Signal.new() :: Signal.Signal<Types.ResultsPayload>

local services: { [string]: any } = {}

function MissionService:Init(all: { [string]: any })
	services = all
end

function MissionService:Start()
	Net.event("Mission", "Alarm")
	Net.event("Mission", "Results")
	workspace:SetAttribute(Names.Attr.RoundState, "Lobby")
end

function MissionService:StartRound(_locationId: string?, _seconds: number?) end

function MissionService:EndRound(_reason: Types.EndReason) end

function MissionService:GetState(): Types.RoundState
	return (workspace:GetAttribute(Names.Attr.RoundState) :: any) or "Lobby"
end

function MissionService:_startRound(locationId: string, seconds: number)
	self:StartRound(locationId, seconds)
end

function MissionService:_selftest(): (boolean, string)
	return true, "stub"
end

return MissionService
