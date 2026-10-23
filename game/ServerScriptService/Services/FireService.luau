--!strict
-- FireService [owner: G1]. STUB from K0: harmless defaults until G1 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   FireService:Ignite(part: BasePart, cause: Player?): boolean
--   FireService:ApplyWater(player: Player?, origin: Vector3, aim: Vector3, litres: number): number
--   FireService:IsBurning(part: BasePart): boolean
--   FireService:CountBurning(locationId: string?): number
--   FireService:ExtinguishAll()
-- Signals: Ignited(part, cause: Player?), Spread(from, to), Extinguished(part, by: Player?), Charred(part)
-- Writes: tag Burning; attrs FireLevel (1..3), Charred on Flammable parts
-- Test hooks (DevHook only): _index(model, locationId), _ignite(pos), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Signal = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Signal") :: ModuleScript)

local FireService = {}
FireService.Priority = 50
FireService.Ignited = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Spread = Signal.new() :: Signal.Signal<BasePart, BasePart>
FireService.Extinguished = Signal.new() :: Signal.Signal<BasePart, Player?>
FireService.Charred = Signal.new() :: Signal.Signal<BasePart>

local services: { [string]: any } = {}

function FireService:Init(all: { [string]: any })
	services = all
end

function FireService:Start() end

function FireService:Ignite(_part: BasePart, _cause: Player?): boolean
	return false
end

function FireService:ApplyWater(_player: Player?, _origin: Vector3, _aim: Vector3, _litres: number): number
	return 0
end

function FireService:IsBurning(_part: BasePart): boolean
	return false
end

function FireService:CountBurning(_locationId: string?): number
	return 0
end

function FireService:ExtinguishAll() end

function FireService:_index(_model: Instance, _locationId: string) end

function FireService:_ignite(_pos: Vector3): BasePart?
	return nil
end

function FireService:_selftest(): (boolean, string)
	return true, "stub"
end

return FireService
