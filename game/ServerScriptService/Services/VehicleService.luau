--!strict
-- VehicleService [owner: G2]. STUB from K0: harmless defaults until G2 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   VehicleService:GetTruck(): Model?
--   VehicleService:ResetTruck()                         -- back to the station bay (= ParkAt("Station"))
--   VehicleService:ParkAt(locationId: string): boolean  -- pivot the truck onto that location's TruckSpot
-- Signals: Driven(driver: Player, studs: number)        -- v2 (drivable truck); never fires in v1
-- Writes: Workspace.Truck67 (tag Truck) with parts tagged TruckRefill and RescueDropoff
-- Test hooks (DevHook only): _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal") :: ModuleScript)

local VehicleService = {}
VehicleService.Priority = 50
VehicleService.Driven = Signal.new() :: Signal.Signal<Player, number>

local services: { [string]: any } = {}

function VehicleService:Init(all: { [string]: any })
	services = all
end

function VehicleService:Start() end

function VehicleService:GetTruck(): Model?
	return nil
end

function VehicleService:ResetTruck() end

function VehicleService:ParkAt(_locationId: string): boolean
	return false
end

function VehicleService:_selftest(): (boolean, string)
	return true, "stub"
end

return VehicleService
