--!strict
-- HeatService [owner: G1]. STUB from K0 (v1.5): harmless defaults until G1 replaces this file.
-- Per-player Heat 0..100. Rises near Burning parts (per part: HeatConfig.RisePerSecond * FireLevel *
-- falloff(distance / Radius)), cools by CoolPerSecond when nothing is close, drops by SprayCool when a
-- teammate hoses you (ToolService.HoseHit) and by ExtinguisherCool from an extinguisher. At 100 the
-- player is Downed (SquadService:Down(player, "heat")), Overheated fires, Heat resets to ResetAfterDown.
-- HUD reads the Player attr Heat (vignette / red edge).
--
-- Public API (contract, docs/game/03-tech-architecture.md §10 "v1.5 additions"):
--   HeatService:GetHeat(player: Player): number
--   HeatService:AddHeat(player: Player, amount: number, source: string?)
--   HeatService:Cool(player: Player, amount: number, by: Player?)  -- by = teammate who sprayed you
--   HeatService:Reset(player: Player?)                             -- nil = everyone (mission start/end)
-- Signals: Overheated(player: Player)
-- Writes: Player attr Heat; counter heat_downs
-- Test hooks (DevHook only): _setHeat(player, value), _selftest()
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Signal = require(Shared:WaitForChild("Signal") :: ModuleScript)
local Names = require(Shared:WaitForChild("Names") :: ModuleScript)

local HeatService = {}
HeatService.Priority = 55
HeatService.Overheated = Signal.new() :: Signal.Signal<Player>

local services: { [string]: any } = {}

function HeatService:Init(all: { [string]: any })
	services = all
end

function HeatService:Start() end

function HeatService:GetHeat(player: Player): number
	return (player:GetAttribute(Names.Attr.Heat) :: number?) or 0
end

function HeatService:AddHeat(_player: Player, _amount: number, _source: string?) end

function HeatService:Cool(_player: Player, _amount: number, _by: Player?) end

function HeatService:Reset(_player: Player?) end

function HeatService:_setHeat(_player: Player, _value: number) end

function HeatService:_selftest(): (boolean, string)
	return true, "stub"
end

return HeatService
