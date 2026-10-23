--!strict
-- FinaleService [owner: GF]. STUB from K0 (v2 per docs/game/03 §1): harmless defaults until GF builds it.
-- The dam_finale sequence: 3 detonator charges carried from the truck and planted on the dam face
-- (ProximityPrompts, 4 s hold), then the detonator -> HazardService:Trigger(instanceId, "tidal_wave").
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   FinaleService:Arm(instanceId: string)                           -- spawn charges + detonator
--   FinaleService:Detonate(instanceId: string, by: Player?): boolean -- false until every charge is planted
--   FinaleService:GetPlanted(instanceId: string): number
-- Signals: ChargePlanted(instanceId: string, by: Player), Detonated(instanceId: string, by: Player?)
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal") :: ModuleScript)

local FinaleService = {}
FinaleService.Priority = 75
FinaleService.ChargePlanted = Signal.new() :: Signal.Signal<string, Player>
FinaleService.Detonated = Signal.new() :: Signal.Signal<string, Player?>

local services: { [string]: any } = {}

function FinaleService:Init(all: { [string]: any })
	services = all
end

function FinaleService:Start() end

function FinaleService:Arm(_instanceId: string) end

function FinaleService:Detonate(_instanceId: string, _by: Player?): boolean
	return false
end

function FinaleService:GetPlanted(_instanceId: string): number
	return 0
end

function FinaleService:_selftest(): (boolean, string)
	return true, "stub"
end

return FinaleService
