--!strict
-- LobbyService [owner: G3]. STUB from K0 (v1.5): harmless defaults until G3 replaces this file.
-- The fire station is the LOBBY. Players spawn in the station. The Mission Board (part tagged
-- MissionBoard: SurfaceGui + ProximityPrompt, built by StationBuilder) lists MissionCatalog. Squads
-- of 1-4 queue on SquadPads (attr PadId); the squad leader picks a mission and launches; the squad
-- then plays it in its OWN location instance (MissionService:StartMission), so several squads run
-- different missions in parallel in one server. When the mission ends, the squad returns here.
-- Off by default: LobbyConfig.UseLobby = false keeps v1's single auto-round (GameConfig.AutoStart).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   LobbyService:GetSquads(): { Types.Squad }
--   LobbyService:GetSquad(squadId: string): Types.Squad?
--   LobbyService:Join(player: Player, padId: number): string?     -- squadId; first on a pad leads
--   LobbyService:Leave(player: Player)
--   LobbyService:Choose(player: Player, missionId: string): boolean -- leader only, enabled missions only
--   LobbyService:Launch(squadId: string, missionId: string): string? -- instanceId (MissionService:StartMission)
--   LobbyService:ReturnToLobby(players: { Player })               -- back onto station pads, InstanceId = ""
-- Signals: SquadChanged(squadId: string), Launched(squadId: string, missionId: string, instanceId: string)
-- Remotes: Lobby/Board (S->C all: squads: { Types.Squad }), Lobby/Choose (C->S missionId: string, 2/s),
--          Lobby/Launch (C->S none, 1/s; leader only)
-- Writes: Player attrs SquadId ("" = none), InstanceId ("" = in the lobby); counter squads_launched
-- Test hooks (DevHook only): _join(player, padId), _launch(squadId, missionId), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)

local LobbyService = {}
LobbyService.Priority = 55
LobbyService.SquadChanged = Signal.new() :: Signal.Signal<string>
LobbyService.Launched = Signal.new() :: Signal.Signal<string, string, string>

local services: { [string]: any } = {}

function LobbyService:Init(all: { [string]: any })
	services = all
end

function LobbyService:Start()
	Net.event("Lobby", "Board")
	Net.event("Lobby", "Choose")
	Net.event("Lobby", "Launch")
end

function LobbyService:GetSquads(): { Types.Squad }
	return {}
end

function LobbyService:GetSquad(_squadId: string): Types.Squad?
	return nil
end

function LobbyService:Join(_player: Player, _padId: number): string?
	return nil
end

function LobbyService:Leave(_player: Player) end

function LobbyService:Choose(_player: Player, _missionId: string): boolean
	return false
end

function LobbyService:Launch(_squadId: string, _missionId: string): string?
	return nil
end

function LobbyService:ReturnToLobby(_players: { Player }) end

function LobbyService:_join(player: Player, padId: number): string?
	return self:Join(player, padId)
end

function LobbyService:_launch(squadId: string, missionId: string): string?
	return self:Launch(squadId, missionId)
end

function LobbyService:_selftest(): (boolean, string)
	return true, "stub"
end

return LobbyService
