--!strict
-- ToolService [owner: G1]. STUB from K0: harmless defaults until G1 replaces this file.
-- Public API (contract, docs/game/03-tech-architecture.md §10):
--   ToolService:GiveLoadout(player: Player)              -- Hose + Axe, full tank
--   ToolService:Refill(player: Player, litres: number?)  -- nil = full
--   ToolService:ResetDoors(locationId: string)
-- Signals: DoorBroken(player, door: BasePart), WaterUsed(player, litres: number),
--          HoseHit(sprayer: Player, victim: Player)      -- K0 addition (friendly fire, P1.5)
--          HoseRecoil(sprayer: Player, impulse: Vector3) -- v1.5: push-back on the sprayer while spraying;
--                                                           applied with Ragdoll.knockback (ToolConfig.HoseRecoil)
-- Remotes: Tool/Spray (C->S, aim: Vector3 unit, 12/s burst 4)
-- Writes: Player attrs Water, TankSize, Spraying; Door attrs Locked, Broken
-- Test hooks (DevHook only): _spray(player, aim), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Net = require(Shared:WaitForChild("Net") :: ModuleScript)

local ToolService = {}
ToolService.Priority = 50
ToolService.DoorBroken = Signal.new() :: Signal.Signal<Player, BasePart>
ToolService.WaterUsed = Signal.new() :: Signal.Signal<Player, number>
ToolService.HoseHit = Signal.new() :: Signal.Signal<Player, Player>
ToolService.HoseRecoil = Signal.new() :: Signal.Signal<Player, Vector3>

local services: { [string]: any } = {}

function ToolService:Init(all: { [string]: any })
	services = all
end

function ToolService:Start()
	Net.event("Tool", "Spray")
end

function ToolService:GiveLoadout(_player: Player) end

function ToolService:Refill(_player: Player, _litres: number?) end

function ToolService:ResetDoors(_locationId: string) end

function ToolService:_spray(_player: Player, _aim: Vector3) end

function ToolService:_selftest(): (boolean, string)
	return true, "stub"
end

return ToolService
