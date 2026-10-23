--!strict
-- HazardService [owner: GF]. STUB from K0 (v1.5): harmless defaults until GF replaces this file.
-- Scripted chaos per mission instance (docs/game/01 §8). Hazards are scoped to an instanceId (v1's
-- single round uses the location Id, e.g. "Town", as its instanceId).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   HazardService:Trigger(instanceId: string, hazardId: Types.HazardId, params: { [string]: any }?): boolean
--   HazardService:Clear(instanceId: string)                         -- stop every live hazard (mission end)
--   HazardService:GetActive(instanceId: string): { Types.HazardId }
-- params per hazardId (all optional unless marked):
--   electrocution  { fuseBox: BasePart?, culprit: Player? }  -- WetFloor parts in the instance go live while
--                                                             the FuseBox attr Power = true; 40 dmg + 2 s ragdoll
--   fire_tornado   { position: Vector3?, seconds: number? }   -- ignites what it crosses, flings players
--   explosion      { position: Vector3 (required), radius: number?, culprit: Player? }
--   tidal_wave     { direction: Vector3?, seconds: number? }  -- extinguishes every Flammable in the instance
--   cigarette      { npc: Model? }                           -- farmer relights hay until slapped
-- Signals: Triggered(instanceId: string, hazardId: string), Zapped(victim: Player, culprit: Player?),
--          Flung(victim: Player, hazardId: string)
-- Remotes: Hazard/Zapped (S->C all: victim: number, culprit: number? UserIds),
--          Hazard/Fx (S->C all: hazardId: string, position: Vector3, params: { [string]: any })
-- Consumes (nil-guarded): FireService, HeatService, SquadService:Down, Ragdoll, MapService:GetInstance
-- Writes: FuseBox attr Power; counters hazards_triggered, electrocutions
-- Test hooks (DevHook only): _trigger(instanceId, hazardId), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)
local Types = require(Shared:WaitForChild("Types") :: ModuleScript)

local HazardService = {}
HazardService.Priority = 70
HazardService.Triggered = Signal.new() :: Signal.Signal<string, string>
HazardService.Zapped = Signal.new() :: Signal.Signal<Player, Player?>
HazardService.Flung = Signal.new() :: Signal.Signal<Player, string>

local services: { [string]: any } = {}

function HazardService:Init(all: { [string]: any })
	services = all
end

function HazardService:Start()
	Net.event("Hazard", "Zapped")
	Net.event("Hazard", "Fx")
end

function HazardService:Trigger(_instanceId: string, _hazardId: Types.HazardId, _params: { [string]: any }?): boolean
	return false
end

function HazardService:Clear(_instanceId: string) end

function HazardService:GetActive(_instanceId: string): { Types.HazardId }
	return {}
end

function HazardService:_trigger(instanceId: string, hazardId: Types.HazardId): boolean
	return self:Trigger(instanceId, hazardId, nil)
end

function HazardService:_selftest(): (boolean, string)
	return true, "stub"
end

return HazardService
